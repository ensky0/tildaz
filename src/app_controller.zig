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
const paths = @import("paths.zig");
const system_open = @import("system_open.zig");
const dialog = @import("dialog.zig");
const messages = @import("messages.zig");

pub const App = struct {
    session: SessionCore,
    window: Window,
    allocator: std.mem.Allocator,
    renderer: ?RendererBackend = null,
    last_render_ms: i64 = 0,
    tab_interaction: tab_interaction.TabInteraction = .{},
    terminal_interaction: terminal_interaction.TerminalInteraction = .{},

    /// 탭바 스크롤 오프셋 (픽셀, #117). 탭바 총 너비 (`count × TAB_WIDTH`) 가
    /// 윈도우 너비를 초과하면 활성 탭이 보이도록 viewport 자동 이동. 매 frame
    /// `onRender` 에서 `ensureActiveTabVisible` 가 갱신 — drag 중일 때만 skip
    /// (`handleDragMove` 가 자체 auto-scroll 로 직접 갱신).
    tab_scroll_x: c_int = 0,
    /// 사용자가 `<` / `>` 화살표를 직접 눌러 viewport 를 옮긴 상태 (#117). 이
    /// 동안에는 `ensureActiveTabVisible` 호출 안 함 — 활성 탭이 viewport 밖으로
    /// 가려져도 그대로 (Firefox 패턴). 활성 탭 변경 / drag reorder 끝 / 새 탭
    /// 생성 시 false 로 리셋 → 그 시점부터 다시 ensure 동작.
    tab_scroll_user_override: bool = false,

    // DPI-scaled values (initialized in run())
    dpi_scale: f32 = 1.0,
    TAB_BAR_HEIGHT: c_int = 28,
    TAB_WIDTH: c_int = 150,
    TAB_ARROW_W: c_int = 28,
    TAB_PLUS_W: c_int = 28,
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
        const before: usize = self.session.count();
        const grid = self.getTerminalGridSize();
        try self.session.createTab(grid.cols, grid.rows);
        // 1 → 2 전환에서 탭바가 새로 나타나며 cell 영역이 줄어든다 (#127).
        // 새 grid 로 모든 탭 동기화. 다른 count 변화는 그대로.
        if (before == 1) {
            const new_grid = self.getTerminalGridSize();
            self.session.resizeAll(new_grid.cols, new_grid.rows);
        }
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
            .changed => {
                // 2 → 1 전환에서 탭바가 사라지며 cell 영역이 늘어난다 (#127).
                if (self.session.count() == 1) {
                    const grid = self.getTerminalGridSize();
                    self.session.resizeAll(grid.cols, grid.rows);
                }
                self.invalidateRenderer();
            },
        }
    }

    fn closeTab(self: *App, index: usize) void {
        self.handleCloseResult(self.session.closeTab(index));
    }

    /// 탭이 1개 이하면 탭바 자체를 그리지 않으므로 layout 에서도 0 으로 취급
    /// (#127). count 가 1↔2 로 바뀌면 createTab / handleCloseResult 가 즉시
    /// resizeAll 을 호출해 모든 탭 grid 동기화.
    fn effectiveTabBarHeight(self: *const App) c_int {
        return if (self.session.count() > 1) self.TAB_BAR_HEIGHT else 0;
    }

    fn tabBarTotalWidth(self: *const App) c_int {
        return @as(c_int, @intCast(self.session.count())) * self.TAB_WIDTH;
    }

    /// 탭바 layout 계산 (#117 Firefox 패턴). `<` / `>` 화살표 + `+` 버튼이
    /// 탭 viewport 영역을 양쪽에서 깎음. 클릭 hit-test / 렌더 / scroll 보정
    /// 모두 같은 layout 사용해야 일관.
    pub const TabBarLayout = struct {
        tab_area_x: c_int,
        tab_area_w: c_int,
        arrows_visible: bool,
        arrow_w: c_int,
        plus_w: c_int,
        plus_x: c_int,
        left_arrow_x: c_int = 0, // arrows_visible 일 때 의미 있음
        right_arrow_x: c_int = 0,
        left_enabled: bool = false,
        right_enabled: bool = false,
    };

    fn tabBarLayout(self: *const App) TabBarLayout {
        const vp = self.window.getClientSize().w;
        const total = self.tabBarTotalWidth();
        const gap: c_int = @intFromFloat(@round(@as(f32, @floatFromInt(ui_metrics.TAB_CTRL_GAP_PT)) * self.dpi_scale));
        // 탭바 총 너비 + plus_w + gap 이 vp 를 넘으면 화살표 등장.
        const arrows_visible = total + self.TAB_PLUS_W + gap > vp;
        if (!arrows_visible) {
            return .{
                .tab_area_x = 0,
                .tab_area_w = @max(0, vp - self.TAB_PLUS_W - gap),
                .arrows_visible = false,
                .arrow_w = self.TAB_ARROW_W,
                .plus_w = self.TAB_PLUS_W,
                .plus_x = total + gap, // 마지막 탭 옆 (gap)
            };
        }
        // layout: `[<][gap][tabs][gap][+][>]` — 양 끝 화살표, `+` 는 `>` 바로
        // 왼쪽 안쪽. 박스 사이 gap 으로 시각 분리.
        const tab_area_x = self.TAB_ARROW_W + gap;
        const tab_area_w = @max(0, vp - self.TAB_ARROW_W * 2 - self.TAB_PLUS_W - gap * 2);
        const right_arrow_x = vp - self.TAB_ARROW_W;
        const plus_x = right_arrow_x - self.TAB_PLUS_W;
        const left_enabled = self.tab_scroll_x > 0;
        const right_enabled = self.tab_scroll_x + tab_area_w < total;
        return .{
            .tab_area_x = tab_area_x,
            .tab_area_w = tab_area_w,
            .arrows_visible = true,
            .arrow_w = self.TAB_ARROW_W,
            .plus_w = self.TAB_PLUS_W,
            .plus_x = plus_x,
            .left_arrow_x = 0,
            .right_arrow_x = right_arrow_x,
            .left_enabled = left_enabled,
            .right_enabled = right_enabled,
        };
    }

    /// 활성 탭이 viewport 안에 보이도록 `tab_scroll_x` 갱신 (#117). 정책 (b):
    /// 이미 보이면 그대로, 안 보일 때만 보이는 가장 가까운 위치로 minimum 이동.
    /// 양 끝 clamp 로 viewport 가 비는 일 없음. drag 중 / 사용자 화살표 override
    /// 중에는 호출 안 함.
    fn ensureActiveTabVisible(self: *App) void {
        const n = self.session.count();
        if (n == 0) {
            self.tab_scroll_x = 0;
            return;
        }
        const total = self.tabBarTotalWidth();
        const layout = self.tabBarLayout();
        const vp = layout.tab_area_w;
        if (vp <= 0 or total <= vp) {
            self.tab_scroll_x = 0;
            return;
        }
        const active = @as(c_int, @intCast(self.session.activeIndex()));
        const tab_l = active * self.TAB_WIDTH;
        const tab_r = tab_l + self.TAB_WIDTH;
        var sx = self.tab_scroll_x;
        if (tab_l < sx) {
            sx = tab_l;
        } else if (tab_r > sx + vp) {
            sx = tab_r - vp;
        }
        const max_sx = total - vp;
        if (sx < 0) sx = 0;
        if (sx > max_sx) sx = max_sx;
        self.tab_scroll_x = sx;
    }

    /// 화살표 클릭으로 viewport 한 step (= 1 탭 너비) 이동 (#117). 양 끝 clamp.
    /// `tab_scroll_user_override = true` 로 ensure 잠시 비활성 → 활성 탭 변경
    /// 시 다시 활성.
    fn scrollTabsByArrow(self: *App, dir: enum { left, right }) void {
        const total = self.tabBarTotalWidth();
        const layout = self.tabBarLayout();
        const vp = layout.tab_area_w;
        if (vp <= 0 or total <= vp) return;
        const max_sx = total - vp;
        const step = self.TAB_WIDTH;
        var sx = self.tab_scroll_x;
        switch (dir) {
            .left => sx = @max(0, sx - step),
            .right => sx = @min(max_sx, sx + step),
        }
        if (sx == self.tab_scroll_x) return;
        self.tab_scroll_x = sx;
        self.tab_scroll_user_override = true;
        self.invalidateRenderer();
    }

    fn getTerminalGridSize(self: *const App) struct { cols: u16, rows: u16 } {
        if (self.window.hwnd == null) return .{ .cols = 120, .rows = 30 };
        const size = self.window.getClientSize();
        const w = size.w - 2 * self.TERMINAL_PADDING;
        const h = size.h - self.effectiveTabBarHeight() - 2 * self.TERMINAL_PADDING;
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

    /// Alt+F4 / 시스템 close — confirm 다이얼로그 (#116). true 반환 = 종료
    /// 진행, false = 취소. count == 0 (PTY 자동 종료 path) 만 skip — 마지막
    /// 탭 자동 종료는 `closeAfterShellExit` 의 `shell_exited` 분기로 이미
    /// 처리되지만 안전 가드. macOS `applicationShouldTerminate:` 와 같은 정책.
    pub fn onQuitRequest(userdata: ?*anyopaque) bool {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        const n = self.session.count();
        if (n == 0) return true;
        const plural: []const u8 = if (n == 1) "" else "s";
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, messages.quit_confirm_format, .{ n, plural }) catch
            return true;
        return dialog.showConfirm(messages.quit_confirm_title, msg);
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
        self.TAB_ARROW_W = @intFromFloat(@round(@as(f32, @floatFromInt(ui_metrics.TAB_ARROW_W_PT)) * scale));
        self.TAB_PLUS_W = @intFromFloat(@round(@as(f32, @floatFromInt(ui_metrics.TAB_PLUS_W_PT)) * scale));
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

            // #117 — 활성 탭이 viewport 에 보이도록 scroll 갱신. drag 중인 동안은
            // handleDragMove 가 직접 auto-scroll 하므로 skip. 사용자 화살표
            // override 중에도 skip — 활성 탭 변경 시 reset 되어 재가동.
            if (!self.tab_interaction.drag.active and !self.tab_scroll_user_override)
                self.ensureActiveTabVisible();

            if (should_render) {
                // 탭바 + 터미널 함께 렌더 (glClear는 renderTabBar에 포함).
                // count<=1 이면 tab_bar_h=0 → 렌더러가 탭바 자체를 그리지 않고
                // 터미널 영역만 (#127 — 단일 탭에서 cell 영역 reserve 안 함).
                const tab_bar_h = self.effectiveTabBarHeight();
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
                const layout = self.tabBarLayout();
                r.renderTabBar(
                    tab_titles[0..n],
                    self.session.activeIndex(),
                    tab_bar_h,
                    size.w,
                    size.h,
                    self.TAB_WIDTH,
                    self.CLOSE_BTN_SIZE,
                    self.TAB_PADDING,
                    if (drag) |d| d.tab_index else null,
                    if (drag) |d| d.current_x else 0,
                    rs,
                    self.tab_scroll_x,
                    .{
                        .tab_area_x = layout.tab_area_x,
                        .tab_area_w = layout.tab_area_w,
                        .arrows_visible = layout.arrows_visible,
                        .arrow_w = layout.arrow_w,
                        .plus_w = layout.plus_w,
                        .plus_x = layout.plus_x,
                        .left_arrow_x = layout.left_arrow_x,
                        .right_arrow_x = layout.right_arrow_x,
                        .left_enabled = layout.left_enabled,
                        .right_enabled = layout.right_enabled,
                    },
                );
                if (self.activeTabPtr()) |tab| {
                    r.renderTerminal(
                        &tab.terminal,
                        window.cell_width,
                        window.cell_height,
                        size.w,
                        size.h,
                        tab_bar_h,
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
            // 활성 탭 변경 — 사용자 화살표 override 해제. 이 시점부터
            // ensureActiveTabVisible 가 다시 동작해 viewport 가 활성 탭을
            // 따라감 (Alt+N 으로 화살표 너머의 탭으로 이동했을 때 viewport
            // 가 그 탭이 보이는 위치로 minimum 이동). handleTabClick 동일 패턴.
            self.tab_scroll_user_override = false;
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
        const tbh = self.effectiveTabBarHeight();
        const track_h = client_h - tbh - 2 * self.TERMINAL_PADDING;
        if (track_h <= 0) return;

        const rel_y = @max(0, mouse_y - tbh - self.TERMINAL_PADDING);
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

    /// 탭바 hit-test 결과 — handleTabClick 가 분기하는 영역. drag begin 도 같은
    /// 영역 분기 사용.
    const TabBarHit = enum { left_arrow, right_arrow, plus, tab_area, none };

    fn tabBarHitArea(self: *const App, mouse_x: c_int, layout: TabBarLayout) TabBarHit {
        if (layout.arrows_visible) {
            if (mouse_x >= layout.left_arrow_x and mouse_x < layout.left_arrow_x + layout.arrow_w)
                return .left_arrow;
            if (mouse_x >= layout.right_arrow_x and mouse_x < layout.right_arrow_x + layout.arrow_w)
                return .right_arrow;
        }
        if (mouse_x >= layout.plus_x and mouse_x < layout.plus_x + layout.plus_w)
            return .plus;
        if (mouse_x >= layout.tab_area_x and mouse_x < layout.tab_area_x + layout.tab_area_w)
            return .tab_area;
        // arrows_visible == false 면 tab_area 가 0..plus_x 까지인데 위 조건이 그걸 다 잡음.
        // 화살표 미표시 + tab_area 너비가 0 인 비정상 케이스 방지.
        _ = self;
        return .none;
    }

    pub fn handleTabClick(self: *App, mouse_x: c_int, mouse_y: c_int) void {
        // 단일 탭이면 effectiveTabBarHeight==0 → 모든 클릭이 below 로 분류
        // (탭 클릭 자체가 의미 없음). count<=1 일 때 내부 분기에서 빨리 종료.
        if (mouse_y >= self.effectiveTabBarHeight()) return; // Below tab bar
        if (self.session.count() == 0) return;

        const layout = self.tabBarLayout();
        switch (self.tabBarHitArea(mouse_x, layout)) {
            .left_arrow => {
                if (layout.left_enabled) self.scrollTabsByArrow(.left);
                return;
            },
            .right_arrow => {
                if (layout.right_enabled) self.scrollTabsByArrow(.right);
                return;
            },
            .plus => {
                self.handleNewTab();
                return;
            },
            .none => return,
            .tab_area => {},
        }

        // #117 — tab_area 안에서 mouse_x → world 좌표. 탭 viewport 시작 x 가
        // tab_area_x (화살표 있을 때 ARROW_W) 에 오프셋. world_x = (mouse_x -
        // tab_area_x) + scroll_x.
        const local_x = mouse_x - layout.tab_area_x;
        const world_x = local_x + self.tab_scroll_x;
        const tab_index_raw = @divTrunc(world_x, self.TAB_WIDTH);
        if (tab_index_raw < 0) return;
        const tab_index: usize = @intCast(tab_index_raw);
        if (tab_index >= self.session.count()) return;

        // close 버튼 hit (world 좌표).
        const tab_x = @as(c_int, @intCast(tab_index)) * self.TAB_WIDTH;
        const close_x = tab_x + self.TAB_WIDTH - self.CLOSE_BTN_SIZE - self.TAB_PADDING;
        const close_y = @divTrunc(self.TAB_BAR_HEIGHT - self.CLOSE_BTN_SIZE, 2);
        if (world_x >= close_x and world_x <= close_x + self.CLOSE_BTN_SIZE and
            mouse_y >= close_y and mouse_y <= close_y + self.CLOSE_BTN_SIZE)
        {
            self.closeTab(tab_index);
            return;
        }

        if (self.session.setActiveTab(tab_index)) {
            self.tab_scroll_user_override = false;
            self.invalidateRenderer();
        }
    }

    pub fn handleDragStart(self: *App, mouse_x: c_int) void {
        // #117 — DragState 는 world 좌표. 탭 영역 좌표계: world_x = (mouse_x -
        // tab_area_x) + scroll_x. tab_area_x = 화살표 있으면 ARROW_W, 없으면 0.
        const layout = self.tabBarLayout();
        const world_x = (mouse_x - layout.tab_area_x) + self.tab_scroll_x;
        _ = self.tab_interaction.drag.begin(world_x, self.TAB_WIDTH, self.session.count());
    }

    pub fn handleDragMove(self: *App, mouse_x: c_int) void {
        // #117 — drag auto-scroll. mouse_x 가 *탭 영역* 의 좌/우 끝 가까이면
        // scroll 한 step 이동 후 drag.move 에 *갱신된* world 좌표 전달.
        const layout = self.tabBarLayout();
        const total = self.tabBarTotalWidth();
        const vp = layout.tab_area_w;
        if (vp > 0 and total > vp) {
            const max_sx = total - vp;
            const edge: c_int = 32;
            const step: c_int = 16;
            const local_x = mouse_x - layout.tab_area_x;
            if (local_x < edge and self.tab_scroll_x > 0) {
                self.tab_scroll_x = @max(0, self.tab_scroll_x - step);
            } else if (local_x > vp - edge and self.tab_scroll_x < max_sx) {
                self.tab_scroll_x = @min(max_sx, self.tab_scroll_x + step);
            }
        }
        const world_x = (mouse_x - layout.tab_area_x) + self.tab_scroll_x;
        _ = self.tab_interaction.drag.move(world_x);
    }

    pub fn handleDragEnd(self: *App) void {
        if (self.tab_interaction.drag.finish(self.TAB_WIDTH, self.session.count())) |request| {
            if (self.session.reorderTabs(request.from, request.to) catch false) {
                // drag reorder 끝 — 활성 탭 위치 변경, ensure 재가동.
                self.tab_scroll_user_override = false;
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
        const term_y = mouse_y - self.effectiveTabBarHeight() - self.TERMINAL_PADDING;
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
        const tbh = self.effectiveTabBarHeight();
        const term_y = mouse_y - tbh - self.TERMINAL_PADDING;
        if (self.window.hwnd == null) return;
        const client_h = self.window.getClientSize().h;
        const term_h = client_h - tbh - 2 * self.TERMINAL_PADDING;
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
                    .open_config => {
                        const path = paths.configPath(self.allocator) catch return true;
                        defer self.allocator.free(path);
                        system_open.openInDefaultApp(self.allocator, path);
                        return true;
                    },
                    .open_log => {
                        const path = paths.logPath(self.allocator) catch return true;
                        defer self.allocator.free(path);
                        system_open.openInDefaultApp(self.allocator, path);
                        return true;
                    },
                    .switch_tab => |index| {
                        self.handleSwitchTab(index);
                        return true;
                    },
                    .next_tab => {
                        if (self.session.activateNext()) {
                            self.tab_scroll_user_override = false; // #117 — 활성 탭 보이도록 ensure 재가동
                            self.invalidateRenderer();
                        }
                        return true;
                    },
                    .prev_tab => {
                        if (self.session.activatePrev()) {
                            self.tab_scroll_user_override = false;
                            self.invalidateRenderer();
                        }
                        return true;
                    },
                    .copy_selection => {
                        // Ctrl+Shift+C — 현재 highlight 된 selection 을 clipboard 로
                        // (#120). 드래그 직후 finishTerminalSelection 이 자동 copy
                        // 하지만, 그 후 사용자가 키로 다시 트리거하고 싶을 때.
                        if (self.activeTabPtr()) |tab| {
                            const screen: *ghostty.Screen = tab.terminal.screens.active;
                            if (screen.selection) |sel| {
                                const text = screen.selectionString(self.allocator, .{ .sel = sel }) catch return true;
                                defer self.allocator.free(text);
                                if (text.len > 0) self.window.copyToClipboard(text);
                            }
                        }
                        return true;
                    },
                }
            },
            .mouse_down => |mouse| {
                if (self.isRenaming()) self.commitRename();
                // count<=1 면 effectiveTabBarHeight==0 → 탭바 영역 자체가 없으므로
                // 모든 클릭이 터미널/스크롤바 라우팅으로 흘러간다 (#127).
                if (mouse.y < self.effectiveTabBarHeight()) {
                    self.terminal_interaction.cancelPointerModes();
                    self.handleTabClick(mouse.x, mouse.y);
                    // drag begin 은 *탭 영역* 안에서만 — 화살표 / + 위 클릭은
                    // drag 안 시작 (#117).
                    const layout = self.tabBarLayout();
                    if (self.tabBarHitArea(mouse.x, layout) == .tab_area) {
                        self.handleDragStart(mouse.x);
                    }
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
                if (mouse.y < self.effectiveTabBarHeight()) {
                    // #117 — 탭 영역 안에서만 rename, 화살표/+ 위 더블클릭은 무시.
                    const layout = self.tabBarLayout();
                    if (self.tabBarHitArea(mouse.x, layout) == .tab_area) {
                        const local_x = mouse.x - layout.tab_area_x;
                        const tab_index_raw = @divTrunc(local_x + self.tab_scroll_x, self.TAB_WIDTH);
                        if (tab_index_raw >= 0) {
                            const tab_index: usize = @intCast(tab_index_raw);
                            if (tab_index < self.session.count()) {
                                self.startRename(tab_index);
                            }
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
