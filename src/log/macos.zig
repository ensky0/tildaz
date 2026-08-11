// macOS 의 log impl — 시스템 의존 부분 (local time / pid) 만. 공통
// formatting / writeRaw / process-lifetime 로그 파일 경로는 `log.zig`
// (단일 소스, #282 G3).

const std = @import("std");
const log_time = @import("../log_time.zig");

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
    // sec 가 한 칸 앞서가는 race. `clock_gettime` 은 sec 와 nsec 를 한 번에 주므로
    // 이 성질이 그대로 유지된다.
    //
    // Zig 0.16 — `std.time.milliTimestamp` 가 없어졌다 (#451). 시간이 `Io` 경유로
    // 옮겨갔지만 이 함수는 로그 한 줄마다 불려 `io` 를 받을 자리가 없다. std 가 이미
    // 감싸 둔 `std.c.clock_gettime` 을 쓴다 — 직접 `extern "c"` 선언하지 않는다.
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return log_time.fallback();
    if (ts.sec < 0) return log_time.fallback();
    const secs: time_t = @intCast(ts.sec);
    const ms: u16 = @intCast(@divTrunc(ts.nsec, std.time.ns_per_ms));

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
