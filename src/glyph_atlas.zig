// Glyph texture atlas — rasterizes glyphs via DirectWrite, caches in a 2D atlas.
// Two glyph rasterization paths share the same R8G8B8A8 atlas:
//   - Mono / ClearType: `DWRITE_TEXTURE_CLEARTYPE_3x1` 3 bytes/pixel (subpixel
//     R/G/B alpha). Atlas RGB = subpixel masks, A = 0xFF. Shader applies fg
//     color via dual-source ClearType blend.
//   - Color emoji (#134/#136): D3D11 backed D2D RT (per-glyph BGRA texture →
//     `IDXGISurface` → `CreateDxgiSurfaceRenderTarget`) 에 layer 별
//     `DrawGlyphRun` (GRAYSCALE antialias) + 2x super-sampling. staging texture
//     로 `CopyResource` → CPU `Map(READ)` → byte swap (B↔R) + 4-pixel block 평균
//     다운샘플 → atlas RGBA *premultiplied* 그대로 저장 (depremult 안 함).
//     shader 의 color path 가 atlas.rgba 를 SRC0 (premult), atlas.aaaa 를 SRC1
//     로 dual-source blend. Win Terminal `BackendD3D` 동등 path.

const std = @import("std");
const dw = @import("directwrite.zig");
const d3d = @import("d3d11.zig");
const d2d = @import("direct2d.zig");

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
    d3d_device: *d3d.ID3D11Device,
    d3d_ctx: *d3d.ID3D11DeviceContext,

    // Direct2D factory — D3D backed RT (per-glyph) 생성용. null 이면 mono path 만.
    d2d_factory: ?*d2d.ID2D1Factory = null,

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

        // D2D factory — per-glyph D3D11 backed RT 생성용 (#136 컬러 emoji
        // hardware antialias). 실패해도 init 자체는 성공 — color emoji 가 mono
        // path 로 떨어지면서 baseline (1-bit alpha) 결과만 보임.
        var d2d_factory: ?*d2d.ID2D1Factory = null;
        _ = d2d.D2D1CreateFactory(d2d.D2D1_FACTORY_TYPE_SINGLE_THREADED, &d2d.IID_ID2D1Factory, null, &d2d_factory);
        errdefer if (d2d_factory) |f| d2d.factoryRelease(f);

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
            .d3d_device = device,
            .d3d_ctx = ctx,
            .temp_buf = temp_buf,
            .ct_buf = ct_buf,
            .d2d_factory = d2d_factory,
        };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        if (self.d2d_factory) |f| d2d.factoryRelease(f);
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

    /// 컬러 emoji 글리프 라스터화 (#134/#136) — D3D11 backed D2D RT path.
    ///
    /// 흐름:
    ///   1) `IDWriteFactory2::TranslateColorGlyphRun` 으로 layer enumerator
    ///   2) Pass 1: layer 별 ALIASED bounds union → atlas size (w,h) 결정
    ///   3) per-glyph 임시 `ID3D11Texture2D` (BGRA, BIND_RENDER_TARGET) 생성
    ///   4) `IDXGISurface` QI → `D2D Factory.CreateDxgiSurfaceRenderTarget` —
    ///      Win Terminal 과 동일한 hardware antialias path
    ///   5) `BeginDraw` + `SetTextAntialiasMode(GRAYSCALE)` + `Clear(transparent)`
    ///      + layer 마다 `CreateSolidColorBrush(layer.runColor)` + `DrawGlyphRun`
    ///   6) `EndDraw` 후 staging tex 로 `CopyResource` + `Map(READ)` 픽셀 가져옴
    ///   7) BGRA premult → RGBA depremult byte swap into temp_buf →
    ///      atlas `UpdateSubresource`
    ///
    /// is_color=true 인 AtlasEntry 반환. 컬러 글리프 아닌 경우
    /// (`DWRITE_E_NOCOLOR`) 또는 D2D path 실패 시 null → caller 가 일반
    /// `rasterize` (mono ClearType) 로 fall-through.
    fn rasterizeColor(self: *GlyphAtlas, face: *dw.IDWriteFontFace, glyph_index: u16) ?AtlasEntry {
        // D2D factory + IDWriteFactory2 둘 다 있어야 컬러 path 가능.
        const d2d_fac = self.d2d_factory orelse return null;
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

        // 1px padding — D2D antialias 가 ALIASED bounds 약간 밖까지 그릴 수 있음.
        bounds.left -= 1;
        bounds.top -= 1;
        bounds.right += 1;
        bounds.bottom += 1;

        const gw: i32 = bounds.right - bounds.left;
        const gh: i32 = bounds.bottom - bounds.top;
        if (gw <= 0 or gh <= 0) return null;
        const w: u32 = @intCast(gw);
        const h: u32 = @intCast(gh);
        if (w > 256 or h > 256) return null;

        // 2x super-sampling — D2D RT 사이즈 (w*2, h*2), DPI 도 2배 → D2D 가
        // 글리프를 2배 device pixel 그리드에 그림. 이후 4 픽셀 (2×2 block) 평균
        // 으로 다운샘플 → atlas 의 native (w, h) 사이즈에 grayscale antialiased
        // 결과. 작은 cell (9×18) 에서 vector outline 가장자리의 거침을 효과적
        // 으로 부드럽게 함.
        const ss: u32 = 2; // super-sample factor
        const rt_w = w * ss;
        const rt_h = h * ss;

        var rt_tex: ?*d3d.ID3D11Texture2D = null;
        if (self.d3d_device.CreateTexture2D(&.{
            .Width = rt_w,
            .Height = rt_h,
            .Format = d3d.DXGI_FORMAT_B8G8R8A8_UNORM,
            .Usage = d3d.D3D11_USAGE_DEFAULT,
            .BindFlags = d3d.D3D11_BIND_RENDER_TARGET,
        }, null, &rt_tex) < 0 or rt_tex == null) return null;
        defer _ = rt_tex.?.Release();

        // IDXGISurface QI — D2D 가 backing 으로 사용할 표면.
        var dxgi_surf_ptr: ?*anyopaque = null;
        if (rt_tex.?.QueryInterface(&d3d.IID_IDXGISurface, &dxgi_surf_ptr) < 0 or dxgi_surf_ptr == null) return null;
        const dxgi_surf: *d3d.IDXGISurface = @ptrCast(@alignCast(dxgi_surf_ptr));
        defer _ = dxgi_surf.Release();

        // D2D RT — DPI = sys_dpi × ss. baseline DIP 좌표 (-bounds.left, -bounds.top)
        // 가 RT 의 device pixel (-bounds.left × ss, -bounds.top × ss) 위치 에 매핑
        // → 글리프 outline 이 RT 의 (0, 0) ~ (rt_w, rt_h) 에 ss 배 크기로 들어감.
        const sys_dpi: f32 = 96.0 * self.pixels_per_dip;
        const rt_dpi: f32 = sys_dpi * @as(f32, @floatFromInt(ss));
        const rt_props = d2d.D2D1_RENDER_TARGET_PROPERTIES{
            .type = d2d.D2D1_RENDER_TARGET_TYPE_DEFAULT,
            .pixelFormat = .{ .format = d2d.DXGI_FORMAT_B8G8R8A8_UNORM, .alphaMode = d2d.D2D1_ALPHA_MODE_PREMULTIPLIED },
            .dpiX = rt_dpi,
            .dpiY = rt_dpi,
            .usage = d2d.D2D1_RENDER_TARGET_USAGE_NONE,
            .minLevel = d2d.D2D1_FEATURE_LEVEL_DEFAULT,
        };
        var rt: ?*d2d.ID2D1RenderTarget = null;
        if (d2d.factoryCreateDxgiSurfaceRenderTarget(d2d_fac, @ptrCast(dxgi_surf), &rt_props, &rt) < 0 or rt == null) return null;
        defer d2d.renderTargetRelease(rt.?);

        d2d.renderTargetBeginDraw(rt.?);
        d2d.renderTargetSetTextAntialiasMode(rt.?, d2d.D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
        // Win Terminal 동등: D2D RT 에 우리 mono path 와 동일한 rendering params
        // (gamma=1.0, contrast=0, clearTypeLevel=0) 적용. 안 하면 D2D 가 system
        // default 사용 → antialias gradient 의 visual 결과 다름.
        d2d.renderTargetSetTextRenderingParams(rt.?, @ptrCast(self.rendering_params));
        const transparent = d2d.D2D1_COLOR_F{ .r = 0, .g = 0, .b = 0, .a = 0 };
        d2d.renderTargetClear(rt.?, &transparent);

        // baseline = (-bounds.left, -bounds.top) — 글리프 outline 이 RT 의
        // (0,0)..(w,h) 에 들어옴.
        const base_x: f32 = @as(f32, @floatFromInt(-bounds.left));
        const base_y: f32 = @as(f32, @floatFromInt(-bounds.top));

        // Pass 2: layer 별 DrawGlyphRun. enumerator 새로 열어서 iterate.
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
        ) >= 0 and enumerator != null) {
            defer _ = enumerator.?.Release();
            while (true) {
                var has_run: dw.BOOL = 0;
                if (enumerator.?.MoveNext(&has_run) < 0 or has_run == 0) break;
                var cr_ptr: ?*const dw.IDWriteColorGlyphRun = null;
                if (enumerator.?.GetCurrentRun(&cr_ptr) < 0) continue;
                const cr = cr_ptr orelse continue;

                // layer 색. NO_PALETTE 면 사용자 fg 사용해야 하지만 atlas cache
                // 는 fg-independent 라 흰색 대체 (대부분 emoji 는 모든 layer 에
                // palette 색 정의).
                const layer_color = d2d.D2D1_COLOR_F{
                    .r = if (cr.palette_index == dw.DWRITE_NO_PALETTE_INDEX) 1.0 else cr.run_color.r,
                    .g = if (cr.palette_index == dw.DWRITE_NO_PALETTE_INDEX) 1.0 else cr.run_color.g,
                    .b = if (cr.palette_index == dw.DWRITE_NO_PALETTE_INDEX) 1.0 else cr.run_color.b,
                    .a = if (cr.palette_index == dw.DWRITE_NO_PALETTE_INDEX) 1.0 else cr.run_color.a,
                };
                var brush: ?*d2d.ID2D1SolidColorBrush = null;
                if (d2d.renderTargetCreateSolidColorBrush(rt.?, &layer_color, &brush) < 0 or brush == null) continue;
                defer d2d.brushRelease(brush.?);

                const layer_baseline = d2d.D2D_POINT_2F{
                    .x = base_x + cr.baseline_origin_x,
                    .y = base_y + cr.baseline_origin_y,
                };
                d2d.renderTargetDrawGlyphRun(
                    rt.?,
                    layer_baseline,
                    @ptrCast(&cr.glyph_run),
                    d2d.brushAsBrush(brush.?),
                    dw.DWRITE_MEASURING_MODE_NATURAL,
                );
            }
        }

        if (d2d.renderTargetEndDraw(rt.?) < 0) return null;

        // staging texture (CPU read) — super-sample 사이즈 그대로 (rt_w × rt_h).
        var staging_tex: ?*d3d.ID3D11Texture2D = null;
        if (self.d3d_device.CreateTexture2D(&.{
            .Width = rt_w,
            .Height = rt_h,
            .Format = d3d.DXGI_FORMAT_B8G8R8A8_UNORM,
            .Usage = d3d.D3D11_USAGE_STAGING,
            .BindFlags = 0,
            .CPUAccessFlags = d3d.D3D11_CPU_ACCESS_READ,
        }, null, &staging_tex) < 0 or staging_tex == null) return null;
        defer _ = staging_tex.?.Release();

        self.d3d_ctx.CopyResource(@ptrCast(staging_tex.?), @ptrCast(rt_tex.?));

        var mapped: d3d.D3D11_MAPPED_SUBRESOURCE = .{};
        if (self.d3d_ctx.Map(@ptrCast(staging_tex.?), 0, d3d.D3D11_MAP_READ, 0, &mapped) < 0) return null;
        defer self.d3d_ctx.Unmap(@ptrCast(staging_tex.?), 0);

        const src_bytes: [*]const u8 = @ptrCast(mapped.pData orelse return null);
        const stride = mapped.RowPitch;

        // ss×ss block 평균 (premultiplied 공간) → byte swap (B↔R) 만 해서 atlas
        // RGBA **premultiplied 그대로** 저장. Win Terminal 동등: D2D 가 그린 premult
        // 픽셀을 atlas 에 보존, shader 가 atlas.rgba 를 SRC0 (premult) 로 사용 +
        // atlas.aaaa 를 SRC1 로. depremult 안 함.
        var py: u32 = 0;
        while (py < h) : (py += 1) {
            var px: u32 = 0;
            while (px < w) : (px += 1) {
                var sum_b: u32 = 0;
                var sum_g: u32 = 0;
                var sum_r: u32 = 0;
                var sum_a: u32 = 0;
                var dy: u32 = 0;
                while (dy < ss) : (dy += 1) {
                    const sy = py * ss + dy;
                    var dx: u32 = 0;
                    while (dx < ss) : (dx += 1) {
                        const sx = px * ss + dx;
                        const src_off: usize = sy * stride + sx * 4;
                        sum_b += src_bytes[src_off + 0];
                        sum_g += src_bytes[src_off + 1];
                        sum_r += src_bytes[src_off + 2];
                        sum_a += src_bytes[src_off + 3];
                    }
                }
                const n = ss * ss;
                const dst_off: usize = (py * w + px) * 4;
                self.temp_buf[dst_off + 0] = @intCast(sum_r / n); // R
                self.temp_buf[dst_off + 1] = @intCast(sum_g / n); // G
                self.temp_buf[dst_off + 2] = @intCast(sum_b / n); // B
                self.temp_buf[dst_off + 3] = @intCast(sum_a / n); // A
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
