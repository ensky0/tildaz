const std = @import("std");
const ghostty = @import("ghostty-vt");
const app_event = @import("app_event.zig");
const terminal_backend = @import("terminal_backend.zig");
const TerminalBackend = terminal_backend.TerminalBackend;
const themes = @import("themes.zig");
const perf = @import("perf.zig");
const tildaz_log = @import("tildaz_log.zig");

/// Lock-free 링버퍼 (단일 생산자, 단일 소비자)
const RingBuffer = struct {
    buf: [SIZE]u8 align(64) = undefined,
    head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    const SIZE = 4 * 1024 * 1024;

    fn push(self: *RingBuffer, data: []const u8) void {
        var i: usize = 0;
        while (i < data.len) {
            const pos = self.head.load(.monotonic);
            const t = self.tail.load(.acquire);
            const free = if (t <= pos) (SIZE - pos + t - 1) else (t - pos - 1);
            if (free == 0) {
                perf.incExtra(&perf.push);
                std.Thread.yield() catch {};
                continue;
            }
            const batch = @min(data.len - i, free);
            const first = @min(batch, SIZE - pos);
            @memcpy(self.buf[pos..][0..first], data[i..][0..first]);
            if (batch > first) {
                @memcpy(self.buf[0 .. batch - first], data[i + first ..][0 .. batch - first]);
            }
            self.head.store((pos + batch) % SIZE, .release);
            i += batch;
        }
    }

    fn isEmpty(self: *RingBuffer) bool {
        return self.head.load(.acquire) == self.tail.load(.acquire);
    }

    fn pop(self: *RingBuffer, out: []u8) usize {
        const h = self.head.load(.acquire);
        const t = self.tail.load(.monotonic);
        if (t == h) return 0;
        const avail = if (h >= t) (h - t) else (SIZE - t + h);
        const n = @min(avail, out.len);
        const first = @min(n, SIZE - t);
        @memcpy(out[0..first], self.buf[t..][0..first]);
        if (n > first) {
            @memcpy(out[first..n], self.buf[0 .. n - first]);
        }
        self.tail.store((t + n) % SIZE, .release);
        return n;
    }
};

/// PTY write용 큐 (UI → write 스레드)
const WriteQueue = struct {
    buf: [64 * 1024]u8 = undefined,
    head: usize = 0,
    tail: usize = 0,
    mutex: std.Thread.Mutex = .{},
    event: std.Thread.ResetEvent = .{},
    closed: bool = false,

    fn freeSpace(self: *const WriteQueue) usize {
        return if (self.tail <= self.head)
            self.buf.len - self.head + self.tail - 1
        else
            self.tail - self.head - 1;
    }

    fn push(self: *WriteQueue, data: []const u8) void {
        var i: usize = 0;
        while (i < data.len) {
            self.mutex.lock();
            if (self.closed) {
                self.mutex.unlock();
                return;
            }

            const free = self.freeSpace();
            if (free == 0) {
                self.mutex.unlock();
                std.Thread.yield() catch {};
                continue;
            }

            const batch = @min(data.len - i, free);
            const first = @min(batch, self.buf.len - self.head);
            @memcpy(self.buf[self.head..][0..first], data[i..][0..first]);
            if (batch > first) {
                @memcpy(self.buf[0 .. batch - first], data[i + first ..][0 .. batch - first]);
            }
            self.head = (self.head + batch) % self.buf.len;
            self.mutex.unlock();
            self.event.set();
            i += batch;
        }
    }

    fn pop(self: *WriteQueue, out: []u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        while (self.tail != self.head and n < out.len) {
            out[n] = self.buf[self.tail];
            self.tail = (self.tail + 1) % self.buf.len;
            n += 1;
        }
        return n;
    }

    fn close(self: *WriteQueue) void {
        self.mutex.lock();
        self.closed = true;
        self.mutex.unlock();
        self.event.set();
    }

    fn isClosed(self: *WriteQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.closed;
    }
};

pub const Tab = struct {
    terminal: ghostty.Terminal,
    stream: ghostty.TerminalStream,
    backend: TerminalBackend,
    title: [64]u8 = undefined,
    title_len: usize = 0,
    output_ring: RingBuffer = .{},
    write_queue: WriteQueue = .{},
    write_thread: ?std.Thread = null,
    tab_exit_fn: SessionCore.TabExitNotify,
    tab_exit_userdata: ?*anyopaque = null,

    fn init(
        alloc: std.mem.Allocator,
        cols: u16,
        rows: u16,
        shell: terminal_backend.ShellCommand,
        max_scroll_lines: usize,
        theme: ?*const themes.Theme,
        tab_exit_fn: SessionCore.TabExitNotify,
        tab_exit_userdata: ?*anyopaque,
    ) !*Tab {
        const tab = try alloc.create(Tab);
        errdefer alloc.destroy(tab);

        const term_colors = if (theme) |t| ghostty.Terminal.Colors{
            .foreground = ghostty.color.DynamicRGB.init(t.foreground),
            .background = ghostty.color.DynamicRGB.init(t.background),
            .cursor = .unset,
            .palette = ghostty.color.DynamicPalette.init(themes.buildPalette(t.palette)),
        } else ghostty.Terminal.Colors.default;

        var terminal = try ghostty.Terminal.init(alloc, .{
            .cols = cols,
            .rows = rows,
            .max_scrollback = max_scroll_lines * blk: {
                const cap = ghostty.page.std_capacity.adjust(.{ .cols = cols }) catch
                    break :blk (@as(usize, cols) + 1) * 8;
                break :blk ghostty.Page.layout(cap).total_size / cap.rows;
            },
            .colors = term_colors,
        });
        errdefer terminal.deinit(alloc);

        var backend = try TerminalBackend.init(.{
            .allocator = alloc,
            .cols = cols,
            .rows = rows,
            .shell = shell,
            .theme = theme,
        });
        errdefer backend.deinit();

        tab.* = .{
            .terminal = terminal,
            .stream = undefined,
            .backend = backend,
            .tab_exit_fn = tab_exit_fn,
            .tab_exit_userdata = tab_exit_userdata,
        };
        tab.stream = tab.terminal.vtStream();
        tab.write_thread = try std.Thread.spawn(.{}, writeLoop, .{tab});

        return tab;
    }

    fn deinit(tab: *Tab, alloc: std.mem.Allocator) void {
        tab.write_queue.close();
        if (tab.write_thread) |t| {
            t.join();
            tab.write_thread = null;
        }
        tab.backend.deinit();
        tab.terminal.deinit(alloc);
        alloc.destroy(tab);
    }

    pub fn queueWrite(tab: *Tab, data: []const u8) void {
        tab.write_queue.push(data);
    }

    fn drainOutput(tab: *Tab) void {
        const drain_t0 = perf.now();
        var buf: [65536]u8 = undefined;
        var total_bytes: u64 = 0;
        while (true) {
            const n = tab.output_ring.pop(&buf);
            if (n == 0) break;
            const parse_t0 = perf.now();
            tab.stream.nextSlice(buf[0..n]);
            perf.addTimed(&perf.parse, parse_t0);
            total_bytes += n;
        }
        perf.addTimedBytes(&perf.drain, drain_t0, total_bytes);
    }

    fn writeLoop(tab: *Tab) void {
        var buf: [256]u8 = undefined;
        while (true) {
            tab.write_queue.event.wait();
            tab.write_queue.event.reset();
            while (true) {
                const n = tab.write_queue.pop(&buf);
                if (n == 0) break;
                _ = tab.backend.write(buf[0..n]) catch break;
            }
            if (tab.write_queue.isClosed()) break;
        }
    }

    pub fn setTitle(tab: *Tab, title_id: usize) void {
        const result = std.fmt.bufPrint(&tab.title, "Tab {d}", .{title_id}) catch "Tab";
        tab.title_len = result.len;
    }

    pub fn setCustomTitle(tab: *Tab, title: []const u8) void {
        const len = @min(title.len, tab.title.len);
        @memcpy(tab.title[0..len], title[0..len]);
        tab.title_len = len;
    }

    fn onPtyOutput(data: []const u8, userdata: ?*anyopaque) void {
        const tab: *Tab = @ptrCast(@alignCast(userdata.?));
        const t0 = perf.now();
        tab.output_ring.push(data);
        perf.addTimedBytes(&perf.push, t0, data.len);
    }

    fn onPtyExit(userdata: ?*anyopaque) void {
        const tab: *Tab = @ptrCast(@alignCast(userdata.?));
        tildaz_log.appendLine("tab", "shell exited: title={s}", .{tab.title[0..tab.title_len]});
        tab.tab_exit_fn(@intFromPtr(tab), tab.tab_exit_userdata);
    }
};

pub const SessionCore = struct {
    allocator: std.mem.Allocator,
    shell_command: terminal_backend.ShellCommand,
    max_scroll_lines: usize,
    theme: ?*const themes.Theme,
    tab_exit_fn: TabExitNotify,
    tab_exit_userdata: ?*anyopaque,
    tabs: std.ArrayList(*Tab) = .{},
    active_tab: usize = 0,
    next_tab_id: usize = 1,

    pub const TabExitNotify = *const fn (usize, ?*anyopaque) void;
    pub const CloseResult = enum {
        none,
        changed,
        closed_last,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        shell_command: terminal_backend.ShellCommand,
        max_scroll_lines: usize,
        theme: ?*const themes.Theme,
        tab_exit_fn: TabExitNotify,
        tab_exit_userdata: ?*anyopaque,
    ) SessionCore {
        return .{
            .allocator = allocator,
            .shell_command = shell_command,
            .max_scroll_lines = max_scroll_lines,
            .theme = theme,
            .tab_exit_fn = tab_exit_fn,
            .tab_exit_userdata = tab_exit_userdata,
        };
    }

    pub fn deinit(self: *SessionCore) void {
        for (self.tabs.items) |tab| tab.deinit(self.allocator);
        self.tabs.deinit(self.allocator);
    }

    pub fn createTab(self: *SessionCore, cols: u16, rows: u16) !void {
        const tab = try Tab.init(
            self.allocator,
            cols,
            rows,
            self.shell_command,
            self.max_scroll_lines,
            self.theme,
            self.tab_exit_fn,
            self.tab_exit_userdata,
        );
        errdefer tab.deinit(self.allocator);

        tab.setTitle(self.next_tab_id);
        self.next_tab_id += 1;
        try tab.backend.startReadThread(Tab.onPtyOutput, Tab.onPtyExit, tab);
        try self.tabs.append(self.allocator, tab);
        self.active_tab = self.tabs.items.len - 1;
    }

    pub fn closeTab(self: *SessionCore, index: usize) CloseResult {
        if (index >= self.tabs.items.len) return .none;

        const remaining_len = self.tabs.items.len - 1;
        const next_active = nextActiveIndexAfterClose(self.active_tab, index, remaining_len);
        const tab = self.tabs.orderedRemove(index);
        defer tab.deinit(self.allocator);

        if (next_active) |active| {
            self.active_tab = active;
            return .changed;
        }
        self.active_tab = 0;
        return .closed_last;
    }

    pub fn closeTabByPtr(self: *SessionCore, tab_ptr: usize) CloseResult {
        const needle: *Tab = @ptrFromInt(tab_ptr);
        for (self.tabs.items, 0..) |tab, i| {
            if (tab == needle) {
                return self.closeTab(i);
            }
        }
        return .none;
    }

    pub fn tabsSlice(self: *SessionCore) []*Tab {
        return self.tabs.items;
    }

    pub fn count(self: *const SessionCore) usize {
        return self.tabs.items.len;
    }

    pub fn activeIndex(self: *const SessionCore) usize {
        return self.active_tab;
    }

    pub fn tabAt(self: *SessionCore, index: usize) ?*Tab {
        if (index < self.tabs.items.len) return self.tabs.items[index];
        return null;
    }

    pub fn activeTab(self: *SessionCore) ?*Tab {
        return self.tabAt(self.active_tab);
    }

    pub fn setActiveTab(self: *SessionCore, index: usize) bool {
        if (index >= self.tabs.items.len or index == self.active_tab) return false;
        self.active_tab = index;
        return true;
    }

    /// 다음 탭 (마지막이면 0 으로 wrap). 탭이 1 개 이하면 false. macOS
    /// `macos_session.activateNext` 동등 — Ctrl+Tab 핸들러용 (#125).
    pub fn activateNext(self: *SessionCore) bool {
        if (self.tabs.items.len <= 1) return false;
        self.active_tab = (self.active_tab + 1) % self.tabs.items.len;
        return true;
    }

    /// 이전 탭 (0 이면 마지막으로 wrap). 탭이 1 개 이하면 false.
    pub fn activatePrev(self: *SessionCore) bool {
        if (self.tabs.items.len <= 1) return false;
        self.active_tab = if (self.active_tab == 0) self.tabs.items.len - 1 else self.active_tab - 1;
        return true;
    }

    pub fn reorderTabs(self: *SessionCore, from: usize, to: usize) !bool {
        if (from >= self.tabs.items.len or to >= self.tabs.items.len or from == to) return false;

        const active_tab_ptr = self.activeTab();
        const moved = self.tabs.orderedRemove(from);
        try self.tabs.insert(self.allocator, to, moved);

        if (active_tab_ptr) |active| {
            for (self.tabs.items, 0..) |tab, i| {
                if (tab == active) {
                    self.active_tab = i;
                    break;
                }
            }
        }
        return true;
    }

    pub fn queueInputToActive(self: *SessionCore, data: []const u8) void {
        if (self.activeTab()) |tab| {
            tab.queueWrite(data);
            tab.terminal.scrollViewport(.{ .bottom = {} });
        }
    }

    pub fn resizeAll(self: *SessionCore, cols: u16, rows: u16) void {
        for (self.tabs.items) |tab| {
            tab.terminal.resize(self.allocator, cols, rows) catch {};
            tab.backend.resize(cols, rows) catch {};
        }
    }

    pub fn scrollActive(self: *SessionCore, event: app_event.ScrollEvent, visible_rows: u16) bool {
        const tab = self.activeTab() orelse return false;
        const delta: isize = switch (event) {
            .page => |dir| blk: {
                const rows: isize = @intCast(visible_rows);
                break :blk if (dir == .up) -rows else rows;
            },
            .wheel => |raw| @divTrunc(@as(isize, raw), 40),
        };
        tab.terminal.scrollViewport(.{ .delta = -delta });
        return true;
    }

    pub fn resetActive(self: *SessionCore) bool {
        const tab = self.activeTab() orelse return false;
        tab.terminal.fullReset();
        tab.queueWrite("\x0c");
        return true;
    }

    pub fn prepareActiveFrame(self: *SessionCore, last_render_ms: *i64) bool {
        var should_render = true;
        if (self.activeTab()) |tab| {
            tab.drainOutput();
            if (!tab.output_ring.isEmpty()) {
                const now = std.time.milliTimestamp();
                if (now - last_render_ms.* < 8) {
                    should_render = false;
                } else {
                    last_render_ms.* = now;
                }
            }
        }
        return should_render;
    }
};

fn nextActiveIndexAfterClose(active_index: usize, closed_index: usize, remaining_len: usize) ?usize {
    if (remaining_len == 0) return null;
    if (active_index > closed_index) return active_index - 1;
    if (active_index >= remaining_len) return remaining_len - 1;
    return active_index;
}

test "next active index shifts when closing earlier tab" {
    try std.testing.expectEqual(@as(?usize, null), nextActiveIndexAfterClose(0, 0, 0));
    try std.testing.expectEqual(@as(?usize, 0), nextActiveIndexAfterClose(1, 0, 2));
    try std.testing.expectEqual(@as(?usize, 1), nextActiveIndexAfterClose(2, 0, 2));
    try std.testing.expectEqual(@as(?usize, 1), nextActiveIndexAfterClose(1, 1, 2));
    try std.testing.expectEqual(@as(?usize, 1), nextActiveIndexAfterClose(1, 2, 2));
}
