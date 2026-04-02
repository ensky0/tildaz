const std = @import("std");
const ghostty = @import("ghostty-vt");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Create a terminal with 80x24 dimensions
    var terminal = try ghostty.Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer terminal.deinit(alloc);

    // Write a test string to the terminal
    try terminal.printString("TildaZ - Quake-style drop-down terminal for Windows\r\n");

    // Read back the rendered content
    const output = try terminal.plainString(alloc);
    defer alloc.free(output);

    std.debug.print("Terminal output:\n{s}\n", .{output});
    std.debug.print("TildaZ: libghostty-vt integration OK\n", .{});
}
