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

pub const Metrics = struct {
    body_cell_w: i32,
    body_cell_h: i32,
    title_cell_w: i32,
    title_cell_h: i32,
    padding: i32,
    shadow_margin: i32,
    viewport_margin: i32,
    icon_size: i32,
    icon_gap: i32,
    button_w: i32,
    button_h: i32,
    button_gap: i32,
    about_max_w: i32,
    scrollbar_w: i32,
    scrollbar_gap: i32,
};

pub const Size = struct { w: i32, h: i32 };

pub const Layout = struct {
    size: Size,
    wrap_cells: usize,
    message_rows: usize,
    visible_message_rows: usize,
    message_scroll_max: usize,
    show_icon: bool,
    fits: bool,
};

pub const WrappedLines = struct {
    msg: []const u8,
    max_cells: usize,
    pos: usize = 0,

    pub fn next(self: *WrappedLines) ?[]const u8 {
        if (self.pos >= self.msg.len) return null;
        const start = self.pos;
        var i = self.pos;
        var width: usize = 0;
        var last_space: ?usize = null;
        var last_space_end: usize = start;
        const max_cells = @max(self.max_cells, 1);
        while (i < self.msg.len) {
            const b = self.msg[i];
            if (b == '\n') {
                self.pos = i + 1;
                return self.msg[start..i];
            }
            const seq = std.unicode.utf8ByteSequenceLength(b) catch 1;
            const end = @min(i + seq, self.msg.len);
            const cp = std.unicode.utf8Decode(self.msg[i..end]) catch 0xFFFD;
            const w: usize = display_width.codepointWidth(cp);
            if (cp == ' ') {
                last_space = i;
                last_space_end = end;
            }
            if (width + w > max_cells and i > start) {
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
    max_cells: usize,
};

fn longestExplicitLine(message: []const u8) usize {
    var longest: usize = 0;
    var current: usize = 0;
    var iter = std.unicode.Utf8Iterator{ .bytes = message, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        if (cp == '\n') {
            longest = @max(longest, current);
            current = 0;
        } else {
            current += display_width.codepointWidth(@intCast(cp));
        }
    }
    return @max(longest, current);
}

fn measure(message: []const u8, wrap_cells: usize) Measurement {
    var result = Measurement{ .rows = 0, .max_cells = 0 };
    var lines = WrappedLines{ .msg = message, .max_cells = wrap_cells };
    while (lines.next()) |line| {
        result.rows += 1;
        result.max_cells = @max(result.max_cells, display_width.stringWidth(line));
    }
    if (result.rows == 0) result.rows = 1;
    return result;
}

pub fn compute(
    title: []const u8,
    message: []const u8,
    kind: Kind,
    metrics: Metrics,
    viewport: Size,
) Layout {
    return computeWithinSurface(title, message, kind, metrics, .{
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
    surface: Size,
) Layout {
    return computeWithinSurface(title, message, kind, metrics, .{
        .w = @max(1, surface.w),
        .h = @max(1, surface.h),
    });
}

fn computeWithinSurface(
    title: []const u8,
    message: []const u8,
    kind: Kind,
    metrics: Metrics,
    available_surface: Size,
) Layout {
    std.debug.assert(metrics.body_cell_w > 0);
    std.debug.assert(metrics.body_cell_h > 0);
    std.debug.assert(metrics.title_cell_w > 0);
    std.debug.assert(metrics.title_cell_h > 0);
    std.debug.assert(metrics.about_max_w > 0);

    const max_surface = Size{
        .w = if (kind == .about)
            @min(available_surface.w, metrics.about_max_w)
        else
            available_surface.w,
        .h = available_surface.h,
    };

    const content_room_w = @max(
        metrics.body_cell_w,
        max_surface.w - metrics.shadow_margin * 2 - metrics.padding * 2,
    );
    const max_wrap_cells: usize = @intCast(@max(1, @divTrunc(content_room_w, metrics.body_cell_w)));
    const min_cells: usize = if (kind == .prompt) 42 else 30;
    const natural_cells = longestExplicitLine(message);
    var wrap_cells = @min(@max(natural_cells, min_cells), max_wrap_cells);
    var measured = measure(message, wrap_cells);

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
    var visible_message_rows = measured.rows;
    var message_scroll_max: usize = 0;

    // 모든 dialog는 먼저 본문 자연 높이를 사용하고, 화면을 넘을 때만 message
    // viewport를 만든다. scrollbar 공간을 먼저 제외하고 다시 wrap해야 측정 행
    // 수와 실제 그리기 행 수가 정확히 같다. prompt input과 button은 fixed_h에
    // 포함되어 항상 viewport 밖에 고정된다.
    if (fixed_h + rows_h + icon_h > max_surface.h) {
        const scrollbar_room = metrics.scrollbar_w + metrics.scrollbar_gap;
        const scroll_content_room_w = @max(
            metrics.body_cell_w,
            content_room_w - scrollbar_room,
        );
        const scroll_wrap_max: usize = @intCast(@max(1, @divTrunc(scroll_content_room_w, metrics.body_cell_w)));
        wrap_cells = @min(@max(natural_cells, min_cells), scroll_wrap_max);
        measured = measure(message, wrap_cells);
        rows_h = @intCast(measured.rows * @as(usize, @intCast(metrics.body_cell_h)));
        const row_room = max_surface.h - fixed_h - icon_h;
        visible_message_rows = @min(
            measured.rows,
            @as(usize, @intCast(@max(1, @divTrunc(row_room, metrics.body_cell_h)))),
        );
        message_scroll_max = measured.rows - visible_message_rows;
    }

    const scroll_extra = if (message_scroll_max > 0) metrics.scrollbar_w + metrics.scrollbar_gap else 0;
    const body_w = @as(i32, @intCast(measured.max_cells * @as(usize, @intCast(metrics.body_cell_w)))) + scroll_extra;
    const title_w: i32 = @intCast(display_width.stringWidth(title) * @as(usize, @intCast(metrics.title_cell_w)));
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

    return .{
        .size = .{
            .w = @min(desired_w, max_surface.w),
            .h = @min(desired_h, max_surface.h),
        },
        .wrap_cells = wrap_cells,
        .message_rows = measured.rows,
        .visible_message_rows = visible_message_rows,
        .message_scroll_max = message_scroll_max,
        .show_icon = show_icon,
        .fits = desired_w <= max_surface.w and desired_h <= max_surface.h,
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
    const layout = compute("TildaZ Config Error", message, .info, testMetrics(100), .{ .w = 640, .h = 480 });
    if (!layout.fits) {
        std.debug.print(
            "current config layout: fits={} size={}x{} rows={} wrap={} longest={}\n",
            .{ layout.fits, layout.size.w, layout.size.h, layout.message_rows, layout.wrap_cells, longestExplicitLine(message) },
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
        const layout = compute(
            "TildaZ",
            message,
            .info,
            testMetrics(scale_percent),
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
    const layout = compute("TildaZ", message, .info, testMetrics(100), .{ .w = 1280, .h = 720 });
    try std.testing.expect(layout.fits);
    try std.testing.expectEqual(@as(usize, 100), layout.wrap_cells);
    try std.testing.expectEqual(@as(usize, 1), layout.message_rows);
}

test "compact layout keeps branded icon and scrolls only the message" {
    const message = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve";
    const layout = compute("TildaZ", message, .confirm, testMetrics(100), .{ .w = 640, .h = 400 });
    try std.testing.expect(layout.fits);
    try std.testing.expect(layout.show_icon);
    try std.testing.expectEqual(@as(usize, 12), layout.message_rows);
    try std.testing.expectEqual(@as(usize, 9), layout.visible_message_rows);
    try std.testing.expectEqual(@as(usize, 3), layout.message_scroll_max);
}

test "final compositor surface size recomputes wrapping without viewport margin" {
    const message = "A compositor may configure a narrower final surface than the client initially requested for this dialog message.";
    const initial = compute("TildaZ", message, .info, testMetrics(100), .{ .w = 1280, .h = 720 });
    const configured = computeForSurface("TildaZ", message, .info, testMetrics(100), .{ .w = 480, .h = 448 });
    try std.testing.expect(configured.fits);
    try std.testing.expect(configured.wrap_cells < initial.wrap_cells);
    try std.testing.expect(configured.message_rows > initial.message_rows);
    try std.testing.expect(configured.size.w <= 480);
    try std.testing.expect(configured.size.h <= 448);
}

test "current Linux dialog messages fit the 640x480 logical minimum" {
    const themes = @import("../../themes.zig");

    var quit_buf: [128]u8 = undefined;
    const quit_msg = try std.fmt.bufPrint(&quit_buf, messages.quit_confirm_format, .{ 32, "s" });

    var tab_limit_buf: [128]u8 = undefined;
    const tab_limit_msg = try std.fmt.bufPrint(&tab_limit_buf, messages.tab_limit_format, .{32});

    var about_buf: [2048]u8 = undefined;
    const about_msg = try std.fmt.bufPrint(&about_buf, messages.about_format, .{
        "0.6.1",
        "/home/example/.local/bin/tildaz",
        123456,
        "/home/example/.config/tildaz/config_0.json",
        "/home/example/.local/state/tildaz/tildaz0.log",
        "Ctrl+Shift+P",
        "Ctrl+Shift+L",
    });

    var parse_buf: [512]u8 = undefined;
    const parse_msg = try std.fmt.bufPrint(&parse_buf, messages.config_parse_failed_format, .{
        "/home/example/.config/tildaz/config_0.json",
        "SyntaxError",
    });

    var hotkey_invalid_buf: [384]u8 = undefined;
    const hotkey_invalid_msg = try std.fmt.bufPrint(
        &hotkey_invalid_buf,
        messages.config_hotkey_invalid_format,
        .{"shift+t"},
    );

    var theme_buf: [512]u8 = undefined;
    var theme_stream = std.io.fixedBufferStream(&theme_buf);
    const theme_writer = theme_stream.writer();
    try theme_writer.print(messages.config_unknown_theme_header_format, .{"Not A Theme"});
    for (themes.themes, 0..) |theme, i| {
        if (i > 0) try theme_writer.writeAll(", ");
        try theme_writer.writeAll(theme.name);
    }
    const theme_msg = theme_stream.getWritten();

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
    );

    var takeover_buf: [512]u8 = undefined;
    const takeover_msg = try std.fmt.bufPrint(&takeover_buf, messages.hotkey_takeover_format, .{
        "Ctrl+Shift+Space",
        "KWin",
        "Show Desktop Grid",
    });

    var mismatch_buf: [256]u8 = undefined;
    const mismatch_msg = try std.fmt.bufPrint(&mismatch_buf, messages.hotkey_mismatch_persists_format, .{
        "Ctrl+Shift+Space",
        "Meta+Ctrl+Space",
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
        .{ .title = messages.config_error_title, .message = shell_msg, .kind = .info },
        .{ .title = messages.shell_new_tab_error_title, .message = new_tab_msg, .kind = .info },
        // 64pt branded icon을 고정하면 최대 8-entry font 오류는 640x480에서
        // 본문만 3/4/3행 overflow한다. 1.7x는 고정 chrome 반올림으로 한 행 적다.
        .{ .title = messages.config_error_title, .message = font_msg, .kind = .info, .standard_scroll_by_scale = .{ 3, 4, 3 } },
        .{ .title = messages.hotkey_takeover_title, .message = takeover_msg, .kind = .confirm },
        .{ .title = messages.hotkey_mismatch_persists_title, .message = mismatch_msg, .kind = .info },
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
        for (metric_cases, 0..) |metrics, metric_index| {
            const layout = compute(
                title,
                message,
                kind,
                metrics,
                .{
                    .w = @divTrunc(640 * @as(i32, @intCast(scale_percent)), 100),
                    .h = @divTrunc(480 * @as(i32, @intCast(scale_percent)), 100),
                },
            );
            if (!layout.fits) {
                std.debug.print(
                    "dialog does not fit: title={s} scale={d}% body_cell_w={} size={}x{} rows={} wrap={} message_len={} preview={s}\n",
                    .{ title, scale_percent, metrics.body_cell_w, layout.size.w, layout.size.h, layout.message_rows, layout.wrap_cells, message.len, message[0..@min(message.len, 80)] },
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

fn testMetrics(scale_percent: u32) Metrics {
    return testMetricsWithCellWidths(scale_percent, 9, 11);
}

fn testWideCellMetrics(scale_percent: u32) Metrics {
    return testMetricsWithCellWidths(scale_percent, 15, 18);
}

fn testMetricsWithCellWidths(scale_percent: u32, body_cell_w: i32, title_cell_w: i32) Metrics {
    const scale = struct {
        fn value(v: i32, percent: u32) i32 {
            return @divTrunc(v * @as(i32, @intCast(percent)) + 99, 100);
        }
    }.value;
    return .{
        .body_cell_w = scale(body_cell_w, scale_percent),
        .body_cell_h = scale(17, scale_percent),
        .title_cell_w = scale(title_cell_w, scale_percent),
        .title_cell_h = scale(20, scale_percent),
        .padding = scale(8, scale_percent),
        .shadow_margin = scale(12, scale_percent),
        .viewport_margin = scale(16, scale_percent),
        .icon_size = scale(@intCast(ui_metrics.DIALOG_ICON_SIZE_PT), scale_percent),
        .icon_gap = scale(@intCast(ui_metrics.DIALOG_ICON_GAP_PT), scale_percent),
        .button_w = scale(100, scale_percent),
        .button_h = scale(44, scale_percent),
        .button_gap = scale(12, scale_percent),
        .about_max_w = scale(960, scale_percent),
        .scrollbar_w = scale(10, scale_percent),
        .scrollbar_gap = scale(8, scale_percent),
    };
}

test "dialogs use overflow rows only when content exceeds viewport" {
    const ordinary = "TildaZ v0.6.1\n\nexe: /home/example/tildaz\nconfig: /home/example/config.json";
    const ordinary_layout = compute("About TildaZ", ordinary, .about, testMetrics(100), .{ .w = 640, .h = 480 });
    try std.testing.expect(ordinary_layout.fits);
    try std.testing.expectEqual(@as(usize, 0), ordinary_layout.message_scroll_max);
    try std.testing.expectEqual(ordinary_layout.message_rows, ordinary_layout.visible_message_rows);

    const long_message = ("/home/" ++ ("x" ** 500) ++ "\n") ** 4;
    const overflow = compute("About TildaZ", long_message, .about, testMetrics(100), .{ .w = 640, .h = 480 });
    try std.testing.expect(overflow.fits);
    try std.testing.expect(overflow.show_icon);
    try std.testing.expect(overflow.message_scroll_max > 0);
    try std.testing.expect(overflow.visible_message_rows < overflow.message_rows);
    try std.testing.expect(overflow.size.w <= 640 - 32);
    try std.testing.expect(overflow.size.h <= 480 - 32);

    const info_overflow = compute("TildaZ Error", long_message, .info, testMetrics(100), .{ .w = 640, .h = 480 });
    try std.testing.expect(info_overflow.fits);
    try std.testing.expect(info_overflow.show_icon);
    try std.testing.expect(info_overflow.message_scroll_max > 0);

    const prompt_overflow = compute("TildaZ", long_message, .prompt, testMetrics(100), .{ .w = 640, .h = 480 });
    try std.testing.expect(prompt_overflow.fits);
    try std.testing.expect(prompt_overflow.show_icon);
    try std.testing.expect(prompt_overflow.message_scroll_max > 0);
}

test "#314 About maximum width scales in logical points" {
    const message = "x" ** 2000;
    const scales = [_]u32{ 100, 170, 200 };
    for (scales) |scale_percent| {
        const layout = compute(
            "About TildaZ",
            message,
            .about,
            testMetrics(scale_percent),
            .{
                .w = @divTrunc(2200 * @as(i32, @intCast(scale_percent)), 100),
                .h = @divTrunc(1200 * @as(i32, @intCast(scale_percent)), 100),
            },
        );
        try std.testing.expect(layout.size.w <= @divTrunc(960 * @as(i32, @intCast(scale_percent)) + 99, 100));
    }
}
