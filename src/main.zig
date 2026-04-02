const std = @import("std");
const ghostty = @import("ghostty-vt");
const ConPty = @import("conpty.zig").ConPty;
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const RECT = window_mod.RECT;
const GlRenderer = @import("renderer.zig").GlRenderer;
const Config = @import("config.zig").Config;
const autostart = @import("autostart.zig");

const HWND = ?*anyopaque;
const WCHAR = u16;
extern "user32" fn MessageBoxW(?*anyopaque, [*:0]const WCHAR, [*:0]const WCHAR, c_uint) callconv(.c) c_int;
extern "user32" fn PostMessageW(HWND, c_uint, usize, isize) callconv(.c) c_int;
extern "user32" fn GetClientRect(HWND, *RECT) callconv(.c) c_int;
extern "kernel32" fn CreateMutexW(?*anyopaque, c_int, [*:0]const WCHAR) callconv(.c) ?*anyopaque;
extern "kernel32" fn GetLastError() callconv(.c) u32;
extern "kernel32" fn CloseHandle(?*anyopaque) callconv(.c) c_int;
const ERROR_ALREADY_EXISTS: u32 = 183;
const WM_CLOSE: c_uint = 0x0010;
const WM_KEYDOWN: c_uint = 0x0100;
const WM_SYSKEYDOWN: c_uint = 0x0104;
const WM_LBUTTONDOWN: c_uint = 0x0201;
const WM_LBUTTONUP: c_uint = 0x0202;
const WM_MOUSEMOVE: c_uint = 0x0200;
const MK_LBUTTON: usize = 0x0001;
const MB_OK: c_uint = 0x0;
const MB_ICONERROR: c_uint = 0x10;
const MB_ICONINFORMATION: c_uint = 0x40;
pub const WM_TAB_CLOSED: c_uint = 0x0402; // WM_USER + 2

const Tab = struct {
    terminal: ghostty.Terminal,
    stream: ghostty.TerminalStream,
    pty: ConPty,
    mutex: std.Thread.Mutex = .{},
    title: [64]u8 = undefined,
    title_len: usize = 0,
    alive: bool = true,
    owner: *App,

    fn init(alloc: std.mem.Allocator, cols: u16, rows: u16, shell: [*:0]const u16, owner: *App) !*Tab {
        const tab = try alloc.create(Tab);
        errdefer alloc.destroy(tab);
        tab.* = .{
            .terminal = try ghostty.Terminal.init(alloc, .{ .cols = cols, .rows = rows }),
            .stream = undefined,
            .pty = try ConPty.init(alloc, cols, rows, shell),
            .owner = owner,
        };
        tab.stream = tab.terminal.vtStream();
        return tab;
    }

    fn deinit(tab: *Tab, alloc: std.mem.Allocator) void {
        tab.pty.deinit();
        tab.terminal.deinit(alloc);
        alloc.destroy(tab);
    }

    fn setTitle(tab: *Tab, index: usize) void {
        const result = std.fmt.bufPrint(&tab.title, "Tab {d}", .{index + 1}) catch "Tab";
        tab.title_len = result.len;
    }
};

const App = struct {
    tabs: std.ArrayList(*Tab),
    active_tab: usize = 0,
    window: Window,
    allocator: std.mem.Allocator,
    gl_renderer: ?GlRenderer = null,
    shell_utf16: [*:0]const u16,
    dragging: bool = false,
    drag_tab_index: usize = 0,
    drag_start_x: c_int = 0,
    drag_current_x: c_int = 0,

    // Tab bar constants
    const TAB_BAR_HEIGHT: c_int = 28;
    const TAB_WIDTH: c_int = 150;
    const CLOSE_BTN_SIZE: c_int = 14;
    const TAB_PADDING: c_int = 6;

    fn createTab(self: *App) !void {
        const grid = self.getTerminalGridSize();
        const tab = try Tab.init(self.allocator, grid.cols, grid.rows, self.shell_utf16, self);
        errdefer tab.deinit(self.allocator);

        tab.setTitle(self.tabs.items.len);
        try self.tabs.append(self.allocator, tab);
        self.active_tab = self.tabs.items.len - 1;

        try tab.pty.startReadThread(onPtyOutputTab, onPtyExitTab, tab);
    }

    fn closeTab(self: *App, index: usize) void {
        if (index >= self.tabs.items.len) return;
        const tab = self.tabs.orderedRemove(index);

        // Renumber remaining tabs
        for (self.tabs.items, 0..) |t, i| {
            t.setTitle(i);
        }

        if (self.tabs.items.len == 0) {
            // Last tab closed — exit
            self.window.shell_exited = true;
            if (self.window.hwnd) |hwnd| {
                _ = PostMessageW(hwnd, WM_CLOSE, 0, 0);
            }
        } else {
            if (self.active_tab >= self.tabs.items.len) {
                self.active_tab = self.tabs.items.len - 1;
            }
        }
        tab.deinit(self.allocator);
    }

    fn getTerminalGridSize(self: *const App) struct { cols: u16, rows: u16 } {
        if (self.window.hwnd == null) return .{ .cols = 120, .rows = 30 };
        var rect: RECT = undefined;
        _ = GetClientRect(self.window.hwnd, &rect);
        const w = rect.right - rect.left;
        const h = rect.bottom - rect.top - TAB_BAR_HEIGHT;
        const cols: u16 = if (self.window.cell_width > 0) @intCast(@max(1, @divTrunc(w, self.window.cell_width))) else 120;
        const rows: u16 = if (self.window.cell_height > 0) @intCast(@max(1, @divTrunc(@max(h, 1), self.window.cell_height))) else 30;
        return .{ .cols = cols, .rows = rows };
    }

    fn activeTabPtr(self: *App) ?*Tab {
        if (self.active_tab < self.tabs.items.len) return self.tabs.items[self.active_tab];
        return null;
    }

    // --- Callbacks for ConPTY (userdata = *Tab) ---

    fn onPtyOutputTab(data: []const u8, userdata: ?*anyopaque) void {
        const tab: *Tab = @ptrCast(@alignCast(userdata.?));
        tab.mutex.lock();
        defer tab.mutex.unlock();
        tab.stream.nextSlice(data);
    }

    fn onPtyExitTab(userdata: ?*anyopaque) void {
        const tab: *Tab = @ptrCast(@alignCast(userdata.?));
        tab.alive = false;
        if (tab.owner.window.hwnd) |hwnd| {
            _ = PostMessageW(hwnd, WM_TAB_CLOSED, @intFromPtr(tab), 0);
        }
    }

    // --- Window callbacks (userdata = *App) ---

    fn onKeyInput(data: []const u8, userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        if (self.activeTabPtr()) |tab| {
            _ = tab.pty.write(data) catch {};
        }
    }

    fn onResize(_: u16, _: u16, userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        const grid = self.getTerminalGridSize();
        for (self.tabs.items) |tab| {
            tab.mutex.lock();
            defer tab.mutex.unlock();
            tab.terminal.resize(self.allocator, grid.cols, grid.rows) catch {};
            tab.pty.resize(grid.cols, grid.rows) catch {};
        }
    }

    fn onRender(window: *Window) void {
        const self: *App = @ptrCast(@alignCast(window.userdata.?));

        if (self.gl_renderer) |*r| {
            const size = window.getClientSize();

            // Render tab bar
            r.renderTabBar(
                self.tabs.items.len,
                self.active_tab,
                TAB_BAR_HEIGHT,
                size.w,
                size.h,
                TAB_WIDTH,
                CLOSE_BTN_SIZE,
                TAB_PADDING,
                if (self.dragging) self.drag_tab_index else null,
                if (self.dragging) self.drag_current_x else 0,
            );

            // Render active tab's terminal content (offset by tab bar)
            if (self.activeTabPtr()) |tab| {
                tab.mutex.lock();
                defer tab.mutex.unlock();
                r.renderTerminal(
                    &tab.terminal,
                    self.allocator,
                    window.cell_width,
                    window.cell_height,
                    size.w,
                    size.h,
                    TAB_BAR_HEIGHT,
                );
            }
        }
    }

    // --- Tab management from window messages ---

    pub fn handleTabClosed(self: *App, tab_ptr: usize) void {
        const needle: *Tab = @ptrFromInt(tab_ptr);
        for (self.tabs.items, 0..) |t, i| {
            if (t == needle) {
                self.closeTab(i);
                return;
            }
        }
    }

    pub fn handleNewTab(self: *App) void {
        self.createTab() catch {};
    }

    pub fn handleCloseActiveTab(self: *App) void {
        if (self.tabs.items.len > 0) {
            self.closeTab(self.active_tab);
        }
    }

    pub fn handleSwitchTab(self: *App, index: usize) void {
        if (index < self.tabs.items.len) {
            self.active_tab = index;
        }
    }

    pub fn handleTabClick(self: *App, mouse_x: c_int, mouse_y: c_int) void {
        if (mouse_y >= TAB_BAR_HEIGHT) return; // Below tab bar
        if (self.tabs.items.len == 0) return;

        const tab_index_raw = @divTrunc(mouse_x, TAB_WIDTH);
        if (tab_index_raw < 0) return;
        const tab_index: usize = @intCast(tab_index_raw);
        if (tab_index >= self.tabs.items.len) return;

        // Check if click is on close button
        const tab_x = @as(c_int, @intCast(tab_index)) * TAB_WIDTH;
        const close_x = tab_x + TAB_WIDTH - CLOSE_BTN_SIZE - 6;
        const close_y = @divTrunc(TAB_BAR_HEIGHT - CLOSE_BTN_SIZE, 2);
        if (mouse_x >= close_x and mouse_x <= close_x + CLOSE_BTN_SIZE and
            mouse_y >= close_y and mouse_y <= close_y + CLOSE_BTN_SIZE)
        {
            self.closeTab(tab_index);
            return;
        }

        self.active_tab = tab_index;
    }

    pub fn handleDragStart(self: *App, mouse_x: c_int) void {
        self.dragging = false;
        const idx_raw = @divTrunc(mouse_x, TAB_WIDTH);
        if (idx_raw < 0) return;
        const idx: usize = @intCast(idx_raw);
        if (idx >= self.tabs.items.len) return;
        self.drag_tab_index = idx;
        self.drag_start_x = mouse_x;
        self.drag_current_x = mouse_x;
    }

    pub fn handleDragMove(self: *App, mouse_x: c_int) void {
        const delta = if (mouse_x > self.drag_start_x) mouse_x - self.drag_start_x else self.drag_start_x - mouse_x;
        if (delta > 5) self.dragging = true;
        self.drag_current_x = mouse_x;
    }

    pub fn handleDragEnd(self: *App) void {
        if (self.dragging and self.tabs.items.len > 1 and self.drag_tab_index < self.tabs.items.len) {
            var target_raw = @divTrunc(self.drag_current_x, TAB_WIDTH);
            target_raw = @max(0, @min(target_raw, @as(c_int, @intCast(self.tabs.items.len - 1))));
            const target: usize = @intCast(target_raw);
            if (target != self.drag_tab_index) {
                const tab = self.tabs.orderedRemove(self.drag_tab_index);
                self.tabs.insert(self.allocator, target, tab) catch {};
                self.active_tab = target;
                // Renumber
                for (self.tabs.items, 0..) |t, i| {
                    t.setTitle(i);
                }
            }
        }
        self.dragging = false;
    }

    fn onAppMessage(msg: c_uint, wParam: usize, lParam: isize, userdata: ?*anyopaque) bool {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        switch (msg) {
            WM_KEYDOWN => {
                if (wParam == 0x54) { // Ctrl+Shift+T
                    self.handleNewTab();
                    return true;
                }
                if (wParam == 0x57) { // Ctrl+Shift+W
                    self.handleCloseActiveTab();
                    return true;
                }
                return false;
            },
            WM_SYSKEYDOWN => {
                if (wParam >= 0x31 and wParam <= 0x39) { // Alt+1..9
                    self.handleSwitchTab(wParam - 0x31);
                    return true;
                }
                return false;
            },
            WM_LBUTTONDOWN => {
                const x = getXParam(lParam);
                const y = getYParam(lParam);
                if (y < TAB_BAR_HEIGHT) {
                    self.handleTabClick(x, y);
                    self.handleDragStart(x);
                    return true;
                }
                return false;
            },
            WM_MOUSEMOVE => {
                if (wParam & MK_LBUTTON != 0) {
                    self.handleDragMove(getXParam(lParam));
                }
                return true;
            },
            WM_LBUTTONUP => {
                self.handleDragEnd();
                return true;
            },
            WM_TAB_CLOSED => {
                self.handleTabClosed(wParam);
                return true;
            },
            else => return false,
        }
    }

    fn getXParam(lp: isize) c_int {
        return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lp))))));
    }

    fn getYParam(lp: isize) c_int {
        return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lp)) >> 16))));
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

    if (config.validate()) |err_msg| {
        const title = std.unicode.utf8ToUtf16LeStringLiteral("TildaZ Config Error");
        _ = MessageBoxW(null, err_msg, title, MB_OK | MB_ICONERROR);
        return;
    }

    if (config.auto_start) {
        autostart.enable() catch {};
    } else {
        autostart.disable() catch {};
    }

    var app = App{
        .tabs = .{},
        .window = .{},
        .allocator = alloc,
        .shell_utf16 = config.shellUtf16(),
    };
    defer {
        for (app.tabs.items) |tab| tab.deinit(alloc);
        app.tabs.deinit(alloc);
    }

    // Set up window
    app.window.userdata = &app;
    app.window.write_fn = App.onKeyInput;
    app.window.render_fn = App.onRender;
    app.window.resize_fn = App.onResize;
    app.window.app_msg_fn = App.onAppMessage;
    const font_family_w = config.fontFamilyUtf16();
    const font_size: c_int = @intCast(config.font_size);
    try app.window.init(font_family_w, font_size);
    defer app.window.deinit();

    // Initialize OpenGL renderer
    app.gl_renderer = GlRenderer.init(font_family_w, font_size, @intCast(app.window.cell_width), @intCast(app.window.cell_height)) catch null;
    defer if (app.gl_renderer) |*r| r.deinit();

    // Apply position from config
    app.window.setPosition(config.dock_position, config.width, config.height, config.offset);

    // Create initial tab
    try app.createTab();

    if (!config.hidden_start) {
        app.window.show();
    }
    app.window.messageLoop();
}
