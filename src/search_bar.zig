//! #646 3 단계 — 검색바의 cross-platform 모델. 좌표는 **logical pt** 이고 host renderer 가
//! scale 을 곱해 physical px 로 바꾼다 ([`command_menu.zig`](command_menu.zig) 와 같은 결).
//!
//! **탭바와 한 문법이다** — 배경은 `TAB_BAR_BG`, 경계선은 `TAB_SEPARATOR_COLOR`, 높이도
//! 탭바와 같은 `TAB_BAR_HEIGHT_PT`, 컨트롤 폭도 탭바의 `24pt` 다. command menu 가 이미 같은
//! 규칙을 쓴다 (`ui_metrics.zig` 의 "탭바와 한 문법, 2026-07-22 사용자 확정").
//!
//! **창 하단 전역 바 하나다** (2026-09-11 결정). pane 안에 두지 않는 이유는 pane 이
//! `MIN_PANE_COLS = 20` 밑으로도 내려갈 수 있어서 입력칸 + 카운터가 안 들어가기 때문이다.
//! 대상 pane 은 기존 amber focus line 으로 이미 구별된다. 검색 *상태* 는 pane 별로 보존되고
//! 이 바는 **활성 pane 의 상태를 비추는 창** 이다.

const std = @import("std");
const ui_metrics = @import("ui_metrics.zig");

/// 바 높이 — 탭바와 같다. 위아래로 짝을 이뤄 앱이 한 덩어리로 읽힌다.
pub const HEIGHT_PT: f32 = @floatFromInt(ui_metrics.TAB_BAR_HEIGHT_PT);

/// 위쪽 경계선 두께. 탭 사이 구분선(`TAB_SEPARATOR_W_PT`)과 같다.
pub const BORDER_PT: f32 = @floatFromInt(ui_metrics.TAB_SEPARATOR_W_PT);

/// 키보드 포커스가 검색바에 있을 때 위쪽에 얹는 amber 선. 활성 탭 밑줄과 **같은 두께 · 같은
/// 색** 이다 — "지금 입력이 터미널이 아니라 여기로 간다" 를 앱이 이미 쓰는 신호로 말한다.
/// 검색바 포커스 중에도 pane 이동 단축키가 동작하므로 (2026-09-11 결정) 이 구분이 필요하다.
pub const FOCUS_LINE_PT: f32 = @floatFromInt(ui_metrics.TAB_ACTIVE_UNDERLINE_PT);

/// 좌우 끝 여백.
pub const PADDING_PT: f32 = 8;
/// 요소 사이 간격.
pub const GAP_PT: f32 = 6;
/// 컨트롤(‹ › ×) 한 칸 폭 — 탭바 컨트롤과 같다.
pub const CONTROL_W_PT: f32 = @floatFromInt(ui_metrics.TAB_CLOSE_W_PT);
/// 돋보기 아이콘 한 변 — 탭 아이콘과 같다 (`tab_icons.rasterize(.search, …)`).
pub const ICON_PT: f32 = @floatFromInt(ui_metrics.TAB_ICON_SIZE_PT);
/// 돋보기가 차지하는 칸 (아이콘 + 좌우 숨).
pub const ICON_SLOT_PT: f32 = ICON_PT + GAP_PT;

/// 카운터(`3/17`) 자리 폭. **고정 폭이다** — 숫자가 늘어도 입력칸 경계가 흔들리지 않게.
/// 네 자리 + 네 자리 + 구분자가 들어가는 크기이고, 그보다 큰 수는 잘리는 대신 오른쪽
/// 정렬로 앞자리를 보여준다 (매치가 만 개면 정확한 수보다 "많다" 가 중요하다).
pub const COUNT_W_PT: f32 = 56;

/// 입력칸이 유지하는 최소 폭. **다른 무엇보다 먼저 확보한다** — 검색바에서 가장 중요한 것은
/// *무엇을 치고 있는지* 보이는 것이라, 좁다고 입력칸부터 줄이면 바가 쓸모없어진다.
pub const FIELD_MIN_PT: f32 = 40;

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

/// 바 안의 누를 수 있는 것.
pub const Control = enum { prev, next, close };

/// host → renderer 로 넘기는 검색바 상태. `command_menu.Ui` 와 같은 역할이다.
///
/// 문자열은 **빌려온 것** 이고 프레임 동안만 유효하다 (renderer 가 그리는 즉시 쓴다).
pub const Ui = struct {
    /// 바가 떠 있는가. `false` 면 renderer 는 아무것도 그리지 않고 터미널이 그만큼 넓어진다.
    open: bool = false,

    /// 확정된 검색어. 비어 있으면 안내문을 대신 그린다.
    needle: []const u8 = "",

    /// IME 조합 중 글자 — `needle` 의 caret 자리에 끼워 강조해서 그린다. 확정 전이라
    /// 검색에는 쓰지 않는다 (SPEC §5 의 preedit 규칙을 검색바 안에서 그대로 따른다).
    preedit: []const u8 = "",

    /// caret 의 byte offset (`needle` 기준). 편집 중 커서 위치다.
    caret: usize = 0,

    /// 지금 선택된 매치 번호 (1-based). `0` 이면 선택 없음.
    current: usize = 0,
    /// 찾은 매치 수.
    total: usize = 0,

    /// 아직 훑는 중인가. 카운터를 수 대신 `…` 로 그려 "0 개" 와 구별한다 — 짧은 needle 의
    /// 디바운스 대기와 큰 스크롤백의 증분 진행이 모두 여기에 해당한다.
    searching: bool = false,

    /// 키보드 포커스가 바에 있는가 (amber 선).
    focused: bool = false,

    /// pointer 가 올라간 컨트롤.
    hover: ?Control = null,
};

/// 계산된 배치. 모든 rect 는 logical pt 이고 viewport 좌상단 기준이다.
pub const View = struct {
    /// 경계선을 포함한 바 전체.
    rect: Rect,
    /// 위쪽 경계선 (또는 포커스 선) 이 차지하는 띠.
    border: Rect,
    /// 돋보기 아이콘.
    icon: Rect,
    /// 검색어 + preedit + caret 이 그려지는 영역. 남는 폭을 전부 갖는다.
    field: Rect,
    /// `3/17` 카운터.
    count: Rect,
    prev: Rect,
    next: Rect,
    close: Rect,
};

/// 폭에 따라 무엇까지 보이는가. **폭이 줄면 요소가 늘지 않는다** — 단계로 정의하지 않고
/// "자리가 남으면 넣는다" 로 하면, 아이콘이 작아서 *컨트롤이 못 들어가는 폭에도 살아남는*
/// 뒤집힌 조합이 나온다 (테스트가 실제로 잡았다).
pub const Stage = enum {
    /// 전부.
    full,
    /// 아이콘을 접는다 — 장식에 가장 가깝다.
    no_icon,
    /// 컨트롤(‹ › ×)까지 접는다. Enter · Shift+Enter · Esc 로 대체된다.
    minimal,
    /// 카운터까지 접고 입력칸만 남긴다. 검색바에서 마지막까지 남아야 하는 것은
    /// *무엇을 치고 있는지* 다.
    bare,
};

/// 각 단계에 필요한 최소 창 폭 (logical pt).
pub const NEED_FULL_PT: f32 = PADDING_PT * 2 + ICON_SLOT_PT + FIELD_MIN_PT + GAP_PT + COUNT_W_PT + CONTROL_W_PT * 3;
pub const NEED_NO_ICON_PT: f32 = PADDING_PT * 2 + FIELD_MIN_PT + GAP_PT + COUNT_W_PT + CONTROL_W_PT * 3;
pub const NEED_MINIMAL_PT: f32 = PADDING_PT * 2 + FIELD_MIN_PT + GAP_PT + COUNT_W_PT;

pub fn stageFor(viewport_w_pt: f32) Stage {
    if (viewport_w_pt >= NEED_FULL_PT) return .full;
    if (viewport_w_pt >= NEED_NO_ICON_PT) return .no_icon;
    if (viewport_w_pt >= NEED_MINIMAL_PT) return .minimal;
    return .bare;
}

/// 창 하단에 붙는 바를 계산한다. `viewport_w_pt` · `viewport_h_pt` 는 창 전체 크기다.
///
/// 좁아질 때 접히는 순서는 **아이콘 → 컨트롤 → 카운터** 이고 입력칸은 마지막까지 남는다
/// (`Stage`). 순서의 근거는 *키보드로 대체 가능한가* 다 — 카운터는 화면에만 있는 정보라
/// 가장 오래 남기고, 컨트롤은 Enter · Shift+Enter · Esc 로 대체되며, 아이콘은 장식에 가깝다.
///
/// 남는 폭은 전부 입력칸이 갖는다.
pub fn view(viewport_w_pt: f32, viewport_h_pt: f32) View {
    const y = viewport_h_pt - HEIGHT_PT;
    const rect: Rect = .{ .x = 0, .y = y, .w = viewport_w_pt, .h = HEIGHT_PT };
    const border: Rect = .{ .x = 0, .y = y, .w = viewport_w_pt, .h = BORDER_PT };

    // 경계선 아래가 내용 영역이다.
    const inner_y = y + BORDER_PT;
    const inner_h = HEIGHT_PT - BORDER_PT;

    const stage = stageFor(viewport_w_pt);
    const icon_slot: f32 = if (stage == .full) ICON_SLOT_PT else 0;
    const count_w: f32 = switch (stage) {
        .full, .no_icon, .minimal => COUNT_W_PT,
        .bare => 0,
    };
    const controls_w: f32 = switch (stage) {
        .full, .no_icon => CONTROL_W_PT * 3,
        .minimal, .bare => 0,
    };

    const total = @max(0, viewport_w_pt - PADDING_PT * 2);
    const used = icon_slot + count_w + (if (count_w > 0) GAP_PT else 0) + controls_w;
    const field_w = @max(0, total - used);

    var x = PADDING_PT;
    const icon: Rect = if (icon_slot > 0) .{
        .x = x,
        .y = inner_y + (inner_h - ICON_PT) * 0.5,
        .w = ICON_PT,
        .h = ICON_PT,
    } else emptyAt(x, inner_y);
    x += icon_slot;

    const field: Rect = .{ .x = x, .y = inner_y, .w = field_w, .h = inner_h };
    x += field_w;

    const count: Rect = if (count_w > 0) blk: {
        x += GAP_PT;
        const r: Rect = .{ .x = x, .y = inner_y, .w = count_w, .h = inner_h };
        x += count_w;
        break :blk r;
    } else emptyAt(x, inner_y);

    const prev: Rect = if (controls_w > 0) .{ .x = x, .y = inner_y, .w = CONTROL_W_PT, .h = inner_h } else emptyAt(x, inner_y);
    const next: Rect = if (controls_w > 0) .{ .x = x + CONTROL_W_PT, .y = inner_y, .w = CONTROL_W_PT, .h = inner_h } else emptyAt(x, inner_y);
    const close: Rect = if (controls_w > 0) .{ .x = x + CONTROL_W_PT * 2, .y = inner_y, .w = CONTROL_W_PT, .h = inner_h } else emptyAt(x, inner_y);

    return .{
        .rect = rect,
        .border = border,
        .icon = icon,
        .field = field,
        .count = count,
        .prev = prev,
        .next = next,
        .close = close,
    };
}

fn emptyAt(x: f32, y: f32) Rect {
    return .{ .x = x, .y = y, .w = 0, .h = 0 };
}

/// 바가 차지하는 높이. host 가 터미널 격자를 계산할 때 뺀다 — 바가 떠 있으면 터미널이
/// 그만큼 줄어든다 (겹쳐서 마지막 줄을 가리지 않는다).
pub fn reservedHeightPt(open: bool) f32 {
    return if (open) HEIGHT_PT else 0;
}

/// 컨트롤 히트 테스트. 바 밖이거나 빈 자리면 `null`.
pub fn hit(v: View, x: f32, y: f32) ?Control {
    if (!inside(v.rect, x, y)) return null;
    if (inside(v.prev, x, y)) return .prev;
    if (inside(v.next, x, y)) return .next;
    if (inside(v.close, x, y)) return .close;
    return null;
}

/// 좌표가 바 위에 있는가. host 가 "이 클릭은 터미널이 아니라 검색바 것" 을 가를 때 쓴다.
pub fn contains(v: View, x: f32, y: f32) bool {
    return inside(v.rect, x, y);
}

fn inside(r: Rect, x: f32, y: f32) bool {
    return r.w > 0 and r.h > 0 and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

/// 카운터 문구를 만든다. `buf` 는 최소 24 바이트.
///
/// - 훑는 중 → `…` (아직 모르는 것과 "없다" 를 구별한다)
/// - 매치 없음 → `0/0`
/// - 선택 전 → `17` (총 개수만)
/// - 선택 후 → `3/17`
pub fn countText(ui: Ui, buf: []u8) []const u8 {
    if (ui.searching) return "…";
    if (ui.total == 0) return "0/0";
    if (ui.current == 0) return std.fmt.bufPrint(buf, "{d}", .{ui.total}) catch "…";
    return std.fmt.bufPrint(buf, "{d}/{d}", .{ ui.current, ui.total }) catch "…";
}

test "#646 view — 바는 창 아래에 붙고 높이는 탭바와 같다" {
    const v = view(800, 600);
    try std.testing.expectEqual(@as(f32, 0), v.rect.x);
    try std.testing.expectEqual(@as(f32, 800), v.rect.w);
    try std.testing.expectEqual(HEIGHT_PT, v.rect.h);
    try std.testing.expectEqual(@as(f32, 600) - HEIGHT_PT, v.rect.y);
    // 경계선은 맨 위 띠다.
    try std.testing.expectEqual(v.rect.y, v.border.y);
    try std.testing.expectEqual(BORDER_PT, v.border.h);
}

test "#646 view — 요소가 겹치지 않고 왼쪽에서 오른쪽 순서다" {
    const v = view(800, 600);
    try std.testing.expect(v.icon.x < v.field.x);
    try std.testing.expect(v.field.x + v.field.w <= v.count.x);
    try std.testing.expect(v.count.x + v.count.w <= v.prev.x);
    try std.testing.expect(v.prev.x + v.prev.w <= v.next.x);
    try std.testing.expect(v.next.x + v.next.w <= v.close.x);
    // 마지막 컨트롤이 오른쪽 여백 안에 들어간다.
    try std.testing.expect(v.close.x + v.close.w <= 800 - PADDING_PT + 0.01);
}

test "#646 view — 접히는 순서는 아이콘 → 컨트롤 → 카운터, 입력칸이 마지막까지 남는다" {
    try std.testing.expectEqual(Stage.full, stageFor(NEED_FULL_PT));
    try std.testing.expectEqual(Stage.no_icon, stageFor(NEED_FULL_PT - 1));
    try std.testing.expectEqual(Stage.no_icon, stageFor(NEED_NO_ICON_PT));
    try std.testing.expectEqual(Stage.minimal, stageFor(NEED_NO_ICON_PT - 1));
    try std.testing.expectEqual(Stage.minimal, stageFor(NEED_MINIMAL_PT));
    try std.testing.expectEqual(Stage.bare, stageFor(NEED_MINIMAL_PT - 1));

    const full = view(800, 600);
    try std.testing.expect(full.icon.w > 0 and full.count.w > 0 and full.close.w > 0);

    const no_icon = view(NEED_NO_ICON_PT, 600);
    try std.testing.expectEqual(@as(f32, 0), no_icon.icon.w);
    try std.testing.expect(no_icon.count.w > 0 and no_icon.close.w > 0);

    const minimal = view(NEED_MINIMAL_PT, 600);
    try std.testing.expectEqual(@as(f32, 0), minimal.close.w);
    try std.testing.expect(minimal.count.w > 0);

    const bare = view(NEED_MINIMAL_PT - 1, 600);
    try std.testing.expectEqual(@as(f32, 0), bare.count.w);
    try std.testing.expect(bare.field.w > 0);
}

test "#646 view — 폭이 줄면 요소가 늘지 않는다 (단조)" {
    var w: f32 = 900;
    var prev_icon: f32 = std.math.floatMax(f32);
    var prev_count: f32 = std.math.floatMax(f32);
    var prev_ctrl: f32 = std.math.floatMax(f32);
    while (w >= 0) : (w -= 1) {
        const v = view(w, 600);
        try std.testing.expect(v.icon.w <= prev_icon);
        try std.testing.expect(v.count.w <= prev_count);
        try std.testing.expect(v.close.w <= prev_ctrl);
        try std.testing.expect(v.field.w >= 0);
        prev_icon = v.icon.w;
        prev_count = v.count.w;
        prev_ctrl = v.close.w;
    }
}

test "#646 hit — 컨트롤을 가르고 빈 자리는 null" {
    const v = view(800, 600);
    const cy = v.rect.y + HEIGHT_PT * 0.5;
    try std.testing.expectEqual(Control.prev, hit(v, v.prev.x + 1, cy).?);
    try std.testing.expectEqual(Control.next, hit(v, v.next.x + 1, cy).?);
    try std.testing.expectEqual(Control.close, hit(v, v.close.x + 1, cy).?);
    // 입력칸은 컨트롤이 아니다.
    try std.testing.expect(hit(v, v.field.x + 1, cy) == null);
    // 바 밖.
    try std.testing.expect(hit(v, 400, v.rect.y - 5) == null);
}

test "#646 contains — 바 위인지 가른다" {
    const v = view(800, 600);
    try std.testing.expect(contains(v, 400, v.rect.y + 1));
    try std.testing.expect(!contains(v, 400, v.rect.y - 1));
}

test "#646 countText — 상태마다 다른 문구" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("…", countText(.{ .searching = true }, &buf));
    try std.testing.expectEqualStrings("0/0", countText(.{ .total = 0 }, &buf));
    try std.testing.expectEqualStrings("17", countText(.{ .total = 17 }, &buf));
    try std.testing.expectEqualStrings("3/17", countText(.{ .current = 3, .total = 17 }, &buf));
}

test "#646 reservedHeightPt — 열려 있을 때만 자리를 차지한다" {
    try std.testing.expectEqual(@as(f32, 0), reservedHeightPt(false));
    try std.testing.expectEqual(HEIGHT_PT, reservedHeightPt(true));
}
