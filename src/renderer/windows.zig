// D3D11 terminal renderer with custom HLSL ClearType shader pipeline.
// Replaces D2D DrawGlyphRun with: DWrite glyph atlas + D3D11 instanced quads + dual-source ClearType blending.

const std = @import("std");
const ghostty = @import("ghostty-vt");
const d3d = @import("windows/d3d11.zig");
const dw = @import("../font/windows/directwrite.zig");
const dwrite_font = @import("../font/windows/font.zig");
const DWriteFontContext = dwrite_font.DWriteFontContext;
const font_spec = @import("../font/spec.zig");
const ui_metrics = @import("../ui_metrics.zig");
const chrome_palette = @import("../chrome_palette.zig");
const themes = @import("../themes.zig");
const scrollbar = @import("../scrollbar.zig");
const GlyphAtlas = @import("windows/glyph_atlas.zig").GlyphAtlas;
const ATLAS_SIZE = @import("windows/glyph_atlas.zig").ATLAS_SIZE;
const perf = @import("../perf.zig");
const log = @import("../log.zig");
const display_width = @import("../font/display_width.zig");
const tab_layout = @import("../tab_layout.zig");
const tab_chrome = @import("../tab_chrome.zig");
const session_core = @import("../session_core.zig");
const tab_icons = @import("../tab_icons.zig");
const tab_interaction = @import("../tab_interaction.zig");
const command_menu = @import("../command_menu.zig");
const block_element = @import("block_element.zig");
const cell_color = @import("cell_color.zig");
const box_drawing = @import("../box_drawing.zig");
const ligature_mod = @import("../font/ligature.zig");
const isLigatureCandidate = ligature_mod.isLigatureCandidate;

const MAX_INSTANCES: u32 = 32768;
extern "user32" fn GetDpiForWindow(?*anyopaque) callconv(.c) c_uint;
extern "user32" fn GetWindowLongPtrW(?*anyopaque, c_int) callconv(.c) isize;
extern "user32" fn GetClientRect(?*anyopaque, *dw.RECT) callconv(.c) i32;

/// COM IUnknown 최소 layout — QI 로 받은 임시 인터페이스(IDXGIDevice 등)의
/// Release 전용 (#89 2단계).
const ComUnknown = extern struct {
    vtable: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ComUnknown) callconv(.c) u32,
    },
    fn Release(self: *ComUnknown) u32 {
        return self.vtable.Release(self);
    }
};

fn comRelease(ptr: *anyopaque) void {
    const unk: *ComUnknown = @ptrCast(@alignCast(ptr));
    _ = unk.Release();
}
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

/// #343 — 공통 `tab_chrome.Rect` 를 D3D11 `BgInstance` 로. 필드가 이미 같은
/// shape 라 옮기기만 한다 (`shade` 는 기본값 0 = solid fill).
fn bgFromChrome(r: tab_chrome.Rect) BgInstance {
    return .{ .pos = .{ r.x, r.y }, .size = .{ r.w, r.h }, .color = r.color };
}

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
    tab_font: DWriteFontContext,
    tab_atlas: GlyphAtlas,
    /// 현재 DPI scale (dpi/96). pt → px 변환에 곱하는 단일 scale 값 — UI metric
    /// (탭바 아이콘 크기/두께 등) 이 이 값을 쓴다. init / DPI 변경 시 갱신.
    pixels_per_dip: f32 = 1.0,
    render_state: ghostty.RenderState = .empty,
    /// 마지막 그린 cursor 의 pixel 좌표 (Win client area 기준). 매 frame
    /// renderTerminal cell cursor 그리면서
    /// 갱신. App 가 IME composition 활성 시 ImmSetCompositionWindow(CFS_POINT)
    /// 로 IME 후보 popup 을 이 위치 근처에 띄움 (#164 1d).
    last_cursor_px_x: c_int = 0,
    last_cursor_px_y: c_int = 0,

    // D3D11 core
    device: *d3d.ID3D11Device,
    ctx: *d3d.ID3D11DeviceContext,
    swap_chain: *d3d.IDXGISwapChain,
    /// #89 2단계 — 반투명(opacity<255) composition 경로의 DComp 객체.
    /// opacity 100% (hwnd flip-model) 또는 composition 실패 fallback 시 null.
    dcomp_device: ?*d3d.IDCompositionDesktopDevice = null,
    dcomp_target: ?*d3d.IDCompositionTarget = null,
    dcomp_visual: ?*d3d.IDCompositionVisual = null,
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

    // active terminal 이 배경색을 제공하지 않을 때만 쓰는 init theme fallback.
    fallback_bg: [3]f32,

    /// #335 — theme 배경에서 파생한 탭바 / command menu chrome 색. theme 은
    /// runtime 에 바뀌지 않으므로 init 에서 한 번 계산해 보관한다. 탭바 그리기는
    /// `ui_metrics` 색 상수를 직접 참조하지 않고 이 값만 쓴다.
    chrome: chrome_palette.Palette,

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

    const FontResources = struct {
        font: DWriteFontContext,
        atlas: GlyphAtlas,

        fn deinit(self: *FontResources) void {
            self.atlas.deinit();
            self.font.deinit();
        }
    };

    fn initTabFontResources(
        alloc: std.mem.Allocator,
        font_chain: []const [*:0]const u16,
        dpi: c_uint,
        device: *d3d.ID3D11Device,
        ctx: *d3d.ID3D11DeviceContext,
    ) !FontResources {
        const effective_dpi: u32 = if (dpi > 0) dpi else 96;
        const pixels_per_dip = @as(f32, @floatFromInt(effective_dpi)) / 96.0;
        const spec = ui_metrics.tabLabelFontSpec();
        const physical_size = spec.physicalSizeRatioPx(effective_dpi, 96);
        const measured = try dwrite_font.measureCell(font_chain[0], physical_size);
        const cell_w = font_spec.ceilPositivePx(measured.cell_w * spec.cell_width_ratio);
        const cell_h = font_spec.ceilPositivePx(measured.cell_h * spec.line_height_ratio);

        var font_ctx = try DWriteFontContext.init(alloc, font_chain, spec, cell_w, cell_h);
        errdefer font_ctx.deinit();
        font_ctx.ascent_px *= pixels_per_dip;

        var atlas = try GlyphAtlas.init(alloc, font_ctx.factory, font_ctx.font_em_size, pixels_per_dip, device, ctx);
        errdefer atlas.deinit();
        return .{ .font = font_ctx, .atlas = atlas };
    }

    fn isLayeredWindow(hwnd: ?*anyopaque) bool {
        const handle = hwnd orelse return false;
        return (GetWindowLongPtrW(handle, GWL_EXSTYLE) & WS_EX_LAYERED) != 0;
    }

    /// #89 2단계 — 반투명 composition 경로 구성: D3D device(단독) → composition
    /// swap chain(premultiplied) → DComp device/target/visual → SetContent →
    /// visual3.SetOpacity(uniform) → SetRoot → Commit. 성공 시 out 파라미터를
    /// 채우고 true. 실패 시 만든 것을 전부 해제·null 후 false — caller 가
    /// 불투명 hwnd flip-model 로 fallback.
    fn initCompositionChain(
        hwnd: ?*anyopaque,
        opacity: u8,
        device: *?*d3d.ID3D11Device,
        ctx: *?*d3d.ID3D11DeviceContext,
        swap_chain: *?*d3d.IDXGISwapChain,
        dcomp_device: *?*d3d.IDCompositionDesktopDevice,
        dcomp_target: *?*d3d.IDCompositionTarget,
        dcomp_visual: *?*d3d.IDCompositionVisual,
    ) bool {
        var ok = false;
        defer if (!ok) {
            if (dcomp_visual.*) |v| {
                _ = v.Release();
                dcomp_visual.* = null;
            }
            if (dcomp_target.*) |t| {
                _ = t.Release();
                dcomp_target.* = null;
            }
            if (dcomp_device.*) |dd| {
                _ = dd.Release();
                dcomp_device.* = null;
            }
            if (swap_chain.*) |sc| {
                _ = sc.Release();
                swap_chain.* = null;
            }
            if (ctx.*) |c| {
                _ = c.Release();
                ctx.* = null;
            }
            if (device.*) |dev| {
                _ = dev.Release();
                device.* = null;
            }
        };

        if (d3d.D3D11CreateDevice(null, d3d.D3D_DRIVER_TYPE_HARDWARE, null, d3d.D3D11_CREATE_DEVICE_BGRA_SUPPORT, null, 0, d3d.D3D11_SDK_VERSION, device, null, ctx) < 0) return false;
        const dev = device.* orelse return false;

        var factory_any: ?*anyopaque = null;
        if (d3d.CreateDXGIFactory1(&d3d.IID_IDXGIFactory2, &factory_any) < 0 or factory_any == null) return false;
        const factory2: *d3d.IDXGIFactory2 = @ptrCast(@alignCast(factory_any.?));
        defer _ = factory2.Release();

        // composition swap chain 은 크기 자동 유도가 없어 명시 필수 — 이후
        // 크기 변화는 기존 ResizeBuffers 경로가 그대로 처리.
        var rc = std.mem.zeroes(dw.RECT);
        _ = GetClientRect(hwnd, &rc);
        const client_w: u32 = if (rc.right > rc.left) @intCast(rc.right - rc.left) else 800;
        const client_h: u32 = if (rc.bottom > rc.top) @intCast(rc.bottom - rc.top) else 400;

        const desc1 = d3d.DXGI_SWAP_CHAIN_DESC1{
            .Width = client_w,
            .Height = client_h,
            .Format = d3d.DXGI_FORMAT_B8G8R8A8_UNORM,
            .SampleDesc = .{ .Count = 1 },
            .BufferUsage = d3d.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 2,
            .Scaling = d3d.DXGI_SCALING_STRETCH,
            .SwapEffect = d3d.DXGI_SWAP_EFFECT_FLIP_DISCARD,
            // IGNORE — 내용은 불투명, 투명도는 visual SetOpacity 담당 (#89 2단계).
            .AlphaMode = d3d.DXGI_ALPHA_MODE_IGNORE,
        };
        if (factory2.CreateSwapChainForComposition(@ptrCast(dev), &desc1, null, swap_chain) < 0 or swap_chain.* == null) return false;

        // D3D device → IDXGIDevice → DComp device.
        const qi: *const fn (*d3d.ID3D11Device, *const d3d.GUID, *?*anyopaque) callconv(.c) d3d.HRESULT = @ptrCast(@alignCast(dev.vtable.QueryInterface));
        var dxgi_dev: ?*anyopaque = null;
        if (qi(dev, &d3d.IID_IDXGIDevice, &dxgi_dev) < 0 or dxgi_dev == null) return false;
        defer comRelease(dxgi_dev.?);

        var dcomp_any: ?*anyopaque = null;
        if (d3d.DCompositionCreateDevice3(dxgi_dev.?, &d3d.IID_IDCompositionDesktopDevice, &dcomp_any) < 0 or dcomp_any == null) return false;
        dcomp_device.* = @ptrCast(@alignCast(dcomp_any.?));
        const dd = dcomp_device.*.?;

        if (dd.CreateTargetForHwnd(hwnd, 1, dcomp_target) < 0 or dcomp_target.* == null) return false;
        if (dd.CreateVisual(dcomp_visual) < 0 or dcomp_visual.* == null) return false;
        const vis = dcomp_visual.*.?;
        if (vis.SetContent(@ptrCast(swap_chain.*.?)) < 0) return false;

        // uniform opacity — IDCompositionVisual3.SetOpacity (Win10+). 실패해도
        // composition 자체는 유지 (불투명 표시로 degrade, 로그로 알림).
        var vis3_any: ?*anyopaque = null;
        if (vis.QueryInterface(&d3d.IID_IDCompositionVisual3, &vis3_any) >= 0 and vis3_any != null) {
            const vis3: *d3d.IDCompositionVisual3 = @ptrCast(@alignCast(vis3_any.?));
            const hr_op = vis3.SetOpacity(@as(f32, @floatFromInt(opacity)) / 255.0);
            _ = vis3.Release();
            if (hr_op < 0) log.appendLine("d3d", "DComp SetOpacity failed hr=0x{x} — opacity 미적용", .{@as(u32, @bitCast(hr_op))});
        } else {
            log.appendLine("d3d", "IDCompositionVisual3 QI failed — opacity 미적용", .{});
        }

        if (dcomp_target.*.?.SetRoot(vis) < 0) return false;
        if (dd.Commit() < 0) return false;

        ok = true;
        return true;
    }

    fn swapEffectName(swap_effect: u32) []const u8 {
        return switch (swap_effect) {
            d3d.DXGI_SWAP_EFFECT_FLIP_DISCARD => "flip_discard",
            d3d.DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL => "flip_sequential",
            d3d.DXGI_SWAP_EFFECT_DISCARD => "discard",
            else => "unknown",
        };
    }

    pub fn init(alloc: std.mem.Allocator, hwnd: ?*anyopaque, font_chain: []const [*:0]const u16, spec: font_spec.Spec, cell_w: u32, cell_h: u32, bg_rgb: ?[3]u8, opacity: u8) !D3d11Renderer {
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

        // #89 2단계 — 반투명(opacity<255)은 DirectComposition 경로: composition
        // swap chain(premultiplied alpha) + DComp visual 의 uniform SetOpacity.
        // 렌더 내용은 불투명 그대로라 파이프라인 무변경, LWA_ALPHA 의미론 동일.
        // 실패 시 불투명 flip-model 로 degrade (opacity 미적용 — 검정/미표시보다 안전).
        var dcomp_device: ?*d3d.IDCompositionDesktopDevice = null;
        var dcomp_target: ?*d3d.IDCompositionTarget = null;
        var dcomp_visual: ?*d3d.IDCompositionVisual = null;
        var composition_active = false;
        if (opacity < 255 and !layered_window) {
            composition_active = initCompositionChain(hwnd, opacity, &device, &ctx, &swap_chain, &dcomp_device, &dcomp_target, &dcomp_visual);
            if (!composition_active) {
                log.appendLine("d3d", "composition path failed — falling back to opaque flip-model (opacity ignored)", .{});
            }
        }

        const layered_swap_effects = [_]u32{d3d.DXGI_SWAP_EFFECT_DISCARD};
        const standard_swap_effects = [_]u32{
            d3d.DXGI_SWAP_EFFECT_FLIP_DISCARD,
            d3d.DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
            d3d.DXGI_SWAP_EFFECT_DISCARD,
        };
        const swap_effects: []const u32 = if (layered_window) &layered_swap_effects else &standard_swap_effects;
        var create_hr: d3d.HRESULT = if (composition_active) 0 else -1;
        var selected_swap_effect: u32 = if (composition_active) d3d.DXGI_SWAP_EFFECT_FLIP_DISCARD else d3d.DXGI_SWAP_EFFECT_DISCARD;
        if (composition_active) sc_desc.BufferCount = 2;
        for (if (composition_active) swap_effects[0..0] else swap_effects) |swap_effect| {
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
        log.appendLineVerbose("d3d", "swap chain created: layered={} composition={} effect={s} buffers={d}", .{
            layered_window,
            composition_active,
            swapEffectName(selected_swap_effect),
            sc_desc.BufferCount,
        });

        // #89 — DXGI 의 내장 Alt+Enter 감시 차단. DXGI 는 swap chain 이 붙은
        // 창의 Alt+Enter 를 자체 hook 으로 감지해 exclusive fullscreen 전환을
        // 시도한다 (WndProc 가 메시지를 소비해도 무관). tildaz 는 Alt+Enter 를
        // 자체 fullscreen 토글로 쓰므로 이중 처리 — layered+BitBlt 시절엔
        // 전환이 조용히 실패해 숨어 있다가, flip-model 활성화(7ef7302) 후
        // 실제 발동해 화면 하단이 검게 덮이는 실기 증상으로 드러남 (창 rect
        // 는 정상인데 taskbar 영역만 검정 + 클릭은 통과 — DXGI FS 전환의
        // 전형). NO_WINDOW_CHANGES 로 감시 자체를 끈다. (composition swap
        // chain 은 hwnd 연동 자체가 없어 해당 없음.)
        if (!composition_active) {
            var factory_ptr: ?*anyopaque = null;
            if (swap_chain.?.GetParent(&d3d.IID_IDXGIFactory, &factory_ptr) >= 0) {
                if (factory_ptr) |fp| {
                    const factory: *d3d.IDXGIFactory = @ptrCast(@alignCast(fp));
                    const mwa_hr = factory.MakeWindowAssociation(hwnd, d3d.DXGI_MWA_NO_WINDOW_CHANGES | d3d.DXGI_MWA_NO_ALT_ENTER);
                    log.appendLineVerbose("d3d", "MakeWindowAssociation(NO_WINDOW_CHANGES|NO_ALT_ENTER) hr=0x{x}", .{@as(u32, @bitCast(mwa_hr))});
                    _ = factory.Release();
                }
            }
        }
        errdefer {
            _ = ctx.?.Release();
            _ = swap_chain.?.Release();
            _ = device.?.Release();
        }

        // 2. Init font context
        var font_ctx = try DWriteFontContext.init(alloc, font_chain, spec, cell_w, cell_h);
        errdefer font_ctx.deinit();

        // 3. Init glyph atlas (with DPI-aware pixelsPerDip)
        const dpi = GetDpiForWindow(hwnd);
        const pixels_per_dip: f32 = if (dpi > 0) @as(f32, @floatFromInt(dpi)) / 96.0 else 1.0;
        // Scale ascent_px to match actual rendered glyph pixels (font_em_size is unscaled,
        // but CreateGlyphRunAnalysis renders at font_em_size * pixels_per_dip)
        font_ctx.ascent_px *= pixels_per_dip;
        var atlas = try GlyphAtlas.init(alloc, font_ctx.factory, font_ctx.font_em_size, pixels_per_dip, device.?, ctx.?);
        errdefer atlas.deinit();

        var tab_resources = try initTabFontResources(alloc, font_chain, dpi, device.?, ctx.?);
        errdefer tab_resources.deinit();

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
            .tab_font = tab_resources.font,
            .tab_atlas = tab_resources.atlas,
            .pixels_per_dip = pixels_per_dip,
            .device = device.?,
            .ctx = ctx.?,
            .swap_chain = swap_chain.?,
            .dcomp_device = dcomp_device,
            .dcomp_target = dcomp_target,
            .dcomp_visual = dcomp_visual,
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
            .fallback_bg = .{ colorF(bg[0]), colorF(bg[1]), colorF(bg[2]) },
            .chrome = chrome_palette.derive(bg, themes.isDarkRgb(bg[0], bg[1], bg[2])),
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
        self.tab_atlas.deinit();
        self.tab_font.deinit();
        self.atlas.deinit();
        self.font.deinit();
        // #89 2단계 — DComp 객체는 swap chain(visual content) 보다 먼저 해제.
        if (self.dcomp_visual) |v| _ = v.Release();
        if (self.dcomp_target) |t| _ = t.Release();
        if (self.dcomp_device) |dd| _ = dd.Release();
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
    /// On failure the previous renderer resources remain active.
    pub fn rebuildFont(
        self: *D3d11Renderer,
        hwnd: ?*anyopaque,
        font_chain: []const [*:0]const u16,
        spec: font_spec.Spec,
        cell_w: u32,
        cell_h: u32,
    ) !void {
        var font_ctx = try DWriteFontContext.init(self.alloc, font_chain, spec, cell_w, cell_h);
        errdefer font_ctx.deinit();

        const dpi = GetDpiForWindow(hwnd);
        const pixels_per_dip: f32 = if (dpi > 0) @as(f32, @floatFromInt(dpi)) / 96.0 else 1.0;
        // Match the scaling done in `init` so glyphs positioned using
        // `ascent_px` line up with the DPI-scaled raster.
        font_ctx.ascent_px *= pixels_per_dip;

        var atlas = try GlyphAtlas.init(self.alloc, font_ctx.factory, font_ctx.font_em_size, pixels_per_dip, self.device, self.ctx);
        errdefer atlas.deinit();

        var tab_resources = try initTabFontResources(self.alloc, font_chain, dpi, self.device, self.ctx);
        errdefer tab_resources.deinit();

        self.tab_atlas.deinit();
        self.tab_font.deinit();
        self.atlas.deinit();
        self.font.deinit();
        self.font = font_ctx;
        self.atlas = atlas;
        self.tab_font = tab_resources.font;
        self.tab_atlas = tab_resources.atlas;
        self.pixels_per_dip = pixels_per_dip;

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
        /// #282 B8 — active terminal 의 현재 background (OSC 11 포함).
        /// null 은 terminal 에 배경이 없을 때만 init theme fallback 사용.
        terminal_background: ?ghostty.color.RGB,
        tab_bar_height: c_int,
        client_w: c_int,
        client_h: c_int,
        tab_width: c_int,
        tab_padding: c_int,
        /// Windows DPI / 96. 탭 gap과 hover inset의 logical point를 physical
        /// pixel로 변환할 때 사용한다.
        dpi_scale: f32,
        /// drag 진행 중인 탭. null = drag 안 함 또는 5px 임계 미만. `current_x`
        /// (c_int) 는 *world* 좌표 (#117) — 화면 위치는 `current_x -
        /// tab_scroll_x + tab_area_x`. cross-platform `tab_interaction.DragView`.
        drag_view: ?tab_interaction.DragView,
        /// 탭바 스크롤 오프셋 (#117). 각 탭 / drag 탭의 화면 x = world - 이 값
        /// + tab_area_x 오프셋.
        tab_scroll_x: c_int,
        /// 화살표 / + / × 버튼 layout. arrows_visible == false 면 화살표 없음.
        layout: TabBarLayout,
        /// #268 2b — hover 중인 컨트롤 버튼 (.none = 없음). 해당 버튼에 강조
        /// 배경 박스.
        hover: tab_layout.Area,
    ) void {
        const tab_count = tab_titles.len;
        const rtv = self.rtv orelse return;
        const frame_bg = cell_color.resolveFrameBackground(terminal_background, self.fallback_bg);

        // tab_bar_height == 0 면 탭바 자체를 그리지 않고 clear 만 하고 종료
        // (#127 — 단일 탭에서는 app_controller.effectiveTabBarHeight() 가 0).
        // clear 는 항상 필요 — renderTerminal 보다 먼저 active terminal 의 현재
        // background 로 채운다.
        if (tab_bar_height <= 0) {
            self.setupFrame(rtv);
            const clear_color = [4]d3d.FLOAT{ frame_bg[0], frame_bg[1], frame_bg[2], 1.0 };
            self.ctx.ClearRenderTargetView(rtv, &clear_color);
            return;
        }

        const tbh: f32 = @floatFromInt(tab_bar_height);
        const tw: f32 = @floatFromInt(tab_width);
        const pad: f32 = @floatFromInt(tab_padding);
        const tab_gap = ui_metrics.tabGapPx(dpi_scale);
        const cw: f32 = @floatFromInt(self.tab_font.cell_width_px);
        const ch: f32 = @floatFromInt(self.tab_font.cell_height_px);
        const w_f: f32 = @floatFromInt(client_w);

        // Ensure viewport dimensions are set
        if (self.vp_width == 0 or self.vp_height == 0) {
            self.vp_width = @intCast(@max(1, client_w));
            self.vp_height = @intCast(@max(1, client_h));
        }

        // Update viewport and constant buffer
        self.setupFrame(rtv);

        // Clear with the active terminal's current background.
        const clear_color = [4]d3d.FLOAT{ frame_bg[0], frame_bg[1], frame_bg[2], 1.0 };
        self.ctx.ClearRenderTargetView(rtv, &clear_color);

        // #343 — rect 목록과 그 순서는 공통 `tab_chrome` 이 만든다. 여기서는
        // `BgInstance` 로 옮기고, 사이사이에 이 renderer 고유인 텍스트 / 아이콘
        // batch 를 끼운다 (`before_titles` 경계).
        const chrome_in = tab_chrome.Inputs{
            .viewport_w = w_f,
            .tab_bar_h = tbh,
            .tab_w = tw,
            .sep_w = ui_metrics.strokePx(ui_metrics.TAB_SEPARATOR_W_PT, self.pixels_per_dip),
            .underline_h = ui_metrics.strokePx(ui_metrics.TAB_ACTIVE_UNDERLINE_PT, self.pixels_per_dip),
            .hover_inset = tab_gap.control_hover_inset,
            .tab_count = tab_count,
            .active_idx = active_tab,
            .scroll_x = @floatFromInt(tab_scroll_x),
            .drag = drag_view,
            .layout = layout,
            .hover = hover,
            .palette = &self.chrome,
        };
        var chrome_rects: [tab_chrome.maxRects(session_core.MAX_TABS)]tab_chrome.Rect = undefined;
        const built = tab_chrome.build(&chrome_rects, chrome_in);

        var bg_instances: [128]BgInstance = undefined;
        var bg_count: u32 = 0;
        for (built.rects[0..built.before_titles]) |r| {
            if (bg_count >= bg_instances.len) break;
            bg_instances[bg_count] = bgFromChrome(r);
            bg_count += 1;
        }
        const tab_area_end = layout.tab_area_x + layout.tab_area_w;

        // Draw backgrounds
        self.drawBgInstances(bg_instances[0..bg_count]);

        // Tab title text + close buttons via glyph atlas
        var text_instances: [512]TextInstance = undefined;
        var text_count: u32 = 0;
        for (0..tab_count) |i| {
            const tab_x = tab_chrome.tabX(i, chrome_in);
            switch (tab_chrome.tabClip(tab_x, tw, layout.tab_area_x, tab_area_end, drag_view != null)) {
                .skip => continue,
                .stop => break,
                .draw => {},
            }

            const title = tab_titles[i];
            const baseline_y2 = (tbh + self.tab_font.ascent_px - (ch - self.tab_font.ascent_px)) / 2.0;

            // Max text width — #268 per-tab close 제거로 탭 전체 (양쪽 padding 제외).
            const max_text_w = tw - pad * 2;
            // 탭 제목의 실제 시각 폭 — wide char (한글/CJK/Fullwidth/주요 emoji)
            // 는 셀 2 칸. byte length × cw 로 추정하면 ASCII / CJK 모두 어긋남.
            const total_text_w = @as(f32, @floatFromInt(display_width.stringWidth(title))) * cw;
            const needs_truncate = total_text_w > max_text_w;

            // cross-platform iterTabText — codepoint 별 cb 호출. 세 platform 이
            // 같은 helper 호출 → fix 한 곳 전부 자동 반영. (#163 옵션 A)
            // text_x_start = absolute x (tab 내 text 시작점). cb 가 받는 x 도
            // absolute.
            const text_x_start = tab_x + pad;
            const Ctx = struct {
                self: *D3d11Renderer,
                text_instances: *[512]TextInstance,
                text_count: *u32,
                baseline_y2: f32,
                /// #343 — glyph clip 을 **명시** 로 통일. 이전에는 좌측만
                /// (`text_x_start`) 보고 우측은 나중에 그리는 컨트롤 fill 이
                /// 덮어 가렸다. 좌측도 `tab_area_x` 로 clamp 한다 — 부분 잘린
                /// 첫 탭은 `text_x_start` 가 tab_area 왼쪽으로 넘어갈 수 있다.
                viewport_left: f32,
                tab_area_end: f32,
            };
            const ctx = Ctx{
                .self = self,
                .text_instances = &text_instances,
                .text_count = &text_count,
                .baseline_y2 = baseline_y2,
                .viewport_left = @max(text_x_start, layout.tab_area_x),
                .tab_area_end = tab_area_end,
            };
            tab_layout.iterTabText(title, text_x_start, cw, max_text_w, needs_truncate, ctx, struct {
                fn cb(c: Ctx, g: tab_layout.Glyph) void {
                    if (g.x < c.viewport_left) return;
                    if (g.x >= c.tab_area_end) return;
                    const result = c.self.tab_font.resolveGlyph(g.cp) orelse return;
                    const entry = c.self.tab_atlas.getOrInsert(result.face, result.index) orelse {
                        if (result.owned) _ = result.face.vtable.Release(result.face);
                        return;
                    };
                    if (result.owned) _ = result.face.vtable.Release(result.face);
                    if (entry.w == 0 or entry.h == 0) return;
                    const gx = g.x + @as(f32, @floatFromInt(entry.bearing_x));
                    const gy = c.baseline_y2 + @as(f32, @floatFromInt(entry.bearing_y));
                    if (c.text_count.* >= 510) return;
                    c.text_instances[c.text_count.*] = .{
                        .pos = .{ gx, gy },
                        .size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                        .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
                        .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                        .fg_color = c.self.chrome.tab_text,
                    };
                    c.text_count.* += 1;
                }
            }.cb);
        }

        if (text_count > 0) {
            self.drawTextInstancesWithAtlas(text_instances[0..text_count], &self.tab_atlas);
        }

        // #343 — 제목 뒤 구간: 컨트롤 bg fill → hover 박스 → 세로 구분선.
        // 별도 batch 로 그리는 이유는 그대로다 (#117) — 탭 텍스트 *후* 여야
        // 컨트롤 영역이 온전하다. 어떤 rect 를 어떤 순서로 놓을지는 이제 공통
        // `tab_chrome` 이 정한다 (세 renderer 정본 순서).
        {
            var tail_buf: [tab_chrome.maxRects(session_core.MAX_TABS)]BgInstance = undefined;
            var tail_n: u32 = 0;
            for (built.rects[built.before_titles..]) |r| {
                tail_buf[tail_n] = bgFromChrome(r);
                tail_n += 1;
            }
            if (tail_n > 0) self.drawBgInstances(tail_buf[0..tail_n]);
        }

        // #268 직접 그리기 — 아이콘 (`< > × +`) 을 `tab_icons` 공통 rasterizer 로
        // 알파 커버리지 비트맵을 만들어 atlas 커스텀 엔트리로 그림 (폰트 독립).
        // Linux / macOS 와 같은 비트맵 → 세 platform 픽셀 동일. box 중앙 정렬.
        // scale 은 renderer 가 들고 있는 pixels_per_dip 사용 (탭바 폰트/metric 과
        // 동일 scale — 역산 아님).
        var ctrl_text_buf: [5]TextInstance = undefined;
        var ctrl_text_n: u32 = 0;
        const icon_size: u32 = ui_metrics.scaledPx(u32, ui_metrics.TAB_ICON_SIZE_PT, self.pixels_per_dip);
        const icon_stroke: f32 = ui_metrics.strokePx(ui_metrics.TAB_ICON_STROKE_PT, self.pixels_per_dip);
        const more_stroke: f32 = ui_metrics.strokePx(ui_metrics.TAB_MORE_DOT_DIAMETER_PT, self.pixels_per_dip);
        const drawIcon = struct {
            fn run(rself: *D3d11Renderer, icon: tab_icons.Icon, box_x: f32, box_w: f32, tbh_: f32, isz: u32, istroke: f32, color: [4]f32, buf: []TextInstance, n: *u32) void {
                if (n.* >= buf.len) return;
                if (box_w <= 0 or isz == 0) return;
                const entry = rself.tab_atlas.getOrInsertIcon(icon, isz, istroke) orelse return;
                if (entry.w == 0 or entry.h == 0) return;
                const fsz: f32 = @floatFromInt(isz);
                const gx = box_x + (box_w - fsz) * 0.5;
                const gy = (tbh_ - fsz) * 0.5;
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
            const left_color = if (layout.left_enabled) self.chrome.ctrl_active else self.chrome.arrow_disabled;
            const right_color = if (layout.right_enabled) self.chrome.ctrl_active else self.chrome.arrow_disabled;
            drawIcon(self, .chevron_left, layout.left_arrow_x, layout.arrow_w, tbh, icon_size, icon_stroke, left_color, &ctrl_text_buf, &ctrl_text_n);
            drawIcon(self, .chevron_right, layout.right_arrow_x, layout.arrow_w, tbh, icon_size, icon_stroke, right_color, &ctrl_text_buf, &ctrl_text_n);
        }
        // #329 — MAX_TABS 도달 시 `+` 는 자리 유지 + 비활성 색 (arrow 동일 관례).
        const plus_color = if (layout.plus_enabled) self.chrome.ctrl_active else self.chrome.arrow_disabled;
        drawIcon(self, .plus, layout.plus_x, layout.plus_w, tbh, icon_size, icon_stroke, plus_color, &ctrl_text_buf, &ctrl_text_n);
        // #268 — 우측 끝 활성 탭 닫기 버튼 `×`.
        drawIcon(self, .close, layout.close_x, layout.close_w, tbh, icon_size, icon_stroke, self.chrome.ctrl_active, &ctrl_text_buf, &ctrl_text_n);
        drawIcon(self, .more, layout.more_x, layout.more_w, tbh, icon_size, more_stroke, self.chrome.ctrl_active, &ctrl_text_buf, &ctrl_text_n);
        if (ctrl_text_n > 0) self.drawTextInstancesWithAtlas(ctrl_text_buf[0..ctrl_text_n], &self.tab_atlas);

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
        scrollbar_y_offset: c_int,
        padding: c_int,
        scrollbar_w: c_int,
        scrollbar_min_thumb_h: c_int,
        /// IME 조합 중 자모 / 미완성 음절 — cursor 뒤 inline 표시 (#164). 빈
        /// slice = 표시 안 함. Window 가 WM_IME_COMPOSITION 처리 후 buffer 채움.
        preedit_utf8: []const u8,
        control_layout: TabBarLayout,
        control_hover: tab_layout.Area,
        menu_ui: command_menu.Ui,
        toggle_hotkey: []const u8,
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

                    // #353 — 음영 ░▒▓ (alpha 0.25/0.5/0.75) 을 공통
                    // `ui_metrics.blendOverRgb` 로 **여기서 한 번** 합성하고 알파 1.0
                    // 으로 그린다. 이전에는 알파를 blend unit 에 맡겼고, blend factor
                    // 가 render target 정밀도(8bit)로 양자화되는 하드웨어 동작 때문에
                    // Linux · macOS 와 값이 갈렸다 (최대 차 2).
                    //
                    // 합성 대상은 bg pass 가 이 셀에 칠한 색과 같아야 한다 — 같은
                    // `cell_color.resolveBg` 를 쓰고 null 이면 `colors.background`
                    // (bg pass 의 `dbg_*` 와 동일) 로 떨어진다. 솔리드 블록
                    // (alpha 1.0) 은 합성 결과가 `fg_rgb` 그대로다.
                    const block_bg = cell_color.resolveBg(style_b, &raw, &colors, is_selected_b, is_inverse_b) orelse colors.background;
                    const blended = ui_metrics.blendOverRgb(
                        .{ fg_rgb.r, fg_rgb.g, fg_rgb.b },
                        .{ block_bg.r, block_bg.g, block_bg.b },
                        rect.alpha,
                    );
                    bg_buf[block_count] = .{
                        .pos = .{ fx + rect.x0 * width, fy + rect.y0 * ch },
                        .size = .{ (rect.x1 - rect.x0) * width, (rect.y1 - rect.y0) * ch },
                        .color = .{ colorF(blended[0]), colorF(blended[1]), colorF(blended[2]), 1 },
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
                        // #353 — `br.cov` (AA coverage) 를 공통 `ui_metrics.blendOverRgb`
                        // 로 미리 합성하고 알파 1.0 으로 그린다. **emitter 가 픽셀당
                        // rect 를 하나만 내보내므로** (대각선은 두 선을 `@max` 로, 호는
                        // arm·arc 거리를 `@min` 으로 합친 *뒤* emit) 한 픽셀에 blend 가
                        // 한 번뿐이고, 배경과 미리 합성한 결과가 순차 blend 와 같다.
                        // 이전에는 `SRC_ALPHA` blend factor 가 8bit 로 양자화돼
                        // fringe 픽셀이 Linux · macOS 와 갈렸다.
                        const box_bg = cell_color.resolveBg(style_x, &raw, &colors, is_selected_x, is_inverse_x) orelse colors.background;
                        for (box_rects[0..bn]) |br| {
                            const cov_blend = ui_metrics.blendOverRgb(
                                .{ fg_rgb_x.r, fg_rgb_x.g, fg_rgb_x.b },
                                .{ box_bg.r, box_bg.g, box_bg.b },
                                br.cov,
                            );
                            bg_buf[block_count] = .{
                                .pos = .{ fx_box + br.x, fy + br.y },
                                .size = .{ br.w, br.h },
                                .color = .{ colorF(cov_blend[0]), colorF(cov_blend[1]), colorF(cov_blend[2]), 1 },
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
                        emitClusterInstance(self, text_buf[0..], &text_count, bg_buf[0..], &block_count, r, x, fy, cw, x_pad, fg_rgb, if (raw.wide == .wide) 2.0 else 1.0, 0);
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
                emitClusterInstance(self, text_buf[0..], &text_count, bg_buf[0..], &block_count, single_result, x, fy, cw, x_pad, fg_rgb, if (raw.wide == .wide) 2.0 else 1.0, 0);
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

        // --- Cursor (#297 — 세로 막대 bar, 세 platform 공통) ---
        // 셀 좌측에 opaque bar. wide char 는 wide_tail 보정으로 글자 시작
        // cell 의 좌측에 위치. 폭은 `ui_metrics.CURSOR_BAR_W_PT` × DPI scale.
        if (self.render_state.cursor.visible) {
            if (self.render_state.cursor.viewport) |vp| {
                var cursor_x: f32 = @floatFromInt(vp.x);
                const cursor_y: f32 = @floatFromInt(vp.y);
                if (vp.wide_tail and vp.x > 0) cursor_x -= 1.0;
                const cx0 = cursor_x * cw + x_pad;
                const cy0 = cursor_y * ch + y_off;
                var cursor_color: [4]f32 = .{ 180.0 / 255.0, 180.0 / 255.0, 180.0 / 255.0, 1.0 };
                if (colors.cursor) |cc| {
                    cursor_color = .{ colorF(cc.r), colorF(cc.g), colorF(cc.b), 1.0 };
                }
                const cursor_inst = [1]BgInstance{.{
                    .pos = .{ cx0, cy0 },
                    .size = .{ ui_metrics.cursorBarWidthPx(self.pixels_per_dip), ch },
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
                    // #299 — 강조 블록(w_cells 셀) 안 가운데 정렬 (본문과 동일 정책).
                    const pre_center: f32 = if (entry.advance > 0) @floor((w_cells * cw - entry.advance) / 2.0) else 0;
                    const gx = cell_x + pre_center + @as(f32, @floatFromInt(entry.bearing_x));
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
            @floatFromInt(scrollbar_y_offset),
            @floatFromInt(padding),
            @floatFromInt(scrollbar_min_thumb_h),
        )) |h| {
            const sbw: f32 = @floatFromInt(scrollbar_w);
            const vp_wf: f32 = @floatFromInt(vp_w);
            const track_x: f32 = vp_wf - sbw;
            // #344 — 정수 픽셀 스냅은 공통 `scrollbar.thumbPx`. 세 platform 이
            // 같은 값을 그려 track 위·아래 여백이 항상 같다.
            const t = h.thumb();
            // #346 — 섞는 색을 배경 명도로 뒤집는다. 판정 입력은 terminal 의
            // 현재 배경 (OSC 11 · reverse_colors 반영된 `RenderState.Colors`)
            // 이라 셸이 배경을 바꿔도 thumb 이 따라 전환된다.
            //
            // #353 — 합성은 `scrollbarColor` 가 이미 끝냈고 여기서는 알파 1.0 으로
            // 그린다. 이전에는 알파를 그대로 넘겨 `SRC_ALPHA` blend factor 가 곱했고,
            // 그 factor 가 render target 정밀도(8bit)로 양자화되는 하드웨어 동작
            // 때문에 Linux(CPU 버림) · macOS(고정밀 반올림) 와 값이 갈렸다.
            const sb_bg = [3]u8{ colors.background.r, colors.background.g, colors.background.b };
            const sb_dark = themes.isDarkRgb(colors.background.r, colors.background.g, colors.background.b);
            const sb_col = ui_metrics.scrollbarColor(sb_bg, sb_dark);
            const scrollbar_inst = [1]BgInstance{.{
                .pos = .{ track_x, @floatCast(t.top) },
                .size = .{ sbw, @floatCast(t.h) },
                .color = .{ colorF(sb_col[0]), colorF(sb_col[1]), colorF(sb_col[2]), 1 },
            }};
            self.drawBgInstances(&scrollbar_inst);
        }

        if (y_offset == 0) self.drawSingleControlStrip(control_layout, control_hover);
        if (menu_ui.open) self.drawCommandMenu(vp_w, @intCast(self.vp_height), menu_ui, toggle_hotkey);

        perf.addTimed(&perf.render, render_t0);

        // Present
        const present_t0 = perf.now();
        _ = self.swap_chain.Present(1, 0);
        perf.addTimed(&perf.present, present_t0);
    }

    /// #329 — 단일 탭 terminal 위에 우측 `[+][×][…]`만 최종 합성한다.
    fn drawSingleControlStrip(self: *D3d11Renderer, layout: TabBarLayout, hover: tab_layout.Area) void {
        const h = ui_metrics.scaledPxF(ui_metrics.TAB_BAR_HEIGHT_PT, self.pixels_per_dip);
        const gap = ui_metrics.tabGapPx(self.pixels_per_dip);
        // #343 — 컨트롤 bg fill · hover 는 탭바 경로와 같은 `tab_chrome`
        // (`buildControlsOnly`) 이 만든다. 탭바 전체 배경 · 밑줄 · 구분선은
        // 단일 탭 overlay 에 없으므로 컨트롤 구간만 쓴다.
        const chrome_in = tab_chrome.Inputs{
            .viewport_w = 0,
            .tab_bar_h = h,
            .tab_w = 0,
            .sep_w = 0,
            .underline_h = 0,
            .hover_inset = gap.control_hover_inset,
            .tab_count = 0,
            .active_idx = 0,
            .scroll_x = 0,
            .drag = null,
            .layout = layout,
            .hover = hover,
            .palette = &self.chrome,
        };
        var chrome_rects: [tab_chrome.maxRects(0)]tab_chrome.Rect = undefined;
        var bg: [tab_chrome.maxRects(0)]BgInstance = undefined;
        var bg_n: usize = 0;
        for (tab_chrome.buildControlsOnly(&chrome_rects, chrome_in)) |r| {
            bg[bg_n] = bgFromChrome(r);
            bg_n += 1;
        }
        if (bg_n > 0) self.drawBgInstances(bg[0..bg_n]);

        var icons: [3]TextInstance = undefined;
        var icon_n: u32 = 0;
        const size: u32 = ui_metrics.scaledPx(u32, ui_metrics.TAB_ICON_SIZE_PT, self.pixels_per_dip);
        const stroke = ui_metrics.strokePx(ui_metrics.TAB_ICON_STROKE_PT, self.pixels_per_dip);
        const more_stroke = ui_metrics.strokePx(ui_metrics.TAB_MORE_DOT_DIAMETER_PT, self.pixels_per_dip);
        const emit = struct {
            fn icon(r: *D3d11Renderer, kind: tab_icons.Icon, x: f32, w: f32, bar_h: f32, icon_size: u32, icon_stroke: f32, out: []TextInstance, n: *u32) void {
                if (w <= 0 or n.* >= out.len) return;
                const entry = r.tab_atlas.getOrInsertIcon(kind, icon_size, icon_stroke) orelse return;
                const sf: f32 = @floatFromInt(icon_size);
                out[n.*] = .{
                    .pos = .{ x + (w - sf) * 0.5, (bar_h - sf) * 0.5 },
                    .size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                    .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
                    .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                    .fg_color = r.chrome.ctrl_active,
                };
                n.* += 1;
            }
        }.icon;
        emit(self, .plus, layout.plus_x, layout.plus_w, h, size, stroke, &icons, &icon_n);
        emit(self, .close, layout.close_x, layout.close_w, h, size, stroke, &icons, &icon_n);
        emit(self, .more, layout.more_x, layout.more_w, h, size, more_stroke, &icons, &icon_n);
        if (icon_n > 0) self.drawTextInstancesWithAtlas(icons[0..icon_n], &self.tab_atlas);
    }

    fn drawCommandMenu(self: *D3d11Renderer, viewport_w: c_int, viewport_h: c_int, ui: command_menu.Ui, toggle_hotkey: []const u8) void {
        const scale = self.pixels_per_dip;
        // #329 — viewport 높이에 맞춰 entry 단위로 자른 View. 안 보이는 entry
        // 는 그리지 않는다 (부분 행 없음 — scroll 은 first_visible 로).
        const v = command_menu.view(
            @as(f32, @floatFromInt(viewport_w)) / scale,
            @as(f32, @floatFromInt(viewport_h)) / scale,
            @floatFromInt(ui_metrics.TAB_BAR_HEIGHT_PT),
            ui.first_visible,
        );
        const mx = v.rect.x * scale;
        const my = v.rect.y * scale;
        const mw = v.rect.w * scale;
        const mh = v.rect.h * scale;
        const bg_color = self.chrome.tab_bar_bg;
        // 내부 구분선은 1 logical pt — HiDPI 에서 상대 두께 유지 (#329).
        const line_px = @max(1.0, scale);
        // #342 — 메뉴 **외곽선 없음** (2026-07-27 시연 후 사용자 확정). 탭바에서
        // 가로 경계선을 없앤 것과 같은 문법: chrome 과 terminal 의 경계는 배경
        // 명도 차이만으로 둔다. 내부 구분선은 유지 (역할이 다름 — 면의 경계가
        // 아니라 항목 그룹).
        //
        // 이전 테두리는 `my - line_px` 라 탭바 마지막 행을 1px 침범했는데,
        // 같은 색 가로 경계선이 그 자리를 덮고 있어 보이지 않았다. 가로선을
        // 없애자 드러난 것 — 덮어써서 가려지던 지오메트리 오류였다.
        var boxes = [_]BgInstance{
            .{ .pos = .{ mx, my }, .size = .{ mw, mh }, .color = bg_color },
        };
        self.drawBgInstances(&boxes);
        for (v.first..v.first + v.count) |i| {
            if (command_menu.entries[i] != null) continue;
            const r = command_menu.entryRect(v, i).?;
            const sep = [1]BgInstance{.{
                .pos = .{ mx + 8 * scale, (r.y + r.h / 2) * scale },
                .size = .{ mw - 16 * scale, line_px },
                .color = self.chrome.separator,
            }};
            self.drawBgInstances(&sep);
        }
        // 강조는 pointer hover 우선, 없으면 keyboard focus.
        if (ui.hover orelse ui.focused) |command| {
            if (command_menu.itemRect(v, command)) |item| {
                const hover_bg = [1]BgInstance{.{
                    .pos = .{ (item.x + 2) * scale, (item.y + 1) * scale },
                    .size = .{ (item.w - 4) * scale, (item.h - 2) * scale },
                    .color = self.chrome.menu_hover_bg,
                }};
                self.drawBgInstances(&hover_bg);
            }
        }

        // #334 — 잘림 상태의 상/하단 스크롤 표시 행 (탭바 `<`/`>` 관례:
        // 끝에 닿으면 비활성 색, 클릭 = 한 entry 스크롤).
        if (v.clipped) {
            const ind_size: u32 = ui_metrics.scaledPx(u32, ui_metrics.MENU_INDICATOR_ICON_PT, scale);
            const ind_stroke = ui_metrics.strokePx(ui_metrics.TAB_ICON_STROKE_PT, scale);
            const size_f: f32 = @floatFromInt(ind_size);
            const ind_cx = mx + mw * 0.5 - size_f * 0.5;
            const up_y = (v.rect.y + command_menu.PADDING_PT + command_menu.INDICATOR_HEIGHT_PT * 0.5) * scale - size_f * 0.5;
            const down_y = (v.rect.y + v.rect.h - command_menu.PADDING_PT - command_menu.INDICATOR_HEIGHT_PT * 0.5) * scale - size_f * 0.5;
            const pairs = [2]struct { kind: tab_icons.Icon, y: f32, enabled: bool }{
                .{ .kind = .chevron_up, .y = up_y, .enabled = v.can_scroll_up },
                .{ .kind = .chevron_down, .y = down_y, .enabled = v.can_scroll_down },
            };
            var ind: [2]TextInstance = undefined;
            var ind_n: u32 = 0;
            for (pairs) |p| {
                const entry = self.tab_atlas.getOrInsertIcon(p.kind, ind_size, ind_stroke) orelse continue;
                ind[ind_n] = .{
                    .pos = .{ ind_cx, p.y },
                    .size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                    .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
                    .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                    .fg_color = if (p.enabled) self.chrome.ctrl_active else self.chrome.arrow_disabled,
                };
                ind_n += 1;
            }
            if (ind_n > 0) self.drawTextInstancesWithAtlas(ind[0..ind_n], &self.tab_atlas);
        }

        var glyphs: [512]TextInstance = undefined;
        var glyph_n: u32 = 0;
        const cw: f32 = @floatFromInt(self.tab_font.cell_width_px);
        const ch: f32 = @floatFromInt(self.tab_font.cell_height_px);
        const emit = struct {
            fn text(r: *D3d11Renderer, bytes: []const u8, start_x: f32, baseline: f32, color: [4]f32, out: []TextInstance, n: *u32) void {
                var x = start_x;
                var iter = std.unicode.Utf8Iterator{ .bytes = bytes, .i = 0 };
                while (iter.nextCodepoint()) |cp| {
                    if (n.* >= out.len) return;
                    const result = r.tab_font.resolveGlyph(cp) orelse continue;
                    const entry = r.tab_atlas.getOrInsert(result.face, result.index) orelse {
                        if (result.owned) _ = result.face.vtable.Release(result.face);
                        continue;
                    };
                    if (result.owned) _ = result.face.vtable.Release(result.face);
                    if (entry.w > 0 and entry.h > 0) {
                        out[n.*] = .{
                            .pos = .{ x + @as(f32, @floatFromInt(entry.bearing_x)), baseline + @as(f32, @floatFromInt(entry.bearing_y)) },
                            .size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                            .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
                            .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                            .fg_color = color,
                        };
                        n.* += 1;
                    }
                    x += @as(f32, @floatFromInt(display_width.codepointWidth(@intCast(cp)))) * @as(f32, @floatFromInt(r.tab_font.cell_width_px));
                }
            }
        }.text;
        for (v.first..v.first + v.count) |i| {
            const command = command_menu.entries[i] orelse continue;
            const item = command_menu.entryRect(v, i).?;
            const ix = item.x * scale;
            const iy = item.y * scale;
            const iw = item.w * scale;
            const ih = item.h * scale;
            const baseline = iy + (ih + self.tab_font.ascent_px - (ch - self.tab_font.ascent_px)) / 2;
            emit(self, command_menu.label(command), ix + 8 * scale, baseline, self.chrome.menu_label, &glyphs, &glyph_n);
            const hint = command_menu.shortcut(command, false, toggle_hotkey, ui.fullscreen_workarea);
            if (hint.len > 0) {
                const hint_w = @as(f32, @floatFromInt(display_width.stringWidth(hint))) * cw;
                const label_w = @as(f32, @floatFromInt(display_width.stringWidth(command_menu.label(command)))) * cw;
                // #329 — 좁은 메뉴 / 긴 configured hotkey 에서 label 과 겹치면
                // hint 를 먼저 숨긴다 (label 우선 정책, 세 renderer 공통).
                if (command_menu.hintFits(item.w, label_w / scale, hint_w / scale)) {
                    emit(self, hint, ix + iw - 8 * scale - hint_w, baseline, self.chrome.menu_hint, &glyphs, &glyph_n);
                }
            }
        }
        if (glyph_n > 0) self.drawTextInstancesWithAtlas(glyphs[0..glyph_n], &self.tab_atlas);
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
        self.drawTextInstancesWithAtlas(instances, &self.atlas);
    }

    fn drawTextInstancesWithAtlas(self: *D3d11Renderer, instances: []const TextInstance, atlas: *const GlyphAtlas) void {
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
        const srvs = [1]?*d3d.ID3D11ShaderResourceView{atlas.srv};
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
        /// #299 — 글리프를 배정된 셀 영역(span×cw) 가운데 정렬 (Linux 의
        /// `(cell_w − advance)/2` 와 동일 정책, 정수 px floor). null = 정렬
        /// 안 함 (ligature 경로 — GPOS offset 사용, ASCII 라 center ≈ 0).
        span_cells: ?f32,
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

        const center: f32 = if (span_cells) |span| blk: {
            if (entry.advance <= 0) break :blk 0;
            break :blk @floor((span * cw - entry.advance) / 2.0);
        } else 0;
        const fx: f32 = @as(f32, @floatFromInt(x)) * cw + x_pad + dx + center;
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
        self.emitClusterInstance(text_buf, text_count, bg_buf, block_count, result, x, fy, cw, x_pad, fg_rgb, null, dx);
    }

    // --- Color helpers ---

    /// 색 해석 정책은 공유 모듈 `cell_color.zig` (#282 B2). 여기선 null
    /// (= cell 고유 bg 없음) 을 default-bg float 로 변환만 — 호출부가
    /// is_custom_bg 로 instance 생략하므로 실제로는 도달 안 하는 방어값.
    fn resolveBg(style: ghostty.Style, raw: *const ghostty.Cell, colors: *const ghostty.RenderState.Colors, is_selected: bool, is_inverse: bool, dbg_r: f32, dbg_g: f32, dbg_b: f32) [3]f32 {
        if (cell_color.resolveBg(style, raw, colors, is_selected, is_inverse)) |rgb| {
            return .{ colorF(rgb.r), colorF(rgb.g), colorF(rgb.b) };
        }
        return .{ dbg_r, dbg_g, dbg_b };
    }

    const resolveFg = cell_color.resolveFg;

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
