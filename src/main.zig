const std = @import("std");
const ghostty = @import("ghostty-vt");
const ConPty = @import("conpty.zig").ConPty;
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const RECT = window_mod.RECT;
const GlRenderer = @import("renderer.zig").GlRenderer;
const Config = @import("config.zig").Config;
const themes = @import("themes.zig");
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
const WM_LBUTTONDBLCLK: c_uint = 0x0203;
const WM_MOUSEWHEEL: c_uint = 0x020A;
pub const WM_TAB_CLOSED: c_uint = 0x0402; // WM_USER + 2

/// Lock-free 링버퍼 (단일 생산자, 단일 소비자)
const RingBuffer = struct {
    buf: [64 * 1024]u8 = undefined, // 64KB
    head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0), // 쓰기 위치 (생산자)
    tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0), // 읽기 위치 (소비자)

    const SIZE = 64 * 1024;

    /// 생산자: 데이터 추가 (읽기 스레드에서 호출)
    fn push(self: *RingBuffer, data: []const u8) void {
        const h = self.head.load(.acquire);
        const t = self.tail.load(.acquire);
        var pos = h;
        for (data) |byte| {
            const next = (pos + 1) % SIZE;
            if (next == t) break; // 가득 차면 drop
            self.buf[pos] = byte;
            pos = next;
        }
        self.head.store(pos, .release);
    }

    /// 소비자: 데이터 꺼내기 (UI 스레드에서 호출)
    fn pop(self: *RingBuffer, out: []u8) usize {
        const h = self.head.load(.acquire);
        var t = self.tail.load(.acquire);
        var n: usize = 0;
        while (t != h and n < out.len) {
            out[n] = self.buf[t];
            t = (t + 1) % SIZE;
            n += 1;
        }
        self.tail.store(t, .release);
        return n;
    }
};

/// PTY write용 큐 (UI → write 스레드)
const WriteQueue = struct {
    buf: [4096]u8 = undefined,
    head: usize = 0,
    tail: usize = 0,
    mutex: std.Thread.Mutex = .{},
    event: std.Thread.ResetEvent = .{},
    closed: bool = false,

    fn push(self: *WriteQueue, data: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (data) |byte| {
            const next = (self.head + 1) % self.buf.len;
            if (next == self.tail) continue;
            self.buf[self.head] = byte;
            self.head = next;
        }
        self.event.set();
    }

    fn pop(self: *WriteQueue, out: []u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        while (self.tail != self.head and n < out.len) {
            out[n] = self.buf[self.tail];
            self.tail = (self.tail + 1) % self.buf.len;
            n += 1;
        }
        return n;
    }

    fn close(self: *WriteQueue) void {
        self.mutex.lock();
        self.closed = true;
        self.mutex.unlock();
        self.event.set();
    }

    fn isClosed(self: *WriteQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.closed;
    }
};

const Tab = struct {
    terminal: ghostty.Terminal,
    stream: ghostty.TerminalStream,
    pty: ConPty,
    title: [64]u8 = undefined,
    title_len: usize = 0,
    alive: bool = true,
    owner: *App,
    // PTY 출력 버퍼: 읽기 스레드 → UI 스레드 (lock-free)
    output_ring: RingBuffer = .{},
    // PTY 입력 큐: UI 스레드 → write 스레드
    write_queue: WriteQueue = .{},
    write_thread: ?std.Thread = null,

    fn init(alloc: std.mem.Allocator, cols: u16, rows: u16, shell: [*:0]const u16, owner: *App) !*Tab {
        const tab = try alloc.create(Tab);
        errdefer alloc.destroy(tab);
        const term_colors = if (owner.theme) |t| ghostty.Terminal.Colors{
            .foreground = ghostty.color.DynamicRGB.init(t.foreground),
            .background = ghostty.color.DynamicRGB.init(t.background),
            .cursor = .unset,
            .palette = ghostty.color.DynamicPalette.init(themes.buildPalette(t.palette)),
        } else ghostty.Terminal.Colors.default;
        tab.* = .{
            .terminal = try ghostty.Terminal.init(alloc, .{
                .cols = cols,
                .rows = rows,
                .max_scrollback = owner.max_scroll_lines,
                .colors = term_colors,
            }),
            .stream = undefined,
            .pty = try ConPty.init(alloc, cols, rows, shell),
            .owner = owner,
        };
        tab.stream = tab.terminal.vtStream();
        tab.write_thread = try std.Thread.spawn(.{}, writeLoop, .{tab});
        return tab;
    }

    fn deinit(tab: *Tab, alloc: std.mem.Allocator) void {
        tab.write_queue.close();
        if (tab.write_thread) |t| {
            t.join();
            tab.write_thread = null;
        }
        tab.pty.deinit();
        tab.terminal.deinit(alloc);
        alloc.destroy(tab);
    }

    fn queueWrite(tab: *Tab, data: []const u8) void {
        tab.write_queue.push(data);
    }

    /// UI 스레드에서 호출: 버퍼에 쌓인 PTY 출력을 VT 파서로 처리
    fn drainOutput(tab: *Tab) void {
        var buf: [4096]u8 = undefined;
        // 16ms 프레임 내에 처리할 수 있는 만큼만 (최대 ~64KB)
        var total: usize = 0;
        while (total < 64 * 1024) {
            const n = tab.output_ring.pop(&buf);
            if (n == 0) break;
            tab.stream.nextSlice(buf[0..n]);
            total += n;
        }
    }

    fn writeLoop(tab: *Tab) void {
        var buf: [256]u8 = undefined;
        while (true) {
            tab.write_queue.event.wait();
            tab.write_queue.event.reset();
            while (true) {
                const n = tab.write_queue.pop(&buf);
                if (n == 0) break;
                _ = tab.pty.write(buf[0..n]) catch {};
            }
            if (tab.write_queue.isClosed()) break;
        }
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
    max_scroll_lines: usize = 10_000,
    theme: ?*const themes.Theme = null,
    dragging: bool = false,
    drag_tab_index: usize = 0,
    drag_start_x: c_int = 0,
    drag_current_x: c_int = 0,
    tab_drag_active: bool = false, // true = drag started in tab bar
    selecting: bool = false, // true = terminal text selection in progress
    scrollbar_dragging: bool = false, // true = scrollbar drag in progress
    select_start_pin: ?ghostty.PageList.Pin = null,

    // Word boundary characters for double-click selection
    const word_boundaries = [_]u21{ ' ', '\t', '"', '\'', '`', '|', ':', ';', ',', '.', '(', ')', '[', ']', '{', '}', '<', '>' };

    // Tab bar constants
    const TAB_BAR_HEIGHT: c_int = 28;
    const TAB_WIDTH: c_int = 150;
    const CLOSE_BTN_SIZE: c_int = 14;
    const TAB_PADDING: c_int = 6;
    const SCROLLBAR_W: c_int = 8;

    fn createTab(self: *App) !void {
        const grid = self.getTerminalGridSize();
        const tab = try Tab.init(self.allocator, grid.cols, grid.rows, self.shell_utf16, self);
        errdefer tab.deinit(self.allocator);

        tab.setTitle(self.tabs.items.len);
        try self.tabs.append(self.allocator, tab);
        self.active_tab = self.tabs.items.len - 1;
        if (self.gl_renderer) |*r| r.invalidate();

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
            // Force full redraw so the new active tab's content is rendered
            if (self.gl_renderer) |*r| r.invalidate();
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
        // 링버퍼에 넣기만 함 (lock-free, 즉시 반환)
        tab.output_ring.push(data);
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
            tab.queueWrite(data);
            tab.terminal.scrollViewport(.{ .bottom = {} });
        }
    }

    fn onResize(_: u16, _: u16, userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        const grid = self.getTerminalGridSize();
        for (self.tabs.items) |tab| {
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

            // VT 처리 + 렌더링 (둘 다 UI 스레드에서 — mutex 경합 없음)
            if (self.activeTabPtr()) |tab| {
                tab.drainOutput();
                r.renderTerminal(
                    &tab.terminal,
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
        if (index < self.tabs.items.len and index != self.active_tab) {
            self.active_tab = index;
            if (self.gl_renderer) |*r| r.invalidate();
        }
    }

    pub fn handleScroll(self: *App, wParam: usize) void {
        const tab = self.activeTabPtr() orelse return;
        const vk_prior: usize = 0x21;
        const vk_next: usize = 0x22;

        // Shift+PageUp/Down: wParam is the VK code
        if (wParam == vk_prior or wParam == vk_next) {
            const rows: isize = @intCast(self.getTerminalGridSize().rows);
            const delta: isize = if (wParam == vk_prior) -rows else rows;
            tab.terminal.scrollViewport(.{ .delta = delta });
            if (self.gl_renderer) |*r| r.invalidate();
            return;
        }

        // Mouse wheel: wParam high word is wheel delta (120 = one notch)
        const raw: i16 = @bitCast(@as(u16, @truncate(wParam >> 16)));
        const delta: isize = @divTrunc(@as(isize, raw), 40); // ~3 lines per notch
        tab.terminal.scrollViewport(.{ .delta = -delta });
        if (self.gl_renderer) |*r| r.invalidate();
    }

    fn scrollToY(self: *App, mouse_y: c_int) void {
        const tab = self.activeTabPtr() orelse return;
        const screen = tab.terminal.screens.active;
        const sb = screen.pages.scrollbar();
        if (sb.total <= sb.len) return;

        // 터미널 영역 내 Y 비율 → 스크롤 위치
        var client_h: c_int = 0;
        if (self.window.hwnd) |hwnd| {
            var rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            _ = GetClientRect(hwnd, &rect);
            client_h = rect.bottom;
        }
        const track_h = client_h - TAB_BAR_HEIGHT;
        if (track_h <= 0) return;

        const rel_y = @max(0, mouse_y - TAB_BAR_HEIGHT);
        const clamped_y = @min(rel_y, track_h);
        const ratio = @as(f64, @floatFromInt(clamped_y)) / @as(f64, @floatFromInt(track_h));
        const target_row: usize = @intFromFloat(ratio * @as(f64, @floatFromInt(sb.total - sb.len)));

        // delta = target - current offset
        const current: isize = @intCast(sb.offset);
        const target: isize = @intCast(target_row);
        const delta = target - current;
        if (delta != 0) {
            tab.terminal.scrollViewport(.{ .delta = delta });
            if (self.gl_renderer) |*r| r.invalidate();
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

        if (tab_index != self.active_tab) {
            self.active_tab = tab_index;
            if (self.gl_renderer) |*r| r.invalidate();
        }
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

    fn mouseToCell(self: *const App, mouse_x: c_int, mouse_y: c_int) struct { col: u16, row: u16 } {
        const cw = self.window.cell_width;
        const ch = self.window.cell_height;
        const grid = self.getTerminalGridSize();
        const term_y = mouse_y - TAB_BAR_HEIGHT;
        const col: u16 = if (cw > 0 and mouse_x >= 0) @intCast(@min(@divTrunc(mouse_x, cw), @as(c_int, grid.cols) - 1)) else 0;
        const row: u16 = if (ch > 0 and term_y >= 0) @intCast(@min(@divTrunc(term_y, ch), @as(c_int, grid.rows) - 1)) else 0;
        return .{ .col = col, .row = row };
    }

    fn startTerminalSelection(self: *App, mouse_x: c_int, mouse_y: c_int) void {
        const cell = self.mouseToCell(mouse_x, mouse_y);
        self.selecting = true;

        if (self.activeTabPtr()) |tab| {
            const screen: *ghostty.Screen = tab.terminal.screens.active;
            screen.clearSelection();
            // Pin으로 저장 — viewport가 스크롤돼도 위치 유지
            self.select_start_pin = screen.pages.pin(.{ .viewport = .{ .x = cell.col, .y = cell.row } });
        }
    }

    fn updateTerminalSelection(self: *App, mouse_x: c_int, mouse_y: c_int) void {
        if (!self.selecting) return;
        const start_pin = self.select_start_pin orelse return;
        const tab = self.activeTabPtr() orelse return;

        // 터미널 영역 위/아래로 드래그 시 자동 스크롤
        const term_y = mouse_y - TAB_BAR_HEIGHT;
        var client_h: c_int = 0;
        if (self.window.hwnd) |hwnd| {
            var rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            _ = GetClientRect(hwnd, &rect);
            client_h = rect.bottom;
        }
        const term_h = client_h - TAB_BAR_HEIGHT;
        if (term_y < 0) {
            tab.terminal.scrollViewport(.{ .delta = -3 });
        } else if (term_y > term_h) {
            tab.terminal.scrollViewport(.{ .delta = 3 });
        }

        const cell = self.mouseToCell(mouse_x, mouse_y);
        const screen: *ghostty.Screen = tab.terminal.screens.active;

        const end_pin = screen.pages.pin(.{ .viewport = .{ .x = cell.col, .y = cell.row } }) orelse return;

        const sel = ghostty.Selection.init(start_pin, end_pin, false);
        screen.select(sel) catch {};
    }

    fn finishTerminalSelection(self: *App) void {
        if (!self.selecting) return;
        self.selecting = false;

        const tab = self.activeTabPtr() orelse return;
        const screen: *ghostty.Screen = tab.terminal.screens.active;

        const sel = screen.selection orelse return;
        const text = screen.selectionString(self.allocator, .{ .sel = sel }) catch return;
        defer self.allocator.free(text);
        if (text.len > 0) {
            self.window.copyToClipboard(text);
        }
    }

    fn selectWordAt(self: *App, mouse_x: c_int, mouse_y: c_int) void {
        const tab = self.activeTabPtr() orelse return;
        const cell = self.mouseToCell(mouse_x, mouse_y);

        const screen: *ghostty.Screen = tab.terminal.screens.active;

        const pin = screen.pages.pin(.{ .viewport = .{ .x = cell.col, .y = cell.row } }) orelse return;
        const sel = screen.selectWord(pin, &word_boundaries) orelse return;
        screen.select(sel) catch {};

        // Copy word to clipboard
        const text = screen.selectionString(self.allocator, .{ .sel = sel }) catch return;
        defer self.allocator.free(text);
        if (text.len > 0) {
            self.window.copyToClipboard(text);
        }
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
                    self.tab_drag_active = true;
                    self.selecting = false;
                    self.scrollbar_dragging = false;
                    self.handleTabClick(x, y);
                    self.handleDragStart(x);
                } else {
                    var client_w: c_int = 0;
                    if (self.window.hwnd) |hwnd| {
                        var rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
                        _ = GetClientRect(hwnd, &rect);
                        client_w = rect.right;
                    }
                    if (x >= client_w - SCROLLBAR_W) {
                        self.scrollbar_dragging = true;
                        self.tab_drag_active = false;
                        self.selecting = false;
                        self.scrollToY(y);
                    } else {
                        self.tab_drag_active = false;
                        self.scrollbar_dragging = false;
                        self.startTerminalSelection(x, y);
                    }
                }
                return true;
            },
            WM_LBUTTONDBLCLK => {
                const x = getXParam(lParam);
                const y = getYParam(lParam);
                if (y >= TAB_BAR_HEIGHT) {
                    self.selectWordAt(x, y);
                }
                return true;
            },
            WM_MOUSEMOVE => {
                if (wParam & MK_LBUTTON != 0) {
                    if (self.scrollbar_dragging) {
                        self.scrollToY(getYParam(lParam));
                    } else if (self.tab_drag_active) {
                        self.handleDragMove(getXParam(lParam));
                    } else if (self.selecting) {
                        self.updateTerminalSelection(getXParam(lParam), getYParam(lParam));
                    }
                }
                return true;
            },
            WM_LBUTTONUP => {
                if (self.scrollbar_dragging) {
                    self.scrollbar_dragging = false;
                } else if (self.tab_drag_active) {
                    self.handleDragEnd();
                    self.tab_drag_active = false;
                } else {
                    self.finishTerminalSelection();
                }
                return true;
            },
            WM_MOUSEWHEEL => {
                self.handleScroll(wParam);
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
        autostart.disable();
    }

    var app = App{
        .tabs = .{},
        .window = .{},
        .allocator = alloc,
        .shell_utf16 = config.shellUtf16(),
        .max_scroll_lines = config.max_scroll_lines,
        .theme = config.theme,
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
    try app.window.init(font_family_w, font_size, config.opacity);
    defer app.window.deinit();

    // Initialize OpenGL renderer
    const theme_bg: ?[3]u8 = if (config.theme) |t| .{ t.background.r, t.background.g, t.background.b } else null;
    app.gl_renderer = GlRenderer.init(alloc, font_family_w, font_size, @intCast(app.window.cell_width), @intCast(app.window.cell_height), theme_bg) catch null;
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
