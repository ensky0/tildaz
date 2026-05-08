//! macOS 의 TerminalBackend 구현 — POSIX PTY (`openpty` + `forkpty`) wrapper.
//! `terminal.zig` 가 comptime 으로 select.
//!
//! `Options.shell` 은 `[]const u8` (UTF-8 path). theme 기반 환경변수 (COLORFGBG
//! 등) 는 현재 미적용 — Windows 동등성 follow-up 이슈에서 추가 예정.

const std = @import("std");
const themes = @import("../themes.zig");
const terminal = @import("../terminal.zig");
const Pty = @import("macos/pty.zig").Pty;

pub const Backend = struct {
    pty: Pty,

    pub fn init(opts: terminal.Options) !Backend {
        // theme-based 환경변수는 현재 macOS 에선 inject 안 함 — Windows 와의
        // 동등성 갭. follow-up 이슈에서 ColorFG / 그 외 PTY 환경 통일.
        _ = themes;
        return .{
            .pty = try Pty.init(
                opts.allocator,
                opts.cols,
                opts.rows,
                opts.shell,
                null,
            ),
        };
    }

    pub fn deinit(self: *Backend) void {
        self.pty.deinit();
    }

    pub fn write(self: *Backend, data: []const u8) !usize {
        return self.pty.write(data);
    }

    pub fn resize(self: *Backend, cols: u16, rows: u16) !void {
        return self.pty.resize(cols, rows);
    }

    pub fn startReadThread(
        self: *Backend,
        read_cb: terminal.ReadCallback,
        exit_cb: terminal.ExitCallback,
        userdata: ?*anyopaque,
    ) !void {
        return self.pty.startReadThread(read_cb, exit_cb, userdata);
    }
};
