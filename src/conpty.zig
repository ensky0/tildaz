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

pub const ConPty = struct {
    hpc: HPCON,
    pipe_in: HANDLE, // write to this → goes to ConPTY input
    pipe_out: HANDLE, // read from this → ConPTY output
    process_info: PROCESS_INFORMATION,
    attr_list_buf: []u8,
    read_thread: ?std.Thread = null,
    allocator: std.mem.Allocator,

    pub const ReadCallback = *const fn (data: []const u8, userdata: ?*anyopaque) void;

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16, shell: [*:0]const WCHAR) !ConPty {
        // Create pipes for ConPTY
        var pty_input_read: HANDLE = INVALID_HANDLE_VALUE;
        var pty_input_write: HANDLE = INVALID_HANDLE_VALUE;
        var pty_output_read: HANDLE = INVALID_HANDLE_VALUE;
        var pty_output_write: HANDLE = INVALID_HANDLE_VALUE;

        if (CreatePipe(&pty_input_read, &pty_input_write, null, 0) == 0) {
            return error.CreatePipeFailed;
        }
        errdefer {
            _ = CloseHandle(pty_input_read);
            _ = CloseHandle(pty_input_write);
        }

        if (CreatePipe(&pty_output_read, &pty_output_write, null, 0) == 0) {
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
            .process_info = process_info,
            .attr_list_buf = attr_list_buf,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConPty) void {
        if (self.read_thread) |t| {
            // Close pipe_out first to unblock the read thread
            _ = CloseHandle(self.pipe_out);
            self.pipe_out = INVALID_HANDLE_VALUE;
            t.join();
            self.read_thread = null;
        }

        if (self.pipe_out != INVALID_HANDLE_VALUE) {
            _ = CloseHandle(self.pipe_out);
        }

        ClosePseudoConsole(self.hpc);
        _ = CloseHandle(self.pipe_in);
        _ = CloseHandle(self.process_info.hProcess);
        _ = CloseHandle(self.process_info.hThread);

        DeleteProcThreadAttributeList(@ptrCast(self.attr_list_buf.ptr));
        self.allocator.free(self.attr_list_buf);
    }

    pub fn write(self: *ConPty, data: []const u8) !usize {
        var bytes_written: DWORD = 0;
        if (WriteFile(
            self.pipe_in,
            data.ptr,
            @intCast(data.len),
            &bytes_written,
            null,
        ) == 0) {
            return error.WriteFailed;
        }
        return @intCast(bytes_written);
    }

    pub fn resize(self: *ConPty, cols: u16, rows: u16) !void {
        const size = COORD{ .x = @intCast(cols), .y = @intCast(rows) };
        const hr = ResizePseudoConsole(self.hpc, size);
        if (hr < 0) {
            return error.ResizeFailed;
        }
    }

    pub fn startReadThread(self: *ConPty, callback: ReadCallback, userdata: ?*anyopaque) !void {
        self.read_thread = try std.Thread.spawn(.{}, readLoop, .{ self.pipe_out, callback, userdata });
    }

    fn readLoop(pipe_out: HANDLE, callback: ReadCallback, userdata: ?*anyopaque) void {
        var buf: [4096]u8 = undefined;
        while (true) {
            var bytes_read: DWORD = 0;
            if (ReadFile(pipe_out, &buf, buf.len, &bytes_read, null) == 0) {
                break; // pipe closed or error
            }
            if (bytes_read == 0) break;
            callback(buf[0..bytes_read], userdata);
        }
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
