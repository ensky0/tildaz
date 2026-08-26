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

**핫키를 손으로 바꿀 필요는 없어요.** [#510](https://github.com/ensky0/tildaz/issues/510)
이후 `config_1.toml` 은 자기 index 에서 파생한 `F2` 로 생성돼요 (daily 는 `F1`). 그래서
그냥 띄우면 돼요 — 예전 판이 안내하던 "`config_1` 의 `hotkey` 를 `ctrl+alt+f9` 로 바꾼
뒤 다시 띄워요" 우회는 더 필요 없어요.

`F2` 를 이미 다른 앱이 쥐고 있는 기계라면 그때만 `config_1.toml` 의 `hotkey` 를 비어
있는 조합으로 바꿔요. 세 platform 모두 전역 핫키를 못 잡으면 안내창을 띄우고 **종료**
해요 (#510) — 어느 platform 에서든 조용히 넘어가지 않아요.

**검증이 끝나면 `config_1.toml` 을 지워요** — 남겨 두면 사용자가 평소 TildaZ 를 띄울 때
그 인스턴스가 같이 떠요.

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
sh dist/mouse/mouse-probe.sh --log /tmp/m.log   # 화면 + 파일 (자동 판정용)
```

**`--log <경로>` 는 받은 바이트를 파일에도 그대로 써요.** 화면 출력은 그대로예요.
화면에만 찍으면 **출력이 화면을 넘치는 순간 앞 항목이 사라져요** — [#502](https://github.com/ensky0/tildaz/issues/502)
macOS 실기에서 실제로 그랬어요 (휠 결함으로 한 번 훑기에 보고가 66~86 건 나와서 그 앞의
A1~A3 이 스크롤로 밀려 올라갔어요). 파일로 함께 받으면 사람 검증과 자동 판정이 같은
프로브를 써요. 쓰기는 `>>` 라 **매 글자가 버퍼링 없이 바로** 들어가요.

`-e` 로 띄울 때는 인자를 못 넘기니 (`run_options.zig` — argv 가 `{shell}` 고정) 한 줄
래퍼를 만들어 넘겨요.

```sh
printf '#!/usr/bin/env bash\nexec sh %s/dist/mouse/mouse-probe.sh 1002 1006 --log /tmp/m.log\n' "$PWD" > /tmp/wrap.sh
chmod +x /tmp/wrap.sh
open -n /Applications/TildaZ.app --args --instance 1 -e /tmp/wrap.sh -size 88x33   # macOS
```

**Windows 는 PowerShell 이 아니라 Git Bash** 로 돌려요 (POSIX sh). 두 가지를 주의해요.

- **`bash` 를 그냥 치면 Git Bash 가 아닐 수 있어요.** Git for Windows 는 PATH 에 `Git\cmd`
  만 넣고 `bash.exe` 는 `Git\bin` 에 있어서, PATH 의 `bash` 가 **WSL 스텁**
  (`%LocalAppData%\Microsoft\WindowsApps\bash.exe`) 으로 잡히는 경우가 많아요.
- **탭 셸의 cwd 는 레포 루트가 아니에요** (`%USERPROFILE%`) — 상대 경로가 안 맞아요.

둘 다 전체 경로로 피해요 (TildaZ 의 cmd · PowerShell 탭 어디서든).

```
"C:\Program Files\Git\bin\bash.exe" C:/Users/<you>/tildaz/dist/mouse/mouse-probe.sh
```

종료는 **`q` 또는 `Ctrl+C`** — 프로브가 mode 를 끄고 나가요. `q` 는 마우스 보고에
나오지 않는 글자라 종료 키로 안전해요. (`exit` 를 치면 셸이 닫혀 앱까지 같이 닫혀요.)

**탭바 hover 를 확인할 때만 `-size` 를 빼고 띄워요.** 탭바는 탭 2개부터 그려지니
`Ctrl+Shift+T` 로 탭을 하나 더 만들어야 하는데, `-size` 로 격자를 고정한 창에서 탭을
만들면 맨 아래 행이 창 밖으로 밀려요 ([#506](https://github.com/ensky0/tildaz/issues/506)
— 마우스와 무관한 검증 전용 경로의 제약이에요). `-size` 없이 띄우면 격자가 탭바 높이를
반영해 다시 계산되므로 문제가 없어요.

```sh
./zig-out/bin/tildaz --instance 1 &        # -size 없이 (탭바 테스트용)
```

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
| A10 | 왼쪽 / 가운데를 누른 채 **창 밖으로** 끌기 | 좌표가 가장자리에 clamp 된 채 `Cb` 32 / 33 이 **계속 나옴**, 창 밖에서 떼도 뗌이 옴 |

`1003` 으로 다시 띄우면 **버튼 없이 움직이기만** 해도 `Cb` 35 (3 + 32) 가 나와야 해요.
**탭바 위에서 움직일 때는 안 나와야** 정상이에요 — viewport 밖이라 인코더가 걸러요
(탭 2개 이상 필요 — 위의 `-size` 주의 참고).
`1000` 이면 드래그해도 motion 이 안 나오고, `9` 면 누름만 나오고 modifier 가 안 실려요.

**A10 이 왜 있나** — host 가 창 밖으로 나간 드래그의 이벤트를 계속 받아야 (Windows
`SetCapture` · macOS 는 자동 · Linux 는 Wayland implicit grab) 인코더의 "뗌은 어디서 놓든
항상 보고한다" 가 성립해요. 빠지면 motion 이 끊기고 **창 밖에서 뗀 뗌이 유실돼서 앱이 그
버튼을 영원히 눌린 것으로** 알아요. #502 Windows 실기에서 가운데 버튼이 그랬어요 (A9 는
드래그가 창 안에서 끝나 이 경로를 지나가지 않아요). 창 밖에서 뗄 때는 **커서 아래에 있는
창을 조심해요** — capture 가 안 걸린 상태라면 그 클릭이 그 창으로 가요 (가운데 클릭이
브라우저 · 편집기의 탭을 닫을 수 있어요). 빈 데스크톱 위에서 떼는 게 안전해요.

## B. macOS 고유

| # | 동작 | 기대 | 왜 |
|---|---|---|---|
| M1 | 우클릭한 채 드래그 | 출력 0건 | macOS 는 `rightMouseDragged:` 미등록이라 그 경로가 없다는 판정을 실측으로 확인 |
| M2 | 가운데 버튼 클릭 · 드래그 | `Cb` 1 / 33 | `otherMouseDown:`/`otherMouseDragged:`/`otherMouseUp:` 경로. Cocoa 는 버튼별 selector 라 가운데 드래그가 `mouseDragged:` 로 오지 않는다 — `otherMouseDragged:` 는 #502 에서 누락이 발견되어 추가됐고 macOS 실기로 확인했다. `Cb 33` 이 안 나오면 그 등록을 먼저 본다. **트랙패드엔 가운데 버튼이 없다** — 실물 마우스가 없으면 아래 「합성 입력」 으로 만든다 |
| M3 | Cmd+클릭 | `Cb` = 0 | Cmd 는 프로토콜에 자리가 없어 싣지 않는다. 4·8·16 이 붙으면 버그 |
| M4 | 실물 마우스 휠 한 칸 | `Cb` 64 **1 건** (또는 65) | `1 notch = 보고 1 건` (Linux · Windows 와 같다). 2 건이 나오면 `hasPreciseScrollingDeltas` 분기가 깨진 것이다 — tick 에 트랙패드용 배율이 곱해진다 |
| M5 | 트랙패드 두 손가락 스크롤 | 이동 **거리에 비례** (살짝 움직이면 0~1 건) | 연속 delta (논리 pt) 를 누적해 **cell 높이당 1 notch**, 나머지는 보존. 살짝 움직였는데도 여러 건이 나오거나 한 번 훑기가 수백 건이면 누적이 깨진 것이다 |
| M6 | `?1007` — alt screen 에서 휠 한 칸 | 화살표 **3 개** | notch 당 3 줄 (SPEC §3 · Linux `n * 3`). `less` 로 본다 |

### 합성 입력으로 가운데 버튼 · 휠 만들기 (macOS)

실물 마우스가 없어도 `CGEventPost` 로 A5 · A9 · M2 · M4 를 만들 수 있어요
([#502](https://github.com/ensky0/tildaz/issues/502) macOS 검증에서 이렇게 했어요).
선례는 [`dist/stress/mac-input.m`](../stress/mac-input.m) 예요.

- 가운데 버튼은 `kCGEventOtherMouseDown`/`Dragged`/`Up` + `kCGMouseEventButtonNumber = 2` 예요.
- 휠은 `CGEventCreateScrollWheelEvent2` 로 만들고 **단위가 그대로 장치 구분이 돼요** —
  `kCGScrollEventUnitLine` 은 `hasPreciseScrollingDeltas = false` (마우스 휠, delta = tick 수),
  `kCGScrollEventUnitPixel` 은 `true` (트랙패드, delta = 논리 pt) 로 들어와요 (실측 확인).
  scroll 이벤트는 위치를 안 실으니 `CGEventSetLocation` 으로 지정해요.
- hover (`?1003`) 는 `CGWarpMouseCursorPosition` 만으로는 안 걸려요 — `kCGEventMouseMoved` 를
  실제로 보내야 해요.
- **권한은 보내는 쪽에 필요해요.** 없으면 `CGEventPost` 가 *성공을 반환하면서 아무 일도 하지
  않아요.* 같은 프로세스에서 `AXIsProcessTrusted()` 로 먼저 판정해요. TildaZ 는 받는 쪽이라
  이 권한이 필요 없어요.
- 소스는 `kCGEventSourceStatePrivate` 로 만들고 **flags 는 0 이어도 반드시 설정**해요 —
  직전 조합의 modifier 가 남아 엉뚱한 `Cb` 가 돼요.
- **트랙패드 체감 (M5) 은 합성으로 대신할 수 없어요.** 관성 · `phase` 가 재현되지 않아서
  거리 감각은 사람 손으로 봐요.

## C. Windows 고유

| # | 동작 | 기대 | 왜 |
|---|---|---|---|
| W1 | 휠을 화면 여러 위치에서 | `Cb 64` 의 `COL;ROW` 가 포인터 위치를 따라 **제대로 변한다** | `WM_MOUSEWHEEL` 의 `lParam` 은 **screen 좌표**라 `ScreenToClient` 변환이 필요. 인코더가 좌표를 `@min(…, cols−1)` 로 clamp 하므로 변환이 빠져도 "엉뚱한 큰 수" 가 아니라 **마지막 열에 고정**되거나 행이 일정량 밀린다 — *값이 위치에 따라 변하는지*로 판정한다. 창이 화면 위쪽이면 `screen y == client y` 라 **y 축을 못 가른다**: `dock_position` 을 `bottom` 으로 바꿔 한 번 더 본다 |
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

`--log` 를 쓰면 로그 파일에서 바로 세어 판정할 수 있어요. 항목 사이에 표식을 넣어 두면
구간이 갈려요 (`printf '\n>>>A1\n' >> /tmp/m.log`).

```sh
cat -v /tmp/m.log | sed 's/\^\[\[</ CSI</g'          # 사람이 읽는 형태로
grep -o $'\x1b\[<' /tmp/m.log | wc -l                 # 보고 건수 (휠 notch 판정)
```

**판정은 좌표 절대값이 아니라 `Cb` 값과 press/release 짝으로** 해요 — 창 위치 · 배율 ·
cell 크기가 머신마다 달라서 좌표는 환경에 딸려 가요. 좌표는 *칸이 바뀌었는지* / *가장자리에
clamp 됐는지* 같은 상대 판정에 써요.
