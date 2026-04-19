// Unified log file at %APPDATA%\tildaz\tildaz.log
//
// Purpose:
//   - boot / exit / autostart / conpty 등 런타임 이벤트 타임라인
//   - perf 스냅샷 블록 (Ctrl+Shift+P) 도 같은 파일에 이어 쌓임
//   - 배포 환경에서도 동작하도록 %APPDATA%\tildaz\ 에 기록
//     (기존 perf.zig 는 C:\tildaz_win\perf.log 에 하드코딩되어 있었음)
//
// 포맷:
//   [YYYY-MM-DD HH:MM:SS.mmm] [category] <message>\n
//
// perf 스냅샷처럼 여러 줄 블록은 appendBlock 으로 원문 그대로 append.

const std = @import("std");

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
extern "kernel32" fn GetModuleFileNameW(?HANDLE, [*]WCHAR, DWORD) callconv(.c) DWORD;
extern "kernel32" fn GetCurrentProcessId() callconv(.c) DWORD;

/// `%APPDATA%\tildaz\tildaz.log` 의 full UTF-8 path 를 buf 에 작성하고 slice 반환.
/// 성공 시 `%APPDATA%\tildaz` 디렉토리 존재를 보장. 실패 시 null.
fn resolvePath(buf: []u8) ?[]const u8 {
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

    // ensure directory exists (EEXIST 무시)
    std.fs.makeDirAbsolute(buf[0..dir_end]) catch {};

    // append "\tildaz.log"
    @memcpy(buf[dir_end..][0..file_suffix.len], file_suffix);
    const total = dir_end + file_suffix.len;
    return buf[0..total];
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
    var st: SYSTEMTIME = undefined;
    GetLocalTime(&st);

    var buf: [2048]u8 = undefined;
    const prefix = std.fmt.bufPrint(
        &buf,
        "[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}] [{s}] ",
        .{ st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, category },
    ) catch return;

    const body = std.fmt.bufPrint(buf[prefix.len..], fmt, args) catch return;

    const total = prefix.len + body.len;
    if (total + 1 > buf.len) return;
    buf[total] = '\n';
    writeRaw(buf[0 .. total + 1]);
}

/// 여러 줄 블록을 타임스탬프/카테고리 prefix 없이 그대로 append.
/// perf 스냅샷처럼 자체 헤더/포맷을 가진 텍스트에 사용.
pub fn appendBlock(text: []const u8) void {
    writeRaw(text);
}

/// 부팅 시 `[boot] tildaz v<ver> pid=<pid> exe=<full path>` 기록.
pub fn logStart(version: []const u8) void {
    var path_buf: [300]WCHAR = undefined;
    const path_wlen = GetModuleFileNameW(null, &path_buf, path_buf.len);
    var path_utf8: [600]u8 = undefined;
    const path_utf8_len: usize = if (path_wlen > 0)
        (std.unicode.utf16LeToUtf8(&path_utf8, path_buf[0..path_wlen]) catch 0)
    else
        0;

    const pid = GetCurrentProcessId();
    appendLine("boot", "tildaz v{s}  pid={d}  exe={s}", .{
        version,
        pid,
        path_utf8[0..path_utf8_len],
    });
}

/// 정상 종료 시 `[exit] tildaz v<ver> pid=<pid>` 기록.
pub fn logStop(version: []const u8) void {
    const pid = GetCurrentProcessId();
    appendLine("exit", "tildaz v{s}  pid={d}", .{ version, pid });
}
