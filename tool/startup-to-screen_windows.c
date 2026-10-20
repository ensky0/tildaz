// startup-to-screen_windows.c — 터미널을 실행한 순간부터 그 안의 프로그램이 그린 표식이 화면에 처음 보일 때까지를
// 앱 밖에서 잰다 (#756 · 시작 시간). macOS 판 (`startup-to-screen_macos.m`) 의 Windows 짝이다.
//
//   zig cc -O2 -o startup-to-screen.exe tool/startup-to-screen_windows.c -ld3d11 -ldxgi -lole32 -lshell32
//   startup-to-screen [--timeout-ms 10000] [--min-pixels 22500] -- <실행 파일> <인자…>
//
// 1. 주 화면 전체를 DXGI Desktop Duplication 으로 받는다 (`dxgi-dup_windows.h`).
// 2. 첫 프레임에 마젠타가 이미 있으면 멈춘다 — 판정이 성립하지 않는다.
// 3. **명령을 이 프로그램이 직접 띄운다** — `ShellExecuteExW`. 시작 메뉴 · 탐색기가 앱을 여는 길이다
//    (#761 의 "사용자가 여는 길 = ShellExecute"). 띄우기 직전의 QPC 가 기준이다.
// 4. 마젠타 (R>200 · G<80 · B>200) 픽셀이 `--min-pixels` (물리 px) 이상인 첫 프레임의 `LastPresentTime` 과의 차이를
//    낸다 — "실행 → 화면에 첫 표식" 이다. 픽셀은 가로 · 세로 2 칸마다 하나를 세고 4 배 한다.
//
// - 표식은 터미널 안 프로그램 (`bench-child_windows.c` 의 startup) 이 칠한다.
// - 띄운 프로그램은 기다리지 않는다. 정리는 부르는 쪽 몫이다 (`proc-usage_windows.c` 의 `kill`).
// - `LastPresentTime` 은 DWM 이 바탕 화면 그림을 바꾼 순간이다. OS 사이에 절대값을 견주지 않는다.

#include "dxgi-dup_windows.h"
#include <shellapi.h>
#include <objbase.h>
#include <stdlib.h>

#ifndef DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
#define DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 ((DPI_AWARENESS_CONTEXT)-4)
#endif

static long count_magenta(Dup *d) {
    UINT pitch;
    const uint8_t *p = dup_map(d, &pitch);
    if (!p) return -1;
    long n = 0;
    for (int y = 0; y < d->sh; y += 2) {
        const uint8_t *row = p + (size_t)y * pitch;
        for (int x = 0; x < d->sw; x += 2) {
            const uint8_t *px = row + x * 4; // BGRA
            if (px[2] > 200 && px[1] < 80 && px[0] > 200) n++;
        }
    }
    dup_unmap(d);
    return n * 4;
}

static LONGLONG qpc(void) {
    LARGE_INTEGER v;
    QueryPerformanceCounter(&v);
    return v.QuadPart;
}

// CommandLineToArgvW 의 규칙으로 되읽히게 인자 하나를 따옴표로 감싼다.
static void append_arg(wchar_t *dst, size_t cap, const wchar_t *a) {
    size_t n = wcslen(dst);
    if (n) dst[n++] = L' ';
    int quote = !*a || wcspbrk(a, L" \t\"") != NULL;
    if (quote) dst[n++] = L'"';
    for (const wchar_t *p = a; *p && n + 4 < cap; p++) {
        if (*p == L'"') dst[n++] = L'\\';
        dst[n++] = *p;
    }
    if (quote) dst[n++] = L'"';
    dst[n] = 0;
}

int main(void) {
    int argc;
    wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    int timeout_ms = 10000;
    long min_pixels = 22500;
    int cmd = -1;
    for (int i = 1; i < argc; i++) {
        if (!wcscmp(argv[i], L"--timeout-ms") && i + 1 < argc) timeout_ms = _wtoi(argv[++i]);
        else if (!wcscmp(argv[i], L"--min-pixels") && i + 1 < argc) min_pixels = _wtol(argv[++i]);
        else if (!wcscmp(argv[i], L"--")) { cmd = i + 1; break; }
    }
    if (cmd < 0 || cmd >= argc) {
        fprintf(stderr, "쓰는 법: startup-to-screen [--timeout-ms N] [--min-pixels N] -- <실행 파일> <인자…>\n");
        return 2;
    }
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    LARGE_INTEGER fq;
    QueryPerformanceFrequency(&fq);

    Dup d;
    if (!dup_init(&d, GetSystemMetrics(SM_CXSCREEN) / 2, GetSystemMetrics(SM_CYSCREEN) / 2)) {
        fprintf(stderr, "화면 캡처를 못 열었어요.\n");
        return 1;
    }
    int ow = d.desk.right - d.desk.left, oh = d.desk.bottom - d.desk.top;
    LONGLONG t = 0;
    long base = -1;
    for (int i = 0; i < 100 && base < 0; i++)
        if (dup_next(&d, 20, 0, 0, ow, oh, &t) == 1) base = count_magenta(&d);
    if (base < 0) { fprintf(stderr, "첫 프레임이 안 와요.\n"); return 1; }
    if (base >= min_pixels) { fprintf(stderr, "띄우기 전에 이미 마젠타가 %ld px 보여요 — 판정이 안 돼요.\n", base); return 1; }

    static wchar_t params[8192];
    params[0] = 0;
    for (int i = cmd + 1; i < argc; i++) append_arg(params, sizeof(params) / sizeof(params[0]), argv[i]);
    SHELLEXECUTEINFOW si;
    memset(&si, 0, sizeof(si));
    si.cbSize = sizeof(si);
    si.fMask = SEE_MASK_FLAG_NO_UI;
    si.lpVerb = L"open";
    si.lpFile = argv[cmd];
    si.lpParameters = params[0] ? params : NULL;
    si.nShow = SW_SHOWNORMAL;
    LONGLONG t0 = qpc();
    if (!ShellExecuteExW(&si)) { fprintf(stderr, "ShellExecuteEx 실패 %lu\n", (unsigned long)GetLastError()); return 1; }

    while ((double)(qpc() - t0) * 1000.0 / (double)fq.QuadPart < timeout_ms) {
        int r = dup_next(&d, 50, 0, 0, ow, oh, &t);
        if (r < 0) { fprintf(stderr, "캡처 실패\n"); return 1; }
        if (r == 0 || t <= t0) continue;
        long n = count_magenta(&d);
        if (n >= min_pixels) {
            printf("startup_ms=%.1f\n", (double)(t - t0) * 1000.0 / (double)fq.QuadPart);
            printf("pixels=%ld\n", n);
            return 0;
        }
    }
    printf("timeout\n");
    return 1;
}
