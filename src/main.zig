const std = @import("std");
const ghostty = @import("ghostty-vt");
const ConPty = @import("conpty.zig").ConPty;
const Window = @import("window.zig").Window;
const render = @import("renderer.zig");
const Config = @import("config.zig").Config;
const autostart = @import("autostart.zig");

const HDC = ?*anyopaque;
const WCHAR = u16;

extern "user32" fn MessageBoxW(?*anyopaque, [*:0]const WCHAR, [*:0]const WCHAR, c_uint) callconv(.c) c_int;
const MB_OK: c_uint = 0x0;
const MB_ICONERROR: c_uint = 0x10;

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

    fn onRender(window: *Window, hdc: HDC) void {
        const self: *App = @ptrCast(@alignCast(window.userdata.?));

        self.mutex.lock();
        defer self.mutex.unlock();
        render.renderTerminal(hdc, &self.terminal, self.allocator, window.cell_width, window.cell_height);
    }
};

pub fn main() void {
    run() catch {
        const msg = std.unicode.utf8ToUtf16LeStringLiteral("TildaZ 실행 중 오류가 발생했습니다.");
        const title = std.unicode.utf8ToUtf16LeStringLiteral("TildaZ Error");
        _ = MessageBoxW(null, msg, title, MB_OK | MB_ICONERROR);
    };
}

fn run() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Load configuration
    var config = Config.load(alloc);

    // Validate config values
    if (config.validate()) |err_msg| {
        const title = std.unicode.utf8ToUtf16LeStringLiteral("TildaZ Config Error");
        _ = MessageBoxW(null, err_msg, title, MB_OK | MB_ICONERROR);
        return;
    }

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
    app.window.setPosition(config.dock_position, config.width, config.length, config.offset);

    // Start PTY read thread
    try app.pty.startReadThread(App.onPtyOutput, &app);

    // Show window and enter message loop
    app.window.show();
    app.window.messageLoop();
}
