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
const ui_rect = @import("ui_rect.zig");
const ui_metrics = @import("ui_metrics.zig");
const chrome_palette = @import("chrome_palette.zig");

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
/// hover / focus 강조 박스가 항목 rect 안으로 물러나는 양. 좌우가 위아래보다 큰
/// 이유는 항목이 세로로 촘촘해서 (22pt) 위아래를 더 깎으면 띠가 얇아지기 때문.
pub const HIGHLIGHT_INSET_X_PT: f32 = 2;
pub const HIGHLIGHT_INSET_Y_PT: f32 = 1;
/// 항목 구분선이 메뉴 좌우 끝에서 물러나는 양 — 선이 면 경계까지 닿지 않게.
pub const SEPARATOR_INSET_PT: f32 = 8;
/// label 과 shortcut hint 사이 최소 간격 — 못 지키면 hint 를 숨긴다.
pub const HINT_GAP_PT: f32 = 16;

pub const Command = enum {
    toggle_visibility,
    new_tab,
    /// #483 4c — 활성 pane 분할. 마우스 경로 (우클릭은 붙여넣기라 컨텍스트 메뉴를 못 쓴다).
    split_right,
    split_down,
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
    .split_right,
    .split_down,
    .close_active_tab,
    .copy_selection,
    .paste,
    .fullscreen,
    .open_config,
    null,
    .keyboard_shortcuts,
    .about,
};

/// 전체 content 높이 (padding 제외) — 항목과 구분선을 `entries` 에서 센다 (항목 11 + 구분선 2).
const CONTENT_HEIGHT_PT: f32 = blk: {
    var h: f32 = 0;
    for (entries) |entry| h += entryHeight(entry);
    break :blk h;
};
pub const HEIGHT_PT: f32 = PADDING_PT * 2 + CONTENT_HEIGHT_PT;

fn entryHeight(entry: ?Command) f32 {
    return if (entry != null) ITEM_HEIGHT_PT else SEPARATOR_HEIGHT_PT;
}

pub fn label(command: Command) []const u8 {
    return switch (command) {
        .toggle_visibility => messages.command_toggle_visibility,
        .new_tab => messages.command_new_tab,
        .split_right => messages.command_split_right,
        .split_down => messages.command_split_down,
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
        .split_right => if (macos) messages.shortcut_split_right_macos else messages.shortcut_split_right,
        .split_down => if (macos) messages.shortcut_split_down_macos else messages.shortcut_split_down,
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

// ── 그리기 rect (#343 단계 3) ────────────────────────────────────────────────

/// `rects` 가 만들 수 있는 rect 최대 개수 — 호출처 고정 버퍼 크기 산정용.
/// 메뉴 배경 1 + 강조 박스 1 + 구분선 (`entries` 의 `null` 개수).
pub const MAX_RECTS: usize = blk: {
    var seps: usize = 0;
    for (entries) |entry| {
        if (entry == null) seps += 1;
    }
    break :blk 2 + seps;
};

/// 모든 rect 를 **정수 격자에 맞춰** 내보낸다 (#357 — `ui_rect.snapped`).
/// `tab_chrome.push` 와 대칭이다. 소수 좌표에서는 Linux 의 `snap`(양 끝 반올림)과
/// GPU 반열림 래스터화의 tie-break 가 갈린다 — 항목 구분선 y 가 `(r.y + r.h/2)`
/// 라 **항상 `.5`** 가 남아, 배율 1.0 에서 Windows 는 픽셀 `60`, Linux 는 `61` 로
/// 갈렸다 ([Windows 실측](https://github.com/ensky0/tildaz/issues/357#issuecomment-5143421541)).
/// 탭바에서 닫은 갈래가 메뉴에만 남아 있던 것을 여기서 닫는다.
fn push(out: []ui_rect.Rect, n: *usize, r: ui_rect.Rect) void {
    if (n.* >= out.len) return; // 호출처 버퍼 상한 — `MAX_RECTS` 로 산정한다.
    out[n.*] = ui_rect.snapped(r);
    n.* += 1;
}

/// #343 단계 3 — 메뉴의 **색칠된 사각형 목록**. 세 renderer 가 이 함수 하나를
/// 호출하고, 목록을 그린 뒤 자기 고유의 텍스트 (label · hint) 와 아이콘
/// (`chevron_up` / `chevron_down` 스크롤 표시) 을 그린다.
///
/// ## 그리는 순서 (정본)
///
/// ```
///   메뉴 배경 → hover/focus 강조 → 항목 구분선 × n
///   (renderer)  텍스트 · 스크롤 표시 아이콘
/// ```
///
/// 통합 전 Linux 는 `배경 → 강조 → 구분선`, macOS · Windows 는 `배경 → 구분선 →
/// 강조` 였다 ([`macos.zig:1336`](renderer/macos.zig) 과 Windows 는 서로 같은
/// 코드였고 Linux 만 갈라졌다). 구분선은 `null` entry 의 행 중앙에, 강조는
/// command 항목 행에 놓이므로 **서로 다른 행이라 겹치는 픽셀이 없다** — 순서
/// 통일은 시각에 영향을 주지 않는다.
///
/// 또한 통합 전 Linux 는 구분선을 항목 loop 안에서 텍스트와 교대로 방출했다.
/// 여기서는 "구분선 전부 → 텍스트 전부" 로 평탄화되는데, GPU renderer 는 어차피
/// 버퍼 단위 flush 라 이미 평탄한 순서로 그리고 있었다.
///
/// 좌표는 device px f32. Linux software rasterizer 는 `ui_rect.snap` 으로 정수화
/// 한다 — 위치와 크기를 따로 반올림하던 것이 이 통합으로 사라진다
/// ([#344](https://github.com/ensky0/tildaz/issues/344) 와 같은 계약).
pub fn rects(
    out: []ui_rect.Rect,
    v: View,
    ui: Ui,
    scale: f32,
    palette: *const chrome_palette.Palette,
) []const ui_rect.Rect {
    var n: usize = 0;

    // 1. 메뉴 배경. #342 — **외곽선 없음** (2026-07-27 시연 후 사용자 확정).
    //    탭바에서 가로 경계선을 없앤 것과 같은 문법: chrome 과 terminal 의 경계는
    //    배경 명도 차이만으로 둔다. 내부 구분선은 유지 (역할이 다름 — 면의 경계가
    //    아니라 항목 그룹).
    push(out, &n, .{
        .x = v.rect.x * scale,
        .y = v.rect.y * scale,
        .w = v.rect.w * scale,
        .h = v.rect.h * scale,
        .color = palette.tab_bar_bg,
    });

    // 2. 강조는 pointer hover 우선, 없으면 keyboard focus.
    if (ui.hover orelse ui.focused) |command| {
        if (itemRect(v, command)) |item| {
            push(out, &n, .{
                .x = (item.x + HIGHLIGHT_INSET_X_PT) * scale,
                .y = (item.y + HIGHLIGHT_INSET_Y_PT) * scale,
                .w = (item.w - HIGHLIGHT_INSET_X_PT * 2) * scale,
                .h = (item.h - HIGHLIGHT_INSET_Y_PT * 2) * scale,
                .color = palette.menu_hover_bg,
            });
        }
    }

    // 3. 항목 구분선 — 1 logical pt 두께로 HiDPI 에서 상대 두께를 유지한다 (#329).
    //    #357 — 두께는 **정수 px** 다. 소수로 두면 선의 y 소수부에 따라 덮는 행 수가
    //    갈려 같은 메뉴 안 두 구분선의 두께가 달라졌다 (@1.7 에서 2px / 1px).
    //    탭바 세로 구분선과 같은 상수·같은 함수를 쓴다.
    const line_px = ui_metrics.linePx(ui_metrics.TAB_SEPARATOR_W_PT, scale);
    for (v.first..v.first + v.count) |i| {
        if (entries[i] != null) continue;
        const r = entryRect(v, i).?;
        push(out, &n, .{
            .x = v.rect.x * scale + SEPARATOR_INSET_PT * scale,
            .y = (r.y + r.h / 2) * scale,
            .w = v.rect.w * scale - SEPARATOR_INSET_PT * 2 * scale,
            .h = line_px,
            .color = palette.separator,
        });
    }

    return out[0..n];
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
    // new [65,87) / split_right [87,109) / split_down [109,131) / close [131,153) /
    // copy [153,175) / paste [175,197) / fs [197,219) / config [219,241) / sep [241,250) /
    // ks [250,272) / about [272,294).
    try std.testing.expectEqual(Command.toggle_visibility, hit(v, 490, 40).?);
    try std.testing.expect(hit(v, 490, 60) == null); // first separator
    try std.testing.expectEqual(Command.new_tab, hit(v, 490, 70).?);
    try std.testing.expectEqual(Command.split_right, hit(v, 490, 90).?);
    try std.testing.expectEqual(Command.split_down, hit(v, 490, 120).?);
    try std.testing.expectEqual(Command.open_config, hit(v, 490, 230).?);
    try std.testing.expect(hit(v, 490, 245) == null); // second separator
    try std.testing.expectEqual(Command.keyboard_shortcuts, hit(v, 490, 255).?);
    try std.testing.expectEqual(Command.about, hit(v, 490, 280).?);
    try std.testing.expect(hit(v, 470, 40) == null); // 메뉴 왼쪽 밖
}

test "narrow viewport clamps menu to the left edge" {
    const v = view(120, 600, 28, 0);
    try std.testing.expectEqual(@as(f32, 0), v.rect.x);
    try std.testing.expectEqual(@as(f32, 120), v.rect.w);
}

test "#329 short viewport quantizes to whole entries and scrolls to reach the tail" {
    // avail_full = 200-28-8-12 = 152 < content 260 → clipped, avail = 152-28 = 124.
    // toggle(22)+sep(9)+new(22)+split_right(22)+split_down(22)+close(22) = 119 ≤ 124 → 6 entry.
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

test "#343 rects — 정본 순서와 지오메트리 (배경 → 강조 → 구분선)" {
    const palette = chrome_palette.derive(.{ 0, 0, 0 }, true);
    var buf: [MAX_RECTS]ui_rect.Rect = undefined;

    // 잘림 없는 뷰 (viewport 800x600, 탭바 28) — entry 13개 전부 보이고 구분선 2개.
    const v = view(800, 600, 28, 0);
    const with_hover = rects(&buf, v, .{ .open = true, .hover = .new_tab }, 1.0, &palette);
    try std.testing.expectEqual(@as(usize, 4), with_hover.len); // bg + 강조 + 구분선 2

    // 배경 — View.rect 그대로.
    try std.testing.expectEqual(@as(f32, 480), with_hover[0].x);
    try std.testing.expectEqual(@as(f32, 28), with_hover[0].y);
    try std.testing.expectEqual(@as(f32, 320), with_hover[0].w);
    try std.testing.expectEqual(@as(f32, HEIGHT_PT), with_hover[0].h);
    try std.testing.expectEqual(palette.tab_bar_bg, with_hover[0].color);

    // 강조 — new_tab 항목 [65,87) 에서 좌우 2 / 위아래 1 물러난다.
    const item = itemRect(v, .new_tab).?;
    try std.testing.expectEqual(item.x + 2, with_hover[1].x);
    try std.testing.expectEqual(item.y + 1, with_hover[1].y);
    try std.testing.expectEqual(item.w - 4, with_hover[1].w);
    try std.testing.expectEqual(item.h - 2, with_hover[1].h);
    try std.testing.expectEqual(palette.menu_hover_bg, with_hover[1].color);

    // 구분선 — 메뉴 좌우에서 8 물러나고 두께 1pt, `null` entry 행 중앙.
    try std.testing.expectEqual(@as(f32, 488), with_hover[2].x);
    try std.testing.expectEqual(@as(f32, 304), with_hover[2].w);
    try std.testing.expectEqual(@as(f32, 1), with_hover[2].h);
    try std.testing.expectEqual(palette.separator, with_hover[2].color);
    // 첫 구분선 [56,65) 의 중앙 = 60.5, 두 번째 [241,250) 의 중앙 = 245.5 →
    // #357 로 **정수 격자에 맞춰** 61 / 246 로 나온다. 소수 `.5` 를 그대로 두면
    // Linux(`@round` → 61) 와 GPU(`[60.5,61.5)` → 60) 가 갈렸다 (Windows 실측).
    try std.testing.expectEqual(@as(f32, 61), with_hover[2].y);
    try std.testing.expectEqual(@as(f32, 246), with_hover[3].y);

    // hover 도 focus 도 없으면 강조 rect 를 만들지 않는다.
    const plain = rects(&buf, v, .{ .open = true }, 1.0, &palette);
    try std.testing.expectEqual(@as(usize, 3), plain.len);
    // hover 가 없으면 keyboard focus 가 강조를 받는다 (hover orelse focused).
    const focused = rects(&buf, v, .{ .open = true, .focused = .about }, 1.0, &palette);
    try std.testing.expectEqual(@as(usize, 4), focused.len);
    try std.testing.expectEqual(itemRect(v, .about).?.y + 1, focused[1].y);
    // 스크롤로 안 보이는 항목이 focus 면 강조를 만들지 않는다 (itemRect = null).
    const short = view(800, 200, 28, 0);
    try std.testing.expect(itemRect(short, .about) == null);
    const off = rects(&buf, short, .{ .open = true, .focused = .about }, 1.0, &palette);
    try std.testing.expectEqual(@as(usize, 2), off.len); // bg + 보이는 구분선 1개
}

test "#343 rects — scale 을 곱하고 구분선은 최소 1px" {
    const palette = chrome_palette.derive(.{ 0, 0, 0 }, true);
    var buf: [MAX_RECTS]ui_rect.Rect = undefined;
    const v = view(800, 600, 28, 0);

    const r17 = rects(&buf, v, .{ .open = true }, 1.7, &palette);
    try std.testing.expectEqual(@as(f32, 480 * 1.7), r17[0].x);
    try std.testing.expectEqual(@as(f32, 320 * 1.7), r17[0].w);
    // #357 — 구분선 두께는 **정수** px (`ui_metrics.linePx`). 1pt × 1.7 = 1.7 → 2.
    // 소수(1.7)로 두면 선의 y 소수부에 따라 2px / 1px 로 갈렸다.
    try std.testing.expectEqual(@as(f32, 2), r17[1].h);

    // Linux 정수 스냅 — 양 끝을 각각 반올림하므로 우측 끝이 참값에 붙는다.
    // 배율 1.7 · 구분선 x = 480*1.7 + 13.6 = 829.6, 우측 끝 = 829.6 + 516.8 = 1346.4.
    // (`r17` 은 `buf` 를 가리키므로 다음 `rects` 호출 전에 확인한다.)
    const i = ui_rect.snap(r17[1]);
    try std.testing.expectEqual(@as(i32, 830), i.x);
    try std.testing.expectEqual(@as(i32, 1346 - 830), i.w);

    // scale < 1 에서도 구분선이 사라지지 않는다.
    const r05 = rects(&buf, v, .{ .open = true }, 0.5, &palette);
    try std.testing.expectEqual(@as(f32, 1), r05[1].h);
}

test "#357 한 메뉴 안 두 구분선의 두께가 분수 배율에서도 균일하다" {
    // #357 의 증상 그 자체를 고정한다. 통합 전에는 두께가 소수(1pt × scale)라
    // 선의 y 소수부에 따라 덮는 행 수가 갈렸다 — @1.7 에서 첫 구분선(중심 60.5pt →
    // 102.85px)은 2px, 둘째(201.5pt → 342.55px)는 1px 이었다.
    const palette = chrome_palette.derive(.{ 0, 0, 0 }, true);
    var buf: [MAX_RECTS]ui_rect.Rect = undefined;
    const v = view(800, 600, 28, 0);

    inline for (.{ 1.0, 1.25, 1.5, 1.7, 1.75, 2.0, 2.5 }) |scale| {
        const rs = rects(&buf, v, .{ .open = true }, scale, &palette);
        try std.testing.expectEqual(@as(usize, 3), rs.len); // bg + 구분선 2

        // 두 구분선이 **같은 두께**이고, 정수 스냅 후에도 같아야 한다.
        try std.testing.expectEqual(rs[1].h, rs[2].h);
        const a = ui_rect.snap(rs[1]);
        const b = ui_rect.snap(rs[2]);
        try std.testing.expectEqual(a.h, b.h);
        try std.testing.expectEqual(a.w, b.w);
        // 두께는 1pt 를 반올림한 정수 px 이고 최소 1px 이다.
        try std.testing.expectEqual(ui_metrics.linePx(ui_metrics.TAB_SEPARATOR_W_PT, scale), rs[1].h);
        try std.testing.expect(a.h >= 1);
    }
}

test "#329 hint hides before label truncates in a narrow menu" {
    try std.testing.expect(hintFits(320, 120, 100));
    try std.testing.expect(!hintFits(160, 120, 100));
    try std.testing.expect(!hintFits(320, 120, 0)); // hint 없음 = 표시 안 함
}
