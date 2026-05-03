// Direct2D 바인딩 — D3D11 backed render target (#136 컬러 emoji 품질 개선).
//
// Win Terminal 의 BackendD3D 와 동일한 path: 임시 D3D11 Texture2D (BIND_RENDER_TARGET)
// → IDXGISurface QI → D2D `CreateDxgiSurfaceRenderTarget` → BeginDraw +
// SetTextAntialiasMode(GRAYSCALE) + DrawGlyphRun + EndDraw → CopySubresourceRegion
// 으로 atlas 의 packed 위치에 GPU-to-GPU 복사 (CPU staging 불필요).
//
// WIC bitmap RT (software, CPU memory) 와 비교 시 hardware antialias 가 적용되어
// 작은 사이즈 emoji 의 가장자리 부드러움. CoInit 는 D2D path 에서 불필요
// (CoCreateInstance 안 씀, D2D1CreateFactory 가 자체 COM 초기화).

const std = @import("std");

const HRESULT = i32;
const FLOAT = f32;
const UINT32 = u32;

pub const GUID = extern struct { d1: u32, d2: u16, d3: u16, d4: [8]u8 };

// {06152247-6F50-465A-9245-118BFD3B6007}
pub const IID_ID2D1Factory = GUID{ .d1 = 0x06152247, .d2 = 0x6F50, .d3 = 0x465A, .d4 = .{ 0x92, 0x45, 0x11, 0x8B, 0xFD, 0x3B, 0x60, 0x07 } };

// --- D2D enums / structs ---

pub const D2D1_FACTORY_TYPE_SINGLE_THREADED: u32 = 0;
pub const D2D1_RENDER_TARGET_TYPE_DEFAULT: u32 = 0;
pub const D2D1_RENDER_TARGET_USAGE_NONE: u32 = 0;
pub const D2D1_FEATURE_LEVEL_DEFAULT: u32 = 0;
pub const D2D1_ALPHA_MODE_PREMULTIPLIED: u32 = 1;
pub const D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE: u32 = 2;

pub const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;

pub const D2D1_PIXEL_FORMAT = extern struct {
    format: u32,
    alphaMode: u32,
};

pub const D2D1_RENDER_TARGET_PROPERTIES = extern struct {
    type: u32,
    pixelFormat: D2D1_PIXEL_FORMAT,
    dpiX: FLOAT,
    dpiY: FLOAT,
    usage: u32,
    minLevel: u32,
};

pub const D2D1_COLOR_F = extern struct {
    r: FLOAT,
    g: FLOAT,
    b: FLOAT,
    a: FLOAT,
};

pub const D2D_POINT_2F = extern struct {
    x: FLOAT,
    y: FLOAT,
};

pub const D2D1_RECT_F = extern struct {
    left: FLOAT,
    top: FLOAT,
    right: FLOAT,
    bottom: FLOAT,
};

pub const D2D1_ANTIALIAS_MODE_ALIASED: u32 = 1;

// --- DLL exports ---

pub extern "d2d1" fn D2D1CreateFactory(
    factory_type: u32,
    riid: *const GUID,
    options: ?*const anyopaque,
    factory: *?*ID2D1Factory,
) callconv(.c) HRESULT;

// --- Forward decls ---
pub const ID2D1Factory = opaque {};
pub const ID2D1RenderTarget = opaque {};
pub const ID2D1Brush = opaque {};
pub const ID2D1SolidColorBrush = opaque {};

// ID2D1Factory: IUnknown(3) + 14 own = 17 vtable slots. CreateDxgiSurfaceRenderTarget
// 은 slot 15.
const ID2D1FactoryVTable = extern struct {
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const fn (*ID2D1Factory) callconv(.c) u32,
    ReloadSystemMetrics: *const anyopaque,
    GetDesktopDpi: *const anyopaque,
    CreateRectangleGeometry: *const anyopaque,
    CreateRoundedRectangleGeometry: *const anyopaque,
    CreateEllipseGeometry: *const anyopaque,
    CreateGeometryGroup: *const anyopaque,
    CreateTransformedGeometry: *const anyopaque,
    CreatePathGeometry: *const anyopaque,
    CreateStrokeStyle: *const anyopaque,
    CreateDrawingStateBlock: *const anyopaque,
    CreateWicBitmapRenderTarget: *const anyopaque,
    CreateHwndRenderTarget: *const anyopaque,
    /// 15: CreateDxgiSurfaceRenderTarget(*IDXGISurface, *const RT_PROPS, **RT)
    CreateDxgiSurfaceRenderTarget: *const fn (
        *ID2D1Factory,
        *anyopaque, // IDXGISurface
        *const D2D1_RENDER_TARGET_PROPERTIES,
        *?*ID2D1RenderTarget,
    ) callconv(.c) HRESULT,
    CreateDCRenderTarget: *const anyopaque,
};

pub fn factoryRelease(self: *ID2D1Factory) void {
    const vt: *const *const ID2D1FactoryVTable = @ptrCast(@alignCast(self));
    _ = vt.*.Release(self);
}

pub fn factoryCreateDxgiSurfaceRenderTarget(
    self: *ID2D1Factory,
    dxgi_surface: *anyopaque, // *IDXGISurface
    props: *const D2D1_RENDER_TARGET_PROPERTIES,
    out: *?*ID2D1RenderTarget,
) HRESULT {
    const vt: *const *const ID2D1FactoryVTable = @ptrCast(@alignCast(self));
    return vt.*.CreateDxgiSurfaceRenderTarget(self, dxgi_surface, props, out);
}

// ID2D1RenderTarget — 사용하는 method 만 typed, 나머지 anyopaque.
// slot 8: CreateSolidColorBrush, 29: DrawGlyphRun, 34: SetTextAntialiasMode,
// 47: Clear, 48: BeginDraw, 49: EndDraw.
const ID2D1RenderTargetVTable = extern struct {
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const fn (*ID2D1RenderTarget) callconv(.c) u32,
    GetFactory: *const anyopaque,
    CreateBitmap: *const anyopaque,
    CreateBitmapFromWicBitmap: *const anyopaque,
    CreateSharedBitmap: *const anyopaque,
    CreateBitmapBrush: *const anyopaque,
    CreateSolidColorBrush: *const fn (
        *ID2D1RenderTarget,
        *const D2D1_COLOR_F,
        ?*const anyopaque,
        *?*ID2D1SolidColorBrush,
    ) callconv(.c) HRESULT,
    CreateGradientStopCollection: *const anyopaque,
    CreateLinearGradientBrush: *const anyopaque,
    CreateRadialGradientBrush: *const anyopaque,
    CreateCompatibleRenderTarget: *const anyopaque,
    CreateLayer: *const anyopaque,
    CreateMesh: *const anyopaque,
    DrawLine: *const anyopaque,
    DrawRectangle: *const anyopaque,
    FillRectangle: *const anyopaque,
    DrawRoundedRectangle: *const anyopaque,
    FillRoundedRectangle: *const anyopaque,
    DrawEllipse: *const anyopaque,
    FillEllipse: *const anyopaque,
    DrawGeometry: *const anyopaque,
    FillGeometry: *const anyopaque,
    FillMesh: *const anyopaque,
    FillOpacityMask: *const anyopaque,
    DrawBitmap: *const anyopaque,
    DrawText: *const anyopaque,
    DrawTextLayout: *const anyopaque,
    DrawGlyphRun: *const fn (
        *ID2D1RenderTarget,
        D2D_POINT_2F,
        *const anyopaque, // *DWRITE_GLYPH_RUN
        *ID2D1Brush,
        u32,
    ) callconv(.c) void,
    SetTransform: *const anyopaque,
    GetTransform: *const anyopaque,
    SetAntialiasMode: *const anyopaque,
    GetAntialiasMode: *const anyopaque,
    SetTextAntialiasMode: *const fn (*ID2D1RenderTarget, u32) callconv(.c) void,
    GetTextAntialiasMode: *const anyopaque,
    SetTextRenderingParams: *const fn (*ID2D1RenderTarget, ?*anyopaque) callconv(.c) void,
    GetTextRenderingParams: *const anyopaque,
    SetTags: *const anyopaque,
    GetTags: *const anyopaque,
    PushLayer: *const anyopaque,
    PopLayer: *const anyopaque,
    Flush: *const anyopaque,
    SaveDrawingState: *const anyopaque,
    RestoreDrawingState: *const anyopaque,
    PushAxisAlignedClip: *const fn (*ID2D1RenderTarget, *const D2D1_RECT_F, u32) callconv(.c) void,
    PopAxisAlignedClip: *const fn (*ID2D1RenderTarget) callconv(.c) void,
    Clear: *const fn (*ID2D1RenderTarget, ?*const D2D1_COLOR_F) callconv(.c) void,
    BeginDraw: *const fn (*ID2D1RenderTarget) callconv(.c) void,
    EndDraw: *const fn (*ID2D1RenderTarget, ?*u64, ?*u64) callconv(.c) HRESULT,
    GetPixelFormat: *const anyopaque,
    SetDpi: *const anyopaque,
    GetDpi: *const anyopaque,
    GetSize: *const anyopaque,
    GetPixelSize: *const anyopaque,
    GetMaximumBitmapSize: *const anyopaque,
    IsSupported: *const anyopaque,
};

pub fn renderTargetRelease(self: *ID2D1RenderTarget) void {
    const vt: *const *const ID2D1RenderTargetVTable = @ptrCast(@alignCast(self));
    _ = vt.*.Release(self);
}

pub fn renderTargetCreateSolidColorBrush(
    self: *ID2D1RenderTarget,
    color: *const D2D1_COLOR_F,
    out: *?*ID2D1SolidColorBrush,
) HRESULT {
    const vt: *const *const ID2D1RenderTargetVTable = @ptrCast(@alignCast(self));
    return vt.*.CreateSolidColorBrush(self, color, null, out);
}

pub fn renderTargetDrawGlyphRun(
    self: *ID2D1RenderTarget,
    baseline: D2D_POINT_2F,
    glyph_run: *const anyopaque,
    brush: *ID2D1Brush,
    measuring_mode: u32,
) void {
    const vt: *const *const ID2D1RenderTargetVTable = @ptrCast(@alignCast(self));
    vt.*.DrawGlyphRun(self, baseline, glyph_run, brush, measuring_mode);
}

pub fn renderTargetSetTextAntialiasMode(self: *ID2D1RenderTarget, mode: u32) void {
    const vt: *const *const ID2D1RenderTargetVTable = @ptrCast(@alignCast(self));
    vt.*.SetTextAntialiasMode(self, mode);
}

/// IDWriteRenderingParams 를 D2D RT 에 적용. Win Terminal 동등 — gamma=1.0 등
/// 우리 mono path custom params 와 일치시켜 D2D 가 system default (gamma=1.8~2.2)
/// 로 그리지 않도록.
pub fn renderTargetSetTextRenderingParams(self: *ID2D1RenderTarget, params: ?*anyopaque) void {
    const vt: *const *const ID2D1RenderTargetVTable = @ptrCast(@alignCast(self));
    vt.*.SetTextRenderingParams(self, params);
}

pub fn renderTargetClear(self: *ID2D1RenderTarget, color: ?*const D2D1_COLOR_F) void {
    const vt: *const *const ID2D1RenderTargetVTable = @ptrCast(@alignCast(self));
    vt.*.Clear(self, color);
}

pub fn renderTargetBeginDraw(self: *ID2D1RenderTarget) void {
    const vt: *const *const ID2D1RenderTargetVTable = @ptrCast(@alignCast(self));
    vt.*.BeginDraw(self);
}

pub fn renderTargetEndDraw(self: *ID2D1RenderTarget) HRESULT {
    const vt: *const *const ID2D1RenderTargetVTable = @ptrCast(@alignCast(self));
    return vt.*.EndDraw(self, null, null);
}

pub fn renderTargetPushAxisAlignedClip(self: *ID2D1RenderTarget, rect: *const D2D1_RECT_F, mode: u32) void {
    const vt: *const *const ID2D1RenderTargetVTable = @ptrCast(@alignCast(self));
    vt.*.PushAxisAlignedClip(self, rect, mode);
}

pub fn renderTargetPopAxisAlignedClip(self: *ID2D1RenderTarget) void {
    const vt: *const *const ID2D1RenderTargetVTable = @ptrCast(@alignCast(self));
    vt.*.PopAxisAlignedClip(self);
}

// ID2D1SolidColorBrush extends ID2D1Brush extends ID2D1Resource extends IUnknown.
// vtable order: 0..2 IUnknown, 3 GetFactory (Resource), 4 SetOpacity (Brush),
// 5 SetTransform, 6 GetOpacity, 7 GetTransform, 8 SetColor (SolidColorBrush),
// 9 GetColor.
const ID2D1SolidColorBrushVTable = extern struct {
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const fn (*ID2D1SolidColorBrush) callconv(.c) u32,
    GetFactory: *const anyopaque,
    SetOpacity: *const anyopaque,
    SetTransform: *const anyopaque,
    GetOpacity: *const anyopaque,
    GetTransform: *const anyopaque,
    /// 8: SetColor(*const D2D1_COLOR_F)
    SetColor: *const fn (*ID2D1SolidColorBrush, *const D2D1_COLOR_F) callconv(.c) void,
    GetColor: *const anyopaque,
};

pub fn brushRelease(self: *ID2D1SolidColorBrush) void {
    const vt: *const *const ID2D1SolidColorBrushVTable = @ptrCast(@alignCast(self));
    _ = vt.*.Release(self);
}

pub fn brushAsBrush(self: *ID2D1SolidColorBrush) *ID2D1Brush {
    return @ptrCast(self);
}

/// SolidColorBrush 의 색을 변경 (재사용용). Win Terminal 처럼 brush 한 번 만들고
/// layer 마다 SetColor 만 호출.
pub fn brushSetColor(self: *ID2D1SolidColorBrush, color: *const D2D1_COLOR_F) void {
    const vt: *const *const ID2D1SolidColorBrushVTable = @ptrCast(@alignCast(self));
    vt.*.SetColor(self, color);
}
