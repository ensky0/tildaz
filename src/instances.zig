const std = @import("std");
const config = @import("config.zig");
const paths = @import("paths.zig");

pub const max_config_index: u32 = 999;

pub const ProcessLock = struct {
    file: std.fs.File,
    clear_pid_on_close: bool,

    pub fn deinit(self: *ProcessLock) void {
        if (self.clear_pid_on_close) self.file.setEndPos(0) catch {};
        self.file.unlock();
        self.file.close();
    }
};

pub fn parseConfigFileName(name: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, name, "config_") or !std.mem.endsWith(u8, name, ".json")) return null;
    const digits = name["config_".len .. name.len - ".json".len];
    if (digits.len == 0 or (digits.len > 1 and digits[0] == '0')) return null;
    const index = std.fmt.parseInt(u32, digits, 10) catch return null;
    return if (index <= max_config_index) index else null;
}

pub fn listConfigIndices(allocator: std.mem.Allocator) ![]u32 {
    const dir_path = try paths.configDir(allocator);
    defer allocator.free(dir_path);
    try paths.ensureConfigDir(allocator);

    var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();
    var indices: std.ArrayList(u32) = .empty;
    errdefer indices.deinit(allocator);
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (parseConfigFileName(entry.name)) |index| try indices.append(allocator, index);
    }
    std.mem.sort(u32, indices.items, {}, std.sort.asc(u32));
    return indices.toOwnedSlice(allocator);
}

pub fn nextConfigIndex(indices: []const u32) !u32 {
    if (indices.len == 0) return 0;
    if (indices[indices.len - 1] >= max_config_index) return error.TooManyConfigs;
    return indices[indices.len - 1] + 1;
}

pub fn createDefaultConfig(
    allocator: std.mem.Allocator,
    index: u32,
    shell_resolved: []const u8,
    hotkey: []const u8,
) !void {
    const path = try paths.configPathFor(allocator, index);
    defer allocator.free(path);
    const json = try config.defaultConfigJsonWithHotkey(allocator, shell_resolved, hotkey);
    defer allocator.free(json);

    const file = try std.fs.createFileAbsolute(path, .{ .exclusive = true });
    defer file.close();
    try file.writeAll(json);
}

pub fn acquireWorkerLock(allocator: std.mem.Allocator, index: u32) !?ProcessLock {
    const path = try paths.instanceLockPath(allocator, index);
    defer allocator.free(path);
    var lock = (try tryAcquireProcessLock(path)) orelse return null;
    errdefer lock.deinit();
    try writeOwnerPid(lock.file);
    lock.clear_pid_on_close = true;
    return lock;
}

pub fn acquireLauncherLock(allocator: std.mem.Allocator) !ProcessLock {
    const path = try paths.launcherLockPath(allocator);
    defer allocator.free(path);
    const file = try std.fs.createFileAbsolute(path, .{
        .truncate = false,
        .read = true,
        .lock = .exclusive,
    });
    var lock: ProcessLock = .{ .file = file, .clear_pid_on_close = false };
    errdefer lock.deinit();
    try writeOwnerPid(lock.file);
    lock.clear_pid_on_close = true;
    return lock;
}

pub fn isRunning(allocator: std.mem.Allocator, index: u32) !bool {
    const path = try paths.instanceLockPath(allocator, index);
    defer allocator.free(path);
    var lock = (try tryAcquireProcessLock(path)) orelse return true;
    // lock을 얻었다는 사실이 owner 부재를 증명한다. 이전 crash가 남긴 PID를
    // lock 아래에서 비워 다음 worker의 PID 기록을 startup acknowledgment로 쓴다.
    try lock.file.setEndPos(0);
    lock.deinit();
    return false;
}

pub fn waitUntilRunning(allocator: std.mem.Allocator, index: u32, timeout_ns: u64) !void {
    const path = try paths.instanceLockPath(allocator, index);
    defer allocator.free(path);
    var timer = try std.time.Timer.start();
    while (timer.read() < timeout_ns) {
        // PID는 worker가 lock을 획득한 뒤 기록한다. 파일이 비어 있는 동안 lock을
        // probe하면 launcher가 worker보다 먼저 lock을 잡는 race가 생기므로 metadata만
        // 확인한다. PID가 쓰인 뒤 실제 생존 판정은 다시 advisory lock으로 검증한다.
        if (ownerPidWritten(path) and try isRunning(allocator, index)) return;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return error.WorkerStartTimeout;
}

fn ownerPidWritten(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();
    return (file.getEndPos() catch return false) != 0;
}

fn tryAcquireProcessLock(path: []const u8) !?ProcessLock {
    const file = std.fs.createFileAbsolute(path, .{
        .truncate = false,
        .read = true,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return null,
        else => return err,
    };
    return .{ .file = file, .clear_pid_on_close = false };
}

fn writeOwnerPid(file: std.fs.File) !void {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}\n", .{currentProcessId()});
    try file.setEndPos(0);
    try file.seekTo(0);
    try file.writeAll(text);
}

fn currentProcessId() u32 {
    return switch (@import("builtin").os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
}

pub fn spawnWorker(allocator: std.mem.Allocator, index: u32) !void {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = try std.fs.selfExePath(&exe_buf);
    const index_text = try std.fmt.allocPrint(allocator, "{d}", .{index});
    defer allocator.free(index_text);
    var child = std.process.Child.init(&.{ exe, "--instance", index_text }, allocator);
    try child.spawn();
}

pub fn defaultShell(allocator: std.mem.Allocator) ![]u8 {
    if (@import("builtin").os.tag != .windows) {
        if (std.process.getEnvVarOwned(allocator, "SHELL") catch null) |shell| return shell;
    }
    return allocator.dupe(u8, config.Defaults.shell);
}

pub fn configAutoStart(allocator: std.mem.Allocator, index: u32) !bool {
    const path = try paths.configPathFor(allocator, index);
    defer allocator.free(path);
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(content);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidConfig;
    const value = parsed.value.object.get("auto_start") orelse return error.InvalidConfig;
    if (value != .bool) return error.InvalidConfig;
    return value.bool;
}

pub fn configHotkeyText(allocator: std.mem.Allocator, index: u32) ![]u8 {
    const path = try paths.configPathFor(allocator, index);
    defer allocator.free(path);
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(content);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidConfig;
    const value = parsed.value.object.get("hotkey") orelse return error.InvalidConfig;
    if (value != .string) return error.InvalidConfig;
    return allocator.dupe(u8, value.string);
}

pub fn hotkeyTaken(allocator: std.mem.Allocator, indices: []const u32, candidate: config.Hotkey) !bool {
    for (indices) |index| {
        const path = try paths.configPathFor(allocator, index);
        defer allocator.free(path);
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 64 * 1024);
        defer allocator.free(content);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidConfig;
        const value = parsed.value.object.get("hotkey") orelse return error.InvalidConfig;
        if (value != .string) return error.InvalidConfig;
        const existing = config.Hotkey.fromString(value.string) orelse return error.InvalidConfig;
        if (std.meta.eql(existing, candidate)) return true;
    }
    return false;
}

test "only canonical numbered config names are accepted" {
    try std.testing.expectEqual(@as(?u32, 0), parseConfigFileName("config_0.json"));
    try std.testing.expectEqual(@as(?u32, 42), parseConfigFileName("config_42.json"));
    try std.testing.expectEqual(@as(?u32, null), parseConfigFileName("config.json"));
    try std.testing.expectEqual(@as(?u32, null), parseConfigFileName("config0.json"));
    try std.testing.expectEqual(@as(?u32, null), parseConfigFileName("config_01.json"));
    try std.testing.expectEqual(@as(?u32, null), parseConfigFileName("config-1.json"));
    try std.testing.expectEqual(@as(?u32, null), parseConfigFileName("config_1000.json"));
}

test "next config index follows the greatest existing index" {
    try std.testing.expectEqual(@as(u32, 0), try nextConfigIndex(&.{}));
    try std.testing.expectEqual(@as(u32, 1), try nextConfigIndex(&.{0}));
    try std.testing.expectEqual(@as(u32, 8), try nextConfigIndex(&.{ 0, 3, 7 }));
    try std.testing.expectError(error.TooManyConfigs, nextConfigIndex(&.{max_config_index}));
}

test "current process id is available for lock diagnostics" {
    try std.testing.expect(currentProcessId() != 0);
}

test "process lock records pid and excludes a second owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "instance7.lock" });
    defer allocator.free(path);

    {
        var first = (try tryAcquireProcessLock(path)).?;
        defer first.deinit();
        try writeOwnerPid(first.file);
        first.clear_pid_on_close = true;

        try first.file.seekTo(0);
        var pid_buf: [32]u8 = undefined;
        const pid_text = std.mem.trim(u8, pid_buf[0..try first.file.readAll(&pid_buf)], "\r\n");
        try std.testing.expectEqual(currentProcessId(), try std.fmt.parseInt(u32, pid_text, 10));
        try std.testing.expect((try tryAcquireProcessLock(path)) == null);
    }
    var next = (try tryAcquireProcessLock(path)).?;
    next.deinit();
}
