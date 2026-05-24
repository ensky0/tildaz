//! #198 — portal `GlobalShortcuts` 가용 안 한 DE (Cinnamon / mutter / wlroots 등)
//! 에서 `tildaz --toggle` CLI 를 통한 hide/show toggle. 사용자가 자기 DE 의
//! keyboard shortcut 설정 (KDE Plasma System Settings, GNOME Settings, sway
//! config 등) 에서 `tildaz --toggle` 명령 등록 → 그 단축키가 두 번째 tildaz
//! 인스턴스 시작 → 우리는 Unix domain socket 으로 첫 인스턴스에 신호 + exit.
//!
//! 첫 인스턴스는 시작 시 `$XDG_RUNTIME_DIR/tildaz.sock` listen. 두 번째 인스턴스는
//! connect + 1 byte ('T') 송신 + exit. 첫 인스턴스의 main loop 가 accept + read
//! → portal `Activated` 와 같은 `handleActivatedToggle` 경로로 hide/show.
//!
//! portal `GlobalShortcuts` 와 공존 — 둘 다 작동하는 환경 (KDE Plasma 6 등)
//! 에선 둘 다 trigger 가능. fallback 안 함, 둘 다 active.

const std = @import("std");
const posix = std.posix;
const log = @import("../../log.zig");

/// 1 byte command — `T` (toggle). 확장 시 다른 byte 추가 (예: `Q` quit).
pub const cmd_toggle: u8 = 'T';

/// Socket path. `$XDG_RUNTIME_DIR/tildaz.sock` (정상 표준) 또는
/// fallback `/tmp/tildaz-<uid>.sock`. `$XDG_RUNTIME_DIR` 는 systemd / elogind
/// 가 user session 마다 설정 (`/run/user/<uid>`) — 거의 모든 모던 Linux
/// 데스크탑 환경 보장.
fn socketPath(buf: []u8) ![:0]const u8 {
    if (std.posix.getenv("XDG_RUNTIME_DIR")) |runtime_dir| {
        return std.fmt.bufPrintZ(buf, "{s}/tildaz.sock", .{runtime_dir});
    }
    const uid = std.os.linux.getuid();
    return std.fmt.bufPrintZ(buf, "/tmp/tildaz-{d}.sock", .{uid});
}

/// `tildaz --toggle` 진입점 — 두 번째 인스턴스가 첫 인스턴스에 toggle 신호.
/// 첫 인스턴스가 없으면 (socket 미존재 또는 connect 실패) `error.NoRunningInstance`.
/// 성공 시 send 후 close, 두 번째 process exit.
pub fn sendToggle() !void {
    var path_buf: [256]u8 = undefined;
    const path = try socketPath(&path_buf);

    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(fd);

    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    if (path.len + 1 > addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    const addrlen: posix.socklen_t = @intCast(@sizeOf(@TypeOf(addr.family)) + path.len + 1);

    posix.connect(fd, @ptrCast(&addr), addrlen) catch {
        return error.NoRunningInstance;
    };

    _ = try posix.write(fd, &.{cmd_toggle});
}

/// 첫 인스턴스가 시작 시 호출. stale socket 정리 + listen. 같은 user 의 두 번째
/// 인스턴스가 동시 listen 시도하면 bind 실패 (`AddressInUse`) — 우리는 정상
/// 동작하는 인스턴스가 있는 거니 host 가 `error.AlreadyRunning` 으로 처리해
/// 사용자에게 명확한 메시지 표시 권장.
///
/// 반환 fd 는 host 가 main loop polling 에 등록 + 종료 시 close.
pub fn createListener() !posix.fd_t {
    var path_buf: [256]u8 = undefined;
    const path = try socketPath(&path_buf);

    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);

    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    if (path.len + 1 > addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    const addrlen: posix.socklen_t = @intCast(@sizeOf(@TypeOf(addr.family)) + path.len + 1);

    // stale socket 정리. 이전 process 가 crash 로 안 지운 경우 등.
    // 단 active connect 가능한 path 면 다른 인스턴스가 살아있다는 거라 unlink
    // 안 하고 bind 시도 → `AddressInUse` 로 fail → host 가 분기.
    posix.unlink(path) catch {};

    posix.bind(fd, @ptrCast(&addr), addrlen) catch |err| return err;
    try posix.listen(fd, 4);

    log.appendLine("toggle-ipc", "listening on {s}", .{path});
    return fd;
}

/// listener fd 의 accept + 1 byte read. callable from main loop poll handler.
/// 한 connection 마다 한 byte (cmd_toggle) 받으면 true, 그 외엔 false. 후속
/// queued connection 다음 poll iteration 에서 처리.
pub fn acceptToggle(listener_fd: posix.fd_t) !bool {
    const client_fd = posix.accept(listener_fd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC) catch |err| switch (err) {
        error.WouldBlock => return false,
        else => return err,
    };
    defer posix.close(client_fd);

    var buf: [16]u8 = undefined;
    const n = posix.read(client_fd, &buf) catch return false;
    return n >= 1 and buf[0] == cmd_toggle;
}

/// process 종료 시 socket file 정리. listener fd 는 close 책임 caller, 우리는
/// path unlink 만. errdefer / defer 에서 호출.
pub fn cleanup() void {
    var path_buf: [256]u8 = undefined;
    const path = socketPath(&path_buf) catch return;
    posix.unlink(path) catch {};
}
