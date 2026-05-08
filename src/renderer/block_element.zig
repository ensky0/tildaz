// Unicode block element + shade pattern → cell-aligned rectangle / procedural
// dot mask. WT / xterm 전통: 폰트 글리프가 cell 너비 1/8 단위로 정확히 안
// 떨어지면 인접 셀 사이 갭 / overlap 이 생기므로 폰트 fallback 대신 코드로
// 직접 그림. shade (░▒▓) 도 폰트 dot pattern 의존성 제거.
//
// Windows (d3d11) 와 macOS (Metal) 양쪽이 이 모듈을 import 해 셀 좌표 →
// instance 변환을 동일 로직으로. 셰이더 procedural pattern 은 platform 별
// 별도 (HLSL / MSL 문법 차이) 지만 indexing 식은 Windows shader (`bg_shader_src`
// in d3d11_renderer.zig) 와 동등.

pub const BlockRect = struct {
    /// Cell 안 fraction (0~1). x0/y0 = 좌상단, x1/y1 = 우하단.
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    /// 항상 1.0 (alpha 변조 없는 solid). 향후 reverse-video 등 토글 위치.
    alpha: f32,
    /// 0 = solid fill. 1/2/3 = U+2591/2/3 LIGHT/MEDIUM/DARK SHADE.
    /// 셰이더가 픽셀 (x,y) 로 procedural dot mask 계산 + discard.
    shade: f32 = 0,
};

/// 셀 cp 가 block element 인지. Renderer 가 text path 와 분기할 때 사용.
pub fn isBlockElement(cp: u21) bool {
    return blockElementRect(cp) != null;
}

/// Solid block (▀▁..▏ ▐ ▔▕) + shade (░▒▓) 의 cell-fraction 좌표.
/// 폰트 무관 — Apple Color Emoji 같은 SBIX 라스터와 무관하게 항상 정확.
pub fn blockElementRect(cp: u21) ?BlockRect {
    return switch (cp) {
        0x2580 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 0.5, .alpha = 1 },
        0x2581 => .{ .x0 = 0, .y0 = 7.0 / 8.0, .x1 = 1, .y1 = 1, .alpha = 1 },
        0x2582 => .{ .x0 = 0, .y0 = 6.0 / 8.0, .x1 = 1, .y1 = 1, .alpha = 1 },
        0x2583 => .{ .x0 = 0, .y0 = 5.0 / 8.0, .x1 = 1, .y1 = 1, .alpha = 1 },
        0x2584 => .{ .x0 = 0, .y0 = 4.0 / 8.0, .x1 = 1, .y1 = 1, .alpha = 1 },
        0x2585 => .{ .x0 = 0, .y0 = 3.0 / 8.0, .x1 = 1, .y1 = 1, .alpha = 1 },
        0x2586 => .{ .x0 = 0, .y0 = 2.0 / 8.0, .x1 = 1, .y1 = 1, .alpha = 1 },
        0x2587 => .{ .x0 = 0, .y0 = 1.0 / 8.0, .x1 = 1, .y1 = 1, .alpha = 1 },
        0x2588 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 1 },
        0x2589 => .{ .x0 = 0, .y0 = 0, .x1 = 7.0 / 8.0, .y1 = 1, .alpha = 1 },
        0x258A => .{ .x0 = 0, .y0 = 0, .x1 = 6.0 / 8.0, .y1 = 1, .alpha = 1 },
        0x258B => .{ .x0 = 0, .y0 = 0, .x1 = 5.0 / 8.0, .y1 = 1, .alpha = 1 },
        0x258C => .{ .x0 = 0, .y0 = 0, .x1 = 4.0 / 8.0, .y1 = 1, .alpha = 1 },
        0x258D => .{ .x0 = 0, .y0 = 0, .x1 = 3.0 / 8.0, .y1 = 1, .alpha = 1 },
        0x258E => .{ .x0 = 0, .y0 = 0, .x1 = 2.0 / 8.0, .y1 = 1, .alpha = 1 },
        0x258F => .{ .x0 = 0, .y0 = 0, .x1 = 1.0 / 8.0, .y1 = 1, .alpha = 1 },
        0x2590 => .{ .x0 = 0.5, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 1 },
        0x2591 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 1, .shade = 1 },
        0x2592 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 1, .shade = 2 },
        0x2593 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 1, .shade = 3 },
        0x2594 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1.0 / 8.0, .alpha = 1 },
        0x2595 => .{ .x0 = 7.0 / 8.0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 1 },
        else => null,
    };
}
