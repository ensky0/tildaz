//! #701 — launcher 가 sway · Hyprland 자동 실행을 처음 넣었을 때의 안내를 worker 에게 넘긴다.
//!
//! launcher 는 창이 없어서 그 자리에서 띄운 다이얼로그는 로그로만 간다 (`Config.load_notice`
//! 주석과 같은 이유). 그래서 launcher 가 상태 폴더에 알릴 내용을 남기고, worker 가 창이 뜬 뒤
//! 읽어 한 번 보여 준다 (`wayland_minimal.zig` 의 `drainConfigNotice`).
//!
//! **파일을 지우는 데 성공한 worker 만 보여 준다.** worker 가 여럿 떠도 안내는 한 번이다.
const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const paths = @import("../paths.zig");
const log = @import("../log.zig");

const file_name = "autostart-notice-pending";

pub const Notice = struct {
    /// 데스크톱 이름 (`sway` · `Hyprland`).
    desktop: []const u8,
    /// 불러오는 줄을 넣은 사용자 설정 파일.
    path: []const u8,
    /// 넣은 줄.
    line: []const u8,
    raw: []u8,

    pub fn deinit(self: Notice, allocator: std.mem.Allocator) void {
        allocator.free(self.raw);
    }
};

fn noticePath(rt: Runtime, allocator: std.mem.Allocator) ![]u8 {
    const dir = try paths.stateDir(rt, allocator);
    defer allocator.free(dir);
    return std.Io.Dir.path.join(allocator, &.{ dir, file_name });
}

/// launcher 가 부른다.
pub fn record(rt: Runtime, allocator: std.mem.Allocator, desktop: []const u8, path: []const u8, line: []const u8) !void {
    for ([_][]const u8{ desktop, path, line }) |part| {
        if (std.mem.indexOfScalar(u8, part, '\n') != null) return error.UnsupportedPath;
    }
    const content = try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}\n", .{ desktop, path, line });
    defer allocator.free(content);
    const file = try noticePath(rt, allocator);
    defer allocator.free(file);
    if (std.Io.Dir.path.dirname(file)) |dir| try paths.ensureDir(rt, dir);
    _ = try paths.writeFileIfChanged(rt, allocator, file, content);
}

/// worker 가 부른다. 남은 안내가 있으면 지우고 돌려준다. 호출자가 `deinit` 한다.
pub fn take(rt: Runtime, allocator: std.mem.Allocator) ?Notice {
    const file = noticePath(rt, allocator) catch return null;
    defer allocator.free(file);
    const raw = readFile(rt, allocator, file) orelse return null;
    std.Io.Dir.deleteFileAbsolute(rt.io, file) catch {
        // 다른 worker 가 먼저 지웠다 — 그쪽이 보여 준다.
        allocator.free(raw);
        return null;
    };
    return parse(raw) orelse {
        log.appendLine("desktop", "autostart notice file was malformed — dropped", .{});
        allocator.free(raw);
        return null;
    };
}

fn readFile(rt: Runtime, allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(rt.io, path, .{}) catch return null;
    defer file.close(rt.io);
    var reader = file.reader(rt.io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(16 * 1024)) catch null;
}

fn parse(raw: []u8) ?Notice {
    var it = std.mem.splitScalar(u8, raw, '\n');
    const desktop = it.next() orelse return null;
    const path = it.next() orelse return null;
    const line = it.next() orelse return null;
    if (desktop.len == 0 or path.len == 0 or line.len == 0) return null;
    return .{ .desktop = desktop, .path = path, .line = line, .raw = raw };
}

test "#701 the autostart notice keeps the desktop, file and line" {
    var raw = "Hyprland\n/home/u/.config/hypr/hyprland.lua\npcall(require, \"tildaz\")\n".*;
    const n = parse(&raw).?;
    try std.testing.expectEqualStrings("Hyprland", n.desktop);
    try std.testing.expectEqualStrings("/home/u/.config/hypr/hyprland.lua", n.path);
    try std.testing.expectEqualStrings("pcall(require, \"tildaz\")", n.line);
    var short = "sway\n/home/u/.config/sway/config\n".*;
    try std.testing.expect(parse(&short) == null);
    var empty = "".*;
    try std.testing.expect(parse(&empty) == null);
}
