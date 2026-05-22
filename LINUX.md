# Linux 백엔드 구현 계획

상태: [#189](https://github.com/ensky0/tildaz/issues/189) 구현 진행 중.
아직 Linux 릴리즈 아티팩트는 없다.

이 문서는 Linux 백엔드 구현을 이어받기 위한 내부 작업 문서다. end-user에게
공개적으로 약속하는 문서가 아니라, 결정 사항, 확인된 동작, 남은 리스크,
milestone 상태를 정확히 남기는 용도다.

## 결정 요약

| 항목 | 결정 |
|---|---|
| 초기 display target | Wayland-only. X11은 첫 Linux 구현 범위에 넣지 않는다. |
| X11 future path | 나중에 필요하면 `host/linux_x11.zig` 같은 별도 backend로 추가할 수 있게 경계만 열어둔다. |
| Toolkit | core app에 GTK / Qt 필수 의존성을 넣지 않고 direct Wayland backend로 시작한다. |
| GTK / Qt fallback | direct Wayland IME 또는 clipboard가 유지 가능한 방식으로 막힐 때만 마지막 fallback 후보로 재검토한다. |
| Baseline window | `xdg-shell` toplevel window. Linux 최소 실행 경로다. |
| True drop-down | compositor 가 `wlr-layer-shell` 을 client 에게 노출 (Wayland 용어 *advertise* — `wl_registry.global` 로 보내는 protocol 지원 통보) 하면 layer-shell 기반 drop-down 을 목표로 한다. |
| GNOME support | 초기에는 limited support. hack 없이 full drop-down workflow가 가능한 경로가 확인되면 바로 full support로 승격한다. |
| Global shortcut | XDG Desktop Portal `GlobalShortcuts` 우선. 지원이 없으면 조용히 실패하지 말고 명확히 제한 사항을 남긴다. |
| Keyboard | `libxkbcommon`. 현재는 런타임 `dlopen("libxkbcommon.so.0")` 방식. |
| IME | Wayland text-input v3 목표. desktop / IME 호환성은 별도 검증한다. |
| Renderer | 원래 계획은 EGL + OpenGL ES 우선. 현재 구현은 bring-up용 software `wl_shm` renderer다. |
| Font stack | 최종 목표는 fontconfig + FreeType + HarfBuzz. L5-1 (ce12372) fontconfig + FreeType ASCII raster, L5-3 (88db341) chain 구조 + per-face lazy raster + Hangul / CJK 동작 (paste), L5-4 (4816052) BGRA color emoji + 임시 chain hardcoded + fontconfig substitution 검증. HarfBuzz shape / block element / config 통합은 별도 sub-step. |
| First alpha scope | normal window, POSIX PTY, 기본 rendering, keyboard/mouse input, selection, copy/paste. |

## 현재 구현 상태

2026-05-18, Debian Cinnamon Wayland 세션에서 확인된 상태다 (이전까지는 UTM
Debian Wayland 환경).

- Branch: `linux-wayland-bringup`
- Commit: `199d002`
- 실행 경로: `zig build && ./zig-out/bin/tildaz`

| 영역 | 상태 |
|---|---|
| normal Wayland terminal window | 동작 — compositor 가 layer-shell 미advertise (GNOME mutter 등) 시 xdg-shell fallback |
| layer-shell drop-down surface | 동작 (L8-α / β) — compositor 가 `zwlr_layer_shell_v1` advertise 시 자동 사용. `dock_position` / `width_percent` / `height_percent` / `offset_percent` config 반영 (mac `screenFrameForDock` 동등). exclusive keyboard. UTM Debian (mutter) / KDE Plasma 6 (KWin) 시연 OK. KDE Plasma 의 floating dock 영역 일부 가림은 별도 한계 (현재 제한 사항 섹션) |
| shell 출력 표시 | 동작 |
| typing → PTY | 동작 (lowercase / uppercase 시각 구분 포함) |
| Backspace / `exit` / shell exit | 동작 |
| `wl_shm` buffer lifecycle | 같은 크기 buffer 2 개 reuse, churn 없음 |
| 마우스 좌클릭 + 드래그 selection | 동작 (셀 영역 색 반전 표시) |
| selection finish 자동 clipboard copy | 동작 (외부 앱에 paste 가능) |
| 더블클릭 word selection + 자동 copy | 동작 (wide char spacer_tail / boundary 시작 reject 는 macOS / Windows 와 공유 모듈) |
| 우클릭 paste | 동작 (외부 앱 clipboard 의 text 가 PTY 직송) |
| `Ctrl+Shift+C` / `Ctrl+Shift+V` 단축키 | 동작 (Linux 도 Windows 와 동일 native modifier) |
| 휠 스크롤 (scrollback) | 동작 |
| 스크롤바 클릭 + 드래그 | 동작 (우측 8 px thumb, Windows/macOS 패턴 동일) |
| block element + shade (`▀..▏ ▐░▒▓▔▕`) | 동작 (공유 `src/renderer/block_element.zig` 부착, 폰트 무관 cell-aligned procedural rect / dot mask) |
| 한글 IME 입력 (fcitx5 + Cinnamon Wayland) | 동작 — `zwp_text_input_v3` wire-level 구현 + commit_string event → PTY 송신 + preedit inline overlay (보라색 배경, macOS / Windows 동등) + Ctrl+key 시 IME discard + cursor 근처 popover 정렬 (`set_cursor_rectangle`) + terminal hint (`set_content_type purpose=terminal`). spec done-apply batch 패턴. L10-α / L10-β / L10-γ 모두 완료. |
| Wayland 미연결 startup 에러 메시지 | path + WAYLAND_DISPLAY / XDG_SESSION_TYPE / XDG_RUNTIME_DIR + 진단 hint 출력 (`error.WaylandSocketUnavailable`) |
| 사용자 config 적용 (shell / theme / max_scroll / font / cell_ratio / opacity) | 동작 (L13-α + β + γ) — `~/.config/tildaz/config.json` 자동 생성 + 사용자 값 변경 시 재실행에 반영. font.family / glyph_fallback chain / size_point (1:1 logical pixel, mac/win 동등) / cell_width_ratio / line_height_ratio / window.opacity_percent (ARGB8888 alpha) 모두 적용. dock / hotkey 통합은 L8 / L9. |
| Tab (multi-tab + 단축키 + 클릭 + arrow/plus + close 'x' + rename + drag reorder + 32-tab cap) | 동작 (L12 전체) — 상단 28px tab bar + 활성/비활성 탭 + 클릭 activate + `Ctrl+Shift+T/W/]/[` + `tab_layout.compute` 로 arrow `<` `>` + plus `+` + 자동 scroll (활성 탭 보임) + 수동 scroll (override) + 더블클릭 rename (IME 한글 포함) + drag-and-drop reorder (source dim + drop indicator + 가장자리 auto-scroll) + close 'x' (dim 색, mac/win 동등) + `<`/`>` enabled/disabled 색 분기 (mac/win 동등) + 32-tab cap dialog. |
| Key repeat (Wayland client-side timer) | 동작 (L12-γ-5) — 영문 typing / 단축키 누르고 있으면 연속 입력. compositor `wl_keyboard.repeat_info` 의 rate / delay 따름. focus 떠날 때 / 키 뗌 시 즉시 disarm. |
| 로그 noise | bring-up 단계 매 frame redraw 로그 제거, lifecycle 변화 이벤트만 |

사용자 제공 로그에서 확인된 capability:

```text
wl_compositor=true
wl_shm=true
xdg_wm_base=true
zwlr_layer_shell_v1=true
zwp_text_input_manager_v3=true
```

441f894 시연 startup 로그 (typing + 좌클릭 drag + 우클릭 paste + Ctrl+Shift+C/V + `exit` 까지):

```text
[boot] tildaz v0.4.3  pid=...
[wayland] bound globals compositor_id=4 shm_id=5 wm_base_id=6 seat_id=7 data_device_manager_id=8
[wayland] keyboard object created keyboard_id=10
[wayland] pointer object created pointer_id=11
[wayland] data device created data_device_id=12
[wayland] capabilities compositor=true shm=true xdg_wm_base=true layer_shell=true text_input_v3=true data_device_manager=true shm_xrgb8888=true
[wayland] keyboard repeat rate=25 delay=600
[wayland] keyboard keymap loaded size=64822
[wayland] shell objects surface_id=14 xdg_surface_id=15 toplevel_id=16
[linux] terminal session created cols=78 rows=25
[wayland] create shm buffer 640x420 stride=2560 size=1075200 pool_id=17 buffer_id=18
[linux] Wayland terminal window mapped
[wayland] create shm buffer 640x420 stride=2560 size=1075200 pool_id=19 buffer_id=20
[tab] shell exited: title=Tab 1
[exit] tildaz v0.4.3  pid=...
```

판정:

- 이전 protocol / green placeholder / black screen / buffer churn 회귀는 그대로 해결 상태 유지.
- 이전에 보였던 매 frame `redraw ...` / `redraw reuse ...` / `redraw reuse retired ...` 로그는 정리돼 lifecycle 이벤트만 보임 ([commit 54b3e65](https://github.com/ensky0/tildaz/commit/54b3e65)).
- 이전에 보였던 "모두 대문자처럼 보임" 현상은 임시 renderer 의 glyph table 매핑 버그로 확정 후 분리 ([commit c8f97c8](https://github.com/ensky0/tildaz/commit/c8f97c8)).
- 마우스 selection drag + 휠 scroll 동작 추가 ([commit 41fc461](https://github.com/ensky0/tildaz/commit/41fc461)).
- L6.2 / L6.3 / L6.4 클립보드 통합 — 자동 copy + 우클릭 paste + Ctrl+Shift+C/V 단축키 ([commit 441f894](https://github.com/ensky0/tildaz/commit/441f894)). 시연 사이클에서 wl_data_offer opcode 매핑 / xkb MODS_EFFECTIVE 상수 / self-paste deadlock / ghostty selectionString ownership 등 4 가지 잠재 버그 발견 + fix.
- L6.7 더블클릭 word selection 추가 ([commit dd40440](https://github.com/ensky0/tildaz/commit/dd40440)). 같은 cell + 500ms 이내 두 번째 좌클릭 → `terminal_interaction.selectWord` 호출 + 자동 copy.
- L6.6 스크롤바 클릭 + 드래그 추가 ([commit 33b760b](https://github.com/ensky0/tildaz/commit/33b760b)). 우측 8 px thumb 시각 + 좌클릭 hit test 가 selection/더블클릭보다 우선, `scrollToY` 는 Windows `app_controller.scrollToY` 패턴 그대로.
- L5-1 fontconfig + FreeType + ASCII raster 추가 ([commit ce12372](https://github.com/ensky0/tildaz/commit/ce12372)). 5x7 임시 glyph table 제거. `src/font/linux/{fontconfig,freetype,font}.zig` 신규. cell metric 은 Renderer field 로 노출. 시연 사이클에서 max_advance vs 'M' advance / cell-center 정렬 두 가지 잠재 버그 발견 + fix.
- L5-3 font chain + lazy raster 추가 ([commit 88db341](https://github.com/ensky0/tildaz/commit/88db341)). single-face + ASCII pre-raster → N-face chain (MAX_CHAIN=8) + per-face `AutoHashMap(u21, Glyph)` lazy raster. `glyph(cp)` 가 chain 순회 + 첫 매치 face 의 cache 에서 lazy insert. paste 로 한글 / 한자 / 가나 입력 시 wide glyph (2 cell) 정상 — NotoSansCJK primary 한 face 안에서 처리.
- L5-4 BGRA color emoji + 임시 chain 갱신 추가 ([commit 4816052](https://github.com/ensky0/tildaz/commit/4816052)). `FT_LOAD_COLOR` + `FT_PIXEL_MODE_BGRA` raster path + `drawGlyphBgra` (cell ratio scale fit + center + premultiplied alpha 블렌딩). chain 임시 hardcoded (JetBrains/Fira/SourceCode/DejaVu/Liberation/monospace/NotoColorEmoji) + fontconfig substitution 검증 (specific family 가 generic 으로 fallback substitute 된 경우 skip). 시연 사이클에서 fontconfig substitution / dedup log 인덱스 두 가지 잠재 버그 발견 + fix.
- L5-6 block element 부착 추가 ([commit c5bbf2a](https://github.com/ensky0/tildaz/commit/c5bbf2a)). 공유 `src/renderer/block_element.zig` 의 `blockElementRect(cp)` 를 `software_terminal.zig` 셀 loop 에 부착. `U+2580..U+2595` (block + LIGHT/MEDIUM/DARK SHADE) 를 폰트 글리프 대신 cell-aligned procedural rectangle / dot mask 로 그린다. shade 식은 d3d11 `bg_shader_src` / macOS Metal `bg_fs` 와 동일 — `(px + 2py) & 3 == 0` (LIGHT 25%), `(px + py) & 1 == 0` (MEDIUM 50%), `(px + 2py) & 3 != 0` (DARK 75%). `▀..▏` 인접 셀 사이 갭/overlap 없이 정확히 맞물림 확인.
- Wayland startup 에러 메시지 정확성 polish 추가 ([commit 97ee2d0](https://github.com/ensky0/tildaz/commit/97ee2d0)). X11 세션에서 실행 시 `TildaZ failed to start. Error: FileNotFound` 한 줄로 끝나던 generic 메시지를, 시도한 socket path + `WAYLAND_DISPLAY` / `XDG_SESSION_TYPE` / `XDG_RUNTIME_DIR` raw 값 + 진단 hint 까지 출력하도록 교체. 의미 이름 `error.WaylandSocketUnavailable` 로 변환해 `showFatalRunError` 가 generic format 중복 print 안 함. 사용자 메시지 텍스트는 `messages.linux_wayland_socket_unavailable_format` 단일 진입점.
- L10-α IME 기초 wiring 추가 ([commit 76b9bb5](https://github.com/ensky0/tildaz/commit/76b9bb5)). `zwp_text_input_v3` 를 client 측에서 wire-level 직접 구현. fcitx5 wayland frontend (libwaylandim.so) 가 server-side. `bindGlobals` 에서 `text_input_manager.get_text_input(seat)` 호출해 text_input object 생성, `wl_keyboard.enter` 시 `text_input.enable() + commit()` / `wl_keyboard.leave` 시 `disable() + commit()` (text-input-v3 double-buffer 규약). `commit_string` event 의 text 를 `queueInput` 으로 PTY 송신 — 다른 키 path 와 동일 통로. `preedit_string` 은 로그만 (overlay 는 L10-β scope). Cinnamon Wayland + fcitx5-hangul 에서 `한 글`, `되네?`, `이게 되?` 등 한글 음절 완성 시 PTY 도달 확인. opcode 출처 https://wayland.app/protocols/text-input-unstable-v3.
- L10-β IME preedit inline overlay 추가 ([commit 6c685b6](https://github.com/ensky0/tildaz/commit/6c685b6)). cursor 위치에 보라색 (`RGB(64, 64, 128)`) 배경 + foreground 글자색으로 조합 중 텍스트 inline 표시 — macOS Metal / Windows d3d11 와 동등 시각 (AGENTS.md "한글 IME 동작 스펙"). spec done-apply 패턴 도입 — preedit/commit event 는 pending ArrayList 에 누적했다가 `text_input.done(serial)` 시점에 한 batch 로 apply (commit → PTY, preedit → renderer overlay). focus disable 시 preedit + pending 모두 클리어. IME 활성 중에는 `wl_keyboard.key` event 가 IME 로 raised 되어 client 에 안 와서 `needs_redraw` 자동 트리거가 안 닿는 문제 발견 — `applyTextInputBatch` 에서 명시 set. `software_terminal.Renderer.preedit_text` field + `drawPreeditOverlay` (`display_width.codepointWidth` 로 wide char 2 cell, cols 넘어가면 truncate).
- L10-γ IME corner case polish 추가 ([commit 6e46e49](https://github.com/ensky0/tildaz/commit/6e46e49)). 세 가지 묶음: ① Ctrl+key 시 IME 조합 discard (AGENTS.md macOS Cocoa quirk 3번 동등) — `handleKeyboardKey` 진입 시 `ctrlActive() && preedit_text` 면 client 측 pending/preedit 즉시 클리어 + redraw. ② `set_cursor_rectangle(x, y, w, h)` — surface-relative pixel 좌표를 server 에 알려 fcitx5 popover 가 cursor 근처에 정렬. `updateCursorRectangle` helper 가 캐시 비교로 cursor 가 실제로 이동했을 때만 전송 (spam 회피). ③ `set_content_type(none, terminal)` — `enableTextInput` 안에서 enable + set_content_type + commit 한 batch (`content_purpose.terminal=13`). 시연 확인: Ctrl+C 시 preedit 즉시 사라짐 + 다음 입력 잔여물 없음 ✅ / popover cursor 근처 정렬 ✅ / log `content_purpose=terminal` ✅.
- L13-α config integration 기초 + Defaults 단일 struct 리팩토링 + dialog Linux backend 추가 ([commit f416072](https://github.com/ensky0/tildaz/commit/f416072)). (1) `host/linux_wayland.zig` 에 macOS 패턴 동등 `resolveShell` + `Config.load` + `g_config` + log. `Client` 에 `config` / `extra_env_storage` field — SessionCore.init 의 shell / max_scroll_lines / theme / extra_env (TERM / LANG / LC_CTYPE / COLORFGBG / SHELL) 가 사용자 config 에서. (2) `config.zig` 의 `Defaults` 세 platform sub-struct → 단일 struct + 항목별 `if/else` 인라인 — 사용자 명시 지적 ("같은 shape struct 인데 셋 다 sub-struct 분리하면 공통 값 70% 까지 중복") 반영. Linux 가지 default (DejaVu Sans Mono / Noto CJK / Noto Color Emoji / size=12 / shell=/bin/bash) 도 같이 정의. `Hotkey` Linux placeholder 추가 (실제 keysym parsing 은 L9). (3) `src/dialog/linux.zig` 신규 — stderr 출력 backend (zenity / kdialog / GTK 통합은 L11). 시연 확인: `~/.config/tildaz/config.json` 자동 생성 + `config.theme` 을 "Solarized Dark" 등으로 바꿔 재실행 시 배경 / foreground 색 변화 ✅.
- L13-β config.font 통합 추가 ([commit a08c3ca](https://github.com/ensky0/tildaz/commit/a08c3ca)). `software_terminal.default_families` (7-entry hardcoded) / `default_pixel_height=16` 하드코딩 제거 → `cfg.font_families[0..font_family_count]` / `cfg.font_size_point` / `cfg.cell_width_ratio` / `cfg.line_height_ratio`. `font.Context.init` 시그니처에 ratio 2 개 추가해 measured cell_w/cell_h 에 곱해 저장. 시연 사이클에서 첫 시도가 표준 typographic 변환 (1pt = 1/72 inch, × 96/72 ≈ 1.33x) 였는데 사용자가 "mac/win 대비 글자가 크다" 보고 → Windows `font_height_px = font_size_point × DPI_scale` (96 DPI 시 1:1) / macOS logical pixel 패턴과 비교해 cross-platform 비대칭 확인 → 1:1 정정 (cell_h 30 → 15 @ size_point=18). 시연 확인: chain 이 사용자 명시 그대로 (DejaVu / NotoCJK / NotoColorEmoji), size_point 변경 시 cell metric 즉시 반영 ✅.
- L13-γ config.opacity_percent 적용 추가 ([commit 318bbef](https://github.com/ensky0/tildaz/commit/318bbef)). Wayland buffer 의 format 을 `ARGB8888 (=0)` (이전 `XRGB8888 (=1)`) + capability 추적 `saw_argb8888`. `Renderer.opacity_alpha` field + paint() 마지막에 alpha sweep — ARGB buffer 의 alpha byte 를 일괄 `self.opacity_alpha` 로 채움. 모든 pixel write 함수 시그니처 / 호출 site 변경 없이 단일 sweep 으로 통합 — 변경 폭 최소. `fillBuffer` (session 미연결 placeholder) 도 ARGB alpha=255. 시연 확인: `opacity_percent: 100 → 80` 변경 시 윈도우 반투명 (compositor 배경 합성) ✅.
- L12-α tab bar 렌더링 + pointer→cell offset 보정 추가 ([commit b392765](https://github.com/ensky0/tildaz/commit/b392765)). 상단 28 logical pixel tab bar 영역 (`ui_metrics.TAB_BAR_HEIGHT_PT`) + 활성 탭 한 개 (`TAB_WIDTH_PT × tab_bar_h - 4`) + title text. terminal grid 가 그만큼 아래로 밀림 — paint() / gridSize / pixelToCell / updateCursorRectangle / 휠 scroll 의 visible_rows 모두 tab_bar offset 적용. 비활성 탭 / 클릭 라우팅 / drag / 단축키 / 32-tab cap 은 L12-β/γ scope. 시연 사이클에서 발견 + fix: `pixelToCell` 의 py origin 보정 누락으로 드래그/더블클릭 시 한 줄 아래 셀이 선택되던 회귀 — 같은 commit 으로 fix.
- L13-α 회귀 fix: LANG/LC_CTYPE default 를 C.UTF-8 로 ([commit db53efb](https://github.com/ensky0/tildaz/commit/db53efb)). L13-α 가 cfg.shell 을 `/bin/sh` (= dash, readline 없음) → 사용자 `$SHELL` (`/bin/bash`) 로 변경한 후 한글 paste / IME commit 깨짐 보고 (`정상` → `정정상` 같은 byte-level 처리). bisect 로 cause 확정: 우리 extra_env 가 `LANG=LC_CTYPE=en_US.UTF-8` 강제 → 사용자 시스템 (`C.utf8 / ko_KR.utf8` 만, en_US 미설치) 에서 setlocale 실패 → bash readline single-byte 모드 → 한글 byte 가 binary 처리. Linux default 를 `C.UTF-8` (POSIX 표준 portable, 모든 Linux 보장) 로. macOS / Windows 는 그대로 `en_US.UTF-8` (OS 기본). 진단 사이클에서 시도한 IUTF8 직접 비트 OR fix 는 cause 아니라 원복 (`tio.iflag.IUTF8 = true` Zig bitfield 유지).
- L12-β tab 단축키 + multi-tab 표시 + 클릭 activate 추가 ([commit d694392](https://github.com/ensky0/tildaz/commit/d694392)). cross-platform `tab_actions.Host` 패턴 부착 — `buildTabActionsHost()` helper + callback 5 개. `Ctrl+Shift+T` 새 탭 / `Ctrl+Shift+W` 활성 탭 닫기 / `Ctrl+Shift+]` 다음 / `Ctrl+Shift+[` 이전 — 단축키 모두 `Ctrl+Shift+*` 자리 (shell 의 정상 통과 보존, gnome-terminal / kitty 관습). `drawTabBar` 가 모든 탭 iter — 활성 = `TAB_ACTIVE_BG`, 비활성 = renderer background (cell 영역과 자연 이음). tab bar 영역 클릭 → `tab_actions.switchTab`. 32-tab cap dialog (임시 stderr/log backend, GUI 는 L11). 시연 사이클에서 발견 + fix: multi-tab Ctrl+Shift+W 가 모든 탭 cascade 종료 회귀 — `linuxTabExit` 가 read thread 에서 직접 `shell_exited.store(true)` 한 게 cause, macOS `g_pending_close_buf` + main loop drain 패턴으로 교체 (`.ended` 만 종료, `.changed` 는 redraw). 단축키 매핑도 사용자 피드백 반영 (초안 `Ctrl+T` 등 → 모두 `Ctrl+Shift+*`).
- L12-γ-1 tab bar arrow / plus + tab_layout.compute 통합 추가 ([commit 357b0ec](https://github.com/ensky0/tildaz/commit/357b0ec)). cross-platform `tab_layout.compute` / `ensureActiveVisible` / `scrollByArrow` / `hitArea` / `hitTab` 부착. 탭 폭 합 > viewport 폭 시 좌 `<` / 우 `>` arrow + `+` plus 등장. 활성 탭이 viewport 밖 나가면 자동 scroll (override=false 일 때). `<` / `>` 클릭 → 수동 scroll + override true. `+` 클릭 → 새 탭. 탭 클릭 → switchTab.
- L12-γ-4 tab close 'x' 버튼 추가 ([commit 41473d9](https://github.com/ensky0/tildaz/commit/41473d9)). 각 탭 우측 끝 `TAB_CLOSE_SIZE_PT (=14)` box 안 'x' 글리프. mac / win 동등 dim 색 (`TEXT × 0.6 + bg × 0.4`). hit.on_close → `tab_actions.closeIndex` (마지막 탭이면 terminate, 아니면 invalidate). hover 강조는 mac / win 도 미부착이라 동등. `blendU8` helper 신규. 시연 사이클 메모: 임시로 "tab bar 우클릭 → close" 도 추가했었는데 SPEC 외라 사용자 지적 후 즉시 원복.
- L12-γ-5 client-side key repeat 추가 ([commit 7248163](https://github.com/ensky0/tildaz/commit/7248163)). Wayland spec 상 key repeat 은 client 책임 (macOS / Windows 는 OS 자동). `Client.key_repeat_keycode` / `key_repeat_next_ms` / `key_repeat_rate_hz` / `key_repeat_delay_ms` field + `handleKeyboardKey` 의 byte parsing / `processKeyEvent(serial, key)` 로 분리. press → timer arm (`next_ms = now + delay`), release → disarm, `wl_keyboard.leave` → disarm (focus 떠날 때 release 못 받는 stuck 방지). main loop 의 `maybeRepeatKey()` 가 매 iteration `now >= next_ms` 면 `processKeyEvent(last_serial, key)` 재호출 + `next_ms += 1000/rate`. IME 활성 시 key 가 IME 로 raised 되어 안 옴 → fcitx5 자체 repeat (충돌 없음). 시연 확인: `a` 연속 입력, Ctrl+Shift+T 연속 새 탭 (32 도달 시 dialog).
- L12-γ-2 더블클릭 rename + IME foot 패턴 정밀화 추가 ([commit c5689e9](https://github.com/ensky0/tildaz/commit/c5689e9)). 탭바 더블클릭 → cross-platform `tab_interaction.RenameState` 부착 (mac/win 공유). Enter commit (`setCustomTitle`), Escape cancel, rename 중 마우스 클릭 cursor positioning, IME 한글 commit 시 buffer 삽입 (PTY 송신 분기 차단), 포커스 loss 시 preedit 자동 commit (mac / win 동등). 진단 사이클에서 `zwp_text_input_v3` 구현을 foot terminal 패턴으로 정밀화 — `enableTextInput` 한 batch (`enable + set_content_type(NONE, TERMINAL) + set_cursor_rectangle(actual cursor pos) + commit`) + `text_input.leave` 가 disable+commit 책임 + `wl_keyboard.enter/leave` 의 enable/disable 호출 제거 (text_input.enter/leave 가 권위) + `computeCursorRect()` helper (surface-relative cursor pixel rect). VSCode (Electron, X11 frontend) 포커스 후 tildaz 한글 입력 회귀는 foot 도 동일 증상 → fcitx5 X11/Wayland frontend separation 환경 한계 ([#194](https://github.com/ensky0/tildaz/issues/194)). Slack desktop 은 영향 없어 일반화 깨짐.
- L8-β config 의 4 개 geometry 반영 + KDE Plasma dock zone 회피 추가 ([commit 5c203a0](https://github.com/ensky0/tildaz/commit/5c203a0)). L8-α 의 hardcoded (top + full width + 400px) → `dock_position` / `width_percent` / `height_percent` / `offset_percent` 기반. `wl_output.mode` event 로 screen 크기 받음. `LayerLayout` struct + `computeLayerLayout` 가 각 dock 별 두 축의 stretch (≥99.9%) / single edge 4 조합 분기. 핵심 원칙 — percent=100 인 축은 size=0 + opposing edge anchor (예: top dock 의 height_percent=100 → anchor=top+bottom+left + size.height=0) → compositor 가 다른 panel 의 exclusive zone honor 한 영역 안에서 stretch (mac 의 `usable_height = visibleFrame.maxY - visibleFrame.minY` 동등). `set_exclusive_zone(0)` 명시 송신. 시연: UTM Debian mutter Wayland + KDE Plasma 6 KWin 양쪽 동작 OK. 한계: KDE Plasma 의 floating dock 의 floating margin 영역까지는 회피 안 됨 (별도 한계 섹션).
- L8-α wlr-layer-shell drop-down surface 추가 ([commit 4673a2e](https://github.com/ensky0/tildaz/commit/4673a2e)). compositor 가 `zwlr_layer_shell_v1` advertise 한 경우 xdg-shell toplevel 대신 layer-shell surface 생성. `get_layer_surface(surface, output=NULL, layer=TOP, namespace="tildaz")` + `set_anchor(top|left|right)` + `set_size(0, 400)` + `set_keyboard_interactivity(exclusive)`. configure event 시 `ack_configure` + size apply (compositor 가 0 보내면 기존 값 유지). xdg-shell fallback 경로는 `caps.layer_shell.name == 0` 시 (GNOME mutter 등). 시연 (UTM Debian arm64 mutter Wayland): 화면 상단 가로 전체 (1440px) + 우리 요청 높이 400px 그대로 + 기존 키보드 / 마우스 / clipboard / 탭 / scroll / IME enter/leave 회귀 없음. 한글 IME 입력 자체는 미테스트. 알려진 한계: 다른 일반 앱 활성화 시 tildaz 가 z-order 위 유지 — layer=top + exclusive 의 자연스러운 결과, cross-platform 별도 이슈 ([#195](https://github.com/ensky0/tildaz/issues/195)). protocol 출처 https://wayland.app/protocols/wlr-layer-shell-unstable-v1.
- L12-γ-3 drag reorder + scroll polish 추가 ([commit b801baf](https://github.com/ensky0/tildaz/commit/b801baf)). cross-platform `tab_interaction.DragState` 부착 (mac/win 공유). 탭 본체 left press → `tab_drag.begin(world_x, tab_w, count)`, motion → tab area 가장자리 (30px) auto-scroll + `tab_drag.move(world_x)`, release → `tab_drag.finish()?` → `session.reorderTabs(from, to)`. drag source 탭은 글자 색 50% blend (mac/win alpha 0.6 동등), drop_idx 의 left edge 에 2px 세로 indicator. `DragState.finish` 의 `defer reset` + `begin` 의 reset 으로 cancel 경로 자동 (mac 패턴 동등, 별도 Escape 분기 없음). 묶음 scroll polish — ① 첫 보이는 탭이 부분 잘릴 때 (`text_x_start < tab_area_x`) text 가 `<` arrow 영역 invade → `viewport_left = @max(text_x_start, tab_area_x)` clamp (mac/win 의 Metal scissor / NSView bounds 동등 software 패턴). ② `<` / `>` arrow 색 분기 — enabled = `TAB_CTRL_ACTIVE_COLOR (0.95)`, disabled = `TAB_ARROW_DISABLED_COLOR (0.4)`, mac/win 동등. plus 는 항상 enabled. scroll 왼쪽 끝 → `<` 회색, 우측 끝 → `>` 회색.
- L9-α libdbus-1 dlopen + session bus connect 추가 ([commit 0a9e7f6](https://github.com/ensky0/tildaz/commit/0a9e7f6)). `src/host/linux/dbus.zig` 신규 — `dbus_bus_get_private` / `dbus_connection_*` 의 dlopen wrapper + `SessionBus` struct (connect / deinit / `unique_name` 로깅). `Client.dbus_session: ?dbus.SessionBus` field + `tryConnectDbus()` 가 capability 후속 단계에서 호출 — 실패는 fatal 아님 (libdbus 미설치 또는 session bus 부재 시 hotkey 기능 없이 terminal 자체는 정상). 시연 사이클: Cinnamon Wayland 환경에서 `unique_name=:1.X` 로 connect ✅.
- L9-β-1 portal GlobalShortcuts.CreateSession 추가 ([commit 2af21c2](https://github.com/ensky0/tildaz/commit/2af21c2)). `src/host/linux/portal.zig` 신규 — D-Bus method call `/org/freedesktop/portal/desktop` 의 `org.freedesktop.portal.GlobalShortcuts.CreateSession` 호출 + Response signal 대기 (handle_token `tildaz_handle`, timeout 30s). reply 검증 → `session_handle` 파싱 + `Client.portal_session` 에 저장. catch path 별 graceful degrade — 어느 단계 fail 이든 dbus_session / portal_session 일관성 유지.
- L9-β-2 portal BindShortcuts "toggle" 추가 (`wip:` [commit 992a2a7](https://github.com/ensky0/tildaz/commit/992a2a7), KDE/GNOME 정식 시연 대기). CreateSession 후 곧바로 단일 `"toggle"` shortcut 등록 — `shortcuts: a(sa{sv})` 의 한 entry `("toggle", {description: "Show / hide TildaZ", preferred_trigger: keysymToAccelerator(config.hotkey)})`. `keysymToAccelerator` helper — XKB keysym → GTK accelerator string (L9-β-2 scope: F1..F12 + modifier=0). timeout 5분 (user dialog 응답 대기). `shortcut_id_toggle` pub const 노출 — L9-γ 의 `Activated` signal 매칭 키로 재사용. `dbus.dbus_type_struct = 'r'` constant 추가. 시연 사이클: Cinnamon Wayland (xdg-desktop-portal-gtk + -xapp) 환경에선 portal `Desktop` 객체에 `org.freedesktop.portal.GlobalShortcuts` 인터페이스 자체가 없음 → CreateSession 단계 `No such interface` D-Bus error → graceful degrade chain 정상 동작 (`[portal] CreateSession skipped: PortalMethodCallFailed — hotkey 기능 비활성` + 메인 window 정상). 정식 검증은 KDE Plasma 6 (xdg-desktop-portal-kde) 또는 GNOME 45+ (xdg-desktop-portal-gnome) 환경 필요.
- L9-γ portal Activated signal subscribe + window toggle 추가 (`wip:` [commit 8680ac7](https://github.com/ensky0/tildaz/commit/8680ac7), KDE Plasma 6 진단 중). `portal.subscribeActivatedSignal` + `ActivatedSubscription` (match rule `interface=GlobalShortcuts member=Activated` + filter, signal payload `(o session, s shortcut_id, t timestamp, a{sv})` 파싱 + session_handle 매칭 + user callback dispatch). `Client` 에 `portal_subscription` / `surface_hidden` / `last_toggle_timestamp` field + `onPortalActivated` (timestamp debounce + shortcut_id 매칭) → `handleActivatedToggle` (hide = `wl_surface.attach(NULL) + commit`, show = `requestRedraw`). main loop `dispatchDbusMessages` 매 iteration `read_write_dispatch(0)` non-blocking. `dbus.zig` 에 `dbus_type_uint64 = 't'` 추가 + 진단용 trace logger field 들 (`message_get_interface` / `_member` / `_type`). 코드 안 진단용 trace log (Response key/shortcuts entries, dispatch heartbeat, filter 진입 interface/member) — cause 확정 후 원복 예정. 시연 사이클 (KDE Plasma 6 + xdg-desktop-portal-kde) 진단 결과: BindShortcuts 응답으로 `shortcuts total=1 id=toggle` 반환 (등록 success). 그러나 KDE Settings 의 F1 owner 가 Konsole 로 표시 + F1 누름 시 Activated signal 미도착 (filter 진입 0회). 가설 (검증 안 함): portal-kde 가 sender pid 의 process tree / desktop file 매칭으로 client 식별 → tildaz binary 의 `.desktop` 부재 → parent process (실행한 Konsole) 로 fallback. 다음 검증: `.desktop` install + KRunner / `gio launch` 실행 시 owner 변화 여부.
- 지금은 "normal terminal window + 키보드 + 마우스 selection drag + 더블클릭 word + 휠 scroll + 스크롤바 클릭/드래그 + clipboard (자동 copy / 우클릭 paste / 단축키) + ASCII real font (mono polish) + paste 시 한글 / CJK wide glyph + color emoji + block element + 한글 IME (음절 commit + preedit overlay + Ctrl 시 discard + popover cursor 정렬 + terminal hint)" 단계. first alpha 라고 부르기에는 HarfBuzz shape / drop-down / global shortcut / **tabs** / **사용자 config 적용** 이 아직 부족하다.

## 현재 제한 사항

### 임시 software renderer

현재 Linux renderer는 `src/host/linux/software_terminal.zig`에 있는 임시
software-only renderer다. `ghostty-vt` render state를 `wl_shm` XRGB8888
buffer에 직접 그려서 PTY - parser - resize - frame lifecycle을 먼저 검증하기
위한 코드다.

이 renderer는 최종 renderer가 아니다. EGL/OpenGL, fontconfig, FreeType,
HarfBuzz가 붙기 전까지의 bring-up용 경로다.

### KDE Plasma floating dock 의 floating margin 영역 일부 가림 (L8-β 시연 발견)

KDE Plasma 6 KWin 환경에서 dock 의 "Floating" 옵션이 켜진 경우, tildaz 의
layer-shell surface 가 dock 의 floating margin 영역까지 일부 침범. dock 의
base height 만큼은 회피되지만, floating 으로 떠 있는 cosmetic margin (예:
하단 8~12px) 까지는 우리 surface 가 차지해 dock 일부가 가려진다.

#### 가설 — 시연 cross-verification 으로 KWin 의도적 설계 확정

- 매핑 자체는 정확 — 로그 `shell objects (layer-shell) ... anchor=0x7
  size=720x0 margin=(0,0,0,720)` (top+bottom+left + size.height=0 stretch
  + margin.left=720) 가 의도대로 송신됨.
- **KWin 의 dock auto-unfloat trigger 가 normal window 에만 반응, layer-shell
  surface 는 안 봄.** 같은 사용자 환경에서 foot 를 KWin Quick Tile 로 우측
  절반에 magnetize → dock 자동 un-float (화면 끝에 붙음). 즉 normal xdg-shell
  + maximized / tiled state 가 trigger.
- 우리 surface 는 layer-shell 이라 "정상 windows" 카테고리에 없어 trigger
  안 됨 → dock 이 floating 상태 유지 → floating margin (예: 하단 8~12px) 이
  exclusive zone 으로 광고되지 않은 채 떠 있고 우리 surface 가 그 영역 점유
  → 일부 가림.
- KDE Plasma 의 의도적 설계로 추정 (floating 은 cosmetic, "전체 사용" 시점
  만 un-float).

#### 우회

- Plasma 의 dock "Floating" 옵션 끄기 (사용자 환경) — base height 만큼은
  정상적으로 exclusive zone 광고되므로 tildaz 도 정확히 회피.

#### 후속 (필요 시)

- KDE 전용 우회 (예: `org_kde_plasma_window_management` 의 surface state
  hint 로 "이건 maximized 처럼 봐라" 전달) — KDE-specific dependency 추가
  신중. 다른 compositor (mutter / wlroots) 환경에선 의미 없음.
- 또는 KWin upstream 에 "layer-shell surface 도 dock un-float trigger"
  feature request — 별도 KDE 측 작업.

### tildaz 창이 항상 다른 앱 위에 떠 있음 (z-order)

L8-α 의 layer-shell surface 가 `layer=top + keyboard_interactivity=exclusive`
로 set 되어 있어 다른 일반 앱 (browser / VSCode 등) 을 activate 해도 그 앱이
tildaz 위로 못 올라온다. 사용자가 tildaz 를 hide 시켜야만 다른 앱이 보임.

cross-platform 동일 증상 — macOS `NSPopUpMenuWindowLevel`, Windows
`HWND_TOPMOST` 도 같은 결과. drop-down 본분 ("hotkey 토글, focus 잃으면 자동
hide") 가 갖춰지면 자연 해소될 가능성 — [#195](https://github.com/ensky0/tildaz/issues/195)
에서 cross-platform 으로 추적.

### VSCode 포커스 후 tildaz 한글 IME 입력 안 됨

Cinnamon Wayland session + fcitx5-hangul 환경에서 VSCode (Electron, X11 frontend)
텍스트 편집창에 포커스 갔다 tildaz 로 복귀 시 한영키 / 한글 입력이 동작 안 한다.

foot terminal (Wayland 표준 `zwp_text_input_v3` 구현체) 도 동일 증상으로 확인 → tildaz
code 문제가 아닌 **fcitx5 X11/Wayland frontend separation 환경 한계**.

**Slack desktop 등 일부 Electron 앱은 영향 없음** (사용자 확인) — "모든 X11 frontend
Electron 앱 = 회귀" 일반화 아님. VSCode 만의 특수성으로 좁혀짐.

우회: gnome-terminal 등 Wayland frontend 사용 앱에 잠깐 포커스했다 tildaz 로 돌아오면 정상화.

추가 검증 / 우회 방법은 [#194](https://github.com/ensky0/tildaz/issues/194) 에서 tracking.

### KDE Plasma 6 portal-kde 의 GlobalShortcuts silent skip — L9-γ 진단 중

KDE Plasma 6.6.5 + xdg-desktop-portal-kde 6.6.5 + KGlobalAccel 6.26.0 환경에서
portal `BindShortcuts` 가 success response 반환하지만 **실제 KGlobalAccel runtime
component register 가 silent skip**. 결과: F1 누름 시 Activated signal 미도착,
hotkey toggle 동작 X.

#### 진단 단계 / 발견 사항 (2026-05-22)

1. **`.desktop` install + `StartupWMClass=tildaz`** — portal-kde 의 client 식별
   path 성공. KDE Settings → 단축키 → 검색 "F1" 의 owner 가 "TildaZ" 로 표시.
   체크박스 활성 + 적용 한 상태에서도 F1 trigger 안 동작.

2. **dbus-monitor `interface=org.freedesktop.portal.GlobalShortcuts`** 띄우고
   F1 누르면 **Activated signal 자체가 발신 안 됨**. 터미널 / 바탕화면 / VSCode
   어디서도 동일. F1 누르면 그 자리에 raw `^[OP` (ESC O P = F1 ANSI seq) 가
   application 까지 직통 — KDE 가 F1 을 *전혀 가로채지 않음* 확정.

3. **`org.kde.kglobalaccel` D-Bus service** 가 `kwin_wayland` (KWin) process 안에
   흡수됨 (Plasma 6.6 architecture). legacy `/usr/lib/kglobalacceld` 는 startup
   시 self-exit (singleton guard).

4. **KGlobalAccel runtime component list 조사** — `busctl --user tree
   org.kde.kglobalaccel` 결과:
   - `/component/yakuake` (Yakuake F1 정상 동작 reference)
   - `/component/org_kde_konsole`, `/component/plasmashell`, ...
   - **`tildaz` 또는 비슷한 component *없음*** — portal-kde 가 KGlobalAccel 의
     runtime register 까지 못 가서 silent fail.

5. **`~/.config/kglobalshortcutsrc` 의 우리 entry**:
   ```
   toggle=,F1,Show / hide TildaZ
          ^── 빈 string (actual key 미할당)
           ,F1, ── default key 만 표시
   ```
   format `<action>=<actual>,<default>,<friendly_name>` 에서 **actual key 가
   empty**. KDE Settings UI 는 default 자리의 `F1` 표시. 실제 trigger 는 empty
   라 동작 X. [MR !449](https://invent.kde.org/plasma/xdg-desktop-portal-kde/-/merge_requests/449)
   의 "always registered (but not assigned any keys)" 패턴과 정확히 일치.

6. **portal-kde `globalshortcuts.cpp` 분석** (KDE master branch):
   - `newShortcutInfos.empty()` 가 true 면 dialog 안 띄우고 `PortalResponse::
     Success` 즉시 반환.
   - 우리 시연 log: `BindShortcuts request sent` → `Response body code=0` 가
     **1ms 만에 도착**. dialog user 응답 시간 (몇 초) 안 됨 = *dialog 안 뜸*.

#### 가설 (강한 순)

| 가설 | 근거 |
|---|---|
| **MR !449 denied cache 패턴** — portal-kde 가 *이전 시도 시 우리 toggle 을 "user denied" 로 기록* → 이후 BindShortcuts 호출은 dialog skip + empty key 등록 + success response | MR !449 의 정확한 동작 패턴. portal-kde state file `~/.local/state/xdg-desktop-portal-kdestaterc` 의 우리 entry 확인 필요 (진단 다음 단계). |
| **layer-shell `keyboard_interactivity=exclusive` 가 dialog 못 뜨게 가로채기** — 첫 시연에서 우리 surface 가 키 입력 다 차지 → portal-kde 의 dialog 가 발신됐어도 user 응답 못 받음 → 자동 deny | dialog 본 적 없음. 첫 시연부터 1ms response. portal-kde 의 globalshortcuts.cpp 는 layer-shell 인식 코드 없음 — bug 가능성. |
| **portal-kde 의 KDE Plasma 6.6 architecture mismatch** — KGlobalAccel daemon 의 KWin 흡수 timing 에 portal-kde 의 forward path 가 부정합 | Yakuake 의 직접 path (`KGlobalAccel::self()->setGlobalShortcut`) 는 정상 동작 — portal layer 만 wire 가 깨진 가능성. |

#### 다음 진단 단계 (이어가는 PC 에서)

1. **Yakuake F1 binding KDE Settings 에서 임시 disable** (conflict 제거).
2. **portal-kde state file 내용 확인** — 우리 toggle 의 denied / disabled 기록 있나:
   ```sh
   cat ~/.local/state/xdg-desktop-portal-kdestaterc
   ```
3. **cache 삭제 + portal-kde 재시작 + tildaz 재실행**:
   ```sh
   cp ~/.config/kglobalshortcutsrc ~/.config/kglobalshortcutsrc.bak
   sed -i '/^toggle=,F1,Show \/ hide TildaZ/d' ~/.config/kglobalshortcutsrc
   # portal-kde state file 에 우리 entry 있으면 그것도 삭제 (위 확인 결과 따라)
   systemctl --user restart plasma-xdg-desktop-portal-kde.service
   pkill -9 tildaz; sleep 1
   gio launch ~/.local/share/applications/tildaz.desktop
   ```
4. **dialog 진짜 뜨는지 확인** — accept 시 actual key = F1 등록되고 F1 trigger 동작 가능.

#### Workaround 후보 — Yakuake 패턴 (L9-δ)

만약 portal 가 끝까지 안 동작 또는 portal-kde 의 bug 확정 시: **KGlobalAccel
D-Bus 직접 호출**. Yakuake 의 검증된 path ([yakuake mainwindow.cpp](https://invent.kde.org/utilities/yakuake/-/blob/master/app/mainwindow.cpp)):

```cpp
action = actionCollection()->addAction(QStringLiteral("toggle-window-state"));
KGlobalAccel::self()->setGlobalShortcut(action,
    QList<QKeySequence>() << QKeySequence(Qt::Key_F12));
```

portal 우회. *cross-desktop spec 외* (KDE-only) 지만 검증됨. portal 시도 후
KGlobalAccel service 가 D-Bus 에 있으면 추가 등록 — GNOME / wlroots 영향 0
(KGlobalAccel D-Bus 없어 자연 skip).

D-Bus interface: `org.kde.KGlobalAccel`, methods: `doRegister(as)`,
`setForeignShortcut(as a(ai))`, `getComponent(s)`. Signal:
`org.kde.kglobalaccel.Component.globalShortcutPressed`.

#### 참고 link

- [portal-kde globalshortcuts.cpp](https://raw.githubusercontent.com/KDE/xdg-desktop-portal-kde/master/src/globalshortcuts.cpp)
- [MR !449 Remember denied shortcuts](https://invent.kde.org/plasma/xdg-desktop-portal-kde/-/merge_requests/449)
- [XDG GlobalShortcuts spec](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html)
- [Yakuake KGlobalAccel direct path](https://raw.githubusercontent.com/KDE/yakuake/master/app/mainwindow.cpp)

### 해소된 limitation (history 기록용)

이 섹션은 이전에 관찰됐다가 fix 된 limitation 을 짧게 기록만 남긴다.
재현 가능성 / 회귀 탐지를 위해 본문은 issue 와 commit 으로.

| limitation | 해소 commit | 원인 |
|---|---|---|
| "모두 대문자처럼 보임" | [c8f97c8](https://github.com/ensky0/tildaz/commit/c8f97c8) | 임시 5x7 glyph table 이 `'A','a' => same` 매핑. PTY byte 는 정상 lowercase 였으나 화면이 어긋남. [#189 결과 코멘트](https://github.com/ensky0/tildaz/issues/189#issuecomment-4446871720). |
| 매 frame `redraw ...` 로그 noise | [54b3e65](https://github.com/ensky0/tildaz/commit/54b3e65) | bring-up 디버깅용 로그 3 줄이 frame 마다 출력. lifecycle 이벤트만 유지로 정리. |
| 우클릭 paste / Ctrl+Shift+V 시 wayland protocol error | [441f894](https://github.com/ensky0/tildaz/commit/441f894) | `wl_data_offer` request opcode 가 한 칸씩 어긋난 채 push (receive=0, destroy=1 인데 wayland 표준은 receive=1, destroy=2 — 0 은 accept 자리). 시연 검증 안 끝난 L6.3 위에 L6.4 가 누적되면서 발현. opcode 정정 + 시연 OK. |
| Ctrl+Shift+C/V 가 그냥 Ctrl+C/V 처럼 동작 | [441f894](https://github.com/ensky0/tildaz/commit/441f894) | `XKB_STATE_MODS_EFFECTIVE` 상수를 `0x0080` (= `LAYOUT_EFFECTIVE`) 으로 잘못 적어 `xkb_state_mod_name_is_active` 가 modifier component 를 안 봄 → 분기 false → fallthrough utf8 `\x03` PTY 송신 → SIGINT. `(1<<3)=0x0008` 로 정정. |
| 우클릭 paste 후 터미널 freeze | [441f894](https://github.com/ensky0/tildaz/commit/441f894) | 우리 자신이 last clipboard owner 인 상태에서 우클릭 → wayland 의 `source.send` event 가 main thread 로 와야 하는데 main thread 는 paste path 의 `posix.read` 에서 blocking → wayland event 못 받아 deadlock. self-source 가드 추가 (`active_data_source_id != 0` 면 buffer 직접 사용). |
| `Invalid free` panic (좌클릭 drag 자동 copy 반복 시) | [441f894](https://github.com/ensky0/tildaz/commit/441f894) | ghostty `screen.selectionString(allocator, ...)` 결과 ptr 의 ownership 이 우리 allocator (GPA) 가 아니라 ghostty 의 자체 arena. 우리 GPA 로 free 시도 시 invalid free panic. dupe 로 우리 buffer 만들어 그것만 보관/free. addr2line stack 의 `arena_allocator.zig:185` 가 결정적 단서. |

### 아직 검증되지 않은 것

| 항목 | 상태 |
|---|---|
| pointer cursor 모양 (I-beam) | 별도 cross-platform 이슈로 분리 ([#193](https://github.com/ensky0/tildaz/issues/193)) — Win/mac/Linux 셋 다 default 화살표라 Linux 단독 추가는 SPEC parity 깨짐. |
| resize UX polish | 미검증 |
| Hangul / CJK paste 시 wide glyph | 동작 ([88db341](https://github.com/ensky0/tildaz/commit/88db341), NotoSansCJK primary 환경). IME 직접 입력은 L10 별도. |
| color emoji paste | 동작 ([4816052](https://github.com/ensky0/tildaz/commit/4816052), Noto Color Emoji chain 포함 + BGRA raster path) |
| block element + shade (`▀..▏ ▐░▒▓▔▕`) | 동작 ([c5bbf2a](https://github.com/ensky0/tildaz/commit/c5bbf2a), 공유 `block_element.zig` 부착 + procedural dot mask) |
| combining mark / grapheme cluster | 미구현 (L5-5 sub-step) |
| layer-shell drop-down surface (top+left+right anchor, exclusive keyboard) | 동작 (L8-α, [4673a2e](https://github.com/ensky0/tildaz/commit/4673a2e), UTM Debian arm64 mutter Wayland). dock_position / width_percent / height_percent config 반영 + slide animation + hotkey toggle 은 L8-β / γ / L9. |
| global shortcut | 미구현 (L9 대기) |
| IME commit (음절 PTY 송신) | 동작 ([76b9bb5](https://github.com/ensky0/tildaz/commit/76b9bb5), fcitx5 + Cinnamon Wayland) — L10-α |
| IME preedit inline overlay (보라색) | 동작 ([6c685b6](https://github.com/ensky0/tildaz/commit/6c685b6)) — macOS / Windows 동등 시각, spec done-apply batch 패턴 |
| `.desktop` / packaging / autostart | 미구현 (L11 대기) |
| compositor 별 차이 (GNOME / KDE Plasma / wlroots 계열) | 미검증 — 현재 UTM Debian Wayland 한 환경에서만 검증 |

## Support Tier 정의

Linux 지원 수준은 desktop 이름만으로 말하지 않고, 실제 capability와 검증 결과로
표현한다.

| Tier | 의미 |
|---|---|
| Full support | global toggle, monitor-aware drop-down placement, tabbed terminal, Unicode rendering, clipboard, config parity, IME behavior가 해당 desktop에서 cross-platform spec을 만족한다. |
| Limited support | terminal은 사용할 수 있지만 true drop-down layer, global shortcut, IME pre-edit, desktop integration 중 하나 이상이 없거나 미검증이다. |
| Unsupported | baseline Wayland window를 열 수 없거나 terminal session을 실행할 수 없다. |

GNOME Wayland는 처음부터 limited support로 시작한다. 중요하지 않아서가 아니라,
GNOME이 wlroots 계열 compositor와 같은 layer-shell contract를 제공하지 않기
때문이다. 정확하고 유지 가능한 경로가 확인되면 full support로 승격하는 것이
목표다.

## Wayland 우선 이유

Wayland는 현재 Linux desktop의 중심 방향이고, “요즘 desktop manager에서 잘
동작하면 좋겠다”는 사용자 목표와 맞다.

X11 지원이 불가능한 것은 아니다. 하지만 X11을 넣으면 windowing, input,
clipboard, global hotkey, IME, DPI, focus behavior가 모두 별도 host surface가
된다. Wayland backend가 쓸만해진 뒤 실제 사용자 요구나 배포 요구가 있을 때
별도 이슈로 다시 판단한다.

단, 코드 구조는 X11을 영원히 막지 않게 유지한다. Linux-specific 파일은 나중에
X11 backend가 Wayland 옆에 공존할 수 있는 이름과 경계를 갖는다.

## GTK / Qt로 시작하지 않는 이유

GTK와 Qt는 좋은 Linux UI stack이지만, TildaZ는 이미 terminal app surface의 많은
부분을 직접 가진다.

- terminal state와 tabs
- config와 validation
- custom renderer
- selection과 mouse policy
- dialogs와 user-visible messages
- platform-specific PTY lifecycle

Toolkit은 window shell, input plumbing, clipboard, IME integration을 도와줄 수
있지만 global shortcut과 desktop-layer placement의 Wayland 제약을 없애지는
않는다. GTK는 GNOME 쪽 runtime bias가 있고, Qt는 KDE/Plasma 쪽 bias가 있다.
direct Wayland backend는 각 desktop capability를 runtime에 명확히 probe할 수
있다.

Toolkit integration은 direct Wayland text-input 또는 clipboard가 실제로
막힐 때만 fallback 후보로 다시 검토한다.

## Desktop Matrix

| Desktop / compositor | 초기 상태 | 기대 baseline | Full support blocker |
|---|---|---|---|
| Sway, Hyprland, Wayfire 등 wlroots 계열 | Full-support target | `xdg-shell` plus `wlr-layer-shell` when advertised | global shortcut과 IME behavior를 compositor/session별로 검증해야 한다. |
| KDE Plasma Wayland | Full-support candidate | `xdg-shell`; layer-shell support는 실제 probe 필요 | Qt 없이 portal global shortcut과 layer-shell behavior가 가능한지 검증해야 한다. |
| GNOME Wayland | Limited support first | `xdg-shell` normal app window | true drop-down placement는 GNOME Shell extension 등 유지 가능한 별도 경로가 필요할 수 있다. |
| X11 sessions | 초기 범위 밖 | 없음 | 별도 backend 결정과 구현 이슈가 필요하다. |

## Capability Strategy

Linux host는 startup 중 capability를 probe하고 log에 남긴다. 지원이 없으면
정직하게 degrade한다.

| Capability | Probe | 없을 때 |
|---|---|---|
| Baseline window | `xdg_wm_base` | fatal: Linux host가 app window를 열 수 없다. |
| Desktop layer | `zwlr_layer_shell_v1` | normal `xdg-shell` window로 fallback하고 true drop-down unavailable로 표시한다. |
| Keyboard maps | `libxkbcommon` setup | keyboard input을 올바르게 해석할 수 없으므로 fatal 또는 startup error. |
| Clipboard | Wayland data-device support | terminal은 유지하되 copy/paste 제한을 message/log로 명확히 남긴다. |
| Global shortcut | XDG Desktop Portal `GlobalShortcuts` over D-Bus | in-app shortcuts만 유지하고 global toggle setup/unsupported 안내를 제공한다. |
| IME | `zwp_text_input_manager_v3` and real pre-edit/commit events | raw keyboard와 paste는 유지하고, 해당 session에서 IME unavailable로 문서화한다. |

## 구현 파일 경계

현재와 목표를 함께 적는다.

| 영역 | 현재 / 계획 위치 | 메모 |
|---|---|---|
| Host entry | `src/host/linux_wayland.zig` | Linux 실행 진입점. 현재 minimal Wayland client로 연결된다. |
| Minimal Wayland client | `src/host/linux/wayland_minimal.zig` | 현재 핵심 구현. wire protocol 직접 구현, registry, xdg-shell, shm buffer, keyboard 처리. |
| Temporary renderer | `src/host/linux/software_terminal.zig` | 현재 사용 중. 최종 renderer가 아니라 bring-up용 software `wl_shm` renderer. |
| XKB wrapper | `src/host/linux/xkb.zig` | `libxkbcommon.so.0` runtime loading. |
| PTY | `src/terminal/linux/pty.zig` | POSIX PTY. `/dev/ptmx`, `TIOCSPTLCK`, `TIOCGPTN`, `setsid`, `TIOCSCTTY`, stdio dup, shell exec. |
| Terminal backend wrapper | `src/terminal/linux.zig` | Windows/macOS와 같은 `Backend` API wrapper. |
| Final renderer | `src/renderer/linux.zig`, `src/renderer/linux/*` | 아직 미구현. EGL/OpenGL ES surface, glyph atlas, frame lifecycle 후보. |
| Font | `src/font/linux/*` | 아직 미구현. fontconfig discovery, FreeType rasterization, HarfBuzz shaping, shared fallback-chain cap 목표. |
| Dialogs | `src/dialog/linux.zig` | 아직 미구현. shared message text와 desktop-safe minimal path부터 시작. |
| Logging / paths / autostart | 기존 wrapper plus Linux impls | Linux log path는 현재 `~/.local/state/tildaz/tildaz.log`. |

shared core module이 Wayland type에 의존하면 안 된다. Wayland object는 host,
renderer, terminal, font, dialog, path, autostart wrapper 뒤에 둔다.

## Milestones

| Milestone | 목표 | 현재 상태 | 다음 gate |
|---|---|---|---|
| L0 | 문서화 + build boundary | 완료 | 이 문서와 #189에 계획 기록됨. |
| L1 | Linux build skeleton | 완료 | Linux target이 generic unsupported host가 아니라 Linux host boundary로 들어간다. |
| L2 | POSIX PTY | smoke scope 완료 | UTM Linux에서 `/bin/sh` PTY smoke test 성공. |
| L3 | Wayland baseline window | normal `xdg-shell` scope 완료 | Wayland window open/map/close와 capability logging 확인. |
| L4 | EGL/OpenGL renderer | 부분 완료, 단 EGL/OpenGL은 아님 | 임시 software `wl_shm` renderer로 terminal grid 보임. lowercase / uppercase 5x7 glyph 분리 ([c8f97c8](https://github.com/ensky0/tildaz/commit/c8f97c8)). final GPU renderer는 아직. |
| L5 | Fonts | L5-1 / L5-3 / L5-4 / L5-6 완료, 나머지 대기 | L5-1 — fontconfig dlopen + FreeType dlopen + ASCII pre-raster + cell-center 정렬 ([ce12372](https://github.com/ensky0/tildaz/commit/ce12372)). L5-3 — chain 구조 (MAX_CHAIN=8) + per-face lazy raster + Hangul / CJK paste 동작 ([88db341](https://github.com/ensky0/tildaz/commit/88db341)). L5-4 — BGRA color emoji raster path + 임시 chain hardcoded + fontconfig substitution 검증 ([4816052](https://github.com/ensky0/tildaz/commit/4816052)). L5-6 — 공유 `block_element.zig` 부착 + procedural dot mask (d3d11 / Metal 셰이더와 동일 식) ([c5bbf2a](https://github.com/ensky0/tildaz/commit/c5bbf2a)). 남은 sub-step: L5-2 HarfBuzz Latin shape / L5-5 combining mark + ZWJ + grapheme cluster / config 통합 (font.family + font.glyph_fallback). |
| L6 | Input and clipboard | keyboard + mouse selection drag + 더블클릭 word + 휠 scroll + 스크롤바 클릭/드래그 + clipboard (자동 copy / 우클릭 paste / Ctrl+Shift+C/V) 까지 | `wl_keyboard` + runtime `libxkbcommon` keymap loading 성공. `wl_pointer` 도입 후 셀 영역 selection drag + 휠 scroll 동작 ([41fc461](https://github.com/ensky0/tildaz/commit/41fc461)). 그 다음 `wl_data_device_manager` / `wl_data_source` / `wl_data_offer` 도입 + `xkb_state_mod_name_is_active` 로 modifier 검사해서 자동 copy + 우클릭 paste + Ctrl+Shift+C/V 단축키 동작 ([441f894](https://github.com/ensky0/tildaz/commit/441f894)). 더블클릭 word selection ([dd40440](https://github.com/ensky0/tildaz/commit/dd40440)). 스크롤바 클릭 + 드래그 — 우측 8 px thumb hit test + `scrollToY` ([33b760b](https://github.com/ensky0/tildaz/commit/33b760b)). pointer cursor 모양은 cross-platform 이슈로 분리 ([#193](https://github.com/ensky0/tildaz/issues/193)). |
| L7 | First alpha | 대기 | normal window에서 PTY/render/input + selection/copy/paste가 모두 되어야 함. |
| L8 | Layer-shell drop-down | L8-α / β 완료 | L8-α — `caps.layer_shell.name != 0` 시 xdg-shell toplevel 대신 layer-shell surface 생성 + exclusive keyboard ([4673a2e](https://github.com/ensky0/tildaz/commit/4673a2e)). L8-β — `wl_output.mode` 로 screen 크기 받아 `dock_position` / `width_percent` / `height_percent` / `offset_percent` 4 개 config 반영 + `set_exclusive_zone(0)` 명시 + percent=100 축은 size=0 + opposing edge anchor (compositor 가 다른 panel exclusive zone honor 한 영역에서 stretch) ([5c203a0](https://github.com/ensky0/tildaz/commit/5c203a0)). 시연 OK: UTM Debian mutter + KDE Plasma 6 KWin 양쪽. fallback (GNOME mutter 등) 시 xdg-shell. 알려진 한계: ① 다른 일반 앱 z-order 위로 못 옴 — [#195](https://github.com/ensky0/tildaz/issues/195). ② KDE Plasma floating dock 의 floating margin 영역까지 회피 안 됨 (현재 제한 사항 섹션). slide-down animation 은 SPEC 아님 — mac / Windows 도 즉시 표시. 단독 hotkey toggle 은 L9 (portal GlobalShortcuts). |
| L9 | Global shortcut | α / β-1 feat 완료, β-2 / γ 코드 완료 (`wip:`), KDE Plasma 6 진단 중 | L9-α — libdbus-1 dlopen + session bus connect ([0a9e7f6](https://github.com/ensky0/tildaz/commit/0a9e7f6)). L9-β-1 — portal `GlobalShortcuts.CreateSession` ([2af21c2](https://github.com/ensky0/tildaz/commit/2af21c2)). L9-β-2 — portal `BindShortcuts` "toggle" + `keysymToAccelerator` ([992a2a7](https://github.com/ensky0/tildaz/commit/992a2a7) `wip:`, Cinnamon graceful degrade 확인). L9-γ — `Activated` signal subscribe + `handleActivatedToggle` (hide=`wl_surface.attach(NULL)+commit` / show=`requestRedraw`) + main loop `dispatchDbusMessages` ([8680ac7](https://github.com/ensky0/tildaz/commit/8680ac7) `wip:`). KDE Plasma 6.6.5 + xdg-desktop-portal-kde 6.6.5 진단 진행 중 — 자세한 진단 일지 / 가설 / 다음 단계는 "현재 제한 사항" 섹션 의 *"KDE Plasma 6 portal-kde 의 GlobalShortcuts silent skip"* 참고. 요약: `.desktop` install + `StartupWMClass` 후 KDE Settings owner = TildaZ 표시 OK (1차 가설 일부 확정), 그러나 KGlobalAccel runtime component list (`/component/...`) 에 tildaz 가 없고 `~/.config/kglobalshortcutsrc` 의 `toggle=,F1,...` 의 actual key 자리가 *empty*. 현재 강한 가설: [MR !449](https://invent.kde.org/plasma/xdg-desktop-portal-kde/-/merge_requests/449) denied cache 또는 layer-shell exclusive 환경의 dialog 미발신. 다음 단계: portal-kde state file (`~/.local/state/xdg-desktop-portal-kdestaterc`) 의 우리 entry 확인 + cache 삭제 + portal-kde 재시작 + dialog 진짜 뜨는지 검증. Workaround 후보: KGlobalAccel D-Bus 직접 호출 (Yakuake 패턴, L9-δ). **명시 요구사항**: 다른 X11 / Electron 앱 (예: VSCode) 이 focus 잡고 있을 때도 hotkey 가 TildaZ 에 도달해야 한다. X11 시대의 Tilda 가 동일 시나리오에서 VSCode focus 시 F1 이 안 닿는 quirk 가 있는데 (`XGrabKey` 가 XWayland 안 X11 client 의 grab 에 가려짐), TildaZ 는 Wayland native client 로서 portal `GlobalShortcuts` 가 compositor 레벨 routing 이라 focus 무관히 동작해야 한다 — 검증 항목. |
| L10 | IME | 완료 (L10-α / β / γ) | L10-α — `zwp_text_input_v3` wire-level + `get_text_input(seat)` + keyboard focus 시점 enable/disable + `commit_string` → PTY 송신 ([76b9bb5](https://github.com/ensky0/tildaz/commit/76b9bb5)). L10-β — preedit inline overlay (보라색 배경 + foreground 글자, macOS / Windows 동등) + spec done-apply batch 패턴 ([6c685b6](https://github.com/ensky0/tildaz/commit/6c685b6)). L10-γ — Ctrl+key 시 IME 조합 discard + `set_cursor_rectangle` + `set_content_type(purpose=terminal)` ([6e46e49](https://github.com/ensky0/tildaz/commit/6e46e49)). fcitx5-hangul + Cinnamon Wayland 시연 OK. |
| L11 | Packaging | 대기 | `.desktop`, icon install, AppImage/distro package plan, autostart, final config/log path 검증 필요. |
| L12 | Tabs (multi-session UI) | 전체 완료 (α / β / γ-1~5) + Alt+1..9 보강 ([199d002](https://github.com/ensky0/tildaz/commit/199d002)) | L12-α — tab bar + 활성 탭 ([b392765](https://github.com/ensky0/tildaz/commit/b392765)). L12-β — `tab_actions.Host` + 단축키 + multi-tab + 클릭 activate + 32-tab cap + cascade 회귀 fix ([d694392](https://github.com/ensky0/tildaz/commit/d694392)). L12-γ-1 — arrow `<`/`>` + plus `+` + tab_layout.compute / scroll ([357b0ec](https://github.com/ensky0/tildaz/commit/357b0ec)). L12-γ-2 — 더블클릭 rename + IME foot 패턴 ([c5689e9](https://github.com/ensky0/tildaz/commit/c5689e9)). L12-γ-3 — drag reorder + scroll polish (viewport_left clamp + disabled arrow 색) ([b801baf](https://github.com/ensky0/tildaz/commit/b801baf)). L12-γ-4 — close 'x' 버튼 (dim 색, mac/win 동등) ([41473d9](https://github.com/ensky0/tildaz/commit/41473d9)). L12-γ-5 — Wayland client-side key repeat timer ([7248163](https://github.com/ensky0/tildaz/commit/7248163)). First Alpha Contract 의 "tab operation 동작" 이 이 milestone. |
| L13 | Config integration (사용자 설정 적용) | 완료 (L13-α / β / γ) | L13-α — `Config.load` + `resolveShell` + `g_config` + `Client` 에 config / extra_env_storage field. SessionCore.init 이 `config.shell` / `config.max_scroll_lines` / `config.theme` / `extra_env` 사용. `Defaults` 단일 struct 리팩토링 + Linux 가지 default. dialog Linux backend ([f416072](https://github.com/ensky0/tildaz/commit/f416072)). L13-β — `cfg.font_families` chain / `cfg.font_size_point` (1:1 logical pixel, mac/win 동등) / cell_ratio 두 개 적용 ([a08c3ca](https://github.com/ensky0/tildaz/commit/a08c3ca)). L13-γ — ARGB8888 buffer + paint 마지막 alpha sweep 으로 `config.opacity_percent` 반영 ([318bbef](https://github.com/ensky0/tildaz/commit/318bbef)). 나머지 (dock_position 등) 는 L8 / L9 / L11 와 통합. |

## First Alpha Contract

첫 Linux alpha는 normal Wayland terminal window여도 된다. 하지만 아래가 target
desktop에서 모두 참이 되기 전에는 full TildaZ parity를 주장하지 않는다.

- 다른 app에 focus가 있어도 global toggle이 동작한다 (L9).
- window가 monitor-aware drop-down으로 configured edge에 나타난다 (L8).
- keyboard, mouse, selection, copy, paste, resize, tab operation이 동작한다 (tab = L12).
- `AGENTS.md`의 visual regression line으로 Unicode rendering을 통과한다.
- IME pre-edit / commit behavior가 `SPEC.md`와 맞거나, 해당 desktop/session에서
  unavailable로 명확히 표시된다.
- 사용자 `config.json` 의 theme / shell / font / max_scroll_lines / auto_start
  / hidden_start 가 적용된다 (L13). drop-down / hotkey 항목은 L8 / L9 와 통합.

## Validation Checklist

Linux support를 승격할 때마다 아래를 기록한다.

- desktop/compositor 이름과 version
- Wayland session 확인
- portal implementation과 `GlobalShortcuts` availability
- layer-shell availability
- IME stack, 예: ibus 또는 fcitx, 그리고 테스트 언어
- EGL에서 사용한 GPU/driver path
- Latin, Hangul, CJK, emoji, block element font fallback 결과
- visual text regression에 사용한 정확한 command 또는 script

## 다음 작업 후보

우선순위가 높은 순서. 5c203a0 까지 완료된 항목은 ✅ 표시.

| 순서 | 작업 | 상태 |
|---|---|---|
| 1 | "소문자가 대문자처럼 보임" 원인 확정 + fix | ✅ [c8f97c8](https://github.com/ensky0/tildaz/commit/c8f97c8) — renderer limitation 으로 확정, lowercase glyph 분리 |
| 2 | 임시 renderer 로그 noise 감소 | ✅ [54b3e65](https://github.com/ensky0/tildaz/commit/54b3e65) — 매 frame redraw 로그 3 줄 제거 |
| 3 | L6.1 mouse selection drag + L6.5 휠 scroll | ✅ [41fc461](https://github.com/ensky0/tildaz/commit/41fc461) — `wl_pointer` 도입 |
| 4 | L6.2 / L6.3 / L6.4 클립보드 통합 (자동 copy + 우클릭 paste + Ctrl+Shift+C/V) | ✅ [441f894](https://github.com/ensky0/tildaz/commit/441f894) — `wl_data_device_manager` / `wl_data_source` / `wl_data_offer` + `xkb_state_mod_name_is_active`. 시연 사이클에서 opcode / xkb 상수 / self-paste deadlock / selectionString ownership 4 가지 잠재 버그 발견 + fix |
| 5 | L6.7 더블클릭 word selection | ✅ [dd40440](https://github.com/ensky0/tildaz/commit/dd40440) — 같은 cell + 500ms 이내 두 번째 좌클릭 → 공유 `terminal_interaction.selectWord` + 자동 copy |
| 6 | L6.6 스크롤바 클릭 + 드래그 | ✅ [33b760b](https://github.com/ensky0/tildaz/commit/33b760b) — 우측 8 px thumb hit test (selection/더블클릭보다 우선) + Windows `app_controller.scrollToY` 패턴. |
| 7 | pointer cursor 모양 (I-beam) | ↗ [#193](https://github.com/ensky0/tildaz/issues/193) — Win/mac/Linux 셋 다 default 화살표라 Linux 단독 추가는 parity 깨짐. cross-platform 이슈로 분리. |
| 8 | L5-1 fontconfig + FreeType + ASCII raster | ✅ [ce12372](https://github.com/ensky0/tildaz/commit/ce12372) — 5x7 임시 table 제거 + `src/font/linux/{fontconfig,freetype,font}.zig` 도입 + cell-center 정렬. proportional 폰트도 cell 안 균일 분포. |
| 9 | L5-2 HarfBuzz Latin shape | 대기 — kerning / ligature (`==` `!=` `->` 등). dlopen `libharfbuzz.so.0`. |
| 10 | L5-3 font chain + lazy raster | ✅ [88db341](https://github.com/ensky0/tildaz/commit/88db341) — N-face chain (MAX_CHAIN=8) + per-face `AutoHashMap` lazy raster. paste 한글 / 한자 / 가나 wide glyph 동작. config 통합 / 진짜 chain 폰트 추가는 별도 sub-step. |
| 11 | L5-4 emoji (color) + 임시 chain 갱신 | ✅ [4816052](https://github.com/ensky0/tildaz/commit/4816052) — `FT_LOAD_COLOR` + BGRA raster path + `drawGlyphBgra` (cell ratio scale fit + premultiplied alpha 블렌딩). chain 임시 hardcoded + fontconfig substitution 검증 (specific family 의 fallback substitution skip) + dedup log 인덱스 fix. |
| 12 | L5-5 combining mark + ZWJ + grapheme cluster | 대기 — HarfBuzz cluster output. |
| 13 | L5-6 block element | ✅ [c5bbf2a](https://github.com/ensky0/tildaz/commit/c5bbf2a) — 공유 `renderer/block_element.zig` 부착. 셀 loop 분기 + `drawBlockRect` (solid rect / shade procedural dot mask). shade 식은 d3d11 `bg_shader_src` / macOS Metal `bg_fs` 와 동일. `▀..▏` 인접 셀 사이 갭/overlap 없이 정확히 맞물림 확인. |
| 14 | Wayland startup 에러 메시지 정확성 polish | ✅ [97ee2d0](https://github.com/ensky0/tildaz/commit/97ee2d0) — X11 세션 실행 시 `FileNotFound` 한 줄 → 시도한 socket path + `WAYLAND_DISPLAY` / `XDG_SESSION_TYPE` / `XDG_RUNTIME_DIR` + 진단 hint. `error.WaylandSocketUnavailable` 의미 이름으로 변환 + `messages.linux_wayland_socket_unavailable_format` 단일 진입점. |
| 15 | L10-α IME 기초 wiring (commit_string PTY 송신) | ✅ [76b9bb5](https://github.com/ensky0/tildaz/commit/76b9bb5) — `zwp_text_input_v3` wire-level + `get_text_input(seat)` + keyboard focus 시점 enable/disable + commit_string event → PTY 송신. Cinnamon Wayland + fcitx5-hangul 시연 OK. preedit inline overlay 는 L10-β 별도. |
| 16 | L10-β preedit inline overlay | ✅ [6c685b6](https://github.com/ensky0/tildaz/commit/6c685b6) — cursor 위치 보라색 inline (`RGB(64, 64, 128)` 배경 + foreground 글자, macOS / Windows 동등) + spec done-apply batch 패턴 + IME 활성 중 redraw 트리거 fix. |
| 17 | L10-γ Ctrl+key discard / cursor rectangle / content_type | ✅ [6e46e49](https://github.com/ensky0/tildaz/commit/6e46e49) — Ctrl+key 시 client 측 preedit/pending 클리어 + `set_cursor_rectangle` (캐시 비교로 spam 회피) + `set_content_type(purpose=terminal)` 적용. Cinnamon + fcitx5-hangul 시연 OK. |
| 18 | L12 Tabs (multi-session UI) | 대기 — 공유 cross-platform 모듈 (`session_core` / `tab_actions` / `tab_interaction` / `tab_layout`) 은 이미 사용 중, Linux 만 비어 있음. ① tab bar 렌더링 ② pointer 라우팅 ③ Ctrl+T/W/Tab 단축키 + 32-tab cap ④ multi-PTY 라이프사이클 (sub-step 으로 쪼개서 진행). |
| 19 | L13-α Config integration 기초 hook | ✅ [f416072](https://github.com/ensky0/tildaz/commit/f416072) — `Config.load` + `resolveShell` + Client.config / extra_env_storage + Defaults 단일 struct 리팩토링 + dialog Linux backend. shell / theme / max_scroll_lines / extra_env (TERM / LANG / LC_CTYPE / COLORFGBG / SHELL) 사용자 값 적용. |
| 20 | L13-β config.font / cell_ratio 통합 | ✅ [a08c3ca](https://github.com/ensky0/tildaz/commit/a08c3ca) — `cfg.font_families` chain / `cfg.font_size_point` (1:1, mac/win 동등) / `cfg.cell_width_ratio` / `cfg.line_height_ratio` 가 `font.Context` 와 cell metric 에 반영. `default_families` / `default_pixel_height` 하드코딩 제거. 시연 사이클에서 pt-pixel 변환 비대칭 (1.33x) 발견 + fix. |
| 21 | L13-γ config.opacity_percent | ✅ [318bbef](https://github.com/ensky0/tildaz/commit/318bbef) — Wayland buffer format XRGB8888 → ARGB8888 + paint 끝 alpha sweep 으로 일괄 적용. 호출 site 변경 없이 단일 sweep 으로 통합. |
| 22 | L8-α layer-shell drop-down surface (baseline) | ✅ [4673a2e](https://github.com/ensky0/tildaz/commit/4673a2e) — `caps.layer_shell.name != 0` 시 xdg-shell toplevel 대신 layer-shell surface. top+left+right anchor + 고정 400px + exclusive keyboard. UTM Debian arm64 mutter Wayland 에서 가로 full screen (1440px) + 입력 / 탭 / clipboard / IME enter/leave 회귀 없음 확인. |
| 22-β | L8-β config 반영 (`dock_position` / `width_percent` / `height_percent` / `offset_percent`) | ✅ [5c203a0](https://github.com/ensky0/tildaz/commit/5c203a0) — `wl_output.mode` 로 screen 크기 받음 + `LayerLayout` 으로 anchor / size / margin 변환 (mac `screenFrameForDock` 동등). 시연 OK (UTM mutter + KDE Plasma KWin). 한계: KDE Plasma floating dock 의 floating margin 영역까지 회피 안 됨 (현재 제한 사항 섹션). |
| 23 | L9 global shortcut | 진행 중 — α / β-1 feat ([0a9e7f6](https://github.com/ensky0/tildaz/commit/0a9e7f6) / [2af21c2](https://github.com/ensky0/tildaz/commit/2af21c2)), β-2 / γ `wip:` ([992a2a7](https://github.com/ensky0/tildaz/commit/992a2a7) / [8680ac7](https://github.com/ensky0/tildaz/commit/8680ac7)). KDE Plasma 6 진단 진행 중 — `.desktop` install 후 KDE Settings owner = TildaZ 표시 OK, 그러나 KGlobalAccel runtime register silent skip (`kglobalshortcutsrc` 의 actual key empty). 자세한 일지 / 가설 / 다음 단계는 "현재 제한 사항" 섹션. |
| 24 | L9-γ 진단 마무리 (portal cache 삭제 + 재시도) | 다음 PC 에서 — `~/.local/state/xdg-desktop-portal-kdestaterc` 확인 + `kglobalshortcutsrc` tildaz entry 삭제 + portal-kde 재시작 + dialog 진짜 뜨는지 검증. Yakuake F1 임시 disable 권장 (conflict 제거). |
| 25 | L9-δ Workaround — KGlobalAccel D-Bus 직접 호출 (portal 끝까지 안 동작 시) | 대기 — Yakuake 패턴. `org.kde.KGlobalAccel` 의 `doRegister` / `setForeignShortcut` / `globalShortcutPressed` signal. cross-desktop 영향 0 (KGlobalAccel D-Bus 없는 환경은 자연 skip). |
| 24 | L11 packaging | 대기 — `.desktop` / icon / AppImage / autostart / config-log path 검증. |
| 25 | L12-α tab bar 렌더링 (활성 탭 1 개) | ✅ [b392765](https://github.com/ensky0/tildaz/commit/b392765) — 28px tab bar + 활성 탭 + title text + pointer→cell offset 보정. 비활성 / 클릭 라우팅 / drag / 단축키는 L12-β/γ. |
| 26 | L13-α LANG 회귀 fix | ✅ [db53efb](https://github.com/ensky0/tildaz/commit/db53efb) — Linux default LANG/LC_CTYPE 을 C.UTF-8 (POSIX 표준) 로. `en_US.UTF-8` 미설치 환경에서 bash readline single-byte 모드로 빠지던 회귀 fix. |
| 27 | L12-β tab 단축키 + multi-tab + 클릭 activate | ✅ [d694392](https://github.com/ensky0/tildaz/commit/d694392) — `tab_actions.Host` 부착 + Ctrl+Shift+T/W/]/[ + 클릭 activate + 32-tab cap dialog. 시연 사이클에서 multi-tab cascade 종료 회귀 발견 + fix (macOS `pending_close_buf` + main loop drain). |
| 28 | L12-γ-1 arrow / plus + tab_layout.compute 통합 | ✅ [357b0ec](https://github.com/ensky0/tildaz/commit/357b0ec) — 탭 폭 합 > viewport 시 `<` `>` `+` 등장 + 자동 scroll + 수동 scroll override + cross-platform `tab_layout.compute` 사용. |
| 29 | L12-γ-4 tab close 'x' 버튼 | ✅ [41473d9](https://github.com/ensky0/tildaz/commit/41473d9) — 각 탭 우측 끝 'x' 글리프 (mac/win 동등 dim 색) + hit.on_close → closeIndex. 시연 사이클에서 임시 추가했던 우클릭 close 는 SPEC 외라 원복. |
| 30 | L12-γ-2 더블클릭 rename + IME foot 패턴 정밀화 | ✅ [c5689e9](https://github.com/ensky0/tildaz/commit/c5689e9) — 탭바 더블클릭 → cross-platform `tab_interaction.RenameState` 부착 (mac/win 공유). Enter commit (`setCustomTitle`), Escape cancel, 클릭 cursor positioning, IME 한글 commit buffer 삽입, 포커스 loss 시 preedit 자동 commit (mac/win 동등). `zwp_text_input_v3` foot 패턴 정밀화 — `enableTextInput` 한 batch + `text_input.leave` 가 disable+commit + `wl_keyboard.enter/leave` 의 enable/disable 제거. VSCode→tildaz 회귀는 foot 동일 증상 → fcitx5 X11/Wayland frontend separation 환경 한계 ([#194](https://github.com/ensky0/tildaz/issues/194)). |
| 31 | L12-γ-3 drag reorder + scroll polish | ✅ [b801baf](https://github.com/ensky0/tildaz/commit/b801baf) — cross-platform `tab_interaction.DragState` 부착 (mac/win 공유). left press → begin, motion → 30px 가장자리 auto-scroll + move, release → finish → `session.reorderTabs`. drag source 글자 50% blend + drop_idx 2px 세로 indicator. `finish` 의 `defer reset` 으로 cancel 자동. 묶음 scroll polish: ① `viewport_left = @max(text_x_start, tab_area_x)` — 부분 잘린 첫 탭 text 가 `<` arrow 영역 invade 방지 (mac/win 의 native clip 동등 software 패턴). ② `<` / `>` 색 분기 (enabled `TAB_CTRL_ACTIVE_COLOR` 0.95 / disabled `TAB_ARROW_DISABLED_COLOR` 0.4, mac/win 동등). plus 는 항상 enabled. |
| 31 | L12-γ-3 drag reorder | 대기 — 좌클릭 drag 시 tab 위치 swap. `tab_actions` 의 reorder helper 사용. |
| 32 | L12-γ-5 key repeat (Wayland client-side timer) | ✅ [7248163](https://github.com/ensky0/tildaz/commit/7248163) — `wl_keyboard.repeat_info` rate/delay + `maybeRepeatKey()` main loop timer. press → arm, release/leave → disarm. IME 활성 시 fcitx5 자체 repeat (충돌 없음). |

## Source Notes

- XDG Desktop Portal `GlobalShortcuts`는 app focus 밖 global shortcut 등록을 위한
  permissioned cross-desktop API다:
  <https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html>
- `wlr-layer-shell`은 output edge에 anchor할 수 있는 desktop layer surface를 만든다:
  <https://wayland.app/protocols/wlr-layer-shell-unstable-v1>
- `xdg-shell`은 normal desktop-style toplevel window를 위한 baseline Wayland protocol이다:
  <https://wayland.app/protocols/xdg-shell>
- gtk-layer-shell 문서는 layer-shell이 해당 protocol을 지원하는 Wayland compositor에서만
  의미가 있다고 설명한다:
  <https://wmww.github.io/gtk-layer-shell/gtk-layer-shell.html>
- KDE LayerShellQt는 layer-shell Wayland shell integration을 감싼 Qt integration layer다:
  <https://api.kde.org/plasma/layer-shell-qt/html/index.html>
- `libxkbcommon`은 Wayland, GTK, Qt, KWin 등이 사용하는 공통 keyboard handling library다:
  <https://xkbcommon.org/>
- Wayland text-input v3는 pre-edit과 commit string event를 제공하지만 protocol family는
  아직 unstable/experimental이다:
  <https://wayland.app/protocols/text-input-unstable-v3>
