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
const builtin = @import("builtin");

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

    /// `std.process.getEnvVarOwned` 자리. 호출부가 `rt.environ` 을 매번 꺼내지 않게 감싼다.
    /// 반환 메모리는 호출자 소유다.
    ///
    /// **`Environ.getAlloc` 을 쓰지 않는다** ([#519](https://github.com/ensky0/tildaz/issues/519)).
    /// 그 함수는 조회 한 번에 `createMap` 으로 **환경 전체를 할당**해서, 값 하나를 얻는 데
    /// 환경 블록 크기만큼의 메모리를 요구한다. 작은 고정 버퍼를 준 호출부는 **항상**
    /// `OutOfMemory` 로 떨어졌다 — 실측 (환경 블록 4780 B) 에서 4096 · 8192 바이트
    /// `FixedBufferAllocator` 가 모두 실패하고 16384 에서야 성공했다. 그래서 hotkey 실패
    /// 다이얼로그가 config 경로 대신 `(unknown)` 을 보여 줬다.
    ///
    /// 대신 값 하나만 찾아 그것만 복사한다. 호출부 계약 (반환 메모리는 호출자 소유) 은 같다.
    ///
    ///   - **POSIX** — `getPosix` 가 블록을 그대로 훑어 **할당이 없다.** 반환값은 환경
    ///     블록을 가리키므로 소유권을 주려면 여기서 dupe 한다.
    ///   - **Windows** — `getWindows` 가 PEB 를 훑는다. 키를 WTF-16 으로, 값을 WTF-8 로
    ///     한 번씩 옮기는 비용만 든다. `Block` 이 global 아니면 empty 뿐이라
    ///     (`GlobalBlock`) `createMap` 과 결과가 갈리지 않는다 — empty 면 양쪽 다 "없음" 이다.
    ///
    /// 같은 성질 때문에 `envHas` 는 아래처럼 `containsConstant` 를 쓴다.
    pub fn envAlloc(rt: Runtime, allocator: std.mem.Allocator, key: []const u8) ![]u8 {
        if (builtin.os.tag != .windows) {
            const value = rt.environ.getPosix(key) orelse return error.EnvironmentVariableMissing;
            return allocator.dupe(u8, value);
        }

        if (!std.unicode.wtf8ValidateSlice(key)) return error.InvalidWtf8;
        // 환경변수 **이름**은 짧다 (우리 호출부는 전부 리터럴이다). 스택에서 변환해 호출부가
        // 준 allocator 를 키 때문에 건드리지 않는다 — 그 allocator 가 작은 고정 버퍼일 수
        // 있고, 애초에 그것이 이 함수를 고친 이유다.
        var key_buf: [256]u16 = undefined;
        // WTF-16 길이는 WTF-8 바이트 수를 넘지 않는다. 종단 NUL 자리를 한 칸 남긴다.
        if (key.len >= key_buf.len) return rt.environ.getAlloc(allocator, key);
        const key_len = std.unicode.wtf8ToWtf16Le(key_buf[0 .. key_buf.len - 1], key) catch
            return error.InvalidWtf8;
        key_buf[key_len] = 0;

        const value = rt.environ.getWindows(key_buf[0..key_len :0].ptr) orelse
            return error.EnvironmentVariableMissing;
        return std.unicode.wtf16LeToWtf8Alloc(allocator, value);
    }

    /// `std.process.hasEnvVarConstant` 자리 — 0.16 의 `Environ.containsConstant` 다.
    ///
    /// **`Environ.contains` (allocator 를 받는 쪽) 를 쓰면 안 된다.** 그 함수는 안에서
    /// `createMap` 으로 **환경 전체를 할당**한다 (`process/Environ.zig:542`). 처음에 이 자리를
    /// 512 바이트 `FixedBufferAllocator` 로 감쌌다가 항상 `OutOfMemory` → `catch false` 가
    /// 되어 **`TILDAZ_VERBOSE` 가 영영 안 켜졌다** (#451 sway 실기에서 발견). 컴파일도 테스트도
    /// 통과하는 종류의 버그다.
    ///
    /// `containsConstant` 는 comptime key 를 받고 POSIX 에서는 `getPosix` 로 블록을 그대로
    /// 훑어 **할당이 없다**. Windows 는 key 를 comptime 에 WTF-16 으로 바꾼다. 우리 호출부의
    /// key 는 전부 리터럴이라 그대로 맞는다.
    pub inline fn envHas(rt: Runtime, comptime key: []const u8) bool {
        return rt.environ.containsConstant(key);
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

test "#519 envAlloc 은 환경 전체가 아니라 값 하나만 할당한다" {
    // Windows 는 `Block` 이 global 아니면 empty 뿐이라 (`GlobalBlock`) 합성 환경을 만들 수
    // 없다. 그쪽 경로는 `zig build check` 의 컴파일과 실기 검증이 덮는다.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    // 환경 블록을 일부러 크게 만든다 — 예전 구현 (`Environ.getAlloc` → `createMap`) 은 값
    // 하나를 얻으려고 **이 전체**를 복사했다. 그래서 아래 64 바이트 버퍼로는 실패했다.
    const filler = "PAD=" ++ ("x" ** 512);
    const entries = [_:null]?[*:0]const u8{
        "TILDAZ_519=ok",
        filler,
        filler,
        filler,
        filler,
        filler,
        filler,
        filler,
        filler,
    };
    const rt: Runtime = .{ .io = std.testing.io, .environ = .{ .block = .{ .slice = &entries } } };

    // 값이 2 바이트니 버퍼도 그만큼만 있으면 된다. 이 크기가 통과의 요점이다 — 환경 블록
    // (약 4.6 KB) 에 비례하지 않는다는 뜻이다.
    var buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    const value = try rt.envAlloc(fba.allocator(), "TILDAZ_519");
    try std.testing.expectEqualStrings("ok", value);

    // 없는 키는 그대로 `EnvironmentVariableMissing` — 호출부가 `catch null` 로 쓰는 계약이다.
    try std.testing.expectError(
        error.EnvironmentVariableMissing,
        rt.envAlloc(fba.allocator(), "TILDAZ_519_ABSENT"),
    );
}
