const std = @import("std");
const builtin = @import("builtin");
const themes = @import("themes.zig");

pub const ReadCallback = *const fn (data: []const u8, userdata: ?*anyopaque) void;
pub const ExitCallback = *const fn (userdata: ?*anyopaque) void;

pub const ShellCommand = switch (builtin.os.tag) {
    .windows => [*:0]const u16,
    else => []const u8,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    shell: ShellCommand,
    theme: ?*const themes.Theme,
};

pub const TerminalBackend = switch (builtin.os.tag) {
    .windows => WindowsConPtyBackend,
    else => UnsupportedTerminalBackend,
};

const WindowsConPtyBackend = if (builtin.os.tag == .windows) struct {
    const ConPty = @import("conpty.zig").ConPty;

    pty: ConPty,

    pub fn init(opts: Options) !WindowsConPtyBackend {
        return .{
            .pty = try ConPty.init(
                opts.allocator,
                opts.cols,
                opts.rows,
                opts.shell,
                envVarsForTheme(opts.theme),
            ),
        };
    }

    pub fn deinit(self: *WindowsConPtyBackend) void {
        self.pty.deinit();
    }

    pub fn write(self: *WindowsConPtyBackend, data: []const u8) !usize {
        return self.pty.write(data);
    }

    pub fn resize(self: *WindowsConPtyBackend, cols: u16, rows: u16) !void {
        return self.pty.resize(cols, rows);
    }

    pub fn startReadThread(
        self: *WindowsConPtyBackend,
        read_cb: ReadCallback,
        exit_cb: ExitCallback,
        userdata: ?*anyopaque,
    ) !void {
        return self.pty.startReadThread(read_cb, exit_cb, userdata);
    }

    /// 테마 배경 밝기에 따라 Windows child process 환경변수를 구성한다.
    /// SessionCore 는 이 Windows 전용 세부사항을 알 필요가 없다.
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
} else struct {};

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
