//! Linux custom dialog의 content-driven layout 계산 (#306).
//!
//! renderer/Wayland 객체와 분리된 순수 계산만 둔다. 호출자는 output의 physical
//! viewport와 현재 scale에서 만든 physical pixel metrics를 전달한다.

const std = @import("std");
const display_width = @import("../../font/display_width.zig");
const font_validate = @import("../../font/validate.zig");
const messages = @import("../../messages.zig");
const ui_metrics = @import("../../ui_metrics.zig");

pub const Kind = enum { info, about, confirm, prompt };

/// 글자 폭 측정 (#407). 이 모듈은 renderer 객체를 못 부르므로 (파일 머리말) 폭을
/// 재는 수단만 함수 포인터로 받는다. 실기는 `font.Context` 의 glyph advance 를,
/// 테스트는 고정폭 측정기를 넘긴다 — **비례폭 dialog 와 고정폭 터미널이 같은
/// 레이아웃 코드를 쓰되 측정만 갈리게** 하는 자리다.
pub const Measure = struct {
    ctx: *const anyopaque,
    advanceFn: *const fn (ctx: *const anyopaque, cp: u21) i32,

    pub fn advance(self: Measure, cp: u21) i32 {
        return self.advanceFn(self.ctx, cp);
    }

    /// UTF-8 문자열의 픽셀 폭. 개행은 폭 0 으로 친다 (호출자가 줄 단위로 자른다).
    pub fn width(self: Measure, text: []const u8) i32 {
        var total: i32 = 0;
        var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (iter.nextCodepoint()) |cp| {
            if (cp == '\n') continue;
            total += self.advance(@intCast(cp));
        }
        return total;
    }

    /// 최소 폭을 "글자 몇 개" 로 적기 위한 기준 advance. 비례폭에서 대표 폭으로
    /// 숫자 `0` 을 쓴다 (대부분의 폰트가 숫자를 고정폭으로 둔다).
    pub fn refAdvance(self: Measure) i32 {
        return @max(1, self.advance('0'));
    }
};

pub const Metrics = struct {
    body_cell_h: i32,
    title_cell_h: i32,
    padding: i32,
    shadow_margin: i32,
    viewport_margin: i32,
    icon_size: i32,
    icon_gap: i32,
    button_w: i32,
    button_h: i32,
    button_gap: i32,
    preferred_w: i32,
    max_w: i32,
    scrollbar_w: i32,
    scrollbar_gap: i32,
};

pub const Size = struct { w: i32, h: i32 };

pub const Layout = struct {
    size: Size,
    /// 본문을 접는 폭 (**픽셀**). 렌더러가 같은 값으로 `WrappedLines` 를 다시 돌려야
    /// 측정과 그림이 일치한다.
    wrap_width: i32,
    message_rows: usize,
    visible_message_rows: usize,
    message_scroll_max: usize,
    show_icon: bool,
    fits: bool,
};

/// 본문을 `max_width` (**픽셀**) 안에서 접는 iterator. 레이아웃 계산과 렌더링이
/// **같은 iterator 를 같은 폭으로** 돌려야 측정 행 수와 그린 행 수가 정확히 같다.
pub const WrappedLines = struct {
    msg: []const u8,
    max_width: i32,
    measure: Measure,
    pos: usize = 0,

    pub fn next(self: *WrappedLines) ?[]const u8 {
        if (self.pos >= self.msg.len) return null;
        const start = self.pos;
        var i = self.pos;
        var width: i32 = 0;
        var last_space: ?usize = null;
        var last_space_end: usize = start;
        const max_width = @max(self.max_width, 1);
        while (i < self.msg.len) {
            const b = self.msg[i];
            if (b == '\n') {
                self.pos = i + 1;
                return self.msg[start..i];
            }
            const seq = std.unicode.utf8ByteSequenceLength(b) catch 1;
            const end = @min(i + seq, self.msg.len);
            const cp = std.unicode.utf8Decode(self.msg[i..end]) catch 0xFFFD;
            const w: i32 = self.measure.advance(cp);
            if (cp == ' ') {
                last_space = i;
                last_space_end = end;
            }
            if (width + w > max_width and i > start) {
                if (last_space) |sp| {
                    self.pos = last_space_end;
                    return self.msg[start..sp];
                }
                self.pos = i;
                return self.msg[start..i];
            }
            width += w;
            i = end;
        }
        self.pos = i;
        return self.msg[start..i];
    }
};

const Measurement = struct {
    rows: usize,
    max_width: i32,
};

fn longestExplicitLineWidth(message: []const u8, m: Measure) i32 {
    var longest: i32 = 0;
    var current: i32 = 0;
    var iter = std.unicode.Utf8Iterator{ .bytes = message, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        if (cp == '\n') {
            longest = @max(longest, current);
            current = 0;
        } else {
            current += m.advance(@intCast(cp));
        }
    }
    return @max(longest, current);
}

fn measureMessage(message: []const u8, wrap_width: i32, m: Measure) Measurement {
    var result = Measurement{ .rows = 0, .max_width = 0 };
    var lines = WrappedLines{ .msg = message, .max_width = wrap_width, .measure = m };
    while (lines.next()) |line| {
        result.rows += 1;
        result.max_width = @max(result.max_width, m.width(line));
    }
    if (result.rows == 0) result.rows = 1;
    return result;
}

pub fn compute(
    title: []const u8,
    message: []const u8,
    kind: Kind,
    metrics: Metrics,
    body_measure: Measure,
    title_measure: Measure,
    viewport: Size,
) Layout {
    return computeWithinSurface(title, message, kind, metrics, body_measure, title_measure, .{
        .w = @max(1, viewport.w - metrics.viewport_margin * 2),
        .h = @max(1, viewport.h - metrics.viewport_margin * 2),
    });
}

/// compositor가 요청과 다른 최종 surface 크기를 configure한 경우의 재계산.
/// `surface` 자체가 이미 output 바깥 여백을 제외한 값이므로 viewport margin을
/// 다시 빼지 않는다.
pub fn computeForSurface(
    title: []const u8,
    message: []const u8,
    kind: Kind,
    metrics: Metrics,
    body_measure: Measure,
    title_measure: Measure,
    surface: Size,
) Layout {
    return computeWithinSurface(title, message, kind, metrics, body_measure, title_measure, .{
        .w = @max(1, surface.w),
        .h = @max(1, surface.h),
    });
}

fn computeWithinSurface(
    title: []const u8,
    message: []const u8,
    kind: Kind,
    metrics: Metrics,
    body_measure: Measure,
    title_measure: Measure,
    available_surface: Size,
) Layout {
    std.debug.assert(metrics.body_cell_h > 0);
    std.debug.assert(metrics.title_cell_h > 0);
    std.debug.assert(metrics.preferred_w > 0);
    std.debug.assert(metrics.max_w >= metrics.preferred_w);

    const max_surface = Size{
        .w = @min(available_surface.w, metrics.max_w),
        .h = available_surface.h,
    };
    const preferred_surface_w = @min(max_surface.w, metrics.preferred_w);
    // 기준 advance — 최소 폭을 "글자 몇 개" 로 적기 위한 환산 단위다. 고정폭이던
    // 시절의 `body_cell_w` 자리를 대신한다 (#407).
    const ref_adv = body_measure.refAdvance();
    const preferred_content_room_w = @max(
        ref_adv,
        preferred_surface_w - metrics.shadow_margin * 2 - metrics.padding * 2,
    );
    const max_content_room_w = @max(
        ref_adv,
        max_surface.w - metrics.shadow_margin * 2 - metrics.padding * 2,
    );
    const min_width: i32 = ref_adv * @as(i32, if (kind == .prompt) 42 else 30);
    const natural_width = longestExplicitLineWidth(message, body_measure);
    var wrap_width = @min(@max(natural_width, min_width), preferred_content_room_w);
    var measured = measureMessage(message, wrap_width, body_measure);

    const prompt_h: i32 = if (kind == .prompt) metrics.body_cell_h * 3 else 0;
    const fixed_h = metrics.padding * 2 +
        metrics.title_cell_h +
        metrics.body_cell_h + // separator row
        metrics.body_cell_h + // message-to-button gap
        prompt_h +
        metrics.button_h +
        metrics.shadow_margin * 2;
    const icon_h = metrics.icon_size + metrics.icon_gap;
    var rows_h: i32 = @intCast(measured.rows * @as(usize, @intCast(metrics.body_cell_h)));
    const show_icon = true;
    var message_scroll_max: usize = 0;
    var expanded_to_max = false;

    // preferred 폭에서 자연 높이를 먼저 측정하고, 고정 chrome까지 합쳐 화면을
    // 넘을 때만 maximum 폭으로 다시 wrap한다.
    if (fixed_h + rows_h + icon_h > max_surface.h and preferred_content_room_w < max_content_room_w) {
        expanded_to_max = true;
        wrap_width = @min(@max(natural_width, min_width), max_content_room_w);
        measured = measureMessage(message, wrap_width, body_measure);
        rows_h = @intCast(measured.rows * @as(usize, @intCast(metrics.body_cell_h)));
    }

    var visible_message_rows = measured.rows;

    // 모든 dialog는 먼저 본문 자연 높이를 사용하고, 화면을 넘을 때만 message
    // viewport를 만든다. scrollbar 공간을 먼저 제외하고 다시 wrap해야 측정 행
    // 수와 실제 그리기 행 수가 정확히 같다. prompt input과 button은 fixed_h에
    // 포함되어 항상 viewport 밖에 고정된다.
    if (fixed_h + rows_h + icon_h > max_surface.h) {
        const scrollbar_room = metrics.scrollbar_w + metrics.scrollbar_gap;
        const scroll_content_room_w = @max(
            ref_adv,
            max_content_room_w - scrollbar_room,
        );
        wrap_width = @min(@max(natural_width, min_width), scroll_content_room_w);
        measured = measureMessage(message, wrap_width, body_measure);
        rows_h = @intCast(measured.rows * @as(usize, @intCast(metrics.body_cell_h)));
        const row_room = max_surface.h - fixed_h - icon_h;
        visible_message_rows = @min(
            measured.rows,
            @as(usize, @intCast(@max(1, @divTrunc(row_room, metrics.body_cell_h)))),
        );
        message_scroll_max = measured.rows - visible_message_rows;
    }

    const scroll_extra = if (message_scroll_max > 0) metrics.scrollbar_w + metrics.scrollbar_gap else 0;
    const body_w = measured.max_width + scroll_extra;
    const title_w: i32 = title_measure.width(title);
    const inner_w = @max(body_w, title_w);
    const buttons_w = switch (kind) {
        .info, .about => metrics.button_w,
        .confirm, .prompt => metrics.button_w * 2 + metrics.button_gap,
    };
    const box_w = @max(
        @max(inner_w + metrics.padding * 2, buttons_w + metrics.padding * 4),
        metrics.icon_size + metrics.padding * 2,
    );
    const desired_w = box_w + metrics.shadow_margin * 2;

    const visible_rows_h: i32 = @intCast(visible_message_rows * @as(usize, @intCast(metrics.body_cell_h)));
    const desired_h = fixed_h + visible_rows_h + (if (show_icon) icon_h else 0);
    const width_limit = if (expanded_to_max) max_surface.w else preferred_surface_w;

    return .{
        .size = .{
            .w = @min(desired_w, width_limit),
            .h = @min(desired_h, max_surface.h),
        },
        .wrap_width = wrap_width,
        .message_rows = measured.rows,
        .visible_message_rows = visible_message_rows,
        .message_scroll_max = message_scroll_max,
        .show_icon = show_icon,
        .fits = desired_w <= width_limit and desired_h <= max_surface.h,
    };
}

test "current config error fits 640x480 logical viewport" {
    const message =
        \\Configuration: shell executable not found.
        \\
        \\"shell" value: "/definitely/missing/tildaz-306-shell"
        \\Lookup token: "/definitely/missing/tildaz-306-shell"
        \\
        \\Expects an absolute path to an executable. Examples:
        \\  "/bin/bash"
        \\  "/bin/zsh"
        \\  "/usr/bin/fish"
        \\
        \\Config path:
        \\/tmp/tildaz-306-current-home/.config/tildaz/config_98.json
    ;
    const f = testFonts(100);
    const layout = compute("TildaZ Config Error", message, .info, testMetrics(100), f.body(), f.title(), .{ .w = 640, .h = 480 });
    if (!layout.fits) {
        std.debug.print(
            "current config layout: fits={} size={}x{} rows={} wrap_px={} longest_px={}\n",
            .{ layout.fits, layout.size.w, layout.size.h, layout.message_rows, layout.wrap_width, longestExplicitLineWidth(message, f.body()) },
        );
    }
    try std.testing.expect(layout.fits);
    try std.testing.expect(layout.size.w <= 640 - 32);
    try std.testing.expect(layout.size.h <= 480 - 32);
}

test "same logical viewport fits at 1x 1.7x and 2x" {
    const message = "A moderately long dialog line that should keep the same logical layout at every output scale.";
    const scales = [_]u32{ 100, 170, 200 };
    for (scales) |scale_percent| {
        const f = testFonts(scale_percent);
        const layout = compute(
            "TildaZ",
            message,
            .info,
            testMetrics(scale_percent),
            f.body(),
            f.title(),
            .{
                .w = @divTrunc(640 * @as(i32, @intCast(scale_percent)), 100),
                .h = @divTrunc(480 * @as(i32, @intCast(scale_percent)), 100),
            },
        );
        try std.testing.expect(layout.fits);
    }
}

test "wide viewport is not limited to 72 cells" {
    const message = "x" ** 100;
    // preferred 폭에서는 2행이라 화면을 넘고, maximum 폭의 100열 1행은
    // 들어오는 높이다. 과거 72-cell 상한이 되살아나면 이 경계가 실패한다.
    const f = testFonts(100);
    // 높이는 #407 로 넓어진 여백만큼 키웠다 (264 → 285). **경계가 좁다** — 낮으면
    // 스크롤 경로로 빠져 scrollbar 폭만큼 wrap 이 좁아지고, 높으면 preferred 폭
    // (2 행) 에서 이미 들어와 maximum 으로 확장하지 않는다. 둘 다 이 테스트의 의도
    // (폭 상한이 없다) 와 무관한 이유로 실패한다. 현재 여백에서 유효 범위는
    // 279~295 다.
    const layout = compute("TildaZ", message, .info, testMetrics(100), f.body(), f.title(), .{ .w = 1280, .h = 285 });
    try std.testing.expect(layout.fits);
    // 고정폭 측정기라 100 열 = 100 × 9 px 이다.
    try std.testing.expectEqual(@as(i32, 100 * 9), layout.wrap_width);
    try std.testing.expectEqual(@as(usize, 1), layout.message_rows);
}

test "compact layout keeps branded icon and scrolls only the message" {
    const message = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve";
    const f = testFonts(100);
    const layout = compute("TildaZ", message, .confirm, testMetrics(100), f.body(), f.title(), .{ .w = 640, .h = 400 });
    try std.testing.expect(layout.fits);
    try std.testing.expect(layout.show_icon);
    try std.testing.expectEqual(@as(usize, 12), layout.message_rows);
    // #407 로 여백이 넓어져 보이는 행이 9 → 8 이 됐다 (넘치는 행은 3 → 4).
    try std.testing.expectEqual(@as(usize, 8), layout.visible_message_rows);
    try std.testing.expectEqual(@as(usize, 4), layout.message_scroll_max);
}

test "final compositor surface size recomputes wrapping without viewport margin" {
    const message = "A compositor may configure a narrower final surface than the client initially requested for this dialog message.";
    const f = testFonts(100);
    const initial = compute("TildaZ", message, .info, testMetrics(100), f.body(), f.title(), .{ .w = 1280, .h = 720 });
    const configured = computeForSurface("TildaZ", message, .info, testMetrics(100), f.body(), f.title(), .{ .w = 480, .h = 448 });
    try std.testing.expect(configured.fits);
    try std.testing.expect(configured.wrap_width < initial.wrap_width);
    try std.testing.expect(configured.message_rows > initial.message_rows);
    try std.testing.expect(configured.size.w <= 480);
    try std.testing.expect(configured.size.h <= 448);
}

test "current Linux dialog messages fit the 640x480 logical minimum" {
    const themes = @import("../../themes.zig");

    // #483 — 가장 긴 종료 확인은 pane 을 함께 적는 쪽이고, 최악은 상한끼리 (`MAX_TABS` 32 × `MAX_PANES_PER_TAB` 16).
    var quit_buf: [128]u8 = undefined;
    const quit_msg = try std.fmt.bufPrint(&quit_buf, messages.quit_confirm_panes_format, .{ 32, "s", 32 * 16 });

    var tab_limit_buf: [128]u8 = undefined;
    const tab_limit_msg = try std.fmt.bufPrint(&tab_limit_buf, messages.tab_limit_format, .{32});

    var about_buf: [2048]u8 = undefined;
    const about_msg = try std.fmt.bufPrint(&about_buf, messages.about_format, .{
        "0.6.1",
        "/home/example/.local/bin/tildaz",
        123456,
        "/home/example/.config/tildaz/config_0.toml",
        "/home/example/.local/state/tildaz/tildaz0.log",
        "Ctrl+Shift+P",
        "Ctrl+Shift+L",
    });

    // #495 — 경로는 이 본문에 없다. `showConfigFatalMsg` 가 모든 config 오류 앞에
    // 한 번 붙이므로, 레이아웃 검사도 그 조립 결과를 흉내내야 실제와 같은 높이가 된다.
    var parse_buf: [512]u8 = undefined;
    const parse_body = try std.fmt.bufPrint(&parse_buf, messages.config_parse_failed_format, .{"SyntaxError"});
    var parse_full_buf: [640]u8 = undefined;
    const parse_msg = try std.fmt.bufPrint(&parse_full_buf, messages.config_error_with_path_format, .{
        "/home/example/.config/tildaz/config_0.toml",
        parse_body,
    });

    var hotkey_invalid_buf: [384]u8 = undefined;
    const hotkey_invalid_msg = try std.fmt.bufPrint(
        &hotkey_invalid_buf,
        messages.config_hotkey_invalid_format,
        .{"shift+t"},
    );

    var theme_buf: [512]u8 = undefined;
    var theme_stream: std.Io.Writer = .fixed(&theme_buf);
    const theme_writer = &theme_stream;
    try theme_writer.print(messages.config_unknown_theme_header_format, .{"Not A Theme"});
    for (themes.themes, 0..) |theme, i| {
        if (i > 0) try theme_writer.writeAll(", ");
        try theme_writer.writeAll(theme.name);
    }
    const theme_msg = theme_stream.buffered();

    var shell_buf: [1024]u8 = undefined;
    const shell_msg = try std.fmt.bufPrint(&shell_buf, messages.shell_executable_not_found_format, .{
        "/opt/example/TildaZ Shell/bin/example-shell",
        "/opt/example/TildaZ Shell/bin/example-shell",
        messages.shell_examples_posix,
        "/home/example/.config/tildaz/config_98.json",
    });

    var new_tab_buf: [1024]u8 = undefined;
    const new_tab_msg = try std.fmt.bufPrint(&new_tab_buf, messages.shell_new_tab_not_found_format, .{
        "/opt/example/TildaZ Shell/bin/example-shell",
        "/home/example/.config/tildaz/config_98.json",
    });

    var font_buf: [2048]u8 = undefined;
    const font_families = [_][]const u8{
        "Missing Example Font",
        "Noto Sans Mono CJK KR",
        "Noto Color Emoji",
        "Symbols Nerd Font Mono",
        "DejaVu Sans Mono",
        "Liberation Mono",
        "Unifont",
        "FreeMono",
    };
    const font_msg = font_validate.notFoundMessageForPath(
        &font_buf,
        font_families[0],
        &font_families,
        "/home/example/.config/tildaz/config_98.json",
        null,
    );

    var takeover_buf: [512]u8 = undefined;
    const takeover_msg = try std.fmt.bufPrint(&takeover_buf, messages.hotkey_takeover_format, .{
        "Ctrl+Shift+Space",
        "KWin",
        "Show Desktop Grid",
    });

    var prompt_buf: [256]u8 = undefined;
    const prompt_msg = try std.fmt.bufPrint(&prompt_buf, messages.new_instance_hotkey_prompt_format, .{32});

    var create_error_buf: [512]u8 = undefined;
    const create_error_msg = try std.fmt.bufPrint(
        &create_error_buf,
        messages.new_instance_create_failed_format,
        .{"RequestEndpointReadyTimeout"},
    );

    const Case = struct {
        title: []const u8,
        message: []const u8,
        kind: Kind,
        standard_scroll_by_scale: [3]usize = .{ 0, 0, 0 },
    };
    const cases = [_]Case{
        .{ .title = messages.quit_confirm_title, .message = quit_msg, .kind = .confirm },
        .{ .title = messages.tab_limit_title, .message = tab_limit_msg, .kind = .info },
        .{ .title = messages.about_title, .message = about_msg, .kind = .about },
        .{ .title = messages.config_error_title, .message = parse_msg, .kind = .info },
        .{ .title = messages.config_error_title, .message = hotkey_invalid_msg, .kind = .info },
        .{ .title = messages.config_error_title, .message = theme_msg, .kind = .info },
        // 여백을 폰트 비례로 넓히면서 (#407) 1.7x 에서만 행이 넘친다 — 고정 chrome
        // 반올림이 그 배율에서 한 행을 더 먹는다 (font 오류 주석과 같은 이유).
        //
        // #577 — 2 → 1. 경로를 맨 끝 `Config path:` 에서 첫 줄 `Config: ` 로 옮기면서
        // 문구가 한 줄 짧아졌다 (예전 footer 는 빈 줄 + 라벨 줄 + 경로 줄 셋이었다).
        .{ .title = messages.config_error_title, .message = shell_msg, .kind = .info, .standard_scroll_by_scale = .{ 0, 1, 0 } },
        .{ .title = messages.shell_new_tab_error_title, .message = new_tab_msg, .kind = .info },
        // 64pt branded icon을 고정하면 최대 8-entry font 오류는 640x480에서
        // 본문만 overflow한다. 여백을 폰트 비례로 넓히며 (#407) 3/4/3 → 5/5/5 가 됐다.
        //
        // #577 — 5/5/5 → 4/4/4. 위 shell 과 같은 이유다 — 경로가 맨 끝 3 줄 footer 에서
        // 첫 줄 2 줄 접두로 옮겨져 문구가 한 줄 짧아졌다. 세 배율이 함께 줄었다.
        .{ .title = messages.config_error_title, .message = font_msg, .kind = .info, .standard_scroll_by_scale = .{ 4, 4, 4 } },
        .{ .title = messages.hotkey_takeover_title, .message = takeover_msg, .kind = .confirm },
        .{ .title = messages.new_instance_title, .message = prompt_msg, .kind = .prompt },
        .{ .title = messages.new_instance_title, .message = create_error_msg, .kind = .info },
        .{ .title = messages.error_title, .message = messages.request_endpoint_unavailable_msg, .kind = .info },
        .{ .title = messages.error_title, .message = messages.worker_exited_before_endpoint_ready_msg, .kind = .info },
        .{ .title = messages.error_title, .message = messages.request_endpoint_ready_timeout_msg, .kind = .info },
    };

    for (cases) |case| try expectFitsLogicalMinimum(case.title, case.message, case.kind, case.standard_scroll_by_scale);
}

fn expectFitsLogicalMinimum(
    title: []const u8,
    message: []const u8,
    kind: Kind,
    standard_scroll_by_scale: [3]usize,
) !void {
    const scales = [_]u32{ 100, 170, 200 };
    for (scales, 0..) |scale_percent, scale_index| {
        const metric_cases = [_]Metrics{
            testMetrics(scale_percent),
            testWideCellMetrics(scale_percent),
        };
        const font_cases = [_]TestFonts{
            testFonts(scale_percent),
            testFontsWithCellWidths(scale_percent, 15, 18),
        };
        for (metric_cases, font_cases, 0..) |metrics, fonts, metric_index| {
            const layout = compute(
                title,
                message,
                kind,
                metrics,
                fonts.body(),
                fonts.title(),
                .{
                    .w = @divTrunc(640 * @as(i32, @intCast(scale_percent)), 100),
                    .h = @divTrunc(480 * @as(i32, @intCast(scale_percent)), 100),
                },
            );
            if (!layout.fits) {
                std.debug.print(
                    "dialog does not fit: title={s} scale={d}% body_cw={} size={}x{} rows={} wrap_px={} message_len={} preview={s}\n",
                    .{ title, scale_percent, fonts.body_cw, layout.size.w, layout.size.h, layout.message_rows, layout.wrap_width, message.len, message[0..@min(message.len, 80)] },
                );
            }
            try std.testing.expect(layout.fits);
            try std.testing.expect(layout.show_icon);
            // 표준 dialog font는 producer별 정확한 overflow 경계를 확인한다.
            // 보수적인 wide-cell 조건은 더 많은 wrap 행이 생길 수 있다.
            if (metric_index == 0) try std.testing.expectEqual(standard_scroll_by_scale[scale_index], layout.message_scroll_max);
        }
    }
}

/// 테스트용 **고정폭** 측정기. 실기의 비례폭과 달리 `cell_w × display_width` 라
/// 고정폭 시절과 같은 값이 나온다 — 그래서 아래 기대값들이 그대로 유효하다 (#407).
fn fixedAdvance(ctx: *const anyopaque, cp: u21) i32 {
    const cell_w: *const i32 = @ptrCast(@alignCast(ctx));
    return cell_w.* * @as(i32, @intCast(display_width.codepointWidth(cp)));
}

const TestFonts = struct {
    body_cw: i32,
    title_cw: i32,

    fn body(self: *const TestFonts) Measure {
        return .{ .ctx = &self.body_cw, .advanceFn = fixedAdvance };
    }
    fn title(self: *const TestFonts) Measure {
        return .{ .ctx = &self.title_cw, .advanceFn = fixedAdvance };
    }
};

fn testScaleValue(v: i32, percent: u32) i32 {
    return @divTrunc(v * @as(i32, @intCast(percent)) + 99, 100);
}

fn testFonts(scale_percent: u32) TestFonts {
    return testFontsWithCellWidths(scale_percent, 9, 11);
}

fn testFontsWithCellWidths(scale_percent: u32, body_cw: i32, title_cw: i32) TestFonts {
    return .{
        .body_cw = testScaleValue(body_cw, scale_percent),
        .title_cw = testScaleValue(title_cw, scale_percent),
    };
}

fn testMetrics(scale_percent: u32) Metrics {
    return testMetricsWithCellWidths(scale_percent, 9, 11);
}

fn testWideCellMetrics(scale_percent: u32) Metrics {
    return testMetricsWithCellWidths(scale_percent, 15, 18);
}

fn testMetricsWithCellWidths(scale_percent: u32, body_cell_w: i32, title_cell_w: i32) Metrics {
    _ = body_cell_w;
    _ = title_cell_w;
    const scale = struct {
        fn value(v: i32, percent: u32) i32 {
            return @divTrunc(v * @as(i32, @intCast(percent)) + 99, 100);
        }
    }.value;
    return .{
        .body_cell_h = scale(17, scale_percent),
        .title_cell_h = scale(20, scale_percent),
        .padding = scale(@intCast(ui_metrics.DIALOG_BODY_FONT_PT * 6 / 5), scale_percent),
        .shadow_margin = scale(12, scale_percent),
        .viewport_margin = scale(16, scale_percent),
        .icon_size = scale(@intCast(ui_metrics.DIALOG_ICON_SIZE_PT), scale_percent),
        .icon_gap = scale(@intCast(ui_metrics.DIALOG_ICON_GAP_PT), scale_percent),
        .button_w = scale(100, scale_percent),
        .button_h = scale(44, scale_percent),
        .button_gap = scale(@intCast(ui_metrics.DIALOG_BODY_FONT_PT * 8 / 5), scale_percent),
        .preferred_w = scale(@intCast(ui_metrics.DIALOG_PREFERRED_WIDTH_PT), scale_percent),
        .max_w = scale(@intCast(ui_metrics.DIALOG_MAX_WIDTH_PT), scale_percent),
        .scrollbar_w = scale(10, scale_percent),
        .scrollbar_gap = scale(8, scale_percent),
    };
}

test "dialogs use overflow rows only when content exceeds viewport" {
    const ordinary = "TildaZ v0.6.1\n\nexe: /home/example/tildaz\nconfig: /home/example/config.json";
    const f = testFonts(100);
    const ordinary_layout = compute("About TildaZ", ordinary, .about, testMetrics(100), f.body(), f.title(), .{ .w = 640, .h = 480 });
    try std.testing.expect(ordinary_layout.fits);
    try std.testing.expectEqual(@as(usize, 0), ordinary_layout.message_scroll_max);
    try std.testing.expectEqual(ordinary_layout.message_rows, ordinary_layout.visible_message_rows);

    const long_message = ("/home/" ++ ("x" ** 500) ++ "\n") ** 4;
    const overflow = compute("About TildaZ", long_message, .about, testMetrics(100), f.body(), f.title(), .{ .w = 640, .h = 480 });
    try std.testing.expect(overflow.fits);
    try std.testing.expect(overflow.show_icon);
    try std.testing.expect(overflow.message_scroll_max > 0);
    try std.testing.expect(overflow.visible_message_rows < overflow.message_rows);
    try std.testing.expect(overflow.size.w <= 640 - 32);
    try std.testing.expect(overflow.size.h <= 480 - 32);

    const info_overflow = compute("TildaZ Error", long_message, .info, testMetrics(100), f.body(), f.title(), .{ .w = 640, .h = 480 });
    try std.testing.expect(info_overflow.fits);
    try std.testing.expect(info_overflow.show_icon);
    try std.testing.expect(info_overflow.message_scroll_max > 0);

    const prompt_overflow = compute("TildaZ", long_message, .prompt, testMetrics(100), f.body(), f.title(), .{ .w = 640, .h = 480 });
    try std.testing.expect(prompt_overflow.fits);
    try std.testing.expect(prompt_overflow.show_icon);
    try std.testing.expect(prompt_overflow.message_scroll_max > 0);
}

test "dialogs use common preferred then maximum width in logical points" {
    const f = testFonts(100);
    const compact = compute(
        "Quit TildaZ?",
        "1 terminal tab is still running. Quit TildaZ?",
        .confirm,
        testMetrics(100),
        f.body(),
        f.title(),
        .{ .w = 1400, .h = 900 },
    );
    try std.testing.expect(compact.size.w <= @as(i32, @intCast(ui_metrics.DIALOG_PREFERRED_WIDTH_PT)));

    const message = "x" ** 2000;
    const scales = [_]u32{ 100, 170, 200 };
    for (scales) |scale_percent| {
        const sf = testFonts(scale_percent);
        const layout = compute(
            "About TildaZ",
            message,
            .about,
            testMetrics(scale_percent),
            sf.body(),
            sf.title(),
            .{
                .w = @divTrunc(2200 * @as(i32, @intCast(scale_percent)), 100),
                // preferred 580pt에서는 넘지만 maximum 960pt에서는 자연
                // 높이로 들어오는 경계를 모든 scale에서 동일하게 만든다.
                .h = @divTrunc(650 * @as(i32, @intCast(scale_percent)), 100),
            },
        );
        const preferred = @divTrunc(@as(i32, @intCast(ui_metrics.DIALOG_PREFERRED_WIDTH_PT)) * @as(i32, @intCast(scale_percent)) + 99, 100);
        const maximum = @divTrunc(@as(i32, @intCast(ui_metrics.DIALOG_MAX_WIDTH_PT)) * @as(i32, @intCast(scale_percent)) + 99, 100);
        try std.testing.expect(layout.size.w > preferred);
        try std.testing.expect(layout.size.w <= maximum);
    }
}
