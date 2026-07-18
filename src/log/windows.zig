// Windows 의 log impl — 시스템 의존 부분 (local time / pid) 만. 공통
// formatting / writeRaw / process-lifetime 로그 파일 경로는 `log.zig`
// (단일 소스, #282 G3).

const std = @import("std");
const log_time = @import("../log_time.zig");

const DWORD = std.os.windows.DWORD;

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
