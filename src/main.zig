const std = @import("std");
const ghostty = @import("ghostty-vt");
const ConPty = @import("conpty.zig").ConPty;
const Window = @import("window.zig").Window;
const GlRenderer = @import("renderer.zig").GlRenderer;
const Config = @import("config.zig").Config;
const autostart = @import("autostart.zig");

const HWND = ?*anyopaque;
const WCHAR = u16;
extern "user32" fn MessageBoxW(?*anyopaque, [*:0]const WCHAR, [*:0]const WCHAR, c_uint) callconv(.c) c_int;
extern "user32" fn PostMessageW(HWND, c_uint, usize, isize) callconv(.c) c_int;
extern "kernel32" fn CreateMutexW(?*anyopaque, c_int, [*:0]const WCHAR) callconv(.c) ?*anyopaque;
extern "kernel32" fn GetLastError() callconv(.c) u32;
extern "kernel32" fn CloseHandle(?*anyopaque) callconv(.c) c_int;
const ERROR_ALREADY_EXISTS: u32 = 183;
const WM_CLOSE: c_uint = 0x0010;
const MB_OK: c_uint = 0x0;
const MB_ICONERROR: c_uint = 0x10;
const MB_ICONINFORMATION: c_uint = 0x40;

const App = struct {
    terminal: *ghostty.Terminal,
    stream: ghostty.TerminalStream,
    pty: *ConPty,
    window: Window,
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,
    gl_renderer: ?GlRenderer = null,

    fn onPtyOutput(data: []const u8, userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stream.nextSlice(data);
    }

    fn onPtyExit(userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        // Shell exited — close window without confirmation prompt
        self.window.shell_exited = true;
        if (self.window.hwnd) |hwnd| {
            _ = PostMessageW(hwnd, WM_CLOSE, 0, 0);
        }
    }

    fn onKeyInput(data: []const u8, userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        _ = self.pty.write(data) catch {};
    }

    fn onResize(cols: u16, rows: u16, userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.terminal.resize(self.allocator, cols, rows) catch {};
        self.pty.resize(cols, rows) catch {};
    }

    fn onRender(window: *Window) void {
        const self: *App = @ptrCast(@alignCast(window.userdata.?));

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.gl_renderer) |*r| {
            const size = window.getClientSize();
            r.render(self.terminal, self.allocator, window.cell_width, window.cell_height, size.w, size.h);
        }
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
    // Single instance check
    const mutex = CreateMutexW(null, 0, std.unicode.utf8ToUtf16LeStringLiteral("Global\\TildaZ_SingleInstance"));
    if (mutex != null and GetLastError() == ERROR_ALREADY_EXISTS) {
        _ = CloseHandle(mutex);
        const msg = std.unicode.utf8ToUtf16LeStringLiteral("TildaZ is already running.");
        const title = std.unicode.utf8ToUtf16LeStringLiteral("TildaZ");
        _ = MessageBoxW(null, msg, title, MB_OK | MB_ICONINFORMATION);
        return;
    }
    defer if (mutex != null) {
        _ = CloseHandle(mutex);
    };

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Load configuration
    var config = Config.load(alloc);
    defer config.deinit();

    // Validate config values
    if (config.validate()) |err_msg| {
        const title = std.unicode.utf8ToUtf16LeStringLiteral("TildaZ Config Error");
        _ = MessageBoxW(null, err_msg, title, MB_OK | MB_ICONERROR);
        return;
    }


    // Handle autostart
    if (config.auto_start) {
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

    // Create app state (terminal and pty by pointer to avoid copy bugs)
    var app = App{
        .terminal = &terminal,
        .stream = terminal.vtStream(),
        .pty = &pty,
        .window = .{},
        .allocator = alloc,
    };

    // Start PTY read thread early — before window init so WSL output
    // doesn't block on a full pipe while we set up the window
    try app.pty.startReadThread(App.onPtyOutput, App.onPtyExit, &app);

    // Set up window
    app.window.userdata = &app;
    app.window.write_fn = App.onKeyInput;
    app.window.render_fn = App.onRender;
    app.window.resize_fn = App.onResize;
    try app.window.init();
    defer app.window.deinit();

    // Initialize OpenGL renderer (must be after window.init which creates the GL context)
    app.gl_renderer = GlRenderer.init(16, @intCast(app.window.cell_width), @intCast(app.window.cell_height)) catch null;
    defer if (app.gl_renderer) |*r| r.deinit();

    // Apply position from config
    app.window.setPosition(config.dock_position, config.width, config.height, config.offset);

    // Resize terminal and PTY to match actual window size
    const grid = app.window.getGridSize();
    try terminal.resize(alloc, grid.cols, grid.rows);
    try app.pty.resize(grid.cols, grid.rows);

    // Show window unless configured to start hidden (F1 to toggle)
    if (!config.hidden_start) {
        app.window.show();
    }
    app.window.messageLoop();
}
