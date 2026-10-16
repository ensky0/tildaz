//! #732 — macOS 표시 대상. IOSurface 한 장과 그것을 공유하는 `MTLTexture` 한 쌍이다.
//!
//! `CAMetalLayer.nextDrawable` 은 합성기가 drawable 을 돌려줄 때까지 막힌다. 표시 대기열이
//! 꽉 차는 위상에 들어가면 프레임마다 4~8 ms 를 기다렸고 (#476 실측), 그림은 3~4 프레임 뒤에
//! 화면에 나왔다. 그래서 우리가 만든 IOSurface 에 그리고, 다 그린 것을 `CALayer.contents`
//! 에 넣는다 — 줄을 세우지 않고, 기다리는 것은 우리 GPU 일뿐이다. ghostty 와 같은 방식이다
//! (`src/renderer/metal/Target.zig` · `IOSurfaceLayer.zig`).
const std = @import("std");
const objc = @import("../../macos_objc.zig");
const ct = @import("../../font/macos/coretext.zig");

pub const IOSurfaceRef = *opaque {};

extern "IOSurface" fn IOSurfaceCreate(properties: ct.CFDictionaryRef) ?IOSurfaceRef;
extern "IOSurface" fn IOSurfaceSetValue(buffer: IOSurfaceRef, key: ct.CFStringRef, value: ct.CFTypeRef) void;
/// `Boolean` (unsigned char). `IOSurfaceRef.h` 가 "in use" 판정에 쓰라고 하는 유일한 함수다.
extern "IOSurface" fn IOSurfaceIsInUse(buffer: IOSurfaceRef) u8;
extern "IOSurface" const kIOSurfaceWidth: ct.CFStringRef;
extern "IOSurface" const kIOSurfaceHeight: ct.CFStringRef;
extern "IOSurface" const kIOSurfaceBytesPerElement: ct.CFStringRef;
extern "IOSurface" const kIOSurfacePixelFormat: ct.CFStringRef;
extern "IOSurface" const kIOSurfaceColorSpace: ct.CFStringRef;

extern "CoreFoundation" fn CFNumberCreate(alloc: ct.CFAllocatorRef, the_type: ct.CFIndex, value_ptr: *const anyopaque) ?ct.CFTypeRef;
extern "CoreGraphics" fn CGColorSpaceCopyPropertyList(space: ct.CGColorSpaceRef) ?ct.CFTypeRef;

/// `kCFNumberSInt32Type`.
const cf_number_sint32: ct.CFIndex = 3;
/// `kCVPixelFormatType_32BGRA` (`'BGRA'`). `MTLPixelFormatBGRA8Unorm` 텍스처가 이 메모리를 쓴다.
const pixel_format_bgra: i32 = 0x42475241;
/// `MTLPixelFormatBGRA8Unorm`. `CAMetalLayer` 때와 같은 형식이다 — 셰이더 출력은 바뀌지 않는다.
const mtl_pixel_format_bgra8unorm: objc.NSUInteger = 80;
/// `MTLTextureUsageRenderTarget`.
const mtl_texture_usage_render_target: objc.NSUInteger = 4;

pub const Target = struct {
    surface: IOSurfaceRef,
    texture: objc.id,
    width: u32,
    height: u32,

    /// `colorspace` 는 표시 때 합성기가 쓸 색공간이다. #349 — sRGB 를 넘긴다. `CAMetalLayer`
    /// 에 붙이던 `setColorspace:` 와 같은 역할이고, 꼬리표가 없으면 wide-gamut 화면에서 색이
    /// 진해진다.
    ///
    /// `storage_mode` 는 `MTLStorageMode` 값이다. 통합 메모리 GPU 는 `shared` (0), Intel Mac 의
    /// 외장 GPU 는 `managed` (1) 다 — IOSurface 텍스처는 `private` 를 쓸 수 없다. ghostty
    /// `Device.zig` 의 `default_storage_mode` 와 같은 기준이다.
    pub fn init(device: objc.id, width: u32, height: u32, colorspace: ?ct.CGColorSpaceRef, storage_mode: objc.NSUInteger) !Target {
        const w: i32 = @intCast(width);
        const h: i32 = @intCast(height);
        const bpe: i32 = 4;
        const n_w = CFNumberCreate(null, cf_number_sint32, &w) orelse return error.SurfaceCreateFailed;
        defer ct.CFRelease(n_w);
        const n_h = CFNumberCreate(null, cf_number_sint32, &h) orelse return error.SurfaceCreateFailed;
        defer ct.CFRelease(n_h);
        const n_bpe = CFNumberCreate(null, cf_number_sint32, &bpe) orelse return error.SurfaceCreateFailed;
        defer ct.CFRelease(n_bpe);
        const n_pf = CFNumberCreate(null, cf_number_sint32, &pixel_format_bgra) orelse return error.SurfaceCreateFailed;
        defer ct.CFRelease(n_pf);

        const keys = [_]?*const anyopaque{ kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement, kIOSurfacePixelFormat };
        const values = [_]?*const anyopaque{ n_w, n_h, n_bpe, n_pf };
        const props = ct.CFDictionaryCreate(
            null,
            &keys,
            &values,
            keys.len,
            &ct.kCFTypeDictionaryKeyCallBacks,
            &ct.kCFTypeDictionaryValueCallBacks,
        ) orelse return error.SurfaceCreateFailed;
        defer ct.CFRelease(props);

        const surface = IOSurfaceCreate(props) orelse return error.SurfaceCreateFailed;
        errdefer ct.CFRelease(@ptrCast(surface));

        if (colorspace) |cs| {
            if (CGColorSpaceCopyPropertyList(cs)) |plist| {
                defer ct.CFRelease(plist);
                IOSurfaceSetValue(surface, kIOSurfaceColorSpace, plist);
            }
        }

        const desc_class = objc.getClass("MTLTextureDescriptor");
        const make_desc = objc.objcSend(fn (objc.Class, objc.SEL, objc.NSUInteger, objc.NSUInteger, objc.NSUInteger, bool) callconv(.c) objc.id);
        const desc = make_desc(
            desc_class,
            objc.sel("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"),
            mtl_pixel_format_bgra8unorm,
            width,
            height,
            false,
        );
        if (desc == null) return error.SurfaceCreateFailed;
        objc.msgSendVoid1(desc, objc.sel("setUsage:"), mtl_texture_usage_render_target);
        objc.msgSendVoid1(desc, objc.sel("setStorageMode:"), storage_mode);

        const new_texture = objc.objcSend(fn (objc.id, objc.SEL, objc.id, IOSurfaceRef, objc.NSUInteger) callconv(.c) objc.id);
        const texture = new_texture(device, objc.sel("newTextureWithDescriptor:iosurface:plane:"), desc, surface, 0);
        if (texture == null) return error.SurfaceCreateFailed;

        return .{ .surface = surface, .texture = texture, .width = width, .height = height };
    }

    /// #769 — 누군가 (보통 창 서버) 이 장을 아직 잡고 있는가. 잡혀 있으면 다시 그리지 않는다 —
    /// `IOSurfaceRef.h`: *"anyone attempting to maintain a pool of IOSurfaces to be recycled
    /// should not reclaim that IOSurface"*. 우리 프로세스는 사용 카운트를 올리지 않으므로 참이면
    /// 다른 프로세스가 잡고 있다는 뜻이다.
    pub fn inUse(self: *const Target) bool {
        return IOSurfaceIsInUse(self.surface) != 0;
    }

    pub fn deinit(self: *Target) void {
        objc.msgSendVoid(self.texture, objc.sel("release"));
        ct.CFRelease(@ptrCast(self.surface));
        self.* = undefined;
    }
};
