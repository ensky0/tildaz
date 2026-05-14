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
| True drop-down | compositor가 `wlr-layer-shell`을 광고하면 layer-shell 기반 drop-down을 목표로 한다. |
| GNOME support | 초기에는 limited support. hack 없이 full drop-down workflow가 가능한 경로가 확인되면 바로 full support로 승격한다. |
| Global shortcut | XDG Desktop Portal `GlobalShortcuts` 우선. 지원이 없으면 조용히 실패하지 말고 명확히 제한 사항을 남긴다. |
| Keyboard | `libxkbcommon`. 현재는 런타임 `dlopen("libxkbcommon.so.0")` 방식. |
| IME | Wayland text-input v3 목표. desktop / IME 호환성은 별도 검증한다. |
| Renderer | 원래 계획은 EGL + OpenGL ES 우선. 현재 구현은 bring-up용 software `wl_shm` renderer다. |
| Font stack | 최종 목표는 fontconfig + FreeType + HarfBuzz. 현재는 임시 bitmap glyph table이다. |
| First alpha scope | normal window, POSIX PTY, 기본 rendering, keyboard/mouse input, selection, copy/paste. |

## 현재 구현 상태

2026-05-14, UTM Debian Wayland 환경에서 확인된 상태다.

- Branch: `linux-wayland-bringup`
- Commit: `41fc461`
- 실행 경로: `zig build && ./zig-out/bin/tildaz`

| 영역 | 상태 |
|---|---|
| normal Wayland terminal window | 동작 |
| shell 출력 표시 | 동작 |
| typing → PTY | 동작 (lowercase / uppercase 시각 구분 포함) |
| Backspace / `exit` / shell exit | 동작 |
| `wl_shm` buffer lifecycle | 같은 크기 buffer 2 개 reuse, churn 없음 |
| 마우스 좌클릭 + 드래그 selection | 동작 (셀 영역 색 반전 표시). 자동 clipboard copy 는 미구현 |
| 휠 스크롤 (scrollback) | 동작 |
| 로그 noise | bring-up 단계 매 frame redraw 로그 제거, lifecycle 변화 이벤트만 |

사용자 제공 로그에서 확인된 capability:

```text
wl_compositor=true
wl_shm=true
xdg_wm_base=true
zwlr_layer_shell_v1=true
zwp_text_input_manager_v3=true
```

41fc461 시연 로그 (47 초 사용 + 마우스 드래그 + 휠 + shell exit):

```text
[boot] tildaz v0.4.3  pid=...
[wayland] bound globals compositor_id=4 shm_id=5 wm_base_id=6 seat_id=7
[wayland] keyboard object created keyboard_id=9
[wayland] pointer object created pointer_id=10
[wayland] capabilities compositor=true shm=true xdg_wm_base=true layer_shell=true text_input_v3=true shm_xrgb8888=true
[wayland] keyboard repeat rate=25 delay=600
[wayland] keyboard keymap loaded size=64822
[wayland] shell objects surface_id=12 xdg_surface_id=13 toplevel_id=14
[linux] terminal session created cols=78 rows=25
[wayland] create shm buffer 640x420 stride=2560 size=1075200 pool_id=15 buffer_id=16
[linux] Wayland terminal window mapped
[wayland] create shm buffer 640x420 stride=2560 size=1075200 pool_id=17 buffer_id=18
[tab] shell exited: title=Tab 1
[exit] tildaz v0.4.3  pid=...
```

판정:

- 이전 protocol / green placeholder / black screen / buffer churn 회귀는 그대로 해결 상태 유지.
- 이전에 보였던 매 frame `redraw ...` / `redraw reuse ...` / `redraw reuse retired ...` 로그는 정리돼 lifecycle 이벤트만 보임 ([commit 54b3e65](https://github.com/ensky0/tildaz/commit/54b3e65)).
- 이전에 보였던 "모두 대문자처럼 보임" 현상은 임시 renderer 의 glyph table 매핑 버그로 확정 후 분리 ([commit c8f97c8](https://github.com/ensky0/tildaz/commit/c8f97c8)).
- 마우스 selection drag + 휠 scroll 동작 추가 ([commit 41fc461](https://github.com/ensky0/tildaz/commit/41fc461)).
- 지금은 "normal terminal window + 키보드 + 마우스 selection drag + 휠 scroll" 단계. first alpha 라고 부르기에는 clipboard copy / paste / real font / Unicode / drop-down / global shortcut / IME 가 아직 부족하다.

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

### 아직 검증되지 않은 것

| 항목 | 상태 |
|---|---|
| selection finish 시 자동 clipboard copy | 미구현 (L6.2 대기) |
| 우클릭 paste / 단축키 paste | 미구현 (L6.3 / L6.4 대기) |
| 단축키 copy (Ctrl+Shift+C) | 미구현 (L6.4 대기) |
| 더블클릭 word selection | 미구현 (L6.7 대기) |
| 스크롤바 클릭 / 드래그 | 미구현 (L6.6 대기) |
| pointer cursor 모양 (I-beam) | 미구현 — `wl_pointer.set_cursor` 미호출. compositor 가 default 화살표 또는 cursor 미표시 가능 |
| resize UX polish | 미검증 |
| Hangul / CJK / emoji / combining mark / grapheme cluster / block element | 미구현 (L5 real font 후) |
| layer-shell drop-down | 미구현 (L8 대기) |
| global shortcut | 미구현 (L9 대기) |
| IME pre-edit / commit | 미구현 (L10 대기) |
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
| L5 | Fonts | 대기 | 현재는 small bitmap glyph table. fontconfig + FreeType + HarfBuzz 미구현. Latin lowercase / uppercase 시각 구분만 임시로 확보. |
| L6 | Input and clipboard | keyboard + mouse selection drag + 휠 scroll 까지 | `wl_keyboard` + runtime `libxkbcommon` keymap loading 성공. `wl_pointer` 도입 후 셀 영역 selection drag + 휠 scroll 동작 ([41fc461](https://github.com/ensky0/tildaz/commit/41fc461)). 남은 sub-task: clipboard copy 자동 / 단축키 copy / paste / 더블클릭 word selection / 스크롤바 클릭·드래그 / pointer cursor 모양. |
| L7 | First alpha | 대기 | normal window에서 PTY/render/input + selection/copy/paste가 모두 되어야 함. |
| L8 | Layer-shell drop-down | 대기 | 테스트 session에서 `zwlr_layer_shell_v1`은 광고되지만 layer-shell surface는 아직 미구현. |
| L9 | Global shortcut | 대기 | XDG Desktop Portal `GlobalShortcuts` integration 미시작. |
| L10 | IME | 대기 | 테스트 session에서 `zwp_text_input_manager_v3`은 광고되지만 pre-edit / commit path 미구현. |
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

우선순위가 높은 순서. 41fc461 까지 완료된 항목은 ✅ 표시.

| 순서 | 작업 | 상태 |
|---|---|---|
| 1 | "소문자가 대문자처럼 보임" 원인 확정 + fix | ✅ [c8f97c8](https://github.com/ensky0/tildaz/commit/c8f97c8) — renderer limitation 으로 확정, lowercase glyph 분리 |
| 2 | 임시 renderer 로그 noise 감소 | ✅ [54b3e65](https://github.com/ensky0/tildaz/commit/54b3e65) — 매 frame redraw 로그 3 줄 제거 |
| 3 | L6.1 mouse selection drag + L6.5 휠 scroll | ✅ [41fc461](https://github.com/ensky0/tildaz/commit/41fc461) — `wl_pointer` 도입 |
| 4 | L6.2 selection finish 자동 clipboard copy | 대기 — `wl_data_device_manager` / `wl_data_source` 도입 필요. selection 끝 → fd write → clipboard. |
| 5 | L6.3 우클릭 paste | 대기 — `wl_data_offer` 도입 필요. paste fd 비동기 읽기 + PTY write. |
| 6 | L6.4 단축키 copy / paste (Ctrl+Shift+C / V) | 대기 — keyboard path + L6.2 / L6.3 의 clipboard wrapper 재사용. |
| 7 | L6.7 더블클릭 word selection | 대기 — click count 추적 + 공유 [`terminal_interaction.selectWord`](src/terminal_interaction.zig) 호출. |
| 8 | L6.6 스크롤바 클릭 + 드래그 | 대기 — hit test + cross-platform `ScrollbarDragState`. |
| 9 | pointer cursor 모양 (I-beam) | small follow-up — `wl_pointer.set_cursor` + cursor theme 로딩. 셀 영역 hover 시 I-beam. |
| 10 | L5 real font stack | 대기 — fontconfig discovery + FreeType raster + HarfBuzz shaping. Latin / Hangul / CJK / emoji / block element 순차. |
| 11 | L8 layer-shell drop-down prototype | 대기 — `zwlr_layer_shell_v1` 광고 확인됨. anchor / exclusive zone / monitor 선택 검증. |
| 12 | L9 global shortcut | 대기 — XDG Desktop Portal `GlobalShortcuts` over D-Bus. |
| 13 | L10 IME | 대기 — `zwp_text_input_manager_v3` pre-edit / commit path. |
| 14 | L11 packaging | 대기 — `.desktop` / icon / AppImage / autostart / config-log path 검증. |

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
