// Windows auto-start: HKCU\Software\Microsoft\Windows\CurrentVersion\Run
//
// Rationale (see issue #86):
//   - Task Scheduler (schtasks.exe + XML) 는 Group Policy / UAC 설정에 따라
//     "액세스가 거부되었습니다" 로 실패하는 환경이 있음.
//   - v0.2.7 까지는 schtasks 실패 시 legacy Registry Run 정리 단계가 스킵되어
//     stale 엔트리가 영구히 남아 오래된 exe 가 자동 실행되는 사고 발생.
//   - Quake-style 드롭다운 터미널에는 Task Scheduler 의 장점 (지연 실행 /
//     권한 승격 / 배터리 조건) 이 필요 없음.
//   - 따라서 Registry Run 을 primary mechanism 으로 단일화하고, 과거 버전이
//     만들어 둔 Task Scheduler "TildaZ" 엔트리는 마이그레이션 경로로 제거.

const std = @import("std");
const windows = std.os.windows;

const HKEY = ?*anyopaque;
const DWORD = windows.DWORD;
const WCHAR = u16;
const BYTE = windows.BYTE;
const BOOL = windows.BOOL;
const HANDLE = windows.HANDLE;

// --- Registry Run (primary) ---

const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
const KEY_SET_VALUE: DWORD = 0x0002;
const ERROR_SUCCESS: DWORD = 0;
const REG_SZ: DWORD = 1;

extern "advapi32" fn RegOpenKeyExW(HKEY, [*:0]const WCHAR, DWORD, DWORD, *HKEY) callconv(.c) DWORD;
extern "advapi32" fn RegSetValueExW(HKEY, [*:0]const WCHAR, DWORD, DWORD, ?[*]const BYTE, DWORD) callconv(.c) DWORD;
extern "advapi32" fn RegDeleteValueW(HKEY, [*:0]const WCHAR) callconv(.c) DWORD;
extern "advapi32" fn RegCloseKey(HKEY) callconv(.c) DWORD;

const RUN_KEY = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const VALUE_NAME = std.unicode.utf8ToUtf16LeStringLiteral("TildaZ");

extern "kernel32" fn GetModuleFileNameW(?HANDLE, [*]WCHAR, DWORD) callconv(.c) DWORD;

// --- Task Scheduler (legacy cleanup only) ---

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

/// 기존 버전이 만든 Task Scheduler "TildaZ" 엔트리를 조용히 제거.
/// 없으면 에러 무시. 있으면 삭제. schtasks 자체가 막힌 환경이면 어차피
/// 존재도 못 했을 테니 그냥 넘겨도 안전.
fn removeLegacyTaskScheduler() void {
    const cmd_tmpl = std.unicode.utf8ToUtf16LeStringLiteral("schtasks /delete /tn \"TildaZ\" /f");
    var cmd: [cmd_tmpl.len + 1]WCHAR = undefined;
    @memcpy(cmd[0..cmd_tmpl.len], cmd_tmpl);
    cmd[cmd_tmpl.len] = 0;

    var si = STARTUPINFOW{};
    var pi: PROCESS_INFORMATION = undefined;

    if (CreateProcessW(
        null,
        @ptrCast(cmd[0..cmd_tmpl.len :0]),
        null,
        null,
        0,
        CREATE_NO_WINDOW,
        null,
        null,
        &si,
        &pi,
    ) == 0) return;

    // Best-effort migration cleanup only. Do not block startup/shutdown on an
    // external schtasks.exe process that might hang behind policy or shell
    // initialization.
    windows.CloseHandle(pi.hProcess);
    windows.CloseHandle(pi.hThread);
}

/// HKCU\Software\Microsoft\Windows\CurrentVersion\Run\TildaZ 에
/// 현재 실행 중인 tildaz.exe 의 풀 경로를 "따옴표로 감싼" 형태로 기록.
/// 공백이 포함된 경로도 안전. 값이 이미 있으면 덮어쓰기.
///
/// 호출 실패 시 error 반환 — 호출자가 로그 남기는 것을 권장.
pub fn enable() !void {
    var path_buf: [300]WCHAR = undefined;
    const path_len = GetModuleFileNameW(null, &path_buf, path_buf.len);
    if (path_len == 0 or path_len >= path_buf.len) return error.GetModuleFileNameFailed;

    var hkey: HKEY = null;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, RUN_KEY, 0, KEY_SET_VALUE, &hkey) != ERROR_SUCCESS) {
        return error.RegOpenKeyFailed;
    }
    defer _ = RegCloseKey(hkey);

    // "<exe path>" + NUL — quote 로 감싸 경로 공백 대비
    var quoted: [path_buf.len + 3]WCHAR = undefined;
    quoted[0] = '"';
    @memcpy(quoted[1..][0..path_len], path_buf[0..path_len]);
    quoted[1 + path_len] = '"';
    quoted[1 + path_len + 1] = 0;
    const total_wchars: DWORD = @intCast(1 + path_len + 1 + 1); // include NUL terminator
    const cb_data: DWORD = total_wchars * @sizeOf(WCHAR);

    if (RegSetValueExW(hkey, VALUE_NAME, 0, REG_SZ, @ptrCast(&quoted), cb_data) != ERROR_SUCCESS) {
        return error.RegSetValueFailed;
    }

    // 마이그레이션: 옛 버전의 Task Scheduler 엔트리 정리
    removeLegacyTaskScheduler();
}

/// Registry Run 엔트리 제거 + legacy Task Scheduler 엔트리도 같이 정리.
/// 실패는 모두 무시 (에러 전파 없음).
pub fn disable() void {
    var hkey: HKEY = null;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, RUN_KEY, 0, KEY_SET_VALUE, &hkey) == ERROR_SUCCESS) {
        defer _ = RegCloseKey(hkey);
        _ = RegDeleteValueW(hkey, VALUE_NAME);
    }

    removeLegacyTaskScheduler();
}
