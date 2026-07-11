const std = @import("std");
const config = @import("../config.zig");
const instances = @import("../instances.zig");
const log = @import("../log.zig");
const instance_identity = @import("../host/linux/instance_identity.zig");

pub fn sync(allocator: std.mem.Allocator, indices: []const u32) !void {
    try instance_identity.syncDesktopEntries(allocator, indices);
    if (desktopContains("hyprland")) syncHyprland(allocator, indices) catch |err| {
        log.appendLine("hyprland", "numbered hotkey synchronization skipped: {s}", .{@errorName(err)});
    };
    if (desktopContains("cosmic")) syncCosmic(allocator, indices) catch |err| {
        log.appendLine("cosmic", "numbered hotkey synchronization skipped: {s}", .{@errorName(err)});
    };
}

fn desktopContains(name: []const u8) bool {
    const value = std.posix.getenv("XDG_CURRENT_DESKTOP") orelse return false;
    var it = std.mem.tokenizeAny(u8, value, ":;");
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), name)) return true;
    }
    return false;
}

fn syncHyprland(allocator: std.mem.Allocator, indices: []const u32) !void {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = try std.fs.selfExePath(&exe_buf);
    try removeManagedHyprlandBindings(allocator, exe);
    for (indices) |index| {
        const text = try instances.configHotkeyText(allocator, index);
        defer allocator.free(text);
        const hotkey = config.Hotkey.fromString(text) orelse return error.InvalidConfig;
        var accel_buf: [96]u8 = undefined;
        const accel = try hyprlandAccel(&accel_buf, hotkey);
        const binding = try std.fmt.allocPrint(allocator, "{s},exec,{s} --toggle {d}", .{ accel, exe, index });
        defer allocator.free(binding);
        if (!try runHyprlandKeyword(allocator, "bind", binding)) return error.HyprctlFailed;
    }
    log.appendLine("hyprland", "numbered hotkeys synchronized ({d})", .{indices.len});
}

const HyprlandBind = struct {
    modmask: u32 = 0,
    key: []const u8 = "",
    keycode: u32 = 0,
    dispatcher: []const u8 = "",
    arg: []const u8 = "",
};

const hypr_mod_shift: u32 = 1;
const hypr_mod_ctrl: u32 = 4;
const hypr_mod_alt: u32 = 8;
const hypr_mod_super: u32 = 64;
const hypr_supported_mods = hypr_mod_shift | hypr_mod_ctrl | hypr_mod_alt | hypr_mod_super;

fn removeManagedHyprlandBindings(allocator: std.mem.Allocator, exe: []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "hyprctl", "-j", "binds" },
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return error.HyprctlFailed,
        else => return error.HyprctlFailed,
    }

    const parsed = try std.json.parseFromSlice([]HyprlandBind, allocator, result.stdout, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    var removed: usize = 0;
    for (parsed.value) |binding| {
        var accel_buf: [96]u8 = undefined;
        const accel = managedHyprlandAccel(&accel_buf, binding, exe) orelse continue;
        _ = try runHyprlandKeyword(allocator, "unbind", accel);
        removed += 1;
    }
    log.appendLine("hyprland", "removed managed runtime hotkeys ({d})", .{removed});
}

fn managedHyprlandAccel(buf: []u8, binding: HyprlandBind, exe: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, binding.dispatcher, "exec")) return null;
    if (binding.keycode != 0 or binding.key.len == 0) return null;
    if ((binding.modmask & ~hypr_supported_mods) != 0) return null;
    if (!managedToggleCommand(binding.arg, exe)) return null;

    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    if ((binding.modmask & hypr_mod_ctrl) != 0) writer.writeAll("CTRL ") catch return null;
    if ((binding.modmask & hypr_mod_shift) != 0) writer.writeAll("SHIFT ") catch return null;
    if ((binding.modmask & hypr_mod_alt) != 0) writer.writeAll("ALT ") catch return null;
    if ((binding.modmask & hypr_mod_super) != 0) writer.writeAll("SUPER ") catch return null;
    writer.writeByte(',') catch return null;
    writer.writeAll(binding.key) catch return null;
    return fbs.getWritten();
}

fn managedToggleCommand(arg: []const u8, exe: []const u8) bool {
    if (!std.mem.startsWith(u8, arg, exe)) return false;
    const rest = arg[exe.len..];
    const prefix = " --toggle ";
    if (!std.mem.startsWith(u8, rest, prefix)) return false;
    const index_text = rest[prefix.len..];
    if (index_text.len == 0) return false;
    _ = std.fmt.parseInt(u32, index_text, 10) catch return false;
    return true;
}

fn runHyprlandKeyword(allocator: std.mem.Allocator, keyword: []const u8, value: []const u8) !bool {
    var child = std.process.Child.init(&.{ "hyprctl", "keyword", keyword, value }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    return switch (try child.wait()) {
        .Exited => |code| code == 0,
        else => false,
    };
}

pub fn hyprlandAccel(buf: []u8, hotkey: config.Hotkey) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    if ((hotkey.modifiers & config.Hotkey.MOD_CTRL) != 0) try writer.writeAll("CTRL ");
    if ((hotkey.modifiers & config.Hotkey.MOD_SHIFT) != 0) try writer.writeAll("SHIFT ");
    if ((hotkey.modifiers & config.Hotkey.MOD_ALT) != 0) try writer.writeAll("ALT ");
    if ((hotkey.modifiers & config.Hotkey.MOD_SUPER) != 0) try writer.writeAll("SUPER ");
    try writer.writeByte(',');
    try writer.writeAll(config.linuxKeysymName(hotkey.keysym) orelse return error.InvalidConfig);
    return fbs.getWritten();
}

test "managed Hyprland bindings are identified and reconstructed" {
    const exe = "/home/test/tildaz";
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings(",F3", managedHyprlandAccel(&buf, .{
        .key = "F3",
        .dispatcher = "exec",
        .arg = "/home/test/tildaz --toggle 2",
    }, exe).?);
    try std.testing.expectEqualStrings("CTRL SHIFT ,F4", managedHyprlandAccel(&buf, .{
        .modmask = hypr_mod_ctrl | hypr_mod_shift,
        .key = "F4",
        .dispatcher = "exec",
        .arg = "/home/test/tildaz --toggle 3",
    }, exe).?);
    try std.testing.expect(managedHyprlandAccel(&buf, .{
        .key = "F3",
        .dispatcher = "exec",
        .arg = "/usr/bin/other --toggle 2",
    }, exe) == null);
    try std.testing.expect(managedHyprlandAccel(&buf, .{
        .key = "F3",
        .dispatcher = "workspace",
        .arg = "3",
    }, exe) == null);
}

test "Hyprland binds JSON keeps the fields needed for cleanup" {
    const json =
        \\[{"modmask":0,"key":"F3","keycode":0,"dispatcher":"exec","arg":"/home/test/tildaz --toggle 2","description":""}]
    ;
    const parsed = try std.json.parseFromSlice([]HyprlandBind, std.testing.allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.len);
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings(",F3", managedHyprlandAccel(&buf, parsed.value[0], "/home/test/tildaz").?);
}

fn syncCosmic(allocator: std.mem.Allocator, indices: []const u32) !void {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
    const dir_path = try std.fs.path.join(allocator, &.{ home, ".config", "cosmic", "com.system76.CosmicSettings.Shortcuts", "v1" });
    defer allocator.free(dir_path);
    try std.fs.cwd().makePath(dir_path);
    const path = try std.fs.path.join(allocator, &.{ dir_path, "custom" });
    defer allocator.free(path);

    const content = blk: {
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk try allocator.dupe(u8, "{\n}\n"),
            else => return err,
        };
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, 1024 * 1024);
    };
    defer allocator.free(content);

    const close_offset = findClosingMapLine(content) orelse return error.UnsupportedCosmicShortcutFormat;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var offset: usize = 0;
    while (offset < content.len) {
        const end = std.mem.indexOfScalarPos(u8, content, offset, '\n') orelse content.len;
        const line = content[offset..end];
        if (offset == close_offset) try appendCosmicEntries(&output, allocator, indices);
        if (!isTildazCosmicEntry(line)) {
            try output.appendSlice(allocator, line);
            try output.append(allocator, '\n');
        }
        offset = if (end < content.len) end + 1 else content.len;
    }

    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tildaz-tmp", .{path});
    defer allocator.free(temp_path);
    errdefer std.fs.deleteFileAbsolute(temp_path) catch {};
    {
        const temp = try std.fs.createFileAbsolute(temp_path, .{ .truncate = true });
        defer temp.close();
        try temp.writeAll(output.items);
        try temp.sync();
    }
    try std.fs.renameAbsolute(temp_path, path);
    log.appendLine("cosmic", "numbered hotkeys synchronized ({d})", .{indices.len});
}

pub fn findClosingMapLine(content: []const u8) ?usize {
    var found: ?usize = null;
    var offset: usize = 0;
    while (offset < content.len) {
        const end = std.mem.indexOfScalarPos(u8, content, offset, '\n') orelse content.len;
        if (std.mem.eql(u8, std.mem.trim(u8, content[offset..end], " \t\r"), "}")) found = offset;
        offset = if (end < content.len) end + 1 else content.len;
    }
    return found;
}

fn isTildazCosmicEntry(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "description: Some(\"TildaZ instance ") != null or
        (std.mem.indexOf(u8, line, "Spawn(\"") != null and
            std.mem.indexOf(u8, line, "tildaz --toggle") != null);
}

fn appendCosmicEntries(output: *std.ArrayList(u8), allocator: std.mem.Allocator, indices: []const u32) !void {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = try std.fs.selfExePath(&exe_buf);
    for (indices) |index| {
        const text = try instances.configHotkeyText(allocator, index);
        defer allocator.free(text);
        const hotkey = config.Hotkey.fromString(text) orelse return error.InvalidConfig;
        try output.appendSlice(allocator, "    (modifiers: [");
        var first = true;
        const mods = [_]struct { bit: u32, name: []const u8 }{
            .{ .bit = config.Hotkey.MOD_SUPER, .name = "Super" },
            .{ .bit = config.Hotkey.MOD_CTRL, .name = "Ctrl" },
            .{ .bit = config.Hotkey.MOD_ALT, .name = "Alt" },
            .{ .bit = config.Hotkey.MOD_SHIFT, .name = "Shift" },
        };
        for (mods) |mod| {
            if ((hotkey.modifiers & mod.bit) == 0) continue;
            if (!first) try output.appendSlice(allocator, ", ");
            try output.appendSlice(allocator, mod.name);
            first = false;
        }
        try output.appendSlice(allocator, "], key: \"");
        try output.appendSlice(allocator, config.linuxKeysymName(hotkey.keysym) orelse return error.InvalidConfig);
        const description = try std.fmt.allocPrint(allocator, "\", description: Some(\"TildaZ_{d}\")): Spawn(\"", .{index});
        defer allocator.free(description);
        try output.appendSlice(allocator, description);
        try appendRonString(output, allocator, exe);
        const suffix = try std.fmt.allocPrint(allocator, " --toggle {d}\"),\n", .{index});
        defer allocator.free(suffix);
        try output.appendSlice(allocator, suffix);
    }
}

fn appendRonString(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (value) |byte| {
        if (byte == '\\' or byte == '"') try output.append(allocator, '\\');
        try output.append(allocator, byte);
    }
}
