const std = @import("std");
const ghostty = @import("ghostty-vt");
const app_event = @import("app_event.zig");
const session_core = @import("session_core.zig");
const SessionCore = session_core.SessionCore;
const SessionTab = session_core.Tab;
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const RECT = window_mod.RECT;
const D3d11Renderer = @import("d3d11_renderer.zig").D3d11Renderer;
const Config = @import("config.zig").Config;
const autostart = @import("autostart.zig");
const perf = @import("perf.zig");
const tildaz_log = @import("tildaz_log.zig");
const about = @import("about.zig");
const build_options = @import("build_options");

const HWND = ?*anyopaque;
const WCHAR = u16;
extern "user32" fn MessageBoxW(?*anyopaque, [*:0]const WCHAR, [*:0]const WCHAR, c_uint) callconv(.c) c_int;
extern "user32" fn MessageBoxA(?*anyopaque, [*:0]const u8, [*:0]const u8, c_uint) callconv(.c) c_int;
extern "user32" fn PostMessageW(HWND, c_uint, usize, isize) callconv(.c) c_int;
extern "user32" fn GetClientRect(HWND, *RECT) callconv(.c) c_int;
extern "kernel32" fn CreateMutexW(?*anyopaque, c_int, [*:0]const WCHAR) callconv(.c) ?*anyopaque;
extern "kernel32" fn GetLastError() callconv(.c) u32;
extern "kernel32" fn CloseHandle(?*anyopaque) callconv(.c) c_int;
extern "user32" fn SetProcessDpiAwarenessContext(isize) callconv(.c) c_int;
extern "user32" fn GetDpiForWindow(?*anyopaque) callconv(.c) c_uint;
const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;
const ERROR_ALREADY_EXISTS: u32 = 183;
const WM_CLOSE: c_uint = 0x0010;
const MB_OK: c_uint = 0x0;
const MB_ICONERROR: c_uint = 0x10;
const MB_ICONINFORMATION: c_uint = 0x40;

const App = struct {
    session: SessionCore,
    window: Window,
    allocator: std.mem.Allocator,
    d3d_renderer: ?D3d11Renderer = null,
    last_render_ms: i64 = 0,
    dragging: bool = false,
    drag_tab_index: usize = 0,
    drag_start_x: c_int = 0,
    drag_current_x: c_int = 0,
    tab_drag_active: bool = false, // true = drag started in tab bar
    selecting: bool = false, // true = terminal text selection in progress
    scrollbar_dragging: bool = false, // true = scrollbar drag in progress
    select_start_pin: ?ghostty.PageList.Pin = null,
    // Tab rename state
    renaming_tab: ?usize = null, // index of tab being renamed, null = not renaming
    rename_buf: [64]u8 = undefined,
    rename_len: usize = 0,
    rename_cursor: usize = 0,

    // DPI-scaled values (initialized in run())
    dpi_scale: f32 = 1.0,
    TAB_BAR_HEIGHT: c_int = 28,
    TAB_WIDTH: c_int = 150,
    CLOSE_BTN_SIZE: c_int = 14,
    TAB_PADDING: c_int = 6,
    SCROLLBAR_W: c_int = 8,
    // Minimum scrollback thumb height — clamps the thumb so a deeply scrolled
    // buffer (e.g. 10k lines visible 30) doesn't shrink the thumb below a
    // draggable size. Must stay in sync between renderer (draw size) and the
    // hit-test / drag math in main.zig.
    SCROLLBAR_MIN_THUMB_H: c_int = 32,
    TERMINAL_PADDING: c_int = 6,

    // Word boundary characters for double-click selection
    const word_boundaries = [_]u21{ ' ', '\t', '"', '`', '|', ':', ';', '(', ')', '[', ']', '{', '}', '<', '>' };

    fn createTab(self: *App) !void {
        const grid = self.getTerminalGridSize();
        try self.session.createTab(grid.cols, grid.rows);
        if (self.d3d_renderer) |*r| r.invalidate();
    }

    fn closeTab(self: *App, index: usize) void {
        switch (self.session.closeTab(index)) {
            .none => return,
            .closed_last => {
                tildaz_log.appendLine("tab", "last tab closed: posting WM_CLOSE", .{});
                self.window.shell_exited = true;
                if (self.window.hwnd) |hwnd| {
                    _ = PostMessageW(hwnd, WM_CLOSE, 0, 0);
                }
            },
            .changed => {
                // Force full redraw so the new active tab's content is rendered
                if (self.d3d_renderer) |*r| r.invalidate();
            },
        }
    }

    fn getTerminalGridSize(self: *const App) struct { cols: u16, rows: u16 } {
        if (self.window.hwnd == null) return .{ .cols = 120, .rows = 30 };
        var rect: RECT = undefined;
        _ = GetClientRect(self.window.hwnd, &rect);
        const w = rect.right - rect.left - 2 * self.TERMINAL_PADDING;
        const h = rect.bottom - rect.top - self.TAB_BAR_HEIGHT - 2 * self.TERMINAL_PADDING;
        const cols: u16 = if (self.window.cell_width > 0) @intCast(@max(1, @divTrunc(@max(w, 1), self.window.cell_width))) else 120;
        const rows: u16 = if (self.window.cell_height > 0) @intCast(@max(1, @divTrunc(@max(h, 1), self.window.cell_height))) else 30;
        return .{ .cols = cols, .rows = rows };
    }

    fn activeTabPtr(self: *App) ?*SessionTab {
        return self.session.activeTab();
    }

    fn onSessionTabExit(tab_ptr: usize, userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        if (self.window.hwnd) |hwnd| {
            _ = PostMessageW(hwnd, window_mod.WM_TAB_CLOSED, tab_ptr, 0);
        }
    }

    // --- Window callbacks (userdata = *App) ---

    fn onKeyInput(data: []const u8, userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        self.session.queueInputToActive(data);
    }

    fn onResize(_: u16, _: u16, userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        // Resize D3D11 render target to match new window size
        if (self.d3d_renderer) |*r| {
            const size = self.window.getClientSize();
            r.resize(@intCast(@max(1, size.w)), @intCast(@max(1, size.h)));
        }
        const grid = self.getTerminalGridSize();
        self.session.resizeAll(grid.cols, grid.rows);
    }

    /// Recompute DPI-dependent UI constants (tab bar / close button / padding /
    /// scrollbar) from `new_dpi`. Called at startup and whenever the window
    /// moves between monitors with different DPI scales.
    fn applyDpiScale(self: *App, new_dpi: c_uint) void {
        const effective: f32 = if (new_dpi > 0) @as(f32, @floatFromInt(new_dpi)) else 96.0;
        const scale: f32 = effective / 96.0;
        self.dpi_scale = scale;
        self.TAB_BAR_HEIGHT = @intFromFloat(@round(28.0 * scale));
        self.TAB_WIDTH = @intFromFloat(@round(150.0 * scale));
        self.CLOSE_BTN_SIZE = @intFromFloat(@round(14.0 * scale));
        self.TAB_PADDING = @intFromFloat(@round(6.0 * scale));
        self.SCROLLBAR_W = @intFromFloat(@round(8.0 * scale));
        self.SCROLLBAR_MIN_THUMB_H = @intFromFloat(@round(32.0 * scale));
        self.TERMINAL_PADDING = @intFromFloat(@round(6.0 * scale));
        const min_tab_bar_h: c_int = @as(c_int, @intCast(self.window.cell_height)) + 4;
        if (self.TAB_BAR_HEIGHT < min_tab_bar_h) {
            self.TAB_BAR_HEIGHT = min_tab_bar_h;
        }
    }

    /// WM_DPICHANGED path (called from `window.wndProc` after
    /// `rebuildFontForDpi` has updated `cell_width` / `cell_height`).
    ///
    /// Rebuilds the D3D renderer's font context + glyph atlas at the new
    /// DPI so glyphs are rasterized at the new monitor's pixel density,
    /// then rescales the tab bar / scrollbar / padding constants. This
    /// happens before the subsequent `SetWindowPos` → `WM_SIZE` cascade,
    /// so `onResize` computes the terminal grid from the freshly updated
    /// metrics in one step.
    fn onFontChange(window: *Window, userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        if (self.d3d_renderer) |*r| {
            r.rebuildFont(
                window.hwnd,
                window.font_family,
                window.font_size,
                @intCast(window.cell_width),
                @intCast(window.cell_height),
            ) catch {
                // Leave the renderer as-is; glyphs will stay at the old DPI
                // but the app keeps running. User can restart to recover.
            };
        }
        self.applyDpiScale(window.current_dpi);
    }

    fn onRender(window: *Window) void {
        const self: *App = @ptrCast(@alignCast(window.userdata.?));
        const onrender_t0 = perf.now();
        defer perf.addTimed(&perf.onrender, onrender_t0);

        if (self.d3d_renderer) |*r| {
            const size = window.getClientSize();

            // VT 처리 (UI 스레드에서 — mutex 경합 없음)
            const should_render = self.session.prepareActiveFrame(&self.last_render_ms);

            if (should_render) {
                // 탭바 + 터미널 함께 렌더 (glClear는 renderTabBar에 포함)
                var tab_titles: [32]D3d11Renderer.TabTitle = undefined;
                const tabs = self.session.tabsSlice();
                const n = @min(tabs.len, 32);
                for (tabs[0..n], 0..) |t, i| {
                    tab_titles[i] = .{ .ptr = &t.title, .len = t.title_len };
                }
                const rs: ?D3d11Renderer.RenameState = if (self.renaming_tab) |ri| .{
                    .tab_index = ri,
                    .text = &self.rename_buf,
                    .text_len = self.rename_len,
                    .cursor = self.rename_cursor,
                } else null;
                r.renderTabBar(
                    tab_titles[0..n],
                    self.session.activeIndex(),
                    self.TAB_BAR_HEIGHT,
                    size.w,
                    size.h,
                    self.TAB_WIDTH,
                    self.CLOSE_BTN_SIZE,
                    self.TAB_PADDING,
                    if (self.dragging) self.drag_tab_index else null,
                    if (self.dragging) self.drag_current_x else 0,
                    rs,
                );
                if (self.activeTabPtr()) |tab| {
                    r.renderTerminal(
                        &tab.terminal,
                        window.cell_width,
                        window.cell_height,
                        size.w,
                        size.h,
                        self.TAB_BAR_HEIGHT,
                        self.TERMINAL_PADDING,
                        self.SCROLLBAR_W,
                        self.SCROLLBAR_MIN_THUMB_H,
                    );
                }
            } else {
                perf.incExtra(&perf.onrender);
            }
        }
    }

    // --- Tab management from window messages ---

    pub fn handleTabClosed(self: *App, tab_ptr: usize) void {
        switch (self.session.closeTabByPtr(tab_ptr)) {
            .none => return,
            .closed_last => {
                tildaz_log.appendLine("tab", "last tab closed: posting WM_CLOSE", .{});
                self.window.shell_exited = true;
                if (self.window.hwnd) |hwnd| {
                    _ = PostMessageW(hwnd, WM_CLOSE, 0, 0);
                }
            },
            .changed => {
                if (self.d3d_renderer) |*r| r.invalidate();
            },
        }
    }

    pub fn handleNewTab(self: *App) void {
        self.createTab() catch {};
    }

    pub fn handleCloseActiveTab(self: *App) void {
        if (self.session.count() > 0) {
            self.closeTab(self.session.activeIndex());
        }
    }

    pub fn handleSwitchTab(self: *App, index: usize) void {
        if (self.session.setActiveTab(index)) {
            if (self.d3d_renderer) |*r| r.invalidate();
        }
    }

    pub fn handleScroll(self: *App, event: app_event.ScrollEvent) void {
        if (self.session.scrollActive(event, self.getTerminalGridSize().rows)) {
            if (self.d3d_renderer) |*r| r.invalidate();
        }
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
        const track_h = client_h - self.TAB_BAR_HEIGHT - 2 * self.TERMINAL_PADDING;
        if (track_h <= 0) return;

        const rel_y = @max(0, mouse_y - self.TAB_BAR_HEIGHT - self.TERMINAL_PADDING);
        const track_hf = @as(f64, @floatFromInt(track_h));
        const ratio_px = track_hf / @as(f64, @floatFromInt(sb.total));
        // Must match the renderer's `scrollbar_min_thumb_h` so the thumb the
        // user clicks covers the same Y range the drag math walks over.
        const min_thumb: f64 = @floatFromInt(self.SCROLLBAR_MIN_THUMB_H);
        const thumb_h = @max(min_thumb, ratio_px * @as(f64, @floatFromInt(sb.len)));
        const available = track_hf - thumb_h;
        if (available <= 0) return;
        const clamped_y = @min(@as(f64, @floatFromInt(rel_y)), available);
        const scroll_ratio = clamped_y / available;
        const target_row: usize = @intFromFloat(scroll_ratio * @as(f64, @floatFromInt(sb.total - sb.len)));

        // delta = target - current offset
        const current: isize = @intCast(sb.offset);
        const target: isize = @intCast(target_row);
        const delta = target - current;
        if (delta != 0) {
            tab.terminal.scrollViewport(.{ .delta = delta });
            if (self.d3d_renderer) |*r| r.invalidate();
        }
    }

    pub fn handleTabClick(self: *App, mouse_x: c_int, mouse_y: c_int) void {
        if (mouse_y >= self.TAB_BAR_HEIGHT) return; // Below tab bar
        if (self.session.count() == 0) return;

        const tab_index_raw = @divTrunc(mouse_x, self.TAB_WIDTH);
        if (tab_index_raw < 0) return;
        const tab_index: usize = @intCast(tab_index_raw);
        if (tab_index >= self.session.count()) return;

        // Check if click is on close button
        const tab_x = @as(c_int, @intCast(tab_index)) * self.TAB_WIDTH;
        const close_x = tab_x + self.TAB_WIDTH - self.CLOSE_BTN_SIZE - self.TAB_PADDING;
        const close_y = @divTrunc(self.TAB_BAR_HEIGHT - self.CLOSE_BTN_SIZE, 2);
        if (mouse_x >= close_x and mouse_x <= close_x + self.CLOSE_BTN_SIZE and
            mouse_y >= close_y and mouse_y <= close_y + self.CLOSE_BTN_SIZE)
        {
            self.closeTab(tab_index);
            return;
        }

        if (self.session.setActiveTab(tab_index)) {
            if (self.d3d_renderer) |*r| r.invalidate();
        }
    }

    pub fn handleDragStart(self: *App, mouse_x: c_int) void {
        self.dragging = false;
        const idx_raw = @divTrunc(mouse_x, self.TAB_WIDTH);
        if (idx_raw < 0) return;
        const idx: usize = @intCast(idx_raw);
        if (idx >= self.session.count()) return;
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
        if (self.dragging and self.session.count() > 1 and self.drag_tab_index < self.session.count()) {
            var target_raw = @divTrunc(self.drag_current_x, self.TAB_WIDTH);
            target_raw = @max(0, @min(target_raw, @as(c_int, @intCast(self.session.count() - 1))));
            const target: usize = @intCast(target_raw);
            if (target != self.drag_tab_index) {
                if (self.session.reorderTabs(self.drag_tab_index, target) catch false) {
                    if (self.d3d_renderer) |*r| r.invalidate();
                }
            }
        }
        self.dragging = false;
    }

    fn startRename(self: *App, tab_index: usize) void {
        const tab = self.session.tabAt(tab_index) orelse return;
        self.renaming_tab = tab_index;
        @memcpy(self.rename_buf[0..tab.title_len], tab.title[0..tab.title_len]);
        self.rename_len = tab.title_len;
        self.rename_cursor = tab.title_len;
        if (self.d3d_renderer) |*r| r.invalidate();
    }

    fn commitRename(self: *App) void {
        const idx = self.renaming_tab orelse return;
        if (self.rename_len > 0) {
            const tab = self.session.tabAt(idx) orelse {
                self.renaming_tab = null;
                return;
            };
            tab.setCustomTitle(self.rename_buf[0..self.rename_len]);
        }
        self.renaming_tab = null;
        if (self.d3d_renderer) |*r| r.invalidate();
    }

    fn cancelRename(self: *App) void {
        self.renaming_tab = null;
        if (self.d3d_renderer) |*r| r.invalidate();
    }

    fn handleRenameChar(self: *App, cp: u21) void {
        if (self.renaming_tab == null) return;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return;
        if (self.rename_len + len > 63) return; // keep within buffer
        // Shift right to make room at cursor
        if (self.rename_cursor < self.rename_len) {
            std.mem.copyBackwards(u8, self.rename_buf[self.rename_cursor + len .. self.rename_len + len], self.rename_buf[self.rename_cursor..self.rename_len]);
        }
        @memcpy(self.rename_buf[self.rename_cursor .. self.rename_cursor + len], buf[0..len]);
        self.rename_len += len;
        self.rename_cursor += len;
        if (self.d3d_renderer) |*r| r.invalidate();
    }

    fn handleRenameKey(self: *App, vk: usize) bool {
        if (self.renaming_tab == null) return false;
        const vk_return: usize = 0x0D;
        const vk_escape: usize = 0x1B;
        const vk_back: usize = 0x08;
        const vk_left: usize = 0x25;
        const vk_right: usize = 0x27;
        const vk_home: usize = 0x24;
        const vk_end: usize = 0x23;
        const vk_delete: usize = 0x2E;

        switch (vk) {
            vk_return => self.commitRename(),
            vk_escape => self.cancelRename(),
            vk_back => {
                if (self.rename_cursor > 0) {
                    // Find start of previous UTF-8 char
                    var prev = self.rename_cursor - 1;
                    while (prev > 0 and self.rename_buf[prev] & 0xC0 == 0x80) prev -= 1;
                    const char_len = self.rename_cursor - prev;
                    std.mem.copyForwards(u8, self.rename_buf[prev .. self.rename_len - char_len], self.rename_buf[self.rename_cursor..self.rename_len]);
                    self.rename_len -= char_len;
                    self.rename_cursor = prev;
                    if (self.d3d_renderer) |*r| r.invalidate();
                }
            },
            vk_delete => {
                if (self.rename_cursor < self.rename_len) {
                    // Find length of current UTF-8 char
                    const b = self.rename_buf[self.rename_cursor];
                    const char_len: usize = if (b < 0x80) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
                    const end = @min(self.rename_cursor + char_len, self.rename_len);
                    const actual_len = end - self.rename_cursor;
                    std.mem.copyForwards(u8, self.rename_buf[self.rename_cursor .. self.rename_len - actual_len], self.rename_buf[end..self.rename_len]);
                    self.rename_len -= actual_len;
                    if (self.d3d_renderer) |*r| r.invalidate();
                }
            },
            vk_left => {
                if (self.rename_cursor > 0) {
                    self.rename_cursor -= 1;
                    while (self.rename_cursor > 0 and self.rename_buf[self.rename_cursor] & 0xC0 == 0x80) self.rename_cursor -= 1;
                    if (self.d3d_renderer) |*r| r.invalidate();
                }
            },
            vk_right => {
                if (self.rename_cursor < self.rename_len) {
                    const b = self.rename_buf[self.rename_cursor];
                    const char_len: usize = if (b < 0x80) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
                    self.rename_cursor = @min(self.rename_cursor + char_len, self.rename_len);
                    if (self.d3d_renderer) |*r| r.invalidate();
                }
            },
            vk_home => {
                self.rename_cursor = 0;
                if (self.d3d_renderer) |*r| r.invalidate();
            },
            vk_end => {
                self.rename_cursor = self.rename_len;
                if (self.d3d_renderer) |*r| r.invalidate();
            },
            else => return false,
        }
        return true;
    }

    fn mouseToCell(self: *const App, mouse_x: c_int, mouse_y: c_int) struct { col: u16, row: u16 } {
        const cw = self.window.cell_width;
        const ch = self.window.cell_height;
        const grid = self.getTerminalGridSize();
        const term_x = mouse_x - self.TERMINAL_PADDING;
        const term_y = mouse_y - self.TAB_BAR_HEIGHT - self.TERMINAL_PADDING;
        const col: u16 = if (cw > 0 and term_x >= 0) @intCast(@min(@divTrunc(term_x, cw), @as(c_int, grid.cols) - 1)) else 0;
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
        const term_y = mouse_y - self.TAB_BAR_HEIGHT - self.TERMINAL_PADDING;
        var client_h: c_int = 0;
        if (self.window.hwnd) |hwnd| {
            var rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            _ = GetClientRect(hwnd, &rect);
            client_h = rect.bottom;
        }
        const term_h = client_h - self.TAB_BAR_HEIGHT - 2 * self.TERMINAL_PADDING;
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

    fn onAppEvent(event: app_event.Event, userdata: ?*anyopaque) bool {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        switch (event) {
            .text_input => |cp| {
                if (self.renaming_tab != null) {
                    if (cp >= 0x20) { // printable characters only
                        self.handleRenameChar(cp);
                    }
                    return true;
                }
                return false;
            },
            .key_input => |key| {
                const vk: usize = switch (key) {
                    .enter => 0x0D,
                    .escape => 0x1B,
                    .backspace => 0x08,
                    .left => 0x25,
                    .right => 0x27,
                    .home => 0x24,
                    .end => 0x23,
                    .delete => 0x2E,
                };
                if (self.handleRenameKey(vk)) return true;
                if (self.renaming_tab != null) return true; // swallow rename editing keys
                return false;
            },
            .shortcut => |shortcut| {
                switch (shortcut) {
                    .new_tab => {
                        self.handleNewTab();
                        return true;
                    },
                    .close_active_tab => {
                        self.handleCloseActiveTab();
                        return true;
                    },
                    .reset_terminal => {
                        if (self.session.resetActive()) {
                            if (self.d3d_renderer) |*r| r.invalidate();
                        }
                        return true;
                    },
                    .dump_perf => {
                        perf.dumpAndReset("snapshot");
                        return true;
                    },
                    .show_about => {
                        about.showAboutDialog(self.window.hwnd);
                        return true;
                    },
                    .switch_tab => |index| {
                        self.handleSwitchTab(index);
                        return true;
                    },
                }
            },
            .mouse_down => |mouse| {
                if (self.renaming_tab != null) self.commitRename();
                if (mouse.y < self.TAB_BAR_HEIGHT) {
                    self.tab_drag_active = true;
                    self.selecting = false;
                    self.scrollbar_dragging = false;
                    self.handleTabClick(mouse.x, mouse.y);
                    self.handleDragStart(mouse.x);
                    return true;
                }
                var client_w: c_int = 0;
                if (self.window.hwnd) |hwnd| {
                    var rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
                    _ = GetClientRect(hwnd, &rect);
                    client_w = rect.right;
                }
                if (mouse.x >= client_w - self.SCROLLBAR_W) {
                    self.scrollbar_dragging = true;
                    self.tab_drag_active = false;
                    self.selecting = false;
                    self.scrollToY(mouse.y);
                    return true;
                }
                self.tab_drag_active = false;
                self.scrollbar_dragging = false;
                self.startTerminalSelection(mouse.x, mouse.y);
                return true;
            },
            .mouse_double_click => |mouse| {
                if (mouse.y < self.TAB_BAR_HEIGHT) {
                    const tab_index_raw = @divTrunc(mouse.x, self.TAB_WIDTH);
                    if (tab_index_raw >= 0) {
                        const tab_index: usize = @intCast(tab_index_raw);
                        if (tab_index < self.session.count()) {
                            self.startRename(tab_index);
                        }
                    }
                } else {
                    self.selectWordAt(mouse.x, mouse.y);
                }
                return true;
            },
            .mouse_move => |mouse| {
                if (mouse.left_button) {
                    if (self.scrollbar_dragging) {
                        self.scrollToY(mouse.y);
                    } else if (self.tab_drag_active) {
                        self.handleDragMove(mouse.x);
                    } else if (self.selecting) {
                        self.updateTerminalSelection(mouse.x, mouse.y);
                    }
                }
                return true;
            },
            .mouse_up => |_| {
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
            .scroll => |scroll_event| {
                self.handleScroll(scroll_event);
                return true;
            },
            .tab_closed => |tab_ptr| {
                self.handleTabClosed(tab_ptr);
                return true;
            },
        }
    }
};

/// ReleaseFast에서도 crash 원인을 표시하는 panic handler
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    var buf: [512]u8 = undefined;
    const addr = ret_addr orelse @returnAddress();
    const text = std.fmt.bufPrint(&buf, "panic: {s}\nreturn address: 0x{x}", .{ msg, addr }) catch "panic (format failed)";
    var msgbuf: [512:0]u8 = std.mem.zeroes([512:0]u8);
    const copy_len = @min(text.len, 511);
    @memcpy(msgbuf[0..copy_len], text[0..copy_len]);
    _ = MessageBoxA(null, &msgbuf, "TildaZ Crash", MB_OK | MB_ICONERROR);
    std.process.exit(1);
}

pub fn main() void {
    run() catch |err| {
        tildaz_log.appendLine("fatal", "run failed: {s}", .{@errorName(err)});
        const msg = std.unicode.utf8ToUtf16LeStringLiteral("TildaZ 실행 중 오류가 발생했습니다.");
        const title = std.unicode.utf8ToUtf16LeStringLiteral("TildaZ Error");
        _ = MessageBoxW(null, msg, title, MB_OK | MB_ICONERROR);
    };
}

fn run() !void {
    perf.init();

    // Enable per-monitor DPI awareness (must be before any window/GDI calls)
    _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

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

    // %APPDATA%\tildaz\tildaz.log 에 부팅 / 종료 라인을 남긴다.
    // stale exe 가 자동 실행되는 케이스를 사후 추적하기 위한 감사 로그.
    tildaz_log.logStart(build_options.version);
    defer tildaz_log.logStop(build_options.version);

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
    tildaz_log.appendLine("startup", "config loaded: hidden_start={} auto_start={} shell={s}", .{
        config.hidden_start,
        config.auto_start,
        config.shell,
    });

    if (config.auto_start) {
        autostart.enable() catch |err| {
            tildaz_log.appendLine("autostart", "enable failed: {s}", .{@errorName(err)});
        };
    } else {
        autostart.disable();
    }

    var app = App{
        .session = undefined,
        .window = .{},
        .allocator = alloc,
    };
    app.session = SessionCore.init(
        alloc,
        config.shellUtf16(),
        config.max_scroll_lines,
        config.theme,
        App.onSessionTabExit,
        &app,
    );
    defer app.session.deinit();

    // Set up window
    app.window.userdata = &app;
    app.window.write_fn = App.onKeyInput;
    app.window.render_fn = App.onRender;
    app.window.resize_fn = App.onResize;
    app.window.font_change_fn = App.onFontChange;
    app.window.app_event_fn = App.onAppEvent;
    const DWriteFontCtx = @import("dwrite_font.zig").DWriteFontContext;

    // Validate all font families exist on the system
    for (0..config.font_family_count) |i| {
        const idx: u8 = @intCast(i);
        const fam_w = config.fontFamilyUtf16(idx);
        if (!DWriteFontCtx.isFontAvailable(fam_w)) {
            var msg_buf: [256]WCHAR = undefined;
            var pos: usize = 0;
            const prefix = std.unicode.utf8ToUtf16LeStringLiteral("Font not found: \"");
            for (prefix[0..17]) |c| {
                if (pos < msg_buf.len - 2) {
                    msg_buf[pos] = c;
                    pos += 1;
                }
            }
            const fam = config.font_families[i];
            for (fam) |c| {
                if (pos < msg_buf.len - 2) {
                    msg_buf[pos] = c;
                    pos += 1;
                }
            }
            msg_buf[pos] = '"';
            pos += 1;
            msg_buf[pos] = 0;
            _ = MessageBoxW(null, @ptrCast(&msg_buf), std.unicode.utf8ToUtf16LeStringLiteral("TildaZ Config Error"), MB_OK | MB_ICONERROR);
            return;
        }
    }

    const font_family_w = config.fontFamilyUtf16(0);
    const font_size: c_int = @intCast(config.font_size);
    try app.window.init(font_family_w, font_size, config.opacity, config.cell_width, config.line_height);
    tildaz_log.appendLine("startup", "window initialized: dpi={d} cell={}x{}", .{
        app.window.current_dpi,
        app.window.cell_width,
        app.window.cell_height,
    });
    defer app.window.deinit();

    // Scale tab bar / scrollbar / padding constants by the startup DPI.
    // The same computation runs again via `App.onFontChange` whenever the
    // window moves to a monitor with a different DPI.
    app.applyDpiScale(GetDpiForWindow(app.window.hwnd));

    // Initialize D3D11 renderer
    const theme_bg: ?[3]u8 = if (config.theme) |t| .{ t.background.r, t.background.g, t.background.b } else null;
    app.d3d_renderer = D3d11Renderer.init(alloc, app.window.hwnd, font_family_w, font_size, @intCast(app.window.cell_width), @intCast(app.window.cell_height), theme_bg) catch |err| blk: {
        tildaz_log.appendLine("startup", "renderer disabled: {s}", .{@errorName(err)});
        break :blk null;
    };
    tildaz_log.appendLine("startup", "renderer active={}", .{app.d3d_renderer != null});
    defer if (app.d3d_renderer) |*r| r.deinit();

    // Apply position from config
    app.window.setPosition(config.dock_position, config.width, config.height, config.offset);

    // Create initial tab
    try app.createTab();
    tildaz_log.appendLine("startup", "initial tab created: count={d}", .{app.session.count()});

    if (!config.hidden_start) {
        tildaz_log.appendLine("startup", "show window", .{});
        app.window.show();
    }
    tildaz_log.appendLine("startup", "enter message loop", .{});
    app.window.messageLoop();
    tildaz_log.appendLine("startup", "message loop exited", .{});
}
