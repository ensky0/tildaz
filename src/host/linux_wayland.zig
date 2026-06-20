const std = @import("std");
const build_options = @import("build_options");
const log = @import("../log.zig");
const messages = @import("../messages.zig");
const terminal = @import("../terminal.zig");
const config_mod = @import("../config.zig");
const autostart = @import("../autostart.zig");
const gsettings_hotkey = @import("linux/gsettings_hotkey.zig");
const wayland = @import("linux/wayland_minimal.zig");

/// L13-α — 사용자 설정. macOS `g_config` 패턴 동등. `run()` 안에서 한 번
/// load 되고 wayland client 가 module 경계로 가져다 쓴다.
var g_config: ?config_mod.Config = null;

/// `$SHELL` env 우선, 없으면 `Defaults.shell` (= "/bin/bash"). POSIX 패턴 —
/// macOS host 의 `resolveShell` 과 동등.
fn resolveShell(allocator: std.mem.Allocator) []const u8 {
    if (std.process.getEnvVarOwned(allocator, "SHELL") catch null) |s| return s;
    // #218 — Config.load 가 owned 인수를 기대 (disk 경로서 free) — fallback 도
    // dupe. OOM 시 static drift 는 극단 케이스(곧 종료).
    return allocator.dupe(u8, config_mod.Defaults.shell) catch config_mod.Defaults.shell;
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
    // #197 — 사용자 메시지를 stderr + 로그에 동일하게 (log.userFacing). 로그와
    // 화면 내용이 갈리지 않는다.
    switch (err) {
        error.LinuxWaylandBackendNotImplemented => {
            log.userFacing("fatal", messages.linux_backend_not_ready_msg);
        },
        // Wayland socket 실패는 `Client.init` 안에서 path / env 까지 포함한
        // 정확한 메시지를 이미 stderr + log 양쪽에 남겼다. 여기선 errorName 만
        // compact 하게 한 줄 — generic 본문을 다시 내면 그 진단을 가린다.
        error.WaylandSocketUnavailable => {
            log.appendLine("fatal", "run failed: {s}", .{@errorName(err)});
        },
        else => {
            var buf: [256]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, messages.run_failed_format, .{@errorName(err)}) catch messages.run_failed_fallback_msg;
            log.userFacing("fatal", text);
        },
    }
    std.process.exit(1);
}

pub fn run() !void {
    log.logStart(build_options.version);
    defer log.logStop(build_options.version);
    // #197 — env TILDAZ_VERBOSE 면 protocol/timing/detail 로그까지 (기본은 lifecycle).
    log.setVerbose(std.process.hasEnvVarConstant("TILDAZ_VERBOSE"));

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
    defer if (g_config) |*c| c.deinit(gpa.allocator());
    const cfg = &g_config.?;
    log.logConfigLoaded(cfg.*);

    // L11-α — auto-start (XDG autostart `~/.config/autostart/tildaz.desktop`).
    // mac LaunchAgent / Windows Registry Run 동등. 매 부팅마다 enable / disable
    // 을 sync 해 사용자가 config 끄면 즉시 효과. install path 가 바뀌었어도
    // (다른 위치로 binary 옮겼어도) 현재 `selfExePath` 로 자동 갱신.
    // GNOME 은 lifecycle(launch/show/hide) 을 extension 이 담당하므로 XDG
    // autostart `.desktop` 을 쓰지 않는다 — GNOME 이면 extension 감지나 auto_start
    // 값과 무관하게 무조건 삭제한다(KDE/sway 에서 GNOME 으로 바꿨을 때 남은 잔재
    // 포함). 그 외 DE 는 auto_start 따라 enable/disable.
    if (gsettings_hotkey.isGnomeDesktop(gpa.allocator())) {
        // GNOME 은 autostart(로그인 launch)를 extension 이 담당한다. 따라서 XDG
        // autostart `.desktop` 은 GNOME 에서 *절대 쓰지 않는다* — extension 감지
        // 여부나 auto_start 값과 무관하게, 다른 DE(KDE/sway 등)에서 GNOME 으로
        // 바꿨을 때 남은 잔재까지 무조건 확인 후 삭제한다. (autostart .desktop 이
        // 살아 있으면 extension placement 전 중앙 일반창이 떠 lifecycle 이 꼬임.)
        autostart.disable(gpa.allocator());
        if (gsettings_hotkey.isGnomeWithExtension(gpa.allocator())) {
            // extension 이 창을 잡아 배치/숨김. hidden_start(surface 보류)는
            // extension 이 잡을 *창 자체* 를 없애 무한 재launch 를 유발한다(실측).
            // 무시하고 tildaz 는 항상 창을 만들며, 숨김(hidden_start=true)은
            // extension 이 minimize + skip_taskbar 로 처리한다.
            g_config.?.hidden_start = false;
            log.appendLine("autostart", "GNOME + extension — removed autostart .desktop + hidden_start override (extension handles lifecycle)", .{});
        } else {
            log.appendLine("autostart", "GNOME (extension not detected) — removed autostart .desktop (extension handles GNOME autostart)", .{});
        }
    } else if (cfg.auto_start) {
        autostart.enable(gpa.allocator()) catch |err| {
            log.appendLine("autostart", "enable failed: {s}", .{@errorName(err)});
        };
    } else {
        autostart.disable(gpa.allocator());
    }

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
