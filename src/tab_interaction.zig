const std = @import("std");

pub const ReorderRequest = struct {
    from: usize,
    to: usize,
};

pub const DragView = struct {
    tab_index: usize,
    current_x: c_int,
};

pub const DragState = struct {
    active: bool = false,
    dragging: bool = false,
    tab_index: usize = 0,
    start_x: c_int = 0,
    current_x: c_int = 0,

    pub fn begin(self: *DragState, mouse_x: c_int, tab_width: c_int, tab_count: usize) bool {
        self.reset();
        if (tab_width <= 0) return false;
        const idx_raw = @divTrunc(mouse_x, tab_width);
        if (idx_raw < 0) return false;
        const idx: usize = @intCast(idx_raw);
        if (idx >= tab_count) return false;

        self.active = true;
        self.tab_index = idx;
        self.start_x = mouse_x;
        self.current_x = mouse_x;
        return true;
    }

    pub fn move(self: *DragState, mouse_x: c_int) bool {
        if (!self.active) return false;
        const delta = if (mouse_x > self.start_x) mouse_x - self.start_x else self.start_x - mouse_x;
        if (delta > 5) self.dragging = true;
        self.current_x = mouse_x;
        return true;
    }

    pub fn finish(self: *DragState, tab_width: c_int, tab_count: usize) ?ReorderRequest {
        defer self.reset();
        if (!self.dragging or tab_width <= 0 or tab_count <= 1 or self.tab_index >= tab_count) return null;

        var target_raw = @divTrunc(self.current_x, tab_width);
        target_raw = @max(0, @min(target_raw, @as(c_int, @intCast(tab_count - 1))));
        const target: usize = @intCast(target_raw);
        if (target == self.tab_index) return null;
        return .{ .from = self.tab_index, .to = target };
    }

    pub fn reset(self: *DragState) void {
        self.active = false;
        self.dragging = false;
        self.tab_index = 0;
        self.start_x = 0;
        self.current_x = 0;
    }

    pub fn view(self: *const DragState) ?DragView {
        if (!self.dragging) return null;
        return .{ .tab_index = self.tab_index, .current_x = self.current_x };
    }
};

pub const TabInteraction = struct {
    drag: DragState = .{},
};

test "drag finish returns clamped reorder request" {
    var drag = DragState{};
    try std.testing.expect(drag.begin(10, 100, 3));
    try std.testing.expect(drag.move(280));
    const request = drag.finish(100, 3) orelse return error.ExpectedReorder;
    try std.testing.expectEqual(@as(usize, 0), request.from);
    try std.testing.expectEqual(@as(usize, 2), request.to);
    try std.testing.expect(!drag.active);
}
