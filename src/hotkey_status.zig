//! 새 인스턴스 창의 상태 문구 — 문구를 고르는 일과 그 문구가 놓일 자리를 정하는 일
//! ([#721](https://github.com/ensky0/tildaz/issues/721)).
//!
//! Linux · macOS · Windows 가 이 모듈 하나를 같이 쓴다. OS 마다 다른 것은 **글자를 재는
//! 방법뿐**이라 그것만 측정기로 받는다 (`fit`). 렌더러 · OS API 를 모르는 순수 모듈이다 —
//! Linux 의 `dialog_layout.zig` 도 이것을 쓴다.
//!
//! 문구 자체는 `messages.zig` 가 정한다. 여기는 **어떤 문구가 나올 수 있는지** 를 한 곳에
//! 모은다 — `message` 가 고를 수 있는 값과 `candidates` 가 같은 파일에 나란히 있어야
//! 문구가 늘 때 자리 계산이 함께 따라간다.

const std = @import("std");
const messages = @import("messages.zig");

/// "잘못된 키" 상태는 없다 (#721). 검증에 들어가는 글자는 세 OS 모두 캡처
/// (`config.capturedHotkeyText`) 에서만 오고, 캡처는 허용되지 않는 키를 거르며 낸 글자는
/// 다시 해석된다 — 그런 문구는 나올 수 없는데 가장 길어서 창을 넓히고 빈 줄을 만들었다.
pub const HotkeyValidation = union(enum) {
    available,
    duplicate: u32,
    check_failed,
};

/// 다른 인스턴스 번호의 상한. `instances.max_config_index` 와 같아야 한다 — 그쪽 테스트가
/// 대조한다 (이 모듈이 `instances.zig` 를 끌어오면 순수 모듈이 아니게 된다).
pub const max_index: u32 = 9;

pub fn message(buf: []u8, result: HotkeyValidation) []const u8 {
    return switch (result) {
        .available => "",
        .duplicate => |index| std.fmt.bufPrint(buf, messages.new_instance_hotkey_duplicate_format, .{index}) catch messages.new_instance_hotkey_duplicate_fallback,
        .check_failed => messages.new_instance_hotkey_check_failed_msg,
    };
}

/// 상태 칸에 나올 수 있는 문구 **전부**. 번호 문구는 0 부터 상한까지 하나씩 넣는다 —
/// 비례폭 글꼴은 숫자마다 폭이 다를 수 있어서, 대표 하나로 재면 근사가 된다.
pub const candidates: [2 + max_index + 1][]const u8 = blk: {
    var list: [2 + max_index + 1][]const u8 = undefined;
    list[0] = messages.new_instance_hotkey_check_failed_msg;
    list[1] = messages.new_instance_hotkey_duplicate_fallback;
    for (0..max_index + 1) |i| {
        list[2 + i] = std.fmt.comptimePrint(messages.new_instance_hotkey_duplicate_format, .{i});
    }
    const final = list;
    break :blk final;
};

pub fn Fit(comptime T: type) type {
    return struct {
        /// 상태 칸의 폭. 문구는 이 폭에서 줄바꿈하고 줄마다 가운데에 놓는다.
        width: T,
        /// 상태 칸의 높이. 후보 중 가장 큰 높이라 어떤 문구가 와도 창 크기가 그대로다.
        height: T,
    };
}

/// 상태 칸의 자리를 정한다 (#721 의 2026-10-10 사용자 결정).
///
/// - 가장 긴 후보가 `cap` (본문의 기본 폭) 안에 들면 그 폭이다 — 모든 후보가 한 줄이다.
///   호출자는 창을 이 폭까지 넓힌다.
/// - 넘으면 `cap` 에서 줄바꿈한다.
/// - 높이는 후보 중 가장 큰 높이다. 키를 누를 때마다 창 크기가 바뀌지 않게 미리 잡는다.
///
/// `measurer` 는 두 메서드를 가진다 — `naturalWidth(text) T` (한 줄로 둔 폭) 와
/// `wrappedHeight(text, width: T) T` (그 폭에서 줄바꿈한 높이).
pub fn fit(comptime T: type, measurer: anytype, cap: T) Fit(T) {
    var longest: T = 0;
    for (candidates) |text| longest = @max(longest, measurer.naturalWidth(text));
    const width = @min(longest, cap);
    var height: T = 0;
    for (candidates) |text| height = @max(height, measurer.wrappedHeight(text, width));
    return .{ .width = width, .height = height };
}

test "message identifies the conflicting TildaZ instance" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", message(&buf, .available));
    try std.testing.expectEqualStrings("Already used by TildaZ 3.", message(&buf, .{ .duplicate = 3 }));
    try std.testing.expectEqualStrings(messages.new_instance_hotkey_check_failed_msg, message(&buf, .check_failed));
}

test "#721 candidates cover every status message that can appear" {
    const has = struct {
        fn f(text: []const u8) bool {
            for (candidates) |c| if (std.mem.eql(u8, c, text)) return true;
            return false;
        }
    }.f;
    var buf: [128]u8 = undefined;
    try std.testing.expect(has(message(&buf, .check_failed)));
    for (0..max_index + 1) |i| try std.testing.expect(has(message(&buf, .{ .duplicate = @intCast(i) })));
    // 버퍼가 모자라면 번호 없는 문구로 물러선다 — 그것도 후보다.
    var tiny: [4]u8 = undefined;
    try std.testing.expect(has(message(&tiny, .{ .duplicate = 3 })));
}

/// 글자 하나가 폭 1 · 줄 높이 10 인 측정기. 줄바꿈은 낱말 경계 없이 폭으로만 나눈다 —
/// 규칙 함수만 보는 테스트라 그것으로 충분하다.
const FixedMeasurer = struct {
    fn naturalWidth(_: FixedMeasurer, text: []const u8) i32 {
        return @intCast(text.len);
    }
    fn wrappedHeight(_: FixedMeasurer, text: []const u8, width: i32) i32 {
        const w: usize = @intCast(@max(width, 1));
        return @intCast(10 * @max(1, (text.len + w - 1) / w));
    }
};

test "#721 fit keeps every candidate on one line when the longest fits the cap" {
    var longest: usize = 0;
    for (candidates) |c| longest = @max(longest, c.len);
    const got = fit(i32, FixedMeasurer{}, 1000);
    try std.testing.expectEqual(@as(i32, @intCast(longest)), got.width);
    try std.testing.expectEqual(@as(i32, 10), got.height);
}

test "#721 fit wraps at the cap and reserves the tallest candidate" {
    var longest: usize = 0;
    for (candidates) |c| longest = @max(longest, c.len);
    // 가장 긴 후보보다 좁은 폭 — 그 폭에서 줄바꿈하고, 가장 긴 후보의 줄 수만큼 잡는다.
    const cap: i32 = @intCast(longest - 1);
    const got = fit(i32, FixedMeasurer{}, cap);
    try std.testing.expectEqual(cap, got.width);
    const rows: i32 = @intCast((longest + longest - 2) / (longest - 1));
    try std.testing.expectEqual(10 * rows, got.height);
}
