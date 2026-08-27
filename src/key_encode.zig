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

    /// 이 키가 만든 문자. 없으면 빈 문자열.
    utf8: []const u8 = "",

    /// shift 를 떼었을 때의 코드포인트 (`Shift+a` 면 `'a'`). kitty protocol 이 쓴다.
    unshifted_codepoint: u21 = 0,

    /// 길게 눌러 반복 중인가. 뗌(release) 은 아직 보내지 않는다 — kitty protocol 의
    /// release 보고는 후속 작업이다 (#533 코멘트의 결정).
    repeat: bool = false,
};

/// #533 — `utf8` 로 넘겨도 되는 텍스트만 골라 준다.
///
/// **제어문자를 넘기면 안 된다.** xkb 는 `Ctrl+C` 에 대해 `utf8 = "\x03"` 을 주는데
/// (Win32 의 `WM_CHAR` 도 같다), 그것을 그대로 넘기면 인코더가 "일반 문자에 ctrl 이
/// 붙었다" 로 보고 CSI u 로 감싼다 — 실측으로 `\x1b[3;5u` 가 나왔다. 그러면 셸이
/// SIGINT 를 받지 못한다.
///
/// 제어문자는 `code` 와 `mods` 만 주면 인코더가 알아서 만든다 (실측: `\x03`). 그래서
/// 여기서 걸러 낸다. 멀티바이트 UTF-8 은 첫 바이트가 0x20 이상이라 걸리지 않는다.
pub fn textForEncoding(utf8: []const u8) []const u8 {
    if (utf8.len == 1 and (utf8[0] < 0x20 or utf8[0] == 0x7f)) return "";
    return utf8;
}

/// `event` 를 `writer` 에 인코딩한다. 출력이 없는 키도 있다 (modifier 키 등) —
/// 호출부가 쓰인 바이트 수를 보고 판단한다.
pub fn encode(
    writer: *std.Io.Writer,
    event: Event,
    opts: Options,
) std.Io.Writer.Error!void {
    return ghostty.input.encodeKey(writer, .{
        .action = if (event.repeat) .repeat else .press,
        .key = toGhosttyKey(event.code),
        .mods = event.mods,
        .consumed_mods = event.consumed_mods,
        .utf8 = textForEncoding(event.utf8),
        .unshifted_codepoint = event.unshifted_codepoint,
    }, opts);
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

test "제어문자 utf8 은 인코더에 넘기지 않는다 — Ctrl+C 가 CSI u 로 새지 않게" {
    // xkb 가 Ctrl+C 에 주는 값을 그대로 재현한다. 걸러 내지 않으면 \x1b[3;5u 가 나온다.
    var buf: [16]u8 = undefined;
    const out = try encodeToBuf(&buf, .{
        .code = .key_c,
        .mods = .{ .ctrl = true },
        .utf8 = "\x03",
        .unshifted_codepoint = 'c',
    }, .{});
    try testing.expectEqualStrings("\x03", out);
}

test "textForEncoding — 제어문자만 걸러 내고 보통 글자는 그대로" {
    try testing.expectEqualStrings("", textForEncoding("\x03"));
    try testing.expectEqualStrings("", textForEncoding("\x1b"));
    try testing.expectEqualStrings("", textForEncoding("\x7f"));
    try testing.expectEqualStrings("", textForEncoding("\r"));
    try testing.expectEqualStrings("a", textForEncoding("a"));
    try testing.expectEqualStrings(" ", textForEncoding(" "));
    try testing.expectEqualStrings("~", textForEncoding("~"));
    // 한글 · emoji 같은 멀티바이트는 첫 바이트가 0x20 이상이라 그대로 지나간다.
    try testing.expectEqualStrings("가", textForEncoding("가"));
    try testing.expectEqualStrings("é", textForEncoding("é"));
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
