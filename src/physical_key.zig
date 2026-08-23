//! #496 — 키의 **물리적 위치**. layout 과 무관하다.
//!
//! 라벨 (키에 새겨진 글자) 로만 단축키를 표현하면 비라틴 layout (키릴 · 그리스 ·
//! 아랍 ...) 에서 글자 단축키가 전부 죽는다. `ctrl+shift+w` 를 등록해도 `ru`
//! layout 의 어느 키도 `w` 를 내지 않기 때문이다 (`xkbcli how-to-type --layout ru
//! 'w'` 가 빈 결과다). 그래서 위치로도 적을 수 있어야 한다.
//!
//! ## 이름은 W3C 표준을 쓴다
//!
//! 이름 집합은 [UI Events KeyboardEvent code Values](https://www.w3.org/TR/uievents-code/)
//! 다 — 2025 년 W3C Recommendation. 우리가 이름을 발명하지 않는다.
//!
//! 표기는 VS Code 와 같은 대괄호다 (`"ctrl+shift+[KeyW]"`). config 문법에는 표준이
//! 없어 구현마다 다르지만 (`vk(65)` / `sc(30)` — Windows Terminal, `code:25` —
//! Hyprland, `bindcode 25` — i3 · sway), **숫자를 쓰는 쪽은 `xev` / `wev` 로 값을
//! 찾아야 한다.** 이름을 쓰는 VS Code 방식만 config 를 읽어서 이해할 수 있다.
//!
//! ## 수용 범위 — 자판이 낼 수 있는 키에 제한을 두지 않는다
//!
//! 라벨 집합보다 **넓다.** 처음엔 1:1 로 맞췄는데 (라벨이 거부하는 것을 위치만
//! 받으면 수용 집합이 조용히 넓어지므로) 그 제약을 걷었다.
//!
//! 근거는 두 집합의 **의미가 다르다**는 것이다. 라벨을 넓히려면 `-` 에 어떤 값을
//! 줄지 정해야 하는데, `VK_OEM_MINUS` / `kVK_ANSI_Minus` 는 라벨이 아니라 "US 자판
//! 에서 `-` 가 있는 자리" 다. 그것을 라벨로 받으면 Linux 는 라벨로, Windows ·
//! macOS 는 US 위치로 잡아 #496 의 세 갈래 불일치가 더 깊어진다. 라벨을 정직하게
//! 넓히려면 live layout 조회가 필요하다 (macOS `UCKeyTranslate`, Windows
//! `VkKeyScanExW`) — #496 항목 2 이고, 그것이 끝나면 라벨 집합은 "위치로 해석할
//! 이름" 이 되어 이 표에 흡수된다.
//!
//! 위치 쪽은 그 문제가 없다. `[Minus]` 는 처음부터 "그 자리" 이고 세 platform 에
//! 고정값이 있다. 그래서 기호 · numpad · 방향 · 편집 패드 · `F13`~`F24` · ISO / JIS
//! 추가 키까지 담는다.
//!
//! `F13`~`F24` 를 담는 이유를 적어 둔다 — 물리 키로 달린 자판은 드물다 (IBM /
//! Unicomp 122-key 터미널 자판). 실제 쓰임은 **QMK · ZMK · AutoHotkey 로 다른 키를
//! 그 코드에 매핑**하는 것이다. 아무 앱도 쓰지 않는 코드라서 일부러 그렇게 쓴다.
//! 그런 사용자에게는 이 행이 있어야 바인딩이 가능하다.
//!
//! 담지 않는 것이 둘 있다.
//!
//!   - **modifier 자체** (`ShiftLeft` · `ControlLeft` · `MetaLeft` ...). 이 모델에서
//!     modifier 는 비트이고 키 자리가 아니다. `ctrl+[ShiftLeft]` 는 뜻이 없다.
//!   - **media / browser 키** (`MediaPlayPause` · `BrowserBack` ...). 자판 위의
//!     고정 자리가 아니고 (기능 키의 대체 기능이거나 전용 자판에만 있다) macOS 는
//!     `keyDown` 으로 주지 않는다. 필요해지면 행을 더하면 된다.
//!
//! ## 세 platform 값
//!
//! | 열 | 의미 | 출처 |
//! |---|---|---|
//! | `evdev` | Linux evdev keycode | `linux/input-event-codes.h` |
//! | `scan` + `extended` | Windows scan code (set 1) | `WM_KEYDOWN` lParam bit 16~23 + bit 24 |
//! | `mac` | macOS hardware keyCode | `Carbon/HIToolbox/Events.h` `kVK_*` |
//!
//! **`extended` 없이는 Windows 열이 틀린다.** control pad 와 numpad 가 같은 하위
//! 바이트를 쓰고 `0xE0` prefix 로만 갈린다 — `Insert` (`0xE052`) vs `Numpad0`
//! (`0x52`), `NumpadEnter` (`0xE01C`) vs `Enter` (`0x1C`), `NumpadDivide`
//! (`0xE035`) vs `Slash` (`0x35`), `PrintScreen` (`0xE037`) vs `NumpadMultiply`
//! (`0x37`), `Pause` (`0xE045`) vs `NumLock` (`0x45`). lParam bit 24 가 그 prefix
//! 자리다.
//!
//! evdev 와 set-1 scan code 는 main block 에서 값이 같다 (evdev 가 set 1 에서 왔다).
//! 그래도 두 열을 따로 적는다 — extended 키에서 갈리고, 같은 값을 우연에 맡기면
//! 나중에 조용히 어긋난다.
//!
//! ## macOS 에 값이 없는 자리 — 두 가지 이유가 섞여 있다
//!
//! `mac` 이 optional 이다. 그런데 **이유가 둘이고 사용자에게 줄 안내가 다르다.**
//!
//!   - **겹침** — `PrintScreen` · `ScrollLock` · `Pause` 는 macOS 에 키가 없는 것이
//!     아니다. PC 자판을 Mac 에 꽂으면 그 키가 **`F13` · `F14` · `F15` 로 보고된다**
//!     (Apple 확장 자판이 그 자리에 F13~F15 를 둔다). 별 `kVK_*` 가 없을 뿐이다.
//!     그래서 안내가 "쓸 수 없다" 가 아니라 **"macOS 에서는 `[F13]` 으로 잡아라"**
//!     여야 한다. `mac_alias` 가 그 대체 자리를 담는다.
//!   - **부재** — `F21`~`F24` 는 Apple 의 `kVK_*` 가 F20 에서 멈춘다. `Convert` ·
//!     `NonConvert` · `KanaMode` 는 JIS 입력 전환 키로 macOS 가 다르게 처리한다.
//!     대체 자리가 없다.
//!
//! 이 구분은 이전에 `²` 에서 한 번 틀린 것과 같은 종류다 (값이 없다고 적었는데 실은
//! `grave` 와 값이 같았다). 출처는 Chromium 의 `dom_code_data.inc` mac 열이다.
//!
//! 어느 쪽이든 **파싱 단계에서 거부한다** (`config.zig` 의
//! `position_unavailable_on_platform`) — 조용히 아무 일도 안 하게 두면 #208 이 막던
//! silent failure 로 되돌아간다.
//!
//! `mac` 열은 `config.zig` 의 `MacHotkey.keycodeFromKey` 와 **값이 같아야 한다** —
//! 그쪽이 이미 US 위치표이기 때문이다 (그래서 AZERTY macOS 에서 `Z` 라고 새겨진
//! 키가 `w` 로 잡힌다. #496 항목 2). 두 표가 갈라지면 `[KeyW]` 와 라벨 `w` 가 macOS
//! 에서 서로 다른 키가 되고 증상이 조용하다. `config.zig` 의
//! `test "#496 physical_key 의 macOS 열이 keycodeFromKey 와 같다"` 가 그것을 고정한다.

const std = @import("std");
const builtin = @import("builtin");

/// W3C `KeyboardEvent.code` 값 중 TildaZ 가 받는 것.
pub const PhysicalCode = enum {
    // ── Function ────────────────────────────────────────────────────────────
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
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,

    // ── Writing system — 글자 ───────────────────────────────────────────────
    key_a,
    key_b,
    key_c,
    key_d,
    key_e,
    key_f,
    key_g,
    key_h,
    key_i,
    key_j,
    key_k,
    key_l,
    key_m,
    key_n,
    key_o,
    key_p,
    key_q,
    key_r,
    key_s,
    key_t,
    key_u,
    key_v,
    key_w,
    key_x,
    key_y,
    key_z,

    // ── Writing system — 숫자열 ─────────────────────────────────────────────
    digit0,
    digit1,
    digit2,
    digit3,
    digit4,
    digit5,
    digit6,
    digit7,
    digit8,
    digit9,

    // ── Writing system — 기호 ───────────────────────────────────────────────
    backquote,
    minus,
    equal,
    bracket_left,
    bracket_right,
    backslash,
    semicolon,
    quote,
    comma,
    period,
    slash,
    /// ISO 자판에만 있는 키 (AZERTY 의 `<>`, QWERTZ 의 `<>|`). US ANSI 에는 없다.
    intl_backslash,
    /// JIS 자판의 `¥`.
    intl_yen,
    /// JIS 자판의 `_` / `ろ`.
    intl_ro,

    // ── Functional ──────────────────────────────────────────────────────────
    space,
    tab,
    escape,
    enter,
    backspace,
    caps_lock,
    print_screen,
    scroll_lock,
    pause,
    context_menu,
    /// JIS 의 かな, 한글 자판의 한/영 (macOS `kVK_JIS_Kana`).
    lang1,
    /// JIS 의 英数, 한글 자판의 한자 (macOS `kVK_JIS_Eisu`).
    lang2,
    convert,
    non_convert,
    kana_mode,

    // ── Control pad ─────────────────────────────────────────────────────────
    insert,
    delete,
    home,
    end,
    page_up,
    page_down,

    // ── Arrow pad ───────────────────────────────────────────────────────────
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,

    // ── Numpad ──────────────────────────────────────────────────────────────
    num_lock,
    numpad0,
    numpad1,
    numpad2,
    numpad3,
    numpad4,
    numpad5,
    numpad6,
    numpad7,
    numpad8,
    numpad9,
    numpad_divide,
    numpad_multiply,
    numpad_subtract,
    numpad_add,
    numpad_enter,
    numpad_decimal,
    numpad_equal,
};

const Entry = struct {
    code: PhysicalCode,
    /// W3C 표기 그대로. 대소문자까지 표준이다 — 사용자에게 되돌려 줄 때 이 문자열을
    /// 쓴다 (`[KeyW]`).
    name: []const u8,
    evdev: u16,
    scan: u16,
    /// Windows `0xE0` prefix (lParam bit 24). control pad 와 numpad 를 갈라 준다.
    extended: bool = false,
    /// null = macOS 에 별 `kVK_*` 가 없다. 이유는 `mac_alias` 로 갈린다.
    mac: ?u16 = null,
    /// `mac` 이 null 인 이유가 **겹침**일 때 그 대체 자리. macOS 는 이 키를 저 자리로
    /// 보고한다 — 사용자에게 "그 이름을 쓰라" 고 안내할 수 있다.
    mac_alias: ?PhysicalCode = null,
};

/// 단일 출처. 이름 조회 · 값 조회 · 역방향 조회가 모두 이 표를 본다.
const table = [_]Entry{
    // ── Function ────────────────────────────────────────────────────────────
    .{ .code = .f1, .name = "F1", .evdev = 59, .scan = 0x3B, .mac = 0x7A },
    .{ .code = .f2, .name = "F2", .evdev = 60, .scan = 0x3C, .mac = 0x78 },
    .{ .code = .f3, .name = "F3", .evdev = 61, .scan = 0x3D, .mac = 0x63 },
    .{ .code = .f4, .name = "F4", .evdev = 62, .scan = 0x3E, .mac = 0x76 },
    .{ .code = .f5, .name = "F5", .evdev = 63, .scan = 0x3F, .mac = 0x60 },
    .{ .code = .f6, .name = "F6", .evdev = 64, .scan = 0x40, .mac = 0x61 },
    .{ .code = .f7, .name = "F7", .evdev = 65, .scan = 0x41, .mac = 0x62 },
    .{ .code = .f8, .name = "F8", .evdev = 66, .scan = 0x42, .mac = 0x64 },
    .{ .code = .f9, .name = "F9", .evdev = 67, .scan = 0x43, .mac = 0x65 },
    .{ .code = .f10, .name = "F10", .evdev = 68, .scan = 0x44, .mac = 0x6D },
    // F11 / F12 는 F10 다음이 아니다 — set 1 에서 0x57 / 0x58 로 떨어져 있고
    // evdev 도 그것을 따라 87 / 88 이다.
    .{ .code = .f11, .name = "F11", .evdev = 87, .scan = 0x57, .mac = 0x67 },
    .{ .code = .f12, .name = "F12", .evdev = 88, .scan = 0x58, .mac = 0x6F },
    // F13~F20 의 macOS 값은 순서대로가 아니다 (Apple 헤더의 실제 값). Apple 확장
    // 자판이 F13~F15 를 PC 의 PrtSc / ScrLk / Pause 자리에 둔다 — 그래서 그 세 키가
    // 여기로 겹쳐 들어온다 (아래 `mac_alias`).
    .{ .code = .f13, .name = "F13", .evdev = 183, .scan = 0x64, .mac = 0x69 },
    .{ .code = .f14, .name = "F14", .evdev = 184, .scan = 0x65, .mac = 0x6B },
    .{ .code = .f15, .name = "F15", .evdev = 185, .scan = 0x66, .mac = 0x71 },
    .{ .code = .f16, .name = "F16", .evdev = 186, .scan = 0x67, .mac = 0x6A },
    .{ .code = .f17, .name = "F17", .evdev = 187, .scan = 0x68, .mac = 0x40 },
    .{ .code = .f18, .name = "F18", .evdev = 188, .scan = 0x69, .mac = 0x4F },
    .{ .code = .f19, .name = "F19", .evdev = 189, .scan = 0x6A, .mac = 0x50 },
    .{ .code = .f20, .name = "F20", .evdev = 190, .scan = 0x6B, .mac = 0x5A },
    // F21~F24 는 Apple 의 `kVK_*` 가 F20 에서 멈춰 정말로 없다 (대체 자리도 없다).
    .{ .code = .f21, .name = "F21", .evdev = 191, .scan = 0x6C },
    .{ .code = .f22, .name = "F22", .evdev = 192, .scan = 0x6D },
    .{ .code = .f23, .name = "F23", .evdev = 193, .scan = 0x6E },
    .{ .code = .f24, .name = "F24", .evdev = 194, .scan = 0x6F },

    // ── 글자 — QWERTY 자리 이름이다. `KeyW` 는 "US QWERTY 에서 `w` 가 있는 자리"
    // 이고 그 자리는 AZERTY 에서 `z` 를, 키릴에서 `ц` 를 낸다.
    .{ .code = .key_a, .name = "KeyA", .evdev = 30, .scan = 0x1E, .mac = 0x00 },
    .{ .code = .key_b, .name = "KeyB", .evdev = 48, .scan = 0x30, .mac = 0x0B },
    .{ .code = .key_c, .name = "KeyC", .evdev = 46, .scan = 0x2E, .mac = 0x08 },
    .{ .code = .key_d, .name = "KeyD", .evdev = 32, .scan = 0x20, .mac = 0x02 },
    .{ .code = .key_e, .name = "KeyE", .evdev = 18, .scan = 0x12, .mac = 0x0E },
    .{ .code = .key_f, .name = "KeyF", .evdev = 33, .scan = 0x21, .mac = 0x03 },
    .{ .code = .key_g, .name = "KeyG", .evdev = 34, .scan = 0x22, .mac = 0x05 },
    .{ .code = .key_h, .name = "KeyH", .evdev = 35, .scan = 0x23, .mac = 0x04 },
    .{ .code = .key_i, .name = "KeyI", .evdev = 23, .scan = 0x17, .mac = 0x22 },
    .{ .code = .key_j, .name = "KeyJ", .evdev = 36, .scan = 0x24, .mac = 0x26 },
    .{ .code = .key_k, .name = "KeyK", .evdev = 37, .scan = 0x25, .mac = 0x28 },
    .{ .code = .key_l, .name = "KeyL", .evdev = 38, .scan = 0x26, .mac = 0x25 },
    .{ .code = .key_m, .name = "KeyM", .evdev = 50, .scan = 0x32, .mac = 0x2E },
    .{ .code = .key_n, .name = "KeyN", .evdev = 49, .scan = 0x31, .mac = 0x2D },
    .{ .code = .key_o, .name = "KeyO", .evdev = 24, .scan = 0x18, .mac = 0x1F },
    .{ .code = .key_p, .name = "KeyP", .evdev = 25, .scan = 0x19, .mac = 0x23 },
    .{ .code = .key_q, .name = "KeyQ", .evdev = 16, .scan = 0x10, .mac = 0x0C },
    .{ .code = .key_r, .name = "KeyR", .evdev = 19, .scan = 0x13, .mac = 0x0F },
    .{ .code = .key_s, .name = "KeyS", .evdev = 31, .scan = 0x1F, .mac = 0x01 },
    .{ .code = .key_t, .name = "KeyT", .evdev = 20, .scan = 0x14, .mac = 0x11 },
    .{ .code = .key_u, .name = "KeyU", .evdev = 22, .scan = 0x16, .mac = 0x20 },
    .{ .code = .key_v, .name = "KeyV", .evdev = 47, .scan = 0x2F, .mac = 0x09 },
    .{ .code = .key_w, .name = "KeyW", .evdev = 17, .scan = 0x11, .mac = 0x0D },
    .{ .code = .key_x, .name = "KeyX", .evdev = 45, .scan = 0x2D, .mac = 0x07 },
    .{ .code = .key_y, .name = "KeyY", .evdev = 21, .scan = 0x15, .mac = 0x10 },
    .{ .code = .key_z, .name = "KeyZ", .evdev = 44, .scan = 0x2C, .mac = 0x06 },

    // ── 숫자열. macOS 값이 순서대로가 아니다 — `kVK_ANSI_6` (0x16) 이 `kVK_ANSI_5`
    // (0x17) 보다 작다. Apple 헤더의 실제 값이며 오타가 아니다.
    .{ .code = .digit1, .name = "Digit1", .evdev = 2, .scan = 0x02, .mac = 0x12 },
    .{ .code = .digit2, .name = "Digit2", .evdev = 3, .scan = 0x03, .mac = 0x13 },
    .{ .code = .digit3, .name = "Digit3", .evdev = 4, .scan = 0x04, .mac = 0x14 },
    .{ .code = .digit4, .name = "Digit4", .evdev = 5, .scan = 0x05, .mac = 0x15 },
    .{ .code = .digit5, .name = "Digit5", .evdev = 6, .scan = 0x06, .mac = 0x17 },
    .{ .code = .digit6, .name = "Digit6", .evdev = 7, .scan = 0x07, .mac = 0x16 },
    .{ .code = .digit7, .name = "Digit7", .evdev = 8, .scan = 0x08, .mac = 0x1A },
    .{ .code = .digit8, .name = "Digit8", .evdev = 9, .scan = 0x09, .mac = 0x1C },
    .{ .code = .digit9, .name = "Digit9", .evdev = 10, .scan = 0x0A, .mac = 0x19 },
    // `Digit0` 은 숫자열 맨 오른쪽이라 `Digit9` 다음이다 — 값이 0 부터 시작하지
    // 않는다.
    .{ .code = .digit0, .name = "Digit0", .evdev = 11, .scan = 0x0B, .mac = 0x1D },

    // ── 기호 자리. `-` 와 `_` 처럼 Shift 로 갈리는 두 글자가 **한 자리**이므로
    // 이름이 무시프트 글자 기준이다 (W3C 규칙).
    .{ .code = .backquote, .name = "Backquote", .evdev = 41, .scan = 0x29, .mac = 0x32 },
    .{ .code = .minus, .name = "Minus", .evdev = 12, .scan = 0x0C, .mac = 0x1B },
    .{ .code = .equal, .name = "Equal", .evdev = 13, .scan = 0x0D, .mac = 0x18 },
    .{ .code = .bracket_left, .name = "BracketLeft", .evdev = 26, .scan = 0x1A, .mac = 0x21 },
    .{ .code = .bracket_right, .name = "BracketRight", .evdev = 27, .scan = 0x1B, .mac = 0x1E },
    .{ .code = .backslash, .name = "Backslash", .evdev = 43, .scan = 0x2B, .mac = 0x2A },
    .{ .code = .semicolon, .name = "Semicolon", .evdev = 39, .scan = 0x27, .mac = 0x29 },
    .{ .code = .quote, .name = "Quote", .evdev = 40, .scan = 0x28, .mac = 0x27 },
    .{ .code = .comma, .name = "Comma", .evdev = 51, .scan = 0x33, .mac = 0x2B },
    .{ .code = .period, .name = "Period", .evdev = 52, .scan = 0x34, .mac = 0x2F },
    .{ .code = .slash, .name = "Slash", .evdev = 53, .scan = 0x35, .mac = 0x2C },
    // ISO 자판의 추가 키 — US ANSI 에는 **없다.** AZERTY 의 `<>`, QWERTZ 의 `<>|`
    // 자리다 (`KEY_102ND`). macOS 는 `kVK_ISO_Section` 이라는 다른 이름을 쓴다.
    // 이 키가 있어야 그 자판 사용자가 자기 키보드의 모든 키를 쓸 수 있다.
    .{ .code = .intl_backslash, .name = "IntlBackslash", .evdev = 86, .scan = 0x56, .mac = 0x0A },
    .{ .code = .intl_yen, .name = "IntlYen", .evdev = 124, .scan = 0x7D, .mac = 0x5D },
    .{ .code = .intl_ro, .name = "IntlRo", .evdev = 89, .scan = 0x73, .mac = 0x5E },

    // ── Functional ──────────────────────────────────────────────────────────
    .{ .code = .space, .name = "Space", .evdev = 57, .scan = 0x39, .mac = 0x31 },
    .{ .code = .tab, .name = "Tab", .evdev = 15, .scan = 0x0F, .mac = 0x30 },
    .{ .code = .escape, .name = "Escape", .evdev = 1, .scan = 0x01, .mac = 0x35 },
    // W3C 는 main block 의 return 키를 `Enter` 라 부른다 (`Return` 이 아니다).
    .{ .code = .enter, .name = "Enter", .evdev = 28, .scan = 0x1C, .mac = 0x24 },
    .{ .code = .backspace, .name = "Backspace", .evdev = 14, .scan = 0x0E, .mac = 0x33 },
    .{ .code = .caps_lock, .name = "CapsLock", .evdev = 58, .scan = 0x3A, .mac = 0x39 },
    // PC 자판을 Mac 에 꽂으면 이 세 키가 F13 / F14 / F15 로 보고된다. 키가 없는 것이
    // 아니라 별 `kVK_*` 가 없는 것이다 — 그래서 대체 자리를 적어 안내에 쓴다.
    .{ .code = .print_screen, .name = "PrintScreen", .evdev = 99, .scan = 0x37, .extended = true, .mac_alias = .f13 },
    .{ .code = .scroll_lock, .name = "ScrollLock", .evdev = 70, .scan = 0x46, .mac_alias = .f14 },
    .{ .code = .pause, .name = "Pause", .evdev = 119, .scan = 0x45, .extended = true, .mac_alias = .f15 },
    // 메뉴 키는 macOS 에 값이 있다 (`0x6E`) — 외장 PC 자판에서 동작한다.
    .{ .code = .context_menu, .name = "ContextMenu", .evdev = 127, .scan = 0x5D, .extended = true, .mac = 0x6E },
    .{ .code = .lang1, .name = "Lang1", .evdev = 122, .scan = 0xF2, .mac = 0x68 },
    .{ .code = .lang2, .name = "Lang2", .evdev = 123, .scan = 0xF1, .mac = 0x66 },
    // JIS 입력 전환 키 — macOS 가 다르게 처리해 `kVK_*` 가 없고 대체 자리도 없다.
    .{ .code = .convert, .name = "Convert", .evdev = 92, .scan = 0x79 },
    .{ .code = .non_convert, .name = "NonConvert", .evdev = 94, .scan = 0x7B },
    .{ .code = .kana_mode, .name = "KanaMode", .evdev = 93, .scan = 0x70 },

    // ── Control pad — Windows 는 전부 extended 다. 그 비트가 없으면 numpad 와
    // 구분되지 않는다 (모듈 주석의 충돌 표 참고).
    .{ .code = .insert, .name = "Insert", .evdev = 110, .scan = 0x52, .extended = true, .mac = 0x72 },
    .{ .code = .delete, .name = "Delete", .evdev = 111, .scan = 0x53, .extended = true, .mac = 0x75 },
    .{ .code = .home, .name = "Home", .evdev = 102, .scan = 0x47, .extended = true, .mac = 0x73 },
    .{ .code = .end, .name = "End", .evdev = 107, .scan = 0x4F, .extended = true, .mac = 0x77 },
    .{ .code = .page_up, .name = "PageUp", .evdev = 104, .scan = 0x49, .extended = true, .mac = 0x74 },
    .{ .code = .page_down, .name = "PageDown", .evdev = 109, .scan = 0x51, .extended = true, .mac = 0x79 },

    // ── Arrow pad ───────────────────────────────────────────────────────────
    .{ .code = .arrow_up, .name = "ArrowUp", .evdev = 103, .scan = 0x48, .extended = true, .mac = 0x7E },
    .{ .code = .arrow_down, .name = "ArrowDown", .evdev = 108, .scan = 0x50, .extended = true, .mac = 0x7D },
    .{ .code = .arrow_left, .name = "ArrowLeft", .evdev = 105, .scan = 0x4B, .extended = true, .mac = 0x7B },
    .{ .code = .arrow_right, .name = "ArrowRight", .evdev = 106, .scan = 0x4D, .extended = true, .mac = 0x7C },

    // ── Numpad — Windows 는 `NumpadDivide` / `NumpadEnter` 만 extended 다.
    // macOS 는 `kVK_ANSI_Keypad*` 이고 `NumLock` 자리가 `kVK_ANSI_KeypadClear` 다.
    .{ .code = .num_lock, .name = "NumLock", .evdev = 69, .scan = 0x45, .mac = 0x47 },
    .{ .code = .numpad0, .name = "Numpad0", .evdev = 82, .scan = 0x52, .mac = 0x52 },
    .{ .code = .numpad1, .name = "Numpad1", .evdev = 79, .scan = 0x4F, .mac = 0x53 },
    .{ .code = .numpad2, .name = "Numpad2", .evdev = 80, .scan = 0x50, .mac = 0x54 },
    .{ .code = .numpad3, .name = "Numpad3", .evdev = 81, .scan = 0x51, .mac = 0x55 },
    .{ .code = .numpad4, .name = "Numpad4", .evdev = 75, .scan = 0x4B, .mac = 0x56 },
    .{ .code = .numpad5, .name = "Numpad5", .evdev = 76, .scan = 0x4C, .mac = 0x57 },
    .{ .code = .numpad6, .name = "Numpad6", .evdev = 77, .scan = 0x4D, .mac = 0x58 },
    .{ .code = .numpad7, .name = "Numpad7", .evdev = 71, .scan = 0x47, .mac = 0x59 },
    .{ .code = .numpad8, .name = "Numpad8", .evdev = 72, .scan = 0x48, .mac = 0x5B },
    .{ .code = .numpad9, .name = "Numpad9", .evdev = 73, .scan = 0x49, .mac = 0x5C },
    .{ .code = .numpad_divide, .name = "NumpadDivide", .evdev = 98, .scan = 0x35, .extended = true, .mac = 0x4B },
    .{ .code = .numpad_multiply, .name = "NumpadMultiply", .evdev = 55, .scan = 0x37, .mac = 0x43 },
    .{ .code = .numpad_subtract, .name = "NumpadSubtract", .evdev = 74, .scan = 0x4A, .mac = 0x4E },
    .{ .code = .numpad_add, .name = "NumpadAdd", .evdev = 78, .scan = 0x4E, .mac = 0x45 },
    .{ .code = .numpad_enter, .name = "NumpadEnter", .evdev = 96, .scan = 0x1C, .extended = true, .mac = 0x4C },
    .{ .code = .numpad_decimal, .name = "NumpadDecimal", .evdev = 83, .scan = 0x53, .mac = 0x41 },
    .{ .code = .numpad_equal, .name = "NumpadEqual", .evdev = 117, .scan = 0x59, .mac = 0x51 },
};

/// `[...]` 안의 이름 → code. 대소문자 무관 — config 의 다른 토큰이 모두 그렇다.
pub fn fromName(text: []const u8) ?PhysicalCode {
    for (table) |e| {
        if (std.ascii.eqlIgnoreCase(text, e.name)) return e.code;
    }
    return null;
}

/// code → W3C 표기. 사용자에게 되돌려 줄 때 (설정 UI · 오류 메시지) 쓴다.
pub fn name(code: PhysicalCode) []const u8 {
    return entry(code).name;
}

pub fn evdev(code: PhysicalCode) u16 {
    return entry(code).evdev;
}

pub const ScanCode = struct {
    value: u16,
    /// `0xE0` prefix (lParam bit 24).
    extended: bool,
};

pub fn scanCode(code: PhysicalCode) ScanCode {
    const e = entry(code);
    return .{ .value = e.scan, .extended = e.extended };
}

/// null = 이 자리는 macOS 에 별 `kVK_*` 가 없다. 이유는 `macAlias` 로 갈린다.
pub fn macKeyCode(code: PhysicalCode) ?u16 {
    return entry(code).mac;
}

/// macOS 가 이 키를 **다른 자리로 보고**할 때 그 자리. `PrintScreen` → `F13` 처럼
/// "쓸 수 없다" 가 아니라 "저 이름으로 쓰라" 고 안내할 수 있게 한다.
pub fn macAlias(code: PhysicalCode) ?PhysicalCode {
    return entry(code).mac_alias;
}

/// 이 platform 에서 쓸 수 있는 자리인가. false 면 config 파싱이 거부해야 한다 —
/// 조용히 미동작으로 두면 사용자가 이유를 알 수 없다.
pub fn availableOnThisPlatform(code: PhysicalCode) bool {
    if (builtin.os.tag == .macos) return entry(code).mac != null;
    return true;
}

pub fn fromEvdev(value: u32) ?PhysicalCode {
    for (table) |e| {
        if (e.evdev == value) return e.code;
    }
    return null;
}

pub fn fromScanCode(value: u32, extended: bool) ?PhysicalCode {
    for (table) |e| {
        if (e.scan == value and e.extended == extended) return e.code;
    }
    return null;
}

pub fn fromMacKeyCode(value: u32) ?PhysicalCode {
    for (table) |e| {
        if (e.mac) |m| {
            if (m == value) return e.code;
        }
    }
    return null;
}

fn entry(code: PhysicalCode) Entry {
    for (table) |e| {
        if (e.code == code) return e;
    }
    // 아래 test 가 enum 전수를 고정하므로 여기 도달하면 표에 구멍이 난 것이다.
    unreachable;
}

test "표가 enum 을 빠짐없이 정확히 한 번씩 덮는다" {
    const fields = @typeInfo(PhysicalCode).@"enum".fields;
    try std.testing.expectEqual(fields.len, table.len);
    inline for (fields) |f| {
        const code = @field(PhysicalCode, f.name);
        var seen: usize = 0;
        for (table) |e| {
            if (e.code == code) seen += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), seen);
    }
}

test "세 platform 값이 각각 유일하다" {
    // 값이 겹치면 역방향 조회 (`fromEvdev` 등) 가 엉뚱한 code 를 준다.
    for (table, 0..) |a, i| {
        for (table[i + 1 ..]) |b| {
            try std.testing.expect(a.evdev != b.evdev);
            // Windows 는 (scan, extended) 쌍이 열이다 — 하위 바이트만으로는 control
            // pad 와 numpad 가 겹친다.
            try std.testing.expect(!(a.scan == b.scan and a.extended == b.extended));
            try std.testing.expect(!std.ascii.eqlIgnoreCase(a.name, b.name));
            if (a.mac) |am| {
                if (b.mac) |bm| try std.testing.expect(am != bm);
            }
        }
    }
}

test "extended 비트 없이는 Windows 열이 겹친다" {
    // 이 test 가 `extended` 열의 존재 이유다. 아래 쌍들은 하위 바이트가 같고
    // extended 로만 갈린다 — 비트를 빼면 위 유일성 test 가 깨진다.
    const collisions = [_]struct { a: PhysicalCode, b: PhysicalCode }{
        .{ .a = .insert, .b = .numpad0 },
        .{ .a = .delete, .b = .numpad_decimal },
        .{ .a = .numpad_enter, .b = .enter },
        .{ .a = .numpad_divide, .b = .slash },
        .{ .a = .home, .b = .numpad7 },
        .{ .a = .page_up, .b = .numpad9 },
        .{ .a = .end, .b = .numpad1 },
        .{ .a = .page_down, .b = .numpad3 },
        .{ .a = .arrow_up, .b = .numpad8 },
        .{ .a = .arrow_down, .b = .numpad2 },
        .{ .a = .arrow_left, .b = .numpad4 },
        .{ .a = .arrow_right, .b = .numpad6 },
        .{ .a = .print_screen, .b = .numpad_multiply },
        .{ .a = .pause, .b = .num_lock },
    };
    for (collisions) |c| {
        const sa = scanCode(c.a);
        const sb = scanCode(c.b);
        try std.testing.expectEqual(sa.value, sb.value);
        try std.testing.expect(sa.extended != sb.extended);
        // 그래도 역방향 조회는 갈린다.
        try std.testing.expectEqual(c.a, fromScanCode(sa.value, sa.extended).?);
        try std.testing.expectEqual(c.b, fromScanCode(sb.value, sb.extended).?);
    }
}

test "이름 왕복" {
    for (table) |e| {
        try std.testing.expectEqual(e.code, fromName(e.name).?);
        try std.testing.expectEqualStrings(e.name, name(e.code));
    }
    // 대소문자 무관.
    try std.testing.expectEqual(PhysicalCode.key_w, fromName("keyw").?);
    try std.testing.expectEqual(PhysicalCode.key_w, fromName("KEYW").?);
    try std.testing.expectEqual(PhysicalCode.bracket_left, fromName("bracketleft").?);
    // 라벨 집합에 없는 자리도 위치로는 받는다 — 자판이 낼 수 있는 키에 제한을 두지
    // 않는다.
    try std.testing.expectEqual(PhysicalCode.minus, fromName("Minus").?);
    try std.testing.expectEqual(PhysicalCode.slash, fromName("Slash").?);
    try std.testing.expectEqual(PhysicalCode.intl_backslash, fromName("IntlBackslash").?);
    try std.testing.expectEqual(PhysicalCode.numpad7, fromName("Numpad7").?);
    try std.testing.expectEqual(PhysicalCode.arrow_up, fromName("ArrowUp").?);
    try std.testing.expectEqual(PhysicalCode.f24, fromName("F24").?);
    try std.testing.expectEqual(PhysicalCode.intl_yen, fromName("IntlYen").?);
    try std.testing.expectEqual(PhysicalCode.context_menu, fromName("ContextMenu").?);
    // 담지 않는 것 — modifier 자체와 media / browser 키. 오타도 여전히 거부한다.
    try std.testing.expectEqual(@as(?PhysicalCode, null), fromName("ShiftLeft"));
    try std.testing.expectEqual(@as(?PhysicalCode, null), fromName("MetaLeft"));
    try std.testing.expectEqual(@as(?PhysicalCode, null), fromName("MediaPlayPause"));
    try std.testing.expectEqual(@as(?PhysicalCode, null), fromName("F25"));
    try std.testing.expectEqual(@as(?PhysicalCode, null), fromName("NotAKey"));
    try std.testing.expectEqual(@as(?PhysicalCode, null), fromName(""));
}

test "값 왕복" {
    for (table) |e| {
        try std.testing.expectEqual(e.code, fromEvdev(e.evdev).?);
        try std.testing.expectEqual(e.code, fromScanCode(e.scan, e.extended).?);
        try std.testing.expectEqual(e.evdev, evdev(e.code));
        const sc = scanCode(e.code);
        try std.testing.expectEqual(e.scan, sc.value);
        try std.testing.expectEqual(e.extended, sc.extended);
        if (e.mac) |m| {
            try std.testing.expectEqual(e.code, fromMacKeyCode(m).?);
            try std.testing.expectEqual(m, macKeyCode(e.code).?);
        } else {
            try std.testing.expectEqual(@as(?u16, null), macKeyCode(e.code));
        }
    }
}

test "macOS 에 kVK 가 없는 자리와 그 이유를 고정한다" {
    // 사용자에게 보이는 동작 (파싱 거부 + 안내 문구) 이므로 우연히 늘거나 줄지 않게
    // 못을 박는다. **겹침**과 **부재**를 갈라 적는다 — 안내가 다르다.
    const aliased = [_]struct { code: PhysicalCode, alias: PhysicalCode }{
        // PC 자판을 Mac 에 꽂으면 이 자리가 F13~F15 로 보고된다. 키가 없는 것이
        // 아니다 — 이전에 `²` 에서 한 번 틀린 것과 같은 종류의 구분이다.
        .{ .code = .print_screen, .alias = .f13 },
        .{ .code = .scroll_lock, .alias = .f14 },
        .{ .code = .pause, .alias = .f15 },
    };
    for (aliased) |a| {
        try std.testing.expectEqual(@as(?u16, null), macKeyCode(a.code));
        try std.testing.expectEqual(a.alias, macAlias(a.code).?);
        // 대체 자리에는 값이 있어야 안내가 성립한다.
        try std.testing.expect(macKeyCode(a.alias) != null);
    }

    const absent = [_]PhysicalCode{ .f21, .f22, .f23, .f24, .convert, .non_convert, .kana_mode };
    for (absent) |c| {
        try std.testing.expectEqual(@as(?u16, null), macKeyCode(c));
        // 대체 자리가 없다 — 그래서 안내가 "이 platform 에서는 쓸 수 없다" 가 된다.
        try std.testing.expectEqual(@as(?PhysicalCode, null), macAlias(c));
    }

    // 메뉴 키는 값이 **있다.** 한 번 "없다" 고 적었던 자리라 못을 박는다.
    try std.testing.expectEqual(@as(u16, 0x6E), macKeyCode(.context_menu).?);

    var count: usize = 0;
    for (table) |e| {
        if (e.mac == null) count += 1;
    }
    try std.testing.expectEqual(aliased.len + absent.len, count);
}

test "evdev 와 scan code 가 main block 에서 같고 extended 에서 갈린다" {
    // 이 성질에 코드가 기대지 않는다는 것을 문서화하는 test 다 — 두 열을 따로
    // 적는 이유가 여기 있다.
    try std.testing.expectEqual(evdev(.key_q), scanCode(.key_q).value);
    try std.testing.expectEqual(evdev(.f12), scanCode(.f12).value);
    try std.testing.expect(evdev(.page_up) != scanCode(.page_up).value);
    try std.testing.expect(evdev(.arrow_up) != scanCode(.arrow_up).value);
}
