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
//! ## 수용 범위 — 자판의 모든 키를 담는다
//!
//! 라벨 집합보다 **넓다.** 처음엔 1:1 로 맞췄는데 (라벨이 거부하는 것을 위치만
//! 받으면 수용 집합이 조용히 넓어지므로) 그 제약을 명시적으로 걷었다.
//!
//! 근거는 두 집합의 **의미가 다르다**는 것이다. 라벨을 넓히려면 `-` 에 어떤 값을
//! 줄지 정해야 하는데, `VK_OEM_MINUS` / `kVK_ANSI_Minus` 는 라벨이 아니라 "US 자판
//! 에서 `-` 가 있는 자리" 다. 그것을 라벨로 받으면 Linux 는 라벨로, Windows ·
//! macOS 는 US 위치로 잡아 #496 의 세 갈래 불일치가 더 깊어진다. 라벨을 정직하게
//! 넓히려면 live layout 조회가 필요하다 (macOS `UCKeyTranslate`, Windows
//! `VkKeyScanEx`) — #496 항목 2 다.
//!
//! 위치 쪽은 그 문제가 없다. `[Minus]` 는 처음부터 "그 자리" 이고 세 platform 에
//! 고정값이 있다. 그래서 **자판에 있는 키는 위치로 다 쓸 수 있게** 한다.
//!
//! 아직 없는 것: numpad · media 키 · JIS 전용 키 (`IntlYen` · `IntlRo`). 값 검증이
//! 안 됐고 요청도 없었다. 필요하면 표에 행을 더하면 된다.
//!
//! ## 세 platform 값
//!
//! | 열 | 의미 | 출처 |
//! |---|---|---|
//! | `evdev` | Linux evdev keycode | `linux/input-event-codes.h` |
//! | `scan` | Windows scan code (set 1 make code) | `WM_KEYDOWN` lParam bit 16~23 |
//! | `mac` | macOS hardware keyCode | `Carbon/HIToolbox/Events.h` `kVK_*` |
//!
//! evdev 와 set-1 scan code 는 main block 에서 값이 같다 (evdev 가 set 1 에서 왔다).
//! 그래도 두 열을 따로 적는다 — PageUp / PageDown 처럼 extended 키에서 갈리고
//! (evdev 104 vs scan 0x49), 같은 값을 우연에 맡기면 나중에 조용히 어긋난다.
//!
//! `mac` 열은 `config.zig` 의 `MacHotkey.keycodeFromKey` 와 **값이 같아야 한다** —
//! 그쪽이 이미 US 위치표이기 때문이다 (그래서 AZERTY macOS 에서 `Z` 라고 새겨진
//! 키가 `w` 로 잡힌다. #496 항목 2). 두 표가 갈라지면 `[KeyW]` 와 라벨 `w` 가 macOS
//! 에서 서로 다른 키가 되고 증상이 조용하다. `config.zig` 의
//! `test "#496 physical_key 의 macOS 열이 keycodeFromKey 와 같다"` 가 그것을 고정한다.

const std = @import("std");

/// W3C `KeyboardEvent.code` 값 중 TildaZ 가 받는 것.
pub const PhysicalCode = enum {
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

    backquote,
    bracket_left,
    bracket_right,
    minus,
    equal,
    semicolon,
    quote,
    backslash,
    comma,
    period,
    slash,
    /// ISO 자판에만 있는 키 (AZERTY 의 `<>`, QWERTZ 의 `<>|`). US ANSI 에는 없다.
    intl_backslash,

    space,
    tab,
    escape,
    enter,
    page_up,
    page_down,
};

const Entry = struct {
    code: PhysicalCode,
    /// W3C 표기 그대로. 대소문자까지 표준이다 — 사용자에게 되돌려 줄 때 이 문자열을
    /// 쓴다 (`[KeyW]`).
    name: []const u8,
    evdev: u16,
    scan: u16,
    mac: u16,
};

/// 단일 출처. 이름 조회 · 값 조회 · 역방향 조회가 모두 이 표를 본다.
const table = [_]Entry{
    // Function key — layout 무관이라 위치로 적을 이유는 없지만, 라벨 집합에 있는
    // 키는 위치로도 적을 수 있어야 한다 (한쪽만 받으면 그 자체가 함정이다).
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

    // 글자 — QWERTY 자리 이름이다. `KeyW` 는 "US QWERTY 에서 `w` 가 있는 자리" 이고
    // 그 자리는 AZERTY 에서 `z` 를, 키릴에서 `ц` 를 낸다.
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

    // 숫자열. macOS 값이 순서대로가 아니다 — `kVK_ANSI_6` (0x16) 이 `kVK_ANSI_5`
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

    .{ .code = .backquote, .name = "Backquote", .evdev = 41, .scan = 0x29, .mac = 0x32 },
    .{ .code = .bracket_left, .name = "BracketLeft", .evdev = 26, .scan = 0x1A, .mac = 0x21 },
    .{ .code = .bracket_right, .name = "BracketRight", .evdev = 27, .scan = 0x1B, .mac = 0x1E },

    // ASCII 기호 자리. 라벨 집합에는 없지만 (#208) 위치로는 받는다 — 위 정책 문단
    // 참고. `-` 와 `_` 처럼 Shift 로 갈리는 두 글자가 **한 자리**이므로 이름이
    // 무시프트 글자 기준이다 (W3C 규칙).
    .{ .code = .minus, .name = "Minus", .evdev = 12, .scan = 0x0C, .mac = 0x1B },
    .{ .code = .equal, .name = "Equal", .evdev = 13, .scan = 0x0D, .mac = 0x18 },
    .{ .code = .semicolon, .name = "Semicolon", .evdev = 39, .scan = 0x27, .mac = 0x29 },
    .{ .code = .quote, .name = "Quote", .evdev = 40, .scan = 0x28, .mac = 0x27 },
    .{ .code = .backslash, .name = "Backslash", .evdev = 43, .scan = 0x2B, .mac = 0x2A },
    .{ .code = .comma, .name = "Comma", .evdev = 51, .scan = 0x33, .mac = 0x2B },
    .{ .code = .period, .name = "Period", .evdev = 52, .scan = 0x34, .mac = 0x2F },
    .{ .code = .slash, .name = "Slash", .evdev = 53, .scan = 0x35, .mac = 0x2C },
    // ISO 자판의 추가 키 — US ANSI 에는 **없다.** AZERTY 의 `<>`, QWERTZ 의 `<>|`
    // 자리다. `KEY_102ND` / 102-key 자판의 그 키이고, macOS 는 `kVK_ISO_Section`
    // 이라는 다른 이름을 쓴다. 이 키가 있어야 그 자판 사용자가 "내 키보드의 모든
    // 키" 를 실제로 다 쓸 수 있다.
    .{ .code = .intl_backslash, .name = "IntlBackslash", .evdev = 86, .scan = 0x56, .mac = 0x0A },

    .{ .code = .space, .name = "Space", .evdev = 57, .scan = 0x39, .mac = 0x31 },
    .{ .code = .tab, .name = "Tab", .evdev = 15, .scan = 0x0F, .mac = 0x30 },
    .{ .code = .escape, .name = "Escape", .evdev = 1, .scan = 0x01, .mac = 0x35 },
    // W3C 는 main block 의 return 키를 `Enter` 라 부른다 (`Return` 이 아니다).
    .{ .code = .enter, .name = "Enter", .evdev = 28, .scan = 0x1C, .mac = 0x24 },
    // extended 키 — 여기서 evdev 와 scan 이 갈린다. scan 은 `0xE0` prefix 를 뗀
    // 값이다 (`WM_KEYDOWN` lParam 의 bit 16~23 에 그 하위 byte 만 온다).
    .{ .code = .page_up, .name = "PageUp", .evdev = 104, .scan = 0x49, .mac = 0x74 },
    .{ .code = .page_down, .name = "PageDown", .evdev = 109, .scan = 0x51, .mac = 0x79 },
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

pub fn scanCode(code: PhysicalCode) u16 {
    return entry(code).scan;
}

pub fn macKeyCode(code: PhysicalCode) u16 {
    return entry(code).mac;
}

pub fn fromEvdev(value: u32) ?PhysicalCode {
    for (table) |e| {
        if (e.evdev == value) return e.code;
    }
    return null;
}

pub fn fromScanCode(value: u32) ?PhysicalCode {
    for (table) |e| {
        if (e.scan == value) return e.code;
    }
    return null;
}

pub fn fromMacKeyCode(value: u32) ?PhysicalCode {
    for (table) |e| {
        if (e.mac == value) return e.code;
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

test "세 platform 값이 code 안에서 각각 유일하다" {
    // 값이 겹치면 역방향 조회 (`fromEvdev` 등) 가 엉뚱한 code 를 준다.
    for (table, 0..) |a, i| {
        for (table[i + 1 ..]) |b| {
            try std.testing.expect(a.evdev != b.evdev);
            try std.testing.expect(a.scan != b.scan);
            try std.testing.expect(a.mac != b.mac);
            try std.testing.expect(!std.ascii.eqlIgnoreCase(a.name, b.name));
        }
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
    // 라벨 집합에 없는 자리도 위치로는 받는다 — 자판에 있는 키를 다 쓸 수 있게.
    try std.testing.expectEqual(PhysicalCode.minus, fromName("Minus").?);
    try std.testing.expectEqual(PhysicalCode.slash, fromName("Slash").?);
    try std.testing.expectEqual(PhysicalCode.backslash, fromName("Backslash").?);
    try std.testing.expectEqual(PhysicalCode.intl_backslash, fromName("IntlBackslash").?);
    // 표에 없는 이름은 여전히 거부한다 — 오타가 조용히 통과하면 안 된다.
    try std.testing.expectEqual(@as(?PhysicalCode, null), fromName("F13"));
    try std.testing.expectEqual(@as(?PhysicalCode, null), fromName("Numpad0"));
    try std.testing.expectEqual(@as(?PhysicalCode, null), fromName("IntlYen"));
    try std.testing.expectEqual(@as(?PhysicalCode, null), fromName(""));
}

test "값 왕복" {
    for (table) |e| {
        try std.testing.expectEqual(e.code, fromEvdev(e.evdev).?);
        try std.testing.expectEqual(e.code, fromScanCode(e.scan).?);
        try std.testing.expectEqual(e.code, fromMacKeyCode(e.mac).?);
        try std.testing.expectEqual(e.evdev, evdev(e.code));
        try std.testing.expectEqual(e.scan, scanCode(e.code));
        try std.testing.expectEqual(e.mac, macKeyCode(e.code));
    }
}

test "evdev 와 scan code 가 main block 에서 같고 extended 에서 갈린다" {
    // 이 성질에 코드가 기대지 않는다는 것을 문서화하는 test 다 — 두 열을 따로
    // 적는 이유가 여기 있다.
    try std.testing.expectEqual(evdev(.key_q), scanCode(.key_q));
    try std.testing.expectEqual(evdev(.f12), scanCode(.f12));
    try std.testing.expect(evdev(.page_up) != scanCode(.page_up));
    try std.testing.expect(evdev(.page_down) != scanCode(.page_down));
}
