// Linux log impl — system-dependent pieces only. Shared formatting / file IO
// lives in `log.zig`. Log file follows XDG state:
// `~/.local/state/tildaz/tildazN.log`.
//
// #282 후속 — 로컬 시각은 glibc `localtime_r` 로 구한다 (macOS `log/macos.zig` 와
// 동일 패턴). Linux 는 Wayland/xkbcommon 을 dlopen 하려고 시스템 dynamic loader 를
// 쓰기 위해 어차피 glibc 를 링크하므로(build.zig `link_libc = true`), timezone 도
// libc 에 위임하는 게 맞다. 이전의 자체 TZif 파서(+POSIX TZ footer/DST 계산)는
// glibc 가 이미 정확히 하는 일을 다시 구현한 것이었고, slim tzdata 의 DST 오차
// (RFC 9636 footer 미처리) 버그의 원인이기도 했다 — localtime_r 로 통일하며 제거.

const std = @import("std");
const log_time = @import("../log_time.zig");
const instance_context = @import("../instance_context.zig");

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

pub fn currentLocalTime() TimeFields {
    // ms / sec 동일 시각에서 함께 가져옴 — 두 번 query 하면 boundary 에서 sec 가
    // 한 칸 앞서가는 race (macOS 패턴 동일).
    const ms_total = std.time.milliTimestamp();
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

pub fn resolvePath(buf: []u8) ?[]const u8 {
    const home_slice = std.posix.getenv("HOME") orelse return null;
    const dir_suffix = "/.local/state/tildaz";
    if (home_slice.len + dir_suffix.len + 32 >= buf.len) return null;

    @memcpy(buf[0..home_slice.len], home_slice);
    @memcpy(buf[home_slice.len..][0..dir_suffix.len], dir_suffix);
    const dir_end = home_slice.len + dir_suffix.len;

    ensureDir(buf[0..dir_end]) catch {};

    const suffix = std.fmt.bufPrint(buf[dir_end..], "/tildaz{d}.log", .{instance_context.workerIndex() orelse 0}) catch return null;
    return buf[0 .. dir_end + suffix.len];
}

fn ensureDir(dir: []const u8) !void {
    // std.fs.cwd().makePath = 중간 단계 포함 자동 생성 (`~/.local/state/tildaz` 처럼
    // 깊은 경로). 절대경로라 leading `/` 유지 → cwd dirfd 무시하고 그대로 생성.
    // paths.zig 와 동일 — 자체 재귀 mkdir 을 std 로 통일 (#282 후속).
    try std.fs.cwd().makePath(dir);
}
