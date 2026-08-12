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
const Runtime = @import("../../runtime.zig").Runtime;

// #451 — Zig 0.16 이 `std.posix` 의 중간 추상화를 걷어냈다 (릴리즈 노트 *posix and
// os.windows removals*). 여기서 쓰던 `close` · `pipe2` · `fork` · `open` · `fcntl` ·
// `dup2` · `chdir` · `execve` · `poll` · `read` · `write` · `waitpid` · `exit` 가 전부
// 없어졌다. **`Io` 로 올릴 수 없다** — PTY master 는 파일이 아니라 터미널이고, 자식
// 프로세스 생성은 `fork` + `execve` 를 우리가 직접 해야 한다 (`std.process.spawn` 은
// setsid · TIOCSCTTY · login_tty 를 못 한다). 노트의 다른 길인 *"go lower: use
// `std.posix.system` directly"* 를 택했고, 그 대가로 errno 판정을 이 파일이 한다.
//
// `posix.kill` · `posix.tcgetattr` · `posix.tcsetattr` 는 **0.16 에도 남아 있어** 그대로 쓴다.

/// raw 반환값이 실패인지. `posix.errno` 가 `anytype` 이라 libc / 직접 syscall 두 구성에서
/// 같이 쓰인다 (`host/linux/single_instance.zig` 와 같은 헬퍼다).
fn sysFailed(rc: anytype) bool {
    return posix.errno(rc) != .SUCCESS;
}

fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

/// `std.Thread.sleep` 자리. 0.16 의 대체인 `Io.sleep` 은 `Io` 를 요구하고 취소점을
/// 만드는데, 이 자리들 (deinit 의 grace 폴링 · 테스트) 은 `Io` 가 없고 취소도 원하지
/// 않는다. 노트의 *"go lower"* 로 libc `nanosleep` 을 직접 부른다.
fn sleepNs(ns: u64) void {
    var ts: posix.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = posix.system.nanosleep(&ts, null);
}

/// `execve` 가 원하는 `KEY=VALUE` NUL-종단 배열. `std.process.createNullDelimitedEnvMap`
/// 이 0.16 에서 없어져 직접 만든다 — 메모리는 호출자의 arena 소유다.
fn buildEnvp(
    arena: std.mem.Allocator,
    map: *const std.process.Environ.Map,
) ![*:null]const ?[*:0]const u8 {
    const buf = try arena.allocSentinel(?[*:0]const u8, map.count(), null);
    for (map.keys(), map.values(), 0..) |k, v, i| {
        buf[i] = (try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ k, v }, 0)).ptr;
    }
    return buf.ptr;
}

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
        rt: Runtime,
        allocator: std.mem.Allocator,
        cols: u16,
        rows: u16,
        shell: []const u8,
        extra_env: ?[]const EnvVar,
        cwd: ?[]const u8,
    ) !Pty {
        const pair = try openPtyPair(cols, rows);
        errdefer closeFd(pair.master);
        errdefer closeFd(pair.slave);

        const shutdown_pipe = try openShutdownPipe();
        errdefer {
            closeFd(shutdown_pipe[0]);
            closeFd(shutdown_pipe[1]);
        }

        setIutf8(pair.slave);

        const shell_z = try allocator.dupeZ(u8, shell);
        defer allocator.free(shell_z);

        // 자식 환경 — 부모 environ 에 extra_env 를 *override* 로 머지 (map put).
        // POSIX getenv 가 first-match 라 부모의 같은 key (예: SHELL=/bin/bash)
        // 가 살아남으면 우리가 spawn 한 셸과 어긋나는 #118 문제 — extra 우선.
        // #451 — `std.process.getEnvMap` 이 없어졌다. 환경변수는 진입점이 준 `Environ` 에서
        // 온다 (릴리즈 노트 *Environment Variables … Become Non-Global*).
        var env_map = rt.environ.createMap(allocator) catch return error.EnvBuildFailed;
        defer env_map.deinit();
        if (extra_env) |vars| {
            for (vars) |v| {
                env_map.put(v.name, v.value) catch return error.EnvBuildFailed;
            }
        }

        var env_arena = std.heap.ArenaAllocator.init(allocator);
        defer env_arena.deinit();
        const envp = buildEnvp(env_arena.allocator(), &env_map) catch {
            return error.EnvBuildFailed;
        };

        // fork 후 자식은 allocator 를 쓸 수 없으니 (#366) 시작 디렉토리도 미리
        // NUL-term 으로 만들어 둔다 — `shell_z` 와 같은 패턴.
        const cwd_z: ?[:0]u8 = if (cwd) |dir|
            allocator.dupeZ(u8, dir) catch return error.EnvBuildFailed
        else
            null;
        defer if (cwd_z) |z| allocator.free(z);

        // fork 후 자식은 환경변수 조회도 할 수 없으니 (allocator 와 같은 이유) 홈 경로를
        // 미리 집는다. `Environ.getPosix` 는 이미 NUL-종단 slice 를 주고 그 메모리는
        // 프로세스 수명이라 복사가 필요 없다.
        const home_z: ?[*:0]const u8 = if (rt.environ.getPosix("HOME")) |h| h.ptr else null;

        const fork_rc = posix.system.fork();
        if (fork_rc < 0) return error.ForkFailed;
        const pid: posix.pid_t = @intCast(fork_rc);
        if (pid == 0) {
            childExec(
                pair.master,
                pair.slave,
                shell_z.ptr,
                envp,
                if (cwd_z) |z| z.ptr else null,
                home_z,
            );
        }

        closeFd(pair.slave);
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
                sleepNs(step_ms * std.time.ns_per_ms);
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
            _ = posix.system.write(self.shutdown_pipe[1], &[_]u8{1}, 1);
            t.join();
            self.read_thread = null;
        }

        closeFd(self.master_fd);
        closeFd(self.shutdown_pipe[0]);
        closeFd(self.shutdown_pipe[1]);
    }

    pub fn write(self: *Pty, data: []const u8) !usize {
        const rc = posix.system.write(self.master_fd, data.ptr, data.len);
        if (sysFailed(rc)) return switch (posix.errno(rc)) {
            // non-blocking master 가 가득 찬 것은 오류가 아니다 — 호출자가 다시 보낸다.
            .AGAIN => 0,
            else => error.WriteFailed,
        };
        return @intCast(rc);
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
        const master_rc = posix.system.open(
            "/dev/ptmx",
            .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true },
            @as(posix.mode_t, 0),
        );
        if (sysFailed(master_rc)) return error.OpenPtyFailed;
        const master_fd: posix.fd_t = @intCast(master_rc);
        errdefer closeFd(master_fd);

        if (unlockpt(master_fd) != 0) return error.UnlockPtyFailed;

        var slave_path_buf: [64]u8 = undefined;
        if (ptsname_r(master_fd, &slave_path_buf, slave_path_buf.len) != 0) {
            return error.ResolvePtySlaveFailed;
        }
        // ptsname_r 은 null-terminated 경로를 buf 에 기록 → C 문자열로 open.
        const slave_path: [*:0]const u8 = @ptrCast(&slave_path_buf);
        const slave_rc = posix.system.open(
            slave_path,
            .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true },
            @as(posix.mode_t, 0),
        );
        if (sysFailed(slave_rc)) return error.OpenPtyFailed;
        const slave_fd: posix.fd_t = @intCast(slave_rc);
        errdefer closeFd(slave_fd);

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

/// self-pipe 생성 (#223 — readLoop 의 poll 을 깨우는 통로).
///
/// #451 — 예전에는 `std.posix.pipe2` 가 **macOS 에서 `pipe` + `fcntl` 로 fallback** 해 줬다
/// (이 파일 헤더가 적어 둔 동작). 0.16 에서 그 wrapper 가 없어졌고 `std.c.pipe2` 는
/// Linux 계열에만 있어 (macOS 는 `else => {}` 로 `void`) 그 fallback 을 여기서 한다.
fn openShutdownPipe() !([2]posix.fd_t) {
    var fds: [2]posix.fd_t = undefined;
    if (builtin.os.tag == .linux) {
        if (sysFailed(posix.system.pipe2(&fds, .{ .CLOEXEC = true }))) return error.OpenPtyFailed;
    } else {
        if (sysFailed(posix.system.pipe(&fds))) return error.OpenPtyFailed;
        // `pipe` 는 CLOEXEC 없이 만든다 — Linux 경로와 같은 정책으로 맞춘다 (#282 D4).
        setCloexec(fds[0]);
        setCloexec(fds[1]);
    }
    return fds;
}

fn setCloexec(fd: posix.fd_t) void {
    const flags = posix.system.fcntl(fd, posix.F.GETFD, @as(usize, 0));
    if (sysFailed(flags)) return;
    _ = posix.system.fcntl(fd, posix.F.SETFD, @as(usize, @intCast(flags)) | posix.FD_CLOEXEC);
}

fn childExec(
    master_fd: posix.fd_t,
    slave_fd: posix.fd_t,
    shell: [*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    cwd: ?[*:0]const u8,
    /// 부모가 미리 집어 준 `$HOME`. fork 뒤에는 환경변수 조회도 못 한다.
    home: ?[*:0]const u8,
) noreturn {
    closeFd(master_fd);

    if (builtin.os.tag == .linux) {
        // 새 세션 + controlling terminal 등록 + stdio redirect 수동.
        if (linux.setsid() < 0) posix.system._exit(127);
        if (sysFailed(linux.ioctl(slave_fd, linux.T.IOCSCTTY, 0))) posix.system._exit(127);
        if (sysFailed(posix.system.dup2(slave_fd, 0))) posix.system._exit(127);
        if (sysFailed(posix.system.dup2(slave_fd, 1))) posix.system._exit(127);
        if (sysFailed(posix.system.dup2(slave_fd, 2))) posix.system._exit(127);
        if (slave_fd > 2) closeFd(slave_fd);
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
        if (sysFailed(posix.system.chdir(dir))) break :blk false;
        break :blk true;
    } else false;
    if (!moved) {
        if (home) |h| _ = posix.system.chdir(h);
    }

    // macOS 만 login shell (`-l`) — "Last login" + ~/.zprofile 로드,
    // Terminal.app 관례. Linux 터미널 관례는 비-login (#282 D5, SPEC §9).
    if (builtin.os.tag == .macos) {
        const argv = [_:null]?[*:0]const u8{ shell, "-l", null };
        _ = posix.system.execve(shell, &argv, envp);
        posix.system._exit(127);
    } else {
        const argv = [_:null]?[*:0]const u8{ shell, null };
        _ = posix.system.execve(shell, &argv, envp);
        posix.system._exit(127);
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
        if (sysFailed(posix.system.poll(&fds, fds.len, -1))) break;
        // #223 — deinit 이 self-pipe 로 깨움 (daemon 이 slave 를 쥐어 master 에
        // EOF 가 안 와도 read thread 안전 종료 → join deadlock 회피).
        if ((fds[1].revents & posix.POLL.IN) != 0) break;
        if ((fds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            // #160/#254 — poll 대기 (idle) 는 계측 밖, read 복사 시간만.
            // #394 로 **Windows 도 같은 범위**다 (`terminal/windows/pty.zig` 의 readLoop
            // 이 `ERROR_IO_PENDING` 대기를 계측 밖으로 뺐다). 다만 그쪽 pending 경로는
            // 커널이 대기 중에 복사를 끝내 우리가 잴 수 없어서 `ns` 만 빠지고
            // `calls` · `bytes` 는 남는다 — 같은 범위이되 Windows 가 과소 계상이다.
            const t0 = perf.now();
            const rc = posix.system.read(master_fd, &buf, buf.len);
            if (sysFailed(rc)) break;
            const n: usize = @intCast(rc);
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
    _ = posix.system.waitpid(child_pid, null, 0);
    // deinit 의 SIGHUP fallback polling 이 검사하는 flag 를 exit_cb 보다 먼저
    // set (#129) — exit_cb 가 길게 걸려도 deinit 가 즉시 grace loop break.
    child_exited.store(true, .release);
    exit_cb(userdata);
}

// --- test — 실제 PTY roundtrip (POSIX 한정, 테스트 host 에서 실행) ---

/// #451 — 0.16 은 `main` 밖에서 환경변수를 못 읽는다 (릴리즈 노트 *Environment Variables
/// and Process Arguments Become Non-Global*). 그래서 테스트는 **합성 `Environ`** 을 쓴다.
///
/// `HOME=/` 인 이유: 아래 #366 테스트가 "cwd 로 갈 수 없으면 홈" 을 검증하는데, 자식 셸의
/// `$HOME` 과 우리가 `chdir` 한 경로가 같아야 판정이 성립한다. `/` 는 어느 OS 에서도
/// 심볼릭 링크가 아니라 `getcwd` 결과와 문자열이 어긋나지 않는다.
fn testRuntime() Runtime {
    return .{
        .io = std.testing.io,
        .environ = .{ .block = .{ .slice = &[_:null]?[*:0]const u8{"HOME=/"} } },
    };
}

const TestCollector = struct {
    /// #451 — `Thread.Mutex` ➡️ `Io.Mutex` (릴리즈 노트 *Sync Primitives*). lock / unlock 이
    /// `Io` 를 받으므로 테스트용 `std.testing.io` 를 그대로 쓴다.
    var mu: std.Io.Mutex = .init;
    var buf: [8192]u8 = undefined;
    var len: usize = 0;
    var exited = std.atomic.Value(bool).init(false);

    fn reset() void {
        mu.lockUncancelable(std.testing.io);
        defer mu.unlock(std.testing.io);
        len = 0;
        exited.store(false, .release);
    }
    fn onRead(data: []const u8, _: ?*anyopaque) void {
        mu.lockUncancelable(std.testing.io);
        defer mu.unlock(std.testing.io);
        const n = @min(data.len, buf.len - len);
        @memcpy(buf[len..][0..n], data[0..n]);
        len += n;
    }
    fn onExit(_: ?*anyopaque) void {
        exited.store(true, .release);
    }
    fn contains(needle: []const u8) bool {
        mu.lockUncancelable(std.testing.io);
        defer mu.unlock(std.testing.io);
        return std.mem.find(u8, buf[0..len], needle) != null;
    }
};

test "pty — /bin/sh spawn·echo 왕복·extra_env 우선·exit" {
    TestCollector.reset();

    // extra_env 의 SHELL 이 부모값을 override 하는지 (#118 정책) 함께 검증.
    const extra = [_]Pty.EnvVar{.{ .name = "SHELL", .value = "/tmp/tz-pty-test-sentinel" }};
    var pty = try Pty.init(testRuntime(), std.testing.allocator, 80, 24, "/bin/sh", &extra, null);
    try pty.startReadThread(TestCollector.onRead, TestCollector.onExit, null);

    _ = try pty.write("echo pty_roundtrip_$SHELL\n");
    var waited_ms: u64 = 0;
    while (waited_ms < 5000) : (waited_ms += 20) {
        if (TestCollector.contains("pty_roundtrip_/tmp/tz-pty-test-sentinel")) break;
        sleepNs(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(TestCollector.contains("pty_roundtrip_/tmp/tz-pty-test-sentinel"));

    _ = try pty.write("exit\n");
    waited_ms = 0;
    while (waited_ms < 5000) : (waited_ms += 20) {
        if (TestCollector.exited.load(.acquire)) break;
        sleepNs(20 * std.time.ns_per_ms);
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
                sleepNs(20 * std.time.ns_per_ms);
            }
            return false;
        }
    }.f;

    {
        TestCollector.reset();
        var pty = try Pty.init(testRuntime(), std.testing.allocator, 80, 24, "/bin/sh", null, "/");
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
            testRuntime(),
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
