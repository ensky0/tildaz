# stress / 처리량 하네스

대용량 출력을 소화하는 속도를 재고, 장시간·고부하에서 깨지지 않는지 확인하는
하네스예요. [#371](https://github.com/ensky0/tildaz/issues/371) (처리량 측정) 과
[#278](https://github.com/ensky0/tildaz/issues/278) (stress test harness) 이 함께
쓰는 도구예요.

**처리량 말고 응답성도 여기 있어요** — 폭포가 흐르는 동안 입력이 먹히는지 보는 검사는
아래 "[응답성 — 입력 손실 검사](#응답성--입력-손실-검사-441-축-)" 절이에요. 드레인을 건드리는
변경은 두 축이 거래 관계라 한쪽만 재면 판정이 반쪽이에요.

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

# 프레임에 묶인 드레인 — 프레임마다 예산이 걸린다 (앱의 하한, 아래 주의 참고)
zig build stress -Doptimize=ReleaseFast -Dsimd=true -- throughput --layer frame --mb 64

# 워크로드 바꾸기
zig build stress -Doptimize=ReleaseFast -Dsimd=true -- throughput --layer frame --workload cjk

# scrollback 이 쌓이는 동안 속도가 유지되는지 (#278 ①)
zig build stress -Doptimize=ReleaseFast -Dsimd=true -- scrollback --mb 256
```

## 세 가지 도구 — 무엇을 재느냐가 달라요

| 도구 | 재는 것 | 셸 |
|---|---|---|
| `zig build stress` (아래) | **층별 상한** — 파서 / PTY / 프레임 각각의 처리량 | 아무거나 |
| [`compare-terminals.sh`](compare-terminals.sh) | **다섯 터미널 나란히** 처리량 비교 + 창 캡처 | Windows 는 **Git Bash 필수** |
| [`measure-repeat.sh`](measure-repeat.sh) | **우리 앱 안의 배분** — `parse` · `render` · `shape` 몫 | 〃 |
| [`check-input-loss.sh`](check-input-loss.sh) | **응답성 ①** — 폭포 중 입력이 먹히는지 | Linux · macOS |
| [`measure-input-latency.sh`](measure-input-latency.sh) | **응답성 ②** — 키가 화면에 닿기까지 얼마나 걸리는지 | Linux |
| [`hygiene.sh`](hygiene.sh) | 위 넷이 **공유하는 측정 위생** — 검사 · 준비 · 복원 | 실행 파일이 아니라 `.` 로 읽어요 |

`measure-repeat` 는 앱을 반복해 띄워 종료 시 자동 덤프 ([#396](https://github.com/ensky0/tildaz/issues/396))
로 남는 perf 스냅숏을 모으고, **5 회 절사평균 + min~max** 로 표를 내요. 시작 전에 위생을
직접 검사해요 — AC 인지, 주사율이 그 화면의 최대와 같은지 (Windows 의 DRR ·
Linux 는 `kscreen-doctor`). 절전 · 잠금은 `SetThreadExecutionState` / `systemd-inhibit` /
`caffeinate` 로 막아요.

**세 platform 이 이 한 벌이에요.** 예전에는 Windows 용 `measure-repeat.ps1` 이 따로 있었지만
[#381](https://github.com/ensky0/tildaz/issues/381) 에서 없앴어요 — **두 벌이 실제로 갈렸거든요.**
`parse 비중` 계산식이 표마다 달랐고 ([#395](https://github.com/ensky0/tildaz/issues/395)) 워크로드
목록 · 로그 파싱 정규식이 양쪽에 중복이었어요. `compare-terminals.sh` 가 이미 Git Bash 를
요구하고 그건 Git for Windows 에 항상 들어 있어서, 한 벌로 합치는 값이 더 컸어요.

```sh
zig build -Doptimize=ReleaseFast -Dsimd=true
zig build stress -Doptimize=ReleaseFast -Dsimd=true -- throughput --layer parser --mb 1
dist/stress/measure-repeat.sh --phase before
dist/stress/measure-repeat.sh --phase after --workloads zwj,plain
```

**`zig build stress` 를 한 번 더 불러야** 해요 — 기본 `zig build` 는 `tildaz-stress` 를
`zig-out/bin` 에 install 하지 않아서, 예전에 빌드해 둔 producer 가 남아 있으면 그게 그대로 쓰여요.
구버전 producer 는 새로 생긴 워크로드 이름을 몰라 **producer 모드로 진입하지 않고**, 창은 뜨는데
폭포가 없는 껍데기 회차가 돼요 (실측: `emoji_vs16` · `zwj` 가 743 byte 만 읽혔어요). 뒤집어 말하면
**producer 를 일부러 고정할 수도** 있어요 — before / after 를 비교할 때 앱만 바꾸고 producer 를
그대로 두면 양쪽이 완전히 같은 바이트를 받아요 (#397 의 Linux 검증이 그렇게 했어요).

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
| `--workload` | 아래 "워크로드" 절의 열한 개 | `plain` |
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
| `frame` | 위와 같지만 **프레임마다 드레인 예산**을 지킨다 | 렌더 · 프레임 사이 드레인 |

`pty − parser` 가 PTY read 와 ring 층의 몫이에요. `perf` 를 쓸 수 없는 환경에서도
시간이 어디서 가는지 가를 수 있어요.

`frame` 층은 `drainOutputForRender` 를 `--fps` 주기로 **한 번씩** 부르고, 그 안의 `drainFrame`
이 `SessionCore.DRAIN_FRAME_BUDGET_NS` (현재 **4 ms**) 만 파싱해요.

⚠️ **이 층은 더 이상 앱과 같지 않아요.** 사양 A ([#387](https://github.com/ensky0/tildaz/issues/387),
SPEC §13) 이후 세 host 는 **프레임 사이에도** 드레인해서 실제 앱의 duty 가 훨씬 높아요 — Windows ②
60 Hz 실측으로 이 층에 해당하는 구조가 duty 50.6~51.4 % 인데 실제 앱은 **91.5~92.2 %** 였어요.
그러니 이 층 숫자는 **"프레임에 묶였을 때의 하한"** 으로 읽고, 앱의 실제 배분은 perf 덤프
(`Ctrl+Shift+F12` / `Shift+Cmd+F12`) 로 봐요. 아래 "실제 앱" 열도 사양 A 이전 값이에요.
(이 갭은 후속 이슈로 다뤄요.)

⚠️ **`--fps` 를 재는 화면의 재생률로 반드시 지정해요.** 기본값 60 을 고주사율 화면에서
그대로 쓰면 숫자가 크게 어긋나요. 예산이 프레임 간격에서 차지하는 비율 (`예산 / 프레임간격`) 이
완전히 달라지기 때문이에요.

| 화면 | 프레임 간격 | 4 ms 예산의 비율 | (예산 8 ms 였을 때) |
|---|---|---|---|
| 60 Hz | 16.67 ms | 24 % | 48 % |
| **120 Hz** (ProMotion 등) | **8.33 ms** | **48 %** | 96 % |

실측 사례예요 (**예산 8 ms 시점**). 120 Hz 화면을 60 으로 모사했을 때와 제대로 120 을 준 경우:

| 워크로드 | 60 으로 모사 | 120 (실제) | 같은 조건의 실제 앱 |
|---|---:|---:|---:|
| plain | 144 · 초과 0/33 | 141.7 · 초과 0/64 | 130.8 |
| ansi | 103 · 초과 38/44 (86 %) | 137.7 · 초과 25/64 (39 %) | 135.8 |
| cjk | 63 · 초과 62/68 (91 %) | 128.7 · 초과 61/70 (87 %) | 101.0 |

**120 으로 주면 실제 앱 값과 잘 맞았어요** (ansi 는 137.7 vs 136 으로 거의 일치) — 단 이건
**사양 A 이전** 이라 그때는 앱도 프레임당 1 회였기 때문이에요. `--fps` 를 안 주면 리포트가 경고해요.

macOS 에서 재생률을 확인하는 법: `CGDisplayModeGetRefreshRate` 를 부르거나, 시스템 설정의
디스플레이 항목을 봐요 (`system_profiler SPDisplaysDataType` 에는 안 나와요).

리포트의 `over budget` 이 예산을 넘긴 프레임 수예요. 실제 앱에서는 그 프레임마다
vsync 를 놓쳐요 — 즉 이 숫자가 사용자가 보는 "멈칫" 의 빈도예요.

### 워크로드

열한 워크로드는 모두 **결정적이에요** — 같은 옵션이면 어느 platform 에서든 같은
바이트가 나와요. 난수 · 시각 · locale · 셸을 쓰지 않아요. 입력이 다르면 숫자를
나란히 둘 수 없기 때문이에요.

| 이름 | 내용 | 태우는 경로 |
|---|---|---|
| `plain` | 80 byte ASCII 줄 | 파서에 가장 싼 길 |
| `ansi` | SGR 색이 섞인 빌드 로그 모양 | escape sequence 파싱 |
| `cjk` | 한글 · emoji · 스킨톤 · ZWJ 묶음 · block element | wide cell · grapheme cluster |

**귀속용 네 개** ([#381](https://github.com/ensky0/tildaz/issues/381)) — `cjk` 가 섞어 쓰는 경로를
하나씩만 태워요. 넷 다 한 줄의 구조가 같아요 (앞머리 10 열 + 항목 13 개).

| 이름 | 내용 | 태우는 경로 |
|---|---|---|
| `hangul` | 한글만 | **wide cell 만** — BMP codepoint 하나가 셀 하나라 grapheme extras 를 안 지나요 |
| `emoji_vs16` | `❤️` (U+2764 U+FE0F) 만 | **VS-16 경로** — codepoint 2 개가 한 grapheme, 셀이 wide 로 |
| `skintone` | `👋🏻` (U+1F44B U+1F3FB) 만 | **스킨톤 modifier** — codepoint 2 개인데 base 가 non-BMP |
| `zwj` | `👨‍👩‍👧` 만 | **ZWJ 묶음** — codepoint 5 개가 한 grapheme. extras 가 가장 깊어요 |

**종류 다양성 네 개** — 위 넷과 **짝**이에요. 같은 경로 · **같은 줄 byte** 인 채 항목 종류만
늘려요. 위 넷은 항목이 한두 종류라 어떤 캐시에든 hit 율이 사실상 100 % 인 *최상 조건*이고,
아래 넷이 반대쪽 극단이에요. **짝 사이의 차이가 곧 "조회 반복" 이 병목에서 차지하는 몫**이라,
그 값이 shaping 호출 자체를 줄일지 (run 배칭) 결과를 캐시할지 (cluster 캐시) 를 갈라요.

| 이름 | 항목 | 구별되는 종류 | 짝과 달라지는 것 |
|---|---|---:|---|
| `hangul_varied` | 완성형 `가`~`힣` 순회 | **11,172** | glyph atlas / rasterize |
| `emoji_vs16_varied` | text presentation 기본 BMP 기호 + VS-16 | **20** | shaping 조회 반복 |
| `skintone_varied` | base 25 × 스킨톤 5 | **125** | 〃 |
| `zwj_varied` | 3 인 가족 ZWJ 묶음 전부 | **12** | 〃 |

한 화면 (40 행 × 13 항목) 에 동시에 올라오는 종류는 최대 **520** 개예요 — 줄마다 항목 색인이
13 씩 전진해서요. `zig test src/stress/workload.zig` 의 "varied 워크로드는 한 화면에 여러 종류를
올린다" 가 이 종류 수를 못 박아 둬요.

⚠️ **귀속 · varied 워크로드는 MiB/s 를 그대로 비교하면 안 돼요.** 줄 byte 가 경로마다 달라요.
**줄/초 = `MiB/s × 1048576 ÷ 줄 byte`** 로 환산해서 비교해요 — 줄 byte 는 같은 파일의 "귀속
워크로드는 줄 byte 가 고정" 이 못 박아 둬요.

| 짝 | 줄 byte |
|---|---:|
| `hangul` · `hangul_varied` | 50 |
| `emoji_vs16` · `emoji_vs16_varied` | 89 |
| `skintone` · `skintone_varied` | 105 |
| `zwj` · `zwj_varied` | 245 |

#### 항목 13 개는 **최악의 표시 폭**에서 나온 수예요

우리는 `👨‍👩‍👧` 를 한 grapheme 으로 접어 2 열에 그리지만, **안 접는 터미널은 구성원 emoji 세 개를
따로 그려요.** 그때 한 항목이 몇 열이냐가 이 수를 정해요.

| 세는 방식 | 항목당 열 | 어디서 |
|---|---:|---|
| 한 grapheme 으로 접어요 | 2 | TildaZ · Windows Terminal |
| 구성원만 세고 ZWJ 는 0 열 (`Cf` · default-ignorable 이니까) | 6 | — |
| **구성원 + ZWJ 도 1 열씩** | **8** | **alacritty · wezterm (Windows 실측)** |

**처음엔 가운데 줄(6 열)을 최악으로 보고 `110 ÷ 6 = 18` 을 썼는데 그게 틀렸어요.**
Windows 실기에서 alacritty · wezterm 이 **ZWJ 를 1 열로 세는 것**이 확인됐어요
([#381](https://github.com/ensky0/tildaz/issues/381)). 그러면 한 항목이
`👨(2) + ZWJ(1) + 👩(2) + ZWJ(1) + 👧(2) = 8` 열이라 한 줄이 `10 + 18 × 8 = 154` 열이 되어 120 열
격자를 넘어요.

넘는 지점이 하필 한 grapheme 한가운데라 **그 항목 하나가 앞뒤로 쪼개져 합성이 깨진 채** 그려졌어요.
실제 출력이 계산과 정확히 맞았어요 — `10 + 13 × 8 = 114` 까지 온전하고, 남은 6 열에 `👨‍👩‍` (2+1+2+1)
가 들어간 뒤 `👧` 가 다음 행으로 넘어갔어요.

```
000004694 👨‍👩‍👧 × 13 … 👨‍👩‍   ← 120 열에서 끊김
          ‍👧👨‍👩‍👧 × 4        ← 다음 행
```

**줄이 접히면 대상마다 줄 수가 달라져 비교가 성립하지 않아요** — 열 수가 줄바꿈 횟수를 바꾸기
때문이고, 아래 "측정 중 resize" 검사에는 안 걸리는 종류예요. 처음의 35 개 (= `cjk` 와 같은 80 열) 도
같은 이유로 버렸어요 — 그건 **접는 터미널에서만** 80 열이었어요.

그래서 최악을 8 열로 잡고 다시 풀어요: `앞머리 10 + 8 × N ≤ 120` → **N = 13**.
접는 터미널에서 `10 + 13 × 2 = 36` 열로 격자보다 짧은 건 의도예요.

⚠️ **ZWJ 를 2 열로 세는 터미널이 나오면 또 내려야 해요** (항목당 10 열 → N = 11). 판정은
`--capture` 로 찍어 **번호 줄 사이에 조각 줄이 끼는지** 보면 돼요.

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

### 반복과 대표값 — 1 회 측정은 기록하지 않아요

같은 조건을 여러 번 재면 값이 흔들려요. macOS 실측에서 TildaZ 가 **115.0 / 124.2 /
128.7 MiB/s** (12 % 폭), kitty 는 한 번에 **65.7~89.5 MiB/s** (36 % 폭) 였어요. 그 폭보다
작은 차이는 1 회 측정으로 구분할 수 없어요.

그래서 **기록으로 남길 수치는 5 회 반복**하고, 대표값은 **min · max 를 뺀 나머지의 평균
(절사평균)** 으로 내요. 비교 스크립트의 `--repeat` 가 그것을 해 줘요.

```sh
dist/stress/compare-terminals.sh --mb 64 --workload plain --repeat 5
```

| 규칙 | 왜 |
|---|---|
| 5 회 반복 | 3 회는 절사하면 1 개만 남아요. 5 회면 3 개 평균이 되어 재현성이 생겨요 |
| 대표값 = 절사평균 | 중간값은 5 회에서 **사실상 1 개 샘플**이라 그 값이 흔들려요. 단순 평균은 이상치 하나에 끌려가요. 양 극단 (운 좋은 실행 / 스로틀링 걸린 실행) 만 버리고 나머지를 다 쓰는 게 절사평균이에요 |
| `min~max` 를 함께 적기 | 대표값만 적으면 버린 두 값이 사라져요. 흔들림 폭이 보여야 "이 차이가 유의미한가" 를 읽는 사람이 판단할 수 있어요 |
| **회차별 값도 적기** (`--repeat` 2 이상) | `min~max` 는 폭이 *얼마인지*만 알려주고 **어떤 모양인지**는 안 알려줘요. 무작위 산포 · 두 무리로 갈림 (쌍안정) · 회차가 갈수록 느려짐 (열 · 전력 한계) 이 전부 같은 `min~max` 로 나와요. **정렬하지 않고 실행 순서 그대로** 적어요 — 단조 감소는 순서가 있어야 보여요 ([#449](https://github.com/ensky0/tildaz/issues/449)) |
| 표본이 3 개 미만이면 | 절사하지 않고 단순 평균으로 떨어져요. 스크립트가 **그 사실을 표 위에 적어요** — 조용히 다른 통계로 바꾸지 않아요 |

회차별 값은 이렇게 나와요. 폭이 큰 회차가 **어디에 몰렸는지**가 한눈에 보여요.

```
tildaz                843.4       75.9         71.0~91.1     120x40
                 회차별: 74.2  91.1  71.0  75.9  76.5 MiB/s
```

[#449](https://github.com/ensky0/tildaz/issues/449) 의 진단이 이 값이 없어서 **두 번 막혔어요** —
표본이 임시 디렉터리에만 있고 실행이 끝나면 지워져서, 세 모양을 구분할 데이터가 아예 안 남았어요.

### 측정 위생

앞의 셋은 실제로 겪어서 값을 버린 원인이에요.

| 규칙 | 왜 |
|---|---|
| 측정 중 창을 클릭하거나 포커스를 바꾸지 않아요 | 실측 중 키보드 · 마우스가 눌려 그 회차를 버렸어요 |
| 이전 실행의 잔여 터미널 프로세스를 먼저 정리해요 | `kitty --detach` 와 ghostty 는 스크립트가 끝나도 남아서 다음 회차와 CPU 를 나눠요 |
| **평소 쓰는 TildaZ worker 를 종료해요** — **이제 스크립트가 자동으로 해요** | 다른 터미널은 백그라운드 인스턴스가 없는데 TildaZ 만 worker 가 떠 있으면 렌더 · CPU 를 나눠 써요. 터미널 비교에서는 **공정성**이 깨지고 배분 측정에서는 **값이 눌려요** — 형태가 다를 뿐 결론이 같아서 `hygiene.sh` 가 두 도구 모두에서 내려요. 규칙으로만 적어 뒀더니 실제로 잊고 여러 회차를 돌린 적이 있어요 ([#381](https://github.com/ensky0/tildaz/issues/381)). **끝나도 다시 안 띄워요** — 필요하면 직접 띄우세요 |
| **비교 대상 터미널을 종료해요** — **스크립트가 검사해서 걸리면 멈춰요** | 떠 있으면 그 앱이 사용자 창을 그리며 CPU 를 나눠 써요. **숨기는 것으로는 부족해요** — 터미널은 빌드 · 로그를 띄워 둔 채 두는 앱이라, 숨겨도 그 안의 프로그램은 계속 돌아요. 게다가 **Terminal.app · iTerm2 는 hide 로 아예 못 막아요**: 둘 다 *이미 떠 있는 앱 프로세스에 창을 붙이는* 방식이라 우리 측정 창이 사용자 창과 **같은 프로세스** 안에서 그려지고, 창을 만드는 순간 그 앱의 hide 가 풀려요. 같은 함정을 wezterm 이 먼저 만나 `--always-new-process` 로 피했는데 그 둘에는 그런 통로가 없어요 ([#414](https://github.com/ensky0/tildaz/issues/414)). **자동으로 닫지는 않아요** — 사용자의 작업 창이라서요. 그래서 **이 스크립트는 대상이 아닌 터미널에서 돌려요** (VS Code 터미널 · SSH 등) |
| AC 전원에 연결하고 절전 · **화면 잠금을 꺼요** — **잠금 차단은 스크립트가 해요** | 노트북은 배터리 · 열로 스로틀링이 걸려요. 그리고 잠금 화면이 뜨면 **`render` 만 무너지고 `parse` 는 정상이라 결과만 봐서는 티가 안 나요** — 아래 참고. AC 연결 자체는 사람이 해야 하고, 스크립트는 **검사해서 걸리면 멈춰요** |
| **CPU 를 최고 성능으로 둬요** — **이제 스크립트가 해요** | AC 만 확인하고 전원 프로파일은 안 봤더니 `balanced` (EPP `balance_performance`) 인 채로 여러 세션을 쟀어요. Linux 는 `powerprofilesctl set performance` 로 **sudo 없이** 되고, Windows 는 **전원 모드(overlay)** 를 최고 성능으로 둬요 — 둘 다 끝나면 되돌려요. **Windows 는 전원 *구성표* 가 아니에요** — 아래 참고 |
| **Windows 노트북은 동적 새로 고침 빈도(DRR)를 꺼요** | 켜져 있으면 주사율이 측정 중에 바뀌어 **회차가 두 무리로 갈려요** — 아래 참고. `hygiene.sh` 가 시작 전에 이걸 직접 검사하고 걸리면 멈춰요 |
| **화면을 계속 다시 그리는 앱 (브라우저 · 에디터 · 채팅) 을 최소화해요** — **KDE · Windows 에서는 스크립트가 해요** | **우리 수치만 64 % 흔들려요** — 아래 참고. KDE 는 KWin 스크립팅으로 창을 **하나씩 최소화**하고 Windows 는 `Shell.Application.MinimizeAll` 이에요 (**되돌리지 않아요** — 필요하면 직접 올려요). macOS 와 그 밖의 데스크톱에서는 경고만 해요. Show Desktop 은 **측정 창이 뜨는 순간 해제돼서** 못 써요 (실측) |
| 수치는 **실기기**에서 내요 | VM 은 CPU · 메모리 대역폭 · 렌더 경로가 host 와 달라요. VM 은 동작 확인 용도예요 |

#### 잠금 화면이 뜨면 `render` 만 무너져요 — 결과 표에는 안 보여요

측정 중 화면 잠김이 잠깐 떠서 실제로 한 회차를 버렸어요
([#396](https://github.com/ensky0/tildaz/issues/396)). 노트북 AMD Ryzen AI 7 350 · KDE Plasma
(Wayland) · `emoji_vs16` 8 MiB × 5.

| 회차 | parse ms | render ms | render calls |
|---|---:|---:|---:|
| 1~4 (정상) | 402 ~ 423 | 45.8 ~ 53.5 | 50 ~ 52 |
| **5 (잠김)** | **387.175** | **9.433** | **4** |

**`parse` 가 정상 범위라는 게 함정이에요.** 데이터는 다 소화했거든요. 무너진 건 `render` 뿐이에요 —
잠금 화면이 뜨면 compositor 가 우리 surface 에 frame callback 을 보내지 않아서 `redraw` 가 그리지
않고 빠져나가요. 그래서 **처리량만 보는 표에서는 오염이 전혀 안 드러나요.**

##### 회차 유효성은 이 셋으로 판정해요

perf 스냅숏에 답이 있어요 (측정 인스턴스는 종료할 때 자동으로 남겨요 — `Ctrl+Shift+F12` 를 누를
필요 없어요). 앞의 둘은 **그렸는지**를, 셋째는 **다 소화했는지**를 봐요.

| 지표 | 정상 (4 회차) | **오염 (5 회차)** |
|---|---|---|
| `skip / onrender` | 26/75 = 35 % | **71/73 = 97 %** |
| `present calls` | 49 | **2** |

`onrender` 의 `skip` 은 paint 하지 못한 frame tick 수예요. 이게 대부분이면 **그리지 않은 회차**라
`render` 값에 의미가 없어요. 회차 사이에 `render calls` 가 한 자릿수로 떨어지는 것도 같은 신호예요.

###### 셋째 — `readloop bytes − drain bytes` 가 수십 byte 이내여야 해요

**`readloop bytes >= 요청 바이트` 로는 부분 파싱을 못 잡아요.** `readloop` 은 PTY 에서 *읽은* 양이라
파싱과 무관하게 채워지거든요. #396 이 처음 정한 그 기준으로는 **실제로는 54 % 만 파싱한 회차도
통과**했어요 ([#397](https://github.com/ensky0/tildaz/issues/397)). 봐야 할 것은 읽은 양과 **소화한**
양의 차이예요.

세 platform 실측이에요 (`HOLD` 없이, 고침은 [a131250](https://github.com/ensky0/tildaz/commit/a131250)).

| platform · 머신 | 고침 전 손실 | 고침 후 |
|---|---|---|
| macOS · M5 Pro (8 MiB) | `zwj` **45.5 %** | **0** |
| Linux · Intel i5-1240P (64 MiB) | `zwj` **6.1~6.2 %** (5/5) · `plain` **0.9~2.5 %** (5/5) | **0** (10/10) |
| Windows · AMD Ryzen AI 7 350 (64 MiB) | `zwj` **6.3~6.5 %** (5/5) · `plain` 2/5 에서 265 KB~1.25 MB | **16 byte** |

그래서 판정은 `== 0` 이 아니라 **수십 byte 이내**예요. 실제 결함은 **수백 KB~수 MB** 규모라 이
경계로 충분히 갈려요.

**Windows 의 16 byte 는 ConPTY teardown 이에요 — 결함이 아니에요**
([#398](https://github.com/ensky0/tildaz/issues/398) 에서 확정). 자식이 끝날 때 ConPTY 가
`ESC[?1004l` + `ESC[?9001l` (8+8 = **16 byte**) 를 보내요. 시작할 때 보내는 협상 preamble
`…1004h` · `…9001h` 의 짝이고 ([#385](https://github.com/ensky0/tildaz/issues/385)), **창이 닫히는
참의 모드 해제라 파싱할 것이 없어요.** ConPTY 가 없는 Linux · macOS 가 0 인 것도 이걸로 설명돼요.

그래서 **`push bytes` 를 함께 봐요.**

| 지표 | 뜻 | 정상값 |
|---|---|---|
| `readloop bytes` | PTY 에서 **읽은** 양 | teardown 16 을 포함해요 (Windows) |
| `push bytes` | ring 에 **넣은** 양 | — |
| `drain bytes` | **소화한** 양 | — |
| **`push − drain`** | 진짜 손실 | **0 이어야 해요** |
| `readloop − drain` | 위 + teardown | Windows 는 **16**, 나머지는 0 |

`push` 가 예전에는 `data.len` 을 세어서 (실제로 넣은 양이 아니라) 이 구분이 안 됐어요 — 그때는
`push bytes == readloop bytes` 라 teardown 이 손실처럼 보였어요.

⚠️ **`TILDAZ_STRESS_HOLD_MS` 를 주면 이 검사가 통째로 무의미해져요.** 유휴 시간이 드레인할 기회를
줘서 **고치기 전 코드도 손실이 없어 보여요** (Windows 는 `HOLD=3000` 에서 고침 전에도 16 byte 였고,
macOS 는 `HOLD=5000` 에서 100 % 였어요). 배분 측정은 `HOLD` 없이 해요 — `measure-repeat` 의 기본값이
0 인 이유예요.

#### Windows 의 CPU 레버는 전원 *구성표* 가 아니라 전원 *모드* 예요

`hygiene.sh` 는 처음에 **고성능 전원 관리 옵션** (`powercfg /setactive 8c5e7fda-…`) 을 켜려 했는데,
Windows 실기 검증에서 **두 겹으로 틀린 것**이 드러났어요 ([#381](https://github.com/ensky0/tildaz/issues/381),
Intel i5-1240P · Windows 11 26200).

**① Git Bash 에서 `powercfg /…` 는 인자가 통째로 안 먹어요.** MSYS 가 `/getactivescheme` 을 경로로
바꿔요. 같은 파일이 `taskkill //IM` 에서는 이 회피를 이미 쓰고 있었는데 `powercfg` 에만 안
들어갔어요 — 그래서 코드가 **항상** 실패 경로로 갔어요.

```sh
$ powercfg /getactivescheme
매개 변수가 잘못되었습니다. 도움말을 보려면 "/?"를 입력하십시오.
$ powercfg //getactivescheme      # 슬래시를 겹치거나 `-getactivescheme`
전원 구성표 GUID: 381b4222-…  (균형 조정)
```

**② 슬래시를 고쳐도 안 돼요 — Windows 11 에 그 구성표가 없어요.** `powercfg /list` 에 "균형 조정"
하나뿐이고 고성능 GUID `8c5e7fda-…` 는 목록에 없어요. 그러니 예전 경고 문구의 *"설정에서 직접
골라요"* 는 **존재하지 않는 항목**을 가리키고 있었어요.

**실제 레버는 전원 모드(overlay) 예요.** `powercfg` 에는 명령이 없고 (`/overlaylist` 는 `매개 변수가
잘못되었습니다`, `powercfg /?` 에도 항목이 없어요) `powrprof.dll` 의
`PowerGetEffectiveOverlayScheme` / `PowerSetActiveOverlayScheme` 로 읽고 써요. Linux 의
`powerprofilesctl get` / `set` 과 같은 자리예요.

| GUID | 전원 모드 |
|---|---|
| `00000000-0000-0000-0000-000000000000` | 균형 (기본) |
| **`ded574b5-45a0-4f42-8737-46345c09c238`** | **최고 성능** ← 측정용 |
| `961cc777-2547-4f9d-8174-7d86181b8a7a` | 최고의 전원 효율 |

읽어 보니 **이 머신은 이미 최고 성능**이었어요 — Linux 쪽에서 EPP 가 `balance_performance` 였던
것과는 사정이 달라요. 그래도 검사·설정·복원은 그대로 걸어요. *"이미 맞을 것"* 이라고 넘기면
다른 머신에서 조용히 눌린 값을 얻게 되니까요.

#### Windows 의 동적 새로 고침 빈도(DRR)는 회차를 **두 무리로 갈라요**

Windows 11 의 *동적 새로 고침 빈도* 는 화면 내용에 따라 주사율을 오르내려요. 그런데 앱은
주사율을 **시작할 때 한 번만** 읽어서 (`[startup] frame clock started: refresh=..Hz`) 중간 변동을
몰라요. 그래서 값이 한 중심 주위로 흩어지는 게 아니라 **두 무리로 갈려요**.

같은 조건 (`zwj` · 64 MiB · 5 회 · 노트북 AMD Ryzen AI 7 350 · Windows) 을 DRR 만 바꿔 쟀어요
([#394](https://github.com/ensky0/tildaz/issues/394)).

| 지표 | **DRR 켜짐 + 배터리** | DRR 끔 + AC · 120 Hz |
|---|---|---|
| `render calls` | 311~321 **과** 552~561 (두 무리) | 410~441 (한 무리, 폭 7 %) |
| `readloop ms` 폭 | 293~326 (11 %) · `plain` 은 398~721 (**81 %**) | 196~206 (5 %) · `plain` 267~285 (6 %) |
| `drain ms` | 3494~3684 | 2209~2287 (**35 % 빨라요**) |

**두 오염원이 겹쳐 있었어요.** DRR 이 프레임 수를 갈랐고, 배터리 스로틀링이 절대값을 눌렀어요.

##### 판정법

- 로그의 `refresh=..Hz` 가 그 화면의 실제 최대 주사율과 **다르면** DRR 을 의심해요. DRR 이
  켜져 있으면 기본값 (대개 60) 으로 보고돼요.
- 회차의 `render calls` 가 **한 중심 주위로 흩어지지 않고 두 무리로 갈리면** 거의 이것이에요.
  배수가 주사율 비 (60 ↔ 120 이면 약 2 배) 에 가까운지 보면 확실해요.
- 확인: `Get-CimInstance Win32_VideoController` 의 `CurrentRefreshRate` 가 `MaxRefreshRate` 와
  같은지 봐요. **전원도 함께 봐요** — `Get-CimInstance Win32_Battery` 의 `BatteryStatus` 가
  `2` 여야 AC 예요 (`1` = 배터리, 이때 패널이 60 Hz 로 강등되기도 해요).
- 끄는 곳: **설정 → 시스템 → 디스플레이 → 고급 디스플레이 → 새로 고침 빈도** 에서 "동적" 이
  아닌 고정 값을 골라요.

#### 배경 앱이 그리고 있으면 **우리 수치만** 눌려요

같은 조건 (`emoji_vs16` · 8 MiB · `--repeat 5` · Intel i5-1240P) 을 배경 상태만 바꿔 세 번 쟀어요
([#381](https://github.com/ensky0/tildaz/issues/381)).

| 대상 | A · 그대로 (VS Code · Edge 가 보이는 상태) | B · 전체화면 topmost 창으로 덮음 | C · 배경 앱만 최소화 | **C vs A** |
|---|--:|--:|--:|--:|
| **tildaz** | 17.1 | 25.9 | **28.1** | **+64 %** |
| wt | 108.5 | 105.8 | 109.3 | +0.7 % |
| conhost | 24.3 | 24.1 | 26.4 | +9 % |
| wezterm | 13.3 | 12.7 | 13.9 | +5 % |
| alacritty | 10.5 | 9.7 | 11.3 | +8 % |

**원인은 가려짐이 아니라 배경 앱의 렌더링이에요.** B 는 대상 창이 가려져서 빨라진 게 아니에요 —
z-order 를 찍어 보니 tildaz 는 덮개보다 **위**에 있었어요 (`TildaZWindow … [TOPMOST]` 가 1 위).
덮개가 실제로 가린 것은 VS Code · Edge 였고, 그 둘이 그리기를 멈추자 우리 수치가 올랐어요.
덮개 없이 그 둘만 최소화한 C 가 B 보다도 높은 것이 그 확인이에요.

**cluster 워크로드에서 우리가 유독 민감해요** (+64 % 대 wt +0.7 %). 렌더 경로가 자원 경쟁에 약하다는
뜻이고, 이것 자체가 [#389](https://github.com/ensky0/tildaz/issues/389) 의 단서예요. 측정 쪽에서는
**배경 앱을 정리하지 않으면 우리 값만 눌려 비교가 우리에게 불리해진다**는 게 요점이에요.

⚠️ 이 함정은 **`--capture` 로도 안 걸러져요.** 캡처는 대상 창이 제대로 떴는지만 보여 주지, 배경에서
누가 그리고 있는지는 안 보여 줘요.

#### 기록용은 **64 MiB** 로 내요 — 작은 페이로드는 표를 뒤집어요

**이 표의 시간은 producer 가 *쓰기를 끝낸* 시점 기준이에요.** 터미널은 그 뒤로도 소화해요. 아직
소화 못 한 잔여는 그 터미널의 읽기 버퍼 크기라 **거의 고정**이라서, 페이로드가 작을수록 상대 오차가
커져요. 우리 앱 카운터로 확인한 잔여는 약 3 MB 였어요 (`emoji_vs16` 에서 producer 는 282 ms 인데
앱의 parse + render + present 는 549 ms).

같은 조건을 8 MiB 와 64 MiB 로 각각 떠 본 결과예요 ([#381](https://github.com/ensky0/tildaz/issues/381),
Intel i5-1240P · `--repeat 5` · 배경 정리).

| 워크로드 | 8 MiB 에서 우리/wt | **64 MiB 에서 우리/wt** |
|---|--:|--:|
| `plain` | 131 % | 108 % |
| `ansi` | 110 % | **92 %** |
| `hangul` | 118 % | **94 %** |
| `cjk` | 114 % | **56 %** |
| `emoji_vs16` | 25 % | **10 %** |
| `zwj` | 25 % | **10 %** |

**8 MiB 에서는 우리가 앞선 것처럼 보이던 워크로드가 64 MiB 에서 뒤집혀요.** 64 MiB 값은 다른 머신
(AMD 노트북) 결과와도 일치해요 — `cjk` 가 거기서 59 %, 여기서 56 % 예요. 8 MiB 쪽이 이상치였어요.

그래서 스크립트가 **`--repeat 5` 이상인데 `--mb` 가 64 미만이면 경고**해요. 64 MiB 는 원래 기본값이고,
`--mb 8` 은 smoke 확인용이에요. 느린 대상이 64 MiB 를 삼키는 데 15 초쯤 걸리니 `--timeout` 도 90 쯤
줘야 정상 회차가 안 잘려요.

**perf 덤프로 앱을 잴 때의 함정 둘** ([#387](https://github.com/ensky0/tildaz/issues/387) 에서 둘 다 실제로 겪었어요).
둘 다 **코드 회귀와 숫자가 똑같아 보여서** 오진하기 쉬워요.

| 함정 | 판정 방법 |
|---|---|
| **파싱 속도가 세션 단위로 20 % 흔들려요** | 같은 커밋 · 같은 워크로드인데 `drain.bytes / drain.ms` 가 아침 72.4 → 저녁 59.2 MiB/s 였어요 (원인 미확인, 열 · 전력 후보). **처리량 절대값은 같은 세션 안에서만 비교**하고, 교차 세션에는 duty · `drain/프레임` · 프레임 밖 몫처럼 **비율 지표**를 써요 |
| **producer 출력을 PowerShell `*>` 로 뜨면 부풀어요** | `*>` 는 스트림을 텍스트로 받아 `\n` 을 `\r\n` 으로 써요 — 64 KiB `cjk` 가 65,536 → **66,459 byte** 로 보여요. byte 정확 캡처는 `cmd /c "... > file"` 을 써요. [#385](https://github.com/ensky0/tildaz/issues/385) 에서 이걸로 "보낸 쪽에 이미 CR 이 있다" 고 한 번 잘못 읽었어요 |
| **`present` 가 프레임당 10 ms 대로 튀는 회차가 있어요** | 그러면 `onrender` 가 프레임 주기를 꽉 채워 (16.57 / 16.67 ms) 메시지 큐가 비는 순간이 없어지고, **프레임 사이 드레인이 한 번도 안 돌아요.** duty 가 정확히 프레임 상한(`예산/프레임간격`)에 붙어서 *"사양 A 가 작동하지 않는다"* 와 구분이 안 돼요. 정상은 프레임당 **0.17~0.18 ms** 라, duty 가 낮게 나오면 **`present` 를 먼저 보고** 10 ms 대면 그 회차를 버려요 (Windows 실측: 7 회 기동 중 1 회) |

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

### PTY 층의 수신 바이트는 보낸 것보다 많아요 — **거의 전부가 개행 변환이에요**

`\n` 이 `\r\n` 으로 나오는 것 (POSIX 는 termios `ONLCR`, Windows 는 ConPTY 콘솔) 이 초과분의
**대부분**이고, 리포트의 `expected … minimum` 이 그것까지 계산한 값이에요. 그 위에 얹히는
나머지는 platform 마다 달라요 (전부 실측이에요).

| platform | `expected` 위의 초과분 | 성질 |
|---|---|---|
| Linux | **`+0`** | `ONLCR` 변환 외에 아무것도 더하지 않아요. 예상값이 한 byte 도 안 어긋나요 |
| macOS | 64 MiB 에서 **+819 byte** (0.0013 %) | 줄 수에 정비례하고, 터미널 폭 · 줄 길이 · write 조각 크기와 무관하며, 데이터 없이 `\n` 만 보내면 안 생겨요. tty 드라이버 출력 처리에서 오는 것으로 보이지만 **정확한 규칙은 확정하지 않았어요** |
| **Windows** | **`+21~23 byte`** | ConPTY 협상 preamble 뿐이에요 — `ESC[1t` (4) + `ESC[c` `ESC[?1004h` `ESC[?9001h` (19). **본문에는 아무것도 끼워 넣지 않아요** ([#385](https://github.com/ensky0/tildaz/issues/385) 에서 raw 캡처로 확인) |

**Windows 실측 (#385)**: 64 KiB `cjk` 에서 producer 가 정확히 65,536 byte (`LF` 921 · `CR` 0) 를
쓰고 수신이 66,480 byte 예요 — `65,536 + 921 + 23` 으로 **딱 맞아요.** 64 MiB 세 워크로드의
`expected` 대비 초과는 `plain` `+23` · `ansi` `+23` · `cjk` `+21` 이고 (그 **2 byte 차이는 확인하지
않았어요** — `expected` 는 하한이라 판정에 무해해요), 요청 대비 초과는 `cjk` +1.41 % ·
`plain` +1.25 % · `ansi` +0.98 % 로 전부 개행 변환 몫이에요.

> ⚠️ **예전 문서의 "`cjk` 만 +25.6 %, ConPTY 가 wide char 에서 시퀀스를 끼워 넣는다" 는 틀렸어요.**
> 그 측정은 **producer 의 콘솔 출력 코드페이지가 UTF-8 이 아니던 때**의 것이에요 (한국어 Windows
> 는 CP949 → non-ASCII 가 재인코딩되며 부풀고 조각이 잘게 쪼개져 `readloop` 이 6,922 회까지
> 뛰었어요). [`944957a`](https://github.com/ensky0/tildaz/commit/944957a) 로 고친 뒤 재측정하니
> `cjk` +1.41 % · `readloop` 595 회예요. ASCII 는 코드페이지에 불변이라 그때도 `plain` · `ansi` 만
> 정상이던 것이 이 설명과 맞아요.

그래서 두 가지를 이렇게 다뤄요.

- **`expected` 판정은 한 방향으로만** 써요 — 모자라면 데이터 손실이고 남는 건 정상이에요.
  **세 platform 모두 `expected` 를 찍어요** (Windows 도 #385 이후 같은 공식이에요).
- **처리량을 두 줄로** 찍어요. 소화한 바이트 기준과 **보낸 바이트 기준**을 함께 내요.
  소화 기준만 보면 개행이 많은 워크로드가 유리하게 보여요. **platform 사이를 비교할 때는
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
- **`readloop` 시간은 세 platform 이 이제 같은 범위예요** — 유휴 대기를 뺀 **read 복사 시간**
  ([#394](https://github.com/ensky0/tildaz/issues/394)). Windows 도 `ERROR_IO_PENDING` 대기를
  계측 밖으로 뺐어요. 예전의 *"Windows 만 유휴 대기 포함"* ([#254](https://github.com/ensky0/tildaz/issues/254)) 은
  폐기예요 — 그 보류 근거였던 "overlapped I/O 재구성 필요" 가 이미 되어 있었어요.
  **그래도 그대로 빼서 비교하면 안 돼요.** Windows 의 pending 경로는 커널이 대기 중에
  복사를 끝내서 그 몫을 우리 스레드에서 잴 수 없어요 — `calls` · `bytes` 는 남고 `ns` 만
  빠지므로 **Windows 가 과소 계상**이에요. 남는 값은 *전체 복사 시간*이 아니라 **그중
  동기 완료로 걸린 몫**이라, 앱이 병목이냐에 따라 크기가 갈려요.

  | 64 MiB 워크로드 | 파이프 상태 | 걸리는 경로 | `readloop ms` (고치기 전 → 후) |
  |---|---|---|---:|
  | `zwj` | 앱이 병목이라 데이터가 쌓여요 | **동기 완료가 섞여요** | 199 → **6.07** |
  | `plain` | 앱이 빨라 파이프가 비어요 | **거의 pending** | 283 → **0.087** |

  (노트북 AMD Ryzen AI 7 350 · Windows · **AC · 120 Hz** · 64 MiB · 5 회 절사평균.)
  리포트가 어느 쪽인지 괄호로 적어 줘요.
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
## 응답성 — 입력 손실 검사 ([#441](https://github.com/ensky0/tildaz/issues/441) 축 ①)

여기까지가 *얼마나 빨리 소화하나* 였다면, 이 절은 **그 동안 사용자를 잃지 않나** 예요.

**드레인 구조를 건드리는 변경은 전부 처리량과 응답성의 거래예요** — 사양 A ([#387](https://github.com/ensky0/tildaz/issues/387)),
예산 8 → 4 ms (SPEC §13.3), Windows waitable swapchain ([#435](https://github.com/ensky0/tildaz/issues/435)),
Linux poll timeout ([#436](https://github.com/ensky0/tildaz/issues/436)), 유휴 깨우기
([#439](https://github.com/ensky0/tildaz/issues/439)). 처리량 쪽만 도구가 있으면 *"처리량은 숫자로,
응답성은 괜찮아 보인다로"* 남아요. #436 의 거래 (120 Hz cluster fps 121 → 93~104) 를 판단할 때
이 비대칭이 그대로 걸렸어요.

```sh
dist/stress/check-input-loss.sh                 # 기본 — 10 회 · plain · 2 GiB
dist/stress/check-input-loss.sh --presses 20
```

**Linux · macOS 전용이에요.** Windows 는 아래 "Windows 에서는 손으로" 를 보세요.

### ⚠ 분량은 처리량 측정의 64 MiB 를 쓰면 안 돼요

기록용 처리량은 64 MiB 로 내지만 (위 "기록용은 64 MiB"), **이 검사에서 그 값은 못 써요.** Linux 에서
plain 은 200 MB/s 급이라 **0.3 초면 끝나서** 누를 시간이 없어요. 그러면 폭포가 없는 상태에서 누른
것이 되고, ①은 당연히 다 먹고 ②는 버퍼에 쌓일 이유조차 없어요 — **판정이 성립하지 않는데 결과는
`10 / 10` 으로 보여요.** 첫 회차에서 실제로 그렇게 나왔어요 (#441). 기본을 2 GiB 로 두는 이유예요.

### ⚠ ②를 하려면 입력기(IME)가 영문이어야 해요

한글 모드면 타이핑이 한글로 조합돼 `touch` 가 명령이 되지 않아요. **①은 한글 모드에서도
정상이에요** — `Ctrl+Shift+F12` 는 IME 와 무관하게 앱에 도달해요 (#441 실측, fcitx5 · KDE
Plasma · 폭포 유무 · 한글/영문 네 조합 전부 확인).

그래서 `① 정상 + ② 실패` 조합이 **IME 의 표시**예요. 스크립트가 그때 알려 줘요.

> **한때 "한글 모드면 단축키가 앱까지 오지 않는다" 고 적었는데 그건 틀렸어요.** 한 회차가
> `① 0/10` 으로 나와 IME 를 원인으로 짚었지만, **재현되지 않았어요** — 한글 단독 (3/3) ·
> 영문+폭포 (10/10) · 한글+폭포 (10/10) 이 모두 정상이었고, 그 회차에 누른 키는 daily
> 인스턴스 로그에도 남지 않았어요. 원인은 확정하지 못했고 (창 포커스가 유력하지만 증거
> 없음), 그래서 서술을 실측에 맞게 되돌렸어요.

### 폭포 중이었는지를 함께 판정해요 — 개수만 세면 속아요

그래서 **`=== snapshot` 개수만 세지 않아요.** 각 스냅숏의 `drain bytes` 를 함께 봐요.

`dumpAndReset` 은 읽으면서 카운터를 리셋하니, 한 스냅숏의 bytes 는 *직전 스냅숏 이후* 의 몫이에요.
**0 이면 그 사이에 아무것도 안 흘렀다** = 폭포 밖에서 눌렀다는 뜻이에요. 통과 조건은 "눌린 횟수" 가
아니라 **"폭포 중에 눌린 횟수"** 예요.

```
==================== 결과 ====================
 폭포                      ✅ 2013 MiB 흘렀어요
 ① 앱 단축키 · 앱이 소비   ✅ 10 / 10   (전체 눌림 10)
 ② PTY 전달 · 타이핑       ✅ 성공 (파일 생성됨)
==============================================
```

producer 가 안 돌면 `폭포` 줄이 `❌ 231 byte 뿐` 으로 나와요. 그 회차는 나머지 판정이 무의미하니
버려요.

### producer 는 **환경변수 두 개로만** 켜져요

`stress.zig` 의 `producerRequest` 가 `TILDAZ_STRESS_WORKLOAD` 와 `TILDAZ_STRESS_BYTES` 를 **둘 다**
요구하고, 하나라도 빠지면 조용히 일반 모드로 둬요. 그리고 **인자를 주면 안 돼요** — 인자가 있으면
`throughput` 같은 *독립 측정* 모드라 자기 안에서 재고 끝나서, 앱 PTY 로는 폭포가 흐르지 않아요.
(첫 회차의 실수가 정확히 이것이었어요.)

### 두 경로를 따로 봐요 — 하나로 뭉치면 판정이 안 돼요

| # | 경로 | 어떻게 판정하나 | 왜 되나 |
|---|---|---|---|
| **①** | **앱 단축키** (앱이 소비) | 폭포 중 `Ctrl+Shift+F12` (macOS 는 `Shift+Cmd+F12`) 를 N 회 누르고 로그의 `=== snapshot` 블록 수를 센다 | 처리되면 블록이 **정확히 하나** 남아요. 화면을 볼 필요가 없고 개수가 곧 손실률이에요 |
| **②** | **PTY 전달** (타이핑) | 폭포 중 `touch /tmp/tz-ok` 를 타이핑하고, 폭포가 끝난 뒤 그 파일이 생겼는지 본다 | producer 가 **foreground** 라 셸이 stdin 을 읽지 않아 입력이 termios 버퍼에 남고, 폭포가 끝나는 순간 실행돼요 |

**둘 다 필요해요** — ①은 `Ctrl+Shift` 분기에서 앱이 소비하므로 **PTY write 경로를 지나지 않아요.**
②가 그 경로를 봐요. 그리고 ②의 배치는 **Ctrl+C 검사도 함께 성립**시켜요 (producer 가 foreground 라
SIGINT 를 받아요).

`=== snapshot` 만 세면 되는 이유는 **두 덤프가 라벨로 갈리기** 때문이에요. 단축키는
[`perf.zig`](../../src/perf.zig) 의 `dumpAndReset(rt, "snapshot")` 이고, 종료 시 자동 덤프
([#396](https://github.com/ensky0/tildaz/issues/396)) 는 `dumpOnExit` 이 **워크로드 이름**을 라벨로 써요.

### `-e` 에 러너 스크립트를 넘겨요 — 그냥 producer 를 넘기면 ②가 성립 안 해요

`measure-repeat.sh` 처럼 `-e <producer>` 로 띄우면 **폭포가 끝날 때 앱이 함께 종료돼서, 버퍼에 쌓인
입력을 실행할 셸이 없어요.** 그래서 스크립트가 이런 러너를 만들어 넘겨요.

```sh
#!/bin/sh
"$STRESS" throughput --layer pty --mb 64   # foreground 폭포 (stdin 을 안 읽어요)
exec "$SHELL"                              # 폭포 후 셸 — 같은 PTY slave 를 물려받아 버퍼를 읽어요
```

`-e` 가 인자를 못 받는 것도 같은 이유예요 (`run_options.zig` — POSIX PTY 의 argv 가 `{shell}` 로 고정).

### 로그는 `tildaz_stress.log` 로 가요

`-e` 로 띄운 회차는 stress run 으로 판정돼 (`instance_context.isStress`) 평소의 `tildaz_N.log` 가
아니라 **`tildaz_stress.log`** 에 남아요. 판정이 안 나올 때 이걸 먼저 확인해요 — 다른 작업에서도
`tildaz_1.log` 가 비어 있어 한참 헤맨 적이 있어요.

| platform | 경로 |
|---|---|
| Linux | `${XDG_STATE_HOME:-~/.local/state}/tildaz/tildaz_stress.log` |
| macOS | `~/Library/Logs/tildaz_stress.log` |
| Windows | `%APPDATA%\tildaz\tildaz_stress.log` |

### ❌ 이렇게는 판정이 안 돼요 — 다시 만들지 않으려고 적어 둬요

| 안 되는 방법 | 왜 |
|---|---|
| 폭포 중 에코를 **눈으로** 보기 | 초당 100 MiB 넘게 흐르면 1 초에 수만 줄이 지나가서, 에코된 글자가 나타난 순간 이미 스크롤 위로 밀려요. **"안 보인다" 와 "안 먹는다" 가 구분되지 않아요** |
| 백그라운드 job (`( … ) &`) 에 **Ctrl+C** | SIGINT 는 foreground process group (셸) 에만 가요. 앱과 무관하게 **원래 안 멈춰요** |

첫 시연이 이 둘을 겹쳐 놓아서 판정이 아예 불가능한 설계였어요 ([#436 코멘트](https://github.com/ensky0/tildaz/issues/436#issuecomment-5236928407)).

### 위생은 처리량만큼 안 따져요

`hygiene_check` 를 부르지 않아요. 판정이 *"먹었나 / 안 먹었나"* 라는 **이산값**이라 AC · 주사율 ·
배경 앱이 결과를 뒤집지 않아요 (나쁘면 폭포가 느려질 뿐이에요). 처리량 표를 낼 때의 규칙
(위 "측정 위생") 과는 요구가 다르다는 뜻이에요.

### Windows 에서는 손으로

`-e` 에 러너 스크립트를 넘길 수 없어요 — `CreateProcess` 가 `.cmd` 를 직접 실행하지 않아요.
절차는 같으니 손으로 해요.

1. `zig build stress` 로 `tildaz-stress.exe` 를 만들어요.
2. TildaZ 를 평소대로 띄우고 탭에서 producer 를 **foreground** 로 실행해요
   (`zig-out\bin\tildaz-stress.exe throughput --layer pty --mb 64`).
3. 폭포 중 `Ctrl+Shift+F12` 를 10 회 누르고, 결과가 파일로 남는 명령을 타이핑해요
   (PowerShell 이면 `ni $env:TEMP\tz-ok`).
4. `%APPDATA%\tildaz\tildaz_stress.log` 에서 `=== snapshot` 블록 수를 세고 파일 생성을 확인해요.

## 응답 **시간** 측정 ([#441](https://github.com/ensky0/tildaz/issues/441) 축 ②)

위 절이 *"먹었나"* 를 본다면 이쪽은 **"얼마나 늦게 반영되나"** 예요.

```sh
dist/stress/measure-input-latency.sh                      # idle · flood 둘 다
dist/stress/measure-input-latency.sh --mode idle --presses 50
```

**Linux 전용이에요.** 합성 입력이 platform 마다 달라요 — Windows 는 `SendInput`, macOS 는
`CGEvent` 로 [#387](https://github.com/ensky0/tildaz/issues/387) 이 이미 썼으니 그 경로를 옮겨오면
되지만 아직 안 했어요. **계측 자체는 세 platform 에 다 있어요** (`perf.input_latency`).

### 재는 구간

앱이 `perf.markInput()` (키 수신) 부터 `perf.completeInput()` (그 뒤 첫 present 완료) 까지를 재요.
그래서 **키 → PTY write → 셸 에코 → PTY read → parse → render → present** 가 전부 들어가요.
셸 왕복이 섞이지만 **그게 사용자가 실제로 기다리는 시간**이에요.

못 재는 것: `present → 실제 화면 발광` (외부 장비 필요) 과 `키 눌림 → 앱 수신` (compositor 몫).

### 첫 수치 (미니PC · Ryzen 7 8845HS · CachyOS · KDE Plasma · 60 Hz)

5 회 절사평균 + min~max.

| 상황 | 평균 | 최악 |
|---|---|---|
| **유휴** | **0.67 ms** (0.66~0.69) | **12.35 ms** (12.30~12.38) |
| **폭포 중** | **10.69 ms** (10.37~11.72) | **18.64 ms** (18.24~19.14) |

**폭포가 흐르면 평균 응답이 16 배 느려져요.** 재현성도 좋아요 — 유휴 최악은 5 회가 0.08 ms 폭
안에 들어왔어요.

**이 값으로 [#439](https://github.com/ensky0/tildaz/issues/439) 를 판정하면 안 돼요.** 그 이슈는
*"유휴에서 **PTY 출력이 도착**했을 때"* 이고 이 측정은 **키를 눌러** 시작해요 — 키가 오면 앱이 즉시
렌더를 요청하니 유휴 깨우기 경로를 아예 안 타요. 예산 4 ms 와의 직접 비교도 안 돼요 (그건 드레인
한 번의 상한이고, 이 값은 거기에 셸 왕복 · 렌더 · present 가 누적된 것이에요).

### ⚠ 입력기가 한글이면 표본이 안 잡혀요

보내는 것이 **문자 키 `a`** 라서, 한글 모드에서는 IME 가 그것을 조합용으로 가져가요 (`ㅁ` 이 찍혀요).
그러면 앱의 키 핸들러를 안 타서 `markInput()` 이 안 불리고 표본이 비어요. 스크립트가
`fcitx5-remote` 로 **영문으로 바꿨다가 끝나면 되돌려요.**

**단축키는 달라요** — `Ctrl+Shift+F12` 는 한글 모드에서도 앱에 도달해요
([#465](https://github.com/ensky0/tildaz/issues/465)). 위 "입력 손실 검사" 의 ①이 한글 모드에서도
되는 것과 모순이 아니에요. **키 종류가 다른 거예요.**

곁가지로, 한글 모드에서 preedit 은 화면에 그려지는데 표본은 안 잡혀요 — 즉 지금 계측은
**영문 직접 입력 경로만** 봐요. 한글 입력의 응답 지연을 재려면 계측 지점을 IME 경로에도 놓아야 해요.

### 회차가 폐기되면 자동으로 다시 돌아요

표본이 기대치의 8 할 미만이면 그 회차는 폐기예요 (`--retries`, 기본 3 회 재시도). 폐기의 알려진
원인은 **한글 입력기** (위에서 미리 막아요) 와 **측정 중 조작**이에요 — 합성 입력은 포커스된 창으로
가므로 측정 중에 창을 바꾸면 키가 다른 앱으로 새요.

## 다른 터미널과 비교하기

```sh
dist/stress/compare-terminals.sh --mb 64 --workload plain --cols 120 --rows 40
```

### 돌리는 환경 — **Windows 는 Git Bash · Linux 는 KDE Plasma**

`compare-terminals.sh` 는 platform 을 안 가리는 POSIX `sh` 스크립트지만, **셸과 데스크톱은
가려요**. 잘못된 데서 시작하면 아예 안 돌거나 캡처만 조용히 비어요.

| platform | 어디서 | 왜 |
|---|---|---|
| **Windows** | **Git Bash** (필수) | PowerShell 로는 **아예 안 돌아요** — `uname -s` 의 `MINGW*`/`MSYS*`/`CYGWIN*` 로 platform 을 판별하고, 자식이 Windows 실행파일이라 `cygpath -w` 로 경로를 변환해요. Git for Windows 에 항상 들어 있으니 따로 설치할 게 없어요. 아래 [Windows 에서 돌리기](#windows-에서-돌리기) 참고 |
| **Linux** | **KDE Plasma** (권장) | 스크립트 본체는 어느 DE 에서도 돌아요. 갈리는 건 **`--capture` 뿐**이에요 — KDE 만 창 단위로 확실히 잡혀요 (아래 표) |
| **macOS** | 아무 터미널 | 갈리는 게 없어요 |

**`--capture` 를 안 쓰면 Linux 는 DE 를 안 가려요.** 캡처가 필요할 때만 아래가 걸려요.

| Linux DE | 캡처 | 표시 | |
|---|---|---|---|
| **KDE Plasma** | `spectacle -b -n -a` | `@` | ✅ **창 단위**. 실기 검증된 유일한 DE ([#381](https://github.com/ensky0/tildaz/issues/381) AMD Ryzen AI 7 350 · [#413](https://github.com/ensky0/tildaz/issues/413) Intel Core i5-1240P, 둘 다 KDE Plasma Wayland) |
| sway · Hyprland | `grim` | **`~`** | ⚠️ 돼요. 전체 화면이라 **가려진 창은 못 찍어요** (타일링이라 보통 안 가려지긴 해요). 창 단위 성공이 없으니 정상 결과도 `~` 예요 ([#448](https://github.com/ensky0/tildaz/issues/448)) |
| GNOME 43+ | — | — | ❌ `gnome-screenshot` 이 제거돼서 **경로가 없어요** (있으면 `grim` 과 같이 전체 화면 · `~`) |

**어느 도구든 찍기 전에 대상이 살아 있는지 먼저 봐요** ([#448](https://github.com/ensky0/tildaz/issues/448)).
없으면 `?` 이고, 그 회차는 [#413](https://github.com/ensky0/tildaz/issues/413) 의 재시도가 hold 를
늘려 다시 찍어요. 예전에는 Linux 만 이 판정이 없어서 **창이 이미 닫힌 회차도 `@` 로 통과**했어요.

> **`zig build stress` 자체는 이 제약이 없어요.** Windows PowerShell 에서 그대로 돌아가요
> (`## 쓰는 법`). Git Bash · KDE 가 필요한 건 **여러 터미널을 띄워 비교하는 이 스크립트**예요.

같은 producer 를 여러 터미널 안에서 돌리고 완료 시간을 모아요. producer 가 출력을 끝낸 뒤
경과 시간과 **자기 그리드 크기**를 timing 파일에 적고, 스크립트가 그것을 표로 내요.

**그리드를 함께 남기는 게 핵심이에요.** 터미널마다 폰트 크기 해석이 달라서 같은 창 크기를
줘도 셀 수가 갈리고, 열 수가 다르면 줄바꿈 횟수가 달라져 파서 부하가 달라져요. 표의 grid
열이 목표와 다르면 그 줄은 비교에 쓰지 않아요. 실제로 이 검증이 kitty 의 창 크기 옵션이
무시되던 것과 ghostty 의 옵션 파싱 실패를 잡아냈어요.

**일부 터미널은 셸을 spawn 한 뒤 창 크기에 맞춰 resize 해요** (실측: ghostty · kitty · foot).
그래서 producer 는 그리드를 **출력 전후 두 번** 읽고 둘 다 timing 파일에 적어요. 표에
`측정 중 resize (AxB → CxD)` 가 뜨면 producer 가 초반을 다른 열 수로 출력했다는 뜻이라 그
회차는 비교에 쓸 수 없어요 — 열 수가 바뀌면 줄바꿈 횟수가 달라지니까요.

**그래서 producer 가 목표 그리드를 기다렸다가 출력을 시작해요** (`TILDAZ_STRESS_GRID`, 상한
2 초). 전후 두 값만으로는 *얼마나* 오염됐는지 알 수 없거든요 — 전환 시점이 없으니까요.
기다린 시간은 timing 의 `grid_wait_ms` 와 표의 `그리드 대기 N ms` 로 남아서, **어느 대상이
얼마나 늦게 resize 하는지가 그대로 드러나요.**

| 대상 | 대기 | 기다리지 않으면 |
|---|---:|---|
| foot | **10~15 ms** | `80x24 → 120x40` — 초반을 80 열로 출력해요 |
| ghostty | **51~56 ms** | `119x39 → 120x40` |
| kitty · alacritty · wezterm · TildaZ | 0 | 시작부터 목표 그리드예요 |

기다리게 한 뒤 foot 이 114.5 → **138.5 MiB/s** 로 올랐어요 (같은 조건 · 8 MiB smoke). 80 열
구간은 줄바꿈이 더 많아서 **불리하게** 작용하고 있었어요. 상한까지 기다려도 목표에 도달하지
못하면 그때는 예전처럼 `측정 중 resize` 가 떠서 그 회차가 걸러져요.

**대상은 그 platform 에 설치된 것만 자동으로 골라요** (`command -v` 로 확인해요).

| platform | 자동으로 도는 대상 |
|---|---|
| Linux | TildaZ · alacritty · kitty · wezterm · ghostty · **foot** |
| macOS | TildaZ · alacritty · kitty · wezterm · ghostty · **iTerm2** · **Terminal.app** |
| Windows | TildaZ · alacritty · wezterm · **Windows Terminal (`wt`)** · **conhost** |

Windows 에 kitty · ghostty 판이 없고 foot 은 Wayland 전용이라, Windows 는 그 자리를
Windows Terminal 이 채워요.

**OS 기본 터미널 둘 (Terminal.app · conhost) 만 설치 여부를 안 봐요** — 그 OS 에 항상 있으니까요.

**굵은 자리는 "그 OS 사용자가 실제로 쓰는 것" 이에요.** 나머지 넷 (alacritty · kitty ·
wezterm · ghostty) 은 개발자 취향의 선택지라 그것만 놓고 보면 그림이 왜곡돼요 — macOS
기록용 측정에서 **iTerm2 가 `cjk` 에서 우리보다 19 배 느렸어요** (5.9 대 112.0 MiB/s).
"우리가 cluster 에서 뒤진다" 는 이야기의 맥락이 달라지는 종류의 숫자인데, 개발자용만
비교하던 때는 안 보였어요.

#### iTerm2 는 Dynamic Profiles 로 넣어요

`~/Library/Application Support/iTerm2/DynamicProfiles/` 에 JSON 을 놓으면 iTerm2 가 파일
감시로 읽어서 프로파일이 생겨요. 격자 · scrollback · 실행 명령을 한 파일에 담을 수 있고
**사용자 설정을 전혀 건드리지 않아요** — 끝나면 그 파일만 지워요 (`trap EXIT`). `wt` 의 JSON
fragment 도 같은 구조예요 (아래 Windows 절).

다른 길은 전부 막혔어요 (실측):

| 방법 | 결과 |
|---|---|
| CLI (`open -na iTerm.app --args`) | 격자 옵션이 없어요 |
| AppleScript 로 창을 만든 뒤 크기 변경 | **명령이 먼저 시작돼서** 그 시점 격자로 출력해요 |

**측정 창은 스크립트가 닫아요** ([#414](https://github.com/ensky0/tildaz/issues/414)). 프로파일의
`Close Sessions On End` 는 **세션만** 닫아서 **빈 창이 남거든요** — 회차마다 쌓이고, 다음 실행의
위생 검사에도 계속 걸려요. 창 이름이 곧 프로파일 이름 (`tildaz-stress`) 이라 그걸로 우리 창만
골라요. 사용자가 열어 둔 창은 이름이 달라서 후보에 안 들어가요.

#### Terminal.app 은 escape sequence 로 넣어요

macOS 의 OS 기본 터미널이라 **Windows 의 conhost 와 같은 자리**예요 — 하한 기준선이자,
시스템 기본 터미널이 어느 정도인지 보여 주는 대조군이에요.

**격자는 `CSI 8 ; rows ; cols t` 로 줘요.** 셸이 자기 손으로 창을 리사이즈하니까 프로파일이
필요 없고, 사용자 설정에 흔적이 남을 일도 없어요.

```sh
printf '\033[8;40;120t'      # 셸이 자기 창을 120 열 × 40 행으로 바꿔요
```

한동안 *"Terminal.app 은 격자를 프로파일로만 받는다"* 고 정리돼 있었어요
([#381](https://github.com/ensky0/tildaz/issues/381#issuecomment-5220061290)). 그건 시도한 세
방법이 **셋 다 같은 길**이었기 때문이에요 — 전부 *Terminal.app 에게 격자를 알려 주는* 통로를
찾고 있었어요. escape sequence 는 방향이 반대라 그 구조에 아예 걸리지 않아요
([#414](https://github.com/ensky0/tildaz/issues/414) 에서 실측 3/3 이 목표 격자와 일치).

| 예전 방법 | 왜 막혔나 |
|---|---|
| AppleScript `do script` + 격자 설정 | 창을 만든 **뒤** 격자를 바꿔요 |
| `defaults` 로 임시 프로파일 | **프로파일**로 줘요 — 실행 중인 앱이 안 읽어요 (`-1728`) |
| `.terminal` 파일 + `open` | **프로파일**로 줘요 — `CommandString` 이 실행되지 않아요 |

그때 기록된 *"셸이 30×120 을 봐요"* 는 뒤바뀐 격자가 아니었어요. **그 머신 기본 프로파일의
120 열 × 30 행**이에요 — `stty size` 가 `rows cols` 순서로 찍은 값을 `cols×rows` 로 읽은
거예요. 격자를 못 준 게 아니라 **애초에 안 바뀐 상태의 값**이었어요.

**명령은 `exec` 로 띄워요.** 이게 창 정리까지 함께 풀어요.

```applescript
do script "exec sh <wrapper>"     -- 로그인 셸 자체를 wrapper 로 대체해요
```

로그인 셸을 대체하니까 producer 가 끝나는 순간 그 창에 **실행 중인 프로세스가 없어요.**
왜 그게 중요한지는 아래 함정에 적어요.

##### ⚠ 실행 중인 셸이 있는 창은 닫히지 않아요 — 확인 시트

`close` 를 불러도 **아무 반응 없이 창이 그대로**인 것처럼 보이는 때가 있어요. 인덱스로 바꿔도,
네 번을 반복해도 그대로였어요 (실측). `System Events` 로 들여다보고서야 원인이 나왔어요.

```
[… TildaZ-stress-9999 … sheets=1] [… TildaZ-stress-terminal … sheets=1]
```

실행 중인 셸이 있는 창을 닫으려 하면 Terminal.app 이 **확인 시트 (`취소` / `종료`) 를 띄워요.**
시트가 응답을 기다리는 동안 창은 안 닫히고, **그 뒤의 close 는 전부 무시돼요.** 시트를
승인하려면 Accessibility 권한이 필요하고 버튼 이름이 로케일 의존이라 (`종료` / `Terminate`)
자동화로 쓸 수 없어요.

그래서 **순서가 정해져 있어요** — `cleanup_terminals` 가 프로세스를 먼저 죽이고, **그 뒤에**
창을 닫아요. `exec` 로 로그인 셸까지 대체해 두면 남는 프로세스가 없어서 시트가 아예 안 떠요
(실측: 닫기 전후 시트 0, 창이 깨끗이 닫혀요).

##### 창은 태그로 찾아요

`do script` 가 돌려주는 **tab** 에 `custom title` 로 태그 (`TildaZ-stress-<pid>`) 를 달고, 그
태그로만 창을 닫아요. `front window` 로 잡지 않는 이유는 그 찰나에 사용자가 다른 창을 앞으로
가져오면 **사용자 창에 태그가 붙어 나중에 닫히기 때문**이에요. pid 를 넣어서 앞선 실행이 남긴
창도 안 건드려요.

##### ❌ scrollback 은 못 맞춰요

AppleScript 사전에 크기 속성이 아예 없어요 (있는 `history` 는 **내용 읽기 전용**이에요).
그래서 사용자 프로파일 값이 그대로 쓰이고, **이 대상만 조건이 달라요.** 스크립트가 매 실행에서
경고해요.

conhost 와 같은 처지이긴 한데 **성격이 조금 달라요** — conhost 는 "스크롤백 없음" 으로 고정이라
적어도 재현은 되는데, Terminal.app 은 **머신마다 값이 달라요.** 조건이 다를 뿐 아니라 재현성도
떨어진다는 뜻이라, 이 대상의 숫자는 그 점을 알고 읽어야 해요.

**전부 자동이에요.** TildaZ 도 스크립트가 직접 띄워요 — 측정용 실행 옵션 `-e <실행파일>` ·
`-size <COLS>x<ROWS>` 를 [#382](https://github.com/ensky0/tildaz/issues/382) 에서 만들었어요.
그 전에는 TildaZ 만 손으로 재야 했어요 (로그의 셀 크기로 퍼센트를 역산 → config 수정 →
재시작 → F1 으로 열어 명령 붙여넣기 → config 되돌리기).

**두 옵션은 측정 내부용이에요** — 사용자 문서 (`README` · `CONFIG.md` · `KEYBINDINGS.md`) 에
넣지 않고 쓰는 곳은 이 스크립트 하나예요.

측정용 인스턴스는 **평소 쓰는 TildaZ 와 겹치지 않도록 두 가지를 나눠요** — *하지 않는 것*과
*worker 와 다른 이름을 쓰는 것*이에요.

| 무엇 | 어떻게 |
|---|---|
| worker lock | 잡지 않아요 |
| 전역 핫키 · DE 단축키 등록 | 하지 않아요 (Windows `RegisterHotKey` · macOS event tap · Linux 의 sway `bindsym` · GSettings · KDE KGlobalAccel) |
| 새 instance 요청 처리 | 하지 않아요 (macOS 는 broadcast 라 observer 자체를 등록하지 않아요) |
| instance 요청 endpoint 상태 | 기록하지 않아요 |
| config 파일 | **읽기만** 해요 — 같은 폰트 · 테마로 재야 비교가 성립하니 공유하지만, 파일이 없어도 만들지 않아요 |
| 창 타이틀 · Wayland app_id | worker 와 다른 이름 (`TildaZ-stress` · `tildaz.stress`) — worker 창을 찾는 쪽이 (Windows 의 `FindWindowW`, GNOME · Cinnamon extension) 측정 창을 집지 않게요 |
| 로그 파일 | `tildaz_stress.log` — 사용자 세션 로그 (`tildaz_N.log`) 와 섞이면 진단이 어려워요 |

`hidden_start` 는 무시하고 창을 표시한 채 시작하고 (숨겨져 있으면 렌더가 일어나지 않아 측정이
무의미해요), producer 가 끝나면 스스로 종료해요.

이 목록은 한 번에 다 갖춰진 게 아니라 **실기 검증에서 빠진 것이 드러날 때마다 채워졌어요** —
처음엔 lock 과 핫키뿐이었고, [Windows 실기](https://github.com/ensky0/tildaz/issues/382#issuecomment-5172400255)에서
endpoint 상태와 창 타이틀이, [macOS 실기](https://github.com/ensky0/tildaz/issues/382#issuecomment-5173008405)와
그 뒤의 코드 점검에서 나머지가 나왔어요.

**로그로 확인할 때는 host 별 문구가 달라요.** `global hotkey not registered (stress run)` 은
Windows 문구예요. Linux 는 다른 문장을 쓰고, macOS 는 이 항목에 로그를 남기지 않아요 — 그러니
"그 줄이 없다" 를 결함으로 읽지 말고, macOS 에서는 측정 로그 파일이 따로 생기는지와 timing
파일의 격자로 판정하세요.

macOS 의 ghostty 는 조건이 까다로워서 스크립트가 **임시 config 파일**을 만들어 넘겨요.
CLI 로 터미널을 띄울 수 없고 (`ghostty --help`: *"On macOS, launching the terminal emulator
from the CLI is not supported"*), `open -na … --args` 로 config key 옵션을 **여러 개** 주면
한 값으로 합쳐져 실패해요 (실측: `window-width: invalid value "200 --window-height=60"`).
`--config-file` 하나만 넘기면 정상이라 그 길을 써요 — **사용자 설정은 건드리지 않아요.**

**터미널마다 창 크기 지정 방법이 달라요** (실측으로 확정한 것):

| 터미널 | 그리드 지정 |
|---|---|
| kitty | `-o remember_window_size=no -o initial_window_width=120c -o initial_window_height=40c` — `remember_window_size` 를 끄지 않으면 **이전 세션 크기를 복원해서 옵션을 무시해요** |
| alacritty | `-o window.dimensions.columns=120 -o window.dimensions.lines=40` |
| wezterm | `--config initial_cols=120 --config initial_rows=40` — `--config` 는 **전역 옵션**이라 `start` **앞**에 와야 해요 |
| Windows Terminal (`wt`) | `-w new --size 120,40` — 둘 다 필수예요 (아래 Windows 절) |
| conhost | 창 크기 옵션이 없어서 `mode con: cols=120 lines=40` 으로 줘요 (아래 Windows 절) |
| ghostty | 스크립트가 임시 config 파일을 만들어 `--config-file` 로 넘겨요. `window-save-state = never` 가 필수이고 값은 `false` 가 아니라 `default \| never \| always` 중 하나예요 |
| TildaZ | `-size 120x40` — 스크립트가 이걸 써요. config 퍼센트는 건드리지 않아요 |

### 창이 안 보일 때 — `--capture` 로 찍어 둬요

측정 중에는 키보드·마우스에 손을 대지 않아요 ([측정 위생](#측정-위생)). 그런데 **창이 다른 창
뒤에 뜨면** 상태를 확인할 방법이 없어져요 (Windows 에서 wezterm · `wt` 가 그랬어요).

```sh
dist/stress/compare-terminals.sh --mb 8 --workload zwj --repeat 1 --timeout 30 --capture
```

**경로는 선택이에요.** 안 주면 **`dist/stress/shots/`** 에 남아요 — 스크립트 바로 옆이라 찾기
쉽고, **모든 OS · 데스크톱 환경에서 같은 자리**예요 (`.gitignore` 에 있어서 git 에는 안 잡혀요).
다른 곳에 두려면 `--capture /tmp/shots` 처럼 경로를 주면 돼요.

회차마다 `<디렉터리>/<워크로드>-<이름>-<회차>.png` 로 남겨요 (예: `zwj-alacritty-1.png`).
진행 표시가 `.` 대신 아래 다섯으로 바뀌어요.

| 표시 | 뜻 |
|---|---|
| **`@`** | 대상 창을 **창 단위**로 찍었고 **내용이 있어요** (가장 좋은 결과) |
| **`_`** | 찍히긴 했는데 **사실상 빈 이미지**예요 (단색) — 아래 참고 |
| **`~`** | 창은 찾았지만 창 단위가 안 돼서 **전체 화면**으로 물러섰어요 |
| **`?`** | 창을 **아예 못 찾았어요** — PNG 에 대상이 있어도 우연이에요 |
| **`!`** | PNG 자체가 안 생겼어요 |

이 구분이 없던 때 **창을 한 번도 못 잡던 conhost 가 계속 `@` 로 성공처럼 보였어요**
([#381](https://github.com/ensky0/tildaz/issues/381)).

**macOS 도 이제 이 구분을 해요** ([#414](https://github.com/ensky0/tildaz/issues/414)). 예전에는
`~` · `?` 를 Windows 만 갈라내고 macOS 는 전부 `@` 로 찍혀서, **전체 화면으로 물러선 회차를
사람이 PNG 을 열어 봐야만** 알 수 있었어요. 실제로 Terminal.app · iTerm2 두 대상이 전체 화면으로
찍혔는데 표에는 `@` 로 나왔고, 파일을 열어 보고서야 발견했어요.

**`_` 도 같은 사유로 나중에 갈라낸 거예요.** `@` 는 *"캡처 API 가 성공을 돌려줬다"* 는 뜻이었을
뿐이라, 창 단위로 찍었는데 **단색 이미지**가 나와도 성공으로 보였어요 — 실측으로 alacritty 가
**550 byte** 였고 같은 실행의 정상 캡처는 65~134 KB 였어요. 판정은 **파일 크기** (2 KiB 미만) 로
해요. 단색 PNG 은 압축이 극단적으로 잘 되고 텍스트가 찬 터미널 화면은 그럴 수 없어서, 이미지
라이브러리 없이 세 platform 이 같은 코드로 판정할 수 있어요. 창을 아주 작게 (`--rows` 를 줄여)
찍으면 오탐이 날 수 있는데, 임계가 정상값보다 훨씬 아래라 실사용에서는 걸리지 않아요.

**파일명이 워크로드로 시작해요.** 워크로드를 바꿔 가며 같은 디렉터리에 여러 번 찍는 게 정상
사용법인데 (`zwj` 한 번, `cjk` 한 번), 이름에 워크로드가 없으면 **뒤 실행이 앞 실행을 덮어써서**
비교할 수가 없어요. 이름순 정렬도 워크로드끼리 묶여요. 세 platform 공통이에요.

⚠️ **`@` 여도 대상이 안 찍혔을 수 있어요.** 빈 이미지는 이제 `_` 로 갈라내지만, **전체 화면으로
물러선 경우** (macOS 에서 창을 못 찾음 · 리눅스 전체) 는 크기가 정상이면서도 대상이 다른 창 뒤에
있어 안 보일 수 있어요 — 크기로는 못 걸러요. **PNG 을 눈으로 확인해 주세요.** 실제로 그렇게 한
장을 놓친 적이 있어요 (아래 "찍기 전에 기다려요").

⚠️ **이 옵션을 켠 실행의 숫자는 기록용으로 쓰지 마세요.** 캡처 도구가 측정 직후에 CPU 를 쓰고,
producer 가 창을 **4 초** 더 붙들고 있어요 (그래야 찍을 창이 남아요 — `TILDAZ_STRESS_HOLD_MS`).
**smoke 확인용**이에요. 기록용은 이 옵션 없이 `--repeat 5` 로 내요.

| platform | 쓰는 도구 | 범위 | 알아 둘 것 |
|---|---|---|---|
| **macOS** | [`dist/macos/color-capture.m`](../macos/color-capture.m) (ScreenCaptureKit) | **창 단위** | **완전히 가려진 창도 찍혀요** (실측: 같은 자리에 창 둘을 겹치고 아래 창을 찍으니 아래 창 내용이 나왔어요). 스크립트가 `clang` 으로 빌드해서 써요. **화면 기록 권한**이 필요하고 잠금 화면이면 실패해요. 찾는 기준은 **bundle identifier** 예요 (`com.apple.Terminal` 등) — 앱 이름은 **시스템 언어로 번역**돼서 기준이 될 수 없어요 (아래 참고). 창을 못 찾으면 `screencapture -x` 전체 화면으로 물러서고 `?` 를 찍어요 |
| **Windows** | PowerShell (`PrintWindow` → 실패 시 `CopyFromScreen`) | **창 단위** | 창을 띄우자마자 **(0,0) 으로 옮기고 맨 앞으로** 올려요 (`SWP_NOACTIVATE` 라 포커스는 안 뺏어요). `PrintWindow` 가 실패하는 흔한 원인은 **hold 가 모자라 창이 이미 닫힌 것**이라, 그 회차는 hold 를 늘려 다시 찍어요 (아래 참고). **DPI 함정도 있어요 — 아래 참고** |
| **Linux (sway · Hyprland)** | `grim` | 전체 화면 → **`~`** | wlroots 계열의 `zwlr_screencopy` 를 써요. **가려진 창은 못 찍어요** — Wayland 는 client 가 다른 창 내용을 읽을 수 없어요. 타일링이라 보통 안 가려져요. 창 단위 성공이 애초에 없으니 **정상 결과도 `~`** 예요 ([#448](https://github.com/ensky0/tildaz/issues/448)) |
| **Linux (KDE Plasma)** | `spectacle -b -n -a` | **활성 창** → `@` | KWin 은 `zwlr_screencopy` 를 client 에게 노출하지 않아 grim 이 안 돼요. `org.kde.KWin.ScreenShot2` 는 호출자를 검증해서 직접 부를 수 없고, **Spectacle 이 정상 통로**예요 (KDE 기본 설치). `-a` 라 **창 단위로 찍히고 가려짐 문제도 없어요** (활성 창은 맨 앞이니까요). 다만 방금 뜬 창이 활성이 아니면 엉뚱한 창이 찍혀요 — 아래 참고 |
| **Linux (GNOME)** | `gnome-screenshot` | 전체 화면 → **`~`** | GNOME 43 에서 빠졌어요. 없으면 캡처를 못 해요 |

리눅스에 **하나로 다 되는 방법은 없어요** — Wayland 는 client 가 화면을 읽을 수 없고 통로가
compositor 마다 달라요. 위 순서대로 시도하고, 하나도 없으면 시작할 때 그 사실을 알려요.

#### 리눅스가 창 단위 실패를 표시하게 된 경위 ([#448](https://github.com/ensky0/tildaz/issues/448))

예전에는 **Windows 만** `?` · `~` 를 찍었어요 (macOS 는 [#414](https://github.com/ensky0/tildaz/issues/414)
에서 합류). 리눅스는 두 플래그가 `0` 고정이라 표시가 `!` · `_` · `@` 셋뿐이었고, 그래서 **창이 이미
닫힌 회차도 `spectacle -a` 가 엉뚱한 활성 창을 찍어 2 KiB 를 넘기면 `@` 로 통과**했어요. 표시만의
문제가 아니었어요 — [#413](https://github.com/ensky0/tildaz/issues/413) 의 재시도 루프가 `~` · `?` ·
`_` 를 조건으로 도는데 리눅스에서 남는 게 `_` 하나뿐이라 **hold 가 모자라 창이 먼저 닫힌 회차를
다시 찍지 않았어요.**

**판정은 producer 의 생존이에요.** hold 를 붙드는 주체가 producer 이고 (`TILDAZ_STRESS_HOLD_MS` 가
없으면 timing 을 쓴 직후 끝나요), 캡처는 timing + `CAPTURE_DELAY` 에 찍으니 **그 시점에 producer 가
살아 있다는 것이 곧 찍을 창이 있었다**는 뜻이에요. 찾는 방법은 `cleanup_terminals` 와 같은
`$WORK_DIR/<대상>.timing` 명령줄 패턴이라 **대상 이름 표가 필요 없어요** (#414 가 macOS 에서 거부한
그 함정이에요).

**남은 한계 — `@` 는 "대상이 찍혔다" 의 보장이 아니에요.** KDE 에서 대상이 살아 있어도 **다른 창이
활성이었으면** 그 창이 찍혀요. 가르려면 대상을 먼저 활성화해야 하는데, `spectacle` 에 창을 지목하는
옵션이 없어 (`-a` · `-u` 뿐) `org.kde.KWin /WindowsRunner` 의 `Match` + `Run` 으로 가야 하고 그
매칭 키가 **resource class** 라 대상마다 형식이 갈려요 (`foot` · `kitty` · `Alacritty` ·
`org.wezfurlong.wezterm` …). 이름 표를 다시 만드는 셈이라 **별개 결정으로 남겼어요.** 실행 요약이
이 사실을 매번 한 줄로 알려요.

#### macOS 에서 창을 못 찾는 두 가지 이유 ([#414](https://github.com/ensky0/tildaz/issues/414))

둘 다 실측으로 만났고, **증상이 똑같아요** — 그 회차만 전체 화면으로 찍혀요.

**① 앱 이름이 시스템 언어로 번역돼요.** `color-capture --list` 의 `app` 열은
`SCWindow.owningApplication.applicationName` 인데, 이건 **표시 이름**이라 한국어 macOS 에서는
`Terminal` 이 `터미널` 로 나와요 (`제어 센터` · `알림 센터` 도 마찬가지예요).

```
91       com.apple.Terminal           터미널                757x479      tildaz — … — 80×24
```

그래서 찾는 기준을 **bundle identifier** 로 바꿨어요. 언어에 따라 바뀌지 않거든요. **언어별
이름 표는 두지 않아요** — 언어가 늘 때마다 표를 늘려야 하고, 같은 언어라도 OS 판이 바뀌면
표기가 달라져 조용히 빗나가요. 현지화되지 않는 대상들 (kitty · alacritty · wezterm · ghostty) 만
우연히 멀쩡했던 것이라, OS 기본 앱을 대상에 넣자마자 드러났어요.

**② hide 된 앱의 창은 목록에 아예 없어요.** `--list` 는 `onScreen` 인 창만 내요. 그런데 위생
절차가 배경 앱을 hide 하는데 (`hygiene_minimize_macos`), **이미 떠 있던 Terminal.app · iTerm2 는
그 hide 를 겪은 앱에 창을 붙이는** 방식이라 창이 `onScreen` 이 아니에요. 실측에서 iTerm2 가
`visible=false` 인 채로 `--list` 에 없었고, 사용자가 다시 띄우자 바로 나타났어요.

그래서 **스크립트가 측정 창을 만든 뒤 그 앱의 hide 를 풀어요** (`set visible to true`). hide 만
풀고 **앞으로 가져오지는 않아서 포커스를 뺏지 않아요** (실측). 가려져 있어도 ScreenCaptureKit 은
창 내용을 주니까 그걸로 충분해요.

**이건 캡처만의 이야기가 아니에요.** hide 된 앱은 화면을 그리지 않으니, 그대로 두면 **그 회차만
렌더 부하가 빠진 채** 측정돼요 — 새 프로세스로 떠서 화면에 올라오는 다른 대상들과 조건이 달라져
그 대상에게 유리해져요. 위의 [측정 위생](#측정-위생)대로 **대상 터미널을 미리 종료**하면 애초에
hide 를 겪지 않으니, 둘은 같은 문제의 앞뒤 대비책이에요.
`xdg-desktop-portal` 은 표준이지만 **권한 대화상자가 떠서** 손 안 대고 도는 측정과 안 맞아요.

#### 찍기 전에 2 초 기다려요

**timing 파일이 생긴 시점은 측정이 끝난 시점이지 창이 화면에 올라온 시점이 아니에요.** wezterm 은
GUI 시작이 제일 느려서, 8 MiB 측정 (111 ms) 이 창보다 먼저 끝난 회차가 있었어요 — 그 회차 PNG 에는
**wezterm 창이 아예 없었어요** (macOS 실측). 그래서 timing 을 본 뒤 2 초 기다렸다 찍어요.

`TILDAZ_STRESS_HOLD_MS` 4 초는 이 2 초에 캡처 시간을 더한 값이에요. **캡처 자체는 macOS 0.3 초 ·
Windows 0.73 초**예요 (둘 다 실측 — Windows 는 `powershell` 프로세스 시작과 `Add-Type` 의 C#
컴파일까지 포함한 값이에요).

#### hold 가 모자라면 PNG 에 창이 없어요 — `--hold-ms` 와 자동 재시도

**화면이 크면 캡처가 그만큼 오래 걸려서 4 초 안에 못 끝나요.** 그러면 찍을 때 producer 가 이미
창을 놓은 뒤라 **PNG 에 대상이 없어요.** [#413](https://github.com/ensky0/tildaz/issues/413) 에서
실제로 걸렸어요 — 2880×1800 · 200 % 머신에서 tildaz 가 `~` 였는데, **`HOLD_MS` 만 늘리자 `@`** 가
됐어요 (다른 건 아무것도 안 바꿨어요).

| hold | 표본 (대상 × 회차) | `PrintWindow` 실패 |
|---|---|---|
| 넉넉 (15 초) | 18 | **0 건** |
| 기본 (4 초) | 5 | 1 건 |

그래서 두 가지를 뒀어요.

- **`--hold-ms <N>`** 으로 기본값 (4000) 을 바꿀 수 있어요. 표기는 `measure-repeat.sh` 와 같아요.
- **실패한 회차는 hold 를 15 초로 늘려 한 번 다시 찍어요.** `~` (전체 화면으로 물러섬) 과 `_`
  (빈 이미지) 만 대상이에요. 표시는 마지막 시도의 결과이고, 재시도한 회차 수는 표 아래 요약에
  나와요. 자주 뜨면 `--hold-ms` 를 올려 두는 게 나아요.

**`?` (창을 못 찾음) 는 재시도하지 않아요.** 그건 타이밍이 아니라 창을 못 고른 거라 hold 를
늘리면 **오히려 나빠져요** — 앞 회차 창이 오래 남으면 wt 는 `wt -w new` 가 기존 프로세스에 창을
요청해서 새 프로세스가 안 뜨고, *"이번 회차에 새로 뜬 창만 고른다"* 는 `StartTime` 필터에 걸려요
(#413 실측: hold 15 초에서 wt 3 회차 중 2 회차가 `?`. 기본 4 초에서는 안 났어요).

#### `ddagrab` 2 차 경로는 없앴어요

예전에는 ffmpeg 의 `ddagrab` (Desktop Duplication API) 으로 창 rect 만 잘라 찍는 2 차 경로가
있었어요. `PrintWindow` 가 환경에 따라 깨진다고 봤기 때문인데, **그 전제가 위 실측으로 반증됐어요**
— 깨진 게 아니라 hold 가 모자랐던 거예요. 넉넉한 hold 에서는 다섯 대상이 전부 `PrintWindow` 로
찍혀요.

지우니 좋은 점이 셋이에요. **캡처가 빨라져 타임아웃 자체가 줄고** (그 경로가 1.18 초를 먹었어요),
ffmpeg 의존이 사라지고, 딸려 있던 미검증 항목 (다중 모니터에서 `output_idx` 선택 · HDR 화면) 도
함께 없어졌어요.

#### Windows 는 창을 (0,0) 으로 옮겨요

**올리기만 하면 아래가 잘려요.** Windows 가 새 창을 cascade 로 놓아서 y 가 0 이 아닌데, 40 행짜리
터미널 창은 그 offset 만큼 화면 아래로 삐져나가요. 실기에서 **alacritty 는 작업 표시줄에 가렸고
wezterm 은 아래 20 px 이 잘렸어요** ([#381](https://github.com/ensky0/tildaz/issues/381), 2880×1800 ·
200 % 노트북). 그래서 `SWP_NOMOVE` 를 빼고 (0,0) — 주 모니터 좌상단 — 으로 함께 옮겨요.
**캡처는 측정이 끝난 뒤**라 숫자에는 영향이 없어요.

**띄우자마자도 한 번 옮겨요.** 찍기 직전에만 옮기면 **도는 동안 내내** 창이 가려 있거나 화면 밖에
있어서 눈으로 볼 수가 없어요 — 눈으로 보는 게 `--capture` 를 만든 이유인데요. 이때는 `HWND_TOP`
(보통 창들 중 맨 앞) 만 써요. 측정이 도는 내내 topmost 로 박아 두면 다른 창을 계속 덮으니까요.

⚠️ **창이 화면보다 크면 옮겨도 잘려요.** 그때는 `--rows` 를 줄여서 찍어요.

**TildaZ 만 안 옮겨져요 — 의도된 거예요.** [`src/window.zig`](../../src/window.zig) 의
`WM_WINDOWPOSCHANGING` 핸들러가 `SWP_NOMOVE` 없는 외부 요청의 x/y 를 `expected_x`/`expected_y` 로
되돌려요 (Display Fusion · FancyZones 류가 drop-down rect 를 건드리는 걸 막는 방어예요). z-order 는
그대로 올라가고 위치만 무시돼요. TildaZ 는 drop-down 이라 원래 y=0 이라서 잘릴 일이 없으니
예외 처리를 넣지 않았어요.

#### Windows 캡처는 DPI-aware 여야 해요 — 안 그러면 화면의 좌상단 1/4 만 찍혀요

Windows PowerShell 5.1 은 **DPI-unaware** 라 화면 metric 을 *논리* 크기로 줘요. 그런데
`CopyFromScreen` 은 **물리 픽셀을 1:1 로** 복사해요. 둘이 어긋나서 200 % 배율의 2880×1800
화면에서 **좌상단 1440×900 만** 잘려 나왔어요.

| | 값 |
|---|---|
| 물리 해상도 | 2880×1800 |
| `SystemInformation.VirtualScreen` (unaware) | **1440×900** ← 비트맵 크기가 이걸 따라갔어요 |
| `CopyFromScreen` 이 복사한 것 | (0,0) 부터 **물리** 1440×900 = 화면의 좌상단 1/4 |

**배율 100 % 머신에서는 논리 = 물리라 멀쩡해 보여요.** 그래서 200 % 노트북에서만 드러났어요
([#381](https://github.com/ensky0/tildaz/issues/381) 실측 — PNG 다섯 장이 전부 1440×900 이고,
작업 표시줄이 auto-hide 가 아닌데 하단에 없고, 창이 오른쪽에서 잘렸어요).

그래서 `capture.ps1` 이 **화면 크기를 읽기 전에 제일 먼저** `SetProcessDpiAwarenessContext
(PER_MONITOR_AWARE_V2)` 를 불러요. 크기도 WinForms 대신 `GetSystemMetrics(SM_*VIRTUALSCREEN)`
으로 직접 읽어요 — WinForms 가 값을 언제 캐시하는지에 기대지 않으려고요. Windows 10 1703
이전에는 그 export 가 없어서 구형 `SetProcessDPIAware()` 로 물러서요.

**macOS · Linux 에는 이 함정이 없어요.** ScreenCaptureKit · grim · spectacle 은 애초에 물리
픽셀 기준이에요.

#### 생성하는 PowerShell 파일에는 UTF-8 BOM 을 붙여요

Windows PowerShell 5.1 은 **BOM 이 없는 `.ps1` 을 ANSI 코드페이지**로 읽어요 (한국어 Windows 는
CP949). 스크립트가 만드는 `capture.ps1` 은 UTF-8 이라 한글 주석의 바이트가 잘못 해독되는데,
대개는 주석 안이라 무해하지만 **어떤 조합은 토큰을 깨서 파싱이 통째로 실패**해요.

실제로 주석에 `①` 을 넣자 *"예기치 않은 '}' 토큰"* 으로 스크립트가 아예 안 돌아서 **다섯 대상이
전부 `!`** 가 됐어요 ([#381](https://github.com/ensky0/tildaz/issues/381) 실기). 캡처만 죽고
측정은 그대로 돌아서 표는 정상으로 보여요 — 눈치채기 어려운 실패예요.

그래서 heredoc 앞에 BOM 을 먼저 써요 (`printf '\357\273\277'`). 이러면 PowerShell 이 UTF-8 로
읽어서 이 계열의 사고가 아예 안 나요.

#### 캡처 회차 수는 파일로 세요

`run_terminal_win` 은 `run_terminal` 을 **서브셸** `( … )` 안에서 불러요 (환경변수를 이 실행에만
걸려고요). 그래서 그 안에서 올린 셸 변수는 밖에 안 남아요 — alacritty · wezterm · wt 의 회차가
요약 집계에서 통째로 빠져 **다섯 대상이 전부 `!` 인데 "2 회차가 안 찍혔어요"** 로 나왔어요
(212ec07 에서 표시를 넷으로 나눌 때부터 있던 버그예요). 지금은 회차마다 결과를 파일에 한 줄씩
적고 끝에서 세요.

### Windows 에서 돌리기

**Git Bash 에서 같은 스크립트를 그대로 써요.** Git for Windows 에 항상 포함되니 따로 설치할
게 없어요.

```sh
# Git Bash
zig build -Doptimize=ReleaseFast -Dsimd=true --cache-dir C:/ziglang/tildaz-cache
zig build stress -Doptimize=ReleaseFast -Dsimd=true --cache-dir C:/ziglang/tildaz-cache -- throughput --layer parser --mb 1
dist/stress/compare-terminals.sh --mb 64 --workload plain --cols 120 --rows 40
```

Windows 만의 주의점이에요.

| 무엇 | 왜 |
|---|---|
| **경로 변환** | 자식이 Windows 실행파일이라 timing 파일 · producer 경로를 `cygpath -w` 로 넘겨요. MSYS 는 명령줄 인자는 자동 변환하지만 **환경변수 값은 변환하지 않아요** — 그래서 producer 가 timing 파일을 못 열던 문제가 생겨요 |
| **`wt` 는 `-w new` 가 필수** | 사용자의 `windowingBehavior` 가 `useAnyExisting` 이면 기존 창에 **탭으로** 붙어서 창 크기 옵션이 의미를 잃어요 |
| **`wt --size` 가 무시될 수 있어요** | `launchMode` 가 `maximized` · `fullscreen` · focus 계열이면 무시돼요 ([Microsoft Learn](https://learn.microsoft.com/en-us/windows/terminal/command-line-arguments)). 그때는 표의 grid 열이 목표와 달라지니 그 줄을 비교에 쓰지 않아요 |
| **conhost 는 스크롤백이 없어요** | 창 크기 옵션이 없어 `mode con:` 으로 격자를 주는데, `lines=N` 이 창과 버퍼를 함께 N 으로 만들어요. 다른 터미널에는 100000 줄을 주므로 **conhost 값에는 스크롤백 관리 비용이 빠져 있어요** — 같은 조건이 아니라는 뜻이에요 |
| **kitty · ghostty · foot 은 없어요** | Windows 판이 없고 (foot 은 Wayland 전용) `command -v` 로 자동으로 빠져요 |
| **창이 다른 창 뒤에 뜰 수 있어요** | Win32 는 *foreground 프로세스가 **직접** 시작한 프로세스* 에만 창을 앞으로 낼 권한을 줘요 ([SetForegroundWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow)). `wt` 는 실행 별칭이라 부모 관계가 끊기고, wezterm 은 GUI 를 손자 프로세스로 띄웠어요. **`wt` 는 Windows Terminal 자체의 버그** ([#18324](https://github.com/microsoft/terminal/issues/18324), Priority-1) 로 **1.23.10353.0 에서 고쳐졌어요** — `wt --version` 이 그보다 낮으면 업데이트하세요. wezterm 은 아래처럼 실행 방법을 바꿔서 해결했어요. 상태를 봐야 하면 `--capture` 를 쓰세요 |
| **alacritty 는 `zwj` 계열을 소화하지 못해요 — 스크립트가 자동으로 빼요** | 바로 아래 절 참고. Windows + `zwj` / `zwj_varied` 조합만 해당해요 |
| **alacritty 는 큰 출력 뒤에 안 닫혀요 — 스크립트가 상한을 두고 정리해요** | 아래 두 번째 절 참고. 워크로드를 안 가리고 (`plain` 에서도 나요) `--capture` 를 켠 실행에서만 드러나요 |

#### alacritty 는 Windows 에서 `zwj` 계열을 못 돌려요 (자동 제외)

워크로드 11 종을 8 MiB 로 한 번씩 돌려 범위를 좁혔어요 ([#381](https://github.com/ensky0/tildaz/issues/381),
Ryzen AI 7 350 · Windows 11 · alacritty 0.17.0).

| 워크로드 | 결과 | | 워크로드 | 결과 |
|---|---|---|---|---|
| `plain` | 완료 1,038 ms | | **`zwj`** | **멈춤** |
| `ansi` | 완료 990 ms | | `hangul_varied` | 완료 1,644 ms |
| `cjk` | 완료 1,336 ms | | `emoji_vs16_varied` | 완료 1,106 ms |
| `hangul` | 완료 1,746 ms | | `skintone_varied` | 완료 985 ms |
| `emoji_vs16` | 완료 978 ms | | **`zwj_varied`** | **멈춤** |
| `skintone` | 완료 1,097 ms | | | |

**`zwj` 계열 둘만 멈춰요.** `cjk` 도 ZWJ 를 담는데 멀쩡한 게 단서예요 — `cjk` 는 줄에 ZWJ 가 몇
개뿐이고 `zwj` 계열은 **줄 전체가 ZWJ 묶음**이라, **ZWJ 밀도**가 임계를 넘을 때만 나요. 크기
경계도 있어요: `zwj` 는 1 MiB 는 완주하고 **2 MiB 부터 멈춰요** (8 MiB 2/2 멈춤).

멈춘 회차의 **producer CPU 시간은 0 이 아니에요** (0.047 s · 0.016 s). producer 는 시작해서 출력을
하다가 진행이 사실상 멈춰요. 창에 입력 이벤트를 주면 조금 진행하고 다시 멈춰요. 포커스는 변수가
아니에요 (포커스를 준 상태에서도 엔터 사이마다 다시 멈췄어요).

> 이전 판 문서에 있던 *"`main` 진입 전에 멈춘다 · CPU 시간 0"* 은 **틀렸어요** — 위 실측으로 반증됐어요.

⚠️ **"멈춤" 이라는 판정 자체가 아직 확정이 아니에요** (2026-08-07,
[#381](https://github.com/ensky0/tildaz/issues/381)). **`hangul` 도 멈춘 것처럼 보이는데 오래
기다리면 완주해요** (사용자 관찰). 실제로 Windows 기록용 측정에서 alacritty 의 `hangul` 이
**15,401 ms** 로 다섯 대상 중 가장 느렸고 (`--timeout 120` 이라 완주), 위 8 MiB 표에서도 `hangul`
이 1,746 ms 로 열한 워크로드 중 가장 느려요 — 8 배 페이로드에 8.8 배라 **선형에 가까워요.**

그러면 `zwj` 의 멈춤 판정도 다시 봐야 해요. 위의 *"2 MiB 부터 멈춘다"* 는 **`--timeout 30` 회차**
에서 나온 것이라 **저속을 멈춤으로 읽었을 가능성**이 있고, *"producer CPU 시간이 0 이 아니다"* 도
"막혔다" 보다 **"느리게 진행 중"** 에 더 맞아요. 남은 반례는 *"입력을 주면 조금 진행한다"* 하나예요.

확인하려면 `--timeout` 을 크게 주고 `zwj` 를 1 회차 돌려요. `zwj` 는 줄 byte 가 245 (한글 50 의
5 배) 인 데다 alacritty 는 ZWJ 묶음을 **항목당 8 열**로 그리니, 완주하더라도 **분 단위**일 수
있어요 — 그러면 결론은 *"기다리면 되지만 비교 측정에는 못 넣는다"* 가 되고, 표 문구를
`측정 불가` 에서 `너무 느려 제외` 로 바꾸는 게 정확해져요.

그래서 **스크립트가 그 조합에서 alacritty 를 아예 띄우지 않고** 표에 `측정 불가` 로 적어요.
30 초씩 기다렸다 버리는 것보다 낫고, 그 사실이 표에 남아요. 다른 platform · 다른 워크로드는
영향 없어요.

**특정 터미널을 제외하려면 PATH 에서 빼요.** 스크립트가 `command -v` 로 대상을 고르므로 이게 가장
깔끔해요 (플래그는 없어요).

```sh
FP=$(echo "$PATH" | tr ':' '\n' | grep -vi 'alacritty' | paste -sd: -)
PATH="$FP" dist/stress/compare-terminals.sh --mb 64 --workload zwj --repeat 3 --timeout 30
```

⚠️ **wezterm 은 제외하지 마세요 — 정상 동작해요.** 위 멈춤은 **alacritty 에서만** 확인됐어요.
처음에 둘을 한 묶음으로 빼서 wezterm 값을 통째로 잃은 적이 있어요 ([#381](https://github.com/ensky0/tildaz/issues/381)) —
그리고 그 값이 중요했어요. grapheme 워크로드에서 **wezterm 이 우리보다 2.7~2.9 배 빨라서**, 빼 버리면
"우리가 꼴찌" 라는 사실이 표에서 사라져요.

#### alacritty 는 큰 출력을 끝낸 뒤 스스로 안 닫혀요 (상한을 두고 정리)

위 `zwj` 절과 **다른 증상이에요.** 저건 출력 *도중* 진행이 막히는 것이고, 이건 **출력이 다 끝나고
producer 가 정상 종료한 뒤** `alacritty.exe` 만 남는 거예요. 그래서 워크로드를 안 가려요 — `plain`
에서 났어요 ([#414](https://github.com/ensky0/tildaz/issues/414), alacritty 0.17.0 (94e7c88) ·
노트북 AMD Ryzen AI 7 350 · Windows 11 Pro 26200).

**우리 스크립트 없이도 나요.** `alacritty -e <producer>` 만으로 재현돼요.

| 출력량 | 결과 | | 출력량 | 결과 |
|---|---|---|---|---|
| 1 MiB | 3/3 스스로 종료 | | **16 MiB** | **2/3 멈춤** |
| 8 MiB | 3/3 스스로 종료 | | **32 MiB** | **3/3 멈춤** |
| | | | **64 MiB** | **3/3 멈춤** |

**영구 멈춤이에요.** 64 MiB 를 180 초 기다려도 안 닫히고, 그동안 **CPU 시간이 늘지 않아요**
(5.6 초에서 고정 · `Responding=True` · 자식 프로세스 없음) — 오래 걸리는 일을 하는 중이 아니라
멈춘 거예요. producer 쪽은 매번 멀쩡해요 (timing 파일이 완전하고 프로세스가 안 남아요).

**측정값은 유효해요.** 멈춤이 측정과 캡처가 **모두 끝난 뒤**에 일어나고, 값은 producer 가 쓴
timing 파일에서 나와요. 그래서 `zwj` 처럼 대상에서 빼지 않아요.

**스크립트는 그 시도의 hold 만큼만 기다리고 정리해요.** 기다림의 목적이 *producer 의 hold 가 끝나는
것* 하나뿐이라 상한도 거기에 맞춘 거예요 — 재시도 회차는 hold 가 `CAPTURE_RETRY_HOLD_MS` 로
늘어나므로 상한도 같이 늘어나요. 상한에 걸리면 표에 이렇게 남아요.

```
alacritty      @ ok  120x40
               ⚠ alacritty — producer 가 끝난 뒤에도 안 닫혀서 1 회차를 강제로 정리했어요 (측정값은 유효해요).
```

**`--capture` 를 끄면 이 경로를 아예 안 타요** — 기다림 자체가 캡처 전용이고, 캡처가 없으면 곧바로
정리해요. 기록용 실행 (`--capture` 없이 `--repeat 5`) 은 처음부터 영향이 없었어요.

**wezterm 은 `wezterm-gui start --always-new-process` 로 띄워요** (Windows). 두 가지를 함께
해결해요.

- `wezterm start` 는 기본이 *이미 떠 있는 GUI 인스턴스에게 요청* 이에요 ([`wezterm start`](https://wezterm.org/cli/start.html)).
  붙어 버리면 사용자가 열어 둔 창과 **같은 프로세스**를 쓰게 되고, 반복 측정에서 wezterm 만
  **워밍업된 프로세스**로 재게 돼요 — 다른 넷은 매 회차 새 프로세스예요. `--config` 오버라이드도
  기존 인스턴스에는 안 먹을 수 있어요.
- `wezterm.exe` 는 콘솔용 런처라 GUI 를 **손자 프로세스**로 띄워요. `wezterm-gui` 를 직접 부르면
  Git Bash 의 직접 자식이 되어 위 표의 foreground 권한 조건을 맞출 수 있어요.

macOS · Linux 는 `wezterm` 을 그대로 쓰되 `--always-new-process` 는 똑같이 줘요 — 프로세스
재사용 문제는 platform 을 안 가려요 (macOS 에도 [같은 증상의 이슈](https://github.com/wezterm/wezterm/issues/5098)가 있어요).

**출력을 `| tail` 로 파이프하지 마세요** — 스크립트가 끝날 때까지 버퍼링돼서 진행이 하나도 안 보여요.
파일로 받고 (`> out.txt 2>&1`) 그 파일을 읽어요.

### scrollback 은 `--scrollback` 으로 모든 대상에 같은 값을 줘요 (기본 32,767)

**맞추지 않으면 우리가 불리해요.** 우리 config 기본값은 100,000 인데 그 몫이 작지 않아요
(파서 층 · 같은 배치 · 5 회 절사평균, [#381](https://github.com/ensky0/tildaz/issues/381#issuecomment-5198052304)):

| 워크로드 | scrollback 100,000 | 9,000 | 변화 |
|---|---:|---:|---:|
| `plain` | 294.6 MiB/s | **427.8** | **+45.2 %** |
| `hangul` | 117.8 | 123.5 | +4.9 % |

`plain` 은 초당 5.7 M 줄이라 **page 관리 비용이 지배**하고 (100,000 줄 = 작업 집합 ~120 MB → 캐시를
밀어내요), 줄당 파싱 비용이 큰 `hangul` 은 그 몫이 묻혀요.

> `hangul` 의 두 절대값은 **항목 35 개 (줄 116 byte) 시절**이에요 — 지금은 13 개 (50 byte) 라 줄
> 수가 달라서 MiB/s 를 직접 비교할 수 없어요. 여기서 읽을 것은 *변화율*이고 그건 그대로 유효해요.

**기본값이 32,767 인 이유**는 그게 **wt `historySize` 의 최대값**이라서예요
([Microsoft Learn](https://learn.microsoft.com/en-us/windows/terminal/customize-settings/profile-advanced) ·
기본값 9,001). 맞출 수 있는 최댓값이 그 값이에요.

| 대상 | 지정 방법 |
|---|---|
| TildaZ | `-scrollback N` — **config 를 건드리지 않아요** (측정용 내부 옵션, `run_options.zig`). 로그에 `scrollback override: N lines (config M)` 이 찍혀요 |
| alacritty | `-o scrolling.history=N` |
| wezterm | `--config scrollback_lines=N` |
| kitty | `-o scrollback_lines=N` |
| ghostty | 임시 config 의 `scrollback-limit = N` |
| **wt** | **CLI 로 못 줘요** — profile 설정이에요. 스크립트가 **JSON fragment** 로 측정용 프로필을 더해서 거기에 담아요 (아래) |
| **conhost** | **불가** — `mode con: lines` 가 창=버퍼예요. **이 대상만 조건이 달라요** (스크립트가 매 실행에 경고해요) |
| **Terminal.app** | **불가** — AppleScript 에 크기 속성이 없어요 (`history` 는 내용 읽기 전용). **사용자 프로파일 값이 쓰여요** — conhost 와 달리 머신마다 값이 달라서 재현성도 떨어져요 (스크립트가 매 실행에 경고해요) |

**wt 는 JSON fragment 로 프로필을 더해요 — 사용자 `settings.json` 을 교체하지 않아요.**

[JSON fragment extension](https://learn.microsoft.com/en-us/windows/terminal/json-fragment-extensions)
은 iTerm2 의 Dynamic Profiles 와 같은 자리예요. 아래 경로에 파일을 두면 wt 가 읽어서 프로필로
더하고, 우리는 **우리가 만든 디렉터리 하나만 지우면** 돼요.

```
%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\tildaz-compare\measure.json
wt -w new --size <C,R> -p tildaz-compare <producer>
```

사용자의 키바인딩·테마·프로필이 **그대로 유지**돼요. 측정 중 사용자 wt 창의 설정이 눈에 보이게
달라지던 것도 없어졌어요.

> **예전에는 `settings.json` 을 통째로 갈아끼우고 `trap` 으로 복원했어요.** 그 구조에서는 crash 로
> 죽으면 사용자 설정이 임시본인 채 남아서, 백업을 설정 파일 옆에 두고 **다음 실행이 복원하는**
> 안전장치까지 필요했어요. 덮어쓰지 않으면 지킬 게 없어서 그 세 겹이 통째로 사라졌어요
> ([#381](https://github.com/ensky0/tildaz/issues/381)).

⚠️ **`--size` 는 `-p` 보다 앞에 와야 해요.** 뒤에 두면 파서가 서브커맨드 모드로 들어가서
`The following argument was not expected: --size` 로 죽어요 (실측). wezterm 의 `--config` 가
`start` 앞에 와야 하는 것과 같은 종류예요.

⚠️ **fragment 파일은 UTF-8 이어야 해요.** PowerShell 로 만들면 기본이 UTF-16LE 라 wt 가 못 읽어요
(공식 문서 경고). 셸 heredoc 은 문제없어요.

**fragment 를 지워도 사용자 파일에 참조 스텁이 남아요** — wt 가 fragment·dynamic 프로필을 발견하면
`{guid, name, source}` 를 자기 파일에 적고 (WSL·Azure 프로필이 목록에 있는 것과 같은 방식) **종료할
때** 써요. `hidden: true` 여도 남고, fragment 를 지운 뒤 다시 띄워도 정리되지 않아요. 그래서
스크립트가 `trap` 에서 그 블록만 들어내요 — **JSON 파싱은 안 해요** (wt 설정은 주석을 허용하는
JSONC 라 파서 왕복이 사용자 주석을 날려요). 실측으로 **원본과 해시까지 같게** 복구돼요.

**conhost 를 함께 재는 이유**는 두 가지예요. 하나는 legacy GDI 렌더러라 **하한 기준선**이라서고,
다른 하나는 **ConPTY 오버헤드를 가늠할 단서**라서예요 — Windows Terminal · alacritty · TildaZ 는
모두 ConPTY 를 쓰고 그 안에 headless conhost 가 있어요. 같은 producer 를 conhost 에 직접 돌린
값과 비교하면 그 몫이 보여요 ([#371](https://github.com/ensky0/tildaz/issues/371) 의 `cjk`
초과분 +25.6 % 가 그 후보예요).
