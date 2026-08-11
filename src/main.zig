const std = @import("std");
const builtin = @import("builtin");
const host = switch (builtin.os.tag) {
    .windows => @import("host/windows.zig"),
    .macos => @import("host/macos.zig"),
    .linux => @import("host/linux_wayland.zig"),
    else => @import("host/unsupported.zig"),
};
const autostart = @import("autostart.zig");
const config = @import("config.zig");
const console = @import("console.zig");
const instance_context = @import("instance_context.zig");
const instance_request = @import("instance_request.zig");
const instances = @import("instances.zig");
const messages = @import("messages.zig");
const run_options = @import("run_options.zig");
const runtime = @import("runtime.zig");
const shortcut_sync = @import("shortcut_sync.zig");
const version = @import("version.zig");

/// `std.log` 호출 (ghostty-vt 의 `unimplemented mode` 등) 을 우리 통합 로그로
/// redirect — stdout/stderr 안 찍힘. macOS 는 `~/Library/Logs/tildaz_N.log`,
/// Windows 는 `%APPDATA%\tildaz\tildaz_N.log` 의 `[std.log:<scope>]` category.
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

/// #383 — 인자 오류는 셋 다 stderr + `exit(2)` 이고, 다음 행동 (`--help`) 을 같이
/// 안내한다. 종료 코드 2 는 기존 동작 그대로다 (bash 의 "잘못된 사용법" 관례).
fn exitUnknownOption(arg: []const u8) noreturn {
    printOptionError(messages.unknown_option_format, .{arg});
}

fn exitOptionNeedsValue(option: []const u8) noreturn {
    printOptionError(messages.option_needs_value_format, .{option});
}

fn exitInvalidValue(option: []const u8, value: []const u8) noreturn {
    printOptionError(messages.option_invalid_value_format, .{ value, option });
}

fn printOptionError(comptime fmt: []const u8, args: anytype) noreturn {
    // 인자는 사용자가 준 문자열이라 길이 상한이 없다. 버퍼를 넘기면 (예: 아주 긴 경로를
    // 옵션 자리에 넣은 경우) 값을 뺀 일반 안내로 떨어뜨린다 — 안내가 사라지는 것보다 낫다.
    var buf: [1024]u8 = undefined;
    console.errLine(std.fmt.bufPrint(&buf, fmt, args) catch messages.option_error_fallback_msg);
    std.process.exit(2);
}

/// Zig 0.16 은 `main` 의 첫 인자로 `std.process.Init` 을 넘긴다 (#451). 그 안에 런타임이
/// 준비한 `io` · argv (`minimal.args`) · `arena` · `gpa` · `environ_map` 이 들어 있고,
/// `std.process.argsAlloc` 은 없어졌다.
pub fn main(init: std.process.Init) void {
    // **첫 줄이어야 한다.** 전역 로거의 mutex 가 `Io` 를 받아야 하고 (`log.zig` 의
    // `g_path_mutex`), 경로 계산이 환경변수를 읽는다 (`paths.zig`). 그 전 구간은 "아직
    // 스레드가 없다" 는 전제로 잠금을 건너뛴다 (`runtime.zig` 참고).
    runtime.install(init);
    // arena 는 process lifetime 이라 (`std.process.Init` 주석) 따로 해제하지 않는다 —
    // 이전 `argsFree` 가 하던 일이 없어진다.
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch std.process.exit(2);
    var worker_index: ?u32 = null;
    var autostart_launch = false;
    var toggle_index: ?u32 = null;
    // #382 — 측정용 내부 옵션. 문서화하지 않는다 (`run_options.zig` 참고).
    var run_opts: run_options.RunOptions = .{};

    // #383 — `--version` / `--help` 는 다른 인자보다 **먼저** 본다. 두 가지 이유다.
    //
    //  1. 창 · 전역 핫키 · worker lock 어느 것도 건드리지 않고 끝나야 한다. 버전만
    //     보려는데 핫키가 등록되거나 lock 을 잡으면 평소 쓰는 인스턴스를 방해한다.
    //  2. `tildaz --instance 1 --help` 처럼 다른 옵션과 섞여 와도 사용자의 의도는
    //     "설명을 보여 달라" 이다. 위치와 무관하게 이긴다.
    //
    // 둘 다 있으면 `--help` 가 이긴다 — 옵션 목록 쪽이 더 많은 것을 알려 준다.
    var show_help = false;
    var show_version = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) show_help = true;
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) show_version = true;
    }
    if (show_help) {
        console.outLine(messages.help_text);
        std.process.exit(0);
    }
    if (show_version) {
        var buf: [256]u8 = undefined;
        // 버전 문자열은 `version.string` 하나에서 온다 — About 다이얼로그 · 로그의
        // `[boot]` 줄과 같은 값이라야 사용자가 어디서 읽어 오든 같은 것을 말한다.
        const line = std.fmt.bufPrint(&buf, messages.version_line_format, .{version.string}) catch
            version.string;
        console.outLine(line);
        std.process.exit(0);
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--instance")) {
            if (i + 1 >= args.len) exitOptionNeedsValue(arg);
            i += 1;
            worker_index = std.fmt.parseInt(u32, args[i], 10) catch exitInvalidValue(arg, args[i]);
        } else if (std.mem.eql(u8, arg, "-e")) {
            if (i + 1 >= args.len) exitOptionNeedsValue(arg);
            i += 1;
            run_opts.command = args[i];
        } else if (std.mem.eql(u8, arg, "-size")) {
            if (i + 1 >= args.len) exitOptionNeedsValue(arg);
            i += 1;
            run_opts.grid = run_options.parseGrid(args[i]) orelse exitInvalidValue(arg, args[i]);
        } else if (std.mem.eql(u8, arg, "-scrollback")) {
            if (i + 1 >= args.len) exitOptionNeedsValue(arg);
            i += 1;
            run_opts.scrollback = std.fmt.parseInt(usize, args[i], 10) catch exitInvalidValue(arg, args[i]);
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
        } else if (builtin.os.tag == .macos and std.mem.startsWith(u8, arg, "-psn_")) {
            // macOS LaunchServices 가 앱을 띄우며 붙일 수 있는 process serial number.
            // 우리가 준 인자가 아니라서 아래 unknown 처리에 걸리면 `open TildaZ.app` 이
            // 통째로 실패한다. Qt (`QCoreApplication`) · Chromium 도 같은 접두사로
            // 걸러 낸다. 값은 쓰지 않고 버린다.
        } else {
            // #383 이전에는 여기가 없어서 **모르는 인자가 조용히 무시**됐다. `tildaz
            // --versoin` 같은 오타가 아무 말 없이 평소처럼 창을 띄워서, 사용자가 뭘
            // 잘못 쳤는지 알 방법이 없었다.
            exitUnknownOption(arg);
        }
    }

    // #198 — Linux native hotkey IPC. `tildaz --toggle N` 명령은
    // worker N의 Unix domain socket으로 toggle 신호 송신 + 즉시 exit. 사용자가
    // 자기 DE 의 keyboard shortcut 설정에서 이 명령에 단축키 binding —
    // desktop/compositor binding에서 worker의 hotkey toggle을 전달한다.
    if (toggle_index) |index| {
        if (builtin.os.tag == .linux) {
            instance_context.setWorkerIndex(index);
            const si = @import("host/linux/single_instance.zig");
            // 결과를 tildaz_N.log 에도 남긴다 — `tildaz --toggle N` 은 별 process 라
            // stderr 가 compositor 저널로 가 진단이 어렵다 (#230). 매 hotkey 마다
            // 기존 인스턴스에 닿았는지(sent) / 없는지(NoRunningInstance) 기록.
            si.sendToggle(index) catch |err| {
                @import("log.zig").appendLine("toggle-ipc", "--toggle send failed: {s} (no running instance / socket problem)", .{@errorName(err)});
                std.process.exit(1);
            };
            @import("log.zig").appendLine("toggle-ipc", "--toggle sent to running instance", .{});
            std.process.exit(0);
        } else {
            // #383 — `std.debug.print` 는 Windows GUI subsystem 에서 아무 데도 나가지
            // 않는다. 다른 CLI 출력과 같은 경로 (`console.zig`) 로 보내 부모 콘솔에
            // 붙어서 찍는다.
            console.errLine(messages.toggle_unsupported_msg);
            std.process.exit(2);
        }
    }

    // #382 — 측정 모드. worker lock · launcher · 전역 핫키를 모두 건너뛴다. 그러지 않으면
    // 평소 쓰는 TildaZ 의 lock 을 뺏거나 F1 이 두 프로세스에 걸린다. 창 크기는 `-size` 가
    // 덮는다.
    //
    // config 는 worker 와 **공유한다** — 같은 폰트 · 테마로 재야 다른 터미널과의 비교가
    // 성립한다. 단 파일이 없으면 만들지 않는다 (`config.zig` 의 `Config.load`): 측정이
    // 사용자 설정을 만드는 주체가 되면 안 된다.
    //
    // index 는 그대로 쓰지만 **역할은 다르다** (`instance_context.Role`). 창 타이틀 ·
    // app_id · 로그 파일 같은 이름은 그 역할에서 갈린다 — index 에서 파생하면 worker 를
    // 찾는 쪽이 측정 창을 집는다.
    if (run_opts.isStressRun()) {
        instance_context.setRole(.stress);
        instance_context.setWorkerIndex(worker_index orelse 0);
        host.run(run_opts) catch |err| host.showFatalRunError(err);
        return;
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
        host.run(run_opts) catch |err| host.showFatalRunError(err);
        return;
    }

    runLauncher(autostart_launch) catch |err| host.showFatalRunError(err);
}

fn runLauncher(autostart_launch: bool) !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // #301 — Windows plain-launch burst는 blocking launcher_lock보다 먼저 대표
    // 하나를 선출한다. 대표가 동기 새-instance 처리를 끝낼 때까지 gate를 보유.
    // autostart는 prompt 요청이 아니므로 기존 launcher_lock 직렬화만 사용한다.
    var request_gate: ?instance_request.RequestGate = null;
    if (!autostart_launch) {
        request_gate = try instance_request.tryAcquireGate();
        if (request_gate == null) return;
    }
    defer if (request_gate) |*gate| gate.deinit();

    // Windows 동기 request는 이 block 밖에서 전송해 launcher_lock을 먼저 푼다.
    // Linux/macOS의 기존 비동기 adapter는 lock 안에서 보내 기존 순서를 유지한다.
    const send_after_unlock = launcher: {
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
            try instances.createDefaultConfig(allocator, 0, shell, config.Defaults.hotkey);
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
        if (spawned or autostart_launch) break :launcher false;

        // config index별 TildaZ worker가 모두 실행 중일 때만 worker 0에 새 instance
        // 요청을 보낸다. 하나라도 빠졌다면 위 loop가 누락 worker를 전부 시작했다.
        if (comptime builtin.os.tag == .windows) break :launcher true;
        try requestNewInstance(allocator);
        break :launcher false;
    };

    if (send_after_unlock) {
        try requestNewInstance(allocator);
        // WndProc가 반환한 바로 이 지점이 burst 병합의 끝 경계. 이후 시작된
        // launcher는 즉시 다음 요청의 gate를 얻을 수 있게 성공 path에서 해제한다.
        if (request_gate) |*gate| gate.deinit();
        request_gate = null;
    }
}

fn requestNewInstance(allocator: std.mem.Allocator) !void {
    // #304 — lock+PID는 process 생존만 뜻한다. 실제 endpoint와 UI event loop가
    // 준비됐다는 같은 PID의 ready 상태를 확인한 뒤 한 번만 전송한다.
    try instances.waitUntilEndpointReady(allocator, 0, 10 * std.time.ns_per_s);
    try instance_request.send();
}
