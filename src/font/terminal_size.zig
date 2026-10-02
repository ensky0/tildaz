//! #693 — 터미널 글자 크기의 실행 중 상태. Linux · macOS · Windows 공통.
//!
//! 설정값 (`font.size_point` 등 → `Config.terminalFontSpec()`) 과 지금 쓰는 크기를 함께
//! 들고, 폰트를 만드는 쪽에는 `spec()` 하나만 내준다. 세 host 의 renderer 는 이 값을
//! `rebuildFonts` 로 받는다 — 크기를 config 나 renderer 필드에서 각자 읽지 않는다.

const std = @import("std");
const font_spec = @import("spec.zig");

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
};

test "init starts at the configured size" {
    const base = font_spec.Spec{ .size_logical = 15.0, .cell_width_ratio = 1.0, .line_height_ratio = 1.1 };
    const fs = TerminalFontSize.init(base);
    const s = fs.spec();
    try std.testing.expectEqual(@as(f32, 15.0), s.size_logical);
    try std.testing.expectEqual(@as(f32, 1.0), s.cell_width_ratio);
    try std.testing.expectEqual(@as(f32, 1.1), s.line_height_ratio);
}
