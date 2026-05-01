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
    /// 자식 종료 감지 flag — `processWaitLoop` 의 `waitpid` 가 깨어나면 set.
    /// `deinit` 의 SIGHUP fallback (#129) 이 polling 으로 검사.
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

    /// Tab / 앱 종료 시 자식 셸 정리. Windows ConPTY 의 deinit (`src/conpty.zig`
    /// `ConPty.deinit`) 과 흐름이 다름 — 비교 노트.
    ///
    /// === Windows ConPTY 흐름 ===
    /// 1. `ClosePseudoConsole(hpc)` — 한 호출이 input/output pipe 끊고 자식
    ///    process 도 OS 가 정리 (내부적으로 console signal 송신 추정).
    /// 2. `read_thread.join()` — output pipe 끊겨 ReadFile 에러 → break.
    /// 3. `wait_thread.join()` — `WaitForSingleObject(hProc, INFINITE)` 가
    ///    자식 종료 즉시 깨어남.
    /// 4. `CloseHandle` (pipe / event / process / thread).
    ///
    /// === macOS PTY 흐름 (이 함수) ===
    /// 1. `kill(-pid, SIGHUP)` — POSIX 시그널을 process group 으로 송신.
    ///    `login_tty` 가 만든 새 session leader 라 child_pid == pgid, 자식이
    ///    fork 한 손자까지 같이 hangup.
    /// 2. `wait_thread.join()` — `waitpid(pid, 0)` blocking 이 자식 종료 즉시
    ///    깨어남.
    /// 3. `read_thread.join()` — 자식 죽음으로 master fd EIO → read 에러 →
    ///    readLoop break.
    /// 4. `close(master_fd)`.
    ///
    /// === 본질 차이 ===
    /// - Windows 는 `ClosePseudoConsole` 가 자식 정리를 OS API 한 번에 추상화.
    ///   우리 코드는 핸들 close 만.
    /// - macOS 의 PTY master 는 그냥 fd 라 자식에게 *직접* 시그널 보내야 함.
    ///   `close(fd)` 만으로는 다른 thread 의 blocking read 를 깨우는 게 POSIX
    ///   에 보장 안 됨 + 자식이 stdin EOF 처리 안 하는 셸도 있음 → 시그널 필수.
    /// - Windows 의 `WaitForSingleObject` 와 macOS 의 blocking `waitpid` 는
    ///   같은 역할 (자식 종료까지 thread blocking).
    ///
    /// === 폴링 안 하는 이유 ===
    /// 이전 구현 (#111 M11.3 첫 시도) 은 SIGHUP 후 `waitpid(NOHANG)` 폴링 +
    /// 10ms sleep × 20 으로 자식 죽음 확인했는데 사용자 환경에서 약 10~30ms
    /// 인지 가능 지연 보고. wait_thread 가 이미 blocking `waitpid` 으로 자식을
    /// 기다리는 중이므로 그 thread.join 만으로 sleep 없이 즉시 동기화 가능.
    ///
    /// === SIGHUP 무시 셸 fallback (#129) ===
    /// `nohup` wrapper / `trap '' HUP` 셸은 SIGHUP 그냥 흘려보냄 → wait_thread
    /// 의 `waitpid(pid, 0)` 가 영원히 안 깨어남 → `wait_thread.join()` hang.
    /// 우리 앱 종료 / 탭 닫기가 영원히 안 끝남.
    ///
    /// 회피: SIGHUP 송신 후 grace period (500ms) 동안 `child_exited` atomic
    /// flag polling. `processWaitLoop` 가 `waitpid` 깨어나면서 flag set →
    /// loop 즉시 break → 일반 케이스 인지 지연 ≤ step_ms (5ms). grace
    /// 안 끝나면 (= 셸이 SIGHUP 무시) SIGKILL 으로 강제 종료. SIGKILL 은
    /// 무시 못 함 → wait_thread 즉시 깨어남.
    ///
    /// std.Thread 에 timed_join 이 없어서 polling 우회. step_ms = 5ms 로
    /// 정상 케이스 지연 거의 0 (이전 200ms polling 과 차원이 다름).
    pub fn deinit(self: *Pty) void {
        if (self.child_pid > 0) {
            _ = std.c.kill(-self.child_pid, std.posix.SIG.HUP);

            // grace period: 자식이 SIGHUP 으로 정상 종료하길 기다림.
            const grace_ms: u64 = 500;
            const step_ms: u64 = 5;
            var elapsed: u64 = 0;
            while (elapsed < grace_ms) : (elapsed += step_ms) {
                if (self.child_exited.load(.acquire)) break;
                std.Thread.sleep(step_ms * std.time.ns_per_ms);
            }

            // SIGHUP 무시 셸 — SIGKILL 으로 강제 종료. 로그 한 줄 남김.
            if (!self.child_exited.load(.acquire)) {
                _ = std.c.kill(-self.child_pid, std.posix.SIG.KILL);
                @import("macos_log.zig").appendLine(
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
            t.join();
            self.read_thread = null;
        }

        posix.close(self.master_fd);
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
        self.wait_thread = try std.Thread.spawn(.{}, processWaitLoop, .{ self.child_pid, &self.child_exited, exit_cb, userdata });
    }

    fn readLoop(master_fd: posix.fd_t, callback: ReadCallback, userdata: ?*anyopaque) void {
        var buf: [65536]u8 = undefined;
        while (true) {
            const n = posix.read(master_fd, &buf) catch break;
            if (n == 0) break;
            callback(buf[0..n], userdata);
        }
    }

    fn processWaitLoop(child_pid: posix.pid_t, child_exited: *std.atomic.Value(bool), exit_cb: ExitCallback, userdata: ?*anyopaque) void {
        _ = posix.waitpid(child_pid, 0);
        // deinit 의 SIGHUP fallback polling 이 검사하는 flag 를 먼저 set
        // (#129). exit_cb 보다 먼저 — exit_cb 가 길게 걸려도 deinit 가 즉시
        // grace loop break 하도록.
        child_exited.store(true, .release);
        exit_cb(userdata);
    }

    pub fn isProcessAlive(self: *Pty) bool {
        const result = posix.waitpid(self.child_pid, std.c.W.NOHANG);
        return result.pid == 0;
    }
};
