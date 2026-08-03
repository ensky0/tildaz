const std = @import("std");
const windows = std.os.windows;
const perf = @import("../../perf.zig");
const log = @import("../../log.zig");

const HANDLE = windows.HANDLE;
const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const BYTE = windows.BYTE;
const LPVOID = windows.LPVOID;
const HRESULT = windows.HRESULT;
const WCHAR = u16;

// Win32 API declarations
const COORD = extern struct {
    x: i16,
    y: i16,
};

const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD,
    lpSecurityDescriptor: ?LPVOID,
    bInheritHandle: BOOL,
};

const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?[*:0]WCHAR,
    lpDesktop: ?[*:0]WCHAR,
    lpTitle: ?[*:0]WCHAR,
    dwX: DWORD,
    dwY: DWORD,
    dwXSize: DWORD,
    dwYSize: DWORD,
    dwXCountChars: DWORD,
    dwYCountChars: DWORD,
    dwFillAttribute: DWORD,
    dwFlags: DWORD,
    wShowWindow: u16,
    cbReserved2: u16,
    lpReserved2: ?*BYTE,
    hStdInput: ?HANDLE,
    hStdOutput: ?HANDLE,
    hStdError: ?HANDLE,
};

const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW,
    lpAttributeList: ?LPPROC_THREAD_ATTRIBUTE_LIST,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

const LPPROC_THREAD_ATTRIBUTE_LIST = *anyopaque;
const HPCON = *anyopaque;

const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
const STARTF_USESTDHANDLES: DWORD = 0x00000100;
const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;

extern "kernel32" fn CreatePipe(
    hReadPipe: *HANDLE,
    hWritePipe: *HANDLE,
    lpPipeAttributes: ?*const SECURITY_ATTRIBUTES,
    nSize: DWORD,
) callconv(.c) BOOL;

extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const WCHAR) callconv(.c) ?*anyopaque;
extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(.c) ?*const anyopaque;
extern "kernel32" fn GetModuleFileNameW(hModule: ?*anyopaque, lpFilename: [*]WCHAR, nSize: DWORD) callconv(.c) DWORD;
extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const WCHAR) callconv(.c) DWORD;
const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;

// conpty.dll (Microsoft.Windows.Console.ConPTY nupkg) 의 함수 포인터.
// tildaz.exe 옆 번들 `_internal\conpty.dll` 을 LoadLibrary 로 해결한다. 번들
// 런타임은 필수 — 시작 시 hard-fail 로 검증하며 kernel32 fallback 은 없다 (#339).
const ConptyCreateFn = *const fn (COORD, HANDLE, HANDLE, DWORD, *HPCON) callconv(.c) HRESULT;
const ConptyResizeFn = *const fn (HPCON, COORD) callconv(.c) HRESULT;
const ConptyCloseFn = *const fn (HPCON) callconv(.c) void;
const ConptyShowHideFn = *const fn (HPCON, BOOL) callconv(.c) HRESULT;

var conpty_dll_loaded: bool = false;
var conpty_create_fn: ?ConptyCreateFn = null;
var conpty_resize_fn: ?ConptyResizeFn = null;
var conpty_close_fn: ?ConptyCloseFn = null;
var conpty_show_hide_fn: ?ConptyShowHideFn = null;

// `buf` 의 dir prefix (`dir_end` 까지) 뒤에 `_internal\...` suffix + NUL 을 써서
// 절대경로를 만든다. 버퍼가 모자라면 null. 반환 슬라이스는 buf 를 가리키므로
// 다음 호출이 덮어쓴다 (호출처가 즉시 사용).
fn buildInternalPath(buf: *[512]WCHAR, dir_end: usize, comptime suffix_utf8: []const u8) ?[:0]const WCHAR {
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral(suffix_utf8);
    if (dir_end + suffix.len + 1 > buf.len) return null; // suffix + NUL 공간 부족
    @memcpy(buf[dir_end..][0..suffix.len], suffix);
    buf[dir_end + suffix.len] = 0;
    return buf[0 .. dir_end + suffix.len :0];
}

// tildaz.exe 옆 번들 `_internal\conpty.dll` 을 절대경로로 로드한다. 릴리즈 번들은
// Microsoft 런타임 2개 (conpty.dll + OpenConsole.exe) 를 `_internal\` 하위에 숨겨
// 최상위엔 tildaz.exe 만 보이게 하고, conpty.dll 이 sibling OpenConsole.exe 를
// 스폰한다. 두 파일의 존재는 시작 시 bundledRuntimeFilesPresent() 가 hard-fail 로
// 보장하므로 (#339) 여기선 conpty.dll 로드만 한다.
//
// bare name 대신 절대경로 로드라 CWD / PATH 에 심어진 가짜 conpty.dll 을 무는
// DLL search-order hijacking 도 피한다.
fn loadConptyFromInternal() ?*anyopaque {
    var buf: [512]WCHAR = undefined;
    const n = GetModuleFileNameW(null, &buf, buf.len);
    if (n == 0 or n >= buf.len) return null; // 0 = 실패, ==len = 경로 잘림
    // tildaz.exe 파일명을 지우고 마지막 경로 구분자 다음 = dir prefix 끝.
    var dir_end: usize = n;
    while (dir_end > 0) : (dir_end -= 1) {
        if (buf[dir_end - 1] == '\\' or buf[dir_end - 1] == '/') break;
    }
    const dll = buildInternalPath(&buf, dir_end, "_internal\\conpty.dll") orelse return null;
    return LoadLibraryW(dll.ptr);
}

fn ensureConptyDll() void {
    if (conpty_dll_loaded) return;
    conpty_dll_loaded = true;
    const mod = loadConptyFromInternal() orelse {
        // 파일 존재는 시작 시 이미 hard-fail 검증됨 — 여기 도달 = 로드 자체 실패
        // (손상 / arch mismatch 등). ConPty.init 이 create_fn null 을 에러로 처리.
        log.appendLine("conpty", "bundled _internal\\conpty.dll could not be loaded", .{});
        return;
    };
    // ARM64 Windows 의 fn ptr alignment 가 4 (x64 는 1) — `GetProcAddress`
    // 반환은 `?*const anyopaque` (alignment 1) 라 cross-platform fn ptr 변환에
    // `@alignCast` 명시 필요 (#191).
    conpty_create_fn = @ptrCast(@alignCast(GetProcAddress(mod, "ConptyCreatePseudoConsole")));
    conpty_resize_fn = @ptrCast(@alignCast(GetProcAddress(mod, "ConptyResizePseudoConsole")));
    conpty_close_fn = @ptrCast(@alignCast(GetProcAddress(mod, "ConptyClosePseudoConsole")));
    // ShowHide 는 optional — 실패해도 fatal 아님. Windows Terminal 이 호출하는
    // 순서를 따라 CreateProcessW 전에 호출해 OpenConsole 의 pseudo window 를
    // 활성화한다.
    conpty_show_hide_fn = @ptrCast(@alignCast(GetProcAddress(mod, "ConptyShowHidePseudoConsole")));
    if (conpty_create_fn == null or conpty_resize_fn == null or conpty_close_fn == null) {
        log.appendLine("conpty", "bundled conpty.dll loaded but required symbols missing", .{});
        conpty_create_fn = null;
        conpty_resize_fn = null;
        conpty_close_fn = null;
        conpty_show_hide_fn = null;
        return;
    }
    // 성공 로그는 두지 않는다 — fallback 이 없어 "앱이 돌아감 = 번들 사용" 이
    // 자명하므로 (#339). 진단에 의미 있는 건 위의 실패 로그들뿐이다.
}

/// 번들 `_internal\` 런타임이 tildaz.exe 옆에 완전히 있는지 (conpty.dll +
/// OpenConsole.exe 둘 다). Windows 는 이 둘이 필수라 host 가 시작 시 이 검사로
/// hard-fail 한다 (#339). 파일이 확실히 없을 때만 false — exe 경로 판정 불가 등
/// 불확실한 경우엔 시작을 막지 않도록 true 를 반환한다 (확신할 때만 차단).
pub fn bundledRuntimeFilesPresent() bool {
    var buf: [512]WCHAR = undefined;
    const n = GetModuleFileNameW(null, &buf, buf.len);
    if (n == 0 or n >= buf.len) return true; // 경로 판정 불가 → 차단 안 함
    var dir_end: usize = n;
    while (dir_end > 0) : (dir_end -= 1) {
        if (buf[dir_end - 1] == '\\' or buf[dir_end - 1] == '/') break;
    }
    const dll = buildInternalPath(&buf, dir_end, "_internal\\conpty.dll") orelse return true;
    if (GetFileAttributesW(dll.ptr) == INVALID_FILE_ATTRIBUTES) return false;
    const oc = buildInternalPath(&buf, dir_end, "_internal\\OpenConsole.exe") orelse return true;
    if (GetFileAttributesW(oc.ptr) == INVALID_FILE_ATTRIBUTES) return false;
    return true;
}

extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?LPPROC_THREAD_ATTRIBUTE_LIST,
    dwAttributeCount: DWORD,
    dwFlags: DWORD,
    lpSize: *usize,
) callconv(.c) BOOL;

extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
    dwFlags: DWORD,
    Attribute: usize,
    lpValue: ?*anyopaque,
    cbSize: usize,
    lpPreviousValue: ?*anyopaque,
    lpReturnSize: ?*usize,
) callconv(.c) BOOL;

extern "kernel32" fn DeleteProcThreadAttributeList(
    lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
) callconv(.c) void;

extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const WCHAR,
    lpCommandLine: ?[*:0]WCHAR,
    lpProcessAttributes: ?*const SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*const SECURITY_ATTRIBUTES,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?LPVOID,
    lpCurrentDirectory: ?[*:0]const WCHAR,
    lpStartupInfo: *STARTUPINFOEXW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.c) BOOL;

extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]BYTE,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: ?*DWORD,
    lpOverlapped: ?LPVOID,
) callconv(.c) BOOL;

extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const BYTE,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: ?*DWORD,
    lpOverlapped: ?LPVOID,
) callconv(.c) BOOL;

extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.c) BOOL;

extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.c) DWORD;

extern "kernel32" fn GetLastError() callconv(.c) DWORD;

extern "kernel32" fn CreateNamedPipeW(
    lpName: [*:0]const WCHAR,
    dwOpenMode: DWORD,
    dwPipeMode: DWORD,
    nMaxInstances: DWORD,
    nOutBufferSize: DWORD,
    nInBufferSize: DWORD,
    nDefaultTimeOut: DWORD,
    lpSecurityAttributes: ?*const SECURITY_ATTRIBUTES,
) callconv(.c) HANDLE;

extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const WCHAR,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*const SECURITY_ATTRIBUTES,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.c) HANDLE;

extern "kernel32" fn GetOverlappedResult(
    hFile: HANDLE,
    lpOverlapped: *OVERLAPPED,
    lpNumberOfBytesTransferred: *DWORD,
    bWait: BOOL,
) callconv(.c) BOOL;

extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*anyopaque,
    bManualReset: BOOL,
    bInitialState: BOOL,
    lpName: ?[*:0]const WCHAR,
) callconv(.c) ?HANDLE;

extern "kernel32" fn GetCurrentProcessId() callconv(.c) DWORD;
extern "kernel32" fn SetEnvironmentVariableW([*:0]const u16, ?[*:0]const u16) callconv(.c) c_int;
extern "kernel32" fn GetEnvironmentVariableW([*:0]const u16, ?[*]u16, DWORD) callconv(.c) DWORD;

const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: DWORD = 0,
    OffsetHigh: DWORD = 0,
    hEvent: ?HANDLE = null,
};

const PIPE_ACCESS_INBOUND: DWORD = 0x00000001;
const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
const PIPE_TYPE_BYTE: DWORD = 0x00000000;
const PIPE_WAIT: DWORD = 0x00000000;
const GENERIC_WRITE: DWORD = 0x40000000;
const OPEN_EXISTING: DWORD = 3;
const WAIT_OBJECT_0: DWORD = 0;
const ERROR_IO_PENDING: DWORD = 997;
const READ_BUF_SIZE: usize = 128 * 1024;

pub const ConPty = struct {
    hpc: HPCON,
    // 두 개의 파이프:
    //   input:  우리가 write (keystrokes) → conhost reads.      익명 파이프, 동기.
    //   output: conhost writes (display)  → 우리가 overlapped read. named pipe, 우리 쪽 OVERLAPPED.
    pipe_in_write: HANDLE, // 키보드: sync write
    pipe_out_read: HANDLE, // 디스플레이: overlapped read
    read_event: HANDLE,
    process_info: PROCESS_INFORMATION,
    attr_list_buf: []u8,
    read_thread: ?std.Thread = null,
    wait_thread: ?std.Thread = null,
    allocator: std.mem.Allocator,

    pub const ReadCallback = *const fn (data: []const u8, userdata: ?*anyopaque) void;
    pub const ExitCallback = *const fn (userdata: ?*anyopaque) void;
    pub const EnvVar = struct { name: [*:0]const u16, value: [*:0]const u16 };

    /// `cwd` — 셸의 시작 디렉토리 (#366). `null` 이면 홈 (#265). 일반 셸은 Windows
    /// 경로 (`C:\…`), WSL 탭은 Linux 경로 (`/home/me`) 를 받는다 (`isWslCommand`).
    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16, shell: [*:0]const WCHAR, extra_env: ?[]const EnvVar, cwd: ?[:0]const WCHAR) !ConPty {
        // ── Input pipe (익명, sync): 우리 = write, conhost = read
        var pipe_in_read: HANDLE = undefined;
        var pipe_in_write: HANDLE = undefined;
        if (CreatePipe(&pipe_in_read, &pipe_in_write, null, 0) == 0) return error.CreatePipeFailed;
        errdefer _ = CloseHandle(pipe_in_write);
        // pipe_in_read 는 CreatePseudoConsole 후에 닫음

        // ── Output pipe (named, 우리 쪽만 overlapped): conhost = write(sync), 우리 = read(overlapped)
        const S = struct {
            var counter: u32 = 0;
        };
        const pid = GetCurrentProcessId();
        const seq = @atomicRmw(u32, &S.counter, .Add, 1, .monotonic);
        var pipe_name_u8: [256]u8 = undefined;
        const pipe_name_str = std.fmt.bufPrint(
            &pipe_name_u8,
            "\\\\.\\pipe\\tildaz_{d}_{d}",
            .{ pid, seq },
        ) catch return error.CreatePipeFailed;
        // #298 — ASCII u8→u16 수동 widening → std.unicode.utf8ToUtf16Le (pipe 이름은
        // ASCII 뿐이라 동작 동일).
        var pipe_name: [128]WCHAR = undefined;
        const pipe_name_n = std.unicode.utf8ToUtf16Le(&pipe_name, pipe_name_str) catch return error.CreatePipeFailed;
        pipe_name[pipe_name_n] = 0;
        const pipe_name_z: [*:0]const WCHAR = @ptrCast(pipe_name[0..pipe_name_n :0]);

        const pipe_out_read = CreateNamedPipeW(
            pipe_name_z,
            PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED,
            PIPE_TYPE_BYTE | PIPE_WAIT,
            1,
            READ_BUF_SIZE, // out buffer (INBOUND 이라 unused)
            READ_BUF_SIZE, // in buffer — conhost 가 여기 써주고 우리가 읽음
            0,
            null,
        );
        if (pipe_out_read == INVALID_HANDLE_VALUE) {
            _ = CloseHandle(pipe_in_read);
            return error.CreatePipeFailed;
        }
        errdefer _ = CloseHandle(pipe_out_read);

        const pipe_out_write = CreateFileW(
            pipe_name_z,
            GENERIC_WRITE,
            0,
            null,
            OPEN_EXISTING,
            0, // conhost 쪽은 overlapped 불필요 (동기 write)
            null,
        );
        if (pipe_out_write == INVALID_HANDLE_VALUE) {
            _ = CloseHandle(pipe_in_read);
            return error.CreatePipeFailed;
        }
        // pipe_out_write 는 CreatePseudoConsole 후에 닫음

        const read_event = CreateEventW(null, 1, 0, null) orelse {
            _ = CloseHandle(pipe_in_read);
            _ = CloseHandle(pipe_out_write);
            return error.CreateEventFailed;
        };
        errdefer _ = CloseHandle(read_event);

        // ── Pseudo console (번들 _internal conpty.dll 필수 — kernel32 fallback 없음, #339)
        ensureConptyDll();
        const create_fn = conpty_create_fn orelse {
            // 파일 존재는 시작 시 bundledRuntimeFilesPresent() 가 hard-fail 로 이미
            // 검증했다. 여기서 null 이면 파일은 있으나 conpty.dll 로드 / 심볼 해석
            // 실패 (손상 / arch mismatch) — degrade 없이 에러.
            _ = CloseHandle(pipe_in_read);
            _ = CloseHandle(pipe_out_write);
            return error.ConptyRuntimeUnavailable;
        };
        const size = COORD{ .x = @intCast(cols), .y = @intCast(rows) };
        var hpc: HPCON = undefined;
        // 0x8 = PSEUDOCONSOLE_GLYPH_WIDTH_GRAPHEMES (Win11). 미지원 시 0 으로 재시도.
        var hr: HRESULT = create_fn(size, pipe_in_read, pipe_out_write, 0x8, &hpc);
        if (hr < 0) {
            hr = create_fn(size, pipe_in_read, pipe_out_write, 0, &hpc);
            log.appendLine("conpty", "CreatePseudoConsole flags=0x8 failed, retried with 0x0 (hr=0x{x})", .{@as(u32, @bitCast(hr))});
        }

        // CreatePseudoConsole 는 handle 을 내부 duplicate — 우리 쪽 사본은 닫아야 한다.
        _ = CloseHandle(pipe_in_read);
        _ = CloseHandle(pipe_out_write);

        if (hr < 0) return error.CreatePseudoConsoleFailed;
        errdefer conpty_close_fn.?(hpc);

        // ── ShowHide: pseudo window 를 "visible" 로 마킹 (Windows Terminal 순서 복제)
        // microsoft/terminal `ConptyConnection::Start()` 가 CreateProcessW 전에
        //   ConptyShowHidePseudoConsole(hpc, TRUE)
        // 을 호출한다. `PtySignalInputThread::_DoShowHide` 가 이 값을 연결 전에
        // 보존했다가 ConnectConsole 직후 `SetPseudoWindowVisibility(true)` 로
        // 적용한다. 호출하지 않으면 pseudo window 가 기본 hidden 상태로 남아
        // 일부 초기 처리가 지연될 수 있다.
        if (conpty_show_hide_fn) |f| {
            _ = f(hpc, 1);
        }

        // ── STARTUPINFOEX + attribute list
        var attr_list_size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_list_size);

        const attr_list_buf = try allocator.alloc(u8, attr_list_size);
        errdefer allocator.free(attr_list_buf);

        const attr_list: LPPROC_THREAD_ATTRIBUTE_LIST = @ptrCast(attr_list_buf.ptr);
        if (InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_list_size) == 0) {
            return error.InitializeAttributeListFailed;
        }

        if (UpdateProcThreadAttribute(
            attr_list,
            0,
            PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            hpc,
            @sizeOf(HPCON),
            null,
            null,
        ) == 0) {
            return error.UpdateProcThreadAttributeFailed;
        }

        var startup_info = std.mem.zeroes(STARTUPINFOEXW);
        startup_info.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
        startup_info.lpAttributeList = attr_list;
        // STARTF_USESTDHANDLES + NULL std handle (zeroes) — 이 플래그가 없으면
        // CreateProcess 가 부모(tildaz)의 비콘솔 std handle(리다이렉트된
        // 파이프/파일)을 자식 셸에 복제한다. 그러면 셸의 콘솔은 pseudoconsole
        // 인데 stdio 는 부모의 리다이렉트 대상을 가리켜, stdin 이 파이프면
        // PowerShell/cmd 가 비대화형으로 판단해 EOF 즉시 종료한다 (#338).
        // NULL std handle 로 시작한 콘솔 subsystem 자식은 자기 콘솔(=ConPTY)로
        // stdio 를 바인딩한다 — Windows Terminal ConptyConnection 과 동일.
        startup_info.StartupInfo.dwFlags = STARTF_USESTDHANDLES;

        var process_info: PROCESS_INFORMATION = undefined;

        // CreateProcessW may mutate lpCommandLine, so keep a mutable copy.
        // Size it from the validated config value instead of truncating to a
        // small fixed buffer.
        const shell_len = std.mem.len(shell);

        // ── 시작 디렉토리 — 홈 (#265) 또는 활성 탭에서 물려받은 경로 (#366)
        //
        // 일반 exe (cmd.exe / PowerShell 등) 는 lpCurrentDirectory 로 넘기면 되지만,
        // WSL 탭의 목표 위치는 Linux 쪽 경로 — Windows 경로로 표현 불가 + Windows
        // 쪽에서는 그 위치를 확인할 수도 없다. Windows Terminal 과 같은 방식으로
        // wsl 명령줄에 `--cd` 를 끼워 넣어 wsl 자신에게 위임한다
        // (microsoft/terminal PR #9223 의 MangleStartingDirectoryForWSL 패턴).
        // 사용자가 이미 `--cd` 나 단독 `~` 인자를 넣었으면 충돌하므로 건드리지 않는다.
        const L = std.unicode.utf8ToUtf16LeStringLiteral;
        const wsl_cd = wslCdInsertion(shell[0..shell_len]);

        // WSL 탭에 끼워 넣을 인자 — 물려받은 경로가 있으면 그 경로, 없으면 Linux 홈.
        // 공백이 있는 경로도 한 인자로 가도록 `"` 로 감싼다. 경로 안에 `"` 가 있으면
        // 인용이 깨지므로 (그리고 Linux 파일 이름에 `"` 는 허용된다) 그때는 상속을
        // 포기하고 홈으로 간다.
        var wsl_insert_buf: [wsl_insert_max]u16 = undefined;
        const insert: []const u16 = blk: {
            if (!wsl_cd.insert) break :blk &.{};
            if (wsl_cd.is_wsl) if (cwd) |dir| {
                const prefix = L(" --cd \"");
                const total = prefix.len + dir.len + 1;
                if (std.mem.indexOfScalar(u16, dir, '"') == null and total <= wsl_insert_buf.len) {
                    @memcpy(wsl_insert_buf[0..prefix.len], prefix);
                    @memcpy(wsl_insert_buf[prefix.len..][0..dir.len], dir);
                    wsl_insert_buf[total - 1] = '"';
                    break :blk wsl_insert_buf[0..total];
                }
            };
            break :blk L(" --cd ~");
        };

        const cmd_len = shell_len + insert.len;
        const cmd_buf = try allocator.alloc(WCHAR, cmd_len + 1);
        defer allocator.free(cmd_buf);
        @memcpy(cmd_buf[0..wsl_cd.insert_at], shell[0..wsl_cd.insert_at]);
        @memcpy(cmd_buf[wsl_cd.insert_at..][0..insert.len], insert);
        @memcpy(
            cmd_buf[wsl_cd.insert_at + insert.len ..][0 .. shell_len - wsl_cd.insert_at],
            shell[wsl_cd.insert_at..shell_len],
        );
        cmd_buf[cmd_len] = 0;

        // WSL 이 아닌 경우의 홈 = %USERPROFILE%. 환경변수가 없으면 null (기존 동작 —
        // 부모의 현재 디렉토리 상속).
        var home_buf: ?[]u16 = null;
        defer if (home_buf) |b| allocator.free(b);
        if (!wsl_cd.is_wsl) {
            const name = std.unicode.utf8ToUtf16LeStringLiteral("USERPROFILE");
            const needed = GetEnvironmentVariableW(name, null, 0);
            if (needed > 0) {
                const buf = try allocator.alloc(u16, needed);
                const copied = GetEnvironmentVariableW(name, buf.ptr, needed);
                if (copied > 0 and copied < needed) {
                    buf[copied] = 0;
                    home_buf = buf;
                } else {
                    allocator.free(buf);
                }
            }
        }
        const home_dir: ?[*:0]const WCHAR = if (home_buf) |b| @ptrCast(b.ptr) else null;
        // 물려받은 경로는 일반 셸에서만 lpCurrentDirectory 로 쓴다 — WSL 탭은 위
        // `--cd` 로 이미 넘겼고, Linux 경로를 Windows 쪽 시작 디렉토리로 줄 수 없다.
        const inherited_dir: ?[*:0]const WCHAR = if (!wsl_cd.is_wsl)
            if (cwd) |dir| dir.ptr else null
        else
            null;
        const start_dir = inherited_dir orelse home_dir;

        // 자식 프로세스에 추가 환경변수 전달 (기존값 저장 → SetEnv → CreateProcess → 복원)
        const MAX_EXTRA_ENV = 8;
        var saved_vals: [MAX_EXTRA_ENV]?[]u16 = .{null} ** MAX_EXTRA_ENV;
        errdefer {
            for (&saved_vals) |*maybe_buf| {
                if (maybe_buf.*) |buf| {
                    allocator.free(buf);
                    maybe_buf.* = null;
                }
            }
        }
        if (extra_env) |vars| {
            const env_vars = vars[0..@min(vars.len, MAX_EXTRA_ENV)];
            for (env_vars, 0..) |v, vi| {
                const needed = GetEnvironmentVariableW(v.name, null, 0);
                if (needed > 0) {
                    const buf = try allocator.alloc(u16, needed);
                    const copied = GetEnvironmentVariableW(v.name, buf.ptr, needed);
                    if (copied >= needed) return error.GetEnvironmentVariableFailed;
                    buf[copied] = 0;
                    saved_vals[vi] = buf;
                }
            }
            for (env_vars) |v| {
                _ = SetEnvironmentVariableW(v.name, v.value);
            }
        }

        const restore_env = struct {
            fn restore(alloc: std.mem.Allocator, vars: ?[]const EnvVar, s_vals: *[MAX_EXTRA_ENV]?[]u16) void {
                if (vars) |vs| for (vs[0..@min(vs.len, MAX_EXTRA_ENV)], 0..) |v, vi| {
                    if (s_vals[vi]) |buf| {
                        _ = SetEnvironmentVariableW(v.name, @ptrCast(buf.ptr));
                        alloc.free(buf);
                        s_vals[vi] = null;
                    } else {
                        _ = SetEnvironmentVariableW(v.name, null);
                    }
                };
            }
        }.restore;

        // CreateProcessW 는 lpCommandLine 을 제자리에서 고칠 수 있다 ([MS 문서]
        // (https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw)
        // — *"can modify the contents of this string"*). 재시도가 있을 수 있으니
        // 원본 사본을 미리 떠 둔다.
        const retry_buf: ?[]WCHAR = if (inherited_dir != null and home_dir != null)
            try allocator.dupe(WCHAR, cmd_buf[0 .. cmd_len + 1])
        else
            null;
        defer if (retry_buf) |b| allocator.free(b);

        const spawn = struct {
            fn f(
                cmd: [*:0]WCHAR,
                dir: ?[*:0]const WCHAR,
                si: *STARTUPINFOEXW,
                pi: *PROCESS_INFORMATION,
            ) bool {
                return CreateProcessW(
                    null,
                    cmd,
                    null,
                    null,
                    0,
                    EXTENDED_STARTUPINFO_PRESENT,
                    null,
                    dir,
                    si,
                    pi,
                ) != 0;
            }
        }.f;

        var spawned = spawn(
            @ptrCast(cmd_buf[0..cmd_len :0].ptr),
            start_dir,
            &startup_info,
            &process_info,
        );
        if (!spawned) {
            // 물려받은 경로가 spawn 직전에 사라졌을 수 있다 (#366). lpCurrentDirectory
            // 가 없는 디렉토리면 CreateProcessW 자체가 실패하므로, 그대로 두면 새 탭이
            // 아예 열리지 않는다. 홈으로 한 번 되돌려 다시 시도한다.
            if (retry_buf) |b| {
                spawned = spawn(
                    @ptrCast(b[0..cmd_len :0].ptr),
                    home_dir,
                    &startup_info,
                    &process_info,
                );
            }
        }

        restore_env(allocator, extra_env, &saved_vals);
        if (!spawned) return error.CreateProcessFailed;

        // ── DA1 pre-response (번들 OpenConsole 3초 지연 회피)
        //
        // microsoft/terminal `src/host/VtIo.cpp` 의 `StartIfNeeded()` 는 기동 시
        //   writer.WriteUTF8("\x1b[c" ...);  // DA1 query
        //   _deviceAttributes = _pVtInputThread->WaitUntilDA1(3000);
        // 로 최대 3초 동안 터미널의 DA1 응답을 기다린다. 우리가 응답을 주지
        // 않으면 정확히 3초 후 타임아웃으로 풀리기 때문에 번들 OpenConsole 경로
        // 에서 첫 프롬프트가 ~3.9초 늦게 나타난다. Windows Terminal 의
        // ConptyConnection 은 자체 VT parser 가 `\x1b[c` 를 파싱해 응답을
        // input pipe 로 돌려주기 때문에 지연이 없다.
        //
        // 시스템 conhost (kernel32) 경로는 이 핸드셰이크가 없는(또는 더 짧은
        // fallback) 구 버전이라 regression 이 Phase C (번들 OpenConsole) 에만
        // 보였다.
        //
        // 해결: 프로세스 생성 직후 DA1 응답을 input pipe 에 **미리** 써 둔다.
        // OpenConsole 의 `InputStateMachineEngine::WaitUntilDA1` 은 atomic
        // `_deviceAttributes` flag 만 확인하므로 query 전에 응답이 도착해도
        // 파서가 바이트를 소비하면서 flag 를 set → WaitUntilDA1 이 즉시 반환.
        // race-free. 최소 유효 응답: `\x1b[?61c` (VT500 conformance level).
        {
            const da1 = "\x1b[?61c";
            var da1_written: DWORD = 0;
            _ = WriteFile(pipe_in_write, da1.ptr, @intCast(da1.len), &da1_written, null);
        }

        return .{
            .hpc = hpc,
            .pipe_in_write = pipe_in_write,
            .pipe_out_read = pipe_out_read,
            .read_event = read_event,
            .process_info = process_info,
            .attr_list_buf = attr_list_buf,
            .allocator = allocator,
        };
    }

    /// Tab / 앱 종료 시 자식 셸 정리. macOS 의 `macos_pty.Pty.deinit` 과 흐름
    /// 비교 노트가 그쪽 주석에 자세히. 요약: Windows 는 `ClosePseudoConsole` 한
    /// 호출이 자식 정리까지 OS API 추상화. macOS 는 fd 직접 다루므로 시그널
    /// (`kill(-pid, SIGHUP)`) 로 자식 종료를 직접 trigger 해야 함.
    pub fn deinit(self: *ConPty) void {
        // ClosePseudoConsole 가 output pipe 를 끊어주므로 readLoop 가 빠져나옴
        conpty_close_fn.?(self.hpc);

        if (self.read_thread) |t| {
            t.join();
            self.read_thread = null;
        }
        if (self.wait_thread) |t| {
            t.join();
            self.wait_thread = null;
        }

        _ = CloseHandle(self.pipe_in_write);
        _ = CloseHandle(self.pipe_out_read);
        _ = CloseHandle(self.read_event);
        _ = CloseHandle(self.process_info.hProcess);
        _ = CloseHandle(self.process_info.hThread);

        DeleteProcThreadAttributeList(@ptrCast(self.attr_list_buf.ptr));
        self.allocator.free(self.attr_list_buf);
    }

    pub fn write(self: *ConPty, data: []const u8) !usize {
        var bytes_written: DWORD = 0;
        if (WriteFile(
            self.pipe_in_write,
            data.ptr,
            @intCast(data.len),
            &bytes_written,
            null, // 익명 파이프, 동기
        ) == 0) return error.WriteFailed;
        return @intCast(bytes_written);
    }

    pub fn resize(self: *ConPty, cols: u16, rows: u16) !void {
        const size = COORD{ .x = @intCast(cols), .y = @intCast(rows) };
        const hr = conpty_resize_fn.?(self.hpc, size);
        if (hr < 0) return error.ResizeFailed;
    }

    pub fn startReadThread(self: *ConPty, callback: ReadCallback, exit_cb: ExitCallback, userdata: ?*anyopaque) !void {
        self.read_thread = try std.Thread.spawn(.{}, readLoop, .{ self.pipe_out_read, self.read_event, callback, userdata });
        self.wait_thread = try std.Thread.spawn(.{}, processWaitLoop, .{ self.process_info.hProcess, exit_cb, userdata });
    }

    fn readLoop(pipe: HANDLE, read_event: HANDLE, callback: ReadCallback, userdata: ?*anyopaque) void {
        var buf: [READ_BUF_SIZE]u8 = undefined;
        while (true) {
            var overlapped = OVERLAPPED{ .hEvent = read_event };
            var bytes_read: DWORD = 0;
            const t0 = perf.now();
            const ok = ReadFile(pipe, &buf, buf.len, &bytes_read, @ptrCast(&overlapped));
            if (ok == 0) {
                const err = GetLastError();
                if (err != ERROR_IO_PENDING) break;
                if (GetOverlappedResult(pipe, &overlapped, &bytes_read, 1) == 0) break;
            }
            perf.addTimedBytes(&perf.readloop, t0, @intCast(bytes_read));
            if (bytes_read == 0) break;
            callback(buf[0..bytes_read], userdata);
        }
    }

    fn processWaitLoop(process_handle: HANDLE, exit_cb: ExitCallback, userdata: ?*anyopaque) void {
        _ = WaitForSingleObject(process_handle, 0xFFFFFFFF);
        exit_cb(userdata);
    }

    pub fn isProcessAlive(self: *ConPty) bool {
        const result = WaitForSingleObject(self.process_info.hProcess, 0);
        return result != 0;
    }
};

/// WSL 탭에 끼워 넣는 `--cd "<경로>"` 인자의 최대 길이 (UTF-16 unit). Linux PATH_MAX
/// (4096 바이트) 가 UTF-16 으로 늘어나도 담기게 여유를 둔다 — 넘치면 홈으로 열화한다.
const wsl_insert_max = 4200;

/// 이 명령줄이 WSL 탭인지 (#366). WSL 안 셸은 OSC 7 로 **Linux 경로**를 보고하고
/// 새 탭도 `wsl --cd <Linux 경로>` 로 받으므로, 경로 표기를 host OS 기준으로 정하면
/// 안 된다. `terminal.isWslShell` 이 comptime 으로 이 함수를 고른다.
pub fn isWslCommand(cmd: [*:0]const WCHAR) bool {
    return wslCdInsertion(std.mem.span(cmd)).is_wsl;
}

/// #265 — 명령줄이 WSL (`wsl` / `wsl.exe`) 인지 판정하고, WSL 이면 시작
/// 디렉토리를 Linux 홈으로 만들 `--cd ~` 를 끼워 넣을 위치를 계산한다.
/// Windows Terminal 의 `MangleStartingDirectoryForWSL` (microsoft/terminal
/// PR #9223) 과 같은 규칙:
///   - 첫 토큰 (선행 `"` 지원) 의 파일 이름이 정확히 `wsl` / `wsl.exe` 일 때만.
///   - 나머지 인자에 이미 `--cd` 가 있으면 끼워 넣지 않음 (사용자 값이 이김).
///   - 단독 `~` 인자 (wsl 이 홈으로 해석하는 기존 workaround) 가 있어도 충돌
///     이므로 끼워 넣지 않음. `~/script.sh` 처럼 뒤에 글자가 붙으면 무관.
fn wslCdInsertion(cmd: []const u16) struct { is_wsl: bool, insert: bool, insert_at: usize } {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    if (cmd.len == 0) return .{ .is_wsl = false, .insert = false, .insert_at = 0 };

    // 첫 토큰 경계 — `"` 로 시작하면 닫는 `"` 까지, 아니면 첫 공백까지.
    const quoted = cmd[0] == '"';
    const tok_start: usize = if (quoted) 1 else 0;
    var tok_end = tok_start;
    while (tok_end < cmd.len) : (tok_end += 1) {
        const ch = cmd[tok_end];
        if (quoted) {
            if (ch == '"') break;
        } else if (ch == ' ') break;
    }

    // 토큰의 파일 이름 = 마지막 경로 구분자 뒤.
    var base_start = tok_start;
    for (cmd[tok_start..tok_end], tok_start..) |ch, i| {
        if (ch == '\\' or ch == '/') base_start = i + 1;
    }
    const basename = cmd[base_start..tok_end];
    const is_wsl = std.mem.eql(u16, basename, L("wsl")) or
        std.mem.eql(u16, basename, L("wsl.exe"));

    // 끼워 넣는 위치 — 토큰 (닫는 `"` 포함) 바로 뒤.
    const insert_at = if (quoted and tok_end < cmd.len) tok_end + 1 else tok_end;
    if (!is_wsl) return .{ .is_wsl = false, .insert = false, .insert_at = insert_at };

    const args = cmd[@min(insert_at, cmd.len)..];
    if (std.mem.indexOf(u16, args, L("--cd")) != null)
        return .{ .is_wsl = true, .insert = false, .insert_at = insert_at };
    if (std.mem.indexOfScalar(u16, args, '~')) |ti| {
        if (ti + 1 == args.len or args[ti + 1] == ' ')
            return .{ .is_wsl = true, .insert = false, .insert_at = insert_at };
    }
    return .{ .is_wsl = true, .insert = true, .insert_at = insert_at };
}

test "wslCdInsertion: wsl 판정 + 삽입 위치" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;

    // 끼워 넣는 케이스
    {
        const r = wslCdInsertion(L("wsl.exe -d Debian"));
        try std.testing.expect(r.is_wsl and r.insert);
        try std.testing.expectEqual(@as(usize, 7), r.insert_at);
    }
    {
        const r = wslCdInsertion(L("wsl"));
        try std.testing.expect(r.is_wsl and r.insert);
        try std.testing.expectEqual(@as(usize, 3), r.insert_at);
    }
    {
        const r = wslCdInsertion(L("\"C:\\Windows\\System32\\wsl.exe\" -d Debian"));
        try std.testing.expect(r.is_wsl and r.insert);
        try std.testing.expectEqual(@as(usize, 29), r.insert_at);
    }
    // ~/script.sh 처럼 붙은 ~ 는 단독 ~ 가 아니므로 끼워 넣음
    {
        const r = wslCdInsertion(L("wsl -d Debian ~/run.sh"));
        try std.testing.expect(r.is_wsl and r.insert);
    }

    // 끼워 넣지 않는 케이스
    try std.testing.expect(!wslCdInsertion(L("cmd.exe")).is_wsl);
    try std.testing.expect(!wslCdInsertion(L("powershell.exe -NoLogo")).is_wsl);
    try std.testing.expect(!wslCdInsertion(L("mywsl.exe")).is_wsl);
    try std.testing.expect(!wslCdInsertion(L("WSL.EXE")).is_wsl); // WT 와 동일 — 정확 표기만
    {
        const r = wslCdInsertion(L("wsl.exe -d Debian --cd /tmp"));
        try std.testing.expect(r.is_wsl and !r.insert);
    }
    {
        const r = wslCdInsertion(L("wsl.exe -d Debian ~"));
        try std.testing.expect(r.is_wsl and !r.insert);
    }
}

// Simple test: verify ConPTY can be created and destroyed. 번들 _internal
// 런타임이 필수라, 테스트 바이너리 옆에 `_internal\conpty.dll` 이 없는 CI / 로컬
// 환경에서는 ConptyRuntimeUnavailable 로 skip 한다 (fallback 제거, #339).
test "conpty create and destroy" {
    const shell = std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe");
    var pty = ConPty.init(std.testing.allocator, 80, 24, shell, null, null) catch |err| switch (err) {
        error.ConptyRuntimeUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer pty.deinit();
    try std.testing.expect(pty.isProcessAlive());
}
