const std = @import("std");
const windows = std.os.windows;

const HKEY = ?*anyopaque;
const DWORD = windows.DWORD;
const WCHAR = u16;
const BYTE = windows.BYTE;
const BOOL = windows.BOOL;
const HANDLE = windows.HANDLE;

// --- Registry (하위 호환성 정리용) ---

const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
const KEY_SET_VALUE: DWORD = 0x0002;
const ERROR_SUCCESS: DWORD = 0;

extern "advapi32" fn RegOpenKeyExW(HKEY, [*:0]const WCHAR, DWORD, DWORD, *HKEY) callconv(.c) DWORD;
extern "advapi32" fn RegDeleteValueW(HKEY, [*:0]const WCHAR) callconv(.c) DWORD;
extern "advapi32" fn RegCloseKey(HKEY) callconv(.c) DWORD;

const RUN_KEY = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const VALUE_NAME = std.unicode.utf8ToUtf16LeStringLiteral("TildaZ");

fn removeRegistryEntry() void {
    var hkey: HKEY = null;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, RUN_KEY, 0, KEY_SET_VALUE, &hkey) != ERROR_SUCCESS) return;
    defer _ = RegCloseKey(hkey);
    _ = RegDeleteValueW(hkey, VALUE_NAME);
}

// --- Task Scheduler (schtasks.exe + XML) ---

const STARTUPINFOW = extern struct {
    cb: DWORD = @sizeOf(STARTUPINFOW),
    lpReserved: ?[*:0]WCHAR = null,
    lpDesktop: ?[*:0]WCHAR = null,
    lpTitle: ?[*:0]WCHAR = null,
    dwX: DWORD = 0,
    dwY: DWORD = 0,
    dwXSize: DWORD = 0,
    dwYSize: DWORD = 0,
    dwXCountChars: DWORD = 0,
    dwYCountChars: DWORD = 0,
    dwFillAttribute: DWORD = 0,
    dwFlags: DWORD = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*BYTE = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

const CREATE_NO_WINDOW: DWORD = 0x08000000;
const INFINITE: DWORD = 0xFFFFFFFF;

extern "kernel32" fn CreateProcessW(
    ?[*:0]const WCHAR,
    [*:0]WCHAR,
    ?*anyopaque,
    ?*anyopaque,
    BOOL,
    DWORD,
    ?*anyopaque,
    ?[*:0]const WCHAR,
    *STARTUPINFOW,
    *PROCESS_INFORMATION,
) callconv(.c) BOOL;
extern "kernel32" fn WaitForSingleObject(HANDLE, DWORD) callconv(.c) DWORD;
extern "kernel32" fn GetExitCodeProcess(HANDLE, *DWORD) callconv(.c) BOOL;
extern "kernel32" fn GetModuleFileNameW(?HANDLE, [*]WCHAR, DWORD) callconv(.c) DWORD;
extern "kernel32" fn GetTempPathW(DWORD, [*]WCHAR) callconv(.c) DWORD;
extern "kernel32" fn DeleteFileW([*:0]const WCHAR) callconv(.c) BOOL;
extern "kernel32" fn CreateFileW([*:0]const WCHAR, DWORD, DWORD, ?*anyopaque, DWORD, DWORD, ?HANDLE) callconv(.c) HANDLE;
extern "kernel32" fn WriteFile(HANDLE, [*]const u8, DWORD, ?*DWORD, ?*anyopaque) callconv(.c) BOOL;

const GENERIC_WRITE: DWORD = 0x40000000;
const CREATE_ALWAYS: DWORD = 2;
const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

fn runSchtasks(cmd: [*:0]WCHAR) !void {
    var si = STARTUPINFOW{};
    var pi: PROCESS_INFORMATION = undefined;

    if (CreateProcessW(null, cmd, null, null, 0, CREATE_NO_WINDOW, null, null, &si, &pi) == 0)
        return error.CreateProcessFailed;

    defer {
        windows.CloseHandle(pi.hProcess);
        windows.CloseHandle(pi.hThread);
    }

    _ = WaitForSingleObject(pi.hProcess, INFINITE);

    var exit_code: DWORD = 1;
    _ = GetExitCodeProcess(pi.hProcess, &exit_code);
    if (exit_code != 0) return error.SchtasksFailed;
}

fn writeXmlFile(xml_path: [*:0]const WCHAR, exe_path_utf8: []const u8) !void {
    const handle = CreateFileW(xml_path, GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (handle == INVALID_HANDLE_VALUE) return error.CreateFileFailed;
    defer windows.CloseHandle(handle);

    const xml_prefix =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
        \\  <Triggers>
        \\    <LogonTrigger>
        \\      <Enabled>true</Enabled>
        \\      <Delay>PT0S</Delay>
        \\    </LogonTrigger>
        \\  </Triggers>
        \\  <Principals>
        \\    <Principal>
        \\      <LogonType>InteractiveToken</LogonType>
        \\      <RunLevel>LeastPrivilege</RunLevel>
        \\    </Principal>
        \\  </Principals>
        \\  <Settings>
        \\    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
        \\    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
        \\    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
        \\    <Priority>4</Priority>
        \\  </Settings>
        \\  <Actions>
        \\    <Exec>
        \\      <Command>
    ;
    const xml_suffix =
        \\</Command>
        \\    </Exec>
        \\  </Actions>
        \\</Task>
    ;

    var written: DWORD = 0;
    if (WriteFile(handle, xml_prefix.ptr, xml_prefix.len, &written, null) == 0) return error.WriteFailed;
    if (WriteFile(handle, exe_path_utf8.ptr, @intCast(exe_path_utf8.len), &written, null) == 0) return error.WriteFailed;
    if (WriteFile(handle, xml_suffix.ptr, xml_suffix.len, &written, null) == 0) return error.WriteFailed;
}

pub fn enable() !void {
    // exe 경로 획득
    var path_buf: [260]WCHAR = undefined;
    const len = GetModuleFileNameW(null, &path_buf, path_buf.len);
    if (len == 0) return error.GetModuleFileNameFailed;

    // WCHAR → UTF-8
    var exe_utf8: [520]u8 = undefined;
    const utf8_len = std.unicode.utf16LeToUtf8(&exe_utf8, path_buf[0..len]) catch return error.EncodingFailed;

    // %TEMP%\tildaz_task.xml 경로 구성
    var temp_buf: [260]WCHAR = undefined;
    const temp_len = GetTempPathW(temp_buf.len, &temp_buf);
    if (temp_len == 0) return error.GetTempPathFailed;

    const xml_name = std.unicode.utf8ToUtf16LeStringLiteral("tildaz_task.xml");
    var xml_path: [300]WCHAR = undefined;
    @memcpy(xml_path[0..temp_len], temp_buf[0..temp_len]);
    @memcpy(xml_path[temp_len..][0..xml_name.len], xml_name);
    xml_path[temp_len + xml_name.len] = 0;
    const xml_path_z: [*:0]const WCHAR = @ptrCast(xml_path[0 .. temp_len + xml_name.len :0]);

    // XML 파일 작성
    try writeXmlFile(xml_path_z, exe_utf8[0..utf8_len]);
    defer _ = DeleteFileW(xml_path_z);

    // schtasks /create /tn "TildaZ" /xml "<xml_path>" /f
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("schtasks /create /tn \"TildaZ\" /xml \"");
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\" /f");

    var cmd: [600]WCHAR = undefined;
    var pos: usize = 0;
    @memcpy(cmd[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    const xml_path_len = temp_len + xml_name.len;
    @memcpy(cmd[pos..][0..xml_path_len], xml_path[0..xml_path_len]);
    pos += xml_path_len;

    @memcpy(cmd[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    cmd[pos] = 0;

    try runSchtasks(@ptrCast(cmd[0..pos :0]));

    removeRegistryEntry();
}

pub fn disable() void {
    const cmd_tmpl = std.unicode.utf8ToUtf16LeStringLiteral("schtasks /delete /tn \"TildaZ\" /f");
    var cmd: [cmd_tmpl.len + 1]WCHAR = undefined;
    @memcpy(cmd[0..cmd_tmpl.len], cmd_tmpl);
    cmd[cmd_tmpl.len] = 0;
    runSchtasks(@ptrCast(cmd[0..cmd_tmpl.len :0])) catch {};

    removeRegistryEntry();
}
