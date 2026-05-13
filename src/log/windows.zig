// Windows 의 log impl — 시스템 의존 부분만. 공통 formatting / writeRaw 는
// `log.zig`. 로그 파일은 `%APPDATA%\tildaz\tildaz.log`.

const std = @import("std");
const log_time = @import("../log_time.zig");

const WCHAR = u16;
const DWORD = std.os.windows.DWORD;
const HANDLE = std.os.windows.HANDLE;

const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};

extern "kernel32" fn GetLocalTime(*SYSTEMTIME) callconv(.c) void;
extern "kernel32" fn GetEnvironmentVariableW([*:0]const WCHAR, ?[*]WCHAR, u32) callconv(.c) u32;
extern "kernel32" fn GetCurrentProcessId() callconv(.c) DWORD;

pub const TimeFields = log_time.TimeFields;

pub fn currentLocalTime() TimeFields {
    var st: SYSTEMTIME = undefined;
    GetLocalTime(&st);
    return .{
        .year = st.wYear,
        .month = @intCast(st.wMonth),
        .day = @intCast(st.wDay),
        .hour = @intCast(st.wHour),
        .min = @intCast(st.wMinute),
        .sec = @intCast(st.wSecond),
        .ms = st.wMilliseconds,
    };
}

pub fn currentPid() u64 {
    return GetCurrentProcessId();
}

/// `%APPDATA%\tildaz\tildaz.log` 의 full UTF-8 path 를 buf 에 작성하고 slice
/// 반환. 성공 시 `%APPDATA%\tildaz` 디렉토리 존재 보장. 실패 시 null.
pub fn resolvePath(buf: []u8) ?[]const u8 {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("APPDATA");
    var wbuf: [260]WCHAR = undefined;
    const wlen = GetEnvironmentVariableW(name, &wbuf, wbuf.len);
    if (wlen == 0 or wlen >= wbuf.len) return null;

    const appdata_len = std.unicode.utf16LeToUtf8(buf, wbuf[0..wlen]) catch return null;

    const dir_suffix = "\\tildaz";
    const file_suffix = "\\tildaz.log";
    if (appdata_len + dir_suffix.len + file_suffix.len >= buf.len) return null;

    @memcpy(buf[appdata_len..][0..dir_suffix.len], dir_suffix);
    const dir_end = appdata_len + dir_suffix.len;

    std.fs.makeDirAbsolute(buf[0..dir_end]) catch {};

    @memcpy(buf[dir_end..][0..file_suffix.len], file_suffix);
    const total = dir_end + file_suffix.len;
    return buf[0..total];
}
