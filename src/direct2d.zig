// Direct2D COM interface definitions for TildaZ renderer.
// All vtable slots match Windows SDK d2d1.h order.

const std = @import("std");
const dw = @import("directwrite.zig");

pub const HRESULT = c_long;
pub const FLOAT = f32;
pub const BOOL = std.os.windows.BOOL;
pub const HWND = ?*anyopaque;

pub const GUID = dw.GUID;

// --- GUIDs ---

pub const IID_ID2D1Factory = GUID{
    .Data1 = 0x06152247,
    .Data2 = 0x6f50,
    .Data3 = 0x465a,
    .Data4 = .{ 0x92, 0x45, 0x11, 0x8b, 0xfd, 0x3b, 0x60, 0x07 },
};

// --- Enums / Constants ---

pub const D2D1_FACTORY_TYPE_SINGLE_THREADED: u32 = 0;

pub const D2D1_RENDER_TARGET_TYPE_DEFAULT: u32 = 0;
pub const D2D1_RENDER_TARGET_TYPE_HARDWARE: u32 = 2;

pub const D2D1_PRESENT_OPTIONS_NONE: u32 = 0;
pub const D2D1_PRESENT_OPTIONS_IMMEDIATELY: u32 = 2;

pub const D2D1_TEXT_ANTIALIAS_MODE_DEFAULT: u32 = 0;
pub const D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE: u32 = 1;
pub const D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE: u32 = 2;

pub const D2D1_ANTIALIAS_MODE_PER_PRIMITIVE: u32 = 0;

pub const D2D1_ALPHA_MODE_UNKNOWN: u32 = 0;
pub const D2D1_ALPHA_MODE_PREMULTIPLIED: u32 = 1;
pub const D2D1_ALPHA_MODE_IGNORE: u32 = 3;

pub const D2D1_RENDER_TARGET_USAGE_NONE: u32 = 0;
pub const D2D1_FEATURE_LEVEL_DEFAULT: u32 = 0;

pub const DXGI_FORMAT_UNKNOWN: u32 = 0;
pub const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;

pub const DWRITE_MEASURING_MODE_NATURAL: u32 = 0;

// --- Structures ---

pub const D2D1_COLOR_F = extern struct {
    r: FLOAT = 0,
    g: FLOAT = 0,
    b: FLOAT = 0,
    a: FLOAT = 1,
};

pub const D2D1_RECT_F = extern struct {
    left: FLOAT,
    top: FLOAT,
    right: FLOAT,
    bottom: FLOAT,
};

pub const D2D1_POINT_2F = extern struct {
    x: FLOAT,
    y: FLOAT,
};

pub const D2D1_SIZE_U = extern struct {
    width: u32,
    height: u32,
};

pub const D2D1_SIZE_F = extern struct {
    width: FLOAT,
    height: FLOAT,
};

pub const D2D1_MATRIX_3X2_F = extern struct {
    m11: FLOAT = 1,
    m12: FLOAT = 0,
    m21: FLOAT = 0,
    m22: FLOAT = 1,
    dx: FLOAT = 0,
    dy: FLOAT = 0,
};

pub const D2D1_PIXEL_FORMAT = extern struct {
    format: u32 = DXGI_FORMAT_UNKNOWN,
    alphaMode: u32 = D2D1_ALPHA_MODE_UNKNOWN,
};

pub const D2D1_RENDER_TARGET_PROPERTIES = extern struct {
    type: u32 = D2D1_RENDER_TARGET_TYPE_DEFAULT,
    pixelFormat: D2D1_PIXEL_FORMAT = .{},
    dpiX: FLOAT = 0,
    dpiY: FLOAT = 0,
    usage: u32 = D2D1_RENDER_TARGET_USAGE_NONE,
    minLevel: u32 = D2D1_FEATURE_LEVEL_DEFAULT,
};

pub const D2D1_HWND_RENDER_TARGET_PROPERTIES = extern struct {
    hwnd: HWND = null,
    pixelSize: D2D1_SIZE_U = .{ .width = 0, .height = 0 },
    presentOptions: u32 = D2D1_PRESENT_OPTIONS_NONE,
};

// --- D2D1CreateFactory ---

pub extern "d2d1" fn D2D1CreateFactory(
    factoryType: u32,
    riid: *const GUID,
    pFactoryOptions: ?*const anyopaque,
    ppIFactory: *?*ID2D1Factory,
) callconv(.c) HRESULT;

// --- ID2D1Factory ---
// Inherits: IUnknown (3 slots)
// Own methods: 14 slots (3-16)

pub const ID2D1Factory = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown (0-2)
        QueryInterface: *const anyopaque,
        AddRef: *const fn (*ID2D1Factory) callconv(.c) u32,
        Release: *const fn (*ID2D1Factory) callconv(.c) u32,
        // ID2D1Factory (3-16)
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
        CreateHwndRenderTarget: *const fn (
            *ID2D1Factory,
            *const D2D1_RENDER_TARGET_PROPERTIES,
            *const D2D1_HWND_RENDER_TARGET_PROPERTIES,
            *?*ID2D1HwndRenderTarget,
        ) callconv(.c) HRESULT,
        CreateDxgiSurfaceRenderTarget: *const anyopaque,
        CreateDCRenderTarget: *const anyopaque,
    };

    pub fn Release(self: *ID2D1Factory) u32 {
        return self.vtable.Release(self);
    }

    pub fn CreateHwndRenderTarget(
        self: *ID2D1Factory,
        rt_props: *const D2D1_RENDER_TARGET_PROPERTIES,
        hwnd_props: *const D2D1_HWND_RENDER_TARGET_PROPERTIES,
        target: *?*ID2D1HwndRenderTarget,
    ) HRESULT {
        return self.vtable.CreateHwndRenderTarget(self, rt_props, hwnd_props, target);
    }
};

// --- ID2D1Brush (base) ---
// Used as parameter type for FillRectangle, DrawGlyphRun, etc.
// Inherits: IUnknown (3) + ID2D1Resource (1) = 4, own = 4 (slots 4-7)

pub const ID2D1Brush = extern struct {
    vtable: *const anyopaque,
};

// --- ID2D1SolidColorBrush ---
// Inherits: IUnknown (3) + ID2D1Resource (1) + ID2D1Brush (4) = 8
// Own methods: slots 8-9

pub const ID2D1SolidColorBrush = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown (0-2)
        QueryInterface: *const anyopaque,
        AddRef: *const fn (*ID2D1SolidColorBrush) callconv(.c) u32,
        Release: *const fn (*ID2D1SolidColorBrush) callconv(.c) u32,
        // ID2D1Resource (3)
        GetFactory: *const anyopaque,
        // ID2D1Brush (4-7)
        SetOpacity: *const fn (*ID2D1SolidColorBrush, FLOAT) callconv(.c) void,
        GetOpacity: *const anyopaque,
        SetTransform: *const anyopaque,
        GetTransform: *const anyopaque,
        // ID2D1SolidColorBrush (8-9)
        SetColor: *const fn (*ID2D1SolidColorBrush, *const D2D1_COLOR_F) callconv(.c) void,
        GetColor: *const anyopaque,
    };

    pub fn Release(self: *ID2D1SolidColorBrush) u32 {
        return self.vtable.Release(self);
    }

    pub fn SetColor(self: *ID2D1SolidColorBrush, color: *const D2D1_COLOR_F) void {
        self.vtable.SetColor(self, color);
    }

    pub fn SetOpacity(self: *ID2D1SolidColorBrush, opacity: FLOAT) void {
        self.vtable.SetOpacity(self, opacity);
    }

    /// Cast to ID2D1Brush for use in FillRectangle / DrawGlyphRun
    pub fn asBrush(self: *ID2D1SolidColorBrush) *ID2D1Brush {
        return @ptrCast(self);
    }
};

// --- ID2D1RenderTarget ---
// Inherits: IUnknown (3) + ID2D1Resource (1) = 4
// Own methods: 53 slots (4-56), total 57 slots
//
// Vtable order from d2d1.h:
//  4: CreateBitmap           27: DrawText
//  5: CreateBitmapFromWic    28: DrawTextLayout
//  6: CreateSharedBitmap     29: DrawGlyphRun
//  7: CreateBitmapBrush      30: SetTransform
//  8: CreateSolidColorBrush  31: GetTransform
//  9: CreateGradientStops    32: SetAntialiasMode
// 10: CreateLinearGradient   33: GetAntialiasMode
// 11: CreateRadialGradient   34: SetTextAntialiasMode
// 12: CreateCompatibleRT     35: GetTextAntialiasMode
// 13: CreateLayer            36: SetTextRenderingParams
// 14: CreateMesh             37: GetTextRenderingParams
// 15: DrawLine               38: SetTags
// 16: DrawRectangle          39: GetTags
// 17: FillRectangle          40: PushLayer
// 18: DrawRoundedRectangle   41: PopLayer
// 19: FillRoundedRectangle   42: Flush
// 20: DrawEllipse            43: SaveDrawingState
// 21: FillEllipse            44: RestoreDrawingState
// 22: DrawGeometry           45: PushAxisAlignedClip
// 23: FillGeometry           46: PopAxisAlignedClip
// 24: FillMesh               47: Clear
// 25: FillOpacityMask        48: BeginDraw
// 26: DrawBitmap             49: EndDraw
//                            50-56: GetPixelFormat..IsSupported

pub const ID2D1RenderTarget = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown (0-2)
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const anyopaque,
        // ID2D1Resource (3)
        GetFactory: *const anyopaque,
        // ID2D1RenderTarget (4-56)
        CreateBitmap: *const anyopaque, // 4
        CreateBitmapFromWicBitmap: *const anyopaque, // 5
        CreateSharedBitmap: *const anyopaque, // 6
        CreateBitmapBrush: *const anyopaque, // 7
        CreateSolidColorBrush: *const fn (*ID2D1RenderTarget, *const D2D1_COLOR_F, ?*const anyopaque, *?*ID2D1SolidColorBrush) callconv(.c) HRESULT, // 8
        CreateGradientStopCollection: *const anyopaque, // 9
        CreateLinearGradientBrush: *const anyopaque, // 10
        CreateRadialGradientBrush: *const anyopaque, // 11
        CreateCompatibleRenderTarget: *const anyopaque, // 12
        CreateLayer: *const anyopaque, // 13
        CreateMesh: *const anyopaque, // 14
        DrawLine: *const anyopaque, // 15
        DrawRectangle: *const anyopaque, // 16
        FillRectangle: *const fn (*ID2D1RenderTarget, *const D2D1_RECT_F, *ID2D1Brush) callconv(.c) void, // 17
        DrawRoundedRectangle: *const anyopaque, // 18
        FillRoundedRectangle: *const anyopaque, // 19
        DrawEllipse: *const anyopaque, // 20
        FillEllipse: *const anyopaque, // 21
        DrawGeometry: *const anyopaque, // 22
        FillGeometry: *const anyopaque, // 23
        FillMesh: *const anyopaque, // 24
        FillOpacityMask: *const anyopaque, // 25
        DrawBitmap: *const anyopaque, // 26
        DrawText: *const anyopaque, // 27
        DrawTextLayout: *const anyopaque, // 28
        DrawGlyphRun: *const fn (*ID2D1RenderTarget, D2D1_POINT_2F, *const dw.DWRITE_GLYPH_RUN, *ID2D1Brush, u32) callconv(.c) void, // 29
        SetTransform: *const fn (*ID2D1RenderTarget, *const D2D1_MATRIX_3X2_F) callconv(.c) void, // 30
        GetTransform: *const anyopaque, // 31
        SetAntialiasMode: *const fn (*ID2D1RenderTarget, u32) callconv(.c) void, // 32
        GetAntialiasMode: *const anyopaque, // 33
        SetTextAntialiasMode: *const fn (*ID2D1RenderTarget, u32) callconv(.c) void, // 34
        GetTextAntialiasMode: *const anyopaque, // 35
        SetTextRenderingParams: *const fn (*ID2D1RenderTarget, ?*dw.IDWriteRenderingParams) callconv(.c) void, // 36
        GetTextRenderingParams: *const anyopaque, // 37
        SetTags: *const anyopaque, // 38
        GetTags: *const anyopaque, // 39
        PushLayer: *const anyopaque, // 40
        PopLayer: *const anyopaque, // 41
        Flush: *const anyopaque, // 42
        SaveDrawingState: *const anyopaque, // 43
        RestoreDrawingState: *const anyopaque, // 44
        PushAxisAlignedClip: *const anyopaque, // 45
        PopAxisAlignedClip: *const anyopaque, // 46
        Clear: *const fn (*ID2D1RenderTarget, ?*const D2D1_COLOR_F) callconv(.c) void, // 47
        BeginDraw: *const fn (*ID2D1RenderTarget) callconv(.c) void, // 48
        EndDraw: *const fn (*ID2D1RenderTarget, ?*u64, ?*u64) callconv(.c) HRESULT, // 49
        GetPixelFormat: *const anyopaque, // 50
        SetDpi: *const fn (*ID2D1RenderTarget, FLOAT, FLOAT) callconv(.c) void, // 51
        GetDpi: *const anyopaque, // 52
        GetSize: *const anyopaque, // 53
        GetPixelSize: *const anyopaque, // 54
        GetMaximumBitmapSize: *const anyopaque, // 55
        IsSupported: *const anyopaque, // 56
    };

    pub fn CreateSolidColorBrush(self: *ID2D1RenderTarget, color: *const D2D1_COLOR_F, brush: *?*ID2D1SolidColorBrush) HRESULT {
        return self.vtable.CreateSolidColorBrush(self, color, null, brush);
    }

    pub fn FillRectangle(self: *ID2D1RenderTarget, rect: *const D2D1_RECT_F, brush: *ID2D1Brush) void {
        self.vtable.FillRectangle(self, rect, brush);
    }

    pub fn DrawGlyphRun(self: *ID2D1RenderTarget, origin: D2D1_POINT_2F, glyph_run: *const dw.DWRITE_GLYPH_RUN, brush: *ID2D1Brush, measuring_mode: u32) void {
        self.vtable.DrawGlyphRun(self, origin, glyph_run, brush, measuring_mode);
    }

    pub fn SetTransform(self: *ID2D1RenderTarget, transform: *const D2D1_MATRIX_3X2_F) void {
        self.vtable.SetTransform(self, transform);
    }

    pub fn SetAntialiasMode(self: *ID2D1RenderTarget, mode: u32) void {
        self.vtable.SetAntialiasMode(self, mode);
    }

    pub fn SetTextAntialiasMode(self: *ID2D1RenderTarget, mode: u32) void {
        self.vtable.SetTextAntialiasMode(self, mode);
    }

    pub fn SetTextRenderingParams(self: *ID2D1RenderTarget, params: ?*dw.IDWriteRenderingParams) void {
        self.vtable.SetTextRenderingParams(self, params);
    }

    pub fn Clear(self: *ID2D1RenderTarget, color: ?*const D2D1_COLOR_F) void {
        self.vtable.Clear(self, color);
    }

    pub fn BeginDraw(self: *ID2D1RenderTarget) void {
        self.vtable.BeginDraw(self);
    }

    pub fn EndDraw(self: *ID2D1RenderTarget) HRESULT {
        return self.vtable.EndDraw(self, null, null);
    }

    pub fn SetDpi(self: *ID2D1RenderTarget, dpi_x: FLOAT, dpi_y: FLOAT) void {
        self.vtable.SetDpi(self, dpi_x, dpi_y);
    }
};

// --- ID2D1HwndRenderTarget ---
// Inherits: ID2D1RenderTarget (57 slots)
// Own methods: slots 57-58

pub const ID2D1HwndRenderTarget = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown (0-2)
        QueryInterface: *const anyopaque,
        AddRef: *const fn (*ID2D1HwndRenderTarget) callconv(.c) u32,
        Release: *const fn (*ID2D1HwndRenderTarget) callconv(.c) u32,
        // ID2D1Resource (3)
        GetFactory: *const anyopaque,
        // ID2D1RenderTarget (4-56) — same layout as ID2D1RenderTarget.VTable
        CreateBitmap: *const anyopaque, // 4
        CreateBitmapFromWicBitmap: *const anyopaque, // 5
        CreateSharedBitmap: *const anyopaque, // 6
        CreateBitmapBrush: *const anyopaque, // 7
        CreateSolidColorBrush: *const fn (*ID2D1HwndRenderTarget, *const D2D1_COLOR_F, ?*const anyopaque, *?*ID2D1SolidColorBrush) callconv(.c) HRESULT, // 8
        CreateGradientStopCollection: *const anyopaque, // 9
        CreateLinearGradientBrush: *const anyopaque, // 10
        CreateRadialGradientBrush: *const anyopaque, // 11
        CreateCompatibleRenderTarget: *const anyopaque, // 12
        CreateLayer: *const anyopaque, // 13
        CreateMesh: *const anyopaque, // 14
        DrawLine: *const anyopaque, // 15
        DrawRectangle: *const anyopaque, // 16
        FillRectangle: *const fn (*ID2D1HwndRenderTarget, *const D2D1_RECT_F, *ID2D1Brush) callconv(.c) void, // 17
        DrawRoundedRectangle: *const anyopaque, // 18
        FillRoundedRectangle: *const anyopaque, // 19
        DrawEllipse: *const anyopaque, // 20
        FillEllipse: *const anyopaque, // 21
        DrawGeometry: *const anyopaque, // 22
        FillGeometry: *const anyopaque, // 23
        FillMesh: *const anyopaque, // 24
        FillOpacityMask: *const anyopaque, // 25
        DrawBitmap: *const anyopaque, // 26
        DrawText: *const anyopaque, // 27
        DrawTextLayout: *const anyopaque, // 28
        DrawGlyphRun: *const fn (*ID2D1HwndRenderTarget, D2D1_POINT_2F, *const dw.DWRITE_GLYPH_RUN, *ID2D1Brush, u32) callconv(.c) void, // 29
        SetTransform: *const fn (*ID2D1HwndRenderTarget, *const D2D1_MATRIX_3X2_F) callconv(.c) void, // 30
        GetTransform: *const anyopaque, // 31
        SetAntialiasMode: *const fn (*ID2D1HwndRenderTarget, u32) callconv(.c) void, // 32
        GetAntialiasMode: *const anyopaque, // 33
        SetTextAntialiasMode: *const fn (*ID2D1HwndRenderTarget, u32) callconv(.c) void, // 34
        GetTextAntialiasMode: *const anyopaque, // 35
        SetTextRenderingParams: *const fn (*ID2D1HwndRenderTarget, ?*dw.IDWriteRenderingParams) callconv(.c) void, // 36
        GetTextRenderingParams: *const anyopaque, // 37
        SetTags: *const anyopaque, // 38
        GetTags: *const anyopaque, // 39
        PushLayer: *const anyopaque, // 40
        PopLayer: *const anyopaque, // 41
        Flush: *const anyopaque, // 42
        SaveDrawingState: *const anyopaque, // 43
        RestoreDrawingState: *const anyopaque, // 44
        PushAxisAlignedClip: *const anyopaque, // 45
        PopAxisAlignedClip: *const anyopaque, // 46
        Clear: *const fn (*ID2D1HwndRenderTarget, ?*const D2D1_COLOR_F) callconv(.c) void, // 47
        BeginDraw: *const fn (*ID2D1HwndRenderTarget) callconv(.c) void, // 48
        EndDraw: *const fn (*ID2D1HwndRenderTarget, ?*u64, ?*u64) callconv(.c) HRESULT, // 49
        GetPixelFormat: *const anyopaque, // 50
        SetDpi: *const fn (*ID2D1HwndRenderTarget, FLOAT, FLOAT) callconv(.c) void, // 51
        GetDpi: *const anyopaque, // 52
        GetSize: *const anyopaque, // 53
        GetPixelSize: *const anyopaque, // 54
        GetMaximumBitmapSize: *const anyopaque, // 55
        IsSupported: *const anyopaque, // 56
        // ID2D1HwndRenderTarget (57-58)
        CheckWindowState: *const anyopaque, // 57
        Resize: *const fn (*ID2D1HwndRenderTarget, *const D2D1_SIZE_U) callconv(.c) HRESULT, // 58
    };

    pub fn Release(self: *ID2D1HwndRenderTarget) u32 {
        return self.vtable.Release(self);
    }

    pub fn Resize(self: *ID2D1HwndRenderTarget, size: *const D2D1_SIZE_U) HRESULT {
        return self.vtable.Resize(self, size);
    }

    // Delegate to render target methods via direct vtable access
    pub fn BeginDraw(self: *ID2D1HwndRenderTarget) void {
        self.vtable.BeginDraw(self);
    }

    pub fn EndDraw(self: *ID2D1HwndRenderTarget) HRESULT {
        return self.vtable.EndDraw(self, null, null);
    }

    pub fn Clear(self: *ID2D1HwndRenderTarget, color: ?*const D2D1_COLOR_F) void {
        self.vtable.Clear(self, color);
    }

    pub fn FillRectangle(self: *ID2D1HwndRenderTarget, rect: *const D2D1_RECT_F, brush: *ID2D1Brush) void {
        self.vtable.FillRectangle(self, rect, brush);
    }

    pub fn DrawGlyphRun(self: *ID2D1HwndRenderTarget, origin: D2D1_POINT_2F, glyph_run: *const dw.DWRITE_GLYPH_RUN, brush: *ID2D1Brush, measuring_mode: u32) void {
        self.vtable.DrawGlyphRun(self, origin, glyph_run, brush, measuring_mode);
    }

    pub fn SetTransform(self: *ID2D1HwndRenderTarget, transform: *const D2D1_MATRIX_3X2_F) void {
        self.vtable.SetTransform(self, transform);
    }

    pub fn SetAntialiasMode(self: *ID2D1HwndRenderTarget, mode: u32) void {
        self.vtable.SetAntialiasMode(self, mode);
    }

    pub fn SetTextAntialiasMode(self: *ID2D1HwndRenderTarget, mode: u32) void {
        self.vtable.SetTextAntialiasMode(self, mode);
    }

    pub fn SetTextRenderingParams(self: *ID2D1HwndRenderTarget, params: ?*dw.IDWriteRenderingParams) void {
        self.vtable.SetTextRenderingParams(self, params);
    }

    pub fn CreateSolidColorBrush(self: *ID2D1HwndRenderTarget, color: *const D2D1_COLOR_F, brush: *?*ID2D1SolidColorBrush) HRESULT {
        return self.vtable.CreateSolidColorBrush(self, color, null, brush);
    }

    pub fn SetDpi(self: *ID2D1HwndRenderTarget, dpi_x: FLOAT, dpi_y: FLOAT) void {
        self.vtable.SetDpi(self, dpi_x, dpi_y);
    }
};
