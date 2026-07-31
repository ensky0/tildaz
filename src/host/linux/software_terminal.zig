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
const freetype = @import("../../font/linux/freetype.zig");
const block_element = @import("../../renderer/block_element.zig");
const cell_color = @import("../../renderer/cell_color.zig");
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
/// 두 버튼 사이 간격 (PT). pad 와 무관한 작은 gap.
const dialog_button_gap_pt: u32 = 12;

/// #203 Phase C step 3.3 — dialog 상단 아이콘 크기 (PT, 논리 점). `docs/favicon.svg`
/// 의 viewBox=64×64 를 그대로 줄여 그림. tildaz 의 monitor + `>_` 표지. 사용자
/// 시연 발견 — 이전 48 physical 고정 + 1.7x 환경에서 *논리 28* 로 너무 작음.
const dialog_icon_size_pt: u32 = ui_metrics.DIALOG_ICON_SIZE_PT;
const dialog_padding_pt: u32 = 8;
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

pub const Renderer = struct {
    render_state: ghostty.RenderState = .empty,
    font_ctx: font.Context,
    tab_font_ctx: font.Context,
    dialog_font_ctx: font.Context,
    dialog_title_font_ctx: font.Context,
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

        const dialog_spec = ui_metrics.dialogBodyFontSpec();
        const dialog_pixel_height = scaledFontPixelHeight(dialog_spec, scale_num, scale_den);
        var dialog_ctx = try font.Context.init(
            allocator,
            chain,
            dialog_pixel_height,
            dialog_spec.cell_width_ratio,
            dialog_spec.line_height_ratio,
        );
        errdefer dialog_ctx.deinit();

        const dialog_title_spec = ui_metrics.dialogTitleFontSpec();
        const dialog_title_pixel_height = scaledFontPixelHeight(dialog_title_spec, scale_num, scale_den);
        var dialog_title_ctx = try font.Context.init(
            allocator,
            chain,
            dialog_title_pixel_height,
            dialog_title_spec.cell_width_ratio,
            dialog_title_spec.line_height_ratio,
        );
        errdefer dialog_title_ctx.deinit();

        // #335 — chrome 색 파생. null theme fallback 은 `wayland_minimal.zig` 의
        // `fallback_theme` (= themes 첫 entry "Tilda") 와 같은 선택이다.
        const chrome_theme = cfg.theme orelse &themes.themes[0];
        const chrome_bg = chrome_theme.background;

        return .{
            .render_state = .empty,
            .font_ctx = terminal_ctx,
            .tab_font_ctx = tab_ctx,
            .dialog_font_ctx = dialog_ctx,
            .dialog_title_font_ctx = dialog_title_ctx,
            .scale = scaleFactor(scale_num, scale_den),
            .chrome = chrome_palette.derive(
                .{ chrome_bg.r, chrome_bg.g, chrome_bg.b },
                themes.isDark(chrome_theme),
            ),
        };
    }

    pub fn deinit(self: *Renderer, allocator: std.mem.Allocator) void {
        self.render_state.deinit(allocator);
        self.dialog_title_font_ctx.deinit();
        self.dialog_font_ctx.deinit();
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

        const dialog_spec = ui_metrics.dialogBodyFontSpec();
        const dialog_pixel_height = scaledFontPixelHeight(dialog_spec, scale_num, scale_den);
        var new_dialog_ctx = try font.Context.init(
            allocator,
            chain,
            dialog_pixel_height,
            dialog_spec.cell_width_ratio,
            dialog_spec.line_height_ratio,
        );
        errdefer new_dialog_ctx.deinit();

        const dialog_title_spec = ui_metrics.dialogTitleFontSpec();
        const dialog_title_pixel_height = scaledFontPixelHeight(dialog_title_spec, scale_num, scale_den);
        var new_dialog_title_ctx = try font.Context.init(
            allocator,
            chain,
            dialog_title_pixel_height,
            dialog_title_spec.cell_width_ratio,
            dialog_title_spec.line_height_ratio,
        );
        errdefer new_dialog_title_ctx.deinit();

        self.dialog_title_font_ctx.deinit();
        self.dialog_font_ctx.deinit();
        self.tab_font_ctx.deinit();
        self.font_ctx.deinit();
        self.font_ctx = new_ctx;
        self.tab_font_ctx = new_tab_ctx;
        self.dialog_font_ctx = new_dialog_ctx;
        self.dialog_title_font_ctx = new_dialog_title_ctx;
        self.scale = scaleFactor(scale_num, scale_den);
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

    pub fn paint(
        self: *Renderer,
        allocator: std.mem.Allocator,
        memory: []u8,
        width: i32,
        height: i32,
        stride: i32,
        terminal: *ghostty.Terminal,
        theme: *const themes.Theme,
        tab_titles: []const []const u8,
        active_tab_idx: usize,
        layout: tab_layout.Layout,
        tab_scroll_x: f32,
        drag_view: ?tab_interaction.DragView,
        tab_hover: tab_layout.Area,
        menu_ui: command_menu.Ui,
        toggle_hotkey: []const u8,
    ) void {
        self.render_state.update(allocator, terminal) catch {
            fill(memory, width, height, stride, theme.background);
            return;
        };

        const colors = self.render_state.colors;
        fill(memory, width, height, stride, colors.background);

        const cw = self.cellWidth();
        const ch = self.cellHeight();
        const ascent: i32 = @intCast(self.font_ctx.ascent_px);
        const pad: i32 = self.paddingPx();
        const tab_bar_h: i32 = self.tabBarHeightPx(tab_titles.len);
        const scrollbar_top: i32 = if (tab_titles.len > 0) self.chromeHeightPx() else 0;
        const sb_w: i32 = self.scrollbarWPx();
        const sb_min_thumb: i32 = self.scrollbarMinThumbHPx();

        // L12-α/β/γ — 상단 tab bar 영역. cross-platform tab_layout 의 Layout
        // (`<`[tabs][+]`>` 또는 `[tabs][+]` 영역 분할) 따라 그리기. arrow /
        // plus / scroll 모두 적용. #334 — 탭 배경은 탭바와 같은 색, 활성은
        // amber 밑줄, 탭 경계는 세로 구분선 (Windows/macOS 동일).
        drawTabBar(memory, width, height, stride, tab_bar_h, self.tabWidthPx(), self.tabPaddingPx(), tab_titles, active_tab_idx, layout, tab_hover, tab_scroll_x, drag_view, self.scale, &self.tab_font_ctx, &self.chrome);

        const rows = self.render_state.rows;
        const cols = self.render_state.cols;
        const row_slice = self.render_state.row_data.slice();
        const all_cells = row_slice.items(.cells);
        const all_sels = row_slice.items(.selection);

        for (0..rows) |y| {
            if (y >= all_cells.len) break;
            const cell_slice = all_cells[y].slice();
            const raws = cell_slice.items(.raw);
            const styles = cell_slice.items(.style);
            const graphemes = cell_slice.items(.grapheme);
            const sel_range: ?[2]u16 = if (y < all_sels.len) all_sels[y] else null;

            var x: usize = 0;
            while (x < cols and x < raws.len) {
                const raw = raws[x];
                // spacer_head (wide 글자 wrap 직전 행 끝 cell) 는 bg/selection
                // 은 그리고 text 단계에서만 제외 — Windows/macOS 동일 (#282 B9).
                if (raw.wide == .spacer_tail) {
                    x += 1;
                    continue;
                }

                const style = if (raw.style_id != 0) styles[x] else ghostty.Style{};
                const x16: u16 = @intCast(x);
                const is_selected = if (sel_range) |sr| (x16 >= sr[0] and x16 <= sr[1]) else false;
                const bg = resolveBg(style, &raw, &colors, is_selected);
                const cell_x: i32 = pad + @as(i32, @intCast(x)) * cw;
                const cell_y: i32 = tab_bar_h + pad + @as(i32, @intCast(y)) * ch;
                const cell_w: i32 = if (raw.wide == .wide) cw * 2 else cw;

                if (is_selected or style.flags.inverse or style.bg(&raw, &colors.palette) != null) {
                    rect(memory, width, height, stride, cell_x, cell_y, cell_w, ch, bg);
                }

                if (raw.wide == .spacer_head or !raw.hasText() or raw.codepoint() == 0) {
                    x += 1;
                    continue;
                }
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
                    const blended = ui_metrics.blendOverRgb(
                        .{ fg.r, fg.g, fg.b },
                        .{ bg.r, bg.g, bg.b },
                        br.alpha,
                    );
                    drawBlockRect(memory, width, height, stride, cell_x, cell_y, cell_w, ch, br, .{
                        .r = blended[0],
                        .g = blended[1],
                        .b = blended[2],
                    });
                    x += 1;
                    continue;
                }

                // Box-drawing (선/모서리/junction, U+2500–257F) — block element 과
                // 같은 이유로 procedural 사각형 (#258). 폰트(FreeType) 글리프는
                // cell 에 안 맞아 셀 사이 갭. 대각선은 null → 아래 글리프 path.
                if (cp >= 0x2500 and cp <= 0x257F) {
                    var box_rects: [box_drawing.MAX_RECTS]box_drawing.Rect = undefined;
                    if (box_drawing.boxRects(cp, @floatFromInt(cell_w), @floatFromInt(ch), &box_rects)) |bn| {
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
                            rect(
                                memory,
                                width,
                                height,
                                stride,
                                cell_x + @as(i32, @intFromFloat(br.x)),
                                cell_y + @as(i32, @intFromFloat(br.y)),
                                @as(i32, @intFromFloat(br.w)),
                                @as(i32, @intFromFloat(br.h)),
                                .{ .r = cov_blend[0], .g = cov_blend[1], .b = cov_blend[2] },
                            );
                        }
                        x += 1;
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
                    var cluster: [16]u21 = undefined;
                    cluster[0] = cp;
                    const extras = graphemes[x];
                    const take = @min(extras.len, cluster.len - 1);
                    @memcpy(cluster[1..][0..take], extras[0..take]);
                    if (self.font_ctx.resolveCluster(cluster[0 .. 1 + take])) |cg| {
                        const cluster_glyph = self.font_ctx.glyphByIndex(cg.face_idx, cg.glyph_index);
                        if (cluster_glyph.pixel_mode == freetype.FT_PIXEL_MODE_BGRA) {
                            drawGlyphBgra(memory, width, height, stride, cell_x, cell_y, cell_w, ch, cluster_glyph);
                        } else {
                            const baseline = cell_y + ascent;
                            const glyph_advance_i32: i32 = @intCast(cluster_glyph.advance);
                            const center_off: i32 = @divFloor(cell_w - glyph_advance_i32, 2);
                            drawGlyph(
                                memory,
                                width,
                                height,
                                stride,
                                cell_x + center_off + cluster_glyph.bitmap_left + cg.x_offset,
                                baseline - cluster_glyph.bitmap_top - cg.y_offset,
                                cluster_glyph,
                                fg,
                                bg,
                            );
                        }
                        x += 1;
                        continue;
                    }
                    // resolveCluster null → primary face 에 cluster 매치 없음.
                    // 아래 base codepoint chain lookup 으로 fallthrough (extras
                    // 무시되지만 base 는 emoji face 등에서 매치 → 시각상 합리).
                }

                // L5-2-β: 2-char ligature lookahead. 다음 cell 도 plain single
                // codepoint + non-wide + same style + ASCII printable 범위면
                // `ligaturePair(cp, next_cp)` 시도. HarfBuzz shape 결과 1 glyph 면
                // ligature 확정 → 첫 cell 위치에 ligature glyph (2 cell 너비) +
                // 다음 cell 의 cell area 는 bg 만 (다음 cell skip). cache 가
                // 같은 ASCII pair 결과 보관해 매 frame 매 cell pair shape 호출
                // 회피.
                //
                // 조건: 둘 다 narrow, single codepoint, style_id 일치 (= 같은
                // attribute, fg / bg / flags 등). 다른 색 / underline 등 다른
                // style 의 cell pair 는 ligature 안 — terminal 의 자연스러운
                // 의미 (color 분리 = 의도된 두 문자).
                // 3-char ligature lookahead 먼저. Fira Code / JetBrains Mono /
                // Cascadia Code 의 흔한 3-char ligature (`===` / `!==` / `<=>` /
                // `<--` / `-->` / `<->` / `<==` / `==>` / `||=` 등). 2-char
                // 보다 *먼저* 시도해야 `===` 가 `==` + `=` 로 분해되지 않음.
                // cache miss 시 1 회 shape — 같은 triple 반복 호출은 캐시 hit.
                if (x + 2 < cols and x + 2 < raws.len and raw.wide == .narrow and isLigatureCandidate(cp)) {
                    const next = raws[x + 1];
                    const next2 = raws[x + 2];
                    if (next.wide == .narrow and next.hasText() and next.codepoint() != 0 and
                        next.style_id == raw.style_id and isLigatureCandidate(next.codepoint()) and
                        next2.wide == .narrow and next2.hasText() and next2.codepoint() != 0 and
                        next2.style_id == raw.style_id and isLigatureCandidate(next2.codepoint()))
                    {
                        const next_cp = next.codepoint();
                        const next2_cp = next2.codepoint();
                        if (self.font_ctx.ligatureTriple(cp, next_cp, next2_cp)) |lm| {
                            drawLigatureMatch(
                                &self.font_ctx,
                                memory,
                                width,
                                height,
                                stride,
                                raws,
                                styles,
                                sel_range,
                                &colors,
                                pad,
                                cell_y,
                                cw,
                                ch,
                                ascent,
                                x,
                                3,
                                lm,
                                fg,
                                bg,
                            );
                            x += 3;
                            continue;
                        }
                    }
                }

                if (x + 1 < cols and x + 1 < raws.len and raw.wide == .narrow and isLigatureCandidate(cp)) {
                    const next = raws[x + 1];
                    if (next.wide == .narrow and next.hasText() and next.codepoint() != 0 and
                        next.style_id == raw.style_id and isLigatureCandidate(next.codepoint()))
                    {
                        const next_cp = next.codepoint();
                        if (self.font_ctx.ligaturePair(cp, next_cp)) |lm| {
                            drawLigatureMatch(
                                &self.font_ctx,
                                memory,
                                width,
                                height,
                                stride,
                                raws,
                                styles,
                                sel_range,
                                &colors,
                                pad,
                                cell_y,
                                cw,
                                ch,
                                ascent,
                                x,
                                2,
                                lm,
                                fg,
                                bg,
                            );
                            x += 2;
                            continue;
                        }
                    }
                }

                const glyph = self.font_ctx.glyph(cp);
                if (glyph.pixel_mode == freetype.FT_PIXEL_MODE_BGRA) {
                    // color emoji — bitmap 이 보통 strike size (~109px) 라 cell 안 ratio
                    // 유지 scale down + cell 가운데 fit. emoji 색 자체 사용 (fg 무시).
                    drawGlyphBgra(memory, width, height, stride, cell_x, cell_y, cell_w, ch, glyph);
                } else {
                    // proportional 폰트 (`fc-match monospace` 가 NotoSansCJK 같은 sans-serif
                    // 로 매치되는 환경 등) 라도 글자가 cell 안 가운데에 균일하게 분포하도록
                    // advance-center 정렬. monospace 면 글리프 advance == cell width 라 offset
                    // = 0 (그대로). wide glyph 의 fallback (placeholder '?') 도 cell-pair 가운데로.
                    const baseline = cell_y + ascent;
                    const glyph_advance_i32: i32 = @intCast(glyph.advance);
                    const center_off: i32 = @divFloor(cell_w - glyph_advance_i32, 2);
                    drawGlyph(
                        memory,
                        width,
                        height,
                        stride,
                        cell_x + center_off + glyph.bitmap_left,
                        baseline - glyph.bitmap_top,
                        glyph,
                        fg,
                        bg,
                    );
                }
                x += 1;
            }
        }

        // Cursor (#297 — 세로 막대 bar, 세 platform 공통). 셀 좌측에 opaque
        // bar. wide char 는 wide_tail 보정으로 글자 시작 cell 의 좌측에 위치.
        // 폭은 `ui_metrics.CURSOR_BAR_W_PT` × scale (Windows/macOS 와 동일 식).
        if (self.render_state.cursor.visible) {
            if (self.render_state.cursor.viewport) |vp| {
                var cx: i32 = pad + @as(i32, @intCast(vp.x)) * cw;
                if (vp.wide_tail and vp.x > 0) cx -= cw;
                const cy: i32 = tab_bar_h + pad + @as(i32, @intCast(vp.y)) * ch;
                const cursor = colors.cursor orelse ghostty.color.RGB{ .r = 180, .g = 180, .b = 180 };
                const bar_w: i32 = @intFromFloat(ui_metrics.cursorBarWidthPx(self.scale));
                rect(memory, width, height, stride, cx, cy, bar_w, ch, cursor);
            }
        }

        // #343 단계 2 — scrollbar thumb 의 rect 와 색은 공통 `scrollbar.thumbRect`
        // 한 곳이 만든다 (track 자체는 별도 색 없이 배경 그대로 — 세 platform 동일).
        // #259 — drag hit-test (`wayland_minimal.scrollbarHit`) 와 같은 입력.
        const sb = terminal.screens.active.pages.scrollbar();
        if (scrollbar.thumbRect(
            sb.total,
            sb.len,
            sb.offset,
            @floatFromInt(width),
            @floatFromInt(height),
            @floatFromInt(scrollbar_top),
            @floatFromInt(pad),
            @floatFromInt(sb_min_thumb),
            @floatFromInt(sb_w),
            .{ colors.background.r, colors.background.g, colors.background.b },
        )) |r| {
            fillChromeRect(memory, width, height, stride, r);
        }

        // --- L10-β: IME preedit (조합 중) inline overlay ---
        // cursor 위치부터 preedit_text 의 codepoint 별로 보라색 배경 + foreground
        // 글자. AGENTS.md "한글 IME 동작 스펙" — "강조 배경 (보라색 계열) + 글자
        // 로 inline 표시. 별도 candidate window 안 띄움". macOS / Windows 와
        // 동등 색 (`renderer/macos.zig:686`, `renderer/windows.zig:1144`).
        // PTY 에는 들어가지 않고 화면 표시만 — fcitx5 가 commit_string 으로
        // 음절 완성 보내주면 그때 PTY 송신 + preedit 클리어.
        if (self.preedit_text.len > 0) {
            if (self.render_state.cursor.viewport) |vp| {
                drawPreeditOverlay(
                    memory,
                    width,
                    height,
                    stride,
                    pad,
                    tab_bar_h,
                    cw,
                    ch,
                    ascent,
                    @intCast(vp.x),
                    @intCast(vp.y),
                    cols,
                    self.preedit_text,
                    colors.foreground,
                    &self.font_ctx,
                );
            }
        }

        // #329 — 단일 탭은 terminal grid를 y=0에 둔 채 우측 상단
        // `[+][×][…]` 72×28pt만 마지막 chrome layer로 overlay한다.
        if (tab_titles.len == 1) {
            const controls = tab_layout.computeControls(
                @floatFromInt(width),
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
            // (`buildControlsOnly`) 이 만든다. 탭바 전체 배경 · 밑줄 · 구분선은
            // 단일 탭 overlay 에 없으므로 컨트롤 구간만 쓴다.
            const overlay_in = tab_chrome.Inputs{
                .viewport_w = @floatFromInt(width),
                .tab_bar_h = @floatFromInt(self.chromeHeightPx()),
                .tab_w = 0,
                .sep_w = 0,
                .underline_h = 0,
                .hover_inset = @round(ui_metrics.tabGapPx(self.scale).control_hover_inset),
                .tab_count = 0,
                .active_idx = 0,
                .scroll_x = 0,
                .drag = null,
                .layout = overlay_layout,
                .hover = tab_hover,
                .palette = &self.chrome,
            };
            var overlay_rects: [tab_chrome.maxRects(0)]tab_chrome.Rect = undefined;
            for (tab_chrome.buildControlsOnly(&overlay_rects, overlay_in)) |r| {
                fillChromeRect(memory, width, height, stride, r);
            }
            drawTabBarControlIcons(
                memory,
                width,
                height,
                stride,
                self.chromeHeightPx(),
                overlay_layout,
                self.scale,
                &self.chrome,
            );
        }

        if (menu_ui.open) self.drawCommandMenu(memory, width, height, stride, menu_ui, toggle_hotkey);

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

    fn drawCommandMenu(self: *Renderer, memory: []u8, width: i32, height: i32, stride: i32, ui: command_menu.Ui, toggle_hotkey: []const u8) void {
        const scale = self.scale;
        // #329 — viewport 높이에 맞춰 entry 단위로 자른 View. 안 보이는 entry
        // 는 그리지 않는다 (부분 행 없음 — scroll 은 first_visible 로).
        const v = command_menu.view(
            @as(f32, @floatFromInt(width)) / scale,
            @as(f32, @floatFromInt(height)) / scale,
            @floatFromInt(ui_metrics.TAB_BAR_HEIGHT_PT),
            ui.first_visible,
        );
        const mx: i32 = @intFromFloat(@round(v.rect.x * scale));
        const mw: i32 = @intFromFloat(@round(v.rect.w * scale));
        const bg = rgbFromMetrics(self.chrome.tab_bar_bg);
        const fg = rgbFromMetrics(self.chrome.menu_label);
        const hint_fg = rgbFromMetrics(self.chrome.menu_hint);

        // #343 단계 3 — 메뉴 배경 · 강조 박스 · 항목 구분선의 rect 와 그 순서는
        // 공통 `command_menu.rects` 한 곳이 만든다. 여기 남은 것은 텍스트와 스크롤
        // 표시 아이콘 (이 renderer 고유) 뿐이다.
        var menu_rects: [command_menu.MAX_RECTS]tab_chrome.Rect = undefined;
        for (command_menu.rects(&menu_rects, v, ui, scale, &self.chrome)) |r| {
            fillChromeRect(memory, width, height, stride, r);
        }

        // #334 — 잘림 상태의 상/하단 스크롤 표시 행 (탭바 `<`/`>` 관례:
        // 끝에 닿으면 비활성 색, 클릭 = 한 entry 스크롤).
        if (v.clipped) {
            const ind_size_i: i32 = scaledPt(ui_metrics.MENU_INDICATOR_ICON_PT, scale);
            const ind_size: u32 = @intCast(@max(1, @min(@as(i32, @intCast(tab_icons.MAX_SIZE)), ind_size_i)));
            const ind_stroke: f32 = ui_metrics.strokePx(ui_metrics.TAB_ICON_STROKE_PT, scale);
            const active_fg = rgbFromMetrics(self.chrome.ctrl_active);
            const disabled_fg = rgbFromMetrics(self.chrome.arrow_disabled);
            const sz_i: i32 = @intCast(ind_size);
            const ind_cx: i32 = mx + @divTrunc(mw - sz_i, 2);
            const up_y: i32 = @intFromFloat(@round((v.rect.y + command_menu.PADDING_PT + command_menu.INDICATOR_HEIGHT_PT * 0.5) * scale - @as(f32, @floatFromInt(sz_i)) * 0.5));
            const down_y: i32 = @intFromFloat(@round((v.rect.y + v.rect.h - command_menu.PADDING_PT - command_menu.INDICATOR_HEIGHT_PT * 0.5) * scale - @as(f32, @floatFromInt(sz_i)) * 0.5));
            const pairs = [2]struct { kind: tab_icons.Icon, y: i32, enabled: bool }{
                .{ .kind = .chevron_up, .y = up_y, .enabled = v.can_scroll_up },
                .{ .kind = .chevron_down, .y = down_y, .enabled = v.can_scroll_down },
            };
            var cov: [tab_icons.MAX_SIZE * tab_icons.MAX_SIZE]u8 = undefined;
            for (pairs) |p| {
                tab_icons.rasterize(p.kind, ind_size, ind_stroke, &cov);
                const fg_ind = if (p.enabled) active_fg else disabled_fg;
                var row: u32 = 0;
                while (row < ind_size) : (row += 1) {
                    var col: u32 = 0;
                    while (col < ind_size) : (col += 1) {
                        const alpha = cov[row * ind_size + col];
                        if (alpha == 0) continue;
                        const px = ind_cx + @as(i32, @intCast(col));
                        const py = p.y + @as(i32, @intCast(row));
                        if (px < 0 or py < 0 or px >= width or py >= height) continue;
                        const off: usize = @intCast(py * stride + px * 4);
                        std.mem.writeInt(u32, memory[off..][0..4], blendPixel(fg_ind, bg, alpha), .little);
                    }
                }
            }
        }

        const cw: i32 = @intCast(self.tab_font_ctx.cell_width_px);
        const ch: i32 = @intCast(self.tab_font_ctx.cell_height_px);
        for (v.first..v.first + v.count) |i| {
            const command = command_menu.entries[i] orelse continue; // 구분선은 위에서
            const item = command_menu.entryRect(v, i).?;
            const ix: i32 = @intFromFloat(@round(item.x * scale));
            const iy: i32 = @intFromFloat(@round(item.y * scale));
            const iw: i32 = @intFromFloat(@round(item.w * scale));
            const ih: i32 = @intFromFloat(@round(item.h * scale));
            const baseline = iy + @divFloor(ih - ch, 2) + @as(i32, @intCast(self.tab_font_ctx.ascent_px));
            const label = command_menu.label(command);
            self.drawDialogTextLine(&self.tab_font_ctx, memory, width, height, stride, ix + scaledPt(8, scale), baseline, label, fg, bg);
            const hint = command_menu.shortcut(command, false, toggle_hotkey, ui.fullscreen_workarea);
            if (hint.len > 0) {
                const hint_w = @as(i32, @intCast(display_width.stringWidth(hint))) * cw;
                const label_w = @as(i32, @intCast(display_width.stringWidth(label))) * cw;
                // #329 — 좁은 메뉴 / 긴 configured hotkey 에서 label 과 겹치면
                // hint 를 먼저 숨긴다 (label 우선 정책, 세 renderer 공통).
                if (command_menu.hintFits(item.w, @as(f32, @floatFromInt(label_w)) / scale, @as(f32, @floatFromInt(hint_w)) / scale)) {
                    self.drawDialogTextLine(&self.tab_font_ctx, memory, width, height, stride, ix + iw - scaledPt(8, scale) - hint_w, baseline, hint, hint_fg, bg);
                }
            }
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
        wrap_cells: usize,
        message_rows: usize,
        visible_message_rows: usize,
        message_scroll_row: usize,
        show_icon: bool,
    ) void {
        const cw: i32 = @intCast(self.dialog_font_ctx.cell_width_px);
        const ch: i32 = @intCast(self.dialog_font_ctx.cell_height_px);
        const ascent: i32 = @intCast(self.dialog_font_ctx.ascent_px);
        const title_ch: i32 = @intCast(self.dialog_title_font_ctx.cell_height_px);
        const title_ascent: i32 = @intCast(self.dialog_title_font_ctx.ascent_px);
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
        self.drawDialogTextLine(&self.dialog_title_font_ctx, memory, buffer_w, buffer_h, stride, text_x, text_y + title_ascent, title, fg, bg);
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
        var wl = dialog_layout.WrappedLines{ .msg = message, .max_cells = wrap_cells };
        while (wl.next()) |line| {
            if (row >= message_scroll_row and drawn_rows < visible_message_rows) {
                self.drawDialogTextLine(&self.dialog_font_ctx, memory, buffer_w, buffer_h, stride, text_x, text_y + ascent, line, fg, bg);
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
                const thumb_y: i32 = @intFromFloat(t.top);
                const thumb_h: i32 = @intFromFloat(t.h);
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
                self.drawDialogTextLine(&self.dialog_font_ctx, memory, buffer_w, buffer_h, stride, input_x, field_y + @divTrunc(field_h - ch, 2) + ascent, input, fg, bg);
            }
            text_y += field_h + @divTrunc(ch, 2);
        }
        if (prompt_status) |status| {
            if (status.len > 0) {
                self.drawDialogTextLine(&self.dialog_font_ctx, memory, buffer_w, buffer_h, stride, text_x, text_y + ascent, status, .{ .r = 190, .g = 45, .b = 45 }, bg);
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
        const ok_text_cells = display_width.stringWidth(ok_text);
        const ok_text_w: i32 = @intCast(ok_text_cells * @as(usize, @intCast(cw)));
        const ok_text_x: i32 = ok_x + @divTrunc(button_w - ok_text_w, 2);
        const button_text_y: i32 = button_y + @divTrunc(button_h - ch, 2) + ascent;
        self.drawDialogTextLine(&self.dialog_font_ctx, memory, buffer_w, buffer_h, stride, ok_text_x, button_text_y, ok_text, ok_fg, ok_bg);

        // Cancel 버튼 — confirm 모드 에서만. secondary action (회색 배경 + 검정).
        if (is_confirm) {
            const cancel_x: i32 = group_x;
            self.last_dialog_cancel_rect = .{ .x = cancel_x, .y = button_y, .w = button_w, .h = button_h };
            fillRoundedRect(memory, buffer_w, buffer_h, stride, cancel_x, button_y, button_w, button_h, button_r, dialog_cancel_color);
            const cancel_text = messages.button_cancel;
            const cancel_text_cells = display_width.stringWidth(cancel_text);
            const cancel_text_w: i32 = @intCast(cancel_text_cells * @as(usize, @intCast(cw)));
            const cancel_text_x: i32 = cancel_x + @divTrunc(button_w - cancel_text_w, 2);
            self.drawDialogTextLine(&self.dialog_font_ctx, memory, buffer_w, buffer_h, stride, cancel_text_x, button_text_y, cancel_text, dialog_cancel_text_color, dialog_cancel_color);
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
        return dialog_layout.compute(title, message, kind, self.dialogLayoutMetrics(), .{
            .w = viewport_w,
            .h = viewport_h,
        });
    }

    pub fn computeDialogLayoutForSurface(
        self: *const Renderer,
        title: []const u8,
        message: []const u8,
        kind: dialog_layout.Kind,
        surface_w: i32,
        surface_h: i32,
    ) dialog_layout.Layout {
        return dialog_layout.computeForSurface(title, message, kind, self.dialogLayoutMetrics(), .{
            .w = surface_w,
            .h = surface_h,
        });
    }

    fn dialogLayoutMetrics(self: *const Renderer) dialog_layout.Metrics {
        return .{
            .body_cell_w = @intCast(self.dialog_font_ctx.cell_width_px),
            .body_cell_h = @intCast(self.dialog_font_ctx.cell_height_px),
            .title_cell_w = @intCast(self.dialog_title_font_ctx.cell_width_px),
            .title_cell_h = @intCast(self.dialog_title_font_ctx.cell_height_px),
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
        fg: ghostty.color.RGB,
        bg: ghostty.color.RGB,
    ) void {
        _ = self;
        const cw: i32 = @intCast(font_ctx.cell_width_px);
        const ch_metric: i32 = @intCast(font_ctx.cell_height_px);
        var x: i32 = start_x;
        var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (iter.nextCodepoint()) |cp| {
            if (x >= fb_w) break;
            const cells = display_width.codepointWidth(@intCast(cp));
            const adv: i32 = cw * @as(i32, @intCast(cells));
            const gl = font_ctx.glyph(cp);
            if (gl.pixel_mode == freetype.FT_PIXEL_MODE_BGRA) {
                drawGlyphBgra(memory, fb_w, fb_h, stride, x, baseline_y - ch_metric, adv, ch_metric, gl);
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
                    bg,
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
fn drawTabBar(
    memory: []u8,
    fb_w: i32,
    fb_h: i32,
    stride: i32,
    tab_bar_h: i32,
    tab_w: i32,
    tab_pad: i32,
    titles: []const []const u8,
    active_idx: usize,
    layout: tab_layout.Layout,
    tab_hover: tab_layout.Area,
    scroll_x: f32,
    drag_view: ?tab_interaction.DragView,
    scale: f32,
    font_ctx: *font.Context,
    /// #335 — theme 배경에서 파생한 chrome 색 (`Renderer.chrome`).
    chrome: *const chrome_palette.Palette,
) void {
    if (tab_bar_h <= 0 or fb_w <= 0 or titles.len == 0) return;
    const tab_bar_bg = rgbFromMetrics(chrome.tab_bar_bg);

    // #343 — rect 목록과 그 순서는 공통 `tab_chrome` 이 만든다. 여기서는 그것을
    // 정수로 스냅해 그리고, 사이사이에 이 renderer 고유인 텍스트 / 아이콘을 끼운다.
    //
    // 넘기는 metric 은 **이 renderer 가 쓰던 값 그대로**다 (`scaledPt` 로 이미
    // 반올림된 정수). f32 renderer 는 소수를 그대로 넘긴다 — 모듈은 단위에
    // 관여하지 않고 받은 값으로 rect 를 만든다. 입력 metric 자체의 정수/소수
    // 갈래는 별 항목이다 (#343 코멘트).
    // #357 — 선 두께는 공통 `ui_metrics.linePx` 한 곳에서 정수 px 로 온다. 이전에는
    // 여기서만 정수로 반올림하고 mac/win 은 소수 `strokePx` 를 넘겨 값이 갈렸다
    // (배율 1.0 · 1.7 에서는 결과가 같아 #343 단계 1 검증에 안 걸렸다).
    const underline_line = ui_metrics.linePx(ui_metrics.TAB_ACTIVE_UNDERLINE_PT, scale);
    const sep_w_line = ui_metrics.linePx(ui_metrics.TAB_SEPARATOR_W_PT, scale);
    const hover_inset_px: i32 = @intFromFloat(@round(ui_metrics.tabGapPx(scale).control_hover_inset));
    const chrome_in = tab_chrome.Inputs{
        .viewport_w = @floatFromInt(fb_w),
        .tab_bar_h = @floatFromInt(tab_bar_h),
        .tab_w = @floatFromInt(tab_w),
        .sep_w = sep_w_line,
        .underline_h = underline_line,
        .hover_inset = @floatFromInt(hover_inset_px),
        .tab_count = titles.len,
        .active_idx = active_idx,
        .scroll_x = scroll_x,
        .drag = drag_view,
        .layout = layout,
        .hover = tab_hover,
        .palette = chrome,
    };
    var chrome_rects: [tab_chrome.maxRects(session_core.MAX_TABS)]tab_chrome.Rect = undefined;
    const built = tab_chrome.build(&chrome_rects, chrome_in);
    for (built.rects[0..built.before_titles]) |r| fillChromeRect(memory, fb_w, fb_h, stride, r);

    // #342 — 탭바-터미널 가로 경계선은 제거됐다 (2026-07-27 사용자 결정).
    // 탭바와 terminal 의 경계는 배경색 차이만으로 둔다.
    const text_color = rgbFromMetrics(chrome.tab_text);
    const ascent: i32 = @intCast(font_ctx.ascent_px);
    const descent: i32 = @intCast(font_ctx.descent_px);
    const text_baseline: i32 = @divFloor(tab_bar_h + ascent - descent, 2);

    const tab_gap = ui_metrics.tabGapPx(scale);
    const tab_x_inset: i32 = @intFromFloat(@round(tab_gap.tab_horizontal_inset));
    const cell_w: i32 = @intCast(font_ctx.cell_width_px);
    // max_text_w — #268 per-tab close 제거로 탭 전체 (양쪽 padding 제외).
    // mac `tab_w - tab_pad_px * 2` 동등.
    const max_text_w_metric: i32 = tab_w - tab_pad * 2;
    const tab_area_x: i32 = @intFromFloat(layout.tab_area_x);
    const tab_area_w: i32 = @intFromFloat(layout.tab_area_w);
    const tab_area_end: i32 = tab_area_x + tab_area_w;

    // --- 각 탭의 제목 (tab_area 안에서 clipping) ---
    // #343 — 탭 배경 · amber 밑줄은 `tab_chrome` 이 위에서 이미 그렸다. 여기 남은
    // 것은 이 renderer 고유인 glyph 그리기뿐이다. 탭 x 와 화면 밖 판정도 공통
    // 모듈(`tabX` / `tabClip`) 을 쓴다 — 밑줄과 제목이 어긋나지 않게 한다.
    for (titles, 0..) |title, i| {
        const tab_screen_x: i32 = @intFromFloat(tab_chrome.tabX(i, chrome_in));
        switch (tab_chrome.tabClip(
            @floatFromInt(tab_screen_x),
            @floatFromInt(tab_w),
            @floatFromInt(tab_area_x),
            @floatFromInt(tab_area_end),
            drag_view != null,
        )) {
            .skip => continue,
            .stop => break,
            .draw => {},
        }

        const tab_x: i32 = tab_screen_x + tab_x_inset;
        // #334 (2026-07-22 개편) — 탭 배경은 탭바와 같은 색이라 따로 그리지
        // 않는다 (Tilda 문법). 글리프 알파 블렌드 배경도 tab_bar_bg.
        const bg = tab_bar_bg;

        // L12-γ-2/3 — title text 그리기를 cross-platform `tab_layout.
        // iterTabText` 로 — truncate ellipsis 자동. mac / win renderer 의
        // 호출 패턴과 인자 / cb 모두 동등.
        const text_x_start: i32 = tab_x + tab_pad;
        const cw_f: f32 = @floatFromInt(cell_w);
        const max_text_w_f: f32 = @floatFromInt(max_text_w_metric);

        // mac/win 동등 — 짧은 title 은 truncate 안 함 (ellipsis 안 그림).
        const total_text_w_f: f32 = @as(f32, @floatFromInt(display_width.stringWidth(title))) * cw_f;
        const needs_truncate = total_text_w_f > max_text_w_f;

        const TextCtx = struct {
            memory: []u8,
            fb_w: i32,
            fb_h: i32,
            stride: i32,
            viewport_left: i32,
            tab_area_end: i32,
            tab_bar_h: i32,
            text_baseline: i32,
            bg: ghostty.color.RGB,
            text_color: ghostty.color.RGB,
            font_ctx: *font.Context,
        };
        const ctx = TextCtx{
            .memory = memory,
            .fb_w = fb_w,
            .fb_h = fb_h,
            .stride = stride,
            // L12-γ scroll 잘림 fix — 부분 잘린 첫 보이는 탭은 `text_x_start`
            // 가 `tab_area_x` 보다 왼쪽으로 음수 가능 → glyph clip 검사
            // (`px < viewport_left`) 가 무효화되어 화살표 영역 invade. mac
            // 은 Metal scissor / NSView bounds 가 추가 clip 해서 발현 안
            // 함. software 는 수동 max clamp.
            .viewport_left = @max(text_x_start, tab_area_x),
            .tab_area_end = tab_area_end,
            .tab_bar_h = tab_bar_h,
            .text_baseline = text_baseline,
            .bg = bg,
            .text_color = text_color,
            .font_ctx = font_ctx,
        };

        const cb_fn = struct {
            fn emit(c: TextCtx, g: tab_layout.Glyph) void {
                // mac / win 동등 — glyph 만 viewport_left 검사 (scroll
                // 좌측 잘림 영역 skip).
                const px: i32 = @intFromFloat(g.x);
                if (px < c.viewport_left) return;
                if (px >= c.tab_area_end) return;
                const gl = c.font_ctx.glyph(g.cp);
                if (gl.pixel_mode == freetype.FT_PIXEL_MODE_BGRA) {
                    const adv: i32 = @intFromFloat(g.advance);
                    drawGlyphBgra(c.memory, c.fb_w, c.fb_h, c.stride, px, 0, adv, c.tab_bar_h, gl);
                } else {
                    drawGlyph(
                        c.memory,
                        c.fb_w,
                        c.fb_h,
                        c.stride,
                        px + gl.bitmap_left,
                        c.text_baseline - gl.bitmap_top,
                        gl,
                        c.text_color,
                        c.bg,
                    );
                }
            }
        }.emit;

        tab_layout.iterTabText(
            title,
            @floatFromInt(text_x_start),
            cw_f,
            max_text_w_f,
            needs_truncate,
            ctx,
            cb_fn,
        );
    }

    // #343 — 제목 뒤 구간: 컨트롤 bg fill → hover 박스 → 세로 구분선. 순서와
    // 지오메트리는 `tab_chrome` 이 정한다 (세 renderer 정본 순서).
    for (built.rects[built.before_titles..]) |r| fillChromeRect(memory, fb_w, fb_h, stride, r);
    // 아이콘은 이 renderer 고유 (알파 커버리지 비트맵을 직접 blit) — 마지막.
    drawTabBarControlIcons(memory, fb_w, fb_h, stride, tab_bar_h, layout, scale, chrome);
}

/// #343 — `tab_chrome.Rect` (f32) 를 정수 격자에 스냅해 그린다. 스냅 규칙은
/// `tab_chrome.snap` 한 곳에만 있다 (#344 의 `scrollbar.thumbPx` 와 같은 계약).
fn fillChromeRect(memory: []u8, fb_w: i32, fb_h: i32, stride: i32, r: tab_chrome.Rect) void {
    const i = tab_chrome.snap(r);
    rect(memory, fb_w, fb_h, stride, i.x, i.y, i.w, i.h, rgbFromMetrics(r.color));
}

/// `<` / `>` / `×` / `+` / `…` **아이콘** 그리기. 컨트롤 bg fill 과 hover 박스는
/// #343 이후 공통 `tab_chrome` 이 rect 로 만들고 호출처가 이 함수 **직전에** 그린다
/// — 여기 남은 것은 알파 커버리지 비트맵 blit (이 renderer 고유) 뿐이다.
fn drawTabBarControlIcons(
    memory: []u8,
    fb_w: i32,
    fb_h: i32,
    stride: i32,
    tab_bar_h: i32,
    layout: tab_layout.Layout,
    scale: f32,
    /// #335 — theme 배경에서 파생한 chrome 색 (`Renderer.chrome`).
    chrome: *const chrome_palette.Palette,
) void {
    // 아이콘 알파를 섞을 배경 — 바로 앞 layer 인 컨트롤 bg fill 과 같은 색.
    const bg = rgbFromMetrics(chrome.tab_bar_bg);
    // mac / win 동등 — enabled = `ctrl_active` (밝은 흰색), disabled =
    // `arrow_disabled` (회색). scroll 왼쪽 끝이면 `<` 회색, 우측 끝이면 `>` 회색.
    // `+` 는 MAX_TABS 도달 시 회색 (#329).
    const active_color = rgbFromMetrics(chrome.ctrl_active);
    const disabled_color = rgbFromMetrics(chrome.arrow_disabled);

    // #268 직접 그리기 — 아이콘 (`< > × +`) 을 `tab_icons` 공통 rasterizer 로
    // 알파 커버리지 비트맵으로 만든 뒤 box 중앙에 blit (폰트 독립). mac/win 은
    // 같은 비트맵을 atlas 에 올려 그림 → 세 platform 픽셀 동일.
    const icon_size_i: i32 = scaledPt(ui_metrics.TAB_ICON_SIZE_PT, scale);
    const icon_size: u32 = @intCast(@max(1, @min(@as(i32, @intCast(tab_icons.MAX_SIZE)), icon_size_i)));
    const stroke_px: f32 = ui_metrics.strokePx(ui_metrics.TAB_ICON_STROKE_PT, scale);
    const more_stroke_px: f32 = ui_metrics.strokePx(ui_metrics.TAB_MORE_DOT_DIAMETER_PT, scale);

    const drawIcon = struct {
        fn call(
            mem: []u8,
            w: i32,
            h: i32,
            s: i32,
            icon: tab_icons.Icon,
            x_left: i32,
            box_w: i32,
            bar_h: i32,
            sz: u32,
            stroke: f32,
            fg: ghostty.color.RGB,
            bg_color: ghostty.color.RGB,
        ) void {
            var cov: [tab_icons.MAX_SIZE * tab_icons.MAX_SIZE]u8 = undefined;
            tab_icons.rasterize(icon, sz, stroke, &cov);
            const sz_i: i32 = @intCast(sz);
            const draw_x: i32 = x_left + @divFloor(box_w - sz_i, 2);
            const draw_y: i32 = @divFloor(bar_h - sz_i, 2);
            var row: u32 = 0;
            while (row < sz) : (row += 1) {
                var col: u32 = 0;
                while (col < sz) : (col += 1) {
                    const alpha = cov[row * sz + col];
                    if (alpha == 0) continue;
                    const px = draw_x + @as(i32, @intCast(col));
                    const py = draw_y + @as(i32, @intCast(row));
                    if (px < 0 or py < 0 or px >= w or py >= h) continue;
                    const off: usize = @intCast(py * s + px * 4);
                    std.mem.writeInt(u32, mem[off..][0..4], blendPixel(fg, bg_color, alpha), .little);
                }
            }
        }
    }.call;

    if (layout.arrows_visible) {
        const left_x: i32 = @intFromFloat(layout.left_arrow_x);
        const right_x: i32 = @intFromFloat(layout.right_arrow_x);
        const arrow_w: i32 = @intFromFloat(layout.arrow_w);
        const left_color = if (layout.left_enabled) active_color else disabled_color;
        const right_color = if (layout.right_enabled) active_color else disabled_color;
        drawIcon(memory, fb_w, fb_h, stride, .chevron_left, left_x, arrow_w, tab_bar_h, icon_size, stroke_px, left_color, bg);
        drawIcon(memory, fb_w, fb_h, stride, .chevron_right, right_x, arrow_w, tab_bar_h, icon_size, stroke_px, right_color, bg);
    }
    const plus_x: i32 = @intFromFloat(layout.plus_x);
    const plus_w: i32 = @intFromFloat(layout.plus_w);
    // #329 — MAX_TABS 도달 시 `+` 는 자리 유지 + 비활성 색 (arrow 동일 관례).
    const plus_color = if (layout.plus_enabled) active_color else disabled_color;
    drawIcon(memory, fb_w, fb_h, stride, .plus, plus_x, plus_w, tab_bar_h, icon_size, stroke_px, plus_color, bg);
    // #268 — 우측 끝 활성 탭 닫기 버튼. `×` 아이콘을 tab_icons 로 직접 그림.
    const close_x: i32 = @intFromFloat(layout.close_x);
    const close_w: i32 = @intFromFloat(layout.close_w);
    drawIcon(memory, fb_w, fb_h, stride, .close, close_x, close_w, tab_bar_h, icon_size, stroke_px, active_color, bg);
    const more_x: i32 = @intFromFloat(layout.more_x);
    const more_w: i32 = @intFromFloat(layout.more_w);
    drawIcon(memory, fb_w, fb_h, stride, .more, more_x, more_w, tab_bar_h, icon_size, more_stroke_px, active_color, bg);
}

// #353 — 알파 합성 전용이었던 `blendU8` 은 제거했다. 규칙(f32 곱 + 버림)이
// macOS·Windows 의 renderer 합성과 갈렸고, 합성 자체를 공통
// `ui_metrics.blendOverU8` 한 곳으로 모았다. 유일한 호출처였던 scrollbar thumb 은
// 이제 `ui_metrics.scrollbarColor` 가 합성한 색을 그대로 그린다.

fn rgbFromMetrics(c: [4]f32) ghostty.color.RGB {
    return .{
        .r = @intFromFloat(@max(0.0, @min(255.0, c[0] * 255.0))),
        .g = @intFromFloat(@max(0.0, @min(255.0, c[1] * 255.0))),
        .b = @intFromFloat(@max(0.0, @min(255.0, c[2] * 255.0))),
    };
}

/// L10-β preedit overlay — cursor 위치부터 UTF-8 codepoint 별로 cell 너비
/// (display_width.codepointWidth) 만큼 보라색 배경 + foreground 글자. wide
/// char (한글 등) 는 2 cell. 가로 cols 넘어가면 truncate (wrap 안 함 — 다음
/// done event 가 새 preedit 보내주면 갱신).
fn drawPreeditOverlay(
    memory: []u8,
    fb_w: i32,
    fb_h: i32,
    stride: i32,
    pad: i32,
    tab_bar_h: i32,
    cw: i32,
    ch: i32,
    ascent: i32,
    start_col: i32,
    cy_cell: i32,
    cols: usize,
    text: []const u8,
    fg: ghostty.color.RGB,
    font_ctx: *font.Context,
) void {
    // 보라색 배경 — macOS Metal `pre_bg_color = .{0.25, 0.25, 0.5, 1}` 와
    // 동일 색. 8-bit RGB 환산 64 / 64 / 128.
    const preedit_bg = ghostty.color.RGB{ .r = 64, .g = 64, .b = 128 };
    const pre_y: i32 = tab_bar_h + pad + cy_cell * ch;
    const baseline: i32 = pre_y + ascent;

    var col: i32 = start_col;
    var utf8_iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (utf8_iter.nextCodepoint()) |cp| {
        const w_cells: i32 = @intCast(display_width.codepointWidth(cp));
        if (w_cells <= 0) continue;
        if (col + w_cells > @as(i32, @intCast(cols))) break;

        const cell_x: i32 = pad + col * cw;
        const cell_w: i32 = w_cells * cw;
        rect(memory, fb_w, fb_h, stride, cell_x, pre_y, cell_w, ch, preedit_bg);

        const glyph = font_ctx.glyph(cp);
        if (glyph.pixel_mode == freetype.FT_PIXEL_MODE_BGRA) {
            // emoji 가 preedit 으로 올 일 거의 없지만 안전하게 동일 path 분기.
            drawGlyphBgra(memory, fb_w, fb_h, stride, cell_x, pre_y, cell_w, ch, glyph);
        } else {
            const glyph_advance_i32: i32 = @intCast(glyph.advance);
            const center_off: i32 = @divFloor(cell_w - glyph_advance_i32, 2);
            drawGlyph(
                memory,
                fb_w,
                fb_h,
                stride,
                cell_x + center_off + glyph.bitmap_left,
                baseline - glyph.bitmap_top,
                glyph,
                fg,
                preedit_bg,
            );
        }

        col += w_cells;
    }
}

/// 2-cell 또는 3-cell ligature 의 단일 그리기 경로. `LigatureMatch` 의
/// `.single` (입력 N chars → 1 glyph, N-cell wide draw, JetBrains Mono /
/// Cascadia Code 패턴) 과 `.spacer` (입력 N chars → N glyphs each at own
/// cell, Fira Code 패턴) 둘 다 처리. caller 는 `x` (base cell index) +
/// `count` (2 또는 3) + `match` 만 전달.
///
/// 둘 다 다음 N-1 cells 의 bg/selection rect 는 *spacer 의 경우* 본 함수가
/// 그림 (per-cell width=cw); .single 의 경우는 caller 가 base bg 그렸으니
/// 추가 N-1 cells 도 그림. `cell_x` (= `pad + x * cw`) 는 함수 안 재계산.
fn drawLigatureMatch(
    font_ctx: *font.Context,
    memory: []u8,
    fb_w: i32,
    fb_h: i32,
    stride: i32,
    raws: []const ghostty.Cell,
    styles: []const ghostty.Style,
    sel_range: ?[2]u16,
    colors: *const ghostty.RenderState.Colors,
    pad: i32,
    cell_y: i32,
    cw: i32,
    ch: i32,
    ascent: i32,
    x: usize,
    count: usize,
    match: font.LigatureMatch,
    fg: ghostty.color.RGB,
    bg: ghostty.color.RGB,
) void {
    const base_cell_x: i32 = pad + @as(i32, @intCast(x)) * cw;

    // 다음 (count-1) cells 의 selection / bg 그리기 — 둘 다 (.single / .spacer)
    // 공통. base cell 의 bg 는 caller 가 이미 그림.
    for (1..count) |off| {
        const ox = x + off;
        if (ox >= raws.len) break;
        const ocell = raws[ox];
        const ostyle = if (ocell.style_id != 0) styles[ox] else ghostty.Style{};
        const ox16: u16 = @intCast(ox);
        const ois_selected = if (sel_range) |sr| (ox16 >= sr[0] and ox16 <= sr[1]) else false;
        const obg = resolveBg(ostyle, &ocell, colors, ois_selected);
        const ocell_x: i32 = pad + @as(i32, @intCast(ox)) * cw;
        if (ois_selected or ostyle.flags.inverse or ostyle.bg(&ocell, &colors.palette) != null) {
            rect(memory, fb_w, fb_h, stride, ocell_x, cell_y, cw, ch, obg);
        }
    }

    switch (match) {
        .single => |lg| {
            // 1 glyph 이 N-cell 너비 차지 — center 정렬 (count × cw 안).
            const ligature_glyph = font_ctx.glyphByIndex(lg.face_idx, lg.glyph_index);
            const ligature_w: i32 = @intCast(count * @as(usize, @intCast(cw)));
            if (ligature_glyph.pixel_mode == freetype.FT_PIXEL_MODE_BGRA) {
                drawGlyphBgra(memory, fb_w, fb_h, stride, base_cell_x, cell_y, ligature_w, ch, ligature_glyph);
            } else {
                const baseline = cell_y + ascent;
                const glyph_advance_i32: i32 = @intCast(ligature_glyph.advance);
                const center_off: i32 = @divFloor(ligature_w - glyph_advance_i32, 2);
                drawGlyph(
                    memory,
                    fb_w,
                    fb_h,
                    stride,
                    base_cell_x + center_off + ligature_glyph.bitmap_left + lg.x_offset,
                    baseline - ligature_glyph.bitmap_top - lg.y_offset,
                    ligature_glyph,
                    fg,
                    bg,
                );
            }
        },
        .spacer => |sp| {
            // N glyph 을 각 cell 에 (1-cell wide each). Fira Code 의 spacer pattern.
            const n = @min(@as(usize, sp.count), count);
            for (0..n) |i| {
                const gx_cell: i32 = pad + @as(i32, @intCast(x + i)) * cw;
                const g_glyph = font_ctx.glyphByIndex(sp.face_idx, sp.glyph_indices[i]);
                if (g_glyph.pixel_mode == freetype.FT_PIXEL_MODE_BGRA) {
                    drawGlyphBgra(memory, fb_w, fb_h, stride, gx_cell, cell_y, cw, ch, g_glyph);
                } else {
                    const baseline = cell_y + ascent;
                    const glyph_advance_i32: i32 = @intCast(g_glyph.advance);
                    const center_off: i32 = @divFloor(cw - glyph_advance_i32, 2);
                    drawGlyph(
                        memory,
                        fb_w,
                        fb_h,
                        stride,
                        gx_cell + center_off + g_glyph.bitmap_left + sp.x_offsets[i],
                        baseline - g_glyph.bitmap_top - sp.y_offsets[i],
                        g_glyph,
                        fg,
                        bg,
                    );
                }
            }
        },
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
                const br: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(color.r)) * coverage + er * inv));
                const bg_: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(color.g)) * coverage + eg * inv));
                const bb: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(color.b)) * coverage + eb * inv));
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

    const min_x: i32 = @intFromFloat(@floor(@min(x1, x2) - half_t - 1.0));
    const max_x: i32 = @intFromFloat(@ceil(@max(x1, x2) + half_t + 1.0));
    const min_y: i32 = @intFromFloat(@floor(@min(y1, y2) - half_t - 1.0));
    const max_y: i32 = @intFromFloat(@ceil(@max(y1, y2) + half_t + 1.0));

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
                const br: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(color.r)) * coverage + er * inv));
                const bg_: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(color.g)) * coverage + eg * inv));
                const bb: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(color.b)) * coverage + eb * inv));
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
            return @intFromFloat(@round(vb * s));
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
                memory[off + 2] = @intFromFloat(@round(r0 * rgb_keep));
                memory[off + 1] = @intFromFloat(@round(g0 * rgb_keep));
                memory[off + 0] = @intFromFloat(@round(b0 * rgb_keep));
            }

            memory[off + 3] = @intFromFloat(@round(total_alpha));
        }
    }
}

/// 8bpp alpha bitmap 을 fg/bg 알파 블렌딩으로 XRGB8888 buffer 에 그린다.
/// glyph buffer 가 비어 있거나 (space) 좌표가 화면 밖이면 무시.
fn drawGlyph(
    memory: []u8,
    width: i32,
    height: i32,
    stride: i32,
    draw_x: i32,
    draw_y: i32,
    glyph: *const font.Glyph,
    fg: ghostty.color.RGB,
    bg: ghostty.color.RGB,
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
            if (px < 0 or py < 0 or px >= width or py >= height) continue;
            const off: usize = @intCast(py * stride + px * 4);
            const blended = blendPixel(fg, bg, alpha);
            std.mem.writeInt(u32, memory[off..][0..4], blended, .little);
        }
    }
}

/// FT_PIXEL_MODE_BGRA bitmap (premultiplied alpha) 를 cell 안 ratio 유지 scale +
/// center fit + alpha 블렌딩으로 XRGB8888 buffer 에 그린다. emoji 색 자체 사용
/// (fg 무시). nearest neighbor sampling — 작은 cell 에 큰 emoji bitmap (보통
/// strike 109px) 가 들어갈 때 quality 보다 단순성 우선.
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
) void {
    if (glyph.width == 0 or glyph.height == 0 or glyph.bitmap.len == 0) return;
    if (cell_w <= 0 or cell_h <= 0) return;

    const gw_f: f64 = @floatFromInt(glyph.width);
    const gh_f: f64 = @floatFromInt(glyph.height);
    const cw_f: f64 = @floatFromInt(cell_w);
    const ch_f: f64 = @floatFromInt(cell_h);
    const scale: f64 = @min(cw_f / gw_f, ch_f / gh_f);
    const target_w: i32 = @intFromFloat(gw_f * scale);
    const target_h: i32 = @intFromFloat(gh_f * scale);
    if (target_w <= 0 or target_h <= 0) return;
    const off_x: i32 = @divFloor(cell_w - target_w, 2);
    const off_y: i32 = @divFloor(cell_h - target_h, 2);

    var dy: i32 = 0;
    while (dy < target_h) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < target_w) : (dx += 1) {
            const src_xf: f64 = @as(f64, @floatFromInt(dx)) / scale;
            const src_yf: f64 = @as(f64, @floatFromInt(dy)) / scale;
            const src_x: u32 = @intFromFloat(src_xf);
            const src_y: u32 = @intFromFloat(src_yf);
            if (src_x >= glyph.width or src_y >= glyph.height) continue;
            const src_off: usize = (@as(usize, src_y) * glyph.width + src_x) * 4;
            const b = glyph.bitmap[src_off];
            const g = glyph.bitmap[src_off + 1];
            const r = glyph.bitmap[src_off + 2];
            const a = glyph.bitmap[src_off + 3];
            if (a == 0) continue;

            const px = cell_x + off_x + dx;
            const py = cell_y + off_y + dy;
            if (px < 0 or py < 0 or px >= fb_w or py >= fb_h) continue;

            const dst_off: usize = @intCast(py * stride + px * 4);
            const dst_b = memory[dst_off];
            const dst_g = memory[dst_off + 1];
            const dst_r = memory[dst_off + 2];
            const inv: u32 = 255 - @as(u32, a);
            // premultiplied: out = src + (1 - a) * dst.
            const out_b: u8 = @intCast(@min(@as(u32, 255), @as(u32, b) + (@as(u32, dst_b) * inv) / 255));
            const out_g: u8 = @intCast(@min(@as(u32, 255), @as(u32, g) + (@as(u32, dst_g) * inv) / 255));
            const out_r: u8 = @intCast(@min(@as(u32, 255), @as(u32, r) + (@as(u32, dst_r) * inv) / 255));
            memory[dst_off] = out_b;
            memory[dst_off + 1] = out_g;
            memory[dst_off + 2] = out_r;
        }
    }
}

/// Block element rect (`U+2580..U+2595`) 를 셀 안 fraction → 절대 pixel 좌표로
/// 옮겨 그린다. shade == 0 면 solid fg rect. shade ∈ {1,2,3} 이면 d3d11
/// `bg_shader_src` / macOS Metal `bg_fs` 와 동일 식의 procedural dot mask 적용
/// — 픽셀의 absolute (px, py) 로 패턴을 결정해 인접 셀 사이 끊김 없이 대각
/// zigzag 가 이어진다. dot 픽셀만 fg 색으로 set, 나머지는 이미 그려진 배경
/// 그대로 (셰이더의 `discard` 동등).
fn drawBlockRect(
    memory: []u8,
    fb_w: i32,
    fb_h: i32,
    stride: i32,
    cell_x: i32,
    cell_y: i32,
    cell_w: i32,
    cell_h: i32,
    br: block_element.BlockRect,
    /// **`br.alpha` 를 셀 배경과 이미 합성한 색** (#353). 호출처가 공통
    /// `ui_metrics.blendOverRgb` 로 만든다 — 이 함수는 알파를 다시 적용하지 않는다.
    color: ghostty.color.RGB,
) void {
    const cw_f: f32 = @floatFromInt(cell_w);
    const ch_f: f32 = @floatFromInt(cell_h);
    const x0: i32 = cell_x + @as(i32, @intFromFloat(br.x0 * cw_f));
    const y0: i32 = cell_y + @as(i32, @intFromFloat(br.y0 * ch_f));
    const x1: i32 = cell_x + @as(i32, @intFromFloat(br.x1 * cw_f));
    const y1: i32 = cell_y + @as(i32, @intFromFloat(br.y1 * ch_f));

    if (br.shade < 0.5) {
        // 솔리드/음영 — 합성이 끝난 색이라 불투명 rect 로 그린다 (#353). 이전에는
        // 여기서 `blendRect` 로 `br.alpha` 를 적용했고 그 규칙(알파 8bit 버림 + 정수
        // 버림)이 macOS·Windows 의 renderer 합성과 갈렸다.
        rect(memory, fb_w, fb_h, stride, x0, y0, x1 - x0, y1 - y0, color);
        return;
    }

    const cx0 = @max(0, x0);
    const cy0 = @max(0, y0);
    const cx1 = @min(fb_w, x1);
    const cy1 = @min(fb_h, y1);
    if (cx1 <= cx0 or cy1 <= cy0) return;

    const fg_packed = pack(color);
    var py = cy0;
    while (py < cy1) : (py += 1) {
        var px = cx0;
        while (px < cx1) : (px += 1) {
            const on: bool = if (br.shade < 1.5)
                // U+2591 LIGHT 25% — diagonal sparse
                ((px + 2 * py) & 3) == 0
            else if (br.shade < 2.5)
                // U+2592 MEDIUM 50% — checkerboard
                ((px + py) & 1) == 0
            else
                // U+2593 DARK 75% — LIGHT 의 inverse (diagonal dense)
                ((px + 2 * py) & 3) != 0;
            if (!on) continue;
            const off: usize = @intCast(py * stride + px * 4);
            std.mem.writeInt(u32, memory[off..][0..4], fg_packed, .little);
        }
    }
}

fn pack(color: ghostty.color.RGB) u32 {
    return (@as(u32, color.r) << 16) | (@as(u32, color.g) << 8) | color.b;
}

fn blendPixel(fg: ghostty.color.RGB, bg: ghostty.color.RGB, alpha: u8) u32 {
    const a: u32 = alpha;
    const inv: u32 = 255 - a;
    const r: u32 = (@as(u32, fg.r) * a + @as(u32, bg.r) * inv) / 255;
    const g: u32 = (@as(u32, fg.g) * a + @as(u32, bg.g) * inv) / 255;
    const b: u32 = (@as(u32, fg.b) * a + @as(u32, bg.b) * inv) / 255;
    return (r << 16) | (g << 8) | b;
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
        layout.wrap_cells,
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
        layout.wrap_cells,
        layout.message_rows,
        layout.visible_message_rows,
        0,
        layout.show_icon,
    );
    const ch: i32 = @intCast(r.dialog_font_ctx.cell_height_px);
    const title_ch: i32 = @intCast(r.dialog_title_font_ctx.cell_height_px);
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
        layout.wrap_cells,
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
        layout.wrap_cells,
        layout.message_rows,
        layout.visible_message_rows,
        layout.message_scroll_max,
        layout.show_icon,
    );
    try std.testing.expect(r.last_dialog_scrollbar_thumb_rect.y > first_thumb_y);
}
