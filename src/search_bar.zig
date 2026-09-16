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
const ui_rect = @import("ui_rect.zig");
const display_width = @import("font/display_width.zig");
const chrome_palette = @import("chrome_palette.zig");
// `tab_icons` 는 아이콘 rasterizer (std 만 의존하는 순수 모듈) 라 chrome 모듈끼리의
// 상호 참조 (`ui_rect.zig` 머리 주석이 경계하는 것) 에 해당하지 않는다. 컨트롤이 셋이라
// 매핑을 세 renderer 에 복사하는 것보다 여기 한 곳에 두는 편이 낫다.
const tab_icons = @import("tab_icons.zig");
const search = @import("search.zig");

/// 패널 폭.
pub const WIDTH_PT: f32 = 320;

/// 여백의 **하한** (logical pt). 평소 여백은 터미널 셀 한 칸 · 한 줄이지만
/// (`Geometry.cell_w_pt` · `cell_h_pt`), 폰트가 아주 작으면 그것만으로는 패널이 가장자리에
/// 붙어 버린다. 셀 정보가 아직 없는 프레임 (`Geometry` 기본값 0) 의 안전망이기도 하다.
pub const MIN_GAP_PT: f32 = 6;

/// 패널 높이. **탭바 (28 pt) 보다 살짝 높다** — 탭바는 라벨만 얹히지만 검색바는 입력
/// 필드라 글자 위아래로 숨 쉴 자리가 필요하다. 28 은 눌려 보였고 44 는 과했다.
pub const HEIGHT_PT: f32 = 36;

/// 위쪽 경계선 두께. 탭 사이 구분선(`TAB_SEPARATOR_W_PT`)과 같다.
pub const BORDER_PT: f32 = @floatFromInt(ui_metrics.TAB_SEPARATOR_W_PT);

/// (포커스 표시는 테두리 **색** 으로 한다 — `rects` 참고. 두께는 평소와 같다.)
/// 좌우 끝 여백.
pub const PADDING_PT: f32 = 8;
/// 요소 사이 간격.
pub const GAP_PT: f32 = 6;
/// 컨트롤(‹ › ×) 한 칸 폭 — 탭바 컨트롤과 같다.
pub const CONTROL_W_PT: f32 = @floatFromInt(ui_metrics.TAB_CLOSE_W_PT);
/// 돋보기 아이콘 한 변. **탭 아이콘 (10 pt) 보다 크다** — 탭바에서는 아이콘만 나란히 있어
/// 10 pt 가 맞지만, 검색바에서는 13 pt 글자 바로 옆이라 같은 크기면 렌즈 모양이 안 읽힌다.
pub const ICON_PT: f32 = 14;
/// 돋보기 선 두께. **탭 아이콘 (1.5 pt) 보다 얇다** — 아이콘을 키우면 선도 같이 굵어져
/// 렌즈 속이 좁아지고 도넛처럼 보인다. macOS Terminal.app 의 검색 돋보기는 선이 렌즈 지름의
/// 10 % 남짓인데 1.5 pt 로는 18 % 가 된다.
pub const ICON_STROKE_PT: f32 = 1.0;

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

/// 패널을 어디에 놓을지 정하는 창 쪽 사정. **host 가 재서 `Ui` 에 실어 보내고 renderer 는
/// 그대로 쓴다** — 셋이 각자 재면 같은 창에서 platform 마다 다른 자리에 뜬다 (#159 와 같은
/// 이유). 단위는 전부 logical pt.
pub const Geometry = struct {
    viewport_w_pt: f32 = 0,
    viewport_h_pt: f32 = 0,

    /// 터미널 셀 한 칸의 폭 · 높이. 여백을 pt 상수가 아니라 **셀 단위**로 잡는 이유는
    /// 패널이 터미널 격자 위에 떠 있기 때문이다 (2026-09-16 사용자 결정) — 폰트를 키우면
    /// 여백도 같이 커져야 같은 만큼 떨어져 보인다.
    cell_w_pt: f32 = 0,
    cell_h_pt: f32 = 0,

    /// 창 오른쪽에 스크롤바가 떠 있으면 그 폭, 없으면 `0`. 패널의 오른쪽 기준선이 이만큼
    /// 안쪽으로 들어온다 — 스크롤바가 있는데 그것을 빼지 않으면 패널이 스크롤바에 붙는다.
    scrollbar_w_pt: f32 = 0,

    /// 터미널 격자 **맨 아랫줄의 아래 가장자리** (창 위에서부터). `0` 이면 모른다는 뜻이고
    /// 그때는 창 바닥을 기준으로 삼는다.
    ///
    /// 창 바닥이 아니라 이 값이 필요한 이유는 **패딩과 자투리** 때문이다. 격자 높이가 창에
    /// 딱 안 떨어져 아래에 한 줄이 안 되는 빈 자리가 남고, 그 위에 터미널 padding 이 또
    /// 있다. 창 바닥에서 한 줄을 세면 그 둘을 한 줄로 착각해 **맨 아랫줄을 파고든다** —
    /// 거기 프롬프트가 있다 (2026-09-16 실기).
    grid_bottom_pt: f32 = 0,
};

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

    /// 검색바가 키보드를 갖고 있는가. **바가 열려 있으면 언제나 참이다** — 포커스를 터미널과
    /// 나누지 않는다 (2026-09-16 사용자 결정, 근거는 `host/macos.zig` 의 `searchFocused`).
    ///
    /// 그래도 축을 남겨 두는 이유는 `input_policy.State.search_active` 와 짝이기 때문이다 —
    /// 둘을 가를 이유가 생기면 host 의 그 함수 하나만 바뀐다. 이 값이 거짓이면 renderer 는
    /// caret 을 그리지 않는다.
    focused: bool = false,

    /// 입력칸 가로 스크롤 (logical pt). caret 이 늘 보이게 한다.
    scroll_px: f32 = 0,

    /// pointer 가 올라간 컨트롤.
    hover: ?Control = null,

    /// 패널 배치 입력. renderer 는 이것을 `view` 에 그대로 넘긴다.
    geom: Geometry = .{},
};

/// pane 의 검색 상태에서 그리기용 상태를 만든다. **세 host 가 이 함수 하나를 쓴다** — 같은
/// 변환을 셋이 각자 적으면 카운터 규칙 같은 것이 조용히 갈린다.
///
/// `preedit` 과 `focused` · `hover` 는 검색 상태가 아니라 *입력* 쪽 사정이라 host 가 준다.
pub fn uiFrom(
    ps: *search.PaneSearch,
    preedit: []const u8,
    focused: bool,
    hover: ?Control,
    /// 탭 폰트 셀 폭 (logical pt). 입력칸 **글자** 산술에 쓴다 — 패널 여백에 쓰는
    /// `Geometry.cell_w_pt` (터미널 폰트) 와 다른 값이다.
    cw_pt: f32,
    /// 패널 배치 입력.
    geom: Geometry,
) Ui {
    // caret 이 늘 보이도록 스크롤을 갱신하고 **상태에 써 둔다** — 다음 프레임이 그 값을
    // 기준으로 hysteresis 를 판정한다.
    const field_w = view(geom).field.w;
    ps.field_scroll_px = fieldScrollOffset(
        ps.needle.items,
        ps.caret,
        cw_pt,
        field_w,
        textWidthPx(preedit, cw_pt),
        ps.field_scroll_px,
    );
    return .{
        .open = ps.is_open,
        .needle = ps.needle.items,
        .preedit = preedit,
        .caret = ps.caret,
        .current = ps.currentIndex(),
        .total = ps.matchCount(),
        .searching = ps.isSearching(),
        .focused = focused,
        .hover = hover,
        .scroll_px = ps.field_scroll_px,
        .geom = geom,
    };
}

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

/// 폭에 따라 무엇까지 보이는가. 패널 폭이 고정이라 평소에는 늘 `full` 이고, 창이 패널보다
/// 좁아 패널 자체가 줄 때만 갈린다.
pub const Stage = enum { full, no_icon, minimal, bare };

pub const NEED_FULL_PT: f32 = PADDING_PT * 2 + ICON_SLOT_PT + FIELD_MIN_PT + GAP_PT + COUNT_W_PT + CONTROL_W_PT * 3;
pub const NEED_NO_ICON_PT: f32 = PADDING_PT * 2 + FIELD_MIN_PT + GAP_PT + COUNT_W_PT + CONTROL_W_PT * 3;
pub const NEED_MINIMAL_PT: f32 = PADDING_PT * 2 + FIELD_MIN_PT + GAP_PT + COUNT_W_PT;

pub fn stageFor(bar_w_pt: f32) Stage {
    if (bar_w_pt >= NEED_FULL_PT) return .full;
    if (bar_w_pt >= NEED_NO_ICON_PT) return .no_icon;
    if (bar_w_pt >= NEED_MINIMAL_PT) return .minimal;
    return .bare;
}

/// 창 **우상단** 에 떠 있는 패널을 계산한다. `top_pt` 는 컨트롤 스트립 아래 y 다.
pub fn view(g: Geometry) View {
    // 오른쪽 기준선 — 스크롤바가 있으면 그 **왼쪽**이다.
    const right = @max(0, g.viewport_w_pt - g.scrollbar_w_pt);
    const gap_x = @max(MIN_GAP_PT, g.cell_w_pt);
    const gap_y = @max(MIN_GAP_PT, g.cell_h_pt);

    const bar_w = @min(WIDTH_PT, @max(0, right - gap_x * 2));
    const x0 = @max(0, right - gap_x - bar_w);
    // 창 **아래쪽** 모서리에 띄운다 (2026-09-16 실기로 옮김). 처음에는 컨트롤 스트립
    // 바로 아래였는데, 터미널을 쓰는 동안 시선은 늘 맨 아래 프롬프트에 있어서 검색어를
    // 칠 때마다 눈이 창 꼭대기까지 올라가야 했다. `vim` · `less` · `tmux` 가 모두 검색
    // 프롬프트를 맨 아랫줄에 두는 것과 같은 이유다 — 터미널의 입력은 아래에 있다.
    //
    // 가리는 면적도 아래가 낫다. 프롬프트 줄은 보통 짧아 우측 하단이 대체로 비지만,
    // 스크롤백을 읽을 때 우측 상단에는 글자가 차 있다.
    // 패널 바닥을 **맨 아랫줄의 윗변**에 맞춘다 — 그 줄의 프롬프트를 가리지 않는 것이
    // 아래로 내린 목적이다.
    const bottom_ref = if (g.grid_bottom_pt > 0) g.grid_bottom_pt else g.viewport_h_pt;
    const y = @max(0, bottom_ref - gap_y - HEIGHT_PT);

    const rect: Rect = .{ .x = x0, .y = y, .w = bar_w, .h = HEIGHT_PT };
    // 테두리는 패널 전체를 두른다 — `rects` 가 이 사각형을 먼저 칠하고 그 안에 배경을 얹는다.
    const border: Rect = rect;

    const inner_y = y + BORDER_PT;
    const inner_h = HEIGHT_PT - BORDER_PT * 2;

    const stage = stageFor(bar_w);
    const icon_slot: f32 = if (stage == .full) ICON_SLOT_PT else 0;
    const count_w: f32 = switch (stage) {
        .full, .no_icon, .minimal => COUNT_W_PT,
        .bare => 0,
    };
    const controls_w: f32 = switch (stage) {
        .full, .no_icon => CONTROL_W_PT * 3,
        .minimal, .bare => 0,
    };

    const total = @max(0, bar_w - PADDING_PT * 2);
    const used = icon_slot + count_w + (if (count_w > 0) GAP_PT else 0) + controls_w;
    const field_w = @max(0, total - used);

    var x = x0 + PADDING_PT;
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

    return .{ .rect = rect, .border = border, .icon = icon, .field = field, .count = count, .prev = prev, .next = next, .close = close };
}

fn emptyAt(x: f32, y: f32) Rect {
    return .{ .x = x, .y = y, .w = 0, .h = 0 };
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

/// `rects` 가 내보낼 수 있는 최대 개수 — 배경 · 위쪽 선 · hover 강조.
pub const MAX_RECTS: usize = 3;

/// 검색바의 **색칠된 사각형 목록** (device px). 세 renderer 가 이 함수 하나를 부르고,
/// 목록을 그린 뒤 자기 고유의 텍스트 (검색어 · 안내문 · 카운터) 와 아이콘 (돋보기 · ‹ › ×) ·
/// caret 을 그린다 — `command_menu.rects` 와 같은 계약이다.
///
/// ## 그리는 순서 (정본)
///
/// ```
///   바 배경 → 위쪽 선 (포커스면 amber) → hover 강조
///   (renderer)  아이콘 · 텍스트 · caret
/// ```
///
/// 위쪽 선은 **포커스 여부로 색과 두께가 함께 바뀐다** — 평소에는
/// `TAB_SEPARATOR_COLOR` 1 pt 경계선이고, 키보드 포커스가 바에 있으면 `TAB_ACCENT_COLOR`
/// 2 pt 다 (활성 탭 밑줄과 같은 두께 · 색). 두 상태가 *같은 자리* 를 쓰므로 경계선이
/// 사라지고 amber 가 생기는 것이 아니라 그 띠가 두꺼워지며 색이 바뀌는 것으로 보인다.
pub fn rects(
    out: []ui_rect.Rect,
    v: View,
    ui: Ui,
    scale: f32,
    palette: *const chrome_palette.Palette,
) []const ui_rect.Rect {
    var n: usize = 0;

    // 1. 테두리 — 패널 전체를 두르는 1 pt 선. 색은 탭 구분선 (`TAB_SEPARATOR_COLOR`) 이고
    //    **포커스 여부와 무관하게 늘 같다** (2026-09-11 시안 확정).
    //
    //    처음에는 포커스일 때 amber 로 바꿨는데 실기에서 보니 패널이 주황 상자가 되어
    //    터미널 위에서 과하게 튀었다. 입력이 어디로 가는지는 **깜빡이는 caret** 이 이미
    //    말해 주므로 테두리까지 쓸 필요가 없다 — amber 는 활성 탭 · pane 포커스가 쓰는
    //    신호라 여기서 또 쓰면 화면에 셋이 경쟁한다.
    const b = ui_metrics.linePx(BORDER_PT, scale);
    push(out, &n, .{
        .x = v.border.x * scale,
        .y = v.border.y * scale,
        .w = v.border.w * scale,
        .h = v.border.h * scale,
        .color = palette.separator,
    });

    // 2. 그 안쪽이 패널 면 — 탭바와 같은 표면.
    push(out, &n, .{
        .x = v.rect.x * scale + b,
        .y = v.rect.y * scale + b,
        .w = @max(0, v.rect.w * scale - b * 2),
        .h = @max(0, v.rect.h * scale - b * 2),
        .color = palette.tab_bar_bg,
    });

    // 3. hover 한 컨트롤 강조 — 탭바 컨트롤과 같은 색.
    if (ui.hover) |c| {
        const r = controlRect(v, c);
        if (r.w > 0) push(out, &n, .{
            .x = r.x * scale,
            .y = r.y * scale,
            .w = r.w * scale,
            .h = r.h * scale,
            .color = palette.ctrl_hover_bg,
        });
    }

    return out[0..n];
}

/// `command_menu.push` 와 같은 이유로 정수 격자에 맞춰 내보낸다 (#357 · `ui_rect.snapped`).
fn push(out: []ui_rect.Rect, n: *usize, r: ui_rect.Rect) void {
    if (n.* >= out.len) return; // 호출처 버퍼 상한 — `MAX_RECTS` 로 산정한다.
    out[n.*] = ui_rect.snapped(r);
    n.* += 1;
}

pub fn controlRect(v: View, c: Control) Rect {
    return switch (c) {
        .prev => v.prev,
        .next => v.next,
        .close => v.close,
    };
}

/// 컨트롤에 그릴 아이콘 종류. renderer 가 `tab_icons.rasterize` 에 넘긴다.
pub fn controlIcon(c: Control) tab_icons.Icon {
    return switch (c) {
        .prev => .chevron_left,
        .next => .chevron_right,
        .close => .close,
    };
}

pub const Glyph = struct { cp: u21, x: f32, advance: f32 };

/// caret 오른쪽에 늘 비워 두는 폭 (1 cell). **preedit 유무와 무관하게 고정** 이다 — 조합이
/// 시작 · 종료될 때 예약 폭이 바뀌면 caret 이 튄다 (탭 rename 의 `cursorReserve`, #341 이전).
pub fn caretReserve(cw: f32) f32 {
    return cw;
}

/// caret 이 늘 보이도록 텍스트를 왼쪽으로 민 거리 (px). **native textbox 패턴** (#168).
/// 탭 inline rename 의 `tab_layout.cursorScrollOffset` 을 그대로 가져왔다 — 그쪽은 #341 로
/// 사라졌지만 산술은 세 platform 에서 다듬어진 것이다 (2026-09-11 사용자 결정).
///
/// **핵심은 `prev_offset` 유지다.** caret 이 이미 보이면 스크롤을 바꾸지 않는다 — 매 프레임
/// 다시 계산하면 한 글자 칠 때마다 텍스트 전체가 흔들린다.
pub fn fieldScrollOffset(
    text: []const u8,
    caret_byte: usize,
    cw: f32,
    max_text_w: f32,
    preedit_advance_total: f32,
    prev_offset: f32,
) f32 {
    var caret_x: f32 = 0;
    var probe_iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var probe_byte: usize = 0;
    while (probe_iter.nextCodepoint()) |pcp| {
        if (probe_byte >= caret_byte) break;
        caret_x += cw * @as(f32, @floatFromInt(display_width.codepointWidth(@intCast(pcp))));
        probe_byte += std.unicode.utf8CodepointSequenceLength(pcp) catch 1;
    }
    const right_limit = max_text_w - caretReserve(cw);
    const caret_visual = caret_x - prev_offset;
    if (caret_visual + preedit_advance_total > right_limit) return caret_x + preedit_advance_total - right_limit;
    if (caret_visual < 0) return caret_x;
    return prev_offset;
}

/// caret 이 셀 안에서 차지하는 세로 구간 (위아래 2 px inset, #315 과 같은 계산).
pub const CaretVertical = struct { y: f32, height: f32 };

pub fn caretVertical(cell_top: f32, cell_height: f32) CaretVertical {
    const inset_px: f32 = 2;
    return .{ .y = cell_top + inset_px, .height = cell_height - inset_px * 2 };
}

/// 입력칸 텍스트의 glyph layout — **세 renderer 가 이 helper 하나를 쓴다** (#159 · #163 과
/// 같은 이유: 세 곳에 복사하면 같은 fix 를 세 번 해야 한다). 보이는 것만 emit 한다.
pub fn iterFieldText(
    text: []const u8,
    cw: f32,
    max_w: f32,
    scroll_px: f32,
    ctx: anytype,
    comptime cb: fn (@TypeOf(ctx), Glyph) void,
) void {
    var x: f32 = -scroll_px;
    var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        const advance = cw * @as(f32, @floatFromInt(display_width.codepointWidth(@intCast(cp))));
        if (x >= max_w) break;
        if (x >= 0 and x + advance <= max_w) cb(ctx, .{ .cp = @intCast(cp), .x = x, .advance = advance });
        x += advance;
    }
}

/// caret 이 서는 자리 (입력칸 왼쪽 가장자리 기준, logical pt). 조합 중이면 그 **뒤**다 —
/// 조합 글자는 caret 자리에 끼워 그리므로.
///
/// **renderer 와 IME 후보창이 이 한 함수를 쓴다.** 한자 · 일본어 후보 팝업은 caret 바로 아래에
/// 떠야 하는데, 두 곳이 각자 계산하면 글자 폭 · 스크롤 처리가 갈려 팝업이 caret 에서 떨어진다.
pub fn caretOffsetPt(text: []const u8, preedit: []const u8, caret_byte: usize, cw: f32, scroll_px: f32) f32 {
    const before = textWidthPx(text[0..@min(caret_byte, text.len)], cw);
    return before + textWidthPx(preedit, cw) - scroll_px;
}

/// 입력칸을 누른 자리 → **caret 의 byte offset.** `iterFieldText` 의 역함수다 — 같은 전제
/// (왼쪽으로 `scroll_px` 만큼 민 텍스트, 글자 폭은 `display_width`) 로 되짚는다.
///
/// `rel_x` 는 **입력칸 왼쪽 가장자리 기준** 이다 (`click_x - view.field.x`). host 가 창 좌표를
/// 넘기면 세 곳이 각자 빼야 해서 어긋난다.
///
/// 글자 **가운데를 기준**으로 앞뒤를 가른다 — 글자의 왼쪽 절반을 누르면 그 앞, 오른쪽 절반을
/// 누르면 그 뒤다. native textbox 가 모두 같고, 이것이 없으면 글자 오른쪽 끝을 눌러도 caret 이
/// 그 앞에 서서 "누른 자리와 다른 곳에 커서가 생긴다".
pub fn fieldCaret(text: []const u8, cw: f32, scroll_px: f32, rel_x: f32) usize {
    // 텍스트 좌표계로 옮긴다 (스크롤된 만큼 더한다).
    const target = rel_x + scroll_px;
    if (target <= 0) return 0;

    var x: f32 = 0;
    var byte: usize = 0;
    var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        const advance = cw * @as(f32, @floatFromInt(display_width.codepointWidth(@intCast(cp))));
        if (target < x + advance * 0.5) return byte;
        byte += std.unicode.utf8CodepointSequenceLength(cp) catch 1;
        x += advance;
    }
    return text.len;
}

/// 문자열의 표시 폭 (px).
pub fn textWidthPx(text: []const u8, cw: f32) f32 {
    return @as(f32, @floatFromInt(display_width.stringWidth(text))) * cw;
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

/// 테스트용 — 셀 14×20 pt, 스크롤바 없음의 평범한 창. 격자 바닥은 창 바닥에서 패딩 6 pt
/// 와 자투리 4 pt 를 뺀 자리에 둔다 (실제 창이 늘 그렇다).
fn testGeom(w: f32, h: f32) Geometry {
    return .{
        .viewport_w_pt = w,
        .viewport_h_pt = h,
        .cell_w_pt = 14,
        .cell_h_pt = 20,
        .grid_bottom_pt = h - 10,
    };
}

test "#646 view — 패널 바닥이 맨 아랫줄의 윗변에 맞는다 (프롬프트를 안 가린다)" {
    // 격자 바닥이 창 바닥에서 10 pt 위 (패딩 + 자투리). 맨 아랫줄은 그 위 20 pt 다.
    const g: Geometry = .{
        .viewport_w_pt = 800,
        .viewport_h_pt = 600,
        .cell_w_pt = 14,
        .cell_h_pt = 20,
        .grid_bottom_pt = 590,
    };
    const v = view(g);
    const last_row_top = g.grid_bottom_pt - g.cell_h_pt;
    try std.testing.expectEqual(last_row_top, v.rect.y + v.rect.h);

    // 창 바닥만 보고 세면 맨 아랫줄을 10 pt 파고든다 — 그것이 실기에서 난 결함이다.
    const naive_bottom = g.viewport_h_pt - g.cell_h_pt;
    try std.testing.expect(naive_bottom > last_row_top);
}

test "#646 view — 스크롤바가 있으면 그 왼쪽을 기준으로 잡는다" {
    const w: f32 = 800;
    const without = view(.{ .viewport_w_pt = w, .viewport_h_pt = 600, .cell_w_pt = 14, .cell_h_pt = 20 });
    const with_sb = view(.{ .viewport_w_pt = w, .viewport_h_pt = 600, .cell_w_pt = 14, .cell_h_pt = 20, .scrollbar_w_pt = 10 });

    // 스크롤바 폭만큼 통째로 왼쪽으로 온다 — 붙지 않는다.
    try std.testing.expectEqual(without.rect.x - 10, with_sb.rect.x);
    // 패널 오른쪽 끝과 스크롤바 왼쪽 사이가 정확히 셀 한 칸이다.
    try std.testing.expectEqual(@as(f32, 14), (w - 10) - (with_sb.rect.x + with_sb.rect.w));
}

test "#646 view — 셀이 아주 작아도 가장자리에 붙지 않는다" {
    // 셀 정보가 없는 프레임 (기본값 0) 과 아주 작은 폰트 모두 하한이 받는다.
    for ([_]Geometry{
        .{ .viewport_w_pt = 800, .viewport_h_pt = 600 },
        .{ .viewport_w_pt = 800, .viewport_h_pt = 600, .cell_w_pt = 2, .cell_h_pt = 3 },
    }) |g| {
        const v = view(g);
        try std.testing.expect(800 - (v.rect.x + v.rect.w) >= MIN_GAP_PT);
        try std.testing.expect(600 - (v.rect.y + v.rect.h) >= MIN_GAP_PT);
    }
}

test "#646 view — 패널은 창 우하단 모서리에 뜬다" {
    const h: f32 = 600;
    const v = view(testGeom(800, h));
    try std.testing.expectEqual(WIDTH_PT, v.rect.w);
    try std.testing.expectEqual(HEIGHT_PT, v.rect.h);
    // 오른쪽은 셀 한 칸, 아래는 셀 한 줄 띄운다 — 여백이 터미널 격자를 따른다.
    try std.testing.expectEqual(@as(f32, 800) - 14 - WIDTH_PT, v.rect.x);
    try std.testing.expectEqual((h - 10) - 20 - HEIGHT_PT, v.rect.y);
    // 테두리는 패널 전체를 두른다.
    try std.testing.expectEqual(v.rect.x, v.border.x);
    try std.testing.expectEqual(v.rect.w, v.border.w);
    try std.testing.expectEqual(v.rect.h, v.border.h);
}

test "#646 view — 창이 패널보다 좁으면 화면 밖으로 안 나간다" {
    const v = view(testGeom(100, 600));
    try std.testing.expect(v.rect.x >= 0);
    try std.testing.expect(v.rect.x + v.rect.w <= 100 + 0.001);
}

test "#646 view — 요소가 겹치지 않고 왼쪽에서 오른쪽 순서다" {
    const v = view(testGeom(800, 600));
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
    try std.testing.expectEqual(Stage.minimal, stageFor(NEED_NO_ICON_PT - 1));
    try std.testing.expectEqual(Stage.bare, stageFor(NEED_MINIMAL_PT - 1));

    const full = view(testGeom(1600, 600));
    try std.testing.expectEqual(Stage.full, stageFor(full.rect.w));
    try std.testing.expect(full.icon.w > 0 and full.count.w > 0 and full.close.w > 0);

    const no_icon = view(testGeom(NEED_NO_ICON_PT + 14 * 2, 600));
    try std.testing.expectEqual(@as(f32, 0), no_icon.icon.w);
    try std.testing.expect(no_icon.count.w > 0);

    const bare = view(testGeom(NEED_MINIMAL_PT + 14 * 2 - 1, 600));
    try std.testing.expectEqual(@as(f32, 0), bare.count.w);
    try std.testing.expect(bare.field.w > 0);
}

test "#646 view — 폭이 줄면 요소가 늘지 않는다 (단조)" {
    var w: f32 = 900;
    var prev_icon: f32 = std.math.floatMax(f32);
    var prev_count: f32 = std.math.floatMax(f32);
    var prev_ctrl: f32 = std.math.floatMax(f32);
    while (w >= 0) : (w -= 1) {
        const v = view(testGeom(w, 600));
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
    const v = view(testGeom(800, 600));
    const cy = v.rect.y + HEIGHT_PT * 0.5;
    try std.testing.expectEqual(Control.prev, hit(v, v.prev.x + 1, cy).?);
    try std.testing.expectEqual(Control.next, hit(v, v.next.x + 1, cy).?);
    try std.testing.expectEqual(Control.close, hit(v, v.close.x + 1, cy).?);
    // 입력칸은 컨트롤이 아니다.
    try std.testing.expect(hit(v, v.field.x + 1, cy) == null);
    // 바 밖.
    try std.testing.expect(hit(v, 400, v.rect.y - 5) == null);
}

test "#646 contains — 패널 위인지 가른다" {
    const v = view(testGeom(800, 600));
    const cx = v.rect.x + v.rect.w * 0.5;
    try std.testing.expect(contains(v, cx, v.rect.y + 1));
    try std.testing.expect(!contains(v, cx, v.rect.y - 1));
    try std.testing.expect(!contains(v, v.rect.x - 1, v.rect.y + 1));
}

test "#646 countText — 상태마다 다른 문구" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("…", countText(.{ .searching = true }, &buf));
    try std.testing.expectEqualStrings("0/0", countText(.{ .total = 0 }, &buf));
    try std.testing.expectEqualStrings("17", countText(.{ .total = 17 }, &buf));
    try std.testing.expectEqualStrings("3/17", countText(.{ .current = 3, .total = 17 }, &buf));
}

test "#646 rects — 테두리 안에 패널 면이 들어가고 정수 격자에 맞는다" {
    const chrome = chrome_palette.derive(.{ 0, 0, 0 }, true);
    const v = view(testGeom(800, 600));
    var buf: [MAX_RECTS]ui_rect.Rect = undefined;

    const rs = rects(&buf, v, .{ .open = true }, 1.0, &chrome);
    try std.testing.expectEqual(@as(usize, 2), rs.len); // 테두리 + 면 (hover 없음)

    // 평소 테두리는 탭 구분선 색, 그 안쪽이 탭바와 같은 표면이다.
    try std.testing.expectEqual(chrome.separator, rs[0].color);
    try std.testing.expectEqual(chrome.tab_bar_bg, rs[1].color);
    // 면이 테두리 안에 들어간다.
    try std.testing.expect(rs[1].x > rs[0].x);
    try std.testing.expect(rs[1].x + rs[1].w < rs[0].x + rs[0].w);

    for (rs) |r| {
        try std.testing.expectEqual(@round(r.x), r.x);
        try std.testing.expectEqual(@round(r.w), r.w);
    }
}

test "#646 rects — 테두리 색은 포커스와 무관하게 같다" {
    const chrome = chrome_palette.derive(.{ 0, 0, 0 }, true);
    const v = view(testGeom(800, 600));
    var a2: [MAX_RECTS]ui_rect.Rect = undefined;
    var b2: [MAX_RECTS]ui_rect.Rect = undefined;

    const plain = rects(&a2, v, .{ .open = true, .focused = false }, 2.0, &chrome);
    const focused = rects(&b2, v, .{ .open = true, .focused = true }, 2.0, &chrome);

    // 포커스로 패널 모양도 색도 바뀌지 않는다 — 입력 위치는 caret 이 말한다.
    try std.testing.expectEqual(plain.len, focused.len);
    try std.testing.expectEqual(chrome.separator, plain[0].color);
    try std.testing.expectEqual(chrome.separator, focused[0].color);
}

test "#646 rects — hover 한 컨트롤만 강조가 붙는다" {
    const chrome = chrome_palette.derive(.{ 0, 0, 0 }, true);
    const v = view(testGeom(800, 600));
    var buf: [MAX_RECTS]ui_rect.Rect = undefined;

    const rs = rects(&buf, v, .{ .open = true, .hover = .close }, 1.0, &chrome);
    try std.testing.expectEqual(@as(usize, 3), rs.len);
    try std.testing.expectEqual(chrome.ctrl_hover_bg, rs[2].color);
    // 강조가 그 컨트롤 자리에 있다.
    try std.testing.expectEqual(@round(v.close.x), rs[2].x);
}

test "#646 rects — 컨트롤이 접힌 폭에서는 hover 강조를 만들지 않는다" {
    const chrome = chrome_palette.derive(.{ 0, 0, 0 }, true);
    const v = view(testGeom(NEED_MINIMAL_PT + 14 * 2, 600)); // 컨트롤 접힘
    var buf: [MAX_RECTS]ui_rect.Rect = undefined;

    // 폭 0 인 컨트롤에 hover 가 남아 있어도 빈 rect 를 내보내지 않는다.
    const rs = rects(&buf, v, .{ .open = true, .hover = .close }, 1.0, &chrome);
    try std.testing.expectEqual(@as(usize, 2), rs.len);
}

test "#646 fieldCaret — 글자 가운데를 기준으로 앞뒤가 갈린다" {
    const cw: f32 = 10;
    const text = "abc";

    try std.testing.expectEqual(@as(usize, 0), fieldCaret(text, cw, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), fieldCaret(text, cw, 0, 4)); // `a` 왼쪽 절반
    try std.testing.expectEqual(@as(usize, 1), fieldCaret(text, cw, 0, 6)); // `a` 오른쪽 절반
    try std.testing.expectEqual(@as(usize, 1), fieldCaret(text, cw, 0, 14));
    try std.testing.expectEqual(@as(usize, 2), fieldCaret(text, cw, 0, 16));
    // 텍스트 오른쪽 빈 자리를 누르면 맨 뒤.
    try std.testing.expectEqual(@as(usize, 3), fieldCaret(text, cw, 0, 500));
    // 왼쪽 바깥은 맨 앞.
    try std.testing.expectEqual(@as(usize, 0), fieldCaret(text, cw, 0, -20));
}

test "#646 fieldCaret — 두 칸 글자는 두 칸 폭으로 센다" {
    const cw: f32 = 10;
    const text = "가b"; // `가` 는 3 byte · 2 칸

    try std.testing.expectEqual(@as(usize, 0), fieldCaret(text, cw, 0, 9));
    try std.testing.expectEqual(@as(usize, 3), fieldCaret(text, cw, 0, 11)); // `가` 가운데 넘김
    try std.testing.expectEqual(@as(usize, 3), fieldCaret(text, cw, 0, 24));
    try std.testing.expectEqual(@as(usize, 4), fieldCaret(text, cw, 0, 26));
}

test "#646 fieldCaret — 가로 스크롤을 되짚는다" {
    const cw: f32 = 10;
    const text = "abcdef";
    // 20 px 만큼 왼쪽으로 밀렸으면, 화면 x=0 은 텍스트의 `c` 자리다.
    try std.testing.expectEqual(@as(usize, 2), fieldCaret(text, cw, 20, 0));
    try std.testing.expectEqual(@as(usize, 3), fieldCaret(text, cw, 20, 6));
}

test "#646 fieldCaret — iterFieldText 와 같은 자리를 가리킨다" {
    // 역함수 관계를 고정한다. 각 글리프의 시작 x 를 그대로 누르면 그 글자 앞이어야 한다.
    const cw: f32 = 12;
    const text = "a가b다c";
    const Ctx = struct {
        var xs: [8]f32 = undefined;
        var bytes: [8]usize = undefined;
        var n: usize = 0;
    };
    Ctx.n = 0;
    iterFieldText(text, cw, 1000, 0, {}, struct {
        fn cb(_: void, g: Glyph) void {
            Ctx.xs[Ctx.n] = g.x;
            Ctx.n += 1;
        }
    }.cb);

    var byte: usize = 0;
    var i: usize = 0;
    var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iter.nextCodepoint()) |cp| : (i += 1) {
        // 글리프 시작 x 에서 아주 조금 오른쪽 = 그 글자의 왼쪽 절반 → 그 글자 앞.
        try std.testing.expectEqual(byte, fieldCaret(text, cw, 0, Ctx.xs[i] + 1));
        byte += std.unicode.utf8CodepointSequenceLength(cp) catch 1;
    }
    try std.testing.expectEqual(text.len, byte);
}

test "#646 caretOffsetPt — 예전 renderer 산술과 같은 값" {
    // 세 renderer 가 각자 적던 `before_w + preedit_w - scroll` 을 helper 로 모았다.
    // 그 치환이 값이 같은지 고정한다 (macOS 는 px, Linux 는 정수 px, 단위는 무관하다).
    const cw: f32 = 10;
    const needle = "abcdef";
    const preedit = "가";
    const caret: usize = 3;
    const scroll: f32 = 25;

    const before_w = textWidthPx(needle[0..caret], cw);
    const preedit_w = textWidthPx(preedit, cw);
    try std.testing.expectEqual(
        before_w + preedit_w - scroll,
        caretOffsetPt(needle, preedit, caret, cw, scroll),
    );
}

test "#646 caretOffsetPt — caret 범위를 넘겨도 끝에서 멈춘다" {
    const cw: f32 = 10;
    const needle = "abc";
    // 결과가 줄어드는 중에 caret 이 남아 있을 수 있다 — 자르지 않으면 slice 가 터진다.
    try std.testing.expectEqual(
        textWidthPx(needle, cw),
        caretOffsetPt(needle, "", 999, cw, 0),
    );
}

test "#646 caretOffsetPt 와 fieldCaret 은 서로의 역이다" {
    // 클릭 → byte offset (`fieldCaret`) 과 byte offset → x (`caretOffsetPt`) 가 어긋나면
    // "누른 자리와 다른 곳에 커서가 생긴다". 두 함수가 같은 전제를 쓰는지 고정한다.
    const cw: f32 = 12;
    const text = "a가b다c";
    for ([_]f32{ 0, 17, 40 }) |scroll| {
        var byte: usize = 0;
        var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (true) {
            const x = caretOffsetPt(text, "", byte, cw, scroll);
            // caret 자리에서 아주 조금 오른쪽을 누르면 같은 offset 으로 돌아와야 한다.
            try std.testing.expectEqual(byte, fieldCaret(text, cw, scroll, x + 0.5));
            const cp = iter.nextCodepoint() orelse break;
            byte += std.unicode.utf8CodepointSequenceLength(cp) catch 1;
        }
    }
}
