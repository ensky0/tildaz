const std = @import("std");
const build_options = @import("build_options");
const log = @import("../log.zig");
const messages = @import("../messages.zig");
const terminal = @import("../terminal.zig");

pub fn showPanic(msg: []const u8, addr: usize) noreturn {
    log.appendLine("panic", "{s}  return_addr=0x{x}", .{ msg, addr });
    std.debug.print(messages.panic_format ++ "\n", .{ msg, addr });
    std.process.exit(1);
}

pub fn showFatalRunError(err: anyerror) void {
    log.appendLine("fatal", "run failed: {s}", .{@errorName(err)});
    switch (err) {
        error.LinuxWaylandBackendNotImplemented => {
            std.debug.print("{s}\n", .{messages.linux_backend_not_ready_msg});
        },
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
    }

    log.appendLine(
        "linux",
        "Wayland backend boundary reached; implementation starts from #189 L1/L2",
        .{},
    );
    return error.LinuxWaylandBackendNotImplemented;
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
