// Metal terminal renderer — macOS equivalent of windows/renderer.zig (D3D11).
// Uses instanced quads for backgrounds and alpha-blended text from glyph atlas.
// No ClearType (macOS uses grayscale AA) — simpler than Windows pipeline.

const std = @import("std");
const objc = @import("objc.zig");
const ct = @import("coretext.zig");
const CoreTextFontContext = @import("font.zig").CoreTextFontContext;
const GlyphAtlas = @import("glyph_atlas.zig").GlyphAtlas;
const ATLAS_SIZE = @import("glyph_atlas.zig").ATLAS_SIZE;
const ghostty = @import("ghostty-vt");

const MAX_INSTANCES: u32 = 32768;

const MTLClearColor = extern struct { r: f64, g: f64, b: f64, a: f64 };

// --- Instance data layouts (must match MSL structs) ---

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

// --- MSL Shaders ---

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

    // Metal objects (stored as ObjC ids)
    device: objc.id,
    command_queue: objc.id,
    bg_pipeline: objc.id,
    text_pipeline: objc.id,
    bg_buffer: objc.id,
    text_buffer: objc.id,
    atlas_texture: objc.id,
    constants_buffer: objc.id,

    // Default background
    default_bg: [3]f32,

    // Viewport
    vp_width: u32 = 0,
    vp_height: u32 = 0,

    // Retina scale
    scale: f32,

    const TAB_BAR_R: f32 = 20.0 / 255.0;
    const TAB_BAR_G: f32 = 20.0 / 255.0;
    const TAB_BAR_B: f32 = 20.0 / 255.0;
    const TAB_ACTIVE_R: f32 = 50.0 / 255.0;
    const TAB_TEXT_R: f32 = 180.0 / 255.0;
    const SCROLLBAR_W: f32 = 8;
    const SCROLLBAR_MIN_H: f32 = 20;

    fn colorF(v: u8) f32 {
        return @as(f32, @floatFromInt(v)) / 255.0;
    }

    pub fn init(
        alloc: std.mem.Allocator,
        device: objc.id,
        layer: objc.id,
        font_family: []const u8,
        font_size: f32,
        cell_w: u32,
        cell_h: u32,
        bg_rgb: ?[3]u8,
        scale: f32,
    ) !MetalRenderer {
        const bg = bg_rgb orelse [3]u8{ 30, 30, 30 };

        // 1. Create command queue
        const cmd_queue = objc.msgSend(device, objc.sel("newCommandQueue"));

        // 2. Init font context
        var font_ctx = try CoreTextFontContext.init(font_family, font_size, cell_w, cell_h, scale);
        errdefer font_ctx.deinit();

        // 3. Init glyph atlas (CPU-side, uploads to Metal texture)
        var glyph_atlas = try GlyphAtlas.init(alloc, font_size, scale);
        errdefer glyph_atlas.deinit();

        // 4. Compile Metal shaders
        const source_str = objc.nsString(shader_source);
        var err: ?objc.id = null;
        const library = objc.msgSend3(device, objc.sel("newLibraryWithSource:options:error:"), source_str, @as(?objc.id, null), @as(*?objc.id, &err));
        if (@intFromPtr(library) == 0) {
            if (err) |e| {
                const desc = objc.msgSend(e, objc.sel("localizedDescription"));
                const cstr: [*:0]const u8 = @ptrCast(objc.msgSend(desc, objc.sel("UTF8String")));
                std.log.err("Metal shader error: {s}", .{cstr});
            }
            return error.ShaderCompileFailed;
        }

        const bg_vs_fn = objc.msgSend1(library, objc.sel("newFunctionWithName:"), objc.nsString("bg_vs"));
        const bg_fs_fn = objc.msgSend1(library, objc.sel("newFunctionWithName:"), objc.nsString("bg_fs"));
        const text_vs_fn = objc.msgSend1(library, objc.sel("newFunctionWithName:"), objc.nsString("text_vs"));
        const text_fs_fn = objc.msgSend1(library, objc.sel("newFunctionWithName:"), objc.nsString("text_fs"));

        // 5. Create render pipeline states
        const bg_pipeline = try createPipeline(device, bg_vs_fn, bg_fs_fn, true);
        const text_pipeline = try createPipeline(device, text_vs_fn, text_fs_fn, false);

        // 6. Create instance buffers
        const bg_buf = createBuffer(device, MAX_INSTANCES * @sizeOf(BgInstance));
        const text_buf = createBuffer(device, MAX_INSTANCES * @sizeOf(TextInstance));

        // 7. Create constants buffer (float4: screen_w, screen_h, atlas_w, atlas_h)
        const const_buf = createBuffer(device, 16);

        // 8. Create atlas texture (R8Unorm)
        const atlas_tex = createAtlasTexture(device);

        // 9. Configure layer
        objc.msgSendVoid1(layer, objc.sel("setDevice:"), device);
        // MTLPixelFormatBGRA8Unorm = 80
        objc.msgSendVoid1(layer, objc.sel("setPixelFormat:"), @as(objc.NSUInteger, 80));

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
        // Metal objects are ARC-managed (or we leak; cleanup on exit is acceptable)
    }

    pub fn resize(self: *MetalRenderer, width: u32, height: u32) void {
        self.vp_width = width;
        self.vp_height = height;
    }

    /// Render a full frame to the given CAMetalLayer.
    pub fn renderFrame(self: *MetalRenderer, layer: objc.id, terminal: *ghostty.Terminal, cell_w: i32, cell_h: i32, y_offset: i32, padding: i32) void {
        // Get next drawable
        const drawable = objc.msgSend(layer, objc.sel("nextDrawable"));
        if (@intFromPtr(drawable) == 0) return;

        const texture = objc.msgSend(drawable, objc.sel("texture"));

        // Create command buffer
        const cmd_buf = objc.msgSend(self.command_queue, objc.sel("commandBuffer"));
        if (@intFromPtr(cmd_buf) == 0) return;

        // Create render pass descriptor
        const rpd_class = objc.getClass("MTLRenderPassDescriptor");
        const rpd = objc.msgSend(rpd_class, objc.sel("renderPassDescriptor"));

        // Configure color attachment 0
        const attachments = objc.msgSend(rpd, objc.sel("colorAttachments"));
        const att0 = objc.msgSend1(attachments, objc.sel("objectAtIndexedSubscript:"), @as(objc.NSUInteger, 0));
        objc.msgSendVoid1(att0, objc.sel("setTexture:"), texture);
        // MTLLoadActionClear = 2
        objc.msgSendVoid1(att0, objc.sel("setLoadAction:"), @as(objc.NSUInteger, 2));
        // MTLStoreActionStore = 1
        objc.msgSendVoid1(att0, objc.sel("setStoreAction:"), @as(objc.NSUInteger, 1));

        // Set clear color to default background
        const clear = MTLClearColor{
            .r = @floatCast(self.default_bg[0]),
            .g = @floatCast(self.default_bg[1]),
            .b = @floatCast(self.default_bg[2]),
            .a = 1.0,
        };
        setClearColor(att0, clear);

        // Create encoder
        const encoder = objc.msgSend1(cmd_buf, objc.sel("renderCommandEncoderWithDescriptor:"), rpd);
        if (@intFromPtr(encoder) == 0) return;

        // Update constants
        self.updateConstants();

        // Upload atlas if dirty
        if (self.atlas.dirty) {
            self.uploadAtlas();
            self.atlas.dirty = false;
        }

        // Render terminal content
        self.renderTerminalContent(encoder, terminal, cell_w, cell_h, y_offset, padding);

        // End encoding, present, commit
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
        // Clear stale selection data before update. Without this, when dragging
        // right-to-left, non-dirty rows keep previous frame's selection bounds,
        // causing the leftmost character to not be highlighted.
        {
            const slice = self.render_state.row_data.slice();
            for (slice.items(.selection)) |*s| s.* = null;
        }
        self.render_state.selection_cache = null;

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

        if (bg_count > 0) {
            self.drawBgInstances(encoder, bg_buf[0..bg_count]);
        }

        var block_count: u32 = 0;

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

                if (isBlockElement(cp)) {
                    if (block_count >= MAX_CELLS) {
                        self.drawBgInstances(encoder, bg_buf[0..block_count]);
                        block_count = 0;
                    }
                    const style = if (raw.style_id != 0) styles[x] else ghostty.Style{};
                    const is_inverse = style.flags.inverse;
                    const x16: u16 = @intCast(x);
                    const is_selected = if (sel_range) |sr| (x16 >= sr[0] and x16 <= sr[1]) else false;
                    const fg_rgb = resolveFg(style, &raw, &colors, is_selected, is_inverse);
                    const rect = blockElementRect(cp) orelse continue;
                    const width: f32 = if (raw.wide == .wide) 2.0 * cw else cw;
                    const fx: f32 = @as(f32, @floatFromInt(x)) * cw + x_pad;
                    bg_buf[block_count] = .{
                        .pos = .{ fx + rect.x0 * width, fy + rect.y0 * ch },
                        .size = .{ (rect.x1 - rect.x0) * width, (rect.y1 - rect.y0) * ch },
                        .color = .{ colorF(fg_rgb.r), colorF(fg_rgb.g), colorF(fg_rgb.b), rect.alpha },
                    };
                    block_count += 1;
                    continue;
                }

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

                const fx: f32 = @as(f32, @floatFromInt(x)) * cw + x_pad;
                // All values are in pixel units: bearing_x/y from atlas (pixel),
                // ascent_px (pixel), entry.w/h (pixel)
                const gx = fx + @as(f32, @floatFromInt(entry.bearing_x));
                const gy = fy + self.font.ascent_px + @as(f32, @floatFromInt(entry.bearing_y));

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

        if (text_count > 0) {
            self.drawTextInstances(encoder, text_buf[0..text_count]);
        }
        if (block_count > 0) {
            self.drawBgInstances(encoder, bg_buf[0..block_count]);
        }

        // --- Cursor ---
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
    }

    fn updateConstants(self: *MetalRenderer) void {
        const data: *[4]f32 = @ptrCast(@alignCast(objc.msgSend(self.constants_buffer, objc.sel("contents"))));
        data.* = .{
            @floatFromInt(self.vp_width),
            @floatFromInt(self.vp_height),
            @floatFromInt(ATLAS_SIZE),
            @floatFromInt(ATLAS_SIZE),
        };
    }

    fn uploadAtlas(self: *MetalRenderer) void {
        // Replace entire texture content via replaceRegion:mipmapLevel:withBytes:bytesPerRow:
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

        // Upload to buffer
        const contents: [*]BgInstance = @ptrCast(@alignCast(objc.msgSend(self.bg_buffer, objc.sel("contents"))));
        @memcpy(contents[0..instances.len], instances);

        // Set pipeline
        objc.msgSendVoid1(encoder, objc.sel("setRenderPipelineState:"), self.bg_pipeline);

        // Set vertex buffers
        objc.msgSendVoid3(encoder, objc.sel("setVertexBuffer:offset:atIndex:"), self.bg_buffer, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 0));
        objc.msgSendVoid3(encoder, objc.sel("setVertexBuffer:offset:atIndex:"), self.constants_buffer, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 1));

        // Draw instanced triangle strip (4 vertices per quad)
        // MTLPrimitiveTypeTriangleStrip = 4 (NOT 3, which is Triangle)
        msgSendVoid4(encoder, objc.sel("drawPrimitives:vertexStart:vertexCount:instanceCount:"), @as(objc.NSUInteger, 4), @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 4), @as(objc.NSUInteger, instances.len));
    }

    fn drawTextInstances(self: *MetalRenderer, encoder: objc.id, instances: []const TextInstance) void {
        if (instances.len == 0) return;

        const contents: [*]TextInstance = @ptrCast(@alignCast(objc.msgSend(self.text_buffer, objc.sel("contents"))));
        @memcpy(contents[0..instances.len], instances);

        objc.msgSendVoid1(encoder, objc.sel("setRenderPipelineState:"), self.text_pipeline);
        objc.msgSendVoid3(encoder, objc.sel("setVertexBuffer:offset:atIndex:"), self.text_buffer, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 0));
        objc.msgSendVoid3(encoder, objc.sel("setVertexBuffer:offset:atIndex:"), self.constants_buffer, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 1));
        objc.msgSendVoid2(encoder, objc.sel("setFragmentTexture:atIndex:"), self.atlas_texture, @as(objc.NSUInteger, 0));

        // MTLPrimitiveTypeTriangleStrip = 4 (4 vertices → 1 quad)
        msgSendVoid4(encoder, objc.sel("drawPrimitives:vertexStart:vertexCount:instanceCount:"), @as(objc.NSUInteger, 4), @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 4), @as(objc.NSUInteger, instances.len));
    }

    // --- Helpers ---

    fn createPipeline(device: objc.id, vs: objc.id, fs: objc.id, is_bg: bool) !objc.id {
        const desc_class = objc.getClass("MTLRenderPipelineDescriptor");
        const desc = objc.msgSend(objc.msgSend(desc_class, objc.sel("alloc")), objc.sel("init"));

        objc.msgSendVoid1(desc, objc.sel("setVertexFunction:"), vs);
        objc.msgSendVoid1(desc, objc.sel("setFragmentFunction:"), fs);

        // Color attachment 0: BGRA8Unorm
        const attachments = objc.msgSend(desc, objc.sel("colorAttachments"));
        const att0 = objc.msgSend1(attachments, objc.sel("objectAtIndexedSubscript:"), @as(objc.NSUInteger, 0));
        // MTLPixelFormatBGRA8Unorm = 80
        objc.msgSendVoid1(att0, objc.sel("setPixelFormat:"), @as(objc.NSUInteger, 80));

        if (!is_bg) {
            // Alpha blending for text
            objc.msgSendVoid1(att0, objc.sel("setBlendingEnabled:"), objc.YES);
            // MTLBlendFactorSourceAlpha = 4, MTLBlendFactorOneMinusSourceAlpha = 5
            objc.msgSendVoid1(att0, objc.sel("setSourceRGBBlendFactor:"), @as(objc.NSUInteger, 4));
            objc.msgSendVoid1(att0, objc.sel("setDestinationRGBBlendFactor:"), @as(objc.NSUInteger, 5));
            objc.msgSendVoid1(att0, objc.sel("setSourceAlphaBlendFactor:"), @as(objc.NSUInteger, 4));
            objc.msgSendVoid1(att0, objc.sel("setDestinationAlphaBlendFactor:"), @as(objc.NSUInteger, 5));
        } else {
            // Alpha blending for backgrounds too (for cursor transparency, etc.)
            objc.msgSendVoid1(att0, objc.sel("setBlendingEnabled:"), objc.YES);
            objc.msgSendVoid1(att0, objc.sel("setSourceRGBBlendFactor:"), @as(objc.NSUInteger, 4));
            objc.msgSendVoid1(att0, objc.sel("setDestinationRGBBlendFactor:"), @as(objc.NSUInteger, 5));
            objc.msgSendVoid1(att0, objc.sel("setSourceAlphaBlendFactor:"), @as(objc.NSUInteger, 4));
            objc.msgSendVoid1(att0, objc.sel("setDestinationAlphaBlendFactor:"), @as(objc.NSUInteger, 5));
        }

        var err: ?objc.id = null;
        const pipeline = objc.msgSend2(device, objc.sel("newRenderPipelineStateWithDescriptor:error:"), desc, @as(*?objc.id, &err));
        if (@intFromPtr(pipeline) == 0) {
            if (err) |e| {
                const edesc = objc.msgSend(e, objc.sel("localizedDescription"));
                const cstr: [*:0]const u8 = @ptrCast(objc.msgSend(edesc, objc.sel("UTF8String")));
                std.log.err("Pipeline error: {s}", .{cstr});
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

        // MTLPixelFormatR8Unorm = 10
        objc.msgSendVoid1(desc, objc.sel("setPixelFormat:"), @as(objc.NSUInteger, 10));
        objc.msgSendVoid1(desc, objc.sel("setWidth:"), @as(objc.NSUInteger, ATLAS_SIZE));
        objc.msgSendVoid1(desc, objc.sel("setHeight:"), @as(objc.NSUInteger, ATLAS_SIZE));
        // MTLTextureUsageShaderRead = 1
        objc.msgSendVoid1(desc, objc.sel("setUsage:"), @as(objc.NSUInteger, 1));

        return objc.msgSend1(device, objc.sel("newTextureWithDescriptor:"), desc);
    }
};

// --- setClearColor helper (passes struct by value) ---
fn setClearColor(att: objc.id, color: MTLClearColor) void {
    const f: *const fn (objc.id, objc.SEL, @TypeOf(color)) callconv(.c) void = @ptrCast(objc.msgSend_raw);
    f(att, objc.sel("setClearColor:"), color);
}

// --- Color resolution (matches windows/renderer.zig) ---

fn resolveBg(style: ghostty.Style, raw: *const ghostty.Cell, colors: *const ghostty.RenderState.Colors, is_selected: bool, is_inverse: bool, dbg_r: f32, dbg_g: f32, dbg_b: f32) [3]f32 {
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

fn resolveFg(style: ghostty.Style, raw: *const ghostty.Cell, colors: *const ghostty.RenderState.Colors, is_selected: bool, is_inverse: bool) ghostty.color.RGB {
    if (is_selected) return colors.foreground;
    if (is_inverse) {
        if (style.bg(raw, &colors.palette)) |bg_col| return bg_col;
        return colors.background;
    }
    return style.fg(.{ .default = colors.foreground, .palette = &colors.palette });
}

fn isBlockElement(cp: u21) bool {
    return cp >= 0x2580 and cp <= 0x259F;
}

const BlockRect = struct { x0: f32, y0: f32, x1: f32, y1: f32, alpha: f32 };

fn blockElementRect(cp: u21) ?BlockRect {
    return switch (cp) {
        0x2580 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 0.5, .alpha = 1 },
        0x2581 => .{ .x0 = 0, .y0 = 0.875, .x1 = 1, .y1 = 1, .alpha = 1 },
        0x2582 => .{ .x0 = 0, .y0 = 0.75, .x1 = 1, .y1 = 1, .alpha = 1 },
        0x2583 => .{ .x0 = 0, .y0 = 0.625, .x1 = 1, .y1 = 1, .alpha = 1 },
        0x2584 => .{ .x0 = 0, .y0 = 0.5, .x1 = 1, .y1 = 1, .alpha = 1 },
        0x2585 => .{ .x0 = 0, .y0 = 0.375, .x1 = 1, .y1 = 1, .alpha = 1 },
        0x2586 => .{ .x0 = 0, .y0 = 0.25, .x1 = 1, .y1 = 1, .alpha = 1 },
        0x2587 => .{ .x0 = 0, .y0 = 0.125, .x1 = 1, .y1 = 1, .alpha = 1 },
        0x2588 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 1 },
        0x2589 => .{ .x0 = 0, .y0 = 0, .x1 = 0.875, .y1 = 1, .alpha = 1 },
        0x258A => .{ .x0 = 0, .y0 = 0, .x1 = 0.75, .y1 = 1, .alpha = 1 },
        0x258B => .{ .x0 = 0, .y0 = 0, .x1 = 0.625, .y1 = 1, .alpha = 1 },
        0x258C => .{ .x0 = 0, .y0 = 0, .x1 = 0.5, .y1 = 1, .alpha = 1 },
        0x258D => .{ .x0 = 0, .y0 = 0, .x1 = 0.375, .y1 = 1, .alpha = 1 },
        0x258E => .{ .x0 = 0, .y0 = 0, .x1 = 0.25, .y1 = 1, .alpha = 1 },
        0x258F => .{ .x0 = 0, .y0 = 0, .x1 = 0.125, .y1 = 1, .alpha = 1 },
        0x2590 => .{ .x0 = 0.5, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 1 },
        0x2591 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 0.25 },
        0x2592 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 0.5 },
        0x2593 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 0.75 },
        0x2594 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 0.125, .alpha = 1 },
        0x2595 => .{ .x0 = 0.875, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 1 },
        else => null,
    };
}

// Declare msgSendVoid4 that we need
fn msgSendVoid4(target: objc.id, s: objc.SEL, a1: anytype, a2: anytype, a3: anytype, a4: anytype) void {
    const f: *const fn (objc.id, objc.SEL, @TypeOf(a1), @TypeOf(a2), @TypeOf(a3), @TypeOf(a4)) callconv(.c) void = @ptrCast(objc.msgSend_raw);
    f(target, s, a1, a2, a3, a4);
}
