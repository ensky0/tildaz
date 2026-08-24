//! TUI mouse reporting 인코더 ([#502](https://github.com/ensky0/tildaz/issues/502)).
//! 앱이 DECSET 으로 켠 mouse tracking (`?9` / `?1000` / `?1002` / `?1003`) 에 대해
//! 클릭 · 드래그 · 휠을 escape sequence 로 인코딩한다.
//!
//! **순수 · 플랫폼 무관 · ghostty 비의존** — `zig test src/mouse_report.zig` 로 단독
//! 검증된다 (`scrollbar.zig` 와 같은 패턴). 그래서 `Tracking` / `Format` 을 ghostty
//! `terminal.mouse.Event` / `.Format` 과 같은 shape 로 다시 정의한다. 변환은 호출부
//! (`app_controller`) 의 *exhaustive switch* 한 곳에만 두어, upstream 이 variant 를
//! 추가하면 컴파일 에러로 드러나게 한다.
//!
//! 판정 규칙은 ghostty 참조 구현 (`src/input/mouse_encode.zig` — `shouldReport` /
//! `buttonCode`) 과 xterm `ctlseqs` 를 그대로 따른다. 그 인코더는 `ghostty-vt` 모듈
//! 밖 (`src/input/`) 이고 `renderer/size.zig` 에 의존해 import 할 수 없다.

const std = @import("std");

/// 앱이 켠 tracking mode. 서로 배타적이라 단일 enum (ghostty 와 같은 모델).
pub const Tracking = enum {
    /// 아무 mode 도 안 켜짐 — 보고하지 않는다.
    none,
    /// `?9` — 왼 · 가운데 · 오른쪽 *누름만*, modifier 없음.
    x10,
    /// `?1000` — 누름 + 뗌. motion 없음.
    normal,
    /// `?1002` — 누름 + 뗌 + *버튼을 누른 채* 이동.
    button,
    /// `?1003` — 모든 포인터 이동까지.
    any,
};

/// 좌표 인코딩 형식. tracking 과 독립적으로 정해진다 (`?1006` 등은 형식만 바꿈).
pub const Format = enum {
    /// 원조 — `CSI M` + `32 + 값` 1 byte 씩. 좌표 223 상한.
    x10,
    /// `?1005` — x10 의 좌표를 UTF-8 로. 모호성이 남아 사실상 폐기.
    utf8,
    /// `?1006` — `CSI < Cb ; Cx ; Cy M|m`. 현대 표준.
    sgr,
    /// `?1015` — 10진수지만 뗌을 구분하지 못한다 (legacy).
    urxvt,
    /// `?1016` — SGR 과 같은 형식이지만 좌표가 cell 이 아니라 **픽셀**.
    sgr_pixels,
};

pub const Action = enum { press, release, motion };

/// 버튼. 값은 프로토콜 코드가 아니라 의미 이름 — 코드 매핑은 `buttonBase`.
pub const Button = enum {
    left,
    middle,
    right,
    wheel_up,
    wheel_down,
    wheel_left,
    wheel_right,
    back,
    forward,
};

pub const Mods = struct {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

/// viewport 기준 **0-based** cell 좌표. 전송 시 +1 (프로토콜은 1-based).
pub const Cell = struct {
    col: u32,
    row: u32,

    pub fn eql(a: Cell, b: Cell) bool {
        return a.col == b.col and a.row == b.row;
    }
};

/// `sgr_pixels` 전용 terminal-space 픽셀 좌표 (좌상단 = 0,0).
pub const Pixel = struct { x: i32 = 0, y: i32 = 0 };

pub const Event = struct {
    action: Action,
    /// null = 버튼 없는 motion. `any` mode 에서만 의미가 있다.
    button: ?Button = null,
    mods: Mods = .{},
    cell: Cell,
    pixel: Pixel = .{},
    /// 포인터가 셀 viewport 안에 있는지. 버튼을 누른 채 창 밖으로 끌고 나간
    /// 드래그를 어디까지 보낼지 정하는 데 쓴다.
    in_viewport: bool = true,
    /// 이 이벤트 시점에 *아무* 버튼이라도 눌려 있는지 (이 이벤트 자신 포함).
    /// viewport 밖 motion 은 이것이 true 일 때만 보고한다 — TUI 가 "안에서 누르고
    /// 밖으로 끌기" 를 감지할 수 있게.
    any_button_pressed: bool = false,
};

/// 한 이벤트가 만들 수 있는 최대 바이트. `sgr_pixels` 에서 좌표가 u32 10자리씩
/// 나올 때가 최악 (`\x1b[<129;4294967295;4294967295m`).
pub const max_len = 40;

/// 이벤트를 `buf` 에 인코딩하고 그 슬라이스를 돌려준다. **보고하지 않을 이벤트면
/// null** (mode 가 안 켜짐 / 그 mode 가 안 보내는 종류 / x10 좌표 초과 / 같은 cell
/// 안의 중복 motion).
///
/// `last_cell` 은 motion 중복 제거 상태 — 호출부가 탭별로 들고 있다가 포인터로
/// 넘긴다. null 이면 중복 제거를 하지 않는다.
pub fn encode(
    buf: []u8,
    ev: Event,
    tracking: Tracking,
    format: Format,
    last_cell: ?*?Cell,
) ?[]const u8 {
    if (!shouldReport(ev, tracking)) return null;

    // viewport 밖 — 뗌은 어디서 놓든 항상 보고한다 (앱이 버튼 상태를 잃으면
    // 영원히 눌린 것으로 남는다). 그 외는 motion 을 보내는 mode 이고 버튼이
    // 눌려 있을 때만.
    if (ev.action != .release and !ev.in_viewport) {
        if (!sendsMotion(tracking)) return null;
        if (!ev.any_button_pressed) return null;
    }

    // 같은 cell 안에서 픽셀만 움직인 motion 은 보내지 않는다. `sgr_pixels` 는
    // 픽셀 자체가 정보라 예외.
    if (ev.action == .motion and format != .sgr_pixels) {
        if (last_cell) |slot| {
            if (slot.*) |prev| {
                if (prev.eql(ev.cell)) return null;
            }
        }
    }
    if (last_cell) |slot| slot.* = ev.cell;

    const code = buttonCode(ev, tracking, format) orelse return null;

    return switch (format) {
        .x10 => blk: {
            // 1 byte 에 `32 + 좌표 + 1` 를 담아야 해서 222 가 상한.
            if (ev.cell.col > 222 or ev.cell.row > 222) break :blk null;
            const out = std.fmt.bufPrint(buf, "\x1b[M{c}{c}{c}", .{
                32 + code,
                @as(u8, @intCast(32 + ev.cell.col + 1)),
                @as(u8, @intCast(32 + ev.cell.row + 1)),
            }) catch break :blk null;
            break :blk out;
        },

        .utf8 => blk: {
            // `\x1b[M` + code 1 byte + 좌표 2개 (각 최대 4 byte).
            if (buf.len < 4 + 8) break :blk null;
            @memcpy(buf[0..3], "\x1b[M");
            buf[3] = 32 + code;
            var n: usize = 4;
            for ([_]u32{ ev.cell.col, ev.cell.row }) |v| {
                const cp = std.math.cast(u21, v + 33) orelse break :blk null;
                n += std.unicode.utf8Encode(cp, buf[n..]) catch break :blk null;
            }
            break :blk buf[0..n];
        },

        .sgr => std.fmt.bufPrint(buf, "\x1b[<{d};{d};{d}{c}", .{
            code,
            ev.cell.col + 1,
            ev.cell.row + 1,
            finalByte(ev.action),
        }) catch null,

        // urxvt 는 뗌도 `M` 으로 끝난다 — 그래서 뗌의 버튼을 구분할 수 없다.
        .urxvt => std.fmt.bufPrint(buf, "\x1b[{d};{d};{d}M", .{
            32 + @as(u16, code),
            ev.cell.col + 1,
            ev.cell.row + 1,
        }) catch null,

        .sgr_pixels => std.fmt.bufPrint(buf, "\x1b[<{d};{d};{d}{c}", .{
            code,
            ev.pixel.x,
            ev.pixel.y,
            finalByte(ev.action),
        }) catch null,
    };
}

/// motion 을 보내는 mode 인지.
pub fn sendsMotion(tracking: Tracking) bool {
    return tracking == .button or tracking == .any;
}

fn finalByte(action: Action) u8 {
    return if (action == .release) 'm' else 'M';
}

/// 이 mode 가 이 종류의 이벤트를 보내는지.
fn shouldReport(ev: Event, tracking: Tracking) bool {
    return switch (tracking) {
        .none => false,
        // 왼 · 가운데 · 오른쪽 누름만. 휠도 안 보낸다.
        .x10 => ev.action == .press and if (ev.button) |b|
            (b == .left or b == .middle or b == .right)
        else
            false,
        .normal => ev.action != .motion,
        // 버튼이 눌린 이벤트만 — 버튼 없는 motion 은 제외.
        .button => ev.button != null,
        .any => true,
    };
}

/// 버튼 + modifier + motion 비트를 합친 `Cb`. 인코딩할 수 없는 버튼이면 null.
fn buttonCode(ev: Event, tracking: Tracking, format: Format) ?u8 {
    const sgr_like = format == .sgr or format == .sgr_pixels;

    var acc: u8 = code: {
        // 버튼 없는 motion.
        if (ev.button == null) break :code 3;
        // legacy 형식은 뗌의 버튼 번호를 못 싣는다 — 항상 3.
        if (ev.action == .release and !sgr_like) break :code 3;
        break :code buttonBase(ev.button.?);
    };

    // x10 은 modifier 를 싣지 않는다.
    if (tracking != .x10) {
        if (ev.mods.shift) acc += 4;
        if (ev.mods.alt) acc += 8;
        if (ev.mods.ctrl) acc += 16;
    }

    if (ev.action == .motion) acc += 32;

    return acc;
}

fn buttonBase(b: Button) u8 {
    return switch (b) {
        .left => 0,
        .middle => 1,
        .right => 2,
        .wheel_up => 64,
        .wheel_down => 65,
        .wheel_left => 66,
        .wheel_right => 67,
        .back => 128,
        .forward => 129,
    };
}

/// Shift bypass 정책 상태. 앱이 XTSHIFTESCAPE (`CSI > Ps s`) 로 요청할 수 있다.
/// ghostty `Terminal.flags.mouse_shift_capture` 의 3-상태와 같은 모델.
pub const ShiftCapture = enum {
    /// 앱이 지정하지 않음 — 우리 기본값은 "터미널이 Shift 를 가져간다".
    unset,
    /// `CSI > 1 s` — 앱이 Shift 조합도 자기가 받겠다고 요청.
    app,
    /// `CSI > 0 s` — 터미널이 Shift 를 가져가도 좋다고 앱이 허용.
    terminal,
};

/// 셀 영역 pointer 이벤트를 어떻게 처리할지. 세 host (Windows `app_controller` ·
/// macOS `host/macos.zig` · Linux `wayland_minimal.zig`) 가 각자 라우팅을 갖고
/// 있어서, *정책* 은 이 함수 하나로 수렴시킨다.
pub const Decision = union(enum) {
    /// 기존 우리 동작 (selection 시작 / 확장 / 종료). reporting 이 꺼져 있거나
    /// Shift bypass 인 경우.
    local,
    /// 이 바이트를 PTY 로 보낸다.
    report: []const u8,
    /// 앱이 마우스를 소유하지만 이 이벤트는 보내지 않는다 (그 mode 가 안 보내는
    /// 종류 · 같은 cell 중복 motion · x10 좌표 초과). **우리 selection 도 시작하지
    /// 않아야 한다** — 앱 화면 위에 우리 selection 이 겹쳐 그려지면 안 된다.
    swallow,
};

/// 셀 영역 이벤트의 처리 방향을 결정한다. `buf` 는 `report` 로 돌려줄 바이트가
/// 담기는 자리 (`max_len` 이상).
pub fn route(
    buf: []u8,
    ev: Event,
    tracking: Tracking,
    format: Format,
    shift_capture: ShiftCapture,
    last_cell: ?*?Cell,
) Decision {
    // 앱이 mode 를 켜지 않았으면 지금까지의 동작 그대로.
    if (tracking == .none) return .local;

    // Shift bypass — 우리 드래그 selection / 복사를 지킨다 (xterm · iTerm2 ·
    // Windows Terminal 공통 관례). 앱이 XTSHIFTESCAPE 로 Shift 를 명시로 요구한
    // 경우에만 앱에게 넘긴다.
    if (ev.mods.shift and shift_capture != .app) return .local;

    if (encode(buf, ev, tracking, format, last_cell)) |bytes| {
        return .{ .report = bytes };
    }
    return .swallow;
}

/// alternate scroll (`?1007`) 의 휠 → 화살표 키 변환. scrollback 이 없는 alt
/// screen (vim · less) 에서 휠이 무동작이 되는 것을 막는 xterm 관례다. 호출부가
/// notch 수만큼 반복해서 보낸다.
///
/// `application_cursor` = DECCKM (`?1`) 이 켜져 있으면 `CSI` 대신 `SS3` 를 쓴다 —
/// 화살표 키 전송과 같은 규칙이라 앱이 구분 없이 받는다.
pub fn alternateScrollKey(up: bool, application_cursor: bool) []const u8 {
    if (application_cursor) return if (up) "\x1bOA" else "\x1bOB";
    return if (up) "\x1b[A" else "\x1b[B";
}

const testing = std.testing;

fn expectEncoded(
    expected: ?[]const u8,
    ev: Event,
    tracking: Tracking,
    format: Format,
) !void {
    var buf: [max_len]u8 = undefined;
    const got = encode(&buf, ev, tracking, format, null);
    if (expected) |want| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(want, got.?);
    } else {
        try testing.expect(got == null);
    }
}

test "SGR: 클릭 누름 · 뗌 — 좌표는 1-based, 뗌은 소문자 m" {
    const cell: Cell = .{ .col = 39, .row = 11 };
    try expectEncoded("\x1b[<0;40;12M", .{ .action = .press, .button = .left, .cell = cell }, .normal, .sgr);
    try expectEncoded("\x1b[<0;40;12m", .{ .action = .release, .button = .left, .cell = cell }, .normal, .sgr);
}

test "SGR: 뗌도 버튼 번호를 유지한다 (legacy 와의 차이)" {
    const ev: Event = .{ .action = .release, .button = .right, .cell = .{ .col = 0, .row = 0 } };
    try expectEncoded("\x1b[<2;1;1m", ev, .normal, .sgr);
    // legacy 는 같은 이벤트가 버튼 3 으로 뭉개진다.
    try expectEncoded("\x1b[M#!!", ev, .normal, .x10);
}

test "SGR: modifier 비트 — shift 4 · alt 8 · ctrl 16" {
    const cell: Cell = .{ .col = 0, .row = 0 };
    try expectEncoded("\x1b[<4;1;1M", .{ .action = .press, .button = .left, .mods = .{ .shift = true }, .cell = cell }, .normal, .sgr);
    try expectEncoded("\x1b[<8;1;1M", .{ .action = .press, .button = .left, .mods = .{ .alt = true }, .cell = cell }, .normal, .sgr);
    try expectEncoded("\x1b[<16;1;1M", .{ .action = .press, .button = .left, .mods = .{ .ctrl = true }, .cell = cell }, .normal, .sgr);
    try expectEncoded("\x1b[<28;1;1M", .{ .action = .press, .button = .left, .mods = .{ .shift = true, .alt = true, .ctrl = true }, .cell = cell }, .normal, .sgr);
}

test "SGR: ctrl 드래그 — motion 은 +32" {
    // 0 (left) + 16 (ctrl) + 32 (motion) = 48
    try expectEncoded("\x1b[<48;41;12M", .{
        .action = .motion,
        .button = .left,
        .mods = .{ .ctrl = true },
        .cell = .{ .col = 40, .row = 11 },
        .any_button_pressed = true,
    }, .button, .sgr);
}

test "휠: 위 64 · 아래 65 · 가로 66/67" {
    const cell: Cell = .{ .col = 0, .row = 0 };
    try expectEncoded("\x1b[<64;1;1M", .{ .action = .press, .button = .wheel_up, .cell = cell }, .normal, .sgr);
    try expectEncoded("\x1b[<65;1;1M", .{ .action = .press, .button = .wheel_down, .cell = cell }, .normal, .sgr);
    try expectEncoded("\x1b[<66;1;1M", .{ .action = .press, .button = .wheel_left, .cell = cell }, .normal, .sgr);
    try expectEncoded("\x1b[<67;1;1M", .{ .action = .press, .button = .wheel_right, .cell = cell }, .normal, .sgr);
}

test "mode 별 보고 범위" {
    const press: Event = .{ .action = .press, .button = .left, .cell = .{ .col = 0, .row = 0 } };
    const release: Event = .{ .action = .release, .button = .left, .cell = .{ .col = 0, .row = 0 } };
    const drag: Event = .{ .action = .motion, .button = .left, .cell = .{ .col = 1, .row = 0 }, .any_button_pressed = true };
    const hover: Event = .{ .action = .motion, .button = null, .cell = .{ .col = 1, .row = 0 } };
    const wheel: Event = .{ .action = .press, .button = .wheel_up, .cell = .{ .col = 0, .row = 0 } };

    // none — 전부 무시.
    try expectEncoded(null, press, .none, .sgr);

    // x10 — 누름만. 뗌 · 드래그 · hover · 휠 전부 안 보냄.
    try expectEncoded("\x1b[M !!", press, .x10, .x10);
    try expectEncoded(null, release, .x10, .x10);
    try expectEncoded(null, drag, .x10, .x10);
    try expectEncoded(null, hover, .x10, .x10);
    try expectEncoded(null, wheel, .x10, .x10);

    // normal — motion 만 제외.
    try expectEncoded("\x1b[<0;1;1M", press, .normal, .sgr);
    try expectEncoded("\x1b[<0;1;1m", release, .normal, .sgr);
    try expectEncoded(null, drag, .normal, .sgr);
    try expectEncoded(null, hover, .normal, .sgr);
    try expectEncoded("\x1b[<64;1;1M", wheel, .normal, .sgr);

    // button — 버튼 있는 것만. 버튼 없는 hover 제외.
    try expectEncoded("\x1b[<32;2;1M", drag, .button, .sgr);
    try expectEncoded(null, hover, .button, .sgr);

    // any — 버튼 없는 hover 도 보냄 (3 + 32 = 35).
    try expectEncoded("\x1b[<35;2;1M", hover, .any, .sgr);
}

test "x10: modifier 를 싣지 않는다" {
    try expectEncoded("\x1b[M !!", .{
        .action = .press,
        .button = .left,
        .mods = .{ .ctrl = true, .shift = true },
        .cell = .{ .col = 0, .row = 0 },
    }, .x10, .x10);
}

test "x10: 좌표 223 상한을 넘으면 전송 포기" {
    // 222 는 인코딩됨 (32 + 222 + 1 = 255).
    var buf: [max_len]u8 = undefined;
    const ok = encode(&buf, .{ .action = .press, .button = .left, .cell = .{ .col = 222, .row = 0 } }, .normal, .x10, null);
    try testing.expect(ok != null);
    try testing.expectEqual(@as(u8, 255), ok.?[4]);

    // 223 은 담을 수 없다.
    try expectEncoded(null, .{ .action = .press, .button = .left, .cell = .{ .col = 223, .row = 0 } }, .normal, .x10);
    try expectEncoded(null, .{ .action = .press, .button = .left, .cell = .{ .col = 0, .row = 223 } }, .normal, .x10);
    // SGR 은 같은 좌표를 문제없이 보낸다 — 1006 이 생긴 이유.
    try expectEncoded("\x1b[<0;224;1M", .{ .action = .press, .button = .left, .cell = .{ .col = 223, .row = 0 } }, .normal, .sgr);
}

test "utf8: 좌표를 UTF-8 code point 로" {
    // col 223 → cp 256 → 2 byte (0xC4 0x80).
    var buf: [max_len]u8 = undefined;
    const got = encode(&buf, .{ .action = .press, .button = .left, .cell = .{ .col = 223, .row = 0 } }, .normal, .utf8, null).?;
    try testing.expectEqualStrings("\x1b[M ", got[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0xC4, 0x80, '!' }, got[4..]);
}

test "urxvt: 뗌도 M 으로 끝나고 코드는 32 가 더해진다" {
    try expectEncoded("\x1b[35;1;1M", .{ .action = .release, .button = .left, .cell = .{ .col = 0, .row = 0 } }, .normal, .urxvt);
}

test "sgr_pixels: 좌표가 픽셀" {
    try expectEncoded("\x1b[<0;327;154M", .{
        .action = .press,
        .button = .left,
        .cell = .{ .col = 39, .row = 11 },
        .pixel = .{ .x = 327, .y = 154 },
    }, .normal, .sgr_pixels);
}

test "motion 중복 제거 — 같은 cell 은 한 번만" {
    var buf: [max_len]u8 = undefined;
    var last: ?Cell = null;
    const ev: Event = .{ .action = .motion, .button = .left, .cell = .{ .col = 5, .row = 2 }, .any_button_pressed = true };

    try testing.expect(encode(&buf, ev, .button, .sgr, &last) != null);
    // 같은 cell → 두 번째는 null.
    try testing.expect(encode(&buf, ev, .button, .sgr, &last) == null);
    // cell 이 바뀌면 다시 보낸다.
    var moved = ev;
    moved.cell = .{ .col = 6, .row = 2 };
    try testing.expect(encode(&buf, moved, .button, .sgr, &last) != null);
    // sgr_pixels 는 중복 제거 예외 — 픽셀이 정보다.
    last = null;
    try testing.expect(encode(&buf, ev, .button, .sgr_pixels, &last) != null);
    try testing.expect(encode(&buf, ev, .button, .sgr_pixels, &last) != null);
}

test "viewport 밖 — 뗌은 항상 보내고 motion 은 버튼이 눌린 경우만" {
    const out_release: Event = .{ .action = .release, .button = .left, .cell = .{ .col = 0, .row = 0 }, .in_viewport = false };
    try expectEncoded("\x1b[<0;1;1m", out_release, .button, .sgr);

    // 버튼 눌린 채 창 밖으로 끌기 → 보냄.
    try expectEncoded("\x1b[<32;1;1M", .{
        .action = .motion,
        .button = .left,
        .cell = .{ .col = 0, .row = 0 },
        .in_viewport = false,
        .any_button_pressed = true,
    }, .button, .sgr);

    // 버튼 없이 창 밖 hover → 안 보냄.
    try expectEncoded(null, .{
        .action = .motion,
        .button = null,
        .cell = .{ .col = 0, .row = 0 },
        .in_viewport = false,
    }, .any, .sgr);

    // motion 을 안 보내는 mode 면 viewport 밖 누름도 안 보냄.
    try expectEncoded(null, .{
        .action = .press,
        .button = .left,
        .cell = .{ .col = 0, .row = 0 },
        .in_viewport = false,
        .any_button_pressed = true,
    }, .normal, .sgr);
}

test "route: mode 가 꺼져 있으면 기존 동작" {
    var buf: [max_len]u8 = undefined;
    const ev: Event = .{ .action = .press, .button = .left, .cell = .{ .col = 0, .row = 0 } };
    try testing.expect(route(&buf, ev, .none, .sgr, .unset, null) == .local);
}

test "route: Shift 드래그는 우리 selection — 앱이 요구한 경우만 넘긴다" {
    var buf: [max_len]u8 = undefined;
    const ev: Event = .{
        .action = .press,
        .button = .left,
        .mods = .{ .shift = true },
        .cell = .{ .col = 0, .row = 0 },
    };
    // 기본값 · 앱이 허용한 경우 → 우리 것.
    try testing.expect(route(&buf, ev, .normal, .sgr, .unset, null) == .local);
    try testing.expect(route(&buf, ev, .normal, .sgr, .terminal, null) == .local);
    // 앱이 Shift 를 요구 → 앱으로 (shift 비트 4 가 실린다).
    const decision = route(&buf, ev, .normal, .sgr, .app, null);
    try testing.expect(decision == .report);
    try testing.expectEqualStrings("\x1b[<4;1;1M", decision.report);
}

test "route: 앱이 소유하지만 안 보내는 이벤트는 swallow — selection 시작 금지" {
    var buf: [max_len]u8 = undefined;
    // normal mode 는 motion 을 안 보낸다. 그래도 우리 selection 을 시작하면 안 된다.
    const drag: Event = .{
        .action = .motion,
        .button = .left,
        .cell = .{ .col = 1, .row = 0 },
        .any_button_pressed = true,
    };
    try testing.expect(route(&buf, drag, .normal, .sgr, .unset, null) == .swallow);

    // 같은 cell 중복 motion 도 swallow.
    var last: ?Cell = null;
    try testing.expect(route(&buf, drag, .button, .sgr, .unset, &last) == .report);
    try testing.expect(route(&buf, drag, .button, .sgr, .unset, &last) == .swallow);
}

test "route: 평소 클릭은 앱으로" {
    var buf: [max_len]u8 = undefined;
    const ev: Event = .{ .action = .press, .button = .left, .cell = .{ .col = 39, .row = 11 } };
    const decision = route(&buf, ev, .button, .sgr, .unset, null);
    try testing.expect(decision == .report);
    try testing.expectEqualStrings("\x1b[<0;40;12M", decision.report);
}

test "alternate scroll: DECCKM 에 따라 CSI / SS3" {
    try testing.expectEqualStrings("\x1b[A", alternateScrollKey(true, false));
    try testing.expectEqualStrings("\x1b[B", alternateScrollKey(false, false));
    try testing.expectEqualStrings("\x1bOA", alternateScrollKey(true, true));
    try testing.expectEqualStrings("\x1bOB", alternateScrollKey(false, true));
}
