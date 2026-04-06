// Glyph texture atlas — rasterizes glyphs via DirectWrite, caches in a 2D atlas.
// Uses DWRITE_TEXTURE_CLEARTYPE_3x1 for RGB subpixel data.
// The atlas texture is a D3D11 RGBA texture (R8G8B8A8_UNORM).

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

    // Temporary buffer for glyph rasterization (reused)
    temp_buf: []u8,

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

        // Allocate temp buffer for max glyph size (256x256 * 4 bytes RGBA)
        const temp_buf = try alloc.alloc(u8, 256 * 256 * 4);

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
        };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        self.alloc.free(self.temp_buf);
        self.cache.deinit();
        _ = self.srv.Release();
        _ = self.texture.Release();
        _ = self.rendering_params.Release();
    }

    /// Look up or rasterize a glyph. Returns null if rasterization fails.
    pub fn getOrInsert(self: *GlyphAtlas, face: *dw.IDWriteFontFace, glyph_index: u16) ?AtlasEntry {
        const key = GlyphKey{ .face = @intFromPtr(face), .index = glyph_index };
        if (self.cache.get(key)) |entry| return entry;

        // Rasterize
        const entry = self.rasterize(face, glyph_index) orelse return null;

        self.cache.put(key, entry) catch return null;
        return entry;
    }

    /// Reset the atlas (clear cache and packing state).
    pub fn reset(self: *GlyphAtlas) void {
        self.cache.clearRetainingCapacity();
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.row_height = 0;
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
        var ct_buf: [256 * 256 * 3]u8 = undefined;
        if (analysis.?.CreateAlphaTexture(
            dw.DWRITE_TEXTURE_CLEARTYPE_3x1,
            &bounds,
            &ct_buf,
            ct_size,
        ) < 0) return null;

        // Convert ClearType RGB (3bpp) → RGBA (4bpp) for the atlas texture
        const rgba_pitch = w * 4;
        for (0..h) |row| {
            for (0..w) |col| {
                const src_off = row * w * 3 + col * 3;
                const dst_off = row * rgba_pitch + col * 4;
                self.temp_buf[dst_off + 0] = ct_buf[src_off + 0]; // R
                self.temp_buf[dst_off + 1] = ct_buf[src_off + 1]; // G
                self.temp_buf[dst_off + 2] = ct_buf[src_off + 2]; // B
                self.temp_buf[dst_off + 3] = 0xFF; // A (opaque)
            }
        }

        // Pack into atlas
        const pos = self.packGlyph(w, h) orelse blk: {
            // Atlas full — reset and retry
            self.reset();
            break :blk self.packGlyph(w, h) orelse return null;
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
