const std = @import("std");

pub const max_index = 999;

pub fn appId(buf: []u8, index: u32) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, "tildaz.instance{d}", .{index});
}

pub fn displayName(buf: []u8, index: u32) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, "TildaZ_{d}", .{index});
}

pub fn shortcutId(buf: []u8, index: u32) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, "toggle-{d}", .{index});
}

pub fn shortcutDescription(buf: []u8, index: u32) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, "Show / hide TildaZ {d}", .{index});
}

pub fn scopeName(buf: []u8, index: u32, pid: u32) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, "app-tildaz.instance{d}-{d}.scope", .{ index, pid });
}

pub fn isScopeForIndex(leaf: []const u8, index: u32) bool {
    var prefix_buf: [48]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "app-tildaz.instance{d}-", .{index}) catch return false;
    if (!std.mem.startsWith(u8, leaf, prefix) or !std.mem.endsWith(u8, leaf, ".scope")) return false;
    const pid_text = leaf[prefix.len .. leaf.len - ".scope".len];
    if (pid_text.len == 0) return false;
    _ = std.fmt.parseInt(u32, pid_text, 10) catch return false;
    return true;
}

fn parseDesktopFileName(name: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, name, "tildaz.instance") or !std.mem.endsWith(u8, name, ".desktop")) return null;
    const digits = name["tildaz.instance".len .. name.len - ".desktop".len];
    if (digits.len == 0 or (digits.len > 1 and digits[0] == '0')) return null;
    const index = std.fmt.parseInt(u32, digits, 10) catch return null;
    return if (index <= max_index) index else null;
}

fn applicationsDir(allocator: std.mem.Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".local", "share", "applications" });
}

fn containsIndex(indices: []const u32, index: u32) bool {
    for (indices) |candidate| if (candidate == index) return true;
    return false;
}

pub fn ensureDesktopEntry(allocator: std.mem.Allocator, index: u32) !void {
    const dir = try applicationsDir(allocator);
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);

    const file_name = try std.fmt.allocPrint(allocator, "tildaz.instance{d}.desktop", .{index});
    defer allocator.free(file_name);
    const path = try std.fs.path.join(allocator, &.{ dir, file_name });
    defer allocator.free(path);

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = try std.fs.selfExePath(&exe_buf);
    if (std.mem.indexOfAny(u8, exe, "\n\r\"") != null) return error.UnsupportedExecutablePath;

    const content = try std.fmt.allocPrint(allocator,
        \\[Desktop Entry]
        \\Type=Application
        \\Name=TildaZ_{d}
        \\GenericName=Drop-down Terminal Instance
        \\Comment=Independent TildaZ terminal instance {d}
        \\Exec="{s}" --instance {d}
        \\Icon=tildaz
        \\Terminal=false
        \\Categories=System;TerminalEmulator;
        \\StartupWMClass=tildaz.instance{d}
        \\StartupNotify=false
        \\NoDisplay=true
        \\
    , .{ index, index, exe, index, index });
    defer allocator.free(content);

    if (std.fs.openFileAbsolute(path, .{})) |file| {
        defer file.close();
        if (file.readToEndAlloc(allocator, 64 * 1024)) |existing| {
            defer allocator.free(existing);
            if (std.mem.eql(u8, existing, content)) return;
        } else |_| {}
    } else |_| {}

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

pub fn syncDesktopEntries(allocator: std.mem.Allocator, indices: []const u32) !void {
    const dir_path = try applicationsDir(allocator);
    defer allocator.free(dir_path);
    try std.fs.cwd().makePath(dir_path);

    for (indices) |index| try ensureDesktopEntry(allocator, index);

    var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const index = parseDesktopFileName(entry.name) orelse continue;
        if (!containsIndex(indices, index)) try dir.deleteFile(entry.name);
    }
}

test "numbered Linux identity is canonical" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("tildaz.instance12", try appId(&buf, 12));
    try std.testing.expectEqualStrings("TildaZ_12", try displayName(&buf, 12));
    try std.testing.expectEqualStrings("toggle-12", try shortcutId(&buf, 12));
    try std.testing.expectEqualStrings("Show / hide TildaZ 12", try shortcutDescription(&buf, 12));
    try std.testing.expectEqualStrings("app-tildaz.instance12-345.scope", try scopeName(&buf, 12, 345));
    try std.testing.expect(isScopeForIndex("app-tildaz.instance12-345.scope", 12));
    try std.testing.expect(!isScopeForIndex("app-tildaz.instance1-345.scope", 12));
    try std.testing.expect(!isScopeForIndex("app-tildaz.instance12-other.scope", 12));
    try std.testing.expectEqual(@as(?u32, 0), parseDesktopFileName("tildaz.instance0.desktop"));
    try std.testing.expectEqual(@as(?u32, null), parseDesktopFileName("tildaz.instance01.desktop"));
    try std.testing.expectEqual(@as(?u32, null), parseDesktopFileName("tildaz.desktop"));
}
