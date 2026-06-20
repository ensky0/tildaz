const std = @import("std");
const builtin = @import("builtin");
const host = switch (builtin.os.tag) {
    .windows => @import("host/windows.zig"),
    .macos => @import("host/macos.zig"),
    .linux => @import("host/linux_wayland.zig"),
    else => @import("host/unsupported.zig"),
};

/// `std.log` 호출 (ghostty-vt 의 `unimplemented mode` 등) 을 우리 통합 로그로
/// redirect — stdout/stderr 안 찍힘. macOS 는 `~/Library/Logs/tildaz.log`,
/// Windows 는 `%APPDATA%\tildaz\tildaz.log` 의 `[std.log:<scope>]` category.
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
    // #198 — Linux portal-less hotkey support. `tildaz --toggle` 명령은 첫
    // 인스턴스의 Unix domain socket 으로 toggle 신호 송신 + 즉시 exit. 사용자가
    // 자기 DE 의 keyboard shortcut 설정에서 이 명령에 단축키 binding —
    // GlobalShortcuts portal 안 advertise 하는 환경 (Cinnamon / mutter /
    // wlroots) 에서도 hotkey toggle 가능.
    if (builtin.os.tag == .linux) {
        for (std.os.argv[1..]) |arg_ptr| {
            const arg = std.mem.span(arg_ptr);
            if (std.mem.eql(u8, arg, "--toggle")) {
                const si = @import("host/linux/single_instance.zig");
                // 결과를 tildaz.log 에도 남긴다 — `tildaz --toggle` 은 별 process 라
                // stderr 가 compositor 저널로 가 진단이 어렵다 (#230). 매 hotkey 마다
                // 기존 인스턴스에 닿았는지(sent) / 없는지(NoRunningInstance) 기록.
                si.sendToggle() catch |err| {
                    @import("log.zig").appendLine("toggle-ipc", "--toggle send failed: {s} (running instance 없음/socket 문제)", .{@errorName(err)});
                    std.debug.print("tildaz --toggle failed: {s}\n", .{@errorName(err)});
                    std.process.exit(1);
                };
                @import("log.zig").appendLine("toggle-ipc", "--toggle sent to running instance", .{});
                std.process.exit(0);
            }
        }
    }

    host.run() catch |err| host.showFatalRunError(err);
}
