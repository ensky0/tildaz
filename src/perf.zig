// Throughput instrumentation — atomic counters + file logger.
// Writes snapshots to the unified log file (`log.zig`) on dumpAndReset().

const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const instance_context = @import("instance_context.zig");
const Runtime = @import("runtime.zig").Runtime;

const win32 = if (builtin.os.tag == .windows) struct {
    const QueryUnbiasedInterruptTimePreciseFn = *const fn (*u64) callconv(.c) void;

    extern "kernel32" fn LoadLibraryW([*:0]const u16) callconv(.c) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.c) ?*const anyopaque;

    /// #451 — `std.once` 가 0.16 에서 제거됐다 (릴리즈 노트: *"avoid global variables, or
    /// hand-roll the logic yourself"*). 여기서는 **배타 실행이 애초에 필요 없다** —
    /// `LoadLibraryW` · `GetProcAddress` 는 멱등이라 여러 스레드가 동시에 찾아도 같은
    /// 주소가 나온다. 그래서 lock 없이 결과만 원자적으로 발행한다.
    ///
    /// 상태 값: `0` = 아직 안 찾음 · `1` = 없음(확정) · 그 외 = 함수 주소.
    var query_state: std.atomic.Value(usize) = .init(0);

    fn resolveQueryUnbiasedInterruptTimePrecise() usize {
        // API-set contract를 사용해 실제 구현 DLL(KernelBase 등)의 위치와 분리한다.
        // Windows 10 10.0.10240부터 이 contract가 precise clock을 제공한다.
        const module_name = std.unicode.utf8ToUtf16LeStringLiteral("api-ms-win-core-realtime-l1-1-1.dll");
        const module = LoadLibraryW(module_name) orelse return 1;
        const proc = GetProcAddress(module, "QueryUnbiasedInterruptTimePrecise") orelse return 1;
        return @intFromPtr(proc);
    }

    /// Windows 10+ working-state clock. 100ns 단위이며 sleep/hibernate를 세지 않는다.
    fn queryUnbiasedInterruptTimePrecise(ticks_100ns: *u64) bool {
        var state = query_state.load(.acquire);
        if (state == 0) {
            state = resolveQueryUnbiasedInterruptTimePrecise();
            query_state.store(state, .release);
        }
        if (state <= 1) return false;
        const query: QueryUnbiasedInterruptTimePreciseFn = @ptrFromInt(state);
        query(ticks_100ns);
        return true;
    }
} else struct {};

pub const Counter = struct {
    calls: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    extra: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

pub var readloop: Counter = .{}; // ReadFile from ConPTY pipe
pub var push: Counter = .{}; // ring.push — extra = yield spins (full)
pub var drain: Counter = .{}; // drainOutput — ns covers whole loop, bytes = popped
pub var parse: Counter = .{}; // stream.nextSlice alone
pub var render: Counter = .{}; // 첫 drawPane 부터 endFrame 의 Present 직전까지 (프레임당 한 번)
pub var shape: Counter = .{}; // grapheme cluster shaping — subset of render, extra = chain miss
pub var present: Counter = .{}; // swap_chain.Present
pub var onrender: Counter = .{}; // onRender total — extra = skip_swap count
/// #435 — swap chain 이 아직 다음 프레임을 못 받아서 건너뛴 frame tick 수 (extra).
/// `onrender` 의 `skip` 과 **섞지 않는다** — 그쪽은 *"화면이 안 바뀌어서 안 그렸다"*
/// (#386 ②) 라 뜻이 다르고, 한 칸에 합치면 그 게이트를 못 본다.
pub var swapwait: Counter = .{};
/// #441 축 ② — **키를 받은 순간부터 그 뒤 첫 present 가 끝날 때까지.** 위 카운터들이
/// *처리량* 의 구간별 몫을 재는 것과 달리 이쪽은 **응답 지연**이다.
///
/// `calls` = 표본 수 · `ns` = 합 (평균은 나눠서) · `extra` = **최악값**. 평균만 보면
/// 안 되는 값이라 최악을 따로 든다 — 예산 4 ms (SPEC §13.3) 가 상한이라는 주장은
/// *평균*이 아니라 *최악*에 대한 주장이기 때문이다.
pub var input_latency: Counter = .{};

/// 대기 중인 키의 수신 시각(ns). 0 = 없음.
///
/// **이미 대기 중이면 덮지 않는다** (`markInput` 의 CAS). 폭포 중에는 키가 연달아
/// 들어오는데, 덮으면 *가장 최근* 키의 지연만 남아 **가장 오래 기다린 키가 사라진다** —
/// 최악값을 보려는 목적과 정반대가 된다.
var pending_input_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// 키를 받은 자리에서 부른다 (세 host 의 키 진입점).
///
/// `now()` 가 0 을 돌려주면 그 표본은 버려진다 — 0 을 "없음" 으로 쓰기 때문이다.
/// monotonic clock 이 부팅 직후 0 ns 를 낼 확률은 무시할 수준이고, 대신 sentinel 이
/// 없는 구조 (별도 flag) 는 hot path 에 원자 연산을 하나 더 늘린다.
pub fn markInput() void {
    const t = now() orelse return;
    if (t == 0) return;
    _ = pending_input_ns.cmpxchgStrong(0, t, .acq_rel, .monotonic);
}

/// present 가 끝난 자리에서 부른다. 대기 중인 키가 있으면 지연을 적고 비운다.
pub fn completeInput() void {
    const start = pending_input_ns.swap(0, .acq_rel);
    if (start == 0) return;
    const t = now() orelse return;
    if (t <= start) return;
    const delta = t - start;
    _ = input_latency.calls.fetchAdd(1, .monotonic);
    _ = input_latency.ns.fetchAdd(delta, .monotonic);
    // 최악값 갱신. 경합해도 더 큰 값이 이긴다.
    var cur = input_latency.extra.load(.monotonic);
    while (delta > cur) {
        cur = input_latency.extra.cmpxchgWeak(cur, delta, .monotonic, .monotonic) orelse break;
    }
}

/// #439 — **PTY 출력이 도착한 순간부터 그 뒤 첫 present 가 끝날 때까지.**
///
/// `input_latency` 와 구간이 다르다. 그쪽은 *키* 에서 시작하는데, 키가 오면 앱이 즉시
/// 렌더를 요청하므로 **유휴 깨우기 경로를 아예 안 탄다** (#441 에서 유휴 평균이 0.67 ms
/// 로 낮게 나온 이유다). 이쪽은 입력 없이 출력만 도착하는 상황을 재므로 *"유휴에서 첫
/// 출력이 한 프레임 늦는다"* 는 #439 의 가설을 직접 판정한다.
///
/// `calls` = 표본 수 · `ns` = 합 · `extra` = 최악값. 최악을 따로 드는 이유는
/// `input_latency` 와 같다 — 프레임 주기가 상한이라는 주장은 평균이 아니라 최악에 대한 것이다.
pub var output_latency: Counter = .{};

/// 대기 중인 출력의 도착 시각(ns). 0 = 없음.
///
/// `pending_input_ns` 와 같은 이유로 **이미 대기 중이면 덮지 않는다** — 폭포처럼 연달아
/// 들어올 때 덮으면 가장 오래 기다린 조각이 사라진다.
var pending_output_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// PTY 에서 읽은 바이트를 ring 에 넣는 자리에서 부른다.
///
/// **read thread 에서 불린다.** 원자 연산뿐이라 안전하고, 여기서 하는 일은 CAS 하나다 —
/// 이 함수가 무거워지면 read 경로 전체가 느려진다.
pub fn markOutput() void {
    const t = now() orelse return;
    if (t == 0) return;
    _ = pending_output_ns.cmpxchgStrong(0, t, .acq_rel, .monotonic);
}

/// present 가 끝난 자리에서 부른다 (`completeInput` 과 같은 자리).
pub fn completeOutput() void {
    const start = pending_output_ns.swap(0, .acq_rel);
    if (start == 0) return;
    const t = now() orelse return;
    if (t <= start) return;
    const delta = t - start;
    _ = output_latency.calls.fetchAdd(1, .monotonic);
    _ = output_latency.ns.fetchAdd(delta, .monotonic);
    var cur = output_latency.extra.load(.monotonic);
    while (delta > cur) {
        cur = output_latency.extra.cmpxchgWeak(cur, delta, .monotonic, .monotonic) orelse break;
    }
}

/// Cross-platform working-state timestamp(ns). Linux = CLOCK_MONOTONIC,
/// macOS = CLOCK_UPTIME_RAW, Windows = QueryUnbiasedInterruptTimePrecise.
/// 세 clock 모두 system sleep/hibernate를 세지 않는다. 이 모듈의 성능 진단에만
/// 쓰며 기능 동작용 `runtime.Timer` (`Io.Timestamp` 기반) 의 elapsed-time 의미는
/// 바꾸지 않는다.
pub const Timestamp = ?u64;

pub fn now() Timestamp {
    if (comptime builtin.os.tag == .windows) {
        var ticks_100ns: u64 = 0;
        if (!win32.queryUnbiasedInterruptTimePrecise(&ticks_100ns)) return null;
        return ticks100nsToNs(ticks_100ns);
    }

    // #451 — `std.posix.clock_gettime` 이 제거됐다. 대체인 `Io.Timestamp.now` 는 `Io` 를
    // 요구하는데 이 함수는 **계측 hot path** 라 인자를 늘릴 수 없다 (호출부가 프레임마다
    // 돈다). 릴리즈 노트가 남긴 다른 길 *"go lower"* 로 libc 를 직접 부른다 — Windows 가
    // 위에서 이미 kernel32 를 직접 쓰고 있어 방식이 일관된다.
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return null;
    var ts: posix_time.timespec = undefined;
    const clock_id: c_int = if (comptime builtin.os.tag == .linux)
        posix_time.CLOCK_MONOTONIC
    else
        posix_time.CLOCK_UPTIME_RAW;
    if (posix_time.clock_gettime(clock_id, &ts) != 0) return null;
    return timePartsToNs(@intCast(ts.tv_sec), @intCast(ts.tv_nsec));
}

/// POSIX 단조 시계 — `now()` 전용 (위 주석 참고).
const posix_time = if (builtin.os.tag == .linux or builtin.os.tag == .macos) struct {
    pub const timespec = extern struct {
        tv_sec: i64,
        tv_nsec: c_long,
    };
    /// Linux `CLOCK_MONOTONIC`. sleep 은 세지 않는다.
    pub const CLOCK_MONOTONIC: c_int = 1;
    /// macOS `CLOCK_UPTIME_RAW`. Linux 의 MONOTONIC 과 같은 의미로 sleep 을 안 센다.
    pub const CLOCK_UPTIME_RAW: c_int = 8;
    pub extern "c" fn clock_gettime(clk_id: c_int, tp: *timespec) c_int;
} else struct {};

fn ticks100nsToNs(ticks: u64) ?u64 {
    return std.math.mul(u64, ticks, 100) catch null;
}

fn timePartsToNs(seconds: i128, nanoseconds: i128) ?u64 {
    if (seconds < 0 or nanoseconds < 0 or nanoseconds >= std.time.ns_per_s) return null;
    const whole = std.math.mul(u64, @intCast(seconds), std.time.ns_per_s) catch return null;
    return std.math.add(u64, whole, @intCast(nanoseconds)) catch null;
}

fn elapsedNs(start: u64, end: u64) ?u64 {
    if (end < start) return null;
    return end - start;
}

pub fn nsSince(start: Timestamp) ?u64 {
    const start_ns = start orelse return null;
    const end = now() orelse return null;
    return elapsedNs(start_ns, end);
}

pub fn addTimed(c: *Counter, start: Timestamp) void {
    const dt = nsSince(start) orelse return;
    _ = c.ns.fetchAdd(dt, .monotonic);
    _ = c.calls.fetchAdd(1, .monotonic);
}

pub fn addTimedBytes(c: *Counter, start: Timestamp, bytes: u64) void {
    const dt = nsSince(start) orelse return;
    _ = c.ns.fetchAdd(dt, .monotonic);
    _ = c.calls.fetchAdd(1, .monotonic);
    _ = c.bytes.fetchAdd(bytes, .monotonic);
}

pub fn incExtra(c: *Counter) void {
    _ = c.extra.fetchAdd(1, .monotonic);
}

pub fn snapshot(c: *Counter) [4]u64 {
    return .{
        c.calls.swap(0, .monotonic),
        c.ns.swap(0, .monotonic),
        c.bytes.swap(0, .monotonic),
        c.extra.swap(0, .monotonic),
    };
}

pub fn dumpAndReset(rt: Runtime, label: []const u8) void {
    const rl = snapshot(&readloop);
    const pu = snapshot(&push);
    const dr = snapshot(&drain);
    const pa = snapshot(&parse);
    const re = snapshot(&render);
    const sh = snapshot(&shape);
    const pr = snapshot(&present);
    const on = snapshot(&onrender);
    const sw = snapshot(&swapwait);
    const il = snapshot(&input_latency);
    const ol = snapshot(&output_latency);
    // 대기 중인 키는 스냅숏 경계를 넘기지 않는다 — 다음 구간에서 present 가 되면
    // *이전 구간에 눌린* 키의 지연이 그쪽에 잡혀 구간 귀속이 어긋난다.
    _ = pending_input_ns.swap(0, .acq_rel);
    _ = pending_output_ns.swap(0, .acq_rel);

    var buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buf,
        "\n=== {s} @ ts={d}ms ===\n" ++
            "readloop calls={d} bytes={d} ms={d:.3}\n" ++
            "push     calls={d} bytes={d} yields={d}\n" ++
            "drain    calls={d} bytes={d} ms={d:.3}\n" ++
            "parse    calls={d} ms={d:.3}\n" ++
            "render   calls={d} ms={d:.3}\n" ++
            // #395 — render 의 부분집합. cluster shaping 이 render 몫의 얼마인지
            // 가르려고 뽑는다. miss = chain 전체 미스 (base codepoint fallback).
            "shape    calls={d} ms={d:.3} miss={d}\n" ++
            "present  calls={d} ms={d:.3}\n" ++
            // #435 — swap chain 이 안 받아서 건너뛴 tick. waitable 이 없는 경로 (legacy
            // DISCARD · DirectComposition) 에서는 항상 0 이다.
            "swapwait ticks={d}\n" ++
            "onrender calls={d} ms={d:.3} skip={d}\n" ++
            // #441 축 ② — 키 수신 → 첫 present 완료. `max` 를 함께 내는 이유는
            // 위 `input_latency` 주석 참고 (예산 주장은 평균이 아니라 최악에 대한 것).
            "input    samples={d} ms={d:.3} max_ms={d:.3}\n" ++
            // #439 — PTY 도착 → present. `input` 과 시작점이 다르다 (위 주석).
            "output   samples={d} ms={d:.3} max_ms={d:.3}\n",
        .{
            label,
            rt.nowMs(),
            rl[0],
            rl[2],
            @as(f64, @floatFromInt(rl[1])) / 1_000_000.0,
            pu[0],
            pu[2],
            pu[3],
            dr[0],
            dr[2],
            @as(f64, @floatFromInt(dr[1])) / 1_000_000.0,
            pa[0],
            @as(f64, @floatFromInt(pa[1])) / 1_000_000.0,
            re[0],
            @as(f64, @floatFromInt(re[1])) / 1_000_000.0,
            sh[0],
            @as(f64, @floatFromInt(sh[1])) / 1_000_000.0,
            sh[3],
            pr[0],
            @as(f64, @floatFromInt(pr[1])) / 1_000_000.0,
            sw[3],
            on[0],
            @as(f64, @floatFromInt(on[1])) / 1_000_000.0,
            on[3],
            il[0],
            @as(f64, @floatFromInt(il[1])) / 1_000_000.0,
            @as(f64, @floatFromInt(il[3])) / 1_000_000.0,
            ol[0],
            @as(f64, @floatFromInt(ol[1])) / 1_000_000.0,
            @as(f64, @floatFromInt(ol[3])) / 1_000_000.0,
        },
    ) catch return;

    log.appendBlock(text);
}

/// #396 — 측정 인스턴스는 종료 직전에 스냅숏을 **자동으로 한 번** 남긴다. 손으로
/// `Ctrl+Shift+F12` 를 누르던 절차는 세 가지가 문제였다.
///
/// 1. 측정 창에 키 입력을 넣어야 한다 — AGENTS.md 의 "측정 중 기기를 건드리지 않는다"
///    와 정면으로 어긋난다.
/// 2. `dumpAndReset` 이 읽으면서 리셋하므로 두 번 누르면 `parse ms=0.000` 껍데기가 나온다.
/// 3. 무엇보다 `dist/stress/README.md` 의 5 회 반복을 사람이 지킬 수 없어서, 배분 측정이
///    지금까지 전부 1 회였다 (#389 macOS · #395 Linux 둘 다).
///
/// worker 에서는 no-op 이다. 게이트가 *프로세스 역할* 이라 `RunOptions` 를 들고 다니지
/// 않는 이 자리에서도 판정된다 (`instance_context.isStress` 의 doc 주석이 이 용도다).
///
/// 호출은 host 3 곳의 `log.logStop` **직전**이다 — 로그 파일이 닫히기 전이어야 한다.
/// Linux · Windows 는 `defer` 가 LIFO 라 `defer log.logStop(...)` 아래에 두면 되고,
/// macOS 는 Cmd+Q 가 `exit()` 직행이라 `atExitLogStop` 안에 둔다.
pub fn dumpOnExit(rt: Runtime) void {
    if (!instance_context.isStress()) return;

    // 라벨에 워크로드를 넣어 5 회 반복 로그를 기계로 가를 수 있게 한다. 측정 인스턴스에
    // 넘긴 환경변수 (`stress.zig` 의 `env_workload`) 를 그대로 읽는다.
    //
    // 무할당 조회 (`getPosix` / `getWindows`) 를 쓴다 — `rt.envAlloc` (= `Environ.getAlloc`)
    // 은 조회 한 번에 `createMap` 으로 **환경 전체를 할당**해서, 처음에 여기 있던 256 B
    // `FixedBufferAllocator` 로는 항상 `OutOfMemory` → 라벨이 영영 fallback 이었다
    // (#451 재검토에서 실측. `envHas` 를 `containsConstant` 로 고친 96b2a9e 과 같은 패턴).
    // 실패하면 그냥 `"stress"` — 라벨 하나 때문에 덤프 자체를 거르지 않는다.
    var label_buf: [256]u8 = undefined;
    const label: []const u8 = if (builtin.os.tag == .windows) blk: {
        // `containsConstant` 와 같은 방식 — key 는 comptime 에 WTF-16 으로, 값은 스택
        // 버퍼에 WTF-8 로 변환한다 (code unit 당 최대 3 바이트).
        const key_w = comptime std.unicode.wtf8ToWtf16LeStringLiteral("TILDAZ_STRESS_WORKLOAD");
        const val_w = rt.environ.getWindows(key_w) orelse break :blk "stress";
        if (val_w.len * 3 > label_buf.len) break :blk "stress";
        break :blk label_buf[0..std.unicode.wtf16LeToWtf8(&label_buf, val_w)];
    } else rt.environ.getPosix("TILDAZ_STRESS_WORKLOAD") orelse "stress";

    dumpAndReset(rt, label);
}

test "working-time duration rejects reversed samples" {
    const start = now() orelse return error.SkipZigTest;
    // #451 — `Thread.sleep` ➡️ `Io.sleep` (`Runtime.sleepNs`). `.awake` 는 절전 구간을
    // 세지 않는 단조 시계로, 위 `now()` 가 재는 working-time 과 같은 성질이다.
    (Runtime{ .io = std.testing.io, .environ = .empty }).sleepNs(5 * std.time.ns_per_ms);
    const end = now() orelse return error.SkipZigTest;

    try std.testing.expectEqual(@as(?u64, 0), elapsedNs(start, start));
    try std.testing.expect((elapsedNs(start, end) orelse 0) > 0);
    try std.testing.expectEqual(@as(?u64, null), elapsedNs(end, start));
}

test "platform clock units convert to nanoseconds with checked boundaries" {
    try std.testing.expectEqual(@as(?u64, 12_300), ticks100nsToNs(123));
    try std.testing.expectEqual(@as(?u64, null), ticks100nsToNs(std.math.maxInt(u64)));

    try std.testing.expectEqual(@as(?u64, 2_000_000_003), timePartsToNs(2, 3));
    try std.testing.expectEqual(@as(?u64, null), timePartsToNs(-1, 0));
    try std.testing.expectEqual(@as(?u64, null), timePartsToNs(0, std.time.ns_per_s));
    try std.testing.expectEqual(@as(?u64, null), timePartsToNs(std.math.maxInt(u64), 0));
}

test "unavailable clock sample does not update counters" {
    var counter: Counter = .{};

    addTimed(&counter, null);
    addTimedBytes(&counter, null, 123);

    try std.testing.expectEqual(@as(u64, 0), counter.calls.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), counter.ns.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), counter.bytes.load(.monotonic));
}
