//! 단색 사각형 배치 드로 ([#277](https://github.com/ensky0/tildaz/issues/277) S2-3).
//!
//! GLES 렌더러의 첫 그리기 계층이다. 터미널 배경 · 셀 배경 · 탭바 chrome ·
//! scrollbar 처럼 **색만 있는 사각형**을 모아 한 번에 그린다.
//!
//! 인스턴싱을 쓰지 않는다. 사각형마다 삼각형 2 개(정점 6 개)를 CPU 에서 만들어
//! 한 버퍼로 올리고 `glDrawArrays` 한 번으로 그린다. 이유는 두 가지다 —
//! (1) 인스턴싱은 GLES2 코어에 없어 확장/버전 분기가 필요한데, 우리 드라이버
//! 호환 폭을 좁힐 이유가 없다. (2) 셀 7 천 개면 정점 4 만 개로, 이 규모에서는
//! 정점 업로드가 병목이 아니다 (병목이던 것은 픽셀당 CPU 블렌딩이었다 — S2-2
//! 측정에서 CPU 의 85 %).
//!
//! 좌표는 **물리 픽셀, 좌상단 원점**이다. dma-buf 를 FBO 로 쓰면 GL 의 y=0 행이
//! 메모리 첫 행이고 Wayland 는 그 행을 화면 맨 위에 표시하므로, y-flip 보정을
//! 하지 않고 top-down 을 그대로 쓴다 (#277 S0-b 에서 실측 확인).

const std = @import("std");
const egl = @import("egl.zig");
const ui_rect = @import("../../ui_rect.zig");

/// #343 이 만든 공통 사각형 타입을 그대로 쓴다 — 탭바 · scrollbar · command menu
/// 가 이미 이 형식으로 목록을 내보내고, renderer 는 자기 형식으로 옮기기만 한다.
/// 색이 `[4]f32` (0..1) 라 GL 은 변환 없이 그대로 정점에 넣는다 (software 경로는
/// u8 로 바꾸는 단계가 하나 더 있다).
pub const Rect = ui_rect.Rect;

/// 정점 하나 — 위치(px) + 색(0~1 premultiplied 아님, 불투명 사각형 전용).
const Vertex = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

const vertex_src: [*:0]const u8 =
    \\precision highp float;
    \\attribute vec2 a_pos;
    \\attribute vec4 a_color;
    \\uniform vec2 u_viewport;
    \\varying vec4 v_color;
    \\void main() {
    \\    // 픽셀 좌표(좌상단 원점) → clip space. y 를 뒤집지 않는다 — 위 주석 참고.
    \\    vec2 ndc = vec2(a_pos.x / u_viewport.x * 2.0 - 1.0,
    \\                    a_pos.y / u_viewport.y * 2.0 - 1.0);
    \\    gl_Position = vec4(ndc, 0.0, 1.0);
    \\    v_color = a_color;
    \\}
;

const fragment_src: [*:0]const u8 =
    \\precision mediump float;
    \\varying vec4 v_color;
    \\void main() {
    \\    gl_FragColor = v_color;
    \\}
;

pub const Batch = struct {
    program: u32,
    buffer: u32,
    attr_pos: u32 = 0,
    attr_color: u32 = 1,
    uniform_viewport: i32,
    vertices: std.ArrayList(Vertex) = .{},

    pub fn create(api: *const egl.Api) ?Batch {
        const vs = compile(api, egl.GL_VERTEX_SHADER, vertex_src) orelse return null;
        defer api.deleteShader(vs);
        const fs = compile(api, egl.GL_FRAGMENT_SHADER, fragment_src) orelse return null;
        defer api.deleteShader(fs);

        const program = api.createProgram();
        api.attachShader(program, vs);
        api.attachShader(program, fs);
        // location 을 고정한다 — 드라이버가 배정하는 순서에 의존하지 않는다.
        api.bindAttribLocation(program, 0, "a_pos");
        api.bindAttribLocation(program, 1, "a_color");
        api.linkProgram(program);
        var linked: i32 = 0;
        api.getProgramiv(program, egl.GL_LINK_STATUS, &linked);
        if (linked == 0) {
            api.deleteProgram(program);
            return null;
        }

        var buffer: u32 = 0;
        api.genBuffers(1, @ptrCast(&buffer));
        return .{
            .program = program,
            .buffer = buffer,
            .uniform_viewport = api.getUniformLocation(program, "u_viewport"),
        };
    }

    pub fn deinit(self: *Batch, api: *const egl.Api, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        var buf = self.buffer;
        api.deleteBuffers(1, @ptrCast(&buf));
        api.deleteProgram(self.program);
    }

    pub fn clear(self: *Batch) void {
        self.vertices.clearRetainingCapacity();
    }

    /// 사각형 하나를 삼각형 2 개로 쌓는다. 폭/높이가 0 이하면 무시한다.
    pub fn add(self: *Batch, allocator: std.mem.Allocator, rect: Rect) void {
        if (rect.w <= 0 or rect.h <= 0) return;
        const r = rect.color[0];
        const g = rect.color[1];
        const b = rect.color[2];
        const a = rect.color[3];
        const x0 = rect.x;
        const y0 = rect.y;
        const x1 = rect.x + rect.w;
        const y1 = rect.y + rect.h;
        const corners = [6][2]f32{
            .{ x0, y0 }, .{ x1, y0 }, .{ x0, y1 },
            .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 },
        };
        for (corners) |c| {
            self.vertices.append(allocator, .{ .x = c[0], .y = c[1], .r = r, .g = g, .b = b, .a = a }) catch return;
        }
    }

    /// 쌓인 사각형을 한 번에 그린다. 불투명 사각형만 담기므로 블렌딩을 끈다 —
    /// 뒤에 그린 것이 앞을 덮는 것이 software 경로의 `rect()` 와 같은 의미다.
    pub fn flush(self: *Batch, api: *const egl.Api, viewport_w: f32, viewport_h: f32) void {
        if (self.vertices.items.len == 0) return;
        api.disable(egl.GL_BLEND);
        api.useProgram(self.program);
        api.uniform2f(self.uniform_viewport, viewport_w, viewport_h);
        api.bindBuffer(egl.GL_ARRAY_BUFFER, self.buffer);
        api.bufferData(
            egl.GL_ARRAY_BUFFER,
            @intCast(self.vertices.items.len * @sizeOf(Vertex)),
            self.vertices.items.ptr,
            egl.GL_STREAM_DRAW,
        );
        api.enableVertexAttribArray(self.attr_pos);
        api.vertexAttribPointer(self.attr_pos, 2, egl.GL_FLOAT, 0, @sizeOf(Vertex), null);
        api.enableVertexAttribArray(self.attr_color);
        api.vertexAttribPointer(
            self.attr_color,
            4,
            egl.GL_FLOAT,
            0,
            @sizeOf(Vertex),
            @ptrFromInt(@offsetOf(Vertex, "r")),
        );
        api.drawArrays(egl.GL_TRIANGLES, 0, @intCast(self.vertices.items.len));
    }
};

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

test "빈 batch 는 그릴 것이 없다" {
    var batch = Batch{ .program = 0, .buffer = 0, .uniform_viewport = -1 };
    defer batch.vertices.deinit(std.testing.allocator);
    batch.add(std.testing.allocator, .{ .x = 0, .y = 0, .w = 0, .h = 10, .color = .{ 1, 0, 0, 1 } });
    batch.add(std.testing.allocator, .{ .x = 0, .y = 0, .w = 10, .h = -1, .color = .{ 1, 0, 0, 1 } });
    try std.testing.expectEqual(@as(usize, 0), batch.vertices.items.len);
}

test "사각형 하나는 정점 여섯 개" {
    var batch = Batch{ .program = 0, .buffer = 0, .uniform_viewport = -1 };
    defer batch.vertices.deinit(std.testing.allocator);
    batch.add(std.testing.allocator, .{ .x = 2, .y = 4, .w = 8, .h = 16, .color = .{ 1, 0, 0, 1 } });
    try std.testing.expectEqual(@as(usize, 6), batch.vertices.items.len);
    // 좌상단이 (2,4), 우하단이 (10,20) 이어야 한다 (top-down 좌표).
    try std.testing.expectEqual(@as(f32, 2), batch.vertices.items[0].x);
    try std.testing.expectEqual(@as(f32, 4), batch.vertices.items[0].y);
    try std.testing.expectEqual(@as(f32, 10), batch.vertices.items[4].x);
    try std.testing.expectEqual(@as(f32, 20), batch.vertices.items[4].y);
}
