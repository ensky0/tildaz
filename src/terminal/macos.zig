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
        // 호출자가 준 utf-8 env 를 그대로 Pty 로. theme-based 자동 inject (#160)
        // 는 후속 — 현재는 호출자 (host/macos.zig) 가 직접 COLORFGBG 등 추가.
        _ = themes;
        // terminal.ExtraEnv 와 Pty.EnvVar 는 같은 shape ({ name: []const u8,
        // value: []const u8 }) 이지만 nominal 다른 타입 — slice 변환.
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
