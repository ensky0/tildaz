const std = @import("std");
const ghostty = @import("ghostty-vt");
const app_event = @import("app_event.zig");
const session_core = @import("session_core.zig");
const SessionCore = session_core.SessionCore;
const SessionTab = session_core.Tab;
const tab_interaction = @import("tab_interaction.zig");
const tab_layout = @import("tab_layout.zig");
const tab_actions = @import("tab_actions.zig");
const display_width = @import("font/display_width.zig");
const terminal_interaction = @import("terminal_interaction.zig");
const Window = @import("window.zig").Window;
const renderer_backend = @import("renderer.zig");
const RendererBackend = renderer_backend.RendererBackend;
const perf = @import("perf.zig");
const log = @import("log.zig");
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
    // terminal_interaction (mouse selection / scrollbar drag) state 는 per-tab —
    // session_core.Tab.interaction (cross-platform field, macOS 와 동등) 사용.
    // App level 에는 더 이상 글로벌 state 없음. 탭 전환 시 자동으로 새 탭의
    // state 사용 → 탭 별 highlight 보존 + drag stuck 회피.

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
    /// `tab_actions.Host` 인스턴스 — App member (session / override flag) 를
    /// cross-platform helper API 로 노출. `setupHost()` 가 self 의 stable
    /// address 잡힌 후 채움 (콜백이 user_data → *App cast).
    host: tab_actions.Host = undefined,

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

    /// `tab_actions.Host` 콜백 setup — self 의 메모리 위치가 안정 (스택의 `var
    /// app` 한 자리) 인 시점에 한 번만 호출. helper 가 callback 안에서 user_data
    /// → *App cast 해 instance state 접근.
    pub fn setupHost(self: *App) void {
        self.host = .{
            .session = &self.session,
            .override_ptr = &self.tab_scroll_user_override,
            .invalidate = winHostInvalidate,
            .rename_active = winHostRenameActive,
            .insert_rename_cp = winHostInsertRenameCp,
            .clipboard_copy = winHostClipboardCopy,
            .terminate = winHostTerminate,
            .user_data = self,
        };
    }

    fn winHostInvalidate(host: *tab_actions.Host) void {
        const self: *App = @ptrCast(@alignCast(host.user_data.?));
        self.invalidateRenderer();
    }

    fn winHostRenameActive(host: *const tab_actions.Host) bool {
        const self: *const App = @ptrCast(@alignCast(host.user_data.?));
        return self.isRenaming();
    }

    fn winHostInsertRenameCp(host: *tab_actions.Host, cp: u21) void {
        const self: *App = @ptrCast(@alignCast(host.user_data.?));
        self.handleRenameChar(cp);
    }

    fn winHostClipboardCopy(host: *tab_actions.Host, text: [:0]const u8) void {
        const self: *App = @ptrCast(@alignCast(host.user_data.?));
        self.window.copyToClipboard(text);
    }

    fn winHostTerminate(host: *tab_actions.Host) void {
        const self: *App = @ptrCast(@alignCast(host.user_data.?));
        log.appendLine("tab", "last tab exited — requesting window close", .{});
        self.window.closeAfterShellExit();
    }

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

    /// 인덱스 기반 close — 탭바 close 버튼 마우스 클릭 path. helper 가 마지막
    /// 탭 → terminate (`window.closeAfterShellExit`), 그 외 → override clear +
    /// invalidate. .changed 일 때만 grid resize (#127, 2 → 1 전환).
    fn closeTab(self: *App, index: usize) void {
        if (tab_actions.closeIndex(&self.host, index) == .changed) {
            if (self.session.count() == 1) {
                const grid = self.getTerminalGridSize();
                self.session.resizeAll(grid.cols, grid.rows);
            }
        }
    }

    /// 탭이 1개 이하면 탭바 자체를 그리지 않으므로 layout 에서도 0 으로 취급
    /// (#127). count 가 1↔2 로 바뀌면 createTab / handleCloseResult 가 즉시
    /// resizeAll 을 호출해 모든 탭 grid 동기화.
    fn effectiveTabBarHeight(self: *const App) c_int {
        return if (self.session.count() > 1) self.TAB_BAR_HEIGHT else 0;
    }

    /// #193 — Windows host 의 `WM_SETCURSOR` callback. SPEC.md §3.1:
    /// - cell 영역 → I-beam (`.cell`)
    /// - rename 활성 탭의 text 입력 영역 (close 'x' 박스 제외) → I-beam
    /// - 그 외 (탭바 일반 / 스크롤바 / padding) → arrow (`.other`)
    pub fn cursorRegion(x: c_int, y: c_int, userdata: ?*anyopaque) Window.CursorRegion {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        const tab_bar_h = self.effectiveTabBarHeight();
        // 탭바 영역 — rename 활성 탭 text 면 I-beam, 그 외 arrow.
        if (y < tab_bar_h) {
            if (self.tab_interaction.rename.isActive()) {
                const inputs = self.tabBarLayoutInputs();
                const layout = tab_layout.compute(inputs);
                const hit_text = tab_layout.hitRenameText(
                    @floatFromInt(x),
                    @floatFromInt(y),
                    layout,
                    @floatFromInt(self.TAB_WIDTH),
                    @floatFromInt(self.TAB_PADDING),
                    @floatFromInt(self.CLOSE_BTN_SIZE),
                    @floatFromInt(tab_bar_h),
                    @floatFromInt(self.tab_scroll_x),
                    @intCast(self.session.count()),
                    self.tab_interaction.rename.tab_index,
                );
                if (hit_text) return .cell;
            }
            return .other;
        }
        const size = self.window.getClientSize();
        if (x >= size.w - self.SCROLLBAR_W) return .other; // 스크롤바
        const pad = self.TERMINAL_PADDING;
        if (x < pad or y < tab_bar_h + pad) return .other; // 좌측 / 상단 padding
        if (y >= size.h - pad) return .other; // 하단 padding
        if (x >= size.w - pad - self.SCROLLBAR_W) return .other; // 우측 padding (스크롤바 옆)
        return .cell;
    }

    fn tabBarTotalWidth(self: *const App) c_int {
        return @as(c_int, @intCast(self.session.count())) * self.TAB_WIDTH;
    }

    /// 탭바 layout 계산 (#117 Firefox 패턴). `<` / `>` 화살표 + `+` 버튼이
    /// `tab_layout.Layout` alias — cross-platform 모듈 (#159 Phase 1).
    pub const TabBarLayout = tab_layout.Layout;

    /// `tab_layout.Inputs` 채우기 — host 의 글로벌 / member 를 cross-platform
    /// shape 으로 변환만. Windows 는 c_int → f32 cast.
    fn tabBarLayoutInputs(self: *const App) tab_layout.Inputs {
        const vp = self.window.getClientSize().w;
        // count >= MAX_TABS 면 plus 버튼 사라짐 — 마지막 탭이 `>` 화살표 인접.
        const at_limit = self.session.count() >= session_core.MAX_TABS;
        const plus_w_eff: c_int = if (at_limit) 0 else self.TAB_PLUS_W;
        return .{
            .viewport_w = @floatFromInt(vp),
            .tab_count = @intCast(self.session.count()),
            .tab_w = @floatFromInt(self.TAB_WIDTH),
            .arrow_w = @floatFromInt(self.TAB_ARROW_W),
            .plus_w = @floatFromInt(plus_w_eff),
            .scroll_x = @floatFromInt(self.tab_scroll_x),
        };
    }

    fn tabBarLayout(self: *const App) TabBarLayout {
        return tab_layout.compute(self.tabBarLayoutInputs());
    }

    /// 활성 탭이 viewport 안에 보이도록 `tab_scroll_x` 갱신 (#117 정책 b).
    /// drag / 사용자 화살표 override 중에는 호출 안 함.
    fn ensureActiveTabVisible(self: *App) void {
        const inputs = self.tabBarLayoutInputs();
        const layout = tab_layout.compute(inputs);
        const new_sx = tab_layout.ensureActiveVisible(inputs, layout, @intCast(self.session.activeIndex()));
        self.tab_scroll_x = @intFromFloat(new_sx);
    }

    /// 화살표 클릭으로 viewport 한 step (= 1 탭 너비) 이동 (#117). 양 끝 clamp.
    /// `tab_scroll_user_override = true` 로 ensure 잠시 비활성 → 활성 탭 변경
    /// 시 다시 활성.
    fn scrollTabsByArrow(self: *App, dir: tab_layout.ArrowDir) void {
        const inputs = self.tabBarLayoutInputs();
        const layout = tab_layout.compute(inputs);
        if (tab_layout.scrollByArrow(inputs, layout, dir)) |sx| {
            self.tab_scroll_x = @intFromFloat(sx);
            self.tab_scroll_user_override = true;
            self.invalidateRenderer();
        }
    }

    fn getTerminalGridSize(self: *const App) struct { cols: u16, rows: u16 } {
        if (self.window.hwnd == null) return .{ .cols = 120, .rows = 30 };
        const size = self.window.getClientSize();
        const w = size.w - 2 * self.TERMINAL_PADDING;
        const h = size.h - self.effectiveTabBarHeight() - 2 * self.TERMINAL_PADDING;
        const cols: u16 = if (self.window.cell_width_px > 0) @intCast(@max(1, @divTrunc(@max(w, 1), self.window.cell_width_px))) else 120;
        const rows: u16 = if (self.window.cell_height_px > 0) @intCast(@max(1, @divTrunc(@max(h, 1), self.window.cell_height_px))) else 30;
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

    /// F1 hide 직전 — rename 활성 시 commit (#175). 모든 focus_loss = commit
    /// 정책 (SPEC §4.1). preedit 은 hide 시점에 IME 가 OS 차원에서 자동 처리.
    pub fn onBeforeHide(userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        if (self.isRenaming()) self.commitRename();
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
        const min_tab_bar_h: c_int = @as(c_int, @intCast(self.window.cell_height_px)) + 4;
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
                window.font_chain[0..window.font_chain_count],
                window.font_size,
                @intCast(window.cell_width_px),
                @intCast(window.cell_height_px),
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
            // rename / IME preedit 활성 시 throttle 우회 — 두 UI 는 PTY 출력과
            // 무관한 매 keystroke 즉시 화면 갱신 필요 (mac 동등). throttle 만
            // 적용하면 typing 도중 preedit 안 보이거나 늦게 따라옴 (#164 회귀).
            const force_render = self.isRenaming() or self.window.imePreeditSlice().len > 0;

            // #117 — 활성 탭이 viewport 에 보이도록 scroll 갱신. drag 중인 동안은
            // handleDragMove 가 직접 auto-scroll 하므로 skip. 사용자 화살표
            // override 중에도 skip — 활성 탭 변경 시 reset 되어 재가동.
            if (!self.tab_interaction.drag.active and !self.tab_scroll_user_override)
                self.ensureActiveTabVisible();

            if (should_render or force_render) {
                // 탭바 + 터미널 함께 렌더 (glClear는 renderTabBar에 포함).
                // count<=1 이면 tab_bar_h=0 → 렌더러가 탭바 자체를 그리지 않고
                // 터미널 영역만 (#127 — 단일 탭에서 cell 영역 reserve 안 함).
                const tab_bar_h = self.effectiveTabBarHeight();
                var tab_titles: [32][]const u8 = undefined;
                const tabs = self.session.tabsSlice();
                const n = @min(tabs.len, 32);
                for (tabs[0..n], 0..) |t, i| {
                    tab_titles[i] = t.title[0..t.title_len];
                }
                r.renderTabBar(
                    tab_titles[0..n],
                    self.session.activeIndex(),
                    tab_bar_h,
                    size.w,
                    size.h,
                    self.TAB_WIDTH,
                    self.CLOSE_BTN_SIZE,
                    self.TAB_PADDING,
                    self.tab_interaction.drag.view(),
                    self.tab_interaction.rename.view(),
                    // rename 활성 시 IME preedit 을 탭바 cursor 옆 inline 으로
                    // (mac 동등). 비활성이면 cell preedit (renderTerminal) 로.
                    if (self.isRenaming()) self.window.imePreeditSlice() else &.{},
                    self.tab_scroll_x,
                    self.tabBarLayout(),
                );
                if (self.activeTabPtr()) |tab| {
                    r.renderTerminal(
                        &tab.terminal,
                        window.cell_width_px,
                        window.cell_height_px,
                        size.w,
                        size.h,
                        tab_bar_h,
                        self.TERMINAL_PADDING,
                        self.SCROLLBAR_W,
                        self.SCROLLBAR_MIN_THUMB_H,
                        // rename 중이면 cell preedit 빈 slice — IME 자모는 탭바
                        // (1c) 로 라우팅. 아니면 cursor 옆 inline overlay (#164).
                        if (self.isRenaming()) &.{} else self.window.imePreeditSlice(),
                    );
                }
                // IME composition / candidate window 위치 갱신 — 일본 / 중국
                // IME 의 한자 후보 popup 이 cursor 옆 자연스럽게 추적 (#164 1d).
                // renderer 가 cursor 그릴 때 last_cursor_px_* 갱신.
                self.window.imeSetCompositionPos(r.last_cursor_px_x, r.last_cursor_px_y);
            } else {
                perf.incExtra(&perf.onrender);
            }
        }
    }

    // --- Tab management from window messages ---

    pub fn handleTabClosed(self: *App, tab_ptr: usize) void {
        // PTY 자식 종료 → wndProc 가 WM_TAB_CLOSED 라우팅. closeByPtr helper 가
        // 마지막 탭 → terminate (`window.closeAfterShellExit`), 그 외 → override
        // clear + invalidate. .changed 일 때만 grid resize (#127, 2 → 1 전환).
        if (tab_actions.closeByPtr(&self.host, tab_ptr) == .changed) {
            if (self.session.count() == 1) {
                const grid = self.getTerminalGridSize();
                self.session.resizeAll(grid.cols, grid.rows);
            }
        }
    }

    pub fn handleNewTab(self: *App) void {
        if (tab_actions.checkAtLimitAndDialog(&self.host)) return;
        self.createTab() catch {};
    }

    pub fn handleCloseActiveTab(self: *App) void {
        // closeActive helper 가 마지막 탭 → terminate (`window.closeAfterShellExit`),
        // 그 외 → override clear + invalidate. .changed 일 때만 platform-specific
        // grid resize (2 → 1 전환에서 탭바 사라짐, #127).
        if (tab_actions.closeActive(&self.host) == .changed) {
            if (self.session.count() == 1) {
                const grid = self.getTerminalGridSize();
                self.session.resizeAll(grid.cols, grid.rows);
            }
        }
    }

    pub fn handleSwitchTab(self: *App, index: usize) void {
        // 활성 탭 변경 — 사용자 화살표 override 해제. 이 시점부터
        // ensureActiveTabVisible 가 다시 동작해 viewport 가 활성 탭을 따라감
        // (Alt+N 으로 화살표 너머의 탭으로 이동했을 때 viewport 가 그 탭이
        // 보이는 위치로 minimum 이동). handleTabClick 동일 패턴.
        tab_actions.switchTab(&self.host, index);
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

    /// `tab_layout.Area` alias.
    const TabBarHit = tab_layout.Area;

    /// hit-area 검사 — `tab_layout.hitArea` 호출. y 검사를 외부에서 안 하는
    /// Windows 케이스 → py=0, tab_bar_h=무한 으로 통과 처리.
    fn tabBarHitArea(self: *const App, mouse_x: c_int, layout: TabBarLayout) TabBarHit {
        _ = self;
        return tab_layout.hitArea(@floatFromInt(mouse_x), 0, std.math.floatMax(f32), layout);
    }

    /// rename 활성 탭의 text 영역 안 마우스 클릭 시 cursor 위치 변경 후 true.
    /// 영역 밖 / 다른 탭 / close 버튼 / 터미널 등은 false → caller 가 commit.
    /// (#164 follow-up — native textbox UX)
    fn tryRenameClickMoveCursor(self: *App, mouse_x: c_int, mouse_y: c_int) bool {
        const rv = self.tab_interaction.rename.view() orelse return false;
        if (mouse_y >= self.effectiveTabBarHeight()) return false;
        const layout = self.tabBarLayout();
        if (self.tabBarHitArea(mouse_x, layout) != .tab_area) return false;

        const local_x = mouse_x - @as(c_int, @intFromFloat(layout.tab_area_x));
        const tab_index_raw = @divTrunc(local_x + self.tab_scroll_x, self.TAB_WIDTH);
        if (tab_index_raw < 0) return false;
        const tab_index: usize = @intCast(tab_index_raw);
        if (tab_index != rv.tab_index) return false;

        // close 버튼 영역 검사 — 그 위 클릭은 commit + close.
        const tab_x_int = @as(c_int, @intCast(rv.tab_index)) * self.TAB_WIDTH - self.tab_scroll_x + @as(c_int, @intFromFloat(layout.tab_area_x));
        const close_x_int = tab_x_int + self.TAB_WIDTH - self.CLOSE_BTN_SIZE - self.TAB_PADDING;
        if (mouse_x >= close_x_int) return false;

        // preedit 활성 시 manual commit — preedit 자모 들을 현재 cursor 위치
        // 다음에 insert (rename buf 에). 그 후 IME state cancel — 다음
        // GCS_RESULTSTR 안 받게. native textbox UX (#164 follow-up).
        const preedit = self.window.imePreeditSlice();
        if (preedit.len > 0) {
            var commit_iter = std.unicode.Utf8Iterator{ .bytes = preedit, .i = 0 };
            while (commit_iter.nextCodepoint()) |cp| {
                if (cp >= 0x20) _ = self.tab_interaction.rename.insertCodepoint(cp);
            }
            self.window.imeCancelComposition();
        }

        // commit 반영된 새 view 로 mouse → byte 매핑.
        const rv_new = self.tab_interaction.rename.view() orelse return false;
        const cw: f32 = @floatFromInt(self.window.cell_width_px);
        const text_x_start: f32 = @floatFromInt(tab_x_int + self.TAB_PADDING);
        const max_text_w: f32 = @floatFromInt(self.TAB_WIDTH - self.CLOSE_BTN_SIZE - self.TAB_PADDING * 3);

        if (tab_layout.renameTextHit(rv_new.text[0..rv_new.text_len], self.tab_interaction.rename.scroll_offset, text_x_start, cw, max_text_w, @floatFromInt(mouse_x))) |new_byte| {
            self.tab_interaction.rename.setCursor(new_byte);
            self.invalidateRenderer();
            return true;
        }
        return false;
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
        const local_x = mouse_x - @as(c_int, @intFromFloat(layout.tab_area_x));
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
        const world_x = (mouse_x - @as(c_int, @intFromFloat(layout.tab_area_x))) + self.tab_scroll_x;
        _ = self.tab_interaction.drag.begin(world_x, self.TAB_WIDTH, self.session.count());
    }

    pub fn handleDragMove(self: *App, mouse_x: c_int) void {
        // #117 — drag auto-scroll. mouse_x 가 *탭 영역* 의 좌/우 끝 가까이면
        // scroll 한 step 이동 후 drag.move 에 *갱신된* world 좌표 전달.
        const layout = self.tabBarLayout();
        const total = self.tabBarTotalWidth();
        const tab_area_x_int: c_int = @intFromFloat(layout.tab_area_x);
        const vp: c_int = @intFromFloat(layout.tab_area_w);
        if (vp > 0 and total > vp) {
            const max_sx = total - vp;
            const edge: c_int = 32;
            const step: c_int = 16;
            const local_x = mouse_x - tab_area_x_int;
            if (local_x < edge and self.tab_scroll_x > 0) {
                self.tab_scroll_x = @max(0, self.tab_scroll_x - step);
            } else if (local_x > vp - edge and self.tab_scroll_x < max_sx) {
                self.tab_scroll_x = @min(max_sx, self.tab_scroll_x + step);
            }
        }
        const world_x = (mouse_x - tab_area_x_int) + self.tab_scroll_x;
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
        const cw = self.window.cell_width_px;
        const ch = self.window.cell_height_px;
        const grid = self.getTerminalGridSize();
        const term_x = mouse_x - self.TERMINAL_PADDING;
        const term_y = mouse_y - self.effectiveTabBarHeight() - self.TERMINAL_PADDING;
        const col: u16 = if (cw > 0 and term_x >= 0) @intCast(@min(@divTrunc(term_x, cw), @as(c_int, grid.cols) - 1)) else 0;
        const row: u16 = if (ch > 0 and term_y >= 0) @intCast(@min(@divTrunc(term_y, ch), @as(c_int, grid.rows) - 1)) else 0;
        return .{ .col = col, .row = row };
    }

    fn startTerminalSelection(self: *App, mouse_x: c_int, mouse_y: c_int) void {
        const tab = self.activeTabPtr() orelse return;
        const cell = self.mouseToCell(mouse_x, mouse_y);
        const screen: *ghostty.Screen = tab.terminal.screens.active;
        tab.interaction.selection.begin(screen, cell);
    }

    fn updateTerminalSelection(self: *App, mouse_x: c_int, mouse_y: c_int) void {
        const tab = self.activeTabPtr() orelse return;
        if (!tab.interaction.selection.active) return;
        if (self.window.hwnd == null) return;

        // #245 — 경계 밖 방향 판정(공유 헬퍼) + 위/아래면 auto-scroll. 포인터를
        // 경계 밖에 멈춰 둬도 연속되도록 window 의 auto-scroll 타이머를 on/off
        // (타이머가 마지막 mouse_move 를 재전송 → 이 함수 재진입). raw_row 는
        // @divFloor 로 음수(위 경계) 판정.
        const tbh = self.effectiveTabBarHeight();
        const ch: i32 = @intCast(self.window.cell_height_px);
        const term_y: i32 = @intCast(mouse_y - tbh - self.TERMINAL_PADDING);
        const grid = self.getTerminalGridSize();
        const raw_row: i32 = if (ch > 0) @divFloor(term_y, ch) else 0;
        const dir = terminal_interaction.edgeScrollDir(raw_row, grid.rows);
        if (dir < 0) {
            tab.terminal.scrollViewport(.{ .delta = -3 });
        } else if (dir > 0) {
            tab.terminal.scrollViewport(.{ .delta = 3 });
        }
        self.window.setAutoScroll(dir != 0);

        const cell = self.mouseToCell(mouse_x, mouse_y);
        const screen: *ghostty.Screen = tab.terminal.screens.active;
        tab.interaction.selection.update(screen, cell);
    }

    fn finishTerminalSelection(self: *App) void {
        const tab = self.activeTabPtr() orelse return;
        if (!tab.interaction.selection.finish()) return;

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
            .paste => |bytes| {
                // rename routing (printable cp 만 → handleRenameChar) 또는 일반
                // PTY paste (bracketed paste + wrap 은 session 가). 양쪽 분기
                // helper. mac handlePaste 와 같은 path.
                tab_actions.routePaste(&self.host, bytes);
                return true;
            },
            .shortcut => |shortcut| {
                // rename 활성 중 어떤 단축키든 = focus_loss → 현재 입력값으로
                // commit 후 단축키 실행 (#175). mac `commitPendingInput` 동등.
                if (self.isRenaming()) self.commitRename();
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
                        tab_actions.resetActive(&self.host);
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
                        // 우리 창은 WS_EX_TOPMOST 라 새로 launch 되는 editor 가
                        // 그 뒤로 가려져 사용자에겐 안 보임. topmost flag 만 잠시
                        // 내려 → editor 가 자연스럽게 우리 위. 다음 F1 toggle 시
                        // show() 의 applyRect 가 HWND_TOPMOST 복귀.
                        self.window.yieldTopmostUntilNextShow();
                        system_open.openInDefaultApp(self.allocator, path);
                        return true;
                    },
                    .open_log => {
                        const path = paths.logPath(self.allocator) catch return true;
                        defer self.allocator.free(path);
                        self.window.yieldTopmostUntilNextShow();
                        system_open.openInDefaultApp(self.allocator, path);
                        return true;
                    },
                    .switch_tab => |index| {
                        self.handleSwitchTab(index);
                        return true;
                    },
                    .next_tab => {
                        tab_actions.nextTab(&self.host); // #117 — 활성 탭 보이도록 ensure 재가동
                        return true;
                    },
                    .prev_tab => {
                        tab_actions.prevTab(&self.host);
                        return true;
                    },
                    .copy_selection => {
                        // Ctrl+Shift+C — 현재 highlight 된 selection 을 clipboard 로
                        // (#120). 드래그 직후 finishTerminalSelection 이 자동 copy
                        // 하지만, 그 후 사용자가 키로 다시 트리거하고 싶을 때.
                        tab_actions.copyActiveSelection(&self.host, self.allocator);
                        return true;
                    },
                }
            },
            .mouse_down => |mouse| {
                // rename 활성 탭 text 영역 안 클릭 → cursor 위치만 변경 (commit X).
                // native textbox UX (#164 follow-up). 그 외는 기존 동작.
                if (self.isRenaming()) {
                    if (self.tryRenameClickMoveCursor(mouse.x, mouse.y)) return true;
                    self.commitRename();
                }
                // count<=1 면 effectiveTabBarHeight==0 → 탭바 영역 자체가 없으므로
                // 모든 클릭이 터미널/스크롤바 라우팅으로 흘러간다 (#127).
                if (mouse.y < self.effectiveTabBarHeight()) {
                    if (self.activeTabPtr()) |tab| tab.interaction.cancelPointerModes();
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
                    if (self.activeTabPtr()) |tab| {
                        tab.interaction.scrollbar.begin();
                        tab.interaction.selection.cancel();
                    }
                    self.tab_interaction.drag.reset();
                    self.scrollToY(mouse.y);
                    return true;
                }
                self.tab_interaction.drag.reset();
                if (self.activeTabPtr()) |tab| tab.interaction.scrollbar.end();
                self.startTerminalSelection(mouse.x, mouse.y);
                return true;
            },
            .mouse_double_click => |mouse| {
                if (mouse.y < self.effectiveTabBarHeight()) {
                    // #117 — 탭 영역 안에서만 rename, 화살표/+ 위 더블클릭은 무시.
                    const layout = self.tabBarLayout();
                    if (self.tabBarHitArea(mouse.x, layout) == .tab_area) {
                        const local_x = mouse.x - @as(c_int, @intFromFloat(layout.tab_area_x));
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
                    const tab_opt = self.activeTabPtr();
                    if (tab_opt != null and tab_opt.?.interaction.scrollbar.active) {
                        self.scrollToY(mouse.y);
                    } else if (self.tab_interaction.drag.active) {
                        self.handleDragMove(mouse.x);
                    } else if (tab_opt != null and tab_opt.?.interaction.selection.active) {
                        self.updateTerminalSelection(mouse.x, mouse.y);
                    }
                }
                return true;
            },
            .mouse_up => |_| {
                // #245 — 어떤 release 든 drag-select auto-scroll 타이머 정지.
                self.window.setAutoScroll(false);
                if (self.activeTabPtr()) |tab| {
                    if (tab.interaction.scrollbar.active) {
                        tab.interaction.scrollbar.end();
                        return true;
                    }
                }
                if (self.tab_interaction.drag.active) {
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
