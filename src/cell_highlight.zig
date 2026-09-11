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
