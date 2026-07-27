const std = @import("std");
const ghostty = @import("ghostty-vt");
const app_event = @import("app_event.zig");
const input_policy = @import("input_policy.zig");
const windows_input_adapter = @import("windows_input_adapter.zig");
const session_core = @import("session_core.zig");
const SessionCore = session_core.SessionCore;
const SessionTab = session_core.Tab;
const tab_interaction = @import("tab_interaction.zig");
const tab_layout = @import("tab_layout.zig");
const tab_actions = @import("tab_actions.zig");
const terminal_interaction = @import("terminal_interaction.zig");
const Window = @import("window.zig").Window;
const renderer_backend = @import("renderer.zig");
const RendererBackend = renderer_backend.RendererBackend;
const perf = @import("perf.zig");
const log = @import("log.zig");
const about = @import("about.zig");
const ui_metrics = @import("ui_metrics.zig");
const scrollbar = @import("scrollbar.zig");
const paths = @import("paths.zig");
const system_open = @import("system_open.zig");
const dialog = @import("dialog.zig");
const messages = @import("messages.zig");
const command_menu = @import("command_menu.zig");
const shell_validate = @import("shell_validate.zig");

pub const App = struct {
    session: SessionCore,
    window: Window,
    allocator: std.mem.Allocator,
    /// #248 — `config.shell` (UTF-8 원본). 런타임 새 탭 생성 직전 shell 바이너리
    /// 재검증용 (startup `validateOrFatal` 과 같은 값). host(`windows.zig`)가 set.
    shell: []const u8 = "",
    renderer: ?RendererBackend = null,
    last_render_ms: i64 = 0,
    /// 탭 drag-and-drop reorder state. cross-platform `tab_interaction.DragState`
    /// — macOS `g_drag` / Linux `tab_drag` 와 같은 모듈.
    tab_drag: tab_interaction.DragState = .{},
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
    /// 탭바 컨트롤 버튼 (`<` `>` `+` `×` `…`) 의 hover 대상 (#268/#329).
    /// mouse move마다 갱신, 변경 시에만 재렌더. 렌더러가 hover 배경 박스를 그림.
    tab_hover: tab_layout.Area = .none,
    /// #329 command/shortcut menu 표시/hover 상태. 공통 `command_menu.zig`
    /// model로 세 platform의 layout과 hit-test를 맞춘다.
    command_menu_open: bool = false,
    command_menu_hover: ?command_menu.Command = null,
    /// #329 — 메뉴 keyboard focus (Up/Down/Home/End/Tab 이동, Enter/Space 실행).
    command_menu_focus: ?command_menu.Command = null,
    /// #329 — 작은 viewport 에서 entry 단위 scroll 의 첫 표시 entry 인덱스.
    command_menu_first: usize = 0,
    /// #334 — 메뉴 wheel delta 누적 (WHEEL_DELTA=120 미만 정밀 휠도 스크롤
    /// 되게 나머지 보존 — Linux 의 fixed 누적과 같은 패턴).
    command_menu_wheel_accum: i32 = 0,
    toggle_hotkey_hint: [64]u8 = [_]u8{0} ** 64,
    toggle_hotkey_hint_len: usize = 0,
    /// `tab_actions.Host` 인스턴스 — App member (session / override flag) 를
    /// cross-platform helper API 로 노출. `setupHost()` 가 self 의 stable
    /// address 잡힌 후 채움 (콜백이 user_data → *App cast).
    host: tab_actions.Host = undefined,

    // DPI-scaled values (initialized in run()). 기본값은 96dpi(scale 1.0) 기준
    // = ui_metrics 의 PT 값 (#282 G11 — 리터럴 대신 단일 소스 참조). run() 초기
    // applyDpiScale 가 실제 scale 로 모두 덮어써 이 기본값은 transient.
    dpi_scale: f32 = 1.0,
    TAB_BAR_HEIGHT: c_int = @intCast(ui_metrics.TAB_BAR_HEIGHT_PT),
    TAB_WIDTH: c_int = @intCast(ui_metrics.TAB_WIDTH_PT),
    TAB_ARROW_W: c_int = @intCast(ui_metrics.TAB_ARROW_W_PT),
    TAB_PLUS_W: c_int = @intCast(ui_metrics.TAB_PLUS_W_PT),
    TAB_CLOSE_W: c_int = @intCast(ui_metrics.TAB_CLOSE_W_PT),
    TAB_MORE_W: c_int = @intCast(ui_metrics.TAB_MORE_W_PT),
    TAB_PADDING: c_int = @intCast(ui_metrics.TAB_PADDING_PT),
    SCROLLBAR_W: c_int = @intCast(ui_metrics.SCROLLBAR_W_PT),
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
            .clipboard_copy = winHostClipboardCopy,
            .terminate = winHostTerminate,
            .user_data = self,
        };
    }

    pub fn setToggleHotkeyHint(self: *App, hint: []const u8) void {
        self.toggle_hotkey_hint_len = @min(hint.len, self.toggle_hotkey_hint.len);
        @memcpy(self.toggle_hotkey_hint[0..self.toggle_hotkey_hint_len], hint[0..self.toggle_hotkey_hint_len]);
    }

    fn winHostInvalidate(host: *tab_actions.Host) void {
        const self: *App = @ptrCast(@alignCast(host.user_data.?));
        self.invalidateRenderer();
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

    /// 단일 탭에서도 우측 control strip 아래부터 scrollbar track을 시작한다.
    /// terminal grid offset은 `effectiveTabBarHeight` 그대로 0이다.
    fn scrollbarTopInset(self: *const App) c_int {
        return if (self.session.count() > 0) self.TAB_BAR_HEIGHT else 0;
    }

    /// #193 — Windows host 의 `WM_SETCURSOR` callback. SPEC.md §3.1:
    /// - cell 영역 → I-beam (`.cell`)
    /// - 그 외 (탭바 / 스크롤바 / padding) → arrow (`.other`)
    pub fn cursorRegion(x: c_int, y: c_int, userdata: ?*anyopaque) Window.CursorRegion {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        const tab_bar_h = self.effectiveTabBarHeight();
        if (self.singleControlHit(x, y) != .none) return .other;
        if (self.command_menu_open) {
            const menu = self.commandMenuView().rect;
            const px = @as(f32, @floatFromInt(x)) / self.dpi_scale;
            const py = @as(f32, @floatFromInt(y)) / self.dpi_scale;
            if (px >= menu.x and px < menu.x + menu.w and py >= menu.y and py < menu.y + menu.h) return .other;
        }
        // 탭바 영역 — 버튼 성격 영역이라 arrow.
        if (y < tab_bar_h) return .other;
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
        // #329 정책 변경 (2026-07-22) — count >= MAX_TABS 여도 `+` 는 자리를
        // 유지하고 비활성 색 + click noop. `[+][×][…]` 세 버튼이 항상 같은
        // 자리에 있게 한다. 단축키 경로의 한도 dialog 는 그대로.
        const at_limit = self.session.count() >= session_core.MAX_TABS;
        return .{
            .viewport_w = @floatFromInt(vp),
            .tab_count = @intCast(self.session.count()),
            .tab_w = @floatFromInt(self.TAB_WIDTH),
            .arrow_w = @floatFromInt(self.TAB_ARROW_W),
            .plus_w = @floatFromInt(self.TAB_PLUS_W),
            .plus_enabled = !at_limit,
            .close_w = @floatFromInt(self.TAB_CLOSE_W),
            .more_w = @floatFromInt(self.TAB_MORE_W),
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
        // Alt+F4/WM_CLOSE도 다른 focus-loss action과 같은 Windows 입력 정책을
        // 거친다. IME 결과가 confirm dialog보다 먼저 끝나야 Cancel 뒤에도
        // 원래 탭에 확정 결과가 남는다 (#313).
        _ = self.resolveWindowsInput(.{ .shortcut = .quit }) orelse return false;
        const n = self.session.count();
        if (n == 0) return true;
        var msg_buf: [256]u8 = undefined;
        const msg = dialog.quitConfirmMessage(&msg_buf, n) orelse return true;
        return dialog.showConfirm(messages.quit_confirm_title, msg);
    }

    /// F1 hide 직전 — 진행 중 preedit commit (#175). 모든 focus_loss = commit
    /// 정책 (SPEC §4.1).
    pub fn onBeforeHide(userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        // WM_HOTKEY는 app event로 먼저 이 정책을 적용한다. 이 callback은 다른
        // 내부 hide 진입점도 같은 불변식을 지키게 하는 idempotent fallback.
        _ = self.resolveWindowsInput(.{ .shortcut = .toggle_visibility });
    }

    /// #282 A11 — IME 조합 시작 시 활성 탭을 맨 아래로 (macOS/Linux 동등).
    pub fn onImeCompositionStart(userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        self.session.scrollActiveToBottom();
    }

    // --- Window callbacks (userdata = *App) ---

    pub fn onKeyInput(data: []const u8, userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        // #282 A8 — Ctrl+C(ETX 0x03) 는 write_queue 우회 즉시 송신(SIGINT). 대량 paste
        // 로 큐가 가득 차면 SIGINT 가 그 뒤에 밀려 "Ctrl+C 안 먹힘" 이 되므로(macOS 동등).
        // 이 경로는 키보드 write 전용이라 단독 0x03 = Ctrl+C (arrow 등은 multi-byte escape).
        if (data.len == 1 and data[0] == 0x03) {
            self.session.interruptActive(data);
            return;
        }
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
        self.TAB_BAR_HEIGHT = @intCast(ui_metrics.tabBarHeightPx(scale));
        self.TAB_WIDTH = @intFromFloat(@round(@as(f32, @floatFromInt(ui_metrics.TAB_WIDTH_PT)) * scale));
        self.TAB_ARROW_W = @intFromFloat(@round(@as(f32, @floatFromInt(ui_metrics.TAB_ARROW_W_PT)) * scale));
        self.TAB_PLUS_W = @intFromFloat(@round(@as(f32, @floatFromInt(ui_metrics.TAB_PLUS_W_PT)) * scale));
        self.TAB_CLOSE_W = @intFromFloat(@round(@as(f32, @floatFromInt(ui_metrics.TAB_CLOSE_W_PT)) * scale));
        self.TAB_MORE_W = @intFromFloat(@round(@as(f32, @floatFromInt(ui_metrics.TAB_MORE_W_PT)) * scale));
        self.TAB_PADDING = @intFromFloat(@round(@as(f32, @floatFromInt(ui_metrics.TAB_PADDING_PT)) * scale));
        self.SCROLLBAR_W = @intFromFloat(@round(@as(f32, @floatFromInt(ui_metrics.SCROLLBAR_W_PT)) * scale));
        self.SCROLLBAR_MIN_THUMB_H = @intFromFloat(@round(@as(f32, @floatFromInt(ui_metrics.SCROLLBAR_MIN_THUMB_H_PT)) * scale));
        self.TERMINAL_PADDING = @intFromFloat(@round(@as(f32, @floatFromInt(ui_metrics.TERMINAL_PADDING_PT)) * scale));
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
                window.terminal_font,
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
            // IME preedit 활성 시 throttle 우회 — preedit UI 는 PTY 출력과
            // 무관한 매 keystroke 즉시 화면 갱신 필요 (mac 동등). throttle 만
            // 적용하면 typing 도중 preedit 안 보이거나 늦게 따라옴 (#164 회귀).
            const force_render = self.window.imePreeditSlice().len > 0;

            // #117 — 활성 탭이 viewport 에 보이도록 scroll 갱신. drag 중인 동안은
            // handleDragMove 가 직접 auto-scroll 하므로 skip. 사용자 화살표
            // override 중에도 skip — 활성 탭 변경 시 reset 되어 재가동.
            if (!self.tab_drag.active and !self.tab_scroll_user_override)
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
                const terminal_bg = if (self.activeTabPtr()) |tab|
                    tab.terminal.colors.background.get()
                else
                    null;
                r.renderTabBar(
                    tab_titles[0..n],
                    self.session.activeIndex(),
                    terminal_bg,
                    tab_bar_h,
                    size.w,
                    size.h,
                    self.TAB_WIDTH,
                    self.TAB_PADDING,
                    self.dpi_scale,
                    self.tab_drag.view(),
                    self.tab_scroll_x,
                    self.tabBarLayout(),
                    self.tab_hover,
                );
                if (self.activeTabPtr()) |tab| {
                    r.renderTerminal(
                        &tab.terminal,
                        window.cell_width_px,
                        window.cell_height_px,
                        size.w,
                        size.h,
                        tab_bar_h,
                        self.scrollbarTopInset(),
                        self.TERMINAL_PADDING,
                        self.SCROLLBAR_W,
                        self.SCROLLBAR_MIN_THUMB_H,
                        // IME 자모는 cursor 옆 inline overlay (#164).
                        self.window.imePreeditSlice(),
                        self.tabBarLayout(),
                        self.tab_hover,
                        .{
                            .open = self.command_menu_open,
                            .hover = self.command_menu_hover,
                            .focused = self.command_menu_focus,
                            .first_visible = self.command_menu_first,
                            .fullscreen_workarea = self.window.fullscreen_mode == .workarea,
                        },
                        self.toggle_hotkey_hint[0..self.toggle_hotkey_hint_len],
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
        // #248 — shell 이 런타임에 사라졌으면 조용히 죽는 대신 알림 후 취소.
        if (!shell_validate.checkForNewTab(self.allocator, self.shell)) return;
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

    /// 현재 활성 탭의 scrollbar `Hit` (track geometry + thumb geometry). 스크롤백이
    /// 없거나 thumb 가 들어갈 여유가 없으면 null. 렌더러(`renderer/windows.zig`)와
    /// 같은 `scrollbar.hit` 입력을 써서 그림 영역과 클릭 영역을 일치시킨다 (#259).
    fn scrollbarHit(self: *App) ?scrollbar.Hit {
        const tab = self.activeTabPtr() orelse return null;
        if (self.window.hwnd == null) return null;
        const sb = tab.terminal.screens.active.pages.scrollbar();
        const client_h = self.window.getClientSize().h;
        const tbh = self.scrollbarTopInset();
        return scrollbar.hit(
            sb.total,
            sb.len,
            sb.offset,
            @floatFromInt(client_h),
            @floatFromInt(tbh),
            @floatFromInt(self.TERMINAL_PADDING),
            @floatFromInt(self.SCROLLBAR_MIN_THUMB_H),
        );
    }

    /// mouse-down 시 grab offset 산출 (#259). 스크롤바 없으면 0.
    fn scrollbarGrabAt(self: *App, mouse_y: c_int) f64 {
        const h = self.scrollbarHit() orelse return 0;
        return h.grab(@floatFromInt(mouse_y));
    }

    /// 드래그 중 thumb 를 mouse_y 에 맞춰 viewport scroll. grab offset 은 down 때
    /// `scrollbar.begin` 으로 저장된 값을 사용 — thumb 어디를 잡아도 그 지점이
    /// 커서 아래 고정돼 따라온다 (#259, 이전엔 thumb 윗변이 커서로 점프).
    fn scrollToY(self: *App, mouse_y: c_int) void {
        const tab = self.activeTabPtr() orelse return;
        const h = self.scrollbarHit() orelse return;
        const target_row = h.target(@floatFromInt(mouse_y), tab.interaction.scrollbar.grab_offset);
        const delta = @as(isize, @intCast(target_row)) - @as(isize, @intCast(h.offset));
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

    fn singleControlHit(self: *const App, mouse_x: c_int, mouse_y: c_int) TabBarHit {
        if (self.session.count() != 1 or mouse_y < 0 or mouse_y >= self.scrollbarTopInset()) return .none;
        return switch (self.tabBarHitArea(mouse_x, self.tabBarLayout())) {
            .plus, .close, .more => |a| a,
            else => .none,
        };
    }

    /// #329 — 현재 viewport / scroll 기준의 menu View (renderer 와 같은 계산).
    fn commandMenuView(self: *const App) command_menu.View {
        const size = self.window.getClientSize();
        return command_menu.view(
            @as(f32, @floatFromInt(size.w)) / self.dpi_scale,
            @as(f32, @floatFromInt(size.h)) / self.dpi_scale,
            @floatFromInt(ui_metrics.TAB_BAR_HEIGHT_PT),
            self.command_menu_first,
        );
    }

    /// #329 — 메뉴 닫기 공통 지점. focus / scroll 까지 초기화해 다음 열기가
    /// 항상 처음 상태에서 시작한다.
    fn closeCommandMenu(self: *App) void {
        self.command_menu_open = false;
        self.command_menu_hover = null;
        self.command_menu_focus = null;
        self.command_menu_first = 0;
        self.command_menu_wheel_accum = 0;
        self.invalidateRenderer();
    }

    fn commandMenuHit(self: *const App, mouse_x: c_int, mouse_y: c_int) ?command_menu.Command {
        if (!self.command_menu_open or mouse_x < 0 or mouse_y < 0) return null;
        return command_menu.hit(self.commandMenuView(), @as(f32, @floatFromInt(mouse_x)) / self.dpi_scale, @as(f32, @floatFromInt(mouse_y)) / self.dpi_scale);
    }

    /// #329 — 메뉴가 열린 동안의 키 입력. 모든 키를 메뉴 계층이 소비한다
    /// (native menu 동등) — PTY 로 보내지 않는다.
    fn handleCommandMenuKey(self: *App, menu_key: command_menu.MenuKey) void {
        switch (command_menu.onKey(menu_key, &self.command_menu_focus)) {
            .consumed => {
                // #334 — 키보드를 쓰는 순간 pointer hover 강조를 지운다.
                // 마우스가 항목 위에 머물러 있으면 hover 가 focus 를 덮어
                // 키보드 이동이 화면에 안 보였다 (사용자 시연 발견). 마우스를
                // 다시 움직이면 hover 가 재적용되며 focus 도 동기화된다.
                self.command_menu_hover = null;
                if (self.command_menu_focus) |focused| {
                    const size = self.window.getClientSize();
                    self.command_menu_first = command_menu.ensureVisible(
                        @as(f32, @floatFromInt(size.w)) / self.dpi_scale,
                        @as(f32, @floatFromInt(size.h)) / self.dpi_scale,
                        @floatFromInt(ui_metrics.TAB_BAR_HEIGHT_PT),
                        self.command_menu_first,
                        focused,
                    );
                }
                self.invalidateRenderer();
            },
            .close => self.closeCommandMenu(),
            .activate => |command| self.executeCommandMenu(command),
        }
    }

    /// 메뉴 / 탭바 버튼의 상태 변경 명령 공통 진입 — keyboard shortcut 과 같은
    /// 입력 정책(IMM complete → action)을 거친다 (#329).
    /// false 면 IMM complete 실패 등으로 action 을 보류해야 한다.
    fn resolveRunAction(self: *App, sc: input_policy.Shortcut) bool {
        const disposition = self.resolveWindowsInput(.{ .shortcut = sc }) orelse return false;
        return disposition.target == .run_action;
    }

    fn executeCommandMenu(self: *App, command: command_menu.Command) void {
        self.closeCommandMenu();
        // paste 만 commit 정책이 다른 `Input.paste` 경로 — requestPaste 가
        // onAppEvent(.paste) → resolveWindowsInput(.paste) 를 그대로 탄다.
        switch (command) {
            .toggle_visibility => if (self.resolveRunAction(.toggle_visibility)) self.window.toggle(),
            .new_tab => if (self.resolveRunAction(.new_tab)) self.handleNewTab(),
            .close_active_tab => if (self.resolveRunAction(.close_tab)) self.handleCloseActiveTab(),
            .copy_selection => if (self.resolveRunAction(.copy_selection)) tab_actions.copyActiveSelection(&self.host, self.allocator),
            .paste => self.window.requestPaste(),
            // #334 — 메뉴는 상태 기준 토글: 어떤 모드든 전체화면이면 그 모드를
            // 해제, 아니면 monitor 진입 (키보드 self-symmetric 정책은 그대로).
            .fullscreen => if (self.resolveRunAction(.fullscreen)) self.window.toggleFullscreenMode(if (self.window.fullscreen_mode != .none) self.window.fullscreen_mode else .monitor),
            .open_config => if (self.resolveRunAction(.open_config)) {
                const path = paths.configPath(self.allocator) catch return;
                defer self.allocator.free(path);
                self.window.yieldTopmostUntilNextShow();
                system_open.openInDefaultApp(self.allocator, path);
            },
            .keyboard_shortcuts => if (self.resolveRunAction(.open_shortcuts)) {
                self.window.yieldTopmostUntilNextShow();
                system_open.openInDefaultApp(self.allocator, messages.keyboard_shortcuts_url);
            },
            .about => if (self.resolveRunAction(.show_about)) about.showAboutDialog(),
        }
        self.invalidateRenderer();
    }

    /// #268/#329 — 탭바 컨트롤 버튼 hover 갱신.
    /// hover, 탭 본체 / 탭바 밖은 .none. 변경 시에만 재렌더 (mouse move 마다
    /// 그리지 않게).
    fn updateTabHover(self: *App, mouse_x: c_int, mouse_y: c_int) void {
        if (self.command_menu_open) {
            const menu_hover = self.commandMenuHit(mouse_x, mouse_y);
            if (menu_hover != self.command_menu_hover or self.tab_hover != .none) {
                self.command_menu_hover = menu_hover;
                // #329 — pointer 가 항목 위로 오면 keyboard focus 도 그 항목으로
                // 동기화 (표준 메뉴 동작). 안 하면 마우스로 건너뛴 뒤 ↑↓ 가
                // 옛 focus 위치에서 출발한다 (사용자 시연 발견).
                if (menu_hover) |h| self.command_menu_focus = h;
                self.tab_hover = .none;
                self.invalidateRenderer();
            }
            return;
        }
        self.command_menu_hover = null;
        const new_hover: tab_layout.Area = blk: {
            if (self.session.count() == 1) break :blk self.singleControlHit(mouse_x, mouse_y);
            if (mouse_y < 0 or mouse_y >= self.effectiveTabBarHeight()) break :blk .none;
            const layout = self.tabBarLayout();
            break :blk switch (self.tabBarHitArea(mouse_x, layout)) {
                // #329 — 비활성 `+` 는 hover 강조도 없음.
                .plus => if (layout.plus_enabled) tab_layout.Area.plus else .none,
                .left_arrow, .right_arrow, .close, .more => |a| a,
                .tab_area, .none => .none,
            };
        };
        if (new_hover != self.tab_hover) {
            self.tab_hover = new_hover;
            self.invalidateRenderer();
        }
    }

    pub fn handleTabClick(self: *App, mouse_x: c_int, mouse_y: c_int) void {
        if (self.session.count() == 0) return;

        const layout = self.tabBarLayout();
        const area = if (self.session.count() == 1)
            self.singleControlHit(mouse_x, mouse_y)
        else if (mouse_y < self.effectiveTabBarHeight())
            self.tabBarHitArea(mouse_x, layout)
        else
            .none;
        switch (area) {
            .left_arrow => {
                if (layout.left_enabled) self.scrollTabsByArrow(.left);
                return;
            },
            .right_arrow => {
                if (layout.right_enabled) self.scrollTabsByArrow(.right);
                return;
            },
            .plus => {
                // #329 — MAX_TABS 도달 시 비활성 `+` 클릭은 완전 noop (dialog
                // 없음 — 비활성 overflow 화살표와 같은 관례).
                if (!layout.plus_enabled) return;
                if (self.resolveRunAction(.new_tab)) self.handleNewTab();
                return;
            },
            // #268 — 우측 끝 `x` = 활성 탭 닫기 (per-tab close 대체).
            .close => {
                if (self.resolveRunAction(.close_tab)) self.closeTab(self.session.activeIndex());
                return;
            },
            .more => {
                if (!self.resolveRunAction(.open_command_menu)) return;
                self.command_menu_open = !self.command_menu_open;
                self.command_menu_hover = null;
                self.invalidateRenderer();
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

        // #329 — mouse 탭 전환도 keyboard switch_tab 과 같은 정책: 터미널
        // preedit 을 이전 탭에 먼저 commit (늦은 GCS_RESULTSTR 가 새 활성
        // 탭으로 새는 것 방지).
        if (!self.resolveRunAction(.switch_tab)) return;
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
        _ = self.tab_drag.begin(world_x, self.TAB_WIDTH, self.session.count());
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
        _ = self.tab_drag.move(world_x);
    }

    pub fn handleDragEnd(self: *App) void {
        if (self.tab_drag.finish(self.TAB_WIDTH, self.session.count())) |request| {
            if (self.session.reorderTabs(request.from, request.to) catch false) {
                // drag reorder 끝 — 활성 탭 위치 변경, ensure 재가동.
                self.tab_scroll_user_override = false;
                self.invalidateRenderer();
            }
        }
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

    /// #296 — app_event.Shortcut → 입력 정책 Shortcut 매핑 (commit 여부 판정용).
    fn appShortcutToPolicy(sc: app_event.Shortcut) input_policy.Shortcut {
        return switch (sc) {
            .new_tab => .new_tab,
            .close_active_tab => .close_tab,
            .reset_terminal => .reset_terminal,
            .dump_perf => .dump_perf,
            .show_about => .show_about,
            .open_config => .open_config,
            .open_log => .open_log,
            .switch_tab => .switch_tab,
            .next_tab => .next_tab,
            .prev_tab => .prev_tab,
            .copy_selection => .copy_selection,
            .toggle_visibility => .toggle_visibility,
            .fullscreen => .fullscreen,
        };
    }

    /// Windows의 실제 IMM preedit 상태로 공통 입력 정책을 resolve하고 native
    /// pending 을 적용한다. `imeCompleteComposition` 안에서 GCS_RESULTSTR가
    /// 동기 text_input으로 원래 대상에 먼저 들어온다. complete가 실패하면
    /// action을 보류해 queued WM_CHAR가 다른 대상에 들어가는 것을 막는다.
    /// cancel은 정책대로 best-effort이며 ETX는 호출자가 한 번 보낸다.
    fn resolveWindowsInput(self: *App, input: input_policy.Input) ?input_policy.Disposition {
        const resolution = windows_input_adapter.resolve(input, .{
            .ime_preedit_len = self.window.imePreeditSlice().len,
            .ime_result_deferred = self.window.imeHasDeferredResult(),
        });

        switch (resolution.native_pending) {
            .none => {},
            .preserve_ime => if (!self.window.imePreserveComposition()) return null,
            .complete_ime => if (!self.window.imeCompleteComposition()) return null,
            .cancel_ime => _ = self.window.imeCancelComposition(),
        }
        return resolution.disposition;
    }

    pub fn onAppEvent(event: app_event.Event, userdata: ?*anyopaque) bool {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        switch (event) {
            .text_input => |cp| {
                // #329 — 메뉴가 열려 있으면 문자도 메뉴 계층이 소비 (Space =
                // 실행, Tab = 이동, 그 외 noop — native menu 동등).
                if (self.command_menu_open) {
                    self.handleCommandMenuKey(switch (cp) {
                        ' ' => .space,
                        // WM_CHAR 0x09 는 shift 를 안 담음 — Shift+Tab 역방향
                        // 이동을 위해 직접 확인 (재감사 발견, mac/linux 대칭).
                        0x09 => if (self.window.isShiftDown()) command_menu.MenuKey.shift_tab else .tab,
                        else => command_menu.MenuKey.other,
                    });
                    return true;
                }
                return false;
            },
            .key_input => |key| {
                // #329 — 메뉴 keyboard navigation. PTY escape seq 로 안 새게 소비.
                if (self.command_menu_open) {
                    self.handleCommandMenuKey(switch (key) {
                        .escape => .escape,
                        .enter => .enter,
                        .up => .up,
                        .down => .down,
                        .home => .home,
                        .end => .end,
                        else => command_menu.MenuKey.other,
                    });
                    return true;
                }
                return false;
            },
            .paste => |bytes| {
                // #329 — 명시적 paste 명령(Ctrl+Shift+V)은 메뉴를 닫고 정상 실행.
                if (self.command_menu_open) self.closeCommandMenu();
                // PTY paste (bracketed paste + wrap 은 session 가). mac
                // handlePaste 와 같은 path.
                const disposition = self.resolveWindowsInput(.paste) orelse return true;
                if (disposition.target == .pty) {
                    tab_actions.routePaste(&self.host, bytes);
                }
                return true;
            },
            .interrupt => {
                if (self.command_menu_open) self.closeCommandMenu();
                const disposition = self.resolveWindowsInput(.interrupt) orelse return true;
                if (disposition.target == .pty) self.session.interruptActive("\x03");
                return true;
            },
            .mouse_right_down => {
                // #329 — 열린 menu 는 모든 pointer button 보다 우선. 우클릭은
                // 메뉴만 닫고 paste 하지 않는다 (SPEC §5.3). false 면 window 가
                // 기존 즉시 paste (#119).
                if (self.command_menu_open) {
                    self.closeCommandMenu();
                    return true;
                }
                return false;
            },
            .shortcut => |shortcut| {
                // #329 — 단축키는 메뉴를 먼저 닫고 정상 실행 (toggle 로 hide
                // 해도 열린 메뉴가 남지 않음).
                if (self.command_menu_open) self.closeCommandMenu();
                // #296 — 단축키의 preedit commit 여부는 입력 정책(input_policy)
                // 한 곳에서. 상태 변경 단축키는 focus_loss 로 preedit 을 commit
                // 후 실행 (SPEC §4.1).
                const disposition = self.resolveWindowsInput(.{ .shortcut = appShortcutToPolicy(shortcut) }) orelse return true;
                if (disposition.target != .run_action) return true;
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
                        const path = log.filePath() orelse return true;
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
                    .toggle_visibility => {
                        self.window.toggle();
                        return true;
                    },
                    .fullscreen => |workarea| {
                        self.window.toggleFullscreenMode(if (workarea) .workarea else .monitor);
                        return true;
                    },
                }
            },
            .mouse_down => |mouse| {
                if (self.command_menu_open) {
                    // #334 — 스크롤 표시 행 클릭 = 한 entry 스크롤, 메뉴 유지.
                    const menu_view = self.commandMenuView();
                    const px_pt = @as(f32, @floatFromInt(mouse.x)) / self.dpi_scale;
                    const py_pt = @as(f32, @floatFromInt(mouse.y)) / self.dpi_scale;
                    if (command_menu.hitScrollIndicator(menu_view, px_pt, py_pt)) |dir| {
                        self.command_menu_first = command_menu.scrollStep(menu_view, dir == .down);
                        self.invalidateRenderer();
                        return true;
                    }
                    const hit = self.commandMenuHit(mouse.x, mouse.y);
                    self.closeCommandMenu();
                    if (hit) |command| self.executeCommandMenu(command);
                    return true;
                }
                const single_control = self.singleControlHit(mouse.x, mouse.y);
                if (mouse.y < self.effectiveTabBarHeight() or single_control != .none) {
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
                        tab.interaction.scrollbar.begin(self.scrollbarGrabAt(mouse.y));
                        tab.interaction.selection.cancel();
                    }
                    self.tab_drag.reset();
                    self.scrollToY(mouse.y);
                    return true;
                }
                self.tab_drag.reset();
                if (self.activeTabPtr()) |tab| tab.interaction.scrollbar.end();
                self.startTerminalSelection(mouse.x, mouse.y);
                return true;
            },
            .mouse_double_click => |mouse| {
                if (self.singleControlHit(mouse.x, mouse.y) != .none) return true;
                // 탭바 더블클릭은 소비만 (rename 은 #341 로 제거).
                if (mouse.y >= self.effectiveTabBarHeight()) {
                    self.selectWordAt(mouse.x, mouse.y);
                }
                return true;
            },
            .mouse_move => |mouse| {
                if (mouse.left_button) {
                    const tab_opt = self.activeTabPtr();
                    if (tab_opt != null and tab_opt.?.interaction.scrollbar.active) {
                        self.scrollToY(mouse.y);
                    } else if (self.tab_drag.active) {
                        self.handleDragMove(mouse.x);
                    } else if (tab_opt != null and tab_opt.?.interaction.selection.active) {
                        self.updateTerminalSelection(mouse.x, mouse.y);
                    }
                }
                self.updateTabHover(mouse.x, mouse.y);
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
                if (self.tab_drag.active) {
                    self.handleDragEnd();
                } else {
                    self.finishTerminalSelection();
                }
                return true;
            },
            .scroll => |scroll_event| {
                // #329 — 열린 menu 는 wheel 도 소비한다. 작은 viewport 에서
                // 잘린 항목 도달 경로 (entry 단위 scroll). terminal 로 안 보냄.
                if (self.command_menu_open) {
                    switch (scroll_event) {
                        .wheel => |wheel| {
                            // #334 — 정밀 휠/터치패드(delta<120)도 스크롤되게
                            // 누적 + 나머지 보존 (재감사 발견 — divTrunc 단독은
                            // 120 미만에서 항상 0).
                            self.command_menu_wheel_accum += wheel;
                            var steps = @divTrunc(self.command_menu_wheel_accum, 120);
                            self.command_menu_wheel_accum -= steps * 120;
                            while (steps != 0) {
                                const down = steps < 0; // 양수 = 위로 (WHEEL_DELTA)
                                const next = command_menu.scrollStep(self.commandMenuView(), down);
                                if (next == self.command_menu_first) break;
                                self.command_menu_first = next;
                                self.invalidateRenderer();
                                steps += if (down) @as(i32, 1) else -1;
                            }
                        },
                        .page => {},
                    }
                    return true;
                }
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
