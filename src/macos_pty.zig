// macOS POSIX PTY — `openpty(3)` + `forkpty(3)` 패턴으로 셸 spawn + master fd
// 양방향 통신.
//
// Windows 의 `src/conpty.zig` (ConPTY 기반) 와 같은 역할. 인터페이스도 동등하게
// 맞춰서 추후 `src/terminal_backend.zig` 로 통합 시 매끄럽게.
//   - init(allocator, cols, rows, shell, extra_env) → spawn
//   - write(data) → master fd 로 키 입력 송신
//   - resize(cols, rows) → TIOCSWINSZ
//   - startReadThread(read_cb, exit_cb, userdata) → 백그라운드 read / waitpid
//   - deinit() → close + thread join + reap
//
// 패턴은 #75 (claude/infallible-swartz) 에서 검증된 그대로 차용.

const std = @import("std");
const posix = std.posix;

// macOS C API 선언 — Zig 표준 라이브러리에 일부 함수가 없어서 직접.
const c = struct {
    extern "c" fn openpty(
        amaster: *posix.fd_t,
        aslave: *posix.fd_t,
        name: ?[*:0]u8,
        termp: ?*const anyopaque,
        winp: ?*const posix.winsize,
    ) c_int;
    extern "c" fn login_tty(fd: posix.fd_t) c_int;
};

// `TIOCSWINSZ` (윈도우 크기 변경 ioctl) 는 Zig stdlib 의 macOS 정의에 없어서
// 직접. `IOW('t', 103, struct winsize)` 인코딩.
const TIOCSWINSZ: c_int = @bitCast(@as(
    u32,
    0x80000000 | (@as(u32, @sizeOf(posix.winsize)) << 16) | (@as(u32, 't') << 8) | 103,
));

pub const Pty = struct {
    master_fd: posix.fd_t,
    child_pid: posix.pid_t,
    read_thread: ?std.Thread = null,
    wait_thread: ?std.Thread = null,
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

        // 셸 경로를 NUL-terminated 로. execve 가 `argv[0]` 으로 사용.
        const shell_z = try allocator.dupeZ(u8, shell);
        defer allocator.free(shell_z);

        // 자식의 환경변수 — 부모 environ 복사 + extra_env 추가.
        var env_buf: [256]?[*:0]const u8 = @splat(null);
        var env_count: usize = 0;

        const environ: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
        {
            var i: usize = 0;
            while (environ[i] != null and env_count < env_buf.len - 2) : (i += 1) {
                env_buf[env_count] = environ[i].?;
                env_count += 1;
            }
        }

        var extra_env_strs: [16][:0]u8 = undefined;
        var extra_env_count: usize = 0;
        if (extra_env) |vars| {
            for (vars) |v| {
                if (extra_env_count >= extra_env_strs.len) break;
                const s = try std.fmt.allocPrintSentinel(
                    allocator,
                    "{s}={s}",
                    .{ v.name, v.value },
                    0,
                );
                extra_env_strs[extra_env_count] = s;
                env_buf[env_count] = s.ptr;
                env_count += 1;
                extra_env_count += 1;
            }
        }
        defer for (extra_env_strs[0..extra_env_count]) |s| allocator.free(s);

        // env_buf[env_count] 는 @splat 으로 이미 null — sentinel 끝.
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(&env_buf);

        const pid = std.c.fork();
        if (pid < 0) return error.ForkFailed;

        if (pid == 0) {
            // --- 자식 프로세스 ---
            _ = std.c.close(master_fd);

            // 새 세션 + controlling terminal 등록 + stdio (0/1/2) 를 slave 로
            // redirect 까지 한 번에 (login_tty(3)).
            _ = c.login_tty(slave_fd);

            // 셸 실행. argv[0] = shell, argv[1] = null.
            const argv = [_:null]?[*:0]const u8{ shell_z.ptr, null };
            _ = std.c.execve(shell_z.ptr, &argv, envp);

            // execve 실패 — 보통 셸 경로 잘못. exit code 127 (POSIX \"command
            // not found\" 관습).
            std.c.exit(127);
        }

        // --- 부모 프로세스 ---
        _ = std.c.close(slave_fd);

        return .{
            .master_fd = master_fd,
            .child_pid = @intCast(pid),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pty) void {
        // master fd close → read 가 EOF 받고 readLoop 빠져나옴.
        posix.close(self.master_fd);

        if (self.read_thread) |t| {
            t.join();
            self.read_thread = null;
        }
        if (self.wait_thread) |t| {
            t.join();
            self.wait_thread = null;
        }

        // 자식이 이미 죽었으면 zombie 회수, 안 죽었으면 NOHANG 으로 즉시 리턴.
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

    fn processWaitLoop(child_pid: posix.pid_t, exit_cb: ExitCallback, userdata: ?*anyopaque) void {
        _ = posix.waitpid(child_pid, 0);
        exit_cb(userdata);
    }

    pub fn isProcessAlive(self: *Pty) bool {
        const result = posix.waitpid(self.child_pid, std.c.W.NOHANG);
        return result.pid == 0;
    }
};
