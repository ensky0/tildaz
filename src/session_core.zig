const std = @import("std");
const builtin = @import("builtin");
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

const TITLE_DEBOUNCE_NS: u64 = 150 * std.time.ns_per_ms;

/// OSC 자동 제목의 trailing-edge debounce 상태. 셸이 짧은 명령 전후로
/// `cwd -> command cwd -> cwd` 를 수십 ms 안에 보내면 중간 제목을 화면에
/// 노출하지 않는다. raw 문자열은 수정하지 않고 150ms 안정성만 확인한다.
const PendingTitle = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    since_ns: u64 = 0,
    active: bool = false,

    fn clear(self: *PendingTitle) void {
        self.active = false;
        self.len = 0;
        self.since_ns = 0;
    }

    fn queue(self: *PendingTitle, displayed: []const u8, candidate: []const u8, now_ns: u64) void {
        // 셸이 debounce 안에 원래 표시 제목으로 돌아오면 중간 제목을 폐기.
        if (std.mem.eql(u8, displayed, candidate)) {
            self.clear();
            return;
        }
        // 같은 pending title 반복은 안정화 시간을 다시 시작하지 않는다.
        if (self.active and std.mem.eql(u8, self.buf[0..self.len], candidate)) return;

        self.len = copyValidUtf8Title(&self.buf, candidate);
        self.since_ns = now_ns;
        self.active = true;
    }

    fn flush(self: *PendingTitle, dest: []u8, dest_len: *usize, now_ns: u64) bool {
        if (!self.active) return false;
        if (now_ns - self.since_ns < TITLE_DEBOUNCE_NS) return false;

        const changed = !std.mem.eql(u8, dest[0..dest_len.*], self.buf[0..self.len]);
        if (changed) {
            @memcpy(dest[0..self.len], self.buf[0..self.len]);
            dest_len.* = self.len;
        }
        self.clear();
        return changed;
    }
};

pub const Tab = struct {
    terminal: ghostty.Terminal,
    stream: ghostty.TerminalStream,
    backend: TerminalBackend,
    /// OSC title debounce 전용 monotonic elapsed clock. `nanoTimestamp`는
    /// CLOCK_REALTIME/system time이라 시계 보정 영향을 받으므로 쓰지 않는다.
    title_clock: std.time.Timer,
    title: [64]u8 = undefined,
    title_len: usize = 0,
    /// OSC 0/2 빈 제목이 오면 최초 자동 이름으로 돌아가기 위한 stable id.
    default_title_id: usize = 0,
    /// 사용자가 rename 한 제목은 이후 셸의 OSC 0/2 보다 우선한다.
    has_custom_title: bool = false,
    pending_title: PendingTitle = .{},
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
        const title_clock = try std.time.Timer.start();

        tab.* = .{
            .terminal = term,
            .stream = undefined,
            .backend = backend,
            .title_clock = title_clock,
            .tab_exit_fn = tab_exit_fn,
            .tab_exit_userdata = tab_exit_userdata,
        };
        // #266 — 터미널 질의 응답 배선 (macOS / Linux 만). 기본 vtStream() 은
        // 읽기 전용이라 응답이 필요한 시퀀스 (DA1 / DSR / DECRQM / OSC 색 질의
        // / kitty keyboard 질의 / XTVERSION) 를 전부 무시 → fish 가 필수 질의인
        // DA1 응답을 10초 기다리다 경고. effects 에 write_pty (응답 송신 통로)
        // + 콜백들을 연결하면 나머지 질의는 ghostty-vt 가 내장 처리한다.
        //
        // Windows 는 종전 readonly 유지 — ConPTY 구조에서는 자식 앱의 질의에
        // conhost 가 터미널 역할로 직접 응답하므로 우리 응답의 수신자가 없다.
        // 오히려 conhost 자신의 DA1 질의는 spawn 직후 pre-response
        // (terminal/windows/pty.zig) 로 이미 답을 받은 상태라, 파서의 두 번째
        // 응답을 소비하지 않고 자식 입력으로 흘려보내 cmd 프롬프트에 "62;22c"
        // 가 찍히는 leak 이 Windows 시연에서 확인됨 (#266).
        if (comptime builtin.os.tag != .windows) {
            var vt_handler = tab.terminal.vtHandler();
            vt_handler.effects.write_pty = &vtWritePty;
            vt_handler.effects.device_attributes = &vtDeviceAttributes;
            vt_handler.effects.xtversion = &vtXtversion;
            vt_handler.effects.color_scheme = &vtColorScheme;
            vt_handler.effects.title_changed = &vtTitleChanged;
            tab.stream = .initAlloc(alloc, vt_handler);
        } else {
            tab.stream = tab.terminal.vtStream();
        }
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

    /// #266 — ghostty-vt `Effects.write_pty`. 질의 응답 (DA1 / DSR / DECRQM
    /// 등) 을 PTY 로 송신. stream 파싱은 main thread 의 drainOutput 에서
    /// 일어나므로 blocking 가능한 backend.write 직접 호출 대신 키 입력과 같은
    /// write_queue 경로로 (순서 보존 + push 가 복사라 data lifetime 무관).
    fn vtWritePty(handler: *ghostty.TerminalStream.Handler, data: [:0]const u8) void {
        const tab: *Tab = @alignCast(@fieldParentPtr("terminal", handler.terminal));
        tab.queueWrite(data);
    }

    /// #266 — ghostty-vt `Effects.device_attributes`. DA1/DA2/DA3 응답 값.
    /// lib 기본값 (DA1: vt220 conformance + ansi_color = `\x1b[?62;22c`) 그대로.
    fn vtDeviceAttributes(handler: *ghostty.TerminalStream.Handler) VtAttributes {
        _ = handler;
        return .{};
    }

    /// #266 2단계 — ghostty-vt `Effects.xtversion`. XTVERSION (`\e[>0q`) 응답
    /// 문자열. 연결 안 하면 "libghostty" 로 보고돼 터미널 식별이 어긋난다.
    fn vtXtversion(handler: *ghostty.TerminalStream.Handler) []const u8 {
        _ = handler;
        return "tildaz " ++ @import("build_options").version;
    }

    /// #266 2단계 — ghostty-vt `Effects.color_scheme`. color scheme DSR
    /// (`\e[?996n`) 응답 → `\e[?997;1n` (dark) / `\e[?997;2n` (light).
    /// theme 상수가 아니라 terminal 의 *현재* 배경색 (OSC 11 로 런타임 변경
    /// 가능) 으로 판별 — 기준은 COLORFGBG 와 동일 (`themes.isDarkRgb`).
    fn vtColorScheme(handler: *ghostty.TerminalStream.Handler) ?ghostty.device_status.ColorScheme {
        const bg = handler.terminal.colors.background.get() orelse return null;
        return if (themes.isDarkRgb(bg.r, bg.g, bg.b)) .dark else .light;
    }

    /// #269 — Linux · macOS effects stream 의 OSC 0/2 알림. ghostty-vt 가
    /// `Terminal.setTitle` 을 먼저 끝낸 뒤 호출하므로 공통 동기화 함수에서 새
    /// 상태를 읽는다. Windows 는 readonly stream 을 유지해야 해서 drainOutput
    /// 직후 같은 함수를 호출한다.
    fn vtTitleChanged(handler: *ghostty.TerminalStream.Handler) void {
        const tab: *Tab = @alignCast(@fieldParentPtr("terminal", handler.terminal));
        tab.syncTerminalTitle();
    }

    /// ghostty-vt 가 module root (`lib_vt.zig`) 에 `device_attributes.Attributes`
    /// 를 export 하지 않아, Effects 콜백 필드의 함수 반환 타입에서 comptime 으로
    /// 얻는다.
    const VtAttributes = @typeInfo(
        @typeInfo(
            @typeInfo(
                std.meta.fieldInfo(
                    ghostty.TerminalStream.Handler.Effects,
                    .device_attributes,
                ).type,
            ).optional.child,
        ).pointer.child,
    ).@"fn".return_type.?;

    /// Ctrl+C 같은 interrupt char 의 즉시 송신 path. write_queue 의 pending
    /// (paste data 등) 모두 폐기 + backend.write 직접 호출. 큐 우회라 main
    /// thread 에서 호출 안전 (backend.write 자체는 block 가능하지만 single
    /// byte 라 PTY pipe 에 즉시 들어감).
    pub fn interruptWrite(tab: *Tab, data: []const u8) void {
        tab.write_queue.reset();
        _ = tab.backend.write(data) catch {};
    }

    /// 한 번에 최대 64KiB만 파싱한다. frame 전체 예산과 탭 간 순서는
    /// SessionCore가 관리하고, 이 함수는 한 탭의 원자적인 drain 단위만 담당한다.
    fn drainOutputChunk(tab: *Tab) bool {
        const drain_t0 = perf.now();
        var buf: [65536]u8 = undefined;
        const n = tab.output_ring.pop(&buf);
        if (n == 0) return false;

        const parse_t0 = perf.now();
        tab.stream.nextSlice(buf[0..n]);
        // #269 — Windows 는 #266 의 ConPTY 응답 누출을 막기 위해 effects 없는
        // readonly stream 을 유지한다. readonly 여도 OSC 0/2 는 Terminal.title
        // 에 저장되므로 parse 직후 공통 제목 상태만 읽어 동기화한다.
        if (comptime builtin.os.tag == .windows) tab.syncTerminalTitle();
        perf.addTimed(&perf.parse, parse_t0);
        perf.addTimedBytes(&perf.drain, drain_t0, @intCast(n));
        return true;
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
        tab.default_title_id = title_id;
        tab.has_custom_title = false;
        tab.pending_title.clear();
        writeDefaultTitle(&tab.title, &tab.title_len, title_id);
    }

    pub fn setCustomTitle(tab: *Tab, title: []const u8) void {
        tab.title_len = copyValidUtf8Title(&tab.title, title);
        tab.has_custom_title = true;
        tab.pending_title.clear();
    }

    fn syncTerminalTitle(tab: *Tab) void {
        if (tab.has_custom_title) {
            tab.pending_title.clear();
            return;
        }
        const terminal_title: ?[]const u8 = if (tab.terminal.getTitle()) |title| title else null;
        var candidate: [64]u8 = undefined;
        var candidate_len: usize = 0;
        applyAutomaticTitle(
            &candidate,
            &candidate_len,
            tab.default_title_id,
            false,
            terminal_title,
        );
        tab.pending_title.queue(
            tab.title[0..tab.title_len],
            candidate[0..candidate_len],
            tab.title_clock.read(),
        );
    }

    fn flushPendingTitle(tab: *Tab) bool {
        if (tab.has_custom_title) {
            tab.pending_title.clear();
            return false;
        }
        return tab.pending_title.flush(&tab.title, &tab.title_len, tab.title_clock.read());
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

/// 고정 크기 탭 제목 버퍼에 유효한 UTF-8 prefix 만 복사한다. byte 한도에서
/// 다중 바이트 codepoint 가 잘리거나 OSC payload 에 잘못된 byte 가 있으면 마지막
/// 유효 경계까지만 사용해 renderer 에 invalid UTF-8 을 넘기지 않는다.
fn copyValidUtf8Title(dest: []u8, source: []const u8) usize {
    var len = @min(dest.len, source.len);
    while (len > 0 and !std.unicode.utf8ValidateSlice(source[0..len])) : (len -= 1) {}
    @memcpy(dest[0..len], source[0..len]);
    return len;
}

fn writeDefaultTitle(dest: []u8, len: *usize, title_id: usize) void {
    const result = std.fmt.bufPrint(dest, "Tab {d}", .{title_id}) catch "Tab";
    len.* = result.len;
}

/// OSC 0/2 제목 정책의 단일 진입점. 수동 rename 은 자동 제목보다 우선하고,
/// OSC 빈 payload (ghostty `getTitle() == null`) 는 최초 `Tab N` 으로 복귀한다.
fn applyAutomaticTitle(
    dest: []u8,
    len: *usize,
    default_title_id: usize,
    has_custom_title: bool,
    automatic_title: ?[]const u8,
) void {
    if (has_custom_title) return;
    if (automatic_title) |title| {
        if (title.len > 0) {
            len.* = copyValidUtf8Title(dest, title);
            return;
        }
    }
    writeDefaultTitle(dest, len, default_title_id);
}

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
    /// 비활성 탭 drain의 다음 시작 위치. 탭 close/reorder 뒤에는 drain 시점에
    /// 현재 길이로 정규화하므로 별도 인덱스 보정이 필요 없다.
    inactive_drain_cursor: usize = 0,
    next_tab_id: usize = 1,

    /// 한 frame에서 VT parse가 UI thread를 점유할 수 있는 공통 상한.
    /// 활성/비활성 탭이 이 예산을 함께 쓰므로 탭 수가 늘어도 총 예산은 그대로다.
    const DRAIN_FRAME_BUDGET_NS: u64 = 8 * std.time.ns_per_ms;

    const DrainFrameResult = struct {
        active_output: bool = false,
        active_output_pending: bool = false,
        title_changed: bool = false,
    };

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

    /// #242 — 활성 탭 viewport 를 맨 아래로(scroll-on-keystroke). PTY write 없이
    /// scroll 만 필요한 입력 경로용 — IME preedit(조합 중)은 PTY 로 안 가고 화면에
    /// inline 표시만 되므로, 스크롤백 올린 상태에서 조합 시작 시 cursor(맨 아래)로
    /// 내려와야 자기 조합이 보인다. 타이핑 commit 은 queueInputToActive 가 겸함.
    pub fn scrollActiveToBottom(self: *SessionCore) void {
        if (self.activeTab()) |tab| {
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
        // paste 줄바꿈 정규화 (#260). 붙여넣는 텍스트의 줄바꿈은 출처(다른 OS의
        // 클립보드 / 파일 / 웹)에 따라 CRLF·LF·CR 무엇이든 올 수 있으므로 전부
        // CR(\r) 하나로 통일한다 — CR 은 모든 OS 에서 터미널이 Enter 키로 보내는
        // 바이트라 OS 무관하게 옳다:
        //   - Windows: PowerShell/PSReadLine 은 paste 에 LF 가 섞이면 줄 순서를
        //     뒤집는 버그가 있음(PSReadLine #579). LF 를 남기지 않아야 함.
        //   - Unix(mac/Linux): PTY line discipline(ICRNL)이 CR→LF 로 바꿔주므로 정상.
        // CRLF 는 한 개로 합쳐 중복 빈 줄도 방지. *paste* 경로 전용 — 타이핑
        // (queueInputToActive)·프로그램 출력(progress bar 의 \r 등)은 안 건드림.
        const norm = normalizePasteNewlines(self.allocator, data, '\r');
        defer if (norm) |b| self.allocator.free(b);
        const out = norm orelse data; // 변환 불필요(또는 alloc 실패) 시 원본 그대로
        if (tab.terminal.modes.get(.bracketed_paste)) {
            tab.queueWrite("\x1b[200~");
            tab.queueWrite(out);
            tab.queueWrite("\x1b[201~");
        } else {
            tab.queueWrite(out);
        }
        tab.terminal.scrollViewport(.{ .bottom = {} });
    }

    /// paste 데이터의 줄바꿈을 단일 `nl` 로 통일. CRLF·LF·CR 전부 `nl` 하나로
    /// (CRLF 는 한 개로 합침). 대량(수 MB) paste 도 빠르도록:
    ///  - `nl` 외의 줄바꿈 문자가 하나도 없으면 변환 불필요 → null 반환(복사 0,
    ///    호출부가 원본을 그대로 사용). 스캔은 SIMD memchr(`indexOfScalar`).
    ///  - 변환 시에도 줄바꿈 아닌 구간은 `@memcpy` 로 통째 복사(바이트 루프 회피).
    /// alloc 실패도 null.
    fn normalizePasteNewlines(alloc: std.mem.Allocator, data: []const u8, nl: u8) ?[]u8 {
        // nl 이 아닌 줄바꿈 문자(`other`)가 없으면 결과 == 입력 → 변환 생략.
        const other: u8 = if (nl == '\n') '\r' else '\n';
        if (std.mem.indexOfScalar(u8, data, other) == null) return null;

        const buf = alloc.alloc(u8, data.len) catch return null;
        var n: usize = 0;
        var i: usize = 0;
        while (i < data.len) {
            // 줄바꿈 아닌 구간을 통째 복사 (memcpy 속도).
            const start = i;
            while (i < data.len and data[i] != '\r' and data[i] != '\n') i += 1;
            if (i > start) {
                @memcpy(buf[n..][0 .. i - start], data[start..i]);
                n += i - start;
            }
            if (i >= data.len) break;
            buf[n] = nl;
            n += 1;
            // CRLF 는 2바이트 건너뜀, 나머지(CR/LF 단독)는 1바이트.
            i += if (data[i] == '\r' and i + 1 < data.len and data[i + 1] == '\n') 2 else 1;
        }
        return buf[0..n];
    }

    pub fn resizeAll(self: *SessionCore, cols: u16, rows: u16) void {
        for (self.tabs.items) |tab| {
            tab.terminal.resize(self.allocator, cols, rows) catch {};
            tab.backend.resize(cols, rows) catch {};
        }
    }

    pub fn scrollActive(self: *SessionCore, event: app_event.ScrollEvent, visible_rows: u16) bool {
        const tab = self.activeTab() orelse return false;
        // ghostty `scrollViewport(.delta = -X)` = older (scrollback up), `+X` = newer.
        // wheel: 사용자 의도 = wheel 위로 (양수 raw) → older. 그래서 공용 `-delta`
        //   로 반전 → scrollViewport(-X) = older.
        // page: `.up` = older (PgUp 의 사용자 mental model = scrollback). wheel
        //   convention 과 같이 *delta 양수 = 위로 의도* 로 통일. `.up` → +rows
        //   → 공용 `-delta` 후 scrollViewport(-rows) = older. 사용자 시연 발견
        //   정정 — 이전엔 `.up` 이 -rows 였어 최종 scrollViewport(+rows) = newer
        //   로 *반대* 동작 (Win/Linux 모두 영향, mac 은 직접 scrollViewport
        //   호출이라 무관).
        const delta: isize = switch (event) {
            .page => |dir| blk: {
                const rows: isize = @intCast(visible_rows);
                break :blk if (dir == .up) rows else -rows;
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

    /// round-robin cursor에서 시작해 출력이 있는 비활성 탭 하나를 한 chunk 처리한다.
    /// 빈 탭은 건너뛰고, 성공하면 다음 호출이 그 다음 탭부터 찾도록 전진한다.
    fn drainNextInactiveChunk(self: *SessionCore) bool {
        const len = self.tabs.items.len;
        if (len <= 1) return false;

        const start = self.inactive_drain_cursor % len;
        for (0..len) |offset| {
            const index = (start + offset) % len;
            if (index == self.active_tab) continue;
            const tab = self.tabs.items[index];
            if (tab.output_ring.isEmpty()) continue;

            self.inactive_drain_cursor = (index + 1) % len;
            return tab.drainOutputChunk();
        }
        self.inactive_drain_cursor = (start + 1) % len;
        return false;
    }

    /// 활성 탭 한 chunk와 다음 비활성 탭 한 chunk를 번갈아 처리한다. 활성 탭은
    /// 매 frame 첫 순서를 보장하되, 모든 탭이 하나의 8ms 예산을 공유해 탭 수가
    /// 늘어나도 UI thread 점유 시간이 비례해 늘지 않는다.
    fn drainFrame(self: *SessionCore) DrainFrameResult {
        const active = self.activeTab() orelse return .{};
        const started_ns = active.title_clock.read();
        var result: DrainFrameResult = .{};

        while (active.title_clock.read() - started_ns < DRAIN_FRAME_BUDGET_NS) {
            const drained_active = active.drainOutputChunk();
            result.active_output = result.active_output or drained_active;

            if (active.title_clock.read() - started_ns >= DRAIN_FRAME_BUDGET_NS) break;
            const drained_inactive = self.drainNextInactiveChunk();
            if (!drained_active and !drained_inactive) break;
        }

        result.active_output_pending = !active.output_ring.isEmpty();
        for (self.tabs.items) |tab| {
            result.title_changed = tab.flushPendingTitle() or result.title_changed;
        }
        return result;
    }

    pub fn prepareActiveFrame(self: *SessionCore, last_render_ms: *i64) bool {
        var should_render = true;
        if (self.activeTab() != null) {
            const drained = self.drainFrame();
            if (drained.active_output_pending) {
                const now = std.time.milliTimestamp();
                if (now - last_render_ms.* < 8 and !drained.title_changed) {
                    should_render = false;
                } else {
                    last_render_ms.* = now;
                }
            }
        }
        return should_render;
    }

    /// macOS display link와 Linux poll loop가 render 필요 여부를 판단하는 공통 경로.
    /// 비활성 탭의 본문 출력만 파싱한 경우 현재 화면은 변하지 않지만, 어느 탭이든
    /// 제목이 바뀌면 탭바를 다시 그려야 한다.
    pub fn drainOutputForRender(self: *SessionCore) bool {
        const drained = self.drainFrame();
        return drained.active_output or drained.active_output_pending or drained.title_changed;
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

test "OSC 0 and 2 update automatic tab title and empty title restores default" {
    var terminal_state = try ghostty.Terminal.init(std.testing.allocator, .{
        .cols = 80,
        .rows = 24,
    });
    defer terminal_state.deinit(std.testing.allocator);

    var stream = terminal_state.vtStream();
    defer stream.deinit();

    var title: [64]u8 = undefined;
    var title_len: usize = 0;
    writeDefaultTitle(&title, &title_len, 7);

    stream.nextSlice("\x1b]2;fish: ~/src\x1b\\");
    applyAutomaticTitle(&title, &title_len, 7, false, terminal_state.getTitle().?);
    try std.testing.expectEqualStrings("fish: ~/src", title[0..title_len]);

    stream.nextSlice("\x1b]0;vim main.zig\x07");
    applyAutomaticTitle(&title, &title_len, 7, false, terminal_state.getTitle().?);
    try std.testing.expectEqualStrings("vim main.zig", title[0..title_len]);

    stream.nextSlice("\x1b]2;\x1b\\");
    const reset_title: ?[]const u8 = if (terminal_state.getTitle()) |value| value else null;
    applyAutomaticTitle(&title, &title_len, 7, false, reset_title);
    try std.testing.expectEqualStrings("Tab 7", title[0..title_len]);
}

test "automatic title debounce suppresses short command round trip" {
    var title: [64]u8 = undefined;
    var title_len = copyValidUtf8Title(&title, "~");
    var pending: PendingTitle = .{};

    pending.queue(title[0..title_len], "true ~", 0);
    try std.testing.expect(!pending.flush(&title, &title_len, 149 * std.time.ns_per_ms));
    try std.testing.expectEqualStrings("~", title[0..title_len]);

    // 32ms 뒤 fish prompt 가 원래 cwd 제목으로 돌아오면 command title 취소.
    pending.queue(title[0..title_len], "~", 32 * std.time.ns_per_ms);
    try std.testing.expect(!pending.active);
    try std.testing.expect(!pending.flush(&title, &title_len, 500 * std.time.ns_per_ms));
    try std.testing.expectEqualStrings("~", title[0..title_len]);
}

test "automatic title debounce applies stable title at exact boundary" {
    var title: [64]u8 = undefined;
    var title_len = copyValidUtf8Title(&title, "~");
    var pending: PendingTitle = .{};

    pending.queue(title[0..title_len], "sleep 3 ~", 0);
    // 같은 값 반복은 timestamp를 reset하지 않는다.
    pending.queue(title[0..title_len], "sleep 3 ~", 100 * std.time.ns_per_ms);
    try std.testing.expect(!pending.flush(&title, &title_len, 149 * std.time.ns_per_ms));
    try std.testing.expect(pending.flush(&title, &title_len, 150 * std.time.ns_per_ms));
    try std.testing.expectEqualStrings("sleep 3 ~", title[0..title_len]);

    pending.queue(title[0..title_len], "~", 3 * std.time.ns_per_s);
    try std.testing.expect(!pending.flush(&title, &title_len, 3 * std.time.ns_per_s + 149 * std.time.ns_per_ms));
    try std.testing.expect(pending.flush(&title, &title_len, 3 * std.time.ns_per_s + 150 * std.time.ns_per_ms));
    try std.testing.expectEqualStrings("~", title[0..title_len]);
}

test "automatic title debounce supports default reset and manual cancellation" {
    var title: [64]u8 = undefined;
    var title_len = copyValidUtf8Title(&title, "shell title");
    var candidate: [64]u8 = undefined;
    var candidate_len: usize = 0;
    applyAutomaticTitle(&candidate, &candidate_len, 7, false, null);

    var pending: PendingTitle = .{};
    pending.queue(title[0..title_len], candidate[0..candidate_len], 0);
    try std.testing.expect(pending.flush(&title, &title_len, TITLE_DEBOUNCE_NS));
    try std.testing.expectEqualStrings("Tab 7", title[0..title_len]);

    pending.queue(title[0..title_len], "ignored OSC", 2 * std.time.ns_per_s);
    pending.clear(); // setCustomTitle 이 수행하는 취소와 동일.
    title_len = copyValidUtf8Title(&title, "내 작업");
    try std.testing.expect(!pending.flush(&title, &title_len, 3 * std.time.ns_per_s));
    try std.testing.expectEqualStrings("내 작업", title[0..title_len]);
}

test "Windows ConPTY updates active and inactive tab titles without switching" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const Exit = struct {
        fn notify(_: usize, _: ?*anyopaque) void {}
    };
    const shell = std.unicode.utf8ToUtf16LeStringLiteral(
        "cmd.exe /d /c \"title TILDAZ_OSC_TEST & echo ready\"",
    );
    var session = SessionCore.init(
        std.testing.allocator,
        shell,
        100,
        null,
        null,
        &Exit.notify,
        null,
    );
    defer session.deinit();
    try session.createTab(80, 24);
    try session.createTab(80, 24);
    try std.testing.expectEqual(@as(usize, 1), session.activeIndex());

    var active_observed = false;
    var inactive_observed = false;
    for (0..300) |_| {
        _ = session.drainOutputForRender();
        const inactive = session.tabAt(0).?;
        const active = session.tabAt(1).?;
        inactive_observed = std.mem.eql(
            u8,
            inactive.title[0..inactive.title_len],
            "TILDAZ_OSC_TEST",
        );
        active_observed = std.mem.eql(
            u8,
            active.title[0..active.title_len],
            "TILDAZ_OSC_TEST",
        );
        if (inactive_observed and active_observed) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expect(active_observed);
    try std.testing.expect(inactive_observed);
    try std.testing.expectEqual(@as(usize, 1), session.activeIndex());
}

test "manual tab title wins over OSC title" {
    var title: [64]u8 = undefined;
    var title_len = copyValidUtf8Title(&title, "내 작업");

    applyAutomaticTitle(&title, &title_len, 3, true, "shell title");
    try std.testing.expectEqualStrings("내 작업", title[0..title_len]);

    applyAutomaticTitle(&title, &title_len, 3, true, null);
    try std.testing.expectEqualStrings("내 작업", title[0..title_len]);
}

test "tab title truncation preserves valid UTF-8 boundary" {
    var long_ascii: [80]u8 = undefined;
    @memset(&long_ascii, 'a');
    var title: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 64), copyValidUtf8Title(&title, &long_ascii));

    var long_hangul: [66]u8 = undefined;
    for (0..22) |i| @memcpy(long_hangul[i * 3 ..][0..3], "한");
    const hangul_len = copyValidUtf8Title(&title, &long_hangul);
    try std.testing.expectEqual(@as(usize, 63), hangul_len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(title[0..hangul_len]));

    const invalid_len = copyValidUtf8Title(&title, "abc\xffdef");
    try std.testing.expectEqual(@as(usize, 3), invalid_len);
    try std.testing.expectEqualStrings("abc", title[0..invalid_len]);
}

test "normalizePasteNewlines collapses CRLF/LF/CR and skips when unchanged" {
    const a = std.testing.allocator;
    { // CR target: CRLF·LF·CR 모두 단일 CR
        const out = SessionCore.normalizePasteNewlines(a, "1\r\n2\n3\r4", '\r').?;
        defer a.free(out);
        try std.testing.expectEqualStrings("1\r2\r3\r4", out);
    }
    { // LF target: 모두 단일 LF
        const out = SessionCore.normalizePasteNewlines(a, "1\r\n2\n3\r4", '\n').?;
        defer a.free(out);
        try std.testing.expectEqualStrings("1\n2\n3\n4", out);
    }
    // 변환 불필요 → null (복사 0). CR target 인데 LF 없음 / LF target 인데 CR 없음.
    try std.testing.expect(SessionCore.normalizePasteNewlines(a, "abc", '\r') == null);
    try std.testing.expect(SessionCore.normalizePasteNewlines(a, "a\rb\rc", '\r') == null);
    try std.testing.expect(SessionCore.normalizePasteNewlines(a, "a\nb\nc", '\n') == null);
    try std.testing.expect(SessionCore.normalizePasteNewlines(a, "", '\r') == null);
    { // 대량 입력 정확성 (memcpy 구간 + 줄바꿈 혼합). LF→CR 1:1 이라 길이 동일.
        var big: [10000]u8 = undefined;
        for (&big, 0..) |*c, idx| c.* = if (idx % 100 == 99) '\n' else 'x';
        const out = SessionCore.normalizePasteNewlines(a, &big, '\r').?;
        defer a.free(out);
        try std.testing.expectEqual(@as(usize, 10000), out.len);
        try std.testing.expectEqual(@as(u8, '\r'), out[99]);
        try std.testing.expectEqual(@as(u8, 'x'), out[100]);
    }
    { // CRLF 대량 → 길이 절반 가까이 축소 (\r\n → \r)
        var big: [200]u8 = undefined;
        var k: usize = 0;
        while (k < big.len) : (k += 2) {
            big[k] = '\r';
            big[k + 1] = '\n';
        }
        const out = SessionCore.normalizePasteNewlines(a, &big, '\r').?;
        defer a.free(out);
        try std.testing.expectEqual(@as(usize, 100), out.len); // 100 CRLF → 100 CR
    }
}
