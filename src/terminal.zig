//! Cross-platform 터미널 backend 추상화 — 한 탭 = 1 PTY + 1 child shell.
//! 호출처 (`session_core.zig`) 가 platform 별 PTY API (Windows ConPTY /
//! macOS POSIX) 를 직접 다루지 않게.
//!
//! API:
//!   init(Options) → !Self
//!   deinit()
//!   write(data) → !usize
//!   resize(cols, rows) → !void
//!   startReadThread(read_cb, exit_cb, userdata) → !void
//!
//! 실제 구현은 `terminal/windows.zig` / `terminal/macos.zig` /
//! `terminal/linux.zig`. 각 모듈은 동일 API 시그니처를 export.

const std = @import("std");
const builtin = @import("builtin");
const themes = @import("themes.zig");

pub const ReadCallback = *const fn (data: []const u8, userdata: ?*anyopaque) void;
pub const ExitCallback = *const fn (userdata: ?*anyopaque) void;

/// 셸 실행 인자의 platform 별 표현. Windows 는 `CreateProcessW` 가 NUL-term
/// UTF-16 을 받고, POSIX 는 `execve` 가 NUL-term UTF-8 (= zig `[]const u8` +
/// dupeZ).
pub const ShellCommand = switch (builtin.os.tag) {
    .windows => [*:0]const u16,
    else => []const u8,
};

/// 자식 셸에 inject 할 환경변수. 양쪽 platform 동일 type (UTF-8). Windows
/// Backend 는 init 시 UTF-16 변환 + 호출 후 환경 복원, macOS Backend 는
/// `KEY=VALUE` allocPrintSentinel 후 execve 환경 배열에 prepend.
pub const ExtraEnv = struct {
    name: []const u8,
    value: []const u8,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    shell: ShellCommand,
    theme: ?*const themes.Theme,
    /// 호출자가 자식 셸에 inject 할 env (TERM / LANG / SHELL 등). theme 기반
    /// COLORFGBG / WSLENV (Windows) / 그 외 platform 자동 inject 와는 별개로
    /// 합쳐짐.
    extra_env: ?[]const ExtraEnv = null,
};

pub const TerminalBackend = switch (builtin.os.tag) {
    .windows => @import("terminal/windows.zig").Backend,
    .macos => @import("terminal/macos.zig").Backend,
    .linux => @import("terminal/linux.zig").Backend,
    else => UnsupportedTerminalBackend,
};

const UnsupportedTerminalBackend = struct {
    pub fn init(_: Options) !UnsupportedTerminalBackend {
        return error.UnsupportedTerminalBackend;
    }

    pub fn deinit(_: *UnsupportedTerminalBackend) void {}

    pub fn write(_: *UnsupportedTerminalBackend, _: []const u8) !usize {
        return error.UnsupportedTerminalBackend;
    }

    pub fn resize(_: *UnsupportedTerminalBackend, _: u16, _: u16) !void {
        return error.UnsupportedTerminalBackend;
    }

    pub fn startReadThread(
        _: *UnsupportedTerminalBackend,
        _: ReadCallback,
        _: ExitCallback,
        _: ?*anyopaque,
    ) !void {
        return error.UnsupportedTerminalBackend;
    }
};
