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

/// `pt × scale` 을 f32 physical px 로 하되 **최소 1px 보장** — 선 두께용.
/// scale 이 작아도 선이 0px 로 사라지지 않게 한다 (separator / underline /
/// 아이콘 stroke).
pub fn strokePx(pt: anytype, scale: f32) f32 {
    return @max(1.0, scaledPxF(pt, scale));
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
