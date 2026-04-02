const std = @import("std");
const ghostty = @import("ghostty-vt");
const gl = @import("opengl.zig");
const FontAtlas = @import("font_atlas.zig").FontAtlas;

pub const GlRenderer = struct {
    atlas: FontAtlas,

    const BG_R: gl.GLclampf = 30.0 / 255.0;
    const BG_G: gl.GLclampf = 30.0 / 255.0;
    const BG_B: gl.GLclampf = 30.0 / 255.0;
    const TEXT_R: gl.GLfloat = 204.0 / 255.0;
    const TEXT_G: gl.GLfloat = 204.0 / 255.0;
    const TEXT_B: gl.GLfloat = 204.0 / 255.0;
    const CURSOR_R: gl.GLfloat = 180.0 / 255.0;
    const CURSOR_G: gl.GLfloat = 180.0 / 255.0;
    const CURSOR_B: gl.GLfloat = 180.0 / 255.0;

    pub fn init(font_height: c_int, cell_w: u32, cell_h: u32) !GlRenderer {
        return .{
            .atlas = try FontAtlas.init(font_height, cell_w, cell_h),
        };
    }

    pub fn deinit(self: *GlRenderer) void {
        self.atlas.deinit();
    }

    pub fn render(
        self: *GlRenderer,
        terminal: *ghostty.Terminal,
        alloc: std.mem.Allocator,
        cell_w: c_int,
        cell_h: c_int,
        vp_w: c_int,
        vp_h: c_int,
    ) void {
        // Set up orthographic projection (top-left origin, y-down)
        gl.glViewport(0, 0, vp_w, vp_h);
        gl.glMatrixMode(gl.GL_PROJECTION);
        gl.glLoadIdentity();
        gl.glOrtho(0, @floatFromInt(vp_w), @floatFromInt(vp_h), 0, -1, 1);
        gl.glMatrixMode(gl.GL_MODELVIEW);
        gl.glLoadIdentity();

        // Clear background
        gl.glClearColor(BG_R, BG_G, BG_B, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        // Enable texturing and blending
        gl.glEnable(gl.GL_TEXTURE_2D);
        gl.glEnable(gl.GL_BLEND);
        gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);

        // Bind font atlas texture
        gl.glBindTexture(gl.GL_TEXTURE_2D, self.atlas.texture_id);

        // Get terminal text
        const text = terminal.plainString(alloc) catch return;
        defer alloc.free(text);

        const cw: gl.GLfloat = @floatFromInt(cell_w);
        const ch: gl.GLfloat = @floatFromInt(cell_h);

        // Draw text as textured quads
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
                const y0 = row * ch;
                const x1 = x0 + cw;
                const y1 = y0 + ch;

                gl.glTexCoord2f(uv.u0, uv.v0);
                gl.glVertex2f(x0, y0);
                gl.glTexCoord2f(uv.u1, uv.v0);
                gl.glVertex2f(x1, y0);
                gl.glTexCoord2f(uv.u1, uv.v1);
                gl.glVertex2f(x1, y1);
                gl.glTexCoord2f(uv.u0, uv.v1);
                gl.glVertex2f(x0, y1);

                col += 1;
            }
            row += 1;
        }
        gl.glEnd();

        // Draw cursor (untextured colored quad)
        gl.glDisable(gl.GL_TEXTURE_2D);
        const cursor_x: gl.GLfloat = @floatFromInt(terminal.screens.active.cursor.x);
        const cursor_y: gl.GLfloat = @floatFromInt(terminal.screens.active.cursor.y);
        const cx0 = cursor_x * cw;
        const cy0 = cursor_y * ch;
        const cx1 = cx0 + cw;
        const cy1 = cy0 + ch;

        gl.glColor4f(CURSOR_R, CURSOR_G, CURSOR_B, 0.7);
        gl.glBegin(gl.GL_QUADS);
        gl.glVertex2f(cx0, cy0);
        gl.glVertex2f(cx1, cy0);
        gl.glVertex2f(cx1, cy1);
        gl.glVertex2f(cx0, cy1);
        gl.glEnd();

        gl.glDisable(gl.GL_BLEND);
    }
};
