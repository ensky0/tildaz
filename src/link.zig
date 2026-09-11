//! 마우스 아래에 링크가 있는지 판정한다 ([#647](https://github.com/ensky0/tildaz/issues/647)
//! 2 단계, 요청은 [#643](https://github.com/ensky0/tildaz/issues/643)).
//!
//! 두 종류를 본다. **OSC 8 하이퍼링크가 먼저**고 (앱이 명시적으로 만든 링크다), 없으면
//! **화면 글자에서 URL 을 찾는다** (`url_scan.zig`). 실측으로 후자가 이 요청의 본체다 —
//! `gh` 는 OSC 8 을 쓰지 않고 PR URL 을 맨 글자로 뱉는다 (#647 본문).
//!
//! **읽는 대상은 `RenderState` 다.** `Screen` 이 아니라 렌더 스냅숏을 보는 이유는 두 가지다.
//! ① 화면에 그려진 것과 판정이 같은 프레임을 본다 — 사용자가 가리킨 글자가 곧 판정 대상이다.
//! ② 3 단계의 강조 (`RenderState.Row.highlights`) 와 같은 좌표계를 쓴다.
//!
//! ⚠️ **`state.update` 직후에만 부른다.** `RenderState.Row.pin` 의 주석이 *"its node must not
//! be dereferenced unless the terminal state is protected from changes since the last `update`
//! call"* 이라고 적는다. tildaz 는 터미널 상태를 메인 스레드가 단독 소유하므로 (드레인 · 렌더 ·
//! 입력이 한 스레드) 그 사이에 바뀌지 않지만, 호출 자리를 옮길 때 이 전제를 같이 옮겨야 한다.

const std = @import("std");
const ghostty = @import("ghostty-vt");
const url_scan = @import("url_scan.zig");
const log = @import("log.zig");
const system_open = @import("system_open.zig");
const Runtime = @import("runtime.zig").Runtime;
const cell_highlight = @import("cell_highlight.zig");

/// 링크를 기본 브라우저로 연다. 세 host 가 이 함수 하나를 부른다.
///
/// **로그를 여기서 남기는 이유가 이 함수의 존재 이유다.** 여는 것 자체는
/// `system_open.openInDefaultApp` 한 줄인데, 그것만으로는 "클릭이 링크로 판정됐는지" 와
/// "OS 가 열었는지" 를 가를 수 없다 — 브라우저가 안 뜨면 우리가 안 부른 것인지 OS 가 무시한
/// 것인지 모른다. 실기 검증의 판정선이자 (`#647` 5 단계) 사용자가 이슈에 붙이는 진단 자료다.
///
/// 로그는 영어다 (AGENTS.md `# 메시지 언어` — 로그는 format string 과 인자까지 영어).
pub fn open(rt: Runtime, alloc: std.mem.Allocator, url: []const u8) void {
    log.appendLine("link", "opening link: {s}", .{url});
    system_open.openInDefaultApp(rt, alloc, url);
}

/// 화면(viewport) 셀 좌표.
pub const Coord = struct {
    x: u16,
    y: u16,
};

/// 무엇으로 찾았는가. 강조 · 로그 · 테스트가 구분한다.
pub const Source = enum {
    /// OSC 8 — 앱이 `ESC ] 8 ; ; <uri> ESC \` 로 명시한 링크.
    osc8,
    /// 화면 글자에서 찾은 URL.
    text,
};

/// 마우스 아래에서 찾은 링크. `url` 과 `cells` 는 호출자가 준 allocator 의 것이다.
pub const Hit = struct {
    /// 열 대상. `system_open.openInDefaultApp` 에 그대로 넘긴다.
    url: []const u8,
    source: Source,
    /// 강조할 셀들 (viewport 좌표). OSC 8 은 **연속이 아닐 수 있다** — 같은 `id` 로 묶인
    /// 조각이 화면 여러 곳에 흩어질 수 있는 것이 OSC 8 의 사양이라, 배열로 둔다.
    cells: []const Coord,

    pub fn deinit(self: *Hit, alloc: std.mem.Allocator) void {
        alloc.free(self.url);
        alloc.free(self.cells);
        self.* = undefined;
    }

    /// 같은 링크를 가리키는가. hover 가 바뀌었는지 판정해 불필요한 재그리기를 막는다.
    pub fn eql(self: *const Hit, other: *const Hit) bool {
        if (self.source != other.source) return false;
        if (!std.mem.eql(u8, self.url, other.url)) return false;
        if (self.cells.len != other.cells.len) return false;
        for (self.cells, other.cells) |a, b| {
            if (a.x != b.x or a.y != b.y) return false;
        }
        return true;
    }

    pub fn covers(self: *const Hit, at: Coord) bool {
        for (self.cells) |c| {
            if (c.x == at.x and c.y == at.y) return true;
        }
        return false;
    }
};

/// `at` 을 덮는 링크. 없으면 `null`.
///
/// OSC 8 을 먼저 보는 이유는 **앱이 명시한 것이 화면 글자보다 정확**하기 때문이다. OSC 8 링크의
/// 표시 글자는 `click here` 처럼 URL 과 무관할 수 있고, 반대로 표시 글자가 URL 처럼 보여도 실제
/// 목적지는 다를 수 있다.
pub fn hitTest(
    alloc: std.mem.Allocator,
    state: *const ghostty.RenderState,
    at: Coord,
) std.mem.Allocator.Error!?Hit {
    if (state.cols == 0) return null;
    if (at.x >= state.cols) return null;
    if (at.y >= state.row_data.len) return null;

    if (try hitOsc8(alloc, state, at)) |hit| return hit;
    return try hitText(alloc, state, at);
}

// ── OSC 8 ────────────────────────────────────────────────────────────────────

fn hitOsc8(
    alloc: std.mem.Allocator,
    state: *const ghostty.RenderState,
    at: Coord,
) std.mem.Allocator.Error!?Hit {
    const row_slice = state.row_data.slice();
    const pin = row_slice.items(.pin)[at.y];
    const page = pin.node.page();
    const rac = page.getRowAndCell(at.x, pin.y);
    if (!rac.cell.hyperlink) return null;

    const id = page.lookupHyperlink(rac.cell) orelse return null;
    const entry = page.hyperlink_set.get(page.memory, id);
    const uri = entry.uri.slice(page.memory);
    if (!isOpenableUri(uri)) return null;

    // 같은 링크에 속한 셀 전체. ghostty 가 URI 를 비교해 묶어 주므로 (`render.zig` 의
    // `linkCells`) 조각난 링크도 한 번에 온다.
    var set = try state.linkCells(alloc, .{ .x = at.x, .y = at.y });
    defer set.deinit(alloc);
    if (set.count() == 0) return null;

    const cells = try alloc.alloc(Coord, set.count());
    errdefer alloc.free(cells);
    for (set.keys(), 0..) |k, i| cells[i] = .{ .x = @intCast(k.x), .y = @intCast(k.y) };

    const url = try alloc.dupe(u8, uri);
    return .{ .url = url, .source = .osc8, .cells = cells };
}

/// 브라우저에 넘겨도 되는 URI 인가.
///
/// OSC 8 의 URI 는 **터미널에 출력된 임의의 바이트**다. 셸 주입은 구조적으로 없지만
/// (`openInDefaultApp` 이 `argv` 배열로 spawn 하고 Windows 는 `ShellExecuteW` 에 인자를 따로
/// 넘긴다) 그래도 두 가지는 거른다.
///
/// - **제어문자 · 공백** — 인자 하나로 넘어가는 값에 개행이나 `NUL` 이 섞여 들어갈 이유가 없다.
/// - **scheme 이 없는 것** — `foo/bar` 같은 값을 그대로 넘기면 OS 마다 상대 경로 · 검색어로
///   달리 해석된다. 최소한 `scheme:` 꼴은 요구한다.
///
/// **scheme 화이트리스트는 두지 않는다.** OSC 8 은 앱이 자기 목적으로 만든 링크라
/// `vscode://` · `slack://` 처럼 우리가 모르는 scheme 이 정당하게 쓰인다. 목록으로 막으면
/// 쓸모를 깎는 대신 얻는 안전이 없다 — 실제 실행 여부는 OS 의 handler 등록이 정한다.
fn isOpenableUri(uri: []const u8) bool {
    if (uri.len == 0) return false;

    var colon: ?usize = null;
    for (uri, 0..) |c, i| {
        if (c <= 0x20 or c == 0x7f) return false;
        if (c == ':' and colon == null) colon = i;
    }

    // `scheme:` — RFC 3986 의 scheme 은 ALPHA 로 시작하고 ALPHA / DIGIT / `+` `-` `.` 가 잇는다.
    const end = colon orelse return false;
    if (end == 0) return false;
    if (!std.ascii.isAlphabetic(uri[0])) return false;
    for (uri[1..end]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return true;
}

// ── 화면 글자에서 찾는 URL ───────────────────────────────────────────────────

fn hitText(
    alloc: std.mem.Allocator,
    state: *const ghostty.RenderState,
    at: Coord,
) std.mem.Allocator.Error!?Hit {
    const span = logicalRow(state, at.y);

    // 논리 줄의 codepoint. 셀 하나에 항목 하나라 인덱스가 곧 `(행, 열)` 이다.
    const cols: usize = state.cols;
    const count = (span.end - span.start + 1) * cols;
    const text = try alloc.alloc(u21, count);
    defer alloc.free(text);

    const row_slice = state.row_data.slice();
    const row_cells = row_slice.items(.cells);
    var w: usize = 0;
    for (span.start..span.end + 1) |y| {
        for (row_cells[y].items(.raw)) |cell| {
            text[w] = cell.codepoint();
            w += 1;
        }
        // 행이 `cols` 보다 짧을 일은 없지만 (`RenderState` 가 보장한다) 방어적으로 채운다.
        while (w < (y - span.start + 1) * cols) : (w += 1) text[w] = 0;
    }

    const index = (at.y - span.start) * cols + at.x;
    const range = url_scan.findAt(text, index) orelse return null;

    const cells = try alloc.alloc(Coord, range.len());
    errdefer alloc.free(cells);
    for (range.start..range.end, 0..) |i, n| cells[n] = .{
        .x = @intCast(i % cols),
        .y = @intCast(span.start + i / cols),
    };

    var url: std.ArrayList(u8) = .empty;
    errdefer url.deinit(alloc);
    var buf: [4]u8 = undefined;
    for (text[range.start..range.end]) |c| {
        const n = std.unicode.utf8Encode(c, &buf) catch continue;
        try url.appendSlice(alloc, buf[0..n]);
    }

    return .{
        .url = try url.toOwnedSlice(alloc),
        .source = .text,
        .cells = cells,
    };
}

const RowSpan = struct { start: u16, end: u16 };

/// `y` 가 속한 **논리 줄**의 viewport 행 범위 (양끝 포함).
///
/// 터미널은 창 폭에서 줄을 접으므로 (`row.wrap`) 긴 URL 은 여러 행에 걸친다. `gh` 가 뱉는 PR
/// URL 이 80 열에서 접히는 것이 정확히 이 경우라, 이어 붙이지 않으면 요청의 주 시나리오를 반쪽만
/// 덮는다.
///
/// 스크롤백 경계는 넘지 않는다 — viewport 밖은 `RenderState` 에 없다. 화면 위쪽으로 이어진
/// URL 은 보이는 부분까지만 잡히는데, 그 조각도 대개 `https://` 를 포함하지 않아 애초에 매치되지
/// 않는다.
fn logicalRow(state: *const ghostty.RenderState, y: u16) RowSpan {
    const raws = state.row_data.slice().items(.raw);
    var start = y;
    while (start > 0 and raws[start].wrap_continuation) start -= 1;
    var end = y;
    while (end + 1 < raws.len and raws[end].wrap) end += 1;
    return .{ .start = start, .end = end };
}

// ── hover 상태 ───────────────────────────────────────────────────────────────

/// 지금 마우스가 가리키는 링크. **창마다 하나**다 — 포인터가 하나라서 pane 이 여럿이어도
/// hover 는 한 곳이다 (검색이 pane 별 상태인 것과 다른 축이다, [#646](https://github.com/ensky0/tildaz/issues/646)).
///
/// 세 host 가 이 상태 기계 하나를 공유한다. host 가 하는 일은 좌표를 셀로 바꿔 `update` 를
/// 부르고, 반환이 `true` 면 다시 그리는 것뿐이다.
///
/// **보이는 것과 되는 것을 일치시킨다 — 밑줄이 있으면 클릭하면 열린다.**
///
/// 두 번의 사용자 지적으로 여기까지 왔다 (2026-09-11).
///
/// 1. *"ctrl 을 안 눌러도 밑줄은 보여야 하는 거 아냐? 우선 click 가능한 건지 알아야 클릭할
///    생각을 하지"* — 수식키를 눌러야 밑줄이 뜨면 링크인 줄 모르는 사람은 수식키를 누를
///    이유가 없다 (순환). 그래서 hover 만으로 밑줄을 켰다.
/// 2. *"밑줄이 보이니까 바로 클릭하면 링크가 열릴 것 같은데 안 열려. cmd 를 눌러야만 열려.
///    이거 이상해"* — 밑줄은 "클릭하면 열린다" 는 신호인데 수식키를 요구하면 어긋난다.
///
/// 그래서 **kitty 의 모델**을 따른다 — 기본 `mouse_map left click ungrabbed …` 이 수식키
/// 없이 좌클릭으로 링크를 열고, `ungrabbed` (앱이 마우스를 잡지 않았을 때) 라는 조건이 붙는다.
/// 그 조건을 `Probe.active` 가 담는다. Windows Terminal · VS Code 는 수식키를 요구하는 대신
/// *툴팁* 으로 어긋남을 메우는데, 우리에겐 툴팁 자리가 없다.
pub const Hover = struct {
    hit: ?Hit = null,
    /// 마지막 판정 입력. 같으면 다시 판정하지 않는다 — motion 은 픽셀마다 오지만 판정이
    /// 달라지는 것은 셀 · 수식키 · pane 이 바뀔 때뿐이다.
    probe: ?Probe = null,
    /// 강조를 다시 칠해야 하는가. `update` · `clear` 가 세우고 `applyHighlights` 가 내린다.
    highlights_dirty: bool = false,
    /// 지금 `RenderState` 에 우리 강조가 올라가 있는가. 링크가 없어졌을 때 **지울 것이
    /// 있는지**를 이걸로 알아서, 아무 일도 없는 프레임에 행을 순회하지 않는다.
    painted: bool = false,

    pub const Probe = struct {
        /// 포인터가 있는 셀. 셀 영역 밖 (탭바 · padding · 스크롤바 · 창 밖) 이면 `null`.
        cell: ?Coord,
        /// **지금 이 클릭이 링크로 갈 수 있는가.** 아니면 링크로 치지 않는다 — 밑줄도 손
        /// 커서도 없고 클릭도 앱에 간다.
        ///
        /// host 가 `앱이 마우스를 잡지 않았다 or 수식키가 눌렸다` 로 계산한다. 앱이
        /// mouse tracking 을 켠 동안 (vim · htop) 클릭은 앱 것이라, 그때 밑줄을 보여 주면
        /// 또 "보이는데 안 열리는" 어긋남이 된다 (#647 · kitty 의 `ungrabbed` 조건).
        active: bool,
        /// 어느 pane 의 화면인가. 같은 셀 좌표여도 pane 이 다르면 다른 글자다.
        pane: u64,

        fn eql(self: Probe, other: Probe) bool {
            if (self.active != other.active or self.pane != other.pane) return false;
            if (self.cell == null and other.cell == null) return true;
            const a = self.cell orelse return false;
            const b = other.cell orelse return false;
            return a.x == b.x and a.y == b.y;
        }
    };

    pub fn deinit(self: *Hover, alloc: std.mem.Allocator) void {
        if (self.hit) |*h| h.deinit(alloc);
        self.* = .{};
    }

    /// 이 입력으로 판정을 다시 해야 하는가.
    ///
    /// host 가 `update` 를 부르기 **전에** 물어서, 필요 없으면 `RenderState.update` 까지
    /// 건너뛴다. 포인터 motion 은 픽셀마다 오지만 판정이 달라지는 것은 셀 · 수식키 · pane 이
    /// 바뀔 때뿐이라, 이게 없으면 마우스를 움직이는 내내 스냅숏을 갱신하게 된다.
    pub fn needsUpdate(self: *const Hover, probe: Probe) bool {
        const p = self.probe orelse return true;
        return !p.eql(probe);
    }

    /// 화면 내용이 바뀌었으니 다음 `update` 는 반드시 다시 판정하라.
    ///
    /// 포인터가 가만히 있어도 그 자리의 **글자가** 바뀌면 (출력 · 스크롤) 판정이 달라진다.
    /// host 는 드레인이 화면을 바꾼 프레임에 이것을 부른다.
    pub fn invalidate(self: *Hover) void {
        self.probe = null;
    }

    /// 판정을 갱신한다. **화면에 보이는 것이 달라졌으면 `true`** — host 는 그때만 다시 그린다.
    ///
    /// ⚠️ `state` 는 `update` 직후여야 한다 (모듈 머리 주석).
    pub fn update(
        self: *Hover,
        alloc: std.mem.Allocator,
        state: *const ghostty.RenderState,
        probe: Probe,
    ) std.mem.Allocator.Error!bool {
        if (self.probe) |p| {
            if (p.eql(probe)) return false;
        }
        self.probe = probe;

        var found: ?Hit = null;
        if (probe.active) {
            if (probe.cell) |c| found = try hitTest(alloc, state, c);
        }

        // 같은 링크면 그리기가 달라지지 않는다 — 한 링크 안에서 칸을 옮길 때가 그렇다.
        if (self.hit) |*old| {
            if (found) |*new| {
                if (old.eql(new)) {
                    new.deinit(alloc);
                    return false;
                }
            }
        } else if (found == null) return false;

        if (self.hit) |*old| old.deinit(alloc);
        self.hit = found;
        self.highlights_dirty = true;
        return true;
    }

    /// hover 를 지운다 (포인터가 창을 떠남 · 창이 포커스를 잃음). 달라졌으면 `true`.
    pub fn clear(self: *Hover, alloc: std.mem.Allocator) bool {
        self.probe = null;
        if (self.hit) |*h| {
            h.deinit(alloc);
            self.hit = null;
            self.highlights_dirty = true;
            return true;
        }
        return false;
    }

    /// hover 중인 링크를 `RenderState` 의 per-row 강조로 칠한다. **`state.update` 직후**에
    /// 부른다 — row 가 재구축된 뒤라야 칠할 자리가 있다.
    ///
    /// 세 renderer 가 각자 계산하지 않고 이 한 함수를 쓴다 — 검색의
    /// `search.PaneSearch.applyHighlights` 와 같은 자리 · 같은 규칙이다 (AGENTS.md 의 single
    /// definition). renderer 는 결과 (`row_data.items(.highlights)`) 만 읽는다.
    ///
    /// **아무 일도 없는 프레임에는 행을 순회하지 않는다.** 링크는 마우스가 움직일 때마다 후보가
    /// 바뀌어서 검색보다 자주 불린다 — 조기 반환이 없으면 hover 가 없는 사용자도 프레임마다
    /// 전체 행을 훑는다 (#646 이 `d1b6b41` 에서 같은 것을 고쳤다).
    pub fn applyHighlights(
        self: *Hover,
        alloc: std.mem.Allocator,
        state: *ghostty.RenderState,
    ) void {
        if (self.hit == null and !self.painted) return;
        if (!self.highlights_dirty and state.dirty == .false) return;
        self.highlights_dirty = false;

        // **우리 tag 만** 지운다 — 같은 행에 검색 매치가 함께 있을 수 있다. 계약은
        // `cell_highlight.zig` 에 있다.
        _ = cell_highlight.clear(state, &.{.link_hover});
        self.painted = false;

        const hit = self.hit orelse return;

        // 셀 목록을 **행별 연속 구간**으로 묶어 칠한다. OSC 8 은 조각이 흩어질 수 있어
        // (같은 `id` 로 묶인 링크의 사양) 구간이 여럿 나올 수 있다.
        //
        // 목록이 `(y, x)` 오름차순이라는 가정을 **하지 않는다** — 정렬돼 있지 않으면 구간이
        // 잘게 쪼개질 뿐 결과는 같다. 지금 두 경로는 모두 오름차순이다.
        var i: usize = 0;
        while (i < hit.cells.len) {
            const start = hit.cells[i];
            var end_x = start.x;
            var j = i + 1;
            while (j < hit.cells.len and
                hit.cells[j].y == start.y and
                hit.cells[j].x == end_x + 1) : (j += 1)
            {
                end_x = hit.cells[j].x;
            }
            cell_highlight.add(state, alloc, .link_hover, start.y, start.x, end_x) catch {
                // 이번 프레임만 표시가 빠진다 — 다음 프레임이 같은 자리에서 다시 시도한다.
                self.highlights_dirty = true;
                return;
            };
            i = j;
        }
        self.painted = true;
    }

    /// 그 셀에서 열 URL. 클릭 · 커서 판정이 함께 쓴다.
    ///
    /// `null` 이 아니면 **밑줄이 그려져 있다는 뜻**이기도 하다 — 그래서 이것만 보면 "보이는
    /// 것과 되는 것" 이 저절로 맞는다. 앱이 마우스를 잡았는데 수식키를 안 누른 상태는
    /// `Probe.active` 가 false 라 `hit` 자체가 없다.
    ///
    /// **지금 hover 중인 링크만 본다.** 다시 `hitTest` 하지 않는 이유는 두 가지다 — ① 사용자가
    /// *본* 것 (밑줄이 그려진 것) 과 여는 것이 같아야 한다. ② 클릭 시점에 다시 판정하면 그 사이
    /// 출력이 화면을 밀었을 때 엉뚱한 링크가 열린다.
    pub fn urlAt(self: *const Hover, at: Coord) ?[]const u8 {
        const h = self.hit orelse return null;
        if (!h.covers(at)) return null;
        return h.url;
    }
};

// ── 테스트 ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// `cols` × `rows` 터미널에 `content` 를 찍고 `RenderState` 까지 만들어 준다.
const Fixture = struct {
    term: ghostty.Terminal,
    state: ghostty.RenderState,

    fn init(alloc: std.mem.Allocator, cols: u16, rows: u16) !Fixture {
        return .{
            .term = try ghostty.Terminal.init(testing.io, alloc, .{
                .cols = cols,
                .rows = rows,
                .max_scrollback_lines = 100,
                .max_scrollback_bytes = null,
            }),
            .state = .empty,
        };
    }

    fn sync(self: *Fixture, alloc: std.mem.Allocator) !void {
        try self.state.update(alloc, &self.term);
    }

    fn deinit(self: *Fixture, alloc: std.mem.Allocator) void {
        self.state.deinit(alloc);
        self.term.deinit(alloc);
    }
};

test "#647 화면 글자에서 URL 을 찾는다" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 60, 5);
    defer f.deinit(alloc);
    try f.term.printString("see https://example.com/pr/1 for details");
    try f.sync(alloc);

    // `see ` 가 0..3 이므로 URL 은 4 부터.
    var hit = (try hitTest(alloc, &f.state, .{ .x = 4, .y = 0 })).?;
    defer hit.deinit(alloc);
    try testing.expectEqualStrings("https://example.com/pr/1", hit.url);
    try testing.expectEqual(Source.text, hit.source);
    try testing.expectEqual(@as(usize, 24), hit.cells.len);
    try testing.expect(hit.covers(.{ .x = 4, .y = 0 }));
    try testing.expect(hit.covers(.{ .x = 27, .y = 0 }));
    try testing.expect(!hit.covers(.{ .x = 28, .y = 0 }));
}

test "#647 링크가 없는 자리는 null" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 60, 5);
    defer f.deinit(alloc);
    try f.term.printString("see https://example.com for details");
    try f.sync(alloc);

    // 앞의 `see`, URL 뒤 공백, 빈 행, 범위 밖.
    try testing.expect(try hitTest(alloc, &f.state, .{ .x = 1, .y = 0 }) == null);
    try testing.expect(try hitTest(alloc, &f.state, .{ .x = 28, .y = 0 }) == null);
    try testing.expect(try hitTest(alloc, &f.state, .{ .x = 0, .y = 2 }) == null);
    try testing.expect(try hitTest(alloc, &f.state, .{ .x = 99, .y = 0 }) == null);
    try testing.expect(try hitTest(alloc, &f.state, .{ .x = 0, .y = 99 }) == null);
}

test "#647 줄을 넘어간 URL 을 이어 붙인다" {
    const alloc = testing.allocator;
    // 20 열이라 URL 이 접힌다.
    var f = try Fixture.init(alloc, 20, 5);
    defer f.deinit(alloc);
    try f.term.printString("https://example.com/a/very/long/path");
    try f.sync(alloc);

    // 첫 행 · 둘째 행 어디를 가리켜도 같은 URL 이 나온다.
    var first = (try hitTest(alloc, &f.state, .{ .x = 0, .y = 0 })).?;
    defer first.deinit(alloc);
    try testing.expectEqualStrings("https://example.com/a/very/long/path", first.url);

    var second = (try hitTest(alloc, &f.state, .{ .x = 3, .y = 1 })).?;
    defer second.deinit(alloc);
    try testing.expectEqualStrings("https://example.com/a/very/long/path", second.url);
    try testing.expect(first.eql(&second));

    // 강조 셀이 두 행에 걸친다.
    var rows_seen: [2]bool = .{ false, false };
    for (first.cells) |c| {
        if (c.y < 2) rows_seen[c.y] = true;
    }
    try testing.expect(rows_seen[0] and rows_seen[1]);
}

test "#647 OSC 8 하이퍼링크가 글자보다 우선한다" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 60, 5);
    defer f.deinit(alloc);

    // 표시 글자는 URL 처럼 보이지만 실제 목적지는 다르다 — OSC 8 을 봐야 맞는 곳으로 간다.
    const screen = f.term.screens.active;
    try screen.startHyperlink("https://real.example/target", null);
    try f.term.printString("https://fake.example");
    screen.endHyperlink();
    try f.sync(alloc);

    var hit = (try hitTest(alloc, &f.state, .{ .x = 3, .y = 0 })).?;
    defer hit.deinit(alloc);
    try testing.expectEqualStrings("https://real.example/target", hit.url);
    try testing.expectEqual(Source.osc8, hit.source);
    try testing.expectEqual(@as(usize, 20), hit.cells.len);
}

test "#647 OSC 8 이 끝난 뒤의 글자는 다시 글자 판정이다" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 60, 5);
    defer f.deinit(alloc);

    const screen = f.term.screens.active;
    try screen.startHyperlink("https://real.example/target", null);
    try f.term.printString("click");
    screen.endHyperlink();
    try f.term.printString(" https://plain.example");
    try f.sync(alloc);

    var linked = (try hitTest(alloc, &f.state, .{ .x = 2, .y = 0 })).?;
    defer linked.deinit(alloc);
    try testing.expectEqual(Source.osc8, linked.source);

    var plain = (try hitTest(alloc, &f.state, .{ .x = 8, .y = 0 })).?;
    defer plain.deinit(alloc);
    try testing.expectEqual(Source.text, plain.source);
    try testing.expectEqualStrings("https://plain.example", plain.url);
}

test "#647 열 수 없는 OSC 8 URI 는 무시한다" {
    // 제어문자 · 공백 · scheme 없음.
    try testing.expect(!isOpenableUri(""));
    try testing.expect(!isOpenableUri("foo/bar"));
    try testing.expect(!isOpenableUri("://no-scheme"));
    try testing.expect(!isOpenableUri("1http://digit-first"));
    try testing.expect(!isOpenableUri("https://a b"));
    try testing.expect(!isOpenableUri("https://a\nb"));
    try testing.expect(!isOpenableUri("https://a\x00b"));

    // 우리가 모르는 scheme 도 통과시킨다 — 앱이 자기 목적으로 만든 링크다.
    try testing.expect(isOpenableUri("https://example.com"));
    try testing.expect(isOpenableUri("mailto:a@b.c"));
    try testing.expect(isOpenableUri("vscode://file/tmp/a.zig:3"));
    try testing.expect(isOpenableUri("x-custom+scheme.v2://thing"));
}

test "#647 eql — 같은 링크인지로 hover 갱신을 가른다" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 60, 5);
    defer f.deinit(alloc);
    try f.term.printString("https://a.example and https://b.example");
    try f.sync(alloc);

    var a1 = (try hitTest(alloc, &f.state, .{ .x = 0, .y = 0 })).?;
    defer a1.deinit(alloc);
    var a2 = (try hitTest(alloc, &f.state, .{ .x = 5, .y = 0 })).?;
    defer a2.deinit(alloc);
    var b = (try hitTest(alloc, &f.state, .{ .x = 25, .y = 0 })).?;
    defer b.deinit(alloc);

    // 같은 링크의 다른 칸 → 같다 (다시 그릴 필요 없다).
    try testing.expect(a1.eql(&a2));
    // 다른 링크 → 다르다.
    try testing.expect(!a1.eql(&b));
}

test "#647 hover — 수식키 없이도 링크를 잡는다 (표시와 활성화를 가른다)" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 60, 5);
    defer f.deinit(alloc);
    try f.term.printString("see https://example.com now");
    try f.sync(alloc);

    var hover: Hover = .{};
    defer hover.deinit(alloc);

    // 수식키를 누르지 않아도 포인터가 링크 위면 잡힌다 — 그래야 *클릭할 수 있는 것인지* 를
    // 알 수 있다. 여는 데만 수식키가 필요하고 그 판정은 host 에 있다.
    try testing.expect(try hover.update(alloc, &f.state, .{ .cell = .{ .x = 6, .y = 0 }, .active = true, .pane = 0 }));
    try testing.expectEqualStrings("https://example.com", hover.hit.?.url);

    // 링크 밖으로 나가면 풀린다.
    try testing.expect(try hover.update(alloc, &f.state, .{ .cell = .{ .x = 1, .y = 0 }, .active = true, .pane = 0 }));
    try testing.expect(hover.hit == null);
}

test "#647 hover — 같은 링크 안에서 칸을 옮기면 다시 그리지 않는다" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 60, 5);
    defer f.deinit(alloc);
    try f.term.printString("see https://example.com and https://other.example");
    try f.sync(alloc);

    var hover: Hover = .{};
    defer hover.deinit(alloc);

    try testing.expect(try hover.update(alloc, &f.state, .{ .cell = .{ .x = 4, .y = 0 }, .active = true, .pane = 0 }));
    // 같은 링크의 다른 칸 — 판정은 다시 하지만 그림은 그대로다.
    try testing.expect(!try hover.update(alloc, &f.state, .{ .cell = .{ .x = 10, .y = 0 }, .active = true, .pane = 0 }));
    try testing.expectEqualStrings("https://example.com", hover.hit.?.url);

    // 다른 링크로 옮기면 다시 그린다.
    try testing.expect(try hover.update(alloc, &f.state, .{ .cell = .{ .x = 30, .y = 0 }, .active = true, .pane = 0 }));
    try testing.expectEqualStrings("https://other.example", hover.hit.?.url);

    // 링크 밖으로 나가면 풀린다.
    try testing.expect(try hover.update(alloc, &f.state, .{ .cell = .{ .x = 1, .y = 0 }, .active = true, .pane = 0 }));
    try testing.expect(hover.hit == null);
    // 링크 밖에서 칸만 옮기는 것은 변화가 아니다.
    try testing.expect(!try hover.update(alloc, &f.state, .{ .cell = .{ .x = 2, .y = 0 }, .active = true, .pane = 0 }));
}

test "#647 hover — 셀 영역 밖과 pane 전환" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 60, 5);
    defer f.deinit(alloc);
    try f.term.printString("see https://example.com now");
    try f.sync(alloc);

    var hover: Hover = .{};
    defer hover.deinit(alloc);

    try testing.expect(try hover.update(alloc, &f.state, .{ .cell = .{ .x = 6, .y = 0 }, .active = true, .pane = 0 }));
    // 탭바 · padding 처럼 셀이 없는 자리 → 해제.
    try testing.expect(try hover.update(alloc, &f.state, .{ .cell = null, .active = true, .pane = 0 }));
    try testing.expect(hover.hit == null);

    // 같은 입력을 다시 주면 판정을 건너뛴다.
    try testing.expect(try hover.update(alloc, &f.state, .{ .cell = .{ .x = 6, .y = 0 }, .active = true, .pane = 0 }));
    const before = hover.probe.?;
    try testing.expect(!try hover.update(alloc, &f.state, before));

    // 셀과 수식키가 같아도 **pane 이 다르면 다른 입력**이다 — 같은 좌표의 다른 화면이라
    // 캐시가 먹으면 안 된다.
    const p0: Hover.Probe = .{ .cell = .{ .x = 6, .y = 0 }, .active = true, .pane = 0 };
    const p1: Hover.Probe = .{ .cell = .{ .x = 6, .y = 0 }, .active = true, .pane = 1 };
    try testing.expect(p0.eql(p0));
    try testing.expect(!p0.eql(p1));
    // 셀 없음끼리는 같고, 한쪽만 없으면 다르다.
    const none: Hover.Probe = .{ .cell = null, .active = true, .pane = 0 };
    try testing.expect(none.eql(.{ .cell = null, .active = true, .pane = 0 }));
    try testing.expect(!none.eql(p0));
    try testing.expect(!p0.eql(none));
}

test "#647 hover — invalidate 는 같은 자리를 다시 판정하게 한다" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 60, 5);
    defer f.deinit(alloc);
    try f.term.printString("see https://example.com now");
    try f.sync(alloc);

    var hover: Hover = .{};
    defer hover.deinit(alloc);

    const at: Hover.Probe = .{ .cell = .{ .x = 6, .y = 0 }, .active = true, .pane = 0 };
    try testing.expect(try hover.update(alloc, &f.state, at));
    try testing.expect(!try hover.update(alloc, &f.state, at)); // 캐시 hit

    // 그 자리의 글자가 바뀌면 (여기서는 화면을 밀어 링크를 지운다) 다시 판정해야 한다.
    try f.term.printString("\r\n");
    f.term.eraseDisplay(.complete, false);
    try f.sync(alloc);
    hover.invalidate();
    try testing.expect(try hover.update(alloc, &f.state, at));
    try testing.expect(hover.hit == null);
}

test "#647 hover — urlAt 은 보고 있는 링크만 연다" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 60, 5);
    defer f.deinit(alloc);
    try f.term.printString("see https://example.com now");
    try f.sync(alloc);

    var hover: Hover = .{};
    defer hover.deinit(alloc);

    // hover 가 없으면 아무 셀도 안 연다.
    try testing.expect(hover.urlAt(.{ .x = 6, .y = 0 }) == null);

    _ = try hover.update(alloc, &f.state, .{ .cell = .{ .x = 6, .y = 0 }, .active = true, .pane = 0 });
    try testing.expectEqualStrings("https://example.com", hover.urlAt(.{ .x = 6, .y = 0 }).?);
    try testing.expectEqualStrings("https://example.com", hover.urlAt(.{ .x = 4, .y = 0 }).?);
    // 링크 밖 셀은 열지 않는다.
    try testing.expect(hover.urlAt(.{ .x = 1, .y = 0 }) == null);
    try testing.expect(hover.urlAt(.{ .x = 40, .y = 0 }) == null);
}

test "#647 hover — clear 는 창을 떠날 때" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 60, 5);
    defer f.deinit(alloc);
    try f.term.printString("see https://example.com now");
    try f.sync(alloc);

    var hover: Hover = .{};
    defer hover.deinit(alloc);

    try testing.expect(!hover.clear(alloc)); // 원래 없으면 변화 없음
    _ = try hover.update(alloc, &f.state, .{ .cell = .{ .x = 6, .y = 0 }, .active = true, .pane = 0 });
    try testing.expect(hover.clear(alloc));
    try testing.expect(hover.hit == null);
    try testing.expect(!hover.clear(alloc));
}

test "#647 applyHighlights — hover 를 행 강조로 칠하고, 풀면 지운다" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 60, 5);
    defer f.deinit(alloc);
    try f.term.printString("see https://example.com now");
    try f.sync(alloc);

    var hover: Hover = .{};
    defer hover.deinit(alloc);

    const cell_highlight_mod = @import("cell_highlight.zig");
    const rowHls = struct {
        fn get(state: *ghostty.RenderState, y: usize) []const ghostty.RenderState.Highlight {
            return state.row_data.slice().items(.highlights)[y].items;
        }
    }.get;

    // hover 가 없으면 아무것도 칠하지 않고, 행을 순회하지도 않는다.
    hover.applyHighlights(alloc, &f.state);
    try testing.expectEqual(@as(usize, 0), rowHls(&f.state, 0).len);

    // 링크 위에 올리면 그 구간이 `link_hover` 로 칠해진다 (`see ` 뒤 4..22).
    _ = try hover.update(alloc, &f.state, .{ .cell = .{ .x = 6, .y = 0 }, .active = true, .pane = 0 });
    hover.applyHighlights(alloc, &f.state);
    const hls = rowHls(&f.state, 0);
    try testing.expectEqual(@as(usize, 1), hls.len);
    try testing.expectEqual(cell_highlight_mod.Tag.link_hover.value(), hls[0].tag);
    try testing.expectEqual(@as(u16, 4), hls[0].range[0]);
    try testing.expectEqual(@as(u16, 22), hls[0].range[1]);
    try testing.expectEqual(cell_highlight_mod.Tag.link_hover, cell_highlight_mod.at(hls, 10).?);

    // 두 번 불러도 쌓이지 않는다.
    hover.applyHighlights(alloc, &f.state);
    try testing.expectEqual(@as(usize, 1), rowHls(&f.state, 0).len);

    // 링크를 벗어나면 지워진다.
    _ = try hover.update(alloc, &f.state, .{ .cell = .{ .x = 1, .y = 0 }, .active = true, .pane = 0 });
    hover.applyHighlights(alloc, &f.state);
    try testing.expectEqual(@as(usize, 0), rowHls(&f.state, 0).len);

    // 지운 뒤에는 다시 조기 반환한다 (칠한 것이 없으므로).
    try testing.expect(!hover.painted);
}

test "#647 applyHighlights — 접힌 URL 은 행마다 구간이 하나씩" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 20, 5);
    defer f.deinit(alloc);
    try f.term.printString("https://example.com/a/very/long/path");
    try f.sync(alloc);

    var hover: Hover = .{};
    defer hover.deinit(alloc);

    _ = try hover.update(alloc, &f.state, .{ .cell = .{ .x = 0, .y = 0 }, .active = true, .pane = 0 });
    hover.applyHighlights(alloc, &f.state);

    const slice = f.state.row_data.slice();
    // 36 글자 ÷ 20 열 = 첫 행이 꽉 차고 (0..19) 둘째 행에 나머지 16 글자 (0..15).
    try testing.expectEqual(@as(usize, 1), slice.items(.highlights)[0].items.len);
    try testing.expectEqual(@as(u16, 0), slice.items(.highlights)[0].items[0].range[0]);
    try testing.expectEqual(@as(u16, 19), slice.items(.highlights)[0].items[0].range[1]);
    try testing.expectEqual(@as(usize, 1), slice.items(.highlights)[1].items.len);
    try testing.expectEqual(@as(u16, 0), slice.items(.highlights)[1].items[0].range[0]);
    try testing.expectEqual(@as(u16, 15), slice.items(.highlights)[1].items[0].range[1]);
    // 셋째 행은 링크가 아니다.
    try testing.expectEqual(@as(usize, 0), slice.items(.highlights)[2].items.len);
}

test "#647 hover — 앱이 마우스를 잡으면 (active=false) 링크로 치지 않는다" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, 60, 5);
    defer f.deinit(alloc);
    try f.term.printString("see https://example.com now");
    try f.sync(alloc);

    var hover: Hover = .{};
    defer hover.deinit(alloc);

    // `active = false` — 앱이 mouse tracking 을 켰고 수식키도 안 눌린 상태.
    try testing.expect(!try hover.update(alloc, &f.state, .{ .cell = .{ .x = 6, .y = 0 }, .active = false, .pane = 0 }));
    try testing.expect(hover.hit == null);
    try testing.expect(hover.urlAt(.{ .x = 6, .y = 0 }) == null);

    // 수식키를 누르면 (active = true) 그때 잡힌다.
    try testing.expect(try hover.update(alloc, &f.state, .{ .cell = .{ .x = 6, .y = 0 }, .active = true, .pane = 0 }));
    try testing.expectEqualStrings("https://example.com", hover.urlAt(.{ .x = 6, .y = 0 }).?);

    // 다시 놓으면 풀린다 — 밑줄도 사라지고 클릭도 앱에 간다.
    try testing.expect(try hover.update(alloc, &f.state, .{ .cell = .{ .x = 6, .y = 0 }, .active = false, .pane = 0 }));
    try testing.expect(hover.hit == null);
}
