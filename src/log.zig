//! Cross-platform 로그 — 통합 로그 파일에 timestamp + category + message 한
//! 줄 append. `perf` 스냅샷 같이 자체 헤더를 가진 다중 줄 블록은 `appendBlock`
//! 으로 prefix 없이 그대로.
//!
//! 로그 위치:
//!   - Windows: `%APPDATA%\tildaz\tildazN.log`
//!   - macOS:   `~/Library/Logs/tildazN.log`  (Apple HIG — Console.app 자동 인덱싱)
//!   - Linux:   `~/.local/state/tildaz/tildazN.log`  (XDG state)
//!
//! 포맷:
//!   `[YYYY-MM-DD HH:MM:SS.mmm] [category] <message>\n`
//!   모든 platform 에서 local time 을 사용한다.
//!
//! Platform 모듈 (`log/windows.zig` / `log/macos.zig`) 은 시스템 의존 부분
//! (local time 변환 / pid / 로그 파일 path) 만 제공 — 그 외 formatting /
//! file IO 는 이 파일에서 단일 구현.

const std = @import("std");
const builtin = @import("builtin");
const log_time = @import("log_time.zig");

// #282 D1 — Windows 원자적 append 용 Win32 externs. Windows 에서만 참조되는
// comptime 분기(writeRaw)에서만 쓰이므로 다른 platform 빌드엔 영향 없음.
const win32 = if (builtin.os.tag == .windows) struct {
    const w = std.os.windows;
    pub extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: w.DWORD,
        dwShareMode: w.DWORD,
        lpSecurityAttributes: ?*const anyopaque,
        dwCreationDisposition: w.DWORD,
        dwFlagsAndAttributes: w.DWORD,
        hTemplateFile: ?w.HANDLE,
    ) callconv(.c) w.HANDLE;
    pub extern "kernel32" fn WriteFile(
        hFile: w.HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: w.DWORD,
        lpNumberOfBytesWritten: ?*w.DWORD,
        lpOverlapped: ?*anyopaque,
    ) callconv(.c) w.BOOL;
    pub extern "kernel32" fn CloseHandle(hObject: w.HANDLE) callconv(.c) w.BOOL;
} else struct {};

pub const TimeFields = log_time.TimeFields;

const impl = switch (builtin.os.tag) {
    .windows => @import("log/windows.zig"),
    .macos => @import("log/macos.zig"),
    .linux => @import("log/linux.zig"),
    else => struct {
        pub const TimeFields = log_time.TimeFields;
        pub fn currentLocalTime() log_time.TimeFields {
            return log_time.fallback();
        }
        pub fn currentPid() u64 {
            return 0;
        }
        pub fn resolvePath(_: []u8) ?[]const u8 {
            return null;
        }
    },
};

fn writeRaw(text: []const u8) void {
    var path_buf: [520]u8 = undefined;
    const path = impl.resolvePath(&path_buf) orelse return;
    if (builtin.os.tag == .windows) {
        // #282 D1 — POSIX 는 O_APPEND(아래)로 고쳤으나 Windows 는 createFile+seekFromEnd+
        // writeAll race 였다 (seek 와 write 사이 동시 writer 시 torn line). FILE_APPEND_DATA
        // 로 열면 OS 가 매 write 를 원자적으로 EOF 에 append — ConPty wait_thread(onPtyExit)
        // vs main thread 동시 write(shell exit 시점, post-mortem 로그 필요 순간)에도 줄이 안
        // 섞인다. 한 줄 단일 WriteFile — 작은 크기라 partial 없이 한 번에.
        const w = std.os.windows;
        var path_w: [520]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(path_w[0 .. path_w.len - 1], path) catch return;
        path_w[n] = 0;
        const FILE_APPEND_DATA: w.DWORD = 0x0004;
        const FILE_SHARE_RW: w.DWORD = 0x00000001 | 0x00000002; // READ | WRITE
        const OPEN_ALWAYS: w.DWORD = 4;
        const FILE_ATTRIBUTE_NORMAL: w.DWORD = 0x80;
        const handle = win32.CreateFileW(path_w[0..n :0].ptr, FILE_APPEND_DATA, FILE_SHARE_RW, null, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
        if (handle == w.INVALID_HANDLE_VALUE) return;
        defer _ = win32.CloseHandle(handle);
        var written: w.DWORD = undefined;
        _ = win32.WriteFile(handle, text.ptr, @intCast(text.len), &written, null);
    } else {
        // O_APPEND — 커널이 매 write 를 파일 끝에 원자적으로 append (한 줄 < PIPE_BUF).
        // 여러 프로세스(메인 인스턴스 + `tildaz --toggle` 자식, #230)가 동시에 써도
        // 줄이 안 섞인다. 이전 createFile+seekFromEnd+writeAll 은 seek 와 write 사이
        // race 라 동시 writer 시 torn line 이 났다. 한 줄 단일 write — 작은 크기라
        // partial write 없이 한 번에 atomic append.
        const posix = std.posix;
        const fd = posix.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644) catch return;
        defer posix.close(fd);
        _ = posix.write(fd, text) catch {};
    }
}

/// `[YYYY-MM-DD HH:MM:SS.mmm] [category] <fmt args>\n` 한 줄 append.
pub fn appendLine(category: []const u8, comptime fmt: []const u8, args: anytype) void {
    const t = impl.currentLocalTime();

    var buf: [2048]u8 = undefined;
    const prefix = std.fmt.bufPrint(
        &buf,
        "[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}] [{s}] ",
        .{ t.year, t.month, t.day, t.hour, t.min, t.sec, t.ms, category },
    ) catch return;

    const body = std.fmt.bufPrint(buf[prefix.len..], fmt, args) catch return;

    const total = prefix.len + body.len;
    if (total + 1 > buf.len) return;
    buf[total] = '\n';
    writeRaw(buf[0 .. total + 1]);
}

/// #197 — verbose 토글. boot 시 한 번 set (main thread), 이후 read-only 라
/// thread race 없음. true 일 때만 `appendLineVerbose` 가 출력.
var g_verbose: bool = false;

pub fn setVerbose(v: bool) void {
    g_verbose = v;
}

/// #197 — protocol-level / timing / detail 전용 로그. `setVerbose(true)` (env
/// `TILDAZ_VERBOSE`) 일 때만 출력. 기본(production)은 lifecycle + summary 만 남겨
/// platform 간 분량 일관. 호출 형태는 `appendLine` 과 동일.
pub fn appendLineVerbose(category: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!g_verbose) return;
    appendLine(category, fmt, args);
}

/// 여러 줄 블록을 timestamp / category prefix 없이 그대로 append. perf
/// 스냅샷처럼 자체 헤더 / 포맷을 가진 텍스트용.
pub fn appendBlock(text: []const u8) void {
    writeRaw(text);
}

/// 부팅 시 `[boot] tildaz v<ver> pid=<pid> exe=<full path>` 한 줄.
pub fn logStart(version: []const u8) void {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = std.fs.selfExePath(&exe_buf) catch "(unknown)";
    appendLine("boot", "tildaz v{s}  pid={d}  exe={s}", .{ version, impl.currentPid(), exe });
}

/// 정상 종료 시 `[exit] tildaz v<ver> pid=<pid>` 한 줄.
pub fn logStop(version: []const u8) void {
    appendLine("exit", "tildaz v{s}  pid={d}", .{ version, impl.currentPid() });
}

/// #197 — cross-platform `[startup] config loaded` 한 줄. 모든 host 가 동일
/// 필드 / 순서로 출력 — 이전엔 Linux / Win / mac 각각 다른 형식으로 verbose
/// 일관성이 깨졌었음 (Linux 가 fullest, Win 이 sparse).
///
/// `cfg` 는 `config.Config` (anytype 으로 받아 import 순환 회피).
pub fn logConfigLoaded(cfg: anytype) void {
    appendLine("startup", "config loaded: theme={s} shell={s} font_size={d} max_scroll={d} auto_start={} hidden_start={}", .{
        if (cfg.theme) |t| t.name else "default",
        cfg.shell,
        cfg.font_size_point,
        cfg.max_scroll_lines,
        cfg.auto_start,
        cfg.hidden_start,
    });
}

/// #197 — fatal / 시작 실패처럼 *사용자에게 직접 보여주는* 메시지를 한 번만
/// 받아 두 채널에 동일하게 보낸다:
///   1. stderr — 터미널에서 직접 실행한 사용자가 즉시 본다.
///   2. 로그 파일 — post-mortem 기록.
/// 호출처가 같은 문자열을 쓰므로 "로그엔 진단 한 줄, 화면엔 다른 문구" 식의
/// 내용 분기가 생기지 않는다 (이전엔 socket 실패 등이 같은 데이터를 두 번
/// 따로 포맷해 갈렸음). 메시지는 이미 렌더된 최종 텍스트 (multi-line 허용).
pub fn userFacing(category: []const u8, text: []const u8) void {
    std.debug.print("{s}\n", .{text});
    appendLine(category, "{s}", .{text});
}
