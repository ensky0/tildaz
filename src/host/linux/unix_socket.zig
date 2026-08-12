//! Unix domain socket 배관 — `single_instance.zig` (toggle IPC) 와
//! `wayland_minimal.zig` (Wayland 연결) 이 함께 쓴다
//! ([#451](https://github.com/ensky0/tildaz/issues/451)).
//!
//! ## 왜 이 파일이 생겼나
//!
//! Zig 0.16 은 `std.posix` 의 중간 추상화를 걷어냈다 (릴리즈 노트 *posix and os.windows
//! removals*: *"Go higher: use `std.Io`" / "Go lower: use `std.posix.system` directly"*).
//! `socket` · `connect` · `bind` · `listen` · `accept` · `read` · `write` · `close` ·
//! `unlink` 가 전부 없어졌고, `std.net` 이 `std.Io.net` 으로 가면서 `Address.initUnix` 가
//! 하던 `sockaddr_un` 조립도 우리 몫이 됐다.
//!
//! 두 파일이 **같은 이유로 같은 결론**에 도달했고 (아래), 그래서 조립과 errno 판정이
//! 두 벌 생길 뻔했다. `AGENTS.md` 의 *single definition 우선* 대로 한 곳에 둔다.
//!
//! ## 왜 위 (`Io.net`) 로 못 가나 — 두 파일의 이유가 다르다
//!
//! `std.Io.net.UnixAddress` 는 실제로 있다 (`Io/net.zig:838`~, `listen` · `connect` ·
//! vtable 의 `netListenUnix` · `netConnectUnix`). 막히는 지점이 각각이다.
//!
//! **`single_instance` — non-blocking accept 를 표현할 수 없다.**
//! `UnixAddress.ListenOptions` 에는 `kernel_backlog` 뿐이라 소켓을 non-blocking 으로
//! 만들 수 없고 (`Io/Threaded.zig` 의 `openSocketPosix` 는 `mode | CLOEXEC` 만 붙인다),
//! `netAcceptPosix` 는 `EAGAIN` 을 `errnoBug` 로 넘긴다 — debug 빌드에서
//! `std.debug.panic("programmer bug caused syscall error")` 다. `Server.AcceptError` 에
//! `WouldBlock` 이 선언돼 있어도 POSIX 경로는 그것을 반환하지 않는다.
//!
//! **`wayland_minimal` — fd 를 넘길 길이 없다.** Wayland 는 `sendmsg` + `SCM_RIGHTS` 로
//! dmabuf · keymap fd 를 넘긴다. ancillary data 는 `control` 필드로 표현되는데 그 필드는
//! `OutgoingMessage` / `IncomingMessage` 에만 있고 (`Io/net.zig:968` · `:931`), 이 둘을
//! 쓰는 `Socket.send` · `sendMany` · `receive*` 는 주소가 `IpAddress` 로 고정돼 있다
//! (`:1124`~`:1191`). `UnixAddress.connect` 가 주는 `Stream` 은 `close` · `shutdown` ·
//! `Reader` · `Writer` 뿐이다 (`:1243`~). 즉 **Unix 소켓으로 `SCM_RIGHTS` 를 보낼 방법이
//! std 에 없다.** 읽기도 `netReadPosix` 가 `.AGAIN` 을 `errnoBug` 로 넘겨
//! (`Io/Threaded.zig:12587`·`12619`) non-blocking 읽기를 못 태운다.
//!
//! 릴리즈 노트 *Networking* 절의 *"Io.net currently lacks a way to do non-IP networking"*
//! 은 `UnixAddress` 가 있다는 점에서는 부정확하지만, **메시지 API 기준으로는 맞는 서술**이다.
//!
//! ## 아래로 내려간 대가는 errno 판정이다
//!
//! `std.posix.system.*` 은 raw 반환값을 준다. 예전 std wrapper 가 하던 실패 판정을
//! `checkErr` 한 곳으로 모았고, 두 파일의 모든 syscall 이 여기를 지난다.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// `std.posix.system.*` 의 raw 반환값을 오류로 판정한다. 성공이면 `null`.
///
/// **`anytype` 인 이유.** `std.posix.system` 은 libc 링크 여부로 갈린다 — libc 를 링크하면
/// `std.c` (반환 `c_int` / `isize`), 아니면 `std.os.linux` (반환 `usize`) 다. `posix.errno`
/// 자체가 `anytype` 을 받으므로 (`c.zig` 의 `fn errno(rc: anytype) E`) 여기도 열어 두면
/// 두 구성에서 같은 코드가 컴파일된다.
pub fn checkErr(rc: anytype) ?posix.E {
    const e = posix.errno(rc);
    return if (e == .SUCCESS) null else e;
}

/// `sockaddr_un` 조립 — 예전 `std.net.Address.initUnix` 자리.
///
/// 넘기는 길이는 `SUN_LEN` 관례다 — 구조체 전체가 아니라 **경로 길이 + NUL** 까지만
/// 준다. filesystem socket 에서 커널이 경로 끝을 그렇게 읽는다.
pub const UnixAddr = struct { addr: linux.sockaddr.un, len: posix.socklen_t };

pub fn unixAddress(path: []const u8) error{PathTooLong}!UnixAddr {
    var addr: linux.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    // NUL 자리를 남겨야 하므로 `>=` 다.
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    const len: posix.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);
    return .{ .addr = addr, .len = len };
}

/// `extra_flags` 가 `comptime_int` 인 것도 `checkErr` 와 같은 이유다 — 두 구성의 인자 타입이
/// (`c_int` vs `u32`) 달라서, 호출부의 comptime 상수를 그대로 흘려보내 coercion 을 맡긴다.
pub fn openSocket(comptime extra_flags: comptime_int) error{SocketCreateFailed}!posix.fd_t {
    const rc = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM | extra_flags, 0);
    if (checkErr(rc) != null) return error.SocketCreateFailed;
    return @intCast(rc);
}

pub fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

/// 열려 있는 fd 를 `path` 의 Unix 소켓에 연결한다. 실패는 errno 를 그대로 돌려준다 —
/// 호출부마다 의미 있는 이름이 달라서다 (`NoRunningInstance` vs Wayland 진단 메시지).
pub fn connect(fd: posix.fd_t, path: []const u8) error{ PathTooLong, ConnectFailed }!void {
    const ua = try unixAddress(path);
    if (checkErr(posix.system.connect(fd, @ptrCast(&ua.addr), ua.len)) != null) {
        return error.ConnectFailed;
    }
}

/// 버퍼 전체를 쓴다. 예전 `std.net.Stream.writeAll` 자리 — 짧은 쓰기를 이어서 마저 쓴다.
pub fn writeAll(fd: posix.fd_t, bytes: []const u8) error{WriteFailed}!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = posix.system.write(fd, bytes.ptr + off, bytes.len - off);
        if (checkErr(rc)) |e| switch (e) {
            // 시그널에 끊긴 것은 실패가 아니다 — 이어서 다시 쓴다.
            .INTR => continue,
            else => return error.WriteFailed,
        };
        const n: usize = @intCast(rc);
        // 0 바이트가 반복되면 진행이 없다 — 무한 루프 대신 실패로 끝낸다.
        if (n == 0) return error.WriteFailed;
        off += n;
    }
}
