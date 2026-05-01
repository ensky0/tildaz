const std = @import("std");
const ghostty = @import("ghostty-vt");

pub const Cell = struct {
    col: u16,
    row: u16,
};

pub const SelectionState = struct {
    active: bool = false,
    start_pin: ?ghostty.PageList.Pin = null,

    pub fn begin(self: *SelectionState, screen: *ghostty.Screen, cell: Cell) void {
        self.active = true;
        screen.clearSelection();
        self.start_pin = screen.pages.pin(.{ .viewport = .{ .x = cell.col, .y = cell.row } });
    }

    pub fn update(self: *SelectionState, screen: *ghostty.Screen, cell: Cell) void {
        if (!self.active) return;
        const start = self.start_pin orelse return;
        const end = screen.pages.pin(.{ .viewport = .{ .x = cell.col, .y = cell.row } }) orelse return;
        const selection = ghostty.Selection.init(start, end, false);
        screen.select(selection) catch {};
    }

    pub fn finish(self: *SelectionState) bool {
        if (!self.active) return false;
        self.active = false;
        self.start_pin = null;
        return true;
    }

    pub fn cancel(self: *SelectionState) void {
        self.active = false;
        self.start_pin = null;
    }
};

pub const ScrollbarDragState = struct {
    active: bool = false,

    pub fn begin(self: *ScrollbarDragState) void {
        self.active = true;
    }

    pub fn end(self: *ScrollbarDragState) void {
        self.active = false;
    }
};

pub const TerminalInteraction = struct {
    selection: SelectionState = .{},
    scrollbar: ScrollbarDragState = .{},

    pub fn cancelPointerModes(self: *TerminalInteraction) void {
        self.selection.cancel();
        self.scrollbar.end();
    }
};

/// 더블클릭 word selection — ghostty 의 `selectWord` 가 wide char (한/中/日 등)
/// 의 spacer_tail cell (글자의 right-half) 을 boundary 로 취급해 (i) 음절 사이
/// 클릭 시 null, (ii) 글자 위 클릭 시 그 음절 한 개만 선택. 우리가 직접 구현해
/// spacer_tail 은 같은 word 의 continuation 으로 처리.
///
/// 알고리즘 — ghostty `selectWord` 와 동일 구조 (`Screen.zig:2784`) 지만
/// spacer_tail 은 `expect_boundary` 검사 *없이* 통과하고 다음 cell 로 진행.
pub fn selectWord(screen: *ghostty.Screen, cell: Cell) bool {
    var start_pin = screen.pages.pin(.{ .viewport = .{ .x = cell.col, .y = cell.row } }) orelse return false;

    // spacer_tail cell 위 클릭이면 wide char main cell (왼쪽 한 칸) 으로 정규화.
    {
        const rac = start_pin.rowAndCell();
        if (rac.cell.wide == .spacer_tail and start_pin.x > 0) {
            start_pin.x -= 1;
        }
    }

    const start_rac = start_pin.rowAndCell();
    if (!start_rac.cell.hasText()) return false;

    const start_cp = start_rac.cell.content.codepoint;
    // 시작 cell 이 boundary 문자 (공백 / 따옴표 / 구두점 등) 면 더블클릭 word
    // selection 의도가 아니라고 보고 무시. ghostty default 는 boundary 끼리도
    // 묶지만, 터미널 사용자가 expect 하는 동작은 "단어 본체만 선택" — iTerm2 /
    // Terminal.app 동등. 시작이 word body 인 경우만 양쪽 확장.
    if (std.mem.indexOfAny(u21, &word_boundaries, &.{start_cp}) != null) return false;
    const expect_boundary = false;

    // forward — 양쪽으로 같은 boundary 상태인 cell 까지 확장.
    const end: ghostty.Pin = blk: {
        var it = start_pin.cellIterator(.right_down, null);
        var prev = it.next().?;
        while (it.next()) |p| {
            const rac = p.rowAndCell();
            // spacer_tail 은 wide char 의 right-half — codepoint=0 이지만 같은
            // 글자라 word continuation 으로 처리. boundary 검사 skip + prev 만 update.
            if (rac.cell.wide == .spacer_tail) {
                prev = p;
                continue;
            }
            if (!rac.cell.hasText()) break :blk prev;
            const this_b = std.mem.indexOfAny(u21, &word_boundaries, &.{rac.cell.content.codepoint}) != null;
            if (this_b != expect_boundary) break :blk prev;
            if (p.x == p.node.data.size.cols - 1 and !rac.row.wrap) break :blk p;
            prev = p;
        }
        break :blk prev;
    };

    // backward — 같은 logic 의 거울.
    const start: ghostty.Pin = blk: {
        var it = start_pin.cellIterator(.left_up, null);
        var prev = it.next().?;
        while (it.next()) |p| {
            const rac = p.rowAndCell();
            if (rac.cell.wide == .spacer_tail) {
                prev = p;
                continue;
            }
            if (p.x == p.node.data.size.cols - 1 and !rac.row.wrap) break :blk prev;
            if (!rac.cell.hasText()) break :blk prev;
            const this_b = std.mem.indexOfAny(u21, &word_boundaries, &.{rac.cell.content.codepoint}) != null;
            if (this_b != expect_boundary) break :blk prev;
            prev = p;
        }
        break :blk prev;
    };

    const selection = ghostty.Selection.init(start, end, false);
    screen.select(selection) catch return false;
    return true;
}

const word_boundaries = [_]u21{ ' ', '\t', '"', '`', '|', ':', ';', '(', ')', '[', ']', '{', '}', '<', '>' };

test "selection finish and cancel clear active state" {
    var selection = SelectionState{ .active = true };
    try std.testing.expect(selection.finish());
    try std.testing.expect(!selection.active);
    try std.testing.expect(!selection.finish());

    selection.active = true;
    selection.cancel();
    try std.testing.expect(!selection.active);
}

test "scrollbar drag state toggles explicitly" {
    var scrollbar = ScrollbarDragState{};
    scrollbar.begin();
    try std.testing.expect(scrollbar.active);
    scrollbar.end();
    try std.testing.expect(!scrollbar.active);
}
