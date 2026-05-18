const std = @import("std");
const build_options = @import("build_options");
const log = @import("../log.zig");
const messages = @import("../messages.zig");
const terminal = @import("../terminal.zig");
const config_mod = @import("../config.zig");
const wayland = @import("linux/wayland_minimal.zig");

/// L13-α — 사용자 설정. macOS `g_config` 패턴 동등. `run()` 안에서 한 번
/// load 되고 wayland client 가 module 경계로 가져다 쓴다.
var g_config: ?config_mod.Config = null;

/// `$SHELL` env 우선, 없으면 `Defaults.shell` (= "/bin/bash"). POSIX 패턴 —
/// macOS host 의 `resolveShell` 과 동등.
fn resolveShell(allocator: std.mem.Allocator) []const u8 {
    if (std.process.getEnvVarOwned(allocator, "SHELL") catch null) |s| return s;
    return config_mod.Defaults.shell;
}

/// wayland_minimal 이 `runBaselineWindow` 진입 시 module global 에서 꺼내
/// 쓰는 진입점. `run()` 이 먼저 load 한 뒤에만 valid.
pub fn config() *const config_mod.Config {
    return &g_config.?;
}

pub fn showPanic(msg: []const u8, addr: usize, _: ?*std.builtin.StackTrace) noreturn {
    log.appendLine("panic", "{s}  return_addr=0x{x}", .{ msg, addr });
    // zig default panic — stderr 에 자동으로 file:line + backtrace dump.
    // 시연 시 `./zig-out/bin/tildaz 2>&1 | tee /tmp/run.log` 처럼 stderr 도
    // 캡처해야 보임. 우리 log file 에는 ret_addr 만 남기고 자세한 stack 은
    // stderr 캡처에 위임 — symbolicate 직접 구현 (SelfInfo / Module getSymbolAtAddress)
    // 보다 default 가 maintenance-light.
    std.debug.defaultPanic(msg, addr);
}

pub fn showFatalRunError(err: anyerror) void {
    log.appendLine("fatal", "run failed: {s}", .{@errorName(err)});
    switch (err) {
        error.LinuxWaylandBackendNotImplemented => {
            std.debug.print("{s}\n", .{messages.linux_backend_not_ready_msg});
        },
        // Wayland socket 실패는 `Client.init` 안에서 path / env 까지 포함한
        // 정확한 메시지를 이미 stderr + log 양쪽에 남긴다. 여기서 generic
        // `run_failed_format` 을 다시 찍으면 진단 정보를 가리는 노이즈.
        error.WaylandSocketUnavailable => {},
        else => {
            std.debug.print(messages.run_failed_format ++ "\n", .{@errorName(err)});
        },
    }
    std.process.exit(1);
}

pub fn run() !void {
    log.logStart(build_options.version);
    defer log.logStop(build_options.version);

    if (std.process.hasEnvVarConstant("TILDAZ_LINUX_PTY_SMOKE")) {
        var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
        defer _ = gpa.deinit();
        try runPtySmoke(gpa.allocator());
        return;
    }

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    // L13-α — `Config.load` (cross-platform). 첫 실행 시 `~/.config/tildaz/
    // config.json` template 생성, 이후 실행은 disk 값 그대로. shell_resolved
    // 는 macOS / Windows host 와 같은 의미 — 첫 실행 시 disk JSON 에 명시될
    // shell path 결정.
    const shell_resolved = resolveShell(gpa.allocator());
    g_config = config_mod.Config.load(gpa.allocator(), shell_resolved);
    defer if (g_config) |*c| c.deinit();
    const cfg = &g_config.?;
    log.appendLine("startup", "config loaded: theme={s} shell={s} max_scroll={} auto_start={} hidden_start={}", .{
        if (cfg.theme) |t| t.name else "default",
        cfg.shell,
        cfg.max_scroll_lines,
        cfg.auto_start,
        cfg.hidden_start,
    });

    try wayland.runBaselineWindow(gpa.allocator(), &g_config.?);
}

fn runPtySmoke(allocator: std.mem.Allocator) !void {
    var done = std.atomic.Value(bool).init(false);
    var backend = try terminal.TerminalBackend.init(.{
        .allocator = allocator,
        .cols = 80,
        .rows = 24,
        .shell = "/bin/sh",
        .theme = null,
    });
    defer backend.deinit();

    try backend.startReadThread(smokeRead, smokeExit, &done);
    _ = try backend.write("printf 'tildaz linux pty ok\\n'; exit\n");

    var elapsed_ms: u64 = 0;
    while (!done.load(.acquire) and elapsed_ms < 2000) : (elapsed_ms += 10) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

fn smokeRead(data: []const u8, _: ?*anyopaque) void {
    std.debug.print("{s}", .{data});
}

fn smokeExit(userdata: ?*anyopaque) void {
    const done: *std.atomic.Value(bool) = @ptrCast(@alignCast(userdata.?));
    done.store(true, .release);
}
