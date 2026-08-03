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
//! 실제 구현은 `terminal/windows.zig` (ConPTY) / `terminal/posix.zig`
//! (Linux · macOS 공용, #294 G2). 각 모듈은 동일 API 시그니처를 export.

const std = @import("std");
const builtin = @import("builtin");

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
/// Backend 는 init 시 UTF-16 변환 + 호출 후 환경 복원, POSIX Backend 는
/// 부모 environ 에 override 머지 후 execve 환경 배열로.
pub const ExtraEnv = struct {
    name: []const u8,
    value: []const u8,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    shell: ShellCommand,
    /// 호출자가 자식 셸에 inject 할 env (TERM / LANG / SHELL 등). theme 기반
    /// COLORFGBG / WSLENV (Windows) / 그 외 platform 자동 inject 와는 별개로
    /// 합쳐짐.
    extra_env: ?[]const ExtraEnv = null,
    /// 셸의 시작 디렉토리 (#366). `null` 이면 홈 — [#265](https://github.com/ensky0/tildaz/issues/265)
    /// 로 정한 기존 동작이다. 값이 있어도 그 경로로 시작하지 못하면 각 backend 가
    /// 홈으로 열화한다 (경로가 spawn 직전에 사라질 수 있다).
    ///
    /// 표기는 **탭의 셸 기준**이다 — WSL 탭은 host 가 Windows 여도 Linux 경로다
    /// (`isWslShell` 참조).
    cwd: ?[]const u8 = null,
};

/// 이 셸 커맨드가 WSL 탭인지. WSL 안 셸은 Linux 경로를 보고하고 새 탭도
/// `wsl --cd <Linux 경로>` 로 받으므로, OSC 7 경로의 표기 방식이 host OS 와 다르다
/// (#366). Windows 아닌 platform 은 항상 false.
///
/// comptime 으로 고르는 이유: Windows 구현은 `wsl.exe` 명령줄 토큰을 UTF-16 으로
/// 훑는 코드라 다른 platform 에서는 컴파일 자체가 안 된다 (`TerminalBackend` 와 같은
/// 패턴).
pub const isWslShell = if (builtin.os.tag == .windows)
    @import("terminal/windows/pty.zig").isWslCommand
else
    struct {
        fn notWsl(_: ShellCommand) bool {
            return false;
        }
    }.notWsl;

pub const TerminalBackend = switch (builtin.os.tag) {
    .windows => @import("terminal/windows.zig").Backend,
    .macos, .linux => @import("terminal/posix.zig").Backend,
    else => UnsupportedTerminalBackend,
};

const UnsupportedTerminalBackend = struct {
    pub fn init(_: Options) !UnsupportedTerminalBackend {
        return error.UnsupportedTerminalBackend;
    }

    pub fn deinit(_: *UnsupportedTerminalBackend) void {}

    pub fn childPid(_: *UnsupportedTerminalBackend) i32 {
        return 0;
    }

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
