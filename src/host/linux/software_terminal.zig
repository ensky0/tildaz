//! Temporary Linux bring-up renderer.
//!
//! Software-only — paints ghostty-vt render state into a Wayland `wl_shm`
//! XRGB8888 buffer. 진짜 GPU renderer (EGL/OpenGL) 로 갈 때까지의 bring-up 코드.
//! Glyph 는 fontconfig + FreeType 으로 raster (ASCII 만 pre-cached, [font/linux/font.zig](../../font/linux/font.zig)).

const std = @import("std");
const ghostty = @import("ghostty-vt");
const themes = @import("../../themes.zig");
const font = @import("../../font/linux/font.zig");

pub const padding_px: i32 = 8;
/// 우측 스크롤바 너비 — Windows / macOS 의 `ui_metrics.SCROLLBAR_W_PT = 8` 과 동일.
pub const scrollbar_w_px: i32 = 8;
/// thumb 최소 높이 — scrollback 이 길어 ratio 작아져도 클릭 가능한 영역 확보.
pub const scrollbar_min_thumb_h: i32 = 20;
const scrollbar_thumb_color = ghostty.color.RGB{ .r = 96, .g = 96, .b = 96 };

/// 임시 raster pixel height. font.size_point 설정과 통합은 별도 sub-task.
const default_pixel_height: u32 = 16;

/// 임시 default font chain. config.font.family / font.glyph_fallback 통합은
/// 별도 sub-task — Win/mac 처럼 config 에서 받기. 현재는 generic "monospace"
/// 만 — fontconfig 가 시스템 default 매치 (Debian 환경에선 NotoSansCJK 라
/// Hangul / CJK ASCII 모두 같은 face).
const default_families = [_][]const u8{"monospace"};

pub const Renderer = struct {
    render_state: ghostty.RenderState = .empty,
    font_ctx: font.Context,

    pub fn init(allocator: std.mem.Allocator) !Renderer {
        return .{
            .render_state = .empty,
            .font_ctx = try font.Context.init(allocator, &default_families, default_pixel_height),
        };
    }

    pub fn deinit(self: *Renderer, allocator: std.mem.Allocator) void {
        self.render_state.deinit(allocator);
        self.font_ctx.deinit();
    }

    pub fn cellWidth(self: *const Renderer) i32 {
        return @intCast(self.font_ctx.cell_width_px);
    }

    pub fn cellHeight(self: *const Renderer) i32 {
        return @intCast(self.font_ctx.cell_height_px);
    }

    pub fn paint(
        self: *Renderer,
        allocator: std.mem.Allocator,
        memory: []u8,
        width: i32,
        height: i32,
        stride: i32,
        terminal: *ghostty.Terminal,
        theme: *const themes.Theme,
    ) void {
        self.render_state.update(allocator, terminal) catch {
            fill(memory, width, height, stride, theme.background);
            return;
        };

        const colors = self.render_state.colors;
        fill(memory, width, height, stride, colors.background);

        const cw = self.cellWidth();
        const ch = self.cellHeight();
        const ascent: i32 = @intCast(self.font_ctx.ascent_px);

        const rows = self.render_state.rows;
        const cols = self.render_state.cols;
        const row_slice = self.render_state.row_data.slice();
        const all_cells = row_slice.items(.cells);
        const all_sels = row_slice.items(.selection);

        for (0..rows) |y| {
            if (y >= all_cells.len) break;
            const cell_slice = all_cells[y].slice();
            const raws = cell_slice.items(.raw);
            const styles = cell_slice.items(.style);
            const sel_range: ?[2]u16 = if (y < all_sels.len) all_sels[y] else null;

            for (0..cols) |x| {
                if (x >= raws.len) break;
                const raw = raws[x];
                if (raw.wide == .spacer_tail or raw.wide == .spacer_head) continue;

                const style = if (raw.style_id != 0) styles[x] else ghostty.Style{};
                const x16: u16 = @intCast(x);
                const is_selected = if (sel_range) |sr| (x16 >= sr[0] and x16 <= sr[1]) else false;
                const bg = resolveBg(style, &raw, &colors, is_selected);
                const cell_x: i32 = padding_px + @as(i32, @intCast(x)) * cw;
                const cell_y: i32 = padding_px + @as(i32, @intCast(y)) * ch;
                const cell_w: i32 = if (raw.wide == .wide) cw * 2 else cw;

                if (is_selected or style.flags.inverse or style.bg(&raw, &colors.palette) != null) {
                    rect(memory, width, height, stride, cell_x, cell_y, cell_w, ch, bg);
                }

                if (!raw.hasText() or raw.codepoint() == 0) continue;
                const fg = resolveFg(style, &colors, is_selected);
                const glyph = self.font_ctx.glyph(raw.codepoint());
                const baseline = cell_y + ascent;
                // proportional 폰트 (`fc-match monospace` 가 NotoSansCJK 같은 sans-serif
                // 로 매치되는 환경 등) 라도 글자가 cell 안 가운데에 균일하게 분포하도록
                // advance-center 정렬. monospace 면 글리프 advance == cell width 라 offset
                // = 0 (그대로). wide glyph 의 fallback (placeholder '?') 도 cell-pair 가운데로.
                const glyph_advance_i32: i32 = @intCast(glyph.advance);
                const center_off: i32 = @divFloor(cell_w - glyph_advance_i32, 2);
                drawGlyph(
                    memory,
                    width,
                    height,
                    stride,
                    cell_x + center_off + glyph.bitmap_left,
                    baseline - glyph.bitmap_top,
                    glyph,
                    fg,
                    bg,
                );
            }
        }

        if (self.render_state.cursor.visible) {
            if (self.render_state.cursor.viewport) |vp| {
                var cx: i32 = padding_px + @as(i32, @intCast(vp.x)) * cw;
                if (vp.wide_tail and vp.x > 0) cx -= cw;
                const cy: i32 = padding_px + @as(i32, @intCast(vp.y)) * ch;
                const cursor = colors.cursor orelse ghostty.color.RGB{ .r = 180, .g = 180, .b = 180 };
                rect(memory, width, height, stride, cx, cy + ch - 3, cw, 2, cursor);
            }
        }

        // 우측 스크롤바 thumb — scrollback 있을 때만. track 자체는 별도 색 안 그림
        // (배경 그대로). Windows / macOS 패턴 동일 (`renderer/macos.zig:662` 참고).
        const sb = terminal.screens.active.pages.scrollbar();
        if (sb.total > sb.len) {
            const track_h: i32 = height - 2 * padding_px;
            if (track_h > 0) {
                const track_hf: f64 = @floatFromInt(track_h);
                const total_f: f64 = @floatFromInt(sb.total);
                const len_f: f64 = @floatFromInt(sb.len);
                const ratio_px: f64 = track_hf / total_f;
                const min_thumb_f: f64 = @floatFromInt(scrollbar_min_thumb_h);
                const thumb_hf: f64 = @max(min_thumb_f, ratio_px * len_f);
                const available: f64 = track_hf - thumb_hf;
                const max_off_f: f64 = total_f - len_f;
                const offset_f: f64 = @floatFromInt(sb.offset);
                const offset_ratio: f64 = if (max_off_f > 0) offset_f / max_off_f else 0;
                const thumb_y_px: i32 = padding_px + @as(i32, @intFromFloat(offset_ratio * available));
                const thumb_h_px: i32 = @intFromFloat(thumb_hf);
                const sb_x: i32 = width - scrollbar_w_px;
                rect(memory, width, height, stride, sb_x, thumb_y_px, scrollbar_w_px, thumb_h_px, scrollbar_thumb_color);
            }
        }
    }
};

fn resolveFg(style: ghostty.Style, colors: *const ghostty.RenderState.Colors, selected: bool) ghostty.color.RGB {
    if (selected) return colors.background;
    if (style.flags.inverse) return colors.background;
    return style.fg(.{
        .default = colors.foreground,
        .palette = &colors.palette,
        .bold = .bright,
    });
}

fn resolveBg(
    style: ghostty.Style,
    raw: *const ghostty.Cell,
    colors: *const ghostty.RenderState.Colors,
    selected: bool,
) ghostty.color.RGB {
    if (selected) return colors.foreground;
    if (style.flags.inverse) {
        return style.fg(.{
            .default = colors.foreground,
            .palette = &colors.palette,
            .bold = .bright,
        });
    }
    return style.bg(raw, &colors.palette) orelse colors.background;
}

fn fill(memory: []u8, width: i32, height: i32, stride: i32, color: ghostty.color.RGB) void {
    rect(memory, width, height, stride, 0, 0, width, height, color);
}

fn rect(
    memory: []u8,
    width: i32,
    height: i32,
    stride: i32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    color: ghostty.color.RGB,
) void {
    const x0 = @max(0, x);
    const y0 = @max(0, y);
    const x1 = @min(width, x + w);
    const y1 = @min(height, y + h);
    if (x1 <= x0 or y1 <= y0) return;

    const packed_color = pack(color);
    var py = y0;
    while (py < y1) : (py += 1) {
        var px = x0;
        while (px < x1) : (px += 1) {
            const off: usize = @intCast(py * stride + px * 4);
            std.mem.writeInt(u32, memory[off..][0..4], packed_color, .little);
        }
    }
}

/// 8bpp alpha bitmap 을 fg/bg 알파 블렌딩으로 XRGB8888 buffer 에 그린다.
/// glyph buffer 가 비어 있거나 (space) 좌표가 화면 밖이면 무시.
fn drawGlyph(
    memory: []u8,
    width: i32,
    height: i32,
    stride: i32,
    draw_x: i32,
    draw_y: i32,
    glyph: *const font.Glyph,
    fg: ghostty.color.RGB,
    bg: ghostty.color.RGB,
) void {
    if (glyph.width == 0 or glyph.height == 0 or glyph.bitmap.len == 0) return;

    var row: u32 = 0;
    while (row < glyph.height) : (row += 1) {
        var col: u32 = 0;
        while (col < glyph.width) : (col += 1) {
            const alpha = glyph.bitmap[row * glyph.width + col];
            if (alpha == 0) continue;
            const px = draw_x + @as(i32, @intCast(col));
            const py = draw_y + @as(i32, @intCast(row));
            if (px < 0 or py < 0 or px >= width or py >= height) continue;
            const off: usize = @intCast(py * stride + px * 4);
            const blended = blendPixel(fg, bg, alpha);
            std.mem.writeInt(u32, memory[off..][0..4], blended, .little);
        }
    }
}

fn pack(color: ghostty.color.RGB) u32 {
    return (@as(u32, color.r) << 16) | (@as(u32, color.g) << 8) | color.b;
}

fn blendPixel(fg: ghostty.color.RGB, bg: ghostty.color.RGB, alpha: u8) u32 {
    const a: u32 = alpha;
    const inv: u32 = 255 - a;
    const r: u32 = (@as(u32, fg.r) * a + @as(u32, bg.r) * inv) / 255;
    const g: u32 = (@as(u32, fg.g) * a + @as(u32, bg.g) * inv) / 255;
    const b: u32 = (@as(u32, fg.b) * a + @as(u32, bg.b) * inv) / 255;
    return (r << 16) | (g << 8) | b;
}
