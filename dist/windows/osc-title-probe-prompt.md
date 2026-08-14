# Windows 실측 프롬프트 — 셸이 첫 OSC 제목을 보내는 시점 (#364)

> 이 파일 전체가 **Windows 머신의 Claude Code 세션에 그대로 붙여 넣는 프롬프트**다.
> Linux 쪽 실측은 이미 끝났고 (`dist/linux/osc-title-probe.zig` +
> [#364 댓글](https://github.com/ensky0/tildaz/issues/364#issuecomment-5151754093)),
> Windows 는 ConPTY 라 같은 도구를 쓸 수 없어서 같은 방법론을 Windows API 로 재현해야 한다.

**Linux 기준값** (CachyOS, 셸당 n=10, `fork` 기준 첫 non-empty OSC 0/2 의 min~max):

| 셸 | 첫 출력 byte | 첫 제목 | 비고 |
|---|---|---|---|
| bash 5.3.15 | 8.6 ms | 7.9~9.6 ms | `/etc/bash.bashrc` 의 `PROMPT_COMMAND` |
| fish 4.8.1 | 24.6 ms | 43.2~54.7 ms | fish 기본 `fish_title` |
| zsh 5.9.2 + Powerlevel10k | 4.4 ms | **327.8~409.6 ms** | 200~300 ms 유예를 기각시킨 값 |
| `sh` (bash POSIX 모드) / 순수 zsh | — | **미전송** | `Tab N` fallback 경로 |

Windows 결과는 이 표에 이어 붙일 수 있는 형태로 내줘.

---

먼저 `AGENTS.md` 를 읽고 그 워크플로우를 따라줘. 그다음 아래 작업을 해줘.

## 목적

[#364](https://github.com/ensky0/tildaz/issues/364) 의 개선안 2번 — **초기 제목 유예를 1 초에서 200~300 ms 로 줄여도 되는지**를 판정할 근거를 Windows 에서 실측한다. 근거 없이 숫자만 줄이면 OSC 를 늦게 보내는 셸에서 `Tab N` → 실제 제목 깜빡임이 생긴다.

관련 코드 ([`src/session_core.zig`](../../src/session_core.zig)) — **cross-platform 공통**이라 세 platform 이 같은 유예를 쓴다:

```zig
const TITLE_DEBOUNCE_NS: u64 = 150 * std.time.ns_per_ms;
const INITIAL_TITLE_GRACE_NS: u64 = std.time.ns_per_s;   // 1 초
```

Windows 에서 증상이 더 자주 보이는 이유는 지연이 더 길어서가 아니라 **cmd / PowerShell 이 OSC 0/2 를 안 보내는 경우가 많아** fallback 경로를 자주 타기 때문이다. 그래서 Windows 실측의 질문은 두 개다.

1. Windows 셸 중 OSC 0/2 를 **보내는** 것이 있는가. 보낸다면 **몇 ms 에** 보내는가.
2. 안 보내는 셸은 어느 것인가 (= 유예를 다 기다린 뒤 `Tab N` 이 뜨는 경로).

## 재는 값의 정의

- **시각 0** = 자식 셸 프로세스를 만든 직후. tildaz 는 `TerminalBackend.init` (ConPTY + `CreateProcessW`) 이 끝난 다음 `Tab.title_clock` 을 시작하고, 그 clock 으로 유예를 판정한다 ([`session_core.zig` `Tab.init`](../../src/session_core.zig)).
- **첫 제목** = ConPTY output pipe 로 들어온 **첫 non-empty OSC 0 또는 OSC 2**. OSC 1 (icon) 은 제외 — ghostty-vt 의 `getTitle()` 에 안 들어간다. payload 가 빈 OSC (`\e]0;\a`) 도 제외 — 유예 중에는 usable title 로 인정되지 않는다 (`queueAutomaticTitle`).
- **마지막 제목** = 관측 창 안에서 마지막으로 바뀐 제목. `TITLE_DEBOUNCE_NS` (150 ms) 안정화 시점을 판단하는 데 쓴다.
- **질의** = 자식이 보낸 터미널 질의 (DA1 / DSR / XTVERSION / DECRQM / kitty / OSC 색). Windows 에서 tildaz 는 **readonly VT stream** 을 유지하므로 (#266 / #269, `session_core.zig` 의 `comptime builtin.os.tag != .windows` 분기) 이 질의들에 **응답하지 않는다**. 그러니 probe 도 응답하면 안 된다 — 응답하면 실제 앱보다 빠른 값이 나온다.

## 충실도 요건 — 이걸 어기면 측정이 무의미하다

[`src/terminal/windows/pty.zig`](../../src/terminal/windows/pty.zig) 를 읽고 spawn 조건을 그대로 복제해줘. 특히:

1. **ConPTY 생성** — `CreatePseudoConsole` (번들 `OpenConsole.dll` 경로가 있으면 tildaz 와 같은 쪽을 쓴다), pipe 4개, `cols`/`rows` 는 아무 값이나 (예 120×30) 로 고정하고 보고에 적어줘.
2. **`CreateProcessW`** — `EXTENDED_STARTUPINFO_PRESENT` + `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` (`0x00020016`) + `STARTF_USESTDHANDLES` + NULL std handle. 이 플래그를 빼면 셸이 비대화형으로 판단해 즉시 종료한다 (#338).
3. **DA1 pre-response 를 반드시 재현** — tildaz 는 프로세스 생성 직후 input pipe 에 `\x1b[?61c` 를 미리 쓴다. 안 쓰면 OpenConsole 의 `WaitUntilDA1(3000)` 이 3 초 타임아웃을 다 기다려 **첫 프롬프트가 ~3.9 초 늦는다** ([`pty.zig` 의 DA1 pre-response 주석](../../src/terminal/windows/pty.zig)). 이걸 빼먹으면 측정값이 통째로 3 초 밀린다.
4. **시작 디렉토리** = `%USERPROFILE%` (#265). WSL 셸이면 명령줄에 `--cd ~` 를 끼우는 tildaz 방식을 그대로.
5. **환경변수** — Windows 는 `COLORFGBG` (dark 테마면 `15;0`) 와 `WSLENV` (`COLORFGBG` 추가) 만 명시 설정한다. `TERM` / locale 은 ConPTY 와 셸 기본에 위임 (AGENTS.md "터미널 환경변수" 표). tildaz 의 `buildExtraEnv` 를 그대로 따라줘.
6. **질의 무응답** — 위 "정의" 항목대로 DA1 pre-response 를 제외한 어떤 질의에도 답하지 않는다. 단 **어떤 질의가 언제 왔는지는 전부 기록**해줘 (무응답 대기로 시점이 밀리면 timeline 에 그대로 드러나야 한다).

## 구현 지침

- Linux 판 [`dist/linux/osc-title-probe.zig`](../linux/osc-title-probe.zig) 를 참고해줘. OSC / CSI / DCS 파서, 이벤트 기록, run 반복, 통계 출력, `--runs` / `--window-ms` / `--verbose` 인자 처리 구조를 그대로 가져오고 **PTY spawn 부분만 ConPTY 로 교체**하면 된다.
- 파일은 `dist/windows/osc-title-probe.zig` — tildaz 본체 빌드에 넣지 않는 독립 측정 도구다 (`dist/linux/dmabuf-probe.zig` / `dist/macos/color-capture.m` 와 같은 위치의 물건). 이후 #451에서 Zig API 호환을 놓치지 않도록 `zig build probe-check`의 compile-only 대상에는 포함됐다.
- 빌드: `zig build-exe dist/windows/osc-title-probe.zig -O ReleaseSafe -lc --cache-dir C:/ziglang/tildaz-cache`. Debug 는 링커 문제를 피하려고 쓰지 않는다.
- 파일 맨 위 doc comment 에 "Windows 전용 (ConPTY)" 와 `comptime` 가드를 넣어줘 (Linux 판과 같은 패턴).
- 출력은 run 별 한 줄 + 마지막에 min / median / mean / max + **유예 후보별 판정** (1000 / 500 / 300 / 250 / 200 / 150 / 100 ms 각각에서 "첫 제목이 유예보다 늦은 run 수") 까지. Linux 판 출력 형식을 그대로 맞춰줘 — 두 platform 결과를 같은 표로 합쳐야 한다.

## 실행 매트릭스

이 머신에서 **실측 가능한 모든 셸**을 다 재줘. 없는 것은 "미설치" 로 적고 넘어가면 된다.

| 셸 | 비고 |
|---|---|
| `cmd.exe` | config 기본값 (`config.zig` 의 `Defaults.shell`) |
| `powershell.exe` | Windows PowerShell 5.1 |
| `pwsh.exe` | PowerShell 7 — 설치되어 있으면 |
| `wsl.exe` (+ 배포판 기본 셸) | WSL distro 가 설치되어 있으면. AGENTS.md 대로 있다고 가정하지 않는다 |
| 그 밖에 설치된 셸 | Git Bash (`bash.exe`), nu, elvish 등 있으면 전부 |

각 셸마다:

- **10 run** (첫 run 은 cold 라 느릴 수 있으니 min / median / max 를 모두 보고)
- 관측 창은 첫 제목이 확실히 들어오도록 여유 있게 (기본 3000 ms, OSC 를 안 보내는 셸은 미수신 확인용으로 그대로 3000 ms)
- PowerShell 은 **프로필 유무가 결정적일 수 있다** (PSReadLine / oh-my-posh / starship 이 제목을 심는다). 프로필 있는 상태 그대로 한 벌, `-NoProfile` 로 한 벌 재고 둘 다 보고해줘. 프로필 경로 (`$PROFILE`) 와 그 안에 제목을 심는 코드가 있는지도 같이 확인해서 적어줘.
- WSL bash 는 `/etc/bash.bashrc` 나 `~/.bashrc` 의 `PROMPT_COMMAND` 가 OSC 0 을 심는지 (배포판마다 다르다) 확인하고 적어줘.

## 보고 형식

결과는 **[#364](https://github.com/ensky0/tildaz/issues/364) 댓글**로 기록해줘 (AGENTS.md: 작업 기록은 이슈에). 형식:

1. **측정 조건** — 머신 / Windows 버전 / ConPTY 경로 (번들 OpenConsole vs 시스템 conhost) / cols×rows / probe 커밋
2. **셸별 표** — 셸 | 프로필 | 첫 제목 min / median / max (ms) | 제목 횟수 | 질의 수 | OSC 전송 여부
3. **유예 후보별 판정 표** — 1000 / 500 / 300 / 250 / 200 / 150 ms 에서 늦은 run 수
4. **timeline 예시** — 셸 하나당 `--verbose` 출력 한 벌 (질의 시점 포함)
5. **결론** — Windows 기준으로 유예를 얼마까지 줄일 수 있는지, OSC 를 안 보내는 셸이 무엇인지. 판단이 아니라 **측정값으로 말해줘.**
6. Linux 결과 댓글 링크를 달고 차이가 있으면 짚어줘.

숫자를 요약할 때 **추정과 실측을 섞지 마.** 안 재본 셸은 "미측정" 으로 남겨줘.

## 규칙 (AGENTS.md 요약)

- 모든 대화 / 커밋 / 이슈 댓글은 **한국어**.
- 모든 도구 호출에 `timeout: 60000` 명시. 1 분 넘게 걸릴 빌드는 background.
- `Co-Authored-By` 트레일러 금지.
- **방향 결정은 단독으로 하지 마.** 이 작업은 *측정만* 이다 — `session_core.zig` 의 상수를 고치는 건 이 작업 범위가 아니다. 측정이 끝나면 결과를 보고하고 사용자 판단을 기다려줘.
- 작업 브랜치는 `probe/364-osc-title-timing` (Linux probe 가 이미 이 브랜치에 있다). 여기에 `dist/windows/osc-title-probe.zig` 를 추가 커밋해줘.
