const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const ghostty = @import("ghostty-vt");
const app_event = @import("app_event.zig");
const input_policy = @import("input_policy.zig");
const windows_input_adapter = @import("windows_input_adapter.zig");
const session_core = @import("session_core.zig");
const pane_layout = @import("pane_layout.zig");
const SessionCore = session_core.SessionCore;
const SessionTab = session_core.Tab;
const tab_interaction = @import("tab_interaction.zig");
const tab_layout = @import("tab_layout.zig");
const tab_actions = @import("tab_actions.zig");
const terminal_interaction = @import("terminal_interaction.zig");
const mouse_report = @import("mouse_report.zig");
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
const run_options = @import("run_options.zig");

/// #483 5단계 — 분할선 드래그 상태 (Linux `Client.sep_drag` 상당). 놓을 때만 트리에 적용한다 — 드래그
/// 중엔 프레임이 트리 복사본에 놓아 본 자리에 amber 고스트를 그린다.
const SepDrag = struct { node: u8, axis: pane_layout.Axis, px: c_int };

pub const App = struct {
    /// #451 — 진입점이 만든 `Io` · 환경변수 묶음. 릴리즈 노트가 지정한 두 길 중
    /// "context struct 에 담아 넘긴다" 로, host 의 `run(rt, …)` 이 여기 심는다.
    rt: Runtime,
    session: SessionCore,
    window: Window,
    allocator: std.mem.Allocator,
    /// #248 — `config.shell` (UTF-8 원본). 런타임 새 탭 생성 직전 shell 바이너리
    /// 재검증용 (startup `validateOrFatal` 과 같은 값). host(`windows.zig`)가 set.
    shell: []const u8 = "",
    renderer: ?RendererBackend = null,
    /// [#506](https://github.com/ensky0/tildaz/issues/506) — `-size COLSxROWS` 요청.
    /// host (`windows.zig`) 가 심는다. 창 크기를 boot 에서 한 번 정하고 마는 것이
    /// 아니라 **탭 수가 1↔2 로 바뀔 때마다 다시 정해야** 해서 (탭바가 세로 공간을
    /// 먹거나 돌려준다) App 이 요청을 들고 있어야 한다.
    grid: ?run_options.Grid = null,
    /// #376 — 직전 tick 의 blink 위상. 이 값이 **바뀌는 프레임에만** 렌더 게이트를
    /// 연다. "화면에 blink 셀이 있다" 로 열면 매 tick(16ms) 그리게 되지만, 위상
    /// 전환은 1초에 두 번뿐이라 추가 렌더가 초당 2프레임이다.
    last_blink_phase: bool = false,
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
    /// #502 — mouse reporting / alternate scroll 의 휠 notch 누적. 정밀 휠 ·
    /// 터치패드는 이벤트당 `WHEEL_DELTA` 미만이 와서 (#334 와 같은 문제) 누적
    /// 없이는 한 notch 도 안 나간다. 나머지는 보존한다.
    report_wheel_accum: i32 = 0,
    sep_drag: ?SepDrag = null,
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

    fn winHostInvalidate(_: *tab_actions.Host) void {
        // #483 2단계 ① — 이전에는 렌더러의 공유 `render_state` 를 초기화했다. 스냅숏이
        // 탭의 것이 되어 초기화할 것이 없고, 다음 프레임은 `wndProc` 이 메시지마다 여는
        // `needs_render` 가 그린다 (macOS 와 같은 no-op).
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

    /// #506 — `-size` 가 요청한 격자를 담는 창 크기를 **지금 탭바 높이 기준으로** 환산한다.
    ///
    /// 창 크기 경로가 퍼센트 기반이라 (`Window.percentForPixels` 주석) 픽셀을 퍼센트로
    /// 바꿔 넣는다. 예전에는 boot 에서 탭바를 `0` 으로 두고 한 번만 환산해서, 탭을 만들면
    /// 탭바가 먹은 만큼 격자가 조용히 줄었다 — 요청한 셀 수로 재는 측정이 그 순간부터
    /// 다른 격자를 재고 있었다.
    pub fn gridWindowPercent(self: *App) ?Window.SizePercent {
        const want = self.grid orelse return null;
        const cell_w: i64 = @intCast(self.window.cell_width_px);
        const cell_h: i64 = @intCast(self.window.cell_height_px);
        const vp = ui_metrics.viewportForGrid(
            want.cols,
            want.rows,
            self.TERMINAL_PADDING,
            self.SCROLLBAR_W,
            self.effectiveTabBarHeight(),
            cell_w,
            cell_h,
        );
        // 셀 절반을 여유로 더하는 이유는 `percentForPixels` 주석 참고.
        return self.window.percentForPixels(vp.w + @divTrunc(cell_w, 2), vp.h + @divTrunc(cell_h, 2));
    }

    /// #506 — `-size` 요청을 이 화면에서 지킬 수 있는지. Linux · macOS 의 같은 이름 함수와
    /// 같은 규칙이다 — **탭바를 포함해 재고**, 못 지키면 실행하지 않는다. 탭바를 미리 넣는
    /// 이유는 `ui_metrics.gridFitsScreen` 주석에 있다.
    ///
    /// **boot 에서 한 번만 부른다.** 실행 중에 다른 모니터로 옮겼다고 이미 돌고 있는
    /// 터미널을 죽이는 것은 이 가드의 일이 아니다.
    pub fn guardRequestedGridFits(self: *App) void {
        const want = self.grid orelse return;
        const area = self.window.workAreaSize() orelse return;
        const fit = ui_metrics.gridFitsScreen(
            want.cols,
            want.rows,
            self.TERMINAL_PADDING,
            self.SCROLLBAR_W,
            // **탭 수와 무관한** 탭바 높이 — 이 시점엔 탭이 없어 `effectiveTabBarHeight`
            // 가 0 이지만, 사용자는 언제든 탭을 둘로 만든다.
            self.TAB_BAR_HEIGHT,
            @intCast(self.window.cell_width_px),
            @intCast(self.window.cell_height_px),
            area.w,
            area.h,
        );
        if (fit.fits) return;
        run_options.exitSizeDoesNotFit(want, fit.needed_w, fit.needed_h, area.w, area.h);
    }

    /// #506 — 탭 수가 1↔2 로 바뀌었을 때의 geometry 재동기화.
    ///
    /// 평소에는 창 크기가 그대로이므로 격자만 다시 계산하면 된다 (#127). `-size` 는
    /// 반대다 — **격자가 기준**이라 탭바가 생긴 만큼 창을 키워야 요청 격자가 유지된다.
    /// 창을 다시 잡으면 `WM_SIZE` 로 격자가 따라오지만, 창 크기가 안 바뀌는 경우
    /// (`-size` 없음) 도 있으므로 격자 동기화는 항상 한다.
    fn syncGeometryAfterTabCountChange(self: *App) void {
        if (self.gridWindowPercent()) |pct| {
            self.window.setPosition(self.window.dock, pct.w, pct.h, self.window.offset_percent);
        }
        self.syncPaneGrids();
    }

    /// #483 5단계 — 모든 탭의 pane 격자를 layout 에 맞춘다 (`applyLayouts`, 같은 격자면 건너뜀). `-size` 측정
    /// 인스턴스는 창 안 단축키가 없어 분할이 없으므로 pane 하나에 요청 격자 그대로 (#382 — 이전의 `resizeAll`).
    fn syncPaneGrids(self: *App) void {
        if (self.grid != null) {
            const grid = self.getTerminalGridSize();
            self.session.resizeAll(grid.cols, grid.rows);
            return;
        }
        self.session.applyLayouts(self.paneArea(), self.paneMetrics());
    }

    pub fn createTab(self: *App) !void {
        const before: usize = self.session.count();
        const grid = self.getTerminalGridSize();
        try self.session.createTab(grid.cols, grid.rows);
        // 1 → 2 전환에서 탭바가 새로 나타나며 cell 영역이 줄어든다 (#127).
        // 새 grid 로 모든 탭 동기화. 다른 count 변화는 그대로.
        if (before == 1) self.syncGeometryAfterTabCountChange();
    }

    /// 인덱스 기반 close — 탭바 close 버튼 마우스 클릭 path. helper 가 마지막
    /// 탭 → terminate (`window.closeAfterShellExit`), 그 외 → override clear +
    /// invalidate. .changed 일 때만 grid resize (#127, 2 → 1 전환).
    fn closeTab(self: *App, index: usize) void {
        if (tab_actions.closeIndex(&self.host, index) == .changed) {
            // #483 — pane 이 닫혀도 (탭 수 그대로) 남은 pane 이 자리를 이어받으므로 격자를 맞춘다; 2 → 1 탭
            // 전환 (#127) 도 같은 경로다 (`applyLayouts` 는 같은 격자면 건너뛴다).
            self.syncGeometryAfterTabCountChange();
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
        // #483 5단계 — 분할선 위 (±slop) 는 리사이즈 커서, pane 의 셀 영역 (padding · scrollbar 자리 안쪽) 은
        // I-beam. pane 하나면 이전의 창 기준 판정과 같다.
        if (self.separatorAt(x, y)) |s| return if (s.axis == .side_by_side) .separator_v else .separator_h;
        var buf: [pane_layout.MAX_PANES_PER_TAB]pane_layout.PaneRect = undefined;
        const lay = self.activeLayout(&buf);
        const id = pane_layout.paneAt(lay, x, y) orelse return .other;
        const pr = pane_layout.find(lay, id) orelse return .other;
        const pad = self.TERMINAL_PADDING;
        if (x < pr.grid_x or y < pr.grid_y) return .other; // 좌측 / 상단 padding
        if (y >= pr.rect.y + pr.rect.h - pad) return .other; // 하단 padding
        if (x >= pr.rect.x + pr.rect.w - pad - self.SCROLLBAR_W) return .other; // 우측 padding · 스크롤바
        return .cell;
    }

    // ── #483 5단계 — pane 기하 helper (Linux `Client.paneMetrics` … · macOS `paneMetricsMac` … 상당) ──

    fn paneMetrics(self: *const App) pane_layout.Metrics {
        return .{
            .cell_w = self.window.cell_width_px,
            .cell_h = self.window.cell_height_px,
            .pad = self.TERMINAL_PADDING,
            .scrollbar_w = self.SCROLLBAR_W,
            .separator_w = @intFromFloat(ui_metrics.linePx(ui_metrics.PANE_SEPARATOR_W_PT, self.dpi_scale)),
        };
    }

    /// 탭바를 뺀 터미널 영역 (`pane_layout.layout` 의 `rect`).
    fn paneArea(self: *const App) pane_layout.Rect {
        const size = self.window.getClientSize();
        const tab_bar_h = self.effectiveTabBarHeight();
        return .{ .x = 0, .y = tab_bar_h, .w = size.w, .h = size.h - tab_bar_h };
    }

    /// 활성 탭의 pane 배치 (최대화 반영, `TabGroup.layout`). 창 · 탭이 없으면 빈 slice.
    fn activeLayout(self: *const App, buf: *[pane_layout.MAX_PANES_PER_TAB]pane_layout.PaneRect) []pane_layout.PaneRect {
        if (self.window.hwnd == null) return buf[0..0];
        const sess = &self.session;
        if (sess.active_tab >= sess.tabs.items.len) return buf[0..0];
        return sess.tabs.items[sess.active_tab].layout(self.paneArea(), self.paneMetrics(), buf);
    }

    fn activePaneRect(self: *const App) ?pane_layout.PaneRect {
        const sess = &self.session;
        if (sess.active_tab >= sess.tabs.items.len) return null;
        var buf: [pane_layout.MAX_PANES_PER_TAB]pane_layout.PaneRect = undefined;
        return pane_layout.find(self.activeLayout(&buf), sess.tabs.items[sess.active_tab].active_pane);
    }

    /// 활성 pane 의 첫 셀 좌상 px. pane 이 없으면 pane 하나일 때의 값 (`pad` · `tab_bar_h + pad`).
    fn activeGridOrigin(self: *const App) struct { x: c_int, y: c_int } {
        if (self.activePaneRect()) |pr| return .{ .x = pr.grid_x, .y = pr.grid_y };
        return .{ .x = self.TERMINAL_PADDING, .y = self.effectiveTabBarHeight() + self.TERMINAL_PADDING };
    }

    /// 활성 pane 의 격자 (터미널의 cols/rows). 탭이 없으면 창 격자.
    fn activeGrid(self: *const App) struct { cols: u16, rows: u16 } {
        if (self.session.tabs.items.len > self.session.active_tab) {
            const t = self.session.tabs.items[self.session.active_tab].activeTab();
            return .{ .cols = @max(1, t.terminal.cols), .rows = @max(1, t.terminal.rows) };
        }
        const g = self.getTerminalGridSize();
        return .{ .cols = g.cols, .rows = g.rows };
    }

    /// pane 의 scrollbar track inset — 단일 탭 컨트롤 스트립 (#329) 은 오른쪽 위에 얹히므로 그 모서리를 가진
    /// pane 만 (pane 하나면 이전의 `scrollbarTopInset − tab_bar_h`).
    fn paneScrollbarTopInset(self: *const App, rect: pane_layout.Rect, area: pane_layout.Rect) c_int {
        const inset = self.scrollbarTopInset() - self.effectiveTabBarHeight();
        if (inset <= 0) return 0;
        return if (rect.y == area.y and rect.x + rect.w == area.x + area.w) inset else 0;
    }

    /// 포인터 아래의 분할선 (양쪽 `PANE_SEPARATOR_HIT_SLOP_PT`). 메뉴가 떠 있으면 null.
    fn separatorAt(self: *const App, x: c_int, y: c_int) ?pane_layout.Separator {
        if (self.window.hwnd == null or self.command_menu_open) return null;
        const sess = &self.session;
        if (sess.active_tab >= sess.tabs.items.len) return null;
        var buf: [pane_layout.MAX_PANES_PER_TAB]pane_layout.Separator = undefined;
        const seps = sess.tabs.items[sess.active_tab].separators(self.paneArea(), self.paneMetrics(), &buf);
        const slop = ui_metrics.scaledPx(c_int, ui_metrics.PANE_SEPARATOR_HIT_SLOP_PT, self.dpi_scale);
        return pane_layout.separatorAt(seps, x, y, slop);
    }

    /// 포인터가 활성 pane 의 scrollbar 자리 (오른쪽 `SCROLLBAR_W`, pane 높이 전체) 안인가. pane 하나면 이전의
    /// `x >= client_w − SCROLLBAR_W` 와 같다.
    fn inActiveScrollbarColumn(self: *const App, x: c_int, y: c_int) bool {
        const pr = self.activePaneRect() orelse return false;
        return x >= pr.rect.x + pr.rect.w - self.SCROLLBAR_W and x < pr.rect.x + pr.rect.w and y >= pr.rect.y and y < pr.rect.y + pr.rect.h;
    }

    /// 포인터 아래 pane 이 활성 pane 이 아니면 그 pane 으로 포커스를 옮기고 true (Linux · macOS 와 같은 규칙).
    fn focusPaneUnderPointer(self: *App, x: c_int, y: c_int) bool {
        const group = self.session.activeGroup() orelse return false;
        const id = self.session.paneIdAt(x, y, self.paneArea(), self.paneMetrics()) orelse return false;
        if (id == group.active_pane) return false;
        group.activeTab().interaction.cancelPointerModes();
        self.window.setAutoScroll(false);
        _ = self.session.setActivePane(id);
        log.appendLine("pane", "focus by click — active pane {}", .{id});
        return true;
    }

    /// 활성 pane 을 `dir` 쪽으로 가른다. 거부 (`TooSmall` · `TooManyPanes`) 는 탭 한도와 같은 dialog.
    fn handleSplit(self: *App, dir: pane_layout.Direction) void {
        if (self.window.hwnd == null) return;
        if (!shell_validate.checkForNewTab(self.rt, self.allocator, self.shell)) return;
        self.session.splitActive(dir, self.paneArea(), self.paneMetrics()) catch |err| switch (err) {
            error.TooSmall => {
                var buf: [160]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, messages.pane_too_small_format, .{ pane_layout.MIN_PANE_COLS, pane_layout.MIN_PANE_ROWS }) catch
                    messages.pane_too_small_format;
                dialog.showInfo(self.rt, messages.pane_too_small_title, msg);
                return;
            },
            error.TooManyPanes => {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, messages.pane_limit_format, .{pane_layout.MAX_PANES_PER_TAB}) catch
                    messages.pane_limit_format;
                dialog.showInfo(self.rt, messages.pane_limit_title, msg);
                return;
            },
            error.NoActiveTab => return,
            else => {
                log.appendLine("pane", "split failed: {s}", .{@errorName(err)});
                return;
            },
        };
        const group = self.session.activeGroup().?;
        log.appendLine("pane", "split {s} — tab {} has {} panes, active pane {}", .{ @tagName(dir), self.session.active_tab, group.paneCount(), group.active_pane });
    }

    fn handleFocusPane(self: *App, dir: pane_layout.Direction) void {
        const leaving = self.activeTabPtr() orelse return;
        if (!self.session.focusPane(dir, self.paneArea(), self.paneMetrics())) return;
        leaving.interaction.cancelPointerModes();
        self.window.setAutoScroll(false);
        // 최대화가 풀렸을 수 있다 → 펼친 격자로 (같으면 건너뛴다).
        self.syncPaneGrids();
        log.appendLine("pane", "focus {s} — active pane {}", .{ @tagName(dir), self.session.activeGroup().?.active_pane });
    }

    fn handleResizePane(self: *App, dir: pane_layout.Direction) void {
        _ = self.session.resizeActivePane(dir, 1, self.paneArea(), self.paneMetrics());
    }

    fn handleEqualizePanes(self: *App) void {
        if (self.session.activeGroup() == null) return;
        self.session.equalizeActive(self.paneArea(), self.paneMetrics());
    }

    /// `Ctrl+Shift+Z` — 활성 pane 최대화 토글. 격자는 `syncPaneGrids` 가 맞춘다 (켤 때 그 pane 만, 풀 때 모두).
    fn handleZoomPane(self: *App) void {
        if (!self.session.toggleZoomActive()) return;
        self.syncPaneGrids();
        log.appendLine("pane", "zoom {s} — active pane {}", .{ if (self.session.activeGroup().?.zoomed != null) "on" else "off", self.session.activeGroup().?.active_pane });
    }

    /// `+` 클릭 — Alt 를 누르고 있으면 새 탭 대신 활성 pane 분할 (Windows Terminal 의 Alt+클릭 선례). 방향은
    /// pane 모양대로 — 넓으면 오른쪽, 높으면 아래.
    fn handlePlusClick(self: *App) void {
        if (!self.window.isAltDown()) {
            if (self.resolveRunAction(.new_tab)) self.handleNewTab();
            return;
        }
        if (!self.resolveRunAction(.split)) return;
        const pr = self.activePaneRect() orelse return;
        self.handleSplit(if (pr.rect.w >= pr.rect.h) .right else .down);
    }

    /// 분할선 드래그를 놓았다 — 여기서 한 번만 트리에 적용 + 격자 (PTY resize 한 번, 확정 설계 축 2).
    fn finishSeparatorDrag(self: *App, d: SepDrag) void {
        if (self.session.setSeparatorPx(d.node, d.px, self.paneArea(), self.paneMetrics())) {
            log.appendLine("pane", "separator drag — node {} to {s} {}", .{ d.node, if (d.axis == .side_by_side) "x" else "y", d.px });
        }
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
        self.tab_scroll_x = @trunc(new_sx);
    }

    /// 화살표 클릭으로 viewport 한 step (= 1 탭 너비) 이동 (#117). 양 끝 clamp.
    /// `tab_scroll_user_override = true` 로 ensure 잠시 비활성 → 활성 탭 변경
    /// 시 다시 활성.
    fn scrollTabsByArrow(self: *App, dir: tab_layout.ArrowDir) void {
        const inputs = self.tabBarLayoutInputs();
        const layout = tab_layout.compute(inputs);
        if (tab_layout.scrollByArrow(inputs, layout, dir)) |sx| {
            self.tab_scroll_x = @trunc(sx);
            self.tab_scroll_user_override = true;
        }
    }

    /// 터미널 격자 크기. 계산은 공통 `ui_metrics` 가 한다 — 열 수는 좌우 padding +
    /// scrollbar 자리 차감 (#350), 행 수는 탭바 + 위아래 padding 차감 (#352).
    ///
    /// #352 — 이전에는 `hwnd == null → {120, 30}` 과 `cell_*_px > 0` 두 갈래의 매직
    /// fallback 이 있었다. 둘 다 **도달 불가**다. `hwnd` 는 [`host/windows.run`] 의
    /// `try app.window.init(...)` 이 성공한 뒤에만 이 함수가 불리므로 항상 있고
    /// (실패는 `error.CreateWindowFailed` 로 `run()` 을 중단시킨다), `cell_*_px` 는
    /// `font/spec.ceilPositivePx` 를 거쳐 0 이 될 수 없다. 일어날 수 없는 상태에
    /// 그럴듯한 값을 채우는 것은 그 값이 어디까지 흘러가는지 추적을 어렵게 만든다 —
    /// 이제 불변식은 아래 assert 로 밝히고, 극단값 방어는 `terminalCols` /
    /// `terminalRows` 의 "최소 1" 계약 한 곳에 있다.
    fn getTerminalGridSize(self: *const App) struct { cols: u16, rows: u16 } {
        std.debug.assert(self.window.hwnd != null);
        const size = self.window.getClientSize();
        return .{
            .cols = ui_metrics.terminalCols(size.w, self.TERMINAL_PADDING, self.SCROLLBAR_W, self.window.cell_width_px),
            .rows = ui_metrics.terminalRows(size.h, self.effectiveTabBarHeight(), self.TERMINAL_PADDING, self.window.cell_height_px),
        };
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
        return dialog.showConfirm(self.rt, messages.quit_confirm_title, msg);
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

    /// #352 — `resize_fn` 은 "창 크기가 바뀌었다" 는 알림만 준다. 이전 시그니처는
    /// cols/rows 를 받았지만 여기서 `getTerminalGridSize` 로 다시 계산하고 인자는
    /// 버렸다 (window layer 는 padding · scrollbar · 탭바를 모른다).
    pub fn onResize(userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        if (self.renderer) |*r| {
            const size = self.window.getClientSize();
            r.resize(@intCast(@max(1, size.w)), @intCast(@max(1, size.h)));
        }
        self.syncPaneGrids();
    }

    /// Recompute DPI-dependent UI constants (tab bar / close button / padding /
    /// scrollbar) from `new_dpi`. Called at startup and whenever the window
    /// moves between monitors with different DPI scales.
    pub fn applyDpiScale(self: *App, new_dpi: c_uint) void {
        const effective: f32 = if (new_dpi > 0) @as(f32, @floatFromInt(new_dpi)) else 96.0;
        const scale: f32 = effective / 96.0;
        self.dpi_scale = scale;
        self.TAB_BAR_HEIGHT = @intCast(ui_metrics.tabBarHeightPx(scale));
        self.TAB_WIDTH = ui_metrics.scaledPx(c_int, ui_metrics.TAB_WIDTH_PT, scale);
        self.TAB_ARROW_W = ui_metrics.scaledPx(c_int, ui_metrics.TAB_ARROW_W_PT, scale);
        self.TAB_PLUS_W = ui_metrics.scaledPx(c_int, ui_metrics.TAB_PLUS_W_PT, scale);
        self.TAB_CLOSE_W = ui_metrics.scaledPx(c_int, ui_metrics.TAB_CLOSE_W_PT, scale);
        self.TAB_MORE_W = ui_metrics.scaledPx(c_int, ui_metrics.TAB_MORE_W_PT, scale);
        self.TAB_PADDING = ui_metrics.scaledPx(c_int, ui_metrics.TAB_PADDING_PT, scale);
        self.SCROLLBAR_W = ui_metrics.scaledPx(c_int, ui_metrics.SCROLLBAR_W_PT, scale);
        self.SCROLLBAR_MIN_THUMB_H = ui_metrics.scaledPx(c_int, ui_metrics.SCROLLBAR_MIN_THUMB_H_PT, scale);
        self.TERMINAL_PADDING = ui_metrics.scaledPx(c_int, ui_metrics.TERMINAL_PADDING_PT, scale);
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

    /// #387 — 사양 A. 메시지 큐가 빈 순간에 밀린 PTY 출력을 한 번 더 파싱한다.
    ///
    /// `DRAIN_FRAME_BUDGET_NS` 는 `drainFrame` 한 번의 **응답성** 상한이지 처리량 상한이
    /// 아니다. 그런데 드레인이 `onRender` 안에만 있으면 프레임당 1 회로 묶여 duty 상한이
    /// `예산 / 프레임간격` 이 되고, 그러면 **화면 주사율이 처리량을 결정**한다 (#386 실측,
    /// 당시 예산 8 ms: 60 Hz 48 % · 120 Hz 88 %). Linux 는 드레인이 poll loop 에 있어
    /// 주사율과 무관하다.
    ///
    /// 호출 시점은 `Window.messageLoop` 이 정한다 — `PeekMessage` 가 비었을 때만이라
    /// **입력과 프레임 tick 이 항상 이 드레인보다 우선**한다. 여기서는 렌더를 하지 않고
    /// 게이트만 열어 두고, 실제 그리기는 다음 프레임 tick 의 `onRender` 가 한다.
    ///
    /// 반환값은 "더 할 일이 있나" — `messageLoop` 이 이 값으로 블록 여부를 정한다.
    /// macOS · Linux 가 쓰는 것과 **같은 공유 함수** (`drainOutputForRender`) 를 부른다.
    pub fn onIdleDrain(userdata: ?*anyopaque) bool {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        if (!self.session.drainOutputForRender()) return false;
        self.window.requestRender();
        return true;
    }

    pub fn onRender(window: *Window) void {
        const self: *App = @ptrCast(@alignCast(window.userdata.?));
        const onrender_t0 = perf.now();
        defer perf.addTimed(&perf.onrender, onrender_t0);

        if (self.renderer) |*r| {
            const size = window.getClientSize();

            // VT 처리 (UI 스레드에서 — mutex 경합 없음). macOS · Linux 와 **같은 공유
            // 함수** — #388 에서 Windows 전용 `prepareActiveFrame` 을 지우고 합쳤다.
            const had_output = self.session.drainOutputForRender();
            // #386 ② — 화면이 바뀌지 않았으면 GPU 작업 (render + present) 을 건너뛴다.
            // macOS #255 Phase 2 동등. 이전에는 출력이 없을 때도 `true` 라 **유휴에도 매
            // 프레임 그렸다** — 출력 0 인 10 초 동안 588 프레임 전부 그린 것이 #386 의 ②다.
            // `needs_render` 는 `wndProc` 이 프레임 tick 이 아닌 모든 메시지에서 연다
            // (window.zig). **이것이 렌더를 줄이는 유일한 게이트다** (#388).
            const should_render = had_output or self.window.needs_render;
            // IME preedit 활성 시 게이트 우회 — preedit UI 는 PTY 출력과 무관하게 매
            // keystroke 즉시 화면 갱신이 필요하다 (mac 동등).
            //
            // ⚠️ 이 우회가 막던 #164 회귀의 원인은 **throttle** 이었고 그건 #388 에서
            // 지웠다. 지금 이 값이 넘는 것은 #386 ② 게이트뿐인데, `WM_IME_COMPOSITION`
            // 이 `wndProc` 에서 `needs_render` 를 열어 주므로 **없어도 될 가능성이 있다.**
            // 확인하지 않았으므로 그대로 둔다 — 지우려면 한글 · 일본어 IME 로 typing
            // 중 preedit 이 즉시 따라오는지 실기 검증이 먼저다.
            const force_render = self.window.imePreeditSlice().len > 0;

            // #376 — blink 위상이 뒤집힌 **그 프레임에만**, 그리고 직전 프레임에
            // blink 셀이 실제로 보였을 때만 연다. 둘을 함께 봐야 blink 이 없는
            // 화면에서 공짜로 초당 2프레임을 낭비하지 않는다.
            const blink_phase_now = ui_metrics.blinkFaintPhase(self.rt.nowMs());
            const blink_tick = blink_phase_now != self.last_blink_phase and r.saw_blink_cell;
            self.last_blink_phase = blink_phase_now;

            // #117 — 활성 탭이 viewport 에 보이도록 scroll 갱신. drag 중인 동안은
            // handleDragMove 가 직접 auto-scroll 하므로 skip. 사용자 화살표
            // override 중에도 skip — 활성 탭 변경 시 reset 되어 재가동.
            if (!self.tab_drag.active and !self.tab_scroll_user_override)
                self.ensureActiveTabVisible();

            // #435 — swap chain 이 다음 프레임을 받을 준비가 됐나. 논블로킹 확인이라
            // UI 스레드를 잡지 않는다. 준비가 안 됐으면 이번 tick 은 그리지 않고 넘겨,
            // 곧장 `messageLoop` 으로 돌아가 유휴 드레인 (#387 사양 A) 을 계속한다.
            //
            // ⚠️ **순서가 중요하다 — 그릴 게 있을 때만 묻는다.** frame-latency waitable 은
            // 세마포어라 **기다려서 통과하면 카운트를 소비**하고, 그 카운트는 `Present` 한
            // 프레임이 물러날 때 돌아온다 (그래서 정석이 "기다린다 → 반드시 present 한다"
            // 1:1 이다). 그릴지 정하기 전에 물으면 유휴 프레임이 카운트만 먹고 present 를
            // 안 해서 카운트가 영영 안 돌아오고, 몇 프레임 뒤부터 화면이 멈춘다.
            //
            // **`needs_render` 를 지우지 않는 것도 핵심이다** — 아래 게이트를 통과했을
            // 때만 닫는다. 여기서 닫으면 "그릴 이유가 있었는데 안 그린" 프레임의 이유가
            // 사라져, 다음 출력이 올 때까지 화면이 멈춘다.
            //
            // waitable 이 없는 경로 (legacy DISCARD · DirectComposition) 는 `frameReady`
            // 가 항상 true 라 동작이 이 이슈 이전과 완전히 같다.
            const want_render = should_render or force_render or blink_tick;
            // #439 — 그릴 것이 없으면 유휴다. read thread 가 이 값을 보고 통보 여부를 정한다
            // (`Window.notifyPtyOutput` — 폭포에서 통보하면 사양 A 드레인이 굶는다).
            self.window.frame_idle.store(!want_render, .release);
            const swap_ready = want_render and r.frameReady();
            if (want_render and !swap_ready) perf.incExtra(&perf.swapwait);

            if (swap_ready) {
                // 그리기로 했으니 게이트를 닫는다. 렌더 중에 도착한 메시지는 큐에 있다가
                // 이 프레임 뒤에 처리되면서 다시 열므로 변화를 놓치지 않는다.
                self.window.needs_render = false;
                // 탭바 + 터미널 함께 렌더 (glClear는 renderTabBar에 포함).
                // count<=1 이면 tab_bar_h=0 → 렌더러가 탭바 자체를 그리지 않고
                // 터미널 영역만 (#127 — 단일 탭에서 cell 영역 reserve 안 함).
                const tab_bar_h = self.effectiveTabBarHeight();
                var tab_titles: [32][]const u8 = undefined;
                const tabs = self.session.tabsSlice();
                const n = @min(tabs.len, 32);
                for (tabs[0..n], 0..) |group, i| {
                    // #483 3단계 — 탭바 제목은 그 탭의 활성 pane 의 것.
                    const t = group.activeTab();
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
                if (self.session.activeGroup()) |group| {
                    // #483 5단계 — 활성 탭의 pane 마다 `drawPane` (`TabGroup.layout` 순서 — 최대화면 하나).
                    // rect 는 탭바를 뺀 영역을 트리로 나눈 것 (pane 하나면 2단계와 같은 값).
                    const area = self.paneArea();
                    const m = self.paneMetrics();
                    var rect_buf: [pane_layout.MAX_PANES_PER_TAB]pane_layout.PaneRect = undefined;
                    const lay = group.layout(area, m, &rect_buf);
                    var active_rect: ?pane_layout.Rect = null;
                    for (lay) |pr| {
                        const t = group.panes[pr.pane].?;
                        const is_active = pr.pane == group.active_pane;
                        // 최대화 중이면 pane 하나여도 넘긴다 — 네 변 amber 가 최대화 표시다 (2026-08-27 결정 A).
                        if (is_active and (lay.len > 1 or group.zoomed != null)) active_rect = pr.rect;
                        r.drawPane(.{
                            .terminal = &t.terminal,
                            .state = &t.render_state,
                            .rect = pr.rect,
                            .cell_w = window.cell_width_px,
                            .cell_h = window.cell_height_px,
                            .pad = self.TERMINAL_PADDING,
                            .scrollbar_w = @floatFromInt(self.SCROLLBAR_W),
                            .scrollbar_min_thumb_h = @floatFromInt(self.SCROLLBAR_MIN_THUMB_H),
                            // 단일 탭의 컨트롤 스트립 (#329) 아래로 track 을 내린다 — 오른쪽 위 pane 만.
                            .scrollbar_top_inset = self.paneScrollbarTopInset(pr.rect, area),
                            // IME 자모는 키보드가 가는 pane (활성) 의 cursor 옆에만 (#164).
                            .preedit_utf8 = if (is_active) self.window.imePreeditSlice() else &.{},
                            // #376 — 위쪽 게이트가 이미 구한 위상을 그대로 내린다. 렌더러가
                            // 시계를 다시 읽으면 500 ms 경계에서 둘이 갈릴 수 있다.
                            .blink_faint = blink_phase_now,
                            .is_active = is_active,
                        });
                    }
                    // 분할선 · amber · 드래그 고스트 (Linux · macOS 와 같은 규칙). 고스트는 트리 복사본에
                    // 놓아 본 자리 — 스냅 · 최소 크기 판정을 실제 놓기와 같은 함수가 한다.
                    var sep_buf: [pane_layout.MAX_PANES_PER_TAB]pane_layout.Separator = undefined;
                    const seps = group.separators(area, m, &sep_buf);
                    var ghost: ?pane_layout.Rect = null;
                    if (self.sep_drag) |d| {
                        var trial = group.tree;
                        if (trial.setSeparatorPx(d.node, d.px, area, m)) {
                            var gbuf: [pane_layout.MAX_PANES_PER_TAB]pane_layout.Separator = undefined;
                            for (pane_layout.separators(&trial, area, m, &gbuf)) |s| {
                                if (s.node == d.node) ghost = s.rect;
                            }
                        }
                    }
                    r.drawPaneChrome(seps, area, active_rect, ghost, group.zoomed != null);
                    r.endFrame(
                        size.w,
                        tab_bar_h,
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
                //
                // 개선 후보 (#386 §2.4, 우선순위 낮음): 그리는 **매 프레임** IMM 을 부른다.
                // 조합 중이 아니거나 위치가 안 바뀐 프레임은 건너뛸 수 있다. 폭포 중 프레임당
                // 비용은 측정하지 않았다 — 하려면 조합 여부 · 좌표 변화로 가드를 두면 된다.
                self.window.imeSetCompositionPos(r.last_cursor_px_x, r.last_cursor_px_y);
            } else if (!want_render) {
                // #386 ② 게이트가 닫힌 경우만 여기서 센다. swap chain 대기로 넘긴 tick 은
                // 위에서 `perf.swapwait` 로 따로 세므로 두 이유가 한 칸에 섞이지 않는다.
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
            // #483 — pane 이 닫혀도 (탭 수 그대로) 남은 pane 이 자리를 이어받으므로 격자를 맞춘다; 2 → 1 탭
            // 전환 (#127) 도 같은 경로다 (`applyLayouts` 는 같은 격자면 건너뛴다).
            self.syncGeometryAfterTabCountChange();
        }
    }

    pub fn handleNewTab(self: *App) void {
        if (tab_actions.checkAtLimitAndDialog(self.rt, &self.host)) return;
        // #248 — shell 이 런타임에 사라졌으면 조용히 죽는 대신 알림 후 취소.
        if (!shell_validate.checkForNewTab(self.rt, self.allocator, self.shell)) return;
        self.createTab() catch {};
    }

    pub fn handleCloseActiveTab(self: *App) void {
        // closeActive helper 가 마지막 탭 → terminate (`window.closeAfterShellExit`),
        // 그 외 → override clear + invalidate. .changed 일 때만 platform-specific
        // grid resize (2 → 1 전환에서 탭바 사라짐, #127).
        if (tab_actions.closeActive(&self.host) == .changed) {
            // #483 — pane 이 닫혀도 (탭 수 그대로) 남은 pane 이 자리를 이어받으므로 격자를 맞춘다; 2 → 1 탭
            // 전환 (#127) 도 같은 경로다 (`applyLayouts` 는 같은 격자면 건너뛴다).
            self.syncGeometryAfterTabCountChange();
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
        // #483 6단계 결정 B — 휠은 **포인터 아래 pane** 을 스크롤하고 포커스는 바꾸지 않는다 (분할선 위나 pane
        // 밖이면 활성 pane). 페이지 키는 키라 활성 pane. 행 수는 그 pane 의 것.
        const under: ?*SessionTab = switch (event) {
            .wheel => |w| self.session.paneTabAt(w.x, w.y, self.paneArea(), self.paneMetrics()),
            .page => null,
        };
        const target = under orelse self.session.activeTab() orelse return;
        session_core.SessionCore.scrollTab(target, event, @max(1, target.terminal.rows));
    }

    /// 현재 활성 탭의 scrollbar `Hit` (track geometry + thumb geometry). 스크롤백이
    /// 없거나 thumb 가 들어갈 여유가 없으면 null. 렌더러(`renderer/windows.zig`)와
    /// 같은 `scrollbar.hit` 입력을 써서 그림 영역과 클릭 영역을 일치시킨다 (#259).
    fn scrollbarHit(self: *App) ?scrollbar.Hit {
        const tab = self.activeTabPtr() orelse return null;
        if (self.window.hwnd == null) return null;
        const sb = tab.terminal.screens.active.pages.scrollbar();
        // #483 5단계 — track 은 활성 pane 기준 (렌더러 `thumbRect` 인자와 같은 값 — pane 하나면 이전과 같다).
        const pr = self.activePaneRect() orelse return null;
        return scrollbar.hit(
            sb.total,
            sb.len,
            sb.offset,
            @floatFromInt(pr.rect.y + pr.rect.h),
            @floatFromInt(pr.rect.y + self.paneScrollbarTopInset(pr.rect, self.paneArea())),
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
            // #483 5단계 — 메뉴의 분할 항목 (마우스 경로).
            .split_vertical => if (self.resolveRunAction(.split)) self.handleSplit(.right),
            .split_horizontal => if (self.resolveRunAction(.split)) self.handleSplit(.down),
            .close_active_tab => if (self.resolveRunAction(.close_tab)) self.handleCloseActiveTab(),
            .copy_selection => if (self.resolveRunAction(.copy_selection)) tab_actions.copyActiveSelection(&self.host, self.allocator),
            .paste => self.window.requestPaste(),
            // #334 — 메뉴는 상태 기준 토글: 어떤 모드든 전체화면이면 그 모드를
            // 해제, 아니면 monitor 진입 (키보드 self-symmetric 정책은 그대로).
            .fullscreen => if (self.resolveRunAction(.fullscreen)) self.window.toggleFullscreenMode(if (self.window.fullscreen_mode != .none) self.window.fullscreen_mode else .monitor),
            .open_config => if (self.resolveRunAction(.open_config)) {
                const path = paths.configPath(self.rt, self.allocator) catch return;
                defer self.allocator.free(path);
                self.window.yieldTopmostUntilNextShow();
                system_open.openInDefaultApp(self.rt, self.allocator, path);
            },
            .keyboard_shortcuts => if (self.resolveRunAction(.open_shortcuts)) {
                self.window.yieldTopmostUntilNextShow();
                system_open.openInDefaultApp(self.rt, self.allocator, messages.keyboard_shortcuts_url);
            },
            .about => if (self.resolveRunAction(.show_about)) about.showAboutDialog(self.rt),
        }
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
                // #483 5단계 — Alt+클릭이면 분할 (`handlePlusClick` 이 가른다).
                self.handlePlusClick();
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
                return;
            },
            .none => return,
            .tab_area => {},
        }

        // #117 — tab_area 안에서 mouse_x → world 좌표. 탭 viewport 시작 x 가
        // tab_area_x (화살표 있을 때 ARROW_W) 에 오프셋. world_x = (mouse_x -
        // tab_area_x) + scroll_x.
        const local_x = mouse_x - @as(c_int, @trunc(layout.tab_area_x));
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
        }
    }

    pub fn handleDragStart(self: *App, mouse_x: c_int) void {
        // #117 — DragState 는 world 좌표. 탭 영역 좌표계: world_x = (mouse_x -
        // tab_area_x) + scroll_x. tab_area_x = 화살표 있으면 ARROW_W, 없으면 0.
        const layout = self.tabBarLayout();
        const world_x = (mouse_x - @as(c_int, @trunc(layout.tab_area_x))) + self.tab_scroll_x;
        _ = self.tab_drag.begin(world_x, self.TAB_WIDTH, self.session.count());
    }

    pub fn handleDragMove(self: *App, mouse_x: c_int) void {
        // #117 — drag auto-scroll. mouse_x 가 *탭 영역* 의 좌/우 끝 가까이면
        // scroll 한 step 이동 후 drag.move 에 *갱신된* world 좌표 전달.
        const layout = self.tabBarLayout();
        const total = self.tabBarTotalWidth();
        const tab_area_x_int: c_int = @trunc(layout.tab_area_x);
        const vp: c_int = @trunc(layout.tab_area_w);
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
            }
        }
    }

    /// Windows `WHEEL_DELTA`. 세 host 가 자기 휠 단위를 이 눈금으로 올린다.
    const WHEEL_DELTA: i32 = 120;

    fn reportButton(button: app_event.MouseButton) mouse_report.Button {
        return switch (button) {
            .left => .left,
            .middle => .middle,
            .right => .right,
        };
    }

    /// 셀 영역 pointer 이벤트를 인코더 입력으로. 계산은 cross-platform
    /// `terminal_interaction.reportEvent` 한 곳에 있고 (세 host 공용) 여기서는
    /// Windows 의 기하 값만 채운다.
    fn reportEvent(
        self: *const App,
        action: mouse_report.Action,
        button: ?mouse_report.Button,
        mods: app_event.MouseMods,
        mouse_x: c_int,
        mouse_y: c_int,
        any_button: bool,
    ) mouse_report.Event {
        // #483 5단계 — 격자 원점 · 격자는 활성 pane 의 것.
        const origin = self.activeGridOrigin();
        const grid = self.activeGrid();
        return terminal_interaction.reportEvent(
            action,
            button,
            .{ .shift = mods.shift, .alt = mods.alt, .ctrl = mods.ctrl },
            @intCast(mouse_x),
            @intCast(mouse_y),
            .{
                .cell_w = @intCast(self.window.cell_width_px),
                .cell_h = @intCast(self.window.cell_height_px),
                .cols = grid.cols,
                .rows = grid.rows,
                // #483 — 격자 원점. Windows 는 pane 하나 (5단계 전) 라 `pad` · `tab_bar_h + pad`.
                .grid_x = @intCast(origin.x),
                .grid_y = @intCast(origin.y),
            },
            any_button,
        );
    }

    /// 셀 영역 이벤트를 앱에 보낼지 우리가 처리할지 결정하고, 보낼 것이면 PTY 로
    /// 보낸다. 반환값 = **우리 chrome 이 이 이벤트를 계속 처리해야 하는지**.
    fn routeMouseToApp(self: *App, ev: mouse_report.Event) bool {
        const tab = self.activeTabPtr() orelse return true;
        var buf: [mouse_report.max_len]u8 = undefined;
        const decision = terminal_interaction.routeMouse(&buf, &tab.terminal, &tab.interaction, ev);
        return switch (decision) {
            .local => true,
            .swallow => false,
            .report => |bytes| blk: {
                tab.queueWrite(bytes);
                break :blk false;
            },
        };
    }

    /// 휠을 앱이 가져가야 하면 보내고 true. false 면 기존 scrollback 스크롤.
    ///
    /// tracking 이 켜져 있으면 휠도 보고 (`Cb` 64/65) 로 나간다. 안 켜져 있고
    /// **alt screen + `?1007`** 이면 xterm 관례대로 화살표 키로 바꿔 보낸다 —
    /// alt screen 은 scrollback 이 없어서 그대로 두면 휠이 무동작이다.
    fn routeWheel(self: *App, wheel: app_event.WheelEvent) bool {
        const tab = self.activeTabPtr() orelse return false;
        if (wheel.delta == 0) return false;

        const tracking = terminal_interaction.reportTracking(&tab.terminal);
        const alt_scroll = tracking == .none and
            tab.terminal.screens.active_key == .alternate and
            tab.terminal.modes.get(.mouse_alternate_scroll);
        if (tracking == .none and !alt_scroll) return false;

        // Shift bypass — Shift+휠은 우리 scrollback 스크롤로 남긴다 (클릭·드래그의
        // Shift bypass 와 같은 정책). 앱이 Shift 를 명시로 요구한 경우만 넘긴다.
        if (wheel.mods.shift and terminal_interaction.reportShiftCapture(&tab.terminal) != .app) return false;

        self.report_wheel_accum += wheel.delta;
        const steps = @divTrunc(self.report_wheel_accum, WHEEL_DELTA);
        self.report_wheel_accum -= steps * WHEEL_DELTA;
        // 앱 것이지만 아직 한 notch 가 안 찼다 — 소비하고 우리 스크롤도 안 한다.
        if (steps == 0) return true;

        const up = steps > 0;
        const n: usize = @intCast(@abs(steps));

        if (alt_scroll) {
            // xterm 은 notch 당 3 줄을 보낸다.
            const key = mouse_report.alternateScrollKey(up, tab.terminal.modes.get(.cursor_keys));
            var i: usize = 0;
            while (i < n * 3) : (i += 1) tab.queueWrite(key);
            return true;
        }

        var buf: [mouse_report.max_len]u8 = undefined;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const ev = self.reportEvent(
                .press,
                if (up) .wheel_up else .wheel_down,
                wheel.mods,
                wheel.x,
                wheel.y,
                false,
            );
            switch (mouse_report.route(
                &buf,
                ev,
                tracking,
                terminal_interaction.reportFormat(&tab.terminal),
                terminal_interaction.reportShiftCapture(&tab.terminal),
                null,
            )) {
                .report => |bytes| tab.queueWrite(bytes),
                .local, .swallow => {},
            }
        }
        return true;
    }

    fn mouseToCell(self: *const App, mouse_x: c_int, mouse_y: c_int) terminal_interaction.Cell {
        const cw = self.window.cell_width_px;
        const ch = self.window.cell_height_px;
        // #483 5단계 — 활성 pane 의 격자 원점 · 격자 (pane 하나면 `pad` · `tab_bar_h + pad`).
        const origin = self.activeGridOrigin();
        const grid = self.activeGrid();
        const term_x = mouse_x - origin.x;
        const term_y = mouse_y - origin.y;
        const col: u16 = if (cw > 0 and term_x >= 0) @intCast(@min(@divTrunc(term_x, cw), @as(c_int, grid.cols) - 1)) else 0;
        const row: u16 = if (ch > 0 and term_y >= 0) @intCast(@min(@divTrunc(term_y, ch), @as(c_int, grid.rows) - 1)) else 0;
        return .{ .col = col, .row = row };
    }

    /// #483 6단계 — 마우스 좌표를 선택 문턱 판정용 px 로.
    fn mousePx(mouse_x: c_int, mouse_y: c_int) terminal_interaction.Px {
        return .{ .x = @floatFromInt(mouse_x), .y = @floatFromInt(mouse_y) };
    }

    fn startTerminalSelection(self: *App, mouse_x: c_int, mouse_y: c_int) void {
        const tab = self.activeTabPtr() orelse return;
        const cell = self.mouseToCell(mouse_x, mouse_y);
        const screen: *ghostty.Screen = tab.terminal.screens.active;
        // #483 6단계 — 선택 시작 문턱 (물리 px). DPI 배율 · 셀 크기가 바뀌면 따라 바뀐다.
        const slop = ui_metrics.selectionDragSlopPx(@floatFromInt(self.window.cell_width_px), self.dpi_scale);
        tab.interaction.selection.begin(screen, cell, mousePx(mouse_x, mouse_y), slop);
    }

    fn updateTerminalSelection(self: *App, mouse_x: c_int, mouse_y: c_int) void {
        const tab = self.activeTabPtr() orelse return;
        if (!tab.interaction.selection.active) return;
        if (self.window.hwnd == null) return;

        // #245 — 경계 밖 방향 판정(공유 헬퍼) + 위/아래면 auto-scroll. 포인터를
        // 경계 밖에 멈춰 둬도 연속되도록 window 의 auto-scroll 타이머를 on/off
        // (타이머가 마지막 mouse_move 를 재전송 → 이 함수 재진입). raw_row 는
        // @divFloor 로 음수(위 경계) 판정.
        const ch: i32 = @intCast(self.window.cell_height_px);
        // #483 5단계 — 활성 pane 의 격자 원점 · 격자.
        const term_y: i32 = @intCast(mouse_y - self.activeGridOrigin().y);
        const grid = self.activeGrid();
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
        tab.interaction.selection.update(screen, cell, mousePx(mouse_x, mouse_y));
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
            .split => .split,
            .focus_pane => .focus_pane,
            .resize_pane => .resize_pane,
            .equalize_panes => .equalize_panes,
            .zoom_pane => .zoom_pane,
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
            .mouse_right_down => |mouse| {
                // #329 — 열린 menu 는 모든 pointer button 보다 우선. 우클릭은
                // 메뉴만 닫고 paste 하지 않는다 (SPEC §5.3). false 면 window 가
                // 기존 즉시 paste (#119).
                if (self.command_menu_open) {
                    self.closeCommandMenu();
                    return true;
                }
                // #483 5단계 — 비활성 pane 우클릭은 포커스만 옮기고 붙여넣지 않는다 (확정 설계 축 3). true 면
                // window 가 붙여넣기를 건너뛴다.
                if (self.focusPaneUnderPointer(mouse.x, mouse.y)) return true;
                return false;
            },
            .focus_lost => {
                // #390 — 다른 앱으로 focus 가 넘어가면 열린 menu 를 닫는다
                // (native menu 동등). 창 밖 클릭 자체는 우리에게 오지 않으므로
                // focus 상실이 유일한 훅이다 (SPEC §5.3).
                if (!self.command_menu_open) return false;
                self.closeCommandMenu();
                return true;
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
                        perf.dumpAndReset(self.rt, "snapshot");
                        return true;
                    },
                    .show_about => {
                        about.showAboutDialog(self.rt);
                        return true;
                    },
                    .open_config => {
                        const path = paths.configPath(self.rt, self.allocator) catch return true;
                        defer self.allocator.free(path);
                        // 우리 창은 WS_EX_TOPMOST 라 새로 launch 되는 editor 가
                        // 그 뒤로 가려져 사용자에겐 안 보임. topmost flag 만 잠시
                        // 내려 → editor 가 자연스럽게 우리 위. 다음 F1 toggle 시
                        // show() 의 applyRect 가 HWND_TOPMOST 복귀.
                        self.window.yieldTopmostUntilNextShow();
                        system_open.openInDefaultApp(self.rt, self.allocator, path);
                        return true;
                    },
                    .open_log => {
                        const path = log.filePath() orelse return true;
                        self.window.yieldTopmostUntilNextShow();
                        system_open.openInDefaultApp(self.rt, self.allocator, path);
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
                    // #483 5단계 — 분할 · 포커스 · 크기 · 균등 · 최대화 (Linux 4b · 4c · macOS 와 같은 배선).
                    .split => |dir| {
                        self.handleSplit(dir);
                        return true;
                    },
                    .focus_pane => |dir| {
                        self.handleFocusPane(dir);
                        return true;
                    },
                    .resize_pane => |dir| {
                        self.handleResizePane(dir);
                        return true;
                    },
                    .equalize_panes => {
                        self.handleEqualizePanes();
                        return true;
                    },
                    .zoom_pane => {
                        self.handleZoomPane();
                        return true;
                    },
                }
            },
            .mouse_down => |mouse| {
                // #502 — 가운데 / 오른쪽 버튼은 chrome 에 역할이 없다. reporting 이
                // 켜져 있으면 앱으로 보내고 아니면 무시한다 — chrome 체인을 타게
                // 두면 가운데 클릭이 탭 전환 / 탭 닫기로 오인된다.
                if (mouse.button != .left) {
                    _ = self.routeMouseToApp(self.reportEvent(
                        .press,
                        reportButton(mouse.button),
                        mouse.mods,
                        mouse.x,
                        mouse.y,
                        true,
                    ));
                    return true;
                }
                if (self.command_menu_open) {
                    // #334 — 스크롤 표시 행 클릭 = 한 entry 스크롤, 메뉴 유지.
                    const menu_view = self.commandMenuView();
                    const px_pt = @as(f32, @floatFromInt(mouse.x)) / self.dpi_scale;
                    const py_pt = @as(f32, @floatFromInt(mouse.y)) / self.dpi_scale;
                    if (command_menu.hitScrollIndicator(menu_view, px_pt, py_pt)) |dir| {
                        self.command_menu_first = command_menu.scrollStep(menu_view, dir == .down);
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
                // #483 5단계 — 분할선 (±slop) 누름 = 드래그 시작 (pane 판정보다 먼저 — Linux · macOS 와 같은 순서).
                if (self.separatorAt(mouse.x, mouse.y)) |s| {
                    if (self.activeTabPtr()) |tab| tab.interaction.cancelPointerModes();
                    self.tab_drag.reset();
                    self.sep_drag = .{ .node = s.node, .axis = s.axis, .px = if (s.axis == .side_by_side) mouse.x else mouse.y };
                    return true;
                }
                // 다른 pane 을 눌렀으면 먼저 그 pane 으로 포커스 하고, 그 pane 기준으로 아래 scrollbar · 셀 판정을
                // 이어 간다 (포커스 이동과 선택 시작이 한 클릭).
                _ = self.focusPaneUnderPointer(mouse.x, mouse.y);
                if (self.inActiveScrollbarColumn(mouse.x, mouse.y)) {
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
                // #502 — 앱이 mouse tracking 을 켰으면 셀 영역 클릭은 앱 것이다.
                // Shift 를 누르면 우리 selection 으로 돌아온다 (bypass).
                if (!self.routeMouseToApp(self.reportEvent(
                    .press,
                    .left,
                    mouse.mods,
                    mouse.x,
                    mouse.y,
                    true,
                ))) return true;
                self.startTerminalSelection(mouse.x, mouse.y);
                return true;
            },
            .mouse_double_click => |mouse| {
                if (self.singleControlHit(mouse.x, mouse.y) != .none) return true;
                // 탭바 더블클릭은 소비만 (rename 은 #341 로 제거).
                if (mouse.y >= self.effectiveTabBarHeight()) {
                    // #502 — reporting 중이면 두 번째 클릭도 press 로 보낸다. 더블
                    // 클릭의 *의미* 는 앱이 정하므로 (앱마다 다르다) 우리가 word
                    // selection 으로 가로채지 않는다.
                    if (!self.routeMouseToApp(self.reportEvent(
                        .press,
                        .left,
                        mouse.mods,
                        mouse.x,
                        mouse.y,
                        true,
                    ))) return true;
                    self.selectWordAt(mouse.x, mouse.y);
                }
                return true;
            },
            .mouse_move => |mouse| {
                // #483 5단계 — 분할선 드래그 중: 좌표만 기억 (고스트는 프레임이 그린다). 트리는 놓을 때.
                if (self.sep_drag) |*d| {
                    if (mouse.left_button) {
                        d.px = if (d.axis == .side_by_side) mouse.x else mouse.y;
                        return true;
                    }
                }
                if (mouse.left_button) {
                    const tab_opt = self.activeTabPtr();
                    if (tab_opt != null and tab_opt.?.interaction.scrollbar.active) {
                        self.scrollToY(mouse.y);
                    } else if (self.tab_drag.active) {
                        self.handleDragMove(mouse.x);
                    } else if (tab_opt != null and tab_opt.?.interaction.selection.active) {
                        self.updateTerminalSelection(mouse.x, mouse.y);
                    } else {
                        // #502 — 우리 pointer mode 가 아무것도 아닌 왼쪽 드래그는
                        // 앱의 드래그다 (press 를 앱이 가져갔다는 뜻).
                        _ = self.routeMouseToApp(self.reportEvent(
                            .motion,
                            .left,
                            mouse.mods,
                            mouse.x,
                            mouse.y,
                            true,
                        ));
                    }
                } else if (mouse.heldButton()) |held| blk: {
                    // 가운데 드래그는 앱 몫. **오른쪽은 제외** — 우클릭은 paste 로
                    // 남기므로 press · release 를 안 보내는데 motion 만 보내면 앱의
                    // 드래그 상태가 갇힌다 (`mouse_report.motionReportable`).
                    const b = reportButton(held);
                    if (!mouse_report.motionReportable(b)) break :blk;
                    _ = self.routeMouseToApp(self.reportEvent(
                        .motion,
                        b,
                        mouse.mods,
                        mouse.x,
                        mouse.y,
                        true,
                    ));
                } else {
                    // 버튼 없는 hover — `?1003` (any) 만 보낸다. 그 판정과 같은
                    // cell 중복 제거는 인코더가 한다. 탭바 위 hover 는 viewport
                    // 밖이라 저절로 걸러진다.
                    _ = self.routeMouseToApp(self.reportEvent(
                        .motion,
                        null,
                        mouse.mods,
                        mouse.x,
                        mouse.y,
                        false,
                    ));
                }
                self.updateTabHover(mouse.x, mouse.y);
                return true;
            },
            .mouse_up => |mouse| {
                // #502 — 가운데 / 오른쪽 뗌은 chrome 에 역할이 없다. 앱이 press 를
                // 받았으면 뗌도 받아야 버튼이 눌린 채로 남지 않는다.
                if (mouse.button != .left) {
                    _ = self.routeMouseToApp(self.reportEvent(
                        .release,
                        reportButton(mouse.button),
                        mouse.mods,
                        mouse.x,
                        mouse.y,
                        false,
                    ));
                    return true;
                }
                // #245 — 어떤 release 든 drag-select auto-scroll 타이머 정지.
                self.window.setAutoScroll(false);
                // #483 5단계 — 분할선 드래그 끝: 여기서 한 번만 트리에 적용.
                if (self.sep_drag) |d| {
                    self.sep_drag = null;
                    self.finishSeparatorDrag(d);
                    return true;
                }
                if (self.activeTabPtr()) |tab| {
                    if (tab.interaction.scrollbar.active) {
                        tab.interaction.scrollbar.end();
                        return true;
                    }
                }
                if (self.tab_drag.active) {
                    self.handleDragEnd();
                } else {
                    // #502 — 뗌은 앱에게 먼저. viewport 밖에서 놓아도 항상 보내야
                    // 앱이 버튼 상태를 잃지 않는다 (인코더가 그 규칙을 갖는다).
                    if (!self.routeMouseToApp(self.reportEvent(
                        .release,
                        .left,
                        mouse.mods,
                        mouse.x,
                        mouse.y,
                        false,
                    ))) return true;
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
                            self.command_menu_wheel_accum += wheel.delta;
                            var steps = @divTrunc(self.command_menu_wheel_accum, 120);
                            self.command_menu_wheel_accum -= steps * 120;
                            while (steps != 0) {
                                const down = steps < 0; // 양수 = 위로 (WHEEL_DELTA)
                                const next = command_menu.scrollStep(self.commandMenuView(), down);
                                if (next == self.command_menu_first) break;
                                self.command_menu_first = next;
                                steps += if (down) @as(i32, 1) else -1;
                            }
                        },
                        .page => {},
                    }
                    return true;
                }
                // #502 — 앱이 tracking 을 켰으면 휠은 앱 것 (`Cb` 64/65). 안 켰지만
                // alt screen + `?1007` 이면 화살표 키로 바꿔 보낸다.
                switch (scroll_event) {
                    .wheel => |wheel| if (self.routeWheel(wheel)) return true,
                    .page => {},
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
