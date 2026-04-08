// macOS Objective-C 브릿지 헤더
// Zig에서 @cImport로 가져오는 C 호환 선언들.
// 실제 구현은 bridge.m (Objective-C) 에 있다.

#pragma once
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─── 불투명 핸들 ───────────────────────────────────────────────────
typedef void* TildazApp;
typedef void* TildazWindow;
typedef void* TildazMetalView;

// ─── 콜백 타입 ────────────────────────────────────────────────────
typedef void (*TildazRenderFn)(void* userdata);
typedef void (*TildazResizeFn)(uint16_t cols, uint16_t rows, void* userdata);
typedef void (*TildazKeyFn)(uint32_t key_code, uint32_t modifiers, bool is_repeat, void* userdata);
typedef void (*TildazCharFn)(uint32_t codepoint, uint32_t modifiers, void* userdata);
typedef void (*TildazMouseFn)(int32_t x, int32_t y, uint32_t button, uint32_t modifiers, void* userdata);
typedef void (*TildazScrollFn)(float dx, float dy, void* userdata);
typedef void (*TildazHotkeyFn)(void* userdata);
typedef void (*TildazTabBarFn)(int32_t x, int32_t y, bool dblclick, void* userdata);

// ─── 셀 메트릭 ────────────────────────────────────────────────────
typedef struct {
    float cell_width;
    float cell_height;
    float ascent;
    float descent;
    float leading;
} TildazFontMetrics;

// ─── 앱 생명주기 ───────────────────────────────────────────────────
TildazApp tildazAppCreate(void);
void tildazAppRun(TildazApp app);
void tildazAppTerminate(TildazApp app);

// ─── 윈도우 생성/소멸 ──────────────────────────────────────────────
// font_name: UTF-8, font_size: pt, opacity: 0-255, scale: Retina 배율
TildazWindow tildazWindowCreate(
    TildazApp app,
    const char* font_name,
    float font_size,
    uint8_t opacity,
    float cell_width_scale,
    float line_height_scale,
    TildazFontMetrics* out_metrics
);
void tildazWindowDestroy(TildazWindow win);

// ─── 윈도우 표시/숨기기 ───────────────────────────────────────────
void tildazWindowShow(TildazWindow win);
void tildazWindowHide(TildazWindow win);
bool tildazWindowIsVisible(TildazWindow win);

// ─── 윈도우 위치/크기 ──────────────────────────────────────────────
// dock: 0=top, 1=bottom, 2=left, 3=right
void tildazWindowSetPosition(TildazWindow win, int dock, uint8_t width_pct, uint8_t height_pct, uint8_t offset_pct);

// ─── 불투명도 ─────────────────────────────────────────────────────
void tildazWindowSetOpacity(TildazWindow win, uint8_t opacity);

// ─── Metal 렌더 서피스 ────────────────────────────────────────────
TildazMetalView tildazWindowGetMetalView(TildazWindow win);

// 다음 vsync에서 render 콜백 트리거
void tildazWindowScheduleRedraw(TildazWindow win);

// ─── 콜백 등록 ────────────────────────────────────────────────────
void tildazWindowSetRenderCallback(TildazWindow win, TildazRenderFn fn, void* userdata);
void tildazWindowSetResizeCallback(TildazWindow win, TildazResizeFn fn, void* userdata);
void tildazWindowSetKeyCallback(TildazWindow win, TildazKeyFn fn, void* userdata);
void tildazWindowSetCharCallback(TildazWindow win, TildazCharFn fn, void* userdata);
void tildazWindowSetMouseCallback(TildazWindow win, TildazMouseFn fn, void* userdata);
void tildazWindowSetScrollCallback(TildazWindow win, TildazScrollFn fn, void* userdata);
void tildazWindowSetTabBarCallback(TildazWindow win, TildazTabBarFn fn, void* userdata);

// ─── 글로벌 핫키 (F1) ─────────────────────────────────────────────
// Accessibility 권한이 필요하다. 없으면 false 반환.
bool tildazRegisterHotkey(TildazHotkeyFn fn, void* userdata);
void tildazUnregisterHotkey(void);

// ─── 클립보드 ─────────────────────────────────────────────────────
// 반환값: 호출자가 free() 해야 함. 데이터 없으면 NULL.
char* tildazClipboardGet(void);
void tildazClipboardSet(const char* utf8_text);

// ─── 폰트 메트릭 ──────────────────────────────────────────────────
bool tildazMeasureFont(
    const char* font_name,
    float font_size,
    float scale_factor,
    float cell_width_scale,
    float line_height_scale,
    TildazFontMetrics* out
);

// ─── 스크린 정보 ──────────────────────────────────────────────────
// 커서가 있는 스크린의 작업 영역 반환
void tildazGetWorkArea(int* x, int* y, int* w, int* h);

// ─── Metal 레이어에서 현재 drawable CAMetalDrawable 획득 ──────────
void* tildazGetNextDrawable(TildazMetalView view);

#ifdef __cplusplus
}
#endif
