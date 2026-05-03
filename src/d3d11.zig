// D3D11 / DXGI COM interface definitions for TildaZ renderer.
// All vtable slots match Windows SDK d3d11.h / dxgi.h order.

const std = @import("std");
const dw = @import("directwrite.zig");

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

pub const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;
pub const D3D11_SDK_VERSION: u32 = 7;
pub const D3D11_CREATE_DEVICE_DEBUG: u32 = 0x2;

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

pub const D3D11_BIND_VERTEX_BUFFER: u32 = 0x1;
pub const D3D11_BIND_CONSTANT_BUFFER: u32 = 0x4;
pub const D3D11_BIND_SHADER_RESOURCE: u32 = 0x8;

pub const D3D11_CPU_ACCESS_WRITE: u32 = 0x10000;

pub const D3D11_MAP_WRITE_DISCARD: u32 = 4;

pub const D3D11_INPUT_PER_VERTEX_DATA: u32 = 0;
pub const D3D11_INPUT_PER_INSTANCE_DATA: u32 = 1;

pub const D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP: u32 = 5;

pub const D3D11_BLEND_ZERO: u32 = 1;
pub const D3D11_BLEND_ONE: u32 = 2;
pub const D3D11_BLEND_SRC_ALPHA: u32 = 5;
pub const D3D11_BLEND_INV_SRC_ALPHA: u32 = 6;
pub const D3D11_BLEND_SRC1_COLOR: u32 = 16;
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
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11Texture2D) callconv(.c) u32,
    },
    pub fn Release(self: *ID3D11Texture2D) u32 {
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
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IDXGISwapChain) callconv(.c) u32,
        // IDXGIObject (3-6)
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const anyopaque,
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
        CopySubresourceRegion: *const anyopaque, // 46
        CopyResource: *const anyopaque, // 47
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
