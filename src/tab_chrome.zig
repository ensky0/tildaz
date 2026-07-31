//! #343 — 탭바 chrome 을 **색칠된 사각형 목록** 으로 만드는 cross-platform 단일 정의.
//!
//! 이전에는 같은 그리기가 세 renderer 에 삼중으로 있었다. macOS 와 Windows 는
//! `BgInstance { pos, size, color }` 배열을 채우고, Linux 만 정수 software
//! rasterizer 라 `rect()` 를 직접 호출했다 — 구조가 같은데 코드가 셋이라
//! [#342](https://github.com/ensky0/tildaz/issues/342) 의 지오메트리 변경은 같은
//! 편집을 세 번 해야 했다.
//!
//! 여기서 만드는 것은 **rect 목록과 그 순서** 뿐이다. 계산·판정은 이미 공유
//! 모듈이 담당한다 — `tab_layout` (버튼 layout / hit-test / `hasSeparator` /
//! `activeUnderlineEdges`), `tab_icons` (아이콘 비트맵), `chrome_palette` (색),
//! `ui_metrics` (pt→px). 텍스트와 아이콘만 renderer 고유로 남는다 (glyph atlas
//! vs 직접 rasterize).
//!
//! ## 그리는 순서 (정본)
//!
//! ```
//!   rects[0..before_titles]   탭바 배경 → 활성 탭 amber 밑줄
//!   (renderer)                탭 제목 텍스트
//!   rects[before_titles..]    컨트롤 bg fill → hover 박스 → 세로 구분선
//!   (renderer)                컨트롤 아이콘 (`< > × + …`)
//! ```
//!
//! **이 순서를 정본으로 고정한 것이 이 모듈의 핵심 결정이다** (2026-07-31 사용자
//! 결정). 통합 전 세 renderer 는 뒤 네 layer 의 순서가 서로 달랐다 — Linux 는
//! `fill → hover → 아이콘 → 세로선`, macOS 는 `fill → 세로선 → hover → 아이콘`,
//! Windows 는 `fill → hover → 세로선 → 아이콘`. 세 코드 모두 주석에는 같은 의도를
//! 적어 두고 구현이 셋이었다 (GPU renderer 는 rect 를 버퍼에 모아 flush 하므로
//! 코드 순서가 아니라 flush 순서가 z-order 라 눈에 띄지 않았다). 각 layer 가 다수
//! 쪽을 따르는 Windows 순서를 정본으로 삼았다.
//!
//! ## clip 은 지오메트리로 한다 — 나중에 덮어 가리지 않는다
//!
//! 활성 탭 amber 밑줄은 `tab_area` 로 **명시 clip** 한다. 이전 macOS · Windows 는
//! 슬롯 폭 그대로 emit 하고 나중에 그리는 컨트롤 fill 이 덮게 뒀는데, 그리기 순서가
//! 조금만 바뀌면 조용히 깨지는 방식이고 AGENTS.md `# 근본 해결 원칙` 의 "증상을
//! 가리는 fix" 에 해당한다 (같은 종류가 [#342](https://github.com/ensky0/tildaz/issues/342)
//! 에서 기각됐다). 실측 근거는 [#343 Windows](https://github.com/ensky0/tildaz/issues/343#issuecomment-5114021989)
//! · [macOS](https://github.com/ensky0/tildaz/issues/343#issuecomment-5114134914) 코멘트.

const std = @import("std");
const tab_layout = @import("tab_layout.zig");
const tab_interaction = @import("tab_interaction.zig");
const ui_metrics = @import("ui_metrics.zig");
const chrome_palette = @import("chrome_palette.zig");

/// device pixel 단위 사각형. 색은 `chrome_palette` 와 같은 linear-free `[4]f32`
/// (renderer 가 자기 형식으로 옮긴다 — macOS · Windows 는 `BgInstance` 에 그대로,
/// Linux 는 `snap()` 으로 정수화 후 8-bit RGB).
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: [4]f32,
};

pub const Inputs = struct {
    /// 창 전체 폭 (탭바 배경이 가로 전체를 덮는다).
    viewport_w: f32,
    tab_bar_h: f32,
    tab_w: f32,
    /// 세로 구분선 두께. 경계 중심 정렬이라 슬롯 안으로 좌우 `sep_w/2` 씩 들어온다.
    sep_w: f32,
    /// 활성 탭 amber 밑줄 두께.
    underline_h: f32,
    /// hover 박스가 컨트롤 버튼 box 안으로 물러나는 양 (네 방향 동일).
    hover_inset: f32,
    tab_count: usize,
    active_idx: usize,
    scroll_x: f32,
    drag: ?tab_interaction.DragView,
    layout: tab_layout.Layout,
    hover: tab_layout.Area,
    palette: *const chrome_palette.Palette,
};

pub const Chrome = struct {
    rects: []const Rect,
    /// `rects[0..before_titles]` 를 그린 뒤 탭 제목을, 나머지를 그린 뒤 아이콘을
    /// 그린다 (위 "그리는 순서" 참고).
    before_titles: usize,
};

/// `build` 가 만들 수 있는 rect 최대 개수 — 호출처 고정 버퍼 크기 산정용.
/// 탭바 배경 1 + 밑줄 1 + 컨트롤 fill 5 + hover 1 + 구분선 `tab_count + 1`.
pub fn maxRects(tab_count: usize) usize {
    return 8 + tab_count + 1;
}

/// 탭 `i` 의 화면 x. drag 중인 탭은 포인터를 따라간다 (나머지는 world 슬롯 고정 —
/// 원위치 슬롯이 비어 보여 재배열 위치를 인지할 수 있다).
pub fn tabX(i: usize, in: Inputs) f32 {
    if (in.drag) |d| {
        if (d.tab_index == i) {
            return @as(f32, @floatFromInt(d.current_x)) - in.tab_w * 0.5 - in.scroll_x + in.layout.tab_area_x;
        }
    }
    return @as(f32, @floatFromInt(i)) * in.tab_w - in.scroll_x + in.layout.tab_area_x;
}

pub const ClipDecision = enum { skip, stop, draw };

/// 탭 하나가 `tab_area` 밖이라 그릴 필요가 없는지. drag 중에는 loop 의 x 단조성이
/// 깨지므로 (drag 탭이 임의 위치) 우측 밖에서도 `stop` 대신 `skip` 이다.
/// 이전에는 Linux 만 이 판정을 갖고 있었고 macOS · Windows 는 전부 emit 한 뒤
/// 덮어 가렸다 — rect 를 애초에 만들지 않는 것이 명시 clip 과 같은 결이다.
pub fn tabClip(tab_left: f32, tab_w: f32, area_left: f32, area_right: f32, drag_active: bool) ClipDecision {
    if (tab_left + tab_w <= area_left) return .skip;
    if (tab_left >= area_right) return if (drag_active) .skip else .stop;
    return .draw;
}

/// 정수 rasterizer (Linux software renderer) 전용 변환. **양 끝을 각각 반올림한 뒤
/// 크기를 뺀다** — 위치와 크기를 따로 절단하면 오차가 누적돼 아랫변이 1px 모자란다
/// ([#344](https://github.com/ensky0/tildaz/issues/344) 에서 scrollbar thumb 이
/// 실제로 그랬다). `scrollbar.thumbPx` 와 같은 계약이다.
///
/// [#277](https://github.com/ensky0/tildaz/issues/277) 이 Linux 를 EGL/OpenGL ES
/// (f32) 로 바꾸면 **이 함수와 그 호출부만** 걷어내면 된다 — rect 목록을 만드는
/// 위 코드는 그대로 남는다.
pub const IRect = struct { x: i32, y: i32, w: i32, h: i32 };

pub fn snap(r: Rect) IRect {
    const x0 = @round(r.x);
    const y0 = @round(r.y);
    const x1 = @round(r.x + r.w);
    const y1 = @round(r.y + r.h);
    return .{
        .x = @intFromFloat(x0),
        .y = @intFromFloat(y0),
        .w = @max(1, @as(i32, @intFromFloat(x1 - x0))),
        .h = @max(1, @as(i32, @intFromFloat(y1 - y0))),
    };
}

fn push(out: []Rect, n: *usize, r: Rect) void {
    if (n.* >= out.len) return; // 호출처 버퍼 상한 — `maxRects` 로 산정한다.
    out[n.*] = r;
    n.* += 1;
}

pub fn build(out: []Rect, in: Inputs) Chrome {
    var n: usize = 0;
    const area_left = in.layout.tab_area_x;
    const area_right = in.layout.tab_area_x + in.layout.tab_area_w;

    // 1. 탭바 전체 배경. 탭 배경은 따로 그리지 않는다 — 탭바와 같은 색이고
    //    경계는 세로 구분선이 표시한다 (#334 2026-07-22, Tilda 문법).
    push(out, &n, .{
        .x = 0,
        .y = 0,
        .w = in.viewport_w,
        .h = in.tab_bar_h,
        .color = in.palette.tab_bar_bg,
    });

    // 2. 활성 탭 amber 밑줄 — 활성 구분의 유일한 표시 (#334). #342 로 가로
    //    경계선이 없어져 탭바 **맨 아래 모서리**. 세로 구분선과 겹치지 않도록
    //    밑줄 자체가 물러난다 (덮어 가리기가 아니라 지오메트리, #342).
    if (in.active_idx < in.tab_count) {
        const tx = tabX(in.active_idx, in);
        const is_dragged = if (in.drag) |d| d.tab_index == in.active_idx else false;
        const edges = tab_layout.activeUnderlineEdges(
            in.active_idx,
            in.tab_count,
            is_dragged,
            in.layout.arrows_visible,
            area_left,
            area_right,
            in.tab_w,
            in.scroll_x,
        );
        const half = in.sep_w * 0.5;
        const cut_l: f32 = if (edges.inset_left) half else 0;
        const cut_r: f32 = if (edges.inset_right) half else 0;
        const ux = tx + cut_l;
        const uw = in.tab_w - cut_l - cut_r;
        // tab_area 로 명시 clip — 컨트롤 영역까지 그려 놓고 나중에 덮지 않는다.
        const cx = @max(ux, area_left);
        const cw = @min(ux + uw, area_right) - cx;
        if (cw > 0) {
            push(out, &n, .{
                .x = cx,
                .y = in.tab_bar_h - in.underline_h,
                .w = cw,
                .h = in.underline_h,
                .color = ui_metrics.TAB_ACCENT_COLOR,
            });
        }
    }

    const before_titles = n;

    // 3·4. 컨트롤 bg fill → hover 박스.
    pushControls(out, &n, in);

    // 5. 탭 슬롯 경계 세로 구분선 — **모두 중심 정렬** (안쪽 정렬은 끝 탭만
    //    좁아져 기각, #334). world(슬롯) 기준이라 drag 중 빈 원위치 슬롯의
    //    경계도 유지된다. 컨트롤 fill · 밑줄 뒤에 그려 항상 온전한 두께.
    {
        var bi: usize = 0;
        while (bi <= in.tab_count) : (bi += 1) {
            if (!tab_layout.hasSeparator(
                bi,
                in.tab_count,
                in.layout.arrows_visible,
                area_left,
                area_right,
                in.tab_w,
                in.scroll_x,
            )) continue;
            const x = area_left + @as(f32, @floatFromInt(bi)) * in.tab_w - in.scroll_x;
            push(out, &n, .{
                .x = x - in.sep_w * 0.5,
                .y = 0,
                .w = in.sep_w,
                .h = in.tab_bar_h,
                .color = in.palette.separator,
            });
        }
    }

    return .{ .rects = out[0..n], .before_titles = before_titles };
}

/// #329 — 단일 탭일 때는 탭바를 띄우지 않고 우측 상단 `[+][×][…]` 만 overlay 한다.
/// 그 경로가 쓰는 진입점 — `build` 의 컨트롤 구간과 **같은 함수**를 호출하므로
/// fill / hover 지오메트리와 순서가 갈리지 않는다.
///
/// `Inputs` 중 `layout` · `hover` · `hover_inset` · `tab_bar_h` · `palette` 만
/// 쓴다 (나머지는 호출처가 0 을 넣어도 된다).
pub fn buildControlsOnly(out: []Rect, in: Inputs) []const Rect {
    var n: usize = 0;
    pushControls(out, &n, in);
    return out[0..n];
}

/// 컨트롤 bg fill (`< > × + …` 버튼 자리) → hover 강조 박스.
///
/// fill 은 제목 텍스트 **뒤에** 그려서 tab_area 를 넘어온 glyph 를 가리는 역할도
/// 했는데, 텍스트가 명시 clip 으로 바뀌어 이제는 순수한 버튼 배경이다.
/// hover 는 버튼 bg 위 / 아이콘 아래 — 비활성 화살표와 비활성 `+` 는 host 가
/// hover 를 억제하므로 여기서 다시 판정한다.
fn pushControls(out: []Rect, n: *usize, in: Inputs) void {
    if (in.layout.arrows_visible) {
        pushControlBg(out, n, in, in.layout.left_arrow_x, in.layout.arrow_w);
        pushControlBg(out, n, in, in.layout.right_arrow_x, in.layout.arrow_w);
    }
    pushControlBg(out, n, in, in.layout.close_x, in.layout.close_w);
    pushControlBg(out, n, in, in.layout.plus_x, in.layout.plus_w);
    pushControlBg(out, n, in, in.layout.more_x, in.layout.more_w);

    var hx: f32 = 0;
    var hw: f32 = 0;
    switch (in.hover) {
        .plus => {
            hx = in.layout.plus_x;
            hw = in.layout.plus_w;
        },
        .close => {
            hx = in.layout.close_x;
            hw = in.layout.close_w;
        },
        .more => {
            hx = in.layout.more_x;
            hw = in.layout.more_w;
        },
        .left_arrow => if (in.layout.arrows_visible and in.layout.left_enabled) {
            hx = in.layout.left_arrow_x;
            hw = in.layout.arrow_w;
        },
        .right_arrow => if (in.layout.arrows_visible and in.layout.right_enabled) {
            hx = in.layout.right_arrow_x;
            hw = in.layout.arrow_w;
        },
        .tab_area, .none => {},
    }
    if (hw > in.hover_inset * 2.0) {
        push(out, n, .{
            .x = hx + in.hover_inset,
            .y = in.hover_inset,
            .w = hw - in.hover_inset * 2.0,
            .h = in.tab_bar_h - in.hover_inset * 2.0,
            .color = in.palette.ctrl_hover_bg,
        });
    }
}

fn pushControlBg(out: []Rect, n: *usize, in: Inputs, x: f32, w: f32) void {
    if (w <= 0) return;
    push(out, n, .{
        .x = x,
        .y = 0,
        .w = w,
        .h = in.tab_bar_h,
        .color = in.palette.tab_bar_bg,
    });
}

// --- tests ---

const testing = std.testing;

fn testInputs(palette: *const chrome_palette.Palette) Inputs {
    return .{
        .viewport_w = 960,
        .tab_bar_h = 28,
        .tab_w = 150,
        .sep_w = 1,
        .underline_h = 2,
        .hover_inset = 2,
        .tab_count = 3,
        .active_idx = 0,
        .scroll_x = 0,
        .drag = null,
        .layout = .{
            .tab_area_x = 0,
            .tab_area_w = 840,
            .arrows_visible = false,
            .arrow_w = 24,
            .plus_w = 24,
            .plus_x = 864,
            .close_w = 24,
            .close_x = 912,
            .more_w = 24,
            .more_x = 888,
        },
        .hover = .none,
        .palette = palette,
    };
}

test "build — 배경이 첫 rect, 밑줄이 제목 앞 구간에 든다" {
    const p = chrome_palette.derive(.{ 0, 0, 0 }, true);
    var buf: [32]Rect = undefined;
    const c = build(&buf, testInputs(&p));

    try testing.expectEqual(@as(f32, 0), c.rects[0].x);
    try testing.expectEqual(@as(f32, 960), c.rects[0].w);
    try testing.expectEqual(@as(f32, 28), c.rects[0].h);
    // 배경 + 밑줄 = 제목 앞 구간.
    try testing.expectEqual(@as(usize, 2), c.before_titles);
    // 밑줄은 탭바 맨 아래.
    try testing.expectEqual(@as(f32, 26), c.rects[1].y);
    try testing.expectEqual(@as(f32, 2), c.rects[1].h);
    try testing.expectEqual(ui_metrics.TAB_ACCENT_COLOR, c.rects[1].color);
}

test "build — 컨트롤 fill → hover → 구분선 순서" {
    const p = chrome_palette.derive(.{ 0, 0, 0 }, true);
    var in = testInputs(&p);
    in.hover = .plus;
    var buf: [32]Rect = undefined;
    const c = build(&buf, in);

    const tail = c.rects[c.before_titles..];
    // fill 3개 (화살표 없음: close · plus · more) → hover 1개 → 구분선.
    try testing.expectEqual(p.tab_bar_bg, tail[0].color);
    try testing.expectEqual(p.tab_bar_bg, tail[1].color);
    try testing.expectEqual(p.tab_bar_bg, tail[2].color);
    try testing.expectEqual(p.ctrl_hover_bg, tail[3].color);
    try testing.expectEqual(p.separator, tail[4].color);
    // hover 는 네 방향 inset.
    try testing.expectEqual(@as(f32, 866), tail[3].x);
    try testing.expectEqual(@as(f32, 20), tail[3].w);
    try testing.expectEqual(@as(f32, 24), tail[3].h);
}

test "build — 밑줄이 tab_area 오른쪽 경계에서 잘린다" {
    const p = chrome_palette.derive(.{ 0, 0, 0 }, true);
    var in = testInputs(&p);
    in.tab_count = 8;
    in.active_idx = 5;
    in.scroll_x = 24; // 활성 슬롯 750..900, tab_area_end = 840
    var buf: [32]Rect = undefined;
    const c = build(&buf, in);

    const u = c.rects[1];
    try testing.expect(u.x + u.w <= 840);
}

test "build — 버퍼가 모자라면 넘치지 않는다" {
    const p = chrome_palette.derive(.{ 0, 0, 0 }, true);
    var in = testInputs(&p);
    in.tab_count = 8;
    var buf: [3]Rect = undefined;
    const c = build(&buf, in);
    try testing.expectEqual(@as(usize, 3), c.rects.len);
}

test "snap — 양 끝을 각각 반올림한다 (아랫변 보존)" {
    // 0.4 에서 시작해 높이 10.2 → 아랫변 10.6. 각각 반올림하면 0..11 = 11.
    // 위치·크기를 따로 절단하면 0 + 10 = 10 으로 아랫변이 모자란다 (#344).
    const r = Rect{ .x = 0, .y = 0.4, .w = 5, .h = 10.2, .color = .{ 0, 0, 0, 1 } };
    const i = snap(r);
    try testing.expectEqual(@as(i32, 0), i.y);
    try testing.expectEqual(@as(i32, 11), i.h);
}

test "snap — 폭 0 이어도 최소 1px" {
    const r = Rect{ .x = 3.2, .y = 0, .w = 0.1, .h = 0.1, .color = .{ 0, 0, 0, 1 } };
    const i = snap(r);
    try testing.expectEqual(@as(i32, 1), i.w);
    try testing.expectEqual(@as(i32, 1), i.h);
}

test "#343 이전 Linux 정수 식과 결과가 같다 — sep 1px (scale 1.0)" {
    // 통합 전 Linux 는 모든 좌표를 i32 로 계산했고, 세로 구분선이 슬롯 안으로
    // 들어오는 양이 왼쪽 `w − divTrunc(w,2)` / 오른쪽 `divTrunc(w,2)` 로 **홀수
    // 두께에서 비대칭** 이었다 (w=1 이면 좌 1 / 우 0). 지금은 좌우 `w/2` 대칭 +
    // `snap` 이다. 아래는 그 두 규칙의 결과가 같은지 고정한다.
    const p = chrome_palette.derive(.{ 0, 0, 0 }, true);
    var in = testInputs(&p);
    in.active_idx = 1;
    var buf: [32]Rect = undefined;
    const c = build(&buf, in);

    // 탭바 배경 — 이전 `rect(0, 0, fb_w, tab_bar_h)`.
    try testing.expectEqual(IRect{ .x = 0, .y = 0, .w = 960, .h = 28 }, snap(c.rects[0]));
    // 밑줄 — 이전 `u_x = tab_screen_x + (sep_w − divTrunc(sep_w,2)) = 150 + 1`,
    // `u_w = tab_w − cut_l − cut_r = 150 − 1 − 0 = 149`, `y = 28 − 2`.
    try testing.expectEqual(IRect{ .x = 151, .y = 26, .w = 149, .h = 2 }, snap(c.rects[1]));

    // 세로 구분선 — 이전 `x = 경계 − divTrunc(sep_w,2)`, 폭 `sep_w`.
    const tail = c.rects[c.before_titles..];
    var seps: [8]IRect = undefined;
    var sn: usize = 0;
    for (tail) |r| {
        if (std.meta.eql(r.color, p.separator)) {
            seps[sn] = snap(r);
            sn += 1;
        }
    }
    // 화살표가 없고 scroll 0 이면 첫 탭 왼쪽 경계(bi=0)에는 선이 없다 —
    // 창 가장자리와 겹치기 때문 (`tab_layout.hasSeparator` 규칙). 1..3 만.
    try testing.expectEqual(@as(usize, 3), sn);
    try testing.expectEqual(IRect{ .x = 150, .y = 0, .w = 1, .h = 28 }, seps[0]);
    try testing.expectEqual(IRect{ .x = 300, .y = 0, .w = 1, .h = 28 }, seps[1]);
    try testing.expectEqual(IRect{ .x = 450, .y = 0, .w = 1, .h = 28 }, seps[2]);
}

test "#343 이전 Linux 정수 식과 결과가 같다 — sep 2px (scale 1.7 상당)" {
    // 이전: `cut_l = 2 − divTrunc(2,2) = 1`, `cut_r = divTrunc(2,2) = 1`,
    // 세로선 `x = 경계 − 1`, 폭 2. 지금: 좌우 `1.0` 대칭 + snap → 같아야 한다.
    const p = chrome_palette.derive(.{ 0, 0, 0 }, true);
    var in = testInputs(&p);
    in.tab_w = 255;
    in.sep_w = 2;
    in.underline_h = 3;
    in.tab_bar_h = 48;
    in.active_idx = 1;
    var buf: [32]Rect = undefined;
    const c = build(&buf, in);

    try testing.expectEqual(IRect{ .x = 256, .y = 45, .w = 253, .h = 3 }, snap(c.rects[1]));

    const tail = c.rects[c.before_titles..];
    for (tail) |r| {
        if (!std.meta.eql(r.color, p.separator)) continue;
        const s = snap(r);
        try testing.expectEqual(@as(i32, 2), s.w);
        try testing.expectEqual(@as(i32, 48), s.h);
        // 경계는 255 의 배수 — 중심 정렬이라 시작이 `경계 − 1`.
        try testing.expectEqual(@as(i32, 0), @mod(s.x + 1, 255));
        break;
    }
}

test "#343 이전 Linux 정수 식과 결과가 같다 — 컨트롤 fill / hover" {
    // 이전 Linux: fill `x = trunc(layout.x)`, `w = trunc(layout.w)`, 높이 탭바 전체.
    // hover `x = trunc(hx) + inset`, `y = inset`, `w = trunc(hw) − 2·inset`,
    // `h = max(tab_bar_h − 2·inset, 1)`.
    const p = chrome_palette.derive(.{ 0, 0, 0 }, true);
    var in = testInputs(&p);
    in.hover = .close;
    var buf: [32]Rect = undefined;
    const c = build(&buf, in);
    const tail = c.rects[c.before_titles..];

    try testing.expectEqual(IRect{ .x = 912, .y = 0, .w = 24, .h = 28 }, snap(tail[0])); // close
    try testing.expectEqual(IRect{ .x = 864, .y = 0, .w = 24, .h = 28 }, snap(tail[1])); // plus
    try testing.expectEqual(IRect{ .x = 888, .y = 0, .w = 24, .h = 28 }, snap(tail[2])); // more
    try testing.expectEqual(IRect{ .x = 914, .y = 2, .w = 20, .h = 24 }, snap(tail[3])); // hover
}

test "buildControlsOnly — 단일 탭 overlay 는 컨트롤 rect 만" {
    const p = chrome_palette.derive(.{ 0, 0, 0 }, true);
    var in = testInputs(&p);
    in.hover = .more;
    var buf: [8]Rect = undefined;
    const rects = buildControlsOnly(&buf, in);
    // fill 3 + hover 1. 탭바 배경 · 밑줄 · 구분선은 없다.
    try testing.expectEqual(@as(usize, 4), rects.len);
    for (rects[0..3]) |r| try testing.expectEqual(p.tab_bar_bg, r.color);
    try testing.expectEqual(p.ctrl_hover_bg, rects[3].color);
}

test "tabClip — drag 중에는 우측 밖에서도 stop 하지 않는다" {
    try testing.expectEqual(ClipDecision.skip, tabClip(-200, 150, 0, 840, false));
    try testing.expectEqual(ClipDecision.draw, tabClip(-10, 150, 0, 840, false));
    try testing.expectEqual(ClipDecision.stop, tabClip(900, 150, 0, 840, false));
    try testing.expectEqual(ClipDecision.skip, tabClip(900, 150, 0, 840, true));
}
