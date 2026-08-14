//! POSIX (Linux · macOS) TerminalBackend — `posix/pty.zig` 의 얇은 wrapper.
//! `terminal.zig` 가 comptime 으로 select. Windows 는 `terminal/windows.zig`
//! (ConPTY). #294 G2 — 이전 `terminal/linux.zig` ↔ `terminal/macos.zig` 2벌
//! (라인 수준 동일) 통합.

const terminal = @import("../terminal.zig");
const Pty = @import("posix/pty.zig").Pty;

pub const Backend = struct {
    pty: Pty,

    pub fn init(opts: terminal.Options) !Backend {
        // terminal.ExtraEnv 와 Pty.EnvVar 는 같은 shape ({ name, value }) 지만
        // nominal 다른 타입 — slice 변환.
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
                opts.rt,
                opts.allocator,
                opts.cols,
                opts.rows,
                opts.shell,
                pty_env,
                opts.cwd,
            ),
        };
    }

    pub fn deinit(self: *Backend) void {
        self.pty.deinit();
    }

    /// 자식 셸의 pid. 셸이 OSC 7 을 보내지 않을 때 OS 에 현재 디렉토리를 직접 묻는
    /// 데 쓴다 (#366, `process_cwd.zig`). **foreground process 가 아니라 셸 자신**이라
    /// `sudo` 같은 것에 흔들리지 않는다.
    pub fn childPid(self: *Backend) i32 {
        return self.pty.child_pid;
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
