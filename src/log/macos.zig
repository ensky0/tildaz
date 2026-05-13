// macOS 의 log impl — 시스템 의존 부분만. 공통 formatting / writeRaw 는
// `log.zig`. 로그 파일은 `~/Library/Logs/tildaz.log` (Apple HIG — Console.app
// 자동 인덱싱).

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
    // sec 가 한 칸 앞서가는 race.
    const ms_total = std.time.milliTimestamp();
    const secs: time_t = @intCast(@divTrunc(ms_total, 1000));
    const ms: u16 = @intCast(@mod(ms_total, 1000));

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

/// `~/Library/Logs/tildaz.log` 의 absolute UTF-8 path 를 buf 에 작성하고 slice
/// 반환. `~/Library/Logs/` 는 macOS default 로 존재 (수동 생성 불필요). 실패 시 null.
pub fn resolvePath(buf: []u8) ?[]const u8 {
    const home = std.c.getenv("HOME") orelse return null;
    const home_slice = std.mem.span(home);
    const suffix = "/Library/Logs/tildaz.log";
    if (home_slice.len + suffix.len >= buf.len) return null;
    @memcpy(buf[0..home_slice.len], home_slice);
    @memcpy(buf[home_slice.len..][0..suffix.len], suffix);
    return buf[0 .. home_slice.len + suffix.len];
}
