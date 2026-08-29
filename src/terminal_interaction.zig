const std = @import("std");
const ghostty = @import("ghostty-vt");
const mouse_report = @import("mouse_report.zig");

pub const Cell = struct {
    col: u16,
    row: u16,
};

/// #245 — drag-select auto-scroll 경계 판정. 보이는 grid 의 row 범위(0..rows)
/// 기준, unclamped row 가 위(<0)면 -1(older/위로 스크롤), 아래(>=rows)면 +1(newer),
/// 안이면 0. 각 host(Win app_controller / mac / Linux)가 공유한다.
pub fn edgeScrollDir(row: i32, rows: u16) i8 {
    if (row < 0) return -1;
    if (row >= @as(i32, @intCast(rows))) return 1;
    return 0;
}

/// #245 — 선택 갱신용 cell 을 보이는 grid 범위로 clamp. 경계 밖으로 드래그해도
/// (가장자리 행/열) 선택이 freeze 되지 않고 가장자리까지 연장 — auto-scroll 과
/// 함께 scrollback 까지 선택을 늘린다 (이전엔 viewport clamp 로 막혔음).
pub fn clampCell(col: i32, row: i32, cols: u16, rows: u16) Cell {
    const cmax: i32 = if (cols == 0) 0 else @as(i32, @intCast(cols)) - 1;
    const rmax: i32 = if (rows == 0) 0 else @as(i32, @intCast(rows)) - 1;
    return .{
        .col = @intCast(std.math.clamp(col, 0, cmax)),
        .row = @intCast(std.math.clamp(row, 0, rmax)),
    };
}

/// #483 6단계 — 포인터 위치 (물리 px). 선택 시작 문턱 판정에만 쓴다.
pub const Px = struct { x: f32, y: f32 };

pub const SelectionState = struct {
    active: bool = false,
    start_pin: ?ghostty.PageList.Pin = null,
    /// #483 6단계 — 누른 셀 · 누른 자리 · 문턱. 셋 다 `arm` 이 쓴다.
    start_cell: Cell = .{ .col = 0, .row = 0 },
    start_px: Px = .{ .x = 0, .y = 0 },
    /// 물리 px 문턱 — host 가 `ui_metrics.selectionDragSlopPx(cell_w_px, scale)` 로 만들어 준다.
    slop_px: f32 = 0,
    /// 문턱을 한 번이라도 넘었는가. 켜지면 계속 켜져 있다.
    armed: bool = false,

    pub fn begin(self: *SelectionState, screen: *ghostty.Screen, cell: Cell, px: Px, slop_px: f32) void {
        self.active = true;
        self.armed = false;
        self.start_cell = cell;
        self.start_px = px;
        self.slop_px = slop_px;
        screen.clearSelection();
        self.start_pin = screen.pages.pin(.{ .viewport = .{ .x = cell.col, .y = cell.row } });
    }

    /// #483 6단계 — 이 자리로 선택을 늘려도 되는가 (2026-08-28 macOS 실기).
    ///
    /// **트랙패드 클릭의 1~3 px 떨림에도 `update` 가 불려** 한 칸 선택이 만들어졌고, 놓을 때 자동 복사까지
    /// 돼서 pane 마다 흰 자국이 남고 클립보드가 한 글자로 덮였다 (사용자가 pane 셋을 클릭해 포커스만
    /// 옮겼는데 세 칸에 자국). 그래서 둘 중 하나가 되기 전에는 선택을 만들지 않는다:
    ///
    /// - 누른 자리에서 **문턱 (`slop_px`) 보다 많이** 움직였다 — 같은 칸 안이어도 된다. 그래야 글자 하나를
    ///   그 자리에서 끌어 선택할 수 있다 (문턱은 `ui_metrics.selectionDragSlopPx` 가 반 칸을 넘지 않게 잡는다).
    /// - **다른 칸으로 넘어갔다** — 문턱보다 작게 움직였어도 칸이 바뀌었으면 선택이다.
    ///
    /// 한 번 켜지면 유지되므로 (`armed`) 이웃 칸으로 갔다 돌아오는 한 칸 선택도 그대로 된다.
    fn arm(self: *SelectionState, cell: Cell, px: Px) bool {
        if (self.armed) return true;
        const moved = @abs(px.x - self.start_px.x) > self.slop_px or
            @abs(px.y - self.start_px.y) > self.slop_px;
        const same_cell = cell.col == self.start_cell.col and cell.row == self.start_cell.row;
        if (!moved and same_cell) return false;
        self.armed = true;
        return true;
    }

    pub fn update(self: *SelectionState, screen: *ghostty.Screen, cell: Cell, px: Px) void {
        if (!self.active) return;
        if (!self.arm(cell, px)) return;
        const start = self.start_pin orelse return;
        const end = screen.pages.pin(.{ .viewport = .{ .x = cell.col, .y = cell.row } }) orelse return;
        const selection = ghostty.Selection.init(start, end, false);
        screen.select(selection) catch {};
    }

    pub fn finish(self: *SelectionState) bool {
        if (!self.active) return false;
        self.active = false;
        self.start_pin = null;
        self.armed = false;
        return true;
    }

    pub fn cancel(self: *SelectionState) void {
        self.active = false;
        self.start_pin = null;
        self.armed = false;
    }
};

pub const ScrollbarDragState = struct {
    active: bool = false,
    /// #259 — mouse-down 시 잡은 thumb 지점의 offset (track_top 기준 thumb 윗변과
    /// 커서의 거리). 드래그 중 `thumb_top = mouse_rel_y - grab_offset` 로 환산해
    /// 잡은 지점이 커서 아래 고정된 채 따라오게 한다. `scrollbar.grabOffset` 산출.
    grab_offset: f64 = 0,

    pub fn begin(self: *ScrollbarDragState, grab: f64) void {
        self.active = true;
        self.grab_offset = grab;
    }

    pub fn end(self: *ScrollbarDragState) void {
        self.active = false;
    }
};

pub const TerminalInteraction = struct {
    selection: SelectionState = .{},
    scrollbar: ScrollbarDragState = .{},
    /// #502 — mouse reporting 의 motion 중복 제거 상태. 같은 cell 안에서 픽셀만
    /// 움직인 motion 을 앱에 다시 보내지 않는다. 탭별 상태라 여기에 둔다.
    report_last_cell: ?mouse_report.Cell = null,

    pub fn cancelPointerModes(self: *TerminalInteraction) void {
        self.selection.cancel();
        self.scrollbar.end();
        // 다음 드래그가 첫 motion 부터 보고되도록 초기화 — 남겨 두면 새 드래그의
        // 첫 cell 이 이전 드래그의 마지막 cell 과 같을 때 통째로 삼켜진다.
        self.report_last_cell = null;
    }
};

/// #502 — mouse reporting 의 *ghostty 연결* 과 *좌표 계산*. 세 host (Windows
/// `app_controller` · macOS `host/macos.zig` · Linux `wayland_minimal.zig`) 가 각자
/// 라우팅을 갖고 있어서, 판정에 들어가는 값은 이 함수들로 수렴시킨다. 인코딩 자체는
/// ghostty 비의존 순수 모듈 `mouse_report.zig` 가 한다.
///
/// ghostty 가 DECSET 을 해석해 `Terminal.flags` 에 넣어 둔 mode 를 인코더 enum 으로
/// 옮긴다. **exhaustive switch** 라 upstream 이 variant 를 추가하면 컴파일 에러로
/// 드러난다 (인코더를 ghostty 비의존으로 둔 대가).
pub fn reportTracking(t: *const ghostty.Terminal) mouse_report.Tracking {
    return switch (t.flags.mouse_event) {
        .none => .none,
        .x10 => .x10,
        .normal => .normal,
        .button => .button,
        .any => .any,
    };
}

pub fn reportFormat(t: *const ghostty.Terminal) mouse_report.Format {
    return switch (t.flags.mouse_format) {
        .x10 => .x10,
        .utf8 => .utf8,
        .sgr => .sgr,
        .urxvt => .urxvt,
        .sgr_pixels => .sgr_pixels,
    };
}

/// XTSHIFTESCAPE (`CSI > Ps s`). ghostty 의 3-상태를 우리 정책 enum 으로. `.true` =
/// 터미널이 Shift 를 가져가도 좋다는 앱의 허용, `.false` = 앱이 Shift 조합을 자기가
/// 받겠다는 요청.
pub fn reportShiftCapture(t: *const ghostty.Terminal) mouse_report.ShiftCapture {
    return switch (t.flags.mouse_shift_capture) {
        .null => .unset,
        .true => .terminal,
        .false => .app,
    };
}

/// 셀 영역 좌표 계산에 필요한 host 기하. 단위는 **물리 픽셀** — 각 host 가 자기
/// 단위 (Windows `c_int` / macOS `f32` / Linux `i32`) 를 i32 px 로 변환해 넘긴다
/// (`scrollbar.zig` 와 같은 계약).
pub const ReportGeometry = struct {
    cell_w: i32,
    cell_h: i32,
    cols: u16,
    rows: u16,
    /// 첫 셀의 좌상 px. #483 — pane 이 창의 왼쪽 위에 있지 않을 수 있어 `pad` · `tab_bar_h` 가
    /// 아니라 격자 원점을 받는다 (pane 하나면 `pad` · `tab_bar_h + pad` 와 같은 값).
    grid_x: i32,
    grid_y: i32,
};

/// pointer 픽셀 좌표를 인코더 입력으로. cell 은 grid 안으로 clamp 하지만
/// **`in_viewport` 판정은 clamp 전 원좌표로** 한다 — clamp 된 값만 보면 창 밖
/// 드래그가 언제나 가장자리 cell "안" 으로 보여서, 뗌만 보내야 하는 규칙이 깨진다.
pub fn reportEvent(
    action: mouse_report.Action,
    button: ?mouse_report.Button,
    mods: mouse_report.Mods,
    x: i32,
    y: i32,
    geom: ReportGeometry,
    any_button_pressed: bool,
) mouse_report.Event {
    const term_x = x - geom.grid_x;
    const term_y = y - geom.grid_y;
    const cols: i32 = @intCast(geom.cols);
    const rows: i32 = @intCast(geom.rows);
    const col: u32 = if (geom.cell_w > 0 and term_x >= 0)
        @intCast(@min(@divTrunc(term_x, geom.cell_w), cols - 1))
    else
        0;
    const row: u32 = if (geom.cell_h > 0 and term_y >= 0)
        @intCast(@min(@divTrunc(term_y, geom.cell_h), rows - 1))
    else
        0;
    return .{
        .action = action,
        .button = button,
        .mods = mods,
        .cell = .{ .col = col, .row = row },
        .pixel = .{ .x = term_x, .y = term_y },
        .in_viewport = term_x >= 0 and term_y >= 0 and
            term_x < geom.cell_w * cols and term_y < geom.cell_h * rows,
        .any_button_pressed = any_button_pressed,
    };
}

/// 이벤트를 앱에 보낼지 우리가 처리할지 결정한다. host 는 `.report` 면 그 바이트를
/// PTY 로 쓰고, `.local` 이면 기존 동작을 계속하고, `.swallow` 면 아무것도 하지
/// 않는다 (앱이 마우스를 소유하는데 이 이벤트만 안 보내는 경우 — 우리 selection 을
/// 시작하면 앱 화면 위에 겹쳐 그려진다).
///
/// PTY 전송에 `queueInputToActive` 를 쓰지 않는다 — 그 경로는 write 뒤
/// `scrollViewport(.bottom)` 을 강제해서 매 motion 마다 viewport 가 끝으로 당겨진다
/// (primary screen 에서 scrollback 을 올려 둔 채 드래그하면 화면이 튄다). 마우스
/// 보고는 사용자 입력이 아니라 좌표 통보라 viewport 를 건드리지 않는 게 맞다.
pub fn routeMouse(
    buf: []u8,
    t: *const ghostty.Terminal,
    state: *TerminalInteraction,
    ev: mouse_report.Event,
) mouse_report.Decision {
    return mouse_report.route(
        buf,
        ev,
        reportTracking(t),
        reportFormat(t),
        reportShiftCapture(t),
        &state.report_last_cell,
    );
}

/// 더블클릭 word selection — ghostty 의 `selectWord` 가 wide char (한/中/日 등)
/// 의 spacer_tail cell (글자의 right-half) 을 boundary 로 취급해 (i) 음절 사이
/// 클릭 시 null, (ii) 글자 위 클릭 시 그 음절 한 개만 선택. 우리가 직접 구현해
/// spacer_tail 은 같은 word 의 continuation 으로 처리.
///
/// 알고리즘 — ghostty `selectWord` 와 동일 구조 (`Screen.zig:2784`) 지만
/// spacer_tail 은 `expect_boundary` 검사 *없이* 통과하고 다음 cell 로 진행.
pub fn selectWord(screen: *ghostty.Screen, cell: Cell) bool {
    var start_pin = screen.pages.pin(.{ .viewport = .{ .x = cell.col, .y = cell.row } }) orelse return false;

    // spacer_tail cell 위 클릭이면 wide char main cell (왼쪽 한 칸) 으로 정규화.
    {
        const rac = start_pin.rowAndCell();
        if (rac.cell.wide == .spacer_tail and start_pin.x > 0) {
            start_pin.x -= 1;
        }
    }

    const start_rac = start_pin.rowAndCell();
    if (!start_rac.cell.hasText()) return false;

    const start_cp = start_rac.cell.content.codepoint.data;
    // 시작 cell 이 boundary 문자 (공백 / 따옴표 / 구두점 등) 면 더블클릭 word
    // selection 의도가 아니라고 보고 무시. ghostty default 는 boundary 끼리도
    // 묶지만, 터미널 사용자가 expect 하는 동작은 "단어 본체만 선택" — iTerm2 /
    // Terminal.app 동등. 시작이 word body 인 경우만 양쪽 확장.
    if (std.mem.findAny(u21, &word_boundaries, &.{start_cp}) != null) return false;
    const expect_boundary = false;

    // forward — 양쪽으로 같은 boundary 상태인 cell 까지 확장.
    const end: ghostty.Pin = blk: {
        var it = start_pin.cellIterator(.right_down, null);
        var prev = it.next().?;
        while (it.next()) |p| {
            const rac = p.rowAndCell();
            // spacer_tail 은 wide char 의 right-half — codepoint=0 이지만 같은
            // 글자라 word continuation 으로 처리. boundary 검사 skip + prev 만 update.
            if (rac.cell.wide == .spacer_tail) {
                prev = p;
                continue;
            }
            if (!rac.cell.hasText()) break :blk prev;
            const this_b = std.mem.findAny(u21, &word_boundaries, &.{rac.cell.content.codepoint.data}) != null;
            if (this_b != expect_boundary) break :blk prev;
            // #451 — `Node.data` 가 `union { resident, compressed }` 로 바뀌었다 (offscreen
            // scrollback LZ4 압축). 열 수는 메타데이터라 압축을 풀지 않는 `Node.cols()` 가
            // 그 자리다 (`PageList.zig` 의 *"metadata functions"*).
            if (p.x == p.node.cols() - 1 and !rac.row.wrap) break :blk p;
            prev = p;
        }
        break :blk prev;
    };

    // backward — 같은 logic 의 거울.
    const start: ghostty.Pin = blk: {
        var it = start_pin.cellIterator(.left_up, null);
        var prev = it.next().?;
        while (it.next()) |p| {
            const rac = p.rowAndCell();
            if (rac.cell.wide == .spacer_tail) {
                prev = p;
                continue;
            }
            if (p.x == p.node.cols() - 1 and !rac.row.wrap) break :blk prev;
            if (!rac.cell.hasText()) break :blk prev;
            const this_b = std.mem.findAny(u21, &word_boundaries, &.{rac.cell.content.codepoint.data}) != null;
            if (this_b != expect_boundary) break :blk prev;
            prev = p;
        }
        break :blk prev;
    };

    const selection = ghostty.Selection.init(start, end, false);
    screen.select(selection) catch return false;
    return true;
}

const word_boundaries = [_]u21{ ' ', '\t', '"', '`', '|', ':', ';', '(', ')', '[', ']', '{', '}', '<', '>' };

test "#483 6단계 — 클릭 떨림은 선택을 만들지 않는다 (문턱 · 칸 넘기 중 하나)" {
    const at = struct {
        fn s(col: u16, row: u16, x: f32, y: f32) SelectionState {
            return .{
                .active = true,
                .start_cell = .{ .col = col, .row = row },
                .start_px = .{ .x = x, .y = y },
                .slop_px = 8, // 4 pt @2x — 셀 폭 19 px 의 절반보다 작다.
            };
        }
    }.s;

    // ① 같은 칸 안 · 문턱 이하 (트랙패드 떨림 3 px) — 선택 아님.
    var jitter = at(5, 3, 100, 200);
    try std.testing.expect(!jitter.arm(.{ .col = 5, .row = 3 }, .{ .x = 103, .y = 201 }));
    try std.testing.expect(!jitter.armed);

    // ② 같은 칸 안이어도 문턱을 넘으면 시작 — 글자 하나를 그 자리에서 끌어 선택할 수 있다.
    var in_cell = at(5, 3, 100, 200);
    try std.testing.expect(in_cell.arm(.{ .col = 5, .row = 3 }, .{ .x = 109, .y = 200 }));
    try std.testing.expect(in_cell.armed);

    // ③ 문턱보다 작게 움직였어도 칸이 바뀌면 시작 (셀 경계 바로 옆을 눌렀을 때).
    var crossed = at(5, 3, 100, 200);
    try std.testing.expect(crossed.arm(.{ .col = 6, .row = 3 }, .{ .x = 102, .y = 200 }));

    // ④ 세로 이동도 같다.
    var vertical = at(5, 3, 100, 200);
    try std.testing.expect(vertical.arm(.{ .col = 5, .row = 3 }, .{ .x = 100, .y = 212 }));

    // ⑤ 한 번 켜지면 돌아와도 유지 — 이웃 칸으로 갔다 온 한 칸 선택.
    try std.testing.expect(crossed.arm(.{ .col = 5, .row = 3 }, .{ .x = 100, .y = 200 }));

    // ⑥ finish · cancel 은 문턱을 다시 채운다 (다음 클릭이 또 걸러지게).
    _ = crossed.finish();
    try std.testing.expect(!crossed.armed);
    in_cell.cancel();
    try std.testing.expect(!in_cell.armed);
}

test "selection finish and cancel clear active state" {
    var selection = SelectionState{ .active = true };
    try std.testing.expect(selection.finish());
    try std.testing.expect(!selection.active);
    try std.testing.expect(!selection.finish());

    selection.active = true;
    selection.cancel();
    try std.testing.expect(!selection.active);
}

test "scrollbar drag state toggles explicitly" {
    var scrollbar = ScrollbarDragState{};
    scrollbar.begin(12.5);
    try std.testing.expect(scrollbar.active);
    try std.testing.expectEqual(@as(f64, 12.5), scrollbar.grab_offset);
    scrollbar.end();
    try std.testing.expect(!scrollbar.active);
}

// #259 — scrollbar.zig 순수 모듈의 테스트가 어느 플랫폼 빌드에서든 실행되도록
// (host 별 hit-test 가 platform-gated 라) 항상 reachable 한 여기서 참조한다.
test {
    std.testing.refAllDecls(@import("scrollbar.zig"));
}
