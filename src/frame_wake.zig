//! [#770](https://github.com/ensky0/tildaz/issues/770) — host 가 "그릴 것이 없으면 잔다" 로 돌 때
//! **언제까지만 자면 되는지** 를 정한다. 세 host 가 같은 판정을 쓴다.
//!
//! tick 에만 기대던 일 가운데 시간에 걸린 것을 모았다. 사건 (입력 · 출력 · 창) 은 host 가 각자
//! 깨우고, 여기는 "사건이 없어도 이 시각에는 깨어나야 한다" 만 다룬다.
//!
//! - 자동 제목 · 검색 debounce — `SessionCore.nextWakeInNs` 가 준다 (공통 코드)
//! - blink 위상 — 화면에 blink 셀이 있을 때만 (#376)
//! - 드래그 선택 자동 스크롤 — 포인터가 창 밖에 멈춰 있으면 이벤트가 오지 않는다 (#245)
//! - 키 반복 — Wayland 는 client 가 직접 반복한다 (macOS · Windows 는 OS 가 한다)
//!
//! 순수 함수만 둔다 — 시계를 읽지 않고 받는다. 그래야 경계를 테스트로 박을 수 있다.

const std = @import("std");
const ui_metrics = @import("ui_metrics.zig");

pub const Inputs = struct {
    /// `SessionCore.hasPendingOutput()` — 어느 탭이든 아직 파싱하지 않은 출력이 남았는가.
    /// `drainOutputForRender` 의 반환값은 "활성 탭 화면이 바뀌었나" 뿐이라 비활성 탭에만 남은
    /// 출력을 알려 주지 않는다. 남았으면 지금 계속 돌아야 한다 — 출력 통보는 새 출력에만 온다.
    pending_output: bool,
    /// `SessionCore.nextWakeInNs()` 의 값.
    session_wake_ns: ?u64,
    /// host 의 ms 시계 (`runtime.nowMs`). 아래 `*_next_ms` 와 같은 시계여야 한다.
    now_ms: i64,
    /// 직전 프레임에 blink 셀이 보였는가 (`renderer.saw_blink_cell`).
    saw_blink_cell: bool,
    /// 드래그 자동 스크롤이 진행 중이면 다음 스크롤 시각. 아니면 `null`.
    autoscroll_next_ms: ?i64 = null,
    /// client 가 직접 키를 반복하는 동안 다음 반복 시각. 아니면 `null`.
    key_repeat_next_ms: ?i64 = null,
};

/// 다음에 깨어나야 할 때까지 남은 시간 (ns). `null` 이면 시간에 걸린 일이 없다 — 사건이 깨울
/// 때까지 자도 된다. `0` 이면 지금 할 일이 있다.
pub fn idleWakeInNs(in: Inputs) ?u64 {
    if (in.pending_output) return 0;
    var best = in.session_wake_ns;
    if (in.saw_blink_cell) best = minOpt(best, msToNs(ui_metrics.blinkNextFlipInMs(in.now_ms)));
    if (in.autoscroll_next_ms) |t| best = minOpt(best, msToNs(t - in.now_ms));
    if (in.key_repeat_next_ms) |t| best = minOpt(best, msToNs(t - in.now_ms));
    return best;
}

/// `poll` 의 timeout (ms) 으로 바꾼다. `null` 은 무한 (`-1`). 올림이다 — 내림하면 마감 직전에
/// 깨어나 할 일이 없어 다시 잠드는 헛바퀴가 생긴다.
pub fn pollTimeoutMs(wake_in_ns: ?u64) i32 {
    const ns = wake_in_ns orelse return -1;
    const ms = std.math.divCeil(u64, ns, std.time.ns_per_ms) catch unreachable;
    return @intCast(@min(ms, std.math.maxInt(i32)));
}

/// 둘 중 가까운 것. `null` 은 "없음" 이라 다른 쪽이 이긴다.
pub fn minOpt(a: ?u64, b: ?u64) ?u64 {
    const x = a orelse return b;
    const y = b orelse return x;
    return @min(x, y);
}

/// 남은 ms 를 ns 로. 이미 지난 시각 (음수) 은 `0` — 지금 할 일이 있다.
fn msToNs(ms: i64) u64 {
    if (ms <= 0) return 0;
    return @as(u64, @intCast(ms)) * std.time.ns_per_ms;
}

test "#770 idleWakeInNs — 시간에 걸린 일이 없으면 null" {
    try std.testing.expectEqual(@as(?u64, null), idleWakeInNs(.{ .pending_output = false, .session_wake_ns = null, .now_ms = 1_000, .saw_blink_cell = false }));
}

test "#770 idleWakeInNs — 가장 가까운 마감을 고른다" {
    const ms = std.time.ns_per_ms;
    // blink 은 1_000 ms 에서 500 ms 뒤에 뒤집힌다. 자동 스크롤 30 ms 가 더 가깝다.
    try std.testing.expectEqual(@as(?u64, 30 * ms), idleWakeInNs(.{
        .pending_output = false,
        .session_wake_ns = 150 * ms,
        .now_ms = 1_000,
        .saw_blink_cell = true,
        .autoscroll_next_ms = 1_030,
    }));
    // blink 이 보이지 않으면 셈하지 않는다.
    try std.testing.expectEqual(@as(?u64, 150 * ms), idleWakeInNs(.{ .pending_output = false, .session_wake_ns = 150 * ms, .now_ms = 1_000, .saw_blink_cell = false }));
    try std.testing.expectEqual(@as(?u64, 100 * ms), idleWakeInNs(.{ .pending_output = false, .session_wake_ns = null, .now_ms = 1_400, .saw_blink_cell = true }));
}

test "#770 idleWakeInNs — 이미 지난 마감은 0 (지금 할 일)" {
    try std.testing.expectEqual(@as(?u64, 0), idleWakeInNs(.{ .pending_output = false, .session_wake_ns = null, .now_ms = 1_000, .saw_blink_cell = false, .key_repeat_next_ms = 990 }));
    try std.testing.expectEqual(@as(?u64, 0), idleWakeInNs(.{ .pending_output = false, .session_wake_ns = null, .now_ms = 1_000, .saw_blink_cell = false, .autoscroll_next_ms = 0 }));
}

test "#770 pollTimeoutMs — null 은 무한, 나머지는 올림" {
    try std.testing.expectEqual(@as(i32, -1), pollTimeoutMs(null));
    try std.testing.expectEqual(@as(i32, 0), pollTimeoutMs(0));
    try std.testing.expectEqual(@as(i32, 1), pollTimeoutMs(1));
    try std.testing.expectEqual(@as(i32, 150), pollTimeoutMs(150 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(i32, 151), pollTimeoutMs(150 * std.time.ns_per_ms + 1));
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), pollTimeoutMs(std.math.maxInt(u64)));
}

test "#770 idleWakeInNs — 어느 탭이든 밀린 출력이 있으면 지금 돈다" {
    try std.testing.expectEqual(@as(?u64, 0), idleWakeInNs(.{ .pending_output = true, .session_wake_ns = null, .now_ms = 1_000, .saw_blink_cell = false }));
}
