// Metal terminal renderer — Windows 의 `src/d3d11_renderer.zig` 와 같은 역할.
// 인스턴스드 쿼드 (한 cell = 한 quad instance) 로 배경 + 글리프 텍스트 그림.
// macOS 는 grayscale antialias 만 지원 (Mojave+) 이라 ClearType 서브픽셀 셰이더
// 불필요. 셰이더 / 셀 파이프라인이 Windows 보다 단순.
//
// #75 (claude/infallible-swartz) 의 macos/renderer.zig 패턴 그대로 차용 +
// 우리 nullable `id` (?*opaque) 와 평면 모듈 구조에 맞춰 정리.

const std = @import("std");
const objc = @import("../macos_objc.zig");
const perf = @import("../perf.zig");
const ct = @import("../font/macos/coretext.zig");
const mac_font = @import("../font/macos/font.zig");
const CoreTextFontContext = mac_font.CoreTextFontContext;
const font_spec = @import("../font/spec.zig");
const font_constants = @import("../font/constants.zig");
const macos_glyph_atlas = @import("macos/glyph_atlas.zig");
const ui_metrics = @import("../ui_metrics.zig");
const chrome_palette = @import("../chrome_palette.zig");
const themes = @import("../themes.zig");
const Runtime = @import("../runtime.zig").Runtime;
const scrollbar = @import("../scrollbar.zig");
const GlyphAtlas = macos_glyph_atlas.GlyphAtlas;
const ATLAS_SIZE = macos_glyph_atlas.ATLAS_SIZE;
const ghostty = @import("ghostty-vt");
const display_width = @import("../font/display_width.zig");
const block_element = @import("block_element.zig");
const box_drawing = @import("../box_drawing.zig");
const cell_color = @import("cell_color.zig");
const cell_decoration = @import("cell_decoration.zig");
const pane_draw = @import("pane_draw.zig");
const pane_layout = @import("../pane_layout.zig");
const tab_layout = @import("../tab_layout.zig");
const tab_chrome = @import("../tab_chrome.zig");
const ui_rect = @import("../ui_rect.zig");
const tab_icons = @import("../tab_icons.zig");
const session_core = @import("../session_core.zig");
const tab_interaction = @import("../tab_interaction.zig");
const command_menu = @import("../command_menu.zig");
const ligature_mod = @import("../font/ligature.zig");
const isLigatureCandidate = ligature_mod.isLigatureCandidate;

const MAX_INSTANCES: u32 = 32768;

// --- #255 Phase 2: CADisplayLink pause 합성 게이트 ---
// drawable 이 *실제로 화면에 표시*됐는지 확인하는 신호. host 가 idle 시 displayLink
// 를 pause 하려면 "show 직후 첫 프레임이 합성(composite)됐다"를 알아야 한다 — 안
// 그러면 합성 전 1프레임만 그리고 멈춰 빈 화면(#252 의 근본). `addPresentedHandler:`
// 는 drawable 이 표시된 *직후* 호출되고 `presentedTime>0` 이면 표시 확정. 핸들러는
// CoreAnimation presentation 스레드에서 불리므로 atomic. captures 없는 global block.
const BlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};
const PresentedBlock = extern struct {
    isa: ?*const anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const fn (*PresentedBlock, objc.id) callconv(.c) void,
    descriptor: *const BlockDescriptor,
};
extern const _NSConcreteGlobalBlock: anyopaque;
const BLOCK_IS_GLOBAL: c_int = 1 << 28;
var g_frame_presented = std.atomic.Value(bool).init(false);

fn presentedInvoke(_: *PresentedBlock, drawable: objc.id) callconv(.c) void {
    if (drawable == null) return;
    const presentedTimeOf = objc.objcSend(fn (objc.id, objc.SEL) callconv(.c) f64);
    if (presentedTimeOf(drawable, objc.sel("presentedTime")) > 0)
        g_frame_presented.store(true, .seq_cst);
}
var presented_block_descriptor: BlockDescriptor = .{ .reserved = 0, .size = @sizeOf(PresentedBlock) };
var presented_block: PresentedBlock = .{
    .isa = null, // 런타임에 _NSConcreteGlobalBlock 로 설정 (extern 주소는 comptime 불가).
    .flags = BLOCK_IS_GLOBAL,
    .reserved = 0,
    .invoke = &presentedInvoke,
    .descriptor = &presented_block_descriptor,
};

/// 마지막 show 이후 drawable 이 화면에 표시된 적 있나 (host 의 pause 게이트).
pub fn frameWasPresented() bool {
    return g_frame_presented.load(.seq_cst);
}
/// show(hidden→visible) 시 host 가 호출 — 재합성 필요하므로 표시 확정 리셋.
pub fn resetFramePresented() void {
    g_frame_presented.store(false, .seq_cst);
}

// --- Instance data layouts (MSL struct 와 일치해야 함) ---

const BgInstance = extern struct {
    pos: [2]f32,
    size: [2]f32,
    color: [4]f32,
    /// 0 = solid fill. 1/2/3 = U+2591/2/3 LIGHT/MEDIUM/DARK SHADE — fragment
    /// 셰이더가 픽셀 parity 로 dot mask 계산 + discard. block_element.zig 와
    /// d3d11 의 BgInstance.shade 와 동일 의미 (#155).
    shade: f32 = 0,
    /// MSL `float4` 16-byte align — 36 bytes 면 다음 multiple-of-16 (48) 으로
    /// stride padding 되어 instance[1] 부터 깨짐. 12 bytes 명시 padding 으로
    /// stride = 48 고정.
    _pad: [3]f32 = .{ 0, 0, 0 },
};

/// #343 — 공통 `tab_chrome.Rect` 를 Metal `BgInstance` 로. 필드가 이미 같은
/// shape 라 옮기기만 한다 (`shade` / `_pad` 는 기본값).
fn bgFromChrome(r: tab_chrome.Rect) BgInstance {
    return .{ .pos = .{ r.x, r.y }, .size = .{ r.w, r.h }, .color = r.color };
}

/// #483 5단계 — 정수 px 사각형 (분할선 · amber 선 · 드래그 고스트) → 배경 인스턴스.
fn rectInstance(r: pane_layout.Rect, color: [4]f32) BgInstance {
    return .{ .pos = .{ @floatFromInt(r.x), @floatFromInt(r.y) }, .size = .{ @floatFromInt(r.w), @floatFromInt(r.h) }, .color = color };
}

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
    \\struct BgInst { float2 pos; float2 size; float4 color; float shade; };
    \\struct BgOut { float4 position [[position]]; float4 color; float shade; };
    \\
    \\vertex BgOut bg_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
    \\    const device BgInst* inst [[buffer(0)]], constant float4& sa [[buffer(1)]]) {
    \\    float2 c = float2(vid & 1, vid >> 1);
    \\    float2 px = (inst[iid].pos + c * inst[iid].size) / sa.xy * 2.0 - 1.0;
    \\    BgOut o; o.position = float4(px.x, -px.y, 0, 1);
    \\    o.color = inst[iid].color;
    \\    o.shade = inst[iid].shade;
    \\    return o;
    \\}
    \\fragment float4 bg_fs(BgOut in [[stage_in]]) {
    \\    if (in.shade > 0.5) {
    \\        // Procedural shade pattern — d3d11_renderer.zig bg_shader_src 동등.
    \\        // 픽셀 parity 로 dot mask 계산 후 discard. 폰트 무관.
    \\        int2 px = int2(in.position.xy);
    \\        if (in.shade < 1.5) {
    \\            // U+2591 LIGHT 25% — diagonal sparse: ON at (px + 2*py) % 4 == 0
    \\            if (((px.x + 2 * px.y) & 3) != 0) discard_fragment();
    \\        } else if (in.shade < 2.5) {
    \\            // U+2592 MEDIUM 50% — checkerboard
    \\            if (((px.x + px.y) & 1) != 0) discard_fragment();
    \\        } else {
    \\            // U+2593 DARK 75% — LIGHT 의 inverse (diagonal dense)
    \\            if (((px.x + 2 * px.y) & 3) == 0) discard_fragment();
    \\        }
    \\    }
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

/// 탭바 layout (#117 Firefox 패턴) — cross-platform `tab_layout.Layout` 그대로
/// 사용 (#163 4-i-2). 호출처 host 가 `tab_layout.compute()` 결과를 그대로 넘김
/// — renderer struct 변환 cast block 사라짐.
pub const TabBarLayout = tab_layout.Layout;

/// renderTabBar 가 받은 인자를 endFrame 까지 전달. tabs 는 z-order 상
/// terminal 위에 그려져야 하므로 실제 encode 는 endFrame 에서.
const PendingTabs = struct {
    titles: []const []const u8,
    active: usize,
    drag_view: ?tab_interaction.DragView,
    scroll_x_px: f32,
    layout: TabBarLayout,
    hover: tab_layout.Area,
};

pub const MetalRenderer = struct {
    /// #451 — `applyScale` 이 나중에 폰트를 다시 만들 때도 폰트 미설치 fatal 경로를
    /// 타므로, `alloc` · `font_families` 와 같은 자리에 함께 보관한다.
    rt: Runtime,
    alloc: std.mem.Allocator,
    font: CoreTextFontContext,
    atlas: GlyphAtlas,
    tab_font: CoreTextFontContext,
    tab_atlas: GlyphAtlas,

    // Metal 객체 (모두 ObjC id, 우리는 ARC 안 쓰지만 process 종료 시 회수).
    device: objc.id,
    /// CAMetalLayer — init 에서 받아 보관. drawable 획득 시점이 매 frame
    /// 다르므로 host 가 매번 인자로 줄 필요 없도록 self 안에 보관 (Windows
    /// D3d11Renderer 의 hwnd / rtv 보관 패턴과 같은 의도).
    layer: objc.id,
    command_queue: objc.id,
    bg_pipeline: objc.id,
    text_pipeline: objc.id,
    bg_buffer: objc.id,
    text_buffer: objc.id,
    atlas_texture: objc.id,
    tab_atlas_texture: objc.id,
    constants_buffer: objc.id,

    // frame 내 누적된 instance 수. 매 drawBgInstances / drawTextInstances 호출이
    // 같은 buffer 의 *다음 offset* 에 쓰고 setVertexBuffer offset 도 그에 맞게.
    // 같은 frame 안에서 여러 호출 (cell bg → cursor → scrollbar → preedit) 의
    // 데이터가 buffer 안에서 서로 덮어쓰지 않게. renderTabBar 시작 시 0 reset.
    bg_used: u32 = 0,
    text_used: u32 = 0,

    // 현재 buffer 가 담을 수 있는 instance 수. 초기 MAX_INSTANCES, 수요 초과 시
    // frame 시작에서 키운다 (monotonic). box-drawing 은 MAX_RECTS=384 까지 분해돼
    // 화면 가득 + 큰 선택(선택 cell 마다 배경 instance)이 겹치면 32768 을 쉽게
    // 넘어, 초과분 draw 가 silent drop 되어 선택과 무관한 box 선까지 사라졌었다.
    bg_capacity: u32 = MAX_INSTANCES,
    text_capacity: u32 = MAX_INSTANCES,

    // #399 — cluster shaping 을 런 단위로 묶는 데 쓰는 작업 버퍼다. 셀 루프의 지역 변수로
    // 두면 13 KB 가량이라 (cluster 당 최대 17 codepoint × 128) 프레임 스택에 부담이라
    // renderer 가 들고 재사용한다. `render` 시간의 92 % 가 shaping 이고 cluster 마다
    // `CTLine` 을 새로 만드는 고정 비용이 그 대부분이다.
    /// 런 안 cluster 들의 codepoint 를 이어 담는다 (base 1 + extras 최대 16).
    run_cps: [CoreTextFontContext.MAX_RUN_CLUSTERS * 17]u21 = undefined,
    /// 위 버퍼를 cluster 단위로 가리키는 slice 들. `resolveGraphemeRun` 의 입력이다.
    run_slices: [CoreTextFontContext.MAX_RUN_CLUSTERS][]const u21 = undefined,
    /// 각 cluster 가 있던 셀의 x. 글리프를 되돌려 놓을 때 쓴다 (셀마다 색이 다르다).
    run_cells: [CoreTextFontContext.MAX_RUN_CLUSTERS]u16 = undefined,
    /// shaping 결과. cluster 당 하나다.
    run_glyphs: [CoreTextFontContext.MAX_RUN_CLUSTERS]mac_font.GlyphResult = undefined,
    // 이번 frame 이 그리려 *요청한* 총 instance 수 (drop 포함). frame 시작에서
    // capacity 와 비교해 버퍼 확대 판단 후 0 reset. capacity 와 달리 drop 된 것도 셈.
    bg_needed: u32 = 0,
    text_needed: u32 = 0,

    // Frame in progress — renderTabBar 가 begin (drawable + cmd_buf + encoder
    // 생성 + clear), drawPane 이 pane 마다 encode, endFrame 이 end (탭바 encode +
    // present + commit).
    // Windows 의 self.rtv 패턴과 같은 의도. null = frame 진행 중 아님.
    current_drawable: objc.id = null,
    current_cmd_buf: objc.id = null,
    current_encoder: objc.id = null,
    /// renderTabBar 가 받은 args 보관. endFrame 에서 z-order 상 terminal
    /// 위에 tabs 가 그려지도록 마지막에 encode (Windows 와 layout 자체가 분리
    /// 영역이라 z-order 무관하지만, 같은 frame state 의 일부로 처리).
    pending_tabs: ?PendingTabs = null,

    // active terminal 이 배경색을 제공하지 않을 때만 쓰는 init theme fallback.
    fallback_bg: [3]f32,

    /// #335 — theme 배경에서 파생한 탭바 / command menu chrome 색. theme 은
    /// runtime 에 바뀌지 않으므로 init 에서 한 번 계산해 보관한다. 탭바 그리기는
    /// `ui_metrics` 색 상수를 직접 참조하지 않고 이 값만 쓴다.
    chrome: chrome_palette.Palette,

    // viewport (pixel 단위).
    vp_width: u32 = 0,
    vp_height: u32 = 0,

    // Retina backing scale.
    scale: f32,

    /// #376 — 직전 프레임에 blink 셀이 화면에 있었나. host 의 렌더 게이트가 이
    /// 값과 위상 전환을 **함께** 봐서, blink 이 실제로 보일 때만 초당 2프레임을
    /// 추가로 그린다. "blink 셀이 있다" 만으로 게이트를 열면 매 vsync 그리게 돼
    /// #255 의 절전 이득이 사라진다.
    saw_blink_cell: bool = false,
    /// #483 2단계 ② — 이 프레임에 `drawPane` 이 불린 횟수. `renderTabBar` 가 0 으로 되돌리고, 첫
    /// pane 이 `saw_blink_cell` 을 리셋하며 `render_t0` 를 찍는다.
    panes_drawn: u32 = 0,
    render_t0: @TypeOf(perf.now()) = undefined,

    // #253 — 다른 scale 모니터로 이동 시 cell 재측정(applyScale)에 필요한 init
    // 파라미터 보관. font_families 슬라이스/문자열은 host 가 process lifetime 으로
    // 보유(g_config 또는 run() 의 env_chain) — 재init 시 그대로 재사용.
    font_families: []const []const u8,
    terminal_font: font_spec.Spec,

    pub fn colorF(v: u8) f32 {
        return @as(f32, @floatFromInt(v)) / 255.0;
    }

    pub fn init(
        rt: Runtime,
        alloc: std.mem.Allocator,
        device: objc.id,
        layer: objc.id,
        font_families: []const []const u8,
        terminal_font: font_spec.Spec,
        bg_rgb: ?[3]u8,
        scale: f32,
    ) !MetalRenderer {
        const bg = bg_rgb orelse [3]u8{ 30, 30, 30 };

        const cmd_queue = objc.msgSend(device, objc.sel("newCommandQueue"));

        var font_ctx = try CoreTextFontContext.init(
            rt,
            alloc,
            font_families,
            terminal_font,
            scale,
        );
        errdefer font_ctx.deinit();

        var glyph_atlas = try GlyphAtlas.init(alloc, terminal_font.size_logical, scale);
        errdefer glyph_atlas.deinit();
        // #421 — 위 결합 기호를 여기에 맞춰 높이를 고른다. `ascent_px` 는 물리 픽셀이라
        // atlas 가 쓰는 pt 단위로 되돌린다 (atlas 안에서 다시 `scale` 을 곱한다).
        glyph_atlas.ascent_pt = font_ctx.ascent_px / font_ctx.retina_scale;

        const tab_spec = ui_metrics.tabLabelFontSpec();
        var tab_font_ctx = try CoreTextFontContext.init(
            rt,
            alloc,
            font_families,
            tab_spec,
            scale,
        );
        errdefer tab_font_ctx.deinit();

        var tab_glyph_atlas = try GlyphAtlas.init(alloc, tab_spec.size_logical, scale);
        errdefer tab_glyph_atlas.deinit();

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
        const tab_atlas_tex = createAtlasTexture(device);

        // CAMetalLayer 설정 (device 등록 + pixel format).
        objc.msgSendVoid1(layer, objc.sel("setDevice:"), device);
        objc.msgSendVoid1(layer, objc.sel("setPixelFormat:"), @as(objc.NSUInteger, 80)); // BGRA8Unorm

        // #349 — layer 색공간을 sRGB 로 명시. 우리 색 상수는 sRGB 로 설계 · 튜닝됐고
        // (#334 / #342 anchor, #335 파생식) window server 는 이 태그를 보고 디스플레이
        // 색공간으로 변환한다.
        //
        // 명시하는 이유: 바로 위 `setPixelFormat:` 호출이 colorspace 를 자동으로
        // `kCGColorSpaceSRGB` 로 채우는데 (실측) 이건 문서에 없는 동작이다. Apple 문서와
        // `CAMetalLayer.h` 가 적어 둔 기본값은 `nil` = "no colormatching" 이라, 문서만
        // 읽으면 우리가 색 변환을 안 한다고 정반대로 이해하게 된다. 자동 기본값에
        // 색 정확성을 맡기지 않고 같은 값을 직접 넣는다 — 실측으로 자동값과 **같은
        // 싱글턴 인스턴스**라 픽셀은 한 비트도 바뀌지 않는다.
        //
        // null 이면 지정하지 않는다: `colorspace = nil` 은 변환을 없애서 wide-gamut
        // 디스플레이에서 실제로 색이 진해진다 (실측: amber `#F7A41D` 가 P3 원색으로).
        if (ct.CGColorSpaceCreateWithName(ct.kCGColorSpaceSRGB)) |cs| {
            defer ct.CGColorSpaceRelease(cs);
            objc.msgSendVoid1(layer, objc.sel("setColorspace:"), cs);
        } else {
            std.log.warn("sRGB 색공간 생성 실패 — layer colorspace 를 그대로 둠", .{});
        }

        return .{
            .rt = rt,
            .alloc = alloc,
            .font = font_ctx,
            .atlas = glyph_atlas,
            .tab_font = tab_font_ctx,
            .tab_atlas = tab_glyph_atlas,
            .device = device,
            .layer = layer,
            .command_queue = cmd_queue,
            .bg_pipeline = bg_pipeline,
            .text_pipeline = text_pipeline,
            .bg_buffer = bg_buf,
            .text_buffer = text_buf,
            .atlas_texture = atlas_tex,
            .tab_atlas_texture = tab_atlas_tex,
            .constants_buffer = const_buf,
            .fallback_bg = .{ colorF(bg[0]), colorF(bg[1]), colorF(bg[2]) },
            .chrome = chrome_palette.derive(bg, themes.isDarkRgb(bg[0], bg[1], bg[2])),
            .scale = scale,
            .font_families = font_families,
            .terminal_font = terminal_font,
        };
    }

    /// #253 — backingScaleFactor 가 바뀐 모니터로 이동했을 때 호출. 새 scale 의
    /// pixel 크기로 폰트 cell 을 재측정하고 glyph atlas 를 재구성한다(Windows
    /// `rebuildFontForDpi` / Linux `applyScale` 동등). 안 하면 init scale 의 cell·
    /// glyph·UI metric 을 그대로 써서 다른 scale 모니터에서 글자/탭바가 배율만큼
    /// 틀어진다. scale 이 실제로 바뀐 경우에만 호출(같은 scale 이동은 viewport 만).
    pub fn applyScale(self: *MetalRenderer, new_scale: f32) !void {
        if (new_scale == self.scale) return;

        // 1. 새 scale 로 폰트 cell 재측정. 성공 후에만 기존 font 교체(실패 시 unchanged).
        var new_font = try CoreTextFontContext.init(
            self.rt,
            self.alloc,
            self.font_families,
            self.terminal_font,
            new_scale,
        );
        errdefer new_font.deinit();

        var new_tab_font = try CoreTextFontContext.init(
            self.rt,
            self.alloc,
            self.font_families,
            ui_metrics.tabLabelFontSpec(),
            new_scale,
        );
        errdefer new_tab_font.deinit();

        self.tab_font.deinit();
        self.font.deinit();
        self.font = new_font;
        self.tab_font = new_tab_font;

        // 2. atlas 를 새 scale 로 재구성 — cache/packing/pixels clear + scale 갱신.
        //    다음 render 에서 글리프가 새 scale 로 재라스터되고 dirty 로 재업로드됨.
        //    (atlas_texture 자체는 ATLAS_SIZE 고정이라 재사용.)
        self.atlas.scale = new_scale;
        self.atlas.ascent_pt = self.font.ascent_px / self.font.retina_scale;
        self.atlas.reset();
        self.tab_atlas.scale = new_scale;
        self.tab_atlas.reset();

        // 3. renderer scale 갱신 — 탭바/스크롤바/패딩 등 UI metric 이 곱해 쓰는 값.
        self.scale = new_scale;
    }

    pub fn deinit(self: *MetalRenderer) void {
        self.tab_atlas.deinit();
        self.tab_font.deinit();
        self.atlas.deinit();
        self.font.deinit();
        // Metal 객체는 ARC / process exit 으로 정리.
    }

    pub fn resize(self: *MetalRenderer, width: u32, height: u32) void {
        self.vp_width = width;
        self.vp_height = height;
    }

    /// Frame begin — drawable + cmd_buf + encoder 생성, clear color 설정. 받은
    /// tab args 는 self.pending_tabs 에 보관, 실제 encode 는 `endFrame` 에서
    /// (terminal 위에 그려지도록). Windows D3d11Renderer.renderTabBar 의 setupFrame
    /// + clear 패턴과 같은 의도 — host 가 두 fn 사이의 frame lifecycle 을 신경
    /// 쓰지 않게.
    ///
    /// host 는 *항상* renderTabBar → drawPane (pane 마다) → endFrame 순서로 호출. tab_titles.len <
    /// 2 면 단일 탭이라 탭바 자체는 안 그림 (#127) 단 frame begin 은 동일.
    pub fn renderTabBar(
        self: *MetalRenderer,
        /// 멀티탭 (#111). 길이 ≥ 2 일 때만 탭바 그림. 길이 0 / 1 이면 single-tab
        /// 으로 보고 cell grid 가 풀 화면 사용.
        tab_titles: []const []const u8,
        active_tab: usize,
        /// #282 B8 — active terminal 의 현재 background (OSC 11 포함).
        /// null 은 terminal 에 배경이 없을 때만 init theme fallback 사용.
        terminal_background: ?ghostty.color.RGB,
        /// drag 진행 중이면 그 탭을 마우스 위치 따라 이동시켜 그림. null = drag
        /// 안 함 또는 5px 임계 미만. `current_x` (c_int) 는 *world* 좌표 (#117) —
        /// 화면 위치는 `current_x - tab_scroll_x_px + tab_area_x`.
        drag_view: ?tab_interaction.DragView,
        /// 탭바 스크롤 오프셋 (픽셀, #117). 각 탭 / drag 탭의 화면 x = world -
        /// 이 값 + tab_area_x.
        tab_scroll_x_px: f32,
        /// 탭바 layout — `<` `>` `×` `+` 버튼 위치, 탭 viewport 영역.
        tab_bar_layout: TabBarLayout,
        /// #268 2b — hover 중인 컨트롤 버튼 (.none = 없음). 강조 배경 박스.
        tab_hover: tab_layout.Area,
    ) void {
        // #483 2단계 ② — 프레임 시작. 이 프레임의 pane 수를 0 으로.
        self.panes_drawn = 0;
        const frame_bg = cell_color.resolveFrameBackground(terminal_background, self.fallback_bg);
        const drawable = objc.msgSend(self.layer, objc.sel("nextDrawable"));
        if (drawable == null) {
            self.pending_tabs = null;
            return;
        }
        self.current_drawable = drawable;

        // 직전 frame 이 요청한 instance 수가 buffer 용량을 넘었으면 키운다. 누적-offset
        // 방식이라 buffer 는 frame 전체 instance 를 동시에 담아야 하는데, 초과 시
        // drawBgInstances 가 그 호출을 통째 drop 해 box-drawing 등 뒷 draw 가 사라졌다.
        // frame 시작(아직 draw 없음)에서만 재할당 — 진행 중 swap 회피. 직전 frame 의
        // command buffer 가 옛 buffer 를 retain 하므로 즉시 release 안전.
        self.growInstanceBuffers();

        // frame 내 buffer overwrite 방지 — 매 frame 시작 시 누적 offset 리셋.
        self.bg_used = 0;
        self.text_used = 0;
        self.bg_needed = 0;
        self.text_needed = 0;

        const texture = objc.msgSend(drawable, objc.sel("texture"));

        const cmd_buf = objc.msgSend(self.command_queue, objc.sel("commandBuffer"));
        self.current_cmd_buf = cmd_buf;

        const rpd_class = objc.getClass("MTLRenderPassDescriptor");
        const rpd = objc.msgSend(rpd_class, objc.sel("renderPassDescriptor"));

        const attachments = objc.msgSend(rpd, objc.sel("colorAttachments"));
        const att0 = objc.msgSend1(attachments, objc.sel("objectAtIndexedSubscript:"), @as(objc.NSUInteger, 0));
        objc.msgSendVoid1(att0, objc.sel("setTexture:"), texture);
        objc.msgSendVoid1(att0, objc.sel("setLoadAction:"), @as(objc.NSUInteger, 2)); // Clear
        objc.msgSendVoid1(att0, objc.sel("setStoreAction:"), @as(objc.NSUInteger, 1)); // Store

        const ClearColor = extern struct { r: f64, g: f64, b: f64, a: f64 };
        const clear = ClearColor{
            .r = @floatCast(frame_bg[0]),
            .g = @floatCast(frame_bg[1]),
            .b = @floatCast(frame_bg[2]),
            .a = 1.0,
        };
        const setClearColorFn: *const fn (objc.id, objc.SEL, ClearColor) callconv(.c) void = @ptrCast(objc.msgSend_raw);
        setClearColorFn(att0, objc.sel("setClearColor:"), clear);

        const encoder = objc.msgSend1(cmd_buf, objc.sel("renderCommandEncoderWithDescriptor:"), rpd);
        if (encoder == null) {
            self.current_drawable = null;
            self.current_cmd_buf = null;
            self.pending_tabs = null;
            return;
        }
        self.current_encoder = encoder;

        self.pending_tabs = .{
            .titles = tab_titles,
            .active = active_tab,
            .drag_view = drag_view,
            .scroll_x_px = tab_scroll_x_px,
            .layout = tab_bar_layout,
            .hover = tab_hover,
        };
    }

    /// #483 2단계 ② — pane 하나를 그린다 (셀 · 커서 · preedit · scrollbar 를 `pane.rect` 안에).
    /// 프레임 시작은 `renderTabBar`, 끝 (탭바 · 스트립 · 메뉴 · endEncoding · present) 은 `endFrame`.
    /// `renderTabBar` 가 drawable 획득에 실패했으면 (`current_encoder` 가 null) no-op (frame skip).
    pub fn drawPane(self: *MetalRenderer, pane: pane_draw.PaneDraw) void {
        const encoder = self.current_encoder;
        if (encoder == null) return;

        if (self.panes_drawn == 0) {
            // #160 — render(그리기, present 제외) 계측. Windows renderer/windows.zig 동등. 첫 pane 의
            // 시작이 이전 `renderTerminal` 의 시작과 같은 자리다.
            self.render_t0 = perf.now();
            // #376 — blink 셀 존재 판정은 프레임 단위다. 첫 pane 이 지우고 pane 들이 OR 로 모은다.
            self.saw_blink_cell = false;
        }
        self.panes_drawn += 1;
        self.updateConstants();

        if (self.atlas.dirty) {
            self.uploadAtlas(&self.atlas, self.atlas_texture);
            self.atlas.dirty = false;
        }
        // 탭 glyph/icon atlas도 main atlas와 같은 2-frame 정책: 이전 frame에서
        // 만든 내용을 draw 전에 upload한다. 삽입 직후 같은 Metal encoder에서
        // sample하면 정적인 단일 탭 최초 frame의 icon이 투명하게 남았다.
        self.uploadTabAtlasIfDirty();

        self.renderTerminalContent(encoder, pane);
    }

    /// #483 5단계 — pane 사이 회색 분할선 · 활성 pane 의 amber 선 · 드래그 고스트 (Linux
    /// `software_terminal.collectPaneChrome` 과 같은 규칙: 회색은 `chrome.separator`, amber 는
    /// `TAB_ACCENT_COLOR` 를 활성 pane 의 padding 안쪽 · 다른 pane 과 맞닿는 변에만). `drawPane` 들 뒤,
    /// `endFrame` 앞에 한 번. 셀 위에 겹치지 않는 자리라 순서는 무관하고 고스트만 드래그 중 셀 위에 얹힌다.
    pub fn drawPaneChrome(self: *MetalRenderer, seps: []const pane_layout.Separator, area: pane_layout.Rect, active: ?pane_layout.Rect, ghost: ?pane_layout.Rect) void {
        const encoder = self.current_encoder;
        if (encoder == null) return;
        // 분할선 ≤ MAX−1, amber 변 ≤ 4, 고스트 1.
        var buf: [pane_layout.MAX_PANES_PER_TAB + 5]BgInstance = undefined;
        var n: usize = 0;
        for (seps) |s| {
            if (n >= buf.len) break;
            buf[n] = rectInstance(s.rect, self.chrome.separator);
            n += 1;
        }
        const amber = ui_metrics.TAB_ACCENT_COLOR;
        if (active) |r| {
            const t: i32 = @intFromFloat(ui_metrics.linePx(ui_metrics.PANE_FOCUS_LINE_PT, self.scale));
            if (r.x > area.x) {
                buf[n] = rectInstance(.{ .x = r.x, .y = r.y, .w = t, .h = r.h }, amber);
                n += 1;
            }
            if (r.x + r.w < area.x + area.w) {
                buf[n] = rectInstance(.{ .x = r.x + r.w - t, .y = r.y, .w = t, .h = r.h }, amber);
                n += 1;
            }
            if (r.y > area.y) {
                buf[n] = rectInstance(.{ .x = r.x, .y = r.y, .w = r.w, .h = t }, amber);
                n += 1;
            }
            if (r.y + r.h < area.y + area.h) {
                buf[n] = rectInstance(.{ .x = r.x, .y = r.y + r.h - t, .w = r.w, .h = t }, amber);
                n += 1;
            }
        }
        if (ghost) |g| {
            buf[n] = rectInstance(g, amber);
            n += 1;
        }
        self.drawBgInstances(encoder, buf[0..n]);
    }

    /// #483 2단계 ② — 프레임 끝: 보류한 탭바 (또는 단일 탭 스트립) · command menu → endEncoding →
    /// present + commit. `drawPane` 이 0 번이어도 프레임은 끝낸다.
    pub fn endFrame(self: *MetalRenderer, menu_ui: command_menu.Ui, toggle_hotkey: []const u8) void {
        const encoder = self.current_encoder;
        if (encoder == null) return;

        if (self.pending_tabs) |t| {
            if (t.titles.len >= 2) {
                self.drawTabBar(encoder, t.titles, t.active, t.drag_view, t.scroll_x_px, t.layout, t.hover);
            } else if (t.titles.len == 1) {
                self.drawSingleControlStrip(encoder, t.layout, t.hover);
            }
        }
        if (menu_ui.open) self.drawCommandMenu(encoder, menu_ui, toggle_hotkey);

        objc.msgSendVoid(encoder, objc.sel("endEncoding"));
        // `perf.render` 는 첫 `drawPane` 의 시작부터 여기까지 — 이전 `renderTerminal` 과 같은 구간을
        // 프레임에 한 번 잰다 (`addTimed` 가 호출 수도 세므로 pane 마다 재면 지표가 갈린다).
        if (self.panes_drawn > 0) perf.addTimed(&perf.render, self.render_t0);
        self.panes_drawn = 0;

        // #255 Phase 2 — 표시 확정 전이면 presented handler 부착(present *전*에 등록).
        // 표시 확정되면 더는 안 닮 — host 가 idle 시 frameWasPresented() 로 pause 판단.
        if (!g_frame_presented.load(.seq_cst)) {
            presented_block.isa = &_NSConcreteGlobalBlock;
            const addHandler = objc.objcSend(fn (objc.id, objc.SEL, *PresentedBlock) callconv(.c) void);
            addHandler(self.current_drawable, objc.sel("addPresentedHandler:"), &presented_block);
        }

        // #160 — present(drawable 표시 + commit) 계측.
        const present_t0 = perf.now();
        objc.msgSendVoid1(self.current_cmd_buf, objc.sel("presentDrawable:"), self.current_drawable);
        objc.msgSendVoid(self.current_cmd_buf, objc.sel("commit"));
        perf.addTimed(&perf.present, present_t0);
        // #441 축 ② — 대기 중인 키가 있으면 여기까지가 그 키의 응답 지연이다.
        perf.completeInput();
        perf.completeOutput();

        // Frame end — state reset.
        self.current_encoder = null;
        self.current_cmd_buf = null;
        self.current_drawable = null;
        self.pending_tabs = null;
    }

    fn renderTerminalContent(self: *MetalRenderer, encoder: objc.id, pane: pane_draw.PaneDraw) void {
        const terminal = pane.terminal;
        const state = pane.state;
        const cell_w: i32 = pane.cell_w;
        const cell_h: i32 = pane.cell_h;
        const padding: i32 = pane.pad;
        const preedit_utf8 = pane.preedit_utf8;
        const blink_faint = pane.blink_faint;
        state.update(self.alloc, terminal) catch return;

        const rows = state.rows;
        const cols = state.cols;
        const colors = state.colors;
        const row_slice = state.row_data.slice();

        const cw: f32 = @floatFromInt(cell_w);
        const ch: f32 = @floatFromInt(cell_h);
        // 위쪽 padding 보정: 폰트의 ascent 가 cap_height 보다 위쪽 internal
        // leading 만큼 더 큰데 cell box top 부터 ascent 만큼 내려간 위치가
        // baseline 이라, 대문자 visible top 은 cell top + (ascent − cap_height)
        // 위치. 좌/우 padding 은 글자에 딱 붙는데 위쪽만 (ascent − cap_height)
        // 만큼 추가 여백이 생겨 비대칭. 모든 row 의 fy 를 위로 그만큼 shift
        // 해서 첫 행 글자 visible top 이 정확히 padding 위치에 오게.
        // #483 2단계 ② — 격자 원점은 pane 기준. `rect` 가 탭바를 뺀 영역이라 pane 하나면 이전의
        // `padding` / `tab_bar_h + padding` 과 같은 값이다 (1단계 `leafRect` 의 `grid_x` / `grid_y`).
        const y_off: f32 = @as(f32, @floatFromInt(pane.rect.y + padding)) - self.font.top_pad_px;
        const x_pad: f32 = @floatFromInt(pane.rect.x + padding);

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

                // #376 — bg pass 는 **모든 셀**을 돌므로 blink 셀 존재 판정을 여기서
                // 한다 (text pass 는 글자 있는 셀만 본다). 위상이 off 면 `faint` 를
                // 세워 fg 해석과 선 색이 한 번에 흐려지게 한다.
                const raw_style = if (raw.style_id != 0) styles[x] else ghostty.Style{};
                if (raw_style.flags.blink) self.saw_blink_cell = true;
                const style = cell_color.applyBlinkPhase(raw_style, blink_faint);
                const is_inverse = style.flags.inverse;
                const x16: u16 = @intCast(x);
                const is_selected = if (sel_range) |sr| (x16 >= sr[0] and x16 <= sr[1]) else false;

                const is_custom_bg = is_selected or is_inverse or (style.bg(&raw, &colors.palette) != null);
                // #365 — SGR 선 속성 (밑줄 · 취소선 · 윗줄) 도 이 pass 에서 만든다.
                // **text pass 가 아니라 bg pass 인 것이 핵심** — 선이 글리프보다 먼저
                // 그려져야 색 밑줄이 글자를 가로지르지 않는다 (ghostty 와 같은 선택,
                // [`cell_decoration`](cell_decoration.zig) 주석). text pass 의
                // `bg_buf` 에 넣으면 글리프 *위*로 올라가 정반대가 된다.
                const has_deco = cell_decoration.hasDecoration(style);
                if (!is_custom_bg and !has_deco) continue;

                const width: f32 = if (raw.wide == .wide) 2.0 * cw else cw;
                const fx: f32 = @as(f32, @floatFromInt(x)) * cw + x_pad;
                const fy: f32 = @as(f32, @floatFromInt(y)) * ch + y_off;

                if (is_custom_bg) {
                    if (bg_count >= MAX_CELLS) {
                        self.drawBgInstances(encoder, bg_buf[0..bg_count]);
                        bg_count = 0;
                    }
                    const cell_bg = resolveBg(style, &raw, &colors, is_selected, is_inverse, dbg_r, dbg_g, dbg_b);
                    bg_buf[bg_count] = .{
                        .pos = .{ fx, fy },
                        .size = .{ width, ch },
                        .color = .{ cell_bg[0], cell_bg[1], cell_bg[2], 1 },
                    };
                    bg_count += 1;
                }

                if (has_deco) {
                    var deco: [cell_decoration.MAX_RECTS]cell_decoration.Rect = undefined;
                    const dn = cell_decoration.rects(
                        style,
                        resolveFg(style, &raw, &colors, is_selected, is_inverse),
                        &colors.palette,
                        self.font.ascent_px,
                        width,
                        ch,
                        if (raw.wide == .wide) 2 else 1,
                        &deco,
                    );
                    // 셀 하나가 최대 4 개를 만들므로 남은 자리를 미리 확인한다 —
                    // box drawing 이 같은 이유로 `bg_count + bn` 을 검사한다.
                    if (bg_count + dn > MAX_CELLS) {
                        self.drawBgInstances(encoder, bg_buf[0..bg_count]);
                        bg_count = 0;
                    }
                    // #374 — 물결은 곡선이라 가장자리 픽셀의 `cov` 가 1 미만이다.
                    // box drawing 과 같은 처리 — 공통 `blendOverRgb` 로 셀 배경과
                    // **미리** 합성해 알파 1.0 solid 로 그린다 (#353). `cov == 1` 인
                    // 나머지 선은 합성 결과가 원래 색 그대로다.
                    const deco_bg = cell_color.resolveBg(style, &raw, &colors, is_selected, is_inverse) orelse colors.background;
                    for (deco[0..dn]) |d| {
                        const blended = ui_metrics.blendOverRgb(
                            .{ d.color.r, d.color.g, d.color.b },
                            .{ deco_bg.r, deco_bg.g, deco_bg.b },
                            d.cov,
                        );
                        bg_buf[bg_count] = .{
                            .pos = .{ fx + d.x, fy + d.y },
                            .size = .{ d.w, d.h },
                            .color = .{ colorF(blended[0]), colorF(blended[1]), colorF(blended[2]), 1 },
                        };
                        bg_count += 1;
                    }
                }
            }
        }

        if (bg_count > 0) self.drawBgInstances(encoder, bg_buf[0..bg_count]);
        // bg pass 끝났으니 block element pass 가 같은 buffer 재사용 (Windows 동등).
        bg_count = 0;

        // --- Text pass (block element 도 여기서 처리) ---
        for (0..rows) |y| {
            if (y >= all_cells.len) break;
            const cell_slice = all_cells[y].slice();
            const raws = cell_slice.items(.raw);
            const styles = cell_slice.items(.style);
            const graphemes = cell_slice.items(.grapheme);
            const sel_range: ?[2]u16 = if (y < all_sels.len) all_sels[y] else null;

            const fy: f32 = @as(f32, @floatFromInt(y)) * ch + y_off;

            var x: usize = 0;
            while (x < cols) {
                if (x >= raws.len) break;
                const raw = raws[x];

                const is_text = raw.hasText() and raw.wide != .spacer_tail and raw.wide != .spacer_head and raw.codepoint() != 0;
                if (!is_text) {
                    x += 1;
                    continue;
                }

                // #365 — `invisible` (SGR 8) 은 전경 요소를 하나도 내보내지 않는다.
                // 글리프뿐 아니라 block element · box drawing 도 전경이라 여기서 함께
                // 막는다. 선은 bg pass 가 이미 걸렀다 (`hasDecoration` 이 false).
                // xterm · ghostty 와 같은 정책 — "아무것도 안 보임" 이 SGR 8 의 의미다.
                if (raw.style_id != 0 and styles[x].flags.invisible) {
                    x += 1;
                    continue;
                }

                const cp = raw.codepoint();

                // Block element / shade — font glyph 대신 cell-aligned procedural
                // rectangle (#155). Windows d3d11 와 동일 path. 폰트 의존 제거 +
                // 인접 셀 사이 갭 없음.
                if (block_element.isBlockElement(cp)) {
                    if (bg_count >= MAX_CELLS) {
                        self.drawBgInstances(encoder, bg_buf[0..bg_count]);
                        bg_count = 0;
                    }
                    const style_b = cell_color.applyBlinkPhase(if (raw.style_id != 0) styles[x] else ghostty.Style{}, blink_faint);
                    const is_inverse_b = style_b.flags.inverse;
                    const x16_b: u16 = @intCast(x);
                    const is_selected_b = if (sel_range) |sr| (x16_b >= sr[0] and x16_b <= sr[1]) else false;
                    const fg_rgb = resolveFg(style_b, &raw, &colors, is_selected_b, is_inverse_b);
                    const rect = block_element.blockElementRect(cp) orelse {
                        x += 1;
                        continue;
                    };
                    const block_w: f32 = if (raw.wide == .wide) 2.0 * cw else cw;
                    const block_x: f32 = @as(f32, @floatFromInt(x)) * cw + x_pad;
                    // #353 — 음영 ░▒▓ (alpha 0.25/0.5/0.75) 을 공통
                    // `ui_metrics.blendOverRgb` 로 **여기서 한 번** 합성하고 알파 1.0
                    // 으로 그린다. 이전에는 알파를 blend unit 에 맡겨 세 platform 이
                    // 서로 다른 정밀도로 8bit 를 만들었다 (최대 차 2).
                    //
                    // 합성 대상은 bg pass 가 이 셀에 칠한 색과 같아야 한다 — 같은
                    // `cell_color.resolveBg` 를 쓰고 null 이면 `colors.background`
                    // (bg pass 의 `dbg_*` 와 동일) 로 떨어진다. 솔리드 블록
                    // (alpha 1.0) 은 합성 결과가 `fg_rgb` 그대로다.
                    const block_bg = cell_color.resolveBg(style_b, &raw, &colors, is_selected_b, is_inverse_b) orelse colors.background;
                    const blended = ui_metrics.blendOverRgb(
                        .{ fg_rgb.r, fg_rgb.g, fg_rgb.b },
                        .{ block_bg.r, block_bg.g, block_bg.b },
                        rect.alpha,
                    );
                    bg_buf[bg_count] = .{
                        .pos = .{ block_x + rect.x0 * block_w, fy + rect.y0 * ch },
                        .size = .{ (rect.x1 - rect.x0) * block_w, (rect.y1 - rect.y0) * ch },
                        .color = .{ colorF(blended[0]), colorF(blended[1]), colorF(blended[2]), 1 },
                        .shade = rect.shade,
                    };
                    bg_count += 1;
                    x += 1;
                    continue;
                }

                // Box-drawing (선/모서리/junction, U+2500–257F) — block element 과
                // 같은 이유로 procedural 사각형 (#258). 대각선은 null → 글리프 path.
                if (cp >= 0x2500 and cp <= 0x257F) {
                    const box_w: f32 = if (raw.wide == .wide) 2.0 * cw else cw;
                    var box_rects: [box_drawing.MAX_RECTS]box_drawing.Rect = undefined;
                    if (box_drawing.boxRects(cp, box_w, ch, &box_rects)) |bn| {
                        if (bg_count + bn > MAX_CELLS) {
                            self.drawBgInstances(encoder, bg_buf[0..bg_count]);
                            bg_count = 0;
                        }
                        const style_x = cell_color.applyBlinkPhase(if (raw.style_id != 0) styles[x] else ghostty.Style{}, blink_faint);
                        const is_inverse_x = style_x.flags.inverse;
                        const x16_x: u16 = @intCast(x);
                        const is_selected_x = if (sel_range) |sr| (x16_x >= sr[0] and x16_x <= sr[1]) else false;
                        const fg_rgb_x = resolveFg(style_x, &raw, &colors, is_selected_x, is_inverse_x);
                        const box_x: f32 = @as(f32, @floatFromInt(x)) * cw + x_pad;
                        // #353 — `br.cov` (AA coverage) 를 공통 `ui_metrics.blendOverRgb`
                        // 로 미리 합성하고 알파 1.0 으로 그린다. **emitter 가 픽셀당
                        // rect 를 하나만 내보내므로** (대각선은 두 선을 `@max` 로, 호는
                        // arm·arc 거리를 `@min` 으로 합친 *뒤* emit) 한 픽셀에 blend 가
                        // 한 번뿐이고, 배경과 미리 합성한 결과가 순차 blend 와 같다.
                        const box_bg = cell_color.resolveBg(style_x, &raw, &colors, is_selected_x, is_inverse_x) orelse colors.background;
                        for (box_rects[0..bn]) |br| {
                            const cov_blend = ui_metrics.blendOverRgb(
                                .{ fg_rgb_x.r, fg_rgb_x.g, fg_rgb_x.b },
                                .{ box_bg.r, box_bg.g, box_bg.b },
                                br.cov,
                            );
                            bg_buf[bg_count] = .{
                                .pos = .{ box_x + br.x, fy + br.y },
                                .size = .{ br.w, br.h },
                                .color = .{ colorF(cov_blend[0]), colorF(cov_blend[1]), colorF(cov_blend[2]), 1 },
                                .shade = 0,
                            };
                            bg_count += 1;
                        }
                        x += 1;
                        continue;
                    }
                }

                const style = cell_color.applyBlinkPhase(if (raw.style_id != 0) styles[x] else ghostty.Style{}, blink_faint);
                const is_inverse = style.flags.inverse;
                const x16: u16 = @intCast(x);
                const is_selected = if (sel_range) |sr| (x16 >= sr[0] and x16 <= sr[1]) else false;
                const fg_rgb = resolveFg(style, &raw, &colors, is_selected, is_inverse);

                // grapheme cluster (VS-16 / skin tone modifier / ZWJ 시퀀스) — cell 의
                // base + extras 를 CTLine 으로 shape, 단일 representative glyph 으로
                // reduce. 일반 cell 은 빠른 single-codepoint path 또는 ligature
                // lookahead 분기.
                if (raw.hasGrapheme() and x < graphemes.len) {
                    // #399 — **연속된 grapheme 셀을 모아 한 번에 shape 한다.** cluster 마다
                    // `CTLine` 을 새로 만드는 고정 비용이 `render` 의 92 % 를 차지해서, 한 줄을
                    // 묶으면 실측으로 3.1~8.3 배 싸다. 런이 2 개 미만이면 이득이 없어 아래
                    // 개별 경로로 간다.
                    //
                    // 런 경계는 셋만 본다: 연속 grapheme 셀 · `spacer_tail` 은 **건너뛰고 이어감**
                    // (wide cluster 뒤엔 항상 오므로 여기서 끊으면 런이 1 개씩 쪼개진다) ·
                    // `invisible` 에서 끊음. **`style_id` 는 안 본다** — 글리프는 폰트에만
                    // 의존하고 색은 셀마다 따로 계산한다.
                    var run_n: usize = 0;
                    var cps_used: usize = 0;
                    var scan = x;
                    while (scan < cols and scan < raws.len and run_n < CoreTextFontContext.MAX_RUN_CLUSTERS) {
                        const rr = raws[scan];
                        if (rr.wide == .spacer_tail) {
                            scan += 1;
                            continue;
                        }
                        if (!(rr.hasText() and rr.wide != .spacer_head and rr.codepoint() != 0)) break;
                        if (!(rr.hasGrapheme() and scan < graphemes.len)) break;
                        if (rr.style_id != 0 and styles[scan].flags.invisible) break;

                        const ex = graphemes[scan];
                        const ex_take = @min(ex.len, 16);
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
                        self.font.resolveGraphemeRun(self.run_slices[0..run_n], self.run_glyphs[0..run_n]) == run_n)
                    {
                        for (0..run_n) |i| {
                            const cell_x = self.run_cells[i];
                            const result = self.run_glyphs[i];
                            const rr = raws[cell_x];
                            // 색은 셀마다 다시 계산한다 — 런을 style 로 끊지 않기 때문이다.
                            const st = cell_color.applyBlinkPhase(if (rr.style_id != 0) styles[cell_x] else ghostty.Style{}, blink_faint);
                            const inv = st.flags.inverse;
                            const sel = if (sel_range) |sr| (cell_x >= sr[0] and cell_x <= sr[1]) else false;
                            const fg = resolveFg(st, &rr, &colors, sel, inv);

                            if (text_count >= MAX_CELLS) {
                                self.drawTextInstances(encoder, text_buf[0..text_count]);
                                text_count = 0;
                            }
                            // #401 — cluster 가 글리프 여러 개면 한 비트맵으로 합성한다.
                            // 하나면 `getOrInsertCluster` 가 기존 경로로 넘긴다.
                            const entry_opt = self.atlas.getOrInsertCluster(result.font, result.glyphs[0..result.count], result.positions[0..result.count], result.fonts[0..result.count], result.advance);
                            mac_font.releaseCluster(result);
                            if (entry_opt) |entry| {
                                if (entry.w > 0 and entry.h > 0) {
                                    emitTextInstance(text_buf[0..], &text_count, entry, cell_x, fy, cw, x_pad, self.font.ascent_px, fg, glyphCenterDx(entry, rr.wide == .wide, cw), 0);
                                }
                            }
                        }
                        x = scan;
                        continue;
                    }

                    // 개별 경로 — 런이 1 개거나 배칭이 실패했을 때. 렌더가 틀리느니 느린 게 낫다.
                    if (text_count >= MAX_CELLS) {
                        self.drawTextInstances(encoder, text_buf[0..text_count]);
                        text_count = 0;
                    }
                    var cluster: [16]u21 = undefined;
                    cluster[0] = cp;
                    const extras = graphemes[x];
                    const take = @min(extras.len, cluster.len - 1);
                    @memcpy(cluster[1..][0..take], extras[0..take]);
                    const r_opt = self.font.resolveGrapheme(cluster[0 .. 1 + take]);
                    if (r_opt) |result| {
                        // #401 — 위 배칭 경로와 같은 이유로 multi-glyph 를 합성해 그린다.
                        const entry_opt = self.atlas.getOrInsertCluster(result.font, result.glyphs[0..result.count], result.positions[0..result.count], result.fonts[0..result.count], result.advance);
                        mac_font.releaseCluster(result);
                        if (entry_opt) |entry| {
                            if (entry.w > 0 and entry.h > 0) {
                                emitTextInstance(text_buf[0..], &text_count, entry, x, fy, cw, x_pad, self.font.ascent_px, fg_rgb, glyphCenterDx(entry, raw.wide == .wide, cw), 0);
                            }
                        }
                        x += 1;
                        continue;
                    }
                }

                // SPEC § 12.2 — N-char ligature lookahead. 3-char → 2-char 순서.
                // 모든 cell narrow + single codepoint + same style_id + ASCII
                // candidate. 매치 시 `.single` 은 N-cell 너비 1 glyph, `.spacer`
                // 는 각 cell 별 1 glyph.
                if (x + 2 < cols and x + 2 < raws.len and raw.wide == .narrow and isLigatureCandidate(cp)) {
                    const next = raws[x + 1];
                    const next2 = raws[x + 2];
                    if (next.wide == .narrow and next.hasText() and next.codepoint() != 0 and
                        next.style_id == raw.style_id and isLigatureCandidate(next.codepoint()) and
                        next2.wide == .narrow and next2.hasText() and next2.codepoint() != 0 and
                        next2.style_id == raw.style_id and isLigatureCandidate(next2.codepoint()))
                    {
                        if (self.font.ligatureTriple(cp, next.codepoint(), next2.codepoint())) |lm| {
                            emitLigatureMatch(self, encoder, text_buf[0..], &text_count, x, 3, lm, fy, cw, x_pad, fg_rgb);
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
                        if (self.font.ligaturePair(cp, next.codepoint())) |lm| {
                            emitLigatureMatch(self, encoder, text_buf[0..], &text_count, x, 2, lm, fy, cw, x_pad, fg_rgb);
                            x += 2;
                            continue;
                        }
                    }
                }

                if (text_count >= MAX_CELLS) {
                    self.drawTextInstances(encoder, text_buf[0..text_count]);
                    text_count = 0;
                }

                const result = self.font.resolveGlyph(
                    cp,
                    // #375 — SGR 1 / 3 이 요구하는 face 변종. 없는 family 는 폰트
                    // 모듈이 regular 로 떨어뜨린다.
                    font_constants.FaceStyle.from(style.flags.bold, style.flags.italic),
                ) orelse {
                    x += 1;
                    continue;
                };
                const entry = self.atlas.getOrInsert(result.font, @intCast(result.index)) orelse {
                    mac_font.releaseCluster(result);
                    x += 1;
                    continue;
                };
                mac_font.releaseCluster(result);

                if (entry.w == 0 or entry.h == 0) {
                    x += 1;
                    continue;
                }

                emitTextInstance(text_buf[0..], &text_count, entry, x, fy, cw, x_pad, self.font.ascent_px, fg_rgb, glyphCenterDx(entry, raw.wide == .wide, cw), 0);
                x += 1;
            }
        }

        if (text_count > 0) self.drawTextInstances(encoder, text_buf[0..text_count]);
        // Block element pass flush — text pass 안에서 bg_buf 재사용해 누적된 것.
        if (bg_count > 0) {
            self.drawBgInstances(encoder, bg_buf[0..bg_count]);
            bg_count = 0;
        }

        // --- Cursor (#297 — 세로 막대 bar, 세 platform 공통) ---
        // 셀 좌측에 opaque bar. wide char 는 wide_tail 보정으로 글자 시작
        // cell 의 좌측에 위치. 폭은 `ui_metrics.CURSOR_BAR_W_PT` × retina scale.
        if (state.cursor.visible) {
            if (state.cursor.viewport) |vp| {
                var cursor_x: f32 = @floatFromInt(vp.x);
                const cursor_y: f32 = @floatFromInt(vp.y);
                if (vp.wide_tail and vp.x > 0) cursor_x -= 1.0;
                const cx0 = cursor_x * cw + x_pad;
                const cy0 = cursor_y * ch + y_off;
                var cursor_color: [4]f32 = .{ 180.0 / 255.0, 180.0 / 255.0, 180.0 / 255.0, 1.0 };
                if (colors.cursor) |cc| {
                    cursor_color = .{ colorF(cc.r), colorF(cc.g), colorF(cc.b), 1.0 };
                }
                const cursor_inst = [1]BgInstance{.{
                    .pos = .{ cx0, cy0 },
                    .size = .{ ui_metrics.cursorBarWidthPx(self.scale), ch },
                    .color = cursor_color,
                }};
                self.drawBgInstances(encoder, &cursor_inst);
            }
        }

        // --- Scrollbar ---
        // #343 단계 2 — scrollbar thumb 의 rect 와 색은 공통 `scrollbar.thumbRect`
        // 한 곳이 만든다 (track 자체는 별도 색 없이 배경 그대로 — 세 platform 동일).
        // #259 — drag hit-test (`host/macos.scrollbarHit`) 와 같은 입력. track_top 은
        // 셀 영역 윗변(`y_offset + padding`) — 텍스트 baseline 용 `y_off`(top_pad_px
        // 보정 포함) 와 달라 scrollbar 는 별도로 둔다.
        // #483 2단계 ② — track 은 pane 기준이다. `thumbRect` 의 viewport 인자에 pane 의 오른쪽 · 아래
        // **가장자리**를, track_top 에 `rect.y + scrollbar_top_inset` 을 넘기면 같은 식이 pane
        // 좌표계에서 성립한다 (pane 하나면 이전 인자와 값이 같다). 폭 · thumb 최소 높이는 host 가
        // 이전과 같은 `scaledPxF` 값을 f32 로 넘긴다.
        const sb = terminal.screens.active.pages.scrollbar();
        if (scrollbar.thumbRect(
            sb.total,
            sb.len,
            sb.offset,
            @floatFromInt(pane.rect.x + pane.rect.w),
            @floatFromInt(pane.rect.y + pane.rect.h),
            @floatFromInt(pane.rect.y + pane.scrollbar_top_inset),
            @floatFromInt(padding),
            pane.scrollbar_min_thumb_h,
            pane.scrollbar_w,
            .{ colors.background.r, colors.background.g, colors.background.b },
        )) |r| {
            const scrollbar_inst = [1]BgInstance{bgFromChrome(r)};
            self.drawBgInstances(encoder, &scrollbar_inst);
        }

        // --- IME preedit (조합 중) overlay ---
        // cursor 위치부터 preedit_utf8 의 각 codepoint 를 그림. 배경 강조 +
        // 글자 + 아래 underline. PTY 에는 안 들어가지만 사용자가 조합 중인
        // 자모 / 음절을 볼 수 있게.
        if (preedit_utf8.len > 0 and state.cursor.viewport != null) {
            const vp = state.cursor.viewport.?;
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
                const result = self.font.resolveGlyph(@intCast(cp), .regular) orelse continue;
                const entry = self.atlas.getOrInsert(result.font, @intCast(result.index)) orelse {
                    mac_font.releaseCluster(result);
                    continue;
                };
                mac_font.releaseCluster(result);

                const w_cells: f32 = @floatFromInt(display_width.codepointWidth(cp));

                const cell_x = pre_col * cw + x_pad;
                pre_bg_buf[pre_bg_n] = .{
                    .pos = .{ cell_x, pre_y },
                    .size = .{ w_cells * cw, ch },
                    .color = pre_bg_color,
                };
                pre_bg_n += 1;

                if (entry.w > 0 and entry.h > 0 and pre_text_n < pre_text_buf.len) {
                    // #299 — 강조 블록(w_cells 셀) 안 가운데 정렬 (본문과 동일 정책).
                    const gx = cell_x + glyphCenterDx(entry, w_cells >= 2.0, cw) + @as(f32, @floatFromInt(entry.bearing_x));
                    const gy = pre_y + self.font.ascent_px - @as(f32, @floatFromInt(entry.bearing_y)) - @as(f32, @floatFromInt(entry.h));
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

    /// 윈도우 상단 탭바 (#111 M11.4, #334 2026-07-22 개편). Windows
    /// `D3d11Renderer.renderTabBar` 와 같은 시각 디자인 (Tilda 문법):
    ///   - 탭 배경(활성 포함) = 탭바 배경(TAB_BAR_BG) — 탭바 전체가 하나의
    ///     회색 띠. 활성 탭은 하단 amber 밑줄로만 구분.
    ///   - 탭 사이 경계는 세로 구분선(TAB_SEPARATOR_COLOR) — 슬롯(world) 기준
    ///     고정이라 drag 재배열 중 빈 원위치 슬롯도 구분선+제목 부재로 인지.
    fn drawTabBar(
        self: *MetalRenderer,
        encoder: objc.id,
        tab_titles: []const []const u8,
        active_tab: usize,
        drag_view: ?tab_interaction.DragView,
        /// 탭바 스크롤 오프셋 (픽셀, #117). 각 탭 / drag 탭의 화면 x =
        /// `world_x - tab_scroll_x_px + tab_area_x`.
        tab_scroll_x_px: f32,
        /// `<` `>` `×` `+` 버튼 layout. tab_area_x = 화살표 있을 때 ARROW_W.
        layout: TabBarLayout,
        /// #268 2b — hover 중인 컨트롤 버튼 (.none = 없음). 강조 배경 박스.
        hover: tab_layout.Area,
    ) void {
        const tab_bar_h_px: f32 = @floatFromInt(ui_metrics.tabBarHeightPx(self.scale));
        const tab_w_px = ui_metrics.scaledPxF(ui_metrics.TAB_WIDTH_PT, self.scale);
        const tab_pad_px = ui_metrics.scaledPxF(ui_metrics.TAB_PADDING_PT, self.scale);
        const tab_gap = ui_metrics.tabGapPx(self.scale);

        const MAX_BG: usize = 64;
        const MAX_TEXT: usize = 512;
        var bg_buf: [MAX_BG]BgInstance = undefined;
        var bg_n: usize = 0;
        var text_buf: [MAX_TEXT]TextInstance = undefined;
        var text_n: usize = 0;

        // #343 — rect 목록과 그 순서는 공통 `tab_chrome` 이 만든다. 여기서는
        // `BgInstance` 로 옮기고, 사이사이에 이 renderer 고유인 텍스트 / 아이콘
        // batch 를 끼운다 (`before_titles` 경계).
        const chrome_in = tab_chrome.Inputs{
            .viewport_w = @floatFromInt(self.vp_width),
            .tab_bar_h = tab_bar_h_px,
            .tab_w = tab_w_px,
            // #357 — 선 두께는 정수 px (`linePx`). 소수 두께는 위치 소수부에 따라
            // 덮는 픽셀 수가 갈려 같은 화면 안 구분선들의 두께가 달라졌고, 두께를
            // 미리 정수로 반올림하는 Linux 와도 값이 어긋났다.
            .sep_w = ui_metrics.linePx(ui_metrics.TAB_SEPARATOR_W_PT, self.scale),
            .underline_h = ui_metrics.linePx(ui_metrics.TAB_ACTIVE_UNDERLINE_PT, self.scale),
            .hover_inset = tab_gap.control_hover_inset,
            .tab_count = tab_titles.len,
            .active_idx = active_tab,
            .scroll_x = tab_scroll_x_px,
            .drag = drag_view,
            .layout = layout,
            .hover = hover,
            .palette = &self.chrome,
        };
        var chrome_rects: [tab_chrome.maxRects(session_core.MAX_TABS)]tab_chrome.Rect = undefined;
        const built = tab_chrome.build(&chrome_rects, chrome_in);
        for (built.rects[0..built.before_titles]) |r| {
            if (bg_n >= MAX_BG) break;
            bg_buf[bg_n] = bgFromChrome(r);
            bg_n += 1;
        }

        const tab_area_end = layout.tab_area_x + layout.tab_area_w;

        // 각 탭 제목 텍스트 — 탭바 배경과 amber 밑줄은 위에서 `tab_chrome` 이
        // 이미 넣었다 (`before_titles` 앞 구간).
        const cw: f32 = @floatFromInt(self.tab_font.cell_width_px);
        const ch: f32 = @floatFromInt(self.tab_font.cell_height_px);
        const text_y_top: f32 = (tab_bar_h_px - ch) * 0.5;
        // #268 — per-tab close 제거로 text 영역이 탭 전체 (양쪽 padding 제외).
        const max_text_w_px = tab_w_px - tab_pad_px * 2;

        // 제목 emit — 두 번 쓰인다: 일반 탭(1차 batch) 과 드래그 중인 탭(2차
        // batch, 세로선 뒤). 후자는 공통 계약 `Chrome.deferred_title` 이 정한다.
        const TitleCtx = struct {
            self: *MetalRenderer,
            text_buf: *[MAX_TEXT]TextInstance,
            text_n: *usize,
            text_y_top: f32,
            viewport_left: f32,
            tab_area_end: f32,
        };
        const emitTitle = struct {
            fn f(
                rself: *MetalRenderer,
                title: []const u8,
                tab_x: f32,
                pad: f32,
                area_x: f32,
                area_end: f32,
                cw_: f32,
                max_w: f32,
                y_top: f32,
                buf: *[MAX_TEXT]TextInstance,
                n: *usize,
            ) void {
                const text_x_start = tab_x + pad;
                // #343 — glyph clip 을 **명시** 로 통일했다. 이전에는 좌측만 보고
                // (`text_x_start`) 우측은 나중에 그리는 컨트롤 fill 이 덮어 가렸다.
                // 좌측도 `tab_area_x` 로 clamp — 부분 잘린 첫 탭은 `text_x_start`
                // 가 tab_area 왼쪽으로 넘어갈 수 있다.
                const total_text_w = @as(f32, @floatFromInt(display_width.stringWidth(title))) * cw_;
                const ctx = TitleCtx{
                    .self = rself,
                    .text_buf = buf,
                    .text_n = n,
                    .text_y_top = y_top,
                    .viewport_left = area_x,
                    .tab_area_end = area_end,
                };
                tab_layout.iterTabText(title, text_x_start, cw_, max_w, total_text_w > max_w, ctx, struct {
                    fn cb(c: TitleCtx, g: tab_layout.Glyph) void {
                        if (c.text_n.* >= MAX_TEXT) return;
                        const result = c.self.tab_font.resolveGlyph(@intCast(g.cp), .regular) orelse return;
                        const entry = c.self.tab_atlas.getOrInsert(result.font, @intCast(result.index)) orelse {
                            mac_font.releaseCluster(result);
                            return;
                        };
                        mac_font.releaseCluster(result);
                        if (entry.w == 0 or entry.h == 0) return;
                        const gx = g.x + @as(f32, @floatFromInt(entry.bearing_x));
                        const gy = c.text_y_top + c.self.tab_font.ascent_px - @as(f32, @floatFromInt(entry.bearing_y)) - @as(f32, @floatFromInt(entry.h));
                        // #343 A-2 — glyph 를 `tab_area` 에서 **잘라** 안쪽만 그린다.
                        // quad 와 atlas UV 를 같은 양만큼 민다 (텍셀 1:1).
                        const cl = ui_rect.clipX(gx, @floatFromInt(entry.w), c.viewport_left, c.tab_area_end) orelse return;
                        c.text_buf[c.text_n.*] = .{
                            .pos = .{ cl.x, gy },
                            .size = .{ cl.w, @floatFromInt(entry.h) },
                            .uv_pos = .{ @as(f32, @floatFromInt(entry.x)) + cl.cut_left, @floatFromInt(entry.y) },
                            .uv_size = .{ cl.w, @floatFromInt(entry.h) },
                            .fg_color = c.self.chrome.tab_text,
                            .color_flag = if (entry.is_color) 1 else 0,
                        };
                        c.text_n.* += 1;
                    }
                }.cb);
            }
        }.f;

        for (tab_titles, 0..) |title, i| {
            // #343 — 공통 계약: 이 인덱스는 맨 마지막에 그린다 (집어 든 탭이 맨 위 layer).
            if (built.deferred_title) |d| if (d == i) continue;
            const tab_x = tab_chrome.tabX(i, chrome_in);
            switch (tab_chrome.tabClip(tab_x, tab_w_px, layout.tab_area_x, tab_area_end, drag_view != null)) {
                .skip => continue,
                .stop => break,
                .draw => {},
            }
            emitTitle(self, title, tab_x, tab_pad_px, layout.tab_area_x, tab_area_end, cw, max_text_w_px, text_y_top, &text_buf, &text_n);
        }

        // 1차 batch — 탭 BG / 텍스트 그림.
        if (bg_n > 0) self.drawBgInstances(encoder, bg_buf[0..bg_n]);
        if (text_n > 0) {
            self.drawTextInstancesWithTexture(encoder, text_buf[0..text_n], self.tab_atlas_texture);
        }

        // #343 — 제목 뒤 구간: 컨트롤 bg fill → hover 박스 → 세로 구분선.
        // 별도 batch 로 그리는 이유는 그대로다 (#117) — 탭 텍스트 *후* 에 그려야
        // 컨트롤 영역이 온전하다. 다만 어떤 rect 를 어떤 순서로 놓을지는 이제
        // 공통 `tab_chrome` 이 정한다 (세 renderer 정본 순서).
        bg_n = 0;
        text_n = 0;
        for (built.rects[built.before_titles..]) |r| {
            if (bg_n >= MAX_BG) break;
            bg_buf[bg_n] = bgFromChrome(r);
            bg_n += 1;
        }

        // #343 — 드래그 중인 탭의 제목을 2차 batch 에 넣는다 — 세로선·다른 탭 제목
        // **위**로 온다 (집어 든 탭이 맨 위 layer, 2026-07-31 사용자 결정).
        // 텍스트끼리는 지오메트리로 잘라 낼 수 없어 이 항목만 layer 순서로 표현한다.
        if (built.deferred_title) |di| {
            if (di < tab_titles.len) {
                const dx = tab_chrome.tabX(di, chrome_in);
                if (tab_chrome.tabClip(dx, tab_w_px, layout.tab_area_x, tab_area_end, true) == .draw) {
                    emitTitle(self, tab_titles[di], dx, tab_pad_px, layout.tab_area_x, tab_area_end, cw, max_text_w_px, text_y_top, &text_buf, &text_n);
                }
            }
        }

        // #268 직접 그리기 — 아이콘 (`< > × +`) 을 `tab_icons` 공통 rasterizer 로
        // 알파 커버리지 비트맵을 만들어 atlas 커스텀 엔트리로 그림 (폰트 독립).
        // Linux / Windows 와 같은 비트맵 → 세 platform 픽셀 동일. box 중앙 정렬.
        const icon_size: u32 = ui_metrics.scaledPx(u32, ui_metrics.TAB_ICON_SIZE_PT, self.scale);
        const icon_stroke: f32 = ui_metrics.strokePx(ui_metrics.TAB_ICON_STROKE_PT, self.scale);
        const more_stroke: f32 = ui_metrics.strokePx(ui_metrics.TAB_MORE_DOT_DIAMETER_PT, self.scale);
        const drawIcon = struct {
            fn run(rself: *MetalRenderer, icon: tab_icons.Icon, box_x: f32, box_w: f32, tbh: f32, isz: u32, istroke: f32, color: [4]f32, buf: []TextInstance, n: *usize) void {
                if (n.* >= buf.len) return;
                if (box_w <= 0 or isz == 0) return;
                const entry = rself.tab_atlas.getOrInsertIcon(icon, isz, istroke) orelse return;
                if (entry.w == 0 or entry.h == 0) return;
                const fsz: f32 = @floatFromInt(isz);
                const gx = box_x + (box_w - fsz) * 0.5;
                const gy = (tbh - fsz) * 0.5;
                buf[n.*] = .{
                    .pos = .{ gx, gy },
                    .size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                    .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
                    .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                    .fg_color = color,
                    .color_flag = 0,
                };
                n.* += 1;
            }
        }.run;

        if (layout.arrows_visible) {
            const left_color = if (layout.left_enabled) self.chrome.ctrl_active else self.chrome.arrow_disabled;
            const right_color = if (layout.right_enabled) self.chrome.ctrl_active else self.chrome.arrow_disabled;
            drawIcon(self, .chevron_left, layout.left_arrow_x, layout.arrow_w, tab_bar_h_px, icon_size, icon_stroke, left_color, &text_buf, &text_n);
            drawIcon(self, .chevron_right, layout.right_arrow_x, layout.arrow_w, tab_bar_h_px, icon_size, icon_stroke, right_color, &text_buf, &text_n);
        }
        // #329 — MAX_TABS 도달 시 `+` 는 자리 유지 + 비활성 색 (arrow 동일 관례).
        const plus_color = if (layout.plus_enabled) self.chrome.ctrl_active else self.chrome.arrow_disabled;
        drawIcon(self, .plus, layout.plus_x, layout.plus_w, tab_bar_h_px, icon_size, icon_stroke, plus_color, &text_buf, &text_n);
        // #268 — 우측 끝 활성 탭 닫기 버튼 `×`.
        drawIcon(self, .close, layout.close_x, layout.close_w, tab_bar_h_px, icon_size, icon_stroke, self.chrome.ctrl_active, &text_buf, &text_n);
        drawIcon(self, .more, layout.more_x, layout.more_w, tab_bar_h_px, icon_size, more_stroke, self.chrome.ctrl_active, &text_buf, &text_n);

        if (bg_n > 0) self.drawBgInstances(encoder, bg_buf[0..bg_n]);
        if (text_n > 0) {
            self.drawTextInstancesWithTexture(encoder, text_buf[0..text_n], self.tab_atlas_texture);
        }
    }

    /// #329 — 단일 탭 terminal 위에 우측 `[+][×][…]`만 최종 합성한다.
    /// 전체 tabbar 배경은 그리지 않아 terminal grid/y-offset을 그대로 유지한다.
    fn drawSingleControlStrip(
        self: *MetalRenderer,
        encoder: objc.id,
        layout: TabBarLayout,
        hover: tab_layout.Area,
    ) void {
        const h: f32 = @floatFromInt(ui_metrics.tabBarHeightPx(self.scale));
        const gap = ui_metrics.tabGapPx(self.scale);
        // #343 — 컨트롤 bg fill · hover 는 탭바 경로와 같은 `tab_chrome`
        // (`buildControlsOnly`) 이 만든다. 탭바 전체 배경 · 밑줄 · 구분선은
        // 단일 탭 overlay 에 없으므로 컨트롤 구간만 쓴다.
        const chrome_in = tab_chrome.Inputs{
            .viewport_w = @floatFromInt(self.vp_width),
            .tab_bar_h = h,
            .tab_w = 0,
            .sep_w = 0,
            .underline_h = 0,
            .hover_inset = gap.control_hover_inset,
            .tab_count = 0,
            .active_idx = 0,
            .scroll_x = 0,
            .drag = null,
            .layout = layout,
            .hover = hover,
            .palette = &self.chrome,
        };
        var chrome_rects: [tab_chrome.maxRects(0)]tab_chrome.Rect = undefined;
        var bg: [tab_chrome.maxRects(0)]BgInstance = undefined;
        var bg_n: usize = 0;
        for (tab_chrome.buildControlsOnly(&chrome_rects, chrome_in)) |r| {
            bg[bg_n] = bgFromChrome(r);
            bg_n += 1;
        }
        if (bg_n > 0) self.drawBgInstances(encoder, bg[0..bg_n]);

        var text_buf: [3]TextInstance = undefined;
        var text_n: usize = 0;
        const icon_size: u32 = ui_metrics.scaledPx(u32, ui_metrics.TAB_ICON_SIZE_PT, self.scale);
        const icon_stroke = ui_metrics.strokePx(ui_metrics.TAB_ICON_STROKE_PT, self.scale);
        const more_stroke = ui_metrics.strokePx(ui_metrics.TAB_MORE_DOT_DIAMETER_PT, self.scale);
        const emit = struct {
            fn icon(rself: *MetalRenderer, kind: tab_icons.Icon, x: f32, w: f32, bar_h: f32, size: u32, stroke: f32, out: []TextInstance, count: *usize) void {
                if (w <= 0 or count.* >= out.len) return;
                const entry = rself.tab_atlas.getOrInsertIcon(kind, size, stroke) orelse return;
                const size_f: f32 = @floatFromInt(size);
                out[count.*] = .{
                    .pos = .{ x + (w - size_f) * 0.5, (bar_h - size_f) * 0.5 },
                    .size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                    .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
                    .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                    .fg_color = rself.chrome.ctrl_active,
                    .color_flag = 0,
                };
                count.* += 1;
            }
        }.icon;
        emit(self, .plus, layout.plus_x, layout.plus_w, h, icon_size, icon_stroke, &text_buf, &text_n);
        emit(self, .close, layout.close_x, layout.close_w, h, icon_size, icon_stroke, &text_buf, &text_n);
        emit(self, .more, layout.more_x, layout.more_w, h, icon_size, more_stroke, &text_buf, &text_n);
        if (text_n > 0) {
            // 여기서 uploadTabAtlasIfDirty 를 부르면 안 된다 — 같은 encoder 의
            // insert/upload/sample 은 정적 첫 frame 에서 icon 이 투명하게 남고
            // (실기 확정), dirty 를 지워 host 의 tabAtlasDirty() 후속-frame
            // 요청까지 꺼진다. 새 항목은 drawPane 시작의 2-frame upload
            // 가 다음 frame 에 반영한다 (main glyph atlas 와 같은 정책).
            self.drawTextInstancesWithTexture(encoder, text_buf[0..text_n], self.tab_atlas_texture);
        }
    }

    fn drawCommandMenu(self: *MetalRenderer, encoder: objc.id, ui: command_menu.Ui, toggle_hotkey: []const u8) void {
        const scale = self.scale;
        // #329 — viewport 높이에 맞춰 entry 단위로 자른 View. 안 보이는 entry
        // 는 그리지 않는다 (부분 행 없음 — scroll 은 first_visible 로).
        const v = command_menu.view(
            @as(f32, @floatFromInt(self.vp_width)) / scale,
            @as(f32, @floatFromInt(self.vp_height)) / scale,
            @floatFromInt(ui_metrics.TAB_BAR_HEIGHT_PT),
            ui.first_visible,
        );
        const mx = v.rect.x * scale;
        const mw = v.rect.w * scale;

        // #343 단계 3 — 메뉴 배경 · 강조 박스 · 항목 구분선의 rect 와 그 순서는
        // 공통 `command_menu.rects` 한 곳이 만든다. 여기 남은 것은 텍스트와 스크롤
        // 표시 아이콘 (이 renderer 고유) 뿐이다.
        var menu_rects: [command_menu.MAX_RECTS]tab_chrome.Rect = undefined;
        var menu_bg: [command_menu.MAX_RECTS]BgInstance = undefined;
        var menu_n: usize = 0;
        for (command_menu.rects(&menu_rects, v, ui, scale, &self.chrome)) |r| {
            menu_bg[menu_n] = bgFromChrome(r);
            menu_n += 1;
        }
        self.drawBgInstances(encoder, menu_bg[0..menu_n]);

        // #334 — 잘림 상태의 상/하단 스크롤 표시 행 (탭바 `<`/`>` 관례:
        // 끝에 닿으면 비활성 색, 클릭 = 한 entry 스크롤).
        if (v.clipped) {
            const ind_size: u32 = ui_metrics.scaledPx(u32, ui_metrics.MENU_INDICATOR_ICON_PT, scale);
            const ind_stroke = ui_metrics.strokePx(ui_metrics.TAB_ICON_STROKE_PT, scale);
            const size_f: f32 = @floatFromInt(ind_size);
            const ind_cx = mx + mw * 0.5 - size_f * 0.5;
            const up_y = (v.rect.y + command_menu.PADDING_PT + command_menu.INDICATOR_HEIGHT_PT * 0.5) * scale - size_f * 0.5;
            const down_y = (v.rect.y + v.rect.h - command_menu.PADDING_PT - command_menu.INDICATOR_HEIGHT_PT * 0.5) * scale - size_f * 0.5;
            const pairs = [2]struct { kind: tab_icons.Icon, y: f32, enabled: bool }{
                .{ .kind = .chevron_up, .y = up_y, .enabled = v.can_scroll_up },
                .{ .kind = .chevron_down, .y = down_y, .enabled = v.can_scroll_down },
            };
            var ind: [2]TextInstance = undefined;
            var ind_n: usize = 0;
            for (pairs) |p| {
                const entry = self.tab_atlas.getOrInsertIcon(p.kind, ind_size, ind_stroke) orelse continue;
                ind[ind_n] = .{
                    .pos = .{ ind_cx, p.y },
                    .size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                    .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
                    .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                    .fg_color = if (p.enabled) self.chrome.ctrl_active else self.chrome.arrow_disabled,
                    .color_flag = 0,
                };
                ind_n += 1;
            }
            if (ind_n > 0) self.drawTextInstancesWithTexture(encoder, ind[0..ind_n], self.tab_atlas_texture);
        }

        var glyphs: [512]TextInstance = undefined;
        var glyph_n: usize = 0;
        const cw: f32 = @floatFromInt(self.tab_font.cell_width_px);
        const ch: f32 = @floatFromInt(self.tab_font.cell_height_px);
        const emit = struct {
            fn text(r: *MetalRenderer, bytes: []const u8, start_x: f32, text_top: f32, color: [4]f32, out: []TextInstance, n: *usize) void {
                var x = start_x;
                var iter = std.unicode.Utf8Iterator{ .bytes = bytes, .i = 0 };
                while (iter.nextCodepoint()) |cp| {
                    if (n.* >= out.len) return;
                    const result = r.tab_font.resolveGlyph(@intCast(cp), .regular) orelse continue;
                    const entry = r.tab_atlas.getOrInsert(result.font, @intCast(result.index)) orelse {
                        mac_font.releaseCluster(result);
                        continue;
                    };
                    mac_font.releaseCluster(result);
                    if (entry.w > 0 and entry.h > 0) {
                        out[n.*] = .{
                            .pos = .{ x + @as(f32, @floatFromInt(entry.bearing_x)), text_top + r.tab_font.ascent_px - @as(f32, @floatFromInt(entry.bearing_y)) - @as(f32, @floatFromInt(entry.h)) },
                            .size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                            .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
                            .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
                            .fg_color = color,
                            .color_flag = if (entry.is_color) 1 else 0,
                        };
                        n.* += 1;
                    }
                    x += @as(f32, @floatFromInt(display_width.codepointWidth(@intCast(cp)))) * @as(f32, @floatFromInt(r.tab_font.cell_width_px));
                }
            }
        }.text;
        for (v.first..v.first + v.count) |i| {
            const command = command_menu.entries[i] orelse continue;
            const item = command_menu.entryRect(v, i).?;
            const ix = item.x * scale;
            const iy = item.y * scale;
            const iw = item.w * scale;
            const ih = item.h * scale;
            const text_top = iy + (ih - ch) * 0.5;
            emit(self, command_menu.label(command), ix + 8 * scale, text_top, self.chrome.menu_label, &glyphs, &glyph_n);
            const hint = command_menu.shortcut(command, true, toggle_hotkey, ui.fullscreen_workarea);
            if (hint.len > 0) {
                const hint_w = @as(f32, @floatFromInt(display_width.stringWidth(hint))) * cw;
                const label_w = @as(f32, @floatFromInt(display_width.stringWidth(command_menu.label(command)))) * cw;
                // #329 — 좁은 메뉴 / 긴 configured hotkey 에서 label 과 겹치면
                // hint 를 먼저 숨긴다 (label 우선 정책, 세 renderer 공통).
                if (command_menu.hintFits(item.w, label_w / scale, hint_w / scale)) {
                    emit(self, hint, ix + iw - 8 * scale - hint_w, text_top, self.chrome.menu_hint, &glyphs, &glyph_n);
                }
            }
        }
        if (glyph_n > 0) {
            self.drawTextInstancesWithTexture(encoder, glyphs[0..glyph_n], self.tab_atlas_texture);
        }
    }

    pub fn tabAtlasDirty(self: *const MetalRenderer) bool {
        return self.tab_atlas.dirty;
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

    fn uploadAtlas(_: *MetalRenderer, atlas: *GlyphAtlas, texture: objc.id) void {
        const Region = extern struct { ox: usize, oy: usize, oz: usize, sx: usize, sy: usize, sz: usize };
        const region = Region{ .ox = 0, .oy = 0, .oz = 0, .sx = ATLAS_SIZE, .sy = ATLAS_SIZE, .sz = 1 };

        const f: *const fn (objc.id, objc.SEL, Region, objc.NSUInteger, [*]const u8, objc.NSUInteger) callconv(.c) void = @ptrCast(objc.msgSend_raw);
        f(
            texture,
            objc.sel("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"),
            region,
            0,
            atlas.pixels.ptr,
            ATLAS_SIZE * 4, // BGRA8 = 4 bytes per pixel.
        );
    }

    fn uploadTabAtlasIfDirty(self: *MetalRenderer) void {
        if (!self.tab_atlas.dirty) return;
        self.uploadAtlas(&self.tab_atlas, self.tab_atlas_texture);
        self.tab_atlas.dirty = false;
    }

    fn drawBgInstances(self: *MetalRenderer, encoder: objc.id, instances: []const BgInstance) void {
        if (instances.len == 0) return;
        // 이번 frame 의 총 수요 누적 (drop 돼도 셈) — frame 시작에서 buffer 확대 판단용.
        self.bg_needed += @intCast(instances.len);
        // 현재 용량 초과면 이 호출만 drop. 다음 frame 시작에서 buffer 가 커져 복구.
        if (self.bg_used + instances.len > self.bg_capacity) return;

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
        self.drawTextInstancesWithTexture(encoder, instances, self.atlas_texture);
    }

    fn drawTextInstancesWithTexture(self: *MetalRenderer, encoder: objc.id, instances: []const TextInstance, texture: objc.id) void {
        if (instances.len == 0) return;
        self.text_needed += @intCast(instances.len);
        if (self.text_used + instances.len > self.text_capacity) return;

        const contents_ptr = objc.msgSend(self.text_buffer, objc.sel("contents")) orelse return;
        const contents: [*]TextInstance = @ptrCast(@alignCast(contents_ptr));
        @memcpy(contents[self.text_used..][0..instances.len], instances);

        const offset_bytes: objc.NSUInteger = @as(objc.NSUInteger, self.text_used) * @sizeOf(TextInstance);

        objc.msgSendVoid1(encoder, objc.sel("setRenderPipelineState:"), self.text_pipeline);
        objc.msgSendVoid3(encoder, objc.sel("setVertexBuffer:offset:atIndex:"), self.text_buffer, offset_bytes, @as(objc.NSUInteger, 0));
        objc.msgSendVoid3(encoder, objc.sel("setVertexBuffer:offset:atIndex:"), self.constants_buffer, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 1));
        objc.msgSendVoid2(encoder, objc.sel("setFragmentTexture:atIndex:"), texture, @as(objc.NSUInteger, 0));

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

    /// 직전 frame 이 요청한 instance 수(`*_needed`)가 현재 buffer 용량을 넘으면
    /// 2배씩 키워 다음 frame 부터 drop 없이 그린다 (monotonic — 줄이진 않음).
    /// frame 시작에서만 호출 (아직 draw encode 전이라 안전). 옛 buffer 는 직전
    /// frame 의 command buffer 가 retain 하므로 release 해도 in-flight 안전.
    fn growInstanceBuffers(self: *MetalRenderer) void {
        if (self.bg_needed > self.bg_capacity) {
            var cap = self.bg_capacity;
            while (cap < self.bg_needed) cap *|= 2;
            const buf = createBuffer(self.device, cap * @sizeOf(BgInstance));
            if (buf != null) {
                objc.msgSendVoid(self.bg_buffer, objc.sel("release"));
                self.bg_buffer = buf;
                self.bg_capacity = cap;
            }
        }
        if (self.text_needed > self.text_capacity) {
            var cap = self.text_capacity;
            while (cap < self.text_needed) cap *|= 2;
            const buf = createBuffer(self.device, cap * @sizeOf(TextInstance));
            if (buf != null) {
                objc.msgSendVoid(self.text_buffer, objc.sel("release"));
                self.text_buffer = buf;
                self.text_capacity = cap;
            }
        }
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

/// 한 cell 의 atlas entry 를 `text_buf` 에 instance 로 emit. base cell index `x`
/// + 추가 dx/dy (`.spacer` 의 cell 별 offset 또는 `.single` 의 0). atlas entry
/// 의 bearing 으로 glyph 의 cell 안 위치 계산.
/// wide 글리프(한글/CJK/emoji)를 배정된 셀 영역(1 또는 2셀) 가운데로 (#299 —
/// Linux software renderer 의 `(cell_w − advance)/2` 와 동일 정책). primary
/// Latin 은 advance ≈ cell_w 라 0. 정수 px 로 floor — Latin 의 sub-px 이동을
/// 만들지 않기 위함 (Linux 의 정수 divFloor 와 동일 의미).
fn glyphCenterDx(entry: macos_glyph_atlas.AtlasEntry, wide: bool, cw: f32) f32 {
    if (entry.advance <= 0) return 0;
    const span: f32 = if (wide) 2.0 else 1.0;
    return @floor((span * cw - entry.advance) / 2.0);
}

fn emitTextInstance(
    text_buf: []TextInstance,
    text_count: *u32,
    entry: macos_glyph_atlas.AtlasEntry,
    x: usize,
    fy: f32,
    cw: f32,
    x_pad: f32,
    ascent_px: f32,
    fg_rgb: ghostty.color.RGB,
    dx: f32,
    dy: f32,
) void {
    const fx: f32 = @as(f32, @floatFromInt(x)) * cw + x_pad + dx;
    const gx = fx + @as(f32, @floatFromInt(entry.bearing_x));
    const gy = fy + ascent_px - @as(f32, @floatFromInt(entry.bearing_y)) - @as(f32, @floatFromInt(entry.h)) + dy;
    text_buf[text_count.*] = .{
        .pos = .{ gx, gy },
        .size = .{ @as(f32, @floatFromInt(entry.w)), @as(f32, @floatFromInt(entry.h)) },
        .uv_pos = .{ @floatFromInt(entry.x), @floatFromInt(entry.y) },
        .uv_size = .{ @floatFromInt(entry.w), @floatFromInt(entry.h) },
        .fg_color = .{ MetalRenderer.colorF(fg_rgb.r), MetalRenderer.colorF(fg_rgb.g), MetalRenderer.colorF(fg_rgb.b), 1 },
        .color_flag = if (entry.is_color) 1 else 0,
    };
    text_count.* += 1;
}

/// `LigatureMatch` switch — `.single` 은 1 glyph 을 base cell 에 (font 의 자연
/// width 그대로, ligature glyph 이 N-cell wide bbox 가짐), `.spacer` 는 각
/// glyph 을 자기 cell 에 (1-cell wide each). 모두 primary font 의 glyph_index
/// 로 atlas lookup.
///
/// 호출자가 N 의 trailing cells 의 bg/selection 은 bg pass 에서 이미 그렸으니
/// text pass 만 처리. text_buf overflow 면 flush.
fn emitLigatureMatch(
    self: *MetalRenderer,
    encoder: objc.id,
    text_buf: []TextInstance,
    text_count: *u32,
    x: usize,
    count: usize,
    match: mac_font.LigatureMatch,
    fy: f32,
    cw: f32,
    x_pad: f32,
    fg_rgb: ghostty.color.RGB,
) void {
    _ = count;
    switch (match) {
        .single => |lg| {
            if (text_count.* >= text_buf.len) {
                self.drawTextInstances(encoder, text_buf[0..text_count.*]);
                text_count.* = 0;
            }
            const entry = self.atlas.getOrInsert(self.font.primary_font, @intCast(lg.glyph_index)) orelse return;
            if (entry.w == 0 or entry.h == 0) return;
            emitTextInstance(text_buf, text_count, entry, x, fy, cw, x_pad, self.font.ascent_px, fg_rgb, @as(f32, @floatFromInt(lg.x_offset)), @as(f32, @floatFromInt(lg.y_offset)));
        },
        .spacer => |sp| {
            for (0..sp.count) |i| {
                if (text_count.* >= text_buf.len) {
                    self.drawTextInstances(encoder, text_buf[0..text_count.*]);
                    text_count.* = 0;
                }
                const entry = self.atlas.getOrInsert(self.font.primary_font, @intCast(sp.glyph_indices[i])) orelse continue;
                if (entry.w == 0 or entry.h == 0) continue;
                emitTextInstance(text_buf, text_count, entry, x + i, fy, cw, x_pad, self.font.ascent_px, fg_rgb, @as(f32, @floatFromInt(sp.x_offsets[i])), @as(f32, @floatFromInt(sp.y_offsets[i])));
            }
        },
    }
}

// --- 색상 해석 — 공유 모듈 `cell_color.zig` (#282 B2, 세 renderer 공통 정책) ---

/// null (= cell 고유 bg 없음) 을 default-bg float 로 변환만 — 호출부가
/// is_custom_bg 로 instance 생략하므로 실제로는 도달 안 하는 방어값.
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
    if (cell_color.resolveBg(style, raw, colors, is_selected, is_inverse)) |rgb| {
        return .{ MetalRenderer.colorF(rgb.r), MetalRenderer.colorF(rgb.g), MetalRenderer.colorF(rgb.b) };
    }
    return .{ dbg_r, dbg_g, dbg_b };
}

const resolveFg = cell_color.resolveFg;
