//! #533 — 키 입력을 자식 프로세스로 보낼 바이트로 바꾼다.
//!
//! 세 host 가 native 이벤트에서 뽑은 정보를 `Event` 에 담아 주면, 여기서
//! ghostty 의 `input.encodeKey` 를 불러 바이트를 만든다. **인코딩 표를 우리가
//! 갖지 않는다** — `Alt` 앞의 `ESC`, 화살표·기능키의 CSI modifier, DEC mode
//! (cursor keys / keypad / DECBKM …), kitty keyboard protocol 이 전부 그 함수
//! 안에 있다.
//!
//! 이전에는 host 마다 escape sequence 를 직접 적고 있었다 — Linux 는
//! `processKeyEvent`, macOS 는 `keyDown` 과 `imeDoCommand` **두 곳**, Windows 는
//! `window.zig`. 네 곳 어디도 modifier 를 싣지 않아서 `Alt+a` 가 `a` 로 나갔고
//! (#533 신고), `Shift+←` · `Alt+←` 도 함께 나가지 않았다.
//!
//! ## 마우스는 왜 같은 방법을 못 썼나
//!
//! `mouse_encode.Options` 가 `size: renderer_size.Size` 를 필수 필드로 요구하는데
//! 그 타입을 `ghostty-vt` 가 노출하지 않는다. 함수(`encodeMouse`)는 잡히지만 인자를
//! 만들 수 없어 [`mouse_report.zig`](mouse_report.zig) 는 직접 구현했다. **키는 그
//! 제약이 없다** — `key_encode.zig` 는 renderer 를 전혀 참조하지 않아서 필요한 타입이
//! 모두 노출돼 있다.
//!
//! ## host 가 채워야 하는 것
//!
//! `utf8` 과 `consumed_mods` 가 정책의 핵심이다. OS · xkb 가 **이미 문자를 만들어 준**
//! 조합(프랑스 자판의 `AltGr+2` → `~`, macOS 의 `Option+a` → `å`)은 그 문자를 그대로
//! 보내야 하고 `ESC` 를 붙이면 안 된다. 그 판정을 인코더가 할 수 있도록, 문자를 만드는
//! 데 쓰인 modifier 를 `consumed_mods` 에 표시해 준다.

const std = @import("std");
const builtin = @import("builtin");
const ghostty = @import("ghostty-vt");
const physical_key = @import("physical_key.zig");

/// ghostty 의 modifier 집합을 그대로 쓴다. 이 모듈은 어차피 ghostty 에 의존하므로
/// (`mouse_report.zig` 와 달리) 같은 shape 를 다시 정의하지 않는다.
pub const Mods = ghostty.input.KeyMods;

/// 눌림 · 반복 · 뗌. #538 — 그 전에는 `repeat: bool` 뿐이었고 그마저 세팅하는 자리가
/// 없어서 **세 갈래가 전부 `.press` 로** 인코딩됐다.
pub const Action = ghostty.input.KeyAction;

/// 인코딩 옵션. 8 개 중 7 개는 `fromTerminal` 이 터미널 상태에서 뽑아 주고,
/// `macos_option_as_alt` 만 앱 config 가 정한다 (터미널이 알 수 없는 값).
pub const Options = ghostty.input.KeyEncodeOptions;

/// host 가 native 키 이벤트에서 뽑아 채우는 값.
pub const Event = struct {
    /// 물리 키 위치. `physical_key.fromEvdev` / `fromScanCode` / `fromMacKeyCode`
    /// 의 결과를 그대로 넣는다. 모르는 키는 `null` — 그러면 `utf8` 만으로 인코딩된다.
    code: ?physical_key.PhysicalCode = null,

    /// 지금 눌려 있는 modifier.
    mods: Mods = .{},

    /// `utf8` 을 만드는 데 **쓰인** modifier. 여기 표시된 것은 인코더가 다시 세지
    /// 않는다 — `AltGr+2` 가 `~` 를 냈다면 alt 를 여기 넣어야 `ESC~` 가 되지 않는다.
    /// `utf8` 이 비어 있으면 의미 없는 값이다.
    consumed_mods: Mods = .{},

    /// 이 키가 만든 글자. 없으면 빈 문자열.
    ///
    /// **제어문자를 넣지 않는다.** OS 는 `Ctrl+A` 에 `"\x01"` 을 주지만, 인코더가 기대하는
    /// 것은 **Ctrl 을 뺀 글자** (`"a"`) 다. 제어문자를 그대로 넣으면 "글자에 ctrl 이
    /// 붙었다" 로 보고 CSI u 로 감싸고, 비워서 넣으면 인코더가 **물리 키의 US 글자**로
    /// 제어문자를 만든다 — AZERTY 의 `Ctrl+A`(물리 `Q` 자리) 가 `\x11` XOFF 가 되고
    /// Dvorak 의 `Ctrl+C` 는 SIGINT 를 잃는다. 세 host 가 각자 그 변환을 한다
    /// (Linux 는 keysym, macOS · Windows 는 Ctrl 을 뺀 재번역).
    utf8: []const u8 = "",

    /// 수식키를 다 뗀 글자의 코드포인트 (`Shift+a` 면 `'a'`).
    ///
    /// **kitty keyboard protocol 에서 press 마다 필요하다.** 그 프로토콜은 글자 키의
    /// 항목을 이 값으로 만들기 때문에, 0 이면 항목이 생기지 않아 `Ctrl+C` 가 바이트 0 개가
    /// 되고 `Alt+n` 이 `ESC` 없이 `n` 으로 나간다.
    unshifted_codepoint: u21 = 0,

    /// 눌림 · 반복 · 뗌 (#538).
    ///
    /// **`.release` 를 모드와 무관하게 넘겨도 된다.** 인코더가 알아서 거른다 — kitty
    /// flags 가 없으면 legacy 경로가 `.press` · `.repeat` 만 내보내고, flags 가 있어도
    /// `report_events` 가 꺼져 있으면 `kitty()` 앞부분에서 돌아간다. 그래서 host 가
    /// "지금 kitty 모드인가" 를 판정할 필요가 없다.
    ///
    /// 다만 **`.release` 를 인코더까지 흘리기 전에 host 가 걸러야 하는 것**은 있다.
    /// 다이얼로그 · 메뉴가 떠 있어 press 가 PTY 로 가지 않은 경우다 — 그때 뗌만 가면
    /// 앱이 짝 없는 release 를 본다.
    action: Action = .press,
};

/// #533 — **글자를 만들지 않는 키**인가 (화살표 · nav · F-key).
///
/// host 가 "이 키는 IME 를 거치지 않고 바로 인코더로 보내도 된다" 를 판정하는 데 쓴다.
/// macOS 가 특히 그렇다 — 문자 키를 이 경로로 보내면 `interpretKeyEvents:` 를 건너뛰어
/// 한글 조합이 깨진다. 그래서 집합을 좁게 유지한다.
///
/// **Enter · Tab · Escape · Backspace 는 일부러 뺐다.** macOS 는 그것들을 IME 의
/// `doCommandBySelector:` 로 받고 있고, 그 경로를 건드리는 것은 이 변경의 범위가 아니다.
pub fn isNavOrFunction(code: physical_key.PhysicalCode) bool {
    return switch (code) {
        .arrow_up,
        .arrow_down,
        .arrow_left,
        .arrow_right,
        .home,
        .end,
        .page_up,
        .page_down,
        .insert,
        .delete,
        .f1,
        .f2,
        .f3,
        .f4,
        .f5,
        .f6,
        .f7,
        .f8,
        .f9,
        .f10,
        .f11,
        .f12,
        .f13,
        .f14,
        .f15,
        .f16,
        .f17,
        .f18,
        .f19,
        .f20,
        .f21,
        .f22,
        .f23,
        .f24,
        => true,
        else => false,
    };
}

/// #533 후속 ([#483](https://github.com/ensky0/tildaz/issues/483) 브랜치에서 고침) — 물리 키가 **US 배열
/// 에서 내는 ASCII 글자**. macOS 는 입력원이 곧 배열이라 한글 2벌식 · 러시아어 입력원에서는
/// `charactersByApplyingModifiers:0` 이 자모 (`ㅁ`) 를 준다. 그러면 `Option` 을 Alt 로 쓰기로 해도
/// 인코더가 `ESC` 를 붙일 ASCII 를 못 찾아 (`legacyAltPrefix` 는 1 바이트 utf8 이나 ASCII
/// `unshifted_codepoint` 만 본다) 자모가 그대로 나간다 — `Alt+n` (zellij · tmux) 이 안 닿는다.
/// 그 되짚기를 여기서 준다 (ghostty 의 `ctrlSeq` 가 러시아어 자판에 쓰는 것과 같은 수 — 그쪽은
/// `logical_key.codepoint()`).
///
/// 대문자 여부는 호출부가 정한다 (Shift 를 눌렀으면 그쪽에서 올린다).
pub fn usAscii(code: ?physical_key.PhysicalCode) ?u8 {
    const cp = toGhosttyKey(code).codepoint() orelse return null;
    return std.math.cast(u8, cp);
}

/// `event` 를 `writer` 에 인코딩한다. 출력이 없는 키도 있다 (modifier 키 등) —
/// 호출부가 쓰인 바이트 수를 보고 판단한다.
pub fn encode(
    writer: *std.Io.Writer,
    event: Event,
    opts: Options,
) std.Io.Writer.Error!void {
    const ghostty_event: ghostty.input.KeyEvent = .{
        .action = event.action,
        .key = toGhosttyKey(event.code),
        .mods = event.mods,
        .consumed_mods = event.consumed_mods,
        .utf8 = event.utf8,
        .unshifted_codepoint = event.unshifted_codepoint,
    };

    // #650 — ghostty 가 fixterms 때문에 C0 표에서 뺀 세 키를 legacy 에서 되돌린다.
    if (legacyC0Override(event, opts)) |byte| return writer.writeByte(byte);

    // #648 — legacy 인 Ctrl+Shift 조합만 결과를 들여다본다. 나머지는 그대로 흘려
    // 보낸다 (버퍼 한 번을 더 쓰지 않는다).
    if (mayDropExtended(event, opts)) {
        var buf: [64]u8 = undefined;
        var probe: std.Io.Writer = .fixed(&buf);
        if (ghostty.input.encodeKey(&probe, ghostty_event, opts)) {
            const bytes = probe.buffered();
            if (isUnrequestedExtended(bytes, opts)) return;
            return writer.writeAll(bytes);
        } else |_| {
            // legacy 경로가 64 바이트를 넘는 일은 없다 (가장 긴 것이 `ESC[27;…;…~`).
            // 넘었다면 우리가 모르는 모양이므로 규칙을 적용하지 않고 원래대로 보낸다.
        }
    }

    return ghostty.input.encodeKey(writer, ghostty_event, opts);
}

/// #650 — legacy 에서 `Ctrl+[` · `Ctrl+I` · `Ctrl+M` 이 내야 할 C0 바이트.
///
/// ghostty 의 `ctrlSeq` C0 표는 이 셋을 **주석과 함께 일부러 비워 두었다** —
/// *"These are purposely NOT handled here because of the fixterms specification …
/// processed as CSI u"*. 앱이 `Tab` 과 `Ctrl+I` 를, `Enter` 와 `Ctrl+M` 을 구분할 수
/// 있게 하려는 것이고 그 자체는 타당하다. 문제는 **앱이 그 프로토콜을 켜지 않았을 때도**
/// 그렇게 나간다는 것이다 — bash 에서 `Ctrl+[` 가 ESC 가 아니라 `ESC[91;5u` 라서
/// vi-mode 탈출이 안 됐다.
///
/// 그래서 legacy 일 때만 되돌린다. **kitty flags 나 modifyOtherKeys=2 가 켜져 있으면
/// 손대지 않는다** — vim · emacs 는 후자를 켜고 `ESC[27;5;91~` 를 받아 이미 잘 동작하며,
/// kitty 를 켠 앱은 정확히 그 구분을 원해서 켠 것이다.
///
/// Shift 가 눌린 조합은 #648 의 몫이라 여기서 뺀다 (`Ctrl+Shift+I` 는 계속 0 바이트 —
/// Windows 동등). Alt 는 ESC prefix 규칙이 따로 있어 건드리지 않는다.
///
/// 글자를 고르는 순서는 `ctrlSeq` 와 같다 — 1 바이트 `utf8` 이 있으면 그것, 없으면
/// **물리 키의 US 글자**. 러시아어 배열의 `Ctrl+I` (물리 `i` 자리, keysym `ш`) 가 그
/// 되짚기로 `0x09` 를 낸다. CapsLock 으로 대문자가 와도 내려서 본다.
fn legacyC0Override(event: Event, opts: Options) ?u8 {
    if (opts.kitty_flags.int() != 0) return null;
    if (opts.modify_other_keys_state_2) return null;
    if (!event.mods.ctrl) return null;
    if (event.mods.shift or event.mods.alt or event.mods.super) return null;

    var char: u8 = if (event.utf8.len == 1)
        event.utf8[0]
    else
        usAscii(event.code) orelse return null;
    if (char >= 'A' and char <= 'Z') char = std.ascii.toLower(char);

    return switch (char) {
        '[' => 0x1b,
        'i' => 0x09,
        'm' => 0x0d,
        else => null,
    };
}

/// #648 — 이 이벤트에 "요청되지 않은 확장 인코딩은 버린다" 규칙이 걸릴 수 있는가.
///
/// **kitty flags 가 있으면 걸리지 않는다.** 그때는 앱이 `CSI > flags u` 로 프로토콜을
/// 명시적으로 켠 상태이고, 그런 앱 (nvim · helix · zellij) 은 `Ctrl+Shift+<글자>` 를
/// 정말로 원한다. 여기서 삼키면 그쪽이 통째로 깨진다.
///
/// Shift 가 없는 `Ctrl+<글자>` 도 대상이 아니다 — `^C` · `^F` 는 C0 바이트로 잘 나간다.
/// Alt · Cmd 가 섞인 조합은 각자 규칙 (ESC prefix · macOS super) 이 있어 건드리지 않는다.
fn mayDropExtended(event: Event, opts: Options) bool {
    if (opts.kitty_flags.int() != 0) return false;
    if (!event.mods.ctrl or !event.mods.shift) return false;
    if (event.mods.alt or event.mods.super) return false;
    return true;
}

/// #648 — 이 바이트열이 **앱이 요청한 적 없는** 확장 인코딩인가.
///
/// ghostty 의 legacy 경로는 두 가지로 폴백한다. 둘 다 터미널 상태가 legacy 인데도 나간다.
///
/// 1. **fixterms `CSI <cp>;<mods> u`** — `ctrlSeq()` 가 Shift 가 끼면 늘 `null` 을 주고
///    (ctrl+M 과 ctrl+shift+M 을 앱이 구분할 수 있게 한 upstream 의 의도적 분기다),
///    그 뒤 `if (event.mods.ctrl) csiu:` 블록이 kitty flags 와 무관하게 찍는다.
///    **이 인코딩은 앱이 켤 방법이 아예 없다** — 그래서 legacy 면 언제나 요청 밖이다.
/// 2. **xterm modifyOtherKeys `CSI 27;<mods>;<cp> ~`** — Enter · Tab 은 `function_keys`
///    표에 modifier 조합이 무조건 항목으로 박혀 있어 모드와 상관없이 나간다. 다만 앱이
///    `CSI > 4;2m` 으로 켰다면 그건 **요청된** 것이므로 남긴다.
///
/// `ESC[1;6D` (Ctrl+Shift+←) · `ESC[5;6~` (Ctrl+Shift+PgUp) 같은 표준 CSI modifier 는
/// 확장이 아니다 — 모든 터미널이 예전부터 보내던 모양이라 그대로 둔다. 그래서 `~` 는
/// `ESC[27;` 로 시작할 때만 본다.
fn isUnrequestedExtended(bytes: []const u8, opts: Options) bool {
    if (bytes.len < 4) return false;
    if (bytes[0] != 0x1b or bytes[1] != '[') return false;
    if (bytes[bytes.len - 1] == 'u') return true;
    if (bytes[bytes.len - 1] == '~' and
        !opts.modify_other_keys_state_2 and
        std.mem.startsWith(u8, bytes, "\x1b[27;")) return true;
    return false;
}

/// 우리 `PhysicalCode` → ghostty `input.Key`.
///
/// 두 enum 모두 W3C [UI Events code](https://www.w3.org/TR/uievents-code/) 이름이라
/// 대부분 철자가 같다. 다른 것만 아래에 적고 나머지는 `inline else` 가 이름으로 잇는다 —
/// upstream 이 이름을 바꾸면 `@field` 가 **컴파일 에러**로 드러난다 (`mouse_report.zig`
/// 가 exhaustive switch 로 같은 보호를 두는 것과 같은 이유).
fn toGhosttyKey(code: ?physical_key.PhysicalCode) ghostty.input.Key {
    const c = code orelse return .unidentified;
    return switch (c) {
        // 숫자열 · numpad 만 밑줄 위치가 다르다.
        .digit0 => .digit_0,
        .digit1 => .digit_1,
        .digit2 => .digit_2,
        .digit3 => .digit_3,
        .digit4 => .digit_4,
        .digit5 => .digit_5,
        .digit6 => .digit_6,
        .digit7 => .digit_7,
        .digit8 => .digit_8,
        .digit9 => .digit_9,
        .numpad0 => .numpad_0,
        .numpad1 => .numpad_1,
        .numpad2 => .numpad_2,
        .numpad3 => .numpad_3,
        .numpad4 => .numpad_4,
        .numpad5 => .numpad_5,
        .numpad6 => .numpad_6,
        .numpad7 => .numpad_7,
        .numpad8 => .numpad_8,
        .numpad9 => .numpad_9,

        // 한/영 (`lang1`) · 한자 (`lang2`) 는 ghostty 의 `Key` 에 없다. IME 가 먹는
        // 키라 PTY 로 나갈 일이 없어 그대로 둔다 — 나가야 할 바이트가 생기면 그때
        // upstream 에 올린다.
        .lang1, .lang2 => .unidentified,

        inline else => |tag| @field(ghostty.input.Key, @tagName(tag)),
    };
}

// ── 테스트 ──────────────────────────────────────────────────────────────────
//
// 정책(#533 코멘트의 ①~⑤)을 코드로 고정한다.

const testing = std.testing;

fn encodeToBuf(buf: []u8, event: Event, opts: Options) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try encode(&w, event, opts);
    return w.buffered();
}

test "이름이 같은 키는 그대로 이어진다" {
    try testing.expectEqual(ghostty.input.Key.key_a, toGhosttyKey(.key_a));
    try testing.expectEqual(ghostty.input.Key.arrow_left, toGhosttyKey(.arrow_left));
    try testing.expectEqual(ghostty.input.Key.f12, toGhosttyKey(.f12));
    try testing.expectEqual(ghostty.input.Key.bracket_left, toGhosttyKey(.bracket_left));
}

test "숫자열 · numpad 는 밑줄 위치가 달라 따로 잇는다" {
    try testing.expectEqual(ghostty.input.Key.digit_0, toGhosttyKey(.digit0));
    try testing.expectEqual(ghostty.input.Key.digit_9, toGhosttyKey(.digit9));
    try testing.expectEqual(ghostty.input.Key.numpad_5, toGhosttyKey(.numpad5));
}

test "모르는 키 · IME 전용 키는 unidentified" {
    try testing.expectEqual(ghostty.input.Key.unidentified, toGhosttyKey(null));
    try testing.expectEqual(ghostty.input.Key.unidentified, toGhosttyKey(.lang1));
    try testing.expectEqual(ghostty.input.Key.unidentified, toGhosttyKey(.lang2));
}

test "② Alt+문자 앞에 ESC 가 붙는다 — #533 의 신고 그 자체" {
    // **`macos_option_as_alt` 를 명시한다.** macOS 빌드에서 인코더는 이 값이
    // `.false`(기본) 면 alt 를 modifier 로 치지 않는다 — Option 이 문자를 만드는
    // platform 이라 그것이 옳은 기본값이고, 그래서 이 테스트가 platform 에 따라
    // 갈리면 안 된다. 여기서 재는 것은 "alt 로 취급하기로 했을 때 ESC 가 붙는가" 다.
    var buf: [16]u8 = undefined;
    const out = try encodeToBuf(&buf, .{
        .code = .key_a,
        .mods = .{ .alt = true },
        .utf8 = "a",
        .unshifted_codepoint = 'a',
    }, .{ .alt_esc_prefix = true, .macos_option_as_alt = .true });
    try testing.expectEqualStrings("\x1ba", out);
}

test "④ macOS 기본값에서는 Option 이 문자로 남는다" {
    // Linux · Windows 에는 이 갈림이 없다 (`Alt+a` 가 만드는 문자가 없음). macOS 만
    // OS 가 `å` 같은 문자를 만들어 주므로, 기본값에서는 그 문자를 그대로 보낸다.
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;

    var buf: [16]u8 = undefined;
    const out = try encodeToBuf(&buf, .{
        .code = .key_a,
        .mods = .{ .alt = true },
        .utf8 = "å",
        .unshifted_codepoint = 'a',
    }, .{ .alt_esc_prefix = true, .macos_option_as_alt = .false });
    try testing.expectEqualStrings("å", out);
}

test "① modifier 없는 문자는 그대로 나간다" {
    var buf: [16]u8 = undefined;
    const out = try encodeToBuf(&buf, .{
        .code = .key_a,
        .utf8 = "a",
        .unshifted_codepoint = 'a',
    }, .{});
    try testing.expectEqualStrings("a", out);
}

test "③ 문자를 만든 조합에는 ESC 를 붙이지 않는다 — AltGr" {
    // 프랑스 자판 `AltGr+2` → `~`. xkb 가 이미 문자를 만들었으므로 alt 는
    // consumed 다. 이것을 표시하지 않으면 `ESC~` 가 나가 버린다.
    // `macos_option_as_alt = .true` 로 둔다 — 그래야 "alt 를 modifier 로 치는데도
    // consumed 라서 ESC 가 안 붙는다" 를 재는 것이 된다. 기본값이면 macOS 에서
    // alt 가 애초에 무시돼 통과해도 아무것도 검증하지 못한다.
    var buf: [16]u8 = undefined;
    const out = try encodeToBuf(&buf, .{
        .code = .digit2,
        .mods = .{ .alt = true },
        .consumed_mods = .{ .alt = true },
        .utf8 = "~",
    }, .{ .alt_esc_prefix = true, .macos_option_as_alt = .true });
    try testing.expectEqualStrings("~", out);
}

test "⑤ 화살표 + modifier 는 CSI 로 나간다" {
    var buf: [16]u8 = undefined;

    // modifier 없는 왼쪽 화살표 — 지금까지도 되던 것.
    const plain = try encodeToBuf(&buf, .{ .code = .arrow_left }, .{});
    try testing.expectEqualStrings("\x1b[D", plain);

    // Alt+← — 지금까지 아무것도 나가지 않던 것. modifier 3 = alt.
    var buf2: [16]u8 = undefined;
    const with_alt = try encodeToBuf(&buf2, .{
        .code = .arrow_left,
        .mods = .{ .alt = true },
    }, .{});
    try testing.expectEqualStrings("\x1b[1;3D", with_alt);

    // Shift+← — modifier 2 = shift.
    var buf3: [16]u8 = undefined;
    const with_shift = try encodeToBuf(&buf3, .{
        .code = .arrow_left,
        .mods = .{ .shift = true },
    }, .{});
    try testing.expectEqualStrings("\x1b[1;2D", with_shift);
}

test "DEC mode 1036 을 끄면 ESC 가 붙지 않는다" {
    // 앱이 `?1036l` 로 끌 수 있다. 그 경우 8-bit meta 도 우리가 보내지 않으므로
    // 문자만 나간다 — 터미널 모드를 존중한다는 뜻이다.
    var buf: [16]u8 = undefined;
    const out = try encodeToBuf(&buf, .{
        .code = .key_a,
        .mods = .{ .alt = true },
        .utf8 = "a",
        .unshifted_codepoint = 'a',
    }, .{ .alt_esc_prefix = false, .macos_option_as_alt = .true });
    try testing.expectEqualStrings("a", out);
}

// ── #648 — 요청되지 않은 확장 인코딩은 보내지 않는다 ─────────────────────────
//
// 증상은 macOS 의 `Ctrl+Shift+F` 가 bash 프롬프트에 `2;6u` 를 찍는 것이었다. 터미널은
// `CSI ? u` 질의에 `^[[?0u` (legacy) 라고 답하는데 인코더는 `ESC[102;6u` 를 보내고 있었다.
// Windows 는 `WM_CHAR` 에서 Ctrl+Shift 를 통째로 삼켜 이미 아무것도 내지 않았다 —
// 그 규칙을 세 host 공통 자리인 여기로 올려 셋을 맞춘다.

test "#648 legacy 의 Ctrl+Shift+<글자> 는 아무것도 보내지 않는다" {
    // mac · Linux host 가 채우는 모양 그대로다 — Ctrl 을 뺀 글자(`F`) 와 수식키를 다 뺀
    // 코드포인트(`f`). 고치기 전에는 `ESC[102;6u` 가 나갔다.
    var buf: [16]u8 = undefined;
    const out = try encodeToBuf(&buf, .{
        .code = .key_f,
        .mods = .{ .ctrl = true, .shift = true },
        .consumed_mods = .{ .shift = true },
        .utf8 = "F",
        .unshifted_codepoint = 'f',
    }, .{});
    try testing.expectEqualStrings("", out);
}

test "#648 Shift 없는 Ctrl+<글자> 는 그대로 C0 로 나간다" {
    // 규칙이 `Ctrl+C` 의 SIGINT 를 건드리면 안 된다 — 그것이 이 변경의 가장 큰 위험이다.
    var buf: [16]u8 = undefined;
    const sigint = try encodeToBuf(&buf, .{
        .code = .key_c,
        .mods = .{ .ctrl = true },
        .utf8 = "c",
        .unshifted_codepoint = 'c',
    }, .{});
    try testing.expectEqualStrings("\x03", sigint);

    var buf2: [16]u8 = undefined;
    const ack = try encodeToBuf(&buf2, .{
        .code = .key_f,
        .mods = .{ .ctrl = true },
        .utf8 = "f",
        .unshifted_codepoint = 'f',
    }, .{});
    try testing.expectEqualStrings("\x06", ack);
}

test "#648 kitty 를 켠 앱에는 CSI u 가 그대로 간다" {
    // **이 테스트가 규칙의 경계다.** nvim · helix · zellij 는 `CSI > flags u` 로 프로토콜을
    // 켜고 `Ctrl+Shift+<글자>` 를 실제로 쓴다. 요청한 앱에까지 삼키면 그쪽이 통째로 깨진다.
    var buf: [16]u8 = undefined;
    const out = try encodeToBuf(&buf, .{
        .code = .key_f,
        .mods = .{ .ctrl = true, .shift = true },
        .consumed_mods = .{ .shift = true },
        .utf8 = "F",
        .unshifted_codepoint = 'f',
    }, .{ .kitty_flags = .{ .disambiguate = true } });
    try testing.expectEqualStrings("\x1b[102;6u", out);
}

test "#648 modifyOtherKeys=2 를 켠 앱에는 CSI 27 이 그대로 간다" {
    // 앱이 `CSI > 4;2m` 으로 켠 프로토콜이라 요청된 것이다. 끈 상태에서만 버린다.
    var buf: [16]u8 = undefined;
    const on = try encodeToBuf(&buf, .{
        .code = .key_f,
        .mods = .{ .ctrl = true, .shift = true },
        .consumed_mods = .{ .shift = true },
        .utf8 = "F",
        .unshifted_codepoint = 'f',
    }, .{ .modify_other_keys_state_2 = true });
    try testing.expectEqualStrings("\x1b[27;6;70~", on);
}

test "#648 legacy 의 Ctrl+Shift+Enter 도 보내지 않는다" {
    // Enter 는 CSI u 가 아니라 `function_keys` 표의 `ESC[27;6;13~` 로 나간다 — 그 항목은
    // modifyOtherKeys 와 무관하게 무조건이라 legacy 에서도 샜다. Windows 는 이것도 삼킨다.
    var buf: [16]u8 = undefined;
    const out = try encodeToBuf(&buf, .{
        .code = .enter,
        .mods = .{ .ctrl = true, .shift = true },
    }, .{});
    try testing.expectEqualStrings("", out);

    // Shift 없는 `Ctrl+Enter` 는 규칙 밖이다 — 지금까지대로 나간다.
    var buf2: [16]u8 = undefined;
    const ctrl_only = try encodeToBuf(&buf2, .{
        .code = .enter,
        .mods = .{ .ctrl = true },
    }, .{});
    try testing.expectEqualStrings("\x1b[27;5;13~", ctrl_only);
}

test "#648 표준 CSI modifier 는 확장이 아니라 그대로 둔다" {
    // `ESC[1;6D` · `ESC[5;6~` 는 모든 터미널이 예전부터 보내던 모양이다. Ctrl+Shift 라는
    // 이유만으로 버리면 화살표 · PgUp 이 죽는다 — `~` 를 `ESC[27;` 일 때만 보는 이유다.
    var buf: [16]u8 = undefined;
    const arrow = try encodeToBuf(&buf, .{
        .code = .arrow_left,
        .mods = .{ .ctrl = true, .shift = true },
    }, .{});
    try testing.expectEqualStrings("\x1b[1;6D", arrow);

    var buf2: [16]u8 = undefined;
    const pgup = try encodeToBuf(&buf2, .{
        .code = .page_up,
        .mods = .{ .ctrl = true, .shift = true },
    }, .{});
    try testing.expectEqualStrings("\x1b[5;6~", pgup);
}

// ── #650 — legacy 의 Ctrl+[ · Ctrl+I · Ctrl+M 은 C0 로 나간다 ────────────────
//
// ghostty 는 fixterms 를 따라 이 셋을 C0 표에서 빼고 `CSI u` 로 보낸다. 앱이 프로토콜을
// 켰을 때는 맞지만 legacy 에서는 `Ctrl+[` 가 ESC 가 아니게 되어 bash vi-mode 탈출이
// 깨졌다. Windows 는 `WM_CHAR` 로 OS 가 만든 C0 를 그대로 보내 이미 정상이었다.

test "#650 legacy 에서 Ctrl+[ · Ctrl+I · Ctrl+M 이 C0 로 나간다" {
    const Case = struct { code: physical_key.PhysicalCode, ch: []const u8, want: []const u8 };
    for ([_]Case{
        .{ .code = .bracket_left, .ch = "[", .want = "\x1b" },
        .{ .code = .key_i, .ch = "i", .want = "\x09" },
        .{ .code = .key_m, .ch = "m", .want = "\x0d" },
    }) |c| {
        var buf: [16]u8 = undefined;
        const out = try encodeToBuf(&buf, .{
            .code = c.code,
            .mods = .{ .ctrl = true },
            .utf8 = c.ch,
            .unshifted_codepoint = c.ch[0],
        }, .{});
        try testing.expectEqualStrings(c.want, out);
    }
}

test "#650 프로토콜을 켠 앱에는 확장 인코딩이 그대로 간다" {
    // **이 테스트가 규칙의 경계다.** kitty 를 켠 앱은 정확히 `Tab` 과 `Ctrl+I` 를
    // 구분하려고 켰고, vim · emacs 는 modifyOtherKeys=2 로 이미 잘 받고 있다.
    var buf: [16]u8 = undefined;
    const kitty = try encodeToBuf(&buf, .{
        .code = .bracket_left,
        .mods = .{ .ctrl = true },
        .utf8 = "[",
        .unshifted_codepoint = '[',
    }, .{ .kitty_flags = .{ .disambiguate = true } });
    try testing.expectEqualStrings("\x1b[91;5u", kitty);

    var buf2: [16]u8 = undefined;
    const mok2 = try encodeToBuf(&buf2, .{
        .code = .bracket_left,
        .mods = .{ .ctrl = true },
        .utf8 = "[",
        .unshifted_codepoint = '[',
    }, .{ .modify_other_keys_state_2 = true });
    try testing.expectEqualStrings("\x1b[27;5;91~", mok2);
}

test "#650 Shift 가 끼면 #648 의 몫이라 계속 0 바이트다" {
    var buf: [16]u8 = undefined;
    const out = try encodeToBuf(&buf, .{
        .code = .key_i,
        .mods = .{ .ctrl = true, .shift = true },
        .consumed_mods = .{ .shift = true },
        .utf8 = "I",
        .unshifted_codepoint = 'i',
    }, .{});
    try testing.expectEqualStrings("", out);
}

test "#650 비라틴 배열도 물리 키의 US 글자로 되짚는다" {
    // 러시아어 배열의 물리 `i` 자리는 keysym `ш` 다. `utf8` 이 1 바이트가 아니므로
    // `usAscii` 가 `i` 를 주고, 그래서 `Ctrl+I` 가 Tab 을 잃지 않는다.
    var buf: [16]u8 = undefined;
    const out = try encodeToBuf(&buf, .{
        .code = .key_i,
        .mods = .{ .ctrl = true },
        .utf8 = "ш",
        .unshifted_codepoint = 0x448,
    }, .{});
    try testing.expectEqualStrings("\x09", out);
}

test "#650 이웃 키는 한 바이트도 달라지지 않는다" {
    // `Ctrl+H` · `Ctrl+]` · `Ctrl+\` 는 원래 C0 표에 있어 정상이었다. 되돌리는 과정에서
    // 이것들을 건드리면 조용한 회귀가 된다.
    const Case = struct { code: physical_key.PhysicalCode, ch: []const u8, want: []const u8 };
    for ([_]Case{
        .{ .code = .key_h, .ch = "h", .want = "\x08" },
        .{ .code = .bracket_right, .ch = "]", .want = "\x1d" },
        .{ .code = .backslash, .ch = "\\", .want = "\x1c" },
        .{ .code = .key_c, .ch = "c", .want = "\x03" },
    }) |c| {
        var buf: [16]u8 = undefined;
        const out = try encodeToBuf(&buf, .{
            .code = c.code,
            .mods = .{ .ctrl = true },
            .utf8 = c.ch,
            .unshifted_codepoint = c.ch[0],
        }, .{});
        try testing.expectEqualStrings(c.want, out);
    }
}

test "기존 세 host 의 escape 매핑과 한 바이트도 다르지 않다" {
    // (라-1) 로 걷어낼 매핑들이다 — Linux `terminalSequenceForKeysym`, macOS
    // `keyCodeToEscape`, Windows `window.zig` 의 VK switch 가 서로 같은 값을 쓰고
    // 있었고, `encodeKey` 도 26 개 전부 같은 값을 낸다 (2026-08-27 대조).
    //
    // 이 표를 남겨 두는 이유는 **회귀 감시**다. host 를 인코더로 옮긴 뒤 upstream 이
    // 시퀀스를 바꾸면 여기서 먼저 드러난다 — 사용자의 vim · htop 이 아니라.
    const cases = [_]struct { code: physical_key.PhysicalCode, want: []const u8 }{
        .{ .code = .enter, .want = "\r" },
        .{ .code = .escape, .want = "\x1b" },
        .{ .code = .backspace, .want = "\x7f" },
        .{ .code = .tab, .want = "\t" },
        .{ .code = .arrow_up, .want = "\x1b[A" },
        .{ .code = .arrow_down, .want = "\x1b[B" },
        .{ .code = .arrow_right, .want = "\x1b[C" },
        .{ .code = .arrow_left, .want = "\x1b[D" },
        .{ .code = .home, .want = "\x1b[H" },
        .{ .code = .end, .want = "\x1b[F" },
        .{ .code = .insert, .want = "\x1b[2~" },
        .{ .code = .delete, .want = "\x1b[3~" },
        .{ .code = .page_up, .want = "\x1b[5~" },
        .{ .code = .page_down, .want = "\x1b[6~" },
        // #282 A7 — F1~F4 는 SS3, F5 부터 CSI ~ 다.
        .{ .code = .f1, .want = "\x1bOP" },
        .{ .code = .f2, .want = "\x1bOQ" },
        .{ .code = .f3, .want = "\x1bOR" },
        .{ .code = .f4, .want = "\x1bOS" },
        .{ .code = .f5, .want = "\x1b[15~" },
        .{ .code = .f6, .want = "\x1b[17~" },
        .{ .code = .f7, .want = "\x1b[18~" },
        .{ .code = .f8, .want = "\x1b[19~" },
        .{ .code = .f9, .want = "\x1b[20~" },
        .{ .code = .f10, .want = "\x1b[21~" },
        .{ .code = .f11, .want = "\x1b[23~" },
        .{ .code = .f12, .want = "\x1b[24~" },
    };
    for (cases) |c| {
        var buf: [32]u8 = undefined;
        const out = try encodeToBuf(&buf, .{ .code = c.code }, .{});
        testing.expectEqualStrings(c.want, out) catch |err| {
            std.debug.print("어긋난 키: {s}\n", .{@tagName(c.code)});
            return err;
        };
    }
}

test "ISO_Left_Tab (Shift+Tab) 은 CSI Z 다 — Linux 만 갖고 있던 매핑" {
    var buf: [16]u8 = undefined;
    const out = try encodeToBuf(&buf, .{
        .code = .tab,
        .mods = .{ .shift = true },
    }, .{});
    try testing.expectEqualStrings("\x1b[Z", out);
}

test "Enter · Tab 은 code 로 나가고 utf8 이 있어도 겹치지 않는다" {
    // xkb 는 Enter 에 code 와 utf8("\r") 을 함께 준다. 둘 다 넘겨도 한 번만 나가야 한다.
    var b1: [16]u8 = undefined;
    try testing.expectEqualStrings("\r", try encodeToBuf(&b1, .{ .code = .enter, .utf8 = "\r" }, .{}));
    var b2: [16]u8 = undefined;
    try testing.expectEqualStrings("\t", try encodeToBuf(&b2, .{ .code = .tab, .utf8 = "\t" }, .{}));
    var b3: [16]u8 = undefined;
    try testing.expectEqualStrings("\x1b", try encodeToBuf(&b3, .{ .code = .escape, .utf8 = "\x1b" }, .{}));
}

test "#533 후속 — usAscii: 물리 키의 US 글자 (비-ASCII 입력원에서 ESC 를 붙일 근거)" {
    try testing.expectEqual(@as(?u8, 'a'), usAscii(.key_a));
    try testing.expectEqual(@as(?u8, 'n'), usAscii(.key_n));
    try testing.expectEqual(@as(?u8, '1'), usAscii(.digit1));
    try testing.expectEqual(@as(?u8, '['), usAscii(.bracket_left));
    // 글자가 없는 키 · 모르는 키는 null — 호출부가 예전 경로로 떨어진다.
    try testing.expectEqual(@as(?u8, null), usAscii(.arrow_left));
    try testing.expectEqual(@as(?u8, null), usAscii(.f5));
    try testing.expectEqual(@as(?u8, null), usAscii(null));
}

test "isNavOrFunction — 글자 키와 IME 가 맡는 키는 빠진다" {
    try testing.expect(isNavOrFunction(.arrow_left));
    try testing.expect(isNavOrFunction(.page_up));
    try testing.expect(isNavOrFunction(.f5));
    try testing.expect(isNavOrFunction(.delete));

    // 글자 키 — 이것이 true 가 되면 macOS 에서 IME 를 건너뛰어 한글이 깨진다.
    try testing.expect(!isNavOrFunction(.key_a));
    try testing.expect(!isNavOrFunction(.digit1));
    try testing.expect(!isNavOrFunction(.space));
    // IME 의 doCommandBySelector 가 맡고 있는 키들.
    try testing.expect(!isNavOrFunction(.enter));
    try testing.expect(!isNavOrFunction(.tab));
    try testing.expect(!isNavOrFunction(.escape));
    try testing.expect(!isNavOrFunction(.backspace));
}

test "① 배열이 다른 자판에서 Ctrl+글자 — AZERTY" {
    // AZERTY 의 `A` 는 물리적으로 US 의 `Q` 자리다. `utf8` 을 비워서 넘기면 인코더가
    // 물리 키의 US 글자(`q`)로 제어문자를 만들어 `\x11`(XOFF, 화면 멈춤)이 나간다.
    var buf: [16]u8 = undefined;
    const out = try encodeToBuf(&buf, .{
        .code = .key_q,
        .mods = .{ .ctrl = true },
        .utf8 = "a",
        .unshifted_codepoint = 'a',
    }, .{});
    try testing.expectEqualStrings("\x01", out);
}

test "① 배열이 다른 자판에서 Ctrl+글자 — Dvorak" {
    // Dvorak 의 `C` 는 물리적으로 US 의 `I` 자리다. 비우면 `\x09`(Tab) 가 나가 SIGINT 가 안 간다.
    var buf: [16]u8 = undefined;
    const out = try encodeToBuf(&buf, .{
        .code = .key_i,
        .mods = .{ .ctrl = true },
        .utf8 = "c",
        .unshifted_codepoint = 'c',
    }, .{});
    try testing.expectEqualStrings("\x03", out);
}

test "② kitty keyboard protocol — Ctrl+C" {
    var buf: [16]u8 = undefined;
    const out = try encodeToBuf(&buf, .{
        .code = .key_c,
        .mods = .{ .ctrl = true },
        .utf8 = "c",
        .unshifted_codepoint = 'c',
    }, .{ .kitty_flags = .{ .disambiguate = true } });
    try testing.expectEqualStrings("\x1b[99;5u", out);
}

test "② kitty keyboard protocol — Alt+n" {
    var buf: [16]u8 = undefined;
    const out = try encodeToBuf(&buf, .{
        .code = .key_n,
        .mods = .{ .alt = true },
        .utf8 = "n",
        .unshifted_codepoint = 'n',
    }, .{ .kitty_flags = .{ .disambiguate = true }, .macos_option_as_alt = .true });
    try testing.expectEqualStrings("\x1b[110;3u", out);
}

test "② kitty keyboard protocol — 수식키 없는 글자는 그대로" {
    var buf: [16]u8 = undefined;
    const out = try encodeToBuf(&buf, .{
        .code = .key_a,
        .utf8 = "a",
        .unshifted_codepoint = 'a',
    }, .{ .kitty_flags = .{ .disambiguate = true } });
    try testing.expectEqualStrings("a", out);
}

test "#538 release 는 report_events + report_all 에서만 나간다" {
    var buf: [32]u8 = undefined;
    var ev: Event = .{ .code = .enter };
    ev.action = .release;

    // upstream 이 스스로 단언하는 값이다 — enter · backspace · tab 은 `report_all`
    // 이 있어야 뗌을 낸다. 마지막 `:3` 이 event type = release 다.
    try testing.expectEqualStrings("\x1b[13;1:3u", try encodeToBuf(&buf, ev, .{
        .kitty_flags = .{ .disambiguate = true, .report_events = true, .report_all = true },
    }));

    // `report_all` 이 없으면 그 셋은 뗌을 안 낸다.
    try testing.expectEqualStrings("", try encodeToBuf(&buf, ev, .{
        .kitty_flags = .{ .disambiguate = true, .report_events = true },
    }));
}

test "#538 report_events 가 없으면 release 는 바이트를 내지 않는다 — 회귀 가드" {
    var buf: [32]u8 = undefined;
    var release: Event = .{ .code = .key_a, .utf8 = "a", .unshifted_codepoint = 'a' };
    release.action = .release;

    // kitty flags 자체가 없는 흔한 경우 — legacy 경로가 press · repeat 만 낸다.
    try testing.expectEqualStrings("", try encodeToBuf(&buf, release, .{}));

    // `disambiguate` 만 켠 경우 (#533 에서 fish · neovim · zellij 로 검증한 그 모드).
    // **이 줄이 핵심 회귀 가드다** — 여기서 바이트가 나오면 흔한 앱에 입력이 두 배로 간다.
    try testing.expectEqualStrings("", try encodeToBuf(&buf, release, .{
        .kitty_flags = .{ .disambiguate = true },
    }));

    // 화살표처럼 kitty 표에 항목이 있는 키도 마찬가지여야 한다.
    var arrow: Event = .{ .code = .arrow_left };
    arrow.action = .release;
    try testing.expectEqualStrings("", try encodeToBuf(&buf, arrow, .{
        .kitty_flags = .{ .disambiguate = true },
    }));
}

test "#538 repeat 는 press 와 갈린다 — 그 전에는 둘 다 press 로 나갔다" {
    var buf: [32]u8 = undefined;
    const opts: Options = .{
        .kitty_flags = .{ .disambiguate = true, .report_events = true, .report_all = true },
    };
    var press: Event = .{ .code = .enter };
    press.action = .press;
    var repeat: Event = .{ .code = .enter };
    repeat.action = .repeat;

    // press 는 수식키가 기본값이면 `;1` 을 생략한다 (event 항목이 뒤에 붙는
    // repeat · release 는 자리를 채워야 해서 `;1` 이 남는다).
    try testing.expectEqualStrings("\x1b[13u", try encodeToBuf(&buf, press, opts));
    var buf2: [32]u8 = undefined;
    try testing.expectEqualStrings("\x1b[13;1:2u", try encodeToBuf(&buf2, repeat, opts));
}

test "#538 report_events 를 켜도 press 는 그대로다 — 기존 동작 회귀 가드" {
    var buf: [32]u8 = undefined;
    var press: Event = .{
        .code = .key_c,
        .mods = .{ .ctrl = true },
        .utf8 = "c",
        .unshifted_codepoint = 'c',
    };
    press.action = .press;
    const with = try encodeToBuf(&buf, press, .{
        .kitty_flags = .{ .disambiguate = true, .report_events = true },
    });
    var buf2: [32]u8 = undefined;
    const without = try encodeToBuf(&buf2, press, .{ .kitty_flags = .{ .disambiguate = true } });
    try testing.expectEqualStrings(without, with);
}
