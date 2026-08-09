//! Linux 폰트 컨텍스트 — fontconfig 로 family path 조회 + FreeType 으로 face
//! 로드 + per-face lazy raster cache + chain fallback lookup.
//!
//! [src/font/windows/font.zig](../windows/font.zig) (DWriteFontContext) /
//! [src/font/macos/font.zig](../macos/font.zig) (CoreTextFontContext) 와 같은
//! 역할. `glyph(cp)` 가 primary → fallback chain 순회로 첫 매치 face 에서
//! raster + cache. chain 모두 미스면 fontconfig charset 매치로 system font
//! fallback (#289 B5 — Windows `MapCharacters` / macOS `CTFontCreateForString`
//! 동등), 그마저 미보유면 primary 의 placeholder ('?') 반환.
//!
//! 8bpp gray (`FT_PIXEL_MODE_GRAY`) 와 color (`FT_PIXEL_MODE_BGRA`, Noto Color
//! Emoji 등) 둘 다 raster — Glyph.pixel_mode 로 호출자 (`software_terminal.paint`)
//! 가 두 path 갈래.

const std = @import("std");
const fontconfig = @import("fontconfig.zig");
const freetype = @import("freetype.zig");
const harfbuzz = @import("harfbuzz.zig");
const log = @import("../../log.zig");
const perf = @import("../../perf.zig");
const font_constants = @import("../constants.zig");
const ligature = @import("../ligature.zig");
const cluster_cache = @import("../cluster_cache.zig");
const font_spec = @import("../spec.zig");

pub const MAX_CHAIN: usize = font_constants.MAX_CHAIN;

/// #289 B5 — system fallback face 의 상한. chain 밖 codepoint 가 요구하는
/// 스크립트 다양성의 실사용 범위(수 개)를 넉넉히 덮되, 비정상 입력이 face
/// 를 무한 로드하지 않게 cap. 도달 시 신규 로드만 중단 (placeholder 로 degrade,
/// 로그 1줄) — 기로드 face 는 계속 동작.
const MAX_FALLBACK: usize = 8;

/// #419 — `face_idx` 에서 **system fallback face 를 가리키는 구간**의 시작.
///
/// chain 은 최대 8 (`MAX_CHAIN`) 이라 `0x80` 위와 겹치지 않는다. index 공간을 나눠 두면
/// `ClusterGlyph.face_idx` · `GlyphRef.indexed.face` · atlas key 가 전부 `u8` 그대로여도
/// 두 종류를 구분할 수 있다 — 렌더러와 atlas 를 손대지 않아도 되는 이유다.
const FALLBACK_FACE_BASE: u8 = 0x80;

/// #362 — 해석 캐시의 배열 갈래가 덮는 범위 (`0x20`~`0x7E`, printable ASCII).
/// 터미널 텍스트의 대부분이라 이 구간만 해시를 피해도 대부분을 피한다.
const ASCII_LO: u21 = 0x20;
const ASCII_HI: u21 = 0x7E;
const ASCII_SPAN: usize = ASCII_HI - ASCII_LO + 1;

fn asciiSlot(cp: u21) ?usize {
    if (cp < ASCII_LO or cp > ASCII_HI) return null;
    return cp - ASCII_LO;
}

/// #399 — 한 번의 shape 호출로 묶는 cluster 수 상한. 넘으면 caller 가 런을 끊고
/// 다음 런이 이어받는다. Windows 판과 같은 값이다 (`MAX_RUN_CLUSTERS = 32`) — 이 값이
/// shaping 작업 버퍼 크기를 정하는데, 32 면 codepoint 버퍼가 2 KB 로 지역 배열에 둘 만하다.
pub const MAX_RUN_CLUSTERS = 32;

/// cluster 하나가 가질 수 있는 codepoint 수 상한. 셀 루프의 개별 경로가 쓰는
/// `cluster: [16]u21` (base 1 + extras 15) 과 **같은 값이어야** 배칭과 개별 경로가 같은
/// cluster 를 본다.
pub const MAX_CLUSTER_CPS = 16;

/// #401 — cluster 하나가 만들 수 있는 글리프 수 상한. codepoint 수보다 많을 수 있어
/// (shaping 이 하나를 여럿으로 분해하는 경우) 여유를 둔다. Windows 판의
/// `MAX_CLUSTER_GLYPHS` 와 같은 역할이다.
pub const MAX_CLUSTER_GLYPHS = 32;

/// #401 — 합성 비트맵 한 변의 상한 (px). 넘으면 합성을 포기한다 (caller 가 다음 face 로).
/// 정상적인 cluster 는 셀 두어 개 크기를 넘지 않는다 — 이 값은 폰트가 비정상적으로 큰
/// 글리프를 주거나 배치 계산이 어긋났을 때 메모리를 지키는 상한이다.
const MAX_COMPOSED_PX: usize = 512;

// Cross-platform ligature 타입 re-export — caller (software_terminal.zig)
// 가 `font.LigatureMatch` 식으로 그대로 쓸 수 있게.
pub const LigatureGlyph = ligature.LigatureGlyph;
pub const LigatureSpacer = ligature.LigatureSpacer;
pub const LigatureMatch = ligature.LigatureMatch;

/// #401 — grapheme cluster 하나의 그리기 결과.
///
/// **cluster 가 글리프 하나로 합성되지 않는 경우가 있다.** 폰트에 precomposed 글리프가
/// 없는 결합 기호 (`a` + `U+0305`) 가 대표적이고, 그때 HarfBuzz 는 base 와 mark 를 각각
/// 돌려주며 offset 으로 겹쳐 그리라고 지시한다. 예전에는 그런 face 를 `n != 1` 로 거부해
/// chain 전체가 미매치가 됐고, caller 가 base codepoint 로 fallback 해서 **악센트가 통째로
/// 사라졌다** (#401 에서 실측 1,891 조합).
///
/// 그래서 `composed` 갈래를 둔다 — 여러 글리프를 한 비트맵으로 미리 구워 두고 그 캐시
/// 키를 든다. Windows 의 `getOrInsertCluster` · macOS 의 `rasterizeCluster` 와 같은 자리다.
pub const ClusterGlyph = struct {
    /// chain index 의 face.
    face_idx: u8 = 0,
    /// `composed` 가 false 면 FreeType glyph index (`glyphByIndex` 로 raster),
    /// true 면 합성 비트맵의 캐시 키 (`composedGlyph` 로 조회).
    glyph_index: u32,
    /// GPOS offset. 합성 글리프는 offset 이 비트맵 안에 이미 반영돼 있어 0 이다.
    x_offset: i32 = 0,
    y_offset: i32 = 0,
    composed: bool = false,
};

pub const Glyph = struct {
    /// gray = width × height × 1 byte (alpha). BGRA = width × height × 4 byte
    /// (premultiplied alpha). width=0 또는 height=0 이면 invisible (예: space).
    bitmap: []u8,
    width: u32,
    height: u32,
    bitmap_left: i32,
    bitmap_top: i32,
    advance: u32,
    /// `FT_PIXEL_MODE_GRAY` 또는 `FT_PIXEL_MODE_BGRA`. 그 외는 invisible bitmap.
    pixel_mode: u8,
};

/// HarfBuzz 가 shape 한 한 glyph. `cluster` 는 입력 codepoint array 의 어느
/// index 의 char 에서 나왔는지 (ligature 면 여러 char 가 같은 cluster index 공유).
/// mac `resolveGrapheme` 의 CTRun glyph / Win `shapeOnFaceMulti` 의 dwrite glyph
/// 와 같은 의미.
pub const ShapedGlyph = struct {
    /// FreeType `FT_Load_Glyph(idx, ...)` 에 직접 넣을 수 있는 glyph index. shape
    /// 결과라 codepoint 와 다른 값 (예: `=>` 가 한 ligature glyph 인덱스로 collapse).
    glyph_index: u32,
    /// 입력 codepoint array 의 *시작* index. ligature 면 첫 char 의 index, 그 뒤
    /// char 들은 같은 cluster 공유 (= 결과 ShapedGlyph 에 안 나옴).
    cluster: u32,
    /// 26.6 fixed point 의 integer 부 (px) — HarfBuzz 반환값을 >> 6.
    x_advance: i32,
    x_offset: i32,
    y_offset: i32,
};

pub const Face = struct {
    allocator: std.mem.Allocator,
    ft_face: freetype.FT_Face,
    family: []u8,
    /// 로딩 시 fontconfig 가 반환한 파일 path — chain 중복 제거에 사용.
    path: []u8,
    /// codepoint → Glyph cache (단순 lookup path, `Context.glyph` 가 사용).
    ///
    /// **`Glyph` 를 값이 아니라 개별 할당한 포인터로 담는다** — 그래야 주소가
    /// 고정되어 캐시에 들어간 글리프를 프레임 목록이 포인터로 들 수 있다. 값으로
    /// 담으면 재해싱 때 주소가 움직여 먼저 얻은 포인터가 무효가 되고, 그것 때문에
    /// `GlyphItem` 이 48 B 를 통째로 복사해야 했다 (#362).
    glyph_cache: std.AutoHashMap(u21, *Glyph),
    /// glyph_index → Glyph cache (shape 결과의 ligature glyph 등 codepoint 와
    /// 다른 idx 의 cache). `Context.shapeRun` 의 결과 raster 가 사용.
    glyph_by_index: std.AutoHashMap(u32, *Glyph),
    /// HarfBuzz hb_font (FT_Face 의 referenced wrap). HarfBuzz API 가 advertise
    /// 안 되거나 dlopen 실패 시 null — 그 경우 `shapeRun` 도 fallback (= 단순
    /// codepoint loop).
    hb_font: ?*harfbuzz.hb_font_t = null,

    fn deinit(self: *Face, ft_api: freetype.Api, hb_api: ?*const harfbuzz.Api) void {
        var it = self.glyph_cache.valueIterator();
        while (it.next()) |slot| {
            if (slot.*.bitmap.len > 0) self.allocator.free(slot.*.bitmap);
            self.allocator.destroy(slot.*);
        }
        self.glyph_cache.deinit();
        var it2 = self.glyph_by_index.valueIterator();
        while (it2.next()) |slot| {
            if (slot.*.bitmap.len > 0) self.allocator.free(slot.*.bitmap);
            self.allocator.destroy(slot.*);
        }
        self.glyph_by_index.deinit();
        if (self.hb_font) |hb| {
            if (hb_api) |api| api.font_destroy(hb);
        }
        _ = ft_api.done_face(self.ft_face);
        self.allocator.free(self.family);
        self.allocator.free(self.path);
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    ft_api: freetype.Api,
    ft_lib: freetype.FT_Library,
    /// HarfBuzz dlopen 결과. dlopen 실패 시 null — `shapeRun` 이 fallback (단순
    /// codepoint loop, ligature 안 됨, 기능 자체는 유지). compositor / OS 가
    /// libharfbuzz.so.0 없는 minimal Linux 환경 graceful degrade.
    hb_api: ?harfbuzz.Api = null,
    /// shape 호출 사이 reuse 하는 buffer. shape 마다 clear_contents 호출 후 재사용.
    hb_buffer: ?*harfbuzz.hb_buffer_t = null,
    /// #399 — cluster shaping 이 **직전에 성공한 face**. chain 순회를 이 face 부터
    /// 시작한다.
    ///
    /// **이게 Linux 의 진짜 병목이었다.** mac (CoreText) · Win (DirectWrite) 은 호출당
    /// 고정 비용 (`CTLine` 생성 · COM 왕복) 이 커서 런 배칭만으로 크게 줄었는데,
    /// HarfBuzz 는 그 고정 비용이 작고 **codepoint 수에 비례**한다. 그래서 배칭해도
    /// chain 앞쪽의 emoji 없는 face 들에서 런 전체를 shape 하고 버리는 작업량이 그대로
    /// 남아, `zwj` 는 shape 호출이 11 배 줄었는데도 시간이 -0.4 % 였다 (실측).
    ///
    /// 터미널 화면은 같은 종류의 cluster 가 이어지는 것이 보통이라 (한 줄이 전부 emoji
    /// 이거나 전부 한글), 직전 face 를 먼저 보면 대부분 한 번에 맞는다. 틀리면 기존대로
    /// 전체를 돌므로 **결과는 바뀌지 않고 순서만 바뀐다.**
    last_cluster_face: u8 = 0,
    /// pair/triple lookahead cache. 세 backend 공통 key + positive/negative 저장.
    ligature_cache: ligature.Cache,
    /// #399 (B) — grapheme cluster shaping 결과 cache. 세 platform 공용 모듈이고
    /// Linux 값은 `ClusterGlyph` (face index + glyph/합성 키) 라 소유권이 없어 `release`
    /// 가 `null` 이다. **Linux 에서 이게 주 레버다** — HarfBuzz 는 호출당 고정 비용이 작아
    /// 런 배칭이 준 것이 작았고 (`zwj` -0.4 %), 남은 비용은 shape 작업량 자체라 그것을
    /// 통째로 건너뛰는 캐시가 듣는다.
    cluster_cache: cluster_cache.ClusterCache(ClusterGlyph, null),
    /// #401 — 여러 글리프를 한 비트맵으로 합성한 결과. 키는 `(face << 32) | 해시` 이고
    /// 해시는 글리프 인덱스 · offset · advance 로 만든다 (macOS atlas 가 `Wyhash` 를
    /// truncate 해 키로 쓰는 것과 같은 패턴).
    ///
    /// **`Face.glyph_by_index` 에 못 담는다** — 그 키는 glyph index 하나인데 합성 결과는
    /// *글리프 조합*이라서다. `Glyph` 를 개별 할당한 포인터로 담는 것은 그쪽과 같은
    /// 이유다 (#362 — 재해싱이 주소를 옮기면 프레임 목록의 포인터가 죽는다).
    composed_glyphs: std.AutoHashMap(u64, *Glyph),
    faces: [MAX_CHAIN]?Face,
    face_count: usize,
    /// #375 — bold · italic · bold_italic chain. regular 는 위 `faces` 가 담당하므로
    /// 3 벌만 둔다 (`FaceStyle.index() - 1` 로 색인).
    ///
    /// **처음 필요할 때 로드한다** (`ensureStyledChain`). chain 이 최대 8 이라 즉시
    /// 로드하면 face 가 32 개가 되고, dialog 폰트를 lazy 로 돌린 것과 같은 이유로
    /// (#368 — 시작 시간의 절반) 시작이 느려진다. bold / italic 을 안 쓰는 세션이
    /// 대부분이다.
    ///
    /// `null` 인 칸은 **regular face 를 그대로 쓴다** — 해당 변종 face 가 없거나
    /// (fontconfig 가 regular 와 같은 파일을 돌려준 경우) 로드에 실패한 경우다.
    styled_faces: [font_constants.FaceStyle.count - 1][MAX_CHAIN]?Face,
    /// 변종 chain 로드를 시도했는가. 실패해도 true 라 매 프레임 재시도하지 않는다.
    styled_loaded: [font_constants.FaceStyle.count - 1]bool,

    /// #289 B5 — chain 밖 codepoint 용 system fallback faces (fontconfig
    /// charset 매치로 lazy 로드). chain `faces` 와 분리 저장 — `glyphByIndex`
    /// / shape 경로의 face_idx 는 chain 만 가리키므로 index 충돌 없음.
    fallback_faces: [MAX_FALLBACK]?Face,
    fallback_count: usize,
    /// cp → fallback_faces index. **null = 시스템 전체에 없음** (negative
    /// cache — 없으면 미보유 cp 가 cell 마다 매 frame fontconfig 왕복 유발).
    system_fallback: std.AutoHashMap(u21, ?u8),

    /// #362 — cp → 최종 글리프. `glyph` 가 chain 순회 · `FT_Get_Char_Index` ·
    /// face 캐시 조회 · system fallback 조회를 통째로 건너뛰게 해 준다.
    /// ASCII (`0x20`~`0x7E`) 는 배열, 나머지는 맵. `freeFaces` 가 비운다.
    /// #375 — face 변종별로 나눈다. 같은 cp 라도 bold 와 regular 는 다른 글리프다.
    resolved_ascii: [font_constants.FaceStyle.count][ASCII_SPAN]?*const Glyph,
    resolved: [font_constants.FaceStyle.count]std.AutoHashMap(u21, *const Glyph),
    /// chain 로드 시 pixel size — system fallback face 를 같은 크기로 로드.
    pixel_height: u32,

    cell_width_px: u32,
    cell_height_px: u32,
    ascent_px: u32,
    descent_px: u32,

    placeholder: Glyph,

    pub fn init(
        allocator: std.mem.Allocator,
        families: []const []const u8,
        pixel_height: u32,
        cell_width_ratio: f32,
        line_height_ratio: f32,
    ) !Context {
        if (families.len == 0) return error.NoFamilies;

        var ft_api = try freetype.Api.load();
        errdefer ft_api.deinit();

        var ft_lib: freetype.FT_Library = undefined;
        if (ft_api.init_free_type(&ft_lib) != 0) return error.FreetypeInitFailed;
        errdefer _ = ft_api.done_free_type(ft_lib);

        // HarfBuzz dlopen 시도. 실패해도 fatal 아님 — `shapeRun` 이 fallback
        // (codepoint loop, ligature 안 됨). graceful degrade.
        var hb_api: ?harfbuzz.Api = harfbuzz.Api.load() catch |err| blk: {
            log.appendLine("font", "HarfBuzz load skipped: {s} — ligature / cluster shape disabled", .{@errorName(err)});
            break :blk null;
        };
        errdefer if (hb_api) |*api| api.deinit();
        const hb_buffer = if (hb_api) |api| api.buffer_create() else null;
        errdefer if (hb_buffer) |b| if (hb_api) |api| api.buffer_destroy(b);

        var self: Context = .{
            .allocator = allocator,
            .ft_api = ft_api,
            .ft_lib = ft_lib,
            .hb_api = hb_api,
            .hb_buffer = hb_buffer,
            .ligature_cache = ligature.Cache.init(allocator),
            .cluster_cache = cluster_cache.ClusterCache(ClusterGlyph, null).init(allocator),
            .composed_glyphs = std.AutoHashMap(u64, *Glyph).init(allocator),
            .faces = [_]?Face{null} ** MAX_CHAIN,
            .face_count = 0,
            .styled_faces = .{[_]?Face{null} ** MAX_CHAIN} ** (font_constants.FaceStyle.count - 1),
            .styled_loaded = .{false} ** (font_constants.FaceStyle.count - 1),
            .fallback_faces = [_]?Face{null} ** MAX_FALLBACK,
            .fallback_count = 0,
            .system_fallback = std.AutoHashMap(u21, ?u8).init(allocator),
            .resolved_ascii = .{[_]?*const Glyph{null} ** ASCII_SPAN} ** font_constants.FaceStyle.count,
            .resolved = .{std.AutoHashMap(u21, *const Glyph).init(allocator)} ** font_constants.FaceStyle.count,
            .pixel_height = pixel_height,
            .cell_width_px = pixel_height / 2,
            .cell_height_px = pixel_height,
            .ascent_px = 0,
            .descent_px = 0,
            .placeholder = .{
                .bitmap = &.{},
                .width = 0,
                .height = 0,
                .bitmap_left = 0,
                .bitmap_top = 0,
                .advance = 0,
                .pixel_mode = freetype.FT_PIXEL_MODE_GRAY,
            },
        };
        errdefer self.freeFaces();

        const max_load = @min(families.len, MAX_CHAIN);
        for (families[0..max_load], 0..) |family, i| {
            self.tryLoadFamily(family, i, pixel_height) catch |err| {
                log.appendLine("font", "chain[{d}] skip family={s} err={s}", .{ i, family, @errorName(err) });
            };
        }

        if (self.face_count == 0) return error.NoFaceLoaded;

        // L13-β — config.cell_width_ratio / line_height_ratio 적용. measured
        // 값에 곱해 저장 — `Renderer.cellWidth/cellHeight` getter 가 단순
        // 반환만 하면 자동으로 ratio 가 적용됨. 1.0 / 1.1 등 사용자가
        // config_N.json 으로 조절 가능 (Config 검증 범위 0.5..2.0).
        self.cell_width_px = font_spec.ceilPositivePx(@as(f32, @floatFromInt(self.cell_width_px)) * cell_width_ratio);
        self.cell_height_px = font_spec.ceilPositivePx(@as(f32, @floatFromInt(self.cell_height_px)) * line_height_ratio);
        log.appendLineVerbose("font", "applied ratios cell_w={} cell_h={} cell_width_ratio={d:.2} line_height_ratio={d:.2}", .{
            self.cell_width_px,
            self.cell_height_px,
            cell_width_ratio,
            line_height_ratio,
        });

        return self;
    }

    /// 한 family 의 path 조회 + face 등록. 실패는 caller 가 잡고 skip (err return).
    fn tryLoadFamily(self: *Context, family: []const u8, log_idx: usize, pixel_height: u32) !void {
        const family_z = try self.allocator.allocSentinel(u8, family.len, 0);
        defer self.allocator.free(family_z);
        @memcpy(family_z[0..family.len], family);

        const fc_result = try fontconfig.lookup(self.allocator, family_z.ptr);
        defer fc_result.deinitAdditionalFamilies(self.allocator);
        defer self.allocator.free(fc_result.family);
        var path_owned_by_face = false;
        defer if (!path_owned_by_face) self.allocator.free(fc_result.path);

        // fontconfig 는 정확한 매치 없으면 fallback substitution 으로 다른 family
        // 의 path 를 반환한다. generic family ("monospace" 등) 는 substitution 이
        // 의도 — 시스템 default 매치. specific family 는 결과 family 명이 우리
        // 요청과 반환 family/alias 항목이 exact match가 아니면 substitution으로
        // 판단 + skip. 이름 내부의 부분 문자열은 설치 증거가 아니다.
        // (config 명시 chain 은 boot 검증 — `familyInstalled`, 같은 판정 규칙 —
        // 을 이미 통과했으므로 여기 skip 은 face 로드 실패류만 남는다, #289 B6.)
        // #406 — 예전에는 여기서 skip 했지만 (`error.FontconfigFallbackSubstitution`) 이제
        // **그 폰트로 로드한다.** 대체됐다는 것은 요청한 이름이 시스템에 없다는 뜻이 아니라
        // (그건 위 `lookup` 이 `FontconfigNoMatch` 로 걸러 낸다) 별칭 규칙이 다른 폰트를
        // 가리키게 했다는 뜻이다. 그 폰트는 실재하므로 글자는 그려진다.
        //
        // 사용자가 나중에 "왜 다른 폰트로 보이지" 를 추적할 수 있도록 로그를 남긴다.
        if (!matchResolvesFamily(family, fc_result.family, fc_result.additional_families)) {
            log.appendLine("font", "chain[{d}] \"{s}\" resolved to \"{s}\" (system alias) — using it", .{
                log_idx, family, fc_result.family,
            });
        }

        // 같은 path 가 chain 안 이미 있으면 dedup. log 인덱스 = 매치된 face 의
        // 실제 index (자기 자신이 아니라).
        for (self.faces[0..self.face_count], 0..) |slot, idx| {
            const existing = slot orelse continue;
            if (std.mem.eql(u8, existing.path, fc_result.path)) {
                log.appendLineVerbose("font", "chain[{d}] dedup family={s} path={s} (same as chain[{d}])", .{
                    log_idx, family, fc_result.path, idx,
                });
                return;
            }
        }

        const path_z = try self.allocator.allocSentinel(u8, fc_result.path.len, 0);
        defer self.allocator.free(path_z);
        @memcpy(path_z[0..fc_result.path.len], fc_result.path);

        var ft_face: freetype.FT_Face = undefined;
        if (self.ft_api.new_face(self.ft_lib, path_z.ptr, 0, &ft_face) != 0) {
            return error.FreetypeNewFaceFailed;
        }
        errdefer _ = self.ft_api.done_face(ft_face);

        // set_pixel_sizes 가 fixed-strike 폰트 (Noto Color Emoji 등) 에서 fail
        // 가능. fail 면 첫 strike 선택으로 fallback.
        if (self.ft_api.set_pixel_sizes(ft_face, 0, pixel_height) != 0) {
            if (ft_face.num_fixed_sizes <= 0 or self.ft_api.select_size(ft_face, 0) != 0) {
                return error.FreetypeSetSizeFailed;
            }
        }

        // primary face 자격 — 'M' glyph 가 있어야 cell metric 측정 가능. emoji
        // 폰트 (Noto Color Emoji 등) 가 chain 의 첫 family 로 시도되어도 'M' 없으면
        // primary 자리 미적임. 다음 family 시도.
        const m_idx = self.ft_api.get_char_index(ft_face, 'M');
        if (self.face_count == 0 and m_idx == 0) {
            return error.NoLatinM;
        }

        const family_owned = try self.allocator.dupe(u8, family);
        errdefer self.allocator.free(family_owned);

        // HarfBuzz 가 advertise 됐으면 FT_Face 를 hb_font 로 wrap. `_referenced`
        // 변종은 FT_Reference_Face 자동 — hb_font_destroy 시 FT_Done_Face 도 자동.
        // FT_Face 의 ownership 은 *hb_font 와 우리 둘 다 부분 소유* — Face.deinit
        // 에서 hb_font_destroy 호출 → FT 의 ref count 감소, 우리 FT_Done_Face
        // 가 마지막 ref 제거.
        const hb_font: ?*harfbuzz.hb_font_t = if (self.hb_api) |*api|
            api.ft_font_create_referenced(@ptrCast(ft_face))
        else
            null;

        self.faces[self.face_count] = .{
            .allocator = self.allocator,
            .ft_face = ft_face,
            .family = family_owned,
            .path = fc_result.path,
            .glyph_cache = std.AutoHashMap(u21, *Glyph).init(self.allocator),
            .glyph_by_index = std.AutoHashMap(u32, *Glyph).init(self.allocator),
            .hb_font = hb_font,
        };
        path_owned_by_face = true;
        self.face_count += 1;

        // #197 — chain detail (path 포함) 은 verbose. primary 의 path 도 여기 남고,
        // production 1줄 lifecycle 은 path 없이 cross-platform 동일 형식.
        log.appendLineVerbose("font", "chain[{d}] family={s} path={s}", .{ log_idx, family, fc_result.path });

        if (self.face_count == 1) {
            if (m_idx != 0 and self.ft_api.load_glyph(ft_face, m_idx, 0) == 0) {
                if (ft_face.glyph) |m_slot| {
                    const adv = @divFloor(m_slot.advance.x, 64);
                    if (adv > 0) self.cell_width_px = @intCast(adv);
                }
            }
            if (ft_face.size) |size_rec| {
                const m = size_rec.metrics;
                const ascent = @divFloor(m.ascender, 64);
                const descent = @divFloor(-m.descender, 64);
                const height = @divFloor(m.height, 64);
                if (ascent > 0) self.ascent_px = @intCast(ascent);
                if (descent > 0) self.descent_px = @intCast(descent);
                if (height > 0) self.cell_height_px = @intCast(height);
            }
            // #197 — primary 1줄 lifecycle (cross-platform 동일 형식). path 는
            // platform 차이(mac/win 은 system font 라 path 없음)라 제외 — Linux
            // path 는 위 chain verbose 에 남음. fallback chain / ratios 는 verbose.
            log.appendLine("font", "primary family={s} cell_w={d} cell_h={d} ascent={d} descent={d}", .{
                family, self.cell_width_px, self.cell_height_px, self.ascent_px, self.descent_px,
            });
            self.placeholder = rasterOne(self.allocator, self.ft_api, ft_face, '?') catch self.placeholder;
        }
    }

    pub fn deinit(self: *Context) void {
        self.freeFaces();
        self.system_fallback.deinit();
        for (&self.resolved) |*m| m.deinit();
        if (self.placeholder.bitmap.len > 0) self.allocator.free(self.placeholder.bitmap);
        self.ligature_cache.deinit();
        self.cluster_cache.deinit();
        self.composed_glyphs.deinit();
        if (self.hb_api) |*api| {
            if (self.hb_buffer) |b| api.buffer_destroy(b);
            api.deinit();
            self.hb_api = null;
            self.hb_buffer = null;
        }
        _ = self.ft_api.done_free_type(self.ft_lib);
        self.ft_api.deinit();
    }

    fn freeFaces(self: *Context) void {
        // face 를 버리면 그 안의 글리프도 사라진다 — 해석 캐시가 죽은 포인터를
        // 들고 있으면 안 된다 (#362).
        self.resolved_ascii = .{[_]?*const Glyph{null} ** ASCII_SPAN} ** font_constants.FaceStyle.count;
        for (&self.resolved) |*m| m.clearRetainingCapacity();
        // #399 — cluster 캐시도 같은 이유로 비운다. face 를 버리면 담아 둔 `face_idx` ·
        // `glyph_index` 가 다른 폰트를 가리키게 된다.
        self.cluster_cache.clear();
        // #401 — 합성 비트맵도 같은 이유다. 그 face 의 글리프로 구운 것이라 face 가 바뀌면
        // 다른 그림이 된다.
        self.freeComposedGlyphs();

        const hb_api_ptr: ?*const harfbuzz.Api = if (self.hb_api) |*api| api else null;
        for (&self.faces) |*slot| {
            if (slot.*) |*face| face.deinit(self.ft_api, hb_api_ptr);
            slot.* = null;
        }
        self.face_count = 0;
        // #375 — 변종 chain 도 함께 버리고 "미로드" 로 돌린다 (폰트 재로드 시 새
        // 크기로 다시 만들어야 한다).
        for (&self.styled_faces) |*chain| {
            for (chain) |*slot| {
                if (slot.*) |*face| face.deinit(self.ft_api, hb_api_ptr);
                slot.* = null;
            }
        }
        self.styled_loaded = .{false} ** (font_constants.FaceStyle.count - 1);
        for (&self.fallback_faces) |*slot| {
            if (slot.*) |*face| face.deinit(self.ft_api, hb_api_ptr);
            slot.* = null;
        }
        self.fallback_count = 0;
    }

    /// #401 — 합성 비트맵을 전부 버린다. 맵 자체는 남긴다 (`deinit` 이 마지막에 없앤다).
    fn freeComposedGlyphs(self: *Context) void {
        var it = self.composed_glyphs.valueIterator();
        while (it.next()) |slot| {
            if (slot.*.bitmap.len > 0) self.allocator.free(slot.*.bitmap);
            self.allocator.destroy(slot.*);
        }
        self.composed_glyphs.clearRetainingCapacity();
    }

    /// #418 — 이 글리프가 **자리를 차지하지 않는 결합 문자**에서 왔는가.
    ///
    /// advance 로는 판정할 수 없다 — `DejaVu Sans Mono` 는 관통 overlay (`U+0335` · `U+0336` ·
    /// `U+0338`) 에 advance 를 준다. **GDEF glyph class 로도 안 된다** — 같은 폰트가 그 셋을
    /// `BASE_GLYPH` 로 분류해 두었다 (`U+0305` · `U+0308` 은 `MARK` 인데 overlay 만 base 다).
    ///
    /// 그래서 codepoint 를 본다. shaping 이 글리프를 합쳐 놓아도 (`a`+`U+0301` → `á`)
    /// `ShapedGlyph.cluster` 가 **입력 codepoint 인덱스**라 되짚을 수 있다. 합쳐진 글리프는
    /// cluster 가 base 를 가리키므로 mark 로 오인되지 않는다.
    ///
    /// `cluster_base` 는 런 배칭에서 여러 cluster 를 이어 붙였을 때의 시작 offset 이다
    /// (개별 경로는 0).
    fn glyphIsMark(self: *Context, cps: []const u21, cluster_base: u32, g: ShapedGlyph) bool {
        const api = if (self.hb_api) |*a| a else return false;
        if (g.cluster < cluster_base) return false;
        const idx = g.cluster - cluster_base;
        if (idx >= cps.len) return false;
        return api.isNonSpacingMark(cps[idx]);
    }

    /// #418 — 이 글리프가 **관통 (overlay) 결합 기호**에서 왔는가 (Unicode combining class 1).
    ///
    /// 집합이 작고 고정이라 표로 둔다 — Windows 판과 같은 목록이다. 관통 mark 만 세로를 base
    /// 잉크 중앙에 맞춘다 (위 · 아래 mark 는 자기 디자인 높이가 옳다).
    fn glyphIsOverlayMark(self: *Context, cps: []const u21, cluster_base: u32, g: ShapedGlyph) bool {
        _ = self;
        if (g.cluster < cluster_base) return false;
        const idx = g.cluster - cluster_base;
        if (idx >= cps.len) return false;
        return switch (cps[idx]) {
            0x0334...0x0338, 0x20D2, 0x20D3, 0x20E5, 0x20E6, 0x20EB => true,
            else => false,
        };
    }

    /// #401 — 합성 글리프 조회. `ClusterGlyph.composed` 가 true 일 때 `glyph_index` 가
    /// 여기의 키다. 없으면 placeholder — 합성은 `resolveCluster` 시점에 이미 끝나 있으므로
    /// 정상 경로에서는 항상 있다.
    pub fn composedGlyph(self: *Context, face_idx: u8, key: u32) *const Glyph {
        const map_key = (@as(u64, face_idx) << 32) | @as(u64, key);
        if (self.composed_glyphs.get(map_key)) |g| return g;
        return &self.placeholder;
    }

    /// `cp` 의 글리프. **해석 결과를 codepoint 당 한 번만 구한다** (#362).
    ///
    /// 원래는 셀마다 매 프레임 chain 을 돌며 face 마다 `FT_Get_Char_Index` 를
    /// 부르고, 그다음 face 의 캐시를 해시로 찾고, chain 이 다 미스면
    /// `system_fallback` 을 또 해시로 찾았다. 결과는 codepoint 만의 함수인데
    /// 매번 다시 구한 것이다 — 프로파일에서 해싱이 프레임 CPU 의 14 % 였다.
    ///
    /// ASCII 는 해시조차 안 쓴다 (배열 직접 인덱싱). 터미널 텍스트의 대부분이라
    /// 이 갈래 하나가 곧 성능이다.
    ///
    /// 캐시가 포인터를 들 수 있는 근거는 `Face.glyph_cache` 가 글리프를 개별
    /// 할당해 **주소가 고정**이기 때문이다. 폰트를 다시 로드하면 (`freeFaces`)
    /// 이 캐시도 함께 비운다.
    pub fn glyph(self: *Context, cp: u21, style: font_constants.FaceStyle) *const Glyph {
        const si = style.index();
        if (asciiSlot(cp)) |i| {
            if (self.resolved_ascii[si][i]) |g| return g;
            const g = self.resolveGlyph(cp, style);
            self.resolved_ascii[si][i] = g;
            return g;
        }
        if (self.resolved[si].get(cp)) |g| return g;
        const g = self.resolveGlyph(cp, style);
        self.resolved[si].put(cp, g) catch {};
        return g;
    }

    /// #375 — 변종 chain 을 **처음 필요할 때** 만든다. 실패해도 다시 시도하지 않는다
    /// (매 프레임 fontconfig 왕복을 막는다). 만들지 못한 칸은 `null` 로 남고
    /// [`faceFor`](#faceFor) 가 regular face 로 떨어뜨린다.
    fn ensureStyledChain(self: *Context, style: font_constants.FaceStyle) void {
        if (style == .regular) return;
        const slot = style.index() - 1;
        if (self.styled_loaded[slot]) return;
        self.styled_loaded[slot] = true;

        for (self.faces[0..self.face_count], 0..) |maybe_base, i| {
            const base = maybe_base orelse continue;
            self.styled_faces[slot][i] = self.loadStyledFace(base, style) catch |err| {
                log.appendLineVerbose("font", "styled chain[{d}] skip family={s} style={s} err={s}", .{
                    i, base.family, @tagName(style), @errorName(err),
                });
                continue;
            };
        }
    }

    /// 같은 family 의 변종 face 하나. **fontconfig 가 regular 와 같은 파일을 돌려주면
    /// `null`** 을 준다 — 그 family 에 해당 변종이 없다는 뜻이고, 같은 파일을 두 번
    /// 열어 메모리와 atlas 를 낭비할 이유가 없다.
    fn loadStyledFace(self: *Context, base: Face, style: font_constants.FaceStyle) !?Face {
        const family_z = try self.allocator.allocSentinel(u8, base.family.len, 0);
        defer self.allocator.free(family_z);
        @memcpy(family_z[0..base.family.len], base.family);

        const fc_result = try fontconfig.lookupStyled(self.allocator, family_z.ptr, style);
        defer fc_result.deinitAdditionalFamilies(self.allocator);
        defer self.allocator.free(fc_result.family);
        var path_owned_by_face = false;
        defer if (!path_owned_by_face) self.allocator.free(fc_result.path);

        if (std.mem.eql(u8, fc_result.path, base.path)) return null;

        const path_z = try self.allocator.allocSentinel(u8, fc_result.path.len, 0);
        defer self.allocator.free(path_z);
        @memcpy(path_z[0..fc_result.path.len], fc_result.path);

        var ft_face: freetype.FT_Face = undefined;
        if (self.ft_api.new_face(self.ft_lib, path_z.ptr, 0, &ft_face) != 0) {
            return error.FreetypeNewFaceFailed;
        }
        errdefer _ = self.ft_api.done_face(ft_face);

        if (self.ft_api.set_pixel_sizes(ft_face, 0, self.pixel_height) != 0) {
            if (ft_face.num_fixed_sizes <= 0 or self.ft_api.select_size(ft_face, 0) != 0) {
                return error.FreetypeSetSizeFailed;
            }
        }

        const family_owned = try self.allocator.dupe(u8, base.family);
        errdefer self.allocator.free(family_owned);

        const hb_font: ?*harfbuzz.hb_font_t = if (self.hb_api) |*api|
            api.ft_font_create_referenced(@ptrCast(ft_face))
        else
            null;

        path_owned_by_face = true;
        return .{
            .allocator = self.allocator,
            .ft_face = ft_face,
            .family = family_owned,
            .path = fc_result.path,
            .glyph_cache = std.AutoHashMap(u21, *Glyph).init(self.allocator),
            .glyph_by_index = std.AutoHashMap(u32, *Glyph).init(self.allocator),
            .hb_font = hb_font,
        };
    }

    /// chain 의 `i` 번째 face — 변종이 있으면 그것, 없으면 regular.
    fn faceFor(self: *Context, i: usize, style: font_constants.FaceStyle) ?*Face {
        if (style != .regular) {
            if (self.styled_faces[style.index() - 1][i]) |*f| return f;
        }
        if (self.faces[i]) |*f| return f;
        return null;
    }

    /// chain 순회 → 첫 매치 face 의 cache 에서 lazy raster + insert. chain 모두
    /// 미스면 system fallback (#289 B5), 그마저 미보유 (또는 raster / OOM 실패)
    /// → placeholder. **codepoint 당 한 번만 불린다** (`glyph` 가 결과를 캐시).
    fn resolveGlyph(self: *Context, cp: u21, style: font_constants.FaceStyle) *const Glyph {
        self.ensureStyledChain(style);
        for (0..self.face_count) |i| {
            const face = self.faceFor(i, style) orelse continue;
            const idx = self.ft_api.get_char_index(face.ft_face, cp);
            if (idx == 0) continue;

            return rasterCached(self.allocator, self.ft_api, face, cp) orelse &self.placeholder;
        }
        return self.systemFallbackGlyph(cp) orelse &self.placeholder;
    }

    /// #289 B5 — chain 밖 cp 의 system fallback 경로. cp → face 매핑이
    /// `system_fallback` 에 캐시되어 fontconfig 왕복은 cp 당 최초 1회.
    fn systemFallbackGlyph(self: *Context, cp: u21) ?*const Glyph {
        const idx: u8 = blk: {
            if (self.system_fallback.get(cp)) |entry| {
                break :blk entry orelse return null; // null = 시스템 전체 미보유 확정
            }
            const loaded = self.loadFallbackForCp(cp);
            self.system_fallback.put(cp, loaded) catch {};
            break :blk loaded orelse return null;
        };
        const face = if (self.fallback_faces[idx]) |*f| f else return null;
        return rasterCached(self.allocator, self.ft_api, face, cp);
    }

    /// cp 를 보유한 system fallback face 의 index 를 반환 — 필요 시 fontconfig
    /// charset 매치로 lazy 로드. null = 시스템 전체 미보유 / 로드 실패 (caller
    /// 가 negative cache 기록).
    fn loadFallbackForCp(self: *Context, cp: u21) ?u8 {
        // 기로드 fallback face 가 cp 를 보유하면 재사용 — fontconfig 왕복 회피
        // (같은 스크립트의 cp 들이 한 face 로 묶이는 일반 케이스).
        for (self.fallback_faces[0..self.fallback_count], 0..) |slot, idx| {
            const existing = slot orelse continue;
            if (self.ft_api.get_char_index(existing.ft_face, cp) != 0) return @intCast(idx);
        }

        const fc_result = fontconfig.lookupForChar(self.allocator, cp) catch |err| {
            log.appendLineVerbose("font", "system fallback lookup failed cp=U+{X} err={s}", .{ cp, @errorName(err) });
            return null;
        };
        defer fc_result.deinitAdditionalFamilies(self.allocator);
        var owned_by_face = false;
        defer if (!owned_by_face) {
            self.allocator.free(fc_result.family);
            self.allocator.free(fc_result.path);
        };

        // 매치 path 가 기로드 face 와 같으면 그 face 는 위 pre-scan 에서 이미
        // cp 미보유 판정 — fontconfig charset metadata 와 cmap 의 불일치 케이스.
        for (self.fallback_faces[0..self.fallback_count]) |slot| {
            const existing = slot orelse continue;
            if (std.mem.eql(u8, existing.path, fc_result.path)) return null;
        }

        if (self.fallback_count >= MAX_FALLBACK) {
            log.appendLine("font", "system fallback cap ({d}) reached — cp=U+{X} placeholder", .{ MAX_FALLBACK, cp });
            return null;
        }

        const path_z = self.allocator.allocSentinel(u8, fc_result.path.len, 0) catch return null;
        defer self.allocator.free(path_z);
        @memcpy(path_z[0..fc_result.path.len], fc_result.path);

        var ft_face: freetype.FT_Face = undefined;
        if (self.ft_api.new_face(self.ft_lib, path_z.ptr, 0, &ft_face) != 0) {
            log.appendLineVerbose("font", "system fallback new_face failed cp=U+{X} path={s}", .{ cp, fc_result.path });
            return null;
        }
        // set_pixel_sizes 실패 시 fixed-strike 선택 — `tryLoadFamily` 와 동일.
        if (self.ft_api.set_pixel_sizes(ft_face, 0, self.pixel_height) != 0) {
            if (ft_face.num_fixed_sizes <= 0 or self.ft_api.select_size(ft_face, 0) != 0) {
                _ = self.ft_api.done_face(ft_face);
                return null;
            }
        }
        // fontconfig charset 은 폰트 metadata — 실제 cmap 미보유면 확정 miss.
        if (self.ft_api.get_char_index(ft_face, cp) == 0) {
            _ = self.ft_api.done_face(ft_face);
            log.appendLineVerbose("font", "system fallback miss cp=U+{X} (best match {s} lacks glyph)", .{ cp, fc_result.family });
            return null;
        }

        self.fallback_faces[self.fallback_count] = .{
            .allocator = self.allocator,
            .ft_face = ft_face,
            .family = fc_result.family,
            .path = fc_result.path,
            .glyph_cache = std.AutoHashMap(u21, *Glyph).init(self.allocator),
            .glyph_by_index = std.AutoHashMap(u32, *Glyph).init(self.allocator),
            .hb_font = null,
        };
        owned_by_face = true;
        const idx: u8 = @intCast(self.fallback_count);
        self.fallback_count += 1;
        log.appendLineVerbose("font", "system fallback[{d}] family={s} path={s} (cp=U+{X})", .{ idx, fc_result.family, fc_result.path, cp });
        return idx;
    }

    /// 지정 face 의 glyph_index 로 raster + cache. shape 결과의 ligature glyph
    /// (codepoint 안 갖는 idx) lookup 에 사용. caller 는 `LigatureGlyph` 의
    /// `face_idx` + `glyph_index` 를 그대로 넣음. ZWJ family emoji cluster
    /// (NotoColorEmoji face) 등 face_idx > 0 에서 raster 되어야 BGRA 가
    /// 살아남는 케이스 대응.
    /// #419 — chain face 와 system fallback face 를 **한 index 공간**으로 조회한다.
    /// `FALLBACK_FACE_BASE` 위는 fallback, 아래는 chain 이다.
    fn faceAt(self: *Context, face_idx: u8) ?*Face {
        if (face_idx >= FALLBACK_FACE_BASE) {
            const i: usize = face_idx - FALLBACK_FACE_BASE;
            if (i >= self.fallback_count) return null;
            return if (self.fallback_faces[i]) |*f| f else null;
        }
        if (face_idx >= self.face_count) return null;
        return if (self.faces[face_idx]) |*f| f else null;
    }

    /// #419 — 그 face 의 hb_font 를 보장한다. system fallback face 는 `hb_font = null` 로
    /// 만들어지므로 (단일 codepoint raster 만 쓰던 시절의 결정) 처음 shaping 할 때 여기서
    /// 만든다. chain face 는 로드 시 이미 있어서 그대로 돌려준다.
    fn ensureHbFont(self: *Context, face_idx: u8) ?*harfbuzz.hb_font_t {
        const api = if (self.hb_api) |*a| a else return null;
        const face = self.faceAt(face_idx) orelse return null;
        if (face.hb_font) |f| return f;
        const created = api.ft_font_create_referenced(face.ft_face);
        face.hb_font = created;
        return created;
    }

    pub fn glyphByIndex(self: *Context, face_idx: u8, glyph_index: u32) *const Glyph {
        const face = self.faceAt(face_idx) orelse return &self.placeholder;
        if (face.glyph_by_index.get(glyph_index)) |cached| return cached;
        const g = rasterByIndex(self.allocator, self.ft_api, face.ft_face, glyph_index) catch {
            return &self.placeholder;
        };
        const slot = self.allocator.create(Glyph) catch {
            if (g.bitmap.len > 0) self.allocator.free(g.bitmap);
            return &self.placeholder;
        };
        slot.* = g;
        face.glyph_by_index.put(glyph_index, slot) catch {
            if (g.bitmap.len > 0) self.allocator.free(g.bitmap);
            self.allocator.destroy(slot);
            return &self.placeholder;
        };
        return slot;
    }

    /// Latin (또는 모든 single-face shape-able) codepoint sequence 를 HarfBuzz
    /// 로 shape. 결과 ShapedGlyph 들을 `out` 에 채워서 *개수* 반환. caller 는
    /// glyph_index 로 `glyphByIndex` 호출해 raster 받음.
    ///
    /// `cps.len <= 16` 권장 — short Latin sequence (terminal ligature run) 의
    /// 가벼운 path. HarfBuzz 미지원 환경 또는 primary face 의 hb_font 가 null
    /// 이면 fallback: 각 cp 의 단순 glyph_index 그대로 1:1 매핑 (= ligature 미적용,
    /// 기존 동작 동등). out 길이 부족하면 fit 만큼만 채움.
    ///
    /// terminal 패턴: ligature 면 결과 glyph 수 < cps 수. 첫 cluster 의 ShapedGlyph
    /// 만 그리고 나머지 cluster index 의 cell 은 빈 background — kitty / alacritty
    /// 패턴.
    pub fn shapeRun(self: *Context, cps: []const u21, out: []ShapedGlyph) usize {
        return self.shapeRunOnFace(0, cps, out);
    }

    /// `shapeRun` 의 multi-face 변종 — `face_idx` 지정. ZWJ family / VS-16 emoji
    /// cluster 가 emoji face (NotoColorEmoji 등) 에서만 GSUB 합성되는 케이스
    /// 대응. caller 는 `resolveCluster` 처럼 chain 순회로 매치 face 검색.
    ///
    /// HarfBuzz 미advertise / face hb_font 없음 — face_idx==0 면 fallback
    /// (cp → idx 1:1), 그 외 face 는 0 반환 (그 face 시도는 skip).
    pub fn shapeRunOnFace(self: *Context, face_idx: u8, cps: []const u21, out: []ShapedGlyph) usize {
        if (cps.len == 0 or out.len == 0 or self.face_count == 0) return 0;

        const hb_api = if (self.hb_api) |*api| api else {
            if (face_idx == 0) return self.shapeRunFallback(cps, out);
            return 0;
        };
        const hb_buf = self.hb_buffer orelse {
            if (face_idx == 0) return self.shapeRunFallback(cps, out);
            return 0;
        };
        // #419 — system fallback face 는 hb_font 없이 만들어진다 (단일 codepoint raster 만
        // 쓸 생각이었다). cluster 를 태우려면 필요하므로 여기서 만들어 둔다.
        const hb_font = self.ensureHbFont(face_idx) orelse {
            if (face_idx == 0) return self.shapeRunFallback(cps, out);
            return 0;
        };

        // codepoint array 를 u32 로 reinterpret (u21 → u32 동일 비트 layout 아님
        // → 명시 변환 buffer 사용).
        //
        // #399 — 크기가 `MAX_RUN_CLUSTERS * 16` 이다. 런 배칭 (`resolveClusterRun`) 이
        // cluster 들을 이어붙여 이 함수로 넘기므로, 예전 64 로는 한 줄이 조용히 잘렸다.
        // 2 KB 짜리 지역 배열이라 프레임마다 불려도 부담이 아니다.
        var u32_buf: [MAX_RUN_CLUSTERS * MAX_CLUSTER_CPS]u32 = undefined;
        const n = @min(cps.len, u32_buf.len);
        for (cps[0..n], 0..) |cp, i| u32_buf[i] = @intCast(cp);

        hb_api.buffer_clear_contents(hb_buf);
        // #418 — **cluster 를 병합하지 않게 한다.** 기본값 `MONOTONE_GRAPHEMES` 는 base 와
        // 뒤따르는 mark 를 한 cluster 로 묶어서 (실측 — `k`+`U+0336` 이 둘 다 `cluster=0`)
        // 글리프가 어느 codepoint 에서 왔는지 되짚을 수 없다. 그 되짚기가 mark 판정의 근거다.
        // 심볼이 없으면 그냥 건너뛴다 (병합된 채로 와서 advance 기준으로 degrade).
        if (hb_api.buffer_set_cluster_level) |set_level| {
            set_level(hb_buf, harfbuzz.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS);
        }
        hb_api.buffer_add_codepoints(hb_buf, &u32_buf, @intCast(n), 0, @intCast(n));
        // `guess_segment_properties` 가 direction / script / language 를 자동
        // 결정 — Latin 이면 LTR + Latn. 또는 명시 set 해도 OK.
        hb_api.buffer_guess_segment_properties(hb_buf);

        hb_api.shape(hb_font, hb_buf, null, 0);

        var glyph_count: c_uint = 0;
        const infos = hb_api.buffer_get_glyph_infos(hb_buf, &glyph_count);
        const positions = hb_api.buffer_get_glyph_positions(hb_buf, &glyph_count);

        const result_count = @min(@as(usize, glyph_count), out.len);
        for (0..result_count) |i| {
            out[i] = .{
                .glyph_index = infos[i].codepoint,
                .cluster = infos[i].cluster,
                .x_advance = @divFloor(positions[i].x_advance, 64),
                .x_offset = @divFloor(positions[i].x_offset, 64),
                .y_offset = @divFloor(positions[i].y_offset, 64),
            };
        }
        return result_count;
    }

    /// grapheme cluster (VS-16 / skin tone / ZWJ 시퀀스 / combining mark) 의
    /// shape 결과를 하나의 representative glyph 로 reduce. cps 는 base + extras
    /// 의 codepoint array (`cell.raw.codepoint()` + `cell.grapheme` 의 합).
    /// mac `CoreTextFontContext.resolveGrapheme` / Win `DWriteFontContext.
    /// resolveGrapheme` 와 같은 의미.
    ///
    /// HarfBuzz GSUB 가 합성 가능한 cluster (대부분 — VS-16 emoji, skin tone,
    /// ZWJ family) 는 shape 결과 1 glyph 이라 그 glyph_index 를 그대로 raster.
    /// chain 의 *모든 face* 를 순회 — primary monospace 가 VS-16 emoji 의 GSUB
    /// 합성 안 하는 케이스도 NotoColorEmoji face 에서 shape 시 1 glyph 가 되어
    /// face_idx>0 으로 매치. mac `CTLineCreateWithAttributedString` 의 자동
    /// fallback / Win `IDWriteTextAnalyzer.GetGlyphs` 의 face fallback 동등.
    ///
    /// 매치 정책 — 첫 face 가 *clean single-glyph* (= n==1 + glyph_index != 0)
    /// 결과 내면 그 face 결과 return. 그 외 (다중 glyph 또는 0-glyph) 는 다음
    /// face 시도. 모든 face 미매치면 null — caller 가 base codepoint chain
    /// lookup (`glyph(cp)`) 으로 fallback (cluster extras 무시되지만 base 표시).
    ///
    /// #395 — 실제 구현은 `resolveClusterInner` 이고 여기서는 `perf.shape` 만 얹는다.
    /// cluster 셀마다 · 프레임마다 불리는 경로라, render 안에서 shaping 이 차지하는
    /// 몫을 이 카운터로 가른다. `return null` 경로가 여럿이라 본체를 건드리지 않도록
    /// wrapper 로 분리했다. mac · Win 의 `resolveGrapheme` 도 같은 모양이다.
    pub fn resolveCluster(self: *Context, cps: []const u21) ?ClusterGlyph {
        const t0 = perf.now();
        const result = self.resolveClusterInner(cps);
        perf.addTimed(&perf.shape, t0);
        // miss — chain 의 어느 face 도 못 맞춘 경우. caller 가 base codepoint 로
        // fallback 한다. Windows 는 이때 system fallback 까지 돌아 가장 비싸다.
        if (result == null) perf.incExtra(&perf.shape);
        return result;
    }

    /// #399 — 연속된 grapheme cluster 를 **한 번의 shape 호출**로 묶는다.
    /// mac `resolveGraphemeRun` · Win `resolveGraphemeRun` 과 같은 자리다.
    ///
    /// `render` 시간의 91.5 % 가 cluster shaping 이고 (#395) 그 대부분이 cluster 마다
    /// chain 을 처음부터 순회하며 HarfBuzz 를 새로 부르는 **고정 비용**이다. 한 줄을
    /// 묶으면 그만큼 준다.
    ///
    /// 성공하면 `clusters.len` 을, 하나라도 못 채우면 0 을 돌려준다 — caller 는 0 이면
    /// 기존 개별 경로 (`resolveCluster`) 로 떨어진다. **렌더가 틀리느니 느린 게 낫다.**
    pub fn resolveClusterRun(
        self: *Context,
        clusters: []const []const u21,
        out: []ClusterGlyph,
    ) usize {
        const t0 = perf.now();
        const n = self.resolveClusterRunInner(clusters, out);
        perf.addTimed(&perf.shape, t0);
        // **런 실패를 miss 로 세지 않는다.** 실패하면 caller 가 개별 경로로 떨어지고
        // 거기서 cluster 마다 `resolveCluster` 가 chain miss 를 센다 — 여기서 또 세면
        // 한 실패가 두 번 잡혀서, `miss` 가 배칭 전후로 **다른 의미**가 된다 (실측에서
        // 180 → 1,133 으로 보여 실패가 6 배 는 것처럼 읽혔다). 이 카운터는 세 platform
        // 에서 계속 "chain 이 못 맞춘 cluster 수" 하나만 뜻해야 비교가 성립한다.
        return n;
    }

    fn resolveClusterRunInner(
        self: *Context,
        clusters: []const []const u21,
        out: []ClusterGlyph,
    ) usize {
        if (clusters.len == 0 or clusters.len > MAX_RUN_CLUSTERS) return 0;
        if (out.len < clusters.len) return 0;
        if (self.face_count == 0 or self.hb_api == null) return 0;

        // cluster 들을 이어붙이면서 **각자의 시작 offset** 을 적어 둔다.
        //
        // `shapeRunOnFace` 는 `hb_buffer_add_codepoints` 로 넣는데, 그때 HarfBuzz 가
        // 매기는 cluster 번호가 **버퍼 안 codepoint 인덱스**다. 그래서 이 offset 표가
        // 그대로 "글리프 → 우리 cluster" 매핑이 된다 — `hb_buffer_add` 를 새로 바인딩할
        // 필요가 없다.
        // #399 (B) — shape 하기 전에 런의 cluster 를 **전부** 캐시에서 찾는다. 다 있으면
        // shape 없이 끝난다. `zwj` 처럼 한 줄이 같은 cluster 면 첫 런 이후 shape 가 0 이 된다.
        //
        // 하나라도 없으면 (또는 캐시된 결과가 실패면) 아래 기존 경로로 간다 — 부분만 쓰고
        // 나머지를 shape 하는 식으로 섞지 않는다. 런은 한 face 로 전체를 맞추는 것이 전제라
        // 섞으면 그 전제가 깨진다.
        var all_hit = true;
        for (clusters, 0..) |c, i| {
            if (self.cluster_cache.get(c)) |cached| {
                if (cached) |g| {
                    out[i] = g;
                    continue;
                }
            }
            all_hit = false;
            break;
        }
        if (all_hit) return clusters.len;

        var cps_buf: [MAX_RUN_CLUSTERS * MAX_CLUSTER_CPS]u21 = undefined;
        var starts: [MAX_RUN_CLUSTERS]u32 = undefined;
        var total: usize = 0;
        for (clusters, 0..) |c, i| {
            if (c.len == 0 or c.len > MAX_CLUSTER_CPS) return 0;
            if (total + c.len > cps_buf.len) return 0;
            starts[i] = @intCast(total);
            @memcpy(cps_buf[total..][0..c.len], c);
            total += c.len;
        }

        // #399 — 직전에 맞은 face 를 먼저 본다 (`last_cluster_face` 주석). 런은 codepoint
        // 가 많아 (`zwj` 13 개면 65 개) 헛도는 face 하나가 그만큼 비싸다.
        var shape_buf: [MAX_RUN_CLUSTERS * MAX_CLUSTER_CPS]ShapedGlyph = undefined;
        const hint = self.last_cluster_face;
        var order: [MAX_CHAIN + 1]u8 = undefined;
        var order_n: usize = 0;
        if (hint < self.face_count) {
            order[0] = hint;
            order_n = 1;
        }
        for (0..self.face_count) |fi| {
            const idx_u8: u8 = @intCast(fi);
            if (order_n > 0 and idx_u8 == hint) continue; // 이미 앞에 넣었다
            order[order_n] = idx_u8;
            order_n += 1;
        }

        for (order[0..order_n]) |idx_u8| {
            const n = self.shapeRunOnFace(idx_u8, cps_buf[0..total], &shape_buf);
            // cluster 수보다 글리프가 적으면 HarfBuzz 가 인접 cluster 둘을 하나로 합친
            // 것이다 — 우리 경계와 다르므로 이 face 는 쓸 수 없다.
            if (n < clusters.len) continue;

            // #401 — 글리프를 **cluster 별로 묶는다.** 예전에는 `n == clusters.len` 을
            // 요구해 cluster 당 글리프가 정확히 하나여야 했는데, 결합 기호처럼 base +
            // mark 로 나오는 cluster 가 섞이면 런 전체가 실패했다. `shape_buf[].cluster`
            // 가 버퍼 안 codepoint 인덱스라 `starts` 표와 그대로 맞는다.
            var ok = true;
            var gi: usize = 0;
            var group_at: [MAX_RUN_CLUSTERS]usize = undefined;
            var group_n: [MAX_RUN_CLUSTERS]usize = undefined;
            for (0..clusters.len) |i| {
                // 경계가 어긋났거나 순서가 뒤집힌 경우를 여기서 함께 잡는다.
                if (gi >= n or shape_buf[gi].cluster != starts[i]) {
                    ok = false;
                    break;
                }
                // **다음 cluster 가 시작되기 전까지**를 이 cluster 의 글리프로 본다.
                // `== starts[i]` 로 비교하면 cluster 병합을 끈 뒤 (#418) mark 글리프가
                // `starts[i]+1` 을 갖게 되어 그룹이 끊긴다. 이 비교는 병합 여부와 무관하게 옳다.
                const next_start: u32 = if (i + 1 < clusters.len) starts[i + 1] else @intCast(total);
                var end = gi + 1;
                while (end < n and shape_buf[end].cluster < next_start) end += 1;
                group_at[i] = gi;
                group_n[i] = end - gi;
                gi = end;
            }
            if (!ok or gi != n) continue;

            // 개별 경로 (`tryClusterOnFace`) 와 같은 기준 — `.notdef` 만 거부한다.
            for (shape_buf[0..n]) |g| {
                if (g.glyph_index == 0) {
                    ok = false;
                    break;
                }
            }
            if (!ok) continue;

            // 결과를 먼저 다 만들고 나서 옮긴다. 합성이 하나라도 실패하면 이 face 를 통째로
            // 넘겨야 한다 — 런은 **한 face 로 전체를 맞추는 것**이 전제라 일부만 쓰면 그
            // 전제가 깨진다 (위 캐시 조회에서 부분 적중을 안 쓰는 것과 같은 이유다).
            var built: [MAX_RUN_CLUSTERS]ClusterGlyph = undefined;
            for (0..clusters.len) |i| {
                const gs = shape_buf[group_at[i]..][0..group_n[i]];
                if (gs.len == 1) {
                    built[i] = .{
                        .face_idx = idx_u8,
                        .glyph_index = gs[0].glyph_index,
                        .x_offset = gs[0].x_offset,
                        .y_offset = gs[0].y_offset,
                    };
                } else {
                    const key = self.composeCluster(idx_u8, clusters[i], starts[i], gs) orelse {
                        ok = false;
                        break;
                    };
                    built[i] = .{ .face_idx = idx_u8, .glyph_index = key, .composed = true };
                }
            }
            if (!ok) continue;

            for (0..clusters.len) |i| {
                out[i] = built[i];
                // 다음 런이 shape 를 건너뛸 수 있게 담는다.
                self.cluster_cache.put(clusters[i], out[i]);
            }
            self.last_cluster_face = idx_u8;
            return clusters.len;
        }
        return 0;
    }

    /// 한 face 로 cluster 하나를 시도한다.
    ///
    /// #401 — **판정 기준은 `.notdef` 뿐이다. 글리프 개수는 보지 않는다.**
    /// [`font/windows/font.zig`](../windows/font.zig) 의 `shapeOnFaceMulti` 와 같은 기준이다.
    /// 예전에는 `n != 1` 이면 face 를 거부했는데, 그러면 폰트에 precomposed 글리프가 없는
    /// 결합 기호 (`a` + `U+0305` → base + mark 2 글리프) 에서 chain 전체가 미매치가 되고
    /// caller 가 base 로 fallback 해 **악센트가 사라졌다**. 글리프 수가 여럿인 것은 실패가
    /// 아니라 *겹쳐 그리라는 폰트의 지시*다.
    ///
    /// 글리프가 하나면 그대로, 여럿이면 한 비트맵으로 합성해 그 키를 돌려준다.
    fn tryClusterOnFace(self: *Context, face_idx: u8, cps: []const u21) ?ClusterGlyph {
        var shape_buf: [MAX_CLUSTER_GLYPHS]ShapedGlyph = undefined;
        const n = self.shapeRunOnFace(face_idx, cps, &shape_buf);
        if (n == 0) return null;
        // 하나라도 `.notdef` 면 이 face 는 cluster 의 codepoint 를 다 갖지 못한 것이다 —
        // 다음 face 로 넘긴다.
        for (shape_buf[0..n]) |g| {
            if (g.glyph_index == 0) return null;
        }
        if (n == 1) {
            return .{
                .face_idx = face_idx,
                .glyph_index = shape_buf[0].glyph_index,
                .x_offset = shape_buf[0].x_offset,
                .y_offset = shape_buf[0].y_offset,
            };
        }
        const key = self.composeCluster(face_idx, cps, 0, shape_buf[0..n]) orelse return null;
        return .{ .face_idx = face_idx, .glyph_index = key, .composed = true };
    }

    /// #401 — 글리프 여러 개를 한 비트맵으로 굽고 캐시 키를 돌려준다.
    ///
    /// 배치는 HarfBuzz 가 준 값을 그대로 쓴다 — `x_advance` 로 pen 을 밀고 `x_offset` ·
    /// `y_offset` 을 더한다. **결합 기호는 mark 의 `x_advance` 가 0** 이라 pen 이 안 움직여
    /// base 위에 겹친다. 우리가 겹치라고 정하는 것이 아니라 폰트가 그렇게 지시하는 것이다
    /// (Windows 가 `advances` · `offsets` 를, macOS 가 `positions` 를 넘기는 것과 같다 — #139).
    fn composeCluster(self: *Context, face_idx: u8, cps: []const u21, cluster_base: u32, glyphs: []const ShapedGlyph) ?u32 {
        if (glyphs.len < 2 or glyphs.len > MAX_CLUSTER_GLYPHS) return null;

        // 키 — 같은 face 에서 (글리프 인덱스 + 배치) 가 같으면 그림이 같다.
        var h = std.hash.Wyhash.init(0x40_1C_10_5E);
        for (glyphs) |g| {
            h.update(std.mem.asBytes(&g.glyph_index));
            h.update(std.mem.asBytes(&g.x_offset));
            h.update(std.mem.asBytes(&g.y_offset));
            h.update(std.mem.asBytes(&g.x_advance));
        }
        // 0 은 `.notdef` 와 헷갈리지 않게 피한다 (키 공간이 달라 충돌은 없지만, 로그 ·
        // 디버깅에서 0 이 "없음" 으로 읽히는 것을 막는다).
        const key: u32 = blk: {
            const v: u32 = @truncate(h.final());
            break :blk if (v == 0) 1 else v;
        };
        const map_key = (@as(u64, face_idx) << 32) | @as(u64, key);
        if (self.composed_glyphs.contains(map_key)) return key;

        const composed = self.rasterizeCluster(face_idx, cps, cluster_base, glyphs) orelse return null;
        const slot = self.allocator.create(Glyph) catch {
            if (composed.bitmap.len > 0) self.allocator.free(composed.bitmap);
            return null;
        };
        slot.* = composed;
        self.composed_glyphs.put(map_key, slot) catch {
            if (composed.bitmap.len > 0) self.allocator.free(composed.bitmap);
            self.allocator.destroy(slot);
            return null;
        };
        return key;
    }

    /// #401 — 합성 비트맵을 만든다. 각 글리프를 `glyphByIndex` 로 굽고 (그쪽 캐시를 그대로
    /// 쓴다), 배치 사각형의 **합집합**을 새 비트맵으로 잡아 겹쳐 그린다.
    ///
    /// **픽셀 모드가 섞이면 포기한다** (null → caller 가 다음 face 로). 회색 마스크는 전경색으로
    /// 칠해질 것을 전제로 한 커버리지고 컬러 비트맵은 자기 색을 갖는데, 둘을 한 비트맵에 담으면
    /// 어느 쪽 규약으로도 읽을 수 없다. 한 face 는 보통 한 모드라 (DejaVu 는 전부 회색, Noto
    /// Color Emoji 는 전부 BGRA) 실제로 섞이는 경우는 거의 없다.
    fn rasterizeCluster(self: *Context, face_idx: u8, cps: []const u21, cluster_base: u32, glyphs: []const ShapedGlyph) ?Glyph {
        var rasters: [MAX_CLUSTER_GLYPHS]*const Glyph = undefined;
        var xs: [MAX_CLUSTER_GLYPHS]i32 = undefined;
        var ys: [MAX_CLUSTER_GLYPHS]i32 = undefined;
        // #418 — 세로 보정 단계에서 다시 봐야 해서 배치 루프의 판정을 남겨 둔다.
        var marks: [MAX_CLUSTER_GLYPHS]bool = .{false} ** MAX_CLUSTER_GLYPHS;
        var overlay_only = true; // 결합 기호가 **전부** 관통 류인가
        var has_mark = false;

        var pen_x: i32 = 0;
        // #415 — 직전 base 글리프 **잉크의 가로 중앙**. HarfBuzz 가 배치를 안 한 mark 를 여기에
        // 맞춘다. `null` 이면 앞에 advance ≠ 0 인 base 가 없다는 뜻이라 보정하지 않는다.
        var base_center: ?i32 = null;
        var pixel_mode: u8 = 0;
        var have_ink = false;
        var min_x: i32 = std.math.maxInt(i32);
        var min_y: i32 = std.math.maxInt(i32);
        var max_x: i32 = std.math.minInt(i32);
        var max_y: i32 = std.math.minInt(i32);

        for (glyphs, 0..) |g, i| {
            const r = self.glyphByIndex(face_idx, g.glyph_index);
            rasters[i] = r;

            // #415 — **HarfBuzz 가 mark 를 배치하지 못한 경우를 여기서 되돌린다.**
            //
            // combining mark (`x_advance == 0`) 인데 `x_offset` 까지 0 이면, mark 가 pen —
            // 즉 base 의 advance 뒤 — 에 그대로 남는다는 뜻이다. 배치가 됐다면 base 위로
            // 당기는 음수 offset 이 왔어야 한다. 그대로 그리면 mark 가 옆 셀로 나간다.
            //
            // HarfBuzz 는 `kerx` · `GPOS` · `kern` 이 **모두 없을 때만** 자체 fallback mark
            // positioning 을 한다. DejaVu Sans Mono 처럼 GPOS 는 있는데 그 조합의 anchor 만
            // 없는 폰트는 그 사이에 빠져서 (`a` + `U+0301` 이 `á` 로 합성된 뒤의 `U+0308`)
            // 아무도 배치를 안 해 준다. 그 계층을 우리가 채운다 — 증상을 가리는 보정이 아니라
            // GPOS 가 불완전한 폰트에 같은 fallback 을 적용하는 것이다.
            //
            // **맞출 자리는 잉크 중앙이지 원점이 아니다.** 처음에는 "직전 base 의 시작 pen 으로
            // 되돌린다" 로 구현했고 근거를 *"mark 글리프는 자기 bearing 에 base 위 중앙이 이미
            // 들어 있다"* 로 적었는데, 그것은 **DejaVu 에서만 맞는 말이었다.** mark 글리프를 어디에
            // 그리도록 설계했는지가 폰트마다 다르다 (Windows 실측 — #415):
            //
            //   DejaVu Sans Mono  `U+0308`  bitmap_left=+3  width=6   → 원점이 잉크 왼쪽
            //   Segoe UI Symbol   `U+0305`  bitmap_left=-6  width=12  → 원점이 곧 잉크 중앙
            //
            // 뒤쪽 폰트에서 원점을 맞추면 잉크 중앙이 0 이 되어 base 중앙에서 왼쪽으로 밀리고,
            // 실기에서 앞 글자를 침범했다. 폰트에 무관하게 옳은 것은 **mark 의 잉크 중앙을 base 의
            // 잉크 중앙에 맞추는 것**이고, 이것이 HarfBuzz 가 GPOS 없는 폰트에 적용하는 fallback
            // mark positioning 과 같은 규칙이다 (`hb-ot-shape-fallback` 의 `position_mark`).
            // DejaVu 에서는 두 규칙의 결과가 같다 (`a` 잉크 중앙 6 · diaeresis 잉크 중앙 6).
            //
            // **advance 가 0 인 글리프 위에는 맞추지 않는다** (`base_center == null`). emoji ZWJ 의
            // stack 디자인은 글리프 여럿이 같은 원점에 겹치고 마지막 것만 advance 를 갖는데, 거기서
            // 잉크 중앙을 맞추면 폰트가 의도한 겹침이 어긋난다.
            //
            // 세로는 건드리지 않는다 — mark 의 세로 위치는 자기 디자인에 이미 들어 있다.
            //
            // #418 — **mark 판정은 advance 가 아니라 GDEF glyph class 로 한다.** advance 0 을
            // mark 의 정의로 쓰면 관통 overlay (`U+0335` · `U+0336` · `U+0338`) 를 놓친다 —
            // `DejaVu Sans Mono` 는 그것들에 advance 를 준다 (실측 `idx=702 adv=12`). 그대로
            // 두면 pen 이 밀린 자리에 그려져 **mark 가 옆 칸을 덮는다.** 폰트가 mark 로 분류한
            // 글리프는 advance 를 갖고 있어도 pen 을 밀지 않는 것이 맞다.
            //
            // GDEF 조회가 안 되는 환경 (심볼 없는 축소 libharfbuzz) 에서는 `false` 가 와서
            // 예전과 같은 advance 기준으로 degrade 한다.
            const is_mark = self.glyphIsMark(cps, cluster_base, g) or g.x_advance == 0;
            marks[i] = is_mark and i > 0;
            if (marks[i]) {
                has_mark = true;
                if (!self.glyphIsOverlayMark(cps, cluster_base, g)) overlay_only = false;
            }
            const unplaced_mark = i > 0 and is_mark and g.x_offset == 0;
            // 글리프 잉크의 **자기 원점 기준** 가로 중앙.
            const ink_center = r.bitmap_left + @divFloor(@as(i32, @intCast(r.width)), 2);
            const origin = if (unplaced_mark and base_center != null)
                base_center.? - ink_center
            else
                pen_x;

            // FreeType 은 baseline 기준 · 위쪽이 양수, 화면은 아래쪽이 양수라 부호가 뒤집힌다.
            xs[i] = origin + g.x_offset + r.bitmap_left;
            ys[i] = -g.y_offset - r.bitmap_top;
            // #418 — mark 는 pen 을 밀지 않는다. advance 를 가진 overlay mark 도 마찬가지다 —
            // 그 advance 대로 전진하면 뒤따르는 글리프까지 한 칸씩 밀린다.
            if (!is_mark) {
                base_center = pen_x + g.x_offset + ink_center;
                pen_x += g.x_advance;
            }

            if (r.width == 0 or r.height == 0) continue; // space 등 잉크 없는 글리프
            if (pixel_mode == 0) {
                pixel_mode = r.pixel_mode;
            } else if (pixel_mode != r.pixel_mode) {
                return null; // 모드 혼합 — 위 주석
            }
            have_ink = true;
        }
        if (!have_ink) return null;

        // #418 — **관통 (overlay) mark 만 세로도 base 잉크 중앙에 맞춘다.**
        //
        // mark 의 세로 위치는 GPOS 가 정하는데, 배치가 없으면 폰트의 기본 높이에 남는다. 그
        // 높이는 대개 소문자 기준이라 대문자 (`O` + `U+0337`) 나 획이 긴 글자에서 어긋난다.
        // 관통 mark 는 **글자를 가로질러야** 의미가 살아서 base 잉크 중앙이 옳다.
        //
        // 위 · 아래 mark 는 건드리지 않는다 — acute 를 글자 가운데로 내리면 틀린다. 이 구분은
        // Unicode combining class 이고 HarfBuzz 의 fallback mark positioning 도 같은 기준을 쓴다
        // (`hb-ot-shape-fallback` 의 `position_mark`). Windows 판과 같은 규칙이다 (#418).
        //
        // 보수적으로 둘을 지킨다 — 결합 기호가 **전부** 관통 류일 때만 손대고, `y_offset` 이
        // 이미 있으면 shaping 이 정한 것이므로 덮어쓰지 않는다.
        if (has_mark and overlay_only) {
            var base_top: i32 = std.math.maxInt(i32);
            var base_bottom: i32 = std.math.minInt(i32);
            for (glyphs, 0..) |_, i| {
                if (marks[i]) continue;
                const r = rasters[i];
                if (r.width == 0 or r.height == 0) continue;
                if (ys[i] < base_top) base_top = ys[i];
                const b = ys[i] + @as(i32, @intCast(r.height));
                if (b > base_bottom) base_bottom = b;
            }
            if (base_bottom > base_top) {
                const base_cy = base_top + @divFloor(base_bottom - base_top, 2);
                for (glyphs, 0..) |g, i| {
                    if (!marks[i] or g.y_offset != 0) continue;
                    const r = rasters[i];
                    if (r.width == 0 or r.height == 0) continue;
                    const mark_cy = ys[i] + @divFloor(@as(i32, @intCast(r.height)), 2);
                    ys[i] += base_cy - mark_cy;
                }
            }
        }

        // #421 — **위 mark 를 폰트 ascender 에 맞춘다.** 같은 `U+0305` 가 글자마다 다른 높이에
        // 놓이던 것을 없앤다.
        //
        // 폰트 · shaping 은 base 높이에 맞춰 mark 를 올린다 (실측 — `a` 위에서는 `y_offset` 이
        // 0 인데 `b` 위에서는 +4 다). 겹치지 않으려는 동작이라 각각은 틀리지 않지만, 결과적으로
        // `a̅b̅c̅d̅e̅f̅` 의 윗줄이 계단처럼 들쭉날쭉해진다. Windows 는 균일하고, 사용자가 균일한
        // 쪽을 택했다.
        //
        // **cluster 안의 위 mark 전체를 같은 양만큼 평행이동**한다 — 그래야 연속 조합
        // (`a`+301+308+323) 의 적층이 유지된다. 기준은 가장 아래에 있는 위 mark 이고, 그것의
        // 잉크 top 이 ascender 가 되도록 옮긴다.
        //
        // ascender 위라 `b d f` 의 잉크와 겹치지 않는다 — "평평하게 하면 겹친다" 는 *base 잉크*
        // 기준으로 평평하게 할 때의 이야기고, ascender 기준이면 성립하지 않는다.
        //
        // 관통 mark (바로 위) 와는 배타적이다 — 그쪽은 `overlay_only` 일 때만 도는데 여기는
        // 위 mark 가 하나라도 있어야 돈다.
        if (has_mark and !overlay_only and self.ascent_px > 0) {
            // 잉크가 baseline 위에 **완전히** 있는 mark 만 위 mark 로 본다. 아래 mark (cedilla
            // 등) 와 관통 mark 는 여기서 걸러진다.
            //
            // 기준은 **가장 위에 있는 mark** 다. 가장 아래 것을 ascender 에 맞추면 그 위에 쌓인
            // mark 가 셀 밖으로 나간다 (실측 — Lao `ກິ່` 가 top +19 → +22 로 위 칸을 침범했다).
            // 가장 위 것을 맞추면 cluster 전체가 셀 안에 들어오고, mark 가 하나뿐인 흔한 경우는
            // 어차피 그 하나가 기준이라 평평해지는 결과가 같다.
            var highest_top: ?i32 = null;
            for (glyphs, 0..) |_, i| {
                if (!marks[i]) continue;
                const r = rasters[i];
                if (r.width == 0 or r.height == 0) continue;
                const top = -ys[i]; // baseline 기준 위가 양수
                const bottom = top - @as(i32, @intCast(r.height));
                if (bottom < 0) continue; // baseline 아래로 내려오면 위 mark 가 아니다
                if (highest_top == null or top > highest_top.?) highest_top = top;
            }
            if (highest_top) |lt| {
                const delta = @as(i32, @intCast(self.ascent_px)) - lt;
                if (delta != 0) {
                    for (glyphs, 0..) |_, i| {
                        if (!marks[i]) continue;
                        const r = rasters[i];
                        if (r.width == 0 or r.height == 0) continue;
                        const top = -ys[i];
                        if (top - @as(i32, @intCast(r.height)) < 0) continue; // 위 mark 만
                        ys[i] -= delta; // 화면 y 는 아래가 양수라 부호가 뒤집힌다
                    }
                }
            }
        }

        // 배치가 확정된 뒤에 사각형 합집합을 잡는다 (위 세로 보정이 `ys` 를 바꾼다).
        for (glyphs, 0..) |_, i| {
            const r = rasters[i];
            if (r.width == 0 or r.height == 0) continue;
            if (xs[i] < min_x) min_x = xs[i];
            if (ys[i] < min_y) min_y = ys[i];
            const right = xs[i] + @as(i32, @intCast(r.width));
            const bottom = ys[i] + @as(i32, @intCast(r.height));
            if (right > max_x) max_x = right;
            if (bottom > max_y) max_y = bottom;
        }

        const out_w: usize = @intCast(max_x - min_x);
        const out_h: usize = @intCast(max_y - min_y);
        if (out_w == 0 or out_h == 0) return null;
        // 셀 몇 개 분량을 넘는 것은 우리 격자에 못 담는다 — 그런 결과는 안 그리는 편이 낫다.
        if (out_w > MAX_COMPOSED_PX or out_h > MAX_COMPOSED_PX) return null;

        const bpp: usize = if (pixel_mode == freetype.FT_PIXEL_MODE_BGRA) 4 else 1;
        const buf = self.allocator.alloc(u8, out_w * out_h * bpp) catch return null;
        @memset(buf, 0);

        for (glyphs, 0..) |_, i| {
            const r = rasters[i];
            if (r.width == 0 or r.height == 0) continue;
            const dx: usize = @intCast(xs[i] - min_x);
            const dy: usize = @intCast(ys[i] - min_y);
            const src_w: usize = @intCast(r.width);
            const src_h: usize = @intCast(r.height);
            var row: usize = 0;
            while (row < src_h) : (row += 1) {
                const dst_row = dy + row;
                if (dst_row >= out_h) break;
                var col: usize = 0;
                while (col < src_w) : (col += 1) {
                    const dst_col = dx + col;
                    if (dst_col >= out_w) break;
                    const s = (row * src_w + col) * bpp;
                    const d = (dst_row * out_w + dst_col) * bpp;
                    if (bpp == 1) {
                        // 커버리지끼리는 더 진한 쪽을 남긴다 — base 와 mark 는 원래 겹치지
                        // 않게 설계돼 있어 대부분 한쪽이 0 이다.
                        if (r.bitmap[s] > buf[d]) buf[d] = r.bitmap[s];
                    } else {
                        // premultiplied BGRA over.
                        const sa: u32 = r.bitmap[s + 3];
                        if (sa == 0) continue;
                        const inv: u32 = 255 - sa;
                        for (0..4) |c| {
                            const sv: u32 = r.bitmap[s + c];
                            const dv: u32 = buf[d + c];
                            buf[d + c] = @intCast(@min(255, sv + (dv * inv) / 255));
                        }
                    }
                }
            }
        }

        // advance 는 **첫 글리프 것**을 쓴다. cluster 는 셀 격자에 맞춰 그리므로 (renderer 가
        // 셀 폭으로 중앙정렬) 합계를 쓰면 오히려 어긋난다 — macOS `rasterizeCluster` 와 같다.
        return .{
            .bitmap = buf,
            .width = @intCast(out_w),
            .height = @intCast(out_h),
            .bitmap_left = min_x,
            .bitmap_top = -min_y,
            // advance 는 **base 글리프** 것이다. cluster 가 차지하는 가로는 base 가 정하고
            // mark 는 0 이라서다. 첫 글리프를 쓰면 RTL 에서 어긋난다 — Hebrew `אָ` 는 mark
            // (qamats) 가 먼저 와서 합성 advance 가 0 이 됐다 (#419 에서 실측).
            // advance 는 **cluster 전체가 차지하는 가로**다 — shaping 이 준 `x_advance` 의 합.
            //
            // 한 글리프 것을 집으면 어긋난다. 처음엔 첫 글리프를 썼는데 RTL 에서 mark 가 먼저
            // 와서 (Hebrew `אָ` = qamats → alef) 0 이 나왔고, 첫 *base* 글리프로 바꿨더니 이번엔
            // Devanagari `क्षि` 가 5 를 냈다 — `ि` (short i) 가 **base 앞에 놓이는 모음**이라
            // 첫 base 글리프가 그 조각이다. 렌더러는 이 값으로 셀 안 중앙정렬을 하므로 (#299)
            // 작으면 글자가 오른쪽으로 밀린다 (실기에서 그렇게 보였다).
            //
            // mark 는 `x_advance` 가 0 이라 합에 기여하지 않으므로 따로 거를 필요가 없다.
            .advance = blk: {
                var sum: i32 = 0;
                for (glyphs) |g2| {
                    // mark 는 빼야 한다. 보통 `x_advance` 가 0 이라 저절로 빠지지만 관통
                    // overlay 는 advance 를 갖고 (`DejaVu` 의 `U+0336` = 12) 그대로 더하면
                    // `k̶` 의 advance 가 24 로 두 칸이 된다 — pen 을 안 미는 것과 같은 이유로
                    // 폭에도 넣지 않는다 (#418).
                    if (self.glyphIsMark(cps, cluster_base, g2)) continue;
                    sum += g2.x_advance;
                }
                if (sum > 0) break :blk @intCast(sum);
                break :blk rasters[0].advance; // 전부 zero-advance 인 경우 (드묾)
            },
            .pixel_mode = pixel_mode,
        };
    }

    fn resolveClusterInner(self: *Context, cps: []const u21) ?ClusterGlyph {
        if (cps.len == 0 or self.face_count == 0 or self.hb_api == null) return null;

        // #399 (B) — 캐시가 shape 자체를 건너뛴다. negative 도 담기므로 (`??` 의 안쪽
        // null) chain 이 못 맞춘 cluster 가 매 프레임 chain 을 헛돌지 않는다.
        if (self.cluster_cache.get(cps)) |cached| return cached;

        // #399 — 직전에 맞은 face 를 먼저 본다 (`last_cluster_face` 주석).
        const hint = self.last_cluster_face;
        if (hint < self.face_count) {
            if (self.tryClusterOnFace(hint, cps)) |g| {
                self.cluster_cache.put(cps, g);
                return g;
            }
        }

        for (0..self.face_count) |face_idx| {
            const idx_u8: u8 = @intCast(face_idx);
            if (idx_u8 == hint) continue; // 바로 위에서 이미 봤다
            if (self.tryClusterOnFace(idx_u8, cps)) |g| {
                self.last_cluster_face = idx_u8;
                self.cluster_cache.put(cps, g);
                return g;
            }
        }
        // #419 — chain 이 다 놓쳤으면 **system fallback face** 로 한 번 더 본다.
        //
        // 단일 codepoint 는 예전부터 여기로 왔다 (`glyph` → `systemFallbackGlyph`, #289 B5).
        // cluster 만 chain 에서 끝나서, Devanagari `क्षि` 처럼 chain 밖 스크립트는 **base 만
        // 그려지고 결합이 빠졌다** — 같은 폰트를 한쪽 경로는 쓰고 다른 쪽은 안 쓰는 비대칭이었다.
        // SPEC 은 fallback 을 하는 쪽이다 (*"chain 에 없는 codepoint 는 system fallback 이 자동
        // 처리"*).
        //
        // face 는 **cluster 의 base codepoint** 로 고른다. mark 는 대개 base 와 같은 스크립트라
        // 그 face 가 함께 갖고 있고, 아니면 아래 `tryClusterOnFace` 의 `.notdef` 검사가 걸러 준다.
        if (self.loadFallbackForCp(cps[0])) |fb_idx| {
            const face_idx = FALLBACK_FACE_BASE + fb_idx;
            if (self.tryClusterOnFace(face_idx, cps)) |g| {
                // `last_cluster_face` 에는 담지 않는다 — 그 값은 chain 순회의 시작점이라
                // fallback index 를 넣으면 다음 cluster 가 엉뚱한 곳을 먼저 본다.
                self.cluster_cache.put(cps, g);
                return g;
            }
        }

        // 전부 실패한 것도 담는다 — 안 담으면 매 프레임 다시 헛돈다.
        self.cluster_cache.put(cps, null);
        return null;
    }

    /// 2-char ligature lookup with cache. paint loop 가 매 cell pair 에 호출.
    /// `cp0` + `cp1` shape 결과 glyph 1 개면 ligature → 그 정보 반환. 2 개면
    /// no ligature → null. cache 가 결과 보관 — 같은 pair 반복 호출 시 shape
    /// 호출 회피.
    ///
    /// caller 패턴 (software_terminal.paint):
    /// ```
    /// if (font_ctx.ligaturePair(cp0, cp1)) |lg| {
    ///     // ligature glyph 첫 cell 위치에 그리고 둘째 cell 은 skip
    /// } else {
    ///     // single-char path (기존)
    /// }
    /// ```
    pub fn ligaturePair(self: *Context, cp0: u21, cp1: u21) ?LigatureMatch {
        if (self.face_count == 0 or self.hb_api == null) return null;
        if (self.ligature_cache.getPair(cp0, cp1)) |cached| return cached;

        // cache miss — shape 실행. 결과 1 glyph 면 single-glyph ligature (JetBrains
        // Mono 등), N glyph 인데 indices 가 natural 과 다르면 spacer ligature
        // (Fira Code 등 — `=>` 가 자연 glyph 2개가 아닌 spacer pair 2개로 substitute).
        // 둘 다 아니면 ligature 아님.
        var pair_cps: [2]u21 = .{ cp0, cp1 };
        var shape_buf: [4]ShapedGlyph = undefined;
        const n = self.shapeRun(&pair_cps, &shape_buf);

        const result = detectLigatureMatch(self, &pair_cps, &shape_buf, n);
        self.ligature_cache.putPair(cp0, cp1, result);
        return result;
    }

    /// 3-char ligature lookup with cache. `ligaturePair` 와 동일 패턴, 3 cp.
    /// Fira Code / JetBrains Mono / Cascadia Code 의 흔한 3-char ligature
    /// (`===` / `!==` / `<=>` / `<--` / `-->` / `<->` 등) 대응. paint loop 는
    /// 3-char 먼저 시도 → 결과 1 glyph 면 ligature 확정 + 3 cell skip; 아니면
    /// 2-char (`ligaturePair`) 시도; 둘 다 미매치면 single-char.
    ///
    /// key 는 3 × 21 bits = 63 bits packed in u64 — 충돌 없는 unique 식별.
    pub fn ligatureTriple(self: *Context, cp0: u21, cp1: u21, cp2: u21) ?LigatureMatch {
        if (self.face_count == 0 or self.hb_api == null) return null;
        if (self.ligature_cache.getTriple(cp0, cp1, cp2)) |cached| return cached;

        var triple_cps: [3]u21 = .{ cp0, cp1, cp2 };
        var shape_buf: [4]ShapedGlyph = undefined;
        const n = self.shapeRun(&triple_cps, &shape_buf);

        const result = detectLigatureMatch(self, &triple_cps, &shape_buf, n);
        self.ligature_cache.putTriple(cp0, cp1, cp2, result);
        return result;
    }

    /// shape 결과 (`shape_buf[0..n]`) 와 입력 `cps` 를 비교해 single-glyph
    /// 또는 spacer-pattern ligature 판정.
    ///
    /// - `n < cps.len`: 입력보다 결과 glyph 수가 적음 = classic single-glyph
    ///   ligature (JetBrains Mono / Cascadia Code 의 일부). 첫 glyph 으로 N
    ///   cell width 차지.
    /// - `n == cps.len`: 결과 glyph 수가 입력과 같음. *naturalindices 와 다르면*
    ///   spacer-pattern ligature (Fira Code 의 디폴트 — `=>` 가 2 glyph 으로
    ///   substitute 되되 그 indices 가 자연 `=`, `>` 와 다름). 자연 그대로면
    ///   ligature 아님 (단순 `=>` 가 ligature 없는 폰트).
    /// - 그 외 (n == 0 or n > cps.len): 비정상 결과 — null.
    /// HarfBuzz shape 결과를 `ligature.ShapedSlot[]` 으로 normalize 후 공유
    /// `ligature.classify` 호출. natural indices 는 primary face 의 FreeType
    /// `get_char_index` 로 계산. mac / Windows 도 같은 `classify` 사용.
    ///
    /// `n > cps.len` 인 비정상 shape 결과는 classify 가 null 반환 — slots 채울
    /// 때 cps OOB 만 안 일어나면 됨 (cp_idx clamp).
    fn detectLigatureMatch(self: *Context, cps: []const u21, shape_buf: []const ShapedGlyph, n: usize) ?LigatureMatch {
        if (self.face_count == 0 or cps.len == 0) return null;
        const face = if (self.faces[0]) |*f| f else return null;

        var slots: [4]ligature.ShapedSlot = undefined;
        const checked = @min(n, slots.len);
        for (0..checked) |i| {
            const cp_idx = @min(i, cps.len - 1);
            slots[i] = .{
                .glyph_index = shape_buf[i].glyph_index,
                .natural_glyph_index = self.ft_api.get_char_index(face.ft_face, @intCast(cps[cp_idx])),
                .x_offset = shape_buf[i].x_offset,
                .y_offset = shape_buf[i].y_offset,
            };
        }
        return ligature.classify(cps.len, slots[0..checked]);
    }

    /// HarfBuzz 미지원 / 미적용 환경의 fallback. 각 codepoint 의 단순 glyph_index
    /// (FreeType `get_char_index`) 그대로 1:1 매핑 — ligature 없음, 기존 동작
    /// 동등.
    fn shapeRunFallback(self: *Context, cps: []const u21, out: []ShapedGlyph) usize {
        if (self.face_count == 0) return 0;
        const face = if (self.faces[0]) |*f| f else return 0;
        const n = @min(cps.len, out.len);
        for (cps[0..n], 0..) |cp, i| {
            const idx = self.ft_api.get_char_index(face.ft_face, cp);
            out[i] = .{
                .glyph_index = idx,
                .cluster = @intCast(i),
                .x_advance = @intCast(self.cell_width_px),
                .x_offset = 0,
                .y_offset = 0,
            };
        }
        return n;
    }
};

/// fontconfig 가 fallback substitution 으로 시스템 default 매치하는 게 의도된
/// generic family. 그 외는 결과 family/alias 항목이 요청과 다르면 substitution으로
/// 판단해서 chain 에 안 추가.
fn isGenericFamily(family: []const u8) bool {
    const generic = [_][]const u8{ "monospace", "sans-serif", "serif" };
    for (generic) |g| {
        if (std.ascii.eqlIgnoreCase(family, g)) return true;
    }
    return false;
}

/// fontconfig 매치가 요청 family 를 실제로 해석했는지 판정 — `tryLoadFamily`
/// 의 skip 판정과 boot 검증 (`familyInstalled`) 이 공유하는 단일 규칙.
/// generic family 는 substitution 이 의도이므로 항상 수용, specific family 는
/// 반환 family/alias 중 한 항목과 대소문자 무시 exact match해야 한다.
/// #406 — 이름 정규화. **macOS 판 (`font/macos/font.zig` 의 `normalizeFamily`) 과 같은 규칙**
/// 이어야 두 platform 이 같은 이름을 받아 준다: 공백 · `-` · `_` 를 빼고 소문자로.
///
/// `DejaVuSansMono` · `dejavu sans mono` · `DejaVu-Sans-Mono` 가 모두 같아진다. 사용자가 폰트
/// 이름을 어떤 표기로 적든 통과시키기 위한 것이다.
fn normalizeFamily(name: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (name) |c| {
        if (c == ' ' or c == '-' or c == '_') continue;
        if (n >= buf.len) break;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    return buf[0..n];
}

fn normalizedEql(a: []const u8, b: []const u8) bool {
    var buf_a: [128]u8 = undefined;
    var buf_b: [128]u8 = undefined;
    return std.mem.eql(u8, normalizeFamily(a, &buf_a), normalizeFamily(b, &buf_b));
}

fn matchResolvesFamily(requested: []const u8, primary_family: []const u8, additional_families: anytype) bool {
    if (isGenericFamily(requested)) return true;
    // #406 — 정규화해서 본다. `DejaVuSansMono` 처럼 붙여 쓴 이름을 fontconfig 가 알아서
    // `DejaVu Sans Mono` 로 맞춰 주는데, 예전에는 `eqlIgnoreCase` 라 그것을 **대체로 오분류**
    // 해서 "(system alias)" 라는 사실과 다른 로그를 남겼다. macOS 판과 같은 규칙이다.
    if (normalizedEql(requested, primary_family)) return true;
    for (additional_families) |family| {
        if (normalizedEql(requested, family)) return true;
    }
    return false;
}

test "explicit family resolution requires an exact family or alias" {
    const no_aliases = [_][]const u8{};
    try std.testing.expect(!matchResolvesFamily("Mono", "Noto Sans Mono", &no_aliases));
    try std.testing.expect(!matchResolvesFamily("Sans", "Noto Sans", &no_aliases));
    try std.testing.expect(matchResolvesFamily("nOtO sAnS mOnO", "Noto Sans Mono", &no_aliases));

    const condensed_aliases = [_][]const u8{"DejaVu Sans Condensed"};
    try std.testing.expect(matchResolvesFamily("DejaVu Sans Condensed", "DejaVu Sans", &condensed_aliases));
}

test "generic family resolution keeps fontconfig substitution" {
    const no_aliases = [_][]const u8{};
    try std.testing.expect(matchResolvesFamily("monospace", "Noto Sans Mono", &no_aliases));
    try std.testing.expect(matchResolvesFamily("SANS-SERIF", "Noto Sans", &no_aliases));
    try std.testing.expect(matchResolvesFamily("serif", "Noto Serif", &no_aliases));
}

/// config font chain boot 검증용 가용성 판정 (#289 B6) — Windows
/// `isFontAvailable` / macOS `CTFontCopyFamilyName` 검증과 동등.
pub const FamilyAvailability = enum {
    installed,
    /// #406 — 폰트는 **실재하는데** fontconfig 가 다른 family 로 해석한 경우. 시작을 막지
    /// 않고 그 폰트로 띄운다 — 사용자 의도는 대개 "이 글자를 표시하고 싶다" 이지 "반드시 이
    /// 이름이어야 한다" 가 아니다. 이름이 아예 없는 경우 (`missing`) 와는 갈라야 한다:
    /// 그건 오타일 수 있어 조용히 넘어가면 다른 폰트로 그려진 것을 사용자가 모른다.
    substituted,
    missing,
    /// libfontconfig 자체를 못 열거나 lookup 인프라 실패 — 미설치로 오판해
    /// "Font not found" 를 내지 않고 loader 의 기존 에러 경로에 맡긴다.
    unknown,
};

/// `family` 가 시스템에 설치되어 있는지 — fontconfig lookup + substitution
/// 판정 (`matchResolvesFamily`). caller (Linux host boot 검증) 는 `.missing`
/// 일 때만 fatal.
///
/// `substitute_buf` 를 주면 **substitution 때문에 `.missing` 인 경우** 그 자리에 fontconfig 가
/// 실제로 돌려준 family 를 채우고 그 slice 를 돌려준다 (#405). 그러지 않으면 사용자는
/// *"설치했는데 왜 not found 인가"* 를 알 길이 없다 — 파일도 있고 `fc-list` 에도 나오는데
/// `/etc/fonts/conf.d/` 의 규칙이 다른 폰트로 바꿔치기한 상황이기 때문이다. 실제로
/// `ttf-twemoji` 가 `Noto Color Emoji` 요청을 가로채 부팅이 막혔다.
///
/// 폰트가 아예 없어서 `.missing` 인 경우에는 채우지 않는다 (`null` 반환) — 그때는 이름이
/// 틀렸거나 미설치라는 기존 안내가 맞다.
pub fn familyInstalledDetail(
    allocator: std.mem.Allocator,
    family: []const u8,
    substitute_buf: ?[]u8,
) struct { availability: FamilyAvailability, substitute: ?[]const u8 } {
    const family_z = allocator.allocSentinel(u8, family.len, 0) catch
        return .{ .availability = .unknown, .substitute = null };
    defer allocator.free(family_z);
    @memcpy(family_z[0..family.len], family);

    const fc_result = fontconfig.lookup(allocator, family_z.ptr) catch |err| switch (err) {
        // 시스템에 매치가 아예 없는 경우만 미설치 확정.
        error.FontconfigNoMatch => return .{ .availability = .missing, .substitute = null },
        else => return .{ .availability = .unknown, .substitute = null },
    };
    defer fc_result.deinit(allocator);

    if (matchResolvesFamily(family, fc_result.family, fc_result.additional_families)) {
        return .{ .availability = .installed, .substitute = null };
    }

    // #406 — 여기부터가 "요청과 다른 폰트가 왔다" 인데, 두 경우가 섞여 있어서 갈라야 한다.
    //
    //   Noto Color Emoji -> Twemoji      : 설치돼 있는데 별칭 규칙이 가로챔 -> 띄운다
    //   NoSuchFont12345  -> Noto Sans    : 아예 없음 -> fatal
    //
    // `FcFontMatch` 는 없는 이름에도 항상 무언가를 돌려주므로 (실측: 오타에도 `Noto Sans` 가
    // 나왔다) 반환값만으로는 못 가른다. **설치 목록에 있는지**로 가른다.
    //
    // 목록을 못 얻으면 (`error.*`) 예전처럼 대체로 본다 — 판정 불가를 미설치로 오판해 사용자를
    // 막지 않는다 (`.unknown` 주석과 같은 방향).
    const listed = fontconfig.familyListed(family, normalizedEql) catch true;
    if (!listed) return .{ .availability = .missing, .substitute = null };

    // substitution 이다 — 무엇으로 바뀌었는지 남긴다. #406 이후 이것은 **시작을 막지 않는다**.
    var sub: ?[]const u8 = null;
    if (substitute_buf) |buf| {
        const n = @min(buf.len, fc_result.family.len);
        if (n > 0) {
            @memcpy(buf[0..n], fc_result.family[0..n]);
            sub = buf[0..n];
        }
    }
    return .{ .availability = .substituted, .substitute = sub };
}

/// 이름만 보는 기존 형태 — 대체 폰트가 필요 없는 호출처용.
pub fn familyInstalled(allocator: std.mem.Allocator, family: []const u8) FamilyAvailability {
    return familyInstalledDetail(allocator, family, null).availability;
}

/// face 의 per-cp cache 에서 lookup, 미스면 raster + insert. raster / OOM
/// 실패 → null (caller 가 placeholder 로 degrade). chain 과 system fallback
/// 경로가 공유.
fn rasterCached(allocator: std.mem.Allocator, api: freetype.Api, face: *Face, cp: u21) ?*const Glyph {
    if (face.glyph_cache.get(cp)) |cached| return cached;
    const g = rasterOne(allocator, api, face.ft_face, cp) catch return null;
    const slot = allocator.create(Glyph) catch {
        if (g.bitmap.len > 0) allocator.free(g.bitmap);
        return null;
    };
    slot.* = g;
    face.glyph_cache.put(cp, slot) catch {
        if (g.bitmap.len > 0) allocator.free(g.bitmap);
        allocator.destroy(slot);
        return null;
    };
    return slot;
}

fn rasterOne(
    allocator: std.mem.Allocator,
    api: freetype.Api,
    face: freetype.FT_Face,
    cp: u21,
) !Glyph {
    const idx = api.get_char_index(face, cp);
    return rasterByIndexInner(allocator, api, face, idx);
}

/// shape 결과의 glyph_index (codepoint 안 갖는 ligature idx 등) 로 직접 raster.
/// `rasterOne` 이 cp → idx 변환 후 같은 path 호출.
fn rasterByIndex(
    allocator: std.mem.Allocator,
    api: freetype.Api,
    face: freetype.FT_Face,
    glyph_index: u32,
) !Glyph {
    return rasterByIndexInner(allocator, api, face, glyph_index);
}

fn rasterByIndexInner(
    allocator: std.mem.Allocator,
    api: freetype.Api,
    face: freetype.FT_Face,
    idx: u32,
) !Glyph {
    // FT_LOAD_COLOR — emoji (BGRA) 도 raster. mono 폰트엔 무시.
    const load_flags = freetype.FT_LOAD_RENDER | freetype.FT_LOAD_COLOR;
    if (api.load_glyph(face, idx, load_flags) != 0) return error.FreetypeLoadGlyphFailed;
    const slot = face.glyph orelse return error.FreetypeNoGlyphSlot;
    const bm = slot.bitmap;

    var bitmap_slice: []u8 = &.{};
    var stored_pixel_mode: u8 = bm.pixel_mode;
    if (bm.buffer != null and bm.width > 0 and bm.rows > 0) {
        const w: usize = @intCast(bm.width);
        const h: usize = @intCast(bm.rows);
        const bytes_per_pixel: usize = switch (bm.pixel_mode) {
            freetype.FT_PIXEL_MODE_GRAY => 1,
            freetype.FT_PIXEL_MODE_BGRA => 4,
            else => 0,
        };
        if (bytes_per_pixel > 0) {
            bitmap_slice = try allocator.alloc(u8, w * h * bytes_per_pixel);
            const pitch_abs: usize = if (bm.pitch >= 0) @intCast(bm.pitch) else @intCast(-bm.pitch);
            const row_bytes = w * bytes_per_pixel;
            var row: usize = 0;
            while (row < h) : (row += 1) {
                const src = bm.buffer.?[row * pitch_abs .. row * pitch_abs + row_bytes];
                @memcpy(bitmap_slice[row * row_bytes .. row * row_bytes + row_bytes], src);
            }
        } else {
            stored_pixel_mode = freetype.FT_PIXEL_MODE_GRAY; // 빈 bitmap fallback
        }
    } else {
        stored_pixel_mode = freetype.FT_PIXEL_MODE_GRAY;
    }

    const advance_raw = @divFloor(slot.advance.x, 64);
    const advance_clamped: u32 = if (advance_raw > 0) @intCast(advance_raw) else 0;

    return .{
        .bitmap = bitmap_slice,
        .width = bm.width,
        .height = bm.rows,
        .bitmap_left = slot.bitmap_left,
        .bitmap_top = slot.bitmap_top,
        .advance = advance_clamped,
        .pixel_mode = stored_pixel_mode,
    };
}
