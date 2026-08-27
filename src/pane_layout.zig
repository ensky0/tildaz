//! #483 — 화면 분할 (split pane) 의 트리 · 기하 · hit-test · 이웃 탐색. cross-platform
//! pure functions — `tab_layout.zig` 와 같은 규약이다: state 도 인자로 받고 결과를
//! 반환하며 side effect 가 없다. 할당도 없다 (고정 pool). ghostty 에 의존하지 않아
//! `zig test src/pane_layout.zig` 로 단독 실행된다.
//!
//! **1단계 — 기능 변화 0.** 아직 어느 host 도 이 모듈을 부르지 않는다. 확정 설계와
//! 세 결정 (상한 · 남는 픽셀 · 분할선) 은 이슈에 있다.
//! - 확정 설계: https://github.com/ensky0/tildaz/issues/483#issuecomment-5328315617
//! - 결정 셋:   https://github.com/ensky0/tildaz/issues/483#issuecomment-5422686367
//!
//! **용어.** *pane* = 터미널 하나 (`session_core.Tab` 이 그 실체다). 이 모듈은 pane 을
//! 불투명 id (`PaneId`) 로만 다루고 `*Tab` 을 모른다 — host 가 id ↔ `*Tab` 을 잇는다.
//! 축 이름은 결과로 붙였다 — `.side_by_side` (좌우 나열) / `.stacked` (위아래) —
//! `vertical` 이 터미널마다 반대로 읽히는 모호성을 코드 이름에서 없앤다.
//!
//! **단위.** 모두 physical px 의 `i32`. host 의 `i32` (Linux) / `c_int` (Windows) 는 그대로,
//! `u32` (macOS) 는 cast 해서 넘긴다. leaf 하나의 격자는 `ui_metrics.terminalCols/Rows` 를
//! 그대로 부르므로 **pane 하나의 격자는 지금 단일 창과 같다** (아래 첫 테스트가 고정한다).
//!
//! **남는 픽셀 (결정 2).** 격자가 내림이라 pane 안에 `0 ~ cell−1` px 이 남는다. 분할선은
//! *앞 자식을 leaf 로 본 셀 경계* 중 비율 지점에 가장 가까운 곳에 놓고 나머지를 뒤 자식에
//! 준다 (iTerm2 방식). 그러면 앞 pane 은 남는 px 이 0 이고, 창 전체의 남는 px 은 뒤 pane
//! 의 오른쪽 · 아래 — 지금 단일 창에서 남는 px 이 놓이는 자리 — 에 모인다. 앞 자식이
//! 같은 축으로 다시 나뉜 subtree 면 그 안쪽 leaf 는 자기 rect 에서 내림한다.
//!
//! **분할선 (결정 3).** 격자에 들어가는 것은 회색 띠 `Metrics.separator_w` 하나다 (host 가
//! `ui_metrics.PANE_SEPARATOR_W_PT` 를 `linePx` 로 바꿔 넘긴다). 활성 pane 을 알리는 amber
//! 선은 그 pane 의 padding 안에 그리므로 이 모듈의 기하에 나타나지 않는다.

const std = @import("std");
const ui_metrics = @import("ui_metrics.zig");

/// 결정 1 — 탭당 pane 상한. `session_core.MAX_TABS` (탭바의 탭 수) 와 독립이다. 실제로는
/// 최소 pane 크기 때문에 공간이 먼저 모자라서 여기까지 가는 일이 드물고, 이 값은 고정
/// pool 의 크기를 정한다.
pub const MAX_PANES_PER_TAB: usize = 16;
/// 이진 트리라 leaf 가 n 이면 노드는 2n−1.
pub const MAX_NODES: usize = 2 * MAX_PANES_PER_TAB - 1;
/// 확정 설계 축 2 — 이 아래로는 `split` · `resize` 를 거부한다. 드롭다운은
/// `height_percent` 기본값에서 상하로 나누면 한 자릿수 행이 나오므로 필요한 하한이다.
pub const MIN_PANE_COLS: u16 = 20;
pub const MIN_PANE_ROWS: u16 = 5;

/// host 가 정하는 불투명 id. 한 트리 안에서 유일하면 된다.
pub const PaneId = u32;

pub const Axis = enum {
    /// 좌우로 나란히 — 분할선이 세로다.
    side_by_side,
    /// 위아래로 쌓임 — 분할선이 가로다.
    stacked,
};

pub const Direction = enum {
    left,
    right,
    up,
    down,

    pub fn axis(self: Direction) Axis {
        return switch (self) {
            .left, .right => .side_by_side,
            .up, .down => .stacked,
        };
    }

    /// 분할 노드의 `second` 자식이 있는 쪽인가 (오른쪽 · 아래).
    pub fn towardSecond(self: Direction) bool {
        return switch (self) {
            .right, .down => true,
            .left, .up => false,
        };
    }
};

/// physical px 사각형. `[x, x+w) × [y, y+h)` half-open.
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// 격자 계산 입력 — 모두 physical px. `pad` 와 `scrollbar_w` 는 지금 host 가
/// `terminalCols/Rows` 에 넘기는 값 그대로다.
pub const Metrics = struct {
    cell_w: i32,
    cell_h: i32,
    pad: i32,
    scrollbar_w: i32,
    /// 회색 분할선 두께 (`ui_metrics.PANE_SEPARATOR_W_PT` 의 px).
    separator_w: i32,
};

pub const Cell = struct {
    col: u16,
    row: u16,
};

/// `layout` 의 결과 — pane 하나의 px 영역과 격자.
pub const PaneRect = struct {
    pane: PaneId,
    /// pane 전체 (padding · scrollbar 자리 포함). 이웃 pane 과는 분할선 폭만큼 떨어진다.
    rect: Rect,
    cols: u16,
    rows: u16,
    /// 첫 셀의 좌상 px — `rect.x + pad`, `rect.y + pad`. 지금 host 의 `pad` / `tab_bar_h + pad`
    /// 와 같은 자리다.
    grid_x: i32,
    grid_y: i32,
};

/// 회색 분할선 하나. `axis` 가 `.side_by_side` 면 세로 선이다.
pub const Separator = struct {
    rect: Rect,
    axis: Axis,
    /// 이 분할선을 가진 분할 노드 — `Tree.setSeparatorPx` 의 인자 (4c 드래그). 트리 내부 index 라
    /// 트리가 바뀌면 (분할 · 닫기) 무효다 — 드래그 한 번 안에서만 쓴다.
    node: u8,
};

const NodeIndex = u8;
const NO_NODE: NodeIndex = std.math.maxInt(NodeIndex);

const Split = struct {
    axis: Axis,
    /// `first` 자식이 차지하는 비율 (분할선을 뺀 길이 기준). 셀 수는 매번 유도한다 —
    /// 창 크기 · 배율이 바뀌어도 비율이 유지되고 셀 경계 정렬은 유도 단계에서 다시 잡힌다.
    ratio: f32,
    first: NodeIndex,
    second: NodeIndex,
};

const Node = union(enum) {
    leaf: PaneId,
    split: Split,
};

/// 탭 하나의 분할 트리. 값 타입이다 — 복사가 싸서 (`MAX_NODES` 개 노드) 실패 시 되돌리기는
/// 통째로 복사해 둔 것을 다시 넣는 식으로 한다.
pub const Tree = struct {
    nodes: [MAX_NODES]Node = undefined,
    parent: [MAX_NODES]NodeIndex = [_]NodeIndex{NO_NODE} ** MAX_NODES,
    alive: [MAX_NODES]bool = [_]bool{false} ** MAX_NODES,
    root: NodeIndex = NO_NODE,
    pane_count: u8 = 0,

    pub const SplitError = error{ TooManyPanes, TooSmall, UnknownPane, DuplicatePane };
    pub const CloseError = error{ LastPane, UnknownPane };

    /// pane 하나짜리 트리 — 지금 탭의 상태.
    pub fn single(pane: PaneId) Tree {
        var t: Tree = .{};
        t.nodes[0] = .{ .leaf = pane };
        t.alive[0] = true;
        t.root = 0;
        t.pane_count = 1;
        return t;
    }

    pub fn count(self: *const Tree) usize {
        return self.pane_count;
    }

    pub fn contains(self: *const Tree, pane: PaneId) bool {
        return self.findLeaf(pane) != null;
    }

    /// `target` 을 `dir` 쪽으로 갈라 새 pane `new_pane` 을 그쪽에 놓는다 (비율 반씩).
    /// 갈라진 **두 조각** 이 `MIN_PANE_COLS × MIN_PANE_ROWS` 아래면 트리를 바꾸지 않고 `TooSmall` —
    /// 다른 pane 은 보지 않는다. 창이 줄어 (drop-down 이 작은 모니터로 가면 비율은 그대로) 이미 최소
    /// 아래인 pane 이 있어도, 자리가 있는 pane 은 갈라져야 한다 (2026-08-27 macOS 실기 — 예전엔 탭
    /// 전체를 검사해 A 를 위아래로 가르는데 옆의 B · C 가 17 열이라 거부됐다). 개수 상한은
    /// `TooManyPanes` — host 가 두 거부를 다른 문구로 안내할 수 있게 구분한다. `rect` 는 **탭바를 뺀**
    /// 터미널 영역이다.
    pub fn split(self: *Tree, target: PaneId, dir: Direction, new_pane: PaneId, rect: Rect, m: Metrics) SplitError!void {
        if (self.pane_count >= MAX_PANES_PER_TAB) return error.TooManyPanes;
        if (self.contains(new_pane)) return error.DuplicatePane;
        const at = self.findLeaf(target) orelse return error.UnknownPane;
        const saved = self.*;

        // leaf 자리를 그대로 분할 노드로 바꾼다 — 부모의 자식 index 가 그대로 맞는다.
        const old_leaf = self.allocNode();
        const new_leaf = self.allocNode();
        self.nodes[old_leaf] = .{ .leaf = target };
        self.nodes[new_leaf] = .{ .leaf = new_pane };
        self.parent[old_leaf] = at;
        self.parent[new_leaf] = at;
        const new_is_second = dir.towardSecond();
        self.nodes[at] = .{ .split = .{
            .axis = dir.axis(),
            .ratio = 0.5,
            .first = if (new_is_second) old_leaf else new_leaf,
            .second = if (new_is_second) new_leaf else old_leaf,
        } };
        self.pane_count += 1;

        var buf: [MAX_PANES_PER_TAB]PaneRect = undefined;
        for (layout(self, rect, m, &buf)) |pr| {
            if (pr.pane != target and pr.pane != new_pane) continue;
            if (pr.cols < MIN_PANE_COLS or pr.rows < MIN_PANE_ROWS) {
                self.* = saved;
                return error.TooSmall;
            }
        }
    }

    /// pane 을 트리에서 뺀다 — 형제가 부모 자리로 올라간다. 반환값은 **포커스를 넘길 pane**:
    /// 형제 subtree 에서 닫힌 pane 과 맞닿아 있던 가장자리의 첫 leaf (같은 축의 분할에서는
    /// 닫힌 쪽 자식을, 다른 축에서는 `first` 를 따라 내려간다). 마지막 pane 은 이 모듈이
    /// 닫지 않는다 (`LastPane`) — host 가 탭을 닫는다 (확정 설계: `Ctrl+Shift+W` 의미 확장).
    pub fn close(self: *Tree, pane: PaneId) CloseError!PaneId {
        if (self.pane_count <= 1) return error.LastPane;
        const at = self.findLeaf(pane) orelse return error.UnknownPane;
        const parent_idx = self.parent[at];
        std.debug.assert(parent_idx != NO_NODE); // pane 이 둘 이상이면 leaf 는 root 가 아니다
        const sp = self.nodes[parent_idx].split;
        const closed_is_first = sp.first == at;
        const sibling = if (closed_is_first) sp.second else sp.first;
        const successor = self.edgeLeaf(sibling, sp.axis, closed_is_first);

        // 형제를 부모 자리로 — index 를 유지하고 내용을 옮긴다. 형제가 분할 노드면 그 자식들의
        // 부모 index 를 고쳐 준다.
        self.nodes[parent_idx] = self.nodes[sibling];
        switch (self.nodes[parent_idx]) {
            .split => |s| {
                self.parent[s.first] = parent_idx;
                self.parent[s.second] = parent_idx;
            },
            .leaf => {},
        }
        self.alive[sibling] = false;
        self.alive[at] = false;
        self.parent[sibling] = NO_NODE;
        self.parent[at] = NO_NODE;
        self.pane_count -= 1;
        return successor;
    }

    /// 분할선을 `dir` 방향으로 `cells` 셀 옮긴다. **어느 분할선인가** — pane 의 `dir` 쪽 변이
    /// 분할선이면 그것 (pane 이 그쪽으로 자란다), 그 변이 창 가장자리면 반대쪽 변의 분할선
    /// (pane 이 그쪽으로 줄어든다). 어느 쪽이든 "그 방향으로 옮긴다" 는 뜻은 같다.
    /// 옮길 분할선이 없거나 (그 축의 분할이 없다), 옮긴 뒤 `MIN` 아래로 내려가는 pane 이
    /// 생기면 false 를 돌려주고 트리는 그대로다.
    pub fn resize(self: *Tree, pane: PaneId, dir: Direction, cells: i32, rect: Rect, m: Metrics) bool {
        const at = self.findLeaf(pane) orelse return false;
        const axis = dir.axis();
        const split_idx = self.ancestorSplit(at, axis, dir.towardSecond()) orelse
            self.ancestorSplit(at, axis, !dir.towardSecond()) orelse return false;
        const node_rect = self.rectOf(rect, m, split_idx) orelse return false;
        const sp = self.nodes[split_idx].split;
        const g = splitGeometry(node_rect, m, sp);
        if (g.avail <= 0) return false;

        const along = axis == .side_by_side;
        const cell = if (along) m.cell_w else m.cell_h;
        const step = cells * cell;
        const origin = if (along) node_rect.x else node_rect.y;
        // 드래그와 같은 경로 — clamp 와 "붙은 칸만" 규칙을 함께 얻는다.
        return self.setSeparatorPx(split_idx, origin + g.first_px + (if (dir.towardSecond()) step else -step), rect, m);
    }

    /// 분할 노드 `node` (`Separator.node`) 의 분할선을 분할 축 좌표 `px` 에 놓는다 — 드래그 (4c) 와 키 1셀
    /// 조절 (`resize`) 이 같은 경로다. 2026-08-27 사용자 결정 둘:
    ///
    /// - **clamp** — 최소 크기 (`MIN_PANE_*`) 에 닿으면 거부하지 않고 **그 한계에서 멈춘다** (tmux · Windows
    ///   Terminal 방식). 예전엔 어느 pane 이라도 최소 아래로 가면 드래그 전체를 거부해 (고스트도 안 그려져)
    ///   "끌다가 취소됨" 으로 보였다.
    /// - **선에 붙은 칸만 변한다** — 선 너머 subtree 가 같은 축으로 또 갈려 있으면, 예전엔 비율이 그대로라
    ///   안쪽 분할선까지 비례해 밀렸다. 이제 안쪽 같은-축 분할의 비율을 다시 놓아 **먼 칸은 px 그대로**, 선에
    ///   붙은 칸이 변화를 흡수한다 (`keepFarFixed`). 다른 축의 분할 (위아래로 쌓인 칸) 은 둘 다 선의 이웃이라
    ///   같이 변하는 것이 맞다. 한계도 같은 규칙으로 잰다 (`minExtentKeepFar` — 먼 칸은 지금 크기 그대로).
    ///
    /// 셀 경계 스냅은 `splitGeometry` 가 하므로 드래그 중 고스트와 놓은 결과가 같은 자리다. 바뀐 것이 없으면
    /// (이미 한계 · 같은 셀) false.
    ///
    /// 창이 줄어 **이미 최소 아래인 pane** 이 있으면 (drop-down 이 작은 모니터로 옮겨 가도 비율은 그대로다):
    /// 그 pane 의 한계는 지금 크기라 더 줄지는 않되 **키울 수는 있고**, 뒤의 검사도 "새로 최소 아래로 떨어지는
    /// pane 이 없다" (`noPaneNewlyBelowMin`) 다 — 탭 전체 ≥ 최소를 요구하면 작아진 pane 을 키우는 것까지 막힌다
    /// (2026-08-27 macOS 실기에서 `⇧⌘←` 가 아무 반응 없던 원인).
    pub fn setSeparatorPx(self: *Tree, node: u8, px: i32, rect: Rect, m: Metrics) bool {
        if (node >= MAX_NODES or !self.alive[node]) return false;
        if (self.nodes[node] != .split) return false;
        const node_rect = self.rectOf(rect, m, node) orelse return false;
        const sp = self.nodes[node].split;
        const g = splitGeometry(node_rect, m, sp);
        if (g.avail <= 0) return false;
        const c = childRects(node_rect, sp, g);
        const along = sp.axis == .side_by_side;
        const origin = if (along) node_rect.x else node_rect.y;
        const cell = if (along) m.cell_w else m.cell_h;
        // 한계 — 선에 붙은 칸들만 줄어드니 먼 칸은 지금 크기 그대로 두고 셈.
        const min_first = self.minExtentKeepFar(sp.first, sp.axis, m, c.first, .second);
        const min_second = self.minExtentKeepFar(sp.second, sp.axis, m, c.second, .first);
        const max_first = g.avail - min_second;
        if (min_first > max_first) return false; // 이미 더 못 줄이는 배치
        const target = std.math.clamp(px - origin, min_first, max_first);
        // 스냅 뒤의 실제 위치 — 한계를 넘게 반올림됐으면 한 셀 안쪽으로.
        var trial = sp;
        trial.ratio = ratioOf(target, g.avail);
        var new_first = splitGeometry(node_rect, m, trial).first_px;
        if (new_first < min_first) new_first += cell;
        if (new_first > max_first) new_first -= cell;
        if (new_first == g.first_px or new_first < 0 or new_first > g.avail) return false;
        const saved = self.*;
        self.nodes[node].split.ratio = ratioOf(new_first, g.avail);
        self.keepFarFixed(sp.first, sp.axis, m, c.first, .second, new_first);
        self.keepFarFixed(sp.second, sp.axis, m, c.second, .first, g.avail - new_first);
        if (!self.noPaneNewlyBelowMin(&saved, rect, m)) {
            self.* = saved;
            return false;
        }
        return true;
    }

    /// 바뀐 뒤 어느 pane 도 **새로** 최소 아래로 떨어지지 않았는가 — 이미 작았던 pane (창이 줄어서) 은 그대로거나
    /// 커지면 된다. `before` 는 바꾸기 전 트리.
    fn noPaneNewlyBelowMin(self: *const Tree, before: *const Tree, rect: Rect, m: Metrics) bool {
        var b_buf: [MAX_PANES_PER_TAB]PaneRect = undefined;
        var a_buf: [MAX_PANES_PER_TAB]PaneRect = undefined;
        const b = layout(before, rect, m, &b_buf);
        for (layout(self, rect, m, &a_buf)) |pr| {
            const old = find(b, pr.pane) orelse return false;
            const cols_ok = pr.cols >= MIN_PANE_COLS or pr.cols >= old.cols;
            const rows_ok = pr.rows >= MIN_PANE_ROWS or pr.rows >= old.rows;
            if (!cols_ok or !rows_ok) return false;
        }
        return true;
    }

    /// 움직이는 선이 이 subtree 의 어느 끝에 있는가 — `first` 끝 (선이 앞) 또는 `second` 끝 (선이 뒤).
    const LineSide = enum { first, second };

    /// `idx` subtree 가 `axis` 방향으로 가질 수 있는 최소 길이 — 단, **선에서 먼 칸은 지금 크기 그대로** 두고
    /// (붙은 칸만 줄어들므로). leaf 는 `leafMinExtent` — 단 이미 그보다 작은 leaf (창이 줄어서) 는 **지금 크기**
    /// (더 줄지만 않게). 같은 축의 분할은 먼 자식의 현재 px + 분할선 + 붙은 자식의 재귀값, 다른 축의 분할은 두
    /// 자식 (둘 다 선에 붙어 있다) 중 큰 것.
    fn minExtentKeepFar(self: *const Tree, idx: NodeIndex, axis: Axis, m: Metrics, rect: Rect, line: LineSide) i32 {
        return switch (self.nodes[idx]) {
            .leaf => @min(leafMinExtent(axis, m), if (axis == .side_by_side) rect.w else rect.h),
            .split => |s| blk: {
                const g = splitGeometry(rect, m, s);
                const c = childRects(rect, s, g);
                if (s.axis != axis) break :blk @max(
                    self.minExtentKeepFar(s.first, axis, m, c.first, line),
                    self.minExtentKeepFar(s.second, axis, m, c.second, line),
                );
                break :blk switch (line) {
                    .second => g.first_px + g.sep_px + self.minExtentKeepFar(s.second, axis, m, c.second, .second),
                    .first => self.minExtentKeepFar(s.first, axis, m, c.first, .first) + g.sep_px + g.second_px,
                };
            },
        };
    }

    /// `idx` subtree 의 `axis` 길이가 `new_extent` 로 바뀔 때, 선에서 먼 칸의 px 는 그대로 두고 붙은 칸이 변화를
    /// 흡수하도록 안쪽 같은-축 분할의 비율을 다시 놓는다. `rect` 는 바뀌기 전 영역 (현재 px 를 읽는 데 쓴다).
    fn keepFarFixed(self: *Tree, idx: NodeIndex, axis: Axis, m: Metrics, rect: Rect, line: LineSide, new_extent: i32) void {
        switch (self.nodes[idx]) {
            .leaf => {},
            .split => |s| {
                const g = splitGeometry(rect, m, s);
                const c = childRects(rect, s, g);
                if (s.axis != axis) {
                    // 다른 축 — 두 자식 모두 이 축 길이가 같이 바뀐다 (둘 다 선의 이웃).
                    self.keepFarFixed(s.first, axis, m, c.first, line, new_extent);
                    self.keepFarFixed(s.second, axis, m, c.second, line, new_extent);
                    return;
                }
                const new_avail = new_extent - g.sep_px;
                if (new_avail <= 0) return;
                var new_rect = rect;
                if (axis == .side_by_side) new_rect.w = new_extent else new_rect.h = new_extent;
                switch (line) {
                    .second => {
                        // first 가 먼 칸 — px 그대로. second 가 흡수.
                        const first_px = @min(g.first_px, new_avail);
                        self.nodes[idx].split.ratio = ratioOf(first_px, new_avail);
                        const g2 = splitGeometry(new_rect, m, self.nodes[idx].split);
                        self.keepFarFixed(s.second, axis, m, c.second, .second, new_avail - g2.first_px);
                    },
                    .first => {
                        // second 가 먼 칸 — px 그대로. first 가 흡수.
                        const first_px = @max(0, new_avail - g.second_px);
                        self.nodes[idx].split.ratio = ratioOf(first_px, new_avail);
                        const g2 = splitGeometry(new_rect, m, self.nodes[idx].split);
                        self.keepFarFixed(s.first, axis, m, c.first, .first, g2.first_px);
                    },
                }
            },
        }
    }

    /// 균등 분배 — 모든 분할의 비율을 양쪽 leaf 수에 비례시킨다. 형제의 leaf 가 1 : 2 면
    /// 1/3 : 2/3 이 되어 leaf 마다 같은 넓이를 갖는다. (분할마다 반씩으로 하는 다른 정의도
    /// 있다 — 4단계 실기에서 이 결과가 어색하면 그때 바꾼다.)
    pub fn equalize(self: *Tree) void {
        for (&self.nodes, self.alive) |*n, alive| {
            if (!alive) continue;
            switch (n.*) {
                .split => |*s| {
                    const a: f32 = @floatFromInt(self.leafCount(s.first));
                    const b: f32 = @floatFromInt(self.leafCount(s.second));
                    s.ratio = a / (a + b);
                },
                .leaf => {},
            }
        }
    }

    fn findLeaf(self: *const Tree, pane: PaneId) ?NodeIndex {
        for (self.nodes, self.alive, 0..) |n, alive, i| {
            if (!alive) continue;
            switch (n) {
                .leaf => |p| {
                    if (p == pane) return @intCast(i);
                },
                .split => {},
            }
        }
        return null;
    }

    fn allocNode(self: *Tree) NodeIndex {
        for (&self.alive, 0..) |*a, i| {
            if (!a.*) {
                a.* = true;
                return @intCast(i);
            }
        }
        // pool 이 2·MAX−1 이라 pane_count < MAX 인 동안 빈 자리는 항상 있다.
        unreachable;
    }

    fn leafCount(self: *const Tree, idx: NodeIndex) usize {
        return switch (self.nodes[idx]) {
            .leaf => 1,
            .split => |s| self.leafCount(s.first) + self.leafCount(s.second),
        };
    }

    /// `node` subtree 에서 `axis` 방향 한쪽 가장자리의 첫 leaf. `pick_first` 면 같은 축의
    /// 분할에서 `first` 쪽을, 아니면 `second` 쪽을 따라간다. 다른 축의 분할은 `first`.
    fn edgeLeaf(self: *const Tree, node: NodeIndex, axis: Axis, pick_first: bool) PaneId {
        var cur = node;
        while (true) {
            switch (self.nodes[cur]) {
                .leaf => |p| return p,
                .split => |s| cur = if (s.axis == axis and !pick_first) s.second else s.first,
            }
        }
    }

    /// `leaf` 의 조상 중 `axis` 방향 분할이면서, `pane_in_first` 면 leaf 가 `first` 쪽에 (즉
    /// 분할선이 leaf 의 second 방향 변에), 아니면 `second` 쪽에 있는 가장 가까운 것.
    fn ancestorSplit(self: *const Tree, leaf: NodeIndex, axis: Axis, pane_in_first: bool) ?NodeIndex {
        var child = leaf;
        var p = self.parent[child];
        while (p != NO_NODE) : ({
            child = p;
            p = self.parent[p];
        }) {
            const s = self.nodes[p].split;
            if (s.axis != axis) continue;
            if ((pane_in_first and s.first == child) or (!pane_in_first and s.second == child)) return p;
        }
        return null;
    }

    fn rectOf(self: *const Tree, root_rect: Rect, m: Metrics, target: NodeIndex) ?Rect {
        if (self.root == NO_NODE) return null;
        return self.rectOfNode(self.root, root_rect, m, target);
    }

    fn rectOfNode(self: *const Tree, idx: NodeIndex, rect: Rect, m: Metrics, target: NodeIndex) ?Rect {
        if (idx == target) return rect;
        return switch (self.nodes[idx]) {
            .leaf => null,
            .split => |s| blk: {
                const c = childRects(rect, s, splitGeometry(rect, m, s));
                break :blk self.rectOfNode(s.first, c.first, m, target) orelse
                    self.rectOfNode(s.second, c.second, m, target);
            },
        };
    }
};

const SplitGeometry = struct {
    first_px: i32,
    sep_px: i32,
    second_px: i32,
    /// 분할선을 뺀, 두 자식이 나눠 쓰는 길이.
    avail: i32,
};

/// 결정 2 — 분할선 위치. `first` 의 길이를 *leaf 로 봤을 때의 셀 경계* (`overhead + n·cell`)
/// 중 `ratio` 지점에 가장 가까운 곳으로 잡고 나머지를 `second` 에 준다. 가장 가까운 경계
/// (반올림) 인 이유: 비율이 가리키는 px 에서 가장 덜 어긋나서, 드래그로 놓은 자리가 그대로
/// 남는다. 내림과의 차이는 홀수 셀 하나가 앞 · 뒤 어느 쪽에 가는가뿐이다 — 결정 댓글의 숫자
/// 예는 내림으로 적어 77 | 78 이고 이 구현은 78 | 77 인데, 앞 pane 셀 정렬 · 총 열 최대 ·
/// 뒤 pane 흡수는 둘이 같다.
fn splitGeometry(rect: Rect, m: Metrics, s: Split) SplitGeometry {
    const along = s.axis == .side_by_side;
    const extent = if (along) rect.w else rect.h;
    const cell = if (along) m.cell_w else m.cell_h;
    // leaf 하나의 고정 길이 — 좌우는 양쪽 padding + scrollbar 자리, 상하는 양쪽 padding.
    const overhead = if (along) 2 * m.pad + m.scrollbar_w else 2 * m.pad;
    const sep = std.math.clamp(m.separator_w, 0, @max(extent, 0));
    const avail = extent - sep;
    if (avail <= 0) return .{ .first_px = 0, .sep_px = sep, .second_px = 0, .avail = 0 };

    const ratio = std.math.clamp(s.ratio, 0, 1);
    const want: f32 = ratio * @as(f32, @floatFromInt(avail));
    var first: i32 = undefined;
    if (cell <= 0) {
        first = @intFromFloat(@round(want));
    } else {
        const cells_f = @round((want - @as(f32, @floatFromInt(overhead))) / @as(f32, @floatFromInt(cell)));
        const cells: i32 = @intFromFloat(@max(cells_f, 0));
        first = overhead + cells * cell;
    }
    first = std.math.clamp(first, 0, avail);
    return .{ .first_px = first, .sep_px = sep, .second_px = avail - first, .avail = avail };
}

const ChildRects = struct {
    first: Rect,
    sep: Rect,
    second: Rect,
};

fn childRects(rect: Rect, s: Split, g: SplitGeometry) ChildRects {
    return switch (s.axis) {
        .side_by_side => .{
            .first = .{ .x = rect.x, .y = rect.y, .w = g.first_px, .h = rect.h },
            .sep = .{ .x = rect.x + g.first_px, .y = rect.y, .w = g.sep_px, .h = rect.h },
            .second = .{ .x = rect.x + g.first_px + g.sep_px, .y = rect.y, .w = g.second_px, .h = rect.h },
        },
        .stacked => .{
            .first = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = g.first_px },
            .sep = .{ .x = rect.x, .y = rect.y + g.first_px, .w = rect.w, .h = g.sep_px },
            .second = .{ .x = rect.x, .y = rect.y + g.first_px + g.sep_px, .w = rect.w, .h = g.second_px },
        },
    };
}

/// leaf 하나의 격자 — 지금 host 가 창 전체에 하는 계산을 pane 의 rect 에 그대로 적용한다.
/// `rect` 는 탭바를 이미 뺀 영역이라 `terminalRows` 의 `tab_bar_h` 는 0 이다.
pub fn leafRect(pane: PaneId, rect: Rect, m: Metrics) PaneRect {
    return .{
        .pane = pane,
        .rect = rect,
        .cols = ui_metrics.terminalCols(rect.w, m.pad, m.scrollbar_w, m.cell_w),
        .rows = ui_metrics.terminalRows(rect.h, 0, m.pad, m.cell_h),
        .grid_x = rect.x + m.pad,
        .grid_y = rect.y + m.pad,
    };
}

/// 트리를 pane 별 px 영역 + 격자로 편다. `rect` 는 **탭바를 뺀** 터미널 영역이다 (host 가
/// `y = tab_bar_h`, `h = viewport_h − tab_bar_h` 로 넘긴다). 결과는 화면 순서 (왼쪽 · 위
/// 먼저). `out.len >= tree.count()` 여야 한다 — `[MAX_PANES_PER_TAB]PaneRect` 면 항상 충분하다.
pub fn layout(tree: *const Tree, rect: Rect, m: Metrics, out: []PaneRect) []PaneRect {
    var n: usize = 0;
    if (tree.root != NO_NODE) layoutNode(tree, tree.root, rect, m, out, &n);
    return out[0..n];
}

fn layoutNode(tree: *const Tree, idx: NodeIndex, rect: Rect, m: Metrics, out: []PaneRect, n: *usize) void {
    switch (tree.nodes[idx]) {
        .leaf => |p| {
            out[n.*] = leafRect(p, rect, m);
            n.* += 1;
        },
        .split => |s| {
            const c = childRects(rect, s, splitGeometry(rect, m, s));
            layoutNode(tree, s.first, c.first, m, out, n);
            layoutNode(tree, s.second, c.second, m, out, n);
        },
    }
}

/// 회색 분할선 목록 — pane 이 n 이면 n−1 개. `out.len >= tree.count() − 1`.
pub fn separators(tree: *const Tree, rect: Rect, m: Metrics, out: []Separator) []Separator {
    var n: usize = 0;
    if (tree.root != NO_NODE) separatorsNode(tree, tree.root, rect, m, out, &n);
    return out[0..n];
}

fn separatorsNode(tree: *const Tree, idx: NodeIndex, rect: Rect, m: Metrics, out: []Separator, n: *usize) void {
    switch (tree.nodes[idx]) {
        .leaf => {},
        .split => |s| {
            const c = childRects(rect, s, splitGeometry(rect, m, s));
            out[n.*] = .{ .rect = c.sep, .axis = s.axis, .node = idx };
            n.* += 1;
            separatorsNode(tree, s.first, c.first, m, out, n);
            separatorsNode(tree, s.second, c.second, m, out, n);
        },
    }
}

pub fn find(panes: []const PaneRect, pane: PaneId) ?PaneRect {
    for (panes) |pr| {
        if (pr.pane == pane) return pr;
    }
    return null;
}

fn rectContains(r: Rect, px: i32, py: i32) bool {
    return px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h;
}

/// 픽셀이 어느 pane 안인가. 분할선 위 · 영역 밖은 null. (분할선 hit 은 4단계의 드래그가
/// `separators` 결과에 ±slop 을 두고 따로 판정한다.)
pub fn paneAt(panes: []const PaneRect, px: i32, py: i32) ?PaneId {
    for (panes) |pr| {
        if (rectContains(pr.rect, px, py)) return pr.pane;
    }
    return null;
}

/// 4c 드래그 — 픽셀이 어느 분할선 위인가. 그리는 선은 1 pt 지만 잡는 영역은 양쪽으로 `slop` px 넓다
/// (확정 설계 축 2 "히트 영역은 그리는 것보다 넓게"). 분할선의 길이 방향으로는 정확히 선 위여야 한다.
pub fn separatorAt(seps: []const Separator, px: i32, py: i32, slop: i32) ?Separator {
    for (seps) |s| {
        const r = s.rect;
        const on = switch (s.axis) {
            .side_by_side => px >= r.x - slop and px < r.x + r.w + slop and py >= r.y and py < r.y + r.h,
            .stacked => py >= r.y - slop and py < r.y + r.h + slop and px >= r.x and px < r.x + r.w,
        };
        if (on) return s;
    }
    return null;
}

/// pane 안의 픽셀 → 셀. Linux `pixelToCell` 과 같은 규칙 — 격자 원점 앞 (padding) 과
/// `cols` / `rows` 밖 (남는 px · scrollbar 자리) 은 null.
pub fn cellAt(pr: PaneRect, px: i32, py: i32, m: Metrics) ?Cell {
    if (m.cell_w <= 0 or m.cell_h <= 0) return null;
    if (px < pr.grid_x or py < pr.grid_y) return null;
    const col = @divTrunc(px - pr.grid_x, m.cell_w);
    const row = @divTrunc(py - pr.grid_y, m.cell_h);
    if (col >= pr.cols or row >= pr.rows) return null;
    return .{ .col = @intCast(col), .row = @intCast(row) };
}

/// 진행 축 (`along`) 과 교차 축 (`cross`) 으로 본 구간. 모두 half-open.
const Span = struct {
    along_lo: i32,
    along_hi: i32,
    cross_lo: i32,
    cross_hi: i32,
};

fn span(r: Rect, dir: Direction) Span {
    return switch (dir.axis()) {
        .side_by_side => .{ .along_lo = r.x, .along_hi = r.x + r.w, .cross_lo = r.y, .cross_hi = r.y + r.h },
        .stacked => .{ .along_lo = r.y, .along_hi = r.y + r.h, .cross_lo = r.x, .cross_hi = r.x + r.w },
    };
}

/// #483 6단계 — 활성 pane 의 어느 변에 amber 를 그리는가 (2026-08-27 사용자 규칙).
///
/// - 분할선에 닿은 **안쪽 변** 은 항상.
/// - 안쪽 변이 **하나뿐** 인 pane (= 바깥과 3 면 닿음: 반 분할의 양쪽, 한 줄의 양 끝) 은 그 변에 직각으로 붙은
///   바깥 두 변도 → 총 3 면 (⊐ 모양). 안쪽 변 하나만으로는 회색 분할선 어느 쪽인지 1 pt 로 읽히지 않았다.
///   안쪽 변이 둘 이상이면 (ㄴ · ‖) 길이와 모양으로 이미 읽히니 그대로.
/// - 최대화 중이면 네 변 모두 — 일반 pane 은 최대 3 면이라 4 면 틀은 최대화 하나뿐이다.
/// - pane 하나 (안쪽 변 0) 는 아무것도 없다 — host 가 그때 `active_pane_rect` 를 안 넘긴다.
pub const FocusEdges = struct { left: bool, right: bool, top: bool, bottom: bool };

pub fn focusEdges(r: Rect, area: Rect, zoomed: bool) FocusEdges {
    if (zoomed) return .{ .left = true, .right = true, .top = true, .bottom = true };
    var e: FocusEdges = .{
        .left = r.x > area.x,
        .right = r.x + r.w < area.x + area.w,
        .top = r.y > area.y,
        .bottom = r.y + r.h < area.y + area.h,
    };
    const inner: u8 = @as(u8, @intFromBool(e.left)) + @as(u8, @intFromBool(e.right)) +
        @as(u8, @intFromBool(e.top)) + @as(u8, @intFromBool(e.bottom));
    if (inner == 1) {
        if (e.left or e.right) {
            e.top = true;
            e.bottom = true;
        } else {
            e.left = true;
            e.right = true;
        }
    }
    return e;
}

/// leaf 하나가 `axis` 방향으로 가질 수 있는 최소 길이 — `MIN_PANE_*` 셀 + 양쪽 padding (+ 좌우면 scrollbar 자리).
fn leafMinExtent(axis: Axis, m: Metrics) i32 {
    return switch (axis) {
        .side_by_side => 2 * m.pad + m.scrollbar_w + @as(i32, MIN_PANE_COLS) * m.cell_w,
        .stacked => 2 * m.pad + @as(i32, MIN_PANE_ROWS) * m.cell_h,
    };
}

fn ratioOf(first: i32, avail: i32) f32 {
    return @as(f32, @floatFromInt(first)) / @as(f32, @floatFromInt(avail));
}

/// 교차 축 좌표 `ray` 가 구간 안이면 0, 밖이면 가장 가까운 끝 픽셀까지의 거리.
fn crossDistance(t: Span, ray: i32) i32 {
    if (ray < t.cross_lo) return t.cross_lo - ray;
    if (ray >= t.cross_hi) return ray - (t.cross_hi - 1);
    return 0;
}

/// 확정 설계 축 3 — **기하 기반** 이웃. `from` 의 `dir` 쪽 변에서 그 방향으로 쏴서 처음
/// 만나는 pane. 광선의 교차 축 위치는 `anchor` (커서의 px — 좌우 이동이면 y, 상하면 x),
/// 없으면 변의 중점. 바로 맞닿은 pane 들 (분할선 하나 건너) 만 후보이고, 광선이 그 사이
/// 분할선 틈에 떨어지면 광선에 가장 가까운 pane 을 고른다. 그쪽이 창 가장자리면 null.
///
/// 트리 이웃 (형제 우선) 이 아니라 기하로 푸는 이유 — 3 분할 이상에서 화면상 바로 옆인데
/// 트리에서는 사촌이라 안 가는 경우가 생긴다. 아래 "사촌" 테스트가 그 경우다.
pub fn neighbor(panes: []const PaneRect, from: PaneId, dir: Direction, anchor: ?i32) ?PaneId {
    const src = find(panes, from) orelse return null;
    const s = span(src.rect, dir);
    const ray = anchor orelse @divTrunc(s.cross_lo + s.cross_hi, 2);

    var best: ?PaneRect = null;
    var best_gap: i32 = 0;
    for (panes) |p| {
        if (p.pane == from) continue;
        const t = span(p.rect, dir);
        // dir 쪽으로 src 의 앞 변 너머에서 시작해야 한다.
        const ahead = if (dir.towardSecond()) t.along_lo >= s.along_hi else t.along_hi <= s.along_lo;
        if (!ahead) continue;
        // 교차 축으로 겹치지 않으면 광선이 닿을 수 없다.
        if (t.cross_lo >= s.cross_hi or t.cross_hi <= s.cross_lo) continue;
        const gap = if (dir.towardSecond()) t.along_lo - s.along_hi else s.along_lo - t.along_hi;
        if (best == null or gap < best_gap) {
            best = p;
            best_gap = gap;
        } else if (gap == best_gap and crossDistance(t, ray) < crossDistance(span(best.?.rect, dir), ray)) {
            best = p;
        }
    }
    return if (best) |b| b.pane else null;
}

// ── 테스트 ──────────────────────────────────────────────────────────────
//
// 실측값 둘을 쓴다. `mac2x` 는 ui_metrics 테스트의 macOS 2x (cell 19×39 · pad 12 · scrollbar 20),
// `win1x` 는 Windows 100 % (cell 9×19 · pad 6 · scrollbar 10). 분할선은 `linePx(1pt)` = 2 / 1.

const mac2x: Metrics = .{ .cell_w = 19, .cell_h = 39, .pad = 12, .scrollbar_w = 20, .separator_w = 2 };
const win1x: Metrics = .{ .cell_w = 9, .cell_h = 19, .pad = 6, .scrollbar_w = 10, .separator_w = 1 };
/// 결정 2 의 숫자 예에 쓴 창 — 3052 px 폭.
const wide: Rect = .{ .x = 0, .y = 0, .w = 3052, .h = 1800 };

test "#483 단일 pane 은 지금 단일 창과 같은 격자를 낸다" {
    const cases = [_]struct { w: i32, h: i32, tab: i32, m: Metrics }{
        .{ .w = 3024, .h = 1800, .tab = 0, .m = mac2x },
        .{ .w = 3024, .h = 1800, .tab = 56, .m = mac2x },
        .{ .w = 960, .h = 600, .tab = 28, .m = win1x },
        .{ .w = 960, .h = 600, .tab = 0, .m = win1x },
        // 극단적으로 작은 창 — 두 함수의 "최소 1" 계약이 같은 답을 낸다.
        .{ .w = 20, .h = 10, .tab = 28, .m = win1x },
    };
    for (cases) |c| {
        const tree = Tree.single(7);
        var buf: [MAX_PANES_PER_TAB]PaneRect = undefined;
        const p = layout(&tree, .{ .x = 0, .y = c.tab, .w = c.w, .h = c.h - c.tab }, c.m, &buf);
        try std.testing.expectEqual(@as(usize, 1), p.len);
        try std.testing.expectEqual(@as(PaneId, 7), p[0].pane);
        try std.testing.expectEqual(ui_metrics.terminalCols(c.w, c.m.pad, c.m.scrollbar_w, c.m.cell_w), p[0].cols);
        try std.testing.expectEqual(ui_metrics.terminalRows(c.h, c.tab, c.m.pad, c.m.cell_h), p[0].rows);
        try std.testing.expectEqual(c.m.pad, p[0].grid_x);
        try std.testing.expectEqual(c.tab + c.m.pad, p[0].grid_y);
        // 분할선은 없다.
        var sbuf: [MAX_PANES_PER_TAB]Separator = undefined;
        try std.testing.expectEqual(@as(usize, 0), separators(&tree, wide, c.m, &sbuf).len);
    }
}

test "#483 결정 2 — 앞 pane 은 셀에 딱 맞고 남는 px 은 뒤 pane 이 흡수한다 (3052 px 예)" {
    var tree = Tree.single(1);
    try tree.split(1, .right, 2, wide, mac2x);
    var buf: [MAX_PANES_PER_TAB]PaneRect = undefined;
    const p = layout(&tree, wide, mac2x, &buf);
    try std.testing.expectEqual(@as(usize, 2), p.len);

    // 앞 pane — 비율 0.5 는 1525 px. 가장 가까운 셀 경계는 44 + 78·19 = 1526. 남는 px 0.
    try std.testing.expectEqual(@as(PaneId, 1), p[0].pane);
    try std.testing.expectEqual(@as(i32, 1526), p[0].rect.w);
    try std.testing.expectEqual(@as(u16, 78), p[0].cols);
    try std.testing.expectEqual(@as(i32, 0), p[0].rect.w - 44 - 78 * 19);

    // 뒤 pane — 3052 − 2 − 1526 = 1524 → 77 열, 남는 17 px (지금 단일 창처럼 오른쪽 끝에).
    try std.testing.expectEqual(@as(PaneId, 2), p[1].pane);
    try std.testing.expectEqual(@as(i32, 1528), p[1].rect.x);
    try std.testing.expectEqual(@as(i32, 1524), p[1].rect.w);
    try std.testing.expectEqual(@as(u16, 77), p[1].cols);
    try std.testing.expectEqual(@as(i32, 17), p[1].rect.w - 44 - 77 * 19);

    // 총 155 열 = ⌊(3052 − 2 − 2·44) / 19⌋ — 열을 버리지 않는다.
    try std.testing.expectEqual(@as(u16, 155), p[0].cols + p[1].cols);
    // 높이 · 행 · 격자 원점은 단일 창과 같다.
    try std.testing.expectEqual(wide.h, p[0].rect.h);
    try std.testing.expectEqual(wide.h, p[1].rect.h);
    try std.testing.expectEqual(ui_metrics.terminalRows(wide.h, 0, 12, 39), p[0].rows);
    try std.testing.expectEqual(@as(i32, 12), p[0].grid_x);
    try std.testing.expectEqual(@as(i32, 1528 + 12), p[1].grid_x);

    // 분할선 하나 — 두 pane 사이 틈과 정확히 일치.
    var sbuf: [MAX_PANES_PER_TAB]Separator = undefined;
    const seps = separators(&tree, wide, mac2x, &sbuf);
    try std.testing.expectEqual(@as(usize, 1), seps.len);
    try std.testing.expectEqual(Axis.side_by_side, seps[0].axis);
    try std.testing.expectEqual(Rect{ .x = 1526, .y = 0, .w = 2, .h = 1800 }, seps[0].rect);
}

test "#483 결정 2 — 좌우 분할의 총 열은 창 폭을 훑어도 항상 최대다" {
    var w: i32 = 1200;
    while (w <= 4000) : (w += 7) {
        var tree = Tree.single(1);
        const rect: Rect = .{ .x = 0, .y = 0, .w = w, .h = 1000 };
        try tree.split(1, .right, 2, rect, mac2x);
        var buf: [MAX_PANES_PER_TAB]PaneRect = undefined;
        const p = layout(&tree, rect, mac2x, &buf);
        const n_max = @divTrunc(w - mac2x.separator_w - 2 * 44, 19);
        try std.testing.expectEqual(n_max, @as(i32, p[0].cols) + p[1].cols);
        try std.testing.expectEqual(w, p[0].rect.w + mac2x.separator_w + p[1].rect.w);
        // 앞 pane 은 늘 남는 px 이 0.
        try std.testing.expectEqual(@as(i32, 0), p[0].rect.w - 44 - @as(i32, p[0].cols) * 19);
    }
}

test "#483 결정 2 — 상하 분할의 고정 높이는 2·pad 뿐이다 (scrollbar 없음)" {
    var tree = Tree.single(1);
    const rect: Rect = .{ .x = 0, .y = 56, .w = 3024, .h = 1744 }; // 탭바 56 아래
    try tree.split(1, .down, 2, rect, mac2x);
    var buf: [MAX_PANES_PER_TAB]PaneRect = undefined;
    const p = layout(&tree, rect, mac2x, &buf);
    // avail 1742 · 절반 871 → (871 − 24) / 39 = 21.7 → 22 행 → 24 + 858 = 882 px.
    try std.testing.expectEqual(@as(i32, 56), p[0].rect.y);
    try std.testing.expectEqual(@as(i32, 882), p[0].rect.h);
    try std.testing.expectEqual(@as(u16, 22), p[0].rows);
    try std.testing.expectEqual(@as(i32, 56 + 882 + 2), p[1].rect.y);
    try std.testing.expectEqual(@as(i32, 860), p[1].rect.h);
    try std.testing.expectEqual(@as(u16, 21), p[1].rows);
    try std.testing.expectEqual(@divTrunc(1742 - 48, 39), @as(i32, p[0].rows) + p[1].rows);
    // 폭 · 열은 둘 다 단일 창과 같다.
    try std.testing.expectEqual(ui_metrics.terminalCols(3024, 12, 20, 19), p[0].cols);
    try std.testing.expectEqual(p[0].cols, p[1].cols);
    try std.testing.expectEqual(@as(i32, 56 + 12), p[0].grid_y);
    try std.testing.expectEqual(@as(i32, 56 + 882 + 2 + 12), p[1].grid_y);
}

test "#483 결정 2 — 같은 축 중첩: 바깥은 앞 자식을 leaf 로 본 셀 경계, 안쪽은 자기 rect 에서 내림" {
    var tree = Tree.single(1);
    try tree.split(1, .right, 2, wide, mac2x); // 1 | 2
    try tree.split(1, .right, 3, wide, mac2x); // (1 | 3) | 2
    var buf: [MAX_PANES_PER_TAB]PaneRect = undefined;
    const p = layout(&tree, wide, mac2x, &buf);
    try std.testing.expectEqual(@as(usize, 3), p.len);
    try std.testing.expectEqual(@as(PaneId, 1), p[0].pane);
    try std.testing.expectEqual(@as(PaneId, 3), p[1].pane);
    try std.testing.expectEqual(@as(PaneId, 2), p[2].pane);

    // 바깥 분할선은 앞 subtree 를 leaf 로 본 경계 1526 — 위 테스트와 같은 자리.
    try std.testing.expectEqual(@as(i32, 1526), p[0].rect.w + 2 + p[1].rect.w);
    try std.testing.expectEqual(@as(i32, 1528), p[2].rect.x);
    try std.testing.expectEqual(@as(u16, 77), p[2].cols);

    // 안쪽 — avail 1524 · 절반 762 → (762 − 44) / 19 = 37.8 → 38 → 1 은 766 px (남는 0),
    // 3 은 758 px → 37 열, 남는 11 px 은 3 안에서 (C 처럼) 흡수된다.
    try std.testing.expectEqual(@as(i32, 766), p[0].rect.w);
    try std.testing.expectEqual(@as(u16, 38), p[0].cols);
    try std.testing.expectEqual(@as(i32, 768), p[1].rect.x);
    try std.testing.expectEqual(@as(i32, 758), p[1].rect.w);
    try std.testing.expectEqual(@as(u16, 37), p[1].cols);
    try std.testing.expectEqual(@as(i32, 11), p[1].rect.w - 44 - 37 * 19);
}

test "#483 split 거부 — 최소 크기 미달과 개수 초과를 구분하고, 거부되면 트리는 그대로다" {
    // 두 pane 이 합쳐 39 열밖에 못 담는 폭 → 한쪽이 20 미만 → TooSmall.
    var tree = Tree.single(1);
    const narrow: Rect = .{ .x = 0, .y = 0, .w = 44 + 39 * 19 + 2 + 44, .h = 1000 };
    var before_buf: [MAX_PANES_PER_TAB]PaneRect = undefined;
    const before = layout(&tree, narrow, mac2x, &before_buf);
    try std.testing.expectError(error.TooSmall, tree.split(1, .right, 2, narrow, mac2x));
    try std.testing.expectEqual(@as(usize, 1), tree.count());
    var after_buf: [MAX_PANES_PER_TAB]PaneRect = undefined;
    try std.testing.expectEqualDeep(before, layout(&tree, narrow, mac2x, &after_buf));

    // 한 열만 더 있으면 20 / 20 으로 된다.
    const enough: Rect = .{ .x = 0, .y = 0, .w = 44 + 40 * 19 + 2 + 44, .h = 1000 };
    try tree.split(1, .right, 2, enough, mac2x);
    try std.testing.expectEqual(@as(usize, 2), tree.count());
    var p_buf: [MAX_PANES_PER_TAB]PaneRect = undefined;
    const p = layout(&tree, enough, mac2x, &p_buf);
    try std.testing.expectEqual(@as(u16, 20), p[0].cols);
    try std.testing.expectEqual(@as(u16, 20), p[1].cols);

    // 상하도 같은 규칙 — 합쳐 9 행이면 5 / 4 라 TooSmall.
    var t_rows = Tree.single(1);
    const short: Rect = .{ .x = 0, .y = 0, .w = 3000, .h = 24 + 9 * 39 + 2 + 24 };
    try std.testing.expectError(error.TooSmall, t_rows.split(1, .down, 2, short, mac2x));
    const tall: Rect = .{ .x = 0, .y = 0, .w = 3000, .h = 24 + 10 * 39 + 2 + 24 };
    try t_rows.split(1, .down, 2, tall, mac2x);

    // 개수 — 넉넉한 창에서 라운드마다 모든 pane 을 갈라 16 까지, 17 번째는 TooManyPanes.
    var t16 = Tree.single(0);
    const huge: Rect = .{ .x = 0, .y = 0, .w = 20000, .h = 20000 };
    var round: u5 = 0;
    while (round < 4) : (round += 1) {
        const existing: PaneId = @as(PaneId, 1) << round;
        var i: PaneId = 0;
        while (i < existing) : (i += 1) try t16.split(i, .right, existing + i, huge, mac2x);
    }
    try std.testing.expectEqual(MAX_PANES_PER_TAB, t16.count());
    try std.testing.expectError(error.TooManyPanes, t16.split(0, .right, 99, huge, mac2x));
    try std.testing.expectEqual(MAX_PANES_PER_TAB, t16.count());
    var p16_buf: [MAX_PANES_PER_TAB]PaneRect = undefined;
    const p16 = layout(&t16, huge, mac2x, &p16_buf);
    try std.testing.expectEqual(MAX_PANES_PER_TAB, p16.len);
    var s16_buf: [MAX_PANES_PER_TAB]Separator = undefined;
    try std.testing.expectEqual(MAX_PANES_PER_TAB - 1, separators(&t16, huge, mac2x, &s16_buf).len);

    // 모르는 pane · 이미 있는 id.
    try std.testing.expectError(error.UnknownPane, tree.split(42, .right, 3, enough, mac2x));
    try std.testing.expectError(error.DuplicatePane, tree.split(1, .right, 2, enough, mac2x));
}

test "#483 close — 형제가 부모 자리로 올라오고 포커스는 맞닿은 가장자리의 첫 leaf 로 간다" {
    var base = Tree.single(1);
    try base.split(1, .right, 2, wide, mac2x); // 1 | 2
    try base.split(2, .down, 3, wide, mac2x); // 1 | (2 / 3)
    var buf: [MAX_PANES_PER_TAB]PaneRect = undefined;

    // 1 을 닫으면 (2 / 3) 이 root. 닫힌 쪽 (왼쪽) 가장자리 — 다른 축의 분할이라 first → 2.
    var t = base;
    try std.testing.expectEqual(@as(PaneId, 2), try t.close(1));
    try std.testing.expectEqual(@as(usize, 2), t.count());
    var p = layout(&t, wide, mac2x, &buf);
    try std.testing.expectEqual(@as(PaneId, 2), p[0].pane);
    try std.testing.expectEqual(@as(PaneId, 3), p[1].pane);
    try std.testing.expectEqual(wide.w, p[0].rect.w); // 창 폭 전체를 쓴다
    try std.testing.expectEqual(wide.w, p[1].rect.w);
    try std.testing.expectEqual(wide.h, p[0].rect.h + 2 + p[1].rect.h);

    // 2 를 닫으면 1 | 3. 형제 3 이 leaf 라 승계는 3. 바깥 분할의 자식 index 가 그대로 살아
    // 있어야 하므로 그 분할선을 옮기는 resize 가 계속 된다.
    t = base;
    try std.testing.expectEqual(@as(PaneId, 3), try t.close(2));
    p = layout(&t, wide, mac2x, &buf);
    try std.testing.expectEqual(@as(PaneId, 1), p[0].pane);
    try std.testing.expectEqual(@as(PaneId, 3), p[1].pane);
    try std.testing.expectEqual(wide.h, p[1].rect.h);
    try std.testing.expect(t.resize(3, .left, 1, wide, mac2x));

    // 3 을 닫으면 1 | 2, 승계 2.
    t = base;
    try std.testing.expectEqual(@as(PaneId, 2), try t.close(3));
    p = layout(&t, wide, mac2x, &buf);
    try std.testing.expectEqual(@as(usize, 2), p.len);
    try std.testing.expectEqual(@as(PaneId, 2), p[1].pane);
    try std.testing.expectEqual(wide.h, p[1].rect.h);

    // 같은 축에서는 닫힌 쪽 자식을 따라간다 — (1 | 3) | 2 에서 2 를 닫으면 오른쪽 가장자리 leaf 3.
    var same = Tree.single(1);
    try same.split(1, .right, 2, wide, mac2x);
    try same.split(1, .right, 3, wide, mac2x); // (1 | 3) | 2
    try std.testing.expectEqual(@as(PaneId, 3), try same.close(2));

    // 마지막 pane 은 이 모듈이 닫지 않는다. 모르는 pane 도 거부.
    var s = Tree.single(9);
    try std.testing.expectError(error.LastPane, s.close(9));
    try std.testing.expectError(error.UnknownPane, base.close(42));
}

test "#483 4c — 분할선 드래그: setSeparatorPx 는 셀 경계에 스냅하고 최소 크기를 지키며, separatorAt 은 ±slop 으로 잡는다" {
    const m: Metrics = .{ .cell_w = 19, .cell_h = 39, .pad = 12, .scrollbar_w = 20, .separator_w = 2 };
    const rect: Rect = .{ .x = 0, .y = 0, .w = 3052, .h = 1000 };
    var tree = Tree.single(0);
    try tree.split(0, .right, 1, rect, m);
    var sbuf: [MAX_PANES_PER_TAB]Separator = undefined;
    const seps = separators(&tree, rect, m, &sbuf);
    try std.testing.expectEqual(@as(usize, 1), seps.len);
    try std.testing.expectEqual(@as(i32, 1526), seps[0].rect.x); // 78 열 × 19 + 44
    // ±4 px 안은 잡히고, 선의 길이 방향 (y) 은 정확히 선 위여야 한다.
    try std.testing.expect(separatorAt(seps, 1522, 500, 4) != null);
    try std.testing.expect(separatorAt(seps, 1531, 500, 4) != null);
    try std.testing.expect(separatorAt(seps, 1532, 500, 4) == null);
    try std.testing.expect(separatorAt(seps, 1527, 1000, 4) == null);
    // x = 1000 에 놓으면 앞 pane 은 round((1000 − 44) / 19) = 50 열 → 분할선 x = 994.
    try std.testing.expect(tree.setSeparatorPx(seps[0].node, 1000, rect, m));
    var buf: [MAX_PANES_PER_TAB]PaneRect = undefined;
    try std.testing.expectEqual(@as(u16, 50), find(layout(&tree, rect, m, &buf), 0).?.cols);
    try std.testing.expectEqual(@as(i32, 994), separators(&tree, rect, m, &sbuf)[0].rect.x);
    // 최소 크기 (20 열) 아래 자리는 거부하지 않고 **한계에서 멈춘다** (clamp, 2026-08-27 결정) — 앞 pane 20 열.
    try std.testing.expect(tree.setSeparatorPx(seps[0].node, 100, rect, m));
    try std.testing.expectEqual(@as(u16, 20), find(layout(&tree, rect, m, &buf), 0).?.cols);
    // 이미 한계면 바뀐 것이 없어 false.
    try std.testing.expect(!tree.setSeparatorPx(seps[0].node, 50, rect, m));
    // leaf 노드 · 죽은 노드는 거부.
    try std.testing.expect(!tree.setSeparatorPx(1, 1000, rect, m));
    try std.testing.expect(!tree.setSeparatorPx(MAX_NODES - 1, 1000, rect, m));
}

test "#483 6단계 — 선에 붙은 칸만 변한다: 안쪽 같은-축 분할의 먼 칸은 px 그대로, 한계도 먼 칸을 고정한 채 잰다" {
    const m: Metrics = .{ .cell_w = 19, .cell_h = 39, .pad = 12, .scrollbar_w = 20, .separator_w = 2 };
    const rect: Rect = .{ .x = 0, .y = 0, .w = 3052, .h = 1000 };
    // A | (B | C) — 0 을 오른쪽으로 갈라 1, 1 을 다시 오른쪽으로 갈라 2.
    var tree = Tree.single(0);
    try tree.split(0, .right, 1, rect, m);
    try tree.split(1, .right, 2, rect, m);
    var buf: [MAX_PANES_PER_TAB]PaneRect = undefined;
    var sbuf: [MAX_PANES_PER_TAB]Separator = undefined;
    try std.testing.expectEqual(@as(u16, 78), find(layout(&tree, rect, m, &buf), 0).?.cols);
    try std.testing.expectEqual(@as(u16, 38), find(layout(&tree, rect, m, &buf), 1).?.cols);
    try std.testing.expectEqual(@as(u16, 37), find(layout(&tree, rect, m, &buf), 2).?.cols);
    // A|B 선 (루트) 을 5 셀 오른쪽으로: A +5, **B −5, C 그대로** (예전엔 B · C 가 비례해 같이 줄었다).
    const root_sep = separators(&tree, rect, m, &sbuf)[0];
    try std.testing.expectEqual(@as(i32, 1526), root_sep.rect.x);
    try std.testing.expect(tree.setSeparatorPx(root_sep.node, 1526 + 5 * 19, rect, m));
    try std.testing.expectEqual(@as(u16, 83), find(layout(&tree, rect, m, &buf), 0).?.cols);
    try std.testing.expectEqual(@as(u16, 33), find(layout(&tree, rect, m, &buf), 1).?.cols);
    try std.testing.expectEqual(@as(u16, 37), find(layout(&tree, rect, m, &buf), 2).?.cols);
    // 키 1 셀 조절도 같은 경로 — A 를 오른쪽으로 1 셀: A 84, B 32, C 37.
    try std.testing.expect(tree.resize(0, .right, 1, rect, m));
    try std.testing.expectEqual(@as(u16, 84), find(layout(&tree, rect, m, &buf), 0).?.cols);
    try std.testing.expectEqual(@as(u16, 32), find(layout(&tree, rect, m, &buf), 1).?.cols);
    try std.testing.expectEqual(@as(u16, 37), find(layout(&tree, rect, m, &buf), 2).?.cols);
    // 한계 — 멀리 끌어도 B 는 최소 20 열에서 멈추고 C 는 37 그대로: A = 158 − 20 − 37 … 셀 경계로 96.
    try std.testing.expect(tree.setSeparatorPx(root_sep.node, 3000, rect, m));
    try std.testing.expectEqual(@as(u16, 20), find(layout(&tree, rect, m, &buf), 1).?.cols);
    try std.testing.expectEqual(@as(u16, 37), find(layout(&tree, rect, m, &buf), 2).?.cols);
    try std.testing.expectEqual(@as(u16, 96), find(layout(&tree, rect, m, &buf), 0).?.cols);
    // 반대쪽 — B|C 선을 왼쪽으로 끌면 B 만 줄고 A 는 그대로 (A 는 이 선의 subtree 밖).
    tree.equalize();
    const inner = separators(&tree, rect, m, &sbuf)[1];
    const a_before = find(layout(&tree, rect, m, &buf), 0).?.cols;
    try std.testing.expect(tree.setSeparatorPx(inner.node, inner.rect.x - 3 * 19, rect, m));
    try std.testing.expectEqual(a_before, find(layout(&tree, rect, m, &buf), 0).?.cols);
}

test "#483 6단계 — focusEdges: 안쪽 변 하나면 3 면, 둘 이상이면 안쪽만, 최대화면 4 면" {
    const area: Rect = .{ .x = 0, .y = 0, .w = 300, .h = 200 };
    const FE = FocusEdges;
    // A | B 의 A — 안쪽 변은 오른쪽 하나 → 오른쪽 + 위 + 아래 (⊐), 왼쪽 창 가장자리는 비움.
    try std.testing.expectEqual(FE{ .left = false, .right = true, .top = true, .bottom = true }, focusEdges(.{ .x = 0, .y = 0, .w = 150, .h = 200 }, area, false));
    // A | B 의 B — 왼쪽 + 위 + 아래 (⊏).
    try std.testing.expectEqual(FE{ .left = true, .right = false, .top = true, .bottom = true }, focusEdges(.{ .x = 152, .y = 0, .w = 148, .h = 200 }, area, false));
    // A / B 의 A — 아래 하나 → 아래 + 왼쪽 + 오른쪽 (⊔).
    try std.testing.expectEqual(FE{ .left = true, .right = true, .top = false, .bottom = true }, focusEdges(.{ .x = 0, .y = 0, .w = 300, .h = 100 }, area, false));
    // A | B | C 의 B — 안쪽 변 둘 (좌 · 우) → 그 둘만 (‖).
    try std.testing.expectEqual(FE{ .left = true, .right = true, .top = false, .bottom = false }, focusEdges(.{ .x = 100, .y = 0, .w = 100, .h = 200 }, area, false));
    // 2×2 의 왼쪽 위 — 안쪽 변 둘 (우 · 아래) → 그 둘만 (ㄴ).
    try std.testing.expectEqual(FE{ .left = false, .right = true, .top = false, .bottom = true }, focusEdges(.{ .x = 0, .y = 0, .w = 150, .h = 100 }, area, false));
    // A | (B / C / D) 의 C — 안쪽 변 셋 → 그 셋.
    try std.testing.expectEqual(FE{ .left = true, .right = false, .top = true, .bottom = true }, focusEdges(.{ .x = 152, .y = 70, .w = 148, .h = 60 }, area, false));
    // 최대화 — 영역 전체를 차지해도 (안쪽 변 0) 네 변.
    try std.testing.expectEqual(FE{ .left = true, .right = true, .top = true, .bottom = true }, focusEdges(area, area, true));
    // pane 하나 (최대화 아님) — 안쪽 변 0 이면 아무것도 없다.
    try std.testing.expectEqual(FE{ .left = false, .right = false, .top = false, .bottom = false }, focusEdges(area, area, false));
}

test "#483 6단계 — 창이 줄어 최소보다 작아진 pane 이 있어도: 자리가 있는 pane 은 갈라지고, 작은 pane 은 키울 수만 있다" {
    const m = mac2x;
    const roomy: Rect = .{ .x = 0, .y = 0, .w = 3052, .h = 1000 };
    var tree = Tree.single(0);
    try tree.split(0, .right, 1, roomy, m); // A | B
    try tree.split(1, .right, 2, roomy, m); // A | (B | C) — 넓을 때는 78 / 38 / 37 열로 정당
    // 화면이 반으로 줌 (drop-down 이 작은 모니터로) — 비율은 그대로라 B · C 가 20 열 미만 (18 / 17, 2026-08-27 실기와 같다).
    const shrunk: Rect = .{ .x = 0, .y = 0, .w = 1512, .h = 1000 };
    var buf: [MAX_PANES_PER_TAB]PaneRect = undefined;
    const b_cols = find(layout(&tree, shrunk, m, &buf), 1).?.cols;
    const c_cols = find(layout(&tree, shrunk, m, &buf), 2).?.cols;
    try std.testing.expectEqual(@as(u16, 18), b_cols);
    try std.testing.expectEqual(@as(u16, 17), c_cols);
    // ① A (25 행) 는 위아래로 갈 자리가 있다 — 예전엔 옆의 B · C 때문에 TooSmall 이었다.
    try tree.split(0, .down, 3, shrunk, m);
    try std.testing.expectEqual(@as(usize, 4), tree.count());
    // ② B 활성에서 왼쪽으로 2 셀 (A|B 선을 왼쪽으로) — B 가 커진다 (예전엔 전체 검사에 걸려 아무 반응 없음). C 는 그대로.
    try std.testing.expect(tree.resize(1, .left, 2, shrunk, m));
    try std.testing.expectEqual(@as(u16, 20), find(layout(&tree, shrunk, m, &buf), 1).?.cols);
    try std.testing.expectEqual(c_cols, find(layout(&tree, shrunk, m, &buf), 2).?.cols);
    // ③ 반대로 줄이기 — A|B 선을 오른쪽으로: B 의 한계가 지금 크기라 그 자리에서 멈춤 = 변화 없음.
    var sbuf: [MAX_PANES_PER_TAB]Separator = undefined;
    var root_x: i32 = -1;
    for (separators(&tree, shrunk, m, &sbuf)) |s| if (s.node == 0) {
        root_x = s.rect.x;
    };
    try std.testing.expect(root_x > 0);
    try std.testing.expect(!tree.setSeparatorPx(0, root_x + 19, shrunk, m));
    // B|C 선을 오른쪽으로 (C 를 더 줄이기) 도 거부 — C 는 이미 최소 아래.
    try std.testing.expect(!tree.resize(1, .right, 1, shrunk, m));
    try std.testing.expectEqual(@as(u16, 20), find(layout(&tree, shrunk, m, &buf), 1).?.cols);
    try std.testing.expectEqual(c_cols, find(layout(&tree, shrunk, m, &buf), 2).?.cols);
    // ④ 작은 pane 자체를 가르는 것은 여전히 TooSmall (두 조각이 20 열 미만).
    try std.testing.expectError(error.TooSmall, tree.split(2, .right, 4, shrunk, m));
}

test "#483 equalize — 비율을 양쪽 leaf 수에 비례시킨다" {
    var tree = Tree.single(1);
    try tree.split(1, .right, 2, wide, mac2x);
    try tree.split(2, .down, 3, wide, mac2x); // 1 | (2 / 3)
    tree.equalize();
    var buf: [MAX_PANES_PER_TAB]PaneRect = undefined;
    const p = layout(&tree, wide, mac2x, &buf);
    // root 1/3 → 3050 / 3 = 1016.7 → (1016.7 − 44) / 19 = 51.2 → 51 열, 1013 px.
    try std.testing.expectEqual(@as(u16, 51), p[0].cols);
    try std.testing.expectEqual(@as(i32, 1013), p[0].rect.w);
    // 오른쪽 둘은 2037 px → 104 열, 위아래 반씩.
    try std.testing.expectEqual(@as(u16, 104), p[1].cols);
    try std.testing.expectEqual(@as(u16, 104), p[2].cols);
    try std.testing.expectEqual(@as(i32, 1800), p[1].rect.h + 2 + p[2].rect.h);

    // 좌우 하나면 그대로 반씩.
    var two = Tree.single(1);
    try two.split(1, .right, 2, wide, mac2x);
    two.equalize();
    const q = layout(&two, wide, mac2x, &buf);
    try std.testing.expectEqual(@as(u16, 78), q[0].cols);
    try std.testing.expectEqual(@as(u16, 77), q[1].cols);
}

test "#483 resize — 1 셀 옮기면 양쪽 열이 정확히 1 씩 바뀌고, 창 가장자리 변이면 반대쪽 분할선이 움직인다" {
    var tree = Tree.single(1);
    try tree.split(1, .right, 2, wide, mac2x); // 78 | 77
    var buf: [MAX_PANES_PER_TAB]PaneRect = undefined;

    // 1 의 오른쪽 변은 분할선 → 오른쪽으로 1 셀: 79 | 76.
    try std.testing.expect(tree.resize(1, .right, 1, wide, mac2x));
    var p = layout(&tree, wide, mac2x, &buf);
    try std.testing.expectEqual(@as(u16, 79), p[0].cols);
    try std.testing.expectEqual(@as(u16, 76), p[1].cols);
    try std.testing.expectEqual(@as(i32, 0), p[0].rect.w - 44 - 79 * 19);

    // 2 의 오른쪽 변은 창 가장자리 → 왼쪽 변의 분할선이 오른쪽으로: 80 | 75.
    try std.testing.expect(tree.resize(2, .right, 1, wide, mac2x));
    p = layout(&tree, wide, mac2x, &buf);
    try std.testing.expectEqual(@as(u16, 80), p[0].cols);
    try std.testing.expectEqual(@as(u16, 75), p[1].cols);

    // 1 의 왼쪽 변은 창 가장자리 → 오른쪽 분할선이 왼쪽으로 2 셀: 78 | 77.
    try std.testing.expect(tree.resize(1, .left, 2, wide, mac2x));
    p = layout(&tree, wide, mac2x, &buf);
    try std.testing.expectEqual(@as(u16, 78), p[0].cols);
    try std.testing.expectEqual(@as(u16, 77), p[1].cols);

    // 2 의 왼쪽 변은 분할선 → 왼쪽으로: 77 | 78.
    try std.testing.expect(tree.resize(2, .left, 1, wide, mac2x));
    p = layout(&tree, wide, mac2x, &buf);
    try std.testing.expectEqual(@as(u16, 77), p[0].cols);
    try std.testing.expectEqual(@as(u16, 78), p[1].cols);

    // 상하 분할이 없으니 위아래로는 옮길 분할선이 없다.
    try std.testing.expect(!tree.resize(1, .up, 1, wide, mac2x));
    try std.testing.expect(!tree.resize(2, .down, 1, wide, mac2x));

    // 최소 크기 — 뒤 pane 이 20 열이 될 때까지만 자라고, 다음 한 번은 거부되며 트리는 그대로.
    while (tree.resize(1, .right, 1, wide, mac2x)) {}
    p = layout(&tree, wide, mac2x, &buf);
    try std.testing.expectEqual(@as(u16, 20), p[1].cols);
    try std.testing.expectEqual(@as(u16, 135), p[0].cols);
    var again: [MAX_PANES_PER_TAB]PaneRect = undefined;
    try std.testing.expect(!tree.resize(1, .right, 1, wide, mac2x));
    try std.testing.expectEqualDeep(p, layout(&tree, wide, mac2x, &again));

    try std.testing.expect(!tree.resize(42, .right, 1, wide, mac2x));
}

test "#483 paneAt / cellAt — half-open 경계, 분할선 · padding · scrollbar 자리는 null" {
    var tree = Tree.single(1);
    try tree.split(1, .right, 2, wide, mac2x); // 1: x 0..1526 · 분할선 1526..1528 · 2: x 1528..3052
    var buf: [MAX_PANES_PER_TAB]PaneRect = undefined;
    const p = layout(&tree, wide, mac2x, &buf);

    try std.testing.expectEqual(@as(?PaneId, 1), paneAt(p, 0, 0));
    try std.testing.expectEqual(@as(?PaneId, 1), paneAt(p, 1525, 1799));
    try std.testing.expectEqual(@as(?PaneId, null), paneAt(p, 1526, 100));
    try std.testing.expectEqual(@as(?PaneId, null), paneAt(p, 1527, 100));
    try std.testing.expectEqual(@as(?PaneId, 2), paneAt(p, 1528, 0));
    try std.testing.expectEqual(@as(?PaneId, 2), paneAt(p, 3051, 1799));
    try std.testing.expectEqual(@as(?PaneId, null), paneAt(p, 3052, 0));
    try std.testing.expectEqual(@as(?PaneId, null), paneAt(p, 0, -1));
    try std.testing.expectEqual(@as(?PaneId, null), paneAt(p, 0, 1800));

    // 셀 — 격자 원점은 rect + pad. padding 안은 null.
    try std.testing.expectEqual(@as(?Cell, .{ .col = 0, .row = 0 }), cellAt(p[0], 12, 12, mac2x));
    try std.testing.expectEqual(@as(?Cell, null), cellAt(p[0], 11, 12, mac2x));
    try std.testing.expectEqual(@as(?Cell, null), cellAt(p[0], 12, 11, mac2x));
    try std.testing.expectEqual(@as(?Cell, .{ .col = 1, .row = 1 }), cellAt(p[0], 12 + 19, 12 + 39, mac2x));
    // 마지막 열의 마지막 px 은 셀, 그 다음 px 은 scrollbar 자리 (앞 pane 은 남는 px 이 0).
    try std.testing.expectEqual(@as(?Cell, .{ .col = 77, .row = 0 }), cellAt(p[0], 12 + 78 * 19 - 1, 12, mac2x));
    try std.testing.expectEqual(@as(?Cell, null), cellAt(p[0], 12 + 78 * 19, 12, mac2x));
    // 뒤 pane — 원점이 자기 rect 기준. 마지막 열 다음은 남는 px 라 null.
    try std.testing.expectEqual(@as(?Cell, .{ .col = 0, .row = 0 }), cellAt(p[1], 1528 + 12, 12, mac2x));
    try std.testing.expectEqual(@as(?Cell, null), cellAt(p[1], 1528 + 12 + 77 * 19, 12, mac2x));
    // 마지막 행 다음은 null. rows = ⌊(1800 − 24) / 39⌋ = 45.
    try std.testing.expectEqual(@as(u16, 45), p[0].rows);
    try std.testing.expectEqual(@as(?Cell, .{ .col = 0, .row = 44 }), cellAt(p[0], 12, 12 + 44 * 39, mac2x));
    try std.testing.expectEqual(@as(?Cell, null), cellAt(p[0], 12, 12 + 45 * 39, mac2x));
}

test "#483 neighbor — 기하 기반: 2×2 격자, 그리고 트리에서는 사촌인 화면상 이웃" {
    var grid = Tree.single(1);
    try grid.split(1, .right, 2, wide, mac2x); // 1 | 2
    try grid.split(1, .down, 3, wide, mac2x); // (1 / 3) | 2
    try grid.split(2, .down, 4, wide, mac2x); // (1 / 3) | (2 / 4)
    var buf: [MAX_PANES_PER_TAB]PaneRect = undefined;
    const p = layout(&grid, wide, mac2x, &buf);
    try std.testing.expectEqual(@as(usize, 4), p.len);

    try std.testing.expectEqual(@as(?PaneId, 2), neighbor(p, 1, .right, null));
    try std.testing.expectEqual(@as(?PaneId, 3), neighbor(p, 1, .down, null));
    try std.testing.expectEqual(@as(?PaneId, 4), neighbor(p, 3, .right, null));
    try std.testing.expectEqual(@as(?PaneId, 1), neighbor(p, 3, .up, null));
    try std.testing.expectEqual(@as(?PaneId, 1), neighbor(p, 2, .left, null));
    try std.testing.expectEqual(@as(?PaneId, 4), neighbor(p, 2, .down, null));
    try std.testing.expectEqual(@as(?PaneId, 3), neighbor(p, 4, .left, null));
    try std.testing.expectEqual(@as(?PaneId, 2), neighbor(p, 4, .up, null));
    // 창 가장자리 쪽은 없다.
    try std.testing.expectEqual(@as(?PaneId, null), neighbor(p, 1, .left, null));
    try std.testing.expectEqual(@as(?PaneId, null), neighbor(p, 1, .up, null));
    try std.testing.expectEqual(@as(?PaneId, null), neighbor(p, 4, .right, null));
    try std.testing.expectEqual(@as(?PaneId, null), neighbor(p, 3, .down, null));

    // 사촌 — 1 | (2 / 4). 오른쪽으로 갈 때 anchor (커서 y) 가 위 · 아래를 가른다.
    var cousin = Tree.single(1);
    try cousin.split(1, .right, 2, wide, mac2x);
    try cousin.split(2, .down, 4, wide, mac2x);
    var cbuf: [MAX_PANES_PER_TAB]PaneRect = undefined;
    const q = layout(&cousin, wide, mac2x, &cbuf);
    const top = find(q, 2).?;
    const bottom = find(q, 4).?;
    try std.testing.expectEqual(@as(?PaneId, 2), neighbor(q, 1, .right, top.rect.y));
    try std.testing.expectEqual(@as(?PaneId, 4), neighbor(q, 1, .right, bottom.rect.y + 10));
    // 중점 (y 900) 은 위 pane (0..882) 을 지나 아래 pane 안이다.
    try std.testing.expectEqual(@as(i32, 882), top.rect.h);
    try std.testing.expectEqual(@as(?PaneId, 4), neighbor(q, 1, .right, null));
    // 광선이 분할선 틈 (882..884) 에 떨어지면 가까운 쪽 — 882 는 위에서 1 px, 아래에서 2 px.
    try std.testing.expectEqual(@as(?PaneId, 2), neighbor(q, 1, .right, 882));
    try std.testing.expectEqual(@as(?PaneId, 4), neighbor(q, 1, .right, 883));
    // 4 → 왼쪽은 트리에서 사촌이지만 화면에서는 바로 옆인 1. 2 도 같다.
    try std.testing.expectEqual(@as(?PaneId, 1), neighbor(q, 4, .left, null));
    try std.testing.expectEqual(@as(?PaneId, 1), neighbor(q, 2, .left, null));
    try std.testing.expectEqual(@as(?PaneId, 4), neighbor(q, 2, .down, null));
    try std.testing.expectEqual(@as(?PaneId, 2), neighbor(q, 4, .up, null));

    try std.testing.expectEqual(@as(?PaneId, null), neighbor(q, 42, .left, null));
}

test "#483 separators — 개수는 pane − 1 이고 어느 pane 과도 겹치지 않는다" {
    var grid = Tree.single(1);
    try grid.split(1, .right, 2, wide, mac2x);
    try grid.split(1, .down, 3, wide, mac2x);
    try grid.split(2, .down, 4, wide, mac2x); // (1 / 3) | (2 / 4)
    var buf: [MAX_PANES_PER_TAB]PaneRect = undefined;
    const p = layout(&grid, wide, mac2x, &buf);
    var sbuf: [MAX_PANES_PER_TAB]Separator = undefined;
    const seps = separators(&grid, wide, mac2x, &sbuf);
    try std.testing.expectEqual(@as(usize, 3), seps.len);

    // 세로 하나 (창 높이 전체) · 가로 둘 (각 열의 폭).
    var vertical: usize = 0;
    for (seps) |s| {
        if (s.axis == .side_by_side) {
            vertical += 1;
            try std.testing.expectEqual(Rect{ .x = 1526, .y = 0, .w = 2, .h = 1800 }, s.rect);
        } else {
            try std.testing.expectEqual(@as(i32, 882), s.rect.y);
            try std.testing.expectEqual(@as(i32, 2), s.rect.h);
            try std.testing.expect(s.rect.w == 1526 or s.rect.w == 1524);
        }
        // 어느 pane 의 rect 와도 겹치지 않는다.
        for (p) |pr| {
            const overlap = s.rect.x < pr.rect.x + pr.rect.w and s.rect.x + s.rect.w > pr.rect.x and
                s.rect.y < pr.rect.y + pr.rect.h and s.rect.y + s.rect.h > pr.rect.y;
            try std.testing.expect(!overlap);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), vertical);
}

test "#483 Direction — 축과 second 쪽" {
    try std.testing.expectEqual(Axis.side_by_side, Direction.left.axis());
    try std.testing.expectEqual(Axis.side_by_side, Direction.right.axis());
    try std.testing.expectEqual(Axis.stacked, Direction.up.axis());
    try std.testing.expectEqual(Axis.stacked, Direction.down.axis());
    try std.testing.expect(Direction.right.towardSecond());
    try std.testing.expect(Direction.down.towardSecond());
    try std.testing.expect(!Direction.left.towardSecond());
    try std.testing.expect(!Direction.up.towardSecond());
    // 결정 1 — 상한과 pool 크기.
    try std.testing.expectEqual(@as(usize, 16), MAX_PANES_PER_TAB);
    try std.testing.expectEqual(@as(usize, 31), MAX_NODES);
}
