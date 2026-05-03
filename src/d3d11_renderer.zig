// D3D11 terminal renderer with custom HLSL ClearType shader pipeline.
// Replaces D2D DrawGlyphRun with: DWrite glyph atlas + D3D11 instanced quads + dual-source ClearType blending.

const std = @import("std");
const ghostty = @import("ghostty-vt");
const d3d = @import("d3d11.zig");
const dw = @import("directwrite.zig");
const DWriteFontContext = @import("dwrite_font.zig").DWriteFontContext;
const ui_metrics = @import("ui_metrics.zig");
const GlyphAtlas = @import("glyph_atlas.zig").GlyphAtlas;
const ATLAS_SIZE = @import("glyph_atlas.zig").ATLAS_SIZE;
const perf = @import("perf.zig");
const tildaz_log = @import("tildaz_log.zig");
const display_width = @import("display_width.zig");

const WCHAR = u16;
const MAX_INSTANCES: u32 = 32768;
extern "user32" fn GetDpiForWindow(?*anyopaque) callconv(.c) c_uint;
extern "user32" fn GetWindowLongPtrW(?*anyopaque, c_int) callconv(.c) isize;
const GWL_EXSTYLE: c_int = -20;
const WS_EX_LAYERED: isize = 0x00080000;

// --- Instance data layouts ---

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

// Constant buffer (must be 16-byte aligned, multiple of 16 bytes)
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

// --- HLSL Shaders ---

const bg_shader_src =
    \\cbuffer CB : register(b0) { float4 sa; float4 p; };
    \\struct I { float2 pos: IPOS; float2 sz: ISZ; float4 col: ICOL; uint vid: SV_VertexID; };
    \\struct O { float4 pos: SV_POSITION; float4 col: COLOR; };
    \\O bg_vs(I i) { float2 c = float2(i.vid & 1, i.vid >> 1);
    \\  float2 px = (i.pos + c * i.sz) / sa.xy * 2.0 - 1.0;
    \\  O o; o.pos = float4(px.x, -px.y, 0, 1); o.col = i.col; return o; }
    \\float4 bg_ps(O i) : SV_Target { return i.col; }
;

const text_shader_src =
    \\cbuffer CB : register(b0) { float4 sa; float4 p; float4 gr; };
    \\Texture2D atlas : register(t0);
    \\SamplerState smp : register(s0);
    \\struct I { float2 pos: IPOS; float2 sz: ISZ; float2 uvp: IUVP; float2 uvs: IUVS;
    \\  float4 fg: IFG; uint vid: SV_VertexID; };
    \\struct O { float4 pos: SV_POSITION; float2 uv: TEXCOORD; float4 fg: COLOR; };
    \\struct P { float4 c0: SV_Target0; float4 c1: SV_Target1; };
    \\O text_vs(I i) { float2 c = float2(i.vid & 1, i.vid >> 1);
    \\  float2 px = (i.pos + c * i.sz) / sa.xy * 2.0 - 1.0;
    \\  O o; o.pos = float4(px.x, -px.y, 0, 1);
    \\  o.uv = (i.uvp + c * i.uvs) / sa.zw; o.fg = i.fg; return o; }
    \\float enh(float a, float k) { return a * (k + 1.0) / (a * k + 1.0); }
    \\float gammaCorr(float a, float f, float4 g) {
    \\  return a + a * (1.0 - a) * ((g.x * f + g.y) * a + (g.z * f + g.w)); }
    \\float lodAdj(float k, float3 c) {
    \\  return k * saturate(dot(c, float3(0.30, 0.59, 0.11) * -4.0) + 3.0); }
    \\P text_ps(O i) : SV_Target { float3 g = atlas.Sample(smp, i.uv).rgb;
    \\  float k = lodAdj(p.x, i.fg.rgb);
    \\  float3 ct = float3(enh(g.r, k), enh(g.g, k), enh(g.b, k));
    \\  ct = float3(gammaCorr(ct.r, i.fg.r, gr), gammaCorr(ct.g, i.fg.g, gr),
    \\              gammaCorr(ct.b, i.fg.b, gr));
    \\  P o; o.c0 = float4(i.fg.rgb * ct, 1); o.c1 = float4(1 - ct, 1); return o; }
;

// --- Renderer ---

pub const D3d11Renderer = struct {
    alloc: std.mem.Allocator,
    font: DWriteFontContext,
    atlas: GlyphAtlas,
    render_state: ghostty.RenderState = .empty,

    // D3D11 core
    device: *d3d.ID3D11Device,
    ctx: *d3d.ID3D11DeviceContext,
    swap_chain: *d3d.IDXGISwapChain,
    rtv: ?*d3d.ID3D11RenderTargetView = null,

    // Shaders
    bg_vs: *d3d.ID3D11VertexShader,
    bg_ps: *d3d.ID3D11PixelShader,
    bg_layout: *d3d.ID3D11InputLayout,
    text_vs: *d3d.ID3D11VertexShader,
    text_ps: *d3d.ID3D11PixelShader,
    text_layout: *d3d.ID3D11InputLayout,

    // State objects
    sampler: *d3d.ID3D11SamplerState,
    alpha_blend: *d3d.ID3D11BlendState,
    ct_blend: *d3d.ID3D11BlendState,

    // Buffers
    bg_buffer: *d3d.ID3D11Buffer,
    text_buffer: *d3d.ID3D11Buffer,
    cb: *d3d.ID3D11Buffer,

    // Default background
    default_bg: [3]f32,

    // ClearType tuning (from system settings)
    sys_enhanced_contrast: f32,
    gamma_ratios: [4]f32,

    // Viewport dimensions
    vp_width: u32 = 0,
    vp_height: u32 = 0,

    // Tab bar colors
    // 탭 색상은 `ui_metrics.zig` 의 cross-platform 상수 사용 (macOS 와 같은 값).
    // 모두 회색 (R == G == B) 이라 단일 채널 [0] 으로 단축 사용 가능.

    fn colorF(v: u8) f32 {
        return @as(f32, @floatFromInt(v)) / 255.0;
    }

    fn isLayeredWindow(hwnd: ?*anyopaque) bool {
        const handle = hwnd orelse return false;
        return (GetWindowLongPtrW(handle, GWL_EXSTYLE) & WS_EX_LAYERED) != 0;
    }

    fn swapEffectName(swap_effect: u32) []const u8 {
        return switch (swap_effect) {
            d3d.DXGI_SWAP_EFFECT_FLIP_DISCARD => "flip_discard",
            d3d.DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL => "flip_sequential",
            d3d.DXGI_SWAP_EFFECT_DISCARD => "discard",
            else => "unknown",
        };
    }

    pub fn init(alloc: std.mem.Allocator, hwnd: ?*anyopaque, font_chain: []const [*:0]const u16, font_height: c_int, cell_w: u32, cell_h: u32, bg_rgb: ?[3]u8) !D3d11Renderer {
        const bg = bg_rgb orelse [3]u8{ 30, 30, 30 };

        // 1. Create D3D11 device + swap chain
        var sc_desc = d3d.DXGI_SWAP_CHAIN_DESC{
            .BufferDesc = .{ .Format = d3d.DXGI_FORMAT_B8G8R8A8_UNORM },
            .SampleDesc = .{ .Count = 1 },
            .BufferUsage = d3d.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .OutputWindow = hwnd,
            .Windowed = 1,
        };
        var device: ?*d3d.ID3D11Device = null;
        var ctx: ?*d3d.ID3D11DeviceContext = null;
        var swap_chain: ?*d3d.IDXGISwapChain = null;
        const layered_window = isLayeredWindow(hwnd);
        const layered_swap_effects = [_]u32{d3d.DXGI_SWAP_EFFECT_DISCARD};
        const standard_swap_effects = [_]u32{
            d3d.DXGI_SWAP_EFFECT_FLIP_DISCARD,
            d3d.DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
            d3d.DXGI_SWAP_EFFECT_DISCARD,
        };
        const swap_effects: []const u32 = if (layered_window) &layered_swap_effects else &standard_swap_effects;
        var create_hr: d3d.HRESULT = -1;
        var selected_swap_effect: u32 = d3d.DXGI_SWAP_EFFECT_DISCARD;
        for (swap_effects) |swap_effect| {
            sc_desc.BufferCount = if (swap_effect == d3d.DXGI_SWAP_EFFECT_DISCARD) 1 else 2;
            sc_desc.SwapEffect = swap_effect;
            create_hr = d3d.D3D11CreateDeviceAndSwapChain(
                null,
                d3d.D3D_DRIVER_TYPE_HARDWARE,
                null,
                0,
                null,
                0,
                d3d.D3D11_SDK_VERSION,
                &sc_desc,
                &swap_chain,
                &device,
                null,
                &ctx,
            );
            if (create_hr >= 0) {
                selected_swap_effect = swap_effect;
                break;
            }
            if (ctx) |c| {
                _ = c.Release();
                ctx = null;
            }
            if (swap_chain) |sc| {
                _ = sc.Release();
                swap_chain = null;
            }
            if (device) |dev| {
                _ = dev.Release();
                device = null;
            }
        }
        if (create_hr < 0) {
            tildaz_log.appendLine("d3d", "swap chain create failed: layered={} hr=0x{x}", .{
                layered_window,
                @as(u32, @bitCast(create_hr)),
            });
            return error.D3D11CreateFailed;
        }
        tildaz_log.appendLine("d3d", "swap chain created: layered={} effect={s} buffers={d}", .{
            layered_window,
            swapEffectName(selected_swap_effect),
            sc_desc.BufferCount,
        });
        errdefer {
            _ = ctx.?.Release();
            _ = swap_chain.?.Release();
            _ = device.?.Release();
        }

        // 2. Init font context
        var font_ctx = try DWriteFontContext.init(alloc, font_chain, font_height, cell_w, cell_h);
        errdefer font_ctx.deinit();

        // 3. Init glyph atlas (with DPI-aware pixelsPerDip)
        const dpi = GetDpiForWindow(hwnd);
        const pixels_per_dip: f32 = if (dpi > 0) @as(f32, @floatFromInt(dpi)) / 96.0 else 1.0;
        // Scale ascent_px to match actual rendered glyph pixels (font_em_size is unscaled,
        // but CreateGlyphRunAnalysis renders at font_em_size * pixels_per_dip)
        font_ctx.ascent_px *= pixels_per_dip;
        var atlas = try GlyphAtlas.init(alloc, font_ctx.factory, font_ctx.font_em_size, pixels_per_dip, device.?, ctx.?);
        errdefer atlas.deinit();

        // 4. Compile shaders
        const bg_vs_blob = try compileShader(bg_shader_src, "bg_vs", "vs_4_0");
        defer _ = bg_vs_blob.Release();
        const bg_ps_blob = try compileShader(bg_shader_src, "bg_ps", "ps_4_0");
        defer _ = bg_ps_blob.Release();
        const text_vs_blob = try compileShader(text_shader_src, "text_vs", "vs_4_0");
        defer _ = text_vs_blob.Release();
        const text_ps_blob = try compileShader(text_shader_src, "text_ps", "ps_4_0");
        defer _ = text_ps_blob.Release();

        // 5. Create shader objects
        var bg_vs: ?*d3d.ID3D11VertexShader = null;
        if (device.?.CreateVertexShader(bg_vs_blob.GetBufferPointer(), bg_vs_blob.GetBufferSize(), null, &bg_vs) < 0) return error.ShaderFailed;
        errdefer _ = bg_vs.?.Release();

        var bg_ps: ?*d3d.ID3D11PixelShader = null;
        if (device.?.CreatePixelShader(bg_ps_blob.GetBufferPointer(), bg_ps_blob.GetBufferSize(), null, &bg_ps) < 0) return error.ShaderFailed;
        errdefer _ = bg_ps.?.Release();

        var text_vs: ?*d3d.ID3D11VertexShader = null;
        if (device.?.CreateVertexShader(text_vs_blob.GetBufferPointer(), text_vs_blob.GetBufferSize(), null, &text_vs) < 0) return error.ShaderFailed;
        errdefer _ = text_vs.?.Release();

        var text_ps: ?*d3d.ID3D11PixelShader = null;
        if (device.?.CreatePixelShader(text_ps_blob.GetBufferPointer(), text_ps_blob.GetBufferSize(), null, &text_ps) < 0) return error.ShaderFailed;
        errdefer _ = text_ps.?.Release();

        // 6. Input layouts
        const bg_elems = [_]d3d.D3D11_INPUT_ELEMENT_DESC{
            .{ .SemanticName = "IPOS", .SemanticIndex = 0, .Format = d3d.DXGI_FORMAT_R32G32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 0, .InputSlotClass = d3d.D3D11_INPUT_PER_INSTANCE_DATA, .InstanceDataStepRate = 1 },
            .{ .SemanticName = "ISZ", .SemanticIndex = 0, .Format = d3d.DXGI_FORMAT_R32G32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 8, .InputSlotClass = d3d.D3D11_INPUT_PER_INSTANCE_DATA, .InstanceDataStepRate = 1 },
            .{ .SemanticName = "ICOL", .SemanticIndex = 0, .Format = d3d.DXGI_FORMAT_R32G32B32A32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 16, .InputSlotClass = d3d.D3D11_INPUT_PER_INSTANCE_DATA, .InstanceDataStepRate = 1 },
        };
        var bg_layout: ?*d3d.ID3D11InputLayout = null;
        if (device.?.CreateInputLayout(&bg_elems, bg_elems.len, bg_vs_blob.GetBufferPointer(), bg_vs_blob.GetBufferSize(), &bg_layout) < 0) return error.LayoutFailed;
        errdefer _ = bg_layout.?.Release();

        const text_elems = [_]d3d.D3D11_INPUT_ELEMENT_DESC{
            .{ .SemanticName = "IPOS", .SemanticIndex = 0, .Format = d3d.DXGI_FORMAT_R32G32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 0, .InputSlotClass = d3d.D3D11_INPUT_PER_INSTANCE_DATA, .InstanceDataStepRate = 1 },
            .{ .SemanticName = "ISZ", .SemanticIndex = 0, .Format = d3d.DXGI_FORMAT_R32G32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 8, .InputSlotClass = d3d.D3D11_INPUT_PER_INSTANCE_DATA, .InstanceDataStepRate = 1 },
            .{ .SemanticName = "IUVP", .SemanticIndex = 0, .Format = d3d.DXGI_FORMAT_R32G32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 16, .InputSlotClass = d3d.D3D11_INPUT_PER_INSTANCE_DATA, .InstanceDataStepRate = 1 },
            .{ .SemanticName = "IUVS", .SemanticIndex = 0, .Format = d3d.DXGI_FORMAT_R32G32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 24, .InputSlotClass = d3d.D3D11_INPUT_PER_INSTANCE_DATA, .InstanceDataStepRate = 1 },
            .{ .SemanticName = "IFG", .SemanticIndex = 0, .Format = d3d.DXGI_FORMAT_R32G32B32A32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 32, .InputSlotClass = d3d.D3D11_INPUT_PER_INSTANCE_DATA, .InstanceDataStepRate = 1 },
        };
        var text_layout: ?*d3d.ID3D11InputLayout = null;
        if (device.?.CreateInputLayout(&text_elems, text_elems.len, text_vs_blob.GetBufferPointer(), text_vs_blob.GetBufferSize(), &text_layout) < 0) return error.LayoutFailed;
        errdefer _ = text_layout.?.Release();

        // 7. Sampler state (point filtering for pixel-perfect glyphs)
        var sampler: ?*d3d.ID3D11SamplerState = null;
        if (device.?.CreateSamplerState(&.{}, &sampler) < 0) return error.SamplerFailed;
        errdefer _ = sampler.?.Release();

        // 8. Blend states
        // Alpha blend for backgrounds (standard SrcAlpha)
        var alpha_desc = d3d.D3D11_BLEND_DESC{};
        alpha_desc.RenderTarget[0] = .{
            .BlendEnable = 1,
            .SrcBlend = d3d.D3D11_BLEND_SRC_ALPHA,
            .DestBlend = d3d.D3D11_BLEND_INV_SRC_ALPHA,
            .BlendOp = d3d.D3D11_BLEND_OP_ADD,
            .SrcBlendAlpha = d3d.D3D11_BLEND_ONE,
            .DestBlendAlpha = d3d.D3D11_BLEND_INV_SRC_ALPHA,
            .BlendOpAlpha = d3d.D3D11_BLEND_OP_ADD,
        };
        var alpha_blend: ?*d3d.ID3D11BlendState = null;
        if (device.?.CreateBlendState(&alpha_desc, &alpha_blend) < 0) return error.BlendFailed;
        errdefer _ = alpha_blend.?.Release();

        // ClearType dual-source blend: dest * src1 + src0
        var ct_desc = d3d.D3D11_BLEND_DESC{};
        ct_desc.RenderTarget[0] = .{
            .BlendEnable = 1,
            .SrcBlend = d3d.D3D11_BLEND_ONE,
            .DestBlend = d3d.D3D11_BLEND_SRC1_COLOR,
            .BlendOp = d3d.D3D11_BLEND_OP_ADD,
            .SrcBlendAlpha = d3d.D3D11_BLEND_ONE,
            .DestBlendAlpha = d3d.D3D11_BLEND_ONE,
            .BlendOpAlpha = d3d.D3D11_BLEND_OP_ADD,
        };
        var ct_blend: ?*d3d.ID3D11BlendState = null;
        if (device.?.CreateBlendState(&ct_desc, &ct_blend) < 0) return error.BlendFailed;
        errdefer _ = ct_blend.?.Release();

        // 9. Instance buffers (dynamic, pre-allocated)
        var bg_buffer: ?*d3d.ID3D11Buffer = null;
        if (device.?.CreateBuffer(&.{
            .ByteWidth = MAX_INSTANCES * @sizeOf(BgInstance),
            .Usage = d3d.D3D11_USAGE_DYNAMIC,
            .BindFlags = d3d.D3D11_BIND_VERTEX_BUFFER,
            .CPUAccessFlags = d3d.D3D11_CPU_ACCESS_WRITE,
        }, null, &bg_buffer) < 0) return error.BufferFailed;
        errdefer _ = bg_buffer.?.Release();

        var text_buffer: ?*d3d.ID3D11Buffer = null;
        if (device.?.CreateBuffer(&.{
            .ByteWidth = MAX_INSTANCES * @sizeOf(TextInstance),
            .Usage = d3d.D3D11_USAGE_DYNAMIC,
            .BindFlags = d3d.D3D11_BIND_VERTEX_BUFFER,
            .CPUAccessFlags = d3d.D3D11_CPU_ACCESS_WRITE,
        }, null, &text_buffer) < 0) return error.BufferFailed;
        errdefer _ = text_buffer.?.Release();

        // 10. Constant buffer
        var cb: ?*d3d.ID3D11Buffer = null;
        if (device.?.CreateBuffer(&.{
            .ByteWidth = @sizeOf(Constants),
            .Usage = d3d.D3D11_USAGE_DYNAMIC,
            .BindFlags = d3d.D3D11_BIND_CONSTANT_BUFFER,
            .CPUAccessFlags = d3d.D3D11_CPU_ACCESS_WRITE,
        }, null, &cb) < 0) return error.BufferFailed;
        errdefer _ = cb.?.Release();

        // 11. Read system ClearType settings (gamma, enhanced contrast)
        var sys_enhanced_contrast: f32 = 0.5; // default
        var sys_gamma: f32 = 1.8; // default
        var default_rp: ?*dw.IDWriteRenderingParams = null;
        if (font_ctx.factory.CreateRenderingParams(&default_rp) >= 0) {
            sys_enhanced_contrast = default_rp.?.GetEnhancedContrast();
            sys_gamma = default_rp.?.GetGamma();
            _ = default_rp.?.Release();
        }
        const gamma_ratios = computeGammaRatios(sys_gamma);

        // 12. Create initial render target view
        var self = D3d11Renderer{
            .alloc = alloc,
            .font = font_ctx,
            .atlas = atlas,
            .device = device.?,
            .ctx = ctx.?,
            .swap_chain = swap_chain.?,
            .bg_vs = bg_vs.?,
            .bg_ps = bg_ps.?,
            .bg_layout = bg_layout.?,
            .text_vs = text_vs.?,
            .text_ps = text_ps.?,
            .text_layout = text_layout.?,
            .sampler = sampler.?,
            .alpha_blend = alpha_blend.?,
            .ct_blend = ct_blend.?,
            .bg_buffer = bg_buffer.?,
            .text_buffer = text_buffer.?,
            .cb = cb.?,
            .default_bg = .{ colorF(bg[0]), colorF(bg[1]), colorF(bg[2]) },
            .sys_enhanced_contrast = sys_enhanced_contrast,
            .gamma_ratios = gamma_ratios,
        };

        self.createRTV();

        // Set topology once (triangle strip for all draws)
        ctx.?.IASetPrimitiveTopology(d3d.D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);

        return self;
    }

    pub fn deinit(self: *D3d11Renderer) void {
        self.render_state.deinit(self.alloc);
        _ = self.cb.Release();
        _ = self.text_buffer.Release();
        _ = self.bg_buffer.Release();
        _ = self.ct_blend.Release();
        _ = self.alpha_blend.Release();
        _ = self.sampler.Release();
        _ = self.text_layout.Release();
        _ = self.text_ps.Release();
        _ = self.text_vs.Release();
        _ = self.bg_layout.Release();
        _ = self.bg_ps.Release();
        _ = self.bg_vs.Release();
        if (self.rtv) |r| _ = r.Release();
        self.atlas.deinit();
        self.font.deinit();
        _ = self.swap_chain.Release();
        _ = self.ctx.Release();
        _ = self.device.Release();
    }

    pub fn invalidate(self: *D3d11Renderer) void {
        self.render_state.rows = 0;
        self.render_state.cols = 0;
        self.render_state.viewport_pin = null;
    }

    /// Rebuild the DirectWrite font context + glyph atlas at the window's
    /// current DPI. Called after `window.rebuildFontForDpi` has updated
    /// `cell_w` / `cell_h`, so the atlas rasterizes glyphs at the new
    /// monitor's physical pixel density instead of the init-time DPI.
    ///
    /// On failure the renderer is left in a broken state (old resources
    /// already released, new ones not yet created). Callers treat any
    /// error as fatal.
    pub fn rebuildFont(
        self: *D3d11Renderer,
        hwnd: ?*anyopaque,
        font_chain: []const [*:0]const u16,
        font_height: c_int,
        cell_w: u32,
        cell_h: u32,
    ) !void {
        // Release old font + atlas first — the atlas texture is bound to
        // the init-time `pixels_per_dip` and the font metrics were scaled
        // for the init-time DPI, so neither can be reused.
        self.atlas.deinit();
        self.font.deinit();

        var font_ctx = try DWriteFontContext.init(self.alloc, font_chain, font_height, cell_w, cell_h);
        errdefer font_ctx.deinit();

        const dpi = GetDpiForWindow(hwnd);
        const pixels_per_dip: f32 = if (dpi > 0) @as(f32, @floatFromInt(dpi)) / 96.0 else 1.0;
        // Match the scaling done in `init` so glyphs positioned using
        // `ascent_px` line up with the DPI-scaled raster.
        font_ctx.ascent_px *= pixels_per_dip;

        const atlas = try GlyphAtlas.init(self.alloc, font_ctx.factory, font_ctx.font_em_size, pixels_per_dip, self.device, self.ctx);

        self.font = font_ctx;
        self.atlas = atlas;

        // Grid state was computed against the old cell metrics — force a
        // full redraw so every cell re-rasterizes through the new atlas.
        self.invalidate();
    }

    pub fn resize(self: *D3d11Renderer, width: u32, height: u32) void {
        if (self.rtv) |r| {
            _ = r.Release();
            self.rtv = null;
        }
        // Unbind render target before resize
        self.ctx.OMSetRenderTargets(0, null, null);
        _ = self.swap_chain.ResizeBuffers(0, width, height, 0, 0);
        self.createRTV();
        self.vp_width = width;
        self.vp_height = height;
    }

    fn createRTV(self: *D3d11Renderer) void {
        var back_buffer: ?*anyopaque = null;
        if (self.swap_chain.GetBuffer(0, &d3d.IID_ID3D11Texture2D, &back_buffer) >= 0) {
            if (back_buffer) |bb| {
                var rtv: ?*d3d.ID3D11RenderTargetView = null;
                if (self.device.CreateRenderTargetView(bb, null, &rtv) >= 0) {
                    self.rtv = rtv;
                }
                // Release the back buffer texture (RTV holds a ref)
                const tex: *d3d.ID3D11Texture2D = @ptrCast(@alignCast(bb));
                _ = tex.Release();
            }
        }
    }

    // === Tab bar rendering ===

    pub const TabTitle = struct { ptr: [*]const u8, len: usize };

    pub const RenameState = struct {
        tab_index: usize,
        text: [*]const u8,
        text_len: usize,
        cursor: usize,
    };

    /// 탭바 layout (#117 Firefox 패턴) — `<` `>` 화살표 + `+` 버튼이 탭 viewport
    /// 영역을 양쪽에서 깎음. App.tabBarLayout 와 동일 구조.
    pub const TabBarLayout = struct {
        tab_area_x: c_int,
        tab_area_w: c_int,
        arrows_visible: bool,
        arrow_w: c_int,
        plus_w: c_int,
        plus_x: c_int,
        left_arrow_x: c_int,
        right_arrow_x: c_int,
        left_enabled: bool,
        right_enabled: bool,
    };

    pub fn renderTabBar(
        self: *D3d11Renderer,
        tab_titles: []const TabTitle,
        active_tab: usize,
        tab_bar_height: c_int,
        client_w: c_int,
        client_h: c_int,
        tab_width: c_int,
        close_btn_size: c_int,
        tab_padding: c_int,
        dragged_tab: ?usize,
        /// world 좌표 (#117). 화면 좌표는 `drag_x - tab_scroll_x + tab_area_x`.
        drag_x: c_int,
        rename_state: ?RenameState,
        /// 탭바 스크롤 오프셋 (#117). 각 탭 / drag 탭의 화면 x = world - 이 값
        /// + tab_area_x 오프셋.
        tab_scroll_x: c_int,
        /// 화살표 / + 버튼 layout. arrows_visible == false 면 + 만 표시.
        layout: TabBarLayout,
    ) void {
        const tab_count = tab_titles.len;
        const rtv = self.rtv orelse return;

        // tab_bar_height == 0 면 탭바 자체를 그리지 않고 clear 만 하고 종료
        // (#127 — 단일 탭에서는 app_controller.effectiveTabBarHeight() 가 0).
        // clear 는 항상 필요 — renderTerminal 보다 먼저 불려서 default_bg 로
        // 채우는 역할.
        if (tab_bar_height <= 0) {
            self.setupFrame(rtv);
            const clear_color = [4]d3d.FLOAT{ self.default_bg[0], self.default_bg[1], self.default_bg[2], 1.0 };
            self.ctx.ClearRenderTargetView(rtv, &clear_color);
            return;
        }

        const tbh: f32 = @floatFromInt(tab_bar_height);
        const tw: f32 = @floatFromInt(tab_width);
        const cbs: f32 = @floatFromInt(close_btn_size);
        const pad: f32 = @floatFromInt(tab_padding);
        const cw: f32 = @floatFromInt(self.font.cell_width);
        const ch: f32 = @floatFromInt(self.font.cell_height);
        const w_f: f32 = @floatFromInt(client_w);

        // Ensure viewport dimensions are set
        if (self.vp_width == 0 or self.vp_height == 0) {
            self.vp_width = @intCast(@max(1, client_w));
            self.vp_height = @intCast(@max(1, client_h));
        }

        // Update viewport and constant buffer
        self.setupFrame(rtv);

        // Clear with default background
        const clear_color = [4]d3d.FLOAT{ self.default_bg[0], self.default_bg[1], self.default_bg[2], 1.0 };
        self.ctx.ClearRenderTargetView(rtv, &clear_color);

        // Build background instances for tab bar
        var bg_instances: [128]BgInstance = undefined;
        var bg_count: u32 = 0;

        // Tab bar background
        bg_instances[bg_count] = .{ .pos = .{ 0, 0 }, .size = .{ w_f, tbh }, .color = ui_metrics.TAB_BAR_BG };
        bg_count += 1;

        // #117 — 모든 탭 x = world(`i × tw` or drag world) - scroll + tab_area_x.
        // tab_area_x 는 화살표 있을 때 ARROW_W (좌측 화살표 자리), 없으면 0.
        const sx: f32 = @floatFromInt(tab_scroll_x);
        const tax: f32 = @floatFromInt(layout.tab_area_x);

        // Tab backgrounds
        for (0..tab_count) |i| {
            if (bg_count >= 128) break;
            const is_dragged = if (dragged_tab) |dt| (i == dt) else false;
            const tab_x: f32 = if (is_dragged)
                @as(f32, @floatFromInt(drag_x)) - tw / 2.0 - sx + tax
            else
                @as(f32, @floatFromInt(i)) * tw - sx + tax;
            const c = if (i == active_tab) ui_metrics.TAB_ACTIVE_BG[0] else self.default_bg[0];
            bg_instances[bg_count] = .{
                .pos = .{ tab_x + 1, 2 },
                .size = .{ tw - 2, tbh - 2 },
                .color = .{ c, c, c, 1 },
            };
            bg_count += 1;
        }

        // Draw backgrounds
        self.drawBgInstances(bg_instances[0..bg_count]);

        // Tab title text + close buttons via glyph atlas
        var text_instances: [512]TextInstance = undefined;
        var text_count: u32 = 0;

        var cursor_instances: [1]BgInstance = undefined;
        var cursor_count: u32 = 0;
        for (0..tab_count) |i| {
            const is_dragged = if (dragged_tab) |dt| (i == dt) else false;
            const tab_x: f32 = if (is_dragged)
                @as(f32, @floatFromInt(drag_x)) - tw / 2.0 - sx + tax
            else
                @as(f32, @floatFromInt(i)) * tw - sx + tax;

            const is_renaming = if (rename_state) |rs| (i == rs.tab_index) else false;
            const title = if (is_renaming) rename_state.?.text[0..rename_state.?.text_len] else tab_titles[i].ptr[0..tab_titles[i].len];
            const baseline_y2 = (tbh + self.font.ascent_px - (ch - self.font.ascent_px)) / 2.0;

            // Max text width: tab width - close button - padding on both sides - gap before close btn
            const max_text_w = tw - cbs - pad * 3;
            const ellipsis_w = cw * 3; // width of "..."
            // 탭 제목의 실제 시각 폭 — wide char (한글/CJK/Fullwidth/주요 emoji)
            // 는 셀 2 칸. byte length × cw 로 추정하면 ASCII / CJK 모두 어긋남.
            const total_text_w = @as(f32, @floatFromInt(display_width.stringWidth(title))) * cw;
            const needs_truncate = !is_renaming and (total_text_w > max_text_w);

            var x_off: f32 = 0;
            var byte_idx: usize = 0;
            var truncated = false;
            const rename_cursor_pos: ?usize = if (is_renaming) rename_state.?.cursor else null;
            var view = std.unicode.Utf8View.init(title) catch {
                // Invalid UTF-8 — skip this tab's text
                continue;
            };
            var cp_iter = view.iterator();
            while (cp_iter.nextCodepoint()) |codepoint| {
                if (text_count >= 510) break;
                const cp_len = std.unicode.utf8CodepointSequenceLength(codepoint) catch 1;
                const cp_w_cells: u8 = display_width.codepointWidth(codepoint);
                const advance: f32 = cw * @as(f32, @floatFromInt(cp_w_cells));
                // Truncate with "..." if text would overflow
                if (needs_truncate and x_off + advance > max_text_w - ellipsis_w) {
                    // Render "..."
                    for (0..3) |_| {
                        if (text_count >= 512) break;
                        const dot_result = self.font.resolveGlyph('.') orelse break;
                        const dot_entry = self.atlas.getOrInsert(dot_result.face, dot_result.index) orelse {
                            if (dot_result.owned) _ = dot_result.face.vtable.Release(dot_result.face);
                            break;
                        };
                        if (dot_result.owned) _ = dot_result.face.vtable.Release(dot_result.face);
                        if (dot_entry.w > 0 and dot_entry.h > 0) {
                            const gx = tab_x + pad + x_off + @as(f32, @floatFromInt(dot_entry.bearing_x));
                            const gy = baseline_y2 + @as(f32, @floatFromInt(dot_entry.bearing_y));
                            text_instances[text_count] = .{
                                .pos = .{ gx, gy },
                                .size = .{ @floatFromInt(dot_entry.w), @floatFromInt(dot_entry.h) },
                                .uv_pos = .{ @floatFromInt(dot_entry.x), @floatFromInt(dot_entry.y) },
                                .uv_size = .{ @floatFromInt(dot_entry.w), @floatFromInt(dot_entry.h) },
                                .fg_color = ui_metrics.TAB_TEXT_COLOR,
                            };
                            text_count += 1;
                        }
                        x_off += cw;
                    }
                    truncated = true;
                    break;
                }
                // Draw cursor before this character if cursor is at this byte position
                if (rename_cursor_pos) |cp| {
                    if (byte_idx == cp and cursor_count == 0) {
                        cursor_instances[0] = .{
                            .pos = .{ tab_x + pad + x_off, baseline_y2 - self.font.ascent_px + 2 },
                            .size = .{ 1, ch - 2 },
                            .color = ui_metrics.TAB_TEXT_COLOR,
                        };
                        cursor_count = 1;
                    }
                }
                byte_idx += cp_len;
                const result = self.font.resolveGlyph(codepoint) orelse {
                    x_off += advance;
                    continue;
                };
                const entry = self.atlas.getOrInsert(result.face, result.index) orelse {
                    if (result.owned) _ = result.face.vtable.Release(result.face);
                    x_off += advance;
                    continue;
                };
                if (result.owned) _ = result.face.vtable.Release(result.face);
                if (entry.w > 0 and entry.h > 0) {
                    const gx = tab_x + pad + x_off + @as(f32, @floatFromInt(entry.bearing_x));
                    const gy = baseline_y2 + @as(f32, @floatFromInt(entry.bearing_y));
                    text_instances[text_count] = .{
                        .pos = .{ gx, gy },
                        .size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                        .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
                        .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                        .fg_color = ui_metrics.TAB_TEXT_COLOR,
                    };
                    text_count += 1;
                }
                x_off += advance;
            }
            // Cursor at end of text (only if not truncated)
            if (!truncated) {
                if (rename_cursor_pos) |cp| {
                    if (cp >= title.len and cursor_count == 0) {
                        cursor_instances[0] = .{
                            .pos = .{ tab_x + pad + x_off, baseline_y2 - self.font.ascent_px + 2 },
                            .size = .{ 1, ch - 2 },
                            .color = ui_metrics.TAB_TEXT_COLOR,
                        };
                        cursor_count = 1;
                    }
                }
            }

            // Close button "x"
            if (text_count < 512) {
                const close_x = tab_x + tw - cbs - pad;
                const close_y = (tbh - cbs) / 2.0;
                const tab_bg_c = if (i == active_tab) ui_metrics.TAB_ACTIVE_BG[0] else self.default_bg[0];
                const close_c = ui_metrics.TAB_TEXT_COLOR[0] * 0.6 + tab_bg_c * 0.4;

                const result = self.font.resolveGlyph('x') orelse continue;
                const entry = self.atlas.getOrInsert(result.face, result.index) orelse {
                    if (result.owned) _ = result.face.vtable.Release(result.face);
                    continue;
                };
                if (result.owned) _ = result.face.vtable.Release(result.face);
                if (entry.w > 0 and entry.h > 0) {
                    const gx = close_x + (cbs - cw) / 2.0 + @as(f32, @floatFromInt(entry.bearing_x));
                    const close_baseline = close_y + (cbs + self.font.ascent_px - (ch - self.font.ascent_px)) / 2.0;
                    const gy = close_baseline + @as(f32, @floatFromInt(entry.bearing_y));
                    text_instances[text_count] = .{
                        .pos = .{ gx, gy },
                        .size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                        .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
                        .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                        .fg_color = .{ close_c, close_c, close_c, 1 },
                    };
                    text_count += 1;
                }
            }
        }

        if (text_count > 0) {
            self.drawTextInstances(text_instances[0..text_count]);
        }
        if (cursor_count > 0) {
            self.drawBgInstances(cursor_instances[0..cursor_count]);
        }

        // #117 — 화살표 / + 영역. 탭 BG / 텍스트 그린 *후* 별도 batch 로 그려야
        // viewport 끝의 탭이 화살표 영역에 침범한 픽셀이 가려짐 (사용자 제안:
        // 탭 너비 줄이는 효과). 색은 활성 (밝은 흰색) / 비활성 (어두운 회색)
        // 명확히 구분.
        var ctrl_bg_buf: [3]BgInstance = undefined;
        var ctrl_bg_n: u32 = 0;
        if (layout.arrows_visible) {
            ctrl_bg_buf[ctrl_bg_n] = .{
                .pos = .{ @floatFromInt(layout.left_arrow_x), 0 },
                .size = .{ @floatFromInt(layout.arrow_w), tbh },
                .color = ui_metrics.TAB_BAR_BG,
            };
            ctrl_bg_n += 1;
            ctrl_bg_buf[ctrl_bg_n] = .{
                .pos = .{ @floatFromInt(layout.right_arrow_x), 0 },
                .size = .{ @floatFromInt(layout.arrow_w), tbh },
                .color = ui_metrics.TAB_BAR_BG,
            };
            ctrl_bg_n += 1;
        }
        ctrl_bg_buf[ctrl_bg_n] = .{
            .pos = .{ @floatFromInt(layout.plus_x), 0 },
            .size = .{ @floatFromInt(layout.plus_w), tbh },
            .color = ui_metrics.TAB_BAR_BG,
        };
        ctrl_bg_n += 1;
        self.drawBgInstances(ctrl_bg_buf[0..ctrl_bg_n]);

        // 글리프 `<` `>` `+`. 박스 안에 cw × ch 글자 가운데 정렬. 활성 / 비활성
        // 색 분리.
        var ctrl_text_buf: [3]TextInstance = undefined;
        var ctrl_text_n: u32 = 0;
        const drawCtrlGlyph = struct {
            fn run(rself: *D3d11Renderer, codepoint: u21, box_x: c_int, box_w: c_int, tbh_: f32, cw_: f32, ch_: f32, color: [4]f32, buf: []TextInstance, n: *u32) void {
                if (n.* >= buf.len) return;
                const result = rself.font.resolveGlyph(codepoint) orelse return;
                const entry = rself.atlas.getOrInsert(result.face, result.index) orelse {
                    if (result.owned) _ = result.face.vtable.Release(result.face);
                    return;
                };
                if (result.owned) _ = result.face.vtable.Release(result.face);
                if (entry.w == 0 or entry.h == 0) return;
                const bx: f32 = @floatFromInt(box_x);
                const bw: f32 = @floatFromInt(box_w);
                const gx = bx + (bw - cw_) * 0.5 + @as(f32, @floatFromInt(entry.bearing_x));
                const baseline = (tbh_ + rself.font.ascent_px - (ch_ - rself.font.ascent_px)) * 0.5;
                const gy = baseline + @as(f32, @floatFromInt(entry.bearing_y));
                buf[n.*] = .{
                    .pos = .{ gx, gy },
                    .size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                    .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
                    .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                    .fg_color = color,
                };
                n.* += 1;
            }
        }.run;

        if (layout.arrows_visible) {
            const left_color = if (layout.left_enabled) ui_metrics.TAB_CTRL_ACTIVE_COLOR else ui_metrics.TAB_ARROW_DISABLED_COLOR;
            const right_color = if (layout.right_enabled) ui_metrics.TAB_CTRL_ACTIVE_COLOR else ui_metrics.TAB_ARROW_DISABLED_COLOR;
            drawCtrlGlyph(self, '<', layout.left_arrow_x, layout.arrow_w, tbh, cw, ch, left_color, &ctrl_text_buf, &ctrl_text_n);
            drawCtrlGlyph(self, '>', layout.right_arrow_x, layout.arrow_w, tbh, cw, ch, right_color, &ctrl_text_buf, &ctrl_text_n);
        }
        drawCtrlGlyph(self, '+', layout.plus_x, layout.plus_w, tbh, cw, ch, ui_metrics.TAB_CTRL_ACTIVE_COLOR, &ctrl_text_buf, &ctrl_text_n);
        if (ctrl_text_n > 0) self.drawTextInstances(ctrl_text_buf[0..ctrl_text_n]);

        // Don't present — renderTerminal will continue
    }

    // === Terminal rendering ===

    pub fn renderTerminal(
        self: *D3d11Renderer,
        terminal: *ghostty.Terminal,
        cell_w: c_int,
        cell_h: c_int,
        vp_w: c_int,
        vp_h: c_int,
        y_offset: c_int,
        padding: c_int,
        scrollbar_w: c_int,
        scrollbar_min_thumb_h: c_int,
    ) void {
        const render_t0 = perf.now();
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

        // Instance buffers — 4096 cells covers ~200x20 terminals (stack ~200KB each)
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
                    self.drawBgInstances(bg_buf[0..bg_count]);
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

        // Draw backgrounds
        if (bg_count > 0) {
            self.drawBgInstances(bg_buf[0..bg_count]);
        }

        // Reuse bg_buf for block elements (start from 0)
        var block_count: u32 = 0;

        // --- Text pass ---
        for (0..rows) |y| {
            if (y >= all_cells.len) break;
            const cell_slice = all_cells[y].slice();
            const raws = cell_slice.items(.raw);
            const styles = cell_slice.items(.style);
            const graphemes = cell_slice.items(.grapheme);
            const sel_range: ?[2]u16 = if (y < all_sels.len) all_sels[y] else null;

            const fy: f32 = @as(f32, @floatFromInt(y)) * ch + y_off;

            for (0..cols) |x| {
                if (x >= raws.len) break;
                const raw = raws[x];

                const is_text = raw.hasText() and raw.wide != .spacer_tail and raw.wide != .spacer_head and raw.codepoint() != 0;
                if (!is_text) continue;

                const cp = raw.codepoint();

                // Block elements: draw as colored rectangle
                if (isBlockElement(cp)) {
                    if (block_count >= MAX_CELLS) {
                        self.drawBgInstances(bg_buf[0..block_count]);
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
                    self.drawTextInstances(text_buf[0..text_count]);
                    text_count = 0;
                }

                // Resolve glyph. grapheme cluster (VS-16 / skin tone modifier
                // / ZWJ 시퀀스) 면 IDWriteTextAnalyzer.GetGlyphs 로 cluster 통째
                // shape — 단일 (컬러 emoji) 글리프로 reduce. 일반 cell 은 빠른
                // single-codepoint path 그대로. macOS resolveGrapheme 와 동등 패턴.
                const result = blk: {
                    if (raw.hasGrapheme() and x < graphemes.len) {
                        var cluster: [16]u21 = undefined;
                        cluster[0] = cp;
                        const extras = graphemes[x];
                        const take = @min(extras.len, cluster.len - 1);
                        @memcpy(cluster[1..][0..take], extras[0..take]);
                        if (self.font.resolveGrapheme(cluster[0 .. 1 + take])) |r| break :blk r;
                    }
                    break :blk self.font.resolveGlyph(cp) orelse continue;
                };
                var entry_opt = self.atlas.getOrInsert(result.face, result.index);

                // Atlas full: flush pending draws BEFORE reset so queued UV coords stay valid,
                // then reset and retry once.
                if (entry_opt == null and self.atlas.is_full) {
                    if (text_count > 0) {
                        self.drawTextInstances(text_buf[0..text_count]);
                        text_count = 0;
                    }
                    if (block_count > 0) {
                        self.drawBgInstances(bg_buf[0..block_count]);
                        block_count = 0;
                    }
                    self.atlas.reset();
                    entry_opt = self.atlas.getOrInsert(result.face, result.index);
                }

                const entry = entry_opt orelse {
                    if (result.owned) _ = result.face.vtable.Release(result.face);
                    continue;
                };
                if (result.owned) _ = result.face.vtable.Release(result.face);

                if (entry.w == 0 or entry.h == 0) continue; // empty glyph (space)

                const style = if (raw.style_id != 0) styles[x] else ghostty.Style{};
                const is_inverse = style.flags.inverse;
                const x16: u16 = @intCast(x);
                const is_selected = if (sel_range) |sr| (x16 >= sr[0] and x16 <= sr[1]) else false;
                const fg_rgb = resolveFg(style, &raw, &colors, is_selected, is_inverse);

                const fx: f32 = @as(f32, @floatFromInt(x)) * cw + x_pad;
                const gx = fx + @as(f32, @floatFromInt(entry.bearing_x));
                const gy = fy + self.font.ascent_px + @as(f32, @floatFromInt(entry.bearing_y));

                text_buf[text_count] = .{
                    .pos = .{ gx, gy },
                    .size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                    .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
                    .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                    .fg_color = .{ colorF(fg_rgb.r), colorF(fg_rgb.g), colorF(fg_rgb.b), 1 },
                };
                text_count += 1;
            }
        }

        // Draw text glyphs
        if (text_count > 0) {
            self.drawTextInstances(text_buf[0..text_count]);
        }

        // Draw block elements
        if (block_count > 0) {
            self.drawBgInstances(bg_buf[0..block_count]);
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
                self.drawBgInstances(&cursor_inst);
            }
        }

        // --- Scrollbar ---
        // `scrollbar_w` / `scrollbar_min_thumb_h` are DPI-scaled by the
        // caller so the thumb stays visible and draggable across monitor
        // DPI changes. The same `scrollbar_min_thumb_h` is used by the
        // drag hit-test in `main.zig` to keep click → offset mapping
        // consistent with what's drawn.
        const sb = terminal.screens.active.pages.scrollbar();
        if (sb.total > sb.len) {
            const sbw: f32 = @floatFromInt(scrollbar_w);
            const sb_min: f32 = @floatFromInt(scrollbar_min_thumb_h);
            const vp_hf: f32 = @floatFromInt(vp_h);
            const vp_wf: f32 = @floatFromInt(vp_w);
            const track_h: f32 = vp_hf - @as(f32, @floatFromInt(y_offset + padding));
            const track_x: f32 = vp_wf - sbw;
            const ratio = track_h / @as(f32, @floatFromInt(sb.total));
            const thumb_h = @max(sb_min, ratio * @as(f32, @floatFromInt(sb.len)));
            const available = track_h - thumb_h;
            const max_offset: f32 = @floatFromInt(sb.total - sb.len);
            const thumb_y = y_off + if (max_offset > 0) @as(f32, @floatFromInt(sb.offset)) / max_offset * available else 0;
            const scrollbar_inst = [1]BgInstance{.{
                .pos = .{ track_x, thumb_y },
                .size = .{ sbw, thumb_h },
                .color = ui_metrics.SCROLLBAR_COLOR,
            }};
            self.drawBgInstances(&scrollbar_inst);
        }

        perf.addTimed(&perf.render, render_t0);

        // Present
        const present_t0 = perf.now();
        _ = self.swap_chain.Present(1, 0);
        perf.addTimed(&perf.present, present_t0);
    }

    // --- Internal draw helpers ---

    fn setupFrame(self: *D3d11Renderer, rtv: *d3d.ID3D11RenderTargetView) void {
        // Bind render target
        const rtvs = [1]?*d3d.ID3D11RenderTargetView{rtv};
        self.ctx.OMSetRenderTargets(1, &rtvs, null);

        // Update constant buffer
        var mapped: d3d.D3D11_MAPPED_SUBRESOURCE = .{};
        if (self.ctx.Map(@ptrCast(self.cb), 0, d3d.D3D11_MAP_WRITE_DISCARD, 0, &mapped) >= 0) {
            const cb_data: *Constants = @ptrCast(@alignCast(mapped.pData));
            cb_data.* = .{
                .screen_w = @floatFromInt(self.vp_width),
                .screen_h = @floatFromInt(self.vp_height),
                .atlas_w = @floatFromInt(ATLAS_SIZE),
                .atlas_h = @floatFromInt(ATLAS_SIZE),
                .enhanced_contrast = self.sys_enhanced_contrast,
                .gamma_ratios = self.gamma_ratios,
            };
            self.ctx.Unmap(@ptrCast(self.cb), 0);
        }

        // Bind constant buffer to both VS and PS
        const cbs = [1]?*d3d.ID3D11Buffer{self.cb};
        self.ctx.VSSetConstantBuffers(0, 1, &cbs);
        self.ctx.PSSetConstantBuffers(0, 1, &cbs);

        // Set viewport
        const vp = [1]d3d.D3D11_VIEWPORT{.{
            .Width = @floatFromInt(self.vp_width),
            .Height = @floatFromInt(self.vp_height),
        }};
        self.ctx.RSSetViewports(1, &vp);
    }

    fn drawBgInstances(self: *D3d11Renderer, instances: []const BgInstance) void {
        if (instances.len == 0) return;

        // Upload instance data
        var mapped: d3d.D3D11_MAPPED_SUBRESOURCE = .{};
        if (self.ctx.Map(@ptrCast(self.bg_buffer), 0, d3d.D3D11_MAP_WRITE_DISCARD, 0, &mapped) < 0) return;
        const dst: [*]BgInstance = @ptrCast(@alignCast(mapped.pData));
        @memcpy(dst[0..instances.len], instances);
        self.ctx.Unmap(@ptrCast(self.bg_buffer), 0);

        // Set pipeline state
        self.ctx.IASetInputLayout(self.bg_layout);
        const strides = [1]u32{@sizeOf(BgInstance)};
        const offsets = [1]u32{0};
        const bufs = [1]?*d3d.ID3D11Buffer{self.bg_buffer};
        self.ctx.IASetVertexBuffers(0, 1, &bufs, &strides, &offsets);
        self.ctx.VSSetShader(self.bg_vs);
        self.ctx.PSSetShader(self.bg_ps);
        self.ctx.OMSetBlendState(self.alpha_blend, null, 0xffffffff);

        // Draw
        self.ctx.DrawInstanced(4, @intCast(instances.len), 0, 0);
    }

    fn drawTextInstances(self: *D3d11Renderer, instances: []const TextInstance) void {
        if (instances.len == 0) return;

        // Upload instance data
        var mapped: d3d.D3D11_MAPPED_SUBRESOURCE = .{};
        if (self.ctx.Map(@ptrCast(self.text_buffer), 0, d3d.D3D11_MAP_WRITE_DISCARD, 0, &mapped) < 0) return;
        const dst: [*]TextInstance = @ptrCast(@alignCast(mapped.pData));
        @memcpy(dst[0..instances.len], instances);
        self.ctx.Unmap(@ptrCast(self.text_buffer), 0);

        // Set pipeline state
        self.ctx.IASetInputLayout(self.text_layout);
        const strides = [1]u32{@sizeOf(TextInstance)};
        const offsets = [1]u32{0};
        const bufs = [1]?*d3d.ID3D11Buffer{self.text_buffer};
        self.ctx.IASetVertexBuffers(0, 1, &bufs, &strides, &offsets);
        self.ctx.VSSetShader(self.text_vs);
        self.ctx.PSSetShader(self.text_ps);
        self.ctx.OMSetBlendState(self.ct_blend, null, 0xffffffff);

        // Bind atlas texture
        const srvs = [1]?*d3d.ID3D11ShaderResourceView{self.atlas.srv};
        self.ctx.PSSetShaderResources(0, 1, &srvs);
        const samplers = [1]?*d3d.ID3D11SamplerState{self.sampler};
        self.ctx.PSSetSamplers(0, 1, &samplers);

        // Draw
        self.ctx.DrawInstanced(4, @intCast(instances.len), 0, 0);
    }

    fn compileShader(src: []const u8, entry: [*:0]const u8, target: [*:0]const u8) !*d3d.ID3DBlob {
        var code: ?*d3d.ID3DBlob = null;
        var errors: ?*d3d.ID3DBlob = null;
        if (d3d.D3DCompile(
            src.ptr,
            src.len,
            null,
            null,
            null,
            entry,
            target,
            0,
            0,
            &code,
            &errors,
        ) < 0) {
            if (errors) |e| _ = e.Release();
            return error.ShaderCompileFailed;
        }
        if (errors) |e| _ = e.Release();
        return code.?;
    }

    // --- Color helpers ---

    fn resolveBg(style: ghostty.Style, raw: *const ghostty.Cell, colors: *const ghostty.RenderState.Colors, is_selected: bool, is_inverse: bool, dbg_r: f32, dbg_g: f32, dbg_b: f32) [3]f32 {
        if (is_selected or is_inverse) {
            const rgb = style.fg(.{
                .default = colors.foreground,
                .palette = &colors.palette,
            });
            return .{ colorF(rgb.r), colorF(rgb.g), colorF(rgb.b) };
        }
        if (style.bg(raw, &colors.palette)) |rgb| {
            return .{ colorF(rgb.r), colorF(rgb.g), colorF(rgb.b) };
        }
        return .{ dbg_r, dbg_g, dbg_b };
    }

    fn resolveFg(style: ghostty.Style, raw: *const ghostty.Cell, colors: *const ghostty.RenderState.Colors, is_selected: bool, is_inverse: bool) ghostty.color.RGB {
        if (is_selected or is_inverse) {
            return style.bg(raw, &colors.palette) orelse colors.background;
        }
        return style.fg(.{
            .default = colors.foreground,
            .palette = &colors.palette,
            .bold = .bright,
        });
    }

    const BlockRect = struct { x0: f32, y0: f32, x1: f32, y1: f32, alpha: f32 };

    fn isBlockElement(cp: u21) bool {
        return cp >= 0x2580 and cp <= 0x2595;
    }

    fn blockElementRect(cp: u21) ?BlockRect {
        return switch (cp) {
            0x2580 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 0.5, .alpha = 1 },
            0x2581 => .{ .x0 = 0, .y0 = 7.0 / 8.0, .x1 = 1, .y1 = 1, .alpha = 1 },
            0x2582 => .{ .x0 = 0, .y0 = 6.0 / 8.0, .x1 = 1, .y1 = 1, .alpha = 1 },
            0x2583 => .{ .x0 = 0, .y0 = 5.0 / 8.0, .x1 = 1, .y1 = 1, .alpha = 1 },
            0x2584 => .{ .x0 = 0, .y0 = 4.0 / 8.0, .x1 = 1, .y1 = 1, .alpha = 1 },
            0x2585 => .{ .x0 = 0, .y0 = 3.0 / 8.0, .x1 = 1, .y1 = 1, .alpha = 1 },
            0x2586 => .{ .x0 = 0, .y0 = 2.0 / 8.0, .x1 = 1, .y1 = 1, .alpha = 1 },
            0x2587 => .{ .x0 = 0, .y0 = 1.0 / 8.0, .x1 = 1, .y1 = 1, .alpha = 1 },
            0x2588 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 1 },
            0x2589 => .{ .x0 = 0, .y0 = 0, .x1 = 7.0 / 8.0, .y1 = 1, .alpha = 1 },
            0x258A => .{ .x0 = 0, .y0 = 0, .x1 = 6.0 / 8.0, .y1 = 1, .alpha = 1 },
            0x258B => .{ .x0 = 0, .y0 = 0, .x1 = 5.0 / 8.0, .y1 = 1, .alpha = 1 },
            0x258C => .{ .x0 = 0, .y0 = 0, .x1 = 4.0 / 8.0, .y1 = 1, .alpha = 1 },
            0x258D => .{ .x0 = 0, .y0 = 0, .x1 = 3.0 / 8.0, .y1 = 1, .alpha = 1 },
            0x258E => .{ .x0 = 0, .y0 = 0, .x1 = 2.0 / 8.0, .y1 = 1, .alpha = 1 },
            0x258F => .{ .x0 = 0, .y0 = 0, .x1 = 1.0 / 8.0, .y1 = 1, .alpha = 1 },
            0x2590 => .{ .x0 = 0.5, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 1 },
            0x2591 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 0.25 },
            0x2592 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 0.5 },
            0x2593 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 0.75 },
            0x2594 => .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1.0 / 8.0, .alpha = 1 },
            0x2595 => .{ .x0 = 7.0 / 8.0, .y0 = 0, .x1 = 1, .y1 = 1, .alpha = 1 },
            else => null,
        };
    }

    /// Compute gamma ratio coefficients from system gamma, exactly matching
    /// Windows Terminal's DWrite_GetGammaRatios (dwrite_helpers.cpp).
    /// Raw table values are divided by 4, then multiplied by norm13/norm24.
    fn computeGammaRatios(gamma: f32) [4]f32 {
        // Raw coefficient table from WT source (values / 4.0)
        const raw = [13][4]f32{
            .{ 0.0000 / 4.0, 0.0000 / 4.0, 0.0000 / 4.0, 0.0000 / 4.0 }, // 1.0
            .{ 0.0166 / 4.0, -0.0807 / 4.0, 0.2227 / 4.0, -0.0751 / 4.0 }, // 1.1
            .{ 0.0350 / 4.0, -0.1760 / 4.0, 0.4325 / 4.0, -0.1370 / 4.0 }, // 1.2
            .{ 0.0543 / 4.0, -0.2821 / 4.0, 0.6302 / 4.0, -0.1876 / 4.0 }, // 1.3
            .{ 0.0739 / 4.0, -0.3963 / 4.0, 0.8167 / 4.0, -0.2287 / 4.0 }, // 1.4
            .{ 0.0933 / 4.0, -0.5161 / 4.0, 0.9926 / 4.0, -0.2616 / 4.0 }, // 1.5
            .{ 0.1121 / 4.0, -0.6395 / 4.0, 1.1588 / 4.0, -0.2877 / 4.0 }, // 1.6
            .{ 0.1300 / 4.0, -0.7649 / 4.0, 1.3159 / 4.0, -0.3080 / 4.0 }, // 1.7
            .{ 0.1469 / 4.0, -0.8911 / 4.0, 1.4644 / 4.0, -0.3234 / 4.0 }, // 1.8
            .{ 0.1627 / 4.0, -1.0170 / 4.0, 1.6051 / 4.0, -0.3347 / 4.0 }, // 1.9
            .{ 0.1773 / 4.0, -1.1420 / 4.0, 1.7385 / 4.0, -0.3426 / 4.0 }, // 2.0
            .{ 0.1908 / 4.0, -1.2652 / 4.0, 1.8650 / 4.0, -0.3476 / 4.0 }, // 2.1
            .{ 0.2031 / 4.0, -1.3864 / 4.0, 1.9851 / 4.0, -0.3501 / 4.0 }, // 2.2
        };

        // Normalization constants (from WT source)
        const norm13: f32 = @floatCast(@as(f64, 0x10000) / (255.0 * 255.0) * 4.0);
        const norm24: f32 = @floatCast(@as(f64, 0x100) / 255.0 * 4.0);

        // WT uses nearest-index rounding: clamp(gamma*10 + 0.5, 10, 22) - 10
        const idx_raw = @as(i32, @intFromFloat(gamma * 10.0 + 0.5));
        const idx_clamped = @max(10, @min(22, idx_raw)) - 10;
        const idx: usize = @intCast(idx_clamped);
        const r = raw[idx];

        return .{
            norm13 * r[0],
            norm24 * r[1],
            norm13 * r[2],
            norm24 * r[3],
        };
    }
};
