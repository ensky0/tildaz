//! #198 — Linux desktop/compositor에서 `tildaz --toggle` CLI를 통한
//! hide/show toggle. 사용자가 자기 DE의
//! keyboard shortcut 설정 (KDE Plasma System Settings, GNOME Settings, sway
//! config 등) 에서 `tildaz --toggle` 명령 등록 → 그 단축키가 두 번째 tildaz
//! 인스턴스 시작 → 우리는 Unix domain socket 으로 첫 인스턴스에 신호 + exit.
//!
//! worker N은 시작 시 `$XDG_RUNTIME_DIR/tildaz-N.sock` listen. `--toggle N` process는
//! 해당 socket에 connect + 1 byte ('T') 송신 + exit. worker N의 main loop가
//! accept + read → 공통 `handleActivatedToggle` 경로로 hide/show.
//!
//! DE별 global hotkey backend와 공존 — hotkey와 `tildaz --toggle` 모두 같은
//! `handleActivatedToggle` 경로로 수렴한다.
//! 에선 둘 다 trigger 가능. fallback 안 함, 둘 다 active.

const std = @import("std");
const runtime = @import("../../runtime.zig");
const posix = std.posix;
const log = @import("../../log.zig");
const instance_context = @import("../../instance_context.zig");

/// 1 byte command — `T` (toggle). 확장 시 다른 byte 추가 (예: `Q` quit).
pub const cmd_toggle: u8 = 'T';
pub const cmd_new_instance: u8 = 'N';

pub const Command = enum { toggle, new_instance };

/// Socket path. `$XDG_RUNTIME_DIR/tildaz-N.sock` (정상 표준) 또는
/// fallback `/tmp/tildaz-<uid>-N.sock`. `$XDG_RUNTIME_DIR` 는 systemd / elogind
/// 가 user session 마다 설정 (`/run/user/<uid>`) — 거의 모든 모던 Linux
/// 데스크탑 환경 보장.
fn socketPath(buf: []u8, index: u32) ![:0]const u8 {
    // Zig 0.16 — `posix.getenv` 가 없어졌다. 환경변수는 진입점이 받은 블록에서 읽는다
    // (`runtime.zig`, #451). `getPosix` 는 POSIX 전용이고 이 파일은 Linux 전용이다.
    if (runtime.environ().getPosix("XDG_RUNTIME_DIR")) |runtime_dir| {
        return std.fmt.bufPrintZ(buf, "{s}/tildaz-{d}.sock", .{ runtime_dir, index });
    }
    const uid = std.os.linux.getuid();
    return std.fmt.bufPrintZ(buf, "/tmp/tildaz-{d}-{d}.sock", .{ uid, index });
}

/// `tildaz --toggle N` 진입점 — 짧게 실행된 process가 worker N에 toggle 신호.
/// worker N이 없으면 (socket 미존재 또는 connect 실패) `error.NoRunningInstance`.
/// 성공 시 send 후 close, 두 번째 process exit.
pub fn sendToggle(index: u32) !void {
    try sendCommand(index, cmd_toggle);
}

pub fn sendNewInstanceRequest() !void {
    try sendCommand(0, cmd_new_instance);
}

fn sendCommand(index: u32, command: u8) !void {
    var path_buf: [256]u8 = undefined;
    const path = try socketPath(&path_buf, index);

    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(fd);

    // #298 — sockaddr_un 수동 조립 → std.net.Address.initUnix (memcpy + null 종단 +
    // getOsSockLen 을 std 가 처리). filesystem unix socket 경로라 그대로 적용.
    const addr = std.net.Address.initUnix(path) catch return error.PathTooLong;
    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch {
        return error.NoRunningInstance;
    };

    _ = try posix.write(fd, &.{command});
}

/// path 에 *살아있는* 인스턴스가 listen 중인지 connect 로 probe. 성공 = live,
/// 실패 = stale (이전 crash 잔존) 또는 없음. 부작용 없음 — connect 직후 close 하면
/// listener 의 accept+read 가 0 byte(EOF)로 끝나 toggle 안 일으킴 (`acceptCommand`
/// 가 `n>=1 and 'T'` 검사).
fn probeRunning(path: [:0]const u8) bool {
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch return false;
    defer posix.close(fd);
    const addr = std.net.Address.initUnix(path) catch return false;
    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch return false;
    return true;
}

/// 첫 인스턴스가 시작 시 호출. stale socket 정리 + listen. **이미 살아있는
/// 인스턴스가 있으면 `error.AlreadyRunning`** — host 가 toggle 신호만 보내고 이
/// 두 번째 인스턴스를 종료(기존 인스턴스를 보여줌)하게 한다. 살아있는 socket 을
/// 빼앗지(steal) 않는 게 핵심 — 이전엔 무조건 unlink 라 두 번째 전체 인스턴스가
/// 기존 socket 을 빼앗아 orphan 인스턴스가 생기고 hotkey 라우팅이 엉켰다 (#230).
///
/// 반환 fd 는 host 가 main loop polling 에 등록 + 종료 시 close.
pub fn createListener() !posix.fd_t {
    var path_buf: [256]u8 = undefined;
    const path = try socketPath(&path_buf, instance_context.requireWorkerIndex());

    // 살아있는 인스턴스 먼저 판별 — 있으면 steal 금지하고 caller 가 toggle 로 위임.
    if (probeRunning(path)) return error.AlreadyRunning;

    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);

    // #298 — sockaddr_un 수동 조립 → std.net.Address.initUnix.
    const addr = std.net.Address.initUnix(path) catch return error.PathTooLong;

    // probe 에서 connect 실패 = stale 또는 없음 → 남은 socket file 정리 후 bind.
    posix.unlink(path) catch {};

    posix.bind(fd, &addr.any, addr.getOsSockLen()) catch |err| return err;
    try posix.listen(fd, 4);

    log.appendLine("toggle-ipc", "listening on {s}", .{path});
    return fd;
}

/// listener fd 의 accept + 1 byte read. callable from main loop poll handler.
/// 한 connection 마다 한 byte (cmd_toggle) 받으면 true, 그 외엔 false. 후속
/// queued connection 다음 poll iteration 에서 처리.
pub fn acceptCommand(listener_fd: posix.fd_t) !?Command {
    const client_fd = posix.accept(listener_fd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC) catch |err| switch (err) {
        error.WouldBlock => return null,
        else => return err,
    };
    defer posix.close(client_fd);

    var buf: [16]u8 = undefined;
    const n = posix.read(client_fd, &buf) catch return null;
    if (n < 1) return null;
    return switch (buf[0]) {
        cmd_toggle => .toggle,
        cmd_new_instance => .new_instance,
        else => null,
    };
}

/// process 종료 시 socket file 정리. listener fd 는 close 책임 caller, 우리는
/// path unlink 만. errdefer / defer 에서 호출.
pub fn cleanup() void {
    var path_buf: [256]u8 = undefined;
    const path = socketPath(&path_buf, instance_context.requireWorkerIndex()) catch return;
    posix.unlink(path) catch {};
}
