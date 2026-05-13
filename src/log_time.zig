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

pub fn fallback() TimeFields {
    return .{ .year = 1970, .month = 1, .day = 1, .hour = 0, .min = 0, .sec = 0, .ms = 0 };
}

pub fn fromUnixMillis(ms_total: i64, utc_offset_seconds: i32) TimeFields {
    if (ms_total < 0) return fallback();

    const unix_secs = @divTrunc(ms_total, 1000);
    const local_secs = std.math.add(i64, unix_secs, utc_offset_seconds) catch return fallback();
    if (local_secs < 0) return fallback();

    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(local_secs) };
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
        .ms = @intCast(@mod(ms_total, 1000)),
    };
}

test "UTC offset conversion keeps milliseconds" {
    const t = fromUnixMillis(1234, 9 * 60 * 60);
    try std.testing.expectEqual(@as(u16, 1970), t.year);
    try std.testing.expectEqual(@as(u8, 1), t.month);
    try std.testing.expectEqual(@as(u8, 1), t.day);
    try std.testing.expectEqual(@as(u8, 9), t.hour);
    try std.testing.expectEqual(@as(u8, 0), t.min);
    try std.testing.expectEqual(@as(u8, 1), t.sec);
    try std.testing.expectEqual(@as(u16, 234), t.ms);
}

test "negative UTC offset can cross to previous day" {
    const t = fromUnixMillis(34 * 60 * 60 * 1000, -12 * 60 * 60);
    try std.testing.expectEqual(@as(u16, 1970), t.year);
    try std.testing.expectEqual(@as(u8, 1), t.month);
    try std.testing.expectEqual(@as(u8, 1), t.day);
    try std.testing.expectEqual(@as(u8, 22), t.hour);
}
