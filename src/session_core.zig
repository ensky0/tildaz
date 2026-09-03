const std = @import("std");
const runtime = @import("runtime.zig");
const Runtime = runtime.Runtime;
const builtin = @import("builtin");
const ghostty = @import("ghostty-vt");
const pane_layout = @import("pane_layout.zig");
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
    /// #451 — 0.16 은 동기화 primitive 를 `std.Io` 로 옮겼고 (릴리즈 노트 *Sync
    /// Primitives*: `Thread.Mutex` ➡️ `Io.Mutex` · `Thread.ResetEvent` ➡️ `Io.Event`),
    /// 그 API 는 lock / wait / set 마다 `Io` 를 받는다. 이 큐는 UI 스레드와 write
    /// 스레드의 경계라 호출이 잦아, 매번 인자로 넘기는 대신 큐가 한 번 보관한다
    /// (`Tab.init` 이 넣는다 — 기본값이 없어 빠뜨리면 컴파일이 잡는다).
    io: std.Io,
    buf: [8 * 1024 * 1024]u8 = undefined,
    head: usize = 0,
    tail: usize = 0,
    mutex: std.Io.Mutex = .init,
    event: std.Io.Event = .unset,
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
            self.mutex.lockUncancelable(self.io);
            if (self.closed) {
                self.mutex.unlock(self.io);
                return;
            }

            const free = self.freeSpace();
            if (free == 0) {
                self.mutex.unlock(self.io);
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
            self.mutex.unlock(self.io);
            self.event.set(self.io);
            i += batch;
        }
    }

    fn pop(self: *WriteQueue, out: []u8) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var n: usize = 0;
        while (self.tail != self.head and n < out.len) {
            out[n] = self.buf[self.tail];
            self.tail = (self.tail + 1) % self.buf.len;
            n += 1;
        }
        return n;
    }

    fn close(self: *WriteQueue) void {
        self.mutex.lockUncancelable(self.io);
        self.closed = true;
        self.mutex.unlock(self.io);
        self.event.set(self.io);
    }

    /// Pending data 즉시 폐기 — Ctrl+C interrupt 시 큐에 쌓인 paste data 등을
    /// 무효화. write_thread 가 spinning (queue full 시) 중이면 free 공간 생기게
    /// 하는 효과도 있어 main thread 의 다음 push 즉시 진행.
    fn reset(self: *WriteQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.head = 0;
        self.tail = 0;
    }

    fn isClosed(self: *WriteQueue) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
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
    /// [#483](https://github.com/ensky0/tildaz/issues/483) 2단계 ① — 이 터미널의 렌더
    /// 스냅숏. 이전에는 렌더러가 하나를 들고 활성 탭마다 갈아 끼웠는데, pane 이 둘 이상
    /// 보이면 그 하나가 프레임마다 pane 수만큼 전체 재구축을 하므로 (ghostty
    /// `RenderState.update` 는 viewport pin 이 다르면 전부 다시 만든다) 탭이 갖는다.
    ///
    /// **보이지 않는 탭의 것은 비워 둔다** (`releaseRenderState`) — 한 state 가 4K 에서
    /// 2~3 MB 라 32 탭을 다 들고 있으면 메모리가 지금의 30 배가 된다. 활성 탭이 바뀌는
    /// 곳 (`releaseHiddenRenderStates`) 이 비우고, 다음에 보일 때 `update` 가 다시 채운다
    /// — 이전 공유 state 가 탭 전환마다 전체 재구축하던 것과 같은 비용이다.
    render_state: ghostty.RenderState = .empty,
    output_ring: RingBuffer = .{},
    /// stress 하네스가 pane별 공정성을 직접 재는 누적값. `drainOutputChunk`를 호출하는
    /// UI thread 하나만 쓰고 하네스가 같은 thread에서 읽으므로 atomic이 필요 없다.
    stress_drain_chunks: u64 = 0,
    stress_drain_bytes: u64 = 0,
    /// #451 — `Io` 를 담아야 해서 기본값이 없다. `Tab.init` 이 `rt.io` 로 채운다.
    write_queue: WriteQueue,
    write_thread: ?std.Thread = null,
    tab_exit_fn: SessionCore.TabExitNotify,
    tab_exit_userdata: ?*anyopaque = null,
    /// #439 — PTY 출력이 ring 에 들어갔다는 것을 host 에 알린다 (유휴 깨우기).
    ///
    /// **read thread 에서 불린다** — 구현은 다른 스레드에서 불러도 되는 것만 써야 한다
    /// (`eventfd` write · `PostMessageW` · `CFRunLoopSourceSignal`).
    ///
    /// `null` 이면 알리지 않고, 그때는 host 의 프레임 타이머가 지금까지처럼 다음 주기에
    /// 집는다 — host 없이 도는 경로 (stress 하네스 · 단위 테스트) 의 정상 값이다.
    output_wake_fn: ?SessionCore.OutputWakeNotify = null,
    output_wake_userdata: ?*anyopaque = null,

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
            .rt = rt,
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
            .write_queue = .{ .io = rt.io },
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
            // #451 — `Stream.initAlloc(alloc, handler)` 가 `init(Options)` 하나로 합쳐졌다.
            // `allocator` 가 optional 이라, 넣으면 예전 `initAlloc` · 빼면 예전 `init` 이다.
            tab.stream = .init(.{ .handler = vt_handler, .allocator = alloc });
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
        tab.render_state.deinit(alloc);
        tab.terminal.deinit(alloc);
        alloc.destroy(tab);
    }

    /// #397 · #572 — 정상적인 측정 종료가 Tab 을 버리기 전에 ring 의 마지막
    /// payload 를 파싱한다. `closeTab` 과 다중 pane 의 `closePane`이 함께 부른다.
    /// 오류 정리와 SessionCore 자체 deinit 은 perf 스냅숏을 완성하는 경로가 아니므로
    /// 부르지 않는다 — producer 가 살아 있는 OOM 정리에서 출력을 기다리면 안 된다.
    fn finishStressOutput(tab: *Tab) void {
        if (!instance_context.isStress()) return;
        // drainOutputChunk 는 ring 이 비면 false 라 그 자체가 종료 조건이다. producer
        // PTY exit 통보 뒤에는 EOF 에 도달했으므로 새 payload 는 더 오지 않는다.
        while (tab.drainOutputChunk() > 0) {}
    }

    /// #483 — 이 탭이 화면에서 사라졌다. 스냅숏 메모리를 돌려주고 `.empty` 로 되돌린다.
    /// ghostty 의 pin 은 추적 pin 이 아니라 (render.zig: "NOT a tracked pin") 터미널과
    /// 무관하게 언제든 버릴 수 있다. 다음 `update` 가 전체를 다시 만든다.
    pub fn releaseRenderState(tab: *Tab, alloc: std.mem.Allocator) void {
        tab.render_state.deinit(alloc);
        tab.render_state = .empty;
    }

    pub fn queueWrite(tab: *Tab, data: []const u8) void {
        tab.write_queue.push(data);
    }

    /// #266 — ghostty-vt `Effects.write_pty`. 질의 응답 (DA1 / DSR / DECRQM
    /// 등) 을 PTY 로 송신. stream 파싱은 main thread 의 drainOutput 에서
    /// 일어나므로 blocking 가능한 backend.write 직접 호출 대신 키 입력과 같은
    /// write_queue 경로로 (순서 보존 + push 가 복사라 data lifetime 무관).
    ///
    /// #550 — 인자가 `[:0]const u8` 이었다가 upstream 이 `[]const u8` 로 바꿨다.
    /// 본문이 널 종단을 쓰지 않고 `queueWrite` 도 평범한 slice 를 받으므로 타입만
    /// 넓히면 되고 동작은 그대로다.
    fn vtWritePty(handler: *ghostty.TerminalStream.Handler, data: []const u8) void {
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
    fn drainOutputChunk(tab: *Tab) usize {
        const drain_t0 = perf.now();
        var buf: [65536]u8 = undefined;
        const n = tab.output_ring.pop(&buf);
        if (n == 0) return 0;

        const parse_t0 = perf.now();
        tab.stream.nextSlice(buf[0..n]);
        // #269 — Windows 는 #266 의 ConPTY 응답 누출을 막기 위해 effects 없는
        // readonly stream 을 유지한다. readonly 여도 OSC 0/2 는 Terminal.title
        // 에 저장되므로 parse 직후 공통 제목 상태만 읽어 동기화한다.
        if (comptime builtin.os.tag == .windows) tab.syncTerminalTitle();
        perf.addTimed(&perf.parse, parse_t0);
        perf.addTimedBytes(&perf.drain, drain_t0, @intCast(n));
        // 평소 앱의 hot path에는 측정용 누적 연산도 넣지 않는다.
        if (instance_context.isStress()) {
            tab.stress_drain_chunks += 1;
            tab.stress_drain_bytes += n;
        }
        return n;
    }

    fn writeLoop(tab: *Tab) void {
        var buf: [256]u8 = undefined;
        while (true) {
            // #451 — `Io.Event.wait` 은 취소점이라 `Cancelable!void` 다. 이 스레드는
            // 취소를 쓰지 않으므로 (종료는 `closed` flag + `set` 으로 깨운다) 취소점을
            // 만들지 않는 `waitUncancelable` 이 예전 `ResetEvent.wait` 과 같은 자리다.
            tab.write_queue.event.waitUncancelable(tab.write_queue.io);
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
        // #439 — 유휴 응답 지연의 시작점. 여기부터 present 까지가 *"출력이 화면에 닿는
        // 시간"* 이다. 한 byte 도 안 들어간 경우 (닫히는 중) 는 잴 것이 없다.
        if (wrote > 0) {
            perf.markOutput();
            // #439 — 유휴 host 를 깨운다. **계측과 분리해 둔다** — `perf` 는 진단이라
            // 언제든 빠질 수 있고, 기능 동작이 거기 매달리면 안 된다.
            //
            // 넣은 것이 없으면 (`wrote == 0`) 깨우지 않는다. ring 이 꽉 차 `push` 가
            // 기다리는 중이면 그건 유휴가 아니라 폭포라, host 는 이미 자기 주기로 돌며
            // 드레인하고 있다.
            if (tab.output_wake_fn) |wake| wake(tab.output_wake_userdata);
        }
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
        return tab.drainOutputChunk() > 0;
    }
};

/// 한 탭의 VT 상태를 앱 설정대로 만든다. `Tab.init` 과 stress 하네스 (#371) 가
/// **같은 정의**를 쓰도록 한 곳에 둔다 — 하네스가 이 구성을 베껴 쓰면 한쪽만
/// 바뀌었을 때 앱과 다른 파서 설정을 재게 되고, 그 차이는 숫자에 조용히 섞인다.
///
/// #451 — scrollback 은 이제 **줄 수로 직접** 건넨다. 예전에는 ghostty 가 byte 예산만
/// 받아서 우리 config 의 줄 수를 cols 에 따른 page 용량으로 환산했는데, upstream 이
/// `max_scrollback_lines` 를 추가해 그 환산이 필요 없어졌다.
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
        // #451 — 우리 config 의 `max_scroll_lines` 와 **단위가 같다** (물리 줄 수).
        // 예전의 page 용량 환산 (`page.std_capacity.adjust` + `Page.layout`) 은 ghostty 가
        // byte 예산만 받던 시절의 우회였고, 이제 그 계산이 통째로 사라졌다.
        .max_scrollback_lines = max_scroll_lines,
        // **byte 제한은 명시로 끈다.** `Terminal.Options.max_scrollback_bytes` 의 기본값이
        // `10_000` (10 KB) 이고, `PageList.Limits.exceeded` 는 bytes 와 lines 를 **독립적으로**
        // 판정해 각각 page 를 prune 한다 (`PageList.zig` 의 `Limits`). 그대로 두면 10 KB 에서
        // 먼저 잘려 줄 수 제한이 무의미해진다. `null` = 무제한이고, 상한은 줄 수가 정한다.
        .max_scrollback_bytes = null,
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

test "#451 ghostty pin answers DECRQSS and XTGETTCAP with grapheme mode enabled" {
    const rt = Runtime{ .io = std.testing.io, .environ = .empty };
    var term = try initVtTerminal(rt, std.testing.allocator, 80, 24, 10_000, null);
    defer term.deinit(std.testing.allocator);
    try std.testing.expect(term.modes.get(.grapheme_cluster));

    const Capture = struct {
        var response: [128]u8 = undefined;
        var len: usize = 0;
        var calls: usize = 0;

        fn reset() void {
            len = 0;
            calls = 0;
        }

        // #550 — upstream 이 `Effects.write_pty` 의 인자를 `[:0]const u8` 에서
        // `[]const u8` 로 바꿨다. 여기도 길이만 쓰므로 타입만 맞춘다.
        fn writePty(_: *ghostty.TerminalStream.Handler, data: []const u8) void {
            @memcpy(response[0..data.len], data);
            len = data.len;
            calls += 1;
        }

        fn expect(expected: []const u8) !void {
            try std.testing.expectEqual(@as(usize, 1), calls);
            try std.testing.expectEqualStrings(expected, response[0..len]);
            reset();
        }
    };
    Capture.reset();

    // 실제 Tab.init과 같은 effects stream이다. 여기서 응답이 나와야 Tab의
    // `vtWritePty`가 받은 바이트를 PTY write queue로 보낼 수 있다.
    var handler = term.vtHandler();
    handler.effects.write_pty = &Capture.writePty;
    var stream: ghostty.TerminalStream = .init(.{
        .handler = handler,
        .allocator = std.testing.allocator,
    });
    defer stream.deinit();

    stream.nextSlice("\x1b[1m\x1bP$qm\x1b\\");
    try Capture.expect("\x1bP1$r0;1m\x1b\\");

    // XTGETTCAP `Co` (hex 43 6F) → 256 (hex 32 35 36).
    stream.nextSlice("\x1bP+q436F\x1b\\");
    try Capture.expect("\x1bP1+r436F=323536\x1b\\");
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

const VisiblePaneMask = u16;

comptime {
    if (pane_layout.MAX_PANES_PER_TAB > @bitSizeOf(VisiblePaneMask))
        @compileError("VisiblePaneMask cannot represent every pane slot");
}

const VisibleDrainStep = union(enum) {
    pane: pane_layout.PaneId,
    hidden,
};

/// [#574](https://github.com/ensky0/tildaz/issues/574) — 활성 `TabGroup`의 pane을 한 번씩
/// 처리하는 논리 라운드. 4 ms `drainFrame` 호출이 라운드 중간에서 끝나도 `pending`과 다음
/// 위치를 보존하므로 다음 호출이 활성 pane부터 다시 시작하지 않는다.
const VisibleDrainRound = struct {
    const Phase = enum { visible, hidden };

    members: VisiblePaneMask = 0,
    pending: VisiblePaneMask = 0,
    next_index: usize = 0,
    phase: Phase = .visible,
    round_did_work: bool = false,
    /// 포커스만 바뀌었고 새 활성 pane이 이번 라운드 몫을 이미 썼을 때의 1회 우선권.
    /// `pending`은 그대로 두므로 사용자 동작이 남은 pane의 라운드를 폐기하지 않는다.
    focus_priority: ?pane_layout.PaneId = null,

    fn paneBit(id: pane_layout.PaneId) VisiblePaneMask {
        std.debug.assert(id < pane_layout.MAX_PANES_PER_TAB);
        return @as(VisiblePaneMask, 1) << @intCast(id);
    }

    fn reset(round: *VisibleDrainRound, members: VisiblePaneMask, active: pane_layout.PaneId) void {
        round.* = .{
            .members = members,
            .pending = members,
            .next_index = @intCast(active),
        };
    }

    fn ensure(round: *VisibleDrainRound, members: VisiblePaneMask, active: pane_layout.PaneId) void {
        if (round.members != members) round.reset(members, active);
    }

    /// 새 활성 pane을 남은 라운드 안에서 먼저 처리한다. 아직 `pending`이면 순서만 당기고,
    /// 이미 처리했으면 정확히 한 번의 우선권만 더한다.
    fn prioritize(round: *VisibleDrainRound, members: VisiblePaneMask, active: pane_layout.PaneId) void {
        round.ensure(members, active);
        if (round.pending & paneBit(active) != 0) {
            round.next_index = @intCast(active);
            round.focus_priority = null;
        } else {
            round.focus_priority = active;
        }
    }

    fn next(round: *VisibleDrainRound, members: VisiblePaneMask, active: pane_layout.PaneId) VisibleDrainStep {
        round.ensure(members, active);

        if (round.focus_priority) |id| {
            round.focus_priority = null;
            if (members & paneBit(id) != 0) return .{ .pane = id };
        }

        if (round.phase == .visible) {
            var scanned: usize = 0;
            while (scanned < pane_layout.MAX_PANES_PER_TAB) : (scanned += 1) {
                const i = (round.next_index + scanned) % pane_layout.MAX_PANES_PER_TAB;
                const id: pane_layout.PaneId = @intCast(i);
                const bit = paneBit(id);
                if (round.pending & bit == 0) continue;
                round.pending &= ~bit;
                round.next_index = (i + 1) % pane_layout.MAX_PANES_PER_TAB;
                return .{ .pane = id };
            }
            round.phase = .hidden;
        }
        return .hidden;
    }

    /// hidden 단계가 끝나면 라운드를 마치고 그 라운드에 실제 출력이 있었는지를 돌려준다.
    /// pane 단계면 아직 라운드 중이므로 null.
    fn complete(
        round: *VisibleDrainRound,
        step: VisibleDrainStep,
        did_work: bool,
        members: VisiblePaneMask,
        active: pane_layout.PaneId,
    ) ?bool {
        round.round_did_work = round.round_did_work or did_work;
        return switch (step) {
            .pane => null,
            .hidden => finished: {
                const result = round.round_did_work;
                round.reset(members, active);
                break :finished result;
            },
        };
    }
};

/// [#483](https://github.com/ensky0/tildaz/issues/483) 3단계 — 탭바의 탭 하나 = 화면 하나.
/// pane (`Tab`, 터미널 하나) 들을 분할 트리 (`pane_layout.Tree`) 로 배치한다. 지금은 항상
/// leaf 하나다 — 4단계가 `split` 을 부르기 전까지 host 가 보는 동작은 이전의 "탭 = 터미널
/// 하나" 와 같다.
///
/// `Tab` 이름은 그대로 둔다 (확정 설계 "pane = 지금의 Tab"). 이 파일에서 *pane* 이라고 적은
/// 것은 모두 `*Tab` 이다. 탭바 제목은 활성 pane 의 것이다.
pub const TabGroup = struct {
    /// leaf id 가 `panes` 의 index 다. host 가 아니라 이 struct 가 id 를 정한다.
    tree: pane_layout.Tree,
    panes: [pane_layout.MAX_PANES_PER_TAB]?*Tab = [_]?*Tab{null} ** pane_layout.MAX_PANES_PER_TAB,
    /// 키보드 · 붙여넣기 · 스크롤이 가는 pane. 탭바 제목도 이 pane 의 것이다.
    active_pane: pane_layout.PaneId = 0,
    /// #483 4c — 최대화된 pane. 있으면 `layout` 은 이 pane 하나가 영역 전체를 쓰고 다른 pane 은 그리지
    /// 않는다 (셸은 계속 돈다). 그 pane 이 닫히거나 pane 이 하나가 되면 풀린다 (`closePane`). 분할 ·
    /// 포커스 이동 · 크기 조절 · 균등은 먼저 푼다 (`unzoom`) — tmux 의 zoom 과 같은 규칙.
    zoomed: ?pane_layout.PaneId = null,
    /// #574 — 4 ms 호출 경계 밖까지 이어지는 활성 그룹 pane 드레인 라운드.
    visible_drain_round: VisibleDrainRound = .{},

    fn initSingle(alloc: std.mem.Allocator, tab: *Tab) !*TabGroup {
        const group = try alloc.create(TabGroup);
        group.* = .{ .tree = pane_layout.Tree.single(0) };
        group.panes[0] = tab;
        return group;
    }

    /// 그룹과 그 안의 pane 전부를 정리한다.
    fn deinit(group: *TabGroup, alloc: std.mem.Allocator) void {
        for (group.panes) |p| if (p) |tab| tab.deinit(alloc);
        alloc.destroy(group);
    }

    pub fn activeTab(group: *const TabGroup) *Tab {
        return group.panes[group.active_pane].?;
    }

    pub fn paneCount(group: *const TabGroup) usize {
        return group.tree.count();
    }

    fn drainMembers(group: *const TabGroup) VisiblePaneMask {
        var members: VisiblePaneMask = 0;
        for (group.panes, 0..) |pane, i| {
            if (pane != null) members |= VisibleDrainRound.paneBit(@intCast(i));
        }
        return members;
    }

    fn resetVisibleDrainRound(group: *TabGroup) void {
        group.visible_drain_round.reset(group.drainMembers(), group.active_pane);
    }

    fn prioritizeActiveDrain(group: *TabGroup) void {
        group.visible_drain_round.prioritize(group.drainMembers(), group.active_pane);
    }

    /// 이 그룹의 pane 배치 — 최대화 중이면 그 pane 하나가 `rect` 전체 (`pane_layout.leafRect`), 아니면
    /// 트리대로. host 와 `SessionCore` 의 모든 격자 · hit-test 가 이 함수를 거친다.
    pub fn layout(group: *const TabGroup, rect: pane_layout.Rect, m: pane_layout.Metrics, buf: *[pane_layout.MAX_PANES_PER_TAB]pane_layout.PaneRect) []pane_layout.PaneRect {
        if (group.zoomed) |z| {
            buf[0] = pane_layout.leafRect(z, rect, m);
            return buf[0..1];
        }
        return pane_layout.layout(&group.tree, rect, m, buf);
    }

    /// 회색 분할선 목록 — 최대화 중이면 없다.
    pub fn separators(group: *const TabGroup, rect: pane_layout.Rect, m: pane_layout.Metrics, buf: *[pane_layout.MAX_PANES_PER_TAB]pane_layout.Separator) []pane_layout.Separator {
        if (group.zoomed != null) return buf[0..0];
        return pane_layout.separators(&group.tree, rect, m, buf);
    }

    /// 최대화를 푼다. 풀 것이 있었으면 true — 호출처가 격자를 다시 맞춘다.
    fn unzoom(group: *TabGroup) bool {
        if (group.zoomed == null) return false;
        group.zoomed = null;
        return true;
    }

    /// `tab` 이 이 그룹의 pane 이면 그 id.
    fn paneIdOf(group: *const TabGroup, tab: *Tab) ?pane_layout.PaneId {
        for (group.panes, 0..) |p, i| {
            if (p == tab) return @intCast(i);
        }
        return null;
    }

    /// 비어 있는 pane 자리 — 새 pane 의 id. 꽉 찼으면 null (`MAX_PANES_PER_TAB`).
    fn freePaneId(group: *const TabGroup) ?pane_layout.PaneId {
        for (group.panes, 0..) |p, i| {
            if (p == null) return @intCast(i);
        }
        return null;
    }

    /// pane 하나를 닫는다 — 형제가 자리를 이어받고 포커스는 맞닿아 있던 pane 으로
    /// (`pane_layout.Tree.close`). **마지막 pane 은 닫지 않고 false** — 호출처가 그룹(탭)을
    /// 닫는다.
    fn closePane(group: *TabGroup, alloc: std.mem.Allocator, id: pane_layout.PaneId) bool {
        const next = group.tree.close(id) catch return false;
        if (group.panes[id]) |tab| {
            tab.finishStressOutput();
            tab.deinit(alloc);
        }
        group.panes[id] = null;
        if (group.active_pane == id) group.active_pane = next;
        // 최대화된 pane 이 닫혔거나 pane 이 하나만 남으면 최대화는 뜻이 없다.
        if (group.zoomed == id or group.paneCount() < 2) group.zoomed = null;
        group.resetVisibleDrainRound();
        return true;
    }
};

pub const SessionCore = struct {
    /// #451 — 탭 생성이 `Io` 를 타므로 (`ghostty.Terminal.init` · `WriteQueue`) 세션이
    /// 들고 있다가 `Tab.init` 에 넘긴다. host 의 `run(rt, …)` 에서 내려온 값이다.
    rt: Runtime,
    allocator: std.mem.Allocator,
    shell_command: terminal.ShellCommand,
    max_scroll_lines: usize,
    theme: ?*const themes.Theme,
    /// 자식 셸에 inject 할 환경변수 (TERM / LANG / SHELL 등). 모든 탭이 같은
    /// 값. lifetime 은 호출자 책임 (process lifetime static 권장).
    extra_env: ?[]const terminal.ExtraEnv,
    tab_exit_fn: TabExitNotify,
    tab_exit_userdata: ?*anyopaque,
    /// #439 — host 깨우기. `setOutputWake` 로 넣는다 (`init` 인자가 아니다 — Windows 의
    /// `HWND` 와 macOS 의 `CFRunLoopSource` 는 세션보다 **뒤에** 준비된다).
    output_wake_fn: ?OutputWakeNotify = null,
    output_wake_userdata: ?*anyopaque = null,
    /// #483 3단계 — 탭바의 탭 (화면) 목록. 각 탭은 pane (`Tab`) 들의 그룹이다.
    tabs: std.ArrayList(*TabGroup) = .empty,
    active_tab: usize = 0,
    /// 보이지 않는 (활성 그룹 밖의) pane drain 의 다음 시작 위치 — 그 pane 들을 화면 순서로
    /// 편 flat index. 탭 close/reorder 뒤에는 drain 시점에 현재 개수로 정규화하므로 별도
    /// 보정이 필요 없다.
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
    /// #439 — "PTY 출력이 ring 에 들어갔다" 는 host 통보. `Tab.output_wake_fn` 주석 참고.
    pub const OutputWakeNotify = *const fn (?*anyopaque) void;
    pub const CloseResult = enum {
        none,
        changed,
        closed_last,
    };

    pub fn init(
        rt: Runtime,
        allocator: std.mem.Allocator,
        shell_command: terminal.ShellCommand,
        max_scroll_lines: usize,
        theme: ?*const themes.Theme,
        extra_env: ?[]const terminal.ExtraEnv,
        tab_exit_fn: TabExitNotify,
        tab_exit_userdata: ?*anyopaque,
    ) SessionCore {
        return .{
            .rt = rt,
            .allocator = allocator,
            .shell_command = shell_command,
            .max_scroll_lines = max_scroll_lines,
            .theme = theme,
            .extra_env = extra_env,
            .tab_exit_fn = tab_exit_fn,
            .tab_exit_userdata = tab_exit_userdata,
        };
    }

    /// #439 — 유휴 깨우기 통보를 배선한다. host 가 자기 깨우기 장치를 만든 **뒤에**
    /// 부른다 (Windows `HWND` · macOS `CFRunLoopSource` 는 세션보다 뒤에 준비된다).
    ///
    /// 이미 만들어진 탭에도 전파한다 — 첫 탭은 보통 이 호출보다 먼저 생기는데, 거기만
    /// 통보가 없으면 *"첫 탭에서만 유휴 응답이 느린"* 조용한 비대칭이 된다.
    pub fn setOutputWake(self: *SessionCore, wake_fn: ?OutputWakeNotify, userdata: ?*anyopaque) void {
        self.output_wake_fn = wake_fn;
        self.output_wake_userdata = userdata;
        for (self.tabs.items) |group| {
            for (group.panes) |p| {
                const tab = p orelse continue;
                tab.output_wake_fn = wake_fn;
                tab.output_wake_userdata = userdata;
            }
        }
    }

    pub fn deinit(self: *SessionCore) void {
        for (self.tabs.items) |group| group.deinit(self.allocator);
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
        const tab = self.tabs.items[self.active_tab].activeTab();

        // 경로 표기는 **탭의 셸 기준** — WSL 탭은 host 가 Windows 여도 Linux 경로다.
        const wsl = terminal.isWslShell(self.shell_command);
        const style: pwd_uri.Style = if (builtin.os.tag == .windows and !wsl) .windows else .posix;

        // ① 셸이 OSC 7 로 알린 위치. 셸의 논리 경로 (`$PWD`) 라 symlink 를 따라 들어간
        //    사용자의 기대에 맞으므로 ② 보다 우선한다.
        if (tab.terminal.getPwd()) |payload| {
            var host_buf: [local_hostname.max_len]u8 = undefined;
            const hostname = local_hostname.get(&host_buf);
            if (pwd_uri.parse(payload, buf, .{ .hostname = hostname, .style = style })) |path| {
                if (usableDir(self.rt.io, path, wsl)) {
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
        if (process_cwd.ofPid(self.rt.io, tab.backend.childPid(), buf)) |path| {
            if (usableDir(self.rt.io, path, wsl)) {
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
    fn usableDir(io: std.Io, path: []const u8, wsl: bool) bool {
        if (builtin.os.tag == .windows and wsl) return true;
        // #451 — `fs.openDirAbsolute` ➡️ `std.Io.Dir.openDirAbsolute` · `close(io)`.
        var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
        dir.close(io);
        return true;
    }

    pub fn createTab(self: *SessionCore, cols: u16, rows: u16) !void {
        const tab = try self.spawnTab(cols, rows);
        errdefer tab.deinit(self.allocator);
        // #483 3단계 — 새 탭은 pane 하나짜리 그룹이다.
        const group = try TabGroup.initSingle(self.allocator, tab);
        errdefer self.allocator.destroy(group);
        try self.tabs.append(self.allocator, group);
        self.active_tab = self.tabs.items.len - 1;
        self.finishActiveGroupChange();
    }

    /// 터미널 하나 (pane) 를 만들어 셸을 띄운다 — 탭 (`createTab`) 과 분할 (`splitActive`) 의
    /// 공통 부분. 어느 그룹에도 넣지 않는다 — 호출처가 넣고, 넣지 못하면 `deinit` 한다.
    fn spawnTab(self: *SessionCore, cols: u16, rows: u16) !*Tab {
        var cwd_buf: [pwd_uri.max_path_len]u8 = undefined;
        const cwd = self.inheritedCwd(&cwd_buf);

        const tab = try Tab.init(
            self.rt,
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
        // #439 — read thread 가 돌기 **전에** 배선한다. 이 뒤에 대입하면 첫 바이트가
        // 통보 없이 지나갈 수 있다.
        tab.output_wake_fn = self.output_wake_fn;
        tab.output_wake_userdata = self.output_wake_userdata;
        try tab.backend.startReadThread(Tab.onPtyOutput, Tab.onPtyExit, tab);
        return tab;
    }

    pub fn closeTab(self: *SessionCore, index: usize) CloseResult {
        if (index >= self.tabs.items.len) return .none;

        const remaining_len = self.tabs.items.len - 1;
        const next_active = nextActiveIndexAfterClose(self.active_tab, index, remaining_len);
        const group = self.tabs.orderedRemove(index);
        // #397 — 그룹 전체를 닫는 기존 측정 종료 보장. 실제 drain 로직은 #572 에서
        // closePane 과 공유하도록 Tab.finishStressOutput 으로 모았다.
        for (group.panes) |p| if (p) |tab| tab.finishStressOutput();
        defer group.deinit(self.allocator);

        if (next_active) |active| {
            self.active_tab = active;
            self.finishActiveGroupChange();
            return .changed;
        }
        self.active_tab = 0;
        return .closed_last;
    }

    /// pane 의 PTY 가 끝났을 때 (`tab_exit_fn`) — 그 pane 을 찾아 닫는다. #483 3단계 — 그룹에
    /// pane 이 둘 이상이면 그 pane 만 (형제가 자리를 이어받음), 하나면 그룹(탭) 을 닫는다.
    /// 확정 설계 §② 의 "pane 이 여럿이면 활성 pane, 마지막 하나면 탭" 과 같은 규칙이다.
    pub fn closeTabByPtr(self: *SessionCore, tab_ptr: usize) CloseResult {
        const needle: *Tab = @ptrFromInt(tab_ptr);
        for (self.tabs.items, 0..) |group, i| {
            const id = group.paneIdOf(needle) orelse continue;
            if (group.paneCount() > 1 and group.closePane(self.allocator, id)) return .changed;
            return self.closeTab(i);
        }
        return .none;
    }

    /// #483 4a — 활성 pane 을 `dir` 쪽으로 갈라 새 pane (새 셸) 을 그쪽에 놓고 활성으로
    /// 한다. `rect` 는 탭바를 뺀 터미널 영역, `m` 은 host 의 격자 metrics — 트리가 최소
    /// 크기를 판정하고 (`pane_layout.Tree.split`) 새 pane 의 첫 격자를 정하는 데 쓴다.
    /// 성공하면 그룹의 pane 전부를 새 격자로 맞춘다 (`applyGroupLayout`).
    ///
    /// 거부 — `error.TooSmall` (최소 크기 아래) · `error.TooManyPanes` (`MAX_PANES_PER_TAB`)
    /// · `error.NoActiveTab`. host 가 셋을 다른 문구로 안내한다 (확정 설계 §② "거부 +
    /// 안내"). 셸을 띄우지 못하면 트리를 원복하고 그 오류를 그대로 낸다.
    pub fn splitActive(self: *SessionCore, dir: pane_layout.Direction, rect: pane_layout.Rect, m: pane_layout.Metrics) !void {
        const group = self.activeGroup() orelse return error.NoActiveTab;
        const new_id = group.freePaneId() orelse return error.TooManyPanes;
        _ = group.unzoom();
        group.tree.split(group.active_pane, dir, new_id, rect, m) catch |e| switch (e) {
            error.TooManyPanes, error.TooSmall => |narrow| return narrow,
            // `active_pane` 은 늘 트리에 있고 `new_id` 는 빈 자리다 — 둘 다 불변식 위반.
            error.UnknownPane, error.DuplicatePane => unreachable,
        };
        // `close` 는 형제를 부모 자리에 되돌리므로 갈라지기 전 모양이 된다.
        errdefer _ = group.tree.close(new_id) catch unreachable;
        var buf: [pane_layout.MAX_PANES_PER_TAB]pane_layout.PaneRect = undefined;
        const lay = group.layout(rect, m, &buf);
        const pr = pane_layout.find(lay, new_id) orelse unreachable;
        const tab = try self.spawnTab(pr.cols, pr.rows);
        group.panes[new_id] = tab;
        group.active_pane = new_id;
        group.resetVisibleDrainRound();
        self.applyGroupLayout(group, lay);
    }

    /// 활성 pane 을 닫는다 — 그룹에 pane 이 둘 이상이면 그 pane 만 (형제가 자리를 이어받고
    /// 포커스는 맞닿아 있던 pane 으로), 마지막 하나면 탭을 닫는다. `closeTabByPtr` 의 PTY
    /// 종료 경로와 같은 규칙이라, 셸에 `exit` 를 치는 것과 결과가 같다. 남은 pane 의 격자는
    /// host 가 `applyLayouts` 로 맞춘다 — 창 크기와 metrics 는 host 가 안다.
    ///
    /// #544 — 이것을 부르는 것은 액션 `close_pane` (`Ctrl+Shift+X` / `Shift+Cmd+X`) 뿐이다.
    /// `close_tab` 과 마우스 `×` · `⋯` 메뉴는 `closeTab` 으로 **탭 통째로** 닫는다. #483 이
    /// 잠깐 그 둘을 이 함수로 보냈는데, 액션 이름 · 라벨 · SPEC 이 모두 "탭" 이라 되돌렸다.
    pub fn closeActivePane(self: *SessionCore) CloseResult {
        const group = self.activeGroup() orelse return .none;
        if (group.paneCount() > 1 and group.closePane(self.allocator, group.active_pane)) return .changed;
        return self.closeTab(self.active_tab);
    }

    /// 포커스를 `dir` 쪽 이웃 pane 으로 (확정 설계 축 3 — 기하 기반, `pane_layout.neighbor`).
    /// 광선의 위치는 활성 pane 커서의 화면 px — 좌우 이동이면 y, 상하면 x. 이웃이 없으면
    /// (그쪽이 창 가장자리) false 고 바뀌는 것이 없다.
    pub fn focusPane(self: *SessionCore, dir: pane_layout.Direction, rect: pane_layout.Rect, m: pane_layout.Metrics) bool {
        const group = self.activeGroup() orelse return false;
        if (group.paneCount() < 2) return false;
        // 최대화 중이면 먼저 푼다 — 이웃은 펼친 배치에서 찾는다. 이웃이 없어도 푼 것은 변화다.
        const was_zoomed = group.unzoom();
        var buf: [pane_layout.MAX_PANES_PER_TAB]pane_layout.PaneRect = undefined;
        const lay = group.layout(rect, m, &buf);
        const anchor = cursorAnchor(group, lay, dir, m);
        group.active_pane = pane_layout.neighbor(lay, group.active_pane, dir, anchor) orelse return was_zoomed;
        group.prioritizeActiveDrain();
        return true;
    }

    /// 활성 pane 의 커서 셀 중심의 화면 px — `dir` 의 교차 축 (좌우면 y, 상하면 x). 커서는
    /// `render_state` 의 마지막 프레임 값이다 — 한 프레임 늦을 수 있지만 이웃을 고르는 데는
    /// 충분하다. 아직 한 번도 그리지 않았으면 null → `neighbor` 가 변의 중점을 쓴다.
    fn cursorAnchor(group: *const TabGroup, lay: []const pane_layout.PaneRect, dir: pane_layout.Direction, m: pane_layout.Metrics) ?i32 {
        const pr = pane_layout.find(lay, group.active_pane) orelse return null;
        const vp = group.activeTab().render_state.cursor.viewport orelse return null;
        return switch (dir.axis()) {
            .side_by_side => pr.grid_y + @as(i32, vp.y) * m.cell_h + @divTrunc(m.cell_h, 2),
            .stacked => pr.grid_x + @as(i32, vp.x) * m.cell_w + @divTrunc(m.cell_w, 2),
        };
    }

    /// 활성 pane 에 닿은 분할선을 `dir` 쪽으로 `cells` 셀 옮긴다 (`pane_layout.Tree.resize`
    /// 가 어느 분할선인지 정한다). 옮길 분할선이 없거나 최소 크기 아래로 내려가는 pane 이
    /// 생기면 false 고 바뀌는 것이 없다.
    pub fn resizeActivePane(self: *SessionCore, dir: pane_layout.Direction, cells: i32, rect: pane_layout.Rect, m: pane_layout.Metrics) bool {
        const group = self.activeGroup() orelse return false;
        var buf: [pane_layout.MAX_PANES_PER_TAB]pane_layout.PaneRect = undefined;
        // 최대화 중이면 첫 조작은 푸는 것으로 끝난다.
        if (group.unzoom()) {
            self.applyGroupLayout(group, group.layout(rect, m, &buf));
            return true;
        }
        if (!group.tree.resize(group.active_pane, dir, cells, rect, m)) return false;
        self.applyGroupLayout(group, group.layout(rect, m, &buf));
        return true;
    }

    /// 활성 탭의 분할 비율을 양쪽 leaf 수에 비례시켜 pane 마다 넓이가 같아지게 (확정 설계 §②
    /// `equalize`, `pane_layout.Tree.equalize` — 같은 축의 분할은 한 줄로 보고 칸 수로 나눔, tmux · iTerm2 의 n-ary
    /// 분할 "고르게" 와 같은 결과).
    pub fn equalizeActive(self: *SessionCore, rect: pane_layout.Rect, m: pane_layout.Metrics) void {
        const group = self.activeGroup() orelse return;
        _ = group.unzoom();
        group.tree.equalize(rect, m);
        var buf: [pane_layout.MAX_PANES_PER_TAB]pane_layout.PaneRect = undefined;
        self.applyGroupLayout(group, group.layout(rect, m, &buf));
    }

    /// #483 4c — 활성 pane 최대화 토글 (`zoom_pane`). pane 이 하나면 할 일이 없어 false. 바뀌었으면 true —
    /// 호출처가 `applyLayouts` 로 격자를 맞춘다 (켜면 그 pane 이 전체 격자, 풀면 모두 원래 격자).
    pub fn toggleZoomActive(self: *SessionCore) bool {
        const group = self.activeGroup() orelse return false;
        if (group.unzoom()) return true;
        if (group.paneCount() < 2) return false;
        group.zoomed = group.active_pane;
        return true;
    }

    /// #483 4c — 분할선 드래그를 놓았을 때: 분할 노드 `node` (`Separator.node`) 의 분할선을 `px` 에
    /// (`pane_layout.Tree.setSeparatorPx`) 놓고 그룹 격자를 한 번 맞춘다.
    ///
    /// **놓인 자리** (clamp · 셀 스냅 뒤의 절대 px) 를 돌려주고, 바뀐 것이 없으면 `null` 이다. host 의 로그가
    /// 인자가 아니라 이 값을 적는다 (`Tree.setSeparatorPx` 주석의 근거).
    pub fn setSeparatorPx(self: *SessionCore, node: u8, px: i32, rect: pane_layout.Rect, m: pane_layout.Metrics) ?i32 {
        const group = self.activeGroup() orelse return null;
        const placed = group.tree.setSeparatorPx(node, px, rect, m) orelse return null;
        var buf: [pane_layout.MAX_PANES_PER_TAB]pane_layout.PaneRect = undefined;
        self.applyGroupLayout(group, group.layout(rect, m, &buf));
        return placed;
    }

    /// #483 4b — 픽셀 아래의 pane (`pane_layout.paneAt`, 마우스 클릭 포커스). 분할선 위 · 영역 밖 ·
    /// 탭 없음이면 null.
    pub fn paneIdAt(self: *SessionCore, px: i32, py: i32, rect: pane_layout.Rect, m: pane_layout.Metrics) ?pane_layout.PaneId {
        const group = self.activeGroup() orelse return null;
        var buf: [pane_layout.MAX_PANES_PER_TAB]pane_layout.PaneRect = undefined;
        return pane_layout.paneAt(group.layout(rect, m, &buf), px, py);
    }

    /// pane `id` 를 활성으로. 그 pane 이 없거나 이미 활성이면 false 고 바뀌는 것이 없다.
    pub fn setActivePane(self: *SessionCore, id: pane_layout.PaneId) bool {
        const group = self.activeGroup() orelse return false;
        if (id >= group.panes.len or group.panes[id] == null or group.active_pane == id) return false;
        group.active_pane = id;
        group.prioritizeActiveDrain();
        return true;
    }

    /// 모든 탭의 pane 격자를 `rect` · `m` 의 layout 에 맞춘다 — 창 크기 · 폰트가 바뀌었을 때,
    /// 그리고 pane 을 닫은 뒤. `resizeAll(cols, rows)` 를 대신한다 — pane 마다 격자가 다르므로
    /// host 가 격자 하나를 주는 대신 영역과 metrics 를 준다.
    pub fn applyLayouts(self: *SessionCore, rect: pane_layout.Rect, m: pane_layout.Metrics) void {
        var buf: [pane_layout.MAX_PANES_PER_TAB]pane_layout.PaneRect = undefined;
        for (self.tabs.items) |group| {
            self.applyGroupLayout(group, group.layout(rect, m, &buf));
        }
    }

    /// 그룹의 pane 들을 layout 결과의 격자로 resize 한다. 이미 그 격자인 pane 은 건너뛴다 —
    /// 분할 · 크기 조절 뒤에는 대개 일부 pane 만 바뀐다.
    fn applyGroupLayout(self: *SessionCore, group: *TabGroup, lay: []const pane_layout.PaneRect) void {
        for (lay) |pr| {
            const tab = group.panes[pr.pane] orelse continue;
            if (tab.terminal.cols == pr.cols and tab.terminal.rows == pr.rows) continue;
            // #451 — `Terminal.resize` 가 `Resize` 구조체를 받는다 (cell_size_px 가 추가됐다).
            tab.terminal.resize(self.allocator, .{ .cols = pr.cols, .rows = pr.rows }) catch {};
            tab.backend.resize(pr.cols, pr.rows) catch {};
        }
    }

    /// 탭바 순서의 탭 (그룹) 목록. 제목은 `group.activeTab().title`.
    pub fn tabsSlice(self: *SessionCore) []*TabGroup {
        return self.tabs.items;
    }

    pub fn count(self: *const SessionCore) usize {
        return self.tabs.items.len;
    }

    /// #483 — 모든 탭의 pane 을 합한 수 = 지금 살아 있는 셸 수. 종료 확인이 "몇 개가 사라지는가" 를
    /// 정확히 적으려면 탭 수 (`count`) 로는 모자란다 — 탭 하나가 pane 을 16 개까지 담는다.
    pub fn totalPaneCount(self: *const SessionCore) usize {
        var n: usize = 0;
        for (self.tabs.items) |group| n += group.paneCount();
        return n;
    }

    pub fn activeIndex(self: *const SessionCore) usize {
        return self.active_tab;
    }

    /// index 번째 탭의 **활성 pane**. #483 3단계 — 탭은 pane 그룹이라 "그 탭의 터미널" 은
    /// 활성 pane 을 뜻한다.
    pub fn tabAt(self: *SessionCore, index: usize) ?*Tab {
        if (index < self.tabs.items.len) return self.tabs.items[index].activeTab();
        return null;
    }

    pub fn activeGroup(self: *SessionCore) ?*TabGroup {
        if (self.active_tab < self.tabs.items.len) return self.tabs.items[self.active_tab];
        return null;
    }

    /// 활성 탭의 활성 pane — 키보드 · 붙여넣기 · 스크롤이 가는 터미널.
    pub fn activeTab(self: *SessionCore) ?*Tab {
        return self.tabAt(self.active_tab);
    }

    pub fn setActiveTab(self: *SessionCore, index: usize) bool {
        if (index >= self.tabs.items.len or index == self.active_tab) return false;
        self.active_tab = index;
        self.finishActiveGroupChange();
        return true;
    }

    /// 다음 탭 (마지막이면 0 으로 wrap). 탭이 1 개 이하면 false. Ctrl+Tab
    /// 핸들러용 (#125).
    pub fn activateNext(self: *SessionCore) bool {
        if (self.tabs.items.len <= 1) return false;
        self.active_tab = (self.active_tab + 1) % self.tabs.items.len;
        self.finishActiveGroupChange();
        return true;
    }

    /// 이전 탭 (0 이면 마지막으로 wrap). 탭이 1 개 이하면 false.
    pub fn activatePrev(self: *SessionCore) bool {
        if (self.tabs.items.len <= 1) return false;
        self.active_tab = if (self.active_tab == 0) self.tabs.items.len - 1 else self.active_tab - 1;
        self.finishActiveGroupChange();
        return true;
    }

    /// 활성 그룹이 바뀐 뒤 새 그룹은 활성 pane에서 논리 라운드를 시작하고, 다른 그룹의
    /// 렌더 스냅숏은 비운다. 활성 탭을 바꾸는 모든 진입점이 이 한 함수를 쓴다.
    fn finishActiveGroupChange(self: *SessionCore) void {
        if (self.activeGroup()) |group| group.resetVisibleDrainRound();
        self.releaseHiddenRenderStates();
    }

    /// #483 2단계 ① · 3단계 — 활성 그룹에 없는 (보이지 않는) pane 의 렌더 스냅숏을 비운다
    /// (`Tab.render_state` 주석). 활성 탭이 바뀌는 모든 자리에서 부른다. 활성 그룹의 pane 은
    /// 전부 보이는 것이라 남긴다.
    fn releaseHiddenRenderStates(self: *SessionCore) void {
        for (self.tabs.items, 0..) |group, i| {
            if (i == self.active_tab) continue;
            for (group.panes) |p| {
                const tab = p orelse continue;
                if (tab.render_state.row_data.len == 0 and tab.render_state.pending_styles.items.len == 0) continue;
                tab.releaseRenderState(self.allocator);
            }
        }
    }

    pub fn reorderTabs(self: *SessionCore, from: usize, to: usize) !bool {
        if (from >= self.tabs.items.len or to >= self.tabs.items.len or from == to) return false;

        const active_group = self.activeGroup();
        const moved = self.tabs.orderedRemove(from);
        try self.tabs.insert(self.allocator, to, moved);

        if (active_group) |active| {
            for (self.tabs.items, 0..) |group, i| {
                if (group == active) {
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

    /// 모든 pane 을 같은 격자로. #483 — host 배선이 `applyLayouts` 로 넘어가면 (Linux 4b ·
    /// macOS · Windows 5단계) 지운다. 그때까지는 분할이 일어나지 않으므로 둘의 결과가 같다.
    pub fn resizeAll(self: *SessionCore, cols: u16, rows: u16) void {
        for (self.tabs.items) |group| {
            for (group.panes) |p| {
                const tab = p orelse continue;
                // #451 — `Terminal.resize` 가 `Resize` 구조체를 받는다 (cell_size_px 가 추가됐다).
                tab.terminal.resize(self.allocator, .{ .cols = cols, .rows = rows }) catch {};
                tab.backend.resize(cols, rows) catch {};
            }
        }
    }

    pub fn scrollActive(self: *SessionCore, event: app_event.ScrollEvent, visible_rows: u16) bool {
        const tab = self.activeTab() orelse return false;
        scrollTab(tab, event, visible_rows);
        return true;
    }

    /// #483 6단계 — 픽셀 아래의 pane (`Tab`). 분할선 위 · 영역 밖 · 탭 없음이면 null. 휠의 대상이다 — 결정 B:
    /// **포인터 아래 pane 을 스크롤하고 포커스는 바꾸지 않는다** (키보드 pane 은 그대로, 눈으로 보는 pane 을 넘긴다).
    /// 페이지 키 (Shift+PgUp/PgDn) 는 키라 `scrollActive` 로 활성 pane 을 간다.
    pub fn paneTabAt(self: *SessionCore, px: i32, py: i32, rect: pane_layout.Rect, m: pane_layout.Metrics) ?*Tab {
        const group = self.activeGroup() orelse return null;
        const id = self.paneIdAt(px, py, rect, m) orelse return null;
        return group.panes[id];
    }

    /// `tab` 의 viewport 를 스크롤한다. `visible_rows` 는 그 pane 의 행 수 (페이지 단위).
    pub fn scrollTab(tab: *Tab, event: app_event.ScrollEvent, visible_rows: u16) void {
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
            .wheel => |raw| @divTrunc(@as(isize, raw.delta), 40),
        };
        tab.terminal.scrollViewport(.{ .delta = -delta });
    }

    pub fn resetActive(self: *SessionCore) bool {
        const tab = self.activeTab() orelse return false;
        tab.terminal.fullReset();
        tab.queueWrite("\x0c");
        return true;
    }

    /// 보이지 않는 pane (활성 그룹 밖) 을 화면 순서로 편 flat index 와 함께 도는 iterator.
    const HiddenPaneIter = struct {
        session: *SessionCore,
        group: usize = 0,
        pane: usize = 0,
        flat: usize = 0,

        fn next(it: *HiddenPaneIter) ?struct { tab: *Tab, flat: usize } {
            while (it.group < it.session.tabs.items.len) {
                if (it.group == it.session.active_tab) {
                    it.group += 1;
                    it.pane = 0;
                    continue;
                }
                const group = it.session.tabs.items[it.group];
                while (it.pane < group.panes.len) {
                    const p = group.panes[it.pane];
                    it.pane += 1;
                    if (p) |tab| {
                        const flat = it.flat;
                        it.flat += 1;
                        return .{ .tab = tab, .flat = flat };
                    }
                }
                it.group += 1;
                it.pane = 0;
            }
            return null;
        }
    };

    fn hiddenPaneCount(self: *SessionCore) usize {
        var n: usize = 0;
        for (self.tabs.items, 0..) |group, i| {
            if (i == self.active_tab) continue;
            n += group.paneCount();
        }
        return n;
    }

    /// round-robin cursor 에서 시작해 출력이 있는 **보이지 않는 pane** 하나를 한 chunk 처리한다.
    /// 빈 pane 은 건너뛰고, 성공하면 다음 호출이 그 다음 pane 부터 찾도록 전진한다. #483 3단계 —
    /// 그룹마다 pane 이 하나면 이전의 "비활성 탭 라운드로빈" 과 같다.
    fn drainNextInactiveChunk(self: *SessionCore) bool {
        const total = self.hiddenPaneCount();
        if (total == 0) return false;

        const start = self.inactive_drain_cursor % total;
        // 두 바퀴 — start 부터 끝까지, 그다음 처음부터 start 앞까지 (원형 순회).
        var pass: u8 = 0;
        while (pass < 2) : (pass += 1) {
            var it = HiddenPaneIter{ .session = self };
            while (it.next()) |e| {
                const in_range = if (pass == 0) e.flat >= start else e.flat < start;
                if (!in_range) continue;
                if (e.tab.output_ring.isEmpty()) continue;
                self.inactive_drain_cursor = (e.flat + 1) % total;
                return e.tab.drainOutputChunk() > 0;
            }
        }
        self.inactive_drain_cursor = (start + 1) % total;
        return false;
    }

    /// 활성 `TabGroup`의 pane을 논리 라운드당 한 chunk씩 처리한 뒤 숨은 pane 하나를 처리한다.
    /// 라운드는 `drainFrame` 호출 경계를 넘어 이어지고, 활성 pane은 **매 호출**이 아니라 **매
    /// 논리 라운드**의 첫 순서다. 모든 탭은 하나의 `DRAIN_FRAME_BUDGET_NS` 예산을 공유한다.
    fn drainFrame(self: *SessionCore) DrainFrameResult {
        const group = self.activeGroup() orelse return .{};
        const active = group.activeTab();
        const started_ns = active.title_clock.read();
        var result: DrainFrameResult = .{};
        const members = group.drainMembers();

        while (active.title_clock.read() - started_ns < DRAIN_FRAME_BUDGET_NS) {
            // #574 — pane 사이에서 예산이 끝나도 `next`가 pending 위치를 보존한다. 마지막
            // 활성 그룹 pane 뒤에서 끝나면 hidden 단계 역시 다음 호출로 이월된다.
            const step = group.visible_drain_round.next(members, group.active_pane);
            const did_work = switch (step) {
                .pane => |id| pane: {
                    const tab = group.panes[id] orelse break :pane false;
                    const drained = tab.drainOutputChunk() > 0;
                    result.active_output = result.active_output or drained;
                    break :pane drained;
                },
                .hidden => self.drainNextInactiveChunk(),
            };
            const completed_round = group.visible_drain_round.complete(
                step,
                did_work,
                members,
                group.active_pane,
            );

            if (active.title_clock.read() - started_ns >= DRAIN_FRAME_BUDGET_NS) break;
            if (completed_round != null and !completed_round.?) break;
        }

        for (group.panes) |p| {
            const tab = p orelse continue;
            if (!tab.output_ring.isEmpty()) result.active_output_pending = true;
        }
        for (self.tabs.items) |g| {
            for (g.panes) |p| {
                const tab = p orelse continue;
                result.title_changed = tab.flushPendingTitle() or result.title_changed;
            }
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
        for (self.tabs.items) |group| {
            for (group.panes) |p| {
                const tab = p orelse continue;
                if (!tab.output_ring.isEmpty()) return true;
            }
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

fn expectVisibleDrainPane(step: VisibleDrainStep, expected: pane_layout.PaneId) !void {
    switch (step) {
        .pane => |actual| try std.testing.expectEqual(expected, actual),
        .hidden => try std.testing.expect(false),
    }
}

fn takeVisibleDrainPane(
    round: *VisibleDrainRound,
    members: VisiblePaneMask,
    active: pane_layout.PaneId,
    expected: pane_layout.PaneId,
    did_work: bool,
) !void {
    const step = round.next(members, active);
    try expectVisibleDrainPane(step, expected);
    try std.testing.expectEqual(@as(?bool, null), round.complete(step, did_work, members, active));
}

fn finishVisibleDrainRound(
    round: *VisibleDrainRound,
    members: VisiblePaneMask,
    active: pane_layout.PaneId,
    hidden_did_work: bool,
) !bool {
    const step = round.next(members, active);
    switch (step) {
        .pane => try std.testing.expect(false),
        .hidden => {},
    }
    return round.complete(step, hidden_did_work, members, active).?;
}

test "#574 — 논리 드레인 라운드는 호출 경계를 넘어 이어진다" {
    const members: VisiblePaneMask = 0b1111;
    var round: VisibleDrainRound = .{};

    // 각 줄 사이가 4 ms 호출 경계라고 해도 A를 다시 넣지 않고 A, B | C, D로 이어진다.
    try takeVisibleDrainPane(&round, members, 0, 0, true);
    try takeVisibleDrainPane(&round, members, 0, 1, true);

    try takeVisibleDrainPane(&round, members, 0, 2, true);
    try takeVisibleDrainPane(&round, members, 0, 3, true);

    // 마지막 pane 직후 호출이 끝나도 hidden 차례가 사라지지 않는다.
    try std.testing.expect(try finishVisibleDrainRound(&round, members, 0, false));
    try takeVisibleDrainPane(&round, members, 0, 0, true);
}

test "#574 — 한 청크가 예산을 다 써도 두 pane이 번갈아 진행한다" {
    const members: VisiblePaneMask = 0b11;
    var round: VisibleDrainRound = .{};

    // 호출마다 한 단계만 실행하는 최악 조건: A | B | hidden, 그다음 라운드의 A.
    try takeVisibleDrainPane(&round, members, 0, 0, true);
    try takeVisibleDrainPane(&round, members, 0, 1, true);
    try std.testing.expect(try finishVisibleDrainRound(&round, members, 0, false));
    try takeVisibleDrainPane(&round, members, 0, 0, true);
}

test "#574 — 빈 slot과 포커스 우선권이 남은 라운드를 폐기하지 않는다" {
    const members = VisibleDrainRound.paneBit(0) |
        VisibleDrainRound.paneBit(2) |
        VisibleDrainRound.paneBit(5);
    var round: VisibleDrainRound = .{};

    try takeVisibleDrainPane(&round, members, 2, 2, true);
    // 아직 pending인 pane 0은 다음으로 당긴다.
    round.prioritize(members, 0);
    try takeVisibleDrainPane(&round, members, 0, 0, true);
    // 이미 처리한 pane 2는 한 번만 우선하고, pending pane 5는 그대로 남는다.
    round.prioritize(members, 2);
    try takeVisibleDrainPane(&round, members, 2, 2, true);
    try takeVisibleDrainPane(&round, members, 2, 5, true);
    try std.testing.expect(try finishVisibleDrainRound(&round, members, 2, false));
}

test "#574 — pane 구성 변경은 새 활성 pane에서 라운드를 다시 만든다" {
    var round: VisibleDrainRound = .{};
    try takeVisibleDrainPane(&round, 0b111, 0, 0, true);

    // pane 0이 닫히고 pane 1이 활성이 된 상태. 옛 pending을 이어 pane 1을 건너뛰지 않는다.
    try takeVisibleDrainPane(&round, 0b110, 1, 1, true);
    try takeVisibleDrainPane(&round, 0b110, 1, 2, true);
    try std.testing.expect(try finishVisibleDrainRound(&round, 0b110, 1, false));
}

test "#574 — 16 pane 라운드도 각 slot을 정확히 한 번 처리한다" {
    const members = std.math.maxInt(VisiblePaneMask);
    var round: VisibleDrainRound = .{};

    try takeVisibleDrainPane(&round, members, 15, 15, true);
    for (0..15) |i| {
        try takeVisibleDrainPane(&round, members, 15, @intCast(i), true);
    }
    try std.testing.expect(try finishVisibleDrainRound(&round, members, 15, false));
}

test "#574 — 출력이 없는 완전한 라운드는 유휴로 끝난다" {
    const members: VisiblePaneMask = 0b11;
    var round: VisibleDrainRound = .{};
    try takeVisibleDrainPane(&round, members, 0, 0, false);
    try takeVisibleDrainPane(&round, members, 0, 1, false);
    try std.testing.expect(!try finishVisibleDrainRound(&round, members, 0, false));
}

test "OSC 0 and 2 update automatic tab title and empty title restores default" {
    var terminal_state = try ghostty.Terminal.init(std.testing.io, std.testing.allocator, .{
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

/// #451 — 테스트는 `std.testing.io` 를 쓰고 환경변수는 안 본다 (세션은 셸 경로를
/// 인자로 받는다). 값이 고정되니 기계마다 결과가 갈리지도 않는다.
fn testRuntime() Runtime {
    return .{ .io = std.testing.io, .environ = .empty };
}

fn expectStressCloseDrainsUnreadPane(session: *SessionCore) !void {
    const m: pane_layout.Metrics = .{ .cell_w = 19, .cell_h = 39, .pad = 12, .scrollbar_w = 20, .separator_w = 2 };
    const rect: pane_layout.Rect = .{ .x = 0, .y = 0, .w = 3052, .h = 1000 };
    try session.splitActive(.right, rect, m);
    const closing = session.activeTab().?;

    // PTY read thread 의 timing 에 기대지 않고, 닫는 순간 반드시 unread 인 marker 를
    // target pane 의 ring 에 직접 둔다. closeTabByPtr 은 stress actual-app 에서 producer
    // 종료 통보가 타는 바로 그 경로다.
    const marker = "\x1b]0;close-pane-drain-regression\x07";
    try std.testing.expectEqual(marker.len, closing.output_ring.push(marker));
    try std.testing.expect(!closing.output_ring.isEmpty());
    _ = perf.snapshot(&perf.drain);
    defer _ = perf.snapshot(&perf.drain);

    const previous_role = instance_context.currentRole();
    instance_context.setRole(.stress);
    defer instance_context.setRole(previous_role);

    try std.testing.expectEqual(
        SessionCore.CloseResult.changed,
        session.closeTabByPtr(@intFromPtr(closing)),
    );
    try std.testing.expectEqual(@as(usize, 1), session.activeGroup().?.paneCount());
    const drained = perf.snapshot(&perf.drain);
    try std.testing.expect(drained[2] >= marker.len);
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
        testRuntime(),
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
        testRuntime().sleepNs(10 * std.time.ns_per_ms);
    }
}

test "POSIX: #483 3단계 — 탭은 pane 그룹이고 leaf 하나면 이전과 같다" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const Exit = struct {
        fn notify(_: usize, _: ?*anyopaque) void {}
    };
    var session = SessionCore.init(
        testRuntime(),
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
    try session.createTab(80, 24);
    try std.testing.expectEqual(@as(usize, 2), session.count());
    try std.testing.expectEqual(@as(usize, 1), session.activeIndex());
    for (session.tabsSlice()) |group| {
        try std.testing.expectEqual(@as(usize, 1), group.paneCount());
        try std.testing.expectEqual(@as(pane_layout.PaneId, 0), group.active_pane);
    }
    // 활성 탭 = 활성 그룹의 활성 pane.
    const active = session.activeTab().?;
    try std.testing.expectEqual(active, session.activeGroup().?.activeTab());
    try std.testing.expectEqual(active, session.tabAt(1).?);

    // PTY 종료 경로 — leaf 하나인 그룹의 pane 이 끝나면 그룹(탭) 이 닫힌다.
    try std.testing.expectEqual(SessionCore.CloseResult.changed, session.closeTabByPtr(@intFromPtr(active)));
    try std.testing.expectEqual(@as(usize, 1), session.count());
    try std.testing.expectEqual(@as(usize, 0), session.activeIndex());
    const last = session.activeTab().?;
    try std.testing.expectEqual(SessionCore.CloseResult.closed_last, session.closeTabByPtr(@intFromPtr(last)));
    try std.testing.expectEqual(@as(usize, 0), session.count());
    try std.testing.expectEqual(@as(?*Tab, null), session.activeTab());
    // 어느 그룹에도 없는 pane 포인터는 무시한다 (정렬이 맞는 진짜 주소여야 `@ptrFromInt`
    // 안전 검사에 걸리지 않는다).
    const stranger = try std.testing.allocator.create(Tab);
    defer std.testing.allocator.destroy(stranger);
    try std.testing.expectEqual(SessionCore.CloseResult.none, session.closeTabByPtr(@intFromPtr(stranger)));
}

test "POSIX: #572 — stress 중간 pane 종료는 unread ring 을 마저 drain 한다" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const Exit = struct {
        fn notify(_: usize, _: ?*anyopaque) void {}
    };
    var session = SessionCore.init(
        testRuntime(),
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
    try expectStressCloseDrainsUnreadPane(&session);
}

test "POSIX: #483 4단계 — 분할 · 포커스 · 클릭 · 크기 · 최대화 · 분할선 드래그 · 닫기가 격자를 맞춘다" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const Exit = struct {
        fn notify(_: usize, _: ?*anyopaque) void {}
    };
    var session = SessionCore.init(
        testRuntime(),
        std.testing.allocator,
        "/bin/sh",
        100,
        null,
        null,
        &Exit.notify,
        null,
    );
    defer session.deinit();

    // macOS 2x 기준 metrics (`pane_layout` 테스트와 같은 값). 탭바를 뺀 영역 3052×1000 px.
    const m: pane_layout.Metrics = .{ .cell_w = 19, .cell_h = 39, .pad = 12, .scrollbar_w = 20, .separator_w = 2 };
    const rect: pane_layout.Rect = .{ .x = 0, .y = 0, .w = 3052, .h = 1000 };

    // 탭이 없으면 가를 곳이 없다.
    try std.testing.expectError(error.NoActiveTab, session.splitActive(.right, rect, m));

    try session.createTab(80, 24);
    try session.splitActive(.right, rect, m);
    const group = session.activeGroup().?;
    try std.testing.expectEqual(@as(usize, 2), group.paneCount());
    try std.testing.expectEqual(@as(usize, 1), session.count());
    // 새 pane (id 1) 이 활성이고, 두 pane 의 격자는 layout 과 같다 — 78 | 77 열 (1단계 결정 2:
    // 분할선은 앞 pane 의 셀 경계, 나머지는 뒤 pane), 25 줄.
    try std.testing.expectEqual(@as(pane_layout.PaneId, 1), group.active_pane);
    const left = group.panes[0].?;
    const right = group.panes[1].?;
    try std.testing.expectEqual(@as(u16, 78), left.terminal.cols);
    try std.testing.expectEqual(@as(u16, 77), right.terminal.cols);
    try std.testing.expectEqual(@as(u16, 25), right.terminal.rows);
    try expectGridMatchesLayout(group, rect, m);

    // 포커스: 왼쪽 → pane 0. 다시 왼쪽은 창 가장자리, 위는 그 축의 분할이 없다 → false.
    try std.testing.expect(session.focusPane(.left, rect, m));
    try std.testing.expectEqual(@as(pane_layout.PaneId, 0), group.active_pane);
    try std.testing.expect(!session.focusPane(.left, rect, m));
    try std.testing.expect(!session.focusPane(.up, rect, m));
    try std.testing.expectEqual(@as(pane_layout.PaneId, 0), group.active_pane);

    // 크기 조절: 분할선을 오른쪽으로 1셀 → 79 | 76. 상하로는 옮길 분할선이 없다.
    try std.testing.expect(session.resizeActivePane(.right, 1, rect, m));
    try std.testing.expectEqual(@as(u16, 79), left.terminal.cols);
    try std.testing.expectEqual(@as(u16, 76), right.terminal.cols);
    try expectGridMatchesLayout(group, rect, m);
    try std.testing.expect(!session.resizeActivePane(.up, 1, rect, m));
    // equalize → 다시 반씩.
    session.equalizeActive(rect, m);
    try std.testing.expectEqual(@as(u16, 78), left.terminal.cols);
    try std.testing.expectEqual(@as(u16, 77), right.terminal.cols);

    // 최대화 (4c): 활성 pane 0 이 영역 전체 — 배치는 pane 하나, 격자 158 열, 어느 픽셀도 pane 0. 다시
    // 누르면 풀리고 원래 격자로.
    try std.testing.expect(session.toggleZoomActive());
    try std.testing.expectEqual(@as(?pane_layout.PaneId, 0), group.zoomed);
    session.applyLayouts(rect, m);
    try std.testing.expectEqual(@as(u16, 158), left.terminal.cols);
    try std.testing.expectEqual(@as(?pane_layout.PaneId, 0), session.paneIdAt(2000, 500, rect, m));
    try std.testing.expect(session.toggleZoomActive());
    try std.testing.expectEqual(@as(?pane_layout.PaneId, null), group.zoomed);
    session.applyLayouts(rect, m);
    try std.testing.expectEqual(@as(u16, 78), left.terminal.cols);
    // 최대화 중 포커스 이동은 먼저 푼다 — 오른쪽 이웃 (pane 1) 으로 가고 격자는 펼친 것.
    try std.testing.expect(session.toggleZoomActive());
    try std.testing.expect(session.focusPane(.right, rect, m));
    try std.testing.expectEqual(@as(?pane_layout.PaneId, null), group.zoomed);
    try std.testing.expectEqual(@as(pane_layout.PaneId, 1), group.active_pane);
    try std.testing.expect(session.focusPane(.left, rect, m));

    // 분할선 드래그 (4c): x = 1000 에 놓으면 앞 pane 50 열 (셀 경계 스냅), 최소 크기 아래 (x = 100) 는 거부.
    var sbuf: [pane_layout.MAX_PANES_PER_TAB]pane_layout.Separator = undefined;
    const seps = group.separators(rect, m, &sbuf);
    try std.testing.expectEqual(@as(usize, 1), seps.len);
    try std.testing.expect(session.setSeparatorPx(seps[0].node, 1000, rect, m) != null);
    try std.testing.expectEqual(@as(u16, 50), left.terminal.cols);
    try expectGridMatchesLayout(group, rect, m);
    // 최소 크기 아래 자리는 한계에서 멈춘다 (clamp) — 앞 pane 20 열.
    try std.testing.expect(session.setSeparatorPx(seps[0].node, 100, rect, m) != null);
    try std.testing.expectEqual(@as(u16, 20), left.terminal.cols);
    try expectGridMatchesLayout(group, rect, m);
    session.equalizeActive(rect, m);
    try std.testing.expectEqual(@as(u16, 78), left.terminal.cols);

    // 클릭 포커스 (4b): 오른쪽 pane 의 픽셀 → id 1, 왼쪽 → 0, 분할선 (x = 1526 · 1527) 위는 null.
    try std.testing.expectEqual(@as(?pane_layout.PaneId, 1), session.paneIdAt(2000, 500, rect, m));
    try std.testing.expectEqual(@as(?pane_layout.PaneId, 0), session.paneIdAt(100, 500, rect, m));
    try std.testing.expectEqual(@as(?pane_layout.PaneId, null), session.paneIdAt(1527, 500, rect, m));
    try std.testing.expect(session.setActivePane(1));
    try std.testing.expectEqual(@as(pane_layout.PaneId, 1), group.active_pane);
    try std.testing.expect(!session.setActivePane(1));
    try std.testing.expect(!session.setActivePane(5));
    try std.testing.expect(session.setActivePane(0));
    // 휠 대상 (6단계 결정 B): 포인터 아래 pane 의 Tab, 분할선 위는 null — 활성 pane 은 그대로.
    try std.testing.expectEqual(@as(?*Tab, right), session.paneTabAt(2000, 500, rect, m));
    try std.testing.expectEqual(@as(?*Tab, null), session.paneTabAt(1527, 500, rect, m));
    try std.testing.expectEqual(@as(pane_layout.PaneId, 0), group.active_pane);

    // 최소 크기 아래로 내려가는 분할은 거부 — 트리 · pane 수 그대로.
    const narrow: pane_layout.Rect = .{ .x = 0, .y = 0, .w = 900, .h = 1000 };
    try std.testing.expectError(error.TooSmall, session.splitActive(.right, narrow, m));
    try std.testing.expectEqual(@as(usize, 2), group.paneCount());
    try std.testing.expectEqual(@as(pane_layout.PaneId, 0), group.active_pane);

    // pane 닫기: 활성 pane 0 → 남은 pane 1 이 활성, 탭은 그대로. 남은 pane 이 전체를 차지하는
    // 것은 host 가 `applyLayouts` 로 맞춘다 — 158 열.
    try std.testing.expectEqual(SessionCore.CloseResult.changed, session.closeActivePane());
    try std.testing.expectEqual(@as(usize, 1), group.paneCount());
    try std.testing.expectEqual(@as(pane_layout.PaneId, 1), group.active_pane);
    try std.testing.expectEqual(@as(usize, 1), session.count());
    try std.testing.expectEqual(@as(u16, 77), right.terminal.cols);
    session.applyLayouts(rect, m);
    try std.testing.expectEqual(@as(u16, 158), right.terminal.cols);
    try expectGridMatchesLayout(group, rect, m);

    // 마지막 pane 은 탭을 닫는다.
    try std.testing.expectEqual(SessionCore.CloseResult.closed_last, session.closeActivePane());
    try std.testing.expectEqual(@as(usize, 0), session.count());
    try std.testing.expectEqual(SessionCore.CloseResult.none, session.closeActivePane());
}

fn expectGridMatchesLayout(group: *TabGroup, rect: pane_layout.Rect, m: pane_layout.Metrics) !void {
    var buf: [pane_layout.MAX_PANES_PER_TAB]pane_layout.PaneRect = undefined;
    for (group.layout(rect, m, &buf)) |pr| {
        const tab = group.panes[pr.pane].?;
        try std.testing.expectEqual(pr.cols, tab.terminal.cols);
        try std.testing.expectEqual(pr.rows, tab.terminal.rows);
    }
}

test "POSIX: OSC 7 이 우선하고 쓸 수 없으면 프로세스 조회로 내려간다 (#366)" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const Exit = struct {
        fn notify(_: usize, _: ?*anyopaque) void {}
    };
    var session = SessionCore.init(
        testRuntime(),
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
    // GitHub Actions 의 windows-2022 러너에서는 `cmd.exe /c title …` 의 제목이 ConPTY 를 지나 OSC 로 오지 않는다 —
    // 3 초 · 30 초 폴링 둘 다 두 탭 모두 `Tab N` 그대로였다 (#607 ① 첫 · 둘째 native 실행, 375 개 중 이것 하나).
    // 바로 아래 "without OSC keeps default title" 은 그 환경에서도 통과한다 — ConPTY 자체는 산다. 로컬 Windows
    // (이 머신들) 에서는 3 초 안에 늘 통과하므로 러너에서만 건너뛴다. 러너의 OpenConsole 이 제목 OSC 를 내지
    // 않는 이유는 따로 보지 않았다 (세션 0 · 대화형 콘솔 없음이 유력).
    if (testRuntime().envHas("GITHUB_ACTIONS")) return error.SkipZigTest;

    const Exit = struct {
        fn notify(_: usize, _: ?*anyopaque) void {}
    };
    const shell = std.unicode.utf8ToUtf16LeStringLiteral(
        "cmd.exe /d /q /c \"title TILDAZ_OSC_TEST& ping -n 2 127.0.0.1 >nul\"",
    );
    var session = SessionCore.init(
        testRuntime(),
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
        testRuntime().sleepNs(10 * std.time.ns_per_ms);
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
        testRuntime(),
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
    var elapsed: runtime.Timer = .start(testRuntime());
    while (elapsed.read() < 1500 * std.time.ns_per_ms) {
        _ = session.drainOutputForRender();
        try std.testing.expect(session.activeTab().?.title_len > 0);
        testRuntime().sleepNs(10 * std.time.ns_per_ms);
    }
}

test "Windows: #572 — stress 중간 pane 종료는 unread ring 을 마저 drain 한다" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const Exit = struct {
        fn notify(_: usize, _: ?*anyopaque) void {}
    };
    const shell = std.unicode.utf8ToUtf16LeStringLiteral(
        "cmd.exe /d /q /c \"ping -n 2 127.0.0.1 >nul\"",
    );
    var session = SessionCore.init(
        testRuntime(),
        std.testing.allocator,
        shell,
        100,
        null,
        null,
        &Exit.notify,
        null,
    );
    defer session.deinit();
    session.createTab(80, 24) catch |err| switch (err) {
        error.ConptyRuntimeUnavailable => return error.SkipZigTest,
        else => return err,
    };

    try expectStressCloseDrainsUnreadPane(&session);
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
