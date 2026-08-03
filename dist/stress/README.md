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
```

| 옵션 | 값 | 기본값 |
|---|---|---|
| `--layer` | `parser` · `pty` · `frame` | `parser` |
| `--workload` | `plain` · `ansi` · `cjk` | `plain` |
| `--mb` | 쏟아부을 MiB | `64` |
| `--cols` / `--rows` | 그리드 | `120` × `40` |
| `--scrollback` | scrollback 줄 수 | config 기본값 (100,000) |
| `--fps` | `frame` 층이 모사할 프레임 주기 | `60` |

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

- **PTY 층의 수신 바이트는 보낸 것보다 많아요.** `\n` 이 `\r\n` 으로 나오기 때문이고
  (termios `ONLCR`), 리포트의 `expected … minimum` 이 그걸 계산한 값이에요. 실측에서는
  그보다도 조금 더 받아요 — 줄 수에 정비례하고 (80 byte 줄 13,107 개에 +14), 터미널
  폭 · 줄 길이 · write 조각 크기와 무관하며, 데이터 없이 `\n` 만 보내면 안 생겨요.
  tty 드라이버의 출력 처리에서 오는 것으로 보이지만 **정확한 규칙은 확정하지
  않았어요** (64 MiB 에서 819 byte = 0.0013 %). 그래서 판정은 한 방향으로만 써요 —
  **모자라면 데이터 손실**이고 남는 건 정상이에요. 처리량은 실제 소화한 바이트로
  계산해서 이 오차에 영향받지 않아요.
- **`parser` 층의 숫자는 파서의 진짜 상한보다 낮을 수 있어요.** 같은 코어에서
  워크로드를 만들면서 파싱하므로 생성이 캐시를 밀어내요. 실측에서 `plain` 이
  `parser` 층 736 MiB/s 인데 `frame` 층의 `drain busy` 는 1,058 MiB/s 였어요 — 후자는
  바이트를 다른 프로세스가 만들어요. 그래서 `parser` 는 **하한에 가까운 값**으로
  읽는 게 안전해요.
- `parser` 층의 stream 은 응답 통로가 없는 읽기 전용이에요. 프로덕션은 Windows 만
  읽기 전용이고 macOS · Linux 는 질의 응답용 effects 가 붙어요 (#266). 이 하네스의
  워크로드에는 응답이 필요한 질의가 없어서 파싱 비용이 같을 것으로 보지만 **직접 재서
  확인하지는 않았어요.**
- **Windows 는 실기 확인 전이에요.** 코드상 `CreateProcessW` 로 자식을 띄우니 될
  것으로 보지만, ConPTY 조합에서 확인하지 않았어요. ConPTY 는 자식 출력에 자기
  시퀀스를 끼워 넣을 수 있어서 `expected` 계산도 하지 않아요 (`null`).
- 아직 없는 것: scrollback 누적, 다른 터미널과의 비교. #371 · #278 에서 이어서 다뤄요.
