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

# 프레임에 묶인 드레인 — 프레임마다 예산이 걸린다 (앱의 하한, 아래 주의 참고)
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
| 표본이 3 개 미만이면 | 절사하지 않고 단순 평균으로 떨어져요. 스크립트가 **그 사실을 표 위에 적어요** — 조용히 다른 통계로 바꾸지 않아요 |

### 측정 위생

앞의 셋은 실제로 겪어서 값을 버린 원인이에요.

| 규칙 | 왜 |
|---|---|
| 측정 중 창을 클릭하거나 포커스를 바꾸지 않아요 | 실측 중 키보드 · 마우스가 눌려 그 회차를 버렸어요 |
| 이전 실행의 잔여 터미널 프로세스를 먼저 정리해요 | `kitty --detach` 와 ghostty 는 스크립트가 끝나도 남아서 다음 회차와 CPU 를 나눠요 |
| **평소 쓰는 TildaZ worker 를 종료해요** — **이제 스크립트가 자동으로 해요** | 다른 터미널은 백그라운드 인스턴스가 없는데 TildaZ 만 worker 가 떠 있으면 렌더 · CPU 를 나눠 써요. 공정성 문제예요. 규칙으로만 적어 뒀더니 실제로 잊고 여러 회차를 돌린 적이 있어서 ([#381](https://github.com/ensky0/tildaz/issues/381)) `compare-terminals.sh` 가 시작할 때 직접 내려요. **끝나도 다시 안 띄워요** — 필요하면 직접 띄우세요 |
| AC 전원에 연결하고 절전 · **화면 잠금을 꺼요** | 노트북은 배터리 · 열로 스로틀링이 걸려요. 그리고 잠금 화면이 뜨면 **`render` 만 무너지고 `parse` 는 정상이라 결과만 봐서는 티가 안 나요** — 아래 참고 |
| **화면을 계속 다시 그리는 앱 (브라우저 · 에디터 · 채팅) 을 최소화하거나 닫아요** | **우리 수치만 64 % 흔들려요** — 아래 참고 |
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

##### 회차 유효성은 이 둘로 판정해요

perf 스냅숏에 답이 있어요 (측정 인스턴스는 종료할 때 자동으로 남겨요 — `Ctrl+Shift+F12` 를 누를
필요 없어요).

| 지표 | 정상 (4 회차) | **오염 (5 회차)** |
|---|---|---|
| `skip / onrender` | 26/75 = 35 % | **71/73 = 97 %** |
| `present calls` | 49 | **2** |

`onrender` 의 `skip` 은 paint 하지 못한 frame tick 수예요. 이게 대부분이면 **그리지 않은 회차**라
`render` 값에 의미가 없어요. 회차 사이에 `render calls` 가 한 자릿수로 떨어지는 것도 같은 신호예요.

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

### 돌리는 환경 — **Windows 는 Git Bash · Linux 는 KDE Plasma**

`compare-terminals.sh` 는 platform 을 안 가리는 POSIX `sh` 스크립트지만, **셸과 데스크톱은
가려요**. 잘못된 데서 시작하면 아예 안 돌거나 캡처만 조용히 비어요.

| platform | 어디서 | 왜 |
|---|---|---|
| **Windows** | **Git Bash** (필수) | PowerShell 로는 **아예 안 돌아요** — `uname -s` 의 `MINGW*`/`MSYS*`/`CYGWIN*` 로 platform 을 판별하고, 자식이 Windows 실행파일이라 `cygpath -w` 로 경로를 변환해요. Git for Windows 에 항상 들어 있으니 따로 설치할 게 없어요. 아래 [Windows 에서 돌리기](#windows-에서-돌리기) 참고 |
| **Linux** | **KDE Plasma** (권장) | 스크립트 본체는 어느 DE 에서도 돌아요. 갈리는 건 **`--capture` 뿐**이에요 — KDE 만 창 단위로 확실히 잡혀요 (아래 표) |
| **macOS** | 아무 터미널 | 갈리는 게 없어요 |

**`--capture` 를 안 쓰면 Linux 는 DE 를 안 가려요.** 캡처가 필요할 때만 아래가 걸려요.

| Linux DE | 캡처 | |
|---|---|---|
| **KDE Plasma** | `spectacle -b -n -a` | ✅ **창 단위**. 실기 검증된 유일한 DE ([#381](https://github.com/ensky0/tildaz/issues/381), AMD Ryzen AI 7 350 · KDE Plasma Wayland) |
| sway · Hyprland | `grim` | ⚠️ 돼요. 전체 화면이라 **가려진 창은 못 찍어요** (타일링이라 보통 안 가려지긴 해요) |
| GNOME 43+ | — | ❌ `gnome-screenshot` 이 제거돼서 **경로가 없어요** |

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

**대상은 그 platform 에 설치된 것만 자동으로 골라요** (`command -v` 로 확인해요).

| platform | 자동으로 도는 대상 |
|---|---|
| Linux | TildaZ · alacritty · kitty · wezterm · ghostty · foot |
| macOS | TildaZ · alacritty · kitty · wezterm · ghostty |
| Windows | TildaZ · alacritty · wezterm · Windows Terminal (`wt`) |

Windows 에 kitty · ghostty 판이 없고 foot 은 Wayland 전용이라, Windows 는 그 자리를
Windows Terminal 이 채워요.

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
진행 표시가 `.` 대신 아래 넷으로 바뀌어요.

| 표시 | 뜻 |
|---|---|
| **`@`** | 대상 창을 **창 단위**로 찍었어요 (가장 좋은 결과) |
| **`~`** | 창은 찾았지만 창 단위가 안 돼서 **전체 화면**으로 물러섰어요 |
| **`?`** | 창을 **아예 못 찾았어요** — PNG 에 대상이 있어도 우연이에요 |
| **`!`** | PNG 자체가 안 생겼어요 |

이 구분이 없던 때 **창을 한 번도 못 잡던 conhost 가 계속 `@` 로 성공처럼 보였어요**
([#381](https://github.com/ensky0/tildaz/issues/381)).

**파일명이 워크로드로 시작해요.** 워크로드를 바꿔 가며 같은 디렉터리에 여러 번 찍는 게 정상
사용법인데 (`zwj` 한 번, `cjk` 한 번), 이름에 워크로드가 없으면 **뒤 실행이 앞 실행을 덮어써서**
비교할 수가 없어요. 이름순 정렬도 워크로드끼리 묶여요. 세 platform 공통이에요.

⚠️ **`@` 는 파일이 생겼다는 뜻이지 창이 찍혔다는 보장이 아니에요.** 전체 화면으로 물러선
경우 (macOS 에서 창을 못 찾음 · 리눅스 전체) 대상이 다른 창 뒤에 있으면 안 보여요. **PNG 을
눈으로 확인해 주세요.** 실제로 그렇게 한 장을 놓친 적이 있어요 (아래 "찍기 전에 기다려요").

⚠️ **이 옵션을 켠 실행의 숫자는 기록용으로 쓰지 마세요.** 캡처 도구가 측정 직후에 CPU 를 쓰고,
producer 가 창을 **4 초** 더 붙들고 있어요 (그래야 찍을 창이 남아요 — `TILDAZ_STRESS_HOLD_MS`).
**smoke 확인용**이에요. 기록용은 이 옵션 없이 `--repeat 5` 로 내요.

| platform | 쓰는 도구 | 범위 | 알아 둘 것 |
|---|---|---|---|
| **macOS** | [`dist/macos/color-capture.m`](../macos/color-capture.m) (ScreenCaptureKit) | **창 단위** | **완전히 가려진 창도 찍혀요** (실측: 같은 자리에 창 둘을 겹치고 아래 창을 찍으니 아래 창 내용이 나왔어요). 스크립트가 `clang` 으로 빌드해서 써요. **화면 기록 권한**이 필요하고 잠금 화면이면 실패해요. 창을 못 찾으면 `screencapture -x` 전체 화면으로 물러서요 |
| **Windows** | PowerShell (`PrintWindow` → 실패 시 ffmpeg `ddagrab` → 실패 시 `CopyFromScreen`) | **창 단위** | 창을 띄우자마자 **(0,0) 으로 옮기고 맨 앞으로** 올려요 (`SWP_NOACTIVATE` 라 포커스는 안 뺏어요). **창 단위 경로가 둘인 이유는 `PrintWindow` 의 성패가 환경마다 갈리기 때문**이에요 (아래 참고). ffmpeg 은 선택이고 없으면 첫 경로만 써요. **DPI 함정도 있어요 — 아래 참고** |
| **Linux (sway · Hyprland)** | `grim` | 전체 화면 | wlroots 계열의 `zwlr_screencopy` 를 써요. **가려진 창은 못 찍어요** — Wayland 는 client 가 다른 창 내용을 읽을 수 없어요. 타일링이라 보통 안 가려져요 |
| **Linux (KDE Plasma)** | `spectacle -b -n -a` | **활성 창** | KWin 은 `zwlr_screencopy` 를 client 에게 노출하지 않아 grim 이 안 돼요. `org.kde.KWin.ScreenShot2` 는 호출자를 검증해서 직접 부를 수 없고, **Spectacle 이 정상 통로**예요 (KDE 기본 설치). `-a` 라 **창 단위로 찍히고 가려짐 문제도 없어요** (활성 창은 맨 앞이니까요). 다만 방금 뜬 창이 활성이 아니면 엉뚱한 창이 찍혀요 — 확실히 하려면 KWin 스크립팅으로 대상을 활성화해야 하는데, 필요한지 확인되기 전엔 안 넣었어요 |
| **Linux (GNOME)** | `gnome-screenshot` | 전체 화면 | GNOME 43 에서 빠졌어요. 없으면 캡처를 못 해요 |

리눅스에 **하나로 다 되는 방법은 없어요** — Wayland 는 client 가 화면을 읽을 수 없고 통로가
compositor 마다 달라요. 위 순서대로 시도하고, 하나도 없으면 시작할 때 그 사실을 알려요.
`xdg-desktop-portal` 은 표준이지만 **권한 대화상자가 떠서** 손 안 대고 도는 측정과 안 맞아요.

#### 찍기 전에 2 초 기다려요

**timing 파일이 생긴 시점은 측정이 끝난 시점이지 창이 화면에 올라온 시점이 아니에요.** wezterm 은
GUI 시작이 제일 느려서, 8 MiB 측정 (111 ms) 이 창보다 먼저 끝난 회차가 있었어요 — 그 회차 PNG 에는
**wezterm 창이 아예 없었어요** (macOS 실측). 그래서 timing 을 본 뒤 2 초 기다렸다 찍어요.

`TILDAZ_STRESS_HOLD_MS` 4 초는 이 2 초에 캡처 시간을 더한 값이에요. **캡처 자체는 macOS 0.3 초 ·
Windows 0.73 초**예요 (둘 다 실측 — Windows 는 `powershell` 프로세스 시작과 `Add-Type` 의 C#
컴파일까지 포함한 값이에요). `PrintWindow` 가 실패해 **`ddagrab` 까지 가는 회차는 1.18 초**고
(실측 · Intel i5-1240P), 그래도 2 초 예산 안이에요.

#### Windows 는 창 단위 경로가 둘이에요 — `PrintWindow` 가 환경을 타요

**`PrintWindow` 의 성패는 앱이 아니라 환경이 정해요.** 같은 앱이 머신에 따라 뒤집혀요
([#381](https://github.com/ensky0/tildaz/issues/381) 실측, 같은 워크로드 · 같은 격자):

| 대상 | 노트북 AMD Ryzen AI 7 350 · 2880×1800 · 200 % | 노트북 Intel i5-1240P · 1920×1080 · 100 % |
|---|---|---|
| wezterm · tildaz | **실패** — 전체 화면으로 물러서도 PNG 에 창이 없었어요 | **성공** |
| conhost | **창조차 못 잡음** | **성공** |
| alacritty | 성공 | **실패** (회차마다 갈려요) |
| wt | 성공 | 성공 |

그래서 예전에 적어 둔 *"GDI 두 경로가 DWM redirection surface 를 읽는데 flip-model swapchain
창은 그 표면에 안 들어간다"* 는 설명은 **반증됐어요.** 그게 원인이라면 Intel 머신에서도
tildaz · wezterm 이 실패해야 하는데 둘 다 창 단위로 깨끗이 찍혀요. **무엇이 두 환경을 가르는지는
아직 몰라요** — GPU 드라이버 · 배율 · HDR 이 후보예요. (더 앞선 가설이던 *"최대화된 창이 화면을
덮어 direct flip 이 걸려서"* 는 최대화를 푼 뒤에도 재현되어 이미 기각됐어요.)

**그래서 두 번째 창 단위 경로를 뒀어요** — ffmpeg 의 `ddagrab` (Desktop Duplication API) 으로
**창 rect 만 잘라** 찍어요. `ddagrab` 은 DWM 이 합성한 화면을 읽어서 GDI 와 통로가 달라요.

```sh
winget install Gyan.FFmpeg     # 선택이에요. 없으면 PrintWindow 만 써요
```

- **PATH 에 없어도 찾아요** — 방금 깐 경우 이미 떠 있는 셸에는 PATH 가 반영되지 않아서,
  winget 의 shim 디렉터리 (`%LOCALAPPDATA%\Microsoft\WinGet\Links`) 도 함께 봐요.
- **`@` 로 같이 표시돼요** — 창 단위라는 결과가 같아서예요. 어느 경로였는지는 표 아래 요약이
  회차 수로 알려 줘요 (`ℹ N 회차는 PrintWindow 가 안 돼 ddagrab …`).
- **주 모니터에 있는 창만** 잘라요. `output_idx=0` 은 첫 DXGI 출력이라, 다른 모니터의 창을
  자르면 엉뚱한 자리를 찍고도 성공으로 보여요. 창 원점이 주 모니터 밖이면 이 경로를 건너뛰어요.
- **가려진 창은 못 찍어요** (화면을 읽는 방식이라서요). 찍기 직전에 창을 맨 앞으로 올려서 피해요.
- **HDR 화면은 미검증**이에요. 기본 8 bit 요청이 안 먹으면 `output_fmt=10bit` + `format=x2bgr10`
  이 다음 후보고, 그래도 안 되면 전체 화면으로 물러서요.
- **AMD 머신에서 이게 실제로 고쳐 주는지는 아직 확인 못 했어요** — 검증은 Intel 머신에서만
  했어요 (alacritty 를 강제로 `PrintWindow` 실패시켜 `ddagrab` 경로로 찍히는 것까지 확인).

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
하다가 **write 에서 막힌** 거예요. 창에 입력 이벤트를 주면 조금 진행하고 다시 막혀요 — alacritty 가
back-pressure 상황에서 ConPTY 출력을 그만 소비하는 것으로 보여요. 포커스는 변수가 아니에요
(포커스를 준 상태에서도 엔터 사이마다 다시 멈췄어요).

> 이전 판 문서에 있던 *"`main` 진입 전에 멈춘다 · CPU 시간 0"* 은 **틀렸어요** — 위 실측으로 반증됐어요.

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
| **wt** | **CLI 로 못 줘요** — profile 설정이라 `settings.json` 뿐이에요. 스크립트가 아래 절차로 처리해요 |
| **conhost** | **불가** — `mode con: lines` 가 창=버퍼예요. **이 대상만 조건이 달라요** (스크립트가 매 실행에 경고해요) |

**wt 는 스크립트가 설정 파일을 잠시 교체해요.**

1. 원본을 `<settings>.tildaz-compare-backup` 으로 **백업**
2. 측정 전용 **최소 설정**으로 교체 (`historySize` = `--scrollback`, 프로필 하나)
3. 끝나면 (`trap EXIT`) 백업에서 **복원**하고 백업 파일 삭제

**crash 로 죽어도 복원돼요** — 백업이 남아 있으면 다음 실행이 시작할 때 먼저 복원해요 (그래서 백업을
`WORK_DIR` 이 아니라 설정 파일 옆에 둬요). 최소 설정을 쓰는 이유는 사용자 파일을 JSON 파싱하지 않아도
되고 (주석이 섞여 있을 수 있어요) 폰트·acrylic·스킴 같은 커스터마이즈가 측정에 안 섞이기 때문이에요.

**이 백업·복원은 "실행 1 회당 1 벌" 이 의도예요 — 걷어내지 마세요.** 여러 워크로드를 셸 루프로 돌리면
그만큼 반복되는데 (6 워크로드 = 백업·복원 6 회) 그게 낭비처럼 보여도 **그 반복이 안전성이에요**: 어떤
실행이 어떻게 죽어도 그 실행이 자기 뒤를 치워요. 백업·복원을 루프 바깥으로 빼면 "중간에 죽으면 사용자
설정이 패치된 채 남는" 창이 생겨요. 비용은 6 분 측정에 약 6 초 (1.7 %) 예요.

반복이 정말 걸리면 방향은 **`--workload a,b,c` 를 받게 하는 것**이에요 (1 회 호출 → 백업 1 회). 다만
터미널 실행부와 리포트를 워크로드 루프 안으로 들어내는 리팩터라, 안전장치를 없애는 것과는 다른 작업이에요.

⚠️ **wt 창이 열려 있으면 그 창의 설정도 잠시 바뀌어요** (wt 가 파일 변경을 감시해 재적용해요).
측정이 끝나면 복원되지만 눈에 보여요.

**conhost 를 함께 재는 이유**는 두 가지예요. 하나는 legacy GDI 렌더러라 **하한 기준선**이라서고,
다른 하나는 **ConPTY 오버헤드를 가늠할 단서**라서예요 — Windows Terminal · alacritty · TildaZ 는
모두 ConPTY 를 쓰고 그 안에 headless conhost 가 있어요. 같은 producer 를 conhost 에 직접 돌린
값과 비교하면 그 몫이 보여요 ([#371](https://github.com/ensky0/tildaz/issues/371) 의 `cjk`
초과분 +25.6 % 가 그 후보예요).
