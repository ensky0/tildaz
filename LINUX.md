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
- Commit: `5a1dcad`
- 실행 경로: `zig build && ./zig-out/bin/tildaz`
- 결과: normal Wayland terminal window가 뜬다.
- shell 출력이 보인다.
- typing이 PTY로 들어간다.
- Backspace가 동작한다.
- `exit` 명령으로 shell/app이 종료된다.
- 같은 크기의 `wl_shm` buffer는 2개 생성 후 재사용된다.

사용자 제공 로그에서 확인된 capability:

```text
wl_compositor=true
wl_shm=true
xdg_wm_base=true
zwlr_layer_shell_v1=true
zwp_text_input_manager_v3=true
```

buffer lifecycle 확인:

```text
create shm buffer 640x420 ... buffer_id=15
create shm buffer 640x420 ... buffer_id=17
redraw reuse retired 640x420 buffer_id=15
redraw reuse 640x420 buffer_id=15
redraw reuse retired 640x420 buffer_id=17
redraw reuse 640x420 buffer_id=17
```

판정:

- 이전 `wl_registry#2.bind invalid arguments` protocol error는 해결됐다.
- 이전 green placeholder 고정 문제는 해결됐다.
- 이전 black screen 후 redraw가 멈추는 문제는 해결됐다.
- 이전 unbounded `wl_shm` buffer churn은 해결됐다.
- 지금은 “아주 초기 normal terminal window” 단계다. first alpha라고 부르기에는
  selection / copy / paste / real font / Unicode / drop-down / global shortcut /
  IME가 아직 부족하다.

## 현재 제한 사항

### 임시 software renderer

현재 Linux renderer는 `src/host/linux/software_terminal.zig`에 있는 임시
software-only renderer다. `ghostty-vt` render state를 `wl_shm` XRGB8888
buffer에 직접 그려서 PTY - parser - resize - frame lifecycle을 먼저 검증하기
위한 코드다.

이 renderer는 최종 renderer가 아니다. EGL/OpenGL, fontconfig, FreeType,
HarfBuzz가 붙기 전까지의 bring-up용 경로다.

### 소문자가 대문자처럼 보이는 현상

사용자 테스트에서 “모두 대문자로 나온다”는 현상이 관찰됐다.

현재 확인된 코드 근거상, 이 현상은 입력이 실제로 대문자로 바뀌는 버그라고
단정하면 안 된다. 임시 renderer의 bitmap glyph table이 소문자와 대문자에 같은
5x7 glyph를 배정하고 있다.

예:

```zig
'A', 'a' => ...
'B', 'b' => ...
'C', 'c' => ...
```

즉 현재 상태에서는 `echo hi`를 입력해도 내부 terminal에는 lowercase가 들어갔을
수 있지만, 화면 표시 glyph가 uppercase처럼 보일 수 있다.

다음 작업자가 확인해야 할 것:

- PTY로 실제 전달되는 bytes가 lowercase인지 확인한다.
- `src/host/linux/wayland_minimal.zig`의 keyboard path에 짧은 debug log를 넣어
  `key`, `xkb_key`, `keysym`, `utf8 bytes`를 확인한다.
- lowercase bytes가 정상이라면 이 문제는 L5 real font renderer에서 자연스럽게
  해결된다.
- bytes 자체가 uppercase라면 L6 `libxkbcommon` state / modifier handling 버그로
  처리한다.

### 아직 검증되지 않은 것

- mouse selection
- scrollback interaction
- copy
- paste
- tab shortcuts
- resize UX polish
- Hangul / CJK / emoji / combining marks / grapheme cluster / block elements
- layer-shell drop-down
- global shortcut
- IME pre-edit / commit
- `.desktop` / packaging / autostart
- compositor별 차이: GNOME, KDE Plasma, wlroots 계열

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
| L4 | EGL/OpenGL renderer | 부분 완료, 단 EGL/OpenGL은 아님 | 임시 software `wl_shm` renderer로 terminal grid는 보임. final GPU renderer는 아직. |
| L5 | Fonts | 대기 | 현재는 small bitmap glyph table. fontconfig + FreeType + HarfBuzz 미구현. |
| L6 | Input and clipboard | keyboard만 부분 완료 | `wl_keyboard` + runtime `libxkbcommon` keymap loading 성공. typing / Backspace / `exit` 확인. mouse selection, scroll, copy, paste, tab shortcuts 대기. |
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

우선순위가 높은 순서:

1. 현재 “소문자가 대문자처럼 보이는” 현상을 입력 문제인지 renderer 문제인지 확정한다.
   현재 코드 근거상 renderer limitation 가능성이 높다.
2. 임시 renderer 로그를 줄인다. 지금 `redraw reuse...` 로그는 bring-up에는
   유용하지만 장기 실행에는 너무 많다.
3. mouse selection / scroll / copy / paste 중 하나를 L6 후반 작업으로 시작한다.
4. real font path를 시작한다. 최소 Latin lowercase 분리부터 확인하고,
   이후 Hangul/CJK/emoji/block으로 확장한다.
5. layer-shell prototype을 별도 작은 milestone로 진행한다.

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
