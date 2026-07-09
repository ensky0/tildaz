// Throughput instrumentation — atomic counters + file logger.
// Writes snapshots to the unified log file (`log.zig`) on dumpAndReset().

const std = @import("std");
const log = @import("log.zig");

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

/// Cross-platform elapsed-time timestamp. Linux = CLOCK_BOOTTIME, macOS =
/// CLOCK_UPTIME_RAW, Windows = QueryPerformanceCounter. Clock 미지원이면 해당
/// diagnostic sample만 생략한다.
pub const Timestamp = ?std.time.Instant;

pub fn now() Timestamp {
    return std.time.Instant.now() catch null;
}

fn elapsedNs(start: std.time.Instant, end: std.time.Instant) ?u64 {
    if (end.order(start) == .lt) return null;
    return end.since(start);
}

pub fn nsSince(start: Timestamp) ?u64 {
    const start_instant = start orelse return null;
    const end = now() orelse return null;
    return elapsedNs(start_instant, end);
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
    const text = std.fmt.bufPrint(&buf,
        "\n=== {s} @ ts={d}ms ===\n" ++
            "readloop calls={d} bytes={d} ms={d:.3}\n" ++
            "push     calls={d} bytes={d} yields={d}\n" ++
            "drain    calls={d} bytes={d} ms={d:.3}\n" ++
            "parse    calls={d} ms={d:.3}\n" ++
            "render   calls={d} ms={d:.3}\n" ++
            "present  calls={d} ms={d:.3}\n" ++
            "onrender calls={d} ms={d:.3} skip={d}\n",
        .{
            label,              std.time.milliTimestamp(),
            rl[0],              rl[2],
            @as(f64, @floatFromInt(rl[1])) / 1_000_000.0,
            pu[0],              pu[2],              pu[3],
            dr[0],              dr[2],
            @as(f64, @floatFromInt(dr[1])) / 1_000_000.0,
            pa[0],              @as(f64, @floatFromInt(pa[1])) / 1_000_000.0,
            re[0],              @as(f64, @floatFromInt(re[1])) / 1_000_000.0,
            pr[0],              @as(f64, @floatFromInt(pr[1])) / 1_000_000.0,
            on[0],              @as(f64, @floatFromInt(on[1])) / 1_000_000.0,
            on[3],
        },
    ) catch return;

    log.appendBlock(text);
}

test "Instant duration rejects reversed samples" {
    const start = try std.time.Instant.now();
    std.Thread.sleep(5 * std.time.ns_per_ms);
    const end = try std.time.Instant.now();

    try std.testing.expectEqual(@as(?u64, 0), elapsedNs(start, start));
    try std.testing.expect((elapsedNs(start, end) orelse 0) > 0);
    try std.testing.expectEqual(@as(?u64, null), elapsedNs(end, start));
}

test "unavailable clock sample does not update counters" {
    var counter: Counter = .{};

    addTimed(&counter, null);
    addTimedBytes(&counter, null, 123);

    try std.testing.expectEqual(@as(u64, 0), counter.calls.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), counter.ns.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), counter.bytes.load(.monotonic));
}
