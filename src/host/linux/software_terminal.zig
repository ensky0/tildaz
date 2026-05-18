//! Temporary Linux bring-up renderer.
//!
//! Software-only — paints ghostty-vt render state into a Wayland `wl_shm`
//! XRGB8888 buffer. 진짜 GPU renderer (EGL/OpenGL) 로 갈 때까지의 bring-up 코드.
//! Glyph 는 fontconfig + FreeType 으로 raster (ASCII 만 pre-cached, [font/linux/font.zig](../../font/linux/font.zig)).

const std = @import("std");
const ghostty = @import("ghostty-vt");
const themes = @import("../../themes.zig");
const font = @import("../../font/linux/font.zig");
const freetype = @import("../../font/linux/freetype.zig");
const block_element = @import("../../renderer/block_element.zig");
const display_width = @import("../../font/display_width.zig");
const config_mod = @import("../../config.zig");
const ui_metrics = @import("../../ui_metrics.zig");

pub const padding_px: i32 = 8;
/// 우측 스크롤바 너비 — Windows / macOS 의 `ui_metrics.SCROLLBAR_W_PT = 8` 과 동일.
pub const scrollbar_w_px: i32 = 8;
/// thumb 최소 높이 — scrollback 이 길어 ratio 작아져도 클릭 가능한 영역 확보.
pub const scrollbar_min_thumb_h: i32 = 20;
const scrollbar_thumb_color = ghostty.color.RGB{ .r = 96, .g = 96, .b = 96 };

/// `config.font_size_point` 의미는 cross-platform 동등 — Windows host 의
/// `font_height_px = font_size_point × DPI_scale` 식, macOS host 의 logical
/// pixel 그대로 사용 패턴과 같이 **96 DPI 의 logical pixel** 의미. 표준
/// typographic 1pt = 1/72 inch 변환 (× 96/72) 을 다시 곱하면 Win/Mac 대비
/// 1.33x 큰 cell 이 되어 사용자가 "Linux 글자가 크다" 고 느낌 (사용자 보고).
/// 따라서 1:1. fractional / output scale 통합은 후속 sub-step.
fn fontPixelHeight(size_point: u8) u32 {
    return @intCast(size_point);
}

pub const Renderer = struct {
    render_state: ghostty.RenderState = .empty,
    font_ctx: font.Context,
    /// L10-β — IME 조합 중 (preedit) 텍스트. host (wayland_minimal) 가 매
    /// `done` batch 적용 시점에 갱신한다. 빈 slice = 조합 중 아님. storage 는
    /// host 가 소유 — Renderer 는 view 만 빌린다 (paint 호출 동안 valid 보장).
    preedit_text: []const u8 = "",
    /// L13-γ — 매 픽셀의 alpha byte (ARGB8888 의 high byte). `config.opacity_
    /// alpha` 가 그대로. 100% → 255 (완전 opaque, 시각 변화 없음), <100 →
    /// compositor 가 배경과 alpha blending. `Client.init` 에서 채움.
    opacity_alpha: u8 = 255,

    pub fn init(allocator: std.mem.Allocator, cfg: *const config_mod.Config) !Renderer {
        const chain = cfg.font_families[0..cfg.font_family_count];
        const pixel_height = fontPixelHeight(cfg.font_size_point);
        return .{
            .render_state = .empty,
            .font_ctx = try font.Context.init(
                allocator,
                chain,
                pixel_height,
                cfg.cell_width_ratio,
                cfg.line_height_ratio,
            ),
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

    /// Tab bar 높이 (logical pixel). cell grid 가 이 높이 만큼 아래로 밀린다.
    /// Linux 는 1pt = 1px (96 DPI 가정) — fractional scale 통합은 후속.
    pub const tab_bar_height_px: i32 = @intCast(ui_metrics.TAB_BAR_HEIGHT_PT);

    pub fn paint(
        self: *Renderer,
        allocator: std.mem.Allocator,
        memory: []u8,
        width: i32,
        height: i32,
        stride: i32,
        terminal: *ghostty.Terminal,
        theme: *const themes.Theme,
        tab_titles: []const []const u8,
        active_tab_idx: usize,
    ) void {
        self.render_state.update(allocator, terminal) catch {
            fill(memory, width, height, stride, theme.background);
            return;
        };

        const colors = self.render_state.colors;
        fill(memory, width, height, stride, colors.background);

        // L12-α/β — 상단 tab bar 영역. 활성 + 비활성 탭 표시. arrow / plus /
        // 스크롤 layout 은 L12-γ scope (탭 폭 합이 화면 폭 넘어가면 단순
        // truncate). 비활성 탭 배경은 terminal background 와 같은 색 — cell
        // 영역과 자연 이음 (Windows 패턴 동일).
        drawTabBar(memory, width, height, stride, tab_bar_height_px, tab_titles, active_tab_idx, colors.background, &self.font_ctx);

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
                const cell_y: i32 = tab_bar_height_px + padding_px + @as(i32, @intCast(y)) * ch;
                const cell_w: i32 = if (raw.wide == .wide) cw * 2 else cw;

                if (is_selected or style.flags.inverse or style.bg(&raw, &colors.palette) != null) {
                    rect(memory, width, height, stride, cell_x, cell_y, cell_w, ch, bg);
                }

                if (!raw.hasText() or raw.codepoint() == 0) continue;
                const fg = resolveFg(style, &colors, is_selected);
                const cp = raw.codepoint();

                // Block element + shade — cell-aligned procedural rectangle / dot
                // mask. 폰트 fallback (FreeType raster) 대신 공유 모듈로 그려서
                // 인접 셀 사이 갭 / overlap 제거. Windows d3d11 / macOS Metal 가
                // 같은 모듈을 동일 의미로 사용 ([renderer/windows.zig], [renderer/macos.zig]).
                if (block_element.blockElementRect(cp)) |br| {
                    drawBlockRect(memory, width, height, stride, cell_x, cell_y, cell_w, ch, br, fg);
                    continue;
                }

                const glyph = self.font_ctx.glyph(cp);
                if (glyph.pixel_mode == freetype.FT_PIXEL_MODE_BGRA) {
                    // color emoji — bitmap 이 보통 strike size (~109px) 라 cell 안 ratio
                    // 유지 scale down + cell 가운데 fit. emoji 색 자체 사용 (fg 무시).
                    drawGlyphBgra(memory, width, height, stride, cell_x, cell_y, cell_w, ch, glyph);
                } else {
                    // proportional 폰트 (`fc-match monospace` 가 NotoSansCJK 같은 sans-serif
                    // 로 매치되는 환경 등) 라도 글자가 cell 안 가운데에 균일하게 분포하도록
                    // advance-center 정렬. monospace 면 글리프 advance == cell width 라 offset
                    // = 0 (그대로). wide glyph 의 fallback (placeholder '?') 도 cell-pair 가운데로.
                    const baseline = cell_y + ascent;
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
        }

        if (self.render_state.cursor.visible) {
            if (self.render_state.cursor.viewport) |vp| {
                var cx: i32 = padding_px + @as(i32, @intCast(vp.x)) * cw;
                if (vp.wide_tail and vp.x > 0) cx -= cw;
                const cy: i32 = tab_bar_height_px + padding_px + @as(i32, @intCast(vp.y)) * ch;
                const cursor = colors.cursor orelse ghostty.color.RGB{ .r = 180, .g = 180, .b = 180 };
                rect(memory, width, height, stride, cx, cy + ch - 3, cw, 2, cursor);
            }
        }

        // 우측 스크롤바 thumb — scrollback 있을 때만. track 자체는 별도 색 안 그림
        // (배경 그대로). Windows / macOS 패턴 동일 (`renderer/macos.zig:662` 참고).
        const sb = terminal.screens.active.pages.scrollbar();
        if (sb.total > sb.len) {
            const track_h: i32 = height - tab_bar_height_px - 2 * padding_px;
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
                const thumb_y_px: i32 = tab_bar_height_px + padding_px + @as(i32, @intFromFloat(offset_ratio * available));
                const thumb_h_px: i32 = @intFromFloat(thumb_hf);
                const sb_x: i32 = width - scrollbar_w_px;
                rect(memory, width, height, stride, sb_x, thumb_y_px, scrollbar_w_px, thumb_h_px, scrollbar_thumb_color);
            }
        }

        // --- L10-β: IME preedit (조합 중) inline overlay ---
        // cursor 위치부터 preedit_text 의 codepoint 별로 보라색 배경 + foreground
        // 글자. AGENTS.md "한글 IME 동작 스펙" — "강조 배경 (보라색 계열) + 글자
        // 로 inline 표시. 별도 candidate window 안 띄움". macOS / Windows 와
        // 동등 색 (`renderer/macos.zig:686`, `renderer/windows.zig:1144`).
        // PTY 에는 들어가지 않고 화면 표시만 — fcitx5 가 commit_string 으로
        // 음절 완성 보내주면 그때 PTY 송신 + preedit 클리어.
        if (self.preedit_text.len > 0) {
            if (self.render_state.cursor.viewport) |vp| {
                drawPreeditOverlay(
                    memory,
                    width,
                    height,
                    stride,
                    cw,
                    ch,
                    ascent,
                    @intCast(vp.x),
                    @intCast(vp.y),
                    cols,
                    self.preedit_text,
                    colors.foreground,
                    &self.font_ctx,
                );
            }
        }

        // --- L13-γ: opacity alpha sweep ---
        // ARGB8888 buffer 의 alpha byte 를 self.opacity_alpha 로 일괄 채움.
        // pack / rect / drawGlyph / drawGlyphBgra 등 모든 pixel write 함수가
        // RGB 만 채우고 alpha byte (high byte) 는 0 으로 두는 대신, paint
        // 마지막에 한 번 sweep — 함수 시그니처 / 호출 site 의 변경 폭을
        // 줄이고 alpha 미적용 누락도 자동으로 막힘. opacity=255 (= 100%) 면
        // 시각 변화 없음 — compositor 가 fully opaque 로 합성.
        {
            const opacity = self.opacity_alpha;
            var py: i32 = 0;
            while (py < height) : (py += 1) {
                var px: i32 = 0;
                while (px < width) : (px += 1) {
                    const off: usize = @intCast(py * stride + px * 4);
                    memory[off + 3] = opacity;
                }
            }
        }
    }
};

/// L12-α/β tab bar — 상단 (0, 0, width, tab_bar_h) 영역에 배경 (`TAB_BAR_BG`)
/// 채움 + 각 탭 (좌측부터 `TAB_WIDTH_PT` 너비) 을 활성/비활성 색 으로 그리고
/// title text. 비활성 탭은 terminal background 와 같은 색 — cell 영역과 자연
/// 이음 (Windows 패턴 동일, 활성 탭만 두드러짐). arrow / plus / 스크롤 layout
/// 은 L12-γ scope (탭 폭 합이 화면 폭 넘어가면 단순 truncate).
fn drawTabBar(
    memory: []u8,
    fb_w: i32,
    fb_h: i32,
    stride: i32,
    tab_bar_h: i32,
    titles: []const []const u8,
    active_idx: usize,
    inactive_bg: ghostty.color.RGB,
    font_ctx: *font.Context,
) void {
    if (tab_bar_h <= 0 or fb_w <= 0 or titles.len == 0) return;
    const tab_bar_bg = rgbFromMetrics(ui_metrics.TAB_BAR_BG);
    rect(memory, fb_w, fb_h, stride, 0, 0, fb_w, tab_bar_h, tab_bar_bg);

    const tab_w: i32 = @intCast(ui_metrics.TAB_WIDTH_PT);
    const tab_pad: i32 = @intCast(ui_metrics.TAB_PADDING_PT);
    const active_bg = rgbFromMetrics(ui_metrics.TAB_ACTIVE_BG);
    const text_color = rgbFromMetrics(ui_metrics.TAB_TEXT_COLOR);
    const ascent: i32 = @intCast(font_ctx.ascent_px);
    const descent: i32 = @intCast(font_ctx.descent_px);
    const text_baseline: i32 = @divFloor(tab_bar_h + ascent - descent, 2);

    // 좌우 1px + 상하 2px sandwich gap — TAB_BAR_BG 가 윤곽선 역할 (Windows
    // / macOS 패턴 동일).
    const tab_y: i32 = 2;
    const tab_actual_h: i32 = @max(tab_bar_h - 4, 1);
    const tab_actual_w: i32 = @max(tab_w - 2, 1);

    for (titles, 0..) |title, i| {
        const tab_x_outer: i32 = @as(i32, @intCast(i)) * tab_w;
        const tab_x: i32 = tab_x_outer + 1;
        if (tab_x >= fb_w) break; // 화면 폭 넘은 탭은 단순 truncate (L12-γ scope)

        const is_active = i == active_idx;
        const bg = if (is_active) active_bg else inactive_bg;
        rect(memory, fb_w, fb_h, stride, tab_x, tab_y, tab_actual_w, tab_actual_h, bg);

        const text_x_start: i32 = tab_x + tab_pad;
        const text_x_end: i32 = tab_x + tab_actual_w - tab_pad;
        var pen_x: i32 = text_x_start;
        var utf8_iter = std.unicode.Utf8Iterator{ .bytes = title, .i = 0 };
        while (utf8_iter.nextCodepoint()) |cp| {
            const w_cells: u8 = display_width.codepointWidth(cp);
            if (w_cells == 0) continue;
            const glyph = font_ctx.glyph(cp);
            const adv: i32 = @intCast(glyph.advance);
            if (pen_x + adv > text_x_end) break; // 한 탭 안 ellipsis 도 L12-γ
            if (glyph.pixel_mode == freetype.FT_PIXEL_MODE_BGRA) {
                drawGlyphBgra(memory, fb_w, fb_h, stride, pen_x, 0, adv, tab_bar_h, glyph);
            } else {
                drawGlyph(
                    memory,
                    fb_w,
                    fb_h,
                    stride,
                    pen_x + glyph.bitmap_left,
                    text_baseline - glyph.bitmap_top,
                    glyph,
                    text_color,
                    bg,
                );
            }
            pen_x += adv;
        }
    }
}

fn rgbFromMetrics(c: [4]f32) ghostty.color.RGB {
    return .{
        .r = @intFromFloat(@max(0.0, @min(255.0, c[0] * 255.0))),
        .g = @intFromFloat(@max(0.0, @min(255.0, c[1] * 255.0))),
        .b = @intFromFloat(@max(0.0, @min(255.0, c[2] * 255.0))),
    };
}

/// L10-β preedit overlay — cursor 위치부터 UTF-8 codepoint 별로 cell 너비
/// (display_width.codepointWidth) 만큼 보라색 배경 + foreground 글자. wide
/// char (한글 등) 는 2 cell. 가로 cols 넘어가면 truncate (wrap 안 함 — 다음
/// done event 가 새 preedit 보내주면 갱신).
fn drawPreeditOverlay(
    memory: []u8,
    fb_w: i32,
    fb_h: i32,
    stride: i32,
    cw: i32,
    ch: i32,
    ascent: i32,
    start_col: i32,
    cy_cell: i32,
    cols: usize,
    text: []const u8,
    fg: ghostty.color.RGB,
    font_ctx: *font.Context,
) void {
    // 보라색 배경 — macOS Metal `pre_bg_color = .{0.25, 0.25, 0.5, 1}` 와
    // 동일 색. 8-bit RGB 환산 64 / 64 / 128.
    const preedit_bg = ghostty.color.RGB{ .r = 64, .g = 64, .b = 128 };
    const pre_y: i32 = Renderer.tab_bar_height_px + padding_px + cy_cell * ch;
    const baseline: i32 = pre_y + ascent;

    var col: i32 = start_col;
    var utf8_iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (utf8_iter.nextCodepoint()) |cp| {
        const w_cells: i32 = @intCast(display_width.codepointWidth(cp));
        if (w_cells <= 0) continue;
        if (col + w_cells > @as(i32, @intCast(cols))) break;

        const cell_x: i32 = padding_px + col * cw;
        const cell_w: i32 = w_cells * cw;
        rect(memory, fb_w, fb_h, stride, cell_x, pre_y, cell_w, ch, preedit_bg);

        const glyph = font_ctx.glyph(cp);
        if (glyph.pixel_mode == freetype.FT_PIXEL_MODE_BGRA) {
            // emoji 가 preedit 으로 올 일 거의 없지만 안전하게 동일 path 분기.
            drawGlyphBgra(memory, fb_w, fb_h, stride, cell_x, pre_y, cell_w, ch, glyph);
        } else {
            const glyph_advance_i32: i32 = @intCast(glyph.advance);
            const center_off: i32 = @divFloor(cell_w - glyph_advance_i32, 2);
            drawGlyph(
                memory,
                fb_w,
                fb_h,
                stride,
                cell_x + center_off + glyph.bitmap_left,
                baseline - glyph.bitmap_top,
                glyph,
                fg,
                preedit_bg,
            );
        }

        col += w_cells;
    }
}

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

/// FT_PIXEL_MODE_BGRA bitmap (premultiplied alpha) 를 cell 안 ratio 유지 scale +
/// center fit + alpha 블렌딩으로 XRGB8888 buffer 에 그린다. emoji 색 자체 사용
/// (fg 무시). nearest neighbor sampling — 작은 cell 에 큰 emoji bitmap (보통
/// strike 109px) 가 들어갈 때 quality 보다 단순성 우선.
fn drawGlyphBgra(
    memory: []u8,
    fb_w: i32,
    fb_h: i32,
    stride: i32,
    cell_x: i32,
    cell_y: i32,
    cell_w: i32,
    cell_h: i32,
    glyph: *const font.Glyph,
) void {
    if (glyph.width == 0 or glyph.height == 0 or glyph.bitmap.len == 0) return;
    if (cell_w <= 0 or cell_h <= 0) return;

    const gw_f: f64 = @floatFromInt(glyph.width);
    const gh_f: f64 = @floatFromInt(glyph.height);
    const cw_f: f64 = @floatFromInt(cell_w);
    const ch_f: f64 = @floatFromInt(cell_h);
    const scale: f64 = @min(cw_f / gw_f, ch_f / gh_f);
    const target_w: i32 = @intFromFloat(gw_f * scale);
    const target_h: i32 = @intFromFloat(gh_f * scale);
    if (target_w <= 0 or target_h <= 0) return;
    const off_x: i32 = @divFloor(cell_w - target_w, 2);
    const off_y: i32 = @divFloor(cell_h - target_h, 2);

    var dy: i32 = 0;
    while (dy < target_h) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < target_w) : (dx += 1) {
            const src_xf: f64 = @as(f64, @floatFromInt(dx)) / scale;
            const src_yf: f64 = @as(f64, @floatFromInt(dy)) / scale;
            const src_x: u32 = @intFromFloat(src_xf);
            const src_y: u32 = @intFromFloat(src_yf);
            if (src_x >= glyph.width or src_y >= glyph.height) continue;
            const src_off: usize = (@as(usize, src_y) * glyph.width + src_x) * 4;
            const b = glyph.bitmap[src_off];
            const g = glyph.bitmap[src_off + 1];
            const r = glyph.bitmap[src_off + 2];
            const a = glyph.bitmap[src_off + 3];
            if (a == 0) continue;

            const px = cell_x + off_x + dx;
            const py = cell_y + off_y + dy;
            if (px < 0 or py < 0 or px >= fb_w or py >= fb_h) continue;

            const dst_off: usize = @intCast(py * stride + px * 4);
            const dst_b = memory[dst_off];
            const dst_g = memory[dst_off + 1];
            const dst_r = memory[dst_off + 2];
            const inv: u32 = 255 - @as(u32, a);
            // premultiplied: out = src + (1 - a) * dst.
            const out_b: u8 = @intCast(@min(@as(u32, 255), @as(u32, b) + (@as(u32, dst_b) * inv) / 255));
            const out_g: u8 = @intCast(@min(@as(u32, 255), @as(u32, g) + (@as(u32, dst_g) * inv) / 255));
            const out_r: u8 = @intCast(@min(@as(u32, 255), @as(u32, r) + (@as(u32, dst_r) * inv) / 255));
            memory[dst_off] = out_b;
            memory[dst_off + 1] = out_g;
            memory[dst_off + 2] = out_r;
        }
    }
}

/// Block element rect (`U+2580..U+2595`) 를 셀 안 fraction → 절대 pixel 좌표로
/// 옮겨 그린다. shade == 0 면 solid fg rect. shade ∈ {1,2,3} 이면 d3d11
/// `bg_shader_src` / macOS Metal `bg_fs` 와 동일 식의 procedural dot mask 적용
/// — 픽셀의 absolute (px, py) 로 패턴을 결정해 인접 셀 사이 끊김 없이 대각
/// zigzag 가 이어진다. dot 픽셀만 fg 색으로 set, 나머지는 이미 그려진 배경
/// 그대로 (셰이더의 `discard` 동등).
fn drawBlockRect(
    memory: []u8,
    fb_w: i32,
    fb_h: i32,
    stride: i32,
    cell_x: i32,
    cell_y: i32,
    cell_w: i32,
    cell_h: i32,
    br: block_element.BlockRect,
    fg: ghostty.color.RGB,
) void {
    const cw_f: f32 = @floatFromInt(cell_w);
    const ch_f: f32 = @floatFromInt(cell_h);
    const x0: i32 = cell_x + @as(i32, @intFromFloat(br.x0 * cw_f));
    const y0: i32 = cell_y + @as(i32, @intFromFloat(br.y0 * ch_f));
    const x1: i32 = cell_x + @as(i32, @intFromFloat(br.x1 * cw_f));
    const y1: i32 = cell_y + @as(i32, @intFromFloat(br.y1 * ch_f));

    if (br.shade < 0.5) {
        rect(memory, fb_w, fb_h, stride, x0, y0, x1 - x0, y1 - y0, fg);
        return;
    }

    const cx0 = @max(0, x0);
    const cy0 = @max(0, y0);
    const cx1 = @min(fb_w, x1);
    const cy1 = @min(fb_h, y1);
    if (cx1 <= cx0 or cy1 <= cy0) return;

    const fg_packed = pack(fg);
    var py = cy0;
    while (py < cy1) : (py += 1) {
        var px = cx0;
        while (px < cx1) : (px += 1) {
            const on: bool = if (br.shade < 1.5)
                // U+2591 LIGHT 25% — diagonal sparse
                ((px + 2 * py) & 3) == 0
            else if (br.shade < 2.5)
                // U+2592 MEDIUM 50% — checkerboard
                ((px + py) & 1) == 0
            else
                // U+2593 DARK 75% — LIGHT 의 inverse (diagonal dense)
                ((px + 2 * py) & 3) != 0;
            if (!on) continue;
            const off: usize = @intCast(py * stride + px * 4);
            std.mem.writeInt(u32, memory[off..][0..4], fg_packed, .little);
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
