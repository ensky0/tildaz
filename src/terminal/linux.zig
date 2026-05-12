//! Linux TerminalBackend 구현 — POSIX PTY wrapper.
//!
//! macOS 와 같은 POSIX 계열이지만 PTY 생성 경로가 다르다. macOS 는
//! `openpty` / `login_tty` 를 쓰고, Linux 는 `/dev/ptmx` 와 tty ioctl 로
//! pseudoterminal 을 구성한다. 외부 API 만 `terminal.zig` 에 맞춘다.

const std = @import("std");
const terminal = @import("../terminal.zig");
const Pty = @import("linux/pty.zig").Pty;

pub const Backend = struct {
    pty: Pty,

    pub fn init(opts: terminal.Options) !Backend {
        var pty_env_buf: [16]Pty.EnvVar = undefined;
        const pty_env: ?[]const Pty.EnvVar = if (opts.extra_env) |extras| blk: {
            const n = @min(extras.len, pty_env_buf.len);
            for (extras[0..n], 0..) |e, i| {
                pty_env_buf[i] = .{ .name = e.name, .value = e.value };
            }
            break :blk pty_env_buf[0..n];
        } else null;

        return .{
            .pty = try Pty.init(
                opts.allocator,
                opts.cols,
                opts.rows,
                opts.shell,
                pty_env,
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
