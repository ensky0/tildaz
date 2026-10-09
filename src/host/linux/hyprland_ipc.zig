//! #700 — Hyprland 이벤트 소켓 (`socket2`) 에서 "설정을 다시 읽었다" 를 듣는다.
//!
//! Hyprland 은 설정을 다시 읽으면 런타임 바인딩 (`hyprctl` 로 건 것) 을 모두 지우고, 끝나면
//! 이벤트 소켓에 `configreloaded>>` 한 줄을 보낸다 (Hyprland `lua/ConfigManager.cpp` 의
//! reload 경로). 설정 파일이나 거기서 불러온 파일이 바뀌어도 스스로 다시 읽으므로, 사용자가
//! 무엇을 고치든 우리 단축키가 사라질 수 있다. worker 가 이 소켓을 `poll` 해 그때 다시 건다.
//!
//! 이벤트 소켓은 `EVENT>>DATA\n` 줄의 흐름이다 (hyprland-wiki `IPC`). 창 제목도 DATA 에
//! 실리므로 **줄 머리**에서만 찾는다 — 제목에 같은 글자가 있어도 오판하지 않는다.
const std = @import("std");
const posix = std.posix;
const unix_socket = @import("unix_socket.zig");
const Runtime = @import("../../runtime.zig").Runtime;
const log = @import("../../log.zig");

const needle = "\nconfigreloaded>>";

/// 앞선 읽기의 끝부분. 이벤트 줄이 두 번의 `read` 에 걸쳐 갈라져도 찾기 위해 둔다.
/// 처음에는 `\n` 하나로 시작한다 — 흐름의 첫 줄도 줄 머리다.
pub const Tail = struct {
    buf: [needle.len - 1]u8 = undefined,
    len: usize = 0,

    pub const start: Tail = blk: {
        var t: Tail = .{};
        t.buf[0] = '\n';
        t.len = 1;
        break :blk t;
    };
};

/// 이벤트 소켓에 붙는다. Hyprland 이 아니거나 붙지 못하면 `null` (로그만 남긴다).
pub fn subscribeReload(rt: Runtime) ?posix.fd_t {
    const runtime_dir = rt.environ.getPosix("XDG_RUNTIME_DIR") orelse return null;
    const signature = rt.environ.getPosix("HYPRLAND_INSTANCE_SIGNATURE") orelse return null;
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/hypr/{s}/.socket2.sock", .{ runtime_dir, signature }) catch {
        log.appendLine("hyprland", "event socket path too long", .{});
        return null;
    };
    const fd = unix_socket.openSocket(posix.SOCK.CLOEXEC) catch |err| {
        log.appendLine("hyprland", "reload subscription failed: {s}", .{@errorName(err)});
        return null;
    };
    unix_socket.connect(fd, path) catch |err| {
        log.appendLine("hyprland", "reload subscription failed: {s} ({s})", .{ @errorName(err), path });
        unix_socket.closeFd(fd);
        return null;
    };
    log.appendLine("hyprland", "listening for config reloads", .{});
    return fd;
}

/// 소켓이 읽기 가능할 때 부른다. 받은 것 안에 reload 줄이 있으면 `true`. 연결이 끊기면 error.
pub fn readReloadEvent(fd: posix.fd_t, tail: *Tail) !bool {
    var chunk: [4096]u8 = undefined;
    while (true) {
        const rc = posix.system.read(fd, &chunk, chunk.len);
        if (unix_socket.checkErr(rc)) |e| switch (e) {
            .INTR => continue,
            else => return error.HyprlandEventReadFailed,
        };
        const n: usize = @intCast(rc);
        if (n == 0) return error.HyprlandEventsClosed;
        return scan(tail, chunk[0..n]);
    }
}

fn scan(tail: *Tail, chunk: []const u8) bool {
    var joined: [needle.len - 1 + 4096]u8 = undefined;
    const take = @min(chunk.len, 4096);
    @memcpy(joined[0..tail.len], tail.buf[0..tail.len]);
    @memcpy(joined[tail.len..][0..take], chunk[0..take]);
    const all = joined[0 .. tail.len + take];
    const found = std.mem.find(u8, all, needle) != null;
    const keep = @min(all.len, tail.buf.len);
    std.mem.copyForwards(u8, tail.buf[0..keep], all[all.len - keep ..]);
    tail.len = keep;
    return found;
}

test "#700 the reload line is found at a line start, even across reads" {
    var tail: Tail = .start;
    try std.testing.expect(scan(&tail, "configreloaded>>\n"));

    tail = .start;
    try std.testing.expect(!scan(&tail, "activewindow>>foot,~\nconfigrel"));
    try std.testing.expect(scan(&tail, "oaded>>\nworkspace>>1\n"));

    // 창 제목에 같은 글자가 있다 — 줄 머리가 아니므로 reload 가 아니다.
    tail = .start;
    try std.testing.expect(!scan(&tail, "activewindow>>foot,echo configreloaded>>\n"));
    try std.testing.expect(!scan(&tail, "workspace>>2\n"));
}
