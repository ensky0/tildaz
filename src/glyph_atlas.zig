// Glyph texture atlas — rasterizes glyphs via DirectWrite, caches in a 2D atlas.
// Two glyph rasterization paths share the same R8G8B8A8 atlas:
//   - Mono / ClearType: `DWRITE_TEXTURE_CLEARTYPE_3x1` 3 bytes/pixel (subpixel
//     R/G/B alpha). Atlas RGB = subpixel masks, A = 0xFF. Shader applies fg
//     color via dual-source ClearType blend.
//   - Color emoji (#134): `IDWriteFactory2.TranslateColorGlyphRun` 으로 layer
//     enumerator. layer 별로 alpha mask + layer color premultiply 해서
//     accumulator 에 src-over composite, 마지막에 depremult → atlas RGB = 컬러,
//     A = alpha. shader 가 `is_color` 분기로 mask 대신 색 직접 출력.

const std = @import("std");
const dw = @import("directwrite.zig");
const d3d = @import("d3d11.zig");

pub const ATLAS_SIZE: u32 = 2048;

pub const AtlasEntry = struct {
    x: u16, // position in atlas (pixels)
    y: u16,
    w: u16, // glyph dimensions (pixels)
    h: u16,
    bearing_x: i16, // offset from cell origin to glyph top-left
    bearing_y: i16,
    /// true 면 atlas 의 RGB 가 *컬러 (depremult)*, A 가 alpha mask. shader 가
    /// fg 와 곱하지 않고 atlas 그대로 출력 + atlas.a 를 mask 로 ClearType blend
    /// state 에 전달. false 면 기존 ClearType subpixel mono path.
    is_color: bool = false,
};

const GlyphKey = struct {
    face: usize, // pointer value as key
    index: u16,
};

pub const GlyphAtlas = struct {
    alloc: std.mem.Allocator,
    cache: std.AutoHashMap(GlyphKey, AtlasEntry),

    // Atlas packing state (simple row-based)
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    row_height: u32 = 0,

    // DWrite resources for rasterization
    dw_factory: *dw.IDWriteFactory,
    rendering_params: *dw.IDWriteRenderingParams,
    rendering_mode: u32,
    font_em_size: f32,
    pixels_per_dip: f32,

    // D3D11 texture
    texture: *d3d.ID3D11Texture2D,
    srv: *d3d.ID3D11ShaderResourceView,
    d3d_ctx: *d3d.ID3D11DeviceContext,

    // Temporary buffers for glyph rasterization (reused, heap-allocated)
    temp_buf: []u8, // RGBA output: 256*256*4 bytes
    ct_buf: []u8,   // ClearType 3x1 input: 256*256*3 bytes

    // Set to true when getOrInsert finds the atlas full; caller must flush, call reset(), then retry.
    is_full: bool = false,

    pub fn init(
        alloc: std.mem.Allocator,
        dw_factory: *dw.IDWriteFactory,
        font_em_size: f32,
        pixels_per_dip: f32,
        device: *d3d.ID3D11Device,
        ctx: *d3d.ID3D11DeviceContext,
    ) !GlyphAtlas {
        // Read system default rendering params for cleartype_level, pixel_geometry, rendering_mode.
        // Then create custom params with gamma=1.0, contrast=0.0 (shader handles those).
        // This matches Windows Terminal's DWrite_GetRenderParams approach.
        var sys_cleartype_level: f32 = 1.0;
        var sys_pixel_geometry: u32 = dw.DWRITE_PIXEL_GEOMETRY_RGB;
        var sys_rendering_mode: u32 = dw.DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC;
        var sys_rp: ?*dw.IDWriteRenderingParams = null;
        if (dw_factory.CreateRenderingParams(&sys_rp) >= 0) {
            sys_cleartype_level = sys_rp.?.GetClearTypeLevel();
            sys_pixel_geometry = sys_rp.?.GetPixelGeometry();
            sys_rendering_mode = sys_rp.?.GetRenderingMode();
            _ = sys_rp.?.Release();
        }

        var rp: ?*dw.IDWriteRenderingParams = null;
        if (dw_factory.CreateCustomRenderingParams(
            1.0, // gamma (linear — shader applies gamma correction)
            0.0, // enhanced contrast (none — shader handles it)
            sys_cleartype_level,
            sys_pixel_geometry,
            sys_rendering_mode,
            &rp,
        ) < 0) return error.RenderingParamsFailed;
        errdefer _ = rp.?.vtable.Release(rp.?);

        // Create atlas texture (D3D11_USAGE_DEFAULT for UpdateSubresource)
        var tex: ?*d3d.ID3D11Texture2D = null;
        if (device.CreateTexture2D(&.{
            .Width = ATLAS_SIZE,
            .Height = ATLAS_SIZE,
            .Format = d3d.DXGI_FORMAT_R8G8B8A8_UNORM,
            .BindFlags = d3d.D3D11_BIND_SHADER_RESOURCE,
        }, null, &tex) < 0) return error.AtlasTextureFailed;
        errdefer _ = tex.?.Release();

        // Create shader resource view
        var srv: ?*d3d.ID3D11ShaderResourceView = null;
        if (device.CreateShaderResourceView(@ptrCast(tex.?), null, &srv) < 0)
            return error.AtlasSrvFailed;
        errdefer _ = srv.?.Release();

        // Allocate temp buffers for max glyph size (256x256)
        const temp_buf = try alloc.alloc(u8, 256 * 256 * 4); // RGBA
        errdefer alloc.free(temp_buf);
        const ct_buf = try alloc.alloc(u8, 256 * 256 * 3); // ClearType 3x1 RGB

        return .{
            .alloc = alloc,
            .cache = std.AutoHashMap(GlyphKey, AtlasEntry).init(alloc),
            .dw_factory = dw_factory,
            .rendering_params = rp.?,
            .rendering_mode = sys_rendering_mode,
            .font_em_size = font_em_size,
            .pixels_per_dip = pixels_per_dip,
            .texture = tex.?,
            .srv = srv.?,
            .d3d_ctx = ctx,
            .temp_buf = temp_buf,
            .ct_buf = ct_buf,
        };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        self.alloc.free(self.ct_buf);
        self.alloc.free(self.temp_buf);
        self.cache.deinit();
        _ = self.srv.Release();
        _ = self.texture.Release();
        _ = self.rendering_params.Release();
    }

    /// Look up or rasterize a glyph.
    /// Returns null in two cases:
    ///   - is_full=true:  atlas is full; caller must drawTextInstances, call reset(), then retry.
    ///   - is_full=false: DirectWrite rasterization failed; skip this glyph.
    ///
    /// Color emoji 글리프는 `rasterizeColor` (TranslateColorGlyphRun) 를 먼저
    /// 시도; 실패 (DWRITE_E_NOCOLOR 포함) 시 일반 alpha rasterize 로 fall-through.
    pub fn getOrInsert(self: *GlyphAtlas, face: *dw.IDWriteFontFace, glyph_index: u16) ?AtlasEntry {
        const key = GlyphKey{ .face = @intFromPtr(face), .index = glyph_index };
        if (self.cache.get(key)) |entry| return entry;

        const entry = self.rasterizeColor(face, glyph_index) orelse
            self.rasterize(face, glyph_index) orelse return null;
        self.cache.put(key, entry) catch return null;
        return entry;
    }

    /// Reset the atlas (clear cache and packing state). Call only after flushing all pending draws.
    pub fn reset(self: *GlyphAtlas) void {
        self.cache.clearRetainingCapacity();
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.row_height = 0;
        self.is_full = false;
    }

    fn rasterize(self: *GlyphAtlas, face: *dw.IDWriteFontFace, glyph_index: u16) ?AtlasEntry {
        // Create DWRITE_GLYPH_RUN for single glyph
        const indices = [1]dw.UINT16{glyph_index};
        const advances = [1]dw.FLOAT{0}; // not used for analysis
        const glyph_run = dw.DWRITE_GLYPH_RUN{
            .fontFace = face,
            .fontEmSize = self.font_em_size,
            .glyphCount = 1,
            .glyphIndices = &indices,
            .glyphAdvances = &advances,
            .glyphOffsets = null,
            .isSideways = 0,
            .bidiLevel = 0,
        };

        // Create glyph run analysis using system rendering mode
        // Fall back to NATURAL_SYMMETRIC if system returns DEFAULT(0) or unsupported mode
        const render_mode = if (self.rendering_mode >= 3 and self.rendering_mode <= 6)
            self.rendering_mode
        else
            dw.DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC;

        var analysis: ?*dw.IDWriteGlyphRunAnalysis = null;
        if (self.dw_factory.CreateGlyphRunAnalysis(
            &glyph_run,
            self.pixels_per_dip,
            null, // transform
            render_mode,
            dw.DWRITE_MEASURING_MODE_NATURAL,
            0, // baselineOriginX
            0, // baselineOriginY
            &analysis,
        ) < 0) return null;
        defer _ = analysis.?.Release();

        // Get bounds of ClearType texture
        var bounds: dw.RECT = undefined;
        if (analysis.?.GetAlphaTextureBounds(dw.DWRITE_TEXTURE_CLEARTYPE_3x1, &bounds) < 0)
            return null;

        const gw: i32 = bounds.right - bounds.left;
        const gh: i32 = bounds.bottom - bounds.top;
        if (gw <= 0 or gh <= 0) {
            // Empty glyph (e.g. space) — store zero-size entry
            return AtlasEntry{
                .x = 0,
                .y = 0,
                .w = 0,
                .h = 0,
                .bearing_x = @intCast(bounds.left),
                .bearing_y = @intCast(bounds.top),
            };
        }

        const w: u32 = @intCast(gw);
        const h: u32 = @intCast(gh);

        // Check glyph fits in temp buffer
        if (w > 256 or h > 256) return null;

        // Get ClearType alpha texture (3 bytes per pixel: R, G, B)
        const ct_size: u32 = w * h * 3;
        if (analysis.?.CreateAlphaTexture(
            dw.DWRITE_TEXTURE_CLEARTYPE_3x1,
            &bounds,
            self.ct_buf.ptr,
            ct_size,
        ) < 0) return null;

        // Convert ClearType RGB (3bpp) → RGBA (4bpp) for the atlas texture
        const rgba_pitch = w * 4;
        for (0..h) |row| {
            for (0..w) |col| {
                const src_off = row * w * 3 + col * 3;
                const dst_off = row * rgba_pitch + col * 4;
                self.temp_buf[dst_off + 0] = self.ct_buf[src_off + 0]; // R
                self.temp_buf[dst_off + 1] = self.ct_buf[src_off + 1]; // G
                self.temp_buf[dst_off + 2] = self.ct_buf[src_off + 2]; // B
                self.temp_buf[dst_off + 3] = 0xFF; // A (opaque)
            }
        }

        // Pack into atlas; if full, signal caller to flush+reset+retry before we overwrite anything
        const pos = self.packGlyph(w, h) orelse {
            self.is_full = true;
            return null;
        };

        // Upload to GPU texture via UpdateSubresource
        const box = d3d.D3D11_BOX{
            .left = pos[0],
            .top = pos[1],
            .right = pos[0] + w,
            .bottom = pos[1] + h,
        };
        self.d3d_ctx.UpdateSubresource(
            @ptrCast(self.texture),
            0,
            &box,
            @ptrCast(self.temp_buf.ptr),
            rgba_pitch,
            0,
        );

        return AtlasEntry{
            .x = @intCast(pos[0]),
            .y = @intCast(pos[1]),
            .w = @intCast(w),
            .h = @intCast(h),
            .bearing_x = @intCast(bounds.left),
            .bearing_y = @intCast(bounds.top),
            .is_color = false,
        };
    }

    /// 컬러 emoji 글리프 라스터화 (#134) — `IDWriteFactory2.TranslateColorGlyphRun`
    /// 으로 layer 분해 → 각 layer 의 alpha mask × 색을 premultiplied src-over 로
    /// accumulator (temp_buf) 에 누적 → 마지막에 depremultiply → atlas 에 RGBA
    /// (RGB=색, A=alpha) 로 업로드. is_color=true 인 AtlasEntry 반환.
    ///
    /// 컬러 글리프 아닌 경우 (TranslateColorGlyphRun 가 DWRITE_E_NOCOLOR /
    /// 그 외 실패 반환) null 반환 → caller 가 일반 `rasterize` 로 fall-through.
    fn rasterizeColor(self: *GlyphAtlas, face: *dw.IDWriteFontFace, glyph_index: u16) ?AtlasEntry {
        // IDWriteFactory2 가 있어야 컬러 path 가능 (Windows 8.1+).
        var factory2: ?*dw.IDWriteFactory2 = null;
        if (self.dw_factory.QueryInterface(&dw.IID_IDWriteFactory2, @ptrCast(&factory2)) < 0) return null;
        defer _ = factory2.?.Release();

        const indices = [1]dw.UINT16{glyph_index};
        const advances = [1]dw.FLOAT{0};
        const glyph_run = dw.DWRITE_GLYPH_RUN{
            .fontFace = face,
            .fontEmSize = self.font_em_size,
            .glyphCount = 1,
            .glyphIndices = &indices,
            .glyphAdvances = &advances,
            .glyphOffsets = null,
            .isSideways = 0,
            .bidiLevel = 0,
        };

        // 컨테이너 글리프 (glyph_index 가 가리키는 main glyph) 는 COLR/PNG 폰트
        // 에서 outline 이 없을 수 있어 GetAlphaTextureBounds 가 빈 bounds 반환.
        // 따라서 bounds 는 layer 들의 union 으로 계산해야 함 — 두 패스 (Pass 1:
        // bounds 만, Pass 2: composite). enumerator 는 한 번만 iterate 가능
        // (rewind 안 됨) 라 TranslateColorGlyphRun 을 두 번 호출.

        // Pass 1: layer bounds union.
        var bounds = dw.RECT{ .left = 0x7FFFFFFF, .top = 0x7FFFFFFF, .right = -0x80000000, .bottom = -0x80000000 };
        {
            var enum1: ?*dw.IDWriteColorGlyphRunEnumerator = null;
            const tr1 = factory2.?.TranslateColorGlyphRun(
                0,
                0,
                &glyph_run,
                null,
                dw.DWRITE_MEASURING_MODE_NATURAL,
                null,
                0,
                &enum1,
            );
            if (tr1 < 0 or enum1 == null) return null;
            defer _ = enum1.?.Release();
            while (true) {
                var has_run: dw.BOOL = 0;
                if (enum1.?.MoveNext(&has_run) < 0 or has_run == 0) break;
                var cr_ptr: ?*const dw.IDWriteColorGlyphRun = null;
                if (enum1.?.GetCurrentRun(&cr_ptr) < 0) continue;
                const cr = cr_ptr orelse continue;
                var la: ?*dw.IDWriteGlyphRunAnalysis = null;
                if (self.dw_factory.CreateGlyphRunAnalysis(
                    &cr.glyph_run,
                    self.pixels_per_dip,
                    null,
                    dw.DWRITE_RENDERING_MODE_ALIASED,
                    dw.DWRITE_MEASURING_MODE_NATURAL,
                    cr.baseline_origin_x,
                    cr.baseline_origin_y,
                    &la,
                ) < 0) continue;
                defer _ = la.?.Release();
                var lb: dw.RECT = undefined;
                if (la.?.GetAlphaTextureBounds(dw.DWRITE_TEXTURE_ALIASED_1x1, &lb) < 0) continue;
                if (lb.right - lb.left <= 0 or lb.bottom - lb.top <= 0) continue;
                if (lb.left < bounds.left) bounds.left = lb.left;
                if (lb.top < bounds.top) bounds.top = lb.top;
                if (lb.right > bounds.right) bounds.right = lb.right;
                if (lb.bottom > bounds.bottom) bounds.bottom = lb.bottom;
            }
        }

        const gw: i32 = bounds.right - bounds.left;
        const gh: i32 = bounds.bottom - bounds.top;
        if (gw <= 0 or gh <= 0) return null;
        const w: u32 = @intCast(gw);
        const h: u32 = @intCast(gh);
        if (w > 256 or h > 256) return null;

        // Pass 2: composite layers into accumulator.
        var enumerator: ?*dw.IDWriteColorGlyphRunEnumerator = null;
        if (factory2.?.TranslateColorGlyphRun(
            0,
            0,
            &glyph_run,
            null,
            dw.DWRITE_MEASURING_MODE_NATURAL,
            null,
            0,
            &enumerator,
        ) < 0 or enumerator == null) return null;
        defer _ = enumerator.?.Release();

        // accumulator 를 transparent (0,0,0,0) 로 초기화. premult 공간.
        const acc_size = w * h * 4;
        @memset(self.temp_buf[0..acc_size], 0);

        // layer 순회 — bottom-to-top 순서로 enumerator 가 반환.
        while (true) {
            var has_run: dw.BOOL = 0;
            if (enumerator.?.MoveNext(&has_run) < 0 or has_run == 0) break;

            var color_run_ptr: ?*const dw.IDWriteColorGlyphRun = null;
            if (enumerator.?.GetCurrentRun(&color_run_ptr) < 0) continue;
            const cr = color_run_ptr orelse continue;

            // layer 색. paletteIndex == 0xFFFF (NO_PALETTE) 이면 사용자 fg
            // 사용해야 하는 layer — atlas cache 는 fg-independent 라 흰색으로
            // 대체 (대부분 emoji 는 모든 layer 에 palette 색 정의).
            const lr: f32 = if (cr.palette_index == dw.DWRITE_NO_PALETTE_INDEX) 1.0 else cr.run_color.r;
            const lg: f32 = if (cr.palette_index == dw.DWRITE_NO_PALETTE_INDEX) 1.0 else cr.run_color.g;
            const lb: f32 = if (cr.palette_index == dw.DWRITE_NO_PALETTE_INDEX) 1.0 else cr.run_color.b;
            const la: f32 = if (cr.palette_index == dw.DWRITE_NO_PALETTE_INDEX) 1.0 else cr.run_color.a;

            // layer 의 alpha mask 라스터.
            var layer_analysis: ?*dw.IDWriteGlyphRunAnalysis = null;
            if (self.dw_factory.CreateGlyphRunAnalysis(
                &cr.glyph_run,
                self.pixels_per_dip,
                null,
                dw.DWRITE_RENDERING_MODE_ALIASED,
                dw.DWRITE_MEASURING_MODE_NATURAL,
                cr.baseline_origin_x,
                cr.baseline_origin_y,
                &layer_analysis,
            ) < 0) continue;
            defer _ = layer_analysis.?.Release();

            var layer_bounds: dw.RECT = undefined;
            if (layer_analysis.?.GetAlphaTextureBounds(dw.DWRITE_TEXTURE_ALIASED_1x1, &layer_bounds) < 0) continue;
            const lw: i32 = layer_bounds.right - layer_bounds.left;
            const lh: i32 = layer_bounds.bottom - layer_bounds.top;
            if (lw <= 0 or lh <= 0) continue;
            const lwu: u32 = @intCast(lw);
            const lhu: u32 = @intCast(lh);
            if (lwu > 256 or lhu > 256) continue;
            const layer_size = lwu * lhu;
            if (layer_analysis.?.CreateAlphaTexture(
                dw.DWRITE_TEXTURE_ALIASED_1x1,
                &layer_bounds,
                self.ct_buf.ptr,
                layer_size,
            ) < 0) continue;

            // composite layer onto accumulator (premultiplied src-over).
            const offset_x: i32 = layer_bounds.left - bounds.left;
            const offset_y: i32 = layer_bounds.top - bounds.top;
            var ly: u32 = 0;
            while (ly < lhu) : (ly += 1) {
                const ay_i: i32 = @as(i32, @intCast(ly)) + offset_y;
                if (ay_i < 0 or ay_i >= @as(i32, @intCast(h))) continue;
                const ay: u32 = @intCast(ay_i);
                var lx: u32 = 0;
                while (lx < lwu) : (lx += 1) {
                    const ax_i: i32 = @as(i32, @intCast(lx)) + offset_x;
                    if (ax_i < 0 or ax_i >= @as(i32, @intCast(w))) continue;
                    const ax: u32 = @intCast(ax_i);
                    const layer_mask: f32 = @as(f32, @floatFromInt(self.ct_buf[ly * lwu + lx])) / 255.0;
                    if (layer_mask == 0) continue;
                    const eff_a: f32 = layer_mask * la;
                    if (eff_a <= 0) continue;
                    // Premultiplied src.
                    const src_r = lr * eff_a;
                    const src_g = lg * eff_a;
                    const src_b = lb * eff_a;
                    const src_a = eff_a;
                    const acc_off = (ay * w + ax) * 4;
                    const dst_r: f32 = @as(f32, @floatFromInt(self.temp_buf[acc_off + 0])) / 255.0;
                    const dst_g: f32 = @as(f32, @floatFromInt(self.temp_buf[acc_off + 1])) / 255.0;
                    const dst_b: f32 = @as(f32, @floatFromInt(self.temp_buf[acc_off + 2])) / 255.0;
                    const dst_a: f32 = @as(f32, @floatFromInt(self.temp_buf[acc_off + 3])) / 255.0;
                    const inv_a = 1.0 - src_a;
                    const out_r = src_r + dst_r * inv_a;
                    const out_g = src_g + dst_g * inv_a;
                    const out_b = src_b + dst_b * inv_a;
                    const out_a = src_a + dst_a * inv_a;
                    self.temp_buf[acc_off + 0] = @intFromFloat(@min(out_r * 255.0, 255.0));
                    self.temp_buf[acc_off + 1] = @intFromFloat(@min(out_g * 255.0, 255.0));
                    self.temp_buf[acc_off + 2] = @intFromFloat(@min(out_b * 255.0, 255.0));
                    self.temp_buf[acc_off + 3] = @intFromFloat(@min(out_a * 255.0, 255.0));
                }
            }
        }

        // depremultiply: shader 가 atlas.rgb 를 색으로, atlas.a 를 alpha mask
        // 로 사용 (ClearType blend 의 SRC1_COLOR 에 atlas.aaa 전달). non-premult
        // RGB 가 필요.
        var py: u32 = 0;
        while (py < h) : (py += 1) {
            var px: u32 = 0;
            while (px < w) : (px += 1) {
                const off = (py * w + px) * 4;
                const a = self.temp_buf[off + 3];
                if (a > 0) {
                    const af: f32 = @as(f32, @floatFromInt(a)) / 255.0;
                    const inv = 1.0 / af;
                    self.temp_buf[off + 0] = @intFromFloat(@min(@as(f32, @floatFromInt(self.temp_buf[off + 0])) * inv, 255.0));
                    self.temp_buf[off + 1] = @intFromFloat(@min(@as(f32, @floatFromInt(self.temp_buf[off + 1])) * inv, 255.0));
                    self.temp_buf[off + 2] = @intFromFloat(@min(@as(f32, @floatFromInt(self.temp_buf[off + 2])) * inv, 255.0));
                }
            }
        }

        const pos = self.packGlyph(w, h) orelse {
            self.is_full = true;
            return null;
        };
        const rgba_pitch = w * 4;
        const box = d3d.D3D11_BOX{
            .left = pos[0],
            .top = pos[1],
            .right = pos[0] + w,
            .bottom = pos[1] + h,
        };
        self.d3d_ctx.UpdateSubresource(
            @ptrCast(self.texture),
            0,
            &box,
            @ptrCast(self.temp_buf.ptr),
            rgba_pitch,
            0,
        );

        return AtlasEntry{
            .x = @intCast(pos[0]),
            .y = @intCast(pos[1]),
            .w = @intCast(w),
            .h = @intCast(h),
            .bearing_x = @intCast(bounds.left),
            .bearing_y = @intCast(bounds.top),
            .is_color = true,
        };
    }

    /// Simple row-based packing. Returns (x, y) or null if full.
    fn packGlyph(self: *GlyphAtlas, w: u32, h: u32) ?[2]u32 {
        const pad = 1; // 1px padding between glyphs

        if (self.cursor_x + w + pad > ATLAS_SIZE) {
            // Move to next row
            self.cursor_x = 0;
            self.cursor_y += self.row_height + pad;
            self.row_height = 0;
        }

        if (self.cursor_y + h > ATLAS_SIZE) return null; // Atlas full

        const x = self.cursor_x;
        const y = self.cursor_y;
        self.cursor_x += w + pad;
        if (h > self.row_height) self.row_height = h;

        return .{ x, y };
    }
};
