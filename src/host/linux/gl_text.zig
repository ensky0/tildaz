//! 글리프 사각형 배치 드로 ([#277](https://github.com/ensky0/tildaz/issues/277) S2-4).
//!
//! atlas 의 글리프를 셀 위치에 사각형으로 그린다. grayscale 과 컬러가 **다른
//! 텍스처**라 (`gl_atlas` 참고) 정점 목록도 둘로 나눠 모으고 각각 한 번씩 그린다 —
//! 한 draw call 안에서 두 텍스처를 조건부로 샘플링하는 것보다 단순하고 빠르다.
//!
//! ## 블렌딩이 software 경로와 같은 결과를 주는 이유
//!
//! 셰이더는 **premultiplied** 색을 내보내고 `ONE / ONE_MINUS_SRC_ALPHA` 로 섞는다.
//! 프레임버퍼는 비-sRGB 라 (#277 에서 그렇게 유지하기로 했다) 값 그대로 gamma
//! space 에서 섞이고, 그게 software 의 `blendPixel` 과 같은 식이다:
//!
//!   software : out = fg·a + dst·(1−a)          (gamma space 직선 블렌드)
//!   GL       : out = (fg·a) + dst·(1−a)        (premultiplied src, 같은 식)
//!
//! sRGB 프레임버퍼를 쓰면 GPU 가 linear space 로 변환해 섞어 결과가 달라진다 —
//! 그래서 `EGL_KHR_gl_colorspace` 의 `_SRGB` 를 쓰지 않는다.
//!
//! 컬러 emoji 는 FreeType 이 이미 premultiplied BGRA 로 주므로 fg 색을 곱하지 않고
//! 텍셀을 그대로 낸다.

const std = @import("std");
const egl = @import("egl.zig");
const gl_atlas = @import("gl_atlas.zig");

/// 정점 — 위치(px) + atlas UV(0..1) + fg 색.
const Vertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

const vertex_src: [*:0]const u8 =
    \\precision highp float;
    \\attribute vec2 a_pos;
    \\attribute vec2 a_uv;
    \\attribute vec4 a_color;
    \\uniform vec2 u_viewport;
    \\varying vec2 v_uv;
    \\varying vec4 v_color;
    \\void main() {
    \\    // 픽셀 좌표(좌상단 원점) → clip space. y 를 뒤집지 않는다 — dma-buf 를
    \\    // FBO 로 쓰면 GL 의 y=0 행이 메모리 첫 행이고 Wayland 는 그 행을 화면
    \\    // 맨 위에 표시한다 (#277 S0-b 실측).
    \\    vec2 ndc = vec2(a_pos.x / u_viewport.x * 2.0 - 1.0,
    \\                    a_pos.y / u_viewport.y * 2.0 - 1.0);
    \\    gl_Position = vec4(ndc, 0.0, 1.0);
    \\    v_uv = a_uv;
    \\    v_color = a_color;
    \\}
;

/// grayscale — atlas 의 `.a` 를 커버리지로 쓰고 fg 색을 곱한다. 결과는
/// premultiplied 다 (rgb 에 이미 a 가 곱해져 나간다).
const fragment_gray_src: [*:0]const u8 =
    \\precision mediump float;
    \\uniform sampler2D u_atlas;
    \\varying vec2 v_uv;
    \\varying vec4 v_color;
    \\void main() {
    \\    float coverage = texture2D(u_atlas, v_uv).a * v_color.a;
    \\    gl_FragColor = vec4(v_color.rgb * coverage, coverage);
    \\}
;

/// 컬러 emoji — FreeType 이 premultiplied BGRA 로 주고 atlas 에 RGBA 순서로
/// 올렸으므로 텍셀을 그대로 낸다 (fg 색을 곱하지 않는다).
const fragment_color_src: [*:0]const u8 =
    \\precision mediump float;
    \\uniform sampler2D u_atlas;
    \\varying vec2 v_uv;
    \\varying vec4 v_color;
    \\void main() {
    \\    gl_FragColor = texture2D(u_atlas, v_uv) * v_color.a;
    \\}
;

/// 그릴 글리프 하나 — atlas 위치와 화면 위치, 색.
pub const Quad = struct {
    /// 글리프 좌상단 화면 좌표 (px). bearing 이 이미 반영된 값.
    x: f32,
    y: f32,
    entry: gl_atlas.AtlasEntry,
    /// 0..1. 컬러 글리프면 rgb 는 무시되고 a 만 쓰인다.
    color: [4]f32,
};

const Program = struct {
    id: u32,
    uniform_viewport: i32,
    uniform_atlas: i32,
};

pub const Batch = struct {
    gray_program: Program,
    color_program: Program,
    buffer: u32,
    gray: std.ArrayList(Vertex) = .{},
    color: std.ArrayList(Vertex) = .{},

    pub fn create(api: *const egl.Api) ?Batch {
        const vs = compile(api, egl.GL_VERTEX_SHADER, vertex_src) orelse return null;
        defer api.deleteShader(vs);

        const gray = link(api, vs, fragment_gray_src) orelse return null;
        const color = link(api, vs, fragment_color_src) orelse {
            api.deleteProgram(gray.id);
            return null;
        };

        var buffer: u32 = 0;
        api.genBuffers(1, @ptrCast(&buffer));
        return .{ .gray_program = gray, .color_program = color, .buffer = buffer };
    }

    pub fn deinit(self: *Batch, api: *const egl.Api, allocator: std.mem.Allocator) void {
        self.gray.deinit(allocator);
        self.color.deinit(allocator);
        var buf = self.buffer;
        api.deleteBuffers(1, @ptrCast(&buf));
        api.deleteProgram(self.color_program.id);
        api.deleteProgram(self.gray_program.id);
    }

    pub fn clear(self: *Batch) void {
        self.gray.clearRetainingCapacity();
        self.color.clearRetainingCapacity();
    }

    /// 글리프 하나를 삼각형 2 개로 쌓는다. 크기 0 인 글리프(공백 등)는 무시한다.
    pub fn add(self: *Batch, allocator: std.mem.Allocator, quad: Quad) void {
        if (quad.entry.w == 0 or quad.entry.h == 0) return;
        const list = if (quad.entry.is_color) &self.color else &self.gray;

        const inv_atlas: f32 = 1.0 / @as(f32, @floatFromInt(gl_atlas.ATLAS_SIZE));
        const uv_x0 = @as(f32, @floatFromInt(quad.entry.x)) * inv_atlas;
        const uv_y0 = @as(f32, @floatFromInt(quad.entry.y)) * inv_atlas;
        const uv_x1 = @as(f32, @floatFromInt(quad.entry.x + quad.entry.w)) * inv_atlas;
        const uv_y1 = @as(f32, @floatFromInt(quad.entry.y + quad.entry.h)) * inv_atlas;

        const x0 = quad.x;
        const y0 = quad.y;
        const x1 = quad.x + @as(f32, @floatFromInt(quad.entry.w));
        const y1 = quad.y + @as(f32, @floatFromInt(quad.entry.h));

        const corners = [6][4]f32{
            .{ x0, y0, uv_x0, uv_y0 },
            .{ x1, y0, uv_x1, uv_y0 },
            .{ x0, y1, uv_x0, uv_y1 },
            .{ x1, y0, uv_x1, uv_y0 },
            .{ x1, y1, uv_x1, uv_y1 },
            .{ x0, y1, uv_x0, uv_y1 },
        };
        for (corners) |c| {
            list.append(allocator, .{
                .x = c[0],
                .y = c[1],
                .u = c[2],
                .v = c[3],
                .r = quad.color[0],
                .g = quad.color[1],
                .b = quad.color[2],
                .a = quad.color[3],
            }) catch return;
        }
    }

    /// 쌓인 글리프를 그린다. grayscale → 컬러 순서로 두 번 그린다.
    ///
    /// 호출 전에 배경 사각형이 이미 그려져 있어야 한다 — 텍스트는 그 위에 알파
    /// 블렌딩된다 (#361 의 "배경 전부 → 텍스트 전부" 순서).
    pub fn flush(self: *Batch, api: *const egl.Api, atlas: *const gl_atlas.Atlas, viewport_w: f32, viewport_h: f32) void {
        if (self.gray.items.len == 0 and self.color.items.len == 0) return;

        api.enable(egl.GL_BLEND);
        api.blendFunc(egl.GL_ONE, egl.GL_ONE_MINUS_SRC_ALPHA);
        api.activeTexture(egl.GL_TEXTURE0);

        self.draw(api, self.gray_program, self.gray.items, atlas.grayTexture(), viewport_w, viewport_h);
        self.draw(api, self.color_program, self.color.items, atlas.colorTexture(), viewport_w, viewport_h);

        api.disable(egl.GL_BLEND);
    }

    fn draw(
        self: *Batch,
        api: *const egl.Api,
        program: Program,
        vertices: []const Vertex,
        texture: u32,
        viewport_w: f32,
        viewport_h: f32,
    ) void {
        if (vertices.len == 0) return;
        api.useProgram(program.id);
        api.uniform2f(program.uniform_viewport, viewport_w, viewport_h);
        api.uniform1i(program.uniform_atlas, 0);
        api.bindTexture(egl.GL_TEXTURE_2D, texture);
        api.bindBuffer(egl.GL_ARRAY_BUFFER, self.buffer);
        api.bufferData(
            egl.GL_ARRAY_BUFFER,
            @intCast(vertices.len * @sizeOf(Vertex)),
            vertices.ptr,
            egl.GL_STREAM_DRAW,
        );
        api.enableVertexAttribArray(0);
        api.vertexAttribPointer(0, 2, egl.GL_FLOAT, 0, @sizeOf(Vertex), null);
        api.enableVertexAttribArray(1);
        api.vertexAttribPointer(1, 2, egl.GL_FLOAT, 0, @sizeOf(Vertex), @ptrFromInt(@offsetOf(Vertex, "u")));
        api.enableVertexAttribArray(2);
        api.vertexAttribPointer(2, 4, egl.GL_FLOAT, 0, @sizeOf(Vertex), @ptrFromInt(@offsetOf(Vertex, "r")));
        api.drawArrays(egl.GL_TRIANGLES, 0, @intCast(vertices.len));
    }
};

fn link(api: *const egl.Api, vs: u32, fragment: [*:0]const u8) ?Program {
    const fs = compile(api, egl.GL_FRAGMENT_SHADER, fragment) orelse return null;
    defer api.deleteShader(fs);

    const id = api.createProgram();
    api.attachShader(id, vs);
    api.attachShader(id, fs);
    // attribute location 을 고정한다 — 드라이버 배정 순서에 의존하지 않는다.
    api.bindAttribLocation(id, 0, "a_pos");
    api.bindAttribLocation(id, 1, "a_uv");
    api.bindAttribLocation(id, 2, "a_color");
    api.linkProgram(id);
    var linked: i32 = 0;
    api.getProgramiv(id, egl.GL_LINK_STATUS, &linked);
    if (linked == 0) {
        api.deleteProgram(id);
        return null;
    }
    return .{
        .id = id,
        .uniform_viewport = api.getUniformLocation(id, "u_viewport"),
        .uniform_atlas = api.getUniformLocation(id, "u_atlas"),
    };
}

fn compile(api: *const egl.Api, kind: u32, source: [*:0]const u8) ?u32 {
    const shader = api.createShader(kind);
    const sources = [_][*:0]const u8{source};
    api.shaderSource(shader, 1, &sources, null);
    api.compileShader(shader);
    var ok: i32 = 0;
    api.getShaderiv(shader, egl.GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        api.deleteShader(shader);
        return null;
    }
    return shader;
}

test "컬러 글리프와 회색 글리프가 다른 목록에 쌓인다" {
    var batch = Batch{
        .gray_program = .{ .id = 0, .uniform_viewport = -1, .uniform_atlas = -1 },
        .color_program = .{ .id = 0, .uniform_viewport = -1, .uniform_atlas = -1 },
        .buffer = 0,
    };
    defer {
        batch.gray.deinit(std.testing.allocator);
        batch.color.deinit(std.testing.allocator);
    }
    const gray_entry: gl_atlas.AtlasEntry = .{ .x = 0, .y = 0, .w = 8, .h = 16, .bearing_x = 0, .bearing_y = 0 };
    const color_entry: gl_atlas.AtlasEntry = .{ .x = 0, .y = 0, .w = 8, .h = 16, .bearing_x = 0, .bearing_y = 0, .is_color = true };
    batch.add(std.testing.allocator, .{ .x = 0, .y = 0, .entry = gray_entry, .color = .{ 1, 1, 1, 1 } });
    batch.add(std.testing.allocator, .{ .x = 0, .y = 0, .entry = color_entry, .color = .{ 1, 1, 1, 1 } });
    try std.testing.expectEqual(@as(usize, 6), batch.gray.items.len);
    try std.testing.expectEqual(@as(usize, 6), batch.color.items.len);
}

test "크기 0 글리프는 정점을 만들지 않는다" {
    var batch = Batch{
        .gray_program = .{ .id = 0, .uniform_viewport = -1, .uniform_atlas = -1 },
        .color_program = .{ .id = 0, .uniform_viewport = -1, .uniform_atlas = -1 },
        .buffer = 0,
    };
    defer batch.gray.deinit(std.testing.allocator);
    defer batch.color.deinit(std.testing.allocator);
    const empty: gl_atlas.AtlasEntry = .{ .x = 0, .y = 0, .w = 0, .h = 0, .bearing_x = 0, .bearing_y = 0 };
    batch.add(std.testing.allocator, .{ .x = 0, .y = 0, .entry = empty, .color = .{ 1, 1, 1, 1 } });
    try std.testing.expectEqual(@as(usize, 0), batch.gray.items.len);
}
