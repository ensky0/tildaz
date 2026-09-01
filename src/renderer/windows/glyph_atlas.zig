// Glyph texture atlas — rasterizes glyphs via DirectWrite, caches in a 2D atlas.
// Two glyph rasterization paths share the same R8G8B8A8 atlas (`BIND_SHADER_RESOURCE`
// + `BIND_RENDER_TARGET`):
//   - Mono / ClearType: `DWRITE_TEXTURE_CLEARTYPE_3x1` 3 bytes/pixel (subpixel
//     R/G/B alpha) + `UpdateSubresource`. Atlas RGB = subpixel masks, A = 0xFF.
//     Shader applies fg color via dual-source ClearType blend. **cluster 도 여기로
//     온다 (#401)** — 결합 기호처럼 컬러 테이블 없는 폰트의 multi-glyph cluster 는
//     `CreateGlyphRunAnalysis(glyphCount=N)` 이 한 비트맵으로 합성한다.
//   - Color emoji (#134/#136/#137): atlas 자체에 D2D RT 만들어 (atlas init 시
//     1번, `IDXGISurface` QI → `CreateDxgiSurfaceRenderTarget`) layer 별
//     `DrawGlyphRun` (GRAYSCALE antialias + custom rendering params 일치). 매
//     글리프마다 `BeginDraw` + `PushAxisAlignedClip(packed_rect)` + `Clear` +
//     layer composite + `EndDraw`. atlas RGBA premult 그대로 D2D 가 직접 채움 —
//     CPU staging / depremult / byte swap 불필요. shader color path 가
//     atlas.rgba (premult) 를 SRC0, atlas.aaaa 를 SRC1 로 dual-source blend.
//     Win Terminal `BackendD3D` 동등 path.

const std = @import("std");
const dw = @import("../../font/windows/directwrite.zig");
const dwrite_font = @import("../../font/windows/font.zig");
const d3d = @import("d3d11.zig");
const d2d = @import("direct2d.zig");
const tab_icons = @import("../../tab_icons.zig");
const atlas_common = @import("../glyph_atlas_common.zig");

pub const ATLAS_SIZE: u32 = 2048;

/// cluster 하나가 가질 수 있는 글리프 수 — shaping 쪽 상한과 같은 값을 쓴다.
const MAX_CLUSTER_GLYPHS = dwrite_font.MAX_CLUSTER_GLYPHS;

// #282 G5 — AtlasEntry / GlyphKey / packing 은 macOS atlas 와 공통(라인 동일).
pub const AtlasEntry = atlas_common.AtlasEntry;
const GlyphKey = atlas_common.GlyphKey;

/// Multi-glyph cluster (#139) cache key — 정의와 근거는 `glyph_atlas_common.zig` 에 있다
/// (#529 에서 macOS 와 공용으로 올렸다).
const ClusterKey = atlas_common.ClusterKey;

fn hashIndices(indices: []const u16) u64 {
    var h: u64 = 0xcbf29ce484222325; // FNV-1a 64-bit offset basis
    for (indices) |idx| {
        h ^= @as(u64, idx);
        h *%= 0x100000001b3;
    }
    return h;
}

pub const GlyphAtlas = struct {
    alloc: std.mem.Allocator,
    cache: std.AutoHashMap(GlyphKey, AtlasEntry),
    cluster_cache: std.AutoHashMap(ClusterKey, AtlasEntry),

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
    /// Win Terminal 동등 — color emoji layer 마다 brush 새로 만들지 않고 atlas
    /// init 시 1번 흰색으로 만든 brush 를 SetColor 로 layer color 갱신해서 재사용.
    atlas_brush: ?*d2d.ID2D1SolidColorBrush = null,
    /// atlas D2D RT 의 ID2D1DeviceContext (D2D 1.1+) — SetUnitMode(PIXELS) +
    /// GetGlyphRunWorldBounds 사용. Win 7 SP1 미만에서 QI 실패 시 null,
    /// rasterizeColor 가 mono path 로 fallback.
    atlas_dc: ?*d2d.ID2D1DeviceContext = null,
    /// atlas DC 의 ID2D1DeviceContext4 (D2D 1.3+, Win 10 1607+) — bitmap emoji
    /// 글리프 (PNG/JPEG/TIFF/PREMULTIPLIED) 그리기 위한 DrawColorBitmapGlyphRun.
    atlas_dc4: ?*d2d.ID2D1DeviceContext4 = null,
    /// IDWriteFactory4 (DirectWrite 1.4+) — TranslateColorGlyphRun 의 신규
    /// overload (desiredGlyphImageFormats 인자) 로 PNG bitmap layer 도 받음.
    /// Apple Color Emoji 같은 PNG 폰트 지원에 필수. null 이면 fallback.
    dw_factory4: ?*dw.IDWriteFactory4 = null,

    // Temporary buffers for glyph rasterization (reused, heap-allocated)
    temp_buf: []u8, // RGBA output: 256*256*4 bytes
    ct_buf: []u8, // ClearType 3x1 input: 256*256*3 bytes

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
                    // sys_dpi 적용 — RT 가 device pixel 좌표를 정확히 해석.
                    const sys_dpi: f32 = 96.0 * pixels_per_dip;
                    d2d.renderTargetSetDpi(atlas_d2d_rt.?, sys_dpi, sys_dpi);
                }
            }
        }
        errdefer if (atlas_d2d_rt) |r| d2d.renderTargetRelease(r);
        errdefer if (atlas_dxgi) |s| {
            _ = s.Release();
        };

        // ID2D1DeviceContext QI (#137-3) — SetUnitMode(PIXELS) + GetGlyphRunWorldBounds.
        // Win 7 SP1 + Platform Update / Win 8+ 에서 모든 RT 가 DC 호환. atlas_dc
        // null 이면 rasterizeColor 가 fallback (이전 ALIASED bounds path).
        var atlas_dc: ?*d2d.ID2D1DeviceContext = null;
        if (atlas_d2d_rt) |rt| {
            var dc_ptr: ?*anyopaque = null;
            if (d2d.renderTargetQueryInterface(rt, &d2d.IID_ID2D1DeviceContext, &dc_ptr) >= 0 and dc_ptr != null) {
                atlas_dc = @ptrCast(@alignCast(dc_ptr));
                // PIXEL 모드 — 모든 좌표/사이즈가 device pixel. dpi 무관.
                d2d.deviceContextSetUnitMode(atlas_dc.?, d2d.D2D1_UNIT_MODE_PIXELS);
            }
        }
        errdefer if (atlas_dc) |c| d2d.deviceContextRelease(c);

        // ID2D1DeviceContext4 QI (#137-4) — Win 10 1607+ 에서 bitmap emoji 글리프
        // (PNG/SVG) 처리 위한 DrawColorBitmapGlyphRun. null 이면 outline path 만.
        var atlas_dc4: ?*d2d.ID2D1DeviceContext4 = null;
        if (atlas_dc) |dc| {
            var dc4_ptr: ?*anyopaque = null;
            const dc_as_rt: *d2d.ID2D1RenderTarget = @ptrCast(@alignCast(dc));
            if (d2d.renderTargetQueryInterface(dc_as_rt, &d2d.IID_ID2D1DeviceContext4, &dc4_ptr) >= 0 and dc4_ptr != null) {
                atlas_dc4 = @ptrCast(@alignCast(dc4_ptr));
            }
        }
        errdefer if (atlas_dc4) |c| d2d.deviceContext4Release(c);

        // IDWriteFactory4 QI (#137-4) — Factory2.TranslateColorGlyphRun 은
        // desiredGlyphImageFormats 인자 없어 PNG layer 안 받음. Factory4 신규
        // overload 로 모든 형식 (TRUETYPE | CFF | COLR | SVG | PNG | JPEG | TIFF |
        // PREMULTIPLIED) 명시 요청.
        var dw_factory4: ?*dw.IDWriteFactory4 = null;
        var f4_ptr: ?*anyopaque = null;
        if (dw_factory.QueryInterface(&dw.IID_IDWriteFactory4, &f4_ptr) >= 0 and f4_ptr != null) {
            dw_factory4 = @ptrCast(@alignCast(f4_ptr));
        }
        errdefer if (dw_factory4) |f| dw.factory4Release(f);

        // Reusable solid brush (#137-6) — atlas init 시 흰색으로 한 번 생성,
        // layer 마다 SetColor 만 호출해서 재사용. brush 매번 생성/release 비용
        // 제거. Win Terminal `_emojiBrush` (BackendD3D.cpp:892) 동등.
        var atlas_brush: ?*d2d.ID2D1SolidColorBrush = null;
        if (atlas_d2d_rt) |rt| {
            const white = d2d.D2D1_COLOR_F{ .r = 1, .g = 1, .b = 1, .a = 1 };
            _ = d2d.renderTargetCreateSolidColorBrush(rt, &white, &atlas_brush);
        }
        errdefer if (atlas_brush) |b| d2d.brushRelease(b);

        return .{
            .alloc = alloc,
            .cache = std.AutoHashMap(GlyphKey, AtlasEntry).init(alloc),
            .cluster_cache = std.AutoHashMap(ClusterKey, AtlasEntry).init(alloc),
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
            .atlas_brush = atlas_brush,
            .atlas_dc = atlas_dc,
            .atlas_dc4 = atlas_dc4,
            .dw_factory4 = dw_factory4,
        };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        if (self.atlas_brush) |b| d2d.brushRelease(b);
        if (self.atlas_dc4) |c| d2d.deviceContext4Release(c);
        if (self.atlas_dc) |c| d2d.deviceContextRelease(c);
        if (self.atlas_d2d_rt) |r| d2d.renderTargetRelease(r);
        if (self.atlas_dxgi_surface) |s| _ = s.Release();
        if (self.dw_factory4) |f| dw.factory4Release(f);
        if (self.d2d_factory) |f| d2d.factoryRelease(f);
        self.alloc.free(self.ct_buf);
        self.alloc.free(self.temp_buf);
        self.cache.deinit();
        self.cluster_cache.deinit();
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
        const key = GlyphKey{ .font_ptr = @intFromPtr(face), .index = glyph_index };
        if (self.cache.get(key)) |entry| return entry;

        const single_indices = [_]u16{glyph_index};
        const empty_advances = [_]dw.FLOAT{};
        const empty_offsets = [_]dw.DWRITE_GLYPH_OFFSET{};
        var entry = self.rasterizeColor(face, &single_indices, &empty_advances, &empty_offsets) orelse
            self.rasterize(face, &single_indices, &empty_advances, &empty_offsets) orelse return null;
        entry.advance = self.designAdvancePx(face, glyph_index);
        self.cache.put(key, entry) catch return null;
        return entry;
    }

    /// 글리프의 design advance → 물리 px (#299 — 셀 영역 가운데 정렬용).
    /// 실패 시 0 — caller 의 center 계산이 offset 없이 degrade.
    fn designAdvancePx(self: *GlyphAtlas, face: *dw.IDWriteFontFace, glyph_index: u16) f32 {
        var fm: dw.DWRITE_FONT_METRICS = undefined;
        face.GetMetrics(&fm);
        if (fm.designUnitsPerEm == 0) return 0;
        const idx = [1]dw.UINT16{glyph_index};
        var gm: [1]dw.DWRITE_GLYPH_METRICS = undefined;
        if (face.GetDesignGlyphMetrics(&idx, 1, &gm, .FALSE) < 0) return 0;
        return @as(f32, @floatFromInt(gm[0].advanceWidth)) /
            @as(f32, @floatFromInt(fm.designUnitsPerEm)) * self.font_em_size * self.pixels_per_dip;
    }

    /// Multi-glyph cluster (#139, ZWJ family · 결합 기호 등) atlas entry. GSUB 합성 안 된
    /// cluster 의 모든 glyph 를 한 번에 라스터, single composite atlas entry 로 cache.
    /// count=1 이면 single getOrInsert 로 redirect.
    ///
    /// **컬러 · mono 를 모두 시도한다 (#401).** 예전에는 컬러 경로 하나뿐이었고 근거는
    /// *"글자 cluster 는 single glyph 가 일반"* 이었는데, **결합 기호가 그 가정을 깬다** —
    /// `a`+`U+0305` 는 어느 폰트에서도 base + mark 2 글리프이고 그 폰트는 mono 다. 컬러
    /// 테이블이 없는 폰트에 `TranslateColorGlyphRun` 은 `DWRITE_E_NOCOLOR` 를 내므로
    /// 컬러 경로가 null 을 돌려주고, 그러면 `emitClusterInstance` 가 **셀을 통째로 건너뛰어
    /// base 까지 사라졌다.** 단일 글리프 경로 (`getOrInsert`) 에는 원래 있던 폴백을 여기에도 둔다.
    pub fn getOrInsertCluster(
        self: *GlyphAtlas,
        face: *dw.IDWriteFontFace,
        glyph_indices: []const u16,
        advances: []const dw.FLOAT,
        offsets: []const dw.DWRITE_GLYPH_OFFSET,
        /// #418 — cluster 의 결합 기호가 전부 관통 (overlay) 류인지. 폰트 층이 codepoint 로
        /// 판정해 넘긴다 (atlas 는 glyph index 만 받아서 스스로는 알 수 없다).
        overlay_marks: bool,
    ) ?AtlasEntry {
        if (glyph_indices.len == 0) return null;
        if (glyph_indices.len == 1) return self.getOrInsert(face, glyph_indices[0]);
        if (glyph_indices.len > MAX_CLUSTER_GLYPHS) return null;

        const key = ClusterKey{ .font_ptr = @intFromPtr(face), .indices_hash = hashIndices(glyph_indices) };
        if (self.cluster_cache.get(key)) |entry| return entry;

        // #415 · #418 — shaping 이 배치하지 못한 mark 를 base 위로 되돌린 offsets.
        var fixed_offsets: [MAX_CLUSTER_GLYPHS]dw.DWRITE_GLYPH_OFFSET = undefined;
        const placed_offsets = self.placeUnplacedMarks(face, glyph_indices, advances, offsets, overlay_marks, &fixed_offsets);

        var entry = self.rasterizeColor(face, glyph_indices, advances, placed_offsets) orelse
            self.rasterize(face, glyph_indices, advances, placed_offsets) orelse return null;
        // cluster advance = placements 합 (DIP) × DPI scale (#299).
        if (advances.len == glyph_indices.len) {
            var sum: f32 = 0;
            for (advances) |a| sum += a;
            entry.advance = sum * self.pixels_per_dip;
        }
        self.cluster_cache.put(key, entry) catch return null;
        return entry;
    }

    /// [#415](https://github.com/ensky0/tildaz/issues/415) — **shaping 이 배치를 포기한 mark 를
    /// base 잉크 중앙에 맞춘다.**
    ///
    /// ```
    /// 맞춘다  ⟺  i > 0  ∧  advance == 0  ∧  advanceOffset == 0  ∧  앞에 advance≠0 인 base 가 있다
    /// ```
    ///
    /// `advance == 0` 은 combining mark 라는 뜻이고, **`advanceOffset == 0` 이 "배치를 안 했다"
    /// 는 신호**다. 배치했다면 pen (= base 의 advance 뒤) 에서 base 위로 당기는 음수 offset 이
    /// 와야 한다. 0 이면 mark 가 base 오른쪽 advance 자리에 그대로 남는데, combining mark 가
    /// 거기 있는 것은 어떤 폰트에서도 옳지 않다. GPOS 는 있는데 *이 조합의 anchor 만* 없는
    /// 폰트에서 나며, 누락된 fallback 계층을 우리가 채우는 것이다.
    ///
    /// **맞출 자리는 잉크 중앙이지 원점이 아니다 (실측으로 갈랐다).** mark 글리프가 어디에
    /// 그려지도록 설계됐는지는 폰트마다 다르다.
    ///
    /// | 폰트 | mark 글리프 | 원점에 맞추면 |
    /// |---|---|---|
    /// | `Segoe UI Symbol` 의 `U+0305` | `lsb = -6.01` · `inkW = 12.01` — 원점이 곧 잉크 중앙 | 잉크 중앙이 0 — base 중앙 3.62 에서 왼쪽으로 밀린다 |
    /// | DejaVu Sans Mono 의 `U+0308` | `lsb = +3` · `inkW = 6` — 원점이 잉크 왼쪽 | 잉크 중앙이 6 — base 중앙 6 과 일치 |
    ///
    /// 그래서 "원점을 맞춘다" 는 **DejaVu 에서만 우연히 맞는 규칙**이고, 폰트에 무관하게 옳은
    /// 것은 잉크 중앙 정렬이다 — HarfBuzz 가 GPOS 없는 폰트에 적용하는 fallback mark
    /// positioning 과 같은 규칙이다 (`hb-ot-shape-fallback` 의 `position_mark`).
    ///
    /// **세로는 관통 (overlay) mark 만 맞춘다 (#418).** 위 · 아래 mark 의 세로 위치는 자기
    /// 디자인에 이미 들어 있어 건드리면 안 된다 (acute 를 글자 가운데로 내리면 틀린다). 반면
    /// **관통 mark 는 글자를 가로질러야** 하는데 그 높이는 GPOS 가 정하는 것이라, 배치가 없으면
    /// 폰트의 기본 높이에 남는다 — `Segoe UI` 의 `U+0336` 은 baseline 높이여서
    /// (`ink y = [-0.43, 0.45]`) `k` (`[0.00, 11.10]`) 의 맨 아래에 겹쳐 **화면에서 안 보였다.**
    /// 그래서 관통 mark 는 잉크 중앙을 base 잉크의 **세로 중앙**에도 맞춘다.
    ///
    /// 위 · 아래 · 관통을 가르는 것은 Unicode combining class 이고 HarfBuzz 의 fallback 도 같은
    /// 기준을 쓴다. 판정에 codepoint 가 필요해서 폰트 층이 `overlay_marks` 로 알려 준다.
    ///
    /// base 가 baseline 아래로 잉크를 갖는 경우 (Arabic `ب` 의 아래 점) 아래 mark 를 한 단 더
    /// 쌓는 것은 여전히 하지 않는다 — 그건 GPOS `mark` / `mkmk` 의 일이다
    /// ([#416](https://github.com/ensky0/tildaz/issues/416)).
    ///
    /// **advance 가 0 인 글리프 위에는 맞추지 않는다.** emoji ZWJ 의 stack 디자인 (`👨‍❤️‍👨` 은
    /// 세 글리프가 모두 같은 원점에 겹치고 마지막 것만 advance 를 가진다) 이 이 경우인데, 거기서
    /// 잉크 중앙을 맞추면 **폰트가 의도한 겹침이 어긋난다.** 진짜 base (advance ≠ 0) 가 앞에
    /// 있을 때만 보정한다.
    ///
    /// `DWRITE_GLYPH_OFFSET.advanceOffset` 은 pen 에 더해지는 값이라 (글리프 i 는
    /// `pen_i + off_i` 에 그려진다) 넣을 값이 `원하는 원점 − pen_i` 다.
    ///
    /// placements 가 없거나 metric 을 못 읽으면 입력을 그대로 돌려준다.
    fn placeUnplacedMarks(
        self: *GlyphAtlas,
        face: *dw.IDWriteFontFace,
        glyph_indices: []const u16,
        advances: []const dw.FLOAT,
        offsets: []const dw.DWRITE_GLYPH_OFFSET,
        overlay_marks: bool,
        out: *[MAX_CLUSTER_GLYPHS]dw.DWRITE_GLYPH_OFFSET,
    ) []const dw.DWRITE_GLYPH_OFFSET {
        const count = glyph_indices.len;
        if (advances.len != count or offsets.len != count or count > MAX_CLUSTER_GLYPHS) return offsets;

        // 보정 대상이 하나도 없으면 metric 을 읽지 않는다 (흔한 경우 — emoji · 배치된 mark).
        var needs_fix = false;
        for (1..count) |i| {
            if (advances[i] == 0 and offsets[i].advanceOffset == 0) needs_fix = true;
        }
        if (!needs_fix) return offsets;

        var fm: dw.DWRITE_FONT_METRICS = undefined;
        face.GetMetrics(&fm);
        if (fm.designUnitsPerEm == 0) return offsets;
        const to_dip = self.font_em_size / @as(f32, @floatFromInt(fm.designUnitsPerEm));

        var indices: [MAX_CLUSTER_GLYPHS]dw.UINT16 = undefined;
        for (glyph_indices, 0..) |gi, i| indices[i] = gi;
        var gm: [MAX_CLUSTER_GLYPHS]dw.DWRITE_GLYPH_METRICS = undefined;
        if (face.GetDesignGlyphMetrics(&indices, @intCast(count), &gm, .FALSE) < 0) return offsets;

        @memcpy(out[0..count], offsets);

        var pen: f32 = 0;
        var base_center: ?f32 = null; // 직전 base (advance ≠ 0) 잉크의 가로 중앙
        var base_center_y: f32 = 0; // 〃 세로 중앙 (baseline 기준, 위가 +)
        for (0..count) |i| {
            const lsb = @as(f32, @floatFromInt(gm[i].leftSideBearing)) * to_dip;
            const rsb = @as(f32, @floatFromInt(gm[i].rightSideBearing)) * to_dip;
            const design_adv = @as(f32, @floatFromInt(gm[i].advanceWidth)) * to_dip;
            const ink_center = lsb + (design_adv - lsb - rsb) / 2; // 자기 원점 기준

            // 세로 잉크 (baseline 기준, 위가 +). `verticalOriginY` 는 baseline 에서 글리프
            // 세로 원점까지의 거리이고 top/bottom side bearing 이 거기서 잉크까지의 여백이다.
            const vorg = @as(f32, @floatFromInt(gm[i].verticalOriginY)) * to_dip;
            const tsb = @as(f32, @floatFromInt(gm[i].topSideBearing)) * to_dip;
            const bsb = @as(f32, @floatFromInt(gm[i].bottomSideBearing)) * to_dip;
            const adv_h = @as(f32, @floatFromInt(gm[i].advanceHeight)) * to_dip;
            const ink_center_y = ((vorg - tsb) + (vorg - (adv_h - bsb))) / 2; // 자기 원점 기준

            if (i > 0 and advances[i] == 0 and offsets[i].advanceOffset == 0) {
                if (base_center) |bc| {
                    out[i].advanceOffset = (bc - ink_center) - pen;
                    // 관통 mark 만 세로도 맞춘다. 이미 세로 배치가 있으면 (`ascenderOffset != 0`)
                    // shaping 이 정한 것이므로 건드리지 않는다.
                    if (overlay_marks and offsets[i].ascenderOffset == 0) {
                        out[i].ascenderOffset = base_center_y - ink_center_y;
                    }
                }
            } else if (advances[i] != 0) {
                base_center = pen + offsets[i].advanceOffset + ink_center;
                base_center_y = offsets[i].ascenderOffset + ink_center_y;
            }
            pen += advances[i];
        }
        return out[0..count];
    }

    /// 탭바 컨트롤 아이콘 (`< > × +`) 을 `tab_icons` 로 rasterize 해 atlas 에
    /// 캐시 (#268). 폰트 글리프가 아니라 우리가 만든 알파 커버리지라 codepoint
    /// 대신 아이콘 enum 을 key 로 씀 (face=0 은 유효한 face 아님). mono glyph 와
    /// 같은 RGBA 경로 — 회색이라 R=G=B=coverage, A=0xFF (subpixel fringing 없음),
    /// `temp_buf` → `UpdateSubresource` 업로드. is_color=false 로 mono shader path.
    pub fn getOrInsertIcon(self: *GlyphAtlas, icon: tab_icons.Icon, size: u32, stroke_px: f32) ?AtlasEntry {
        const key = GlyphKey{ .font_ptr = 0, .index = @intFromEnum(icon) };
        if (self.cache.get(key)) |entry| return entry;
        if (size == 0 or size > tab_icons.MAX_SIZE) return null;

        var cov: [tab_icons.MAX_SIZE * tab_icons.MAX_SIZE]u8 = undefined;
        tab_icons.rasterize(icon, size, stroke_px, &cov);

        const rgba_pitch = size * 4;
        for (0..size) |row| {
            for (0..size) |col| {
                const a = cov[row * size + col];
                const off = row * rgba_pitch + col * 4;
                self.temp_buf[off + 0] = a; // R
                self.temp_buf[off + 1] = a; // G
                self.temp_buf[off + 2] = a; // B
                self.temp_buf[off + 3] = 0xFF; // A (mono glyph 경로와 동일)
            }
        }

        const pos = self.packGlyph(size, size) orelse {
            self.is_full = true;
            return null;
        };
        const box = d3d.D3D11_BOX{
            .left = pos[0],
            .top = pos[1],
            .right = pos[0] + size,
            .bottom = pos[1] + size,
        };
        self.d3d_ctx.UpdateSubresource(
            @ptrCast(self.texture),
            0,
            &box,
            @ptrCast(self.temp_buf.ptr),
            rgba_pitch,
            0,
        );

        const entry = AtlasEntry{
            .x = @intCast(pos[0]),
            .y = @intCast(pos[1]),
            .w = @intCast(size),
            .h = @intCast(size),
            .bearing_x = 0,
            .bearing_y = 0,
            .is_color = false,
        };
        self.cache.put(key, entry) catch return null;
        return entry;
    }

    /// Reset the atlas (clear cache and packing state). Call only after flushing all pending draws.
    pub fn reset(self: *GlyphAtlas) void {
        self.cache.clearRetainingCapacity();
        self.cluster_cache.clearRetainingCapacity();
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.row_height = 0;
        self.is_full = false;
    }

    /// Mono / ClearType 라스터. **글리프 여러 개를 한 비트맵에 합성한다 (#401)** — 결합 기호처럼
    /// 컬러 테이블이 없는 폰트의 cluster 가 여기로 온다.
    ///
    /// 합성을 우리가 하지 않는다는 점이 Linux · macOS 판과 다르다. `CreateGlyphRunAnalysis` 는
    /// 원래 `glyphCount` · `glyphAdvances` · `glyphOffsets` 를 받는 multi-glyph API 라, 지금까지
    /// `glyphCount = 1` · `glyphOffsets = null` 로 **좁게 부르고 있었을 뿐**이다. FreeType 이
    /// 글리프 하나씩만 굽기 때문에 비트맵을 직접 합성해야 했던 Linux
    /// ([`98eefc8`](https://github.com/ensky0/tildaz/commit/98eefc8)) 와 그 점이 갈린다.
    ///
    /// **스케일 규약이 `rasterizeColor` 와 다르다.** 저쪽은 atlas D2D RT 가 `SetUnitMode(PIXELS)`
    /// 라 `em_px = font_em_size × pixels_per_dip` 을 쓰고 placements 도 같은 비율로 곱한다 (#149).
    /// 여기는 `fontEmSize` 를 DIP 로 주고 `CreateGlyphRunAnalysis` 의 두 번째 인자로
    /// `pixels_per_dip` 을 넘겨 DWrite 가 변환하게 하므로, **advances · offsets 도 DIP 그대로**
    /// 넘긴다. 여기서 곱하면 고DPI 에서 cluster 간격이 어긋난다.
    ///
    /// `advances` · `offsets` 의 길이가 `glyph_indices` 와 다르면 placements 없이 그린다
    /// (단일 글리프 경로가 그렇게 부른다 — 동작은 예전과 같다).
    fn rasterize(
        self: *GlyphAtlas,
        face: *dw.IDWriteFontFace,
        glyph_indices: []const u16,
        in_advances: []const dw.FLOAT,
        in_offsets: []const dw.DWRITE_GLYPH_OFFSET,
    ) ?AtlasEntry {
        if (glyph_indices.len == 0 or glyph_indices.len > MAX_CLUSTER_GLYPHS) return null;

        var indices: [MAX_CLUSTER_GLYPHS]dw.UINT16 = undefined;
        var advances: [MAX_CLUSTER_GLYPHS]dw.FLOAT = undefined;
        var offsets: [MAX_CLUSTER_GLYPHS]dw.DWRITE_GLYPH_OFFSET = undefined;
        const has_placements = in_advances.len == glyph_indices.len and in_offsets.len == glyph_indices.len;
        for (glyph_indices, 0..) |gi, i| {
            indices[i] = gi;
            // placements 가 없으면 advance 0 — 단일 글리프는 pen 이 움직일 일이 없다.
            advances[i] = if (has_placements) in_advances[i] else 0;
            offsets[i] = if (has_placements) in_offsets[i] else .{ .advanceOffset = 0, .ascenderOffset = 0 };
        }

        const glyph_run = dw.DWRITE_GLYPH_RUN{
            .fontFace = face,
            .fontEmSize = self.font_em_size,
            .glyphCount = @intCast(glyph_indices.len),
            .glyphIndices = &indices,
            .glyphAdvances = &advances,
            .glyphOffsets = if (has_placements) &offsets else null,
            .isSideways = .FALSE,
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
    fn rasterizeColor(self: *GlyphAtlas, face: *dw.IDWriteFontFace, glyph_indices: []const u16, in_advances: []const dw.FLOAT, in_offsets: []const dw.DWRITE_GLYPH_OFFSET) ?AtlasEntry {
        // atlas RT + DC + DC4 + brush + Factory4 모두 있어야 컬러 path 가능.
        // Win 10 1607+ 라 모두 사용 가능.
        const atlas_rt = self.atlas_d2d_rt orelse return null;
        const atlas_dc = self.atlas_dc orelse return null;
        const atlas_dc4 = self.atlas_dc4 orelse return null;
        const brush = self.atlas_brush orelse return null;
        const factory4 = self.dw_factory4 orelse return null;
        if (glyph_indices.len == 0 or glyph_indices.len > MAX_CLUSTER_GLYPHS) return null;

        // multi-glyph cluster (#139) — ZWJ family 등 GSUB 가 합성 못 한 cluster 의
        // 모든 glyph 를 한 번에 D2D 에 전달. GetGlyphPlacements 로 받은 정확한
        // advances + offsets 을 사용해 emoji 가 visual family 로 결합되게 함.
        // single-glyph path 는 advances=0, offsets=null 으로 simple.
        var indices_buf: [MAX_CLUSTER_GLYPHS]dw.UINT16 = undefined;
        var advances_buf: [MAX_CLUSTER_GLYPHS]dw.FLOAT = undefined;
        var offsets_buf: [MAX_CLUSTER_GLYPHS]dw.DWRITE_GLYPH_OFFSET = undefined;
        const has_placements = in_advances.len == glyph_indices.len and in_offsets.len == glyph_indices.len;
        // GetGlyphPlacements (`dwrite_font.zig:509`) 가 em=`font_em_size` (DIP)
        // 기준으로 advances/offsets 을 반환. atlas D2D RT 는 PIXEL mode 라
        // fontEmSize 도 device pixel 로 (em_px = font_em_size * pixels_per_dip)
        // 해석. 따라서 placements 도 같은 비율로 스케일해야 spacing 이 일관 —
        // 스케일 안 하면 ZWJ family 등 cluster 가 좁게 압축 (DPI scale 비율로).
        const em_scale = self.pixels_per_dip;
        for (glyph_indices, 0..) |gi, i| {
            indices_buf[i] = gi;
            advances_buf[i] = if (has_placements) in_advances[i] * em_scale else 0;
            offsets_buf[i] = if (has_placements) .{
                .advanceOffset = in_offsets[i].advanceOffset * em_scale,
                .ascenderOffset = in_offsets[i].ascenderOffset * em_scale,
            } else .{ .advanceOffset = 0, .ascenderOffset = 0 };
        }
        const glyph_count: dw.UINT32 = @intCast(glyph_indices.len);
        const offsets_ptr: ?[*]const dw.DWRITE_GLYPH_OFFSET = if (has_placements) &offsets_buf else null;
        // atlas D2D RT 가 SetUnitMode(PIXELS) 라 fontEmSize 가 device pixel 단위로
        // 해석됨 (#149). DIP 값 그대로 넘기면 고DPI 환경에서 emoji 가 DPI scale
        // 만큼 작아짐 — 100% DPI 에서만 우연히 정합. mono path 는 CreateGlyphRunAnalysis
        // 의 두 번째 인자 pixels_per_dip 로 동등 처리.
        const em_px = self.font_em_size * self.pixels_per_dip;
        const glyph_run = dw.DWRITE_GLYPH_RUN{
            .fontFace = face,
            .fontEmSize = em_px,
            .glyphCount = glyph_count,
            .glyphIndices = &indices_buf,
            .glyphAdvances = &advances_buf,
            .glyphOffsets = offsets_ptr,
            .isSideways = .FALSE,
            .bidiLevel = 0,
        };

        // 컨테이너 글리프 (COLR/PNG 폰트의 main glyph) 는 outline 없을 수 있어
        // bounds 는 layer 들의 union. Factory4.TranslateColorGlyphRun 은
        // desiredGlyphImageFormats=ALL 로 PNG bitmap 도 layer 에 포함됨 (Apple
        // Color Emoji 같은 PNG 폰트 지원). enumerator 는 rewind 불가라 두 번 호출
        // (Pass 1: bounds, Pass 2: composite).

        // Pass 1: layer bounds union via GetGlyphRunWorldBounds (PIXEL unit + sys
        // DPI) — antialias gradient 포함된 정확 outline bounds.
        var fbounds = d2d.D2D1_RECT_F{ .left = 1.0e30, .top = 1.0e30, .right = -1.0e30, .bottom = -1.0e30 };
        {
            var enum1: ?*dw.IDWriteColorGlyphRunEnumerator1 = null;
            const tr1 = dw.factory4TranslateColorGlyphRun(
                factory4,
                0,
                0,
                &glyph_run,
                null,
                dw.DWRITE_GLYPH_IMAGE_FORMATS_ALL,
                dw.DWRITE_MEASURING_MODE_NATURAL,
                null,
                0,
                &enum1,
            );
            if (tr1 < 0 or enum1 == null) return null;
            defer _ = enum1.?.Release();
            while (true) {
                var has_run: dw.BOOL = .FALSE;
                if (enum1.?.MoveNext(&has_run) < 0 or !has_run.toBool()) break;
                var cr1_ptr: ?*const dw.IDWriteColorGlyphRun1 = null;
                if (enum1.?.GetCurrentRun1(&cr1_ptr) < 0) continue;
                const cr1 = cr1_ptr orelse continue;
                const baseline = d2d.D2D_POINT_2F{ .x = cr1.baseline_origin_x, .y = cr1.baseline_origin_y };
                var lb: d2d.D2D1_RECT_F = undefined;
                if (d2d.deviceContextGetGlyphRunWorldBounds(
                    atlas_dc,
                    baseline,
                    @ptrCast(&cr1.glyph_run),
                    cr1.measuring_mode,
                    &lb,
                ) < 0) continue;
                if (lb.right - lb.left <= 0 or lb.bottom - lb.top <= 0) continue;
                if (lb.left < fbounds.left) fbounds.left = lb.left;
                if (lb.top < fbounds.top) fbounds.top = lb.top;
                if (lb.right > fbounds.right) fbounds.right = lb.right;
                if (lb.bottom > fbounds.bottom) fbounds.bottom = lb.bottom;
            }
        }
        if (fbounds.right - fbounds.left <= 0 or fbounds.bottom - fbounds.top <= 0) return null;

        // Win Terminal 동등 (`lrintf` round-to-nearest) — floor/ceil 은 antialias
        // 마진을 양쪽으로 1px 씩 추가해서 글리프가 cell 외곽으로 빠질 위험. round
        // 가 outline 의 visual center 에 가장 가까운 정수.
        const bounds = dw.RECT{
            .left = @round(fbounds.left),
            .top = @round(fbounds.top),
            .right = @round(fbounds.right),
            .bottom = @round(fbounds.bottom),
        };

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

        // Pass 2: layer 별 dispatch — fmt 따라 DrawColorBitmapGlyphRun (PNG/JPEG/
        // TIFF/PREMULTIPLIED) 또는 DrawGlyphRun + brush (TRUETYPE/CFF/COLR/SVG).
        var enumerator: ?*dw.IDWriteColorGlyphRunEnumerator1 = null;
        if (dw.factory4TranslateColorGlyphRun(
            factory4,
            0,
            0,
            &glyph_run,
            null,
            dw.DWRITE_GLYPH_IMAGE_FORMATS_ALL,
            dw.DWRITE_MEASURING_MODE_NATURAL,
            null,
            0,
            &enumerator,
        ) >= 0 and enumerator != null) {
            defer _ = enumerator.?.Release();
            while (true) {
                var has_run: dw.BOOL = .FALSE;
                if (enumerator.?.MoveNext(&has_run) < 0 or !has_run.toBool()) break;
                var cr1_ptr: ?*const dw.IDWriteColorGlyphRun1 = null;
                if (enumerator.?.GetCurrentRun1(&cr1_ptr) < 0) continue;
                const cr1 = cr1_ptr orelse continue;

                const layer_baseline = d2d.D2D_POINT_2F{
                    .x = base_x + cr1.baseline_origin_x,
                    .y = base_y + cr1.baseline_origin_y,
                };

                const fmt = cr1.glyph_image_format;
                const is_bitmap = (fmt & (dw.DWRITE_GLYPH_IMAGE_FORMATS_PNG |
                    dw.DWRITE_GLYPH_IMAGE_FORMATS_JPEG |
                    dw.DWRITE_GLYPH_IMAGE_FORMATS_TIFF |
                    dw.DWRITE_GLYPH_IMAGE_FORMATS_PREMULTIPLIED_B8G8R8A8)) != 0;

                if (is_bitmap) {
                    // PNG/JPEG/TIFF/PREMULTIPLIED bitmap layer — D2D 가 자체
                    // 디코드 + 고품질 다운스케일. brush 불필요.
                    d2d.deviceContext4DrawColorBitmapGlyphRun(
                        atlas_dc4,
                        fmt,
                        layer_baseline,
                        @ptrCast(&cr1.glyph_run),
                        cr1.measuring_mode,
                        d2d.D2D1_COLOR_BITMAP_GLYPH_SNAP_OPTION_DEFAULT,
                    );
                } else {
                    // TRUETYPE/CFF/COLR/SVG — outline layer, brush 색으로 그림.
                    // (SVG 는 DrawSvgGlyphRun 이 정공이지만 Segoe UI Emoji 는
                    // COLR layer 만 라 SVG layer 거의 없음, 일단 brush 통일.)
                    const layer_color = d2d.D2D1_COLOR_F{
                        .r = if (cr1.palette_index == dw.DWRITE_NO_PALETTE_INDEX) 1.0 else cr1.run_color.r,
                        .g = if (cr1.palette_index == dw.DWRITE_NO_PALETTE_INDEX) 1.0 else cr1.run_color.g,
                        .b = if (cr1.palette_index == dw.DWRITE_NO_PALETTE_INDEX) 1.0 else cr1.run_color.b,
                        .a = if (cr1.palette_index == dw.DWRITE_NO_PALETTE_INDEX) 1.0 else cr1.run_color.a,
                    };
                    d2d.brushSetColor(brush, &layer_color);
                    d2d.renderTargetDrawGlyphRun(
                        atlas_rt,
                        layer_baseline,
                        @ptrCast(&cr1.glyph_run),
                        d2d.brushAsBrush(brush),
                        cr1.measuring_mode,
                    );
                }
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

    /// #282 G5 — 공통 row-based packing 에 위임.
    fn packGlyph(self: *GlyphAtlas, w: u32, h: u32) ?[2]u32 {
        return atlas_common.packRow(&self.cursor_x, &self.cursor_y, &self.row_height, ATLAS_SIZE, w, h);
    }
};
