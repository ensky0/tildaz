# TildaZ cross-platform 동작 사양 (SPEC)

> 공식 표기는 **TildaZ** (대문자 Z). 실행 파일 / 코드 식별자 / 파일 이름 /
> GitHub repo 등 *기술적 식별자* 만 `tildaz` (소문자).

TildaZ 가 Windows · macOS · Linux 에서 *어떻게 동작해야 하는가* 와 *현재 어디까지
구현되어 있는가* 를 한 표로 정리. 코드 변경할 때 같은 PR 안에서 SPEC update —
체크박스가 사실과 어긋나면 review 시점에 발견되도록. (Linux 데스크톱별 동작은 §1.2.)

상태 표기:
- ✅ 구현 + 사용자 환경 검증 통과
- 🟨 부분 구현 / 환경 한계 (별도 이슈에 사유)
- ❌ 미구현 (이슈 # cross-link)
- — 해당 platform 무관

---

## 0. 원칙

1. **세 platform 동등이 목표. 맞출 기준은 Windows 로 자동 고정하지 않는다.**
   Windows 에 있는 기능은 macOS·Linux 에도 동등 구현하고, "마우스 휠로 충분 /
   optional" 같이 특정 platform 만 빠지는 정당화는 안 한다. 다만 동작·시각의 *기준*
   은 명시 사양(이 SPEC 의 표·값, `ui_metrics` 상수)이 있으면 그 사양이고, 사양이
   없는 차이는 어느 한 platform(과거의 "Windows reference")으로 자동 정렬하지 않고
   항목별로 UX 방향을 결정해 사양화한다 (2026-07-12 결정, [#297](https://github.com/ensky0/tildaz/issues/297)).
   결정된 예: 터미널 커서 = 세로 막대(bar), 탭 drag reorder = 드래그 탭이 마우스
   따라 이동. (platform 고유 제약은 — 별도 이슈 + 상태 표기로.)
2. **platform 표준 / native 동작 우선.** cross-platform 일관성보다 *각 platform
   의 표준 / native 사용자 expectation* 을 우선. modifier 순서 (Apple HIG —
   Control → Option → Shift → Command 라 macOS 는 `Shift+Cmd+P` 가 표준,
   `Cmd+Shift+P` 비표준), config / log 위치, 다이얼로그 패턴 모두 platform 표준.
   같은 *기능* 의 단축키가 platform 별로 다른 키 (Windows / Linux `Ctrl+Shift+P`
   ↔ macOS `Shift+Cmd+P`) — Chrome / VS Code 와 동일 패턴.
3. **config schema 동일, default 만 OS-specific.** font / shell 같은 OS-specific
   resource 만 default 값 platform 별 다름. 필드 이름 / 구조 동일 (#118).
4. **검증 후 commit.** 빌드 + smoke 통과만으로 commit 안 함. 사용자 시연 OK
   후에만 commit / amend / push.

---

## 1. 윈도우 / 디스플레이

| 항목 | 동작 정의 | Windows 구현 | macOS 구현 | Linux 구현 | Win | Mac | Linux |
|---|---|---|---|---|---|---|---|
| Drop-down 위치 | 다른 모든 윈도우 위 | `WS_EX_TOPMOST` + `SetWindowPos(HWND_TOPMOST)` | `NSPopUpMenuWindowLevel` (101) | layer-shell 계열 (KWin / wlroots / smithay): `zwlr_layer_shell_v1.get_layer_surface(layer=top)` (L8-α). mutter(GNOME) / muffin(Cinnamon) 은 layer-shell 미지원이라 tildaz 전용 **Shell extension** 이 일반 xdg-shell 창을 잡아 drop-down 으로 배치 ([#228](https://github.com/ensky0/tildaz/issues/228) / [#229](https://github.com/ensky0/tildaz/issues/229), #215 해소). 자세한 DE 별 동작은 §1.2 | ✅ | ✅ | ✅ (layer-shell + extension) |
| 표시 모니터 (멀티모니터) | **마우스 커서가 있는 모니터**에 등장 (drop-down 표준 UX). show() / hotkey toggle show 시 적용 — work-area relayout(해상도/DPI 변화)은 현재 모니터 유지 | show() 시 `MonitorFromPoint(GetCursorPos)` ([window.zig:954](src/window.zig#L954)) | `NSEvent.mouseLocation` 을 포함하는 NSScreen (`screenForCursor`, [host/macos.zig](src/host/macos.zig)) — 없으면 `NSScreen.mainScreen` fallback ([#240](https://github.com/ensky0/tildaz/issues/240)) | layer-shell 계열은 compositor 가 커서 출력에 anchor. mutter/muffin fallback 은 GNOME(#228)/Cinnamon(#229) extension 이 `get_current_monitor()`(커서 모니터)로 배치 | ✅ | ✅ ([#240](https://github.com/ensky0/tildaz/issues/240) — `screenForCursor`, 멀티모니터 실기 검증) | ✅ (extension 계열) |
| Borderless | titlebar / 사각 모서리 | `WS_POPUP` styleMask | `NSWindowStyleMaskBorderless` + `canBecomeKeyWindow` override | layer-shell 본질 — toplevel 없음, decoration 없음 | ✅ | ✅ | ✅ |
| Shadow | 없음 (drop-down 정체) | (default 없음) | `setHasShadow:false` 안 함 (default true 시각 자연) | compositor 결정 (KDE / GNOME 모두 layer-surface 에 shadow 안 적용) | ✅ | ✅ | ✅ |
| 사용자 드래그 차단 | 사용자가 위치 / 크기 변경 못함 | `WS_POPUP` 자연 차단 | `setMovable:false` + non-resizable | layer-shell 본질 — anchor 가 위치 강제, 사용자 drag 불가 | ✅ | ✅ | ✅ |
| Dock 위치 (config) | top / bottom / left / right | `setPosition` | `repositionWindow` | `set_anchor(top\|bottom\|left\|right)` ([c27d470](https://github.com/ensky0/tildaz/commit/c27d470), L8-β) | ✅ | ✅ | ✅ |
| 크기 비율 (config) | width / height percent | `setPosition` | `repositionWindow` | `wl_output.mode` × percent → `set_size` (L8-β) | ✅ | ✅ | ✅ |
| 위치 offset (config) | dock 안 시작 위치 0..100 | `setPosition` | `repositionWindow` | opposing edge anchor + margin (L8-β) | ✅ | ✅ | ✅ |
| Opacity (config) | 0..100 percent → alpha | `SetLayeredWindowAttributes` (LWA_ALPHA) | `NSWindow.setAlphaValue:` | ARGB8888 alpha sweep ([4020879](https://github.com/ensky0/tildaz/commit/4020879), L13-γ) | ✅ | ✅ | ✅ |
| Theme (config) | 16-color palette + bg/fg | `themes.findTheme` → ghostty Terminal.Colors | 동일 | 동일 (cross-platform `themes` 모듈) | ✅ | ✅ | ✅ |
| 단일 탭 시 탭바 | 자리 없음 (Cmd+Q/W 만 종료) | (탭바 항상 표시) | `tabBarHeightPx == 0` 분기 | `Renderer.tabBarHeightPx(tab_count)` 가 count < 2 시 0 반환 (#127). 호출자 `Client.effectiveTabBarHeightPx()` 가 `session.count()` 전달 — mac `tabBarHeightPx(scale)` 의 `g_session.count() < 2 ? 0 : ...` 동등 | ✅ | ✅ | ✅ |
| Live tracking | 모니터 / DPI 변화 시 재적용 | WM_DPICHANGED + `font_change_fn` | NSScreenDidChange notification | `wp_fractional_scale_v1.preferred_scale` event → `applyScale` (L8-δ) | ✅ | ✅ | ✅ |
| Drag-resize 사용자 차단 | 사용자가 크기 못 바꿈 | `WS_POPUP` styleMask | borderless + non-resizable | layer-shell 본질 (위 동등) | ✅ | ✅ | ✅ |

### 1.1 UI metric scaling (cross-platform)

`src/ui_metrics.zig` 의 `*_PT` 상수 = **logical points** (96 DPI 1x 기준 디자인).
각 host 가 자기 *scale factor* 를 곱해 physical pixel 로 변환. 모든 host 가 같은
PT 값 → 같은 *visual* 결과 보장 (DPI / scale 환경 무관).

| 항목 | 값 (PT) | Windows scale | macOS scale | Linux scale |
|---|---|---|---|---|
| Scale source | — | `GetDpiForWindow(hwnd) / 96.0` | `[window backingScaleFactor]` | `wp_fractional_scale_v1.preferred_scale / 120`, 미advertise 시 `wl_output` 정수 scale fallback (#210/#238) |
| Scale 재계산 시점 | — | `WM_DPICHANGED` + startup | `NSScreenDidChange` notification + 매 resize | `preferred_scale` event |
| Storage | — | `App.dpi_scale` + `applyDpiScale(new_dpi)` 가 모든 derived 값 재계산 | `Renderer.scale` + 매 render 시 재읽음 | `Renderer.scale` + `applyScale(scale_num, scale_den)` |
| Font pixel height | `font.size_point` | `font_size_point × dpi/96` | `font_size_point × scale_pt` | `font_size_point × preferred_scale / 120` |
| `TERMINAL_PADDING_PT` | 6 | `App.TERMINAL_PADDING` | `pad_px` | `Renderer.paddingPx()` |
| `SCROLLBAR_W_PT` | 8 | `App.SCROLLBAR_W` | `scrollbar_w_px` | `Renderer.scrollbarWPx()` |
| `SCROLLBAR_MIN_THUMB_H_PT` | 32 | `App.SCROLLBAR_MIN_THUMB_H` | `scrollbar_min_thumb_h_px` | `Renderer.scrollbarMinThumbHPx()` |
| `TAB_BAR_HEIGHT_PT` | 28 | `ui_metrics.tabBarHeightPx(scale)` | 동일 | 동일 |
| `TAB_LABEL_FONT_PT` | 13 | tab 전용 DWrite context + atlas | tab 전용 CoreText context + atlas/texture | tab 전용 FreeType context + glyph cache |
| `TAB_WIDTH_PT` | 150 | `App.TAB_WIDTH` | `tab_w_px = TAB_WIDTH_PT × scale` | `Renderer.tabWidthPx()` |
| `TAB_PADDING_PT` | 6 | `App.TAB_PADDING` | `tab_pad_px` | `Renderer.tabPaddingPx()` |
| `TAB_GAP_PT` | 2 | `tabGapPx(App.dpi_scale)` | `tabGapPx(Renderer.scale)` | `tabGapPx(scale)` 후 정수 px 반올림 |
| `TAB_CLOSE_W_PT` | 24 | `App.TAB_CLOSE_W` | `tabBarLayoutInputs` | `Renderer.tabCloseWPx()` |
| `TAB_ARROW_W_PT` | 24 | `App.TAB_ARROW_W` | `arrow_w_px` | `Renderer.tabArrowWPx()` |
| `TAB_PLUS_W_PT` | 24 | `App.TAB_PLUS_W` | `plus_w_px` | `Renderer.tabPlusWPx()` |

`font.size_point`는 호환성을 위해 유지하는 외부 key 이름이며 물리적인 1/72 inch
point가 아니다. 내부 의미는 logical size이고 실제 raster 크기는 위 표의 OS scale을
적용한다. 실제 mm 보정은 하지 않는다. 폰트 metric에 cell width/line height ratio와
scale을 적용한 최종 cell 정수 크기는 Linux · macOS · Windows 모두 `ceil`한다.

**탭 gap / hover inset**: `TAB_GAP_PT`를 기준으로 각 탭 배경은 좌우에 절반인
1pt, 상하에 2pt를 inset으로 사용한다. 컨트롤 hover 박스는 네 방향에 2pt를
사용한다. 세 host 모두 현재 화면 scale을 곱하며, Linux software renderer는
최종 physical pixel 좌표에서 가장 가까운 정수로 반올림한다.

**탭 제목 font 분리**: 탭 제목·rename cursor·rename preedit은 terminal의
`font.size_point`와 무관한 고정 13 logical pt를 쓴다. 같은 font family/fallback
chain을 사용하되 Linux · macOS · Windows 모두 terminal과 별도인 font context와
atlas/cache를 소유한다. 따라서 terminal font 크기를 바꿔도 탭 제목과 28pt 탭바
높이는 변하지 않는다. `tabBarHeightPx(scale)`는 fractional scale에서도 세 플랫폼이
같은 physical pixel 높이를 쓰도록 최종값을 공통 반올림한다.

**fallback**: Linux 는 `wp_fractional_scale_v1` 미advertise 환경 (mutter / wlroots) 이면
`wl_output` 정수 scale (event opcode 3) 을 fallback 으로 적용한다 (#210/#238). 둘 다 없거나
(정수 scale 도 안 옴) 첫 init 시점에만 `scale = 1.0` default, PT 값 그대로 사용 (기존 1x
환경 동작 보존).

`tab_layout.compute(Inputs)` 의 `tab_w` / `arrow_w` / `plus_w` 도 *scaled* 값을
넣어야 함 (PT 값 직접 넣으면 인접 hit-test 와 좌표 안 맞음). 모든 host 가 위 표의
host-specific getter 호출 결과를 `Inputs` 에 채워서 전달.

---

## 1.2 Linux 데스크톱(Wayland) 지원

tildaz 는 **Wayland 전용** (X11 backend 없음 — §0 / ARCHITECTURE 의 Design Choices
참조). DE 는 *이름* 보다 **compositor (+ `wlr-layer-shell` 가용성)** 카테고리로
묶인다. drop-down(quake) 은 layer-shell 또는 Shell extension, hotkey 자동 적용은
카테고리별로 메커니즘이 다르다.

### Desktop Matrix

| compositor 카테고리 | layer-shell drop-down | hotkey 자동 적용 메커니즘 | 대표 DE | 상태 |
|---|---|---|---|---|
| **KWin** | ✅ layer-shell | portal `GlobalShortcuts` + `kglobalaccel` takeover | KDE Plasma | ✅완료 (실기 확인) |
| **wlroots** | ✅ layer-shell | sway = `bindsym` i3-ipc→`tildaz --toggle N`, Hyprland = `hyprctl keyword bind`→`--toggle N` (portal 우회) | sway / Hyprland (Wayfire / river / niri 동계열) | ✅완료 (sway / Hyprland 실기 확인) |
| **mutter** | tildaz 전용 Shell extension (xdg-shell 창 배치) | gsettings custom keybinding (libgio) + extension 충돌 시 자동 skip | GNOME (Ubuntu / Budgie / Pantheon 동계열) | ✅완료 (실기 확인) |
| **muffin** | tildaz 전용 Shell extension | gsettings custom keybinding (Cinnamon strv schema) + extension 충돌 skip | Cinnamon | ✅완료 (실기 확인) |
| **smithay** | ✅ layer-shell | RON custom shortcut→`tildaz --toggle N` (portal-cosmic GlobalShortcuts 미구현) | COSMIC | ✅완료 (실기 확인) |
| **X11 전용** | — (Wayland 아님) | — | XFCE / MATE / LXDE | **범위 밖** (별도 backend 필요) |

### Support Tier 정의

Linux 지원 수준은 desktop 이름이 아니라 실제 capability + 검증 결과로 표현한다.

| Tier | 의미 |
|---|---|
| **Full** | global toggle, monitor-aware drop-down placement, tabbed terminal, Unicode rendering, clipboard, config parity, IME behavior 가 그 desktop 에서 cross-platform spec 을 만족 |
| **Limited** | terminal 은 사용 가능하나 true drop-down layer / global shortcut / IME pre-edit / desktop integration 중 하나 이상이 없거나 미검증 |
| **Unsupported** | baseline Wayland window 를 못 열거나 terminal session 을 실행 못 함 |

### DE 별 동작 (요약)

- **KWin (KDE Plasma).** layer-shell drop-down. hotkey 는 portal `GlobalShortcuts`
  로 등록하고, 그 키를 이미 다른 component 가 쓰고 있으면 `kglobalaccel`
  `setForeignShortcut` 로 그 키만 회수(takeover)한 뒤 우리 binding 적용 — config 가
  source of truth. launcher 는 KGlobalAccel component 목록에서 정확히
  `tildaz.instanceN`인 항목만 비교해 config 에 없는 번호의 `toggle-N` action 을
  증분 해제한다. drop-down 재표시는 KWin 만 `#205` unmap/remap 워크어라운드(아래
  부록 B 참조).
- **sway (wlroots).** GlobalShortcuts portal 미지원이라 portal `Activated` 가 안 옴
  → `$SWAYSOCK` 의 i3-ipc `RUN_COMMAND` 로 `bindsym <accel> exec <self_exe> --toggle N`
  를 런타임 등록. hotkey 실동작은 번호별 socket (`$XDG_RUNTIME_DIR/tildaz-N.sock`).
  runtime-only 라 매 실행 등록 = config 가 source of truth. 단 sway IPC 는 현재
  binding 열거 요청을 제공하지 않아 세션 중 stale binding 증분 제거는 지원하지
  않는다. config 삭제/변경 전에 등록된 binding 은 sway 세션 재시작 때 사라진다.
- **Hyprland (wlroots).** layer-shell drop-down 은 sway 와 같은 경로(코드 동일).
  hotkey 는 portal 우회 — 실행 시 `hyprctl -j binds` actual 과 config desired 를
  비교해 TildaZ `--toggle N` binding 의 차이만 `unbind/bind`한다. `install.sh`는
  `~/.config/hypr/` config의
  autostart만 관리한다. drop-down 은 `on_demand`
  keyboard interactivity 로 클릭-어웨이 허용. XDG autostart 미지원이라 autostart 도
  config 의 `exec-once` 로.
- **COSMIC (smithay).** layer-shell drop-down. hotkey 는 RON custom shortcut
  (`~/.config/cosmic/.../custom`) 의 TildaZ 전용 항목을 config_N 전체에 맞춰
  `Spawn("tildaz --toggle N")`로 원자적 갱신하되, 기존 bytes 와 같으면 write/rename 을
  생략한다(portal-cosmic GlobalShortcuts 미구현). XDG autostart 는 지원.
- **GNOME / Cinnamon (mutter / muffin).** layer-shell 미지원이라 TildaZ 본체는 평범한
  xdg-shell client (`app_id="tildaz.instanceN"`) 로 두고, **Shell extension** 이 창을 잡아
  drop-down 배치 + 토글 + 창 목록 숨김(Alt-Tab / taskbar / window-list / Expo)을
  담당. hotkey 는 gsettings custom keybinding 으로 자동 등록(extension 활성 시
  중복 grab 회피로 gsettings 등록 skip). launcher 는 config 에 없는 numbered
  GSettings 항목만 제거하고, Shell extension 은 config directory 변경을 감시해
  index/accelerator 차이만 remove/add한다. config 가 source of truth. 숨김(minimize)
  시 extension 이 keyboard focus 를 MRU 다음 창으로 넘긴다 — mutter/muffin 이
  sticky+above 인 tildaz 를 minimize 해도 focus 를 자동 이양하지 않아, 안 그러면
  숨김 중에도 client 가 키를 계속 받아 Alt+Enter 토글 + 타이핑이 새어든다 (#247).

**drop-down 재표시 정책.** 기본은 hide 시 surface destroy → 다음 show 에서
재생성(destroy/recreate, 모든 compositor 일관). 예외는 **KWin 한 곳** — surface 를
유지하는 `#205` unmap/remap 워크어라운드(KWin Bug 503121 의 surface 재생성 지연
회피). cosmic-comp(smithay) 이 remap 미지원이라 일반화하지 않고 그 버그가 있는
compositor 에만 둔다. mutter / muffin 은 layer-shell 이 아니라 extension 의
minimize/restore.

---

## 2. 키바인딩 매트릭스

같은 *기능* 의 단축키가 platform 별로 다른 modifier — Windows `Ctrl+` / macOS `Cmd+` 표준.

### 2.1 글로벌 hotkey (앱 단위)

| 동작 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|
| 윈도우 토글 (drop-down) | config_N별 hotkey (`RegisterHotKey`) | config_N별 hotkey (CGEventTap) | config_N별 portal `GlobalShortcuts.BindShortcuts` + portal 미가용 환경에선 `tildaz --toggle N` Unix socket IPC ([9803c62](https://github.com/ensky0/tildaz/commit/9803c62), #198) | ✅ | ✅ | ✅ |
| 앱 종료 | Alt+F4 | Cmd+Q (mainMenu Quit) | Alt+F4 (Win 동등 native — Linux desktop 표준). `self.running = false` 로 main loop break | ✅ | ✅ | ✅ |

### 2.2 탭 관리

| 동작 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|
| 새 탭 | Ctrl+Shift+T | Cmd+T | Ctrl+Shift+T (L12-β) | ✅ | ✅ | ✅ |
| 활성 탭 닫기 | Ctrl+Shift+W | Cmd+W | Ctrl+Shift+W (L12-β) | ✅ | ✅ | ✅ |
| 인덱스 점프 (1..9) | Alt+1..9 ([`window.zig:1604-1612`](src/window.zig#L1604-L1612)) | Cmd+1..9 | Alt+1..9 ([a60fb8e](https://github.com/ensky0/tildaz/commit/a60fb8e)) | ✅ | ✅ | ✅ |
| 이전 탭 | Ctrl+Shift+[ | Shift+Cmd+[ | Ctrl+Shift+[ (L12-β) | ✅ | ✅ | ✅ |
| 다음 탭 | Ctrl+Shift+] | Shift+Cmd+] | Ctrl+Shift+] (L12-β) | ✅ | ✅ | ✅ |

### 2.3 클립보드

| 동작 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|
| 복사 (단축키) | Ctrl+Shift+C | Cmd+C | Ctrl+Shift+C ([dfcf9f4](https://github.com/ensky0/tildaz/commit/dfcf9f4), L6) | ✅ | ✅ | ✅ |
| 복사 (드래그 selection 후 자동) | `selection.finish()` → `copyToClipboard` | 동일 (`tildazMouseUp` 분기) | 동일 (Wayland `wl_data_source` + selection.finish, [1bcdbc9](https://github.com/ensky0/tildaz/commit/1bcdbc9)) | ✅ | ✅ | ✅ |
| 붙여넣기 (단축키) | Ctrl+Shift+V | Cmd+V | Ctrl+Shift+V ([dfcf9f4](https://github.com/ensky0/tildaz/commit/dfcf9f4)) | ✅ | ✅ | ✅ |
| 붙여넣기 (마우스 우클릭) | `WM_RBUTTONDOWN` → `pasteClipboard` (cmd.exe console 표준 패턴) | 동일 (`tildazRightMouseDown` → `handlePaste`) | `wl_pointer.button` BTN_RIGHT → `wl_data_offer.receive` → PTY ([dfcf9f4](https://github.com/ensky0/tildaz/commit/dfcf9f4)) | ✅ | ✅ | ✅ |

### 2.4 About 다이얼로그

| 동작 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|
| About 표시 | Ctrl+Shift+I (`MessageBoxW`) | Shift+Cmd+I (mainMenu keyEquivalent + NSAlert) | Ctrl+Shift+I (Win 동등 native) — `about.showAboutDialog()` → 별 layer-shell `overlay` surface (§6 step 3, #203) | ✅ | ✅ | ✅ |

### 2.5 스크롤 / 화면 reset

| 동작 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|
| 한 페이지 위 (scrollback) | Shift+PgUp | Shift+PgUp | Shift+PgUp — `session.scrollActive(.{ .page = .up }, visible_rows)`. wheel 분기와 같은 통로 | ✅ | ✅ | ✅ |
| 한 페이지 아래 | Shift+PgDn | Shift+PgDn | Shift+PgDn — 동상 (`.page = .down`) | ✅ | ✅ | ✅ |
| 화면 reset (활성 탭) | Ctrl+Shift+R | Shift+Cmd+R | Ctrl+Shift+R — `session.resetActive()` = `terminal.fullReset()` + `\\x0c` (Ctrl+L) 송신 ([#214](https://github.com/ensky0/tildaz/issues/214)) | ✅ | ✅ | ✅ |

### 2.6 Ctrl+key PTY 전달 (control char)

| 동작 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|
| Ctrl+C → SIGINT (\\x03) | `WM_CHAR` 자동 ASCII control char | NSEvent.characters 직접 PTY write | xkb modifier check + utf8 fallback ([dfcf9f4](https://github.com/ensky0/tildaz/commit/dfcf9f4)) | ✅ | ✅ | ✅ |
| Ctrl+A ~ Ctrl+Z 일반 control | 동일 | 동일 (Ctrl+] tag jump, Ctrl+W vim window 등) | 동일 (xkb ctrl modifier compose) | ✅ | ✅ | ✅ |
| 한글 IME 조합 중 Ctrl+C | (해당 없음) | `discardMarkedText` + preedit overlay 비움 + \\x03 직송 — shell 의 "입력 라인 버리기" 의도와 일관 | text-input-v3 reset + preedit_buf 비움 + \\x03 ([5f55caa](https://github.com/ensky0/tildaz/commit/5f55caa), L10-γ) | — | ✅ | ✅ |

### 2.7 Key repeat (길게 누름 반복)

| 항목 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|
| 영어/숫자/기호 길게 누름 → 반복 입력 | OS default | `ApplePressAndHoldEnabled = false` 우리 앱 도메인에 등록 — 안 등록하면 system 이 accent picker (à á â) 띄우려 repeat 막음 | client-side timer (compositor `wl_keyboard.repeat_info` 의 rate / delay 따름, [5455d54](https://github.com/ensky0/tildaz/commit/5455d54), L12-γ-5). focus 떠날 때 / key release 시 즉시 disarm | ✅ | ✅ | ✅ |
| 한글 자모 길게 누름 → 반복 입력 | (해당 없음) | IME 경로라 PressAndHold 영향 없음 (자동) | `wl_keyboard.key` 가 IME 로 라우팅됨 — fcitx5 / ibus 자체 key repeat 동작 (compositor `repeat_info` 가 IME 측에 적용). 사용자 일상 사용 OK 확인 (Cinnamon Wayland + fcitx5-hangul, KDE Plasma 6 + KWin). | — | ✅ | ✅ |

### 2.8 전체화면 토글 (윈도우 단위)

| 동작 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|
| 전체화면 — taskbar/dock **덮음** | Alt+Enter | Cmd+Enter | Alt+Enter — layer-shell DE(KWin/sway/Hyprland/COSMIC)는 4-edge anchor + size 0 + `exclusive_zone=-1` 로 패널 위까지 덮음; GNOME/Cinnamon(layer-shell 부재)은 `xdg_toplevel.set_fullscreen` ([#87](https://github.com/ensky0/tildaz/issues/87)) | ✅ | ✅ | ✅ |
| 전체화면 — taskbar/dock **회피** | Shift+Alt+Enter | Shift+Cmd+Enter | Shift+Alt+Enter — layer-shell 은 `exclusive_zone=0` (패널 유지); GNOME/Cinnamon 은 `xdg_toplevel.set_maximized` ([#87](https://github.com/ensky0/tildaz/issues/87)) | ✅ | ✅ | ✅ |
| 같은 키 재입력 → dock 복귀 / 다른 모드 → no-op | Alt+Enter↔Shift+Alt+Enter | Cmd+Enter↔Shift+Cmd+Enter | 동일 (`FullscreenMode {none,cover,avoid}` toggle 로직 — Win 동등) | ✅ | ✅ | ✅ |
| 토글된 fullscreen **상태**가 F1 hide→show 간 유지 | ✅ | ✅ | layer-shell 은 `fullscreen_mode` 필드로 show 시 재적용; GNOME/Cinnamon 은 compositor 가 minimize↔복원 간 maximize/fullscreen 보존 | ✅ | ✅ | ✅ |

> **숨김(hide) 상태에선 전체화면 토글 no-op** — 보이는 창에만 적용되는 윈도우 동작. Win/Mac 은 숨김 시 창이 keyboard focus 를 잃어 키 미수신으로 자연 보장. Linux layer-shell DE 도 hide 시 surface 를 파괴해 키가 안 와 동일 보장. GNOME/Cinnamon 은 mutter/muffin 이 sticky+above 인 tildaz 를 minimize 해도 focus 를 자동 이양하지 않으므로, extension 이 hide 시 keyboard focus 를 다른 창으로 넘겨 동일 보장한다 — 숨김 중엔 Alt+Enter 토글뿐 아니라 모든 키 입력이 tildaz 로 안 들어간다 ([#247](https://github.com/ensky0/tildaz/issues/247)).

---

## 3. 마우스 동작

| 동작 | 위치 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|---|
| 셀 selection (drag) | cell 영역 | mouseDown + mouseMove + mouseUp | 동일 (`tildazMouseDown/Dragged/Up`) | wl_pointer button/motion → 같은 selection 모듈 ([fc3b5bb](https://github.com/ensky0/tildaz/commit/fc3b5bb)) | ✅ | ✅ | ✅ |
| 더블클릭 word selection | cell 영역 | `mouse_double_click` → `selectWord` | 동일 (`tildazMouseDown` clickCount >= 2) | 동일 ([eea926d](https://github.com/ensky0/tildaz/commit/eea926d), L6.7 — 500ms 같은 cell 검사 후 `selectWord`) | ✅ | ✅ | ✅ |
| 더블클릭 후 자동 copy | cell 영역 | `selectWordAt` 안에서 `copyToClipboard` | 동일 — `selectWord` 후 `handleCopy` | 동일 (Wayland `wl_data_source`) | ✅ | ✅ | ✅ |
| selection finish 후 자동 copy | cell 영역 | `selection.finish()` → `copyToClipboard` | 동일 (`tildazMouseUp` 분기) | 동일 ([1bcdbc9](https://github.com/ensky0/tildaz/commit/1bcdbc9)) | ✅ | ✅ | ✅ |
| word selection 동작 사양 | cell 영역 | cross-platform 단일 모듈 ([terminal_interaction.zig:95](src/terminal_interaction.zig#L95)) | 동일 모듈 | 동일 모듈 (cross-platform `terminal_interaction`) | ✅ | ✅ | ✅ |
| 우클릭 paste | 어디든 | `WM_RBUTTONDOWN` → `pasteClipboard` | `tildazRightMouseDown` → `handlePaste` | `wl_pointer.button` BTN_RIGHT → `wl_data_offer.receive` ([dfcf9f4](https://github.com/ensky0/tildaz/commit/dfcf9f4)) | ✅ | ✅ | ✅ |
| 휠 / 트랙패드 scroll | 셀 영역 | `WM_MOUSEWHEEL` → `scrollViewport` | `tildazScrollWheel` → 동일 | `wl_pointer.axis` → 동일 ([fc3b5bb](https://github.com/ensky0/tildaz/commit/fc3b5bb)) | ✅ | ✅ | ✅ |
| 스크롤바 클릭 + 드래그 | 우측 가장자리 | `mouse.x >= client_w - SCROLLBAR_W` → `scrollToY` | 동일 (`scrollbarScrollToY`, Windows 패턴 그대로) | 동일 ([e671b02](https://github.com/ensky0/tildaz/commit/e671b02), L6.6 — Windows 패턴 그대로) | ✅ | ✅ | ✅ |
| viewport 이동 시 selection 유지 | 어디든 | ghostty `Selection` 이 `Pin` (page list 절대 위치) 기반 — viewport 는 보는 창문 | 동일 (같은 ghostty 모듈) | 동일 (같은 ghostty 모듈) | ✅ | ✅ | ✅ |
| 탭바 — 탭 클릭 | 상단 탭 영역 | `handleTabClick` → `setActiveTab` | 동일 (`tabBarHitTest`) | 동일 (L12-β, cross-platform `tab_interaction`) | ✅ | ✅ | ✅ |
| 탭바 — × 클릭 (**활성 탭 닫기**) | 탭바 우측 끝 고정 `×` 버튼 ([#268](https://github.com/ensky0/tildaz/issues/268) — per-tab close 제거, 탭 전환 misclick 방지). `[탭들][×][+]` (`+` 가 최우측 구석 — 구석의 × 는 창 닫기로 읽힘 + Fitts 상 빈번한 + 가 구석 적합, 사용자 결정), 화살표 시 `[<][탭들][>][×][+]`. `×` 는 U+00D7 (\'+\' 와 같은 연산자 계열 글리프 — 크기/중심 일치). 탭 본체 클릭은 어디든 전환만 | `handleTabClick` `.close` → `closeTab(activeIndex)` | `.close` → `handleCloseActiveTab` (Cmd+W 와 동일 helper). 스크롤바 클릭 판정은 탭바 아래 (y ≥ tab_bar_h) 만 — `×` 버튼과 x 밴드 겹침 (시연 발견) | `.close` → `closeIndex(activeIndex)` + `ensureSessionGrid` | ✅ | ✅ | ✅ |
| 탭바 — drag reorder | 탭 본체 drag | `DragState` (5px 임계) → `reorderTabs` | 동일 (`g_drag`) | 동일 (L12-γ-3, [4f7e724](https://github.com/ensky0/tildaz/commit/4f7e724)) | ✅ | ✅ | ✅ |
| 탭바 — drag follow 시각 | drag 중 탭 마우스 따라 이동 ([#297](https://github.com/ensky0/tildaz/issues/297) B3 결정. source 슬롯엔 탭바 배경이 남아 원위치 표시. z-order 최상위는 macOS 만 — Windows/Linux 는 그리기 순서대로) | `dragged_tab + drag_x` 인자 | 동일 (`TabDragView`, drag 탭 bg 마지막에 그려 z-top) | 동일 (#297 B3 — 이전의 source dim + drop indicator 방식 폐기) + 가장자리 auto-scroll | ✅ | ✅ | ✅ |
| 탭바 — 더블클릭 rename | 탭 본체 더블클릭 | `RenameState.begin` | 동일 (`g_rename`) | 동일 (L12-γ-2, [04cec33](https://github.com/ensky0/tildaz/commit/04cec33)) | ✅ | ✅ | ✅ |
| 탭바 — 셸 OSC 0/2 자동 제목 ([#269](https://github.com/ensky0/tildaz/issues/269)) | 탭 제목. 새 탭은 제목 없이 시작하고, 1초 안에 non-empty OSC가 없을 때만 `Tab N` fallback 표시. 1초 직전에 OSC가 도착해 pending 중이면 fallback을 끼워 넣지 않음. 셸이 보낸 raw window title 이 150ms 동안 동일하게 유지되면 반영 (짧은 명령의 순간 왕복 억제). 초기 상태가 끝난 뒤 빈 title 은 최초 `Tab N` 으로 복귀. 사용자가 더블클릭 rename 한 뒤에는 수동 제목이 우선. 활성 탭과 비활성 탭 출력을 공통 8ms frame 예산 안에서 번갈아 파싱하므로 탭 전환 없이 제목 갱신 | readonly VT parse 뒤 `Terminal.getTitle()` 동기화 (#266 의 ConPTY query-response 차단 유지) | `Effects.title_changed` → 공통 pending 제목 상태 | `Effects.title_changed` → 공통 pending 제목 상태 | ✅ | ✅ | ✅ |
| 탭바 — 긴 확정 제목 truncate ([#271](https://github.com/ensky0/tildaz/issues/271)) | text 영역을 넘으면 glyph 경계에서 자르고 마지막에 U+2026 `…` 한 글자(1 cell) 표시. CJK wide glyph를 반으로 자르지 않으므로 최대 1 cell이 남을 수 있음. rename 중에는 ellipsis 없이 cursor follow scroll | 공통 `tab_layout.iterTabText` → 일반 Unicode glyph path | 동일 | 동일 | ✅ | ✅ | ✅ |
| 탭바 — `<` / `>` 화살표 클릭 | 탭바 양 끝 화살표 (#117) | `scrollTabsByArrow` — viewport 만 1 탭 너비씩 이동, **활성 탭 안 바뀜** + `tab_scroll_user_override=true` | 동일 (`scrollTabsByArrow`) | 동일 (L12-γ-1, [1eb51ee](https://github.com/ensky0/tildaz/commit/1eb51ee) — cross-platform `tab_layout`) | ✅ | ✅ | ✅ |
| 탭바 — `+` 클릭 | `>` 안쪽 새 탭 (#117) | 새 탭 생성 → 활성 → ensure 가 viewport 우측 끝으로 정렬 | 동일 | 동일 (L12-γ-1) | ✅ | ✅ | ✅ |
| OS mouse cursor shape (#193) | 아래 §3.1 표 참고 | `WM_SETCURSOR` 가 `App.cursorRegion` 호출 → `IDC_IBEAM` 또는 `IDC_ARROW` `SetCursor` ([src/window.zig](src/window.zig)) | NSView `resetCursorRects` 가 cell rect 에 `NSCursor.IBeamCursor` add ([src/host/macos.zig](src/host/macos.zig) `tildazResetCursorRects`) | `wp_cursor_shape_v1.set_shape(serial, text=9 / default=1)` ([ab8e4b9](https://github.com/ensky0/tildaz/commit/ab8e4b9), #193). compositor advertise 미지원 환경 graceful degrade | ✅ | ✅ | ✅ |
| z-order 양보 on focus loss (#195) | 다른 app 활성화 시 우리 z-order *level* 만 떨어뜨려서 그 app 이 위로. 우리는 *visible 유지* (hide 안 함, 다른 app 뒤에 보임). 다시 우리 app 활성화 시 원래 level 복귀. **Linux 미적용 — layer-shell categorical 한계, 아래 note** | `WM_ACTIVATEAPP wParam=0` → `SetWindowPos(HWND_NOTOPMOST)`, wParam=1 → `SetWindowPos(HWND_TOPMOST)` ([src/window.zig](src/window.zig)) | `applicationDidResignActive:` → `setMainWindowLevel(NSNormalWindowLevel)`, `applicationDidBecomeActive:` → `setPopupWindowLevel()` ([src/host/macos.zig](src/host/macos.zig)) | **❌ platform-limit** — layer-shell 의 4 단계 categorical layer (background/bottom/top/overlay) 가 normal app z-order 와 mix 안 됨. layer=top + exclusive 유지 ([f19a1d6](https://github.com/ensky0/tildaz/commit/f19a1d6), 아래 §3.1 note 참조) | ✅ | ✅ | ❌ (platform-limit) |

### 3.1 OS mouse cursor shape (#193) — 영역별 정의

| 영역 | hover 시 cursor | 비고 |
|---|---|---|
| 셀 (terminal grid) 영역 | I-beam | rename / preedit / 기타 상태 무관, 셀 영역은 *항상* 텍스트 편집 컨텍스트 |
| 탭바 — rename 활성 탭의 *text 입력 영역* | I-beam | rename 진입 (더블클릭) 이후 그 탭의 text 영역만 텍스트 편집 컨텍스트. #268 로 per-tab close 가 사라져 탭 내부 전체가 text 영역 |
| 탭바 — 우측 끝 `+` / `×` 버튼 | arrow | 버튼 성격 — 클릭 = 새 탭 / 활성 탭 닫기 (#268) |
| 탭바 — 비활성 탭 본체 / 활성 탭 본체 (rename 비활성) / `<` / `>` / `+` / 빈 영역 / drag 중 | arrow | 탭바의 기본 — 클릭 / 더블클릭 / drag 등 *버튼* 성격 영역 |
| 스크롤바 (우측 8 PT) | arrow | drag-to-scroll 버튼 |
| 윈도우 padding / 가장자리 | arrow | terminal_padding 영역 |
| 윈도우 가장자리 (system non-client) | OS 기본 | 우리가 안 건드림 (Win: HTBORDER 등은 `DefWindowProc` 처리, mac: borderless 라 가장자리 없음, Linux: layer-shell 가장자리 없음) |

> **참조 비교:** iTerm2 / Terminal.app 동등 패턴 — 셀 항상 I-beam, 탭바 평상 arrow, 탭 rename 더블클릭 시 그 탭 text 만 I-beam. VSCode / Chrome 탭바는 rename 없어 항상 arrow.

> **z-order 양보 — Linux 미적용 (#195):** Linux Wayland 의 `zwlr_layer_shell_v1` 은 *categorical* 4 단계 (background / bottom / top / overlay) 라 *normal xdg_toplevel z-order level* 자체가 없음. `set_layer(bottom)` 으로 떨어뜨려도 *desktop wallpaper 바로 위 + 모든 일반 windows 아래* — 사용자 의도 (*다른 새 창 → tildaz → 그 외*) 와 어긋남 (tildaz 가 모든 일반 windows 아래로 가버림). mac `NSWindow.setLevel(NSNormalWindowLevel)` / Win `SetWindowPos(HWND_NOTOPMOST)` 은 우연히 *normal app z-order* 와 mix 자연이라 한 줄 toggle 로 완벽 — Linux 의 categorical 한계 우회 불가. *layer-shell destroy + xdg_toplevel 재생성* 도 시도 가능하나 DE / compositor 마다 동작 다양 + animation glitch + 매 toggle 마다 수십~수백 ms latency 라 사용자가 알아챔. 회피 — layer=top + `keyboard_interactivity=exclusive` 유지. drop-down 본분 (yakuake / guake / Tilda 등 모든 Linux drop-down 동등 한계). 사용자가 hotkey 로 hide 후 다른 app 사용.

> **`<` / `>` 화살표 vs 활성 탭 — Firefox 패턴 (#117):**
>
> 1. `<` / `>` 클릭은 *viewport 스크롤 전용* — 활성 탭은 절대 안 바뀜. 사용자가 "다른 탭 *목록* 을 보러 왔다" 는 명시 의도이지 활성 전환 의도 아님.
> 2. 활성 변경 트리거는 **탭 클릭 / Alt+숫자 / Ctrl+Shift+[ / Ctrl+Shift+] (Win) / Cmd+숫자 / Shift+Cmd+[ / Shift+Cmd+] (mac) / `+` (새 탭)** 만.
> 3. `<` / `>` 누르는 순간 `tab_scroll_user_override = true` set → 매 frame `ensureActiveTabVisible` skip → 활성 탭이 viewport 밖이어도 그대로. 활성 변경 / 새 탭 / drag reorder 끝나는 시점에 false 로 reset 되어 ensure 재가동.
> 4. 활성 변경 시 viewport 동작: 활성 탭이 이미 보이면 그대로 (색깔만 변경), 안 보이면 보이는 가장 가까운 위치로 *minimum* 이동 (Chrome / Firefox 동등).
>
> **word selection 동작 사양 (cross-platform 단일 구현):** [`terminal_interaction.zig:95`](src/terminal_interaction.zig#L95)
>
> 1. **boundary 문자 목록**: space / tab / 따옴표 / 백틱 / 파이프 / `: ; ( ) [ ] { } < >`
> 2. **시작 cell 이 boundary** (공백 / 따옴표 / 구두점) → 선택 안 함 (false 반환). iTerm2 / Terminal.app 동등 — 터미널에서 공백 더블클릭은 의도가 아님. ghostty default 는 boundary 끼리도 묶지만 우리는 reject.
> 3. **시작 cell 이 word body** → 양쪽으로 boundary 문자 만나기 직전까지 확장.
> 4. **wide char (한/中/日 등) 처리**:
>    - `spacer_tail` cell (글자의 right-half) 위 클릭 → main cell (left-half) 로 정규화 후 진행.
>    - 확장 중 `spacer_tail` 만나면 boundary 검사 *skip* 하고 다음 cell 로 진행 — wide char 가 word body 의 continuation 이므로 음절 사이에서 끊기지 않음.
>
> 우리가 ghostty `screen.selectWord` 를 그대로 쓰지 않고 [`terminal_interaction.selectWord`](src/terminal_interaction.zig#L95) 로 직접 구현한 이유: ghostty 가 spacer_tail 을 boundary 처럼 취급해 한글 단어가 음절마다 끊기는 문제 (#122 시연 중 발견).

---

## 4. 탭 lifecycle

| 항목 | 동작 정의 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|---|
| 컬렉션 | `ArrayList(*Tab)` + `active_tab: usize` | `SessionCore` | `SessionCore` (v0.4.0+ 통합) | `SessionCore` 동일 (L12-α [2455c7e](https://github.com/ensky0/tildaz/commit/2455c7e)) | ✅ | ✅ | ✅ |
| 새 탭 크기 | 활성 탭의 cols/rows 와 동일 | `createTab(cols, rows, ...)` | 동일 | 동일 | ✅ | ✅ | ✅ |
| 단일↔멀티 전환 시 cell 영역 동기화 | 양쪽 모두: 단일 탭 시 탭바 자리 없음 → 전환 시 cell 영역 변화 → 모든 탭 cols/rows 재계산 (#127 으로 Windows 도 동등). | `effectiveTabBarHeight()` + `createTab` / `handleCloseResult` 의 `resizeAll` | `syncTerminalGeometry` 호출 | `handleNewTab` / `handleCloseTab` / `drainExitedTabs` / `handleTabBarClick` (close 'x') 직후 `Client.ensureSessionGrid()` 호출 — 모든 탭 cols/rows 재계산 (#127). mac `syncTerminalGeometry` 동등 | ✅ | ✅ | ✅ |
| 활성 인덱스 자동 조정 (close) | 닫힌 탭이 활성 앞이면 -1, 활성 자체였으면 새 마지막으로 | `nextActiveIndexAfterClose` | `closeTab` 안 동일 정책 | 동일 (SessionCore 공통) | ✅ | ✅ | ✅ |
| PTY exit → 그 탭만 정리 | read thread → main thread 안전 | `WM_TAB_CLOSED` post + `closeTabByPtr` | `Tab.exit_flag` atomic + `drainExitedTabs` | 동일 (Linux PTY `Tab.exit_flag` atomic) | ✅ | ✅ | ✅ |
| 마지막 탭 종료 → 앱 종료 | count == 0 시 | `closeAfterShellExit` | `NSApp.terminate:` | wayland event loop break + `exit(0)` | ✅ | ✅ | ✅ |
| Drag reorder 5px 임계 | drag 가 5px 미만 = click | `DragState.move` | 동일 (cross-platform `tab_interaction.zig`) | 동일 모듈 (L12-γ-3) | ✅ | ✅ | ✅ |
| Rename — cursor 표시 | always-visible 1px vertical bar | `cursor_instances` | 동일 (`drawTabBar`) | 동일 (`drawTabBar` cross-platform) | ✅ | ✅ | ✅ |
| Rename — IME UTF-8 입력 | 한글 / 일본어 등 multi-byte | `RenameState.insertCodepoint` | 동일 (`imeInsertText` rename 분기) | 동일 (`zwp_text_input_v3.commit_string` → RenameState, L12-γ-2) | ✅ | ✅ | ✅ |
| Rename — IME preedit 위치 | 탭바 cursor 옆 inline (보라 배경) | `WM_IME_*` 가로채기 + `ImmGetCompositionStringW` + renderer overlay (#164 v0.4.0) | `drawTabBar` 의 preedit 인자 | text-input-v3 preedit_string → `drawTabBar` overlay (L12-γ-2, foot 패턴) | ✅ | ✅ | ✅ |
| Rename — 마우스 클릭 cursor 이동 | 같은 탭 text 영역 클릭 → cursor 이동 (commit X). 다른 영역 → commit. preedit 활성 시 manual commit + IME state cancel. | `tryRenameClickMoveCursor` + `imeCancelComposition` (#164 v0.4.0) | `tryRenameClickMoveCursor` + `discardMarkedText` 동일 | `tryRenameClickMoveCursor` + text-input reset (L12-γ-2) | ✅ | ✅ | ✅ |
| Rename — preedit 가운데 입력 push-right | cursor 뒤 main text 가 preedit advance 만큼 우측 이동, commit 시 자연 삽입 | `x_off += preedit_advance_total` (#164 v0.4.0) | 동일 (`text_x += preedit_advance_total`) | 동일 (cross-platform `drawTabBar`) | ✅ | ✅ | ✅ |
| Rename — cursor follow scroll reserve | 1 cell (cw) 고정. preedit 폭은 별도 합산하고 활성/비활성 모두 같은 reserve 유지 → typing/commit 때 cursor 안정 + 좌우 여백 비대칭 축소 (#271) | `tab_layout.cursorReserve` / `cursorScrollOffset` (#163 v0.4.0 helper) | 동일 (양쪽 같은 helper) | 동일 (cross-platform `tab_layout`) | ✅ | ✅ | ✅ |
| Rename — MAX_TABS 32 한도 + dialog | `+` layout 자동 사라짐 + 단축키 시 dialog | `tab_actions.checkAtLimitAndDialog` (#159 v0.4.0) | 동일 (양쪽 같은 helper) | 동일 helper — dialog UI 는 §6 step 3 후 layer-shell overlay (#203) | ✅ | ✅ | ✅ |
| Rename — IME 후보 popup 위치 / 한자 치환 | cursor 옆 자연 추적 (한자 / kanji / hanzi). macOS Option+Return 은 조합 중 한글을 먼저 rename buffer 에 commit 한 뒤 후보창을 즉시 띄우고, 후보 확정 시에만 원래 한글 range 를 선택 한자로 치환. Esc / focus loss 는 원래 한글 유지. | `ImmSetCompositionWindow(CFS_POINT, cursor_pixel)` 매 frame (#164 v0.4.0) | `NSTextInputClient.firstRectForCharacterRange` 가 tab rename snapshot 기준 rect 반환 + `insertText:replacementRange:` 로 range 치환 (#166, #190 v0.4.3) | `zwp_text_input_v3.set_cursor_rectangle` 가 IME 후보 popup 위치 — `updateCursorRectangle` 가 `physicalToLogical` 변환 적용 (L10-γ + 사용자 시연 fix). *입력 확정된 한글* 의 한자 변환은 §5 표 참조 (❌ platform-limit) | ✅ | ✅ | 🟨 (cursor 위치 ✅ / 입력 확정된 한글의 한자 변환 ❌ — §5 행) |
| Rename auto-commit on focus loss | 아래 §4.1 통합 표 참조 — 모든 focus_loss = commit, Esc 만 cancel | (각 host 의 호출 site) | (각 host 의 호출 site) | (각 호출 site — §4.1 참조) | ✅ | ✅ | 🟨 (일부 path 미구현 — §4.1 참조) |

### 4.1 Rename focus_loss 통합 표 (#175)

탭 rename 활성 중에 어떤 focus_loss 가 발생해도 동일 동작 = **commit** (현재 입력값으로 그 탭 이름 확정). 유일한 예외 = **Esc** (cancel, 변경 안 함).

다른 inline rename UX 표준과 일치 — Finder filename rename, iTerm2 tab rename 등. 입력 흐름이 *항상 어딘가 저장* → 사용자 입력 손실 회피. cancel 은 명시적 의도일 때만.

| Focus_loss 액션 | Spec | Windows 호출 site | macOS 호출 site | Linux 호출 site | Win | Mac | Linux |
|---|---|---|---|---|---|---|---|
| 마우스로 다른 탭 클릭 | commit | `mouse_down` 진입 첫 줄 (`isRenaming` → `commitRename`) | `tildazMouseDown` 진입 첫 줄 (`commitPendingInput`) | `wl_pointer.button` BTN_LEFT 핸들러 진입 (`commitPendingInput`) | ✅ | ✅ | ✅ |
| 마우스로 터미널 영역 클릭 | commit | 동일 (영역 무관, 모든 `mouse_down`) | 동일 (영역 무관, 모든 `tildazMouseDown`) | 동일 (영역 무관) | ✅ | ✅ | ✅ |
| Cmd/Ctrl+숫자 (탭 전환) | commit | `onAppEvent .shortcut` 분기 진입 첫 줄 (`isRenaming` → `commitRename`) | `tildazKeyDown` 의 Cmd 분기 진입 직전 (`commitPendingInput`) | XKB Alt+숫자 핸들러 진입 (`commitPendingInput`) | ✅ | ✅ | ✅ |
| Cmd/Ctrl+Shift+[ / ] (prev/next) | commit | 동일 (`.shortcut` 진입 첫 줄) | 동일 | 동일 (Ctrl+Shift+[/]) | ✅ | ✅ | ✅ |
| Cmd/Ctrl+T (새 탭) | commit | 동일 | 동일 | 동일 (Ctrl+Shift+T) | ✅ | ✅ | ✅ |
| Cmd/Ctrl+W (탭 닫기) | commit | 동일 | 동일 | 동일 (Ctrl+Shift+W) | ✅ | ✅ | ✅ |
| 그 외 모든 단축키 (reset / dump_perf / show_about / open_config / open_log / copy_selection) | commit | 동일 (`.shortcut` 진입 첫 줄) | 동일 | 각 handler 진입 첫 줄 (`commitPendingInput`) — Ctrl+Shift+I·P·L·R 등 신규 핸들러 모두 동일 패턴. reset_terminal 구현 (#214, Ctrl+Shift+R). dump_perf 는 Ctrl+Shift+F12 로 할당됨 (#160) — 로그만 남기는 dev 도구라 handler 가 `commitPendingInput` 을 호출하진 않지만 관측 가능한 동작 차이는 없음 | ✅ | ✅ | ✅ |
| F1 hide (윈도우 숨김) | commit | `WM_HOTKEY` → `toggle` 호출 직전 (`before_hide_fn` callback) | `toggleWindow` 진입 직전 (visible 이면 `commitPendingInputFromContentView`) | portal `Activated` callback 안 (`commitPendingInput`) + `--toggle` IPC accept 안 | ✅ | ✅ | ✅ |
| **Esc** | **cancel** (유일 예외) | `handleRenameKey` 의 `.cancel` 분기 | `tildazKeyDown` 의 Esc keycode 분기 | XKB_KEY_Escape 의 rename cancel 분기 | ✅ | ✅ | ✅ |

---

## 5. IME 동작 (한국어 / 일본어 / 중국어 — 양쪽 동일 spec)

`AGENTS.md # 한글 IME 동작 스펙` 의 정의 그대로. 요약:

| 항목 | 동작 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|---|
| 조합 중 (preedit) inline 표시 | cursor 위치에 보라색 배경 + 글자 | `WM_IME_*` 가로채기 + `ImmGetCompositionStringW(GCS_COMPSTR)` → preedit_buf → cell / tab rename overlay (#164 v0.4.0) | `g_preedit_buf` + cell `renderFrame` 의 preedit 영역 + tab rename overlay | `zwp_text_input_v3.preedit_string` event → `preedit_buf` → cell / tab rename overlay ([9127ba7](https://github.com/ensky0/tildaz/commit/9127ba7), L10-β) | ✅ | ✅ | ✅ |
| 음절 단위 backspace | 자모 / 음절 단위 되돌리기 | (OS IME 자체) | 동일 | (fcitx5 / ibus 자체) | ✅ | ✅ | ✅ |
| 화살표 / 영문 / space → 음절 commit | IME 가 모르는 키 = 음절 자동 확정 | (OS IME 자체) | `interpretKeyEvents` → IME → callback | text-input-v3 의 commit_string + preedit_string done-apply batch ([5f55caa](https://github.com/ensky0/tildaz/commit/5f55caa), L10-γ) | ✅ | ✅ | ✅ |
| commit 트리거 | 음절 더 확장 안 되면 자동 | (OS IME 자체) | 동일 | (fcitx5 / ibus 자체) — commit_string event | ✅ | ✅ | ✅ |
| 한자 / kanji / hanzi 후보 popup 위치 | cursor 옆 추적 | `ImmSetCompositionWindow(CFS_POINT, cursor_pixel)` 매 frame (#164 v0.4.0) | `NSTextInputClient.firstRectForCharacterRange` 가 terminal cursor row / tab rename snapshot 기준 rect 반환 (#166 v0.4.3) | `zwp_text_input_v3.set_cursor_rectangle` 매 redraw (L10-γ) | ✅ | ✅ | ✅ |
| 후보 popup 안 nav 키 | IME default 따름 — tildaz client 가 키 매핑 강제 / 통일 안 함 (§0 #2 native 우선). 사용자가 IME 별 설정에서 변경 가능 | Win IME native (MS-IME 한국어 default) | mac IM Kit native (한국어 IME default) | IME default (예: fcitx5-hangul = ↑/↓ page nav + Tab/Shift+Tab candidate, ←/→ 미매핑 → cursor 이동 의도로 popup 닫힘) | ✅ | ✅ | ✅ |
| 한자 변환 트리거 키 (*조합 중* 한글) | 조합 중인 한글에서 한자 후보 popup 을 여는 키. 키 자체는 IME 엔진 소관 — tildaz 는 정의 / 강제하지 않음 (§0 native 우선). *입력 확정된* 한글의 재변환 트리거는 아래 #209 행 참조. | Win IME native — 한자 키 (한국어 키보드; MS-IME default) | Apple 한글 IME — `Option+Return` | IME 엔진 설정 키 (ibus-hangul 은 F9 / 한자 키가 default, fcitx5-hangul 은 설정에서 지정 — IME 버전 따라 다를 수 있음) → IME 자체 후보 popup | ✅ | ✅ | ✅ |
| 입력 확정된 한글의 한자 변환 ([#209](https://github.com/ensky0/tildaz/issues/209)) | committed text 또는 조합 중 한글 → 후보 popup → 확정 시 replacement. 후보창이 떠 있는 동안 원래 한글은 그대로 보이고, 후보 확정 시에만 한글을 지우고 한자를 입력. Esc / 후보 취소 / focus loss 는 원래 한글 유지. 일반 용어로는 "Hanja reconversion" — *재변환* 이지만 *한자 → 한글* 의미가 아니라 *이미 commit 된 글자를 다시 IME 의 변환 대상으로 되돌려 후보 popup 띄우기*. | Win IME native conversion key / candidate popup 경로. app 은 후보 위치를 `ImmSetCompositionWindow` 로 유지 | `NSTextInputClient` API (`selectedRange`, `markedRange`, `attributedSubstringForProposedRange`, `firstRectForCharacterRange`, `insertText:replacementRange:`) 구현. terminal cursor row 는 PTY `backspace + insert`, tab rename 은 `RenameState` range 치환. 그 외 범위는 안전하게 plain insert fallback (#166, #190 v0.4.3) | ❌ **platform 한계** — *조합 중* 한자 후보는 fcitx5 / ibus 자체 popup 으로 동작 (어느 host 든 OK). *입력 확정된* 한글의 한자 변환은 `zwp_text_input_v3` wire protocol 에 *해당 request 자체가 없어* client → IME 트리거 경로 부재. text-input-v4 의 `set_surrounding_text` 활용 가능성은 별 후속 검토 — Linux 첫 릴리즈는 unsupported 로 출시 | ✅ | ✅ | ❌ (platform-limit) |

### 5.1 IME preedit × line-nav 키 매트릭스 (#164 follow-up 6, v0.4.0)

탭 rename 과 terminal cell 양쪽에서 IME 조합 (preedit) 중에 line-nav 키 (Home / End / Ctrl+A / Ctrl+E) 를 누를 때 동작 정의. native textbox / iTerm2 동등.

**원칙:** nav 키는 *commit 후 이동* — 입력 중 자모를 잃지 않음. Ctrl+C 만 예외 (line abort 의미라 discard).

| 위치 | 키 | preedit 처리 | 후속 동작 | Mac | Win | Linux |
|---|---|---|---|---|---|---|
| 탭 rename | Home / Ctrl+A | preedit 자모 → rename buf cursor 위치 insert | cursor 맨 앞 | ✅ | ✅ | ✅ (`handleRenameKey` mapping — Home / Ctrl+A 모두 .home 로 변환) |
| 탭 rename | End / Ctrl+E | (동일) | cursor 맨 끝 | ✅ | ✅ | ✅ (End / Ctrl+E 모두 .end 로 변환) |
| 탭 rename | Left / Right | (IME 자체 commit 트리거 — 음절 확정) | cursor 한 자 이동 | ✅ | ✅ | ✅ (`handleRenameKey` mapping + IME commit trigger) |
| 탭 rename | Backspace | (IME 자체 — 자모 단위 되돌리기) | (preedit 안의 음절 처리) | ✅ | ✅ | ✅ (`handleRenameKey` mapping + IME 자모 처리) |
| 탭 rename | Esc | preedit cancel + rename cancel | rename 종료 (변경 안 함) | ✅ | ✅ | ✅ |
| 탭 rename | Enter | preedit 자모 commit + rename commit | rename 종료 (변경 적용) | ✅ | ✅ | ✅ |
| 탭 rename | Cmd / Ctrl+T·W·… 단축키 | preedit + rename 모두 commit | 단축키 동작 | ✅ | ✅ | ✅ |
| 탭 rename | 마우스 click 다른 영역 | preedit + rename 모두 commit | click 동작 | ✅ | ✅ | ✅ |
| terminal cell | Home / End | preedit → PTY commit | escape sequence 발신 (`\x1b[H` / `\x1b[F`) | ✅ | ✅ | ✅ (`terminalSequenceForKeysym` + IME commit trigger) |
| terminal cell | Ctrl+A / Ctrl+E | preedit → PTY commit | Ctrl char 발신 (0x01 / 0x05, shell readline 처리) | ✅ | ✅ | ✅ — `processKeyEvent` 가 Ctrl+letter (Ctrl+C 제외) + preedit 시 `commitPendingInput` → PTY 자모 송신 + IME session reset. 그 다음 utf8 path 가 Ctrl byte 송신 |
| terminal cell | Ctrl+C | preedit *discard* (예외 — line abort) | SIGINT (`\x03` interruptWrite) | ✅ | ✅ | ✅ |
| terminal cell | Ctrl+L / Ctrl+D 등 | preedit → PTY commit | Ctrl char 발신 | ✅ | ✅ | ✅ |
| terminal cell | Left / Right / Up / Down | (IME 자체 commit 트리거) | escape sequence 발신 | ✅ | ✅ | ✅ (`terminalSequenceForKeysym` + IME commit trigger) |

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

### 5.2 Emoji 입력 (OS emoji picker)

emoji picker 는 **OS 제공 도구를 그대로 쓴다** — tildaz 는 picker UI 를 구현하지 않는다 (세 platform 공통). Linux 에 앱단 대응물이 없는 것은 결함이 아니라 **라우팅할 OS 표준 picker 가 Linux 에 없기 때문** (의도된 platform 차이).

| | Windows | macOS | Linux |
|---|---|---|---|
| OS picker 진입 | `Win+.` — OS 전역 단축키, 앱 코드 불요 | `Ctrl+Cmd+Space` (system shortcut) — 앱은 menu item 으로 라우팅만 ([#130](https://github.com/ensky0/tildaz/issues/130)) | **없음** — OS 표준 picker 부재. DE 부속 도구는 있으나 tildaz 안 직접 입력 경로 아님 (아래 참고) |
| tildaz 안 동작 | ✅ OS 가 focused 앱에 직접 입력 | ✅ cursor 에 anchored 된 popover — focus loss 자동 dismiss / `Esc` 닫힘 / emoji 클릭 즉시 입력 (2026-07-13 macOS 26.5.2 + v0.6.1 실기 시연) | emoji 입력은 paste (`Ctrl+Shift+V` / 우클릭) 또는 `echo` / `printf` 로 |
| 참고 | | 과거 "floating panel + no auto-dismiss" quirk 기록 (2026-05-06, [bc9aa0b](https://github.com/ensky0/tildaz/commit/bc9aa0b) 시점) 은 현재 환경에서 재현 안 됨 — 원인 미확정 (후보: #166/#190 의 NSTextInputClient 표면 확장 또는 macOS 업데이트). Esc dismiss 보강 코드 (`isEmojiPickerOpen()`) 는 무해해서 유지. | *미실측 (DE / 버전 따라 다를 수 있음)*: KDE Plasma `Meta+.` 는 클립보드 복사 방식, GNOME `Ctrl+.` 은 IBus 경유 GTK 앱 전용이라 tildaz (비-GTK Wayland client) 안에서 미동작 |

---

## 6. 다이얼로그

| 항목 | 동작 정의 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|---|
| 사용자 표시 텍스트 단일 진입점 | 모든 메시지 / format string 한 곳 | `messages.zig` import | 동일 | 동일 (cross-platform module) | ✅ | ✅ | ✅ |
| 다이얼로그 추상화 | `dialog.showInfo / showError / showFatal / showConfirm / promptHotkey` | `dialog/windows.zig` (`MessageBoxW` + key capture window) | `dialog/macos.zig` (NSAlert + NSEvent key capture + osascript fallback) | `dialog/linux.zig` runtime callback infra + `wayland_minimal.zig` 의 별 layer-shell `overlay` surface backend (#203 Phase C step 3) — main 위 modal 그림. 같은 client 의 별 wl_surface 쌍 + buffer + SDF 합성. | ✅ | ✅ | ✅ |
| About 다이얼로그 | 버전 / exe / pid 표시 | `MessageBoxW` (Windows) | NSAlert + popup level 우회 (host window level 잠깐 normal) | Ctrl+Shift+I → `about.showAboutDialog()` → `dialog.showInfo` → Linux backend → layer-shell overlay 그림. 아이콘 (`docs/favicon.svg` raster) + Title + separator + body + OK 버튼 (system blue). | ✅ | ✅ | ✅ |
| Config 에러 (잘못된 값) | dialog 띄우고 종료 (`showFatal`) | `dialog.showFatal` | 동일 (NSApp init 전 osascript fallback) | `dialog.showFatal` — startup 시점은 wayland client 미초기화라 stderr + log fallback + exit. 런타임은 layer-shell overlay. | ✅ | ✅ | ✅ (런타임) / 🟨 (startup fallback) |
| Panic | dialog + `process.exit(1)` | `dialog.showError` + exit | 동일 | `dialog.showError` → stderr + log fallback + exit (panic 은 일반적으로 runtime 라 overlay 가능하나 안전 fallback 우선) | ✅ | ✅ | ✅ |
| 확인 다이얼로그 (`showConfirm`) | OK / Cancel 선택 — destructive 작업 confirm (Alt+F4 / 단일·다중 탭 모두). mac `applicationShouldTerminate:` / Win `onQuitRequest` 동등 — count==0 (PTY 자동 종료) 만 skip, 단일·다중 탭 *항상* confirm. | `dialog.showConfirm` (`MessageBoxW MB_OKCANCEL`) — `app_controller.onQuitRequest` 가 호출 | NSAlert OK/Cancel — `applicationShouldTerminate:` 가 호출 | `dialog.showConfirm` → host `dialogShowConfirmCb` 의 inner wayland event pump (deferred dismiss + 단일 OK/Cancel 두 버튼 layer-shell overlay). Alt+F4 는 KWin 이 *F4 system shortcut* 으로 가로채고 `closed` event 발송 — `handleEvent` 가 `pending_quit_request=true`, main loop `drainQuitRequest` 가 confirm 호출. Cancel 시 main surface 재생성 (KWin 측 unmap 후 다음 close 이벤트 안 옴 회피, #203 Phase C step 4). | ✅ | ✅ | ✅ |
| Click 정책 (modal) | dialog 떠 있는 동안 *OK 버튼 / Enter / Esc 만* dismiss. 본문 click / 같은 client 의 main click / 다른 app 영역 모두 dismiss X (mac NSAlert / Win MessageBoxW 표준). | OS modal 표준 자체 | OS modal 표준 자체 | dialog overlay surface 의 pointer button + xkb keysym 처리. `last_pointer_enter_surface_id == dialog.surface_id` + OK 버튼 좌표 hit-test → dismiss. 본문 / main click 은 swallow (focus 만 회복). Enter / Esc → dismiss. | ✅ | ✅ | ✅ |
| dismiss 후 focus return | dismiss 후 main 에 keyboard focus 자동 양도 | OS 자체 (modal close 후 caller window 복귀) | OS 자체 | `xdg_activation_v1` 표준 — dismiss 직전 dialog 가 token 발급 → main 에 `activate`. dialog 가 *실제 focus* 일 때만 (focus 가드, KWin protocol error 회피). dismiss 호출은 main loop deferred (inner roundtrip reentrancy 차단). | ✅ | ✅ | ✅ |
| Dialog 시각 크기 scale-aware | DPI / fractional scale 환경에서 일관 시각 크기 | DWrite native | NSAlert native | dialog 시각 상수 (corner radius / shadow margin / button w/h / icon size) PT 단위 + `scaledPt(pt, scale)` 변환. KDE Plasma 6 의 1.25x / 1.5x / 1.7x 환경 모두 일관 (SPEC.md §1.1 UI metric scaling 와 같은 패턴). | ✅ | ✅ | ✅ |

---

## 7. config (#118 — 통합 완료)

같은 nested schema, default 만 OS-specific. *Single source of truth* 패턴 — [`src/config.zig`](src/config.zig) 의 `Defaults` struct (Win/Mac 분기, 같은 필드 순서로 나란히) 한 곳에 모든 default 값. 이로부터:

1. **`defaultConfigJson(allocator, shell_resolved)`** 이 runtime `allocPrint` 로 default JSON 을 생성 (shell 은 host 가 runtime 에 결정한 값이라 comptime 생성 불가 — 과거 `DEFAULT_CONFIG_JSON` + `comptimePrint` 에서 전환) — 첫 실행 시 디스크의 `config_0.json`에 저장 + parse() 의 `validateStructure` 검증 ground truth.
2. **`Config` struct field initializer** 가 참조하는 `default_*` const 모두 같은 `Defaults` 에서 derive — 디스크 default 와 메모리 fallback 자동 sync.

이전엔 default 값이 6+ 곳 (JSON literal + 별도 const 들 + Config struct hardcoded literal) 에 흩어져 있어 한쪽만 고치면 어긋남 — 시연 중 발견 (#135). 이제 `Defaults` 한 곳만 고치면 양쪽 자동 sync.

### 7.1 번호별 config / process 계약 (#267)

- 활성 설정은 `config_0.json`, `config_1.json`, ... 형식만 인식한다. 기존
  `config.json`은 읽기·변환·수정·삭제하지 않는다.
- `config_N.json` 하나가 worker process 하나, global hotkey 하나, `tildazN.log`
  하나를 소유한다. worker는 `--instance N`으로 시작하며 번호별 advisory file lock으로
  중복 실행을 막는다.
- 일반 실행은 config index별 실행 상태를 확인하고 빠진 TildaZ worker를 한 번에 모두
  복구한 뒤 launcher가 종료한다. `config_0.json`이 없으면 다른 번호의 config 존재
  여부와 무관하게 default/F1으로 먼저 생성한다. 단순 process 수가 아니라
  `config_<N>.json` ↔ worker N 대응으로 판정한다.
- 모든 configured TildaZ worker가 이미 실행 중일 때만 총 실행 개수와 hotkey capture 영역을
  한 다이얼로그에 표시한다. prompt 전에 worker 0을 show/restore/activate하며, 표시가
  반영된 뒤 alert를 연다. 실제 key 조합을 캡처하기 전에는 **Create**가 비활성이다.
  입력 직후와 **Create** 클릭 순간에 Linux · macOS · Windows 공통 validator가 형식과
  기존 모든 TildaZ config의 hotkey 중복을 검사한다. 중복이면 `Already used by TildaZ N.`을
  같은 다이얼로그에 표시하고 Create를 비활성화한다. 다른 조합을 입력하면 즉시 다시
  검사한다. 통과한 Create만 다음 번호의 config를 생성하고, **Cancel** / Esc는 config나
  system binding을 변경하지 않으며 worker 0은 보이는 상태를 유지한다.
- autostart entry는 launcher를 `--autostart`로 한 번 실행한다. launcher는
  `auto_start=true`인 config의 TildaZ worker만 시작하고 종료한다. 수동 실행은 모든
  config를 대상으로 한다.
- 각 TildaZ worker는 자기 config, process lock, hotkey, toggle endpoint를 독립 소유한다.
  KDE Plasma에서는 portal/KGlobalAccel identity도 `tildaz.instanceN` (내부 app/component ID),
  `TildaZ_N` (표시명), `toggle-N` (action ID)으로 분리해 다른 worker의 shortcut을
  덮어쓰지 않는다. Linux xdg-shell worker 창도 같은 `tildaz.instanceN` app ID를
  사용하며 GNOME/Cinnamon extension은 창 title의 번호까지 일치할 때만 해당 worker로
  식별한다. 사용자에게 보이는 `tildaz.desktop`은 launcher 전용 identity라 GNOME에서
  worker가 실행 중이어도 아이콘 클릭은 기존 창 activate가 아니라 launcher `Exec`를
  다시 호출한다. 번호별 desktop entry는 worker 식별용이며 `NoDisplay=true`다.
- worker N은 `instanceN.lock`의 exclusive advisory lock을 process 수명 동안 소유한다.
  파일 존재나 내부 PID가 아니라 **lock 획득 성공/실패**가 실행 상태의 source of truth다.
  owner가 정상·비정상 종료하면 OS가 lock을 해제한다. PID는 lock 획득 뒤 기록하는
  진단 정보이며, crash 뒤 stale PID 또는 PID 재사용 가능성이 있으므로 생존 판정에
  사용하지 않는다. launcher가 owner 부재를 lock으로 확인했을 때 stale PID를 비운다.
- `launcher.lock`은 config 열거, index별 생존 확인, 누락 worker spawn, 새-instance 요청
  결정과 worker 0의 hotkey dialog/config 생성 transaction을 직렬화한다. 누락 worker를
  spawn한 launcher 또는 새 config를 만든 worker 0은 각 worker가 자기 lock을 획득하고
  PID를 기록한 것을 확인한 뒤 launcher lock을 해제한다. 따라서 다음 launcher는
  config 생성/spawn과 worker ownership 사이의 중간 상태를 관찰하지 않는다.

> Zig 0.15.2 의 `std.json` 이 comptime allocator 를 지원 안 해 (FixedBufferAllocator 의 `@intFromPtr` runtime-only) JSON → Zig 방향 derive 는 불가. 반대로 Zig `Defaults` struct → JSON 방향 생성이 우리 패턴 — shell 이 runtime 결정값(`resolveShell`)이 되면서 `comptimePrint` 대신 `defaultConfigJson` 의 runtime `allocPrint` 로 생성한다.

| 필드 | 의미 | Windows default | macOS default | Linux default / 구현 | Win | Mac | Linux |
|---|---|---|---|---|---|---|---|
| `window.dock_position` | top / bottom / left / right | `top` | `top` | `top` (layer-shell anchor) | ✅ | ✅ | ✅ |
| `window.width_percent` | float 1.0..100.0 | 50.0 | 50.0 | 50.0 (`set_size` × percent) | ✅ | ✅ | ✅ |
| `window.height_percent` | float 1.0..100.0 | 100.0 | 100.0 | 100.0 | ✅ | ✅ | ✅ |
| `window.offset_percent` | float 0.0..100.0 | 100.0 | 100.0 | 100.0 | ✅ | ✅ | ✅ |
| `window.opacity_percent` | float 0.0..100.0 (memory: 0..255 alpha) | 100.0 | 100.0 | 100.0 (ARGB8888 alpha sweep, L13-γ) | ✅ | ✅ | ✅ |
| `theme` | string (`themes.findTheme`) | `Tilda` | `Tilda` | `Tilda` | ✅ | ✅ | ✅ |
| `font.family` | string (primary font, single) | `Cascadia Code` | `Menlo` | `DejaVu Sans Mono` (config.zig Defaults 하드코딩) | ✅ | ✅ | ✅ |
| `font.glyph_fallback` | string array (max 7 — chain total ≤ 8 with primary). 한글 / 이모지 / 심볼 순. | `["Malgun Gothic", "Segoe UI Emoji", "Segoe UI Symbol"]` | `["Apple SD Gothic Neo", "Apple Color Emoji", "Apple Symbols"]` | `["Noto Sans CJK KR", "Noto Color Emoji"]` (fontconfig 환경 표준, 심볼은 fontconfig 자동 fallback) | ✅ | ✅ | ✅ |
| `font.size_point` | integer 8..72 (logical size — host 가 OS scale 적용) | 15 | 15 | 15 | ✅ | ✅ | ✅ |
| `font.line_height_ratio` | float 0.5..2.0 (측정된 ascent+descent+leading 배율) | 1.1 | 1.1 | 1.1 | ✅ | ✅ | ✅ |
| `font.cell_width_ratio` | float 0.5..2.0 | 1.0 (#150 — DWrite native) | 1.0 (Menlo metric 자연) | 1.0 | ✅ | ✅ | ✅ |
| `shell` | string (셸 경로) | `cmd.exe` | 첫 실행 시 host 의 `resolveShell` 이 `$SHELL` env (있으면) / `/bin/bash` (없으면) 을 disk 명시값으로 작성. 이후 실행은 disk 명시값 그대로. | 첫 실행 시 `$SHELL` env / `/bin/bash` fallback (mac 동등) | ✅ | ✅ | ✅ |
| `auto_start` | bool | `true` | LaunchAgent (`~/Library/LaunchAgents/com.tildaz.app.plist`) | XDG autostart (`~/.config/autostart/tildaz.desktop`), L11-α | ✅ | ✅ | ✅ |
| `hidden_start` | bool | `false` | 첫 hotkey 까지 윈도우 unmapped | 첫 hotkey toggle 까지 layer-surface 생성 skip (L11-β). hotkey 전달 경로 — portal `GlobalShortcuts`(KDE 등) *또는* compositor keybind→`--toggle`(sway/Hyprland/COSMIC, `compositorHotkeyEnv`) — 가 있으면 존중, 그 경로마저 없으면 warning + 즉시 show fallback (영영 못 띄우는 trap 방지). GNOME/Cinnamon + extension 환경은 항상 `false` 로 override — 숨김은 extension 이 map 직후 minimize 로 처리 (`host/linux_wayland.zig`) | ✅ | ✅ | ✅ |
| `max_scroll_lines` | integer 100..10_000_000 | 100_000 | 100_000 default. ghostty `bytes_per_row × lines` 로 max byte 계산. | 동일 | ✅ | ✅ | ✅ |
| `hotkey` | 상세 spec 은 §7.1 (테이블 아래) | `F1` | `F1` | `F1` — `LinuxHotkey.fromString` + `keysymToAccelerator` + `kdeTryAutoApply` (충돌 owner 진단 + confirm dialog + takeover). 자세한 알고리즘 §7.1 | ✅ | ✅ | ✅ (#207) |

> **glyph fallback chain** (#135, v0.4.1 schema breaking): chain = `font.family` (primary, single string) + `font.glyph_fallback` (array of strings). codepoint 별로 chain 순회 → 글리프 가진 첫 폰트 사용. chain 에 없는 codepoint 는 양쪽 OS 모두 system fallback 이 자동 처리 — Windows DirectWrite `IDWriteFontFallback.MapCharacters`, macOS CoreText `CTFontCreateForString`. 사용자가 별도 폰트를 추가하고 싶으면 `glyph_fallback` 끝에 append.
>
> **명시 font chain 길이 제한** (#185): `font.family` 1개 + `font.glyph_fallback` 최대 7개 = 총 8개가 hard limit 이다. 코드 source of truth 는 `src/font/constants.zig` 의 `MAX_CHAIN = 8` 이며, config parser / Windows DirectWrite backend / macOS CoreText backend 는 이 상수를 공유한다. 이 값은 "primary + common fallback 한글 / 이모지 / 심볼 + 사용자 추가 여유" 를 주면서 font face lifetime / atlas key 안정성을 단순하게 유지하기 위한 고정 상한이다. 상한을 바꾸면 SPEC / CONFIG.md / README 의 chain limit 설명도 같이 갱신한다.
>
> 모든 명시 폰트 (primary + fallback) 가 system 에 register 되어 있어야 함 — 하나라도 없으면 fatal dialog (`font_validate` 의 공통 메시지, chain dump + 미설치 표시 + config 경로). macOS substitute font 회피 위해 `CTFontCopyFamilyName` 으로 *실제 family name* 검증, Windows 는 `DWriteFontCtx.isFontAvailable` 로 검증, Linux 는 boot 시 fontconfig lookup + substitution 판정 (`font_linux.familyInstalled`, 검증 시점·overlay 는 §7 startup shell 검증과 동일 C2 패턴) 으로 검증 ([#289](https://github.com/ensky0/tildaz/issues/289) B6). libfontconfig 자체를 못 여는 환경은 판정 불가로 두고 loader 의 에러 경로에 맡긴다 (미설치 오판 방지).
>
> schema 위반 (`font.family` 가 string 아님 / `font.glyph_fallback` 이 string list 아님) 은 별도 fatal — `font_validate.showFamilyMustBeStringFatal` / `showGlyphFallbackMustBeListFatal`.

> **schema strict 검증** (Windows + macOS 동일, v0.4.1 통일 — #118 후속):
> - 모든 키 (`window.*`, `font.*`, `theme`, `shell`, `hotkey`, `auto_start`, `hidden_start`, `max_scroll_lines`) 가 *required*. 한 개라도 missing 이면 fatal `missing required key "..."` (사용자 의도하는 위치에 적었는데 silently 무시되는 사고 방지).
> - 알 수 없는 키 (오타 / 잘못된 위치) 면 fatal `unknown key "..."`. 단 `_` prefix key (예: `_note`, `_disabled_*`) 는 *사용자 주석* 으로 인정 — schema 검사 skip (#173). JSON 표준에 주석 없지만 정식 key 는 `_` 안 붙으니 충돌 없는 convention.
> - Type mismatch (예: `width_percent` 에 string) 면 fatal `type mismatch at "..."`. `font.family` / `font.glyph_fallback` 의 type 위반은 더 친절한 별도 메시지 (`font_validate` 의 helper).
> - 위 검증 모두 `validateStructure(user, default, ctx)` 한 함수가 재귀로 처리 — `defaultConfigJson(allocator, shell_resolved)` 결과와 user config 를 비교.

### 7.1 hotkey 상세

**Schema**: `string`. `config_0.json` 기본값: `"F1"`. 각 config = 해당 worker hotkey의 source of truth (cross-platform parity). Windows 는 `RegisterHotKey`, macOS 는 `CGEventTap`, Linux 는 XDG portal `GlobalShortcuts.BindShortcuts` 로 OS / DE 의 global shortcut service 에 등록. portal `GlobalShortcuts` 미지원 DE 는 `tildaz --toggle N` Unix socket IPC (#198) + DE native binding 자동 등록.

**잘못된 hotkey 처리**: `Hotkey.fromString` 이 *null* 이면 `dialog.showFatal(config_error_title, config_hotkey_invalid_format)` 후 process exit ([src/config.zig:962-974](src/config.zig#L962-L974), mac/win/linux 동일). 즉 *parse-pass = 등록 가능 보장* 이 아니라 *parse-pass = format 문법 합격*. Linux 의 portal-kde 송신 가능 여부는 아래 *Key 토큰 표* 의 "Linux 의 portal-kde 송신 보장" 열 참조.

**일반 입력 보호**: modifier 없이 허용하는 global hotkey는 `F1`~`F12`뿐이다. 문자, 숫자, `Space`, `Tab`, `grave` 등은 `Ctrl` / `Alt` / `Super` (`Cmd`) 중 하나 이상이 있어야 한다. `Shift` 단독 조합도 대문자·기호·`Shift+Tab` 같은 일상 입력을 가로채므로 거부한다. 이 검증은 dialog capture와 config parser 양쪽에 공통 적용된다.

**예제** (모든 platform 동일 문법):

```json
"hotkey": "F1"                  // 기본
"hotkey": "ctrl+space"          // 흔한 toggle
"hotkey": "ctrl+shift+t"        // ✅ KDE 테스트 통과
"hotkey": "alt+f12"             // ✅ KDE 테스트 통과
"hotkey": "super+a"             // ✅ KDE — plasmashell next activity 충돌 → takeover dialog
"hotkey": "ctrl+f7"             // ✅ KDE — kwin ExposeClass 충돌 → takeover dialog
"hotkey": "shift+cmd+t"         // mac 친숙 표기 (`cmd` = `super` = `meta` 모두 동일 키)
"hotkey": "ctrl+grave"          // backtick — `grave` 또는 `` ` `` 둘 다 가능
```

**Modifier 토큰** (대소문자 무관, `+` 분리, 임의 개수 결합):

| 토큰 | 의미 | 비고 |
|---|---|---|
| `ctrl` / `control` | Control | |
| `shift` | Shift | |
| `alt` / `option` / `opt` | Alt | `option` / `opt` 은 mac 친숙 표기 |
| `cmd` / `command` / `super` / `win` / `meta` / `logo` | Super | 모두 같은 키 — Win key / Super / Cmd / KDE Meta / Qt Logo. 어떤 표기든 받음 |

**Key 토큰** (대소문자 무관). 세 OS 가 공통 토크나이저(`config.zig` `parseHotkeyString`, [#294](https://github.com/ensky0/tildaz/issues/294) G1)를 거치므로 수용 범위가 아래 표로 동일하고, OS 별 차이는 key code 매핑(keysym / vkey / kVK)뿐:

| 분류 | 토큰 / 글자 | Linux 의 portal-kde 송신 보장 |
|---|---|---|
| Function key | `f1` ~ `f12` | ✅ |
| Latin letter | `a` ~ `z` (또는 `A` ~ `Z`) | ✅ |
| Digit | `0` ~ `9` | ✅ |
| Named special | `space`, `tab`, `escape` / `esc`, `return` / `enter` | ✅ |
| Backtick | `grave` / `backquote` (이름) 또는 `` ` `` (글자) | ✅ |
| 기타 literal ASCII symbol | `~` `!` `@` `#` `$` `%` `^` `&` `*` `(` `)` `-` `_` `=` `+` `[` `]` `{` `}` `;` `:` `'` `"` `,` `.` `<` `>` `/` `?` `\` `|` | ❌ — `LinuxHotkey.fromString` 이 *명시 reject* (#208 fix). caller 가 `dialog.showFatal(config_error_title, config_hotkey_invalid_format)` 로 즉시 알림. 이전엔 silent F1 fallback 이었음 (수용 범위 확대는 portal-kde `XdgShortcut::parse` 의 실제 Qt::Key 매핑 시연 후 별 sub-task) |

**계층적 fallback chain — config ≠ system binding 시 자동 보정** (`portal.handleHotkeyMismatch`, #207):

1. **1차 (cross-DE 정공)**: XDG portal `UnbindShortcuts` (spec v2) + 재 `BindShortcuts`. portal-kde 6.6.5 는 v2 미구현이라 KDE 에선 항상 fail. portal upstream 가 v2 추가 시 모든 portal-가용 DE 에서 cross-DE 일관 동작.

2. **2차 (KDE-specific, `kdeTryAutoApply`)**:
   - `org.kde.KGlobalAccel.action(qt_key) → as` 로 현재 owner 진단 (4-string actionId).
   - owner ≠ tildaz 면 `dialog.showConfirm` (OK/Cancel — Enter=OK / Esc=Cancel (#250), Wayland modal layer-shell overlay, #203 의 dialog backend).
   - 사용자 OK 시 → `shortcut(as) → ai` query 로 owner 의 현재 keys 전체 가져와 → 해당 키만 filter out → `setForeignShortcut(owner, filtered)` 로 *그 키만* 회수 (다른 binding 보존. 예: kwin `ExposeClass` 의 `[Meta+F7, Ctrl+F7]` 에서 `Ctrl+F7` 빼면 `Meta+F7` 유지).
   - `setForeignShortcut(tildaz_actionId, [qt_key])` 로 우리 binding 적용.
   - `shortcut(tildaz_actionId)` 재 query 로 검증 — 우리 qt_key 와 다르면 fallback dialog.
   - **runtime cache only** — `kglobalshortcutsrc` 파일은 미갱신, KGlobalAccel daemon 재시작 시 reset 가능. tildaz 매 실행마다 mismatch 감지 → takeover 자동 재 적용.
   - **GNOME / Cinnamon** — `tryDeSpecificHotkeyFix` 의 분기에서 미구현. 각 DE 의 dconf 경로가 달라 현재는 3차 fallback dialog 로 간다. (Hyprland와 sway는 portal mismatch 경로가 아니라 아래 별도 runtime binding 경로.)

3. **3차 fallback**: `dialog.showInfo` overlay (layer-shell) 로 *수동 변경 안내* — 사용자가 KDE Settings / GNOME Settings / sway config 등에서 수동 조정.

**sway (portal `GlobalShortcuts` 미지원) — `bindsym` 자동 등록** (`sway_ipc.registerToggleIfSway`, #207): sway (xdg-desktop-portal-wlr) 는 GlobalShortcuts portal 이 없어 portal `Activated` 가 오지 않는다. 따라서 위 mismatch chain 이 아니라 *별도 boot 진입점*으로 처리 — `SWAYSOCK` 존재 (또는 `XDG_CURRENT_DESKTOP=sway`) 시, `$SWAYSOCK` 의 i3-ipc `RUN_COMMAND` 로 `bindsym --no-warn <accel> exec "<self_exe>" --toggle N` 를 자동 등록 (`swaymsg` subprocess 아닌 직접 socket). hotkey 실동작은 번호별 single-instance socket. sway IPC에는 runtime binding 열거 request가 없으므로 외부 binding 충돌은 조회하지 않고, Create가 통과한 TildaZ hotkey가 같은 accelerator의 일반 binding을 의도적으로 덮어쓴다([sway IPC request 목록](https://github.com/swaywm/sway/blob/master/sway/sway-ipc.7.scd), [`bindsym --no-warn`](https://man.archlinux.org/man/sway.5.en)). `bindsym` 은 runtime-only라 매 worker 실행 시 등록한다. config 삭제/변경 전에 등록된 stale binding은 같은 accelerator를 재사용하면 새 TildaZ command로 덮이고, 재사용하지 않으면 sway 세션 재시작 때 사라진다.

**Wayland hotkey capture inhibitor**: Linux prompt surface가 focus를 가진 동안 compositor가 `zwp_keyboard_shortcuts_inhibit_manager_v1`을 client에게 노출하면 `zwp_keyboard_shortcuts_inhibitor_v1`을 생성한다. 따라서 기존 compositor binding이 있는 F-key도 prompt가 직접 받는다. Create / Cancel / Esc / surface 종료 시 inhibitor를 surface보다 먼저 파괴해 일반 shortcut routing을 즉시 복구한다. protocol을 노출하지 않는 compositor는 기존 입력 경로를 유지한다. sway에서 `--inhibited`로 등록한 특수 binding은 compositor 정책상 예외로 계속 실행될 수 있다([Wayland protocol](https://wayland.app/protocols/keyboard-shortcuts-inhibit-unstable-v1), [sway inhibitor 동작](https://man.archlinux.org/man/sway.5.en)).

**Hyprland (portal `GlobalShortcuts` 미사용) — runtime binding 증분 동기화**: launcher lock 안에서 `hyprctl -j binds` JSON actual 과 `config_N.json` desired 를 비교한다. accelerator와 현재 TildaZ 실행 파일의 `--toggle N` command가 모두 같은 binding은 유지하고, TildaZ가 소유한 stale binding만 `unbind`, 누락 binding만 `bind`한다. 따라서 config 삭제나 hotkey 변경 뒤 과거 F3/F4 등이 세션에 남아 prompt 입력을 가로채지 않는다. 다른 실행 파일이나 dispatcher의 사용자 binding은 식별 대상이 아니다.

**KDE Plasma / GNOME / Cinnamon — persistent binding 증분 정리**: launcher는 KDE Plasma에서 KGlobalAccel `allComponents()`와 Component `uniqueName`을 조회해 config에서 사라진 `tildaz.instanceN`의 `toggle-N`만 `unregister`한다([KGlobalAccel D-Bus interface](https://github.com/KDE/kglobalaccel/blob/master/src/org.kde.KGlobalAccel.xml), [Component interface](https://github.com/KDE/kglobalaccel/blob/master/src/org.kde.kglobalaccel.Component.xml)). GNOME/Cinnamon의 GSettings fallback도 custom keybinding 목록에서 TildaZ numbered entry만 식별해 사라진 번호를 제거하며 사용자 항목은 보존한다. GNOME/Cinnamon Shell extension은 config directory monitor로 변경을 받고 동일 index/accelerator는 유지한다.

**Display 표기 (사용자 dialog / log)**: `keysymDisplayString` 가 Title case + `+` 분리 (`Meta+A`, `Ctrl+Shift+T`, `Ctrl+F7`) — KDE 친화. portal-kde D-Bus 송신용 parse format (`LOGO+a`, `SHIFT+CTRL+grave`) 과 분리.

**기타 KDE 제약 / 시도 학습**:
- portal-kde 의 `XdgShortcut::parse` 가 *대문자 modifier만* (`CTRL`/`SHIFT`/`ALT`/`LOGO`) case-sensitive HashMap — `keysymToAccelerator` 가 대문자 송신.
- portal-kde 의 *key 부분* 은 `^([\w\d_]+).*$` regex 로 alphanumeric + underscore — literal symbol 은 xkb name (예: `` ` `` → `grave`) 거쳐 송신 필요.
- `KGlobalAccel.setShortcut` 은 Qt 내부 client API 라 외부 D-Bus 거부. `setForeignShortcut` 이 외부용 정공 (void return).
- `KGlobalAccel.unregister` 는 *binding + listener 둘 다 해제* — invasive, 사용 X.

### 7.2 셸 시작 디렉토리 ([#265](https://github.com/ensky0/tildaz/issues/265))

새 탭의 셸은 모든 platform 에서 **홈 디렉토리에서 시작**한다. 지정하지 않으면 자식 셸이 부모 (앱) 의 현재 디렉토리를 물려받아, 앱을 어떻게 실행했는지 (Finder / 런처 / 개발 중 셸) 에 따라 시작 위치가 달라진다.

| platform | 방법 | 구현 | 상태 |
|---|---|---|---|
| Windows — 일반 exe (`cmd.exe` / PowerShell 등) | `CreateProcessW` 의 `lpCurrentDirectory` 에 `%USERPROFILE%` (환경변수 없으면 null = 부모 디렉토리 상속) | [src/terminal/windows/pty.zig](src/terminal/windows/pty.zig) | ✅ |
| Windows — 셸이 `wsl` / `wsl.exe` | 명령줄에 `--cd ~` 삽입 → **Linux 홈**에서 시작. Windows Terminal 의 `MangleStartingDirectoryForWSL` 과 동일 규칙 ([microsoft/terminal PR #9223](https://github.com/microsoft/terminal/pull/9223)) — 사용자가 이미 `--cd` 나 단독 `~` 인자를 넣었으면 삽입 안 함 (사용자 값이 이김) | 동일 파일 `wslCdInsertion` | ✅ |
| macOS | fork 자식에서 `execve` 전 `chdir(getenv("HOME"))` — 실패 시 무시하고 진행 | [src/terminal/macos/pty.zig](src/terminal/macos/pty.zig) | ✅ |
| Linux | 동일 — `chdir(getenv("HOME"))` | [src/terminal/linux/pty.zig](src/terminal/linux/pty.zig) | ✅ |

> Windows 에서 Linux 홈을 `lpCurrentDirectory` 로 지정할 수 없는 이유 (Windows 경로만 표현 가능 + Linux 홈 위치는 distro 안에서만 알 수 있음) 와 `\\wsl$\...` 대안이 기각된 근거는 [#265 코멘트](https://github.com/ensky0/tildaz/issues/265#issuecomment-4910677101) 참조.

**셸 login 모드 — 각 OS 터미널 관례를 따르는 의도적 차이** (2026-07-12 결정, #282 D5). macOS 는 자식 셸을 **login shell** (`argv = {shell, "-l"}`) 로 띄우고 (Terminal.app / iTerm2 표준 — `~/.zprofile`·`~/.bash_profile` 로드; padding 비대칭 원인이던 non-login + `~/.hushlogin` 문제 해결, 커밋 d801d4c), Linux 는 **비-login** 으로 띄운다 (GNOME Terminal / Konsole 표준 — `~/.zshrc`·`~/.bashrc` 만 로드). 어느 dotfile 이 로드되는지가 platform 간 다르지만, 각 OS 터미널의 관례와 일치시킨 의도된 차이다 (cross-platform 동등성 룰의 명시 예외).

---

## 8. PTY 자식 종료

| 항목 | 동작 정의 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|---|
| 탭 닫기 시 자식 정리 | 즉시 종료 + read thread join | `ClosePseudoConsole(hpc)` 한 호출 | `kill(-pid, SIGHUP)` + `wait_thread.join()` | `kill(-pid, SIGHUP)` + `wait_thread.join()` + `read_thread.join()` ([src/terminal/linux/pty.zig:103-145](src/terminal/linux/pty.zig#L103-L145)) | ✅ | ✅ | ✅ |
| Polling sleep 회피 | join 직접 동기화 | (OS API 자동) | wait_thread blocking `waitpid` 으로 즉시 깨어남 | 동일 (`waitpid` blocking + `child_exited` atomic 으로 grace loop break) | ✅ | ✅ | ✅ |
| SIGHUP 무시 셸 fallback | SIGKILL 강제 | (자동) | 500ms grace (5ms polling, `child_exited` atomic) → SIGKILL | 500ms grace / 5ms polling → `posix.kill(-pid, SIG.KILL)` ([src/terminal/linux/pty.zig:105-122](src/terminal/linux/pty.zig#L105-L122)) | ✅ | ✅ | ✅ |

---

## 9. 터미널 환경변수 (자식 셸에 전달)

`AGENTS.md # 터미널 환경변수` 와 동일. 우리 코드 자체엔 사용 X — 모두 자식 셸 / vim / less 같은 TUI 가 보는 변수.

**정책:** 부모 environ 모두 복사 + extra_env 뒤 추가. POSIX `getenv` first-match 라 *부모 환경에 있으면 그것 우선, 없으면 우리 값 fallback*. `.app` GUI launch (`open TildaZ.app`) 는 부모 환경 거의 비어 있어 fallback 적용. CLI 직접 실행은 사용자 셸의 값 우선.

| 환경변수 | 역할 | 우리 default (없을 때 fallback) | Win | Mac | Linux |
|---|---|---|---|---|---|
| `TERM` | escape sequence + 256-color capability | `xterm-256color` (Windows ConPTY 자체 default 있음, macOS 명시) | (PTY default) | ✅ | ✅ ([wayland_minimal.zig:1033](src/host/linux/wayland_minimal.zig#L1033), 5-entry storage) |
| `LANG` | bash readline multi-byte 처리 | `en_US.UTF-8` (안 하면 한글 byte raw 처리, echo 안 됨) | (PTY default) | ✅ | ✅ — `C.UTF-8` (L13-α [ec72010](https://github.com/ensky0/tildaz/commit/ec72010), 한글 IME 회귀 fix) |
| `LC_CTYPE` | locale, 일부 셸이 `LANG` 안 봄 | `en_US.UTF-8` | (PTY default) | ✅ | ✅ — `C.UTF-8` 동일 |
| `COLORFGBG` | vim / less / tmux 자동 dark/light colorscheme (구식 TUI 용 통로) | `themes.isDark(theme)` → `15;0` (dark) / `0;15` (light) — *theme 으로 강제* (사용자 환경 override 의도). **spawn 시 1회 스냅샷** — env 는 이미 뜬 프로세스에 갱신 불가 (환경변수 본질 한계) | ✅ | ✅ | ✅ ([wayland_minimal.zig:1044](src/host/linux/wayland_minimal.zig#L1044)) |
| `WSLENV` | WSL 안 process 에 `COLORFGBG` 전달 | `COLORFGBG` 추가 | ✅ | — | — (WSL Linux-host 무관) |

**예외 — `COLORFGBG` 만 우리 값 강제 의도** (theme 따라 결정). 다른 변수는 사용자 환경 우선.

**dark/light 판별 통로는 두 겹** ([#266](https://github.com/ensky0/tildaz/issues/266)): `COLORFGBG` 는 질의를 안 보내는 구식 TUI 용 spawn 스냅샷이고, 질의를 보내는 앱 (fish 4 / neovim / 최신 vim) 은 §9.1 의 OSC 11 · DSR `?996n` 응답으로 *현재* 배경색 (OSC 로 런타임 변경 반영, ssh 너머 동작) 을 받는다. 두 통로의 판별 공식은 [`themes.isDarkRgb`](src/themes.zig) 하나로 공유 — 서로 어긋날 수 없음.

### 9.1 터미널 질의 응답 ([#266](https://github.com/ensky0/tildaz/issues/266))

앱이 터미널에게 보내는 질의 (응답을 PTY 로 되돌려야 하는 시퀀스) 의 응답 사양. 파싱과 응답 생성은 ghostty-vt 가 담당하고, [`session_core.zig`](src/session_core.zig) 의 Tab.init 이 `vtHandler().effects` 에 콜백을 연결한다 (응답 송신은 `write_pty` → `tab.queueWrite`).

**macOS · Linux 만 배선 — Windows 는 의도적으로 readonly 유지.** ConPTY 구조에서는 자식 앱의 질의에 conhost 가 터미널 역할로 직접 응답하므로 (아래 표의 동작을 conhost 가 제공) 우리 응답의 수신자가 없다. 오히려 conhost 자신의 DA1 질의는 spawn 직후 pre-response ([terminal/windows/pty.zig](src/terminal/windows/pty.zig)) 로 이미 답을 받은 상태라, 파서가 두 번째 응답을 보내면 conhost 가 소비하지 않고 자식 입력으로 흘려보내 cmd 프롬프트에 `62;22c` 가 찍히는 leak 이 실기에서 확인됐다 (#266 Windows 시연).

> **Windows 한계 — 기본색 질의 (OSC 10/11) 는 ConPTY 전체의 platform 한계** (#266 W8 로 확정). conhost 는 headless 에서 기본 fg/bg 를 모르며 (`INVALID_COLOR` 초기화, [RenderSettings 생성자](https://github.com/microsoft/terminal/blob/main/src/renderer/base/RenderSettings.cpp)), 모르는 색 질의는 **응답도 호스트 전달도 없이 소멸**시키고 ([RequestXtermColorResource](https://github.com/microsoft/terminal/blob/main/src/terminal/adapter/adaptDispatch.cpp) — `INVALID_COLOR` 면 응답 생략, else 분기 없음), 밖에서 conhost 에 색을 알려줄 통로도 없다. Windows 에 응답을 배선해도 질의가 우리에게 도달하지 않음을 실기로 확인 (실험 [0781275](https://github.com/ensky0/tildaz/commit/0781275722b63abd9f60e7df551636273310364a) → 판정 후 revert). **Microsoft 의 Windows Terminal 도 동일하게 무응답** (실기 확인). 즉 WSL 앱의 theme 자동 감지 (`fish_terminal_color_theme` 등) 가 Windows 에서 빈 값인 것은 정상이며, 이 용도는 spawn 시 넘기는 `COLORFGBG` (§9) 가 담당한다.

| 질의 | 응답 | 구현 |
|---|---|---|
| DA1 / DA2 / DA3 (`\e[c` 등) | `\e[?62;22c` (vt220 + ansi_color, lib 기본값) | `device_attributes` 콜백 |
| DSR 5n / 6n (상태 / 커서 위치) | `\e[0n` / `\e[row;colR` | lib 내장 (`write_pty` 만 필요) |
| DECRQM (mode 2026 등) | mode 상태 보고 | lib 내장 |
| kitty keyboard 질의 (`\e[?u`) | 현재 flags | lib 내장 |
| XTVERSION (`\e[>0q`) | `tildaz <version>` (`build_options.version`) | `xtversion` 콜백 |
| OSC 4 / 10 / 11 색 질의 | 현재 palette / fg / bg 색 | lib 내장 (ghostty pin [ad692f1](https://github.com/ghostty-org/ghostty/commit/ad692f1e858b8c6475aec4539934526a8d783e6d)+) |
| color scheme DSR (`\e[?996n`) | `\e[?997;1n` (dark) / `2n` (light) — terminal *현재* 배경색의 `themes.isDarkRgb` | `color_scheme` 콜백 |
| XTGETTCAP | **미구현** — upstream lib 도 DCS 무시. #266 3단계 후보 | — |

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
| **config** | `%APPDATA%\tildaz\config_N.json` (Microsoft 표준) | `~/.config/tildaz/config_N.json` (XDG, ghostty/alacritty 패턴 — 터미널 사용자 친숙) | `~/.config/tildaz/config_N.json` (XDG) |
| **log** | `%APPDATA%\tildaz\tildazN.log` (Microsoft 표준) | `~/Library/Logs/tildazN.log` (Apple HIG — Console.app 자동 인덱싱) | `~/.local/state/tildaz/tildazN.log` (XDG state) |
| **process lock** | `%LOCALAPPDATA%\tildaz\run\launcher.lock`, `instanceN.lock` | `~/Library/Caches/TildaZ/launcher.lock`, `instanceN.lock` | `$XDG_RUNTIME_DIR/tildaz/launcher.lock`, `instanceN.lock`; `XDG_RUNTIME_DIR`가 없으면 `${XDG_CACHE_HOME:-~/.cache}/tildaz/run/` |

파일이 없으면 첫 실행 시 default 가 자동 생성된다.

process lock은 config가 아니라 transient runtime/cache state다. `launcher.lock`과
`instanceN.lock`은 실행 뒤 파일 자체가 남을 수 있으며, 존재 여부는 실행 상태를 뜻하지
않는다. `instanceN.lock`의 PID는 process 검색을 돕는 진단값이고 실제 생존 여부는
advisory lock으로만 판정한다.

**stdout / stderr 정책**: 통합 로그가 single source of truth — stdout/stderr 에는 정보성 메시지 안 찍음. 모든 정보 (boot, startup, font/renderer init, tab create, geom, perm, pty, exit) 는 통합 로그로. ghostty-vt 의 `std.log` 호출 (예: `unimplemented mode: ...`) 도 `main.zig` 의 `std_options.logFn` 으로 redirect — 단 `unimplemented mode` noise 는 filter (xterm DECSET 중 ghostty 가 안 구현한 것들, terminal 동작 영향 없음). 권한 안내처럼 첫 부팅 사용자 actionable 인 것은 `dialog.showInfo` 로 messagebox 표시. (예외: macOS IMK system framework 의 stderr noise `IMKCFRunLoopWakeUpReliable` — system framework 가 우리 우회 없이 직접 찍는 것이라 차단 불가, 무시.)

### 11.2 Open Config / Log 단축키 (default editor 열기)

| 동작 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|
| Config 열기 | Ctrl+Shift+P | Shift+Cmd+P | Ctrl+Shift+P — 현재 worker의 `paths.configPath` + `system_open.openInDefaultApp` (xdg-open) | ✅ | ✅ | ✅ |
| Log 열기 | Ctrl+Shift+L | Shift+Cmd+L | Ctrl+Shift+L — 현재 worker의 `paths.logPath` + `system_open.openInDefaultApp` | ✅ | ✅ | ✅ |

> Windows 의 `dump_perf` (스냅샷) 단축키는 Ctrl+Shift+P 와 충돌해 Ctrl+Shift+F12 로 이동 (개발자 dev 도구 컨벤션, F12).

**메커니즘:**
- Windows: `ShellExecuteW(NULL, "open", path, ...)` — 사용자 default editor (`.json` / `.log` 의 file association).
- macOS: `[NSWorkspace openURL:]` 또는 `system("open <path>")` — Finder 가 file extension 따라 default app.
- Linux: `xdg-open <path>` — XDG MIME database.

### 11.3 About 다이얼로그 — 경로 표시 (모두 절대 경로) + Tip 라인

기존 About 텍스트 (TildaZ vX.Y.Z / exe / pid) 에 config / log 경로 + 그 경로를 빨리 여는 단축키 Tip 추가. **`~` 같은 단축 안 쓰고 절대 경로** — 사용자가 그대로 복사해서 vim / ls 명령에 paste 가능 + `~` 가 환경에 따라 다른 위치라 ambiguity 제거.

**body 구조는 양쪽 platform 동일** (`messages.about_format`). Tip 라인의 단축키 *토큰* 만 platform native (Windows `Ctrl+Shift+P/L` ↔ macOS `Shift+Cmd+P/L`) — SPEC §0 #2 의 platform 표준 우선 원칙.

**About 본문 복사는 세 platform 이 공통으로 제공해야 하는 동작이 아니다** (2026-07-12 결정, #282 C3). Windows 는 `MessageBoxW` 의 OS 기본 Ctrl+C, macOS 는 accessoryView selection auto-copy (#128) 로 복사가 되지만, **Linux overlay dialog 는 복사를 제공하지 않는다 (의도).** About 이 보여주는 config/log 경로는 Open Config (`Ctrl+Shift+P`) / Open Log (`Ctrl+Shift+L`) 단축키로 직접 열 수 있어 복사의 실용 가치가 대체되기 때문이다.

```
TildaZ v0.3.0

exe   : /Applications/TildaZ.app/Contents/MacOS/tildaz   (mac)
        C:\Users\<u>\...\tildaz.exe                       (win)
pid   : 12345
config: /Users/<u>/.config/tildaz/config_0.json            (mac)
        C:\Users\<u>\AppData\Roaming\tildaz\config_0.json   (win)
log   : /Users/<u>/Library/Logs/tildaz0.log               (mac)
        C:\Users\<u>\AppData\Roaming\tildaz\tildaz0.log    (win)

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

### 11.4 config error 시 dialog 경로 안내

잘못된 config 값 발견 시 `dialog.showFatal` 본문에 *해당 config 파일 경로* 명시 — 사용자가 어디 고쳐야 할지 즉시 알게.

---

## 12. 폰트 / 텍스트 렌더링 (cross-platform 동등)

폰트 family chain (`primary` + `glyph_fallback`) 은 모두 동일하게 적용 (config § 7). 본 절은 *shape* / *rendering* 동작 spec.

### 12.1 Grapheme cluster

VS-16 / 스킨톤 modifier / ZWJ family (`👨‍👩‍👧` 등) / combining mark (`e + ́` → `é`) 는 cluster 단위로 shape — base + extras 를 함께 platform shape API 에 넣어 representative glyph 으로 reduce. ghostty Mode 2027 (grapheme cluster) ON 에서 cluster = 1 base cell (wide=2, narrow=1) + spacer_tail.

| platform | shape API | 위치 |
|---|---|---|
| Windows | `IDWriteTextAnalyzer.GetGlyphs` + `GetGlyphPlacements` | `src/font/windows/font.zig` `resolveGrapheme` |
| macOS | `CTLineCreateWithAttributedString` 후 첫 CTRun | `src/font/macos/font.zig` `resolveGrapheme` |
| Linux | HarfBuzz `hb_shape` on chain face | `src/font/linux/font.zig` `resolveCluster` (chain 의 모든 face 순회 — primary 미매치 시 NotoColorEmoji 등 fallback face 에서 GSUB 합성 잡음) |

### 12.2 Ligature (인접 cell sequence)

Fira Code / JetBrains Mono / Cascadia Code 등 ligature 폰트 사용 시 인접 char sequence (`==`, `=>`, `!=`, `->`, `<=`, `>=`, `&&`, `||`, `===`, `!==`, `<=>`, `==>`, `-->`, `<--`, `<->`, `||=`, `<==>`, `=<<`, `>>=` 등) 가 ligature glyph 으로 합성 표시.

cross-platform 공유 detection helper: `src/font/ligature.zig` 의 `classify` (input_count + shape result slot 비교).

**판정 규칙** (`LigatureMatch`):
- n < input_count → `.single` (classic GSUB merged — JetBrains Mono / Cascadia Code 일부)
- n == input_count + glyph index 중 하나라도 natural (자연 글리프 = `get_char_index(face, cp)` 동등) 과 다름 → `.spacer` (Fira Code 6.x 의 cursor-aware multi-glyph 패턴 — `=>` 가 `LIG.arrow.start` + `LIG.arrow.end` 두 glyph 으로 substitute 되어 각 cell 차지하며 시각상 합쳐 보임)
- n == input_count + 모두 natural → null (ligature 아님)
- 그 외 (n == 0 or n > input_count) → null

**Paint loop 순서** (셋 다 동일):
1. block element (§ 별도 — `src/renderer/block_element.zig`)
2. grapheme cluster (§ 12.1)
3. **N-char ligature lookahead** — 4-char → 3-char → 2-char 우선 시도 (긴 ligature 가 짧은 것으로 분해되지 않게)
4. single-char chain lookup

**조건** (lookahead 시도):
- 모든 cell 이 `narrow` + single codepoint + same `style_id` (다른 색 / underline 의 cell pair 는 ligature 안 함 — 의도된 분리)
- 모든 codepoint 가 ASCII printable (0x20..0x7E) — non-ASCII (CJK 등) 은 cluster path 또는 single-char path

**그리기** (`LigatureMatch` switch):
- `.single`: 1 glyph 을 N × cell_w 너비로 base cell 위치에 center 정렬 draw
- `.spacer`: 각 glyph (`glyph_indices[i]`) 을 자기 cell 너비 (cell_w) 로 i 번째 cell 위치에 draw

| platform | shape API | 위치 |
|---|---|---|
| Windows | `IDWriteTextAnalyzer.GetGlyphs` (짧은 string) + `GetGlyphIndices` natural | `src/font/windows/font.zig` `ligaturePair` / `ligatureTriple` |
| macOS | CTLine 짧은 line shape + 첫 CTRun glyphs + `CTFontGetGlyphsForCharacters` natural | `src/font/macos/font.zig` `ligaturePair` / `ligatureTriple` |
| Linux | HarfBuzz `shapeRun` + FreeType `get_char_index` natural | `src/font/linux/font.zig` `ligaturePair` / `ligatureTriple` |

4-char+ ligature (`<==>`, `=<<`, `>>=`) 는 후속 sub-step — 위 인프라 위에 동일 패턴으로 셋 다 동시 추가 예정.

cache: 각 platform 이 `AutoHashMap(u64 또는 u128, ?LigatureMatch)` 보관 (key = packed codepoint bits). 같은 sequence 의 반복 호출은 cache hit.

**Fallback**: shape API 미사용 환경 (HarfBuzz dlopen fail, TextAnalyzer 실패 등) → `ligaturePair` 등이 null 반환 → single-char path (자연 글자).

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
| 로그 시스템 (`~/Library/Logs/tildazN.log`) | ✅ | #124 | Windows 와 공통 `src/log.zig` (+ OS 별 `src/log/{windows,macos,linux}.zig`) 동등. `[exit]` 는 `atexit()` hook 으로 기록 — NSApp `terminate:` 가 `exit()` 직행이라 main 의 `defer` 안 거침. |
| Developer ID 코드사인 + notarization | 🔴 (환경 한계) | #109 | 회사 keychain 정책 — fallback ad-hoc |
| config schema 확장 (font.* / shell / max_scroll_lines) | ✅ | #118 | Linux · macOS · Windows가 같은 schema를 사용하고 default만 OS별로 다름. |
| SIGHUP 무시 셸 fallback (SIGKILL) | ✅ | #129 | `Pty.deinit` 에 grace period (500ms / 5ms polling) + `child_exited` atomic flag. wait_thread 의 waitpid 가 깨어나면 즉시 break, 안 깨어나면 SIGKILL. Cmd+W / 탭 close button 으로만 트리거 (Cmd+Q 는 NSApp `terminate:` → `exit()` 직행). |
### A.2 Windows 미구현 (macOS 기능 → Windows 추가)

| 항목 | 우선순위 | 이슈 | 비고 |
|---|---|---|---|
| 이전 / 다음 탭 단축키 | ✅ | #125 | Windows: Ctrl+Shift+[ / Ctrl+Shift+] (macOS Shift+Cmd+[/] 와 동일 키 pair, modifier 만 Windows 네이티브). macOS: Shift+Cmd+[/]. |
| 단일 탭 시 탭바 자리 reserve 버그 | ✅ | #127 | `App.effectiveTabBarHeight()` + count 1↔2 전환 시 `resizeAll`. `renderer/windows.zig` 도 height==0 면 탭바 skip. |
| 컬러 emoji + grapheme cluster shaping | ✅ | [#134](https://github.com/ensky0/tildaz/issues/134), [#136](https://github.com/ensky0/tildaz/issues/136), [#139](https://github.com/ensky0/tildaz/issues/139) | macOS #132 동등성. (a) `IDWriteFactory2.TranslateColorGlyphRun` + Direct2D D3D11-backed RT (`CreateDxgiSurfaceRenderTarget`) 으로 layer 별 `DrawGlyphRun` (`GRAYSCALE` antialias) + 2x super-sampling + `SetTextRenderingParams` (gamma=1.0) → atlas 에 premultiplied BGRA 로 저장. shader color path 가 `atlas.rgba` (premult) + `atlas.aaaa` 로 dual-source blend (Win Terminal `BackendD3D` 동등). (b) `IDWriteTextAnalyzer` 로 grapheme cluster shaping (skin tone, ZWJ). (c) `mode 2027` (grapheme cluster) ON. (d) ZWJ family glyph (`👨‍👩‍👧` 등) 는 `IDWriteTextAnalyzer.GetGlyphPlacements` 로 multi-glyph cluster 의 advance/offset 받아 visual 결합 (#139, WT 동등). |
| IME inline preedit (cell + tab rename) | ✅ | [#164](https://github.com/ensky0/tildaz/issues/164) v0.4.0 | macOS 의 `g_preedit_buf` + 보라 overlay 동등. `WM_IME_STARTCOMPOSITION` / `WM_IME_COMPOSITION` (`GCS_COMPSTR`) / `WM_IME_ENDCOMPOSITION` 가로채기 + `ImmGetCompositionStringW` UTF-16 → UTF-8 → `Window.preedit_buf` → renderer overlay (cell 시 cursor 위치 / rename 시 cursor 옆 inline). |
| IME 후보 popup cursor 추적 | ✅ | [#164](https://github.com/ensky0/tildaz/issues/164) 1d v0.4.0 | `ImmSetCompositionWindow(CFS_POINT, cursor_pixel)` 매 frame onRender 끝에 호출. 일본 / 중국 / 한국 IME 의 한자 후보 popup 이 cursor 옆 자연 추적. `D3d11Renderer.last_cursor_px_x/_y` 에 cursor 그릴 때 보관 (terminal cell / tab rename 양쪽). |
| About 다이얼로그 본문 복사 | ✅ | #128 | Windows는 `MessageBoxW`의 Ctrl+C, macOS는 selectable `NSTextView` selection 변경 시 자동 copy로 NSAlert firstResponder 제약을 우회. |

---

## 부록 B — 알려진 quirk (자잘한 이상 동작, low priority)

> **quirk** = *버그까지는 아닌 알려진 자잘한 비표준 동작* (워크어라운드 알려진 minor 이슈). 사용자 환경 영향 거의 없거나 rare 케이스만 발생.

| quirk | 영향 | 우회 / 대안 |
|---|---|---|
| macOS Metal layer (0,0) 픽셀 미렌더링 | 좌상 1px corner 안 그려짐 | `TERMINAL_PADDING_PT >= 1` 이라 인지 거의 없음 |
| 한영 jamo replay (IMK mach port timing) | 한영 전환 직후 마지막 jamo 가 두 번 처리될 수 있음 | 사용자 환경 미발생. 우리 코드에 워크어라운드 없음. |
| ZWJ family / wide cluster emoji 다중 paste 시 줄바꿈 안 됨 ([#141](https://github.com/ensky0/tildaz/issues/141)) | `Cmd+V` 길게 누름 (key repeat ~30회/초) 으로 `👨‍👩‍👧` 같은 ZWJ family 를 flood 시 같은 줄에 덮어써짐. 1 회 paste 는 정상. | ghostty 의 Mode 2027 (grapheme cluster) 가 cluster = 2 cells 로 처리, bash 3.2 의 wcwidth 는 codepoint sum (man 2 + ZWJ 0 + woman 2 + ZWJ 0 + girl 2 = 6 cells) 으로 계산 → cell 4 mismatch/family. flood 시 bash 의 internal cursor 가 자기 wrap 임계 도달 → `\r` (CR) 출력 → 우리 grid col 0 으로 reset → 같은 자리 덮어써짐. fix path A (Mode 2027 OFF) 는 family ligature 깨짐, B (cluster cell width = codepoint sum + visual ligature 합성) 는 ghostty design 변경 필요 — 둘 다 trade-off 큼. 일반 사용 (1 회 paste) 무영향이라 known limitation 등재. zsh 5.x 등 cluster-aware shell 사용 시 자연 해소. |
| Fira Code `||=` 의 `=` 분리 갭 — 모든 shaper ([#189](https://github.com/ensky0/tildaz/issues/189) 후속) | `||=` 시퀀스에서 `||` 부분만 합쳐지고 마지막 `=` 가 자연 글리프로 분리되어 시각 갭. 다른 3-char ligature (`===`, `==>`, `<==`, `<=>`, `-->`, `<--` 등) 는 정상 합성. | Fira Code 6.x 의 calt 룰 chain 호환성 문제 — `=` 를 `equal_end.seq` 로 substitute 하는 룰이 mac (CoreText) / Linux (HarfBuzz) / Windows (DirectWrite) 모든 shaper 에서 적용 안 됨. 모든 platform 동일이라 cross-platform 동등성 유지. 폰트 update 또는 다른 폰트로 우회 외 우리 코드 fix 불가. |
| KDE Plasma floating dock 가림 ([#206](https://github.com/ensky0/tildaz/issues/206)) — Linux, platform-limit | KDE Plasma 6 의 *floating panel* (떠다니는 dock) 이 인접 창에 따라 화면 안쪽으로 떠오르면, 우리 layer-surface 하단이 그 영역을 덮어 dock 일부가 가려짐. dock 이 가장자리에 anchored 인 동안엔 KWin 이 그만큼 줄인 크기를 줘서 충돌 없음. | client (tildaz) 가 정공으로 해결 불가 — compositor (KWin) 가 floating panel 을 drop-down 출현에 **defloat** 시켜야 하는데 layer-shell 에 그 트리거가 없음(아래 상세). KDE 공식 yakuake 도 동일 미해결([KDE Bug 491006](https://bugs.kde.org/show_bug.cgi?id=491006)). **회피책 — panel 의 *Floating* 옵션을 끄면(anchored 고정) 충돌 없음.** |
| Linux software `wl_shm` renderer 는 임시 | Linux 는 현재 software-only `wl_shm` 렌더러를 쓴다 (Windows D3D11 / macOS Metal 과 달리 GPU 렌더러 아님). | bring-up 용 경로 — PTY / parser / resize / frame lifecycle 검증이 목적. 향후 EGL/OpenGL ES 경로로 교체 예정 (ARCHITECTURE 의 Linux Pipeline / Open Work 참조). 사용자 영향은 없음(렌더 결과 동일). |

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

> **macOS emoji picker 이력 노트 ([#130](https://github.com/ensky0/tildaz/issues/130)):** 2026-05-06 ([bc9aa0b](https://github.com/ensky0/tildaz/commit/bc9aa0b)) 시점엔 picker 가 cursor 옆 popover 가 아닌 화면 floating panel 로 뜨고 focus loss 에 자동 dismiss 안 되는 quirk 가 이 표에 있었다. 2026-07-13 실기 (macOS 26.5.2 + v0.6.1) 재검증에서 popover + 자동 dismiss 로 정상 동작해 **해소 확인** — 현행 동작은 §5.2. 원인은 미확정 (후보: 그 직후 #166/#190 의 NSTextInputClient 표면 확장, 또는 macOS 업데이트). Esc dismiss 보강 코드 (`isEmojiPickerOpen()`, `src/host/macos.zig` — `CGWindowListCopyWindowInfo` 로 `com.apple.Character*` bundle 의 onscreen 윈도우 감지) 는 무해해서 유지한다. 관련 검색어: `orderFrontCharacterPalette`, `CharacterPicker.framework`.

> **ZWJ family / wide cluster emoji 다중 paste 줄바꿈 안 됨 상세 ([#141](https://github.com/ensky0/tildaz/issues/141)):**
>
> ghostty 가 Mode 2027 (grapheme cluster, [`session_core.zig:285`](src/session_core.zig#L285)) ON 으로 ZWJ cluster (man + ZWJ + woman + ZWJ + girl) 를 받으면 첫 base char (man) 만 cell 차지 (wide = 2 cells), 나머지 codepoint 들은 모두 *같은 cell 의 grapheme extras* 로 append 되고 cursor 안 advance — cluster 1 개 = grid 의 2 cells. 시각적으로는 우리 metal renderer 가 cluster 의 base + extras 를 모아 CTLine 으로 single shape → family ligature 정상 표시 ([`renderer/macos.zig:777-800`](src/renderer/macos.zig#L777-L800)).
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

> **Fira Code `||=` 의 `=` 분리 갭 상세 ([#189](https://github.com/ensky0/tildaz/issues/189) 후속):**
>
> Fira Code 6.x 의 `||=` 시퀀스가 `||` 부분만 ligature substitute 되고 마지막 `=` 가 자연 글리프로 분리되어 시각 갭. mac (CoreText) / Linux (HarfBuzz) / Windows (DirectWrite) 모든 shaper 에서 동일 모양.
>
> - **언제 발생하나?** Fira Code 6.x 폰트 + 임의 shaper 환경 + `||=` 시퀀스. mac kitty 0.47.0 + mac Apple Terminal + Linux tildaz + Windows tildaz 4 환경 모두 같은 모양 시연 확인. 다른 3-char ligature (`===`, `==>`, `<==`, `<=>`, `-->`, `<--` 등) 는 모두 정상 합성.
> - **폰트 spec** — [`features/calt/equal_arrows.fea`](https://github.com/tonsky/FiraCode/blob/master/features/calt/equal_arrows.fea) 의 line 51-52 가 `|` `|` `=` 의 첫 두 char 를 `bar.spacer` + `bar_bar_equal_start.seq` 로 substitute. line 10 의 `sub [... bar_bar_equal_start.seq ...] equal' by equal_end.seq;` 가 `=` 를 `equal_end.seq` 로 substitute 하려는 의도. 그러나 모든 shaper 에서 line 10 적용 안 됨 — calt 룰 chain 의 lookup 순서 또는 shaper 별 contextual substitution 호환성 문제 추정.
> - **우리 디버그 결과** — mac CT `ligatureShape` ([`src/font/macos/font.zig`](src/font/macos/font.zig)) 의 GSUB output: `g=(1484,1330,1578) nat=(1327,1327,1578)`. g[2]=1578 (= 자연 글리프) 그대로 → line 10 미적용 확정. Linux / Windows 도 시연 결과 동일 시각 모양 → 같은 substitution 결과 추정. 또한 `||=` `=` 뒤에 공백이 있는 경우만 line 10 의 trailing context 가 매칭 안 되는지 등 contextual 룰 정의 자체 의심도 남음.
> - **fix path 분석** — A (옵션 A workaround: `ligature.classify` 의 "ALL must differ" 룰 완화 + 자연 마지막 glyph 에 강제 negative x_offset paint shift): mac / Linux / Windows 우리 코드만 fix 가능하나 폰트 디자이너 의도와 다른 hack + 다른 폰트 부작용 검증 필요 + 폰트 update 시 conflict 가능. B (옵션 C: HB mac 도입): mac CT → HB 교체 큰 작업이나 root cause 가 폰트라 fix 안 됨. C (폰트 issue 보고): tonsky/FiraCode 측에서만 가능 fix. **우리 범위 아님**.
> - **결론** — 모든 platform 동일이라 우리 cross-platform 동등성 깨지지 않음 (mac/Linux/Windows 다 같이 갭). 폰트 issue 라 fix 안 함. #189 의 직접 motivation 이었으나 우리 코드 fix 대상 아니라고 확정 후 종결. 단 #189 의 부수 fix (모든 spacer ligature 의 GPOS x_offset 추출 + cross-platform unit convention 통일 — `1af2247` / `b1bdbf3` / `487cd0e`) 는 다른 ligature 의 GPOS positioning 정확성 측면에서 유지.
>
> 관련 검색어: `Fira Code ||= ligature broken`, `calt lookup chain shaper compatibility`, `tonsky FiraCode equal_arrows`.

> **KDE Plasma floating dock 가림 상세 ([#206](https://github.com/ensky0/tildaz/issues/206)) — platform-limit:**
>
> KDE Plasma 6.6.5 / KWin (scale 1.7x) 실기 조사 결론 — 이 한계는 **client (tildaz) 가 정공으로 해결할 수 없고 compositor (KWin) 가 고쳐야 하는 문제**다.
>
> 1. **layer-shell 동적 통보 없음.** 다른 창을 maximize↔restore 해서 dock 을 anchored↔floating 으로 왕복시켜도 우리 layer-surface 에 `configure` event 가 재발신되지 않는다. [wlr-layer-shell spec](https://wayland.app/protocols/wlr-layer-shell-unstable-v1) 에 floating panel 의 *동적* geometry 를 client 에 통보하는 mechanism 자체가 없다.
> 2. **KDE scripting 으로도 동적 상태 못 얻음.** `org.kde.plasmashell` `evaluateScript` 로 panel 을 query 해도 `location` / `height` / `floating`(설정 on/off) 등만 노출되고, "지금 인접 창 때문에 떠올랐나" 하는 동적 상태도 실시간 픽셀 위치도 안 나온다.
> 3. **KDE 공식 yakuake 도 동일 미해결.** 같은 증상이 [KDE Bug 491006](https://bugs.kde.org/show_bug.cgi?id=491006) (product=yakuake, CONFIRMED) 로 보고됨. 근본 = "floating panel 이 drop-down 출현에 defloat 하지 않는다" 이고 이는 compositor 가 트리거해야 하는 것이라 layer-shell client 가 일으킬 수 없다. upstream 미해결.
>
> **결정.** 정적으로 dock 영역을 항상 비워두는 회피는 anchored 상태에서 빈 공간 / 정렬 갭을 만들어 폐기. *빈 공간보다 가림이 낫다* 는 판단으로 현 동작(dock 가림) 유지 + KDE Bug 491006 upstream 추적 + platform-limit 문서화. 사용자 회피책은 panel 의 *Floating* 끄기.

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

*마지막 업데이트: 2026-07-13 (#293 문서-코드 정합 pass — #282 감사 후속).
이 문서는 living document — 코드 변경할 때 같은 커밋 안에서 update.*
