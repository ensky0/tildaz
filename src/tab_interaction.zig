const std = @import("std");

pub const RenameKey = enum {
    enter,
    escape,
    backspace,
    left,
    right,
    home,
    end,
    delete,
};

pub const RenameOutcome = enum {
    none,
    changed,
    commit,
    cancel,
};

pub const RenameView = struct {
    tab_index: usize,
    text: *[RenameState.BUF_SIZE]u8,
    text_len: usize,
    cursor: usize,
};

pub const RenameCommit = struct {
    tab_index: usize,
    title: []const u8,
};

pub const RenameState = struct {
    tab_index: ?usize = null,
    buf: [BUF_SIZE]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,

    pub const BUF_SIZE = 64;
    const MAX_LEN = BUF_SIZE - 1;

    pub fn isActive(self: *const RenameState) bool {
        return self.tab_index != null;
    }

    pub fn begin(self: *RenameState, tab_index: usize, title: []const u8) void {
        const copy_len = @min(title.len, MAX_LEN);
        self.tab_index = tab_index;
        @memcpy(self.buf[0..copy_len], title[0..copy_len]);
        self.len = copy_len;
        self.cursor = copy_len;
    }

    pub fn clear(self: *RenameState) void {
        self.tab_index = null;
        self.len = 0;
        self.cursor = 0;
    }

    pub fn view(self: *RenameState) ?RenameView {
        const idx = self.tab_index orelse return null;
        return .{
            .tab_index = idx,
            .text = &self.buf,
            .text_len = self.len,
            .cursor = self.cursor,
        };
    }

    pub fn commitRequest(self: *RenameState) ?RenameCommit {
        const idx = self.tab_index orelse return null;
        return .{
            .tab_index = idx,
            .title = self.buf[0..self.len],
        };
    }

    pub fn insertCodepoint(self: *RenameState, cp: u21) bool {
        if (!self.isActive() or cp < 0x20) return false;

        var encoded: [4]u8 = undefined;
        const encoded_len = std.unicode.utf8Encode(cp, &encoded) catch return false;
        if (self.len + encoded_len > MAX_LEN) return false;

        if (self.cursor < self.len) {
            std.mem.copyBackwards(
                u8,
                self.buf[self.cursor + encoded_len .. self.len + encoded_len],
                self.buf[self.cursor..self.len],
            );
        }
        @memcpy(self.buf[self.cursor .. self.cursor + encoded_len], encoded[0..encoded_len]);
        self.len += encoded_len;
        self.cursor += encoded_len;
        return true;
    }

    pub fn handleKey(self: *RenameState, key: RenameKey) RenameOutcome {
        if (!self.isActive()) return .none;

        switch (key) {
            .enter => return .commit,
            .escape => return .cancel,
            .backspace => return self.backspace(),
            .delete => return self.delete(),
            .left => return self.moveLeft(),
            .right => return self.moveRight(),
            .home => {
                if (self.cursor == 0) return .none;
                self.cursor = 0;
                return .changed;
            },
            .end => {
                if (self.cursor == self.len) return .none;
                self.cursor = self.len;
                return .changed;
            },
        }
    }

    fn backspace(self: *RenameState) RenameOutcome {
        if (self.cursor == 0) return .none;
        const prev = self.prevCharStart(self.cursor);
        const char_len = self.cursor - prev;
        std.mem.copyForwards(
            u8,
            self.buf[prev .. self.len - char_len],
            self.buf[self.cursor..self.len],
        );
        self.len -= char_len;
        self.cursor = prev;
        return .changed;
    }

    fn delete(self: *RenameState) RenameOutcome {
        if (self.cursor >= self.len) return .none;
        const char_len = self.charLenAt(self.cursor);
        const end = @min(self.cursor + char_len, self.len);
        const actual_len = end - self.cursor;
        std.mem.copyForwards(
            u8,
            self.buf[self.cursor .. self.len - actual_len],
            self.buf[end..self.len],
        );
        self.len -= actual_len;
        return .changed;
    }

    fn moveLeft(self: *RenameState) RenameOutcome {
        if (self.cursor == 0) return .none;
        self.cursor = self.prevCharStart(self.cursor);
        return .changed;
    }

    fn moveRight(self: *RenameState) RenameOutcome {
        if (self.cursor >= self.len) return .none;
        self.cursor = @min(self.cursor + self.charLenAt(self.cursor), self.len);
        return .changed;
    }

    fn prevCharStart(self: *const RenameState, cursor: usize) usize {
        var prev = cursor - 1;
        while (prev > 0 and self.buf[prev] & 0xC0 == 0x80) prev -= 1;
        return prev;
    }

    fn charLenAt(self: *const RenameState, index: usize) usize {
        const b = self.buf[index];
        return if (b < 0x80) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
    }
};

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
    rename: RenameState = .{},
    drag: DragState = .{},
};

test "rename insert and utf8 cursor movement" {
    var rename = RenameState{};
    rename.begin(0, "ab");
    try std.testing.expect(rename.insertCodepoint('한'));
    try std.testing.expectEqualStrings("ab한", rename.buf[0..rename.len]);
    try std.testing.expectEqual(RenameOutcome.changed, rename.handleKey(.left));
    try std.testing.expect(rename.insertCodepoint('Z'));
    try std.testing.expectEqualStrings("abZ한", rename.buf[0..rename.len]);
}

test "drag finish returns clamped reorder request" {
    var drag = DragState{};
    try std.testing.expect(drag.begin(10, 100, 3));
    try std.testing.expect(drag.move(280));
    const request = drag.finish(100, 3) orelse return error.ExpectedReorder;
    try std.testing.expectEqual(@as(usize, 0), request.from);
    try std.testing.expectEqual(@as(usize, 2), request.to);
    try std.testing.expect(!drag.active);
}
