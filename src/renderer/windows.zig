// D3D11 terminal renderer with custom HLSL ClearType shader pipeline.
// Replaces D2D DrawGlyphRun with: DWrite glyph atlas + D3D11 instanced quads + dual-source ClearType blending.

const std = @import("std");
const ghostty = @import("ghostty-vt");
const d3d = @import("windows/d3d11.zig");
const dw = @import("../font/windows/directwrite.zig");
const dwrite_font = @import("../font/windows/font.zig");
const DWriteFontContext = dwrite_font.DWriteFontContext;
const ui_metrics = @import("../ui_metrics.zig");
const scrollbar = @import("../scrollbar.zig");
const GlyphAtlas = @import("windows/glyph_atlas.zig").GlyphAtlas;
const ATLAS_SIZE = @import("windows/glyph_atlas.zig").ATLAS_SIZE;
const perf = @import("../perf.zig");
const log = @import("../log.zig");
const display_width = @import("../font/display_width.zig");
const tab_layout = @import("../tab_layout.zig");
const tab_interaction = @import("../tab_interaction.zig");
const block_element = @import("block_element.zig");
const box_drawing = @import("../box_drawing.zig");
const ligature_mod = @import("../font/ligature.zig");
const isLigatureCandidate = ligature_mod.isLigatureCandidate;

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
    /// 0 = solid fill. 1 / 2 / 3 = U+2591 LIGHT / U+2592 MEDIUM / U+2593 DARK
    /// SHADE — shader 가 픽셀 (x,y) parity 로 dot mask 계산 + `discard` 로
    /// 25% / 50% / 75% 밀도 표현. WT / xterm 전통의 procedural shade. 폰트
    /// 글리프 fallback 보다 일관성 (font 무관).
    shade: f32 = 0,
};

const TextInstance = extern struct {
    pos: [2]f32,
    size: [2]f32,
    uv_pos: [2]f32,
    uv_size: [2]f32,
    fg_color: [4]f32,
    /// 0 = mono / ClearType (atlas RGB = subpixel mask, shader 가 fg_color 곱).
    /// 1 = color emoji (atlas RGB = 컬러, atlas A = alpha mask).
    color_flag: f32 = 0.0,
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
    \\struct I { float2 pos: IPOS; float2 sz: ISZ; float4 col: ICOL; float sh: ISH; uint vid: SV_VertexID; };
    \\struct O { float4 pos: SV_POSITION; float4 col: COLOR; float sh: SHADE; };
    \\O bg_vs(I i) { float2 c = float2(i.vid & 1, i.vid >> 1);
    \\  float2 px = (i.pos + c * i.sz) / sa.xy * 2.0 - 1.0;
    \\  O o; o.pos = float4(px.x, -px.y, 0, 1); o.col = i.col; o.sh = i.sh; return o; }
    \\float4 bg_ps(O i) : SV_Target {
    \\  if (i.sh > 0.5) {
    \\    // Procedural shade pattern (WT / xterm 전통). 셋 다 *대각 zigzag* —
    \\    // 행마다 1px 어긋난 정렬 → 세 밀도 섞여도 일관된 시각.
    \\    int2 px = int2(i.pos.xy);
    \\    if (i.sh < 1.5) {
    \\      // U+2591 LIGHT 25% — diagonal sparse: ON at (px + 2*py) % 4 == 0
    \\      if (((px.x + 2 * px.y) & 3) != 0) discard;
    \\    } else if (i.sh < 2.5) {
    \\      // U+2592 MEDIUM 50% — checkerboard
    \\      if (((px.x + px.y) & 1) != 0) discard;
    \\    } else {
    \\      // U+2593 DARK 75% — LIGHT 의 inverse (diagonal dense)
    \\      if (((px.x + 2 * px.y) & 3) == 0) discard;
    \\    }
    \\  }
    \\  return i.col;
    \\}
;

const text_shader_src =
    \\cbuffer CB : register(b0) { float4 sa; float4 p; float4 gr; };
    \\Texture2D atlas : register(t0);
    \\SamplerState smp : register(s0);
    \\struct I { float2 pos: IPOS; float2 sz: ISZ; float2 uvp: IUVP; float2 uvs: IUVS;
    \\  float4 fg: IFG; float cf: ICF; uint vid: SV_VertexID; };
    \\struct O { float4 pos: SV_POSITION; float2 uv: TEXCOORD; float4 fg: COLOR;
    \\  float cf: COLOR1; };
    \\struct P { float4 c0: SV_Target0; float4 c1: SV_Target1; };
    \\O text_vs(I i) { float2 c = float2(i.vid & 1, i.vid >> 1);
    \\  float2 px = (i.pos + c * i.sz) / sa.xy * 2.0 - 1.0;
    \\  O o; o.pos = float4(px.x, -px.y, 0, 1);
    \\  o.uv = (i.uvp + c * i.uvs) / sa.zw; o.fg = i.fg; o.cf = i.cf; return o; }
    \\float enh(float a, float k) { return a * (k + 1.0) / (a * k + 1.0); }
    \\float gammaCorr(float a, float f, float4 g) {
    \\  return a + a * (1.0 - a) * ((g.x * f + g.y) * a + (g.z * f + g.w)); }
    \\float lodAdj(float k, float3 c) {
    \\  return k * saturate(dot(c, float3(0.30, 0.59, 0.11) * -4.0) + 3.0); }
    \\P text_ps(O i) : SV_Target {
    \\  float4 sample = atlas.Sample(smp, i.uv);
    \\  P o;
    \\  if (i.cf > 0.5) {
    \\    // Color emoji path — atlas 가 D2D 가 그린 *premultiplied* BGRA 를 byte
    \\    // swap 만 해서 RGBA 로 보관 (Win Terminal 동등). c0 = atlas.rgba 그대로
    \\    // (premult), c1 = atlas.aaaa (4채널 동일). dual-source blend
    \\    // (SrcBlend=ONE / DestBlend=INV_SRC1_COLOR) 로 result = sample +
    \\    // dst*(1 - sample.aaaa) — premultiplied src-over 정확히 일치.
    \\    o.c0 = sample;
    \\    o.c1 = sample.aaaa;
    \\    return o;
    \\  }
    \\  float3 g = sample.rgb;
    \\  float k = lodAdj(p.x, i.fg.rgb);
    \\  float3 ct = float3(enh(g.r, k), enh(g.g, k), enh(g.b, k));
    \\  ct = float3(gammaCorr(ct.r, i.fg.r, gr), gammaCorr(ct.g, i.fg.g, gr),
    \\              gammaCorr(ct.b, i.fg.b, gr));
    \\  // c1 = coverage (per-channel). blend 가 INV_SRC1_COLOR 로 (1-ct) 합성 →
    \\  // result = fg*ct + dst*(1-ct). WT shader_ps.hlsl ClearType weights 동등.
    \\  o.c0 = float4(i.fg.rgb * ct, 1); o.c1 = float4(ct, 1); return o; }
;

// --- Renderer ---

pub const D3d11Renderer = struct {
    alloc: std.mem.Allocator,
    font: DWriteFontContext,
    atlas: GlyphAtlas,
    render_state: ghostty.RenderState = .empty,
    /// 마지막 그린 cursor 의 pixel 좌표 (Win client area 기준). 매 frame
    /// renderTerminal cell cursor 또는 renderTabBar rename cursor 그리면서
    /// 갱신. App 가 IME composition 활성 시 ImmSetCompositionWindow(CFS_POINT)
    /// 로 IME 후보 popup 을 이 위치 근처에 띄움 (#164 1d).
    last_cursor_px_x: c_int = 0,
    last_cursor_px_y: c_int = 0,

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
                d3d.D3D11_CREATE_DEVICE_BGRA_SUPPORT, // D2D interop 필요 (#136)
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
            log.appendLine("d3d", "swap chain create failed: layered={} hr=0x{x}", .{
                layered_window,
                @as(u32, @bitCast(create_hr)),
            });
            return error.D3D11CreateFailed;
        }
        log.appendLineVerbose("d3d", "swap chain created: layered={} effect={s} buffers={d}", .{
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
            .{ .SemanticName = "ISH", .SemanticIndex = 0, .Format = d3d.DXGI_FORMAT_R32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 32, .InputSlotClass = d3d.D3D11_INPUT_PER_INSTANCE_DATA, .InstanceDataStepRate = 1 },
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
            .{ .SemanticName = "ICF", .SemanticIndex = 0, .Format = d3d.DXGI_FORMAT_R32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 48, .InputSlotClass = d3d.D3D11_INPUT_PER_INSTANCE_DATA, .InstanceDataStepRate = 1 },
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

        // Dual-source blend (WT BackendD3D 동등) — ClearType per-channel weights
        // + premultiplied color emoji src-over 한 path 로 통일. shader 가 SV_Target1
        // 으로 *coverage* (ClearType: ct, color: alpha) 를 emit, blend stage 가
        // INV_SRC1_COLOR 로 (1-coverage) 합성 → result = src + dst*(1-coverage).
        // ClearType: fg*ct + dst*(1-ct), color emoji: sample + dst*(1-alpha).
        var ct_desc = d3d.D3D11_BLEND_DESC{};
        ct_desc.RenderTarget[0] = .{
            .BlendEnable = 1,
            .SrcBlend = d3d.D3D11_BLEND_ONE,
            .DestBlend = d3d.D3D11_BLEND_INV_SRC1_COLOR,
            .BlendOp = d3d.D3D11_BLEND_OP_ADD,
            .SrcBlendAlpha = d3d.D3D11_BLEND_ONE,
            .DestBlendAlpha = d3d.D3D11_BLEND_INV_SRC1_ALPHA,
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

    /// 탭바 layout (#117 Firefox 패턴) — cross-platform `tab_layout.Layout`
    /// 그대로 (#163 4-i-2). 호출처 host 가 `tab_layout.compute()` 결과를 그대로
    /// 넘김 — c_int 변환 cast block 사라짐. 본문 안 layout.* 가 f32 라 vertex
    /// 좌표에 그대로 사용.
    pub const TabBarLayout = tab_layout.Layout;

    pub fn renderTabBar(
        self: *D3d11Renderer,
        tab_titles: []const []const u8,
        active_tab: usize,
        tab_bar_height: c_int,
        client_w: c_int,
        client_h: c_int,
        tab_width: c_int,
        close_btn_size: c_int,
        tab_padding: c_int,
        /// drag 진행 중인 탭. null = drag 안 함 또는 5px 임계 미만. `current_x`
        /// (c_int) 는 *world* 좌표 (#117) — 화면 위치는 `current_x -
        /// tab_scroll_x + tab_area_x`. cross-platform `tab_interaction.DragView`.
        drag_view: ?tab_interaction.DragView,
        /// rename 진행 중이면 그 탭의 title 대신 이 텍스트를 그림. null = rename
        /// 비활성. cross-platform `tab_interaction.RenameView`.
        rename_view: ?tab_interaction.RenameView,
        /// rename 활성 탭의 cursor 옆에 IME 조합 중 자모 inline 표시 (#164 1c).
        /// 빈 slice = 표시 안 함. host 가 rename 활성 시 IME preedit 을 cell 대신
        /// 여기로 라우팅.
        rename_preedit: []const u8,
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
        const cw: f32 = @floatFromInt(self.font.cell_width_px);
        const ch: f32 = @floatFromInt(self.font.cell_height_px);
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
        const tax: f32 = layout.tab_area_x;

        // Tab backgrounds
        for (0..tab_count) |i| {
            if (bg_count >= 128) break;
            const is_dragged = if (drag_view) |d| (i == d.tab_index) else false;
            const tab_x: f32 = if (is_dragged)
                @as(f32, @floatFromInt(drag_view.?.current_x)) - tw / 2.0 - sx + tax
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
        // IME preedit overlay 별 buffer — main text drawTextInstances 후에
        // 별도 호출하기 위함. 같은 buffer 에 두면 main bg → main text → preedit
        // bg → preedit text 의 layer 순서 보장 못 함 (main text 가 preedit bg
        // 위에 그려져 cursor 뒤 글자가 보라 위에 보임). #164 1c-fix2.
        var pre_bg_buf: [16]BgInstance = undefined;
        var pre_bg_n: u32 = 0;
        var pre_text_buf: [16]TextInstance = undefined;
        var pre_text_n: u32 = 0;

        var cursor_instances: [1]BgInstance = undefined;
        var cursor_count: u32 = 0;
        for (0..tab_count) |i| {
            const is_dragged = if (drag_view) |d| (i == d.tab_index) else false;
            const tab_x: f32 = if (is_dragged)
                @as(f32, @floatFromInt(drag_view.?.current_x)) - tw / 2.0 - sx + tax
            else
                @as(f32, @floatFromInt(i)) * tw - sx + tax;

            const is_renaming = if (rename_view) |rv| (i == rv.tab_index) else false;
            const title = if (is_renaming) rename_view.?.text[0..rename_view.?.text_len] else tab_titles[i];
            const baseline_y2 = (tbh + self.font.ascent_px - (ch - self.font.ascent_px)) / 2.0;

            // Max text width: tab width - close button - padding on both sides - gap before close btn
            const max_text_w = tw - cbs - pad * 3;
            // 탭 제목의 실제 시각 폭 — wide char (한글/CJK/Fullwidth/주요 emoji)
            // 는 셀 2 칸. byte length × cw 로 추정하면 ASCII / CJK 모두 어긋남.
            const total_text_w = @as(f32, @floatFromInt(display_width.stringWidth(title))) * cw;
            const needs_truncate = !is_renaming and (total_text_w > max_text_w);
            const rename_cursor_pos: ?usize = if (is_renaming) rename_view.?.cursor else null;

            // cross-platform iterTabText — codepoint 별 cb 호출. mac/win 양쪽
            // 같은 helper 호출 → fix 한 곳 양쪽 자동 반영. (#163 옵션 A 확장)
            // text_x_start = absolute x (tab 내 text 시작점). cb 가 받는 x 도
            // absolute. preedit BG / glyph 은 별 buffer (1c-fix2) 라 main text
            // drawCall 후 별도 호출 — cb 가 cmd 종류로 분기.
            const text_x_start = tab_x + pad;
            const Ctx = struct {
                self: *D3d11Renderer,
                text_instances: *[512]TextInstance,
                text_count: *u32,
                cursor_instances: *[1]BgInstance,
                cursor_count: *u32,
                pre_bg_buf: *[16]BgInstance,
                pre_bg_n: *u32,
                pre_text_buf: *[16]TextInstance,
                pre_text_n: *u32,
                ch: f32,
                baseline_y2: f32,
                text_x_start: f32,
                pre_bg_color: [4]f32,
            };
            const ctx = Ctx{
                .self = self,
                .text_instances = &text_instances,
                .text_count = &text_count,
                .cursor_instances = &cursor_instances,
                .cursor_count = &cursor_count,
                .pre_bg_buf = &pre_bg_buf,
                .pre_bg_n = &pre_bg_n,
                .pre_text_buf = &pre_text_buf,
                .pre_text_n = &pre_text_n,
                .ch = ch,
                .baseline_y2 = baseline_y2,
                .text_x_start = text_x_start,
                .pre_bg_color = .{ 0.25, 0.25, 0.5, 1 },
            };
            const Target = enum { main, preedit };
            const emitGlyph = struct {
                fn run(c: Ctx, cp: u21, x: f32, into: Target) void {
                    if (x < c.text_x_start) return;
                    const result = c.self.font.resolveGlyph(cp) orelse return;
                    const entry = c.self.atlas.getOrInsert(result.face, result.index) orelse {
                        if (result.owned) _ = result.face.vtable.Release(result.face);
                        return;
                    };
                    if (result.owned) _ = result.face.vtable.Release(result.face);
                    if (entry.w == 0 or entry.h == 0) return;
                    const gx = x + @as(f32, @floatFromInt(entry.bearing_x));
                    const gy = c.baseline_y2 + @as(f32, @floatFromInt(entry.bearing_y));
                    const inst: TextInstance = .{
                        .pos = .{ gx, gy },
                        .size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                        .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
                        .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                        .fg_color = ui_metrics.TAB_TEXT_COLOR,
                    };
                    switch (into) {
                        .main => {
                            if (c.text_count.* >= 510) return;
                            c.text_instances[c.text_count.*] = inst;
                            c.text_count.* += 1;
                        },
                        .preedit => {
                            if (c.pre_text_n.* >= c.pre_text_buf.len) return;
                            c.pre_text_buf[c.pre_text_n.*] = inst;
                            c.pre_text_n.* += 1;
                        },
                    }
                }
            }.run;
            const rename_scroll_inout: ?*f32 = if (is_renaming) rename_view.?.scroll_offset else null;
            tab_layout.iterTabText(title, rename_cursor_pos, rename_preedit, text_x_start, cw, max_text_w, is_renaming, needs_truncate, rename_scroll_inout, ctx, struct {
                fn cb(c: Ctx, cmd: tab_layout.TextCmd) void {
                    switch (cmd) {
                        .glyph => |g| emitGlyph(c, g.cp, g.x, .main),
                        .cursor => |cur| {
                            const cy_px = c.baseline_y2 - c.self.font.ascent_px + 2;
                            c.cursor_instances[0] = .{
                                .pos = .{ cur.x, cy_px },
                                .size = .{ 1, c.ch - 2 },
                                .color = ui_metrics.TAB_TEXT_COLOR,
                            };
                            c.cursor_count.* = 1;
                            c.self.last_cursor_px_x = @intFromFloat(cur.x);
                            c.self.last_cursor_px_y = @intFromFloat(cy_px);
                        },
                        .preedit_bg => |pbg| {
                            if (c.pre_bg_n.* >= c.pre_bg_buf.len) return;
                            const cell_top = c.baseline_y2 - c.self.font.ascent_px;
                            c.pre_bg_buf[c.pre_bg_n.*] = .{
                                .pos = .{ pbg.x, cell_top },
                                .size = .{ pbg.advance, c.ch },
                                .color = c.pre_bg_color,
                            };
                            c.pre_bg_n.* += 1;
                        },
                        .preedit_glyph => |pg| emitGlyph(c, pg.cp, pg.x, .preedit),
                        .truncate_dot => |dot| emitGlyph(c, '.', dot.x, .main),
                    }
                }
            }.cb);

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
        // IME preedit overlay — main text drawCall *후* 그려 cursor 뒤 main
        // 글자가 보라 BG 에 가리도록 (#164 1c-fix2). 1c-fix2 commit msg 의
        // "main text 후 별도 호출" 작업이 실제 코드에 누락 → preedit 안 보임.
        if (pre_bg_n > 0) self.drawBgInstances(pre_bg_buf[0..pre_bg_n]);
        if (pre_text_n > 0) self.drawTextInstances(pre_text_buf[0..pre_text_n]);

        // #117 — 화살표 / + 영역. 탭 BG / 텍스트 그린 *후* 별도 batch 로 그려야
        // viewport 끝의 탭이 화살표 영역에 침범한 픽셀이 가려짐 (사용자 제안:
        // 탭 너비 줄이는 효과). 색은 활성 (밝은 흰색) / 비활성 (어두운 회색)
        // 명확히 구분.
        var ctrl_bg_buf: [3]BgInstance = undefined;
        var ctrl_bg_n: u32 = 0;
        if (layout.arrows_visible) {
            ctrl_bg_buf[ctrl_bg_n] = .{
                .pos = .{ layout.left_arrow_x, 0 },
                .size = .{ layout.arrow_w, tbh },
                .color = ui_metrics.TAB_BAR_BG,
            };
            ctrl_bg_n += 1;
            ctrl_bg_buf[ctrl_bg_n] = .{
                .pos = .{ layout.right_arrow_x, 0 },
                .size = .{ layout.arrow_w, tbh },
                .color = ui_metrics.TAB_BAR_BG,
            };
            ctrl_bg_n += 1;
        }
        ctrl_bg_buf[ctrl_bg_n] = .{
            .pos = .{ layout.plus_x, 0 },
            .size = .{ layout.plus_w, tbh },
            .color = ui_metrics.TAB_BAR_BG,
        };
        ctrl_bg_n += 1;
        self.drawBgInstances(ctrl_bg_buf[0..ctrl_bg_n]);

        // 글리프 `<` `>` `+`. 박스 안에 cw × ch 글자 가운데 정렬. 활성 / 비활성
        // 색 분리.
        var ctrl_text_buf: [3]TextInstance = undefined;
        var ctrl_text_n: u32 = 0;
        const drawCtrlGlyph = struct {
            fn run(rself: *D3d11Renderer, codepoint: u21, box_x: f32, box_w: f32, tbh_: f32, cw_: f32, ch_: f32, color: [4]f32, buf: []TextInstance, n: *u32) void {
                if (n.* >= buf.len) return;
                if (box_w <= 0) return;
                const result = rself.font.resolveGlyph(codepoint) orelse return;
                const entry = rself.atlas.getOrInsert(result.face, result.index) orelse {
                    if (result.owned) _ = result.face.vtable.Release(result.face);
                    return;
                };
                if (result.owned) _ = result.face.vtable.Release(result.face);
                if (entry.w == 0 or entry.h == 0) return;
                const gx = box_x + (box_w - cw_) * 0.5 + @as(f32, @floatFromInt(entry.bearing_x));
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
        /// IME 조합 중 자모 / 미완성 음절 — cursor 뒤 inline 표시 (#164). 빈
        /// slice = 표시 안 함. Window 가 WM_IME_COMPOSITION 처리 후 buffer 채움.
        preedit_utf8: []const u8,
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

            var x: usize = 0;
            while (x < cols) {
                if (x >= raws.len) break;
                const raw = raws[x];

                const is_text = raw.hasText() and raw.wide != .spacer_tail and raw.wide != .spacer_head and raw.codepoint() != 0;
                if (!is_text) {
                    x += 1;
                    continue;
                }

                const cp = raw.codepoint();

                // Block elements: draw as colored rectangle
                if (isBlockElement(cp)) {
                    if (block_count >= MAX_CELLS) {
                        self.drawBgInstances(bg_buf[0..block_count]);
                        block_count = 0;
                    }
                    const style_b = if (raw.style_id != 0) styles[x] else ghostty.Style{};
                    const is_inverse_b = style_b.flags.inverse;
                    const x16_b: u16 = @intCast(x);
                    const is_selected_b = if (sel_range) |sr| (x16_b >= sr[0] and x16_b <= sr[1]) else false;
                    const fg_rgb = resolveFg(style_b, &raw, &colors, is_selected_b, is_inverse_b);
                    const rect = blockElementRect(cp) orelse {
                        x += 1;
                        continue;
                    };
                    const width: f32 = if (raw.wide == .wide) 2.0 * cw else cw;
                    const fx: f32 = @as(f32, @floatFromInt(x)) * cw + x_pad;

                    bg_buf[block_count] = .{
                        .pos = .{ fx + rect.x0 * width, fy + rect.y0 * ch },
                        .size = .{ (rect.x1 - rect.x0) * width, (rect.y1 - rect.y0) * ch },
                        .color = .{ colorF(fg_rgb.r), colorF(fg_rgb.g), colorF(fg_rgb.b), rect.alpha },
                        .shade = rect.shade,
                    };
                    block_count += 1;
                    x += 1;
                    continue;
                }

                // Box-drawing (선/모서리/junction, U+2500–257F) — block element 과
                // 같은 이유로 procedural 사각형 (#258). 폰트 글리프는 cell 에 안
                // 맞아 셀 사이 갭. 대각선(╱╲╳)은 boxRects 가 null → 아래 글리프 path.
                if (cp >= 0x2500 and cp <= 0x257F) {
                    const box_w: f32 = if (raw.wide == .wide) 2.0 * cw else cw;
                    var box_rects: [box_drawing.MAX_RECTS]box_drawing.Rect = undefined;
                    if (box_drawing.boxRects(cp, box_w, ch, &box_rects)) |bn| {
                        if (block_count + bn > MAX_CELLS) {
                            self.drawBgInstances(bg_buf[0..block_count]);
                            block_count = 0;
                        }
                        const style_x = if (raw.style_id != 0) styles[x] else ghostty.Style{};
                        const is_inverse_x = style_x.flags.inverse;
                        const x16_x: u16 = @intCast(x);
                        const is_selected_x = if (sel_range) |sr| (x16_x >= sr[0] and x16_x <= sr[1]) else false;
                        const fg_rgb_x = resolveFg(style_x, &raw, &colors, is_selected_x, is_inverse_x);
                        const fx_box: f32 = @as(f32, @floatFromInt(x)) * cw + x_pad;
                        for (box_rects[0..bn]) |br| {
                            bg_buf[block_count] = .{
                                .pos = .{ fx_box + br.x, fy + br.y },
                                .size = .{ br.w, br.h },
                                .color = .{ colorF(fg_rgb_x.r), colorF(fg_rgb_x.g), colorF(fg_rgb_x.b), 1 },
                                .shade = 0,
                            };
                            block_count += 1;
                        }
                        x += 1;
                        continue;
                    }
                }

                const style = if (raw.style_id != 0) styles[x] else ghostty.Style{};
                const is_inverse = style.flags.inverse;
                const x16: u16 = @intCast(x);
                const is_selected = if (sel_range) |sr| (x16 >= sr[0] and x16 <= sr[1]) else false;
                const fg_rgb = resolveFg(style, &raw, &colors, is_selected, is_inverse);

                // SPEC § 12.1 — Grapheme cluster (VS-16 / skin tone / ZWJ family /
                // combining mark). IDWriteTextAnalyzer.GetGlyphs 로 cluster 통째
                // shape — single glyph (GSUB 합성 OK) 또는 multi-glyph (#139 ZWJ
                // family 등 합성 안 되는 cluster). ligature lookahead 와 별개.
                if (raw.hasGrapheme() and x < graphemes.len) {
                    if (text_count >= MAX_CELLS) {
                        self.drawTextInstances(text_buf[0..text_count]);
                        text_count = 0;
                    }
                    var cluster: [16]u21 = undefined;
                    cluster[0] = cp;
                    const extras = graphemes[x];
                    const take = @min(extras.len, cluster.len - 1);
                    @memcpy(cluster[1..][0..take], extras[0..take]);
                    const r_opt = self.font.resolveGrapheme(cluster[0 .. 1 + take]);
                    if (r_opt) |r| {
                        emitClusterInstance(self, text_buf[0..], &text_count, bg_buf[0..], &block_count, r, x, fy, cw, x_pad, fg_rgb, 0);
                        x += 1;
                        continue;
                    }
                }

                // SPEC § 12.2 — N-char ligature lookahead. 3-char → 2-char 순서.
                if (x + 2 < cols and x + 2 < raws.len and raw.wide == .narrow and isLigatureCandidate(cp)) {
                    const next = raws[x + 1];
                    const next2 = raws[x + 2];
                    if (next.wide == .narrow and next.hasText() and next.codepoint() != 0 and
                        next.style_id == raw.style_id and isLigatureCandidate(next.codepoint()) and
                        next2.wide == .narrow and next2.hasText() and next2.codepoint() != 0 and
                        next2.style_id == raw.style_id and isLigatureCandidate(next2.codepoint()))
                    {
                        if (self.font.ligatureTriple(cp, next.codepoint(), next2.codepoint())) |lm| {
                            emitLigatureMatch(self, text_buf[0..], &text_count, bg_buf[0..], &block_count, x, lm, fy, cw, x_pad, fg_rgb);
                            x += 3;
                            continue;
                        }
                    }
                }
                if (x + 1 < cols and x + 1 < raws.len and raw.wide == .narrow and isLigatureCandidate(cp)) {
                    const next = raws[x + 1];
                    if (next.wide == .narrow and next.hasText() and next.codepoint() != 0 and
                        next.style_id == raw.style_id and isLigatureCandidate(next.codepoint()))
                    {
                        if (self.font.ligaturePair(cp, next.codepoint())) |lm| {
                            emitLigatureMatch(self, text_buf[0..], &text_count, bg_buf[0..], &block_count, x, lm, fy, cw, x_pad, fg_rgb);
                            x += 2;
                            continue;
                        }
                    }
                }

                if (text_count >= MAX_CELLS) {
                    self.drawTextInstances(text_buf[0..text_count]);
                    text_count = 0;
                }

                const single = self.font.resolveGlyph(cp) orelse {
                    x += 1;
                    continue;
                };
                var single_indices = [_]u16{0} ** dwrite_font.MAX_CLUSTER_GLYPHS;
                single_indices[0] = single.index;
                const single_advances = [_]dw.FLOAT{0} ** dwrite_font.MAX_CLUSTER_GLYPHS;
                const single_offsets = [_]dw.DWRITE_GLYPH_OFFSET{.{ .advanceOffset = 0, .ascenderOffset = 0 }} ** dwrite_font.MAX_CLUSTER_GLYPHS;
                const single_result = dwrite_font.ClusterResult{
                    .face = single.face,
                    .indices = single_indices,
                    .advances = single_advances,
                    .offsets = single_offsets,
                    .count = 1,
                    .owned = single.owned,
                };
                emitClusterInstance(self, text_buf[0..], &text_count, bg_buf[0..], &block_count, single_result, x, fy, cw, x_pad, fg_rgb, 0);
                x += 1;
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
                self.last_cursor_px_x = @intFromFloat(cx0);
                self.last_cursor_px_y = @intFromFloat(cy0);
            }
        }

        // --- IME preedit overlay (#164) ---
        // cursor 위치부터 preedit_utf8 의 codepoint 별 cell 단위 확장. 보라
        // 배경 (mac `renderer/macos.zig` 의 pre_bg_color 동일) + glyph. wide
        // char (CJK) 는 2 cell 차지. 한글 / 일본어 / 중국어 / 베트남어 등 모든
        // IMM IME path. atlas 가 dirty 면 다음 frame 에 글자 표시 — 한 frame 늦음.
        if (preedit_utf8.len > 0 and self.render_state.cursor.viewport != null) {
            const vp = self.render_state.cursor.viewport.?;
            var pre_col: f32 = @floatFromInt(vp.x);
            const pre_row: f32 = @floatFromInt(vp.y);
            const pre_y = pre_row * ch + y_off;

            var pre_bg_buf: [16]BgInstance = undefined;
            var pre_text_buf: [16]TextInstance = undefined;
            var pre_bg_n: u32 = 0;
            var pre_text_n: u32 = 0;
            const fg_color: [4]f32 = .{ colorF(colors.foreground.r), colorF(colors.foreground.g), colorF(colors.foreground.b), 1 };
            const pre_bg_color: [4]f32 = .{ 0.25, 0.25, 0.5, 1 };

            var utf8_iter = std.unicode.Utf8Iterator{ .bytes = preedit_utf8, .i = 0 };
            while (utf8_iter.nextCodepoint()) |cp| {
                if (pre_bg_n >= pre_bg_buf.len) break;
                const result = self.font.resolveGlyph(@intCast(cp)) orelse continue;
                const entry = self.atlas.getOrInsert(result.face, result.index) orelse {
                    if (result.owned) _ = result.face.vtable.Release(result.face);
                    continue;
                };
                if (result.owned) _ = result.face.vtable.Release(result.face);

                const w_cells: f32 = @floatFromInt(display_width.codepointWidth(cp));

                const cell_x = pre_col * cw + x_pad;
                pre_bg_buf[pre_bg_n] = .{
                    .pos = .{ cell_x, pre_y },
                    .size = .{ w_cells * cw, ch },
                    .color = pre_bg_color,
                };
                pre_bg_n += 1;

                if (entry.w > 0 and entry.h > 0 and pre_text_n < pre_text_buf.len) {
                    const gx = cell_x + @as(f32, @floatFromInt(entry.bearing_x));
                    const gy = pre_y + self.font.ascent_px + @as(f32, @floatFromInt(entry.bearing_y));
                    pre_text_buf[pre_text_n] = .{
                        .pos = .{ gx, gy },
                        .size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                        .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
                        .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                        .fg_color = fg_color,
                        .color_flag = if (entry.is_color) 1.0 else 0.0,
                    };
                    pre_text_n += 1;
                }
                pre_col += w_cells;
            }

            if (pre_bg_n > 0) self.drawBgInstances(pre_bg_buf[0..pre_bg_n]);
            if (pre_text_n > 0) self.drawTextInstances(pre_text_buf[0..pre_text_n]);
        }

        // --- Scrollbar ---
        // `scrollbar_w` / `scrollbar_min_thumb_h` are DPI-scaled by the
        // caller so the thumb stays visible and draggable across monitor
        // DPI changes. The same `scrollbar_min_thumb_h` is used by the
        // drag hit-test in `main.zig` to keep click → offset mapping
        // consistent with what's drawn.
        const sb = terminal.screens.active.pages.scrollbar();
        // #259 — drag hit-test (`app_controller.scrollbarHit`) 와 같은 `scrollbar.hit`
        // 입력을 써서 thumb 그림 영역과 클릭 영역을 일치시킨다. track = `y_offset`
        // (탭바) 아래 + 위/아래 padding 반영.
        if (scrollbar.hit(
            sb.total,
            sb.len,
            sb.offset,
            @floatFromInt(vp_h),
            @floatFromInt(y_offset),
            @floatFromInt(padding),
            @floatFromInt(scrollbar_min_thumb_h),
        )) |h| {
            const sbw: f32 = @floatFromInt(scrollbar_w);
            const vp_wf: f32 = @floatFromInt(vp_w);
            const track_x: f32 = vp_wf - sbw;
            const scrollbar_inst = [1]BgInstance{.{
                .pos = .{ track_x, @floatCast(h.thumbTop()) },
                .size = .{ sbw, @floatCast(h.g.thumb_h) },
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

    /// 한 cluster (multi-glyph composite atlas entry) 또는 single-glyph 의 atlas
    /// entry 를 `text_buf` 에 push. atlas full 시 flush + reset + retry 패턴.
    /// fg_rgb 는 caller 가 cell 별 resolveFg 로 계산해 넘김.
    fn emitClusterInstance(
        self: *D3d11Renderer,
        text_buf: []TextInstance,
        text_count: *u32,
        bg_buf: []BgInstance,
        block_count: *u32,
        result: dwrite_font.ClusterResult,
        x: usize,
        fy: f32,
        cw: f32,
        x_pad: f32,
        fg_rgb: ghostty.color.RGB,
        /// spacer ligature 의 GPOS x_offset (DWRITE_GLYPH_OFFSET.advanceOffset
        /// 추출, Fira Code `||=` 의 `=` 가 `||` 쪽으로 당겨지는 디자인 등).
        /// 일반 cluster / single-glyph 는 0.
        dx: f32,
    ) void {
        if (text_count.* >= text_buf.len) {
            self.drawTextInstances(text_buf[0..text_count.*]);
            text_count.* = 0;
        }
        var entry_opt = self.atlas.getOrInsertCluster(result.face, result.indices[0..result.count], result.advances[0..result.count], result.offsets[0..result.count]);
        if (entry_opt == null and self.atlas.is_full) {
            if (text_count.* > 0) {
                self.drawTextInstances(text_buf[0..text_count.*]);
                text_count.* = 0;
            }
            if (block_count.* > 0) {
                self.drawBgInstances(bg_buf[0..block_count.*]);
                block_count.* = 0;
            }
            self.atlas.reset();
            entry_opt = self.atlas.getOrInsertCluster(result.face, result.indices[0..result.count], result.advances[0..result.count], result.offsets[0..result.count]);
        }
        const entry = entry_opt orelse {
            if (result.owned) _ = result.face.vtable.Release(result.face);
            return;
        };
        if (result.owned) _ = result.face.vtable.Release(result.face);
        if (entry.w == 0 or entry.h == 0) return;

        const fx: f32 = @as(f32, @floatFromInt(x)) * cw + x_pad + dx;
        const gx = fx + @as(f32, @floatFromInt(entry.bearing_x));
        const gy = fy + self.font.ascent_px + @as(f32, @floatFromInt(entry.bearing_y));
        text_buf[text_count.*] = .{
            .pos = .{ gx, gy },
            .size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
            .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
            .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
            .fg_color = .{ colorF(fg_rgb.r), colorF(fg_rgb.g), colorF(fg_rgb.b), 1 },
            .color_flag = if (entry.is_color) 1.0 else 0.0,
        };
        text_count.* += 1;
    }

    /// `LigatureMatch` switch — `.single` 은 1 glyph 을 base cell 에, `.spacer`
    /// 는 각 glyph 을 자기 cell 에 emit. 둘 다 single-glyph cluster atlas entry 로
    /// 그림. primary face 사용 (Latin ligature 는 primary 의 GSUB). `.spacer`
    /// 의 각 glyph 별 GPOS x_offset 적용 (`||=` 같은 디자인).
    fn emitLigatureMatch(
        self: *D3d11Renderer,
        text_buf: []TextInstance,
        text_count: *u32,
        bg_buf: []BgInstance,
        block_count: *u32,
        x: usize,
        match: dwrite_font.LigatureMatch,
        fy: f32,
        cw: f32,
        x_pad: f32,
        fg_rgb: ghostty.color.RGB,
    ) void {
        if (self.font.chain_count == 0) return;
        const face = self.font.chain_faces[0] orelse return;
        switch (match) {
            .single => |lg| {
                self.emitSingleGlyphCluster(text_buf, text_count, bg_buf, block_count, face, @intCast(lg.glyph_index), x, fy, cw, x_pad, fg_rgb, @as(f32, @floatFromInt(lg.x_offset)));
            },
            .spacer => |sp| {
                for (0..sp.count) |i| {
                    self.emitSingleGlyphCluster(text_buf, text_count, bg_buf, block_count, face, @intCast(sp.glyph_indices[i]), x + i, fy, cw, x_pad, fg_rgb, @as(f32, @floatFromInt(sp.x_offsets[i])));
                }
            },
        }
    }

    /// 단일 glyph_index 를 single-element ClusterResult 로 wrap 후 `emitClusterInstance`.
    fn emitSingleGlyphCluster(
        self: *D3d11Renderer,
        text_buf: []TextInstance,
        text_count: *u32,
        bg_buf: []BgInstance,
        block_count: *u32,
        face: *dw.IDWriteFontFace,
        glyph_index: u16,
        x: usize,
        fy: f32,
        cw: f32,
        x_pad: f32,
        fg_rgb: ghostty.color.RGB,
        dx: f32,
    ) void {
        var indices = [_]u16{0} ** dwrite_font.MAX_CLUSTER_GLYPHS;
        indices[0] = glyph_index;
        const advances = [_]dw.FLOAT{0} ** dwrite_font.MAX_CLUSTER_GLYPHS;
        const offsets = [_]dw.DWRITE_GLYPH_OFFSET{.{ .advanceOffset = 0, .ascenderOffset = 0 }} ** dwrite_font.MAX_CLUSTER_GLYPHS;
        const result = dwrite_font.ClusterResult{
            .face = face,
            .indices = indices,
            .advances = advances,
            .offsets = offsets,
            .count = 1,
            .owned = false,
        };
        self.emitClusterInstance(text_buf, text_count, bg_buf, block_count, result, x, fy, cw, x_pad, fg_rgb, dx);
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

    /// Block element + shade 처리는 양 platform 공유 모듈 `block_element.zig` 로
    /// 옮김 (#155). Windows / macOS 가 동일 코드포인트 → cell-fraction 좌표
    /// 매핑을 사용하고, 셰이더 procedural shade 만 platform 별 작성.
    const BlockRect = block_element.BlockRect;
    const isBlockElement = block_element.isBlockElement;
    const blockElementRect = block_element.blockElementRect;

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
