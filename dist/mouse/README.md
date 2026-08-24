# mouse reporting 검증 절차

TUI 앱에게 마우스를 전달하는 경로 ([#502](https://github.com/ensky0/tildaz/issues/502),
사양은 [`SPEC.md`](../../SPEC.md) §3) 를 실기로 확인하는 절차예요. 세 platform 에서
같은 시나리오를 돌리고, platform 고유 경로만 따로 봐요.

[`mouse-probe.sh`](mouse-probe.sh) 는 터미널이 앱에게 **실제로 보낸 바이트를 화면에
그대로** 찍어요. "클릭이 먹네" 를 보는 것과 달리 `Cb` 값 · 좌표 · 뗌의 대소문자까지
판정할 수 있어서, 회귀가 났을 때 어느 규칙이 깨졌는지 바로 짚여요.

## 준비

```sh
git fetch origin && git checkout <브랜치>
```

**항상 `--instance 1` 로 띄워요** — daily 인스턴스 (`--instance 0`) 를 안 건드려요.
핫키 충돌 다이얼로그가 뜨면 **`Cancel`** 이에요 (daily 가 핫키를 지켜야 해요). 테스트
인스턴스는 전역 핫키가 없으니 창을 숨기지 말아요.

| platform | 빌드 | 실행 |
|---|---|---|
| Linux | `zig build -Doptimize=ReleaseFast -Dsimd=true` | `./zig-out/bin/tildaz --instance 1 -size 88x33 &` |
| macOS | `dist/macos/build_and_install.sh` (서명 필수) | `/Applications/TildaZ.app/Contents/MacOS/tildaz --instance 1 -size 88x33 &` |
| Windows | `zig build -Doptimize=ReleaseFast -Dsimd=true --cache-dir C:/ziglang/tildaz-cache` | `.\zig-out\bin\tildaz.exe --instance 1 -size 88x33` |

macOS 는 마우스 검증에 권한이 필요 없어서 (Input Monitoring 은 전역 핫키용) 번들 안
바이너리를 직접 띄워도 돼요.

## 프로브 실행

```sh
sh dist/mouse/mouse-probe.sh              # ?1002 + ?1006 — 기본
sh dist/mouse/mouse-probe.sh 1003         # hover (버튼 없는 이동) 까지
sh dist/mouse/mouse-probe.sh 1000         # motion 없음 — 누름/뗌만
sh dist/mouse/mouse-probe.sh 9 1006       # x10 — 누름만, modifier 없음, 좌표 223 상한
```

**Windows 는 PowerShell 이 아니라 Git Bash** 로 돌려요 (POSIX sh). TildaZ 의
PowerShell 탭에서 `bash dist/mouse/mouse-probe.sh` 로 실행해도 돼요.

종료는 **`q` 또는 `Ctrl+C`** — 프로브가 mode 를 끄고 나가요. `q` 는 마우스 보고에
나오지 않는 글자라 종료 키로 안전해요. (`exit` 를 치면 셸이 닫혀 앱까지 같이 닫혀요.)

**탭바 hover 를 확인하려면 먼저 `Ctrl+Shift+T` 로 탭을 2개 이상 만들어요** — 탭바는
탭 2개부터 그려져요 (단일 탭에서는 그 영역이 없어서 판정할 수 없어요).

## A. 공통 시나리오 (세 platform)

| # | 동작 | 기대 |
|---|---|---|
| A1 | 셀 영역 왼쪽 클릭 | `^[[<0;C;R M` 과 `^[[<0;C;R m` — **뗌이 소문자 `m`** |
| A2 | 누른 채 천천히 드래그 | `^[[<32;C;R M` 이 **칸이 바뀔 때만**. 같은 칸에서 꿈틀거려도 안 나옴 |
| A3 | Ctrl+클릭 | `Cb` = 16 (Alt 8 · Shift 4) |
| A4 | 휠 위 / 아래 | 64 / 65 |
| A5 | 가운데 버튼 클릭 | `Cb` = 1, 뗌도 1. **탭이 생기거나 닫히면 버그** |
| A6 | Shift+드래그 | **출력 0건** + 선택 표시 + 놓으면 자동 복사 |
| A7 | 우클릭 | **출력 0건** + 클립보드 paste |
| A8 | 우클릭한 채 드래그 | **출력 0건** — 오른쪽은 motion 도 안 보낸다 |
| A9 | 가운데 누른 채 드래그 | `Cb` = 33 (1 + 32) |

`1003` 으로 다시 띄우면 **버튼 없이 움직이기만** 해도 `Cb` 35 (3 + 32) 가 나와야 해요.
**탭바 위에서 움직일 때는 안 나와야** 정상이에요 — viewport 밖이라 인코더가 걸러요
(탭 2개 이상 필요).
`1000` 이면 드래그해도 motion 이 안 나오고, `9` 면 누름만 나오고 modifier 가 안 실려요.

## B. macOS 고유

| # | 동작 | 기대 | 왜 |
|---|---|---|---|
| M1 | 우클릭한 채 드래그 | 출력 0건 | macOS 는 `rightMouseDragged:` 미등록이라 그 경로가 없다는 판정을 실측으로 확인 |
| M2 | 가운데 버튼 클릭 · 드래그 | `Cb` 1 / 33 | `otherMouseDown:`/`otherMouseUp:` 경로. **트랙패드엔 가운데 버튼이 없어 실물 마우스 필요** |
| M3 | Cmd+클릭 | `Cb` = 0 | Cmd 는 프로토콜에 자리가 없어 싣지 않는다. 4·8·16 이 붙으면 버그 |
| M4 | 트랙패드 두 손가락 스크롤 | 64/65 가 과도하게 쏟아지지 않음 | 연속 delta 를 notch 로 환산 (multiplier 2). 한 번 훑을 때 수십 줄이면 조정 필요 |

## C. Windows 고유

| # | 동작 | 기대 | 왜 |
|---|---|---|---|
| W1 | 휠을 화면 여러 위치에서 | `Cb 64` 의 `COL;ROW` 가 포인터 위치와 일치 | `WM_MOUSEWHEEL` 의 `lParam` 은 **screen 좌표**라 `ScreenToClient` 변환이 필요. 빠지면 엉뚱한 큰 수가 나온다 |
| W2 | 가운데 버튼 클릭 · 드래그 | `Cb` 1 / 33 | `WM_MBUTTONDOWN`/`UP` 경로 |
| W3 | Alt+클릭 | `Cb` = 8 | Alt 는 `wParam` 에 없어 `GetKeyState(VK_MENU)` 로 읽는다 |
| W4 | 우클릭한 채 드래그 | 출력 0건 | Linux 와 같은 경로 (`heldButton`) 라 함께 확인 |

## D. 실제 앱

프로브가 통과하면 실사용도 확인해요.

```sh
btop                       # 행 클릭 / 메뉴 클릭 / 휠 — 마우스 기본 on
vim <파일>                 # :set mouse=a → 클릭으로 커서 이동, 드래그 visual, 휠
less <파일>                # 휠 스크롤 = ?1007 alternate scroll (앱이 tracking 을 안 켠 경우)
less --mouse <파일>        # 휠 = 보고 경로. 둘 다 되면 두 경로가 정상
```

Windows 는 Git Bash 안의 `vim` · `less` 를 쓰면 돼요 (Git for Windows 에 들어 있어요).

## E. 회귀 — 가장 중요

프로브·앱을 다 끄고 **평소 셸 프롬프트**에서 봐요. reporting 이 꺼진 상태라 지금까지의
동작이 **하나도 바뀌지 않아야** 해요.

| 확인 | 기대 |
|---|---|
| 텍스트 드래그 | Shift 없이도 선택 + 놓으면 자동 복사 |
| 우클릭 | paste |
| 더블클릭 | 단어 선택 + 복사 |
| 우측 스크롤바 드래그 | 스크롤 |
| 탭바 — 탭 클릭 / `+` / `×` / `…` | 정상 |
| 가운데 클릭 | **아무 일도 없어야** 정상 |
| 휠 | 스크롤백 스크롤 |

## 결과 기록

**어느 머신인지 함께 적어요** (`AGENTS.md` 의 실행 환경 규칙 — 실기 결과는 머신을 같이
기록해요).

```
[머신] MacBook Pro (M5 Pro) / macOS 26.x
A1~A9: 전부 OK        (실패 시 "A8 에서 ^[[<34;29;12M 나옴" 처럼 바이트 그대로)
M1~M4: 전부 OK
D 실제 앱: btop OK / vim OK / less OK
E 회귀: 전부 OK
```

실패는 **무엇을 했을 때 무엇이 나왔는지** 를 그대로 남겨요. `Cb` 값만 있어도 어느
규칙이 깨졌는지 좁혀져요 (버튼 비트 · modifier 비트 · motion 비트가 분리돼 있어요).
