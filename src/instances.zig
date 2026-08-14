const std = @import("std");
const config = @import("config.zig");
const paths = @import("paths.zig");
const runtime = @import("runtime.zig");
const Runtime = runtime.Runtime;

pub const max_config_index: u32 = 999;

/// #282 G12 — instance 창 식별자 단일 소스. Windows 는 이 값들로 worker 창을
/// IPC 조회한다: `instance_request` 가 FindWindowW 로 coordinator 를 찾고,
/// `hotkey_capture` 가 각 worker 로 broadcast, `window` 가 창을 생성 — 셋이
/// 같은 클래스명·타이틀 형식을 써야 한다(불일치 시 hotkey_capture 는 무음
/// no-op, instance_request 는 CoordinatorNotRunning 오해석). Linux 는 같은
/// 타이틀 형식을 xdg_toplevel 표시 타이틀로 재사용(형식 일관성).
pub const window_class_name = "TildaZWindow";
pub const window_title_prefix = "TildaZ-";

/// 창 타이틀 = `TildaZ-<worker index>` (예 "TildaZ-0" = coordinator).
pub fn windowTitle(buf: []u8, index: u32) ![]const u8 {
    return std.fmt.bufPrint(buf, window_title_prefix ++ "{d}", .{index});
}

/// 측정용 인스턴스 (#382 의 `-e`) 의 창 타이틀. **worker 의 타이틀과 절대 겹치지 않는
/// 이름이어야 한다** — Windows 의 `instance_request.send` 와 `hotkey_capture.broadcast`
/// 는 worker 창을 `FindWindowW(window_class_name, "TildaZ-<index>")` 로 찾으므로, 측정
/// 창이 같은 타이틀을 쓰면 그 조회가 worker 대신 측정 창을 집을 수 있다. 측정 인스턴스는
/// worker 가 아니다 — worker lock 도 endpoint 상태도 갖지 않는다.
///
/// index 를 붙이지 않는다. 측정은 한 번에 하나만 돌리고 (`compare-terminals.sh`), 어떤
/// index 로 실행하든 (`--instance N` + `-e`) worker 조회에서 빠지는 것이 목적이다.
pub const stress_window_title = window_title_prefix ++ "stress";

/// 현재 역할의 창 타이틀. **Windows 와 Linux 가 같은 함수를 쓴다** — 두 host 가 각자
/// `switch (identity)` 를 두면 한쪽만 고쳐지고, 그것이 e5c7857 에서 실제로 일어났다
/// (Windows 만 분리되고 Linux 의 `createXdgToplevel` 이 worker 타이틀을 계속 보냈다).
pub fn windowTitleForCurrentRole(buf: []u8) ![]const u8 {
    const instance_context = @import("instance_context.zig");
    return switch (instance_context.currentRole()) {
        .worker => try windowTitle(buf, instance_context.requireWorkerIndex()),
        .stress => stress_window_title,
    };
}

test "측정 창 타이틀은 어떤 worker 타이틀과도 겹치지 않는다" {
    // 표본 몇 개를 비교하는 것으로는 계약이 지켜지지 않는다 — `stress_window_title` 을
    // "TildaZ-5" 로 바꿔도 그 표본만 피하면 통과하면서, `FindWindowW(class, "TildaZ-5")`
    // 가 측정 창을 집게 된다. 그래서 **접미사가 10진수가 아님을 단정한다.** worker 타이틀은
    // prefix + 10진수뿐이므로 이 성질이 곧 "어떤 index 와도 겹치지 않는다" 다.
    try std.testing.expect(std.mem.startsWith(u8, stress_window_title, window_title_prefix));
    const suffix = stress_window_title[window_title_prefix.len..];
    try std.testing.expect(suffix.len > 0);
    try std.testing.expectError(error.InvalidCharacter, std.fmt.parseInt(u32, suffix, 10));

    // 위 성질의 결과를 표본으로도 한 번 더 확인한다 (경계 index 포함).
    var buf: [32]u8 = undefined;
    for ([_]u32{ 0, 1, 9, 10, 99, max_config_index, std.math.maxInt(u32) }) |index| {
        try std.testing.expect(!std.mem.eql(u8, stress_window_title, try windowTitle(&buf, index)));
    }
}

test "창 타이틀은 역할에서 갈린다" {
    const instance_context = @import("instance_context.zig");
    const previous_role = instance_context.currentRole();
    defer instance_context.setRole(previous_role);

    var buf: [32]u8 = undefined;
    instance_context.setWorkerIndex(0);
    instance_context.setRole(.worker);
    try std.testing.expectEqualStrings("TildaZ-0", try windowTitleForCurrentRole(&buf));
    instance_context.setRole(.stress);
    try std.testing.expectEqualStrings(stress_window_title, try windowTitleForCurrentRole(&buf));
}

pub const ProcessLock = struct {
    file: std.Io.File,
    clear_pid_on_close: bool,

    pub fn deinit(self: *ProcessLock, rt: Runtime) void {
        // #451 — `fs.File.setEndPos` ➡️ `Io.File.setLength` (릴리즈 노트 upgrade guide).
        if (self.clear_pid_on_close) self.file.setLength(rt.io, 0) catch {};
        self.file.unlock(rt.io);
        self.file.close(rt.io);
    }
};

/// #304 — worker process 생존과 request endpoint 준비는 서로 다른 상태다.
/// lock owner PID와 같은 PID의 상태만 유효하며, 이전 process가 남긴 파일은
/// launcher가 ready로 인정하지 않는다.
pub const EndpointState = enum {
    starting,
    ready,
    unavailable,
};

const EndpointSnapshot = struct {
    pid: u32,
    state: EndpointState,
};

const EndpointProbeResult = enum {
    starting,
    ready,
    unavailable,
    worker_exited,
};

const endpoint_poll_interval_ns = 10 * std.time.ns_per_ms;

pub fn parseConfigFileName(name: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, name, "config_") or !std.mem.endsWith(u8, name, ".json")) return null;
    const digits = name["config_".len .. name.len - ".json".len];
    if (digits.len == 0 or (digits.len > 1 and digits[0] == '0')) return null;
    const index = std.fmt.parseInt(u32, digits, 10) catch return null;
    return if (index <= max_config_index) index else null;
}

pub fn listConfigIndices(rt: Runtime, allocator: std.mem.Allocator) ![]u32 {
    const dir_path = try paths.configDir(rt, allocator);
    defer allocator.free(dir_path);
    try paths.ensureConfigDir(rt, allocator);

    var dir = try std.Io.Dir.openDirAbsolute(rt.io, dir_path, .{ .iterate = true });
    defer dir.close(rt.io);
    var indices: std.ArrayList(u32) = .empty;
    errdefer indices.deinit(allocator);
    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
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
    rt: Runtime,
    allocator: std.mem.Allocator,
    index: u32,
    shell_resolved: []const u8,
    hotkey: []const u8,
) !void {
    const path = try paths.configPathFor(rt, allocator, index);
    defer allocator.free(path);
    const json = try config.defaultConfigJsonWithHotkey(allocator, shell_resolved, hotkey);
    defer allocator.free(json);

    const file = try std.Io.Dir.createFileAbsolute(rt.io, path, .{ .exclusive = true });
    defer file.close(rt.io);
    try file.writeStreamingAll(rt.io, json);
}

pub fn acquireWorkerLock(rt: Runtime, allocator: std.mem.Allocator, index: u32) !?ProcessLock {
    const path = try paths.instanceLockPath(rt, allocator, index);
    defer allocator.free(path);
    var lock = (try tryAcquireProcessLock(rt, path)) orelse return null;
    errdefer lock.deinit(rt);
    // 새 PID를 lock 파일에 공개하기 전에 이전 endpoint 상태를 starting으로
    // 원자 교체한다. PID가 재사용돼도 stale ready를 관찰할 틈이 없다.
    try recordEndpointStateForPid(rt, allocator, index, currentProcessId(), .starting);
    try writeOwnerPid(rt, lock.file);
    lock.clear_pid_on_close = true;
    return lock;
}

pub fn acquireLauncherLock(rt: Runtime, allocator: std.mem.Allocator) !ProcessLock {
    const path = try paths.launcherLockPath(rt, allocator);
    defer allocator.free(path);
    const file = try std.Io.Dir.createFileAbsolute(rt.io, path, .{
        .truncate = false,
        .read = true,
        .lock = .exclusive,
    });
    var lock: ProcessLock = .{ .file = file, .clear_pid_on_close = false };
    errdefer lock.deinit(rt);
    try writeOwnerPid(rt, lock.file);
    lock.clear_pid_on_close = true;
    return lock;
}

pub fn isRunning(rt: Runtime, allocator: std.mem.Allocator, index: u32) !bool {
    const path = try paths.instanceLockPath(rt, allocator, index);
    defer allocator.free(path);
    return workerLockOwned(rt, path);
}

fn workerLockOwned(rt: Runtime, path: []const u8) !bool {
    var lock = (try tryAcquireProcessLock(rt, path)) orelse return true;
    // lock을 얻었다는 사실이 owner 부재를 증명한다. 이전 crash가 남긴 PID를
    // lock 아래에서 비워 다음 worker의 PID 기록을 startup acknowledgment로 쓴다.
    try lock.file.setLength(rt.io, 0);
    lock.deinit(rt);
    return false;
}

pub fn waitUntilRunning(rt: Runtime, allocator: std.mem.Allocator, index: u32, timeout_ns: u64) !void {
    const path = try paths.instanceLockPath(rt, allocator, index);
    defer allocator.free(path);
    var timer: runtime.Timer = .start(rt);
    while (timer.read() < timeout_ns) {
        // PID는 worker가 lock을 획득한 뒤 기록한다. 파일이 비어 있는 동안 lock을
        // probe하면 launcher가 worker보다 먼저 lock을 잡는 race가 생기므로 metadata만
        // 확인한다. PID가 쓰인 뒤 실제 생존 판정은 다시 advisory lock으로 검증한다.
        if (ownerPidWritten(rt, path) and try isRunning(rt, allocator, index)) return;
        rt.sleepNs(10 * std.time.ns_per_ms);
    }
    return error.WorkerStartTimeout;
}

pub fn recordEndpointState(rt: Runtime, allocator: std.mem.Allocator, index: u32, state: EndpointState) !void {
    try recordEndpointStateForPid(rt, allocator, index, currentProcessId(), state);
}

fn recordEndpointStateForPid(
    rt: Runtime,
    allocator: std.mem.Allocator,
    index: u32,
    pid: u32,
    state: EndpointState,
) !void {
    const path = try paths.instanceEndpointStatePath(rt, allocator, index);
    defer allocator.free(path);
    try writeEndpointSnapshot(rt, allocator, path, pid, state);
}

fn writeEndpointSnapshot(
    rt: Runtime,
    allocator: std.mem.Allocator,
    path: []const u8,
    pid: u32,
    state: EndpointState,
) !void {
    var buf: [64]u8 = undefined;
    const content = try std.fmt.bufPrint(&buf, "v1 {d} {s}\n", .{ pid, @tagName(state) });
    _ = try paths.writeFileIfChanged(rt, allocator, path, content);
}

/// 실제 worker 0 요청을 보내기 직전에만 사용한다. fixed retry 대신 worker가
/// 기록한 endpoint 상태를 기다리며, unavailable/종료는 timeout 전에 반환한다.
pub fn waitUntilEndpointReady(rt: Runtime, allocator: std.mem.Allocator, index: u32, timeout_ns: u64) !void {
    const lock_path = try paths.instanceLockPath(rt, allocator, index);
    defer allocator.free(lock_path);
    const endpoint_path = try paths.instanceEndpointStatePath(rt, allocator, index);
    defer allocator.free(endpoint_path);

    var probe = FileEndpointProbe{
        .rt = rt,
        .lock_path = lock_path,
        .endpoint_path = endpoint_path,
        .timer = .start(rt),
    };
    try waitUntilEndpointReadyWithProbe(&probe, timeout_ns);
}

const FileEndpointProbe = struct {
    rt: Runtime,
    lock_path: []const u8,
    endpoint_path: []const u8,
    timer: runtime.Timer,

    fn poll(self: *@This()) !EndpointProbeResult {
        return probeEndpointFiles(self.rt, self.lock_path, self.endpoint_path);
    }

    fn elapsedNs(self: *@This()) u64 {
        return self.timer.read();
    }

    fn sleep(self: *@This(), duration_ns: u64) void {
        self.rt.sleepNs(duration_ns);
    }
};

fn waitUntilEndpointReadyWithProbe(probe: anytype, timeout_ns: u64) !void {
    while (probe.elapsedNs() < timeout_ns) {
        switch (try probe.poll()) {
            .starting => {},
            .ready => return,
            .unavailable => return error.RequestEndpointUnavailable,
            .worker_exited => return error.WorkerExitedBeforeEndpointReady,
        }

        const elapsed = probe.elapsedNs();
        if (elapsed >= timeout_ns) break;
        probe.sleep(@min(endpoint_poll_interval_ns, timeout_ns - elapsed));
    }
    return error.RequestEndpointReadyTimeout;
}

fn probeEndpointFiles(rt: Runtime, lock_path: []const u8, endpoint_path: []const u8) !EndpointProbeResult {
    const snapshot = try readEndpointSnapshot(rt, endpoint_path);
    const owner_pid = try readOwnerPid(rt, lock_path);

    if (owner_pid == null) {
        // acquireWorkerLock은 lock을 가진 뒤 starting을 먼저 쓰고 PID를 쓴다.
        // 따라서 상태가 있으면 lock probe가 안전하며, free면 이미 종료한 것.
        if (snapshot != null) {
            return if (try workerLockOwned(rt, lock_path)) .starting else .worker_exited;
        }
        return .starting;
    }

    if (!try workerLockOwned(rt, lock_path)) return .worker_exited;

    // lock 생존 판정 사이에 owner가 바뀌지 않았는지 다시 확인한다.
    const confirmed_pid = (try readOwnerPid(rt, lock_path)) orelse return .worker_exited;
    if (!std.meta.eql(confirmed_pid, owner_pid.?)) return .starting;

    const current = snapshot orelse return .starting;
    if (!ownerMatchesSnapshot(confirmed_pid, current.pid)) return .starting;
    return switch (current.state) {
        .starting => .starting,
        .ready => .ready,
        .unavailable => .unavailable,
    };
}

const OwnerPid = union(enum) {
    versioned: u32,
    /// #304 수정 전 형식은 잠긴 byte 0부터 PID를 썼다. Windows launcher는
    /// 첫 byte를 읽을 수 없으므로 나머지 숫자를 endpoint PID와 대조한다.
    legacy_suffix: struct {
        value: u32,
        digits: u8,
    },
};

fn readOwnerPid(rt: Runtime, path: []const u8) !?OwnerPid {
    const file = std.Io.Dir.openFileAbsolute(rt.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(rt.io);
    // Zig의 Windows File.lock은 byte 0을 잠근다. PID는 그 다음 byte부터
    // 보관해 launcher의 별도 handle이 lock 보유 중에도 읽을 수 있게 한다.
    //
    // #451 — 예전엔 `seekTo(1)` + `readAll` 이었다. 0.16 의 `readPositionalAll` 은
    // offset 을 직접 받아 (`fs.File.preadAll` 자리) 파일 위치를 건드리지 않는다 —
    // 같은 handle 을 다른 곳에서 안 쓰더라도 seek 상태가 없는 쪽이 안전하다.
    var buf: [32]u8 = undefined;
    const n = try file.readPositionalAll(rt.io, &buf, 1);
    if (n == 0) return null;
    if (n == buf.len and try file.length(rt.io) > buf.len) return error.InvalidWorkerOwnerPid;
    const text = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (std.mem.startsWith(u8, text, "v1 ")) {
        const pid = std.fmt.parseInt(u32, text[3..], 10) catch return error.InvalidWorkerOwnerPid;
        if (pid == 0) return error.InvalidWorkerOwnerPid;
        return .{ .versioned = pid };
    }

    // 실행 중인 구버전 worker와의 migration 경로. byte 0의 첫 숫자는 lock에
    // 가려지므로 suffix만 보존하고 endpoint snapshot과 함께 검증한다.
    for (text) |c| if (!std.ascii.isDigit(c)) return error.InvalidWorkerOwnerPid;
    const suffix = if (text.len == 0) 0 else std.fmt.parseInt(u32, text, 10) catch return error.InvalidWorkerOwnerPid;
    return .{ .legacy_suffix = .{ .value = suffix, .digits = @intCast(text.len) } };
}

fn ownerMatchesSnapshot(owner: OwnerPid, snapshot_pid: u32) bool {
    return switch (owner) {
        .versioned => |pid| pid == snapshot_pid,
        .legacy_suffix => |suffix| blk: {
            var buf: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}", .{snapshot_pid}) catch break :blk false;
            if (text.len == 0 or text.len - 1 != suffix.digits) break :blk false;
            const value = if (text.len == 1)
                0
            else
                std.fmt.parseInt(u32, text[1..], 10) catch break :blk false;
            break :blk value == suffix.value;
        },
    };
}

fn readEndpointSnapshot(rt: Runtime, path: []const u8) !?EndpointSnapshot {
    const file = std.Io.Dir.openFileAbsolute(rt.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(rt.io);
    var buf: [64]u8 = undefined;
    const n = try file.readPositionalAll(rt.io, &buf, 0);
    if (n == buf.len and try file.length(rt.io) > buf.len) return error.InvalidEndpointState;
    return try parseEndpointSnapshot(buf[0..n]);
}

fn parseEndpointSnapshot(content: []const u8) !EndpointSnapshot {
    var fields = std.mem.tokenizeAny(u8, content, " \t\r\n");
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidEndpointState, "v1"))
        return error.InvalidEndpointState;
    const pid_text = fields.next() orelse return error.InvalidEndpointState;
    const pid = std.fmt.parseInt(u32, pid_text, 10) catch return error.InvalidEndpointState;
    if (pid == 0) return error.InvalidEndpointState;
    const state_text = fields.next() orelse return error.InvalidEndpointState;
    const state = std.meta.stringToEnum(EndpointState, state_text) orelse return error.InvalidEndpointState;
    if (fields.next() != null) return error.InvalidEndpointState;
    return .{ .pid = pid, .state = state };
}

fn ownerPidWritten(rt: Runtime, path: []const u8) bool {
    const file = std.Io.Dir.openFileAbsolute(rt.io, path, .{}) catch return false;
    defer file.close(rt.io);
    return (file.length(rt.io) catch return false) != 0;
}

fn tryAcquireProcessLock(rt: Runtime, path: []const u8) !?ProcessLock {
    const file = std.Io.Dir.createFileAbsolute(rt.io, path, .{
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

fn writeOwnerPid(rt: Runtime, file: std.Io.File) !void {
    var buf: [36]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "\nv1 {d}\n", .{currentProcessId()});
    try file.setLength(rt.io, 0);
    // #451 — `seekTo(0)` + `writeAll` 을 offset 0 의 positional write 로 대체한다
    // (`fs.File.pwriteAll` 자리). 파일 위치를 남기지 않아 lock 을 공유하는 다른
    // handle 의 읽기와 간섭하지 않는다.
    try file.writePositionalAll(rt.io, text, 0);
}

fn currentProcessId() u32 {
    return switch (@import("builtin").os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
}

pub fn spawnWorker(rt: Runtime, allocator: std.mem.Allocator, index: u32) !void {
    // #451 — `fs.selfExePath` ➡️ `std.process.executablePath` (길이를 돌려준다) ·
    // `process.Child.init` + `spawn` ➡️ `std.process.spawn(io, options)` (릴리즈 노트
    // *Process* 절). 기본 stdio 는 예전 `Child.init` 과 같은 상속이라 따로 안 적는다.
    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_len = try std.process.executablePath(rt.io, &exe_buf);
    const exe = exe_buf[0..exe_len];
    const index_text = try std.fmt.allocPrint(allocator, "{d}", .{index});
    defer allocator.free(index_text);
    // 자식을 기다리지 않는다 — worker 는 독립 프로세스이고, launcher 는 lock 파일로
    // 기동을 확인한 뒤 (`waitUntilRunning`) 곧 끝난다. 예전 `Child.init` + `spawn` 도
    // 같았다 (`wait` 를 부르지 않았다).
    _ = try std.process.spawn(rt.io, .{ .argv = &.{ exe, "--instance", index_text } });
}

pub fn defaultShell(rt: Runtime, allocator: std.mem.Allocator) ![]u8 {
    if (@import("builtin").os.tag != .windows) {
        if (rt.envAlloc(allocator, "SHELL") catch null) |shell| return shell;
    }
    return allocator.dupe(u8, config.Defaults.shell);
}

pub fn configAutoStart(rt: Runtime, allocator: std.mem.Allocator, index: u32) !bool {
    const path = try paths.configPathFor(rt, allocator, index);
    defer allocator.free(path);
    const file = try std.Io.Dir.openFileAbsolute(rt.io, path, .{});
    defer file.close(rt.io);
    // #451 — `fs.File.readToEndAlloc` ➡️ `File.Reader.allocRemaining` (릴리즈 노트 전용 절).
    var file_reader = file.reader(rt.io, &.{});
    const content = try file_reader.interface.allocRemaining(allocator, .limited(64 * 1024));
    defer allocator.free(content);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidConfig;
    const value = parsed.value.object.get("auto_start") orelse return error.InvalidConfig;
    if (value != .bool) return error.InvalidConfig;
    return value.bool;
}

pub fn configHotkeyText(rt: Runtime, allocator: std.mem.Allocator, index: u32) ![]u8 {
    const path = try paths.configPathFor(rt, allocator, index);
    defer allocator.free(path);
    const file = try std.Io.Dir.openFileAbsolute(rt.io, path, .{});
    defer file.close(rt.io);
    // #451 — `fs.File.readToEndAlloc` ➡️ `File.Reader.allocRemaining` (릴리즈 노트 전용 절).
    var file_reader = file.reader(rt.io, &.{});
    const content = try file_reader.interface.allocRemaining(allocator, .limited(64 * 1024));
    defer allocator.free(content);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidConfig;
    const value = parsed.value.object.get("hotkey") orelse return error.InvalidConfig;
    if (value != .string) return error.InvalidConfig;
    return allocator.dupe(u8, value.string);
}

pub fn hotkeyOwner(rt: Runtime, allocator: std.mem.Allocator, indices: []const u32, candidate: config.Hotkey) !?u32 {
    for (indices) |index| {
        const path = try paths.configPathFor(rt, allocator, index);
        defer allocator.free(path);
        const file = try std.Io.Dir.openFileAbsolute(rt.io, path, .{});
        defer file.close(rt.io);
        var file_reader = file.reader(rt.io, &.{});
        const content = try file_reader.interface.allocRemaining(allocator, .limited(64 * 1024));
        defer allocator.free(content);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidConfig;
        const value = parsed.value.object.get("hotkey") orelse return error.InvalidConfig;
        if (value != .string) return error.InvalidConfig;
        const existing = config.Hotkey.fromString(value.string) orelse return error.InvalidConfig;
        if (std.meta.eql(existing, candidate)) return index;
    }
    return null;
}

/// 기동 시 핫키 중복 판정에 쓰는 한 인스턴스의 상태. `hotkey` 가 `null` 이면 그 config 를
/// 읽거나 파싱하지 못했다는 뜻이다.
pub const HotkeyEntry = struct { index: u32, hotkey: ?config.Hotkey };

/// **뒤에 있는 것이 양보한다** ([#431](https://github.com/ensky0/tildaz/issues/431)) —
/// `self_index` 보다 **낮은** index 중 같은 핫키를 쓰는 가장 작은 index 를 돌려준다.
///
/// 이 방향이 필요한 이유: 겹친 두 인스턴스는 *양쪽 다* 중복을 감지한다. 규칙 없이 둘 다
/// 멈추면 사용자는 아무 인스턴스도 못 쓴다. 낮은 쪽을 살려 두면 항상 정확히 한 쪽만 멈춘다.
///
/// `hotkey == null` 인 항목은 건너뛴다 — *남의* config 가 깨져서 내가 못 뜨는 일을 만들지
/// 않는다. 같은 파일을 읽는 `hotkeyOwner` 가 `error.InvalidConfig` 를 전파하는 것과 정책이
/// 반대인데, 그쪽은 사용자가 키를 **고르는 중**이라 "검사하지 못했다" 를 알려야 해서다
/// (`dialog.HotkeyValidation.check_failed`).
///
/// I/O 가 없어 단위 테스트가 그대로 태울 수 있다 — 디스크를 읽는 부분은
/// `lowerIndexHotkeyConflict` 가 맡는다.
pub fn conflictingLowerIndex(entries: []const HotkeyEntry, self_index: u32, candidate: config.Hotkey) ?u32 {
    var winner: ?u32 = null;
    for (entries) |entry| {
        if (entry.index >= self_index) continue;
        const existing = entry.hotkey orelse continue;
        if (!std.meta.eql(existing, candidate)) continue;
        if (winner == null or entry.index < winner.?) winner = entry.index;
    }
    return winner;
}

/// 디스크의 다른 config 를 읽어 `conflictingLowerIndex` 에 넘긴다. 목록 자체를 못 얻거나
/// 메모리가 없으면 `null` — **검사를 못 했다고 기동을 막지는 않는다** (전역 핫키 등록 실패는
/// 그 뒤 단계에서 여전히 잡힌다).
pub fn lowerIndexHotkeyConflict(rt: Runtime, allocator: std.mem.Allocator, self_index: u32, candidate: config.Hotkey) ?u32 {
    const indices = listConfigIndices(rt, allocator) catch return null;
    defer allocator.free(indices);

    const entries = allocator.alloc(HotkeyEntry, indices.len) catch return null;
    defer allocator.free(entries);
    for (indices, 0..) |index, i| {
        const parsed: ?config.Hotkey = blk: {
            const text = configHotkeyText(rt, allocator, index) catch break :blk null;
            defer allocator.free(text);
            break :blk config.Hotkey.fromString(text);
        };
        entries[i] = .{ .index = index, .hotkey = parsed };
    }
    return conflictingLowerIndex(entries, self_index, candidate);
}

test "핫키 중복은 뒤에 있는 인스턴스가 양보한다 (#431)" {
    const f1 = config.Hotkey.fromString("F1").?;
    const f2 = config.Hotkey.fromString("F2").?;
    const entries = [_]HotkeyEntry{
        .{ .index = 0, .hotkey = f1 },
        .{ .index = 3, .hotkey = f1 },
        .{ .index = 5, .hotkey = f2 },
        .{ .index = 7, .hotkey = null }, // 읽기·파싱 실패 — 건너뛴다
        .{ .index = 9, .hotkey = f1 },
    };

    // 낮은 index 가 이미 쓰고 있으면 그 index. 여럿이면 가장 작은 것.
    try std.testing.expectEqual(@as(?u32, 0), conflictingLowerIndex(&entries, 9, f1));
    try std.testing.expectEqual(@as(?u32, 0), conflictingLowerIndex(&entries, 3, f1));

    // 자기보다 높은 index 는 보지 않는다 — 양보는 뒤에 있는 쪽 몫이다.
    try std.testing.expectEqual(@as(?u32, null), conflictingLowerIndex(&entries, 0, f1));
    try std.testing.expectEqual(@as(?u32, null), conflictingLowerIndex(&entries, 5, f2));

    // 같은 index (자기 자신) 도 충돌이 아니다.
    try std.testing.expectEqual(@as(?u32, null), conflictingLowerIndex(entries[0..1], 0, f1));

    // 겹치는 키가 없으면 null.
    try std.testing.expectEqual(@as(?u32, null), conflictingLowerIndex(&entries, 9, config.Hotkey.fromString("F4").?));

    // hotkey == null 인 항목은 어떤 후보와도 안 겹친다.
    const only_null = [_]HotkeyEntry{.{ .index = 1, .hotkey = null }};
    try std.testing.expectEqual(@as(?u32, null), conflictingLowerIndex(&only_null, 2, f1));
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

/// #451 — 테스트는 `std.testing.io` 를 쓰고 환경변수는 안 본다 (여기 함수들은 경로를
/// 인자로 받는다). `paths.zig` 처럼 합성 환경변수가 필요한 경우가 아니라 `.empty` 로 족하다.
fn testRuntime() Runtime {
    return .{ .io = std.testing.io, .environ = .empty };
}

test "process lock records pid and excludes a second owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const rt = testRuntime();
    const root = try tmp.dir.realPathFileAlloc(rt.io, ".", allocator);
    defer allocator.free(root);
    const path = try std.Io.Dir.path.join(allocator, &.{ root, "instance7.lock" });
    defer allocator.free(path);

    {
        var first = (try tryAcquireProcessLock(rt, path)).?;
        defer first.deinit(rt);
        try writeOwnerPid(rt, first.file);
        first.clear_pid_on_close = true;

        const owner = (try readOwnerPid(rt, path)).?;
        switch (owner) {
            .versioned => |pid| try std.testing.expectEqual(currentProcessId(), pid),
            .legacy_suffix => return error.TestUnexpectedResult,
        }
        try std.testing.expect((try tryAcquireProcessLock(rt, path)) == null);
    }
    var next = (try tryAcquireProcessLock(rt, path)).?;
    next.deinit(rt);
}

test "endpoint state parser requires version pid and known state" {
    try std.testing.expectEqualDeep(
        EndpointSnapshot{ .pid = 42, .state = .ready },
        try parseEndpointSnapshot("v1 42 ready\n"),
    );
    try std.testing.expectError(error.InvalidEndpointState, parseEndpointSnapshot("42 ready\n"));
    try std.testing.expectError(error.InvalidEndpointState, parseEndpointSnapshot("v1 0 ready\n"));
    try std.testing.expectError(error.InvalidEndpointState, parseEndpointSnapshot("v1 42 unknown\n"));
    try std.testing.expectError(error.InvalidEndpointState, parseEndpointSnapshot("v1 42 ready extra\n"));
}

test "endpoint probe requires live lock and matching owner pid" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const rt = testRuntime();
    const root = try tmp.dir.realPathFileAlloc(rt.io, ".", allocator);
    defer allocator.free(root);
    const lock_path = try std.Io.Dir.path.join(allocator, &.{ root, "instance0.lock" });
    defer allocator.free(lock_path);
    const endpoint_path = try std.Io.Dir.path.join(allocator, &.{ root, "instance0.endpoint" });
    defer allocator.free(endpoint_path);

    const pid = currentProcessId();
    const other_pid = if (pid == std.math.maxInt(u32)) pid - 1 else pid + 1;
    {
        var worker_lock = (try tryAcquireProcessLock(rt, lock_path)).?;
        defer worker_lock.deinit(rt);

        // acquireWorkerLock의 실제 순서: lock 아래 starting이 owner PID보다 먼저다.
        try writeEndpointSnapshot(rt, allocator, endpoint_path, pid, .starting);
        try std.testing.expectEqual(
            EndpointProbeResult.starting,
            try probeEndpointFiles(rt, lock_path, endpoint_path),
        );

        // 수정 전 worker가 byte 0부터 쓴 PID도 endpoint의 전체 PID와 suffix를
        // 대조해 업그레이드 중인 launcher가 ready 상태를 계속 읽을 수 있다.
        var legacy_buf: [32]u8 = undefined;
        const legacy_text = try std.fmt.bufPrint(&legacy_buf, "{d}\n", .{pid});
        try worker_lock.file.setLength(rt.io, 0);
        try worker_lock.file.writePositionalAll(rt.io, legacy_text, 0);
        try writeEndpointSnapshot(rt, allocator, endpoint_path, pid, .ready);
        try std.testing.expectEqual(
            EndpointProbeResult.ready,
            try probeEndpointFiles(rt, lock_path, endpoint_path),
        );

        try writeOwnerPid(rt, worker_lock.file);
        worker_lock.clear_pid_on_close = true;
        try writeEndpointSnapshot(rt, allocator, endpoint_path, other_pid, .ready);
        try std.testing.expectEqual(
            EndpointProbeResult.starting,
            try probeEndpointFiles(rt, lock_path, endpoint_path),
        );

        try writeEndpointSnapshot(rt, allocator, endpoint_path, pid, .ready);
        try std.testing.expectEqual(
            EndpointProbeResult.ready,
            try probeEndpointFiles(rt, lock_path, endpoint_path),
        );

        try writeEndpointSnapshot(rt, allocator, endpoint_path, pid, .unavailable);
        try std.testing.expectEqual(
            EndpointProbeResult.unavailable,
            try probeEndpointFiles(rt, lock_path, endpoint_path),
        );
    }

    // clean exit 뒤 남은 endpoint 파일은 같은 PID여도 ready로 인정하지 않는다.
    try std.testing.expectEqual(
        EndpointProbeResult.worker_exited,
        try probeEndpointFiles(rt, lock_path, endpoint_path),
    );
}

const FakeEndpointProbe = struct {
    results: []const EndpointProbeResult,
    next_result: usize = 0,
    elapsed_ns: u64 = 0,

    fn poll(self: *@This()) !EndpointProbeResult {
        const index = @min(self.next_result, self.results.len - 1);
        self.next_result += 1;
        return self.results[index];
    }

    fn elapsedNs(self: *@This()) u64 {
        return self.elapsed_ns;
    }

    fn sleep(self: *@This(), duration_ns: u64) void {
        self.elapsed_ns += duration_ns;
    }
};

test "endpoint ready wait succeeds after more than fixed 200ms" {
    const starting = [_]EndpointProbeResult{.starting} ** 22;
    const results = starting ++ .{.ready};
    var probe = FakeEndpointProbe{ .results = &results };
    try waitUntilEndpointReadyWithProbe(&probe, std.time.ns_per_s);
    try std.testing.expect(probe.elapsed_ns > 200 * std.time.ns_per_ms);
}

test "endpoint ready wait reports unavailable without waiting for timeout" {
    const results = [_]EndpointProbeResult{.unavailable};
    var probe = FakeEndpointProbe{ .results = &results };
    try std.testing.expectError(
        error.RequestEndpointUnavailable,
        waitUntilEndpointReadyWithProbe(&probe, std.time.ns_per_s),
    );
    try std.testing.expectEqual(@as(u64, 0), probe.elapsed_ns);
}

test "endpoint ready wait reports worker exit without waiting for timeout" {
    const results = [_]EndpointProbeResult{ .starting, .worker_exited };
    var probe = FakeEndpointProbe{ .results = &results };
    try std.testing.expectError(
        error.WorkerExitedBeforeEndpointReady,
        waitUntilEndpointReadyWithProbe(&probe, std.time.ns_per_s),
    );
    try std.testing.expectEqual(endpoint_poll_interval_ns, probe.elapsed_ns);
}

test "endpoint ready wait has a finite timeout" {
    const results = [_]EndpointProbeResult{.starting};
    var probe = FakeEndpointProbe{ .results = &results };
    const timeout_ns = 25 * std.time.ns_per_ms;
    try std.testing.expectError(
        error.RequestEndpointReadyTimeout,
        waitUntilEndpointReadyWithProbe(&probe, timeout_ns),
    );
    try std.testing.expectEqual(timeout_ns, probe.elapsed_ns);
}
