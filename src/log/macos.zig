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

/// POSIX `struct timespec`.
const timespec = extern struct {
    tv_sec: time_t,
    tv_nsec: c_long,
};

/// `CLOCK_REALTIME` — POSIX 가 0 으로 못박은 값 (Linux · macOS 동일).
const CLOCK_REALTIME: c_int = 0;

// #451 — `std.time.milliTimestamp` 제거. 대체인 `Io.Timestamp.now` 는 `Io` 를 요구하는데
// **`log.zig` 는 `Io` 를 들이지 않는다** (기록이 raw syscall 이라야 O_APPEND 원자성이
// 유지된다). 릴리즈 노트가 남긴 다른 길 *"go lower"* 로 libc 를 직접 부른다 — 이 파일이
// 이미 `localtime_r` · `getpid` 를 그렇게 쓰고 있다.
extern "c" fn clock_gettime(clk_id: c_int, tp: *timespec) c_int;

pub const TimeFields = log_time.TimeFields;

/// Unix epoch 기준 밀리초. 실패하면 음수를 돌려 호출부가 fallback 하게 한다.
fn wallClockMs() i64 {
    var ts: timespec = undefined;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) return -1;
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}

pub fn currentLocalTime() TimeFields {
    // ms / sec 동일 시각에서 함께 가져옴 — 두 번 query 하면 boundary 에서
    // sec 가 한 칸 앞서가는 race.
    const ms_total = wallClockMs();
    // `wallClockMs` 는 실패를 음수로 알린다 — 그대로 쓰면 아래 `@intCast` 가 panic 한다
    // (Linux 쪽에 이미 있던 가드와 같게 맞춘다).
    if (ms_total < 0) return log_time.fallback();
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
