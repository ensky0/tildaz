//! Cross-platform 로그 — 통합 로그 파일에 timestamp + category + message 한
//! 줄 append. `perf` 스냅샷 같이 자체 헤더를 가진 다중 줄 블록은 `appendBlock`
//! 으로 prefix 없이 그대로.
//!
//! 로그 위치:
//!   - Windows: `%APPDATA%\tildaz\tildaz.log`
//!   - macOS:   `~/Library/Logs/tildaz.log`  (Apple HIG — Console.app 자동 인덱싱)
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
        const f = std.fs.createFileAbsolute(path, .{ .truncate = false, .read = false }) catch return;
        defer f.close();
        f.seekFromEnd(0) catch {};
        f.writeAll(text) catch {};
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
