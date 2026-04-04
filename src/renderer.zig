const std = @import("std");
const ghostty = @import("ghostty-vt");
const gl = @import("opengl.zig");
const FontAtlas = @import("font_atlas.zig").FontAtlas;

// Inline GLSL shaders
const bg_vert_src: [*:0]const u8 =
    \\#version 330
    \\layout(location=0) in vec2 aPos;
    \\layout(location=1) in vec4 aColor;
    \\uniform vec2 uScreen;
    \\out vec4 vColor;
    \\void main() {
    \\    vec2 ndc = aPos / uScreen * 2.0 - 1.0;
    \\    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
    \\    vColor = aColor;
    \\}
;

const bg_frag_src: [*:0]const u8 =
    \\#version 330
    \\in vec4 vColor;
    \\out vec4 fragColor;
    \\void main() {
    \\    fragColor = vColor;
    \\}
;

const text_vert_src: [*:0]const u8 =
    \\#version 330
    \\layout(location=0) in vec2 aPos;
    \\layout(location=1) in vec2 aTexCoord;
    \\layout(location=2) in vec3 aFgColor;
    \\layout(location=3) in vec3 aBgColor;
    \\uniform vec2 uScreen;
    \\out vec2 vTexCoord;
    \\out vec3 vFgColor;
    \\out vec3 vBgColor;
    \\void main() {
    \\    vec2 ndc = aPos / uScreen * 2.0 - 1.0;
    \\    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
    \\    vTexCoord = aTexCoord;
    \\    vFgColor = aFgColor;
    \\    vBgColor = aBgColor;
    \\}
;

const text_frag_src: [*:0]const u8 =
    \\#version 330
    \\in vec2 vTexCoord;
    \\in vec3 vFgColor;
    \\in vec3 vBgColor;
    \\uniform sampler2D uAtlas;
    \\out vec4 fragColor;
    \\void main() {
    \\    vec3 alpha = texture(uAtlas, vTexCoord).rgb;
    \\    if (alpha == vec3(0.0)) discard;
    \\    vec3 color = vFgColor * alpha + vBgColor * (1.0 - alpha);
    \\    fragColor = vec4(color, 1.0);
    \\}
;

// Vertex types
const BgVertex = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

const TextVertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    fg_r: f32,
    fg_g: f32,
    fg_b: f32,
    bg_r: f32,
    bg_g: f32,
    bg_b: f32,
};

const MAX_QUADS = 40000;
const BG_VERTS = MAX_QUADS * 6;
const TEXT_VERTS = MAX_QUADS * 6;

pub const GlRenderer = struct {
    atlas: FontAtlas,
    alloc: std.mem.Allocator,
    render_state: ghostty.RenderState = .empty,
    f: gl.GlFuncs,

    // Default terminal background
    default_bg_r: f32,
    default_bg_g: f32,
    default_bg_b: f32,

    // Shader programs
    bg_program: gl.GLuint = 0,
    text_program: gl.GLuint = 0,

    // Background pass GPU objects
    bg_vao: gl.GLuint = 0,
    bg_vbo: gl.GLuint = 0,
    bg_screen_loc: gl.GLint = -1,

    // Text pass GPU objects
    text_vao: gl.GLuint = 0,
    text_vbo: gl.GLuint = 0,
    text_screen_loc: gl.GLint = -1,
    text_atlas_loc: gl.GLint = -1,

    // CPU vertex buffers
    bg_buf: []BgVertex,
    text_buf: []TextVertex,

    // Tab bar colors (keep hardcoded)
    const TAB_BAR_R: gl.GLfloat = 20.0 / 255.0;
    const TAB_BAR_G: gl.GLfloat = 20.0 / 255.0;
    const TAB_BAR_B: gl.GLfloat = 20.0 / 255.0;
    const TAB_ACTIVE_R: gl.GLfloat = 50.0 / 255.0;
    const TAB_ACTIVE_G: gl.GLfloat = 50.0 / 255.0;
    const TAB_ACTIVE_B: gl.GLfloat = 50.0 / 255.0;
    const TAB_TEXT_R: gl.GLfloat = 180.0 / 255.0;
    const TAB_TEXT_G: gl.GLfloat = 180.0 / 255.0;
    const TAB_TEXT_B: gl.GLfloat = 180.0 / 255.0;

    fn colorF(v: u8) f32 {
        return @as(f32, @floatFromInt(v)) / 255.0;
    }

    pub fn init(alloc: std.mem.Allocator, font_family: [*:0]const u16, font_height: c_int, cell_w: u32, cell_h: u32, bg_rgb: ?[3]u8, gl_funcs: ?gl.GlFuncs) !GlRenderer {
        const bg = bg_rgb orelse [3]u8{ 30, 30, 30 };
        const f = gl_funcs orelse return error.GlFuncsNotAvailable;

        // Compile shaders
        const bg_vert = try gl.compileShaderSource(&f, gl.GL_VERTEX_SHADER, bg_vert_src);
        defer f.deleteShader(bg_vert);
        const bg_frag = try gl.compileShaderSource(&f, gl.GL_FRAGMENT_SHADER, bg_frag_src);
        defer f.deleteShader(bg_frag);
        const bg_prog = try gl.linkShaderProgram(&f, bg_vert, bg_frag);

        const text_vert = try gl.compileShaderSource(&f, gl.GL_VERTEX_SHADER, text_vert_src);
        defer f.deleteShader(text_vert);
        const text_frag = try gl.compileShaderSource(&f, gl.GL_FRAGMENT_SHADER, text_frag_src);
        defer f.deleteShader(text_frag);
        const text_prog = try gl.linkShaderProgram(&f, text_vert, text_frag);

        // --- Background VAO/VBO ---
        var bg_vao: gl.GLuint = 0;
        var bg_vbo: gl.GLuint = 0;
        f.genVertexArrays(1, @ptrCast(&bg_vao));
        f.genBuffers(1, @ptrCast(&bg_vbo));
        f.bindVertexArray(bg_vao);
        f.bindBuffer(gl.GL_ARRAY_BUFFER, bg_vbo);
        f.bufferData(gl.GL_ARRAY_BUFFER, @intCast(BG_VERTS * @sizeOf(BgVertex)), null, gl.GL_DYNAMIC_DRAW);
        // aPos (location=0): 2 floats at offset 0
        f.vertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(BgVertex), @ptrFromInt(0));
        f.enableVertexAttribArray(0);
        // aColor (location=1): 4 floats at offset 8
        f.vertexAttribPointer(1, 4, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(BgVertex), @ptrFromInt(8));
        f.enableVertexAttribArray(1);

        // --- Text VAO/VBO ---
        var text_vao: gl.GLuint = 0;
        var text_vbo: gl.GLuint = 0;
        f.genVertexArrays(1, @ptrCast(&text_vao));
        f.genBuffers(1, @ptrCast(&text_vbo));
        f.bindVertexArray(text_vao);
        f.bindBuffer(gl.GL_ARRAY_BUFFER, text_vbo);
        f.bufferData(gl.GL_ARRAY_BUFFER, @intCast(TEXT_VERTS * @sizeOf(TextVertex)), null, gl.GL_DYNAMIC_DRAW);
        // aPos (location=0): 2 floats at offset 0
        f.vertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(TextVertex), @ptrFromInt(0));
        f.enableVertexAttribArray(0);
        // aTexCoord (location=1): 2 floats at offset 8
        f.vertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(TextVertex), @ptrFromInt(8));
        f.enableVertexAttribArray(1);
        // aFgColor (location=2): 3 floats at offset 16
        f.vertexAttribPointer(2, 3, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(TextVertex), @ptrFromInt(16));
        f.enableVertexAttribArray(2);
        // aBgColor (location=3): 3 floats at offset 28
        f.vertexAttribPointer(3, 3, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(TextVertex), @ptrFromInt(28));
        f.enableVertexAttribArray(3);

        // Unbind
        f.bindVertexArray(0);

        // Get uniform locations
        const bg_screen_loc = f.getUniformLocation(bg_prog, "uScreen");
        const text_screen_loc = f.getUniformLocation(text_prog, "uScreen");
        const text_atlas_loc = f.getUniformLocation(text_prog, "uAtlas");

        // Allocate CPU vertex buffers
        const bg_buf = try alloc.alloc(BgVertex, BG_VERTS);
        const text_buf = try alloc.alloc(TextVertex, TEXT_VERTS);

        return .{
            .atlas = try FontAtlas.init(alloc, font_family, font_height, cell_w, cell_h),
            .alloc = alloc,
            .f = f,
            .default_bg_r = colorF(bg[0]),
            .default_bg_g = colorF(bg[1]),
            .default_bg_b = colorF(bg[2]),
            .bg_program = bg_prog,
            .text_program = text_prog,
            .bg_vao = bg_vao,
            .bg_vbo = bg_vbo,
            .bg_screen_loc = bg_screen_loc,
            .text_vao = text_vao,
            .text_vbo = text_vbo,
            .text_screen_loc = text_screen_loc,
            .text_atlas_loc = text_atlas_loc,
            .bg_buf = bg_buf,
            .text_buf = text_buf,
        };
    }

    pub fn invalidate(self: *GlRenderer) void {
        self.render_state.rows = 0;
        self.render_state.cols = 0;
        self.render_state.viewport_pin = null;
    }

    pub fn deinit(self: *GlRenderer) void {
        self.render_state.deinit(self.alloc);
        self.alloc.free(self.bg_buf);
        self.alloc.free(self.text_buf);
        if (self.bg_vao != 0) self.f.deleteVertexArrays(1, @ptrCast(&self.bg_vao));
        if (self.bg_vbo != 0) self.f.deleteBuffers(1, @ptrCast(&self.bg_vbo));
        if (self.text_vao != 0) self.f.deleteVertexArrays(1, @ptrCast(&self.text_vao));
        if (self.text_vbo != 0) self.f.deleteBuffers(1, @ptrCast(&self.text_vbo));
        if (self.bg_program != 0) self.f.deleteProgram(self.bg_program);
        if (self.text_program != 0) self.f.deleteProgram(self.text_program);
        self.atlas.deinit();
    }

    // --- Emit helpers (append 6 vertices = 2 triangles = 1 quad) ---

    inline fn emitBgQuad(buf: []BgVertex, count: *usize, x0: f32, y0: f32, x1: f32, y1: f32, r: f32, g: f32, b: f32, a: f32) void {
        if (count.* + 6 > buf.len) return;
        const i = count.*;
        buf[i + 0] = .{ .x = x0, .y = y0, .r = r, .g = g, .b = b, .a = a };
        buf[i + 1] = .{ .x = x1, .y = y0, .r = r, .g = g, .b = b, .a = a };
        buf[i + 2] = .{ .x = x1, .y = y1, .r = r, .g = g, .b = b, .a = a };
        buf[i + 3] = .{ .x = x0, .y = y0, .r = r, .g = g, .b = b, .a = a };
        buf[i + 4] = .{ .x = x1, .y = y1, .r = r, .g = g, .b = b, .a = a };
        buf[i + 5] = .{ .x = x0, .y = y1, .r = r, .g = g, .b = b, .a = a };
        count.* += 6;
    }

    inline fn emitTextQuad(buf: []TextVertex, count: *usize, x0: f32, y0: f32, x1: f32, y1: f32, tu0: f32, tv0: f32, tu1: f32, tv1: f32, fg_r: f32, fg_g: f32, fg_b: f32, bg_r: f32, bg_g: f32, bg_b: f32) void {
        if (count.* + 6 > buf.len) return;
        const i = count.*;
        buf[i + 0] = .{ .x = x0, .y = y0, .u = tu0, .v = tv0, .fg_r = fg_r, .fg_g = fg_g, .fg_b = fg_b, .bg_r = bg_r, .bg_g = bg_g, .bg_b = bg_b };
        buf[i + 1] = .{ .x = x1, .y = y0, .u = tu1, .v = tv0, .fg_r = fg_r, .fg_g = fg_g, .fg_b = fg_b, .bg_r = bg_r, .bg_g = bg_g, .bg_b = bg_b };
        buf[i + 2] = .{ .x = x1, .y = y1, .u = tu1, .v = tv1, .fg_r = fg_r, .fg_g = fg_g, .fg_b = fg_b, .bg_r = bg_r, .bg_g = bg_g, .bg_b = bg_b };
        buf[i + 3] = .{ .x = x0, .y = y0, .u = tu0, .v = tv0, .fg_r = fg_r, .fg_g = fg_g, .fg_b = fg_b, .bg_r = bg_r, .bg_g = bg_g, .bg_b = bg_b };
        buf[i + 4] = .{ .x = x1, .y = y1, .u = tu1, .v = tv1, .fg_r = fg_r, .fg_g = fg_g, .fg_b = fg_b, .bg_r = bg_r, .bg_g = bg_g, .bg_b = bg_b };
        buf[i + 5] = .{ .x = x0, .y = y1, .u = tu0, .v = tv1, .fg_r = fg_r, .fg_g = fg_g, .fg_b = fg_b, .bg_r = bg_r, .bg_g = bg_g, .bg_b = bg_b };
        count.* += 6;
    }

    // === Tab bar (legacy GL — will be ported later) ===

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

        // Use legacy GL for tab bar (compatibility profile)
        self.f.useProgram(0);
        self.f.bindVertexArray(0);

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

        // Pre-cache tab title glyphs
        for (0..tab_count) |i| {
            var pre_buf: [16]u8 = undefined;
            const pre_title = std.fmt.bufPrint(&pre_buf, "Tab {d}", .{i + 1}) catch unreachable;
            for (pre_title) |ch| {
                _ = self.atlas.getOrRenderGlyph(ch, false);
            }
        }
        _ = self.atlas.getOrRenderGlyph('x', false);

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

            // Use GL_BLEND tex env: output = vertex_color * (1-tex) + env_color * tex
            // This gives: tab_bg * (1-alpha) + text_color * alpha — proper ClearType blending
            gl.glEnable(gl.GL_TEXTURE_2D);
            gl.glBindTexture(gl.GL_TEXTURE_2D, self.atlas.texture_id);
            gl.glTexEnvi(gl.GL_TEXTURE_ENV, gl.GL_TEXTURE_ENV_MODE, gl.GL_BLEND);
            const text_env = [4]gl.GLfloat{ TAB_TEXT_R, TAB_TEXT_G, TAB_TEXT_B, 1.0 };
            gl.glTexEnvfv(gl.GL_TEXTURE_ENV, gl.GL_TEXTURE_ENV_COLOR, &text_env);
            gl.glDisable(gl.GL_BLEND); // tex env already computes the blend

            // Vertex color = tab background (used as bg in the blend formula)
            const tab_bg_r: gl.GLfloat = if (i == active_tab) TAB_ACTIVE_R else self.default_bg_r;
            const tab_bg_g: gl.GLfloat = if (i == active_tab) TAB_ACTIVE_G else self.default_bg_g;
            const tab_bg_b: gl.GLfloat = if (i == active_tab) TAB_ACTIVE_B else self.default_bg_b;
            gl.glColor3f(tab_bg_r, tab_bg_g, tab_bg_b);

            gl.glBegin(gl.GL_QUADS);
            for (title, 0..) |ch, ci| {
                const glyph = self.atlas.getOrRenderGlyph(ch, false);
                const uv = glyph.uv;
                const cx0 = tab_x + pad + @as(gl.GLfloat, @floatFromInt(ci)) * cell_w;
                const cy0 = text_y;
                const gx0 = cx0 + @as(gl.GLfloat, @floatFromInt(glyph.offset_x));
                const gy0 = cy0 + @as(gl.GLfloat, @floatFromInt(glyph.offset_y));
                const gx1 = gx0 + @as(gl.GLfloat, @floatFromInt(glyph.pixel_w));
                const gy1 = gy0 + @as(gl.GLfloat, @floatFromInt(glyph.pixel_h));
                gl.glTexCoord2f(uv.u0, uv.v0);
                gl.glVertex2f(gx0, gy0);
                gl.glTexCoord2f(uv.u1, uv.v0);
                gl.glVertex2f(gx1, gy0);
                gl.glTexCoord2f(uv.u1, uv.v1);
                gl.glVertex2f(gx1, gy1);
                gl.glTexCoord2f(uv.u0, uv.v1);
                gl.glVertex2f(gx0, gy1);
            }
            gl.glEnd();

            // Close button "x"
            const close_x = tab_x + tw - cbs - pad;
            const close_y = (tbh - cbs) / 2.0;
            const glyph_x = self.atlas.getOrRenderGlyph('x', false);
            const uv_x = glyph_x.uv;
            // Slightly transparent close button: mix text color at 60% with bg
            const close_env = [4]gl.GLfloat{
                TAB_TEXT_R * 0.6 + tab_bg_r * 0.4,
                TAB_TEXT_G * 0.6 + tab_bg_g * 0.4,
                TAB_TEXT_B * 0.6 + tab_bg_b * 0.4,
                1.0,
            };
            gl.glTexEnvfv(gl.GL_TEXTURE_ENV, gl.GL_TEXTURE_ENV_COLOR, &close_env);
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

        // Restore default tex env and blending state
        gl.glTexEnvi(gl.GL_TEXTURE_ENV, gl.GL_TEXTURE_ENV_MODE, gl.GL_MODULATE);
        gl.glEnable(gl.GL_BLEND);
        gl.glDisable(gl.GL_TEXTURE_2D);
    }

    // === Terminal rendering (shader-based) ===

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

        const cw: f32 = @floatFromInt(cell_w);
        const ch: f32 = @floatFromInt(cell_h);
        const y_off: f32 = @floatFromInt(y_offset + padding);
        const x_pad: f32 = @floatFromInt(padding);
        const screen_w: f32 = @floatFromInt(vp_w);
        const screen_h: f32 = @floatFromInt(vp_h);

        const all_cells = row_slice.items(.cells);
        const all_sels = row_slice.items(.selection);

        // Default background color
        const dbg_r = colorF(colors.background.r);
        const dbg_g = colorF(colors.background.g);
        const dbg_b = colorF(colors.background.b);

        // Pre-cache all glyphs
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

        // --- Build vertex buffers ---
        var bg_count: usize = 0;
        var text_count: usize = 0;

        for (0..rows) |y| {
            if (y >= all_cells.len) break;
            const cell_slice = all_cells[y].slice();
            const raws = cell_slice.items(.raw);
            const styles = cell_slice.items(.style);
            const sel_range: ?[2]u16 = if (y < all_sels.len) all_sels[y] else null;

            for (0..cols) |x| {
                if (x >= raws.len) break;
                const raw = raws[x];
                const style = if (raw.style_id != 0) styles[x] else ghostty.Style{};
                const is_inverse = style.flags.inverse;
                const x16: u16 = @intCast(x);
                const is_selected = if (sel_range) |sr| (x16 >= sr[0] and x16 <= sr[1]) else false;

                const width: f32 = if (raw.wide == .wide) 2.0 * cw else cw;
                const fx: f32 = @as(f32, @floatFromInt(x)) * cw + x_pad;
                const fy: f32 = @as(f32, @floatFromInt(y)) * ch + y_off;

                // --- Resolve background color for this cell ---
                const cell_bg = blk: {
                    if (is_selected) {
                        const rgb = style.fg(.{
                            .default = colors.foreground,
                            .palette = &colors.palette,
                        });
                        break :blk [3]f32{ colorF(rgb.r), colorF(rgb.g), colorF(rgb.b) };
                    } else if (is_inverse) {
                        const rgb = style.fg(.{
                            .default = colors.foreground,
                            .palette = &colors.palette,
                        });
                        break :blk [3]f32{ colorF(rgb.r), colorF(rgb.g), colorF(rgb.b) };
                    } else {
                        if (style.bg(&raw, &colors.palette)) |rgb| {
                            break :blk [3]f32{ colorF(rgb.r), colorF(rgb.g), colorF(rgb.b) };
                        }
                        break :blk [3]f32{ dbg_r, dbg_g, dbg_b };
                    }
                };

                // Emit background quad if not default
                if (raw.wide != .spacer_tail) {
                    const is_custom_bg = is_selected or is_inverse or (style.bg(&raw, &colors.palette) != null);
                    if (is_custom_bg) {
                        emitBgQuad(self.bg_buf, &bg_count, fx, fy, fx + width, fy + ch, cell_bg[0], cell_bg[1], cell_bg[2], 1.0);
                    }
                }

                // --- Text ---
                if (!raw.hasText()) continue;
                if (raw.wide == .spacer_tail or raw.wide == .spacer_head) continue;
                const cp = raw.codepoint();
                if (cp == 0) continue;

                if (isBlockElement(cp)) {
                    // Block element: emit as colored background quad
                    const rect = blockElementRect(cp) orelse continue;
                    const fg_rgb = resolveFg(style, &raw, &colors, is_selected, is_inverse);
                    const qx0 = fx + rect.x0 * width;
                    const qy0 = fy + rect.y0 * ch;
                    const qx1 = fx + rect.x1 * width;
                    const qy1 = fy + rect.y1 * ch;
                    emitBgQuad(self.bg_buf, &bg_count, qx0, qy0, qx1, qy1, colorF(fg_rgb.r), colorF(fg_rgb.g), colorF(fg_rgb.b), rect.alpha);
                    continue;
                }

                const is_wide = raw.wide == .wide;
                const glyph = self.atlas.getOrRenderGlyph(cp, is_wide);
                const fg_rgb = resolveFg(style, &raw, &colors, is_selected, is_inverse);
                const uv = glyph.uv;

                // Position quad at actual glyph bounds (offset from cell origin)
                const gx0 = fx + @as(f32, @floatFromInt(glyph.offset_x));
                const gy0 = fy + @as(f32, @floatFromInt(glyph.offset_y));
                const gx1 = gx0 + @as(f32, @floatFromInt(glyph.pixel_w));
                const gy1 = gy0 + @as(f32, @floatFromInt(glyph.pixel_h));

                emitTextQuad(
                    self.text_buf,
                    &text_count,
                    gx0,
                    gy0,
                    gx1,
                    gy1,
                    uv.u0,
                    uv.v0,
                    uv.u1,
                    uv.v1,
                    colorF(fg_rgb.r),
                    colorF(fg_rgb.g),
                    colorF(fg_rgb.b),
                    cell_bg[0],
                    cell_bg[1],
                    cell_bg[2],
                );
            }
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
                    emitBgQuad(self.bg_buf, &bg_count, cx0, cy0, cx0 + cw, cy0 + ch, colorF(cc.r), colorF(cc.g), colorF(cc.b), 0.7);
                } else {
                    emitBgQuad(self.bg_buf, &bg_count, cx0, cy0, cx0 + cw, cy0 + ch, 180.0 / 255.0, 180.0 / 255.0, 180.0 / 255.0, 0.7);
                }
            }
        }

        // --- Scrollbar ---
        const sb = terminal.screens.active.pages.scrollbar();
        if (sb.total > sb.len) {
            const track_h: f32 = @floatFromInt(vp_h - y_offset - padding);
            const track_x: f32 = @as(f32, @floatFromInt(vp_w)) - SCROLLBAR_W;
            const ratio = track_h / @as(f32, @floatFromInt(sb.total));
            const thumb_h = @max(SCROLLBAR_MIN_H, ratio * @as(f32, @floatFromInt(sb.len)));
            const available = track_h - thumb_h;
            const max_offset: f32 = @floatFromInt(sb.total - sb.len);
            const thumb_y = y_off + if (max_offset > 0) @as(f32, @floatFromInt(sb.offset)) / max_offset * available else 0;
            emitBgQuad(self.bg_buf, &bg_count, track_x, thumb_y, track_x + SCROLLBAR_W, thumb_y + thumb_h, 1.0, 1.0, 1.0, 0.3);
        }

        // --- Upload & Draw ---

        // Background pass
        if (bg_count > 0) {
            self.f.useProgram(self.bg_program);
            self.f.uniform2f(self.bg_screen_loc, screen_w, screen_h);
            gl.glEnable(gl.GL_BLEND);
            gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
            self.f.bindVertexArray(self.bg_vao);
            self.f.bindBuffer(gl.GL_ARRAY_BUFFER, self.bg_vbo);
            self.f.bufferSubData(gl.GL_ARRAY_BUFFER, 0, @intCast(bg_count * @sizeOf(BgVertex)), @ptrCast(self.bg_buf.ptr));
            self.f.drawArrays(gl.GL_TRIANGLES, 0, @intCast(bg_count));
        }

        // Text pass (ClearType subpixel blending in shader — no hardware alpha blend needed)
        if (text_count > 0) {
            self.f.useProgram(self.text_program);
            self.f.uniform2f(self.text_screen_loc, screen_w, screen_h);
            self.f.activeTexture(0x84C0); // GL_TEXTURE0
            gl.glBindTexture(gl.GL_TEXTURE_2D, self.atlas.texture_id);
            self.f.uniform1i(self.text_atlas_loc, 0);
            gl.glDisable(gl.GL_BLEND); // Shader does per-channel blending, output is opaque
            self.f.bindVertexArray(self.text_vao);
            self.f.bindBuffer(gl.GL_ARRAY_BUFFER, self.text_vbo);
            self.f.bufferSubData(gl.GL_ARRAY_BUFFER, 0, @intCast(text_count * @sizeOf(TextVertex)), @ptrCast(self.text_buf.ptr));
            self.f.drawArrays(gl.GL_TRIANGLES, 0, @intCast(text_count));
        }

        // Restore state for legacy tab bar
        self.f.bindVertexArray(0);
        self.f.useProgram(0);
        gl.glEnable(gl.GL_BLEND);
    }

    fn resolveFg(style: ghostty.Style, raw: *const ghostty.Cell, colors: *const ghostty.RenderState.Colors, is_selected: bool, is_inverse: bool) ghostty.color.RGB {
        if (is_selected) {
            return style.bg(raw, &colors.palette) orelse colors.background;
        } else if (is_inverse) {
            return style.bg(raw, &colors.palette) orelse colors.background;
        } else {
            return style.fg(.{
                .default = colors.foreground,
                .palette = &colors.palette,
                .bold = .bright,
            });
        }
    }

    const SCROLLBAR_W: f32 = 8.0;
    const SCROLLBAR_MIN_H: f32 = 16.0;

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
