// Metal terminal renderer — Windows 의 `src/d3d11_renderer.zig` 와 같은 역할.
// 인스턴스드 쿼드 (한 cell = 한 quad instance) 로 배경 + 글리프 텍스트 그림.
// macOS 는 grayscale antialias 만 지원 (Mojave+) 이라 ClearType 서브픽셀 셰이더
// 불필요. 셰이더 / 셀 파이프라인이 Windows 보다 단순.
//
// #75 (claude/infallible-swartz) 의 macos/renderer.zig 패턴 그대로 차용 +
// 우리 nullable `id` (?*opaque) 와 평면 모듈 구조에 맞춰 정리.

const std = @import("std");
const objc = @import("macos_objc.zig");
const ct = @import("macos_coretext.zig");
const CoreTextFontContext = @import("macos_font.zig").CoreTextFontContext;
const macos_glyph_atlas = @import("macos_glyph_atlas.zig");
const ui_metrics = @import("ui_metrics.zig");
const GlyphAtlas = macos_glyph_atlas.GlyphAtlas;
const ATLAS_SIZE = macos_glyph_atlas.ATLAS_SIZE;
const ghostty = @import("ghostty-vt");

const MAX_INSTANCES: u32 = 32768;

// --- Instance data layouts (MSL struct 와 일치해야 함) ---

const BgInstance = extern struct {
    pos: [2]f32,
    size: [2]f32,
    color: [4]f32,
};

const TextInstance = extern struct {
    pos: [2]f32,
    size: [2]f32,
    uv_pos: [2]f32,
    uv_size: [2]f32,
    fg_color: [4]f32,
    /// 0 = 일반 글리프 (atlas × fg 로 색 입힘), 1 = 컬러 글리프 (SBIX/COLR — atlas
    /// 그대로 출력, fg 무시). MSL 의 분기에서 0.5 임계값으로 판단. f32 인 이유는
    /// MSL struct 의 alignment 단순화 + vertex output interpolation.
    color_flag: f32,
    /// MSL 의 `float4` 는 16-byte aligned. struct 사이즈가 16 의 배수가 아니면
    /// MSL 은 그 다음 배수로 padding 한 stride 로 inst[iid] 인덱싱 (e.g., 52 bytes
    /// 작성 → 64 bytes 로 읽음 → instance[1] 부터 모든 필드 깨짐).
    /// 기존 5-field TextInstance (48 bytes) 는 16 배수라 padding 불필요했지만
    /// color_flag 추가로 52 bytes 가 되어 12 bytes 명시적 padding 필요.
    _pad: [3]f32 = .{ 0, 0, 0 },
};

// --- MSL 셰이더 ---

// === KNOWN ISSUE: layer 의 (0, 0) 픽셀 미렌더링 ===
//
// 진단 마커로 확인된 quirk: pos=(0,0) 위치에 그린 instance 의 좌상 1px 모서리
// (정확히 NDC(-1, +1) corner) 만 화면에 안 그려진다. pos=(1,1) 부터는 정상.
// 다른 모서리 (NDC (+1,+1), (-1,-1), (+1,-1)) 는 영향 없음 — 좌상 corner 만.
//
// 영향: TERMINAL_PADDING_PT >= 1 이면 글자가 항상 (1, 1) 안쪽에 있어 사용자가
// 인지하지 못 함. padding=0 으로 두고 셀 (0, 0) 부터 그릴 때만 1px 누락 보임.
//
// 추정 원인: Metal 의 `-px.y` NDC 변환 + viewport rasterization 의 좌상
// corner sample point 처리. 정확한 NDC corner vertex 가 fragment 에 sample
// 되지 않거나 `kCAGravityResize` 의 sub-pixel rounding 에서 누락되는 가능성.
// CAMetalLayer.contentsGravity = kCAGravityTopLeft 또는 viewport 명시적 설정
// 으로 회피 가능할 수 있으나 미검증. follow-up 으로 추적.
//
// === Shader ===
// Atlas 가 BGRA8 premultiplied 라 fragment 출력도 모두 premultiplied 로 통일.
// blend mode 도 (One, OneMinusSourceAlpha) — `createPipeline` 참조.
//
// - bg_fs: input color 는 plain (r,g,b,a). premultiply 해서 출력.
// - text_fs: atlas sample 이 이미 premult.
//   - 일반 글리프 (color_flag = 0): atlas = (a, a, a, a) 흰색 premult. fg 와 곱
//     → (a*fg.r, a*fg.g, a*fg.b, a*fg.a) = premult 결과.
//   - 컬러 글리프 (color_flag = 1, Apple Color Emoji 등): atlas = SBIX 의 본래
//     색깔 premult. fg 무시하고 그대로 출력.
const shader_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct BgInst { float2 pos; float2 size; float4 color; };
    \\struct BgOut { float4 position [[position]]; float4 color; };
    \\
    \\vertex BgOut bg_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
    \\    const device BgInst* inst [[buffer(0)]], constant float4& sa [[buffer(1)]]) {
    \\    float2 c = float2(vid & 1, vid >> 1);
    \\    float2 px = (inst[iid].pos + c * inst[iid].size) / sa.xy * 2.0 - 1.0;
    \\    BgOut o; o.position = float4(px.x, -px.y, 0, 1); o.color = inst[iid].color; return o;
    \\}
    \\fragment float4 bg_fs(BgOut in [[stage_in]]) {
    \\    return float4(in.color.rgb * in.color.a, in.color.a);
    \\}
    \\
    \\struct TxInst { float2 pos; float2 size; float2 uvp; float2 uvs; float4 fg; float color_flag; };
    \\struct TxOut { float4 position [[position]]; float2 uv; float4 fg; float color_flag; };
    \\
    \\vertex TxOut text_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
    \\    const device TxInst* inst [[buffer(0)]], constant float4& sa [[buffer(1)]]) {
    \\    float2 c = float2(vid & 1, vid >> 1);
    \\    float2 px = (inst[iid].pos + c * inst[iid].size) / sa.xy * 2.0 - 1.0;
    \\    TxOut o; o.position = float4(px.x, -px.y, 0, 1);
    \\    o.uv = (inst[iid].uvp + c * inst[iid].uvs) / sa.zw;
    \\    o.fg = inst[iid].fg;
    \\    o.color_flag = inst[iid].color_flag;
    \\    return o;
    \\}
    \\fragment float4 text_fs(TxOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    \\    constexpr sampler smp(mag_filter::nearest, min_filter::nearest);
    \\    float4 s = atlas.sample(smp, in.uv);
    \\    if (in.color_flag > 0.5) return s;
    \\    return s * in.fg;
    \\}
;

// --- Renderer ---

/// rename 시각 정보 — drawTabBar 가 활성 탭 title 대신 이 텍스트를 그림.
/// `cursor` byte offset 위치에 1px vertical bar (Windows 와 동일 always-visible).
/// `preedit` 는 IME composition 중 자모 / 미완성 음절 — cursor 뒤에 inline 표시.
pub const TabRenameView = struct {
    tab_index: usize,
    text: []const u8,
    cursor: usize,
    preedit: []const u8,
};

/// drag 시각 정보 — drag 중인 탭 위치를 마우스 따라 (`current_x_px - tab_w/2`)
/// 그림. Windows `d3d11_renderer.zig:560` 와 동일 패턴.
pub const TabDragView = struct {
    tab_index: usize,
    current_x_px: f32,
};

/// 탭바 layout (#117 Firefox 패턴) — `<` `>` 화살표 + `+` 버튼이 탭 viewport
/// 영역을 깎음. 호출처 (macos_host) 가 계산해서 넘김.
pub const TabBarLayout = struct {
    tab_area_x: f32,
    tab_area_w: f32,
    arrows_visible: bool,
    arrow_w: f32,
    plus_w: f32,
    plus_x: f32,
    left_arrow_x: f32,
    right_arrow_x: f32,
    left_enabled: bool,
    right_enabled: bool,
};

pub const MetalRenderer = struct {
    alloc: std.mem.Allocator,
    font: CoreTextFontContext,
    atlas: GlyphAtlas,
    render_state: ghostty.RenderState = .empty,

    // Metal 객체 (모두 ObjC id, 우리는 ARC 안 쓰지만 process 종료 시 회수).
    device: objc.id,
    command_queue: objc.id,
    bg_pipeline: objc.id,
    text_pipeline: objc.id,
    bg_buffer: objc.id,
    text_buffer: objc.id,
    atlas_texture: objc.id,
    constants_buffer: objc.id,

    // frame 내 누적된 instance 수. 매 drawBgInstances / drawTextInstances 호출이
    // 같은 buffer 의 *다음 offset* 에 쓰고 setVertexBuffer offset 도 그에 맞게.
    // 같은 frame 안에서 여러 호출 (cell bg → cursor → scrollbar → preedit) 의
    // 데이터가 buffer 안에서 서로 덮어쓰지 않게. renderFrame 시작 시 0 reset.
    bg_used: u32 = 0,
    text_used: u32 = 0,

    // 기본 배경색 (theme 미설정 시).
    default_bg: [3]f32,

    // viewport (pixel 단위).
    vp_width: u32 = 0,
    vp_height: u32 = 0,

    // Retina backing scale.
    scale: f32,

    pub fn colorF(v: u8) f32 {
        return @as(f32, @floatFromInt(v)) / 255.0;
    }

    pub fn init(
        alloc: std.mem.Allocator,
        device: objc.id,
        layer: objc.id,
        font_families: []const []const u8,
        font_size: f32,
        /// Windows config 와 동일한 미적 보정. 폰트 변경 시 cell 크기는
        /// font 가 자체 측정 (advance + ascent/descent/leading).
        cell_width_scale: f32,
        line_height_scale: f32,
        bg_rgb: ?[3]u8,
        scale: f32,
    ) !MetalRenderer {
        const bg = bg_rgb orelse [3]u8{ 30, 30, 30 };

        const cmd_queue = objc.msgSend(device, objc.sel("newCommandQueue"));

        var font_ctx = try CoreTextFontContext.init(
            font_families,
            font_size,
            scale,
            cell_width_scale,
            line_height_scale,
        );
        errdefer font_ctx.deinit();

        var glyph_atlas = try GlyphAtlas.init(alloc, font_size, scale);
        errdefer glyph_atlas.deinit();

        // Metal 셰이더 컴파일.
        const source_str = objc.nsString(shader_source);
        var err: objc.id = null;
        const library = objc.msgSend3(
            device,
            objc.sel("newLibraryWithSource:options:error:"),
            source_str,
            @as(objc.id, null),
            @as(*objc.id, &err),
        );
        if (library == null) {
            if (err) |e| {
                const desc = objc.msgSend(e, objc.sel("localizedDescription"));
                if (desc) |d| {
                    const cstr_ptr = objc.msgSend(d, objc.sel("UTF8String"));
                    if (cstr_ptr) |p| {
                        const cstr: [*:0]const u8 = @ptrCast(p);
                        std.log.err("Metal shader error: {s}", .{cstr});
                    }
                }
            }
            return error.ShaderCompileFailed;
        }

        const bg_vs_fn = objc.msgSend1(library, objc.sel("newFunctionWithName:"), objc.nsString("bg_vs"));
        const bg_fs_fn = objc.msgSend1(library, objc.sel("newFunctionWithName:"), objc.nsString("bg_fs"));
        const text_vs_fn = objc.msgSend1(library, objc.sel("newFunctionWithName:"), objc.nsString("text_vs"));
        const text_fs_fn = objc.msgSend1(library, objc.sel("newFunctionWithName:"), objc.nsString("text_fs"));

        const bg_pipeline = try createPipeline(device, bg_vs_fn, bg_fs_fn);
        const text_pipeline = try createPipeline(device, text_vs_fn, text_fs_fn);

        const bg_buf = createBuffer(device, MAX_INSTANCES * @sizeOf(BgInstance));
        const text_buf = createBuffer(device, MAX_INSTANCES * @sizeOf(TextInstance));

        // constants buffer = float4 (screen_w, screen_h, atlas_w, atlas_h).
        const const_buf = createBuffer(device, 16);

        const atlas_tex = createAtlasTexture(device);

        // CAMetalLayer 설정 (device 등록 + pixel format).
        objc.msgSendVoid1(layer, objc.sel("setDevice:"), device);
        objc.msgSendVoid1(layer, objc.sel("setPixelFormat:"), @as(objc.NSUInteger, 80)); // BGRA8Unorm

        return .{
            .alloc = alloc,
            .font = font_ctx,
            .atlas = glyph_atlas,
            .device = device,
            .command_queue = cmd_queue,
            .bg_pipeline = bg_pipeline,
            .text_pipeline = text_pipeline,
            .bg_buffer = bg_buf,
            .text_buffer = text_buf,
            .atlas_texture = atlas_tex,
            .constants_buffer = const_buf,
            .default_bg = .{ colorF(bg[0]), colorF(bg[1]), colorF(bg[2]) },
            .scale = scale,
        };
    }

    pub fn deinit(self: *MetalRenderer) void {
        self.atlas.deinit();
        self.font.deinit();
        // Metal 객체는 ARC / process exit 으로 정리.
    }

    pub fn resize(self: *MetalRenderer, width: u32, height: u32) void {
        self.vp_width = width;
        self.vp_height = height;
    }

    /// 한 프레임 렌더 — drawable 획득 → 배경 + 텍스트 + 커서 + preedit (IME
    /// 조합 중) 그리기 → present.
    pub fn renderFrame(
        self: *MetalRenderer,
        layer: objc.id,
        terminal: *ghostty.Terminal,
        cell_w: i32,
        cell_h: i32,
        y_offset: i32,
        padding: i32,
        preedit_utf8: []const u8,
        /// 멀티탭 (#111). 길이 ≥ 2 일 때만 탭바 그림. 길이 0 / 1 이면 single-tab
        /// 으로 보고 cell grid 가 풀 화면 사용.
        tab_titles: []const []const u8,
        active_tab: usize,
        /// rename 진행 중이면 그 탭의 title 대신 이 텍스트를 그림 (#111 M11.6b).
        /// null = rename 비활성.
        rename_view: ?TabRenameView,
        /// drag 진행 중이면 그 탭을 마우스 위치 (`current_x_px`) 따라 이동시켜
        /// 그림. null = drag 안 함 또는 5px 임계 미만. `current_x_px` 는 *world*
        /// 좌표 (#117) — 화면 위치는 `current_x_px - tab_scroll_x_px + tab_area_x`.
        drag_view: ?TabDragView,
        /// 탭바 스크롤 오프셋 (픽셀, #117). 각 탭 / drag 탭의 화면 x = world -
        /// 이 값 + tab_area_x.
        tab_scroll_x_px: f32,
        /// 탭바 layout — `<` `>` `+` 버튼 위치, 탭 viewport 영역.
        tab_bar_layout: TabBarLayout,
    ) void {
        const drawable = objc.msgSend(layer, objc.sel("nextDrawable"));
        if (drawable == null) return;

        // frame 내 buffer overwrite 방지 — 매 frame 시작 시 누적 offset 리셋.
        self.bg_used = 0;
        self.text_used = 0;

        const texture = objc.msgSend(drawable, objc.sel("texture"));

        const cmd_buf = objc.msgSend(self.command_queue, objc.sel("commandBuffer"));

        const rpd_class = objc.getClass("MTLRenderPassDescriptor");
        const rpd = objc.msgSend(rpd_class, objc.sel("renderPassDescriptor"));

        const attachments = objc.msgSend(rpd, objc.sel("colorAttachments"));
        const att0 = objc.msgSend1(attachments, objc.sel("objectAtIndexedSubscript:"), @as(objc.NSUInteger, 0));
        objc.msgSendVoid1(att0, objc.sel("setTexture:"), texture);
        objc.msgSendVoid1(att0, objc.sel("setLoadAction:"), @as(objc.NSUInteger, 2)); // Clear
        objc.msgSendVoid1(att0, objc.sel("setStoreAction:"), @as(objc.NSUInteger, 1)); // Store

        const ClearColor = extern struct { r: f64, g: f64, b: f64, a: f64 };
        const clear = ClearColor{
            .r = @floatCast(self.default_bg[0]),
            .g = @floatCast(self.default_bg[1]),
            .b = @floatCast(self.default_bg[2]),
            .a = 1.0,
        };
        const setClearColorFn: *const fn (objc.id, objc.SEL, ClearColor) callconv(.c) void = @ptrCast(objc.msgSend_raw);
        setClearColorFn(att0, objc.sel("setClearColor:"), clear);

        const encoder = objc.msgSend1(cmd_buf, objc.sel("renderCommandEncoderWithDescriptor:"), rpd);
        if (encoder == null) return;

        self.updateConstants();

        if (self.atlas.dirty) {
            self.uploadAtlas();
            self.atlas.dirty = false;
        }

        self.renderTerminalContent(encoder, terminal, cell_w, cell_h, y_offset, padding, preedit_utf8);

        if (tab_titles.len >= 2) self.drawTabBar(encoder, tab_titles, active_tab, rename_view, drag_view, tab_scroll_x_px, tab_bar_layout);

        objc.msgSendVoid(encoder, objc.sel("endEncoding"));
        objc.msgSendVoid1(cmd_buf, objc.sel("presentDrawable:"), drawable);
        objc.msgSendVoid(cmd_buf, objc.sel("commit"));
    }

    fn renderTerminalContent(
        self: *MetalRenderer,
        encoder: objc.id,
        terminal: *ghostty.Terminal,
        cell_w: i32,
        cell_h: i32,
        y_offset: i32,
        padding: i32,
        preedit_utf8: []const u8,
    ) void {
        self.render_state.update(self.alloc, terminal) catch return;

        const rows = self.render_state.rows;
        const cols = self.render_state.cols;
        const colors = self.render_state.colors;
        const row_slice = self.render_state.row_data.slice();

        const cw: f32 = @floatFromInt(cell_w);
        const ch: f32 = @floatFromInt(cell_h);
        // 위쪽 padding 보정: 폰트의 ascent 가 cap_height 보다 위쪽 internal
        // leading 만큼 더 큰데 cell box top 부터 ascent 만큼 내려간 위치가
        // baseline 이라, 대문자 visible top 은 cell top + (ascent − cap_height)
        // 위치. 좌/우 padding 은 글자에 딱 붙는데 위쪽만 (ascent − cap_height)
        // 만큼 추가 여백이 생겨 비대칭. 모든 row 의 fy 를 위로 그만큼 shift
        // 해서 첫 행 글자 visible top 이 정확히 padding 위치에 오게.
        const y_off: f32 = @as(f32, @floatFromInt(y_offset + padding)) - self.font.top_pad_px;
        const x_pad: f32 = @floatFromInt(padding);

        const all_cells = row_slice.items(.cells);
        const all_sels = row_slice.items(.selection);

        const dbg_r = colorF(colors.background.r);
        const dbg_g = colorF(colors.background.g);
        const dbg_b = colorF(colors.background.b);

        const MAX_CELLS = 4096;
        var bg_buf: [MAX_CELLS]BgInstance = undefined;
        var bg_count: u32 = 0;
        var text_buf: [MAX_CELLS]TextInstance = undefined;
        var text_count: u32 = 0;

        // --- Background pass ---
        for (0..rows) |y| {
            if (y >= all_cells.len) break;
            const cell_slice = all_cells[y].slice();
            const raws = cell_slice.items(.raw);
            const styles = cell_slice.items(.style);
            const sel_range: ?[2]u16 = if (y < all_sels.len) all_sels[y] else null;

            for (0..cols) |x| {
                if (x >= raws.len) break;
                const raw = raws[x];
                if (raw.wide == .spacer_tail) continue;

                const style = if (raw.style_id != 0) styles[x] else ghostty.Style{};
                const is_inverse = style.flags.inverse;
                const x16: u16 = @intCast(x);
                const is_selected = if (sel_range) |sr| (x16 >= sr[0] and x16 <= sr[1]) else false;

                const is_custom_bg = is_selected or is_inverse or (style.bg(&raw, &colors.palette) != null);
                if (!is_custom_bg) continue;

                if (bg_count >= MAX_CELLS) {
                    self.drawBgInstances(encoder, bg_buf[0..bg_count]);
                    bg_count = 0;
                }
                const width: f32 = if (raw.wide == .wide) 2.0 * cw else cw;
                const fx: f32 = @as(f32, @floatFromInt(x)) * cw + x_pad;
                const fy: f32 = @as(f32, @floatFromInt(y)) * ch + y_off;

                const cell_bg = resolveBg(style, &raw, &colors, is_selected, is_inverse, dbg_r, dbg_g, dbg_b);
                bg_buf[bg_count] = .{
                    .pos = .{ fx, fy },
                    .size = .{ width, ch },
                    .color = .{ cell_bg[0], cell_bg[1], cell_bg[2], 1 },
                };
                bg_count += 1;
            }
        }

        if (bg_count > 0) self.drawBgInstances(encoder, bg_buf[0..bg_count]);

        // --- Text pass ---
        for (0..rows) |y| {
            if (y >= all_cells.len) break;
            const cell_slice = all_cells[y].slice();
            const raws = cell_slice.items(.raw);
            const styles = cell_slice.items(.style);
            const graphemes = cell_slice.items(.grapheme);
            const sel_range: ?[2]u16 = if (y < all_sels.len) all_sels[y] else null;

            const fy: f32 = @as(f32, @floatFromInt(y)) * ch + y_off;

            for (0..cols) |x| {
                if (x >= raws.len) break;
                const raw = raws[x];

                const is_text = raw.hasText() and raw.wide != .spacer_tail and raw.wide != .spacer_head and raw.codepoint() != 0;
                if (!is_text) continue;

                const cp = raw.codepoint();

                if (text_count >= MAX_CELLS) {
                    self.drawTextInstances(encoder, text_buf[0..text_count]);
                    text_count = 0;
                }

                // grapheme cluster (VS-16 / skin tone modifier / ZWJ 시퀀스) 면 CTLine
                // 으로 shape — 단일 컬러 emoji 글리프로 reduce. 일반 cell 은 빠른
                // single-codepoint path 그대로.
                const result = blk: {
                    if (raw.hasGrapheme() and x < graphemes.len) {
                        var cluster: [16]u21 = undefined;
                        cluster[0] = cp;
                        const extras = graphemes[x];
                        const take = @min(extras.len, cluster.len - 1);
                        @memcpy(cluster[1..][0..take], extras[0..take]);
                        if (self.font.resolveGrapheme(cluster[0 .. 1 + take])) |r| break :blk r;
                    }
                    break :blk self.font.resolveGlyph(cp) orelse continue;
                };
                const entry = self.atlas.getOrInsert(result.font, @intCast(result.index)) orelse {
                    if (result.owned) ct.CFRelease(result.font);
                    continue;
                };
                if (result.owned) ct.CFRelease(result.font);

                if (entry.w == 0 or entry.h == 0) continue;

                const style = if (raw.style_id != 0) styles[x] else ghostty.Style{};
                const is_inverse = style.flags.inverse;
                const x16: u16 = @intCast(x);
                const is_selected = if (sel_range) |sr| (x16 >= sr[0] and x16 <= sr[1]) else false;
                const fg_rgb = resolveFg(style, &raw, &colors, is_selected, is_inverse);

                // 모든 좌표 pixel 단위. bearing / atlas size / cell_w/h /
                // ascent_px 모두 pixel — font.init 시 scale 곱해 통일됨.
                //
                // bearing_y 는 CG 의 bbox.origin.y * scale (= bbox 의 bottom,
                // baseline-Y-up 좌표). 화면 Y-down 좌표에서 글리프 top 위치는:
                //   gy = cell_top + ascent − top_of_bbox_y_up
                //      = cell_top + ascent − (bearing_y + h)
                // serene-euler #73 의 `offset_y = ascent - (origin.y + size.h)`
                // 와 동일.
                const fx: f32 = @as(f32, @floatFromInt(x)) * cw + x_pad;
                const gx = fx + @as(f32, @floatFromInt(entry.bearing_x));
                const gy = fy + self.font.ascent_px
                    - @as(f32, @floatFromInt(entry.bearing_y))
                    - @as(f32, @floatFromInt(entry.h));

                text_buf[text_count] = .{
                    .pos = .{ gx, gy },
                    .size = .{ @as(f32, @floatFromInt(entry.w)), @as(f32, @floatFromInt(entry.h)) },
                    .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
                    .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                    .fg_color = .{ colorF(fg_rgb.r), colorF(fg_rgb.g), colorF(fg_rgb.b), 1 },
                    .color_flag = if (entry.is_color) 1 else 0,
                };
                text_count += 1;
            }
        }

        if (text_count > 0) self.drawTextInstances(encoder, text_buf[0..text_count]);


        // --- Cursor (단순 박스) ---
        if (self.render_state.cursor.visible) {
            if (self.render_state.cursor.viewport) |vp| {
                var cursor_x: f32 = @floatFromInt(vp.x);
                const cursor_y: f32 = @floatFromInt(vp.y);
                if (vp.wide_tail and vp.x > 0) cursor_x -= 1.0;
                const cx0 = cursor_x * cw + x_pad;
                const cy0 = cursor_y * ch + y_off;
                var cursor_color: [4]f32 = .{ 180.0 / 255.0, 180.0 / 255.0, 180.0 / 255.0, 0.7 };
                if (colors.cursor) |cc| {
                    cursor_color = .{ colorF(cc.r), colorF(cc.g), colorF(cc.b), 0.7 };
                }
                const cursor_inst = [1]BgInstance{.{
                    .pos = .{ cx0, cy0 },
                    .size = .{ cw, ch },
                    .color = cursor_color,
                }};
                self.drawBgInstances(encoder, &cursor_inst);
            }
        }

        // --- Scrollbar (Windows d3d11_renderer 와 동일 패턴) ---
        // pixel 단위. self.scale 곱해 retina pixel 로.
        const sb = terminal.screens.active.pages.scrollbar();
        if (sb.total > sb.len) {
            const sbw: f32 = @as(f32, @floatFromInt(ui_metrics.SCROLLBAR_W_PT)) * self.scale;
            const sb_min: f32 = @as(f32, @floatFromInt(ui_metrics.SCROLLBAR_MIN_THUMB_H_PT)) * self.scale;
            const vp_hf: f32 = @floatFromInt(self.vp_height);
            const vp_wf: f32 = @floatFromInt(self.vp_width);
            const track_h: f32 = vp_hf - @as(f32, @floatFromInt(y_offset + padding));
            const track_x: f32 = vp_wf - sbw;
            const ratio = track_h / @as(f32, @floatFromInt(sb.total));
            const thumb_h = @max(sb_min, ratio * @as(f32, @floatFromInt(sb.len)));
            const available = track_h - thumb_h;
            const max_offset: f32 = @floatFromInt(sb.total - sb.len);
            const thumb_y = y_off + if (max_offset > 0)
                @as(f32, @floatFromInt(sb.offset)) / max_offset * available
            else
                0;
            const scrollbar_inst = [1]BgInstance{.{
                .pos = .{ track_x, thumb_y },
                .size = .{ sbw, thumb_h },
                .color = ui_metrics.SCROLLBAR_COLOR,
            }};
            self.drawBgInstances(encoder, &scrollbar_inst);
        }

        // --- IME preedit (조합 중) overlay ---
        // cursor 위치부터 preedit_utf8 의 각 codepoint 를 그림. 배경 강조 +
        // 글자 + 아래 underline. PTY 에는 안 들어가지만 사용자가 조합 중인
        // 자모 / 음절을 볼 수 있게.
        if (preedit_utf8.len > 0 and self.render_state.cursor.viewport != null) {
            const vp = self.render_state.cursor.viewport.?;
            var pre_col: f32 = @floatFromInt(vp.x);
            const pre_row: f32 = @floatFromInt(vp.y);
            const pre_y = pre_row * ch + y_off;

            var pre_bg_buf: [16]BgInstance = undefined;
            var pre_text_buf: [16]TextInstance = undefined;
            var pre_bg_n: usize = 0;
            var pre_text_n: usize = 0;
            const fg = colors.foreground;
            const fg_color: [4]f32 = .{ colorF(fg.r), colorF(fg.g), colorF(fg.b), 1 };
            // preedit 배경 색 — 약간 진한 회색 / 강조.
            const pre_bg_color: [4]f32 = .{ 0.25, 0.25, 0.5, 1 };

            // UTF-8 codepoint iteration.
            var utf8_iter = std.unicode.Utf8Iterator{ .bytes = preedit_utf8, .i = 0 };
            while (utf8_iter.nextCodepoint()) |cp| {
                if (pre_bg_n >= pre_bg_buf.len) break;
                const result = self.font.resolveGlyph(@intCast(cp)) orelse continue;
                const entry = self.atlas.getOrInsert(result.font, @intCast(result.index)) orelse {
                    if (result.owned) ct.CFRelease(result.font);
                    continue;
                };
                if (result.owned) ct.CFRelease(result.font);

                // wide char (CJK) 는 2 cell 차지.
                const is_wide = cp >= 0x1100 and (cp <= 0x115F or
                    (cp >= 0x2E80 and cp <= 0x9FFF) or
                    (cp >= 0xA000 and cp <= 0xA4CF) or
                    (cp >= 0xAC00 and cp <= 0xD7A3) or
                    (cp >= 0xF900 and cp <= 0xFAFF) or
                    (cp >= 0xFE30 and cp <= 0xFE4F) or
                    (cp >= 0xFF00 and cp <= 0xFF60) or
                    (cp >= 0xFFE0 and cp <= 0xFFE6));
                const w_cells: f32 = if (is_wide) 2 else 1;

                const cell_x = pre_col * cw + x_pad;
                pre_bg_buf[pre_bg_n] = .{
                    .pos = .{ cell_x, pre_y },
                    .size = .{ w_cells * cw, ch },
                    .color = pre_bg_color,
                };
                pre_bg_n += 1;

                if (entry.w > 0 and entry.h > 0 and pre_text_n < pre_text_buf.len) {
                    const gx = cell_x + @as(f32, @floatFromInt(entry.bearing_x));
                    const gy = pre_y + self.font.ascent_px
                        - @as(f32, @floatFromInt(entry.bearing_y))
                        - @as(f32, @floatFromInt(entry.h));
                    pre_text_buf[pre_text_n] = .{
                        .pos = .{ gx, gy },
                        .size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                        .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
                        .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                        .fg_color = fg_color,
                        .color_flag = if (entry.is_color) 1 else 0,
                    };
                    pre_text_n += 1;
                }

                pre_col += w_cells;
            }

            if (pre_bg_n > 0) self.drawBgInstances(encoder, pre_bg_buf[0..pre_bg_n]);
            // atlas 가 dirty 면 다음 frame 에 업로드 — 한 frame 늦은 표시.
            if (pre_text_n > 0) self.drawTextInstances(encoder, pre_text_buf[0..pre_text_n]);
        }
    }

    /// 윈도우 상단 탭바 (#111 M11.4 + M11.4-fix). Windows `D3d11Renderer.renderTabBar`
    /// 와 같은 시각 디자인:
    ///   - 탭바 BG 는 매우 어둡게 (TAB_BAR_BG = 20/255).
    ///   - 비활성 탭 BG = renderer 의 `default_bg` (terminal 배경) → cell grid 와
    ///     자연스럽게 이어짐.
    ///   - 활성 탭 BG = TAB_ACTIVE_BG (50/255) → 어두운 BG 대비 두드러짐.
    ///   - 탭 placement: 좌우 1px + 상하 2px gap 을 두고 sandwich → 그 gap 으로
    ///     TAB_BAR_BG 가 보여 탭의 명확한 윤곽선 역할.
    ///   - 우측 끝에 'x' 글리프 (close 버튼) — dim 회색. 클릭 처리는 M11.5.
    fn drawTabBar(
        self: *MetalRenderer,
        encoder: objc.id,
        tab_titles: []const []const u8,
        active_tab: usize,
        rename_view: ?TabRenameView,
        drag_view: ?TabDragView,
        /// 탭바 스크롤 오프셋 (픽셀, #117). 각 탭 / drag 탭의 화면 x =
        /// `world_x - tab_scroll_x_px + tab_area_x`.
        tab_scroll_x_px: f32,
        /// `<` `>` `+` 버튼 layout. tab_area_x = 화살표 있을 때 ARROW_W.
        layout: TabBarLayout,
    ) void {
        const tab_bar_h_px = @as(f32, @floatFromInt(ui_metrics.TAB_BAR_HEIGHT_PT)) * self.scale;
        const tab_w_px = @as(f32, @floatFromInt(ui_metrics.TAB_WIDTH_PT)) * self.scale;
        const tab_pad_px = @as(f32, @floatFromInt(ui_metrics.TAB_PADDING_PT)) * self.scale;
        const close_size_px = @as(f32, @floatFromInt(ui_metrics.TAB_CLOSE_SIZE_PT)) * self.scale;
        const inactive_bg: [4]f32 = .{ self.default_bg[0], self.default_bg[1], self.default_bg[2], 1.0 };

        const MAX_BG: usize = 64;
        const MAX_TEXT: usize = 512;
        var bg_buf: [MAX_BG]BgInstance = undefined;
        var bg_n: usize = 0;
        var text_buf: [MAX_TEXT]TextInstance = undefined;
        var text_n: usize = 0;

        // 1. 탭바 전체 배경.
        bg_buf[bg_n] = .{
            .pos = .{ 0, 0 },
            .size = .{ @floatFromInt(self.vp_width), tab_bar_h_px },
            .color = ui_metrics.TAB_BAR_BG,
        };
        bg_n += 1;

        // 각 탭의 좌상단 x 좌표 — world (`i × tab_w_px`) - scroll + tab_area_x.
        // tab_area_x 는 화살표 있을 때 ARROW_W (좌측 화살표 자리), 없으면 0.
        // drag.current_x_px 도 *world* 라 같은 변환.
        const tax = layout.tab_area_x;
        const tabXFor = struct {
            fn f(i: usize, w: f32, dv: ?TabDragView, sx: f32, tax_: f32) f32 {
                if (dv) |d| if (d.tab_index == i) return d.current_x_px - w * 0.5 - sx + tax_;
                return @as(f32, @floatFromInt(i)) * w - sx + tax_;
            }
        }.f;

        // 2. 각 탭 배경 — 좌우 1px + 상하 2px sandwich (Windows 패턴). drag 탭은
        //    마지막에 그려서 다른 탭 위에 올라오게.
        for (tab_titles, 0..) |_, i| {
            if (bg_n >= MAX_BG) break;
            if (drag_view) |d| if (d.tab_index == i) continue;
            const tab_x = tabXFor(i, tab_w_px, drag_view, tab_scroll_x_px, tax);
            const color = if (i == active_tab) ui_metrics.TAB_ACTIVE_BG else inactive_bg;
            bg_buf[bg_n] = .{
                .pos = .{ tab_x + 1, 2 },
                .size = .{ @max(tab_w_px - 2, 1), @max(tab_bar_h_px - 4, 1) },
                .color = color,
            };
            bg_n += 1;
        }
        // drag 중인 탭 BG (다른 탭 위에 그려지도록 마지막).
        if (drag_view) |d| if (d.tab_index < tab_titles.len and bg_n < MAX_BG) {
            const tab_x = tabXFor(d.tab_index, tab_w_px, drag_view, tab_scroll_x_px, tax);
            const color = if (d.tab_index == active_tab) ui_metrics.TAB_ACTIVE_BG else inactive_bg;
            bg_buf[bg_n] = .{
                .pos = .{ tab_x + 1, 2 },
                .size = .{ @max(tab_w_px - 2, 1), @max(tab_bar_h_px - 4, 1) },
                .color = color,
            };
            bg_n += 1;
        };

        // 3. 각 탭 제목 텍스트 + close 버튼 (× 글리프).
        const cw: f32 = @floatFromInt(self.font.cell_width);
        const ch: f32 = @floatFromInt(self.font.cell_height);
        const text_y_top: f32 = (tab_bar_h_px - ch) * 0.5;
        // close 버튼 자리 + 양쪽 padding 빼고 남은 영역만 텍스트.
        const max_text_w_px = tab_w_px - close_size_px - tab_pad_px * 3;
        // rename preedit 배경색 (cell preedit 과 동일 — 보라 회색).
        const preedit_bg_color: [4]f32 = .{ 0.25, 0.25, 0.5, 1.0 };

        for (tab_titles, 0..) |orig_title, i| {
            const tab_x = tabXFor(i, tab_w_px, drag_view, tab_scroll_x_px, tax);
            const text_x_start = tab_x + tab_pad_px;
            var text_x = text_x_start;

            // rename 진행 중인 탭이면 그 buf 의 텍스트를 대신 표시 + cursor +
            // preedit (IME 자모) 인라인.
            const renaming_this = if (rename_view) |rv| (rv.tab_index == i) else false;
            const title = if (renaming_this) rename_view.?.text else orig_title;
            const cursor_byte: ?usize = if (renaming_this) rename_view.?.cursor else null;
            const preedit_text: []const u8 = if (renaming_this) rename_view.?.preedit else &.{};

            var byte_idx: usize = 0;
            var cursor_drawn = false;
            var iter = std.unicode.Utf8Iterator{ .bytes = title, .i = 0 };
            while (iter.nextCodepoint()) |cp| {
                if (text_n >= MAX_TEXT) break;
                if (text_x - text_x_start + cw > max_text_w_px) break;

                // cursor 가 이 byte 위치에 와 있으면 1px vertical bar.
                if (cursor_byte) |cb| {
                    if (byte_idx == cb and !cursor_drawn and bg_n < MAX_BG) {
                        bg_buf[bg_n] = .{
                            .pos = .{ text_x, text_y_top + 2 },
                            .size = .{ 1, ch - 4 },
                            .color = ui_metrics.TAB_TEXT_COLOR,
                        };
                        bg_n += 1;
                        cursor_drawn = true;
                    }
                }

                const cp_len = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
                byte_idx += cp_len;

                const result = self.font.resolveGlyph(@intCast(cp)) orelse {
                    text_x += cw;
                    continue;
                };
                const entry = self.atlas.getOrInsert(result.font, @intCast(result.index)) orelse {
                    if (result.owned) ct.CFRelease(result.font);
                    text_x += cw;
                    continue;
                };
                if (result.owned) ct.CFRelease(result.font);

                if (entry.w > 0 and entry.h > 0) {
                    const gx = text_x + @as(f32, @floatFromInt(entry.bearing_x));
                    const gy = text_y_top + self.font.ascent_px
                        - @as(f32, @floatFromInt(entry.bearing_y))
                        - @as(f32, @floatFromInt(entry.h));
                    text_buf[text_n] = .{
                        .pos = .{ gx, gy },
                        .size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                        .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
                        .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                        .fg_color = ui_metrics.TAB_TEXT_COLOR,
                        .color_flag = if (entry.is_color) 1 else 0,
                    };
                    text_n += 1;
                }
                text_x += cw;
            }

            // 끝에 cursor (text 가 cursor 위치를 안 지났을 때 — 예: cursor == title.len).
            if (renaming_this and !cursor_drawn and bg_n < MAX_BG) {
                if (cursor_byte) |cb| if (cb >= title.len) {
                    bg_buf[bg_n] = .{
                        .pos = .{ text_x, text_y_top + 2 },
                        .size = .{ 1, ch - 4 },
                        .color = ui_metrics.TAB_TEXT_COLOR,
                    };
                    bg_n += 1;
                };
            }

            // preedit (IME composition) 인라인 — cursor 뒤에 보라 배경 + 글자.
            if (renaming_this and preedit_text.len > 0) {
                var pre_iter = std.unicode.Utf8Iterator{ .bytes = preedit_text, .i = 0 };
                while (pre_iter.nextCodepoint()) |cp| {
                    if (text_n >= MAX_TEXT or bg_n >= MAX_BG) break;
                    if (text_x - text_x_start + cw > max_text_w_px) break;

                    // 보라색 배경 (cell preedit 과 같은 색).
                    bg_buf[bg_n] = .{
                        .pos = .{ text_x, text_y_top },
                        .size = .{ cw, ch },
                        .color = preedit_bg_color,
                    };
                    bg_n += 1;

                    const result = self.font.resolveGlyph(@intCast(cp)) orelse {
                        text_x += cw;
                        continue;
                    };
                    const entry = self.atlas.getOrInsert(result.font, @intCast(result.index)) orelse {
                        if (result.owned) ct.CFRelease(result.font);
                        text_x += cw;
                        continue;
                    };
                    if (result.owned) ct.CFRelease(result.font);

                    if (entry.w > 0 and entry.h > 0) {
                        const gx = text_x + @as(f32, @floatFromInt(entry.bearing_x));
                        const gy = text_y_top + self.font.ascent_px
                            - @as(f32, @floatFromInt(entry.bearing_y))
                            - @as(f32, @floatFromInt(entry.h));
                        text_buf[text_n] = .{
                            .pos = .{ gx, gy },
                            .size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                            .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
                            .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                            .fg_color = ui_metrics.TAB_TEXT_COLOR,
                            .color_flag = if (entry.is_color) 1 else 0,
                        };
                        text_n += 1;
                    }
                    text_x += cw;
                }
            }

            // close 버튼 'x' — 우측 끝 + tab_pad 위치. 색은 텍스트 60% + 탭
            // 배경 40% (Windows 와 동일 — 너무 강조되지 않게 dim).
            if (text_n < MAX_TEXT) {
                const tab_bg = if (i == active_tab) ui_metrics.TAB_ACTIVE_BG else inactive_bg;
                const close_c: [4]f32 = .{
                    ui_metrics.TAB_TEXT_COLOR[0] * 0.6 + tab_bg[0] * 0.4,
                    ui_metrics.TAB_TEXT_COLOR[1] * 0.6 + tab_bg[1] * 0.4,
                    ui_metrics.TAB_TEXT_COLOR[2] * 0.6 + tab_bg[2] * 0.4,
                    1.0,
                };
                const close_x = tab_x + tab_w_px - close_size_px - tab_pad_px;
                const close_y = (tab_bar_h_px - close_size_px) * 0.5;
                if (self.font.resolveGlyph('x')) |result| {
                    if (self.atlas.getOrInsert(result.font, @intCast(result.index))) |entry| {
                        if (result.owned) ct.CFRelease(result.font);
                        if (entry.w > 0 and entry.h > 0) {
                            // close 박스 (close_size_px × close_size_px) 안에 cell
                            // (cw × ch) 를 중앙 정렬한 가상 cell 의 baseline.
                            const close_baseline = close_y + (close_size_px + self.font.ascent_px - (ch - self.font.ascent_px)) * 0.5;
                            const gx = close_x + (close_size_px - cw) * 0.5 + @as(f32, @floatFromInt(entry.bearing_x));
                            // macOS 좌표계 (cell 글리프와 동일 패턴):
                            //   gy = baseline − bearing_y − h
                            // Windows 는 `+ bearing_y` 인데 그건 DirectWrite 의
                            // bearing_y 부호 정의가 달라서. CoreText 는 baseline
                            // 위쪽이 양수 bearing_y 이고 atlas 의 entry.h 가
                            // 글리프 height 라 위로 올라가야 top.
                            const gy = close_baseline
                                - @as(f32, @floatFromInt(entry.bearing_y))
                                - @as(f32, @floatFromInt(entry.h));
                            text_buf[text_n] = .{
                                .pos = .{ gx, gy },
                                .size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                                .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
                                .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                                .fg_color = close_c,
                                .color_flag = if (entry.is_color) 1 else 0,
                            };
                            text_n += 1;
                        }
                    } else if (result.owned) ct.CFRelease(result.font);
                }
            }
        }

        // 1차 batch — 탭 BG / 텍스트 / cursor / close 글리프 그림.
        if (bg_n > 0) self.drawBgInstances(encoder, bg_buf[0..bg_n]);
        if (text_n > 0) self.drawTextInstances(encoder, text_buf[0..text_n]);

        // #117 — 2차 batch: 화살표 / + 영역. 탭 BG / 텍스트 *후* 에 별도 batch 로
        // 그려야 viewport 끝에서 잘리는 첫/마지막 탭의 글자가 화살표 영역에 침범
        // 한 부분이 덮여 가려짐 (사용자 제안: 탭 너비 줄이는 효과).
        bg_n = 0;
        text_n = 0;
        if (layout.arrows_visible) {
            bg_buf[bg_n] = .{
                .pos = .{ layout.left_arrow_x, 0 },
                .size = .{ layout.arrow_w, tab_bar_h_px },
                .color = ui_metrics.TAB_BAR_BG,
            };
            bg_n += 1;
            bg_buf[bg_n] = .{
                .pos = .{ layout.right_arrow_x, 0 },
                .size = .{ layout.arrow_w, tab_bar_h_px },
                .color = ui_metrics.TAB_BAR_BG,
            };
            bg_n += 1;
        }
        bg_buf[bg_n] = .{
            .pos = .{ layout.plus_x, 0 },
            .size = .{ layout.plus_w, tab_bar_h_px },
            .color = ui_metrics.TAB_BAR_BG,
        };
        bg_n += 1;

        // 글리프 `<` `>` `+` — 박스 안 cw × ch 가운데 정렬. 활성 / 비활성 색 분리.
        const drawCtrlGlyph = struct {
            fn run(rself: *MetalRenderer, codepoint: u21, box_x: f32, box_w: f32, tbh: f32, cw_: f32, ch_: f32, color: [4]f32, buf: []TextInstance, n: *usize) void {
                if (n.* >= buf.len) return;
                const result = rself.font.resolveGlyph(@intCast(codepoint)) orelse return;
                const entry = rself.atlas.getOrInsert(result.font, @intCast(result.index)) orelse {
                    if (result.owned) ct.CFRelease(result.font);
                    return;
                };
                if (result.owned) ct.CFRelease(result.font);
                if (entry.w == 0 or entry.h == 0) return;
                const baseline_top = (tbh - ch_) * 0.5;
                const gx = box_x + (box_w - cw_) * 0.5 + @as(f32, @floatFromInt(entry.bearing_x));
                const gy = baseline_top + rself.font.ascent_px
                    - @as(f32, @floatFromInt(entry.bearing_y))
                    - @as(f32, @floatFromInt(entry.h));
                buf[n.*] = .{
                    .pos = .{ gx, gy },
                    .size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                    .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
                    .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                    .fg_color = color,
                    .color_flag = if (entry.is_color) 1 else 0,
                };
                n.* += 1;
            }
        }.run;

        if (layout.arrows_visible) {
            const left_color = if (layout.left_enabled) ui_metrics.TAB_CTRL_ACTIVE_COLOR else ui_metrics.TAB_ARROW_DISABLED_COLOR;
            const right_color = if (layout.right_enabled) ui_metrics.TAB_CTRL_ACTIVE_COLOR else ui_metrics.TAB_ARROW_DISABLED_COLOR;
            drawCtrlGlyph(self, '<', layout.left_arrow_x, layout.arrow_w, tab_bar_h_px, cw, ch, left_color, &text_buf, &text_n);
            drawCtrlGlyph(self, '>', layout.right_arrow_x, layout.arrow_w, tab_bar_h_px, cw, ch, right_color, &text_buf, &text_n);
        }
        drawCtrlGlyph(self, '+', layout.plus_x, layout.plus_w, tab_bar_h_px, cw, ch, ui_metrics.TAB_CTRL_ACTIVE_COLOR, &text_buf, &text_n);

        if (bg_n > 0) self.drawBgInstances(encoder, bg_buf[0..bg_n]);
        if (text_n > 0) self.drawTextInstances(encoder, text_buf[0..text_n]);
    }

    fn updateConstants(self: *MetalRenderer) void {
        const contents_ptr = objc.msgSend(self.constants_buffer, objc.sel("contents")) orelse return;
        const data: *[4]f32 = @ptrCast(@alignCast(contents_ptr));
        data.* = .{
            @floatFromInt(self.vp_width),
            @floatFromInt(self.vp_height),
            @floatFromInt(ATLAS_SIZE),
            @floatFromInt(ATLAS_SIZE),
        };
    }

    fn uploadAtlas(self: *MetalRenderer) void {
        const Region = extern struct { ox: usize, oy: usize, oz: usize, sx: usize, sy: usize, sz: usize };
        const region = Region{ .ox = 0, .oy = 0, .oz = 0, .sx = ATLAS_SIZE, .sy = ATLAS_SIZE, .sz = 1 };

        const f: *const fn (objc.id, objc.SEL, Region, objc.NSUInteger, [*]const u8, objc.NSUInteger) callconv(.c) void = @ptrCast(objc.msgSend_raw);
        f(
            self.atlas_texture,
            objc.sel("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"),
            region,
            0,
            self.atlas.pixels.ptr,
            ATLAS_SIZE * 4, // BGRA8 = 4 bytes per pixel.
        );
    }

    fn drawBgInstances(self: *MetalRenderer, encoder: objc.id, instances: []const BgInstance) void {
        if (instances.len == 0) return;
        if (self.bg_used + instances.len > MAX_INSTANCES) return;

        const contents_ptr = objc.msgSend(self.bg_buffer, objc.sel("contents")) orelse return;
        const contents: [*]BgInstance = @ptrCast(@alignCast(contents_ptr));
        // 같은 frame 의 이전 호출들이 쓴 데이터 뒤에 append. 첫 selected cell
        // 이 cursor / scrollbar 호출에 의해 instance[0] 위치에서 overwrite
        // 되던 buffer race 해결.
        @memcpy(contents[self.bg_used..][0..instances.len], instances);

        const offset_bytes: objc.NSUInteger = @as(objc.NSUInteger, self.bg_used) * @sizeOf(BgInstance);

        objc.msgSendVoid1(encoder, objc.sel("setRenderPipelineState:"), self.bg_pipeline);
        objc.msgSendVoid3(encoder, objc.sel("setVertexBuffer:offset:atIndex:"), self.bg_buffer, offset_bytes, @as(objc.NSUInteger, 0));
        objc.msgSendVoid3(encoder, objc.sel("setVertexBuffer:offset:atIndex:"), self.constants_buffer, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 1));

        // MTLPrimitiveTypeTriangleStrip = 4.
        objc.msgSendVoid4(
            encoder,
            objc.sel("drawPrimitives:vertexStart:vertexCount:instanceCount:"),
            @as(objc.NSUInteger, 4),
            @as(objc.NSUInteger, 0),
            @as(objc.NSUInteger, 4),
            @as(objc.NSUInteger, instances.len),
        );

        self.bg_used += @intCast(instances.len);
    }

    fn drawTextInstances(self: *MetalRenderer, encoder: objc.id, instances: []const TextInstance) void {
        if (instances.len == 0) return;
        if (self.text_used + instances.len > MAX_INSTANCES) return;

        const contents_ptr = objc.msgSend(self.text_buffer, objc.sel("contents")) orelse return;
        const contents: [*]TextInstance = @ptrCast(@alignCast(contents_ptr));
        @memcpy(contents[self.text_used..][0..instances.len], instances);

        const offset_bytes: objc.NSUInteger = @as(objc.NSUInteger, self.text_used) * @sizeOf(TextInstance);

        objc.msgSendVoid1(encoder, objc.sel("setRenderPipelineState:"), self.text_pipeline);
        objc.msgSendVoid3(encoder, objc.sel("setVertexBuffer:offset:atIndex:"), self.text_buffer, offset_bytes, @as(objc.NSUInteger, 0));
        objc.msgSendVoid3(encoder, objc.sel("setVertexBuffer:offset:atIndex:"), self.constants_buffer, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 1));
        objc.msgSendVoid2(encoder, objc.sel("setFragmentTexture:atIndex:"), self.atlas_texture, @as(objc.NSUInteger, 0));

        objc.msgSendVoid4(
            encoder,
            objc.sel("drawPrimitives:vertexStart:vertexCount:instanceCount:"),
            @as(objc.NSUInteger, 4), // TriangleStrip
            @as(objc.NSUInteger, 0),
            @as(objc.NSUInteger, 4),
            @as(objc.NSUInteger, instances.len),
        );

        self.text_used += @intCast(instances.len);
    }

    // --- Helpers ---

    fn createPipeline(device: objc.id, vs: objc.id, fs: objc.id) !objc.id {
        const desc_class = objc.getClass("MTLRenderPipelineDescriptor");
        const desc = objc.msgSend(objc.msgSend(desc_class, objc.sel("alloc")), objc.sel("init"));

        objc.msgSendVoid1(desc, objc.sel("setVertexFunction:"), vs);
        objc.msgSendVoid1(desc, objc.sel("setFragmentFunction:"), fs);

        const attachments = objc.msgSend(desc, objc.sel("colorAttachments"));
        const att0 = objc.msgSend1(attachments, objc.sel("objectAtIndexedSubscript:"), @as(objc.NSUInteger, 0));
        objc.msgSendVoid1(att0, objc.sel("setPixelFormat:"), @as(objc.NSUInteger, 80)); // BGRA8Unorm

        // 텍스트 + 배경 둘 다 alpha 블렌딩 (커서 / 셀 투명도 + 컬러 emoji 용).
        // Premultiplied output → blend factor (One, OneMinusSourceAlpha).
        // Atlas 가 BGRA premult 라 셰이더 출력도 premult 로 통일 (#132).
        objc.msgSendVoid1(att0, objc.sel("setBlendingEnabled:"), objc.YES);
        objc.msgSendVoid1(att0, objc.sel("setSourceRGBBlendFactor:"), @as(objc.NSUInteger, 1)); // One
        objc.msgSendVoid1(att0, objc.sel("setDestinationRGBBlendFactor:"), @as(objc.NSUInteger, 5)); // OneMinusSourceAlpha
        objc.msgSendVoid1(att0, objc.sel("setSourceAlphaBlendFactor:"), @as(objc.NSUInteger, 1));
        objc.msgSendVoid1(att0, objc.sel("setDestinationAlphaBlendFactor:"), @as(objc.NSUInteger, 5));

        var err: objc.id = null;
        const pipeline = objc.msgSend2(device, objc.sel("newRenderPipelineStateWithDescriptor:error:"), desc, @as(*objc.id, &err));
        if (pipeline == null) {
            if (err) |e| {
                const edesc = objc.msgSend(e, objc.sel("localizedDescription"));
                if (edesc) |d| {
                    const cstr_ptr = objc.msgSend(d, objc.sel("UTF8String"));
                    if (cstr_ptr) |p| {
                        const cstr: [*:0]const u8 = @ptrCast(p);
                        std.log.err("Pipeline error: {s}", .{cstr});
                    }
                }
            }
            return error.PipelineFailed;
        }
        return pipeline;
    }

    fn createBuffer(device: objc.id, size: u32) objc.id {
        // MTLResourceStorageModeShared = 0
        return objc.msgSend2(device, objc.sel("newBufferWithLength:options:"), @as(objc.NSUInteger, size), @as(objc.NSUInteger, 0));
    }

    fn createAtlasTexture(device: objc.id) objc.id {
        const desc_class = objc.getClass("MTLTextureDescriptor");
        const desc = objc.msgSend(objc.msgSend(desc_class, objc.sel("alloc")), objc.sel("init"));

        // BGRA8Unorm — atlas 가 premultiplied BGRA. 일반 글리프엔 (a,a,a,a) 가
        // 들어가고 컬러 글리프엔 본래 색이 들어감 (#132).
        objc.msgSendVoid1(desc, objc.sel("setPixelFormat:"), @as(objc.NSUInteger, 80)); // BGRA8Unorm
        objc.msgSendVoid1(desc, objc.sel("setWidth:"), @as(objc.NSUInteger, ATLAS_SIZE));
        objc.msgSendVoid1(desc, objc.sel("setHeight:"), @as(objc.NSUInteger, ATLAS_SIZE));
        objc.msgSendVoid1(desc, objc.sel("setUsage:"), @as(objc.NSUInteger, 1)); // ShaderRead

        return objc.msgSend1(device, objc.sel("newTextureWithDescriptor:"), desc);
    }
};

// --- 색상 해석 (Windows renderer 와 같은 규칙) ---

fn resolveBg(
    style: ghostty.Style,
    raw: *const ghostty.Cell,
    colors: *const ghostty.RenderState.Colors,
    is_selected: bool,
    is_inverse: bool,
    dbg_r: f32,
    dbg_g: f32,
    dbg_b: f32,
) [3]f32 {
    if (is_selected) return .{ 0.25, 0.45, 0.75 };
    if (is_inverse) {
        const fg = style.fg(.{ .default = colors.foreground, .palette = &colors.palette });
        return .{ MetalRenderer.colorF(fg.r), MetalRenderer.colorF(fg.g), MetalRenderer.colorF(fg.b) };
    }
    if (style.bg(raw, &colors.palette)) |bg_col| {
        return .{ MetalRenderer.colorF(bg_col.r), MetalRenderer.colorF(bg_col.g), MetalRenderer.colorF(bg_col.b) };
    }
    return .{ dbg_r, dbg_g, dbg_b };
}

fn resolveFg(
    style: ghostty.Style,
    raw: *const ghostty.Cell,
    colors: *const ghostty.RenderState.Colors,
    is_selected: bool,
    is_inverse: bool,
) ghostty.color.RGB {
    if (is_selected) return colors.foreground;
    if (is_inverse) {
        if (style.bg(raw, &colors.palette)) |bg_col| return bg_col;
        return colors.background;
    }
    return style.fg(.{ .default = colors.foreground, .palette = &colors.palette });
}
