# TildaZ cross-platform 동작 사양 (SPEC)

> 공식 표기는 **TildaZ** (대문자 Z). 실행 파일 / 코드 식별자 / 파일 이름 /
> GitHub repo 등 *기술적 식별자* 만 `tildaz` (소문자).

TildaZ 가 Windows 와 macOS 에서 *어떻게 동작해야 하는가* 와 *현재 어디까지
구현되어 있는가* 를 한 표로 정리. 코드 변경할 때 같은 PR 안에서 SPEC update —
체크박스가 사실과 어긋나면 review 시점에 발견되도록.

상태 표기:
- ✅ 구현 + 사용자 환경 검증 통과
- 🟨 부분 구현 / 환경 한계 (별도 이슈에 사유)
- ❌ 미구현 (이슈 # cross-link)
- — 해당 platform 무관

---

## 0. 원칙

1. **Windows reference, macOS 동등.** Windows 에 있는 기능은 macOS 에도 동등
   구현. "마우스 휠로 충분 / optional" 같이 macOS 만 빠지는 정당화 안 함.
2. **platform 표준 / native 동작 우선.** cross-platform 일관성보다 *각 platform
   의 표준 / native 사용자 expectation* 을 우선. modifier 순서 (Apple HIG —
   Control → Option → Shift → Command 라 macOS 는 `Shift+Cmd+P` 가 표준,
   `Cmd+Shift+P` 비표준), config / log 위치, 다이얼로그 패턴 모두 platform 표준.
   같은 *기능* 의 단축키가 platform 별로 다른 키 (Windows `Ctrl+Shift+P` ↔
   macOS `Shift+Cmd+P`) — Chrome / VS Code 와 동일 패턴.
3. **config schema 동일, default 만 OS-specific.** font / shell 같은 OS-specific
   resource 만 default 값 platform 별 다름. 필드 이름 / 구조 동일 (#118).
4. **검증 후 commit.** 빌드 + smoke 통과만으로 commit 안 함. 사용자 시연 OK
   후에만 commit / amend / push.

---

## 1. 윈도우 / 디스플레이

| 항목 | 동작 정의 | Windows 구현 | macOS 구현 | Win | Mac |
|---|---|---|---|---|---|
| Drop-down 위치 | 다른 모든 윈도우 위 | `WS_EX_TOPMOST` + `SetWindowPos(HWND_TOPMOST)` | `NSPopUpMenuWindowLevel` (101) | ✅ | ✅ |
| Borderless | titlebar / 사각 모서리 | `WS_POPUP` styleMask | `NSWindowStyleMaskBorderless` + `canBecomeKeyWindow` override | ✅ | ✅ |
| Shadow | 없음 (drop-down 정체) | (default 없음) | `setHasShadow:false` 안 함 (default true 시각 자연) | ✅ | ✅ |
| 사용자 드래그 차단 | 사용자가 위치 / 크기 변경 못함 | `WS_POPUP` 자연 차단 | `setMovable:false` + non-resizable | ✅ | ✅ |
| Dock 위치 (config) | top / bottom / left / right | `setPosition` | `repositionWindow` | ✅ | ✅ |
| 크기 비율 (config) | width / height percent | `setPosition` | `repositionWindow` | ✅ | ✅ |
| 위치 offset (config) | dock 안 시작 위치 0..100 | `setPosition` | `repositionWindow` | ✅ | ✅ |
| Opacity (config) | 0..100 percent → alpha | `SetLayeredWindowAttributes` (LWA_ALPHA) | `NSWindow.setAlphaValue:` | ✅ | ✅ |
| Theme (config) | 16-color palette + bg/fg | `themes.findTheme` → ghostty Terminal.Colors | 동일 | ✅ | ✅ |
| 단일 탭 시 탭바 | 자리 없음 (Cmd+Q/W 만 종료) | (탭바 항상 표시) | `tabBarHeightPx == 0` 분기 | ✅ | ✅ |
| Live tracking | 모니터 / DPI 변화 시 재적용 | WM_DPICHANGED + `font_change_fn` | NSScreenDidChange notification | ✅ | ✅ |
| Drag-resize 사용자 차단 | 사용자가 크기 못 바꿈 | `WS_POPUP` styleMask | borderless + non-resizable | ✅ | ✅ |

---

## 2. 키바인딩 매트릭스

같은 *기능* 의 단축키가 platform 별로 다른 modifier — Windows `Ctrl+` / macOS `Cmd+` 표준.

### 2.1 글로벌 hotkey (앱 단위)

| 동작 | Windows | macOS | Win | Mac |
|---|---|---|---|---|
| 윈도우 토글 (drop-down) | F1 (`RegisterHotKey`) | F1 (CGEventTap, config 변경 가능) | ✅ | ✅ |
| 앱 종료 | Alt+F4 | Cmd+Q (mainMenu Quit) | ✅ | ✅ |

### 2.2 탭 관리

| 동작 | Windows | macOS | Win | Mac |
|---|---|---|---|---|
| 새 탭 | Ctrl+Shift+T | Cmd+T | ✅ | ✅ |
| 활성 탭 닫기 | Ctrl+Shift+W | Cmd+W | ✅ | ✅ |
| 인덱스 점프 (1..9) | Alt+1..9 ([`window.zig:1194-1200`](src/window.zig#L1194-L1200)) | Cmd+1..9 | ✅ | ✅ |
| 이전 탭 | Ctrl+Shift+Tab (Windows Terminal 컨벤션) | Shift+Cmd+[ | ✅ | ✅ |
| 다음 탭 | Ctrl+Tab | Shift+Cmd+] | ✅ | ✅ |

### 2.3 클립보드

| 동작 | Windows | macOS | Win | Mac |
|---|---|---|---|---|
| 복사 (단축키) | Ctrl+Shift+C | Cmd+C | ✅ | ✅ |
| 복사 (드래그 selection 후 자동) | `selection.finish()` → `copyToClipboard` | 동일 (`tildazMouseUp` 분기) | ✅ | ✅ |
| 붙여넣기 (단축키) | Ctrl+Shift+V | Cmd+V | ✅ | ✅ |
| 붙여넣기 (마우스 우클릭) | `WM_RBUTTONDOWN` → `pasteClipboard` (cmd.exe console 표준 패턴) | 동일 (`tildazRightMouseDown` → `handlePaste`) | ✅ | ✅ |

### 2.4 About 다이얼로그

| 동작 | Windows | macOS | Win | Mac |
|---|---|---|---|---|
| About 표시 | Ctrl+Shift+I (`MessageBoxW`) | Shift+Cmd+I (mainMenu keyEquivalent + NSAlert) | ✅ | ✅ |

### 2.5 스크롤

| 동작 | Windows | macOS | Win | Mac |
|---|---|---|---|---|
| 한 페이지 위 (scrollback) | Shift+PgUp | Shift+PgUp | ✅ | ✅ |
| 한 페이지 아래 | Shift+PgDn | Shift+PgDn | ✅ | ✅ |

### 2.6 Ctrl+key PTY 전달 (control char)

| 동작 | Windows | macOS | Win | Mac |
|---|---|---|---|---|
| Ctrl+C → SIGINT (\\x03) | `WM_CHAR` 자동 ASCII control char | NSEvent.characters 직접 PTY write | ✅ | ✅ |
| Ctrl+A ~ Ctrl+Z 일반 control | 동일 | 동일 (Ctrl+] tag jump, Ctrl+W vim window 등) | ✅ | ✅ |
| 한글 IME 조합 중 Ctrl+C | (해당 없음) | `discardMarkedText` + preedit overlay 비움 + \\x03 직송 — shell 의 "입력 라인 버리기" 의도와 일관 | — | ✅ |

### 2.7 Key repeat (길게 누름 반복)

| 항목 | Windows | macOS | Win | Mac |
|---|---|---|---|---|
| 영어/숫자/기호 길게 누름 → 반복 입력 | OS default | `ApplePressAndHoldEnabled = false` 우리 앱 도메인에 등록 — 안 등록하면 system 이 accent picker (à á â) 띄우려 repeat 막음 | ✅ | ✅ |
| 한글 자모 길게 누름 → 반복 입력 | (해당 없음) | IME 경로라 PressAndHold 영향 없음 (자동) | — | ✅ |

---

## 3. 마우스 동작

| 동작 | 위치 | Windows | macOS | Win | Mac |
|---|---|---|---|---|---|
| 셀 selection (drag) | cell 영역 | mouseDown + mouseMove + mouseUp | 동일 (`tildazMouseDown/Dragged/Up`) | ✅ | ✅ |
| 더블클릭 word selection | cell 영역 | `mouse_double_click` → `selectWord` | 동일 (`tildazMouseDown` clickCount >= 2) | ✅ | ✅ |
| 더블클릭 후 자동 copy | cell 영역 | `selectWordAt` 안에서 `copyToClipboard` | 동일 — `selectWord` 후 `handleCopy` | ✅ | ✅ |
| selection finish 후 자동 copy | cell 영역 | `selection.finish()` → `copyToClipboard` | 동일 (`tildazMouseUp` 분기) | ✅ | ✅ |
| word selection 동작 사양 | cell 영역 | cross-platform 단일 모듈 ([terminal_interaction.zig:8](src/terminal_interaction.zig#L8)) | 동일 모듈 | ✅ | ✅ |
| 우클릭 paste | 어디든 | `WM_RBUTTONDOWN` → `pasteClipboard` | `tildazRightMouseDown` → `handlePaste` | ✅ | ✅ |
| 휠 / 트랙패드 scroll | 셀 영역 | `WM_MOUSEWHEEL` → `scrollViewport` | `tildazScrollWheel` → 동일 | ✅ | ✅ |
| 스크롤바 클릭 + 드래그 | 우측 가장자리 | `mouse.x >= client_w - SCROLLBAR_W` → `scrollToY` | 동일 (`scrollbarScrollToY`, Windows 패턴 그대로) | ✅ | ✅ |
| viewport 이동 시 selection 유지 | 어디든 | ghostty `Selection` 이 `Pin` (page list 절대 위치) 기반 — viewport 는 보는 창문 | 동일 (같은 ghostty 모듈) | ✅ | ✅ |
| 탭바 — 탭 클릭 | 상단 탭 영역 | `handleTabClick` → `setActiveTab` | 동일 (`tabBarHitTest`) | ✅ | ✅ |
| 탭바 — × 클릭 | 탭 우측 close 박스 | `handleTabClick` → `closeTab` | 동일 | ✅ | ✅ |
| 탭바 — drag reorder | 탭 본체 drag | `DragState` (5px 임계) → `reorderTabs` | 동일 (`g_drag`) | ✅ | ✅ |
| 탭바 — drag follow 시각 | drag 중 탭 마우스 따라 | `dragged_tab + drag_x` 인자 | 동일 (`TabDragView`) | ✅ | ✅ |
| 탭바 — 더블클릭 rename | 탭 본체 더블클릭 | `RenameState.begin` | 동일 (`g_rename`) | ✅ | ✅ |

> **word selection 동작 사양 (cross-platform 단일 구현):** [`terminal_interaction.zig:8`](src/terminal_interaction.zig#L8)
>
> 1. **boundary 문자 목록**: space / tab / 따옴표 / 백틱 / 파이프 / `: ; ( ) [ ] { } < >`
> 2. **시작 cell 이 boundary** (공백 / 따옴표 / 구두점) → 선택 안 함 (false 반환). iTerm2 / Terminal.app 동등 — 터미널에서 공백 더블클릭은 의도가 아님. ghostty default 는 boundary 끼리도 묶지만 우리는 reject.
> 3. **시작 cell 이 word body** → 양쪽으로 boundary 문자 만나기 직전까지 확장.
> 4. **wide char (한/中/日 등) 처리**:
>    - `spacer_tail` cell (글자의 right-half) 위 클릭 → main cell (left-half) 로 정규화 후 진행.
>    - 확장 중 `spacer_tail` 만나면 boundary 검사 *skip* 하고 다음 cell 로 진행 — wide char 가 word body 의 continuation 이므로 음절 사이에서 끊기지 않음.
>
> 우리가 ghostty `screen.selectWord` 를 그대로 쓰지 않고 [`terminal_interaction.selectWord`](src/terminal_interaction.zig#L8) 로 직접 구현한 이유: ghostty 가 spacer_tail 을 boundary 처럼 취급해 한글 단어가 음절마다 끊기는 문제 (#122 시연 중 발견).

---

## 4. 탭 lifecycle

| 항목 | 동작 정의 | Windows | macOS | Win | Mac |
|---|---|---|---|---|---|
| 컬렉션 | `ArrayList(*Tab)` + `active_tab: usize` | `SessionCore` | `macos_session.SessionCore` | ✅ | ✅ |
| 새 탭 크기 | 활성 탭의 cols/rows 와 동일 | `createTab(cols, rows, ...)` | 동일 | ✅ | ✅ |
| 단일↔멀티 전환 시 cell 영역 동기화 | 양쪽 모두: 단일 탭 시 탭바 자리 없음 → 전환 시 cell 영역 변화 → 모든 탭 cols/rows 재계산 (#127 으로 Windows 도 동등). | `effectiveTabBarHeight()` + `createTab` / `handleCloseResult` 의 `resizeAll` | `syncTerminalGeometry` 호출 | ✅ | ✅ |
| 활성 인덱스 자동 조정 (close) | 닫힌 탭이 활성 앞이면 -1, 활성 자체였으면 새 마지막으로 | `nextActiveIndexAfterClose` | `closeTab` 안 동일 정책 | ✅ | ✅ |
| PTY exit → 그 탭만 정리 | read thread → main thread 안전 | `WM_TAB_CLOSED` post + `closeTabByPtr` | `Tab.exit_flag` atomic + `drainExitedTabs` | ✅ | ✅ |
| 마지막 탭 종료 → 앱 종료 | count == 0 시 | `closeAfterShellExit` | `NSApp.terminate:` | ✅ | ✅ |
| Drag reorder 5px 임계 | drag 가 5px 미만 = click | `DragState.move` | 동일 (cross-platform `tab_interaction.zig`) | ✅ | ✅ |
| Rename — cursor 표시 | always-visible 1px vertical bar | `cursor_instances` | 동일 (`drawTabBar`) | ✅ | ✅ |
| Rename — IME UTF-8 입력 | 한글 / 일본어 등 multi-byte | `RenameState.insertCodepoint` | 동일 (`imeInsertText` rename 분기) | ✅ | ✅ |
| Rename — IME preedit 위치 | 탭바 cursor 옆 inline | (Windows IME preedit 미구현 — #110) | `drawTabBar` 의 preedit 인자 | 🟨 #110 | ✅ |
| Rename auto-commit on focus loss | mouseDown / 다른 탭 활성 시 commit | `mouse_down` 진입 첫 줄 + `handleSwitchTab` | `commitOrCancelRename` 동일 | ✅ | ✅ |

---

## 5. 한글 IME 동작 (양쪽 동일 spec)

`AGENTS.md # 한글 IME 동작 스펙` 의 정의 그대로. 요약:

| 항목 | 동작 | Windows | macOS | Win | Mac |
|---|---|---|---|---|---|
| 조합 중 (preedit) inline 표시 | cursor 위치에 보라색 배경 + 글자 | (의도된 platform 차이 — OS IME candidate window 표준) | `g_preedit_buf` + cell `renderFrame` 의 preedit 영역 | — | ✅ |
| 음절 단위 backspace | 자모 / 음절 단위 되돌리기 | (OS IME 자체) | 동일 | ✅ | ✅ |
| 화살표 / 영문 / space → 음절 commit | IME 가 모르는 키 = 음절 자동 확정 | (OS IME 자체) | `interpretKeyEvents` → IME → callback | ✅ | ✅ |
| commit 트리거 | 음절 더 확장 안 되면 자동 | (OS IME 자체) | 동일 | ✅ | ✅ |

---

## 6. 다이얼로그

| 항목 | 동작 정의 | Windows | macOS | Win | Mac |
|---|---|---|---|---|---|
| 사용자 표시 텍스트 단일 진입점 | 모든 메시지 / format string 한 곳 | `messages.zig` import | 동일 | ✅ | ✅ |
| 다이얼로그 추상화 | `dialog.showInfo / showError / showFatal` | `dialog_windows.zig` (`MessageBoxW`) | `dialog_macos.zig` (NSAlert + osascript fallback) | ✅ | ✅ |
| About 다이얼로그 | 버전 / exe / pid 표시 | `MessageBoxW` (Windows) | NSAlert + popup level 우회 (host window level 잠깐 normal) | ✅ | ✅ |
| Config 에러 (잘못된 값) | dialog 띄우고 종료 (`showFatal`) | `dialog.showFatal` | 동일 (NSApp init 전 osascript fallback) | ✅ | ✅ |
| Panic | dialog + `process.exit(1)` | `dialog.showError` + exit | 동일 | ✅ | ✅ |

---

## 7. config (#118 — 통합 진행 중)

같은 schema, default 만 OS-specific.

| 필드 | 의미 | Windows default | macOS default | Win | Mac |
|---|---|---|---|---|---|
| `dock_position` | top / bottom / left / right | `top` | `top` | ✅ | ✅ |
| `width` | 1..100 percent | 50 | 50 | ✅ | ✅ |
| `height` | 1..100 percent | 100 | 100 | ✅ | ✅ |
| `offset` | 0..100 percent | 100 | 100 | ✅ | ✅ |
| `opacity` | 0..100 percent | 100 | 100 | ✅ | ✅ |
| `theme` | string (`themes.findTheme`) | `Tilda` | `Tilda` | ✅ | ✅ |
| `font.family` | string / array | `["Cascadia Mono", "Malgun Gothic", "Segoe UI Symbol"]` | (없음 — Menlo hardcoded) | ✅ | ❌ #118 |
| `font.size` | integer 8..72 | 19 | (hardcoded) | ✅ | ❌ #118 |
| `font.line_height` | float | 0.95 | (hardcoded) | ✅ | ❌ #118 |
| `font.cell_width` | float | 1.1 | (hardcoded) | ✅ | ❌ #118 |
| `shell` | string (셸 경로) | `cmd.exe` | (`$SHELL` env, hardcoded path) | ✅ | ❌ #118 |
| `auto_start` | bool | `true` | LaunchAgent (`~/Library/LaunchAgents/com.tildaz.app.plist`) | ✅ | ✅ |
| `hidden_start` | bool | `false` | 첫 hotkey 까지 윈도우 unmapped | ✅ | ✅ |
| `max_scroll_lines` | integer | 100_000 | (hardcoded 100_000) | ✅ | ❌ #118 |
| `hotkey` | string (macOS 만 — Windows 는 OS API 고정 F1) | — | `f1` | — | ✅ |

---

## 8. PTY 자식 종료

| 항목 | 동작 정의 | Windows | macOS | Win | Mac |
|---|---|---|---|---|---|
| 탭 닫기 시 자식 정리 | 즉시 종료 + read thread join | `ClosePseudoConsole(hpc)` 한 호출 | `kill(-pid, SIGHUP)` + `wait_thread.join()` | ✅ | ✅ |
| Polling sleep 회피 | join 직접 동기화 | (OS API 자동) | wait_thread blocking `waitpid` 으로 즉시 깨어남 | ✅ | ✅ |
| SIGHUP 무시 셸 fallback | SIGKILL 강제 | (자동) | 500ms grace (5ms polling, `child_exited` atomic) → SIGKILL | ✅ | ✅ |

---

## 9. 터미널 환경변수 (자식 셸에 전달)

`AGENTS.md # 터미널 환경변수` 와 동일. 우리 코드 자체엔 사용 X — 모두 자식 셸 / vim / less 같은 TUI 가 보는 변수.

**정책:** 부모 environ 모두 복사 + extra_env 뒤 추가. POSIX `getenv` first-match 라 *부모 환경에 있으면 그것 우선, 없으면 우리 값 fallback*. `.app` GUI launch (`open TildaZ.app`) 는 부모 환경 거의 비어 있어 fallback 적용. CLI 직접 실행은 사용자 셸의 값 우선.

| 환경변수 | 역할 | 우리 default (없을 때 fallback) | Win | Mac |
|---|---|---|---|---|
| `TERM` | escape sequence + 256-color capability | `xterm-256color` (Windows ConPTY 자체 default 있음, macOS 명시) | (PTY default) | ✅ |
| `LANG` | bash readline multi-byte 처리 | `en_US.UTF-8` (안 하면 한글 byte raw 처리, echo 안 됨) | (PTY default) | ✅ |
| `LC_CTYPE` | locale, 일부 셸이 `LANG` 안 봄 | `en_US.UTF-8` | (PTY default) | ✅ |
| `COLORFGBG` | vim / less / tmux 자동 dark/light colorscheme | `themes.isDark(theme)` → `15;0` (dark) / `0;15` (light) — *theme 으로 강제* (사용자 환경 override 의도) | ✅ | ✅ |
| `WSLENV` | WSL 안 process 에 `COLORFGBG` 전달 | `COLORFGBG` 추가 | ✅ | — |

**예외 — `COLORFGBG` 만 우리 값 강제 의도** (theme 따라 결정). 다른 변수는 사용자 환경 우선.

---

## 10. 메시지 언어

| 영역 | 언어 | 예 |
|---|---|---|
| 내부 협업 (commit / 이슈 / 댓글 / PR / SPEC.md / AGENTS.md / memory) | 한국어 | 이 문서, AGENTS.md |
| 외부 공개 (README / SECURITY / docs/ Pages / **릴리즈 노트** / 앱 UI) | 영어 | README.md, `dist/release-notes/*.md`, dialog 의 사용자 표시 텍스트 |

**릴리즈 노트는 영어** — end-user 가 GitHub Release 페이지에서 직접 봄. 이전 v0.2.13 까지 한국어로 작성됐지만 앞으로 영어. `AGENTS.md # 메시지 언어` 룰과 동기.

---

## 11. config / log 파일 위치 + Open Config/Log 단축키

각 OS 표준 위치 따름 (원칙 §0 #2). 사용자 발견성은 *About 다이얼로그 경로 표시* + *단축키로 default editor 열기* 로 보장 — UI 버튼 / 메뉴 시각이 없는 drop-down 정체상.

### 11.1 파일 위치

| 항목 | Windows | macOS | Linux |
|---|---|---|---|
| **config** | `%APPDATA%\tildaz\config.json` (Microsoft 표준) | `~/.config/tildaz/config.json` (XDG, ghostty/alacritty 패턴 — 터미널 사용자 친숙) | `~/.config/tildaz/config.json` (XDG) |
| **log** | `%APPDATA%\tildaz\tildaz.log` (Microsoft 표준) | `~/Library/Logs/tildaz.log` (Apple HIG — Console.app 자동 인덱싱) | `~/.local/state/tildaz/tildaz.log` (XDG state) |

파일이 없으면 첫 실행 시 default 가 자동 생성된다.

**stdout / stderr 정책**: 통합 로그가 single source of truth — stdout/stderr 에는 정보성 메시지 안 찍음. 모든 정보 (boot, startup, font/renderer init, tab create, geom, perm, pty, exit) 는 통합 로그로. ghostty-vt 의 `std.log` 호출 (예: `unimplemented mode: ...`) 도 `main.zig` 의 `std_options.logFn` 으로 redirect — 단 `unimplemented mode` noise 는 filter (xterm DECSET 중 ghostty 가 안 구현한 것들, terminal 동작 영향 없음). 권한 안내처럼 첫 부팅 사용자 actionable 인 것은 `dialog.showInfo` 로 messagebox 표시. (예외: macOS IMK system framework 의 stderr noise `IMKCFRunLoopWakeUpReliable` — system framework 가 우리 우회 없이 직접 찍는 것이라 차단 불가, 무시.)

### 11.2 Open Config / Log 단축키 (default editor 열기)

| 동작 | Windows | macOS | Win | Mac |
|---|---|---|---|---|
| Config 열기 | Ctrl+Shift+P | Shift+Cmd+P | ✅ | ✅ |
| Log 열기 | Ctrl+Shift+L | Shift+Cmd+L | ✅ | ✅ |

> Windows 의 `dump_perf` (스냅샷) 단축키는 Ctrl+Shift+P 와 충돌해 Ctrl+Shift+F12 로 이동 (개발자 dev 도구 컨벤션, F12).

**메커니즘:**
- Windows: `ShellExecuteW(NULL, "open", path, ...)` — 사용자 default editor (`.json` / `.log` 의 file association).
- macOS: `[NSWorkspace openURL:]` 또는 `system("open <path>")` — Finder 가 file extension 따라 default app.
- Linux: `xdg-open <path>` — XDG MIME database.

### 11.3 About 다이얼로그 — 경로 표시 (모두 절대 경로)

기존 About 텍스트 (TildaZ vX.Y.Z / exe / pid) 에 config / log 경로 추가. **`~` 같은 단축 안 쓰고 절대 경로** — 사용자가 그대로 복사해서 vim / ls 명령에 paste 가능 + `~` 가 환경에 따라 다른 위치라 ambiguity 제거.

```
TildaZ v0.2.13

exe   : /Applications/TildaZ.app/Contents/MacOS/tildaz
pid   : 12345
config: /Users/yongjun/.config/tildaz/config.json
log   : /Users/yongjun/Library/Logs/tildaz.log

https://github.com/ensky0/tildaz
```

Windows 도 동일 — `C:\Users\yongjun\AppData\Roaming\tildaz\config.json` 같이 absolute. `%APPDATA%` 같은 env var expansion 안 쓰고 펼친 경로.

사용자가 단축키 까먹어도 Shift+Cmd+I / Ctrl+Shift+I 로 About → 경로 확인 → 우리 터미널 안에서 `vim /Users/yongjun/.config/tildaz/config.json` 으로 편집.

**텍스트 selection / copy:**
- **Windows**: `MessageBoxW` 가 표준 dialog — Ctrl+C 자체 동작 (윈도우 내장).
- **macOS**: `NSAlert.accessoryView` 의 `NSTextView` (selectable / monospace) 로 본문 표시. 그리고 selection 변경 시 자동 clipboard copy (NSTextView delegate 의 `textViewDidChangeSelection:`) — 우리 터미널의 selection finish auto-copy (#122) 와 같은 패턴.
  - **왜 자동 copy?**: NSAlert 의 modal panel 안에서 NSTextView 가 firstResponder 를 안정적으로 못 잡음 → Cmd+C 의 `copy:` 액션이 OK 버튼 쪽으로 라우팅되어 클립보드에 안 들어감. 우클릭 contextual menu Copy 는 firstResponder 와 무관한 path 라 동작은 했지만 사용자 흐름상 어색. selection auto-copy 가 (a) 라우팅 우회 (b) 터미널 동작과 일관 두 가지 모두 해결.

### 11.4 config error 시 dialog 경로 안내

잘못된 config 값 발견 시 `dialog.showFatal` 본문에 *해당 config 파일 경로* 명시 — 사용자가 어디 고쳐야 할지 즉시 알게.

---

## 부록 A — 미구현 항목 (cross-platform 동등성 룰)

원칙은 *Windows 가 reference, macOS 동등* 이지만 *macOS 만 있는 기능* 도 동일 룰로 *Windows 에 추가* 해야 cross-platform 동등 (사용자 명시 룰).

### A.1 macOS 미구현 (Windows 기능 → macOS 추가)

| 항목 | 우선순위 | 이슈 | 비고 |
|---|---|---|---|
| Ctrl+key PTY 전달 (Ctrl+C SIGINT 등) | ✅ | #121 | NSEvent.characters 직송 + IME 조합 중에도 동작 + `ApplePressAndHoldEnabled=false` 로 영어 key repeat |
| 드래그 selection 자동 copy | ✅ | #122 | `selection.finish()` 자동 + 더블클릭 word selection 후 자동 copy + ghostty selectWord 직접 구현 (wide char 처리, boundary 시작 reject). |
| 마우스 우클릭 paste (양쪽 변경) | ✅ | #119 | Windows 가운데 버튼 (`WM_MBUTTONDOWN`, deprecated) → 우클릭 (`WM_RBUTTONDOWN`). macOS 우클릭 추가. |
| 스크롤바 마우스 클릭 + 드래그 | ✅ | #123 | `scrollbarScrollToY` (Windows `scrollToY` 패턴 그대로). cross-platform `ScrollbarDragState` + ghostty `Pin` 기반 selection 으로 viewport 이동해도 selection 유지. |
| autostart (LaunchAgent) | ✅ | #126 | `~/Library/LaunchAgents/com.tildaz.app.plist` (RunAtLoad), Windows Registry Run 동등 |
| 로그 시스템 (`~/Library/Logs/tildaz.log`) | ✅ | #124 | Windows `tildaz_log.zig` 동등. `[exit]` 는 `atexit()` hook 으로 기록 — NSApp `terminate:` 가 `exit()` 직행이라 main 의 `defer` 안 거침. |
| Developer ID 코드사인 + notarization | 🔴 (환경 한계) | #109 | 회사 keychain 정책 — fallback ad-hoc |
| config schema 확장 (font.* / shell / max_scroll_lines) | 🟡 | #118 | Windows config 와 동일 schema. macOS 는 현재 dock_position / width / height / offset / opacity / theme / hotkey / auto_start / hidden_start 만. font / shell / max_scroll 모두 hardcoded → JSON 으로. |
| SIGHUP 무시 셸 fallback (SIGKILL) | ✅ | #129 | `Pty.deinit` 에 grace period (500ms / 5ms polling) + `child_exited` atomic flag. wait_thread 의 waitpid 가 깨어나면 즉시 break, 안 깨어나면 SIGKILL. Cmd+W / 탭 close button 으로만 트리거 (Cmd+Q 는 NSApp `terminate:` → `exit()` 직행). |

### A.2 Windows 미구현 (macOS 기능 → Windows 추가)

| 항목 | 우선순위 | 이슈 | 비고 |
|---|---|---|---|
| 이전 / 다음 탭 단축키 | 🟢 | #125 | macOS Shift+Cmd+[/]. Windows 는 Ctrl+Tab / Ctrl+Shift+Tab 표준 권장. |
| 단일 탭 시 탭바 자리 reserve 버그 | ✅ | #127 | `App.effectiveTabBarHeight()` + count 1↔2 전환 시 `resizeAll`. d3d11_renderer 도 height==0 면 탭바 skip. |

---

## 부록 B — 알려진 quirk (자잘한 이상 동작, low priority)

> **quirk** = *버그까지는 아닌 알려진 자잘한 비표준 동작* (워크어라운드 알려진 minor 이슈). 사용자 환경 영향 거의 없거나 rare 케이스만 발생.

| quirk | 영향 | 우회 / 대안 |
|---|---|---|
| macOS Metal layer (0,0) 픽셀 미렌더링 | 좌상 1px corner 안 그려짐 | `TERMINAL_PADDING_PT >= 1` 이라 인지 거의 없음 |
| 한영 jamo replay (IMK mach port timing) | 한영 전환 직후 첫 jamo 가 두 번 처리 | 사용자 환경 미발생 |

---

## 부록 C — cross-platform 후속 이슈 (macOS 릴리즈 후)

| 이슈 | 내용 |
|---|---|
| #116 | Cmd+Q / Alt+F4 종료 확인 다이얼로그 |
| #117 | 탭바 squish (탭 수 늘면 너비 동적 축소) |
| #118 | config schema 통합 (이 문서 §7 의 ❌ 항목 정리) |

---

## 부록 D — 핵심 milestone commit 표

옵션 D (drop-down + 단일 zig 바이너리) 검증의 기록.

| commit | 내용 |
|---|---|
| [`14cc989`](https://github.com/ensky0/tildaz/commit/14cc989) | macOS #112 마우스 selection + 클립보드 + Metal buffer race fix |
| [`1868b6e`](https://github.com/ensky0/tildaz/commit/1868b6e) | refactor(dialog) cross-platform dialog/messages 모듈화 + About 일반화 |
| [`0a9e6cc`](https://github.com/ensky0/tildaz/commit/0a9e6cc) ~ [`602663b`](https://github.com/ensky0/tildaz/commit/602663b) | macOS #111 멀티탭 M11.1 ~ M11.7 |
| [`a9f1391`](https://github.com/ensky0/tildaz/commit/a9f1391) | macOS About 단축키 Shift+Cmd+I + NSAlert popup level 위 |
| [`6c0818e`](https://github.com/ensky0/tildaz/commit/6c0818e) | macOS #113 M13.1 opacity |
| [`7770b4f`](https://github.com/ensky0/tildaz/commit/7770b4f) | macOS #113 M13.2 theme + COLORFGBG |
| [`10be93b`](https://github.com/ensky0/tildaz/commit/10be93b) | macOS Shift+PgUp/PgDn scrollback |

---

*마지막 업데이트: 2026-05-01. 이 문서는 living document — 코드 변경할 때 같은
PR 안에서 update.*
