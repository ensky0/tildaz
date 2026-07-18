// Throughput instrumentation — atomic counters + file logger.
// Writes snapshots to the unified log file (`log.zig`) on dumpAndReset().

const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");

const win32 = if (builtin.os.tag == .windows) struct {
    /// Windows 10+ working-state clock. 100ns 단위이며 sleep/hibernate를 세지 않는다.
    pub extern "kernel32" fn QueryUnbiasedInterruptTimePrecise(*u64) callconv(.c) void;
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
pub var present: Counter = .{}; // swap_chain.Present
pub var onrender: Counter = .{}; // onRender total — extra = skip_swap count

/// Cross-platform working-state timestamp(ns). Linux = CLOCK_MONOTONIC,
/// macOS = CLOCK_UPTIME_RAW, Windows = QueryUnbiasedInterruptTimePrecise.
/// 세 clock 모두 system sleep/hibernate를 세지 않는다. 이 모듈의 성능 진단에만
/// 쓰며 기능 동작용 std.time.Timer의 elapsed-time 의미는 바꾸지 않는다.
pub const Timestamp = ?u64;

pub fn now() Timestamp {
    if (comptime builtin.os.tag == .windows) {
        var ticks_100ns: u64 = 0;
        win32.QueryUnbiasedInterruptTimePrecise(&ticks_100ns);
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

fn snapshot(c: *Counter) [4]u64 {
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
    const pr = snapshot(&present);
    const on = snapshot(&onrender);

    var buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buf,
        "\n=== {s} @ ts={d}ms ===\n" ++
            "readloop calls={d} bytes={d} ms={d:.3}\n" ++
            "push     calls={d} bytes={d} yields={d}\n" ++
            "drain    calls={d} bytes={d} ms={d:.3}\n" ++
            "parse    calls={d} ms={d:.3}\n" ++
            "render   calls={d} ms={d:.3}\n" ++
            "present  calls={d} ms={d:.3}\n" ++
            "onrender calls={d} ms={d:.3} skip={d}\n",
        .{
            label,                                        std.time.milliTimestamp(),
            rl[0],                                        rl[2],
            @as(f64, @floatFromInt(rl[1])) / 1_000_000.0, pu[0],
            pu[2],                                        pu[3],
            dr[0],                                        dr[2],
            @as(f64, @floatFromInt(dr[1])) / 1_000_000.0, pa[0],
            @as(f64, @floatFromInt(pa[1])) / 1_000_000.0, re[0],
            @as(f64, @floatFromInt(re[1])) / 1_000_000.0, pr[0],
            @as(f64, @floatFromInt(pr[1])) / 1_000_000.0, on[0],
            @as(f64, @floatFromInt(on[1])) / 1_000_000.0, on[3],
        },
    ) catch return;

    log.appendBlock(text);
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
