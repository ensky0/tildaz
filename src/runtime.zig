//! 프로세스가 런타임에게서 받은 것 — `Io` 와 환경변수 — 를 담아 **인자로 흘려보내는 값**
//! ([#451](https://github.com/ensky0/tildaz/issues/451)).
//!
//! Zig 0.16 은 파일 IO · 환경변수 · 시간 · 동기화를 전역 함수에서 걷어내고 `Io` ·
//! `Environ` 를 거치게 바꿨다 (릴리즈 노트 *I/O as an Interface* ·
//! *Environment Variables and Process Arguments Become Non-Global*). 그래서
//! `std.process.getEnvVarOwned` · `std.time.milliTimestamp` · `std.Thread.sleep` 처럼
//! 아무 데서나 부르던 전역 함수가 없어졌고, 그 값을 가진 객체가 필요해졌다.
//!
//! **왜 값 타입인가.** 노트가 지정한 길은 둘이다 — 필요한 값을 인자로 받거나, context
//! struct 에 담아 넘긴다. 이 파일이 후자다:
//!
//! > "it is better to accept an `Io` parameter if you need one (or store one on a context
//! > struct for convenience). Point is that the application's main function should generally
//! > be responsible for constructing the `Io` instance used throughout."
//!
//! 환경변수 쪽은 노트가 더 못박는다 — *"functions which need access environment variables
//! should accept parameters for the needed values, or accept a `*const process.Environ.Map`
//! parameter."* 전역으로 두면 0.16 이 없앤 바로 그 전역을 우리가 다시 만드는 셈이다.
//!
//! **전역이 없다.** `install` 같은 것이 없고, 진입점 (`main.zig` · `stress.zig` ·
//! `render_test.zig`) 이 `std.process.Init` 에서 하나 만들어 호출 사슬로 내려보낸다.
//! 그래서 "아직 설치 전이라 잠그지 않는다" / "설치 전이라 시간이 0 이다" 같은 조용한
//! 반쪽 상태가 아예 생기지 않는다.
//!
//! **`log.zig` 는 이 값을 안 받는다.** 로그 기록은 raw syscall 이고 (O_APPEND 원자성,
//! #282 D1) 경로는 프로세스 수명 동안 하나라, 진입점이 `log.init(path)` 로 한 번 넘긴다.
//! 덕분에 `appendLine` 계열 297 자리가 시그니처를 안 바꾼다.

const std = @import("std");

/// `Io` 와 환경변수 묶음. 복사가 싸다 (`Io` 는 vtable + userdata 포인터 쌍,
/// `Environ` 은 작은 블록 참조) — 포인터가 아니라 값으로 넘긴다.
pub const Runtime = struct {
    io: std.Io,
    environ: std.process.Environ,

    /// 진입점에서 한 번 만든다. `std.process.Init` 은 Zig 0.16 이 `main` 의 첫 인자로
    /// 넘겨주는 묶음이다 (릴리즈 노트 *"Juicy Main"*).
    pub fn fromInit(init: std.process.Init) Runtime {
        return .{ .io = init.io, .environ = init.minimal.environ };
    }

    /// `Init.Minimal` 만 받는 진입점용 (`arena` · `gpa` 가 필요 없는 하네스).
    pub fn fromMinimal(minimal: std.process.Init.Minimal) Runtime {
        return .{ .io = minimal.io, .environ = minimal.environ };
    }

    /// `std.process.getEnvVarOwned` 자리. 호출부가 `rt.environ` 을 매번 꺼내지 않게 감싼다.
    /// 반환 메모리는 호출자 소유다.
    pub fn envAlloc(rt: Runtime, allocator: std.mem.Allocator, key: []const u8) ![]u8 {
        return rt.environ.getAlloc(allocator, key);
    }

    /// `std.process.hasEnvVarConstant` 자리. `Environ.contains` 가 allocator 를 받는 것은
    /// Windows 가 WTF-16 변환을 해야 해서다 — 호출부는 bool 만 원하므로 감싼다.
    pub fn envHas(rt: Runtime, allocator: std.mem.Allocator, key: []const u8) bool {
        return rt.environ.contains(allocator, key) catch false;
    }

    /// `std.time.milliTimestamp` 자리. `.real` 이 Unix epoch wall clock 이다
    /// (`Io.Clock.real` 주석 — 다른 epoch 를 쓰는 OS 는 런타임이 변환해 준다).
    pub fn nowMs(rt: Runtime) i64 {
        return std.Io.Timestamp.now(rt.io, .real).toMilliseconds();
    }

    /// `std.Thread.sleep` 자리. `.awake` 는 절전 구간을 세지 않는 단조 시계다 —
    /// 벽시계 (`.real`) 로 자면 시스템 시각이 조정될 때 길이가 흔들린다.
    pub fn sleepNs(rt: Runtime, ns: u64) void {
        std.Io.sleep(rt.io, .{ .nanoseconds = @intCast(ns) }, .awake) catch {};
    }
};

/// `std.time.Timer` 자리 — 0.16 이 `Timer` 와 `Instant` 를 `Io.Timestamp` 하나로 합쳤다
/// (릴리즈 노트 *Time* 절). 경과 시간만 재던 기존 호출부 모양 (`start` / `read` /
/// `reset`) 을 그대로 두려고 얇게 감싼다.
///
/// 시계는 `.awake` 다 — 절전 구간을 세지 않는 단조 시계이고, 예전 `std.time.Timer` 의
/// 성질과 같다. 벽시계 (`.real`) 로 재면 시스템 시각이 조정될 때 경과가 뒤로 갈 수 있다.
pub const Timer = struct {
    io: std.Io,
    start_ns: i96,

    /// 예전 `std.time.Timer.start()` 와 달리 **실패하지 않는다** — 0.16 은 시계 조회에
    /// 오류가 없고, 해상도는 필요하면 `Io.Clock.resolution` 으로 따로 묻는다.
    pub fn start(rt: Runtime) Timer {
        return .{ .io = rt.io, .start_ns = std.Io.Timestamp.now(rt.io, .awake).nanoseconds };
    }

    /// 시작 이후 경과 나노초.
    pub fn read(t: Timer) u64 {
        const now = std.Io.Timestamp.now(t.io, .awake).nanoseconds;
        return @intCast(@max(0, now - t.start_ns));
    }

    pub fn reset(t: *Timer) void {
        t.start_ns = std.Io.Timestamp.now(t.io, .awake).nanoseconds;
    }
};
