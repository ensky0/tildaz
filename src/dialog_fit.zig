//! 다이얼로그 본문의 크기를 정한다 — 세 OS 공통 ([#795](https://github.com/ensky0/tildaz/issues/795)).
//!
//! 예전에는 Windows (`dialog/windows.zig` 의 `scrollLayout` · `promptLayout`) · Linux
//! (`host/linux/dialog_layout.zig` 의 `computeWithinSurface`) · macOS (`dialog/macos.zig` 의
//! `makeDialogBody`) 가 같은 규칙을 각자 구현했다. 그러다 조금씩 어긋났다 — 580pt 가 무엇의 폭인지
//! (#793), 언제 최대 폭으로 넓히는지 (Linux 만 창 전체 높이를 봤다). 이제 판단은 여기 하나다.
//!
//! **규칙** (SPEC §2.4, 2026-10-18 사용자 결정 — #795 의 (나)):
//! 1. 가장 긴 줄이 최대 폭 안에 들면 그 줄이 들어가는 폭이다. 짧으면 최소 폭까지 좁아진다.
//! 2. 최대 폭으로도 안 들어가는 줄이 있으면 기본 폭에서 접는다.
//! 3. 접은 줄이 있고 본문이 높이 상한을 넘으면 최대 폭으로 넓혀 다시 접는다. 접은 줄이 없으면
//!    넓혀도 높이가 그대로라 넓히지 않는다.
//! 4. 그래도 넘치면 본문만 스크롤한다. 스크롤바가 글 영역 안에 서면 그만큼 빼고 다시 접는다.
//!
//! **OS 마다 다른 것은 넘겨받는다.** 글자 재기 (`measurer`), 화면 크기로 줄인 폭 · 높이 상한,
//! 스크롤바 자리. 선례는 [`hotkey_status.fit`](hotkey_status.zig) (#721) 이다.
//!
//! 단위는 호출자가 고른다 — Linux · Windows 는 물리 px 정수 (`i32`), macOS 는 AppKit point (`f64`).

const std = @import("std");

pub fn Limits(comptime T: type) type {
    return struct {
        /// 글 영역의 최소 · 기본 · 최대 폭. **호출자가 화면 크기로 이미 줄인 값**이다
        /// (`min_w <= preferred_w <= max_w` — `normalize` 가 맞춘다).
        min_w: T,
        preferred_w: T,
        max_w: T,
        /// 본문이 쓸 수 있는 최대 높이 — 화면에 남은 높이와 화면의 절반 중 작은 쪽
        /// (`ui_metrics.DIALOG_BODY_MAX_SCREEN_PERCENT`). 이보다 높으면 스크롤한다.
        body_max_h: T,
        /// 스크롤할 때 글 폭에서 빼는 스크롤바 자리. 스크롤바가 글 영역 밖에 붙거나 OS 위젯이
        /// 스스로 다시 접으면 0 이다.
        scrollbar_w: T = 0,

        /// 화면이 아주 좁아 최소 폭이 최대 폭을 넘는 경우 등을 정리한다.
        pub fn normalize(self: @This()) @This() {
            var out = self;
            out.max_w = @max(out.max_w, 1);
            out.min_w = @min(@max(out.min_w, 1), out.max_w);
            out.preferred_w = @min(@max(out.preferred_w, out.min_w), out.max_w);
            return out;
        }
    };
}

pub fn Fit(comptime T: type) type {
    return struct {
        /// 글 영역 폭. 창은 여기에 여백 · 테두리 · 그림자를 더한다.
        width: T,
        /// 줄을 접는 폭. 스크롤바가 글 영역 안에 서면 `width - scrollbar_w`, 아니면 `width`.
        wrap_width: T,
        /// `wrap_width` 에서 접은 본문 전체의 높이.
        height: T,
        /// 화면에 보이는 본문 높이 (`min(height, body_max_h)`).
        visible_height: T,
        /// 본문이 상한을 넘어 스크롤해야 하는지.
        scroll: bool,
        /// 높이 때문에 최대 폭으로 넓혔는지 (규칙 3).
        widened_for_height: bool,
    };
}

/// `measurer` 는 두 메서드를 가진다 —
/// `naturalWidth() T` (본문을 접지 않았을 때 가장 긴 줄의 폭. 글 영역 안쪽 여백이 있으면 포함한다),
/// `wrappedHeight(width: T) T` (그 폭에서 접은 본문 높이).
pub fn fit(comptime T: type, measurer: anytype, raw_limits: Limits(T)) Fit(T) {
    const limits = raw_limits.normalize();
    const natural = measurer.naturalWidth();

    // 규칙 1 · 2.
    var width: T = if (natural <= limits.max_w) @max(natural, limits.min_w) else limits.preferred_w;
    var height = measurer.wrappedHeight(width);

    // 규칙 3. 접힌 줄이 있을 때만 넓힌다 — 규칙 1 로 가장 긴 줄 폭을 잡았으면 접힌 줄이 없어서
    // 넓혀도 높이가 그대로이고 창만 넓어진다 (#795 macOS 권한 안내 창: 629 → 960, 높이 504 그대로).
    var widened = false;
    if (height > limits.body_max_h and width < limits.max_w and natural > width) {
        width = limits.max_w;
        height = measurer.wrappedHeight(width);
        widened = true;
    }

    // 규칙 4.
    const scroll = height > limits.body_max_h;
    var wrap_width = width;
    if (scroll and limits.scrollbar_w > 0) {
        wrap_width = @max(width - limits.scrollbar_w, 1);
        height = measurer.wrappedHeight(wrap_width);
    }

    return .{
        .width = width,
        .wrap_width = wrap_width,
        .height = height,
        .visible_height = @min(height, limits.body_max_h),
        .scroll = scroll,
        .widened_for_height = widened,
    };
}

// ── 테스트 ───────────────────────────────────────────────────────────────────

/// 줄마다 글자 하나가 폭 1, 줄 높이 10 인 측정기. 줄바꿈은 낱말 경계 없이 폭으로만 나눈다 —
/// 규칙만 보는 테스트라 그것으로 충분하다.
const LinesMeasurer = struct {
    lines: []const usize,

    fn naturalWidth(self: LinesMeasurer) i32 {
        var longest: usize = 0;
        for (self.lines) |n| longest = @max(longest, n);
        return @intCast(longest);
    }

    fn wrappedHeight(self: LinesMeasurer, width: i32) i32 {
        const w: usize = @intCast(@max(width, 1));
        var rows: usize = 0;
        for (self.lines) |n| rows += @max(1, (n + w - 1) / w);
        return @intCast(10 * rows);
    }
};

const test_limits = Limits(i32){ .min_w = 32, .preferred_w = 58, .max_w = 96, .body_max_h = 100 };

test "#795 short text shrinks to its own width but not below the minimum" {
    const got = fit(i32, LinesMeasurer{ .lines = &.{ 40, 10 } }, test_limits);
    try std.testing.expectEqual(@as(i32, 40), got.width);
    try std.testing.expectEqual(@as(i32, 20), got.height);
    try std.testing.expect(!got.scroll);

    const tiny = fit(i32, LinesMeasurer{ .lines = &.{5} }, test_limits);
    try std.testing.expectEqual(@as(i32, 32), tiny.width);
}

test "#795 a line that fits the maximum widens the box to that line" {
    // 기본 폭 (58) 보다 길지만 최대 폭 (96) 안 — 그 줄이 들어가는 폭까지 넓히고 접지 않는다.
    const got = fit(i32, LinesMeasurer{ .lines = &.{ 67, 20 } }, test_limits);
    try std.testing.expectEqual(@as(i32, 67), got.width);
    try std.testing.expectEqual(@as(i32, 20), got.height);
    try std.testing.expect(!got.widened_for_height);
}

test "#795 a line longer than the maximum wraps at the preferred width" {
    // 최대 폭으로도 한 줄에 안 들어가면 넓히지 않고 기본 폭에서 접는다 — 긴 문장이 화면 절반을
    // 차지하지 않게.
    const got = fit(i32, LinesMeasurer{ .lines = &.{150} }, test_limits);
    try std.testing.expectEqual(@as(i32, 58), got.width);
    try std.testing.expectEqual(@as(i32, 30), got.height);
}

test "#795 a body taller than the cap widens to the maximum before it scrolls" {
    // 기본 폭에서 11 줄 (110 > 100) — 최대 폭으로 넓히면 6 줄이라 스크롤하지 않는다.
    const got = fit(i32, LinesMeasurer{ .lines = &.{ 150, 150, 150, 150, 10 } }, test_limits);
    try std.testing.expectEqual(@as(i32, 96), got.width);
    try std.testing.expect(got.widened_for_height);
    try std.testing.expect(!got.scroll);
    try std.testing.expectEqual(@as(i32, 90), got.height);
}

test "#795 a tall body with no wrapped line does not widen" {
    // 가장 긴 줄 (70) 이 최대 폭 안이라 70 폭에서 접는 줄이 없다. 12 줄 (120 > 100) 이라 높이는
    // 넘치지만, 넓혀도 줄 수가 같으니 70 에 머물러 스크롤한다.
    const lines = [_]usize{ 70, 70, 70, 70, 70, 70, 70, 70, 70, 70, 70, 70 };
    const got = fit(i32, LinesMeasurer{ .lines = &lines }, test_limits);
    try std.testing.expectEqual(@as(i32, 70), got.width);
    try std.testing.expect(!got.widened_for_height);
    try std.testing.expect(got.scroll);
    try std.testing.expectEqual(@as(i32, 120), got.height);
}

test "#795 still too tall scrolls and rewraps inside the scrollbar" {
    var limits = test_limits;
    limits.scrollbar_w = 6;
    const lines = [_]usize{ 96, 96, 96, 96, 96, 96, 96, 96, 96, 96, 96, 96 };
    const got = fit(i32, LinesMeasurer{ .lines = &lines }, limits);
    try std.testing.expect(got.scroll);
    try std.testing.expectEqual(@as(i32, 96), got.width);
    try std.testing.expectEqual(@as(i32, 90), got.wrap_width);
    // 90 폭에서 줄마다 2 행 — 240. 보이는 것은 상한 100.
    try std.testing.expectEqual(@as(i32, 240), got.height);
    try std.testing.expectEqual(@as(i32, 100), got.visible_height);
}

test "#795 limits are normalized on a screen narrower than the minimum" {
    const narrow = Limits(i32){ .min_w = 32, .preferred_w = 58, .max_w = 20, .body_max_h = 100 };
    const got = fit(i32, LinesMeasurer{ .lines = &.{5} }, narrow);
    try std.testing.expectEqual(@as(i32, 20), got.width);
}

test "#795 the same rules work in AppKit points (f64)" {
    const F = struct {
        fn naturalWidth(_: @This()) f64 {
            return 600.5;
        }
        fn wrappedHeight(_: @This(), width: f64) f64 {
            return if (width >= 600.5) 18.0 else 36.0;
        }
    };
    const got = fit(f64, F{}, .{ .min_w = 320, .preferred_w = 580, .max_w = 960, .body_max_h = 500 });
    try std.testing.expectEqual(@as(f64, 600.5), got.width);
    try std.testing.expectEqual(@as(f64, 18.0), got.height);
}
