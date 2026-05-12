// Linux log impl — system-dependent pieces only. Shared formatting / file IO
// lives in `log.zig`. Log file follows XDG state:
// `~/.local/state/tildaz/tildaz.log`.

const std = @import("std");

pub const TimeFields = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    min: u8,
    sec: u8,
    ms: u16,
};

pub fn currentLocalTime() TimeFields {
    // No-libc cross builds do not have a portable localtime_r path. Use UTC
    // fields for Linux logs until the Linux host grows a fuller OS service
    // layer.
    const ms_total = std.time.milliTimestamp();
    if (ms_total < 0) {
        return .{ .year = 1970, .month = 1, .day = 1, .hour = 0, .min = 0, .sec = 0, .ms = 0 };
    }

    const secs_total: u64 = @intCast(@divTrunc(ms_total, 1000));
    const ms: u16 = @intCast(@mod(ms_total, 1000));
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs_total };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_secs.getDaySeconds();

    return .{
        .year = @intCast(year_day.year),
        .month = @intCast(month_day.month.numeric()),
        .day = @intCast(month_day.day_index + 1),
        .hour = @intCast(day_secs.getHoursIntoDay()),
        .min = @intCast(day_secs.getMinutesIntoHour()),
        .sec = @intCast(day_secs.getSecondsIntoMinute()),
        .ms = ms,
    };
}

pub fn currentPid() u64 {
    return @intCast(std.os.linux.getpid());
}

pub fn resolvePath(buf: []u8) ?[]const u8 {
    const home_slice = std.posix.getenv("HOME") orelse return null;
    const dir_suffix = "/.local/state/tildaz";
    const file_suffix = "/tildaz.log";
    if (home_slice.len + dir_suffix.len + file_suffix.len >= buf.len) return null;

    @memcpy(buf[0..home_slice.len], home_slice);
    @memcpy(buf[home_slice.len..][0..dir_suffix.len], dir_suffix);
    const dir_end = home_slice.len + dir_suffix.len;

    std.fs.makeDirAbsolute(buf[0..dir_end]) catch {};

    @memcpy(buf[dir_end..][0..file_suffix.len], file_suffix);
    return buf[0 .. dir_end + file_suffix.len];
}
