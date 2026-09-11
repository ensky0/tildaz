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
