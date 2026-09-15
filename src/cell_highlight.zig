//! 셀 범위 강조 (`RenderState.Row.highlights`) 의 **공용 계약** — tag 배분 · 지우기 ·
//! 조회. 검색 매치 (#646) 와 링크 hover (#647) 처럼 서로 다른 기능이 *같은 행의 같은
//! 목록*에 강조를 넣으므로, 규칙을 한 곳에 두지 않으면 서로의 것을 지우거나 자기 색으로
//! 그린다 (2026-09-11 세션 간 합의).
//!
//! `RenderState` 에게 `tag` 는 불투명한 `u8` 이다 — ghostty 는 그대로 돌려줄 뿐 의미를
//! 모른다. 그래서 의미는 전부 이 파일이 정한다.

const std = @import("std");
const ghostty = @import("ghostty-vt");

/// 강조 종류. **값이 곧 우선순위다 — 작을수록 위에 그린다.**
///
/// 우선순위를 *삽입 순서* 가 아니라 값으로 정하는 이유는, 두 기능이 각자 다른 프레임에
/// 자기 강조를 다시 칠해서 목록 안 순서가 프레임마다 달라지기 때문이다. 값으로 정하면
/// 누가 먼저 칠하든 화면이 같다.
///
/// (`updateHighlightsFlattened` 자체는 "먼저 넣은 것이 앞" 이라는 성질이 있지만, 그것에
/// 기대지 않는다.)
pub const Tag = enum(u8) {
    /// 마우스가 올라가 있는 링크 — [#647](https://github.com/ensky0/tildaz/issues/647).
    ///
    /// 검색 매치보다 위다. hover 는 *지금 포인터가 가리키는 자리* 에 대한 즉각 피드백이고
    /// 검색 매치는 정적인 표시라, 겹치면 움직이는 쪽이 보여야 한다.
    link_hover = 0,

    /// 지금 선택된 검색 매치 — [#646](https://github.com/ensky0/tildaz/issues/646).
    search_current = 1,

    /// 찾았지만 선택되지 않은 검색 매치.
    search_match = 2,

    pub fn value(self: Tag) u8 {
        return @intFromEnum(self);
    }
};

/// `tags` 에 든 종류의 강조만 모든 행에서 지운다. 다른 기능의 강조는 남긴다.
///
/// **`RenderState` 에는 강조를 지우는 API 가 없다.** `update` 는 *바뀐 행* 의 것만
///리셋하고 (`render.zig` 의 "dirty row resets highlights") 안 바뀐 행은 그대로 두므로,
/// 다시 칠하기 전에 직접 지우지 않으면 같은 행에 계속 쌓인다.
///
/// 행 전체를 비우지 않고 tag 로 거르는 이유가 이 함수의 존재 이유다 — 행 단위
/// `clearRetainingCapacity()` 는 그 행에 있는 *다른 기능* 의 강조까지 지운다.
///
/// 지운 행은 dirty 로 표시한다. 하나라도 지웠으면 `true` 를 돌려준다.
pub fn clear(state: *ghostty.RenderState, tags: []const Tag) bool {
    const row_data = state.row_data.slice();
    var any = false;
    for (row_data.items(.highlights), row_data.items(.dirty)) |*hls, *dirty| {
        if (hls.items.len == 0) continue;

        // 남길 것만 앞으로 당긴다. 순서를 그대로 두는 이유는 우선순위 때문이 아니라
        // (그건 tag 값이 정한다) 불필요한 재정렬을 만들지 않기 위해서다.
        var w: usize = 0;
        for (hls.items) |h| {
            if (contains(tags, h.tag)) continue;
            hls.items[w] = h;
            w += 1;
        }
        if (w == hls.items.len) continue;

        hls.shrinkRetainingCapacity(w);
        dirty.* = true;
        any = true;
    }
    if (any and state.dirty == .false) state.dirty = .partial;
    return any;
}

fn contains(tags: []const Tag, raw: u8) bool {
    for (tags) |t| if (t.value() == raw) return true;
    return false;
}

/// viewport 행 `y` 의 `[x0, x1]` (양끝 포함) 에 강조를 더한다.
///
/// **`updateHighlightsFlattened` 를 쓰지 않는 경우를 위한 것이다.** 검색은 ghostty 가 돌려준
/// `highlight.Flattened` 를 그대로 넘기면 되지만 ([#646](https://github.com/ensky0/tildaz/issues/646)),
/// 링크 hover ([#647](https://github.com/ensky0/tildaz/issues/647)) 는 판정 결과가 이미 **viewport
/// 좌표**라 `Flattened` (page node · serial · chunk) 로 되돌렸다가 다시 행·열로 풀 이유가 없다.
///
/// 지운 뒤 다시 칠하는 쪽이 호출자 책임인 것은 `clear` 와 같다 — `RenderState` 는 강조를 스스로
/// 지우지 않는다 (바뀐 행의 것만 리셋한다).
///
/// ⚠️ **강조는 행의 arena 로 할당한다 — general allocator 를 쓰면 샌다.**
/// `RenderState.deinit` 은 `arena` · `cells` · `applied_styles` 만 해제하고 **`highlights` 는
/// 해제하지 않는다** (`render.zig`). 행의 arena 가 그 몫을 맡기 때문이고, upstream 의
/// `updateHighlightsFlattened` 도 같은 자리에서 `row_arena.promote(alloc)` 으로 arena 를 꺼내
/// 쓴다. `alloc` 은 그 arena 를 promote 하는 데만 쓰인다.
pub fn add(
    state: *ghostty.RenderState,
    alloc: std.mem.Allocator,
    tag: Tag,
    y: u16,
    x0: u16,
    x1: u16,
) std.mem.Allocator.Error!void {
    const row_data = state.row_data.slice();
    if (y >= row_data.len) return;

    const row_arena = &row_data.items(.arena)[y];
    var arena = row_arena.promote(alloc);
    defer row_arena.* = arena.state;

    try row_data.items(.highlights)[y].append(arena.allocator(), .{
        .tag = tag.value(),
        .range = .{ x0, x1 },
    });
    row_data.items(.dirty)[y] = true;
    if (state.dirty == .false) state.dirty = .partial;
}

/// 링크 hover 는 **색이 아니라 밑줄**로 표시한다. 그 칸이 링크면 밑줄을 켠 style 을 준다.
///
/// `cell_color.highlightColors` 가 `.link_hover => null` 인 이유가 이것이다 — 셀 색을 바꾸지
/// 않고 SGR 밑줄과 **같은 선**을 하나 켠다. 그러면 두께 · 위치 · 색이 `cell_decoration` 의
/// 기존 계산을 그대로 타서 폰트 · 배율이 달라져도 따로 맞출 것이 없다. 밑줄인 것은 웹과 터미널
/// 양쪽의 관례이고 ghostty 도 같다.
///
/// **이미 밑줄이 있으면 그대로 둔다.** `.double` · `.curly` 를 `.single` 로 덮으면 원래 내용의
/// 뜻 (SGR 4:3 등) 이 사라지는데, 링크 표시로는 어느 밑줄이든 충분하다.
pub fn withLinkUnderline(
    style: ghostty.Style,
    hls: []const ghostty.RenderState.Highlight,
    x: u16,
) ghostty.Style {
    if (at(hls, x) != .link_hover) return style;
    if (style.flags.underline != .none) return style;
    var out = style;
    out.flags.underline = .single;
    return out;
}

/// 열 `x` 를 덮는 강조 중 **우선순위가 가장 높은 것** (= tag 값이 가장 작은 것).
/// 없으면 `null`.
///
/// renderer 가 셀마다 부른다. 한 행의 강조 개수는 보통 한 자리라 선형 탐색으로 충분하다.
/// 알 수 없는 tag (다른 기능이 우리보다 새 값을 쓰는 경우) 는 무시한다 — 모르는 색으로
/// 그리는 것보다 안 그리는 쪽이 안전하다.
pub fn at(hls: []const ghostty.RenderState.Highlight, x: u16) ?Tag {
    var best: ?Tag = null;
    for (hls) |h| {
        if (x < h.range[0] or x > h.range[1]) continue;
        // `Tag` 에 항목이 늘면 이 루프가 자동으로 따라온다 (정수 switch 로 적으면
        // 새 값을 조용히 빠뜨린다).
        const tag = blk: {
            inline for (comptime std.enums.values(Tag)) |t| {
                if (t.value() == h.tag) break :blk t;
            }
            continue;
        };
        if (best == null or tag.value() < best.?.value()) best = tag;
    }
    return best;
}

test "#646 at — 열 범위 밖은 없음, 안은 해당 tag" {
    const hls = [_]ghostty.RenderState.Highlight{
        .{ .tag = Tag.search_match.value(), .range = .{ 3, 7 } },
    };
    try std.testing.expect(at(&hls, 2) == null);
    try std.testing.expectEqual(Tag.search_match, at(&hls, 3).?);
    try std.testing.expectEqual(Tag.search_match, at(&hls, 7).?);
    try std.testing.expect(at(&hls, 8) == null);
}

test "#646 at — 겹치면 tag 값이 작은 쪽이 이긴다 (삽입 순서 무관)" {
    // 검색 매치가 먼저 들어가고 링크 hover 가 나중에 들어간 경우.
    const a = [_]ghostty.RenderState.Highlight{
        .{ .tag = Tag.search_match.value(), .range = .{ 0, 9 } },
        .{ .tag = Tag.link_hover.value(), .range = .{ 2, 5 } },
    };
    try std.testing.expectEqual(Tag.link_hover, at(&a, 3).?);
    try std.testing.expectEqual(Tag.search_match, at(&a, 7).?);

    // 반대 순서로 들어가도 결과가 같아야 한다 — 이 성질이 이 설계의 목적이다.
    const b = [_]ghostty.RenderState.Highlight{
        .{ .tag = Tag.link_hover.value(), .range = .{ 2, 5 } },
        .{ .tag = Tag.search_match.value(), .range = .{ 0, 9 } },
    };
    try std.testing.expectEqual(Tag.link_hover, at(&b, 3).?);
    try std.testing.expectEqual(Tag.search_match, at(&b, 7).?);
}

test "#646 at — 현재 매치가 일반 매치를 이긴다" {
    const hls = [_]ghostty.RenderState.Highlight{
        .{ .tag = Tag.search_match.value(), .range = .{ 0, 9 } },
        .{ .tag = Tag.search_current.value(), .range = .{ 4, 6 } },
    };
    try std.testing.expectEqual(Tag.search_current, at(&hls, 5).?);
    try std.testing.expectEqual(Tag.search_match, at(&hls, 1).?);
}

test "#646 at — 모르는 tag 는 무시한다" {
    const hls = [_]ghostty.RenderState.Highlight{
        .{ .tag = 200, .range = .{ 0, 9 } },
    };
    try std.testing.expect(at(&hls, 5) == null);
}
