// proc-usage_macos.c — 터미널 하나의 메모리 · CPU 시간을 앱 밖에서 읽는다 (#756).
//
//   clang -O2 -o /tmp/proc-usage tool/proc-usage_macos.c
//   /tmp/proc-usage find <경로 일부> [제외할 pid 목록 파일]   # 경로에 그 문자열이 든 프로세스 중 가장 늦게 뜬 pid
//   /tmp/proc-usage measure <본체 pid>                       # 아래 집합의 줄마다 pid · 메모리 · CPU 시간 · 경로, 끝에 total
//
// **"그 터미널의 프로세스" 의 정의** (2026-10-13 macOS 실측으로 정했다):
//   - 본체와 그 **모든 자손**, 그리고 실행 파일이 **본체와 같은 앱 번들 안**에 있는 프로세스.
//     kitty 는 자식 `kitten` 둘, iTerm2 는 자식 `iTermServer` (번들 밖) 와 부모가 launchd 인
//     `pidinfo.xpc` (번들 안) 가 있다.
//   - **셸 쪽은 뺀다** — 실행 파일이 `/bin/` · `/usr/bin/` · `/usr/sbin/` 아래이거나, 이름이 셸 · `login`
//     인 것 (측정용 자식 · 로그인 셸). 모든 대상에 같이 붙는 것이라 터미널의 몫이 아니다.
//   - "측정 동안 새로 생긴 프로세스 전부" 로는 안 된다 — 무관한 시스템 서비스 (`mdworker_shared` ·
//     `SetStoreUpdateService` 등) 가 그 사이 우연히 뜬다.
//
// 메모리는 `ri_phys_footprint` 다 — Activity Monitor 의 "메모리" 열과 같은 값이다. CPU 시간은
// `ri_user_time + ri_system_time` 이다. **두 시간의 단위는 SDK 헤더에 적혀 있지 않다.** Apple Silicon 에서는
// mach 시간 단위로 와서 `mach_timebase_info` 로 나노초로 바꾼다 (확인: `yes` 를 1 초 돌려 1.0 초 남짓이
// 나오는지 — README 의 메모리 · 유휴 CPU 절).
//
// 같은 사용자의 프로세스면 루트 없이 읽힌다 (`proc_pid_rusage` 는 task port 가 필요 없다).

#include <libproc.h>
#include <mach/mach_time.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/resource.h>

#define MAX_PIDS 16384

static int g_pids[MAX_PIDS];
static int g_npids = 0;

static void listPids(void) {
    int n = proc_listallpids(g_pids, (int)sizeof(g_pids));
    g_npids = n > 0 ? n : 0;
}

static int pathOf(int pid, char *buf) {
    buf[0] = 0;
    return proc_pidpath(pid, buf, PROC_PIDPATHINFO_MAXSIZE) > 0;
}

static int bsdOf(int pid, struct proc_bsdinfo *bi) {
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, bi, (int)sizeof(*bi)) == (int)sizeof(*bi);
}

static int inFile(const char *file, int pid) {
    if (!file) return 0;
    FILE *f = fopen(file, "r");
    if (!f) return 0;
    int v, hit = 0;
    while (fscanf(f, "%d", &v) == 1)
        if (v == pid) { hit = 1; break; }
    fclose(f);
    return hit;
}

// 경로만 보면 Homebrew 의 셸 (`/opt/homebrew/…/bash`) 이 빠지지 않는다. iTerm2 · Terminal.app 은 사용자의
// 로그인 셸을 띄우므로, 그 셸이 Homebrew 판이면 두 대상에만 셸 몫이 더해진다. 그래서 이름으로도 거른다.
static int isShellSide(const char *path) {
    if (strncmp(path, "/bin/", 5) == 0 || strncmp(path, "/usr/bin/", 9) == 0 ||
        strncmp(path, "/usr/sbin/", 10) == 0)
        return 1;
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    static const char *shells[] = {"sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "login", NULL};
    for (int i = 0; shells[i]; i++)
        if (strcmp(base, shells[i]) == 0) return 1;
    return 0;
}

// 후보가 여럿이면 **부모가 후보가 아닌 것 (맨 위)** 을 본체로 고른다. kitty 는 같은 실행 파일의
// 프로세스가 둘이다 — 부모가 launchd 인 창 프로세스와 그 자식. 가장 늦게 뜬 것을 고르던 처음 판은
// 곧 끝나는 자식을 집어 메모리를 못 읽었다 (2026-10-13 실측). 맨 위가 여럿이면 가장 늦게 뜬 것.
static int cmdFind(const char *needle, const char *exclude_file) {
    listPids();
    static int cand[MAX_PIDS], cand_ppid[MAX_PIDS];
    static uint64_t cand_start[MAX_PIDS];
    int nc = 0;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    for (int i = 0; i < g_npids; i++) {
        int pid = g_pids[i];
        if (pid <= 0 || !pathOf(pid, path) || !strstr(path, needle)) continue;
        if (inFile(exclude_file, pid)) continue;
        struct proc_bsdinfo bi;
        if (!bsdOf(pid, &bi)) continue;
        cand[nc] = pid;
        cand_ppid[nc] = (int)bi.pbi_ppid;
        cand_start[nc] = bi.pbi_start_tvsec * 1000000ULL + bi.pbi_start_tvusec;
        nc++;
    }
    int best = 0;
    uint64_t best_start = 0;
    for (int i = 0; i < nc; i++) {
        int parent_is_cand = 0;
        for (int j = 0; j < nc; j++)
            if (cand[j] == cand_ppid[i]) { parent_is_cand = 1; break; }
        if (parent_is_cand) continue;
        if (cand_start[i] >= best_start) { best_start = cand_start[i]; best = cand[i]; }
    }
    if (!best) return 1;
    printf("%d\n", best);
    return 0;
}

static int cmdMeasure(int main_pid) {
    listPids();
    char main_path[PROC_PIDPATHINFO_MAXSIZE];
    if (!pathOf(main_pid, main_path)) {
        fprintf(stderr, "pid %d 의 경로를 못 읽었어요 (이미 끝났나요?)\n", main_pid);
        return 2;
    }
    // 본체의 앱 번들 (`….app/`) — 없으면 (CLI 실행 파일) 번들 규칙은 안 쓴다.
    char bundle[PROC_PIDPATHINFO_MAXSIZE] = "";
    char *app = strstr(main_path, ".app/");
    if (app) {
        size_t len = (size_t)(app - main_path) + 5;
        memcpy(bundle, main_path, len);
        bundle[len] = 0;
    }

    static int ppid_of[MAX_PIDS];
    for (int i = 0; i < g_npids; i++) {
        struct proc_bsdinfo bi;
        ppid_of[i] = bsdOf(g_pids[i], &bi) ? (int)bi.pbi_ppid : -1;
    }
    static char in_set[MAX_PIDS];
    memset(in_set, 0, sizeof(in_set));
    // 자손 — 바뀌는 것이 없을 때까지 넓힌다 (프로세스 수가 적어 이 정도로 충분하다).
    for (int i = 0; i < g_npids; i++)
        if (g_pids[i] == main_pid) in_set[i] = 1;
    for (int changed = 1; changed;) {
        changed = 0;
        for (int i = 0; i < g_npids; i++) {
            if (in_set[i] || ppid_of[i] <= 0) continue;
            for (int j = 0; j < g_npids; j++)
                if (in_set[j] && g_pids[j] == ppid_of[i]) { in_set[i] = 1; changed = 1; break; }
        }
    }

    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    uint64_t total_mem = 0, total_cpu = 0;
    int count = 0;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    for (int i = 0; i < g_npids; i++) {
        int pid = g_pids[i];
        if (pid <= 0 || !pathOf(pid, path)) continue;
        int pick = in_set[i] || (bundle[0] && strncmp(path, bundle, strlen(bundle)) == 0);
        if (!pick || isShellSide(path)) continue;
        struct rusage_info_v4 ri;
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) continue;
        uint64_t cpu_ns = (ri.ri_user_time + ri.ri_system_time) * tb.numer / tb.denom;
        printf("%d %llu %llu %s\n", pid, (unsigned long long)ri.ri_phys_footprint,
               (unsigned long long)cpu_ns, path);
        total_mem += ri.ri_phys_footprint;
        total_cpu += cpu_ns;
        count++;
    }
    printf("total %d %llu %llu\n", count, (unsigned long long)total_mem, (unsigned long long)total_cpu);
    return count ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc >= 3 && strcmp(argv[1], "find") == 0) return cmdFind(argv[2], argc >= 4 ? argv[3] : NULL);
    if (argc >= 3 && strcmp(argv[1], "measure") == 0) return cmdMeasure(atoi(argv[2]));
    fprintf(stderr,
            "쓰는 법: proc-usage find <경로 일부> [제외할 pid 목록 파일]\n"
            "         proc-usage measure <본체 pid>\n");
    return 2;
}
