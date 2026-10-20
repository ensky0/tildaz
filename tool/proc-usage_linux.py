#!/usr/bin/env python3
"""터미널 하나의 메모리 · CPU 시간을 앱 밖에서 읽는다 — `tool/proc-usage_macos.c` 의 Linux 짝 (#756).

    tool/proc-usage_linux.py measure <본체 pid>
    → 줄마다 `pid 메모리(byte) CPU(ns) 이름`, 끝에 `total <개수> <메모리 byte> <CPU ns>`

**"그 터미널의 프로세스"** 는 macOS 판과 같은 뜻이다.
  - 본체 (창 주인 — `tool/kwin-window_linux.py` 의 `pid=`) 와 그 **모든 자손**.
  - **셸 쪽은 뺀다** — 이름이 셸 · `login` 이거나 측정 프로그램이 부르는 도구 (`sleep` · `awk` · `env`),
    또는 `.sh` 로 끝나는 것 (측정 프로그램 자신). Linux 는 터미널도 `/usr/bin/` 에 있어서 macOS 처럼 경로로
    가를 수 없고 이름으로만 가른다. 스크립트를 직접 실행하면 이름이 `sh` 가 아니라 스크립트 이름이 된다 —
    처음 판은 그래서 `memory-child.sh` 를 터미널 몫으로 셌다 (2026-10-13 실측).
  - GNOME Terminal 의 `bwrap` · `glycin-svg` 는 그 터미널이 띄운 이미지 로더라 터미널 몫으로 센다.
  - GNOME Terminal 은 창 주인이 D-Bus 로 뜬 `gnome-terminal-server` 라 그것이 본체다. 그 서버에 다른
    창이 있으면 함께 세어진다 — 측정 위생이 떠 있는 비교 대상 터미널을 막는 이유 중 하나다.

메모리는 **PSS** (`/proc/<pid>/smaps_rollup` 의 `Pss:`) 다 (#756 계획 — RSS 는 DE 공유 라이브러리를 프로세스마다
통째로 센다. PSS 는 공유 페이지를 나눠 센다). CPU 시간은 `/proc/<pid>/stat` 의 `utime + stime` 이다 (단위는
`SC_CLK_TCK` 틱 — `proc(5)`).
"""

import os
import sys

SHELLISH = {"sh", "bash", "zsh", "dash", "fish", "ksh", "login", "sleep", "awk", "gawk", "mawk", "env"}
TICK_NS = 1e9 / os.sysconf("SC_CLK_TCK")


def stat(pid):
    """(이름, 부모 pid, CPU ns). 없으면 None."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            s = f.read()
    except OSError:
        return None
    # comm 에 공백 · 괄호가 들어갈 수 있어 첫 '(' 와 마지막 ')' 로 자른다 (`proc(5)`).
    comm = s[s.index("(") + 1 : s.rindex(")")]
    rest = s[s.rindex(")") + 2 :].split()
    # rest[0] 은 3 번째 칸 (state) 이다. ppid 4 · utime 14 · stime 15 번째 칸.
    return comm, int(rest[1]), (int(rest[11]) + int(rest[12])) * TICK_NS


def pss(pid):
    try:
        with open(f"/proc/{pid}/smaps_rollup") as f:
            for line in f:
                if line.startswith("Pss:"):
                    return int(line.split()[1]) * 1024
    except OSError:
        pass
    return 0


def measure(main):
    children = {}
    for d in os.listdir("/proc"):
        if d.isdigit():
            st = stat(int(d))
            if st:
                children.setdefault(st[1], []).append(int(d))
    todo, seen = [main], []
    while todo:
        p = todo.pop()
        seen.append(p)
        todo.extend(children.get(p, []))
    total_mem = total_cpu = n = 0
    for p in sorted(seen):
        st = stat(p)
        if st is None or st[0] in SHELLISH or st[0].endswith(".sh"):
            continue
        mem = pss(p)
        print(f"{p} {mem} {int(st[2])} {st[0]}")
        total_mem += mem
        total_cpu += st[2]
        n += 1
    print(f"total {n} {total_mem} {int(total_cpu)}")


def main():
    if len(sys.argv) != 3 or sys.argv[1] != "measure":
        print(__doc__, file=sys.stderr)
        return 2
    measure(int(sys.argv[2]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
