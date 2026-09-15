//! [#483](https://github.com/ensky0/tildaz/issues/483) 2단계 ② — pane 하나를 그리는 데 렌더러가
//! 받는 입력. 세 렌더러 (Windows `D3d11Renderer` · macOS `MetalRenderer` · Linux
//! `software_terminal.Renderer`) 가 같은 struct 를 받아서, host 가 pane 을 어떻게 배치했는지
//! (1단계 `pane_layout.layout()`) 와 렌더러가 그것을 어떻게 그리는지가 한 자료형으로 만난다.
//!
//! `rect` 는 **탭바를 뺀** px 영역이다 — pane 하나면 `{0, tab_bar_h, W, H − tab_bar_h}` 이고,
//! 그때 격자 원점 `rect + pad` 와 scrollbar track 은 이전 `renderTerminal` 의 인자 (`padding` /
//! `tab_bar_h + padding` / `scrollbar_y_offset`) 와 같은 값이 된다. 2단계는 그 항등을 지키는
//! 것이 목표다 (화면 변화 0). 4단계에서 host 가 `layout()` 의 pane 마다 이것을 하나씩 만든다.

const ghostty = @import("ghostty-vt");
const pane_layout = @import("../pane_layout.zig");
const search = @import("../search.zig");
const link = @import("../link.zig");

pub const PaneDraw = struct {
    terminal: *ghostty.Terminal,
    /// 이 터미널의 `Tab.render_state` (2단계 ①). 렌더러가 `update` 하고 읽는다.
    state: *ghostty.RenderState,
    /// 탭바를 뺀 pane 영역 (physical px). 1단계 `PaneRect.rect` 와 같은 뜻이다.
    rect: pane_layout.Rect,
    cell_w: i32,
    cell_h: i32,
    /// `ui_metrics.TERMINAL_PADDING_PT` 의 px — pane 네 변에 붙는다.
    pad: i32,
    /// scrollbar 폭 · thumb 최소 높이 (px). **f32 인 이유** — macOS 는 `ui_metrics.scaledPxF` 로
    /// 소수를 그대로 넘기고, Windows · Linux 는 정수를 넘긴다. 셋 다 지금 넘기는 값을 그대로 담아
    /// `scrollbar.thumbRect` (f64) 에 이르게 한다 — 여기서 정수로 바꾸면 macOS 픽셀이 바뀔 수 있다.
    scrollbar_w: f32,
    scrollbar_min_thumb_h: f32,
    /// scrollbar track 을 pane 윗변에서 얼마나 내리는가 (px). 탭이 하나면 `[+][×][…]` 컨트롤
    /// 스트립이 터미널 위에 얹히므로 (#329) 그 높이, 탭바가 있으면 0. host 가
    /// `scrollbarTopInset − tab_bar_h` 로 계산한다.
    scrollbar_top_inset: i32,
    /// IME 조합 중 글자 — cursor 뒤 inline 표시. 빈 slice 면 표시 안 함. Linux 는 IME preedit 이 없을 때 dead key
    /// 조합 중 표시 (#530 `compose_preview`) 를 같은 자리에 넣는다 — 어느 쪽이든 활성 pane 에만.
    preedit_utf8: []const u8,
    /// #376 — 프레임 단위 blink 위상. host 의 게이트가 구한 값을 그대로 내린다.
    blink_faint: bool,
    /// #646 — 이 pane 의 검색 상태. renderer 가 `state.update` 직후에
    /// `applyHighlights` 를 불러 매치를 `state` 의 per-row 강조로 칠한다.
    ///
    /// **검색 중이 아니어도 넘긴다** — 검색을 막 껐을 때 남아 있는 강조를 지우는 것도
    /// 그 함수의 일이라, 여기서 `null` 로 바꾸면 강조가 화면에 남는다. host 가 pane 을
    /// 그릴 수 없는 경우 (테스트 하네스 등) 만 `null` 이다.
    search: ?*search.PaneSearch,
    /// #647 — 마우스가 가리키는 링크. **활성 pane 에만 실린다** (포인터가 하나라 hover 도
    /// 하나다). 렌더러가 `state.update` 직후 `applyHighlights` 를 불러 `link_hover` 강조를
    /// 칠하고, 셀마다 `cell_highlight.withLinkUnderline` 이 그것을 밑줄로 바꾼다.
    link_hover: ?*link.Hover,
    /// #483 5단계 — 키보드가 가는 pane 인가. 렌더러가 pane 마다 달라야 하는 부수 효과 (Windows 의 IME 조합
    /// 창 위치 `last_cursor_px`) 를 활성 pane 에만 적용하는 데 쓴다. 그리기 자체는 이 값을 보지 않는다.
    is_active: bool,
};
