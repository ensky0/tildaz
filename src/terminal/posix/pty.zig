//! POSIX PTY backend — Linux · macOS 공용 (#294 G2, 이전 `terminal/linux/pty.zig`
//! ↔ `terminal/macos/pty.zig` 2벌 통합).
//!
//! lifecycle (deinit 의 SIGHUP → grace → SIGKILL, write, readLoop,
//! processWaitLoop, chdir(HOME), env 조립) 은 한 벌이고, OS 가 실제로 다른
//! 지점만 comptime 분기:
//!   - PTY pair 생성: Linux `/dev/ptmx` + `unlockpt` + `ptsname_r`,
//!     macOS `openpty(3)` (+ Linux 와 동일한 CLOEXEC 정책 — #282 D4).
//!   - child tty 설정: Linux `setsid` + `TIOCSCTTY` + dup2, macOS `login_tty(3)`.
//!   - shell argv: macOS 만 login shell (`-l`) — OS 터미널 관례 차이 (#282 D5,
//!     SPEC §9 문서화된 의도).
//!   - resize ioctl 호출 방법.
//!
//! read thread 의 종료 깨우기는 self-pipe — 이전 Linux 의 eventfd (#223) 를
//! 이식 primitive 로 교체 (`std.posix.pipe2` 가 macOS 에선 pipe+fcntl 로
//! fallback). macOS 는 XNU 가 session leader 종료 시 revoke 로 POLLHUP 을
//! 보장하지만 (#282 검증 기록), 같은 코드가 돌아도 무해 + 방어 겸용.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const perf = @import("../../perf.zig");

// Linux: PTY slave unlock / 경로 조회 — glibc POSIX ptmx API (#298).
// macOS: openpty / login_tty 는 Zig std 에 없어 직접 선언.
// extern 선언 자체는 양 OS 에서 무해 — 참조 안 되는 심볼은 링크에 안 끌려온다.
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, buflen: usize) c_int;
extern "c" fn openpty(
    amaster: *posix.fd_t,
    aslave: *posix.fd_t,
    name: ?[*:0]u8,
    termp: ?*const anyopaque,
    winp: ?*const posix.winsize,
) c_int;
extern "c" fn login_tty(fd: posix.fd_t) c_int;

/// `TIOCSWINSZ` 는 Zig stdlib 의 macOS 정의에 없어서 직접. `IOW('t', 103,
/// struct winsize)` 인코딩. (Linux 는 `linux.T.IOCSWINSZ` 사용.)
const DARWIN_TIOCSWINSZ: c_int = @bitCast(@as(
    u32,
    0x80000000 | (@as(u32, @sizeOf(posix.winsize)) << 16) | (@as(u32, 't') << 8) | 103,
));

pub const Pty = struct {
    master_fd: posix.fd_t,
    /// self-pipe — deinit 이 write 끝에 1 byte 써서 readLoop 의 poll 을 깨움.
    /// [0] = read (poll 대상), [1] = write.
    shutdown_pipe: [2]posix.fd_t,
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
        cwd: ?[]const u8,
    ) !Pty {
        const pair = try openPtyPair(cols, rows);
        errdefer posix.close(pair.master);
        errdefer posix.close(pair.slave);

        const shutdown_pipe = posix.pipe2(.{ .CLOEXEC = true }) catch return error.OpenPtyFailed;
        errdefer {
            posix.close(shutdown_pipe[0]);
            posix.close(shutdown_pipe[1]);
        }

        setIutf8(pair.slave);

        const shell_z = try allocator.dupeZ(u8, shell);
        defer allocator.free(shell_z);

        // 자식 환경 — 부모 environ 에 extra_env 를 *override* 로 머지 (map put).
        // POSIX getenv 가 first-match 라 부모의 같은 key (예: SHELL=/bin/bash)
        // 가 살아남으면 우리가 spawn 한 셸과 어긋나는 #118 문제 — extra 우선.
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

        // fork 후 자식은 allocator 를 쓸 수 없으니 (#366) 시작 디렉토리도 미리
        // NUL-term 으로 만들어 둔다 — `shell_z` 와 같은 패턴.
        const cwd_z: ?[:0]u8 = if (cwd) |dir|
            allocator.dupeZ(u8, dir) catch return error.EnvBuildFailed
        else
            null;
        defer if (cwd_z) |z| allocator.free(z);

        const pid = posix.fork() catch return error.ForkFailed;
        if (pid == 0) {
            childExec(
                pair.master,
                pair.slave,
                shell_z.ptr,
                envp,
                if (cwd_z) |z| z.ptr else null,
            );
        }

        posix.close(pair.slave);
        return .{
            .master_fd = pair.master,
            .shutdown_pipe = shutdown_pipe,
            .child_pid = pid,
            .allocator = allocator,
        };
    }

    /// Tab / 앱 종료 시 자식 셸 정리. SIGHUP 을 process group 으로 (session
    /// leader 라 child_pid == pgid — 손자까지 hangup) 보내고, wait_thread 의
    /// blocking `waitpid` 가 종료를 감지하길 grace (500ms) 동안 기다린다.
    /// SIGHUP 무시 셸 (`trap '' HUP` / nohup wrapper, #129) 은 SIGKILL 로 강제
    /// — 아니면 `wait_thread.join()` 이 영원히 안 끝난다. polling (5ms step)
    /// 인 이유: std.Thread 에 timed_join 이 없음.
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
            _ = posix.write(self.shutdown_pipe[1], &.{1}) catch {};
            t.join();
            self.read_thread = null;
        }

        posix.close(self.master_fd);
        posix.close(self.shutdown_pipe[0]);
        posix.close(self.shutdown_pipe[1]);
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
        self.read_thread = try std.Thread.spawn(.{}, readLoop, .{ self.master_fd, self.shutdown_pipe[0], callback, userdata });
        self.wait_thread = try std.Thread.spawn(.{}, processWaitLoop, .{ self.child_pid, &self.child_exited, exit_cb, userdata });
    }
};

const PtyPair = struct { master: posix.fd_t, slave: posix.fd_t };

fn openPtyPair(cols: u16, rows: u16) !PtyPair {
    if (builtin.os.tag == .linux) {
        const master_fd = posix.open(
            "/dev/ptmx",
            .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true },
            0,
        ) catch return error.OpenPtyFailed;
        errdefer posix.close(master_fd);

        if (unlockpt(master_fd) != 0) return error.UnlockPtyFailed;

        var slave_path_buf: [64]u8 = undefined;
        if (ptsname_r(master_fd, &slave_path_buf, slave_path_buf.len) != 0) {
            return error.ResolvePtySlaveFailed;
        }
        // ptsname_r 은 null-terminated 경로를 buf 에 기록 → C 문자열로 open.
        const slave_path: [*:0]const u8 = @ptrCast(&slave_path_buf);
        const slave_fd = posix.openZ(
            slave_path,
            .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true },
            0,
        ) catch return error.OpenPtyFailed;
        errdefer posix.close(slave_fd);

        try resizeFd(slave_fd, cols, rows);
        return .{ .master = master_fd, .slave = slave_fd };
    } else {
        var master_fd: posix.fd_t = undefined;
        var slave_fd: posix.fd_t = undefined;
        const ws = posix.winsize{ .col = cols, .row = rows, .xpixel = 0, .ypixel = 0 };
        if (openpty(&master_fd, &slave_fd, null, null, &ws) < 0) {
            return error.OpenPtyFailed;
        }
        // openpty 는 CLOEXEC 없이 fd 를 만든다 — Linux 와 동일 정책으로 set
        // (#282 D4: 없으면 나중 탭의 자식 셸이 기존 탭들의 master 를 execve
        // 이후까지 상속). 자식의 stdio 는 login_tty 가 dup 으로 만들어 dup 이
        // FD_CLOEXEC 를 지우므로 slave 에 걸어도 안전.
        setCloexec(master_fd);
        setCloexec(slave_fd);
        return .{ .master = master_fd, .slave = slave_fd };
    }
}

fn setCloexec(fd: posix.fd_t) void {
    const flags = posix.fcntl(fd, posix.F.GETFD, 0) catch return;
    _ = posix.fcntl(fd, posix.F.SETFD, flags | posix.FD_CLOEXEC) catch {};
}

fn childExec(
    master_fd: posix.fd_t,
    slave_fd: posix.fd_t,
    shell: [*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    cwd: ?[*:0]const u8,
) noreturn {
    posix.close(master_fd);

    if (builtin.os.tag == .linux) {
        // 새 세션 + controlling terminal 등록 + stdio redirect 수동.
        if (linux.setsid() < 0) posix.exit(127);
        if (posix.errno(linux.ioctl(slave_fd, linux.T.IOCSCTTY, 0)) != .SUCCESS) posix.exit(127);
        posix.dup2(slave_fd, 0) catch posix.exit(127);
        posix.dup2(slave_fd, 1) catch posix.exit(127);
        posix.dup2(slave_fd, 2) catch posix.exit(127);
        if (slave_fd > 2) posix.close(slave_fd);
    } else {
        // login_tty(3) 가 setsid + TIOCSCTTY + stdio dup 을 한 번에.
        _ = login_tty(slave_fd);
    }

    // 시작 디렉토리 — 호출자가 준 경로 (#366, 활성 탭이 OSC 7 로 알린 위치) 를
    // 먼저 쓰고, 없거나 그리로 못 가면 홈 (#265) 으로 간다. `HOME` 까지 실패하면
    // 그대로 진행 (#265 이전 동작).
    //
    // cwd 실패를 그냥 넘기지 않고 홈으로 되돌리는 이유: 아무 곳도 안 가면 부모
    // (앱) 의 현재 디렉토리를 물려받아 실행 경로 (런처 / Finder / 셸) 에 따라 시작
    // 위치가 달라진다 — #265 가 고친 문제가 그대로 되살아난다. 호출자가 spawn 전에
    // 디렉토리 존재를 확인하지만 그 사이에 지워질 수 있다.
    const moved = if (cwd) |dir| blk: {
        posix.chdirZ(dir) catch break :blk false;
        break :blk true;
    } else false;
    if (!moved) {
        if (posix.getenv("HOME")) |home| {
            posix.chdir(home) catch {};
        }
    }

    // macOS 만 login shell (`-l`) — "Last login" + ~/.zprofile 로드,
    // Terminal.app 관례. Linux 터미널 관례는 비-login (#282 D5, SPEC §9).
    if (builtin.os.tag == .macos) {
        const argv = [_:null]?[*:0]const u8{ shell, "-l", null };
        switch (posix.execveZ(shell, &argv, envp)) {
            else => posix.exit(127),
        }
    } else {
        const argv = [_:null]?[*:0]const u8{ shell, null };
        switch (posix.execveZ(shell, &argv, envp)) {
            else => posix.exit(127),
        }
    }
}

/// termios IUTF8 활성화 — multi-byte UTF-8 의 cooked-mode editing (한글
/// backspace 등) 정확히. macOS default 는 OFF, Linux 배포판은 대개 ON 이지만
/// 명시 set 으로 통일.
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
    if (builtin.os.tag == .linux) {
        if (posix.errno(linux.ioctl(fd, linux.T.IOCSWINSZ, @intFromPtr(&ws))) != .SUCCESS) {
            return error.ResizeFailed;
        }
    } else {
        if (std.c.ioctl(fd, DARWIN_TIOCSWINSZ, @intFromPtr(&ws)) < 0) {
            return error.ResizeFailed;
        }
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
        // #223 — deinit 이 self-pipe 로 깨움 (daemon 이 slave 를 쥐어 master 에
        // EOF 가 안 와도 read thread 안전 종료 → join deadlock 회피).
        if ((fds[1].revents & posix.POLL.IN) != 0) break;
        if ((fds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            // #160/#254 — poll 대기 (idle) 는 계측 밖, read 복사 시간만.
            // (Windows 는 유휴 대기 포함 — #254 결정.)
            const t0 = perf.now();
            const n = posix.read(master_fd, &buf) catch break;
            perf.addTimedBytes(&perf.readloop, t0, @intCast(n));
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
    // deinit 의 SIGHUP fallback polling 이 검사하는 flag 를 exit_cb 보다 먼저
    // set (#129) — exit_cb 가 길게 걸려도 deinit 가 즉시 grace loop break.
    child_exited.store(true, .release);
    exit_cb(userdata);
}

// --- test — 실제 PTY roundtrip (POSIX 한정, 테스트 host 에서 실행) ---

const TestCollector = struct {
    var mu: std.Thread.Mutex = .{};
    var buf: [8192]u8 = undefined;
    var len: usize = 0;
    var exited = std.atomic.Value(bool).init(false);

    fn reset() void {
        mu.lock();
        defer mu.unlock();
        len = 0;
        exited.store(false, .release);
    }
    fn onRead(data: []const u8, _: ?*anyopaque) void {
        mu.lock();
        defer mu.unlock();
        const n = @min(data.len, buf.len - len);
        @memcpy(buf[len..][0..n], data[0..n]);
        len += n;
    }
    fn onExit(_: ?*anyopaque) void {
        exited.store(true, .release);
    }
    fn contains(needle: []const u8) bool {
        mu.lock();
        defer mu.unlock();
        return std.mem.indexOf(u8, buf[0..len], needle) != null;
    }
};

test "pty — /bin/sh spawn·echo 왕복·extra_env 우선·exit" {
    TestCollector.reset();

    // extra_env 의 SHELL 이 부모값을 override 하는지 (#118 정책) 함께 검증.
    const extra = [_]Pty.EnvVar{.{ .name = "SHELL", .value = "/tmp/tz-pty-test-sentinel" }};
    var pty = try Pty.init(std.testing.allocator, 80, 24, "/bin/sh", &extra, null);
    try pty.startReadThread(TestCollector.onRead, TestCollector.onExit, null);

    _ = try pty.write("echo pty_roundtrip_$SHELL\n");
    var waited_ms: u64 = 0;
    while (waited_ms < 5000) : (waited_ms += 20) {
        if (TestCollector.contains("pty_roundtrip_/tmp/tz-pty-test-sentinel")) break;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(TestCollector.contains("pty_roundtrip_/tmp/tz-pty-test-sentinel"));

    _ = try pty.write("exit\n");
    waited_ms = 0;
    while (waited_ms < 5000) : (waited_ms += 20) {
        if (TestCollector.exited.load(.acquire)) break;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(TestCollector.exited.load(.acquire));

    pty.deinit();
}

// `cwd` 를 넘겼을 때 셸이 정말 그 디렉토리에서 시작하는지, 그리고 그 경로로 갈 수
// 없을 때 홈으로 되돌아오는지 (#366 의 실패 방어) 를 실제 spawn 으로 확인한다.
//
// 비교 대상으로 `/` 를 쓰는 이유: macOS 의 `/tmp` 는 `/private/tmp` 심볼릭 링크라
// 셸의 `$PWD` (시작 시 `getcwd`, 물리 경로) 와 문자열이 어긋난다. `/` 는 어느 OS
// 에서도 링크가 아니다.
test "pty — cwd 지정 시 그 디렉토리에서 시작, 갈 수 없으면 홈 (#366)" {
    const waitFor = struct {
        fn f(needle: []const u8) bool {
            var waited_ms: u64 = 0;
            while (waited_ms < 5000) : (waited_ms += 20) {
                if (TestCollector.contains(needle)) return true;
                std.Thread.sleep(20 * std.time.ns_per_ms);
            }
            return false;
        }
    }.f;

    {
        TestCollector.reset();
        var pty = try Pty.init(std.testing.allocator, 80, 24, "/bin/sh", null, "/");
        defer pty.deinit();
        try pty.startReadThread(TestCollector.onRead, TestCollector.onExit, null);

        _ = try pty.write("[ \"$PWD\" = \"/\" ] && echo tz366_root_ok\n");
        try std.testing.expect(waitFor("tz366_root_ok"));
    }

    {
        TestCollector.reset();
        // 존재하지 않는 경로 — 호출자가 spawn 전에 확인하지만 그 사이에 지워지는
        // race 가 있고, 그때 앱의 현재 디렉토리를 물려받으면 #265 가 되살아난다.
        var pty = try Pty.init(
            std.testing.allocator,
            80,
            24,
            "/bin/sh",
            null,
            "/tz366-does-not-exist",
        );
        defer pty.deinit();
        try pty.startReadThread(TestCollector.onRead, TestCollector.onExit, null);

        // 현재 위치를 기억한 뒤 홈으로 이동해 같은 곳인지 본다 ($HOME 이 심볼릭
        // 링크여도 양쪽 모두 `getcwd` 결과라 문자열이 일치한다).
        _ = try pty.write("P=$PWD; cd \"$HOME\"; [ \"$P\" = \"$PWD\" ] && echo tz366_home_ok\n");
        try std.testing.expect(waitFor("tz366_home_ok"));
    }
}
