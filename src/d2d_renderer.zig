// Direct2D terminal renderer — replaces OpenGL texture atlas with native DirectWrite rendering.
// Uses DrawGlyphRun batching for performance (same font_face + fg_color → single call).

const std = @import("std");
const ghostty = @import("ghostty-vt");
const d2d = @import("direct2d.zig");
const dw = @import("directwrite.zig");
const DWriteFontContext = @import("dwrite_font.zig").DWriteFontContext;

const WCHAR = u16;

const MAX_COLS = 512;

pub const D2dRenderer = struct {
    alloc: std.mem.Allocator,
    font: DWriteFontContext,
    render_state: ghostty.RenderState = .empty,

    // D2D resources
    factory: *d2d.ID2D1Factory,
    target: *d2d.ID2D1HwndRenderTarget,
    fg_brush: *d2d.ID2D1SolidColorBrush,
    bg_brush: *d2d.ID2D1SolidColorBrush,

    // Default background color
    default_bg: d2d.D2D1_COLOR_F,

    // Glyph run batching buffers (reused per frame)
    glyph_indices: [MAX_COLS]u16 = undefined,
    glyph_advances: [MAX_COLS]f32 = undefined,

    // Tab bar colors
    const TAB_BAR_COLOR = d2d.D2D1_COLOR_F{ .r = 20.0 / 255.0, .g = 20.0 / 255.0, .b = 20.0 / 255.0 };
    const TAB_ACTIVE_COLOR = d2d.D2D1_COLOR_F{ .r = 50.0 / 255.0, .g = 50.0 / 255.0, .b = 50.0 / 255.0 };
    const TAB_TEXT_COLOR = d2d.D2D1_COLOR_F{ .r = 180.0 / 255.0, .g = 180.0 / 255.0, .b = 180.0 / 255.0 };

    fn colorF(v: u8) f32 {
        return @as(f32, @floatFromInt(v)) / 255.0;
    }

    pub fn init(alloc: std.mem.Allocator, hwnd: ?*anyopaque, font_family: [*:0]const u16, font_height: c_int, cell_w: u32, cell_h: u32, bg_rgb: ?[3]u8) !D2dRenderer {
        const bg = bg_rgb orelse [3]u8{ 30, 30, 30 };

        // Create D2D factory
        var d2d_factory: ?*d2d.ID2D1Factory = null;
        if (d2d.D2D1CreateFactory(
            d2d.D2D1_FACTORY_TYPE_SINGLE_THREADED,
            &d2d.IID_ID2D1Factory,
            null,
            &d2d_factory,
        ) < 0) return error.D2DFactoryFailed;
        errdefer _ = d2d_factory.?.Release();

        // Create HWND render target
        var rt_props = d2d.D2D1_RENDER_TARGET_PROPERTIES{
            .type = d2d.D2D1_RENDER_TARGET_TYPE_DEFAULT,
            .pixelFormat = .{
                .format = d2d.DXGI_FORMAT_B8G8R8A8_UNORM,
                .alphaMode = d2d.D2D1_ALPHA_MODE_IGNORE,
            },
        };
        var hwnd_props = d2d.D2D1_HWND_RENDER_TARGET_PROPERTIES{
            .hwnd = hwnd,
            .presentOptions = d2d.D2D1_PRESENT_OPTIONS_NONE,
        };
        var render_target: ?*d2d.ID2D1HwndRenderTarget = null;
        if (d2d_factory.?.CreateHwndRenderTarget(&rt_props, &hwnd_props, &render_target) < 0)
            return error.RenderTargetFailed;
        errdefer _ = render_target.?.Release();

        // Set ClearType text rendering
        render_target.?.SetTextAntialiasMode(d2d.D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE);

        // Init DWrite font context
        var font_ctx = try DWriteFontContext.init(font_family, font_height, cell_w, cell_h);
        errdefer font_ctx.deinit();

        // Set DirectWrite rendering params on D2D target
        render_target.?.SetTextRenderingParams(font_ctx.rendering_params);

        // Create brushes
        const default_bg = d2d.D2D1_COLOR_F{ .r = colorF(bg[0]), .g = colorF(bg[1]), .b = colorF(bg[2]) };
        var fg_brush: ?*d2d.ID2D1SolidColorBrush = null;
        const white = d2d.D2D1_COLOR_F{ .r = 1, .g = 1, .b = 1 };
        if (render_target.?.CreateSolidColorBrush(&white, &fg_brush) < 0) return error.BrushFailed;
        errdefer _ = fg_brush.?.Release();

        var bg_brush: ?*d2d.ID2D1SolidColorBrush = null;
        if (render_target.?.CreateSolidColorBrush(&default_bg, &bg_brush) < 0) return error.BrushFailed;
        errdefer _ = bg_brush.?.Release();

        // Set identity transform
        const identity = d2d.D2D1_MATRIX_3X2_F{};
        render_target.?.SetTransform(&identity);

        return .{
            .alloc = alloc,
            .font = font_ctx,
            .factory = d2d_factory.?,
            .target = render_target.?,
            .fg_brush = fg_brush.?,
            .bg_brush = bg_brush.?,
            .default_bg = default_bg,
        };
    }

    pub fn deinit(self: *D2dRenderer) void {
        self.render_state.deinit(self.alloc);
        _ = self.bg_brush.Release();
        _ = self.fg_brush.Release();
        _ = self.target.Release();
        _ = self.factory.Release();
        self.font.deinit();
    }

    pub fn invalidate(self: *D2dRenderer) void {
        self.render_state.rows = 0;
        self.render_state.cols = 0;
        self.render_state.viewport_pin = null;
    }

    pub fn resize(self: *D2dRenderer, width: u32, height: u32) void {
        const size = d2d.D2D1_SIZE_U{ .width = width, .height = height };
        _ = self.target.Resize(&size);
    }

    // === Tab bar rendering ===

    pub fn renderTabBar(
        self: *D2dRenderer,
        tab_count: usize,
        active_tab: usize,
        tab_bar_height: c_int,
        client_w: c_int,
        _: c_int, // client_h — unused
        tab_width: c_int,
        close_btn_size: c_int,
        tab_padding: c_int,
        dragged_tab: ?usize,
        drag_x: c_int,
    ) void {
        const tbh: f32 = @floatFromInt(tab_bar_height);
        const tw: f32 = @floatFromInt(tab_width);
        const cbs: f32 = @floatFromInt(close_btn_size);
        const pad: f32 = @floatFromInt(tab_padding);
        const cw: f32 = @floatFromInt(self.font.cell_width);
        const ch: f32 = @floatFromInt(self.font.cell_height);
        const w_f: f32 = @floatFromInt(client_w);

        self.target.BeginDraw();
        self.target.Clear(&self.default_bg);

        // Tab bar background
        self.bg_brush.SetColor(&TAB_BAR_COLOR);
        self.target.FillRectangle(&.{ .left = 0, .top = 0, .right = w_f, .bottom = tbh }, self.bg_brush.asBrush());

        for (0..tab_count) |i| {
            const is_dragged = if (dragged_tab) |dt| (i == dt) else false;
            const tab_x: f32 = if (is_dragged)
                @as(f32, @floatFromInt(drag_x)) - tw / 2.0
            else
                @as(f32, @floatFromInt(i)) * tw;

            // Tab background
            const tab_bg = if (i == active_tab) TAB_ACTIVE_COLOR else self.default_bg;
            self.bg_brush.SetColor(&tab_bg);
            self.target.FillRectangle(&.{
                .left = tab_x + 1,
                .top = 2,
                .right = tab_x + tw - 1,
                .bottom = tbh,
            }, self.bg_brush.asBrush());

            // Tab title text
            var title_buf: [16]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buf, "Tab {d}", .{i + 1}) catch unreachable;
            const text_y = (tbh - ch) / 2.0;

            self.fg_brush.SetColor(&TAB_TEXT_COLOR);
            self.fg_brush.SetOpacity(1.0);
            self.drawAsciiText(title, tab_x + pad, text_y, cw);

            // Close button "x"
            const close_x = tab_x + tw - cbs - pad;
            const close_y = (tbh - cbs) / 2.0;
            const close_color = d2d.D2D1_COLOR_F{
                .r = TAB_TEXT_COLOR.r * 0.6 + tab_bg.r * 0.4,
                .g = TAB_TEXT_COLOR.g * 0.6 + tab_bg.g * 0.4,
                .b = TAB_TEXT_COLOR.b * 0.6 + tab_bg.b * 0.4,
            };
            self.fg_brush.SetColor(&close_color);
            self.drawAsciiText("x", close_x + (cbs - cw) / 2.0, close_y + (cbs - ch) / 2.0, cw);
        }

        // Don't EndDraw here — renderTerminal will continue drawing
    }

    /// Draw ASCII text using DrawGlyphRun (for tab bar titles).
    fn drawAsciiText(self: *D2dRenderer, text: []const u8, x: f32, y: f32, advance: f32) void {
        var count: usize = 0;
        for (text) |ch| {
            if (count >= MAX_COLS) break;
            const result = self.font.resolveGlyph(ch) orelse continue;
            if (result.owned) _ = result.face.vtable.Release(result.face);
            self.glyph_indices[count] = result.index;
            self.glyph_advances[count] = advance;
            count += 1;
        }
        if (count == 0) return;

        const glyph_run = dw.DWRITE_GLYPH_RUN{
            .fontFace = self.font.primary_font_face,
            .fontEmSize = self.font.font_em_size,
            .glyphCount = @intCast(count),
            .glyphIndices = &self.glyph_indices,
            .glyphAdvances = &self.glyph_advances,
            .glyphOffsets = null,
            .isSideways = 0,
            .bidiLevel = 0,
        };

        self.target.DrawGlyphRun(
            .{ .x = x, .y = y + self.font.ascent_px },
            &glyph_run,
            self.fg_brush.asBrush(),
            dw.DWRITE_MEASURING_MODE_NATURAL,
        );
    }

    // === Terminal rendering ===

    pub fn renderTerminal(
        self: *D2dRenderer,
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

        const cw: f32 = @floatFromInt(cell_w);
        const ch: f32 = @floatFromInt(cell_h);
        const y_off: f32 = @floatFromInt(y_offset + padding);
        const x_pad: f32 = @floatFromInt(padding);

        const all_cells = row_slice.items(.cells);
        const all_sels = row_slice.items(.selection);

        const dbg_r = colorF(colors.background.r);
        const dbg_g = colorF(colors.background.g);
        const dbg_b = colorF(colors.background.b);

        // --- Background pass ---
        for (0..rows) |y| {
            if (y >= all_cells.len) break;
            const cell_slice = all_cells[y].slice();
            const raws = cell_slice.items(.raw);
            const styles = cell_slice.items(.style);
            const sel_range: ?[2]u16 = if (y < all_sels.len) all_sels[y] else null;

            for (0..cols) |x| {
                if (x >= raws.len) break;
                const raw = raws[x];
                if (raw.wide == .spacer_tail) continue;

                const style = if (raw.style_id != 0) styles[x] else ghostty.Style{};
                const is_inverse = style.flags.inverse;
                const x16: u16 = @intCast(x);
                const is_selected = if (sel_range) |sr| (x16 >= sr[0] and x16 <= sr[1]) else false;

                const is_custom_bg = is_selected or is_inverse or (style.bg(&raw, &colors.palette) != null);
                if (!is_custom_bg) continue;

                const width: f32 = if (raw.wide == .wide) 2.0 * cw else cw;
                const fx: f32 = @as(f32, @floatFromInt(x)) * cw + x_pad;
                const fy: f32 = @as(f32, @floatFromInt(y)) * ch + y_off;

                const cell_bg = resolveBg(style, &raw, &colors, is_selected, is_inverse, dbg_r, dbg_g, dbg_b);
                self.bg_brush.SetColor(&.{ .r = cell_bg[0], .g = cell_bg[1], .b = cell_bg[2] });
                self.target.FillRectangle(&.{
                    .left = fx,
                    .top = fy,
                    .right = fx + width,
                    .bottom = fy + ch,
                }, self.bg_brush.asBrush());
            }
        }

        // --- Text pass (batched DrawGlyphRun) ---
        for (0..rows) |y| {
            if (y >= all_cells.len) break;
            const cell_slice = all_cells[y].slice();
            const raws = cell_slice.items(.raw);
            const styles = cell_slice.items(.style);
            const sel_range: ?[2]u16 = if (y < all_sels.len) all_sels[y] else null;

            const fy: f32 = @as(f32, @floatFromInt(y)) * ch + y_off;

            // Batching state
            var run_face: ?*dw.IDWriteFontFace = null;
            var run_fg: [3]f32 = .{ 0, 0, 0 };
            var run_start_x: f32 = 0;
            var glyph_count: usize = 0;
            // Track owned fallback faces to release after flush
            var owned_faces: [MAX_COLS]?*dw.IDWriteFontFace = undefined;
            var owned_count: usize = 0;

            for (0..cols) |x| {
                if (x >= raws.len) break;
                const raw = raws[x];

                const is_text = raw.hasText() and raw.wide != .spacer_tail and raw.wide != .spacer_head and raw.codepoint() != 0;
                if (!is_text) {
                    // Non-text cell breaks any glyph run in progress
                    if (glyph_count > 0) {
                        self.flushGlyphRun(run_face.?, glyph_count, run_start_x, fy, run_fg);
                        self.releaseOwnedFaces(owned_faces[0..owned_count]);
                        owned_count = 0;
                        glyph_count = 0;
                        run_face = null;
                    }
                    continue;
                }
                const cp = raw.codepoint();

                // Block elements: draw as colored rectangle
                if (isBlockElement(cp)) {
                    // Flush any pending glyph run first
                    if (glyph_count > 0) {
                        self.flushGlyphRun(run_face.?, glyph_count, run_start_x, fy, run_fg);
                        glyph_count = 0;
                        run_face = null;
                    }
                    self.releaseOwnedFaces(owned_faces[0..owned_count]);
                    owned_count = 0;

                    const style = if (raw.style_id != 0) styles[x] else ghostty.Style{};
                    const is_inverse = style.flags.inverse;
                    const x16: u16 = @intCast(x);
                    const is_selected = if (sel_range) |sr| (x16 >= sr[0] and x16 <= sr[1]) else false;
                    const fg_rgb = resolveFg(style, &raw, &colors, is_selected, is_inverse);

                    const rect = blockElementRect(cp) orelse continue;
                    const width: f32 = if (raw.wide == .wide) 2.0 * cw else cw;
                    const fx: f32 = @as(f32, @floatFromInt(x)) * cw + x_pad;
                    self.bg_brush.SetColor(&.{ .r = colorF(fg_rgb.r), .g = colorF(fg_rgb.g), .b = colorF(fg_rgb.b), .a = rect.alpha });
                    self.target.FillRectangle(&.{
                        .left = fx + rect.x0 * width,
                        .top = fy + rect.y0 * ch,
                        .right = fx + rect.x1 * width,
                        .bottom = fy + rect.y1 * ch,
                    }, self.bg_brush.asBrush());
                    continue;
                }

                // Resolve glyph
                const result = self.font.resolveGlyph(cp) orelse continue;

                const style = if (raw.style_id != 0) styles[x] else ghostty.Style{};
                const is_inverse = style.flags.inverse;
                const x16: u16 = @intCast(x);
                const is_selected = if (sel_range) |sr| (x16 >= sr[0] and x16 <= sr[1]) else false;
                const fg_rgb = resolveFg(style, &raw, &colors, is_selected, is_inverse);
                const fg = [3]f32{ colorF(fg_rgb.r), colorF(fg_rgb.g), colorF(fg_rgb.b) };

                const fx: f32 = @as(f32, @floatFromInt(x)) * cw + x_pad;
                const advance: f32 = if (raw.wide == .wide) 2.0 * cw else cw;

                // Check if we need to start a new batch
                const need_new_batch = glyph_count == 0 or
                    result.face != run_face.? or
                    fg[0] != run_fg[0] or fg[1] != run_fg[1] or fg[2] != run_fg[2] or
                    glyph_count >= MAX_COLS;

                if (need_new_batch and glyph_count > 0) {
                    // Flush current batch
                    self.flushGlyphRun(run_face.?, glyph_count, run_start_x, fy, run_fg);
                    self.releaseOwnedFaces(owned_faces[0..owned_count]);
                    owned_count = 0;
                    glyph_count = 0;
                }

                if (glyph_count == 0) {
                    run_face = result.face;
                    run_fg = fg;
                    run_start_x = fx;
                }

                if (result.owned) {
                    if (owned_count < MAX_COLS) {
                        owned_faces[owned_count] = result.face;
                        owned_count += 1;
                    }
                }

                self.glyph_indices[glyph_count] = result.index;
                self.glyph_advances[glyph_count] = advance;
                glyph_count += 1;
            }

            // Flush remaining glyphs for this row
            if (glyph_count > 0) {
                self.flushGlyphRun(run_face.?, glyph_count, run_start_x, fy, run_fg);
            }
            self.releaseOwnedFaces(owned_faces[0..owned_count]);
        }

        // --- Cursor ---
        if (self.render_state.cursor.visible) {
            if (self.render_state.cursor.viewport) |vp| {
                var cursor_x: f32 = @floatFromInt(vp.x);
                const cursor_y: f32 = @floatFromInt(vp.y);
                if (vp.wide_tail and vp.x > 0) cursor_x -= 1.0;
                const cx0 = cursor_x * cw + x_pad;
                const cy0 = cursor_y * ch + y_off;
                if (colors.cursor) |cc| {
                    self.bg_brush.SetColor(&.{ .r = colorF(cc.r), .g = colorF(cc.g), .b = colorF(cc.b), .a = 0.7 });
                } else {
                    self.bg_brush.SetColor(&.{ .r = 180.0 / 255.0, .g = 180.0 / 255.0, .b = 180.0 / 255.0, .a = 0.7 });
                }
                self.target.FillRectangle(&.{
                    .left = cx0,
                    .top = cy0,
                    .right = cx0 + cw,
                    .bottom = cy0 + ch,
                }, self.bg_brush.asBrush());
            }
        }

        // --- Scrollbar ---
        const sb = terminal.screens.active.pages.scrollbar();
        if (sb.total > sb.len) {
            const vp_hf: f32 = @floatFromInt(vp_h);
            const vp_wf: f32 = @floatFromInt(vp_w);
            const track_h: f32 = vp_hf - @as(f32, @floatFromInt(y_offset + padding));
            const track_x: f32 = vp_wf - SCROLLBAR_W;
            const ratio = track_h / @as(f32, @floatFromInt(sb.total));
            const thumb_h = @max(SCROLLBAR_MIN_H, ratio * @as(f32, @floatFromInt(sb.len)));
            const available = track_h - thumb_h;
            const max_offset: f32 = @floatFromInt(sb.total - sb.len);
            const thumb_y = y_off + if (max_offset > 0) @as(f32, @floatFromInt(sb.offset)) / max_offset * available else 0;
            self.bg_brush.SetColor(&.{ .r = 1, .g = 1, .b = 1, .a = 0.3 });
            self.target.FillRectangle(&.{
                .left = track_x,
                .top = thumb_y,
                .right = track_x + SCROLLBAR_W,
                .bottom = thumb_y + thumb_h,
            }, self.bg_brush.asBrush());
        }

        // EndDraw (started in renderTabBar)
        _ = self.target.EndDraw();
    }

    fn flushGlyphRun(self: *D2dRenderer, face: *dw.IDWriteFontFace, count: usize, start_x: f32, row_y: f32, fg: [3]f32) void {
        const glyph_run = dw.DWRITE_GLYPH_RUN{
            .fontFace = face,
            .fontEmSize = self.font.font_em_size,
            .glyphCount = @intCast(count),
            .glyphIndices = &self.glyph_indices,
            .glyphAdvances = &self.glyph_advances,
            .glyphOffsets = null,
            .isSideways = 0,
            .bidiLevel = 0,
        };

        self.fg_brush.SetColor(&.{ .r = fg[0], .g = fg[1], .b = fg[2] });
        self.fg_brush.SetOpacity(1.0);
        self.target.DrawGlyphRun(
            .{ .x = start_x, .y = row_y + self.font.ascent_px },
            &glyph_run,
            self.fg_brush.asBrush(),
            dw.DWRITE_MEASURING_MODE_NATURAL,
        );
    }

    fn releaseOwnedFaces(_: *D2dRenderer, faces: []?*dw.IDWriteFontFace) void {
        for (faces) |f| {
            if (f) |face| _ = face.vtable.Release(face);
        }
    }

    fn resolveBg(style: ghostty.Style, raw: *const ghostty.Cell, colors: *const ghostty.RenderState.Colors, is_selected: bool, is_inverse: bool, dbg_r: f32, dbg_g: f32, dbg_b: f32) [3]f32 {
        if (is_selected or is_inverse) {
            const rgb = style.fg(.{
                .default = colors.foreground,
                .palette = &colors.palette,
            });
            return .{ colorF(rgb.r), colorF(rgb.g), colorF(rgb.b) };
        }
        if (style.bg(raw, &colors.palette)) |rgb| {
            return .{ colorF(rgb.r), colorF(rgb.g), colorF(rgb.b) };
        }
        return .{ dbg_r, dbg_g, dbg_b };
    }

    fn resolveFg(style: ghostty.Style, raw: *const ghostty.Cell, colors: *const ghostty.RenderState.Colors, is_selected: bool, is_inverse: bool) ghostty.color.RGB {
        if (is_selected or is_inverse) {
            return style.bg(raw, &colors.palette) orelse colors.background;
        }
        return style.fg(.{
            .default = colors.foreground,
            .palette = &colors.palette,
            .bold = .bright,
        });
    }

    const SCROLLBAR_W: f32 = 8.0;
    const SCROLLBAR_MIN_H: f32 = 16.0;

    const BlockRect = struct { x0: f32, y0: f32, x1: f32, y1: f32, alpha: f32 };

    fn isBlockElement(cp: u21) bool {
        return cp >= 0x2580 and cp <= 0x2595;
    }

    fn blockElementRect(cp: u21) ?BlockRect {
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
            0x2591 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 0.25 },
            0x2592 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 0.5 },
            0x2593 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 0.75 },
            0x2594 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1.0 / 8.0, .alpha = 1 },
            0x2595 => .{ .x0 = 7.0 / 8.0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 1 },
            else => null,
        };
    }
};
