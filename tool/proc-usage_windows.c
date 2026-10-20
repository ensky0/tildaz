// proc-usage_windows.c — 터미널 하나의 메모리 · CPU 시간을 앱 밖에서 읽는다 (#756). macOS · Linux 판
// (`proc-usage_macos.c` · `proc-usage_linux.py`) 의 Windows 짝이다.
//
//   zig cc -O2 -o proc-usage.exe tool/proc-usage_windows.c -lpsapi
//   proc-usage main <터미널 안 프로그램 pid> <본체 이름들>     # 본체 pid (이름은 `alacritty.exe;wezterm-gui.exe` 꼴)
//   proc-usage measure <본체 pid>                              # 줄마다 pid · 메모리 · CPU 시간 · 이름, 끝에 total
//   proc-usage kill <터미널 안 프로그램 이름들> <본체 이름들>    # 그 프로그램이 든 터미널을 트리째 끝낸다
//
// **"그 터미널의 프로세스"** — 본체와 그 모든 자손. 셸 쪽 (`cmd` · `powershell` · `bash` · 측정 프로그램) 은 뺀다.
// ConPTY 를 쓰는 터미널이 띄운 `conhost.exe` · `OpenConsole.exe` 는 터미널의 몫이라 넣는다 (`proc-tree_windows.h`).
//
// **메모리는 Private Working Set 이다** — 작업 관리자의 "메모리" 열 (*active private working set*) 과 같은 값이다.
// `PROCESS_MEMORY_COUNTERS_EX2.PrivateWorkingSetSize` (Windows 10 1809+). mingw 헤더에 없어서 아래에 문서대로 둔다
// ([PROCESS_MEMORY_COUNTERS_EX2](https://learn.microsoft.com/en-us/windows/win32/api/psapi/ns-psapi-process_memory_counters_ex2)).
// GPU 메모리 (전용 · 공유) 는 들지 않는다. macOS (`phys_footprint`) · Linux (PSS) 와 재는 것이 달라 OS 사이에 견주지 않는다.
//
// CPU 시간은 `GetProcessTimes` 의 커널 + 사용자 시간이다 (100 ns 단위 → ns 로 낸다).
//
// `kill` 은 회차 정리다. Windows 의 Git Bash 에는 `pkill` 이 없고 (`terminals.sh` 의 `cleanup_terminals` 주석),
// 이름으로 죽이면 사용자가 따로 열어 둔 창까지 죽는다. 그래서 **측정 프로그램을 품은 터미널만** 고른다.

#include "proc-tree_windows.h"
#include <psapi.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
    DWORD cb;
    DWORD PageFaultCount;
    SIZE_T PeakWorkingSetSize;
    SIZE_T WorkingSetSize;
    SIZE_T QuotaPeakPagedPoolUsage;
    SIZE_T QuotaPagedPoolUsage;
    SIZE_T QuotaPeakNonPagedPoolUsage;
    SIZE_T QuotaNonPagedPoolUsage;
    SIZE_T PagefileUsage;
    SIZE_T PeakPagefileUsage;
    SIZE_T PrivateUsage;
    SIZE_T PrivateWorkingSetSize;
    ULONG64 SharedCommitUsage;
} PmcEx2;

static const char *SHELL_SIDE = "cmd.exe;powershell.exe;pwsh.exe;bash.exe;sh.exe;wsl.exe;"
                                "latency-child.exe;memory-child.exe;startup-child.exe;tildaz-stress.exe";

static int usage(void) {
    fprintf(stderr, "쓰는 법: proc-usage {main <pid> <이름들> | measure <pid> | kill <프로그램 이름들> <본체 이름들>}\n");
    return 2;
}

int main(int argc, char **argv) {
    if (argc < 3) return usage();
    pt_snapshot();
    if (!strcmp(argv[1], "main") && argc >= 4) {
        PtProc *m = pt_main_of((DWORD)strtoul(argv[2], NULL, 10), argv[3], NULL, NULL);
        if (!m) return 1;
        printf("%lu\n", (unsigned long)m->pid);
        return 0;
    }
    if (!strcmp(argv[1], "measure")) {
        PtProc *root = pt_find((DWORD)strtoul(argv[2], NULL, 10));
        if (!root) return 1;
        static PtProc *tree[PT_MAX];
        int n = pt_tree(root, tree, PT_MAX);
        int count = 0;
        unsigned long long mem = 0, cpu = 0;
        for (int i = 0; i < n; i++) {
            if (i > 0 && pt_name_in(tree[i]->exe, SHELL_SIDE)) continue;
            HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, tree[i]->pid);
            if (!h) continue;
            PmcEx2 pm;
            memset(&pm, 0, sizeof(pm));
            pm.cb = sizeof(pm);
            FILETIME c, e, k, u;
            unsigned long long pmem = 0, pcpu = 0;
            if (GetProcessMemoryInfo(h, (PROCESS_MEMORY_COUNTERS *)&pm, sizeof(pm))) pmem = pm.PrivateWorkingSetSize;
            if (GetProcessTimes(h, &c, &e, &k, &u))
                pcpu = ((((ULONGLONG)k.dwHighDateTime << 32) | k.dwLowDateTime) +
                        (((ULONGLONG)u.dwHighDateTime << 32) | u.dwLowDateTime)) * 100ULL;
            CloseHandle(h);
            char name[MAX_PATH];
            WideCharToMultiByte(CP_UTF8, 0, tree[i]->exe, -1, name, sizeof(name), NULL, NULL);
            printf("%lu %llu %llu %s\n", (unsigned long)tree[i]->pid, pmem, pcpu, name);
            mem += pmem; cpu += pcpu; count++;
        }
        printf("total %d %llu %llu\n", count, mem, cpu);
        return 0;
    }
    if (!strcmp(argv[1], "kill") && argc >= 4) {
        int killed = 0;
        for (int i = 0; i < g_npt; i++) {
            if (!pt_name_in(g_pt[i].exe, argv[2])) continue;
            PtProc *m = pt_main_of(g_pt[i].pid, argv[3], NULL, NULL);
            static PtProc *tree[PT_MAX];
            int n = m ? pt_tree(m, tree, PT_MAX) : 0;
            if (!m) { tree[0] = &g_pt[i]; n = 1; }
            // 자손부터 끝낸다 — 본체가 먼저 죽으면 남은 자손의 부모 정보가 흐려진다.
            for (int j = n - 1; j >= 0; j--) {
                HANDLE h = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE, tree[j]->pid);
                if (!h) continue;
                if (TerminateProcess(h, 1)) { WaitForSingleObject(h, 3000); killed++; }
                CloseHandle(h);
            }
        }
        printf("killed=%d\n", killed);
        return 0;
    }
    return usage();
}
