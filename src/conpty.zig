const std = @import("std");
const windows = std.os.windows;

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

extern "kernel32" fn CancelIo(hFile: HANDLE) callconv(.c) BOOL;

extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*anyopaque,
    bManualReset: BOOL,
    bInitialState: BOOL,
    lpName: ?[*:0]const WCHAR,
) callconv(.c) ?HANDLE;

extern "kernel32" fn GetCurrentProcessId() callconv(.c) DWORD;

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
const WAIT_TIMEOUT: DWORD = 0x102;
const ERROR_IO_PENDING: DWORD = 997;

pub const ConPty = struct {
    hpc: HPCON,
    pipe_in: HANDLE, // write to this → goes to ConPTY input (overlapped)
    pipe_out: HANDLE, // read from this → ConPTY output
    write_event: HANDLE, // event for overlapped write
    process_info: PROCESS_INFORMATION,
    attr_list_buf: []u8,
    read_thread: ?std.Thread = null,
    wait_thread: ?std.Thread = null,
    allocator: std.mem.Allocator,

    pub const ReadCallback = *const fn (data: []const u8, userdata: ?*anyopaque) void;
    pub const ExitCallback = *const fn (userdata: ?*anyopaque) void;

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16, shell: [*:0]const WCHAR) !ConPty {
        // Create pipes for ConPTY
        // Input pipe: overlapped named pipe (write side) so WriteFile won't block UI
        var pty_output_read: HANDLE = INVALID_HANDLE_VALUE;
        var pty_output_write: HANDLE = INVALID_HANDLE_VALUE;

        const S = struct {
            var counter: u32 = 0;
        };
        const pid = GetCurrentProcessId();
        const seq = @atomicRmw(u32, &S.counter, .Add, 1, .monotonic);
        var pipe_name_buf: [128]WCHAR = undefined;
        const pipe_name_str = std.fmt.bufPrint(
            @as(*[256]u8, @ptrCast(&pipe_name_buf)),
            "\\\\.\\pipe\\tildaz_{d}_{d}\x00",
            .{ pid, seq },
        ) catch return error.CreatePipeFailed;
        // Convert ASCII to WCHAR in-place (backwards to avoid overwrite)
        var pipe_name: [128]WCHAR = undefined;
        var pi: usize = pipe_name_str.len;
        while (pi > 0) {
            pi -= 1;
            pipe_name[pi] = pipe_name_str[pi];
        }
        const pipe_name_z: [*:0]const WCHAR = @ptrCast(pipe_name[0 .. pipe_name_str.len - 1 :0]);

        // Server side (read end) — synchronous, given to ConPTY
        const pty_input_read = CreateNamedPipeW(
            pipe_name_z,
            PIPE_ACCESS_INBOUND, // read-only server
            PIPE_TYPE_BYTE | PIPE_WAIT,
            1,
            4096,
            4096,
            0,
            null,
        );
        if (pty_input_read == INVALID_HANDLE_VALUE) return error.CreatePipeFailed;
        errdefer _ = CloseHandle(pty_input_read);

        // Client side (write end) — overlapped
        const pty_input_write = CreateFileW(
            pipe_name_z,
            GENERIC_WRITE,
            0,
            null,
            OPEN_EXISTING,
            FILE_FLAG_OVERLAPPED,
            null,
        );
        if (pty_input_write == INVALID_HANDLE_VALUE) return error.CreatePipeFailed;
        errdefer _ = CloseHandle(pty_input_write);

        // Event for overlapped writes
        const write_event = CreateEventW(null, 1, 0, null) orelse return error.CreateEventFailed;
        errdefer _ = CloseHandle(write_event);

        // Large output buffer to prevent WSL from blocking during startup
        if (CreatePipe(&pty_output_read, &pty_output_write, null, 256 * 1024) == 0) {
            return error.CreatePipeFailed;
        }
        errdefer {
            _ = CloseHandle(pty_output_read);
            _ = CloseHandle(pty_output_write);
        }

        // Create pseudo console
        const size = COORD{ .x = @intCast(cols), .y = @intCast(rows) };
        var hpc: HPCON = undefined;
        const hr = CreatePseudoConsole(size, pty_input_read, pty_output_write, 0, &hpc);
        if (hr < 0) {
            return error.CreatePseudoConsoleFailed;
        }
        errdefer ClosePseudoConsole(hpc);

        // Close the handles that ConPTY now owns
        _ = CloseHandle(pty_input_read);
        _ = CloseHandle(pty_output_write);

        // Prepare STARTUPINFOEX with attribute list
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

        // Create process
        var startup_info = std.mem.zeroes(STARTUPINFOEXW);
        startup_info.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
        startup_info.lpAttributeList = attr_list;

        var process_info: PROCESS_INFORMATION = undefined;

        // We need a mutable copy of the shell command line
        var cmd_buf: [256]WCHAR = undefined;
        var i: usize = 0;
        while (shell[i] != 0) : (i += 1) {
            cmd_buf[i] = shell[i];
        }
        cmd_buf[i] = 0;

        if (CreateProcessW(
            null,
            @ptrCast(&cmd_buf),
            null,
            null,
            0, // FALSE
            EXTENDED_STARTUPINFO_PRESENT,
            null,
            null,
            &startup_info,
            &process_info,
        ) == 0) {
            return error.CreateProcessFailed;
        }

        return .{
            .hpc = hpc,
            .pipe_in = pty_input_write,
            .pipe_out = pty_output_read,
            .write_event = write_event,
            .process_info = process_info,
            .attr_list_buf = attr_list_buf,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConPty) void {
        // Close pseudoconsole FIRST — this breaks the output pipe,
        // unblocking ReadFile in the read thread (Microsoft-recommended pattern)
        ClosePseudoConsole(self.hpc);

        // Join threads (read thread exits because pipe is broken)
        if (self.read_thread) |t| {
            t.join();
            self.read_thread = null;
        }
        if (self.wait_thread) |t| {
            t.join();
            self.wait_thread = null;
        }

        // Close remaining handles
        if (self.pipe_out != INVALID_HANDLE_VALUE) _ = CloseHandle(self.pipe_out);
        _ = CloseHandle(self.pipe_in);
        _ = CloseHandle(self.write_event);
        _ = CloseHandle(self.process_info.hProcess);
        _ = CloseHandle(self.process_info.hThread);

        DeleteProcThreadAttributeList(@ptrCast(self.attr_list_buf.ptr));
        self.allocator.free(self.attr_list_buf);
    }

    pub fn write(self: *ConPty, data: []const u8) !usize {
        var overlapped = OVERLAPPED{ .hEvent = self.write_event };
        var bytes_written: DWORD = 0;

        const result = WriteFile(
            self.pipe_in,
            data.ptr,
            @intCast(data.len),
            &bytes_written,
            @ptrCast(&overlapped),
        );

        if (result != 0) return @intCast(bytes_written);

        // WriteFile이 비동기 시작됨 — 100ms 타임아웃으로 대기
        if (GetLastError() != ERROR_IO_PENDING) return error.WriteFailed;

        const wait = WaitForSingleObject(self.write_event, 100);
        if (wait == WAIT_OBJECT_0) {
            _ = GetOverlappedResult(self.pipe_in, &overlapped, &bytes_written, 0);
            return @intCast(bytes_written);
        }

        // 타임아웃 — write 취소하고 다음 write로 넘어감
        _ = CancelIo(self.pipe_in);
        _ = GetOverlappedResult(self.pipe_in, &overlapped, &bytes_written, 1);
        return error.WriteTimeout;
    }

    pub fn resize(self: *ConPty, cols: u16, rows: u16) !void {
        const size = COORD{ .x = @intCast(cols), .y = @intCast(rows) };
        const hr = ResizePseudoConsole(self.hpc, size);
        if (hr < 0) {
            return error.ResizeFailed;
        }
    }

    pub fn startReadThread(self: *ConPty, callback: ReadCallback, exit_cb: ExitCallback, userdata: ?*anyopaque) !void {
        self.read_thread = try std.Thread.spawn(.{}, readLoop, .{ self.pipe_out, callback, userdata });
        // Separate thread: wait for shell process to exit, then notify
        self.wait_thread = try std.Thread.spawn(.{}, processWaitLoop, .{ self.process_info.hProcess, exit_cb, userdata });
    }

    fn readLoop(pipe_out: HANDLE, callback: ReadCallback, userdata: ?*anyopaque) void {
        var buf: [65536]u8 = undefined;
        while (true) {
            var bytes_read: DWORD = 0;
            if (ReadFile(pipe_out, &buf, buf.len, &bytes_read, null) == 0) {
                break; // pipe closed or error
            }
            if (bytes_read == 0) break;
            callback(buf[0..bytes_read], userdata);
        }
    }

    fn processWaitLoop(process_handle: HANDLE, exit_cb: ExitCallback, userdata: ?*anyopaque) void {
        _ = WaitForSingleObject(process_handle, 0xFFFFFFFF); // INFINITE
        exit_cb(userdata);
    }

    pub fn isProcessAlive(self: *ConPty) bool {
        const result = WaitForSingleObject(self.process_info.hProcess, 0);
        return result != 0; // WAIT_OBJECT_0 = 0 means process exited
    }
};

// Simple test: verify ConPTY can be created and destroyed
test "conpty create and destroy" {
    const shell = std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe");
    var pty = try ConPty.init(std.testing.allocator, 80, 24, shell);
    defer pty.deinit();
    try std.testing.expect(pty.isProcessAlive());
}
