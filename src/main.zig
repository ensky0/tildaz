const std = @import("std");
const builtin = @import("builtin");
const host = switch (builtin.os.tag) {
    .windows => @import("host/windows.zig"),
    .macos => @import("host/macos.zig"),
    .linux => @import("host/linux_wayland.zig"),
    else => @import("host/unsupported.zig"),
};
const autostart = @import("autostart.zig");
const instance_context = @import("instance_context.zig");
const instances = @import("instances.zig");
const shortcut_sync = @import("shortcut_sync.zig");

/// `std.log` 호출 (ghostty-vt 의 `unimplemented mode` 등) 을 우리 통합 로그로
/// redirect — stdout/stderr 안 찍힘. macOS 는 `~/Library/Logs/tildazN.log`,
/// Windows 는 `%APPDATA%\tildaz\tildazN.log` 의 `[std.log:<scope>]` category.
pub const std_options: std.Options = .{
    .logFn = tildazLogFn,
    .log_level = .warn,
};

fn tildazLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    // ghostty-vt 의 noise 무시 — 새 탭 / shell prompt 마다 매번 찍혀 로그 오염.
    // `unimplemented mode` 류는 xterm DECSET 중 ghostty 가 안 구현한 것들 (예:
    // 1034 = 8th-bit input, bash readline 시작 시 보냄). terminal 기능에 영향 없음.
    if (comptime std.mem.indexOf(u8, fmt, "unimplemented mode") != null) return;

    const cat = "std.log:" ++ @tagName(scope) ++ "/" ++ @tagName(level);
    @import("log.zig").appendLine(cat, fmt, args);
}

/// ReleaseFast에서도 crash 원인을 표시하는 panic handler
pub fn panic(msg: []const u8, st: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    const addr = ret_addr orelse @returnAddress();
    host.showPanic(msg, addr, st);
}

pub fn main() void {
    const args = std.process.argsAlloc(std.heap.page_allocator) catch std.process.exit(2);
    defer std.process.argsFree(std.heap.page_allocator, args);
    var worker_index: ?u32 = null;
    var autostart_launch = false;
    var toggle_index: ?u32 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--instance")) {
            if (i + 1 >= args.len) std.process.exit(2);
            i += 1;
            worker_index = std.fmt.parseInt(u32, args[i], 10) catch std.process.exit(2);
        } else if (std.mem.eql(u8, arg, "--autostart")) {
            autostart_launch = true;
        } else if (std.mem.eql(u8, arg, "--toggle")) {
            toggle_index = 0;
            if (i + 1 < args.len) {
                if (std.fmt.parseInt(u32, args[i + 1], 10)) |index| {
                    toggle_index = index;
                    i += 1;
                } else |_| {}
            }
        }
    }

    // #198 — Linux portal-less hotkey support. `tildaz --toggle` 명령은 첫
    // 인스턴스의 Unix domain socket 으로 toggle 신호 송신 + 즉시 exit. 사용자가
    // 자기 DE 의 keyboard shortcut 설정에서 이 명령에 단축키 binding —
    // GlobalShortcuts portal 안 advertise 하는 환경 (Cinnamon / mutter /
    // wlroots) 에서도 hotkey toggle 가능.
    if (builtin.os.tag == .linux) {
        if (toggle_index) |index| {
            instance_context.setWorkerIndex(index);
            const si = @import("host/linux/single_instance.zig");
            // 결과를 tildazN.log 에도 남긴다 — `tildaz --toggle N` 은 별 process 라
            // stderr 가 compositor 저널로 가 진단이 어렵다 (#230). 매 hotkey 마다
            // 기존 인스턴스에 닿았는지(sent) / 없는지(NoRunningInstance) 기록.
            si.sendToggle(index) catch |err| {
                @import("log.zig").appendLine("toggle-ipc", "--toggle send failed: {s} (no running instance / socket problem)", .{@errorName(err)});
                std.process.exit(1);
            };
            @import("log.zig").appendLine("toggle-ipc", "--toggle sent to running instance", .{});
            std.process.exit(0);
        }
    }

    if (worker_index) |index| {
        instance_context.setWorkerIndex(index);
        var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
        defer _ = gpa.deinit();
        var worker_lock = (instances.acquireWorkerLock(gpa.allocator(), index) catch |err| {
            host.showFatalRunError(err);
            return;
        }) orelse return;
        defer worker_lock.deinit();
        host.run() catch |err| host.showFatalRunError(err);
        return;
    }

    runLauncher(autostart_launch) catch |err| host.showFatalRunError(err);
}

fn runLauncher(autostart_launch: bool) !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // config discovery와 spawn/dialog 결정을 직렬화한다. spawn한 모든 worker가
    // index lock을 소유할 때까지 기다린 뒤 launcher lock을 풀어, 다음 launcher가
    // 중간 상태를 관찰하지 못하게 한다.
    var launcher_lock = try instances.acquireLauncherLock(allocator);
    defer launcher_lock.deinit();

    var indices = try instances.listConfigIndices(allocator);
    defer allocator.free(indices);
    if (indices.len == 0 or indices[0] != 0) {
        const shell = try instances.defaultShell(allocator);
        defer allocator.free(shell);
        try instances.createDefaultConfig(allocator, 0, shell, "f1");
        const expanded = try allocator.alloc(u32, indices.len + 1);
        expanded[0] = 0;
        @memcpy(expanded[1..], indices);
        allocator.free(indices);
        indices = expanded;
    }

    var any_auto_start = false;
    for (indices) |index| {
        if (try instances.configAutoStart(allocator, index)) any_auto_start = true;
    }
    if (!autostart_launch) {
        if (any_auto_start) try autostart.enable(allocator) else autostart.disable(allocator);
    }

    try shortcut_sync.sync(allocator, indices);

    var spawned = false;
    for (indices) |index| {
        if (autostart_launch and !try instances.configAutoStart(allocator, index)) continue;
        if (!try instances.isRunning(allocator, index)) {
            try instances.spawnWorker(allocator, index);
            try instances.waitUntilRunning(allocator, index, 10 * std.time.ns_per_s);
            spawned = true;
        }
    }
    if (spawned or autostart_launch) return;

    // config index별 TildaZ worker가 모두 실행 중일 때만 worker 0에 새 instance
    // 요청을 보낸다. 하나라도 빠졌다면 위 loop가 누락 worker를 전부 시작했고
    // spawned=true로 이미 반환했다.
    try requestNewInstance();
}

fn requestNewInstance() !void {
    try @import("instance_request.zig").send();
}
