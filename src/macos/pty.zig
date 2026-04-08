const std = @import("std");
const posix = std.posix;

// macOS C API declarations
const c = struct {
    extern "c" fn openpty(
        amaster: *posix.fd_t,
        aslave: *posix.fd_t,
        name: ?[*:0]u8,
        termp: ?*const anyopaque,
        winp: ?*const posix.winsize,
    ) c_int;
    extern "c" fn setsid() std.c.pid_t;
    extern "c" fn login_tty(fd: posix.fd_t) c_int;
};

// TIOCSWINSZ: not defined in Zig stdlib for macOS, define manually
// IOW('t', 103, struct winsize) = 0x80000000 | (sizeof(winsize) << 16) | ('t' << 8) | 103
const TIOCSWINSZ: c_int = @bitCast(@as(u32, 0x80000000 | (@as(u32, @sizeOf(posix.winsize)) << 16) | (@as(u32, 't') << 8) | 103));

pub const Pty = struct {
    master_fd: posix.fd_t,
    child_pid: posix.pid_t,
    read_thread: ?std.Thread = null,
    wait_thread: ?std.Thread = null,
    allocator: std.mem.Allocator,

    pub const ReadCallback = *const fn (data: []const u8, userdata: ?*anyopaque) void;
    pub const ExitCallback = *const fn (userdata: ?*anyopaque) void;
    pub const EnvVar = struct { name: []const u8, value: []const u8 };

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16, shell: []const u8, extra_env: ?[]const EnvVar) !Pty {
        var master_fd: posix.fd_t = undefined;
        var slave_fd: posix.fd_t = undefined;

        const ws = posix.winsize{
            .col = cols,
            .row = rows,
            .xpixel = 0,
            .ypixel = 0,
        };

        if (c.openpty(&master_fd, &slave_fd, null, null, &ws) < 0) {
            return error.OpenPtyFailed;
        }

        // Prepare shell arguments for execvp
        const shell_z = try allocator.dupeZ(u8, shell);
        defer allocator.free(shell_z);

        // Prepare environment variables
        var env_buf: [256]?[*:0]const u8 = @splat(null);
        var env_count: usize = 0;

        // Copy existing environment
        const environ: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
        {
            var i: usize = 0;
            while (environ[i] != null and env_count < env_buf.len - 2) : (i += 1) {
                env_buf[env_count] = environ[i].?;
                env_count += 1;
            }
        }

        // Add extra environment variables
        var extra_env_strs: [16][:0]u8 = undefined;
        var extra_env_count: usize = 0;
        if (extra_env) |vars| {
            for (vars) |v| {
                if (extra_env_count >= extra_env_strs.len) break;
                const s = try std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ v.name, v.value }, 0);
                extra_env_strs[extra_env_count] = s;
                env_buf[env_count] = s.ptr;
                env_count += 1;
                extra_env_count += 1;
            }
        }
        defer for (extra_env_strs[0..extra_env_count]) |s| allocator.free(s);

        // env_buf[env_count] is already null from @splat
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(&env_buf);

        const pid = std.c.fork();
        if (pid < 0) return error.ForkFailed;

        if (pid == 0) {
            // --- Child process ---
            _ = std.c.close(master_fd);

            // Create new session + set controlling terminal + redirect stdio
            _ = c.login_tty(slave_fd);

            // Exec shell
            const argv = [_:null]?[*:0]const u8{ shell_z.ptr, null };
            _ = std.c.execve(shell_z.ptr, &argv, envp);

            // execve failed
            std.c.exit(127);
        }

        // --- Parent process ---
        _ = std.c.close(slave_fd);

        return .{
            .master_fd = master_fd,
            .child_pid = @intCast(pid),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pty) void {
        posix.close(self.master_fd);

        if (self.read_thread) |t| {
            t.join();
            self.read_thread = null;
        }
        if (self.wait_thread) |t| {
            t.join();
            self.wait_thread = null;
        }

        _ = posix.waitpid(self.child_pid, std.c.W.NOHANG);
    }

    pub fn write(self: *Pty, data: []const u8) !usize {
        return posix.write(self.master_fd, data) catch |err| switch (err) {
            error.WouldBlock => return 0,
            else => return error.WriteFailed,
        };
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) !void {
        var ws: posix.winsize = .{
            .col = cols,
            .row = rows,
            .xpixel = 0,
            .ypixel = 0,
        };
        const rc = std.c.ioctl(self.master_fd, TIOCSWINSZ, @intFromPtr(&ws));
        if (rc < 0) return error.ResizeFailed;
    }

    pub fn startReadThread(self: *Pty, callback: ReadCallback, exit_cb: ExitCallback, userdata: ?*anyopaque) !void {
        self.read_thread = try std.Thread.spawn(.{}, readLoop, .{ self.master_fd, callback, userdata });
        self.wait_thread = try std.Thread.spawn(.{}, processWaitLoop, .{ self.child_pid, exit_cb, userdata });
    }

    fn readLoop(master_fd: posix.fd_t, callback: ReadCallback, userdata: ?*anyopaque) void {
        var buf: [65536]u8 = undefined;
        while (true) {
            const n = posix.read(master_fd, &buf) catch break;
            if (n == 0) break;
            callback(buf[0..n], userdata);
        }
    }

    fn processWaitLoop(child_pid: posix.pid_t, exit_cb: ExitCallback, userdata: ?*anyopaque) void {
        _ = posix.waitpid(child_pid, 0);
        exit_cb(userdata);
    }

    pub fn isProcessAlive(self: *Pty) bool {
        const result = posix.waitpid(self.child_pid, std.c.W.NOHANG);
        return result.pid == 0;
    }
};
