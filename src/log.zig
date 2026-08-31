//! Cross-platform 로그 — 통합 로그 파일에 timestamp + category + message 한
//! 줄 append. `perf` 스냅샷 같이 자체 헤더를 가진 다중 줄 블록은 `appendBlock`
//! 으로 prefix 없이 그대로.
//!
//! 로그 위치:
//!   - Windows: `%APPDATA%\tildaz\tildaz_N.log`
//!   - macOS:   `~/Library/Logs/tildaz_N.log`  (Apple HIG — Console.app 자동 인덱싱)
//!   - Linux:   `$XDG_STATE_HOME/tildaz/tildaz_N.log` (fallback `~/.local/state`)
//!
//! 포맷:
//!   `[YYYY-MM-DD HH:MM:SS.mmm] [category] <message>\n`
//!   모든 platform 에서 local time 을 사용한다.
//!
//! Platform 모듈 (`log/{windows,macos,linux}.zig`) 은 시스템 의존 부분
//! (local time 변환 / pid) 만 제공. 로그 파일 경로는 **진입점이 `init` 으로 한 번
//! 넘겨** 프로세스 수명 동안 보관하며, 기록 / About / Open Log가 이 값을 함께 쓴다
//! (#451 — 예전의 lazy 준비를 대체. 아래 `init` 주석). formatting / file IO 는 이
//! 파일에서 단일 구현.

const std = @import("std");
const builtin = @import("builtin");
const log_time = @import("log_time.zig");
const messages = @import("messages.zig");

// #282 D1 — Windows 원자적 append 용 Win32 externs. Windows 에서만 참조되는
// comptime 분기(writeRaw)에서만 쓰이므로 다른 platform 빌드엔 영향 없음.
//
// #451 — Zig 0.16 은 `std.os.windows` 의 중간 추상화를 걷어냈다. `OpenFile` 과
// `PathSpace` 가 없어졌고 `kernel32` 에 남은 extern 은 `CreateProcessW` 하나뿐이다
// (릴리즈 노트 *Completed Migration to NtDll*). 그래서 파일 열기도 여기서 직접
// 선언한다 — 이 파일이 이미 `WriteFile` · `CloseHandle` 을 그렇게 쓰고 있었고,
// 레포 전체가 같은 방식으로 kernel32 를 53 자리 선언한다.
const win32 = if (builtin.os.tag == .windows) struct {
    const w = std.os.windows;

    /// 매 write 를 OS 가 원자적으로 EOF 에 붙인다 — 이 파일의 존재 이유 (#282 D1).
    pub const FILE_APPEND_DATA: w.DWORD = 0x0004;
    /// 다른 인스턴스 (`tildaz --toggle` 자식 등) 가 같은 파일을 동시에 열 수 있어야 한다.
    pub const FILE_SHARE_ALL: w.DWORD = 0x00000001 | 0x00000002 | 0x00000004;
    /// 없으면 만들고 있으면 연다 (`O_CREAT` 상당, truncate 하지 않는다).
    pub const OPEN_ALWAYS: w.DWORD = 4;
    pub const FILE_ATTRIBUTE_NORMAL: w.DWORD = 0x80;

    pub extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: w.DWORD,
        dwShareMode: w.DWORD,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: w.DWORD,
        dwFlagsAndAttributes: w.DWORD,
        hTemplateFile: ?w.HANDLE,
    ) callconv(.winapi) w.HANDLE;
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

/// UTF-8 경로. `init` 전에는 null 이고 그동안의 기록은 조용히 버려진다 — 예전 lazy
/// 준비도 실패하면 같은 결과였다.
var g_path: ?[]const u8 = null;
/// Windows 전용 — `CreateFileW` 에 넘길 WTF-16 경로. `init` 에서 한 번 만든다.
var g_path_w: if (builtin.os.tag == .windows) ?[:0]const u16 else void =
    if (builtin.os.tag == .windows) null else {};

/// 로그 파일 경로를 프로세스에 한 번 심는다 ([#451](https://github.com/ensky0/tildaz/issues/451)).
///
/// **왜 진입점이 넘기나.** 예전에는 첫 기록에서 lazy 로 `paths.logPath` 를 불렀다.
/// Zig 0.16 은 경로 계산이 `Io` 와 환경변수를 받아야 하는데 (`paths.zig`), 그러면
/// `appendLine` 계열 **297 자리**가 전부 그 둘을 들고 다녀야 한다. 경로는 프로세스
/// 수명 동안 **하나뿐**이라 진입점이 한 번 넘기면 그만이고, 그러면 기록 호출부는
/// 시그니처가 하나도 안 바뀐다.
///
/// **경합이 없다.** 진입점이 worker index 를 정한 **직후**, 스레드를 만들기 전에
/// 부른다. 예전 lazy 준비를 지키던 mutex 가 그래서 사라졌다 — 늦게 붙는 잠금이
/// 아니라 아예 순서로 막는다.
///
/// `path` 는 프로세스 수명 동안 살아 있어야 한다 (호출자 소유, 여기서 해제하지 않는다).
/// 준비 실패는 로그 자체에 쓸 수 없으므로 stderr 에 한 번 명시한다.
pub fn init(allocator: std.mem.Allocator, path: []const u8) void {
    g_path = path;
    if (comptime builtin.os.tag == .windows) {
        // `\\?\` 접두사 — Win32 `MAX_PATH` (260) 를 넘는 경로도 열린다. 예전
        // `sliceToPrefixedFileW` 가 해 주던 일이고 (Zig 0.16 에서 `std.os.windows`
        // 밖으로 나갔다), 우리 경로는 항상 drive 절대경로라 접두사 조건을 만족한다.
        const prefixed = std.fmt.allocPrint(allocator, "\\\\?\\{s}", .{path}) catch |err| {
            std.debug.print(messages.log_path_prepare_failed_format ++ "\n", .{@errorName(err)});
            return;
        };
        defer allocator.free(prefixed);
        g_path_w = std.unicode.wtf8ToWtf16LeAllocZ(allocator, prefixed) catch |err| {
            std.debug.print(messages.log_path_prepare_failed_format ++ "\n", .{@errorName(err)});
            return;
        };
    }
}

/// 실제 기록 파일 경로. process lifetime borrowed slice이며 호출자가 해제하지
/// 않는다. `init` 전이거나 준비가 실패한 경우에만 null.
pub fn filePath() ?[]const u8 {
    return g_path;
}

fn writeRaw(text: []const u8) void {
    if (builtin.os.tag == .windows) {
        // #282 D1 — POSIX 는 O_APPEND(아래)로 고쳤으나 Windows 는 createFile+seekFromEnd+
        // writeAll race 였다 (seek 와 write 사이 동시 writer 시 torn line). FILE_APPEND_DATA
        // 로 열면 OS 가 매 write 를 원자적으로 EOF 에 append — ConPty wait_thread(onPtyExit)
        // vs main thread 동시 write(shell exit 시점, post-mortem 로그 필요 순간)에도 줄이 안
        // 섞인다. 한 줄 단일 WriteFile — 작은 크기라 partial 없이 한 번에.
        //
        // #451 — 예전엔 `std.os.windows.OpenFile` 에 `sliceToPrefixedFileW` 결과를 넘겼다.
        // Zig 0.16 에서 둘 다 `std.os.windows` 밖으로 나가서, `init` 이 만들어 둔 `\\?\`
        // WTF-16 경로를 우리가 선언한 `CreateFileW` 에 그대로 넘긴다. 원자성의 근거는
        // 그대로 FILE_APPEND_DATA 이고 MAX_PATH 비의존도 접두사로 유지된다.
        const path_w = g_path_w orelse return;
        const handle = win32.CreateFileW(
            path_w.ptr,
            win32.FILE_APPEND_DATA,
            win32.FILE_SHARE_ALL,
            null,
            win32.OPEN_ALWAYS,
            win32.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (handle == std.os.windows.INVALID_HANDLE_VALUE) return;
        defer _ = win32.CloseHandle(handle);
        var written: std.os.windows.DWORD = undefined;
        _ = win32.WriteFile(handle, text.ptr, @intCast(text.len), &written, null);
    } else {
        // O_APPEND — 커널이 매 write 를 파일 끝에 원자적으로 append (한 줄 < PIPE_BUF).
        // 여러 프로세스(메인 인스턴스 + `tildaz --toggle` 자식, #230)가 동시에 써도
        // 줄이 안 섞인다. 이전 createFile+seekFromEnd+writeAll 은 seek 와 write 사이
        // race 라 동시 writer 시 torn line 이 났다. 한 줄 단일 write — 작은 크기라
        // partial write 없이 한 번에 atomic append.
        //
        // #451 — 이 경로는 `Io` 로 올릴 수 없다. `Io.Dir` 의 파일 열기 옵션에 **append
        // 모드가 없어서** (`OpenFileOptions` · `CreateFileOptions` 전수 확인) O_APPEND
        // 원자성을 표현할 방법이 없다. 릴리즈 노트가 남긴 다른 길인 *"go lower: use
        // `std.posix.system` directly"* 를 택한다.
        const path = g_path orelse return;
        const posix = std.posix;
        const fd = posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644) catch return;
        defer _ = posix.system.close(fd);
        _ = posix.system.write(fd, text.ptr, text.len);
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
///
/// #451 — 실행파일 경로 조회가 `Io` 를 받는다 (`fs.selfExePath` ➡️
/// `std.process.executablePath`, 릴리즈 노트 upgrade guide). 기록 자체는 `Io` 를 안
/// 타므로 (`writeRaw` 는 raw syscall) `io` 가 필요한 것은 이 함수뿐이고, host 진입점
/// 세 곳에서만 부른다.
pub fn logStart(io: std.Io, version: []const u8) void {
    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe = if (std.process.executablePath(io, &exe_buf)) |n|
        exe_buf[0..n]
    else |_|
        "(unknown)";
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

/// 세 host가 같은 의미와 형식을 써야 하는 진단 로그. platform 코드는 측정값과
/// 동작 결과만 넘기고 category / format string은 여기 한 곳에서 정한다 (#576).
pub fn logPanic(msg: []const u8, return_addr: usize) void {
    appendLine("panic", "{s}  return_addr=0x{x}", .{ msg, return_addr });
}

pub fn logRunFailed(err: anyerror) void {
    appendLine("fatal", "run failed: {s}", .{@errorName(err)});
}

pub fn logScrollbackOverride(lines: anytype, config_lines: anytype) void {
    appendLine("startup", "scrollback override: {d} lines (config {d})", .{ lines, config_lines });
}

pub fn logOutputWakeInstalled() void {
    appendLine("startup", "output wake installed (idle PTY notify)", .{});
}

pub fn logDisplayTiming(refresh_hz: f64) void {
    if (!std.math.isFinite(refresh_hz) or refresh_hz <= 0.0) return;
    appendLine("startup", "display timing: refresh={d:.3}Hz period={d:.3}ms", .{
        refresh_hz,
        1000.0 / refresh_hz,
    });
}

pub fn logPrimaryFont(family: []const u8, cell_w: anytype, cell_h: anytype, ascent: anytype, descent: anytype) void {
    appendLine("font", "primary family={s} cell_w={d} cell_h={d} ascent={d} descent={d}", .{
        family, cell_w, cell_h, ascent, descent,
    });
}

pub fn logPaneFocusByClick(id: anytype) void {
    appendLine("pane", "focus by click — active pane {}", .{id});
}

pub fn logPaneSplitTooSmall(direction: []const u8, min_cols: anytype, min_rows: anytype) void {
    appendLine("pane", "split {s} rejected: pane would be under {d}x{d}", .{ direction, min_cols, min_rows });
}

pub fn logPaneSplitTooMany(direction: []const u8, max_panes: anytype) void {
    appendLine("pane", "split {s} rejected: tab already has {d} panes", .{ direction, max_panes });
}

pub fn logPaneSplitFailed(err: anyerror) void {
    appendLine("pane", "split failed: {s}", .{@errorName(err)});
}

pub fn logPaneSplit(direction: []const u8, tab_index: anytype, pane_count: anytype, active_pane: anytype) void {
    appendLine("pane", "split {s} — tab {} has {} panes, active pane {}", .{
        direction, tab_index, pane_count, active_pane,
    });
}

pub fn logPaneFocus(direction: []const u8, active_pane: anytype) void {
    appendLine("pane", "focus {s} — active pane {}", .{ direction, active_pane });
}

pub fn logPaneEqualize(pane_count: anytype) void {
    appendLine("pane", "equalize — {} panes", .{pane_count});
}

pub fn logPaneZoom(enabled: bool, active_pane: anytype) void {
    appendLine("pane", "zoom {s} — active pane {}", .{ if (enabled) "on" else "off", active_pane });
}

pub fn logPaneSeparatorMoved(node: anytype, axis: []const u8, placed: anytype) void {
    appendLine("pane", "separator drag — node {} to {s} {}", .{ node, axis, placed });
}

pub fn logPaneSeparatorUnchanged(node: anytype) void {
    appendLine("pane", "separator drag — node {} unchanged (limit or same cell)", .{node});
}

pub fn logNewTabFailed(err: anyerror) void {
    appendLine("tab", "new tab failed: {s}", .{@errorName(err)});
}

pub fn logTabReorderFailed(err: anyerror) void {
    appendLine("tab", "reorder failed: {s}", .{@errorName(err)});
}

pub fn logToggle(show: bool) void {
    appendLineVerbose("toggle", "{s}", .{if (show) "show" else "hide"});
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
