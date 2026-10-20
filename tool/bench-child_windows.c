// bench-child_windows.c — 지연 · 메모리 · 시작 시간 측정 때 터미널 안에서 도는 프로그램 (#756, Windows).
//
// macOS · Linux 는 셸 스크립트 (`compare-latency.sh` 의 `latency-child.sh` 등) 다. Windows 는 그럴 수 없다 —
// Alacritty · WezTerm 은 MSYS `sh` 를 ConPTY 로 못 띄운다 (`terminals.sh` 의 `run_terminal_win` 주석). 그래서 같은
// 일을 하는 네이티브 프로그램을 둔다. 하는 일은 셸 판과 같다.
//
// **모드는 실행 파일 이름으로 정한다** — `latency-child.exe` · `memory-child.exe` · `startup-child.exe`. 부르는 쪽이
// 이 파일 하나를 세 이름으로 복사한다. 환경변수에 기대지 않는 이유: Windows Terminal 은 새 탭에 자기를 부른 프로세스의
// 환경을 넘기지 않을 수 있다 (확인 필요 — `compatibility.reloadEnvironmentVariables`). 시작 시간은 timing 파일 없이도
// 돈다.
//
//   latency  커서를 숨기고 → 목표 격자 (`TILDAZ_STRESS_GRID`) 를 최대 5 초 기다리고 → timing 파일에 격자 · pid 를 적고 →
//            키를 받기만 한다. 화면의 글자는 콘솔의 **cooked 모드 echo** 가 그린다 (ConPTY 안의 conhost — Unix 의 tty echo
//            자리). 모든 대상에서 같은 경로다.
//   memory   목표 격자를 기다리고 → 격자 · pid 를 적고 → `<timing>.go` 가 생기면 100 자 줄을 `TILDAZ_BENCH_FILL_LINES`
//            (기본 40,000) 줄 내고 → `filled=1` 을 덧붙이고 → 가만히 있는다. 커서는 숨기지 않는다.
//   startup  화면을 마젠타 (256 색 201 번) 로 칠하고 가만히 있는다. 배경색 지우기 (BCE) 를 안 하는 터미널도 칠해지게
//            그 색의 공백 줄도 낸다.
//
//   zig cc -O2 -o latency-child.exe tool/bench-child_windows.c

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static HANDLE g_out;

static void out(const char *s, DWORD n) {
    DWORD w;
    while (n > 0 && WriteFile(g_out, s, n, &w, NULL) && w > 0) { s += w; n -= w; }
}

static void outs(const char *s) { out(s, (DWORD)strlen(s)); }

static void grid(int *cols, int *rows) {
    CONSOLE_SCREEN_BUFFER_INFO bi;
    *cols = *rows = 0;
    if (GetConsoleScreenBufferInfo(g_out, &bi)) {
        *cols = bi.srWindow.Right - bi.srWindow.Left + 1;
        *rows = bi.srWindow.Bottom - bi.srWindow.Top + 1;
    }
}

// 목표 격자가 될 때까지 (최대 5 초) 기다린다 — 셸 판의 `stty size` 고리와 같다.
static void wait_grid(int *cols, int *rows) {
    const char *want = getenv("TILDAZ_STRESS_GRID");
    for (int i = 0; i < 50; i++) {
        grid(cols, rows);
        char now[32];
        snprintf(now, sizeof(now), "%dx%d", *cols, *rows);
        if (!want || !strcmp(now, want)) return;
        Sleep(100);
    }
}

// 임시 파일에 쓰고 바꿔 끼운다 — 부르는 쪽이 반쯤 쓴 파일을 읽지 않게.
static void write_timing(const char *path, int cols, int rows) {
    if (!path) return;
    char tmp[MAX_PATH + 8];
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    FILE *f = fopen(tmp, "wb");
    if (!f) return;
    fprintf(f, "cols=%d\nrows=%d\npid=%lu\n", cols, rows, (unsigned long)GetCurrentProcessId());
    fclose(f);
    MoveFileExA(tmp, path, MOVEFILE_REPLACE_EXISTING);
}

int main(void) {
    g_out = GetStdHandle(STD_OUTPUT_HANDLE);
    HANDLE in = GetStdHandle(STD_INPUT_HANDLE);
    DWORD m;
    // VT 를 켠다 — 커서 숨김 · 256 색 배경을 쓴다.
    if (GetConsoleMode(g_out, &m)) SetConsoleMode(g_out, m | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    char self[MAX_PATH];
    GetModuleFileNameA(NULL, self, sizeof(self));
    const char *base = strrchr(self, '\\');
    base = base ? base + 1 : self;
    const char *timing = getenv("TILDAZ_STRESS_TIMING_FILE");
    int cols, rows;

    if (!_strnicmp(base, "startup", 7)) {
        outs("\x1b[?25l\x1b[48;5;201m\x1b[2J\x1b[H");
        char line[244];
        memset(line, ' ', 240);
        line[240] = '\r'; line[241] = '\n';
        for (int i = 0; i < 60; i++) out(line, 242);
        write_timing(timing, 0, 0);
        Sleep(INFINITE);
        return 0;
    }

    if (!_strnicmp(base, "memory", 6)) {
        wait_grid(&cols, &rows);
        write_timing(timing, cols, rows);
        char go[MAX_PATH + 8];
        snprintf(go, sizeof(go), "%s.go", timing ? timing : "");
        while (GetFileAttributesA(go) == INVALID_FILE_ATTRIBUTES) Sleep(200);
        const char *fl = getenv("TILDAZ_BENCH_FILL_LINES");
        int lines = fl ? atoi(fl) : 40000;
        // 셸 판의 `awk` 와 같은 100 자 줄 — `%06d ` + `x` 93 개.
        static char buf[1 << 16];
        int used = 0;
        for (int i = 0; i < lines; i++) {
            if (used > (int)sizeof(buf) - 128) { out(buf, (DWORD)used); used = 0; }
            used += snprintf(buf + used, 16, "%06d ", i);
            memset(buf + used, 'x', 93);
            used += 93;
            buf[used++] = '\r';
            buf[used++] = '\n';
        }
        out(buf, (DWORD)used);
        FILE *f = fopen(timing, "ab");
        if (f) { fputs("filled=1\n", f); fclose(f); }
        Sleep(INFINITE);
        return 0;
    }

    // latency
    outs("\x1b[?25l");
    // cooked 모드 echo 를 분명히 켠다 (기본값이지만 부모가 바꿔 두었을 수 있다).
    if (GetConsoleMode(in, &m))
        SetConsoleMode(in, (m | ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT) & ~ENABLE_VIRTUAL_TERMINAL_INPUT);
    wait_grid(&cols, &rows);
    write_timing(timing, cols, rows);
    char b[256];
    DWORD r;
    while (ReadFile(in, b, sizeof(b), &r, NULL) && r > 0) {}
    Sleep(INFINITE);
    return 0;
}
