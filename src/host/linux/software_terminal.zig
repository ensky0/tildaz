//! Temporary Linux bring-up renderer.
//!
//! Software-only — paints ghostty-vt render state into a Wayland `wl_shm`
//! XRGB8888 buffer. 진짜 GPU renderer (EGL/OpenGL) 로 갈 때까지의 bring-up 코드.
//! Glyph 는 fontconfig + FreeType 으로 raster (ASCII 만 pre-cached, [font/linux/font.zig](../../font/linux/font.zig)).

const std = @import("std");
const ghostty = @import("ghostty-vt");
const themes = @import("../../themes.zig");
const font = @import("../../font/linux/font.zig");
const freetype = @import("../../font/linux/freetype.zig");
const block_element = @import("../../renderer/block_element.zig");
const display_width = @import("../../font/display_width.zig");
const config_mod = @import("../../config.zig");
const ui_metrics = @import("../../ui_metrics.zig");
const tab_layout = @import("../../tab_layout.zig");
const tab_interaction = @import("../../tab_interaction.zig");
const dialog_mod = @import("../../dialog.zig");

const scrollbar_thumb_color = ghostty.color.RGB{ .r = 96, .g = 96, .b = 96 };

/// #203 Phase C step 3.1 — dialog 박스 모서리 radius (physical px). macOS
/// NSAlert / Win 11 dialog 의 ~12-16 범위. fractional scaling 환경 에선 그대로
/// physical px — `applyScale` 후 cell_h 변하지만 radius 는 시각 일정 (≈ 시스템
/// 표준 dialog radius). **PT (논리 점) 단위** — `scaledPt(pt, scale)` 로 physical
/// 변환. fractional scaling (KDE Plasma 6 125% / 170% 등) 환경에서도 일관 시각.
const dialog_corner_radius_pt: u32 = 16;

/// #203 Phase C step 3.2 — drop shadow 너비 (PT, 논리 점). 박스 outer edge 에서
/// 그림자가 fade out 되는 거리. buffer 가 box 보다 4 방향 각 `dialog_shadow_margin`
/// 만큼 큼 — set_size 와 computeDialogSize 모두 합산 포함.
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
/// Confirm dialog 의 Cancel 버튼 색 — macOS secondary action 모양 (회색
/// 배경 + 검정 글자). OK 와 시각 구분.
const dialog_cancel_color: ghostty.color.RGB = .{ .r = 0xD8, .g = 0xD8, .b = 0xD8 };
const dialog_cancel_text_color: ghostty.color.RGB = .{ .r = 0x1A, .g = 0x1A, .b = 0x1A };
/// 두 버튼 사이 간격 (PT). pad 와 무관한 작은 gap.
const dialog_button_gap_pt: u32 = 12;

/// #203 Phase C step 3.3 — dialog 상단 아이콘 크기 (PT, 논리 점). `docs/favicon.svg`
/// 의 viewBox=64×64 를 그대로 줄여 그림. tildaz 의 monitor + `>_` 표지. 사용자
/// 시연 발견 — 이전 48 physical 고정 + 1.7x 환경에서 *논리 28* 로 너무 작음.
const dialog_icon_size_pt: u32 = 64;

/// #203 Phase C step 3.6 — dialog 배경 / 텍스트 색. 터미널 theme (`render_state
/// .colors`) 와 분리 — Tilda 같은 어두운 테마라도 dialog 는 *시스템 표준 밝은
/// 색* (macOS NSAlert / Win 10+ MessageBox 의 light mode 동등). OS 의 light/
/// dark 자동 감지는 별 작업 (portal `org.freedesktop.appearance.color-scheme`).
const dialog_bg_color: ghostty.color.RGB = .{ .r = 0xF2, .g = 0xF2, .b = 0xF2 };
const dialog_text_color: ghostty.color.RGB = .{ .r = 0x1A, .g = 0x1A, .b = 0x1A };
const dialog_separator_color: ghostty.color.RGB = .{ .r = 0xC8, .g = 0xC8, .b = 0xC8 };

/// `ui_metrics.zig` 의 PT (logical point) 값을 `scale` 곱해 physical pixel 로
/// 변환. mac `backingScaleFactor` / Win `dpi/96.0` 동등 패턴. 1.0x 면 PT 그대로.
fn scaledPt(pt: u32, scale: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(pt)) * scale));
}

/// preferred_scale (= scale_num/scale_den, e.g. 204/120 = 1.7x) 을 f32 factor 로.
/// denominator 0 또는 분자 0 이면 1.0 (no-op fallback).
fn scaleFactor(scale_num: u32, scale_den: u32) f32 {
    if (scale_num == 0 or scale_den == 0) return 1.0;
    return @as(f32, @floatFromInt(scale_num)) / @as(f32, @floatFromInt(scale_den));
}

/// `config.font_size_point` 의미는 cross-platform 동등 — Windows host 의
/// `font_height_px = font_size_point × DPI_scale` 식, macOS host 의 logical
/// pixel 그대로 사용 패턴과 같이 **96 DPI 의 logical pixel** 의미. 표준
/// typographic 1pt = 1/72 inch 변환 (× 96/72) 을 다시 곱하면 Win/Mac 대비
/// 1.33x 큰 cell 이 되어 사용자가 "Linux 글자가 크다" 고 느낌 (사용자 보고).
/// 따라서 1:1. fractional / output scale 통합은 후속 sub-step.
fn fontPixelHeight(size_point: u8) u32 {
    return @intCast(size_point);
}

pub const Renderer = struct {
    render_state: ghostty.RenderState = .empty,
    font_ctx: font.Context,
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
    /// L13-γ — 매 픽셀의 alpha byte (ARGB8888 의 high byte). `config.opacity_
    /// alpha` 가 그대로. 100% → 255 (완전 opaque, 시각 변화 없음), <100 →
    /// compositor 가 배경과 alpha blending. `Client.init` 에서 채움.
    opacity_alpha: u8 = 255,
    /// `ui_metrics.*_PT` 를 physical pixel 로 변환할 때 곱하는 factor.
    /// mac `backingScaleFactor` / Win `dpi/96.0` 동등. preferred_scale event
    /// 로 갱신 (`applyScale`). default 1.0 — fractional scaling 미advertise
    /// 환경 또는 첫 init 시점.
    scale: f32 = 1.0,

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
        const pixel_height = scaledFontPixelHeight(cfg.font_size_point, scale_num, scale_den);
        return .{
            .render_state = .empty,
            .font_ctx = try font.Context.init(
                allocator,
                chain,
                pixel_height,
                cfg.cell_width_ratio,
                cfg.line_height_ratio,
            ),
            .scale = scaleFactor(scale_num, scale_den),
        };
    }

    pub fn deinit(self: *Renderer, allocator: std.mem.Allocator) void {
        self.render_state.deinit(allocator);
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
        const pixel_height = scaledFontPixelHeight(cfg.font_size_point, scale_num, scale_den);
        const new_ctx = try font.Context.init(
            allocator,
            chain,
            pixel_height,
            cfg.cell_width_ratio,
            cfg.line_height_ratio,
        );
        self.font_ctx.deinit();
        self.font_ctx = new_ctx;
        self.scale = scaleFactor(scale_num, scale_den);
    }

    /// 터미널 영역 안쪽 padding (cell grid 가 surface 모서리에서 떨어진 거리).
    /// `ui_metrics.TERMINAL_PADDING_PT` (6 pt) × scale. mac `pad_px` / Win
    /// `TERMINAL_PADDING` 동등.
    pub fn paddingPx(self: *const Renderer) i32 {
        return scaledPt(ui_metrics.TERMINAL_PADDING_PT, self.scale);
    }

    /// 우측 스크롤바 thumb 너비. `ui_metrics.SCROLLBAR_W_PT` (8 pt) × scale.
    pub fn scrollbarWPx(self: *const Renderer) i32 {
        return scaledPt(ui_metrics.SCROLLBAR_W_PT, self.scale);
    }

    /// 스크롤바 thumb 최소 높이 — scrollback 이 길어 ratio 작아져도 클릭 가능
    /// 영역. `ui_metrics.SCROLLBAR_MIN_THUMB_H_PT` (32 pt) × scale.
    pub fn scrollbarMinThumbHPx(self: *const Renderer) i32 {
        return scaledPt(ui_metrics.SCROLLBAR_MIN_THUMB_H_PT, self.scale);
    }

    /// 상단 탭바 높이. `ui_metrics.TAB_BAR_HEIGHT_PT` (28 pt) × scale. mac /
    /// Win `applyDpiScale` 동등 — cell_h 보다 작아지면 cell_h + 4 px 로 보정
    /// (탭 텍스트 + 약간의 여백 보장, Win `applyDpiScale` 의 `min_tab_bar_h`
    /// 패턴).
    ///
    /// `tab_count < 2` 면 0 — 단일 탭 시 탭바 자리 안 띄움 (#127, SPEC.md §1
    /// `단일 탭 시 탭바 자리`). mac `tabBarHeightPx` / Win `effectiveTabBarHeight`
    /// 동등. 탭 카운트 변화 시점 (createTab / closeTab / 탭 exit) 에 호출자가
    /// 모든 탭 cols/rows 재계산 책임 (Linux 는 `Client.ensureSessionGrid`).
    pub fn tabBarHeightPx(self: *const Renderer, tab_count: usize) i32 {
        if (tab_count < 2) return 0;
        const base = scaledPt(ui_metrics.TAB_BAR_HEIGHT_PT, self.scale);
        const min: i32 = self.cellHeight() + 4;
        return @max(base, min);
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

    /// 탭 close 'x' 박스 size. `ui_metrics.TAB_CLOSE_SIZE_PT` (14 pt) × scale.
    pub fn tabCloseSizePx(self: *const Renderer) i32 {
        return scaledPt(ui_metrics.TAB_CLOSE_SIZE_PT, self.scale);
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

    fn scaledFontPixelHeight(size_point: u8, scale_num: u32, scale_den: u32) u32 {
        const base = fontPixelHeight(size_point);
        if (scale_num == scale_den) return base;
        const base_i: i64 = @intCast(base);
        const num: i64 = @intCast(scale_num);
        const den: i64 = @intCast(scale_den);
        // round-up — 작은 pixel_height 보다 큰 게 user 시각에 더 자연.
        const scaled = @divFloor(base_i * num + den - 1, den);
        if (scaled <= 0) return base;
        return @intCast(scaled);
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
        rename_view: ?tab_interaction.RenameView,
        drag_view: ?tab_interaction.DragView,
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
        const sb_w: i32 = self.scrollbarWPx();
        const sb_min_thumb: i32 = self.scrollbarMinThumbHPx();

        // L12-α/β/γ — 상단 tab bar 영역. cross-platform tab_layout 의 Layout
        // (`<`[tabs][+]`>` 또는 `[tabs][+]` 영역 분할) 따라 그리기. arrow /
        // plus / scroll 모두 적용. 활성 = `TAB_ACTIVE_BG`, 비활성 = renderer
        // background (cell 영역과 자연 이음, Windows 패턴 동일).
        drawTabBar(memory, width, height, stride, tab_bar_h, self.tabWidthPx(), self.tabPaddingPx(), self.tabCloseSizePx(), tab_titles, active_tab_idx, layout, tab_scroll_x, rename_view, drag_view, self.preedit_text, cw, colors.background, &self.font_ctx);

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
                if (raw.wide == .spacer_tail or raw.wide == .spacer_head) {
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

                if (!raw.hasText() or raw.codepoint() == 0) {
                    x += 1;
                    continue;
                }
                const fg = resolveFg(style, &colors, is_selected);
                const cp = raw.codepoint();

                // Block element + shade — cell-aligned procedural rectangle / dot
                // mask. 폰트 fallback (FreeType raster) 대신 공유 모듈로 그려서
                // 인접 셀 사이 갭 / overlap 제거. Windows d3d11 / macOS Metal 가
                // 같은 모듈을 동일 의미로 사용 ([renderer/windows.zig], [renderer/macos.zig]).
                if (block_element.blockElementRect(cp)) |br| {
                    drawBlockRect(memory, width, height, stride, cell_x, cell_y, cell_w, ch, br, fg);
                    x += 1;
                    continue;
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
                                memory, width, height, stride,
                                raws, styles, sel_range, &colors,
                                pad, cell_y, cw, ch, ascent,
                                x, 3, lm, fg, bg,
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
                                memory, width, height, stride,
                                raws, styles, sel_range, &colors,
                                pad, cell_y, cw, ch, ascent,
                                x, 2, lm, fg, bg,
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

        if (self.render_state.cursor.visible) {
            if (self.render_state.cursor.viewport) |vp| {
                var cx: i32 = pad + @as(i32, @intCast(vp.x)) * cw;
                if (vp.wide_tail and vp.x > 0) cx -= cw;
                const cy: i32 = tab_bar_h + pad + @as(i32, @intCast(vp.y)) * ch;
                const cursor = colors.cursor orelse ghostty.color.RGB{ .r = 180, .g = 180, .b = 180 };
                rect(memory, width, height, stride, cx, cy + ch - 3, cw, 2, cursor);
            }
        }

        // 우측 스크롤바 thumb — scrollback 있을 때만. track 자체는 별도 색 안 그림
        // (배경 그대로). Windows / macOS 패턴 동일 (`renderer/macos.zig:662` 참고).
        const sb = terminal.screens.active.pages.scrollbar();
        if (sb.total > sb.len) {
            const track_h: i32 = height - tab_bar_h - 2 * pad;
            if (track_h > 0) {
                const track_hf: f64 = @floatFromInt(track_h);
                const total_f: f64 = @floatFromInt(sb.total);
                const len_f: f64 = @floatFromInt(sb.len);
                const ratio_px: f64 = track_hf / total_f;
                const min_thumb_f: f64 = @floatFromInt(sb_min_thumb);
                const thumb_hf: f64 = @max(min_thumb_f, ratio_px * len_f);
                const available: f64 = track_hf - thumb_hf;
                const max_off_f: f64 = total_f - len_f;
                const offset_f: f64 = @floatFromInt(sb.offset);
                const offset_ratio: f64 = if (max_off_f > 0) offset_f / max_off_f else 0;
                const thumb_y_px: i32 = tab_bar_h + pad + @as(i32, @intFromFloat(offset_ratio * available));
                const thumb_h_px: i32 = @intFromFloat(thumb_hf);
                const sb_x: i32 = width - sb_w;
                rect(memory, width, height, stride, sb_x, thumb_y_px, sb_w, thumb_h_px, scrollbar_thumb_color);
            }
        }

        // --- L10-β: IME preedit (조합 중) inline overlay ---
        // cursor 위치부터 preedit_text 의 codepoint 별로 보라색 배경 + foreground
        // 글자. AGENTS.md "한글 IME 동작 스펙" — "강조 배경 (보라색 계열) + 글자
        // 로 inline 표시. 별도 candidate window 안 띄움". macOS / Windows 와
        // 동등 색 (`renderer/macos.zig:686`, `renderer/windows.zig:1144`).
        // PTY 에는 들어가지 않고 화면 표시만 — fcitx5 가 commit_string 으로
        // 음절 완성 보내주면 그때 PTY 송신 + preedit 클리어.
        //
        // L12-γ-2 — rename 모드 활성 시 preedit 은 tab bar 안 rename cursor
        // 옆에 그려진다 (`iterTabText` 가 preedit_text 인자로 처리). cell
        // 영역에 또 그리면 두 군데 — skip.
        const rename_active = rename_view != null;
        if (!rename_active and self.preedit_text.len > 0) {
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
        severity: dialog_mod.Severity,
        title: []const u8,
        message: []const u8,
        confirm_focus_ok: ?bool,
    ) void {
        const ch = self.cellHeight();
        const ascent: i32 = @intCast(self.font_ctx.ascent_px);
        const pad: i32 = @max(@as(i32, 8), @divTrunc(ch, 2));
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
        const accent: ghostty.color.RGB = switch (severity) {
            .info => dialog_separator_color,
            .err => .{ .r = 220, .g = 80, .b = 80 },
        };
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
        const icon_x: i32 = box_x + @divTrunc(box_w - icon_size, 2);
        const icon_y: i32 = box_y + pad;
        drawDialogIcon(memory, buffer_w, buffer_h, stride, icon_x, icon_y, icon_size);

        const text_x: i32 = box_x + pad;
        // 텍스트 시작 — 아이콘 하단 + 작은 gap (ch/2).
        var text_y: i32 = icon_y + icon_size + @divTrunc(ch, 2);

        // (3) Title.
        self.drawDialogTextLine(memory, buffer_w, buffer_h, stride, text_x, text_y + ascent, title, fg, bg);
        text_y += ch;

        // (3) separator line — title 과 message 구분.
        const inner_w: i32 = box_w - pad * 2;
        rect(memory, buffer_w, buffer_h, stride, text_x, text_y + @divTrunc(ch, 2), inner_w, 1, accent);
        text_y += ch;

        // (4) Message lines (\n split).
        var iter = std.mem.splitScalar(u8, message, '\n');
        while (iter.next()) |line| {
            self.drawDialogTextLine(memory, buffer_w, buffer_h, stride, text_x, text_y + ascent, line, fg, bg);
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
        fillRoundedRect(memory, buffer_w, buffer_h, stride, ok_x, button_y, button_w, button_h, button_r, dialog_button_color);
        const ok_text = "OK";
        const ok_text_cells = display_width.stringWidth(ok_text);
        const ok_text_w: i32 = @intCast(ok_text_cells * @as(usize, @intCast(self.cellWidth())));
        const ok_text_x: i32 = ok_x + @divTrunc(button_w - ok_text_w, 2);
        const button_text_y: i32 = button_y + @divTrunc(button_h - ch, 2) + ascent;
        self.drawDialogTextLine(memory, buffer_w, buffer_h, stride, ok_text_x, button_text_y, ok_text, dialog_button_text_color, dialog_button_color);

        // Cancel 버튼 — confirm 모드 에서만. secondary action (회색 배경 + 검정).
        if (is_confirm) {
            const cancel_x: i32 = group_x;
            self.last_dialog_cancel_rect = .{ .x = cancel_x, .y = button_y, .w = button_w, .h = button_h };
            fillRoundedRect(memory, buffer_w, buffer_h, stride, cancel_x, button_y, button_w, button_h, button_r, dialog_cancel_color);
            const cancel_text = "Cancel";
            const cancel_text_cells = display_width.stringWidth(cancel_text);
            const cancel_text_w: i32 = @intCast(cancel_text_cells * @as(usize, @intCast(self.cellWidth())));
            const cancel_text_x: i32 = cancel_x + @divTrunc(button_w - cancel_text_w, 2);
            self.drawDialogTextLine(memory, buffer_w, buffer_h, stride, cancel_text_x, button_text_y, cancel_text, dialog_cancel_text_color, dialog_cancel_color);
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

    /// #203 Phase C step 3 — dialog buffer 의 physical pixel 크기 계산. 박스
    /// (텍스트 폭 × cell_w + padding + 라인 수 × cell_h + 버튼) + 4 방향 shadow
    /// margin. `openInfoDialog` 가 surface set_size 보내기 전 호출 — 전체
    /// surface / buffer 크기 결정.
    pub fn computeDialogSize(
        self: *const Renderer,
        title: []const u8,
        message: []const u8,
        confirm: bool,
    ) struct { w: i32, h: i32 } {
        const cw = self.cellWidth();
        const ch = self.cellHeight();
        const pad: i32 = @max(@as(i32, 8), @divTrunc(ch, 2));
        // confirm: Cancel 버튼 너비 추가 분기 (아래 buttons_w 계산).

        var max_cells: usize = display_width.stringWidth(title);
        var line_count: usize = 0;
        var iter = std.mem.splitScalar(u8, message, '\n');
        while (iter.next()) |line| {
            max_cells = @max(max_cells, display_width.stringWidth(line));
            line_count += 1;
        }
        // 최소 30 cell 폭 — 너무 짧은 title 의 박스가 어색해지지 않게.
        max_cells = @max(max_cells, 30);

        // 행 (text 영역): title(1) + separator(1) + msg(line_count) + gap(1).
        // 위로 아이콘 (icon_size + 짧은 gap), 아래로 OK 버튼 + bottom pad.
        // box_h = pad(top) + icon + gap + text_rows*ch + button_h + pad(bottom)
        const text_rows: i32 = 1 + 1 + @as(i32, @intCast(line_count)) + 1;
        const inner_w: i32 = @intCast(max_cells * @as(usize, @intCast(cw)));
        // PT × scale — drawDialogContent 와 같은 변환식 사용해 layout 좌표 일관.
        const button_w: i32 = scaledPt(dialog_button_w_pt, self.scale);
        const button_h: i32 = scaledPt(dialog_button_h_pt, self.scale);
        const icon_size: i32 = scaledPt(dialog_icon_size_pt, self.scale);
        const sm: i32 = scaledPt(dialog_shadow_margin_pt, self.scale);
        const button_gap: i32 = scaledPt(dialog_button_gap_pt, self.scale);
        // Confirm 모드 시 OK + Cancel 두 버튼 + gap. Info 모드 는 OK 하나.
        const buttons_w: i32 = if (confirm) button_w * 2 + button_gap else button_w;
        // 박스 폭 — 텍스트 폭 vs 버튼 폭 vs 아이콘 폭 + 좌우 여유 중 가장 큰.
        const box_w: i32 = @max(@max(inner_w + pad * 2, buttons_w + pad * 4), icon_size + pad * 2);
        const icon_section: i32 = icon_size + @divTrunc(ch, 2);
        const box_h: i32 = pad * 2 + icon_section + text_rows * ch + button_h;
        // buffer = box + shadow margin × 2 (모든 4 방향).
        return .{ .w = box_w + sm * 2, .h = box_h + sm * 2 };
    }

    /// drawDialogContent helper — UTF-8 line 을 codepoint 별 glyph draw.
    /// 03d07c6a 의 `drawDialogTextLine` 재이식. cell-aligned 라 ligature /
    /// cluster shape 안 필요.
    fn drawDialogTextLine(
        self: *Renderer,
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
        const cw = self.cellWidth();
        const ch_metric = self.cellHeight();
        var x: i32 = start_x;
        var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (iter.nextCodepoint()) |cp| {
            if (x >= fb_w) break;
            const cells = display_width.codepointWidth(@intCast(cp));
            const adv: i32 = cw * @as(i32, @intCast(cells));
            const gl = self.font_ctx.glyph(cp);
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

/// L12-α/β/γ tab bar — cross-platform `tab_layout.Layout` 따라 영역 분할 + 각
/// 탭 그리기. `[<][tabs+][+][>]` (arrows_visible) 또는 `[tabs+][+]`. tab area
/// 안 탭들은 `scroll_x` 만큼 좌측 밀려 그려지고 area 범위 밖은 clip. 활성 =
/// `TAB_ACTIVE_BG`, 비활성 = `inactive_bg` (cell 영역 background 와 자연 이음).
fn drawTabBar(
    memory: []u8,
    fb_w: i32,
    fb_h: i32,
    stride: i32,
    tab_bar_h: i32,
    tab_w: i32,
    tab_pad: i32,
    close_size_metric: i32,
    titles: []const []const u8,
    active_idx: usize,
    layout: tab_layout.Layout,
    scroll_x: f32,
    rename_view: ?tab_interaction.RenameView,
    drag_view: ?tab_interaction.DragView,
    preedit_text: []const u8,
    cell_w: i32,
    inactive_bg: ghostty.color.RGB,
    font_ctx: *font.Context,
) void {
    if (tab_bar_h <= 0 or fb_w <= 0 or titles.len == 0) return;
    const tab_bar_bg = rgbFromMetrics(ui_metrics.TAB_BAR_BG);
    rect(memory, fb_w, fb_h, stride, 0, 0, fb_w, tab_bar_h, tab_bar_bg);

    const active_bg = rgbFromMetrics(ui_metrics.TAB_ACTIVE_BG);
    const text_color = rgbFromMetrics(ui_metrics.TAB_TEXT_COLOR);
    const ascent: i32 = @intCast(font_ctx.ascent_px);
    const descent: i32 = @intCast(font_ctx.descent_px);
    const text_baseline: i32 = @divFloor(tab_bar_h + ascent - descent, 2);

    const tab_y: i32 = 2;
    const tab_actual_h: i32 = @max(tab_bar_h - 4, 1);
    const tab_actual_w: i32 = @max(tab_w - 2, 1);
    // mac / win 동등 — text 영역 y 위치는 cell height 기준 vertical center.
    // cursor / preedit_bg 의 y 도 이 값. close 'x' / title text glyph baseline
    // 도 동일.
    const cell_h: i32 = @intCast(font_ctx.cell_height_px);
    const text_y_top: i32 = @divFloor(tab_bar_h - cell_h, 2);
    // close 'x' / preedit / cursor 모두 동일한 max_text_w — mac `tab_w -
    // close_size_px - tab_pad_px * 3` 동등 (close box + 양쪽 padding).
    const max_text_w_metric: i32 = tab_w - close_size_metric - tab_pad * 3;
    const tab_area_x: i32 = @intFromFloat(layout.tab_area_x);
    const tab_area_w: i32 = @intFromFloat(layout.tab_area_w);
    const tab_area_end: i32 = tab_area_x + tab_area_w;
    const scroll_x_i: i32 = @intFromFloat(scroll_x);

    // --- 각 탭 (tab_area 안에서 clipping) ---
    for (titles, 0..) |title_default, i| {
        // L12-γ-2 — rename 활성 탭은 title 대신 buffer 사용.
        const renaming_this = if (rename_view) |rv| rv.tab_index == i else false;
        // L12-γ-3 — drag source 탭은 글자 색 dim (mac / win alpha 0.6 동등 visual).
        // bg 와 50% blend → drop 위치로 옮겨가는 중임을 시각적으로 표시.
        const is_drag_source = if (drag_view) |dv| dv.tab_index == i else false;
        const effective_text: ghostty.color.RGB = if (is_drag_source) ghostty.color.RGB{
            .r = blendU8(text_color.r, tab_bar_bg.r, 0.5),
            .g = blendU8(text_color.g, tab_bar_bg.g, 0.5),
            .b = blendU8(text_color.b, tab_bar_bg.b, 0.5),
        } else text_color;
        const title: []const u8 = if (renaming_this) blk: {
            const rv = rename_view.?;
            break :blk rv.text[0..rv.text_len];
        } else title_default;

        // tab 의 world (scroll-relative) 좌측. tab_area_x 더하면 surface 좌표.
        const tab_world_x: i32 = @as(i32, @intCast(i)) * tab_w;
        const tab_screen_x: i32 = tab_area_x + tab_world_x - scroll_x_i;
        // tab 전체가 tab_area 밖 (좌/우) 이면 skip — clipping 효과.
        if (tab_screen_x + tab_w <= tab_area_x) continue;
        if (tab_screen_x >= tab_area_end) break;

        const tab_x: i32 = tab_screen_x + 1;
        const is_active = i == active_idx;
        const bg = if (is_active) active_bg else inactive_bg;
        // rect helper 의 (x, w) → 자동 clip 단, 우리는 tab_area 경계 안에서
        // 그리도록 보정. min/max 로 clipping. (fb 의 외부 clip 은 rect 의 내부
        // clamp 가 처리, tab_area 경계 clip 만 우리가.)
        const clip_x: i32 = @max(tab_x, tab_area_x);
        const clip_w: i32 = @min(tab_x + tab_actual_w, tab_area_end) - clip_x;
        if (clip_w > 0) {
            rect(memory, fb_w, fb_h, stride, clip_x, tab_y, clip_w, tab_actual_h, bg);
        }

        // close 'x' — 탭 우측 끝 padding 안. mac / win 동등 시각 — 'x'
        // 글리프 + 색을 `TAB_TEXT_COLOR × 0.6 + bg × 0.4` 로 dim (활성 / 비활성
        // 탭 배경 색 차이가 자연 반영). `tab_layout.hitTab` 의 `close_x_min
        // = tab_x + tab_w - close_size - tab_pad` 와 정확 align.
        const close_size: i32 = close_size_metric;
        const close_x_outer: i32 = tab_x + tab_actual_w - close_size - tab_pad;
        if (close_x_outer >= tab_area_x and close_x_outer + close_size <= tab_area_end) {
            const close_color = ghostty.color.RGB{
                .r = blendU8(effective_text.r, bg.r, 0.6),
                .g = blendU8(effective_text.g, bg.g, 0.6),
                .b = blendU8(effective_text.b, bg.b, 0.6),
            };
            const x_glyph = font_ctx.glyph('x');
            const x_adv: i32 = @intCast(x_glyph.advance);
            const x_glyph_x: i32 = close_x_outer + @divFloor(close_size - x_adv, 2);
            drawGlyph(
                memory,
                fb_w,
                fb_h,
                stride,
                x_glyph_x + x_glyph.bitmap_left,
                text_baseline - x_glyph.bitmap_top,
                x_glyph,
                close_color,
                bg,
            );
        }

        // L12-γ-2/3 — title text 그리기를 cross-platform `tab_layout.
        // iterTabText` 로 — cursor follow scroll + truncate ellipsis +
        // preedit overlay (rename 활성 시 cursor 옆 inline) 모두 자동.
        // mac / win renderer 의 호출 패턴과 인자 / cb 분기 모두 동등.
        const text_x_start: i32 = tab_x + tab_pad;
        const cw_f: f32 = @floatFromInt(cell_w);
        const max_text_w_f: f32 = @floatFromInt(max_text_w_metric);

        const cursor_byte: ?usize = if (renaming_this) rename_view.?.cursor else null;
        const scroll_inout: ?*f32 = if (renaming_this) rename_view.?.scroll_offset else null;
        const preedit_for_this: []const u8 = if (renaming_this) preedit_text else "";
        // mac/win 동등 — 짧은 title 은 truncate 안 함 (ellipsis 안 그림).
        // rename 활성 중에는 cursor follow scroll 가 처리 — truncate 비활성.
        const total_text_w_f: f32 = @as(f32, @floatFromInt(display_width.stringWidth(title))) * cw_f;
        const needs_truncate = !renaming_this and total_text_w_f > max_text_w_f;

        const TextCtx = struct {
            memory: []u8,
            fb_w: i32,
            fb_h: i32,
            stride: i32,
            viewport_left: i32,
            tab_area_end: i32,
            text_y_top: i32,
            cell_h: i32,
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
            .text_y_top = text_y_top,
            .cell_h = cell_h,
            .tab_bar_h = tab_bar_h,
            .text_baseline = text_baseline,
            .bg = bg,
            .text_color = effective_text,
            .font_ctx = font_ctx,
        };

        const cb_fn = struct {
            fn emit(c: TextCtx, cmd: tab_layout.TextCmd) void {
                switch (cmd) {
                    .glyph => |g| {
                        // mac / win 동등 — glyph 만 viewport_left 검사 (scroll
                        // 좌측 잘림 영역 skip). cursor / preedit_bg 는 검사 X.
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
                    },
                    .cursor => |cur| {
                        // mac 동등 — 1px wide, height = cell_h - 4, y = text_y_top + 2.
                        const px: i32 = @intFromFloat(cur.x);
                        rect(c.memory, c.fb_w, c.fb_h, c.stride, px, c.text_y_top + 2, 1, @max(c.cell_h - 4, 1), c.text_color);
                    },
                    .preedit_bg => |pb| {
                        // mac 동등 — y = text_y_top, height = cell_h.
                        const px: i32 = @intFromFloat(pb.x);
                        const adv: i32 = @intFromFloat(pb.advance);
                        const preedit_bg = ghostty.color.RGB{ .r = 64, .g = 64, .b = 128 };
                        rect(c.memory, c.fb_w, c.fb_h, c.stride, px, c.text_y_top, adv, c.cell_h, preedit_bg);
                    },
                    .preedit_glyph => |pg| {
                        const px: i32 = @intFromFloat(pg.x);
                        const gl = c.font_ctx.glyph(pg.cp);
                        const preedit_bg = ghostty.color.RGB{ .r = 64, .g = 64, .b = 128 };
                        if (gl.pixel_mode == freetype.FT_PIXEL_MODE_BGRA) {
                            const adv: i32 = @intFromFloat(pg.advance);
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
                                preedit_bg,
                            );
                        }
                    },
                    .truncate_dot => |dot| {
                        // emitGlyph('.') 동등 — mac 의 emitGlyph 호출 패턴.
                        const px: i32 = @intFromFloat(dot.x);
                        if (px < c.viewport_left) return;
                        if (px >= c.tab_area_end) return;
                        const gl = c.font_ctx.glyph('.');
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
                    },
                }
            }
        }.emit;

        tab_layout.iterTabText(
            title,
            cursor_byte,
            preedit_for_this,
            @floatFromInt(text_x_start),
            cw_f,
            max_text_w_f,
            renaming_this,
            needs_truncate,
            scroll_inout,
            ctx,
            cb_fn,
        );
    }

    // L12-γ-3 — drop indicator. source 와 drop_idx 가 다를 때만 drop_idx 의
    // left edge 에 2px wide 세로 line (text_color). drop_idx 는 `DragState.
    // finish` 와 같은 공식 (`current_x / tab_w` clamped).
    if (drag_view) |dv| {
        if (titles.len > 1 and dv.tab_index < titles.len) {
            const tab_count_c: c_int = @intCast(titles.len);
            var target_raw: c_int = @divTrunc(dv.current_x, tab_w);
            target_raw = @max(0, @min(target_raw, tab_count_c - 1));
            if (target_raw != @as(c_int, @intCast(dv.tab_index))) {
                const drop_idx: i32 = @intCast(target_raw);
                const indicator_world_x: i32 = drop_idx * tab_w;
                const indicator_screen_x: i32 = tab_area_x + indicator_world_x - scroll_x_i;
                if (indicator_screen_x >= tab_area_x - 1 and indicator_screen_x <= tab_area_end) {
                    rect(memory, fb_w, fb_h, stride, indicator_screen_x, tab_y, 2, tab_actual_h, text_color);
                }
            }
        }
    }

    // --- arrow / plus 버튼 ---
    drawTabBarControls(memory, fb_w, fb_h, stride, tab_bar_h, layout, font_ctx);
}

/// `<` / `>` / `+` 버튼 그리기. arrows_visible 면 좌측 `<` + 우측 `>`. 항상
/// `+` (탭 area 끝 또는 우 arrow 좌측). 색은 TAB_TEXT_COLOR, 배경은 TAB_BAR_BG
/// 그대로 — 별도 fill 없이 글자만.
fn drawTabBarControls(
    memory: []u8,
    fb_w: i32,
    fb_h: i32,
    stride: i32,
    tab_bar_h: i32,
    layout: tab_layout.Layout,
    font_ctx: *font.Context,
) void {
    const ascent: i32 = @intCast(font_ctx.ascent_px);
    const descent: i32 = @intCast(font_ctx.descent_px);
    const baseline: i32 = @divFloor(tab_bar_h + ascent - descent, 2);
    const bg = rgbFromMetrics(ui_metrics.TAB_BAR_BG);
    // mac / win 동등 — enabled = `TAB_CTRL_ACTIVE_COLOR` (밝은 흰색 0.95),
    // disabled = `TAB_ARROW_DISABLED_COLOR` (회색 0.4). scroll 왼쪽 끝이면
    // `<` 회색, 우측 끝이면 `>` 회색. plus 는 항상 enabled.
    const active_color = rgbFromMetrics(ui_metrics.TAB_CTRL_ACTIVE_COLOR);
    const disabled_color = rgbFromMetrics(ui_metrics.TAB_ARROW_DISABLED_COLOR);

    const drawCentered = struct {
        fn call(
            mem: []u8,
            w: i32,
            h: i32,
            s: i32,
            cp: u21,
            x_left: i32,
            box_w: i32,
            line_baseline: i32,
            fg: ghostty.color.RGB,
            bg_color: ghostty.color.RGB,
            ctx: *font.Context,
        ) void {
            const g = ctx.glyph(cp);
            const adv: i32 = @intCast(g.advance);
            const center: i32 = x_left + @divFloor(box_w - adv, 2);
            if (g.pixel_mode == freetype.FT_PIXEL_MODE_BGRA) return;
            drawGlyph(mem, w, h, s, center + g.bitmap_left, line_baseline - g.bitmap_top, g, fg, bg_color);
        }
    }.call;

    if (layout.arrows_visible) {
        const left_x: i32 = @intFromFloat(layout.left_arrow_x);
        const right_x: i32 = @intFromFloat(layout.right_arrow_x);
        const arrow_w: i32 = @intFromFloat(layout.arrow_w);
        const left_color = if (layout.left_enabled) active_color else disabled_color;
        const right_color = if (layout.right_enabled) active_color else disabled_color;
        drawCentered(memory, fb_w, fb_h, stride, '<', left_x, arrow_w, baseline, left_color, bg, font_ctx);
        drawCentered(memory, fb_w, fb_h, stride, '>', right_x, arrow_w, baseline, right_color, bg, font_ctx);
    }
    const plus_x: i32 = @intFromFloat(layout.plus_x);
    const plus_w: i32 = @intFromFloat(layout.plus_w);
    drawCentered(memory, fb_w, fb_h, stride, '+', plus_x, plus_w, baseline, active_color, bg, font_ctx);
}

/// `a * weight + b * (1 - weight)` 의 u8 클램프. close 'x' 의 dim 색 등에 사용.
fn blendU8(a: u8, b: u8, weight: f32) u8 {
    const a_f: f32 = @floatFromInt(a);
    const b_f: f32 = @floatFromInt(b);
    const mixed = a_f * weight + b_f * (1.0 - weight);
    return @intFromFloat(@max(0.0, @min(255.0, mixed)));
}

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
                    memory, fb_w, fb_h, stride,
                    base_cell_x + center_off + ligature_glyph.bitmap_left + lg.x_offset,
                    baseline - ligature_glyph.bitmap_top - lg.y_offset,
                    ligature_glyph, fg, bg,
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
                        memory, fb_w, fb_h, stride,
                        gx_cell + center_off + g_glyph.bitmap_left + sp.x_offsets[i],
                        baseline - g_glyph.bitmap_top - sp.y_offsets[i],
                        g_glyph, fg, bg,
                    );
                }
            }
        },
    }
}

fn resolveFg(style: ghostty.Style, colors: *const ghostty.RenderState.Colors, selected: bool) ghostty.color.RGB {
    if (selected) return colors.background;
    if (style.flags.inverse) return colors.background;
    return style.fg(.{
        .default = colors.foreground,
        .palette = &colors.palette,
        .bold = .bright,
    });
}

fn resolveBg(
    style: ghostty.Style,
    raw: *const ghostty.Cell,
    colors: *const ghostty.RenderState.Colors,
    selected: bool,
) ghostty.color.RGB {
    if (selected) return colors.foreground;
    if (style.flags.inverse) {
        return style.fg(.{
            .default = colors.foreground,
            .palette = &colors.palette,
            .bold = .bright,
        });
    }
    return style.bg(raw, &colors.palette) orelse colors.background;
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
    fg: ghostty.color.RGB,
) void {
    const cw_f: f32 = @floatFromInt(cell_w);
    const ch_f: f32 = @floatFromInt(cell_h);
    const x0: i32 = cell_x + @as(i32, @intFromFloat(br.x0 * cw_f));
    const y0: i32 = cell_y + @as(i32, @intFromFloat(br.y0 * ch_f));
    const x1: i32 = cell_x + @as(i32, @intFromFloat(br.x1 * cw_f));
    const y1: i32 = cell_y + @as(i32, @intFromFloat(br.y1 * ch_f));

    if (br.shade < 0.5) {
        rect(memory, fb_w, fb_h, stride, x0, y0, x1 - x0, y1 - y0, fg);
        return;
    }

    const cx0 = @max(0, x0);
    const cy0 = @max(0, y0);
    const cx1 = @min(fb_w, x1);
    const cy1 = @min(fb_h, y1);
    if (cx1 <= cx0 or cy1 <= cy0) return;

    const fg_packed = pack(fg);
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

// #213 재현 — About dialog paint 경로 (compositor 무관). KDE Plasma 1.7x 에서
// Ctrl+Shift+I crash 가 layer-shell dialog paint (`handleDialogConfigure` →
// `drawDialogContent`) 에 있는지 격리. layer-shell 미지원 DE (Cinnamon 등) 에선
// dialog 가 안 떠 GUI 재현 불가하므로 paint 만 직접 호출. ReleaseSafe 로 돌리면
// safety panic 의 정확한 source line 확보.
test "#213 about dialog paint — scale 1.7 + 긴 multi-line + URL" {
    const allocator = std.testing.allocator;
    // 실제 GUI 경로 재현 — hand-build 가 아니라 `Renderer.init` 로 *실제 Config*
    // (Linux default = DejaVu Sans Mono + Noto fallback chain + size_point 16 +
    // cell_width_ratio 1.0 + **line_height_ratio 1.1**) 를 scale 1.7 (204/120) 로
    // 초기화. 이전 버전은 chain={"monospace"} + line_height 1.0 hand-build 라
    // 사용자 config (line_height 1.1) 의 layout 을 재현 못 했음 (#213 진단 cycle).
    const cfg = config_mod.Config{};
    var r = Renderer.init(allocator, &cfg, 204, 120) catch |e| {
        std.debug.print("[#213] Renderer.init failed ({s}) — skip (no fontconfig?)\n", .{@errorName(e)});
        return;
    };
    defer r.deinit(allocator);

    const title = "About TildaZ";
    const msg =
        \\TildaZ v0.5.0
        \\
        \\exe   : /home/ensky0/tildaz/zig-out/bin/tildaz
        \\pid   : 12345
        \\config: /home/ensky0/.config/tildaz/config.json
        \\log   : /home/ensky0/.local/state/tildaz/tildaz.log
        \\
        \\Tip: Ctrl+Shift+P opens config in default editor.
        \\     Ctrl+Shift+L opens log.
        \\
        \\https://github.com/ensky0/tildaz
    ;

    const size = r.computeDialogSize(title, msg, false);
    // handleDialogConfigure 의 logical 왕복 재현 (preferred_scale 204/120 = 1.7x):
    // physical → logical(set_size) → KWin echo → logicalToPhysical(buffer).
    const lw = @divFloor(size.w * 120, 204);
    const lh = @divFloor(size.h * 120, 204);
    const pw = @divFloor(lw * 204, 120);
    const ph = @divFloor(lh * 204, 120);
    const stride = pw * 4;
    std.debug.print("[#213] computeDialogSize={}x{} logical={}x{} buffer={}x{}\n", .{ size.w, size.h, lw, lh, pw, ph });
    const buf = try allocator.alloc(u8, @intCast(stride * ph));
    defer allocator.free(buf);
    @memset(buf, 0);
    r.drawDialogContent(buf, pw, ph, stride, .info, title, msg, null);
    std.debug.print("[#213] painted ok\n", .{});
}
