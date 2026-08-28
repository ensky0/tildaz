// Cross-platform config_N.json schema + parser. Windows + macOS 같은 nested
// schema, default 만 OS-specific (font.family / font.size / shell / hotkey
// 등). `Defaults` struct + `defaultConfigToml(alloc, shell_resolved)` 가 schema
// single source — createDefault 가 그대로 파일에 저장 + parse 시 user config
// 와 비교 (`validateStructure`) 검증의 ground truth.
//
// 새 필드 추가 시 *Defaults + defaultConfigToml 한 곳만* update 하면 required /
// unknown / type 검증 자동 sync. value range 만 별도 hardcoded.

const std = @import("std");
const toml = @import("toml");
const Runtime = @import("runtime.zig").Runtime;
const builtin = @import("builtin");
const windows = std.os.windows;
const themes = @import("themes.zig");
const dialog = @import("dialog.zig");
const messages = @import("messages.zig");
const log = @import("log.zig");
const instance_context = @import("instance_context.zig");
// #431 — 기동 시 인스턴스 간 핫키 중복 검사. `instances.zig` 도 이 모듈을 import 하지만
// (`config.Hotkey`), 서로의 *값*에 의존하지 않아 순환 참조가 성립한다.
const instances = @import("instances.zig");
const paths = @import("paths.zig");
const font_validate = @import("font/validate.zig");
const font_constants = @import("font/constants.zig");
const font_spec = @import("font/spec.zig");
const physical_key = @import("physical_key.zig");
const input_policy = @import("input_policy.zig");
/// #496 — host 가 key event 의 물리 위치를 넘길 때 쓴다 (`lookupAction` 의 3 번째
/// 인자). config 표면의 타입이므로 여기서 다시 노출한다.
pub const PhysicalCode = physical_key.PhysicalCode;

const WCHAR = u16;

pub const MAX_FONT_FAMILIES = font_constants.MAX_CHAIN;

// Linux 는 이 둘이 아닌 `else` 분기 — 별 술어를 두지 않는다.
const is_windows = builtin.os.tag == .windows;
const is_macos = builtin.os.tag == .macos;

// --- DockPosition (cross-platform) ---

/// #533 — macOS 의 `Option` 을 Alt(Meta) 로 볼 것인가.
///
/// **macOS 에만 의미가 있다.** 그 platform 에서는 `Option` 이 OS 수준에서 문자를
/// 만들기 때문이다 (ABC 자판 `Option+a` → `å`, French `Option+e` → `ê`). 그래서 한
/// 키 조합이 두 뜻을 갖고, 둘 중 하나만 고를 수 있다 — 문자를 보내거나 `ESC a` 를
/// 보내거나. Linux · Windows 에는 그 갈림이 없다 (`Alt+a` 가 만드는 문자가 없어
/// 언제나 Meta 다).
///
/// **그런데도 세 platform 의 config 에 모두 둔다.** dotfiles 로 같은 파일을 여러 OS
/// 에서 쓰는 사람이 있고, 스키마 검증이 양방향이라 (모르는 키도 빠진 키도 fatal)
/// 한쪽에만 두면 파일이 호환되지 않는다. 이름에 `macos_` 를 박아 두어 다른 두
/// platform 에서 무엇인지 바로 보이게 했다 (Ghostty · kitty 도 같은 이름이다).
pub const MacOptionAsAlt = enum {
    /// Option 은 문자를 만든다 (macOS 표준). 기본값.
    none,
    /// 양쪽 Option 을 Alt 로.
    both,
    /// 왼쪽만 Alt — 오른쪽은 특수문자 입력용으로 남긴다.
    left,
    /// 오른쪽만 Alt.
    right,

    pub fn fromString(s: []const u8) ?MacOptionAsAlt {
        const map = [_]struct { name: []const u8, val: MacOptionAsAlt }{
            .{ .name = "none", .val = .none },
            .{ .name = "both", .val = .both },
            .{ .name = "left", .val = .left },
            .{ .name = "right", .val = .right },
        };
        for (map) |m| {
            if (std.mem.eql(u8, s, m.name)) return m.val;
        }
        return null;
    }
};

pub const DockPosition = enum {
    top,
    bottom,
    left,
    right,

    pub fn fromString(s: []const u8) ?DockPosition {
        const map = [_]struct { name: []const u8, val: DockPosition }{
            .{ .name = "top", .val = .top },
            .{ .name = "bottom", .val = .bottom },
            .{ .name = "left", .val = .left },
            .{ .name = "right", .val = .right },
        };
        for (map) |entry| {
            if (std.mem.eql(u8, s, entry.name)) return entry.val;
        }
        return null;
    }
};

// --- Hotkey (platform-specific ABI, same string parser interface) ---

/// Windows: `RegisterHotKey` 의 vkey + modifier flags. macOS: CGEventTap 이
/// 받는 `kVK_*` keycode + `kCGEventFlagMask*` modifier mask. 외부 인터페이스는
/// `Hotkey.fromString(s)` 로 동일.
pub const Hotkey = if (is_windows) WindowsHotkey else if (is_macos) MacHotkey else LinuxHotkey;

pub const CAPTURE_MOD_ALT: u32 = 0x1;
pub const CAPTURE_MOD_CTRL: u32 = 0x2;
pub const CAPTURE_MOD_SHIFT: u32 = 0x4;
pub const CAPTURE_MOD_PRIMARY: u32 = 0x8;

fn modifierFreeCaptureAllowed(key_name: []const u8) bool {
    const names = [_][]const u8{
        "F1", "F2", "F3", "F4",  "F5",  "F6",
        "F7", "F8", "F9", "F10", "F11", "F12",
    };
    for (names) |name| {
        if (std.mem.eql(u8, key_name, name)) return true;
    }
    return false;
}

fn globalHotkeyAllowed(key_name: []const u8, has_command_modifier: bool) bool {
    return has_command_modifier or modifierFreeCaptureAllowed(key_name);
}

// --- 공통 hotkey 토크나이저 (#294 G1) ---
//
// 문법 · alias · 일반 입력 보호 규칙은 세 OS 가 동일해야 한다 (SPEC §7.1
// "모든 platform 동일 문법"). OS 별로 다른 것은 key / modifier 의 *코드 값*
// 뿐이므로, 각 `fromString` 은 이 파서의 결과를 OS 코드로 변환만 한다.

const HotkeyNamedKey = enum {
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    space,
    grave,
    tab,
    escape,
    @"return",
    page_up,
    page_down,
    bracket_left,
    bracket_right,
};

const HotkeyKeyToken = union(enum) {
    named: HotkeyNamedKey,
    /// 소문자 latin letter 또는 digit (ASCII).
    char: u8,
    /// #496 — **물리 위치** (`[KeyW]`). 라벨이 아니므로 layout 을 갈아도 같은 자리다.
    /// 비라틴 layout 에서 글자 단축키를 쓸 수 있는 유일한 방법이다.
    code: PhysicalCode,
};

const ParsedHotkey = struct {
    ctrl: bool,
    shift: bool,
    alt: bool,
    super: bool,
    key: HotkeyKeyToken,
};

/// hotkey 문자열이 거부된 **이유**. 원인이 둘인데 메시지가 하나여서 사용자를 막다른
/// 길로 보내고 있었다 (#484): `ctrl+twosuperior` 는 이미 modifier 가 있는데도
/// "Other keys require Ctrl, Alt, Super, or Cmd" 라고 안내했다. 신고자는 modifier 를
/// 더해 보고도 같은 메시지를 받아 실제 원인 (모르는 key 이름) 을 알 수 없었다.
pub const HotkeyFailure = enum {
    /// key 자리의 이름을 못 알아봤다 — 또는 key 토큰이 아예 없다.
    unknown_key,
    /// key 는 유효하지만 modifier 없이 전역 등록할 수 없는 키다 (F1~F12 만 허용).
    modifier_required,
    /// #496 — macOS 가 이 자리를 **다른 이름으로 보고**한다. `PrintScreen` ·
    /// `ScrollLock` · `Pause` 를 PC 자판에서 누르면 `F13` · `F14` · `F15` 로 온다
    /// (Apple 확장 자판이 그 자리에 F13~F15 를 둔다). 키가 없는 것이 아니므로
    /// 안내가 "쓸 수 없다" 가 아니라 "저 이름을 쓰라" 여야 한다.
    position_aliased_on_macos,
    /// #496 — macOS 에 이 자리가 정말로 없다. `F21`~`F24` (Apple 의 `kVK_*` 가 F20
    /// 에서 멈춘다) 와 JIS 입력 전환 키 (`Convert` · `NonConvert` · `KanaMode`).
    position_absent_on_macos,
};

/// `Hotkey.fromString` 이 왜 null 이었는지. **판정을 재현하지 않고** 같은
/// `parseHotkeyString` 을 쓴다 — 두 곳에 규칙을 두면 갈라진다 (#484 의 원인이
/// writer/matcher 가 갈라진 것이었다).
pub fn hotkeyFailure(s: []const u8) ?HotkeyFailure {
    return switch (parseHotkeyString(s, .global_hotkey)) {
        .ok => null,
        .unknown_key => .unknown_key,
        .modifier_required => .modifier_required,
        .position_aliased_on_macos => .position_aliased_on_macos,
        .position_absent_on_macos => .position_absent_on_macos,
    };
}

const HotkeyParse = union(enum) {
    ok: ParsedHotkey,
    unknown_key,
    modifier_required,
    position_aliased_on_macos,
    position_absent_on_macos,
};

/// 파싱 규칙이 쓰임새에 따라 다르다 (#493). `parseHotkeyString` 참고.
pub const HotkeyScope = enum {
    /// `hotkey` — OS 에 등록하는 전역 핫키. modifier 없는 일반 키를 허용하면 OS
    /// 전체의 타이핑을 가로챈다.
    global_hotkey,
    /// `[keys]` — 앱 내부 단축키. 터미널 focus 중에만 유효하므로 위험 범위가 좁다.
    app_binding,
};

fn parseHotkeyString(s: []const u8, scope: HotkeyScope) HotkeyParse {
    var ctrl = false;
    var shift = false;
    var alt = false;
    var super = false;
    var key: ?HotkeyKeyToken = null;
    var iter = std.mem.tokenizeScalar(u8, s, '+');
    while (iter.next()) |raw| {
        const tok = std.mem.trim(u8, raw, " \t");
        if (eqIc(tok, "ctrl") or eqIc(tok, "control")) {
            ctrl = true;
        } else if (eqIc(tok, "shift")) {
            shift = true;
        } else if (eqIc(tok, "alt") or eqIc(tok, "option") or eqIc(tok, "opt")) {
            alt = true;
        } else if (eqIc(tok, "win") or eqIc(tok, "super") or eqIc(tok, "cmd") or
            eqIc(tok, "meta") or eqIc(tok, "command") or eqIc(tok, "logo"))
        {
            // 모두 같은 키 — Linux Super = Windows Win = Mac Cmd = KDE Meta
            // = Qt Logo. 사용자 친숙한 표기 어떤 것이든 받음.
            super = true;
        } else {
            key = hotkeyKeyFromName(tok) orelse return .unknown_key;
        }
    }
    // key 토큰이 아예 없는 경우 (예: `"ctrl"` 하나만) 도 "모르는 key" 로 묶는다 —
    // 사용자가 받아야 하는 안내가 같다 (받는 key 목록).
    const resolved = key orelse return .unknown_key;
    // #496 — 이 platform 에서 값이 없는 자리는 거부한다. 조용히 미동작으로 두면
    // 사용자가 config 를 몇 번이고 다시 읽게 된다 (#208 이 막으려던 것).
    if (is_macos and resolved == .code and !physical_key.availableOnThisPlatform(resolved.code)) {
        return if (physical_key.macAlias(resolved.code) != null)
            .position_aliased_on_macos
        else
            .position_absent_on_macos;
    }
    // Bare 문자/숫자/Space/Tab/grave나 Shift-only 조합을 전역 단축키로
    // 등록하면 일상 입력을 OS 전체에서 가로챈다. modifier 없이 안전하게
    // 허용하는 키는 F1~F12뿐 — capturedHotkeyText 와 동일 규칙.
    const is_function_key = switch (resolved) {
        .named => |n| switch (n) {
            .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => true,
            else => false,
        },
        .char => false,
        // #496 1-c — 위치 표기가 전역 hotkey 에 들어오면서 이 자리가 살아났다.
        // 기준은 라벨과 같다: **글자를 내지 않는 함수 키만** modifier 없이 받는다.
        //
        // `F13`~`F24` 까지 넣는 것은 라벨 집합보다 넓지만 의도한 것이다. 그 자리는
        // 라벨로 적을 방법이 아예 없고 (이름이 없다), 물리 자판에 달린 경우가 드물어
        // **QMK · ZMK 로 다른 키를 그 코드에 매핑해 쓰는** 것이 실제 쓰임이다
        // (`physical_key.zig` 헤더). 그런 사용자에게 modifier 를 요구하면 그 키를
        // 전역 핫키로 쓸 방법이 없어진다. 글자를 내지 않으므로 일상 입력을 훔치지도
        // 않는다 — 이 규칙이 막으려는 것이 그것이다.
        .code => |c| switch (c) {
            .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => true,
            .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20 => true,
            .f21, .f22, .f23, .f24 => true,
            else => false,
        },
    };
    if (scope == .global_hotkey) {
        if (!(ctrl or alt or super) and !is_function_key) return .modifier_required;
    } else {
        // #493 — `[keys]` (앱 내부 단축키) 는 규칙이 다르다. 전역 핫키의 제약은 *OS
        // 전체의 입력을 가로채는* 것을 막기 위한 것이고, 앱 내부 단축키는 터미널이
        // focus 를 가진 동안만 유효하다. 그래서 위험의 성질이 다르다.
        //
        // 여기서 막아야 하는 것은 **타이핑을 훔치는 것**이다. `shift+t` 를 허용하면
        // 터미널에 `T` 를 칠 수 없다. 반면 `shift+pageup` 은 PageUp 이 글자를 내는
        // 키가 아니라 무해하다 — 그리고 기본 bindings 가 그것을 쓴다.
        //
        // 그래서 판정 기준을 "modifier 유무" 가 아니라 **그 키가 글자를 내는가** 로
        // 둔다. 글자를 내지 않는 키 (F1~F12 · PageUp · PageDown) 는 modifier 없이도
        // 안전하고, 글자를 내는 키는 ctrl / alt / super 중 하나가 필요하다.
        const types_text = switch (resolved) {
            .char => true,
            .named => |n| switch (n) {
                .space, .tab, .@"return" => true,
                .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => false,
                .page_up, .page_down => false,
                .escape => false,
                // 글자를 내는 키 — modifier 없이 바인딩하면 터미널에 그 글자를 칠 수
                // 없게 된다.
                .grave, .bracket_left, .bracket_right => true,
            },
            // #496 — 위치도 같은 기준이다. 그 *자리* 가 글자를 내는지로 본다: 어떤
            // layout 에서든 `KeyW` 자리는 글자를 내고 `F5` 자리는 내지 않는다.
            //
            // 방향키 · `Home` · `End` · `Delete` 등은 글자를 내지 않지만 **터미널로
            // escape sequence 를 보낸다.** modifier 없이 바인딩하면 그 키를 TUI 앱에
            // 넘길 방법이 없어지므로 여기서는 "글자를 내는 것" 과 같이 취급한다 —
            // `else => true` 가 그 뜻이다. 예전부터 맨 `PageUp` / `PageDown` /
            // `Escape` 를 허용해 온 것은 유지한다 (그 셋은 라벨 쪽 규칙과 짝이다).
            .code => |c| switch (c) {
                .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => false,
                .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20 => false,
                .f21, .f22, .f23, .f24 => false,
                .print_screen, .scroll_lock, .pause, .context_menu => false,
                .num_lock, .caps_lock => false,
                .page_up, .page_down, .escape => false,
                else => true,
            },
        };
        if (types_text and !(ctrl or alt or super)) return .modifier_required;
    }
    return .{ .ok = .{ .ctrl = ctrl, .shift = shift, .alt = alt, .super = super, .key = resolved } };
}

/// 키 이름 토큰 → 정규화된 key. 두 표기 모두 받음 (사용자 친화):
///   - 이름: `f1`, `grave` / `backquote`, `space`, `tab`, `escape` / `esc`,
///     `return` / `enter`
///   - literal: `` ` ``, ASCII letter (a-z / A-Z), digit (0-9)
///
/// **수용 범위는 Linux native backend가 공통으로 변환하는 key set과 1:1** (#208).
/// 이전엔 Linux가 ASCII symbol (`~`, `!`, `=`, `-` 등) 모두 받았으나
/// backend key-name 매핑 부재로 `"F1"` silent fallback이 발생했다. 명시 reject로
/// caller(config load)의 `dialog.showFatal` 경로를 활성화해 잘못된 binding을
/// 조용히 만드는 일을 막는다. literal symbol 확대는 모든 native backend의
/// 실제 key-code 매핑을 검증하는 별도 작업이다.
fn hotkeyKeyFromName(name: []const u8) ?HotkeyKeyToken {
    const map = [_]struct { name: []const u8, key: HotkeyNamedKey }{
        .{ .name = "f1", .key = .f1 },            .{ .name = "f2", .key = .f2 },
        .{ .name = "f3", .key = .f3 },            .{ .name = "f4", .key = .f4 },
        .{ .name = "f5", .key = .f5 },            .{ .name = "f6", .key = .f6 },
        .{ .name = "f7", .key = .f7 },            .{ .name = "f8", .key = .f8 },
        .{ .name = "f9", .key = .f9 },            .{ .name = "f10", .key = .f10 },
        .{ .name = "f11", .key = .f11 },          .{ .name = "f12", .key = .f12 },
        .{ .name = "space", .key = .space },      .{ .name = "grave", .key = .grave },
        .{ .name = "backquote", .key = .grave },  .{ .name = "tab", .key = .tab },
        .{ .name = "escape", .key = .escape },    .{ .name = "esc", .key = .escape },
        .{ .name = "return", .key = .@"return" }, .{ .name = "enter", .key = .@"return" },
        // #493 — `[keys]` 의 기본 bindings 가 쓴다 (scroll_page_up / prev_tab 등).
        // 어느 layout 에나 있는 단일 물리 키라 layout 종속 문제가 없다 (#482).
        .{ .name = "pageup", .key = .page_up },   .{ .name = "pgup", .key = .page_up },
        .{ .name = "pagedown", .key = .page_down }, .{ .name = "pgdn", .key = .page_down },
        // #493 — 기본 bindings 의 `prev_tab` / `next_tab` 이 쓴다. 세 platform 의 키
        // 값이 이미 기존 매처에 있어 추측이 아니다 (아래 각 map 의 주석 참고).
        .{ .name = "bracketleft", .key = .bracket_left },
        .{ .name = "bracketright", .key = .bracket_right },
    };
    for (map) |entry| {
        if (eqIc(name, entry.name)) return .{ .named = entry.key };
    }
    // #496 — 위치 표기 `[KeyW]`. VS Code 와 같은 대괄호이고 안의 이름은 W3C
    // `KeyboardEvent.code` 값이다 (`physical_key.zig`).
    //
    // `[` 와 `]` 는 **라벨로도** 받는 키라 (`prev_tab` 기본값이 `ctrl+shift+[`)
    // 표기가 겹쳐 보인다. 구분은 길이로 명확하다 — 1 자 `[` 는 라벨, `[...]` 는
    // 위치다. VS Code 도 같은 상황을 안고 배포한다 (기본값에 `ctrl+[` 가 있다).
    // 아래 `name.len == 1` 분기보다 **먼저** 봐야 한다.
    if (name.len >= 3 and name[0] == '[' and name[name.len - 1] == ']') {
        const inner = name[1 .. name.len - 1];
        return .{ .code = physical_key.fromName(inner) orelse return null };
    }
    if (name.len == 1) {
        const c = name[0];
        if (c >= 'A' and c <= 'Z') return .{ .char = c + 0x20 }; // 소문자로 정규화
        if (c >= 'a' and c <= 'z') return .{ .char = c };
        if (c >= '0' and c <= '9') return .{ .char = c };
        if (c == '`') return .{ .named = .grave };
        if (c == '[') return .{ .named = .bracket_left };
        if (c == ']') return .{ .named = .bracket_right };
    }
    return null;
}

/// OS key event를 config에 저장하는 canonical hotkey 문자열로 변환한다.
/// key_code의 의미만 platform별이다: Linux keysym, Windows virtual-key,
/// macOS hardware keyCode. modifier 비트는 위 CAPTURE_MOD_*로 정규화한다.
pub fn capturedHotkeyText(buf: []u8, key_code: u32, modifiers: u32) ?[]const u8 {
    const key_name = switch (builtin.os.tag) {
        .linux => linuxKeysymName(if (key_code >= 'A' and key_code <= 'Z') key_code + 0x20 else key_code),
        .windows => windowsVkeyName(key_code),
        .macos => macKeycodeName(key_code),
        else => null,
    } orelse return null;

    // Bare 문자/숫자/Space/Tab/grave나 Shift-only 조합을 전역 단축키로
    // 등록하면 일상 입력을 OS 전체에서 가로챈다. modifier 없이 안전하게
    // 허용하는 키는 F1~F12뿐이다. 일반 키는 command 성격의 modifier가 필수다.
    const command_modifiers = CAPTURE_MOD_CTRL | CAPTURE_MOD_ALT | CAPTURE_MOD_PRIMARY;
    if (!globalHotkeyAllowed(key_name, (modifiers & command_modifiers) != 0)) return null;

    // #451 — `std.io.fixedBufferStream` 은 0.16 에서 삭제됐다 (릴리즈 노트 *Io: delete
    // GenericReader, AnyReader, FixedBufferStream*). 고정 버퍼 쓰기는 `Io.Writer.fixed`
    // 가 그 자리이고, 쓴 만큼은 `getWritten()` 대신 `buffered()` 로 얻는다.
    var fbs: std.Io.Writer = .fixed(buf);
    const writer = &fbs;
    const ModifierPart = struct { bit: u32, text: []const u8 };
    const modifier_parts = if (builtin.os.tag == .macos)
        [_]ModifierPart{
            .{ .bit = CAPTURE_MOD_CTRL, .text = "Control+" },
            .{ .bit = CAPTURE_MOD_ALT, .text = "Option+" },
            .{ .bit = CAPTURE_MOD_SHIFT, .text = "Shift+" },
            .{ .bit = CAPTURE_MOD_PRIMARY, .text = "Command+" },
        }
    else
        [_]ModifierPart{
            .{ .bit = CAPTURE_MOD_CTRL, .text = "Ctrl+" },
            .{ .bit = CAPTURE_MOD_SHIFT, .text = "Shift+" },
            .{ .bit = CAPTURE_MOD_ALT, .text = "Alt+" },
            .{ .bit = CAPTURE_MOD_PRIMARY, .text = "Super+" },
        };
    for (modifier_parts) |part| {
        if ((modifiers & part.bit) != 0) writer.writeAll(part.text) catch return null;
    }
    writer.writeAll(key_name) catch return null;
    return fbs.buffered();
}

/// Parsed platform-native hotkey를 command menu에 표시할 canonical 문자열로
/// 되돌린다. config가 source of truth이며 F1을 별도로 hardcode하지 않는다.
pub fn hotkeyDisplay(buf: []u8, hotkey: Hotkey) []const u8 {
    const native = switch (builtin.os.tag) {
        .linux => .{ .key = hotkey.keysym, .modifiers = hotkey.modifiers },
        .windows => .{ .key = hotkey.vkey, .modifiers = hotkey.modifiers },
        .macos => blk: {
            var modifiers: u32 = 0;
            if ((hotkey.modifiers & 0x00040000) != 0) modifiers |= CAPTURE_MOD_CTRL;
            if ((hotkey.modifiers & 0x00080000) != 0) modifiers |= CAPTURE_MOD_ALT;
            if ((hotkey.modifiers & 0x00020000) != 0) modifiers |= CAPTURE_MOD_SHIFT;
            if ((hotkey.modifiers & 0x00100000) != 0) modifiers |= CAPTURE_MOD_PRIMARY;
            break :blk .{ .key = hotkey.keycode, .modifiers = modifiers };
        },
        else => return "?",
    };
    const text = capturedHotkeyText(buf, native.key, native.modifiers) orelse return "?";
    // Linux 의 캡처 canonical 은 소문자 문자 키 (`Ctrl+Shift+t` — parser 정규화와
    // round-trip). 사용자 *표시* 관례는 세 platform 모두 대문자 (`Ctrl+Shift+T`,
    // KDE / GNOME 표기 동일) 라 표시 시점에만 대문자화한다. 문자 키 토큰은
    // 항상 마지막 + 단일 char — `space` / `grave` 같은 이름 키는 건드리지 않음.
    if (text.len >= 1) {
        const is_single_char_key = text.len == 1 or text[text.len - 2] == '+';
        const last = &buf[text.len - 1];
        if (is_single_char_key and last.* >= 'a' and last.* <= 'z') last.* -= 0x20;
    }
    return text;
}

test "configured hotkey display is derived from the parsed native value" {
    var buf: [64]u8 = undefined;
    const parsed = Hotkey.fromString("ctrl+shift+t").?;
    const expected = if (builtin.os.tag == .macos) "Control+Shift+T" else "Ctrl+Shift+T";
    try std.testing.expectEqualStrings(expected, hotkeyDisplay(&buf, parsed));
}

/// Linux global-hotkey backend 공통 xkb keysym 매핑. Win `WindowsHotkey` /
/// mac `MacHotkey` 와 같은 토큰 분리 패턴 (`+` 로 token, modifier + 키 이름).
/// DE별 backend가 이 `keysym + modifiers`를 KGlobalAccel의 Qt key 또는 GTK/XKB
/// accelerator 문자열로 변환한다.
const LinuxHotkey = struct {
    /// keysym (xkb). `f1` = 0xffbe (xkbcommon `XKB_KEY_F1`).
    keysym: u32 = 0xffbe,
    /// modifier 비트마스크. Win 패턴 동등 — `MOD_*` 비트. `keysymToAccelerator`
    /// 가 이를 `<Control><Shift>...` 같은 prefix 로 변환.
    modifiers: u32 = 0,

    /// #496 — non-null 이면 이 binding 은 **물리 위치**로 매칭한다 (`[KeyW]`).
    /// 그때 라벨 쪽 값 (`keysym`) 은 의미가 없다. `lookupAction` 이 이 필드로
    /// 어느 기준을 볼지 고른다 — 두 기준을 한 값에 눌러 담을 수 없어서 (같은
    /// event 가 라벨 binding 과 위치 binding 에 동시에 걸려야 한다) 필드를 나눈다.
    code: ?PhysicalCode = null,

    pub const MOD_ALT: u32 = 0x1;
    pub const MOD_CTRL: u32 = 0x2;
    pub const MOD_SHIFT: u32 = 0x4;
    pub const MOD_SUPER: u32 = 0x8; // Win key / Super / `cmd` 토큰.

    pub fn fromString(s: []const u8) ?LinuxHotkey {
        const parsed = switch (parseHotkeyString(s, .global_hotkey)) {
            .ok => |p| p,
            else => return null,
        };
        return fromParsed(parsed);
    }

    /// #493 — `[keys]` 파싱이 같은 변환을 쓴다. `fromString` 안에 두면 scope 마다
    /// 복제해야 하고, 복제하면 갈라진다 (#484 의 교훈).
    pub fn fromParsed(parsed: ParsedHotkey) LinuxHotkey {
        var modifiers: u32 = 0;
        if (parsed.alt) modifiers |= MOD_ALT;
        if (parsed.ctrl) modifiers |= MOD_CTRL;
        if (parsed.shift) modifiers |= MOD_SHIFT;
        if (parsed.super) modifiers |= MOD_SUPER;
        return .{
            .keysym = keysymFromKey(parsed.key),
            .modifiers = modifiers,
            .code = if (parsed.key == .code) parsed.key.code else null,
        };
    }

    /// 정규화된 key → xkb keysym. `xkbcommon/xkbcommon-keysyms.h` 의
    /// `XKB_KEY_*`. Latin 문자 / 숫자 는 ASCII 값 그대로 keysym (xkb 정의).
    fn keysymFromKey(key: HotkeyKeyToken) u32 {
        return switch (key) {
            .char => |c| c,
            // 위치 binding 은 keysym 으로 매칭하지 않는다 — `code` 필드가 기준이다.
            // 0 은 어떤 실제 keysym 과도 겹치지 않는 sentinel 이다.
            .code => 0,
            .named => |n| switch (n) {
                .f1 => 0xffbe,
                .f2 => 0xffbf,
                .f3 => 0xffc0,
                .f4 => 0xffc1,
                .f5 => 0xffc2,
                .f6 => 0xffc3,
                .f7 => 0xffc4,
                .f8 => 0xffc5,
                .f9 => 0xffc6,
                .f10 => 0xffc7,
                .f11 => 0xffc8,
                .f12 => 0xffc9,
                .space => 0x0020,
                .grave => 0x0060,
                .tab => 0xff09,
                .escape => 0xff1b,
                .@"return" => 0xff0d,
                .page_up => 0xff55,
                .page_down => 0xff56,
                // `wayland_minimal.xkb_key_bracketleft` / `..right` 와 같은 값.
                .bracket_left => 0x5b,
                .bracket_right => 0x5d,
            },
        };
    }
};

/// 검증된 Linux hotkey keysym을 desktop/compositor 설정에 쓰는 표준 이름으로
/// 되돌린다. fromString의 수용 범위와 반드시 1:1로 유지한다.
pub fn linuxKeysymName(keysym: u32) ?[]const u8 {
    return switch (keysym) {
        0xffbe => "F1",
        0xffbf => "F2",
        0xffc0 => "F3",
        0xffc1 => "F4",
        0xffc2 => "F5",
        0xffc3 => "F6",
        0xffc4 => "F7",
        0xffc5 => "F8",
        0xffc6 => "F9",
        0xffc7 => "F10",
        0xffc8 => "F11",
        0xffc9 => "F12",
        0xff55 => "Page_Up",
        0xff56 => "Page_Down",
        0x5b => "bracketleft",
        0x5d => "bracketright",
        0xff09 => "Tab",
        0xff0d => "Return",
        0xff1b => "Escape",
        'a'...'z', '0'...'9' => &linux_single_char_lookup[keysym - 0x0020],
        ' ' => "space",
        '`' => "grave",
        else => null,
    };
}

const linux_single_char_lookup = blk: {
    var table: [0x7a - 0x20 + 1][1]u8 = undefined;
    for (0x20..0x7b) |value| table[value - 0x20][0] = @intCast(value);
    break :blk table;
};

test "captured hotkey is formatted canonically" {
    if (builtin.os.tag == .linux) {
        var buf: [64]u8 = undefined;
        const text = capturedHotkeyText(&buf, 0xffbf, CAPTURE_MOD_CTRL | CAPTURE_MOD_SHIFT).?;
        try std.testing.expectEqualStrings("Ctrl+Shift+F2", text);
        try std.testing.expect(Hotkey.fromString(text) != null);
    }
}

test "macOS captured hotkey uses native modifier names and keeps legacy aliases" {
    if (builtin.os.tag == .macos) {
        var buf: [64]u8 = undefined;
        const text = capturedHotkeyText(
            &buf,
            0x11, // kVK_ANSI_T
            CAPTURE_MOD_CTRL | CAPTURE_MOD_ALT | CAPTURE_MOD_SHIFT | CAPTURE_MOD_PRIMARY,
        ).?;
        try std.testing.expectEqualStrings("Control+Option+Shift+Command+T", text);

        const native = MacHotkey.fromString(text).?;
        const legacy = MacHotkey.fromString("Ctrl+Alt+Shift+Cmd+T").?;
        try std.testing.expectEqual(native.keycode, legacy.keycode);
        try std.testing.expectEqual(native.modifiers, legacy.modifiers);
    }
}

test "modifier-free capture only accepts function keys" {
    if (builtin.os.tag == .linux) {
        var buf: [64]u8 = undefined;
        try std.testing.expectEqualStrings("F3", capturedHotkeyText(&buf, 0xffc0, 0).?);
        try std.testing.expect(capturedHotkeyText(&buf, 't', 0) == null);
        try std.testing.expect(capturedHotkeyText(&buf, '3', 0) == null);
        try std.testing.expect(capturedHotkeyText(&buf, ' ', 0) == null);
        try std.testing.expect(capturedHotkeyText(&buf, 0xff09, 0) == null);
        try std.testing.expect(capturedHotkeyText(&buf, '`', 0) == null);
        try std.testing.expect(capturedHotkeyText(&buf, 't', CAPTURE_MOD_SHIFT) == null);
        try std.testing.expectEqualStrings("Ctrl+t", capturedHotkeyText(&buf, 't', CAPTURE_MOD_CTRL).?);
        try std.testing.expectEqualStrings("Ctrl+Shift+t", capturedHotkeyText(&buf, 't', CAPTURE_MOD_CTRL | CAPTURE_MOD_SHIFT).?);
    }
}

test "config parser rejects unsafe global hotkeys" {
    if (builtin.os.tag == .linux) {
        try std.testing.expect(Hotkey.fromString("f3") != null);
        try std.testing.expect(Hotkey.fromString("t") == null);
        try std.testing.expect(Hotkey.fromString("shift+t") == null);
        try std.testing.expect(Hotkey.fromString("ctrl+t") != null);
        try std.testing.expect(Hotkey.fromString("ctrl+shift+t") != null);
    }
}

test "#493 [keys] scope accepts what the defaults need, and still guards typing" {
    // 기본 bindings 가 실제로 파싱되는지 — 이게 깨지면 첫 실행부터 fatal 이다.
    // (`ctrl+shift+[` 가 수용 집합에 없어 여기서 잡혔던 적이 있다.)
    for (std.enums.values(KeyAction)) |action| {
        for (defaultBindings(action)) |text| {
            const parsed = parseHotkeyString(text, .app_binding);
            if (parsed != .ok) {
                std.debug.print("기본 binding 이 파싱 실패: {s} = \"{s}\" ({s})\n", .{ action.configName(), text, @tagName(parsed) });
                return error.TestUnexpectedResult;
            }
        }
    }

    // `[keys]` 는 글자를 내지 않는 키를 modifier 없이 허용한다 — 기본값이 쓴다.
    try std.testing.expect(parseHotkeyString("shift+pageup", .app_binding) == .ok);
    try std.testing.expect(parseHotkeyString("pageup", .app_binding) == .ok);
    try std.testing.expect(parseHotkeyString("f5", .app_binding) == .ok);

    // 글자를 내는 키는 여전히 modifier 가 필요하다 — 없으면 터미널에 그 글자를
    // 칠 수 없게 된다.
    try std.testing.expectEqual(HotkeyParse.modifier_required, parseHotkeyString("t", .app_binding));
    try std.testing.expectEqual(HotkeyParse.modifier_required, parseHotkeyString("shift+t", .app_binding));
    try std.testing.expectEqual(HotkeyParse.modifier_required, parseHotkeyString("[", .app_binding));
    try std.testing.expectEqual(HotkeyParse.modifier_required, parseHotkeyString("shift+space", .app_binding));

    // 전역 핫키 규칙은 더 엄격하다 — Shift 는 trigger modifier 가 아니다.
    try std.testing.expectEqual(HotkeyParse.modifier_required, parseHotkeyString("shift+pageup", .global_hotkey));
    try std.testing.expect(parseHotkeyString("f5", .global_hotkey) == .ok);
}

test "#493 lookup is exact — no shift-insensitive fallback" {
    // 이 테스트가 `lookupAction` 을 실제로 호출해 **세 platform 에서 컴파일 검증**
    // 되게 한다 (Zig 는 호출되지 않는 함수 본문을 분석하지 않는다).
    var buf: [MAX_KEY_BINDINGS]KeyBinding = undefined;
    var n: usize = 0;
    const add = struct {
        fn f(list: []KeyBinding, count: *usize, text: []const u8, action: KeyAction) !void {
            const parsed = switch (parseHotkeyString(text, .app_binding)) {
                .ok => |v| v,
                else => return error.TestUnexpectedResult,
            };
            list[count.*] = .{ .hotkey = Hotkey.fromParsed(parsed), .action = action };
            count.* += 1;
        }
    }.f;
    try add(&buf, &n, "alt+return", .fullscreen);
    try add(&buf, &n, "shift+alt+return", .fullscreen_workarea);
    try add(&buf, &n, "alt+1", .switch_tab1);
    const bindings = buf[0..n];

    const hk = struct {
        fn f(text: []const u8) !Hotkey {
            return switch (parseHotkeyString(text, .app_binding)) {
                .ok => |v| Hotkey.fromParsed(v),
                else => error.TestUnexpectedResult,
            };
        }
    }.f;

    try std.testing.expectEqual(KeyAction.fullscreen, lookupAction(bindings, try hk("alt+return"), null).?);
    try std.testing.expectEqual(KeyAction.fullscreen_workarea, lookupAction(bindings, try hk("shift+alt+return"), null).?);
    try std.testing.expectEqual(KeyAction.switch_tab1, lookupAction(bindings, try hk("alt+1"), null).?);

    // Shift 가 더 붙은 조합은 **일치하지 않는다.** 완화 조회를 뺀 결과이고 의도된
    // 동작이다 — `shift+alt+f4` 가 `alt+f4` 를 발동시키는 일이 없다.
    try std.testing.expect(lookupAction(bindings, try hk("ctrl+alt+return"), null) == null);
    try std.testing.expect(lookupAction(bindings, try hk("shift+alt+return"), null).? == .fullscreen_workarea);

    // **숫자만 예외다** (#482). AZERTY 에서 숫자열은 Shift 를 눌러야 숫자가 나오므로
    // `Alt+1` 이 항상 `Alt+Shift+1` 로 도착한다. 이 예외가 없으면 세 platform 모두
    // 그 layout 에서 인덱스 탭 전환이 죽는다 — 세 host 가 이미 Shift 를 안 본다
    // (`isDigitBinding` 주석 참고). 확대가 아니라 현행 유지다.
    try std.testing.expect(lookupAction(bindings, try hk("shift+alt+1"), null).? == .switch_tab1);
    // 예외는 숫자에서 멈춘다 — 다른 키는 여전히 엄격하다.
    try add(&buf, &n, "alt+f4", .quit);
    const with_quit = buf[0..n];
    try std.testing.expect(lookupAction(with_quit, try hk("shift+alt+f4"), null) == null);
    try std.testing.expect(lookupAction(with_quit, try hk("alt+f4"), null).? == .quit);
}

test "#496 위치 binding 은 라벨과 무관하게 자리로 매칭한다" {
    const parse = struct {
        fn f(text: []const u8) !Hotkey {
            return switch (parseHotkeyString(text, .app_binding)) {
                .ok => |v| Hotkey.fromParsed(v),
                else => error.TestUnexpectedResult,
            };
        }
    }.f;

    var buf: [MAX_KEY_BINDINGS]KeyBinding = undefined;
    var n: usize = 0;
    // 라벨 binding 하나, 위치 binding 하나 — 한 조회가 둘 다 상대한다.
    buf[n] = .{ .hotkey = try parse("ctrl+shift+t"), .action = .new_tab };
    n += 1;
    buf[n] = .{ .hotkey = try parse("ctrl+shift+[KeyW]"), .action = .close_tab };
    n += 1;
    const bindings = buf[0..n];

    // 위치 binding 은 라벨을 보지 않는다. 키릴 layout 에서 그 자리를 누르면 라벨은
    // `ц` 라서 라벨 표현이 무엇이든 상관없이 자리로 잡혀야 한다 — 여기서는 라벨
    // 표현을 일부러 엉뚱한 것 (`ctrl+shift+f9`) 으로 주고 자리만 맞춘다.
    try std.testing.expectEqual(
        KeyAction.close_tab,
        lookupAction(bindings, try parse("ctrl+shift+f9"), .key_w).?,
    );
    // modifier 가 다르면 자리가 맞아도 매칭하지 않는다.
    try std.testing.expect(lookupAction(bindings, try parse("ctrl+f9"), .key_w) == null);
    // 자리를 모르는 event (표에 없는 키) 는 위치 binding 을 발동시키지 않는다.
    try std.testing.expect(lookupAction(bindings, try parse("ctrl+shift+f9"), null) == null);
    // 라벨 binding 은 자리 정보가 있어도 라벨로 판정한다 — 위치를 엉뚱하게 줘도
    // 라벨이 맞으면 잡힌다.
    try std.testing.expectEqual(
        KeyAction.new_tab,
        lookupAction(bindings, try parse("ctrl+shift+t"), .key_z).?,
    );
}

test "#496 macOS 에 값이 없는 자리는 그 platform 에서만 거부한다" {
    // 거부는 **platform 조건**이다. Linux / Windows 에서 `[PrintScreen]` 은 정상
    // 이므로, 한 config 를 세 OS 에서 쓰는 사용자는 macOS 에서만 안내를 받는다.
    if (is_macos) {
        try std.testing.expectEqual(
            HotkeyParse.position_aliased_on_macos,
            parseHotkeyString("ctrl+[PrintScreen]", .app_binding),
        );
        try std.testing.expectEqual(
            HotkeyParse.position_absent_on_macos,
            parseHotkeyString("ctrl+[F21]", .app_binding),
        );
        // 안내가 가리키는 대체 자리는 실제로 받아야 한다 — 그러지 않으면 막다른
        // 길이 된다 (#484).
        try std.testing.expect(parseHotkeyString("ctrl+[F13]", .app_binding) == .ok);

        // #496 1-c — **전역 `hotkey` scope 에서도 같은 거부가 난다.** 위치 표기를 받기
        // 시작하면서 생긴 경로이고, config 로드부는 이것을 `unreachable` 로 두고 있었다.
        // ReleaseFast 는 안전 검사가 없어 크래시 대신 `modifier_required` 안내로
        // 떨어졌고, `ctrl` 을 이미 준 사용자에게 "modifier 를 달라" 고 말했다 (macOS
        // 실기 확인). 여기서 고정해 두면 그 전제가 다시 깨질 때 테스트가 잡는다.
        try std.testing.expectEqual(
            HotkeyParse.position_aliased_on_macos,
            parseHotkeyString("ctrl+[PrintScreen]", .global_hotkey),
        );
        try std.testing.expectEqual(
            HotkeyParse.position_absent_on_macos,
            parseHotkeyString("ctrl+[F21]", .global_hotkey),
        );
        // config 로드부는 `parseHotkeyString` 이 아니라 `hotkeyFailure` 로 분기하므로
        // 그쪽도 같은 값을 내야 한다.
        try std.testing.expectEqual(
            HotkeyFailure.position_aliased_on_macos,
            hotkeyFailure("ctrl+[PrintScreen]").?,
        );
        try std.testing.expectEqual(
            HotkeyFailure.position_absent_on_macos,
            hotkeyFailure("ctrl+[F21]").?,
        );
    } else {
        try std.testing.expect(parseHotkeyString("ctrl+[PrintScreen]", .app_binding) == .ok);
        try std.testing.expect(parseHotkeyString("ctrl+[F21]", .app_binding) == .ok);
    }
    // 메뉴 키는 세 platform 모두 값이 있다 — 한 번 "macOS 에 없다" 고 적었던
    // 자리이므로 못을 박는다.
    try std.testing.expect(parseHotkeyString("ctrl+[ContextMenu]", .app_binding) == .ok);

    // 방향키 · 편집 패드는 글자를 내지 않지만 터미널로 escape sequence 를 보낸다.
    // modifier 없이 바인딩하면 TUI 앱에 그 키를 넘길 방법이 없어지므로 요구한다.
    try std.testing.expectEqual(HotkeyParse.modifier_required, parseHotkeyString("[ArrowUp]", .app_binding));
    try std.testing.expectEqual(HotkeyParse.modifier_required, parseHotkeyString("[Home]", .app_binding));
    try std.testing.expectEqual(HotkeyParse.modifier_required, parseHotkeyString("[Numpad5]", .app_binding));
    try std.testing.expect(parseHotkeyString("ctrl+[ArrowUp]", .app_binding) == .ok);
    // 기능 키 자리는 modifier 없이도 안전하다 (글자도 sequence 도 아니다).
    try std.testing.expect(parseHotkeyString("[F13]", .app_binding) == .ok);
    try std.testing.expect(parseHotkeyString("[NumLock]", .app_binding) == .ok);
}

test "#496 항목 2 — macOS 라벨 binding 은 이벤트가 낸 글자로 매칭한다" {
    // macOS 가 라벨 매칭으로 바뀐 뒤의 계약을 고정한다. 이 테스트가 없으면 "AZERTY
    // 에서 어느 키가 잡히는가" 가 실기로만 확인되고, 되돌아가도 조용하다.
    if (!is_macos) return;

    const parse = struct {
        fn f(text: []const u8) !Hotkey {
            return switch (parseHotkeyString(text, .app_binding)) {
                .ok => |v| Hotkey.fromParsed(v),
                else => error.TestUnexpectedResult,
            };
        }
    }.f;

    // (1) 라벨 binding 은 `label` 을 갖고 위치 binding 은 갖지 않는다.
    const label_w = try parse("cmd+w");
    try std.testing.expectEqual(@as(u32, 'w'), label_w.label);
    try std.testing.expectEqual(@as(?PhysicalCode, null), label_w.code);

    const position_w = try parse("cmd+[KeyW]");
    try std.testing.expectEqual(@as(u32, 0), position_w.label);
    try std.testing.expect(position_w.code != null);

    // (2) layout 무관 키는 라벨을 쓰지 않고, layout 에 따라 글자가 바뀌는 기호는 쓴다.
    try std.testing.expectEqual(@as(u32, 0), (try parse("cmd+f1")).label);
    try std.testing.expectEqual(@as(u32, 0), (try parse("cmd+space")).label);
    try std.testing.expectEqual(@as(u32, 0x60), (try parse("cmd+grave")).label);
    try std.testing.expectEqual(@as(u32, 0x5B), (try parse("cmd+[")).label);

    var buf: [MAX_KEY_BINDINGS]KeyBinding = undefined;
    buf[0] = .{ .hotkey = label_w, .action = .close_tab };
    const bindings = buf[0..1];

    const cmd = Hotkey.MOD_SUPER;
    const kvk_w: u32 = 0x0D; // kVK_ANSI_W — AZERTY 에서 `z` 를 낸다
    const kvk_z: u32 = 0x06; // kVK_ANSI_Z — AZERTY 에서 `w` 를 낸다

    // (3) AZERTY — `W` 라 인쇄된 키 (US `Z` 자리) 가 잡혀야 한다. Safari 와 같은 키다.
    try std.testing.expectEqual(@as(?KeyAction, .close_tab), lookupAction(
        bindings,
        .{ .keycode = kvk_z, .modifiers = cmd, .label = 'w' },
        physical_key.fromMacKeyCode(kvk_z),
    ));
    // (4) 같은 자판에서 US `W` 자리는 라벨이 `z` 라 잡히면 **안 된다** (예전 동작).
    try std.testing.expectEqual(@as(?KeyAction, null), lookupAction(
        bindings,
        .{ .keycode = kvk_w, .modifiers = cmd, .label = 'z' },
        physical_key.fromMacKeyCode(kvk_w),
    ));

    // (5) 라틴을 한 자도 못 내는 layout (키릴 · 한글) 은 fallback 후보를 갖는다.
    const candidate = fallbackCandidate(label_w) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 'w'), candidate.keysym);
    try std.testing.expectEqual(physical_key.fromName("KeyW").?, candidate.code);

    // (6) 그 fallback 이 켜지면 US `w` 자리가 잡힌다 — 한글에서 지금까지의 동작 그대로다.
    var fallbacks = [_]?PhysicalCode{candidate.code};
    try std.testing.expectEqual(@as(?KeyAction, .close_tab), lookupActionWithFallback(
        bindings,
        &fallbacks,
        .{ .keycode = kvk_w, .modifiers = cmd, .label = 0 },
        physical_key.fromMacKeyCode(kvk_w),
    ));
}

test "#496 physical_key 의 macOS 열이 keycodeFromKey 와 같다" {
    // `physical_key.zig` 의 `mac` 열과 `MacHotkey.keycodeFromKey` 는 **같은 US 위치
    // 표** 다. 두 곳에 값을 두는 것은 어쩔 수 없다 (한쪽은 라벨 → 위치, 한쪽은 위치
    // 이름 → 위치) — 그래서 갈라지지 않는다는 것을 여기서 고정한다. 표가 갈라지면
    // `[KeyW]` 와 라벨 `w` 가 macOS 에서 다른 키가 되고, 그 증상은 조용하다.
    var name_buf: [16]u8 = undefined;

    for ('a'..'z' + 1) |c| {
        const letter: u8 = @intCast(c);
        const name = std.fmt.bufPrint(&name_buf, "Key{c}", .{std.ascii.toUpper(letter)}) catch unreachable;
        const code = physical_key.fromName(name).?;
        try std.testing.expectEqual(
            MacHotkey.keycodeFromKey(.{ .char = letter }),
            @as(u32, physical_key.macKeyCode(code).?),
        );
    }
    for ('0'..'9' + 1) |c| {
        const digit: u8 = @intCast(c);
        const name = std.fmt.bufPrint(&name_buf, "Digit{c}", .{digit}) catch unreachable;
        const code = physical_key.fromName(name).?;
        try std.testing.expectEqual(
            MacHotkey.keycodeFromKey(.{ .char = digit }),
            @as(u32, physical_key.macKeyCode(code).?),
        );
    }

    const pairs = [_]struct { named: HotkeyNamedKey, code: PhysicalCode }{
        .{ .named = .f1, .code = .f1 },       .{ .named = .f2, .code = .f2 },
        .{ .named = .f3, .code = .f3 },       .{ .named = .f4, .code = .f4 },
        .{ .named = .f5, .code = .f5 },       .{ .named = .f6, .code = .f6 },
        .{ .named = .f7, .code = .f7 },       .{ .named = .f8, .code = .f8 },
        .{ .named = .f9, .code = .f9 },       .{ .named = .f10, .code = .f10 },
        .{ .named = .f11, .code = .f11 },     .{ .named = .f12, .code = .f12 },
        .{ .named = .space, .code = .space }, .{ .named = .tab, .code = .tab },
        .{ .named = .escape, .code = .escape },
        // 라벨은 `return`, W3C 이름은 `Enter` 다 — 같은 키다.
        .{ .named = .@"return", .code = .enter },
        .{ .named = .grave, .code = .backquote },
        .{ .named = .page_up, .code = .page_up },
        .{ .named = .page_down, .code = .page_down },
        .{ .named = .bracket_left, .code = .bracket_left },
        .{ .named = .bracket_right, .code = .bracket_right },
    };
    for (pairs) |pair| {
        try std.testing.expectEqual(
            MacHotkey.keycodeFromKey(.{ .named = pair.named }),
            @as(u32, physical_key.macKeyCode(pair.code).?),
        );
    }
    // `pairs` 가 named 라벨을 **빠짐없이** 덮어야 한다. 라벨을 하나 더하면 여기서
    // 걸리고, 그때 위 표에 대응 위치를 적어야 한다.
    try std.testing.expectEqual(@typeInfo(HotkeyNamedKey).@"enum".fields.len, pairs.len);
    // 방향은 한쪽뿐이다 — **모든 라벨에는 위치가 있지만 그 반대는 아니다.** 위치
    // 집합이 더 넓다: 라벨이 거부하는 ASCII 기호 자리와 ISO 추가 키를 담는다
    // (`physical_key.zig` 의 정책 문단 참고). 그래서 등호가 아니라 부등호다.
    try std.testing.expect(
        @typeInfo(PhysicalCode).@"enum".fields.len >= pairs.len + 26 + 10,
    );
}

test "#496 위치 표기 파싱" {
    // 대괄호 안은 W3C `KeyboardEvent.code` 이름이고 대소문자 무관이다.
    try std.testing.expect(parseHotkeyString("ctrl+shift+[KeyW]", .app_binding) == .ok);
    try std.testing.expect(parseHotkeyString("ctrl+shift+[keyw]", .app_binding) == .ok);
    try std.testing.expect(parseHotkeyString("ctrl+[BracketLeft]", .app_binding) == .ok);
    try std.testing.expect(parseHotkeyString("[F5]", .app_binding) == .ok);

    // 1 자 `[` 는 여전히 **라벨**이다 — 표기가 겹쳐 보이지만 길이로 갈린다.
    const label = switch (parseHotkeyString("ctrl+shift+[", .app_binding)) {
        .ok => |v| v,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(label.key == .named);
    try std.testing.expectEqual(HotkeyNamedKey.bracket_left, label.key.named);

    const position = switch (parseHotkeyString("ctrl+shift+[BracketLeft]", .app_binding)) {
        .ok => |v| v,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(position.key == .code);
    try std.testing.expectEqual(PhysicalCode.bracket_left, position.key.code);

    // 라벨이 거부하는 기호 자리도 **위치로는 받는다** — 자판에 있는 키를 다 쓸 수
    // 있게 한 결정이다 (`physical_key.zig` 의 정책 문단). 라벨 쪽은 그대로 좁다:
    // 고정표로 라벨을 넓히면 그건 라벨이 아니라 US 위치가 되기 때문이다.
    try std.testing.expect(parseHotkeyString("ctrl+[Minus]", .app_binding) == .ok);
    try std.testing.expect(parseHotkeyString("ctrl+[Slash]", .app_binding) == .ok);
    try std.testing.expect(parseHotkeyString("ctrl+[IntlBackslash]", .app_binding) == .ok);
    try std.testing.expectEqual(HotkeyParse.unknown_key, parseHotkeyString("ctrl+minus", .app_binding));
    try std.testing.expectEqual(HotkeyParse.unknown_key, parseHotkeyString("ctrl+slash", .app_binding));
    // 표에 없는 이름은 여전히 거부한다.
    try std.testing.expectEqual(HotkeyParse.unknown_key, parseHotkeyString("ctrl+[NotAKey]", .app_binding));
    try std.testing.expectEqual(HotkeyParse.unknown_key, parseHotkeyString("ctrl+[]", .app_binding));

    // 글자를 내는 자리는 modifier 가 필요하고, 내지 않는 자리는 필요 없다 — 라벨과
    // 같은 기준이다.
    try std.testing.expectEqual(HotkeyParse.modifier_required, parseHotkeyString("[KeyW]", .app_binding));
    try std.testing.expectEqual(HotkeyParse.modifier_required, parseHotkeyString("shift+[KeyW]", .app_binding));
    try std.testing.expect(parseHotkeyString("[PageUp]", .app_binding) == .ok);
    try std.testing.expect(parseHotkeyString("shift+[PageUp]", .app_binding) == .ok);

    // #496 1-c — 전역 `hotkey` 도 위치를 받는다.
    try std.testing.expect(parseHotkeyString("ctrl+[KeyW]", .global_hotkey) == .ok);
    try std.testing.expectEqual(@as(?HotkeyFailure, null), hotkeyFailure("ctrl+[KeyW]"));
    try std.testing.expect(Hotkey.fromString("ctrl+[KeyW]") != null);

    // modifier 없이 받는 것은 함수 키 자리뿐이다 — 라벨 규칙과 짝이다.
    try std.testing.expect(parseHotkeyString("[F1]", .global_hotkey) == .ok);
    try std.testing.expect(parseHotkeyString("[F13]", .global_hotkey) == .ok);
    try std.testing.expectEqual(
        HotkeyParse.modifier_required,
        parseHotkeyString("[KeyW]", .global_hotkey),
    );
    try std.testing.expectEqual(
        HotkeyParse.modifier_required,
        parseHotkeyString("shift+[Backquote]", .global_hotkey),
    );
}

test "#493 default [keys] has no conflicting bindings" {
    // 액션 → 키 방향을 택한 대가로 충돌 감지가 우리 몫이다 (키 → 액션이면 TOML 이
    // 중복 키로 잡아 준다). 기본값끼리 충돌하면 첫 실행부터 fatal 이므로 고정한다.
    var seen: [MAX_KEY_BINDINGS]KeyBinding = undefined;
    var count: usize = 0;
    for (std.enums.values(KeyAction)) |action| {
        for (defaultBindings(action)) |text| {
            const parsed = switch (parseHotkeyString(text, .app_binding)) {
                .ok => |v| v,
                else => return error.TestUnexpectedResult,
            };
            const hk = Hotkey.fromParsed(parsed);
            for (seen[0..count]) |prev| {
                if (std.meta.eql(prev.hotkey, hk)) {
                    std.debug.print("기본 binding 충돌: \"{s}\" — {s} vs {s}\n", .{ text, prev.action.configName(), action.configName() });
                    return error.TestUnexpectedResult;
                }
            }
            try std.testing.expect(count < MAX_KEY_BINDINGS);
            seen[count] = .{ .hotkey = hk, .action = action };
            count += 1;
        }
    }
    // 액션 23 개 + prev_tab / next_tab 이 2 개씩 = 25.
    try std.testing.expectEqual(@as(usize, 25), count);
}

test "#493 generated config carries every action so none is silently missing" {
    const allocator = std.testing.allocator;
    const doc = try schemaReferenceToml(allocator);
    defer allocator.free(doc);

    // "모든 액션을 항상 파일에 적는다" 가 결정 3 이다. 하나라도 빠지면 사용자가
    // 읽어서 발견하거나 바꿀 수 없다.
    for (std.enums.values(KeyAction)) |action| {
        const name = action.configName();
        if (std.mem.find(u8, doc, name) == null) {
            std.debug.print("생성된 config 에 액션이 없음: {s}\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(std.mem.find(u8, doc, "[keys]") != null);
    // `[keys]` 는 테이블이라 최상위 스칼라보다 뒤에 와야 한다.
    try std.testing.expect(std.mem.find(u8, doc, "max_scroll_lines").? < std.mem.find(u8, doc, "[keys]").?);
}

test "hotkey rejection reports the cause, not one blanket message" {
    // #484 — 원인이 둘인데 메시지가 하나여서 `ctrl+twosuperior` 처럼 **이미 modifier 가
    // 있는** 값에도 "modifier 를 달라" 고 안내했다. 신고자는 modifier 를 더해 보고도
    // 같은 안내를 다시 받아 실제 원인을 알 수 없었다.

    // 모르는 key 이름 — modifier 유무와 무관하게 `unknown_key` 다.
    try std.testing.expectEqual(HotkeyFailure.unknown_key, hotkeyFailure("twosuperior").?);
    try std.testing.expectEqual(HotkeyFailure.unknown_key, hotkeyFailure("ctrl+twosuperior").?);
    try std.testing.expectEqual(HotkeyFailure.unknown_key, hotkeyFailure("ctrl+minus").?);
    try std.testing.expectEqual(HotkeyFailure.unknown_key, hotkeyFailure("ctrl+shift+f13").?);
    // key 토큰이 아예 없는 경우도 같은 안내를 받아야 한다 (받는 key 목록).
    try std.testing.expectEqual(HotkeyFailure.unknown_key, hotkeyFailure("ctrl").?);
    try std.testing.expectEqual(HotkeyFailure.unknown_key, hotkeyFailure("ctrl+shift").?);

    // key 는 유효하지만 modifier 없이 전역 등록할 수 없는 경우 — 기존 안내가 맞다.
    try std.testing.expectEqual(HotkeyFailure.modifier_required, hotkeyFailure("t").?);
    try std.testing.expectEqual(HotkeyFailure.modifier_required, hotkeyFailure("shift+t").?);
    try std.testing.expectEqual(HotkeyFailure.modifier_required, hotkeyFailure("space").?);
    try std.testing.expectEqual(HotkeyFailure.modifier_required, hotkeyFailure("grave").?);
    try std.testing.expectEqual(HotkeyFailure.modifier_required, hotkeyFailure("5").?);

    // 통과하는 값은 실패 이유가 없다 — `fromString` 과 판정이 갈리지 않는지 함께 본다.
    const accepted = [_][]const u8{ "f1", "f12", "ctrl+space", "shift+cmd+t", "super+grave", "alt+3" };
    for (accepted) |text| {
        try std.testing.expect(hotkeyFailure(text) == null);
        try std.testing.expect(Hotkey.fromString(text) != null);
    }

    // 거부되는 값은 반드시 이유가 있다 (둘의 판정이 어긋나면 메시지가 사라진다).
    const rejected = [_][]const u8{ "twosuperior", "ctrl+minus", "t", "shift+t", "ctrl", "" };
    for (rejected) |text| {
        try std.testing.expect(Hotkey.fromString(text) == null);
        try std.testing.expect(hotkeyFailure(text) != null);
    }
}

// 파서 3벌은 OS API 비의존 순수 로직이라 어느 테스트 호스트에서도 세 OS 분을
// 전부 검증할 수 있다 (#294 G1).

test "hotkey 문법·alias 는 세 OS 파서가 동일 수용 (#294 G1)" {
    const accepted = [_][]const u8{
        "F1",               "f12",          "ctrl+space",     "Ctrl+Shift+T",
        "alt+f12",          "super+a",      "win+z",          "cmd+grave",
        "option+space",     "opt+space",    "meta+f1",        "command+t",
        "logo+1",           "ctrl+`",       "ctrl+backquote", "CTRL+SHIFT+F12",
        "Ctrl + Shift + G", "shift+f5",     "ctrl+enter",     "alt+Return",
        "ctrl+esc",         "super+Escape", "ctrl+tab",       "alt+0",
    };
    for (accepted) |s| {
        try std.testing.expect(LinuxHotkey.fromString(s) != null);
        try std.testing.expect(WindowsHotkey.fromString(s) != null);
        try std.testing.expect(MacHotkey.fromString(s) != null);
    }
    const rejected = [_][]const u8{
        "",        "t",           "3",         "space",      "grave",  "`",
        "shift+t", "shift+space", "ctrl",      "ctrl+shift", "ctrl+~", "ctrl+=",
        "ctrl+-",  "ctrl+f13",    "ctrl+nope",
    };
    for (rejected) |s| {
        try std.testing.expect(LinuxHotkey.fromString(s) == null);
        try std.testing.expect(WindowsHotkey.fromString(s) == null);
        try std.testing.expect(MacHotkey.fromString(s) == null);
    }
}

test "hotkey 파싱 — OS 코드 값 매핑 (#294 G1)" {
    const lh = LinuxHotkey.fromString("Ctrl+Shift+F2").?;
    try std.testing.expectEqual(@as(u32, 0xffbf), lh.keysym);
    try std.testing.expectEqual(LinuxHotkey.MOD_CTRL | LinuxHotkey.MOD_SHIFT, lh.modifiers);

    const wh = WindowsHotkey.fromString("Ctrl+Shift+F2").?;
    try std.testing.expectEqual(@as(u32, 0x71), wh.vkey);
    try std.testing.expectEqual(@as(u32, 0x2 | 0x4), wh.modifiers);

    const mh = MacHotkey.fromString("Ctrl+Shift+F2").?;
    try std.testing.expectEqual(@as(u32, 0x78), mh.keycode);
    try std.testing.expectEqual(@as(u64, 0x00040000 | 0x00020000), mh.modifiers);

    // grave 세 표기 (`grave` / `backquote` / literal backtick) 는 같은 코드로 수렴
    const grave_variants = [_][]const u8{ "ctrl+grave", "ctrl+backquote", "ctrl+`" };
    for (grave_variants) |s| {
        try std.testing.expectEqual(@as(u32, 0x0060), LinuxHotkey.fromString(s).?.keysym);
        try std.testing.expectEqual(@as(u32, 0xC0), WindowsHotkey.fromString(s).?.vkey);
        try std.testing.expectEqual(@as(u32, 0x32), MacHotkey.fromString(s).?.keycode);
    }

    // letter 대소문자 정규화 — Linux 소문자 keysym / Windows 대문자 vkey / mac kVK
    for ([_][]const u8{ "ctrl+t", "ctrl+T" }) |s| {
        try std.testing.expectEqual(@as(u32, 't'), LinuxHotkey.fromString(s).?.keysym);
        try std.testing.expectEqual(@as(u32, 'T'), WindowsHotkey.fromString(s).?.vkey);
        try std.testing.expectEqual(@as(u32, 0x11), MacHotkey.fromString(s).?.keycode);
    }

    // Super alias 6종 → 같은 modifier 비트
    const super_aliases = [_][]const u8{ "win+a", "super+a", "cmd+a", "meta+a", "command+a", "logo+a" };
    for (super_aliases) |s| {
        try std.testing.expectEqual(LinuxHotkey.MOD_SUPER, LinuxHotkey.fromString(s).?.modifiers);
        try std.testing.expectEqual(@as(u32, 0x8), WindowsHotkey.fromString(s).?.modifiers);
        try std.testing.expectEqual(@as(u64, 0x00100000), MacHotkey.fromString(s).?.modifiers);
    }
}

const WindowsHotkey = struct {
    vkey: u32 = 0x70, // VK_F1
    modifiers: u32 = 0,

    /// #496 — non-null 이면 이 binding 은 **물리 위치**로 매칭한다 (`[KeyW]`).
    /// 그때 라벨 쪽 값 (`vkey`) 은 의미가 없다. `lookupAction` 이 이 필드로
    /// 어느 기준을 볼지 고른다 — 두 기준을 한 값에 눌러 담을 수 없어서 (같은
    /// event 가 라벨 binding 과 위치 binding 에 동시에 걸려야 한다) 필드를 나눈다.
    code: ?PhysicalCode = null,

    pub fn fromString(s: []const u8) ?WindowsHotkey {
        const parsed = switch (parseHotkeyString(s, .global_hotkey)) {
            .ok => |p| p,
            else => return null,
        };
        return fromParsed(parsed);
    }

    /// `RegisterHotKey` 의 modifier 비트. #493 3-c 의 `lookupAction` 이 platform 과
    /// 무관하게 `Hotkey.MOD_SHIFT` 를 참조하므로 세 타입이 같은 이름을 갖는다.
    pub const MOD_ALT: u32 = 0x1;
    pub const MOD_CTRL: u32 = 0x2;
    pub const MOD_SHIFT: u32 = 0x4;
    pub const MOD_SUPER: u32 = 0x8;

    pub fn fromParsed(parsed: ParsedHotkey) WindowsHotkey {
        var modifiers: u32 = 0;
        if (parsed.alt) modifiers |= MOD_ALT;
        if (parsed.ctrl) modifiers |= MOD_CTRL;
        if (parsed.shift) modifiers |= MOD_SHIFT;
        if (parsed.super) modifiers |= MOD_SUPER;
        return .{
            .vkey = vkeyFromKey(parsed.key),
            .modifiers = modifiers,
            .code = if (parsed.key == .code) parsed.key.code else null,
        };
    }

    /// 정규화된 key → virtual-key code. letter / digit 은 대문자 ASCII 값
    /// 그대로 vkey (`VK_A`..`VK_Z` = 'A'..'Z', `VK_0`..`VK_9` = '0'..'9').
    fn vkeyFromKey(key: HotkeyKeyToken) u32 {
        return switch (key) {
            .char => |c| std.ascii.toUpper(c),
            // 위치 binding 은 scan code 로 매칭한다 — `code` 필드가 기준이고 vkey 는
            // 보지 않는다. 0 은 유효한 virtual-key 가 아니라 sentinel 로 안전하다.
            .code => 0,
            .named => |n| switch (n) {
                .f1 => 0x70,
                .f2 => 0x71,
                .f3 => 0x72,
                .f4 => 0x73,
                .f5 => 0x74,
                .f6 => 0x75,
                .f7 => 0x76,
                .f8 => 0x77,
                .f9 => 0x78,
                .f10 => 0x79,
                .f11 => 0x7A,
                .f12 => 0x7B,
                .space => 0x20,
                .grave => 0xC0, // VK_OEM_3
                .tab => 0x09,
                .escape => 0x1B,
                .@"return" => 0x0D,
                // #493 — `VK_PRIOR` / `VK_NEXT`. #482 의 `wndProc` 이 쓰는 값과 같다.
                .page_up => 0x21,
                .page_down => 0x22,
                // `VK_OEM_4` / `VK_OEM_6`. `window.zig` 의 prev/next tab 이 쓰는 값.
                .bracket_left => 0xDB,
                .bracket_right => 0xDD,
            },
        };
    }
};

fn windowsVkeyName(vkey: u32) ?[]const u8 {
    return switch (vkey) {
        0x70 => "F1",
        0x71 => "F2",
        0x72 => "F3",
        0x73 => "F4",
        0x74 => "F5",
        0x75 => "F6",
        0x76 => "F7",
        0x77 => "F8",
        0x78 => "F9",
        0x79 => "F10",
        0x7A => "F11",
        0x7B => "F12",
        0x20 => "space",
        0xC0 => "grave",
        0x09 => "Tab",
        0x0D => "Return",
        0x1B => "Escape",
        'A'...'Z', '0'...'9' => &windows_single_char_lookup[vkey - '0'],
        else => null,
    };
}

const windows_single_char_lookup = blk: {
    var table: ['Z' - '0' + 1][1]u8 = undefined;
    for ('0'..'Z' + 1) |value| table[value - '0'][0] = @intCast(value);
    break :blk table;
};

const MacHotkey = struct {
    /// `kVK_*` (Carbon Events.h). 우리는 macOS Tahoe + Carbon 못 써 직접 매핑.
    keycode: u32 = 0x7A, // kVK_F1
    /// CGEventFlags (`kCGEventFlagMask*`). u64 — bit 16..23 사용.
    modifiers: u64 = 0,

    /// #496 — non-null 이면 이 binding 은 **물리 위치**로 매칭한다 (`[KeyW]`).
    /// 그때 라벨 쪽 값 (`keycode`) 은 의미가 없다. `lookupAction` 이 이 필드로
    /// 어느 기준을 볼지 고른다 — 두 기준을 한 값에 눌러 담을 수 없어서 (같은
    /// event 가 라벨 binding 과 위치 binding 에 동시에 걸려야 한다) 필드를 나눈다.
    code: ?PhysicalCode = null,

    /// #496 항목 2 — **라벨** binding 이 기다리는 글자 (유니코드 코드포인트).
    /// `0` 은 "라벨로 매칭하지 않는다" 는 뜻이고, 그때는 `keycode` 로 매칭한다.
    ///
    /// 이 필드가 없던 시절 macOS 는 라벨 binding (`w`) 도 `keycode` (= US 위치)
    /// 로 저장했다. 그래서 AZERTY 에서 `Cmd+W` 가 `Z` 라 인쇄된 키였다 — 비교할
    /// 라벨 값 자체가 없었던 것이 원인이다.
    ///
    /// **layout 에 따라 글자가 바뀌는 키만** 채운다:
    ///   - 글자 · 숫자 (`w` · `1`)
    ///   - `` ` `` · `[` · `]` — AZERTY 에서 `<` · `^` · `$` 로 바뀐다 (실측)
    /// `F1` · `space` 처럼 어느 자판에나 같은 자리에 있는 키는 `0` 이다. 그런 키에
    /// 라벨 매칭을 쓰면 `NSEvent` 의 private codepoint (`0xF700`~) 에 기대게 되어
    /// 이득 없이 취약해진다.
    label: u32 = 0,

    pub fn fromString(s: []const u8) ?MacHotkey {
        const parsed = switch (parseHotkeyString(s, .global_hotkey)) {
            .ok => |p| p,
            else => return null,
        };
        return fromParsed(parsed);
    }

    /// `kCGEventFlagMask*`. #493 3-c 의 `lookupAction` 이 platform 과 무관하게
    /// `Hotkey.MOD_SHIFT` 를 참조하므로 세 타입이 같은 이름을 갖는다.
    pub const MOD_SHIFT: u64 = 0x00020000;
    pub const MOD_CTRL: u64 = 0x00040000;
    pub const MOD_ALT: u64 = 0x00080000;
    pub const MOD_SUPER: u64 = 0x00100000;

    pub fn fromParsed(parsed: ParsedHotkey) MacHotkey {
        var modifiers: u64 = 0;
        if (parsed.shift) modifiers |= MOD_SHIFT;
        if (parsed.ctrl) modifiers |= MOD_CTRL;
        if (parsed.alt) modifiers |= MOD_ALT;
        if (parsed.super) modifiers |= MOD_SUPER;
        return .{
            .keycode = keycodeFromKey(parsed.key),
            .modifiers = modifiers,
            .code = if (parsed.key == .code) parsed.key.code else null,
            .label = labelFromKey(parsed.key),
        };
    }

    /// 정규화된 key → **라벨** (유니코드 코드포인트). `0` = 라벨 매칭 안 함.
    /// 무엇을 채우고 무엇을 비우는지는 `label` 필드 주석에 있다.
    fn labelFromKey(key: HotkeyKeyToken) u32 {
        return switch (key) {
            // 위치 표기는 라벨과 무관하다 — `code` 필드가 매칭을 맡는다.
            .code => 0,
            // parseHotkeyString 의 char 는 소문자 letter / digit 만이라 그대로 쓴다.
            .char => |c| c,
            .named => |n| switch (n) {
                .grave => 0x60,
                .bracket_left => 0x5B,
                .bracket_right => 0x5D,
                // 나머지는 layout 무관 — keycode 로 매칭한다.
                .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => 0,
                .space, .tab, .escape, .@"return", .page_up, .page_down => 0,
            },
        };
    }

    /// 정규화된 key → `kVK_*` keycode.
    fn keycodeFromKey(key: HotkeyKeyToken) u32 {
        return switch (key) {
            // macOS 는 `keycode` 자체가 물리 위치라 위치 binding 도 같은 표현이 된다
            // — sentinel 이 필요 없다. 그래서 라벨 `w` 와 `[KeyW]` 가 이 platform 에서
            // 완전히 같은 값을 낸다 (#496 항목 2 의 뿌리이기도 하다: 라벨 쪽이 live
            // layout 을 보지 않고 US 위치를 준다).
            // 파싱이 `availableOnThisPlatform` 으로 이미 거부했으므로 macOS 에서
            // null 이 여기 도달할 수 없다. 조용히 0 을 쓰면 #208 이 막던 silent
            // failure 로 되돌아가므로 값을 꾸미지 않는다.
            .code => |c| physical_key.macKeyCode(c) orelse unreachable,
            .named => |n| switch (n) {
                .f1 => 0x7A,
                .f2 => 0x78,
                .f3 => 0x63,
                .f4 => 0x76,
                .f5 => 0x60,
                .f6 => 0x61,
                .f7 => 0x62,
                .f8 => 0x64,
                .f9 => 0x65,
                .f10 => 0x6D,
                .f11 => 0x67,
                .f12 => 0x6F,
                .space => 0x31,
                .grave => 0x32,
                .tab => 0x30,
                .escape => 0x35,
                .@"return" => 0x24,
                // #493 — `kVK_PageUp` / `kVK_PageDown`. #482 의 `host/macos.zig` 가
                // 쓰는 값과 같다 (116 / 121 십진).
                .page_up => 0x74,
                .page_down => 0x79,
                // `kVK_ANSI_LeftBracket` / `..RightBracket`. `host/macos.zig` 의
                // prev/next tab 이 쓰는 값.
                .bracket_left => 0x21,
                .bracket_right => 0x1E,
            },
            // kVK_ANSI_* — parseHotkeyString 의 char 는 소문자 letter / digit 만.
            .char => |c| switch (c) {
                'a' => 0x00,
                'b' => 0x0B,
                'c' => 0x08,
                'd' => 0x02,
                'e' => 0x0E,
                'f' => 0x03,
                'g' => 0x05,
                'h' => 0x04,
                'i' => 0x22,
                'j' => 0x26,
                'k' => 0x28,
                'l' => 0x25,
                'm' => 0x2E,
                'n' => 0x2D,
                'o' => 0x1F,
                'p' => 0x23,
                'q' => 0x0C,
                'r' => 0x0F,
                's' => 0x01,
                't' => 0x11,
                'u' => 0x20,
                'v' => 0x09,
                'w' => 0x0D,
                'x' => 0x07,
                'y' => 0x10,
                'z' => 0x06,
                '1' => 0x12,
                '2' => 0x13,
                '3' => 0x14,
                '4' => 0x15,
                '5' => 0x17,
                '6' => 0x16,
                '7' => 0x1A,
                '8' => 0x1C,
                '9' => 0x19,
                '0' => 0x1D,
                else => unreachable,
            },
        };
    }
};

fn macKeycodeName(keycode: u32) ?[]const u8 {
    const map = [_]struct { code: u32, name: []const u8 }{
        .{ .code = 0x7A, .name = "F1" },     .{ .code = 0x78, .name = "F2" },
        .{ .code = 0x63, .name = "F3" },     .{ .code = 0x76, .name = "F4" },
        .{ .code = 0x60, .name = "F5" },     .{ .code = 0x61, .name = "F6" },
        .{ .code = 0x62, .name = "F7" },     .{ .code = 0x64, .name = "F8" },
        .{ .code = 0x65, .name = "F9" },     .{ .code = 0x6D, .name = "F10" },
        .{ .code = 0x67, .name = "F11" },    .{ .code = 0x6F, .name = "F12" },
        .{ .code = 0x31, .name = "space" },  .{ .code = 0x32, .name = "grave" },
        .{ .code = 0x30, .name = "Tab" },    .{ .code = 0x24, .name = "Return" },
        .{ .code = 0x35, .name = "Escape" }, .{ .code = 0x00, .name = "A" },
        .{ .code = 0x0B, .name = "B" },      .{ .code = 0x08, .name = "C" },
        .{ .code = 0x02, .name = "D" },      .{ .code = 0x0E, .name = "E" },
        .{ .code = 0x03, .name = "F" },      .{ .code = 0x05, .name = "G" },
        .{ .code = 0x04, .name = "H" },      .{ .code = 0x22, .name = "I" },
        .{ .code = 0x26, .name = "J" },      .{ .code = 0x28, .name = "K" },
        .{ .code = 0x25, .name = "L" },      .{ .code = 0x2E, .name = "M" },
        .{ .code = 0x2D, .name = "N" },      .{ .code = 0x1F, .name = "O" },
        .{ .code = 0x23, .name = "P" },      .{ .code = 0x0C, .name = "Q" },
        .{ .code = 0x0F, .name = "R" },      .{ .code = 0x01, .name = "S" },
        .{ .code = 0x11, .name = "T" },      .{ .code = 0x20, .name = "U" },
        .{ .code = 0x09, .name = "V" },      .{ .code = 0x0D, .name = "W" },
        .{ .code = 0x07, .name = "X" },      .{ .code = 0x10, .name = "Y" },
        .{ .code = 0x06, .name = "Z" },      .{ .code = 0x12, .name = "1" },
        .{ .code = 0x13, .name = "2" },      .{ .code = 0x14, .name = "3" },
        .{ .code = 0x15, .name = "4" },      .{ .code = 0x17, .name = "5" },
        .{ .code = 0x16, .name = "6" },      .{ .code = 0x1A, .name = "7" },
        .{ .code = 0x1C, .name = "8" },      .{ .code = 0x19, .name = "9" },
        .{ .code = 0x1D, .name = "0" },
    };
    for (map) |entry| if (entry.code == keycode) return entry.name;
    return null;
}

fn eqIc(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// =============================================================================
// Defaults — config 의 *모든* default 값 단일 source of truth.
//
// Win 과 Mac 에서 schema (키 set / 중첩 구조 / value type) 는 동일하고 *값* 만
// 일부 OS-specific (font.family / font.size / cell_width / line_height /
// shell). 두 OS 의 default 를 같은 struct 의 if-else 분기 + 같은 필드 순서로
// 나란히 두어서 한눈에 비교 / 편집 가능.
//
// 이 한 곳만 고치면:
//   (a) `defaultConfigToml(alloc, shell_resolved)` — Defaults 값 그대로 TOML
//       템플릿 생성. 첫 실행 시 디스크의 `config_0.json`
//       에 저장됨 + parse() 의 `validateStructure` 가 schema 검증 ground
//       truth 로 사용. shell 만 host 가 첫 실행 시점에 resolveShell 로 결정해
//       인자로 전달 (Windows 는 항상 Defaults.shell, macOS 는 $SHELL 우선).
//   (b) `Config` struct 의 field initializer 가 참조하는 `default_*` const 도
//       모두 같은 Defaults 에서 derive — disk 와 memory 가 자동 sync.
//
// 이전엔 JSON literal + `DEFAULT_FONT_FAMILIES` + `default_font_size` /
// `default_shell` 등 6+ 곳에 default 값이 흩어져 한쪽만 고치면 disk vs memory
// default 가 어긋나는 잠재 버그.
// =============================================================================

/// 세 platform 의 첫-실행 default. 같은 shape struct 라 OS 별 sub-struct 셋을
/// 분리하면 공통 값 (dock_position, width_percent, opacity_percent, theme,
/// hotkey, max_scroll_lines, ...) 까지 다 중복됨. 단일 struct + OS 별로 *진짜*
/// 다른 항목만 `if/else` 인라인.
pub const Defaults = struct {
    pub const dock_position: []const u8 = "top";
    /// percent (0..100). 실수 — 사용자 세밀 조정용 (예: 33.3, 66.7).
    pub const width_percent: f32 = 50.0;
    pub const height_percent: f32 = 100.0;
    pub const offset_percent: f32 = 100.0;
    /// JSON 은 0..100 percent (실수). 메모리 alpha (0..255 u8) 변환은
    /// default_opacity_alpha 가 처리.
    pub const opacity_percent: f32 = 100.0;
    /// cell width *ratio* — 측정된 advance 에 곱해 글자 사이 padding 조절.
    /// 1.0 = 폰트 그대로, 1.1 = 10% 더 넓음. 세 platform 공통.
    pub const cell_width_ratio: f32 = 1.0;
    /// #533 — macOS 표준을 기본으로 둔다. Option 으로 특수문자를 쓰던 사용자가
    /// 업그레이드로 그것을 잃지 않게 한다. Linux · Windows 에서는 읽히지 않는다.
    pub const macos_option_as_alt: []const u8 = "none";
    pub const theme: []const u8 = "Tilda";
    pub const auto_start: bool = true;
    pub const hidden_start: bool = false;
    /// 100,000 은 다른 터미널의 10~100 배였다 (#425 조사 — 2 위 alacritty · GNOME Terminal
    /// 이 10,000 이고 중앙값은 1,000~2,000, 우리가 자리를 물려받은 Tilda 는 5,000). 그 값이
    /// `cols=120` 에서 130.5 MiB 라 앱의 `parse` 시간이 1.82 배 · `yields` 가 0 → 86 만이
    /// 됐다 (실측). 활성 작업집합이 캐시를 넘어서 생기는 비용이고 (`instructions` 는 같은데
    /// `cache-misses` 4,341 배) 로직 최적화로는 줄지 않는다. 최상위권 (ghostty 10 MB ·
    /// Windows Terminal 9,001 · GNOME Terminal · alacritty 10,000) 에 맞춘다.
    pub const max_scroll_lines: u32 = 10_000;

    /// Primary font — 단일 string. 시스템에 반드시 설치돼 있어야 함 (없으면
    /// startup 시 fatal). Windows: Cascadia Code (Win10 22H2+ / Win11 기본).
    /// macOS: Menlo (OS X 10.6+ 기본). Linux: DejaVu Sans Mono (Debian /
    /// Ubuntu / Fedora / Arch 거의 기본).
    pub const font_family: []const u8 = if (is_windows)
        "Cascadia Code"
    else if (is_macos)
        "Menlo"
    else
        "DejaVu Sans Mono";

    /// Glyph fallback chain — primary 에 글리프 없을 때 순서대로 lookup. 모두
    /// 시스템에 설치돼 있어야 함 (없으면 fatal). 한글 → 이모지 → 심볼 패턴.
    pub const glyph_fallback: []const []const u8 = if (is_windows)
        &.{ "Malgun Gothic", "Segoe UI Emoji", "Segoe UI Symbol" }
    else if (is_macos)
        &.{ "Apple SD Gothic Neo", "Apple Color Emoji", "Apple Symbols" }
    else
        &.{ "Noto Sans CJK KR", "Noto Color Emoji" };

    /// Logical font size. host 가 OS scale 을 곱한 후 raster.
    /// Linux · macOS · Windows 공통 기본값.
    /// Linux 12 / 14 는 KDE 170% fractional scale 에서 "너무 작다" 보고.
    pub const font_size_point: u8 = 15;

    /// line height ratio — 측정된 ascent+descent+leading 에 곱해 줄 높이
    /// 조절. Linux · macOS · Windows 공통 기본값.
    pub const line_height_ratio: f32 = 1.1;

    /// host 의 `resolveShell` 이 `$SHELL` env 가 비어있을 때 쓰는 fallback.
    /// 첫 실행 시 host 는 `$SHELL` (있으면) 또는 이 값을 disk JSON 에 명시.
    /// Windows 는 POSIX `$SHELL` 컨벤션 없어 무조건 cmd.exe.
    pub const shell: []const u8 = if (is_windows) "cmd.exe" else "/bin/bash";

    /// **instance N 의 기본 전역 핫키는 `F(N+1)`** ([#510](https://github.com/ensky0/tildaz/issues/510)).
    /// index 0 → `F1`, 1 → `F2`, … 9 → `F10`.
    ///
    /// 예전에는 index 와 무관한 상수 하나 (`"F1"`) 였다. config 경로 (`config_N.toml`)
    /// 와 로그 경로 (`tildaz_N.log`) 는 이미 index 파생인데 **인스턴스마다 고유해야 하는
    /// 자원 중 핫키만 상수**였다. 그래서 `tildaz --instance 1` 을 config 없이 띄우면
    /// config_0 과 **같은 `F1`** 이 적힌 파일이 생겼고, Windows 실기에서 `RegisterHotKey`
    /// 가 실패해 **앱이 아예 안 떴다** (#510).
    ///
    /// **예외 분기가 없다.** 상한이 `instances.max_config_index` (= 9) 라 index 10 은
    /// 존재할 수 없고, 표가 그 상한을 덮으므로 "핫키 없는 instance" 라는 상태 자체가
    /// 생기지 않는다. 규칙이 이 한 줄로 끝난다.
    ///
    /// **표를 `F12` 까지 채우지 않는 이유는 Windows 다.** modifier 없는 `F12` 는 전역
    /// 핫키로 등록되지 않아서 (`ERROR_HOTKEY_ALREADY_REGISTERED` — 커널 디버거가 쥐고
    /// 있다) 그 칸을 쓰면 그 index 가 기본 config 로 뜨지 못한다. 근거와 실측은
    /// `instances.max_config_index` 주석에 있다.
    ///
    /// 새로 **만드는** 파일에만 적용된다 — 이미 있는 config 는 읽은 값 그대로다.
    pub fn hotkeyFor(index: u32) []const u8 {
        std.debug.assert(index < index_hotkeys.len);
        return index_hotkeys[index];
    }

    /// 상한과 길이가 어긋나면 컴파일이 멈춘다 — 위 주석의 "표가 상한을 덮는다" 를
    /// 주석이 아니라 컴파일러가 지키게 한다.
    ///
    /// **`F11` · `F12` 를 여기 더하지 않는다.** 표를 늘리면 `max_config_index` 도 함께
    /// 올려야 이 검사를 통과하는데, 그러면 bare `F12` 를 쓰는 index 가 다시 생겨
    /// Windows 에서 그 인스턴스가 뜨지 못한다 (위 `hotkeyFor` 주석).
    const index_hotkeys = blk: {
        const names = [_][]const u8{
            "F1", "F2", "F3", "F4", "F5",
            "F6", "F7", "F8", "F9", "F10",
        };
        if (names.len != instances.max_config_index + 1) {
            @compileError("Defaults.hotkeyFor 의 표가 instances.max_config_index 와 어긋난다");
        }
        break :blk names;
    };
};

/// `Defaults` + host 가 첫-실행 시 결정한 `shell_resolved` 로부터 JSON 템플릿
/// 생성. 첫 실행 시 디스크의 `config_0.json`에 저장 +
/// schema 검증 (`validateStructure`) ground truth. Caller 는 반환 slice 를 free.
///
/// `shell_resolved` 는 host 의 `resolveShell` 이 OS 환경에서 결정한 값:
///   - Windows: 항상 `Defaults.shell` (= `cmd.exe`).
///   - macOS: `$SHELL` env 가 있으면 그 값, 없으면 `Defaults.shell` (= `/bin/bash`).
/// 이렇게 disk 에 명시값으로 적어두면 이후 실행은 disk 그대로 사용 — host 의
/// runtime fallback 분기 없음 (config 가 단일 source of truth).
/// 기본 config 문서 (TOML). 두 곳에서 쓴다:
///   (a) 첫 실행 시 `config_N.toml` 생성
///   (b) `parse` 의 schema 검증 — 이 문서를 파싱해 key set / 구조 / 타입의 기준으로 삼는다
///
/// 그래서 **새 필드를 추가할 때 `Defaults` 와 이 함수 두 곳만** 고치면 required key
/// 검증까지 따라온다.
///
/// #510 — `hotkey` 는 **인자로 받는다.** 예전에는 인자 없는 wrapper 가 `Defaults.hotkey`
/// 상수를 넣었고, 파일을 만드는 경로가 그 wrapper 를 부르는 바람에 **어느 index 로 띄우든
/// 같은 `F1`** 이 적혔다. 이제 기본값이 index 파생 (`Defaults.hotkeyFor`) 이라 그 wrapper
/// 는 "index 를 모르는 채 파일을 만드는" 구멍이 된다. 그래서 없앴다 — 문서를 만드는 쪽이
/// 어느 키를 적는지 항상 말해야 한다. schema 기준 문서만 index 를 안 따지므로
/// `schemaReferenceToml` 이 따로 있다.
///
/// 키 순서와 빈 줄 묶음은 의도된 것이다 (#493 결정 10) — **부르는 법 → 안에서 도는 것
/// → 언제 뜨는가 → 어떻게 보이는가 → 한계**. TOML 은 파싱이 순서와 무관하므로 순전히
/// 읽는 사람을 위한 배치다.
///
/// TOML 제약: **최상위 스칼라는 테이블 헤더보다 먼저** 와야 한다. `[window]` 뒤에
/// `theme` 을 두면 `window.theme` 으로 해석된다.
pub fn defaultConfigToml(
    allocator: std.mem.Allocator,
    shell_resolved: []const u8,
    hotkey: []const u8,
) ![]const u8 {
    var fb_buf: [1024]u8 = undefined;
    var fb_fbs: std.Io.Writer = .fixed(&fb_buf);
    const fw = &fb_fbs;
    try fw.writeAll("[");
    for (Defaults.glyph_fallback, 0..) |f, i| {
        if (i > 0) try fw.writeAll(", ");
        try fw.print("\"{s}\"", .{f});
    }
    try fw.writeAll("]");
    const glyph_fallback_toml = fb_fbs.buffered();

    const head = try std.fmt.allocPrint(allocator,
        \\# TildaZ config
        \\#
        \\# Since v0.9.0 this file is TOML. If you had a JSON config, it is still
        \\# next to this file as config_N.json -- TildaZ no longer reads it.
        \\#
        \\# Field meanings and accepted ranges: CONFIG.md
        \\
        \\# Global hotkey -- the OS delivers this even when TildaZ is not focused.
        \\#
        \\# Two ways to name the key:
        \\#   label      "ctrl+space"        the character the key types
        \\#   position   "ctrl+[Backquote]"  the physical spot, whatever it prints
        \\#
        \\# A function key is the safest choice: F1-F12 sit in the same place on
        \\# every layout. Function-key positions are also the only ones accepted
        \\# without a modifier -- "[F13]" is valid, "[KeyW]" is not.
        \\#
        \\# Reach for a position when the key you want prints something different
        \\# from one layout to the next. The key left of 1 is the clearest case;
        \\# these are measured, not guessed:
        \\#
        \\#   layout                      that key prints
        \\#   US QWERTY                   `      (same on all three platforms)
        \\#   French   (Linux)            ²
        \\#   French   (Windows legacy)   ²
        \\#   French   (Windows standard) @
        \\#   French   (macOS)            <
        \\#   Russian  (Linux, Windows)   ё
        \\#   Russian  (macOS)            ]
        \\#   German   (Linux)            a dead key -- refused, with a message
        \\#
        \\# "ctrl+[Backquote]" means that one physical key on every row above. A
        \\# label such as "ctrl+grave" only fires where the layout types a backtick.
        \\#
        \\# More positions worth knowing:
        \\#   "ctrl+[BracketLeft]"   [ on US. On French it needs AltGr, so the
        \\#                          label form would be a four-finger chord.
        \\#   "[F13]"                On a PC keyboard attached to a Mac this is
        \\#                          the PrintScreen spot -- macOS reports F13.
        \\#
        \\# Position names are W3C KeyboardEvent.code values. Full list: CONFIG.md
        \\hotkey           = "{s}"
        \\
        \\shell            = "{s}"
        \\
        \\auto_start       = {}
        \\hidden_start     = {}
        \\
        \\theme            = "{s}"
        \\max_scroll_lines = {d}
        \\
        \\[window]
        \\dock_position   = "{s}"   # top | bottom | left | right
        \\width_percent   = {d:.1}
        \\height_percent  = {d:.1}
        \\offset_percent  = {d:.1}
        \\opacity_percent = {d:.1}
        \\
        \\[font]
        \\family            = "{s}"
        \\glyph_fallback    = {s}
        \\size_point        = {d}
        \\cell_width_ratio  = {d:.1}
        \\line_height_ratio = {d:.1}
        \\
        \\[input]
        \\# macOS only. On Linux and Windows this key is read but not used --
        \\# there Alt is always Meta, because Alt+a produces no character.
        \\#
        \\# macOS is different: the OS itself turns Option+a into a character
        \\# (ABC types "a-ring", French types "e-circumflex"). One key press,
        \\# two meanings -- so you pick one.
        \\#
        \\#   none    Option types characters. The macOS default.
        \\#   both    Both Option keys act as Alt, so Option+n reaches zellij,
        \\#           tmux and emacs. You lose the characters above.
        \\#   left    Only the left Option acts as Alt. The right one keeps
        \\#           typing characters.
        \\#   right   The mirror of "left".
        \\macos_option_as_alt = "{s}"
        \\
    , .{
        hotkey,
        shell_resolved,
        Defaults.auto_start,
        Defaults.hidden_start,
        Defaults.theme,
        Defaults.max_scroll_lines,
        Defaults.dock_position,
        Defaults.width_percent,
        Defaults.height_percent,
        Defaults.offset_percent,
        Defaults.opacity_percent,
        Defaults.font_family,
        glyph_fallback_toml,
        Defaults.font_size_point,
        Defaults.cell_width_ratio,
        Defaults.line_height_ratio,
        Defaults.macos_option_as_alt,
    });
    defer allocator.free(head);

    // `[keys]` 는 액션 수가 많아 별 helper 로 조립한다. **최상위 스칼라 뒤, 테이블
    // 뒤**에 온다 — TOML 은 테이블 헤더 다음의 키를 그 테이블 소속으로 읽으므로
    // 순서를 바꿀 수 없다.
    // 액션 23 개 × 한 줄 ~60 byte + 안내 주석 (라벨 / 위치 두 표기 설명이 들어가
    // 커졌다). 고정 버퍼로 충분하고 (이 코드베이스의 `Io.Writer.fixed` 패턴) 넘치면
    // `writeAll` 이 오류를 낸다 — 조용히 잘리지 않는다.
    var keys_buf: [8192]u8 = undefined;
    var keys_fbs: std.Io.Writer = .fixed(&keys_buf);
    try appendKeysSection(&keys_fbs);
    const keys = keys_fbs.buffered();

    const out = try allocator.alloc(u8, head.len + keys.len);
    @memcpy(out[0..head.len], head);
    @memcpy(out[head.len..], keys);
    return out;
}

/// schema 검증 (`validateStructure`) 의 기준 문서. **파일로 쓰는 용도가 아니다** —
/// key set / 중첩 구조 / value type 만 보므로 `shell` 과 `hotkey` 의 *값* 은 무의미하다.
///
/// #510 — 그래서 index 를 안 받는다. 파일을 만드는 경로는 `defaultConfigToml` 을 직접
/// 부르고 그 index 의 핫키를 명시해야 한다.
pub fn schemaReferenceToml(allocator: std.mem.Allocator) ![]const u8 {
    return defaultConfigToml(allocator, Defaults.shell, Defaults.hotkeyFor(0));
}

// `Defaults` 의 string / float 값을 Config struct 가 보관하는 native type 으로
// 변환 (DockPosition enum / Hotkey struct / Theme pointer / alpha u8).
const default_dock_position: DockPosition = DockPosition.fromString(Defaults.dock_position) orelse unreachable;
const default_macos_option_as_alt: MacOptionAsAlt = MacOptionAsAlt.fromString(Defaults.macos_option_as_alt) orelse unreachable;
/// JSON 은 percent (0..100, f32), 메모리는 alpha (0..255 u8). `100.0` percent → `255` alpha.
const default_opacity_alpha: u8 = @round(Defaults.opacity_percent * 255.0 / 100.0);
const default_theme: ?*const themes.Theme = themes.findTheme(Defaults.theme);
/// #510 — `Config{}` 의 field initializer 는 comptime 이라 index 를 모른다. 그래서 이
/// 값은 **index 0 의 키**이고, 파일이 없거나 못 읽어 기본값으로 떨어지는 경로는
/// `defaultOwned` 가 자기 index 의 키로 덮어쓴다.
const default_hotkey: Hotkey = Hotkey.fromString(Defaults.hotkeyFor(0)) orelse unreachable;
const default_font_size_point: u8 = Defaults.font_size_point;
const default_cell_width_ratio: f32 = Defaults.cell_width_ratio;
const default_line_height_ratio: f32 = Defaults.line_height_ratio;
const default_shell: []const u8 = Defaults.shell;
/// Internal chain = primary (Defaults.font_family) + glyph_fallback. parse 후
/// `Config.font_families` 도 같은 의미 — chain[0] 은 primary, chain[1..] 은
/// glyph fallback. host / renderer 가 보는 인터페이스는 합친 chain 한 개.
const DEFAULT_FONT_CHAIN_COUNT: u8 = @intCast(1 + Defaults.glyph_fallback.len);

fn defaultFontFamiliesArray() [MAX_FONT_FAMILIES][]const u8 {
    var arr: [MAX_FONT_FAMILIES][]const u8 = undefined;
    arr[0] = Defaults.font_family;
    for (Defaults.glyph_fallback, 0..) |fb, i| arr[i + 1] = fb;
    var i: usize = 1 + Defaults.glyph_fallback.len;
    while (i < MAX_FONT_FAMILIES) : (i += 1) arr[i] = "";
    return arr;
}

/// #493 — `[keys]` 에서 바인딩할 수 있는 액션. **`input_policy.Shortcut` 과 1:1 이
/// 아니다** — 그쪽은 런타임 dispatch 용이고 이쪽은 config 표면이다. 차이가 셋 있다:
///
///   - `switch_tab1`~`9` 는 config 에서 9 개지만 런타임은 `Shortcut.switch_tab`
///     하나 + 인덱스다. 사람이 읽는 파일에서 "몇 번 탭" 이 이름에 있어야 한다.
///   - `paste` 는 `Shortcut` 이 아니라 `Input.paste` 다 (preedit commit 정책이 달라
///     분리돼 있다). config 표면에서는 다른 단축키와 나란히 있어야 자연스럽다.
///   - `fullscreen_workarea` 는 별 `Shortcut` 이 없다 — 런타임은 `fullscreen` +
///     Shift 여부로 갈린다. config 에서는 두 동작이 별 항목이어야 각각 바인딩할 수
///     있다.
///
/// **스크롤백 (`Shift+PgUp` / `Shift+PgDn`) 은 일부러 없다.** 그것은 단축키가 아니라
/// **스크롤**이다 — `app_event.Event` 에서도 `shortcut` 이 아니라 `scroll` 범주이고,
/// 마우스 휠과 같은 자리다. 세 platform 모두 매처 밖에서 처리한다 (Linux
/// `wayland_minimal` · Windows `wndProc` · macOS `tildazKeyDown`). 마우스 스크롤을
/// 재바인딩하지 않는 것과 같은 이유로 설정 대상이 아니다.
///
/// 그래서 이 enum 이 config 의 단일 출처이고, 런타임 매핑은 3-c 단계에서 붙인다.
///
/// 이름을 바꾸면 기존 사용자 config 의 그 키가 "모르는 키" 가 된다 — 결정 8 의
/// 삭제 대상이 되므로 이름 변경은 비가산적 변경이다.
/// #493 — 액션별 기본 키.
///
/// **한 표로 세 platform 을 덮을 수 없다.** 처음엔 `cmd` 토큰이 차이를 흡수한다고
/// 적었는데 (Linux Super = Windows Win = macOS Command) 그것으로는 부족하다 —
/// macOS 는 modifier 만 다른 것이 아니라 **Shift 의 유무가 다르다.** Apple HIG 를
/// 따르는 관습이 `Cmd+T` 인데 PC 쪽은 `Ctrl+Shift+T` 다. `KEYBINDINGS.md` 의 표가
/// 그 차이를 이미 기록하고 있고, 3-c 배선에서 그 표를 그대로 재현해야 한다.
/// `cmd` 로만 치환하면 macOS 사용자의 모든 단축키가 `Control+Shift+*` 로 바뀐다.
///
/// `KeyAction` 에 variant 를 추가하면 **두 표를 다** 채워야 한다. 빠지면
/// `defaultKeysToml` 이 컴파일 시점에 잡는다 (exhaustive switch).
pub fn defaultBindings(action: KeyAction) []const []const u8 {
    return if (is_macos) macDefaultBindings(action) else pcDefaultBindings(action);
}

/// macOS 기본 bindings — `KEYBINDINGS.md` 의 macOS 열과 1:1. Apple HIG 순서
/// (`Shift+Cmd`) 를 따른다.
fn macDefaultBindings(action: KeyAction) []const []const u8 {
    return switch (action) {
        .new_tab => &.{"cmd+t"},
        .close_tab => &.{"cmd+w"},
        .prev_tab => &.{ "shift+cmd+[", "cmd+pageup" },
        .next_tab => &.{ "shift+cmd+]", "cmd+pagedown" },
        .switch_tab1 => &.{"cmd+1"},
        .switch_tab2 => &.{"cmd+2"},
        .switch_tab3 => &.{"cmd+3"},
        .switch_tab4 => &.{"cmd+4"},
        .switch_tab5 => &.{"cmd+5"},
        .switch_tab6 => &.{"cmd+6"},
        .switch_tab7 => &.{"cmd+7"},
        .switch_tab8 => &.{"cmd+8"},
        .switch_tab9 => &.{"cmd+9"},
        .copy_selection => &.{"cmd+c"},
        .paste => &.{"cmd+v"},
        .fullscreen => &.{"cmd+return"},
        .fullscreen_workarea => &.{"shift+cmd+return"},
        .quit => &.{"cmd+q"},
        .reset_terminal => &.{"shift+cmd+r"},
        .show_about => &.{"shift+cmd+i"},
        .open_config => &.{"shift+cmd+p"},
        .open_log => &.{"shift+cmd+l"},
        .dump_perf => &.{"shift+cmd+f12"},
    };
}

/// Linux · Windows 기본 bindings — `KEYBINDINGS.md` 의 두 열과 1:1 (그 둘은 같다).
fn pcDefaultBindings(action: KeyAction) []const []const u8 {
    return switch (action) {
        .new_tab => &.{"ctrl+shift+t"},
        .close_tab => &.{"ctrl+shift+w"},
        // #482 — bracket 조합은 AZERTY 에서 쓸 수 없어 (`[` = AltGr+5) PgUp / PgDn
        // 을 layout 무관 대안으로 함께 둔다.
        .prev_tab => &.{ "ctrl+shift+[", "ctrl+pageup" },
        .next_tab => &.{ "ctrl+shift+]", "ctrl+pagedown" },
        .switch_tab1 => &.{"alt+1"},
        .switch_tab2 => &.{"alt+2"},
        .switch_tab3 => &.{"alt+3"},
        .switch_tab4 => &.{"alt+4"},
        .switch_tab5 => &.{"alt+5"},
        .switch_tab6 => &.{"alt+6"},
        .switch_tab7 => &.{"alt+7"},
        .switch_tab8 => &.{"alt+8"},
        .switch_tab9 => &.{"alt+9"},
        .copy_selection => &.{"ctrl+shift+c"},
        .paste => &.{"ctrl+shift+v"},
        .fullscreen => &.{"alt+return"},
        .fullscreen_workarea => &.{"shift+alt+return"},
        .quit => &.{"alt+f4"},
        .reset_terminal => &.{"ctrl+shift+r"},
        .show_about => &.{"ctrl+shift+i"},
        .open_config => &.{"ctrl+shift+p"},
        .open_log => &.{"ctrl+shift+l"},
        .dump_perf => &.{"ctrl+shift+f12"},
    };
}

/// `[keys]` 섹션 본문. 그룹 주석과 순서는 의도된 것이다 (#493 결정 10) — 파일을
/// 읽는 사람이 묶음을 알아볼 수 있어야 한다.
fn appendKeysSection(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\
        \\# ─────────────────────────────────────────────────────────────────────────
        \\# Keyboard shortcuts
        \\#
        \\# An action may have several keys. An empty list [] means "no shortcut".
        \\#
        \\# `cmd` resolves per OS -- Super on Linux, Win on Windows, Command on
        \\# macOS -- so a combination you write yourself works on all three.
        \\#
        \\# A key can be named two ways:
        \\#
        \\#   by label      "ctrl+shift+w"        the letter printed on the key
        \\#   by position   "ctrl+shift+[KeyW]"   the physical spot, any layout
        \\#
        \\# Labels are simpler and are what these defaults use. Use a position when
        \\# a label cannot reach the key -- on a Cyrillic or Greek layout no key
        \\# produces `w`, so "ctrl+shift+w" can never fire. Position names are W3C
        \\# KeyboardEvent.code values: https://www.w3.org/TR/uievents-code/
        \\#
        \\# Accepted labels: F1-F12, A-Z, 0-9, space, tab, escape, return,
        \\#                  grave(`), pageup, pagedown, [, ]
        \\# Accepted positions: every key a keyboard can send -- letters, digits,
        \\#                  symbols, numpad, arrows, F13-F24. See CONFIG.md.
        \\#
        \\# Scrolling (shift+pageup / shift+pagedown) and ctrl+c are not here: the
        \\# first is the mouse wheel driven from the keyboard, the second sends
        \\# SIGINT. Neither can be rebound.
        \\#
        \\# CONFIG.md has the full syntax; KEYBINDINGS.md has worked examples for
        \\# AZERTY and non-Latin keyboards.
        \\# ─────────────────────────────────────────────────────────────────────────
        \\
        \\[keys]
        \\
        \\# Tabs
        \\
    );
    const groups = [_]struct { title: ?[]const u8, actions: []const KeyAction }{
        .{ .title = null, .actions = &.{ .new_tab, .close_tab, .prev_tab, .next_tab, .switch_tab1, .switch_tab2, .switch_tab3, .switch_tab4, .switch_tab5, .switch_tab6, .switch_tab7, .switch_tab8, .switch_tab9 } },
        .{ .title = "Clipboard", .actions = &.{ .copy_selection, .paste } },
        .{ .title = "Window", .actions = &.{ .fullscreen, .fullscreen_workarea, .quit } },
        .{ .title = "Tools", .actions = &.{ .reset_terminal, .show_about, .open_config, .open_log, .dump_perf } },
    };
    for (groups) |g| {
        if (g.title) |t| {
            try w.writeAll("\n# ");
            try w.writeAll(t);
            try w.writeAll("\n");
        }
        for (g.actions) |a| {
            const name = a.configName();
            try w.writeAll(name);
            // 값 열을 맞춘다 — 가장 긴 이름 (`fullscreen_workarea`, 19) 기준.
            var pad: usize = 19 + 1;
            while (pad > name.len) : (pad -= 1) try w.writeAll(" ");
            try w.writeAll("= [");
            for (defaultBindings(a), 0..) |k, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("\"{s}\"", .{k});
            }
            try w.writeAll("]\n");
        }
    }
}

pub const KeyAction = enum {
    new_tab,
    close_tab,
    prev_tab,
    next_tab,
    switch_tab1,
    switch_tab2,
    switch_tab3,
    switch_tab4,
    switch_tab5,
    switch_tab6,
    switch_tab7,
    switch_tab8,
    switch_tab9,
    copy_selection,
    paste,
    fullscreen,
    fullscreen_workarea,
    quit,
    reset_terminal,
    show_about,
    open_config,
    open_log,
    dump_perf,

    /// config 파일에 쓰는 이름. enum tag 그대로다 — 파일과 코드가 갈라지지 않게
    /// 별 문자열 표를 두지 않는다 (#484 의 writer/matcher 교훈).
    pub fn configName(self: KeyAction) []const u8 {
        return @tagName(self);
    }
};

/// #493 3-c — 키 이벤트에서 만든 `Hotkey` 로 액션을 찾는다. **정확히 일치만** 본다.
///
/// Shift 를 무시하는 완화 조회를 두었다가 뺐다. AZERTY 처럼 숫자열에 Shift 가 필요한
/// layout 에서 `Alt+1` 이 `Alt+Shift+(&1 키)` 로 도착하는 문제를 매칭 쪽에서 풀려고
/// 했는데, 그러면
///
///   - `Shift+Alt+F4` 도 `alt+f4` (quit) 로 잡히는 등 **의도하지 않은 조합이 발동**하고,
///   - QWERTY 에서 `Shift+[` 는 keysym 이 `{` 라서 정규화 표가 따로 필요해지고,
///   - 무엇보다 "이 키가 왜 저 동작을 하는가" 를 사용자가 설명할 수 없게 된다.
///
/// layout 때문에 특정 조합을 누를 수 없다면 **그 layout 에서 다른 키로 바꾸는 것**이
/// 답이다 — `[keys]` 를 설정 가능하게 만든 이유가 그것이다.
///
/// ## 두 기준
///
/// #496 — binding 은 라벨로도 (`ctrl+shift+w`) 위치로도 (`ctrl+shift+[KeyW]`) 적을 수
/// 있고, 한 event 가 두 종류의 binding 모두와 겨뤄야 한다. 그래서 호출자는 같은
/// key event 를 **두 표현으로** 넘긴다:
///
///   - `hotkey` — 라벨 표현. platform 이 주는 keysym / vkey / keycode 로 만든다.
///     `hotkey.code` 는 **반드시 null** 이어야 한다 (event 는 binding 이 아니다).
///   - `code` — 물리 위치. Linux evdev keycode · Windows scan code · macOS keyCode 를
///     `physical_key.fromEvdev` / `..fromScanCode` / `..fromMacKeyCode` 로 옮긴 값.
///     표에 없는 키면 null 이고, 그때 위치 binding 은 아무것도 매칭하지 않는다.
///
/// binding 쪽 `code` 가 non-null 이면 위치로, null 이면 라벨로 판정한다. 한 binding 이
/// 두 기준을 동시에 갖지 않으므로 "왜 이 키가 이 동작을 했는가" 가 항상 한 가지로
/// 설명된다.
/// #493 3-c — Linux: 도착한 keysym 을 **binding 쪽 표현**으로 옮긴다.
///
/// Linux 는 세 platform 중 유일하게 **라벨 (keysym) 로 매칭한다.** 그래서 Shift 가
/// keysym 자체를 바꾸는 것이 문제가 된다: binding `ctrl+shift+c` 는 keysym `c`
/// (0x63) 로 저장되는데 실제로 도착하는 것은 `C` (0x43) 다. 예전 하드코딩 매처가
/// 두 값을 나란히 적어 (`xkb_key_c_lower, xkb_key_c_upper`) 해결하던 자리이고,
/// 그것을 규칙 하나로 옮긴 것이 이 함수다.
///
/// **Shift 비트는 건드리지 않는다.** 키 값만 무시프트 표현으로 되돌리므로
/// `ctrl+shift+c` 와 `ctrl+c` 가 여전히 다른 조합이다 — Shift 를 선택적으로 만드는
/// 완화가 아니다 (그것은 #493 에서 명시적으로 거부했다).
///
/// 수용 집합 안에서 Shift 가 값을 바꾸는 키만 다룬다. 숫자는 **일부러 빼 놓았다**:
/// QWERTY 에서 `Shift+1` 은 `exclam` 인데 그것을 `1` 로 되돌리면 `Alt+Shift+1` 이
/// 탭 전환이 되어 동작이 넓어진다. AZERTY 의 숫자 문제는 값이 아니라 Shift 비트
/// 쪽이라 `isDigitBinding` 예외가 담당한다.
pub fn normalizeLinuxKeysym(sym: u32) u32 {
    // 대문자 latin → 소문자. binding 은 항상 소문자로 저장된다
    // (`hotkeyKeyFromName` 이 정규화한다).
    if (sym >= 'A' and sym <= 'Z') return sym + 0x20;
    return switch (sym) {
        0x7b => 0x5b, // braceleft  -> bracketleft
        0x7d => 0x5d, // braceright -> bracketright
        0x7e => 0x60, // asciitilde -> grave
        else => sym,
    };
}

test "#493 3-c — Linux keysym 정규화는 값만 되돌리고 Shift 를 건드리지 않는다" {
    // 대문자 → 소문자. `ctrl+shift+c` binding 이 도착한 `C` 와 만나는 자리다.
    try std.testing.expectEqual(@as(u32, 0x63), normalizeLinuxKeysym(0x43)); // C -> c
    try std.testing.expectEqual(@as(u32, 0x77), normalizeLinuxKeysym(0x57)); // W -> w
    // Shift 가 값을 바꾸는 기호 — 예전 매처가 두 값을 나란히 적던 자리.
    try std.testing.expectEqual(@as(u32, 0x5b), normalizeLinuxKeysym(0x7b)); // { -> [
    try std.testing.expectEqual(@as(u32, 0x5d), normalizeLinuxKeysym(0x7d)); // } -> ]
    try std.testing.expectEqual(@as(u32, 0x60), normalizeLinuxKeysym(0x7e)); // ~ -> `
    // 이미 무시프트인 값은 그대로.
    try std.testing.expectEqual(@as(u32, 0x63), normalizeLinuxKeysym(0x63));
    try std.testing.expectEqual(@as(u32, 0xffbe), normalizeLinuxKeysym(0xffbe)); // F1
    // 숫자는 건드리지 않는다 — `exclam` 이 `1` 이 되면 동작이 넓어진다.
    try std.testing.expectEqual(@as(u32, 0x21), normalizeLinuxKeysym(0x21)); // ! 그대로
    try std.testing.expectEqual(@as(u32, 0x31), normalizeLinuxKeysym(0x31)); // 1 그대로
}

/// #493 3-c — `[keys]` 문법의 키 문자열 하나를 `Hotkey` 로. host 의 테스트와 설정
/// UI 가 쓴다. 실패 원인이 필요하면 `parseHotkeyString` 을 직접 쓴다 — 여기서는
/// "되면 값, 안 되면 null" 만 준다.
pub fn appBindingHotkey(text: []const u8) ?Hotkey {
    return switch (parseHotkeyString(text, .app_binding)) {
        .ok => |p| Hotkey.fromParsed(p),
        else => null,
    };
}

/// #493 3-c — config 액션을 런타임 입력으로 옮긴다. **세 host 가 이 한 표를 쓴다** —
/// host 마다 매핑을 두면 갈라진다 (#296 이 정확히 그래서 만들어졌다).
///
/// `KeyAction` 과 `input_policy.Shortcut` 이 1:1 이 아니라서 이 표가 필요하다:
///
///   - `switch_tab1`~`9` 는 config 에서 9 개, 런타임은 `switch_tab` 하나 + 인덱스다.
///     **인덱스의 출처가 액션 이름이 된다** — 예전엔 host 마다 native 키 코드에서
///     뽑았다 (macOS `keycodeToTabIndex`, Linux `sym - xkb_key_1`, Windows
///     `wParam - 0x31`). 액션을 다 펼쳐 적기로 한 결정의 값을 여기서 돌려받는다.
///   - `paste` 는 `Shortcut` 이 아니라 `Input.paste` 다 (preedit commit 정책이
///     다르다).
pub const ActionInput = struct {
    input: input_policy.Input,
    /// `switch_tab` 일 때 0-based 탭 인덱스. 그 외에는 null.
    tab_index: ?usize = null,
};

pub fn inputForAction(action: KeyAction) ActionInput {
    return switch (action) {
        .new_tab => .{ .input = .{ .shortcut = .new_tab } },
        .close_tab => .{ .input = .{ .shortcut = .close_tab } },
        .prev_tab => .{ .input = .{ .shortcut = .prev_tab } },
        .next_tab => .{ .input = .{ .shortcut = .next_tab } },
        .switch_tab1 => .{ .input = .{ .shortcut = .switch_tab }, .tab_index = 0 },
        .switch_tab2 => .{ .input = .{ .shortcut = .switch_tab }, .tab_index = 1 },
        .switch_tab3 => .{ .input = .{ .shortcut = .switch_tab }, .tab_index = 2 },
        .switch_tab4 => .{ .input = .{ .shortcut = .switch_tab }, .tab_index = 3 },
        .switch_tab5 => .{ .input = .{ .shortcut = .switch_tab }, .tab_index = 4 },
        .switch_tab6 => .{ .input = .{ .shortcut = .switch_tab }, .tab_index = 5 },
        .switch_tab7 => .{ .input = .{ .shortcut = .switch_tab }, .tab_index = 6 },
        .switch_tab8 => .{ .input = .{ .shortcut = .switch_tab }, .tab_index = 7 },
        .switch_tab9 => .{ .input = .{ .shortcut = .switch_tab }, .tab_index = 8 },
        .copy_selection => .{ .input = .{ .shortcut = .copy_selection } },
        .paste => .{ .input = .paste },
        .fullscreen => .{ .input = .{ .shortcut = .fullscreen } },
        .fullscreen_workarea => .{ .input = .{ .shortcut = .fullscreen_workarea } },
        .quit => .{ .input = .{ .shortcut = .quit } },
        .reset_terminal => .{ .input = .{ .shortcut = .reset_terminal } },
        .show_about => .{ .input = .{ .shortcut = .show_about } },
        .open_config => .{ .input = .{ .shortcut = .open_config } },
        .open_log => .{ .input = .{ .shortcut = .open_log } },
        .dump_perf => .{ .input = .{ .shortcut = .dump_perf } },
    };
}

/// #496 1-a — 이 binding 이 **라틴 fallback 후보인가.**
///
/// 비라틴 layout (키릴 · 그리스 · 아랍 ...) 에서는 그 자판의 어느 키도 라틴 글자를
/// 내지 않으므로 `ctrl+shift+w` 가 영원히 발동하지 않는다. 그럴 때 **US 자판에서 그
/// 글자가 있던 자리**로 대신 매칭해 준다 — GTK · i3 · sway · VS Code 가 하는 것과 같다.
///
/// 후보 조건은 **layout 에 따라 달라지는 라벨**이라는 것이다:
///
///   - 위치로 적은 binding 은 후보가 아니다 (이미 layout 무관하다).
///   - `F1` · `PageUp` 처럼 layout 과 무관한 named 키는 후보가 아니다 — 어느 자판에나
///     그 키가 있으므로 라벨 매칭이 실패할 이유가 없다.
///   - 글자 · 숫자 · `` ` `` · `[` · `]` 만 후보다.
///
/// **실제로 fallback 을 만들지는 호출자가 정한다** — 현재 keymap 이 그 글자를 낼 수
/// 있으면 만들지 않는다. 그것이 중요하다: AZERTY 는 `w` 를 낼 수 있으므로 fallback 이
/// 생기지 않고, 따라서 `Z` 라 인쇄된 키 (US `w` 자리) 가 `close_tab` 을 발동시키지
/// **않는다.** 무조건 두 번째 pass 를 돌리면 그 layout 에서 한 동작에 키가 둘 생긴다.
pub const FallbackCandidate = struct {
    /// 이 binding 이 기다리는 라벨. 호출자가 "지금 layout 이 이 글자를 낼 수 있나"
    /// 를 물어볼 값이다. Linux 에서는 keysym, **macOS 에서는 `MacHotkey.label`**
    /// 이고 라틴 글자 범위에서는 둘이 같은 값 (ASCII) 이라 이름을 나누지 않았다.
    keysym: u32,
    /// 그 글자가 US 자판에서 있던 자리.
    code: PhysicalCode,
};

pub fn fallbackCandidate(hotkey: Hotkey) ?FallbackCandidate {
    // Windows 는 fallback 이 필요 없다 — 비라틴 layout DLL 이 물리 위치에 라틴 VK 를
    // 배정하므로 (`KBDRU` 의 scancode 0x11 → `VK_W`) OS 가 이미 해 준다.
    //
    // **macOS 는 #496 항목 2 부터 필요하다.** 그전에는 `kVK_ANSI_*` (위치) 로
    // 매칭해서 키릴에서도 그냥 동작했지만, 라벨 매칭으로 바꾸면 키릴 · 한글처럼
    // **라틴 글자를 한 자도 못 내는 layout** 에서 글자 단축키가 전부 죽는다
    // (실측: `ru` · 2-Set Korean 모두 라틴 0 개). Linux 와 같은 fallback 이 그것을 막는다.
    if (is_windows) return null;
    if (hotkey.code != null) return null;
    const label = if (is_macos) hotkey.label else hotkey.keysym;
    // macOS 의 `label == 0` 은 "라벨로 매칭하지 않는 키" (`F1` 등) 다 — layout 과
    // 무관하므로 fallback 도 필요 없다.
    if (label == 0) return null;
    const code = usPositionForKeysym(label) orelse return null;
    return .{ .keysym = label, .code = code };
}

/// keysym → US 자판에서 그 글자가 있던 자리. `LinuxHotkey.keysymFromKey` 의 역방향
/// 이고 **char 계열만** 다룬다 (named 키는 layout 무관이라 fallback 이 필요 없다).
fn usPositionForKeysym(keysym: u32) ?PhysicalCode {
    var name_buf: [8]u8 = undefined;
    if (keysym >= 'a' and keysym <= 'z') {
        const name = std.fmt.bufPrint(&name_buf, "Key{c}", .{std.ascii.toUpper(@intCast(keysym))}) catch return null;
        return physical_key.fromName(name);
    }
    if (keysym >= '0' and keysym <= '9') {
        const name = std.fmt.bufPrint(&name_buf, "Digit{c}", .{@as(u8, @intCast(keysym))}) catch return null;
        return physical_key.fromName(name);
    }
    return switch (keysym) {
        0x60 => .backquote,
        0x5b => .bracket_left,
        0x5d => .bracket_right,
        else => null,
    };
}

/// #496 1-a — 라벨 조회가 실패했을 때 **대체 위치**로 한 번 더 본다.
///
/// `fallbacks` 는 `bindings` 와 **같은 인덱스**다. non-null 인 항목만 2 차 pass 의
/// 대상이고, 그것은 호출자가 "이 라벨은 현재 keymap 으로 낼 수 없다" 고 판정한
/// binding 뿐이다 (`fallbackCandidate` 주석 참고).
///
/// 순서가 중요하다 — **라벨이 먼저다.** 라벨로 잡히는 event 가 fallback 때문에 다른
/// 액션이 되면 사용자가 설명할 수 없다.
pub fn lookupActionWithFallback(
    bindings: []const KeyBinding,
    fallbacks: []const ?PhysicalCode,
    hotkey: Hotkey,
    code: ?PhysicalCode,
) ?KeyAction {
    if (lookupAction(bindings, hotkey, code)) |action| return action;
    const got = code orelse return null;
    for (bindings, 0..) |b, i| {
        if (i >= fallbacks.len) break;
        const want = fallbacks[i] orelse continue;
        if (want != got) continue;
        // modifier 규칙은 1 차 pass 와 같다 — 숫자 예외까지 포함해서다 (#482).
        const shift_bit: @TypeOf(hotkey.modifiers) = Hotkey.MOD_SHIFT;
        const mods_match = b.hotkey.modifiers == hotkey.modifiers or
            (isDigitBinding(b.hotkey) and b.hotkey.modifiers == (hotkey.modifiers & ~shift_bit));
        if (mods_match) return b.action;
    }
    return null;
}

pub fn lookupAction(bindings: []const KeyBinding, hotkey: Hotkey, code: ?PhysicalCode) ?KeyAction {
    std.debug.assert(hotkey.code == null);
    for (bindings) |b| {
        const mods_match = b.hotkey.modifiers == hotkey.modifiers or
            (isDigitBinding(b.hotkey) and
                b.hotkey.modifiers == (hotkey.modifiers & ~@as(@TypeOf(hotkey.modifiers), Hotkey.MOD_SHIFT)));
        if (!mods_match) continue;
        if (b.hotkey.code) |want| {
            // 위치 binding — 자리가 일치해야 한다. 라벨 쪽 값 (keysym / vkey /
            // keycode) 은 보지 않는다.
            const got = code orelse continue;
            if (got == want) return b.action;
            continue;
        }
        if (is_macos) {
            // #496 항목 2 — macOS 는 binding 마다 비교 대상이 갈린다.
            //
            //   `label != 0`  라벨 binding (`w` · `` ` ``). **이벤트가 실제로 낸
            //                 글자**와 비교한다. 그래서 AZERTY 에서는 `W` 라 인쇄된
            //                 키가, US 에서는 같은 자리가 걸린다.
            //   `label == 0`  layout 무관 키 (`F1` · `space` …). keycode 로 본다.
            //
            // 이벤트가 라벨을 못 낸 경우 (modifier 키 · function 키) `hotkey.label`
            // 이 0 이라 라벨 binding 에 걸리지 않는다 — 그게 맞다.
            //
            // 다른 두 platform 처럼 `modifiersAside` 하나로 비교할 수 없다. 그쪽은
            // 라벨 값 하나 (keysym / vkey) 로 모든 키를 표현하지만 macOS 의 `keycode`
            // 는 위치라서, 라벨과 위치를 같은 칸에 넣을 수 없다.
            if (b.hotkey.label != 0) {
                if (hotkey.label != 0 and hotkey.label == b.hotkey.label) return b.action;
            } else if (hotkey.keycode == b.hotkey.keycode) {
                return b.action;
            }
            continue;
        }
        if (b.hotkey.code == null and hotkey.code == null and modifiersAside(b.hotkey) == modifiersAside(hotkey)) {
            return b.action;
        }
    }
    return null;
}

/// modifier 를 뺀 라벨 쪽 키 값. `std.meta.eql` 로 통째로 비교하면 Shift 예외를
/// 표현할 수 없어 (아래) 키 값만 따로 꺼낸다.
fn modifiersAside(h: Hotkey) u32 {
    if (is_windows) return h.vkey;
    // macOS 는 위의 `lookupAction` 이 먼저 갈라져서 여기 오지 않는다 (#496 항목 2).
    // 값을 남겨 두는 것은 `Hotkey` 가 comptime 으로 갈리는 타입이라 세 분기가 다
    // 컴파일되어야 하기 때문이다.
    if (is_macos) return h.keycode;
    return h.keysym;
}

/// #482 — **숫자 binding 은 Shift 를 무시한다.** 일반 규칙이 아니라 숫자에만 두는
/// 좁은 예외이고, 이유가 layout 에 있다: AZERTY (fr) 등에서 숫자열은 **Shift 를
/// 눌러야 숫자가 나온다** (무시프트는 `&é"'(-è_çà`). 그래서 `Alt+1` 이 그 layout
/// 에서 항상 `Alt+Shift+1` 로 도착하고, 엄격히 비교하면 인덱스 탭 전환이 그
/// layout 에서 아예 동작하지 않는다.
///
/// **이것은 동작 확대가 아니다** — 3-c 이전의 세 host 가 이미 그렇게 동작했다.
/// Windows 는 `wParam >= 0x31 and wParam <= 0x39` 로 Shift 를 아예 보지 않았고
/// (`window.zig`), macOS 는 `keycodeToTabIndex(kc) != null` 로 역시 보지 않았으며
/// (`host/macos.zig`), Linux 도 #482 에서 `!shift` 요구를 걷어냈다. 그 셋을 한 규칙
/// (`lookupAction`) 으로 모을 때 이 예외를 빼면 세 platform 모두 AZERTY 에서
/// 퇴행한다. 세 곳의 하드코딩은 3-c 에서 사라졌고 근거만 여기 남는다.
///
/// QWERTY 에는 영향이 없다: 그쪽에서 `Alt+Shift+1` 은 keysym 이 `exclam` 이라
/// 라벨 비교 자체가 실패한다. Windows / macOS 는 위치 기반이어서 오늘도 잡히므로
/// 역시 변화가 없다.
fn isDigitBinding(h: Hotkey) bool {
    if (h.code) |c| {
        return switch (c) {
            .digit0, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9 => true,
            else => false,
        };
    }
    // 라벨 쪽은 platform 값에서 되짚는다 — 세 표 모두 숫자를 ASCII 그대로 (Linux
    // keysym · Windows vkey) 쓰거나 `kVK_ANSI_0`~`9` 로 쓴다.
    const v = modifiersAside(h);
    if (is_macos) return physical_key.fromMacKeyCode(v) != null and switch (physical_key.fromMacKeyCode(v).?) {
        .digit0, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9 => true,
        else => false,
    };
    return v >= '0' and v <= '9';
}

/// 한 액션에 키를 여러 개 줄 수 있다 (결정 3). 런타임 조회 방향은 **키 → 액션**
/// 이므로 (키 이벤트를 받아 "무슨 액션인가" 를 묻는다) 평면 배열로 보관한다.
pub const KeyBinding = struct {
    hotkey: Hotkey,
    action: KeyAction,
};

/// 액션 25 개 × 대개 1~2 개. 넉넉히 잡아 할당을 없앤다 (`font_families` 와 같은 방식).
pub const MAX_KEY_BINDINGS = 64;

pub const Config = struct {
    /// #501 — config 를 읽지 못하거나 만들지 못한 사실. **fatal 이 아니다** — 시작을
    /// 거부하면 사용자가 스스로 잠긴다 (config 를 고칠 터미널이 tildaz 뿐일 수 있다).
    ///
    /// 여기 조립된 문장을 그대로 담는다 (경로 포함, #495 형식). 구조체로 들고 가서
    /// 나중에 포맷하지 않는 이유는 **경로**다 — `load` 가 연 path 는 그 함수를 벗어나면
    /// 해제되고, 다시 조회하면 instance 번호와 실제 파일이 갈릴 수 있다 (#316 의 교훈).
    ///
    /// host 가 **창이 뜬 뒤** 한 번 보여준다. 로드 시점에 바로 띄우지 않는 이유는
    /// Linux 에서 그때는 Wayland backend 가 없어 다이얼로그가 stderr / log 로만
    /// 가기 때문이다 — 데스크톱 아이콘으로 띄운 사용자에게는 보이지 않는다.
    load_notice: ?[]const u8 = null,
    /// #533 — macOS 의 Option 을 Alt 로 볼지. 다른 두 platform 에서는 값이 읽히지만
    /// 쓰이지 않는다 (`MacOptionAsAlt` 의 주석 참고).
    macos_option_as_alt: MacOptionAsAlt = default_macos_option_as_alt,
    dock_position: DockPosition = default_dock_position,
    /// 화면 가로 점유율 percent (1..100, f32). 실수 허용 — 세밀 조정용.
    width_percent: f32 = Defaults.width_percent,
    height_percent: f32 = Defaults.height_percent,
    offset_percent: f32 = Defaults.offset_percent,
    /// memory 0..255 alpha. JSON `window.opacity_percent` (0..100, f32) → parse
    /// 시 alpha 로 매핑. memory 표현은 host 의 native API (NSWindow.alphaValue,
    /// SetLayeredWindowAttributes) 가 byte alpha 사용해 그 형식 그대로 보관.
    opacity_alpha: u8 = default_opacity_alpha,
    theme: ?*const themes.Theme = default_theme,
    hotkey: Hotkey = default_hotkey,
    /// Shell path. 첫 실행 시 host 의 `resolveShell` 이 결정한 값으로 disk 에
    /// 명시되며, 이후 실행은 disk 의 명시값을 그대로 읽음 (runtime fallback
    /// 분기 없음). 빈 문자열은 허용하지 않음 — `shell_validate` 가 잡음.
    shell: []const u8 = default_shell,
    auto_start: bool = Defaults.auto_start,
    hidden_start: bool = Defaults.hidden_start,
    max_scroll_lines: u32 = Defaults.max_scroll_lines,
    /// Logical font size (8..72). host 가 OS scale 을 곱해 raster.
    font_size_point: u8 = default_font_size_point,
    /// cell width ratio — 측정된 advance 에 곱해 글자 사이 padding 조절. 1.0
    /// = 폰트 그대로, 1.1 = 10% 넓음. range 0.5..2.0.
    cell_width_ratio: f32 = default_cell_width_ratio,
    /// line height ratio — 측정된 ascent+descent+leading 에 곱해 줄 높이 조절.
    line_height_ratio: f32 = default_line_height_ratio,
    /// chain = primary + glyph_fallback (parse 후 합쳐짐). chain[0] 은 primary,
    /// chain[1..] 은 glyph fallback 순서. host / renderer 가 한 개의 array 로 받음.
    font_families: [MAX_FONT_FAMILIES][]const u8 = defaultFontFamiliesArray(),
    font_family_count: u8 = DEFAULT_FONT_CHAIN_COUNT,
    /// #493 — `[keys]` 파싱 결과. 키 → 액션 방향으로 평면 보관한다.
    key_bindings: [MAX_KEY_BINDINGS]KeyBinding = undefined,
    key_binding_count: u8 = 0,

    pub fn terminalFontSpec(self: *const Config) font_spec.Spec {
        return .{
            .size_logical = @floatFromInt(self.font_size_point),
            .cell_width_ratio = self.cell_width_ratio,
            .line_height_ratio = self.line_height_ratio,
        };
    }

    /// `shell_resolved` 는 host 의 `resolveShell` 결과 (process lifetime 보유).
    /// 첫 실행이거나 disk 를 못 읽을 때 memory default `Config.shell` 도 이
    /// 값으로 sync. disk 명시값이 있으면 그 값 그대로 (parse 가 alloc.dupe).
    /// #218 — `shell_resolved` 소유권 인수. 첫 실행 / disk 못 읽음(fail) 경로는
    /// 그대로 보관(+ font_families 도 owned dupe 로 정규화), disk 정상 경로는 parse
    /// 가 JSON 값을 dupe 하므로 안 쓰는 `shell_resolved` 를 free. 결과 Config 는
    /// 모든 경로에서 shell / font_families 가 owned → `deinit` 이 일관 free.
    /// 따라서 `shell_resolved` 는 호출처가 항상 *owned* 로 넘겨야 한다.
    pub fn load(rt: Runtime, allocator: std.mem.Allocator, shell_resolved: []const u8) Config {
        const path = paths.configPath(rt, allocator) catch {
            return defaultOwned(allocator, shell_resolved);
        };
        defer allocator.free(path);

        const loaded = blk: {
            const file = std.Io.Dir.openFileAbsolute(rt.io, path, .{}) catch {
                // #382 — 측정 인스턴스는 **사용자 설정을 만들지 않는다.** config 는 worker 와
                // 공유하지만 (같은 폰트 · 테마로 재야 다른 터미널과의 비교가 성립한다) 그것은
                // *읽기* 까지다. 파일이 없는 기계에서 하네스를 먼저 돌리면 측정 프로세스가
                // 사용자 config 를 만드는 주체가 되는데, 그것은 launcher 의 일이다
                // (`instances.createDefaultConfig` — auto_start · 단축키 동기화까지 함께 한다).
                // 측정은 기본값을 메모리에서만 쓰고 지나간다. **그래서 안내도 없다** —
                // 만들지 않은 것이 정상 동작이다 (#501).
                var fallback = defaultOwned(allocator, shell_resolved);
                if (!instance_context.isStress()) {
                    fallback.load_notice = createDefault(rt, allocator, path, shell_resolved);
                }
                break :blk fallback;
            };
            defer file.close(rt.io);

            var file_reader = file.reader(rt.io, &.{});
            const content = file_reader.interface.allocRemaining(allocator, .limited(64 * 1024)) catch |err| {
                // #501 — 파일이 **있는데 못 읽은 것**이다. 예전에는 파일이 없는 경우와
                // 결과가 같았고 (조용히 기본값) 사용자는 자기 설정이 무시된 이유를 알
                // 방법이 없었다. 64 KiB 상한 초과가 특히 그렇다 — 조용한 절단도 아니고
                // 조용한 **무시** 다.
                var fallback = defaultOwned(allocator, shell_resolved);
                fallback.load_notice = loadNoticeAlloc(allocator, messages.config_read_failed_format, path, err);
                break :blk fallback;
            };
            defer allocator.free(content);

            // disk 정상 — parse 가 JSON 의 shell 을 dupe 하므로 인자는 미사용. 누수 방지 free.
            allocator.free(shell_resolved);
            break :blk parse(rt, allocator, content, path);
        };

        // #431 — 핫키 중복 검사는 **여기 한 곳**이다. `parse` 안에 두면 위의 두 fallback
        // (파일 없음 · 못 읽음) 이 구멍으로 남는다.
        //
        // #510 — 그 두 경로가 예전에 특히 위험했던 이유는 기본값이 index 무관 상수 `F1`
        // 이라 `tildaz --instance 9` 가 config_0 과 **같은 키**로 떴기 때문이다. 이제
        // 기본값이 `F(N+1)` 이라 *기본값끼리는* 겹치지 않는다. 그래도 검사는 그대로 둔다 —
        // 사용자가 config 를 직접 겹치게 고치는 경우가 남고, 애초에 이 검사가 막는 것이
        // 그쪽이다.
        fatalIfHotkeyTakenByLowerIndex(rt, allocator, loaded.hotkey, path);
        return loaded;
    }

    /// **뒤에 있는 것이 양보한다** ([#431](https://github.com/ensky0/tildaz/issues/431)) —
    /// 자기보다 낮은 index 가 같은 전역 핫키를 쓰면 이 인스턴스가 멈춘다. 겹친 두 인스턴스는
    /// 양쪽 다 중복을 감지하므로, 규칙이 없으면 둘 다 안 뜬다.
    ///
    /// 세 platform 이 여기서 함께 덮인다. 전에는 Windows 만 `RegisterHotKey` 실패로 뒤늦게
    /// 걸렸고 (원인이 자기 다른 인스턴스인지 알 수 없는 안내였다), macOS 는 `CGEventTap` 이
    /// 배타 등록이 아니라 **두 인스턴스가 같은 키에 함께 반응**했다.
    fn fatalIfHotkeyTakenByLowerIndex(rt: Runtime, allocator: std.mem.Allocator, hotkey: Hotkey, config_path: []const u8) void {
        // 측정 인스턴스는 전역 핫키를 등록하지 않는다 (#382). worker index 가 없으면
        // (단위 테스트 등) 비교할 자기 자신이 없다.
        if (instance_context.isStress()) return;
        const self_index = instance_context.workerIndex() orelse return;
        const owner = instances.lowerIndexHotkeyConflict(rt, allocator, self_index, hotkey) orelse return;

        // 사용자가 적은 원문 대신 canonical 표기를 쓴다 — fallback 경로에는 원문 자체가 없다.
        var key_buf: [64]u8 = undefined;
        var msg_buf: [384]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            messages.config_hotkey_duplicate_format,
            .{ hotkeyDisplay(&key_buf, hotkey), owner },
        ) catch messages.config_hotkey_duplicate_fallback_msg;
        showConfigFatalMsg(rt, config_path, msg);
    }

    /// #218 — fail 경로 공통: shell 은 인수한 `shell_resolved`(owned) 보관, static
    /// default `font_families` 를 owned dupe 로 정규화 → deinit 이 일관 free.
    ///
    /// #510 — **핫키도 여기서 자기 index 로 맞춘다.** `Config{}` 의 field initializer 는
    /// comptime 이라 index 0 의 키 (`default_hotkey`) 로 고정돼 있는데, 이 함수를 타는
    /// 세 경로 (파일 없음 · 못 읽음 · 경로 조회 실패) 는 모두 *어느 index 인지 아는*
    /// 상태다. 안 맞추면 방금 디스크에 적은 `F2` 와 메모리의 `F1` 이 갈린다 — 그 실행
    /// 동안만 다른 키로 도는, 재시작해야 사라지는 종류의 어긋남이다.
    ///
    /// worker index 가 없는 경우 (단위 테스트) 는 index 0 으로 둔다.
    fn defaultOwned(allocator: std.mem.Allocator, shell_resolved: []const u8) Config {
        var c: Config = .{};
        c.shell = shell_resolved;
        const index = instance_context.workerIndex() orelse 0;
        if (Hotkey.fromString(Defaults.hotkeyFor(index))) |hk| c.hotkey = hk;
        for (c.font_families[0..c.font_family_count]) |*f| {
            f.* = allocator.dupe(u8, f.*) catch f.*;
        }
        return c;
    }

    fn parse(rt: Runtime, allocator: std.mem.Allocator, content: []const u8, config_path: []const u8) Config {
        var config = Config{};
        // #493 — TOML. `toml.Table` 로 받아 **값 트리**를 직접 훑는다. 구조체 매핑을
        // 쓰지 않는 이유는 아래 필드별 오류 메시지다 — 매핑에 맡기면 "어느 필드가 왜
        // 틀렸는지" 가 파서의 일반 오류로 퇴화한다.
        var parser: toml.Parser(toml.Table) = .init(allocator);
        defer parser.deinit();
        var parsed = parser.parseString(content) catch |err| {
            // TOML 파서는 구문 오류의 **위치**를 준다 (JSON 은 오류 이름만 줬다).
            // 사용자가 어디를 고쳐야 할지 알 수 있게 line / col 을 함께 보여 준다.
            //
            // #495 — 경로는 본문에 넣지 않는다. `showConfigFatalMsg` 가 모든 config
            // 오류 앞에 한 번 붙이므로 여기서 넣으면 두 번 나온다. 그리고 그 함수를
            // 지나는 것 자체가 요점이다 — 예전엔 이 경로만 `dialog.showFatal` 을 직접
            // 불러 형식이 갈라졌다.
            var buf: [256]u8 = undefined;
            const msg = if (parser.error_info) |info| switch (info) {
                .parse => |pos| std.fmt.bufPrint(
                    &buf,
                    messages.config_parse_failed_at_format,
                    .{ pos.line, pos.pos, @errorName(err) },
                ) catch messages.config_parse_failed_fallback_msg,
                .struct_mapping => std.fmt.bufPrint(
                    &buf,
                    messages.config_parse_failed_format,
                    .{@errorName(err)},
                ) catch messages.config_parse_failed_fallback_msg,
            } else std.fmt.bufPrint(
                &buf,
                messages.config_parse_failed_format,
                .{@errorName(err)},
            ) catch messages.config_parse_failed_fallback_msg;
            showConfigFatalMsg(rt, config_path, msg);
        };
        defer parsed.deinit();

        // TOML 문서의 최상위는 **항상 테이블**이라 JSON 의 "top-level must be object"
        // 검사가 필요 없다. 그 자리를 파서가 문법으로 보장한다.
        const root: toml.Value = .{ .table = &parsed.value };

        // font.family / font.glyph_fallback 의 type 만 우선 사전 체크 —
        // validateStructure 의 일반 missing-key / type-mismatch 메시지보다 schema
        // 의도 (primary single string + glyph fallback list) 를 명확히 안내.
        if (true) {
            if (root.table.get("font")) |fv_pre| {
                if (fv_pre == .table) {
                    if (fv_pre.table.get("family")) |fam_v| {
                        if (fam_v != .string) font_validate.showFamilyMustBeStringFatal(rt);
                    }
                    if (fv_pre.table.get("glyph_fallback")) |fb_v| {
                        if (fb_v != .array) font_validate.showGlyphFallbackMustBeListFatal(rt);
                        for (fb_v.array.items) |item| {
                            if (item != .string) font_validate.showGlyphFallbackMustBeListFatal(rt);
                        }
                    }
                }
            }
        }

        // Schema 검증 — `defaultConfigToml` 과 비교 (key set + nested 구조 + type).
        // shell 인자는 schema 검증 시 *값* 무관 — `Defaults.shell` 한 번 사용.
        const default_doc = schemaReferenceToml(allocator) catch unreachable;
        defer allocator.free(default_doc);
        var default_parser: toml.Parser(toml.Table) = .init(allocator);
        defer default_parser.deinit();
        var default_parsed = default_parser.parseString(default_doc) catch unreachable;
        defer default_parsed.deinit();
        const default_root: toml.Value = .{ .table = &default_parsed.value };
        validateStructure(rt, root, default_root, "(top-level)", config_path);

        // #533 — input section. macOS 만 값을 쓰지만 세 platform 이 같은 파일을
        // 읽을 수 있어야 해서 어디서든 파싱한다 (`MacOptionAsAlt` 주석 참고).
        if (root.table.get("input")) |iv| {
            if (iv.table.get("macos_option_as_alt")) |v| {
                if (MacOptionAsAlt.fromString(v.string)) |mode| {
                    config.macos_option_as_alt = mode;
                } else {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(
                        &buf,
                        messages.config_macos_option_as_alt_invalid_format,
                        .{v.string},
                    ) catch messages.config_macos_option_as_alt_invalid_fallback_msg;
                    showConfigFatalMsg(rt, config_path, msg);
                }
            }
        }

        // window section
        if (root.table.get("window")) |wv| {
            if (wv.table.get("dock_position")) |v| {
                if (DockPosition.fromString(v.string)) |dp| {
                    config.dock_position = dp;
                } else {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(
                        &buf,
                        messages.config_dock_position_invalid_format,
                        .{v.string},
                    ) catch messages.config_dock_position_invalid_fallback_msg;
                    showConfigFatalMsg(rt, config_path, msg);
                }
            }
            if (wv.table.get("width_percent")) |v| {
                const f = parseFloat(v) orelse showConfigFatal(rt, config_path, messages.config_field_number_required_format, .{"window.width_percent"});
                if (f < 1.0 or f > 100.0) showConfigFatal(rt, config_path, messages.config_field_range_required_format, .{ "window.width_percent", "1..100" });
                config.width_percent = f;
            }
            if (wv.table.get("height_percent")) |v| {
                const f = parseFloat(v) orelse showConfigFatal(rt, config_path, messages.config_field_number_required_format, .{"window.height_percent"});
                if (f < 1.0 or f > 100.0) showConfigFatal(rt, config_path, messages.config_field_range_required_format, .{ "window.height_percent", "1..100" });
                config.height_percent = f;
            }
            if (wv.table.get("offset_percent")) |v| {
                const f = parseFloat(v) orelse showConfigFatal(rt, config_path, messages.config_field_number_required_format, .{"window.offset_percent"});
                if (f < 0.0 or f > 100.0) showConfigFatal(rt, config_path, messages.config_field_range_required_format, .{ "window.offset_percent", "0..100" });
                config.offset_percent = f;
            }
            if (wv.table.get("opacity_percent")) |v| {
                const f = parseFloat(v) orelse showConfigFatal(rt, config_path, messages.config_field_number_required_format, .{"window.opacity_percent"});
                if (f < 0.0 or f > 100.0) showConfigFatal(rt, config_path, messages.config_field_range_required_format, .{ "window.opacity_percent", "0..100" });
                config.opacity_alpha = @round(f * 255.0 / 100.0);
            }
        }

        // theme
        if (root.table.get("theme")) |v| {
            if (v.string.len > 0) {
                config.theme = themes.findTheme(v.string);
                if (config.theme == null) {
                    var buf: [512]u8 = undefined;
                    var fbs: std.Io.Writer = .fixed(&buf);
                    const w = &fbs;
                    w.print(messages.config_unknown_theme_header_format, .{v.string}) catch {};
                    for (themes.themes, 0..) |t, i| {
                        if (i > 0) w.writeAll(", ") catch {};
                        w.writeAll(t.name) catch {};
                    }
                    showConfigFatalMsg(rt, config_path, fbs.buffered());
                }
            }
        }

        // hotkey
        if (root.table.get("hotkey")) |v| {
            if (Hotkey.fromString(v.string)) |h| {
                config.hotkey = h;
            } else {
                // #484 — 거부 이유별로 다른 안내를 보낸다. 한 메시지로 묶으면
                // modifier 를 이미 준 사용자에게 "modifier 를 달라" 고 말하게 된다.
                // `bufPrint` 의 format 은 comptime 이라 분기 안에서 각각 포맷한다.
                var buf: [768]u8 = undefined;
                const msg = switch (hotkeyFailure(v.string).?) {
                    .unknown_key => std.fmt.bufPrint(&buf, messages.config_hotkey_unknown_key_format, .{v.string}) catch
                        messages.config_hotkey_unknown_key_fallback_msg,
                    .modifier_required => std.fmt.bufPrint(&buf, messages.config_hotkey_invalid_format, .{v.string}) catch
                        messages.config_hotkey_invalid_fallback_msg,
                    // #496 1-c — **여기는 `unreachable` 이었다.** 전역 `hotkey` 가 위치
                    // 표기를 아예 안 받던 시절의 전제였는데 1-c 가 그것을 받게 하면서
                    // 깨졌다. ReleaseFast 는 안전 검사가 없어 크래시 대신 위의
                    // `modifier_required` 안내로 떨어졌고, `ctrl` 을 이미 준 사용자에게
                    // "modifier 를 달라" 고 말했다 (macOS 실기 확인) — 바로 위 주석이
                    // 막으려던 실패다.
                    .position_aliased_on_macos => std.fmt.bufPrint(&buf, messages.config_hotkey_position_aliased_format, .{v.string}) catch
                        messages.config_hotkey_position_aliased_fallback_msg,
                    .position_absent_on_macos => std.fmt.bufPrint(&buf, messages.config_hotkey_position_absent_format, .{v.string}) catch
                        messages.config_hotkey_position_absent_fallback_msg,
                };
                showConfigFatalMsg(rt, config_path, msg);
            }
        }

        // shell
        if (root.table.get("shell")) |v| {
            if (v.string.len > 0) {
                config.shell = allocator.dupe(u8, v.string) catch v.string;
            } else {
                config.shell = "";
            }
        }

        // auto_start / hidden_start
        if (root.table.get("auto_start")) |v| config.auto_start = v.boolean;
        if (root.table.get("hidden_start")) |v| config.hidden_start = v.boolean;

        // max_scroll_lines
        if (root.table.get("max_scroll_lines")) |v| {
            if (v.integer < 100 or v.integer > 10_000_000) {
                showConfigFatal(rt, config_path, messages.config_field_integer_range_required_format, .{ "max_scroll_lines", "100..10_000_000" });
            }
            config.max_scroll_lines = @intCast(v.integer);
        }

        // font section — schema validateStructure 로 family / size_point /
        // cell_width_ratio / line_height_ratio 모두 required + type 검증 끝남.
        // 여기서는 value range + parse.
        const fv = root.table.get("font").?;
        if (fv.table.get("size_point")) |v| {
            if (v.integer < 8 or v.integer > 72) {
                showConfigFatal(rt, config_path, messages.config_field_integer_range_required_format, .{ "font.size_point", "8..72" });
            }
            config.font_size_point = @intCast(v.integer);
        }
        if (fv.table.get("cell_width_ratio")) |v| {
            const f = parseFloat(v) orelse showConfigFatal(rt, config_path, messages.config_field_number_required_format, .{"font.cell_width_ratio"});
            if (f < 0.5 or f > 2.0) showConfigFatal(rt, config_path, messages.config_field_range_required_format, .{ "font.cell_width_ratio", "0.5..2.0" });
            config.cell_width_ratio = f;
        }
        if (fv.table.get("line_height_ratio")) |v| {
            const f = parseFloat(v) orelse showConfigFatal(rt, config_path, messages.config_field_number_required_format, .{"font.line_height_ratio"});
            if (f < 0.5 or f > 2.0) showConfigFatal(rt, config_path, messages.config_field_range_required_format, .{ "font.line_height_ratio", "0.5..2.0" });
            config.line_height_ratio = f;
        }
        // font.family — primary, single string. type 은 사전 체크에서 이미
        // 보장됨 (위 font_validate.showFamilyMustBeStringFatal). 여기서는 빈
        // 문자열만 reject + chain[0] 에 저장.
        var chain_count: usize = 0;
        if (fv.table.get("family")) |v| {
            if (v.string.len == 0) showConfigFatalMsg(rt, config_path, messages.config_font_family_empty_msg);
            config.font_families[0] = allocator.dupe(u8, v.string) catch v.string;
            chain_count = 1;
        }

        // font.glyph_fallback — array of strings. type / element 모두 사전
        // 체크 보장. 빈 array 는 허용 (system fallback 만 의존). chain[1..] 에
        // 저장. chain 총 길이 (1 + fallback) 가 MAX_FONT_FAMILIES 초과 시 fatal —
        // silent truncate 방지.
        if (fv.table.get("glyph_fallback")) |v| {
            for (v.array.items) |item| {
                if (item.string.len == 0) continue;
                if (chain_count >= MAX_FONT_FAMILIES) {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(
                        &buf,
                        messages.config_font_chain_too_long_format,
                        .{MAX_FONT_FAMILIES},
                    ) catch messages.config_font_chain_too_long_fallback_msg;
                    showConfigFatalMsg(rt, config_path, msg);
                }
                config.font_families[chain_count] = allocator.dupe(u8, item.string) catch item.string;
                chain_count += 1;
            }
        }

        var i = chain_count;
        while (i < MAX_FONT_FAMILIES) : (i += 1) config.font_families[i] = "";
        config.font_family_count = @intCast(chain_count);

        parseKeys(rt, root, config_path, &config);

        return config;
    }

    /// #493 — `[keys]` 파싱. 액션 → 키 리스트를 읽어 **키 → 액션** 평면 배열로
    /// 뒤집는다 (런타임 조회 방향이 그쪽이다).
    ///
    /// 액션 → 키 방향을 택한 대가로 **충돌 감지가 우리 몫**이다. 키 → 액션이었다면
    /// 같은 키가 두 번 나오는 순간 TOML 파서가 중복 키로 잡지만, 이 방향에서는
    /// `new_tab` 과 `open_config` 에 둘 다 `ctrl+shift+t` 를 적어도 문법상 정상이다.
    ///
    /// `[keys]` 자체가 없거나 특정 액션이 빠져 있으면 **기본값으로 채운다** (결정 2).
    /// 정상 상태에서는 생성기가 모든 액션을 적으므로 이 경로는 버전 업그레이드 뒤의
    /// 안전망이다.
    fn parseKeys(rt: Runtime, root: toml.Value, config_path: []const u8, config: *Config) void {
        const keys_table: ?*toml.Table = if (root.table.get("keys")) |kv|
            (if (kv == .table) kv.table else null)
        else
            null;

        var count: usize = 0;
        for (std.enums.values(KeyAction)) |action| {
            const name = action.configName();

            // 이 액션의 키 목록. 파일에 있으면 그것을, 없으면 기본값을 쓴다.
            var from_file: ?*toml.ValueList = null;
            if (keys_table) |kt| {
                if (kt.get(name)) |v| {
                    if (v != .array) {
                        var buf: [512]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, messages.config_key_not_list_format, .{ name, name }) catch
                            messages.config_key_not_list_fallback_msg;
                        showConfigFatalMsg(rt, config_path, msg);
                    }
                    from_file = v.array;
                }
            }

            if (from_file) |list| {
                for (list.items) |item| {
                    if (item != .string) {
                        var buf: [512]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, messages.config_key_not_list_format, .{ name, name }) catch
                            messages.config_key_not_list_fallback_msg;
                        showConfigFatalMsg(rt, config_path, msg);
                    }
                    count = addBinding(rt, config, count, action, item.string, config_path);
                }
            } else {
                for (defaultBindings(action)) |text| {
                    count = addBinding(rt, config, count, action, text, config_path);
                }
            }
        }
        config.key_binding_count = @intCast(count);
    }

    /// 키 문자열 하나를 파싱해 배열에 넣는다. 이미 같은 키가 있으면 **양쪽 액션을
    /// 짚어** fatal.
    fn addBinding(
        rt: Runtime,
        config: *Config,
        count: usize,
        action: KeyAction,
        text: []const u8,
        config_path: []const u8,
    ) usize {
        const parsed = switch (parseHotkeyString(text, .app_binding)) {
            .ok => |v| v,
            .unknown_key => {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, messages.config_key_invalid_format, .{ action.configName(), text }) catch
                    messages.config_key_invalid_fallback_msg;
                showConfigFatalMsg(rt, config_path, msg);
            },
            .modifier_required => {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, messages.config_key_needs_modifier_format, .{ action.configName(), text }) catch
                    messages.config_key_needs_modifier_fallback_msg;
                showConfigFatalMsg(rt, config_path, msg);
            },
            // #496 — macOS 에서만 나온다. 겹침 / 부재를 갈라 다른 안내를 준다.
            .position_aliased_on_macos => {
                var buf: [640]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, messages.config_key_position_aliased_format, .{ action.configName(), text }) catch
                    messages.config_key_position_aliased_fallback_msg;
                showConfigFatalMsg(rt, config_path, msg);
            },
            .position_absent_on_macos => {
                var buf: [640]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, messages.config_key_position_absent_format, .{ action.configName(), text }) catch
                    messages.config_key_position_absent_fallback_msg;
                showConfigFatalMsg(rt, config_path, msg);
            },
        };
        const hotkey = Hotkey.fromParsed(parsed);

        for (config.key_bindings[0..count]) |existing| {
            if (std.meta.eql(existing.hotkey, hotkey)) {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, messages.config_key_conflict_format, .{
                    text,
                    existing.action.configName(),
                    action.configName(),
                }) catch messages.config_key_conflict_fallback_msg;
                showConfigFatalMsg(rt, config_path, msg);
            }
        }

        if (count >= MAX_KEY_BINDINGS) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, messages.config_key_too_many_format, .{MAX_KEY_BINDINGS}) catch
                messages.config_key_too_many_fallback_msg;
            showConfigFatalMsg(rt, config_path, msg);
        }
        config.key_bindings[count] = .{ .hotkey = hotkey, .action = action };
        return count + 1;
    }

    /// #501 — 실패를 **삼키지 않는다.** 예전에는 세 실패가 모두 `catch return` /
    /// `catch {}` 였고, 그래서 첫 실행에서 config 를 못 만든 사용자는 아무 안내도 없이
    /// 기본값으로 도는 인스턴스를 얻었다. 다음 실행에도 파일이 없으니 같은 일이
    /// 반복되고, 증상은 "설정을 고쳐도 저장되지 않는다" 로 보인다.
    ///
    /// 반환값 = 사용자에게 보여줄 문장 (owned) 또는 null (성공). 여기서 다이얼로그를
    /// 띄우지 않는 이유는 `Config.load_notice` 주석 참고 — Linux 에서 이 시점의
    /// 다이얼로그는 보이지 않는다.
    fn createDefault(
        rt: Runtime,
        allocator: std.mem.Allocator,
        path: []const u8,
        shell_resolved: []const u8,
    ) ?[]const u8 {
        const file = std.Io.Dir.createFileAbsolute(rt.io, path, .{}) catch |err| {
            // 파일 생성 실패의 대개는 디렉터리가 없거나 쓸 수 없는 것이다
            // (`paths.configPath` 가 `createDirPath` 를 이미 시도한 뒤다).
            return loadNoticeAlloc(allocator, messages.config_dir_create_failed_format, path, err);
        };
        defer file.close(rt.io);
        // #510 — 이 경로가 정확히 그 사고 지점이다. `tildaz --instance 1` 처럼 config
        // 없는 index 로 직접 띄우면 여기서 파일이 생기는데, 예전에는 index 와 무관한
        // `F1` 이 적혀 config_0 과 겹쳤다. `path` 는 이미 그 index 로 만들어졌으니
        // (`paths.configPath`) 핫키도 같은 index 에서 파생한다.
        const doc = defaultConfigToml(allocator, shell_resolved, Defaults.hotkeyFor(instance_context.requireWorkerIndex())) catch |err| {
            return loadNoticeAlloc(allocator, messages.config_default_write_failed_format, path, err);
        };
        defer allocator.free(doc);
        file.writeStreamingAll(rt.io, doc) catch |err| {
            return loadNoticeAlloc(allocator, messages.config_default_write_failed_format, path, err);
        };
        return null;
    }

    /// #218 — `load` 가 owned 로 정규화한 `shell` / `font_families` 해제. 모든
    /// load 경로(첫 실행 fail 포함)가 owned 라 일관 free (빈 문자열은 len 0 → skip).
    /// host loop 종료 후 호출 (Linux `run` / Windows `main`). macOS 는 terminate
    /// 가 exit 직행이라 미호출 — at-exit OS 회수 (leak detect 미작동).
    pub fn deinit(self: *const Config, allocator: std.mem.Allocator) void {
        // #501 — `showLoadNotice` 는 필드만 비우고 해제하지 않는다 (host 마다 호출
        // 시점이 달라 이중 해제 위험). 여기서 한 번 해제한다.
        if (self.load_notice) |n| allocator.free(n);
        if (self.shell.len > 0) allocator.free(self.shell);
        for (self.font_families[0..self.font_family_count]) |f| {
            if (f.len > 0) allocator.free(f);
        }
    }

    /// Windows 만 사용하는 helper — UTF-8 `font_families[index]` 를 Win32 가
    /// 받는 UTF-16 null-terminated string 으로 변환. chain entry 별 별도 static
    /// buffer 라 process 전체 lifetime 동안 안정적인 포인터 (호출처가 보관해도
    /// 안전). DWriteFontContext / 검증 loop 가 이 포인터를 들고 있어도 OK.
    ///
    /// 이전 버전은 6 개 hardcoded 폰트 이름만 if-eql 로 인식하고 그 외엔 모두
    /// `"Consolas"` literal 반환 — 사용자가 `"JetBrains Mono"` 같은 일반 코딩
    /// 폰트를 적어도 시스템에 설치되어 있는지와 무관하게 결과는 Consolas. 같은
    /// 패턴이 `windowsShellUtf16` 에도 있었고 commit `836fe97` 에서 fix. font 도 같이.
    pub fn windowsFontFamilyUtf16(self: *const Config, index: u8) [*:0]const WCHAR {
        if (!is_windows) @compileError("windowsFontFamilyUtf16 is Windows-only");
        const S = struct {
            var bufs: [MAX_FONT_FAMILIES][512]u16 = undefined;
        };
        if (index >= self.font_family_count or index >= MAX_FONT_FAMILIES) {
            return std.unicode.utf8ToUtf16LeStringLiteral("Consolas");
        }
        const family = self.font_families[index];
        const buf = &S.bufs[index];
        const reserve_for_null = 1;
        const max_in = buf.len - reserve_for_null;
        const written = std.unicode.utf8ToUtf16Le(buf[0..max_in], family) catch {
            return std.unicode.utf8ToUtf16LeStringLiteral("Consolas");
        };
        buf[written] = 0;
        return buf[0..written :0].ptr;
    }

    /// Windows 만 — `config.shell` (UTF-8) 을 `CreateProcessW` 가 받는 UTF-16
    /// null-terminated string 으로 변환. 함수-local static buffer 에 한 번 변환
    /// 후 그 포인터 반환 — process 전체 lifetime. 단일 startup 콜만 가정 (host
    /// 가 SessionCore.init 에 한 번 넘김), 이후 SessionCore 가 그 포인터 보관.
    ///
    /// 이전 버전은 `_ = self;` + literal "cmd.exe" 만 반환해서 사용자가 config
    /// 의 `"shell"` 값을 바꿔도 적용 안 되는 사고 (시연 중 발견 — `"wsl.exe -d
    /// Debian --cd ~"` 무시되고 cmd 만 떴음).
    pub fn windowsShellUtf16(self: *const Config) [*:0]const WCHAR {
        if (!is_windows) @compileError("windowsShellUtf16 is Windows-only");
        const S = struct {
            var buf: [1024]u16 = undefined;
        };
        const reserve_for_null = 1;
        const max_in = S.buf.len - reserve_for_null;
        const written = std.unicode.utf8ToUtf16Le(S.buf[0..max_in], self.shell) catch {
            // 비정상 UTF-8 (JSON parser 가 이미 막지만 방어). cmd.exe 로 fallback —
            // 적어도 윈도우는 떠 있게.
            return std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe");
        };
        S.buf[written] = 0;
        return S.buf[0..written :0].ptr;
    }
};

// --- Helpers ---

fn parseFloat(v: toml.Value) ?f32 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => null,
    };
}

/// #495 — 모든 config 오류 메시지의 **단일 조립 지점.** 경로가 첫 줄로 붙는다.
/// 예전엔 파싱 오류가 이 함수를 지나지 않고 자기 본문에 `Path:` 를 직접 넣어,
/// 오류 종류에 따라 경로 위치가 달랐다 (파싱은 셋째 줄, 의미 오류는 맨 끝).
fn configErrorMessageAlloc(allocator: std.mem.Allocator, message: []const u8, config_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, messages.config_error_with_path_format, .{ config_path, message });
}

/// #501 — 로드 실패 안내 한 줄을 조립한다. 실패해도 null 을 주고 넘어간다 — 안내를
/// 만들다 실패해서 시작을 막으면 이 이슈가 고치려는 것과 같은 종류의 실패가 된다.
/// 형식은 #495 와 같다 (경로가 첫 줄).
fn loadNoticeAlloc(
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    config_path: []const u8,
    err: anyerror,
) ?[]const u8 {
    var buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, fmt, .{@errorName(err)}) catch return null;
    return configErrorMessageAlloc(allocator, body, config_path) catch null;
}

/// #501 — host 가 **창이 뜬 뒤** 한 번 부른다. 안내가 없으면 아무 일도 하지 않는다.
///
/// 로드 시점에 바로 띄우지 않는 이유는 Linux 다 — 그때는 Wayland backend 가 없어
/// `dialog.showError` 가 stderr / log 로만 가고, 데스크톱 아이콘이나 autostart 로
/// 띄운 사용자에게는 보이지 않는다. Windows (`MessageBoxW`) 와 macOS
/// (`osascript display dialog`) 는 그 시점에도 보이지만, 그쪽만 즉시로 두면 세
/// platform 의 시점이 갈리고 안내가 두 번 뜰 수 있다. 한 곳으로 모은다 (#296 이
/// 입력 정책을 모은 것과 같은 이유).
///
/// **fatal 이 아니다** — 보여주고 계속 돈다. `showError` 는 반환한다.
pub fn showLoadNotice(rt: Runtime, config: *Config) void {
    const notice = config.load_notice orelse return;
    // 한 번만 보여준다. 소유권은 `deinit` 이 계속 들고 있다 — 여기서 free 하면
    // host 마다 호출 시점이 달라 이중 해제 위험이 생긴다.
    config.load_notice = null;
    showLoadNoticeText(rt, notice);
}

/// Linux host 는 `*const Config` 를 들고 있어 위 함수의 "필드를 비운다" 를 할 수
/// 없다. 대신 자기 one-shot flag 로 한 번만 부른다 — 문안과 로그는 여기 한 곳이라
/// 세 platform 이 같은 안내를 낸다.
pub fn showLoadNoticeText(rt: Runtime, notice: []const u8) void {
    log.appendLine("config", "load failed — running with defaults", .{});
    dialog.showError(rt, messages.config_not_loaded_title, notice);
}

fn showConfigFatalMsg(rt: Runtime, config_path: []const u8, message: []const u8) noreturn {
    const full_message = configErrorMessageAlloc(std.heap.page_allocator, message, config_path) catch
        messages.config_error_with_path_fallback_msg;
    dialog.showFatal(rt, messages.config_error_title, full_message);
}

fn showConfigFatal(rt: Runtime, config_path: []const u8, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch messages.config_error_fallback_msg;
    showConfigFatalMsg(rt, config_path, msg);
}

/// user config 의 구조가 default config 와 일치하는지 재귀 검증:
/// - object: key set 일치 (missing / unknown 양방향) + 각 value 재귀
/// - 그 외 type: tag 일치 (integer ≠ float, string ≠ bool 등)
///
/// value range / 의미 검증은 caller (각 필드 별로 hardcoded — default 만으로는
/// "1..100" 같은 range 표현 불가).
/// #493 — `std.json.Value` 트리 비교에서 `toml.Value` 트리 비교로 옮겼다. 구조는
/// 그대로다: 사용자 문서와 `defaultConfigToml` 을 파싱한 기준 문서를 같은 자리에서
/// 비교해 key set · 중첩 · 타입을 검사한다.
fn validateStructure(rt: Runtime, user: toml.Value, def: toml.Value, ctx: []const u8, config_path: []const u8) void {
    const user_tag = std.meta.activeTag(user);
    const def_tag = std.meta.activeTag(def);
    if (user_tag != def_tag) {
        const both_numeric = (user_tag == .integer or user_tag == .float) and
            (def_tag == .integer or def_tag == .float);
        if (!both_numeric) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                messages.config_type_mismatch_format,
                .{ ctx, @tagName(def_tag), @tagName(user_tag) },
            ) catch messages.config_type_mismatch_fallback_msg;
            showConfigFatalMsg(rt, config_path, msg);
        }
    }

    if (user_tag != .table) return;

    var def_iter = def.table.iterator();
    while (def_iter.next()) |entry| {
        const key = entry.key_ptr.*;
        if (user.table.get(key) == null) {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                messages.config_missing_key_format,
                .{ key, ctx },
            ) catch messages.config_missing_key_fallback_msg;
            showConfigFatalMsg(rt, config_path, msg);
        }
    }

    var user_iter = user.table.iterator();
    while (user_iter.next()) |entry| {
        const key = entry.key_ptr.*;
        if (def.table.get(key) == null) {
            // #493 — `_` prefix key 를 주석 대용으로 허용하던 예외를 없앴다 (#173).
            // JSON 에 주석이 없어서 두었던 우회인데, TOML 은 `#` 으로 진짜 주석을
            // 쓸 수 있으므로 필요가 사라졌다. 남겨 두면 `_shell` 같은 오타가 조용히
            // 무시돼 "왜 설정이 안 먹지" 가 된다 — 모르는 key 는 전부 알린다.
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                messages.config_unknown_key_format,
                .{ key, ctx },
            ) catch messages.config_unknown_key_fallback_msg;
            showConfigFatalMsg(rt, config_path, msg);
        }
    }

    var rec_iter = def.table.iterator();
    while (rec_iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const u_val = user.table.get(key).?;
        var path_buf: [256]u8 = undefined;
        const path = if (std.mem.eql(u8, ctx, "(top-level)"))
            std.fmt.bufPrint(&path_buf, "{s}", .{key}) catch key
        else
            std.fmt.bufPrint(&path_buf, "{s}.{s}", .{ ctx, key }) catch key;
        validateStructure(rt, u_val, entry.value_ptr.*, path, config_path);
    }
}

// --- Tests ---

test "#501 config 를 만들지 못하면 안내를 만들고 시작을 막지 않는다" {
    const allocator = std.testing.allocator;
    const rt: Runtime = .{ .io = std.testing.io, .environ = .empty };

    // 존재하지 않는 디렉터리 아래 — `createFileAbsolute` 가 실패한다. 실제 config
    // 경로를 건드리지 않으므로 이 test 는 사용자 파일에 영향이 없다.
    const path = "/tildaz-test-nonexistent-dir-9f3a/config_0.toml";
    const notice = Config.createDefault(rt, allocator, path, "/bin/bash");

    // **안내가 만들어져야 한다.** 예전에는 `catch return` 으로 삼켜서 사용자가 아무
    // 것도 못 받았고, 다음 실행에도 같은 일이 반복됐다.
    try std.testing.expect(notice != null);
    defer allocator.free(notice.?);

    // #495 형식 — 경로가 첫 줄이다.
    try std.testing.expect(std.mem.startsWith(u8, notice.?, "Config: " ++ path));
    // **결과 상태를 말해야 한다.** 오류만 알려 주고 "그래서 지금 어떤 상태인가" 를
    // 빼면 사용자는 자기 설정이 적용됐는지 모른 채 쓰게 된다 — 이 이슈의 원래 증상과
    // 사실상 같아진다.
    try std.testing.expect(std.mem.indexOf(u8, notice.?, "default settings") != null);
}

test "#501 안내는 Config 소유이고 deinit 이 정확히 한 번 해제한다" {
    const allocator = std.testing.allocator;

    // `Config{}` 를 그대로 deinit 할 수 없다 — 기본값이 comptime 리터럴이라 `deinit`
    // 이 static 메모리를 free 한다. `load` 경로는 `defaultOwned` 로 owned 로 만든
    // 뒤에만 deinit 대상이 된다 (그 함수 주석의 "모든 load 경로가 owned").
    const shell = try allocator.dupe(u8, "/bin/bash");
    var config = Config.defaultOwned(allocator, shell);
    config.load_notice = try allocator.dupe(u8, "Config: /x");

    // `showLoadNotice` 는 필드만 비우고 **해제하지 않는다** — host 마다 호출 시점이
    // 달라 거기서 해제하면 이중 해제 위험이 생긴다. 해제는 `deinit` 한 곳이다.
    // testing allocator 가 leak 과 double-free 를 잡으므로 이 test 가 그 계약을
    // 고정한다.
    allocator.free(config.load_notice.?);
    config.load_notice = null;
    config.deinit(allocator);
}

test "#316 · #495 config 오류는 경로를 첫 줄에 정확히 한 번 담는다" {
    const message = try configErrorMessageAlloc(
        std.testing.allocator,
        messages.config_font_family_empty_msg,
        "/home/user/.config/tildaz/config_7.toml",
    );
    defer std.testing.allocator.free(message);

    // #495 — 경로가 **첫 줄**이다. 사용자가 오류 내용을 읽기 전에 눈에 들어와야 한다.
    try std.testing.expectEqualStrings(
        "Config: /home/user/.config/tildaz/config_7.toml\n\n" ++
            "Configuration: \"font.family\" must not be empty.",
        message,
    );
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, message, "/home/user/.config/tildaz/config_7.toml"));
}

test "#316 · #495 어떤 오류 종류든 경로가 같은 자리에 온다" {
    const bodies = [_][]const u8{
        // 파싱 오류도 이제 같은 형식을 지난다 — 예전엔 자기 본문에 `Path:` 를 넣었다.
        "Failed to parse config file.\n\nLine 12, column 3\nError: UnexpectedToken",
        "Failed to parse config file.\n\nError: UnexpectedToken",
        "Configuration: failed to parse \"hotkey\" value \"plain-t\".",
        "Configuration: \"window.width_percent\" must be a number.",
        "Configuration: unknown theme \"Missing\"\n\nAvailable themes:\nTilda",
        "Configuration: missing required key \"font\" in (top-level).",
        "Configuration: unknown key \"extra\" in (top-level).",
    };
    const config_paths = [_][]const u8{
        "/home/user/.config/tildaz/config_0.toml",
        "/Users/user/.config/tildaz/config_3.toml",
        "C:\\Users\\user\\AppData\\Roaming\\tildaz\\config_12.toml",
    };

    for (bodies) |body| {
        for (config_paths) |config_path| {
            const message = try configErrorMessageAlloc(std.testing.allocator, body, config_path);
            defer std.testing.allocator.free(message);
            // 경로가 앞, 본문이 뒤 — 순서가 뒤집혔다 (#495).
            try std.testing.expect(std.mem.startsWith(u8, message, "Config: "));
            try std.testing.expect(std.mem.endsWith(u8, message, body));
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, message, config_path));
        }
    }

    // 긴 경로도 잘리지 않는다 — 조립이 `allocPrint` 라 상한이 없다. 경로가 앞으로
    // 옮겨졌으므로 이제 `startsWith` 로 본다 (#495).
    var long_path: [5000]u8 = undefined;
    @memset(&long_path, 'x');
    const long_message = try configErrorMessageAlloc(std.testing.allocator, messages.config_error_fallback_msg, &long_path);
    defer std.testing.allocator.free(long_message);
    try std.testing.expect(std.mem.startsWith(u8, long_message, "Config: " ++ ("x" ** 5000)));
    try std.testing.expect(std.mem.endsWith(u8, long_message, messages.config_error_fallback_msg));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, long_message, &long_path));
}

test "DockPosition.fromString" {
    try std.testing.expectEqual(DockPosition.top, DockPosition.fromString("top").?);
    try std.testing.expectEqual(DockPosition.bottom, DockPosition.fromString("bottom").?);
    try std.testing.expectEqual(@as(?DockPosition, null), DockPosition.fromString("nope"));
}

test "terminal font defaults use the cross-platform logical size contract" {
    const config = Config{};
    const spec = config.terminalFontSpec();

    try std.testing.expectEqual(@as(u8, 15), Defaults.font_size_point);
    try std.testing.expectEqual(@as(f32, @floatFromInt(Defaults.font_size_point)), spec.size_logical);
    try std.testing.expectEqual(@as(f32, 1.0), spec.cell_width_ratio);
    try std.testing.expectEqual(@as(f32, 1.1), spec.line_height_ratio);
}

test "default config TOML uses the common terminal font defaults" {
    const allocator = std.testing.allocator;
    const doc = try schemaReferenceToml(allocator);
    defer allocator.free(doc);

    var parser: toml.Parser(toml.Table) = .init(allocator);
    defer parser.deinit();
    var parsed = try parser.parseString(doc);
    defer parsed.deinit();

    const font = parsed.value.get("font").?.table;
    try std.testing.expectEqual(@as(i64, 15), font.get("size_point").?.integer);
    try std.testing.expectEqual(@as(f64, 1.1), font.get("line_height_ratio").?.float);

    // #493 — 확정한 키 순서 (결정 10) 를 문서 자체로 고정한다. 순서가 흐트러지면
    // "부르는 법 → 안에서 도는 것 → 언제 뜨는가 → 어떻게 보이는가 → 한계" 의 의도가
    // 사라진다. TOML 은 파싱이 순서와 무관하므로 파싱 결과로는 잡히지 않는다.
    const order = [_][]const u8{
        "hotkey", "shell", "auto_start", "hidden_start", "theme", "max_scroll_lines",
        "[window]", "[font]",
    };
    var at: usize = 0;
    for (order) |needle| {
        const found = std.mem.findPos(u8, doc, at, needle) orelse return error.TestUnexpectedResult;
        at = found + needle.len;
    }
    // 최상위 스칼라가 테이블 헤더보다 뒤에 오면 TOML 이 그 테이블 소속으로 해석한다.
    const first_header = std.mem.find(u8, doc, "[window]").?;
    try std.testing.expect(std.mem.find(u8, doc, "max_scroll_lines").? < first_header);
}

test "explicit line height ratio is preserved when parsing" {
    const allocator = std.testing.allocator;
    const json_text = @constCast(try schemaReferenceToml(allocator));
    defer allocator.free(json_text);

    const expected = "line_height_ratio = 1.1";
    const offset = std.mem.find(u8, json_text, expected) orelse return error.TestUnexpectedResult;
    const value_offset = offset + expected.len - 3;
    @memcpy(json_text[value_offset .. value_offset + 3], "0.9");

    // #451 — 정상 문서라 `parse` 가 fatal 경로 (config 경로 조회) 로 가지 않는다.
    // 그래서 `Environ.empty` 로 두어 테스트가 기계의 환경에 안 묶이게 한다.
    const rt: Runtime = .{ .io = std.testing.io, .environ = .empty };
    const config = Config.parse(rt, allocator, json_text, "/tmp/config_0.toml");
    defer config.deinit(allocator);
    try std.testing.expectEqual(@as(f32, 0.9), config.line_height_ratio);
}
