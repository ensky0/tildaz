//! Linux POSIX PTY backend.
//!
//! 생성 순서:
//!   1. `/dev/ptmx` master open
//!   2. `TIOCSPTLCK` 로 slave unlock
//!   3. `TIOCGPTN` 으로 `/dev/pts/<n>` slave 경로 확인
//!   4. child fork 후 `setsid` + `TIOCSCTTY` + stdio dup
//!   5. shell exec

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

pub const Pty = struct {
    master_fd: posix.fd_t,
    shutdown_fd: posix.fd_t,
    child_pid: posix.pid_t,
    read_thread: ?std.Thread = null,
    wait_thread: ?std.Thread = null,
    child_exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    allocator: std.mem.Allocator,

    pub const ReadCallback = *const fn (data: []const u8, userdata: ?*anyopaque) void;
    pub const ExitCallback = *const fn (userdata: ?*anyopaque) void;
    pub const EnvVar = struct { name: []const u8, value: []const u8 };

    pub fn init(
        allocator: std.mem.Allocator,
        cols: u16,
        rows: u16,
        shell: []const u8,
        extra_env: ?[]const EnvVar,
    ) !Pty {
        const master_fd = posix.open(
            "/dev/ptmx",
            .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true },
            0,
        ) catch return error.OpenPtyFailed;
        errdefer posix.close(master_fd);

        // #223 — read thread 의 poll 을 종료 시 깨우는 eventfd. EFD_CLOEXEC 로
        // 자식(shell)에 상속 안 되게.
        const shutdown_fd = posix.eventfd(0, linux.EFD.CLOEXEC) catch return error.OpenPtyFailed;
        errdefer posix.close(shutdown_fd);

        var unlock: c_int = 0;
        if (posix.errno(linux.ioctl(master_fd, linux.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS) {
            return error.UnlockPtyFailed;
        }

        var pty_num: c_uint = 0;
        if (posix.errno(linux.ioctl(master_fd, linux.T.IOCGPTN, @intFromPtr(&pty_num))) != .SUCCESS) {
            return error.ResolvePtySlaveFailed;
        }

        var slave_path_buf: [64]u8 = undefined;
        const slave_path = std.fmt.bufPrintZ(&slave_path_buf, "/dev/pts/{d}", .{pty_num}) catch {
            return error.ResolvePtySlaveFailed;
        };
        const slave_fd = posix.openZ(
            slave_path.ptr,
            .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true },
            0,
        ) catch return error.OpenPtyFailed;
        errdefer posix.close(slave_fd);

        try resizeFd(slave_fd, cols, rows);
        setIutf8(slave_fd);

        const shell_z = try allocator.dupeZ(u8, shell);
        defer allocator.free(shell_z);

        var env_map = std.process.getEnvMap(allocator) catch return error.EnvBuildFailed;
        defer env_map.deinit();
        if (extra_env) |vars| {
            for (vars) |v| {
                env_map.put(v.name, v.value) catch return error.EnvBuildFailed;
            }
        }

        var env_arena = std.heap.ArenaAllocator.init(allocator);
        defer env_arena.deinit();
        const envp_buf = std.process.createNullDelimitedEnvMap(env_arena.allocator(), &env_map) catch {
            return error.EnvBuildFailed;
        };
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(envp_buf.ptr);

        const pid = posix.fork() catch return error.ForkFailed;
        if (pid == 0) {
            childExec(master_fd, slave_fd, shell_z.ptr, envp);
        }

        posix.close(slave_fd);
        return .{
            .master_fd = master_fd,
            .shutdown_fd = shutdown_fd,
            .child_pid = pid,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pty) void {
        if (self.child_pid > 0 and !self.child_exited.load(.acquire)) {
            posix.kill(-self.child_pid, posix.SIG.HUP) catch {};

            const grace_ms: u64 = 500;
            const step_ms: u64 = 5;
            var elapsed: u64 = 0;
            while (elapsed < grace_ms) : (elapsed += step_ms) {
                if (self.child_exited.load(.acquire)) break;
                std.Thread.sleep(step_ms * std.time.ns_per_ms);
            }

            if (!self.child_exited.load(.acquire)) {
                posix.kill(-self.child_pid, posix.SIG.KILL) catch {};
                @import("../../log.zig").appendLine(
                    "pty",
                    "SIGHUP ignored after {d}ms, sent SIGKILL pgid={d}",
                    .{ grace_ms, self.child_pid },
                );
            }
        }

        if (self.wait_thread) |t| {
            t.join();
            self.wait_thread = null;
        }

        if (self.read_thread) |t| {
            // #223 — readLoop 의 poll 을 깨워 종료시킨다. daemon (예: openconnect
            // -b) 이 PTY slave 를 쥐고 있으면 master read 에 EOF 가 안 와서, 이
            // 신호 없이 join 하면 영원히 블록한다.
            const one: u64 = 1;
            _ = posix.write(self.shutdown_fd, std.mem.asBytes(&one)) catch {};
            t.join();
            self.read_thread = null;
        }

        posix.close(self.master_fd);
        posix.close(self.shutdown_fd);
    }

    pub fn write(self: *Pty, data: []const u8) !usize {
        return posix.write(self.master_fd, data) catch |err| switch (err) {
            error.WouldBlock => return 0,
            else => return error.WriteFailed,
        };
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) !void {
        return resizeFd(self.master_fd, cols, rows);
    }

    pub fn startReadThread(
        self: *Pty,
        callback: ReadCallback,
        exit_cb: ExitCallback,
        userdata: ?*anyopaque,
    ) !void {
        self.read_thread = try std.Thread.spawn(.{}, readLoop, .{ self.master_fd, self.shutdown_fd, callback, userdata });
        self.wait_thread = try std.Thread.spawn(.{}, processWaitLoop, .{ self.child_pid, &self.child_exited, exit_cb, userdata });
    }

    pub fn isProcessAlive(self: *Pty) bool {
        const result = posix.waitpid(self.child_pid, posix.W.NOHANG);
        return result.pid == 0;
    }
};

fn childExec(
    master_fd: posix.fd_t,
    slave_fd: posix.fd_t,
    shell: [*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) noreturn {
    posix.close(master_fd);

    if (linux.setsid() < 0) posix.exit(127);
    if (posix.errno(linux.ioctl(slave_fd, linux.T.IOCSCTTY, 0)) != .SUCCESS) posix.exit(127);

    posix.dup2(slave_fd, 0) catch posix.exit(127);
    posix.dup2(slave_fd, 1) catch posix.exit(127);
    posix.dup2(slave_fd, 2) catch posix.exit(127);
    if (slave_fd > 2) posix.close(slave_fd);

    const argv = [_:null]?[*:0]const u8{ shell, null };
    switch (posix.execveZ(shell, &argv, envp)) {
        else => posix.exit(127),
    }
}

fn setIutf8(fd: posix.fd_t) void {
    var tio = posix.tcgetattr(fd) catch return;
    tio.iflag.IUTF8 = true;
    posix.tcsetattr(fd, .NOW, tio) catch {};
}

fn resizeFd(fd: posix.fd_t, cols: u16, rows: u16) !void {
    var ws: posix.winsize = .{
        .col = cols,
        .row = rows,
        .xpixel = 0,
        .ypixel = 0,
    };
    if (posix.errno(linux.ioctl(fd, linux.T.IOCSWINSZ, @intFromPtr(&ws))) != .SUCCESS) {
        return error.ResizeFailed;
    }
}

fn readLoop(master_fd: posix.fd_t, shutdown_fd: posix.fd_t, callback: Pty.ReadCallback, userdata: ?*anyopaque) void {
    var buf: [65536]u8 = undefined;
    var fds = [_]posix.pollfd{
        .{ .fd = master_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = shutdown_fd, .events = posix.POLL.IN, .revents = 0 },
    };
    while (true) {
        _ = posix.poll(&fds, -1) catch break;
        // #223 — deinit 이 shutdown_fd 로 깨움 (daemon 이 slave 를 쥐어 master 에
        // EOF 가 안 와도 read thread 안전 종료 → join deadlock 회피).
        if ((fds[1].revents & posix.POLL.IN) != 0) break;
        if ((fds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            const n = posix.read(master_fd, &buf) catch break;
            if (n == 0) break;
            callback(buf[0..n], userdata);
        }
    }
}

fn processWaitLoop(
    child_pid: posix.pid_t,
    child_exited: *std.atomic.Value(bool),
    exit_cb: Pty.ExitCallback,
    userdata: ?*anyopaque,
) void {
    _ = posix.waitpid(child_pid, 0);
    child_exited.store(true, .release);
    exit_cb(userdata);
}
