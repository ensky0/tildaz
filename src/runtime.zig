//! Zig 0.16 런타임 손잡이 — 진입점이 받은 `std.process.Init` 의 조각을 보관한다 ([#451]).
//!
//! Zig 0.16 은 환경변수 · 파일 IO · argv · 동기화를 **`Io` 와 `Environ` 경유**로 바꿨다.
//! 예전에는 `std.process.getEnvVarOwned` · `std.time.milliTimestamp` · `std.Thread.Mutex`
//! 처럼 전역 함수로 아무 데서나 부를 수 있었는데, 이제 그 값을 가진 객체가 필요하다.
//!
//! **왜 전역인가.** 그 값을 필요로 하는 자리가 전역 로거 (`log.zig`) 와 경로 계산
//! (`paths.zig`) 인데, 둘 다 호출부가 앱 전체에 흩어져 있어 인자로 흘려보내려면 거의 모든
//! 함수 시그니처를 바꿔야 한다. #451 에서 세 안 중 **A (Io 를 최소로만 들인다)** 를 골랐고,
//! 이 파일이 그 구현이다 — 진입점이 `install` 을 한 번 부르고 나머지는 여기서 읽는다.
//!
//! **왜 한 파일에 모으나.** 같은 성질의 전역을 `log.zig` · `paths.zig` · `stress.zig` 에
//! 각각 두면 세 곳이 따로 늙는다. 여기로 모으면 Zig 0.16 에 대한 결합이 한 파일에만 있어서,
//! 나중에 안 C (ghostty 처럼 최소 Io 구현) 로 옮길 때 고칠 자리가 한 군데다.
//!
//! **진입점은 두 개다** — `main.zig` (앱) 와 `stress.zig` (측정 하네스). 둘 다 `install` 을
//! 첫 줄에서 부른다.

const std = @import("std");

/// 런타임이 준 `Io`. `install` 전에는 null 이다 — 그 구간은 아직 스레드가 없어서
/// (진입점 첫 줄에서 부른다) 잠글 상대가 없다는 것이 `log.zig` 의 전제다.
var g_io: ?std.Io = null;

/// 런타임이 준 환경변수 블록. `install` 전에는 비어 있어서 조회가 전부 null 이 된다 —
/// 그러면 `paths.zig` 가 fallback 경로를 쓴다 (환경변수가 없는 환경과 같은 취급).
var g_environ: std.process.Environ = .empty;

/// 진입점 (`main`) 의 **첫 줄**에서 부른다.
pub fn install(init: std.process.Init) void {
    g_io = init.io;
    g_environ = init.minimal.environ;
}

/// `install` 전이면 null. 호출부가 "그럼 잠그지 않는다" 를 명시적으로 처리하도록
/// optional 을 그대로 넘긴다 — 조용히 기본값을 만들어 주면 경합 여부가 가려진다.
pub fn io() ?std.Io {
    return g_io;
}

/// 환경변수 블록. `install` 전이면 비어 있다 (위 `g_environ` 주석).
pub fn environ() std.process.Environ {
    return g_environ;
}

/// `std.process.getEnvVarOwned` 자리. 0.16 에서 그 전역 함수가 없어졌고
/// `Environ.getAlloc` 이 같은 일을 한다 — 호출부가 매번 `environ()` 을 거치지 않도록 감싼다.
pub fn envAlloc(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    return g_environ.getAlloc(allocator, key);
}
