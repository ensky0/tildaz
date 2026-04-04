const std = @import("std");
const ghostty = @import("ghostty-vt");
const gl = @import("opengl.zig");
const FontAtlas = @import("font_atlas.zig").FontAtlas;

pub const GlRenderer = struct {
    atlas: FontAtlas,
    alloc: std.mem.Allocator,
    render_state: ghostty.RenderState = .empty,
    // Default terminal background (configurable via theme)
    default_bg_r: gl.GLclampf,
    default_bg_g: gl.GLclampf,
    default_bg_b: gl.GLclampf,

    // Tab bar colors (keep hardcoded — not from terminal state)
    const TAB_BAR_R: gl.GLfloat = 20.0 / 255.0;
    const TAB_BAR_G: gl.GLfloat = 20.0 / 255.0;
    const TAB_BAR_B: gl.GLfloat = 20.0 / 255.0;
    const TAB_ACTIVE_R: gl.GLfloat = 50.0 / 255.0;
    const TAB_ACTIVE_G: gl.GLfloat = 50.0 / 255.0;
    const TAB_ACTIVE_B: gl.GLfloat = 50.0 / 255.0;
    const TAB_TEXT_R: gl.GLfloat = 180.0 / 255.0;
    const TAB_TEXT_G: gl.GLfloat = 180.0 / 255.0;
    const TAB_TEXT_B: gl.GLfloat = 180.0 / 255.0;

    fn colorF(v: u8) gl.GLclampf {
        return @as(gl.GLclampf, @floatFromInt(v)) / 255.0;
    }

    pub fn init(alloc: std.mem.Allocator, font_family: [*:0]const u16, font_height: c_int, cell_w: u32, cell_h: u32, bg_rgb: ?[3]u8) !GlRenderer {
        const bg = bg_rgb orelse [3]u8{ 30, 30, 30 };
        return .{
            .atlas = try FontAtlas.init(alloc, font_family, font_height, cell_w, cell_h),
            .alloc = alloc,
            .default_bg_r = colorF(bg[0]),
            .default_bg_g = colorF(bg[1]),
            .default_bg_b = colorF(bg[2]),
        };
    }

    /// Force a full redraw on next renderTerminal call (e.g. after tab switch)
    pub fn invalidate(self: *GlRenderer) void {
        self.render_state.rows = 0;
        self.render_state.cols = 0;
        self.render_state.viewport_pin = null;
    }

    pub fn deinit(self: *GlRenderer) void {
        self.render_state.deinit(self.alloc);
        self.atlas.deinit();
    }

    pub fn renderTabBar(
        self: *GlRenderer,
        tab_count: usize,
        active_tab: usize,
        tab_bar_height: c_int,
        client_w: c_int,
        client_h: c_int,
        tab_width: c_int,
        close_btn_size: c_int,
        tab_padding: c_int,
        dragged_tab: ?usize,
        drag_x: c_int,
    ) void {
        const w_f: gl.GLfloat = @floatFromInt(client_w);
        const h_f: gl.GLfloat = @floatFromInt(client_h);
        const tbh: gl.GLfloat = @floatFromInt(tab_bar_height);
        const tw: gl.GLfloat = @floatFromInt(tab_width);
        const cbs: gl.GLfloat = @floatFromInt(close_btn_size);
        const pad: gl.GLfloat = @floatFromInt(tab_padding);
        const cell_w: gl.GLfloat = @floatFromInt(self.atlas.cell_width);
        const cell_h: gl.GLfloat = @floatFromInt(self.atlas.cell_height);

        gl.glViewport(0, 0, client_w, client_h);
        gl.glMatrixMode(gl.GL_PROJECTION);
        gl.glLoadIdentity();
        gl.glOrtho(0, @floatFromInt(client_w), @floatFromInt(client_h), 0, -1, 1);
        gl.glMatrixMode(gl.GL_MODELVIEW);
        gl.glLoadIdentity();

        gl.glClearColor(self.default_bg_r, self.default_bg_g, self.default_bg_b, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        gl.glEnable(gl.GL_BLEND);
        gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);

        // Tab bar background
        gl.glDisable(gl.GL_TEXTURE_2D);
        gl.glColor3f(TAB_BAR_R, TAB_BAR_G, TAB_BAR_B);
        gl.glBegin(gl.GL_QUADS);
        gl.glVertex2f(0, 0);
        gl.glVertex2f(w_f, 0);
        gl.glVertex2f(w_f, tbh);
        gl.glVertex2f(0, tbh);
        gl.glEnd();

        _ = h_f;

        // Pre-cache tab title glyphs before any glBegin/glEnd
        for (0..tab_count) |i| {
            var pre_buf: [16]u8 = undefined;
            const pre_title = std.fmt.bufPrint(&pre_buf, "Tab {d}", .{i + 1}) catch unreachable;
            for (pre_title) |ch| {
                _ = self.atlas.getOrRenderGlyph(ch, false);
            }
        }
        _ = self.atlas.getOrRenderGlyph('x', false); // close button

        for (0..tab_count) |i| {
            const is_dragged = if (dragged_tab) |dt| (i == dt) else false;
            const tab_x: gl.GLfloat = if (is_dragged)
                @as(gl.GLfloat, @floatFromInt(drag_x)) - tw / 2.0
            else
                @as(gl.GLfloat, @floatFromInt(i)) * tw;

            gl.glDisable(gl.GL_TEXTURE_2D);
            if (i == active_tab) {
                gl.glColor3f(TAB_ACTIVE_R, TAB_ACTIVE_G, TAB_ACTIVE_B);
            } else {
                gl.glColor3f(self.default_bg_r, self.default_bg_g, self.default_bg_b);
            }
            gl.glBegin(gl.GL_QUADS);
            gl.glVertex2f(tab_x + 1, 2);
            gl.glVertex2f(tab_x + tw - 1, 2);
            gl.glVertex2f(tab_x + tw - 1, tbh);
            gl.glVertex2f(tab_x + 1, tbh);
            gl.glEnd();

            // Tab title text
            var title_buf: [16]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buf, "Tab {d}", .{i + 1}) catch unreachable;
            const text_y = (tbh - cell_h) / 2.0;

            gl.glEnable(gl.GL_TEXTURE_2D);
            gl.glBindTexture(gl.GL_TEXTURE_2D, self.atlas.texture_id);
            gl.glColor3f(TAB_TEXT_R, TAB_TEXT_G, TAB_TEXT_B);
            gl.glBegin(gl.GL_QUADS);
            for (title, 0..) |ch, ci| {
                const uv = self.atlas.getUV(ch);
                const x0 = tab_x + pad + @as(gl.GLfloat, @floatFromInt(ci)) * cell_w;
                const y0 = text_y;
                gl.glTexCoord2f(uv.u0, uv.v0);
                gl.glVertex2f(x0, y0);
                gl.glTexCoord2f(uv.u1, uv.v0);
                gl.glVertex2f(x0 + cell_w, y0);
                gl.glTexCoord2f(uv.u1, uv.v1);
                gl.glVertex2f(x0 + cell_w, y0 + cell_h);
                gl.glTexCoord2f(uv.u0, uv.v1);
                gl.glVertex2f(x0, y0 + cell_h);
            }
            gl.glEnd();

            // Close button "x"
            const close_x = tab_x + tw - cbs - pad;
            const close_y = (tbh - cbs) / 2.0;
            const uv_x = self.atlas.getUV('x');
            gl.glColor4f(TAB_TEXT_R, TAB_TEXT_G, TAB_TEXT_B, 0.6);
            gl.glBegin(gl.GL_QUADS);
            gl.glTexCoord2f(uv_x.u0, uv_x.v0);
            gl.glVertex2f(close_x, close_y);
            gl.glTexCoord2f(uv_x.u1, uv_x.v0);
            gl.glVertex2f(close_x + cbs, close_y);
            gl.glTexCoord2f(uv_x.u1, uv_x.v1);
            gl.glVertex2f(close_x + cbs, close_y + cbs);
            gl.glTexCoord2f(uv_x.u0, uv_x.v1);
            gl.glVertex2f(close_x, close_y + cbs);
            gl.glEnd();
        }

        gl.glDisable(gl.GL_TEXTURE_2D);
    }

    pub fn renderTerminal(
        self: *GlRenderer,
        terminal: *ghostty.Terminal,
        cell_w: c_int,
        cell_h: c_int,
        vp_w: c_int,
        vp_h: c_int,
        y_offset: c_int,
        padding: c_int,
    ) void {
        self.render_state.update(self.alloc, terminal) catch return;

        const rows = self.render_state.rows;
        const cols = self.render_state.cols;
        const colors = self.render_state.colors;
        const row_slice = self.render_state.row_data.slice();

        const cw: gl.GLfloat = @floatFromInt(cell_w);
        const ch: gl.GLfloat = @floatFromInt(cell_h);
        const y_off: gl.GLfloat = @floatFromInt(y_offset + padding);
        const x_pad: gl.GLfloat = @floatFromInt(padding);

        gl.glEnable(gl.GL_BLEND);
        gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);

        const all_cells = row_slice.items(.cells);

        // --- Pre-pass: cache all glyphs BEFORE glBegin (glTexSubImage2D is illegal inside glBegin/glEnd) ---
        for (0..rows) |y| {
            if (y >= all_cells.len) break;
            const cell_slice = all_cells[y].slice();
            const raws = cell_slice.items(.raw);

            for (0..cols) |x| {
                if (x >= raws.len) break;
                const raw = raws[x];
                if (!raw.hasText()) continue;
                if (raw.wide == .spacer_tail or raw.wide == .spacer_head) continue;
                const cp = raw.codepoint();
                if (cp == 0) continue;
                if (isBlockElement(cp)) continue;
                _ = self.atlas.getOrRenderGlyph(cp, raw.wide == .wide);
            }
        }

        const all_sels = row_slice.items(.selection);

        // --- 1st pass: background colors ---
        gl.glDisable(gl.GL_TEXTURE_2D);
        gl.glBegin(gl.GL_QUADS);

        for (0..rows) |y| {
            if (y >= all_cells.len) break;
            const cell_slice = all_cells[y].slice();
            const raws = cell_slice.items(.raw);
            const styles = cell_slice.items(.style);

            // Selection range for this row (if any)
            const sel_range: ?[2]u16 = if (y < all_sels.len) all_sels[y] else null;

            for (0..cols) |x| {
                if (x >= raws.len) break;
                const raw = raws[x];
                if (raw.wide == .spacer_tail) continue;

                const style = if (raw.style_id != 0) styles[x] else ghostty.Style{};
                const is_inverse = style.flags.inverse;
                const x16: u16 = @intCast(x);
                const is_selected = if (sel_range) |sr| (x16 >= sr[0] and x16 <= sr[1]) else false;

                // Resolve background color
                const bg_rgb = blk: {
                    if (is_selected) {
                        // Selection highlight: swap fg/bg for visual feedback
                        break :blk style.fg(.{
                            .default = colors.foreground,
                            .palette = &colors.palette,
                        });
                    } else if (is_inverse) {
                        // Inverse: bg becomes fg
                        break :blk style.fg(.{
                            .default = colors.foreground,
                            .palette = &colors.palette,
                        });
                    } else {
                        break :blk style.bg(&raw, &colors.palette) orelse continue;
                    }
                };

                // Skip if same as default background (but never skip selection)
                if (!is_selected and
                    bg_rgb.r == colors.background.r and
                    bg_rgb.g == colors.background.g and
                    bg_rgb.b == colors.background.b) continue;

                const width: gl.GLfloat = if (raw.wide == .wide) 2.0 * cw else cw;
                const fx: gl.GLfloat = @as(gl.GLfloat, @floatFromInt(x)) * cw + x_pad;
                const fy: gl.GLfloat = @as(gl.GLfloat, @floatFromInt(y)) * ch + y_off;

                gl.glColor3f(
                    @as(gl.GLfloat, @floatFromInt(bg_rgb.r)) / 255.0,
                    @as(gl.GLfloat, @floatFromInt(bg_rgb.g)) / 255.0,
                    @as(gl.GLfloat, @floatFromInt(bg_rgb.b)) / 255.0,
                );
                gl.glVertex2f(fx, fy);
                gl.glVertex2f(fx + width, fy);
                gl.glVertex2f(fx + width, fy + ch);
                gl.glVertex2f(fx, fy + ch);
            }
        }
        gl.glEnd();

        // --- 2nd pass: text with per-cell foreground colors ---
        gl.glEnable(gl.GL_TEXTURE_2D);
        gl.glBindTexture(gl.GL_TEXTURE_2D, self.atlas.texture_id);
        gl.glBegin(gl.GL_QUADS);

        for (0..rows) |y| {
            if (y >= all_cells.len) break;
            const cell_slice = all_cells[y].slice();
            const raws = cell_slice.items(.raw);
            const styles = cell_slice.items(.style);

            const sel_range: ?[2]u16 = if (y < all_sels.len) all_sels[y] else null;

            for (0..cols) |x| {
                if (x >= raws.len) break;
                const raw = raws[x];

                if (!raw.hasText()) continue;
                if (raw.wide == .spacer_tail or raw.wide == .spacer_head) continue;

                const cp = raw.codepoint();
                if (cp == 0) continue;
                if (isBlockElement(cp)) continue;
                const is_wide = raw.wide == .wide;

                const glyph = self.atlas.getOrRenderGlyph(cp, is_wide);

                const style = if (raw.style_id != 0) styles[x] else ghostty.Style{};
                const is_inverse = style.flags.inverse;
                const x16: u16 = @intCast(x);
                const is_selected = if (sel_range) |sr| (x16 >= sr[0] and x16 <= sr[1]) else false;

                // Resolve foreground color
                const fg_rgb = blk: {
                    if (is_selected) {
                        // Selection: fg becomes bg for contrast
                        break :blk style.bg(&raw, &colors.palette) orelse colors.background;
                    } else if (is_inverse) {
                        // Inverse: fg becomes bg
                        break :blk style.bg(&raw, &colors.palette) orelse colors.background;
                    } else {
                        break :blk style.fg(.{
                            .default = colors.foreground,
                            .palette = &colors.palette,
                            .bold = .bright,
                        });
                    }
                };

                gl.glColor3f(
                    @as(gl.GLfloat, @floatFromInt(fg_rgb.r)) / 255.0,
                    @as(gl.GLfloat, @floatFromInt(fg_rgb.g)) / 255.0,
                    @as(gl.GLfloat, @floatFromInt(fg_rgb.b)) / 255.0,
                );

                const width: gl.GLfloat = if (is_wide) 2.0 * cw else cw;
                const fx: gl.GLfloat = @as(gl.GLfloat, @floatFromInt(x)) * cw + x_pad;
                const fy: gl.GLfloat = @as(gl.GLfloat, @floatFromInt(y)) * ch + y_off;
                const uv = glyph.uv;

                gl.glTexCoord2f(uv.u0, uv.v0);
                gl.glVertex2f(fx, fy);
                gl.glTexCoord2f(uv.u1, uv.v0);
                gl.glVertex2f(fx + width, fy);
                gl.glTexCoord2f(uv.u1, uv.v1);
                gl.glVertex2f(fx + width, fy + ch);
                gl.glTexCoord2f(uv.u0, uv.v1);
                gl.glVertex2f(fx, fy + ch);
            }
        }
        gl.glEnd();

        // --- 3rd pass: block element characters (U+2580-U+2595) ---
        gl.glDisable(gl.GL_TEXTURE_2D);
        gl.glBegin(gl.GL_QUADS);

        for (0..rows) |y| {
            if (y >= all_cells.len) break;
            const cell_slice = all_cells[y].slice();
            const raws = cell_slice.items(.raw);
            const styles = cell_slice.items(.style);

            const sel_range: ?[2]u16 = if (y < all_sels.len) all_sels[y] else null;

            for (0..cols) |x| {
                if (x >= raws.len) break;
                const raw = raws[x];

                if (!raw.hasText()) continue;
                if (raw.wide == .spacer_tail or raw.wide == .spacer_head) continue;

                const cp = raw.codepoint();
                const rect = blockElementRect(cp) orelse continue;

                const style = if (raw.style_id != 0) styles[x] else ghostty.Style{};
                const is_inverse = style.flags.inverse;
                const x16: u16 = @intCast(x);
                const is_selected = if (sel_range) |sr| (x16 >= sr[0] and x16 <= sr[1]) else false;

                const fg_rgb = blk: {
                    if (is_selected) {
                        break :blk style.bg(&raw, &colors.palette) orelse colors.background;
                    } else if (is_inverse) {
                        break :blk style.bg(&raw, &colors.palette) orelse colors.background;
                    } else {
                        break :blk style.fg(.{
                            .default = colors.foreground,
                            .palette = &colors.palette,
                            .bold = .bright,
                        });
                    }
                };

                gl.glColor4f(
                    @as(gl.GLfloat, @floatFromInt(fg_rgb.r)) / 255.0,
                    @as(gl.GLfloat, @floatFromInt(fg_rgb.g)) / 255.0,
                    @as(gl.GLfloat, @floatFromInt(fg_rgb.b)) / 255.0,
                    rect.alpha,
                );

                const width: gl.GLfloat = if (raw.wide == .wide) 2.0 * cw else cw;
                const fx: gl.GLfloat = @as(gl.GLfloat, @floatFromInt(x)) * cw + x_pad;
                const fy: gl.GLfloat = @as(gl.GLfloat, @floatFromInt(y)) * ch + y_off;

                const qx0 = fx + rect.x0 * width;
                const qy0 = fy + rect.y0 * ch;
                const qx1 = fx + rect.x1 * width;
                const qy1 = fy + rect.y1 * ch;

                gl.glVertex2f(qx0, qy0);
                gl.glVertex2f(qx1, qy0);
                gl.glVertex2f(qx1, qy1);
                gl.glVertex2f(qx0, qy1);
            }
        }
        gl.glEnd();

        // --- Cursor ---
        if (self.render_state.cursor.visible) {
            if (self.render_state.cursor.viewport) |vp| {
                gl.glDisable(gl.GL_TEXTURE_2D);
                var cursor_x: gl.GLfloat = @floatFromInt(vp.x);
                const cursor_y: gl.GLfloat = @floatFromInt(vp.y);

                if (vp.wide_tail and vp.x > 0) {
                    cursor_x -= 1.0;
                }

                const cx0 = cursor_x * cw + x_pad;
                const cy0 = cursor_y * ch + y_off;

                // Use terminal cursor color if set, otherwise default
                if (colors.cursor) |cc| {
                    gl.glColor4f(
                        @as(gl.GLfloat, @floatFromInt(cc.r)) / 255.0,
                        @as(gl.GLfloat, @floatFromInt(cc.g)) / 255.0,
                        @as(gl.GLfloat, @floatFromInt(cc.b)) / 255.0,
                        0.7,
                    );
                } else {
                    gl.glColor4f(180.0 / 255.0, 180.0 / 255.0, 180.0 / 255.0, 0.7);
                }

                gl.glBegin(gl.GL_QUADS);
                gl.glVertex2f(cx0, cy0);
                gl.glVertex2f(cx0 + cw, cy0);
                gl.glVertex2f(cx0 + cw, cy0 + ch);
                gl.glVertex2f(cx0, cy0 + ch);
                gl.glEnd();
            }
        }

        // --- Scrollbar ---
        const sb = terminal.screens.active.pages.scrollbar();
        if (sb.total > sb.len) {
            const track_h: gl.GLfloat = @floatFromInt(vp_h - y_offset - padding);
            const track_x: gl.GLfloat = @as(gl.GLfloat, @floatFromInt(vp_w)) - SCROLLBAR_W;

            const ratio = track_h / @as(gl.GLfloat, @floatFromInt(sb.total));
            const thumb_h = @max(SCROLLBAR_MIN_H, ratio * @as(gl.GLfloat, @floatFromInt(sb.len)));
            const available = track_h - thumb_h;
            const max_offset: gl.GLfloat = @floatFromInt(sb.total - sb.len);
            const thumb_y = y_off + if (max_offset > 0) @as(gl.GLfloat, @floatFromInt(sb.offset)) / max_offset * available else 0;

            gl.glDisable(gl.GL_TEXTURE_2D);

            // Thumb
            gl.glColor4f(1.0, 1.0, 1.0, 0.3);
            gl.glBegin(gl.GL_QUADS);
            gl.glVertex2f(track_x, thumb_y);
            gl.glVertex2f(track_x + SCROLLBAR_W, thumb_y);
            gl.glVertex2f(track_x + SCROLLBAR_W, thumb_y + thumb_h);
            gl.glVertex2f(track_x, thumb_y + thumb_h);
            gl.glEnd();
        }

        gl.glDisable(gl.GL_BLEND);
    }

    const SCROLLBAR_W: gl.GLfloat = 8.0;
    const SCROLLBAR_MIN_H: gl.GLfloat = 16.0;

    const BlockRect = struct { x0: f32, y0: f32, x1: f32, y1: f32, alpha: f32 };

    fn isBlockElement(cp: u21) bool {
        return cp >= 0x2580 and cp <= 0x2595;
    }

    fn blockElementRect(cp: u21) ?BlockRect {
        return switch (cp) {
            0x2580 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 0.5, .alpha = 1 }, // ▀ upper half
            0x2581 => .{ .x0 = 0, .y0 = 7.0 / 8.0, .x1 = 1, .y1 = 1, .alpha = 1 }, // ▁ lower 1/8
            0x2582 => .{ .x0 = 0, .y0 = 6.0 / 8.0, .x1 = 1, .y1 = 1, .alpha = 1 }, // ▂ lower 1/4
            0x2583 => .{ .x0 = 0, .y0 = 5.0 / 8.0, .x1 = 1, .y1 = 1, .alpha = 1 }, // ▃ lower 3/8
            0x2584 => .{ .x0 = 0, .y0 = 4.0 / 8.0, .x1 = 1, .y1 = 1, .alpha = 1 }, // ▄ lower half
            0x2585 => .{ .x0 = 0, .y0 = 3.0 / 8.0, .x1 = 1, .y1 = 1, .alpha = 1 }, // ▅ lower 5/8
            0x2586 => .{ .x0 = 0, .y0 = 2.0 / 8.0, .x1 = 1, .y1 = 1, .alpha = 1 }, // ▆ lower 3/4
            0x2587 => .{ .x0 = 0, .y0 = 1.0 / 8.0, .x1 = 1, .y1 = 1, .alpha = 1 }, // ▇ lower 7/8
            0x2588 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 1 }, // █ full block
            0x2589 => .{ .x0 = 0, .y0 = 0, .x1 = 7.0 / 8.0, .y1 = 1, .alpha = 1 }, // ▉ left 7/8
            0x258A => .{ .x0 = 0, .y0 = 0, .x1 = 6.0 / 8.0, .y1 = 1, .alpha = 1 }, // ▊ left 3/4
            0x258B => .{ .x0 = 0, .y0 = 0, .x1 = 5.0 / 8.0, .y1 = 1, .alpha = 1 }, // ▋ left 5/8
            0x258C => .{ .x0 = 0, .y0 = 0, .x1 = 4.0 / 8.0, .y1 = 1, .alpha = 1 }, // ▌ left half
            0x258D => .{ .x0 = 0, .y0 = 0, .x1 = 3.0 / 8.0, .y1 = 1, .alpha = 1 }, // ▍ left 3/8
            0x258E => .{ .x0 = 0, .y0 = 0, .x1 = 2.0 / 8.0, .y1 = 1, .alpha = 1 }, // ▎ left 1/4
            0x258F => .{ .x0 = 0, .y0 = 0, .x1 = 1.0 / 8.0, .y1 = 1, .alpha = 1 }, // ▏ left 1/8
            0x2590 => .{ .x0 = 0.5, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 1 }, // ▐ right half
            0x2591 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 0.25 }, // ░ light shade
            0x2592 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 0.5 }, // ▒ medium shade
            0x2593 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 0.75 }, // ▓ dark shade
            0x2594 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1.0 / 8.0, .alpha = 1 }, // ▔ upper 1/8
            0x2595 => .{ .x0 = 7.0 / 8.0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 1 }, // ▕ right 1/8
            else => null,
        };
    }
};
