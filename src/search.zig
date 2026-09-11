//! #646 — pane 별 버퍼 검색 상태. 검색 **엔진은 짜지 않는다** — ghostty-vt 의
//! `search.Screen` (`ScreenSearch`) 가 증분 검색 · 결과 캐시 · 매치 선택 추적 ·
//! 화면 변화 따라잡기를 전부 갖고 있고, 이 모듈은 그것의 *수명과 진행*만 맡는다.
//!
//! **진행은 `tick()` 으로 나눠서 한다.** `searchAll` 을 한 번에 부르면 10,000 줄에서
//! 6.5 ms 가 걸려 SPEC §13 의 프레임 예산 (4 ms) 을 넘는다. 반면 `tick` 한 번은
//! 최악 (거의 모든 줄이 매치) 에서도 1.12 ms, 흔한 경우 0.24 ms 라 예산 안에 들어간다
//! (2026-09-11 실측 · MacBook Pro M5 Pro · ReleaseFast — #646 코멘트). 그래서
//! 백그라운드 스레드가 필요 없다 — `search.Thread` 는 `emit-lib-vt` 에서 `void` 이고,
//! libghostty-vt 자체가 thread-safe 하지 않아 스레드를 두면 터미널 상태 락을 우리가
//! 전부 떠안게 된다.
//!
//! **검색바가 열려 있으면 needle 이 비어도 "검색 있음" 이다** (2026-09-11 결정) —
//! 여닫기는 사용자가 명시적으로 하고, pane 을 오가는 것으로 닫히지 않는다.

const std = @import("std");
const ghostty = @import("ghostty-vt");
const cell_highlight = @import("cell_highlight.zig");

/// needle 이 이 길이 미만이면 입력이 멈출 때까지 검색을 미룬다. 한 글자마다 전수
/// 검색을 새로 시작하면 타이핑 중 예산을 계속 먹는다 — ghostty 의 macOS 앱도 같은
/// 자리에 3 자 / 300 ms 를 쓴다 (`SurfaceView_AppKit.swift` 의 needle debounce).
pub const DEBOUNCE_MIN_NEEDLE_LEN: usize = 3;
pub const DEBOUNCE_NS: u64 = 300 * std.time.ns_per_ms;

/// 한 pane 의 검색 상태.
///
/// `engine` 은 needle 이 확정된 뒤에만 있다. needle 이 짧아 디바운스 중이거나 비어
/// 있으면 `null` 이고, 그때도 `open` 은 참일 수 있다 (위 정책).
pub const PaneSearch = struct {
    /// 검색바가 열려 있는가. `engine` 유무와 **독립**이다.
    is_open: bool = false,

    /// 사용자가 입력한 검색어. 소유한다.
    needle: std.ArrayList(u8) = .empty,

    /// ghostty 검색기. needle 이 확정되면 만들고, needle 이 바뀌거나 대상 screen 이
    /// 바뀌면 버린다.
    engine: ?ghostty.search.Screen = null,

    /// `engine` 이 잡고 있는 screen. `Terminal.screens.active` 는 alt screen 전환
    /// (vim 등) 으로 **바뀐다** — 그때 옛 screen 을 가리키는 엔진을 그대로 쓰면 죽은
    /// 메모리를 읽는다. 매 진행 전에 이 값과 현재 active 를 비교한다.
    engine_screen: ?*ghostty.Screen = null,

    /// 디바운스 만료 시각 (`Tab.title_clock` 과 같은 단조 시계의 ns). `null` 이면
    /// 대기 중이 아니다.
    debounce_deadline_ns: ?u64 = null,

    /// 현재 terminal 상태 기준으로 검색이 끝났는가. 끝나도 결과는 유지된다.
    complete: bool = false,

    /// 매치 목록이나 선택이 바뀌어 `RenderState` 의 highlight 를 다시 칠해야 하는가.
    ///
    /// 매 프레임 다시 칠하지 않는 이유는 비용이다 — 지우기는 행 수만큼, 칠하기는 매치
    /// 수만큼 드는데 매치가 만 개인 화면이 실제로 있다. ghostty 본체도 같은 자리에
    /// `search_matches_dirty` 를 둔다 (`renderer/generic.zig`).
    highlights_dirty: bool = false,

    /// #646 — 입력칸 가로 스크롤 (logical pt). `search_bar.fieldScrollOffset` 이 매 프레임
    /// 갱신해 여기 써 둔다. **상태로 남겨야** caret 이 보이는 동안 스크롤을 바꾸지 않는
    /// hysteresis 가 성립한다 (탭 rename 이 `RenameState` 에 같은 값을 뒀다).
    field_scroll_px: f32 = 0,

    /// 이 pane 의 검색이 더 진행할 일이 남았는가. `false` 면 `step` 을 부르지 않는다.
    pub fn isRunning(self: *const PaneSearch) bool {
        return self.engine != null and !self.complete;
    }

    pub fn deinit(self: *PaneSearch, alloc: std.mem.Allocator) void {
        self.dropEngine();
        self.needle.deinit(alloc);
        self.* = .{};
    }

    /// 엔진만 버린다. needle 과 `open` 은 남는다.
    ///
    /// `ScreenSearch.deinit` 은 tracked pin 을 돌려주려고 **screen 을 만진다.** 그래서
    /// screen 이 이미 사라졌으면 (탭 종료 순서) 그쪽을 만지지 않는
    /// `deinitScreenInvalid` 를 써야 한다 — 여기서는 screen 이 살아 있는 경로만
    /// 다루므로 평범한 `deinit` 이고, 탭 종료는 `deinitAfterScreen` 을 쓴다.
    pub fn dropEngine(self: *PaneSearch) void {
        if (self.engine) |*e| e.deinit();
        self.engine = null;
        self.engine_screen = null;
        self.complete = false;
        self.highlights_dirty = true;
    }

    /// 터미널이 먼저 해제된 뒤에 부르는 정리. `ScreenSearch` 가 screen 을 만지지
    /// 않게 한다.
    pub fn deinitAfterScreen(self: *PaneSearch, alloc: std.mem.Allocator) void {
        if (self.engine) |*e| e.deinitScreenInvalid();
        self.engine = null;
        self.engine_screen = null;
        self.needle.deinit(alloc);
        self.* = .{};
    }

    /// 검색바를 연다. 이미 열려 있으면 아무 일도 하지 않는다 (needle 유지).
    pub fn open(self: *PaneSearch) void {
        self.is_open = true;
    }

    /// 검색바를 닫는다. **needle 과 결과까지 버린다** — 닫기는 사용자가 명시적으로
    /// 하는 행동이고, 다시 열었을 때 옛 검색어가 남아 있으면 그게 어느 시점 것인지
    /// 알 수 없다.
    ///
    /// **화면의 강조는 여기서 지워지지 않는다.** 이 함수는 `highlights_dirty` 만 세우고,
    /// 실제로 지우는 것은 다음 렌더의 `applyHighlights` 다 (`RenderState` 는 렌더 루프
    /// 안에서만 만진다). 그 렌더가 돌도록 `session_core.drainFrame` 이 "닫혔는데 dirty"
    /// 상태를 보고 렌더를 한 번 요청한다 — 없으면 화면이 안 바뀌어 게이트 (#388) 에
    /// 걸리고 강조가 칠해진 채로 남는다.
    pub fn close(self: *PaneSearch, alloc: std.mem.Allocator) void {
        self.dropEngine();
        self.needle.clearAndFree(alloc);
        self.debounce_deadline_ns = null;
        self.is_open = false;
    }

    /// 검색어를 통째로 바꾼다. 엔진은 버리고 디바운스를 다시 건다.
    ///
    /// `now_ns` 는 `Tab.title_clock.read()` 와 같은 단조 시계 값이다.
    pub fn setNeedle(
        self: *PaneSearch,
        alloc: std.mem.Allocator,
        text: []const u8,
        now_ns: u64,
    ) std.mem.Allocator.Error!void {
        // 같은 needle 이면 진행 중인 검색을 버리지 않는다 — 타이핑이 아니라 같은 값을
        // 다시 set 하는 경로 (포커스 복귀 등) 에서 검색이 처음부터 다시 도는 것을 막는다.
        if (std.mem.eql(u8, self.needle.items, text)) return;

        self.needle.clearRetainingCapacity();
        try self.needle.appendSlice(alloc, text);
        self.dropEngine();

        // 짧은 needle 만 기다린다. 긴 needle 과 빈 needle 은 대기가 없다 (`null`).
        self.debounce_deadline_ns = if (text.len != 0 and text.len < DEBOUNCE_MIN_NEEDLE_LEN)
            now_ns + DEBOUNCE_NS
        else
            null;
    }

    /// 아직 시작하지 않은 검색을 시작할 때가 됐는지.
    ///
    /// **`debounce_deadline_ns` 가 `null` 이면 "대기 없음" 이지 "시작 금지" 가 아니다.**
    /// 이 둘을 섞으면 엔진을 한 번 버린 뒤 (alt screen 전환 등) 검색이 영영 재개되지
    /// 않는다 — 그 자리에서 deadline 이 비기 때문이다. 실제로 그 버그를
    /// `대상 screen 이 바뀌면 엔진을 다시 만든다` 테스트가 잡았다.
    fn readyToStart(self: *const PaneSearch, now_ns: u64) bool {
        if (self.engine != null) return false;
        if (self.needle.items.len == 0) return false;
        const deadline = self.debounce_deadline_ns orelse return true;
        return now_ns >= deadline;
    }

    /// 진행을 한 걸음 나아간다. **예산은 부르는 쪽이 잰다** — 이 함수는 한 step 만
    /// 하고 돌아온다.
    ///
    /// 반환값은 "이번 호출이 무언가 했는가" 다. `false` 면 이 프레임에 더 부를 필요가
    /// 없다.
    pub fn step(
        self: *PaneSearch,
        alloc: std.mem.Allocator,
        screen: *ghostty.Screen,
        now_ns: u64,
    ) std.mem.Allocator.Error!bool {
        if (!self.is_open) return false;

        // alt screen 전환 등으로 대상이 바뀌었으면 엔진을 다시 만든다. 비교를 먼저
        // 하는 이유는 아래 어느 경로도 옛 screen 을 만지면 안 되기 때문이다.
        if (self.engine_screen) |prev| {
            if (prev != screen) self.dropEngine();
        }

        if (self.readyToStart(now_ns)) {
            self.engine = try .init(alloc, screen, self.needle.items);
            self.engine_screen = screen;
            self.complete = false;
            self.debounce_deadline_ns = null;
            self.highlights_dirty = true;
            return true;
        }

        if (self.complete) return false;
        const engine: *ghostty.search.Screen = if (self.engine) |*e| e else return false;

        engine.tick() catch |err| switch (err) {
            error.FeedRequired => {
                try engine.feed();
                self.highlights_dirty = true;
                return true;
            },
            error.SearchComplete => {
                self.complete = true;
                return false;
            },
            else => |e| return e,
        };
        self.highlights_dirty = true;
        return true;
    }

    /// 지금까지 찾은 매치 수.
    pub fn matchCount(self: *const PaneSearch) usize {
        const engine: *const ghostty.search.Screen = if (self.engine) |*e| e else return 0;
        return engine.matchesLen();
    }

    /// 선택된 매치를 다음/이전으로 옮긴다. 옮겼으면 `true`.
    pub fn select(self: *PaneSearch, to: ghostty.search.Screen.Select) std.mem.Allocator.Error!bool {
        const engine: *ghostty.search.Screen = if (self.engine) |*e| e else return false;
        const moved = try engine.select(to);
        if (moved) self.highlights_dirty = true;
        return moved;
    }

    /// 선택된 매치의 **1-based 번호** (`3/17` 의 `3`). 선택이 없으면 `0`.
    ///
    /// ghostty 의 `selected.idx` 는 *목록 끝에서부터* 세는 0-based 다 (`0` = 가장 최근 매치).
    /// 사용자는 위에서부터 세므로 뒤집어서 보여준다.
    pub fn currentIndex(self: *const PaneSearch) usize {
        const engine: *const ghostty.search.Screen = if (self.engine) |*e| e else return 0;
        const sel = engine.selected orelse return 0;
        const total = engine.matchesLen();
        if (sel.idx >= total) return 0; // 결과가 줄어드는 중이면 표시하지 않는다.
        return total - sel.idx;
    }

    /// 아직 훑는 중인가 — 카운터를 수 대신 `…` 로 보여줄 조건이다. 디바운스 대기 (엔진이
    /// 아직 없음) 와 증분 진행 (엔진이 있고 미완) 을 모두 포함한다.
    pub fn isSearching(self: *const PaneSearch) bool {
        if (!self.is_open) return false;
        if (self.needle.items.len == 0) return false;
        return if (self.engine == null) true else !self.complete;
    }

    /// 지금 선택된 매치. 없으면 `null`.
    pub fn selectedMatch(self: *const PaneSearch) ?ghostty.highlight.Flattened {
        const engine: *const ghostty.search.Screen = if (self.engine) |*e| e else return null;
        return engine.selectedMatch();
    }

    /// 매치를 `RenderState` 의 per-row highlight 로 칠한다. **`state.update` 직후**에
    /// 부른다 — row 가 재구축된 뒤라야 칠할 자리가 있다.
    ///
    /// 세 renderer 가 각자 부르지 않고 이 한 함수를 쓴다 (AGENTS.md 의 single
    /// definition 규칙). renderer 는 결과 (`row_data.items(.highlights)`) 만 읽는다.
    ///
    /// 다시 칠하는 조건은 **매치가 바뀌었거나 (`highlights_dirty`) row 가 바뀐 것
    /// (`state.dirty`)** 둘 중 하나다. row 가 바뀌면 ghostty 가 그 행의 highlight 를
    /// 지우므로 (`render.zig` 의 "dirty row resets highlights") 다시 칠해야 한다.
    pub fn applyHighlights(
        self: *PaneSearch,
        alloc: std.mem.Allocator,
        state: *ghostty.RenderState,
    ) void {
        // 검색을 쓴 적이 없으면 할 일이 없다. 이 줄이 없으면 **검색을 안 켠 사용자도**
        // 화면이 바뀌는 프레임마다 전체 행을 순회한다 (`state.dirty` 가 아래 조건에
        // 들어 있어서다) — 지울 강조도 칠할 매치도 없는데.
        if (self.engine == null and !self.highlights_dirty) return;
        if (!self.highlights_dirty and state.dirty == .false) return;
        self.highlights_dirty = false;

        // **우리 tag 만** 지운다 — 같은 행에 링크 hover (#647) 등 다른 기능의 강조가
        // 함께 있을 수 있다. 계약은 `cell_highlight.zig` 에 있다.
        _ = cell_highlight.clear(state, &.{ .search_current, .search_match });

        const engine: *ghostty.search.Screen = if (self.engine) |*e| e else return;

        // 우선순위는 **tag 값**이 정한다 (`cell_highlight.Tag` — 작을수록 위). 넣는 순서에
        // 기대지 않는 이유는 두 기능이 서로 다른 프레임에 자기 강조를 다시 칠해서 목록 안
        // 순서가 프레임마다 달라지기 때문이다.
        if (engine.selectedMatch()) |m| {
            state.updateHighlightsFlattened(alloc, cell_highlight.Tag.search_current.value(), &.{m}) catch {
                // 칠하지 못해도 검색 자체는 유효하다 — 이번 프레임만 표시가 빠진다.
                self.highlights_dirty = true;
            };
        }

        // 결과 배열을 그대로 넘긴다 (`matches()` 는 새 배열을 할당한다 — 프레임마다
        // 만 개를 복사할 이유가 없다).
        for ([_][]const ghostty.highlight.Flattened{
            engine.history_results.items,
            engine.active_results.items,
        }) |list| {
            if (list.len == 0) continue;
            state.updateHighlightsFlattened(alloc, cell_highlight.Tag.search_match.value(), list) catch {
                self.highlights_dirty = true;
            };
        }
    }
};

test "#646 needle 이 비면 검색을 시작하지 않는다" {
    const alloc = std.testing.allocator;
    var s: PaneSearch = .{};
    defer s.deinit(alloc);

    s.open();
    try s.setNeedle(alloc, "", 0);
    try std.testing.expect(!s.readyToStart(0));
    try std.testing.expect(!s.readyToStart(std.math.maxInt(u64)));
}

test "#646 짧은 needle 은 디바운스를 기다린다" {
    const alloc = std.testing.allocator;
    var s: PaneSearch = .{};
    defer s.deinit(alloc);

    s.open();
    try s.setNeedle(alloc, "ab", 1_000);
    // 아직 이르다.
    try std.testing.expect(!s.readyToStart(1_000 + DEBOUNCE_NS - 1));
    // 만료 뒤에는 시작한다.
    try std.testing.expect(s.readyToStart(1_000 + DEBOUNCE_NS));
}

test "#646 충분히 긴 needle 은 즉시 시작한다" {
    const alloc = std.testing.allocator;
    var s: PaneSearch = .{};
    defer s.deinit(alloc);

    s.open();
    try s.setNeedle(alloc, "abc", 5_000);
    try std.testing.expect(s.readyToStart(5_000));
}

test "#646 같은 needle 을 다시 넣어도 진행 중 검색을 버리지 않는다" {
    const alloc = std.testing.allocator;
    var s: PaneSearch = .{};
    defer s.deinit(alloc);

    s.open();
    try s.setNeedle(alloc, "abc", 0);
    s.debounce_deadline_ns = 12_345;
    try s.setNeedle(alloc, "abc", 999_999);
    try std.testing.expectEqual(@as(?u64, 12_345), s.debounce_deadline_ns);
}

test "#646 닫으면 needle 과 결과를 버린다" {
    const alloc = std.testing.allocator;
    var s: PaneSearch = .{};
    defer s.deinit(alloc);

    s.open();
    try s.setNeedle(alloc, "abc", 0);
    try std.testing.expect(s.is_open);
    try std.testing.expect(s.needle.items.len > 0);

    s.close(alloc);
    try std.testing.expect(!s.is_open);
    try std.testing.expectEqual(@as(usize, 0), s.needle.items.len);
    try std.testing.expect(s.engine == null);
}

test "#646 실제 스크롤백을 step 으로 끝까지 검색한다" {
    const alloc = std.testing.allocator;
    var term = try ghostty.Terminal.init(std.testing.io, alloc, .{
        .cols = 40,
        .rows = 10,
        .max_scrollback_lines = 500,
        .max_scrollback_bytes = null,
    });
    defer term.deinit(alloc);

    for (0..200) |i| {
        var buf: [64]u8 = undefined;
        const line = if (i % 50 == 0)
            try std.fmt.bufPrint(&buf, "row {d} FINDME\r\n", .{i})
        else
            try std.fmt.bufPrint(&buf, "row {d} plain\r\n", .{i});
        try term.printString(line);
    }

    var s: PaneSearch = .{};
    defer s.deinitAfterScreen(alloc);

    s.open();
    try s.setNeedle(alloc, "FINDME", 0);

    var steps: usize = 0;
    while (try s.step(alloc, term.screens.active, 0)) {
        steps += 1;
        try std.testing.expect(steps < 10_000); // 무한 루프 방지
    }

    try std.testing.expect(s.complete);
    try std.testing.expectEqual(@as(usize, 4), s.matchCount());
    try std.testing.expect(try s.select(.next));
    try std.testing.expect(s.selectedMatch() != null);
}

test "#646 대상 screen 이 바뀌면 엔진을 다시 만든다" {
    const alloc = std.testing.allocator;
    var term = try ghostty.Terminal.init(std.testing.io, alloc, .{
        .cols = 40,
        .rows = 10,
        .max_scrollback_lines = 100,
        .max_scrollback_bytes = null,
    });
    defer term.deinit(alloc);
    try term.printString("hello FINDME world\r\n");

    var s: PaneSearch = .{};
    defer s.deinitAfterScreen(alloc);

    s.open();
    try s.setNeedle(alloc, "FINDME", 0);
    _ = try s.step(alloc, term.screens.active, 0);
    try std.testing.expect(s.engine != null);
    const first_screen = s.engine_screen.?;

    // alt screen 으로 전환하면 `screens.active` 가 달라진다.
    _ = try term.switchScreen(.alternate);
    const alt = term.screens.active;
    try std.testing.expect(alt != first_screen);

    _ = try s.step(alloc, alt, 0);
    try std.testing.expectEqual(alt, s.engine_screen.?);
}

test "#646 검색을 닫으면 강조가 사라진다 — 셀은 평소 색으로 돌아간다" {
    const alloc = std.testing.allocator;
    var term = try ghostty.Terminal.init(std.testing.io, alloc, .{
        .cols = 40,
        .rows = 10,
        .max_scrollback_lines = 100,
        .max_scrollback_bytes = null,
    });
    defer term.deinit(alloc);
    try term.printString("hello FINDME world\r\n");

    var state: ghostty.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    var s: PaneSearch = .{};
    defer s.deinitAfterScreen(alloc);

    s.open();
    try s.setNeedle(alloc, "FINDME", 0);
    while (try s.step(alloc, term.screens.active, 0)) {}
    s.applyHighlights(alloc, &state);

    // 칠해졌는지 먼저 확인 — 이게 0 이면 아래 단언이 의미가 없다.
    try std.testing.expect(countHighlights(&state) > 0);

    // 닫으면 그 다음 프레임에 지워져야 한다. `close` 자체는 `state` 를 만지지 않고
    // `highlights_dirty` 만 세우므로, 지우는 일은 다음 `applyHighlights` 가 한다.
    s.close(alloc);
    s.applyHighlights(alloc, &state);
    try std.testing.expectEqual(@as(usize, 0), countHighlights(&state));
}

test "#646 needle 을 바꾸면 옛 매치가 남지 않는다" {
    const alloc = std.testing.allocator;
    var term = try ghostty.Terminal.init(std.testing.io, alloc, .{
        .cols = 40,
        .rows = 10,
        .max_scrollback_lines = 100,
        .max_scrollback_bytes = null,
    });
    defer term.deinit(alloc);
    try term.printString("aaa FINDME bbb OTHER ccc\r\n");

    var state: ghostty.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    var s: PaneSearch = .{};
    defer s.deinitAfterScreen(alloc);

    s.open();
    try s.setNeedle(alloc, "FINDME", 0);
    while (try s.step(alloc, term.screens.active, 0)) {}
    s.applyHighlights(alloc, &state);
    const first = countHighlights(&state);
    try std.testing.expect(first > 0);

    // 다른 needle 로 바꾸면 옛 강조가 지워지고 새 것만 남아야 한다 — 지우지 않으면
    // 행에 계속 쌓여 지워진 검색어의 자리가 그대로 칠해진 채로 남는다.
    try s.setNeedle(alloc, "OTHER", 0);
    while (try s.step(alloc, term.screens.active, 0)) {}
    s.applyHighlights(alloc, &state);
    try std.testing.expectEqual(first, countHighlights(&state));
}

fn countHighlights(state: *ghostty.RenderState) usize {
    var n: usize = 0;
    const rd = state.row_data.slice();
    for (rd.items(.highlights)) |h| n += h.items.len;
    return n;
}
