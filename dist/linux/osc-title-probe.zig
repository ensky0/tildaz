//! 셸이 첫 OSC 0/2 제목을 보내는 시점 실측 도구 ([#364](https://github.com/ensky0/tildaz/issues/364)).
//!
//! **Linux 전용이다** (POSIX PTY + `/dev/ptmx`). Windows 는 ConPTY 라 별도 도구가
//! 필요하다 — 같은 방법론을 Windows 에서 재현하는 지침은
//! `dist/windows/osc-title-probe-prompt.md` 에 있다.
//!
//! 왜 필요한가: `src/session_core.zig` 의 `INITIAL_TITLE_GRACE_NS` (1 초) 를 줄여도
//! 되는지는 **셸이 실제로 언제 OSC 를 보내는지**에 달려 있다. 이 도구는 tildaz 가
//! 자식 셸을 띄우는 조건을 그대로 복제해서 그 시점을 µs 해상도로 측정한다.
//!
//! tildaz 와 같게 맞춘 것 (`src/terminal/posix/pty.zig` 의 Linux 경로):
//!   - `/dev/ptmx` + `unlockpt` + `ptsname_r` + slave `O_RDWR|O_NOCTTY|O_CLOEXEC`
//!   - slave termios `IUTF8` on
//!   - child: `setsid` → `TIOCSCTTY` → `dup2(0/1/2)` → `chdir($HOME)` → `execve`
//!   - argv = `{ shell }` — Linux 는 login shell (`-l`) 이 아니다 (#282 D5)
//!   - env = 부모 environ + override `TERM=xterm-256color` / `LANG=C.UTF-8` /
//!     `LC_CTYPE=C.UTF-8` / `COLORFGBG` / `SHELL=<shell>`
//!   - 시각 0 = `fork` 직후 (tildaz 의 `Tab.title_clock` 이 시작하는 지점)
//!   - 터미널 질의 응답 = ghostty-vt 가 실제로 보내는 값 (#266). fish 는 DA1 응답을
//!     기다리므로 이게 없으면 측정값이 수 초 왜곡된다.
//!
//! 빌드 / 실행 (본체 빌드에는 들어가지 않고 `zig build probe-check`가 호환만 확인):
//! ```sh
//! zig build-exe dist/linux/osc-title-probe.zig -O ReleaseSafe -lc
//! ./osc-title-probe --shell /bin/bash --runs 10 --verbose
//! ./osc-title-probe --shell /usr/bin/fish --runs 10 --no-reply   # 질의 응답 없이 비교
//! ./osc-title-probe --shell /usr/bin/zsh --runs 5 --home /tmp/empty  # 사용자 rc 없는 셸
//! ```
//!
//! 인자: `--shell PATH` `--runs N` `--window-ms N` `--home PATH` `--label TEXT`
//! `--no-reply` (터미널 질의에 응답하지 않음) `--verbose` (run 별 timeline).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

comptime {
    if (builtin.os.tag != .linux) {
        @compileError("osc-title-probe 는 Linux 전용 (POSIX PTY). Windows 는 ConPTY 용 별도 도구가 필요하다.");
    }
}

extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, buflen: usize) c_int;

/// Zig 0.16이 걷어낸 `std.posix` syscall wrapper 자리. 이 도구는 PTY의
/// `fork`/`setsid`/`TIOCSCTTY`가 필요해 `std.process.spawn`으로 올릴 수 없으므로
/// 앱의 POSIX PTY와 같이 `std.posix.system`으로 내려간다.
fn sysFailed(rc: anytype) bool {
    return posix.errno(rc) != .SUCCESS;
}

fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

/// XTVERSION 응답에 쓰는 값 — tildaz 의 `vtXtversion` 과 같은 형식.
const app_version = "0.6.2";
/// Tilda 테마 (config 기본값) 의 fg / bg — OSC 10 / 11 질의 응답에 쓴다.
const theme_fg = "rgb:ffff/ffff/ffff";
const theme_bg = "rgb:0000/0000/0000";
/// dark 배경 → `COLORFGBG=15;0`, color scheme DSR 응답은 `\e[?997;1n` (dark).
const colorfgbg = "15;0";

/// Zig 0.16에서 제거된 `std.time.Timer`의 자리. 측정 구간은 절전 시간을 세지 않는
/// `.awake` 단조 시계를 써서 tildaz의 `runtime.Timer`와 같은 의미를 유지한다.
const Timer = struct {
    io: std.Io,
    start_ns: i96,

    fn start(io: std.Io) Timer {
        return .{ .io = io, .start_ns = std.Io.Timestamp.now(io, .awake).nanoseconds };
    }

    fn read(self: Timer) u64 {
        const now = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        return @intCast(@max(0, now - self.start_ns));
    }
};

const Kind = enum {
    title, // OSC 0 / 2 (ghostty getTitle() 에 반영되는 것)
    icon, // OSC 1 (제목 아님 — 참고용)
    answered, // 터미널 질의 + 우리가 ghostty-vt 와 같은 응답을 보냈다
    ignored, // 터미널 질의인데 tildaz 도 응답하지 않는 것 (또는 미구현)
};

const Event = struct {
    t_ns: u64 = 0,
    kind: Kind = .title,
    text: [160]u8 = undefined,
    text_len: usize = 0,

    fn str(self: *const Event) []const u8 {
        return self.text[0..self.text_len];
    }
};

const Recorder = struct {
    events: [768]Event = undefined,
    count: usize = 0,
    dropped: usize = 0,
    master: posix.fd_t = -1,
    timer: Timer = undefined,
    reply: bool = true,
    total_bytes: usize = 0,

    fn add(self: *Recorder, kind: Kind, text: []const u8) void {
        if (self.count >= self.events.len) {
            self.dropped += 1;
            return;
        }
        const e = &self.events[self.count];
        e.* = .{ .t_ns = self.timer.read(), .kind = kind };
        e.text_len = @min(text.len, e.text.len);
        @memcpy(e.text[0..e.text_len], text[0..e.text_len]);
        self.count += 1;
    }

    fn respond(self: *Recorder, data: []const u8) void {
        if (!self.reply) return;
        _ = posix.system.write(self.master, data.ptr, data.len);
    }
};

// ── 파서 — OSC / CSI / DCS 만 구분한다. 화면 내용은 관심 없다. ───────────────

const Parser = struct {
    const State = enum { ground, esc, csi, str };
    const StrKind = enum { osc, dcs, other };

    state: State = .ground,
    str_kind: StrKind = .osc,
    in_esc: bool = false,
    buf: [512]u8 = undefined,
    len: usize = 0,

    fn push(self: *Parser, b: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = b;
            self.len += 1;
        }
    }

    fn feed(self: *Parser, rec: *Recorder, data: []const u8) void {
        for (data) |b| self.byte(rec, b);
    }

    fn byte(self: *Parser, rec: *Recorder, b: u8) void {
        switch (self.state) {
            .ground => if (b == 0x1b) {
                self.state = .esc;
            },
            .esc => {
                self.len = 0;
                self.in_esc = false;
                switch (b) {
                    ']' => {
                        self.state = .str;
                        self.str_kind = .osc;
                    },
                    '[' => self.state = .csi,
                    'P' => {
                        self.state = .str;
                        self.str_kind = .dcs;
                    },
                    '_', '^', 'X' => {
                        self.state = .str;
                        self.str_kind = .other;
                    },
                    0x1b => self.state = .esc,
                    else => self.state = .ground,
                }
            },
            .csi => {
                if (b >= 0x40 and b <= 0x7e) {
                    self.push(b);
                    self.dispatchCsi(rec);
                    self.state = .ground;
                    self.len = 0;
                } else self.push(b);
            },
            .str => {
                if (self.in_esc) {
                    self.in_esc = false;
                    if (b == '\\') { // ST
                        self.dispatchStr(rec);
                        self.state = .ground;
                        self.len = 0;
                        return;
                    }
                    self.push(0x1b);
                    self.push(b);
                    return;
                }
                if (b == 0x1b) {
                    self.in_esc = true;
                    return;
                }
                if (b == 0x07 and self.str_kind == .osc) { // BEL
                    self.dispatchStr(rec);
                    self.state = .ground;
                    self.len = 0;
                    return;
                }
                self.push(b);
            },
        }
    }

    fn dispatchStr(self: *Parser, rec: *Recorder) void {
        const s = self.buf[0..self.len];
        switch (self.str_kind) {
            .osc => self.dispatchOsc(rec, s),
            .dcs => {
                // XTGETTCAP (`DCS + q <hex> ST`) — 셸이 terminfo capability 를
                // 물어보는 경우. tildaz 가 실제로 답하는지는 ghostty-vt 내부 —
                // 여기서는 응답하지 않고 기록만 한다 (응답 대기로 시점이 밀리면
                // timeline 에 그대로 드러난다).
                var line: [180]u8 = undefined;
                const n = render(&line, "DCS ", s);
                rec.add(.ignored, line[0..n]);
            },
            .other => {},
        }
    }

    fn dispatchOsc(self: *Parser, rec: *Recorder, s: []const u8) void {
        _ = self;
        const semi = std.mem.indexOfScalar(u8, s, ';');
        const code_str = if (semi) |i| s[0..i] else s;
        const payload = if (semi) |i| s[i + 1 ..] else "";
        const code = std.fmt.parseInt(u32, code_str, 10) catch return;

        switch (code) {
            0, 2 => {
                var line: [180]u8 = undefined;
                const n = (std.fmt.bufPrint(&line, "OSC {d} title=\"{s}\"", .{ code, payload }) catch @as([]u8, line[0..0])).len;
                rec.add(.title, line[0..n]);
            },
            1 => {
                var line: [180]u8 = undefined;
                const n = (std.fmt.bufPrint(&line, "OSC 1 icon=\"{s}\"", .{payload}) catch @as([]u8, line[0..0])).len;
                rec.add(.icon, line[0..n]);
            },
            // 색 질의 — ghostty-vt 가 terminal 의 현재 색으로 답한다.
            10, 11, 12 => {
                if (std.mem.eql(u8, payload, "?")) {
                    const color = if (code == 11) theme_bg else theme_fg;
                    var out: [64]u8 = undefined;
                    const resp = std.fmt.bufPrint(&out, "\x1b]{d};{s}\x1b\\", .{ code, color }) catch return;
                    rec.respond(resp);
                    var line: [180]u8 = undefined;
                    const n = (std.fmt.bufPrint(&line, "OSC {d} color query -> {s}", .{ code, color }) catch @as([]u8, line[0..0])).len;
                    rec.add(.answered, line[0..n]);
                }
            },
            4 => {
                // OSC 4 ; n ; ? — palette 질의. 값은 테마 palette 이지만 시점
                // 측정에는 무관하므로 회색으로 답하고 기록한다.
                if (std.mem.endsWith(u8, payload, "?")) {
                    const idx_end = std.mem.indexOfScalar(u8, payload, ';') orelse return;
                    var out: [64]u8 = undefined;
                    const resp = std.fmt.bufPrint(
                        &out,
                        "\x1b]4;{s};rgb:8080/8080/8080\x1b\\",
                        .{payload[0..idx_end]},
                    ) catch return;
                    rec.respond(resp);
                    var line: [180]u8 = undefined;
                    const n = (std.fmt.bufPrint(&line, "OSC 4;{s} palette query -> answered", .{payload[0..idx_end]}) catch @as([]u8, line[0..0])).len;
                    rec.add(.answered, line[0..n]);
                }
            },
            else => {}, // OSC 7 (cwd) / 8 (hyperlink) / 133 (prompt mark) 등 — 제목 무관
        }
    }

    fn dispatchCsi(self: *Parser, rec: *Recorder) void {
        const s = self.buf[0..self.len];
        if (s.len == 0) return;
        const final = s[s.len - 1];
        var body = s[0 .. s.len - 1];

        var private: u8 = 0;
        if (body.len > 0 and (body[0] == '?' or body[0] == '>' or body[0] == '=' or body[0] == '<')) {
            private = body[0];
            body = body[1..];
        }
        var intermediate: u8 = 0;
        if (body.len > 0 and (body[body.len - 1] == '$' or body[body.len - 1] == ' ' or body[body.len - 1] == '!')) {
            intermediate = body[body.len - 1];
            body = body[0 .. body.len - 1];
        }
        const first_param = std.fmt.parseInt(u32, firstParam(body), 10) catch 0;

        var line: [180]u8 = undefined;
        switch (final) {
            // DA1 / DA2 / DA3 — tildaz 는 ghostty-vt 기본값을 그대로 쓴다 (#266).
            'c' => {
                const resp = switch (private) {
                    '>' => "\x1b[>1;0;0c", // DA2
                    '=' => "\x1bP!|00000000\x1b\\", // DA3
                    else => "\x1b[?62;22c", // DA1
                };
                rec.respond(resp);
                const n = render(&line, "CSI ", s);
                rec.add(.answered, line[0..n]);
            },
            'n' => { // DSR
                if (private == '?' and first_param == 996) {
                    rec.respond("\x1b[?997;1n"); // dark
                } else if (private == 0 and first_param == 5) {
                    rec.respond("\x1b[0n");
                } else if (first_param == 6) {
                    rec.respond(if (private == '?') "\x1b[?1;1R" else "\x1b[1;1R");
                } else {
                    const n = render(&line, "CSI ", s);
                    rec.add(.ignored, line[0..n]);
                    return;
                }
                const n = render(&line, "CSI ", s);
                rec.add(.answered, line[0..n]);
            },
            'u' => {
                if (private == '?') { // kitty keyboard 질의
                    rec.respond("\x1b[?0u");
                    const n = render(&line, "CSI ", s);
                    rec.add(.answered, line[0..n]);
                }
            },
            'q' => {
                if (private == '>') { // XTVERSION
                    rec.respond("\x1bP>|tildaz " ++ app_version ++ "\x1b\\");
                    const n = render(&line, "CSI ", s);
                    rec.add(.answered, line[0..n]);
                }
            },
            'p' => {
                if (private == '?' and intermediate == '$') { // DECRQM
                    var out: [32]u8 = undefined;
                    // 2027 (grapheme cluster) 은 tildaz 가 켠다 → set(1).
                    // 나머지는 recognized-but-reset(2) 로 답한다 (근사).
                    const value: u8 = if (first_param == 2027) 1 else 2;
                    const resp = std.fmt.bufPrint(&out, "\x1b[?{d};{d}$y", .{ first_param, value }) catch return;
                    rec.respond(resp);
                    const n = render(&line, "CSI ", s);
                    rec.add(.answered, line[0..n]);
                }
            },
            't', 'S' => { // XTWINOPS / XTSMGRAPHICS — tildaz 는 응답하지 않는다
                const n = render(&line, "CSI ", s);
                rec.add(.ignored, line[0..n]);
            },
            else => {},
        }
    }
};

fn firstParam(body: []const u8) []const u8 {
    const semi = std.mem.indexOfScalar(u8, body, ';') orelse return body;
    return body[0..semi];
}

/// 제어 시퀀스를 읽을 수 있는 문자열로. ESC 는 `\e`, 나머지 비출력 문자는 `\xNN`.
fn render(out: []u8, prefix: []const u8, s: []const u8) usize {
    var n: usize = 0;
    for (prefix) |c| {
        if (n < out.len) {
            out[n] = c;
            n += 1;
        }
    }
    for (s) |c| {
        if (c >= 0x20 and c < 0x7f) {
            if (n < out.len) {
                out[n] = c;
                n += 1;
            }
        } else {
            const hex = std.fmt.bufPrint(out[n..], "\\x{x:0>2}", .{c}) catch break;
            n += hex.len;
        }
    }
    return n;
}

// ── PTY spawn — tildaz 의 Linux 경로와 동일 ────────────────────────────────

const Spawn = struct { master: posix.fd_t, pid: posix.pid_t };

/// `execve`가 받는 `KEY=VALUE` NUL-종단 배열. Zig 0.16에서는 부모 환경을
/// `std.process.Init`의 `Environ`에서 받아 명시적으로 만든다.
fn buildEnvp(
    arena: std.mem.Allocator,
    map: *const std.process.Environ.Map,
) ![*:null]const ?[*:0]const u8 {
    const buf = try arena.allocSentinel(?[*:0]const u8, map.count(), null);
    for (map.keys(), map.values(), 0..) |key, value, i| {
        buf[i] = (try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ key, value }, 0)).ptr;
    }
    return buf.ptr;
}

fn spawnShell(
    alloc: std.mem.Allocator,
    environ: std.process.Environ,
    shell: []const u8,
    cols: u16,
    rows: u16,
    home_override: ?[]const u8,
) !Spawn {
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
    if (ptsname_r(master_fd, &slave_path_buf, slave_path_buf.len) != 0) return error.ResolvePtySlaveFailed;
    const slave_path: [*:0]const u8 = @ptrCast(&slave_path_buf);
    const slave_rc = posix.system.open(
        slave_path,
        .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true },
        @as(posix.mode_t, 0),
    );
    if (sysFailed(slave_rc)) return error.OpenPtyFailed;
    const slave_fd: posix.fd_t = @intCast(slave_rc);
    errdefer closeFd(slave_fd);

    var ws: posix.winsize = .{ .col = cols, .row = rows, .xpixel = 0, .ypixel = 0 };
    if (posix.errno(linux.ioctl(slave_fd, linux.T.IOCSWINSZ, @intFromPtr(&ws))) != .SUCCESS) {
        return error.ResizeFailed;
    }

    // IUTF8 — tildaz 의 setIutf8 과 동일.
    if (posix.tcgetattr(slave_fd)) |tio_const| {
        var tio = tio_const;
        tio.iflag.IUTF8 = true;
        posix.tcsetattr(slave_fd, .NOW, tio) catch {};
    } else |_| {}

    const shell_z = try alloc.dupeZ(u8, shell);
    defer alloc.free(shell_z);

    var env_map = try environ.createMap(alloc);
    defer env_map.deinit();
    // tildaz 가 Linux 에서 넘기는 5종 (wayland_minimal.zig `extra_env_storage`).
    try env_map.put("TERM", "xterm-256color");
    try env_map.put("LANG", "C.UTF-8");
    try env_map.put("LC_CTYPE", "C.UTF-8");
    try env_map.put("COLORFGBG", colorfgbg);
    try env_map.put("SHELL", shell);
    if (home_override) |h| try env_map.put("HOME", h);
    // 측정 프로세스 (agent 셸) 에서 흘러들어온 흔적은 제거 — 데스크톱 세션에서
    // 실행되는 tildaz 의 환경에는 없는 값이다.
    _ = env_map.swapRemove("CLAUDECODE");
    _ = env_map.swapRemove("CLAUDE_CODE_ENTRYPOINT");

    var env_arena = std.heap.ArenaAllocator.init(alloc);
    defer env_arena.deinit();
    const envp = try buildEnvp(env_arena.allocator(), &env_map);

    const home_z_owned: ?[:0]u8 = if (home_override) |h| try alloc.dupeZ(u8, h) else null;
    defer if (home_z_owned) |h| alloc.free(h);
    // fork 뒤에는 환경 조회나 할당을 하지 않는다. 부모의 환경 블록은 프로세스 수명이고
    // `getPosix` 반환값은 이미 NUL-종단이라 그대로 `chdir`에 쓸 수 있다.
    const home_z: ?[*:0]const u8 = if (home_z_owned) |h|
        h.ptr
    else if (environ.getPosix("HOME")) |h|
        h.ptr
    else
        null;

    const fork_rc = posix.system.fork();
    if (sysFailed(fork_rc)) return error.ForkFailed;
    const pid: posix.pid_t = @intCast(fork_rc);
    if (pid == 0) {
        closeFd(master_fd);
        if (linux.setsid() < 0) posix.system._exit(127);
        if (sysFailed(linux.ioctl(slave_fd, linux.T.IOCSCTTY, 0))) posix.system._exit(127);
        if (sysFailed(posix.system.dup2(slave_fd, 0))) posix.system._exit(127);
        if (sysFailed(posix.system.dup2(slave_fd, 1))) posix.system._exit(127);
        if (sysFailed(posix.system.dup2(slave_fd, 2))) posix.system._exit(127);
        if (slave_fd > 2) closeFd(slave_fd);
        if (home_z) |home| _ = posix.system.chdir(home);
        const argv = [_:null]?[*:0]const u8{ shell_z.ptr, null };
        _ = posix.system.execve(shell_z.ptr, &argv, envp);
        posix.system._exit(127);
    }

    closeFd(slave_fd);
    return .{ .master = master_fd, .pid = pid };
}

// ── 한 번의 측정 ──────────────────────────────────────────────────────────

const RunResult = struct {
    /// 첫 출력 byte 시각 — 사용자가 프롬프트를 보기 시작하는 시점의 대용값.
    /// 제목만 늦는 건지 (= 빈 제목이 눈에 띈다) 셸 자체가 늦는 건지 구분한다.
    first_byte_ns: ?u64 = null,
    first_title_ns: ?u64 = null,
    first_nonempty_ns: ?u64 = null,
    last_title_ns: ?u64 = null,
    titles: usize = 0,
    distinct_titles: usize = 0,
    queries: usize = 0,
    ignored_queries: usize = 0,
    bytes: usize = 0,
};

fn runOnce(
    io: std.Io,
    environ: std.process.Environ,
    alloc: std.mem.Allocator,
    shell: []const u8,
    window_ms: u64,
    reply: bool,
    home_override: ?[]const u8,
    verbose: bool,
) !RunResult {
    const sp = try spawnShell(alloc, environ, shell, 120, 30, home_override);
    // 시각 0 — tildaz 는 backend.init (fork) 직후 title_clock 을 시작한다.
    var rec = Recorder{ .master = sp.master, .timer = .start(io), .reply = reply };
    var parser = Parser{};

    var buf: [8192]u8 = undefined;
    var first_byte_ns: ?u64 = null;
    while (true) {
        const elapsed_ms = rec.timer.read() / std.time.ns_per_ms;
        if (elapsed_ms >= window_ms) break;
        var fds = [_]posix.pollfd{.{ .fd = sp.master, .events = posix.POLL.IN, .revents = 0 }};
        const ready_rc = posix.system.poll(&fds, fds.len, @intCast(window_ms - elapsed_ms));
        if (sysFailed(ready_rc)) break;
        const ready: usize = @intCast(ready_rc);
        if (ready == 0) continue;
        if (fds[0].revents & (posix.POLL.IN | posix.POLL.HUP) == 0) continue;
        const read_rc = posix.system.read(sp.master, &buf, buf.len);
        if (sysFailed(read_rc)) break;
        const n: usize = @intCast(read_rc);
        if (n == 0) break; // EOF — 셸 종료
        if (first_byte_ns == null) first_byte_ns = rec.timer.read();
        rec.total_bytes += n;
        parser.feed(&rec, buf[0..n]);
    }

    posix.kill(-sp.pid, posix.SIG.KILL) catch {};
    _ = posix.system.waitpid(sp.pid, null, 0);
    closeFd(sp.master);

    // 결과 집계
    var result = RunResult{ .bytes = rec.total_bytes, .first_byte_ns = first_byte_ns };
    var last_title: [160]u8 = undefined;
    var last_title_len: usize = 0;
    for (rec.events[0..rec.count]) |e| {
        switch (e.kind) {
            .title => {
                const payload = titlePayload(e.str());
                result.titles += 1;
                if (result.first_title_ns == null) result.first_title_ns = e.t_ns;
                if (payload.len > 0 and result.first_nonempty_ns == null) result.first_nonempty_ns = e.t_ns;
                if (payload.len > 0) result.last_title_ns = e.t_ns;
                if (!std.mem.eql(u8, last_title[0..last_title_len], payload)) {
                    result.distinct_titles += 1;
                    last_title_len = @min(payload.len, last_title.len);
                    @memcpy(last_title[0..last_title_len], payload[0..last_title_len]);
                }
            },
            .icon => {},
            .answered => result.queries += 1,
            .ignored => {
                result.queries += 1;
                result.ignored_queries += 1;
            },
        }
    }

    if (verbose) {
        for (rec.events[0..rec.count]) |e| {
            const tag = switch (e.kind) {
                .title => "TITLE  ",
                .icon => "icon   ",
                .answered => "query→ ",
                .ignored => "query✗ ",
            };
            std.debug.print("    [{d:>8.3} ms] {s} {s}\n", .{
                @as(f64, @floatFromInt(e.t_ns)) / @as(f64, std.time.ns_per_ms),
                tag,
                e.str(),
            });
        }
        if (rec.dropped > 0) std.debug.print("    (event buffer overflow: {d} dropped)\n", .{rec.dropped});
    }

    return result;
}

/// `OSC 0 title="..."` 형태에서 제목만 뽑는다.
fn titlePayload(line: []const u8) []const u8 {
    const start = std.mem.indexOfScalar(u8, line, '"') orelse return "";
    const end = std.mem.lastIndexOfScalar(u8, line, '"') orelse return "";
    if (end <= start) return "";
    return line[start + 1 .. end];
}

fn median(values: []u64) u64 {
    if (values.len == 0) return 0;
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[values.len / 2];
}

fn ms(v: u64) f64 {
    return @as(f64, @floatFromInt(v)) / @as(f64, std.time.ns_per_ms);
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    var shell: []const u8 = "/bin/bash";
    var runs: usize = 10;
    var window_ms: u64 = 3000;
    var reply = true;
    var verbose = false;
    var home_override: ?[]const u8 = null;
    var label: []const u8 = "";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--shell") and i + 1 < args.len) {
            i += 1;
            shell = args[i];
        } else if (std.mem.eql(u8, a, "--runs") and i + 1 < args.len) {
            i += 1;
            runs = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "--window-ms") and i + 1 < args.len) {
            i += 1;
            window_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--home") and i + 1 < args.len) {
            i += 1;
            home_override = args[i];
        } else if (std.mem.eql(u8, a, "--label") and i + 1 < args.len) {
            i += 1;
            label = args[i];
        } else if (std.mem.eql(u8, a, "--no-reply")) {
            reply = false;
        } else if (std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        } else {
            std.debug.print("알 수 없는 인자: {s}\n", .{a});
            return error.InvalidArgs;
        }
    }

    std.debug.print("== OSC 제목 도착 시각 실측 (#364) ==\n", .{});
    std.debug.print("shell={s} runs={d} window={d}ms query_reply={s} home={s} {s}\n\n", .{
        shell,
        runs,
        window_ms,
        if (reply) "on(ghostty-vt 동등)" else "off",
        home_override orelse "(그대로)",
        label,
    });

    const firsts = try alloc.alloc(u64, runs);
    var firsts_len: usize = 0;
    const lasts = try alloc.alloc(u64, runs);
    var lasts_len: usize = 0;
    const bytes_first = try alloc.alloc(u64, runs);
    var bytes_first_len: usize = 0;
    var no_title_runs: usize = 0;

    for (0..runs) |run| {
        if (verbose) std.debug.print("  run {d}:\n", .{run + 1});
        const r = try runOnce(init.io, init.minimal.environ, alloc, shell, window_ms, reply, home_override, verbose);
        if (r.first_nonempty_ns) |t| {
            firsts[firsts_len] = t;
            firsts_len += 1;
            if (r.last_title_ns) |l| {
                lasts[lasts_len] = l;
                lasts_len += 1;
            }
            const fb = r.first_byte_ns orelse 0;
            bytes_first[bytes_first_len] = fb;
            bytes_first_len += 1;
            std.debug.print(
                "  run {d:>2}: 첫 출력 {d:>7.2} ms | 첫 제목 {d:>8.2} ms | 제목 공백 {d:>8.2} ms | 마지막 제목 {d:>8.2} ms | 제목 {d}회(구별 {d}) | 질의 {d}(무응답 {d}) | {d} bytes\n",
                .{ run + 1, ms(fb), ms(t), ms(t -| fb), ms(r.last_title_ns orelse t), r.titles, r.distinct_titles, r.queries, r.ignored_queries, r.bytes },
            );
        } else {
            no_title_runs += 1;
            std.debug.print(
                "  run {d:>2}: 제목 없음 ({d}ms 동안 OSC 0/2 미수신) | 질의 {d}(무응답 {d}) | {d} bytes\n",
                .{ run + 1, window_ms, r.queries, r.ignored_queries, r.bytes },
            );
        }
    }

    std.debug.print("\n", .{});
    if (firsts_len == 0) {
        std.debug.print("결과: OSC 0/2 제목을 한 번도 보내지 않았다 ({d}/{d} run). → fallback (`Tab N`) 경로.\n", .{ no_title_runs, runs });
        return;
    }

    const f = firsts[0..firsts_len];
    var min_v: u64 = std.math.maxInt(u64);
    var max_v: u64 = 0;
    var sum: u64 = 0;
    for (f) |v| {
        min_v = @min(min_v, v);
        max_v = @max(max_v, v);
        sum += v;
    }
    const med = median(f);

    std.debug.print("첫 non-empty OSC 제목 (fork 기준):\n", .{});
    std.debug.print("  min {d:.2} ms | median {d:.2} ms | mean {d:.2} ms | max {d:.2} ms  (n={d})\n", .{
        ms(min_v), ms(med), ms(sum / firsts_len), ms(max_v), firsts_len,
    });
    if (lasts_len > 0) {
        const l = lasts[0..lasts_len];
        var lmax: u64 = 0;
        for (l) |v| lmax = @max(lmax, v);
        std.debug.print("  마지막 제목 갱신 max {d:.2} ms (150ms debounce 안정화 시점 판단용)\n", .{ms(lmax)});
    }
    if (no_title_runs > 0) {
        std.debug.print("  제목 없음: {d}/{d} run\n", .{ no_title_runs, runs });
    }

    std.debug.print("\n유예 후보별 판정 (첫 제목이 유예보다 늦으면 `Tab N` 이 먼저 보이고 교체됨):\n", .{});
    for ([_]u64{ 1000, 500, 300, 250, 200, 150, 100 }) |cand_ms| {
        const cand_ns = cand_ms * std.time.ns_per_ms;
        var late: usize = 0;
        for (f) |v| {
            if (v > cand_ns) late += 1;
        }
        std.debug.print("  {d:>4} ms 유예: 늦은 run {d}/{d} | 여유 (유예 - max) {d:.2} ms\n", .{
            cand_ms, late, firsts_len, @as(f64, @floatFromInt(cand_ms)) - ms(max_v),
        });
    }
}
