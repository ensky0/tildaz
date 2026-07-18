//! Cross-platform 로그 — 통합 로그 파일에 timestamp + category + message 한
//! 줄 append. `perf` 스냅샷 같이 자체 헤더를 가진 다중 줄 블록은 `appendBlock`
//! 으로 prefix 없이 그대로.
//!
//! 로그 위치:
//!   - Windows: `%APPDATA%\tildaz\tildaz_N.log`
//!   - macOS:   `~/Library/Logs/tildaz_N.log`  (Apple HIG — Console.app 자동 인덱싱)
//!   - Linux:   `~/.local/state/tildaz/tildaz_N.log`  (XDG state)
//!
//! 포맷:
//!   `[YYYY-MM-DD HH:MM:SS.mmm] [category] <message>\n`
//!   모든 platform 에서 local time 을 사용한다.
//!
//! Platform 모듈 (`log/{windows,macos,linux}.zig`) 은 시스템 의존 부분
//! (local time 변환 / pid) 만 제공. 로그 파일 경로는 처음 사용할 때 실제
//! 길이만큼 한 번 준비해 프로세스 수명 동안 보관하며, 기록 / About /
//! Open Log가 이 값을 함께 쓴다. formatting / file IO 는 이 파일에서 단일 구현.

const std = @import("std");
const builtin = @import("builtin");
const log_time = @import("log_time.zig");
const messages = @import("messages.zig");
const paths = @import("paths.zig");

// #282 D1 — Windows 원자적 append 용 Win32 externs. Windows 에서만 참조되는
// comptime 분기(writeRaw)에서만 쓰이므로 다른 platform 빌드엔 영향 없음.
const win32 = if (builtin.os.tag == .windows) struct {
    const w = std.os.windows;
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
    },
};

const CachedPath = if (builtin.os.tag == .windows)
    struct {
        utf8: []const u8,
        native: *const std.os.windows.PathSpace,
    }
else
    struct {
        utf8: []const u8,
    };

var g_path_mutex: std.Thread.Mutex = .{};
var g_path_attempted = false;
var g_cached_path: ?CachedPath = null;

/// worker index 가 정해진 뒤 처음 호출될 때 경로를 동적으로 준비한다. 보관
/// 메모리는 process lifetime 이며, 이후 로그 기록 / About / Open Log가 같은
/// slice를 사용한다. 준비 실패는 로그 자체에 쓸 수 없으므로 stderr에 한 번
/// 명시하고 이후 null을 반환한다.
fn cachedPath() ?CachedPath {
    g_path_mutex.lock();
    defer g_path_mutex.unlock();

    if (g_cached_path) |path| return path;
    if (g_path_attempted) return null;
    g_path_attempted = true;

    g_cached_path = prepareCachedPath() catch |err| {
        std.debug.print(messages.log_path_prepare_failed_format ++ "\n", .{@errorName(err)});
        return null;
    };
    return g_cached_path;
}

fn prepareCachedPath() !CachedPath {
    const allocator = std.heap.page_allocator;
    const utf8 = try paths.logPath(allocator);
    errdefer allocator.free(utf8);

    if (comptime builtin.os.tag == .windows) {
        const native = try allocator.create(std.os.windows.PathSpace);
        errdefer allocator.destroy(native);
        native.* = try std.os.windows.sliceToPrefixedFileW(null, utf8);
        return .{ .utf8 = utf8, .native = native };
    }
    return .{ .utf8 = utf8 };
}

/// 실제 기록 파일 경로. process lifetime borrowed slice이며 호출자가 해제하지
/// 않는다. 기록 경로 준비가 실패한 경우에만 null.
pub fn filePath() ?[]const u8 {
    const path = cachedPath() orelse return null;
    return path.utf8;
}

fn writeRaw(text: []const u8) void {
    const path = cachedPath() orelse return;
    if (builtin.os.tag == .windows) {
        // #282 D1 — POSIX 는 O_APPEND(아래)로 고쳤으나 Windows 는 createFile+seekFromEnd+
        // writeAll race 였다 (seek 와 write 사이 동시 writer 시 torn line). FILE_APPEND_DATA
        // 로 열면 OS 가 매 write 를 원자적으로 EOF 에 append — ConPty wait_thread(onPtyExit)
        // vs main thread 동시 write(shell exit 시점, post-mortem 로그 필요 순간)에도 줄이 안
        // 섞인다. 한 줄 단일 WriteFile — 작은 크기라 partial 없이 한 번에.
        // `sliceToPrefixedFileW`가 만든 NT namespace 경로를 보관해 Win32
        // MAX_PATH / 이전 520 UTF-16 배열에 의존하지 않는다. OpenFile은 이
        // prefixed 경로를 그대로 NtCreateFile에 전달한다.
        const w = std.os.windows;
        const handle = w.OpenFile(path.native.span(), .{
            .access_mask = w.FILE_APPEND_DATA | w.SYNCHRONIZE,
            .creation = w.FILE_OPEN_IF,
        }) catch return;
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
        const fd = posix.open(path.utf8, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644) catch return;
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

test "filePath returns one process-lifetime path" {
    const first = filePath() orelse return error.SkipZigTest;
    const second = filePath() orelse return error.SkipZigTest;

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(second.ptr));
}
