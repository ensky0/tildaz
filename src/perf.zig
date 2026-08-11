// Throughput instrumentation — atomic counters + file logger.
// Writes snapshots to the unified log file (`log.zig`) on dumpAndReset().

const std = @import("std");
const runtime = @import("runtime.zig");
const builtin = @import("builtin");
const log = @import("log.zig");
const instance_context = @import("instance_context.zig");

const win32 = if (builtin.os.tag == .windows) struct {
    const QueryUnbiasedInterruptTimePreciseFn = *const fn (*u64) callconv(.c) void;

    extern "kernel32" fn LoadLibraryW([*:0]const u16) callconv(.c) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.c) ?*const anyopaque;

    var query_unbiased_interrupt_time_precise: ?QueryUnbiasedInterruptTimePreciseFn = null;
    var query_once = std.once(resolveQueryUnbiasedInterruptTimePrecise);

    fn resolveQueryUnbiasedInterruptTimePrecise() void {
        // API-set contract를 사용해 실제 구현 DLL(KernelBase 등)의 위치와 분리한다.
        // Windows 10 10.0.10240부터 이 contract가 precise clock을 제공한다.
        const module_name = std.unicode.utf8ToUtf16LeStringLiteral("api-ms-win-core-realtime-l1-1-1.dll");
        const module = LoadLibraryW(module_name) orelse return;
        query_unbiased_interrupt_time_precise = @ptrCast(@alignCast(GetProcAddress(
            module,
            "QueryUnbiasedInterruptTimePrecise",
        )));
    }

    /// Windows 10+ working-state clock. 100ns 단위이며 sleep/hibernate를 세지 않는다.
    fn queryUnbiasedInterruptTimePrecise(ticks_100ns: *u64) bool {
        query_once.call();
        const query = query_unbiased_interrupt_time_precise orelse return false;
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
pub var render: Counter = .{}; // renderTerminal excluding Present
pub var shape: Counter = .{}; // grapheme cluster shaping — subset of render, extra = chain miss
pub var present: Counter = .{}; // swap_chain.Present
pub var onrender: Counter = .{}; // onRender total — extra = skip_swap count
/// #435 — swap chain 이 아직 다음 프레임을 못 받아서 건너뛴 frame tick 수 (extra).
/// `onrender` 의 `skip` 과 **섞지 않는다** — 그쪽은 *"화면이 안 바뀌어서 안 그렸다"*
/// (#386 ②) 라 뜻이 다르고, 한 칸에 합치면 그 게이트를 못 본다.
pub var swapwait: Counter = .{};

/// Cross-platform working-state timestamp(ns). Linux = CLOCK_MONOTONIC,
/// macOS = CLOCK_UPTIME_RAW, Windows = QueryUnbiasedInterruptTimePrecise.
/// 세 clock 모두 system sleep/hibernate를 세지 않는다. 이 모듈의 성능 진단에만
/// 쓰며 기능 동작용 std.time.Timer의 elapsed-time 의미는 바꾸지 않는다.
pub const Timestamp = ?u64;

pub fn now() Timestamp {
    if (comptime builtin.os.tag == .windows) {
        var ticks_100ns: u64 = 0;
        if (!win32.queryUnbiasedInterruptTimePrecise(&ticks_100ns)) return null;
        return ticks100nsToNs(ticks_100ns);
    }

    const ts = if (comptime builtin.os.tag == .linux)
        std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch return null
    else if (comptime builtin.os.tag == .macos)
        std.posix.clock_gettime(std.posix.CLOCK.UPTIME_RAW) catch return null
    else
        return null;
    return timePartsToNs(@intCast(ts.sec), @intCast(ts.nsec));
}

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

pub fn dumpAndReset(label: []const u8) void {
    const rl = snapshot(&readloop);
    const pu = snapshot(&push);
    const dr = snapshot(&drain);
    const pa = snapshot(&parse);
    const re = snapshot(&render);
    const sh = snapshot(&shape);
    const pr = snapshot(&present);
    const on = snapshot(&onrender);
    const sw = snapshot(&swapwait);

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
            "onrender calls={d} ms={d:.3} skip={d}\n",
        .{
            label,
            std.time.milliTimestamp(),
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
pub fn dumpOnExit() void {
    if (!instance_context.isStress()) return;

    // 라벨에 워크로드를 넣어 5 회 반복 로그를 기계로 가를 수 있게 한다. 측정 인스턴스에
    // 넘긴 환경변수 (`stress.zig` 의 `env_workload`) 를 그대로 읽는다. Windows 는
    // `getEnvVarOwned` 가 key 의 WTF-16 변환에도 allocator 를 쓰므로 넉넉히 잡는다.
    // 실패하면 그냥 `"stress"` — 라벨 하나 때문에 덤프 자체를 거르지 않는다.
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const label: []const u8 = if (runtime.envAlloc(
        fba.allocator(),
        "TILDAZ_STRESS_WORKLOAD",
    )) |workload| workload else |_| "stress";

    dumpAndReset(label);
}

test "working-time duration rejects reversed samples" {
    const start = now() orelse return error.SkipZigTest;
    std.Thread.sleep(5 * std.time.ns_per_ms);
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
