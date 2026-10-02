//! #693 — 터미널 글자 크기의 실행 중 상태. Linux · macOS · Windows 공통.
//!
//! 설정값 (`font.size_point` 등 → `Config.terminalFontSpec()`) 과 지금 쓰는 크기를 함께
//! 들고, 폰트를 만드는 쪽에는 `spec()` 하나만 내준다. 세 host 의 renderer 는 이 값을
//! `rebuildFonts` 로 받는다 — 크기를 config 나 renderer 필드에서 각자 읽지 않는다.
//!
//! 단축키 (`increase_font_size` 등) 는 창 전체에 한 번 적용된다 — 모든 탭 · pane 이 같은
//! 크기다. 재시작하면 설정값으로 돌아간다 (config 에 쓰지 않는다).

const std = @import("std");
const font_spec = @import("spec.zig");

/// 글자 크기 범위. `font.size_point` 검사 (`config.zig`) 도 이 값을 쓴다 — 단축키로 갈 수
/// 있는 크기와 설정 파일에 적을 수 있는 크기가 갈라지지 않게.
pub const MIN_SIZE_POINT = 8;
pub const MAX_SIZE_POINT = 72;
/// 한 번 누를 때 바뀌는 양. ghostty · Windows Terminal 과 같다 (kitty 는 2).
pub const STEP_POINT = 1;

pub const Change = enum { increase, decrease, reset };

pub const TerminalFontSize = struct {
    /// 설정 파일이 정한 값. 실행 중에 바뀌지 않는다.
    base: font_spec.Spec,
    /// 지금 쓰는 논리 크기 (`Spec.size_logical` 과 같은 단위).
    size_logical: f32,

    pub fn init(base: font_spec.Spec) TerminalFontSize {
        return .{ .base = base, .size_logical = base.size_logical };
    }

    /// 폰트를 만들 때 쓰는 값 — 설정의 비율은 그대로, 크기만 지금 값.
    pub fn spec(self: *const TerminalFontSize) font_spec.Spec {
        var s = self.base;
        s.size_logical = self.size_logical;
        return s;
    }

    /// 크기를 바꾼다. **실제로 바뀌었을 때만 true** — 범위 끝에서 더 누르거나 이미 설정값인데
    /// 되돌리면 false 라, host 는 그때 폰트를 다시 만들지 않는다.
    pub fn apply(self: *TerminalFontSize, change: Change) bool {
        const min: f32 = MIN_SIZE_POINT;
        const max: f32 = MAX_SIZE_POINT;
        const next: f32 = switch (change) {
            .increase => @min(self.size_logical + STEP_POINT, max),
            .decrease => @max(self.size_logical - STEP_POINT, min),
            .reset => self.base.size_logical,
        };
        if (next == self.size_logical) return false;
        self.size_logical = next;
        return true;
    }
};

const test_base = font_spec.Spec{ .size_logical = 15.0, .cell_width_ratio = 1.0, .line_height_ratio = 1.1 };

test "init starts at the configured size" {
    const fs = TerminalFontSize.init(test_base);
    const s = fs.spec();
    try std.testing.expectEqual(@as(f32, 15.0), s.size_logical);
    try std.testing.expectEqual(@as(f32, 1.0), s.cell_width_ratio);
    try std.testing.expectEqual(@as(f32, 1.1), s.line_height_ratio);
}

test "increase · decrease step by one point and keep the ratios" {
    var fs = TerminalFontSize.init(test_base);
    try std.testing.expect(fs.apply(.increase));
    try std.testing.expectEqual(@as(f32, 16.0), fs.spec().size_logical);
    try std.testing.expect(fs.apply(.decrease));
    try std.testing.expect(fs.apply(.decrease));
    try std.testing.expectEqual(@as(f32, 14.0), fs.spec().size_logical);
    try std.testing.expectEqual(@as(f32, 1.1), fs.spec().line_height_ratio);
}

test "reset returns to the configured size and reports no change when already there" {
    var fs = TerminalFontSize.init(test_base);
    try std.testing.expect(!fs.apply(.reset));
    _ = fs.apply(.increase);
    _ = fs.apply(.increase);
    try std.testing.expect(fs.apply(.reset));
    try std.testing.expectEqual(@as(f32, 15.0), fs.spec().size_logical);
}

test "size stays within the config range and reports no change at the ends" {
    var fs = TerminalFontSize.init(.{ .size_logical = MAX_SIZE_POINT, .cell_width_ratio = 1.0, .line_height_ratio = 1.0 });
    try std.testing.expect(!fs.apply(.increase));
    try std.testing.expectEqual(@as(f32, MAX_SIZE_POINT), fs.size_logical);

    fs = TerminalFontSize.init(.{ .size_logical = MIN_SIZE_POINT, .cell_width_ratio = 1.0, .line_height_ratio = 1.0 });
    try std.testing.expect(!fs.apply(.decrease));
    try std.testing.expectEqual(@as(f32, MIN_SIZE_POINT), fs.size_logical);
}
