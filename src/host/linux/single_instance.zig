//! #198 — Linux desktop/compositor에서 `tildaz --toggle` CLI를 통한
//! hide/show toggle. 사용자가 자기 DE의
//! keyboard shortcut 설정 (KDE Plasma System Settings, GNOME Settings, sway
//! config 등) 에서 `tildaz --toggle` 명령 등록 → 그 단축키가 두 번째 tildaz
//! 인스턴스 시작 → 우리는 Unix domain socket 으로 첫 인스턴스에 신호 + exit.
//!
//! worker N은 시작 시 `$XDG_RUNTIME_DIR/<name>/run/instanceN.sock` listen. `--toggle N` process는
//! 해당 socket에 connect + 1 byte ('T') 송신 + exit. worker N의 main loop가
//! accept + read → 공통 `handleActivatedToggle` 경로로 hide/show.
//!
//! DE별 global hotkey backend와 공존 — hotkey와 `tildaz --toggle` 모두 같은
//! `handleActivatedToggle` 경로로 수렴한다.
//! 에선 둘 다 trigger 가능. fallback 안 함, 둘 다 active.
//!
//! ## Zig 0.16 — 왜 `std.posix.system` 인가 ([#451](https://github.com/ensky0/tildaz/issues/451))
//!
//! 배관과 그 근거는 [`unix_socket.zig`](unix_socket.zig) 에 있다 (`wayland_minimal.zig`
//! 과 공유한다). 이 파일 몫의 이유만 적으면:
//!
//! **위로 (`Io.net`) 갈 수 없는 이유는 non-blocking accept 다.** 우리 `acceptCommand` 는
//! Wayland poll 루프가 "읽을 게 있다" 고 할 때 불리고 `WouldBlock` 을 **정상 흐름**으로
//! 쓴다 (spurious wakeup 이면 그냥 돌아간다). 그런데 `netAcceptPosix` 는 `EAGAIN` 을
//! `errnoBug` 로 넘기고 그것은 debug 빌드에서 panic 이다. 위로 올리면 메인 루프가 통째로
//! 블록되거나 패닉한다.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const app_id = @import("../../app_id.zig");
const unix_socket = @import("unix_socket.zig");
const checkErr = unix_socket.checkErr;
const unixAddress = unix_socket.unixAddress;
const openSocket = unix_socket.openSocket;
const closeFd = unix_socket.closeFd;
const Runtime = @import("../../runtime.zig").Runtime;
const log = @import("../../log.zig");
const instance_context = @import("../../instance_context.zig");

/// 1 byte command — `T` (toggle). 확장 시 다른 byte 추가 (예: `Q` quit).
pub const cmd_toggle: u8 = 'T';
pub const cmd_new_instance: u8 = 'N';

pub const Command = enum { toggle, new_instance };

/// Socket path. `$XDG_RUNTIME_DIR/<name>/run/instanceN.sock` (정상 표준) 또는
/// fallback `/tmp/<name>-<uid>-N.sock`. `$XDG_RUNTIME_DIR` 는 systemd / elogind
/// 가 user session 마다 설정 (`/run/user/<uid>`) — 거의 모든 모던 Linux
/// 데스크탑 환경 보장.
///
/// **`paths.lockDir` 과 같은 디렉터리에 둔다** ([#654](https://github.com/ensky0/tildaz/issues/654) ⓒ).
/// 예전에는 lock 이 `$XDG_RUNTIME_DIR/tildaz/` 안인데 소켓만 그 **형제**인
/// `$XDG_RUNTIME_DIR/tildaz-N.sock` 이라, 같은 인스턴스의 흔적이 두 자리로 흩어졌다.
/// 이름도 `app_id.name` 을 타므로 개발 빌드와 릴리즈가 서로의 인스턴스를 잡지 않는다 —
/// 안 갈리면 launcher 가 엉뚱한 인스턴스에 toggle 을 보낸다.
///
/// `sun_path` 는 108 바이트다. 가장 긴 조합이 `/run/user/<uid>/tildaz-dev/run/instanceN.sock`
/// 로 45 자 남짓이라 여유가 크다 (`unixAddress` 가 초과를 잡는다).
///
/// #451 — `std.posix.getenv` 가 없어졌다. `Environ.getPosix` 가 그 자리이고, POSIX 에서는
/// 블록을 그대로 훑어 **할당이 없다** — 이 함수가 고정 버퍼만 쓰는 성질이 유지된다.
fn socketPath(rt: Runtime, buf: []u8, index: u32) ![:0]const u8 {
    if (rt.environ.getPosix("XDG_RUNTIME_DIR")) |runtime_dir| {
        return std.fmt.bufPrintSentinel(buf, "{s}/{s}/run/instance{d}.sock", .{ runtime_dir, app_id.name, index }, 0);
    }
    const uid = linux.getuid();
    return std.fmt.bufPrintSentinel(buf, "/tmp/{s}-{d}-{d}.sock", .{ app_id.name, uid, index }, 0);
}

/// bind 전에 소켓 디렉터리를 만든다. 예전 경로는 `$XDG_RUNTIME_DIR` 바로 아래라 만들 것이
/// 없었지만, 이제 두 단계가 더 생긴다 (`<name>/run`). `paths.instanceLockPath` 도 같은
/// 디렉터리를 만들지만 **순서에 기대지 않는다** — 먼저 도는 쪽이 만들면 뒤는 EEXIST 다.
/// 실패는 무시한다: 진짜로 못 만들면 그다음 `bind` 가 `BindFailed` 로 말해 준다.
fn ensureSocketDir(rt: Runtime) void {
    const runtime_dir = rt.environ.getPosix("XDG_RUNTIME_DIR") orelse return; // `/tmp` fallback 은 이미 있다
    var buf: [256]u8 = undefined;
    // `mkdir` 은 한 단계씩만 만든다 — 부모부터 차례로.
    const parent = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ runtime_dir, app_id.name }, 0) catch return;
    _ = posix.system.mkdir(parent.ptr, 0o700);
    var run_buf: [256]u8 = undefined;
    const dir = std.fmt.bufPrintSentinel(&run_buf, "{s}/{s}/run", .{ runtime_dir, app_id.name }, 0) catch return;
    _ = posix.system.mkdir(dir.ptr, 0o700);
}

/// `tildaz --toggle N` 진입점 — 짧게 실행된 process가 worker N에 toggle 신호.
/// worker N이 없으면 (socket 미존재 또는 connect 실패) `error.NoRunningInstance`.
/// 성공 시 send 후 close, 두 번째 process exit.
pub fn sendToggle(rt: Runtime, index: u32) !void {
    try sendCommand(rt, index, cmd_toggle);
}

pub fn sendNewInstanceRequest(rt: Runtime) !void {
    try sendCommand(rt, 0, cmd_new_instance);
}

fn sendCommand(rt: Runtime, index: u32, command: u8) !void {
    var path_buf: [256]u8 = undefined;
    const path = try socketPath(rt, &path_buf, index);

    const fd = try openSocket(0);
    defer closeFd(fd);

    const ua = try unixAddress(path);
    if (checkErr(posix.system.connect(fd, @ptrCast(&ua.addr), ua.len)) != null) {
        return error.NoRunningInstance;
    }

    const payload = [_]u8{command};
    if (checkErr(posix.system.write(fd, &payload, payload.len)) != null) {
        return error.ToggleSendFailed;
    }
}

/// path 에 *살아있는* 인스턴스가 listen 중인지 connect 로 probe. 성공 = live,
/// 실패 = stale (이전 crash 잔존) 또는 없음. 부작용 없음 — connect 직후 close 하면
/// listener 의 accept+read 가 0 byte(EOF)로 끝나 toggle 안 일으킴 (`acceptCommand`
/// 가 `n>=1 and 'T'` 검사).
fn probeRunning(path: [:0]const u8) bool {
    const fd = openSocket(posix.SOCK.CLOEXEC) catch return false;
    defer closeFd(fd);
    const ua = unixAddress(path) catch return false;
    return checkErr(posix.system.connect(fd, @ptrCast(&ua.addr), ua.len)) == null;
}

/// 첫 인스턴스가 시작 시 호출. stale socket 정리 + listen. **이미 살아있는
/// 인스턴스가 있으면 `error.AlreadyRunning`** — host 가 toggle 신호만 보내고 이
/// 두 번째 인스턴스를 종료(기존 인스턴스를 보여줌)하게 한다. 살아있는 socket 을
/// 빼앗지(steal) 않는 게 핵심 — 이전엔 무조건 unlink 라 두 번째 전체 인스턴스가
/// 기존 socket 을 빼앗아 orphan 인스턴스가 생기고 hotkey 라우팅이 엉켰다 (#230).
///
/// 반환 fd 는 host 가 main loop polling 에 등록 + 종료 시 close.
pub fn createListener(rt: Runtime) !posix.fd_t {
    var path_buf: [256]u8 = undefined;
    const path = try socketPath(rt, &path_buf, instance_context.requireWorkerIndex());

    // 살아있는 인스턴스 먼저 판별 — 있으면 steal 금지하고 caller 가 toggle 로 위임.
    if (probeRunning(path)) return error.AlreadyRunning;

    const fd = try openSocket(posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC);
    errdefer closeFd(fd);

    const ua = try unixAddress(path);

    // probe 에서 connect 실패 = stale 또는 없음 → 남은 socket file 정리 후 bind.
    // 파일이 없으면 `ENOENT` 인데 그게 정상 경로라 반환값을 보지 않는다.
    ensureSocketDir(rt);
    _ = posix.system.unlink(path.ptr);

    if (checkErr(posix.system.bind(fd, @ptrCast(&ua.addr), ua.len)) != null) return error.BindFailed;
    if (checkErr(posix.system.listen(fd, 4)) != null) return error.ListenFailed;

    log.appendLine("toggle-ipc", "listening on {s}", .{path});
    return fd;
}

/// listener fd 의 accept + 1 byte read. callable from main loop poll handler.
/// 한 connection 마다 한 byte (cmd_toggle) 받으면 true, 그 외엔 false. 후속
/// queued connection 다음 poll iteration 에서 처리.
///
/// #451 — `EAGAIN` (= 지금 받을 연결 없음) 은 **오류가 아니라 정상 흐름**이라 `null` 이다.
/// listener 가 non-blocking 이고, poll 이 깨워도 실제 연결이 없을 수 있다. 예전
/// `posix.accept` 의 `error.WouldBlock` 분기가 이 자리였다.
pub fn acceptCommand(listener_fd: posix.fd_t) !?Command {
    const rc = posix.system.accept4(listener_fd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC);
    if (checkErr(rc)) |e| switch (e) {
        .AGAIN => return null,
        else => return error.AcceptFailed,
    };
    const client_fd: posix.fd_t = @intCast(rc);
    defer closeFd(client_fd);

    var buf: [16]u8 = undefined;
    const n_rc = posix.system.read(client_fd, &buf, buf.len);
    if (checkErr(n_rc) != null) return null;
    if (n_rc < 1) return null;
    return switch (buf[0]) {
        cmd_toggle => .toggle,
        cmd_new_instance => .new_instance,
        else => null,
    };
}

/// process 종료 시 socket file 정리. listener fd 는 close 책임 caller, 우리는
/// path unlink 만. errdefer / defer 에서 호출.
pub fn cleanup(rt: Runtime) void {
    var path_buf: [256]u8 = undefined;
    const path = socketPath(rt, &path_buf, instance_context.requireWorkerIndex()) catch return;
    _ = posix.system.unlink(path.ptr);
}
