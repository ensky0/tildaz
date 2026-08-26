//! Temporary Linux bring-up renderer.
//!
//! Software-only — paints ghostty-vt render state into a Wayland `wl_shm`
//! XRGB8888 buffer. 진짜 GPU renderer (EGL/OpenGL) 로 갈 때까지의 bring-up 코드.
//! Glyph 는 fontconfig + FreeType 으로 raster (ASCII 만 pre-cached, [font/linux/font.zig](../../font/linux/font.zig)).

const std = @import("std");
const ghostty = @import("ghostty-vt");
const themes = @import("../../themes.zig");
const font = @import("../../font/linux/font.zig");
const font_spec = @import("../../font/spec.zig");
const font_constants = @import("../../font/constants.zig");
const freetype = @import("../../font/linux/freetype.zig");
const block_element = @import("../../renderer/block_element.zig");
const cell_color = @import("../../renderer/cell_color.zig");
const cell_decoration = @import("../../renderer/cell_decoration.zig");
const pane_draw = @import("../../renderer/pane_draw.zig");
const box_drawing = @import("../../box_drawing.zig");
const display_width = @import("../../font/display_width.zig");
const config_mod = @import("../../config.zig");
const ui_metrics = @import("../../ui_metrics.zig");
const chrome_palette = @import("../../chrome_palette.zig");
const scrollbar = @import("../../scrollbar.zig");
const tab_layout = @import("../../tab_layout.zig");
const tab_chrome = @import("../../tab_chrome.zig");
const tab_icons = @import("../../tab_icons.zig");
const session_core = @import("../../session_core.zig");
const tab_interaction = @import("../../tab_interaction.zig");
const dialog_mod = @import("../../dialog.zig");
const messages = @import("../../messages.zig");
const command_menu = @import("../../command_menu.zig");
const dialog_layout = @import("dialog_layout.zig");
const log = @import("../../log.zig");

/// #203 Phase C step 3.1 — dialog 박스 모서리 radius (physical px). macOS
/// NSAlert / Win 11 dialog 의 ~12-16 범위. fractional scaling 환경 에선 그대로
/// physical px — `applyScale` 후 cell_h 변하지만 radius 는 시각 일정 (≈ 시스템
/// 표준 dialog radius). **PT (논리 점) 단위** — `scaledPt(pt, scale)` 로 physical
/// 변환. fractional scaling (KDE Plasma 6 125% / 170% 등) 환경에서도 일관 시각.
const dialog_corner_radius_pt: u32 = 16;

/// #203 Phase C step 3.2 — drop shadow 너비 (PT, 논리 점). 박스 outer edge 에서
/// 그림자가 fade out 되는 거리. buffer 가 box 보다 4 방향 각 `dialog_shadow_margin`
/// 만큼 큼 — set_size 와 computeDialogLayout 모두 합산 포함.
const dialog_shadow_margin_pt: u32 = 12;

/// drop shadow 의 최대 alpha — 박스 edge 바로 바깥 픽셀 의 검정 alpha. 거기서
/// 거리 비례 (quadratic) 로 0 까지 감소. macOS NSAlert 의 그림자 짙기 정도.
/// 색 / 투명도라 scale 무관 (PT 아님).
const dialog_shadow_max_alpha: u8 = 96;

/// #203 Phase C step 3.4 — dialog 의 OK / Cancel button 시각 (PT, 논리 점).
/// macOS 시스템 파란 + 흰 글자 의 표준 primary action 버튼. 사용자 시연 발견
/// — 이전 80×36 physical 고정 + 1.7x 환경에서 *논리 47×21* 로 너무 작아 누르기
/// 어려움. PT × scale 패턴으로 모든 DPI 환경에서 일관 크기.
const dialog_button_w_pt: u32 = 100;
const dialog_button_h_pt: u32 = 44;
const dialog_button_radius_pt: u32 = 16;
const dialog_button_color: ghostty.color.RGB = .{ .r = 45, .g = 125, .b = 210 }; // macOS 시스템 blue
const dialog_button_text_color: ghostty.color.RGB = .{ .r = 255, .g = 255, .b = 255 };
const dialog_disabled_button_color: ghostty.color.RGB = .{ .r = 0xC8, .g = 0xC8, .b = 0xC8 };
const dialog_disabled_button_text_color: ghostty.color.RGB = .{ .r = 0x78, .g = 0x78, .b = 0x78 };
/// Confirm dialog 의 Cancel 버튼 색 — macOS secondary action 모양 (회색
/// 배경 + 검정 글자). OK 와 시각 구분.
const dialog_cancel_color: ghostty.color.RGB = .{ .r = 0xD8, .g = 0xD8, .b = 0xD8 };
const dialog_cancel_text_color: ghostty.color.RGB = .{ .r = 0x1A, .g = 0x1A, .b = 0x1A };
/// 두 버튼 사이 간격 — **본문 폰트 크기에 비례**한다 (#407). 절대 pt 를 박으면
/// 폰트가 커져도 간격이 그대로라 버튼이 붙어 보인다. 1.6 배 — 1.0 배도 좁다는
/// 사용자 지적으로 넓혔다.
const dialog_button_gap_pt: u32 = ui_metrics.DIALOG_BODY_FONT_PT * 8 / 5;

/// #203 Phase C step 3.3 — dialog 상단 아이콘 크기 (PT, 논리 점). `docs/favicon.svg`
/// 의 viewBox=64×64 를 그대로 줄여 그림. tildaz 의 monitor + `>_` 표지. 사용자
/// 시연 발견 — 이전 48 physical 고정 + 1.7x 환경에서 *논리 28* 로 너무 작음.
const dialog_icon_size_pt: u32 = ui_metrics.DIALOG_ICON_SIZE_PT;
/// dialog 안쪽 여백 — **본문 폰트 크기에 비례**한다 (#407). 예전 8 pt 는 폰트의
/// 0.53 배라 내용이 창 가장자리에 붙어 답답했다 (Windows 는 같은 자리가 1.6 배였다).
/// 1.2 배로 둔다 — 더 키우면 640x480 최소 화면에서 본문 행을 잡아먹는다.
const dialog_padding_pt: u32 = ui_metrics.DIALOG_BODY_FONT_PT * 6 / 5;
const dialog_icon_gap_pt: u32 = ui_metrics.DIALOG_ICON_GAP_PT;
const dialog_viewport_margin_pt: u32 = 16;

/// #203 Phase C step 3.6 — dialog 배경 / 텍스트 색. 터미널 theme (`render_state
/// .colors`) 와 분리 — Tilda 같은 어두운 테마라도 dialog 는 *시스템 표준 밝은
/// 색* (macOS NSAlert / Win 10+ MessageBox 의 light mode 동등). OS 의 light/
/// dark 자동 감지는 별 작업 (portal `org.freedesktop.appearance.color-scheme`).
const dialog_bg_color: ghostty.color.RGB = .{ .r = 0xF2, .g = 0xF2, .b = 0xF2 };
const dialog_text_color: ghostty.color.RGB = .{ .r = 0x1A, .g = 0x1A, .b = 0x1A };
/// `docs/style.css --brand-orange` / `docs/favicon.svg`의 Zig Z와 같은 색.
/// dialog 종류나 severity와 무관하게 제목 separator 하나에만 사용한다.
const dialog_separator_color: ghostty.color.RGB = .{
    .r = ui_metrics.DIALOG_SEPARATOR_COLOR.r,
    .g = ui_metrics.DIALOG_SEPARATOR_COLOR.g,
    .b = ui_metrics.DIALOG_SEPARATOR_COLOR.b,
};
/// 밝은 dialog 배경에서 thumb가 보이도록 유지하는 중립 회색. 브랜드 accent와
/// 역할이 다르므로 separator 색을 바꿔도 scrollbar 색은 따라가지 않는다.
const dialog_scrollbar_color: ghostty.color.RGB = .{ .r = 0xC8, .g = 0xC8, .b = 0xC8 };

/// `ui_metrics.zig` 의 PT (logical point) 값을 `scale` 곱해 physical pixel 로
/// 변환. mac `backingScaleFactor` / Win `dpi/96.0` 동등 패턴. 1.0x 면 PT 그대로.
///
/// **변환 규칙은 [`ui_metrics.scaledPx`](../../ui_metrics.zig) 한 곳에만 있다** (#350).
/// 이 함수는 Linux 호출처(48곳)가 쓰는 `i32` 를 돌려주는 alias 일 뿐 계산을
/// 따로 쓰지 않는다 — 이전에는 세 platform 이 같은 식을 각자 적었고 macOS 만
/// 반올림이 빠져 있었다.
fn scaledPt(pt: anytype, scale: f32) i32 {
    return ui_metrics.scaledPx(i32, pt, scale);
}

/// preferred_scale (= scale_num/scale_den, e.g. 204/120 = 1.7x) 을 f32 factor 로.
/// denominator 0 또는 분자 0 이면 1.0 (no-op fallback).
fn scaleFactor(scale_num: u32, scale_den: u32) f32 {
    if (scale_num == 0 or scale_den == 0) return 1.0;
    return @as(f32, @floatFromInt(scale_num)) / @as(f32, @floatFromInt(scale_den));
}

/// #277 S2-3 — 셀 배경 사각형 하나. CPU 경로와 GL 경로가 **같은 목록**을 소비해
/// "어느 셀에 어떤 배경색" 판단이 한 곳에만 있게 한다.
///
/// 색을 `ui_rect.Rect` 의 `[4]f32` 가 아니라 u8 로 들고 있는 이유: 셀 색은
/// ghostty 가 u8 로 주는 원본이다. f32 로 통일하면 CPU 경로가 u8 → f32 → u8 왕복을
/// 하게 되고, `255 * (k / 255)` 가 f32 에서 `k` 보다 미세하게 작을 수 있어 truncate
/// 시 1 비트가 깎인다. GL 은 f32 를 원하므로 그쪽에서만 한 방향으로 변환한다.
/// (chrome 색은 반대로 f32 가 원본이라 `ui_rect.Rect` 를 그대로 쓴다.)
pub const SolidRect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    color: ghostty.color.RGB,
    /// #277 S2-4 — 0 이면 불투명 채움. 1·2·3 은 음영 `░▒▓` 의 픽셀 패턴
    /// (`block_element.BlockRect.shade`). 패턴은 **절대 픽셀 좌표**로 결정되므로
    /// 인접 셀 사이에서 끊기지 않는다 — CPU 는 `drawSolidRect`, GL 은 셰이더가
    /// 같은 식을 쓴다.
    shade: u8 = 0,
};

/// #277 S2-4 — 글리프를 어느 lookup 으로 찾았는지. atlas 의 캐시 키이자 CPU 가
/// 다시 조회할 때의 좌표다. Linux 폰트 경로는 codepoint 와 glyph_index 두 갈래가
/// 있어 (`Context.glyph` / `Context.glyphByIndex`) 같은 숫자가 다른 글리프를 뜻할
/// 수 있다.
pub const GlyphRef = union(enum) {
    codepoint: u21,
    indexed: struct { face: u8, index: u32 },
    /// #401 — cluster 하나를 여러 글리프로 합성해 구운 비트맵. `index` 는 FreeType glyph
    /// index 가 아니라 합성 캐시 키다 (`Context.composedGlyph`). 같은 face 안에서도 키
    /// 공간이 달라 `indexed` 와 구분해야 한다.
    composed: struct { face: u8, key: u32 },
};

/// #277 S2-5 — 글리프를 어느 폰트에서 구웠는지. atlas 캐시 키의 일부다 — 터미널
/// 폰트와 탭바 폰트는 크기가 달라 같은 codepoint 라도 다른 그림이다.
pub const FontId = enum(u8) {
    terminal,
    tab,
};

/// #277 S2-4 — 그릴 글리프 하나. **"어느 글리프를 어디에" 는 전부 여기 들어 있고,
/// 두 경로는 이 값을 읽기만 한다** — shaping / ligature / wide 중앙정렬 / bearing
/// 이 모두 수집기에서 끝난다.
pub const GlyphItem = struct {
    ref: GlyphRef,
    font: FontId = .terminal,
    /// raster 결과. font cache 가 소유하며 **주소가 고정**이라 포인터로 든다 —
    /// 캐시가 글리프를 개별 할당하므로 재해싱이 주소를 옮기지 않는다 (#362).
    /// 유효 범위는 폰트를 다시 로드하기 전까지 (`applyScale`) 이고, 프레임 목록은
    /// 매 프레임 새로 만들어지므로 항상 그 안이다.
    glyph: *const font.Glyph,
    /// 알파 마스크 글리프면 **bitmap 좌상단** (bearing · 중앙정렬 반영 완료).
    /// 컬러(BGRA) 글리프면 fit 대상 사각형의 좌상단.
    x: i32,
    y: i32,
    /// 컬러 글리프의 fit 대상 사각형 크기 (셀 또는 ligature 폭). 마스크면 0.
    w: i32 = 0,
    h: i32 = 0,
    /// 마스크 글리프의 전경색. 컬러 글리프는 텍셀 색을 그대로 쓰므로 무시된다.
    /// 바탕색은 싣지 않는다 — 두 경로 모두 **프레임버퍼와** 섞는다 (#277 S2-4).
    fg: ghostty.color.RGB,
    /// #375 — atlas 캐시 키를 가르기 위한 face 변종.
    ///
    /// **`codepoint` 경로는 face 정보가 키에 없다** (`gl_atlas.Key` 가 `face` 를
    /// `0xFF` 로 고정한다). 이 값이 없으면 bold `A` 와 regular `A` 가 같은 칸을
    /// 덮어쓴다. `indexed` 경로는 face index 가 이미 키에 있어 영향이 없다.
    face_style: font_constants.FaceStyle = .regular,
};

/// #277 S2-5 — 아이콘 하나 (`< > + × …`). 폰트 글리프가 아니라 공통
/// [`tab_icons`](../../tab_icons.zig) 가 그려 주는 알파 커버리지 비트맵이다.
///
/// **비트맵을 목록에 싣지 않고 (종류, 크기, 굵기) 만 싣는다.** 래스터화는 순수
/// 함수라 두 경로가 각자 불러도 같은 그림이 나오고 — CPU 는 매 프레임, GL 은 atlas
/// 가 비었을 때만 부른다 — 목록이 픽셀 소유권을 지지 않아도 된다. "어디에" 는 여기
/// 이미 정해져 있다.
pub const IconItem = struct {
    kind: tab_icons.Icon,
    /// 한 변 (px). `tab_icons.MAX_SIZE` 이하.
    size: u32,
    stroke: f32,
    /// 비트맵 좌상단.
    x: i32,
    y: i32,
    color: ghostty.color.RGB,
};

/// #277 S2-5 — chrome 그리기 명령 하나.
///
/// chrome 은 터미널 레이어와 달리 **순서 그대로의 명령 목록**이다. 탭바가
/// `사각형 → 제목 → 사각형 → 집어 든 제목 → 아이콘` 으로 실제 교차하고 (#343 이
/// 정한 layer 순서), 항목이 수백 개뿐이라 계층으로 쪼개는 것보다 순서를 그대로
/// 지키는 편이 안전하다. GL 은 종류가 바뀔 때만 batch 를 flush 한다.
pub const ChromeItem = union(enum) {
    rect: SolidRect,
    glyph: ChromeGlyph,
    icon: IconItem,
};

/// chrome 글리프 — 터미널 글리프에 **가로 clip 경계**가 붙는다. 탭 제목은 탭 영역
/// 밖으로 나가면 픽셀 단위로 잘린다 (#343 A-2 — 통째로 버리지 않고 남은 조각을
/// 보여 준다).
pub const ChromeGlyph = struct {
    item: GlyphItem,
    clip_x0: i32,
    clip_x1: i32,
};

/// #277 S2-4/S2-5 — 한 프레임의 그리기 목록 전체. **CPU 와 GL 이 이 목록만
/// 소비한다** — "무엇을 어디에" 판단이 한 벌뿐이라 두 경로가 구조적으로 어긋날 수
/// 없다.
///
/// 목록이 나뉜 것은 **그리는 순서가 의미를 갖기** 때문이다. 터미널 부분의 순서는
/// macOS · Windows renderer 와 같다 (`renderer/macos.zig` · `renderer/windows.zig`
/// 의 bg pass → text pass → block pass → cursor → scrollbar → preedit) — #361 에서
/// "셀 배경을 전부 먼저" 로 정한 규칙의 연장이다.
///
///   1. `chrome_before`  탭바 (터미널 격자 위쪽)
///   2. `cell_bg`        셀 배경
///   3. `glyphs`         터미널 텍스트
///   4. `overlay`        block element · box drawing · 커서 · scrollbar thumb
///   5. `preedit_bg`     IME 조합 중 배경
///   6. `preedit_glyphs` IME 조합 중 글자
///   7. `chrome_after`   단일 탭 컨트롤 overlay · command menu
///
/// 매 프레임 `clearRetainingCapacity` 로 비우므로 할당은 초반 몇 프레임에만 난다.
pub const FrameLayer = struct {
    chrome_before: std.ArrayList(ChromeItem) = .empty,
    cell_bg: std.ArrayList(SolidRect) = .empty,
    glyphs: std.ArrayList(GlyphItem) = .empty,
    overlay: std.ArrayList(SolidRect) = .empty,
    preedit_bg: std.ArrayList(SolidRect) = .empty,
    preedit_glyphs: std.ArrayList(GlyphItem) = .empty,
    chrome_after: std.ArrayList(ChromeItem) = .empty,

    fn clear(self: *FrameLayer) void {
        self.chrome_before.clearRetainingCapacity();
        self.cell_bg.clearRetainingCapacity();
        self.glyphs.clearRetainingCapacity();
        self.overlay.clearRetainingCapacity();
        self.preedit_bg.clearRetainingCapacity();
        self.preedit_glyphs.clearRetainingCapacity();
        self.chrome_after.clearRetainingCapacity();
    }

    fn deinit(self: *FrameLayer, allocator: std.mem.Allocator) void {
        self.chrome_before.deinit(allocator);
        self.cell_bg.deinit(allocator);
        self.glyphs.deinit(allocator);
        self.overlay.deinit(allocator);
        self.preedit_bg.deinit(allocator);
        self.preedit_glyphs.deinit(allocator);
        self.chrome_after.deinit(allocator);
    }
};

/// #277 S2-5 — 한 프레임의 입력. `paint` (CPU) 와 `buildGlFrame` (GL) 이 **같은
/// 값을 받는다** — 입력이 갈리면 목록을 공유해도 소용이 없다.
pub const FrameInputs = struct {
    /// #483 2단계 ② — 이 프레임에 그릴 pane 들 (화면 순서). 지금은 활성 탭 하나다. 각 pane 의
    /// `state` 는 `paint` / `buildGlFrame` 이 갱신하고, 첫 pane 의 배경색이 표면 전체의 배경이다.
    panes: []const pane_draw.PaneDraw,
    theme: *const themes.Theme,
    width: i32,
    height: i32,
    tab_titles: []const []const u8,
    active_tab_idx: usize,
    layout: tab_layout.Layout,
    tab_scroll_x: f32,
    drag_view: ?tab_interaction.DragView,
    tab_hover: tab_layout.Area,
    menu_ui: command_menu.Ui,
    toggle_hotkey: []const u8,
    /// #376 — blink 위상. **프레임 단위** 값이라 (셀마다 다르지 않다) 호출부가 프레임
    /// 하나에 한 번 구해서 내려보낸다. 렌더러가 따로 시계를 읽으면 500 ms 경계에서
    /// 호출부의 게이트 판정과 화면이 서로 다른 위상을 볼 수 있다.
    blink_faint: bool,
};

/// #277 S2-3 — GL 경로가 한 프레임을 그리는 데 필요한 기술. `buildGlFrame` 이
/// 돌려준다. host 는 `ghostty` 를 import 하지 않으므로 타입에 이름을 준다.
pub const GlFrame = struct {
    background: ghostty.color.RGB,
    layer: *const FrameLayer,
};

/// #362 진단 — 프레임 CPU 를 `render_state.update` (ghostty 스냅샷) 와
/// `collectFrame` (우리 수집기) 으로 나눠 본다. GPU 로 래스터화를 옮긴 뒤 남은
/// CPU 가 어디인지 이 둘의 비율이 말해 준다.
///
/// `TILDAZ_GPU_TIMING=1` 일 때만 잰다 — 매 프레임 시계를 두 번 읽는 비용을 평소에
/// 지불하지 않는다.
pub var timing_enabled: bool = false;
/// #451 — `std.time.nanoTimestamp` 이 없어졌다 (릴리즈 노트 *Time*: `time.Instant` ·
/// `time.Timer` ➡️ `Io.Timestamp`). 시계를 읽으려면 `Io` 가 필요한데, 이 계측 machinery 는
/// 이미 전부 module-level 전역이라 (`timing_enabled` · 아래 누적값들) 시계도 같은 자리에
/// 둔다 — 프레임 데이터도 렌더러 상태도 아니기 때문이다. `timing_enabled` 를 켜는 쪽이
/// 함께 채운다. 켜지 않으면 `null` 이고 아무도 읽지 않는다.
pub var timing_io: ?std.Io = null;

/// `.awake` 단조 시계의 현재 나노초. `timing_enabled` 가 참일 때만 불린다.
fn timingNowNs() i128 {
    const io = timing_io orelse return 0;
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}
pub var last_update_ns: u64 = 0;
pub var last_collect_ns: u64 = 0;
/// 누적 — 한 프레임 표본은 스케줄링·캐시 상태에 크게 흔들린다. 평균으로 본다.
pub var acc_update_ns: u64 = 0;
pub var acc_collect_ns: u64 = 0;
pub var acc_frames: u64 = 0;

/// #362 — `collect` 안에서 **셀 순회**가 차지하는 몫. 나머지 (탭바 · 커서 ·
/// scrollbar · preedit · 메뉴) 는 항목이 수백 개뿐이라 합쳐서 수 µs 다.
pub var acc_cells_ns: u64 = 0;

pub const Renderer = struct {
    /// #277 S2-3/S2-4/S2-5 — 프레임마다 재사용하는 그리기 목록. `collectFrame` 이
    /// 채우고 CPU · GL 이 소비한다.
    layer: FrameLayer = .{},
    /// #376 — 직전 프레임에 blink 셀이 화면에 있었나. host 의 poll 루프가 이 값과
    /// 위상 전환을 **함께** 봐서, blink 이 실제로 보일 때만 초당 2프레임을 추가로
    /// 그린다. "blink 셀이 있다" 만으로 열면 매 tick(16ms) 그리게 된다.
    saw_blink_cell: bool = false,

    // #399 — cluster shaping 을 런 단위로 묶는 데 쓰는 작업 버퍼다. 셀 루프의 지역 변수로
    // 두면 3 KB 가량이라 프레임 스택에 부담이라 renderer 가 들고 재사용한다. `render` 의
    // 91.5 % 가 shaping 이고 (#395), cluster 마다 chain 을 처음부터 순회하며 HarfBuzz 를
    // 새로 부르는 고정 비용이 그 대부분이다.
    /// 런 안 cluster 들의 codepoint 를 이어 담는다 (base 1 + extras 최대 15).
    run_cps: [font.MAX_RUN_CLUSTERS * font.MAX_CLUSTER_CPS]u21 = undefined,
    /// 위 버퍼를 cluster 단위로 가리키는 slice 들. `resolveClusterRun` 의 입력이다.
    run_slices: [font.MAX_RUN_CLUSTERS][]const u21 = undefined,
    /// 각 cluster 가 있던 셀의 x. 글리프를 되돌려 놓을 때 쓴다 (셀마다 색이 다르다).
    run_cells: [font.MAX_RUN_CLUSTERS]u16 = undefined,
    /// shaping 결과. cluster 당 하나다. #401 부터 그 하나가 **합성 비트맵일 수 있다** —
    /// 폰트가 cluster 를 글리프 하나로 안 줄이면 여러 글리프를 겹쳐 구운 결과를 가리킨다.
    run_results: [font.MAX_RUN_CLUSTERS]font.ClusterGlyph = undefined,

    font_ctx: font.Context,
    tab_font_ctx: font.Context,
    /// #368 — dialog 폰트는 **처음 dialog 를 열 때** 만든다. 대부분의 세션은 dialog 를
    /// 열지 않는데, 미리 구우면 시작 시간의 절반을 거기 쓴다 (실측 44 ms 중 22 ms,
    /// fractional scale 이면 재초기화까지 43 ms).
    dialog_font_ctx: ?font.Context = null,
    dialog_title_font_ctx: ?font.Context = null,
    /// 지연 생성에 필요한 것 — `Renderer.init` 이 받은 그대로 보관한다.
    font_chain: []const []const u8 = &.{},
    /// #406 — dialog 를 **시스템 기본 고정폭**으로 그린다. 폰트 설정이 잘못됐다고 알리는
    /// 화면이 바로 그 잘못된 설정으로 그려지면 안 되기 때문이다 — 실제로 `font.family` 에
    /// 오타를 냈을 때 fallback 인 비례폭 폰트로 그려져 자간이 벌어졌다. 폰트 검증 실패
    /// 경로가 dialog 를 띄우기 전에 세운다.
    dialog_use_system_font: bool = false,
    scale_num: u32 = 120,
    scale_den: u32 = 120,
    /// L10-β — IME 조합 중 (preedit) 텍스트. host (wayland_minimal) 가 매
    /// `done` batch 적용 시점에 갱신한다. 빈 slice = 조합 중 아님. storage 는
    /// host 가 소유 — Renderer 는 view 만 빌린다 (paint 호출 동안 valid 보장).
    preedit_text: []const u8 = "",
    /// #203 Phase C — drawDialogContent 가 그린 OK / Cancel 버튼 좌표 (dialog
    /// surface-local physical pixel). host (handlePointerButton) 가 hit-test 에
    /// 사용. dialog 안 떠 있으면 `w == 0`. mac/win modal 정책 (본문 click 은
    /// 무시, OK / Cancel 버튼 click 만 dismiss) 의 구현 보조. Confirm 모드 가
    /// 아니면 cancel rect 의 `w == 0` (그리지 않음).
    last_dialog_ok_rect: struct { x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0 } = .{},
    last_dialog_cancel_rect: struct { x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0 } = .{},
    last_dialog_scrollbar_track_rect: struct { x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0 } = .{},
    /// 보이는 track 왼쪽의 dialog 전용 빈 gap까지 포함한 pointer hit target.
    /// thumb 자체는 `SCROLLBAR_W_PT` 폭으로 유지하고 조작 영역만 넓힌다.
    last_dialog_scrollbar_hit_rect: struct { x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0 } = .{},
    last_dialog_scrollbar_thumb_rect: struct { x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0 } = .{},
    /// L13-γ — 매 픽셀의 alpha byte (ARGB8888 의 high byte). `config.opacity_
    /// alpha` 가 그대로. 100% → 255 (완전 opaque, 시각 변화 없음), <100 →
    /// compositor 가 배경과 alpha blending. `Client.init` 에서 채움.
    opacity_alpha: u8 = 255,
    /// `ui_metrics.*_PT` 를 physical pixel 로 변환할 때 곱하는 factor.
    /// mac `backingScaleFactor` / Win `dpi/96.0` 동등. preferred_scale event
    /// 로 갱신 (`applyScale`). default 1.0 — fractional scaling 미advertise
    /// 환경 또는 첫 init 시점.
    scale: f32 = 1.0,

    /// #335 — theme 배경에서 파생한 탭바 / command menu chrome 색. theme 은
    /// runtime 에 바뀌지 않으므로 init 에서 한 번 계산해 보관한다. 탭바 그리기는
    /// `ui_metrics` 색 상수를 직접 참조하지 않고 이 값만 쓴다 (자유 함수엔 인자로
    /// 전달 — #343 이 rect 목록 생성 함수의 인자로 그대로 흡수하도록).
    ///
    /// 기본값을 두지 않는다 — `derive` 는 `std.math.pow` 를 쓰고 comptime 에서는
    /// 평가되지 않는다. `Renderer.init` 이 항상 채운다.
    chrome: chrome_palette.Palette,

    /// `scale_num / scale_den` — fractional scaling factor (e.g. 204/120 = 1.7x).
    /// 첫 init 시점엔 wp_fractional_scale_v1 의 preferred_scale event 가 아직
    /// 안 왔을 수 있어 default 120/120 = 1.0x. event 받은 후 `applyScale` 로
    /// 정확한 scale 의 font 재초기화 + scale field 갱신.
    pub fn init(
        allocator: std.mem.Allocator,
        cfg: *const config_mod.Config,
        scale_num: u32,
        scale_den: u32,
    ) !Renderer {
        const chain = cfg.font_families[0..cfg.font_family_count];
        const spec = cfg.terminalFontSpec();
        const pixel_height = scaledFontPixelHeight(spec, scale_num, scale_den);
        var terminal_ctx = try font.Context.init(
            allocator,
            chain,
            pixel_height,
            spec.cell_width_ratio,
            spec.line_height_ratio,
        );
        errdefer terminal_ctx.deinit();

        const tab_spec = ui_metrics.tabLabelFontSpec();
        const tab_pixel_height = scaledFontPixelHeight(tab_spec, scale_num, scale_den);
        var tab_ctx = try font.Context.init(
            allocator,
            chain,
            tab_pixel_height,
            tab_spec.cell_width_ratio,
            tab_spec.line_height_ratio,
        );
        errdefer tab_ctx.deinit();

        // #335 — chrome 색 파생. null theme fallback 은 `wayland_minimal.zig` 의
        // `fallback_theme` (= themes 첫 entry "Tilda") 와 같은 선택이다.
        const chrome_theme = cfg.theme orelse &themes.themes[0];
        const chrome_bg = chrome_theme.background;

        return .{
            .font_ctx = terminal_ctx,
            .tab_font_ctx = tab_ctx,
            .font_chain = chain,
            .scale_num = scale_num,
            .scale_den = scale_den,
            .scale = scaleFactor(scale_num, scale_den),
            .chrome = chrome_palette.derive(
                .{ chrome_bg.r, chrome_bg.g, chrome_bg.b },
                themes.isDark(chrome_theme),
            ),
        };
    }

    pub fn deinit(self: *Renderer, allocator: std.mem.Allocator) void {
        self.layer.deinit(allocator);
        self.releaseDialogFonts();
        self.tab_font_ctx.deinit();
        self.font_ctx.deinit();
    }

    /// fractional scale 변경 시 font 재초기화 + UI chrome scale 갱신. preferred_
    /// scale event handler 가 호출 — pixel_height = base × scale / 120 으로 raster
    /// + `Renderer.scale` field 갱신해 tab bar / padding / scrollbar 도 같은
    /// scale 로 정렬.
    pub fn applyScale(
        self: *Renderer,
        allocator: std.mem.Allocator,
        cfg: *const config_mod.Config,
        scale_num: u32,
        scale_den: u32,
    ) !void {
        const chain = cfg.font_families[0..cfg.font_family_count];
        const spec = cfg.terminalFontSpec();
        const pixel_height = scaledFontPixelHeight(spec, scale_num, scale_den);
        var new_ctx = try font.Context.init(
            allocator,
            chain,
            pixel_height,
            spec.cell_width_ratio,
            spec.line_height_ratio,
        );
        errdefer new_ctx.deinit();

        const tab_spec = ui_metrics.tabLabelFontSpec();
        const tab_pixel_height = scaledFontPixelHeight(tab_spec, scale_num, scale_den);
        var new_tab_ctx = try font.Context.init(
            allocator,
            chain,
            tab_pixel_height,
            tab_spec.cell_width_ratio,
            tab_spec.line_height_ratio,
        );
        errdefer new_tab_ctx.deinit();

        // #368 — dialog 폰트는 **다시 만들지 않고 버린다.** 다음에 dialog 를 열 때
        // 새 scale 로 만들어진다. 대부분의 세션은 그 순간이 오지 않는다.
        self.releaseDialogFonts();
        self.tab_font_ctx.deinit();
        self.font_ctx.deinit();
        self.font_ctx = new_ctx;
        self.tab_font_ctx = new_tab_ctx;
        self.scale_num = scale_num;
        self.scale_den = scale_den;
        self.scale = scaleFactor(scale_num, scale_den);
    }

    /// #368 — dialog 폰트를 지금 만든다 (없으면). dialog 진입점이 부른다.
    ///
    /// 실패하면 **탭 폰트로 대신 그린다** — 같은 family / fallback chain 이 이미
    /// 로드돼 있으므로 크기만 다르고 읽을 수 있다. `Renderer.init` 에서 실패하면 앱이
    /// 아예 못 뜨지만, 이 시점의 실패는 dialog 하나의 문제여야 한다.
    pub fn ensureDialogFonts(self: *Renderer, allocator: std.mem.Allocator) void {
        if (self.dialog_font_ctx != null and self.dialog_title_font_ctx != null) return;
        // **dialog 는 언제나 시스템 UI 폰트 (비례폭) 로 그린다** (#407). `sans-serif` 는
        // `monospace` 와 같은 generic family 라 fontconfig 가 시스템 기본으로 해석하는 것이
        // **의도된 동작**이고 (`isGenericFamily`), 사용자 chain 을 못 믿는 상황에서도 쓸 수
        // 있다 (#406). 터미널 본문과 달리 dialog 는 고정폭일 이유가 없고, macOS · Windows 가
        // OS 위젯을 쓰므로 이미 비례폭이라 **Linux 만 인상이 튀던 것**을 맞춘다.
        const system_chain = [_][]const u8{"sans-serif"};
        const chain: []const []const u8 = &system_chain;
        _ = self.dialog_use_system_font;
        if (self.dialog_font_ctx == null) {
            const spec = ui_metrics.dialogBodyFontSpec();
            self.dialog_font_ctx = font.Context.init(
                allocator,
                chain,
                scaledFontPixelHeight(spec, self.scale_num, self.scale_den),
                spec.cell_width_ratio,
                spec.line_height_ratio,
            ) catch |err| blk: {
                log.appendLine("font", "dialog body font creation failed ({s}) — drawing with the tab font", .{@errorName(err)});
                break :blk null;
            };
        }
        if (self.dialog_title_font_ctx == null) {
            const spec = ui_metrics.dialogTitleFontSpec();
            self.dialog_title_font_ctx = font.Context.init(
                allocator,
                chain,
                scaledFontPixelHeight(spec, self.scale_num, self.scale_den),
                spec.cell_width_ratio,
                spec.line_height_ratio,
            ) catch |err| blk: {
                log.appendLine("font", "dialog title font creation failed ({s}) — drawing with the tab font", .{@errorName(err)});
                break :blk null;
            };
        }
    }

    fn releaseDialogFonts(self: *Renderer) void {
        if (self.dialog_font_ctx) |*c| c.deinit();
        if (self.dialog_title_font_ctx) |*c| c.deinit();
        self.dialog_font_ctx = null;
        self.dialog_title_font_ctx = null;
    }

    /// dialog 본문 폰트 — 생성 실패 시 탭 폰트로 떨어진다 (`ensureDialogFonts` 참고).
    fn dialogFont(self: *Renderer) *font.Context {
        if (self.dialog_font_ctx) |*c| return c;
        return &self.tab_font_ctx;
    }

    fn dialogTitleFont(self: *Renderer) *font.Context {
        if (self.dialog_title_font_ctx) |*c| return c;
        return &self.tab_font_ctx;
    }

    /// `dialogLayoutMetrics` 는 `*const Renderer` 라 const 판이 따로 필요하다.
    fn dialogFontConst(self: *const Renderer) *const font.Context {
        if (self.dialog_font_ctx) |*c| return c;
        return &self.tab_font_ctx;
    }

    fn dialogTitleFontConst(self: *const Renderer) *const font.Context {
        if (self.dialog_title_font_ctx) |*c| return c;
        return &self.tab_font_ctx;
    }

    /// 터미널 영역 안쪽 padding (cell grid 가 surface 모서리에서 떨어진 거리).
    /// `ui_metrics.TERMINAL_PADDING_PT` (6 pt) × scale. mac `pad_px` / Win
    /// `TERMINAL_PADDING` 동등.
    pub fn paddingPx(self: *const Renderer) i32 {
        return scaledPt(ui_metrics.TERMINAL_PADDING_PT, self.scale);
    }

    /// 우측 스크롤바 thumb 너비. `ui_metrics.SCROLLBAR_W_PT` (10 pt) × scale.
    pub fn scrollbarWPx(self: *const Renderer) i32 {
        return scaledPt(ui_metrics.SCROLLBAR_W_PT, self.scale);
    }

    /// 스크롤바 thumb 최소 높이 — scrollback 이 길어 ratio 작아져도 클릭 가능
    /// 영역. `ui_metrics.SCROLLBAR_MIN_THUMB_H_PT` (32 pt) × scale.
    pub fn scrollbarMinThumbHPx(self: *const Renderer) i32 {
        return scaledPt(ui_metrics.SCROLLBAR_MIN_THUMB_H_PT, self.scale);
    }

    /// 상단 탭바 높이. terminal cell height와 독립된 공통 28 logical pt.
    ///
    /// `tab_count < 2` 면 0 — 단일 탭 시 탭바 자리 안 띄움 (#127, SPEC.md §1
    /// `단일 탭 시 탭바 자리`). mac `tabBarHeightPx` / Win `effectiveTabBarHeight`
    /// 동등. 탭 카운트 변화 시점 (createTab / closeTab / 탭 exit) 에 호출자가
    /// 모든 탭 cols/rows 재계산 책임 (Linux 는 `Client.ensureSessionGrid`).
    pub fn tabBarHeightPx(self: *const Renderer, tab_count: usize) i32 {
        if (tab_count < 2) return 0;
        return @intCast(ui_metrics.tabBarHeightPx(self.scale));
    }

    /// 단일 탭 overlay와 다중 탭 bar가 공유하는 chrome 높이. Terminal grid의
    /// y-offset과 분리해 단일 탭에서는 grid를 밀지 않고 control/scrollbar에만 쓴다.
    pub fn chromeHeightPx(self: *const Renderer) i32 {
        return @intCast(ui_metrics.tabBarHeightPx(self.scale));
    }

    /// 한 탭의 너비. `ui_metrics.TAB_WIDTH_PT` (150 pt) × scale.
    pub fn tabWidthPx(self: *const Renderer) i32 {
        return scaledPt(ui_metrics.TAB_WIDTH_PT, self.scale);
    }

    /// 탭 안 padding (title text / close 'x' 정렬). `ui_metrics.TAB_PADDING_PT`
    /// (6 pt) × scale.
    pub fn tabPaddingPx(self: *const Renderer) i32 {
        return scaledPt(ui_metrics.TAB_PADDING_PT, self.scale);
    }

    /// 탭바 우측 끝 `x` (활성 탭 닫기) 버튼 너비 (#268).
    /// `ui_metrics.TAB_CLOSE_W_PT` (24 pt) × scale.
    pub fn tabCloseWPx(self: *const Renderer) i32 {
        return scaledPt(ui_metrics.TAB_CLOSE_W_PT, self.scale);
    }

    /// 탭바 좌/우 스크롤 화살표 `<` / `>` 너비. `ui_metrics.TAB_ARROW_W_PT`
    /// (24 pt) × scale.
    pub fn tabArrowWPx(self: *const Renderer) i32 {
        return scaledPt(ui_metrics.TAB_ARROW_W_PT, self.scale);
    }

    /// 탭바 `+` 새 탭 버튼 너비. `ui_metrics.TAB_PLUS_W_PT` (24 pt) × scale.
    pub fn tabPlusWPx(self: *const Renderer) i32 {
        return scaledPt(ui_metrics.TAB_PLUS_W_PT, self.scale);
    }

    /// 탭바 `…` command menu 버튼 너비.
    pub fn tabMoreWPx(self: *const Renderer) i32 {
        return scaledPt(ui_metrics.TAB_MORE_W_PT, self.scale);
    }

    /// `Config.terminalFontSpec().size_logical` 의미는 cross-platform 동등 —
    /// Windows host 의 `font_height_px = size_logical × DPI_scale` 식, macOS host
    /// 의 logical pixel 그대로 사용 패턴과 같이 **96 DPI 의 logical pixel** 의미.
    /// 표준 typographic 1pt = 1/72 inch 변환 (× 96/72) 을 다시 곱하면 Win/Mac
    /// 대비 1.33x 큰 cell 이 되어 사용자가 "Linux 글자가 크다" 고 느낌 (사용자
    /// 보고). 따라서 1:1 에 output scale 만 곱한다.
    fn scaledFontPixelHeight(spec: font_spec.Spec, scale_num: u32, scale_den: u32) u32 {
        return spec.physicalSizeRatioCeilPx(scale_num, scale_den);
    }

    pub fn cellWidth(self: *const Renderer) i32 {
        return @intCast(self.font_ctx.cell_width_px);
    }

    pub fn cellHeight(self: *const Renderer) i32 {
        return @intCast(self.font_ctx.cell_height_px);
    }

    /// #277 S2-3 — GL 경로용 프레임 준비. `in.panes` 의 각 `state` (탭의 `RenderState`) 를 갱신하고 터미널 레이어
    /// 목록을 만들어 돌려준다. 표면 배경색도 함께 준다 (GL 은 `glClear` 로 칠한다).
    ///
    /// CPU 경로의 `paint` 과 **같은 `collectTerminalLayer` 를 쓴다** — 그게 두 경로가
    /// 갈리지 않는 이유다. chrome (탭바 · 단일 탭 컨트롤 · command menu) 은 아직
    /// 여기 없다.
    ///
    /// 어느 pane 의 `state` 갱신이라도 실패하면 배경색과 빈 목록을 돌려준다 — 그 프레임은 빈
    /// 화면이지만 CPU 경로의 같은 실패 처리와 동일하다 (`fill` 후 return).
    pub fn buildGlFrame(self: *Renderer, allocator: std.mem.Allocator, in: FrameInputs) GlFrame {
        const t_start = if (timing_enabled) timingNowNs() else 0;
        for (in.panes) |p| p.state.update(allocator, p.terminal) catch {
            self.layer.clear();
            return .{ .background = in.theme.background, .layer = &self.layer };
        };
        const t_updated = if (timing_enabled) timingNowNs() else 0;
        defer if (timing_enabled) {
            last_update_ns = @intCast(t_updated - t_start);
            last_collect_ns = @intCast(timingNowNs() - t_updated);
            acc_update_ns += last_update_ns;
            acc_collect_ns += last_collect_ns;
            acc_frames += 1;
        };
        self.collectFrame(allocator, in);
        return .{ .background = frameBackground(in), .layer = &self.layer };
    }

    /// #483 2단계 ② — 표면 전체를 채우는 배경. 첫 pane (활성 탭) 의 현재 배경 (OSC 11 반영) 이고,
    /// pane 이 없으면 theme 배경이다. 4단계에서 pane 마다 배경이 갈릴 수 있으면 다시 본다.
    fn frameBackground(in: FrameInputs) ghostty.color.RGB {
        return if (in.panes.len > 0) in.panes[0].state.colors.background else in.theme.background;
    }

    /// 그릴 세션이 없는 프레임용 — 목록을 비우고 그 자리를 돌려준다. 배경만 칠하는
    /// 프레임에서도 GL 경로가 지난 프레임의 목록을 다시 그리지 않게 한다.
    pub fn emptyLayer(self: *Renderer) *const FrameLayer {
        self.layer.clear();
        return &self.layer;
    }

    /// #277 S2-3/S2-4 — 터미널 레이어의 그리기 목록을 만든다. CPU 경로(`paint`)와
    /// GL 경로(`buildGlFrame`)가 **이 함수 하나를 공유한다.**
    ///
    /// **요점은 "무엇을 어디에" 가 여기에만 있다는 것이다.** 셀 배경색 판단, shaping,
    /// ligature, wide 중앙정렬, block element · box drawing 의 절차적 사각형, 커서,
    /// IME preedit 까지 전부 여기서 끝난다. 어느 한쪽 renderer 에 이 판단을 다시
    /// 적으면 그 순간부터 두 경로가 조용히 갈린다.
    ///
    /// 목록의 순서는 `TerminalLayer` 주석 참고 (macOS · Windows 와 같은 계층 순서).
    ///
    /// `in.panes` 의 `state` 가 최신이어야 한다 (호출 전에 `update` 됨을 전제).
    /// 할당 실패는 조용히 무시한다 — 그 프레임의 일부가 빠질 뿐이고, 다음 프레임에
    /// 다시 시도한다. 여기서 화면 전체를 포기하는 것보다 낫다.
    pub fn collectFrame(self: *Renderer, allocator: std.mem.Allocator, in: FrameInputs) void {
        self.layer.clear();

        const tab_bar_h = self.tabBarHeightPx(in.tab_titles.len);
        self.collectTabBar(allocator, in, tab_bar_h);
        // #376 — blink 셀 존재 판정은 프레임 단위다. 여기서 지우고 pane 들이 OR 로 모은다.
        self.saw_blink_cell = false;
        // #483 2단계 ② — pane 마다 셀 · 커서 · scrollbar · preedit. 순서는 이전과 같다.
        for (in.panes) |pane| {
            const t_cells = if (timing_enabled) timingNowNs() else 0;
            self.collectCells(allocator, pane);
            if (timing_enabled) acc_cells_ns += @intCast(timingNowNs() - t_cells);
            self.collectCursor(allocator, pane);
            self.collectScrollbar(allocator, pane);
            self.collectPreedit(allocator, pane);
        }
        self.collectSingleTabControls(allocator, in);
        if (in.menu_ui.open) self.collectCommandMenu(allocator, in);
    }

    /// #362 — 한 줄에서 실제로 볼 필요가 있는 칸의 개수.
    ///
    /// 터미널 한 줄은 대부분 **한 번도 쓰인 적 없는** 칸이다 — 4K 는 한 줄이 424
    /// 칸인데 프롬프트나 로그 한 줄은 그중 일부만 쓴다. `ghostty.Cell` 은
    /// `packed struct(u64)` 이고 그 문서가 "**0 이 곧 유효한 빈 칸**" 임을 보장하므로,
    /// 뒤에서부터 u64 비교 하나로 경계를 찾는다. 비교 400 번은 셀 본문 400 번보다
    /// 한 자릿수 싸다.
    ///
    /// **선택 영역은 예외다** — 빈 칸이라도 선택되면 배경 사각형을 그려야 하므로
    /// 경계를 선택 끝까지 늘린다. 커서 · scrollbar · preedit 는 각자 수집기가
    /// 따로 그리므로 여기 경계와 무관하다.
    fn rowLimit(raws: []const ghostty.Cell, cols: usize, sel_range: ?[2]u16) usize {
        var limit = @min(cols, raws.len);
        while (limit > 0 and @as(u64, @bitCast(raws[limit - 1])) == 0) limit -= 1;
        if (sel_range) |sr| {
            const sel_end = @as(usize, sr[1]) + 1;
            limit = @max(limit, @min(sel_end, @min(cols, raws.len)));
        }
        return limit;
    }

    /// #277 S2-3/S2-4 · #361 · #362 — 셀 배경 사각형과 셀 텍스트를 **한 번의
    /// 순회**로 만든다. 배경은 `layer.cell_bg`, 글리프는 `layer.glyphs`, block
    /// element 와 box drawing 의 절차적 사각형은 `layer.overlay` 에 쌓는다.
    ///
    /// 목록이 여럿으로 나뉘는 것이 곧 **그리기 순서**다 — 배경을 전부 그린 뒤
    /// 글리프, 그다음 절차적 사각형 (macOS · Windows 와 동일). 이전에는 셀 순서로
    /// 번갈아 그려서 셀을 넘은 글리프가 이웃의 box drawing 위에 남을지 지워질지가
    /// *방향에 따라* 갈렸다 — #361 이 셀 배경에서 없앤 것과 같은 종류의 비대칭이다.
    ///
    /// **그런데 목록이 나뉘는 것과 순회가 나뉘는 것은 별개다.** 예전에는 배경과
    /// 텍스트가 각자 전체 셀을 돌아 4K 에서 프레임마다 95,824 번 방문했다. 셀 방문
    /// 자체가 수집 비용의 대부분이라 (셀당 작업을 셋이나 꺼도 8% 밖에 안 줄었다)
    /// 한 번만 도는 것이 곧 성능이다 (#362).
    fn collectCells(self: *Renderer, allocator: std.mem.Allocator, pane: pane_draw.PaneDraw) void {
        const state = pane.state;
        const blink_faint = pane.blink_faint;
        const colors = state.colors;
        const cw = pane.cell_w;
        const ch = pane.cell_h;
        const ascent: i32 = @intCast(self.font_ctx.ascent_px);
        const pad = pane.pad;
        const rows = state.rows;
        const cols = state.cols;
        const row_slice = state.row_data.slice();
        const all_cells = row_slice.items(.cells);
        const all_sels = row_slice.items(.selection);

        for (0..rows) |y| {
            if (y >= all_cells.len) break;
            const cell_slice = all_cells[y].slice();
            const raws = cell_slice.items(.raw);
            const styles = cell_slice.items(.style);
            const graphemes = cell_slice.items(.grapheme);
            const sel_range: ?[2]u16 = if (y < all_sels.len) all_sels[y] else null;

            // ligature 가 삼킨 뒤따르는 셀은 **텍스트만** 건너뛴다. 배경은 셀마다
            // 그대로 만들어야 한다 — 예전에 두 순회가 나뉘어 있을 때 배경 쪽이
            // 자연히 하던 일이다.
            var text_skip: usize = 0;

            var x: usize = 0;
            const limit = rowLimit(raws, cols, sel_range);
            while (x < limit) : (x += 1) {
                const raw = raws[x];
                if (raw.wide == .spacer_tail) continue;

                // #376 — 이 순회가 **모든 셀**을 보므로 blink 셀 존재 판정도 여기서
                // 한다. 위상이 off 면 `faint` 를 세워 fg 해석과 선 색이 한 번에
                // 흐려지게 한다 (macOS · Windows 와 같은 helper).
                const raw_style = if (raw.style_id != 0) styles[x] else ghostty.Style{};
                if (raw_style.flags.blink) self.saw_blink_cell = true;
                const style = cell_color.applyBlinkPhase(raw_style, blink_faint);
                const x16: u16 = @intCast(x);
                const is_selected = if (sel_range) |sr| (x16 >= sr[0] and x16 <= sr[1]) else false;
                // #483 2단계 ② — 격자 원점은 pane 기준 (`rect` 는 탭바를 뺀 영역). pane 하나면 이전의
                // `pad` / `tab_bar_h + pad` 와 같은 값이다.
                const cell_x: i32 = pane.rect.x + pad + @as(i32, @intCast(x)) * cw;
                const cell_y: i32 = pane.rect.y + pad + @as(i32, @intCast(y)) * ch;
                const cell_w: i32 = if (raw.wide == .wide) cw * 2 else cw;

                // 셀 배경 — 평범한 셀 (선택·반전·명시 bg 없음) 은 사각형을 만들지
                // 않는다. 표면 전체가 이미 배경색이라 (CPU 는 `fill`, GL 은
                // `glClear`) 덧그릴 필요가 없다.
                if (is_selected or style.flags.inverse or style.bg(&raw, &colors.palette) != null) {
                    self.layer.cell_bg.append(allocator, .{
                        .x = cell_x,
                        .y = cell_y,
                        .w = cell_w,
                        .h = ch,
                        .color = resolveBg(style, &raw, &colors, is_selected),
                    }) catch {};
                }

                // #365 — SGR 선 속성 (밑줄 · 취소선 · 윗줄). **글리프보다 먼저**
                // 그려야 하므로 `overlay` (4번) 가 아니라 `cell_bg` (2번) 에 넣는다 —
                // 색 밑줄이 글자를 가로지르지 않게 하는 ghostty 의 선택과 같다
                // ([`cell_decoration`](../../renderer/cell_decoration.zig) 주석).
                // 같은 셀 안에서 배경 다음에 넣으므로 배경에 가리지 않고, 셀끼리는
                // 사각형이 자기 영역 안에만 있어 서로 덮지 않는다.
                //
                // **텍스트 유무와 무관하게** 여기서 만든다 — `\e[4m` 뒤의 공백에도
                // 밑줄이 이어져야 하고, `spacer_head` 처럼 글자가 없는 셀도 배경과
                // 같은 취급이다. 그래서 아래 텍스트 early-continue 보다 위에 둔다.
                if (cell_decoration.hasDecoration(style)) {
                    var deco: [cell_decoration.MAX_RECTS]cell_decoration.Rect = undefined;
                    const dn = cell_decoration.rects(
                        style,
                        resolveFg(style, &raw, &colors, is_selected),
                        &colors.palette,
                        @floatFromInt(ascent),
                        @floatFromInt(cell_w),
                        @floatFromInt(ch),
                        if (raw.wide == .wide) 2 else 1,
                        &deco,
                    );
                    // #374 — 물결은 곡선이라 가장자리 픽셀의 `cov` 가 1 미만이다.
                    // box drawing 과 같은 처리 — 공통 `blendOverRgb` 로 셀 배경과
                    // **미리** 합성해 불투명 rect 로 그린다 (#353). `cov == 1` 인
                    // 나머지 선은 합성 결과가 원래 색 그대로다.
                    const deco_bg = resolveBg(style, &raw, &colors, is_selected);
                    for (deco[0..dn]) |d| {
                        const blended = ui_metrics.blendOverRgb(
                            .{ d.color.r, d.color.g, d.color.b },
                            .{ deco_bg.r, deco_bg.g, deco_bg.b },
                            d.cov,
                        );
                        self.layer.cell_bg.append(allocator, .{
                            .x = cell_x + @as(i32, @trunc(d.x)),
                            .y = cell_y + @as(i32, @trunc(d.y)),
                            .w = @trunc(d.w),
                            .h = @trunc(d.h),
                            .color = .{ .r = blended[0], .g = blended[1], .b = blended[2] },
                        }) catch {};
                    }
                }

                // 여기부터 셀 텍스트.
                if (text_skip > 0) {
                    text_skip -= 1;
                    continue;
                }

                // **그릴 것이 없는 셀은 여기서 끝낸다.** spacer_head (wide 글자 wrap
                // 직전 행 끝 cell) 는 배경만 있고 글자는 없다 (#282 B9) — 그 배경은
                // 바로 위에서 이미 만들었다.
                if (raw.wide == .spacer_head or !raw.hasText() or raw.codepoint() == 0) continue;

                // #365 — `invisible` (SGR 8) 은 글리프를 내보내지 않는다. 선도 위에서
                // 이미 걸렀다 (`hasDecoration` 이 false) — xterm · ghostty 와 같이
                // "아무것도 안 보임" 이 SGR 8 의 의미다.
                if (style.flags.invisible) continue;

                const fg = resolveFg(style, &raw, &colors, is_selected);
                const cp = raw.codepoint();

                // Block element + shade — cell-aligned procedural rectangle / dot
                // mask. 폰트 fallback (FreeType raster) 대신 공유 모듈로 그려서
                // 인접 셀 사이 갭 / overlap 제거. Windows d3d11 / macOS Metal 가
                // 같은 모듈을 동일 의미로 사용 ([renderer/windows.zig], [renderer/macos.zig]).
                if (block_element.blockElementRect(cp)) |br| {
                    // #353 — 음영 ░▒▓ (alpha 0.25/0.5/0.75) 은 공통
                    // `ui_metrics.blendOverRgb` 로 **여기서 한 번** 합성한다. 합성
                    // 대상은 이 셀의 배경 `bg` 다 — cell bg rect 를 안 그리는 경우
                    // (`style.bg` 없음 · 미선택 · 비반전) 에도 `resolveBg` 가
                    // `colors.background` 를 돌려주고 프레임버퍼도 그 값이라 일치한다.
                    // 솔리드 블록 (alpha 1.0) 은 합성 결과가 `fg` 그대로다.
                    //
                    // `bg` 는 여기와 아래 box drawing 에서만 쓴다 — 평범한 글리프
                    // 셀에서는 해석하지 않는다 (#362).
                    const bg = resolveBg(style, &raw, &colors, is_selected);
                    const blended = ui_metrics.blendOverRgb(
                        .{ fg.r, fg.g, fg.b },
                        .{ bg.r, bg.g, bg.b },
                        br.alpha,
                    );
                    const cw_f: f32 = @floatFromInt(cell_w);
                    const ch_f: f32 = @floatFromInt(ch);
                    const bx0: i32 = cell_x + @as(i32, @trunc(br.x0 * cw_f));
                    const by0: i32 = cell_y + @as(i32, @trunc(br.y0 * ch_f));
                    const bx1: i32 = cell_x + @as(i32, @trunc(br.x1 * cw_f));
                    const by1: i32 = cell_y + @as(i32, @trunc(br.y1 * ch_f));
                    self.layer.overlay.append(allocator, .{
                        .x = bx0,
                        .y = by0,
                        .w = bx1 - bx0,
                        .h = by1 - by0,
                        .color = .{ .r = blended[0], .g = blended[1], .b = blended[2] },
                        .shade = shadeCode(br.shade),
                    }) catch {};
                    continue;
                }

                // Box-drawing (선/모서리/junction, U+2500–257F) — block element 과
                // 같은 이유로 procedural 사각형 (#258). 폰트(FreeType) 글리프는
                // cell 에 안 맞아 셀 사이 갭. 대각선은 null → 아래 글리프 path.
                if (cp >= 0x2500 and cp <= 0x257F) {
                    var box_rects: [box_drawing.MAX_RECTS]box_drawing.Rect = undefined;
                    if (box_drawing.boxRects(cp, @floatFromInt(cell_w), @floatFromInt(ch), &box_rects)) |bn| {
                        const bg = resolveBg(style, &raw, &colors, is_selected);
                        for (box_rects[0..bn]) |br| {
                            // #353 — `br.cov` (AA coverage) 도 공통
                            // `ui_metrics.blendOverRgb` 로 미리 합성하고 불투명 rect 로
                            // 그린다. **emitter 가 픽셀당 rect 를 하나만 내보내므로**
                            // (대각선은 두 선을 `@max` 로, 호는 arm·arc 거리를 `@min`
                            // 으로 합친 *뒤* emit) 한 픽셀에 blend 가 한 번뿐이고,
                            // 배경과 미리 합성한 결과가 순차 blend 와 같다.
                            // `cov == 1` 인 crisp rect 는 합성 결과가 `fg` 그대로다.
                            const cov_blend = ui_metrics.blendOverRgb(
                                .{ fg.r, fg.g, fg.b },
                                .{ bg.r, bg.g, bg.b },
                                br.cov,
                            );
                            self.layer.overlay.append(allocator, .{
                                .x = cell_x + @as(i32, @trunc(br.x)),
                                .y = cell_y + @as(i32, @trunc(br.y)),
                                .w = @as(i32, @trunc(br.w)),
                                .h = @as(i32, @trunc(br.h)),
                                .color = .{ .r = cov_blend[0], .g = cov_blend[1], .b = cov_blend[2] },
                            }) catch {};
                        }
                        continue;
                    }
                }

                // L5-5: grapheme cluster (VS-16 emoji, skin tone modifier, ZWJ
                // 시퀀스, combining mark) → HarfBuzz 로 shape 후 representative
                // single glyph 으로 reduce. cells.items(.grapheme) 가 base 외
                // extras (`[]const u21`) 슬라이스를 모든 셀에 대해 보관 (extras
                // 가 없는 cell 은 빈 슬라이스). `raw.hasGrapheme()` 가 그
                // cell 의 content_tag 가 `codepoint_grapheme` 인지 알려준다.
                //
                // mac `CoreTextFontContext.resolveGrapheme` ([renderer/macos.zig:577])
                // / Win `DWriteFontContext.resolveGrapheme` ([renderer/windows.zig:1043])
                // 와 같은 패턴 — cluster 시도 → 실패 (= 결과 glyph_index 0,
                // primary face 에 cluster glyph 없음) 면 base codepoint 의 chain
                // lookup (`glyph(cp)`) 로 fallback. emoji 같은 경우 chain 의
                // NotoColorEmoji 가 base codepoint 만 매치해도 visual 은 그대로
                // emoji.
                //
                // cluster path 는 ligature lookahead *보다 먼저* — extras 있는
                // cell 은 2-char ASCII pair 가 아니라 cluster 자체로 해석되어야
                // 함.
                if (raw.hasGrapheme() and x < graphemes.len) {
                    // #399 — **연속된 grapheme 셀을 모아 한 번에 shape 한다.** cluster 마다
                    // chain 을 처음부터 순회하며 HarfBuzz 를 새로 부르는 고정 비용이
                    // `render` 의 대부분이라, 한 줄을 묶으면 그만큼 준다. 런이 2 개 미만이면
                    // 이득이 없어 아래 개별 경로로 간다.
                    //
                    // 런 경계는 셋만 본다 (mac · Win 과 같다): 연속 grapheme 셀 ·
                    // `spacer_tail` 은 **건너뛰고 이어감** (wide cluster 뒤엔 항상 오므로
                    // 여기서 끊으면 런이 1 개씩 쪼개진다) · `invisible` 에서 끊음.
                    // **`style_id` 는 안 본다** — 글리프는 폰트에만 의존하고 색은 셀마다
                    // 따로 계산한다.
                    var run_n: usize = 0;
                    var cps_used: usize = 0;
                    var scan = x;
                    while (scan < limit and scan < raws.len and run_n < font.MAX_RUN_CLUSTERS) {
                        const rr = raws[scan];
                        if (rr.wide == .spacer_tail) {
                            scan += 1;
                            continue;
                        }
                        if (!(rr.hasText() and rr.wide != .spacer_head and rr.codepoint() != 0)) break;
                        if (!(rr.hasGrapheme() and scan < graphemes.len)) break;
                        if (rr.style_id != 0 and styles[scan].flags.invisible) break;

                        const ex = graphemes[scan];
                        // 개별 경로의 `cluster[16]` 과 같은 상한이다 (base 1 + extras 15).
                        const ex_take = @min(ex.len, font.MAX_CLUSTER_CPS - 1);
                        if (cps_used + 1 + ex_take > self.run_cps.len) break;
                        self.run_cps[cps_used] = rr.codepoint();
                        @memcpy(self.run_cps[cps_used + 1 ..][0..ex_take], ex[0..ex_take]);
                        self.run_slices[run_n] = self.run_cps[cps_used..][0 .. 1 + ex_take];
                        self.run_cells[run_n] = @intCast(scan);
                        cps_used += 1 + ex_take;
                        run_n += 1;
                        scan += 1;
                    }

                    if (run_n >= 2 and
                        self.font_ctx.resolveClusterRun(self.run_slices[0..run_n], self.run_results[0..run_n]) == run_n)
                    {
                        for (0..run_n) |i| {
                            const rx: usize = self.run_cells[i];
                            const rr = raws[rx];
                            // 색은 셀마다 다시 계산한다 — 런을 style 로 끊지 않기 때문이다.
                            const rs = if (rr.style_id != 0) styles[rx] else ghostty.Style{};
                            const rst = cell_color.applyBlinkPhase(rs, blink_faint);
                            const rx16: u16 = @intCast(rx);
                            const rsel = if (sel_range) |sr| (rx16 >= sr[0] and rx16 <= sr[1]) else false;
                            const cg = self.run_results[i];
                            appendGlyph(&self.layer.glyphs, allocator, .{
                                .ref = clusterRef(cg),
                                .glyph = clusterGlyph(&self.font_ctx, cg),
                                .cell_x = pad + @as(i32, @intCast(rx)) * cw,
                                .cell_y = cell_y,
                                .cell_w = if (rr.wide == .wide) cw * 2 else cw,
                                .cell_h = ch,
                                .ascent = ascent,
                                .x_offset = cg.x_offset,
                                .y_offset = cg.y_offset,
                                .fg = resolveFg(rst, &rr, &colors, rsel),
                            });
                        }
                        // **`x` 를 점프하지 않는다.** 이 셀 루프는 셀마다 배경 · 선택 · 커서를
                        // 먼저 만들고 나서 텍스트로 오기 때문에, 건너뛰면 그 셀들의 배경이
                        // 통째로 사라진다 (mac · Win 은 배경을 따로 모아서 점프해도 됐다).
                        // `text_skip` 은 **텍스트만** 건너뛴다 — ligature 경로가 쓰는 그
                        // 변수다. `spacer_tail` 은 루프 맨 위에서 먼저 `continue` 되어 이 값을
                        // 소비하지 않으므로, wide cluster 가 섞여도 수가 어긋나지 않는다.
                        text_skip = run_n - 1;
                        continue;
                    }

                    var cluster: [16]u21 = undefined;
                    cluster[0] = cp;
                    const extras = graphemes[x];
                    const take = @min(extras.len, cluster.len - 1);
                    @memcpy(cluster[1..][0..take], extras[0..take]);
                    if (self.font_ctx.resolveCluster(cluster[0 .. 1 + take])) |cg| {
                        appendGlyph(&self.layer.glyphs, allocator, .{
                            .ref = clusterRef(cg),
                            .glyph = clusterGlyph(&self.font_ctx, cg),
                            .cell_x = cell_x,
                            .cell_y = cell_y,
                            .cell_w = cell_w,
                            .cell_h = ch,
                            .ascent = ascent,
                            .x_offset = cg.x_offset,
                            .y_offset = cg.y_offset,
                            .fg = fg,
                        });
                        continue;
                    }
                    // resolveCluster null → primary face 에 cluster 매치 없음.
                    // 아래 base codepoint chain lookup 으로 fallthrough (extras
                    // 무시되지만 base 는 emoji face 등에서 매치 → 시각상 합리).
                }

                // L5-2-β: ligature lookahead. 다음 cell 들도 plain single
                // codepoint + non-wide + same style + ASCII printable 범위면
                // `ligaturePair` / `ligatureTriple` 시도. HarfBuzz shape 결과가
                // ligature 면 첫 cell 위치에 N-cell 너비 글리프 (또는 cell 별
                // spacer glyph). cache 가 같은 ASCII 조합 결과를 보관해 매 frame
                // 매 cell shape 호출을 피한다.
                //
                // 조건: 전부 narrow, single codepoint, style_id 일치 (= 같은
                // attribute, fg / bg / flags 등). 다른 색 / underline 등 다른
                // style 의 cell pair 는 ligature 안 — terminal 의 자연스러운
                // 의미 (color 분리 = 의도된 두 문자).
                //
                // 3-char 를 2-char 보다 *먼저* 시도해야 `===` 가 `==` + `=` 로
                // 분해되지 않는다.
                if (x + 2 < cols and x + 2 < raws.len and raw.wide == .narrow and isLigatureCandidate(cp)) {
                    const next = raws[x + 1];
                    const next2 = raws[x + 2];
                    if (next.wide == .narrow and next.hasText() and next.codepoint() != 0 and
                        next.style_id == raw.style_id and isLigatureCandidate(next.codepoint()) and
                        next2.wide == .narrow and next2.hasText() and next2.codepoint() != 0 and
                        next2.style_id == raw.style_id and isLigatureCandidate(next2.codepoint()))
                    {
                        if (self.font_ctx.ligatureTriple(cp, next.codepoint(), next2.codepoint())) |lm| {
                            self.collectLigatureMatch(allocator, lm, cell_x, cell_y, cw, ch, ascent, 3, fg);
                            text_skip = 2;
                            continue;
                        }
                    }
                }

                if (x + 1 < cols and x + 1 < raws.len and raw.wide == .narrow and isLigatureCandidate(cp)) {
                    const next = raws[x + 1];
                    if (next.wide == .narrow and next.hasText() and next.codepoint() != 0 and
                        next.style_id == raw.style_id and isLigatureCandidate(next.codepoint()))
                    {
                        if (self.font_ctx.ligaturePair(cp, next.codepoint())) |lm| {
                            self.collectLigatureMatch(allocator, lm, cell_x, cell_y, cw, ch, ascent, 2, fg);
                            text_skip = 1;
                            continue;
                        }
                    }
                }

                // #375 — SGR 1 / 3 이 요구하는 face 변종. 없는 family 는 폰트 모듈이
                // regular 로 떨어뜨린다.
                const face_style = font_constants.FaceStyle.from(style.flags.bold, style.flags.italic);
                appendGlyph(&self.layer.glyphs, allocator, .{
                    .ref = .{ .codepoint = cp },
                    .glyph = self.font_ctx.glyph(cp, face_style),
                    .face_style = face_style,
                    .cell_x = cell_x,
                    .cell_y = cell_y,
                    .cell_w = cell_w,
                    .cell_h = ch,
                    .ascent = ascent,
                    .fg = fg,
                });
            }
        }
    }

    /// 2-cell 또는 3-cell ligature. `LigatureMatch` 의 `.single` (입력 N chars →
    /// 1 glyph, N-cell wide draw, JetBrains Mono / Cascadia Code 패턴) 과
    /// `.spacer` (입력 N chars → N glyphs each at own cell, Fira Code 패턴) 둘 다.
    ///
    /// 뒤따르는 N-1 cells 의 배경은 여기서 만들지 않는다 — 부르는 쪽 루프가 셀을
    /// 하나씩 돌며 (`text_skip` 은 텍스트만 건너뛴다) 이미 같은 조건으로 만든다.
    fn collectLigatureMatch(
        self: *Renderer,
        allocator: std.mem.Allocator,
        match: font.LigatureMatch,
        cell_x: i32,
        cell_y: i32,
        cw: i32,
        ch: i32,
        ascent: i32,
        count: usize,
        fg: ghostty.color.RGB,
    ) void {
        switch (match) {
            .single => |lg| {
                // 1 glyph 이 N-cell 너비 차지 — center 정렬 (count × cw 안).
                appendGlyph(&self.layer.glyphs, allocator, .{
                    .ref = .{ .indexed = .{ .face = lg.face_idx, .index = lg.glyph_index } },
                    .glyph = self.font_ctx.glyphByIndex(lg.face_idx, lg.glyph_index),
                    .cell_x = cell_x,
                    .cell_y = cell_y,
                    .cell_w = cw * @as(i32, @intCast(count)),
                    .cell_h = ch,
                    .ascent = ascent,
                    .x_offset = lg.x_offset,
                    .y_offset = lg.y_offset,
                    .fg = fg,
                });
            },
            .spacer => |sp| {
                // N glyph 을 각 cell 에 (1-cell wide each). Fira Code 의 spacer pattern.
                const n = @min(@as(usize, sp.count), count);
                for (0..n) |i| {
                    appendGlyph(&self.layer.glyphs, allocator, .{
                        .ref = .{ .indexed = .{ .face = sp.face_idx, .index = sp.glyph_indices[i] } },
                        .glyph = self.font_ctx.glyphByIndex(sp.face_idx, sp.glyph_indices[i]),
                        .cell_x = cell_x + @as(i32, @intCast(i)) * cw,
                        .cell_y = cell_y,
                        .cell_w = cw,
                        .cell_h = ch,
                        .ascent = ascent,
                        .x_offset = sp.x_offsets[i],
                        .y_offset = sp.y_offsets[i],
                        .fg = fg,
                    });
                }
            },
        }
    }

    /// Cursor (#297 — 세로 막대 bar, 세 platform 공통). 셀 좌측에 opaque bar.
    /// wide char 는 wide_tail 보정으로 글자 시작 cell 의 좌측에 위치. 폭은
    /// `ui_metrics.CURSOR_BAR_W_PT` × scale (Windows/macOS 와 동일 식).
    fn collectCursor(self: *Renderer, allocator: std.mem.Allocator, pane: pane_draw.PaneDraw) void {
        const state = pane.state;
        if (!state.cursor.visible) return;
        const vp = state.cursor.viewport orelse return;
        const cw = pane.cell_w;
        const ch = pane.cell_h;
        const pad = pane.pad;
        var cx: i32 = pane.rect.x + pad + @as(i32, @intCast(vp.x)) * cw;
        if (vp.wide_tail and vp.x > 0) cx -= cw;
        self.layer.overlay.append(allocator, .{
            .x = cx,
            .y = pane.rect.y + pad + @as(i32, @intCast(vp.y)) * ch,
            .w = @trunc(ui_metrics.cursorBarWidthPx(self.scale)),
            .h = ch,
            .color = state.colors.cursor orelse .{ .r = 180, .g = 180, .b = 180 },
        }) catch {};
    }

    /// #343 단계 2 — scrollbar thumb 의 rect 와 색은 공통 `scrollbar.thumbRect`
    /// 한 곳이 만든다 (track 자체는 별도 색 없이 배경 그대로 — 세 platform 동일).
    /// #259 — drag hit-test (`wayland_minimal.scrollbarHit`) 와 같은 입력.
    fn collectScrollbar(self: *Renderer, allocator: std.mem.Allocator, pane: pane_draw.PaneDraw) void {
        const colors = pane.state.colors;
        // #483 2단계 ② — track 은 pane 기준이다. `thumbRect` 의 viewport 인자에 pane 의 오른쪽 · 아래
        // **가장자리**를, track_top 에 `rect.y + scrollbar_top_inset` 을 넘기면 같은 식이 pane
        // 좌표계에서 성립한다 (pane 하나면 이전 인자와 값이 같다 — inset 은 host 가 `chromeHeightPx
        // − tab_bar_h` 로 만든다).
        const sb = pane.terminal.screens.active.pages.scrollbar();
        const r = scrollbar.thumbRect(
            sb.total,
            sb.len,
            sb.offset,
            @floatFromInt(pane.rect.x + pane.rect.w),
            @floatFromInt(pane.rect.y + pane.rect.h),
            @floatFromInt(pane.rect.y + pane.scrollbar_top_inset),
            @floatFromInt(pane.pad),
            pane.scrollbar_min_thumb_h,
            pane.scrollbar_w,
            .{ colors.background.r, colors.background.g, colors.background.b },
        ) orelse return;
        // 정수 격자 스냅과 색 변환은 chrome 그리기와 같은 규칙을 쓴다 (#357).
        const i = tab_chrome.snap(r);
        self.layer.overlay.append(allocator, .{
            .x = i.x,
            .y = i.y,
            .w = i.w,
            .h = i.h,
            .color = rgbFromMetrics(r.color),
        }) catch {};
    }

    /// L10-β — IME preedit (조합 중) inline overlay. cursor 위치부터 preedit_text
    /// 의 codepoint 별로 보라색 배경 + foreground 글자. AGENTS.md "한글 IME 동작
    /// 스펙" — "강조 배경 (보라색 계열) + 글자로 inline 표시. 별도 candidate window
    /// 안 띄움". macOS / Windows 와 동등 색 (`renderer/macos.zig:686`,
    /// `renderer/windows.zig:1144`). PTY 에는 들어가지 않고 화면 표시만 — fcitx5 가
    /// commit_string 으로 음절 완성 보내주면 그때 PTY 송신 + preedit 클리어.
    fn collectPreedit(self: *Renderer, allocator: std.mem.Allocator, pane: pane_draw.PaneDraw) void {
        const state = pane.state;
        if (pane.preedit_utf8.len == 0) return;
        const vp = state.cursor.viewport orelse return;

        // 보라색 배경 — macOS Metal `pre_bg_color = .{0.25, 0.25, 0.5, 1}` 와
        // 동일 색. 8-bit RGB 환산 64 / 64 / 128.
        const preedit_bg = ghostty.color.RGB{ .r = 64, .g = 64, .b = 128 };
        const cw = pane.cell_w;
        const ch = pane.cell_h;
        const ascent: i32 = @intCast(self.font_ctx.ascent_px);
        const pad = pane.pad;
        const cols = state.cols;
        const fg = state.colors.foreground;
        const pre_y: i32 = pane.rect.y + pad + @as(i32, @intCast(vp.y)) * ch;

        var col: i32 = @intCast(vp.x);
        var utf8_iter = std.unicode.Utf8Iterator{ .bytes = pane.preedit_utf8, .i = 0 };
        while (utf8_iter.nextCodepoint()) |cp| {
            const w_cells: i32 = @intCast(display_width.codepointWidth(cp));
            if (w_cells <= 0) continue;
            if (col + w_cells > @as(i32, @intCast(cols))) break;

            const cell_x: i32 = pane.rect.x + pad + col * cw;
            const cell_w: i32 = w_cells * cw;
            self.layer.preedit_bg.append(allocator, .{
                .x = cell_x,
                .y = pre_y,
                .w = cell_w,
                .h = ch,
                .color = preedit_bg,
            }) catch {};
            appendGlyph(&self.layer.preedit_glyphs, allocator, .{
                .ref = .{ .codepoint = cp },
                .glyph = self.font_ctx.glyph(cp, .regular),
                .cell_x = cell_x,
                .cell_y = pre_y,
                .cell_w = cell_w,
                .cell_h = ch,
                .ascent = ascent,
                .fg = fg,
            });
            col += w_cells;
        }
    }

    /// #277 S2-5 — 탭바. rect 목록과 그 **순서**는 공통 `tab_chrome` 이 만들고
    /// (#343), 여기서는 사이사이에 이 renderer 고유인 제목 / 아이콘을 끼운다.
    ///
    /// 넘기는 metric 은 이 renderer 가 쓰던 값 그대로다 (`scaledPt` 로 이미 반올림된
    /// 정수). f32 renderer 는 소수를 그대로 넘긴다 — 모듈은 단위에 관여하지 않는다.
    /// #357 — 선 두께는 공통 `ui_metrics.linePx` 한 곳에서 정수 px 로 온다.
    fn collectTabBar(self: *Renderer, allocator: std.mem.Allocator, in: FrameInputs, tab_bar_h: i32) void {
        if (tab_bar_h <= 0 or in.width <= 0 or in.tab_titles.len == 0) return;

        const scale = self.scale;
        const tab_w = self.tabWidthPx();
        const tab_pad = self.tabPaddingPx();
        const chrome_in = tab_chrome.Inputs{
            .viewport_w = @floatFromInt(in.width),
            .tab_bar_h = @floatFromInt(tab_bar_h),
            .tab_w = @floatFromInt(tab_w),
            .sep_w = ui_metrics.linePx(ui_metrics.TAB_SEPARATOR_W_PT, scale),
            .underline_h = ui_metrics.linePx(ui_metrics.TAB_ACTIVE_UNDERLINE_PT, scale),
            .hover_inset = @round(ui_metrics.tabGapPx(scale).control_hover_inset),
            .tab_count = in.tab_titles.len,
            .active_idx = in.active_tab_idx,
            .scroll_x = in.tab_scroll_x,
            .drag = in.drag_view,
            .layout = in.layout,
            .hover = in.tab_hover,
            .palette = &self.chrome,
        };
        var chrome_rects: [tab_chrome.maxRects(session_core.MAX_TABS)]tab_chrome.Rect = undefined;
        const built = tab_chrome.build(&chrome_rects, chrome_in);
        for (built.rects[0..built.before_titles]) |r| self.appendChromeRect(allocator, &self.layer.chrome_before, r);

        // #342 — 탭바-터미널 가로 경계선은 제거됐다 (2026-07-27 사용자 결정).
        const text_color = rgbFromMetrics(self.chrome.tab_text);
        const ascent: i32 = @intCast(self.tab_font_ctx.ascent_px);
        const descent: i32 = @intCast(self.tab_font_ctx.descent_px);
        const text_baseline: i32 = @divFloor(tab_bar_h + ascent - descent, 2);
        const tab_x_inset: i32 = @round(ui_metrics.tabGapPx(scale).tab_horizontal_inset);
        // max_text_w — #268 per-tab close 제거로 탭 전체 (양쪽 padding 제외).
        const max_text_w: i32 = tab_w - tab_pad * 2;
        const tab_area_x: i32 = @trunc(in.layout.tab_area_x);
        const tab_area_end: i32 = tab_area_x + @as(i32, @trunc(in.layout.tab_area_w));

        // --- 각 탭의 제목 (tab_area 안에서 clipping) ---
        // 탭 x 와 화면 밖 판정도 공통 모듈(`tabX` / `tabClip`) 을 쓴다 — 밑줄과
        // 제목이 어긋나지 않게 한다.
        for (in.tab_titles, 0..) |title, i| {
            // #343 — 공통 계약: 이 인덱스는 맨 마지막에 그린다 (집어 든 탭이 맨 위 layer).
            if (built.deferred_title) |d| if (d == i) continue;
            const tab_screen_x: i32 = @trunc(tab_chrome.tabX(i, chrome_in));
            switch (tab_chrome.tabClip(
                @floatFromInt(tab_screen_x),
                @floatFromInt(tab_w),
                @floatFromInt(tab_area_x),
                @floatFromInt(tab_area_end),
                in.drag_view != null,
            )) {
                .skip => continue,
                .stop => break,
                .draw => {},
            }
            self.collectTabTitle(allocator, .{
                .tab_bar_h = tab_bar_h,
                .tab_x = tab_screen_x + tab_x_inset,
                .tab_pad = tab_pad,
                .tab_area_x = tab_area_x,
                .tab_area_end = tab_area_end,
                .text_baseline = text_baseline,
                .max_text_w = max_text_w,
                .title = title,
                .text_color = text_color,
            });
        }

        // #343 — 제목 뒤 구간: 컨트롤 bg fill → hover 박스 → 세로 구분선 →
        // (드래그 중이면) 집어 든 탭의 밑줄.
        for (built.rects[built.before_titles..]) |r| self.appendChromeRect(allocator, &self.layer.chrome_before, r);

        // #343 — 드래그 중인 탭의 제목을 **맨 마지막에** — 집어 든 탭이 다른 탭의
        // 세로선·제목 위로 온다 (2026-07-31 사용자 결정). 텍스트끼리는 잘라 낼 수
        // 없으므로 이것만은 지오메트리가 아니라 layer 순서로 표현한다.
        if (built.deferred_title) |di| {
            if (di < in.tab_titles.len) {
                const dx: i32 = @trunc(tab_chrome.tabX(di, chrome_in));
                if (tab_chrome.tabClip(
                    @floatFromInt(dx),
                    @floatFromInt(tab_w),
                    @floatFromInt(tab_area_x),
                    @floatFromInt(tab_area_end),
                    true,
                ) == .draw) {
                    self.collectTabTitle(allocator, .{
                        .tab_bar_h = tab_bar_h,
                        .tab_x = dx + tab_x_inset,
                        .tab_pad = tab_pad,
                        .tab_area_x = tab_area_x,
                        .tab_area_end = tab_area_end,
                        .text_baseline = text_baseline,
                        .max_text_w = max_text_w,
                        .title = in.tab_titles[di],
                        .text_color = text_color,
                    });
                }
            }
        }

        self.collectControlIcons(allocator, &self.layer.chrome_before, tab_bar_h, in.layout);
    }

    const TabTitle = struct {
        tab_bar_h: i32,
        tab_x: i32,
        tab_pad: i32,
        tab_area_x: i32,
        tab_area_end: i32,
        text_baseline: i32,
        max_text_w: i32,
        title: []const u8,
        text_color: ghostty.color.RGB,
    };

    /// 탭 제목 한 개. 글자 위치와 ellipsis 판단은 공통 `tab_layout.iterTabText` 가
    /// 한다 — 세 platform 이 같은 자리에 같은 글자를 놓는다.
    fn collectTabTitle(self: *Renderer, allocator: std.mem.Allocator, t: TabTitle) void {
        const cw_f: f32 = @floatFromInt(self.tab_font_ctx.cell_width_px);
        const max_text_w_f: f32 = @floatFromInt(t.max_text_w);
        // mac/win 동등 — 짧은 title 은 truncate 안 함 (ellipsis 안 그림).
        const total_text_w_f: f32 = @as(f32, @floatFromInt(display_width.stringWidth(t.title))) * cw_f;
        const needs_truncate = total_text_w_f > max_text_w_f;

        const Ctx = struct {
            renderer: *Renderer,
            allocator: std.mem.Allocator,
            t: TabTitle,
            /// L12-γ scroll 잘림 fix — 부분 잘린 첫 보이는 탭은 시작 x 가
            /// `tab_area_x` 보다 왼쪽으로 음수 가능 → clip 검사가 무효화되어 화살표
            /// 영역을 침범한다. 좌측도 `tab_area_x` 로 clamp 한다.
            viewport_left: i32,
        };
        const ctx = Ctx{
            .renderer = self,
            .allocator = allocator,
            .t = t,
            .viewport_left = t.tab_area_x,
        };

        tab_layout.iterTabText(
            t.title,
            @floatFromInt(t.tab_x + t.tab_pad),
            cw_f,
            max_text_w_f,
            needs_truncate,
            ctx,
            struct {
                fn emit(c: Ctx, g: tab_layout.Glyph) void {
                    // #343 A-2 — glyph 를 통째로 버리지 않고 `tab_area` 경계에서
                    // **픽셀 단위로 잘라** 안쪽만 그린다.
                    appendChromeGlyph(&c.renderer.layer.chrome_before, c.allocator, .{
                        .ref = .{ .codepoint = g.cp },
                        .glyph = c.renderer.tab_font_ctx.glyph(g.cp, .regular),
                        .pen_x = @trunc(g.x),
                        .baseline = c.t.text_baseline,
                        .box_y = 0,
                        .box_w = @trunc(g.advance),
                        .box_h = c.t.tab_bar_h,
                        .fg = c.t.text_color,
                        .clip_x0 = c.viewport_left,
                        .clip_x1 = c.t.tab_area_end,
                    });
                }
            }.emit,
        );
    }

    /// #268 — 컨트롤 아이콘 (`< > × + …`). 공통 `tab_icons` 가 알파 커버리지
    /// 비트맵을 만든다 (폰트 독립). mac/win 은 같은 비트맵을 atlas 에 올려 그리므로
    /// 세 platform 픽셀이 같다.
    ///
    /// enabled = `ctrl_active` (밝은 흰색), disabled = `arrow_disabled` (회색).
    /// scroll 왼쪽 끝이면 `<` 회색, 우측 끝이면 `>` 회색. `+` 는 MAX_TABS 도달 시
    /// 회색 (#329) — 자리는 유지한다.
    fn collectControlIcons(
        self: *Renderer,
        allocator: std.mem.Allocator,
        list: *std.ArrayList(ChromeItem),
        bar_h: i32,
        layout: tab_layout.Layout,
    ) void {
        const scale = self.scale;
        const active_color = rgbFromMetrics(self.chrome.ctrl_active);
        const disabled_color = rgbFromMetrics(self.chrome.arrow_disabled);
        const size_i: i32 = scaledPt(ui_metrics.TAB_ICON_SIZE_PT, scale);
        const size: u32 = @intCast(@max(1, @min(@as(i32, @intCast(tab_icons.MAX_SIZE)), size_i)));
        const stroke: f32 = ui_metrics.strokePx(ui_metrics.TAB_ICON_STROKE_PT, scale);
        const more_stroke: f32 = ui_metrics.strokePx(ui_metrics.TAB_MORE_DOT_DIAMETER_PT, scale);

        if (layout.arrows_visible) {
            const arrow_w: i32 = @trunc(layout.arrow_w);
            self.appendIcon(allocator, list, .chevron_left, @trunc(layout.left_arrow_x), arrow_w, bar_h, size, stroke, if (layout.left_enabled) active_color else disabled_color);
            self.appendIcon(allocator, list, .chevron_right, @trunc(layout.right_arrow_x), arrow_w, bar_h, size, stroke, if (layout.right_enabled) active_color else disabled_color);
        }
        self.appendIcon(allocator, list, .plus, @trunc(layout.plus_x), @trunc(layout.plus_w), bar_h, size, stroke, if (layout.plus_enabled) active_color else disabled_color);
        // #268 — 우측 끝 활성 탭 닫기 버튼.
        self.appendIcon(allocator, list, .close, @trunc(layout.close_x), @trunc(layout.close_w), bar_h, size, stroke, active_color);
        self.appendIcon(allocator, list, .more, @trunc(layout.more_x), @trunc(layout.more_w), bar_h, size, more_stroke, active_color);
    }

    /// 아이콘을 box 가운데에 놓는다.
    fn appendIcon(
        self: *Renderer,
        allocator: std.mem.Allocator,
        list: *std.ArrayList(ChromeItem),
        kind: tab_icons.Icon,
        box_x: i32,
        box_w: i32,
        box_h: i32,
        size: u32,
        stroke: f32,
        color: ghostty.color.RGB,
    ) void {
        _ = self;
        const size_i: i32 = @intCast(size);
        list.append(allocator, .{ .icon = .{
            .kind = kind,
            .size = size,
            .stroke = stroke,
            .x = box_x + @divFloor(box_w - size_i, 2),
            .y = @divFloor(box_h - size_i, 2),
            .color = color,
        } }) catch {};
    }

    /// #329 — 단일 탭은 terminal grid 를 y=0 에 둔 채 우측 상단 `[+][×][…]`
    /// 72×28pt 만 마지막 chrome layer 로 overlay 한다.
    fn collectSingleTabControls(self: *Renderer, allocator: std.mem.Allocator, in: FrameInputs) void {
        if (in.tab_titles.len != 1) return;
        const bar_h = self.chromeHeightPx();
        const controls = tab_layout.computeControls(
            @floatFromInt(in.width),
            @floatFromInt(self.tabPlusWPx()),
            @floatFromInt(self.tabCloseWPx()),
            @floatFromInt(self.tabMoreWPx()),
        );
        const overlay_layout = tab_layout.Layout{
            .tab_area_x = 0,
            .tab_area_w = 0,
            .arrows_visible = false,
            .arrow_w = 0,
            .plus_w = controls.plus_w,
            .plus_x = controls.plus_x,
            .close_w = controls.close_w,
            .close_x = controls.close_x,
            .more_w = controls.more_w,
            .more_x = controls.more_x,
        };
        // #343 — 컨트롤 bg fill · hover 는 탭바 경로와 같은 `tab_chrome`
        // (`buildControlsOnly`) 이 만든다. 탭바 전체 배경 · 밑줄 · 구분선은 단일 탭
        // overlay 에 없으므로 컨트롤 구간만 쓴다.
        var overlay_rects: [tab_chrome.maxRects(0)]tab_chrome.Rect = undefined;
        for (tab_chrome.buildControlsOnly(&overlay_rects, .{
            .viewport_w = @floatFromInt(in.width),
            .tab_bar_h = @floatFromInt(bar_h),
            .tab_w = 0,
            .sep_w = 0,
            .underline_h = 0,
            .hover_inset = @round(ui_metrics.tabGapPx(self.scale).control_hover_inset),
            .tab_count = 0,
            .active_idx = 0,
            .scroll_x = 0,
            .drag = null,
            .layout = overlay_layout,
            .hover = in.tab_hover,
            .palette = &self.chrome,
        })) |r| self.appendChromeRect(allocator, &self.layer.chrome_after, r);

        self.collectControlIcons(allocator, &self.layer.chrome_after, bar_h, overlay_layout);
    }

    /// chrome 사각형 — 정수 격자 스냅과 색 변환은 한 곳(`tab_chrome.snap` +
    /// `rgbFromMetrics`)에서만 한다 (#357).
    fn appendChromeRect(
        self: *Renderer,
        allocator: std.mem.Allocator,
        list: *std.ArrayList(ChromeItem),
        r: tab_chrome.Rect,
    ) void {
        _ = self;
        const i = tab_chrome.snap(r);
        list.append(allocator, .{ .rect = .{
            .x = i.x,
            .y = i.y,
            .w = i.w,
            .h = i.h,
            .color = rgbFromMetrics(r.color),
        } }) catch {};
    }

    pub fn paint(
        self: *Renderer,
        allocator: std.mem.Allocator,
        memory: []u8,
        stride: i32,
        in: FrameInputs,
    ) void {
        const width = in.width;
        const height = in.height;
        for (in.panes) |p| p.state.update(allocator, p.terminal) catch {
            fill(memory, width, height, stride, in.theme.background);
            return;
        };

        fill(memory, width, height, stride, frameBackground(in));

        // #277 S2-4/S2-5 — **목록은 GL 경로와 같은 수집기가 만들고 여기서는 그리기만
        // 한다.** 순서는 `FrameLayer` 가 정의하고 두 경로가 그대로 따른다.
        self.collectFrame(allocator, in);
        for (self.layer.chrome_before.items) |it| drawChromeItem(memory, width, height, stride, it);
        for (self.layer.cell_bg.items) |r| drawSolidRect(memory, width, height, stride, r);
        for (self.layer.glyphs.items) |*g| drawGlyphItem(memory, width, height, stride, g);
        for (self.layer.overlay.items) |r| drawSolidRect(memory, width, height, stride, r);
        for (self.layer.preedit_bg.items) |r| drawSolidRect(memory, width, height, stride, r);
        for (self.layer.preedit_glyphs.items) |*g| drawGlyphItem(memory, width, height, stride, g);
        for (self.layer.chrome_after.items) |it| drawChromeItem(memory, width, height, stride, it);

        // --- L13-γ: opacity alpha sweep ---
        // ARGB8888 buffer 의 alpha byte 를 self.opacity_alpha 로 일괄 채움.
        // pack / rect / drawGlyph / drawGlyphBgra 등 모든 pixel write 함수가
        // RGB 만 채우고 alpha byte (high byte) 는 0 으로 두는 대신, paint
        // 마지막에 한 번 sweep — 함수 시그니처 / 호출 site 의 변경 폭을
        // 줄이고 alpha 미적용 누락도 자동으로 막힘. opacity=255 (= 100%) 면
        // 시각 변화 없음 — compositor 가 fully opaque 로 합성.
        {
            const opacity = self.opacity_alpha;
            var py: i32 = 0;
            while (py < height) : (py += 1) {
                var px: i32 = 0;
                while (px < width) : (px += 1) {
                    const off: usize = @intCast(py * stride + px * 4);
                    memory[off + 3] = opacity;
                }
            }
        }
    }

    /// #277 S2-5 — command menu. #343 단계 3 — 메뉴 배경 · 강조 박스 · 항목
    /// 구분선의 rect 와 그 순서는 공통 `command_menu.rects` 한 곳이 만든다. 여기
    /// 남은 것은 텍스트와 스크롤 표시 아이콘뿐이다.
    fn collectCommandMenu(self: *Renderer, allocator: std.mem.Allocator, in: FrameInputs) void {
        const scale = self.scale;
        const ui = in.menu_ui;
        // #329 — viewport 높이에 맞춰 entry 단위로 자른 View. 안 보이는 entry 는
        // 그리지 않는다 (부분 행 없음 — scroll 은 first_visible 로).
        const v = command_menu.view(
            @as(f32, @floatFromInt(in.width)) / scale,
            @as(f32, @floatFromInt(in.height)) / scale,
            @floatFromInt(ui_metrics.TAB_BAR_HEIGHT_PT),
            ui.first_visible,
        );
        const mx: i32 = @round(v.rect.x * scale);
        const mw: i32 = @round(v.rect.w * scale);
        const fg = rgbFromMetrics(self.chrome.menu_label);
        const hint_fg = rgbFromMetrics(self.chrome.menu_hint);
        const list = &self.layer.chrome_after;

        var menu_rects: [command_menu.MAX_RECTS]tab_chrome.Rect = undefined;
        for (command_menu.rects(&menu_rects, v, ui, scale, &self.chrome)) |r| {
            self.appendChromeRect(allocator, list, r);
        }

        // #334 — 잘림 상태의 상/하단 스크롤 표시 행 (탭바 `<`/`>` 관례: 끝에 닿으면
        // 비활성 색, 클릭 = 한 entry 스크롤).
        if (v.clipped) {
            const ind_size_i: i32 = scaledPt(ui_metrics.MENU_INDICATOR_ICON_PT, scale);
            const ind_size: u32 = @intCast(@max(1, @min(@as(i32, @intCast(tab_icons.MAX_SIZE)), ind_size_i)));
            const ind_stroke: f32 = ui_metrics.strokePx(ui_metrics.TAB_ICON_STROKE_PT, scale);
            const active_fg = rgbFromMetrics(self.chrome.ctrl_active);
            const disabled_fg = rgbFromMetrics(self.chrome.arrow_disabled);
            const sz_i: i32 = @intCast(ind_size);
            const ind_cx: i32 = mx + @divTrunc(mw - sz_i, 2);
            const up_y: i32 = @round((v.rect.y + command_menu.PADDING_PT + command_menu.INDICATOR_HEIGHT_PT * 0.5) * scale - @as(f32, @floatFromInt(sz_i)) * 0.5);
            const down_y: i32 = @round((v.rect.y + v.rect.h - command_menu.PADDING_PT - command_menu.INDICATOR_HEIGHT_PT * 0.5) * scale - @as(f32, @floatFromInt(sz_i)) * 0.5);
            const pairs = [2]struct { kind: tab_icons.Icon, y: i32, enabled: bool }{
                .{ .kind = .chevron_up, .y = up_y, .enabled = v.can_scroll_up },
                .{ .kind = .chevron_down, .y = down_y, .enabled = v.can_scroll_down },
            };
            for (pairs) |p| {
                list.append(allocator, .{ .icon = .{
                    .kind = p.kind,
                    .size = ind_size,
                    .stroke = ind_stroke,
                    .x = ind_cx,
                    .y = p.y,
                    .color = if (p.enabled) active_fg else disabled_fg,
                } }) catch {};
            }
        }

        const cw: i32 = @intCast(self.tab_font_ctx.cell_width_px);
        const ch: i32 = @intCast(self.tab_font_ctx.cell_height_px);
        for (v.first..v.first + v.count) |i| {
            const command = command_menu.entries[i] orelse continue; // 구분선은 위에서
            const item = command_menu.entryRect(v, i).?;
            const ix: i32 = @round(item.x * scale);
            const iw: i32 = @round(item.w * scale);
            const ih: i32 = @round(item.h * scale);
            const iy: i32 = @round(item.y * scale);
            const baseline = iy + @divFloor(ih - ch, 2) + @as(i32, @intCast(self.tab_font_ctx.ascent_px));
            const label = command_menu.label(command);
            self.collectChromeText(allocator, list, ix + scaledPt(8, scale), baseline, ch, label, fg, in.width);
            const hint = command_menu.shortcut(command, false, in.toggle_hotkey, ui.fullscreen_workarea);
            if (hint.len == 0) continue;
            const hint_w = @as(i32, @intCast(display_width.stringWidth(hint))) * cw;
            const label_w = @as(i32, @intCast(display_width.stringWidth(label))) * cw;
            // #329 — 좁은 메뉴 / 긴 configured hotkey 에서 label 과 겹치면 hint 를
            // 먼저 숨긴다 (label 우선 정책, 세 renderer 공통).
            if (command_menu.hintFits(item.w, @as(f32, @floatFromInt(label_w)) / scale, @as(f32, @floatFromInt(hint_w)) / scale)) {
                self.collectChromeText(allocator, list, ix + iw - scaledPt(8, scale) - hint_w, baseline, ch, hint, hint_fg, in.width);
            }
        }
    }

    /// cell-aligned chrome 텍스트 한 줄 (탭 폰트). ligature / cluster shape 이
    /// 필요 없는 자리 — 메뉴 항목처럼 짧은 label 에 쓴다.
    fn collectChromeText(
        self: *Renderer,
        allocator: std.mem.Allocator,
        list: *std.ArrayList(ChromeItem),
        start_x: i32,
        baseline: i32,
        line_h: i32,
        text: []const u8,
        fg: ghostty.color.RGB,
        clip_x1: i32,
    ) void {
        const cw: i32 = @intCast(self.tab_font_ctx.cell_width_px);
        var x: i32 = start_x;
        var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (iter.nextCodepoint()) |cp| {
            if (x >= clip_x1) break;
            const adv: i32 = cw * @as(i32, @intCast(display_width.codepointWidth(cp)));
            appendChromeGlyph(list, allocator, .{
                .ref = .{ .codepoint = cp },
                .glyph = self.tab_font_ctx.glyph(cp, .regular),
                .pen_x = x,
                .baseline = baseline,
                .box_y = baseline - line_h,
                .box_w = adv,
                .box_h = line_h,
                .fg = fg,
                .clip_x0 = 0,
                .clip_x1 = clip_x1,
            });
            x += adv;
        }
    }

    /// #203 Phase C step 3 — 별 layer-shell overlay dialog surface 의 buffer
    /// 그리기. main paint 와 달리 dim / wallpaper 합성 없음 (별 surface 라
    /// compositor 가 main 위 modal 로 합성). buffer = 박스 + drop shadow 영역.
    ///
    /// 좌표계 — 박스 = (sm, sm) ~ (buffer_w - sm, buffer_h - sm). 모든 텍스트 /
    /// 배경 그리기는 박스 안쪽. shadow 영역 (margin) 은 (6) 단일 SDF pass 에서
    /// 검정 + falloff alpha 로 합성.
    ///
    /// 구조 — 박스 안 pad 안: title → 1px separator → message lines → gap →
    /// footer hint. border 없음 (둥근 모서리 + drop shadow 로 박스 시각 분리,
    /// macOS NSAlert 동등).
    pub fn drawDialogContent(
        self: *Renderer,
        memory: []u8,
        buffer_w: i32,
        buffer_h: i32,
        stride: i32,
        _: dialog_mod.Severity,
        title: []const u8,
        message: []const u8,
        confirm_focus_ok: ?bool,
        prompt_input: ?[]const u8,
        prompt_status: ?[]const u8,
        prompt_available: bool,
        wrap_width: i32,
        message_rows: usize,
        visible_message_rows: usize,
        message_scroll_row: usize,
        show_icon: bool,
    ) void {
        const cw: i32 = @intCast(self.dialogFont().cell_width_px);
        const ch: i32 = @intCast(self.dialogFont().cell_height_px);
        const ascent: i32 = @intCast(self.dialogFont().ascent_px);
        const title_ch: i32 = @intCast(self.dialogTitleFont().cell_height_px);
        const title_ascent: i32 = @intCast(self.dialogTitleFont().ascent_px);
        const pad: i32 = scaledPt(dialog_padding_pt, self.scale);
        // PT × scale → physical pixel. 한 번씩 계산해서 layout 일관 보장.
        const sm: i32 = scaledPt(dialog_shadow_margin_pt, self.scale);
        const corner_r: i32 = scaledPt(dialog_corner_radius_pt, self.scale);
        const icon_size: i32 = scaledPt(dialog_icon_size_pt, self.scale);
        const button_w: i32 = scaledPt(dialog_button_w_pt, self.scale);
        const button_h: i32 = scaledPt(dialog_button_h_pt, self.scale);
        const button_r: i32 = scaledPt(dialog_button_radius_pt, self.scale);

        const box_x: i32 = sm;
        const box_y: i32 = sm;
        const box_w: i32 = buffer_w - sm * 2;
        const box_h: i32 = buffer_h - sm * 2;

        // dialog 색 — terminal theme 와 분리, 시스템 표준 light dialog.
        const fg = dialog_text_color;
        const bg = dialog_bg_color;
        // step 4 — confirm_focus_ok != null 이면 confirm 모드 (OK + Cancel 두
        // 버튼). null 이면 info 모드 (OK 하나만, 가로 중앙). focus 표시 (.true =
        // OK, .false = Cancel) 는 차후 시각 강조 (tab focus 등) — 현재는 동작 결정
        // 만 영향. mac NSAlert 표준: primary (OK) 가 오른쪽, secondary (Cancel)
        // 가 왼쪽. 그룹은 박스 가로 중앙.
        const is_confirm: bool = confirm_focus_ok != null;
        // confirm_focus_ok 의 *값* (true = OK / false = Cancel) 은 focus 시각
        // 강조 (예: 두꺼운 테두리) 에 후속 활용. 현재는 *null vs bool* 만 사용.

        // (1) 박스 영역만 배경 (shadow 영역 제외).
        rect(memory, buffer_w, buffer_h, stride, box_x, box_y, box_w, box_h, bg);

        // (2) 아이콘 — 박스 가로 중앙, 박스 상단 padding 아래.
        const text_x: i32 = box_x + pad;
        var text_y: i32 = box_y + pad;
        if (show_icon) {
            const icon_x: i32 = box_x + @divTrunc(box_w - icon_size, 2);
            const icon_y: i32 = text_y;
            drawDialogIcon(memory, buffer_w, buffer_h, stride, icon_x, icon_y, icon_size);
            text_y += icon_size + scaledPt(dialog_icon_gap_pt, self.scale);
        }

        // (3) Title.
        self.drawDialogTextLine(self.dialogTitleFont(), memory, buffer_w, buffer_h, stride, text_x, text_y + title_ascent, title, fg);
        text_y += title_ch;

        // (3) separator line — title 과 message 구분.
        const inner_w: i32 = box_w - pad * 2;
        const separator_h = scaledPt(ui_metrics.DIALOG_SEPARATOR_THICKNESS_PT, self.scale);
        const separator_y = text_y + @divTrunc(ch, 2) - @divTrunc(separator_h, 2);
        rect(memory, buffer_w, buffer_h, stride, text_x, separator_y, inner_w, separator_h, dialog_separator_color);
        text_y += ch;

        // (4) Message lines — output viewport에서 계산한 content-driven 폭으로
        // wrap. computeDialogLayout과 같은 iterator/폭이라 측정과 그림이 일치.
        const message_y = text_y;
        var row: usize = 0;
        var drawn_rows: usize = 0;
        var wl = dialog_layout.WrappedLines{
            .msg = message,
            .max_width = wrap_width,
            .measure = self.dialogBodyMeasure(),
        };
        while (wl.next()) |line| {
            if (row >= message_scroll_row and drawn_rows < visible_message_rows) {
                self.drawDialogTextLine(self.dialogFont(), memory, buffer_w, buffer_h, stride, text_x, text_y + ascent, line, fg);
                text_y += ch;
                drawn_rows += 1;
            }
            row += 1;
            if (drawn_rows == visible_message_rows) break;
        }

        self.last_dialog_scrollbar_track_rect = .{};
        self.last_dialog_scrollbar_hit_rect = .{};
        self.last_dialog_scrollbar_thumb_rect = .{};
        if (message_rows > visible_message_rows) {
            const sb_w = scaledPt(ui_metrics.SCROLLBAR_W_PT, self.scale);
            const sb_gap = scaledPt(ui_metrics.DIALOG_SCROLLBAR_GAP_PT, self.scale);
            const track_h: i32 = @intCast(visible_message_rows * @as(usize, @intCast(ch)));
            const track_x = box_x + box_w - pad - sb_w;
            self.last_dialog_scrollbar_track_rect = .{ .x = track_x, .y = message_y, .w = sb_w, .h = track_h };
            self.last_dialog_scrollbar_hit_rect = .{ .x = track_x - sb_gap, .y = message_y, .w = sb_gap + sb_w, .h = track_h };
            if (scrollbar.geom(
                message_rows,
                visible_message_rows,
                message_scroll_row,
                @floatFromInt(track_h),
                @floatFromInt(scaledPt(ui_metrics.SCROLLBAR_MIN_THUMB_H_PT, self.scale)),
            )) |g| {
                // #344 — terminal scrollbar 와 같은 공통 스냅. dialog track 도
                // 위·아래 여백이 같아야 한다.
                const t = scrollbar.thumbPx(@floatFromInt(message_y), g);
                const thumb_y: i32 = @trunc(t.top);
                const thumb_h: i32 = @trunc(t.h);
                // Terminal scrollbar의 white/30%는 dark theme용이다. 밝은 dialog
                // 배경에 blend하면 RGB 242→246이라 thumb가 사실상 사라진다.
                // 중립 회색을 써 가시 대비를 유지하고 제목 accent와 분리한다.
                rect(memory, buffer_w, buffer_h, stride, track_x, thumb_y, sb_w, thumb_h, dialog_scrollbar_color);
                self.last_dialog_scrollbar_thumb_rect = .{ .x = track_x, .y = thumb_y, .w = sb_w, .h = thumb_h };
            }
        }

        if (prompt_input) |input| {
            const field_h = ch + @max(@as(i32, 8), @divTrunc(ch, 2));
            const field_y = text_y;
            if (input.len > 0) {
                const input_w: i32 = @intCast(display_width.stringWidth(input) * @as(usize, @intCast(cw)));
                const input_x = text_x + @divTrunc(inner_w - input_w, 2);
                self.drawDialogTextLine(self.dialogFont(), memory, buffer_w, buffer_h, stride, input_x, field_y + @divTrunc(field_h - ch, 2) + ascent, input, fg);
            }
            text_y += field_h + @divTrunc(ch, 2);
        }
        if (prompt_status) |status| {
            if (status.len > 0) {
                self.drawDialogTextLine(self.dialogFont(), memory, buffer_w, buffer_h, stride, text_x, text_y + ascent, status, .{ .r = 190, .g = 45, .b = 45 });
            }
            text_y += ch;
        }

        // (5) 버튼 — Info 모드: OK 하나만 중앙. Confirm 모드: OK + Cancel 그룹,
        // mac NSAlert 표준 — primary (OK) 오른쪽, secondary (Cancel) 왼쪽.
        const button_y: i32 = box_y + box_h - pad - button_h;
        const button_gap: i32 = scaledPt(dialog_button_gap_pt, self.scale);
        const group_w: i32 = if (is_confirm) button_w * 2 + button_gap else button_w;
        const group_x: i32 = box_x + @divTrunc(box_w - group_w, 2);

        // OK 버튼 (primary action, 항상 그림).
        const ok_x: i32 = if (is_confirm) group_x + button_w + button_gap else group_x;
        self.last_dialog_ok_rect = .{ .x = ok_x, .y = button_y, .w = button_w, .h = button_h };
        const create_enabled = if (prompt_input != null) prompt_available else true;
        const ok_bg = if (create_enabled) dialog_button_color else dialog_disabled_button_color;
        const ok_fg = if (create_enabled) dialog_button_text_color else dialog_disabled_button_text_color;
        fillRoundedRect(memory, buffer_w, buffer_h, stride, ok_x, button_y, button_w, button_h, button_r, ok_bg);
        const ok_text = if (prompt_input != null) messages.button_create else messages.button_ok;
        // **라벨 폭도 실제 advance 로 잰다** (#407). 예전에는 `cell_width × 글자수`
        // 였는데 비례폭에서는 그 값이 실제보다 넓어서 **라벨이 버튼 안에서 왼쪽으로
        // 밀렸다** (긴 라벨일수록 심해서 `Cancel` 이 `OK` 보다 눈에 띄었다).
        const button_measure = self.dialogBodyMeasure();
        const ok_text_w: i32 = button_measure.width(ok_text);
        const ok_text_x: i32 = ok_x + @divTrunc(button_w - ok_text_w, 2);
        const button_text_y: i32 = button_y + @divTrunc(button_h - ch, 2) + ascent;
        self.drawDialogTextLine(self.dialogFont(), memory, buffer_w, buffer_h, stride, ok_text_x, button_text_y, ok_text, ok_fg);

        // Cancel 버튼 — confirm 모드 에서만. secondary action (회색 배경 + 검정).
        if (is_confirm) {
            const cancel_x: i32 = group_x;
            self.last_dialog_cancel_rect = .{ .x = cancel_x, .y = button_y, .w = button_w, .h = button_h };
            fillRoundedRect(memory, buffer_w, buffer_h, stride, cancel_x, button_y, button_w, button_h, button_r, dialog_cancel_color);
            const cancel_text = messages.button_cancel;
            const cancel_text_w: i32 = button_measure.width(cancel_text);
            const cancel_text_x: i32 = cancel_x + @divTrunc(button_w - cancel_text_w, 2);
            self.drawDialogTextLine(self.dialogFont(), memory, buffer_w, buffer_h, stride, cancel_text_x, button_text_y, cancel_text, dialog_cancel_text_color);
        } else {
            self.last_dialog_cancel_rect = .{}; // info 모드: Cancel 그리지 않음.
        }

        // (6) Single-pass SDF — 박스 내부 alpha sweep + 둥근 모서리 + drop shadow
        // 한 번에 처리. 박스 안 (d < 0): opacity 보장 / 박스 모서리 1-pixel 띠
        // (d ∈ [-0.5, 0.5)): anti-alias / 박스 밖 shadow 띠 (d ∈ [0.5, sm)):
        // 검정 + quadratic falloff / 그 밖 (d ≥ sm): alpha=0 (compositor 가
        // underlying surface 와 합성).
        applyShadowAndMask(
            memory,
            buffer_w,
            buffer_h,
            stride,
            sm,
            corner_r,
            self.opacity_alpha,
            dialog_shadow_max_alpha,
        );
    }

    /// #306 — basis output viewport와 고정 dialog typography로 content-driven
    /// surface 크기/wrap 폭을 계산한다. 실제 메시지가 640×480 logical 최소 화면에
    /// 들어오는지 pure dialog_layout 테스트에서 검증한다.
    pub fn computeDialogLayout(
        self: *const Renderer,
        title: []const u8,
        message: []const u8,
        kind: dialog_layout.Kind,
        viewport_w: i32,
        viewport_h: i32,
    ) dialog_layout.Layout {
        return dialog_layout.compute(
            title,
            message,
            kind,
            self.dialogLayoutMetrics(),
            self.dialogBodyMeasure(),
            self.dialogTitleMeasure(),
            .{ .w = viewport_w, .h = viewport_h },
        );
    }

    pub fn computeDialogLayoutForSurface(
        self: *const Renderer,
        title: []const u8,
        message: []const u8,
        kind: dialog_layout.Kind,
        surface_w: i32,
        surface_h: i32,
    ) dialog_layout.Layout {
        return dialog_layout.computeForSurface(
            title,
            message,
            kind,
            self.dialogLayoutMetrics(),
            self.dialogBodyMeasure(),
            self.dialogTitleMeasure(),
            .{ .w = surface_w, .h = surface_h },
        );
    }

    /// dialog 글자 폭 측정 (#407). `glyph` 는 glyph 캐시를 채우므로 mutable 를
    /// 요구하지만 그것은 순수 memoization 이라 **측정에서 const 를 벗겨도 관측 가능한
    /// 차이가 없다** — 같은 글리프를 어차피 그릴 때 채운다. 레이아웃 경로가
    /// `*const Renderer` 인 것을 유지하려고 여기서만 벗긴다.
    fn dialogFontAdvance(ctx: *const anyopaque, cp: u21) i32 {
        const font_ctx: *font.Context = @constCast(@ptrCast(@alignCast(ctx)));
        return @intCast(font_ctx.glyph(cp, .regular).advance);
    }

    fn dialogBodyMeasure(self: *const Renderer) dialog_layout.Measure {
        return .{ .ctx = self.dialogFontConst(), .advanceFn = dialogFontAdvance };
    }

    fn dialogTitleMeasure(self: *const Renderer) dialog_layout.Measure {
        return .{ .ctx = self.dialogTitleFontConst(), .advanceFn = dialogFontAdvance };
    }

    fn dialogLayoutMetrics(self: *const Renderer) dialog_layout.Metrics {
        return .{
            .body_cell_h = @intCast(self.dialogFontConst().cell_height_px),
            .title_cell_h = @intCast(self.dialogTitleFontConst().cell_height_px),
            .padding = scaledPt(dialog_padding_pt, self.scale),
            .shadow_margin = scaledPt(dialog_shadow_margin_pt, self.scale),
            .viewport_margin = scaledPt(dialog_viewport_margin_pt, self.scale),
            .icon_size = scaledPt(dialog_icon_size_pt, self.scale),
            .icon_gap = scaledPt(dialog_icon_gap_pt, self.scale),
            .button_w = scaledPt(dialog_button_w_pt, self.scale),
            .button_h = scaledPt(dialog_button_h_pt, self.scale),
            .button_gap = scaledPt(dialog_button_gap_pt, self.scale),
            .preferred_w = scaledPt(ui_metrics.DIALOG_PREFERRED_WIDTH_PT, self.scale),
            .max_w = scaledPt(ui_metrics.DIALOG_MAX_WIDTH_PT, self.scale),
            .scrollbar_w = scaledPt(ui_metrics.SCROLLBAR_W_PT, self.scale),
            .scrollbar_gap = scaledPt(ui_metrics.DIALOG_SCROLLBAR_GAP_PT, self.scale),
        };
    }

    /// drawDialogContent helper — UTF-8 line 을 codepoint 별 glyph draw.
    /// 48038081 의 `drawDialogTextLine` 재이식. cell-aligned 라 ligature /
    /// cluster shape 안 필요.
    fn drawDialogTextLine(
        self: *Renderer,
        font_ctx: *font.Context,
        memory: []u8,
        fb_w: i32,
        fb_h: i32,
        stride: i32,
        start_x: i32,
        baseline_y: i32,
        text: []const u8,
        /// 배경색 인자는 없다 — `drawGlyph` 가 프레임버퍼와 직접 섞는다 (#277 S2-4).
        fg: ghostty.color.RGB,
    ) void {
        _ = self;
        const ch_metric: i32 = @intCast(font_ctx.cell_height_px);
        var x: i32 = start_x;
        var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (iter.nextCodepoint()) |cp| {
            if (x >= fb_w) break;
            const gl = font_ctx.glyph(cp, .regular);
            // **글리프의 실제 advance 로 pen 을 민다** (#407). 예전에는
            // `cell_width × display_width` 였는데, 그러면 비례폭 폰트를 줘도 글자가
            // 균등 간격으로 놓여 문장이 성기게 보였다. 레이아웃도 같은 advance 로
            // 재므로 (`dialog_layout.Measure`) 측정과 그림이 일치한다.
            const adv: i32 = @intCast(gl.advance);
            if (gl.pixel_mode == freetype.FT_PIXEL_MODE_BGRA) {
                drawGlyphBgra(memory, fb_w, fb_h, stride, x, baseline_y - ch_metric, adv, ch_metric, gl, 0, fb_w);
            } else {
                drawGlyph(
                    memory,
                    fb_w,
                    fb_h,
                    stride,
                    x + gl.bitmap_left,
                    baseline_y - gl.bitmap_top,
                    gl,
                    fg,
                    0,
                    fb_w,
                );
            }
            x += adv;
        }
    }
};

const TabClipDecision = enum { skip, draw, stop };

/// index 순서의 tab loop clipping 판단. drag 중이 아니면 tab x가 단조 증가하므로
/// 우측 viewport 밖 첫 탭에서 stop 가능하다. drag 중에는 source tab만 mouse x를
/// 따라 index 순서를 벗어나므로 뒤 index에 화면 안 source가 있을 수 있다 — 이때
/// 우측 밖 일반 탭은 skip만 하고 loop를 계속한다 (#309).
fn tabClipDecision(
    tab_left: i32,
    tab_width: i32,
    viewport_left: i32,
    viewport_right: i32,
    drag_active: bool,
) TabClipDecision {
    if (tab_left + tab_width <= viewport_left) return .skip;
    if (tab_left >= viewport_right) return if (drag_active) .skip else .stop;
    return .draw;
}

/// L12-α/β/γ tab bar — cross-platform `tab_layout.Layout` 따라 영역 분할 + 각
/// 탭 그리기. `[<][tabs+][+][>]` (arrows_visible) 또는 `[tabs+][+]`. tab area
/// 안 탭들은 `scroll_x` 만큼 좌측 밀려 그려지고 area 범위 밖은 clip.
/// #334 (2026-07-22) — 탭 배경(활성 포함) = 탭바 색, 활성은 amber 밑줄로만
/// 구분, 탭 경계는 세로 구분선 (Tilda 문법, mac/win 동등).
fn rgbFromMetrics(c: [4]f32) ghostty.color.RGB {
    return .{
        .r = @trunc(@max(0.0, @min(255.0, c[0] * 255.0))),
        .g = @trunc(@max(0.0, @min(255.0, c[1] * 255.0))),
        .b = @trunc(@max(0.0, @min(255.0, c[2] * 255.0))),
    };
}

/// [`appendGlyph`] 의 인자 묶음 — 셀 기하와 색.
const GlyphPlacement = struct {
    ref: GlyphRef,
    glyph: *const font.Glyph,
    /// #375 — atlas 키 구분용. `appendGlyph` 가 `GlyphItem` 으로 그대로 옮긴다.
    face_style: font_constants.FaceStyle = .regular,
    cell_x: i32,
    cell_y: i32,
    cell_w: i32,
    cell_h: i32,
    ascent: i32,
    /// shaping 결과의 보정 (ligature · cluster). 없으면 0.
    x_offset: i32 = 0,
    y_offset: i32 = 0,
    fg: ghostty.color.RGB,
};

/// #277 S2-4 — 글리프 하나를 그리기 목록에 넣는다. **"어디에" 의 단일 정의다.**
///
/// 컬러(BGRA) 글리프는 대상 사각형 안에 비율 유지 fit 하므로 셀 사각형을 그대로
/// 싣고 (fit 계산은 그리는 쪽이 [`colorGlyphFit`] 로 한다 — 역시 한 곳), 알파 마스크
/// 글리프는 여기서 최종 bitmap 좌상단까지 계산해 싣는다.
///
/// proportional 폰트 (`fc-match monospace` 가 NotoSansCJK 같은 sans-serif 로
/// 매치되는 환경 등) 라도 글자가 cell 안 가운데에 균일하게 분포하도록 advance-center
/// 정렬한다. monospace 면 글리프 advance == cell width 라 offset = 0 (그대로).
/// wide glyph 의 fallback (placeholder `?`) 도 cell-pair 가운데로.
///
/// #401 — cluster 결과의 참조. 합성이면 `glyph_index` 가 FreeType glyph index 가 아니라
/// 합성 캐시 키라 갈래가 다르다. 배칭 · 개별 두 경로가 같은 판단을 하도록 여기 한곳에 둔다.
fn clusterRef(cg: font.ClusterGlyph) GlyphRef {
    return if (cg.composed)
        .{ .composed = .{ .face = cg.face_idx, .key = cg.glyph_index } }
    else
        .{ .indexed = .{ .face = cg.face_idx, .index = cg.glyph_index } };
}

/// #401 — cluster 결과의 raster. `clusterRef` 와 짝이다.
fn clusterGlyph(ctx: *font.Context, cg: font.ClusterGlyph) *const font.Glyph {
    return if (cg.composed)
        ctx.composedGlyph(cg.face_idx, cg.glyph_index)
    else
        ctx.glyphByIndex(cg.face_idx, cg.glyph_index);
}

/// 보이지 않는 글리프 (공백 등) 는 목록에 넣지 않는다 — 두 경로 모두 그릴 것이 없다.
fn appendGlyph(list: *std.ArrayList(GlyphItem), allocator: std.mem.Allocator, p: GlyphPlacement) void {
    const glyph = p.glyph;
    if (glyph.width == 0 or glyph.height == 0 or glyph.bitmap.len == 0) return;

    if (glyph.pixel_mode == freetype.FT_PIXEL_MODE_BGRA) {
        list.append(allocator, .{
            .ref = p.ref,
            .glyph = glyph,
            .x = p.cell_x,
            .y = p.cell_y,
            .w = p.cell_w,
            .h = p.cell_h,
            .fg = p.fg,
            .face_style = p.face_style,
        }) catch return;
        return;
    }

    const advance: i32 = @intCast(glyph.advance);
    const center_off: i32 = @divFloor(p.cell_w - advance, 2);
    list.append(allocator, .{
        .ref = p.ref,
        .glyph = glyph,
        .x = p.cell_x + center_off + glyph.bitmap_left + p.x_offset,
        .y = p.cell_y + p.ascent - glyph.bitmap_top - p.y_offset,
        .fg = p.fg,
        .face_style = p.face_style,
    }) catch return;
}

/// [`appendChromeGlyph`] 의 인자 묶음.
const ChromeGlyphPlacement = struct {
    ref: GlyphRef,
    glyph: *const font.Glyph,
    /// 펜 위치 (advance 기준 좌측) 와 baseline.
    pen_x: i32,
    baseline: i32,
    /// 컬러 글리프가 들어갈 상자 — 마스크 글리프는 쓰지 않는다.
    box_y: i32,
    box_w: i32,
    box_h: i32,
    fg: ghostty.color.RGB,
    clip_x0: i32,
    clip_x1: i32,
};

/// #277 S2-5 — chrome 글리프 하나를 목록에 넣는다.
///
/// 터미널 셀과 달리 **중앙 정렬을 하지 않는다** — chrome 텍스트는 격자가 아니라
/// 펜 위치로 흐르므로 `pen_x + bearing` 이 그대로 글리프 자리다. 폰트는 항상 탭
/// 폰트라 `font` 를 여기서 채운다 (atlas 키가 터미널 폰트와 갈린다).
fn appendChromeGlyph(list: *std.ArrayList(ChromeItem), allocator: std.mem.Allocator, p: ChromeGlyphPlacement) void {
    const glyph = p.glyph;
    if (glyph.width == 0 or glyph.height == 0 or glyph.bitmap.len == 0) return;

    const item: GlyphItem = if (glyph.pixel_mode == freetype.FT_PIXEL_MODE_BGRA) .{
        .ref = p.ref,
        .font = .tab,
        .glyph = glyph,
        .x = p.pen_x,
        .y = p.box_y,
        .w = p.box_w,
        .h = p.box_h,
        .fg = p.fg,
    } else .{
        .ref = p.ref,
        .font = .tab,
        .glyph = glyph,
        .x = p.pen_x + glyph.bitmap_left,
        .y = p.baseline - glyph.bitmap_top,
        .fg = p.fg,
    };
    list.append(allocator, .{ .glyph = .{
        .item = item,
        .clip_x0 = p.clip_x0,
        .clip_x1 = p.clip_x1,
    } }) catch return;
}

/// [`ChromeItem`] 하나를 그린다 (CPU 경로).
fn drawChromeItem(memory: []u8, width: i32, height: i32, stride: i32, it: ChromeItem) void {
    switch (it) {
        .rect => |r| drawSolidRect(memory, width, height, stride, r),
        .glyph => |g| {
            if (g.item.glyph.pixel_mode == freetype.FT_PIXEL_MODE_BGRA) {
                drawGlyphBgra(memory, width, height, stride, g.item.x, g.item.y, g.item.w, g.item.h, g.item.glyph, g.clip_x0, g.clip_x1);
            } else {
                drawGlyph(memory, width, height, stride, g.item.x, g.item.y, g.item.glyph, g.item.fg, g.clip_x0, g.clip_x1);
            }
        },
        .icon => |ic| {
            // 래스터화는 순수 함수라 매 프레임 다시 불러도 같은 그림이다 (GL 은
            // atlas 가 비었을 때만 부른다). 알파는 프레임버퍼와 섞는다 —
            // `drawGlyph` 와 같은 규칙 (#277 S2-4).
            var cov: [tab_icons.MAX_SIZE * tab_icons.MAX_SIZE]u8 = undefined;
            if (ic.size == 0 or ic.size > tab_icons.MAX_SIZE) return;
            tab_icons.rasterize(ic.kind, ic.size, ic.stroke, &cov);
            var row: u32 = 0;
            while (row < ic.size) : (row += 1) {
                var col: u32 = 0;
                while (col < ic.size) : (col += 1) {
                    const alpha = cov[row * ic.size + col];
                    if (alpha == 0) continue;
                    const px = ic.x + @as(i32, @intCast(col));
                    const py = ic.y + @as(i32, @intCast(row));
                    if (px < 0 or py < 0 or px >= width or py >= height) continue;
                    const off: usize = @intCast(py * stride + px * 4);
                    const dst = ghostty.color.RGB{
                        .b = memory[off],
                        .g = memory[off + 1],
                        .r = memory[off + 2],
                    };
                    std.mem.writeInt(u32, memory[off..][0..4], blendPixel(ic.color, dst, alpha), .little);
                }
            }
        },
    }
}

/// `block_element.BlockRect.shade` (f32) 를 [`SolidRect`] 의 패턴 코드로. 경계
/// 판정은 이 함수 하나에만 있다.
fn shadeCode(shade: f32) u8 {
    if (shade < 0.5) return 0;
    if (shade < 1.5) return 1; // U+2591 LIGHT
    if (shade < 2.5) return 2; // U+2592 MEDIUM
    return 3; // U+2593 DARK
}

/// 컬러(BGRA) 글리프를 대상 사각형 안에 **비율 유지 + 가운데** 로 넣은 결과.
pub const ColorGlyphFit = struct {
    /// 대상 사각형 좌상단 기준 offset (px).
    off_x: i32,
    off_y: i32,
    w: i32,
    h: i32,
};

/// #277 S2-4 — 컬러 글리프의 fit 계산. **CPU 와 GL 이 같은 함수를 쓴다** — emoji 가
/// 어디에 얼마 크기로 앉는지가 두 벌이 되면 화면이 갈린다.
///
/// emoji bitmap 은 보통 폰트의 strike size (~109px) 라 cell 보다 크다. 비율을
/// 유지한 채 cell 에 들어가는 최대 크기로 줄이고 가운데 정렬한다.
pub fn colorGlyphFit(cell_w: i32, cell_h: i32, glyph_w: u32, glyph_h: u32) ?ColorGlyphFit {
    if (cell_w <= 0 or cell_h <= 0 or glyph_w == 0 or glyph_h == 0) return null;
    const gw_f: f64 = @floatFromInt(glyph_w);
    const gh_f: f64 = @floatFromInt(glyph_h);
    const scale: f64 = @min(
        @as(f64, @floatFromInt(cell_w)) / gw_f,
        @as(f64, @floatFromInt(cell_h)) / gh_f,
    );
    const w: i32 = @trunc(gw_f * scale);
    const h: i32 = @trunc(gh_f * scale);
    if (w <= 0 or h <= 0) return null;
    return .{
        .off_x = @divFloor(cell_w - w, 2),
        .off_y = @divFloor(cell_h - h, 2),
        .w = w,
        .h = h,
    };
}

/// [`GlyphItem`] 하나를 그린다 (CPU 경로). 터미널 셀 글리프는 셀에 클립하지 않는다 —
/// 표면 전체에만 클립한다 (#361 에서 확정한 "번짐 보존").
fn drawGlyphItem(memory: []u8, width: i32, height: i32, stride: i32, item: *const GlyphItem) void {
    if (item.glyph.pixel_mode == freetype.FT_PIXEL_MODE_BGRA) {
        drawGlyphBgra(memory, width, height, stride, item.x, item.y, item.w, item.h, item.glyph, 0, width);
    } else {
        drawGlyph(memory, width, height, stride, item.x, item.y, item.glyph, item.fg, 0, width);
    }
}

// 색 해석 정책은 공유 모듈 `cell_color.zig` (#282 B2 — 이전 사본은
// selection/inverse 시 cell 고유 색을 무시하고 theme 전역 fg/bg 를 써서
// Windows/macOS 의 '색 교환' 렌더와 달랐다). software renderer 는 모든
// cell 을 직접 칠하므로 null (= cell 고유 bg 없음) 을 theme 배경으로.

fn resolveFg(style: ghostty.Style, raw: *const ghostty.Cell, colors: *const ghostty.RenderState.Colors, selected: bool) ghostty.color.RGB {
    return cell_color.resolveFg(style, raw, colors, selected, style.flags.inverse);
}

fn resolveBg(
    style: ghostty.Style,
    raw: *const ghostty.Cell,
    colors: *const ghostty.RenderState.Colors,
    selected: bool,
) ghostty.color.RGB {
    return cell_color.resolveBg(style, raw, colors, selected, style.flags.inverse) orelse colors.background;
}

const isLigatureCandidate = @import("../../font/ligature.zig").isLigatureCandidate;

fn fill(memory: []u8, width: i32, height: i32, stride: i32, color: ghostty.color.RGB) void {
    rect(memory, width, height, stride, 0, 0, width, height, color);
}

fn rect(
    memory: []u8,
    width: i32,
    height: i32,
    stride: i32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    color: ghostty.color.RGB,
) void {
    const x0 = @max(0, x);
    const y0 = @max(0, y);
    const x1 = @min(width, x + w);
    const y1 = @min(height, y + h);
    if (x1 <= x0 or y1 <= y0) return;

    const packed_color = pack(color);
    var py = y0;
    while (py < y1) : (py += 1) {
        var px = x0;
        while (px < x1) : (px += 1) {
            const off: usize = @intCast(py * stride + px * 4);
            std.mem.writeInt(u32, memory[off..][0..4], packed_color, .little);
        }
    }
}

// #353 — box-drawing AA 전용이었던 `blendRect` 는 제거했다. 규칙(알파 8bit
// 버림 + 정수 버림)이 macOS·Windows 의 renderer 합성과 갈렸고, 합성 자체를
// 공통 `ui_metrics.blendOverRgb` 한 곳으로 모았다. 유일한 호출처였던 호·대각선
// AA 는 이제 미리 합성한 색을 불투명 `rect` 로 그린다.

/// #203 Phase C step 3.4 — 둥근 사각형 채우기. dialog 의 OK / Cancel button
/// 등. SDF (signed distance function) 기반으로 내부 = 솔리드 color, edge
/// 1-pixel 띠 = 기존 픽셀 (= box bg) 와 anti-alias 블렌딩, 외부 = 손대지 않음
/// (= 박스 bg 보존). alpha byte 는 안 건드림 — drawDialogContent 의 마지막
/// `applyShadowAndMask` 가 일괄 처리.
fn fillRoundedRect(
    memory: []u8,
    buffer_w: i32,
    buffer_h: i32,
    stride: i32,
    rect_x: i32,
    rect_y: i32,
    rect_w: i32,
    rect_h: i32,
    radius: i32,
    color: ghostty.color.RGB,
) void {
    if (rect_w <= 0 or rect_h <= 0) return;
    const cx: f32 = @as(f32, @floatFromInt(rect_x)) + @as(f32, @floatFromInt(rect_w)) * 0.5;
    const cy: f32 = @as(f32, @floatFromInt(rect_y)) + @as(f32, @floatFromInt(rect_h)) * 0.5;
    const hw: f32 = @as(f32, @floatFromInt(rect_w)) * 0.5;
    const hh: f32 = @as(f32, @floatFromInt(rect_h)) * 0.5;
    // radius 가 박스 절반 보다 크면 clamp (overflow 방지).
    const max_r = @min(@divTrunc(rect_w, 2), @divTrunc(rect_h, 2));
    const r: f32 = @floatFromInt(@min(radius, max_r));
    const packed_color = pack(color);

    var py = @max(0, rect_y);
    const py_end = @min(buffer_h, rect_y + rect_h);
    while (py < py_end) : (py += 1) {
        var px = @max(0, rect_x);
        const px_end = @min(buffer_w, rect_x + rect_w);
        while (px < px_end) : (px += 1) {
            const xf: f32 = @as(f32, @floatFromInt(px)) + 0.5 - cx;
            const yf: f32 = @as(f32, @floatFromInt(py)) + 0.5 - cy;
            const ax: f32 = if (xf < 0) -xf else xf;
            const ay: f32 = if (yf < 0) -yf else yf;
            const qx: f32 = ax - hw + r;
            const qy: f32 = ay - hh + r;
            const ox: f32 = if (qx > 0) qx else 0;
            const oy: f32 = if (qy > 0) qy else 0;
            const outside_len: f32 = @sqrt(ox * ox + oy * oy);
            const max_q: f32 = if (qx > qy) qx else qy;
            const inside_term: f32 = if (max_q < 0) max_q else 0;
            const d: f32 = outside_len + inside_term - r;

            const off: usize = @intCast(py * stride + px * 4);
            if (d < -0.5) {
                // 내부 — 솔리드 color.
                std.mem.writeInt(u32, memory[off..][0..4], packed_color, .little);
            } else if (d < 0.5) {
                // 모서리 anti-alias — 기존 pixel 과 coverage 비례 블렌딩.
                const coverage: f32 = 0.5 - d;
                const inv: f32 = 1.0 - coverage;
                const existing = std.mem.readInt(u32, memory[off..][0..4], .little);
                const er: f32 = @floatFromInt((existing >> 16) & 0xff);
                const eg: f32 = @floatFromInt((existing >> 8) & 0xff);
                const eb: f32 = @floatFromInt(existing & 0xff);
                const br: u32 = @round(@as(f32, @floatFromInt(color.r)) * coverage + er * inv);
                const bg_: u32 = @round(@as(f32, @floatFromInt(color.g)) * coverage + eg * inv);
                const bb: u32 = @round(@as(f32, @floatFromInt(color.b)) * coverage + eb * inv);
                const blended: u32 = (br << 16) | (bg_ << 8) | bb;
                std.mem.writeInt(u32, memory[off..][0..4], blended, .little);
            }
            // d >= 0.5: 외부 — 손대지 않음 (기존 box bg 보존).
        }
    }
}

/// #203 Phase C step 3.3 — 두 점 사이의 두꺼운 line drawing (round caps).
/// SDF 기반 — 픽셀 별로 line segment 까지 거리 계산, distance < thickness/2
/// 면 색 채움. 1-pixel 띠 anti-alias. `fillRoundedRect` 와 같이 alpha byte 는
/// 안 건드림 (마지막 `applyShadowAndMask` 가 일괄 처리).
fn drawThickLine(
    memory: []u8,
    buffer_w: i32,
    buffer_h: i32,
    stride: i32,
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    thickness: f32,
    color: ghostty.color.RGB,
) void {
    const half_t: f32 = thickness * 0.5;
    const dx: f32 = x2 - x1;
    const dy: f32 = y2 - y1;
    const len_sq: f32 = dx * dx + dy * dy;
    if (len_sq < 0.0001) return;

    const min_x: i32 = @floor(@min(x1, x2) - half_t - 1.0);
    const max_x: i32 = @ceil(@max(x1, x2) + half_t + 1.0);
    const min_y: i32 = @floor(@min(y1, y2) - half_t - 1.0);
    const max_y: i32 = @ceil(@max(y1, y2) + half_t + 1.0);

    const packed_color = pack(color);

    var py = @max(0, min_y);
    const py_end = @min(buffer_h, max_y + 1);
    while (py < py_end) : (py += 1) {
        var px = @max(0, min_x);
        const px_end = @min(buffer_w, max_x + 1);
        while (px < px_end) : (px += 1) {
            const pxf: f32 = @as(f32, @floatFromInt(px)) + 0.5;
            const pyf: f32 = @as(f32, @floatFromInt(py)) + 0.5;
            const apx: f32 = pxf - x1;
            const apy: f32 = pyf - y1;
            const t_raw: f32 = (apx * dx + apy * dy) / len_sq;
            const t: f32 = @max(0.0, @min(1.0, t_raw));
            const proj_x: f32 = x1 + t * dx;
            const proj_y: f32 = y1 + t * dy;
            const ddx: f32 = pxf - proj_x;
            const ddy: f32 = pyf - proj_y;
            const dist: f32 = @sqrt(ddx * ddx + ddy * ddy);

            const off: usize = @intCast(py * stride + px * 4);
            if (dist < half_t - 0.5) {
                std.mem.writeInt(u32, memory[off..][0..4], packed_color, .little);
            } else if (dist < half_t + 0.5) {
                const coverage: f32 = half_t + 0.5 - dist;
                const inv: f32 = 1.0 - coverage;
                const existing = std.mem.readInt(u32, memory[off..][0..4], .little);
                const er: f32 = @floatFromInt((existing >> 16) & 0xff);
                const eg: f32 = @floatFromInt((existing >> 8) & 0xff);
                const eb: f32 = @floatFromInt(existing & 0xff);
                const br: u32 = @round(@as(f32, @floatFromInt(color.r)) * coverage + er * inv);
                const bg_: u32 = @round(@as(f32, @floatFromInt(color.g)) * coverage + eg * inv);
                const bb: u32 = @round(@as(f32, @floatFromInt(color.b)) * coverage + eb * inv);
                const blended: u32 = (br << 16) | (bg_ << 8) | bb;
                std.mem.writeInt(u32, memory[off..][0..4], blended, .little);
            }
        }
    }
}

/// #203 Phase C step 3.3 — `docs/favicon.svg` 의 tildaz 아이콘을 직접 raster.
/// viewBox=64×64 의 SVG 를 `icon_size`×`icon_size` 로 scale 해 (icon_x, icon_y)
/// 좌상단부터 그림. SVG primitive 5개 (배경 + 모니터 외곽 + 스탠드 + `>` +
/// `_`) 를 fillRoundedRect / rect / drawThickLine 으로 매핑.
fn drawDialogIcon(
    memory: []u8,
    buffer_w: i32,
    buffer_h: i32,
    stride: i32,
    icon_x: i32,
    icon_y: i32,
    icon_size: i32,
) void {
    const scale: f32 = @as(f32, @floatFromInt(icon_size)) / 64.0;
    const sx = struct {
        fn f(s: f32, vb: f32) f32 {
            return vb * s;
        }
        fn i(s: f32, vb: f32) i32 {
            return @round(vb * s);
        }
    };
    const fx: f32 = @floatFromInt(icon_x);
    const fy: f32 = @floatFromInt(icon_y);

    const dark_bg = ghostty.color.RGB{ .r = 0x0d, .g = 0x11, .b = 0x17 };
    const green = ghostty.color.RGB{ .r = 0x7e, .g = 0xe7, .b = 0x87 };
    const orange = ghostty.color.RGB{ .r = 0xF7, .g = 0xA4, .b = 0x1D };

    // (1) Outer rounded square (rx=12) — 어두운 배경.
    fillRoundedRect(
        memory,
        buffer_w,
        buffer_h,
        stride,
        icon_x,
        icon_y,
        icon_size,
        icon_size,
        sx.i(scale, 12.0),
        dark_bg,
    );

    // (2) Monitor 외곽 — SVG 에서 stroke 3px 의 fill=none rect. 우리는 outer
    // 녹색 + inner dark 두 fill 로 stroke 효과 흉내. SVG stroke 중심선이 path
    // 위에 있어 outer/inner extent 는 ±half_stroke (= ±1.5).
    const m_outer_x = icon_x + sx.i(scale, 7.0 - 1.5);
    const m_outer_y = icon_y + sx.i(scale, 8.0 - 1.5);
    const m_outer_w = sx.i(scale, 50.0 + 3.0);
    const m_outer_h = sx.i(scale, 44.0 + 3.0);
    fillRoundedRect(memory, buffer_w, buffer_h, stride, m_outer_x, m_outer_y, m_outer_w, m_outer_h, sx.i(scale, 4.0 + 1.5), green);
    const m_inner_x = icon_x + sx.i(scale, 7.0 + 1.5);
    const m_inner_y = icon_y + sx.i(scale, 8.0 + 1.5);
    const m_inner_w = sx.i(scale, 50.0 - 3.0);
    const m_inner_h = sx.i(scale, 44.0 - 3.0);
    fillRoundedRect(memory, buffer_w, buffer_h, stride, m_inner_x, m_inner_y, m_inner_w, m_inner_h, sx.i(scale, 4.0 - 1.5), dark_bg);

    // (3) Monitor stand neck — 작은 녹색 rect.
    rect(memory, buffer_w, buffer_h, stride, icon_x + sx.i(scale, 27.0), icon_y + sx.i(scale, 52.0), sx.i(scale, 10.0), sx.i(scale, 4.0), green);
    // (4) Monitor stand base.
    rect(memory, buffer_w, buffer_h, stride, icon_x + sx.i(scale, 21.0), icon_y + sx.i(scale, 56.0), sx.i(scale, 22.0), sx.i(scale, 3.0), green);

    // (5) Orange `>` (M 14 20 L 24 30 L 14 40) — stroke 5px, round caps/joins.
    const stroke: f32 = sx.f(scale, 5.0);
    drawThickLine(memory, buffer_w, buffer_h, stride, fx + sx.f(scale, 14.0), fy + sx.f(scale, 20.0), fx + sx.f(scale, 24.0), fy + sx.f(scale, 30.0), stroke, orange);
    drawThickLine(memory, buffer_w, buffer_h, stride, fx + sx.f(scale, 24.0), fy + sx.f(scale, 30.0), fx + sx.f(scale, 14.0), fy + sx.f(scale, 40.0), stroke, orange);
    // (6) Orange `_` (32 40 → 46 40).
    drawThickLine(memory, buffer_w, buffer_h, stride, fx + sx.f(scale, 32.0), fy + sx.f(scale, 40.0), fx + sx.f(scale, 46.0), fy + sx.f(scale, 40.0), stroke, orange);
}

/// #203 Phase C step 3.2 / 3.7 / 3.8 — ARGB8888 buffer 에 SDF (signed distance
/// function) pass 적용해 box 내부 alpha sweep + 둥근 모서리 + drop shadow
/// 동시 처리. 3.8 — supersampling 2×2 (픽셀 당 4 sample) 로 진짜 anti-alias.
///
/// 박스 영역 = buffer 중앙의 `(buffer_w - margin×2) × (buffer_h - margin×2)`
/// 정사각형 (radius 만큼 둥글). 박스 SDF d (음수=내부, 양수=외부).
///
/// 픽셀 별 처리 (각 픽셀 4 subpixel sample 평균):
///   각 sample i 에 대해:
///     box_in_i     = (d_i < 0) ? 1 : 0
///     shadow_cov_i = (d_i ∈ (0, margin)) ? (1 - d_i/margin)² : 0
///   box_cov = avg(box_in_i)
///   shadow_cov = avg(shadow_cov_i) × (1 - box_cov)
///   box_alpha    = box_cov * opacity
///   shadow_alpha = shadow_cov * shadow_max
///   total_alpha  = box_alpha + shadow_alpha (Porter-Duff "box over shadow")
///   RGB = existing × (1 - shadow_alpha / total_alpha)  (검정 쪽 blend)
///
/// supersampling 으로 SDF 의 자연 coverage 가 fractional. 모서리 stair / halo
/// 모두 해소. `drawDialogContent` 의 마지막 step 이어야 (text drawing 의 alpha=0 정정).
fn applyShadowAndMask(
    memory: []u8,
    buffer_w: i32,
    buffer_h: i32,
    stride: i32,
    margin: i32,
    radius: i32,
    opacity_alpha: u8,
    shadow_max_alpha: u8,
) void {
    if (buffer_w <= 0 or buffer_h <= 0) return;
    if (buffer_w <= margin * 2 or buffer_h <= margin * 2) return;

    const cx: f32 = @as(f32, @floatFromInt(buffer_w)) * 0.5;
    const cy: f32 = @as(f32, @floatFromInt(buffer_h)) * 0.5;
    const box_w_f: f32 = @floatFromInt(buffer_w - margin * 2);
    const box_h_f: f32 = @floatFromInt(buffer_h - margin * 2);
    const hw: f32 = box_w_f * 0.5;
    const hh: f32 = box_h_f * 0.5;
    const r: f32 = @floatFromInt(radius);
    const margin_f: f32 = @floatFromInt(margin);
    const opacity_f: f32 = @floatFromInt(opacity_alpha);
    const shadow_max_f: f32 = @floatFromInt(shadow_max_alpha);

    // 2×2 supersampling — 픽셀 당 4 sample 의 subpixel offset.
    const sample_offsets = [_][2]f32{
        .{ 0.25, 0.25 },
        .{ 0.75, 0.25 },
        .{ 0.25, 0.75 },
        .{ 0.75, 0.75 },
    };

    var py: i32 = 0;
    while (py < buffer_h) : (py += 1) {
        var px: i32 = 0;
        while (px < buffer_w) : (px += 1) {
            // 4 sample 평균.
            var box_cov_sum: f32 = 0;
            var shadow_cov_sum: f32 = 0;
            for (sample_offsets) |so| {
                const xf: f32 = @as(f32, @floatFromInt(px)) + so[0] - cx;
                const yf: f32 = @as(f32, @floatFromInt(py)) + so[1] - cy;
                const ax: f32 = if (xf < 0) -xf else xf;
                const ay: f32 = if (yf < 0) -yf else yf;
                const qx: f32 = ax - hw + r;
                const qy: f32 = ay - hh + r;
                const ox: f32 = if (qx > 0) qx else 0;
                const oy: f32 = if (qy > 0) qy else 0;
                const outside_len: f32 = @sqrt(ox * ox + oy * oy);
                const max_q: f32 = if (qx > qy) qx else qy;
                const inside_term: f32 = if (max_q < 0) max_q else 0;
                const d: f32 = outside_len + inside_term - r;

                if (d < 0) {
                    box_cov_sum += 1.0;
                } else if (d < margin_f) {
                    const t: f32 = d / margin_f;
                    const t_inv: f32 = 1.0 - t;
                    shadow_cov_sum += t_inv * t_inv;
                }
            }
            const box_cov: f32 = box_cov_sum * 0.25;
            const shadow_cov: f32 = (shadow_cov_sum * 0.25) * (1.0 - box_cov);

            const off: usize = @intCast(py * stride + px * 4);

            const box_alpha: f32 = box_cov * opacity_f;
            const shadow_alpha: f32 = shadow_cov * shadow_max_f;
            const total_alpha: f32 = box_alpha + shadow_alpha;

            if (total_alpha < 0.5) {
                memory[off + 3] = 0;
                continue;
            }

            // RGB blending — shadow 비율 만큼 검정 쪽으로.
            if (shadow_alpha > 0.5) {
                const shadow_weight: f32 = shadow_alpha / total_alpha;
                const rgb_keep: f32 = 1.0 - shadow_weight;
                const r0: f32 = @floatFromInt(memory[off + 2]);
                const g0: f32 = @floatFromInt(memory[off + 1]);
                const b0: f32 = @floatFromInt(memory[off + 0]);
                memory[off + 2] = @round(r0 * rgb_keep);
                memory[off + 1] = @round(g0 * rgb_keep);
                memory[off + 0] = @round(b0 * rgb_keep);
            }

            memory[off + 3] = @round(total_alpha);
        }
    }
}

/// 8bpp alpha bitmap 을 fg/bg 알파 블렌딩으로 XRGB8888 buffer 에 그린다.
/// glyph buffer 가 비어 있거나 (space) 좌표가 화면 밖이면 무시.
/// #343 A-2 — `clip_x0` / `clip_x1` 는 가로 clip 경계 (반열림 `[x0, x1)`). 탭 제목이
/// `tab_area` 경계에 걸칠 때 glyph 를 통째로 버리지 않고 **픽셀 단위로 잘라** 안쪽만
/// 그린다. 그 외 호출처는 framebuffer 전체를 넘겨 이전과 같다.
/// 알파 마스크 글리프를 프레임버퍼에 합성한다.
///
/// **바탕은 프레임버퍼에 이미 있는 픽셀이다** — 호출처가 넘긴 배경색이 아니다
/// (#277 S2-4). 이전에는 "이 셀의 배경색" 을 인자로 받아 그것과 섞었는데, 글리프가
/// 셀을 넘어 다른 배경 위로 번지거나 글리프끼리 겹치면 실제로 밑에 있는 색과 달랐다.
/// GPU 블렌드 유닛은 언제나 프레임버퍼와 섞으므로, 두 경로를 같게 만들려면 CPU 도
/// 그래야 한다. 겹치지 않는 보통의 셀에서는 두 값이 같으므로 결과도 같다.
fn drawGlyph(
    memory: []u8,
    width: i32,
    height: i32,
    stride: i32,
    draw_x: i32,
    draw_y: i32,
    glyph: *const font.Glyph,
    fg: ghostty.color.RGB,
    clip_x0: i32,
    clip_x1: i32,
) void {
    if (glyph.width == 0 or glyph.height == 0 or glyph.bitmap.len == 0) return;

    var row: u32 = 0;
    while (row < glyph.height) : (row += 1) {
        var col: u32 = 0;
        while (col < glyph.width) : (col += 1) {
            const alpha = glyph.bitmap[row * glyph.width + col];
            if (alpha == 0) continue;
            const px = draw_x + @as(i32, @intCast(col));
            const py = draw_y + @as(i32, @intCast(row));
            if (px < clip_x0 or px >= clip_x1) continue;
            if (px < 0 or py < 0 or px >= width or py >= height) continue;
            const off: usize = @intCast(py * stride + px * 4);
            const dst = ghostty.color.RGB{
                .b = memory[off],
                .g = memory[off + 1],
                .r = memory[off + 2],
            };
            std.mem.writeInt(u32, memory[off..][0..4], blendPixel(fg, dst, alpha), .little);
        }
    }
}

/// FT_PIXEL_MODE_BGRA bitmap (premultiplied alpha) 를 대상 사각형 안 ratio 유지
/// scale + center fit + alpha 블렌딩으로 XRGB8888 buffer 에 그린다. emoji 색 자체
/// 사용 (fg 무시).
///
/// fit 계산은 [`colorGlyphFit`] 한 곳에 있다 — GL 경로가 정점을 만들 때 같은 함수를
/// 쓴다.
///
/// **샘플링은 대상 픽셀의 중심**이다 (`(d + 0.5) × src / dst`). GL_NEAREST 텍스처
/// 샘플링이 정확히 그 지점을 고르므로, 이 규칙이라야 두 경로가 같은 텍셀을 집는다
/// (#277 S2-4). 이전에는 `d × src / dst` 라 반 픽셀 왼쪽·위로 치우쳐 있었다.
/// #343 A-2 — `clip_x0` / `clip_x1` 는 가로 clip 경계 (`drawGlyph` 와 같은 계약).
fn drawGlyphBgra(
    memory: []u8,
    fb_w: i32,
    fb_h: i32,
    stride: i32,
    cell_x: i32,
    cell_y: i32,
    cell_w: i32,
    cell_h: i32,
    glyph: *const font.Glyph,
    clip_x0: i32,
    clip_x1: i32,
) void {
    if (glyph.width == 0 or glyph.height == 0 or glyph.bitmap.len == 0) return;
    const fit = colorGlyphFit(cell_w, cell_h, glyph.width, glyph.height) orelse return;

    const gw_f: f64 = @floatFromInt(glyph.width);
    const gh_f: f64 = @floatFromInt(glyph.height);
    const tw_f: f64 = @floatFromInt(fit.w);
    const th_f: f64 = @floatFromInt(fit.h);

    var dy: i32 = 0;
    while (dy < fit.h) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < fit.w) : (dx += 1) {
            // 여기 `+ 0.5` 는 반올림 보정이 아니라 **목적 픽셀의 중심**을 원본 좌표로
            // 옮기는 nearest-neighbor 샘플링이다 (`@round` 로 바꾸면 샘플 위치가 어긋난다).
            const src_x: u32 = @trunc((@as(f64, @floatFromInt(dx)) + 0.5) * gw_f / tw_f);
            const src_y: u32 = @trunc((@as(f64, @floatFromInt(dy)) + 0.5) * gh_f / th_f);
            if (src_x >= glyph.width or src_y >= glyph.height) continue;
            const src_off: usize = (@as(usize, src_y) * glyph.width + src_x) * 4;
            const b = glyph.bitmap[src_off];
            const g = glyph.bitmap[src_off + 1];
            const r = glyph.bitmap[src_off + 2];
            const a = glyph.bitmap[src_off + 3];
            if (a == 0) continue;

            const px = cell_x + fit.off_x + dx;
            const py = cell_y + fit.off_y + dy;
            if (px < clip_x0 or px >= clip_x1) continue;
            if (px < 0 or py < 0 or px >= fb_w or py >= fb_h) continue;

            const dst_off: usize = @intCast(py * stride + px * 4);
            const dst_b = memory[dst_off];
            const dst_g = memory[dst_off + 1];
            const dst_r = memory[dst_off + 2];
            const inv: u32 = 255 - @as(u32, a);
            // premultiplied: out = src + (1 - a) * dst. 반올림은 최근접 —
            // `blendPixel` 과 같은 이유로 GPU 블렌드 유닛에 맞춘다 (#277 S2-4).
            const out_b: u8 = @intCast(@min(@as(u32, 255), @as(u32, b) + (@as(u32, dst_b) * inv + 127) / 255));
            const out_g: u8 = @intCast(@min(@as(u32, 255), @as(u32, g) + (@as(u32, dst_g) * inv + 127) / 255));
            const out_r: u8 = @intCast(@min(@as(u32, 255), @as(u32, r) + (@as(u32, dst_r) * inv + 127) / 255));
            memory[dst_off] = out_b;
            memory[dst_off + 1] = out_g;
            memory[dst_off + 2] = out_r;
        }
    }
}

/// [`SolidRect`] 하나를 그린다 (CPU 경로).
///
/// `shade == 0` 이면 불투명 채움. `1·2·3` 이면 d3d11 `bg_shader_src` / macOS Metal
/// `bg_fs` / GL `gl_rects` 셰이더와 **동일 식**의 procedural dot mask 를 적용한다 —
/// 픽셀의 absolute (px, py) 로 패턴을 결정해 인접 셀 사이 끊김 없이 대각 zigzag 가
/// 이어진다. dot 픽셀만 색을 쓰고 나머지는 이미 그려진 배경 그대로 (셰이더의
/// `discard` 동등).
///
/// 색은 **알파를 이미 배경과 합성한 값** (#353) — 수집기가 공통
/// `ui_metrics.blendOverRgb` 로 만든다. 여기서 알파를 다시 적용하지 않는다.
fn drawSolidRect(memory: []u8, fb_w: i32, fb_h: i32, stride: i32, r: SolidRect) void {
    if (r.shade == 0) {
        rect(memory, fb_w, fb_h, stride, r.x, r.y, r.w, r.h, r.color);
        return;
    }

    const cx0 = @max(0, r.x);
    const cy0 = @max(0, r.y);
    const cx1 = @min(fb_w, r.x + r.w);
    const cy1 = @min(fb_h, r.y + r.h);
    if (cx1 <= cx0 or cy1 <= cy0) return;

    const fg_packed = pack(r.color);
    var py = cy0;
    while (py < cy1) : (py += 1) {
        var px = cx0;
        while (px < cx1) : (px += 1) {
            const on: bool = switch (r.shade) {
                // U+2591 LIGHT 25% — diagonal sparse
                1 => ((px + 2 * py) & 3) == 0,
                // U+2592 MEDIUM 50% — checkerboard
                2 => ((px + py) & 1) == 0,
                // U+2593 DARK 75% — LIGHT 의 inverse (diagonal dense)
                else => ((px + 2 * py) & 3) != 0,
            };
            if (!on) continue;
            const off: usize = @intCast(py * stride + px * 4);
            std.mem.writeInt(u32, memory[off..][0..4], fg_packed, .little);
        }
    }
}

fn pack(color: ghostty.color.RGB) u32 {
    return (@as(u32, color.r) << 16) | (@as(u32, color.g) << 8) | color.b;
}

/// 알파 합성 한 픽셀. **반올림은 최근접**이다 — 공통 [`ui_metrics.blendOverU8`]
/// (#353) 과 같은 규칙이고, GPU 의 블렌드 유닛과도 같다.
///
/// `(x + 127) / 255` 가 `round(x / 255)` 와 **정확히** 같다: `x = 255k + r` 이면
/// `r ≤ 127` 일 때 `k`, `r ≥ 128` 일 때 `k+1` 이 나온다. 정수 `x` 에 대해
/// `x / 255 = k + 0.5` 는 성립할 수 없으므로 tie 자체가 없다.
///
/// 이전에는 버림(`/ 255`)이었다. 같은 화면을 GL 로 그리면 GPU 가 최근접으로
/// 반올림해 안티에일리어싱 픽셀이 채널당 1 씩 어긋났고, 저장소 자신의 합성 규칙
/// (`blendOverU8`) 과도 어긋나 있었다 (#277 S2-4).
fn blendPixel(fg: ghostty.color.RGB, bg: ghostty.color.RGB, alpha: u8) u32 {
    const a: u32 = alpha;
    const inv: u32 = 255 - a;
    const r: u32 = (@as(u32, fg.r) * a + @as(u32, bg.r) * inv + 127) / 255;
    const g: u32 = (@as(u32, fg.g) * a + @as(u32, bg.g) * inv + 127) / 255;
    const b: u32 = (@as(u32, fg.b) * a + @as(u32, bg.b) * inv + 127) / 255;
    return (r << 16) | (g << 8) | b;
}

test "#362 — 줄 경계는 쓰인 칸을 절대 빼먹지 않는다" {
    // `Cell` 의 zero value 가 "한 번도 쓰인 적 없는 칸" 이라는 것이 근거다.
    // 여기서 고정하는 것은 **한쪽으로만 틀린다** 는 성질 — 넘치게 도는 것은
    // 괜찮고, 쓰인 칸을 건너뛰는 것은 화면이 틀리는 것이다.
    var cells: [40]ghostty.Cell = @splat(.{});
    cells[3] = .{ .content_tag = .codepoint, .content = .{ .codepoint = .{ .data = 'A' } } };
    cells[20] = .{ .content_tag = .codepoint, .content = .{ .codepoint = .{ .data = 'B' } } };

    // 마지막으로 쓰인 칸(20) 다음까지.
    try std.testing.expectEqual(@as(usize, 21), Renderer.rowLimit(&cells, 40, null));
    // 선택이 그 뒤까지 걸리면 경계를 늘린다 (빈 칸도 배경을 그려야 한다).
    try std.testing.expectEqual(@as(usize, 31), Renderer.rowLimit(&cells, 40, .{ 25, 30 }));
    // 선택이 쓰인 범위 안이면 경계는 그대로.
    try std.testing.expectEqual(@as(usize, 21), Renderer.rowLimit(&cells, 40, .{ 1, 5 }));
    // 전부 빈 줄은 볼 것이 없다.
    const blank: [40]ghostty.Cell = @splat(.{});
    try std.testing.expectEqual(@as(usize, 0), Renderer.rowLimit(&blank, 40, null));
}

test "#277 S2-4 — blendPixel 은 최근접 반올림 (GPU 블렌드 유닛과 같은 규칙)" {
    const white = ghostty.color.RGB{ .r = 255, .g = 255, .b = 255 };
    const black = ghostty.color.RGB{ .r = 0, .g = 0, .b = 0 };
    // alpha=128 → 255*128/255 = 128.0 정확. 버림/반올림 무관.
    try std.testing.expectEqual(@as(u32, 0x808080), blendPixel(white, black, 128));
    // alpha=1 → 255/255 = 1.0 정확.
    try std.testing.expectEqual(@as(u32, 0x010101), blendPixel(white, black, 1));
    // fg=1 bg=0 alpha=200 → 200/255 = 0.784 → 최근접 1 (버림이면 0).
    const one = ghostty.color.RGB{ .r = 1, .g = 1, .b = 1 };
    try std.testing.expectEqual(@as(u32, 0x010101), blendPixel(one, black, 200));
    // 모든 (fg, bg, alpha) 조합에서 공통 `blendOverU8` 과 일치해야 한다.
    for ([_]u8{ 0, 1, 63, 127, 128, 200, 254, 255 }) |fg_v| {
        for ([_]u8{ 0, 7, 64, 129, 200, 255 }) |bg_v| {
            for ([_]u8{ 0, 1, 17, 127, 128, 199, 254, 255 }) |a| {
                const packed_rgb = blendPixel(
                    .{ .r = fg_v, .g = fg_v, .b = fg_v },
                    .{ .r = bg_v, .g = bg_v, .b = bg_v },
                    a,
                );
                const expected = ui_metrics.blendOverU8(fg_v, bg_v, @as(f32, @floatFromInt(a)) / 255.0);
                try std.testing.expectEqual(@as(u32, expected), packed_rgb & 0xFF);
            }
        }
    }
}

test "#309 tab clipping keeps a high-index drag source reachable" {
    const left: i32 = 24;
    const right: i32 = 324;
    const tab_w: i32 = 100;

    // Exact boundaries and partial overlap.
    try std.testing.expectEqual(TabClipDecision.skip, tabClipDecision(left - tab_w, tab_w, left, right, false));
    try std.testing.expectEqual(TabClipDecision.draw, tabClipDecision(left - tab_w + 1, tab_w, left, right, false));
    try std.testing.expectEqual(TabClipDecision.draw, tabClipDecision(right - 1, tab_w, left, right, false));
    try std.testing.expectEqual(TabClipDecision.stop, tabClipDecision(right, tab_w, left, right, false));
    try std.testing.expectEqual(TabClipDecision.skip, tabClipDecision(right, tab_w, left, right, true));

    // indices 3..6 are ordinary tabs beyond the right edge, while high index 7
    // is the drag source moved under the pointer into the viewport. The old
    // source-only guard stopped at index 3 and never reached index 7.
    const dragged_positions = [_]i32{ 24, 124, 224, 324, 424, 524, 624, 74 };
    var reached_drag_source = false;
    for (dragged_positions, 0..) |tab_x, i| {
        switch (tabClipDecision(tab_x, tab_w, left, right, true)) {
            .skip => continue,
            .stop => break,
            .draw => if (i == 7) {
                reached_drag_source = true;
            },
        }
    }
    try std.testing.expect(reached_drag_source);

    // Without a drag, positions remain monotonic and the existing early stop
    // optimization must remain active at the exact right boundary.
    const ordered_positions = [_]i32{ 24, 124, 224, 324, 424 };
    var draw_count: usize = 0;
    var stop_index: ?usize = null;
    for (ordered_positions, 0..) |tab_x, i| {
        switch (tabClipDecision(tab_x, tab_w, left, right, false)) {
            .skip => continue,
            .stop => {
                stop_index = i;
                break;
            },
            .draw => draw_count += 1,
        }
    }
    try std.testing.expectEqual(@as(usize, 3), draw_count);
    try std.testing.expectEqual(@as(?usize, 3), stop_index);
}

// #213 재현 — About dialog paint 경로 (compositor 무관). KDE Plasma 1.7x 에서
// Ctrl+Shift+I crash 가 layer-shell dialog paint (`handleDialogConfigure` →
// `drawDialogContent`) 에 있는지 격리. layer-shell 미지원 DE (Cinnamon 등) 에선
// dialog 가 안 떠 GUI 재현 불가하므로 paint 만 직접 호출. ReleaseSafe 로 돌리면
// safety panic 의 정확한 source line 확보.
test "#213 about dialog paint — scale 1.7 + 긴 multi-line + URL" {
    const allocator = std.testing.allocator;
    // 실제 GUI 경로 재현 — hand-build 가 아니라 `Renderer.init` 로 *실제 Config*
    // (Linux default = DejaVu Sans Mono + Noto fallback chain + size_point 15 +
    // cell_width_ratio 1.0 + **line_height_ratio 1.1**) 를 scale 1.7 (204/120) 로
    // 초기화. 이전 버전은 chain={"monospace"} + line_height 1.0 hand-build 라
    // 사용자 config (line_height 1.1) 의 layout 을 재현 못 했음 (#213 진단 cycle).
    const cfg = config_mod.Config{};
    var r = Renderer.init(allocator, &cfg, 204, 120) catch {
        // fontconfig 없는 환경(CI 등)에선 이 테스트를 건너뛴다.
        return error.SkipZigTest;
    };
    defer r.deinit(allocator);
    // #368 — dialog 폰트는 지연 생성이다. host 는 dialog 를 열 때 이걸 부른다
    // (`openDialogSurface`) — 테스트도 같은 순서를 밟아야 실제 경로와 같다.
    r.ensureDialogFonts(allocator);

    const title = "About TildaZ";
    const msg =
        \\TildaZ v0.5.0
        \\
        \\exe   : /home/ensky0/tildaz/zig-out/bin/tildaz
        \\pid   : 12345
        \\config: /home/ensky0/.config/tildaz/config_0.json
        \\log   : /home/ensky0/.local/state/tildaz/tildaz_0.log
        \\
        \\Tip: Ctrl+Shift+P opens config in default editor.
        \\     Ctrl+Shift+L opens log.
        \\
        \\https://github.com/ensky0/tildaz
    ;

    const layout = r.computeDialogLayout(title, msg, .info, 1920, 1080);
    const size = layout.size;
    // handleDialogConfigure 의 logical 왕복 재현 (preferred_scale 204/120 = 1.7x):
    // physical → logical(set_size) → KWin echo → logicalToPhysical(buffer).
    const lw = @divFloor(size.w * 120, 204);
    const lh = @divFloor(size.h * 120, 204);
    const pw = @divFloor(lw * 204, 120);
    const ph = @divFloor(lh * 204, 120);
    const stride = pw * 4;
    const buf = try allocator.alloc(u8, @intCast(stride * ph));
    defer allocator.free(buf);
    @memset(buf, 0);
    r.drawDialogContent(
        buf,
        pw,
        ph,
        stride,
        .info,
        title,
        msg,
        null,
        null,
        null,
        false,
        layout.wrap_width,
        layout.message_rows,
        layout.visible_message_rows,
        0,
        layout.show_icon,
    );
}

test "#314 overflow About renderer draws 2pt brand separator and movable gray scrollbar at 1.7x" {
    const allocator = std.testing.allocator;
    const cfg = config_mod.Config{};
    var r = Renderer.init(allocator, &cfg, 204, 120) catch return error.SkipZigTest;
    // #368 — dialog 폰트는 지연 생성이다. host 는 dialog 를 열 때 이걸 부른다
    // (`openDialogSurface`) — 테스트도 같은 순서를 밟아야 실제 경로와 같다.
    r.ensureDialogFonts(allocator);
    defer r.deinit(allocator);

    const title = "About TildaZ";
    const msg = ("/home/" ++ ("x" ** 500) ++ "\n") ** 4;
    const layout = r.computeDialogLayout(title, msg, .about, 1088, 816);
    try std.testing.expect(layout.message_scroll_max > 0);
    try std.testing.expect(layout.visible_message_rows < layout.message_rows);

    const stride = layout.size.w * 4;
    const buf = try allocator.alloc(u8, @intCast(stride * layout.size.h));
    defer allocator.free(buf);
    @memset(buf, 0);

    r.drawDialogContent(
        buf,
        layout.size.w,
        layout.size.h,
        stride,
        .info,
        title,
        msg,
        null,
        null,
        null,
        false,
        layout.wrap_width,
        layout.message_rows,
        layout.visible_message_rows,
        0,
        layout.show_icon,
    );
    // #368 — dialog 폰트는 지연 생성이라 이 시점엔 이미 만들어져 있어야 한다
    // (`drawDialogContent` 가 위에서 불렸다). 없으면 그 자체가 회귀다.
    const ch: i32 = @intCast(r.dialog_font_ctx.?.cell_height_px);
    const title_ch: i32 = @intCast(r.dialog_title_font_ctx.?.cell_height_px);
    const sm = scaledPt(dialog_shadow_margin_pt, r.scale);
    const pad = scaledPt(dialog_padding_pt, r.scale);
    const separator_x = sm + pad + 1;
    const separator_h = scaledPt(ui_metrics.DIALOG_SEPARATOR_THICKNESS_PT, r.scale);
    try std.testing.expectEqual(@as(i32, 3), separator_h);
    const separator_center_y = sm + pad +
        (if (layout.show_icon)
            scaledPt(dialog_icon_size_pt, r.scale) + scaledPt(dialog_icon_gap_pt, r.scale)
        else
            0) +
        title_ch + @divTrunc(ch, 2);
    const separator_y = separator_center_y - @divTrunc(separator_h, 2);
    var separator_row: i32 = 0;
    while (separator_row < separator_h) : (separator_row += 1) {
        const separator_off: usize = @intCast((separator_y + separator_row) * stride + separator_x * 4);
        const info_separator = std.mem.readInt(u32, buf[separator_off..][0..4], .little) & 0x00FF_FFFF;
        try std.testing.expectEqual(pack(dialog_separator_color), info_separator);
    }
    const separator_center_off: usize = @intCast(separator_center_y * stride + separator_x * 4);
    const info_separator = std.mem.readInt(u32, buf[separator_center_off..][0..4], .little) & 0x00FF_FFFF;

    const first_thumb_y = r.last_dialog_scrollbar_thumb_rect.y;
    try std.testing.expect(r.last_dialog_scrollbar_track_rect.w > 0);
    try std.testing.expect(r.last_dialog_scrollbar_thumb_rect.h > 0);
    try std.testing.expectEqual(@as(i32, 17), r.last_dialog_scrollbar_track_rect.w);
    try std.testing.expectEqual(@as(i32, 31), r.last_dialog_scrollbar_hit_rect.w);
    try std.testing.expectEqual(
        r.last_dialog_scrollbar_track_rect.x,
        r.last_dialog_scrollbar_hit_rect.x + 14,
    );
    const thumb = r.last_dialog_scrollbar_thumb_rect;
    const thumb_center_off: usize = @intCast(
        (thumb.y + @divTrunc(thumb.h, 2)) * stride +
            (thumb.x + @divTrunc(thumb.w, 2)) * 4,
    );
    const thumb_pixel = std.mem.readInt(u32, buf[thumb_center_off..][0..4], .little);
    // drawDialogContent는 마지막에 surface opacity를 high alpha byte에 채운다.
    // 가시 대비 판정은 같은 alpha를 제외한 RGB channel을 비교한다.
    const thumb_rgb = thumb_pixel & 0x00FF_FFFF;
    try std.testing.expectEqual(pack(dialog_scrollbar_color), thumb_rgb);
    try std.testing.expect(thumb_rgb != pack(dialog_bg_color));
    try std.testing.expect(thumb_rgb != info_separator);

    r.drawDialogContent(
        buf,
        layout.size.w,
        layout.size.h,
        stride,
        .err,
        title,
        msg,
        null,
        null,
        null,
        false,
        layout.wrap_width,
        layout.message_rows,
        layout.visible_message_rows,
        0,
        layout.show_icon,
    );
    const error_separator = std.mem.readInt(u32, buf[separator_center_off..][0..4], .little) & 0x00FF_FFFF;
    try std.testing.expectEqual(info_separator, error_separator);

    r.drawDialogContent(
        buf,
        layout.size.w,
        layout.size.h,
        stride,
        .info,
        title,
        msg,
        null,
        null,
        null,
        false,
        layout.wrap_width,
        layout.message_rows,
        layout.visible_message_rows,
        layout.message_scroll_max,
        layout.show_icon,
    );
    try std.testing.expect(r.last_dialog_scrollbar_thumb_rect.y > first_thumb_y);
}
