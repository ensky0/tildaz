// Metal terminal renderer — Windows 의 `src/d3d11_renderer.zig` 와 같은 역할.
// 인스턴스드 쿼드 (한 cell = 한 quad instance) 로 배경 + 글리프 텍스트 그림.
// macOS 는 grayscale antialias 만 지원 (Mojave+) 이라 ClearType 서브픽셀 셰이더
// 불필요. 셰이더 / 셀 파이프라인이 Windows 보다 단순.
//
// #75 (claude/infallible-swartz) 의 macos/renderer.zig 패턴 그대로 차용 +
// 우리 nullable `id` (?*opaque) 와 평면 모듈 구조에 맞춰 정리.

const std = @import("std");
const objc = @import("macos_objc.zig");
const ct = @import("macos_coretext.zig");
const CoreTextFontContext = @import("macos_font.zig").CoreTextFontContext;
const macos_glyph_atlas = @import("macos_glyph_atlas.zig");
const ui_metrics = @import("ui_metrics.zig");
const GlyphAtlas = macos_glyph_atlas.GlyphAtlas;
const ATLAS_SIZE = macos_glyph_atlas.ATLAS_SIZE;
const ghostty = @import("ghostty-vt");

const MAX_INSTANCES: u32 = 32768;

// --- Instance data layouts (MSL struct 와 일치해야 함) ---

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

// --- MSL 셰이더 ---

// === KNOWN ISSUE: layer 의 (0, 0) 픽셀 미렌더링 ===
//
// 진단 마커로 확인된 quirk: pos=(0,0) 위치에 그린 instance 의 좌상 1px 모서리
// (정확히 NDC(-1, +1) corner) 만 화면에 안 그려진다. pos=(1,1) 부터는 정상.
// 다른 모서리 (NDC (+1,+1), (-1,-1), (+1,-1)) 는 영향 없음 — 좌상 corner 만.
//
// 영향: TERMINAL_PADDING_PT >= 1 이면 글자가 항상 (1, 1) 안쪽에 있어 사용자가
// 인지하지 못 함. padding=0 으로 두고 셀 (0, 0) 부터 그릴 때만 1px 누락 보임.
//
// 추정 원인: Metal 의 `-px.y` NDC 변환 + viewport rasterization 의 좌상
// corner sample point 처리. 정확한 NDC corner vertex 가 fragment 에 sample
// 되지 않거나 `kCAGravityResize` 의 sub-pixel rounding 에서 누락되는 가능성.
// CAMetalLayer.contentsGravity = kCAGravityTopLeft 또는 viewport 명시적 설정
// 으로 회피 가능할 수 있으나 미검증. follow-up 으로 추적.
//
// === Shader ===
const shader_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct BgInst { float2 pos; float2 size; float4 color; };
    \\struct BgOut { float4 position [[position]]; float4 color; };
    \\
    \\vertex BgOut bg_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
    \\    const device BgInst* inst [[buffer(0)]], constant float4& sa [[buffer(1)]]) {
    \\    float2 c = float2(vid & 1, vid >> 1);
    \\    float2 px = (inst[iid].pos + c * inst[iid].size) / sa.xy * 2.0 - 1.0;
    \\    BgOut o; o.position = float4(px.x, -px.y, 0, 1); o.color = inst[iid].color; return o;
    \\}
    \\fragment float4 bg_fs(BgOut in [[stage_in]]) { return in.color; }
    \\
    \\struct TxInst { float2 pos; float2 size; float2 uvp; float2 uvs; float4 fg; };
    \\struct TxOut { float4 position [[position]]; float2 uv; float4 fg; };
    \\
    \\vertex TxOut text_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
    \\    const device TxInst* inst [[buffer(0)]], constant float4& sa [[buffer(1)]]) {
    \\    float2 c = float2(vid & 1, vid >> 1);
    \\    float2 px = (inst[iid].pos + c * inst[iid].size) / sa.xy * 2.0 - 1.0;
    \\    TxOut o; o.position = float4(px.x, -px.y, 0, 1);
    \\    o.uv = (inst[iid].uvp + c * inst[iid].uvs) / sa.zw; o.fg = inst[iid].fg; return o;
    \\}
    \\fragment float4 text_fs(TxOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    \\    constexpr sampler smp(mag_filter::nearest, min_filter::nearest);
    \\    float a = atlas.sample(smp, in.uv).r;
    \\    return float4(in.fg.rgb, in.fg.a * a);
    \\}
;

// --- Renderer ---

pub const MetalRenderer = struct {
    alloc: std.mem.Allocator,
    font: CoreTextFontContext,
    atlas: GlyphAtlas,
    render_state: ghostty.RenderState = .empty,

    // Metal 객체 (모두 ObjC id, 우리는 ARC 안 쓰지만 process 종료 시 회수).
    device: objc.id,
    command_queue: objc.id,
    bg_pipeline: objc.id,
    text_pipeline: objc.id,
    bg_buffer: objc.id,
    text_buffer: objc.id,
    atlas_texture: objc.id,
    constants_buffer: objc.id,

    // 기본 배경색 (theme 미설정 시).
    default_bg: [3]f32,

    // viewport (pixel 단위).
    vp_width: u32 = 0,
    vp_height: u32 = 0,

    // Retina backing scale.
    scale: f32,

    pub fn colorF(v: u8) f32 {
        return @as(f32, @floatFromInt(v)) / 255.0;
    }

    pub fn init(
        alloc: std.mem.Allocator,
        device: objc.id,
        layer: objc.id,
        font_family: []const u8,
        font_size: f32,
        /// Windows config 와 동일한 미적 보정. 폰트 변경 시 cell 크기는
        /// font 가 자체 측정 (advance + ascent/descent/leading).
        cell_width_scale: f32,
        line_height_scale: f32,
        bg_rgb: ?[3]u8,
        scale: f32,
    ) !MetalRenderer {
        const bg = bg_rgb orelse [3]u8{ 30, 30, 30 };

        const cmd_queue = objc.msgSend(device, objc.sel("newCommandQueue"));

        var font_ctx = try CoreTextFontContext.init(
            font_family,
            font_size,
            scale,
            cell_width_scale,
            line_height_scale,
        );
        errdefer font_ctx.deinit();

        var glyph_atlas = try GlyphAtlas.init(alloc, font_size, scale);
        errdefer glyph_atlas.deinit();

        // Metal 셰이더 컴파일.
        const source_str = objc.nsString(shader_source);
        var err: objc.id = null;
        const library = objc.msgSend3(
            device,
            objc.sel("newLibraryWithSource:options:error:"),
            source_str,
            @as(objc.id, null),
            @as(*objc.id, &err),
        );
        if (library == null) {
            if (err) |e| {
                const desc = objc.msgSend(e, objc.sel("localizedDescription"));
                if (desc) |d| {
                    const cstr_ptr = objc.msgSend(d, objc.sel("UTF8String"));
                    if (cstr_ptr) |p| {
                        const cstr: [*:0]const u8 = @ptrCast(p);
                        std.log.err("Metal shader error: {s}", .{cstr});
                    }
                }
            }
            return error.ShaderCompileFailed;
        }

        const bg_vs_fn = objc.msgSend1(library, objc.sel("newFunctionWithName:"), objc.nsString("bg_vs"));
        const bg_fs_fn = objc.msgSend1(library, objc.sel("newFunctionWithName:"), objc.nsString("bg_fs"));
        const text_vs_fn = objc.msgSend1(library, objc.sel("newFunctionWithName:"), objc.nsString("text_vs"));
        const text_fs_fn = objc.msgSend1(library, objc.sel("newFunctionWithName:"), objc.nsString("text_fs"));

        const bg_pipeline = try createPipeline(device, bg_vs_fn, bg_fs_fn);
        const text_pipeline = try createPipeline(device, text_vs_fn, text_fs_fn);

        const bg_buf = createBuffer(device, MAX_INSTANCES * @sizeOf(BgInstance));
        const text_buf = createBuffer(device, MAX_INSTANCES * @sizeOf(TextInstance));

        // constants buffer = float4 (screen_w, screen_h, atlas_w, atlas_h).
        const const_buf = createBuffer(device, 16);

        const atlas_tex = createAtlasTexture(device);

        // CAMetalLayer 설정 (device 등록 + pixel format).
        objc.msgSendVoid1(layer, objc.sel("setDevice:"), device);
        objc.msgSendVoid1(layer, objc.sel("setPixelFormat:"), @as(objc.NSUInteger, 80)); // BGRA8Unorm

        return .{
            .alloc = alloc,
            .font = font_ctx,
            .atlas = glyph_atlas,
            .device = device,
            .command_queue = cmd_queue,
            .bg_pipeline = bg_pipeline,
            .text_pipeline = text_pipeline,
            .bg_buffer = bg_buf,
            .text_buffer = text_buf,
            .atlas_texture = atlas_tex,
            .constants_buffer = const_buf,
            .default_bg = .{ colorF(bg[0]), colorF(bg[1]), colorF(bg[2]) },
            .scale = scale,
        };
    }

    pub fn deinit(self: *MetalRenderer) void {
        self.atlas.deinit();
        self.font.deinit();
        // Metal 객체는 ARC / process exit 으로 정리.
    }

    pub fn resize(self: *MetalRenderer, width: u32, height: u32) void {
        self.vp_width = width;
        self.vp_height = height;
    }

    /// 한 프레임 렌더 — drawable 획득 → 배경 + 텍스트 + 커서 그리기 → present.
    pub fn renderFrame(
        self: *MetalRenderer,
        layer: objc.id,
        terminal: *ghostty.Terminal,
        cell_w: i32,
        cell_h: i32,
        y_offset: i32,
        padding: i32,
    ) void {
        const drawable = objc.msgSend(layer, objc.sel("nextDrawable"));
        if (drawable == null) return;

        const texture = objc.msgSend(drawable, objc.sel("texture"));

        const cmd_buf = objc.msgSend(self.command_queue, objc.sel("commandBuffer"));

        const rpd_class = objc.getClass("MTLRenderPassDescriptor");
        const rpd = objc.msgSend(rpd_class, objc.sel("renderPassDescriptor"));

        const attachments = objc.msgSend(rpd, objc.sel("colorAttachments"));
        const att0 = objc.msgSend1(attachments, objc.sel("objectAtIndexedSubscript:"), @as(objc.NSUInteger, 0));
        objc.msgSendVoid1(att0, objc.sel("setTexture:"), texture);
        objc.msgSendVoid1(att0, objc.sel("setLoadAction:"), @as(objc.NSUInteger, 2)); // Clear
        objc.msgSendVoid1(att0, objc.sel("setStoreAction:"), @as(objc.NSUInteger, 1)); // Store

        const ClearColor = extern struct { r: f64, g: f64, b: f64, a: f64 };
        const clear = ClearColor{
            .r = @floatCast(self.default_bg[0]),
            .g = @floatCast(self.default_bg[1]),
            .b = @floatCast(self.default_bg[2]),
            .a = 1.0,
        };
        const setClearColorFn: *const fn (objc.id, objc.SEL, ClearColor) callconv(.c) void = @ptrCast(objc.msgSend_raw);
        setClearColorFn(att0, objc.sel("setClearColor:"), clear);

        const encoder = objc.msgSend1(cmd_buf, objc.sel("renderCommandEncoderWithDescriptor:"), rpd);
        if (encoder == null) return;

        self.updateConstants();

        if (self.atlas.dirty) {
            self.uploadAtlas();
            self.atlas.dirty = false;
        }

        self.renderTerminalContent(encoder, terminal, cell_w, cell_h, y_offset, padding);

        objc.msgSendVoid(encoder, objc.sel("endEncoding"));
        objc.msgSendVoid1(cmd_buf, objc.sel("presentDrawable:"), drawable);
        objc.msgSendVoid(cmd_buf, objc.sel("commit"));
    }

    fn renderTerminalContent(
        self: *MetalRenderer,
        encoder: objc.id,
        terminal: *ghostty.Terminal,
        cell_w: i32,
        cell_h: i32,
        y_offset: i32,
        padding: i32,
    ) void {
        self.render_state.update(self.alloc, terminal) catch return;

        const rows = self.render_state.rows;
        const cols = self.render_state.cols;
        const colors = self.render_state.colors;
        const row_slice = self.render_state.row_data.slice();

        const cw: f32 = @floatFromInt(cell_w);
        const ch: f32 = @floatFromInt(cell_h);
        // 위쪽 padding 보정: 폰트의 ascent 가 cap_height 보다 위쪽 internal
        // leading 만큼 더 큰데 cell box top 부터 ascent 만큼 내려간 위치가
        // baseline 이라, 대문자 visible top 은 cell top + (ascent − cap_height)
        // 위치. 좌/우 padding 은 글자에 딱 붙는데 위쪽만 (ascent − cap_height)
        // 만큼 추가 여백이 생겨 비대칭. 모든 row 의 fy 를 위로 그만큼 shift
        // 해서 첫 행 글자 visible top 이 정확히 padding 위치에 오게.
        const y_off: f32 = @as(f32, @floatFromInt(y_offset + padding)) - self.font.top_pad_px;
        const x_pad: f32 = @floatFromInt(padding);

        const all_cells = row_slice.items(.cells);
        const all_sels = row_slice.items(.selection);

        const dbg_r = colorF(colors.background.r);
        const dbg_g = colorF(colors.background.g);
        const dbg_b = colorF(colors.background.b);

        const MAX_CELLS = 4096;
        var bg_buf: [MAX_CELLS]BgInstance = undefined;
        var bg_count: u32 = 0;
        var text_buf: [MAX_CELLS]TextInstance = undefined;
        var text_count: u32 = 0;

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

                if (bg_count >= MAX_CELLS) {
                    self.drawBgInstances(encoder, bg_buf[0..bg_count]);
                    bg_count = 0;
                }
                const width: f32 = if (raw.wide == .wide) 2.0 * cw else cw;
                const fx: f32 = @as(f32, @floatFromInt(x)) * cw + x_pad;
                const fy: f32 = @as(f32, @floatFromInt(y)) * ch + y_off;

                const cell_bg = resolveBg(style, &raw, &colors, is_selected, is_inverse, dbg_r, dbg_g, dbg_b);
                bg_buf[bg_count] = .{
                    .pos = .{ fx, fy },
                    .size = .{ width, ch },
                    .color = .{ cell_bg[0], cell_bg[1], cell_bg[2], 1 },
                };
                bg_count += 1;
            }
        }

        if (bg_count > 0) self.drawBgInstances(encoder, bg_buf[0..bg_count]);

        // --- Text pass ---
        for (0..rows) |y| {
            if (y >= all_cells.len) break;
            const cell_slice = all_cells[y].slice();
            const raws = cell_slice.items(.raw);
            const styles = cell_slice.items(.style);
            const sel_range: ?[2]u16 = if (y < all_sels.len) all_sels[y] else null;

            const fy: f32 = @as(f32, @floatFromInt(y)) * ch + y_off;

            for (0..cols) |x| {
                if (x >= raws.len) break;
                const raw = raws[x];

                const is_text = raw.hasText() and raw.wide != .spacer_tail and raw.wide != .spacer_head and raw.codepoint() != 0;
                if (!is_text) continue;

                const cp = raw.codepoint();

                if (text_count >= MAX_CELLS) {
                    self.drawTextInstances(encoder, text_buf[0..text_count]);
                    text_count = 0;
                }

                const result = self.font.resolveGlyph(cp) orelse continue;
                const entry = self.atlas.getOrInsert(result.font, @intCast(result.index)) orelse {
                    if (result.owned) ct.CFRelease(result.font);
                    continue;
                };
                if (result.owned) ct.CFRelease(result.font);

                if (entry.w == 0 or entry.h == 0) continue;

                const style = if (raw.style_id != 0) styles[x] else ghostty.Style{};
                const is_inverse = style.flags.inverse;
                const x16: u16 = @intCast(x);
                const is_selected = if (sel_range) |sr| (x16 >= sr[0] and x16 <= sr[1]) else false;
                const fg_rgb = resolveFg(style, &raw, &colors, is_selected, is_inverse);

                // 모든 좌표 pixel 단위. bearing / atlas size / cell_w/h /
                // ascent_px 모두 pixel — font.init 시 scale 곱해 통일됨.
                //
                // bearing_y 는 CG 의 bbox.origin.y * scale (= bbox 의 bottom,
                // baseline-Y-up 좌표). 화면 Y-down 좌표에서 글리프 top 위치는:
                //   gy = cell_top + ascent − top_of_bbox_y_up
                //      = cell_top + ascent − (bearing_y + h)
                // serene-euler #73 의 `offset_y = ascent - (origin.y + size.h)`
                // 와 동일.
                const fx: f32 = @as(f32, @floatFromInt(x)) * cw + x_pad;
                const gx = fx + @as(f32, @floatFromInt(entry.bearing_x));
                const gy = fy + self.font.ascent_px
                    - @as(f32, @floatFromInt(entry.bearing_y))
                    - @as(f32, @floatFromInt(entry.h));

                text_buf[text_count] = .{
                    .pos = .{ gx, gy },
                    .size = .{ @as(f32, @floatFromInt(entry.w)), @as(f32, @floatFromInt(entry.h)) },
                    .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
                    .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                    .fg_color = .{ colorF(fg_rgb.r), colorF(fg_rgb.g), colorF(fg_rgb.b), 1 },
                };
                text_count += 1;
            }
        }

        if (text_count > 0) self.drawTextInstances(encoder, text_buf[0..text_count]);

        // === M5.3 진단 ===
        // 1초 (~60 frame) 마다 stderr 로 프레임 / 카운트 / 커서 / 첫 row 의 codepoint
        // dump. 화면에 글자 안 보일 때 어디서 끊겼는지 구별 (text=0 이면 grid 비어
        // 있음; cursor=null 이면 vt 가 cursor 안 갱신; codepoint=0 이면 grid 미수신).
        {
            const S = struct {
                var frame_count: u32 = 0;
            };
            S.frame_count += 1;
            if (S.frame_count % 60 == 0) {
                const cur_x: i32 = if (self.render_state.cursor.viewport) |v| @intCast(v.x) else -1;
                const cur_y: i32 = if (self.render_state.cursor.viewport) |v| @intCast(v.y) else -1;
                std.debug.print(
                    "[render] frame={d} vp={d}x{d} rows={d} cols={d} text={d} bg={d} cursor=({d},{d}) atlas_dirty={}\n",
                    .{ S.frame_count, self.vp_width, self.vp_height, rows, cols, text_count, bg_count, cur_x, cur_y, self.atlas.dirty },
                );
                if (rows > 0 and all_cells.len > 0) {
                    const cell_slice = all_cells[0].slice();
                    const raws = cell_slice.items(.raw);
                    std.debug.print("[render] row0 cp:", .{});
                    var i: usize = 0;
                    while (i < @min(raws.len, 20)) : (i += 1) {
                        std.debug.print(" {x}", .{raws[i].codepoint()});
                    }
                    std.debug.print("\n", .{});
                }
            }
        }

        // --- Cursor (단순 박스) ---
        if (self.render_state.cursor.visible) {
            if (self.render_state.cursor.viewport) |vp| {
                var cursor_x: f32 = @floatFromInt(vp.x);
                const cursor_y: f32 = @floatFromInt(vp.y);
                if (vp.wide_tail and vp.x > 0) cursor_x -= 1.0;
                const cx0 = cursor_x * cw + x_pad;
                const cy0 = cursor_y * ch + y_off;
                var cursor_color: [4]f32 = .{ 180.0 / 255.0, 180.0 / 255.0, 180.0 / 255.0, 0.7 };
                if (colors.cursor) |cc| {
                    cursor_color = .{ colorF(cc.r), colorF(cc.g), colorF(cc.b), 0.7 };
                }
                const cursor_inst = [1]BgInstance{.{
                    .pos = .{ cx0, cy0 },
                    .size = .{ cw, ch },
                    .color = cursor_color,
                }};
                self.drawBgInstances(encoder, &cursor_inst);
            }
        }

        // --- Scrollbar (Windows d3d11_renderer 와 동일 패턴) ---
        // pixel 단위. self.scale 곱해 retina pixel 로.
        const sb = terminal.screens.active.pages.scrollbar();
        if (sb.total > sb.len) {
            const sbw: f32 = @as(f32, @floatFromInt(ui_metrics.SCROLLBAR_W_PT)) * self.scale;
            const sb_min: f32 = @as(f32, @floatFromInt(ui_metrics.SCROLLBAR_MIN_THUMB_H_PT)) * self.scale;
            const vp_hf: f32 = @floatFromInt(self.vp_height);
            const vp_wf: f32 = @floatFromInt(self.vp_width);
            const track_h: f32 = vp_hf - @as(f32, @floatFromInt(y_offset + padding));
            const track_x: f32 = vp_wf - sbw;
            const ratio = track_h / @as(f32, @floatFromInt(sb.total));
            const thumb_h = @max(sb_min, ratio * @as(f32, @floatFromInt(sb.len)));
            const available = track_h - thumb_h;
            const max_offset: f32 = @floatFromInt(sb.total - sb.len);
            const thumb_y = y_off + if (max_offset > 0)
                @as(f32, @floatFromInt(sb.offset)) / max_offset * available
            else
                0;
            const scrollbar_inst = [1]BgInstance{.{
                .pos = .{ track_x, thumb_y },
                .size = .{ sbw, thumb_h },
                .color = ui_metrics.SCROLLBAR_COLOR,
            }};
            self.drawBgInstances(encoder, &scrollbar_inst);
        }
    }

    fn updateConstants(self: *MetalRenderer) void {
        const contents_ptr = objc.msgSend(self.constants_buffer, objc.sel("contents")) orelse return;
        const data: *[4]f32 = @ptrCast(@alignCast(contents_ptr));
        data.* = .{
            @floatFromInt(self.vp_width),
            @floatFromInt(self.vp_height),
            @floatFromInt(ATLAS_SIZE),
            @floatFromInt(ATLAS_SIZE),
        };
    }

    fn uploadAtlas(self: *MetalRenderer) void {
        const Region = extern struct { ox: usize, oy: usize, oz: usize, sx: usize, sy: usize, sz: usize };
        const region = Region{ .ox = 0, .oy = 0, .oz = 0, .sx = ATLAS_SIZE, .sy = ATLAS_SIZE, .sz = 1 };

        const f: *const fn (objc.id, objc.SEL, Region, objc.NSUInteger, [*]const u8, objc.NSUInteger) callconv(.c) void = @ptrCast(objc.msgSend_raw);
        f(
            self.atlas_texture,
            objc.sel("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"),
            region,
            0,
            self.atlas.pixels.ptr,
            ATLAS_SIZE,
        );
    }

    fn drawBgInstances(self: *MetalRenderer, encoder: objc.id, instances: []const BgInstance) void {
        if (instances.len == 0) return;

        const contents_ptr = objc.msgSend(self.bg_buffer, objc.sel("contents")) orelse return;
        const contents: [*]BgInstance = @ptrCast(@alignCast(contents_ptr));
        @memcpy(contents[0..instances.len], instances);

        objc.msgSendVoid1(encoder, objc.sel("setRenderPipelineState:"), self.bg_pipeline);
        objc.msgSendVoid3(encoder, objc.sel("setVertexBuffer:offset:atIndex:"), self.bg_buffer, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 0));
        objc.msgSendVoid3(encoder, objc.sel("setVertexBuffer:offset:atIndex:"), self.constants_buffer, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 1));

        // MTLPrimitiveTypeTriangleStrip = 4 (3 은 Triangle 이라 단일 3-vertex
        // triangle 만 그림 → quad 가 절반만 보임). #75 댓글 6 에서 정정된 값.
        objc.msgSendVoid4(
            encoder,
            objc.sel("drawPrimitives:vertexStart:vertexCount:instanceCount:"),
            @as(objc.NSUInteger, 4),
            @as(objc.NSUInteger, 0),
            @as(objc.NSUInteger, 4),
            @as(objc.NSUInteger, instances.len),
        );
    }

    fn drawTextInstances(self: *MetalRenderer, encoder: objc.id, instances: []const TextInstance) void {
        if (instances.len == 0) return;

        const contents_ptr = objc.msgSend(self.text_buffer, objc.sel("contents")) orelse return;
        const contents: [*]TextInstance = @ptrCast(@alignCast(contents_ptr));
        @memcpy(contents[0..instances.len], instances);

        objc.msgSendVoid1(encoder, objc.sel("setRenderPipelineState:"), self.text_pipeline);
        objc.msgSendVoid3(encoder, objc.sel("setVertexBuffer:offset:atIndex:"), self.text_buffer, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 0));
        objc.msgSendVoid3(encoder, objc.sel("setVertexBuffer:offset:atIndex:"), self.constants_buffer, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 1));
        objc.msgSendVoid2(encoder, objc.sel("setFragmentTexture:atIndex:"), self.atlas_texture, @as(objc.NSUInteger, 0));

        objc.msgSendVoid4(
            encoder,
            objc.sel("drawPrimitives:vertexStart:vertexCount:instanceCount:"),
            @as(objc.NSUInteger, 4), // TriangleStrip
            @as(objc.NSUInteger, 0),
            @as(objc.NSUInteger, 4),
            @as(objc.NSUInteger, instances.len),
        );
    }

    // --- Helpers ---

    fn createPipeline(device: objc.id, vs: objc.id, fs: objc.id) !objc.id {
        const desc_class = objc.getClass("MTLRenderPipelineDescriptor");
        const desc = objc.msgSend(objc.msgSend(desc_class, objc.sel("alloc")), objc.sel("init"));

        objc.msgSendVoid1(desc, objc.sel("setVertexFunction:"), vs);
        objc.msgSendVoid1(desc, objc.sel("setFragmentFunction:"), fs);

        const attachments = objc.msgSend(desc, objc.sel("colorAttachments"));
        const att0 = objc.msgSend1(attachments, objc.sel("objectAtIndexedSubscript:"), @as(objc.NSUInteger, 0));
        objc.msgSendVoid1(att0, objc.sel("setPixelFormat:"), @as(objc.NSUInteger, 80)); // BGRA8Unorm

        // 텍스트 + 배경 둘 다 alpha 블렌딩 (커서 / 셀 투명도용).
        objc.msgSendVoid1(att0, objc.sel("setBlendingEnabled:"), objc.YES);
        objc.msgSendVoid1(att0, objc.sel("setSourceRGBBlendFactor:"), @as(objc.NSUInteger, 4)); // SourceAlpha
        objc.msgSendVoid1(att0, objc.sel("setDestinationRGBBlendFactor:"), @as(objc.NSUInteger, 5)); // OneMinusSourceAlpha
        objc.msgSendVoid1(att0, objc.sel("setSourceAlphaBlendFactor:"), @as(objc.NSUInteger, 4));
        objc.msgSendVoid1(att0, objc.sel("setDestinationAlphaBlendFactor:"), @as(objc.NSUInteger, 5));

        var err: objc.id = null;
        const pipeline = objc.msgSend2(device, objc.sel("newRenderPipelineStateWithDescriptor:error:"), desc, @as(*objc.id, &err));
        if (pipeline == null) {
            if (err) |e| {
                const edesc = objc.msgSend(e, objc.sel("localizedDescription"));
                if (edesc) |d| {
                    const cstr_ptr = objc.msgSend(d, objc.sel("UTF8String"));
                    if (cstr_ptr) |p| {
                        const cstr: [*:0]const u8 = @ptrCast(p);
                        std.log.err("Pipeline error: {s}", .{cstr});
                    }
                }
            }
            return error.PipelineFailed;
        }
        return pipeline;
    }

    fn createBuffer(device: objc.id, size: u32) objc.id {
        // MTLResourceStorageModeShared = 0
        return objc.msgSend2(device, objc.sel("newBufferWithLength:options:"), @as(objc.NSUInteger, size), @as(objc.NSUInteger, 0));
    }

    fn createAtlasTexture(device: objc.id) objc.id {
        const desc_class = objc.getClass("MTLTextureDescriptor");
        const desc = objc.msgSend(objc.msgSend(desc_class, objc.sel("alloc")), objc.sel("init"));

        objc.msgSendVoid1(desc, objc.sel("setPixelFormat:"), @as(objc.NSUInteger, 10)); // R8Unorm
        objc.msgSendVoid1(desc, objc.sel("setWidth:"), @as(objc.NSUInteger, ATLAS_SIZE));
        objc.msgSendVoid1(desc, objc.sel("setHeight:"), @as(objc.NSUInteger, ATLAS_SIZE));
        objc.msgSendVoid1(desc, objc.sel("setUsage:"), @as(objc.NSUInteger, 1)); // ShaderRead

        return objc.msgSend1(device, objc.sel("newTextureWithDescriptor:"), desc);
    }
};

// --- 색상 해석 (Windows renderer 와 같은 규칙) ---

fn resolveBg(
    style: ghostty.Style,
    raw: *const ghostty.Cell,
    colors: *const ghostty.RenderState.Colors,
    is_selected: bool,
    is_inverse: bool,
    dbg_r: f32,
    dbg_g: f32,
    dbg_b: f32,
) [3]f32 {
    if (is_selected) return .{ 0.25, 0.45, 0.75 };
    if (is_inverse) {
        const fg = style.fg(.{ .default = colors.foreground, .palette = &colors.palette });
        return .{ MetalRenderer.colorF(fg.r), MetalRenderer.colorF(fg.g), MetalRenderer.colorF(fg.b) };
    }
    if (style.bg(raw, &colors.palette)) |bg_col| {
        return .{ MetalRenderer.colorF(bg_col.r), MetalRenderer.colorF(bg_col.g), MetalRenderer.colorF(bg_col.b) };
    }
    return .{ dbg_r, dbg_g, dbg_b };
}

fn resolveFg(
    style: ghostty.Style,
    raw: *const ghostty.Cell,
    colors: *const ghostty.RenderState.Colors,
    is_selected: bool,
    is_inverse: bool,
) ghostty.color.RGB {
    if (is_selected) return colors.foreground;
    if (is_inverse) {
        if (style.bg(raw, &colors.palette)) |bg_col| return bg_col;
        return colors.background;
    }
    return style.fg(.{ .default = colors.foreground, .palette = &colors.palette });
}
