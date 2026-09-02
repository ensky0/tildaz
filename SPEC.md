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
| 표시 모니터 (멀티모니터) | **마우스 커서가 있는 모니터**에 등장 (drop-down 표준 UX). show() / hotkey toggle show 시 적용 — work-area relayout(해상도/DPI 변화)은 현재 모니터 유지 | show() 시 [`Window.monitorInfoFor(.cursor)`](src/window.zig) → `GetCursorPos` / `MonitorFromPoint` | `NSEvent.mouseLocation` 을 포함하는 NSScreen (`screenForCursor`, [host/macos.zig](src/host/macos.zig)) — 없으면 `NSScreen.mainScreen` fallback ([#240](https://github.com/ensky0/tildaz/issues/240)) | layer-shell 계열은 compositor 가 커서 출력에 anchor. mutter/muffin fallback 은 GNOME(#228)/Cinnamon(#229) extension 이 `get_current_monitor()`(커서 모니터)로 배치 | ✅ | ✅ ([#240](https://github.com/ensky0/tildaz/issues/240) — `screenForCursor`, 멀티모니터 실기 검증) | ✅ (extension 계열) |
| Borderless | titlebar / 사각 모서리 | `WS_POPUP` styleMask | `NSWindowStyleMaskBorderless` + `canBecomeKeyWindow` override | layer-shell 본질 — toplevel 없음, decoration 없음 | ✅ | ✅ | ✅ |
| Shadow | 없음 (drop-down 정체) | (default 없음) | `setHasShadow:false` 안 함 (default true 시각 자연) | compositor 결정 (KDE / GNOME 모두 layer-surface 에 shadow 안 적용) | ✅ | ✅ | ✅ |
| 사용자 드래그 차단 | 사용자가 위치 / 크기 변경 못함 | `WS_POPUP` 자연 차단 | `setMovable:false` + non-resizable | layer-shell 본질 — anchor 가 위치 강제, 사용자 drag 불가 | ✅ | ✅ | ✅ |
| Dock 위치 (config) | top / bottom / left / right | `setPosition` | `repositionWindow` | `set_anchor(top\|bottom\|left\|right)` ([ba89f0d](https://github.com/ensky0/tildaz/commit/ba89f0d), L8-β) | ✅ | ✅ | ✅ |
| 크기 비율 (config) | width / height percent | `setPosition` | `repositionWindow` | `wl_output.mode` × percent → `set_size` (L8-β) | ✅ | ✅ | ✅ |
| 위치 offset (config) | dock 안 시작 위치 0..100 | `setPosition` | `repositionWindow` | opposing edge anchor + margin (L8-β) | ✅ | ✅ | ✅ |
| Opacity (config) | 0..100 percent → alpha | 100%: normal flip-model; below 100%: `WS_EX_NOREDIRECTIONBITMAP` + DirectComposition visual opacity ([#89](https://github.com/ensky0/tildaz/issues/89)) | `NSWindow.setAlphaValue:` | ARGB8888 alpha sweep ([fa4e036](https://github.com/ensky0/tildaz/commit/fa4e036), L13-γ) | ✅ | ✅ | ✅ |
| Theme (config) | 16-color palette + bg/fg | `themes.findTheme` → ghostty Terminal.Colors | 동일 | 동일 (cross-platform `themes` 모듈) | ✅ | ✅ | ✅ |
| 단일 탭 시 상단 chrome ([#329](https://github.com/ensky0/tildaz/issues/329)) | full 탭바 자리 없음. 우측 상단에 `[+][×][…]` 72×28 logical pt strip만 terminal 위에 overlay. terminal grid y-offset은 0, scrollbar draw/hit track만 28pt 아래에서 시작 | `effectiveTabBarHeight()==0`, 별도 `scrollbarTopInset()` + renderer final overlay | `tabBarHeightPx()==0`, 별도 `scrollbarTopInsetPx()` + Metal final overlay | `Renderer.tabBarHeightPx(1)==0`, 별도 `chromeHeightPx()` + software final overlay | ✅ | ✅ | ✅ |
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
| `SCROLLBAR_W_PT` | 10 | `App.SCROLLBAR_W` | `scrollbar_w_px` | `Renderer.scrollbarWPx()` |
| `SCROLLBAR_MIN_THUMB_H_PT` | 32 | `App.SCROLLBAR_MIN_THUMB_H` | `scrollbar_min_thumb_h_px` | `Renderer.scrollbarMinThumbHPx()` |
| `TAB_BAR_HEIGHT_PT` | 28 | `ui_metrics.tabBarHeightPx(scale)` | 동일 | 동일 |
| `TAB_LABEL_FONT_PT` | 13 | tab 전용 DWrite context + atlas | tab 전용 CoreText context + atlas/texture | tab 전용 FreeType context + glyph cache |
| `TAB_WIDTH_PT` | 150 | `App.TAB_WIDTH` | `tab_w_px = TAB_WIDTH_PT × scale` | `Renderer.tabWidthPx()` |
| `TAB_PADDING_PT` | 6 | `App.TAB_PADDING` | `tab_pad_px` | `Renderer.tabPaddingPx()` |
| `TAB_GAP_PT` | 2 | `tabGapPx(App.dpi_scale)` | `tabGapPx(Renderer.scale)` | `tabGapPx(scale)` 후 정수 px 반올림 |
| `TAB_CLOSE_W_PT` | 24 | `App.TAB_CLOSE_W` | `tabBarLayoutInputs` | `Renderer.tabCloseWPx()` |
| `TAB_ARROW_W_PT` | 24 | `App.TAB_ARROW_W` | `arrow_w_px` | `Renderer.tabArrowWPx()` |
| `TAB_PLUS_W_PT` | 24 | `App.TAB_PLUS_W` | `plus_w_px` | `Renderer.tabPlusWPx()` |

**`pt → px` 변환은 반올림이고 공통 함수만 쓴다** ([#350](https://github.com/ensky0/tildaz/issues/350) 2026-07-30 확정). 위 표의 각 `*_PT` 를 physical pixel 로 바꿀 때 세 platform 이 **같은 규칙**을 쓰고, 계산은 [`src/ui_metrics.zig`](src/ui_metrics.zig) 의 세 함수에만 있다. host / renderer 가 `@round(@as(f32, @floatFromInt(X_PT)) * scale)` 을 직접 적지 않는다.

| 함수 | 결과 | 쓰는 자리 |
|---|---|---|
| `scaledPx(T, pt, scale)` | 정수 px, **반올림** (`@round`). `T` 로 호출처 정수 타입 지정 | 격자 / 레이아웃처럼 정수 픽셀이 필요한 곳 |
| `scaledPxF(pt, scale)` | f32 px, 정수 스냅 없음 | 그리기 좌표 (서브픽셀 유지) |
| `strokePx(pt, scale)` | f32 px + **최소 1px**, 소수 유지 | **아이콘 stroke 전용** (`TAB_ICON_STROKE_PT` · `TAB_MORE_DOT_DIAMETER_PT`) — `tab_icons.rasterize` 가 안티에일리어싱 커버리지를 만들어 소수가 의미를 갖는다 |
| `linePx(pt, scale)` | **정수** px + 최소 1px | **선 두께** (탭바 세로 구분선 · 활성 탭 amber 밑줄 · command menu 항목 구분선) — 격자에 놓이는 실선 |

`scaledPx` 는 `scaledPxF` 를 반올림한 것으로 정의해 두 함수가 어긋날 수 없다. 반올림을 택한 것은 다수 규칙(당시 18곳)에 맞춘 것이고, 버림보다 원래 pt 크기에 가깝다 (`round(12.5) = 13` vs `trunc(12.5) = 12`).

**왜 사양으로 못 박는가.** 이전에는 같은 변환이 세 platform 에 흩어져 있었고 **규칙이 갈렸다** — Linux (`scaledPt`) 와 Windows (`app_controller`) 는 반올림, macOS `host/macos.zig` 9곳은 버림이었다 (`TERMINAL_PADDING_PT` 5곳 · `SCROLLBAR_W_PT` 3곳 · `TAB_WIDTH_PT` 2곳). macOS 안에서도 `renderer/macos.zig` 의 아이콘 크기는 반올림이라 파일마다 달랐다. `backingScaleFactor` 가 1.0 / 2.0 이라 정수 배율에서는 두 규칙의 결과가 같아 증상이 드러나지 않았을 뿐이고 (fractional scale 에서 1px 갈린다), 같은 상수를 platform 마다 다른 픽셀로 바꾸는 것은 §0 #1 (세 platform 동등) 에 어긋난다. 바로 위 항목의 격자 열 수 식에 들어가는 `TERMINAL_PADDING` · `SCROLLBAR_W` 가 이 변환의 결과다.

**선 두께는 정수 px 다** ([#357](https://github.com/ensky0/tildaz/issues/357) 2026-07-31 확정). 격자에 놓이는 실선의 두께는 `linePx` 로 **먼저 정수로 양자화**하고, 위치 규칙(`ui_rect.snap`)은 건드리지 않는다. 근거는 라스터화 규칙이다 — 두께 `t` 의 선이 `top` 에 놓일 때 덮는 행은 `[round(top), round(top + t))` 이고 (`ui_rect.snap` 의 정의이자 GPU 의 pixel-center 규칙), `t` 가 정수면 `round(top + t) = round(top) + t` 가 **항상** 성립해 위치 소수부와 무관하게 정확히 `t` 픽셀이 나온다. 소수 두께는 그렇지 않아 **같은 화면 안 선들의 두께가 갈렸다** — 예: 1pt × 1.7 = 1.7px 은 `top` 소수부 0.85 에서 2px, 0.55 에서 1px 이라 command menu 의 두 구분선 두께가 달랐다. 동시에 이것은 platform 갈래이기도 했다: Linux 는 두께를 미리 정수로 반올림하고 macOS · Windows 는 소수를 그대로 GPU 에 넘겨, `150pt × scale` 이 정수가 아닌 배율(1.25 · 1.75 = Windows 125% · 175%)에서 탭바 세로 구분선이 어긋났다. 배율 1.0 · 1.7 에서는 두 규칙의 결과가 같아 [#343](https://github.com/ensky0/tildaz/issues/343) 단계 1 의 픽셀 검증(1.0 · 1.7)에 걸리지 않았다.

**예외 하나 — Wayland dialog scrollbar 의 최소 thumb 높이.** [`wayland_minimal.dialogScrollbarGeom`](src/host/linux/wayland_minimal.zig) 은 helper 를 쓰지 않고 `preferred_scale` 을 **유리수 그대로** (204/120 등) 정수 산술로 반올림한다 (`(pt × num + den/2) / den`) — f32 변환 오차를 아예 만들지 않기 위해서다 (`src/font/spec.zig` 의 rational scale 과 같은 이유). **규칙(반올림)은 helper 와 같으므로 결과도 일치한다.**

### 알파 합성 — renderer 가 아니라 공유 코드가 한 번만 한다 ([#353](https://github.com/ensky0/tildaz/issues/353))

**반투명 요소는 알파를 renderer 에 넘기지 않는다.** 배경과의 합성을 공통 [`ui_metrics.blendOverU8` / `blendOverRgb`](src/ui_metrics.zig) 가 **한 곳에서 한 번** 수행하고, 세 renderer 는 그 결과를 **알파 1.0 불투명**으로 그린다.

| 요소 | 알파 | 합성 입력 |
|---|---|---|
| scrollbar thumb | `SCROLLBAR_ALPHA` 0.3 | terminal 의 **현재** 배경 (아래 §스크롤바 thumb 색) |
| 음영 `░▒▓` (U+2591–2593) | 0.25 / 0.5 / 0.75 | **그 셀의 배경** (`cell_color.resolveBg` → null 이면 `colors.background`) |
| box-drawing AA — 호 `╭╮╰╯` · 대각선 `╱╲╳` | `box_drawing.Rect.cov` (**런타임** 값) | 동일 |

**알파가 런타임 값이어도 된다.** helper 는 `alpha: f32` 를 인자로 받으므로 상수일 필요가 없다. box AA 의 `cov` 는 셀 크기에 따라 픽셀별로 계산되지만, [`boxRects`](src/box_drawing.zig) 의 emitter 가 **한 픽셀에 rect 를 하나만** 내보낸다 — 대각선은 두 선의 coverage 를 `@max` 로, 호는 arm·arc 거리를 `@min` 으로 합친 **뒤** emit 하고, `rounded` 분기는 arm 까지 같은 루프가 전담해 별도 불투명 arm rect 와 섞이지 않는다. 그래서 한 픽셀의 blend 가 정확히 한 번이고, **배경과 미리 합성한 결과가 순차 blend 와 같다.** `cov = 1` 인 crisp rect 는 합성 결과가 `fg` 그대로다.

계산은 **`f64` 로 하고 최근접 반올림**한다. `u8 × f32` 의 곱과 합은 `f64` 안에서 오차 없이 떨어지므로(필요 비트 ~40 < 53) 결과가 정확값의 최근접 정수다. `f32` 로 하면 곱이 f32 격자로 반올림되면서 정확값이 `x.5` 가 아닌데도 tie 로 보이는 자리가 생겨 방향이 뒤집힌다 (예: `(1−0.3f) × 245` 는 정확히 `171.4999970…` 인데 f32 에서는 `171.5`). tie 방향은 `@round` (0 에서 먼 쪽) 인데, **이 함수 하나가 결정하므로 platform 간 갈래가 되지 않는다.**

**왜 사양으로 못 박는가.** 이전에는 세 renderer 가 각자의 합성 지점에서 8bit 로 떨어뜨렸고 **규칙이 셋으로 갈렸다.**

| platform | 이전 규칙 |
|---|---|
| Linux | `blendU8` — f32 곱 + **버림** (음영은 `blendRect` 로 알파 8bit 버림 + 정수 버림, 즉 Linux 안에서도 둘) |
| macOS | 셰이더 premultiply → 고정밀 곱 + 최근접 반올림 |
| Windows | non-premultiplied + `SRC_ALPHA` → blend factor 가 **render target 정밀도(8bit)로 양자화**된 뒤 최근접 반올림 |

같은 알파를 같은 배경에 얹어도 배경의 **약 45%** 에서 채널당 1 이 갈렸고 (음영은 최대 2), Windows 쪽은 blend factor 양자화가 **하드웨어 동작**이라 우리 코드로 맞출 수 없었다 — D3D11 명세가 blend 정밀도를 "render target format 이상" 으로만 요구하므로 GPU / 드라이버마다 달라질 수 있다. 합성을 공유 코드로 옮기면 하드웨어가 합성에 관여하지 않아 **정의상 일치**한다.

**비범위 — 글리프 anti-alias.** 폰트 글리프의 AA 는 별개 경로다 (Linux 는 FreeType coverage → `blendPixel`, Windows 는 ClearType dual-source blend `ct_blend`, macOS 는 Core Text). 알파 상수가 아니라 rasterizer 가 만드는 커버리지이고 platform 마다 rasterizer 자체가 다르므로 이 규칙의 대상이 아니다.

`font.size_point`는 호환성을 위해 유지하는 외부 key 이름이며 물리적인 1/72 inch
point가 아니다. 내부 의미는 logical size이고 실제 raster 크기는 위 표의 OS scale을
적용한다. 실제 mm 보정은 하지 않는다. 폰트 metric에 cell width/line height ratio와
scale을 적용한 최종 cell 정수 크기는 Linux · macOS · Windows 모두 `ceil`한다 — 위
`scaledPx` 의 반올림과 다른 규칙인데, cell 은 글리프가 잘리면 안 되므로 올림이다.

**탭 gap / hover inset**: `TAB_GAP_PT`를 기준으로 각 탭 배경은 좌우에 절반인
1pt, 상하에 2pt를 inset으로 사용한다. 컨트롤 hover 박스는 네 방향에 2pt를
사용한다. 세 host 모두 현재 화면 scale을 곱하며, Linux는
최종 physical pixel 좌표에서 가장 가까운 정수로 반올림한다 (CPU · GPU 두 경로가
같은 `tab_chrome.snap` 결과를 쓴다).

**탭 제목 font 분리**: 탭 제목은 terminal의
`font.size_point`와 무관한 고정 13 logical pt를 쓴다. 같은 font family/fallback
chain을 사용하되 Linux · macOS · Windows 모두 terminal과 별도인 font context와
atlas/cache를 소유한다. 따라서 terminal font 크기를 바꿔도 탭 제목과 28pt 탭바
높이는 변하지 않는다. `tabBarHeightPx(scale)`는 fractional scale에서도 세 플랫폼이
같은 physical pixel 높이를 쓰도록 최종값을 공통 반올림한다.

**fallback**: Linux 는 `wp_fractional_scale_v1` 미advertise 환경 (mutter / wlroots) 이면
`wl_output` 정수 scale (event opcode 3) 을 fallback 으로 적용한다 (#210/#238). 둘 다 없거나
(정수 scale 도 안 옴) 첫 init 시점에만 `scale = 1.0` default, PT 값 그대로 사용 (기존 1x
환경 동작 보존).

**Linux mixed-output basis**: The client binds and tracks advertised `wl_output`
objects, up to the fixed limit of eight, and records the set reported by the main
surface's `wl_surface.enter` / `wl_surface.leave` events. At the end of each
dispatch batch it keeps the current basis while that output remains in the set;
otherwise it prefers the first-bound output when present, then the first entered
output. An empty set preserves the current basis. Batch-level selection prevents
wlroots compositors from oscillating when a surface flush with an adjacent output
receives enter events for both outputs. The selected output's current mode drives
percentage layout. Its integer scale is the fallback when
`wp_fractional_scale_v1` is unavailable; per-surface `preferred_scale` remains
authoritative otherwise. A mapped layer surface is replaced create-before-destroy
when its basis dimensions change so the compositor applies the new layout
immediately ([#295](https://github.com/ensky0/tildaz/issues/295)).

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
| **KWin** | ✅ layer-shell | direct KGlobalAccel D-Bus 등록·Pressed signal | KDE Plasma | ✅완료 (실기 확인) |
| **wlroots** | Hyprland = ✅ layer-shell · sway = xdg_toplevel + i3 IPC 배치/scratchpad 토글 ([#454](https://github.com/ensky0/tildaz/issues/454) — sway 는 layer-shell `on_demand` 에서 map 시 keyboard focus 를 안 줌) | Hyprland = `hyprctl keyword bind`→`tildaz --toggle N`, sway = `bindsym` i3-ipc→`--toggle N` | Hyprland / sway (Wayfire / river / niri 동계열) | ✅완료 (Hyprland / sway 실기 확인) |
| **mutter** | tildaz 전용 Shell extension (xdg-shell 창 배치) | gsettings custom keybinding (libgio) + extension 충돌 시 자동 skip | GNOME (Ubuntu / Budgie / Pantheon 동계열) | ✅완료 (실기 확인) |
| **muffin** | tildaz 전용 Shell extension | gsettings custom keybinding (Cinnamon strv schema) + extension 충돌 skip | Cinnamon | ✅완료 (실기 확인) |
| **smithay** | ✅ layer-shell | RON custom shortcut→`tildaz --toggle N` | COSMIC | ✅완료 (실기 확인) |
| **X11 전용** | — (Wayland 아님) | — | XFCE / MATE / LXDE | **범위 밖** (별도 backend 필요) |

### Support Tier 정의

Linux 지원 수준은 desktop 이름이 아니라 실제 capability + 검증 결과로 표현한다.

| Tier | 의미 |
|---|---|
| **Full** | global toggle, monitor-aware drop-down placement, tabbed terminal, Unicode rendering, clipboard, config parity, IME behavior 가 그 desktop 에서 cross-platform spec 을 만족 |
| **Limited** | terminal 은 사용 가능하나 true drop-down layer / global shortcut / IME pre-edit / desktop integration 중 하나 이상이 없거나 미검증 |
| **Unsupported** | baseline Wayland window 를 못 열거나 terminal session 을 실행 못 함 |

### DE 별 동작 (요약)

- **KWin (KDE Plasma).** layer-shell drop-down. worker가 KGlobalAccel D-Bus에
  instance별 action을 직접 등록하고 Component의 `globalShortcutPressed`를 받는다.
  그 키를 이미 다른 component가 쓰고 있으면 사용자 확인 뒤 그 key sequence만
  회수(takeover)하고 다른 binding은 보존한다. config가 source of truth다.
  launcher는 KGlobalAccel component 목록에서 정확히
  `tildaz.instanceN`인 항목만 비교해 config 에 없는 번호의 `toggle-N` action 을
  증분 해제한다. drop-down 재표시는 KWin 만 `#205` unmap/remap 워크어라운드(아래
  부록 B 참조).
- **sway (wlroots).** drop-down 은 **layer-shell 이 아니라 xdg_toplevel + i3 IPC**
  ([#454](https://github.com/ensky0/tildaz/issues/454)) — sway 는 layer-shell
  `on_demand` 에서 map 시 keyboard focus 를 주지 않아 (spec 상 compositor 재량,
  KWin·Hyprland·COSMIC 셋은 줌) 토글 직후 타이핑이 안 됐다. 판별은 `SWAYSOCK` 의
  주인과 현재 Wayland compositor 의 `SO_PEERCRED` PID 가 **같은 프로세스**일 때만이다
  — 존재만 보면 sway 세션이 systemd user 환경에 남긴 stale 변수가 다음 KDE 세션에서
  sway 경로를 오발동시킨다 (KDE 실기 회귀로 확정). 성립하면 layer-shell 을 기록하지
  않고 xdg fallback 으로 뜬 뒤, 배치는 `for_window` 규칙
  (floating·sticky·border·크기 — **명령당 규칙 하나**, 콤마 체인은 sway 가 첫
  명령까지만 규칙으로 받고 나머지를 focus 창에 즉시 실행) + map 후 `move`(ppt) 로,
  토글은 scratchpad 로 한다 (sway 1.12 실기 확인). hotkey 는 `$SWAYSOCK`의 i3-ipc
  `RUN_COMMAND`로 `bindsym <accel> exec <self_exe> --toggle N` 를 런타임 등록.
  hotkey 실동작은 번호별 socket (`$XDG_RUNTIME_DIR/tildaz-N.sock`).
  runtime-only 라 매 실행 등록 = config 가 source of truth. 단 sway IPC 는 현재
  binding 열거 요청을 제공하지 않아 세션 중 stale binding 증분 제거는 지원하지
  않는다. config 삭제/변경 전에 등록된 binding 은 sway 세션 재시작 때 사라진다.
- **Hyprland (wlroots).** layer-shell drop-down (KWin·COSMIC 과 같은 경로 —
  sway 는 #454 로 xdg_toplevel + IPC 로 분리됨).
  hotkey는 실행 시 `hyprctl -j binds` actual과 config desired를
  비교해 TildaZ `--toggle N` binding 의 차이만 `unbind/bind`한다. `install.sh`는
  `~/.config/hypr/` config의
  autostart만 관리한다. drop-down 은 `on_demand`
  keyboard interactivity 로 클릭-어웨이 허용. XDG autostart 미지원이라 autostart 도
  config 의 `exec-once` 로.
- **`tildaz --toggle N` 의 계약** ([#489](https://github.com/ensky0/tildaz/issues/489)).
  아래 DE 들이 등록하는 단축키 명령이 전부 이것이라, 세 상태의 동작을 여기서 고정한다.
  판정은 **socket 과 lock 두 신호**를 함께 본다 — `connect` 실패는 "워커 없음" 과
  "워커는 있는데 socket 에 못 닿음" 을 모두 포함해서 socket 만으로는 영원히 못 가르고,
  `flock` 기반 instance lock 은 socket 과 독립이다.

  | 상태 | 동작 | exit |
  |---|---|---|
  | socket 도달 가능 | toggle 전달 | 0 |
  | lock 비어 있음 (워커 없음) | **런처 경로로 넘어가 워커를 띄운다** | 0 |
  | lock 잡힘 + socket 도달 불가 | 로그만 남기고 **아무것도 하지 않는다** | 3 |

  세 번째에서 띄우면 안 된다: lock 때문에 중복 워커는 안 생기지만, 런처가 "모든 워커가
  이미 떠 있다" 를 새 인스턴스 요청으로 읽어 **Create 다이얼로그**를 띄운다 — 단축키를
  눌렀을 때 나올 화면이 아니다. 두 번째가 exit 1 이던 시절에는 autostart 를 켜지 않으면
  **단축키가 완전히 무반응**이었다. 이 계약 덕에 DE 단축키 명령은 `--toggle N` 하나로
  충분하다 (셸 fallback `|| tildaz` 가 필요 없다 — `||` 는 0 이 아니면 전부 실행해서
  세 번째 상태를 표현할 수 없다).
- **COSMIC (smithay).** layer-shell drop-down. hotkey 는 RON custom shortcut
  (`~/.config/cosmic/.../custom`) 의 TildaZ 전용 항목을 config_N 전체에 맞춰
  `Spawn("tildaz --toggle N")`로 원자적 갱신하되, 기존 bytes 와 같으면 write/rename 을
  생략한다. XDG autostart는 지원. **`install.sh` 는 COSMIC 항목을 쓰지 않는다** — writer 는
  이 경로 하나다 ([#514](https://github.com/ensky0/tildaz/issues/514), Hyprland 와 같은 규칙).
  - **"TildaZ 전용 항목" 의 판정 근거는 우리가 쓰는 description 표식
    (`description: Some("TildaZ_<index>")`) 하나다** — 명령 문자열이 아니다
    ([#484](https://github.com/ensky0/tildaz/issues/484)). 이 파일에는 사용자가 만든
    단축키가 함께 들어 있어서, 판정을 틀리면 양방향으로 깨진다: 자기 항목을 못
    알아보면 중복 맵 키가 쌓여 COSMIC 이 **파일 전체를 버리고**(사용자 단축키까지
    사라진다), 남의 항목을 자기 것으로 착각하면 **조용히 지운다**. 명령에는 바이너리
    경로와 이름이 들어가 사용자가 바꿀 수 있으므로 판정 근거가 될 수 없다. 표식 뒤의
    번호가 정수인지도 확인한다.
  - **예외는 하나뿐이다 — 예전 `install.sh` 가 표식 없이 쓴 줄을 흡수한다**
    ([#514](https://github.com/ensky0/tildaz/issues/514)). 그 시절엔 writer 가 둘이었고
    스크립트 쪽이 표식을 안 붙여, 같은 hotkey 가 RON 에 두 번 남았다. 흡수 조건은 **완전
    일치**다: `description` 이 아예 없고, `Spawn` 명령이 *지금 실행 파일 경로* +
    `--toggle <index>` 와 바이트까지 같으며, 그 index 를 우리가 실제로 관리할 때. 셋 중
    하나라도 어긋나면 사용자 항목으로 보고 남긴다.
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
| 윈도우 토글 (drop-down) | config_N별 hotkey (`RegisterHotKey`) | config_N별 hotkey (CGEventTap) | KDE Plasma는 direct KGlobalAccel, 그 외 지원 desktop은 native binding→`tildaz --toggle N` Unix socket IPC ([fb775a9](https://github.com/ensky0/tildaz/commit/fb775a9), #198) | ✅ | ✅ | ✅ |
| 앱 종료 | Alt+F4 | Cmd+Q (mainMenu Quit) | Alt+F4 (Win 동등 native — Linux desktop 표준). `self.running = false` 로 main loop break | ✅ | ✅ | ✅ |

**hotkey 를 못 잡으면 기동을 멈춘다 — 세 platform 공통** ([#510](https://github.com/ensky0/tildaz/issues/510)).
부를 수 없는 드롭다운은 사용자가 도달할 방법이 없는 창이라, 그 상태로 도는 것보다 안내 후
종료가 낫다. #431 의 *"뒤에 있는 것이 양보한다"* 를 실제로 세 platform 에 맞춘 것이고, 그전에는
**Windows 만** 멈췄다.

- **적용 대상은 기동 등록이다.** 기동 이후의 재등록 실패 (KDE 의 layout 전환 재bind 등) 는
  멈추지 않는다 — 그때 프로세스를 죽이면 **열려 있던 셸 세션이 함께 날아간다.** 로그만 남긴다.
- **측정 인스턴스 (`-e` · `-size`) 는 애초에 전역 hotkey 를 등록하지 않으므로** (#382) 이 정책
  밖이다.
- 안내는 세 platform 모두 공통 dialog 경로를 쓴다. Linux 는 overlay 를 Wayland globals +
  keyboard 준비 뒤에만 그릴 수 있어 (#282 F9), 발견 시점에 기록해 두고 shell · font 검증과
  **같은 구간에서** 한 번에 안내한다.

**"못 잡았다" 를 아는 방법은 데스크톱마다 다르다.** Linux 는 등록 경로가 하나가 아니라 여섯이고,
다섯이 fire-and-forget 이었다. 그래서 "등록이 실패했나" 를 물을 수 없는 곳은 **쓰기 전에 읽어**
소유권을 판정한다.

| 등록 상대 | 판정 방법 | 근거 |
|---|---|---|
| Windows | `RegisterHotKey` 반환값 / 위치 표기는 `WH_KEYBOARD_LL` 훅 설치 여부 | API 가 실패를 돌려준다 |
| macOS | Input Monitoring · Accessibility preflight + `CGEventTapCreate` | 권한이 없어도 멈춘다 — 그 상태로는 hotkey 가 영영 안 온다 |
| KDE Plasma | KGlobalAccel 의 사전 소유자 조회 → 사용자 확인 → 인수 → 사후 검증 | Linux 에서 유일하게 *남이 쥐고 있다* 를 직접 안다 |
| GNOME | Shell extension 이 `grab_accelerator` 결과를 `instanceN.hotkey` 에 남기고 worker 가 부팅 때 읽는다 | 셸 **안에서만** 답이 나오고, 그 답이 worker 탄생보다 먼저 확정된다 (실측: GNOME Shell 50.4 에서 grab 실패 → 파일 기록 → worker 종료까지 연쇄 확인) |
| Cinnamon | 같은 배선이지만 **실질적으로는 감지되지 않는다** | `Main.keybindingManager.addHotKey` 가 **accel 충돌에 실패하지 않는다** — wm 키바인딩과 custom 키바인딩 양쪽으로 선점해 보아도 성공한다 (실측: Cinnamon 6.6.9). 배선 자체는 산다 — `addHotKey` 가 실제로 실패하는 경우 (표에 없는 위치 이름 등) 는 GNOME 과 같은 경로로 걸린다 |
| sway | `RUN_COMMAND` 응답의 `success` (거절 사유 문자열 포함) | 등록 실패는 알려 준다. **중복은 알 수 없고 알 필요도 없다** — sway 는 기존 binding 을 조용히 밀어내고 우리 등록이 항상 이긴다 (실측: sway 1.12 가 `Overwriting binding` 을 자기 로그에만 남기고 `success: true` 를 준다) |
| Hyprland | `hyprctl -j binds` 로 **전체 목록을 읽어** 우리 accel 을 쓰는 남의 binding 을 찾는다 | 중복 bind 가 `ok` 를 돌려주고 **둘 다 살아 함께 발화한다** (실측: Hyprland 0.56.2) |
| COSMIC | 사용자 `custom` RON 을 읽어 우리 accel 을 쓰는 남의 항목을 찾는다 | 파일 쓰기라 되먹임이 없다. 같은 키가 두 번 들어가면 COSMIC 이 파일을 통째로 버린다 (#484) |

**판정하지 못하는 경우는 통과시킨다.** 도구가 없거나 파일을 못 읽은 것은 충돌했다는 뜻이
아니고, 잘못된 종료는 놓친 감지보다 나쁘다. 알려진 갭 셋을 여기 적어 둔다.

- **COSMIC 의 시스템 기본 단축키** (`/usr/share/cosmic/…/v1/defaults`) 는 보지 않는다.
  `custom` 이 기본값을 덮는지 **확인하지 못했다** — 덮는다면 겹침은 우리가 이기는 상황이라,
  충돌로 읽으면 멀쩡한 설정에서 앱이 안 뜬다.
- **GNOME · Cinnamon 에서 extension 이 꺼져 있으면** 등록은 GSettings 경로가 하고, 그쪽은
  `g_settings_set_*` 의 결과만 알 뿐 mutter · muffin 이 실제로 grab 했는지 모른다.
- **Cinnamon 은 extension 이 켜져 있어도 accel 충돌을 못 본다** (위 표). 그래서 "다른 앱이 그
  조합을 쓰고 있다" 는 Cinnamon 에서 유일하게 남는 미검출 경로다.

### 2.2 탭 관리

| 동작 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|
| 새 탭 | Ctrl+Shift+T | Cmd+T | Ctrl+Shift+T (L12-β) | ✅ | ✅ | ✅ |
| 활성 탭 닫기 | Ctrl+Shift+W | Cmd+W | Ctrl+Shift+W (L12-β) | ✅ | ✅ | ✅ |
| 활성 pane 닫기 | Ctrl+Shift+X | Shift+Cmd+X | Ctrl+Shift+X | ✅ | ✅ | ✅ |
| 인덱스 점프 (1..9) | Alt+1..9 ([`Window.wndProc`의 `WM_SYSKEYDOWN`](src/window.zig)) | Cmd+1..9 | Alt+1..9 ([c0828f1](https://github.com/ensky0/tildaz/commit/c0828f1)) | ✅ | ✅ | ✅ |
| 이전 탭 | Ctrl+Shift+[ **또는 Ctrl+PgUp** | Shift+Cmd+[ **또는 Cmd+PgUp** | Ctrl+Shift+[ (L12-β) **또는 Ctrl+PgUp** | ✅ | ✅ | ✅ |
| 다음 탭 | Ctrl+Shift+] **또는 Ctrl+PgDn** | Shift+Cmd+] **또는 Cmd+PgDn** | Ctrl+Shift+] (L12-β) **또는 Ctrl+PgDn** | ✅ | ✅ | ✅ |

**이 표는 기본값이다** ([#493](https://github.com/ensky0/tildaz/issues/493) 3-c 이후).
scrollback 쌍과 `Ctrl+C` 를 뺀 모든 조합은 config 의 `[keys]` 로 바꿀 수 있고, 세 platform 의
판정이 `config.lookupAction` 한 곳에서 일어난다. 그 전에는 host 마다 하드코딩된 키 표가 있었고
**분류부와 실행부에 같은 표가 두 번** 적혀 있었다 — 그 이중 기술이 갈라지는 것이
[#484](https://github.com/ensky0/tildaz/issues/484) 의 원인이었다.

기본값 표는 **platform 별로 둘이다** (`macDefaultBindings` / `pcDefaultBindings`). `cmd` 토큰이
modifier 차이를 흡수하지만 macOS 는 **Shift 의 유무까지 다르다** — PC 쪽 `Ctrl+Shift+T` 에
대응하는 Apple HIG 관습이 `Cmd+T` 다. 한 표로 덮으면 macOS 사용자의 모든 단축키가
`Control+Shift+*` 가 된다.

**keyboard layout 독립성** ([#482](https://github.com/ensky0/tildaz/issues/482) ·
[#496](https://github.com/ensky0/tildaz/issues/496)). **글자 키에서는 세 platform 이 매칭하는
대상이 모두 라벨** — *눌러서 나오는 문자* — 로 모였다. Linux 는 **xkb keysym**, macOS 는
`NSEvent charactersByApplyingModifiers:`, Windows 는 **virtual-key** 다.
**macOS 가 라벨로 바뀐 것은 #496 항목 2 이고, 그전에는 `kVK_ANSI_*` (물리 위치) 였다** — 그래서
AZERTY 에서 `Cmd+W` 가 `Z` 라 인쇄된 키였고, 같은 Mac 의 Safari (Cocoa 메뉴 `keyEquivalent` =
문자 비교) 와 다른 키를 요구했다.

**Windows 의 VK 는 layout DLL 이 배정한다** — 우리가 고른 것이 아니라 OS 가 정하는 값이라 성질이
둘로 갈린다 ([실측](https://github.com/ensky0/tildaz/issues/496#issuecomment-5404000121)).

- **글자 키는 라틴 layout 에서 라벨을 따라간다** — AZERTY 에서 scancode `0x1E` 가 `VK_Q` 다. 그
  자리는 `Q` 라고 인쇄돼 있다.
- **비라틴 layout 에서는 US 위치로 떨어진다** — Russian 의 `0x11` 이 `VK_W` 다. 키릴 라벨에
  대응하는 VK 가 없어서다. **그래서 Windows 만 라틴 fallback 이 필요 없다** (아래 1-a 가 Linux ·
  macOS 뿐인 이유). 한국어 · 일본어는 layout DLL 수준에서 그냥 US QWERTY 라 애초에 해당이 없다.
- **기호 키는 라벨도 위치도 아니다.** `VK_OEM_*` 은 layout DLL 이 배정하는 **슬롯**이라 자리가
  움직인다 — 같은 `VK_OEM_3` 이 US `0x29` · 프랑스어 legacy `0x28` (`ù`) · 독일어 `0x27` (`ö`) 다.
  그래서 `grave` 바인딩은 AZERTY 에서 `` ` `` 도 `²` 도 아닌 **`ù` 키**를 잡는다 (실기 확정).
  이 부류의 답은 라벨을 넓히는 것이 아니라 위치 표기다 — 라벨로 통일하면 `ctrl+grave` 가 AZERTY
  에서 `Ctrl+AltGr+7` (게다가 dead key) 이 되어 **누를 수 없는 조합**이 된다.

그래서 layout 종속 결함의 모양이 platform 마다 다르다.

- **비라틴 layout (키릴 · 그리스 · 아랍 ...) 에서는 글자 단축키를 라벨로 적을 수 없다.**
  `xkbcli how-to-type --layout ru 'w'` 가 빈 결과다 — 그 자판의 어느 키도 `w` 를 내지 않으므로
  `ctrl+shift+w` 는 영원히 발동하지 않고, **다른 글자로 재바인딩해도 해결되지 않는다** (라틴
  알파벳 전체가 없다). 그래서 키를 **물리 위치**로도 적을 수 있게 했다 — `"ctrl+shift+[KeyW]"`.
  이름은 [W3C `KeyboardEvent.code`](https://www.w3.org/TR/uievents-code/) 값이고 (2025 년
  Recommendation) 표기는 VS Code 와 같은 대괄호다. 세 platform 값의 단일 출처는
  `src/physical_key.zig` 다.
- **그리고 기본값이 그대로 동작하도록 라틴 fallback 을 둔다** (1-a, **Linux · macOS**).
  각 라벨 binding 에 대해 **지금 layout 이 그 문자를 낼 수 있는지** 묻고, 낼 수 없으면 그 문자가
  US 자판에서 있던 자리로 매칭한다. 묻는 방법은 platform 마다 다르다 — Linux 는 활성 group 에
  `xkb.canProduceKeysym` 으로 묻고, macOS 는 keycode `0..127` 을 훑어 라벨 표를 만든다
  (`host/macos.zig` 의 `macRebuildLayoutLabels`).
  - **판정은 활성 group 만 본다.** 처음에 group 을 전수로 훑었는데 그것이 결함이었다 —
    매처는 활성 group 이 내는 keysym 만 보므로 판정도 같은 group 을 봐야 한다. 실측
    (`us,ru` keymap): group 0 은 `sym@KeyW=0x77`, group 1 은 `0x6c3`
    (`Cyrillic_tse`) 인데 전수 조회는 양쪽에서 `canProduceKeysym('w') = true` 를 낸다.
    그래서 ru group 으로 전환한 사용자는 fallback 을 받지 못해 단축키가 죽었고, 그것이
    비라틴 사용자의 **가장 흔한 설정**이라 정작 다수 사례를 놓쳤다.
  - **재해석 트리거가 둘이다.** keymap 교체는 `wl_keyboard.keymap`, **group 전환은
    `wl_keyboard.modifiers` 의 `group` 필드**로 온다. 후자를 빠뜨리면 위 결함이 된다.
    Mutter 도 `keymap-changed` 와 `keymap-layout-group-changed` 둘 다 훅한다.
  - level 은 전수로 훑는다 — "Shift 를 눌러야 나오는 문자" 도 낼 수 있는 것으로 세야
    한다. 키마다 layout 수가 달라 유효 layout 은 `group % num_layouts_for_key` 다.
  - **닿지 않을 때만 만든다.** 무조건 2 차 pass 를 돌리면 AZERTY 에서 `Z` 라 인쇄된
    키 (US `w` 자리) 가 `close_tab` 을 발동시켜 한 동작에 키가 둘 생긴다.
  - **macOS 의 재해석 트리거는 `NSTextInputContext.selectedKeyboardInputSource` 다.** 헤더가
    *"The ID corresponds to the kTISPropertyInputSourceID attribute"* 라고 적는 값이고,
    **Carbon 을 링크하지 않고** 현재 layout 을 식별할 수 있다. 키 이벤트마다 그 문자열을
    비교해 바뀌었을 때만 표를 다시 만든다 (대개 비교 한 번으로 끝난다).
  - **macOS 는 라벨을 뽑을 때 Shift 만 반영한다.** AZERTY 는 숫자열이 Shift 를 눌러야 숫자가
    나오므로 (무시프트는 `&é"'(-è_çà`) Shift 까지 빼고 뽑으면 `cmd+1` 이 그 layout 에서 영영
    매칭되지 않는다 (#482 의 숫자 예외가 무력해진다). 라벨 표에도 base 와 shift 두 벌을 담는다.
  - **`charactersByApplyingModifiers:` 는 modifier keycode 에서 죽는다.** `0x36`–`0x3F`
    (`kVK_RightCommand` ~ `kVK_Function`) 를 넘기면 헤더 서술 (*"will return nil"*) 과 달리
    `NSAssertionHandler` 를 거쳐 `abort()` 다 (실측, macOS 26.6.2 · SDK 26.5). 거르지 않으면
    **Shift 를 누르는 것만으로 앱이 죽는다.**
  - **판정 불가 (`null`) 와 false 를 구분한다.** libxkbcommon 이 keymap 조회 심볼을
    안 내주면 fallback 을 만들지 않는다 — false 로 읽으면 없어도 되는 fallback 이
    생긴다. 그 심볼 다섯은 **optional** 이다: 기존 심볼처럼 묶으면 오래된
    libxkbcommon 에서 키보드가 통째로 죽는데 그것은 이 기능이 감당할 대가가 아니다.
  - **라벨이 먼저다.** 라벨로 잡히는 event 가 fallback 때문에 다른 액션이 되면
    사용자가 설명할 수 없다.
  - GTK 는 같은 문제를 "영어 layout 이 첫 layout 으로 설정돼 있어야 한다" 는 *요구*로
    푼다. 우리는 요구하지 않고 활성 group 을 보고 스스로 판정하므로 `us,ru` · `ru` 단독
    양쪽에서 동작한다. Mutter 는 `us` keymap 을 즉석 컴파일해 같은 결과를 얻는다
    (`create_us_layout()`) — 우리는 내장 W3C 위치표가 그 자리를 대신한다.
- **수용 집합은 라벨 쪽이 좁고 위치 쪽이 넓다.** 의도한 비대칭이다. 라벨을 넓히려면 `-` 에
  값을 줘야 하는데, Windows 에서 쓸 수 있는 고정값 (`VK_OEM_MINUS`) 은 라벨이 아니라 layout DLL
  이 배정한 슬롯이다. 그것을 라벨이라 부르면 같은 config 가 layout 마다 다른 키를 뜻한다. 위치는
  처음부터 자리이므로 그 문제가 없어 자판이 낼 수 있는 키를 다 담는다.
  - **남은 전제는 Windows 뿐이다.** Linux 와 macOS 는 라벨을 **문자 그대로** (keysym · 유니코드
    코드포인트) 담고 이벤트가 낸 문자와 견주므로, 새 라벨 이름은 값을 더 주지 않아도 매칭된다.
    Windows 만 라벨을 VK 로 바꿔야 해서 live layout 조회 (`VkKeyScanExW` 로 로드 시 해석 +
    `WM_INPUTLANGCHANGE` 로 재해석) 가 전제다. #496 항목 2 가 macOS 쪽을 이미 없앴다.
- **Linux 는 라벨 매칭이라 Shift 가 바꾼 키 값을 되돌린다** (`normalizeLinuxKeysym`).
  `ctrl+shift+c` binding 은 keysym `c` 로 저장되는데 실제로는 `C` 가 도착하고, `ctrl+shift+[` 는
  `{` 로 도착한다. 예전 매처가 두 값을 나란히 적어 (`xkb_key_c_lower, xkb_key_c_upper`) 풀던
  자리다. **Shift 비트는 건드리지 않는다** — 값만 되돌리므로 `ctrl+shift+c` 와 `ctrl+c` 는 여전히
  다른 조합이다. 숫자는 일부러 제외한다: `exclam` → `1` 로 되돌리면 QWERTY 에서 `Alt+Shift+1` 이
  탭 전환이 되어 동작이 넓어진다.
- **Shift 를 적은 binding 은 무시프트 값으로도 맞는다** ([#483](https://github.com/ensky0/tildaz/issues/483)
  6단계, 2026-08-27 — `Hotkey.unshifted`). 위 되돌림은 `{` `}` `~` 와 대문자만 다뤄 `shift+alt+0` (US 에서
  `parenright`) 이 Linux 실제 키보드에서, `⇧⌘0` · `⇧⌘[` 이 macOS 에서 (`charactersByApplyingModifiers:` 가
  Shift 를 반영해 `)` `{`) 죽어 있었다. 이벤트 쪽이 같은 키의 Shift 없는 값 (Linux 는 xkb level 0,
  macOS 는 Shift 를 뺀 라벨) 을 함께 넘기고, `lookupAction` 은 **binding 에 Shift 가 적혀 있고 수식키가
  정확히 같을 때만** (숫자 예외 없이) 그 값과 비교한다. 그래서 #493 이 거부한 넓어짐은 없다 — US 의
  `Alt+Shift+1` (`!`, 무시프트 `1`) 은 `alt+1` 에 걸리지 않는다. AZERTY 는 `⇧+à` 가 `0` 을 내 라벨이 바로
  맞으므로 이 규칙이 개입하지 않는다. Windows 는 VK 가 Shift 무관이라 해당 없음.
- **인덱스 점프는 숫자 binding 에서 Shift 를 무시한다** (`isDigitBinding`). AZERTY (fr) 등은
  숫자열에 Shift 가 필요해 keysym / VK `1`~`9` 가 **항상 Shift 와 함께** 도착한다. 확대가 아니라
  현행 유지다 — 3-c 이전의 세 host 가 모두 Shift 를 보지 않았다 (Windows
  `wParam >= 0x31 and wParam <= 0x39`, macOS `keycodeToTabIndex(kc) != null`, Linux 는 #482 에서
  `!shift` 요구 제거). 예외는 **숫자에서 멈춘다** — `shift+alt+f4` 는 `alt+f4` 를 발동시키지
  않는다. QWERTY 에는 영향이 없다: Shift 가 keysym 을 `exclam` 으로 바꿔 애초에 매칭되지 않는다.
- **PgUp / PgDn 조합**은 `[` / `]` 가 AltGr 를 요구하는 layout (AZERTY 는 `[` = AltGr+5 →
  조합이 Ctrl+Shift+AltGr+5) 을 위한 layout 무관 대안이다. 기존 bracket 조합을 **대체하지 않고
  추가**한다. `Ctrl+Tab` 은 쓰지 않는다 — kitty / CSI-u 에서 구별 가능한 시퀀스라 TUI 앱이
  정당하게 바인딩하는데 터미널이 삼키면 통과시킬 방법이 없다. PgUp / PgDn 은 GNOME Terminal ·
  Konsole · Windows Terminal 이 탭 전환에 쓰는, 터미널이 관습적으로 소유하는 조합이다.
- **기존 PgUp / PgDn 경로는 그대로다** — Shift 동반은 scrollback (§2.5), 맨 키는 PTY.
- **전역 `hotkey` 도 위치 표기를 받는다** ([#496](https://github.com/ensky0/tildaz/issues/496)
  1-c). 다만 `[keys]` 와 달리 **OS / compositor 에 *등록* 해야** 해서 경로마다 담을 수 있는 것이
  다르고, 그것이 이 절 아래의 갈림들이다. 등록 경로는 **다섯**이다 — sway `bindcode` · Hyprland
  keysym · GNOME / Cinnamon GTK accelerator (`buildGtkAccel`) · COSMIC RON `key:` ·
  KGlobalAccel `qtKey`. (처음에 "4 경로" 로 적었는데 GNOME · Cinnamon 이 빠져 있었다.)
  - **Windows 는 `RegisterHotKey` 가 아니라 저수준 훅으로 잡는다.** 그 API 는 VK 만 받는데 VK 는
    layout DLL 이 배정하는 슬롯이라 자판마다 자리가 움직인다 (`VK_OEM_3` 이 US `0x29` · 프랑스어
    legacy `0x28` · 독일어 `0x27`). 자리를 VK 로 풀어 캐시하면 layout 이 바뀔 때 **핫키가 다른
    물리 키로 옮겨간다** (실측). `WM_INPUTLANGCHANGE` 로 갱신하는 길은 그 메시지가 스레드별 ·
    포커스 의존이라 숨은 드롭다운에서 닫히지 않는다 — 핫키가 먹어야 포커스를 얻는 순환이다.
    `WH_KEYBOARD_LL` 의 `scanCode` 는 layout 이 개입하지 않은 raw 값이라 변환도 캐시도 없다.
    **라벨 표기는 계속 `RegisterHotKey`** 다 (라벨을 layout 으로 푸는 것은 OS 의 몫이다).
  - **DE 넷은 이미 스스로 라틴 fallback 을 한다** — GNOME (Mutter 3.28+) · Cinnamon (Muffin
    5.4+) · COSMIC (2026-02+) · KDE (Plasma 5.22+). 그래서 1-b 가 손댈 곳은 그것을 하지 않는
    sway · Hyprland 였다.
  - **sway 는 `bindcode` 로 등록한다** (1-b). 자리를 고르는 규칙이 1-a 와 같다 — 활성
    layout 이 그 문자를 내면 그 키, 못 내면 US 자판에서 그 문자가 있던 자리. 판정할 수
    없으면 `bindsym` 으로 되돌아간다 (핫키를 아예 잃는 것보다 낫다).
    - **숫자는 evdev 가 아니라 xkb keycode (= evdev + 8)** 다. sway 는 2018 년 커밋
      *"Use XKB keycode numbering for bindcode"* 로 evdev 를 일부러 뺐고, **잘못된 숫자를
      거부하지 않는다** (`xkb_keycode_is_legal_ext` 가 `XKB_KEYCODE_MAX` 까지 통과) — off-by-8
      이면 조용히 옆 키에 붙는다. `sway_ipc.zig` 의 test 가 그 +8 을 고정한다.
    - **등록을 keymap 도착 뒤로 미룬다.** 위치로 등록하려면 "이 문자를 내는 키가 어디인가" 를
      알아야 하는데 `client.run()` 앞에는 keymap 이 없다. 미루는 창은 밀리초 단위다 (keymap 은
      seat 의 keyboard capability 가 생길 때 오고 focus 와 무관하다).
    - **재등록이 없다.** 한 번 자리에 고정하면 group 전환에 영향받지 않는다 — 그것이 위치
      등록을 고른 이유다. `bindsym` 은 활성 layout 이 바뀔 때마다 죽었다 살았다 한다.
  - **Hyprland 는 남는다** (known limitation). 그쪽 등록은 launcher 단계 (`shortcut_sync`)
    라 keyboard 자체가 없어 물어볼 keymap 이 없다. sway 가 되는 이유는 등록이 *떠 있는
    터미널 안*에서 일어나기 때문이다. 덮으려면 `hyprctl getoption input:kb_layout` 조회 +
    `xkb_keymap_new_from_names` 심볼 추가 + host 재동기화 배관이 필요하다.
  - 다만 **비라틴 단독 layout** 에서는 갈린다. Mutter · Muffin 은 `us` keymap 을 즉석에
    컴파일해 (`create_us_layout()`) 라틴 layout 이 없어도 동작하고, COSMIC · KDE 는 *사용자의
    다른 xkb group* 을 훑으므로 `ru` 단독이면 실패한다. 그 둘은 API 가 keysym 만 받아
    **우리가 고칠 수 없다.**
  - **COSMIC 의 RON `keycode:` 필드는 쓰면 안 된다.** 파싱은 되는데 cosmic-comp 가 값을 읽지
    않고, `key:` 가 없으면 matcher 가 *modifier 전용 바인딩* 으로 취급해 modifier 를 뗄 때
    발동한다. cosmic-settings 자신이 저장 전에 그 필드를 지운다.
- **macOS 에 없는 위치가 있다.** `PrintScreen` · `ScrollLock` · `Pause` 는 **없는 것이 아니라
  `F13` · `F14` · `F15` 로 보고된다** (Apple 확장 자판이 그 자리에 F13~F15 를 둔다). `F21`~`F24`
  와 JIS 입력 전환 키 3 개는 정말 없다. 두 경우의 안내가 다르다 — 앞쪽은 "그 이름을 쓰라",
  뒤쪽은 "이 platform 에 없다". 어느 쪽이든 **파싱 단계에서 거부한다**: 조용히 미동작으로 두면
  [#208](https://github.com/ensky0/tildaz/issues/208) 이 막던 silent failure 로 되돌아간다.

**재바인딩할 수 없는 것 둘.** `Shift+PgUp` / `Shift+PgDn` 은 단축키가 아니라 **스크롤**이고
(`app_event` 에서도 `scroll` 범주로, 마우스 휠과 같은 자리다) `Ctrl+C` 는 SIGINT 다. 둘 다
config 로 가릴 수 있게 하면 실수 한 번으로 터미널의 기본 기능을 잃는다. 그래서 `Ctrl+C` 는
config 조회보다 **먼저** 판정한다.

### 2.3 클립보드

| 동작 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|
| 복사 (단축키) | Ctrl+Shift+C | Cmd+C | Ctrl+Shift+C ([40af18b](https://github.com/ensky0/tildaz/commit/40af18b), L6) | ✅ | ✅ | ✅ |
| 복사 (드래그 selection 후 자동) | `selection.finish()` → `copyToClipboard` | 동일 (`tildazMouseUp` 분기) | 동일 (Wayland `wl_data_source` + selection.finish, [e4d42d4](https://github.com/ensky0/tildaz/commit/e4d42d4)) | ✅ | ✅ | ✅ |
| 붙여넣기 (단축키) | Ctrl+Shift+V | Cmd+V | Ctrl+Shift+V ([40af18b](https://github.com/ensky0/tildaz/commit/40af18b)) | ✅ | ✅ | ✅ |
| 붙여넣기 (마우스 우클릭) | `WM_RBUTTONDOWN` → `pasteClipboard` (cmd.exe console 표준 패턴) | 동일 (`tildazRightMouseDown` → `handlePaste`) | `wl_pointer.button` BTN_RIGHT → `wl_data_offer.receive` → PTY ([40af18b](https://github.com/ensky0/tildaz/commit/40af18b)) | ✅ | ✅ | ✅ |

### 2.4 About 다이얼로그

| 동작 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|
| About 표시 | Ctrl+Shift+I (read-only multiline EDIT 전용 window) | Shift+Cmd+I (mainMenu keyEquivalent + NSAlert) | Ctrl+Shift+I — `about.showAboutDialog()` → 별 layer-shell `overlay` surface (§6 step 3, #203) | ✅ | ✅ | ✅ |

macOS의 info/error/fatal/confirm/About/new-instance prompt는 같은 branded NSAlert
action row를 사용한다. action button은 48 logical pt frame, 15pt medium 글자,
AccessoryBar bezel(Swift의 `recessed`)로 표시한다. macOS 26 이상에서는
`NSControlSizeExtraLarge`, 그 이전에는 같은 48pt frame에 `NSControlSizeLarge`를
사용한다([Apple `NSControl.ControlSize`](https://developer.apple.com/documentation/appkit/nscontrol/controlsize-swift.enum),
[#237](https://github.com/ensky0/tildaz/issues/237)). 활성 primary action(OK/Create)은
[`NSButton.bezelColor`](https://developer.apple.com/documentation/appkit/nsbutton/bezelcolor)에
[`NSColor.controlAccentColor`](https://developer.apple.com/documentation/appkit/nscolor/controlaccentcolor)를
적용하고, Cancel과 disabled Create는 neutral native appearance를 유지한다. AppKit logical point 좌표라
현재 screen의 `backingScaleFactor`에 맞춰 물리 픽셀로 자동 변환된다.

Dialog 본문 폭은 Linux · macOS · Windows 공통으로 preferred 580 logical pt에서
실제 wrap 높이를 먼저 측정한다. 고정 header/action/prompt controls까지 현재 screen
높이를 넘을 때만 maximum 960pt로 확장해 다시 측정하고, 그래도 넘을 때만 본문을
scroll한다. macOS는 현재 screen의 좌우에 각각 최소 48pt를 남기도록 더 작은 값을
선택한다. macOS error는 AppKit의
critical style이 만드는 caution icon+app badge 조합을 사용하지 않고 warning style과
TildaZ icon을 사용한다([Apple `NSCriticalAlertStyle`](https://developer.apple.com/documentation/appkit/nscriticalalertstyle),
[#237](https://github.com/ensky0/tildaz/issues/237)).

### 2.5 스크롤 / 화면 reset

| 동작 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|
| 한 페이지 위 (scrollback) | Shift+PgUp | Shift+PgUp | Shift+PgUp — `session.scrollActive(.{ .page = .up }, visible_rows)`. wheel 분기와 같은 통로 | ✅ | ✅ | ✅ |
| 한 페이지 아래 | Shift+PgDn | Shift+PgDn | Shift+PgDn — 동상 (`.page = .down`) | ✅ | ✅ | ✅ |
| 화면 reset (활성 탭) | Ctrl+Shift+R | Shift+Cmd+R | Ctrl+Shift+R — `session.resetActive()` = `terminal.fullReset()` + `\\x0c` (Ctrl+L) 송신 ([#214](https://github.com/ensky0/tildaz/issues/214)) | ✅ | ✅ | ✅ |

### 2.6 수식키 PTY 전달 (Ctrl · Alt · CSI modifier)

| 동작 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|
| Ctrl+C → SIGINT (\\x03) | `WM_KEYDOWN` → 공통 입력 정책 → `interruptActive`; TranslateMessage가 만든 짝꿍 `WM_CHAR`는 consume해 ETX 정확히 1회 | NSEvent.characters 직접 PTY write | xkb modifier check + utf8 fallback ([40af18b](https://github.com/ensky0/tildaz/commit/40af18b)) | ✅ | ✅ | ✅ |
| Ctrl+A ~ Ctrl+Z 일반 control | 동일 | 동일 (Ctrl+] tag jump, Ctrl+W vim window 등) | 동일 (xkb ctrl modifier compose) | ✅ | ✅ | ✅ |
| 한글 IME 조합 중 Ctrl+C | `ImmNotifyIME(CPS_CANCEL)` + preedit overlay 비움 + \\x03 직송; queued `WM_CHAR` consume — discard와 ETX 각각 정확히 1회 | `discardMarkedText` + preedit overlay 비움 + \\x03 직송 — shell 의 "입력 라인 버리기" 의도와 일관 | text-input-v3 reset + preedit_buf 비움 + \\x03 ([9215807](https://github.com/ensky0/tildaz/commit/9215807), L10-γ) | ✅ | ✅ | ✅ |

#### Alt(Meta) · 화살표/기능키의 modifier ([#533](https://github.com/ensky0/tildaz/issues/533))

**tildaz 가 소비하지 않은 키 입력은 전부 표준 인코딩으로 자식 프로세스에 전달한다.**
세 host 가 native 이벤트를 `key_encode.Event` 로 담아 주면 ghostty 의 `input.encodeKey`
하나가 바이트를 만든다 — 인코딩 표를 우리가 갖지 않는다. 그 전에는 host 마다 escape
sequence 를 직접 적고 있었고 (Linux `terminalSequenceForKeysym` · macOS `keyCodeToEscape` ·
Windows `window.zig` 의 VK switch) 네 곳 어디도 modifier 를 싣지 않아, `Alt+a` 가 `a` 로
나가고 `Shift+←` 는 아무것도 나가지 않았다.

| 입력 | 나가는 것 |
|---|---|
| `Alt` + 글자 | `ESC` + 글자 (xterm meta prefix). `Alt+a` → `\x1b a` |
| 화살표 · 기능키 + modifier | xterm CSI modifier. `Alt+←` → `\x1b[1;3D`, `Shift+F5` → `\x1b[15;2~` |
| AltGr 처럼 **이미 글자를 만든 조합** | 그 글자를 그대로. 프랑스 자판 `AltGr+2` → `~` (`ESC` 를 붙이지 않는다) |
| 앱이 kitty keyboard protocol 을 켠 경우 | 그 프로토콜의 인코딩. `Ctrl+C` → `\x1b[99;5u` |

**IME 조합 중의 `Ctrl+C` 는 예외다 — kitty 여부와 무관하게 조합을 버리고 `\x03` 을 보낸다.**
인터럽트는 "지금 치던 줄을 버린다" 는 뜻이라 조합 중이던 음절도 함께 버리는 것이 셸의 의도와
맞고, macOS 도 같다 (`discardMarkedText` 뒤 `\x03` 직송). 조합 중이라도 **다른** 조합은 음절을
먼저 확정하고 그 키를 인코더로 보낸다 (`Ctrl+A` → `한` + `\x1b[97;5u`) — "IME 가 모르는 키는
commit 후 전달" 규칙 그대로다. Windows 에서 이 예외를 빼면 `Ctrl+C` 의 판정 주체가 사라져
보류된 음절이 인터럽트 **뒤에** PTY 로 샌다 (`03 ed 95 9c` — [#533](https://github.com/ensky0/tildaz/issues/533)
Windows 실측).

**tildaz 단축키가 먼저다.** `Alt+1`~`Alt+9` · `Alt+Enter` 는 우리가 먹는다. 자식에게
넘기려면 `[keys]` 에서 그 바인딩을 비운다. Windows 의 `Alt+F4`(창 닫기) 와
`Alt+Space`(시스템 메뉴) 는 OS 에 남긴다 — 어느 앱에서나 기대되는 동작이라 우리가
가로채지 않는다.

**host 가 인코더에 넘기는 값의 계약** — 이 둘이 어긋나면 조용히 다른 바이트가 나간다.

| 필드 | 규칙 | 어기면 |
|---|---|---|
| `utf8` | 이 키가 만든 글자. **제어문자면 Ctrl 을 뺀 글자로 바꿔서** 넘긴다 (`Ctrl+A` → `"a"`) | 그대로 넘기면 CSI u 로 감싸이고, 비우면 인코더가 **물리 키의 US 글자**로 제어문자를 만든다 — AZERTY 의 `Ctrl+A` 가 `\x11` XOFF, Dvorak 의 `Ctrl+C` 가 SIGINT 상실 |
| `unshifted_codepoint` | 수식키를 다 뺀 글자의 코드포인트 | `0` 이면 kitty 모드에서 항목이 안 생겨 `Ctrl+C` 가 바이트 0 개, `Alt+n` 이 `ESC` 없이 `n` |

얻는 방법은 platform 마다 다르다 — Linux 는 keysym (`oneSym` · `keysymAtEvdev`), macOS 는
`charactersByApplyingModifiers:` 를 Ctrl 뺀 flags 와 `0` 으로, Windows 는 `ToUnicodeEx` 를
수식키 없이. macOS 의 `consumed_mods` 는 정확한 API 가 없어 ghostty 와 같은 휴리스틱을
쓴다 (ctrl · cmd 는 글자 번역에 기여하지 않고 나머지는 기여했다고 본다).

**macOS 의 `Option` 만 갈림길이 있다** — 그 platform 은 OS 가 `Option+a` 를 `å` 로 만들어
주므로 한 키 조합이 두 뜻을 갖는다. `[input] macos_option_as_alt` 가 고르고 기본은 `none`
(macOS 표준대로 글자). 글자를 만들지 않는 키는 그 설정과 무관하게 alt 가 실린다
(`Option+←` → `\x1b[1;3D`). Linux · Windows 에는 이 갈림이 없어 Alt 는 언제나 Meta 다.

**비라틴 배열 · 입력원에서는 물리 키의 US 글자로 되짚는다** ([#483](https://github.com/ensky0/tildaz/issues/483)
브랜치에서 #533 후속으로, 2026-08-29 실기). Alt 앞에 붙일 `ESC` 뒤의 글자를 인코더는 **1 바이트 utf8
이나 ASCII `unshifted_codepoint`** 에서만 찾는데, 러시아어 · 그리스어 **배열** (Linux · Windows) 과
한글 · 러시아어 **입력원** (macOS 는 입력원이 곧 배열) 에서는 그 글자가 ASCII 가 아니다. 되짚지
않으면 `Alt+n` 이 `ESC n` 이 아니라 `н` · `ㅜ` 로 나가 zellij · tmux · emacs 의 Alt 조합이 죽는다.
그래서 **Alt 가 눌렸는데 그 배열의 글자가 1 바이트 ASCII 가 아니면** `key_encode.usAscii` (ghostty
`input.Key.codepoint()` — 물리 키의 US 글자) 로 바꿔 넘긴다 (Shift 면 대문자). ghostty 의 `ctrlSeq`
가 Cyrillic 자판에 쓰는 되짚기와 같은 수이고, **AltGr 로 만든 글자는 건드리지 않는다** (Linux 는
`consumed.alt` 를 함께 본다 — 프랑스 자판 `AltGr+2` → `~`). 실기: macOS 한글 2벌식 + `both` 에서
`^[a` · `^[n`, Linux 러시아어 배열에서 `n` 은 `т` 그대로이고 `Alt+n` 은 `^[n`. **kitty keyboard 는
손대지 않는다** — 그 규격은 주 키 코드가 배열의 코드포인트이고 US 기준 키는 `report_alternates`
를 요청한 앱에만 alternate 로 준다 (실측: `^[[12618;5u`, 플래그 5 면 `^[[12618::99;5u`).

### 2.7 Key repeat (길게 누름 반복)

| 항목 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|
| 영어/숫자/기호 길게 누름 → 반복 입력 | OS default | `ApplePressAndHoldEnabled = false` 우리 앱 도메인에 등록 — 안 등록하면 system 이 accent picker (à á â) 띄우려 repeat 막음 | client-side timer (compositor `wl_keyboard.repeat_info` 의 rate / delay 따름, [17937a9](https://github.com/ensky0/tildaz/commit/17937a9), L12-γ-5). focus 떠날 때 / key release 시 즉시 disarm. 반복을 내보내기 전에 입력 큐를 한 번 비워, 오래 걸린 핸들러 (pane 마다 500 ms 유예가 쌓이는 탭 닫기 등) 동안 도착한 release 를 먼저 반영한다 — 그래서 *이미 뗀 키* 로 반복이 나가지 않는다 ([#546](https://github.com/ensky0/tildaz/issues/546)) | ✅ | ✅ | ✅ |
| 한글 자모 길게 누름 → 반복 입력 | (해당 없음) | IME 경로라 PressAndHold 영향 없음 (자동) | `wl_keyboard.key` 가 IME 로 라우팅됨 — fcitx5 / ibus 자체 key repeat 동작 (compositor `repeat_info` 가 IME 측에 적용). 사용자 일상 사용 OK 확인 (Cinnamon Wayland + fcitx5-hangul, KDE Plasma 6 + KWin). | — | ✅ | ✅ |

### 2.8 전체화면 토글 (윈도우 단위)

| 동작 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|
| 전체화면 — taskbar/dock **덮음** | Alt+Enter | Cmd+Enter | Alt+Enter — layer-shell DE(KWin/Hyprland/COSMIC)는 4-edge anchor + size 0 + `exclusive_zone=-1` 로 패널 위까지 덮음; GNOME/Cinnamon(layer-shell 부재)과 sway(xdg_toplevel + IPC, [#454](https://github.com/ensky0/tildaz/issues/454))는 `xdg_toplevel.set_fullscreen` ([#87](https://github.com/ensky0/tildaz/issues/87)) | ✅ | ✅ | ✅ |
| 전체화면 — taskbar/dock **회피** | Shift+Alt+Enter | Shift+Cmd+Enter | Shift+Alt+Enter — layer-shell 은 `exclusive_zone=0` (패널 유지); GNOME/Cinnamon 은 `xdg_toplevel.set_maximized` ([#87](https://github.com/ensky0/tildaz/issues/87)); sway 는 floating 창의 `set_maximized` 를 무시해 IPC 로 workspace 영역(패널 제외)을 채움 ([#454](https://github.com/ensky0/tildaz/issues/454), sway 1.12 실기) | ✅ | ✅ | ✅ |
| 같은 키 재입력 → dock 복귀 / 다른 모드 → no-op | Alt+Enter↔Shift+Alt+Enter | Cmd+Enter↔Shift+Cmd+Enter | 동일 (`FullscreenMode {none,cover,avoid}` toggle 로직 — Win 동등) | ✅ | ✅ | ✅ |
| 토글된 fullscreen **상태**가 F1 hide→show 간 유지 | ✅ | ✅ | layer-shell 은 `fullscreen_mode` 필드로 show 시 재적용; GNOME/Cinnamon 은 compositor 가 minimize↔복원 간 maximize/fullscreen 보존; sway 는 scratchpad 이동이 fullscreen 을 해제하므로 show 때 `fullscreen_mode` 를 재적용 ([#454](https://github.com/ensky0/tildaz/issues/454)) | ✅ | ✅ | ✅ |

> **숨김(hide) 상태에선 전체화면 토글 no-op** — 보이는 창에만 적용되는 윈도우 동작. Win/Mac 은 숨김 시 창이 keyboard focus 를 잃어 키 미수신으로 자연 보장. Linux layer-shell DE 도 hide 시 surface 를 파괴해 키가 안 와 동일 보장. GNOME/Cinnamon 은 mutter/muffin 이 sticky+above 인 tildaz 를 minimize 해도 focus 를 자동 이양하지 않으므로, extension 이 hide 시 keyboard focus 를 다른 창으로 넘겨 동일 보장한다 — 숨김 중엔 Alt+Enter 토글뿐 아니라 모든 키 입력이 tildaz 로 안 들어간다 ([#247](https://github.com/ensky0/tildaz/issues/247)).

---

## 3. 마우스 동작

| 동작 | 위치 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|---|
| 셀 selection (drag) | cell 영역. **앱이 mouse tracking 을 켠 동안은 `Shift` 를 함께 눌러야 한다** — 아래 mouse reporting 행 ([#502](https://github.com/ensky0/tildaz/issues/502)) | mouseDown + mouseMove + mouseUp | 동일 (`tildazMouseDown/Dragged/Up`) | wl_pointer button/motion → 같은 selection 모듈 ([a8f2461](https://github.com/ensky0/tildaz/commit/a8f2461)) | ✅ | ✅ | ✅ |
| 더블클릭 word selection | cell 영역 | `mouse_double_click` → `selectWord` | 동일 (`tildazMouseDown` clickCount >= 2) | 동일 ([1f58687](https://github.com/ensky0/tildaz/commit/1f58687), L6.7 — 500ms 같은 cell 검사 후 `selectWord`) | ✅ | ✅ | ✅ |
| 더블클릭 후 자동 copy | cell 영역 | `selectWordAt` 안에서 `copyToClipboard` | 동일 — `selectWord` 후 `handleCopy` | 동일 (Wayland `wl_data_source`) | ✅ | ✅ | ✅ |
| selection finish 후 자동 copy | cell 영역 | `selection.finish()` → `copyToClipboard` | 동일 (`tildazMouseUp` 분기) | 동일 ([e4d42d4](https://github.com/ensky0/tildaz/commit/e4d42d4)) | ✅ | ✅ | ✅ |
| 선택 시작 문턱 ([#483](https://github.com/ensky0/tildaz/issues/483) 6단계, 2026-08-28 실기) | 누른 뒤 **문턱보다 많이 움직였거나 다른 칸으로 넘어가야** 선택이 시작된다 (`terminal_interaction.SelectionState.arm` — 세 platform 공통). 문턱은 `ui_metrics.SELECTION_DRAG_SLOP_PT` **4 pt** 을 배율로 옮긴 물리 px 이되 **반 칸을 넘지 않는다** (`selectionDragSlopPx`) — 그래야 아주 작은 폰트에서도 칸 안에서 글자 하나를 끌어 선택할 수 있다. 4 pt 은 Windows 의 드래그 판정 기본값 (`SM_CXDRAG` 4 px @96 dpi) 과 같은 수준. 한 번 넘으면 유지되어 (`armed`) 이웃 칸으로 갔다 돌아오는 한 칸 선택도 된다. 그 전에는 트랙패드 클릭의 1~3 px 떨림이 매번 한 칸 선택 + 자동 복사를 만들어, pane 을 클릭해 포커스만 옮겨도 흰 자국이 남고 클립보드가 한 글자로 덮였다 (사용자 캡처 — pane 셋 클릭에 자국 셋) | `App.startTerminalSelection` / `updateTerminalSelection` 이 마우스 px 를 넘긴다 | `tildazMouseDown` / `Dragged` (auto-scroll 은 `g_last_drag_*`) | `pointerPx()` · `selectionSlop()` | ✅ | ✅ | ✅ |
| word selection 동작 사양 | cell 영역 | cross-platform 단일 모듈 ([terminal_interaction.zig:95](src/terminal_interaction.zig#L95)) | 동일 모듈 | 동일 모듈 (cross-platform `terminal_interaction`) | ✅ | ✅ | ✅ |
| 우클릭 paste | 어디든. **mouse tracking 이 켜져 있어도 paste 를 유지하고 앱에 보내지 않는다** ([#502](https://github.com/ensky0/tildaz/issues/502) 2026-08-24 결정 — 매일 쓰는 동작이라 앱이 켰다고 빼앗지 않는다. 앱에 우클릭이 필요하면 별도 논의) | `WM_RBUTTONDOWN` → `pasteClipboard` | `tildazRightMouseDown` → `handlePaste` | `wl_pointer.button` BTN_RIGHT → `wl_data_offer.receive` ([40af18b](https://github.com/ensky0/tildaz/commit/40af18b)) | ✅ | ✅ | ✅ |
| 휠 / 트랙패드 scroll | 셀 영역 | `WM_MOUSEWHEEL` → `scrollViewport` | `tildazScrollWheel` → 동일 | `wl_pointer.axis` → 동일 ([a8f2461](https://github.com/ensky0/tildaz/commit/a8f2461)) | ✅ | ✅ | ✅ |
| 스크롤바 클릭 + 드래그 | 우측 가장자리. **track** = `top = tab_bar_h + pad`, `h = viewport_h − tab_bar_h − 2·pad` (`pad` = `TERMINAL_PADDING_PT`) — thumb 을 맨 위로 올렸을 때 위 여백과 맨 아래로 내렸을 때 아래 여백이 **같아야 한다**. **thumb 의 정수 픽셀 스냅은 공통 `scrollbar.thumbPx()` 하나만 사용**하고, 위치와 크기를 따로 정수화하지 않는다 — 양 끝을 각각 반올림한 뒤 크기를 빼야 track 아랫변(정수)이 보존된다. 따로 절단하면 `⌊T−h⌋+⌊h⌋ = T−1` 로 아래 여백만 1pt 커진다 ([#344](https://github.com/ensky0/tildaz/issues/344), Linux 실기 발견). hit-test 는 계속 f64 연속값을 써서 드래그가 스냅에 끌리지 않는다. 같은 규칙을 dialog 본문 scrollbar 에도 적용 | `mouse.x >= client_w - SCROLLBAR_W` → `scrollToY` | 동일 (`scrollbarScrollToY`, Windows 패턴 그대로) | 동일 ([b53e4ab](https://github.com/ensky0/tildaz/commit/b53e4ab), L6.6 — Windows 패턴 그대로) | ✅ | ✅ | ✅ |
| 스크롤바 thumb 색 — **터미널 현재 배경 명도로 섞는 색을 뒤집음** ([#346](https://github.com/ensky0/tildaz/issues/346) 2026-07-29 확정) | 알파의 세기는 30% 그대로 두고 (`SCROLLBAR_ALPHA` 0.3) **섞는 색만** 배경 명도로 바꾼다 — 어두우면 흰색, 밝으면 검정. 판정은 `themes.isDarkRgb` 에 **terminal 의 현재 배경** (`RenderState.Colors.background` — OSC 11 과 `reverse_colors` 가 반영된 실효 배경) 을 넣는다. 탭바 chrome 이 **config theme** 배경을 쓰는 것과 기준이 다른데, thumb 은 chrome 이 아니라 **terminal 표면 위에** 얹히므로 그 면을 따른다 — config 기준이면 셸이 OSC 11 로 명도를 뒤집는 순간 thumb 이 소멸한다. [#266](https://github.com/ensky0/tildaz/issues/266) 의 color scheme DSR 도 같은 기준. 이전 흰색 고정은 밝은 테마 4종에서 대비가 **1.02~1.04** 로 소멸했고, 이제 18종 전부 **2.09 이상** (어두운 14종 2.465~2.713 / 밝은 4종 2.087~2.102). 합성을 공유 코드로 옮긴 뒤 (#353) 세 platform 이 **같은 값**을 낸다 — Tilda 는 `#4D4D4D` (정확값 `76.50000304` 의 최근접). 그 전에는 Linux · Windows 가 `#4C4C4C`, macOS 만 `#4D4D4D` 였다. `track`(홈)은 그리지 않는다 — thumb 만 (고정된 외관이 필요하면 track 도입이 수단이지만 시각 디자인 변경이라 비범위). 알려진 귀결 — 배경이 **중간 명도**면 어느 쪽을 섞어도 대비가 낮다 (`#808080` 에서 1.62 / 1.76). 내장 18종엔 그런 배경이 없고 OSC 11 로만 가능하다 | 우측 가장자리 thumb | 공통 [`ui_metrics.scrollbarColor(bg, dark)`](src/ui_metrics.zig) 가 **합성까지 끝낸 solid** 를 준다 — 세 platform 이 알파 1.0 으로 그린다 ([#353](https://github.com/ensky0/tildaz/issues/353), §알파 합성) | 동일 | 동일 | ✅ | ✅ | ✅ |
| viewport 이동 시 selection 유지 | 어디든 | ghostty `Selection` 이 `Pin` (page list 절대 위치) 기반 — viewport 는 보는 창문 | 동일 (같은 ghostty 모듈) | 동일 (같은 ghostty 모듈) | ✅ | ✅ | ✅ |
| 탭바 — 탭 클릭 | 상단 탭 영역 | `handleTabClick` → `setActiveTab` | 동일 (`tabBarHitTest`) | 동일 (L12-β, cross-platform `tab_interaction`) | ✅ | ✅ | ✅ |
| 탭바 — × 클릭 (**활성 탭 닫기**) | 우측 control cluster의 `×` ([#268](https://github.com/ensky0/tildaz/issues/268)). 단일 탭 `[+][×][…]`, 멀티탭 `[탭들][+][×][…]`, overflow `[<][탭들][>][+][×][…]`. per-tab close는 두지 않아 탭 전환 misclick을 막는다. 탭 본체 클릭은 어디든 전환만 | `handleTabClick` `.close` → `closeTab(activeIndex)` | `.close` → `handleCloseActiveTab` (Cmd+W 와 동일 helper) | `.close` → `closeIndex(activeIndex)` + `ensureSessionGrid` | ✅ | ✅ | ✅ |
| 탭바 — 활성 탭 표시·시각 대비 ([#334](https://github.com/ensky0/tildaz/issues/334) 2026-07-22 확정, [#342](https://github.com/ensky0/tildaz/issues/342) 2026-07-27 개정, [#335](https://github.com/ensky0/tildaz/issues/335) 2026-07-28 테마 파생) | **모든 탭 배경(활성 포함) = 탭바 배경**(`TAB_BAR_BG` — Tilda 에서 33/35/38, 사용자가 실측한 살짝 파란 끼의 회색. 순수 중성 회색은 갈색 끼로 보임. **다른 테마에서는 그 배경에서 파생** — 아래 별도 행) — 탭바 전체가 하나의 회색 띠 (Tilda 문법). **탭바-터미널 가로 경계선은 없다** (#342 — 탭바와 terminal 의 경계는 배경색 차이만으로). 활성 탭은 **탭바 맨 아래 모서리, 슬롯 폭 전체의 amber(`#F7A41D`) 2pt 밑줄로만** 구분 (drag 중이면 따라감). 탭 슬롯 경계는 **세로 구분선**(`TAB_SEPARATOR_W_PT` 1pt, `TAB_SEPARATOR_COLOR` — Tilda 에서 79/79/84) — y=0 부터 **탭바 전체 높이**, **모두 중심 정렬**(모든 탭 폭 동일) + 컨트롤 fill **뒤**에 그려 화살표 옆에서도 온전한 두께. 화살표 옆에는 끝 탭이 완전히 보일 때만 선. **amber 밑줄은 세로 구분선과 지오메트리상 겹치지 않는다** — 덮어서 가리는 게 아니라 밑줄 자체가 물러난다 (#342): 세로선이 중심 정렬로 슬롯 안에 들어오는 만큼 밑줄 양 끝을 줄이되, **선이 실제로 그려지는 경계에서만** (화살표 없을 때의 bi=0, tab_area 밖으로 잘린 경계에서는 물러나지 않아야 틈이 안 생김). 판정은 세로선 루프와 공유하는 `tab_layout.hasSeparator` 단일 정의. 물러나는 **양**은 renderer 수 체계마다 달라 각자 계산 — f32(macOS·Windows)는 좌우 `w/2` 대칭, 정수(Linux)는 `w − divTrunc(w,2)` / `divTrunc(w,2)` 로 홀수 두께에서 비대칭. drag 중인 탭은 슬롯 경계에 정렬되지 않아 물러나지 않는다. renderer 통합과 이 정수/실수 갈래 해소는 [#343](https://github.com/ensky0/tildaz/issues/343). hover 박스는 탭바 상하 기준 2pt 대칭 (경계선이 없어져 하단 보정 제거). world(슬롯) 기준 고정이라 drag 재배열 중 빈 원위치 슬롯도 구분선+제목 부재로 인지. 이 결정은 비활성 탭이 terminal 배경을 따르던 [#282](https://github.com/ensky0/tildaz/issues/282) 정책을 대체 | 공통 [`ui_metrics.zig`](src/ui_metrics.zig) 상수 + D3D11 | 동일 상수 + Metal | 동일 상수 + software | ✅ | ✅ | ✅ |
| 탭바 · command menu chrome 색 — **터미널 테마 배경에서 파생** ([#335](https://github.com/ensky0/tildaz/issues/335) 2026-07-28 확정) | `ui_metrics.zig` 의 chrome 색 9개는 **anchor** (= Tilda 순수 검정 배경에서의 값, #334/#342 시연 확정) 이고, 실제 색은 **config theme 의 배경**에서 파생한다 (OSC 11 런타임 배경이 아니라 config 값 — 2026-07-28 결정). 채널별 linear-light 에서 `C = k·bg + A` (dark) / `C = (bg − A)/k` (light, dark 의 **역함수**), `k = 1 + Y(A)/0.05`. 따라서 (1) Tilda 는 anchor 그대로 (2) `Y(C)+0.05 = k·(Y(bg)+0.05)` 항등이라 **요소 쌍의 대비비가 테마와 무관하게 상수** (탭바 1.33 / 구분선 1.93 / 제목 7.58 / hint 6.44 / hover 1.45·1.52) (3) `k·bg` 항이 테마 배경의 색상을 운반. 밝은 테마는 역함수라 탭바·구분선·제목이 모두 **어두워지는 방향**. `ctrl_active`(k=18.8) · `menu_label`(k=17.7) 은 chrome 이 밝아지면 목표 대비를 만들 흰색이 없어 **chrome→목표 방향 전체를 스케일백**한다 (채널별 클리핑은 hue 를 틀어서 쓰지 않음; 캡 후 대비는 최악 7.75). 출력 RGB 는 **8-bit 로 양자화**해 세 platform 이 정의상 같은 값을 받는다. **amber accent 는 파생하지 않는다** (브랜드 색 — 밝은 테마에서 밑줄 대비 1.35~1.46 은 알려진 귀결). `TAB_CTRL_HOVER_BG` 는 알파(흰색 12%)가 아니라 **합성 결과 solid** — 세 platform 블렌드가 모두 gamma space 라 값이 같다 | 공통 [`chrome_palette.zig`](src/chrome_palette.zig) → `D3d11Renderer.chrome` | 동일 → `MetalRenderer.chrome` | 동일 → `Renderer.chrome` (자유 함수엔 인자 전달) | ✅ | ✅ | ✅ |
| 탭바 — drag reorder | 탭 본체 drag | `DragState` (5px 임계) → `reorderTabs` | 동일 (`g_drag`) | 동일 (L12-γ-3, [5730137](https://github.com/ensky0/tildaz/commit/5730137)) | ✅ | ✅ | ✅ |
| 탭바 — drag follow 시각 | drag 중 탭 마우스 따라 이동 ([#297](https://github.com/ensky0/tildaz/issues/297) B3 결정. source 슬롯엔 탭바 배경이 남아 원위치 표시. z-order 최상위는 macOS 만 — Windows/Linux 는 그리기 순서대로) | `dragged_tab + drag_x` 인자 | 동일 (`TabDragView`, drag 탭 bg 마지막에 그려 z-top) | 동일 (#297 B3 — 이전의 source dim + drop indicator 방식 폐기) + 가장자리 auto-scroll | ✅ | ✅ | ✅ |
| 탭바 — 셸 OSC 0/2 자동 제목 ([#269](https://github.com/ensky0/tildaz/issues/269), [#364](https://github.com/ensky0/tildaz/issues/364) 2026-08-02 개정) | 탭 제목. **새 탭은 생성 시점부터 `Tab N` 을 표시**하고, 셸이 OSC 0/2 로 제목을 보내면 교체한다 — 제목 자리가 비는 구간이 없다. **첫 제목은 debounce 없이 즉시 반영**하고 (화면에 `Tab N` 만 있어 밀어낼 중간 제목이 없다), 두 번째 제목부터 셸이 보낸 raw window title 이 150ms 동안 동일하게 유지되면 반영 (짧은 명령의 순간 왕복 억제). 빈 title 은 최초 `Tab N` 으로 복귀. **이전 사양의 "1초 유예 후 fallback" 은 폐기** — OSC 를 안 보내는 셸이 흔해서 (실측: Windows `cmd`·PowerShell 5.1·pwsh 7 은 10/10 미전송, Linux POSIX `sh`·rc 없는 zsh 도 미전송) 기본 사용자가 1초 빈 제목을 봤고, 유예를 200~300ms 로 줄이는 안은 제목을 늦게 보내는 셸 (Linux zsh+p10k 328~410ms, Windows Git Bash 200~241ms, WSL cold 2.2초) 때문에 실측으로 기각됐다. 활성 탭과 비활성 탭 출력을 공통 드레인 예산 (§13) 안에서 번갈아 파싱하므로 탭 전환 없이 제목 갱신 | readonly VT parse 뒤 `Terminal.getTitle()` 동기화 (#266 의 ConPTY query-response 차단 유지) | `Effects.title_changed` → 공통 pending 제목 상태 | `Effects.title_changed` → 공통 pending 제목 상태 | ✅ | ✅ | ✅ |
| 탭바 — 긴 확정 제목 truncate ([#271](https://github.com/ensky0/tildaz/issues/271)) | text 영역을 넘으면 glyph 경계에서 자르고 마지막에 U+2026 `…` 한 글자(1 cell) 표시. CJK wide glyph를 반으로 자르지 않으므로 최대 1 cell이 남을 수 있음 | 공통 `tab_layout.iterTabText` → 일반 Unicode glyph path | 동일 | 동일 | ✅ | ✅ | ✅ |
| 탭바 — `<` / `>` 화살표 클릭 | 탭바 양 끝 화살표 (#117) | `scrollTabsByArrow` — viewport 만 1 탭 너비씩 이동, **활성 탭 안 바뀜** + `tab_scroll_user_override=true` | 동일 (`scrollTabsByArrow`) | 동일 (L12-γ-1, [2522e9a](https://github.com/ensky0/tildaz/commit/2522e9a) — cross-platform `tab_layout`) | ✅ | ✅ | ✅ |
| 탭바 — `+` 클릭 | control cluster 첫 버튼. 새 탭 생성 → 활성 → ensure가 viewport 우측 끝으로 정렬. 32-tab limit에서는 자리를 유지하고 비활성 색 + 클릭 noop ([#329](https://github.com/ensky0/tildaz/issues/329) 2026-07-22 결정 — 숨김 정책 대체. 단축키 경로 dialog 는 유지) | `handleNewTab` + `tab_layout.Layout.plus_enabled` | 동일 | 동일 | ✅ | ✅ | ✅ |
| 탭바 — `…` command menu ([#329](https://github.com/ensky0/tildaz/issues/329)) | 2.2pt diameter로 광학 보정한 원 3개 procedural icon (`+`/`×`는 1.5pt stroke 유지). Show / Hide TildaZ + 현재 instance의 실제 configured hotkey / 구분선 / New Tab / Close Active Tab / Copy Selection / Paste / Toggle Full Screen (hint 는 상태 의존 — workarea 전체화면 중에는 해제 키 `Shift+Alt+Enter`/`Shift+Cmd+Enter` 표시, 클릭은 어떤 모드든 상태 기준 토글) / Open Config / 구분선 / Keyboard Shortcuts / About TildaZ. Copy에는 drag, Paste에는 right-click 안내를 함께 표시. Keyboard Shortcuts는 canonical [`KEYBINDINGS.md`](KEYBINDINGS.md) URL을 기본 브라우저로 연다. **메뉴가 열린 동안은 modal 계층**: 모든 키는 메뉴가 소비 — Esc 닫기, Up/Down/Home/End/Tab/Shift+Tab focus 이동, Enter/Space 실행, 그 외 noop (PTY 로 안 감). pointer 가 항목 위로 오면 keyboard focus 도 그 항목으로 동기화 (표준 메뉴 — 마우스로 건너뛴 뒤 ↑↓ 가 그 자리에서 이어감). 단축키·명시적 paste·**Ctrl+C(interrupt — 2026-07-23 확정)** 는 메뉴를 닫고 정상 실행, global hotkey hide 도 메뉴를 닫음. menu 밖 click 은 닫고 그 click 은 terminal 에 전달하지 않음 — **우클릭도 닫기만 하고 paste 하지 않음**. 그 규칙은 창 *안* click 전제이고, **창이 focus 를 잃으면 메뉴를 닫는다** ([#390](https://github.com/ensky0/tildaz/issues/390) 2026-08-06 확정) — 창 *밖* click 은 OS/compositor 가 다른 창으로 라우팅해 pointer event 가 애초에 우리에게 오지 않는다 (native menu 를 닫아 주는 pointer grab 이, 창 안에 그리는 overlay 인 우리 메뉴에는 없다). 그래서 훅은 focus 상실뿐이다: mac `applicationDidResignActive` / Windows `WM_ACTIVATEAPP`(wParam=0) → `app_event.focus_lost` (menu 상태가 `App` 에 있어 `Window` 가 직접 못 닫음) / Linux `wl_keyboard.leave` (**main surface 만** — leave 는 client 전체 대상이라 자체 dialog surface 가 focus 를 받아도 main 에 온다). 세 훅 모두 다른 *앱/창* 활성화에만 와서 자체 dialog 로는 안 뜨고, 이미 있던 focus-loss 지점 그대로다 — mac · Windows 는 z-order 양보(#195), Linux 는 preedit commit (§4.1) 자리다 (Linux 는 z-order 양보가 platform-limit 로 미적용 — 아래 §3 표). **pointer 가 창을 떠나는 것은 훅이 아니다** (`wl_pointer.leave` · mouse leave) — 마우스만 창 밖으로 움직여도 닫히면 native menu 와 다르다. focus 를 잃어도 창은 visible 로 남으므로(#195) 닫을 때의 재그리기가 필수다 — `closeCommandMenu` 가 세 platform 모두 redraw 요청을 포함한다. viewport 높이가 모자라면 entry 단위로 잘라 wheel/키로 scroll (부분 행 없음, wheel 은 세 platform 모두 delta 누적 + 나머지 보존) 하고 **상/하단에 chevron 스크롤 표시 행** 이 생김 (탭바 `<`/`>` 관례 — 끝에 닿으면 비활성 색, 클릭 = 한 entry 스크롤 + 메뉴 유지). 좁은 폭·긴 hotkey 에서는 shortcut hint 를 먼저 숨김 (label 우선). 행 높이 22pt / 폭 320pt (#334 피드백 — 시연 튜닝). **색**: 배경 = `TAB_BAR_BG`, 항목 label = `MENU_LABEL_COLOR`, 우측 hint = `MENU_HINT_COLOR`, hover/focus 강조 = `MENU_HOVER_BG`, 내부 구분선 = `TAB_SEPARATOR_COLOR` (탭바와 한 문법 — #334 2026-07-22 확정). **외곽선은 없다** ([#342](https://github.com/ensky0/tildaz/issues/342) 2026-07-27 시연 확정) — 탭바에서 가로 경계선을 없앤 것과 같은 문법으로 chrome/terminal 경계는 배경 명도 차이만으로 둔다. 내부 구분선은 면의 경계가 아니라 항목 그룹이라 역할이 달라 유지한다. (이전 테두리는 `menu_y − line` 이라 탭바 마지막 행을 1pt 침범했는데 같은 색 가로 경계선이 덮고 있어 보이지 않던 것 — 가로선 제거로 드러난 지오메트리 오류였다.) 메뉴 명령 실행은 열기/실행 모두 pending 입력(terminal preedit) commit 후 — keyboard shortcut 과 같은 입력 정책 경유 | 공통 `command_menu.zig` View/hit/onKey + D3D11 overlay + `resolveWindowsInput` 경유 action | 공통 View/hit/onKey + Metal overlay + mouseDown 공통 commit 경유 action | 공통 View/hit/onKey + software overlay + `commitPendingInput` 경유 action | ✅ | ✅ | ✅ |
| 비활성 창의 첫 클릭 (click-through) ([#391](https://github.com/ensky0/tildaz/issues/391) 2026-08-06 확정) | 어디든 — **view 전체** (탭바만 아님). tildaz 는 focus 를 잃어도 숨지 않고 visible 로 남는 drop-down 이라 (#195 — z-order 만 양보) "비활성인데 화면에 보이는 창" 이 정상 상태이고, 그 상태의 첫 클릭을 버리면 탭바 `+`/`×`/`…` 를 포함해 **모든 클릭이 두 번**이 된다. 좌클릭만 해당 — 우클릭 paste (#119) 는 macOS 도 비활성 창에 `rightMouseDown:` 을 전달한다 | `WM_MOUSEACTIVATE` 핸들러를 두지 않아 `DefWindowProc` 기본값 `MA_ACTIVATE` (≠ `MA_ACTIVATEANDEAT`) 가 활성화 후 `WM_LBUTTONDOWN` 을 그대로 전달 | `acceptsFirstMouse:` → YES (`tildazAcceptsFirstMouse`). AppKit 기본값 NO 는 그 클릭을 창 활성화에만 쓰고 view 로 보내지 않는다 — Apple 문서가 override 예로 드는 것이 창 title-bar 버튼의 click-through 다 | pointer event 는 keyboard focus 와 무관하게 커서 아래 surface 로 간다 (Wayland 모델). layer-shell `on_demand` 라 그 클릭으로 keyboard focus 도 함께 받는다 | ✅ | ✅ | ✅ |
| OS mouse cursor shape (#193) | 아래 §3.1 표 참고 | `WM_SETCURSOR` 가 `App.cursorRegion` 호출 → `IDC_IBEAM` 또는 `IDC_ARROW` `SetCursor` ([src/window.zig](src/window.zig)) | NSView `resetCursorRects` 가 cell rect 에 `NSCursor.IBeamCursor` add ([src/host/macos.zig](src/host/macos.zig) `tildazResetCursorRects`) | `wp_cursor_shape_v1.set_shape(serial, text=9 / default=1)` ([30e94f0](https://github.com/ensky0/tildaz/commit/30e94f0), #193). compositor advertise 미지원 환경 graceful degrade | ✅ | ✅ | ✅ |
| z-order 양보 on focus loss (#195) | 다른 app 활성화 시 우리 z-order *level* 만 떨어뜨려서 그 app 이 위로. 우리는 *visible 유지* (hide 안 함, 다른 app 뒤에 보임). 다시 우리 app 활성화 시 원래 level 복귀. **Linux 미적용 — layer-shell categorical 한계, 아래 note** | `WM_ACTIVATEAPP wParam=0` → `SetWindowPos(HWND_NOTOPMOST)`, wParam=1 → `SetWindowPos(HWND_TOPMOST)` ([src/window.zig](src/window.zig)) | `applicationDidResignActive:` → `setMainWindowLevel(NSNormalWindowLevel)`, `applicationDidBecomeActive:` → `setPopupWindowLevel()` ([src/host/macos.zig](src/host/macos.zig)) | **❌ platform-limit** — layer-shell 의 4 단계 categorical layer (background/bottom/top/overlay) 가 normal app z-order 와 mix 안 됨. layer=top + exclusive 유지 ([aa59753](https://github.com/ensky0/tildaz/commit/aa59753), 아래 §3.1 note 참조) | ✅ | ✅ | ❌ (platform-limit) |
| **TUI mouse reporting** ([#502](https://github.com/ensky0/tildaz/issues/502)) | cell 영역만 (탭바 · 스크롤바 · command menu 는 언제나 우리 chrome 이 먼저 먹는다). 앱이 DECSET 으로 켠 tracking 에 따라 클릭 · 드래그 · 휠을 escape sequence 로 PTY 에 보낸다 — `?9` x10 (왼·가운데·오른쪽 **누름만**, modifier 없음, 좌표 223 상한) / `?1000` normal (누름+뗌) / `?1002` button (버튼 누른 채 이동) / `?1003` any (모든 이동). 좌표 형식은 `?1006` SGR (`CSI < Cb ; Cx ; Cy M`, 뗌은 소문자 `m` — 현대 표준) / `?1005` utf8 / `?1015` urxvt / `?1016` SGR-pixels. `Cb` = 버튼 (왼 0 · 가운데 1 · 오른 2 · 휠 64/65 · 가로 휠 66/67 · 뒤로/앞으로 128/129) + modifier (shift +4 · alt +8 · ctrl +16) + motion (+32). **휠은 `1 notch = 보고 1 건`** 이고, 연속 delta 를 주는 장치는 **누적 + 나머지 보존**으로 notch 를 센다 (버리면 느린 스크롤이 무동작이 되고, 이벤트마다 1 notch 로 세면 트랙패드에서 수십 배로 부푼다 — [#502](https://github.com/ensky0/tildaz/issues/502) macOS 실기에서 한 번 훑기에 66~86 건이 나갔다). 좌표는 내부 0-based → 전송 시 +1. **뗌의 버튼 번호는 SGR 계열만 유지**하고 legacy 는 항상 3. motion 은 **cell 이 바뀔 때만** 보낸다 (`?1016` 은 픽셀이 정보라 예외). viewport 밖은 **뗌은 항상** 보내고 motion 은 버튼이 눌린 경우만 — **그러려면 host 가 창 밖으로 나간 드래그의 이벤트를 계속 받아야 한다** (Windows `SetCapture`, macOS 는 `mouseDown` 받은 view 가 자동, Linux 는 Wayland implicit grab). 이것이 빠지면 인코더가 손쓸 수 없다: 창 밖에서 뗀 버튼의 이벤트가 아예 오지 않아 앱이 그 버튼을 영원히 눌린 것으로 안다 ([#502](https://github.com/ensky0/tildaz/issues/502) Windows 실기에서 가운데 버튼이 그랬다). **`Shift` 는 우리 것** — Shift+드래그 / Shift+휠은 앱에 보내지 않고 selection / scrollback 으로 남긴다 (xterm · iTerm2 · Windows Terminal 관례). 단 앱이 XTSHIFTESCAPE (`CSI > 1 s`) 로 Shift 를 요구하면 넘긴다. 더블클릭은 press 로만 보내고 word selection 으로 가로채지 않는다 (의미는 앱이 정한다). 가운데 버튼은 chrome 에 역할이 없어 reporting 전용. **가로 휠 · 뒤로/앞으로 버튼은 인코더만 있고 host 배선은 미구현** | 공통 `mouse_report.zig` + `terminal_interaction.routeMouse` → `app_controller` 의 `.mouse_*` / `.scroll` 분기. `WM_MBUTTONDOWN`/`UP` 신규 — **왼쪽과 같이 `SetCapture` 를 잡고**, 뗌은 보고 대상 버튼 (왼쪽 · 가운데) 이 하나도 안 남았을 때만 `ReleaseCapture` (capture 가 스레드당 하나라, 무조건 놓으면 함께 누른 다른 버튼의 드래그가 끊긴다). `WM_MOUSEWHEEL` 은 `ScreenToClient` 로 좌표 변환 (screen 좌표로 옴) + `WHEEL_DELTA` (120) 눈금이 곧 notch | 같은 공통 모듈 + `tildazMouseDown/Dragged/Up` · `scrollWheel:` (**`hasPreciseScrollingDeltas` 로 단위를 가른다** — 트랙패드는 논리 pt 라 cell 높이당 1 notch, 마우스 휠은 tick 이라 그대로. 느린 한 칸이 `0.1` 로 오므로 최소 1 tick 으로 올린다) · `mouseMoved:` · `otherMouseDown:`/**`otherMouseDragged:`**/`otherMouseUp:` (가운데 버튼, 신규 등록 — Cocoa 는 버튼별 selector 라 가운데 드래그가 `mouseDragged:` 로 오지 않는다) | 같은 공통 모듈 + `wl_pointer.button`/`motion`/`axis`. **버튼 상태를 직접 추적** (`wl_pointer.motion` 은 눌린 버튼을 싣지 않는다) + modifier 는 `wl_keyboard.modifiers` 쪽 (`keyboard.{shift,ctrl,alt}Active()`). `BTN_MIDDLE` (0x112) 신규. 휠은 `wl_fixed` 를 120 단위로 누적 (`report_wheel_accum`) | ✅ | ✅ | ✅ |
| alternate scroll ([#502](https://github.com/ensky0/tildaz/issues/502)) | tracking 이 **꺼져 있고** alt screen + `?1007` (ghostty 기본 on) 이면 휠을 화살표 키로 바꿔 보낸다 — notch 당 3 줄, DECCKM (`?1`) 이 켜져 있으면 `SS3` (`ESC O A/B`) 아니면 `CSI` (`ESC [ A/B`). alt screen 은 scrollback 이 없어서 그대로 두면 휠이 무동작이다. Shift+휠은 여기서도 우리 scrollback 이다 | `routeWheel` (`app_controller`) | `routeWheelMac` | `routeWheelLinux` | ✅ | ✅ | ✅ |

### 3.1 OS mouse cursor shape (#193) — 영역별 정의

| 영역 | hover 시 cursor | 비고 |
|---|---|---|
| 셀 (terminal grid) 영역 | I-beam | preedit / 기타 상태 무관, 셀 영역은 *항상* 텍스트 편집 컨텍스트 |
| 탭바 — 우측 `+` / `×` / `…` 버튼 | arrow | 버튼 성격 — 클릭 = 새 탭 / 활성 탭 닫기 / command menu (#268, #329) |
| 탭바 — 탭 본체 / `<` / `>` / `+` / `×` / `…` / 빈 영역 / drag 중 | arrow | 탭바의 기본 — 클릭 / drag 등 *버튼* 성격 영역 |
| 스크롤바 (우측 10 PT) | arrow | drag-to-scroll 버튼 |
| 윈도우 padding / 가장자리 | arrow | terminal_padding 영역 |
| 윈도우 가장자리 (system non-client) | OS 기본 | 우리가 안 건드림 (Win: HTBORDER 등은 `DefWindowProc` 처리, mac: borderless 라 가장자리 없음, Linux: layer-shell 가장자리 없음) |

> **참조 비교:** VSCode / Chrome 탭바 동등 패턴 — 셀(내용 영역) I-beam, 탭바는 항상 arrow. (탭 inline rename 은 [#341](https://github.com/ensky0/tildaz/issues/341) 로 제거 — rename 활성 탭 text 영역의 I-beam 예외도 함께 삭제.)

> **z-order 양보 — Linux 미적용 (#195):** Linux Wayland 의 `zwlr_layer_shell_v1` 은 *categorical* 4 단계 (background / bottom / top / overlay) 라 *normal xdg_toplevel z-order level* 자체가 없음. `set_layer(bottom)` 으로 떨어뜨려도 *desktop wallpaper 바로 위 + 모든 일반 windows 아래* — 사용자 의도 (*다른 새 창 → tildaz → 그 외*) 와 어긋남 (tildaz 가 모든 일반 windows 아래로 가버림). mac `NSWindow.setLevel(NSNormalWindowLevel)` / Win `SetWindowPos(HWND_NOTOPMOST)` 은 우연히 *normal app z-order* 와 mix 자연이라 한 줄 toggle 로 완벽 — Linux 의 categorical 한계 우회 불가. *layer-shell destroy + xdg_toplevel 재생성* 도 시도 가능하나 DE / compositor 마다 동작 다양 + animation glitch + 매 toggle 마다 수십~수백 ms latency 라 사용자가 알아챔. 회피 — layer=top + `keyboard_interactivity=exclusive` 유지. drop-down 본분 (yakuake / guake / Tilda 등 모든 Linux drop-down 동등 한계). 사용자가 hotkey 로 hide 후 다른 app 사용.

> **`<` / `>` 화살표 vs 활성 탭 — Firefox 패턴 (#117):**
>
> 1. `<` / `>` 클릭은 *viewport 스크롤 전용* — 활성 탭은 절대 안 바뀜. 사용자가 "다른 탭 *목록* 을 보러 왔다" 는 명시 의도이지 활성 전환 의도 아님.
> 2. 활성 변경 트리거는 **탭 클릭 / Alt+숫자 / Ctrl+Shift+[ / Ctrl+Shift+] / Ctrl+PgUp / Ctrl+PgDn (Win · Linux) / Cmd+숫자 / Shift+Cmd+[ / Shift+Cmd+] / Cmd+PgUp / Cmd+PgDn (mac) / `+` (새 탭)** 만.
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
| 컬렉션 | `ArrayList(*Tab)` + `active_tab: usize` | `SessionCore` | `SessionCore` (v0.4.0+ 통합) | `SessionCore` 동일 (L12-α [15b886a](https://github.com/ensky0/tildaz/commit/15b886a)) | ✅ | ✅ | ✅ |
| 새 탭 크기 | 활성 탭의 cols/rows 와 동일 | `createTab(cols, rows, ...)` | 동일 | 동일 | ✅ | ✅ | ✅ |
| 격자 **열 수** — scrollbar 자리를 **항상** 비운다 ([#350](https://github.com/ensky0/tildaz/issues/350) 2026-07-29 확정) | `cols = ⌊(viewport_w − 2·TERMINAL_PADDING − SCROLLBAR_W) / cell_w⌋` (최소 1). scrollbar 는 스크롤백이 있을 때만 그려지지만 **자리는 항상 비운다** — 보일 때만 비우면 스크롤백이 처음 생기는 순간 열 수가 줄어 셸이 reflow 하고 출력 중 레이아웃이 흔들린다. 이 식이라 셀의 오른쪽 끝이 hit-test 의 셀 경계 (`viewport_w − pad − SCROLLBAR_W`) 를 넘지 않는다. 이전에는 세 platform 이 `viewport − 2·pad` 를 각자 계산했고 (macOS 는 세 곳, 합 **다섯 곳**) 전부 scrollbar 를 빼지 않아 **마지막 열이 scrollbar 열과 겹치고 hit-test 와 어긋나 클릭·선택이 안 됐다.** 같은 누락 재발을 막으려 단일 정의로 모았다 | 공통 [`ui_metrics.terminalCols`](src/ui_metrics.zig) ← `getTerminalGridSize` | 동일 ← `syncTerminalGeometry` / screen-change / session 생성 3곳 | 동일 ← `Client.gridSize` | ✅ | ✅ | ✅ |
| 격자 **행 수** — 탭바와 위아래 padding 을 뺀다 ([#352](https://github.com/ensky0/tildaz/issues/352)) | `rows = ⌊(viewport_h − tab_bar_h − 2·TERMINAL_PADDING) / cell_h⌋` (최소 1, 상한 `u16`). `tab_bar_h` 는 탭이 1개면 0 이다 (#127) — 그 판정은 host 가 하고 식은 받은 값만 뺀다. 열 수가 `SCROLLBAR_W` 를 빼는 자리에 행 수는 `tab_bar_h` 를 뺀다 (**대칭**). [#350](https://github.com/ensky0/tildaz/issues/350) 이 열 수만 모았을 때 행 수는 같은 다섯 곳에 남아 **한 함수 안에서 `cols` 는 방어되고 다음 줄 `rows` 는 안 되는** 비대칭이 생겼고, 세 platform 이 같은 위험을 각자 다른 방식으로 막고 있었다 (Linux 는 분자 clamp + `u16` 상한, Windows 는 분자 clamp + `cell_h == 0` guard, macOS 는 `u32` 언더플로용 명시 guard 에 상한 없음). 산술 결과는 도달 가능한 입력 전부에서 같았고 이 통합으로 방어까지 한 곳이 됐다 | 공통 [`ui_metrics.terminalRows`](src/ui_metrics.zig) ← `getTerminalGridSize` | 동일 ← 지역 `terminalGrid` (3곳 공용) | 동일 ← `Client.gridSize` | ✅ | ✅ | ✅ |
| 단일↔멀티 전환 시 cell 영역 동기화 | 단일 탭은 full 탭바 자리 없이 control strip만 overlay → 멀티탭 전환 시 full 탭바가 cell 영역을 줄이므로 모든 탭 cols/rows 재계산 (#127, #329). | `effectiveTabBarHeight()` + `createTab` / `handleCloseResult` 의 `resizeAll` | `syncTerminalGeometry` 호출 | `handleNewTab` / `handleCloseTab` / `drainExitedTabs` / `handleTabBarClick` 직후 `Client.ensureSessionGrid()` 호출 | ✅ | ✅ | ✅ |
| 활성 인덱스 자동 조정 (close) | 닫힌 탭이 활성 앞이면 -1, 활성 자체였으면 새 마지막으로 | `nextActiveIndexAfterClose` | `closeTab` 안 동일 정책 | 동일 (SessionCore 공통) | ✅ | ✅ | ✅ |
| PTY exit → 그 탭만 정리 | read thread → main thread 안전 | `WM_TAB_CLOSED` post + `closeTabByPtr` | `Tab.exit_flag` atomic + `drainExitedTabs` | 동일 (Linux PTY `Tab.exit_flag` atomic) | ✅ | ✅ | ✅ |
| 마지막 탭 종료 → 앱 종료 | count == 0 시 | `closeAfterShellExit` | `NSApp.terminate:` | wayland event loop break + `exit(0)` | ✅ | ✅ | ✅ |
| Drag reorder 5px 임계 | drag 가 5px 미만 = click | `DragState.move` | 동일 (cross-platform `tab_interaction.zig`) | 동일 모듈 (L12-γ-3) | ✅ | ✅ | ✅ |
| 탭 — MAX_TABS 32 한도 + dialog | `+` 는 자리 유지 + 비활성 색 + 클릭 noop ([#329](https://github.com/ensky0/tildaz/issues/329)), 단축키 시 dialog | `tab_actions.checkAtLimitAndDialog` (#159 v0.4.0) | 동일 (양쪽 같은 helper) | 동일 helper — dialog UI 는 §6 step 3 후 layer-shell overlay (#203) | ✅ | ✅ | ✅ |

### 4.1 Pending 입력 (terminal preedit) focus_loss 정책 (#175, #296)

> **입력 상태 × 단축키/키 처리 정책은 `src/input_policy.zig` (`resolve`) 단일 소스** — 세 host(Windows `onAppEvent` / macOS keyDown / Linux `processKeyEvent`)가 native 입력을 분류해 `resolve` 에 넘기고 그 결과(pending: leave/commit/discard × target: pty/run_action)대로 동작한다. §5.1 이 그 정책의 truth table 이며 `input_policy` 의 단위 테스트로 고정 (#296).

terminal preedit(조합 중 자모) 활성 중에 어떤 focus_loss (마우스 클릭 / 상태 변경 단축키 / F1 hide / quit) 가 발생해도 동일 동작 = **commit** (자모를 PTY 로 flush — 사용자 입력 손실 회피). 예외 둘: **Ctrl+C** 는 discard (line abort, §5.1), **read-only 단축키(copy_selection / dump_perf)** 는 preedit 을 유지하되 자모 보존이 필요한 terminal preedit 은 flush 후 실행한다.

(탭 inline rename 과 그 focus_loss commit 표는 [#341](https://github.com/ensky0/tildaz/issues/341) 로 제거 — 과거 표는 그 이슈와 git 이력 참조.)

### 4.2 화면 분할 (pane) — [#483](https://github.com/ensky0/tildaz/issues/483)

탭 하나 = pane 그룹 (`session_core.TabGroup`), pane = 터미널 하나 (`Tab`). 배치는 분할 트리 (`pane_layout.Tree`) 이고 격자 계산 · hit-test · 이웃 찾기는 순수 모듈 [`pane_layout.zig`](src/pane_layout.zig) 한 곳이다. 확정 설계는 이슈 첫 댓글, 단축키 표는 [KEYBINDINGS.md](KEYBINDINGS.md#split-panes). 2026-08-27 4단계에 Linux, 5단계에 macOS · Windows host 를 배선했다. **세 platform 모두 실기 손 확인을 마쳤다** — macOS (2026-08-28 · 08-29), Windows 11 (W1~W25, [실기 댓글](https://github.com/ensky0/tildaz/issues/483#issuecomment-5459938906)), KDE Plasma 6.7 · 분수 배율 1.7× (L1~L20, [실기 댓글](https://github.com/ensky0/tildaz/issues/483#issuecomment-5459875149)). 2026-08-27 6단계 마무리에서 사용자 결정으로 단축키 (분할 둘로 축소 · macOS `alt+cmd`) · 표시 (3 면 규칙 · 최대화 4 면) · 크기 조절 (clamp · 붙은 칸만) 을 바꿨다 — 그 뒤 바뀐 행 (균등 · 최소 크기 · 선택 문턱 · 비라틴 배열 Alt) 도 세 platform 실기에서 다시 확인했다.

| 항목 | 동작 정의 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|---|
| 분할 | 네 방향 **`split_left` · `split_right` · `split_up` · `split_down`** — 화살표가 곧 새 pane 이 놓이는 자리다. 왼쪽 · 위는 오른쪽 · 아래와 격자가 **완전히 같고** 새 pane 이 분할 노드의 first 냐 second 냐만 다르다 (`Direction.towardSecond()`). 2026-08-27 에는 오른쪽 · 아래 둘뿐이었고 이름도 `split_vertical` / `split_horizontal` 이었는데, 2026-08-29 에 네 방향으로 넓히면서 방향 이름으로 바꿨다 — `vertical` / `horizontal` 은 tmux 와 iTerm2 가 **정반대 뜻**으로 쓰는 낱말이라 어느 쪽을 따르든 절반은 헷갈리고, 방향 이름은 `focus_pane_*` · `resize_pane_*` 와 낱말이 같아진다. 활성 pane 을 반씩 가르고 새 pane (새 셸, cwd 상속 규칙은 새 탭과 같다) 이 **활성** 이 된다 (tmux · iTerm2 · WT · Ghostty · vim 모두 새 pane 으로). 왼쪽 · 위를 4a 에서 뺐던 근거 ("어느 터미널에도 기본에 없다") 는 지금도 사실이지만, `[keys]` 가 양방향 strict 라 액션 추가가 곧 기존 config 의 부팅을 막으므로 **이미 스키마가 깨지는 v0.9.3 에 함께 넣는 것이 사용자 비용 0** 이고, `Ctrl+Shift+←` 가 비어 있어 "수식키가 동사, 방향키가 방향" 규칙이 절반만 적용돼 있었다. 분할선은 앞 pane 의 셀 경계에 두고 남는 px 는 뒤 pane 에 (1단계 결정 2) | `ctrl+shift+{right,down,left,up}` → `app_event.Shortcut.split` (+ `direction`) → `App.handleSplit` | `alt+cmd+{right,down,left,up}` → `handleSplit` — 4a 의 `ctrl+cmd+방향키` 는 `⌃↑` / `⌃↓` (Mission Control) 와 부딪혀 바꿨고, Apple Terminal · iTerm2 의 `⌘D` 는 글자에 뜻이 없어 안 쓴다 | `ctrl+shift+{right,down,left,up}` → `SessionCore.splitActive` | ✅ | ✅ | ✅ |
| 상한 · 최소 크기 | 탭당 pane **16** (`MAX_PANES_PER_TAB`, 탭 32 와 독립 — 1단계 결정 1) · pane 최소 **20×5** 셀 (`MIN_PANE_COLS/ROWS`). 넘으면 트리를 바꾸지 않고 거부 + dialog (`messages.pane_limit_*` / `pane_too_small_*`) — 단축키에는 시각 피드백이 없어 탭 한도와 같은 방식 | `App.handleSplit` (같은 dialog) | `handleSplit` (같은 dialog) | `handleSplit` | ✅ | ✅ | ✅ |
| 포커스 이동 | **기하 기반** 이웃 (`pane_layout.neighbor`) — 활성 pane 의 커서 행/열에서 그 방향으로 쏴 처음 만나는 pane (3 분할 이상에서 트리 형제가 아닌 화면상 이웃으로 간다). 창 가장자리면 무시. 떠나는 pane 의 진행 중 선택 · 드래그는 탭 전환과 같이 정리 | `alt+방향키` → `App.handleFocusPane` | `cmd+방향키` → `handleFocusPane` | `alt+방향키` → `SessionCore.focusPane` | ✅ | ✅ | ✅ |
| 크기 조절 · 균등 | 활성 pane 에 닿은 분할선을 한 셀 옮김 (`Tree.resize` — 그쪽 변이 창 가장자리면 반대쪽 분할선). 드래그와 **같은 경로** (`Tree.setSeparatorPx`) 라 규칙도 같다 — 최소 크기에 닿으면 **거부하지 않고 거기서 멈추고** (clamp), **선에 붙은 칸만** 변한다 (아래 분할선 드래그 행, 2026-08-27 결정). 균등은 **같은 축으로 이어진 분할선을 한 줄로 보고 그 줄을 행 · 열 수로 고르게 나눈다** (`Tree.equalize(rect, m)` · `cellsAlong` — 칸 = pane 하나 또는 다른 축으로 갈린 묶음 하나). 비율이 아니라 **셀 수** 로 나누는 이유: 비율만 정하면 픽셀 위치를 `splitGeometry` 가 그때그때 반올림하는데 그 반올림이 트리 중첩을 따라 일어나 같은 4 칸이라도 만든 순서가 다르면 결과가 달랐다 (2026-08-28 실기 — 두 열의 가로선이 26 px 어긋나고 한 열 안 높이가 466 · 505 로 벌어짐). 같은 이유로 `splitGeometry` 의 셀 격자도 앞 자식이 품은 **칸 수** 를 센다 (결정 2 개정 — 중첩된 두 칸이 38 · 37 열 + 남는 11 px 대신 38 · 38 열로 떨어진다). A \| B \| C 는 ⅓ 씩, A \| (B/C) 는 A ½ 에 B · C 가 오른쪽 절반을 위아래 반씩, 2×2 는 ¼ 씩 — tmux · iTerm2 처럼 한 줄에 칸이 여럿인 (n-ary) 분할의 "고르게 펴기" 와 같은 결과 (tmux `even-*` 는 배치를 한 줄로 바꾸는 다른 것). 2026-08-28 결정 ① — 거쳐 온 둘: vim `Ctrl+W =` 식 leaf 수 가중은 A \| (B/C) 에서 A 가 ⅓ 로 줄어 어색했고, 층별 반씩은 A \| B \| C 가 A ½ · B ¼ · C ¼ 라 "셋인데 균등이 아니다" 였다. 메뉴에는 없다 (2026-08-27 — 쓰임이 드물어 단축키만) | `shift+alt+방향키` · `shift+alt+0` | `shift+cmd+방향키` · `shift+cmd+0` | `shift+alt+방향키` · `shift+alt+0` | ✅ | ✅ | ✅ |
| 닫기 — 탭 | `close_tab` = **활성 탭 통째로** (그 안의 pane 전부). 마우스 `×` 와 `⋯` 메뉴의 `Close Active Tab` 도 같다 — 액션 이름 · 라벨 · 위 §2.2 표가 모두 "탭" 이므로 ([#544](https://github.com/ensky0/tildaz/issues/544), 2026-08-29). **세 platform 모두 실기 확인** ([Windows 8 케이스](https://github.com/ensky0/tildaz/issues/544#issuecomment-5462736212) · [macOS 8 케이스](https://github.com/ensky0/tildaz/issues/544#issuecomment-5462767119)) | `tab_actions.closeActive` → `SessionCore.closeTab(active_tab)` | 동일 | 동일 + `ensureSessionGrid` | ✅ | ✅ | ✅ |
| 닫기 — pane | `close_pane` = **활성 pane 하나만** (형제가 자리를 이어받고 포커스는 맞닿아 있던 pane), 마지막 pane 이면 탭, 마지막 탭이면 앱 종료. pane 의 PTY 종료 (셸에 `exit`) 도 같은 규칙 (`closeTabByPtr`) 이라 결과가 같다. **마우스 수단은 없다** — `×` · `⋯` 메뉴는 둘 다 탭이다 (#544). **세 platform 모두 실기 확인** ([Windows 8 케이스](https://github.com/ensky0/tildaz/issues/544#issuecomment-5462736212) · [macOS 8 케이스](https://github.com/ensky0/tildaz/issues/544#issuecomment-5462767119)) | `tab_actions.closeActivePane` → `SessionCore.closeActivePane` | 동일 | 동일 + `ensureSessionGrid` 로 남은 pane 격자 | ✅ | ✅ | ✅ |
| 표시 | 회색 분할선 **1 pt** (`PANE_SEPARATOR_W_PT`, 색은 탭 구분선과 같은 `chrome.separator` — 테마 파생) + 활성 pane 의 padding 안쪽 amber **1 pt** (`PANE_FOCUS_LINE_PT`, `TAB_ACCENT_COLOR`). 어느 변인가는 순수 함수 `pane_layout.focusEdges` 하나가 정한다 (2026-08-27 사용자 규칙): ① 다른 pane 과 맞닿는 **안쪽 변** 은 항상 ② 안쪽 변이 **하나뿐** 인 pane (반 분할의 양쪽, 한 줄의 양 끝 — 바깥과 3 면 닿음) 은 그 변에 직각인 바깥 두 변도 → **3 면** (⊐ 모양). 안쪽 변 하나만으로는 회색 선 어느 쪽인지 1 pt 로 읽히지 않았다 (반 분할에서 두 pane 의 표시가 같은 선 하나) ③ 안쪽 변 둘 이상 (ㄴ · ‖) 은 길이 · 모양으로 읽히니 안쪽만 ④ 최대화면 **4 면** — 일반 pane 은 최대 3 면이라 4 면 틀 = 최대화. pane 하나면 없음. **비활성 pane dim 없음** (2026-08-27 사용자 결정 — 다른 pane 도 또렷히 보는 것이 분할의 목적). 비활성 pane 의 커서도 그대로 그린다 (`PaneDraw.is_active` 는 그리기에 안 씀) | `D3d11Renderer.drawPaneChrome` | `MetalRenderer.drawPaneChrome` | `software_terminal.collectPaneChrome` | ✅ | ✅ | ✅ |
| 마우스 | 좌클릭 = 그 pane 포커스 + 그 자리에서 선택 시작 (한 클릭) · **비활성 pane 우클릭 = 포커스만, 붙여넣기 X** · scrollbar hit-test · Shift+PgUp/PgDn 은 활성 pane 기준 · **휠은 포인터 아래 pane 을 스크롤하고 포커스는 그대로** (6단계 결정 B, 2026-08-27 — `SessionCore.paneTabAt`; 분할선 위 · pane 밖이면 활성 pane; 마우스 reporting 의 휠은 활성 pane 기준 그대로. 세 platform 실기 확인 — 비활성 pane 위 휠에 그 pane 만 변하고 amber · 포커스는 그대로. macOS 는 `CGEventCreateScrollWheelEvent` 도구, Linux 는 uinput 휠 + 픽셀 diff ([#483](https://github.com/ensky0/tildaz/issues/483#issuecomment-5439772268)), Windows 는 W13 — thumb `y858`→`y760` 이고 활성 pane 의 thumb · amber 는 불변 ([#483](https://github.com/ensky0/tildaz/issues/483#issuecomment-5459938906))) · 분할선 위 클릭은 무시 (드래그는 4c) | `App.focusPaneUnderPointer` · `inActiveScrollbarColumn` (우클릭은 좌표를 실은 `mouse_right_down`) | `focusPaneUnderPointer` · `inActiveScrollbarColumnMac` (우클릭은 `tildazRightMouseDown`) | `focusPaneUnderPointer` · `pointerInActiveScrollbarColumn` | ✅ | ✅ | ✅ |
| 격자 | 창 · 탭바 · 폰트가 바뀌면 모든 탭의 pane 을 layout 결과로 resize (`SessionCore.applyLayouts`, 같은 격자면 건너뜀). `-size` 측정 인스턴스는 pane 하나에 요청 격자 그대로 (#382) | `App.syncPaneGrids` → `applyLayouts` (`-size` 는 `resizeAll`) | `syncTerminalGeometry` · `syncGeometryAfterScreenChange` → `applyLayouts` (`-size` 는 `resizeAll`) | `ensureSessionGrid` → `applyLayouts` | ✅ | ✅ | ✅ |
| IME · 컨트롤 스트립 | preedit inline 표시 · IME 커서 rect · mouse reporting 좌표는 활성 pane 의 격자 원점 기준 (`terminal_interaction.ReportGeometry.grid_x/grid_y`). 단일 탭 컨트롤 스트립 (#329) 의 scrollbar inset 은 오른쪽 위 pane 만 | `App.activeGridOrigin` (`mouseToCell` · 선택 · mouse reporting); IME 조합 창 위치는 렌더러가 활성 pane (`PaneDraw.is_active`) 의 커서만 기록 | `renderFrameTick` · `activeGridOriginPx` (IME 스냅숏 · `imeFirstRect` 도 이 원점) | `frameInputs` · `activeGridOrigin` | ✅ | ✅ | ✅ |
| 최대화 (zoom) | `zoom_pane` 토글 — 켜면 활성 pane 하나가 탭 영역 전체 (`TabGroup.zoomed`, `layout` 이 `leafRect` 하나를 돌려준다), 다른 pane 은 그리지 않되 셸은 계속 돈다. 분할 · 포커스 이동 · 크기 조절 · 균등은 먼저 푼다 (tmux zoom 규칙), 그 pane 이 닫히거나 pane 이 하나가 되면 풀린다. 표시는 활성 pane **네 변** amber (2026-08-27 결정 A — 분할선 · amber 가 사라지는 것만으로는 분할 없는 탭과 구분이 안 됐다; 일반 pane 은 최대 3 면이라 4 면 틀은 최대화 하나뿐, 위 표시 행) | `ctrl+shift+z` → `App.handleZoomPane` | `shift+cmd+z` → `handleZoomPane` | `ctrl+shift+z` → `SessionCore.toggleZoomActive` | ✅ | ✅ | ✅ |
| 분할선 드래그 | 회색 선 ±4 pt (`PANE_SEPARATOR_HIT_SLOP_PT`) 누름 → 드래그. 드래그 중엔 셀 경계에 스냅된 amber 고스트만 그리고 (`Tree.setSeparatorPx` 를 트리 복사본에 적용해 자리를 얻는다) **놓을 때 한 번만** 트리 갱신 + PTY resize (확정 설계 축 2 — Konsole 방식, SIGWINCH 폭풍 방지). 최소 크기 (20×5 셀) 에 닿으면 **거기서 멈춘다** (clamp, 2026-08-27 결정 — 고스트가 한계에 서고 놓으면 거기까지만; 예전엔 드래그 전체를 거부해 "끌다가 취소됨" 으로 보였다). **선에 붙은 칸만 변한다** — 선 너머가 같은 축으로 또 갈려 있어도 먼 칸은 px 그대로 (`Tree.keepFarFixed` 가 안쪽 같은-축 분할의 비율을 다시 놓는다; 예전엔 비율이 그대로라 안쪽 분할선까지 비례해 밀렸다). 위아래로 쌓인 칸은 둘 다 선의 이웃이라 같이 변한다. 한계도 먼 칸을 고정한 채 잰다 (`Tree.minExtentKeepFar`). 커서는 분할선 위에서 `col_resize` / `row_resize` | `App.sep_drag` · `finishSeparatorDrag`, 커서는 `WM_SETCURSOR` 의 `IDC_SIZEWE` / `IDC_SIZENS` (`CursorRegion.separator_*`) | `g_sep_drag` · `finishSeparatorDrag`, 커서는 `resetCursorRects` 의 `resizeLeftRight/UpDownCursor` | `sep_drag` · `finishSeparatorDrag` | ✅ | ✅ | ✅ |
| 최소 크기 20 열 × 5 행 | `MIN_PANE_COLS` / `MIN_PANE_ROWS` (열 × 행 — 터미널 `80x24` 표기 순서). **분할은 갈라지는 두 조각을, 가르는 축만** 검사한다 (2026-08-28 결정 — 좌우 분할은 `cols`, 위아래 분할은 `rows`. 반대 축은 이 분할이 건드리지 않는다: 창이 줄어 19 열이 된 pane 을 위아래로 가르는 것이 "20 열 미만" 으로 거부되던 것이 실기에서 걸렸다). 거부는 `TooSmall` → 대화상자 "Each pane needs at least 20 columns × 5 rows". 창이 줄면 (drop-down 은 커서가 있는 모니터 크기를 따르고 pane 은 비율 유지) pane 이 최소 아래로 **갈 수 있다** — 막지 않는다 (tmux 도 같다). 그 뒤 크기 조절 · 드래그는 그 pane 을 **더 줄이지만 않고** (한계 = 지금 크기, `minExtentKeepFar`), 뒤 검사는 "새로 최소 아래로 떨어지는 pane 이 없다" (`noPaneNewlyBelowMin`) 다. 2026-08-27 macOS 실기: 큰 모니터에서 가른 뒤 작은 모니터로 돌아오니 B · C 가 17 열이 됐고, 예전의 탭 전체 검사 (`allPanesAtLeastMin`, 삭제) 가 A 의 위아래 분할과 B 키우기까지 막았다 | 공통 `pane_layout` | 동일 | 동일 | ✅ | ✅ | ✅ |
| 마우스 경로 | `…` 메뉴 *Split Right* / *Split Down* (`command_menu.Command.split_right/horizontal`, 순수 모듈이라 세 host 에 같이 뜬다 — 실행은 배선된 host 만) · `+` **Alt+클릭** = 활성 pane 분할 (Windows Terminal 선례; 방향은 pane 이 넓으면 오른쪽, 높으면 아래 — WT `auto`) | `executeCommandMenu` · `handlePlusClick` (Alt+클릭, `Window.isAltDown`) | `executeCommandMenu` · `handlePlusClick` (Option+클릭) | `executeCommandMenu` · `handlePlusClick` | ✅ | ✅ | ✅ |
| 출력 드레인 | 예산 4 ms 하나를 보이는 pane 이 나눠 씀 — 활성 pane 먼저, pane 사이에도 예산 검사 (§13.3.1, 세 platform 실측 표). **코드는 공통이지만 실측은 갈린다** — Linux 만 16 pane 에서 상한이 깨지고, 공정성은 pane 2 개부터 host 마다 크게 다르다 (§13.3.1) | 공통 `SessionCore.drainFrame` | 동일 | 동일 | ✅ | ✅ | ✅ |
| 비활성 pane 스크롤바 | 클릭 = 그 pane 포커스 뒤 그 pane 의 scrollbar 로 (좌클릭 경로가 포커스를 먼저 옮긴다) | 동일 | 동일 | 동일 | ✅ | ✅ | ✅ |

---

## 5. IME 동작 (한국어 / 일본어 / 중국어 — 양쪽 동일 spec)

`AGENTS.md # 한글 IME 동작 스펙` 의 정의 그대로. 요약:

| 항목 | 동작 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|---|
| 조합 중 (preedit) inline 표시 | cursor 위치에 보라색 배경 + 글자 | `WM_IME_*` 가로채기 + `ImmGetCompositionStringW(GCS_COMPSTR)` → preedit_buf → cell overlay (#164 v0.4.0) | `g_preedit_buf` + cell `renderFrame` 의 preedit 영역 | `zwp_text_input_v3.preedit_string` event → `preedit_buf` → cell overlay ([7971cfb](https://github.com/ensky0/tildaz/commit/7971cfb), L10-β) | ✅ | ✅ | ✅ |
| 음절 단위 backspace | 자모 / 음절 단위 되돌리기 | (OS IME 자체) | 동일 | (fcitx5 / ibus 자체) | ✅ | ✅ | ✅ |
| 화살표 / 영문 / space → 음절 commit | IME 가 모르는 키 = 음절 자동 확정 | (OS IME 자체) | `interpretKeyEvents` → IME → callback | text-input-v3 의 commit_string + preedit_string done-apply batch ([9215807](https://github.com/ensky0/tildaz/commit/9215807), L10-γ) | ✅ | ✅ | ✅ |
| commit 트리거 | 음절 더 확장 안 되면 자동 | (OS IME 자체) | 동일 | (fcitx5 / ibus 자체) — commit_string event | ✅ | ✅ | ✅ |
| 한자 / kanji / hanzi 후보 popup 위치 | cursor 옆 추적 | `ImmSetCompositionWindow(CFS_POINT, cursor_pixel)` 매 frame (#164 v0.4.0) | `NSTextInputClient.firstRectForCharacterRange` 가 terminal cursor row 기준 rect 반환 (#166 v0.4.3) | `zwp_text_input_v3.set_cursor_rectangle` 매 redraw (L10-γ) | ✅ | ✅ | ✅ |
| 후보 popup 안 nav 키 | IME default 따름 — tildaz client 가 키 매핑 강제 / 통일 안 함 (§0 #2 native 우선). 사용자가 IME 별 설정에서 변경 가능 | Win IME native (MS-IME 한국어 default) | mac IM Kit native (한국어 IME default) | IME default (예: fcitx5-hangul = ↑/↓ page nav + Tab/Shift+Tab candidate, ←/→ 미매핑 → cursor 이동 의도로 popup 닫힘) | ✅ | ✅ | ✅ |
| 한자 변환 트리거 키 (*조합 중* 한글) | 조합 중인 한글에서 한자 후보 popup 을 여는 키. 키 자체는 IME 엔진 소관 — tildaz 는 정의 / 강제하지 않음 (§0 native 우선). *입력 확정된* 한글의 재변환 트리거는 아래 #209 행 참조. | Win IME native — 한자 키 (한국어 키보드; MS-IME default) | Apple 한글 IME — `Option+Return` | IME 엔진 설정 키 (ibus-hangul 은 F9 / 한자 키가 default, fcitx5-hangul 은 설정에서 지정 — IME 버전 따라 다를 수 있음) → IME 자체 후보 popup | ✅ | ✅ | ✅ |
| 입력 확정된 한글의 한자 변환 ([#209](https://github.com/ensky0/tildaz/issues/209)) | committed text 또는 조합 중 한글 → 후보 popup → 확정 시 replacement. 후보창이 떠 있는 동안 원래 한글은 그대로 보이고, 후보 확정 시에만 한글을 지우고 한자를 입력. Esc / 후보 취소 / focus loss 는 원래 한글 유지. 일반 용어로는 "Hanja reconversion" — *재변환* 이지만 *한자 → 한글* 의미가 아니라 *이미 commit 된 글자를 다시 IME 의 변환 대상으로 되돌려 후보 popup 띄우기*. | Win IME native conversion key / candidate popup 경로. app 은 후보 위치를 `ImmSetCompositionWindow` 로 유지 | `NSTextInputClient` API (`selectedRange`, `markedRange`, `attributedSubstringForProposedRange`, `firstRectForCharacterRange`, `insertText:replacementRange:`) 구현. terminal cursor row 는 PTY `backspace + insert`. 그 외 범위는 안전하게 plain insert fallback (#166, #190 v0.4.3) | ❌ **platform 한계** — *조합 중* 한자 후보는 fcitx5 / ibus 자체 popup 으로 동작 (어느 host 든 OK). *입력 확정된* 한글의 한자 변환은 `zwp_text_input_v3` wire protocol 에 *해당 request 자체가 없어* client → IME 트리거 경로 부재. text-input-v4 의 `set_surrounding_text` 활용 가능성은 별 후속 검토 — Linux 첫 릴리즈는 unsupported 로 출시 | ✅ | ✅ | ❌ (platform-limit) |

### 5.1 IME preedit × line-nav 키 매트릭스 (#164 follow-up 6, v0.4.0)

terminal cell 에서 IME 조합 (preedit) 중에 line-nav 키 (Home / End / Ctrl+A / Ctrl+E) 를 누를 때 동작 정의. native textbox / iTerm2 동등.

**원칙:** nav 키와 focus-loss action은 *commit 후 이동/action* — 입력 중 자모를
잃지 않고, 결과 문자가 action보다 먼저 원래 prompt 에 정확히 한 번
들어간다. paste는 preedit commit 뒤 paste payload 순서라 `하` 조합 중 `X`를 붙이면
`하X`다. Ctrl+C만 예외(line abort 의미). Windows와 macOS는 조합 자모까지 discard,
Linux/fcitx5는 자모를 먼저 확정한 뒤 SIGINT(`가^C`) — 어느 쪽이든 줄이 취소돼 실행
안 되므로 무해(표준 터미널과 동일).

Windows adapter는 실제 `imePreeditSlice().len`, 보류된 IME result
상태로 `input_policy.resolve`를 호출한다. commit이면 `ImmNotifyIME(CPS_COMPLETE)`가
nested 발생시킨 `GCS_RESULTSTR`를 `WM_IME_COMPOSITION` 안에서 원래 대상에 동기
전달하고 message를 소비한 뒤 action을 실행한다.
discard면 `CPS_CANCEL` 뒤 ETX를 직접 한 번 보내고 translated `WM_CHAR`를 소비한다.
read-only action보다 result가 먼저 오면 action까지 보류하고 leave 정책에
따라 `ImmSetCompositionStringW(SCS_SETSTR)`로 실제 IMM composition을 복원한다. 이
순서는 shortcut, Ctrl+Shift+V, 우클릭 paste, F1, Alt+Enter, Alt+F4, Ctrl+C에 공통이다
([#313](https://github.com/ensky0/tildaz/issues/313)).

macOS는 `keyDown:` Cmd shortcut, F1 event tap, About/Config/Log/Quit NSMenu
selector, Cmd+Q의 `TildazView.performKeyEquivalent:`,
`applicationShouldTerminate:`가 모두 action 전에 같은
`applyShortcutInputPolicy`를 호출한다. helper가 `macInputState()`를
`input_policy.resolve`에 전달하고 pending을 처리하므로 NSMenu가 `keyDown:`을
우회해도 terminal preedit은 원래 sink에 정확히 한 번 반영된다. 공통
`commitPendingInput`은 상태를 비운 뒤 render를 요청해 NSMenu/종료 확인 창 뒤에도
마지막 preedit frame이 남지 않는다. AppKit이 Command key equivalent를
`keyDown:`보다 먼저 key window의 view hierarchy에 전달하므로, custom
NSTextInputClient인 TildazView가 Cmd+Q의 pending 입력을 먼저 처리한다. terminal
marked-input 첫 event를 main menu가 매칭하지 않는 경로에서는 기존 custom Quit
selector를 기존 macOS main-queue deferral(`dispatch_async_f`)로 다음 turn에 실행해
현재 event dispatch가 끝난 뒤 같은 action을 실행한다
([Apple Cocoa Event Handling Guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingKeyEvents/HandlingKeyEvents.html)).
menu click/hidden window는 custom selector가 같은 순서로 처리한다. 따라서 terminal
marked input에서도 첫 Cmd+Q action이 유실되지 않고, Cancel 복귀 시 IME 후속 commit이
terminal로 중복 전달되지 않는다. `applicationShouldTerminate:`의 재적용과 Quit
Cancel 뒤 재시도는 첫 호출에서 이미 pending 상태가 비워져 모두 no-op이다
([#317](https://github.com/ensky0/tildaz/issues/317)).

| 위치 | 키 | preedit 처리 | 후속 동작 | Mac | Win | Linux |
|---|---|---|---|---|---|---|
| terminal cell | Home / End | preedit → PTY commit | escape sequence 발신 (`\x1b[H` / `\x1b[F`) | ✅ | ✅ | ✅ (`terminalSequenceForKeysym` + IME commit trigger) |
| terminal cell | Ctrl+A / Ctrl+E | preedit → PTY commit | Ctrl char 발신 (0x01 / 0x05, shell readline 처리) | ✅ | ✅ | ✅ — `processKeyEvent` 가 Ctrl+letter (Ctrl+C 제외) + preedit 시 `commitPendingInput` → PTY 자모 송신 + IME session reset. 그 다음 utf8 path 가 Ctrl byte 송신 |
| terminal cell | Ctrl+C | line abort — 자모 discard *시도* 후 SIGINT (IME 의존) | SIGINT (`\x03`) | ✅ (`discardMarkedText` 로 완전 discard) | ✅ | 🟨 fcitx5 가 Ctrl+C 에서 자모 먼저 확정 → `가^C` (취소된 줄에 남아 무해); 완전 discard 아님 |
| terminal cell | Ctrl+L / Ctrl+D 등 | preedit → PTY commit | Ctrl char 발신 | ✅ | ✅ | ✅ |
| terminal cell | Left / Right / Up / Down | (IME 자체 commit 트리거) | escape sequence 발신 | ✅ | ✅ | ✅ (`terminalSequenceForKeysym` + IME commit trigger) |
| terminal cell | action 단축키 / F1 / fullscreen / quit | preedit → 원래 PTY commit | commit 처리 뒤 action | ✅ | ✅ | ✅ |
| terminal cell | paste (`X`) | preedit → 원래 PTY commit | paste payload 전달 (`하X`) | ✅ | ✅ | ✅ |

#### 의사결정 rationale

| 결정 | 이유 |
|---|---|
| **Cmd+Left/Right 미매핑** | mac Terminal.app 도 동일 — terminal-style 앱은 Ctrl+A/E 만 받음. Cmd+Left/Right 는 일반 mac textbox 표준 (NSTextField line begin/end) 이지만 우리 앱은 terminal context 우선. Cmd+Left/Right 누르면 cmd 분기에서 commitPendingInput 후 mainMenu dispatch (key match 없으면 그대로 commit 됨). |
| **nav 키 + preedit = commit (Ctrl+C 외)** | iTerm2 / native textbox 동등. 사용자가 입력 중인 자모 잃지 않음. terminal preedit 은 PTY 로 직송 (셸 readline 이 받음). |
| **Ctrl+C = line abort** | shell 의 SIGINT 가 "현재 입력 라인 버리기". macOS 는 조합 자모까지 discard(`discardMarkedText`). Linux/fcitx5 는 Ctrl+C 에서 자모를 먼저 확정해 `가^C`(자모가 취소된 줄에 남음) — gnome-terminal 등 표준 터미널과 동일하고 줄이 취소되어 무해. 완전 discard 는 IME 가 preedit 을 남겨두는 경우에만(best-effort). |

#### 시도 / 폐기 기록 (2026-05-10 세션)

세션 중 시도한 접근 둘이 폐기됨. 이후 다른 agent/유지보수자가 동일 함정 빠지지 않게 기록.

**1. Paragraph selectors 매핑 (commit 320cd09 → 3212b6f 로 amend 교체)**

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

해결 (당시): `tildazKeyDown` 에 직접 keyCode intercept 추가. Cocoa StandardKeyBinding mechanism 우회. mac virtual keycode (`kVK_Home` = 115, `kVK_End` = 119, `kVK_ANSI_A` = 0, `kVK_ANSI_E` = 14) 직접 검사. 외장 키보드 / fn+Left/Right / Ctrl+A/E 모두 동일 처리.

→ **교훈:** custom NSView 에서 line-nav 키는 StandardKeyBinding 의존 X, 직접 keyCode intercept.

#### 구현 디테일

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

### 5.2 Emoji 입력 (OS emoji picker)

emoji picker 는 **OS 제공 도구를 그대로 쓴다** — tildaz 는 picker UI 를 구현하지 않는다 (세 platform 공통). Linux 에 앱단 대응물이 없는 것은 결함이 아니라 **라우팅할 OS 표준 picker 가 Linux 에 없기 때문** (의도된 platform 차이).

| | Windows | macOS | Linux |
|---|---|---|---|
| OS picker 진입 | `Win+.` — OS 전역 단축키, 앱 코드 불요 | `Ctrl+Cmd+Space` (system shortcut) — 앱은 menu item 으로 라우팅만 ([#130](https://github.com/ensky0/tildaz/issues/130)) | **없음** — OS 표준 picker 부재. DE 부속 도구는 있으나 tildaz 안 직접 입력 경로 아님 (아래 참고) |
| tildaz 안 동작 | ✅ OS 가 focused 앱에 직접 입력 | ✅ cursor 에 anchored 된 popover — focus loss 자동 dismiss / `Esc` 닫힘 / emoji 클릭 즉시 입력 (2026-07-13 macOS 26.5.2 + v0.6.1 실기 시연) | emoji 입력은 paste (`Ctrl+Shift+V` / 우클릭) 또는 `echo` / `printf` 로 |
| 참고 | | 과거 "floating panel + no auto-dismiss" quirk 기록 (2026-05-06, [5b1d8b5](https://github.com/ensky0/tildaz/commit/5b1d8b5) 시점) 은 현재 환경에서 재현 안 됨 — 원인 미확정 (후보: #166/#190 의 NSTextInputClient 표면 확장 또는 macOS 업데이트). Esc dismiss 보강 코드 (`isEmojiPickerOpen()`) 는 무해해서 유지. | *미실측 (DE / 버전 따라 다를 수 있음)*: KDE Plasma `Meta+.` 는 클립보드 복사 방식, GNOME `Ctrl+.` 은 IBus 경유 GTK 앱 전용이라 tildaz (비-GTK Wayland client) 안에서 미동작 |

### 5.3 Dead key 조합 — Linux 는 앱이 Compose 로 한다 ([#494](https://github.com/ensky0/tildaz/issues/494))

dead key (`^` `¨` `´` `` ` `` `~` — 프랑스어 · 독일어 · 스페인어 · 이탈리아어 등 대부분의 유럽 layout) 는 키 하나로 글자가 되지 않고 **다음 키와 조합**된다 (`^`+`e` → `ê`, `^`+space → `^`). 세 platform 이 같은 결과를 내야 하고, 다른 것은 **누가 조합하는가**뿐이다.

| platform | 조합 주체 | 경로 |
|---|---|---|
| macOS | OS — 조합 중 `ˆ` 를 marked text 로 **보여 준다** (2026-08-27 실기: ABC + `Option+i`, `setMarkedText:` → preedit 렌더) | `interpretKeyEvents:` — AppKit 텍스트 입력 시스템이 dead key 상태를 든다 |
| Windows | OS — 조합 중 표시 **없음** (`WM_DEADCHAR` 를 그리는 코드가 없다 — 코드 확정, 실기 미확인) | `TranslateMessage` → `WM_CHAR`. `ToUnicode` 가 상태를 든다 |
| **Linux** | **tildaz** — #530 부터 조합 중 표시도 한다 | libxkbcommon **Compose** (`xkb_compose_state_feed`) — [`xkb.zig`](src/host/linux/xkb.zig) `Keyboard.composeFeed`. #494 전에는 `xkb_state_key_get_utf8` 만 있어 dead key 가 **빈 문자열** = 아무것도 보내지 않았다 |

Linux 만 앱이 keysym → 글자 변환을 스스로 하기 때문이다 (#496 과 같은 뿌리). 규칙:

- **글자가 될 키만 compose 를 거친다.** 단축키 · 다이얼로그 · 메뉴 · scrollback · nav 키 (`terminalSequenceForKeysym`) 는 그 앞에서 끝난다.
- **Ctrl / Alt 가 눌린 키는 거치지 않는다** (GTK 와 같다). `^` 다음 `Ctrl+C` 는 `\x03` 이 그대로 나간다. AltGr (`Mod5`) 은 해당 없음 — AltGr 로 내는 dead key 도 조합된다.
- **IME preedit 이 있으면 IME 가 주인** — compose 를 건너뛴다.
- **활성 pane · 탭이 바뀌면 조합을 버린다** ([#536](https://github.com/ensky0/tildaz/issues/536), 2026-08-29). 조합을 시작한 셸이 아닌 곳에서 확정되면 안 된다 (KDE 실기: `^` 를 띄운 채 옆 pane 을 클릭하니 표시가 따라가 그 셸에 `ê` 가 들어갔다). 규칙은 #530 이 창 포커스 이탈에 정한 것과 같다 — IME 는 commit, dead key 는 버림.
    - **버리는 자리는 handler 안이다** — `leaveShell` (= `commitPendingInput` + `resetCompose`) 을 활성 pane · 탭을 바꾸는 handler (`handleNewTab` · `handleSplit` · `handleCloseTab` · `handleFocusPane` · `handleSwitchTab` · `handleNextTab` · `handlePrevTab` · `focusPaneUnderPointer` · 탭바 클릭) 가 부른다. 진입점 (단축키 · `+` · `×` · 탭바 · `⋯` 메뉴의 새 탭 · 분할 · 닫기) 마다 부르면 하나가 빠지기 때문이다 — 첫 수정이 `⋯` 메뉴와 단일 탭 컨트롤 스트립의 `×` 를 실제로 놓쳤다.
    - **키보드도 같은 결과다.** `processKeyEvent` 의 `defer` 가 compose 를 거치지 않은 키마다 이미 버리므로 (위 · 아래 규칙), 마우스와 갈리지 않는다. 그래서 *바뀌지 않는* 경우까지 대칭이다 — 이미 활성인 탭을 클릭해도 (`Alt+1` 을 그 탭에서 누른 것과 같이) 버리고, 새 탭이 32 개 한도에 걸려 dialog 로 되돌아가도 (`Ctrl+Shift+T` 와 같이) 버린다.
    - **활성 pane 안을 클릭하는 것은 해당 없다** — 셸이 그대로다 (`focusPaneUnderPointer` 가 같은 pane 이면 `false` 로 빠진다). 커서를 놓으려는 평범한 터미널 클릭이 조합을 깨지 않는다.
    - **자식 셸이 스스로 끝나서 활성 pane 이 바뀌는 경우 (`drainExitedTabs`) 는 이 규칙 밖이다 — 확인 필요.** 사용자 동작이 아니라 PTY 종료가 원인이고, 그 자리에서는 IME preedit 을 *확정* 하는 것이 옳은지부터 갈린다 (확정 대상 셸이 이미 죽었다). 조합 중에 활성 pane 의 셸이 스스로 끝나면 조합이 형제 pane 으로 따라갈 수 있다 — 미검증.
    - **macOS · Windows 는 해당 없음** — 조합 주체가 OS 라 앱이 들고 있는 상태가 없다 (`grep -c compose` = 0).
- **compose 를 거치지 않은 키가 끼면 조합을 버린다** (`composeReset`). `^` → Enter → `e` 는 `\r` `e` 다. modifier 키 자체 (Shift 를 누르는 것) 는 libxkbcommon 이 IGNORED 로 받아 상태를 지킨다 — `^` → Shift+`e` → `Ê`.
- 상태별 동작: `NOTHING` → 기존 utf8 경로 · `COMPOSING` → 아무것도 안 보냄 · `COMPOSED` → 결과 바이트 · `CANCELLED` (`^` 다음 `x`) → **둘 다 버림**. X11 · xterm 관례다 — GTK 만 `^x` 를 내는데 Compose 표 밖의 별도 규칙이라 채택하지 않았다.
- key repeat 은 press 와 같은 경로라 `^` 를 누르고 있으면 `<dead_circumflex><dead_circumflex>` → `^` 가 두 번마다 하나 — X 앱과 같다.
- **locale** 은 `LC_ALL` → `LC_CTYPE` → `LANG` (libxkbcommon 규약). 그 표가 없으면 `en_US.UTF-8` 로 한 번 더 시도한다 — X11 `compose.dir` 이 거의 모든 UTF-8 locale 을 그 파일로 보낸다. libxkbcommon 1.12+ 의 자체 fallback 은 C 라이브러리가 아는 locale 에만 적용된다 (실측 1.13.1: 미설치 `xx_XX.UTF-8` 은 `XKB-679` 에러 + `NULL` — 우리 재시도가 있어야 조합이 살았다). 둘 다 없으면 (Compose 파일 미설치 — Debian 계열 `libx11-data`) 로그 한 줄 (`compose table unavailable`) 을 남기고 종전처럼 동작한다. 사용자 `~/.XCompose` · `$XDG_CONFIG_HOME/XCompose` 도 libxkbcommon 이 읽는다.
- Compose 심볼 8 개는 **optional** (`ComposeApi`, all-or-nothing) — 없으면 조합만 꺼지고 키보드는 그대로다.
- **조합 중인 dead key 를 커서 자리에 보여 준다** ([#530](https://github.com/ensky0/tildaz/issues/530)) — IME preedit 과 같은 강조 (보라색 배경 + 글자) 로, 문자는 **GTK 표** (`gtkimcontextsimple.c` `append_dead_key`: `^` `´` `` ` `` `¨` `~` `¯` `˘` `˚` `˝` `ˇ` `¸` `˛` …) 를 따른다 — 같은 데스크톱의 GTK · Qt 앱과 같아야 하므로 macOS 의 `ˆ` (U+02C6) 대신 platform native 를 택했다. GTK 가 결합 문자로 근사하는 항목 (`abovedot` · `belowdot` · `horn` · `stroke` …) 과 `Multi_key` 는 표시하지 않는다 (조합은 된다 — 결합 문자는 셀에 그려지지 않는다). dead key 가 이어지면 덧붙인다 (`^´`). 조합을 버리는 모든 지점 (compose 를 거치지 않은 키 · `CANCELLED` · 키보드 focus 이탈 · **활성 pane · 탭 전환** (#536) · IME preedit 도착) 에서 함께 지우고, 결과가 나오면 (`COMPOSED`) 지운 뒤 보낸다. IME preedit 이 있으면 IME 표시가 우선이다. 저장소는 IME `preedit_text` 와 **분리** — 그쪽은 `commitPendingInput` 이 PTY 로 보내고 `input_policy` 가 판정에 쓰기 때문이다.

검증 상태 (2026-08-26 · 27): lima VM (Ubuntu aarch64 · libxkbcommon 1.13.1 · headless sway · `wtype` keysym 주입 — [`dist/linux/dead-key-compose-check.sh`](dist/linux/dead-key-compose-check.sh)) 통과에 이어, **실기 두 DE 에서 13 케이스 전부 일치** — 노트북 i5-1240P (CachyOS · libxkbcommon 1.13.2), COSMIC (cosmic-comp 1.6.0) 과 KDE Plasma (KWin 6.7.4), 실제 `fr` · `de` layout 에 `/dev/uinput` scancode 주입, 두 DE 가 같은 바이트 ([COSMIC](https://github.com/ensky0/tildaz/issues/494#issuecomment-5427290965) · [KDE](https://github.com/ensky0/tildaz/issues/494#issuecomment-5427566292)). 실기에서 확인된 사실:

- **text-input-v3 IME (fcitx5) 가 떠 있을 때 누가 조합하는지는 입력기에 따라 갈린다** (#494 · #530 실기 [COSMIC](https://github.com/ensky0/tildaz/issues/530#issuecomment-5432460964) · [KDE](https://github.com/ensky0/tildaz/issues/530#issuecomment-5434640115)). fcitx5 의 **키보드 IM** (`keyboard-us` · `keyboard-fr` …) 은 fcitx5 가 자기 Compose 로 조합해 preedit · commit 을 보내므로 위 경계 규칙이 관측되지 않는다 (`^`+`x` 가 `^x`). `hangul` 입력기는 조합 중이던 한글을 확정한 뒤 **키를 앱으로 넘기므로** 앱의 Compose 와 조합 중 표시가 그대로 동작한다 — 한국어 사용자는 대개 이쪽이다. 한글 조합 중에는 IME 가 전부 소유한다 — "IME 가 주인" 규칙 그대로. 검증 결과에는 *조합 주체가 누구였는지* (앱 로그의 `text_input preedit/commit` 줄 수) 를 함께 적어야 한다.
- 대조군 foot 1.27.0 은 `^` 뒤 Enter 를 삼키고 (`65` 만 나옴) `^`+Ctrl+C 를 `ĉ` 로 조합해 **SIGINT 를 삼킨다** — "Ctrl/Alt 제외 · 조합 버림" 두 규칙의 근거가 실기로 재현됐다.
- `ko_KR.UTF-8` 의 Compose 파일은 `en_US.UTF-8` 을 include 하는 한 줄이라 fallback 없이 바로 로드된다.

macOS 의 조합 (과 조합 중 표시) 은 2026-08-27 실기로 확인했다 (위 표). **Windows 는 코드 판정이고 실기 미확인**이다 — OS 가 조합 주체라 코드 리뷰로는 드러나지 않으므로 따로 재야 한다.

조합 중 표시 (#530) 의 검증 (2026-08-27): lima headless sway (software 렌더) 에서 `grim` 캡처의 preedit 배경색 픽셀 151 → 0 과 스크린샷 확인, **COSMIC 1.6.0 실기 (GL 렌더 · 실제 `fr` 자판 · fcitx5 공존 포함) 7 케이스 전부 일치** ([#530 댓글](https://github.com/ensky0/tildaz/issues/530#issuecomment-5432460964)) — `^` 표시 · `e` 로 확정 · Enter / Ctrl+C / 단축키 / 포커스 이탈에서 지움 · `^´` 두 글자 덧붙임 · IME preedit 과 같은 프레임에 겹치지 않음. **KDE Plasma 6.7.4 (KWin · scale 1.6 · GL 렌더) 실기에서도 7 케이스 전부 일치** ([#530 댓글](https://github.com/ensky0/tildaz/issues/530#issuecomment-5434640115)) — 384 px = 151 × 1.6² 로 셀 면적까지 맞는다. KDE 고유 관측 둘, 표시 동작에는 영향이 없었다: KWin 은 등록된 layout 전부를 **한 keymap** 에 담아 준다 (`layouts=[English (US), French]` — COSMIC 은 layout 마다 새 keymap); fcitx5 가 떠 있으면 **layout 제어권이 fcitx5 로 넘어가** 앱은 단일 layout keymap 을 받고 KWin 의 `getLayout` 은 `0` 을 계속 보고하므로 layout 근거로 쓸 수 없다.

---

## 6. 다이얼로그

| 항목 | 동작 정의 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|---|
| 사용자 표시 텍스트 단일 진입점 | 모든 메시지 / format string 한 곳 | `messages.zig` import | 동일 | 동일 (cross-platform module) | ✅ | ✅ | ✅ |
| 다이얼로그 추상화 | `dialog.showInfo / showError / showFatal / showConfirm / promptHotkey / showAboutAlert` | `dialog/windows.zig` (`MessageBoxW` + key capture window + overflow read-only EDIT window) | `dialog/macos.zig` (NSAlert + overflow NSScrollView + NSEvent key capture + osascript fallback) | `dialog/linux.zig` runtime callback infra + `wayland_minimal.zig` 의 별 layer-shell `overlay` surface backend (#203 Phase C step 3) — main 위 modal 그림. 같은 client 의 별 wl_surface 쌍 + buffer + SDF 합성. | ✅ | ✅ | ✅ |
| 본문 overflow 정책 | info/error/fatal/confirm/prompt/About 모두 실제 텍스트의 자연 크기를 먼저 사용하고, 화면을 넘을 때만 본문에 세로 scroll. 제목·button·prompt input/status는 고정 | 짧은 info/error/confirm은 `MessageBoxW`, prompt 본문은 `STATIC`; overflow 때 read-only multiline `EDIT` + OS scrollbar로 전환 | 짧은 본문은 NSAlert `informativeText`; overflow 때 `NSScrollView` + `NSTextView`. prompt는 같은 accessoryView 아래에 key capture/status를 고정 | 공통 `dialog_layout`이 종류와 무관하게 message viewport를 계산. wheel/touchpad·scrollbar drag는 overflow가 있을 때만 활성 | ✅ | ✅ | ✅ |
| About 다이얼로그 | 버전 / exe / pid / config / log 경로를 잘림 없이 표시. 실제 입력 길이만큼 본문을 할당하고 화면 높이를 넘을 때만 세로 scroll ([#314](https://github.com/ensky0/tildaz/issues/314)) | read-only multiline EDIT 전용 modal window. wheel·scrollbar drag·selection·Ctrl+C는 OS control 동작 | NSAlert accessoryView의 NSScrollView + selectable NSTextView. scrollbar 자동 숨김 | Ctrl+Shift+I → `about.showAboutDialog()` → `dialog.showAboutAlert` → layer-shell overlay. 아이콘 + Title + separator + body + OK 버튼. overflow 때 아이콘을 생략하고 wheel/touchpad·scrollbar drag 지원 | ✅ | ✅ | ✅ |
| Config 에러 (잘못된 값) | 실제로 연 config 절대경로를 본문에 정확히 한 번 붙이고 종료 (`showFatal`, [#316](https://github.com/ensky0/tildaz/issues/316)). 짧은 본문은 native 표시를 유지하고 overflow 때만 전체 본문을 세로 scroll | 짧으면 `MessageBoxW`, 화면 또는 4096 UTF-16 변환 상한을 넘으면 read-only multiline EDIT 전용 window | NSApplication을 config load 전에 준비. 짧으면 NSAlert, 화면 높이를 넘으면 NSScrollView + NSTextView | config parse는 Wayland 연결 전이라 동적 본문 전체를 stderr + log에 남기고 exit(1). 연결 후 startup 검증(예: shell)은 `runFatalDialog` layer-shell overlay(GNOME/Cinnamon은 xdg fallback). **런타임 config 에러 경로는 아직 없음** (hot-reload #170 미구현). | ✅ | ✅ | ✅ (연결 후 overlay) / 🟨 (연결 전 stderr) |
| Panic | dialog + `process.exit(1)` | `dialog.showError` + exit(1) | 동일 | **dialog 호출 안 함** — `showPanic` 이 log(`panic`) + `std.debug.defaultPanic` (stderr 에 file:line + backtrace 후 abort). panic 은 renderer/wayland state 가 이미 불안정할 수 있어 overlay 대신 표준 abort 경로 (의도된 차이). | ✅ | ✅ | 🟨 (dialog 없이 log+abort) |
| 확인 다이얼로그 (`showConfirm`) | OK / Cancel 선택 — destructive 작업 confirm (Alt+F4 / 단일·다중 탭 모두). mac `applicationShouldTerminate:` / Win `onQuitRequest` 동등 — count==0 (PTY 자동 종료) 만 skip, 단일·다중 탭 *항상* confirm. | 짧으면 `MessageBoxW MB_OKCANCEL`, overflow면 고정 OK/Cancel + scroll 본문 — `app_controller.onQuitRequest` 가 호출 | 짧으면 NSAlert OK/Cancel, overflow면 고정 button + scroll 본문 — `applicationShouldTerminate:` 가 호출 | `dialog.showConfirm` → host `dialogShowConfirmCb` 의 inner wayland event pump (deferred dismiss + 단일 OK/Cancel 두 버튼 layer-shell overlay). Alt+F4 는 KWin 이 *F4 system shortcut* 으로 가로채고 `closed` event 발송 — `handleEvent` 가 `pending_quit_request=true`, main loop `drainQuitRequest` 가 confirm 호출. Cancel 시 main surface 재생성 (KWin 측 unmap 후 다음 close 이벤트 안 옴 회피, #203 Phase C step 4). | ✅ | ✅ | ✅ |
| Click 정책 (modal) | dialog 떠 있는 동안 *OK 버튼 / Enter / Esc 만* dismiss. 본문 click / 같은 client 의 main click / 다른 app 영역 모두 dismiss X. | native dialog 또는 소유자 window를 disable한 overflow modal loop | OS modal 표준 자체 | dialog overlay surface 의 pointer button + xkb keysym 처리. `last_pointer_enter_surface_id == dialog.surface_id` + OK 버튼 좌표 hit-test → dismiss. overflow scrollbar drag 외 본문 / main click 은 swallow (focus 만 회복). Enter / Esc → dismiss. | ✅ | ✅ | ✅ |
| dismiss 후 focus return | dismiss 후 main 에 keyboard focus 자동 양도 | OS 자체 (modal close 후 caller window 복귀) | OS 자체 | `xdg_activation_v1` 표준 — dismiss 직전 dialog 가 token 발급 → main 에 `activate`. dialog 가 *실제 focus* 일 때만 (focus 가드, KWin protocol error 회피). dismiss 호출은 main loop deferred (inner roundtrip reentrancy 차단). | ✅ | ✅ | ✅ |
| Dialog 위치 | 현재 monitor 중앙 | overflow window와 prompt는 같은 TildaZ process의 foreground window를 owner로 삼고 그 monitor work area 중앙. 다른 process window는 owner로 사용하지 않음 | NSAlert의 OS modal 배치 | layer-shell 경로(KDE Plasma, COSMIC, Hyprland)는 `anchor=0`으로 현재 output 중앙에 두며 main 창의 dock/width margin과 분리 ([#314](https://github.com/ensky0/tildaz/issues/314), KDE Plasma 1.7x 실기). xdg-toplevel fallback(GNOME, Cinnamon, sway [#454](https://github.com/ensky0/tildaz/issues/454))은 Wayland에 절대 위치 지정 API가 없어 compositor의 transient 배치를 따름 (sway 1.12 실기: floating 중앙 배치·Esc dismiss·focus 복귀 확인) | ✅ | ✅ | ✅ (layer-shell) / 🟨 (xdg compositor 배치) |
| Dialog 시각 크기·배치 scale-aware | DPI / fractional scale 환경에서 일관 시각 크기. **떠 있는 동안 배율이 바뀌어도 따라간다** | overflow window는 현재 monitor DPI와 work area 사용, 최대 폭 960 logical pt. 배율이 바뀌면 `WM_DPICHANGED` 에서 폰트 3벌·아이콘을 새 DPI로 다시 만들고 창과 자식을 재배치한다 — 배치 계산이 순수 함수 하나라 생성 경로와 같은 코드를 쓴다 ([#540](https://github.com/ensky0/tildaz/issues/540)) | NSAlert native, overflow accessory 폭은 최대 580pt. AppKit 좌표가 logical point라 backing scale 변환은 OS가 하고 재배치가 필요 없다 | 본문·버튼 15pt, 제목 18pt 고정 logical 크기이며 terminal `font.size_point`와 독립. corner radius / shadow margin / button w/h / icon size도 PT 단위로 scale 변환한다. 떠 있는 동안 `preferred_scale`이 바뀌면 `applyScaleChange`가 dialog 폰트를 새 scale로 다시 만들고 `sendDialogSurfaceLayout`이 물리 viewport 기준으로 배치를 다시 계산해 surface 크기를 재요청한다. 실제 본문 폭과 wrap 후 행 수로 surface를 키우되 basis output에서 16pt씩 여백을 남긴다. 현재 일반 메시지는 640×480 logical viewport에서 1.0x / 1.7x / 2.0x 모두 scroll 없이 표시하고, 더 긴 본문은 종류와 무관하게 overflow viewport를 사용한다 ([#306](https://github.com/ensky0/tildaz/issues/306), [#318](https://github.com/ensky0/tildaz/issues/318)). About은 최대 폭 960 logical pt다 ([#314](https://github.com/ensky0/tildaz/issues/314)). config parse fatal은 Wayland 연결 전 stderr + log fallback이라 overlay 저장/화면 상한을 거치지 않는다 ([#316](https://github.com/ensky0/tildaz/issues/316)). | ✅ | ✅ | ✅ |

---

## 7. config (#118 — 통합 완료)

같은 nested schema, default 만 OS-specific. *Single source of truth* 패턴 — [`src/config.zig`](src/config.zig) 의 `Defaults` struct (Win/Mac 분기, 같은 필드 순서로 나란히) 한 곳에 모든 default 값. 이로부터:

1. **`defaultConfigToml(allocator, shell_resolved)`** 이 runtime `allocPrint` 로 default TOML 을 생성 (shell 은 host 가 runtime 에 결정한 값이라 comptime 생성 불가 — 과거 `DEFAULT_CONFIG_JSON` + `comptimePrint` 에서 전환) — 첫 실행 시 디스크의 `config_0.toml`에 저장 + parse() 의 `validateStructure` 검증 ground truth.
2. **`Config` struct field initializer** 가 참조하는 `default_*` const 모두 같은 `Defaults` 에서 derive — 디스크 default 와 메모리 fallback 자동 sync.

이전엔 default 값이 6+ 곳 (config literal + 별도 const 들 + Config struct hardcoded literal) 에 흩어져 있어 한쪽만 고치면 어긋남 — 시연 중 발견 (#135). 이제 `Defaults` 한 곳만 고치면 양쪽 자동 sync.

### 7.1 번호별 config / process 정책 (#267)

- 활성 설정은 `config_0.toml`, `config_1.toml`, ... 형식만 인식한다. 기존
  `config.json` 도, TOML 전환 전의 `config_N.json` 도 읽기·변환·수정·삭제하지
  않는다 — 디스크에 그대로 남고 읽지 않는다 (#493).
- `config_N.toml` 하나가 worker process 하나, global hotkey 하나, `tildaz_N.log`
  하나를 소유한다. worker는 `--instance N`으로 시작하며 번호별 advisory file lock으로
  중복 실행을 막는다.
- **N 은 0 … 9 (인스턴스 10 개) 이다** (#510). TildaZ 가 **생성하는** config 의 `hotkey`
  기본값은 `F(N+1)` 이라 index 0 → `F1`, 9 → `F10` 이고, 그 표가 `0 … 9` 를 빠짐없이
  덮으므로 "hotkey 없는 instance" 예외가 생기지 않는다. 상한을 넘는 `--instance N` 은 범위를
  안내하고 거절한다. 같은 상한을 `config_N.toml` · `tildaz.instanceN.desktop` 의 이름
  인식에도 적용한다.
- **표가 `F12` 까지 가지 않는 이유는 Windows 다.** modifier 없는 `F12` 는 커널 디버거
  예약이라 `RegisterHotKey` 가 `ERROR_HOTKEY_ALREADY_REGISTERED` 로 거절한다 (실측:
  bare `F1`…`F11` 은 등록되고 `F12` 만 실패, `ctrl+alt+F12` 는 성공). 기본값이 `F12` 로
  떨어지는 index 가 있으면 그 인스턴스는 **생성된 config 로 아예 기동하지 못한다** — 이
  이슈가 없애려던 증상 그대로다. 사용자가 직접 `hotkey = "F12"` 로 적는 것은 여전히
  유효한 표기이며, 실패하면 기동 시점에 안내 후 종료한다 (§2.1).
- 기본 hotkey 가 index 파생인 것은 **새로 만드는 파일에만** 적용된다. 이미 있는
  `config_N.toml` 은 적힌 값 그대로 읽고 `hotkey` 를 고쳐 쓰지 않는다.
- 다음 config 번호는 **비어 있는 가장 낮은 index** 다 (#510). 최고값+1 이 아니라서
  `config_1.toml` 을 지우면 그 번호와 `F2` 가 함께 다시 열리고, 상한이 *누적 생성 횟수*
  가 아니라 *동시 인스턴스 수* 에 걸린다.
- 일반 실행은 config index별 실행 상태를 확인하고 빠진 TildaZ worker를 한 번에 모두
  복구한 뒤 launcher가 종료한다. `config_0.toml`이 없으면 다른 번호의 config 존재
  여부와 무관하게 default/F1으로 먼저 생성한다. 단순 process 수가 아니라
  `config_<N>.toml` ↔ worker N 대응으로 판정한다.
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
- Windows에서 동시에 진행 중인 일반 launcher는 하나의 새-instance 요청으로 병합한다.
  첫 launcher만 config/worker 상태를 확인하고, 모든 worker가 이미 실행 중이면 worker 0의
  Create/Cancel 처리가 끝날 때까지 해당 요청을 소유한다. 그동안 시작된 추가 launcher는
  별도 prompt를 만들지 않는다. 처리가 반환한 **뒤** 시작된 launcher는 시간 간격과 무관하게
  즉시 다음 새-instance 요청으로 처리한다. `--autostart`는 prompt 요청이 아니므로 이 병합
  대상이 아니다.
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
- request endpoint 준비 상태는 별도 transient 파일 `instanceN.endpoint`에
  `v1 <PID> <starting|ready|unavailable>` 형식으로 기록한다. worker는 lock을 획득한
  직후 owner PID보다 먼저 `starting`을 원자적으로 기록한다. launcher는 endpoint PID와
  lock owner PID가 같고 advisory lock도 실제로 살아 있을 때만 `ready`를 인정하므로,
  이전 process의 stale 파일과 PID 재사용은 성공 판정이 될 수 없다.
- 실제 worker 0 새-instance 요청은 endpoint가 `ready`가 될 때까지 유한 시간 기다린 뒤
  한 번만 전송한다. `unavailable` 또는 ready 전 worker 종료는 즉시 구분된 오류로 끝난다.
  ready 지점은 Linux의 socket·Wayland 초기화·첫 tab 또는 hidden-start 준비 완료,
  macOS의 distributed notification observer·window·renderer·첫 tab·display link 준비
  완료, Windows의 HWND·renderer·첫 tab·표시 정책 적용 후 message loop 진입 직전이다.
  최초 launcher는 기존처럼 worker lock/PID까지만 확인하고 반환하므로 endpoint 실패가
  terminal 자체 실행을 막지 않는 graceful-degradation 동작은 유지한다.
- `launcher.lock`은 config 열거, index별 생존 확인, 누락 worker spawn, 새-instance 요청
  결정과 worker 0의 hotkey dialog/config 생성 transaction을 직렬화한다. 누락 worker를
  spawn한 launcher 또는 새 config를 만든 worker 0은 각 worker가 자기 lock을 획득하고
  PID를 기록한 것을 확인한 뒤 launcher lock을 해제한다. 따라서 다음 launcher는
  config 생성/spawn과 worker ownership 사이의 중간 상태를 관찰하지 않는다. Windows의
  일반 launcher는 동기 새-instance IPC 전에 이 lock을 먼저 해제하고, worker 0이 dialog/
  config transaction을 위해 다시 획득한다. launcher가 lock을 쥔 채 worker의 처리를
  기다리는 순환 대기는 허용하지 않는다.

> 방향은 **Zig `Defaults` struct → TOML** 이고 그 반대가 아니다. shell 이 runtime 결정값(`resolveShell`)이라 comptime 생성이 불가능하므로 `comptimePrint` 대신 `defaultConfigToml` 의 runtime `allocPrint` 로 만든다. 파싱은 `sam701/zig-toml` 의 value tree (`toml.Table` / `toml.Value`) 를 쓰고 struct 매핑은 쓰지 않는다 — `validateStructure` 가 default 문서와 user 문서를 같은 표현으로 비교해야 하기 때문이다.

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
| `auto_start` | bool | `true` | LaunchAgent (`~/Library/LaunchAgents/com.tildaz.app.plist`). plist 는 바이너리가 아니라 `/usr/bin/open -a <bundle> --args --autostart` 를 지목한다 — 직접 지목하면 단명 launcher 가 job 본체가 되어 launchd 가 job 을 닫을 때 worker 까지 거둔다 (#442) | XDG autostart (`$XDG_CONFIG_HOME/autostart/tildaz.desktop`, fallback `~/.config`), L11-α | ✅ | ✅ | ✅ |
| `hidden_start` | bool | `false` | 첫 hotkey 까지 윈도우 unmapped | 첫 hotkey toggle 까지 layer-surface 생성 skip (L11-β). 확인된 hotkey 전달 경로 — direct KGlobalAccel(KDE Plasma) 또는 compositor keybind→`--toggle`(COSMIC/Hyprland/sway, `compositorHotkeyEnv`) — 가 있으면 존중하고, 없으면 warning + 즉시 show fallback으로 영구 숨김을 막는다. GNOME/Cinnamon + extension 환경은 항상 `false`로 override — 숨김은 extension이 map 직후 minimize로 처리 (`host/linux_wayland.zig`) | ✅ | ✅ | ✅ |
| `max_scroll_lines` | integer 100..10_000_000 | 10_000 | 10_000 default. ghostty `max_scrollback_lines` 에 **줄 수를 그대로** 넘기고 byte 제한 (`max_scrollback_bytes`) 은 `null` 로 끈다 — 두 제한은 독립 판정이라 켜 두면 10 KB 에서 먼저 잘린다 ([#451](https://github.com/ensky0/tildaz/issues/451)). **정확한 상한이 아니라 heuristic 이다** — ghostty 가 *complete historical page* 단위로만 prune 하고 (`PageList.Limits.exceeded` 주석: *"complete historical pages are the smallest unit that enforcement removes"*), active 영역을 걸친 경계 page 는 통째로 남긴다. 그래서 실제 줄 수는 page 한 장만큼 톱니로 오르내리고, page 한 장보다 작은 값을 주면 **page 한 장이 하한**이 된다. 실측 (Linux, 80x24, #451): 제한 100 → 최대 588 · 500 → 최대 603 · 2000 → 최대 2013. | 동일 | ✅ | ✅ | ✅ |
| `hotkey` | 상세 spec 은 §7.1 (테이블 아래) | `F1` | `F1` | `F1` — `LinuxHotkey.fromString` + desktop별 native backend. KDE Plasma는 direct KGlobalAccel 충돌 owner 진단 + confirm + takeover. 자세한 알고리즘 §7.1 | ✅ | ✅ | ✅ (#207, #244) |

> **glyph fallback chain** (#135, v0.4.1 schema breaking): chain = `font.family` (primary, single string) + `font.glyph_fallback` (array of strings). codepoint 별로 chain 순회 → 글리프 가진 첫 폰트 사용. chain 에 없는 codepoint 는 양쪽 OS 모두 system fallback 이 자동 처리 — Windows DirectWrite `IDWriteFontFallback.MapCharacters`, macOS CoreText `CTFontCreateForString`. 사용자가 별도 폰트를 추가하고 싶으면 `glyph_fallback` 끝에 append.
>
> **명시 font chain 길이 제한** (#185): `font.family` 1개 + `font.glyph_fallback` 최대 7개 = 총 8개가 hard limit 이다. 코드 source of truth 는 `src/font/constants.zig` 의 `MAX_CHAIN = 8` 이며, config parser / Windows DirectWrite backend / macOS CoreText backend 는 이 상수를 공유한다. 이 값은 "primary + common fallback 한글 / 이모지 / 심볼 + 사용자 추가 여유" 를 주면서 font face lifetime / atlas key 안정성을 단순하게 유지하기 위한 고정 상한이다. 상한을 바꾸면 SPEC / CONFIG.md / README 의 chain limit 설명도 같이 갱신한다.
>
> 모든 명시 폰트 (primary + fallback) 가 system 에 register 되어 있어야 함 — 하나라도 없으면 fatal dialog (`font_validate` 의 공통 메시지, chain dump + 미설치 표시 + config 경로). macOS substitute font 회피 위해 `CTFontCopyFamilyName` 으로 *실제 family name* 검증, Windows 는 `DWriteFontCtx.isFontAvailable` 로 검증한다. Linux 는 boot 시 `font_linux.familyInstalledDetail` 로 검증한다 (검증 시점·overlay 는 §7 startup shell 검증과 동일 C2 패턴; [#289](https://github.com/ensky0/tildaz/issues/289) B6, [#305](https://github.com/ensky0/tildaz/issues/305)). **검증과 실제 로드가 같은 해석 함수를 쓴다** (Linux `resolveRequested` · Windows `resolveFamily`) — 둘이 각자 판정하면 검증을 통과하고도 다른 폰트가 조용히 그려질 수 있다 ([#409](https://github.com/ensky0/tildaz/issues/409)). Windows 는 cell 측정 (`measureCell`) 도 같은 함수를 쓴다 — 거기만 따로 판정하면 chain 은 열리는데 측정만 실패해 GDI fallback (이름을 못 찾으면 **조용히 대체하는** 경로) 으로 떨어진다.
>
> 이름 하나를 face 하나로 해석하는 **순서는 세 platform 이 같다.** 이름 비교는 모두 정규화 (소문자 + 공백 · `-` · `_` 제거) 후 exact match 다.
>
> 1. 적은 이름 그대로 **family** 조회 — Linux 는 `FC_FAMILY` 매치 (반환된 primary family 와 alias 항목 중 하나와 맞으면 설치로 인정), Windows 는 `IDWriteFontCollection.FindFamilyName` (컬렉션 exact match, 대소문자 무시). `monospace` / `sans-serif` / `serif` generic family 는 substitution 이 의도이므로 Linux 에서 항상 통과.
> 2. 설치된 family 목록에 정규화가 같은 이름이 있으면 **그 정식 표기로 다시 조회**한다. Linux 는 `FcFontList` (프로세스당 1 회) — fontconfig 의 family 매칭은 `-` 를 유효 문자로 보므로 `NotoSerifKannada-Light` 같은 표기는 1 에서 엉뚱한 폰트로 간다. Windows 는 `IDWriteFontCollection` 열거 + `GetFamilyNames` 로, **로케일별 이름까지 전부** 본다 (`Malgun Gothic` 은 `맑은 고딕` 도 갖고 둘 다 `FindFamilyName` 으로 왕복한다 — 그래서 `맑은고딕` 도 여기서 잡힌다). 이 단계가 곧 붙여쓰기 (`CascadiaCode`) 를 받는 경로이고, PostScript 조회로는 대신할 수 없다 (실측: `GetMatchingFonts(WIN32_FAMILY_NAME, "CascadiaCode")` 도 0 개). Linux 에서 정식 표기가 원문과 같은데도 다른 폰트가 왔으면 시스템 별칭 규칙이 가로챈 것이다 (`Noto Color Emoji` → `Twemoji`) — **시작을 막지 않고** 그 폰트로 띄우며 로그를 남긴다 ([#406](https://github.com/ensky0/tildaz/issues/406)). **Windows 에는 이 별칭 상태가 없다** — `FindFamilyName` 이 시스템 컬렉션 exact match 라 대체가 개입할 여지가 없고, 그래서 `font_validate` 의 `substitute` 가 Windows 에서 `null` 이다.
> 3. family 가 아니면 **PostScript 이름**으로 조회한다. Linux 는 `FC_POSTSCRIPT_NAME` (`NotoSansCJKkr-Regular`), Windows 는 `IDWriteFontSet.GetMatchingFonts` 의 `DWRITE_FONT_PROPERTY_ID_POSTSCRIPT_NAME` (`CascadiaCodeRoman-Bold`). PostScript 이름은 family 가 아니라 **face** 를 가리키므로 bold PostScript 이름은 bold face 로 로드된다 — macOS `CTFontCreateWithName` 과 같은 의미다. **자기검증 필요 여부가 갈린다**: `FcFontMatch` 는 없는 이름에도 최선 폰트를 돌려주므로 Linux 는 반환된 `postscriptname` 을 되짚어 검증하지만, Windows 는 없는 이름에 빈 set 이 와서 (실측) 그 층이 없다. Windows 의 이 경로는 `IDWriteFactory3` 를 요구하고, 못 얻으면 1 · 2 만으로 판정한다 (컬렉션 열거는 DirectWrite 1.0 이라 붙여쓰기는 그래도 받는다).
> 4. 셋 다 아니면 미설치 — fatal.
>
> **PostScript 를 마지막에 두는 순서가 중요하다.** 먼저 보면 family 이면서 동시에 그 폰트의 PostScript 이름이기도 한 경우 (`Noto Color Emoji`) 에 시스템 별칭 규칙을 덮어 버린다 — 별칭은 시스템 관리자·사용자가 명시한 의도라 우리가 뒤집지 않는다 (#406). Windows 에는 별칭이 없어 그 사고가 안 나지만 **순서는 세 platform 이 같게** 둔다.
>
> Linux 는 해석 결과의 `path` 와 함께 **face `index` 도 `FT_New_Face` 로 넘긴다** — `.ttc` / `.otc` 는 한 파일에 face 가 여러 벌이라 index 를 빼면 요청과 다른 face 가 열린다 (`Noto Sans CJK KR` 은 `NotoSansCJK-Regular.ttc` 의 index 1 이고 index 0 은 JP 다; [#428](https://github.com/ensky0/tildaz/issues/428)). 같은 이유로 face 동일성 판정 (chain dedup · styled 변종의 "regular 와 같은 파일" 검사) 도 (path, index) 쌍으로 한다. libfontconfig 자체를 못 여는 환경은 판정 불가로 두고 loader 의 에러 경로에 맡긴다 (미설치 오판 방지). **#428 은 Linux 전용이다** — macOS `CTFontCreateWithName` 과 Windows `FindFamilyName` → `CreateFontFace` 는 face 를 직접 받아, 파일 경로 + index 로 face 를 여는 곳이 Linux 의 FreeType 경로뿐이다.
>
> schema 위반 (`font.family` 가 string 아님 / `font.glyph_fallback` 이 string list 아님) 은 별도 fatal — `font_validate.showFamilyMustBeStringFatal` / `showGlyphFallbackMustBeListFatal`.

> **schema strict 검증** (Windows + macOS 동일, v0.4.1 통일 — #118 후속):
> - 모든 키 (`window.*`, `font.*`, `theme`, `shell`, `hotkey`, `auto_start`, `hidden_start`, `max_scroll_lines`) 가 *required*. 한 개라도 missing 이면 fatal `missing required key "..."` (사용자 의도하는 위치에 적었는데 silently 무시되는 사고 방지). [#483](https://github.com/ensky0/tildaz/issues/483) (2026-08-27) — 새 버전이 키를 더하면 (예: `[keys]` 의 pane 액션) 이전 파일이 여기서 걸리는데, 기본값으로 조용히 채우지 않고 **strict 를 유지**한다. 대신 메시지가 할 일을 알려 준다: 파일을 옮겨 두고 (지우지 말고) 다시 띄워 기본 파일을 새로 만들고, 바꿔 둔 값을 다시 옮겨 적는다. 세 platform 같은 문구 (`messages.config_missing_key_format`).
> - 알 수 없는 키 (오타 / 잘못된 위치) 면 fatal `unknown key "..."`. 예외는 없다 — TOML 은 `#` 주석을 지원하므로 주석 용도의 key 를 인정할 이유가 없다 (JSON 시절의 `_` prefix convention 은 #493 에서 걷어냈다).
> - Type mismatch (예: `width_percent` 에 string) 면 fatal `type mismatch at "..."`. `font.family` / `font.glyph_fallback` 의 type 위반은 더 친절한 별도 메시지 (`font_validate` 의 helper).
> - 위 검증 모두 `validateStructure(user, default, ctx)` 한 함수가 재귀로 처리 — `defaultConfigToml(allocator, shell_resolved)` 결과와 user config 를 비교.

### 7.1 hotkey 상세

**Schema**: `string`. `config_0.toml` 기본값: `"F1"`. 각 config = 해당 worker hotkey의 source of truth (cross-platform parity). Windows는 `RegisterHotKey`, macOS는 `CGEventTap`, Linux는 desktop별 native backend를 쓴다. KDE Plasma는 direct KGlobalAccel D-Bus, GNOME/Cinnamon은 GSettings·Shell extension, COSMIC/Hyprland/sway는 compositor binding→`tildaz --toggle N` Unix socket IPC(#198)다. 미인식 desktop은 자동 fallback을 만들지 않으며 사용자가 `tildaz --toggle N`을 수동 binding할 수 있다.

**잘못된 hotkey 처리**: `Hotkey.fromString` 이 *null* 이면 `dialog.showFatal(config_error_title, config_hotkey_invalid_format)` 후 process exit ([src/config.zig:962-974](src/config.zig#L962-L974), mac/win/linux 동일). 즉 *parse-pass = 등록 가능 보장* 이 아니라 *parse-pass = format 문법 합격*. Linux native backend 변환 가능 여부는 아래 *Key 토큰 표*를 따른다.

**일반 입력 보호**: modifier 없이 허용하는 global hotkey는 `F1`~`F12`뿐이다. 문자, 숫자, `Space`, `Tab`, `grave` 등은 `Ctrl` / `Alt` / `Super` (`Cmd`) 중 하나 이상이 있어야 한다. `Shift` 단독 조합도 대문자·기호·`Shift+Tab` 같은 일상 입력을 가로채므로 거부한다. 이 검증은 dialog capture와 config parser 양쪽에 공통 적용된다.

**예제** (모든 platform 동일 문법):

```toml
hotkey = "F1"                   # 기본
hotkey = "ctrl+space"           # 흔한 toggle
hotkey = "ctrl+shift+t"         # ✅ KDE 테스트 통과
hotkey = "alt+f12"              # ✅ KDE 테스트 통과
hotkey = "super+a"              # ✅ KDE — plasmashell next activity 충돌 → takeover dialog
hotkey = "ctrl+f7"              # ✅ KDE — kwin ExposeClass 충돌 → takeover dialog
hotkey = "shift+cmd+t"          # mac 친숙 표기 (`cmd` = `super` = `meta` 모두 동일 키)
hotkey = "ctrl+f9"              # punctuation 대신 함수 키 — 어느 자판에서나 같은 키다
```

> **전역 핫키에 punctuation 을 권하지 않는다** ([#496](https://github.com/ensky0/tildaz/issues/496)).
> 위 예제에 punctuation 이 하나도 없는 것은 의도다 — 예전에는 `ctrl+grave` 가 있었는데, 그 조합이
> 자판마다 **다르게 깨진다**는 것이 두 platform 에서 확인됐다.
>
> - **Linux · GNOME** — Mutter 의 `needs_secondary_layout()` 은 `a`–`z` 만 보고 라틴 fallback
>   여부를 정하는데, **라틴이지만 US 가 아닌 layout** 에는 그 문자가 아예 없을 수 있다 — `de` 에는
>   `grave` keysym 이 없다. 그러면 fallback 을 받지 못한 채 바인딩이 keycode 0 개로 해석돼
>   **조용히 죽는다** (`meta_display_grab_accelerator` 가 `ACTION_NONE` 을 낸다). GNOME 자신은
>   같은 문제를 `grave` 대신 위치 토큰 `Above_Tab` 을 써서 피한다.
> - **Windows** — 죽지는 않지만 **다른 키가 걸린다.** `grave` 는 `VK_OEM_3` 이고 그것은 layout
>   DLL 이 배정하는 슬롯이라 자리가 움직인다. 프랑스어 legacy AZERTY 에서 `ctrl+grave` 는 각인
>   `` ` `` 키 (그 자판의 `²`) 가 아니라 **`ù` 키**를 잡는다
>   ([실기 확정](https://github.com/ensky0/tildaz/issues/496#issuecomment-5404000121)).
>
> 어느 자판에서나 안전한 것은 **함수 키** (`F1`~`F12`) 다 — 기본값이 `F1` 인 이유이기도 하다.
> 자리로 고정하고 싶으면 위치 표기를 쓴다 — 전역 `hotkey` 도 받는다 (#496 1-c). 다만
> COSMIC · KDE 는 자리를 못 받아 *그 자리가 지금 layout 에서 내는 글자* 로 등록되므로,
> 그 자리가 dead key 인 layout (독일어의 `[Backquote]`) 에서는 등록되지 않는다.

**Modifier 토큰** (대소문자 무관, `+` 분리, 임의 개수 결합):

| 토큰 | 의미 | 비고 |
|---|---|---|
| `ctrl` / `control` | Control | |
| `shift` | Shift | |
| `alt` / `option` / `opt` | Alt | `option` / `opt` 은 mac 친숙 표기 |
| `cmd` / `command` / `super` / `win` / `meta` / `logo` | Super | 모두 같은 키 — Win key / Super / Cmd / KDE Meta / Qt Logo. 어떤 표기든 받음 |

**Key 토큰** (대소문자 무관). 세 OS 가 공통 토크나이저(`config.zig` `parseHotkeyString`, [#294](https://github.com/ensky0/tildaz/issues/294) G1)를 거치므로 수용 범위가 아래 표로 동일하고, OS 별 차이는 key code 매핑(keysym / vkey / kVK)뿐:

| 분류 | 토큰 / 글자 | Linux native backend 변환 |
|---|---|---|
| Function key | `f1` ~ `f12` | ✅ |
| Latin letter | `a` ~ `z` (또는 `A` ~ `Z`) | ✅ |
| Digit | `0` ~ `9` | ✅ |
| Named special | `space`, `tab`, `escape` / `esc`, `return` / `enter` | ✅ |
| Page key | `pageup` / `pgup`, `pagedown` / `pgdn` | ✅ — 어느 layout 에나 있는 단일 물리 키 ([#482](https://github.com/ensky0/tildaz/issues/482)) |
| Bracket | `bracketleft` / `[`, `bracketright` / `]` | ✅ — `[keys]` 의 `prev_tab` / `next_tab` 기본값이 쓴다 ([#493](https://github.com/ensky0/tildaz/issues/493)) |
| Backtick | `grave` / `backquote` (이름) 또는 `` ` `` (글자) | ✅ |
| 기타 literal ASCII symbol | `~` `!` `@` `#` `$` `%` `^` `&` `*` `(` `)` `-` `_` `=` `+` `{` `}` `;` `:` `'` `"` `,` `.` `<` `>` `/` `?` `\` `|` | ❌ — `LinuxHotkey.fromString`이 명시 reject(#208). caller가 `dialog.showFatal(config_error_title, config_hotkey_invalid_format)`로 즉시 알린다. 수용 범위 확대는 모든 native backend의 실제 key-code mapping 검증 후 별도 진행한다. |

**KDE Plasma direct KGlobalAccel** (`kglobalaccel.Client`, #244):

1. instance별 action ID `[tildaz.instanceN, toggle-N, TildaZ_N, Toggle TildaZ N]`을
   `doRegister(as)`로 만들거나 기존 persistent action을 재사용한다.
2. `getComponent(s) → o`가 반환한 object path의
   `globalShortcutPressed(s,s,x)`만 구독한다. Repeated/Released는 구독하지 않아
   한 번 누름이 정확히 한 번 toggle된다.
3. `action(qt_key) → as`로 현재 owner를 조회한다. 다른 component가 점유하면
   `dialog.showConfirm`으로 사용자 승인을 받은 뒤 그 action의
   `shortcutKeys(as) → a(ai)`에서 정확히 일치하는 single-key sequence만 제거해
   다른 binding과 multi-key sequence를 보존한다.
4. config key를 `setShortcutKeys(as, a(ai), flags=SetPresent|NoAutoloading)`로
   적용한다. KDE의 QKeySequence D-Bus wire shape는 sequence마다 int 4개이므로
   single key도 반드시 `[key, 0, 0, 0]`으로 직렬화한다
   ([공식 serializer](https://github.com/KDE/kglobalaccel/blob/master/src/kglobalshortcutinfo_dbus.cpp)).
5. method 반환 sequence와 `action(qt_key)` owner가 모두 우리 identity인지
   검증한 뒤에만 등록 성공으로 판정한다. config가 source of truth다.
6. `org.kde.kglobalaccel`의 `NameOwnerChanged`에서 owner 재등장을 감지하면
   D-Bus filter 밖 main loop에서 같은 등록·검증 순서를 다시 실행한다. 정상 종료는
   auto-start를 끈 `setInactive(as)` 뒤 match/filter를 해제한다.

공식 계약:
[KGlobalAccel root D-Bus interface](https://github.com/KDE/kglobalaccel/blob/master/src/org.kde.KGlobalAccel.xml),
[Component D-Bus interface](https://github.com/KDE/kglobalaccel/blob/master/src/org.kde.kglobalaccel.Component.xml).

**sway — `bindsym` 자동 등록** (`sway_ipc.registerToggleIfSway`, #207):
`SWAYSOCK` 존재(또는 `XDG_CURRENT_DESKTOP=sway`) 시 `$SWAYSOCK`의 i3-ipc
`RUN_COMMAND`로 `bindsym --no-warn <accel> exec "<self_exe>" --toggle N`을
자동 등록한다(`swaymsg` subprocess가 아닌 직접 socket). hotkey 실동작은 번호별
single-instance socket이다. sway IPC에는 runtime binding 열거 request가 없으므로
외부 binding 충돌은 조회하지 않고, Create가 통과한 TildaZ hotkey가 같은
accelerator의 일반 binding을 의도적으로 덮어쓴다
([sway IPC request 목록](https://github.com/swaywm/sway/blob/master/sway/sway-ipc.7.scd),
[`bindsym --no-warn`](https://man.archlinux.org/man/sway.5.en)). `bindsym`은
runtime-only라 매 worker 실행 시 등록한다. config 삭제/변경 전에 등록된 stale
binding은 같은 accelerator를 재사용하면 새 TildaZ command로 덮이고, 재사용하지
않으면 sway 세션 재시작 때 사라진다.

**Wayland hotkey capture inhibitor**: Linux prompt surface가 focus를 가진 동안 compositor가 `zwp_keyboard_shortcuts_inhibit_manager_v1`을 client에게 노출하면 `zwp_keyboard_shortcuts_inhibitor_v1`을 생성한다. 따라서 기존 compositor binding이 있는 F-key도 prompt가 직접 받는다. Create / Cancel / Esc / surface 종료 시 inhibitor를 surface보다 먼저 파괴해 일반 shortcut routing을 즉시 복구한다. protocol을 노출하지 않는 compositor는 기존 입력 경로를 유지한다. sway에서 `--inhibited`로 등록한 특수 binding은 compositor 정책상 예외로 계속 실행될 수 있다([Wayland protocol](https://wayland.app/protocols/keyboard-shortcuts-inhibit-unstable-v1), [sway inhibitor 동작](https://man.archlinux.org/man/sway.5.en)).

**Hyprland — runtime binding 증분 동기화**: launcher lock 안에서 `hyprctl -j binds` JSON actual 과 `config_N.toml` desired 를 비교한다. accelerator와 현재 TildaZ 실행 파일의 `--toggle N` command가 모두 같은 binding은 유지하고, TildaZ가 소유한 stale binding만 `unbind`, 누락 binding만 `bind`한다. 따라서 config 삭제나 hotkey 변경 뒤 과거 F3/F4 등이 세션에 남아 prompt 입력을 가로채지 않는다. 다른 실행 파일이나 dispatcher의 사용자 binding은 식별 대상이 아니다.

**KDE Plasma / GNOME / Cinnamon — persistent binding 증분 정리**: launcher는 KDE Plasma에서 KGlobalAccel `allComponents()`와 Component `uniqueName`을 조회해 config에서 사라진 `tildaz.instanceN`의 `toggle-N`만 `unregister`한다([KGlobalAccel D-Bus interface](https://github.com/KDE/kglobalaccel/blob/master/src/org.kde.KGlobalAccel.xml), [Component interface](https://github.com/KDE/kglobalaccel/blob/master/src/org.kde.kglobalaccel.Component.xml)). GNOME/Cinnamon의 GSettings fallback도 custom keybinding 목록에서 TildaZ numbered entry만 식별해 사라진 번호를 제거하며 사용자 항목은 보존한다. GNOME/Cinnamon Shell extension은 config directory monitor로 변경을 받고 동일 index/accelerator는 유지한다.

**Display 표기 (사용자 dialog / log)**: `hotkey_format.displayString`이 Title case + `+` 분리(`Meta+A`, `Ctrl+Shift+T`, `Ctrl+F7`)로 표시한다. backend wire 형식과 분리된 사용자용 표기다.

**KDE wire 제약**:
- action ID는 `[componentUnique, actionUnique, componentFriendly, actionFriendly]` 4-string array다.
- `setShortcutKeys`와 `shortcutKeys`의 각 `(ai)` QKeySequence는 항상 int 4개다. single key의 나머지 세 slot은 0이다.
- 정상 종료에는 `unregister`가 아니라 `setInactive(as)`를 사용한다. `unregister`는 persistent action 자체를 제거하므로 config에서 사라진 numbered identity 정리에만 쓴다.

### 7.2 셸 시작 디렉토리 ([#265](https://github.com/ensky0/tildaz/issues/265), [#366](https://github.com/ensky0/tildaz/issues/366) 2026-08-03 개정)

새 탭은 **활성 탭 셸의 현재 위치에서 시작**한다. 그 위치를 알 수 없거나 그리로 들어갈 수 없으면 **홈 디렉토리**로 열화한다 (#265 의 기존 동작). config 옵션은 두지 않는다 — 상속이 항상 기본이고, 홈으로 가려면 새 탭에서 `cd ~` 한 번이면 된다 (반대 방향은 경로를 입력해야 하므로 복구 비용이 비대칭이다).

> **이전 사양의 "항상 홈에서 시작" 은 폐기됐다.** #265 는 시작 디렉토리를 *지정하지 않으면* 자식 셸이 부모 (앱) 의 현재 디렉토리를 물려받아 실행 경로 (Finder / 런처 / 개발 중 셸) 에 따라 위치가 달라지는 문제를 홈 고정으로 막았다. 그 문제 자체는 여전히 유효해서, 상속할 위치가 없을 때의 fallback 이 **앱의 cwd 가 아니라 홈**이라는 점은 그대로 유지한다.

**위치를 얻는 순서** — 세 단계로 내려간다.

| 순위 | 소스 | 특징 |
|---|---|---|
| ① | 셸이 보낸 **OSC 7** (`report_pwd`) | 셸의 논리 경로 (`$PWD`) 라 symlink 를 따라 들어간 사용자의 기대에 맞는다. `Terminal.pwd` 에 raw payload 로 보관되고 스킴 해석은 우리 몫이다 ([`src/pwd_uri.zig`](src/pwd_uri.zig)) |
| ② | **프로세스 cwd 조회** | 셸 · rc 구성과 무관하게 동작한다. Linux · macOS 만 ([`src/process_cwd.zig`](src/process_cwd.zig)) |
| ③ | 홈 | #265 의 동작 |

**platform 별 처리** — 얻는 쪽과 쓰는 쪽이 다르다.

| platform / 탭 | 위치를 얻는 방법 | 새 탭에 넘기는 방법 | 상태 |
|---|---|---|---|
| Linux | `readlink /proc/<셸 pid>/cwd` (셸이 OSC 7 을 보내면 그쪽 우선) | fork 자식에서 `execve` 전 `chdir` — 실패하면 홈으로 되돌린다 | ✅ |
| macOS | `proc_pidinfo(PROC_PIDVNODEPATHINFO)` (동일) | 동일 — 공통 [`terminal/posix/pty.zig`](src/terminal/posix/pty.zig) 의 `childExec` | ✅ |
| Windows — 일반 exe (`cmd.exe` / PowerShell 등) | **OSC 7 뿐.** 프로세스 cwd 조회가 원리적으로 불가해서 셸에 주입한다 (아래) | `CreateProcessW` 의 `lpCurrentDirectory`. 그 디렉토리가 없으면 `CreateProcessW` 자체가 실패하므로 **홈으로 한 번 재시도**한다 (아니면 새 탭이 아예 안 열린다) | ✅ |
| Windows — 셸이 `wsl` / `wsl.exe` | OSC 7 (WSL 안 셸이 보고하는 **Linux 경로**) | 명령줄에 `--cd "<경로>"` 삽입 → wsl 에게 위임. 없으면 `--cd ~` (Linux 홈). Windows Terminal 의 `MangleStartingDirectoryForWSL` 과 동일 규칙 ([microsoft/terminal PR #9223](https://github.com/microsoft/terminal/pull/9223)) — 사용자가 이미 `--cd` 나 단독 `~` 인자를 넣었으면 삽입하지 않는다 | ✅ |

> Windows 에서 Linux 홈을 `lpCurrentDirectory` 로 지정할 수 없는 이유 (Windows 경로만 표현 가능 + Linux 홈 위치는 distro 안에서만 알 수 있음) 와 `\\wsl$\...` 대안이 기각된 근거는 [#265 코멘트](https://github.com/ensky0/tildaz/issues/265#issuecomment-4910677101) 참조.

**경로 표기는 host OS 가 아니라 탭의 셸로 결정한다.** WSL 탭은 host 가 Windows 여도 Linux 경로 (`/home/me`) 를 주고받는다. 그래서 일반 Windows 탭에서 `wsl` 을 직접 실행한 경우처럼 표기가 어긋나면 파서가 거부하고 홈에서 시작한다 (Windows 실기 확인).

**Windows 는 셸에 OSC 7 을 주입한다** — 프로세스 cwd 조회가 불가하기 때문이다. PowerShell 은 `Set-Location` 이 runspace 별 위치만 바꿔서 프로세스 cwd 가 시작값에 고정되고, `cmd` 만 되는 PEB 읽기는 MS 가 *"may be altered or unavailable in future versions"* 로 표기한 비공개 API 다. 조립은 [`src/shell_integration.zig`](src/shell_integration.zig) 가 한다.

| 셸 | 주입 | 사용자 환경 보존 |
|---|---|---|
| `cmd` | `PROMPT` 환경변수 | 기존 `%PROMPT%` **앞에만** 덧붙여 프롬프트 모양을 유지한다. 값이 없으면 cmd 기본값 `$P$G` 를 명시해 이어 붙인다 |
| PowerShell · pwsh | 명령줄 맨 끝에 `-NoExit -EncodedCommand` (UTF-16LE Base64) | **프로필 로드 뒤** 기존 `prompt` 를 감싼다. 사용자가 이미 `-Command` / `-EncodedCommand` / `-File` 을 지정했으면 주입하지 않는다. `$PWD.Provider.Name -eq 'FileSystem'` 일 때만 보고하므로 `HKLM:` 같은 레지스트리 위치는 알리지 않는다 |
| WSL 안 bash | `WSLENV` 로 `PROMPT_COMMAND` 전달 | 사용자 rc 가 `PROMPT_COMMAND=` 로 **대입**하면 무력화된다 (rc 는 자식이 읽어 우리가 볼 수 없다) |
| WSL 안 fish | 없음 — 기본으로 OSC 7 을 보낸다 | — |

스킴은 `kitty-shell-cwd://` (raw) 를 쓴다. 셸의 프롬프트 기능으로는 퍼센트 인코딩을 할 수 없어서 `file://` 로 보내면 `C:\50%20x` 가 `C:\50 x` 로 잘못 디코딩된다. 경로를 URI 로 바꿔 주는 표준 라이브러리는 없다 — 조립이 셸이 프롬프트를 그리는 시점에 일어나기 때문이다 (VTE 는 이 때문에 `vte-urlencode-cwd` 헬퍼 바이너리를 따로 설치하고, ghostty · kitty 는 인코딩을 피하려고 이 raw 스킴을 만들었다).

**동작하지 않는 조합** — 모두 홈 (또는 아래 tmux 처럼 옛 위치) 으로 열화하고, 탭 자체는 정상적으로 열린다.

| 조합 | 결과 | 이유 |
|---|---|---|
| **tmux 안** | tmux 실행 **직전** 위치 ⚠️ | tmux 가 자체 터미널 에뮬레이터로서 OSC 7 을 흡수한다 (tmux 3.7b 실측). 프로세스 조회도 tmux 서버가 별도 프로세스 트리라 통하지 않는다. ghostty · kitty 도 같은 한계이고, tmux 자신은 `#{pane_current_path}` 로 따로 해결한다 |
| **WSL 안 zsh** | 홈 | `ZDOTDIR` 로 파일을 끼워야 하는데 Windows 쪽에서 VM 안에 파일을 만들어야 한다 |
| **ssh 원격** | 홈 | 원격 hostname 이 우리와 달라 파서가 거부한다. 우리 주입도 ssh 를 넘지 못한다 (ssh 는 기본적으로 환경변수를 전달하지 않는다) |
| 지워진 디렉토리 · 디렉토리가 아닌 경로 | 홈 | spawn 전에 `openDirAbsolute` 로 확인한다 (`access` 는 파일도 통과시켜 spawn 이 `ENOTDIR` 로 실패한다) |

어느 단계에서 걸렸는지는 로그 (`cwd` 카테고리) 에 새 탭 하나당 한 줄로 남는다.

**셸 login 모드 — 각 OS 터미널 관례를 따르는 의도적 차이** (2026-07-12 결정, #282 D5). macOS 는 자식 셸을 **login shell** (`argv = {shell, "-l"}`) 로 띄우고 (Terminal.app / iTerm2 표준 — `~/.zprofile`·`~/.bash_profile` 로드; padding 비대칭 원인이던 non-login + `~/.hushlogin` 문제 해결, 커밋 0572ab8), Linux 는 **비-login** 으로 띄운다 (GNOME Terminal / Konsole 표준 — `~/.zshrc`·`~/.bashrc` 만 로드). 어느 dotfile 이 로드되는지가 platform 간 다르지만, 각 OS 터미널의 관례와 일치시킨 의도된 차이다 (cross-platform 동등성 룰의 명시 예외).

---

## 8. PTY 자식 종료

| 항목 | 동작 정의 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|---|
| 탭 닫기 시 자식 정리 | 즉시 종료 + read thread join | `ClosePseudoConsole(hpc)` 한 호출 | 공통 `Pty.deinit`: `kill(-pid, SIGHUP)` + `wait_thread.join()` + `read_thread.join()` | macOS와 같은 [`terminal/posix/pty.zig`](src/terminal/posix/pty.zig)의 `Pty.deinit` | ✅ | ✅ | ✅ |
| Polling sleep 회피 | join 직접 동기화 | (OS API 자동) | wait_thread blocking `waitpid` 으로 즉시 깨어남 | 동일 (`waitpid` blocking + `child_exited` atomic 으로 grace loop break) | ✅ | ✅ | ✅ |
| SIGHUP 무시 셸 fallback | SIGKILL 강제 | (자동) | 공통 `Pty.deinit`: 500ms grace (5ms polling, `child_exited` atomic) → SIGKILL | macOS와 같은 [`terminal/posix/pty.zig`](src/terminal/posix/pty.zig)의 `Pty.deinit` | ✅ | ✅ | ✅ |

---

## 9. 터미널 환경변수 (자식 셸에 전달)

`AGENTS.md # 터미널 환경변수` 와 동일. 우리 코드 자체엔 사용 X — 모두 자식 셸 / vim / less 같은 TUI 가 보는 변수.

**정책:** 부모 environ을 map으로 복사한 뒤 `extra_env`를 `put`해 같은 이름을 덮어쓴다. 즉 명시한 변수는 실행 방식과 무관하게 **우리 값 우선**, 그 외 부모 변수는 그대로 보존한다. Linux · macOS 공통 구현과 override 단위 테스트는 [`terminal/posix/pty.zig`](src/terminal/posix/pty.zig)의 `Pty.init`에 있다 (#118).

| 환경변수 | 역할 | 우리 명시값 | Win | Mac | Linux |
|---|---|---|---|---|---|
| `TERM` | escape sequence + 256-color capability | `xterm-256color` (Windows ConPTY 자체 default 있음, Linux · macOS 명시) | (PTY default) | ✅ | ✅ ([`Client.extra_env_storage`](src/host/linux/wayland_minimal.zig), 5-entry storage) |
| `LANG` | bash readline multi-byte 처리 | `en_US.UTF-8` (안 하면 한글 byte raw 처리, echo 안 됨) | (PTY default) | ✅ | ✅ — `C.UTF-8` (L13-α [ed73eda](https://github.com/ensky0/tildaz/commit/ed73eda), 한글 IME 회귀 fix) |
| `LC_CTYPE` | locale, 일부 셸이 `LANG` 안 봄 | `en_US.UTF-8` | (PTY default) | ✅ | ✅ — `C.UTF-8` 동일 |
| `COLORFGBG` | vim / less / tmux 자동 dark/light colorscheme (구식 TUI 용 통로) | `themes.isDark(theme)` → `15;0` (dark) / `0;15` (light) — *theme 으로 강제*. **spawn 시 1회 스냅샷** — env 는 이미 뜬 프로세스에 갱신 불가 (환경변수 본질 한계) | ✅ | ✅ | ✅ ([`Client.extra_env_storage`](src/host/linux/wayland_minimal.zig)) |
| `SHELL` | spawn한 POSIX 셸 경로 (`echo $SHELL`, prompt/tool 감지) | 실제 spawn에 사용한 셸 path | — | ✅ | ✅ |
| `WSLENV` | WSL 안 process 에 `COLORFGBG` 전달 | `COLORFGBG` 추가 | ✅ | — | — (WSL Linux-host 무관) |

**override 범위:** Linux · macOS는 표의 `TERM` / `LANG` / `LC_CTYPE` / `COLORFGBG` / `SHELL` 다섯 이름을 명시해 부모의 같은 이름보다 우선한다. Windows는 ConPTY와 WSL 관례에 따라 `COLORFGBG` / `WSLENV`만 명시한다. 표에 없는 부모 환경변수는 그대로 전달한다.

**dark/light 판별 통로는 두 겹** ([#266](https://github.com/ensky0/tildaz/issues/266)): `COLORFGBG` 는 질의를 안 보내는 구식 TUI 용 spawn 스냅샷이고, 질의를 보내는 앱 (fish 4 / neovim / 최신 vim) 은 §9.1 의 OSC 11 · DSR `?996n` 응답으로 *현재* 배경색 (OSC 로 런타임 변경 반영, ssh 너머 동작) 을 받는다. 두 통로의 판별 공식은 [`themes.isDarkRgb`](src/themes.zig) 하나로 공유 — 서로 어긋날 수 없음.

### 9.1 터미널 질의 응답 ([#266](https://github.com/ensky0/tildaz/issues/266))

앱이 터미널에게 보내는 질의 (응답을 PTY 로 되돌려야 하는 시퀀스) 의 응답 사양. 파싱과 응답 생성은 ghostty-vt 가 담당하고, [`session_core.zig`](src/session_core.zig) 의 Tab.init 이 `vtHandler().effects` 에 콜백을 연결한다 (응답 송신은 `write_pty` → `tab.queueWrite`).

**macOS · Linux 만 배선 — Windows 는 의도적으로 readonly 유지.** ConPTY 구조에서는 자식 앱의 질의에 conhost 가 터미널 역할로 직접 응답하므로 (아래 표의 동작을 conhost 가 제공) 우리 응답의 수신자가 없다. 오히려 conhost 자신의 DA1 질의는 spawn 직후 pre-response ([terminal/windows/pty.zig](src/terminal/windows/pty.zig)) 로 이미 답을 받은 상태라, 파서가 두 번째 응답을 보내면 conhost 가 소비하지 않고 자식 입력으로 흘려보내 cmd 프롬프트에 `62;22c` 가 찍히는 leak 이 실기에서 확인됐다 (#266 Windows 시연).

> **Windows 한계 — 기본색 질의 (OSC 10/11) 는 ConPTY 전체의 platform 한계** (#266 W8 로 확정). conhost 는 headless 에서 기본 fg/bg 를 모르며 (`INVALID_COLOR` 초기화, [RenderSettings 생성자](https://github.com/microsoft/terminal/blob/main/src/renderer/base/RenderSettings.cpp)), 모르는 색 질의는 **응답도 호스트 전달도 없이 소멸**시키고 ([RequestXtermColorResource](https://github.com/microsoft/terminal/blob/main/src/terminal/adapter/adaptDispatch.cpp) — `INVALID_COLOR` 면 응답 생략, else 분기 없음), 밖에서 conhost 에 색을 알려줄 통로도 없다. Windows 에 응답을 배선해도 질의가 우리에게 도달하지 않음을 실기로 확인 (실험 [288e266](https://github.com/ensky0/tildaz/commit/288e266282b4a120e62c71181ffb3e6009adf3a1) → 판정 후 revert). **Microsoft 의 Windows Terminal 도 동일하게 무응답** (실기 확인). 즉 WSL 앱의 theme 자동 감지 (`fish_terminal_color_theme` 등) 가 Windows 에서 빈 값인 것은 정상이며, 이 용도는 spawn 시 넘기는 `COLORFGBG` (§9) 가 담당한다.

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
| **config** | `%APPDATA%\tildaz\config_N.toml` (Microsoft 표준) | `$XDG_CONFIG_HOME/tildaz/config_N.toml` (fallback `~/.config`; ghostty/alacritty 패턴) | `$XDG_CONFIG_HOME/tildaz/config_N.toml` (fallback `~/.config`) |
| **log** | `%APPDATA%\tildaz\tildaz_N.log` (Microsoft 표준) | `~/Library/Logs/tildaz_N.log` (Apple HIG — Console.app 자동 인덱싱) | `$XDG_STATE_HOME/tildaz/tildaz_N.log` (fallback `~/.local/state`) |
| **process / endpoint state** | `%LOCALAPPDATA%\tildaz\run\launcher.lock`, `instanceN.lock`, `instanceN.endpoint` | `~/Library/Caches/TildaZ/launcher.lock`, `instanceN.lock`, `instanceN.endpoint` | `$XDG_RUNTIME_DIR/tildaz/launcher.lock`, `instanceN.lock`, `instanceN.endpoint`; `XDG_RUNTIME_DIR`가 없으면 `${XDG_CACHE_HOME:-~/.cache}/tildaz/run/` |

파일이 없으면 첫 실행 시 default 가 자동 생성된다.

Linux · macOS config는 유효한 절대 `XDG_CONFIG_HOME`을 우선하고, Linux log는
유효한 절대 `XDG_STATE_HOME`을 우선한다. unset/empty/relative 값은 위 표의
기본 경로로 fallback한다. Linux user autostart도 같은 config base의
`autostart/tildaz.desktop`을 사용한다. custom XDG를 처음 적용할 때는 사용자
config/log를 복사·이동하지 않으며, 구버전이 기본 위치에 만든 TildaZ autostart
entry만 중복 실행 방지를 위해 정리한다 ([XDG Base Directory](https://specifications.freedesktop.org/basedir/), [Desktop Application Autostart](https://specifications.freedesktop.org/autostart/0.5/)).

로그 경로는 worker index가 정해진 뒤 처음 사용할 때 실제 길이만큼 동적으로
준비해 process lifetime 동안 하나의 값으로 보관한다. 로그 기록, About의 `log`
표시, Open Log가 이 동일한 값을 사용하므로 서로 다른 파일을 가리킬 수 없다.
앱 자체의 고정 경로 버퍼 상한은 두지 않으며, Windows 기록은 prefixed NT path와
`FILE_APPEND_DATA`를 함께 사용해 장경로에서도 원자 append를 유지한다. 경로 준비가
실패하면 조용히 생략하지 않고 stderr에 한 번 이유를 남긴다 ([#314](https://github.com/ensky0/tildaz/issues/314)).

process lock과 endpoint 상태는 config가 아니라 transient runtime/cache state다.
`launcher.lock`, `instanceN.lock`, `instanceN.endpoint`는 실행 뒤 파일 자체가 남을 수
있으며, 존재 여부는 실행 상태를 뜻하지 않는다. `instanceN.lock`의 PID는 process 검색을
돕는 진단값이고 실제 생존 여부는 advisory lock으로만 판정한다. endpoint 상태는 같은
lock owner PID와 advisory lock 생존이 함께 확인될 때만 유효하다.

**stdout / stderr 정책**: 통합 로그가 single source of truth — stdout/stderr 에는 정보성 메시지 안 찍음. 모든 정보 (boot, startup, font/renderer init, tab create, geom, perm, pty, exit) 는 통합 로그로. ghostty-vt 의 `std.log` 호출 (예: `unimplemented mode: ...`) 도 `main.zig` 의 `std_options.logFn` 으로 redirect — 단 `unimplemented mode` noise 는 filter (xterm DECSET 중 ghostty 가 안 구현한 것들, terminal 동작 영향 없음). 권한 안내처럼 첫 부팅 사용자 actionable 인 것은 `dialog.showInfo` 로 messagebox 표시. (예외: macOS IMK system framework 의 stderr noise `IMKCFRunLoopWakeUpReliable` — system framework 가 우리 우회 없이 직접 찍는 것이라 차단 불가, 무시.)

### 11.2 Open Config / Log 단축키 (default editor 열기)

| 동작 | Windows | macOS | Linux | Win | Mac | Linux |
|---|---|---|---|---|---|---|
| Config 열기 | Ctrl+Shift+P | Shift+Cmd+P | Ctrl+Shift+P — 현재 worker의 `paths.configPath` + `system_open.openInDefaultApp` (xdg-open) | ✅ | ✅ | ✅ |
| Log 열기 | Ctrl+Shift+L | Shift+Cmd+L | Ctrl+Shift+L — 현재 worker의 `log.filePath` + `system_open.openInDefaultApp` | ✅ | ✅ | ✅ |

> Windows 의 `dump_perf` (스냅샷) 단축키는 Ctrl+Shift+P 와 충돌해 Ctrl+Shift+F12 로 이동 (개발자 dev 도구 컨벤션, F12).

`dump_perf`의 구간별 성능 계측은 system sleep/hibernate를 제외한 working-state
elapsed time을 사용한다. Linux는 `CLOCK_MONOTONIC`, macOS는 `CLOCK_UPTIME_RAW`,
Windows는 `QueryUnbiasedInterruptTimePrecise`를 사용하고 `src/perf.zig`에서 모두
nanosecond로 수렴한다. 이 정책은 PTY read·ring push/drain·parse·render·present·
onrender 진단 수치에만 적용한다. instance timeout이나 Linux startup/show처럼 기능
동작의 실제 경과 시간을 재는 `std.time.Timer`는 기존 의미를 유지한다
([Linux clock_gettime](https://www.man7.org/linux/man-pages/man2/clock_gettime.2.html),
[Apple uptime clock](https://developer.apple.com/documentation/driverkit/kiotimerclockuptimeraw),
[Windows unbiased interrupt time](https://learn.microsoft.com/en-us/windows/win32/api/realtimeapiset/nf-realtimeapiset-queryunbiasedinterrupttimeprecise)).

**메커니즘:**
- Windows: `ShellExecuteW(NULL, "open", path, ...)` — 사용자 default editor (`.toml` / `.log` 의 file association). **연결이 없으면 `notepad.exe` 로 연다** ([#456](https://github.com/ensky0/tildaz/issues/456)). 확장자에 기본 앱이 없으면 Windows 는 아무 것도 열지 않으면서 `ShellExecuteW` 는 성공을 반환해서 (실측: 연결 있는 `.log` 과 연결 없는 `.json` 이 **둘 다 42**, 창은 한쪽만 뜸 — config 가 JSON 이던 시절의 측정이고, `.toml` 도 연결 없는 확장자라 상황은 같다) 호출 결과로는 성패를 알 수 없다. 그래서 열기 **전에** 연결을 조회한다 — `UserChoice` → `HKCR\<ext>` 기본값 → 그 ProgId 의 `shell\open\command` 순. `AssocQueryString` 계열은 `OpenWithProgids` 후보까지 답해서 이 판정에 쓸 수 없다. 확실히 없을 때만 fallback 하고, 조회가 불확실하면 OS 에 맡긴다.
- macOS: `/usr/bin/open <path>` 를 자식 process 로 — Finder 가 file extension 따라 default app.
- Linux: `xdg-open <path>` 를 자식 process 로 — XDG MIME database.

**자식 process 회수 (macOS · Linux)** — spawn 한 자식은 **그 pid 를 지목한 thread 가 `waitpid` 로
거둔다** ([#457](https://github.com/ensky0/tildaz/issues/457)). 안 거두면 `[xdg-open] <defunct>` 가
worker 수명 동안 상한 없이 쌓인다. 거둘 때 `SIGCHLD = SIG_IGN` 이나 `waitpid(-1)` 를 쓰지 않는
이유는 §7 의 PTY 자식 관리와 충돌하기 때문이다 — 그 둘은 `processWaitLoop` 의
`waitpid(child_pid, ...)` 를 자식이 죽기도 전에 `ECHILD` 로 반환시켜, 탭이 열리자마자 닫히고
[#129](https://github.com/ensky0/tildaz/issues/129) 의 SIGHUP grace · SIGKILL fallback 이 무력화된다.
Windows 는 `ShellExecuteW` 라 우리가 자식을 만들지 않아 이 문제가 없다.

### 11.3 About 다이얼로그 — 경로 표시 (모두 절대 경로) + Tip 라인

기존 About 텍스트 (TildaZ vX.Y.Z / exe / pid) 에 config / log 경로 + 그 경로를 빨리 여는 단축키 Tip 추가. **`~` 같은 단축 안 쓰고 절대 경로** — 사용자가 그대로 복사해서 vim / ls 명령에 paste 가능 + `~` 가 환경에 따라 다른 위치라 ambiguity 제거.

**body 구조는 세 platform 동일** (`messages.about_format`). Tip 라인의 단축키 *토큰* 만 platform native다. Linux는 `Ctrl+Shift+P/L`, macOS는 `Shift+Cmd+P/L`, Windows는 `Ctrl+Shift+P/L` — SPEC §0 #2 의 platform 표준 우선 원칙.

**About 본문 복사는 세 platform 이 공통으로 제공해야 하는 동작이 아니다** (2026-07-12 결정, #282 C3). **Linux overlay dialog 는 복사를 제공하지 않는다 (의도).** macOS는 accessoryView selection auto-copy (#128), Windows는 read-only EDIT의 selection/Ctrl+C로 복사한다. About 이 보여주는 config/log 경로는 Open Config (`Ctrl+Shift+P`) / Open Log (`Ctrl+Shift+L`) 단축키로 직접 열 수 있어 복사의 실용 가치가 대체되기 때문이다.

```
TildaZ v0.3.0

exe   : /Applications/TildaZ.app/Contents/MacOS/tildaz   (mac)
        C:\Users\<u>\...\tildaz.exe                       (win)
pid   : 12345
config: /Users/<u>/.config/tildaz/config_0.toml            (mac)
        C:\Users\<u>\AppData\Roaming\tildaz\config_0.toml   (win)
log   : /Users/<u>/Library/Logs/tildaz_0.log               (mac)
        C:\Users\<u>\AppData\Roaming\tildaz\tildaz_0.log    (win)

Tip: Shift+Cmd+P opens config in default editor.       (mac)
     Shift+Cmd+L opens log.
     Ctrl+Shift+P opens config in default editor.       (win)
     Ctrl+Shift+L opens log.

https://github.com/ensky0/tildaz
```

env var expansion (`~`, `%APPDATA%`) 안 쓰고 펼친 절대 경로. 사용자가 단축키 까먹어도 Shift+Cmd+I / Ctrl+Shift+I 로 About → 경로 확인 → Tip 의 단축키로 editor 직행.

**텍스트 selection / copy — body 는 같지만 dialog 메커니즘은 platform native** (각 OS control의 자체 copy 흐름 따름):

- **Windows**: read-only multiline EDIT — 필요한 본문 범위를 선택해 `Ctrl+C`. 또는 Tip 의 `Ctrl+Shift+P/L` 로 editor를 바로 연다.
- **macOS**: `NSAlert.accessoryView` 의 `NSTextView` (selectable / monospace) 로 본문 표시 + selection 변경 시 자동 clipboard copy (NSTextView delegate 의 `textViewDidChangeSelection:`) — 우리 터미널 selection finish auto-copy (#122) 와 같은 패턴. NSAlert modal 안에서 NSTextView 가 firstResponder 를 안정적으로 못 잡아 `Cmd+C` 의 `copy:` 액션이 OK 버튼 쪽으로 라우팅되는 macOS quirk (AGENTS.md macOS Cocoa quirks #4) 우회.

### 11.4 config error 시 dialog 경로 안내

잘못된 config 값 발견 시 `dialog.showFatal` 본문에 *실제로 연 config 파일 절대경로*를 정확히 한 번 명시해 사용자가 어디를 고쳐야 할지 즉시 알게 한다 ([#316](https://github.com/ensky0/tildaz/issues/316)). `Config.load`가 연 path를 `Config.parse`에 직접 전달하고, TOML parse와 모든 semantic/schema 오류가 동적 message 조립을 사용한다. TOML parse 실패는 파서가 준 줄·열까지 함께 보인다. path 조회를 다시 수행하지 않으므로 instance 번호와 실제 파일이 갈리지 않는다.

**경로는 첫 줄이고 형식이 하나다** ([#495](https://github.com/ensky0/tildaz/issues/495)).

```
Config: /home/user/.config/tildaz/config_0.toml

Configuration: missing required key "window" in (top-level).
```

예전에는 두 형식이 있었고 경로 위치가 오류 종류에 따라 달랐다 — 파싱 오류는 본문 셋째 줄 (`Path: {s}`), 의미 오류는 맨 끝 (`Config path:\n  {s}`). 의미 오류가 대부분인데 그쪽이 맨 끝이라, 읽는 순서상 *오류를 읽고 → 고쳐야겠다 판단하고 → 다이얼로그를 닫은 뒤* 경로가 필요해졌다. 위쪽 문구가 명확할수록 (`missing required key "window"`) 더 빨리 닫으므로 더 잘 놓쳤다. 사용자가 실제로 겪었다 (2026-08-22).

조립 지점은 **`configErrorMessageAlloc` 한 곳**이다. 형식이 갈라진 원인이 파싱 오류만 그 함수를 지나지 않고 `dialog.showFatal` 을 직접 부른 것이었으므로, 그 경로도 `showConfigFatalMsg` 를 지나게 했다. 파싱 오류 본문은 경로를 담지 않는다 — 담으면 두 번 나온다.

`allocPrint` 실패 시 fallback 도 **경로 자리를 비우지 않는다** (`Config: (unknown)`). 예전 파싱 쪽 fallback 은 경로를 아예 잃어서, 정작 가장 도움이 필요한 상황에서 가장 적은 정보를 줬다.

### 11.5 config 를 읽지 못하거나 만들지 못했을 때 ([#501](https://github.com/ensky0/tildaz/issues/501))

**fatal 이 아니다 — 안내하고 기본값으로 계속 돈다.** 내용이 틀린 config (§11.4) 와 정책이 다르며, 그 차이가 의도적이다.

| 상황 | 결과 상태 | 한 문장으로 설명되는가 | 정책 |
|---|---|---|---|
| 파일이 없거나 못 읽음 / 못 만듦 | **전부** 기본값 | ✅ "설정을 하나도 읽지 못했다" | 안내 + 계속 |
| 파일은 읽혔는데 내용이 틀림 | **부분** 적용 | ❌ 어느 필드가 살고 어느 필드가 죽었나 | fatal (§11.4) |

시작을 거부하면 **사용자가 스스로 잠긴다** — config 를 고치려면 편집기가 필요하고 편집기를 띄우려면 터미널이 필요한데, tildaz 가 그 터미널이면 벗어날 방법이 없다. 원인이 사용자 잘못이 아닐 수도 있다 (권한 · 디스크 오류 · 홈이 읽기 전용인 컨테이너). 반면 내용이 틀린 경우는 부분 적용이 되어 "테마는 먹었는데 핫키는 안 먹은" 상태를 설명할 수 없으므로 fatal 이 정직하다.

**안내는 창이 뜬 뒤에 한 번 나온다.** config 로드 시점에 띄우지 않는 이유는 Linux 다 — 그때는 Wayland backend 가 없어 다이얼로그가 stderr · log 로만 가고 (`dialog/linux.zig`), 데스크톱 아이콘이나 autostart 로 띄운 사용자에게는 보이지 않는다. Windows (`MessageBoxW`) 와 macOS (`osascript display dialog`) 는 그 시점에도 보이지만, 그쪽만 즉시로 두면 세 platform 의 시점이 갈리고 안내가 두 번 뜰 수 있어 한 곳으로 모았다.

| host | 호출 지점 |
|---|---|
| Linux | 이벤트 loop 의 `drainConfigNotice` — 다른 다이얼로그가 떠 있으면 다음 iteration 으로 **미룬다** (버리지 않는다) |
| Windows | `window.init` 직후 |
| macOS | `NSWindow` 생성 직후 |

안내 문안은 **"그래서 지금 어떤 상태인가" 를 반드시 말한다.** 오류만 알려 주고 결과를 빼면 사용자는 자기 설정이 적용됐는지 모른 채 쓰게 되고, 그것은 이 이슈가 고치려는 증상 (조용한 기본값 동작) 과 사실상 같다. 형식은 §11.4 와 같다 — 경로가 첫 줄이다.

측정 인스턴스는 예외다 ([#382](https://github.com/ensky0/tildaz/issues/382)) — **일부러** 사용자 config 를 만들지 않으므로 안내도 없다.

Windows는 짧은 본문을 기존 `MessageBoxW`로 표시하고 화면 또는 4096 UTF-16 변환 상한을 넘을 때만 read-only multiline EDIT window로 전환한다. macOS는 NSApplication을 config load 전에 준비해 짧은 본문은 기존 NSAlert, overflow 본문은 NSScrollView/NSTextView로 표시한다. Linux config parse는 Wayland 연결 전에 실행되므로 전체 동적 본문을 stderr + log fallback으로 출력한다. **현재 상태: 구현·자동 검증 완료, Linux · macOS · Windows 묶음 실기 대기 (#316).**

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

### 12.3 SGR 선 속성 — 밑줄 · 취소선 · 윗줄 ([#365](https://github.com/ensky0/tildaz/issues/365))

셀에 그리는 선 계열 SGR. 정책은 공통 모듈 [`src/renderer/cell_decoration.zig`](src/renderer/cell_decoration.zig) 한 곳에 있고 세 renderer 는 그 결과를 자기 사각형 목록에 넣기만 한다 (`block_element` · `cell_color` 와 같은 패턴).

| SGR | 속성 | 상태 |
|---|---|---|
| `4` / `24` | `underline` single / reset | ✅ 세 platform |
| `21` | `underline` double | ✅ 세 platform |
| `9` / `29` | `strikethrough` / reset | ✅ 세 platform |
| `53` / `55` | `overline` / reset | ✅ 세 platform |
| `58` / `59` | `underline_color` / reset | ✅ 세 platform |
| `8` / `28` | `invisible` / reset | ✅ 세 platform |
| `4:4` / `4:5` | `dotted` / `dashed` | ✅ 세 platform ([#374](https://github.com/ensky0/tildaz/issues/374)) |
| `4:3` | `curly` | ✅ 세 platform ([#374](https://github.com/ensky0/tildaz/issues/374)) |
| `3` / `1` | `italic` / `bold` 굵기 | ✅ 세 platform (§12.5) |
| `5` / `25` | `blink` | ⛔ [#376](https://github.com/ensky0/tildaz/issues/376) — 지원 여부 미결정 |

**그리는 순서 = 글리프 *아래*.** 선을 글리프보다 먼저 그린다. `underline_color` 로 밑줄이 글자와 다른 색일 때 descender (`g` `y` `p` `j` `q`) 를 가로지르지 않게 하기 위해서다 (ghostty 와 같은 선택). 구현 위치가 platform 마다 다르지만 결과 순서는 같다 — Linux 는 `FrameLayer.cell_bg` (목록 2번, `glyphs` 3번보다 앞), macOS · Windows 는 **bg pass** 다. text pass 의 `bg_buf` 에 넣으면 글리프 *위*로 올라가 정반대가 되므로 주의.

**위치와 두께는 `ascent` 비율 공통 상수** ([`src/ui_metrics.zig`](src/ui_metrics.zig)). 기준점은 세 renderer 공통인 **baseline = 셀 top + `ascent_px`** 다.

| 항목 | 정의 |
|---|---|
| 두께 | `max(1, round(0.06 × ascent))` — 정수 px (위치 소수부와 무관하게 두께 보존, [#357](https://github.com/ensky0/tildaz/issues/357) 과 같은 이유) |
| 밑줄 top | baseline + `round(0.07 × ascent)` |
| 이중 밑줄 | 단일 밑줄 자리를 **비우고** 위아래로 두께만큼 (전체 3×두께) |
| 취소선 **중심** | baseline − `0.30 × ascent` (정석 `x_height / 2` 의 근사) |
| 윗줄 top | 셀 top (0) |
| 점선 (`4:4`) · 파선 (`4:5`) | **같은 경로.** 조각 수를 정하고 **정수 pitch** 로 배치한다 (조각 폭 = `pitch / 2`, 즉 칠한 폭 = 빈 폭). 조각 크기만 다르다 — 점선 `2 × 두께` (정사각형 dot), 파선 **셀 폭** (셀당 1 조각) |
| 물결 (`4:3`) | **raised cosine** `(1 − cos(2π·p)) / 2`, 진폭 `파장 × 0.18`. **셀 경계가 산 · 중앙이 골**. 픽셀 열마다 coverage 로 AA (열당 최대 3 조각) |

**점선·파선은 셀 경계 위상을 맞추지 않는다.** 셀마다 **정수 개**를 균등 배치하고, 셀 폭이 모두 같으므로 이웃 셀과 자연히 같은 리듬이 된다. 절대 x 좌표를 위상에 넣는 처리는 필요 없다.

**wide char 는 base 셀의 배치를 `span` 번 되풀이한다.** 조각 수·`pitch`·조각 폭을 base 셀 하나로 구하고, 그 배치를 `k × base 셀 폭` 오프셋으로 반복한다. 그래서 조각 수가 **정확히 2 배**이고 **리듬도 narrow 와 같다** — 한글 구간과 ASCII 구간이 같아 보인다. 물결이 `cycles = span` 으로 산을 span 개 넣는 것과 같은 원리다.

셀 전체를 한 번에 나누면 안 된다. 두 가지가 깨진다.

- `round(셀폭 / 구간)` 을 그대로 쓰면 반올림 때문에 2 배가 깨진다 (구간 8 일 때 narrow 19 → 2 지만 wide 38 → 5).
- 세는 단계에서 `span` 을 곱해 개수만 맞춰도, 아래 「셀 끝에 닿는 조각 버림」이 `span` 을 모르는 채 셀당 한 번만 일어나 **홀수 폭에서 밀도가 갈린다** — narrow 는 5 중 1 (20%), wide 는 10 중 1 (10%) 을 버린다.

**조각 수 상한도 `span` 으로 나누지 않는다** (상한은 base 셀당). 나누면 wide 만 조각이 줄어 같은 밀도 붕괴가 된다.

**균등 배치가 되기까지 세 번 고쳤다** (2026-08-03 실기, 사용자 지적).

- 점선은 dot 중심을 각각 반올림해서 간격이 `4·4·3·4` 로 흔들렸다.
- 파선은 ghostty 식 (`dash = floor(셀폭/3) + 1` 을 `0` · `2×dash` 에 배치) 을 그대로 옮겼는데, 셀 끝에서 잘린 조각이 **다음 셀 조각과 맞붙어** `7 · 12 · 12 …` 로 얼룩덜룩했다.
- 파선 구간을 `4 × 두께` 로 두니 15pt 셀(19px)에 2 개가 들어가 글자 한 칸에 "칠·빔·칠·빔" 이 반복돼 과밀했다 → **셀 폭 기준(셀당 1 조각)** 으로 바꿨다.
- 점선을 wide 셀 전체에 한 번에 배치하니 **홀수 폭에서 한글 구간만 촘촘**했다 (`cell_w 9` 에서 narrow 4 / wide 9, 기대 8 — 2026-08-03 Linux GL 실기 [#365](https://github.com/ensky0/tildaz/issues/365)) → **base 셀 배치를 `span` 번 되풀이**하도록 바꿨다.

**pitch 를 정수로 고정하는 이유.** 조각 경계를 각각 `@round(slot × i)` 로 구하면 `slot = 셀폭 / 조각수` 가 정수가 아닐 때 조각마다 1px 씩 흔들린다. 셀 폭에 따라 **폭 또는 간격** 한쪽으로 나타난다 (2026-08-03 Windows 실기에서 발견, macOS 픽셀 실측으로 확인).

| 폰트 · 셀 | slot | 고치기 전 증상 |
|---|---|---|
| Cascadia Code 15pt (`cell_w 9`, `t 1`) | 1.8 | 폭 `1,1,2,1` — 두 조각이 인접해 붙음 |
| Menlo 15pt @2x (`cell_w 19`, `t 2`) | 3.8 | 간격 `2,2,1,2` |
| Lucida Console 15pt (`cell_w 10`) | 2.0 | 균일 (정수라서) |

**마지막 조각이 셀 끝에 닿으면 버린다.** 넘는 것을 잘라 넣으면 폭이 다시 불균일해지고, 딱 닿게 두면 다음 셀의 첫 조각과 맞붙어 같은 증상이 되돌아온다 (`cell_w 9` · `pitch 2` 는 다섯째 조각이 정확히 `[8,9)` 로 닿는다). 그 결과 **셀 안의 간격은 완전히 균일**하고 **셀 경계 간격만** 잔여 여백만큼 다르다 (Menlo 15pt@2x 실측: 셀 안 `2,2,2,2` · 경계 `1`).

셀 폭이 홀수면 "폭도 간격도 셀 경계까지 완전 균일" 한 배치가 **존재하지 않는다** — 지금 구현은 셀 안을 균일하게 지키고 오차를 경계 한 곳에 모은 것이다.

**물결은 곡선이라 유일하게 anti-alias 가 걸린다.** 픽셀 열마다 곡선이 걸치는 세로 구간을 coverage 로 내고, 호출부가 [`box_drawing`](src/box_drawing.zig) 과 똑같이 `ui_metrics.blendOverRgb` 로 셀 배경과 **미리 합성**해 알파 1.0 solid 로 그린다 (#353 — 합성은 공통 모듈이 한 번만). 셰이더의 `shade` 채널은 쓰지 않는다: 그쪽은 절대 픽셀의 격자 패턴만 계산하도록 만들어져 있어 곡선을 넣으려면 셰이더 네 곳 (Metal · HLSL · Linux CPU · Linux GL) 에 정점 구조와 varying 까지 손대야 하는데, `discard` 이진 마스크라 **AA 가 아예 안 된다**.

**파형 세 가지가 실기 비교로 정해졌다** (2026-08-03, macOS 에서 ghostty · kitty · Alacritty 를 같은 폰트 · 크기로 나란히 띄워 비교).

- **raised cosine** — `sin(π·p)` 는 사인파의 0~π 볼록만 잘라 붙인 꼴이라 양 끝 기울기가 최대다. 골이 뾰족한 `V` 가 되어 "위로만 볼록한 게 붙어 있는" 모양으로 보였다. `(1 − cos(2π·p)) / 2` 는 `p = 0 · 0.5 · 1` 세 곳 모두 접선이 수평이라 이웃 셀과 만나는 지점이 둥근 골이 된다 (ghostty 가 베지어 제어점을 시작·끝점과 같은 y 에 둬서 얻는 모양과 같다).
- **셀 경계가 산, 중앙이 골** — 반대로 두면 밑줄 자리에서 *올라가며* 시작해 불안정해 보인다. Alacritty 처럼 baseline 에 가까운 높이에서 시작해 중앙으로 처지는 쪽이 글자와의 거리가 일정하게 느껴진다.
- **진폭 `파장 × 0.18`** — ghostty 공식인 `파장 / π` (0.318) 로 만들었더니 넷 중 가장 출렁였다. 0.26 (Alacritty 수준) → 0.22 → 0.15 (너무 평평) 를 거쳐 0.18 로 정했다. 0.26 과 0.22 는 15pt 에서 1px 미만 차이라 체감되지 않았다.

폰트 metric 을 쓰지 않는 이유: 밑줄 position/thickness 는 세 폰트 API 가 모두 주지만 **취소선과 x_height 는 Linux (FreeType) 와 macOS (CoreText) 에 없어** OS/2 테이블을 직접 읽어야 한다. 폰트값을 쓰면 *밑줄은 폰트값 · 취소선은 상수* 로 갈리고 API 별 단위 변환 차이로 platform 간 1px 이 어긋난다.

**선 색.** 밑줄은 `underline_color` (SGR 58) 가 있으면 그 색, 없으면 `fg`. 취소선과 윗줄은 `underline_color` 를 보지 않고 항상 `fg`. 여기서 `fg` 는 [`cell_color.resolveFg`](src/renderer/cell_color.zig) 의 결과라 selection / inverse 교환이 이미 반영돼 있다.

**`invisible` (SGR 8) 은 선까지 전부 숨긴다.** 글리프뿐 아니라 block element · box drawing · 선을 모두 그리지 않는다. xterm · ghostty 와 같은 정책이고, Alacritty 처럼 "텍스트만 숨기고 선은 남기는" 방식과 갈리는 지점이다 (2026-08-03 결정).

**선은 텍스트가 없는 셀에도 그린다** — `\e[4m` 뒤의 공백에 밑줄이 이어져야 하기 때문이다. 반대로 한 번도 쓰지 않은 셀은 `style_id` 가 0 이라 선이 생기지 않는다.

### 12.4 SGR 5 — blink ([#376](https://github.com/ensky0/tildaz/issues/376))

`\e[5m` 을 **지원한다**. 세 platform 동일 주기·동일 위상.

| 항목 | 사양 |
|---|---|
| 주기 | **on 500ms + off 500ms** (1Hz). ECMA-48 의 "slow blink = 분당 150회 미만" 을 만족 |
| off 상태 표현 | **faint (흐리게)** — 완전히 숨기지 않는다 |
| SGR 5 vs 6 (rapid) | **구분하지 않는다** — ghostty 파서가 둘을 `.blink` 하나로 접어서 정보를 주지 않는다 |
| 끄는 수단 | **없다** (아래) |
| 위상 계산 | [`ui_metrics.blinkFaintPhase(now_ms)`](src/ui_metrics.zig) — 세 host 가 [`Runtime.nowMs()`](src/runtime.zig) 를 공통으로 넘긴다 ([#451](https://github.com/ensky0/tildaz/issues/451) 에서 `std.time.milliTimestamp` 이 없어졌다). **프레임당 한 번만 부르고 그 값을 renderer 까지 인자로 내린다** — host 와 renderer 가 각각 시계를 읽으면 500ms 경계에서 게이트 판정과 화면이 서로 다른 위상을 볼 수 있다 |

**off 를 faint 로 표현하는 이유.** 글자가 완전히 사라졌다 나타나는 것은 조사한 방식 중 가장 자극적이다. Windows Terminal 도 4-phase 중 2 를 faint 로 렌더하고, WezTerm 은 투명도를 이징한다. 구현도 이쪽이 깔끔하다 — [`cell_color.applyBlinkPhase`](src/renderer/cell_color.zig) 가 off 위상에서 style 의 `faint` 플래그를 세워 돌려주므로, fg 해석뿐 아니라 **§12.3 의 선 색까지 한 번에** 따라온다 (선은 `fg` 를 받아 그리기 때문). 이미 `faint` 인 셀에 blink 가 걸리면 off 위상에서 변화가 없다 — 알려진 귀결이다.

**절전을 깨지 않는 게이트.** 세 host 는 "tick 은 규칙적으로 돌고 게이트가 그릴 이유를 판정" 하는 구조다 (macOS CADisplayLink · Windows `SetTimer` 16ms · Linux poll 16ms). 게이트를 *"화면에 blink 셀이 있다"* 로 열면 매 tick 그려서 [#255](https://github.com/ensky0/tildaz/issues/255) 의 절전 이득이 사라진다. 그래서 **"위상이 직전 프레임과 달라졌다" × "직전 프레임에 blink 셀이 실제로 보였다"** 두 조건을 함께 본다 — 추가 렌더가 **초당 2프레임**이다. renderer 가 bg pass (Linux 는 단일 순회) 에서 `saw_blink_cell` 을 기록하고 host 가 그것을 읽는다.

**끄는 수단을 두지 않는다.** 조사한 터미널은 모두 끌 수 있게 해 두었지만, 우리 config 는 **재시작할 때만 반영**되어 광과민성처럼 *지금 멈춰야 하는* 문제의 답이 되지 못한다. 필요해지면 config 키가 아니라 **command menu 항목 + 단축키** (즉시 반영) 로 넣는다 — 설계는 #376 에 기록해 두었고 구현은 보류다. OS 접근성 설정 존중은 Linux 에 표준이 없어 (GNOME GSettings / KDE 별도 키 / sway · Hyprland 는 개념 자체 없음) 세 platform 동등이 깨진다. 현재 사용자가 쓸 수 있는 수단은 표준 시퀀스다 — `\e[25m` (blink 해제) · `\e[0m` / `reset` / `tput sgr0`.

### 12.5 SGR 1 · 3 — bold 굵기 · italic ([#375](https://github.com/ensky0/tildaz/issues/375))

`\e[1m` 은 실제 굵은 face, `\e[3m` 은 실제 기울어진 face 로 그린다. 세 platform 동일.

| 항목 | 사양 |
|---|---|
| face 선택 | **같은 family 에서 자동 style-match** — 각 OS 폰트 매칭 API 에 위임 |
| config 키 | **없다.** `font.family_bold` 류를 두지 않는다 |
| face 가 없는 family | **regular 로 떨어뜨린다.** synthetic (offset 두 번 그리기 · shear) 은 만들지 않는다 |
| 적용 범위 | **셀 본문 글리프만.** grapheme cluster (emoji) · ligature · IME preedit · 탭 제목 · system fallback 은 regular |
| `bold_is_bright` | 그대로 유지 — 굵기와 색 승격은 독립이다 |

공통 축은 [`font/constants.zig`](src/font/constants.zig) 의 `FaceStyle` (regular / bold / italic / bold_italic) 하나다. renderer 세 곳이 `FaceStyle.from(flags.bold, flags.italic)` 만 부르므로 판정이 platform 별로 갈리지 않는다.

| platform | face 획득 | 없는 family 처리 |
|---|---|---|
| macOS | `CTFontCreateCopyWithSymbolicTraits` | 함수가 **null 을 준다** → 그 결과가 곧 "이 family 에 bold 가 있나" 의 답. regular 를 `CFRetain` 해 소유권을 통일 |
| Windows | `GetFirstMatchingFont` 의 weight / style 인자 | 함수가 **가장 근접한 face** 를 준다 (실패하지 않는다) → 자연히 regular |
| Linux | fontconfig `lookupStyled` (weight / slant) | fontconfig 도 근접 매치 → **regular 와 (파일, index) 가 같으면 `null`** 로 두어 같은 face 를 두 번 열지 않는다 ([#428](https://github.com/ensky0/tildaz/issues/428) — `.ttc` 는 한 파일에 face 가 여러 벌이라 path 만 보면 다른 face 를 같은 것으로 오인한다) |

**Linux · Windows 는 변종 조회에 *해석된 정식 family* 를 쓴다** — 사용자가 적은 원문이 아니다 ([#409](https://github.com/ensky0/tildaz/issues/409)). `font.family` 에 PostScript 이름이나 다른 표기를 적었을 때 원문으로 조회하면 **엉뚱한 폰트의 변종**이 온다: Linux 실측에서 `DejaVuSansMono-Bold` 의 bold 조회가 `NotoSansCJK-Bold.ttc` 로 갔고, `NotoSerifKannada-Light` 는 `NotoSerifCJK-Bold.ttc` 로 갔다. 그래서 Linux 는 `Face.family` 에 §7 의 이름 해석 결과 (정식 family) 를 담고 변종 조회는 그 이름으로 한다.

**Windows 는 그 family 를 face 에서 되찾는다.** PostScript 이름으로 잡은 face 에는 `IDWriteFontFamily` 가 딸려 오지 않아서, `IDWriteFontCollection.GetFontFromFontFace` → `IDWriteFont.GetFontFamily` 로 얻은 family 로 `GetFirstMatchingFont` 을 부른다. 실측에서 `CascadiaCodeRoman-Bold` 를 적으면 regular 자리에 Bold face 가 오면서도 변종은 `Cascadia Code` 안에서 맞게 나온다 (bold `CascadiaCodeRoman-Bold` · italic `Cascadia-Code-Italic`). face 가 시스템 컬렉션에 없어 family 를 못 얻으면 변종을 만들지 않고 regular 로 떨어뜨린다 — 위 표의 "없는 family 처리" 와 같은 결과다.

Windows 는 `MapCharacters` 의 base family 힌트도 이 정식 이름을 쓴다. 그 인자는 *family 이름* 을 받는 자리라, 원문이 `CascadiaCode` 나 `CascadiaCodeRoman` 이면 DirectWrite 가 알아보지 못해 system fallback 선택이 어긋난다.

**Linux 는 변종 chain 을 lazy 로 만든다.** chain 이 최대 8 이라 즉시 로드하면 face 가 32 개가 되고, dialog 폰트를 lazy 로 돌린 것과 같은 이유로 시작이 느려진다 ([#368](https://github.com/ensky0/tildaz/issues/368) — 시작 시간의 절반). 실패해도 "시도했음" 을 기록해 매 프레임 fontconfig 왕복을 막는다.

**Linux 는 atlas 키에 변종을 실어야 한다.** `gl_atlas.Key` 는 codepoint 경로에서 `face` 를 `0xFF` 로 고정해 face 정보가 키에 없다 — 그대로 두면 bold `A` 와 regular `A` 가 같은 칸을 덮어쓴다. codepoint 가 u21 이라 `value` (u32) 의 상위 비트에 변종을 싣는다. `indexed` 경로는 face index 가 이미 키에 있어 영향이 없다. [#362](https://github.com/ensky0/tildaz/issues/362) 의 `cp → 글리프` 캐시도 변종별로 나눈다.

**한글 bold 가 붙는다.** chain 전체 (primary + `glyph_fallback`) 에 변종을 만들기 때문이다 — macOS 실기 비교에서 kitty · Alacritty 와 같고, ghostty 는 한글이 regular 로 남았다 (2026-08-03).

### 12.6 Glyph atlas — 폰트 식별과 용량 초과 ([#584](https://github.com/ensky0/tildaz/issues/584))

한 화면이 요구하는 글리프가 atlas 에 다 안 들어갈 때의 사양이다. 세 platform 이 **같은 계약**을 쓴다 (§0 #1).

| 축 | 사양 |
|---|---|
| ⓿ **폰트 식별** | cluster 캐시 키는 폰트를 **주소가 아니라 안정된 id** 로 식별한다 |
| ① **찼을 때** | **이미 그린 것을 먼저 flush 하고, 비우고, 재시도한다.** 그 프레임의 화면은 온전하다 |
| ② **용량** | `ATLAS_SIZE` 는 **2048**. 산술이 아니라 ③ 의 실측으로 정한다 |
| ③ **로그** | [`log.logAtlasFull`](src/log.zig) 한 문구를 세 platform 이 그대로 쓴다 |

#### ⓿ 폰트 식별 — 주소를 키에 싣지 않는다

glyph index 는 폰트 안에서만 뜻이 있어서 cluster 키에는 폰트 축이 있어야 한다. **그 축에 폰트 객체의 주소를 쓰면 안 된다** — OS 폰트 매칭이 같은 폰트에 객체를 여러 번 새로 만들기 때문이다. 그러면 같은 그림이 주소마다 새로 담겨 atlas 가 부풀고, 넘치면 화면이 무너진다.

| platform | cluster 키의 폰트 축 | 주소가 왜 안 되는가 (실측) |
|---|---|---|
| macOS | `atlas_common.fontId` — **PostScript 이름의 FNV-1a 64bit 해시** | CoreText 가 CTLine 마다 새 객체를 준다. 같은 `Monaco` 가 주소 **50 개** (640 byte 간격 순차 할당). cluster 2,816 종 화면이 항목 5,600 개 = 정확히 2 배를 썼다 |
| Windows | **같은 `atlas_common.fontId`** | DirectWrite system fallback (`tryClusterOnSystemFallback`) 이 `CreateFontFace` 로 매번 새 객체를 만든다. fallback 폰트 6 종 · cluster 7,560 종 화면에서 `MV Boli` 가 한 프로세스 안에서 주소 **2 개**로 나왔다 |
| Linux | 합성 cluster 는 **내용 해시** (`font/linux/font.zig` 의 `composeCluster` — glyph_index · x_offset · y_offset · x_advance 의 Wyhash), 폰트 축은 chain face **index** (`gl_atlas.Key.face`, `u8`) | **애초에 주소가 없다.** 아래 「Linux 가 계약을 지키는 근거는 셋이다」 |

**family 이름이 아니라 PostScript 이름이다.** `Menlo-Bold` 와 `Menlo-Regular` 는 family 가 둘 다 `"Menlo"` 라, family 로 묶으면 굵기가 다른 그림이 한 칸을 나눠 쓴다 — [#529](https://github.com/ensky0/tildaz/issues/529) 가 그것이었다.

**레지스트리가 아니라 해시다.** 이름 → id 표를 두면 상한과 초과 처리가 생긴다. 해시는 상태도 상한도 없고, 키에 `indices_hash` 가 함께 실려 이중이다. 이름을 못 읽으면 `0` 이다 — 이름 없는 폰트끼리 한 id 로 모여 그림이 섞일 수 있지만, 주소를 쓰던 때처럼 atlas 를 부풀리지는 않는다 (둘 중 덜 나쁜 쪽).

**id 는 프로세스가 달라도 같다.** 주소와 갈리는 지점이다 — Windows 실측에서 `MV Boli` 가 세 번의 실행 내내 `0xbaa15b1cca03f6b6` 였다.

**단일 글리프 키 (`atlas_common.GlyphKey`) 도 같은 id 를 쓴다.** 예전에는 여기만 주소를 두고 *"단일 경로는 폰트 층의 codepoint 캐시가 face 를 붙잡아 객체가 재사용된다"* 를 근거로 삼았는데, **그 근거는 Windows 에만 맞았다.**

| platform | 단일 경로의 codepoint 캐시 | 주소를 두면 |
|---|---|---|
| Windows | `glyph_map` 이 **chain 밖 fallback face 를 붙잡는다** | 주소가 안정적이다 |
| macOS | **없다.** chain 밖 글리프는 셀마다 `CTFontCreateForString` 으로 **새 객체**를 받는다 | 같은 글리프가 주소마다 새로 담긴다 |
| Linux | (자체 `Key` 가 face index 를 쓴다 — 해당 없음) | — |

그리고 **cluster 가 글리프 하나로 합성되면 이 키로 온다** (`getOrInsertCluster` 의 `len == 1` 분기). 그 폰트는 cluster 경로의 OS fallback 이라 세 platform 모두 codepoint 캐시를 거치지 않는다.

macOS 실측 — 다국어 화면 (cluster 7,560 종) 에서 이 맵의 서로 다른 폰트 주소가 **256 개를 넘었다** (실제 폰트는 32 종). 그 중복이 atlas 를 부풀려 **프레임마다 차게** 만들고 (`atlas full` 125 회 / 4.3 초), 찰 때마다 그린 것을 지워 화면이 흐르듯 무너졌다. id 로 옮긴 뒤 `atlas full` 0 회 · 업로드 140 → 1 회 · 이웃 프레임 대조 `0 px` 이 됐다.

**아이콘은 예약값을 쓴다** (`atlas_common.ICON_FONT_ID`). 폰트에서 온 글리프가 아니라 id 가 없는데, 주소 자리에 `0` 을 넣던 것을 그대로 두면 **`fontId` 가 이름을 못 읽어 낸 `0`** 과 한 키 공간을 나눠 쓴다.

cluster 경로가 거치는 shape 결과 캐시 (`font/cluster_cache.zig`, `CAPACITY` = 2048) 는 **넘치면 통째로 비워지면서 face 를 놓는다** — 그것이 위 문제의 출발점이다.

**Linux 가 계약을 지키는 근거는 셋이다** (2026-09-02 소스 판정 + 실기). 인덱스라는 것만으로는 부족하다 — 인덱스가 *재사용되면* 같은 키가 다른 폰트를 뜻하게 되고, 캐시가 *비워지면* 같은 그림이 새 키로 담긴다. 셋이 함께여야 위 사슬이 끊긴다.

| # | 근거 | 어디 |
|---|---|---|
| 1 | 합성 cluster 키가 **내용 해시**라 같은 그림이면 항상 같은 키다 | `font/linux/font.zig` 의 `composeCluster` |
| 2 | fallback face index 를 **재사용하지 않는다** — `MAX_FALLBACK` (8) 에 닿으면 퇴출이 아니라 그 자리에서 placeholder + 로그 | 같은 파일의 `loadFallbackForCp` |
| 3 | 합성 비트맵 맵 `composed_glyphs` 에 **상한이 없다.** 폰트를 다시 로드할 때만 비운다 | 같은 파일의 `Context.composed_glyphs` |

3 번이 macOS 를 부풀린 사슬을 끊는다. 그쪽은 *"`cluster_cache` 가 넘쳐 비워지면 face 를 놓고, 다시 shape 하면 CoreText 가 새 객체를 준다"* 였는데, Linux 는 `cluster_cache` 가 비워져도 다시 shape 한 **내용이 같으므로 해시가 같고 곧 같은 키**다. cluster 10,400 종 화면 (`CAPACITY` 의 5 배) 실측에서 face index 가 하나뿐이었고 같은 그림이 두 키로 담긴 흔적이 없었다.

#### ① 찼을 때 — 이미 그린 것을 지킨다

**셀 루프는 셀마다 atlas 에 넣고 그 자리에서 인스턴스를 emit 한 뒤 나중에 그린다.** 그래서 프레임 중간에 atlas 를 비우면 앞서 emit 한 인스턴스의 UV 가 **이제 다른 것이 들어 있는 자리**를 가리킨다. 비우기 전에 flush 하는 것이 이를 막는 유일한 방법이다.

**어긋난 것이 어떻게 보이는지는 비울 때 픽셀을 지우는지에 달렸다.**

| 비울 때 | 앞서 emit 한 글자 | 어느 platform |
|---|---|---|
| 픽셀을 **0 으로 지운다** | **사라진다** (빈 칸) | macOS (`@memset(pixels, 0)`) |
| 커서만 되돌린다 | **다른 글자로 바뀐다** — 그 자리에 새로 올라온 글리프가 보인다 | Linux · Windows |

빈 칸이 눈에 더 잘 띄므로 **후자가 더 알아보기 어려운 실패다** — 그럴듯한 다른 글자는 "폰트가 이상한가" 로 읽힌다.

| platform | 구현 | 상태 |
|---|---|---|
| **Windows** | `is_full` 을 세우고 **호출자가 처리한다** — `drawTextInstances` · `drawBgInstances` 로 먼저 flush, `reset()`, 재시도 ([`renderer/windows.zig`](src/renderer/windows.zig)) | **사양대로.** 실기 확인 |
| **Linux** | `Atlas.full` 에 **찬 surface 를 표시**하고 호출자가 처리한다 — `glFlushText` 로 먼저 flush, `resetFull()`, 재시도 ([`host/linux/wayland_minimal.zig`](src/host/linux/wayland_minimal.zig) 의 `glAddGlyph`) | **사양대로.** 실기 확인 |
| **macOS** | 그 자리에서 `reset()` + `@memset(pixels, 0)` | **미구현** ([#584](https://github.com/ensky0/tildaz/issues/584)) |

**Linux 는 축이 둘 더 있다.** 텍스처가 `gray` · `color` 둘이라 (위 머리말의 포맷 분리) **찬 쪽만** 비운다 — 다른 쪽은 커서가 그대로여서 이미 내준 좌표가 살아 있다. 그래서 캐시도 surface 별로 나눠 둔다. 그리고 flush 는 **그 시점의 clip 을 들고** 해야 한다 — chrome 은 항목마다 `glScissor` 로 탭 경계를 자르므로, 안전망 flush 가 clip 을 빼면 탭 제목이 탭 밖으로 샌다.

**재시도는 한 번뿐이다** (세 platform 공통). 비운 직후에도 안 들어가면 그림 하나가 atlas 보다 크다는 뜻이라 그 셀을 건너뛴다 — 무한 루프가 없다. Linux 는 조건을 하나 더 둔다: **이미 빈 surface 인데 안 들어가면 `full` 을 아예 표시하지 않는다.** 표시하면 호출자가 글리프마다 헛되게 flush + reset 을 한다.

**Windows 실측** (노트북 · Ryzen AI 7 350 · Windows 11 Pro 26200 · 2880x1800 120 Hz · 150 % · `cell 14x29` · Cascadia Code 15pt). `ATLAS_SIZE` 를 2048 → 256 (넓이로 1/64) 으로 임시로 줄여 강제로 채웠다.

| | `ATLAS_SIZE=2048` | `ATLAS_SIZE=256` |
|---|---|---|
| `atlas full` | 0 회 | 한 화면을 그리는 데 **15 회** |
| 그림 | — | **두 판이 `0 / 1,258,008 px` — 완전 동일** |

**Linux 실측** (노트북 · Ryzen AI 7 350 · CachyOS · KDE Plasma Wayland · 2880x1800 120 Hz · scale 1.6 · `render_path=gpu-gl` · `cell 14x31` · DejaVu Sans Mono 15pt). 결합 기호 cluster **10,400 종** 화면 (200 칸 × 52 줄) 이라 기본 `ATLAS_SIZE` 로도 찬다. **기준은 `ATLAS_SIZE=4096` 판**이다 — 그 화면으로 안 넘치므로 (`atlas full` 0 회) 그것이 온전한 그림이다.

| | 안전망 전 | 안전망 후 |
|---|---|---|
| `ATLAS_SIZE=2048` · `atlas full` | 한 화면에 **4 회** (`glyphs` 8,971~9,156 · `filled_y` 2,042~2,047) | 같음 — 안전망은 *차는 것*을 막지 않는다 |
| 2048 판과 4096 기준판의 그림 | **213,940 / 4,416,000 px 다름** (위쪽 6.22 줄) | **`0 px`** |
| `ATLAS_SIZE=256` (강제) · `atlas full` | 한 화면에 **292 회** | 같음 |
| 256 판과 4096 기준판의 그림 | **2,244,514 px 다름** (50.83 %) | **`0 px`** |

어긋난 폭이 산술과 맞았다 — 마지막 프레임이 `glyphs=9,156` 에서 비웠고 화면이 10,400 셀이므로 남은 `1,244` 셀이 앞자리를 덮어써 `1,244 ÷ 200 = 6.22` 줄이다.

**안전망은 네 조건에서 확인했다** (모두 4096 기준판과 `0 px`).

| 회차 | 무엇을 겨눴나 | `atlas full` |
|---|---|---|
| `ATLAS_SIZE` 2048 · 결합 기호 10,400 종 | 기본값에서 gray 가 차는 경우 | gray 4 회 |
| `ATLAS_SIZE` 256 · 같은 화면 | 한 화면에 여러 번 비우는 경우 | gray 292 회 |
| 2048 · emoji 400 종 + cluster 9,600 종 | **color 가 차는 경우**와 surface 별 캐시 분리 | color 7 회 · gray 4 회 |
| `ATLAS_SIZE` 128 · 탭 2 개 | **chrome 을 그리는 중에 차는 경우** (탭 제목이 clip 된다) | gray 2,423 회 |

마지막 회차가 clip 을 겨눈다 — clip 은 `.glyph` 항목에만 걸리므로 (아이콘 · 사각형은 화면 전체) **탭이 둘 이상이어야** 그 경로가 생긴다. 탭바까지 포함해 대조해 `0 px` 이었다.

**실패 모양이 platform 마다 다르다.** macOS 는 매 프레임 다시 채우므로 **화면이 계속 깜빡인다.** **Linux · Windows 는 화면이 바뀔 때만 다시 그리므로** (Windows 는 6 초 · 120 Hz 에서 `resets` 가 15 에서 멈췄고, Linux 는 두 회차의 그림이 `0 px` 로 같았다) 깜빡임이 아니라 **틀린 화면이 그대로 멈춘다** — 더 눈에 안 띄는 실패다. Windows 는 안전망이 있어 가정법이지만, Linux 는 안전망을 넣기 전까지 실제로 그랬다.

#### ③ 로그 — 세 platform 이 같은 문구

```
atlas full — cleared and refilling (<kind>, resets=N, glyphs=N, clusters=N, fonts=N, filled_y=N)
```

**비우기 직전에** 남긴다 — 그 값이 이 atlas 가 실제로 담을 수 있었던 양이다.

| 필드 | 뜻 |
|---|---|
| `kind` | 어느 라스터 경로에서 찼는지 (`mono` · `color` · `icon` · `gray`) |
| `glyphs` · `clusters` | 담고 있던 항목 수. 둘의 비가 어긋나면 같은 그림을 여러 번 담고 있다는 신호다 |
| `fonts` | cluster 키에 실린 **서로 다른 폰트 id 수.** 화면이 쓰는 폰트 수와 맞아야 한다 |
| `filled_y` | 채운 높이 (px) |
| `resets` | 비운 누적 횟수 |

Linux 는 cluster 를 별도 맵에 두지 않아 `clusters` · `fonts` 자리가 `0` 이고, `glyphs` 는 **찬 surface 의 캐시 항목 수**다 (`kind` 와 같은 축이라 두 값이 짝이 맞는다).

#### ② 용량 — 실측 기준선

`ATLAS_SIZE` 는 산술로 정하지 않는다. cluster 비트맵은 cell 보다 크고 `packRow` 가 줄마다 낭비를 내므로, **위 로그가 유일한 근거**다.

| 환경 | atlas | 담긴 양 |
|---|---|---|
| Windows · Cascadia Code 15pt · `cell 14x29` (150 %) | 2048² | `glyphs 925` + `clusters 5,157` = **6,082** (`filled_y 2,037`) |
| macOS · Monaco | 2048² | 약 **5,880** |
| Linux · DejaVu Sans Mono 15pt · `cell 14x31` (scale 1.6) · **gray** | 2048² | **8,971 ~ 9,156** (`filled_y` 2,042~2,047) |
| Linux · Noto Color Emoji · 같은 기기 · **color** | 2048² | emoji **210 종** (`filled_y` 1,935) |

Linux 의 gray 값이 큰 것은 결합 기호 합성 비트맵의 평균 면적이 376 px² 라 (cell 434 px² 보다 작다) 같은 넓이에 더 들어가기 때문이다. **회차마다 갈리는 것이 정상**이다 — 어느 셀에서 차는지가 프레임 경계에 따라 조금씩 달라진다.

**컬러 쪽은 자리수가 다르다** — 회색이 9 천인데 컬러는 210 이다. 컬러 비트맵은 **cell 이 아니라 폰트 strike 크기**로 담기기 때문이다 (Noto Color Emoji 는 한 변이 100 px 대다). cell 로 줄이는 것은 그릴 때 하고 (`colorGlyphFit`), atlas 에는 구운 크기가 그대로 들어간다. 그래서 **emoji 를 수백 종 쓰는 화면은 컬러 텍스처를 먼저 채운다** — 회색이 한참 남아 있어도 그렇다. Linux 는 텍스처가 둘이라 그때 컬러만 비운다 (위 ①).

**용량으로 막는 것은 포기한다.** 4K@2x 최악 (11,110 종) 은 4096² (약 11,000) 으로도 경계라, ① 이 받게 한다.

---

## 13. VT 파싱 예산 — **응답성 상한이지 처리량 상한이 아니다** ([#387](https://github.com/ensky0/tildaz/issues/387))

`SessionCore.DRAIN_FRAME_BUDGET_NS` (**4 ms**) 의 사양은 이것이다.

> **드레인 한 번이 UI 스레드를 이 예산 이상 점유하지 않는다.**

즉 이 값은 **최악 입력 지연 예산**이다. **얼마나 자주 드레인하는지는 이 예산이 정하지 않는다.**
host 는 *입력을 굶기지 않는 한* 자주 드레인해야 하고, 특히 **프레임에 묶지 않는다.**

**왜 이 사양인가** (2026-08-05 결정, #387 §1). 예산을 "프레임당 1 회" 로 해석하면 duty 상한이
`예산 / 프레임간격` 이 되어 **화면 주사율이 터미널 처리량을 결정**한다 — 같은 CPU·같은 앱인데
60 Hz 사용자가 120 Hz 사용자의 절반만 소화한다. 화면에 보이는 것과 무관한 종속이라 사양이 아니다.
처리량은 CPU 에만 의존해야 한다 (§0 #1 의 세 platform 동등과 같은 취지).

### 13.1 host 별 드레인 지점

세 host 가 **같은 공유 함수** (`SessionCore.drainOutputForRender` → `drainFrame`) 를 쓰고, *부르는
지점*만 다르다. 예산 값과 `drainFrame` 자체는 공통이다. (#388 이전에는 Windows 만 별도
`prepareActiveFrame` 을 거쳤다 — §13.4.)

| platform | 프레임 렌더 | **프레임과 별개의 드레인 지점** |
|---|---|---|
| Linux | `wl_surface.frame` → `maybeRedraw` | **poll loop iteration 마다** + 밀린 출력이 있으면 `poll` timeout 을 **0** 으로 두어 즉시 다음 iteration ([`wayland_minimal.zig`](src/host/linux/wayland_minimal.zig), [#436](https://github.com/ensky0/tildaz/issues/436)) |
| Windows | `WM_FRAME_TICK` → `App.onRender` | **`PeekMessage` 가 빈 순간** (`Window.messageLoop` → `App.onIdleDrain`) |
| macOS | `CADisplayLink` → `renderFrameTick` | **`kCFRunLoopBeforeWaiting`** observer (`idleDrainObserver`) + `CFRunLoopWakeUp` |

**입력이 항상 드레인보다 우선한다.** Windows 는 대기 중인 메시지가 하나라도 있으면 드레인하지 않고,
macOS 의 `BeforeWaiting` 은 입력과 displayLink source 가 모두 처리된 뒤다. 유휴에는 드레인할 것이
없어 각각 `WaitMessage` / run loop sleep 으로 내려가므로 **유휴 절전 (#255 · #386 ②) 이 유지된다.**
Linux 도 밀린 출력이 없으면 timeout 이 `frame_poll_ms` 로 돌아가 같은 절전을 유지한다.

**세 host 의 공통 구조는 "드레인이 진행하는 동안 스스로 재진입한다" 다** — Windows 는 `messageLoop`
의 `if (f(userdata)) continue;`, macOS 는 `CFRunLoopWakeUp`, Linux 는 `poll` timeout 0 이 그 자리다.

### 13.1.1 유휴 깨우기 — PTY 도착을 통보한다 ([#439](https://github.com/ensky0/tildaz/issues/439))

위 재진입은 *이미 깨어 있는* 동안의 이야기다. **유휴에서 무엇이 깨우는가**는 별개 축이고, 예전에는
세 host 모두 프레임 타이머뿐이어서 **깨우기 주기가 그대로 응답 지연**이 됐다 (실측 평균 Linux
8.71 · macOS 5.83 · Windows 8.40 ms — 상한은 `주기 + render + present`).

이제 `SessionCore.pushOutput` 이 ring 에 넣은 자리에서 host 를 깨운다 (`output_wake_fn`).

| platform | 깨우는 법 | 깨어난 뒤 |
|---|---|---|
| Linux | `eventfd` 를 `poll` 배열에 추가, read thread 가 write | 기존 iteration 이 그대로 드레인 + `maybeRedraw` (**렌더 경로 변경 없음**) |
| Windows | `WM_PTY_OUTPUT` 을 `PostMessageW` | 그 핸들러가 `renderFrameTick` |
| macOS | version 0 `CFRunLoopSource` signal + `CFRunLoopWakeUp` | `perform` 콜백이 `renderFrameTick` |

**통보는 유휴일 때만 보낸다** (`frame_idle` / `g_frame_idle` — 직전 프레임이 그릴 것이 없어 건너뛰었나).
타이머가 이미 매 프레임 그리고 있으면 통보는 할 일이 없고, **보내면 오히려 느려진다** — 위 §13.1 표의
*"프레임과 별개의 드레인 지점"* 이 Windows 는 *"`PeekMessage` 가 빈 순간"*, macOS 는
*"`BeforeWaiting`(= run loop 이 잠들기 직전)"* 이라, 폭포에서 통보를 계속 보내면 큐가 비지 않고 run
loop 이 잠들지 않아 **그 드레인이 굶는다.** 그러면 프레임 밖에서 하던 일이 통째로 프레임 안으로
밀려들어 폭포 중 입력 지연이 1.5 → 8.2 ms 로 나빠진다 (macOS 실측 A/B). Linux 는 드레인이 poll loop
iteration 마다라 *자리*가 바뀌지 않아 이 위험이 없다 — **Linux 실측 A/B 가 이 판정을 확인했다**
(2026-08-16 · KDE Plasma 60 Hz): 회귀의 지문인 `onrender` 회당 시간이 0.147 → 0.142 ms 로 늘지 않았고
`drain` · `render` 총 시간과 처리량도 그대로다. 같은 회차에서 유휴 지연은 8.80 → 0.64 ms 다.

**(d) 유휴 타이머 정지는 하지 않기로 했다** (2026-08-16 사용자 결정, #439). 통보가 생겨 기술적으로는
가능해졌지만 이득이 절전 ~0.2 W 뿐인 데 비해 실패 모드가 **화면이 멈추는 것**이고 (판정이 틀리면
아무도 안 깨운다), 유휴 타이머가 host 마다 다른 장치라 (`poll` timeout · `CADisplayLink` ·
`frameClockThread`) *"정말 그릴 것이 없나"* 판정을 세 벌 만들어 세 머신에서 검증해야 한다. 게다가
**(a)(b)(c) 가 들어간 지금은 이득이 더 줄었다** — 통보가 항상 깨우므로 타이머는 백업 역할이다.
그래서 타이머와 `poll` timeout 은 그대로 둔다. 절전이 사용자 요구로 올라오면 그때 새 이슈로 연다.

> ⚠️ **이전 문서는 Linux 를 *"원래부터 이 사양"* 으로 적었는데 사실이 아니었다**
> ([#436](https://github.com/ensky0/tildaz/issues/436), 2026-08-10 실측). Linux 는 iteration 마다
> 드레인하지만, **그 iteration 을 깨우는 것이 폭포 중에는 실질적으로 `wl_surface.frame` callback
> 하나**였다 (`pollAndDispatch` 가 기다리는 fd 는 Wayland · toggle IPC 뿐이고 PTY 도착은 이 poll 을
> 깨우지 않는다). 그래서 회전이 프레임에 묶여 **프레임당 약 1.45 회로 고정**됐고, duty 가
> `프레임당 드레인 ÷ 프레임 간격` 이 되어 **주사율에 반비례**했다 — 이 절이 금지한 바로 그 종속이다.
> timeout 0 재진입으로 고쳤고 실측은 §13.2 에 있다.

### 13.2 실측 — 드레인 지점 한 줄만 켜고/끈 대조 (예산 8 ms 시점)

| | 프레임당 1 회 (이전) | **사양대로** | |
|---|---:|---:|---|
| **Windows ①** (Ryzen AI 7 350 · 외장 59 Hz) | duty 50.2 % · 33.3 MiB/s · 59.0 fps | duty **90.7 %** · **53.5 MiB/s** · 59.0 fps | **×1.61** · fps 손실 없음 |
| **Windows ②** (i5-1240P · 내장 60 Hz) | duty 50.6~51.4 % · 29.3~30.2 MiB/s · 60.0 fps | duty **91.5~92.2 %** · **47.4~53.5 MiB/s** · 60.0 fps | **×1.61~1.77** |
| **macOS** (M5 Pro · 외장 60 Hz) | duty 49.1 % · 60.7 MiB/s · 60.0 fps | duty **96.1 %** · **119.6 MiB/s** · 56.4 fps | **×1.97** |
| **폭포 중 입력 10 회** | — | **10 / 10** (세 platform) | 응답성 비용 없음 |

`drain / 프레임` 이 판정 근거다 — 프레임당 1 회에서는 예산 + 청크 초과분 (8.4~8.6 ms) 이고,
사양대로면 그보다 크다 (15 ms 대).

**주사율 종속이 사라진다.** 프레임당 1 회일 때 Windows ① 내장 120 Hz 는 duty 88 % 인데 외장 60 Hz 는
50.2 % 였다 — 사양대로 고친 뒤 60 Hz 가 90.7 % 로 올라 두 주사율이 같은 수준이 된다.

#### Linux — 같은 대조를 2026-08-10 에 처음 떴다 (예산 4 ms, [#436](https://github.com/ensky0/tildaz/issues/436))

**위 표에 Linux 행이 없던 것은 재지 않았기 때문이고, 재 보니 종속이 남아 있었다.** 같은 기기에서
**주사율만** 바꿔 대조했다 (노트북 AMD Ryzen AI 7 350 · KDE Plasma Wayland · 2880x1800 · scale 1.6 ·
AC · CPU `performance` · 64 MiB · 120x40 · scrollback 32,767 · `ReleaseFast -Dsimd=true` · 5 회 절사평균 ·
손실 0). duty 의 분모는 총시간이다.

| 워크로드 | 60 Hz 처리량 | 60 Hz duty | **`60÷120` 비** |
|---|---|---|---|
| `ansi` | 41.2 → **111.1** (+170 %) | 40.4 → **96.8 %** | 0.49 → **1.03** |
| `hangul` | 53.5 → **122.8** (+130 %) | 39.7 → **80.9 %** | 0.46 → **1.01** |
| `cjk` | 25.4 → **67.6** (+166 %) | 41.9 → **97.9 %** | 0.44 → **1.01** |
| `emoji_vs16` | 12.0 → **25.9** (+116 %) | 48.4 → **98.7 %** | 0.50 → **1.00** |
| `zwj` | 15.2 → **35.3** (+132 %) | 46.8 → **98.7 %** | 0.47 → **1.01** |
| `plain` | 164.3 → 166.5 (+1 %) | 28.1 → 24.8 % | 1.01 → **1.02** |

**`60÷120` 비가 0.44~0.50 에서 1.00~1.03 이 된 것이 판정이다.** `plain` · `hangul` 의 duty 가 낮은
것은 PTY 가 병목이라 **드레인할 것이 없기** 때문이고, 둘 다 `pty` 층 상한의 100 % 를 쓴다. 이 fix 의
거래 (120 Hz cluster 에서 fps 121 → 93~104) 는 §13.5 에 있다.

### 13.3 예산 값 — 4 ms 인 이유

`DRAIN_FRAME_BUDGET_NS` 는 **공유 상수라 세 platform 이 함께 바뀐다.** 값의 의미는 "입력이 최악
얼마나 기다리나" 이므로, 바꾸려면 처리량이 아니라 **입력 지연**을 근거로 판단한다. 예산 검사가
청크 사이에 있어 마지막 청크가 넘기므로 실측 점유는 예산을 조금 초과한다 (4 ms 예산에서 4.4~4.5 ms).

**8 → 4 ms** (2026-08-05 결정, #387). 사양 A 아래에서는 예산이 **처리량과 무관**해져서, 응답성을
공짜로 절반 사는 거래가 됐다. 다섯 조건 실측:

| platform · 화면 | 8 → 4 ms |
|---|---|
| **Windows ②** 60 Hz | fps 60.0 유지 · 처리량 유지 (−4.1~+1.8 %) · **프레임 tick 점유 9.7 → 5.8 ms** |
| **Windows ①** 120 Hz | tick fps 103.3 → **120.0** · 처리량 유지 (62.53 → 62.60 MiB/s) |
| **macOS** 60 Hz | fps 56.7 → **60.0** · 처리량 **+3.3 %** |
| **macOS** 120 Hz | fps 40.7 → **99.6 (×2.4)** · 처리량 −2.6 % |
| **Linux** 120 Hz | fps 60.0 → **109.4 (×1.82)** · 처리량 −1.2 % ⚠️ **120 Hz 만 쟀다 — 아래 참고** |

> ⚠️ **Linux 는 120 Hz 한 조건만 재서 종속을 놓쳤다** ([#436](https://github.com/ensky0/tildaz/issues/436)).
> 위 `−1.2 %` 는 8 ms 에서 드레인이 프레임을 밀어내 fps 가 60 이던 것이 4 ms 에서 109.4 로 회복돼
> **duty 가 우연히 유지된** 결과다. **60 Hz 는 fps 가 이미 패널 상한이라 회복할 여지가 없어 duty 가
> 74 → 41 % 로 내려앉았고**, 그 사실이 2026-08-10 까지 드러나지 않았다. 그래서 **예산을 바꿀 때는
> 주사율이 다른 두 조건을 함께 재야 한다** — 한 조건만 재면 "처리량 유지" 가 그 조건에서만 참일 수 있다.

**하한은 4 ms 다.** macOS 120 Hz 의 3 ms 에서 duty 포화가 96 → 73.7 % 로 깨져 처리량이 23 % 떨어졌다
(호출당 고정비가 예산에 비해 커지는 지점으로 *추정* — 확인 안 함). 60 Hz 는 3 ms 에서도 포화가
유지되므로 **하한은 주사율에 따라 다르고**, 4 ms 가 두 주사율에서 모두 안전한 값이다.

**예산은 사양 A 가 있을 때만 줄일 수 있다.** 사양 A 를 끈 구조에서 8 → 4 ms 를 하면 duty 가 프레임
상한에 붙어 처리량이 반토막난다 (Windows ② 60 Hz 실측: 29.3~30.2 → 15.1~15.2 MiB/s, ×0.50). 즉 예산은
사양 A 아래에서 **응답성 손잡이**, 사양 A 없이는 **처리량 손잡이**다.

### 13.3.1 pane 수 축 — 예산은 하나, 보이는 pane 이 나눠 쓴다 ([#483](https://github.com/ensky0/tildaz/issues/483) 6단계, 2026-08-27 · 세 platform 재측정 [#551](https://github.com/ensky0/tildaz/issues/551), 2026-08-31)

화면 분할로 "활성/비활성" 2 분법이 "보임/안 보임" 이 됐다. `drainFrame` 은 **활성 pane 을 먼저**, 그다음 보이는
pane 을 화면 순서로 한 청크씩 돌리고, **pane 사이에서도 예산을 검사**한다 — 검사 없이 N 청크를 돌면 최악 점유가
`예산 + N 청크` 로 pane 수에 비례해 커진다. 예산 자체는 **4 ms 하나**다 — 보이는 pane 이 몇이든 UI 스레드가 한
번에 붙잡히는 상한은 같고, pane 들은 청크를 번갈아 받아 같은 프레임에 함께 나아간다. "pane 마다 1 ms" 나
"pane 수 × 4 ms" 는 택하지 않았다 — 전자는 처리량을 pane 수로 나누고 (사양 A 가 있어 어차피 프레임 사이에 더
드레인한다), 후자는 최악 입력 지연을 pane 수에 비례해 늘린다.

**실측 — 세 platform** (`zig build stress -- throughput --layer frame --panes N --cols 120 --rows 40`,
`plain` · pane 마다 producer 하나 · **64 MiB/pane** · 합계 격자를 **120×40 으로 고정** · 조건별 5 회 절사평균).
회차별 값과 실제 앱 `perf.render` 까지 담은 전체 표는 [#551](https://github.com/ensky0/tildaz/issues/551) 에 있다.
이전 판은 macOS 한 대에서만 쟀고 8 · 16 pane 만 격자가 240×80 이라 pane 수와 격자가 함께 움직였다.

| platform · 기기 | 최장 드레인 1 → 16 pane | 합계 처리량 1 → 16 pane (120 fps) |
|---|---|---|
| **macOS** · MacBook Pro M5 Pro · 120 Hz | 1.69 → **4.07** ms | 143 → 111 MiB/s |
| **Windows** · Lenovo 83JY · Ryzen AI 7 350 · 120 Hz | 4.16 → **4.55** ms | 161 → 79 MiB/s |
| **Linux** · Ryzen AI 7 350 · 120 Hz | 4.32 → **7.93** ms | 101 → 46 MiB/s |

producer 종료 퍼짐 (pane 간 공정성) 을 모사 프레임으로 환산한 값 — 120 fps 기준:

| pane | macOS | Windows | Linux |
|---:|---:|---:|---:|
| 2 | 0.5 | 4.4 | 14.6 |
| 4 | 0.8 | 24 | 60 |
| 8 | 0.9 | 112 | 125 |
| 16 | **20.4** | **349** | **1,757** |

읽는 법 — 넷이다.

- **예산은 상한으로 작동하지만 초과 폭이 pane 수에 따라 커진다.** 세 platform 다 최장 점유가 pane 수와 함께
  올라간다. 예산 검사가 청크 *사이*에만 있어 마지막 청크가 넘기 때문이고, macOS · Windows 는 16 pane 에서도
  초과 폭이 0.6 ms 안 (청크 하나) 에 머문다.
- **Linux 만 16 pane 에서 상한이 깨진다** (6.98~11.27 ms). 원인 코드는 공통 `drainFrame` 이지만
  **발현은 host 에서 갈린다** — macOS · Windows 는 같은 조건에서 묶였다. Linux host 의 드레인 구조로 따로 추적한다.
- **공정성은 pane 2 개부터 나빠지고 host 마다 크게 다르다.** `drainFrame` 이 매 호출 `group.panes` 를
  **처음부터** 도는데 (숨은 탭에는 `inactive_drain_cursor` 가 있지만 **보이는 pane 에는 커서가 없다**)
  예산이 한 바퀴를 못 채우면 뒤 pane 이 다음 프레임에도 계속 뒤로 밀린다. 한 프레임에 한 바퀴를 도는
  host 에서는 드러나지 않아, 같은 코드가 macOS 0.9 프레임 · Linux 125 프레임으로 갈린다 (8 pane).
- **프레임당 렌더 비용은 pane 수에 비례하지 않는다.** 실제 앱을 띄워 `perf.render` 로 잰
  `render/call` 이 1 → 8 pane 에서 macOS 0.386 → 0.286 ms, Windows 0.653 → 0.894 ms,
  Linux 0.368 → 0.430 ms 로 pane 수에 비례하지 않는다. Windows 4 · 8 pane 은 중간 pane 종료 전
  ring 을 마저 소화하도록 고친 뒤 120 Hz 에서 다시 잰 유효값이다 ([#572](https://github.com/ensky0/tildaz/issues/572)).
  즉 pane 을 늘려도 밀리는 것은 렌더가 아니라 위의 드레인 공정성이다.

합계 처리량은 격자를 고정했는데도 pane 수가 늘면 내려간다 (pane 하나의 몫이 아니라 합계다) — 격자 변화가 아니라
producer · PTY · ring 경쟁 때문이다. `frame` 층은 프레임마다 한 번만 드레인해 (사양 A 없음) 앱의 하한이다.

### 13.4 렌더 게이트는 "화면이 바뀌었나" 하나다 ([#388](https://github.com/ensky0/tildaz/issues/388))

> **밀린 출력이 있다는 것은 그릴 이유이지 안 그릴 이유가 아니다.** 렌더를 줄이는 게이트는
> "안 바뀌면 안 그린다" (#386 ② · #255) 하나뿐이고, **세 platform 공통**이다.

즉 *"출력이 밀렸으니 이 프레임은 건너뛴다"* 류의 시간 기반 렌더 throttle 을 두지 않는다.
프레임 pacing 은 각 host 의 vsync 계열 구동(`WM_FRAME_TICK` clock · `CADisplayLink` ·
`wl_surface.frame`)이 하고, 처리량 조절은 §13 의 드레인 예산이 한다. 두 역할을 한 상수로
섞지 않는다.

**왜 사양으로 적는가.** Windows 에만 `prepareActiveFrame` 안에 *"활성 탭에 밀린 출력이 있고 직전
렌더가 8 ms 안이면 렌더를 건너뛴다"* 는 throttle 이 있었다. 근거가 기록되지 않은 값이었고
([`619fa44`](https://github.com/ensky0/tildaz/commit/619fa44) 가 대규모 리팩터 안에서 200 → 8 ms 로
바꿨다), 드레인 예산과 **같은 숫자 8 인데 의미가 달라** 혼선의 원인이었다. #388 에서 지웠다.

| 판정 | 근거 |
|---|---|
| 물릴 조건이 `문턱 > 프레임 사이클` 이라 **현행 예산에서는 물리지 않았다** | 드레인이 예산을 다 쓰면 `milliTimestamp` delta 가 예산 이상이다. Windows ①·② 의 8 ms 폭포 측정이 모두 `skip=0` |
| 물리면 **거래가 나쁘다** | 문턱만 20 ms 로 올린 실측(Windows ② · 60 Hz): 그린 fps 60.0 → **30.4** 인데 처리량은 +0.7~4.3 % |
| 프레임 tick 만 막는 게 아니었다 | `render_fn` 은 `WM_SIZE` 즉시 렌더 · Alt+Enter 전환에서도 불린다 |
| 선례 | Windows Terminal 도 터미널 렌더에 ms 게이트가 없다 — DXGI frame-latency waitable + `_redraw` 플래그로 pacing (ms throttle 은 XAML 스크롤바 8 ms · regex 패턴 100 ms 처럼 부속 UI 에만) |

### 13.5 알려진 platform 차이 — 폭포 중 fps 는 Windows 만 완전 유지다

**사양 위반이 아니다** (사양은 드레인 한 번의 점유 상한이고 fps 유지는 사양이 아니다). 다만 세
platform 이 갈리는 지점이라 기록해 둔다.

| platform | 폭포 중 fps (예산 4 ms) | 구조상 이유 |
|---|---|---|
| **Windows** | **유지** (60 Hz 60.0 · 120 Hz 120.0) | 별도 clock 스레드가 `WM_FRAME_TICK` 을 post 하고 `PeekMessage` 가 드레인보다 우선이라 tick 이 밀리지 않는다 |
| **Linux** | 60 Hz **61~69 유지** · **120 Hz 93~104** (cluster) | 밀린 출력이 있으면 timeout 0 으로 계속 드레인하므로 (§13.1, [#436](https://github.com/ensky0/tildaz/issues/436)) 프레임당 드레인이 9.9~11.3 ms 로 **120 Hz 간격 8.33 ms 를 넘어** 프레임을 놓친다. 60 Hz 는 간격이 16.67 ms 라 유지된다 (오히려 62 → 65 로 올랐다) |
| **macOS** | 60 Hz 60.0 · **120 Hz 99.6** | `CADisplayLink` 가 **run loop source** 라 `BeforeWaiting` 드레인에 발사가 밀린다 |

**Linux 의 120 Hz 저하는 [#436](https://github.com/ensky0/tildaz/issues/436) 의 fix 가 만든 거래다.**
드레인 재진입을 넣어 duty 가 86~91 → 97.5~98.5 % 로 오르고 처리량이 +8~27 % 됐는데, 그만큼 프레임당
드레인이 길어져 120 Hz 간격을 넘었다. **예산 8 ms 시절과 비교하면 두 지표 모두 낫다** (그때는 프레임당
≈12.4 ms · fps 60 · duty ≈74 %). 사양 위반이 아니고 (예산 4 ms 그대로) 60 Hz 는 영향이 없지만,
121 → 93 은 기록해 둘 값이라 후속으로 볼 수 있다 — *아이디어 (미검증)*: 드레인 사이클 안에서 다음
frame callback 이 도착했는지 보고 양보하기 (macOS 의 아래 아이디어와 같은 모양).

예산 8 ms 시절 macOS 120 Hz 는 40.7 fps 까지 떨어졌고 (Windows 는 같은 조건에서 유지) 4 ms 로 99.6 까지
회복했다. 남은 차이를 없애려면 macOS 의 드레인 지점을 손봐야 한다 — *아이디어 (미검증)*: `BeforeWaiting`
안에서 다음 `CADisplayLink` 발사가 임박했는지 보고 양보하기. 근거와 macOS 열 네 점 실측은
[#387](https://github.com/ensky0/tildaz/issues/387) 에 있다.

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
| autostart (LaunchAgent) | ✅ | #126, #442 | `~/Library/LaunchAgents/com.tildaz.app.plist` (RunAtLoad), Windows Registry Run 동등. `ProgramArguments` 는 `/usr/bin/open -a` 경유 — 번들 밖 실행은 바이너리 직접 지목으로 fallback (#442) |
| 로그 시스템 (`~/Library/Logs/tildaz_N.log`) | ✅ | #124 | Windows 와 공통 `src/log.zig` (+ OS 별 `src/log/{windows,macos,linux}.zig`) 동등. `[exit]` 는 `atexit()` hook 으로 기록 — NSApp `terminate:` 가 `exit()` 직행이라 main 의 `defer` 안 거침. |
| Developer ID 코드사인 + notarization | 🔴 (환경 한계) | #109 | 회사 keychain 정책 — fallback은 stable self-signed TildaZ identity |
| config schema 확장 (font.* / shell / max_scroll_lines) | ✅ | #118 | Linux · macOS · Windows가 같은 schema를 사용하고 default만 OS별로 다름. |
| SIGHUP 무시 셸 fallback (SIGKILL) | ✅ | #129 | `Pty.deinit` 에 grace period (500ms / 5ms polling) + `child_exited` atomic flag. wait_thread 의 waitpid 가 깨어나면 즉시 break, 안 깨어나면 SIGKILL. Cmd+W / 탭 close button 으로만 트리거 (Cmd+Q 는 NSApp `terminate:` → `exit()` 직행). |
### A.2 Windows 미구현 (macOS 기능 → Windows 추가)

| 항목 | 우선순위 | 이슈 | 비고 |
|---|---|---|---|
| 이전 / 다음 탭 단축키 | ✅ | #125 | Windows: Ctrl+Shift+[ / Ctrl+Shift+] (macOS Shift+Cmd+[/] 와 동일 키 pair, modifier 만 Windows 네이티브). macOS: Shift+Cmd+[/]. |
| 단일 탭 시 탭바 자리 reserve 버그 | ✅ | #127 | `App.effectiveTabBarHeight()` + count 1↔2 전환 시 `resizeAll`. `renderer/windows.zig` 도 height==0 면 탭바 skip. |
| 컬러 emoji + grapheme cluster shaping | ✅ | [#134](https://github.com/ensky0/tildaz/issues/134), [#136](https://github.com/ensky0/tildaz/issues/136), [#139](https://github.com/ensky0/tildaz/issues/139) | macOS #132 동등성. (a) `IDWriteFactory2.TranslateColorGlyphRun` + Direct2D D3D11-backed RT (`CreateDxgiSurfaceRenderTarget`) 으로 layer 별 `DrawGlyphRun` (`GRAYSCALE` antialias) + 2x super-sampling + `SetTextRenderingParams` (gamma=1.0) → atlas 에 premultiplied BGRA 로 저장. shader color path 가 `atlas.rgba` (premult) + `atlas.aaaa` 로 dual-source blend (Win Terminal `BackendD3D` 동등). (b) `IDWriteTextAnalyzer` 로 grapheme cluster shaping (skin tone, ZWJ). (c) `mode 2027` (grapheme cluster) ON. (d) ZWJ family glyph (`👨‍👩‍👧` 등) 는 `IDWriteTextAnalyzer.GetGlyphPlacements` 로 multi-glyph cluster 의 advance/offset 받아 visual 결합 (#139, WT 동등). |
| IME inline preedit (cell) | ✅ | [#164](https://github.com/ensky0/tildaz/issues/164) v0.4.0 | macOS 의 `g_preedit_buf` + 보라 overlay 동등. `WM_IME_STARTCOMPOSITION` / `WM_IME_COMPOSITION` (`GCS_COMPSTR`) / `WM_IME_ENDCOMPOSITION` 가로채기 + `ImmGetCompositionStringW` UTF-16 → UTF-8 → `Window.preedit_buf` → renderer overlay (cursor 위치 inline). |
| IME 후보 popup cursor 추적 | ✅ | [#164](https://github.com/ensky0/tildaz/issues/164) 1d v0.4.0 | `ImmSetCompositionWindow(CFS_POINT, cursor_pixel)` 매 frame onRender 끝에 호출. 일본 / 중국 / 한국 IME 의 한자 후보 popup 이 cursor 옆 자연 추적. `D3d11Renderer.last_cursor_px_x/_y` 에 cursor 그릴 때 보관. |
| About 다이얼로그 본문 복사 | ✅ | #128, #314 | Windows는 read-only multiline EDIT의 selection/Ctrl+C, macOS는 selectable `NSTextView` selection 변경 시 자동 copy로 NSAlert firstResponder 제약을 우회. |

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
| Linux GPU 렌더의 안티에일리어싱 ±1 ([#277](https://github.com/ensky0/tildaz/issues/277)) | Linux 도 GPU 렌더러(GBM + dma-buf + OpenGL ES)를 기본으로 쓴다. software `wl_shm` 은 영구 fallback. 두 경로의 화면은 같지만, **회색 배경 위 텍스트의 안티에일리어싱 픽셀이 채널당 최대 1** 다르다. | GPU 가 premultiplied source 를 render target 정밀도(8bit)로 양자화한 뒤 블렌드해 반올림이 두 번 일어나는 **하드웨어 동작** — [#353](https://github.com/ensky0/tildaz/issues/353) 이 Windows D3D11 에서 확인한 것과 같고 우리 코드로 못 맞춘다. macOS · Windows 도 GPU 라 같은 성질을 가지므로 세 platform 이 같은 쪽으로 정렬된 결과다 (2026-08-02 결정). 검은 배경에서는 dst 항이 0 이라 나타나지 않는다. |
| Linux GPU 렌더의 컬러 emoji 축소 필터 ([#277](https://github.com/ensky0/tildaz/issues/277)) | GPU 경로는 컬러 emoji 를 **bilinear** 로 축소하고 software 경로는 nearest 로 축소한다 — 같은 emoji 가 두 경로에서 미세하게 다르게 보인다. | emoji bitmap 은 폰트 strike (~109px) 라 cell 로 크게 축소되는데 nearest 는 텍셀을 통째로 버려 가장자리가 거칠다. GPU 가 공짜로 해 주는 보간을 포기할 이유가 없어 화질을 택했다 (2026-08-02 결정, ghostty · foot 도 같은 선택). software 경로는 픽셀당 보간이 CPU 비용이라 nearest 를 유지한다. |

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

> **macOS emoji picker 이력 노트 ([#130](https://github.com/ensky0/tildaz/issues/130)):** 2026-05-06 ([5b1d8b5](https://github.com/ensky0/tildaz/commit/5b1d8b5)) 시점엔 picker 가 cursor 옆 popover 가 아닌 화면 floating panel 로 뜨고 focus loss 에 자동 dismiss 안 되는 quirk 가 이 표에 있었다. 2026-07-13 실기 (macOS 26.5.2 + v0.6.1) 재검증에서 popover + 자동 dismiss 로 정상 동작해 **해소 확인** — 현행 동작은 §5.2. 원인은 미확정 (후보: 그 직후 #166/#190 의 NSTextInputClient 표면 확장, 또는 macOS 업데이트). Esc dismiss 보강 코드 (`isEmojiPickerOpen()`, `src/host/macos.zig` — `CGWindowListCopyWindowInfo` 로 `com.apple.Character*` bundle 의 onscreen 윈도우 감지) 는 무해해서 유지한다. 관련 검색어: `orderFrontCharacterPalette`, `CharacterPicker.framework`.

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

*마지막 업데이트: 2026-07-18 (#282 XDG base directory·perf clock 정합).
이 문서는 living document — 코드 변경할 때 같은 커밋 안에서 update.*
