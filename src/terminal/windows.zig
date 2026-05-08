//! Windows 의 TerminalBackend 구현 — ConPTY wrapper. `terminal.zig` 가
//! comptime 으로 select. 호출자가 `Options.extra_env` 로 환경변수 (theme 기반
//! COLORFGBG / WSLENV / TERM 등) 를 utf-8 로 보내면 init 시 utf-16 으로 변환해
//! ConPty 의 SetEnvironmentVariableW path 에 전달.

const std = @import("std");
const terminal = @import("../terminal.zig");
const ConPty = @import("windows/pty.zig").ConPty;

pub const Backend = struct {
    pty: ConPty,

    pub fn init(opts: terminal.Options) !Backend {
        // utf-8 → utf-16 변환 buffer 는 이 함수의 stack frame 에 두고, ConPty.init
        // 호출 동안만 valid 하면 됨 (자식 spawn 까지 SetEnvironmentVariableW 가
        // 처리 후 환경 복원).
        const MAX_EXTRA = 8;
        var name_bufs: [MAX_EXTRA][256]u16 = undefined;
        var value_bufs: [MAX_EXTRA][512]u16 = undefined;
        var combined: [MAX_EXTRA]ConPty.EnvVar = undefined;
        var n: usize = 0;
        if (opts.extra_env) |extras| {
            for (extras, 0..) |e, i| {
                if (n >= combined.len or i >= MAX_EXTRA) break;
                const nlen = std.unicode.utf8ToUtf16Le(&name_bufs[i], e.name) catch continue;
                const vlen = std.unicode.utf8ToUtf16Le(&value_bufs[i], e.value) catch continue;
                if (nlen >= name_bufs[i].len or vlen >= value_bufs[i].len) continue;
                name_bufs[i][nlen] = 0;
                value_bufs[i][vlen] = 0;
                combined[n] = .{
                    .name = @ptrCast(name_bufs[i][0..nlen :0]),
                    .value = @ptrCast(value_bufs[i][0..vlen :0]),
                };
                n += 1;
            }
        }

        const env_slice: ?[]const ConPty.EnvVar = if (n > 0) combined[0..n] else null;
        return .{
            .pty = try ConPty.init(opts.allocator, opts.cols, opts.rows, opts.shell, env_slice),
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
