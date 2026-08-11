// D3D11 / DXGI COM interface definitions for TildaZ renderer.
// All vtable slots match Windows SDK d3d11.h / dxgi.h order.

const std = @import("std");
const dw = @import("../../font/windows/directwrite.zig");

pub const HRESULT = c_long;
pub const FLOAT = f32;
pub const BOOL = std.os.windows.BOOL;
pub const HWND = ?*anyopaque;
pub const GUID = dw.GUID;

// --- GUIDs ---

pub const IID_ID3D11Texture2D = GUID{
    .Data1 = 0x6f15aaf2,
    .Data2 = 0xd208,
    .Data3 = 0x4e89,
    .Data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c },
};

// --- Constants ---

// `D3D_DRIVER_TYPE` (d3dcommon.h) — UNKNOWN=0 부터 선언 순서대로.
// https://learn.microsoft.com/en-us/windows/win32/api/d3dcommon/ne-d3dcommon-d3d_driver_type
pub const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;
/// #363 — GPU 를 못 쓸 때의 소프트웨어 래스터라이저. Microsoft 가 OS 에 내장해
/// 제공하며 같은 D3D11 API 로 동작해 셰이더 / 렌더러 코드가 그대로다. 이 값을
/// 넘기면 "런타임이 WARP device 를 만들고 하드웨어 device 는 초기화하지 않는다".
/// Windows 8 이상의 WARP 는 feature level 9_1~11_1 을 지원한다.
/// https://learn.microsoft.com/en-us/windows/win32/direct3darticles/directx-warp
pub const D3D_DRIVER_TYPE_WARP: u32 = 5;
pub const D3D11_SDK_VERSION: u32 = 7;
pub const D3D11_CREATE_DEVICE_DEBUG: u32 = 0x2;
pub const D3D11_CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;

pub const DXGI_FORMAT_R8G8B8A8_UNORM: u32 = 28;
pub const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;
pub const DXGI_FORMAT_R32_FLOAT: u32 = 41;
pub const DXGI_FORMAT_R32G32_FLOAT: u32 = 16;
pub const DXGI_FORMAT_R32G32B32A32_FLOAT: u32 = 2;

pub const DXGI_USAGE_RENDER_TARGET_OUTPUT: u32 = 0x20;
pub const DXGI_SWAP_EFFECT_DISCARD: u32 = 0;
pub const DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL: u32 = 3;
pub const DXGI_SWAP_EFFECT_FLIP_DISCARD: u32 = 4;

pub const D3D11_USAGE_DEFAULT: u32 = 0;
pub const D3D11_USAGE_DYNAMIC: u32 = 2;
pub const D3D11_USAGE_STAGING: u32 = 3;

pub const D3D11_BIND_VERTEX_BUFFER: u32 = 0x1;
pub const D3D11_BIND_CONSTANT_BUFFER: u32 = 0x4;
pub const D3D11_BIND_SHADER_RESOURCE: u32 = 0x8;
pub const D3D11_BIND_RENDER_TARGET: u32 = 0x20;

pub const D3D11_CPU_ACCESS_WRITE: u32 = 0x10000;
pub const D3D11_CPU_ACCESS_READ: u32 = 0x20000;

pub const D3D11_MAP_READ: u32 = 1;
pub const D3D11_MAP_WRITE_DISCARD: u32 = 4;

pub const D3D11_INPUT_PER_VERTEX_DATA: u32 = 0;
pub const D3D11_INPUT_PER_INSTANCE_DATA: u32 = 1;

pub const D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP: u32 = 5;

pub const D3D11_BLEND_ZERO: u32 = 1;
pub const D3D11_BLEND_ONE: u32 = 2;
pub const D3D11_BLEND_SRC_ALPHA: u32 = 5;
pub const D3D11_BLEND_INV_SRC_ALPHA: u32 = 6;
pub const D3D11_BLEND_SRC1_COLOR: u32 = 16;
pub const D3D11_BLEND_INV_SRC1_COLOR: u32 = 17;
pub const D3D11_BLEND_SRC1_ALPHA: u32 = 18;
pub const D3D11_BLEND_INV_SRC1_ALPHA: u32 = 19;
pub const D3D11_BLEND_OP_ADD: u32 = 1;

pub const D3D11_FILTER_MIN_MAG_MIP_POINT: u32 = 0;
pub const D3D11_TEXTURE_ADDRESS_CLAMP: u32 = 3;
pub const D3D11_COMPARISON_NEVER: u32 = 1;

pub const D3D11_COLOR_WRITE_ENABLE_ALL: u8 = 0xf;

pub const D3D11_APPEND_ALIGNED_ELEMENT: u32 = 0xffffffff;

// --- Structures ---

pub const DXGI_RATIONAL = extern struct {
    Numerator: u32 = 0,
    Denominator: u32 = 0,
};

pub const DXGI_SAMPLE_DESC = extern struct {
    Count: u32 = 1,
    Quality: u32 = 0,
};

pub const DXGI_MODE_DESC = extern struct {
    Width: u32 = 0,
    Height: u32 = 0,
    RefreshRate: DXGI_RATIONAL = .{},
    Format: u32 = 0,
    ScanlineOrdering: u32 = 0,
    Scaling: u32 = 0,
};

pub const DXGI_SWAP_CHAIN_DESC = extern struct {
    BufferDesc: DXGI_MODE_DESC = .{},
    SampleDesc: DXGI_SAMPLE_DESC = .{},
    BufferUsage: u32 = 0,
    BufferCount: u32 = 0,
    OutputWindow: HWND = null,
    Windowed: BOOL = 1,
    SwapEffect: u32 = 0,
    Flags: u32 = 0,
};

pub const D3D11_TEXTURE2D_DESC = extern struct {
    Width: u32,
    Height: u32,
    MipLevels: u32 = 1,
    ArraySize: u32 = 1,
    Format: u32,
    SampleDesc: DXGI_SAMPLE_DESC = .{},
    Usage: u32 = D3D11_USAGE_DEFAULT,
    BindFlags: u32 = 0,
    CPUAccessFlags: u32 = 0,
    MiscFlags: u32 = 0,
};

pub const D3D11_BUFFER_DESC = extern struct {
    ByteWidth: u32,
    Usage: u32 = D3D11_USAGE_DEFAULT,
    BindFlags: u32 = 0,
    CPUAccessFlags: u32 = 0,
    MiscFlags: u32 = 0,
    StructureByteStride: u32 = 0,
};

pub const D3D11_SUBRESOURCE_DATA = extern struct {
    pSysMem: ?*const anyopaque = null,
    SysMemPitch: u32 = 0,
    SysMemSlicePitch: u32 = 0,
};

pub const D3D11_MAPPED_SUBRESOURCE = extern struct {
    pData: ?*anyopaque = null,
    RowPitch: u32 = 0,
    DepthPitch: u32 = 0,
};

pub const D3D11_INPUT_ELEMENT_DESC = extern struct {
    SemanticName: [*:0]const u8,
    SemanticIndex: u32,
    Format: u32,
    InputSlot: u32,
    AlignedByteOffset: u32,
    InputSlotClass: u32,
    InstanceDataStepRate: u32,
};

pub const D3D11_VIEWPORT = extern struct {
    TopLeftX: FLOAT = 0,
    TopLeftY: FLOAT = 0,
    Width: FLOAT,
    Height: FLOAT,
    MinDepth: FLOAT = 0,
    MaxDepth: FLOAT = 1,
};

pub const D3D11_RENDER_TARGET_BLEND_DESC = extern struct {
    BlendEnable: BOOL = 0,
    SrcBlend: u32 = D3D11_BLEND_ONE,
    DestBlend: u32 = D3D11_BLEND_ZERO,
    BlendOp: u32 = D3D11_BLEND_OP_ADD,
    SrcBlendAlpha: u32 = D3D11_BLEND_ONE,
    DestBlendAlpha: u32 = D3D11_BLEND_ZERO,
    BlendOpAlpha: u32 = D3D11_BLEND_OP_ADD,
    RenderTargetWriteMask: u8 = D3D11_COLOR_WRITE_ENABLE_ALL,
};

pub const D3D11_BLEND_DESC = extern struct {
    AlphaToCoverageEnable: BOOL = 0,
    IndependentBlendEnable: BOOL = 0,
    RenderTarget: [8]D3D11_RENDER_TARGET_BLEND_DESC = [_]D3D11_RENDER_TARGET_BLEND_DESC{.{}} ** 8,
};

pub const D3D11_SAMPLER_DESC = extern struct {
    Filter: u32 = D3D11_FILTER_MIN_MAG_MIP_POINT,
    AddressU: u32 = D3D11_TEXTURE_ADDRESS_CLAMP,
    AddressV: u32 = D3D11_TEXTURE_ADDRESS_CLAMP,
    AddressW: u32 = D3D11_TEXTURE_ADDRESS_CLAMP,
    MipLODBias: FLOAT = 0,
    MaxAnisotropy: u32 = 1,
    ComparisonFunc: u32 = D3D11_COMPARISON_NEVER,
    BorderColor: [4]FLOAT = .{ 0, 0, 0, 0 },
    MinLOD: FLOAT = 0,
    MaxLOD: FLOAT = 0,
};

pub const D3D11_BOX = extern struct {
    left: u32,
    top: u32,
    front: u32 = 0,
    right: u32,
    bottom: u32,
    back: u32 = 1,
};

// --- Simple COM objects (only need Release) ---

pub const ID3D11Buffer = extern struct {
    vtable: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11Buffer) callconv(.c) u32,
    },
    pub fn Release(self: *ID3D11Buffer) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3D11Texture2D = extern struct {
    vtable: *const extern struct {
        QueryInterface: *const fn (*ID3D11Texture2D, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11Texture2D) callconv(.c) u32,
    },
    pub fn Release(self: *ID3D11Texture2D) u32 {
        return self.vtable.Release(self);
    }
    pub fn QueryInterface(self: *ID3D11Texture2D, riid: *const GUID, ppv: *?*anyopaque) HRESULT {
        return self.vtable.QueryInterface(self, riid, ppv);
    }
};

// IDXGISurface — D3D11 texture 를 D2D RT 의 backing 으로 사용하기 위해 ID3D11Texture2D
// 에서 QueryInterface 로 받음. D2D `CreateDxgiSurfaceRenderTarget` 의 인자.
// {CAFCB56C-6AC3-4889-BF47-9E23BBD260EC}
pub const IID_IDXGISurface = GUID{
    .Data1 = 0xCAFCB56C,
    .Data2 = 0x6AC3,
    .Data3 = 0x4889,
    .Data4 = .{ 0xBF, 0x47, 0x9E, 0x23, 0xBB, 0xD2, 0x60, 0xEC },
};

pub const IDXGISurface = extern struct {
    vtable: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IDXGISurface) callconv(.c) u32,
    },
    pub fn Release(self: *IDXGISurface) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3D11ShaderResourceView = extern struct {
    vtable: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11ShaderResourceView) callconv(.c) u32,
    },
    pub fn Release(self: *ID3D11ShaderResourceView) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3D11RenderTargetView = extern struct {
    vtable: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11RenderTargetView) callconv(.c) u32,
    },
    pub fn Release(self: *ID3D11RenderTargetView) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3D11VertexShader = extern struct {
    vtable: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11VertexShader) callconv(.c) u32,
    },
    pub fn Release(self: *ID3D11VertexShader) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3D11PixelShader = extern struct {
    vtable: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11PixelShader) callconv(.c) u32,
    },
    pub fn Release(self: *ID3D11PixelShader) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3D11InputLayout = extern struct {
    vtable: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11InputLayout) callconv(.c) u32,
    },
    pub fn Release(self: *ID3D11InputLayout) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3D11SamplerState = extern struct {
    vtable: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11SamplerState) callconv(.c) u32,
    },
    pub fn Release(self: *ID3D11SamplerState) u32 {
        return self.vtable.Release(self);
    }
};

pub const ID3D11BlendState = extern struct {
    vtable: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11BlendState) callconv(.c) u32,
    },
    pub fn Release(self: *ID3D11BlendState) u32 {
        return self.vtable.Release(self);
    }
};

// --- ID3D10Blob (ID3DBlob) ---
// IUnknown (3) + 2 own = 5

pub const ID3DBlob = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown (0-2)
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3DBlob) callconv(.c) u32,
        // ID3D10Blob (3-4)
        GetBufferPointer: *const fn (*ID3DBlob) callconv(.c) ?*anyopaque,
        GetBufferSize: *const fn (*ID3DBlob) callconv(.c) usize,
    };

    pub fn Release(self: *ID3DBlob) u32 {
        return self.vtable.Release(self);
    }
    pub fn GetBufferPointer(self: *ID3DBlob) ?*anyopaque {
        return self.vtable.GetBufferPointer(self);
    }
    pub fn GetBufferSize(self: *ID3DBlob) usize {
        return self.vtable.GetBufferSize(self);
    }
};

// --- IDXGISwapChain ---
// IUnknown (3) + IDXGIObject (4) + IDXGIDeviceSubObject (1) + IDXGISwapChain (10) = 18
//
// Slots:
//  0-2:  IUnknown (QueryInterface, AddRef, Release)
//  3-6:  IDXGIObject (SetPrivateData, SetPrivateDataInterface, GetPrivateData, GetParent)
//  7:    IDXGIDeviceSubObject (GetDevice)
//  8:    Present
//  9:    GetBuffer
// 10:    SetFullscreenState
// 11:    GetFullscreenState
// 12:    GetDesc
// 13:    ResizeBuffers
// 14-17: ResizeTarget, GetContainingOutput, GetFrameStatistics, GetLastPresentCount

pub const IDXGISwapChain = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown (0-2)
        QueryInterface: *const fn (*IDXGISwapChain, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const anyopaque,
        Release: *const fn (*IDXGISwapChain) callconv(.c) u32,
        // IDXGIObject (3-6)
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const fn (*IDXGISwapChain, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        // IDXGIDeviceSubObject (7)
        GetDevice: *const anyopaque,
        // IDXGISwapChain (8-17)
        Present: *const fn (*IDXGISwapChain, u32, u32) callconv(.c) HRESULT,
        GetBuffer: *const fn (*IDXGISwapChain, u32, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        SetFullscreenState: *const anyopaque,
        GetFullscreenState: *const anyopaque,
        GetDesc: *const anyopaque,
        ResizeBuffers: *const fn (*IDXGISwapChain, u32, u32, u32, u32, u32) callconv(.c) HRESULT,
    };

    pub fn QueryInterface(self: *IDXGISwapChain, riid: *const GUID, out: *?*anyopaque) HRESULT {
        return self.vtable.QueryInterface(self, riid, out);
    }
    pub fn Release(self: *IDXGISwapChain) u32 {
        return self.vtable.Release(self);
    }
    pub fn Present(self: *IDXGISwapChain, sync_interval: u32, flags: u32) HRESULT {
        return self.vtable.Present(self, sync_interval, flags);
    }
    pub fn GetBuffer(self: *IDXGISwapChain, buffer: u32, riid: *const GUID, surface: *?*anyopaque) HRESULT {
        return self.vtable.GetBuffer(self, buffer, riid, surface);
    }
    pub fn ResizeBuffers(self: *IDXGISwapChain, count: u32, w: u32, h: u32, fmt: u32, flags: u32) HRESULT {
        return self.vtable.ResizeBuffers(self, count, w, h, fmt, flags);
    }
    pub fn GetParent(self: *IDXGISwapChain, riid: *const GUID, parent: *?*anyopaque) HRESULT {
        return self.vtable.GetParent(self, riid, parent);
    }
};

// --- IDXGIFactory ---
// IUnknown (3) + IDXGIObject (4) + IDXGIFactory (5) = 12 slots.
// `MakeWindowAssociation` 만 사용 (#89) — DXGI 의 내장 Alt+Enter 감시가
// swap chain 을 exclusive fullscreen 으로 자동 전환하는 것을 차단.

pub const DXGI_MWA_NO_WINDOW_CHANGES: u32 = 1;
pub const DXGI_MWA_NO_ALT_ENTER: u32 = 2;

pub const IID_IDXGIFactory = GUID{
    .Data1 = 0x7b7166ec,
    .Data2 = 0x21c7,
    .Data3 = 0x44ae,
    .Data4 = .{ 0xb2, 0x1a, 0xc9, 0xae, 0x32, 0x1a, 0xe3, 0x69 },
};

pub const IDXGIFactory = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown (0-2)
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IDXGIFactory) callconv(.c) u32,
        // IDXGIObject (3-6)
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const anyopaque,
        // IDXGIFactory (7-11)
        EnumAdapters: *const anyopaque,
        MakeWindowAssociation: *const fn (*IDXGIFactory, ?*anyopaque, u32) callconv(.c) HRESULT,
        GetWindowAssociation: *const anyopaque,
        CreateSwapChain: *const anyopaque,
        CreateSoftwareAdapter: *const anyopaque,
    };

    pub fn Release(self: *IDXGIFactory) u32 {
        return self.vtable.Release(self);
    }
    pub fn MakeWindowAssociation(self: *IDXGIFactory, hwnd: ?*anyopaque, flags: u32) HRESULT {
        return self.vtable.MakeWindowAssociation(self, hwnd, flags);
    }
};

// --- ID3D11Device ---
// IUnknown (3) + 40 own methods = 43 vtable slots
//
// Slots:
//  0-2:  IUnknown
//  3:    CreateBuffer
//  4:    CreateTexture1D
//  5:    CreateTexture2D
//  6:    CreateTexture3D
//  7:    CreateShaderResourceView
//  8:    CreateUnorderedAccessView
//  9:    CreateRenderTargetView
// 10:    CreateDepthStencilView
// 11:    CreateInputLayout
// 12:    CreateVertexShader
// 13:    CreateGeometryShader
// 14:    CreateGeometryShaderWithStreamOutput
// 15:    CreatePixelShader
// 16:    CreateHullShader
// 17:    CreateDomainShader
// 18:    CreateComputeShader
// 19:    CreateClassLinkage
// 20:    CreateBlendState
// 21:    CreateDepthStencilState
// 22:    CreateRasterizerState
// 23:    CreateSamplerState
// 24-42: Query/Check/Get methods

pub const ID3D11Device = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (0-2)
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11Device) callconv(.c) u32,
        // ID3D11Device (3-42)
        CreateBuffer: *const fn (*ID3D11Device, *const D3D11_BUFFER_DESC, ?*const D3D11_SUBRESOURCE_DATA, *?*ID3D11Buffer) callconv(.c) HRESULT, // 3
        CreateTexture1D: *const anyopaque, // 4
        CreateTexture2D: *const fn (*ID3D11Device, *const D3D11_TEXTURE2D_DESC, ?*const D3D11_SUBRESOURCE_DATA, *?*ID3D11Texture2D) callconv(.c) HRESULT, // 5
        CreateTexture3D: *const anyopaque, // 6
        CreateShaderResourceView: *const fn (*ID3D11Device, *anyopaque, ?*const anyopaque, *?*ID3D11ShaderResourceView) callconv(.c) HRESULT, // 7
        CreateUnorderedAccessView: *const anyopaque, // 8
        CreateRenderTargetView: *const fn (*ID3D11Device, *anyopaque, ?*const anyopaque, *?*ID3D11RenderTargetView) callconv(.c) HRESULT, // 9
        CreateDepthStencilView: *const anyopaque, // 10
        CreateInputLayout: *const fn (*ID3D11Device, [*]const D3D11_INPUT_ELEMENT_DESC, u32, ?*const anyopaque, usize, *?*ID3D11InputLayout) callconv(.c) HRESULT, // 11
        CreateVertexShader: *const fn (*ID3D11Device, ?*const anyopaque, usize, ?*anyopaque, *?*ID3D11VertexShader) callconv(.c) HRESULT, // 12
        CreateGeometryShader: *const anyopaque, // 13
        CreateGeometryShaderWithStreamOutput: *const anyopaque, // 14
        CreatePixelShader: *const fn (*ID3D11Device, ?*const anyopaque, usize, ?*anyopaque, *?*ID3D11PixelShader) callconv(.c) HRESULT, // 15
        CreateHullShader: *const anyopaque, // 16
        CreateDomainShader: *const anyopaque, // 17
        CreateComputeShader: *const anyopaque, // 18
        CreateClassLinkage: *const anyopaque, // 19
        CreateBlendState: *const fn (*ID3D11Device, *const D3D11_BLEND_DESC, *?*ID3D11BlendState) callconv(.c) HRESULT, // 20
        CreateDepthStencilState: *const anyopaque, // 21
        CreateRasterizerState: *const anyopaque, // 22
        CreateSamplerState: *const fn (*ID3D11Device, *const D3D11_SAMPLER_DESC, *?*ID3D11SamplerState) callconv(.c) HRESULT, // 23
    };

    pub fn Release(self: *ID3D11Device) u32 {
        return self.vtable.Release(self);
    }

    pub fn CreateBuffer(self: *ID3D11Device, desc: *const D3D11_BUFFER_DESC, init_data: ?*const D3D11_SUBRESOURCE_DATA, buffer: *?*ID3D11Buffer) HRESULT {
        return self.vtable.CreateBuffer(self, desc, init_data, buffer);
    }

    pub fn CreateTexture2D(self: *ID3D11Device, desc: *const D3D11_TEXTURE2D_DESC, init_data: ?*const D3D11_SUBRESOURCE_DATA, texture: *?*ID3D11Texture2D) HRESULT {
        return self.vtable.CreateTexture2D(self, desc, init_data, texture);
    }

    pub fn CreateShaderResourceView(self: *ID3D11Device, resource: *anyopaque, desc: ?*const anyopaque, srv: *?*ID3D11ShaderResourceView) HRESULT {
        return self.vtable.CreateShaderResourceView(self, resource, desc, srv);
    }

    pub fn CreateRenderTargetView(self: *ID3D11Device, resource: *anyopaque, desc: ?*const anyopaque, rtv: *?*ID3D11RenderTargetView) HRESULT {
        return self.vtable.CreateRenderTargetView(self, resource, desc, rtv);
    }

    pub fn CreateInputLayout(self: *ID3D11Device, descs: [*]const D3D11_INPUT_ELEMENT_DESC, num: u32, bytecode: ?*const anyopaque, bytecode_len: usize, layout: *?*ID3D11InputLayout) HRESULT {
        return self.vtable.CreateInputLayout(self, descs, num, bytecode, bytecode_len, layout);
    }

    pub fn CreateVertexShader(self: *ID3D11Device, bytecode: ?*const anyopaque, len: usize, linkage: ?*anyopaque, shader: *?*ID3D11VertexShader) HRESULT {
        return self.vtable.CreateVertexShader(self, bytecode, len, linkage, shader);
    }

    pub fn CreatePixelShader(self: *ID3D11Device, bytecode: ?*const anyopaque, len: usize, linkage: ?*anyopaque, shader: *?*ID3D11PixelShader) HRESULT {
        return self.vtable.CreatePixelShader(self, bytecode, len, linkage, shader);
    }

    pub fn CreateBlendState(self: *ID3D11Device, desc: *const D3D11_BLEND_DESC, state: *?*ID3D11BlendState) HRESULT {
        return self.vtable.CreateBlendState(self, desc, state);
    }

    pub fn CreateSamplerState(self: *ID3D11Device, desc: *const D3D11_SAMPLER_DESC, state: *?*ID3D11SamplerState) HRESULT {
        return self.vtable.CreateSamplerState(self, desc, state);
    }
};

// --- ID3D11DeviceContext ---
// IUnknown (3) + ID3D11DeviceChild (4) + own methods
//
// Base slots 0-6:
//  0-2: IUnknown
//  3-6: ID3D11DeviceChild (GetDevice, GetPrivateData, SetPrivateData, SetPrivateDataInterface)
//
// Own methods starting at slot 7:
//  7:  VSSetConstantBuffers
//  8:  PSSetShaderResources
//  9:  PSSetShader
// 10:  PSSetSamplers
// 11:  VSSetShader
// 12:  DrawIndexed
// 13:  Draw
// 14:  Map
// 15:  Unmap
// 16:  PSSetConstantBuffers
// 17:  IASetInputLayout
// 18:  IASetVertexBuffers
// 19:  IASetIndexBuffer
// 20:  DrawIndexedInstanced
// 21:  DrawInstanced
// 22:  GSSetConstantBuffers
// 23:  GSSetShader
// 24:  IASetPrimitiveTopology
// 25-32: VS/GS/Begin/End/GetData/SetPredication/GS*
// 33:  OMSetRenderTargets
// 34:  OMSetRenderTargetsAndUnorderedAccessViews
// 35:  OMSetBlendState
// 36-43: OMSetDepthStencil/SO/DrawAuto/DrawIndirect/Dispatch/RSSetState
// 44:  RSSetViewports
// 45-47: RSSetScissorRects/CopySubresourceRegion/CopyResource
// 48:  UpdateSubresource
// 49:  CopyStructureCount
// 50:  ClearRenderTargetView

pub const ID3D11DeviceContext = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown (0-2)
        QueryInterface: *const anyopaque, // 0
        AddRef: *const anyopaque, // 1
        Release: *const fn (*ID3D11DeviceContext) callconv(.c) u32, // 2
        // ID3D11DeviceChild (3-6)
        GetDevice: *const anyopaque, // 3
        GetPrivateData: *const anyopaque, // 4
        SetPrivateData: *const anyopaque, // 5
        SetPrivateDataInterface: *const anyopaque, // 6
        // ID3D11DeviceContext own methods (7+)
        VSSetConstantBuffers: *const fn (*ID3D11DeviceContext, u32, u32, ?[*]const ?*ID3D11Buffer) callconv(.c) void, // 7
        PSSetShaderResources: *const fn (*ID3D11DeviceContext, u32, u32, ?[*]const ?*ID3D11ShaderResourceView) callconv(.c) void, // 8
        PSSetShader: *const fn (*ID3D11DeviceContext, ?*ID3D11PixelShader, ?*anyopaque, u32) callconv(.c) void, // 9
        PSSetSamplers: *const fn (*ID3D11DeviceContext, u32, u32, ?[*]const ?*ID3D11SamplerState) callconv(.c) void, // 10
        VSSetShader: *const fn (*ID3D11DeviceContext, ?*ID3D11VertexShader, ?*anyopaque, u32) callconv(.c) void, // 11
        DrawIndexed: *const anyopaque, // 12
        Draw: *const fn (*ID3D11DeviceContext, u32, u32) callconv(.c) void, // 13
        Map: *const fn (*ID3D11DeviceContext, *anyopaque, u32, u32, u32, *D3D11_MAPPED_SUBRESOURCE) callconv(.c) HRESULT, // 14
        Unmap: *const fn (*ID3D11DeviceContext, *anyopaque, u32) callconv(.c) void, // 15
        PSSetConstantBuffers: *const fn (*ID3D11DeviceContext, u32, u32, ?[*]const ?*ID3D11Buffer) callconv(.c) void, // 16
        IASetInputLayout: *const fn (*ID3D11DeviceContext, ?*ID3D11InputLayout) callconv(.c) void, // 17
        IASetVertexBuffers: *const fn (*ID3D11DeviceContext, u32, u32, ?[*]const ?*ID3D11Buffer, [*]const u32, [*]const u32) callconv(.c) void, // 18
        IASetIndexBuffer: *const anyopaque, // 19
        DrawIndexedInstanced: *const anyopaque, // 20
        DrawInstanced: *const fn (*ID3D11DeviceContext, u32, u32, u32, u32) callconv(.c) void, // 21
        GSSetConstantBuffers: *const anyopaque, // 22
        GSSetShader: *const anyopaque, // 23
        IASetPrimitiveTopology: *const fn (*ID3D11DeviceContext, u32) callconv(.c) void, // 24
        VSSetShaderResources: *const anyopaque, // 25
        VSSetSamplers: *const anyopaque, // 26
        Begin: *const anyopaque, // 27
        End: *const anyopaque, // 28
        GetData: *const anyopaque, // 29
        SetPredication: *const anyopaque, // 30
        GSSetShaderResources: *const anyopaque, // 31
        GSSetSamplers: *const anyopaque, // 32
        OMSetRenderTargets: *const fn (*ID3D11DeviceContext, u32, ?[*]const ?*ID3D11RenderTargetView, ?*anyopaque) callconv(.c) void, // 33
        OMSetRenderTargetsAndUnorderedAccessViews: *const anyopaque, // 34
        OMSetBlendState: *const fn (*ID3D11DeviceContext, ?*ID3D11BlendState, ?*const [4]FLOAT, u32) callconv(.c) void, // 35
        OMSetDepthStencilState: *const anyopaque, // 36
        SOSetTargets: *const anyopaque, // 37
        DrawAuto: *const anyopaque, // 38
        DrawIndexedInstancedIndirect: *const anyopaque, // 39
        DrawInstancedIndirect: *const anyopaque, // 40
        Dispatch: *const anyopaque, // 41
        DispatchIndirect: *const anyopaque, // 42
        RSSetState: *const anyopaque, // 43
        RSSetViewports: *const fn (*ID3D11DeviceContext, u32, [*]const D3D11_VIEWPORT) callconv(.c) void, // 44
        RSSetScissorRects: *const anyopaque, // 45
        CopySubresourceRegion: *const fn (*ID3D11DeviceContext, *anyopaque, u32, u32, u32, u32, *anyopaque, u32, ?*const D3D11_BOX) callconv(.c) void, // 46
        CopyResource: *const fn (*ID3D11DeviceContext, *anyopaque, *anyopaque) callconv(.c) void, // 47
        UpdateSubresource: *const fn (*ID3D11DeviceContext, *anyopaque, u32, ?*const D3D11_BOX, *const anyopaque, u32, u32) callconv(.c) void, // 48
        CopyStructureCount: *const anyopaque, // 49
        ClearRenderTargetView: *const fn (*ID3D11DeviceContext, *ID3D11RenderTargetView, *const [4]FLOAT) callconv(.c) void, // 50
    };

    pub fn Release(self: *ID3D11DeviceContext) u32 {
        return self.vtable.Release(self);
    }

    pub fn VSSetConstantBuffers(self: *ID3D11DeviceContext, slot: u32, num: u32, buffers: ?[*]const ?*ID3D11Buffer) void {
        self.vtable.VSSetConstantBuffers(self, slot, num, buffers);
    }
    pub fn PSSetShaderResources(self: *ID3D11DeviceContext, slot: u32, num: u32, srvs: ?[*]const ?*ID3D11ShaderResourceView) void {
        self.vtable.PSSetShaderResources(self, slot, num, srvs);
    }
    pub fn PSSetShader(self: *ID3D11DeviceContext, shader: ?*ID3D11PixelShader) void {
        self.vtable.PSSetShader(self, shader, null, 0);
    }
    pub fn PSSetSamplers(self: *ID3D11DeviceContext, slot: u32, num: u32, samplers: ?[*]const ?*ID3D11SamplerState) void {
        self.vtable.PSSetSamplers(self, slot, num, samplers);
    }
    pub fn VSSetShader(self: *ID3D11DeviceContext, shader: ?*ID3D11VertexShader) void {
        self.vtable.VSSetShader(self, shader, null, 0);
    }
    pub fn Draw(self: *ID3D11DeviceContext, vertex_count: u32, start: u32) void {
        self.vtable.Draw(self, vertex_count, start);
    }
    pub fn Map(self: *ID3D11DeviceContext, resource: *anyopaque, subresource: u32, map_type: u32, flags: u32, mapped: *D3D11_MAPPED_SUBRESOURCE) HRESULT {
        return self.vtable.Map(self, resource, subresource, map_type, flags, mapped);
    }
    pub fn Unmap(self: *ID3D11DeviceContext, resource: *anyopaque, subresource: u32) void {
        self.vtable.Unmap(self, resource, subresource);
    }
    pub fn PSSetConstantBuffers(self: *ID3D11DeviceContext, slot: u32, num: u32, buffers: ?[*]const ?*ID3D11Buffer) void {
        self.vtable.PSSetConstantBuffers(self, slot, num, buffers);
    }
    pub fn IASetInputLayout(self: *ID3D11DeviceContext, layout: ?*ID3D11InputLayout) void {
        self.vtable.IASetInputLayout(self, layout);
    }
    pub fn IASetVertexBuffers(self: *ID3D11DeviceContext, slot: u32, num: u32, buffers: ?[*]const ?*ID3D11Buffer, strides: [*]const u32, offsets: [*]const u32) void {
        self.vtable.IASetVertexBuffers(self, slot, num, buffers, strides, offsets);
    }
    pub fn DrawInstanced(self: *ID3D11DeviceContext, vertex_count: u32, instance_count: u32, start_vertex: u32, start_instance: u32) void {
        self.vtable.DrawInstanced(self, vertex_count, instance_count, start_vertex, start_instance);
    }
    pub fn IASetPrimitiveTopology(self: *ID3D11DeviceContext, topology: u32) void {
        self.vtable.IASetPrimitiveTopology(self, topology);
    }
    pub fn OMSetRenderTargets(self: *ID3D11DeviceContext, num: u32, rtvs: ?[*]const ?*ID3D11RenderTargetView, dsv: ?*anyopaque) void {
        self.vtable.OMSetRenderTargets(self, num, rtvs, dsv);
    }
    pub fn OMSetBlendState(self: *ID3D11DeviceContext, state: ?*ID3D11BlendState, factor: ?*const [4]FLOAT, mask: u32) void {
        self.vtable.OMSetBlendState(self, state, factor, mask);
    }
    pub fn RSSetViewports(self: *ID3D11DeviceContext, num: u32, viewports: [*]const D3D11_VIEWPORT) void {
        self.vtable.RSSetViewports(self, num, viewports);
    }
    pub fn UpdateSubresource(self: *ID3D11DeviceContext, resource: *anyopaque, subresource: u32, box: ?*const D3D11_BOX, data: *const anyopaque, row_pitch: u32, depth_pitch: u32) void {
        self.vtable.UpdateSubresource(self, resource, subresource, box, data, row_pitch, depth_pitch);
    }
    pub fn CopySubresourceRegion(self: *ID3D11DeviceContext, dst: *anyopaque, dst_subresource: u32, dst_x: u32, dst_y: u32, dst_z: u32, src: *anyopaque, src_subresource: u32, src_box: ?*const D3D11_BOX) void {
        self.vtable.CopySubresourceRegion(self, dst, dst_subresource, dst_x, dst_y, dst_z, src, src_subresource, src_box);
    }
    pub fn CopyResource(self: *ID3D11DeviceContext, dst: *anyopaque, src: *anyopaque) void {
        self.vtable.CopyResource(self, dst, src);
    }
    pub fn ClearRenderTargetView(self: *ID3D11DeviceContext, rtv: *ID3D11RenderTargetView, color: *const [4]FLOAT) void {
        self.vtable.ClearRenderTargetView(self, rtv, color);
    }
};

// --- Extern functions ---

pub extern "d3d11" fn D3D11CreateDeviceAndSwapChain(
    pAdapter: ?*anyopaque,
    DriverType: u32,
    Software: ?*anyopaque,
    Flags: u32,
    pFeatureLevels: ?*const u32,
    FeatureLevels: u32,
    SDKVersion: u32,
    pSwapChainDesc: *const DXGI_SWAP_CHAIN_DESC,
    ppSwapChain: *?*IDXGISwapChain,
    ppDevice: *?*ID3D11Device,
    pFeatureLevel: ?*u32,
    ppImmediateContext: *?*ID3D11DeviceContext,
) callconv(.c) HRESULT;

pub extern "d3dcompiler_47" fn D3DCompile(
    pSrcData: [*]const u8,
    SrcDataSize: usize,
    pSourceName: ?[*:0]const u8,
    pDefines: ?*const anyopaque,
    pInclude: ?*anyopaque,
    pEntrypoint: [*:0]const u8,
    pTarget: [*:0]const u8,
    Flags1: u32,
    Flags2: u32,
    ppCode: *?*ID3DBlob,
    ppErrorMsgs: *?*ID3DBlob,
) callconv(.c) HRESULT;

// --- #89 2단계 — DirectComposition 투명도 경로 (opacity <100%) ---
// 반투명 창을 WS_EX_LAYERED(BitBlt 강제) 대신 WS_EX_NOREDIRECTIONBITMAP +
// composition swap chain 으로. 렌더 내용은 불투명 그대로 두고 DComp visual
// 의 uniform opacity 로 LWA_ALPHA 의미론을 재현한다.

pub extern "d3d11" fn D3D11CreateDevice(
    pAdapter: ?*anyopaque,
    DriverType: u32,
    Software: ?*anyopaque,
    Flags: u32,
    pFeatureLevels: ?[*]const u32,
    FeatureLevels: u32,
    SDKVersion: u32,
    ppDevice: *?*ID3D11Device,
    pFeatureLevel: ?*u32,
    ppImmediateContext: *?*ID3D11DeviceContext,
) callconv(.c) HRESULT;

pub extern "dxgi" fn CreateDXGIFactory1(riid: *const GUID, ppFactory: *?*anyopaque) callconv(.c) HRESULT;

// v3 — visual 객체의 인터페이스 버전은 *만든 device 버전* 을 따른다. v1
// DCompositionCreateDevice 의 visual 은 IDCompositionVisual3 QI 가 실패
// (Windows 실기 실측) → SetOpacity 불가. Device3 로 만들어야 Visual3 지원.
pub extern "dcomp" fn DCompositionCreateDevice3(
    renderingDevice: *anyopaque,
    iid: *const GUID,
    dcompositionDevice: *?*anyopaque,
) callconv(.c) HRESULT;

pub const DXGI_SCALING_STRETCH: u32 = 0;
pub const DXGI_ALPHA_MODE_PREMULTIPLIED: u32 = 1;
// per-pixel 알파 무시 (내용 불투명 취급). 투명도는 DComp visual 의 uniform
// SetOpacity 가 담당 — 우리 렌더가 대상 알파를 1 로 보장하지 않아도(기존
// layered 경로는 per-pixel 알파 미사용) premultiplied 의 '색×0=투명' 으로
// 창이 통째로 사라지는 문제 회피 (#89 2단계 실기).
pub const DXGI_ALPHA_MODE_IGNORE: u32 = 3;

pub const DXGI_SWAP_CHAIN_DESC1 = extern struct {
    Width: u32,
    Height: u32,
    Format: u32,
    Stereo: i32 = 0,
    SampleDesc: DXGI_SAMPLE_DESC,
    BufferUsage: u32,
    BufferCount: u32,
    Scaling: u32,
    SwapEffect: u32,
    AlphaMode: u32,
    Flags: u32 = 0,
};

/// #435 — swap chain 이 다음 프레임을 받을 준비가 됐는지 **논블로킹으로 물어볼 수 있는**
/// 이벤트를 달아 준다. `IDXGIFactory2::CreateSwapChainFor*` 로 만들 때만 걸 수 있고
/// `D3D11CreateDeviceAndSwapChain` 으로는 못 건다.
///
/// ⚠️ **`0x800` 과 헷갈리기 쉽다** — 그쪽은 `ALLOW_TEARING` 이다. 값은 zig 가 번들한
/// MinGW-w64 `dxgi.h` 의 `DXGI_SWAP_CHAIN_FLAG` 로 확인했다.
pub const DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT: u32 = 0x40;

pub const IID_IDXGIFactory2 = GUID{
    .Data1 = 0x50c83a1c,
    .Data2 = 0xe072,
    .Data3 = 0x4c48,
    .Data4 = .{ 0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0 },
};

pub const IID_IDXGIDevice = GUID{
    .Data1 = 0x54ec77fa,
    .Data2 = 0x1377,
    .Data3 = 0x44e6,
    .Data4 = .{ 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c },
};

pub const IDXGIFactory2 = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown (0-2)
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IDXGIFactory2) callconv(.c) u32,
        // IDXGIObject (3-6)
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const anyopaque,
        // IDXGIFactory (7-11)
        EnumAdapters: *const anyopaque,
        MakeWindowAssociation: *const fn (*IDXGIFactory2, ?*anyopaque, u32) callconv(.c) HRESULT,
        GetWindowAssociation: *const anyopaque,
        CreateSwapChain: *const anyopaque,
        CreateSoftwareAdapter: *const anyopaque,
        // IDXGIFactory1 (12-13)
        EnumAdapters1: *const anyopaque,
        IsCurrent: *const anyopaque,
        // IDXGIFactory2 (14-24)
        IsWindowedStereoEnabled: *const anyopaque,
        CreateSwapChainForHwnd: *const fn (*IDXGIFactory2, *anyopaque, ?*anyopaque, *const DXGI_SWAP_CHAIN_DESC1, ?*const anyopaque, ?*anyopaque, *?*IDXGISwapChain) callconv(.c) HRESULT,
        CreateSwapChainForCoreWindow: *const anyopaque,
        GetSharedResourceAdapterLuid: *const anyopaque,
        RegisterStereoStatusWindow: *const anyopaque,
        RegisterStereoStatusEvent: *const anyopaque,
        UnregisterStereoStatus: *const anyopaque,
        RegisterOcclusionStatusWindow: *const anyopaque,
        RegisterOcclusionStatusEvent: *const anyopaque,
        UnregisterOcclusionStatus: *const anyopaque,
        CreateSwapChainForComposition: *const fn (*IDXGIFactory2, *anyopaque, *const DXGI_SWAP_CHAIN_DESC1, ?*anyopaque, *?*IDXGISwapChain) callconv(.c) HRESULT,
    };

    pub fn Release(self: *IDXGIFactory2) u32 {
        return self.vtable.Release(self);
    }
    /// ppSwapChain 은 실제로 IDXGISwapChain1 이지만 vtable 이 IDXGISwapChain 의
    /// 상위 호환(선두 18 slot 동일)이라 기존 wrapper 로 그대로 사용.
    pub fn CreateSwapChainForComposition(self: *IDXGIFactory2, device: *anyopaque, desc: *const DXGI_SWAP_CHAIN_DESC1, restrict_out: ?*anyopaque, out: *?*IDXGISwapChain) HRESULT {
        return self.vtable.CreateSwapChainForComposition(self, device, desc, restrict_out, out);
    }
    /// #435 — hwnd 용. `D3D11CreateDeviceAndSwapChain` 과 달리 `DESC1.Flags` 를 받아서
    /// frame-latency waitable 을 걸 수 있다. `fullscreen_desc` 는 null 이면 windowed.
    /// 반환은 `CreateSwapChainForComposition` 과 같은 이유로 `IDXGISwapChain` 으로 받는다.
    pub fn CreateSwapChainForHwnd(self: *IDXGIFactory2, device: *anyopaque, hwnd: ?*anyopaque, desc: *const DXGI_SWAP_CHAIN_DESC1, fullscreen_desc: ?*const anyopaque, restrict_out: ?*anyopaque, out: *?*IDXGISwapChain) HRESULT {
        return self.vtable.CreateSwapChainForHwnd(self, device, hwnd, desc, fullscreen_desc, restrict_out, out);
    }
    /// #89 — DXGI 내장 Alt+Enter 감시 차단. 지금까지는 swap chain 의 `GetParent` 로
    /// `IDXGIFactory` 를 다시 얻어 불렀는데, hwnd 경로는 factory 를 이미 들고 있다.
    pub fn MakeWindowAssociation(self: *IDXGIFactory2, hwnd: ?*anyopaque, flags: u32) HRESULT {
        return self.vtable.MakeWindowAssociation(self, hwnd, flags);
    }
};

// --- IDXGISwapChain2 (#435) ---
// IDXGISwapChain (0-17) + IDXGISwapChain1 (18-28) + IDXGISwapChain2 (29-35).
// 선두 18 slot 이 IDXGISwapChain 과 같아 같은 포인터를 두 타입으로 볼 수 있지만,
// 아래 두 메서드는 QueryInterface 로 얻은 IDXGISwapChain2 에서만 부른다.
//
// Slots (zig 번들 MinGW-w64 `dxgi1_3.h` 의 IDXGISwapChain2Vtbl 로 확인):
// 18-28: IDXGISwapChain1 (GetDesc1, GetFullscreenDesc, GetHwnd, GetCoreWindow, Present1,
//        IsTemporaryMonoSupported, GetRestrictToOutput, SetBackgroundColor,
//        GetBackgroundColor, SetRotation, GetRotation)
// 29:    SetSourceSize
// 30:    GetSourceSize
// 31:    SetMaximumFrameLatency
// 32:    GetMaximumFrameLatency
// 33:    GetFrameLatencyWaitableObject
// 34-35: SetMatrixTransform, GetMatrixTransform

pub const IID_IDXGISwapChain2 = GUID{
    .Data1 = 0xa8be2ac4,
    .Data2 = 0x199f,
    .Data3 = 0x4946,
    .Data4 = .{ 0xb3, 0x31, 0x79, 0x59, 0x9f, 0xb9, 0x8d, 0xe7 },
};

pub const IDXGISwapChain2 = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown (0-2)
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IDXGISwapChain2) callconv(.c) u32,
        // IDXGIObject (3-6)
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const anyopaque,
        // IDXGIDeviceSubObject (7)
        GetDevice: *const anyopaque,
        // IDXGISwapChain (8-17)
        Present: *const anyopaque,
        GetBuffer: *const anyopaque,
        SetFullscreenState: *const anyopaque,
        GetFullscreenState: *const anyopaque,
        GetDesc: *const anyopaque,
        ResizeBuffers: *const anyopaque,
        ResizeTarget: *const anyopaque,
        GetContainingOutput: *const anyopaque,
        GetFrameStatistics: *const anyopaque,
        GetLastPresentCount: *const anyopaque,
        // IDXGISwapChain1 (18-28)
        GetDesc1: *const anyopaque,
        GetFullscreenDesc: *const anyopaque,
        GetHwnd: *const anyopaque,
        GetCoreWindow: *const anyopaque,
        Present1: *const anyopaque,
        IsTemporaryMonoSupported: *const anyopaque,
        GetRestrictToOutput: *const anyopaque,
        SetBackgroundColor: *const anyopaque,
        GetBackgroundColor: *const anyopaque,
        SetRotation: *const anyopaque,
        GetRotation: *const anyopaque,
        // IDXGISwapChain2 (29-35)
        SetSourceSize: *const anyopaque,
        GetSourceSize: *const anyopaque,
        SetMaximumFrameLatency: *const fn (*IDXGISwapChain2, u32) callconv(.c) HRESULT,
        GetMaximumFrameLatency: *const anyopaque,
        GetFrameLatencyWaitableObject: *const fn (*IDXGISwapChain2) callconv(.c) ?*anyopaque,
        SetMatrixTransform: *const anyopaque,
        GetMatrixTransform: *const anyopaque,
    };

    pub fn Release(self: *IDXGISwapChain2) u32 {
        return self.vtable.Release(self);
    }
    pub fn SetMaximumFrameLatency(self: *IDXGISwapChain2, max_latency: u32) HRESULT {
        return self.vtable.SetMaximumFrameLatency(self, max_latency);
    }
    /// 반환 HANDLE 의 소유권은 **호출자**에게 있다 — 다 쓰면 `CloseHandle`.
    pub fn GetFrameLatencyWaitableObject(self: *IDXGISwapChain2) ?*anyopaque {
        return self.vtable.GetFrameLatencyWaitableObject(self);
    }
};

pub const IID_IDCompositionDesktopDevice = GUID{
    .Data1 = 0x5F4633FE,
    .Data2 = 0x1E08,
    .Data3 = 0x4CB8,
    .Data4 = .{ 0x8C, 0x75, 0xCE, 0x24, 0x33, 0x3F, 0x56, 0x02 },
};

pub const IID_IDCompositionVisual3 = GUID{
    .Data1 = 0x2775F462,
    .Data2 = 0xB6C1,
    .Data3 = 0x4015,
    .Data4 = .{ 0xB0, 0xBE, 0xB3, 0xE7, 0xD6, 0xA4, 0x97, 0x6D },
};

// IDCompositionDesktopDevice (: IDCompositionDevice2) — Device2 메서드
// 21개(slot 3-23: Commit, WaitForCommitCompletion, GetFrameStatistics,
// CreateVisual, CreateSurfaceFactory, CreateSurface, CreateVirtualSurface,
// Translate/Scale/Rotate/Skew/Matrix/Group transform 6, 3D transform 5,
// EffectGroup, RectangleClip, Animation) 뒤에 DesktopDevice 의
// CreateTargetForHwnd(24)·CreateSurfaceFromHandle(25)·CreateSurfaceFromHwnd(26).
pub const IDCompositionDesktopDevice = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const anyopaque, // 0
        AddRef: *const anyopaque, // 1
        Release: *const fn (*IDCompositionDesktopDevice) callconv(.c) u32, // 2
        Commit: *const fn (*IDCompositionDesktopDevice) callconv(.c) HRESULT, // 3
        WaitForCommitCompletion: *const anyopaque, // 4
        GetFrameStatistics: *const anyopaque, // 5
        CreateVisual: *const fn (*IDCompositionDesktopDevice, *?*IDCompositionVisual) callconv(.c) HRESULT, // 6
        CreateSurfaceFactory: *const anyopaque, // 7
        CreateSurface: *const anyopaque, // 8
        CreateVirtualSurface: *const anyopaque, // 9
        CreateTranslateTransform: *const anyopaque, // 10
        CreateScaleTransform: *const anyopaque, // 11
        CreateRotateTransform: *const anyopaque, // 12
        CreateSkewTransform: *const anyopaque, // 13
        CreateMatrixTransform: *const anyopaque, // 14
        CreateTransformGroup: *const anyopaque, // 15
        CreateTranslateTransform3D: *const anyopaque, // 16
        CreateScaleTransform3D: *const anyopaque, // 17
        CreateRotateTransform3D: *const anyopaque, // 18
        CreateMatrixTransform3D: *const anyopaque, // 19
        CreateTransform3DGroup: *const anyopaque, // 20
        CreateEffectGroup: *const anyopaque, // 21
        CreateRectangleClip: *const anyopaque, // 22
        CreateAnimation: *const anyopaque, // 23
        CreateTargetForHwnd: *const fn (*IDCompositionDesktopDevice, ?*anyopaque, i32, *?*IDCompositionTarget) callconv(.c) HRESULT, // 24
        CreateSurfaceFromHandle: *const anyopaque, // 25
        CreateSurfaceFromHwnd: *const anyopaque, // 26
    };

    pub fn Release(self: *IDCompositionDesktopDevice) u32 {
        return self.vtable.Release(self);
    }
    pub fn Commit(self: *IDCompositionDesktopDevice) HRESULT {
        return self.vtable.Commit(self);
    }
    pub fn CreateTargetForHwnd(self: *IDCompositionDesktopDevice, hwnd: ?*anyopaque, topmost: i32, out: *?*IDCompositionTarget) HRESULT {
        return self.vtable.CreateTargetForHwnd(self, hwnd, topmost, out);
    }
    pub fn CreateVisual(self: *IDCompositionDesktopDevice, out: *?*IDCompositionVisual) HRESULT {
        return self.vtable.CreateVisual(self, out);
    }
};

pub const IDCompositionTarget = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IDCompositionTarget) callconv(.c) u32,
        SetRoot: *const fn (*IDCompositionTarget, ?*IDCompositionVisual) callconv(.c) HRESULT, // 3
    };

    pub fn Release(self: *IDCompositionTarget) u32 {
        return self.vtable.Release(self);
    }
    pub fn SetRoot(self: *IDCompositionTarget, visual: ?*IDCompositionVisual) HRESULT {
        return self.vtable.SetRoot(self, visual);
    }
};

// IDCompositionVisual — 각 속성이 (float, animation) 오버로드 쌍. dcomp.h
// 선언 순서는 float 변형이 먼저 (win32metadata 의 무접미사/2-접미사 순서와
// 일치). SetContent 는 쌍 내부 순서와 무관하게 slot 15.
pub const IDCompositionVisual = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown (0-2)
        QueryInterface: *const fn (*IDCompositionVisual, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const anyopaque,
        Release: *const fn (*IDCompositionVisual) callconv(.c) u32,
        // IDCompositionVisual (3-19)
        SetOffsetX_f: *const anyopaque, // 3
        SetOffsetX_anim: *const anyopaque, // 4
        SetOffsetY_f: *const anyopaque, // 5
        SetOffsetY_anim: *const anyopaque, // 6
        SetTransform_m: *const anyopaque, // 7
        SetTransform_i: *const anyopaque, // 8
        SetTransformParent: *const anyopaque, // 9
        SetEffect: *const anyopaque, // 10
        SetBitmapInterpolationMode: *const anyopaque, // 11
        SetBorderMode: *const anyopaque, // 12
        SetClip_r: *const anyopaque, // 13
        SetClip_i: *const anyopaque, // 14
        SetContent: *const fn (*IDCompositionVisual, ?*anyopaque) callconv(.c) HRESULT, // 15
    };

    pub fn Release(self: *IDCompositionVisual) u32 {
        return self.vtable.Release(self);
    }
    pub fn SetContent(self: *IDCompositionVisual, content: ?*anyopaque) HRESULT {
        return self.vtable.SetContent(self, content);
    }
    pub fn QueryInterface(self: *IDCompositionVisual, riid: *const GUID, out: *?*anyopaque) HRESULT {
        return self.vtable.QueryInterface(self, riid, out);
    }
};

// IDCompositionVisual3 (: VisualDebug : Visual2 : Visual) — SetOpacity(float)
// 는 slot **30**. dcomp 의 오버로드는 vtable 에서 **animation 버전이 float
// 버전보다 먼저** 온다 (Wine dcomp.idl `SetOffsetXAnimation` → `SetOffsetX(f)`
// 로 확인 + 실기 crash 로 확인: slot 29 를 float 로 호출하면 그건 실제로는
// SetOpacity(animation) 라 f32 를 포인터로 해석해 access violation).
// slot 산정: IUnknown(0-2) + Visual(3-19, SetContent=15 로 실기 검증됨) +
// Visual2 SetOpacityMode(20)·SetBackFaceVisibility(21) + VisualDebug
// Enable/DisableHeatMap(22-23)·Enable/DisableRedrawRegions(24-25) + Visual3
// SetDepthMode(26)·SetOffsetZ anim(27)·SetOffsetZ float(28)·SetOpacity
// anim(29)·**SetOpacity float(30)**.
pub const IDCompositionVisual3 = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const anyopaque, // 0
        AddRef: *const anyopaque, // 1
        Release: *const fn (*IDCompositionVisual3) callconv(.c) u32, // 2
        pad3: *const anyopaque,
        pad4: *const anyopaque,
        pad5: *const anyopaque,
        pad6: *const anyopaque,
        pad7: *const anyopaque,
        pad8: *const anyopaque,
        pad9: *const anyopaque,
        pad10: *const anyopaque,
        pad11: *const anyopaque,
        pad12: *const anyopaque,
        pad13: *const anyopaque,
        pad14: *const anyopaque,
        pad15: *const anyopaque,
        pad16: *const anyopaque,
        pad17: *const anyopaque,
        pad18: *const anyopaque,
        pad19: *const anyopaque,
        pad20: *const anyopaque,
        pad21: *const anyopaque,
        pad22: *const anyopaque,
        pad23: *const anyopaque,
        pad24: *const anyopaque,
        pad25: *const anyopaque,
        pad26: *const anyopaque,
        pad27: *const anyopaque,
        pad28: *const anyopaque,
        pad29: *const anyopaque, // SetOpacity(animation) — 미사용
        SetOpacity: *const fn (*IDCompositionVisual3, f32) callconv(.c) HRESULT, // 30
    };

    pub fn Release(self: *IDCompositionVisual3) u32 {
        return self.vtable.Release(self);
    }
    pub fn SetOpacity(self: *IDCompositionVisual3, opacity: f32) HRESULT {
        return self.vtable.SetOpacity(self, opacity);
    }
};
