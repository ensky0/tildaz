const std = @import("std");
const runtime = @import("runtime.zig");
const Runtime = runtime.Runtime;
const builtin = @import("builtin");
const ghostty = @import("ghostty-vt");
const app_event = @import("app_event.zig");
const terminal = @import("terminal.zig");
const TerminalBackend = terminal.TerminalBackend;
const terminal_interaction = @import("terminal_interaction.zig");
const themes = @import("themes.zig");
const perf = @import("perf.zig");
const log = @import("log.zig");
const pwd_uri = @import("pwd_uri.zig");
const local_hostname = @import("local_hostname.zig");
const process_cwd = @import("process_cwd.zig");
const instance_context = @import("instance_context.zig");

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

    /// **실제로 ring 에 넣은 byte 수**를 돌려준다 (#398). `closed` 면 중간에 그만두므로
    /// `data.len` 보다 작을 수 있고, 호출자는 이 값을 세야 카운터가 사실과 맞는다.
    fn push(self: *RingBuffer, data: []const u8) usize {
        var i: usize = 0;
        while (i < data.len) {
            if (self.closed.load(.acquire)) return i;
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
        return i;
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

/// 새 탭이 아직 첫 non-empty OSC 제목을 받지 못한 상태. 시간 개념이 없다 —
/// 탭 생성 시점에 이미 `Tab N` 을 표시해 두므로 (#364) "언제 fallback 을 쓸지"
/// 를 판정할 필요가 없고, 첫 제목이 올 때까지 계속 waiting 이다. 이 flag 의
/// 유일한 용도는 그 첫 제목을 debounce 없이 즉시 반영하는 것.
const InitialTitleState = struct {
    waiting: bool = false,

    fn begin(self: *InitialTitleState) void {
        self.waiting = true;
    }

    fn clear(self: *InitialTitleState) void {
        self.waiting = false;
    }
};

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

    /// `immediate` 는 첫 제목 전용 — 화면에 `Tab N` 만 있고 아직 화면에서
    /// 밀어낼 중간 제목이 없으므로 debounce 를 건너뛴다 (#364).
    fn flush(self: *PendingTitle, dest: []u8, dest_len: *usize, now_ns: u64, immediate: bool) bool {
        if (!self.active) return false;
        if (!immediate and now_ns - self.since_ns < TITLE_DEBOUNCE_NS) return false;

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
    title_clock: runtime.Timer,
    title: [64]u8 = undefined,
    title_len: usize = 0,
    /// OSC 0/2 빈 제목이 오면 최초 자동 이름으로 돌아가기 위한 stable id.
    default_title_id: usize = 0,
    initial_title: InitialTitleState = .{},
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
        rt: Runtime,
        alloc: std.mem.Allocator,
        cols: u16,
        rows: u16,
        shell: terminal.ShellCommand,
        max_scroll_lines: usize,
        theme: ?*const themes.Theme,
        extra_env: ?[]const terminal.ExtraEnv,
        cwd: ?[]const u8,
        tab_exit_fn: SessionCore.TabExitNotify,
        tab_exit_userdata: ?*anyopaque,
    ) !*Tab {
        const tab = try alloc.create(Tab);
        errdefer alloc.destroy(tab);

        var term = try initVtTerminal(rt, alloc, cols, rows, max_scroll_lines, theme);
        errdefer term.deinit(alloc);

        var backend = try TerminalBackend.init(.{
            .allocator = alloc,
            .cols = cols,
            .rows = rows,
            .shell = shell,
            .extra_env = extra_env,
            .cwd = cwd,
        });
        errdefer backend.deinit();
        const title_clock: runtime.Timer = .start(rt);

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

    /// 새 탭 제목 초기화. **첫 OSC 를 기다리는 동안 제목 자리가 비지 않도록
    /// `Tab N` 을 먼저 써 둔다** (#364). OSC 를 보내는 셸은 곧 자기 제목으로
    /// 교체하고, 안 보내는 셸 (cmd / PowerShell / POSIX `sh` / rc 없는 zsh) 은
    /// 이 값이 그대로 남는다 — 이전 구현은 1 초를 기다린 뒤에야 이걸 썼다.
    fn beginInitialTitle(tab: *Tab, title_id: usize) void {
        tab.default_title_id = title_id;
        tab.pending_title.clear();
        writeDefaultTitle(&tab.title, &tab.title_len, title_id);
        tab.initial_title.begin();
    }

    fn syncTerminalTitle(tab: *Tab) void {
        const terminal_title: ?[]const u8 = if (tab.terminal.getTitle()) |title| title else null;
        queueAutomaticTitle(
            &tab.pending_title,
            tab.title[0..tab.title_len],
            tab.default_title_id,
            terminal_title,
            tab.title_clock.read(),
        );
    }

    fn flushPendingTitle(tab: *Tab) bool {
        return flushAutomaticTitle(
            &tab.initial_title,
            &tab.pending_title,
            &tab.title,
            &tab.title_len,
            tab.title_clock.read(),
        );
    }

    fn onPtyOutput(data: []const u8, userdata: ?*anyopaque) void {
        const tab: *Tab = @ptrCast(@alignCast(userdata.?));
        const t0 = perf.now();
        // #398 — **넣은 양**을 센다. `closed` 면 `push` 가 중간에 그만두는데 예전에는
        // `data.len` 을 그대로 세어서, 실제로는 한 byte 도 안 들어간 것까지 계상됐다.
        //
        // Windows 에서 `readloop bytes - drain bytes` 가 **항상 정확히 16** 이던 것이 이것이다.
        // `Tab.deinit` 이 (deadlock 을 피하려고) `output_ring.close()` 를 먼저 부르고
        // `backend.deinit()` 을 뒤에 하는데, 그 사이에 ConPTY 가 **teardown 시퀀스**
        // `ESC[?1004l` + `ESC[?9001l` (8+8 = 16 byte) 를 보낸다 — 시작 때 보내는 협상
        // preamble `…h` 의 짝이다 (#385). read thread 가 그것을 읽어 push 하지만 이미 closed 라
        // 즉시 반환하고, 카운터만 16 이 올라갔다. ConPTY 가 없는 Linux · macOS 는 0 이었다.
        //
        // 그 16 byte 는 **손실이 아니다** — 창이 닫히는 참의 모드 해제라 파싱할 것이 없다.
        const wrote = tab.output_ring.push(data);
        perf.addTimedBytes(&perf.push, t0, wrote);
    }

    fn onPtyExit(userdata: ?*anyopaque) void {
        const tab: *Tab = @ptrCast(@alignCast(userdata.?));
        log.appendLine("tab", "shell exited: title={s}", .{tab.title[0..tab.title_len]});
        tab.tab_exit_fn(@intFromPtr(tab), tab.tab_exit_userdata);
    }

    /// stress 하네스 전용 통로 (#371) — `drainFrame` 의 프레임 예산을 거치지 않고
    /// output ring 에서 **한 덩어리**를 소화한다. 소화할 것이 있었으면 true.
    ///
    /// 한 덩어리씩 돌려주는 이유가 있다. "ring 이 빌 때까지" 도는 형태로 두었더니
    /// 우리가 producer 보다 느린 워크로드 (CJK · emoji) 에서 **그 루프가 끝나지 않았다**
    /// — 비우는 동안 read thread 가 계속 채우기 때문이다. 그래서 한 번 호출이 128 MiB
    /// 를 다 먹고 반환해, 하네스가 중간에 구간을 나누거나 시각을 찍을 틈이 없었다.
    /// 언제 멈출지는 하네스가 정해야 한다.
    ///
    /// 프레임 예산 아래의 체감 처리량을 잴 때는 이걸 쓰지 않고
    /// `SessionCore.drainOutputForRender` 를 루프로 부른다 — 그쪽이 `DRAIN_FRAME_BUDGET_NS`
    /// 를 지키는 경로다. 단 **프레임당 1 회로 부르면 앱과 다르다** — 사양 A (#387) 이후
    /// host 는 프레임 사이에도 부른다 (SPEC §13.1).
    pub fn drainChunkForStress(tab: *Tab) bool {
        return tab.drainOutputChunk();
    }
};

/// 한 탭의 VT 상태를 앱 설정대로 만든다. `Tab.init` 과 stress 하네스 (#371) 가
/// **같은 정의**를 쓰도록 한 곳에 둔다 — 하네스가 이 구성을 베껴 쓰면 한쪽만
/// 바뀌었을 때 앱과 다른 파서 설정을 재게 되고, 그 차이는 숫자에 조용히 섞인다.
///
/// scrollback 은 줄 수가 아니라 byte 예산이라 cols 에 따른 page 용량으로 환산한다.
pub fn initVtTerminal(
    rt: Runtime,
    alloc: std.mem.Allocator,
    cols: u16,
    rows: u16,
    max_scroll_lines: usize,
    theme: ?*const themes.Theme,
) !ghostty.Terminal {
    const term_colors = if (theme) |t| ghostty.Terminal.Colors{
        .foreground = ghostty.color.DynamicRGB.init(t.foreground),
        .background = ghostty.color.DynamicRGB.init(t.background),
        .cursor = .unset,
        .palette = ghostty.color.DynamicPalette.init(themes.buildPalette(t.palette)),
    } else ghostty.Terminal.Colors.default;

    // #451 — ghostty main 의 `Terminal.init` 도 `std.Io` 를 첫 인자로 받는다 (upstream 이
    // 같은 0.16 전환을 했다). 우리 `rt.io` 가 그대로 들어간다.
    var term = try ghostty.Terminal.init(rt.io, alloc, .{
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

    return term;
}

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

/// OSC 0/2 제목 정책의 단일 진입점. OSC 빈 payload (ghostty
/// `getTitle() == null`) 는 최초 `Tab N` 으로 복귀한다.
fn applyAutomaticTitle(
    dest: []u8,
    len: *usize,
    default_title_id: usize,
    automatic_title: ?[]const u8,
) void {
    if (automatic_title) |title| {
        if (title.len > 0) {
            len.* = copyValidUtf8Title(dest, title);
            return;
        }
    }
    writeDefaultTitle(dest, len, default_title_id);
}

/// OSC title을 공통 pending 상태에 넣는다. 빈 OSC payload (ghostty
/// `getTitle() == null`) 의 후보는 `Tab N` 이고, 그 값은 탭 생성 시점부터 이미
/// 표시돼 있으므로 (#364) `PendingTitle.queue` 가 "표시 제목과 같다" 로 폐기한다
/// — 별도의 초기 상태 분기가 필요 없다.
fn queueAutomaticTitle(
    pending: *PendingTitle,
    displayed: []const u8,
    default_title_id: usize,
    automatic_title: ?[]const u8,
    now_ns: u64,
) void {
    var candidate: [64]u8 = undefined;
    var candidate_len: usize = 0;
    applyAutomaticTitle(
        &candidate,
        &candidate_len,
        default_title_id,
        automatic_title,
    );
    pending.queue(displayed, candidate[0..candidate_len], now_ns);
}

/// **첫 제목은 debounce 없이 즉시 반영한다** (#364). 화면에는 탭 생성 시점부터
/// `Tab N` 이 있고 아직 화면에서 밀어낼 중간 제목이 없으므로, 150ms 를 기다리면
/// 지연만 생긴다. 두 번째 제목부터는 평소대로 trailing-edge debounce 를 탄다.
///
/// 전제 — 셸이 시작 직후 서로 다른 제목을 150ms 안에 두 번 이상 보내지 않는다.
/// Linux · Windows 실측에서 5개 셸 계열 (bash `/etc/bash.bashrc` PS1 /
/// zsh + Powerlevel10k / fish 기본 `fish_title` / Git Bash `git-prompt.sh` /
/// WSL Debian `~/.bashrc` PS1) 이 모두 "시작 직후 제목 1회 (구별 1)" 였다:
///   - https://github.com/ensky0/tildaz/issues/364#issuecomment-5151754093 (Linux)
///   - https://github.com/ensky0/tildaz/issues/364#issuecomment-5151857026 (Windows)
///
/// 이 전제를 깨는 두 경우를 알고 있다.
///   1. **macOS 는 미측정.** login shell (`-l`, #282 D5) 이라 rc 를 더 읽는다.
///   2. **Windows 시스템 conhost 경로** (kernel32 `CreatePseudoConsole`) 는
///      conhost 가 exe 경로를 첫 제목으로 보낸다 (`cmd` →
///      `C:\Windows\SYSTEM32\cmd.exe`). tildaz 는 번들 런타임만 쓰고 이
///      fallback 을 없앴으므로 (#339) 현행 코드엔 해당하지 않지만, **되살리면
///      즉시 반영이 exe 경로를 먼저 보여주므로 여기를 재검토해야 한다.**
fn flushAutomaticTitle(
    initial: *InitialTitleState,
    pending: *PendingTitle,
    dest: []u8,
    dest_len: *usize,
    now_ns: u64,
) bool {
    if (!pending.active) return false;
    const changed = pending.flush(dest, dest_len, now_ns, initial.waiting);
    if (!pending.active) initial.clear();
    return changed;
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
    tabs: std.ArrayList(*Tab) = .empty,
    active_tab: usize = 0,
    /// 비활성 탭 drain의 다음 시작 위치. 탭 close/reorder 뒤에는 drain 시점에
    /// 현재 길이로 정규화하므로 별도 인덱스 보정이 필요 없다.
    inactive_drain_cursor: usize = 0,
    next_tab_id: usize = 1,

    /// 드레인 **한 번**이 UI thread 를 점유할 수 있는 공통 상한 = **최악 입력 지연 예산**
    /// (사양은 SPEC §13, #387). 처리량 상한이 아니다 — 얼마나 자주 드레인하는지는 host 가
    /// 정한다. 활성/비활성 탭이 이 예산을 함께 쓰므로 탭 수가 늘어도 총 점유는 그대로다.
    ///
    /// **4 ms 인 이유** (#387, 2026-08-05 결정). 세 platform 실측이 8 → 4 ms 에서 처리량
    /// 손실 없이 점유만 줄었다: Windows ② 60 Hz 는 처리량 유지(−4.1~+1.8 %)에 프레임 tick
    /// 점유 9.7 → 5.8 ms, Windows ① 120 Hz 는 tick fps 103 → 120, macOS 60 Hz 는 fps
    /// 56.7 → 60.0 · 처리량 +3.3 %, macOS 120 Hz 는 fps ×2.4, Linux 120 Hz 는 fps ×1.82.
    /// **하한은 4 ms 다** — macOS 120 Hz 의 3 ms 에서 duty 포화가 깨져 처리량이 23 % 떨어졌다.
    ///
    /// 이 값이 처리량과 무관해진 것은 사양 A (프레임 사이에도 드레인) 덕이다. 사양 A 가
    /// 꺼진 구조에서는 예산이 곧 처리량이라 (실측: 8 → 4 ms 에서 처리량 ×0.50) 값을 줄일
    /// 수 없었다.
    ///
    /// stress 하네스 (#371) 가 이 값을 읽어 예산 초과 프레임을 센다 — 하네스가 숫자를
    /// 따로 적어 두면 여기만 바뀌었을 때 조용히 다른 기준으로 판정한다.
    pub const DRAIN_FRAME_BUDGET_NS: u64 = 4 * std.time.ns_per_ms;

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

    /// 새 탭이 물려받을 시작 디렉토리 (#366). 활성 탭의 셸이 OSC 7 로 알린 위치를
    /// 쓴다. 값이 없거나 (셸이 OSC 7 을 안 보냄 / tmux 안이라 흡수됨 / ssh 원격
    /// 경로라 거부됨) 그리로 들어갈 수 없으면 `null` — 각 backend 가 홈에서 시작한다
    /// ([#265](https://github.com/ensky0/tildaz/issues/265) 의 기존 동작).
    ///
    /// 반환 slice 는 `buf` 안을 가리키므로 호출자의 `buf` 가 살아 있는 동안만 유효하다.
    fn inheritedCwd(self: *SessionCore, buf: []u8) ?[]const u8 {
        // 첫 탭은 물려받을 곳이 없다.
        if (self.tabs.items.len == 0 or self.active_tab >= self.tabs.items.len) return null;
        const tab = self.tabs.items[self.active_tab];

        // 경로 표기는 **탭의 셸 기준** — WSL 탭은 host 가 Windows 여도 Linux 경로다.
        const wsl = terminal.isWslShell(self.shell_command);
        const style: pwd_uri.Style = if (builtin.os.tag == .windows and !wsl) .windows else .posix;

        // ① 셸이 OSC 7 로 알린 위치. 셸의 논리 경로 (`$PWD`) 라 symlink 를 따라 들어간
        //    사용자의 기대에 맞으므로 ② 보다 우선한다.
        if (tab.terminal.getPwd()) |payload| {
            var host_buf: [local_hostname.max_len]u8 = undefined;
            const hostname = local_hostname.get(&host_buf);
            if (pwd_uri.parse(payload, buf, .{ .hostname = hostname, .style = style })) |path| {
                if (usableDir(path, wsl)) {
                    log.appendLine("cwd", "new tab cwd={s} (shell reported)", .{path});
                    return path;
                }
                log.appendLine("cwd", "shell-reported cwd unusable: {s}", .{path});
            } else {
                // 다른 머신 (ssh) 이거나 표기가 이 탭의 셸과 안 맞는 경우.
                log.appendLine(
                    "cwd",
                    "shell-reported pwd rejected: payload={s} style={s} hostname={s}",
                    .{ payload, @tagName(style), hostname },
                );
            }
        }

        // ② 셸이 알려주지 않으면 OS 에 직접 묻는다 (Linux · macOS 만 — Windows 는 항상
        //    null 이라 OSC 7 주입에 의존한다). 셸 종류 / rc 구성과 무관하게 동작한다.
        if (process_cwd.ofPid(tab.backend.childPid(), buf)) |path| {
            if (usableDir(path, wsl)) {
                log.appendLine("cwd", "new tab cwd={s} (process probe)", .{path});
                return path;
            }
        }

        log.appendLine("cwd", "no inheritable cwd, starting in home", .{});
        return null;
    }

    /// 시작 디렉토리로 실제 쓸 수 있는지. `access` 는 **파일도 통과시켜** spawn 이
    /// `ENOTDIR` 로 실패하므로 디렉토리로 열어 본다.
    ///
    /// WSL 탭만 예외로 확인 없이 통과시킨다 — 보고된 Linux 경로를 Windows 쪽에서 확인할
    /// 방법이 없어서 `wsl --cd` 에 위임한다. 그 경로가 없으면 wsl 이 에러 한 줄을 찍고
    /// 셸은 정상적으로 뜬다 (Windows 실기 확인, #366).
    fn usableDir(path: []const u8, wsl: bool) bool {
        if (builtin.os.tag == .windows and wsl) return true;
        var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
        dir.close();
        return true;
    }

    pub fn createTab(self: *SessionCore, cols: u16, rows: u16) !void {
        var cwd_buf: [pwd_uri.max_path_len]u8 = undefined;
        const cwd = self.inheritedCwd(&cwd_buf);

        const tab = try Tab.init(
            self.allocator,
            cols,
            rows,
            self.shell_command,
            self.max_scroll_lines,
            self.theme,
            self.extra_env,
            cwd,
            self.tab_exit_fn,
            self.tab_exit_userdata,
        );
        errdefer tab.deinit(self.allocator);

        tab.beginInitialTitle(self.next_tab_id);
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
        // #397 — 측정 인스턴스는 탭을 버리기 전에 ring 에 남은 출력을 마저 파싱한다.
        // ring 은 Tab 소유라 아래 deinit 뒤에는 사라지고, 그 시점의 perf 스냅숏
        // (#396 의 종료 시 자동 덤프) 은 파싱하다 만 값이 된다 — macOS 실측에서
        // `drain` 이 `readloop` 의 54 % 였다. host 의 `terminate` 구현이 셋 다 달라
        // (macOS 는 `exit()` 직행) 종료 뒤에 기대면 platform 마다 결과가 갈리므로
        // 공통 경로인 여기서 끝낸다. `drainOutputChunk` 은 ring 이 비면 false 라
        // 그 자체가 종료 조건이고, producer 는 이미 죽어 EOF 다. worker 는 no-op.
        if (instance_context.isStress()) while (Tab.drainOutputChunk(tab)) {};
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

    /// #282 A8 — Ctrl+C 등 interrupt char 즉시 송신. `write_queue` 의 pending
    /// (대량 paste 등)을 폐기하고 backend 에 직접 write 해 SIGINT 가 큐 뒤에 밀려
    /// 늦게 도착("Ctrl+C 안 먹힘")하는 것을 막는다 + #242 로 viewport 를 맨 아래로.
    /// macOS host 가 쓰던 `Tab.interruptWrite` 경로를 세 platform 공통 진입점으로
    /// 캡슐화 — Windows / Linux 도 이 경로로 SIGINT 즉시성이 동등해진다.
    pub fn interruptActive(self: *SessionCore, data: []const u8) void {
        if (self.activeTab()) |tab| {
            tab.interruptWrite(data);
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
        if (std.mem.findScalar(u8, data, other) == null) return null;

        // CRLF만 2→1로 줄고, 단독 CR/LF와 나머지 byte는 모두 1→1이다.
        // 정확한 결과 길이로 할당해야 반환 slice를 그대로 free할 수 있다.
        // 입력 길이로 할당한 뒤 짧은 slice를 반환하면 allocator의 allocation/free
        // size가 달라져 paste 호출부와 테스트에서 invalid free가 된다 (#318).
        const normalized_len = data.len - std.mem.count(u8, data, "\r\n");
        const buf = alloc.alloc(u8, normalized_len) catch return null;
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
    /// 매 frame 첫 순서를 보장하되, 모든 탭이 하나의 `DRAIN_FRAME_BUDGET_NS` 예산을 공유해 탭 수가
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

    /// 세 host 가 render 필요 여부를 판단하는 **공통 경로**. 비활성 탭의 본문 출력만
    /// 파싱한 경우 현재 화면은 변하지 않지만, 어느 탭이든 제목이 바뀌면 탭바를 다시
    /// 그려야 한다.
    ///
    /// 반환값은 **"화면이 바뀌었나" 하나**다. *"출력이 밀렸으니 이 프레임은 건너뛴다"*
    /// 는 판단을 여기서 하지 않는다 — 밀린 출력은 그릴 이유이지 안 그릴 이유가 아니다.
    /// 렌더를 줄이는 게이트는 #386 ② 의 "안 바뀌면 안 그린다" 하나뿐이다 (host 쪽
    /// `needs_render` / `g_needs_render` / `needs_redraw`).
    ///
    /// #388 — 이전에는 Windows 만 이 함수 대신 `prepareActiveFrame` 을 거쳤고, 그 안에
    /// **밀린 출력이 있으면 직전 렌더 8 ms 안이면 렌더를 건너뛰는** throttle 이 있었다
    /// ([`619fa44`](https://github.com/ensky0/tildaz/commit/619fa44) 이 근거 없이 200 → 8 ms
    /// 로 바꾼 값). 지웠다. 근거:
    ///
    /// - **현행 예산에서 물릴 수 없었다.** throttle 은 `active_output_pending` 일 때만
    ///   상담되는데 그건 실질적으로 "예산을 다 썼다" 와 같고 (일찍 끝나면 ring 이 비어
    ///   pending 이 거짓), 그러면 `milliTimestamp` delta 가 예산 이상이라 문턱과 같은 값인
    ///   8 을 넘는다. Windows ①·② 의 8 ms 폭포 측정이 모두 `skip=0` 이었다.
    /// - **살아나면 거래가 나쁘다.** 문턱만 20 ms 로 올려 강제로 물린 실측(Windows ② ·
    ///   60 Hz)에서 그린 fps 가 60.0 → 30.4 로 반토막인데 처리량은 +0.7~4.3 % 였다.
    /// - **프레임 tick 만 막는 게 아니었다.** `render_fn` 은 `WM_SIZE` 즉시 렌더 ·
    ///   Alt+Enter 전환에서도 불리는데 그것들까지 no-op 이 될 수 있었다.
    /// - **Windows Terminal 도 터미널 렌더에 ms 게이트를 두지 않는다** — DXGI
    ///   frame-latency waitable + `_redraw` 플래그로 pacing 한다.
    pub fn drainOutputForRender(self: *SessionCore) bool {
        const drained = self.drainFrame();
        return drained.active_output or drained.active_output_pending or drained.title_changed;
    }

    /// 아직 파싱하지 않은 PTY 출력이 어느 탭에든 남아 있으면 true.
    ///
    /// #436 — host 가 *"지금 자도 되나"* 를 판단하는 데 쓴다. `drainOutputForRender` 는
    /// **"화면이 바뀌었나" 하나**만 돌려주므로 (§13.4) 밀린 출력 여부를 알 수 없다.
    ///
    /// **활성 탭만 보지 않는다** — `drainFrame` 이 비활성 탭도 같은 예산 안에서 번갈아
    /// 파싱하므로 (§13, 탭 제목 갱신), 비활성 탭에 밀린 것이 있어도 계속 돌아야 한다.
    pub fn hasPendingOutput(self: *SessionCore) bool {
        for (self.tabs.items) |tab| {
            if (!tab.output_ring.isEmpty()) return true;
        }
        return false;
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
    applyAutomaticTitle(&title, &title_len, 7, terminal_state.getTitle().?);
    try std.testing.expectEqualStrings("fish: ~/src", title[0..title_len]);

    stream.nextSlice("\x1b]0;vim main.zig\x07");
    applyAutomaticTitle(&title, &title_len, 7, terminal_state.getTitle().?);
    try std.testing.expectEqualStrings("vim main.zig", title[0..title_len]);

    stream.nextSlice("\x1b]2;\x1b\\");
    const reset_title: ?[]const u8 = if (terminal_state.getTitle()) |value| value else null;
    applyAutomaticTitle(&title, &title_len, 7, reset_title);
    try std.testing.expectEqualStrings("Tab 7", title[0..title_len]);
}

test "no fallback timer: default title is present from tab creation" {
    // #364 — 이전 구현은 1초 유예가 끝날 때 `Tab N` 을 썼다. 이제 탭 생성 시점
    // (`beginInitialTitle`) 에 이미 쓰여 있고, pending 이 없으면 시간이 얼마나
    // 흘러도 제목을 건드리지 않는다.
    var title: [64]u8 = undefined;
    var title_len: usize = 0;
    writeDefaultTitle(&title, &title_len, 7);
    var initial: InitialTitleState = .{};
    var pending: PendingTitle = .{};
    initial.begin();

    try std.testing.expect(!flushAutomaticTitle(
        &initial,
        &pending,
        &title,
        &title_len,
        5 * std.time.ns_per_s,
    ));
    try std.testing.expectEqualStrings("Tab 7", title[0..title_len]);
    try std.testing.expect(initial.waiting);
}

test "first OSC title applies immediately and the next one debounces" {
    var title: [64]u8 = undefined;
    var title_len: usize = 0;
    writeDefaultTitle(&title, &title_len, 7);
    var initial: InitialTitleState = .{};
    var pending: PendingTitle = .{};
    initial.begin();

    // bash 실측 (~9ms) — 도착한 frame 에서 바로 반영된다.
    const received_ns = 9 * std.time.ns_per_ms;
    queueAutomaticTitle(&pending, title[0..title_len], 7, "~", received_ns);
    try std.testing.expect(flushAutomaticTitle(
        &initial,
        &pending,
        &title,
        &title_len,
        received_ns,
    ));
    try std.testing.expectEqualStrings("~", title[0..title_len]);
    try std.testing.expect(!initial.waiting);

    // 두 번째 제목부터는 150ms debounce 를 다시 탄다 — 즉시 반영이 첫 회
    // 한정임을 고정한다 (이게 없으면 debounce 무력화 회귀를 못 잡는다).
    const second_ns = received_ns + 50 * std.time.ns_per_ms;
    queueAutomaticTitle(&pending, title[0..title_len], 7, "~/work", second_ns);
    try std.testing.expect(!flushAutomaticTitle(
        &initial,
        &pending,
        &title,
        &title_len,
        second_ns + TITLE_DEBOUNCE_NS - 1,
    ));
    try std.testing.expectEqualStrings("~", title[0..title_len]);
    try std.testing.expect(flushAutomaticTitle(
        &initial,
        &pending,
        &title,
        &title_len,
        second_ns + TITLE_DEBOUNCE_NS,
    ));
    try std.testing.expectEqualStrings("~/work", title[0..title_len]);
}

test "empty OSC keeps default title and a late first title still applies immediately" {
    var title: [64]u8 = undefined;
    var title_len: usize = 0;
    writeDefaultTitle(&title, &title_len, 7);
    var initial: InitialTitleState = .{};
    var pending: PendingTitle = .{};
    initial.begin();

    // 빈 OSC 의 후보는 `Tab N` 이고 그게 이미 표시 중이라 후보가 폐기된다
    // (초기 상태 전용 분기 없이 `PendingTitle.queue` 가 처리).
    queueAutomaticTitle(&pending, title[0..title_len], 7, null, 800 * std.time.ns_per_ms);
    try std.testing.expect(!pending.active);
    try std.testing.expect(!flushAutomaticTitle(
        &initial,
        &pending,
        &title,
        &title_len,
        900 * std.time.ns_per_ms,
    ));
    try std.testing.expectEqualStrings("Tab 7", title[0..title_len]);
    try std.testing.expect(initial.waiting);

    // WSL cold 실측 (2.15~2.26초) — 아무리 늦게 와도 첫 제목이면 즉시 반영.
    const late_ns = 2_200 * std.time.ns_per_ms;
    queueAutomaticTitle(&pending, title[0..title_len], 7, "ensky0@host: ~", late_ns);
    try std.testing.expect(flushAutomaticTitle(
        &initial,
        &pending,
        &title,
        &title_len,
        late_ns,
    ));
    try std.testing.expectEqualStrings("ensky0@host: ~", title[0..title_len]);
    try std.testing.expect(!initial.waiting);
}

test "automatic title debounce suppresses short command round trip" {
    var title: [64]u8 = undefined;
    var title_len = copyValidUtf8Title(&title, "~");
    var pending: PendingTitle = .{};

    pending.queue(title[0..title_len], "true ~", 0);
    try std.testing.expect(!pending.flush(&title, &title_len, 149 * std.time.ns_per_ms, false));
    try std.testing.expectEqualStrings("~", title[0..title_len]);

    // 32ms 뒤 fish prompt 가 원래 cwd 제목으로 돌아오면 command title 취소.
    pending.queue(title[0..title_len], "~", 32 * std.time.ns_per_ms);
    try std.testing.expect(!pending.active);
    try std.testing.expect(!pending.flush(&title, &title_len, 500 * std.time.ns_per_ms, false));
    try std.testing.expectEqualStrings("~", title[0..title_len]);
}

test "automatic title debounce applies stable title at exact boundary" {
    var title: [64]u8 = undefined;
    var title_len = copyValidUtf8Title(&title, "~");
    var pending: PendingTitle = .{};

    pending.queue(title[0..title_len], "sleep 3 ~", 0);
    // 같은 값 반복은 timestamp를 reset하지 않는다.
    pending.queue(title[0..title_len], "sleep 3 ~", 100 * std.time.ns_per_ms);
    try std.testing.expect(!pending.flush(&title, &title_len, 149 * std.time.ns_per_ms, false));
    try std.testing.expect(pending.flush(&title, &title_len, 150 * std.time.ns_per_ms, false));
    try std.testing.expectEqualStrings("sleep 3 ~", title[0..title_len]);

    pending.queue(title[0..title_len], "~", 3 * std.time.ns_per_s);
    try std.testing.expect(!pending.flush(&title, &title_len, 3 * std.time.ns_per_s + 149 * std.time.ns_per_ms, false));
    try std.testing.expect(pending.flush(&title, &title_len, 3 * std.time.ns_per_s + 150 * std.time.ns_per_ms, false));
    try std.testing.expectEqualStrings("~", title[0..title_len]);
}

test "automatic title debounce supports default reset" {
    var title: [64]u8 = undefined;
    var title_len = copyValidUtf8Title(&title, "shell title");
    var candidate: [64]u8 = undefined;
    var candidate_len: usize = 0;
    applyAutomaticTitle(&candidate, &candidate_len, 7, null);

    var pending: PendingTitle = .{};
    pending.queue(title[0..title_len], candidate[0..candidate_len], 0);
    try std.testing.expect(pending.flush(&title, &title_len, TITLE_DEBOUNCE_NS, false));
    try std.testing.expectEqualStrings("Tab 7", title[0..title_len]);
}

test "POSIX: new tab shows Tab N from creation, before any shell output" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const Exit = struct {
        fn notify(_: usize, _: ?*anyopaque) void {}
    };
    // #364 — 셸 출력과 무관한 불변식만 본다. `/bin/sh` 는 Linux · macOS 양쪽에
    // 있고 OSC 제목을 보내지 않으므로 (Linux 실측 5/5 미전송) 이 테스트는 어느
    // 머신의 rc 구성에도 흔들리지 않는다.
    var session = SessionCore.init(
        std.testing.allocator,
        "/bin/sh",
        100,
        null,
        null,
        &Exit.notify,
        null,
    );
    defer session.deinit();

    try session.createTab(80, 24);
    {
        const tab = session.activeTab().?;
        try std.testing.expectEqualStrings("Tab 1", tab.title[0..tab.title_len]);
    }
    try session.createTab(80, 24);
    {
        const tab = session.activeTab().?;
        try std.testing.expectEqualStrings("Tab 2", tab.title[0..tab.title_len]);
    }

    // 유예가 없으니 어느 시점에도 제목 자리가 비지 않는다. 셸이 제목을 보내는
    // 구성 (macOS 는 `sh -l` 이라 `~/.profile` 을 읽는다) 에서도 성립하도록
    // 같은 문자열이 아니라 **비어 있지 않음**을 본다.
    for (0..20) |_| {
        _ = session.drainOutputForRender();
        try std.testing.expect(session.tabAt(0).?.title_len > 0);
        try std.testing.expect(session.tabAt(1).?.title_len > 0);
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

test "POSIX: OSC 7 이 우선하고 쓸 수 없으면 프로세스 조회로 내려간다 (#366)" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const Exit = struct {
        fn notify(_: usize, _: ?*anyopaque) void {}
    };
    var session = SessionCore.init(
        std.testing.allocator,
        "/bin/sh",
        100,
        null,
        null,
        &Exit.notify,
        null,
    );
    defer session.deinit();
    try session.createTab(80, 24);

    var cwd_buf: [pwd_uri.max_path_len]u8 = undefined;

    // `/bin/sh` 는 OSC 7 을 보내지 않지만, POSIX 는 프로세스 조회 fallback 이 있어서
    // 셸의 현재 위치를 얻는다. 구체적인 값은 spawn 타이밍 (자식이 `chdir` 하기 전일
    // 수 있다) 에 따라 홈이거나 앱의 위치라 단정하지 않고, **절대 경로가 나온다**는
    // 것만 본다.
    {
        const probed = session.inheritedCwd(&cwd_buf) orelse return error.FallbackMissing;
        try std.testing.expect(std.Io.Dir.path.isAbsolute(probed));
    }

    // host 는 조회한 값을 그대로 써서 파서의 host 검사를 실제로 통과시킨다. 조회가
    // 실패해 빈 문자열이면 `file:///…` 형태가 되고 그것도 수락 대상이다.
    var host_buf: [local_hostname.max_len]u8 = undefined;
    const host = local_hostname.get(&host_buf);
    var payload: [local_hostname.max_len + 64]u8 = undefined;

    const tab = session.tabAt(0).?;

    // 셸이 알린 위치가 있으면 그것이 조회보다 우선한다. `/` 를 쓰는 이유는 어느 OS
    // 에서도 심볼릭 링크가 아니고 항상 있기 때문이다.
    tab.stream.nextSlice(try std.fmt.bufPrint(&payload, "\x1b]7;file://{s}/\x1b\\", .{host}));
    try std.testing.expectEqualStrings("/", session.inheritedCwd(&cwd_buf).?);

    // 파싱은 되지만 열 수 없는 경로 → 조회로 내려간다 (그 경로를 그대로 쓰지 않는다).
    tab.stream.nextSlice(try std.fmt.bufPrint(
        &payload,
        "\x1b]7;file://{s}/tz366-does-not-exist\x1b\\",
        .{host},
    ));
    {
        const probed = session.inheritedCwd(&cwd_buf) orelse return error.FallbackMissing;
        try std.testing.expect(!std.mem.eql(u8, probed, "/tz366-does-not-exist"));
        try std.testing.expect(std.Io.Dir.path.isAbsolute(probed));
    }

    // 다른 머신 (ssh 원격) → 거부되고 조회로 내려간다.
    tab.stream.nextSlice("\x1b]7;file://tz366-other-box/\x1b\\");
    {
        const probed = session.inheritedCwd(&cwd_buf) orelse return error.FallbackMissing;
        try std.testing.expect(std.Io.Dir.path.isAbsolute(probed));
    }
}

test "Windows ConPTY updates active and inactive tab titles without switching" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const Exit = struct {
        fn notify(_: usize, _: ?*anyopaque) void {}
    };
    const shell = std.unicode.utf8ToUtf16LeStringLiteral(
        "cmd.exe /d /q /c \"title TILDAZ_OSC_TEST& ping -n 2 127.0.0.1 >nul\"",
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
    // 번들 _internal 런타임이 테스트 바이너리 옆에 없으면 ConPty 를 못 만든다
    // (fallback 제거, #339) — 그 환경에선 skip.
    session.createTab(80, 24) catch |err| switch (err) {
        error.ConptyRuntimeUnavailable => return error.SkipZigTest,
        else => return err,
    };
    try session.createTab(80, 24);
    try std.testing.expectEqual(@as(usize, 1), session.activeIndex());
    // #364 — 탭 생성 시점부터 `Tab N` 이 들어 있다 (이전엔 1초 동안 빈 제목).
    {
        const t0 = session.tabAt(0).?;
        const t1 = session.tabAt(1).?;
        try std.testing.expectEqualStrings("Tab 1", t0.title[0..t0.title_len]);
        try std.testing.expectEqualStrings("Tab 2", t1.title[0..t1.title_len]);
    }

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

test "Windows ConPTY without OSC keeps default title from tab creation" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const Exit = struct {
        fn notify(_: usize, _: ?*anyopaque) void {}
    };
    const shell = std.unicode.utf8ToUtf16LeStringLiteral(
        "cmd.exe /d /q /c \"ping -n 4 127.0.0.1 >nul\"",
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
    // 번들 _internal 런타임이 없으면 skip (fallback 제거, #339).
    session.createTab(80, 24) catch |err| switch (err) {
        error.ConptyRuntimeUnavailable => return error.SkipZigTest,
        else => return err,
    };
    // #364 — cmd 는 OSC 0/2 를 보내지 않는다 (Windows 실측 10/10 미전송). 생성
    // 직후부터 `Tab 1` 이고, 유예가 없으니 빈 제목 구간도 교체도 없다.
    {
        const tab = session.activeTab().?;
        try std.testing.expectEqualStrings("Tab 1", tab.title[0..tab.title_len]);
    }

    // 이후로도 제목 자리가 비지 않는다. 문자열을 고정하지 않는 이유: conhost 가
    // 종료 시점 등에 제목을 보낼지는 우리 계약이 아니라 환경 사실이다 (실측에서
    // cmd 는 10/10 미전송이었지만 그걸 테스트로 못 박지 않는다).
    var elapsed = try std.time.Timer.start();
    while (elapsed.read() < 1500 * std.time.ns_per_ms) {
        _ = session.drainOutputForRender();
        try std.testing.expect(session.activeTab().?.title_len > 0);
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
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
