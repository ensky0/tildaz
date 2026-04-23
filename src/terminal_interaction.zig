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

pub fn selectWord(screen: *ghostty.Screen, cell: Cell) bool {
    const pin = screen.pages.pin(.{ .viewport = .{ .x = cell.col, .y = cell.row } }) orelse return false;
    const selection = screen.selectWord(pin, &word_boundaries) orelse return false;
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
