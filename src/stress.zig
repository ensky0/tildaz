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
const instance_context = @import("instance_context.zig");
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
/// 다른 터미널 안에서 producer 를 돌릴 때 결과를 돌려받는 통로 (#371 L4). 우리 하네스가
/// 부모일 때는 쓰지 않는다.
const env_timing_file = "TILDAZ_STRESS_TIMING_FILE";

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
    // 하네스는 **언제나** 측정이다. `main.zig` 는 `-e` 일 때만 이 역할을 세우지만
    // (`run_opts.isStressRun()`) 여기는 조건이 없다.
    //
    // 이걸 빠뜨리면 역할이 기본값 `.worker` 로 남아 `paths.logPath` 가 사용자 세션의
    // `tildaz_N.log` 를 고른다 — #382 가 막으려던 바로 그 오염이다. Windows 층별 측정
    // (#381) 에서 실제로 `tildaz_0.log` 에 30 줄이 들어갔다. 하네스는 config 파일을
    // 읽지도 창을 띄우지도 않으므로 이 호출이 바꾸는 것은 로그 파일 이름 하나다.
    //
    // producer 모드 판정보다 앞에 둔다 — producer 자식도 같은 실행파일이다.
    instance_context.setRole(.stress);

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

    switch (opts.command) {
        .throughput => switch (opts.layer) {
            .parser => try runParser(alloc, opts),
            .pty => try runPty(alloc, opts),
            .frame => try runFrame(alloc, opts),
        },
        .scrollback => try runScrollback(alloc, opts),
    }
}

// --- producer 모드 ---

const ProducerRequest = struct {
    kind: workload.Kind,
    bytes: u64,
    /// 있으면 출력을 끝낸 뒤 여기에 결과를 적는다 (#371 L4). 우리 하네스가 부모일
    /// 때는 필요 없다 — 부모가 직접 재니까. **다른 터미널 안에서 돌 때** 결과를
    /// 돌려받을 통로가 이것뿐이다.
    timing_path: ?[]const u8 = null,
};

/// 환경변수 두 개가 다 있고 값이 유효할 때만 producer 모드다. 하나라도 빠지거나
/// 이상하면 일반 모드로 두어, 실수로 켜진 환경변수 때문에 조용히 다른 일을 하지
/// 않게 한다. timing 파일은 선택이다.
fn producerRequest(alloc: std.mem.Allocator) !?ProducerRequest {
    const kind_name = std.process.getEnvVarOwned(alloc, env_workload) catch return null;
    defer alloc.free(kind_name);
    const bytes_text = std.process.getEnvVarOwned(alloc, env_bytes) catch return null;
    defer alloc.free(bytes_text);

    const kind = workload.Kind.parse(kind_name) orelse return null;
    const bytes = std.fmt.parseInt(u64, bytes_text, 10) catch return null;

    // 호출자가 free 하지 않는다 — producer 는 이 값을 쓰고 곧 종료한다.
    const timing_path = std.process.getEnvVarOwned(alloc, env_timing_file) catch null;

    return .{ .kind = kind, .bytes = bytes, .timing_path = timing_path };
}

/// 정해진 바이트를 stdout 에 쏟고 끝낸다. stdout 은 PTY slave 라 부모의 read
/// thread (또는 우리를 띄운 다른 터미널) 가 그대로 받는다.
fn produce(req: ProducerRequest) !void {
    if (builtin.os.tag == .windows) {
        // producer 의 stdout 은 ConPTY 콘솔이다. 출력 코드페이지를 UTF-8 로 맞춰 cjk 가
        // 콘솔 기본 CP (CP949 등) 로 깨지지 않게 한다 (위 SetConsoleOutputCP 주석).
        _ = SetConsoleOutputCP(65001);
    }
    var gen: workload.Generator = .{ .kind = req.kind };
    var buf: [chunk_size]u8 = undefined;
    const out = std.fs.File.stdout();

    // 그리드를 **출력 전후 두 번** 읽는다. 한 번만 읽으면 어느 쪽이든 틀린다:
    //
    // - 시작 시점만 읽으면 **resize race** 에 걸린다. 일부 터미널 (실측: ghostty · kitty)
    //   은 셸을 spawn 한 뒤 창 크기에 맞춰 PTY 를 resize 하므로, 그 전에 읽으면 초기값을
    //   본다 (ghostty 에서 100x30 을 줬는데 50x6 으로 읽혔다). alacritty 는 spawn 전에
    //   크기가 확정돼서 이 문제가 없다.
    // - 끝 시점만 읽으면 창이 닫히는 중일 수 있다.
    //
    // 둘을 다 남기고 판정은 호출자에게 맡긴다. 다르면 그 측정은 그리드가 흔들린 것이다.
    const grid_start = producerGrid();

    var timer = try std.time.Timer.start();
    var left = req.bytes;
    while (left > 0) {
        const n = @min(buf.len, left);
        _ = gen.read(buf[0..n]);
        try out.writeAll(buf[0..n]);
        left -= n;
    }
    const elapsed_ns = timer.read();
    const grid_end = producerGrid();

    if (req.timing_path) |path| {
        writeTiming(path, req, elapsed_ns, grid_start, grid_end) catch {};
    }
}

const Grid = struct { cols: u16, rows: u16 };

// cjk 워크로드는 UTF-8 바이트다. producer 가 콘솔 출력 코드페이지를 UTF-8 로 맞추지 않으면
// 콘솔 기본값 (한국어 Windows 는 CP949) 으로 깨져 렌더돼, 화면도 깨지고 cjk 처리량도 실제
// wide-cell 부하가 아니게 된다 (Windows 실기: 다섯 터미널 모두 cjk 가 깨졌다). produce 가
// 시작할 때 한 번 65001 로 맞춘다. `std.os.windows.kernel32` 에 없어 직접 선언한다.
extern "kernel32" fn SetConsoleOutputCP(wCodePageID: c_uint) callconv(.c) c_int;

/// producer 가 자기 tty 의 그리드를 직접 읽는다. **이게 L4 비교의 전제다** — 터미널마다
/// 폰트 크기 해석이 달라서 같은 창 크기를 줘도 셀 수가 갈리고, 열 수가 다르면 줄바꿈
/// 횟수가 달라져 파서 부하가 달라진다. [#362](https://github.com/ensky0/tildaz/issues/362)
/// 에서 그리드가 31 배 어긋난 채로 비교하려던 적이 있어서, 재는 쪽이 스스로 남긴다.
///
/// host 마다 tty 크기를 묻는 API 가 다르다 — POSIX 는 `ioctl(TIOCGWINSZ)`, Windows 는
/// console screen buffer info 다. **Windows 도 반드시 값을 내야 한다** — `-size` 가 실제로
/// 그 격자를 만들었는지 확인하는 통로가 timing 파일의 이 값이기 때문이다
/// ([#382](https://github.com/ensky0/tildaz/issues/382)). 예전에 Windows 를 `null` 로
/// 두었을 때는 `cols=0 rows=0` 이 적혀서, 그 확인 절차 자체가 Windows 에서 성립하지
/// 않았다 (실기 검증에서 창 크기를 밖에서 재는 우회가 필요했다).
fn producerGrid() ?Grid {
    if (builtin.os.tag == .windows) {
        // producer 의 stdout 은 우리 ConPTY 의 콘솔이라 console API 가 그대로 동작한다.
        // **`dwSize` 가 아니라 `srWindow` 를 쓴다** — `dwSize` 는 스크롤백을 포함한 버퍼
        // 크기이고, 우리가 재려는 것은 *보이는* 격자다. 우리는
        // `CreatePseudoConsole(COORD{cols, rows})` 로 창 = 요청 격자를 넘기므로 두 값이
        // 실제로 갈렸다는 관측은 아직 없다 (**추정** — ConPTY 가 버퍼 높이를 창보다 크게
        // 잡을 수 있다는 문서 근거를 확인하지 않았다). 어느 쪽이든 *보이는* 격자를 원하니
        // `srWindow` 가 맞는 선택이다.
        const win = std.os.windows;
        var info: win.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        const handle = std.fs.File.stdout().handle;
        if (win.kernel32.GetConsoleScreenBufferInfo(handle, &info) == 0) return null;
        const cols: i32 = @as(i32, info.srWindow.Right) - info.srWindow.Left + 1;
        const rows: i32 = @as(i32, info.srWindow.Bottom) - info.srWindow.Top + 1;
        if (cols <= 0 or rows <= 0) return null;
        return .{ .cols = @intCast(cols), .rows = @intCast(rows) };
    }

    var ws: std.posix.winsize = undefined;
    const fd = std.fs.File.stdout().handle;
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        if (std.posix.errno(linux.ioctl(fd, linux.T.IOCGWINSZ, @intFromPtr(&ws))) != .SUCCESS) {
            return null;
        }
    } else {
        if (std.c.ioctl(fd, std.c.T.IOCGWINSZ, @intFromPtr(&ws)) < 0) return null;
    }
    if (ws.col == 0 or ws.row == 0) return null;
    return .{ .cols = ws.col, .rows = ws.row };
}

/// `key=value` 줄로 적는다 — 스크립트가 파싱하기 쉽고 사람도 읽을 수 있다.
///
/// **경과 시간의 의미**: producer 가 마지막 byte 를 `write` 한 시점까지다. 그 순간
/// 터미널이 아직 남은 것을 파싱하고 있을 수 있다. `time cat <파일>` 로 재는 것과 같은
/// 성질의 값이고 (이 이슈 본문이 제안한 방법), PTY 버퍼가 작아서 대개 근사가 된다.
fn writeTiming(
    path: []const u8,
    req: ProducerRequest,
    elapsed_ns: u64,
    grid_start: ?Grid,
    grid_end: ?Grid,
) !void {
    var buf: [512]u8 = undefined;
    var w = Report{ .buf = &buf };
    w.print("elapsed_ns={d}\n", .{elapsed_ns});
    w.print("bytes={d}\n", .{req.bytes});
    w.print("workload={s}\n", .{@tagName(req.kind)});
    if (grid_start) |g| {
        w.print("cols_start={d}\nrows_start={d}\n", .{ g.cols, g.rows });
    } else {
        w.print("cols_start=0\nrows_start=0\n", .{});
    }
    // 마지막 줄이 `rows` 다 — 읽는 쪽이 파일이 끝까지 쓰였는지 이 줄로 판단한다.
    if (grid_end) |g| {
        w.print("cols={d}\nrows={d}\n", .{ g.cols, g.rows });
    } else {
        w.print("cols=0\nrows=0\n", .{});
    }

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(w.slice());
}

// --- 옵션 ---

const Command = enum { throughput, scrollback };

const Layer = enum { parser, pty, frame };

const Options = struct {
    command: Command = .throughput,
    layer: Layer = .parser,
    workload_kind: workload.Kind = .plain,
    bytes: u64 = 64 * 1024 * 1024,
    cols: u16 = 120,
    rows: u16 = 40,
    /// 앱 기본값과 같게 둔다 — scrollback 예산이 page 할당량을 정해서 파서 부하에
    /// 영향을 준다.
    scroll_lines: u32 = config.Defaults.max_scroll_lines,
    /// `frame` 층이 모사할 프레임 주기. 실제 앱은 디스플레이 재생률에 맞춰 돌므로
    /// **재는 화면의 재생률**을 넣는다 (일반 화면 60, ProMotion 등 고주사율 120).
    fps: u32 = 60,
    /// `--fps` 를 명시했는지. 기본값 60 을 그대로 쓰면 고주사율 화면에서 숫자가 크게
    /// 어긋나므로 (실측: 120 Hz 화면에서 ansi 가 103 → 138 MiB/s) 리포트가 경고한다.
    fps_explicit: bool = false,
    /// `scrollback` 명령이 출력을 몇 구간으로 나눠 볼지. 구간마다 처리 속도를 따로
    /// 재서 뒤로 갈수록 느려지는지 본다.
    segments: u32 = 8,
};

fn parseArgs(args: []const []const u8) !Options {
    if (args.len < 2) return error.Usage;

    var opts: Options = .{};
    opts.command = std.meta.stringToEnum(Command, args[1]) orelse return error.Usage;

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
            opts.fps_explicit = true;
        } else if (std.mem.eql(u8, key, "--segments")) {
            opts.segments = std.fmt.parseInt(u32, value, 10) catch return error.Usage;
            if (opts.segments == 0 or opts.segments > max_segments) return error.Usage;
        } else {
            return error.Usage;
        }
    }
    return opts;
}

fn printUsage() !void {
    try std.fs.File.stdout().writeAll(
        \\usage: zig build stress -- <throughput | scrollback> [options]
        \\
        \\  throughput   how fast bulk output is consumed
        \\  scrollback   whether the rate holds as scrollback accumulates (#278)
        \\
        \\  --layer      parser | pty | frame  (default: parser, throughput only)
        \\  --workload   plain | ansi | cjk    (default: plain)
        \\  --mb         MiB to push           (default: 64)
        \\  --cols       grid columns          (default: 120)
        \\  --rows       grid rows             (default: 40)
        \\  --scrollback scrollback lines      (default: config default)
        \\  --fps        frame layer only      (default: 60)
        \\  --segments   scrollback only       (default: 8)
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
    fps_explicit: bool,
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
        // 한 덩어리씩 받는다 — `drainChunkForStress` 주석의 이유대로, 우리가 producer
        // 보다 느리면 "빌 때까지" 도는 형태는 반환하지 않는다.
        const had_data = tab.drainChunkForStress();
        const now_ns = timer.read();

        if (had_data) {
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
            .fps_explicit = opts.fps_explicit,
            .frames = frames,
            .over_budget = over_budget,
        },
    });
}

/// PTY 를 지나며 늘어난 바이트를 포함한 **최소** 수신량. `\n` 하나가 `\r\n` 으로
/// 나오므로 (termios `ONLCR`) 송신 바이트 + 송신 안의 `\n` 개수다. 워크로드가
/// 결정적이라 다시 만들어 세면 정확히 나온다.
///
/// **하한이지 정확값이 아니다.** platform 마다 그 위에 얹히는 초과분이 다르다 (실측):
///
/// - **Linux 는 `+0`** — `ONLCR` 변환 외에 아무것도 더하지 않아 예상값이 정확히 맞는다.
/// - **macOS 는 조금 더 받는다** (64 MiB 에서 819 byte = 0.0013 %). 줄 수에 정비례하고,
///   터미널 폭 · 줄 길이 · write 조각 크기와 무관하며, 데이터 없이 `\n` 만 보내면
///   생기지 않는다. tty 드라이버 출력 처리에서 오는 것으로 보이지만 **정확한 규칙은
///   확정하지 않았다.**
///
/// 그래서 판정은 한 방향으로만 쓴다 — **모자라면 데이터를 흘린 것**이고, 남는 것은
/// 정상이다. 처리량은 소화한 바이트와 보낸 바이트 두 기준으로 모두 찍으므로 이 오차가
/// platform 비교를 왜곡하지 않는다.
///
/// 그래서 판정은 한 방향으로만 쓴다 — **모자라면 데이터를 흘린 것**이고, 남는 것은
/// 정상이다. 처리량은 실제 소화한 바이트로 계산하므로 이 오차에 영향받지 않는다.
///
/// Windows 는 `null` 이다 — ConPTY 가 자식 출력에 자기 시퀀스를 끼워 넣어서 이렇게
/// 계산할 수 있는 종류가 아니다. 실측이 그것을 뒷받침한다: 초과분이 `plain` +1.3 % ·
/// `ansi` +1.0 % 인데 **`cjk` 는 +25.6 %** 이고, `readloop` 호출 수도 1,026 → 6,922 로
/// 뛴다 (wide char 에서 시퀀스를 훨씬 많이 끼워 넣고 조각도 잘게 쪼갠다 — 원인 미확정).
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

// --- command: scrollback ---

/// 구간 수 상한. 리포트를 고정 버퍼에 쓰기 때문에 걸어 둔다.
const max_segments = 32;

const Segment = struct {
    bytes: u64,
    ns: u64,
    /// 이 구간이 끝난 시점의 scrollback 줄 수 (화면 밖으로 밀려난 줄 포함).
    scrollback_lines: usize,
    peak_rss: ?u64,
};

/// 대량 출력을 구간으로 나눠 **구간마다 처리 속도를 따로** 잰다 (#278 ①).
///
/// 처리량 명령과 목적이 다르다 — 절대 속도가 아니라 **뒤로 갈수록 느려지는지**를
/// 본다. scrollback 이 쌓이면서 소화 속도가 떨어지면 줄 수에 비례하지 않는 비용이
/// 어딘가 있다는 뜻이고, 그건 오래 켜 둔 터미널에서만 드러나는 종류의 회귀다.
/// 같은 이유로 메모리 최고치도 함께 본다.
///
/// 프레임 예산이 없는 경로 (`pty` 층과 같은 방식) 로 돌린다 — 예산에 눌린 상태에서는
/// 구간 간 차이가 예산에 가려 안 보인다.
fn runScrollback(alloc: std.mem.Allocator, opts: Options) !void {
    var segments: [max_segments]Segment = undefined;
    var segment_count: usize = 0;

    resetCounters();
    var timer = try std.time.Timer.start();

    const session = try ProducerSession.start(alloc, opts);
    defer session.deinit();
    const tab = try session.tab();

    // 구간 경계는 **바이트**로 잡는다. chunk 수로 잡으면 안 된다 — ring pop 은 그 순간
    // ring 에 있는 만큼만 가져오므로 chunk 하나가 64 KiB 가 아니라 평균 1 KiB 정도다
    // (우리가 producer 보다 빨라서 대개 조금씩 비운다). 실측에서 chunk 기준으로 나눴을
    // 때 앞 8 구간이 550 KiB 씩이고 나머지 267 MiB 가 마지막 한 구간에 몰렸다.
    //
    // 누적 바이트는 `perf.drain` 카운터를 리셋하지 않고 읽는다. 원자 load 라 매 루프
    // 읽어도 부담이 없고, 구간 값은 차분으로 낸다.
    const bytes_per_segment = @max(opts.bytes / opts.segments, 1);

    var segment_start_bytes: u64 = 0;
    var segment_start_ns = timer.read();
    var last_data_ns: u64 = 0;

    while (true) {
        const had_data = tab.drainChunkForStress();
        const now_ns = timer.read();

        if (had_data) {
            last_data_ns = now_ns;

            // 마지막 구간은 루프 밖에서 남은 전부를 담는다 — 여기서 닫으면 잔여가
            // 작은 구간으로 따로 떨어져 나와 잡음이 된다.
            const total_bytes = perf.drain.bytes.load(.monotonic);
            if (total_bytes - segment_start_bytes >= bytes_per_segment and
                segment_count + 1 < opts.segments)
            {
                segments[segment_count] = .{
                    .bytes = total_bytes - segment_start_bytes,
                    .ns = now_ns - segment_start_ns,
                    .scrollback_lines = scrollbackLines(tab),
                    .peak_rss = peakRssBytes(),
                };
                segment_count += 1;
                segment_start_bytes = total_bytes;
                segment_start_ns = now_ns;
            }
        } else {
            if (session.exited() and now_ns - last_data_ns > drain_quiet_ns) break;
            std.Thread.yield() catch {};
        }

        if (now_ns > total_timeout_ns) return error.StressTimeout;
    }

    const total_bytes = perf.drain.bytes.load(.monotonic);
    if (total_bytes > segment_start_bytes and segment_count < max_segments) {
        segments[segment_count] = .{
            .bytes = total_bytes - segment_start_bytes,
            .ns = last_data_ns - segment_start_ns,
            .scrollback_lines = scrollbackLines(tab),
            .peak_rss = peakRssBytes(),
        };
        segment_count += 1;
    }

    try reportScrollback(opts, segments[0..segment_count]);
}

/// 화면 밖으로 밀려난 줄까지 포함한 현재 총 줄 수. 앱의 스크롤바가 쓰는 것과 같은
/// 값이라 (`app_controller.scrollbarHit` 등) 사용자가 보는 스크롤 범위와 일치한다.
fn scrollbackLines(tab: *session_core.Tab) usize {
    return tab.terminal.screens.active.pages.scrollbar().total;
}

/// 프로세스 메모리 최고치. `getrusage` 의 `maxrss` 는 **단위가 OS 마다 다르다** —
/// macOS 는 byte, Linux 는 KiB 로 보고한다 (`getrusage(2)`).
///
/// Windows 는 `null` 이다 — `GetProcessMemoryInfo` 를 따로 불러야 한다. 하네스 자체는
/// Windows 실기에서 확인됐으므로 (#371) 이제 붙일 수 있는 조건이지만, 이 커밋의 범위가
/// 아니라 후속으로 둔다. 리포트는 그 자리에 `(unavailable)` 을 찍는다.
fn peakRssBytes() ?u64 {
    if (builtin.os.tag == .windows) return null;
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    if (usage.maxrss <= 0) return null;
    const raw: u64 = @intCast(usage.maxrss);
    return if (builtin.os.tag == .macos) raw else raw * 1024;
}

fn reportScrollback(opts: Options, segments: []const Segment) !void {
    var buf: [8192]u8 = undefined;
    var w = Report{ .buf = &buf };
    const mib = 1024.0 * 1024.0;

    w.print("=== tildaz stress: scrollback ===\n", .{});
    w.print("workload      {s}\n", .{@tagName(opts.workload_kind)});
    w.print("grid          {d}x{d}\n", .{ opts.cols, opts.rows });
    w.print("scrollback    {d} lines (config limit)\n", .{opts.scroll_lines});
    w.print("requested     {d} bytes ({d:.1} MiB)\n", .{
        opts.bytes,
        @as(f64, @floatFromInt(opts.bytes)) / mib,
    });
    w.print("build         {s} simd={} version={s}\n", .{
        @tagName(builtin.mode),
        build_options.simd,
        build_options.version,
    });
    w.print("platform      {s} {s}\n", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    w.print("\n", .{});

    w.print("segment  consumed      MiB/s    scrollback lines   peak RSS\n", .{});
    var first_rate: f64 = 0;
    var worst_rate: f64 = 0;
    for (segments, 0..) |seg, i| {
        const seconds = @as(f64, @floatFromInt(seg.ns)) / std.time.ns_per_s;
        const rate = if (seconds > 0) (@as(f64, @floatFromInt(seg.bytes)) / mib) / seconds else 0;
        if (i == 0) {
            first_rate = rate;
            worst_rate = rate;
        } else if (rate < worst_rate) {
            worst_rate = rate;
        }

        w.print("{d: <8} {d: <13} {d: <8.1} {d: <18} ", .{ i + 1, seg.bytes, rate, seg.scrollback_lines });
        if (seg.peak_rss) |rss| {
            w.print("{d:.1} MiB\n", .{@as(f64, @floatFromInt(rss)) / mib});
        } else {
            w.print("(unavailable)\n", .{});
        }
    }
    w.print("\n", .{});

    // 뒤 구간이 첫 구간보다 크게 느려지면 줄 수에 비례하지 않는 비용이 있다는 신호다.
    // 다만 이 하네스는 같은 조건 재실행도 ±15 % 흔들리므로 한 번의 결과로 단정하지
    // 않는다 — 여러 번 돌려 같은 방향이 나오는지 본다.
    if (first_rate > 0) {
        const ratio = worst_rate / first_rate;
        w.print("slowest / first segment  {d:.2}x", .{ratio});
        if (ratio < 0.7) {
            w.print("  ← 뒤 구간이 크게 느려졌다. 여러 번 돌려 확인할 것\n", .{});
        } else {
            w.print("  (측정 흔들림 범위)\n", .{});
        }
    }

    try std.fs.File.stdout().writeAll(w.slice());
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
    w.print("throughput    {d:.1} MiB/s (end to end, 소화한 바이트 기준)\n", .{throughput});

    // PTY 를 지나면 소화한 바이트가 보낸 것보다 많다. 그 초과분이 platform 마다 성질이
    // 전혀 달라서 (Linux 0 %, macOS 0.001 %, Windows 는 cjk 에서 25 %) 소화 기준 값만
    // 찍으면 **초과가 큰 platform 이 유리하게 보인다.** 워크로드를 같게 준 것이 비교의
    // 전제이므로 요청 기준 값도 함께 찍는다.
    if (result.consumed > opts.bytes and seconds > 0) {
        const requested_mib = @as(f64, @floatFromInt(opts.bytes)) / mib;
        const inflation = (@as(f64, @floatFromInt(result.consumed - opts.bytes)) /
            @as(f64, @floatFromInt(opts.bytes))) * 100.0;
        w.print("              {d:.1} MiB/s (보낸 {d:.1} MiB 기준 — PTY 가 {d:.2} % 부풀림)\n", .{
            requested_mib / seconds,
            requested_mib,
            inflation,
        });
    }

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
        // 기본값을 그대로 쓰면 고주사율 화면에서 크게 어긋난다. 실측: 120 Hz 화면을 60 으로
        // 모사했더니 ansi 가 103 MiB/s 로 나왔는데 (예산 초과 86 %), 120 으로 고치자
        // 138 MiB/s · 초과 39 % 였고 실제 앱 값 (136 MiB/s) 과 거의 같았다. 120 Hz 는 프레임
        // 간격이 8.33 ms 라 8 ms 예산이 프레임 전체에 가깝다 — 60 Hz 의 48 % 와 성질이 다르다.
        if (!split.fps_explicit) {
            w.print(
                "  ⚠ --fps 를 안 줘서 {d} 으로 가정했어요. 재는 화면의 재생률과 다르면\n" ++
                    "    숫자가 크게 어긋나요 (ProMotion 등 고주사율 화면은 120).\n",
                .{split.fps},
            );
        }
    }
    w.print("\n", .{});

    if (result.counters) |counters| {
        // readloop 과 push 는 PTY read thread 에서 도므로 위 벽시계와 나란히 흐른다 —
        // drain / parse 와 더하면 안 된다. drain 은 ring pop + parse 를 모두 포함한다.
        w.print("--- perf counters (readloop/push 는 별 thread) ---\n", .{});

        // readloop 의 시간은 **platform 간 비교가 안 된다.** POSIX 는 poll 대기를 빼고
        // read 복사만 재는데 Windows 는 유휴 대기를 포함한다 (#254 결정,
        // `terminal/posix/pty.zig` 의 readLoop 주석). 어느 쪽인지 옆에 적어 둔다.
        writeCounter(&w, "readloop", counters.readloop, .{
            .note = if (builtin.os.tag == .windows) "유휴 대기 포함" else "read 복사만",
        });
        // push 의 `extra` 는 ring 이 가득 차서 양보한 횟수다. 이 값이 크면 **우리가
        // 소화보다 느려서 read thread 가 대기했다는 뜻** — producer 까지 압력이 갔다.
        // 실측에서 Linux frame cjk 의 push 시간이 drain 보다 컸는데 그 정체가 이것이다.
        writeCounter(&w, "push", counters.push, .{ .yields = counters.push[3] });
        writeCounter(&w, "drain", counters.drain, .{});
        writeCounter(&w, "parse", counters.parse, .{ .show_bytes = false });
    } else {
        w.print("--- perf counters ---\nnot instrumented on this layer\n", .{});
    }

    try std.fs.File.stdout().writeAll(w.slice());
}

const CounterOpts = struct {
    /// `parse` 는 시간만 재고 byte 를 세지 않아서 (`perf.addTimed`) 0 을 찍으면 "0 byte
    /// 를 파싱했다" 로 읽힌다. 그때는 칸을 비운다.
    show_bytes: bool = true,
    /// ring 이 가득 차서 양보한 횟수 (`push` 만 의미가 있다).
    yields: ?u64 = null,
    /// 그 카운터를 읽는 방법에 조건이 있으면 적는다.
    note: ?[]const u8 = null,
};

fn writeCounter(w: *Report, name: []const u8, c: [4]u64, opts: CounterOpts) void {
    const ms = @as(f64, @floatFromInt(c[1])) / std.time.ns_per_ms;
    if (opts.show_bytes) {
        w.print("{s: <9} calls={d: <8} bytes={d: <12} ms={d:.3}", .{ name, c[0], c[2], ms });
    } else {
        w.print("{s: <9} calls={d: <8} {s: <18} ms={d:.3}", .{ name, c[0], "", ms });
    }
    if (opts.yields) |yields| w.print(" yields={d}", .{yields});
    if (opts.note) |note| w.print("  ({s})", .{note});
    w.print("\n", .{});
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
