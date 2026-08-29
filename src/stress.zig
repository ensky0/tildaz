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
const pane_layout = @import("pane_layout.zig");
const terminal = @import("terminal.zig");
const workload = @import("stress/workload.zig");
const runtime = @import("runtime.zig");
const Runtime = runtime.Runtime;
const Timer = runtime.Timer;

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
/// 출력을 끝내고 이 밀리초만큼 살아 있는다 — 하네스의 `--capture` 가 창을 찍을 시간을
/// 준다 (#381). producer 가 끝나면 터미널이 곧바로 창을 닫아서, 이게 없으면 찍을 창이
/// 없다. **Windows 는 `sh -c "…; sleep 3"` 으로 대신할 수 없다** — alacritty · wezterm 이
/// MSYS sh 를 ConPTY 로 띄우지 못해 하네스가 producer 를 직접 실행하기 때문이다
/// (`dist/stress/compare-terminals.sh` 의 `run_terminal_win` 주석). 그래서 producer 안에 둔다.
///
/// 기다리는 것은 **timing 파일을 쓴 뒤**다. 하네스는 timing 파일을 보고 측정이 끝난 것을
/// 알고 캡처를 시작하므로, 순서가 반대면 하네스가 창이 닫힌 뒤에 찍으러 온다.
const env_hold_ms = "TILDAZ_STRESS_HOLD_MS";
/// producer 가 이 그리드가 될 때까지 기다렸다가 출력을 시작한다 (`ProducerRequest.target_grid`).
const env_grid = "TILDAZ_STRESS_GRID";

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

pub fn main(init: std.process.Init) !void {
    const rt: Runtime = .fromInit(init);
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

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // producer 모드는 argv 가 아니라 환경변수로 판정한다 (위 문서 주석).
    if (try producerRequest(rt, alloc)) |req| return produce(rt, req);

    // #451 — `process.argsAlloc` ➡️ `Init.minimal.args.toSlice`. arena 는 프로세스 수명이라
    // (`Init.arena` 주석) 예전 `argsFree` 가 하던 일이 없다.
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // 파싱에 sentinel 이 필요 없다. 느슨한 타입으로 보면 테스트가 문자열 리터럴 배열을
    // 그대로 넘길 수 있다.
    const argv: []const []const u8 = @ptrCast(args);

    // #451 — `parseArgs` 의 에러 집합은 `error{Usage}` 하나다. 0.16 은 에러 switch 의
    // 도달 불가 `else` 를 컴파일 오류로 잡는다 (릴리즈 노트 *switch* 절).
    const opts = parseArgs(argv) catch |err| switch (err) {
        error.Usage => {
            try printUsage(rt);
            std.process.exit(2);
        },
    };

    switch (opts.command) {
        .throughput => switch (opts.layer) {
            .parser => try runParser(rt, alloc, opts),
            .pty => try runPty(rt, alloc, opts),
            .frame => try runFrame(rt, alloc, opts),
        },
        .scrollback => try runScrollback(rt, alloc, opts),
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
    /// timing 을 쓴 뒤 이만큼 더 살아 있는다 (`env_hold_ms`). 0 이면 곧바로 끝낸다.
    hold_ms: u32 = 0,
    /// 있으면 tty 그리드가 이 값이 될 때까지 기다렸다가 출력을 시작한다 (`env_grid`).
    ///
    /// **왜 필요한가** — 일부 터미널은 셸을 spawn 한 **뒤에** 창 크기에 맞춰 PTY 를 resize
    /// 한다. 실측으로 foot 은 80x24 로 시작해 120x40 이 되고 ghostty 는 119x39 로 시작한다.
    /// 그러면 producer 가 초반을 다른 열 수로 출력해서 줄바꿈 횟수가 달라지고, 그 회차는
    /// 다른 대상과 비교할 수 없다. 전후 그리드를 둘 다 남기는 것만으로는 **얼마나 오염됐는지**
    /// 를 알 수 없다 (전환 시점이 없다) — 그래서 아예 기다린다.
    target_grid: ?Grid = null,
};

/// `target_grid` 를 기다린 상한. 넘으면 그대로 진행하고 timing 에 대기 시간이 남는다 —
/// 조용히 포기하지 않고, 어느 대상이 목표 그리드에 아예 도달하지 않는지 드러나게 한다.
const grid_wait_limit_ms: u64 = 2000;

/// 환경변수 두 개가 다 있고 값이 유효할 때만 producer 모드다. 하나라도 빠지거나
/// 이상하면 일반 모드로 두어, 실수로 켜진 환경변수 때문에 조용히 다른 일을 하지
/// 않게 한다. timing 파일은 선택이다.
fn producerRequest(rt: Runtime, alloc: std.mem.Allocator) !?ProducerRequest {
    const kind_name = rt.envAlloc(alloc, env_workload) catch return null;
    defer alloc.free(kind_name);
    const bytes_text = rt.envAlloc(alloc, env_bytes) catch return null;
    defer alloc.free(bytes_text);

    const kind = workload.Kind.parse(kind_name) orelse return null;
    const bytes = std.fmt.parseInt(u64, bytes_text, 10) catch return null;

    // 호출자가 free 하지 않는다 — producer 는 이 값을 쓰고 곧 종료한다.
    const timing_path = rt.envAlloc(alloc, env_timing_file) catch null;

    // 값이 이상하면 **0 으로 본다** — 기다리지 않는 쪽이 안전하다. 창이 남으면 다음 회차와
    // CPU 를 나눠 써서 측정을 오염시킨다.
    var hold_ms: u32 = 0;
    if (rt.envAlloc(alloc, env_hold_ms) catch null) |text| {
        defer alloc.free(text);
        hold_ms = std.fmt.parseInt(u32, text, 10) catch 0;
    }

    // `120x40` 형식. 이상하면 **없는 것으로 본다** — 기다리지 않는 쪽이 안전하다.
    var target_grid: ?Grid = null;
    if (rt.envAlloc(alloc, env_grid) catch null) |text| {
        defer alloc.free(text);
        target_grid = parseGrid(text);
    }

    return .{
        .kind = kind,
        .bytes = bytes,
        .timing_path = timing_path,
        .hold_ms = hold_ms,
        .target_grid = target_grid,
    };
}

fn parseGrid(text: []const u8) ?Grid {
    const x = std.mem.findScalar(u8, text, 'x') orelse return null;
    const cols = std.fmt.parseInt(u16, text[0..x], 10) catch return null;
    const rows = std.fmt.parseInt(u16, text[x + 1 ..], 10) catch return null;
    if (cols == 0 or rows == 0) return null;
    return .{ .cols = cols, .rows = rows };
}

/// 그리드가 `target` 이 될 때까지 기다리고, 기다린 시간 (ms) 을 돌려준다.
///
/// 상한 (`grid_wait_limit_ms`) 을 넘으면 그대로 진행한다. 도달하지 못하는 경우가 실제로
/// 있어서다 — 창 크기 옵션이 무시되거나 폰트 때문에 셀 수가 목표와 다를 수 있다. 그때는
/// 기존대로 `cols_start` / `cols` 비교가 그 회차를 걸러낸다.
fn waitForGrid(rt: Runtime, target: Grid) u64 {
    // #451 — `time.Timer` ➡️ `runtime.Timer` (`Io.Timestamp` 기반). 시계 조회가 더 이상
    // 실패하지 않으므로 예전의 `catch return 0` 분기가 사라진다.
    var timer: Timer = .start(rt);
    const limit_ns = grid_wait_limit_ms * std.time.ns_per_ms;
    while (true) {
        const now = producerGrid() orelse break;
        if (now.cols == target.cols and now.rows == target.rows) break;
        if (timer.read() >= limit_ns) break;
        // 5 ms 는 resize 가 도는 주기보다 충분히 짧다 (실측에서 대기가 수십 ms 규모다).
        rt.sleepNs(5 * std.time.ns_per_ms);
    }
    return timer.read() / std.time.ns_per_ms;
}

/// 정해진 바이트를 stdout 에 쏟고 끝낸다. stdout 은 PTY slave 라 부모의 read
/// thread (또는 우리를 띄운 다른 터미널) 가 그대로 받는다.
fn produce(rt: Runtime, req: ProducerRequest) !void {
    if (builtin.os.tag == .windows) {
        // producer 의 stdout 은 ConPTY 콘솔이다. 출력 코드페이지를 UTF-8 로 맞춰 cjk 가
        // 콘솔 기본 CP (CP949 등) 로 깨지지 않게 한다 (위 SetConsoleOutputCP 주석).
        _ = SetConsoleOutputCP(65001);
    }
    var gen: workload.Generator = .{ .kind = req.kind };
    var buf: [chunk_size]u8 = undefined;
    const out = std.Io.File.stdout();

    // 그리드를 **출력 전후 두 번** 읽는다. 한 번만 읽으면 어느 쪽이든 틀린다:
    //
    // - 시작 시점만 읽으면 **resize race** 에 걸린다. 일부 터미널 (실측: ghostty · kitty)
    //   은 셸을 spawn 한 뒤 창 크기에 맞춰 PTY 를 resize 하므로, 그 전에 읽으면 초기값을
    //   본다 (ghostty 에서 100x30 을 줬는데 50x6 으로 읽혔다). alacritty 는 spawn 전에
    //   크기가 확정돼서 이 문제가 없다.
    // - 끝 시점만 읽으면 창이 닫히는 중일 수 있다.
    //
    // 둘을 다 남기고 판정은 호출자에게 맡긴다. 다르면 그 측정은 그리드가 흔들린 것이다.
    //
    // 목표 그리드를 받았으면 그 전에 **기다린다** (`target_grid` 주석). 기다린 뒤에 읽어야
    // `grid_start` 가 실제로 출력한 그리드와 같다.
    const grid_wait_ms = if (req.target_grid) |t| waitForGrid(rt, t) else 0;
    const grid_start = producerGrid();

    var timer: Timer = .start(rt);
    var left = req.bytes;
    while (left > 0) {
        const n = @min(buf.len, left);
        _ = gen.read(buf[0..n]);
        try out.writeStreamingAll(rt.io, buf[0..n]);
        left -= n;
    }
    const elapsed_ns = timer.read();
    const grid_end = producerGrid();

    if (req.timing_path) |path| {
        writeTiming(rt, path, req, elapsed_ns, grid_start, grid_end, grid_wait_ms) catch {};
    }

    // 하네스의 `--capture` 가 창을 찍을 시간. timing 을 쓴 **뒤**여야 한다 (`env_hold_ms`).
    if (req.hold_ms > 0) rt.sleepNs(@as(u64, req.hold_ms) * std.time.ns_per_ms);
}

const Grid = struct { cols: u16, rows: u16 };

// cjk 워크로드는 UTF-8 바이트다. producer 가 콘솔 출력 코드페이지를 UTF-8 로 맞추지 않으면
// 콘솔 기본값 (한국어 Windows 는 CP949) 으로 깨져 렌더돼, 화면도 깨지고 cjk 처리량도 실제
// wide-cell 부하가 아니게 된다 (Windows 실기: 다섯 터미널 모두 cjk 가 깨졌다). produce 가
// 시작할 때 한 번 65001 로 맞춘다. `std.os.windows.kernel32` 에 없어 직접 선언한다.
extern "kernel32" fn SetConsoleOutputCP(wCodePageID: c_uint) callconv(.c) c_int;

// #451 — 0.16 이 `std.os.windows` 에서 `CONSOLE_SCREEN_BUFFER_INFO` 와 kernel32 래퍼를
// 걷어냈다 (릴리즈 노트 *Completed Migration to NtDll* — std 에 남은 kernel32 extern 은
// `CreateProcessW` 뿐이다). 릴리즈 노트가 지정한 두 방향 (*"Go higher: use std.Io"* /
// *"Go lower"*) 중 아래쪽이다 — `Io` 에 콘솔 격자를 묻는 길이 없고, 이 파일이 이미 위의
// `SetConsoleOutputCP` 를 같은 방식으로 선언하고 있다.
const COORD = extern struct { X: i16, Y: i16 };
const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };
const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: u16,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};
extern "kernel32" fn GetConsoleScreenBufferInfo(
    hConsoleOutput: std.os.windows.HANDLE,
    lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO,
) callconv(.c) std.os.windows.BOOL;

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
        var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        const handle = std.Io.File.stdout().handle;
        if (!GetConsoleScreenBufferInfo(handle, &info).toBool()) return null;
        const cols: i32 = @as(i32, info.srWindow.Right) - info.srWindow.Left + 1;
        const rows: i32 = @as(i32, info.srWindow.Bottom) - info.srWindow.Top + 1;
        if (cols <= 0 or rows <= 0) return null;
        return .{ .cols = @intCast(cols), .rows = @intCast(rows) };
    }

    var ws: std.posix.winsize = undefined;
    const fd = std.Io.File.stdout().handle;
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
    rt: Runtime,
    path: []const u8,
    req: ProducerRequest,
    elapsed_ns: u64,
    grid_start: ?Grid,
    grid_end: ?Grid,
    grid_wait_ms: u64,
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
    // 목표 그리드를 기다린 시간. 크면 그 대상이 늦게 resize 한다는 뜻이고, 상한
    // (`grid_wait_limit_ms`) 에 붙어 있으면 목표에 아예 도달하지 못한 것이다.
    w.print("grid_wait_ms={d}\n", .{grid_wait_ms});
    // 마지막 줄이 `rows` 다 — 읽는 쪽이 파일이 끝까지 쓰였는지 이 줄로 판단한다.
    if (grid_end) |g| {
        w.print("cols={d}\nrows={d}\n", .{ g.cols, g.rows });
    } else {
        w.print("cols=0\nrows=0\n", .{});
    }

    const file = try std.Io.Dir.cwd().createFile(rt.io, path, .{});
    defer file.close(rt.io);
    try file.writeStreamingAll(rt.io, w.slice());
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
    /// #483 6단계 — `frame` 층에서 활성 탭을 N 개 pane 으로 갈라 pane 마다 producer 하나 (드레인 예산
    /// 재검토 측정). 1 이면 이전과 같다.
    panes: u32 = 1,
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
        } else if (std.mem.eql(u8, key, "--panes")) {
            opts.panes = std.fmt.parseInt(u32, value, 10) catch return error.Usage;
            if (opts.panes == 0 or opts.panes > pane_layout.MAX_PANES_PER_TAB) return error.Usage;
        } else {
            return error.Usage;
        }
    }
    return opts;
}

fn printUsage(rt: Runtime) !void {
    try std.Io.File.stdout().writeStreamingAll(
        rt.io,
        \\usage: zig build stress -- <throughput | scrollback> [options]
        \\
        \\  throughput   how fast bulk output is consumed
        \\  scrollback   whether the rate holds as scrollback accumulates (#278)
        \\
        \\  --layer      parser | pty | frame  (default: parser, throughput only)
        \\  --workload   (default: plain)
        \\                 plain | ansi | cjk
        \\                 hangul | emoji_vs16 | skintone | zwj
        \\                     one kind per line — best case for any cache
        \\                 hangul_varied | emoji_vs16_varied |
        \\                 skintone_varied | zwj_varied
        \\                     same path and line bytes, many kinds — worst case
        \\  --mb         MiB to push           (default: 64)
        \\  --cols       grid columns          (default: 120)
        \\  --rows       grid rows             (default: 40)
        \\  --scrollback scrollback lines      (default: config default)
        \\  --fps        frame layer only      (default: 60)
        \\  --segments   scrollback only       (default: 8)
        \\  --panes      frame layer only      (default: 1; 2..16 = split panes, #483)
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
    /// 프레임 예산 (`DRAIN_FRAME_BUDGET_NS`) 을 넘긴 프레임 수. 리포트가 값을 함께 찍는다.
    over_budget: u64,
    /// #483 6단계 — pane 수 · pane 별 producer 종료 시각 (프레임 단위, timer 절대값) · 드레인 1 회 최장 점유.
    panes: u32 = 1,
    finished: u32 = 0,
    finish_ns: [pane_layout.MAX_PANES_PER_TAB]u64 = [_]u64{0} ** pane_layout.MAX_PANES_PER_TAB,
    max_drain_ns: u64 = 0,
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
fn runParser(rt: Runtime, alloc: std.mem.Allocator, opts: Options) !void {
    var term = try session_core.initVtTerminal(rt, alloc, opts.cols, opts.rows, opts.scroll_lines, null);
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    var gen: workload.Generator = .{ .kind = opts.workload_kind };
    var buf: [chunk_size]u8 = undefined;

    var timer: Timer = .start(rt);

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
    try report(rt, opts, .{
        .consumed = opts.bytes,
        .elapsed_ns = elapsed_ns,
        .parser_split = .{ .parse_ns = parse_ns, .generate_ns = generate_ns },
    });
}

// --- layer: pty ---

const ExitState = struct {
    exited: std.atomic.Value(bool) = .init(false),
    /// #483 6단계 — pane 마다 producer 가 하나라 마지막 pane 이 끝날 때 `exited`.
    exited_count: std.atomic.Value(u32) = .init(0),
    total: u32 = 1,
};

fn onTabExit(_: usize, userdata: ?*anyopaque) void {
    const state: *ExitState = @ptrCast(@alignCast(userdata.?));
    const n = state.exited_count.fetchAdd(1, .acq_rel) + 1;
    if (n >= state.total) state.exited.store(true, .release);
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

    fn start(rt: Runtime, alloc: std.mem.Allocator, opts: Options) !*ProducerSession {
        const self = try alloc.create(ProducerSession);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .shell_command = undefined };

        var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        // #451 — `fs.selfExePath` ➡️ `std.process.executablePath` (길이를 돌려준다).
        const exe_len = try std.process.executablePath(rt.io, &exe_buf);
        self.shell_command = try toShellCommand(alloc, exe_buf[0..exe_len]);
        errdefer freeShellCommand(alloc, self.shell_command);

        const bytes_text = try std.fmt.bufPrint(&self.bytes_text, "{d}", .{opts.bytes});
        self.extra_env = .{
            .{ .name = env_workload, .value = @tagName(opts.workload_kind) },
            .{ .name = env_bytes, .value = bytes_text },
        };

        self.core = session_core.SessionCore.init(
            rt,
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
        self.state.total = opts.panes;
        try self.core.createTab(opts.cols, opts.rows);
        // #483 6단계 — `--panes N`: 활성 탭을 N 개 pane 으로 갈라 pane 마다 producer 하나. 합성 metrics
        // (셀 9×19 · pad 6 · scrollbar 10 · 분할선 1) 로 영역을 cols×rows 격자 하나 크기로 잡으므로 pane 들의
        // 격자를 합치면 대략 pane 하나일 때와 같다 — 파서 일은 비슷하고 pane 수만 축이 된다. 균등 배치.
        if (opts.panes > 1) {
            const m: pane_layout.Metrics = .{ .cell_w = 9, .cell_h = 19, .pad = 6, .scrollbar_w = 10, .separator_w = 1 };
            const area: pane_layout.Rect = .{ .x = 0, .y = 0, .w = @as(i32, opts.cols) * 9 + 22, .h = @as(i32, opts.rows) * 19 + 12 };
            var i: u32 = 1;
            while (i < opts.panes) : (i += 1) {
                // 가장 큰 pane 을 골라 그 모양대로 가른다 (넓으면 오른쪽, 높으면 아래 — `+` Alt+클릭의 auto).
                // 활성 pane 만 계속 가르면 (사용자가 하듯) 깊은 트리가 되어 16 pane 에서 `TooSmall` 에 걸린다.
                const group = self.core.activeGroup() orelse return error.NoTab;
                var buf: [pane_layout.MAX_PANES_PER_TAB]pane_layout.PaneRect = undefined;
                var biggest: ?pane_layout.PaneRect = null;
                for (group.layout(area, m, &buf)) |pr| {
                    if (biggest == null or pr.rect.w * pr.rect.h > biggest.?.rect.w * biggest.?.rect.h) biggest = pr;
                }
                const pr = biggest orelse return error.NoTab;
                _ = self.core.setActivePane(pr.pane);
                try self.core.splitActive(if (pr.rect.w >= pr.rect.h) .right else .down, area, m);
                // 분할마다 균등화 — 새 pane 만 계속 가르면 1/2 · 1/4 · 1/8 로 줄어 `TooSmall` 에 걸린다.
                self.core.equalizeActive(area, m);
            }
        }
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

fn runPty(rt: Runtime, alloc: std.mem.Allocator, opts: Options) !void {
    resetCounters();
    var timer: Timer = .start(rt);

    const session = try ProducerSession.start(rt, alloc, opts);
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

    try report(rt, opts, .{
        // drain 카운터의 bytes 가 우리가 VT 로 넘긴 실제 바이트다.
        .consumed = counters.drain[2],
        .expected = expectedPtyBytes(opts),
        .elapsed_ns = last_data_ns - start_ns,
        .spawn_ns = start_ns,
        .counters = counters,
    });
}

// --- layer: frame ---

/// 프레임당 1 회 드레인을 모사한다 — `drainOutputForRender` 를 `--fps` 주기로 한 번씩 부르고,
/// 그 안의 `drainFrame` 이 `session_core.SessionCore.DRAIN_FRAME_BUDGET_NS` 만 파싱한다.
/// 그래서 처리량이 파서 상한이 아니라 `예산 / 프레임 간격` 으로 눌린다.
///
/// ⚠️ **이 층은 더 이상 앱과 같지 않다.** 사양 A (#387) 이후 세 host 는 **프레임 사이에도**
/// 드레인하므로 (SPEC §13.1) 실제 앱의 duty 는 이 층보다 훨씬 높다 (Windows ② 60 Hz 실측:
/// 이 층에 해당하는 구조가 duty 50.6~51.4 %, 실제 앱은 91.5~92.2 %). 그러니 이 층의 숫자는
/// **"프레임에 묶였을 때의 하한"** 으로 읽는다. 앱의 실제 배분은 perf 덤프
/// (`Ctrl+Shift+F12` / `Shift+Cmd+F12`) 로 본다 — 후속 이슈에서 다룰 갭이다.
///
/// macOS 는 CADisplayLink (`NSWindow.displayLink`) 가 vsync 마다 main thread 에서
/// 부르고, Linux 는 poll loop, Windows 는 app_controller 의 프레임 경로다. 여기서는
/// 그 주기를 `--fps` 로 모사한다.
///
/// **렌더는 하지 않는다.** 이 층이 재는 것은 "프레임 예산이 파싱을 어디까지 누르는가"
/// 이고, 실제 앱은 여기에 렌더 시간까지 더해진다. 즉 이 숫자는 체감의 **상한**이다.
fn runFrame(rt: Runtime, alloc: std.mem.Allocator, opts: Options) !void {
    resetCounters();
    var timer: Timer = .start(rt);

    const session = try ProducerSession.start(rt, alloc, opts);
    defer session.deinit();

    const frame_ns = std.time.ns_per_s / @as(u64, opts.fps);
    var next_frame_ns: u64 = frame_ns;

    var frames: u64 = 0;
    var over_budget: u64 = 0;
    var first_data_ns: ?u64 = null;
    var last_data_ns: u64 = 0;
    var max_drain_ns: u64 = 0;
    var finish_ns: [pane_layout.MAX_PANES_PER_TAB]u64 = [_]u64{0} ** pane_layout.MAX_PANES_PER_TAB;
    var finished: u32 = 0;

    while (true) {
        const before_ns = timer.read();
        const had_output = session.core.drainOutputForRender();
        const after_ns = timer.read();

        frames += 1;
        if (after_ns - before_ns > frame_budget_ns) over_budget += 1;
        max_drain_ns = @max(max_drain_ns, after_ns - before_ns);
        // #483 6단계 — pane 별 producer 종료 시각 (이 프레임에서 처음 본 순간).
        const exited_now = session.state.exited_count.load(.acquire);
        while (finished < exited_now and finished < finish_ns.len) : (finished += 1) finish_ns[finished] = after_ns;

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
            rt.sleepNs(next_frame_ns - now_ns);
            next_frame_ns += frame_ns;
        } else {
            next_frame_ns = now_ns + frame_ns;
        }
    }

    const counters = takeCounters();
    const start_ns = first_data_ns orelse return error.NoOutput;

    try report(rt, opts, .{
        .consumed = counters.drain[2],
        .expected = if (expectedPtyBytes(opts)) |e| e * opts.panes else null,
        .elapsed_ns = last_data_ns - start_ns,
        .spawn_ns = start_ns,
        .counters = counters,
        .frame_split = .{
            .fps = opts.fps,
            .fps_explicit = opts.fps_explicit,
            .frames = frames,
            .over_budget = over_budget,
            .panes = opts.panes,
            .finished = finished,
            .finish_ns = finish_ns,
            .max_drain_ns = max_drain_ns,
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
/// - **Windows 도 같은 공식이 맞는다** (#385 에서 실측으로 확정). ConPTY 콘솔이 `\n` 을
///   `\r\n` 으로 바꾸는 것이 초과분의 대부분이고, 그 위에 **21~23 byte** 협상 preamble
///   (`ESC[1t` 4 + `ESC[c` `ESC[?1004h` `ESC[?9001h` 19) 만 얹힌다. 64 KiB `cjk` 실측:
///   producer 가 정확히 65,536 byte (`LF` 921 · `CR` 0) 를 쓰고 수신은 66,480 byte =
///   `65,536 + 921 + 23` 으로 맞는다. 64 MiB 는 `plain` · `ansi` 가 `+23`, `cjk` 가 `+21`
///   인데 그 **2 byte 차이는 확인하지 않았다** — `expected` 는 하한이라 판정에 무해하다.
///
///   이전 주석은 여기서 `null` 을 돌려주며 *"ConPTY 가 시퀀스를 끼워 넣어 계산할 수 없다"*
///   고 했고 근거로 `cjk` +25.6 % · `readloop` 6,922 회를 들었는데, **그 측정은 producer 의
///   콘솔 출력 코드페이지가 UTF-8 이 아니던 때의 것**이다 (한국어 Windows 는 CP949 →
///   non-ASCII 가 재인코딩되며 부풀고 조각이 잘게 쪼개졌다). `944957a` 로 고친 뒤 재측정하니
///   `cjk` +1.41 % · `readloop` 595 회로, `plain` +1.25 % · `ansi` +0.98 % 와 같은 수준이다.
///   ASCII 는 코드페이지에 불변이라 그때도 `plain` · `ansi` 만 정상이던 것이 이 설명과 맞는다.
fn expectedPtyBytes(opts: Options) ?u64 {
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
fn runScrollback(rt: Runtime, alloc: std.mem.Allocator, opts: Options) !void {
    var segments: [max_segments]Segment = undefined;
    var segment_count: usize = 0;

    resetCounters();
    var timer: Timer = .start(rt);

    const session = try ProducerSession.start(rt, alloc, opts);
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

    try reportScrollback(rt, opts, segments[0..segment_count]);
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

fn reportScrollback(rt: Runtime, opts: Options, segments: []const Segment) !void {
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

    try std.Io.File.stdout().writeStreamingAll(rt.io, w.slice());
}

// --- 리포트 ---

fn report(rt: Runtime, opts: Options, result: Result) !void {
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

    // PTY 를 지나면 소화한 바이트가 보낸 것보다 많다. 소화 기준 값만 찍으면 **초과가 큰
    // platform 이 유리하게 보인다.** 워크로드를 같게 준 것이 비교의 전제이므로 요청 기준
    // 값도 함께 찍는다.
    //
    // **초과분을 "PTY 가 부풀림" 이라고 부르지 않는다** (#385). 초과분의 대부분은 `\n` →
    // `\r\n` 개행 변환이고 (POSIX `ONLCR`, Windows 는 ConPTY 콘솔), 그건 `expected` 줄이
    // 이미 계산해 둔 몫이다. 예전 문구가 이 전부를 PTY 탓으로 돌려서, 개행 변환을
    // "ConPTY 가 시퀀스를 끼워 넣는다" 로 읽게 만들었다 — 그것이 #385 의 출발점이었다.
    if (result.consumed > opts.bytes and seconds > 0) {
        const requested_mib = @as(f64, @floatFromInt(opts.bytes)) / mib;
        const inflation = (@as(f64, @floatFromInt(result.consumed - opts.bytes)) /
            @as(f64, @floatFromInt(opts.bytes))) * 100.0;
        w.print("              {d:.1} MiB/s (보낸 {d:.1} MiB 기준 — 수신 초과 {d:.2} %: 개행 변환 + PTY preamble)\n", .{
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
        w.print("  drain max   {d:.2} ms (한 번 호출의 최장 점유)\n", .{
            @as(f64, @floatFromInt(split.max_drain_ns)) / std.time.ns_per_ms,
        });
        // #483 6단계 — pane 마다 producer 하나. 종료 시각의 퍼짐이 pane 간 공정성이다.
        if (split.panes > 1) {
            w.print("  panes       {d} (pane 마다 producer 하나, 합쳐 {d} MiB)\n", .{ split.panes, opts.bytes / (1024 * 1024) * split.panes });
            const base = result.spawn_ns orelse 0;
            for (split.finish_ns[0..split.finished], 0..) |t, i| {
                w.print("  pane exit   #{d} at {d:.1} ms\n", .{ i + 1, @as(f64, @floatFromInt(t -| base)) / std.time.ns_per_ms });
            }
        }
        // 기본값을 그대로 쓰면 고주사율 화면에서 크게 어긋난다. 실측 (당시 예산 8 ms):
        // 120 Hz 화면을 60 으로 모사했더니 ansi 가 103 MiB/s 로 나왔는데 (예산 초과 86 %),
        // 120 으로 고치자 138 MiB/s · 초과 39 % 였다. 예산이 프레임 간격에서 차지하는 비율이
        // `예산 / 프레임간격` 이라 주사율이 결과를 지배한다.
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

        // #394 — 세 platform 모두 유휴 대기를 뺀 **read 복사 시간**이다 (Windows 도
        // `ERROR_IO_PENDING` 대기를 계측 밖으로 뺐다 — `terminal/windows/pty.zig`).
        // 그래도 **그대로 빼서 비교하면 안 된다.** Windows 의 pending 경로는 커널이
        // 대기 중에 복사를 끝내 그 몫을 우리 스레드에서 잴 수 없어서, `calls` ·
        // `bytes` 는 남고 `ns` 만 빠진다 — 같은 범위이되 Windows 가 과소 계상이다.
        // 어느 쪽인지 옆에 적어 둔다.
        writeCounter(&w, "readloop", counters.readloop, .{
            .note = if (builtin.os.tag == .windows)
                "read 복사만 · pending 분은 커널이 복사해 미계상"
            else
                "read 복사만",
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

    try std.Io.File.stdout().writeStreamingAll(rt.io, w.slice());
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
    // Windows 도 포함한다 — ConPTY 콘솔의 `\n` → `\r\n` 도 같은 공식이다 (#385 실측).

    // plain 은 80 byte 고정 줄이라 1 MiB 안의 개행 수를 손으로 계산할 수 있다.
    const opts: Options = .{ .workload_kind = .plain, .bytes = 80 * 1000 };
    const expected = expectedPtyBytes(opts).?;
    try std.testing.expectEqual(@as(u64, 80 * 1000 + 1000), expected);
}
