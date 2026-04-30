const std = @import("std");
const ghostty = @import("ghostty-vt");
const app_event = @import("app_event.zig");
const session_core = @import("session_core.zig");
const SessionCore = session_core.SessionCore;
const SessionTab = session_core.Tab;
const tab_interaction = @import("tab_interaction.zig");
const terminal_interaction = @import("terminal_interaction.zig");
const Window = @import("window.zig").Window;
const renderer_backend = @import("renderer_backend.zig");
const RendererBackend = renderer_backend.RendererBackend;
const perf = @import("perf.zig");
const tildaz_log = @import("tildaz_log.zig");
const about = @import("about.zig");
const ui_metrics = @import("ui_metrics.zig");

pub const App = struct {
    session: SessionCore,
    window: Window,
    allocator: std.mem.Allocator,
    renderer: ?RendererBackend = null,
    last_render_ms: i64 = 0,
    tab_interaction: tab_interaction.TabInteraction = .{},
    terminal_interaction: terminal_interaction.TerminalInteraction = .{},

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
    // hit-test / drag math in App.
    SCROLLBAR_MIN_THUMB_H: c_int = 32,
    TERMINAL_PADDING: c_int = 6,

    pub fn createTab(self: *App) !void {
        const grid = self.getTerminalGridSize();
        try self.session.createTab(grid.cols, grid.rows);
        self.invalidateRenderer();
    }

    fn invalidateRenderer(self: *App) void {
        if (self.renderer) |*r| r.invalidate();
    }

    fn handleCloseResult(self: *App, result: SessionCore.CloseResult) void {
        switch (result) {
            .none => return,
            .closed_last => {
                tildaz_log.appendLine("tab", "마지막 탭 종료: 창 닫기 요청", .{});
                self.window.closeAfterShellExit();
            },
            .changed => self.invalidateRenderer(),
        }
    }

    fn closeTab(self: *App, index: usize) void {
        self.handleCloseResult(self.session.closeTab(index));
    }

    fn getTerminalGridSize(self: *const App) struct { cols: u16, rows: u16 } {
        if (self.window.hwnd == null) return .{ .cols = 120, .rows = 30 };
        const size = self.window.getClientSize();
        const w = size.w - 2 * self.TERMINAL_PADDING;
        const h = size.h - self.TAB_BAR_HEIGHT - 2 * self.TERMINAL_PADDING;
        const cols: u16 = if (self.window.cell_width > 0) @intCast(@max(1, @divTrunc(@max(w, 1), self.window.cell_width))) else 120;
        const rows: u16 = if (self.window.cell_height > 0) @intCast(@max(1, @divTrunc(@max(h, 1), self.window.cell_height))) else 30;
        return .{ .cols = cols, .rows = rows };
    }

    fn activeTabPtr(self: *App) ?*SessionTab {
        return self.session.activeTab();
    }

    pub fn onSessionTabExit(tab_ptr: usize, userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        self.window.postTabClosed(tab_ptr);
    }

    // --- Window callbacks (userdata = *App) ---

    pub fn onKeyInput(data: []const u8, userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        self.session.queueInputToActive(data);
    }

    pub fn onResize(_: u16, _: u16, userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        if (self.renderer) |*r| {
            const size = self.window.getClientSize();
            r.resize(@intCast(@max(1, size.w)), @intCast(@max(1, size.h)));
        }
        const grid = self.getTerminalGridSize();
        self.session.resizeAll(grid.cols, grid.rows);
    }

    /// Recompute DPI-dependent UI constants (tab bar / close button / padding /
    /// scrollbar) from `new_dpi`. Called at startup and whenever the window
    /// moves between monitors with different DPI scales.
    pub fn applyDpiScale(self: *App, new_dpi: c_uint) void {
        const effective: f32 = if (new_dpi > 0) @as(f32, @floatFromInt(new_dpi)) else 96.0;
        const scale: f32 = effective / 96.0;
        self.dpi_scale = scale;
        self.TAB_BAR_HEIGHT = @intFromFloat(@round(28.0 * scale));
        self.TAB_WIDTH = @intFromFloat(@round(150.0 * scale));
        self.CLOSE_BTN_SIZE = @intFromFloat(@round(14.0 * scale));
        self.TAB_PADDING = @intFromFloat(@round(6.0 * scale));
        self.SCROLLBAR_W = @intFromFloat(@round(@as(f32, @floatFromInt(ui_metrics.SCROLLBAR_W_PT)) * scale));
        self.SCROLLBAR_MIN_THUMB_H = @intFromFloat(@round(@as(f32, @floatFromInt(ui_metrics.SCROLLBAR_MIN_THUMB_H_PT)) * scale));
        self.TERMINAL_PADDING = @intFromFloat(@round(@as(f32, @floatFromInt(ui_metrics.TERMINAL_PADDING_PT)) * scale));
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
    pub fn onFontChange(window: *Window, userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        if (self.renderer) |*r| {
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

    pub fn onRender(window: *Window) void {
        const self: *App = @ptrCast(@alignCast(window.userdata.?));
        const onrender_t0 = perf.now();
        defer perf.addTimed(&perf.onrender, onrender_t0);

        if (self.renderer) |*r| {
            const size = window.getClientSize();

            // VT 처리 (UI 스레드에서 — mutex 경합 없음)
            const should_render = self.session.prepareActiveFrame(&self.last_render_ms);

            if (should_render) {
                // 탭바 + 터미널 함께 렌더 (glClear는 renderTabBar에 포함)
                var tab_titles: [32]renderer_backend.TabTitle = undefined;
                const tabs = self.session.tabsSlice();
                const n = @min(tabs.len, 32);
                for (tabs[0..n], 0..) |t, i| {
                    tab_titles[i] = .{ .ptr = &t.title, .len = t.title_len };
                }
                const rs: ?renderer_backend.RenameState = if (self.tab_interaction.rename.view()) |rename| .{
                    .tab_index = rename.tab_index,
                    .text = rename.text,
                    .text_len = rename.text_len,
                    .cursor = rename.cursor,
                } else null;
                const drag = self.tab_interaction.drag.view();
                r.renderTabBar(
                    tab_titles[0..n],
                    self.session.activeIndex(),
                    self.TAB_BAR_HEIGHT,
                    size.w,
                    size.h,
                    self.TAB_WIDTH,
                    self.CLOSE_BTN_SIZE,
                    self.TAB_PADDING,
                    if (drag) |d| d.tab_index else null,
                    if (drag) |d| d.current_x else 0,
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
        self.handleCloseResult(self.session.closeTabByPtr(tab_ptr));
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
            self.invalidateRenderer();
        }
    }

    pub fn handleScroll(self: *App, event: app_event.ScrollEvent) void {
        if (self.session.scrollActive(event, self.getTerminalGridSize().rows)) {
            self.invalidateRenderer();
        }
    }

    fn scrollToY(self: *App, mouse_y: c_int) void {
        const tab = self.activeTabPtr() orelse return;
        const screen = tab.terminal.screens.active;
        const sb = screen.pages.scrollbar();
        if (sb.total <= sb.len) return;

        // 터미널 영역 내 Y 비율 → 스크롤 위치
        if (self.window.hwnd == null) return;
        const client_h = self.window.getClientSize().h;
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
            self.invalidateRenderer();
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
            self.invalidateRenderer();
        }
    }

    pub fn handleDragStart(self: *App, mouse_x: c_int) void {
        _ = self.tab_interaction.drag.begin(mouse_x, self.TAB_WIDTH, self.session.count());
    }

    pub fn handleDragMove(self: *App, mouse_x: c_int) void {
        _ = self.tab_interaction.drag.move(mouse_x);
    }

    pub fn handleDragEnd(self: *App) void {
        if (self.tab_interaction.drag.finish(self.TAB_WIDTH, self.session.count())) |request| {
            if (self.session.reorderTabs(request.from, request.to) catch false) {
                self.invalidateRenderer();
            }
        }
    }

    fn startRename(self: *App, tab_index: usize) void {
        const tab = self.session.tabAt(tab_index) orelse return;
        self.tab_interaction.rename.begin(tab_index, tab.title[0..tab.title_len]);
        self.invalidateRenderer();
    }

    fn commitRename(self: *App) void {
        const request = self.tab_interaction.rename.commitRequest() orelse return;
        if (request.title.len > 0) {
            if (self.session.tabAt(request.tab_index)) |tab| {
                tab.setCustomTitle(request.title);
            }
        }
        self.tab_interaction.rename.clear();
        self.invalidateRenderer();
    }

    fn cancelRename(self: *App) void {
        self.tab_interaction.rename.clear();
        self.invalidateRenderer();
    }

    fn handleRenameChar(self: *App, cp: u21) void {
        if (self.tab_interaction.rename.insertCodepoint(cp)) {
            self.invalidateRenderer();
        }
    }

    fn handleRenameKey(self: *App, key: app_event.KeyInput) bool {
        const rename_key: tab_interaction.RenameKey = switch (key) {
            .enter => .enter,
            .escape => .escape,
            .backspace => .backspace,
            .left => .left,
            .right => .right,
            .home => .home,
            .end => .end,
            .delete => .delete,
        };

        switch (self.tab_interaction.rename.handleKey(rename_key)) {
            .none => return false,
            .changed => self.invalidateRenderer(),
            .commit => self.commitRename(),
            .cancel => self.cancelRename(),
        }
        return true;
    }

    fn isRenaming(self: *const App) bool {
        return self.tab_interaction.rename.isActive();
    }

    fn mouseToCell(self: *const App, mouse_x: c_int, mouse_y: c_int) terminal_interaction.Cell {
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

        if (self.activeTabPtr()) |tab| {
            const screen: *ghostty.Screen = tab.terminal.screens.active;
            self.terminal_interaction.selection.begin(screen, cell);
        }
    }

    fn updateTerminalSelection(self: *App, mouse_x: c_int, mouse_y: c_int) void {
        if (!self.terminal_interaction.selection.active) return;
        const tab = self.activeTabPtr() orelse return;

        // 터미널 영역 위/아래로 드래그 시 자동 스크롤
        const term_y = mouse_y - self.TAB_BAR_HEIGHT - self.TERMINAL_PADDING;
        if (self.window.hwnd == null) return;
        const client_h = self.window.getClientSize().h;
        const term_h = client_h - self.TAB_BAR_HEIGHT - 2 * self.TERMINAL_PADDING;
        if (term_y < 0) {
            tab.terminal.scrollViewport(.{ .delta = -3 });
        } else if (term_y > term_h) {
            tab.terminal.scrollViewport(.{ .delta = 3 });
        }

        const cell = self.mouseToCell(mouse_x, mouse_y);
        const screen: *ghostty.Screen = tab.terminal.screens.active;
        self.terminal_interaction.selection.update(screen, cell);
    }

    fn finishTerminalSelection(self: *App) void {
        if (!self.terminal_interaction.selection.finish()) return;

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
        if (!terminal_interaction.selectWord(screen, cell)) return;

        // Copy word to clipboard
        const sel = screen.selection orelse return;
        const text = screen.selectionString(self.allocator, .{ .sel = sel }) catch return;
        defer self.allocator.free(text);
        if (text.len > 0) {
            self.window.copyToClipboard(text);
        }
    }

    pub fn onAppEvent(event: app_event.Event, userdata: ?*anyopaque) bool {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        switch (event) {
            .text_input => |cp| {
                if (self.isRenaming()) {
                    if (cp >= 0x20) { // printable characters only
                        self.handleRenameChar(cp);
                    }
                    return true;
                }
                return false;
            },
            .key_input => |key| {
                if (self.handleRenameKey(key)) return true;
                if (self.isRenaming()) return true; // swallow rename editing keys
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
                            self.invalidateRenderer();
                        }
                        return true;
                    },
                    .dump_perf => {
                        perf.dumpAndReset("snapshot");
                        return true;
                    },
                    .show_about => {
                        about.showAboutDialog();
                        return true;
                    },
                    .switch_tab => |index| {
                        self.handleSwitchTab(index);
                        return true;
                    },
                }
            },
            .mouse_down => |mouse| {
                if (self.isRenaming()) self.commitRename();
                if (mouse.y < self.TAB_BAR_HEIGHT) {
                    self.terminal_interaction.cancelPointerModes();
                    self.handleTabClick(mouse.x, mouse.y);
                    self.handleDragStart(mouse.x);
                    return true;
                }
                const client_w = self.window.getClientSize().w;
                if (mouse.x >= client_w - self.SCROLLBAR_W) {
                    self.terminal_interaction.scrollbar.begin();
                    self.tab_interaction.drag.reset();
                    self.terminal_interaction.selection.cancel();
                    self.scrollToY(mouse.y);
                    return true;
                }
                self.tab_interaction.drag.reset();
                self.terminal_interaction.scrollbar.end();
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
                    if (self.terminal_interaction.scrollbar.active) {
                        self.scrollToY(mouse.y);
                    } else if (self.tab_interaction.drag.active) {
                        self.handleDragMove(mouse.x);
                    } else if (self.terminal_interaction.selection.active) {
                        self.updateTerminalSelection(mouse.x, mouse.y);
                    }
                }
                return true;
            },
            .mouse_up => |_| {
                if (self.terminal_interaction.scrollbar.active) {
                    self.terminal_interaction.scrollbar.end();
                } else if (self.tab_interaction.drag.active) {
                    self.handleDragEnd();
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
