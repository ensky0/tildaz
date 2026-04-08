// macOS Metal 렌더러
// D3d11Renderer(windows/renderer.zig)와 동일한 공개 인터페이스를 제공한다.
//
// 렌더링 파이프라인:
//   1. 배경 쿼드 (instanced) — BgInstance
//   2. 텍스트 쿼드 (instanced) — TextInstance + CoreText glyph atlas
//   3. MSL 셰이더 (HLSL → Metal Shading Language 변환)

const std = @import("std");
const ghostty = @import("ghostty-vt");

const font_mod = @import("font.zig");
const CoreTextFont = font_mod.CoreTextFont;
const GlyphAtlas = font_mod.GlyphAtlas;

const c = @cImport({
    @cInclude("macos/metal_bridge.h");
});

// ─── 인스턴스 데이터 레이아웃 (D3D11과 동일) ─────────────────────

const BgInstance = extern struct {
    pos: [2]f32,
    size: [2]f32,
    color: [4]f32,
};

const TextInstance = extern struct {
    pos: [2]f32,
    size: [2]f32,
    uv_pos: [2]f32,
    uv_size: [2]f32,
    fg_color: [4]f32,
};

const Constants = extern struct {
    screen_w: f32,
    screen_h: f32,
    atlas_w: f32,
    atlas_h: f32,
    enhanced_contrast: f32,
    _pad1: f32 = 0,
    _pad2: f32 = 0,
    _pad3: f32 = 0,
    gamma_ratios: [4]f32 = .{ 0, 0, 0, 0 },
};

const MAX_INSTANCES: u32 = 32768;

// ─── MSL 셰이더 ───────────────────────────────────────────────────
// 배경 셰이더: HLSL bg_vs/bg_ps → MSL
const bg_shader_msl =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct BgInstance {
    \\  float2 pos      [[attribute(0)]];
    \\  float2 sz       [[attribute(1)]];
    \\  float4 col      [[attribute(2)]];
    \\};
    \\
    \\struct BgOut {
    \\  float4 pos [[position]];
    \\  float4 col;
    \\};
    \\
    \\struct CB {
    \\  float2 screen;
    \\  float2 atlas;
    \\  float enhanced_contrast;
    \\  float pad[3];
    \\  float4 gamma_ratios;
    \\};
    \\
    \\vertex BgOut bg_vs(
    \\  BgInstance in [[stage_in]],
    \\  uint vid [[vertex_id]],
    \\  constant CB& cb [[buffer(0)]]
    \\) {
    \\  float2 corner = float2(float(vid & 1), float(vid >> 1));
    \\  float2 px = (in.pos + corner * in.sz) / cb.screen * 2.0 - 1.0;
    \\  BgOut out;
    \\  out.pos = float4(px.x, -px.y, 0.0, 1.0); // Y flip
    \\  out.col = in.col;
    \\  return out;
    \\}
    \\
    \\fragment float4 bg_ps(BgOut in [[stage_in]]) {
    \\  return in.col;
    \\}
;

// 텍스트 셰이더: HLSL text_vs/text_ps → MSL
const text_shader_msl =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct TextInstance {
    \\  float2 pos      [[attribute(0)]];
    \\  float2 sz       [[attribute(1)]];
    \\  float2 uv_pos   [[attribute(2)]];
    \\  float2 uv_sz    [[attribute(3)]];
    \\  float4 fg       [[attribute(4)]];
    \\};
    \\
    \\struct TextOut {
    \\  float4 pos [[position]];
    \\  float2 uv;
    \\  float4 fg;
    \\};
    \\
    \\struct CB {
    \\  float2 screen;
    \\  float2 atlas;
    \\  float enhanced_contrast;
    \\  float pad[3];
    \\  float4 gamma_ratios;
    \\};
    \\
    \\vertex TextOut text_vs(
    \\  TextInstance in [[stage_in]],
    \\  uint vid [[vertex_id]],
    \\  constant CB& cb [[buffer(0)]]
    \\) {
    \\  float2 corner = float2(float(vid & 1), float(vid >> 1));
    \\  float2 px = (in.pos + corner * in.sz) / cb.screen * 2.0 - 1.0;
    \\  TextOut out;
    \\  out.pos = float4(px.x, -px.y, 0.0, 1.0);
    \\  out.uv  = (in.uv_pos + corner * in.uv_sz) / cb.atlas;
    \\  out.fg  = in.fg;
    \\  return out;
    \\}
    \\
    \\// 감마 보정 (HLSL gammaCorr 동일)
    \\float gammaCorr(float a, float f, float4 g) {
    \\  return a + a * (1.0 - a) * ((g.x * f + g.y) * a + (g.z * f + g.w));
    \\}
    \\// enhanced contrast (HLSL enh 동일)
    \\float enh(float a, float k) { return a * (k + 1.0) / (a * k + 1.0); }
    \\// luminance 기반 LOD 조정
    \\float lodAdj(float k, float3 col) {
    \\  return k * saturate(dot(col, float3(0.30, 0.59, 0.11) * -4.0) + 3.0);
    \\}
    \\
    \\struct TextFrag {
    \\  float4 color [[color(0)]];
    \\  float4 blend [[color(1)]];  // dual-source ClearType
    \\};
    \\
    \\fragment TextFrag text_ps(
    \\  TextOut in [[stage_in]],
    \\  texture2d<float> atlas [[texture(0)]],
    \\  sampler smp [[sampler(0)]],
    \\  constant CB& cb [[buffer(0)]]
    \\) {
    \\  float3 g = atlas.sample(smp, in.uv).rgb;
    \\  float k = lodAdj(cb.enhanced_contrast, in.fg.rgb);
    \\  float3 ct = float3(enh(g.r, k), enh(g.g, k), enh(g.b, k));
    \\  ct = float3(gammaCorr(ct.r, in.fg.r, cb.gamma_ratios),
    \\              gammaCorr(ct.g, in.fg.g, cb.gamma_ratios),
    \\              gammaCorr(ct.b, in.fg.b, cb.gamma_ratios));
    \\  TextFrag out;
    \\  out.color = float4(in.fg.rgb * ct, 1.0);
    \\  out.blend = float4(1.0 - ct, 1.0);
    \\  return out;
    \\}
;

// ─── MetalRenderer ────────────────────────────────────────────────

pub const MetalRenderer = struct {
    alloc: std.mem.Allocator,
    font: CoreTextFont,
    atlas: GlyphAtlas,
    render_state: ghostty.RenderState = .empty,

    // Metal 객체 (불투명 포인터 — C 브릿지로 관리)
    device: ?*anyopaque,
    queue: ?*anyopaque,
    bg_pipeline: ?*anyopaque,
    text_pipeline: ?*anyopaque,
    bg_buf: ?*anyopaque,
    text_buf: ?*anyopaque,
    cb_buf: ?*anyopaque,
    atlas_tex: ?*anyopaque,
    sampler: ?*anyopaque,
    layer: ?*anyopaque, // CAMetalLayer

    default_bg: [3]f32,
    vp_width: u32 = 0,
    vp_height: u32 = 0,
    scale: f32 = 1.0,

    // 탭바 색상
    const TAB_BAR_R: f32 = 20.0 / 255.0;
    const TAB_BAR_G: f32 = 20.0 / 255.0;
    const TAB_BAR_B: f32 = 20.0 / 255.0;
    const TAB_ACTIVE_R: f32 = 50.0 / 255.0;
    const TAB_TEXT_R: f32 = 180.0 / 255.0;

    fn colorF(v: u8) f32 {
        return @as(f32, @floatFromInt(v)) / 255.0;
    }

    // D3D11 init과 동일한 시그니처 (hwnd → metal_view, font_family → UTF-8)
    pub fn init(
        alloc: std.mem.Allocator,
        metal_view: ?*anyopaque, // TildazMetalView (CAMetalLayer 소유)
        font_family: [*:0]const u8,
        font_height: c_int,
        cell_w: u32,
        cell_h: u32,
        bg_rgb: ?[3]u8,
    ) !MetalRenderer {
        const bg = bg_rgb orelse [3]u8{ 30, 30, 30 };

        // 1. Metal 디바이스 + 커맨드 큐
        const device = c.tildazMetalCreateDevice() orelse return error.NoMetalDevice;
        const queue = c.tildazMetalCreateQueue(device) orelse return error.MetalQueueFailed;

        // 2. CAMetalLayer 디바이스 연결
        const scale = c.tildazMetalLayerSetup(metal_view, device);

        // 3. 셰이더 컴파일
        const bg_pipeline = c.tildazMetalCompilePipeline(
            device,
            bg_shader_msl.ptr,
            bg_shader_msl.len,
            "bg_vs",
            "bg_ps",
            0, // 배경: alpha 블렌딩
        ) orelse return error.BgPipelineError;

        const text_pipeline = c.tildazMetalCompilePipeline(
            device,
            text_shader_msl.ptr,
            text_shader_msl.len,
            "text_vs",
            "text_ps",
            1, // 텍스트: dual-source blend
        ) orelse return error.TextPipelineError;

        // 4. 버퍼 생성
        const bg_buf_size = MAX_INSTANCES * @sizeOf(BgInstance);
        const text_buf_size = MAX_INSTANCES * @sizeOf(TextInstance);
        const cb_buf_size = @sizeOf(Constants);

        const bg_buf = c.tildazMetalCreateBuffer(device, bg_buf_size) orelse return error.BgBufFailed;
        const text_buf = c.tildazMetalCreateBuffer(device, text_buf_size) orelse return error.TextBufFailed;
        const cb_buf = c.tildazMetalCreateBuffer(device, cb_buf_size) orelse return error.CbBufFailed;

        // 5. Atlas 텍스처 (2048×2048 BGRA)
        const atlas_size = font_mod.ATLAS_SIZE;
        const atlas_tex = c.tildazMetalCreateTexture(device, atlas_size, atlas_size) orelse return error.AtlasTexFailed;

        // 6. 샘플러 (포인트 필터링)
        const sampler = c.tildazMetalCreateSampler(device) orelse return error.SamplerFailed;

        // 7. 폰트 컨텍스트
        const font = try CoreTextFont.init(
            alloc,
            font_family,
            @floatFromInt(font_height),
            scale,
            @floatFromInt(cell_w),
            @floatFromInt(cell_h),
        );

        // 8. Glyph 아틀라스 (Metal 텍스처 업로드 콜백 포함)
        const atlas = GlyphAtlas.init(alloc, atlas_tex);

        return .{
            .alloc = alloc,
            .font = font,
            .atlas = atlas,
            .device = device,
            .queue = queue,
            .bg_pipeline = bg_pipeline,
            .text_pipeline = text_pipeline,
            .bg_buf = bg_buf,
            .text_buf = text_buf,
            .cb_buf = cb_buf,
            .atlas_tex = atlas_tex,
            .sampler = sampler,
            .layer = metal_view,
            .default_bg = .{
                colorF(bg[0]),
                colorF(bg[1]),
                colorF(bg[2]),
            },
            .scale = scale,
        };
    }

    pub fn deinit(self: *MetalRenderer) void {
        self.font.deinit();
        self.atlas.deinit();
        c.tildazMetalRelease(self.bg_pipeline);
        c.tildazMetalRelease(self.text_pipeline);
        c.tildazMetalRelease(self.bg_buf);
        c.tildazMetalRelease(self.text_buf);
        c.tildazMetalRelease(self.cb_buf);
        c.tildazMetalRelease(self.atlas_tex);
        c.tildazMetalRelease(self.sampler);
        c.tildazMetalRelease(self.queue);
        c.tildazMetalRelease(self.device);
    }

    pub fn invalidate(_: *MetalRenderer) void {
        // Metal: draw-on-demand 방식이므로 타이머가 처리
    }

    pub fn resize(self: *MetalRenderer, width: u32, height: u32) void {
        if (self.vp_width == width and self.vp_height == height) return;
        self.vp_width = width;
        self.vp_height = height;
        c.tildazMetalResizeLayer(self.layer, width, height);
    }

    // ─── 탭 타이틀 / 리네임 (D3D11과 동일한 타입) ─────────────────

    pub const TabTitle = struct { ptr: [*]const u8, len: usize };
    pub const RenameState = struct {
        tab_index: usize,
        text: *const [64]u8,
        text_len: usize,
        cursor: usize,
    };

    // ─── renderTabBar ──────────────────────────────────────────────

    pub fn renderTabBar(
        self: *MetalRenderer,
        titles: []const TabTitle,
        active: usize,
        tab_bar_h: c_int,
        screen_w: c_int,
        screen_h: c_int,
        tab_width: c_int,
        close_btn_size: c_int,
        tab_padding: c_int,
        drag_idx: ?usize,
        drag_x: c_int,
        rename: ?RenameState,
    ) void {
        _ = rename;
        _ = drag_x;
        _ = drag_idx;
        _ = tab_padding;
        _ = close_btn_size;

        const W: f32 = @floatFromInt(screen_w);
        const H: f32 = @floatFromInt(screen_h);
        const TH: f32 = @floatFromInt(tab_bar_h);
        const TW: f32 = @floatFromInt(tab_width);

        // drawable 획득
        const drawable = c.tildazMetalNextDrawable(self.layer) orelse return;
        const cmd = c.tildazMetalBeginFrame(self.queue, drawable, self.default_bg[0], self.default_bg[1], self.default_bg[2]) orelse return;
        defer c.tildazMetalEndFrame(cmd, drawable);

        // 상수 버퍼 업데이트
        const cb = Constants{
            .screen_w = W,
            .screen_h = H,
            .atlas_w = @floatFromInt(font_mod.ATLAS_SIZE),
            .atlas_h = @floatFromInt(font_mod.ATLAS_SIZE),
            .enhanced_contrast = 0.3,
        };
        c.tildazMetalUpdateBuffer(self.cb_buf, &cb, @sizeOf(Constants));

        // 탭바 배경
        var bg_instances: [128]BgInstance = undefined;
        var bg_count: usize = 0;

        bg_instances[bg_count] = .{
            .pos = .{ 0, 0 },
            .size = .{ W, TH },
            .color = .{ TAB_BAR_R, TAB_BAR_G, TAB_BAR_B, 1 },
        };
        bg_count += 1;

        // 탭 배경
        for (titles, 0..) |_, i| {
            const tx: f32 = @as(f32, @floatFromInt(i)) * TW;
            const is_active = i == active;
            bg_instances[bg_count] = .{
                .pos = .{ tx, 0 },
                .size = .{ TW, TH },
                .color = .{
                    if (is_active) TAB_ACTIVE_R else TAB_BAR_R,
                    TAB_BAR_G,
                    TAB_BAR_B,
                    1,
                },
            };
            bg_count += 1;
            if (bg_count >= bg_instances.len) break;
        }

        self.drawBgInstances(cmd, bg_instances[0..bg_count], W, H);

        // 탭 텍스트
        var text_instances: [512]TextInstance = undefined;
        var text_count: usize = 0;

        for (titles, 0..) |t, i| {
            if (text_count >= text_instances.len - 32) break;
            const tx: f32 = @as(f32, @floatFromInt(i)) * TW;
            const title_slice = t.ptr[0..t.len];
            self.layoutText(
                title_slice,
                tx + 8,
                4,
                .{ TAB_TEXT_R, TAB_TEXT_R, TAB_TEXT_R, 1 },
                &text_instances,
                &text_count,
            );
        }

        if (text_count > 0) {
            self.drawTextInstances(cmd, text_instances[0..text_count], W, H);
        }
    }

    // ─── renderTerminal ────────────────────────────────────────────

    pub fn renderTerminal(
        self: *MetalRenderer,
        terminal: *ghostty.Terminal,
        cell_w: c_int,
        cell_h: c_int,
        screen_w: c_int,
        screen_h: c_int,
        tab_bar_h: c_int,
        padding: c_int,
    ) void {
        const W: f32 = @floatFromInt(screen_w);
        const H: f32 = @floatFromInt(screen_h);
        const CW: f32 = @floatFromInt(cell_w);
        const CH: f32 = @floatFromInt(cell_h);
        const TAB_H: f32 = @floatFromInt(tab_bar_h);
        const PAD: f32 = @floatFromInt(padding);

        const drawable = c.tildazMetalNextDrawable(self.layer) orelse return;
        const cmd = c.tildazMetalBeginFrameNoClear(self.queue, drawable) orelse return;
        defer c.tildazMetalEndFrame(cmd, drawable);

        const state = terminal.renderDiff(&self.render_state, self.alloc) catch return;
        defer self.render_state = state;

        const grid = terminal.screen.pages.pin(.{ .active = .{ .x = 0, .y = 0 } });
        _ = grid;

        var bg_buf: [MAX_INSTANCES]BgInstance = undefined;
        var text_buf: [MAX_INSTANCES]TextInstance = undefined;
        var bg_count: usize = 0;
        var text_count: usize = 0;

        // 터미널 셀 순회
        var row_it = terminal.screen.pages.rowIterator(.right_down, .{ .active = .{} }, null);
        var row_y: u32 = 0;
        while (row_it.next()) |row_pin| {
            defer row_y += 1;
            const screen_y: f32 = TAB_H + PAD + @as(f32, @floatFromInt(row_y)) * CH;
            if (screen_y > H) break;

            var cell_it = row_pin.row.cells(.all);
            var col_x: u32 = 0;
            while (cell_it.next()) |cell| {
                defer col_x += 1;
                const screen_x: f32 = PAD + @as(f32, @floatFromInt(col_x)) * CW;

                // 배경 색상
                const bg_color = cell.bg;
                if (!bg_color.isDefault()) {
                    const rgb = bg_color.toRgb(terminal.screen.color_palette);
                    bg_buf[bg_count] = .{
                        .pos = .{ screen_x, screen_y },
                        .size = .{ CW, CH },
                        .color = .{ colorF(rgb.r), colorF(rgb.g), colorF(rgb.b), 1 },
                    };
                    bg_count += 1;
                    if (bg_count >= bg_buf.len) {
                        self.drawBgInstances(cmd, bg_buf[0..bg_count], W, H);
                        bg_count = 0;
                    }
                }

                // 글리프
                const cp = cell.codepoint;
                if (cp == 0 or cp == ' ') continue;

                const fg_color = cell.fg;
                const fg_rgb = fg_color.toRgb(terminal.screen.color_palette);

                const glyph = self.atlas.getOrRasterize(&self.font, cp) catch continue;
                text_buf[text_count] = .{
                    .pos = .{ screen_x + glyph.offset_x, screen_y + glyph.offset_y },
                    .size = .{ @floatFromInt(glyph.width), @floatFromInt(glyph.height) },
                    .uv_pos = .{ @floatFromInt(glyph.atlas_x), @floatFromInt(glyph.atlas_y) },
                    .uv_size = .{ @floatFromInt(glyph.width), @floatFromInt(glyph.height) },
                    .fg_color = .{ colorF(fg_rgb.r), colorF(fg_rgb.g), colorF(fg_rgb.b), 1 },
                };
                text_count += 1;

                if (text_count >= text_buf.len) {
                    self.drawTextInstances(cmd, text_buf[0..text_count], W, H);
                    text_count = 0;
                }
            }
        }

        if (bg_count > 0) self.drawBgInstances(cmd, bg_buf[0..bg_count], W, H);
        if (text_count > 0) self.drawTextInstances(cmd, text_buf[0..text_count], W, H);
    }

    // ─── 내부 드로우 헬퍼 ────────────────────────────────────────

    fn drawBgInstances(self: *MetalRenderer, cmd: ?*anyopaque, instances: []const BgInstance, w: f32, h: f32) void {
        const cb = Constants{
            .screen_w = w,
            .screen_h = h,
            .atlas_w = @floatFromInt(font_mod.ATLAS_SIZE),
            .atlas_h = @floatFromInt(font_mod.ATLAS_SIZE),
            .enhanced_contrast = 0.3,
        };
        c.tildazMetalUpdateBuffer(self.cb_buf, &cb, @sizeOf(Constants));
        c.tildazMetalUpdateBuffer(self.bg_buf, instances.ptr, instances.len * @sizeOf(BgInstance));
        c.tildazMetalDrawInstanced(
            cmd,
            self.bg_pipeline,
            self.bg_buf,
            self.cb_buf,
            null, null, null, // 텍스처/샘플러 없음
            @intCast(instances.len),
            4, // 쿼드: 4 vertices
        );
    }

    fn drawTextInstances(self: *MetalRenderer, cmd: ?*anyopaque, instances: []const TextInstance, w: f32, h: f32) void {
        const cb = Constants{
            .screen_w = w,
            .screen_h = h,
            .atlas_w = @floatFromInt(font_mod.ATLAS_SIZE),
            .atlas_h = @floatFromInt(font_mod.ATLAS_SIZE),
            .enhanced_contrast = 0.3,
        };
        c.tildazMetalUpdateBuffer(self.cb_buf, &cb, @sizeOf(Constants));
        c.tildazMetalUpdateBuffer(self.text_buf, instances.ptr, instances.len * @sizeOf(TextInstance));
        c.tildazMetalDrawInstanced(
            cmd,
            self.text_pipeline,
            self.text_buf,
            self.cb_buf,
            self.atlas_tex,
            self.sampler,
            null,
            @intCast(instances.len),
            4,
        );
    }

    fn layoutText(
        self: *MetalRenderer,
        text: []const u8,
        x: f32,
        y: f32,
        color: [4]f32,
        buf: *[512]TextInstance,
        count: *usize,
    ) void {
        var cx: f32 = x;
        var i: usize = 0;
        while (i < text.len) {
            // UTF-8 디코딩
            const byte = text[i];
            const cp: u21 = if (byte < 0x80) blk: {
                i += 1;
                break :blk byte;
            } else blk: {
                const len = std.unicode.utf8ByteSequenceLength(byte) catch { i += 1; continue; };
                if (i + len > text.len) break;
                const codepoint = std.unicode.utf8Decode(text[i .. i + len]) catch { i += 1; continue; };
                i += len;
                break :blk codepoint;
            };

            const glyph = self.atlas.getOrRasterize(&self.font, cp) catch {
                cx += self.font.cell_width;
                continue;
            };

            if (count.* < buf.len) {
                buf[count.*] = .{
                    .pos = .{ cx + glyph.offset_x, y + glyph.offset_y },
                    .size = .{ @floatFromInt(glyph.width), @floatFromInt(glyph.height) },
                    .uv_pos = .{ @floatFromInt(glyph.atlas_x), @floatFromInt(glyph.atlas_y) },
                    .uv_size = .{ @floatFromInt(glyph.width), @floatFromInt(glyph.height) },
                    .fg_color = color,
                };
                count.* += 1;
            }
            cx += self.font.cell_width;
        }
    }
};
