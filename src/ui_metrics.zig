//! 크로스 플랫폼 UI 디자인 상수. logical points 단위 — 사용처에서 DPI /
//! Retina scale 을 곱해 pixel 단위로 변환. Linux · macOS · Windows 가 동일
//! 값을 사용해 세 플랫폼 시각적 일관성 유지.

const std = @import("std");
const font_spec = @import("font/spec.zig");

/// 터미널 영역 안쪽 padding. 글자가 윈도우 모서리에 딱 붙지 않게.
pub const TERMINAL_PADDING_PT: u32 = 6;

/// 우측 scrollbar 너비.
pub const SCROLLBAR_W_PT: u32 = 10;

/// 터미널 격자의 **열 수** — 좌우 padding 과 **scrollbar 자리**를 뺀 폭을 cell 폭으로
/// 나눈다 (#350).
///
/// scrollbar 자리는 **항상** 비운다. scrollbar 는 스크롤백이 있을 때만 그려지지만
/// (`scrollbar.hit` 이 `total <= len` 이면 null), 보일 때만 비우면 스크롤백이 처음
/// 생기는 순간 열 수가 줄어 셸이 reflow 한다 — 출력 중에 레이아웃이 흔들린다
/// (2026-07-29 사용자 결정).
///
/// **단일 정의로 모은 이유.** 이전에는 세 platform 이 `viewport − 2·pad` 를 각자
/// 계산했고 (macOS 는 세 곳, 합 다섯 곳), **다섯 곳 전부 scrollbar 를 빼지 않아**
/// 마지막 열이 scrollbar 열과 겹쳤다. hit-test 는 이미 `viewport − pad − SCROLLBAR_W`
/// 를 셀 밖으로 처리하고 있었으므로 (주석까지 *"스크롤바 옆"*) 의도는 처음부터
/// 비워두는 것이었고 격자 계산만 빠졌다 — 그리기와 hit-test 가 어긋나 마지막 열이
/// 클릭·선택되지 않았다. 같은 누락이 반복되지 않도록 여기 한 곳에 둔다.
///
/// 인자는 모두 physical px 이고 `i64` 라 호출처의 `c_int` / `u32` / `i32` 가 캐스팅
/// 없이 들어온다. 창이 극단적으로 좁아 cell 하나도 못 담으면 1 열을 보장한다.
pub fn terminalCols(viewport_w: i64, pad: i64, scrollbar_w: i64, cell_w: i64) u16 {
    if (cell_w <= 0) return 1;
    const usable = viewport_w - 2 * pad - scrollbar_w;
    if (usable < cell_w) return 1;
    return @intCast(@min(@divTrunc(usable, cell_w), @as(i64, std.math.maxInt(u16))));
}

/// 터미널 격자의 **행 수** — 상단 탭바와 위아래 padding 을 뺀 높이를 cell 높이로
/// 나눈다 ([#352](https://github.com/ensky0/tildaz/issues/352)).
///
/// `terminalCols` 와 **대칭**이다 — 열 수가 `scrollbar_w` 를 빼는 자리에 행 수는
/// `tab_bar_h` 를 뺀다. 탭바는 단일 탭이면 0 이다 (`tabBarHeightPx` 가 count < 2 에서
/// 0, #127) — 그 판정은 호출처(host)가 하고 여기서는 받은 값만 뺀다.
///
/// **단일 정의로 모은 이유.** #350 이 열 수를 여기로 모을 때 행 수는 같은 다섯 곳에
/// 남아 있었고, 그래서 **같은 함수 안에서 `cols` 는 방어되고 바로 다음 줄의 `rows` 는
/// 안 되는** 비대칭이 생겼다. 게다가 세 platform 이 같은 위험을 각자 다른 방식으로
/// 막고 있었다 — Linux 는 분자를 `cell_h` 로 clamp + `u16` 상한, Windows 는 분자를
/// `1` 로 clamp + `cell_h == 0` guard, macOS 는 `u32` 라 언더플로 wrap 을 막는 명시
/// `if` guard (상한 clamp 없음). 산술 결과는 도달 가능한 입력 전부에서 같았지만
/// (#352 본문의 경계 4케이스 표), 방어가 네 갈래라 다음 사람이 "왜 여긴 없지" 를
/// 판단해야 했다. 그 갈래를 이 함수 안으로 흡수한다.
///
/// 인자는 모두 physical px 이고 `i64` 라 호출처의 `i32` (Linux) / `c_int` (Windows) /
/// `u32` (macOS) 가 캐스팅 없이 들어온다 — 부호 없는 타입의 언더플로 wrap 이 원천
/// 차단된다. 창이 극단적으로 낮아 cell 하나도 못 담으면 1 행을 보장한다.
pub fn terminalRows(viewport_h: i64, tab_bar_h: i64, pad: i64, cell_h: i64) u16 {
    if (cell_h <= 0) return 1;
    const usable = viewport_h - tab_bar_h - 2 * pad;
    if (usable < cell_h) return 1;
    return @intCast(@min(@divTrunc(usable, cell_h), @as(i64, std.math.maxInt(u16))));
}

/// `terminalCols` · `terminalRows` 의 **역함수** — 원하는 격자를 담는 viewport 크기를
/// 낸다 ([#382](https://github.com/ensky0/tildaz/issues/382) 의 `-size` 옵션).
///
/// 앱은 보통 창 크기에서 격자를 구하지만, 측정할 때는 반대 방향이 필요하다. 터미널마다
/// 폰트 해석이 달라 같은 창 크기가 다른 셀 수를 주므로, 다른 터미널과 비교하려면 **셀
/// 수를 직접 맞춰야** 한다 ([#371](https://github.com/ensky0/tildaz/issues/371) L4).
///
/// 위 두 함수가 `@divTrunc` 로 내림하므로 그 결과가 정확히 `cols` · `rows` 가 되는 가장
/// 작은 크기를 낸다. 인자 단위와 의미는 두 함수와 같다 (physical px).
///
/// 셀 크기는 폰트 metrics 에서 나오므로 **renderer 초기화 뒤에야** 알 수 있다. 즉 호출처는
/// 창을 먼저 띄우고 그 뒤에 이 값으로 크기를 다시 맞춰야 한다.
pub fn viewportForGrid(
    cols: u16,
    rows: u16,
    pad: i64,
    scrollbar_w: i64,
    tab_bar_h: i64,
    cell_w: i64,
    cell_h: i64,
) struct { w: i64, h: i64 } {
    return .{
        .w = @as(i64, cols) * cell_w + 2 * pad + scrollbar_w,
        .h = @as(i64, rows) * cell_h + tab_bar_h + 2 * pad,
    };
}

test "viewportForGrid 는 terminalCols/Rows 의 역함수다" {
    // 실기에서 나온 값 (macOS: cell=19x39px, pad=12px, scrollbar=20px, 탭 1개라 탭바 0).
    const pad: i64 = 12;
    const sb: i64 = 20;
    const tab: i64 = 0;
    const cw: i64 = 19;
    const ch: i64 = 39;

    for ([_]u16{ 1, 40, 77, 120, 424 }) |cols| {
        for ([_]u16{ 1, 24, 40, 113 }) |rows| {
            const vp = viewportForGrid(cols, rows, pad, sb, tab, cw, ch);
            try std.testing.expectEqual(cols, terminalCols(vp.w, pad, sb, cw));
            try std.testing.expectEqual(rows, terminalRows(vp.h, tab, pad, ch));
        }
    }
}

test "viewportForGrid 는 가장 작은 크기를 낸다 — 1px 줄면 격자가 준다" {
    const vp = viewportForGrid(120, 40, 12, 20, 0, 19, 39);
    try std.testing.expectEqual(@as(u16, 120), terminalCols(vp.w, 12, 20, 19));
    try std.testing.expectEqual(@as(u16, 119), terminalCols(vp.w - 1, 12, 20, 19));
    try std.testing.expectEqual(@as(u16, 40), terminalRows(vp.h, 0, 12, 39));
    try std.testing.expectEqual(@as(u16, 39), terminalRows(vp.h - 1, 0, 12, 39));
}

test "viewportForGrid 는 탭바 높이를 더한다" {
    const without = viewportForGrid(120, 40, 12, 20, 0, 19, 39);
    const with = viewportForGrid(120, 40, 12, 20, 56, 19, 39);
    try std.testing.expectEqual(without.w, with.w);
    try std.testing.expectEqual(without.h + 56, with.h);
    // 탭바가 있는 창에서도 같은 rows 가 나와야 한다.
    try std.testing.expectEqual(@as(u16, 40), terminalRows(with.h, 56, 12, 39));
}

// --- pt → px 변환 (#350) ---
//
// 이 모듈의 `*_PT` 상수는 logical point 단위이고, 그리는 쪽은 현재 화면 scale 을
// 곱해 physical px 로 바꿔 쓴다. **그 변환은 여기 세 함수에만 있다** — 호출처가
// `@intFromFloat(@as(f32, @floatFromInt(X_PT)) * scale)` 을 직접 쓰지 않는다.
//
// 한 곳에 모은 이유. 이전에는 같은 변환이 세 platform 에 61곳으로 복붙돼 있었고
// **규칙이 갈렸다** — Linux(`scaledPt`) 와 Windows(`app_controller`) 는 `@round`,
// macOS `host/macos.zig` 9곳은 `@round` 없이 버림이었다. macOS 안에서조차
// `renderer/macos.zig` 의 아이콘 크기는 `@round` 를 써서 파일마다 달랐다.
// `backingScaleFactor` 가 1.0 / 2.0 이라 정수 배율에서는 두 규칙의 결과가 같아
// 증상이 드러나지 않았을 뿐이다 (fractional scale 에서 1px 갈린다).
// 같은 상수를 platform 마다 다른 픽셀로 바꾸는 것은 SPEC §0 #1 (세 platform
// 동등) 에 어긋나고, 이 이슈의 격자 버그가 정확히 "같은 계산 복붙" 이었다.
//
// 반올림을 택한 것은 다수 규칙(18곳)에 맞춘 것이고, 버림보다 원래 pt 크기에
// 가깝다 (`round(10.2) = 10` vs `trunc(10.2) = 10`, `round(17.0) = 17`).

/// `pt × scale` 을 정수 physical px 로 — **반올림**. 격자 / 레이아웃처럼 정수
/// 픽셀이 필요한 자리에 쓴다.
///
/// `T` 는 호출처가 쓰는 정수 타입 (`u32` / `i32` / `c_int`) 을 그대로 지정한다 —
/// 캐스팅을 호출처마다 반복하지 않기 위해서다. `pt` 는 `u32` 상수와 `f32` 상수를
/// 모두 받는다 (`TERMINAL_PADDING_PT` 는 `u32`, `TAB_ICON_STROKE_PT` 는 `f32`).
///
/// 음수 결과는 없다 (`pt` · `scale` 모두 음수가 아니므로). `T` 가 부호 없는
/// 타입이어도 안전하다.
pub fn scaledPx(comptime T: type, pt: anytype, scale: f32) T {
    return @intFromFloat(@round(scaledPxF(pt, scale)));
}

/// `pt × scale` 을 f32 physical px 로 — 정수 스냅 없이 소수를 유지한다. 그리기
/// 좌표처럼 서브픽셀 정밀도를 그대로 쓰는 자리용.
pub fn scaledPxF(pt: anytype, scale: f32) f32 {
    const pt_f: f32 = switch (@typeInfo(@TypeOf(pt))) {
        .int, .comptime_int => @floatFromInt(pt),
        else => pt,
    };
    return pt_f * scale;
}

/// `pt × scale` 을 f32 physical px 로 하되 **최소 1px 보장**. 소수를 유지한다 —
/// **아이콘 stroke 전용**이다 (`TAB_ICON_STROKE_PT` · `TAB_MORE_DOT_DIAMETER_PT`).
/// `tab_icons.rasterize` 가 이 값으로 안티에일리어싱 커버리지를 만들므로 소수가
/// 그대로 의미를 갖는다.
///
/// **격자에 놓이는 실선(separator / underline)에는 쓰지 않는다** — 그쪽은
/// `linePx` 다 ([#357](https://github.com/ensky0/tildaz/issues/357)). 두 용도가 이
/// 함수 하나에 섞여 있었고, 그 때문에 선 두께가 분수 배율에서 갈렸다.
pub fn strokePx(pt: anytype, scale: f32) f32 {
    return @max(1.0, scaledPxF(pt, scale));
}

/// **선 두께** — `pt × scale` 을 **정수** physical px 로 (최소 1px).
/// ([#357](https://github.com/ensky0/tildaz/issues/357))
///
/// 탭바 세로 구분선 · 활성 탭 amber 밑줄 · command menu 항목 구분선처럼 픽셀 격자에
/// 놓이는 실선의 두께에 쓴다. 반환형이 f32 인 것은 호출처(`tab_chrome.Inputs` ·
/// `command_menu.rects`)가 f32 좌표계라서다 — 값은 항상 정수다.
///
/// ## 왜 정수여야 하는가
///
/// 라스터화 규칙은 "픽셀 **중심**이 도형 안이면 칠한다" 이므로, 두께 `t` 의 선이
/// `top` 에 놓일 때 덮는 행은 `[round(top), round(top + t))` 다 (`ui_rect.snap` 의
/// 정의와 같고 GPU 도 같다). `t` 가 **정수면 `round(top + t) = round(top) + t` 가
/// 항상 성립**하므로 위치 소수부가 무엇이든 정확히 `t` 픽셀이 나온다. 소수면
/// 그렇지 않다 — 예: 두께 1.7px 은 `top` 의 소수부가 0.85 면 2px, 0.55 면 1px 이라
/// **같은 화면 안 두 구분선의 두께가 갈린다.**
///
/// 그 갈림이 [#357](https://github.com/ensky0/tildaz/issues/357) 의 증상이었고,
/// 동시에 Linux(두께를 미리 정수로 반올림) 와 macOS · Windows(소수를 그대로 GPU 로)
/// 사이의 **platform 갈래**이기도 했다. 배율 1.0 · 2.0 에서는 두 규칙의 결과가 같아
/// 증상이 드러나지 않았을 뿐이다 (1.25 · 1.75 에서 갈린다 — Windows 의 125% · 175%).
///
/// **위치 규칙은 건드리지 않는다** (`ui_rect.snap` 그대로). 두께만 정수로 만들면
/// 위치는 어디든 두께가 보존되기 때문이다.
pub fn linePx(pt: anytype, scale: f32) f32 {
    return @max(1, @round(scaledPxF(pt, scale)));
}

// ── SGR 선 속성의 위치·두께 (#365) ──────────────────────────────────
//
// `underline` (single · double) · `strikethrough` · `overline` 이 쓰는 세 비율.
// 조립은 [`renderer/cell_decoration.zig`](renderer/cell_decoration.zig) 가 하고
// 여기에는 값만 둔다 (platform 별로 다시 정의하지 않는다).
//
// ## 왜 `linePx` 가 아니라 `ascent` 비율인가
//
// 탭바 구분선 같은 chrome 은 화면 배율에만 비례하면 되므로 pt 상수 + `linePx` 다.
// 셀 안의 선은 **글자에 붙는 요소**라 폰트 크기에도 비례해야 한다 — pt 로 고정하면
// `font.size_point` 를 키웠을 때 글자만 커지고 밑줄은 그대로라 상대적으로 가늘어진다.
// 기준을 `ascent` 로 잡은 것은 세 renderer 가 **baseline = 셀 top + `ascent_px`**
// 로 글리프를 놓기 때문이다 (macOS `emitTextInstance` · Windows
// `emitClusterInstance` · Linux `appendGlyph` 모두 같은 식). 선을 같은 기준으로
// 계산하면 글리프와 항상 일관되고, macOS 만 행 원점을 `top_pad_px` 만큼 올리는
// 기존 차이도 자동으로 따라간다.
//
// ## 왜 폰트 metric 을 쓰지 않는가
//
// 밑줄 position / thickness 는 세 폰트 API 가 모두 주지만 **취소선과 x_height 는
// Linux (FreeType `FT_FaceRec`) 와 macOS (CoreText) 에 없다** — OS/2 테이블을
// 직접 읽어야 한다. 폰트값을 쓰면 *밑줄은 폰트값 · 취소선은 상수* 로 갈리고, 세
// API 의 단위 변환·반올림 차이로 platform 간 1px 이 어긋날 여지가 생긴다.
// #350 · #353 · #357 이 반복해 없애 온 종류의 갈래라 공통 상수로 간다
// (2026-08-03 사용자 확정).
//
// ## 값의 근거 — macOS CoreText 실측 (2026-08-03)
//
// | 폰트 | 밑줄 위치 ÷ ascent | 두께 ÷ ascent | (x_height÷2) ÷ ascent |
// |---|---|---|---|
// | Menlo (macOS 기본) | 0.068 | 0.047 | 0.295 |
// | Monaco | 0.038 | 0.076 | 0.273 |
// | Courier New | 0.280 | 0.049 | 0.254 |
// | DejaVu Sans Mono (Linux 기본) | 0.068 | 0.047 | 0.298 |
//
// Menlo 를 9 · 12 · 15 · 18 · 21 · 24 pt 로 재도 비율이 소수점 넷째 자리까지
// 같았다 — 비율이 폰트 크기와 무관하다는 근거다. Cascadia Code (Windows 기본) 는
// 측정 머신에 없어 system fallback 값이 나왔으므로 표에서 뺐다 (**확인 필요** —
// Windows 실기에서 재야 한다).

/// 셀 안 선(밑줄 · 취소선 · 윗줄)의 두께 비율 — `ascent` 대비. 실측 4종의
/// 0.047~0.076 사이 값.
pub const CELL_LINE_THICKNESS_RATIO: f32 = 0.06;

/// 밑줄 top 이 baseline 아래로 내려가는 거리 — `ascent` 대비. Menlo · DejaVu 의
/// 실측값 0.068 에 맞춘다.
pub const UNDERLINE_GAP_RATIO: f32 = 0.07;

/// 취소선 **중심**이 baseline 위로 올라가는 거리 — `ascent` 대비. 정석은
/// `x_height / 2` (소문자 한가운데) 이고 실측 4종이 0.254~0.298 이다.
pub const STRIKETHROUGH_CENTER_RATIO: f32 = 0.30;

/// 물결 밑줄 (`4:3`) 의 진폭 — **파장 대비** (#374).
///
/// ghostty 는 `파장 / π` (≈ 0.318) 를 쓴다. 그 값으로 만들어 macOS 실기에서 네
/// 터미널을 나란히 놓고 보니 **우리가 가장 출렁였다** — 물결 밴드가 TildaZ 8px ·
/// Alacritty 7px · kitty 6px 였다 (2026-08-03, Menlo 15pt @2x). 밑줄은 정보를
/// 전달하는 요소이지 장식이 아니라서, kitty 만큼 평평하지는 않되 Alacritty 정도로
/// 낮춘다 (사용자 선택). Alacritty 수준인 0.26 에서 한 번 더 다듬어 0.22 로 정했다
/// — 나란히 놓고 "살짝만 더 평평하게" 를 반영한 값이다 (2026-08-03 실기).
///
/// 처음에는 진폭을 **두께** 대비로 잡아 (`2 × 두께`) 계단 조각 수를 줄이려 했지만,
/// 15pt 에서 반올림 후 실질 진폭이 3px 까지 줄어 거의 직선처럼 뭉개졌다.
pub const CURLY_AMPLITUDE_RATIO: f32 = 0.18;

/// 셀 안 선의 두께 (physical px) — **정수 + 최소 1px**.
///
/// 정수여야 하는 이유는 [`linePx`](#linePx) 와 같다 (#357): 라스터화가
/// `[round(top), round(top + t))` 를 칠하므로 `t` 가 정수여야 위치 소수부와 무관하게
/// 두께가 보존된다. 소수 두께면 같은 화면 안 두 밑줄이 1px 씩 갈린다.
///
/// `ascent_px` 는 이미 화면 배율이 곱해진 physical px 다 (세 renderer 의
/// `font.ascent_px` 가 그렇다) — 그래서 여기서 `scale` 을 다시 곱하지 않는다.
pub fn cellLineThicknessPx(ascent_px: f32) f32 {
    return @max(1, @round(ascent_px * CELL_LINE_THICKNESS_RATIO));
}

// ── SGR 5 (blink) 의 주기 (#376) ─────────────────────────────────────
//
// ## 왜 완전히 숨기지 않고 faint 인가
//
// off 위상을 **faint (흐리게)** 로 표현한다. Windows Terminal 과 같은 선택이고
// ([PR #7490](https://github.com/microsoft/terminal/pull/7490) — 4-phase 중 2 를
// faint 로 렌더), WezTerm 도 딱딱 끄지 않고 투명도를 이징한다. 글자가 완전히
// 사라졌다 나타나는 것은 조사한 방식 중 가장 자극적이고, 광과민성 관점에서
// 굳이 택할 이유가 없다.
//
// 구현도 이쪽이 깔끔하다 — [`cell_color.resolveFg`](renderer/cell_color.zig) 가
// 이미 `flags.faint` 를 `themes.faintBlend` 로 처리하므로 그 경로를 그대로 탄다.
//
// ## 왜 이 값이 절전을 깨지 않는가
//
// 세 host 는 "tick 은 규칙적으로 돌고 게이트가 그릴 이유를 판정" 하는 구조다
// (macOS CADisplayLink · Windows `SetTimer` 16ms · Linux poll 16ms). 게이트를
// "화면에 blink 셀이 **있다**" 로 열면 매 vsync 그려서 [#255](https://github.com/ensky0/tildaz/issues/255)
// 의 절전 이득이 사라진다. **"phase 가 직전 프레임과 달라졌다"** 로 열면 1초에
// 전환이 정확히 2회뿐이라 추가 렌더가 초당 2프레임이다.
//
// SGR 5 (slow) 와 6 (rapid) 은 구분하지 않는다 — 구분하고 싶어도 못 한다. pin 된
// ghostty 파서가 둘을 모두 `.blink` 하나로 접어서 정보를 주지 않는다.

/// blink 한 위상의 길이 (ms). on 500 + off 500 = 1Hz 로, ECMA-48 의 "slow blink =
/// 분당 150회 미만" 을 만족하는 가장 흔한 값이다.
pub const BLINK_HALF_PERIOD_MS: i64 = 500;

/// 지금이 blink 셀을 **흐리게 그릴** 위상인가. `now_ms` 는 `Runtime.nowMs()` — 세 host 가
/// 같은 시계를 넘겨 위상을 맞춘다 (autoscroll tick 이 이미 쓰는 함수).
///
/// #451 — 호출은 **프레임마다 한 번**이다. 그 값을 렌더러까지 인자로 내려보내므로
/// 게이트 판정과 화면이 500 ms 경계에서 갈리지 않는다.
///
/// 벽시계라 시스템 시간이 점프하면 위상이 한 번 튈 수 있다. 깜빡임 한 번이
/// 어긋나는 것뿐이라 monotonic 시계를 따로 들이지 않았다.
pub fn blinkFaintPhase(now_ms: i64) bool {
    return @mod(@divFloor(now_ms, BLINK_HALF_PERIOD_MS), 2) != 0;
}

/// 터미널 커서 — 셀 좌측 세로 막대(bar)의 폭. #297 UX 결정 (2026-07-12):
/// 세 platform 모두 bar 커서로 통일 (이전: Windows/macOS full-cell block
/// alpha 0.7, Linux 하단 2px underline — 제각각).
pub const CURSOR_BAR_W_PT: f32 = 2.0;

/// bar 커서 폭의 physical px 변환 — 최소 1px 보장 (scale < 0.5 에서도 소멸 방지).
/// `strokePx` 와 달리 정수로 스냅한다 (커서는 셀 경계에 딱 붙어야 흐리지 않다).
pub fn cursorBarWidthPx(scale: f32) f32 {
    return @max(1.0, @round(CURSOR_BAR_W_PT * scale));
}

/// scrollbar thumb 의 최소 높이 — scrollback 이 길어 ratio 가 매우 작아도
/// thumb 가 클릭 가능한 크기 유지.
pub const SCROLLBAR_MIN_THUMB_H_PT: u32 = 32;

/// scrollbar thumb 의 알파. 값의 의미는 그대로 "30%" 이고, **합성은 renderer 가
/// 아니라 `blendOverRgb` 가 한 번만 수행**한다 (#353).
pub const SCROLLBAR_ALPHA: f32 = 0.3;

/// 알파 합성을 **이 한 곳에서만** 수행한다 (#353). `src` 를 `dst` 위에 `alpha`
/// 로 얹은 8bit 결과.
///
/// **왜 renderer 에 맡기지 않는가.** 이전에는 세 platform 이 각자의 합성 지점에서
/// 8bit 로 떨어뜨렸고 **규칙이 셋으로 갈렸다** — Linux 는 f32 곱 + 버림, macOS 는
/// 고정밀 곱 + 최근접 반올림, Windows 는 알파를 8bit 로 양자화한 뒤 최근접 반올림.
/// 같은 알파를 같은 배경에 얹어도 배경의 약 45% 에서 채널당 1 이 갈렸다 (음영은 2).
/// Windows 쪽은 blend factor 를 render target 정밀도로 양자화하는 **하드웨어 동작**
/// 이라 우리 코드로 맞출 수 없었다 — D3D11 명세가 blend 정밀도를 "RT format 이상"
/// 으로만 요구하므로 GPU / 드라이버마다 달라질 수 있다.
///
/// 여기서 한 번 합성해 **알파 1.0 solid** 를 renderer 에 넘기면 하드웨어가 합성에
/// 관여하지 않으므로 세 platform 이 *정의상* 일치한다. 반올림 tie 방향도 이 함수가
/// 결정하므로 platform 간 문제가 되지 않는다.
///
/// 반올림은 **최근접**이다 — 정확값에 가장 가까운 정수이고, 버림은 원래 알파가
/// 의도한 색에서 더 멀어진다. tie (`x.5`) 는 `@round` 가 0 에서 먼 쪽으로
/// 보내는데, **이 함수 하나가 그 방향을 결정하므로 platform 간 갈래가 되지
/// 않는다** (이전에는 renderer 마다 tie 방향이 달랐다).
///
/// **`f64` 로 계산하는 이유.** `src`·`dst` 가 `u8` 이고 `alpha` 가 `f32` 이면 곱과
/// 합이 `f64` 안에서 **오차 없이** 떨어진다 (필요 비트 ~40 < 53). `f32` 로 하면
/// 곱 결과가 `f32` 격자로 반올림되면서 정확값이 `x.5` 가 아닌데도 tie 로 보이는
/// 경우가 생겨 (예: `245 × (1−0.3f)` 는 정확히 `171.4999970…` 인데 `f32` 에서는
/// `171.5`) 반올림 방향이 뒤집힌다.
pub fn blendOverU8(src: u8, dst: u8, alpha: f32) u8 {
    const a: f64 = alpha;
    const s: f64 = @floatFromInt(src);
    const d: f64 = @floatFromInt(dst);
    const mixed = s * a + d * (1.0 - a);
    return @intFromFloat(@round(@max(0.0, @min(255.0, mixed))));
}

/// [`blendOverU8`] 을 3 채널에 적용. 합성은 채널 독립이다.
pub fn blendOverRgb(src: [3]u8, dst: [3]u8, alpha: f32) [3]u8 {
    return .{
        blendOverU8(src[0], dst[0], alpha),
        blendOverU8(src[1], dst[1], alpha),
        blendOverU8(src[2], dst[2], alpha),
    };
}

/// scrollbar thumb 색 — **섞는 색을 배경 명도로 뒤집는다** (#346).
///
/// 이전에는 흰색 고정이었고 주석이 *"어떤 배경 위에서도 살짝 보임"* 이라고
/// 적었지만 성립하지 않았다. 흰 배경에 흰색을 30% 섞으면 아무 일도 일어나지
/// 않아 밝은 테마 4종에서 대비가 **1.02~1.04** 로 소멸했다. 어두운 배경엔
/// 흰색, 밝은 배경엔 검정을 섞어 18종 전부에서 **2.09 이상**을 확보한다
/// (어두운 14종 2.465~2.713 / 밝은 4종 2.087~2.102).
///
/// `dark` 는 [`themes.isDarkRgb`](themes.zig) 의 결과를 받는다 — 명도 판정의
/// 단일 정의를 그 모듈에 두고 여기선 결과만 쓴다. `chrome_palette.derive` 와
/// 같은 패턴이며, 덕분에 이 모듈이 ghostty 에 의존하지 않는다.
///
/// 판정 입력은 **terminal 의 현재 배경** (`RenderState.Colors.background`) 이다 —
/// OSC 11 과 `reverse_colors` 가 반영된 실효 배경이다. 탭바 chrome 은 config
/// theme 배경을 쓰지만 (#335) thumb 은 chrome 이 아니라 terminal 표면 *위에*
/// 얹히므로 그 면을 따른다. config theme 를 기준으로 두면 셸이 OSC 11 로 명도를
/// 뒤집는 순간 thumb 이 다시 소멸한다. #266 의 color scheme DSR 도 같은 기준
/// (terminal 의 현재 배경) 을 쓴다.
///
/// 알려진 귀결 — 배경이 **중간 명도**면 어느 쪽을 섞어도 대비가 낮다
/// (`#808080` 에서 1.62 / 1.76). 내장 테마 18종에는 그런 배경이 없어 실사용에서는
/// 걸리지 않지만 OSC 11 로는 가능하다. 대비를 모든 배경에서 일정하게 고정하려면
/// `chrome_palette` 의 파생식이 필요한데, #346 은 최소 변경을 택했다.
///
/// **`bg` 와 미리 합성한 solid 를 돌려준다** (#353) — 세 renderer 는 이 값을 알파
/// 1.0 으로 그린다. 이전에는 알파를 그대로 넘겨 renderer 마다 다른 규칙으로
/// 합성했고 값이 갈렸다 (`blendOverU8` 주석 참고). thumb 은 격자 밖 (#350 이
/// scrollbar 자리를 항상 비운다) 이라 밑에 cell 이 오지 않으므로 solid 로 바꿔도
/// 시각적 손실이 없다.
pub fn scrollbarColor(bg: [3]u8, dark: bool) [3]u8 {
    const src: u8 = if (dark) 255 else 0;
    return blendOverRgb(.{ src, src, src }, bg, SCROLLBAR_ALPHA);
}

// 탭바 — Windows `d3d11_renderer.zig` 의 TAB_* 상수와 같은 디자인 (시각 일관성).
pub const TAB_BAR_HEIGHT_PT: u32 = 28;
/// 터미널 콘텐츠 font와 독립된 탭 제목 logical size. 같은 font family/fallback을
/// 사용하되 terminal의 `font.size_point` 변경에는 영향받지 않는다.
pub const TAB_LABEL_FONT_PT: u32 = 13;
/// Linux custom dialog typography (#306). Family/fallback stays aligned with
/// the terminal, while size remains independent from terminal font settings.
pub const DIALOG_BODY_FONT_PT: u32 = 15;
pub const DIALOG_TITLE_FONT_PT: u32 = 18;
/// Dialog action controls use logical points. Native backends convert this
/// through their current screen scale (AppKit does so automatically).
pub const DIALOG_ACTION_BUTTON_HEIGHT_PT: u32 = 48;
/// 안내·오류·확인·prompt·About에 공통으로 표시하는 TildaZ 앱 아이콘.
/// Linux와 Windows는 이 logical 크기에 현재 scale/DPI를 곱하고, macOS는
/// NSAlert가 bundle icon을 native 크기로 배치한다.
pub const DIALOG_ICON_SIZE_PT: u32 = 64;
pub const DIALOG_ICON_GAP_PT: u32 = 8;

/// `docs/style.css --brand-orange` / `docs/favicon.svg`와 같은 dialog accent.
/// platform backend는 이 RGB를 native color 형식으로 변환해 사용한다.
pub const DIALOG_SEPARATOR_COLOR = .{ .r = 0xF7, .g = 0xA4, .b = 0x1D };
pub const DIALOG_SEPARATOR_THICKNESS_PT: u32 = 2;
/// Dialog는 preferred 폭 안에서 먼저 실제 wrap 높이를 측정한다. 고정 chrome을
/// 포함해 현재 screen 높이를 넘을 때만 maximum 폭으로 확장한 뒤 다시 측정한다.
pub const DIALOG_PREFERRED_WIDTH_PT: u32 = 580;
/// 긴 절대경로에서도 screen 전체 폭을 차지하지 않게 하는 logical 최대 폭.
pub const DIALOG_MAX_WIDTH_PT: u32 = 960;
pub const DIALOG_SCROLLBAR_GAP_PT: u32 = 8;
pub const TAB_WIDTH_PT: u32 = 150;
pub const TAB_PADDING_PT: u32 = 6;
/// 컨트롤 hover 박스의 네 방향 inset(2pt)과 탭 제목 x offset 의 근원 gap.
/// #334 개편 전에는 탭 배경 사각형의 상하/좌우 inset 으로도 쓰였으나, 탭
/// 배경이 탭바와 통일되며 그 용도는 사라졌다 (`tab_vertical_inset` 제거).
pub const TAB_GAP_PT: u32 = 2;

pub const TabGapPx = struct {
    tab_horizontal_inset: f32,
    control_hover_inset: f32,
};

/// logical gap을 현재 화면 scale에 맞는 physical pixel inset으로 변환한다.
pub fn tabGapPx(scale: f32) TabGapPx {
    const gap_px = scaledPxF(TAB_GAP_PT, scale);
    return .{
        .tab_horizontal_inset = gap_px / 2.0,
        .control_hover_inset = gap_px,
    };
}

// ── chrome 색 anchor (#335) ─────────────────────────────────────────
// 아래 9개 색 상수는 **anchor** 다 — Tilda (순수 검정) 배경에서의 값이고 #334 /
// #342 가 시연으로 확정했다. renderer 는 이 상수를 직접 참조하지 않고
// [`chrome_palette.derive`](chrome_palette.zig) 가 현재 theme 배경으로 옮긴 결과를
// 쓴다. bg = 검정이면 파생 결과가 anchor 와 같으므로 Tilda 는 아래 값 그대로다.
//
// 모두 **8-bit 격자 위의 값**을 `N.0/255.0` 으로 적는다 (파생이 anchor 를 8-bit 로
// 확정해 쓰므로 격자에서 벗어나면 Tilda 재현이 어긋난다). 예전에 `0.25` / `0.92`
// 처럼 소수로 적힌 상수는 Linux 의 truncate 와 GPU 의 round 가 1/255 갈렸는데
// (`MENU_HOVER_BG` 63 vs 64 등), 8-bit 로 적으면서 세 platform 이 같아졌다.
//
// amber accent (`TAB_ACCENT_COLOR`) 는 브랜드 색이라 파생하지 않는다 — 2026-07-28
// 사용자 확정. 밝은 theme 에서 밑줄 대비가 1.35~1.46 으로 낮아지는 것은 알려진 귀결.

/// 탭바 배경 = 모든 탭(활성 포함)의 배경 (#334 2026-07-22 결정 — Tilda 문법).
/// 이전의 "활성 탭만 밝은 회색 + 비활성은 terminal 배경(#282)" 정책을 대체:
/// 탭바 전체가 하나의 회색 띠가 되고, 활성 탭은 amber 밑줄로만 구분한다.
/// 33/35/38 은 사용자가 Tilda(Breeze dark)에서 실측한 값 — 순수 중성 회색
/// (52/52/52)은 상대적으로 따뜻하게(갈색 끼) 보였고, 살짝 파란 끼의 이
/// 회색이 더 예쁘다는 사용자 확정 (2026-07-22).
pub const TAB_BAR_BG: [4]f32 = .{ 33.0 / 255.0, 35.0 / 255.0, 38.0 / 255.0, 1.0 };
/// #334 — 탭 사이 세로 구분선 색 (두께는 `TAB_SEPARATOR_W_PT`). 탭과 탭바가
/// 같은 색이라 경계는 명시적인 선으로. drag 재배열 중 빈 원위치 슬롯도 이
/// 구분선 + 제목 부재로 인지한다. command menu 의 테두리·내부 구분선도 같은
/// 값을 참조한다 (2026-07-22 "메뉴는 탭바와 한 문법" 결정).
///
/// #342 (2026-07-27) — 100/100/106 → 79/79/84. 100 은 탭바 배경이 52/255 이던
/// 튜닝 라운드의 값인데, 그 뒤 배경만 33/35/38 로 내려가고 이 값은 남아 대비가
/// 2.12 → 2.68 로 저절로 올라가 있었다. 79/79/84 는 1.93.
pub const TAB_SEPARATOR_COLOR: [4]f32 = .{ 79.0 / 255.0, 79.0 / 255.0, 84.0 / 255.0, 1.0 };
/// #334 — 활성 탭 하단 accent 밑줄. TildaZ amber (#F7A41D) — dialog 구분선
/// (`DIALOG_SEPARATOR_COLOR`) 과 같은 색으로 "강조 = amber" 문법 통일.
/// 같은 제목 탭이 흔한 터미널에서 배경 밝기 차이만으로는 활성 탭이 곁눈에
/// 안 들어와 accent 밑줄로 보강 (Tilda 의 파란 밑줄과 같은 자리).
pub const TAB_ACCENT_COLOR: [4]f32 = .{ 247.0 / 255.0, 164.0 / 255.0, 29.0 / 255.0, 1.0 };
/// #334 — 활성 탭 amber 밑줄 두께 (logical pt). 활성 탭 슬롯 구간에만 얹힌다.
/// #342 로 가로 경계선이 사라져 탭바 **맨 아래 모서리**에 붙는다 (이전에는
/// 경계선 바로 위). 좌우 끝은 세로 구분선이 덮는다 — 아래 `TAB_SEPARATOR_W_PT`.
pub const TAB_ACTIVE_UNDERLINE_PT: u32 = 2;
/// #342 — 탭 사이 세로 구분선 두께 (logical pt). 색은 `TAB_SEPARATOR_COLOR`.
///
/// #334 의 `TAB_BOTTOM_BORDER_PT` 를 이름만 바꾼 것이다. 원래 탭바-터미널 가로
/// 경계선 두께였고 세로 구분선이 그 값을 빌려 썼는데, 가로 경계선이 제거되며
/// (2026-07-27 사용자 결정) 세로선 전용이 됐다. 이름이 남으면 없는 요소를
/// 가리키게 되므로 함께 정리.
pub const TAB_SEPARATOR_W_PT: u32 = 1;
/// #334 — command menu 스크롤 표시 chevron 의 비트맵 한 변 (logical pt).
/// 탭바 아이콘(10pt)보다 크게 — 메뉴 폭에 어울리는 납작한 꺾쇠.
pub const MENU_INDICATOR_ICON_PT: u32 = 14;
// command menu 색 (#329/#334) — 배경은 `TAB_BAR_BG`, 테두리/구분선은
// `TAB_SEPARATOR_COLOR` 를 그대로 재사용 (탭바와 한 문법, 2026-07-22 사용자
// 확정). 아래 셋은 메뉴 고유 값 — 세 renderer 가 이 상수만 참조한다.
/// 메뉴 항목의 hover / keyboard focus 강조 배경.
pub const MENU_HOVER_BG: [4]f32 = .{ 64.0 / 255.0, 64.0 / 255.0, 71.0 / 255.0, 1.0 };
/// 메뉴 항목 label 텍스트 색.
pub const MENU_LABEL_COLOR: [4]f32 = .{ 235.0 / 255.0, 235.0 / 255.0, 240.0 / 255.0, 1.0 };
/// 메뉴 우측 단축키 hint 색 — label 보다 어둡게 (독립 값).
pub const MENU_HINT_COLOR: [4]f32 = .{ 166.0 / 255.0, 166.0 / 255.0, 173.0 / 255.0, 1.0 };
/// 탭 텍스트 색 (180/255 ≈ 0.706). Windows `TAB_TEXT_R` 와 동일.
pub const TAB_TEXT_COLOR: [4]f32 = .{ 180.0 / 255.0, 180.0 / 255.0, 180.0 / 255.0, 1.0 };

// 탭바 컨트롤 버튼 (#117 — Firefox 패턴). width < height 로 살짝 세로 길쭉
// (탭바 height 28 vs width 24) — 가로 넓적하지 않은 chevron 느낌.
/// `<` / `>` 좌우 스크롤 화살표. 탭 viewport 가 탭으로 가득 차야 양 끝에 등장.
/// 한 번 클릭에 1 탭 너비씩 viewport 이동.
pub const TAB_ARROW_W_PT: u32 = 24;
/// `+` 새 탭 버튼. #329부터 우측 고정 클러스터는 `[+][×][…]` 순서.
/// MAX_TABS 도달 시에도 자리 유지 — 비활성 색 + click noop (2026-07-22 결정).
pub const TAB_PLUS_W_PT: u32 = 24;
/// `×` 활성 탭 닫기 버튼 — 우측 고정 클러스터의 가운데 자리.
/// per-tab close 를 대체: 탭 전환 클릭과 물리적으로 분리해 misclick 방지.
pub const TAB_CLOSE_W_PT: u32 = 24;
/// `…` command/shortcut menu 버튼 — 우측 고정 클러스터의 최우측 자리.
pub const TAB_MORE_W_PT: u32 = 24;
/// 활성 화살표 / `+` 색 — 탭 텍스트보다 더 밝게 (강조).
pub const TAB_CTRL_ACTIVE_COLOR: [4]f32 = .{ 242.0 / 255.0, 242.0 / 255.0, 242.0 / 255.0, 1.0 };
/// 탭바 컨트롤 버튼 hover 배경 (#268 2b — VSCode 패턴의 은은한 밝은 박스).
/// 어두운 탭바 배경 위에서만 살짝 떠 보이는 밝기.
///
/// #335 — 이전엔 `{ 1, 1, 1, 0.12 }` (흰색 12% 알파) 였다. 파생이 anchor 를 색으로
/// 받아야 하므로 **합성 결과 solid** 로 바꿨다. 값은 세 platform 이 실제로 그리던
/// 것과 같다 — 블렌드가 gamma space 에서 일어나기 때문이다 (Windows swapchain
/// `DXGI_FORMAT_B8G8R8A8_UNORM` = `_SRGB` 아님 · macOS layer pixelFormat 80
/// `BGRA8Unorm` · Linux `blendU8` 이 u8 값에서 혼합). linear space 였다면
/// `102/103/105` 였을 것이므로 확인이 필요했다.
///
/// 단 Linux 만 `@intFromFloat` 로 truncate 해 `59.64 → 59` 였다 (R 채널 1 낮음).
/// 이제 세 platform 이 같은 `60` 을 쓴다.
pub const TAB_CTRL_HOVER_BG: [4]f32 = .{ 60.0 / 255.0, 61.0 / 255.0, 64.0 / 255.0, 1.0 };
/// 비활성 화살표 (더 갈 곳 없음) 의 색 — 활성과 명확히 구분되도록 어둡지만
/// 너무 어둡지 않게. Firefox 의 disabled chevron 과 동등 시각.
pub const TAB_ARROW_DISABLED_COLOR: [4]f32 = .{ 102.0 / 255.0, 102.0 / 255.0, 102.0 / 255.0, 1.0 };

// 탭바 컨트롤 아이콘 (`< > + × …`) 절차적 그리기 (#199 / #268 / #329) — 폰트 독립.
// `src/tab_icons.zig` 가 선분 geometry 를 알파 커버리지 비트맵으로 rasterize,
// 세 renderer 가 같은 비트맵을 glyph 처럼 그림 (세 platform 픽셀 동일).
/// 아이콘 한 변 (bounding square). 버튼 box (24pt) 안에 여백 두고 들어가는 크기.
pub const TAB_ICON_SIZE_PT: u32 = 10;
/// 아이콘 선 두께 (pt). `pt × scale` 로 px 두께. AA 로 fractional scale 도 또렷.
pub const TAB_ICON_STROKE_PT: f32 = 1.5;
/// `…`의 점은 같은 1.5pt stroke로 그리면 `+`/`×`보다 가늘어 보이므로
/// diameter만 별도로 광학 보정한다.
pub const TAB_MORE_DOT_DIAMETER_PT: f32 = 2.2;

pub fn tabLabelFontSpec() font_spec.Spec {
    return .{
        .size_logical = @floatFromInt(TAB_LABEL_FONT_PT),
        .cell_width_ratio = 1.0,
        .line_height_ratio = 1.0,
    };
}

pub fn dialogBodyFontSpec() font_spec.Spec {
    return .{
        .size_logical = @floatFromInt(DIALOG_BODY_FONT_PT),
        .cell_width_ratio = 1.0,
        .line_height_ratio = 1.1,
    };
}

pub fn dialogTitleFontSpec() font_spec.Spec {
    return .{
        .size_logical = @floatFromInt(DIALOG_TITLE_FONT_PT),
        .cell_width_ratio = 1.0,
        .line_height_ratio = 1.1,
    };
}

pub fn tabBarHeightPx(scale: f32) u32 {
    return scaledPx(u32, TAB_BAR_HEIGHT_PT, scale);
}

test "tab gap scales from logical points to physical pixels" {
    const Case = struct {
        scale: f32,
        horizontal: f32,
        vertical: f32,
    };
    const cases = [_]Case{
        .{ .scale = 1.0, .horizontal = 1.0, .vertical = 2.0 },
        .{ .scale = 1.5, .horizontal = 1.5, .vertical = 3.0 },
        .{ .scale = 1.7, .horizontal = 1.7, .vertical = 3.4 },
        .{ .scale = 2.0, .horizontal = 2.0, .vertical = 4.0 },
    };

    for (cases) |case| {
        const gap = tabGapPx(case.scale);
        try std.testing.expectApproxEqAbs(case.horizontal, gap.tab_horizontal_inset, 0.0001);
        try std.testing.expectApproxEqAbs(case.vertical, gap.control_hover_inset, 0.0001);
    }
}

test "tab label font uses a fixed logical size" {
    const spec = tabLabelFontSpec();
    try std.testing.expectEqual(@as(f32, @floatFromInt(TAB_LABEL_FONT_PT)), spec.size_logical);
    try std.testing.expectEqual(@as(f32, 1.0), spec.cell_width_ratio);
    try std.testing.expectEqual(@as(f32, 1.0), spec.line_height_ratio);
}

test "dialog fonts use fixed 15pt body and 18pt title sizes" {
    const body = dialogBodyFontSpec();
    const title = dialogTitleFontSpec();
    try std.testing.expectEqual(@as(f32, 15.0), body.size_logical);
    try std.testing.expectEqual(@as(f32, 18.0), title.size_logical);
    try std.testing.expectEqual(@as(f32, 1.0), body.cell_width_ratio);
    try std.testing.expectEqual(@as(f32, 1.1), body.line_height_ratio);
    try std.testing.expectEqual(@as(f32, 1.0), title.cell_width_ratio);
    try std.testing.expectEqual(@as(f32, 1.1), title.line_height_ratio);
}

test "dialog icon uses common logical size and gap" {
    try std.testing.expectEqual(@as(u32, 48), DIALOG_ACTION_BUTTON_HEIGHT_PT);
    try std.testing.expectEqual(@as(u32, 64), DIALOG_ICON_SIZE_PT);
    try std.testing.expectEqual(@as(u32, 8), DIALOG_ICON_GAP_PT);
    try std.testing.expectEqual(@as(u8, 0xF7), DIALOG_SEPARATOR_COLOR.r);
    try std.testing.expectEqual(@as(u8, 0xA4), DIALOG_SEPARATOR_COLOR.g);
    try std.testing.expectEqual(@as(u8, 0x1D), DIALOG_SEPARATOR_COLOR.b);
    try std.testing.expectEqual(@as(u32, 2), DIALOG_SEPARATOR_THICKNESS_PT);
    try std.testing.expectEqual(@as(u32, 580), DIALOG_PREFERRED_WIDTH_PT);
    try std.testing.expectEqual(@as(u32, 960), DIALOG_MAX_WIDTH_PT);
}

test "tab bar height uses common rounded physical pixels" {
    try std.testing.expectEqual(@as(u32, 28), tabBarHeightPx(1.0));
    try std.testing.expectEqual(@as(u32, 42), tabBarHeightPx(1.5));
    try std.testing.expectEqual(@as(u32, 48), tabBarHeightPx(1.7));
    try std.testing.expectEqual(@as(u32, 56), tabBarHeightPx(2.0));
}

test "#335 chrome 색 anchor 는 8-bit 격자 위에 있다" {
    // `chrome_palette` 가 anchor 를 8-bit 로 확정해 파생하므로, 격자에서 벗어난
    // 값이 섞이면 Tilda 재현이 1/255 어긋난다.
    const anchors = [_][4]f32{
        TAB_BAR_BG,            TAB_SEPARATOR_COLOR,      TAB_TEXT_COLOR,
        TAB_CTRL_ACTIVE_COLOR, TAB_ARROW_DISABLED_COLOR, TAB_CTRL_HOVER_BG,
        MENU_HOVER_BG,         MENU_LABEL_COLOR,         MENU_HINT_COLOR,
    };
    for (anchors) |a| {
        try std.testing.expectEqual(@as(f32, 1.0), a[3]);
        for (a[0..3]) |c| {
            const scaled = c * 255.0;
            try std.testing.expectApproxEqAbs(@round(scaled), scaled, 1e-3);
        }
    }
}

test "#329 three-button cluster uses single common metrics" {
    try std.testing.expectEqual(@as(u32, 24), TAB_PLUS_W_PT);
    try std.testing.expectEqual(@as(u32, 24), TAB_CLOSE_W_PT);
    try std.testing.expectEqual(@as(u32, 24), TAB_MORE_W_PT);
    try std.testing.expectEqual(@as(u32, 72), TAB_PLUS_W_PT + TAB_CLOSE_W_PT + TAB_MORE_W_PT);
}

test "#350 격자 열 수가 scrollbar 자리를 비운다" {
    // Windows scale 1.0 실측 환경: client 960 / pad 6 / scrollbar 10 / cell 9.
    // 이전 식 `(960 - 12) / 9` 은 105 였고 셀이 x 6..950 까지 가서 scrollbar
    // (x 950..959) 와 x=950 한 열이 겹쳤다. 이제 104 로 x 6..942 에서 끝난다.
    try std.testing.expectEqual(@as(u16, 104), terminalCols(960, 6, 10, 9));
    try std.testing.expectEqual(@as(u16, 105), @as(u16, @intCast(@divTrunc(960 - 2 * 6, 9)))); // 이전 식 (회귀 근거)

    // 열 오른쪽 끝이 hit-test 경계 (`viewport − pad − SCROLLBAR_W`) 를 넘지 않는다.
    // hit-test 는 `x >= w - pad - SCROLLBAR_W` 를 셀 밖으로 처리한다.
    const cases = [_][4]i64{
        // viewport, pad, scrollbar_w, cell_w
        .{ 960, 6, 10, 9 },    .{ 960, 9, 15, 14 },   .{ 1920, 6, 10, 9 },
        .{ 3024, 12, 20, 19 }, .{ 1029, 10, 17, 15 }, .{ 800, 6, 10, 8 },
    };
    for (cases) |c| {
        const cols = terminalCols(c[0], c[1], c[2], c[3]);
        const right_edge = c[1] + @as(i64, cols) * c[3];
        try std.testing.expect(right_edge <= c[0] - c[1] - c[2]);
    }

    // 창이 극단적으로 좁아도 최소 1 열, cell_w 0 도 안전.
    try std.testing.expectEqual(@as(u16, 1), terminalCols(20, 6, 10, 9));
    try std.testing.expectEqual(@as(u16, 1), terminalCols(0, 6, 10, 9));
    try std.testing.expectEqual(@as(u16, 1), terminalCols(960, 6, 10, 0));
    // scrollbar 를 빼면 정확히 한 열이 줄어드는 경계.
    try std.testing.expectEqual(@as(u16, 104), terminalCols(960, 6, 9, 9));
    try std.testing.expectEqual(@as(u16, 105), terminalCols(960, 6, 0, 9));
}

test "#352 격자 행 수는 탭바와 위아래 padding 을 뺀다 — terminalCols 와 대칭" {
    // 정상 케이스. 탭 2개 이상 (탭바 28) / pad 6 / cell 19.
    // (600 − 28 − 12) / 19 = 560/19 = 29.
    try std.testing.expectEqual(@as(u16, 29), terminalRows(600, 28, 6, 19));
    // 단일 탭이면 호출처가 tab_bar_h = 0 을 준다 (#127) → 한 행 이상 늘어난다.
    try std.testing.expectEqual(@as(u16, 30), terminalRows(600, 0, 6, 19));

    // 대칭 확인 — 열 수가 scrollbar 를 빼는 자리에 행 수는 탭바를 뺀다.
    // 같은 숫자를 넣으면 같은 값이 나와야 한다.
    try std.testing.expectEqual(terminalCols(600, 6, 28, 19), terminalRows(600, 28, 6, 19));
}

test "#352 행 수의 경계 4케이스 — 세 platform 의 갈린 방어가 한 함수로 수렴한다" {
    // #352 본문의 표를 그대로 고정한다. 통합 전에는 Linux 가 분자를 cell_h 로
    // clamp, Windows 가 분자를 1 로 clamp, macOS 가 명시 if guard 로 각각 막았고
    // 결과만 같았다.
    const cell: i64 = 19;

    // ① usable ≥ cell (정상)
    try std.testing.expectEqual(@as(u16, 2), terminalRows(28 + 12 + 2 * cell, 28, 6, cell));
    // ② 1 ≤ usable < cell → 1
    try std.testing.expectEqual(@as(u16, 1), terminalRows(28 + 12 + 1, 28, 6, cell));
    // ③ usable == 0 → 1
    try std.testing.expectEqual(@as(u16, 1), terminalRows(28 + 12, 28, 6, cell));
    // ④ usable < 0 → 1. macOS 는 u32 라 이 자리에서 wrap 하면 거대한 rows 가 됐다.
    try std.testing.expectEqual(@as(u16, 1), terminalRows(0, 28, 6, cell));
    try std.testing.expectEqual(@as(u16, 1), terminalRows(10, 28, 6, cell));

    // cell_h <= 0 방어 — Windows 만 갖고 있던 guard (도달 불가지만 계약으로 고정).
    try std.testing.expectEqual(@as(u16, 1), terminalRows(600, 28, 6, 0));
    try std.testing.expectEqual(@as(u16, 1), terminalRows(600, 28, 6, -5));

    // u16 상한 clamp — Linux 만 갖고 있었다.
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), terminalRows(1 << 40, 0, 0, 1));
}

test "#352 행 수는 호출처 정수 타입과 무관하다" {
    // 세 platform 이 각자 다른 타입을 쓴다 — Linux i32 / Windows c_int / macOS u32.
    // i64 인자라 캐스팅 없이 들어오고 결과가 같아야 한다.
    const vp_h_i32: i32 = 600;
    const vp_h_u32: u32 = 600;
    const vp_h_cint: c_int = 600;
    const tab_i32: i32 = 28;
    const pad_u32: u32 = 6;
    const cell_cint: c_int = 19;

    const expect: u16 = 29;
    try std.testing.expectEqual(expect, terminalRows(vp_h_i32, tab_i32, pad_u32, cell_cint));
    try std.testing.expectEqual(expect, terminalRows(vp_h_u32, tab_i32, pad_u32, cell_cint));
    try std.testing.expectEqual(expect, terminalRows(vp_h_cint, tab_i32, pad_u32, cell_cint));

    // 부호 없는 viewport 가 탭바+padding 보다 작아도 wrap 하지 않는다 (macOS 경로).
    const tiny: u32 = 10;
    try std.testing.expectEqual(@as(u16, 1), terminalRows(tiny, tab_i32, pad_u32, cell_cint));
}

test "#346 scrollbar thumb — 섞는 색이 배경 명도로 뒤집힌다" {
    // 어두운 배경엔 흰색을 30% → 밝아진다.
    try std.testing.expectEqual([3]u8{ 77, 77, 77 }, scrollbarColor(.{ 0, 0, 0 }, true));
    // 밝은 배경엔 검정을 30% → 어두워진다. (흰색을 섞으면 250 → 252 로 소멸했다.)
    try std.testing.expectEqual([3]u8{ 175, 175, 175 }, scrollbarColor(.{ 250, 250, 250 }, false));
    // 알파의 *의미* 는 30% 그대로다 — solid 로 바뀐 것은 renderer 에 넘기는 형태다.
    try std.testing.expectEqual(@as(f32, 0.3), SCROLLBAR_ALPHA);
}

test "#353 알파 합성은 한 곳에서 최근접 반올림 — f32 로 계산하면 갈리는 자리를 고정한다" {
    // 경계 — 알파 0 은 배경 그대로, 1 은 src 그대로.
    try std.testing.expectEqual(@as(u8, 200), blendOverU8(50, 200, 0.0));
    try std.testing.expectEqual(@as(u8, 50), blendOverU8(50, 200, 1.0));
    // clamp — 255 를 넘거나 0 아래로 가지 않는다.
    try std.testing.expectEqual(@as(u8, 255), blendOverU8(255, 255, 0.3));
    try std.testing.expectEqual(@as(u8, 0), blendOverU8(0, 0, 0.3));

    // **f64 로 계산해야 맞는 자리.** `(1−0.3f) × 245` 의 정확값은 171.4999970… 라
    // 최근접이 171 인데, f32 로 곱하면 결과가 f32 격자의 171.5 로 반올림돼 tie 처럼
    // 보이고 172 가 된다. 이 단언이 그 갈래를 고정한다 (Catppuccin Latte 의 B 채널).
    try std.testing.expectEqual(@as(u8, 171), blendOverU8(0, 245, 0.3));
    // 같은 이유로 Catppuccin Latte 전체가 #A7A9AB 다.
    try std.testing.expectEqual([3]u8{ 0xA7, 0xA9, 0xAB }, scrollbarColor(.{ 0xEF, 0xF1, 0xF5 }, false));

    // **런타임 알파도 같은 helper 를 탄다** — box-drawing AA 의 `cov` 는 셀 크기에
    // 따라 픽셀별로 계산되는 값이지만 상수일 필요가 없다. `cov == 1` 인 crisp rect 는
    // 합성 결과가 `fg` 그대로여서 픽셀이 안 바뀌는 것을 고정한다.
    try std.testing.expectEqual(@as(u8, 200), blendOverU8(200, 30, 1.0));
    try std.testing.expectEqual([3]u8{ 10, 20, 30 }, blendOverRgb(.{ 10, 20, 30 }, .{ 200, 200, 200 }, 1.0));
    // 중간 coverage 는 정확값의 최근접 — cov 0.5 로 fg 255 를 bg 0 에 얹으면 127.5 →
    // `@round` 가 0 에서 먼 쪽으로 보내 128.
    try std.testing.expectEqual(@as(u8, 128), blendOverU8(255, 0, 0.5));

    // 채널 독립 — rgb 버전이 채널별 결과와 같다.
    const rgb = blendOverRgb(.{ 10, 20, 30 }, .{ 200, 210, 220 }, 0.3);
    try std.testing.expectEqual(blendOverU8(10, 200, 0.3), rgb[0]);
    try std.testing.expectEqual(blendOverU8(20, 210, 0.3), rgb[1]);
    try std.testing.expectEqual(blendOverU8(30, 220, 0.3), rgb[2]);
}

/// 내장 theme 18종의 배경 — `themes.zig` 와 같은 값. 이 모듈은 ghostty 에
/// 의존하지 않아야 해서 (`chrome_palette` 가 이 모듈을 참조한다) 값을 직접 적고,
/// `dark` 도 `themes.isDarkRgb` 의 결과를 리터럴로 둔다. `chrome_palette.zig` 의
/// `test_themes` 와 같은 집합·같은 패턴이다.
const sb_test_themes = [_]struct { name: []const u8, bg: [3]u8, dark: bool }{
    .{ .name = "Tilda", .bg = .{ 0x00, 0x00, 0x00 }, .dark = true },
    .{ .name = "Ghostty", .bg = .{ 0x1d, 0x1f, 0x21 }, .dark = true },
    .{ .name = "Windows Terminal", .bg = .{ 0x0c, 0x0c, 0x0c }, .dark = true },
    .{ .name = "Catppuccin Mocha", .bg = .{ 0x1e, 0x1e, 0x2e }, .dark = true },
    .{ .name = "Dracula", .bg = .{ 0x28, 0x2a, 0x36 }, .dark = true },
    .{ .name = "Gruvbox Dark", .bg = .{ 0x28, 0x28, 0x28 }, .dark = true },
    .{ .name = "Tokyo Night", .bg = .{ 0x1a, 0x1b, 0x26 }, .dark = true },
    .{ .name = "Nord", .bg = .{ 0x2e, 0x34, 0x40 }, .dark = true },
    .{ .name = "One Half Dark", .bg = .{ 0x28, 0x2c, 0x34 }, .dark = true },
    .{ .name = "Solarized Dark", .bg = .{ 0x00, 0x1e, 0x27 }, .dark = true },
    .{ .name = "Monokai Soda", .bg = .{ 0x1a, 0x1a, 0x1a }, .dark = true },
    .{ .name = "Rose Pine", .bg = .{ 0x19, 0x17, 0x24 }, .dark = true },
    .{ .name = "Kanagawa", .bg = .{ 0x1f, 0x1f, 0x28 }, .dark = true },
    .{ .name = "Everforest Dark", .bg = .{ 0x1e, 0x23, 0x26 }, .dark = true },
    .{ .name = "Catppuccin Latte", .bg = .{ 0xef, 0xf1, 0xf5 }, .dark = false },
    .{ .name = "Solarized Light", .bg = .{ 0xfd, 0xf6, 0xe3 }, .dark = false },
    .{ .name = "Gruvbox Light", .bg = .{ 0xfb, 0xf1, 0xc7 }, .dark = false },
    .{ .name = "One Half Light", .bg = .{ 0xfa, 0xfa, 0xfa }, .dark = false },
};

fn sbSrgbToLinear(v: f64) f64 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
}

fn sbLuminance(c: [3]f64) f64 {
    var l: [3]f64 = undefined;
    for (0..3) |i| l[i] = sbSrgbToLinear(c[i] / 255.0);
    return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2];
}

fn sbContrast(a: [3]f64, b: [3]f64) f64 {
    const la = sbLuminance(a);
    const lb = sbLuminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

test "#346 thumb 이 18종 theme 배경 전부에서 대비 2.0 이상" {
    // 이전 흰색 고정 방식은 밝은 4종에서 1.02~1.04 로 소멸했다. 실측 최소는
    // 어두운 쪽 2.465 (Tilda) / 밝은 쪽 2.087 (Gruvbox Light) 이므로 하한 2.0.
    for (sb_test_themes) |t| {
        // #353 — 합성은 `scrollbarColor` 가 이미 했다. 테스트가 renderer 의 합성을
        // 흉내낼 필요가 없어졌다 (그게 platform 마다 갈렸던 지점이다).
        const thumb = scrollbarColor(t.bg, t.dark);
        const bg = [3]f64{
            @floatFromInt(t.bg[0]),
            @floatFromInt(t.bg[1]),
            @floatFromInt(t.bg[2]),
        };
        const mixed = [3]f64{
            @floatFromInt(thumb[0]),
            @floatFromInt(thumb[1]),
            @floatFromInt(thumb[2]),
        };
        const cr = sbContrast(mixed, bg);
        std.testing.expect(cr >= 2.0) catch |err| {
            std.debug.print("theme {s}: contrast {d:.3} < 2.0\n", .{ t.name, cr });
            return err;
        };
    }
}

test "#353 Tilda thumb 은 77 — 정확값이 0.5 를 넘기 때문이다" {
    // `0.3` 은 f32 로 정확히 표현되지 않아 `0.30000001192…` 이고, ×255 의 정확값은
    // **76.50000303983688** 로 0.5 를 살짝 넘는다. 따라서 최근접은 77 이다.
    //
    // 이 자리가 세 platform 이 갈렸던 대표 지점이다 — 이전에는 Linux 가 76 (f32 곱
    // 후 버림), Windows 가 76 (알파를 8bit 76 으로 양자화), macOS 만 77 (고정밀 곱 +
    // 최근접) 이었다. 합성을 한 곳으로 모은 뒤로 셋 다 77 이다 (#353).
    try std.testing.expectEqual([3]u8{ 77, 77, 77 }, scrollbarColor(.{ 0, 0, 0 }, true));
    // f32 로 곱하면 정확히 76.5 가 되어 tie 로 보이고, 버림 renderer 는 76 을 냈다.
    try std.testing.expectEqual(@as(u8, 77), blendOverU8(255, 0, SCROLLBAR_ALPHA));
}

test "#350 pt→px 변환은 세 platform 공통 — 반올림, 타입 무관" {
    // 이 이슈 이전에는 macOS `host/macos.zig` 9곳만 버림이었고 나머지 18곳은
    // 반올림이었다. 통일된 규칙이 반올림임을 고정한다.
    try std.testing.expectEqual(@as(u32, 10), scaledPx(u32, TERMINAL_PADDING_PT, 1.7)); // 10.2 → 10
    try std.testing.expectEqual(@as(u32, 17), scaledPx(u32, SCROLLBAR_W_PT, 1.7)); // 17.0 → 17
    try std.testing.expectEqual(@as(u32, 9), scaledPx(u32, SCROLLBAR_W_PT, 0.9)); // 9.0  → 9
    try std.testing.expectEqual(@as(u32, 8), scaledPx(u32, TERMINAL_PADDING_PT, 1.25)); // 7.5  → 8 (버림이면 7)
    try std.testing.expectEqual(@as(u32, 13), scaledPx(u32, SCROLLBAR_W_PT, 1.25)); // 12.5 → 13 (버림이면 12)

    // 정수 배율에서는 버림과 결과가 같다 — 현행 macOS(1.0/2.0) 가 픽셀 불변인 근거.
    try std.testing.expectEqual(@as(u32, 12), scaledPx(u32, TERMINAL_PADDING_PT, 2.0));
    try std.testing.expectEqual(@as(u32, 20), scaledPx(u32, SCROLLBAR_W_PT, 2.0));
    try std.testing.expectEqual(@as(u32, 300), scaledPx(u32, TAB_WIDTH_PT, 2.0));

    // 호출처가 쓰는 정수 타입을 그대로 받는다 (캐스팅을 호출처에 반복하지 않는다).
    try std.testing.expectEqual(@as(i32, 12), scaledPx(i32, TERMINAL_PADDING_PT, 2.0));
    try std.testing.expectEqual(@as(c_int, 300), scaledPx(c_int, TAB_WIDTH_PT, 2.0));

    // f32 상수도 같은 함수로 받는다.
    try std.testing.expectEqual(@as(u32, 3), scaledPx(u32, TAB_ICON_STROKE_PT, 2.0));
}

test "#357 linePx 는 선 두께를 정수로 양자화한다 — 최소 1px" {
    // 정수 배율은 이미 정수라 그대로.
    try std.testing.expectEqual(@as(f32, 1.0), linePx(TAB_SEPARATOR_W_PT, 1.0));
    try std.testing.expectEqual(@as(f32, 2.0), linePx(TAB_SEPARATOR_W_PT, 2.0));
    try std.testing.expectEqual(@as(f32, 2.0), linePx(TAB_ACTIVE_UNDERLINE_PT, 1.0));
    try std.testing.expectEqual(@as(f32, 4.0), linePx(TAB_ACTIVE_UNDERLINE_PT, 2.0));

    // 분수 배율 — 반올림. 1pt 선은 1.25 → 1, 1.7 → 2.
    try std.testing.expectEqual(@as(f32, 1.0), linePx(TAB_SEPARATOR_W_PT, 1.25));
    try std.testing.expectEqual(@as(f32, 2.0), linePx(TAB_SEPARATOR_W_PT, 1.5));
    try std.testing.expectEqual(@as(f32, 2.0), linePx(TAB_SEPARATOR_W_PT, 1.7));
    try std.testing.expectEqual(@as(f32, 2.0), linePx(TAB_SEPARATOR_W_PT, 1.75));
    // 2pt 밑줄.
    try std.testing.expectEqual(@as(f32, 3.0), linePx(TAB_ACTIVE_UNDERLINE_PT, 1.25));
    try std.testing.expectEqual(@as(f32, 3.0), linePx(TAB_ACTIVE_UNDERLINE_PT, 1.7));

    // scale 이 작아도 선이 사라지지 않는다.
    try std.testing.expectEqual(@as(f32, 1.0), linePx(TAB_SEPARATOR_W_PT, 0.1));
    try std.testing.expectEqual(@as(f32, 1.0), linePx(TAB_SEPARATOR_W_PT, 0.4));

    // 값은 항상 정수다 (반환형만 f32).
    inline for (.{ 0.5, 1.0, 1.25, 1.4, 1.5, 1.7, 1.75, 2.0, 2.5 }) |s| {
        const t = linePx(TAB_SEPARATOR_W_PT, s);
        try std.testing.expectEqual(t, @round(t));
        const u = linePx(TAB_ACTIVE_UNDERLINE_PT, s);
        try std.testing.expectEqual(u, @round(u));
    }
}

test "#357 정수 두께는 위치 소수부와 무관하게 두께가 보존된다 — 소수 두께는 갈린다" {
    // 이 테스트가 `linePx` 의 존재 이유를 고정한다. 라스터화 규칙은
    // `[round(top), round(top + t))` — `ui_rect.snap` 과 GPU 가 같다.
    const rows = struct {
        fn n(top: f32, t: f32) i32 {
            return @as(i32, @intFromFloat(@round(top + t))) - @as(i32, @intFromFloat(@round(top)));
        }
    }.n;

    // 정수 두께 — 위치 소수부 전부에서 정확히 t 픽셀.
    inline for (.{ 1.0, 2.0, 3.0 }) |t| {
        inline for (.{ 0.0, 0.05, 0.25, 0.45, 0.5, 0.55, 0.75, 0.85, 0.95 }) |frac| {
            try std.testing.expectEqual(@as(i32, @intFromFloat(t)), rows(100.0 + frac, t));
        }
    }

    // 소수 두께 1.7 (= 이전 mac/win 의 1pt @1.7) — 소수부에 따라 2px / 1px 로 갈린다.
    // #357 에서 실측한 두 구분선의 소수부가 정확히 이 두 값이었다 (0.85 / 0.55).
    try std.testing.expectEqual(@as(i32, 2), rows(102.85, 1.7));
    try std.testing.expectEqual(@as(i32, 1), rows(342.55, 1.7));
    // 같은 자리에 `linePx` 를 쓰면 둘 다 2px 로 균일해진다.
    const t17 = linePx(TAB_SEPARATOR_W_PT, 1.7);
    try std.testing.expectEqual(@as(i32, 2), rows(102.85, t17));
    try std.testing.expectEqual(@as(i32, 2), rows(342.55, t17));

    // 소수 두께 1.25 (= 이전 mac/win 의 1pt @1.25, 탭 슬롯 경계 짝/홀 phase).
    try std.testing.expectEqual(@as(i32, 2), rows(100.375, 1.25)); // 짝
    try std.testing.expectEqual(@as(i32, 1), rows(100.875, 1.25)); // 홀
    const t125 = linePx(TAB_SEPARATOR_W_PT, 1.25);
    try std.testing.expectEqual(@as(i32, 1), rows(100.375, t125));
    try std.testing.expectEqual(@as(i32, 1), rows(100.875, t125));
}

test "#376 blink 위상은 500ms 마다 뒤집히고 1초에 정확히 2번 전환된다" {
    // 위상 경계 — 0~499 는 밝게(false), 500~999 는 흐리게(true).
    try std.testing.expect(!blinkFaintPhase(0));
    try std.testing.expect(!blinkFaintPhase(499));
    try std.testing.expect(blinkFaintPhase(500));
    try std.testing.expect(blinkFaintPhase(999));
    try std.testing.expect(!blinkFaintPhase(1000));

    // **절전의 근거** — 1초 동안 전환이 정확히 2번이어야 추가 렌더가 초당 2프레임이다.
    var transitions: u32 = 0;
    var prev = blinkFaintPhase(0);
    var t: i64 = 1;
    while (t < 1000) : (t += 1) {
        const cur = blinkFaintPhase(t);
        if (cur != prev) transitions += 1;
        prev = cur;
    }
    // [0,1000) 구간 안에서는 500 에서 한 번. 다음 전환은 1000 에서 일어난다.
    try std.testing.expectEqual(@as(u32, 1), transitions);
    try std.testing.expect(blinkFaintPhase(999) != blinkFaintPhase(1000));

    // 한 주기는 1Hz — 같은 위상이 1000ms 뒤에 돌아온다.
    inline for (.{ 0, 123, 499, 500, 777, 999 }) |ms| {
        try std.testing.expectEqual(blinkFaintPhase(ms), blinkFaintPhase(ms + 2 * BLINK_HALF_PERIOD_MS));
        try std.testing.expect(blinkFaintPhase(ms) != blinkFaintPhase(ms + BLINK_HALF_PERIOD_MS));
    }

    // 벽시계라 실제 값은 크다 — 큰 수에서도 규칙이 유지되는지 (i64 오버플로 없음).
    const big: i64 = 1_754_000_000_000; // 2025-08 무렵의 milliTimestamp
    try std.testing.expect(blinkFaintPhase(big) != blinkFaintPhase(big + BLINK_HALF_PERIOD_MS));
}

test "#350 strokePx 는 최소 1px 을 보장하고 scaledPxF 는 소수를 유지한다" {
    // 선 두께는 scale 이 작아도 사라지면 안 된다.
    try std.testing.expectEqual(@as(f32, 1.0), strokePx(TAB_ICON_STROKE_PT, 0.1));
    try std.testing.expectEqual(@as(f32, 1.0), strokePx(@as(u32, 1), 0.5));
    try std.testing.expectEqual(@as(f32, 3.0), strokePx(TAB_ICON_STROKE_PT, 2.0));

    // scaledPxF 는 스냅하지 않는다 — 서브픽셀 그리기 좌표용.
    try std.testing.expectApproxEqAbs(@as(f32, 10.2), scaledPxF(TERMINAL_PADDING_PT, 1.7), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), scaledPxF(@as(f32, 0.2), 1.5), 1e-6);

    // scaledPx 는 scaledPxF 를 반올림한 것과 같다 (한 정의에서 파생).
    inline for (.{ 1.0, 1.25, 1.5, 1.7, 2.0 }) |s| {
        const expect: u32 = @intFromFloat(@round(scaledPxF(SCROLLBAR_W_PT, s)));
        try std.testing.expectEqual(expect, scaledPx(u32, SCROLLBAR_W_PT, s));
    }
}
