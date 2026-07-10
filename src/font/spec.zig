//! Cross-platform font sizing contract.
//!
//! `size_logical` intentionally means the same logical size TildaZ already
//! uses for `font.size_point`: physical raster size is `size_logical * scale`.
//! This is not the typographic `1pt = 1/72in` conversion.

const std = @import("std");

pub const Spec = struct {
    size_logical: f32,
    cell_width_ratio: f32,
    line_height_ratio: f32,

    pub fn physicalSizePx(self: Spec, scale: f32) f32 {
        return self.size_logical * scale;
    }

    pub fn physicalSizeRatioPx(self: Spec, scale_num: u32, scale_den: u32) f32 {
        return @floatCast(self.physicalSizeRatio(scale_num, scale_den));
    }

    pub fn physicalSizeCeilPx(self: Spec, scale: f32) u32 {
        return ceilPositivePx(self.physicalSizePx(scale));
    }

    pub fn physicalSizeRatioCeilPx(self: Spec, scale_num: u32, scale_den: u32) u32 {
        return ceilPositivePx(self.physicalSizeRatio(scale_num, scale_den));
    }

    fn physicalSizeRatio(self: Spec, scale_num: u32, scale_den: u32) f64 {
        std.debug.assert(scale_den != 0);
        return @as(f64, self.size_logical) * @as(f64, @floatFromInt(scale_num)) /
            @as(f64, @floatFromInt(scale_den));
    }
};

pub fn ceilPositivePx(value: anytype) u32 {
    const wide: f64 = @floatCast(value);
    return @intFromFloat(@max(1.0, @ceil(wide)));
}

pub fn scaledRatioCeilPx(base: f32, ratio: f32, scale: f32) u32 {
    return ceilPositivePx(base * ratio * scale);
}

test "Spec physical size uses logical size times scale" {
    const spec = Spec{
        .size_logical = 15.0,
        .cell_width_ratio = 1.0,
        .line_height_ratio = 1.1,
    };

    try std.testing.expectApproxEqAbs(@as(f32, 15.0), spec.physicalSizePx(1.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 22.5), spec.physicalSizePx(1.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 25.5), spec.physicalSizePx(1.7), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 30.0), spec.physicalSizePx(2.0), 0.001);
}

test "positive physical px ceil never returns zero" {
    try std.testing.expectEqual(@as(u32, 1), ceilPositivePx(0.0));
    try std.testing.expectEqual(@as(u32, 1), ceilPositivePx(0.01));
    try std.testing.expectEqual(@as(u32, 1), ceilPositivePx(1.0));
    try std.testing.expectEqual(@as(u32, 2), ceilPositivePx(1.01));
    try std.testing.expectEqual(@as(u32, 16), ceilPositivePx(15.0001));
}

test "scaled ratio metric uses ceil after all factors" {
    try std.testing.expectEqual(@as(u32, 11), scaledRatioCeilPx(10.0, 1.0, 1.01));
    try std.testing.expectEqual(@as(u32, 19), scaledRatioCeilPx(17.0, 1.1, 1.0));
    try std.testing.expectEqual(@as(u32, 32), scaledRatioCeilPx(17.0, 1.1, 1.7));
}

test "Spec can ceil physical font size at fractional scale" {
    const spec = Spec{
        .size_logical = 15.0,
        .cell_width_ratio = 1.0,
        .line_height_ratio = 1.1,
    };

    try std.testing.expectEqual(@as(u32, 15), spec.physicalSizeCeilPx(1.0));
    try std.testing.expectEqual(@as(u32, 23), spec.physicalSizeCeilPx(1.5));
    try std.testing.expectEqual(@as(u32, 26), spec.physicalSizeCeilPx(1.7));
    try std.testing.expectEqual(@as(u32, 30), spec.physicalSizeCeilPx(2.0));
}

test "rational scale avoids f32 overshoot at exact integer boundaries" {
    const spec_25 = Spec{
        .size_logical = 25.0,
        .cell_width_ratio = 1.0,
        .line_height_ratio = 1.1,
    };
    const spec_27 = Spec{
        .size_logical = 27.0,
        .cell_width_ratio = 1.0,
        .line_height_ratio = 1.1,
    };

    try std.testing.expectEqual(@as(u32, 30), spec_25.physicalSizeRatioCeilPx(144, 120));
    try std.testing.expectEqual(@as(u32, 117), spec_27.physicalSizeRatioCeilPx(520, 120));
    try std.testing.expectApproxEqAbs(@as(f32, 30.0), spec_25.physicalSizeRatioPx(144, 120), 0.001);
}
