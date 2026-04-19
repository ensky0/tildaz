// Throughput instrumentation — atomic counters + file logger.
// Writes snapshots to %APPDATA%\tildaz\tildaz.log via tildaz_log on dumpAndReset().

const std = @import("std");
const tildaz_log = @import("tildaz_log.zig");

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

extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.c) std.os.windows.BOOL;
extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.c) std.os.windows.BOOL;

var freq: i64 = 0;

pub fn init() void {
    _ = QueryPerformanceFrequency(&freq);
}

pub fn now() i64 {
    var t: i64 = undefined;
    _ = QueryPerformanceCounter(&t);
    return t;
}

pub fn nsSince(start: i64) u64 {
    var end: i64 = undefined;
    _ = QueryPerformanceCounter(&end);
    const ticks: u128 = @intCast(end - start);
    return @intCast(ticks * 1_000_000_000 / @as(u128, @intCast(freq)));
}

pub fn addTimed(c: *Counter, start: i64) void {
    const dt = nsSince(start);
    _ = c.ns.fetchAdd(dt, .monotonic);
    _ = c.calls.fetchAdd(1, .monotonic);
}

pub fn addTimedBytes(c: *Counter, start: i64, bytes: u64) void {
    const dt = nsSince(start);
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

    tildaz_log.appendBlock(text);
}
