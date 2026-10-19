// proc-tree_windows.h — 프로세스 목록 · 조상 · 자손을 다루는 도우미 (#756).
//
// `tool/proc-usage_windows.c` · `tool/key-to-screen_windows.c` 가 함께 쓴다.
//
// **본체 찾기는 터미널 안 프로그램에서 위로 올라간다.** 터미널 안 프로그램의 pid 는 그 프로그램이 timing 파일에
// 적는다. 조상 사슬을 따라 올라가다 **처음 만나는 대상의 실행 파일 이름** (`alacritty.exe` · `WindowsTerminal.exe` 등)
// 이 본체다. 그 위로는 올라가지 않는다 — 더 올라가면 측정을 띄운 Git Bash · VS Code 가 나온다.
//
// - Toolhelp 의 `th32ParentProcessID` 는 **부모가 죽은 뒤 재사용된 pid 일 수 있다.** 그래서 부모로 인정하려면
//   부모의 생성 시각이 자식보다 앞서야 한다.
// - 셸 쪽 (`cmd` · `powershell` · `bash` · 측정 프로그램) 은 터미널의 몫이 아니다. ConPTY 안에서 도는 `conhost.exe` ·
//   `OpenConsole.exe` 는 터미널의 몫이다 (터미널이 띄운 것이다).

#ifndef TZ_PROC_TREE_WINDOWS_H
#define TZ_PROC_TREE_WINDOWS_H

#include <windows.h>
#include <tlhelp32.h>
#include <stdint.h>
#include <string.h>
#include <wchar.h>

#define PT_MAX 8192

typedef struct {
    DWORD pid, ppid;
    wchar_t exe[MAX_PATH];
    ULONGLONG created; // FILETIME (100 ns). 못 읽으면 0
} PtProc;

static PtProc g_pt[PT_MAX];
static int g_npt = 0;

static ULONGLONG pt_created(DWORD pid) {
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return 0;
    FILETIME c, e, k, u;
    ULONGLONG v = 0;
    if (GetProcessTimes(h, &c, &e, &k, &u)) v = ((ULONGLONG)c.dwHighDateTime << 32) | c.dwLowDateTime;
    CloseHandle(h);
    return v;
}

static void pt_snapshot(void) {
    g_npt = 0;
    HANDLE s = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (s == INVALID_HANDLE_VALUE) return;
    PROCESSENTRY32W e;
    e.dwSize = sizeof(e);
    for (BOOL ok = Process32FirstW(s, &e); ok && g_npt < PT_MAX; ok = Process32NextW(s, &e)) {
        PtProc *p = &g_pt[g_npt++];
        p->pid = e.th32ProcessID;
        p->ppid = e.th32ParentProcessID;
        wcsncpy(p->exe, e.szExeFile, MAX_PATH - 1);
        p->exe[MAX_PATH - 1] = 0;
        p->created = pt_created(p->pid);
    }
    CloseHandle(s);
}

static PtProc *pt_find(DWORD pid) {
    for (int i = 0; i < g_npt; i++)
        if (g_pt[i].pid == pid) return &g_pt[i];
    return NULL;
}

// `c` 의 진짜 부모. 재사용된 pid 면 NULL.
static PtProc *pt_parent(PtProc *c) {
    PtProc *p = pt_find(c->ppid);
    if (!p || p == c) return NULL;
    if (p->created && c->created && p->created > c->created) return NULL;
    return p;
}

static int pt_is_parent_of(PtProc *p, PtProc *c) { return c->ppid == p->pid && pt_parent(c) == p; }

// 이름은 `alacritty.exe` 처럼 확장자까지. 대소문자는 안 가린다. `;` 로 여러 개를 줄 수 있다.
static int pt_name_in(const wchar_t *exe, const char *names) {
    char buf[MAX_PATH];
    WideCharToMultiByte(CP_UTF8, 0, exe, -1, buf, sizeof(buf), NULL, NULL);
    const char *p = names;
    size_t n = strlen(buf);
    while (*p) {
        const char *q = strchr(p, ';');
        size_t len = q ? (size_t)(q - p) : strlen(p);
        if (len == n && _strnicmp(p, buf, n) == 0) return 1;
        if (!q) break;
        p = q + 1;
    }
    return 0;
}

// 터미널 안 프로그램 `child` 에서 올라가 처음 만나는 `names` 의 프로세스. 사슬 (child 부터 본체까지) 을
// `chain` 에 담는다 — 콘솔 창의 주인이 본체가 아니라 그 사이의 `cmd.exe` 인 경우가 있어서다 (`terminals.sh` 의
// `win_proc_name` 주석). 못 찾으면 NULL.
static PtProc *pt_main_of(DWORD child, const char *names, DWORD *chain, int *nchain) {
    PtProc *c = pt_find(child);
    int n = 0;
    for (int depth = 0; c && depth < 32; depth++) {
        if (chain && n < 32) chain[n++] = c->pid;
        if (depth > 0 && pt_name_in(c->exe, names)) {
            if (nchain) *nchain = n;
            return c;
        }
        c = pt_parent(c);
    }
    if (nchain) *nchain = 0;
    return NULL;
}

// `root` 와 그 자손 전부를 `out` 에 담는다 (root 가 첫째). 개수를 돌려준다.
static int pt_tree(PtProc *root, PtProc **out, int max) {
    int n = 0;
    out[n++] = root;
    for (int i = 0; i < n; i++)
        for (int k = 0; k < g_npt && n < max; k++)
            if (pt_is_parent_of(out[i], &g_pt[k])) {
                int dup = 0;
                for (int j = 0; j < n; j++) dup |= out[j] == &g_pt[k];
                if (!dup) out[n++] = &g_pt[k];
            }
    return n;
}

#endif
