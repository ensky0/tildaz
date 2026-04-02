const std = @import("std");
const ghostty = @import("ghostty-vt");
const ConPty = @import("conpty.zig").ConPty;

const VtCtx = struct {
    terminal: *ghostty.Terminal,
    stream: ghostty.TerminalStream,
    mutex: std.Thread.Mutex = .{},
    received: bool = false,

    fn init(terminal: *ghostty.Terminal) VtCtx {
        return .{
            .terminal = terminal,
            .stream = terminal.vtStream(),
        };
    }

    fn onPtyOutput(data: []const u8, userdata: ?*anyopaque) void {
        const ctx: *VtCtx = @ptrCast(@alignCast(userdata.?));
        ctx.mutex.lock();
        defer ctx.mutex.unlock();
        ctx.stream.nextSlice(data);
        ctx.received = true;
    }
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Create ghostty terminal (80x24)
    var terminal = try ghostty.Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer terminal.deinit(alloc);

    // Set up VT stream context
    var ctx = VtCtx.init(&terminal);

    // Create ConPTY with cmd.exe
    const shell = std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe");
    var pty = try ConPty.init(alloc, 80, 24, shell);
    defer pty.deinit();

    // Start reading ConPTY output → VT stream → terminal state
    try pty.startReadThread(VtCtx.onPtyOutput, &ctx);

    // Wait for shell startup
    std.Thread.sleep(500 * std.time.ns_per_ms);

    // Send a test command
    _ = try pty.write("echo Hello from TildaZ\r\n");

    // Wait for response
    std.Thread.sleep(500 * std.time.ns_per_ms);

    // Read terminal content (thread-safe)
    ctx.mutex.lock();
    const output = try terminal.plainString(alloc);
    ctx.mutex.unlock();
    defer alloc.free(output);

    std.debug.print("=== Terminal Content ===\n{s}\n=== End ===\n", .{output});

    if (ctx.received) {
        std.debug.print("SUCCESS: ConPTY → VT Stream → Terminal working!\n", .{});
    } else {
        std.debug.print("WARNING: No output received from ConPTY\n", .{});
    }
}
