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

### 1.1 UI metric scaling (cross-platform)

`src/ui_metrics.zig` 의 `*_PT` 상수 = **logical points** (96 DPI 1x 기준 디자인).
각 host 가 자기 *scale factor* 를 곱해 physical pixel 로 변환. 모든 host 가 같은
PT 값 → 같은 *visual* 결과 보장 (DPI / scale 환경 무관).

| 항목 | 값 (PT) | Windows scale | macOS scale | Linux scale |
|---|---|---|---|---|
| Scale source | — | `GetDpiForWindow(hwnd) / 96.0` | `[window backingScaleFactor]` | `wp_fractional_scale_v1.preferred_scale / 120` |
| Scale 재계산 시점 | — | `WM_DPICHANGED` + startup | `NSScreenDidChange` notification + 매 resize | `preferred_scale` event |
| Storage | — | `App.dpi_scale` + `applyDpiScale(new_dpi)` 가 모든 derived 값 재계산 | `Renderer.scale` + 매 render 시 재읽음 | `Renderer.scale` + `applyScale(scale_num, scale_den)` |
| Font pixel height | `font.size_point` | `font_size_point × dpi/96` | `font_size_point × scale_pt` | `font_size_point × preferred_scale / 120` |
| `TERMINAL_PADDING_PT` | 6 | `App.TERMINAL_PADDING` | `pad_px` | `Renderer.paddingPx()` |
| `SCROLLBAR_W_PT` | 8 | `App.SCROLLBAR_W` | `scrollbar_w_px` | `Renderer.scrollbarWPx()` |
| `SCROLLBAR_MIN_THUMB_H_PT` | 32 | `App.SCROLLBAR_MIN_THUMB_H` | `scrollbar_min_thumb_h_px` | `Renderer.scrollbarMinThumbHPx()` |
| `TAB_BAR_HEIGHT_PT` | 28 | `App.TAB_BAR_HEIGHT`, `max(_, cell_h + 4)` 보정 | `tabBarHeightPx(scale)`, 동일 보정 | `Renderer.tabBarHeightPx()`, 동일 보정 |
| `TAB_WIDTH_PT` | 150 | `App.TAB_WIDTH` | `tab_w_px = TAB_WIDTH_PT × scale` | `Renderer.tabWidthPx()` |
| `TAB_PADDING_PT` | 6 | `App.TAB_PADDING` | `tab_pad_px` | `Renderer.tabPaddingPx()` |
| `TAB_CLOSE_SIZE_PT` | 14 | `App.CLOSE_BTN_SIZE` | `close_size_px` | `Renderer.tabCloseSizePx()` |
| `TAB_ARROW_W_PT` | 24 | `App.TAB_ARROW_W` | `arrow_w_px` | `Renderer.tabArrowWPx()` |
| `TAB_PLUS_W_PT` | 24 | `App.TAB_PLUS_W` | `plus_w_px` | `Renderer.tabPlusWPx()` |

**`max(_, cell_h + 4)` 보정**: 폰트 cell 이 디자인 tab bar 높이 보다 클 때 (예:
KDE 170% + 16pt 폰트의 cell_h = 33 physical > TAB_BAR_HEIGHT_PT 28 × 1.7 = 47.6
같은 케이스가 아니라, 작은 scale 환경에서 cell_h 가 28 보다 커지는 케이스) 텍스트
잘림 방지. 세 host 모두 동일 로직.

**fallback**: scale 정보 못 받은 환경 (Linux 의 fractional_scale_manager 미advertise,
mutter / wlroots) 또는 첫 init 시점 — `scale = 1.0` default, PT 값 그대로 사용
(기존 1x 환경 동작 보존).

`tab_layout.compute(Inputs)` 의 `tab_w` / `arrow_w` / `plus_w` 도 *scaled* 값을
넣어야 함 (PT 값 직접 넣으면 인접 hit-test 와 좌표 안 맞음). 모든 host 가 위 표의
host-specific getter 호출 결과를 `Inputs` 에 채워서 전달.

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
| 이전 탭 | Ctrl+Shift+[ | Shift+Cmd+[ | ✅ | ✅ |
| 다음 탭 | Ctrl+Shift+] | Shift+Cmd+] | ✅ | ✅ |

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
| 탭바 — `<` / `>` 화살표 클릭 | 탭바 양 끝 화살표 (#117) | `scrollTabsByArrow` — viewport 만 1 탭 너비씩 이동, **활성 탭 안 바뀜** + `tab_scroll_user_override=true` | 동일 (`scrollTabsByArrow`) | ✅ | ✅ |
| 탭바 — `+` 클릭 | `>` 안쪽 새 탭 (#117) | 새 탭 생성 → 활성 → ensure 가 viewport 우측 끝으로 정렬 | 동일 | ✅ | ✅ |

> **`<` / `>` 화살표 vs 활성 탭 — Firefox 패턴 (#117):**
>
> 1. `<` / `>` 클릭은 *viewport 스크롤 전용* — 활성 탭은 절대 안 바뀜. 사용자가 "다른 탭 *목록* 을 보러 왔다" 는 명시 의도이지 활성 전환 의도 아님.
> 2. 활성 변경 트리거는 **탭 클릭 / Alt+숫자 / Ctrl+Shift+[ / Ctrl+Shift+] (Win) / Cmd+숫자 / Shift+Cmd+[ / Shift+Cmd+] (mac) / `+` (새 탭)** 만.
> 3. `<` / `>` 누르는 순간 `tab_scroll_user_override = true` set → 매 frame `ensureActiveTabVisible` skip → 활성 탭이 viewport 밖이어도 그대로. 활성 변경 / 새 탭 / drag reorder 끝나는 시점에 false 로 reset 되어 ensure 재가동.
> 4. 활성 변경 시 viewport 동작: 활성 탭이 이미 보이면 그대로 (색깔만 변경), 안 보이면 보이는 가장 가까운 위치로 *minimum* 이동 (Chrome / Firefox 동등).
>
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
| 컬렉션 | `ArrayList(*Tab)` + `active_tab: usize` | `SessionCore` | `SessionCore` (v0.4.0+ 통합) | ✅ | ✅ |
| 새 탭 크기 | 활성 탭의 cols/rows 와 동일 | `createTab(cols, rows, ...)` | 동일 | ✅ | ✅ |
| 단일↔멀티 전환 시 cell 영역 동기화 | 양쪽 모두: 단일 탭 시 탭바 자리 없음 → 전환 시 cell 영역 변화 → 모든 탭 cols/rows 재계산 (#127 으로 Windows 도 동등). | `effectiveTabBarHeight()` + `createTab` / `handleCloseResult` 의 `resizeAll` | `syncTerminalGeometry` 호출 | ✅ | ✅ |
| 활성 인덱스 자동 조정 (close) | 닫힌 탭이 활성 앞이면 -1, 활성 자체였으면 새 마지막으로 | `nextActiveIndexAfterClose` | `closeTab` 안 동일 정책 | ✅ | ✅ |
| PTY exit → 그 탭만 정리 | read thread → main thread 안전 | `WM_TAB_CLOSED` post + `closeTabByPtr` | `Tab.exit_flag` atomic + `drainExitedTabs` | ✅ | ✅ |
| 마지막 탭 종료 → 앱 종료 | count == 0 시 | `closeAfterShellExit` | `NSApp.terminate:` | ✅ | ✅ |
| Drag reorder 5px 임계 | drag 가 5px 미만 = click | `DragState.move` | 동일 (cross-platform `tab_interaction.zig`) | ✅ | ✅ |
| Rename — cursor 표시 | always-visible 1px vertical bar | `cursor_instances` | 동일 (`drawTabBar`) | ✅ | ✅ |
| Rename — IME UTF-8 입력 | 한글 / 일본어 등 multi-byte | `RenameState.insertCodepoint` | 동일 (`imeInsertText` rename 분기) | ✅ | ✅ |
| Rename — IME preedit 위치 | 탭바 cursor 옆 inline (보라 배경) | `WM_IME_*` 가로채기 + `ImmGetCompositionStringW` + renderer overlay (#164 v0.4.0) | `drawTabBar` 의 preedit 인자 | ✅ | ✅ |
| Rename — 마우스 클릭 cursor 이동 | 같은 탭 text 영역 클릭 → cursor 이동 (commit X). 다른 영역 → commit. preedit 활성 시 manual commit + IME state cancel. | `tryRenameClickMoveCursor` + `imeCancelComposition` (#164 v0.4.0) | `tryRenameClickMoveCursor` + `discardMarkedText` 동일 | ✅ | ✅ |
| Rename — preedit 가운데 입력 push-right | cursor 뒤 main text 가 preedit advance 만큼 우측 이동, commit 시 자연 삽입 | `x_off += preedit_advance_total` (#164 v0.4.0) | 동일 (`text_x += preedit_advance_total`) | ✅ | ✅ |
| Rename — cursor follow scroll reserve | wide 1 글자 (cw*2) 고정. preedit 활성/비활성 무관 → typing 빠를 때 cursor 안정 | `tab_layout.cursorReserve` / `cursorScrollOffset` (#163 v0.4.0 helper) | 동일 (양쪽 같은 helper) | ✅ | ✅ |
| Rename — MAX_TABS 32 한도 + dialog | `+` layout 자동 사라짐 + 단축키 시 dialog | `tab_actions.checkAtLimitAndDialog` (#159 v0.4.0) | 동일 (양쪽 같은 helper) | ✅ | ✅ |
| Rename — IME 후보 popup 위치 / Hanja 치환 | cursor 옆 자연 추적 (한자 / kanji / hanzi). macOS Option+Return 은 조합 중 한글을 먼저 rename buffer 에 commit 한 뒤 후보창을 즉시 띄우고, 후보 확정 시에만 원래 한글 range 를 선택 한자로 치환. Esc / focus loss 는 원래 한글 유지. | `ImmSetCompositionWindow(CFS_POINT, cursor_pixel)` 매 frame (#164 v0.4.0) | `NSTextInputClient.firstRectForCharacterRange` 가 tab rename snapshot 기준 rect 반환 + `insertText:replacementRange:` 로 range 치환 (#166, #190 v0.4.3) | ✅ | ✅ |
| Rename auto-commit on focus loss | 아래 §4.1 통합 표 참조 — 모든 focus_loss = commit, Esc 만 cancel | (각 host 의 호출 site) | (각 host 의 호출 site) | ✅ | ✅ |

### 4.1 Rename focus_loss 통합 표 (#175)

탭 rename 활성 중에 어떤 focus_loss 가 발생해도 동일 동작 = **commit** (현재 입력값으로 그 탭 이름 확정). 유일한 예외 = **Esc** (cancel, 변경 안 함).

다른 inline rename UX 표준과 일치 — Finder filename rename, iTerm2 tab rename 등. 입력 흐름이 *항상 어딘가 저장* → 사용자 입력 손실 회피. cancel 은 명시적 의도일 때만.

| Focus_loss 액션 | Spec | Windows 호출 site | macOS 호출 site |
|---|---|---|---|
| 마우스로 다른 탭 클릭 | commit | `mouse_down` 진입 첫 줄 (`isRenaming` → `commitRename`) | `tildazMouseDown` 진입 첫 줄 (`commitPendingInput`) |
| 마우스로 터미널 영역 클릭 | commit | 동일 (영역 무관, 모든 `mouse_down`) | 동일 (영역 무관, 모든 `tildazMouseDown`) |
| Cmd/Ctrl+숫자 (탭 전환) | commit | `onAppEvent .shortcut` 분기 진입 첫 줄 (`isRenaming` → `commitRename`) | `tildazKeyDown` 의 Cmd 분기 진입 직전 (`commitPendingInput`) |
| Cmd/Ctrl+Shift+[ / ] (prev/next) | commit | 동일 (`.shortcut` 진입 첫 줄) | 동일 |
| Cmd/Ctrl+T (새 탭) | commit | 동일 | 동일 |
| Cmd/Ctrl+W (탭 닫기) | commit | 동일 | 동일 |
| 그 외 모든 단축키 (reset / dump_perf / show_about / open_config / open_log / copy_selection) | commit | 동일 (`.shortcut` 진입 첫 줄) | 동일 |
| F1 hide (윈도우 숨김) | commit | `WM_HOTKEY` → `toggle` 호출 직전 (`before_hide_fn` callback) | `toggleWindow` 진입 직전 (visible 이면 `commitPendingInputFromContentView`) |
| **Esc** | **cancel** (유일 예외) | `handleRenameKey` 의 `.cancel` 분기 | `tildazKeyDown` 의 Esc keycode 분기 |

---

## 5. IME 동작 (한국어 / 일본어 / 중국어 — 양쪽 동일 spec)

`AGENTS.md # 한글 IME 동작 스펙` 의 정의 그대로. 요약:

| 항목 | 동작 | Windows | macOS | Win | Mac |
|---|---|---|---|---|---|
| 조합 중 (preedit) inline 표시 | cursor 위치에 보라색 배경 + 글자 | `WM_IME_*` 가로채기 + `ImmGetCompositionStringW(GCS_COMPSTR)` → preedit_buf → cell / tab rename overlay (#164 v0.4.0) | `g_preedit_buf` + cell `renderFrame` 의 preedit 영역 + tab rename overlay | ✅ | ✅ |
| 음절 단위 backspace | 자모 / 음절 단위 되돌리기 | (OS IME 자체) | 동일 | ✅ | ✅ |
| 화살표 / 영문 / space → 음절 commit | IME 가 모르는 키 = 음절 자동 확정 | (OS IME 자체) | `interpretKeyEvents` → IME → callback | ✅ | ✅ |
| commit 트리거 | 음절 더 확장 안 되면 자동 | (OS IME 자체) | 동일 | ✅ | ✅ |
| 한자 / kanji / hanzi 후보 popup 위치 | cursor 옆 추적 | `ImmSetCompositionWindow(CFS_POINT, cursor_pixel)` 매 frame (#164 v0.4.0) | `NSTextInputClient.firstRectForCharacterRange` 가 terminal cursor row / tab rename snapshot 기준 rect 반환 (#166 v0.4.3) | ✅ | ✅ |
| Hanja / kanji reconversion | committed text 또는 조합 중 한글 → 후보 popup → 확정 시 replacement. 후보창이 떠 있는 동안 원래 한글은 그대로 보이고, 후보 확정 시에만 한글을 지우고 한자를 입력. Esc / 후보 취소 / focus loss 는 원래 한글 유지. | Win IME native conversion key / candidate popup 경로. app 은 후보 위치를 `ImmSetCompositionWindow` 로 유지 | `NSTextInputClient` reconversion API (`selectedRange`, `markedRange`, `attributedSubstringForProposedRange`, `firstRectForCharacterRange`, `insertText:replacementRange:`) 구현. terminal cursor row 는 PTY `backspace + insert`, tab rename 은 `RenameState` range 치환. 그 외 범위는 안전하게 plain insert fallback (#166, #190 v0.4.3) | ✅ | ✅ |

### 5.1 IME preedit × line-nav 키 매트릭스 (#164 follow-up 6, v0.4.0)

탭 rename 과 terminal cell 양쪽에서 IME 조합 (preedit) 중에 line-nav 키 (Home / End / Ctrl+A / Ctrl+E) 를 누를 때 동작 정의. native textbox / iTerm2 동등.

**원칙:** nav 키는 *commit 후 이동* — 입력 중 자모를 잃지 않음. Ctrl+C 만 예외 (line abort 의미라 discard).

| 위치 | 키 | preedit 처리 | 후속 동작 | Mac | Win |
|---|---|---|---|---|---|
| 탭 rename | Home / Ctrl+A | preedit 자모 → rename buf cursor 위치 insert | cursor 맨 앞 | ✅ | ✅ |
| 탭 rename | End / Ctrl+E | (동일) | cursor 맨 끝 | ✅ | ✅ |
| 탭 rename | Left / Right | (IME 자체 commit 트리거 — 음절 확정) | cursor 한 자 이동 | ✅ | ✅ |
| 탭 rename | Backspace | (IME 자체 — 자모 단위 되돌리기) | (preedit 안의 음절 처리) | ✅ | ✅ |
| 탭 rename | Esc | preedit cancel + rename cancel | rename 종료 (변경 안 함) | ✅ | ✅ |
| 탭 rename | Enter | preedit 자모 commit + rename commit | rename 종료 (변경 적용) | ✅ | ✅ |
| 탭 rename | Cmd / Ctrl+T·W·… 단축키 | preedit + rename 모두 commit | 단축키 동작 | ✅ | ✅ |
| 탭 rename | 마우스 click 다른 영역 | preedit + rename 모두 commit | click 동작 | ✅ | ✅ |
| terminal cell | Home / End | preedit → PTY commit | escape sequence 발신 (`\x1b[H` / `\x1b[F`) | ✅ | ✅ |
| terminal cell | Ctrl+A / Ctrl+E | preedit → PTY commit | Ctrl char 발신 (0x01 / 0x05, shell readline 처리) | ✅ | ✅ |
| terminal cell | Ctrl+C | preedit *discard* (예외 — line abort) | SIGINT (`\x03` interruptWrite) | ✅ | ✅ |
| terminal cell | Ctrl+L / Ctrl+D 등 | preedit → PTY commit | Ctrl char 발신 | ✅ | ✅ |
| terminal cell | Left / Right / Up / Down | (IME 자체 commit 트리거) | escape sequence 발신 | ✅ | ✅ |

#### 의사결정 rationale

| 결정 | 이유 |
|---|---|
| **Cmd+Left/Right 미매핑** | mac Terminal.app 도 동일 — terminal-style 앱은 Ctrl+A/E 만 받음. Cmd+Left/Right 는 일반 mac textbox 표준 (NSTextField line begin/end) 이지만 우리 앱은 terminal context 우선. Cmd+Left/Right 누르면 cmd 분기에서 commitPendingInput 후 mainMenu dispatch (key match 없으면 그대로 commit 됨). |
| **Ctrl+A/E + Home/End 매핑** | terminal readline 컨벤션 + native textbox 일부 표준 (NSStandardKeyBindingResponder 의 `moveToBeginningOfParagraph:` 등). 양쪽 fitness 함. |
| **nav 키 + preedit = commit (Ctrl+C 외)** | iTerm2 / native textbox 동등. 사용자가 입력 중인 자모 잃지 않음. terminal preedit 의 경우 PTY 로 직송 (셸 readline 이 받음), tab rename 의 경우 rename buf 의 cursor 위치에 insert. |
| **Ctrl+C 만 discard** | line abort 의미 — shell 의 SIGINT 가 "현재 입력 라인 버리기" 라 자모도 같이 버리는 게 자연스러움. 사용자 mental model 일관. |
| **좌측 ellipsis 안 보여줌** | native textbox (TextEdit, Safari URL bar) 도 안 함. cursor 위치 자체로 "긴 텍스트 안 어딘가" 라는 cue 충분. |
| **우측 ellipsis 도 deferred (#169)** | "탭 이름이 짧아진 듯" 사용자 feedback 으로 시도. 근데 cursor visibility 와 충돌 + zone transition 시 visual jitter 등 edge case 많아 revert. |

#### 시도 / 폐기 기록 (2026-05-10 세션)

세션 중 시도한 접근 둘이 폐기됨. 이후 다른 agent/유지보수자가 동일 함정 빠지지 않게 기록.

**1. Paragraph selectors 매핑 (commit 320cd09 → df4c8d5 로 amend 교체)**

Apple `StandardKeyBinding.dict` (시스템 표준 키바인딩 정의) 에 따르면:

```
"^a" = "moveToBeginningOfParagraph:";
"^e" = "moveToEndOfParagraph:";
"\UF729" (Home) = "moveToBeginningOfDocument:";
"\UF72B" (End) = "moveToEndOfDocument:";
```

`imeDoCommand` 의 selector mapping 에 위 4 개 추가했음. 이론상 `interpretKeyEvents` 가 Cocoa StandardKeyBinding 통해 dispatch 해 우리 callback 이 받아야 함.

**실제 동작 X.** 우리 custom NSView 에선 `interpretKeyEvents` 가 paragraph / document selector 를 dispatch 안 함. 추정 원인:
- `NSTextView` 가 아니라 `NSResponder` 직속 custom view 라 일부 selector 매핑이 path 안 거침
- 또는 fn modifier (외장 키보드 Home/End) 가 StandardKeyBinding lookup 우회

해결: `tildazKeyDown` 의 rename 분기에 직접 keyCode intercept 추가. Cocoa StandardKeyBinding mechanism 우회. mac virtual keycode (`kVK_Home` = 115, `kVK_End` = 119, `kVK_ANSI_A` = 0, `kVK_ANSI_E` = 14) 직접 검사. 외장 키보드 / fn+Left/Right / Ctrl+A/E 모두 동일 처리.

→ **교훈:** custom NSView 에서 line-nav 키는 StandardKeyBinding 의존 X, 직접 keyCode intercept.

**2. rename 우측 ellipsis cue (#169 deferred)**

긴 탭 이름 rename 중 cursor 맨 앞으로 옮기면 우측에 hidden text 있다는 visual cue 가 없어 "탭 이름이 짧아진 느낌" 이라는 사용자 feedback (시연 5/10).

시도한 구현:
- `iterTabText` 에 우측 "..." 3 dots emit
- `break_at` 을 `max - reserve - ellipsis_w` 앞당겨 dots 가 글자랑 안 겹치게 (text 가 ellipsis 자리까지 못 그리게 break)
- 가드: `can_show_right_ellipsis = scroll_offset == 0 AND total > max - reserve AND cursor_x_visual < max - reserve - ellipsis_w`
- 좌측 ellipsis 도 시도했다 native textbox 안 함이라 제거

발견된 문제:
- **Cursor visibility 충돌**: cursor 가 ellipsis zone (max - reserve - ellipsis_w 근처) 으로 이동하면 loop break 가 cursor byte 도달 전이라 cursor 안 그려짐 (typing at front 진행 시 발생)
- **Visual jitter**: cursor 위치에 따라 가드 조건 통과/미통과 transition → ellipsis 갑자기 사라지거나 나타남
- **사용자 시연 결과 "이상함"**: dots 가 글씨랑 겹치고 단일 dot 이 앞으로 오는 등 정렬 이슈

revert 후 [#169](https://github.com/ensky0/tildaz/issues/169) 로 deferred. cursor 동작 자체 (Home/End/Ctrl+A/E + #168 click cursor jump fix) 만 v0.4.0 출시.

향후 접근 옵션 (#169):
- **A.** 그대로 둠 — native textbox 동작 (cursor 위치만으로 판단)
- **B.** dots 대신 다른 cue (gradient fade, edge shadow, 단일 "…" 문자)
- **C.** dots 시도 — cursor 가 ellipsis zone 들어올 때 reserve 영역 동적 조정 + 가드 정밀화

→ **교훈:** native textbox 가 안 하는 visual cue 추가는 textbox 폭이 좁은 우리 환경에서 의미 있을 수 있으나, cursor + ellipsis 의 공간 경쟁이 까다로움. 단순한 break_at 조정만으로 부족 — typing 진행 중 cursor visibility 가 동적으로 변함.

#### 구현 디테일

**`commitPreeditPreserving` helper 분리 ([host/macos.zig:1095-1116](src/host/macos.zig))**

```zig
fn commitPreeditPreserving(self_view: objc.id) void {
    if (g_preedit_len == 0) return;
    if (g_rename.isActive()) {
        // rename 활성: preedit 자모 → rename buf cursor 위치 insert
        var iter = std.unicode.Utf8Iterator{ .bytes = g_preedit_buf[0..g_preedit_len], .i = 0 };
        while (iter.nextCodepoint()) |cp| {
            if (cp >= 0x20) _ = g_rename.insertCodepoint(cp);
        }
    } else {
        // rename 비활성: preedit 자모 → 활성 탭 PTY 직송
        g_session.queueInputToActive(g_preedit_buf[0..g_preedit_len]);
    }
    g_preedit_len = 0;
    g_marked_len = 0;
    // discardMarkedText — IME 가 더 이상 인식 안 함
}

fn commitPendingInput(self_view: objc.id) void {
    commitPreeditPreserving(self_view);
    commitOrCancelRename(true);
}
```

이전엔 `commitPendingInput` 한 함수에 모든 commit 로직 + rename 종료 합쳐져 있어서 "preedit 만 commit 하고 rename 유지" 케이스 (nav 키 처리) 에 재사용 어려웠음. 분리해 양쪽 모두 동일 helper 사용.

**direct keyCode intercept ([host/macos.zig:631-657](src/host/macos.zig))**

`tildazKeyDown` 의 rename 분기 안:

```zig
const rename_nav: ?tab_interaction.RenameKey = blk: {
    if (kc == 115) break :blk .home;            // Home key (외장 키보드)
    if (kc == 119) break :blk .end;             // End key
    if (ctrl and kc == 0) break :blk .home;     // Ctrl+A
    if (ctrl and kc == 14) break :blk .end;     // Ctrl+E
    break :blk null;
};
if (rename_nav) |k| {
    commitPreeditPreserving(self_view);  // preedit 보존
    _ = g_rename.handleKey(k);            // cursor 이동
    setNeedsDisplay(self_view, true);
    return;
}
```

`interpretKeyEvents` 우회. Apple 키보드 fn+Left/Right (= NSHomeFunctionKey = keyCode 115) 와 외장 Home 키 동일 keyCode 라 같이 처리.

**터미널 Ctrl 분기 ([host/macos.zig:661-697](src/host/macos.zig))**

```zig
if (ctrl and !cmd_too) {
    // ... get cstr ...
    const ctrl_c = (len == 1 and cstr[0] == 0x03);
    if (g_marked_len > 0) {
        if (!ctrl_c) {
            // Ctrl+A/E/L/D 등: preedit 자모 PTY commit 후 Ctrl char 발신
            tab.queueWrite(g_preedit_buf[0..g_preedit_len]);
        }
        // Ctrl+C 도 포함: discardMarkedText + g_preedit/marked_len reset
        // (Ctrl+C 만 line abort 의미라 commit X)
    }
    if (ctrl_c) tab.interruptWrite(...);  // SIGINT 큐 우회
    else tab.queueWrite(...);
}
```

**터미널 nav key + preedit 직접 처리 ([host/macos.zig:769-783](src/host/macos.zig))**

`interpretKeyEvents` 가 Home/End selector dispatch 안 하는 케이스 대비 — 시연 중 발견. preedit 활성 상태에서 Home/End 누르면 IME 가 finalize 만 하고 selector callback 안 옴 → escape sequence 안 발신 → cursor 안 움직임.

```zig
if (g_marked_len > 0) {
    if (keyCodeToEscape(keycode2)) |esc| {
        commitPreeditPreserving(self_view);
        tab.queueWrite(esc);
        return;
    }
}
```

**Win window.zig WM_KEYDOWN Ctrl+A/E ([window.zig:1235-1255](src/window.zig))**

```zig
if (GetKeyState(VK_CONTROL) < 0 and GetKeyState(VK_SHIFT) >= 0) {
    const ctrl_rename_key: ?app_event.KeyInput = switch (wParam) {
        0x41 => .home,  // 'A'
        0x45 => .end,   // 'E'
        else => null,
    };
    if (ctrl_rename_key) |k| {
        if (self.dispatchAppEvent(.{ .key_input = k })) {
            // rename consumed → swallow next WM_CHAR (0x01/0x05) 가 PTY 로 안 가게
            self.swallow_next_wm_char = true;
            return 0;
        }
        // rename 비활성 → fall-through → WM_CHAR 정상 PTY 송신 (셸 readline)
    }
}
```

`dispatchAppEvent` 가 `key_input` 받으면 rename 활성 시만 consume. rename 비활성 시 false 반환 → fall-through → TranslateMessage 가 보낸 WM_CHAR 가 정상 PTY 로 (셸 의 readline Ctrl+A/E 동작). Win Home/End 키는 [window.zig:1217-1218](src/window.zig) 에서 이미 KeyInput.home/end 매핑 — rename 활성 시 자동 작동.

**cross-platform**: `tab_layout.iterTabText` 가 cursor 따라 viewport scroll (RenameState.scroll_offset cached state, [#168](https://github.com/ensky0/tildaz/issues/168)) — nav 후 cursor 위치 자동 따라옴. mac/win 양쪽 같은 helper.

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

같은 nested schema, default 만 OS-specific. *Single source of truth* 패턴 — [`src/config.zig`](src/config.zig) 의 `Defaults` struct (Win/Mac 분기, 같은 필드 순서로 나란히) 한 곳에 모든 default 값. 이로부터:

1. **`DEFAULT_CONFIG_JSON`** 이 `std.fmt.comptimePrint` 으로 자동 생성 — 첫 실행 시 디스크 (`%APPDATA%\tildaz\config.json` 등) 에 저장 + parse() 의 `validateStructure` 검증 ground truth.
2. **`Config` struct field initializer** 가 참조하는 `default_*` const 모두 같은 `Defaults` 에서 derive — 디스크 default 와 메모리 fallback 자동 sync.

이전엔 default 값이 6+ 곳 (JSON literal + 별도 const 들 + Config struct hardcoded literal) 에 흩어져 있어 한쪽만 고치면 어긋남 — 시연 중 발견 (#135). 이제 `Defaults` 한 곳만 고치면 양쪽 자동 sync.

> Zig 0.15.2 의 `std.json` 이 comptime allocator 를 지원 안 해 (FixedBufferAllocator 의 `@intFromPtr` runtime-only) JSON → Zig 방향 derive 는 불가. 반대로 Zig struct → JSON 방향 (`comptimePrint`) 이 우리 패턴.

| 필드 | 의미 | Windows default | macOS default | Win | Mac |
|---|---|---|---|---|---|
| `window.dock_position` | top / bottom / left / right | `top` | `top` | ✅ | ✅ |
| `window.width_percent` | float 1.0..100.0 | 50.0 | 50.0 | ✅ | ✅ |
| `window.height_percent` | float 1.0..100.0 | 100.0 | 100.0 | ✅ | ✅ |
| `window.offset_percent` | float 0.0..100.0 | 100.0 | 100.0 | ✅ | ✅ |
| `window.opacity_percent` | float 0.0..100.0 (memory: 0..255 alpha) | 100.0 | 100.0 | ✅ | ✅ |
| `theme` | string (`themes.findTheme`) | `Tilda` | `Tilda` | ✅ | ✅ |
| `font.family` | string (primary font, single) | `Cascadia Code` | `Menlo` | ✅ | ✅ |
| `font.glyph_fallback` | string array (max 7 — chain total ≤ 8 with primary). 한글 / 이모지 / 심볼 순. | `["Malgun Gothic", "Segoe UI Emoji", "Segoe UI Symbol"]` | `["Apple SD Gothic Neo", "Apple Color Emoji", "Apple Symbols"]` | ✅ | ✅ |
| `font.size_point` | integer 8..72 (typographic point — host applies DPI scale) | 16 | 15 (Apple Terminal/iTerm2 컨벤션 + retina) | ✅ | ✅ |
| `font.line_height_ratio` | float 0.5..2.0 | 1.0 (#150 — DWrite native) | 1.1 (Apple HIG) | ✅ | ✅ |
| `font.cell_width_ratio` | float 0.5..2.0 | 1.0 (#150 — DWrite native) | 1.0 (Menlo metric 자연) | ✅ | ✅ |
| `shell` | string (셸 경로) | `cmd.exe` | 첫 실행 시 host 의 `resolveShell` 이 `$SHELL` env (있으면) / `/bin/bash` (없으면) 을 disk 명시값으로 작성. 이후 실행은 disk 명시값 그대로. | ✅ | ✅ |
| `auto_start` | bool | `true` | LaunchAgent (`~/Library/LaunchAgents/com.tildaz.app.plist`) | ✅ | ✅ |
| `hidden_start` | bool | `false` | 첫 hotkey 까지 윈도우 unmapped | ✅ | ✅ |
| `max_scroll_lines` | integer 100..10_000_000 | 100_000 | 100_000 default. ghostty `bytes_per_row × lines` 로 max byte 계산. | ✅ | ✅ |
| `hotkey` | string (`"f1"`, `"ctrl+space"`, `"shift+cmd+t"` 등). Windows 는 RegisterHotKey, macOS 는 CGEventTap. `cmd` 토큰 = Win key on Windows / Cmd on macOS. | `f1` | `f1` | ✅ | ✅ |

> **glyph fallback chain** (#135, v0.4.1 schema breaking): chain = `font.family` (primary, single string) + `font.glyph_fallback` (array of strings). codepoint 별로 chain 순회 → 글리프 가진 첫 폰트 사용. chain 에 없는 codepoint 는 양쪽 OS 모두 system fallback 이 자동 처리 — Windows DirectWrite `IDWriteFontFallback.MapCharacters`, macOS CoreText `CTFontCreateForString`. 사용자가 별도 폰트를 추가하고 싶으면 `glyph_fallback` 끝에 append.
>
> **명시 font chain 길이 제한** (#185): `font.family` 1개 + `font.glyph_fallback` 최대 7개 = 총 8개가 hard limit 이다. 코드 source of truth 는 `src/font/constants.zig` 의 `MAX_CHAIN = 8` 이며, config parser / Windows DirectWrite backend / macOS CoreText backend 는 이 상수를 공유한다. 이 값은 "primary + common fallback 한글 / 이모지 / 심볼 + 사용자 추가 여유" 를 주면서 font face lifetime / atlas key 안정성을 단순하게 유지하기 위한 고정 상한이다. 상한을 바꾸면 SPEC / CONFIG.md / README 의 chain limit 설명도 같이 갱신한다.
>
> 모든 명시 폰트 (primary + fallback) 가 system 에 register 되어 있어야 함 — 하나라도 없으면 fatal dialog (`font_validate.showNotFoundFatal`, chain dump + 미설치 표시 + config 경로). macOS substitute font 회피 위해 `CTFontCopyFamilyName` 으로 *실제 family name* 검증, Windows 는 `DWriteFontCtx.isFontAvailable` 로 검증.
>
> schema 위반 (`font.family` 가 string 아님 / `font.glyph_fallback` 이 string list 아님) 은 별도 fatal — `font_validate.showFamilyMustBeStringFatal` / `showGlyphFallbackMustBeListFatal`.

> **schema strict 검증** (Windows + macOS 동일, v0.4.1 통일 — #118 후속):
> - 모든 키 (`window.*`, `font.*`, `theme`, `shell`, `hotkey`, `auto_start`, `hidden_start`, `max_scroll_lines`) 가 *required*. 한 개라도 missing 이면 fatal `missing required key "..."` (사용자 의도하는 위치에 적었는데 silently 무시되는 사고 방지).
> - 알 수 없는 키 (오타 / 잘못된 위치) 면 fatal `unknown key "..."`. 단 `_` prefix key (예: `_note`, `_disabled_*`) 는 *사용자 주석* 으로 인정 — schema 검사 skip (#173). JSON 표준에 주석 없지만 정식 key 는 `_` 안 붙으니 충돌 없는 convention.
> - Type mismatch (예: `width_percent` 에 string) 면 fatal `type mismatch at "..."`. `font.family` / `font.glyph_fallback` 의 type 위반은 더 친절한 별도 메시지 (`font_validate` 의 helper).
> - 위 검증 모두 `validateStructure(user, default, ctx)` 한 함수가 재귀로 처리 — `defaultConfigJson(allocator, shell_resolved)` 결과와 user config 를 비교.

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

### 11.3 About 다이얼로그 — 경로 표시 (모두 절대 경로) + Tip 라인

기존 About 텍스트 (TildaZ vX.Y.Z / exe / pid) 에 config / log 경로 + 그 경로를 빨리 여는 단축키 Tip 추가. **`~` 같은 단축 안 쓰고 절대 경로** — 사용자가 그대로 복사해서 vim / ls 명령에 paste 가능 + `~` 가 환경에 따라 다른 위치라 ambiguity 제거.

**body 구조는 양쪽 platform 동일** (`messages.about_format`). Tip 라인의 단축키 *토큰* 만 platform native (Windows `Ctrl+Shift+P/L` ↔ macOS `Shift+Cmd+P/L`) — SPEC §0 #2 의 platform 표준 우선 원칙.

```
TildaZ v0.3.0

exe   : /Applications/TildaZ.app/Contents/MacOS/tildaz   (mac)
        C:\Users\<u>\...\tildaz.exe                       (win)
pid   : 12345
config: /Users/<u>/.config/tildaz/config.json            (mac)
        C:\Users\<u>\AppData\Roaming\tildaz\config.json   (win)
log   : /Users/<u>/Library/Logs/tildaz.log               (mac)
        C:\Users\<u>\AppData\Roaming\tildaz\tildaz.log    (win)

Tip: Shift+Cmd+P opens config in default editor.       (mac)
     Shift+Cmd+L opens log.
     Ctrl+Shift+P opens config in default editor.       (win)
     Ctrl+Shift+L opens log.

https://github.com/ensky0/tildaz
```

env var expansion (`~`, `%APPDATA%`) 안 쓰고 펼친 절대 경로. 사용자가 단축키 까먹어도 Shift+Cmd+I / Ctrl+Shift+I 로 About → 경로 확인 → Tip 의 단축키로 editor 직행.

**텍스트 selection / copy — body 는 같지만 dialog 메커니즘은 platform native** (각 OS 표준 dialog 의 자체 copy 흐름 따름):

- **Windows**: `MessageBoxW` 표준 dialog — `Ctrl+C` 가 본문 + 제목 + 버튼 전체를 클립보드로 (Win 내장 동작). path 만 골라내고 싶으면 paste 후 trim, 또는 Tip 의 `Ctrl+Shift+P/L` 로 editor 바로 열기 (path 자체 필요한 경우는 보통 editor 가 더 유용).
- **macOS**: `NSAlert.accessoryView` 의 `NSTextView` (selectable / monospace) 로 본문 표시 + selection 변경 시 자동 clipboard copy (NSTextView delegate 의 `textViewDidChangeSelection:`) — 우리 터미널 selection finish auto-copy (#122) 와 같은 패턴. NSAlert modal 안에서 NSTextView 가 firstResponder 를 안정적으로 못 잡아 `Cmd+C` 의 `copy:` 액션이 OK 버튼 쪽으로 라우팅되는 macOS quirk (AGENTS.md macOS Cocoa quirks #4) 우회.

> **TODO (cross-platform 동등 후속):** Windows 의 `Ctrl+C → 본문 전체 복사` 와 동등하게 macOS 도 `Cmd+C → 본문 전체 복사` 로 매칭 예정. NSAlert firstResponder quirk 때문에 단순 변경으론 안 되고 (a) 자체 NSPanel + custom keyDown 핸들러 또는 (b) `NSEvent.addLocalMonitorForEventsMatchingMask:` + Objective-C block FFI 신규 도입 필요. 별도 cycle 에서 macOS 머신 직접 시연하며 결정.

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
| 이전 / 다음 탭 단축키 | ✅ | #125 | Windows: Ctrl+Shift+[ / Ctrl+Shift+] (macOS Shift+Cmd+[/] 와 동일 키 pair, modifier 만 Windows 네이티브). macOS: Shift+Cmd+[/]. |
| 단일 탭 시 탭바 자리 reserve 버그 | ✅ | #127 | `App.effectiveTabBarHeight()` + count 1↔2 전환 시 `resizeAll`. `renderer/windows.zig` 도 height==0 면 탭바 skip. |
| 컬러 emoji + grapheme cluster shaping | ✅ | [#134](https://github.com/ensky0/tildaz/issues/134), [#136](https://github.com/ensky0/tildaz/issues/136), [#139](https://github.com/ensky0/tildaz/issues/139) | macOS #132 동등성. (a) `IDWriteFactory2.TranslateColorGlyphRun` + Direct2D D3D11-backed RT (`CreateDxgiSurfaceRenderTarget`) 으로 layer 별 `DrawGlyphRun` (`GRAYSCALE` antialias) + 2x super-sampling + `SetTextRenderingParams` (gamma=1.0) → atlas 에 premultiplied BGRA 로 저장. shader color path 가 `atlas.rgba` (premult) + `atlas.aaaa` 로 dual-source blend (Win Terminal `BackendD3D` 동등). (b) `IDWriteTextAnalyzer` 로 grapheme cluster shaping (skin tone, ZWJ). (c) `mode 2027` (grapheme cluster) ON. (d) ZWJ family glyph (`👨‍👩‍👧` 등) 는 `IDWriteTextAnalyzer.GetGlyphPlacements` 로 multi-glyph cluster 의 advance/offset 받아 visual 결합 (#139, WT 동등). |
| IME inline preedit (cell + tab rename) | ✅ | [#164](https://github.com/ensky0/tildaz/issues/164) v0.4.0 | macOS 의 `g_preedit_buf` + 보라 overlay 동등. `WM_IME_STARTCOMPOSITION` / `WM_IME_COMPOSITION` (`GCS_COMPSTR`) / `WM_IME_ENDCOMPOSITION` 가로채기 + `ImmGetCompositionStringW` UTF-16 → UTF-8 → `Window.preedit_buf` → renderer overlay (cell 시 cursor 위치 / rename 시 cursor 옆 inline). |
| IME 후보 popup cursor 추적 | ✅ | [#164](https://github.com/ensky0/tildaz/issues/164) 1d v0.4.0 | `ImmSetCompositionWindow(CFS_POINT, cursor_pixel)` 매 frame onRender 끝에 호출. 일본 / 중국 / 한국 IME 의 한자 후보 popup 이 cursor 옆 자연 추적. `D3d11Renderer.last_cursor_px_x/_y` 에 cursor 그릴 때 보관 (terminal cell / tab rename 양쪽). |
| About 다이얼로그 Cmd+C → 본문 전체 복사 | 🟢 | (#128 후속) | Windows `MessageBoxW` Ctrl+C 와 동등하게 macOS 도 Cmd+C 로 본문 전체 복사 매칭 예정. NSAlert firstResponder quirk 우회 (custom NSPanel + keyDown 핸들러 또는 NSEvent local monitor + Objective-C block FFI 신규 도입) 필요. 사용자 환경에서 macOS 시연 시 결정. |

---

## 부록 B — 알려진 quirk (자잘한 이상 동작, low priority)

> **quirk** = *버그까지는 아닌 알려진 자잘한 비표준 동작* (워크어라운드 알려진 minor 이슈). 사용자 환경 영향 거의 없거나 rare 케이스만 발생.

| quirk | 영향 | 우회 / 대안 |
|---|---|---|
| macOS Metal layer (0,0) 픽셀 미렌더링 | 좌상 1px corner 안 그려짐 | `TERMINAL_PADDING_PT >= 1` 이라 인지 거의 없음 |
| 한영 jamo replay (IMK mach port timing) | 한영 전환 직후 마지막 jamo 가 두 번 처리될 수 있음 | 사용자 환경 미발생. 우리 코드에 워크어라운드 없음. |
| macOS emoji picker — floating panel + no system auto-dismiss ([#130](https://github.com/ensky0/tildaz/issues/130)) | `Ctrl+Cmd+Space` picker 는 트리거되나, cursor 옆 popover 가 아닌 화면 floating panel. focus 잃어도 system 이 자동 안 닫음. | Apple-first-party (Terminal.app / TextEdit / Notes) 만 popover path. ghostty / iTerm2 / Alacritty / Kitty / tildaz 등 모든 custom-NSView 기반 modern 터미널 동등 한계. NSTextView 로 architectural rewrite 외 우회 없음 (10M scrollback / GPU atlas / custom IME overlay 잃음). dismiss: `Ctrl+Cmd+Space` 다시 (toggle) 또는 **`Esc`** (우리 boolean 추적 best-effort). emoji 입력 자체 우회: `echo`, `printf`, 다른 앱에서 복사 → 우클릭 paste. |
| ZWJ family / wide cluster emoji 다중 paste 시 줄바꿈 안 됨 ([#141](https://github.com/ensky0/tildaz/issues/141)) | `Cmd+V` 길게 누름 (key repeat ~30회/초) 으로 `👨‍👩‍👧` 같은 ZWJ family 를 flood 시 같은 줄에 덮어써짐. 1 회 paste 는 정상. | ghostty 의 Mode 2027 (grapheme cluster) 가 cluster = 2 cells 로 처리, bash 3.2 의 wcwidth 는 codepoint sum (man 2 + ZWJ 0 + woman 2 + ZWJ 0 + girl 2 = 6 cells) 으로 계산 → cell 4 mismatch/family. flood 시 bash 의 internal cursor 가 자기 wrap 임계 도달 → `\r` (CR) 출력 → 우리 grid col 0 으로 reset → 같은 자리 덮어써짐. fix path A (Mode 2027 OFF) 는 family ligature 깨짐, B (cluster cell width = codepoint sum + visual ligature 합성) 는 ghostty design 변경 필요 — 둘 다 trade-off 큼. 일반 사용 (1 회 paste) 무영향이라 known limitation 등재. zsh 5.x 등 cluster-aware shell 사용 시 자연 해소. |

> **한영 jamo replay 상세:**
>
> macOS 의 IME 시스템 (Input Method Kit, IMK) 은 한국어 IME ↔ ABC IME 같은 input source 전환을 IMKServer ↔ 클라이언트 앱 간 *Mach port* (커널 IPC) 메시지로 처리한다. 한영 전환 직전에 조합 중이던 markedText (마지막 jamo) 가 commit 되어야 다음 IME 가 새로 입력을 받을 수 있는데, 두 IMKServer 사이의 mach port 메시지 race 로 commit 이 다음 IME 의 input context 에 *재전송* 되거나 두 번 처리될 수 있다.
>
> - **언제 발생하나?** macOS IMK 자체의 timing race — 시스템 부하, 앱 launch 직후, mach port queue depth 등에 따라 발생. 일반적으로 매우 드물게.
> - **재현하기 어려움** — 우리 환경에서도 시연 / 일상 사용 모두 한 번도 발생 안 봄. ghostty / Alacritty / Kitty 등 native IME 통합한 다른 터미널도 같은 IMK 위라 동등 risk.
> - **우리 코드 워크어라운드 없음** — `imeInsertText:` / `imeSetMarkedText:` 가 IMKServer 가 보내는 sequence 그대로 받아 처리. timing 자체는 OS 영역.
> - **정확한 출처**: 이 quirk 는 SPEC 작성 시 "macOS IME 통합 터미널 앱 일반 risk" 로 사전 등재. 우리 앱에서 직접 관찰된 incident 는 없음.
>
> 관련 검색어: `IMK race condition`, `Korean input duplicate jamo macOS`, `NSTextInputClient markedText timing`. (Apple Developer Forums / ghostty / Alacritty GitHub issues 에 비슷한 보고가 있을 수 있으나 이 SPEC 작성 시점에 specific 1차 reference 확인된 것은 없음.)

> **macOS emoji picker — floating panel + no auto-dismiss 상세 ([#130](https://github.com/ensky0/tildaz/issues/130)):**
>
> `NSApp.orderFrontCharacterPalette:` (또는 사용자 system shortcut `Ctrl+Cmd+Space`) 는 Apple 의 private `CharacterPicker.framework` 로 들어가 두 path 중 하나로 picker 를 띄움 — (a) cursor 위치에 anchored 된 NSPopover (focus 잃으면 자동 dismiss), (b) standalone NSWindow floating panel (last-known position 기억, 수동 close).
>
> path 분기 criterion 은 firstResponder 가 NSText / NSTextView 계열 (또는 그에 준하는 internal protocol 통과) 인지에 달림. NSTextInputClient 의 `firstRectForCharacterRange:actualRange:` 만 implement 해도 popover path 활성 안 됨이 검증됨 — 우리 자체 IME 통합으로 그 메서드는 정확한 cursor screen rect 반환하나 system 이 popover 로 띄우지 않음.
>
> - **언제 발생하나?** 항상. `Ctrl+Cmd+Space` 한 번 누를 때마다 floating panel 로 뜸. 우선순위 🟢 (low) — picker 자체는 동작 + emoji 입력은 정상.
> - **Esc dismiss 보강** — system 자동 dismiss 가 안 되는 대신 우리 `tildazKeyDown` 에서 modifier 없는 Esc 를 잡아 picker 닫음. picker 는 우리 process 가 아니라 별도 system process (`com.apple.CharacterPaletteIM` 등 Apple Input Method bundle) 가 호스팅하므로 `[NSApp orderedWindows]` 로는 안 보임 — `isEmojiPickerOpen()` helper 가 `CGWindowListCopyWindowInfo` 로 모든 process 의 onscreen 윈도우 순회 + 각 owner PID 를 `NSRunningApplication` 으로 풀어 `bundleIdentifier` prefix `com.apple.Character` 매칭 (locale-independent). owner name 은 localized 라 매칭에 안 씀 (한글: "이모지 및 기호", 영어: "Emoji & Symbols"). 권한: `kCGWindowOwnerPID` 는 Screen Recording 권한 불필요.
> - **Terminal.app 만 되는 이유** — Apple 첫 party 앱이라 internal heuristic 통과 (정확한 criterion 은 private). 추정: TTView (Terminal.app 의 내부 view class) 가 NSTextView 계열이거나 popover path 를 활성화시키는 private method 를 implement.
> - **다른 custom-view 터미널 동등 한계** — ghostty / iTerm2 / Alacritty / Kitty / WezTerm / Warp 모두 동일한 floating panel 동작. *high-performance terminal architecture* (cell grid + GPU atlas + custom IME overlay + 10M scrollback) 와 NSTextView 의 character-flow / NSLayoutManager 모델은 근본 충돌이라 popover 만 위해 NSTextView 로 갈 수 없음.
> - **우리 코드 워크어라운드 없음** — popover path 는 macOS internal 영역.
>
> 관련 검색어: `orderFrontCharacterPalette`, `CharacterPicker.framework`, `NSTextView popover emoji panel`, `iTerm2 emoji picker floating`.

> **ZWJ family / wide cluster emoji 다중 paste 줄바꿈 안 됨 상세 ([#141](https://github.com/ensky0/tildaz/issues/141)):**
>
> ghostty 가 Mode 2027 (grapheme cluster, [`session_core.zig:205`](src/session_core.zig#L205)) ON 으로 ZWJ cluster (man + ZWJ + woman + ZWJ + girl) 를 받으면 첫 base char (man) 만 cell 차지 (wide = 2 cells), 나머지 codepoint 들은 모두 *같은 cell 의 grapheme extras* 로 append 되고 cursor 안 advance — cluster 1 개 = grid 의 2 cells. 시각적으로는 우리 metal renderer 가 cluster 의 base + extras 를 모아 CTLine 으로 single shape → family ligature 정상 표시 ([`renderer/macos.zig:577-587`](src/renderer/macos.zig#L577-L587)).
>
> 그러나 bash 3.2 (macOS default) 의 readline 은 cluster-unaware POSIX `wcwidth(3)` 로 cell width 계산: codepoint 마다 width 합산 → ZWJ family = man(2) + ZWJ(0) + woman(2) + ZWJ(0) + girl(2) = **6 cells** 로 봄. 매 family 마다 ghostty grid 와 *4 cells mismatch*.
>
> - **언제 발생하나?** `Cmd+V` 길게 누름 (macOS key repeat ~30회/초) 으로 ZWJ cluster 를 flood paste 했을 때만. 일반 1 회 paste 는 화면 너비 (cols=133) 에 비해 1 cluster (6 cells) 작아 wrap 안 일어남 → 영향 없음.
> - **왜 줄바꿈 안 됨?** flood 시 bash 의 internal cursor 가 자기 wrap 임계 (cols=133 / 6 cells/family ≈ 22 family) 에 도달 → `\r` (CR) + `\x1b[K` (Erase Line) + redraw sequence 출력 → 우리 grid 가 그것을 수신해 cursor 를 같은 줄 col 0 으로 reset → 다음 paste 가 같은 자리 덮어써짐 → 스크린샷에 한 줄만 보임.
> - **Terminal.app 비교** — Terminal.app 은 family ligature 도 정상 + 줄바꿈도 정상. 추정: Terminal.app 의 cluster 처리는 cell width 를 codepoint sum (6 cells) 으로 reserve + ligature 는 visual 만 합성 → bash wcwidth 와 일치. ghostty 의 Mode 2027 design (cluster = 2 cells) 과 다른 hybrid 방식.
> - **fix path 분석** — A (Mode 2027 OFF): wrap 정상 + family / skin-tone / VS-16 emoji 모두 깨짐 (사람 3명 따로). B (cluster cell width = codepoint sum + visual ligature 합성): wrap 정상 + ligature 정상이나 ghostty 의 grid 동작 변경 필요 (fork / upstream PR), 작업량 큼. C (bracketed paste): bash 3.2 미지원. 본 이슈 우선순위 🟢 (low) — 일반 사용 무영향이라 fix 안 함.
> - **시간이 자연 해소** — Apple 이 macOS default shell 을 zsh 로 이행 중 (bash 3.2 부팅 시 "default 가 zsh" 안내 출력 함). zsh 5.x 의 ZLE 는 grapheme cluster 인식 → bash 3.2 문제 사라짐.
>
> 관련 검색어: `Mode 2027 grapheme cluster wcwidth`, `bash readline emoji width mismatch`, `ZWJ wcwidth POSIX`, `terminal-unicode-core`.

---

## 부록 C — cross-platform 후속 이슈

| 이슈 | 내용 |
|---|---|
| #118 | config schema 통합 (이 문서 §7 의 ❌ 항목 정리) |

---

## 부록 D — 핵심 milestone commit 표

옵션 D (drop-down + 단일 zig 바이너리) 검증의 기록.

| commit | 내용 |
|---|---|
| [`2a2de8e`](https://github.com/ensky0/tildaz/commit/2a2de8e) | macOS #112 마우스 selection + 클립보드 + Metal buffer race fix |
| [`dc5734e`](https://github.com/ensky0/tildaz/commit/dc5734e) | refactor(dialog) cross-platform dialog/messages 모듈화 + About 일반화 |
| [`f63a600`](https://github.com/ensky0/tildaz/commit/f63a600) ~ [`66ebee6`](https://github.com/ensky0/tildaz/commit/66ebee6) | macOS #111 멀티탭 M11.1 ~ M11.7 |
| [`8929649`](https://github.com/ensky0/tildaz/commit/8929649) | macOS About 단축키 Shift+Cmd+I + NSAlert popup level 위 |
| [`4cb29ae`](https://github.com/ensky0/tildaz/commit/4cb29ae) | macOS #113 M13.1 opacity |
| [`506adfe`](https://github.com/ensky0/tildaz/commit/506adfe) | macOS #113 M13.2 theme + COLORFGBG |
| [`2b6c6a2`](https://github.com/ensky0/tildaz/commit/2b6c6a2) | macOS Shift+PgUp/PgDn scrollback |

---

*마지막 업데이트: 2026-05-12 (v0.4.3 — macOS Hanja reconversion UX + renderer/dialog/env/font-chain 후속 정리).
이 문서는 living document — 코드 변경할 때 같은 PR 안에서 update.*
