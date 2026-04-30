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

        // termios 의 IUTF8 (= 0x4000) 활성화 — 한글 / 일본어 / 중국어 등
        // multi-byte UTF-8 입력 / cooked-mode editing 정확히 처리. macOS
        // default 는 IUTF8 OFF 라 multi-byte 가 단일 byte 로 처리되어 backspace
        // 등이 한 byte 만 지우거나 echo 가 누락되는 문제. tcsetattr 로
        // slave_fd 에 set.
        var tio: std.c.termios = undefined;
        if (std.c.tcgetattr(slave_fd, &tio) == 0) {
            const c_iflag_int: u64 = @bitCast(tio.iflag);
            const new_iflag: u64 = c_iflag_int | 0x4000; // IUTF8
            tio.iflag = @bitCast(new_iflag);
            _ = std.c.tcsetattr(slave_fd, .NOW, &tio);
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

            // 셸 실행. login shell 모드 (`-l` flag) 로 — "Last login: ..."
            // 출력 + ~/.bash_profile / ~/.zprofile 로드. macOS Terminal.app
            // 와 동일 동작. login shell 안 쓰면 row 0 가 비어 있어 첫 글자가
            // row 1 부터 시작 → 위쪽 padding 이 좌측보다 한 줄 더 커 보임.
            const argv = [_:null]?[*:0]const u8{ shell_z.ptr, "-l", null };
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
        // POSIX 는 close() 가 다른 thread 의 blocking read() 를 깨우는 것을
        // *보장 안* 함. macOS 도 깨워주지 않아 master fd close 만으로는 read
        // thread.join() 이 영원히 안 끝나는 deadlock 위험 (#111 M11.3 hang
        // 보고). 안전하게 끝내려면 자식 process group 을 확실히 죽인 후 read
        // 가 EIO 받고 자연 종료할 때까지 대기.
        if (self.child_pid > 0) {
            // -pid = process group. login_tty 가 새 session leader 만들었으니
            // child_pid == pgid. 자식이 fork 한 손자도 같이 hangup.
            _ = std.c.kill(-self.child_pid, std.posix.SIG.HUP);

            // SIGHUP 받고 죽기를 잠시 기다림 — bash / zsh 등 일반 셸은 즉시
            // 종료. 200ms 내에 안 죽으면 SIGKILL 강제.
            var status: c_int = 0;
            const max_polls: u32 = 20; // 20 × 10ms = 200ms
            var p: u32 = 0;
            while (p < max_polls) : (p += 1) {
                const rc = std.c.waitpid(self.child_pid, &status, std.c.W.NOHANG);
                if (rc > 0) break; // 죽음
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
            if (p >= max_polls) {
                std.debug.print("[pty] child {d} did not exit on SIGHUP, sending SIGKILL\n", .{self.child_pid});
                _ = std.c.kill(-self.child_pid, std.posix.SIG.KILL);
                _ = std.c.waitpid(self.child_pid, &status, 0); // blocking — 반드시 죽음
            }
        }

        // 자식 죽음 → master fd 의 read 가 EIO 받고 readLoop 종료. close 는
        // join 후로 미뤄도 되지만 빨리 close 해도 이 시점엔 안전.
        posix.close(self.master_fd);

        if (self.read_thread) |t| {
            t.join();
            self.read_thread = null;
        }
        if (self.wait_thread) |t| {
            t.join();
            self.wait_thread = null;
        }
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
