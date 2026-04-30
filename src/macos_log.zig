// Unified log file at `~/Library/Logs/tildaz.log` (Apple HIG — Console.app
// 자동 인덱싱). Windows `tildaz_log.zig` 와 동등 패턴 (boot/exit/runtime
// 이벤트 타임라인 + perf 블록). cross-platform 추상화는 별도 후속 — 현재는
// platform 별 모듈.
//
// 포맷:
//   [YYYY-MM-DD HH:MM:SS.mmm] [category] <message>\n

const std = @import("std");
const c = std.c;
const builtin = @import("builtin");

extern "c" fn getpid() c_int;

/// `~/Library/Logs/tildaz.log` 의 absolute UTF-8 path 를 buf 에 작성하고 slice
/// 반환. 성공 시 `~/Library/Logs/` 디렉토리 존재 보장 (macOS default 생성됨).
/// 실패 시 null.
pub fn resolvePath(buf: []u8) ?[]const u8 {
    const home = std.c.getenv("HOME") orelse return null;
    const home_slice = std.mem.span(home);
    const suffix = "/Library/Logs/tildaz.log";
    if (home_slice.len + suffix.len >= buf.len) return null;
    @memcpy(buf[0..home_slice.len], home_slice);
    @memcpy(buf[home_slice.len..][0..suffix.len], suffix);
    return buf[0 .. home_slice.len + suffix.len];
}

fn writeRaw(text: []const u8) void {
    var path_buf: [520]u8 = undefined;
    const path = resolvePath(&path_buf) orelse return;
    const f = std.fs.createFileAbsolute(path, .{ .truncate = false, .read = false }) catch return;
    defer f.close();
    f.seekFromEnd(0) catch {};
    f.writeAll(text) catch {};
}

/// `[ts] [category] <fmt args>\n` 한 줄 append.
pub fn appendLine(category: []const u8, comptime fmt: []const u8, args: anytype) void {
    // wall-clock millis 으로 타임스탬프.
    const ms_since_epoch = std.time.milliTimestamp();
    const secs_total = @divTrunc(ms_since_epoch, 1000);
    const millis: u32 = @intCast(@mod(ms_since_epoch, 1000));
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(secs_total) };
    const day_secs = epoch_secs.getDaySeconds();
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var buf: [2048]u8 = undefined;
    const prefix = std.fmt.bufPrint(
        &buf,
        "[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}] [{s}] ",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
            millis,
            category,
        },
    ) catch return;

    const body = std.fmt.bufPrint(buf[prefix.len..], fmt, args) catch return;

    const total = prefix.len + body.len;
    if (total + 1 > buf.len) return;
    buf[total] = '\n';
    writeRaw(buf[0 .. total + 1]);
}

/// 여러 줄 블록을 타임스탬프/카테고리 prefix 없이 그대로 append.
pub fn appendBlock(text: []const u8) void {
    writeRaw(text);
}

/// 부팅 시 `[boot] tildaz v<ver> pid=<pid> exe=<full path>` 기록.
pub fn logStart(version: []const u8) void {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_buf) catch "(unknown)";
    appendLine("boot", "tildaz v{s}  pid={d}  exe={s}", .{
        version,
        getpid(),
        exe_path,
    });
}

/// 정상 종료 시 `[exit] tildaz v<ver> pid=<pid>` 기록.
pub fn logStop(version: []const u8) void {
    appendLine("exit", "tildaz v{s}  pid={d}", .{ version, getpid() });
}
