// Metal C 브릿지 구현
// MTLDevice, MTLCommandQueue, MTLRenderPipelineState, MTLBuffer, MTLTexture 래핑.

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Foundation/Foundation.h>
#include "metal_bridge.h"
#include "bridge.h"  // TildazMetalNSView

// ─── 내부: TildazMetalNSView → CAMetalLayer 접근 ─────────────────
// bridge.m과 같은 컴파일 단위에 있지 않으므로 Objective-C runtime으로 접근
static CAMetalLayer* getLayer(void* metal_view) {
    id view = (__bridge id)metal_view;
    // TildazMetalNSView의 metalLayer 프로퍼티 접근
    if ([view respondsToSelector:@selector(metalLayer)]) {
        return [view performSelector:@selector(metalLayer)];
    }
    // NSView의 layer 접근 (fallback)
    if ([view respondsToSelector:@selector(layer)]) {
        id layer = [view performSelector:@selector(layer)];
        if ([layer isKindOfClass:[CAMetalLayer class]]) {
            return (CAMetalLayer*)layer;
        }
    }
    return nil;
}

// ─── 디바이스/큐 ───────────────────────────────────────────────────

void* tildazMetalCreateDevice(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    return device ? (__bridge_retained void*)device : NULL;
}

void* tildazMetalCreateQueue(void* device) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    return queue ? (__bridge_retained void*)queue : NULL;
}

// ─── CAMetalLayer 설정 ────────────────────────────────────────────

float tildazMetalLayerSetup(void* metal_view, void* device) {
    CAMetalLayer* layer = getLayer(metal_view);
    if (!layer) return 1.0f;

    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    layer.device = dev;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;

    // Retina 스케일
    id view = (__bridge id)metal_view;
    float scale = 1.0f;
    if ([view respondsToSelector:@selector(window)]) {
        NSWindow* win = [view performSelector:@selector(window)];
        if (win) scale = (float)win.backingScaleFactor;
    }
    layer.contentsScale = scale;

    return scale;
}

void tildazMetalResizeLayer(void* metal_view, uint32_t width, uint32_t height) {
    CAMetalLayer* layer = getLayer(metal_view);
    if (!layer) return;
    layer.drawableSize = CGSizeMake((CGFloat)width, (CGFloat)height);
}

// ─── 셰이더 파이프라인 ────────────────────────────────────────────

void* tildazMetalCompilePipeline(
    void* device,
    const char* msl_src,
    size_t msl_len,
    const char* vs_name,
    const char* ps_name,
    int blend_mode
) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;

    NSString* src = [[NSString alloc] initWithBytes:msl_src length:msl_len encoding:NSUTF8StringEncoding];
    NSError* err = nil;
    MTLCompileOptions* opts = [[MTLCompileOptions alloc] init];
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:opts error:&err];
    if (!lib) {
        NSLog(@"[tildaz] Metal shader compile error: %@", err);
        return NULL;
    }

    id<MTLFunction> vs = [lib newFunctionWithName:[NSString stringWithUTF8String:vs_name]];
    id<MTLFunction> ps = [lib newFunctionWithName:[NSString stringWithUTF8String:ps_name]];
    if (!vs || !ps) {
        NSLog(@"[tildaz] Metal function not found: %s / %s", vs_name, ps_name);
        return NULL;
    }

    MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = vs;
    desc.fragmentFunction = ps;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    if (blend_mode == 0) {
        // Alpha 블렌딩
        desc.colorAttachments[0].blendingEnabled = YES;
        desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorZero;
    } else {
        // Dual-source ClearType 블렌딩
        // src0 * src1_color + dst * (1 - src1_color)
        desc.colorAttachments[0].blendingEnabled = YES;
        desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSource1Color;
        desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorZero;
    }

    id<MTLRenderPipelineState> pipeline = [dev newRenderPipelineStateWithDescriptor:desc error:&err];
    if (!pipeline) {
        NSLog(@"[tildaz] Metal pipeline error: %@", err);
        return NULL;
    }

    return (__bridge_retained void*)pipeline;
}

// ─── 버퍼/텍스처/샘플러 ──────────────────────────────────────────

void* tildazMetalCreateBuffer(void* device, size_t size) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    id<MTLBuffer> buf = [dev newBufferWithLength:size options:MTLResourceStorageModeShared];
    return buf ? (__bridge_retained void*)buf : NULL;
}

void* tildazMetalCreateTexture(void* device, uint32_t width, uint32_t height) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    MTLTextureDescriptor* desc = [[MTLTextureDescriptor alloc] init];
    desc.textureType = MTLTextureType2D;
    desc.pixelFormat = MTLPixelFormatBGRA8Unorm;
    desc.width = width;
    desc.height = height;
    desc.storageMode = MTLStorageModeShared;
    desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [dev newTextureWithDescriptor:desc];
    return tex ? (__bridge_retained void*)tex : NULL;
}

void* tildazMetalCreateSampler(void* device) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    MTLSamplerDescriptor* desc = [[MTLSamplerDescriptor alloc] init];
    desc.minFilter = MTLSamplerMinMagFilterNearest;
    desc.magFilter = MTLSamplerMinMagFilterNearest;
    desc.mipFilter = MTLSamplerMipFilterNotMipmapped;
    id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:desc];
    return smp ? (__bridge_retained void*)smp : NULL;
}

// ─── 데이터 업로드 ────────────────────────────────────────────────

void tildazMetalUpdateBuffer(void* buffer, const void* data, size_t size) {
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)buffer;
    memcpy(buf.contents, data, size);
}

void tildazMetalUpdateTexture(void* texture, uint32_t x, uint32_t y, uint32_t w, uint32_t h, const void* data) {
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    MTLRegion region = MTLRegionMake2D(x, y, w, h);
    [tex replaceRegion:region
           mipmapLevel:0
             withBytes:data
           bytesPerRow:w * 4]; // BGRA8: 4 bytes/pixel
}

// ─── 프레임 시작/종료 ─────────────────────────────────────────────

void* tildazMetalNextDrawable(void* layer_or_view) {
    // metal_view(TildazMetalNSView) 또는 CAMetalLayer 모두 허용
    CAMetalLayer* layer = nil;
    id obj = (__bridge id)layer_or_view;
    if ([obj isKindOfClass:[CAMetalLayer class]]) {
        layer = (CAMetalLayer*)obj;
    } else {
        layer = getLayer(layer_or_view);
    }
    if (!layer) return NULL;
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    return drawable ? (__bridge_retained void*)drawable : NULL;
}

void* tildazMetalBeginFrame(void* queue, void* drawable, float r, float g, float b) {
    id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)queue;
    id<CAMetalDrawable> d = (__bridge id<CAMetalDrawable>)drawable;

    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = d.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, 1.0);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLCommandBuffer> cmd = [q commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
    [enc endEncoding];

    return (__bridge_retained void*)cmd;
}

void* tildazMetalBeginFrameNoClear(void* queue, void* drawable) {
    id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)queue;
    id<MTLCommandBuffer> cmd = [q commandBuffer];
    (void)drawable;
    return (__bridge_retained void*)cmd;
}

void tildazMetalEndFrame(void* cmd, void* drawable) {
    id<MTLCommandBuffer> c = (__bridge_transfer id<MTLCommandBuffer>)cmd;
    id<CAMetalDrawable> d = (__bridge_transfer id<CAMetalDrawable>)drawable;
    [c presentDrawable:d];
    [c commit];
}

// ─── 인스턴스 드로우 ──────────────────────────────────────────────

void tildazMetalDrawInstanced(
    void* cmd,
    void* pipeline,
    void* instance_buf,
    void* cb_buf,
    void* texture,
    void* sampler,
    void* unused,
    uint32_t instance_count,
    uint32_t vertex_count
) {
    (void)unused;
    id<MTLCommandBuffer> c = (__bridge id<MTLCommandBuffer>)cmd;
    id<MTLRenderPipelineState> pipe = (__bridge id<MTLRenderPipelineState>)pipeline;
    id<MTLBuffer> ibuf = (__bridge id<MTLBuffer>)instance_buf;
    id<MTLBuffer> cbuf = (__bridge id<MTLBuffer>)cb_buf;

    // 현재 drawable의 texture를 얻기 위한 pass (이미 cmd에 포함된 drawable 재활용)
    // NOTE: 단순화를 위해 각 draw call이 독립적인 render pass를 사용.
    // 실제 구현에서는 프레임당 단일 pass로 통합해야 최적.
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    // drawble texture는 BeginFrame에서 이미 설정됨. 여기서는 load=load, store=store
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> enc = [c renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:pipe];
    [enc setVertexBuffer:ibuf offset:0 atIndex:0];
    [enc setVertexBuffer:cbuf offset:0 atIndex:1];
    [enc setFragmentBuffer:cbuf offset:0 atIndex:0];

    if (texture) {
        id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
        [enc setFragmentTexture:tex atIndex:0];
    }
    if (sampler) {
        id<MTLSamplerState> smp = (__bridge id<MTLSamplerState>)sampler;
        [enc setFragmentSamplerState:smp atIndex:0];
    }

    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
            vertexStart:0
            vertexCount:vertex_count
          instanceCount:instance_count];
    [enc endEncoding];
}

// ─── 리소스 해제 ──────────────────────────────────────────────────

void tildazMetalRelease(void* obj) {
    if (!obj) return;
    CFRelease(obj); // ARC 없이 retain된 객체 해제
}
