// key-to-screen_windows.c — 키를 누른 순간부터 그 창의 그림이 바뀐 프레임까지를 앱 밖에서 잰다 (#756).
//
// macOS 판 (`key-to-screen_macos.m`) · Linux 판 (`key-to-screen_linux.c`) 의 Windows 짝이다.
//
//   1. 터미널 안 프로그램의 pid (`--child-pid`) 에서 조상을 따라 올라가 터미널 본체 (`--main` 의 이름) 를 찾고, 그
//      사슬의 프로세스가 가진 보이는 창 중 가장 큰 것을 고른다 (`proc-tree_windows.h`). 해시할 영역은 그 창의
//      **클라이언트 영역**이다 — 테두리 · 그림자를 빼고, 다른 창 · 시계의 변화를 키의 결과로 잡지 않게.
//   2. 화면은 DXGI Desktop Duplication 으로 받는다 (`dxgi-dup_windows.h`).
//   3. `SendInput` 으로 `a` 를 누르기 직전의 QPC 와, 영역이 처음 바뀐 프레임의 `LastPresentTime` (같은 QPC 시계) 의
//      차이가 키 → 화면이다. `LastPresentTime` 은 DWM 이 바탕 화면 그림을 바꾼 순간이라 macOS 의 표시 시각에 가깝다
//      (확인 필요 — 모니터에 나간 시각은 아니다). **OS 사이에 절대값을 견주지 않는다** (Linux 판과 같은 원칙).
//
// - 포커스는 창 가운데를 한 번 눌러 잡는다 (`--click`). 콘솔 창은 제목 표시줄을 누른다 (아래 `click` 자리 주석). 누른 뒤 **그 창의 IME 를 닫는다** — 이 기기처럼 한국어 ·
//   일본어 IME 만 있으면 `a` 가 IME 로 간다. 기본 IME 창에 `WM_IME_CONTROL` · `IMC_SETOPENSTATUS` 를 보낸다
//   (`ImmGetDefaultIMEWnd`). 측정 창에만 닿는다.
// - **키마다 포커스를 확인한다.** 앞 창이 대상 사슬의 창이 아니면 키를 보내지 않고 멈춘다 — 합성 키는 앞 창으로
//   가서, 그 사이 사용자가 다른 창을 누르면 거기에 타이핑된다 (AGENTS.md 의 합성 입력 주의).
// - `--presses 0` 은 창을 찾아 포커스만 주고 끝난다 (메모리 측정의 포커스 클릭).
//
//   zig cc -O2 -o key-to-screen.exe tool/key-to-screen_windows.c -ld3d11 -ldxgi -limm32
//   key-to-screen --child-pid PID --main alacritty.exe [--click] [--presses 30] [--gap-ms 250] [--verbose]

#include "dxgi-dup_windows.h"
#include "proc-tree_windows.h"
#include <imm.h>
#include <stdlib.h>

#ifndef DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
#define DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 ((DPI_AWARENESS_CONTEXT)-4)
#endif
#ifndef IMC_GETOPENSTATUS
#define IMC_GETOPENSTATUS 0x0005
#endif
#ifndef IMC_SETOPENSTATUS
#define IMC_SETOPENSTATUS 0x0006
#endif

static DWORD g_chain[32];
static int g_nchain = 0;
static HWND g_best = NULL;
static LONG g_best_area = 0;

static int in_chain(DWORD pid) {
    for (int i = 0; i < g_nchain; i++)
        if (g_chain[i] == pid) return 1;
    return 0;
}

static BOOL CALLBACK pick(HWND h, LPARAM lp) {
    (void)lp;
    if (!IsWindowVisible(h)) return TRUE;
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    if (!in_chain(pid)) return TRUE;
    RECT r;
    if (!GetClientRect(h, &r)) return TRUE;
    LONG a = (r.right - r.left) * (r.bottom - r.top);
    if (r.right - r.left < 100 || r.bottom - r.top < 100) return TRUE;
    if (a > g_best_area) { g_best_area = a; g_best = h; }
    return TRUE;
}

static int fg_is_ours(void) {
    DWORD pid = 0;
    GetWindowThreadProcessId(GetForegroundWindow(), &pid);
    return in_chain(pid);
}

static LONGLONG qpc(void) {
    LARGE_INTEGER v;
    QueryPerformanceCounter(&v);
    return v.QuadPart;
}

static uint64_t hash_stage(Dup *d) {
    UINT pitch;
    const uint8_t *p = dup_map(d, &pitch);
    if (!p) return 0;
    uint64_t h = 1469598103934665603ULL;
    for (int y = 0; y < d->sh; y++) {
        const uint8_t *row = p + (size_t)y * pitch;
        for (int x = 0; x < d->sw * 4; x++) { h ^= row[x]; h *= 1099511628211ULL; }
    }
    dup_unmap(d);
    return h;
}

static void send_key(WORD vk, int up) {
    INPUT in;
    memset(&in, 0, sizeof(in));
    in.type = INPUT_KEYBOARD;
    in.ki.wVk = vk;
    in.ki.wScan = (WORD)MapVirtualKeyW(vk, MAPVK_VK_TO_VSC);
    in.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
    SendInput(1, &in, sizeof(in));
}

static void click_at(int x, int y) {
    int vx = GetSystemMetrics(SM_XVIRTUALSCREEN), vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
    int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN), vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    INPUT in[3];
    memset(in, 0, sizeof(in));
    for (int i = 0; i < 3; i++) {
        in[i].type = INPUT_MOUSE;
        in[i].mi.dx = (LONG)(((double)(x - vx) * 65535.0) / (vw - 1));
        in[i].mi.dy = (LONG)(((double)(y - vy) * 65535.0) / (vh - 1));
    }
    in[0].mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    in[1].mi.dwFlags = MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    in[2].mi.dwFlags = MOUSEEVENTF_LEFTUP | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    SendInput(1, &in[0], sizeof(INPUT));
    Sleep(30);
    SendInput(2, &in[1], sizeof(INPUT));
}

static int cmp_d(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

int main(int argc, char **argv) {
    DWORD child = 0;
    const char *names = NULL;
    int presses = 30, gap_ms = 250, click = 0, verbose = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--child-pid") && i + 1 < argc) child = (DWORD)strtoul(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--main") && i + 1 < argc) names = argv[++i];
        else if (!strcmp(argv[i], "--presses") && i + 1 < argc) presses = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--gap-ms") && i + 1 < argc) gap_ms = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--click")) click = 1;
        else if (!strcmp(argv[i], "--verbose")) verbose = 1;
    }
    if (!child || !names) {
        fprintf(stderr, "쓰는 법: key-to-screen --child-pid PID --main NAME[;NAME] [--click] [--presses N] [--gap-ms MS]\n");
        return 2;
    }
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    LARGE_INTEGER fq;
    QueryPerformanceFrequency(&fq);

    // 창이 목록에 올라올 때까지 (최대 5 초).
    PtProc *mainp = NULL;
    for (int t = 0; t < 50 && !g_best; t++) {
        pt_snapshot();
        mainp = pt_main_of(child, names, g_chain, &g_nchain);
        if (mainp) EnumWindows(pick, 0);
        if (!g_best) Sleep(100);
    }
    if (!mainp) { fprintf(stderr, "본체 (%s) 를 못 찾았어요 — child %lu\n", names, (unsigned long)child); return 1; }
    if (!g_best) { fprintf(stderr, "창을 못 찾았어요 — 본체 pid %lu\n", (unsigned long)mainp->pid); return 1; }
    RECT cr;
    GetClientRect(g_best, &cr);
    POINT tl = {0, 0};
    ClientToScreen(g_best, &tl);
    int wx = tl.x, wy = tl.y, ww = cr.right, wh = cr.bottom;
    char cls[128];
    GetClassNameA(g_best, cls, sizeof(cls));
    printf("window main=%lu hwnd=0x%llx class=%s rect=%d,%d,%d,%d\n", (unsigned long)mainp->pid,
           (unsigned long long)(uintptr_t)g_best, cls, wx, wy, ww, wh);
    fflush(stdout);

    if (click) {
        SetForegroundWindow(g_best);
        // 콘솔 창 (conhost) 은 **제목 표시줄**을 누른다. 빠른 편집 모드 (`HKCU\Console\QuickEdit`, 기본 켜짐) 에서
        // 클라이언트 영역을 누르면 선택 모드에 들어가고, 선택 중에는 프로그램의 출력이 멈춘다 — 메모리 측정의 conhost
        // 회차가 300 초를 기다려도 줄을 다 못 냈다 (2026-10-19 데스크탑 Ryzen 7 5700G).
        if (!strcmp(cls, "ConsoleWindowClass")) {
            RECT wr;
            GetWindowRect(g_best, &wr);
            click_at(wx + ww / 2, wr.top + (wy - wr.top) / 2);
        } else {
            click_at(wx + ww / 2, wy + wh / 2);
        }
        Sleep(200);
        HWND ime = ImmGetDefaultIMEWnd(g_best);
        if (ime) {
            DWORD_PTR was = 0, res = 0;
            SendMessageTimeoutW(ime, WM_IME_CONTROL, IMC_GETOPENSTATUS, 0, SMTO_ABORTIFHUNG, 500, &was);
            SendMessageTimeoutW(ime, WM_IME_CONTROL, IMC_SETOPENSTATUS, 0, SMTO_ABORTIFHUNG, 500, &res);
            if (verbose) fprintf(stderr, "ime open=%lu → 0\n", (unsigned long)was);
        }
    }
    if (presses <= 0) return fg_is_ours() ? 0 : 3;

    Dup d;
    if (!dup_init(&d, wx + ww / 2, wy + wh / 2)) { fprintf(stderr, "화면 캡처를 못 열었어요.\n"); return 1; }
    int sx = wx - d.desk.left, sy = wy - d.desk.top, sw = ww, sh = wh;
    if (sx < 0) { sw += sx; sx = 0; }
    if (sy < 0) { sh += sy; sy = 0; }
    int ow = d.desk.right - d.desk.left, oh = d.desk.bottom - d.desk.top;
    if (sx + sw > ow) sw = ow - sx;
    if (sy + sh > oh) sh = oh - sy;
    if (sw <= 0 || sh <= 0) { fprintf(stderr, "창이 화면 밖이에요.\n"); return 1; }

    // 첫 프레임은 지금 화면 전체를 준다 — 그것이 기준 그림이다.
    LONGLONG t = 0;
    uint64_t base = 0;
    int got_first = 0;
    for (int i = 0; i < 100 && !got_first; i++)
        if (dup_next(&d, 20, sx, sy, sw, sh, &t) == 1) { base = hash_stage(&d); got_first = 1; }
    if (!got_first) { fprintf(stderr, "첫 프레임이 안 와요.\n"); return 1; }
    Sleep(800); // 포커스가 옮겨 가고 클릭이 그린 것이 가라앉을 때까지 (macOS · Linux 판과 같은 대기)

    double *lat = calloc((size_t)presses, sizeof(double));
    int got = 0, miss = 0;
    for (int i = 0; i < presses; i++) {
        Sleep((DWORD)gap_ms);
        // 그 사이 바뀐 그림 (앞 키의 echo 등) 을 모두 받아 기준을 새로 잡는다.
        while (dup_next(&d, 0, sx, sy, sw, sh, &t) == 1) base = hash_stage(&d);
        if (!fg_is_ours()) {
            fprintf(stderr, "앞 창이 대상이 아니에요 — 키를 멈춰요 (press %d).\n", i + 1);
            printf("aborted focus\n");
            break;
        }
        LONGLONG t0 = qpc();
        send_key('A', 0);
        send_key('A', 1);
        double found = -1;
        while (found < 0 && (double)(qpc() - t0) * 1000.0 / (double)fq.QuadPart < 500.0) {
            int r = dup_next(&d, 10, sx, sy, sw, sh, &t);
            if (r < 0) break;
            if (r == 0) continue;
            uint64_t h = hash_stage(&d);
            if (h == base) continue;
            if (t > t0) found = (double)(t - t0) * 1000.0 / (double)fq.QuadPart;
            else base = h;
        }
        if (found < 0) {
            miss++;
            printf("press %2d  miss\n", i + 1);
        } else {
            lat[got++] = found;
            printf("press %2d  %6.2f ms\n", i + 1, found);
        }
        fflush(stdout);
    }
    dup_release_frame(&d);
    qsort(lat, (size_t)got, sizeof(double), cmp_d);
    double sum = 0;
    for (int a = 0; a < got; a++) sum += lat[a];
    if (got > 0)
        printf("samples=%d miss=%d mean_ms=%.2f median_ms=%.2f min_ms=%.2f max_ms=%.2f\n", got, miss, sum / got,
               lat[got / 2], lat[0], lat[got - 1]);
    else
        printf("samples=0 miss=%d\n", miss);
    return 0;
}
