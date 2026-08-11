// Linux log impl — system-dependent pieces (local time / pid) only. Shared
// formatting / file IO lives in `log.zig`, and the log file path comes from
// process-lifetime 로그 파일 경로는 `log.zig`가 단일 값으로 보관한다.
//
// #282 후속 — 로컬 시각은 glibc `localtime_r` 로 구한다 (macOS `log/macos.zig` 와
// 동일 패턴). Linux 는 Wayland/xkbcommon 을 dlopen 하려고 시스템 dynamic loader 를
// 쓰기 위해 어차피 glibc 를 링크하므로(build.zig `link_libc = true`), timezone 도
// libc 에 위임하는 게 맞다. 이전의 자체 TZif 파서(+POSIX TZ footer/DST 계산)는
// glibc 가 이미 정확히 하는 일을 다시 구현한 것이었고, slim tzdata 의 DST 오차
// (RFC 9636 footer 미처리) 버그의 원인이기도 했다 — localtime_r 로 통일하며 제거.

const std = @import("std");
const log_time = @import("../log_time.zig");

pub const TimeFields = log_time.TimeFields;

const time_t = i64;

/// glibc `struct tm` (GNU 확장 `tm_gmtoff` / `tm_zone` 포함 — macOS BSD 와 동일 layout).
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

/// POSIX `struct timespec`.
const timespec = extern struct {
    tv_sec: time_t,
    tv_nsec: c_long,
};

/// `CLOCK_REALTIME` — POSIX 가 0 으로 못박은 값 (Linux · macOS 동일).
const CLOCK_REALTIME: c_int = 0;

// #451 — `std.time.milliTimestamp` 는 0.16 에서 없어졌고 대체는 `Io.Timestamp.now(io, …)`
// 인데, **`log.zig` 는 `Io` 를 들이지 않는다** (기록이 raw syscall 이라야 O_APPEND 원자성이
// 유지되고, 그래야 기록 호출부 297 자리가 `io` 를 들고 다니지 않는다). 릴리즈 노트가 남긴
// 다른 길인 *"go lower"* 를 택해 libc 를 직접 부른다 — 이 파일이 이미 `localtime_r` 을
// 그렇게 쓰고 있어 방식이 일관된다.
extern "c" fn clock_gettime(clk_id: c_int, tp: *timespec) c_int;

/// Unix epoch 기준 밀리초. 실패하면 음수를 돌려 호출부가 fallback 하게 한다.
fn wallClockMs() i64 {
    var ts: timespec = undefined;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) return -1;
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}

pub fn currentLocalTime() TimeFields {
    // ms / sec 동일 시각에서 함께 가져옴 — 두 번 query 하면 boundary 에서 sec 가
    // 한 칸 앞서가는 race (macOS 패턴 동일).
    const ms_total = wallClockMs();
    if (ms_total < 0) return log_time.fallback();
    const secs: time_t = @intCast(@divTrunc(ms_total, 1000));
    const ms: u16 = @intCast(@mod(ms_total, 1000));

    var t: tm = undefined;
    if (localtime_r(&secs, &t) == null) return log_time.fallback();
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
    return @intCast(std.os.linux.getpid());
}
