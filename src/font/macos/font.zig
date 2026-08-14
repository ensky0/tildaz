// CoreText 폰트 컨텍스트 — codepoint → (font, glyph_index) 해석. 시스템 폰트
// fallback (CTFontCreateForString) 으로 emoji / 한글 / 기타 문자 처리.
//
// Windows 의 `src/dwrite_font.zig` (DWriteFontContext) 와 같은 역할. #75
// (claude/infallible-swartz) 패턴 그대로 차용.

const std = @import("std");
const ct = @import("coretext.zig");
const font_constants = @import("../constants.zig");
const ligature = @import("../ligature.zig");
const cluster_cache = @import("../cluster_cache.zig");
const font_spec = @import("../spec.zig");
const log = @import("../../log.zig");
const perf = @import("../../perf.zig");
const Runtime = @import("../../runtime.zig").Runtime;

/// 한 cluster 가 낼 수 있는 글리프 수 상한. Windows `MAX_CLUSTER_GLYPHS` 와 같은 값이다.
pub const MAX_CLUSTER_GLYPHS: usize = 16;

pub const GlyphResult = struct {
    /// 첫 글리프의 폰트 (= `fonts[0]`). 단일 글리프 경로가 이것만 쓴다.
    font: ct.CTFontRef,
    /// 첫 글리프. `count == 1` 인 흔한 경우의 빠른 길이고, multi-glyph 여도 여기는 채워진다.
    index: ct.CGGlyph,
    /// true 면 caller 가 CFRelease 책임. fallback font 생성 후 cache 안 할 때.
    ///
    /// ⚠️ **`fonts[0..count]` 를 전부 놓아야 한다** (`releaseCluster`). #420 이후 cluster 안에서
    /// 글리프마다 폰트가 다를 수 있다.
    owned: bool,

    /// #401 — **cluster 가 글리프 하나로 합성되지 않는 경우**를 위한 것이다.
    ///
    /// Apple Color Emoji 는 `👨‍❤️‍👨` 같은 `❤️` 조합을 **글리프 2 개**로 준다 (`👨‍👩‍👧` 는
    /// 1 개다). 예전에는 첫 글리프만 쓰고 나머지를 버려서 `👨` 만 그려졌다. Windows 는 같은
    /// 상황을 `advances` · `offsets` 로 겹쳐 그려 해결하고 있었고 (#139), 여기도 같은 구조다.
    ///
    /// `positions` 는 `CTRun` 이 준 값 그대로다 — GPOS 가 적용된 위치라 이대로 그려야 모양이
    /// 맞는다. 첫 글리프 기준 상대 좌표다.
    glyphs: [MAX_CLUSTER_GLYPHS]ct.CGGlyph = undefined,
    positions: [MAX_CLUSTER_GLYPHS]ct.CGPoint = undefined,

    /// #420 — **글리프마다 폰트가 다를 수 있다.**
    ///
    /// `가` + acute (`U+AC00 U+0301`) 를 넘기면 CoreText 가 base 를 `Apple SD Gothic Neo`,
    /// mark 를 `Monaco` 로 배정해 **run 을 2 개로 나눈다** (실측 — 37 개 cluster 중 이 계열
    /// 둘만 그렇다). 예전에는 첫 run 만 써서 **결합 기호가 통째로 사라졌다.**
    ///
    /// Windows 는 face 를 직접 찾아 붙여야 했지만 (`resolveGraphemeSplit`, #420) 여기서는
    /// CoreText 가 폰트 배정과 위치를 **이미 다 계산해 준다** — 우리는 모아서 그리기만 한다.
    fonts: [MAX_CLUSTER_GLYPHS]ct.CTFontRef = undefined,

    /// 유효한 글리프 수. 1 이면 `index` 만 쓰면 된다.
    count: u8 = 1,

    /// #401 — cluster 가 차지하는 가로 폭 (pt). 셀 안 가운데 정렬이 이 값을 쓴다.
    ///
    /// **첫 글리프의 advance 로는 안 된다.** 앞에 오는 모음처럼 cluster 안 글리프가 **가로로
    /// 늘어서는** 경우 (Devanagari `क्षि`) 첫 글리프가 4.09 pt 인데 cluster 는 15.33 pt 를
    /// 차지한다. 그 차이만큼 글자가 오른쪽으로 밀려 옆 칸을 침범했다 (실측 14 px).
    /// 겹쳐 그리는 cluster (emoji ZWJ · 결합 기호) 는 둘이 같아서 영향이 없다.
    ///
    /// 0 이면 모르는 것이고, atlas 가 단일 글리프 advance 로 물러선다.
    advance: f32 = 0,
};

/// #399 (B) — cluster 캐시가 값을 버릴 때 (퇴출 · 무효화 · 덮어쓰기) 부르는 해제다.
///
/// **`owned` 인 것만 놓는다.** chain 폰트는 context 가 자기 수명 동안 들고 있고 (atlas cache
/// key 가 폰트 포인터라 안정성이 필수다), CTLine 이 fallback 으로 고른 폰트만 우리가 retain
/// 한다 — 그 구분이 곧 `owned` 다.
pub fn releaseCluster(v: GlyphResult) void {
    if (!v.owned) return;
    // #420 — cluster 안에서 폰트가 갈릴 수 있으므로 **전부** 놓는다. 같은 폰트가 여러 번
    // 들어 있어도 그만큼 retain 했으므로 짝이 맞는다.
    for (v.fonts[0..v.count]) |f| ct.CFRelease(f);
}

pub const MAX_FALLBACK_FONTS = font_constants.MAX_CHAIN;

// Cross-platform ligature 타입 re-export — caller (renderer/macos.zig) 가
// `font.LigatureMatch` 식으로 그대로 쓸 수 있게.
pub const LigatureGlyph = ligature.LigatureGlyph;
pub const LigatureSpacer = ligature.LigatureSpacer;
pub const LigatureMatch = ligature.LigatureMatch;

/// #406 — 사용자가 적은 `family` 에 맞는 **설치된 이름의 정식 표기**를 찾아 `out` 에 담아
/// 돌려준다. Linux 의 `FontconfigNoMatch` 판정에 해당한다.
///
/// `CTFontCreateWithName` 은 없는 이름에도 실패하지 않고 시스템 기본 폰트를 돌려주기 때문에,
/// 그 반환값만으로는 "오타 · 미설치" 와 "설치돼 있는데 표기가 다름" 을 가를 수 없다. 그래서
/// 설치 목록을 직접 본다. family 이름과 PostScript 이름 두 곳을 보며, 비교는 정규화
/// (`normalizeFamily`) 후에 한다.
///
/// **bool 이 아니라 이름을 돌려주는 이유** — `CTFontCreateWithName` 은 정규화를 모른다.
/// `menloregular` 를 그대로 주면 Helvetica 가 오므로 (실측: cell_w 19 → 25), 매칭된 정식 이름
/// (`Menlo-Regular`) 으로 **폰트를 다시 만들어야** 의도한 폰트가 나온다. 통과만 시키고 원래
/// 문자열을 쓰면 엉뚱한 폰트로 조용히 그려진다.
///
/// `null` 이면 그런 이름이 없다 — 오타 · 미설치이고 호출부가 fatal 로 간다.
///
/// ⚠️ **판정하지 못하면 원래 이름을 그대로 돌려준다** (fail-open). 목록 조회가 실패했을 때
/// `null` 을 주면 정상 폰트까지 전부 미설치로 몰려 **앱이 아예 안 뜬다.** Linux 의
/// `FamilyAvailability` 가 `.unknown` 을 두고 *"미설치로 오판해 Font not found 를 내지 않는다"*
/// 고 한 것과 같은 이유다 — 판정 불가는 거절 사유가 아니다. 폰트가 정말 못 쓰는 것이면 그 뒤
/// 로드 경로가 자기 에러로 알린다.
fn resolveInstalledName(family: []const u8, out: []u8) ?[]const u8 {
    var want_buf: [256]u8 = undefined;
    const want = normalizeFamily(family, &want_buf);
    if (want.len == 0) return family;

    const names = ct.CTFontManagerCopyAvailableFontFamilyNames() orelse return family;
    defer ct.CFRelease(names);
    const count = ct.CFArrayGetCount(names);
    if (count <= 0) return family;

    var buf: [256]u8 = undefined;
    var norm_buf: [256]u8 = undefined;
    var i: ct.CFIndex = 0;
    while (i < count) : (i += 1) {
        const name_ptr = ct.CFArrayGetValueAtIndex(names, i) orelse continue;
        const name: ct.CFStringRef = @constCast(name_ptr);
        const n = ct.CFStringGetLength(name);
        if (n <= 0) continue;
        var used: ct.CFIndex = 0;
        _ = ct.CFStringGetBytes(name, ct.CFRange{ .location = 0, .length = n }, ct.kCFStringEncodingUTF8, 0, false, &buf, @intCast(buf.len), &used);
        if (used <= 0) continue;
        const got = buf[0..@intCast(used)];
        if (std.mem.eql(u8, want, normalizeFamily(got, &norm_buf))) {
            if (got.len > out.len) return family;
            @memcpy(out[0..got.len], got);
            return out[0..got.len];
        }
    }
    return postScriptNameFor(want, out);
}

/// PostScript 이름 (`Menlo-Regular`) 쪽에서 찾는다. `resolveInstalledName` 의 두 번째 경로다.
///
/// **family 목록에는 이 이름이 아예 없다** — 실측으로 family 256 개 옆에 PostScript 이름이
/// 699 개 더 있었다. 그래서 사용자가 `Menlo-Regular` 를 적으면 폰트가 실재하는데도 미설치로
/// 오판했다.
///
/// `want` 는 **이미 정규화된** 문자열이라 `menloregular` 처럼 하이픈 없이 적어도 맞는다.
///
/// ⚠️ **정규화가 family 이름과 겹치는 것은 문제가 아니다.** 실측에서 73 쌍이 겹쳤는데 전부
/// *같은 폰트의 두 이름* 이었다 (`"Al Bayan"` ↔ `"AlBayan"` · `"Arial Black"` ↔ `"Arial-Black"`).
/// 서로 다른 폰트가 뭉치는 경우는 없어서 어느 쪽에 맞아도 결과가 같다.
fn postScriptNameFor(want: []const u8, out: []u8) ?[]const u8 {
    const collection = ct.CTFontCollectionCreateFromAvailableFonts(null) orelse return null;
    defer ct.CFRelease(collection);
    const descs = ct.CTFontCollectionCreateMatchingFontDescriptors(collection) orelse return null;
    defer ct.CFRelease(descs);

    const count = ct.CFArrayGetCount(descs);
    var buf: [256]u8 = undefined;
    var norm_buf: [256]u8 = undefined;
    var i: ct.CFIndex = 0;
    while (i < count) : (i += 1) {
        const d_ptr = ct.CFArrayGetValueAtIndex(descs, i) orelse continue;
        const desc: ct.CTFontDescriptorRef = @constCast(d_ptr);
        const ps = ct.CTFontDescriptorCopyAttribute(desc, ct.kCTFontNameAttribute) orelse continue;
        defer ct.CFRelease(ps);
        const n = ct.CFStringGetLength(ps);
        if (n <= 0) continue;
        var used: ct.CFIndex = 0;
        _ = ct.CFStringGetBytes(ps, ct.CFRange{ .location = 0, .length = n }, ct.kCFStringEncodingUTF8, 0, false, &buf, @intCast(buf.len), &used);
        if (used <= 0) continue;
        const got = buf[0..@intCast(used)];
        if (std.mem.eql(u8, want, normalizeFamily(got, &norm_buf))) {
            if (got.len > out.len) return null;
            @memcpy(out[0..got.len], got);
            return out[0..got.len];
        }
    }
    return null;
}

/// 폰트 이름 비교용 정규화 — 소문자로 낮추고 공백 · 하이픈 · 밑줄을 뺀다.
///
/// 사용자가 `"apple color emoji"` · `"AppleColorEmoji"` 처럼 적는 것을 받아 주기 위한 것이다.
/// **설치된 family 256 개를 전부 정규화해도 충돌이 0 건**이라 (macOS 실측, #406) 다른 폰트로
/// 오인될 위험이 없다. 버퍼가 차면 거기서 끊는다 — 그만큼 긴 이름은 어차피 위 비교에서 갈린다.
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

pub const CoreTextFontContext = struct {
    primary_font: ct.CTFontRef,
    font_em_size: f32,
    /// Retina scale factor — physical pixels per logical point. CoreText shape
    /// API (CTRun positions 등) 의 결과가 *font_em_size unit (= logical points)*
    /// 인데, 우리 cell metric 은 physical pixels — 변환 시 이 값 곱함.
    retina_scale: f32,
    ascent_px: f32,
    descent_px: f32,
    /// 폰트의 위쪽 internal leading (= ascent − cap_height). 대문자 위쪽
    /// 여백. cell box top 부터 ascent 만큼 내려간 위치가 baseline 인데
    /// 대문자 visible top 은 그보다 `top_pad_px` 만큼 더 아래 — 시각적
    /// padding 보정에 사용 (좌/우/하 padding 과 위 padding 을 같게 보이게).
    top_pad_px: f32,
    /// Monospace cell 크기 — 폰트의 'M' advance + ascent/descent/leading 으로
    /// 측정. host 가 hardcoded 상수 대신 이 값을 사용하면 폰트 교체 시에도
    /// 글자 사이 공백 / 줄 높이 가 자동 맞춰진다.
    cell_width_px: u32,
    cell_height_px: u32,
    /// 실제 lookup 성공한 primary 폰트 family name (debug / 로그 용).
    font_family: []const u8,
    /// config.font.family 의 *모든* chain 폰트 — codepoint 별 글리프 fallback
    /// 에 사용 (Windows DWriteFontContext 와 동등). [0] 은 primary 와 동일.
    fallback_fonts: [MAX_FALLBACK_FONTS]ct.CTFontRef,
    fallback_count: usize,
    /// #375 — bold · italic · bold_italic chain. regular 는 위 `fallback_fonts` 가
    /// 담당하므로 3 벌만 둔다 (`FaceStyle.index() - 1` 로 색인).
    ///
    /// **해당 트레이트 face 가 없는 family 는 regular face 를 retain 해서 넣는다** —
    /// 조회가 언제나 성공하므로 호출부에 "없으면 regular" 분기를 두지 않아도 된다
    /// (synthetic 은 만들지 않는다는 결정의 자연스러운 귀결).
    styled_fonts: [font_constants.FaceStyle.count - 1][MAX_FALLBACK_FONTS]ct.CTFontRef,
    ligature_cache: ligature.Cache,
    /// #399 (B) — grapheme cluster shaping 결과 cache. 세 platform 공용 모듈이고 값만
    /// platform 별이다.
    ///
    /// **macOS 값에는 소유권이 있다** (Linux 의 face index 와 다르고 Windows 와 같다).
    /// `resolveGrapheme` 은 CT 가 fallback 으로 고른 폰트를 `CFRetain` 해서 돌려주고
    /// (`owned = true`) 셀 루프가 매 프레임 `CFRelease` 한다. 캐시에 담은 폰트를 그대로
    /// `owned = true` 로 주면 그 release 가 캐시 안의 폰트를 죽인다. 그래서 캐시가 소유권을
    /// 가져가고 caller 에게는 `owned = false` 로 준다.
    ///
    /// negative 도 담는다 — CT 가 못 만든 cluster 를 안 담으면 매 프레임 `CTLine` 을 헛 만든다.
    cluster_cache: cluster_cache.ClusterCache(GlyphResult, releaseCluster),

    /// #375 — 요청한 변종의 chain. `regular` 는 기존 배열을 그대로 돌려주므로
    /// 이 기능이 들어와도 평시 경로의 동작이 바뀌지 않는다.
    fn chainFor(self: *const CoreTextFontContext, style: font_constants.FaceStyle) []const ct.CTFontRef {
        if (style == .regular) return self.fallback_fonts[0..self.fallback_count];
        return self.styled_fonts[style.index() - 1][0..self.fallback_count];
    }

    pub fn init(
        /// #451 — 폰트 미설치 fatal 다이얼로그가 이 안에서 뜬다 (Linux · Windows 는 host
        /// 에서 미리 검증한다). 0.16 은 dialog 경로가 `Io` 를 요구하므로 여기까지 내려온다.
        rt: Runtime,
        allocator: std.mem.Allocator,
        font_families: []const []const u8,
        spec: font_spec.Spec,
        retina_scale: f32,
    ) !CoreTextFontContext {
        // Font *glyph fallback chain* — config.font.family 의 모든 폰트가
        // system 에 있어야 한다 (Windows DWriteFontContext 와 동등 strict 정책).
        // `CTFontCreateWithName` 은 lookup 실패 시 system substitute (대개
        // `.SF NS Mono`) 를 반환하니 `CTFontCopyFamilyName` 으로 *실제 family
        // name* 검증 → 우리 요청과 다르면 사용자가 명시한 폰트가 시스템에 없는
        // 것 → fatal `Font not found: "Foo"` (Windows messages 와 동일).
        //
        // 모든 chain 폰트를 fallback_fonts 에 저장 → resolveGlyph 가 codepoint
        // 별로 순회 (primary → secondary → ... → system auto fallback).
        var fallback_fonts: [MAX_FALLBACK_FONTS]ct.CTFontRef = undefined;
        var fallback_count: usize = 0;
        var font: ct.CTFontRef = undefined;
        var font_family: []const u8 = "";
        for (font_families) |family| {
            if (family.len == 0) continue;
            if (fallback_count >= MAX_FALLBACK_FONTS) break;
            const family_str = ct.CFStringCreateWithBytes(
                null,
                family.ptr,
                @intCast(family.len),
                ct.kCFStringEncodingUTF8,
                0,
            ) orelse {
                @import("../validate.zig").showNotFoundFatal(rt, family, font_families);
            };
            defer ct.CFRelease(family_str);
            var candidate = ct.CTFontCreateWithName(family_str, @floatCast(spec.size_logical), null) orelse {
                @import("../validate.zig").showNotFoundFatal(rt, family, font_families);
            };
            const actual_family = ct.CTFontCopyFamilyName(candidate);
            const matched = ct.CFStringCompare(actual_family, family_str, 0) == 0;
            if (!matched) {
                // 무엇으로 해석됐는지 — **로그에만** 쓴다. 아래 fatal 에는 넘기지 않는다.
                var sub_buf: [256]u8 = undefined;
                const sub: ?[]const u8 = blk: {
                    const n = ct.CFStringGetLength(actual_family);
                    if (n <= 0) break :blk null;
                    var used: ct.CFIndex = 0;
                    _ = ct.CFStringGetBytes(actual_family, ct.CFRange{ .location = 0, .length = n }, ct.kCFStringEncodingUTF8, 0, false, &sub_buf, @intCast(sub_buf.len), &used);
                    if (used <= 0) break :blk null;
                    break :blk sub_buf[0..@intCast(used)];
                };
                ct.CFRelease(actual_family);

                // #406 — **찾을 수 있는 이름이면 그 폰트로 띄운다.** 시작을 막는 것은 이름이
                // 아예 없을 때 (오타 · 미설치) 뿐이다. Linux 가 `FontconfigNoMatch` 로 가르는
                // 것과 같은 정책인데, 여기서는 `CTFontCreateWithName` 이 없는 이름에도 시스템
                // 기본을 돌려주므로 설치 목록을 직접 봐야 가를 수 있다.
                var canon_buf: [256]u8 = undefined;
                const canonical = resolveInstalledName(family, &canon_buf) orelse {
                    ct.CFRelease(candidate);
                    // ⚠️ **대체 이름을 넘기지 않는다** (`Sub` 아닌 쪽을 부른다). macOS 는
                    // **어떤 오타에도** 대체본을 주므로 (`Menloo` → `Helvetica`) 그 이름이
                    // 정보가 아니라 노이즈다 — "Helvetica 가 있으니 그걸 쓰나?" 로 읽힌다.
                    // Linux 는 fontconfig 가 실제로 별칭을 주입했을 때만 값이 나와서 유용하다.
                    @import("../validate.zig").showNotFoundFatal(rt, family, font_families);
                };

                if (std.mem.eql(u8, canonical, family)) {
                    // 사용자가 적은 그대로 설치된 이름이다. family 이름이 다르게 나오는 것은
                    // PostScript 이름을 적었을 때 정상이다 (`Menlo-Regular` → family `Menlo`).
                    log.appendLine("font", "chain[{d}] \"{s}\" is an installed font name (family \"{s}\") — using it", .{
                        fallback_count, family, sub orelse "?",
                    });
                } else {
                    // **정식 표기로 폰트를 다시 만든다.** `CTFontCreateWithName` 은 정규화를
                    // 모르기 때문에, 검사만 통과시키고 사용자가 적은 문자열을 그대로 쓰면 엉뚱한
                    // 폰트가 그려진다 — `menloregular` 를 그대로 주면 Helvetica 가 온다
                    // (실측: cell_w 19 → 25). `Menlo-Regular` 로 다시 만들면 의도대로 나온다.
                    var remade_ok = false;
                    if (ct.CFStringCreateWithBytes(
                        null,
                        canonical.ptr,
                        @intCast(canonical.len),
                        ct.kCFStringEncodingUTF8,
                        0,
                    )) |canon_str| {
                        defer ct.CFRelease(canon_str);
                        if (ct.CTFontCreateWithName(canon_str, @floatCast(spec.size_logical), null)) |remade| {
                            ct.CFRelease(candidate);
                            candidate = remade;
                            remade_ok = true;
                        }
                    }
                    if (remade_ok) {
                        log.appendLine("font", "chain[{d}] \"{s}\" matched installed \"{s}\" — using it", .{
                            fallback_count, family, canonical,
                        });
                    } else {
                        // 여기 오면 **엉뚱한 폰트로 그린다** (`sub`). 조용히 넘어가면 나중에
                        // "글자 폭이 왜 다르지" 로만 보이므로 원인을 로그에 남긴다.
                        log.appendLine("font", "chain[{d}] \"{s}\" matched installed \"{s}\" but re-create failed — falling back to \"{s}\"", .{
                            fallback_count, family, canonical, sub orelse "?",
                        });
                    }
                }
            } else {
                ct.CFRelease(actual_family);
            }
            fallback_fonts[fallback_count] = candidate;
            if (fallback_count == 0) {
                font = candidate;
                font_family = family;
            }
            fallback_count += 1;
        }
        if (fallback_count == 0) return error.FontCreateFailed;

        // CoreText 의 ascent / descent / leading 은 point 단위. atlas /
        // renderer 가 모두 pixel 단위로 동작하므로 init 시 scale 곱해 통일.
        const ascent: f32 = @floatCast(ct.CTFontGetAscent(font));
        const descent: f32 = @floatCast(ct.CTFontGetDescent(font));
        const leading: f32 = @floatCast(ct.CTFontGetLeading(font));
        const cap_height: f32 = @floatCast(ct.CTFontGetCapHeight(font));

        // Monospace 셀 폭 측정 — 'M' / 'i' / '.' advance 가 모두 같은지 확인
        // 후 'M' 의 advance 를 cell width 로. 한 글자라도 advance 가 다르면
        // proportional 폰트 (또는 system fallback) 가 매칭된 것 — terminal
        // 용도엔 부적합하므로 stderr 로 강한 경고. layout 자체는 진행 (셸이
        // 보이는 게 아예 안 보이는 것보단 낫다).
        const probes = [_]u16{ 'M', 'i', '.', 'W' };
        var probe_glyphs: [probes.len]ct.CGGlyph = @splat(0);
        _ = ct.CTFontGetGlyphsForCharacters(font, &probes, &probe_glyphs, probes.len);
        var probe_adv: [probes.len]ct.CGSize = @splat(.{ .width = 0, .height = 0 });
        _ = ct.CTFontGetAdvancesForGlyphs(
            font,
            ct.kCTFontOrientationHorizontal,
            &probe_glyphs,
            @ptrCast(&probe_adv),
            probes.len,
        );
        const advance_pt: f32 = @floatCast(probe_adv[0].width);

        // 'M' 글리프의 실제 visible top — 폰트 designer 의 cap_height metric
        // 보다 실제 raster 결과에 정확. ascent − bbox.top 이 위쪽 internal
        // leading. (cap_height 만 쓰면 폰트마다 metric 과 raster 결과가 살짝
        // 달라 보정이 부정확해질 수 있다.)
        var m_bbox: ct.CGRect = undefined;
        _ = ct.CTFontGetBoundingRectsForGlyphs(
            font,
            ct.kCTFontOrientationHorizontal,
            probe_glyphs[0..1].ptr,
            @ptrCast(&m_bbox),
            1,
        );
        const m_top_pt: f32 = @floatCast(m_bbox.origin.y + m_bbox.size.height);

        for (probe_adv[1..], probes[1..]) |a, ch| {
            const w: f32 = @floatCast(a.width);
            if (@abs(w - advance_pt) > 0.01) {
                @import("../../log.zig").appendLine(
                    "font",
                    "WARNING: '{c}' advance ({d}) != 'M' advance ({d}). '{s}' is not monospace — terminal layout will look broken.",
                    .{ @as(u8, @intCast(ch)), w, advance_pt, font_family },
                );
                break;
            }
        }

        // 픽셀 단위 cell. Windows 와 동일: advance × cell_width_ratio,
        // (ascent+descent+leading) × line_height_ratio. ceil 로 글리프 잘림
        // 방지. 1.1 / 0.95 같은 미적 보정값을 그대로 적용 가능.
        const cell_w_px = font_spec.scaledRatioCeilPx(advance_pt, spec.cell_width_ratio, retina_scale);
        const cell_h_px = font_spec.scaledRatioCeilPx(ascent + descent + leading, spec.line_height_ratio, retina_scale);

        // top_pad_px = ascent − 'M' bbox top. 폰트 metric (cap_height) 대신
        // 실제 'M' raster bbox 사용 — 폰트마다 metric 과 글리프 실제 모양이
        // 약간 다를 수 있어 더 정확.
        _ = cap_height;
        const top_pad_pt: f32 = ascent - m_top_pt;

        // #197 — primary 1줄 lifecycle (cross-platform 동일 형식). path 는 mac
        // (system font) 에 없어 제외. ascent/descent 는 retina 적용 후 px 정수.
        log.appendLine("font", "primary family={s} cell_w={d} cell_h={d} ascent={d} descent={d}", .{
            font_family,
            cell_w_px,
            cell_h_px,
            @as(u32, @intFromFloat(@round(ascent * retina_scale))),
            @as(u32, @intFromFloat(@round(descent * retina_scale))),
        });

        // #375 — 변종 chain. `CTFontCreateCopyWithSymbolicTraits` 는 해당 face 가
        // 없으면 null 을 주므로, 그 결과가 곧 "이 family 에 bold / italic 이 있나" 의
        // 답이다. 없으면 regular 를 retain 해 넣어 조회가 언제나 성공하게 한다.
        var styled_fonts: [font_constants.FaceStyle.count - 1][MAX_FALLBACK_FONTS]ct.CTFontRef = undefined;
        inline for ([_]font_constants.FaceStyle{ .bold, .italic, .bold_italic }) |fs| {
            const slot = fs.index() - 1;
            for (fallback_fonts[0..fallback_count], 0..) |base, i| {
                styled_fonts[slot][i] = styledCopy(base, spec.size_logical, fs);
            }
        }

        return .{
            .primary_font = font,
            .font_em_size = spec.size_logical,
            .retina_scale = retina_scale,
            .ascent_px = ascent * retina_scale,
            .descent_px = descent * retina_scale,
            .top_pad_px = top_pad_pt * retina_scale,
            .cell_width_px = cell_w_px,
            .cell_height_px = cell_h_px,
            .font_family = font_family,
            .fallback_fonts = fallback_fonts,
            .fallback_count = fallback_count,
            .styled_fonts = styled_fonts,
            .ligature_cache = ligature.Cache.init(allocator),
            .cluster_cache = cluster_cache.ClusterCache(GlyphResult, releaseCluster).init(allocator),
        };
    }

    // chain 의 한 폰트가 system 에 없을 때 — `font_validate.showNotFoundFatal`
    // (cross-platform) 가 chain dump + 미설치 표시 + config 경로 안내 + fatal.
    // Windows / macOS 같은 메시지 형식 사용.

    pub fn deinit(self: *CoreTextFontContext) void {
        self.ligature_cache.deinit();
        // #399 — 담아 둔 fallback 폰트들을 여기서 놓는다 (`releaseCluster`).
        //
        // **따로 `clear()` 를 부를 자리는 없다.** 폰트 · scale 이 바뀌면 renderer 가
        // `CoreTextFontContext.init` 으로 Context 를 새로 만들고 옛 것을 `deinit` 한다
        // (`renderer/macos.zig` 의 `applyScale`) — 폰트만 갈아 끼우는 경로가 없어서,
        // Linux 의 `freeFaces` 에 해당하는 무효화 지점이 이 자리 하나다. Windows 와 같다.
        self.cluster_cache.deinit();
        for (self.fallback_fonts[0..self.fallback_count]) |f| {
            ct.CFRelease(f);
        }
        // #375 — 변종 chain. face 가 없어 regular 를 retain 한 칸도 여기서 release 되어
        // 참조 수가 맞는다.
        for (&self.styled_fonts) |*chain| {
            for (chain[0..self.fallback_count]) |f| ct.CFRelease(f);
        }
    }

    /// #375 — 같은 family 의 변종 face. 없으면 `base` 를 retain 해 돌려준다
    /// (호출부가 소유권을 일관되게 다루도록 — 어느 쪽이든 `CFRelease` 한 번).
    fn styledCopy(base: ct.CTFontRef, size_logical: f32, style: font_constants.FaceStyle) ct.CTFontRef {
        var traits: u32 = 0;
        if (style.isBold()) traits |= ct.kCTFontTraitBold;
        if (style.isItalic()) traits |= ct.kCTFontTraitItalic;
        const mask = ct.kCTFontTraitBold | ct.kCTFontTraitItalic;
        if (ct.CTFontCreateCopyWithSymbolicTraits(base, @floatCast(size_logical), null, traits, mask)) |f| {
            return f;
        }
        return @ptrCast(ct.CFRetain(base));
    }

    /// grapheme cluster (base + extras) 통째 shape → 첫 run 의 첫 glyph 반환.
    /// VS-16 / skin tone / ZWJ 시퀀스 처리 (#132 B). CTLine 이 font fallback +
    /// glyph substitution 모두 자동 → cluster 가 단일 컬러 emoji 글리프로 reduce.
    ///
    /// `cps` 는 [base_cp, extras...] 의 codepoint 배열. UTF-16 으로 변환 후
    /// CFAttributedString (primary font 속성) → CTLine → 첫 CTRun 사용.
    /// 결과의 `font` 는 CTLine 이 fallback 으로 픽한 것 (Apple Color Emoji 등) —
    /// 우리가 따로 retain 안 했지만 CTLine 이 살아있는 동안만 유효. Caller 는
    /// 즉시 atlas getOrInsert 호출해 글리프 라스터 후 결과 사용 안 함.
    /// `owned = false` (CT 가 관리). 실패 시 null → caller 가 base codepoint 만
    /// 으로 fallback.
    ///
    /// #395 — 실제 구현은 `resolveGraphemeInner` 이고 여기서는 `perf.shape` 만 얹는다.
    /// cluster 셀마다 · 프레임마다 불리는 경로라, render 안에서 shaping 이 차지하는
    /// 몫을 이 카운터로 가른다. `return null` 경로가 여럿이라 본체를 건드리지 않도록
    /// wrapper 로 분리했다. Linux `resolveCluster` · Win `resolveGrapheme` 과 같은 모양.
    pub fn resolveGrapheme(self: *CoreTextFontContext, cps: []const u21) ?GlyphResult {
        const t0 = perf.now();
        const result = self.resolveGraphemeInner(cps);
        perf.addTimed(&perf.shape, t0);
        // miss — CT 가 cluster 를 글리프로 못 만든 경우. caller 가 base codepoint 로
        // fallback 한다.
        if (result == null) perf.incExtra(&perf.shape);
        return result;
    }

    /// 런 배칭 상한 ([#399](https://github.com/ensky0/tildaz/issues/399)). 한 줄이 120 열이라
    /// cluster 가 최대 그만큼이고, cluster 하나가 UTF-16 으로 최대 32 unit (16 codepoint ×
    /// surrogate) 이다. 넘으면 호출자가 런을 끊는다.
    pub const MAX_RUN_CLUSTERS = 128;
    const MAX_RUN_U16 = 4096;

    /// **여러 cluster 를 `CTLine` 하나로 shape 한다** (#399). 지금까지는 cluster 마다
    /// `resolveGrapheme` 을 불러 `CFString` · `CFDictionary` · `CFAttributedString` · `CTLine`
    /// 을 매번 새로 만들었는데, 그 **고정 비용이 지배적**이라 한 줄을 묶으면 실측으로
    /// 3.1~8.3 배 싸다 (#399 본문). `render` 의 92 % 가 이 경로다.
    ///
    /// 반환은 **채운 cluster 수**다. `out` 은 `clusters` 와 같은 순서로 채워지고, 0 이면
    /// 호출자가 기존 개별 경로로 떨어진다 — 렌더가 틀리느니 느린 게 낫다.
    ///
    /// **매핑**: cluster 를 구분자 없이 이어붙여도 grapheme break 경계가 유지된다 (실측:
    /// run 1 개 · 글리프가 cluster 당 정확히 1 개 · 항목 시작 위치에 정렬). `CTRunGetStringIndices`
    /// 가 각 글리프의 원본 UTF-16 위치를 주므로, 그 위치를 cluster 번호로 바꾸는 역맵
    /// (`u16_to_cluster`) 하나로 배분이 끝난다. cluster 길이가 제각각이라 나눗셈은 못 쓴다.
    ///
    /// **폰트 소유권**은 기존과 같다 (`owned = true`) — run 폰트를 cluster 마다 retain 하고
    /// 호출자가 각각 release 한다. 그래야 셀 루프의 해제 흐름이 안 바뀐다.
    pub fn resolveGraphemeRun(
        self: *CoreTextFontContext,
        clusters: []const []const u21,
        out: []GlyphResult,
    ) usize {
        const t0 = perf.now();
        const n = self.resolveGraphemeRunInner(clusters, out);
        perf.addTimed(&perf.shape, t0);
        // **여기서 miss 를 세지 않는다.** 런이 실패하면 호출자가 그 셀들을 개별 경로로 다시
        // 도는데, 거기서 `resolveGrapheme` 이 같은 실패를 또 센다 — 한 실패가 두 번 잡혀
        // 카운터가 부풀었다 (Linux 에서 180 → 1,211 로 보였다, 61c8795). 런 실패는 정상적인
        // fallback 이지 shaping 실패가 아니다.
        return n;
    }

    fn resolveGraphemeRunInner(
        self: *CoreTextFontContext,
        clusters: []const []const u21,
        out: []GlyphResult,
    ) usize {
        if (clusters.len == 0 or clusters.len > MAX_RUN_CLUSTERS) return 0;
        if (out.len < clusters.len) return 0;

        // #399 (B) — shape 하기 전에 런의 cluster 를 **전부** 캐시에서 찾는다. 다 있으면
        // `CTLine` 없이 끝난다. `zwj` 처럼 한 줄이 같은 cluster 면 첫 런 이후 shape 가 0 이다.
        //
        // 하나라도 없으면 (또는 캐시된 결과가 실패면) 아래 기존 경로로 간다 — 부분만 쓰고
        // 나머지를 shape 하는 식으로 섞지 않는다. 캐시가 계속 소유하므로 `owned = false` 다.
        var all_hit = true;
        for (clusters, 0..) |c, i| {
            if (self.cluster_cache.get(c)) |cached| {
                if (cached) |v| {
                    out[i] = v;
                    out[i].owned = false;
                    continue;
                }
            }
            all_hit = false;
            break;
        }
        if (all_hit) return clusters.len;

        var u16_buf: [MAX_RUN_U16]u16 = undefined;
        // UTF-16 위치 → cluster 번호. 이어붙인 뒤에는 길이 정보가 사라지므로 여기에 남긴다.
        var u16_to_cluster: [MAX_RUN_U16]u8 = undefined;
        var u16_len: usize = 0;

        for (clusters, 0..) |cps, ci| {
            if (cps.len == 0) return 0;
            for (cps) |cp| {
                if (cp <= 0xFFFF) {
                    if (u16_len + 1 > u16_buf.len) return 0;
                    u16_buf[u16_len] = @intCast(cp);
                    u16_to_cluster[u16_len] = @intCast(ci);
                    u16_len += 1;
                } else {
                    if (u16_len + 2 > u16_buf.len) return 0;
                    const offset = cp - 0x10000;
                    u16_buf[u16_len] = @intCast(0xD800 + (offset >> 10));
                    u16_buf[u16_len + 1] = @intCast(0xDC00 + (offset & 0x3FF));
                    u16_to_cluster[u16_len] = @intCast(ci);
                    u16_to_cluster[u16_len + 1] = @intCast(ci);
                    u16_len += 2;
                }
            }
        }
        if (u16_len == 0) return 0;

        const cf_str = ct.CFStringCreateWithCharacters(null, &u16_buf, @intCast(u16_len)) orelse return 0;
        defer ct.CFRelease(cf_str);

        const keys = [1]?*const anyopaque{@ptrCast(ct.kCTFontAttributeName)};
        const values = [1]?*const anyopaque{@ptrCast(self.primary_font)};
        const attrs = ct.CFDictionaryCreate(
            null,
            &keys,
            &values,
            1,
            @ptrCast(&ct.kCFTypeDictionaryKeyCallBacks),
            @ptrCast(&ct.kCFTypeDictionaryValueCallBacks),
        ) orelse return 0;
        defer ct.CFRelease(attrs);

        const attr_str = ct.CFAttributedStringCreate(null, cf_str, attrs) orelse return 0;
        defer ct.CFRelease(attr_str);

        const line = ct.CTLineCreateWithAttributedString(attr_str) orelse return 0;
        defer ct.CFRelease(line);

        // #401 — cluster 마다 **글리프를 전부** 모은다 (개별 경로와 같은 정책).
        //
        // 예전에는 첫 글리프만 담고 `glyphs` · `positions` · `count` 를 채우지 않았는데,
        // 호출부는 그 셋을 읽는다. 그래서 **미정의 값으로 그렸고, 그 결과가 캐시에까지 들어가**
        // 한 번 배칭을 탄 cluster 는 이후 개별 경로에서도 계속 깨졌다 (실기: `[áéíóú]` 가
        // 두부 하나로). 개별 경로만 multi-glyph 로 옮기고 여기를 빠뜨린 회귀였다.
        var filled = [_]bool{false} ** MAX_RUN_CLUSTERS;
        // 각 cluster 가 run 안에서 차지한 글리프 구간. 폭을 재고 (`CTRunGetTypographicBounds`)
        // 구간이 연속인지 확인하는 데 쓴다.
        var g_lo = [_]usize{0} ** MAX_RUN_CLUSTERS;
        var g_hi = [_]usize{0} ** MAX_RUN_CLUSTERS;
        var count: usize = 0;

        const runs = ct.CTLineGetGlyphRuns(line);
        const run_count = ct.CFArrayGetCount(runs);
        var r: ct.CFIndex = 0;
        while (r < run_count) : (r += 1) {
            const run_ptr = ct.CFArrayGetValueAtIndex(runs, r) orelse continue;
            const run: ct.CTRunRef = @constCast(run_ptr);
            const glyph_count = ct.CTRunGetGlyphCount(run);
            if (glyph_count <= 0) continue;

            // run 이 실제로 쓴 폰트 — CT 가 fallback 으로 고른 것이다. run 마다 다를 수 있어
            // (한 줄에 emoji 와 기호가 섞이는 경우) 여기서 읽는다.
            const run_attrs = ct.CTRunGetAttributes(run);
            const font_val = ct.CFDictionaryGetValue(run_attrs, @ptrCast(ct.kCTFontAttributeName)) orelse continue;
            const run_font: ct.CTFontRef = @constCast(font_val);

            const n: usize = @intCast(glyph_count);
            var glyphs_buf: [MAX_RUN_CLUSTERS * 2]ct.CGGlyph = undefined;
            var idx_buf: [MAX_RUN_CLUSTERS * 2]ct.CFIndex = undefined;
            var pos_buf: [MAX_RUN_CLUSTERS * 2]ct.CGPoint = undefined;
            // 글리프가 버퍼보다 많으면 앞부분만 본다. 그러면 뒤 cluster 가 안 채워져 아래에서
            // 0 으로 떨어지고, 런 전체가 개별 경로로 간다.
            const take = @min(n, glyphs_buf.len);

            const glyphs: [*]const ct.CGGlyph = if (ct.CTRunGetGlyphsPtr(run)) |p| p else blk: {
                ct.CTRunGetGlyphs(run, ct.CFRange{ .location = 0, .length = @intCast(take) }, &glyphs_buf);
                break :blk &glyphs_buf;
            };
            const indices: [*]const ct.CFIndex = if (ct.CTRunGetStringIndicesPtr(run)) |p| p else blk: {
                ct.CTRunGetStringIndices(run, ct.CFRange{ .location = 0, .length = @intCast(take) }, &idx_buf);
                break :blk &idx_buf;
            };
            const positions: [*]const ct.CGPoint = if (ct.CTRunGetPositionsPtr(run)) |p| p else blk: {
                ct.CTRunGetPositions(run, ct.CFRange{ .location = 0, .length = @intCast(take) }, &pos_buf);
                break :blk &pos_buf;
            };

            // 이 run 에서 채운 cluster 만 아래 후처리 대상이다 (run 이 여럿일 수 있다).
            var touched = [_]bool{false} ** MAX_RUN_CLUSTERS;

            var g: usize = 0;
            while (g < take) : (g += 1) {
                const glyph = glyphs[g];
                if (glyph == 0) continue; // .notdef — 이 cluster 는 안 채워져 아래에서 실패한다
                const si = indices[g];
                if (si < 0 or si >= u16_len) continue;
                const ci = u16_to_cluster[@intCast(si)];
                if (ci >= clusters.len) continue;
                if (!filled[ci]) {
                    filled[ci] = true;
                    touched[ci] = true;
                    g_lo[ci] = g;
                    g_hi[ci] = g;
                    // `index` 는 run 순서상 첫 글리프다 — 개별 경로와 같다. 폰트 retain 은
                    // **글리프를 담을 때마다** 한다 (`releaseCluster` 가 `count` 만큼 놓는다).
                    out[ci] = .{ .font = run_font, .index = glyph, .owned = true, .count = 0 };
                    count += 1;
                } else if (!touched[ci]) {
                    // 앞선 run 이 이미 채운 cluster 다. 섞지 않는다.
                    continue;
                } else {
                    if (g < g_lo[ci]) g_lo[ci] = g;
                    if (g > g_hi[ci]) g_hi[ci] = g;
                }
                if (out[ci].count < MAX_CLUSTER_GLYPHS) {
                    out[ci].glyphs[out[ci].count] = glyph;
                    out[ci].positions[out[ci].count] = positions[g];
                    out[ci].fonts[out[ci].count] = run_font;
                    _ = ct.CFRetain(run_font);
                    out[ci].count += 1;
                }
            }

            // cluster 별 후처리 — 위치를 cluster 안 상대 좌표로 바꾸고 폭을 잰다.
            for (0..clusters.len) |ci| {
                if (!touched[ci]) continue;
                const cnt: usize = out[ci].count;

                // 글리프 구간이 **연속이 아니면 이 런을 포기한다.** 다른 cluster 의 글리프가
                // 사이에 끼었다는 뜻이라 폭을 범위로 잴 수 없고, 글리프를 놓쳤을 수도 있다
                // (`MAX_CLUSTER_GLYPHS` 초과 · `.notdef` 섞임). 드문 경우이고 개별 경로가
                // 정확히 처리하므로 그쪽에 맡긴다.
                if (cnt == 0 or g_hi[ci] - g_lo[ci] + 1 != cnt) {
                    releaseCluster(out[ci]);
                    filled[ci] = false;
                    count -= 1;
                    continue;
                }

                // **가장 왼쪽 글리프를 원점으로 삼는다.** run 좌표를 그대로 두면 cluster 의
                // 절대 위치가 `bearing_x` 에 섞여 셀 밖으로 나간다. 첫 글리프가 아니라 최소
                // `x` 인 이유는 RTL 때문이다 — Arabic 은 run 안 cluster 순서가 뒤집혀서
                // (실측: `strIdx` 3,2,1,0) 첫 글리프가 왼쪽 끝이 아니다.
                var min_x = out[ci].positions[0].x;
                for (1..cnt) |k| {
                    if (out[ci].positions[k].x < min_x) min_x = out[ci].positions[k].x;
                }
                for (0..cnt) |k| out[ci].positions[k].x -= min_x;

                out[ci].font = out[ci].fonts[0];
                out[ci].advance = @floatCast(ct.CTRunGetTypographicBounds(
                    run,
                    ct.CFRange{ .location = @intCast(g_lo[ci]), .length = @intCast(cnt) },
                    null,
                    null,
                    null,
                ));
            }
        }

        // **하나라도 못 채우면 통째로 포기한다.** 부분 성공을 섞으면 어느 셀이 개별 경로로
        // 가야 하는지 호출자가 알 수 없고, 그 분기가 셀 루프를 복잡하게 만든다. 런 전체를
        // 개별 경로로 다시 도는 비용이 그보다 싸다 (실패는 드물다).
        if (count != clusters.len) {
            for (0..clusters.len) |i| {
                if (filled[i]) releaseCluster(out[i]);
            }
            return 0;
        }

        // #399 (B) — 다음 런이 shape 를 건너뛸 수 있게 담는다.
        //
        // ⚠️ **Windows 와 다른 자리다.** 거기는 런 결과가 전부 chain face (`owned = false`) 라
        // 소유권 문제가 없었지만, macOS 는 위에서 cluster 마다 `CFRetain` 했다. 그래서 담을 수
        // 있는 것만 담고 소유권을 캐시에 넘기며 (`owned = false`), **키 상한을 넘어 못 담는
        // cluster 는 `owned = true` 그대로 둬서** 호출자가 release 하게 한다. `put` 이 못 담는
        // 값을 그 자리에서 해제하기 때문에 (`cluster_cache.zig:78`) 이 판정을 건너뛰면 caller 가
        // 죽은 폰트를 쓴다.
        for (0..clusters.len) |i| {
            if (clusters[i].len <= cluster_cache.MAX_KEY_CPS) {
                self.cluster_cache.put(clusters[i], out[i]);
                out[i].owned = false;
            }
        }
        return count;
    }

    /// #399 (B) — 캐시를 씌운 층. shape 자체는 `resolveGraphemeUncached` 가 한다.
    ///
    /// **소유권이 이 함수의 핵심이다.** 셀 루프는 `result.owned` 면 매 프레임 `CFRelease` 하는데,
    /// 캐시에 담은 폰트를 `owned = true` 로 돌려주면 그 release 가 캐시 안의 폰트를 죽인다
    /// (use-after-free). 그래서 **캐시가 소유권을 가져가고 caller 에게는 `owned = false`** 로
    /// 준다. 해제는 `releaseCluster` 가 퇴출 · 무효화 때 한다.
    ///
    /// ⚠️ **담지 못하는 cluster 는 소유권을 넘기면 안 된다.** `ClusterCache.put` 은 키 상한
    /// (`MAX_KEY_CPS` = 8) 을 넘으면 담지 않고 **그 자리에서 값을 해제**한다 (소유권을 받았다고
    /// 보기 때문이다). 그때도 `owned = false` 로 바꿔 주면 caller 가 이미 죽은 폰트를 쓴다.
    /// 그래서 담을 수 있는지 **먼저 판정**하고, 못 담으면 원래 소유권 그대로 돌려준다
    /// (Windows 에서 실제로 걸린 함정이다, 07ae715).
    fn resolveGraphemeInner(self: *CoreTextFontContext, cps: []const u21) ?GlyphResult {
        if (self.cluster_cache.get(cps)) |cached| {
            const c = cached orelse return null; // negative hit — CTLine 을 다시 헛 만들지 않는다
            var out = c;
            out.owned = false; // 캐시가 계속 소유한다
            return out;
        }

        const result = self.resolveGraphemeUncached(cps);
        if (cps.len == 0 or cps.len > cluster_cache.MAX_KEY_CPS) return result;

        self.cluster_cache.put(cps, result);
        const r = result orelse return null;
        var out = r;
        out.owned = false;
        return out;
    }

    fn resolveGraphemeUncached(self: *CoreTextFontContext, cps: []const u21) ?GlyphResult {
        if (cps.len == 0) return null;

        // UTF-16 buffer — 각 codepoint 가 1~2 unit. 최대 16 cp 까지 지원 (긴
        // ZWJ 시퀀스는 보통 ≤ 8 cp). overflow 시 truncate.
        var utf16_buf: [32]u16 = undefined;
        var utf16_len: usize = 0;
        for (cps) |cp| {
            if (cp <= 0xFFFF) {
                if (utf16_len + 1 > utf16_buf.len) break;
                utf16_buf[utf16_len] = @intCast(cp);
                utf16_len += 1;
            } else {
                if (utf16_len + 2 > utf16_buf.len) break;
                const offset = cp - 0x10000;
                utf16_buf[utf16_len] = @intCast(0xD800 + (offset >> 10));
                utf16_buf[utf16_len + 1] = @intCast(0xDC00 + (offset & 0x3FF));
                utf16_len += 2;
            }
        }
        if (utf16_len == 0) return null;

        const cf_str = ct.CFStringCreateWithCharacters(null, &utf16_buf, @intCast(utf16_len)) orelse return null;
        defer ct.CFRelease(cf_str);

        // CFDictionary { kCTFontAttributeName: primary_font } — CT 가 shaping
        // 시 이 font 부터 시작해 emoji 자동 fallback.
        const keys = [1]?*const anyopaque{@ptrCast(ct.kCTFontAttributeName)};
        const values = [1]?*const anyopaque{@ptrCast(self.primary_font)};
        const attrs = ct.CFDictionaryCreate(
            null,
            &keys,
            &values,
            1,
            @ptrCast(&ct.kCFTypeDictionaryKeyCallBacks),
            @ptrCast(&ct.kCFTypeDictionaryValueCallBacks),
        ) orelse return null;
        defer ct.CFRelease(attrs);

        const attr_str = ct.CFAttributedStringCreate(null, cf_str, attrs) orelse return null;
        defer ct.CFRelease(attr_str);

        const line = ct.CTLineCreateWithAttributedString(attr_str) orelse return null;
        defer ct.CFRelease(line);

        const runs = ct.CTLineGetGlyphRuns(line);
        const run_count = ct.CFArrayGetCount(runs);
        if (run_count == 0) return null;

        // #401 — **글리프를 전부 가져온다.** 예전에는 첫 개만 쓰고 버렸는데, Apple Color Emoji
        // 가 `👨‍❤️‍👨` 같은 `❤️` 조합을 글리프 2 개로 줘서 `👨` 만 그려졌다. 폰트가 1 개로
        // 합성해 주는 cluster (`👨‍👩‍👧` 등) 는 아래 경로가 그대로 `count == 1` 이 된다.
        //
        // #420 — **run 도 전부 돈다.** 예전에는 첫 run 만 썼는데, `가` + acute 처럼 CoreText 가
        // base 와 mark 를 다른 폰트로 배정하면 run 이 2 개가 되어 **mark 가 통째로 사라졌다**
        // (실측 — `Apple SD Gothic Neo` + `Monaco`). 위치는 run 을 가로질러 이어지므로
        // (`CTRunGetPositions` 는 line 좌표계다) 그대로 모으면 된다.
        var glyphs: [MAX_CLUSTER_GLYPHS]ct.CGGlyph = undefined;
        var positions: [MAX_CLUSTER_GLYPHS]ct.CGPoint = undefined;
        var fonts: [MAX_CLUSTER_GLYPHS]ct.CTFontRef = undefined;
        var take: usize = 0;
        var advance: f64 = 0;

        var r: ct.CFIndex = 0;
        while (r < run_count and take < MAX_CLUSTER_GLYPHS) : (r += 1) {
            const run_ptr = ct.CFArrayGetValueAtIndex(runs, r) orelse continue;
            const run: ct.CTRunRef = @constCast(run_ptr);
            const glyph_count = ct.CTRunGetGlyphCount(run);
            if (glyph_count <= 0) continue;

            // run 의 실제 사용 폰트 — CT 가 fallback 으로 골라준 것 (Apple Color Emoji 등).
            // GetAttributes 와 GetValue 는 non-owning reference 라 line 이 release 되면
            // 무효. CFRetain 으로 caller 에게 ownership 넘김 → `releaseCluster` 가 놓는다.
            const run_attrs = ct.CTRunGetAttributes(run);
            const font_val = ct.CFDictionaryGetValue(run_attrs, @ptrCast(ct.kCTFontAttributeName)) orelse continue;
            const run_font: ct.CTFontRef = @constCast(font_val);

            const n: usize = @min(@as(usize, @intCast(glyph_count)), MAX_CLUSTER_GLYPHS - take);
            var gbuf: [MAX_CLUSTER_GLYPHS]ct.CGGlyph = undefined;
            var pbuf: [MAX_CLUSTER_GLYPHS]ct.CGPoint = undefined;
            if (ct.CTRunGetGlyphsPtr(run)) |ptr| {
                @memcpy(gbuf[0..n], ptr[0..n]);
            } else {
                ct.CTRunGetGlyphs(run, ct.CFRange{ .location = 0, .length = @intCast(n) }, &gbuf);
            }
            // 위치는 GPOS 가 적용된 값이라 이대로 그려야 모양이 맞는다. Windows 가 `advances` ·
            // `offsets` 를 함께 넘기는 것과 같은 이유다 (#139).
            if (ct.CTRunGetPositionsPtr(run)) |ptr| {
                @memcpy(pbuf[0..n], ptr[0..n]);
            } else {
                ct.CTRunGetPositions(run, ct.CFRange{ .location = 0, .length = @intCast(n) }, &pbuf);
            }

            for (0..n) |i| {
                glyphs[take] = gbuf[i];
                positions[take] = pbuf[i];
                fonts[take] = run_font;
                _ = ct.CFRetain(run_font);
                take += 1;
            }
            // cluster 폭은 run 들의 폭을 더한다. run 이 하나면 곧 그 cluster 의 폭이다.
            advance += ct.CTRunGetTypographicBounds(
                run,
                ct.CFRange{ .location = 0, .length = @intCast(n) },
                null,
                null,
                null,
            );
        }

        // `.notdef` 는 실패로 본다 — caller 가 base codepoint 로 fallback 한다.
        if (take == 0 or glyphs[0] == 0) {
            for (fonts[0..take]) |f| ct.CFRelease(f);
            return null;
        }

        return .{
            .font = fonts[0],
            .index = glyphs[0],
            .owned = true,
            .glyphs = glyphs,
            .positions = positions,
            .fonts = fonts,
            .count = @intCast(take),
            .advance = @floatCast(advance),
        };
    }

    /// 2-char ligature lookup (SPEC § 12.2). `cp0` + `cp1` 을 primary font 로
    /// CTLine shape 한 후 결과 glyph 들 vs natural (= `CTFontGetGlyphsForCharacters`
    /// 결과) 비교로 `LigatureMatch` 판정 — 공유 `ligature.classify` 사용.
    ///
    /// Latin ligature 는 primary font 의 GSUB — fallback chain 안 봄. Fira Code 등
    /// ligature 폰트가 user 의 primary 일 때만 의미. caller (renderer/macos) 는
    /// `.single` glyph 또는 `.spacer` glyphs 를 `primary_font` 기준 atlas 에
    /// raster.
    pub fn ligaturePair(self: *CoreTextFontContext, cp0: u21, cp1: u21) ?LigatureMatch {
        if (self.ligature_cache.getPair(cp0, cp1)) |cached| return cached;
        var cps = [_]u21{ cp0, cp1 };
        const result = self.ligatureShape(&cps);
        self.ligature_cache.putPair(cp0, cp1, result);
        return result;
    }

    /// 3-char ligature lookup. `===` / `!==` / `<=>` / `<--` / `-->` 등.
    pub fn ligatureTriple(self: *CoreTextFontContext, cp0: u21, cp1: u21, cp2: u21) ?LigatureMatch {
        if (self.ligature_cache.getTriple(cp0, cp1, cp2)) |cached| return cached;
        var cps = [_]u21{ cp0, cp1, cp2 };
        const result = self.ligatureShape(&cps);
        self.ligature_cache.putTriple(cp0, cp1, cp2, result);
        return result;
    }

    /// CTLine 짧은 line shape + `ligature.classify`. natural indices 는 primary
    /// font 의 `CTFontGetGlyphsForCharacters` 로 직접 계산. `resolveGrapheme` 의
    /// CTLine 호출 패턴 재사용 (fallback chain 부착 안 함 — Latin ligature 는
    /// primary 에서만).
    fn ligatureShape(self: *CoreTextFontContext, cps: []const u21) ?LigatureMatch {
        if (cps.len == 0 or cps.len > 4) return null;

        // UTF-16 buffer — ASCII 만 candidate (`isLigatureCandidate` 0x20..0x7E)
        // 라 항상 1 unit / cp. 안전을 위해 surrogate pair 도 처리.
        var utf16_buf: [8]u16 = undefined;
        var utf16_len: usize = 0;
        var cp_to_utf16_index: [4]u8 = .{ 0, 0, 0, 0 };
        for (cps, 0..) |cp, i| {
            cp_to_utf16_index[i] = @intCast(utf16_len);
            if (cp <= 0xFFFF) {
                if (utf16_len + 1 > utf16_buf.len) return null;
                utf16_buf[utf16_len] = @intCast(cp);
                utf16_len += 1;
            } else {
                if (utf16_len + 2 > utf16_buf.len) return null;
                const offset = cp - 0x10000;
                utf16_buf[utf16_len] = @intCast(0xD800 + (offset >> 10));
                utf16_buf[utf16_len + 1] = @intCast(0xDC00 + (offset & 0x3FF));
                utf16_len += 2;
            }
        }
        if (utf16_len == 0) return null;

        // Natural glyph indices — primary font 의 cp → glyph_index 직접 매핑.
        // ligature 가 *substitute* 한 경우 shape 결과의 glyph_index 가 이 값과
        // 다름. ASCII candidate 라 BMP 안, surrogate 없음 가정.
        var natural: [4]ct.CGGlyph = .{ 0, 0, 0, 0 };
        var natural_u16: [4]u16 = undefined;
        for (cps, 0..) |cp, i| natural_u16[i] = @intCast(cp & 0xFFFF);
        _ = ct.CTFontGetGlyphsForCharacters(self.primary_font, &natural_u16, &natural, @intCast(cps.len));

        // CTLine shape on primary font.
        const cf_str = ct.CFStringCreateWithCharacters(null, &utf16_buf, @intCast(utf16_len)) orelse return null;
        defer ct.CFRelease(cf_str);

        const keys = [1]?*const anyopaque{@ptrCast(ct.kCTFontAttributeName)};
        const values = [1]?*const anyopaque{@ptrCast(self.primary_font)};
        const attrs = ct.CFDictionaryCreate(
            null,
            &keys,
            &values,
            1,
            @ptrCast(&ct.kCFTypeDictionaryKeyCallBacks),
            @ptrCast(&ct.kCFTypeDictionaryValueCallBacks),
        ) orelse return null;
        defer ct.CFRelease(attrs);

        const attr_str = ct.CFAttributedStringCreate(null, cf_str, attrs) orelse return null;
        defer ct.CFRelease(attr_str);

        const line = ct.CTLineCreateWithAttributedString(attr_str) orelse return null;
        defer ct.CFRelease(line);

        const runs = ct.CTLineGetGlyphRuns(line);
        if (ct.CFArrayGetCount(runs) == 0) return null;
        const run_ptr = ct.CFArrayGetValueAtIndex(runs, 0) orelse return null;
        const run: ct.CTRunRef = @constCast(run_ptr);

        const glyph_count_i = ct.CTRunGetGlyphCount(run);
        if (glyph_count_i <= 0) return null;
        const glyph_count: usize = @intCast(glyph_count_i);

        // run 의 font 가 primary 와 다르면 (= CT 의 system fallback 으로 다른
        // font 선택) — Latin ligature 가 아니라 char fallback. ligature 미적용
        // 으로 판정 (single-char path 가 자기 처리).
        const run_attrs = ct.CTRunGetAttributes(run);
        const font_val = ct.CFDictionaryGetValue(run_attrs, @ptrCast(ct.kCTFontAttributeName)) orelse return null;
        if (@as(ct.CTFontRef, @constCast(font_val)) != self.primary_font) return null;

        var glyphs_buf: [4]ct.CGGlyph = .{ 0, 0, 0, 0 };
        const checked = @min(glyph_count, glyphs_buf.len);
        if (ct.CTRunGetGlyphsPtr(run)) |ptr| {
            for (0..checked) |i| glyphs_buf[i] = ptr[i];
        } else {
            ct.CTRunGetGlyphs(run, ct.CFRange{ .location = 0, .length = @intCast(checked) }, &glyphs_buf);
        }

        // CTRun 의 per-glyph positions — GPOS adjustment 가 적용된 실제 위치.
        // Fira Code 6.x 의 `||=` spacer 같이 GPOS 가 `=` glyph 을 `||` 쪽으로
        // 당겨 시각상 연결시키는 디자인은 이 positions 에 반영됨. 우리 paint
        // 가 cell-aligned 으로 draw 하니, (실제 position) − (기본 monospace
        // position = i * cell_w) 차이를 spacer 의 x_offset 으로 추출 → emit
        // 단계에서 cell base position 에 더해줘 정확한 GPOS 위치에 그림.
        var positions_buf: [4]ct.CGPoint = .{
            .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 },
        };
        if (ct.CTRunGetPositionsPtr(run)) |ptr| {
            for (0..checked) |i| positions_buf[i] = ptr[i];
        } else {
            ct.CTRunGetPositions(run, ct.CFRange{ .location = 0, .length = @intCast(checked) }, &positions_buf);
        }

        // CT positions 는 **logical points** (font_em_size unit) — cell_w_px
        // 는 **physical pixels** (× retina_scale). offset 계산 시 positions ×
        // retina_scale 해서 픽셀로 변환 후 default cell 위치와 비교. SPEC §
        // `ShapedSlot.x_offset` convention = PIXELS.
        const cell_w_f: f64 = @floatFromInt(self.cell_width_px);
        const retina: f64 = @floatCast(self.retina_scale);
        var slots: [4]ligature.ShapedSlot = undefined;
        for (0..checked) |i| {
            const cp_idx = @min(i, cps.len - 1);
            const actual_x_px: f64 = positions_buf[i].x * retina; // points → pixels
            const default_x_px: f64 = @as(f64, @floatFromInt(i)) * cell_w_f;
            const offset_x: f64 = actual_x_px - default_x_px;
            // y_offset = 0 — Fira Code 의 GPOS y 조정 거의 없음.
            slots[i] = .{
                .glyph_index = glyphs_buf[i],
                .natural_glyph_index = natural[cp_idx],
                .x_offset = @intFromFloat(@round(offset_x)),
                .y_offset = 0,
            };
        }
        return ligature.classify(cps.len, slots[0..checked]);
    }

    /// codepoint → (font, glyph_index) 해석. config.font.family chain 순회 →
    /// 첫 번째 글리프 가진 폰트 사용 (Windows DWriteFontContext 와 동등). chain
    /// 모두 없으면 `CTFontCreateForString` 의 system auto fallback (Apple Color
    /// Emoji 등). system fallback 결과는 `owned = true` — caller 가 CFRelease.
    /// `style` (#375) 은 SGR `1` · `3` 이 요구하는 face 변종이다. chain 순회만
    /// 이 값을 따르고, grapheme cluster (emoji 등) · ligature 경로는 regular 를
    /// 그대로 쓴다 — 컬러 emoji 에 굵기는 의미가 없고, ligature 는 `style_id` 가
    /// 같은 구간에서만 일어나므로 섞이지 않는다.
    pub fn resolveGlyph(self: *CoreTextFontContext, codepoint: u21, style: font_constants.FaceStyle) ?GlyphResult {
        // codepoint 를 UTF-16 surrogate pair (또는 single unit) 으로.
        var utf16_buf: [2]u16 = undefined;
        var utf16_len: usize = undefined;
        if (codepoint <= 0xFFFF) {
            utf16_buf[0] = @intCast(codepoint);
            utf16_len = 1;
        } else {
            const cp = codepoint - 0x10000;
            utf16_buf[0] = @intCast(0xD800 + (cp >> 10));
            utf16_buf[1] = @intCast(0xDC00 + (cp & 0x3FF));
            utf16_len = 2;
        }

        // 1. chain 순회 — 글리프 가진 첫 폰트 사용.
        for (self.chainFor(style)) |f| {
            var glyphs: [2]ct.CGGlyph = .{ 0, 0 };
            if (ct.CTFontGetGlyphsForCharacters(f, &utf16_buf, &glyphs, @intCast(utf16_len))) {
                if (glyphs[0] != 0) {
                    return .{ .font = f, .index = glyphs[0], .owned = false, .fonts = .{f} ** MAX_CLUSTER_GLYPHS };
                }
            }
        }

        // 2. chain 모두 없으면 system auto fallback (CTFontCreateForString).
        //    Apple Color Emoji 같이 chain 에 명시 안 한 폰트 자동 찾음.
        const str = ct.CFStringCreateWithCharacters(null, &utf16_buf, @intCast(utf16_len)) orelse return null;
        defer ct.CFRelease(str);

        const fallback_font = ct.CTFontCreateForString(self.primary_font, str, ct.CFRange{ .location = 0, .length = @intCast(utf16_len) });
        if (fallback_font == null) return null;

        var fb_glyphs: [2]ct.CGGlyph = .{ 0, 0 };
        if (ct.CTFontGetGlyphsForCharacters(fallback_font.?, &utf16_buf, &fb_glyphs, @intCast(utf16_len))) {
            if (fb_glyphs[0] != 0) {
                return .{ .font = fallback_font.?, .index = fb_glyphs[0], .owned = true, .fonts = .{fallback_font.?} ** MAX_CLUSTER_GLYPHS };
            }
        }

        // fallback 에서도 못 찾으면 release.
        ct.CFRelease(fallback_font.?);
        return null;
    }
};
