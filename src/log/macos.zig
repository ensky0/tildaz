// macOS 의 log impl — 시스템 의존 부분 (local time / pid) 만. 공통
// formatting / writeRaw / process-lifetime 로그 파일 경로는 `log.zig`
// (단일 소스, #282 G3).

const std = @import("std");
const log_time = @import("../log_time.zig");
const runtime = @import("../runtime.zig");

const time_t = i64;

/// POSIX `struct tm`. macOS 는 BSD 확장 (`tm_gmtoff` / `tm_zone`) 포함. C
/// header `<time.h>`.
const tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timep: *const time_t, result: *tm) ?*tm;
extern "c" fn getpid() c_int;

pub const TimeFields = log_time.TimeFields;

pub fn currentLocalTime() TimeFields {
    // ms / sec 동일 시각에서 함께 가져옴 — 두 번 query 하면 boundary 에서
    // sec 가 한 칸 앞서가는 race.
    //
    // Zig 0.16 — `std.time.milliTimestamp` 가 없어졌다 (#451).
    // 0.16 의 지정 대체는 `std.Io.Timestamp.now` 다 (릴리즈 노트의 upgrade guide:
    // `std.time.timestamp` ➡️ `std.Io.Timestamp.now`). `.real` 이 Unix epoch 기준
    // wall clock 이고, nanoseconds 하나로 오므로 sec 와 ms 가 같은 시각에서 나온다.
    //
    // `runtime.io()` 가 null 인 구간 (진입점의 `install` 전) 에는 시각을 알 방법이 없어
    // fallback 으로 떨어뜨린다 — 로그가 안 남는 것보다 낫다.
    const io = runtime.io() orelse return log_time.fallback();
    const ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    if (ns < 0) return log_time.fallback();
    const secs: time_t = @intCast(@divTrunc(ns, std.time.ns_per_s));
    const ms: u16 = @intCast(@divTrunc(@mod(ns, std.time.ns_per_s), std.time.ns_per_ms));

    var t: tm = undefined;
    if (localtime_r(&secs, &t) == null) {
        return log_time.fallback();
    }
    return .{
        .year = @intCast(t.tm_year + 1900),
        .month = @intCast(t.tm_mon + 1),
        .day = @intCast(t.tm_mday),
        .hour = @intCast(t.tm_hour),
        .min = @intCast(t.tm_min),
        .sec = @intCast(t.tm_sec),
        .ms = ms,
    };
}

pub fn currentPid() u64 {
    return @intCast(getpid());
}
