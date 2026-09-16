//! #646 — 검색바 입력칸의 **의미**: 어느 키가 무엇을 하고, 편집이 needle · caret 을
//! 어떻게 바꾸는가.
//!
//! `input_policy` 가 "어디로" 를 정하고 (`Target.search_field`), 여기가 "그래서 무엇" 을
//! 정한다. 두 겹으로 나누는 것은 탭 inline rename 이 쓰던 구조 그대로다 — 라우팅은
//! `input_policy`, 편집 의미는 상태를 가진 쪽 (`tab_interaction.RenameState`) 에 있었다.
//! 그때 결함 (#282) 은 이 구조가 아니라 **host 3 벌이 각자 판정한 것** 이 원인이었으므로,
//! 세 host 가 예외 없이 이 함수들만 부른다.
//!
//! **caret 은 늘 codepoint 경계에 둔다.** UTF-8 중간을 가리키면 그 자리에서 자른 needle 이
//! 깨진 바이트열이 되고, `iterFieldText` 의 그리기도 어긋난다. 경계 계산은 이 파일의
//! `prevBoundary` · `nextBoundary` 한 쌍에만 있다.

const std = @import("std");
const search = @import("search.zig");
const search_bar = @import("search_bar.zig");

/// 검색 입력칸이 뜻을 갖는 키. host 가 native 키를 여기로 분류한다 (`input_policy` 의
/// `edit_key` 분류가 "입력칸이 먹는다" 까지, 이 enum 이 "무엇을 한다" 까지).
pub const Key = enum {
    /// 다음 매치 — **화면 아래쪽**으로. Enter 의 기본 방향이다 (2026-09-16 사용자 결정).
    ///
    /// 아래가 기본인 이유는 카운터다. 위로 가면 `43/43 → 42/43` 처럼 숫자가 줄어 읽는
    /// 방향과 어긋난다. 브라우저 · 에디터의 "다음" 도 모두 아래다. 끝에 닿으면 맨 위에서
    /// 이어진다.
    match_down,
    /// Shift+Enter — **화면 위쪽**으로. 터미널에서 "조금 전 출력" 을 찾는 방향이다.
    match_up,
    /// 검색바 닫기 (Esc). needle 과 결과까지 버린다 — `PaneSearch.close` 참고.
    close,
    backspace,
    /// forward delete (caret 오른쪽 한 글자).
    delete,
    left,
    right,
    home,
    end,
};

/// 입력 한 번이 만든 변화. host 는 이것만 보고 다시 그릴지 · 포커스를 돌릴지 정한다.
///
/// `redraw` 를 반환값으로 두는 이유는 렌더 게이트 (#388) 다 — 화면이 안 바뀌면 프레임을
/// 건너뛰므로, 바뀐 것을 host 가 알려 줘야 한다. caret 이동처럼 터미널 내용이 전혀 바뀌지
/// 않는 편집도 다시 그려야 한다.
pub const Effect = struct {
    redraw: bool = false,
    /// 검색바가 닫혔다 — host 는 키보드 포커스를 터미널로 되돌린다.
    closed: bool = false,
};

/// 키 하나를 적용한다. `now_ns` 는 `Tab.title_clock.read()` 와 같은 단조 시계 값이다
/// (needle 이 바뀌면 디바운스를 다시 걸어야 한다).
pub fn key(
    ps: *search.PaneSearch,
    alloc: std.mem.Allocator,
    k: Key,
    now_ns: u64,
) std.mem.Allocator.Error!Effect {
    const text = ps.needle.items;
    switch (k) {
        .close => {
            ps.close(alloc);
            return .{ .redraw = true, .closed = true };
        },

        // 매치 이동은 엔진이 있어야 한다. 디바운스 대기 중이거나 needle 이 비었으면
        // `select` 가 `false` 를 돌려주고 아무 일도 일어나지 않는다.
        .match_down => return .{ .redraw = try ps.select(.down) },
        .match_up => return .{ .redraw = try ps.select(.up) },

        .backspace => {
            if (ps.caret == 0) return .{};
            return try splice(ps, alloc, prevBoundary(text, ps.caret), ps.caret, "", now_ns);
        },
        .delete => {
            if (ps.caret >= text.len) return .{};
            return try splice(ps, alloc, ps.caret, nextBoundary(text, ps.caret), "", now_ns);
        },

        // caret 이동은 needle 을 바꾸지 않는다 — 검색을 다시 돌리지 않는다.
        .left => return moveCaret(ps, prevBoundary(text, ps.caret)),
        .right => return moveCaret(ps, nextBoundary(text, ps.caret)),
        .home => return moveCaret(ps, 0),
        .end => return moveCaret(ps, text.len),
    }
}

/// 문자열을 caret 자리에 끼운다. 문자 입력과 paste · IME commit 이 모두 이 한 곳으로
/// 들어온다 — 세 경로가 각자 needle 을 만지면 caret 규칙이 갈린다.
///
/// host 는 제어문자를 걸러서 준다 (`input_policy` 가 `text` 로 분류하는 것은 codepoint
/// ≥ 0x20 뿐이다). 다만 **paste 는 payload 에 개행이 섞인다** — 한 줄짜리 입력칸이라
/// 첫 제어문자에서 자른다. 여러 줄을 한 줄로 이어 붙이면 무엇을 찾는지 볼 수 없고,
/// 통째로 버리면 왜 아무 일도 안 일어나는지 알 수 없다. UTF-8 이어지는 바이트는 모두
/// `0x80` 이상이라 이 컷이 글자 중간을 자르지 않는다.
pub fn insertText(
    ps: *search.PaneSearch,
    alloc: std.mem.Allocator,
    text: []const u8,
    now_ns: u64,
) std.mem.Allocator.Error!Effect {
    var end: usize = 0;
    while (end < text.len and text[end] >= 0x20 and text[end] != 0x7F) end += 1;
    if (end == 0) return .{};
    return try splice(ps, alloc, ps.caret, ps.caret, text[0..end], now_ns);
}

/// 바 안의 컨트롤을 눌렀다. 키와 같은 동작으로 모은다 — `< > ×` 가 Shift+Enter ·
/// Enter · Esc 와 다르게 굴면 그 자체가 결함이다.
pub fn control(
    ps: *search.PaneSearch,
    alloc: std.mem.Allocator,
    c: search_bar.Control,
    now_ns: u64,
) std.mem.Allocator.Error!Effect {
    return try key(ps, alloc, switch (c) {
        .prev => .match_up,
        .next => .match_down,
        .close => .close,
    }, now_ns);
}

fn moveCaret(ps: *search.PaneSearch, to: usize) Effect {
    if (ps.caret == to) return .{};
    ps.caret = to;
    return .{ .redraw = true };
}

/// `[from, to)` 를 `insert` 로 갈아 끼우고 caret 을 끼운 것 뒤에 둔다.
fn splice(
    ps: *search.PaneSearch,
    alloc: std.mem.Allocator,
    from: usize,
    to: usize,
    insert: []const u8,
    now_ns: u64,
) std.mem.Allocator.Error!Effect {
    // `setNeedle` 은 통째 교체라 새 문자열을 따로 만든다. needle 은 사람이 치는 길이라
    // 이 복사는 문제가 되지 않는다 (검색 자체가 훨씬 비싸다).
    var next: std.ArrayList(u8) = .empty;
    defer next.deinit(alloc);
    try next.ensureTotalCapacity(alloc, ps.needle.items.len - (to - from) + insert.len);
    next.appendSliceAssumeCapacity(ps.needle.items[0..from]);
    next.appendSliceAssumeCapacity(insert);
    next.appendSliceAssumeCapacity(ps.needle.items[to..]);

    try ps.setNeedle(alloc, next.items, now_ns);
    // `setNeedle` 은 같은 값이면 일찍 돌아오고 (진행 중 검색을 지키려고) caret 을 안
    // 건드리므로, 자리는 언제나 여기서 정한다.
    ps.caret = from + insert.len;
    return .{ .redraw = true };
}

/// caret 왼쪽 codepoint 의 시작 offset. UTF-8 continuation byte (`0b10xxxxxx`) 를 지나
/// 선두 byte 까지 되돌아간다.
fn prevBoundary(text: []const u8, caret: usize) usize {
    if (caret == 0) return 0;
    var i = @min(caret, text.len) - 1;
    while (i > 0 and text[i] & 0xC0 == 0x80) i -= 1;
    return i;
}

/// caret 오른쪽 codepoint의 끝 offset.
fn nextBoundary(text: []const u8, caret: usize) usize {
    if (caret >= text.len) return text.len;
    const len = std.unicode.utf8ByteSequenceLength(text[caret]) catch 1;
    return @min(text.len, caret + len);
}

// ── 테스트 ───────────────────────────────────────────────────────────────────

fn seed(ps: *search.PaneSearch, alloc: std.mem.Allocator, text: []const u8) !void {
    ps.open();
    try ps.setNeedle(alloc, text, 0);
    ps.caret = text.len;
}

test "#646 문자 입력은 caret 자리에 끼우고 caret 을 뒤로 옮긴다" {
    const alloc = std.testing.allocator;
    var ps: search.PaneSearch = .{};
    defer ps.deinit(alloc);

    try seed(&ps, alloc, "abc");
    ps.caret = 1;
    _ = try insertText(&ps, alloc, "XY", 0);
    try std.testing.expectEqualStrings("aXYbc", ps.needle.items);
    try std.testing.expectEqual(@as(usize, 3), ps.caret);
}

test "#646 backspace 는 한 codepoint 를 지운다 — 한글도 한 번에" {
    const alloc = std.testing.allocator;
    var ps: search.PaneSearch = .{};
    defer ps.deinit(alloc);

    try seed(&ps, alloc, "가나");
    try std.testing.expectEqual(@as(usize, 6), ps.caret);

    _ = try key(&ps, alloc, .backspace, 0);
    try std.testing.expectEqualStrings("가", ps.needle.items);
    try std.testing.expectEqual(@as(usize, 3), ps.caret);

    _ = try key(&ps, alloc, .backspace, 0);
    try std.testing.expectEqualStrings("", ps.needle.items);
    try std.testing.expectEqual(@as(usize, 0), ps.caret);

    // 빈 상태에서 더 눌러도 아무 일 없다.
    const e = try key(&ps, alloc, .backspace, 0);
    try std.testing.expect(!e.redraw);
}

test "#646 delete 는 caret 오른쪽 한 codepoint 를 지운다" {
    const alloc = std.testing.allocator;
    var ps: search.PaneSearch = .{};
    defer ps.deinit(alloc);

    try seed(&ps, alloc, "가나");
    ps.caret = 0;
    _ = try key(&ps, alloc, .delete, 0);
    try std.testing.expectEqualStrings("나", ps.needle.items);
    try std.testing.expectEqual(@as(usize, 0), ps.caret);

    // 끝에서는 아무 일 없다.
    ps.caret = ps.needle.items.len;
    const e = try key(&ps, alloc, .delete, 0);
    try std.testing.expect(!e.redraw);
}

test "#646 좌우 이동은 codepoint 경계를 지킨다" {
    const alloc = std.testing.allocator;
    var ps: search.PaneSearch = .{};
    defer ps.deinit(alloc);

    try seed(&ps, alloc, "a가b");
    ps.caret = 0;
    _ = try key(&ps, alloc, .right, 0);
    try std.testing.expectEqual(@as(usize, 1), ps.caret);
    _ = try key(&ps, alloc, .right, 0); // '가' 는 3 byte
    try std.testing.expectEqual(@as(usize, 4), ps.caret);
    _ = try key(&ps, alloc, .left, 0);
    try std.testing.expectEqual(@as(usize, 1), ps.caret);

    // 양 끝에서는 멈춘다 (redraw 없음).
    ps.caret = 0;
    try std.testing.expect(!(try key(&ps, alloc, .left, 0)).redraw);
    ps.caret = ps.needle.items.len;
    try std.testing.expect(!(try key(&ps, alloc, .right, 0)).redraw);
}

test "#646 home / end" {
    const alloc = std.testing.allocator;
    var ps: search.PaneSearch = .{};
    defer ps.deinit(alloc);

    try seed(&ps, alloc, "abc");
    _ = try key(&ps, alloc, .home, 0);
    try std.testing.expectEqual(@as(usize, 0), ps.caret);
    _ = try key(&ps, alloc, .end, 0);
    try std.testing.expectEqual(@as(usize, 3), ps.caret);
}

test "#646 편집은 디바운스를 다시 걸고 caret 은 그 자리에 남는다" {
    const alloc = std.testing.allocator;
    var ps: search.PaneSearch = .{};
    defer ps.deinit(alloc);

    ps.open();
    _ = try insertText(&ps, alloc, "a", 1_000);
    // 짧은 needle 이라 대기가 걸린다.
    try std.testing.expectEqual(@as(?u64, 1_000 + search.DEBOUNCE_NS), ps.debounce_deadline_ns);

    _ = try insertText(&ps, alloc, "bc", 2_000);
    // 3 자가 되면 대기 없이 바로 시작한다.
    try std.testing.expect(ps.debounce_deadline_ns == null);
    try std.testing.expectEqual(@as(usize, 3), ps.caret);
}

test "#646 Esc 는 닫고 needle · caret 을 버린다" {
    const alloc = std.testing.allocator;
    var ps: search.PaneSearch = .{};
    defer ps.deinit(alloc);

    try seed(&ps, alloc, "abc");
    const e = try key(&ps, alloc, .close, 0);
    try std.testing.expect(e.closed);
    try std.testing.expect(!ps.is_open);
    try std.testing.expectEqual(@as(usize, 0), ps.caret);
    try std.testing.expectEqual(@as(usize, 0), ps.needle.items.len);
}

test "#646 컨트롤 클릭은 같은 이름의 키와 같은 일을 한다" {
    const alloc = std.testing.allocator;
    var ps: search.PaneSearch = .{};
    defer ps.deinit(alloc);

    try seed(&ps, alloc, "abc");
    const e = try control(&ps, alloc, .close, 0);
    try std.testing.expect(e.closed);
    try std.testing.expect(!ps.is_open);
}

test "#646 엔진이 없으면 매치 이동은 아무 일도 하지 않는다" {
    const alloc = std.testing.allocator;
    var ps: search.PaneSearch = .{};
    defer ps.deinit(alloc);

    try seed(&ps, alloc, "ab"); // 디바운스 중 — 엔진이 아직 없다
    try std.testing.expect(!(try key(&ps, alloc, .match_down, 0)).redraw);
    try std.testing.expect(!(try key(&ps, alloc, .match_up, 0)).redraw);
}

test "#646 여러 줄 paste 는 첫 줄만 넣는다" {
    const alloc = std.testing.allocator;
    var ps: search.PaneSearch = .{};
    defer ps.deinit(alloc);

    ps.open();
    _ = try insertText(&ps, alloc, "가나다\nlater\n", 0);
    try std.testing.expectEqualStrings("가나다", ps.needle.items);
    try std.testing.expectEqual(@as(usize, 9), ps.caret);

    // 개행으로 시작하면 아무것도 안 들어간다.
    const e = try insertText(&ps, alloc, "\n\n", 0);
    try std.testing.expect(!e.redraw);
    try std.testing.expectEqualStrings("가나다", ps.needle.items);
}
