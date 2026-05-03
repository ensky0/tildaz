// Glyph texture atlas — rasterizes glyphs via DirectWrite, caches in a 2D atlas.
// Two glyph rasterization paths share the same R8G8B8A8 atlas (`BIND_SHADER_RESOURCE`
// + `BIND_RENDER_TARGET`):
//   - Mono / ClearType: `DWRITE_TEXTURE_CLEARTYPE_3x1` 3 bytes/pixel (subpixel
//     R/G/B alpha) + `UpdateSubresource`. Atlas RGB = subpixel masks, A = 0xFF.
//     Shader applies fg color via dual-source ClearType blend.
//   - Color emoji (#134/#136/#137): atlas 자체에 D2D RT 만들어 (atlas init 시
//     1번, `IDXGISurface` QI → `CreateDxgiSurfaceRenderTarget`) layer 별
//     `DrawGlyphRun` (GRAYSCALE antialias + custom rendering params 일치). 매
//     글리프마다 `BeginDraw` + `PushAxisAlignedClip(packed_rect)` + `Clear` +
//     layer composite + `EndDraw`. atlas RGBA premult 그대로 D2D 가 직접 채움 —
//     CPU staging / depremult / byte swap 불필요. shader color path 가
//     atlas.rgba (premult) 를 SRC0, atlas.aaaa 를 SRC1 로 dual-source blend.
//     Win Terminal `BackendD3D` 동등 path.

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

    // Direct2D — atlas 자체에 D2D RT 만들어서 glyph 영역에 직접 그림 (Win
    // Terminal `BackendD3D` 동등). per-glyph staging texture + CopyResource
    // 폐기. byte swap 도 자동 — atlas RGBA + D2D RT RGBA. atlas init 시 1번
    // 생성, deinit 시 release. 둘 중 하나라도 null 이면 color emoji path
    // disable, mono fallback.
    d2d_factory: ?*d2d.ID2D1Factory = null,
    atlas_dxgi_surface: ?*d3d.IDXGISurface = null,
    atlas_d2d_rt: ?*d2d.ID2D1RenderTarget = null,

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

        // Create atlas texture — BIND_SHADER_RESOURCE (shader sample) +
        // BIND_RENDER_TARGET (D2D 가 atlas 의 packed 위치에 직접 그림).
        // USAGE_DEFAULT 라 mono path 의 UpdateSubresource 도 그대로 동작.
        var tex: ?*d3d.ID3D11Texture2D = null;
        if (device.CreateTexture2D(&.{
            .Width = ATLAS_SIZE,
            .Height = ATLAS_SIZE,
            .Format = d3d.DXGI_FORMAT_R8G8B8A8_UNORM,
            .BindFlags = d3d.D3D11_BIND_SHADER_RESOURCE | d3d.D3D11_BIND_RENDER_TARGET,
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

        // D2D factory + atlas D2D RT 한 번 생성. per-glyph staging 폐기 — atlas
        // 자체에 D2D RT 만들고 layer 마다 PushAxisAlignedClip + DrawGlyphRun 으로
        // packed 위치에 직접 그림. atlas RGBA + D2D RT RGBA 같은 format 이라
        // byte swap 자동 해결. 실패해도 init 성공 — d2d_factory==null 이면
        // color emoji path disable, mono fallback.
        var d2d_factory: ?*d2d.ID2D1Factory = null;
        _ = d2d.D2D1CreateFactory(d2d.D2D1_FACTORY_TYPE_SINGLE_THREADED, &d2d.IID_ID2D1Factory, null, &d2d_factory);
        errdefer if (d2d_factory) |f| d2d.factoryRelease(f);

        var atlas_dxgi: ?*d3d.IDXGISurface = null;
        var atlas_d2d_rt: ?*d2d.ID2D1RenderTarget = null;
        if (d2d_factory) |fac| {
            var dxgi_ptr: ?*anyopaque = null;
            if (tex.?.QueryInterface(&d3d.IID_IDXGISurface, &dxgi_ptr) >= 0 and dxgi_ptr != null) {
                atlas_dxgi = @ptrCast(@alignCast(dxgi_ptr));
                // atlas D2D RT — RGBA format (atlas 와 동일) + PREMULTIPLIED.
                // dpi=96 으로 두면 1 DIP = 1 device pixel — bounds (device px)
                // 좌표를 그대로 baseline DIP 로 줘도 일치 (high DPI 정밀도는
                // 별도 작업 — SetUnitMode(PIXELS) 도입 시).
                const rt_props = d2d.D2D1_RENDER_TARGET_PROPERTIES{
                    .type = d2d.D2D1_RENDER_TARGET_TYPE_DEFAULT,
                    .pixelFormat = .{ .format = d2d.DXGI_FORMAT_B8G8R8A8_UNORM, .alphaMode = d2d.D2D1_ALPHA_MODE_PREMULTIPLIED },
                    .dpiX = 96.0,
                    .dpiY = 96.0,
                    .usage = d2d.D2D1_RENDER_TARGET_USAGE_NONE,
                    .minLevel = d2d.D2D1_FEATURE_LEVEL_DEFAULT,
                };
                // RGBA atlas 에 BGRA RT 연결 — pixelFormat.format 은 R8G8B8A8 이어야
                // atlas 와 일치. 위 props 의 format 도 R8G8B8A8 으로 변경 필요.
                var props_rgba = rt_props;
                props_rgba.pixelFormat.format = d3d.DXGI_FORMAT_R8G8B8A8_UNORM;
                if (d2d.factoryCreateDxgiSurfaceRenderTarget(fac, @ptrCast(atlas_dxgi.?), &props_rgba, &atlas_d2d_rt) >= 0 and atlas_d2d_rt != null) {
                    // 한 번만 antialias mode + rendering params 설정 (BeginDraw
                    // 와 무관한 RT state).
                    d2d.renderTargetSetTextAntialiasMode(atlas_d2d_rt.?, d2d.D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
                    d2d.renderTargetSetTextRenderingParams(atlas_d2d_rt.?, @ptrCast(rp.?));
                }
            }
        }
        errdefer if (atlas_d2d_rt) |r| d2d.renderTargetRelease(r);
        errdefer if (atlas_dxgi) |s| {
            _ = s.Release();
        };

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
            .atlas_dxgi_surface = atlas_dxgi,
            .atlas_d2d_rt = atlas_d2d_rt,
        };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        if (self.atlas_d2d_rt) |r| d2d.renderTargetRelease(r);
        if (self.atlas_dxgi_surface) |s| _ = s.Release();
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

    /// 컬러 emoji 글리프 라스터화 (#134/#136/#137) — atlas direct draw path.
    ///
    /// 흐름 (Win Terminal `BackendD3D::_drawGlyph` 동등):
    ///   1) `IDWriteFactory2::TranslateColorGlyphRun` 으로 layer enumerator
    ///   2) Pass 1: layer 별 ALIASED bounds union → atlas size (w,h) 결정
    ///   3) `packGlyph` 으로 atlas 안 packed 위치 (pos.x, pos.y) 결정
    ///   4) atlas 자체에 만들어진 D2D RT (init 시 1번 생성) 의 `BeginDraw` +
    ///      `PushAxisAlignedClip(pos.x, pos.y, pos.x+w, pos.y+h)` 으로 영역
    ///      제한 → `Clear(transparent)` 으로 packed 영역만 초기화
    ///   5) layer 마다 `CreateSolidColorBrush(layer.runColor)` + `DrawGlyphRun`
    ///      (baseline = atlas 좌표계로 `(pos.x - bounds.left, pos.y - bounds.top)`)
    ///   6) `PopAxisAlignedClip` + `EndDraw` — D2D 가 atlas RGBA premult 픽셀을
    ///      직접 그림. CPU staging / depremult / byte swap 없음.
    ///
    /// shader color path 가 atlas.rgba (premult) 를 SRC0, atlas.aaaa 를 SRC1 로
    /// 사용 — 가장자리 antialias gradient 그대로.
    ///
    /// is_color=true 인 AtlasEntry 반환. 컬러 글리프 아닌 경우
    /// (`DWRITE_E_NOCOLOR`) 또는 D2D path 실패 시 null → caller 가 일반
    /// `rasterize` (mono ClearType) 로 fall-through.
    fn rasterizeColor(self: *GlyphAtlas, face: *dw.IDWriteFontFace, glyph_index: u16) ?AtlasEntry {
        // atlas D2D RT + IDWriteFactory2 둘 다 있어야 컬러 path 가능.
        const atlas_rt = self.atlas_d2d_rt orelse return null;
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

        const pos = self.packGlyph(w, h) orelse {
            self.is_full = true;
            return null;
        };

        // atlas D2D RT 의 packed 영역에 직접 그림. dpi=96 (init 시 설정) 라 1 DIP =
        // 1 device pixel — pos / bounds (device pixel) 좌표를 baseline 에 그대로
        // 사용. PushAxisAlignedClip 으로 영역 제한 → 다른 글리프 invade 방지.
        const fpos_x: f32 = @floatFromInt(pos[0]);
        const fpos_y: f32 = @floatFromInt(pos[1]);
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(h);
        const clip_rect = d2d.D2D1_RECT_F{
            .left = fpos_x,
            .top = fpos_y,
            .right = fpos_x + fw,
            .bottom = fpos_y + fh,
        };

        d2d.renderTargetBeginDraw(atlas_rt);
        d2d.renderTargetPushAxisAlignedClip(atlas_rt, &clip_rect, d2d.D2D1_ANTIALIAS_MODE_ALIASED);
        const transparent = d2d.D2D1_COLOR_F{ .r = 0, .g = 0, .b = 0, .a = 0 };
        d2d.renderTargetClear(atlas_rt, &transparent);

        // baseline (atlas 좌표) = (pos.x - bounds.left, pos.y - bounds.top) —
        // 글리프 outline 이 atlas 의 (pos.x, pos.y) ~ (pos.x+w, pos.y+h) 에 들어감.
        const base_x: f32 = fpos_x - @as(f32, @floatFromInt(bounds.left));
        const base_y: f32 = fpos_y - @as(f32, @floatFromInt(bounds.top));

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
                if (d2d.renderTargetCreateSolidColorBrush(atlas_rt, &layer_color, &brush) < 0 or brush == null) continue;
                defer d2d.brushRelease(brush.?);

                const layer_baseline = d2d.D2D_POINT_2F{
                    .x = base_x + cr.baseline_origin_x,
                    .y = base_y + cr.baseline_origin_y,
                };
                d2d.renderTargetDrawGlyphRun(
                    atlas_rt,
                    layer_baseline,
                    @ptrCast(&cr.glyph_run),
                    d2d.brushAsBrush(brush.?),
                    dw.DWRITE_MEASURING_MODE_NATURAL,
                );
            }
        }

        d2d.renderTargetPopAxisAlignedClip(atlas_rt);
        if (d2d.renderTargetEndDraw(atlas_rt) < 0) return null;

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
