// macOS / Linux POSIX PTY 구현
// ConPty(windows/conpty.zig)와 동일한 공개 인터페이스를 제공한다.
//
// 동작 방식:
//   openpty() → fork() → execvp(shell) → 셸 실행
//   부모 프로세스는 master fd로 읽기/쓰기
//   읽기 스레드: master fd에서 read() → callback 호출
//   프로세스 대기 스레드: waitpid() → exit_cb 호출

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    if (builtin.os.tag == .macos) {
        @cInclude("util.h"); // openpty on macOS
    } else {
        @cInclude("pty.h"); // openpty on Linux
    }
});

pub const Pty = struct {
    master_fd: posix.fd_t,
    child_pid: std.posix.pid_t,
    read_thread: ?std.Thread = null,
    wait_thread: ?std.Thread = null,
    allocator: std.mem.Allocator,

    pub const ReadCallback = *const fn (data: []const u8, userdata: ?*anyopaque) void;
    pub const ExitCallback = *const fn (userdata: ?*anyopaque) void;

    pub const EnvVar = struct {
        name: [*:0]const u8,
        value: [*:0]const u8,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        cols: u16,
        rows: u16,
        shell: [*:0]const u8,
        extra_env: ?[]const EnvVar,
    ) !Pty {
        // PTY 생성
        var master_fd: c_int = -1;
        var slave_fd: c_int = -1;

        var ws = std.mem.zeroes(c.struct_winsize);
        ws.ws_col = cols;
        ws.ws_row = rows;
        ws.ws_xpixel = 0;
        ws.ws_ypixel = 0;

        const ret = c.openpty(&master_fd, &slave_fd, null, null, &ws);
        if (ret != 0) return error.OpenPtyFailed;
        errdefer {
            _ = c.close(master_fd);
            _ = c.close(slave_fd);
        }

        // master fd에 O_CLOEXEC 설정 (fork 후 자식에서 닫힘)
        _ = c.fcntl(master_fd, c.F_SETFD, c.FD_CLOEXEC);

        // 자식 프로세스 생성
        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;

        if (pid == 0) {
            // --- 자식 프로세스 ---

            // slave fd를 stdin/stdout/stderr에 연결
            _ = c.close(master_fd);

            // 새 세션 생성 (터미널 제어 설정)
            _ = c.setsid();

            // slave를 제어 터미널로 설정 (TIOCSCTTY)
            _ = c.ioctl(slave_fd, c.TIOCSCTTY, @as(c_int, 0));

            _ = c.dup2(slave_fd, 0);
            _ = c.dup2(slave_fd, 1);
            _ = c.dup2(slave_fd, 2);
            _ = c.close(slave_fd);

            // 환경변수 설정
            if (extra_env) |vars| {
                for (vars) |v| {
                    _ = c.setenv(v.name, v.value, 1);
                }
            }

            // 터미널 타입 설정
            _ = c.setenv("TERM", "xterm-256color", 1);
            _ = c.setenv("COLORTERM", "truecolor", 1);

            // 셸 실행
            const args = [_:null]?[*:0]const u8{ shell, null };
            _ = c.execvp(shell, @ptrCast(&args));

            // execvp 실패 시 종료
            c.exit(1);
        }

        // --- 부모 프로세스 ---
        _ = c.close(slave_fd);

        return .{
            .master_fd = @intCast(master_fd),
            .child_pid = @intCast(pid),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pty) void {
        // 자식 프로세스 종료 시그널
        _ = posix.kill(self.child_pid, posix.SIG.HUP) catch {};

        // 스레드 대기
        if (self.read_thread) |t| {
            // master fd 닫아서 read 스레드 unblock
            posix.close(self.master_fd);
            self.master_fd = -1;
            t.join();
            self.read_thread = null;
        } else {
            if (self.master_fd >= 0) {
                posix.close(self.master_fd);
                self.master_fd = -1;
            }
        }
        if (self.wait_thread) |t| {
            t.join();
            self.wait_thread = null;
        }
    }

    pub fn write(self: *Pty, data: []const u8) !usize {
        return posix.write(self.master_fd, data);
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) !void {
        var ws = std.mem.zeroes(c.struct_winsize);
        ws.ws_col = cols;
        ws.ws_row = rows;
        const ret = c.ioctl(self.master_fd, c.TIOCSWINSZ, &ws);
        if (ret != 0) return error.ResizeFailed;
    }

    pub fn startReadThread(
        self: *Pty,
        callback: ReadCallback,
        exit_cb: ExitCallback,
        userdata: ?*anyopaque,
    ) !void {
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

    fn processWaitLoop(pid: std.posix.pid_t, exit_cb: ExitCallback, userdata: ?*anyopaque) void {
        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
        exit_cb(userdata);
    }

    pub fn isProcessAlive(self: *const Pty) bool {
        var status: c_int = 0;
        const ret = c.waitpid(self.child_pid, &status, c.WNOHANG);
        return ret == 0; // 0 = 아직 살아있음
    }
};
