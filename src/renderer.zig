const std = @import("std");
const ghostty = @import("ghostty-vt");
const gl = @import("opengl.zig");
const FontAtlas = @import("font_atlas.zig").FontAtlas;

pub const GlRenderer = struct {
    atlas: FontAtlas,

    // Terminal colors
    const BG_R: gl.GLclampf = 30.0 / 255.0;
    const BG_G: gl.GLclampf = 30.0 / 255.0;
    const BG_B: gl.GLclampf = 30.0 / 255.0;
    const TEXT_R: gl.GLfloat = 204.0 / 255.0;
    const TEXT_G: gl.GLfloat = 204.0 / 255.0;
    const TEXT_B: gl.GLfloat = 204.0 / 255.0;
    const CURSOR_R: gl.GLfloat = 180.0 / 255.0;
    const CURSOR_G: gl.GLfloat = 180.0 / 255.0;
    const CURSOR_B: gl.GLfloat = 180.0 / 255.0;

    // Tab bar colors
    const TAB_BAR_R: gl.GLfloat = 20.0 / 255.0;
    const TAB_BAR_G: gl.GLfloat = 20.0 / 255.0;
    const TAB_BAR_B: gl.GLfloat = 20.0 / 255.0;
    const TAB_ACTIVE_R: gl.GLfloat = 50.0 / 255.0;
    const TAB_ACTIVE_G: gl.GLfloat = 50.0 / 255.0;
    const TAB_ACTIVE_B: gl.GLfloat = 50.0 / 255.0;
    const TAB_TEXT_R: gl.GLfloat = 180.0 / 255.0;
    const TAB_TEXT_G: gl.GLfloat = 180.0 / 255.0;
    const TAB_TEXT_B: gl.GLfloat = 180.0 / 255.0;

    pub fn init(font_family: [*:0]const u16, font_height: c_int, cell_w: u32, cell_h: u32) !GlRenderer {
        return .{
            .atlas = try FontAtlas.init(font_family, font_height, cell_w, cell_h),
        };
    }

    pub fn deinit(self: *GlRenderer) void {
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

        // Full-window projection (top-left origin, y-down)
        gl.glViewport(0, 0, client_w, client_h);
        gl.glMatrixMode(gl.GL_PROJECTION);
        gl.glLoadIdentity();
        gl.glOrtho(0, @floatFromInt(client_w), @floatFromInt(client_h), 0, -1, 1);
        gl.glMatrixMode(gl.GL_MODELVIEW);
        gl.glLoadIdentity();

        // Clear entire background
        gl.glClearColor(BG_R, BG_G, BG_B, 1.0);
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

        for (0..tab_count) |i| {
            const is_dragged = if (dragged_tab) |dt| (i == dt) else false;
            const tab_x: gl.GLfloat = if (is_dragged)
                @as(gl.GLfloat, @floatFromInt(drag_x)) - tw / 2.0
            else
                @as(gl.GLfloat, @floatFromInt(i)) * tw;

            // Tab background
            gl.glDisable(gl.GL_TEXTURE_2D);
            if (i == active_tab) {
                gl.glColor3f(TAB_ACTIVE_R, TAB_ACTIVE_G, TAB_ACTIVE_B);
            } else {
                gl.glColor3f(BG_R, BG_G, BG_B);
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
        alloc: std.mem.Allocator,
        cell_w: c_int,
        cell_h: c_int,
        vp_w: c_int,
        vp_h: c_int,
        y_offset: c_int,
    ) void {
        _ = vp_w;
        _ = vp_h;
        const y_off: gl.GLfloat = @floatFromInt(y_offset);

        gl.glEnable(gl.GL_TEXTURE_2D);
        gl.glEnable(gl.GL_BLEND);
        gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
        gl.glBindTexture(gl.GL_TEXTURE_2D, self.atlas.texture_id);

        const text = terminal.plainString(alloc) catch return;
        defer alloc.free(text);

        const cw: gl.GLfloat = @floatFromInt(cell_w);
        const ch: gl.GLfloat = @floatFromInt(cell_h);

        gl.glColor3f(TEXT_R, TEXT_G, TEXT_B);
        gl.glBegin(gl.GL_QUADS);

        var row: gl.GLfloat = 0;
        var iter = std.mem.splitSequence(u8, text, "\n");
        while (iter.next()) |line| {
            if (line.len == 0) {
                row += 1;
                continue;
            }

            var col: gl.GLfloat = 0;
            var utf8_view = std.unicode.Utf8View.init(line) catch {
                row += 1;
                continue;
            };
            var cp_iter = utf8_view.iterator();
            while (cp_iter.nextCodepoint()) |cp| {
                const uv = self.atlas.getUV(cp);
                const x0 = col * cw;
                const y0 = row * ch + y_off;

                gl.glTexCoord2f(uv.u0, uv.v0);
                gl.glVertex2f(x0, y0);
                gl.glTexCoord2f(uv.u1, uv.v0);
                gl.glVertex2f(x0 + cw, y0);
                gl.glTexCoord2f(uv.u1, uv.v1);
                gl.glVertex2f(x0 + cw, y0 + ch);
                gl.glTexCoord2f(uv.u0, uv.v1);
                gl.glVertex2f(x0, y0 + ch);

                col += 1;
            }
            row += 1;
        }
        gl.glEnd();

        // Cursor
        gl.glDisable(gl.GL_TEXTURE_2D);
        const cursor_x: gl.GLfloat = @floatFromInt(terminal.screens.active.cursor.x);
        const cursor_y: gl.GLfloat = @floatFromInt(terminal.screens.active.cursor.y);
        const cx0 = cursor_x * cw;
        const cy0 = cursor_y * ch + y_off;

        gl.glColor4f(CURSOR_R, CURSOR_G, CURSOR_B, 0.7);
        gl.glBegin(gl.GL_QUADS);
        gl.glVertex2f(cx0, cy0);
        gl.glVertex2f(cx0 + cw, cy0);
        gl.glVertex2f(cx0 + cw, cy0 + ch);
        gl.glVertex2f(cx0, cy0 + ch);
        gl.glEnd();

        gl.glDisable(gl.GL_BLEND);
    }
};
