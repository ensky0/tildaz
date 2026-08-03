//! stress / 처리량 하네스 ([#371](https://github.com/ensky0/tildaz/issues/371) ·
//! [#278](https://github.com/ensky0/tildaz/issues/278)).
//!
//! 창도 렌더러도 없이 PTY → VT 경로만 돌려서 **대용량 출력을 소화하는 속도**를
//! 잰다. Linux · macOS · Windows 에서 같은 명령으로 돈다.
//!
//! ```sh
//! zig build stress -- throughput --layer parser --mb 64 --workload plain
//! zig build stress -- throughput --layer pty    --mb 64 --workload ansi
//! ```
//!
//! ## 부하를 만드는 쪽도 우리 자신이다
//!
//! `--layer pty` 는 PTY 자식으로 셸이 아니라 **이 실행파일을 producer 모드로**
//! 띄운다. 그래서
//!
//! - Windows 기본 셸이 `cmd.exe` 인 것과 POSIX 가 `/bin/bash` 인 차이가 측정에서
//!   사라진다 (`cat` / `time` / `seq` 가 셸마다 다르거나 없다).
//! - 쏟아붓는 바이트가 세 platform 에서 완전히 같다. 입력이 다르면 숫자를 나란히
//!   둘 수 없다.
//!
//! producer 파라미터는 인자가 아니라 **환경변수**로 넘긴다 — POSIX 는 PTY 자식의
//! argv 가 `{shell}` (macOS 는 `{shell, "-l"}`) 로 고정이라 인자를 넘길 수 없다
//! (`terminal/posix/pty.zig`).
//!
//! ## 층을 나누는 이유
//!
//! | 층 | 지나는 경로 | 비는 것 |
//! |---|---|---|
//! | `parser` | 워크로드 → VT 파서 → grid | PTY · 프로세스 · ring |
//! | `pty` | producer → PTY → read thread → ring → VT 파서 → grid | 렌더 · 프레임 예산 |
//!
//! `pty − parser` 가 PTY read 와 ring 층의 몫이다. 즉 `perf` 없이도 시간이 어디서
//! 가는지 가를 수 있다.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const config = @import("config.zig");
const perf = @import("perf.zig");
const session_core = @import("session_core.zig");
const terminal = @import("terminal.zig");
const workload = @import("stress/workload.zig");

/// ghostty-vt 는 `std.log` 의 info 레벨로 page 용량 조정을 알린다. 색이 많이 섞인
/// 워크로드에서는 그 로그가 수만 줄이 되어 (`ansi` 64 MiB 에서 1.2 MB 출력) 리포트를
/// 덮고, 무엇보다 **로그를 쓰는 시간이 파싱 시간에 섞인다.** 경고 이상만 남긴다.
///
/// 앱 본체는 `std.log` 를 쓰지 않고 자체 `log.zig` 를 쓰므로 (그리고 창 앱이라
/// stderr 가 보이지 않으므로) 이 설정은 하네스에만 필요하다.
pub const std_options: std.Options = .{
    .log_level = .warn,
};

/// producer 모드 진입 + 파라미터. 환경변수인 이유는 위 문서 주석 참고.
const env_workload = "TILDAZ_STRESS_WORKLOAD";
const env_bytes = "TILDAZ_STRESS_BYTES";

/// 자식이 죽은 뒤에도 read thread 가 아직 안 읽은 데이터가 남아 있을 수 있다 —
/// `waitpid` 는 프로세스 종료만 알려주고 커널 버퍼가 비었는지는 말하지 않는다
/// (`terminal/posix/pty.zig` 의 `processWaitLoop` 는 read thread 와 별개다).
/// 그래서 "종료됨" 을 본 뒤에도 이 시간만큼 새 데이터가 없어야 끝으로 본다.
const drain_quiet_ns: u64 = 50 * std.time.ns_per_ms;

/// 무한 대기 방지. producer 가 죽지도 않고 데이터도 안 보내는 상황에서 빠져나온다.
const total_timeout_ns: u64 = 120 * std.time.ns_per_s;

const chunk_size = 64 * 1024;

/// 앱이 한 프레임에 파싱에 쓸 수 있는 상한. `frame` 층이 예산을 넘긴 프레임을 세는
/// 기준이고, 값은 앱과 같은 정의를 쓴다.
const frame_budget_ns = session_core.SessionCore.DRAIN_FRAME_BUDGET_NS;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // producer 모드는 argv 가 아니라 환경변수로 판정한다 (위 문서 주석).
    if (try producerRequest(alloc)) |req| return produce(req);

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    // `argsAlloc` 은 `[][:0]u8` 을 주는데 파싱에 sentinel 이 필요 없다. 느슨한 타입으로
    // 보면 테스트가 문자열 리터럴 배열을 그대로 넘길 수 있다.
    const argv: []const []const u8 = @ptrCast(args);

    const opts = parseArgs(argv) catch |err| switch (err) {
        error.Usage => {
            try printUsage();
            std.process.exit(2);
        },
        else => return err,
    };

    switch (opts.layer) {
        .parser => try runParser(alloc, opts),
        .pty => try runPty(alloc, opts),
        .frame => try runFrame(alloc, opts),
    }
}

// --- producer 모드 ---

const ProducerRequest = struct {
    kind: workload.Kind,
    bytes: u64,
};

/// 환경변수가 둘 다 있고 값이 유효할 때만 producer 모드다. 하나라도 빠지거나
/// 이상하면 일반 모드로 두어, 실수로 켜진 환경변수 때문에 조용히 다른 일을 하지
/// 않게 한다.
fn producerRequest(alloc: std.mem.Allocator) !?ProducerRequest {
    const kind_name = std.process.getEnvVarOwned(alloc, env_workload) catch return null;
    defer alloc.free(kind_name);
    const bytes_text = std.process.getEnvVarOwned(alloc, env_bytes) catch return null;
    defer alloc.free(bytes_text);

    const kind = workload.Kind.parse(kind_name) orelse return null;
    const bytes = std.fmt.parseInt(u64, bytes_text, 10) catch return null;
    return .{ .kind = kind, .bytes = bytes };
}

/// 정해진 바이트를 stdout 에 쏟고 끝낸다. stdout 은 PTY slave 라 부모의 read
/// thread 가 그대로 받는다.
fn produce(req: ProducerRequest) !void {
    var gen: workload.Generator = .{ .kind = req.kind };
    var buf: [chunk_size]u8 = undefined;
    const out = std.fs.File.stdout();

    var left = req.bytes;
    while (left > 0) {
        const n = @min(buf.len, left);
        _ = gen.read(buf[0..n]);
        try out.writeAll(buf[0..n]);
        left -= n;
    }
}

// --- 옵션 ---

const Layer = enum { parser, pty, frame };

const Options = struct {
    layer: Layer = .parser,
    workload_kind: workload.Kind = .plain,
    bytes: u64 = 64 * 1024 * 1024,
    cols: u16 = 120,
    rows: u16 = 40,
    /// 앱 기본값과 같게 둔다 — scrollback 예산이 page 할당량을 정해서 파서 부하에
    /// 영향을 준다.
    scroll_lines: u32 = config.Defaults.max_scroll_lines,
    /// `frame` 층이 모사할 프레임 주기. 실제 앱은 디스플레이 재생률에 맞춰 돌므로
    /// 재는 화면의 재생률을 넣는다 (일반 화면 60, 고주사율 120 등).
    fps: u32 = 60,
};

fn parseArgs(args: []const []const u8) !Options {
    if (args.len < 2) return error.Usage;
    if (!std.mem.eql(u8, args[1], "throughput")) return error.Usage;

    var opts: Options = .{};
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.Usage;
        const key = args[i];
        const value = args[i + 1];

        if (std.mem.eql(u8, key, "--layer")) {
            opts.layer = std.meta.stringToEnum(Layer, value) orelse return error.Usage;
        } else if (std.mem.eql(u8, key, "--workload")) {
            opts.workload_kind = workload.Kind.parse(value) orelse return error.Usage;
        } else if (std.mem.eql(u8, key, "--mb")) {
            const mb = std.fmt.parseInt(u64, value, 10) catch return error.Usage;
            if (mb == 0) return error.Usage;
            opts.bytes = mb * 1024 * 1024;
        } else if (std.mem.eql(u8, key, "--cols")) {
            opts.cols = std.fmt.parseInt(u16, value, 10) catch return error.Usage;
            if (opts.cols == 0) return error.Usage;
        } else if (std.mem.eql(u8, key, "--rows")) {
            opts.rows = std.fmt.parseInt(u16, value, 10) catch return error.Usage;
            if (opts.rows == 0) return error.Usage;
        } else if (std.mem.eql(u8, key, "--scrollback")) {
            opts.scroll_lines = std.fmt.parseInt(u32, value, 10) catch return error.Usage;
        } else if (std.mem.eql(u8, key, "--fps")) {
            opts.fps = std.fmt.parseInt(u32, value, 10) catch return error.Usage;
            if (opts.fps == 0) return error.Usage;
        } else {
            return error.Usage;
        }
    }
    return opts;
}

fn printUsage() !void {
    try std.fs.File.stdout().writeAll(
        \\usage: zig build stress -- throughput [options]
        \\
        \\  --layer      parser | pty | frame  (default: parser)
        \\  --workload   plain | ansi | cjk    (default: plain)
        \\  --mb         MiB to push           (default: 64)
        \\  --cols       grid columns          (default: 120)
        \\  --rows       grid rows             (default: 40)
        \\  --scrollback scrollback lines      (default: config default)
        \\  --fps        frame layer only      (default: 60)
        \\
        \\Grid size changes the parser's line-wrapping work, so always report it
        \\together with the numbers.
        \\
    );
}

// --- 측정 결과 ---

const Result = struct {
    /// 우리가 실제로 소화한 바이트. PTY 층에서는 개행 변환 때문에 요청보다 크다.
    consumed: u64,
    /// PTY 층에서만 의미 있다. `null` 이면 예상값을 계산하지 않았다는 뜻이다.
    expected: ?u64 = null,
    elapsed_ns: u64,
    /// producer 를 띄우고 첫 바이트를 받기까지. PTY 층에서만.
    spawn_ns: ?u64 = null,
    /// `null` 이면 이 층은 계측 지점을 지나지 않는다는 뜻이다. parser 층은
    /// `stream.nextSlice` 를 직접 불러서 `drainOutputChunk` 안의 계측을 안 지난다 —
    /// 그때 0 을 찍으면 "측정 안 됨" 과 "정말 0" 이 구별되지 않는다.
    counters: ?Counters = null,
    /// parser 층에서만. 벽시계에는 하네스가 바이트를 만든 시간이 섞이므로 파서
    /// 상한을 보려면 갈라야 한다.
    parser_split: ?ParserSplit = null,
    /// frame 층에서만.
    frame_split: ?FrameSplit = null,
};

const ParserSplit = struct {
    parse_ns: u64,
    generate_ns: u64,
};

const FrameSplit = struct {
    fps: u32,
    frames: u64,
    /// 프레임 예산 (8 ms) 을 넘긴 프레임 수. 실제 앱에서는 그만큼 vsync 를 놓친다.
    over_budget: u64,
};

const Counters = struct {
    readloop: [4]u64,
    push: [4]u64,
    drain: [4]u64,
    parse: [4]u64,
};

/// `perf.snapshot` 은 읽으면서 0 으로 되돌린다. 측정 시작 전에 한 번 비워 이전
/// 활동이 섞이지 않게 한다.
fn resetCounters() void {
    _ = perf.snapshot(&perf.readloop);
    _ = perf.snapshot(&perf.push);
    _ = perf.snapshot(&perf.drain);
    _ = perf.snapshot(&perf.parse);
}

fn takeCounters() Counters {
    return .{
        .readloop = perf.snapshot(&perf.readloop),
        .push = perf.snapshot(&perf.push),
        .drain = perf.snapshot(&perf.drain),
        .parse = perf.snapshot(&perf.parse),
    };
}

// --- layer: parser ---

/// PTY 도 프로세스도 없이 VT 파서만 돌린다. 파서가 낼 수 있는 상한이다.
///
/// **한계**: 여기 stream 은 응답 통로가 없는 읽기 전용이다 (`vtStream`). 프로덕션은
/// Windows 만 읽기 전용이고 macOS · Linux 는 질의 응답용 effects 가 붙은 stream 을
/// 쓴다 (`session_core.Tab.init`, #266). 이 하네스의 워크로드에는 응답이 필요한
/// 질의 시퀀스가 없으므로 파싱 비용이 같을 것으로 보지만 **직접 재서 확인하지는
/// 않았다.**
fn runParser(alloc: std.mem.Allocator, opts: Options) !void {
    var term = try session_core.initVtTerminal(alloc, opts.cols, opts.rows, opts.scroll_lines, null);
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    var gen: workload.Generator = .{ .kind = opts.workload_kind };
    var buf: [chunk_size]u8 = undefined;

    var timer = try std.time.Timer.start();

    // 바이트를 만드는 시간과 파싱하는 시간을 따로 센다. 한 덩어리로 재면 하네스의
    // 생성 비용이 파서 숫자에 섞여 (실측에서 약 18 %) PTY 층의 소화 속도보다 파서
    // 상한이 낮게 나오는 모순이 생긴다.
    var generate_ns: u64 = 0;
    var parse_ns: u64 = 0;

    var left = opts.bytes;
    while (left > 0) {
        const n = @min(buf.len, left);

        const t0 = timer.read();
        _ = gen.read(buf[0..n]);
        const t1 = timer.read();
        stream.nextSlice(buf[0..n]);
        const t2 = timer.read();

        generate_ns += t1 - t0;
        parse_ns += t2 - t1;
        left -= n;
    }

    const elapsed_ns = timer.read();
    try report(opts, .{
        .consumed = opts.bytes,
        .elapsed_ns = elapsed_ns,
        .parser_split = .{ .parse_ns = parse_ns, .generate_ns = generate_ns },
    });
}

// --- layer: pty ---

const ExitState = struct {
    exited: std.atomic.Value(bool) = .init(false),
};

fn onTabExit(_: usize, userdata: ?*anyopaque) void {
    const state: *ExitState = @ptrCast(@alignCast(userdata.?));
    state.exited.store(true, .release);
}

/// producer 를 PTY 자식으로 띄운 세션. `pty` 와 `frame` 층이 같은 준비 과정을 쓴다.
///
/// 힙에 두는 이유는 `extra_env` 가 자기 안의 `bytes_text` 를 가리키기 때문이다 —
/// 스택에 두면 이 struct 를 옮기는 순간 그 포인터가 어긋난다.
const ProducerSession = struct {
    alloc: std.mem.Allocator,
    shell_command: terminal.ShellCommand,
    bytes_text: [24]u8 = undefined,
    extra_env: [2]terminal.ExtraEnv = undefined,
    state: ExitState = .{},
    core: session_core.SessionCore = undefined,

    fn start(alloc: std.mem.Allocator, opts: Options) !*ProducerSession {
        const self = try alloc.create(ProducerSession);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .shell_command = undefined };

        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_path = try std.fs.selfExePath(&exe_buf);
        self.shell_command = try toShellCommand(alloc, exe_path);
        errdefer freeShellCommand(alloc, self.shell_command);

        const bytes_text = try std.fmt.bufPrint(&self.bytes_text, "{d}", .{opts.bytes});
        self.extra_env = .{
            .{ .name = env_workload, .value = @tagName(opts.workload_kind) },
            .{ .name = env_bytes, .value = bytes_text },
        };

        self.core = session_core.SessionCore.init(
            alloc,
            self.shell_command,
            opts.scroll_lines,
            null,
            &self.extra_env,
            onTabExit,
            &self.state,
        );
        errdefer self.core.deinit();

        // 여기서 자식이 뜨고 곧바로 쓰기 시작한다 — 호출자는 바로 비우기 시작해야 한다.
        try self.core.createTab(opts.cols, opts.rows);
        return self;
    }

    fn deinit(self: *ProducerSession) void {
        self.core.deinit();
        freeShellCommand(self.alloc, self.shell_command);
        self.alloc.destroy(self);
    }

    fn tab(self: *ProducerSession) !*session_core.Tab {
        return self.core.activeTab() orelse error.NoTab;
    }

    fn exited(self: *ProducerSession) bool {
        return self.state.exited.load(.acquire);
    }
};

fn runPty(alloc: std.mem.Allocator, opts: Options) !void {
    resetCounters();
    var timer = try std.time.Timer.start();

    const session = try ProducerSession.start(alloc, opts);
    defer session.deinit();
    const tab = try session.tab();

    var first_data_ns: ?u64 = null;
    var last_data_ns: u64 = 0;
    while (true) {
        const chunks = tab.drainAllForStress();
        const now_ns = timer.read();

        if (chunks > 0) {
            if (first_data_ns == null) first_data_ns = now_ns;
            last_data_ns = now_ns;
        } else {
            // 자식이 끝났고 조용해진 뒤에야 종료한다 (`drain_quiet_ns` 주석 참고).
            if (session.exited() and now_ns - last_data_ns > drain_quiet_ns) break;
            std.Thread.yield() catch {};
        }

        if (now_ns > total_timeout_ns) return error.StressTimeout;
    }

    const counters = takeCounters();
    const start_ns = first_data_ns orelse return error.NoOutput;

    try report(opts, .{
        // drain 카운터의 bytes 가 우리가 VT 로 넘긴 실제 바이트다.
        .consumed = counters.drain[2],
        .expected = expectedPtyBytes(opts),
        .elapsed_ns = last_data_ns - start_ns,
        .spawn_ns = start_ns,
        .counters = counters,
    });
}

// --- layer: frame ---

/// 앱이 실제로 지나는 경로다. host 는 vsync 마다 `drainOutputForRender` 를 부르고,
/// 그 안의 `drainFrame` 이 **한 프레임에 8 ms** 만 파싱한다
/// (`session_core.SessionCore.DRAIN_FRAME_BUDGET_NS`). 그래서 사용자가 겪는 처리량은
/// 파서 상한이 아니라 `예산 / 프레임 간격` 만큼으로 눌린다.
///
/// macOS 는 CADisplayLink (`NSWindow.displayLink`) 가 vsync 마다 main thread 에서
/// 부르고, Linux 는 poll loop, Windows 는 app_controller 의 프레임 경로다. 여기서는
/// 그 주기를 `--fps` 로 모사한다.
///
/// **렌더는 하지 않는다.** 이 층이 재는 것은 "프레임 예산이 파싱을 어디까지 누르는가"
/// 이고, 실제 앱은 여기에 렌더 시간까지 더해진다. 즉 이 숫자는 체감의 **상한**이다.
fn runFrame(alloc: std.mem.Allocator, opts: Options) !void {
    resetCounters();
    var timer = try std.time.Timer.start();

    const session = try ProducerSession.start(alloc, opts);
    defer session.deinit();

    const frame_ns = std.time.ns_per_s / @as(u64, opts.fps);
    var next_frame_ns: u64 = frame_ns;

    var frames: u64 = 0;
    var over_budget: u64 = 0;
    var first_data_ns: ?u64 = null;
    var last_data_ns: u64 = 0;

    while (true) {
        const before_ns = timer.read();
        const had_output = session.core.drainOutputForRender();
        const after_ns = timer.read();

        frames += 1;
        if (after_ns - before_ns > frame_budget_ns) over_budget += 1;

        if (had_output) {
            if (first_data_ns == null) first_data_ns = after_ns;
            last_data_ns = after_ns;
        } else if (session.exited() and after_ns - last_data_ns > drain_quiet_ns) {
            break;
        }

        if (after_ns > total_timeout_ns) return error.StressTimeout;

        // 다음 vsync 까지 기다린다. 예산을 넘겨 이미 늦었으면 따라잡지 않고 지금부터
        // 다시 센다 — 실제 앱도 놓친 vsync 를 몰아서 그리지 않는다.
        const now_ns = timer.read();
        if (next_frame_ns > now_ns) {
            std.Thread.sleep(next_frame_ns - now_ns);
            next_frame_ns += frame_ns;
        } else {
            next_frame_ns = now_ns + frame_ns;
        }
    }

    const counters = takeCounters();
    const start_ns = first_data_ns orelse return error.NoOutput;

    try report(opts, .{
        .consumed = counters.drain[2],
        .expected = expectedPtyBytes(opts),
        .elapsed_ns = last_data_ns - start_ns,
        .spawn_ns = start_ns,
        .counters = counters,
        .frame_split = .{
            .fps = opts.fps,
            .frames = frames,
            .over_budget = over_budget,
        },
    });
}

/// PTY 를 지나며 늘어난 바이트를 포함한 **최소** 수신량. `\n` 하나가 `\r\n` 으로
/// 나오므로 (termios `ONLCR`) 송신 바이트 + 송신 안의 `\n` 개수다. 워크로드가
/// 결정적이라 다시 만들어 세면 정확히 나온다.
///
/// **하한이지 정확값이 아니다.** macOS 실측에서 이 값보다 조금 더 받는다 — 줄 수에
/// 정비례하고 (80 byte 줄 13,107 개에 +14, 40 byte 줄 26,214 개에 +28), 터미널 폭 ·
/// 줄 길이 · write 조각 크기와 무관하며, 데이터 없이 `\n` 만 보내면 생기지 않는다.
/// tty 드라이버의 출력 처리에서 오는 것으로 보이지만 **정확한 규칙은 확정하지
/// 않았다** (64 MiB 에서 819 byte = 0.0013 %). Linux 도 같은지 미확인.
///
/// 그래서 판정은 한 방향으로만 쓴다 — **모자라면 데이터를 흘린 것**이고, 남는 것은
/// 정상이다. 처리량은 실제 소화한 바이트로 계산하므로 이 오차에 영향받지 않는다.
///
/// Windows 는 `null` 이다 — ConPTY 는 자식 출력에 자기 시퀀스를 끼워 넣을 수 있어
/// 이렇게 계산할 수 없다. (Windows 실기 확인 전이다.)
fn expectedPtyBytes(opts: Options) ?u64 {
    if (builtin.os.tag == .windows) return null;

    var gen: workload.Generator = .{ .kind = opts.workload_kind };
    var buf: [chunk_size]u8 = undefined;
    var newlines: u64 = 0;
    var left = opts.bytes;
    while (left > 0) {
        const n = @min(buf.len, left);
        _ = gen.read(buf[0..n]);
        newlines += std.mem.count(u8, buf[0..n], "\n");
        left -= n;
    }
    return opts.bytes + newlines;
}

/// 자기 실행파일 경로를 platform 별 `ShellCommand` 표현으로. Windows 는
/// `CreateProcessW` 가 UTF-16 을 받고, POSIX 는 `execve` 가 UTF-8 을 받는다.
fn toShellCommand(alloc: std.mem.Allocator, exe_path: []const u8) !terminal.ShellCommand {
    if (builtin.os.tag == .windows) {
        return try std.unicode.utf8ToUtf16LeAllocZ(alloc, exe_path);
    }
    return try alloc.dupe(u8, exe_path);
}

fn freeShellCommand(alloc: std.mem.Allocator, cmd: terminal.ShellCommand) void {
    if (builtin.os.tag == .windows) {
        alloc.free(std.mem.span(cmd));
    } else {
        alloc.free(cmd);
    }
}

// --- 리포트 ---

fn report(opts: Options, result: Result) !void {
    var buf: [4096]u8 = undefined;
    var w = Report{ .buf = &buf };

    const mib = 1024.0 * 1024.0;
    const elapsed_ms = @as(f64, @floatFromInt(result.elapsed_ns)) / std.time.ns_per_ms;
    const consumed_mib = @as(f64, @floatFromInt(result.consumed)) / mib;
    const seconds = @as(f64, @floatFromInt(result.elapsed_ns)) / std.time.ns_per_s;
    const throughput = if (seconds > 0) consumed_mib / seconds else 0;

    w.print("=== tildaz stress: throughput ===\n", .{});
    w.print("layer         {s}\n", .{@tagName(opts.layer)});
    w.print("workload      {s}\n", .{@tagName(opts.workload_kind)});
    w.print("grid          {d}x{d}\n", .{ opts.cols, opts.rows });
    w.print("scrollback    {d} lines\n", .{opts.scroll_lines});
    w.print("requested     {d} bytes ({d:.1} MiB)\n", .{
        opts.bytes,
        @as(f64, @floatFromInt(opts.bytes)) / mib,
    });
    w.print("build         {s} simd={} version={s}\n", .{
        @tagName(builtin.mode),
        build_options.simd,
        build_options.version,
    });
    w.print("platform      {s} {s}\n", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    });
    w.print("\n", .{});

    w.print("consumed      {d} bytes ({d:.1} MiB)\n", .{ result.consumed, consumed_mib });
    if (result.expected) |expected| {
        // `expectedPtyBytes` 는 하한이다 — 모자라면 데이터를 흘렸다는 뜻이고 그 숫자는
        // 비교에 쓸 수 없다. 남는 것은 tty 출력 처리에서 오는 정상 오차다.
        if (result.consumed < expected) {
            w.print("expected      {d} bytes minimum (DATA LOSS — {d} byte 부족)\n", .{
                expected,
                expected - result.consumed,
            });
        } else {
            w.print("expected      {d} bytes minimum (ok, +{d} from tty)\n", .{
                expected,
                result.consumed - expected,
            });
        }
    }
    if (result.spawn_ns) |spawn_ns| {
        w.print("spawn→first   {d:.1} ms\n", .{
            @as(f64, @floatFromInt(spawn_ns)) / std.time.ns_per_ms,
        });
    }
    w.print("elapsed       {d:.1} ms (end to end)\n", .{elapsed_ms});
    w.print("throughput    {d:.1} MiB/s (end to end)\n", .{throughput});

    // PTY 층의 벽시계에는 producer 가 다음 조각을 쓸 때까지 기다린 시간이 섞인다.
    // 그걸 가르지 않으면 "우리가 느리다" 와 "부하를 주는 쪽이 느리다" 를 구별할 수
    // 없다 — 아래 두 줄이 그 구분이다.
    if (result.counters) |counters| {
        const busy_ns = counters.drain[1];
        if (busy_ns > 0 and result.elapsed_ns > busy_ns) {
            const busy_s = @as(f64, @floatFromInt(busy_ns)) / std.time.ns_per_s;
            w.print("  drain busy  {d:.1} ms → {d:.1} MiB/s (기다린 시간 제외)\n", .{
                @as(f64, @floatFromInt(busy_ns)) / std.time.ns_per_ms,
                consumed_mib / busy_s,
            });
            w.print("  waiting     {d:.1} ms (producer 가 쓰는 동안)\n", .{
                @as(f64, @floatFromInt(result.elapsed_ns - busy_ns)) / std.time.ns_per_ms,
            });
        }
    }
    if (result.parser_split) |split| {
        const parse_s = @as(f64, @floatFromInt(split.parse_ns)) / std.time.ns_per_s;
        if (parse_s > 0) {
            w.print("  parse only  {d:.1} ms → {d:.1} MiB/s (워크로드 생성 제외)\n", .{
                @as(f64, @floatFromInt(split.parse_ns)) / std.time.ns_per_ms,
                consumed_mib / parse_s,
            });
        }
        w.print("  generating  {d:.1} ms (하네스가 바이트를 만든 시간)\n", .{
            @as(f64, @floatFromInt(split.generate_ns)) / std.time.ns_per_ms,
        });
    }
    if (result.frame_split) |split| {
        w.print("  frames      {d} @ {d} fps 모사 (렌더는 하지 않음)\n", .{
            split.frames,
            split.fps,
        });
        w.print("  over budget {d} frames ({d} ms 예산 초과)\n", .{
            split.over_budget,
            frame_budget_ns / std.time.ns_per_ms,
        });
    }
    w.print("\n", .{});

    if (result.counters) |counters| {
        // readloop 과 push 는 PTY read thread 에서 도므로 위 벽시계와 나란히 흐른다 —
        // drain / parse 와 더하면 안 된다. drain 은 ring pop + parse 를 모두 포함한다.
        w.print("--- perf counters (readloop/push 는 별 thread) ---\n", .{});
        writeCounter(&w, "readloop", counters.readloop, true);
        writeCounter(&w, "push", counters.push, true);
        writeCounter(&w, "drain", counters.drain, true);
        writeCounter(&w, "parse", counters.parse, false);
    } else {
        w.print("--- perf counters ---\nnot instrumented on this layer\n", .{});
    }

    try std.fs.File.stdout().writeAll(w.slice());
}

/// `show_bytes` 가 false 면 byte 칸을 비운다 — `parse` 는 시간만 재고 byte 를 세지
/// 않아서 (`perf.addTimed`), 0 을 찍으면 "0 byte 를 파싱했다" 로 읽힌다.
fn writeCounter(w: *Report, name: []const u8, c: [4]u64, show_bytes: bool) void {
    const ms = @as(f64, @floatFromInt(c[1])) / std.time.ns_per_ms;
    if (show_bytes) {
        w.print("{s: <9} calls={d: <8} bytes={d: <12} ms={d:.3}\n", .{ name, c[0], c[2], ms });
    } else {
        w.print("{s: <9} calls={d: <8} {s: <18} ms={d:.3}\n", .{ name, c[0], "", ms });
    }
}

/// 고정 버퍼에 이어 쓰는 최소 writer. 리포트는 길이가 정해져 있어 넘칠 일이 없다.
const Report = struct {
    buf: []u8,
    len: usize = 0,

    fn print(self: *Report, comptime fmt: []const u8, args: anytype) void {
        const out = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch return;
        self.len += out.len;
    }

    fn slice(self: *const Report) []const u8 {
        return self.buf[0..self.len];
    }
};

// --- tests ---

test "인자 파싱 — 기본값과 명시값" {
    const default_opts = try parseArgs(&.{ "stress", "throughput" });
    try std.testing.expectEqual(Layer.parser, default_opts.layer);
    try std.testing.expectEqual(workload.Kind.plain, default_opts.workload_kind);
    try std.testing.expectEqual(@as(u64, 64 * 1024 * 1024), default_opts.bytes);

    const opts = try parseArgs(&.{
        "stress",     "throughput",
        "--layer",    "pty",
        "--workload", "cjk",
        "--mb",       "8",
        "--cols",     "200",
        "--rows",     "50",
    });
    try std.testing.expectEqual(Layer.pty, opts.layer);
    try std.testing.expectEqual(workload.Kind.cjk, opts.workload_kind);
    try std.testing.expectEqual(@as(u64, 8 * 1024 * 1024), opts.bytes);
    try std.testing.expectEqual(@as(u16, 200), opts.cols);
    try std.testing.expectEqual(@as(u16, 50), opts.rows);
}

test "인자 파싱 — 잘못된 입력은 usage" {
    try std.testing.expectError(error.Usage, parseArgs(&.{"stress"}));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "stress", "nope" }));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "stress", "throughput", "--layer" }));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "stress", "throughput", "--layer", "gpu" }));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "stress", "throughput", "--mb", "0" }));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "stress", "throughput", "--cols", "0" }));
}

test "PTY 예상 바이트는 개행 변환을 센다" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    // plain 은 80 byte 고정 줄이라 1 MiB 안의 개행 수를 손으로 계산할 수 있다.
    const opts: Options = .{ .workload_kind = .plain, .bytes = 80 * 1000 };
    const expected = expectedPtyBytes(opts).?;
    try std.testing.expectEqual(@as(u64, 80 * 1000 + 1000), expected);
}
