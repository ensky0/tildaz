const std = @import("std");
const windows = std.os.windows;
const perf = @import("perf.zig");

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
const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;

extern "kernel32" fn CreatePipe(
    hReadPipe: *HANDLE,
    hWritePipe: *HANDLE,
    lpPipeAttributes: ?*const SECURITY_ATTRIBUTES,
    nSize: DWORD,
) callconv(.c) BOOL;

extern "kernel32" fn CreatePseudoConsole(
    size: COORD,
    hInput: HANDLE,
    hOutput: HANDLE,
    dwFlags: DWORD,
    phPC: *HPCON,
) callconv(.c) HRESULT;

extern "kernel32" fn ResizePseudoConsole(
    hPC: HPCON,
    size: COORD,
) callconv(.c) HRESULT;

extern "kernel32" fn ClosePseudoConsole(
    hPC: HPCON,
) callconv(.c) void;

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

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16, shell: [*:0]const WCHAR, extra_env: ?[]const EnvVar) !ConPty {
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
        var pipe_name: [128]WCHAR = undefined;
        for (pipe_name_str, 0..) |c, i| pipe_name[i] = c;
        pipe_name[pipe_name_str.len] = 0;
        const pipe_name_z: [*:0]const WCHAR = @ptrCast(pipe_name[0..pipe_name_str.len :0]);

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

        // ── Pseudo console
        const size = COORD{ .x = @intCast(cols), .y = @intCast(rows) };
        var hpc: HPCON = undefined;
        // 0x8 = PSEUDOCONSOLE_GLYPH_WIDTH_GRAPHEMES (Win11). 미지원 시 0.
        var hr = CreatePseudoConsole(size, pipe_in_read, pipe_out_write, 0x8, &hpc);
        var flags_used: u32 = 0x8;
        if (hr < 0) {
            flags_used = 0;
            hr = CreatePseudoConsole(size, pipe_in_read, pipe_out_write, 0, &hpc);
        }
        perf.log("[conpty] CreatePseudoConsole flags=0x{x} hr=0x{x} cols={d} rows={d}\n", .{ flags_used, @as(u32, @bitCast(hr)), cols, rows });

        // CreatePseudoConsole 는 handle 을 내부 duplicate — 우리 쪽 사본은 닫아야 한다.
        _ = CloseHandle(pipe_in_read);
        _ = CloseHandle(pipe_out_write);

        if (hr < 0) return error.CreatePseudoConsoleFailed;
        errdefer ClosePseudoConsole(hpc);

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

        var process_info: PROCESS_INFORMATION = undefined;

        var cmd_buf: [256]WCHAR = undefined;
        var i: usize = 0;
        while (shell[i] != 0 and i < cmd_buf.len - 1) : (i += 1) {
            cmd_buf[i] = shell[i];
        }
        cmd_buf[i] = 0;

        // 자식 프로세스에 추가 환경변수 전달 (기존값 저장 → SetEnv → CreateProcess → 복원)
        const MAX_EXTRA_ENV = 4;
        var saved_vals: [MAX_EXTRA_ENV][256]u16 = undefined;
        var saved_lens: [MAX_EXTRA_ENV]u32 = .{0} ** MAX_EXTRA_ENV;
        if (extra_env) |vars| {
            for (vars, 0..) |v, vi| {
                saved_lens[vi] = GetEnvironmentVariableW(v.name, &saved_vals[vi], saved_vals[vi].len);
                _ = SetEnvironmentVariableW(v.name, v.value);
            }
        }

        const restore_env = struct {
            fn restore(vars: ?[]const EnvVar, s_vals: *[MAX_EXTRA_ENV][256]u16, s_lens: *[MAX_EXTRA_ENV]u32) void {
                if (vars) |vs| for (vs, 0..) |v, vi| {
                    if (s_lens[vi] > 0 and s_lens[vi] < s_vals[vi].len) {
                        s_vals[vi][s_lens[vi]] = 0;
                        _ = SetEnvironmentVariableW(v.name, @ptrCast(s_vals[vi][0..s_lens[vi] :0]));
                    } else {
                        _ = SetEnvironmentVariableW(v.name, null);
                    }
                };
            }
        }.restore;

        if (CreateProcessW(
            null,
            @ptrCast(&cmd_buf),
            null,
            null,
            0,
            EXTENDED_STARTUPINFO_PRESENT,
            null,
            null,
            &startup_info,
            &process_info,
        ) == 0) {
            restore_env(extra_env, &saved_vals, &saved_lens);
            return error.CreateProcessFailed;
        }

        restore_env(extra_env, &saved_vals, &saved_lens);

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

    pub fn deinit(self: *ConPty) void {
        // ClosePseudoConsole 가 output pipe 를 끊어주므로 readLoop 가 빠져나옴
        ClosePseudoConsole(self.hpc);

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
        const hr = ResizePseudoConsole(self.hpc, size);
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

// Simple test: verify ConPTY can be created and destroyed
test "conpty create and destroy" {
    const shell = std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe");
    var pty = try ConPty.init(std.testing.allocator, 80, 24, shell, null);
    defer pty.deinit();
    try std.testing.expect(pty.isProcessAlive());
}
