const std = @import("std");
const ghostty = @import("ghostty-vt");
const ConPty = @import("conpty.zig").ConPty;
const Window = @import("window.zig").Window;
const render = @import("renderer.zig");
const Config = @import("config.zig").Config;
const autostart = @import("autostart.zig");

extern "user32" fn GetDC(?*anyopaque) callconv(.c) ?*anyopaque;
extern "user32" fn ReleaseDC(?*anyopaque, ?*anyopaque) callconv(.c) c_int;
extern "gdi32" fn SelectObject(?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
extern "gdi32" fn SetBkMode(?*anyopaque, c_int) callconv(.c) c_int;

const App = struct {
    terminal: ghostty.Terminal,
    stream: ghostty.TerminalStream,
    pty: ConPty,
    window: Window,
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,

    fn onPtyOutput(data: []const u8, userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stream.nextSlice(data);
    }

    fn onKeyInput(data: []const u8, userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        _ = self.pty.write(data) catch {};
    }

    fn onRender(window: *Window) void {
        const self: *App = @ptrCast(@alignCast(window.userdata.?));

        const hdc = GetDC(window.hwnd);
        if (hdc == null) return;
        defer _ = ReleaseDC(window.hwnd, hdc);

        _ = SelectObject(hdc, window.font);
        _ = SetBkMode(hdc, 1); // TRANSPARENT

        self.mutex.lock();
        defer self.mutex.unlock();
        render.renderTerminal(hdc, &self.terminal, self.allocator, window.cell_width, window.cell_height);
    }
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Load configuration
    var config = Config.load(alloc);

    // Save default config if it doesn't exist
    config.save(alloc) catch {};

    // Handle autostart
    if (config.autostart) {
        autostart.enable() catch {};
    } else {
        autostart.disable() catch {};
    }

    // Create terminal
    var terminal = try ghostty.Terminal.init(alloc, .{
        .cols = 120,
        .rows = 30,
    });
    defer terminal.deinit(alloc);

    // Create ConPTY with configured shell
    var pty = try ConPty.init(alloc, 120, 30, config.shellUtf16());
    defer pty.deinit();

    // Create app state
    var app = App{
        .terminal = terminal,
        .stream = terminal.vtStream(),
        .pty = pty,
        .window = .{},
        .allocator = alloc,
    };

    // Set up window
    app.window.userdata = &app;
    app.window.write_fn = App.onKeyInput;
    app.window.render_fn = App.onRender;
    try app.window.init();
    defer app.window.deinit();

    // Apply position from config
    app.window.setPosition(config.edge, config.size, config.length, config.offset);

    // Start PTY read thread
    try app.pty.startReadThread(App.onPtyOutput, &app);

    // Show window and enter message loop
    app.window.show();
    app.window.messageLoop();
}
