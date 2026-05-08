//! Windows 의 TerminalBackend 구현 — ConPTY wrapper. `terminal.zig` 가
//! comptime 으로 select. 환경변수 (COLORFGBG / WSLENV) 셋업은 여기서.

const std = @import("std");
const themes = @import("../themes.zig");
const terminal = @import("../terminal.zig");
const ConPty = @import("windows/pty.zig").ConPty;

pub const Backend = struct {
    pty: ConPty,

    pub fn init(opts: terminal.Options) !Backend {
        // Theme 기반 (static utf-16) + 호출자가 추가한 (utf-8) env 두 source 를
        // 합쳐 ConPty 가 이해하는 utf-16 NUL-term 슬라이스로. utf-8 → utf-16
        // 변환 buffer 는 이 함수의 stack frame 에 두고, ConPty.init 호출 동안만
        // valid 하면 됨 (자식 spawn 까지 SetEnvironmentVariableW 가 다 처리).
        var combined: [16]ConPty.EnvVar = undefined;
        var n: usize = 0;
        if (envVarsForTheme(opts.theme)) |theme_env| {
            for (theme_env) |v| {
                if (n >= combined.len) break;
                combined[n] = v;
                n += 1;
            }
        }

        const MAX_EXTRA = 8;
        var name_bufs: [MAX_EXTRA][256]u16 = undefined;
        var value_bufs: [MAX_EXTRA][512]u16 = undefined;
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

/// 테마 배경 밝기에 따라 Windows child process 환경변수를 구성. SessionCore 는
/// 이 Windows 전용 세부사항을 알 필요가 없다.
fn envVarsForTheme(theme: ?*const themes.Theme) ?[]const ConPty.EnvVar {
    const S = struct {
        const dark_val = std.unicode.utf8ToUtf16LeStringLiteral("15;0");
        const light_val = std.unicode.utf8ToUtf16LeStringLiteral("0;15");
        const colorfgbg_name = std.unicode.utf8ToUtf16LeStringLiteral("COLORFGBG");
        const wslenv_name = std.unicode.utf8ToUtf16LeStringLiteral("WSLENV");
        var vars: [2]ConPty.EnvVar = undefined;
        var wslenv_buf: [512]u16 = undefined;
    };
    const t = theme orelse return null;
    S.vars[0] = .{
        .name = S.colorfgbg_name,
        .value = if (themes.isDark(t)) S.dark_val else S.light_val,
    };

    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("COLORFGBG");
    var pos: usize = 0;
    const existing = getEnvironmentVariableW(S.wslenv_name, &S.wslenv_buf);
    if (existing > 0 and existing < S.wslenv_buf.len - suffix.len - 1) {
        pos = existing;
        S.wslenv_buf[pos] = ':';
        pos += 1;
    }
    for (suffix) |c| {
        S.wslenv_buf[pos] = c;
        pos += 1;
    }
    S.wslenv_buf[pos] = 0;
    S.vars[1] = .{
        .name = S.wslenv_name,
        .value = @ptrCast(S.wslenv_buf[0..pos :0]),
    };
    return &S.vars;
}

extern "kernel32" fn GetEnvironmentVariableW([*:0]const u16, ?[*]u16, u32) callconv(.c) u32;

fn getEnvironmentVariableW(name: [*:0]const u16, buf: []u16) u32 {
    return GetEnvironmentVariableW(name, buf.ptr, @intCast(buf.len));
}
