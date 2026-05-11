const std = @import("std");
const ghostty = @import("ghostty-vt");
const app_event = @import("app_event.zig");
const terminal = @import("terminal.zig");
const TerminalBackend = terminal.TerminalBackend;
const terminal_interaction = @import("terminal_interaction.zig");
const themes = @import("themes.zig");
const perf = @import("perf.zig");
const log = @import("log.zig");

/// Lock-free 링버퍼 (단일 생산자, 단일 소비자)
const RingBuffer = struct {
    buf: [SIZE]u8 align(64) = undefined,
    head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Tab.deinit 신호 — set 시 push 가 spin 풀고 즉시 break. read_thread 가
    /// ring full 에 갇혀 deinit 의 read_thread.join 이 deadlock 되는 것 방지
    /// (Cmd+W 시연 시 발견된 회귀).
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const SIZE = 4 * 1024 * 1024;

    fn push(self: *RingBuffer, data: []const u8) void {
        var i: usize = 0;
        while (i < data.len) {
            if (self.closed.load(.acquire)) return;
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

    fn close(self: *RingBuffer) void {
        self.closed.store(true, .release);
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

/// PTY write용 큐 (UI → write 스레드). 8MB — main thread (Cmd+V) 가 큰 paste
/// 시 queue full 로 yield-loop 빠지지 않도록. 사용자 시연: 64000 라인 (1.1MB)
/// paste 가 freeze 발생 → 1MB → 8MB 로 확장. 16탭 = 128MB — paste 가 일시적
/// 이고 즉시 PTY 로 빠져나가므로 메모리 압박 짧음. 8MB 초과는 여전히 yield
/// 하지만 일반 사용 시나리오에서는 거의 발생 안 함.
const WriteQueue = struct {
    buf: [8 * 1024 * 1024]u8 = undefined,
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

    /// Pending data 즉시 폐기 — Ctrl+C interrupt 시 큐에 쌓인 paste data 등을
    /// 무효화. write_thread 가 spinning (queue full 시) 중이면 free 공간 생기게
    /// 하는 효과도 있어 main thread 의 다음 push 즉시 진행.
    fn reset(self: *WriteQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.head = 0;
        self.tail = 0;
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
    /// 마우스 selection / scrollbar drag 같은 per-tab interaction 상태. 탭 간
    /// 독립 — 탭 전환 시 각자 selection / drag 상태를 보존하고, host 는 활성
    /// 탭의 interaction 을 event/render 시점에 참조한다.
    interaction: terminal_interaction.TerminalInteraction = .{},
    output_ring: RingBuffer = .{},
    write_queue: WriteQueue = .{},
    write_thread: ?std.Thread = null,
    tab_exit_fn: SessionCore.TabExitNotify,
    tab_exit_userdata: ?*anyopaque = null,

    fn init(
        alloc: std.mem.Allocator,
        cols: u16,
        rows: u16,
        shell: terminal.ShellCommand,
        max_scroll_lines: usize,
        theme: ?*const themes.Theme,
        extra_env: ?[]const terminal.ExtraEnv,
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

        var term = try ghostty.Terminal.init(alloc, .{
            .cols = cols,
            .rows = rows,
            .max_scrollback = max_scroll_lines * blk: {
                const cap = ghostty.page.std_capacity.adjust(.{ .cols = cols }) catch
                    break :blk (@as(usize, cols) + 1) * 8;
                break :blk ghostty.Page.layout(cap).total_size / cap.rows;
            },
            .colors = term_colors,
        });
        errdefer term.deinit(alloc);

        // Mode 2027 (grapheme cluster) — VS-16 / skin tone modifier (U+1F3FB-FF)
        // / ZWJ 시퀀스 (U+200D) 가 같은 cell 의 grapheme 으로 묶이게. 기본 OFF
        // 라 ❤️ 가 [U+2764, U+FE0F] 두 cell 에 분리되고 cell 폭도 narrow 로
        // 남음. ON 시 base cell 의 `cell.grapheme` 에 extras 가 저장 + VS-16
        // 일 때 cell 자동으로 wide. renderer 는 이 grapheme 을 cluster 로 shape
        // (#134 C3+). macOS session 의 동일 정책 (commit 0e18ab5) 과 cross-platform
        // sync.
        term.modes.set(.grapheme_cluster, true);

        var backend = try TerminalBackend.init(.{
            .allocator = alloc,
            .cols = cols,
            .rows = rows,
            .shell = shell,
            .theme = theme,
            .extra_env = extra_env,
        });
        errdefer backend.deinit();

        tab.* = .{
            .terminal = term,
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
        // output_ring 도 close 신호 → read_thread 가 ring.push 안에서 spin 하던
        // 중이라도 즉시 break. 이게 없으면 backend.deinit 의 read_thread.join
        // 이 deadlock: paste 후 ring full + main thread 가 deinit 진행 중이라
        // drain 못 함 → push 가 free 공간 안 생겨 spin → join 영원히 안 됨.
        tab.output_ring.close();

        // 순서 핵심 — backend.deinit 을 *먼저* 부른 뒤 write_thread.join.
        // 이유: write_thread 가 PTY pipe full + 자식이 paste 처리 중일 때
        // `backend.write` 안에서 OS-level blocking. close flag 가 inner loop
        // 안에서 검사 안 됨 → write_thread.join 이 영원 (Cmd+W beachball 30초+
        // 회귀). backend.deinit 이 자식 SIGHUP/SIGKILL + master_fd close →
        // write 가 EBADF → catch break → outer close 검사 break. 그 후 join
        // 빠르게 풀림.
        tab.backend.deinit();
        if (tab.write_thread) |t| {
            t.join();
            tab.write_thread = null;
        }
        tab.terminal.deinit(alloc);
        alloc.destroy(tab);
    }

    pub fn queueWrite(tab: *Tab, data: []const u8) void {
        tab.write_queue.push(data);
    }

    /// Ctrl+C 같은 interrupt char 의 즉시 송신 path. write_queue 의 pending
    /// (paste data 등) 모두 폐기 + backend.write 직접 호출. 큐 우회라 main
    /// thread 에서 호출 안전 (backend.write 자체는 block 가능하지만 single
    /// byte 라 PTY pipe 에 즉시 들어감).
    pub fn interruptWrite(tab: *Tab, data: []const u8) void {
        tab.write_queue.reset();
        _ = tab.backend.write(data) catch {};
    }

    fn drainOutput(tab: *Tab) void {
        const drain_t0 = perf.now();
        // 한 frame 에서 ring 통째 parse 하면 큰 paste 후 bash echo (ring 4MB 가능)
        // 시 main thread 가 수 초 점유 → beachball + Cmd+Q / Ctrl+C / mouse 모두
        // dispatch 안 됨. 60fps frame budget (16.7ms) 안의 절반 (8ms) 만 parse,
        // 나머지는 다음 frame 에 계속. ring 이 못 비워져도 next frame fire 시
        // pop 이어짐. 사용자 인지: 출력은 분산되지만 UI 는 항상 반응.
        const FRAME_BUDGET_NS: u64 = 8 * 1_000_000;
        var buf: [65536]u8 = undefined;
        var total_bytes: u64 = 0;
        while (true) {
            const n = tab.output_ring.pop(&buf);
            if (n == 0) break;
            const parse_t0 = perf.now();
            tab.stream.nextSlice(buf[0..n]);
            perf.addTimed(&perf.parse, parse_t0);
            total_bytes += n;
            if (perf.nsSince(drain_t0) > FRAME_BUDGET_NS) break;
        }
        perf.addTimedBytes(&perf.drain, drain_t0, total_bytes);
    }

    fn writeLoop(tab: *Tab) void {
        var buf: [256]u8 = undefined;
        while (true) {
            tab.write_queue.event.wait();
            tab.write_queue.event.reset();
            while (true) {
                // close 후 pending data 처리 안 함 — 큰 paste 잔여 (수 MB) 가
                // PTY 로 송신될 때 deinit 진행이 늦어지지 않게.
                if (tab.write_queue.isClosed()) break;
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
        log.appendLine("tab", "shell exited: title={s}", .{tab.title[0..tab.title_len]});
        tab.tab_exit_fn(@intFromPtr(tab), tab.tab_exit_userdata);
    }
};

/// 탭 동시 존재 한도. 사용자 의도된 작업 흐름 + 탭바 가독성 + renderer
/// instance buffer 한도 균형. 도달 시 새 탭 단축키 / `+` 클릭 거부 + dialog
/// 안내 (cross-platform 동등).
pub const MAX_TABS: usize = 32;

pub const SessionCore = struct {
    allocator: std.mem.Allocator,
    shell_command: terminal.ShellCommand,
    max_scroll_lines: usize,
    theme: ?*const themes.Theme,
    /// 자식 셸에 inject 할 환경변수 (TERM / LANG / SHELL 등). 모든 탭이 같은
    /// 값. lifetime 은 호출자 책임 (process lifetime static 권장).
    extra_env: ?[]const terminal.ExtraEnv,
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
        shell_command: terminal.ShellCommand,
        max_scroll_lines: usize,
        theme: ?*const themes.Theme,
        extra_env: ?[]const terminal.ExtraEnv,
        tab_exit_fn: TabExitNotify,
        tab_exit_userdata: ?*anyopaque,
    ) SessionCore {
        return .{
            .allocator = allocator,
            .shell_command = shell_command,
            .max_scroll_lines = max_scroll_lines,
            .theme = theme,
            .extra_env = extra_env,
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
            self.extra_env,
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

    /// 다음 탭 (마지막이면 0 으로 wrap). 탭이 1 개 이하면 false. Ctrl+Tab
    /// 핸들러용 (#125).
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

    /// Paste 전용 — 활성 탭의 ghostty Terminal mode `.bracketed_paste` (DEC
    /// CSI 2004) 가 켜져 있으면 `\x1b[200~ <data> \x1b[201~` 로 wrap. 셸이
    /// paste 를 한 묶음으로 받아 매 newline 단위 즉시 실행 / prompt redraw 안
    /// 함 — 큰 paste (수만 라인) 의 cooked-mode line discipline 부담 제거.
    /// 일반 typing (`queueInputToActive`) 과 분리 — typing 은 wrap 하면 안 됨.
    pub fn pasteToActive(self: *SessionCore, data: []const u8) void {
        const tab = self.activeTab() orelse return;
        if (tab.terminal.modes.get(.bracketed_paste)) {
            tab.queueWrite("\x1b[200~");
            tab.queueWrite(data);
            tab.queueWrite("\x1b[201~");
        } else {
            tab.queueWrite(data);
        }
        tab.terminal.scrollViewport(.{ .bottom = {} });
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
