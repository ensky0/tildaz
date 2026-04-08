// Metal C 브릿지 헤더
// Zig MetalRenderer에서 @cImport로 가져오는 Metal 객체 관리 함수들.
// 구현은 metal_bridge.m에 있다.

#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─── 디바이스/큐 ───────────────────────────────────────────────────
void* tildazMetalCreateDevice(void);
void* tildazMetalCreateQueue(void* device);

// ─── CAMetalLayer 설정 ────────────────────────────────────────────
// TildazMetalNSView 의 CAMetalLayer에 디바이스를 연결하고 스케일 반환
float tildazMetalLayerSetup(void* metal_view, void* device);

// ─── 레이어 리사이즈 ──────────────────────────────────────────────
void tildazMetalResizeLayer(void* metal_view, uint32_t width, uint32_t height);

// ─── 셰이더 파이프라인 컴파일 ─────────────────────────────────────
// blend_mode: 0=alpha, 1=dual-source (ClearType)
void* tildazMetalCompilePipeline(
    void* device,
    const char* msl_src,
    size_t msl_len,
    const char* vs_name,
    const char* ps_name,
    int blend_mode
);

// ─── 버퍼/텍스처/샘플러 ──────────────────────────────────────────
void* tildazMetalCreateBuffer(void* device, size_t size);
void* tildazMetalCreateTexture(void* device, uint32_t width, uint32_t height);
void* tildazMetalCreateSampler(void* device);

// ─── 버퍼 데이터 업로드 ───────────────────────────────────────────
void tildazMetalUpdateBuffer(void* buffer, const void* data, size_t size);

// ─── 텍스처 서브영역 업로드 ───────────────────────────────────────
// BGRA8 데이터를 atlas의 (x, y) 위치에 w×h 크기로 업로드
void tildazMetalUpdateTexture(void* texture, uint32_t x, uint32_t y, uint32_t w, uint32_t h, const void* data);

// ─── 프레임 시작/종료 ─────────────────────────────────────────────
void* tildazMetalNextDrawable(void* layer);
// 배경 클리어 포함
void* tildazMetalBeginFrame(void* queue, void* drawable, float r, float g, float b);
// 클리어 없이 시작 (renderTerminal에서 사용)
void* tildazMetalBeginFrameNoClear(void* queue, void* drawable);
void  tildazMetalEndFrame(void* cmd, void* drawable);

// ─── 인스턴스 드로우 ──────────────────────────────────────────────
// instance_buf: BgInstance 또는 TextInstance 배열
// cb_buf: Constants 상수 버퍼
// texture/sampler: 배경 셰이더에서는 NULL
void tildazMetalDrawInstanced(
    void* cmd,
    void* pipeline,
    void* instance_buf,
    void* cb_buf,
    void* texture,    // nullable
    void* sampler,    // nullable
    void* unused,
    uint32_t instance_count,
    uint32_t vertex_count  // 쿼드: 4
);

// ─── 리소스 해제 ──────────────────────────────────────────────────
void tildazMetalRelease(void* obj);

#ifdef __cplusplus
}
#endif
