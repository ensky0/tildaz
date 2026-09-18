# tool/ — 검증 · 진단 · 측정 도구

이 디렉터리는 **색인일 뿐이에요.** 도구를 어떻게 쓰는지, 어떤 함정이 있는지는
[`AGENTS.md`](../AGENTS.md) 의 해당 절이 단일 출처예요 — 절차를 여기 옮겨 적지 않아요
(같은 내용을 두 군데 두면 한쪽만 갱신돼요).

배포물 (설치 · 패키징 · 서명 · 릴리즈 노트 · 아이콘 · 데스크톱 확장) 은 [`dist/`](../dist) 에 있어요.

## 이름 규칙 ([#644](https://github.com/ensky0/tildaz/issues/644))

1. **도구 이름이 먼저**예요. OS 로 먼저 나누지 않아요 — 같은 도구의 세 platform 판이
   흩어지면 하나를 고칠 때 나머지를 놓쳐요 ([#641](https://github.com/ensky0/tildaz/pull/641) 이
   실제로 그랬어요).
2. **파일이 하나뿐이면 디렉터리를 만들지 않아요.**
3. **OS 에 의존하면 `_linux` · `_macos` · `_windows` 를 붙여요.** 밑줄이 **없으면 OS 무관**이라는
   뜻이에요.
4. 여러 OS 를 지원하면 `Linux · macOS · Windows` 순서로 이어 붙여요 (`_linux_macos`).
   셋 다 되면 밑줄 없음이에요.
5. OS 접미사는 **항상 이름 끝**이에요 (`osc-title-probe-prompt_windows.md`).

## 여러 platform 판이 있는 도구

| 도구 | 판 | 무엇 | 자세한 곳 (AGENTS.md) |
|---|---|---|---|
| [`deadkey-check/`](deadkey-check) | linux · macos · windows | dead key 조합이 실제로 들어오는지 합성 입력으로 판정 | `# Linux — headless sway …` · `# macOS — 합성 입력으로 …` · `# Windows — 합성 입력으로 …` |
| [`layout-probe/`](layout-probe) | macos · windows | 활성 keyboard layout 이 어느 키에 어느 글자를 두는지 | `# macOS — 키보드 layout 조회 실측 방법` · `# Windows — 키보드 layout 조회 실측 방법` |
| [`osc-title-probe/`](osc-title-probe) | linux · windows | 자식 셸의 OSC 제목이 언제 도착하는지 (독립 zig 도구 · `zig build probe-check`) | — (도구 머리 주석) |
| [`render-ab-shot/`](render-ab-shot) | linux · macos · windows | 두 앱 판을 같은 화면으로 찍어 최종 그림을 픽셀 수로 견줌 | `# macOS — 렌더 결과와 …` · `# Windows — 렌더 결과를 …` · `# Linux — 글리프 · cluster …` |

## 여러 파일로 된 도구

| 도구 | 무엇 | 자세한 곳 |
|---|---|---|
| [`mouse-probe/`](mouse-probe) | TUI mouse reporting 프로브 (`mouse-probe.sh` · OS 무관) 와 macOS 자동 판정 (`mouse-auto-check_macos.sh`) | [`mouse-probe/README.md`](mouse-probe/README.md) · AGENTS.md `# macOS — 합성 입력으로 …` |
| [`stress/`](stress) | 처리량 · 응답 지연 · 유휴 전력 측정 하네스 한 벌. `hygiene.sh` 를 공유해요 | [`stress/README.md`](stress/README.md) · AGENTS.md `# 실행 환경` |

`stress/` 안쪽도 같은 규칙이에요 — `check-input-loss_linux_macos.sh` (Windows 는 `-e` 에 러너를
넘길 수 없어요) · `measure-idle-cstates_linux.sh` (cpuidle sysfs) · `measure-idle-power_linux.sh`
(turbostat · RAPL) · `pane-runner_windows.ps1` · `split-panes_windows.ps1` 만 OS 에 매여 있고,
나머지 (`hygiene.sh` · `compare-terminals.sh` · `measure-repeat.sh` · `measure-input-latency.sh` ·
`measure-idle-latency.sh`) 는 세 platform 다 돌아요.

## 파일 하나짜리 도구

| 도구 | OS | 무엇 | 자세한 곳 (AGENTS.md) |
|---|---|---|---|
| [`bands-check.py`](bands-check.py) | 무관 | 띠 화면 캡처의 세로 단면에서 리샘플 서명을 읽음 | `# Linux — headless sway …` |
| [`clusters.py`](clusters.py) | 무관 | atlas · cluster 검증 화면 생성기 (`many` · `stack2` · `overflow` · `mini` · `bands`) | `# macOS — 렌더 결과와 …` |
| [`color-capture_macos.m`](color-capture_macos.m) | macOS | 출력 색공간을 sRGB 로 지정해 창을 캡처 (`--list` 는 창 목록 · 위치) | `# macOS — 색 실측 방법` |
| [`dmabuf-probe_linux.zig`](dmabuf-probe_linux.zig) | Linux | dma-buf 경로 독립 진단 (`zig build probe-check`) | — (도구 머리 주석) |
| [`headless-check_linux.sh`](headless-check_linux.sh) | Linux | headless sway + 가상 키보드로 탭 · 다이얼로그 · 배율 · 첫 실행을 자동 검증 | `# Linux — headless sway …` |
| [`input_macos.m`](input_macos.m) | macOS | 합성 키 입력 (`send return` · `ime-get` · `ime-ascii` · `ime-set`) | `# macOS — 합성 입력으로 …` |
| [`key-bytes.py`](key-bytes.py) | 무관 | 키 하나가 PTY 로 보낸 **바이트를 그대로** 찍음. `legacy` · `kitty` · `mok2` 세 모드 ([#648](https://github.com/ensky0/tildaz/issues/648) · [#650](https://github.com/ensky0/tildaz/issues/650)) | — (도구 머리 주석) |
| [`key-bytes-check_windows.ps1`](key-bytes-check_windows.ps1) | Windows | 위 도구를 합성 입력으로 돌려 `Ctrl+[` · `Ctrl+Shift+<글자>` 등의 바이트를 기대값과 자동 판정 (legacy · kitty · mok2) | `# Windows — 합성 입력으로 …` |
| [`kitty-text-check_windows.ps1`](kitty-text-check_windows.ps1) | Windows | kitty keyboard protocol 의 글자 키 바이트 판정 | `# Windows — 합성 입력으로 …` |
| [`launcher-fatal-check_windows.ps1`](launcher-fatal-check_windows.ps1) | Windows | launcher 기동 실패가 화면에 뜨는지 | `# Windows — 합성 입력으로 …` |
| [`link-click-check_linux.sh`](link-click-check_linux.sh) | Linux | headless sway 안에서 터미널 링크의 밑줄 · 손 커서 · 클릭으로 열림을 합성 마우스 · 키로 자동 판정 ([#647](https://github.com/ensky0/tildaz/issues/647)) | `# Linux — headless sway …` |
| [`link-click-check_windows.ps1`](link-click-check_windows.ps1) | Windows | 터미널 링크의 밑줄 · 손 커서 · 클릭으로 열림을 합성 마우스 · 키로 자동 판정 ([#647](https://github.com/ensky0/tildaz/issues/647)) | `# Windows — 합성 입력으로 …` |
| [`link-shot_linux.py`](link-shot_linux.py) | Linux | 링크 회차의 캡처 판정 — 격자 찾기 · 밑줄 픽셀 · XCursor 테마와 맞댄 커서 모양 | `# Linux — headless sway …` |
| [`portal-screenshot_linux.py`](portal-screenshot_linux.py) | Linux | xdg-desktop-portal 로 화면 캡처 (실제 GNOME · Cinnamon 세션용) | `# Linux — headless sway …` |
| [`position-hotkey-check_linux.sh`](position-hotkey-check_linux.sh) | Linux | 전역 hotkey 의 위치 표기가 이 데스크톱에 실제로 등록되는지 | `# 전역 hotkey 의 위치 표기 검증` |
| [`real-session-check_linux.sh`](real-session-check_linux.sh) | Linux | 실제 Hyprland · GNOME · Cinnamon 세션에 붙어 배율 · layer-shell 부재를 봄 | `# Linux — headless sway …` |
| [`search-bar-check_windows.ps1`](search-bar-check_windows.ps1) | Windows | 버퍼 검색바의 배치 · 키보드 · IME · 마우스 · 메뉴를 합성 입력과 캡처로 자동 판정 ([#646](https://github.com/ensky0/tildaz/issues/646)) | `# Windows — 합성 입력으로 …` |
| [`render-process-check_macos.sh`](render-process-check_macos.sh) | macOS | 기동 직후부터 촘촘히 찍어 **그리는 과정**을 봄 | `# macOS — 렌더 결과와 …` |
| [`repeat-render-check_macos.sh`](repeat-render-check_macos.sh) | macOS | 같은 바이너리를 여러 번 띄워 **실행 간 비결정**을 봄 | `# macOS — 실행마다 화면이 흔들리는지 보는 법` |
| [`send-keys_windows.ps1`](send-keys_windows.ps1) | Windows | `SendInput` 합성 키 (다른 Windows 도구 셋이 같이 씀) | `# Windows — 합성 입력으로 …` |
| [`tab-churn-check_windows.ps1`](tab-churn-check_windows.ps1) | Windows | 탭을 빠르게 열고 닫아 ConPTY teardown 을 봄 | — (도구 머리 주석) |
| [`vkbd_linux.py`](vkbd_linux.py) | Linux | headless sway 안의 가상 키보드 데몬 (`zwp_virtual_keyboard_v1`) | `# Linux — headless sway …` |
| [`vptr_linux.py`](vptr_linux.py) | Linux | headless sway 안의 가상 포인터 데몬 (`zwlr_virtual_pointer_v1`) — 절대좌표 hover · 클릭 · 드래그 | `# Linux — headless sway …` |
| [`zig-floath-patch_macos.sh`](zig-floath-patch_macos.sh) | macOS | zig 번들 `float.h` 에 SDK 27 의 `__need_infinity_nan` 규약을 넣어 `-Dsimd=true` 를 살림 (`--check` · `--revert`) | `# macOS — zig 번들 float.h 가 SDK 와 어긋날 때` |
