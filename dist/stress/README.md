# stress / 처리량 하네스

대용량 출력을 소화하는 속도를 재고, 장시간·고부하에서 깨지지 않는지 확인하는
하네스예요. [#371](https://github.com/ensky0/tildaz/issues/371) (처리량 측정) 과
[#278](https://github.com/ensky0/tildaz/issues/278) (stress test harness) 이 함께
쓰는 도구예요.

**Linux · macOS · Windows 에서 같은 명령으로 돌아요.** 셸 스크립트가 아니라 Zig
프로그램인 이유는 [#371 코멘트 1 절](https://github.com/ensky0/tildaz/issues/371#issuecomment-5163867655)
에 있어요 — 요약하면 부하를 주는 층과 시간을 재는 층이 platform 마다 갈려서, 셸로
감싸도 공통이 되는 부분이 거의 없어요.

## 쓰는 법

```sh
# 파서 상한 — PTY 도 프로세스도 없이 VT 파서만
zig build stress -Doptimize=ReleaseFast -Dsimd=true -- throughput --layer parser --mb 64

# PTY 전체 — 자식 프로세스 → PTY → read thread → ring → VT 파서
zig build stress -Doptimize=ReleaseFast -Dsimd=true -- throughput --layer pty --mb 64

# 앱이 실제로 지나는 경로 — 프레임마다 8 ms 예산이 걸린다
zig build stress -Doptimize=ReleaseFast -Dsimd=true -- throughput --layer frame --mb 64

# 워크로드 바꾸기
zig build stress -Doptimize=ReleaseFast -Dsimd=true -- throughput --layer frame --workload cjk

# scrollback 이 쌓이는 동안 속도가 유지되는지 (#278 ①)
zig build stress -Doptimize=ReleaseFast -Dsimd=true -- scrollback --mb 256
```

## 두 가지 명령

| 명령 | 보는 것 | 판정 |
|---|---|---|
| `throughput` | 얼마나 빨리 소화하나 | 절대 속도 |
| `scrollback` | scrollback 이 쌓여도 속도가 유지되나 | **구간 간 비교** — 뒤 구간이 느려지면 줄 수에 비례하지 않는 비용이 있다는 신호예요 |

`scrollback` 은 출력을 구간으로 나눠 구간마다 처리 속도 · 총 줄 수 · 메모리 최고치를
찍어요. 오래 켜 둔 터미널에서만 드러나는 종류의 회귀를 찾는 것이 목적이라 절대
속도보다 **구간 사이의 변화**가 중요해요. 프레임 예산이 없는 경로로 돌려요 — 예산에
눌린 상태에서는 구간 간 차이가 예산에 가려 안 보여요.

| 옵션 | 값 | 기본값 |
|---|---|---|
| `--layer` | `parser` · `pty` · `frame` | `parser` |
| `--workload` | `plain` · `ansi` · `cjk` | `plain` |
| `--mb` | 쏟아부을 MiB | `64` |
| `--cols` / `--rows` | 그리드 | `120` × `40` |
| `--scrollback` | scrollback 줄 수 | config 기본값 (100,000) |
| `--fps` | `frame` 층이 모사할 프레임 주기 | `60` |
| `--segments` | `scrollback` 이 나눠 볼 구간 수 | `8` |

### 층

| 층 | 지나는 경로 | 빠지는 것 |
|---|---|---|
| `parser` | 워크로드 → VT 파서 → grid | PTY · 자식 프로세스 · ring · 프레임 예산 |
| `pty` | 자식 → PTY → read thread → ring → VT 파서 → grid | 렌더 · 프레임 예산 |
| `frame` | 위와 같지만 **프레임마다 8 ms 예산**을 지킨다 | 렌더만 |

`pty − parser` 가 PTY read 와 ring 층의 몫이에요. `perf` 를 쓸 수 없는 환경에서도
시간이 어디서 가는지 가를 수 있어요.

**`frame` 이 사용자가 겪는 값에 가장 가까워요.** host 는 vsync 마다
`drainOutputForRender` 를 부르고 그 안의 `drainFrame` 이 한 프레임에 8 ms 만
파싱해요 (`SessionCore.DRAIN_FRAME_BUDGET_NS`). 이 층은 그 주기를 `--fps` 로
모사해요. 다만 **렌더를 하지 않으니 체감의 상한**이에요 — 실제 앱은 여기에 렌더
시간이 더해져요.

리포트의 `over budget` 이 예산을 넘긴 프레임 수예요. 실제 앱에서는 그 프레임마다
vsync 를 놓쳐요 — 즉 이 숫자가 사용자가 보는 "멈칫" 의 빈도예요.

### 워크로드

세 워크로드는 모두 **결정적이에요** — 같은 옵션이면 어느 platform 에서든 같은
바이트가 나와요. 난수 · 시각 · locale · 셸을 쓰지 않아요. 입력이 다르면 숫자를
나란히 둘 수 없기 때문이에요.

| 이름 | 내용 | 태우는 경로 |
|---|---|---|
| `plain` | 80 byte ASCII 줄 | 파서에 가장 싼 길 |
| `ansi` | SGR 색이 섞인 빌드 로그 모양 | escape sequence 파싱 |
| `cjk` | 한글 · emoji · 스킨톤 · ZWJ 묶음 · block element | wide cell · grapheme cluster |

## 부하를 만드는 쪽도 우리 자신이에요

`--layer pty` 는 PTY 자식으로 셸이 아니라 **이 실행파일을 producer 모드로** 띄워요.
그래서

- Windows 기본 셸이 `cmd.exe`, POSIX 가 `/bin/bash` 인 차이가 측정에서 사라져요
  (`cat` / `time` / `seq` 가 셸마다 다르거나 없어요).
- 쏟아붓는 바이트가 세 platform 에서 완전히 같아요.

producer 파라미터는 인자가 아니라 환경변수 (`TILDAZ_STRESS_WORKLOAD` /
`TILDAZ_STRESS_BYTES`) 로 넘겨요 — POSIX 는 PTY 자식의 argv 가 고정이라 인자를 넘길
수 없어요 ([`terminal/posix/pty.zig`](../../src/terminal/posix/pty.zig)).

## 결과를 기록하는 규칙

숫자만 적으면 나중에 비교할 수 없어요. **아래를 항상 함께** 남겨요.

| 항목 | 왜 |
|---|---|
| 빌드 조합 (`optimize` · `simd`) | Debug 와 ReleaseFast 가 수천 배 차이나요 (실측: 같은 워크로드가 0.1 MiB/s ↔ 550 MiB/s). `-Dsimd` 는 정확히 ghostty-vt 의 VT stream 파서를 켜는 옵션이에요 |
| 그리드 (`--cols` × `--rows`) | 열 수가 줄바꿈 횟수를 바꿔서 파서 부하가 달라져요 |
| 워크로드 | ASCII 와 CJK 가 5~6 배 차이나요 |
| 머신 (CPU · 메모리 · OS 버전) | 절대값은 머신마다 달라요 |
| 측정 시점의 다른 부하 | 아래 참고 |

리포트 머리글이 빌드 조합 · 그리드 · 워크로드 · platform 을 이미 찍으니 **그 출력을
그대로 붙이는 것**이 가장 정확해요.

**숫자는 이 저장소에 baseline 으로 두지 않아요.** 머신마다 달라서 "누구 머신 기준"
문제가 생겨요. 측정 결과는 관련 GitHub 이슈 코멘트에 남겨요 (`AGENTS.md` 의 "작업
기록은 이슈에" 와 같은 이유).

## 측정 전 확인할 것

[#362 에서 실제로 겪은 것들](https://github.com/ensky0/tildaz/issues/362#issuecomment-5154477404)
이에요.

- **다른 부하를 먼저 확인해요** (`ps -Ao pid,pcpu,comm -r | head`). 미디어 재생이나
  토런트가 켜져 있어 같은 조건 재측정이 ±8 % 흔들린 적이 있어요.
- **빌드와 측정을 동시에 돌리지 않아요.** `zig build` 가 모든 코어를 먹어서 측정
  한 회차를 오염시킨 적이 있어요.
- **A / B 를 번갈아 돌려요.** 몰아서 돌리면 −8 % 로 보였던 것이 번갈아 돌렸을 때
  −1.5 % 였어요.
- **여러 번 재요.** 이 하네스도 같은 조건 재실행이 ±15 % 흔들려요 (macOS 실측).

## 알려진 것 / 아직 모르는 것

### PTY 층의 수신 바이트는 보낸 것보다 많고, **그 성질이 platform 마다 달라요**

`\n` 이 `\r\n` 으로 나오는 것 (termios `ONLCR`) 이 공통 원인이고, 리포트의
`expected … minimum` 이 그것까지 계산한 값이에요. 그런데 그 위에 얹히는 초과분이
platform 마다 전혀 달라요 (전부 실측이에요).

| platform | 초과분 | 성질 |
|---|---|---|
| Linux | **`+0`** | `ONLCR` 변환 외에 아무것도 더하지 않아요. 예상값이 한 byte 도 안 어긋나요 |
| macOS | 64 MiB 에서 **+819 byte** (0.0013 %) | 줄 수에 정비례하고, 터미널 폭 · 줄 길이 · write 조각 크기와 무관하며, 데이터 없이 `\n` 만 보내면 안 생겨요. tty 드라이버 출력 처리에서 오는 것으로 보이지만 **정확한 규칙은 확정하지 않았어요** |
| Windows | `plain` +1.3 % · `ansi` +1.0 % · **`cjk` +25.6 %** | ConPTY 가 자기 시퀀스를 끼워 넣어요. wide char 에서 특히 심하고 `readloop` 호출 수도 1,026 → 6,922 로 뛰어요. **원인은 확인 필요** |

그래서 두 가지를 이렇게 다뤄요.

- **`expected` 판정은 한 방향으로만** 써요 — 모자라면 데이터 손실이고 남는 건 정상이에요.
  Windows 는 위 표대로 예상값을 계산할 수 있는 종류가 아니라 `expected` 줄을 아예 안 찍어요.
- **처리량을 두 줄로** 찍어요. 소화한 바이트 기준과 **보낸 바이트 기준**을 함께 내요.
  소화 기준만 보면 부풀림이 큰 platform 이 유리하게 보여요 — Windows `cjk` 는 소화
  기준 62.3 MiB/s 인데 보낸 기준으로는 49.6 MiB/s 예요. **platform 사이를 비교할 때는
  보낸 바이트 기준 줄을 봐요.**
- **`parser` 층의 숫자는 파서의 진짜 상한보다 낮을 수 있어요.** 같은 코어에서
  워크로드를 만들면서 파싱하므로 생성이 캐시를 밀어내요. 실측에서 `plain` 이
  `parser` 층 736 MiB/s 인데 `frame` 층의 `drain busy` 는 1,058 MiB/s 였어요 — 후자는
  바이트를 다른 프로세스가 만들어요. 그래서 `parser` 는 **하한에 가까운 값**으로
  읽는 게 안전해요.
- `parser` 층의 stream 은 응답 통로가 없는 읽기 전용이에요. 프로덕션은 Windows 만
  읽기 전용이고 macOS · Linux 는 질의 응답용 effects 가 붙어요 (#266). 이 하네스의
  워크로드에는 응답이 필요한 질의가 없어서 파싱 비용이 같을 것으로 보지만 **직접 재서
  확인하지는 않았어요.**
- **`push` 의 `yields` 가 크면 우리가 못 따라가고 있다는 뜻이에요.** ring 이 가득 차서
  read thread 가 양보한 횟수예요. 이 값이 크면 `push` 시간도 함께 커지고 (실측: macOS
  `frame` cjk 에서 248 만 회 · 243 ms, Linux 는 `push` 가 `drain` 보다 컸어요) 압력이
  producer 까지 전달돼요 — 실제 앱에서는 **셸이 느려지는 것**으로 나타나요.
- **`readloop` 시간은 platform 사이를 비교하면 안 돼요.** POSIX 는 poll 대기를 빼고 read
  복사만 재는데 Windows 는 유휴 대기를 포함해요 (#254 결정). 리포트가 어느 쪽인지
  괄호로 적어 줘요.
- **Windows 는 `zig build stress` 가 install 경로에서 실행돼야 해요.** ConPTY 는 실행파일
  옆 `_internal\conpty.dll` 이 필수인데 (#339 에서 kernel32 fallback 제거) zig 캐시의
  output 디렉토리에는 그것을 놓을 자리가 없어요. `build.zig` 가 `addInstallArtifact` +
  `zig-out/bin` 실행으로 처리해요 — 이걸 `addRunArtifact` 로 되돌리면 Windows 에서
  `parser` 층 말고 전부 `error.ConptyRuntimeUnavailable` 로 즉시 실패해요.
- **ConPTY 가 우리가 모르는 시퀀스를 보내요.** PTY 를 쓰는 모든 Windows 실행에서
  `CSI 1 t` (XTWINOPS de-iconify) 와 DEC private mode `9001` 경고가 나와요. 무해하게
  무시되고 측정값에도 영향이 없지만 **실사용 앱도 같은 것을 받아요.**
- **scrollback 메모리는 줄당 약 1 KiB 예요** (120 열 기준, macOS 실측: 100만 줄 =
  1,008 MiB, 기본값 10만 줄 = 120 MiB). 셀 하나가 8 byte 이고 page 가 고정 폭이라
  `줄 수 × 열 수 × 8 byte` 에 가까워요. 열 수가 많은 창에서는 그만큼 늘어나요.
## 다른 터미널과 비교하기

```sh
dist/stress/compare-terminals.sh --mb 64 --workload plain --cols 120 --rows 40
```

같은 producer 를 여러 터미널 안에서 돌리고 완료 시간을 모아요. producer 가 출력을 끝낸 뒤
경과 시간과 **자기 그리드 크기**를 timing 파일에 적고, 스크립트가 그것을 표로 내요.

**그리드를 함께 남기는 게 핵심이에요.** 터미널마다 폰트 크기 해석이 달라서 같은 창 크기를
줘도 셀 수가 갈리고, 열 수가 다르면 줄바꿈 횟수가 달라져 파서 부하가 달라져요. 표의 grid
열이 목표와 다르면 그 줄은 비교에 쓰지 않아요. 실제로 이 검증이 kitty 의 창 크기 옵션이
무시되던 것과 ghostty 의 옵션 파싱 실패를 잡아냈어요.

| 방식 | 대상 | 이유 |
|---|---|---|
| 자동 | alacritty · kitty · wezterm (+ Linux 의 ghostty · foot) | CLI 로 그리드를 정확히 지정할 수 있어요 |
| **손으로** | **TildaZ** · **macOS 의 ghostty** | 아래 참고 |

- **TildaZ** 는 CLI 로 명령을 주입할 수 없어요 (`--instance` / `--autostart` / `--toggle` 만
  받아요). 스크립트가 붙여넣을 한 줄을 찍어 줘요.
- **macOS 의 ghostty** 는 CLI 로 터미널을 띄울 수 없고 (`ghostty --help`: *"On macOS,
  launching the terminal emulator from the CLI is not supported"*), `open -na … --args` 로는
  옵션 여러 개가 **한 값으로 합쳐져** 전달돼서 창 크기를 정할 수 없어요 (실측: config 에러
  다이얼로그가 떠요). Linux 의 ghostty 는 CLI 가 정상이라 자동으로 돌려요.

손으로 재도 **그리드는 producer 가 스스로 기록**하니 공정성은 유지돼요. 창을 목표 그리드로
맞춰 열고 한 줄 붙여넣으면 자동으로 잰 것과 같은 조건 (렌더 포함) 이 돼요.

**터미널마다 창 크기 지정 방법이 달라요** (실측으로 확정한 것):

| 터미널 | 그리드 지정 |
|---|---|
| kitty | `-o remember_window_size=no -o initial_window_width=120c -o initial_window_height=40c` — `remember_window_size` 를 끄지 않으면 **이전 세션 크기를 복원해서 옵션을 무시해요** |
| alacritty | `-o window.dimensions.columns=120 -o window.dimensions.lines=40` |
| wezterm | `--config initial_cols=120 --config initial_rows=40` — `--config` 는 **전역 옵션**이라 `start` **앞**에 와야 해요 |
| ghostty (Linux) | `--window-width=120 --window-height=40` |
| ghostty (macOS) | `~/.config/ghostty/config` 에 `window-width = 120` · `window-height = 40` |
| TildaZ | config 의 `width_percent` / `height_percent` 와 `font.size` |

**일부 터미널은 셸을 spawn 한 뒤 창 크기에 맞춰 resize 해요** (실측: ghostty · kitty).
그래서 producer 는 그리드를 **출력 전후 두 번** 읽고 둘 다 기록해요. 표에 `측정 중 resize`
가 뜨면 그 측정은 그리드가 흔들린 거예요.

- 아직 없는 것: TildaZ · ghostty 의 macOS 수동 측정값, Linux 에서의 비교 (foot 포함).
  #371 에서 이어서 다뤄요.
