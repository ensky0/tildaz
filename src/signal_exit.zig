//! `SIGTERM` 을 **정상 종료**로 바꾼다 ([#458](https://github.com/ensky0/tildaz/issues/458)).
//!
//! 핸들러가 없으면 `SIGTERM` 의 기본 동작이 즉시 종료라, `defer` 와 `deinit` 이 하나도
//! 돌지 않는다. 그러면 PTY 의 자식 정리가 통째로 건너뛰어진다 — `pty.zig` 의 `deinit` 은
//! [#129](https://github.com/ensky0/tildaz/issues/129) 에서 이미 *프로세스 그룹에 `SIGHUP`
//! → 500 ms grace → `SIGKILL`* 을 하고 있는데, 그 자리에 **도달을 못 한다.**
//!
//! 그래서 `-e` 로 띄운 프로그램이 `SIGHUP` 을 무시하면 앱을 `kill` 한 뒤 고아로 남는다
//! (실측: `trap '' HUP` 을 건 스크립트가 앱 종료 후 `ppid=1` 로 입양돼 살아남았다).
//!
//! **정리 코드를 새로 만들지 않는다.** 이 모듈이 하는 일은 *그 경로에 도달시키는 것* 뿐이다 —
//! 핸들러는 플래그 하나만 세우고, main loop 가 그것을 보고 평소의 종료 경로로 빠진다.
//!
//! 곁가지로 종료 시 로그 flush 와 perf 덤프 (#396) 도 함께 정상화된다. 그 둘도 같은
//! `defer` 에 걸려 있어서 지금까지 `SIGTERM` 회차에서는 남지 않았다.
//!
//! Windows 는 no-op 이다. `SIGTERM` 이 POSIX 개념이고, Windows 의 종료 통보 (`WM_CLOSE` ·
//! `CTRL_CLOSE_EVENT`) 는 이미 다른 경로로 다룬다.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const is_posix = builtin.os.tag != .windows;

/// 핸들러가 세우고 main loop 가 읽는다. 시그널 문맥에서 만질 수 있는 것은 이 정도뿐이다
/// (async-signal-safe) — 로그도 정리도 여기서 하지 않는다.
var term_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn onTerm(_: posix.SIG) callconv(.c) void {
    term_requested.store(true, .release);
}

/// **`requested()` 를 검사하는 loop 와 같은 자리에서 부른다.** 핸들러만 걸고 아무도 플래그를
/// 안 보면 `SIGTERM` 이 무시돼 앱이 종료되지 않는다 — 기본 동작을 없앤 셈이라 고치기 전보다
/// 나쁘다. 지금은 Linux host 만 검사하므로 그쪽에서만 건다.
///
/// 실패해도 조용히 넘어간다 — 핸들러가 없으면 예전 동작 (즉시 종료) 으로 돌아갈 뿐이다.
pub fn install() void {
    if (!is_posix) return;
    var act: posix.Sigaction = .{
        .handler = .{ .handler = onTerm },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &act, null);
}

/// main loop 가 매 바퀴 검사한다. `true` 면 평소의 종료 경로로 빠지면 된다.
pub fn requested() bool {
    if (!is_posix) return false;
    return term_requested.load(.acquire);
}

test "install 은 두 번 불러도 안전하고 기본은 요청 없음" {
    if (!is_posix) return error.SkipZigTest;
    try std.testing.expect(!requested());
    install();
    install();
    try std.testing.expect(!requested());
}
