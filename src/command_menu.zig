//! #329 — `[+][×][…]`의 `…`가 여는 cross-platform command menu 모델.
//! 좌표는 logical pt; host renderer가 scale을 곱해 physical px로 변환한다.
//!
//! 작은 viewport 정책 — 메뉴 전체 높이(`HEIGHT_PT`)가 안 들어가면 entry 단위로
//! 잘라 세로 scroll 한다. scroll 은 entry 경계로만 움직여 **부분 행이 생기지
//! 않는다** — 세 renderer 가 텍스트 clip 없이 보이는 entry 만 그리면 된다.
//! 잘림 상태에서는 상/하단에 스크롤 표시 행(chevron up/down)이 생긴다 — 탭바의
//! `<`/`>` 처럼 끝에 닿으면 비활성 색, 클릭하면 한 entry 씩 스크롤 (#334 피드백).
//! 메뉴가 열린 동안 keyboard(Esc/Up/Down/Home/End/Tab/Enter/Space)/wheel 은
//! 메뉴가 소비하고 PTY 로 보내지 않는다. 정책 근거는 이슈 #329 계획 §6.

const std = @import("std");
const messages = @import("messages.zig");

/// 메뉴 폭. 320 → 280 (#334 행 높이 축소와 함께) → 300 (workarea 상태의
/// `Shift+Cmd+Enter` hint 가 label 과 함께 들어가게) → 320 (300 도 1pt 차이로 탈락 — 최장 조합 기준 여유 확보).
/// 안 들어가는 조합은 hintFits 가 hint 를 먼저 숨긴다.
pub const WIDTH_PT: f32 = 320;
pub const PADDING_PT: f32 = 6;
/// 항목 행 높이. 탭바(28pt)보다 촘촘하게 — #334 사용자 피드백. 시연 튜닝 예정.
pub const ITEM_HEIGHT_PT: f32 = 22;
pub const SEPARATOR_HEIGHT_PT: f32 = 9;
/// 잘림 상태의 상/하단 스크롤 표시 행 높이.
pub const INDICATOR_HEIGHT_PT: f32 = 14;
/// 메뉴 하단과 viewport 바닥 사이 최소 여백.
pub const BOTTOM_MARGIN_PT: f32 = 8;
/// 항목 rect 안 텍스트 좌우 inset (label 시작 / hint 끝 기준).
pub const TEXT_INSET_PT: f32 = 8;
/// label 과 shortcut hint 사이 최소 간격 — 못 지키면 hint 를 숨긴다.
pub const HINT_GAP_PT: f32 = 16;

pub const Command = enum {
    toggle_visibility,
    new_tab,
    close_active_tab,
    copy_selection,
    paste,
    fullscreen,
    open_config,
    keyboard_shortcuts,
    about,
};

pub const entries = [_]?Command{
    .toggle_visibility,
    null,
    .new_tab,
    .close_active_tab,
    .copy_selection,
    .paste,
    .fullscreen,
    .open_config,
    null,
    .keyboard_shortcuts,
    .about,
};

/// 전체 content 높이 (padding 제외) — 항목 9 + 구분선 2.
const CONTENT_HEIGHT_PT: f32 = ITEM_HEIGHT_PT * 9 + SEPARATOR_HEIGHT_PT * 2;
pub const HEIGHT_PT: f32 = PADDING_PT * 2 + CONTENT_HEIGHT_PT;

fn entryHeight(entry: ?Command) f32 {
    return if (entry != null) ITEM_HEIGHT_PT else SEPARATOR_HEIGHT_PT;
}

pub fn label(command: Command) []const u8 {
    return switch (command) {
        .toggle_visibility => messages.command_toggle_visibility,
        .new_tab => messages.command_new_tab,
        .close_active_tab => messages.command_close_active_tab,
        .copy_selection => messages.command_copy_selection,
        .paste => messages.command_paste,
        .fullscreen => messages.command_full_screen,
        .open_config => messages.command_open_config,
        .keyboard_shortcuts => messages.command_keyboard_shortcuts,
        .about => messages.command_about,
    };
}

/// `fullscreen_workarea` — 현재 workarea 전체화면 상태인지. 그 상태에서
/// Toggle Full Screen 이 하는 일은 해제이므로 hint 도 workarea 해제 키
/// (`Shift+Cmd+Enter` / `Alt+Shift+Enter`) 를 보여준다 (#334 사용자 결정).
pub fn shortcut(command: Command, macos: bool, toggle_hotkey: []const u8, fullscreen_workarea: bool) []const u8 {
    return switch (command) {
        .toggle_visibility => toggle_hotkey,
        .new_tab => if (macos) messages.shortcut_new_tab_macos else messages.shortcut_new_tab,
        .close_active_tab => if (macos) messages.shortcut_close_tab_macos else messages.shortcut_close_tab,
        .copy_selection => if (macos) messages.shortcut_copy_macos else messages.shortcut_copy,
        .paste => if (macos) messages.shortcut_paste_macos else messages.shortcut_paste,
        .fullscreen => if (fullscreen_workarea)
            (if (macos) messages.shortcut_full_screen_workarea_macos else messages.shortcut_full_screen_workarea)
        else
            (if (macos) messages.shortcut_full_screen_macos else messages.shortcut_full_screen),
        .open_config => if (macos) messages.shortcut_open_config_macos else messages.shortcut_open_config,
        .keyboard_shortcuts, .about => "",
    };
}

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

/// host → renderer 로 넘기는 메뉴 UI 상태 묶음. focused 는 keyboard focus,
/// hover 는 pointer — 그리기 강조는 hover 우선(hover orelse focused).
/// pointer 가 항목 위로 오면 host 가 focused 도 같은 항목으로 동기화한다.
pub const Ui = struct {
    open: bool = false,
    hover: ?Command = null,
    focused: ?Command = null,
    first_visible: usize = 0,
    /// 현재 workarea 전체화면 상태 — Toggle Full Screen 의 hint 선택용 (#334).
    fullscreen_workarea: bool = false,
};

/// viewport 에 맞춘 실제 메뉴 뷰. `first` 부터 `count` 개 entry 만 보인다.
/// `rect.h` 는 보이는 entry 높이 합 + padding (+ 잘림 시 indicator 두 행) —
/// 부분 행 없음.
pub const View = struct {
    rect: Rect,
    first: usize,
    count: usize,
    can_scroll_up: bool,
    can_scroll_down: bool,
    /// 잘림 상태 — 상/하단에 스크롤 표시 행이 있고 entry 시작 y 가 내려간다.
    clipped: bool,
};

/// `first_visible` 을 정규화하며 뷰를 계산한다. viewport 가 충분하면 전체
/// 11 entry 가 보이고 scroll 은 없다. 최소 한 entry 는 항상 보인다.
pub fn view(viewport_w_pt: f32, viewport_h_pt: f32, top_pt: f32, first_visible: usize) View {
    const avail_full = viewport_h_pt - top_pt - BOTTOM_MARGIN_PT - PADDING_PT * 2;
    const clipped = CONTENT_HEIGHT_PT > avail_full;
    const avail = if (clipped) avail_full - INDICATOR_HEIGHT_PT * 2 else avail_full;
    // 뒤에서부터: 마지막 entry 까지 보이는 데 필요한 최대 first (= scroll 상한).
    var max_first: usize = entries.len - 1;
    {
        var h: f32 = 0;
        var i: usize = entries.len;
        while (i > 0) {
            i -= 1;
            h += entryHeight(entries[i]);
            if (h > avail) break;
            max_first = i;
        }
    }
    const first = @min(first_visible, max_first);
    var count: usize = 0;
    var content_h: f32 = 0;
    for (entries[first..]) |entry| {
        const eh = entryHeight(entry);
        if (count > 0 and content_h + eh > avail) break;
        content_h += eh;
        count += 1;
    }
    const w = @min(viewport_w_pt, WIDTH_PT);
    const indicator_h: f32 = if (clipped) INDICATOR_HEIGHT_PT * 2 else 0;
    return .{
        .rect = .{ .x = @max(0, viewport_w_pt - WIDTH_PT), .y = top_pt, .w = w, .h = content_h + PADDING_PT * 2 + indicator_h },
        .first = first,
        .count = count,
        .can_scroll_up = first > 0,
        .can_scroll_down = first + count < entries.len,
        .clipped = clipped,
    };
}

/// 보이는 entry 의 rect. 안 보이면 null. `index` 는 entries 인덱스.
pub fn entryRect(v: View, index: usize) ?Rect {
    if (index < v.first or index >= v.first + v.count) return null;
    var y = v.rect.y + PADDING_PT + if (v.clipped) INDICATOR_HEIGHT_PT else 0;
    for (entries[v.first..index]) |entry| y += entryHeight(entry);
    return .{ .x = v.rect.x + PADDING_PT, .y = y, .w = v.rect.w - PADDING_PT * 2, .h = entryHeight(entries[index]) };
}

fn commandIndex(command: Command) usize {
    for (entries, 0..) |entry, i| {
        if (entry == command) return i;
    }
    unreachable;
}

/// 보이는 command 항목의 rect. 스크롤로 안 보이면 null.
pub fn itemRect(v: View, command: Command) ?Rect {
    return entryRect(v, commandIndex(command));
}

pub fn hit(v: View, x: f32, y: f32) ?Command {
    if (x < v.rect.x or x >= v.rect.x + v.rect.w or y < v.rect.y or y >= v.rect.y + v.rect.h) return null;
    for (v.first..v.first + v.count) |i| {
        const command = entries[i] orelse continue;
        const r = entryRect(v, i).?;
        if (x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h) return command;
    }
    return null;
}

pub const ScrollDir = enum { up, down };

/// 잘림 상태의 상/하단 스크롤 표시 행 hit (#334). 클릭 = 한 entry 스크롤,
/// 메뉴는 닫지 않는다. 탭바 `<`/`>` 와 같은 관례 — 끝에 닿아 비활성이어도
/// 자리는 유지 (클릭은 noop).
pub fn hitScrollIndicator(v: View, x: f32, y: f32) ?ScrollDir {
    if (!v.clipped) return null;
    if (x < v.rect.x or x >= v.rect.x + v.rect.w) return null;
    if (y >= v.rect.y and y < v.rect.y + PADDING_PT + INDICATOR_HEIGHT_PT) return .up;
    if (y >= v.rect.y + v.rect.h - PADDING_PT - INDICATOR_HEIGHT_PT and y < v.rect.y + v.rect.h) return .down;
    return null;
}

/// wheel / scroll indicator 용 — entry 단위 한 칸 이동한 새 first_visible.
pub fn scrollStep(v: View, down: bool) usize {
    if (down) {
        return if (v.can_scroll_down) v.first + 1 else v.first;
    }
    return if (v.can_scroll_up) v.first - 1 else v.first;
}

/// keyboard focus 이동으로 `command` 가 안 보이면 보이도록 first 조정.
pub fn ensureVisible(viewport_w_pt: f32, viewport_h_pt: f32, top_pt: f32, first_visible: usize, command: Command) usize {
    const idx = commandIndex(command);
    var first = @min(first_visible, idx);
    while (true) {
        const v = view(viewport_w_pt, viewport_h_pt, top_pt, first);
        if (idx < v.first + v.count) return v.first;
        first += 1;
    }
}

// ── keyboard modality ────────────────────────────────────────────────────────

pub const MenuKey = enum { up, down, home, end, tab, shift_tab, enter, space, escape, other };

pub const KeyOutcome = union(enum) {
    /// 소비 — 메뉴 유지 (focus 이동 포함). PTY 로 보내지 않는다.
    consumed,
    /// 메뉴 닫기 (Esc). 키는 소비.
    close,
    /// focus 항목 실행 — 메뉴 닫고 정확히 한 번 dispatch.
    activate: Command,
};

fn stepCommand(current: ?Command, forward: bool) Command {
    const count = @typeInfo(Command).@"enum".fields.len;
    const cur = current orelse {
        return if (forward) @enumFromInt(0) else @enumFromInt(count - 1);
    };
    const i: usize = @intFromEnum(cur);
    const next = if (forward) (i + 1) % count else (i + count - 1) % count;
    return @enumFromInt(next);
}

/// 메뉴가 열린 동안의 키 입력. 어떤 키든 소비된다 — native menu 와 동일하게
/// 인식 못한 키(.other) 도 뒤 terminal 로 보내지 않고 noop.
pub fn onKey(key: MenuKey, focused: *?Command) KeyOutcome {
    switch (key) {
        .escape => return .close,
        .up, .shift_tab => {
            focused.* = stepCommand(focused.*, false);
            return .consumed;
        },
        .down, .tab => {
            focused.* = stepCommand(focused.*, true);
            return .consumed;
        },
        .home => {
            focused.* = @enumFromInt(0);
            return .consumed;
        },
        .end => {
            focused.* = @enumFromInt(@typeInfo(Command).@"enum".fields.len - 1);
            return .consumed;
        },
        .enter, .space => {
            if (focused.*) |command| return .{ .activate = command };
            focused.* = @enumFromInt(0);
            return .consumed;
        },
        .other => return .consumed,
    }
}

// ── hint 표시 정책 ───────────────────────────────────────────────────────────

/// label 과 hint 가 한 행에 함께 안 들어가면 hint 를 먼저 숨긴다 (label 우선).
/// 폭은 모두 logical pt — renderer 가 측정 px 를 scale 로 나눠 전달.
pub fn hintFits(item_w_pt: f32, label_w_pt: f32, hint_w_pt: f32) bool {
    if (hint_w_pt <= 0) return false;
    return label_w_pt + HINT_GAP_PT + hint_w_pt + TEXT_INSET_PT * 2 <= item_w_pt;
}

// ── 테스트 ───────────────────────────────────────────────────────────────────

test "command menu order and hit rectangles include separator gap" {
    const v = view(800, 600, 28, 0);
    try std.testing.expectEqual(@as(f32, 480), v.rect.x); // 800 - WIDTH(320)
    try std.testing.expectEqual(@as(f32, HEIGHT_PT), v.rect.h);
    try std.testing.expectEqual(@as(usize, entries.len), v.count);
    try std.testing.expect(!v.can_scroll_up and !v.can_scroll_down and !v.clipped);
    try std.testing.expect(hitScrollIndicator(v, 490, 30) == null); // 잘림 없음 = 표시 행 없음
    // 항목 y (ITEM=22, SEP=9, PAD=6, top=28): toggle [34,56) / sep [56,65) /
    // new [65,87) / close [87,109) / copy [109,131) / paste [131,153) /
    // fs [153,175) / config [175,197) / sep [197,206) / ks [206,228) / about [228,250).
    try std.testing.expectEqual(Command.toggle_visibility, hit(v, 490, 40).?);
    try std.testing.expect(hit(v, 490, 60) == null); // first separator
    try std.testing.expectEqual(Command.new_tab, hit(v, 490, 70).?);
    try std.testing.expectEqual(Command.open_config, hit(v, 490, 180).?);
    try std.testing.expect(hit(v, 490, 200) == null); // second separator
    try std.testing.expectEqual(Command.keyboard_shortcuts, hit(v, 490, 210).?);
    try std.testing.expectEqual(Command.about, hit(v, 490, 240).?);
    try std.testing.expect(hit(v, 470, 40) == null); // 메뉴 왼쪽 밖
}

test "narrow viewport clamps menu to the left edge" {
    const v = view(120, 600, 28, 0);
    try std.testing.expectEqual(@as(f32, 0), v.rect.x);
    try std.testing.expectEqual(@as(f32, 120), v.rect.w);
}

test "#329 short viewport quantizes to whole entries and scrolls to reach the tail" {
    // avail_full = 200-28-8-12 = 152 < content 216 → clipped, avail = 152-28 = 124.
    // toggle(22)+sep(9)+new(22)+close(22)+copy(22)+paste(22) = 119 ≤ 124 → 6 entry.
    const v = view(800, 200, 28, 0);
    try std.testing.expect(v.clipped);
    try std.testing.expectEqual(@as(usize, 6), v.count);
    try std.testing.expect(v.can_scroll_down and !v.can_scroll_up);
    // 첫 항목 y = 28 + 6(pad) + 14(indicator) = 48.
    try std.testing.expectEqual(@as(f32, 48), itemRect(v, .toggle_visibility).?.y);
    try std.testing.expect(itemRect(v, .about) == null); // 스크롤 전 안 보임

    // 스크롤 표시 행 hit — 상단은 비활성(경계 반환은 동일), 하단 클릭 = down.
    try std.testing.expectEqual(ScrollDir.up, hitScrollIndicator(v, 490, 30).?);
    try std.testing.expectEqual(ScrollDir.down, hitScrollIndicator(v, 490, v.rect.y + v.rect.h - 10).?);
    try std.testing.expect(hitScrollIndicator(v, 490, 100) == null); // entry 영역

    // 끝까지 스크롤하면 about 이 보이고, first 는 상한에서 멈춘다.
    var first: usize = 0;
    var guard: usize = 0;
    while (guard < 32) : (guard += 1) {
        const cur = view(800, 200, 28, first);
        if (!cur.can_scroll_down) break;
        first = scrollStep(cur, true);
    }
    const tail = view(800, 200, 28, first);
    try std.testing.expect(itemRect(tail, .about) != null);
    try std.testing.expect(tail.can_scroll_up and !tail.can_scroll_down);
    try std.testing.expectEqual(first, scrollStep(tail, true)); // 더 안 내려감

    // ensureVisible 로 한 번에 도달해도 같은 결과.
    const jumped = ensureVisible(800, 200, 28, 0, .about);
    const jv = view(800, 200, 28, jumped);
    try std.testing.expect(itemRect(jv, .about) != null);

    // 극단적으로 낮아도 최소 한 entry 는 보인다.
    const tiny = view(800, 60, 28, 0);
    try std.testing.expect(tiny.count >= 1);
}

test "#329 menu keyboard focus cycles, activates, and consumes unknown keys" {
    var focused: ?Command = null;
    try std.testing.expectEqual(KeyOutcome.consumed, onKey(.down, &focused));
    try std.testing.expectEqual(Command.toggle_visibility, focused.?);
    try std.testing.expectEqual(KeyOutcome.consumed, onKey(.up, &focused));
    try std.testing.expectEqual(Command.about, focused.?); // wrap-around
    try std.testing.expectEqual(KeyOutcome.consumed, onKey(.tab, &focused));
    try std.testing.expectEqual(Command.toggle_visibility, focused.?);
    try std.testing.expectEqual(KeyOutcome.consumed, onKey(.end, &focused));
    try std.testing.expectEqual(Command.about, focused.?);
    try std.testing.expectEqual(KeyOutcome.consumed, onKey(.home, &focused));
    try std.testing.expectEqual(Command.toggle_visibility, focused.?);
    try std.testing.expectEqual(KeyOutcome{ .activate = .toggle_visibility }, onKey(.enter, &focused));
    try std.testing.expectEqual(KeyOutcome.close, onKey(.escape, &focused));
    try std.testing.expectEqual(KeyOutcome.consumed, onKey(.other, &focused));

    // focus 없이 Enter 는 실행 대신 첫 항목 focus.
    var blank: ?Command = null;
    try std.testing.expectEqual(KeyOutcome.consumed, onKey(.enter, &blank));
    try std.testing.expectEqual(Command.toggle_visibility, blank.?);
}

test "#329 hint hides before label truncates in a narrow menu" {
    try std.testing.expect(hintFits(320, 120, 100));
    try std.testing.expect(!hintFits(160, 120, 100));
    try std.testing.expect(!hintFits(320, 120, 0)); // hint 없음 = 표시 안 함
}
