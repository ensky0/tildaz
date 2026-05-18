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
- Commit: `76b9bb5`
- 실행 경로: `zig build && ./zig-out/bin/tildaz`

| 영역 | 상태 |
|---|---|
| normal Wayland terminal window | 동작 |
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
| 한글 IME 입력 (fcitx5 + Cinnamon Wayland) | 동작 — `zwp_text_input_v3` wire-level 구현 + commit_string event → PTY 송신. 음절 완성 시점에 글자 도달. preedit inline overlay 는 L10-β 대기 |
| Wayland 미연결 startup 에러 메시지 | path + WAYLAND_DISPLAY / XDG_SESSION_TYPE / XDG_RUNTIME_DIR + 진단 hint 출력 (`error.WaylandSocketUnavailable`) |
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
- 지금은 "normal terminal window + 키보드 + 마우스 selection drag + 더블클릭 word + 휠 scroll + 스크롤바 클릭/드래그 + clipboard (자동 copy / 우클릭 paste / 단축키) + ASCII real font (mono polish) + paste 시 한글 / CJK wide glyph + color emoji + block element + 한글 IME 직접 입력 (음절 commit, preedit overlay 미부착)" 단계. first alpha 라고 부르기에는 HarfBuzz shape / drop-down / global shortcut / preedit overlay 가 아직 부족하다.

## 현재 제한 사항

### 임시 software renderer

현재 Linux renderer는 `src/host/linux/software_terminal.zig`에 있는 임시
software-only renderer다. `ghostty-vt` render state를 `wl_shm` XRGB8888
buffer에 직접 그려서 PTY - parser - resize - frame lifecycle을 먼저 검증하기
위한 코드다.

이 renderer는 최종 renderer가 아니다. EGL/OpenGL, fontconfig, FreeType,
HarfBuzz가 붙기 전까지의 bring-up용 경로다.

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
| layer-shell drop-down | 미구현 (L8 대기) |
| global shortcut | 미구현 (L9 대기) |
| IME commit (음절 PTY 송신) | 동작 ([76b9bb5](https://github.com/ensky0/tildaz/commit/76b9bb5), fcitx5 + Cinnamon Wayland) — L10-α |
| IME preedit inline overlay (보라색) | 미구현 (L10-β 대기) — preedit_string event 는 받지만 화면에 안 그림 |
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
| L8 | Layer-shell drop-down | 대기 | 테스트 session 의 compositor 가 `zwlr_layer_shell_v1` 을 client 에게 노출 (Wayland 용어 *advertise* — `wl_registry.global` 로 보내는 protocol 지원 통보) 하는 건 확인됐지만, TildaZ 가 그 위에 layer-shell surface 를 만드는 코드는 아직 미구현. |
| L9 | Global shortcut | 대기 | XDG Desktop Portal `GlobalShortcuts` integration 미시작. **명시 요구사항**: 다른 X11 / Electron 앱 (예: VSCode) 이 focus 잡고 있을 때도 hotkey 가 TildaZ 에 도달해야 한다. X11 시대의 Tilda 가 동일 시나리오에서 VSCode focus 시 F1 이 안 닿는 quirk 가 있는데 (`XGrabKey` 가 XWayland 안 X11 client 의 grab 에 가려짐), TildaZ 는 Wayland native client 로서 portal `GlobalShortcuts` 가 compositor 레벨 routing 이라 focus 무관히 동작해야 한다 — 검증 항목. |
| L10 | IME | L10-α 완료, L10-β/γ 대기 | L10-α — `zwp_text_input_v3` wire-level 구현 + `bindGlobals` 에서 `get_text_input(seat)` + `wl_keyboard.enter` 시 enable+commit / leave 시 disable+commit + `commit_string` event → `queueInput` 으로 PTY 송신 ([76b9bb5](https://github.com/ensky0/tildaz/commit/76b9bb5)). fcitx5-hangul + Cinnamon Wayland 환경에서 한글 음절 완성 시 PTY 도달 확인. L10-β — preedit inline overlay (macOS/Windows 와 동등 보라색 inline) 대기. L10-γ — Ctrl+key 시 IME 조합 discard / cursor rectangle / content_type 부가 protocol 대기. |
| L11 | Packaging | 대기 | `.desktop`, icon install, AppImage/distro package plan, autostart, final config/log path 검증 필요. |

## First Alpha Contract

첫 Linux alpha는 normal Wayland terminal window여도 된다. 하지만 아래가 target
desktop에서 모두 참이 되기 전에는 full TildaZ parity를 주장하지 않는다.

- 다른 app에 focus가 있어도 global toggle이 동작한다.
- window가 monitor-aware drop-down으로 configured edge에 나타난다.
- keyboard, mouse, selection, copy, paste, resize, tab operation이 동작한다.
- `AGENTS.md`의 visual regression line으로 Unicode rendering을 통과한다.
- IME pre-edit / commit behavior가 `SPEC.md`와 맞거나, 해당 desktop/session에서
  unavailable로 명확히 표시된다.

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

우선순위가 높은 순서. 76b9bb5 까지 완료된 항목은 ✅ 표시.

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
| 16 | L10-β preedit inline overlay | 대기 — cursor 위치 보라색 inline (macOS / Windows 와 동등, AGENTS.md "한글 IME 동작 스펙"). software renderer 의 cursor 위치에 preedit text 를 위로 덮어 그리기. |
| 17 | L10-γ Ctrl+key discard / cursor rectangle / content_type | 대기 — Ctrl+key 시 IME 조합 buffer discard (AGENTS.md macOS quirk 3번 동등) + 우리 cursor 위치를 `set_cursor_rectangle` 로 server 에 알려 fcitx5 popover 위치 정렬 + content_type 으로 url / password / latin-name 같은 hint 제공. |
| 9 | L8 layer-shell drop-down prototype | 대기 — compositor 가 `zwlr_layer_shell_v1` 을 client 에게 노출 (*advertise*) 하는 건 확인됨. anchor / exclusive zone / monitor 선택 검증 필요. |
| 10 | L9 global shortcut | 대기 — XDG Desktop Portal `GlobalShortcuts` over D-Bus. |
| 11 | L10 IME | 대기 — `zwp_text_input_manager_v3` pre-edit / commit path. |
| 12 | L11 packaging | 대기 — `.desktop` / icon / AppImage / autostart / config-log path 검증. |

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
