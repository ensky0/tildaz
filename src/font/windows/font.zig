// DirectWrite font context — GL/D2D independent.
// Extracted from font_atlas.zig for use with Direct2D renderer.

const std = @import("std");
const dw = @import("directwrite.zig");
const font_constants = @import("../constants.zig");
const ligature = @import("../ligature.zig");
const cluster_cache = @import("../cluster_cache.zig");
const font_spec = @import("../spec.zig");
const log = @import("../../log.zig");
const perf = @import("../../perf.zig");
const atlas_common = @import("../../renderer/glyph_atlas_common.zig");
const presentation = @import("../presentation.zig");
const synthetic = @import("../synthetic.zig");
const Presentation = presentation.Presentation;

const BOOL = std.os.windows.BOOL;
const WCHAR = u16;

/// font.family chain 의 최대 길이.
pub const MAX_CHAIN: usize = font_constants.MAX_CHAIN;

// Cross-platform ligature 타입 re-export — caller (renderer/windows.zig) 가
// `font.LigatureMatch` 식으로 그대로 쓸 수 있게.
pub const LigatureGlyph = ligature.LigatureGlyph;
pub const LigatureSpacer = ligature.LigatureSpacer;
pub const LigatureMatch = ligature.LigatureMatch;

pub const GlyphResult = struct {
    face: *dw.IDWriteFontFace,
    index: dw.UINT16,
    owned: bool, // true = caller must Release face
    /// [#584](https://github.com/ensky0/tildaz/issues/584) — atlas 키가 쓰는 **안정된 폰트 id**
    /// (`atlas_common.fontId`). Windows 의 단일 경로는 `glyph_map` 이 fallback face 를 붙잡아
    /// 주소가 안정적이지만, **키 타입을 세 platform 이 공유**하므로 여기도 id 를 싣는다.
    /// cluster 가 글리프 하나로 합성되는 경로는 그 캐시를 거치지 않아 id 가 실제로 필요하다.
    ///
    /// **기본값을 두지 않는다** ([#749](https://github.com/ensky0/tildaz/issues/749)). 빠뜨린 자리가
    /// 0 을 받으면 모든 폰트가 한 id 를 나눠 써서, 같은 글리프 번호의 남의 그림이 그려진다.
    font_id: u64,
    /// #759 — 그릴 때 [`synthetic.slant`](../synthetic.zig) 로 기울인다. DirectWrite 의 기울임 합성
    /// (0.340) 을 뺀 face 에만 붙는다 (`DWriteFontContext.styled_slant`). 저장소 키는 `font_id`
    /// 가 이미 가른다 — 합성 비트가 섞여 있다 (`withSimulations`).
    slant: bool = false,
};

/// ZWJ family / VS-16 / skin tone modifier cluster 의 multi-glyph 결과 (#139).
/// Segoe UI Emoji 가 family ZWJ chain 을 single glyph 로 GSUB 합성 못 하면
/// `count > 1` 의 multi-glyph cluster 반환. atlas 가 multi-glyph DrawGlyphRun
/// 으로 한 번에 그려서 single composite glyph 로 cache.
pub const MAX_CLUSTER_GLYPHS: usize = 16;
pub const ClusterResult = struct {
    face: *dw.IDWriteFontFace,
    /// [#584](https://github.com/ensky0/tildaz/issues/584) — cluster 키가 쓰는 **안정된 폰트 id**
    /// (`atlas_common.fontId` = PostScript 이름의 FNV-1a 해시).
    ///
    /// **주소를 쓰지 않는다.** system fallback (`tryClusterOnSystemFallback`) 은 `CreateFontFace`
    /// 로 face 를 매번 새로 만들고, cluster 캐시가 `CAPACITY` 를 넘으면 통째로 비우며 그것을
    /// 해제한다. 그래서 같은 폰트가 주소 여럿을 갖는다 — Windows 실기에서 `MV Boli` 가 한
    /// 프로세스 안에서 주소 2 개로 나왔다 (macOS 는 `Monaco` 가 50 개였다). 주소를 키에 실으면
    /// 같은 그림이 id 마다 새로 담겨 atlas 가 부푼다.
    ///
    /// cluster 하나는 face 하나로 shape 하므로 macOS 처럼 run 별로 섞을 일이 없다 — 값 하나다.
    ///
    /// **기본값을 두지 않는다** (#749) — `GlyphResult.font_id` 와 같은 이유다. 단일 글리프 경로가
    /// 이 값을 빠뜨려 맑은 고딕 `사` (1740) 자리에 Cascadia `8` (1740) 이 그려졌다.
    font_id: u64,
    indices: [MAX_CLUSTER_GLYPHS]dw.UINT16,
    advances: [MAX_CLUSTER_GLYPHS]dw.FLOAT,
    offsets: [MAX_CLUSTER_GLYPHS]dw.DWRITE_GLYPH_OFFSET,
    count: u8,
    owned: bool,
    /// [#418](https://github.com/ensky0/tildaz/issues/418) — cluster 의 결합 기호가 **전부
    /// overlay 류** (Unicode combining class 1, 글자를 관통하는 mark) 인지. renderer 가
    /// 배치되지 않은 mark 를 **세로로도** base 잉크 중앙에 맞출지 정하는 데 쓴다.
    ///
    /// 이 판정은 codepoint 를 알아야 해서 폰트 층에서 한다 — atlas 는 glyph index 만 받는다.
    /// **전부** overlay 일 때만 참이다. 위 mark 와 섞이면 (`a` + acute + stroke) 보수적으로
    /// 거짓이 되어 세로 보정을 하지 않는다 — 위 mark 를 글자 가운데로 내리면 안 되기 때문이다.
    overlay_marks: bool = false,
    /// #759 — `GlyphResult.slant` 와 같다. 셀 글자 경로가 `resolveGlyph` 결과를 이 구조로 다시
    /// 담으므로, 여기서 빠뜨리면 atlas 가 기울이지 않는다 (Windows 실기에서 한글 Italic 이 똑바로
    /// 섰다). 여러 글리프 cluster 는 regular chain 으로만 shape 해서 늘 `false` 다.
    slant: bool = false,
};

/// [#418](https://github.com/ensky0/tildaz/issues/418) — **글자를 관통하는 결합 기호**인지.
///
/// Unicode combining class **1 (Overlay)** 에 해당하는 codepoint 집합이다. 이 부류는 base 위나
/// 아래가 아니라 **글자를 가로질러** 놓여야 하고, HarfBuzz 의 fallback mark positioning 도
/// combining class 로 위 · 아래 · 관통을 갈라 세로 위치를 정한다
/// (`hb-ot-shape-fallback` 의 `position_mark`).
///
/// 집합이 작고 고정이라 표로 둔다 — 이 때문에 Unicode 데이터 의존을 새로 들이지는 않는다
/// (`font/windows/font.zig` 는 ghostty 비의존을 유지한다).
fn isOverlayMark(cp: u21) bool {
    return switch (cp) {
        0x0334...0x0338 => true, // tilde · short stroke · long stroke · short solidus · long solidus
        0x20D2, 0x20D3 => true, // combining long / short vertical line overlay
        0x20E5, 0x20E6 => true, // reverse solidus · double vertical stroke overlay
        0x20EB => true, // long double solidus overlay
        else => false,
    };
}

/// [#420](https://github.com/ensky0/tildaz/issues/420) — **폭을 차지하지 않아야 하는 결합 기호**인지.
///
/// Unicode 의 combining mark 전용 블록들이고 전부 nonspacing (`Mn`) / enclosing (`Me`) 이다.
/// 이 codepoint 가 `advance ≠ 0` 인 글리프로 shaping 되면 그 face 는 결합 기호를 **spacing
/// 글리프로 그리는 것**이라, base 뒤에 한 칸 밀려 그려지고 옆 칸을 덮는다 (실측: `漢`+acute 를
/// CJK fallback face 가 `advance = 7.5` 로 줬다).
///
/// Hangul Jamo (`U+1100`~) · ZWJ (`U+200D`) · 가나 濁点 (`U+3099`) 은 **일부러 뺐다** — 그것들은
/// 폭을 갖거나 GSUB 로 합성되는 것이 정상이라 같은 기준으로 판정하면 안 된다.
fn isCombiningMark(cp: u21) bool {
    return switch (cp) {
        0x0300...0x036F => true, // Combining Diacritical Marks
        0x1AB0...0x1AFF => true, // 〃 Extended
        0x1DC0...0x1DFF => true, // 〃 Supplement
        0x20D0...0x20F0 => true, // 〃 for Symbols
        0xFE20...0xFE2F => true, // Combining Half Marks
        else => false,
    };
}

/// [#423](https://github.com/ensky0/tildaz/issues/423) — **조합형 한글 자모를 완성형 음절로
/// 합친다** (Unicode 3.12 *Conjoining Jamo Behavior* 의 canonical composition).
///
/// DirectWrite 는 `ᄀ`+`ᅡ` (`U+1100 U+1161`) 를 **두 cluster 로 보고** (`clusterMap = [0,1]`)
/// 합치지 않는다. 그래서 자모가 각각 `advance = 15` (full em) 로 나와 배정된 2 칸 (18 px) 을
/// 넘고 옆 칸을 덮는다. script · locale (`ko-kr`) · `DWRITE_SCRIPT_SHAPES` · OpenType feature
/// (`ljmo`/`vjmo`/`tjmo`) 를 **전부 줘 봐도 결과가 같았다** (Malgun Gothic 실측 2026-08-09).
///
/// **HarfBuzz 의 Hangul shaper 는 이 composition 을 표준대로 한다** (`hb-ot-shaper-hangul.cc`) —
/// 그래서 Linux 는 무증상이고, CoreText 도 마찬가지다. DirectWrite 에만 없는 층이라 여기서
/// 채운다. 조합형과 완성형은 Unicode 가 **정규화 동치**로 정의한 같은 글자다.
///
/// 표가 필요 없다 — 산술이 곧 표준이다. 완전한 `L+V` / `L+V+T` 만 합치고, 자모가 아니거나
/// 시퀀스가 불완전하면 (V 로 시작 · L 만 · T 만) **입력을 그대로 돌려준다.** 합친 뒤 남는
/// codepoint (결합 기호 등) 는 뒤에 그대로 잇는다.
fn composeHangul(cps: []const u21, out: *[MAX_CLUSTER_GLYPHS]u21) []const u21 {
    const L_BASE: u21 = 0x1100;
    const V_BASE: u21 = 0x1161;
    const T_BASE: u21 = 0x11A7; // T 는 1 부터 쓴다 (0 = 종성 없음)
    const S_BASE: u21 = 0xAC00;
    const L_COUNT: u21 = 19;
    const V_COUNT: u21 = 21;
    const T_COUNT: u21 = 28;

    if (cps.len < 2) return cps;
    const l = cps[0];
    if (l < L_BASE or l >= L_BASE + L_COUNT) return cps;
    const v = cps[1];
    if (v < V_BASE or v >= V_BASE + V_COUNT) return cps;

    var used: usize = 2;
    var ti: u21 = 0;
    if (cps.len >= 3) {
        const t = cps[2];
        if (t > T_BASE and t < T_BASE + T_COUNT) {
            ti = t - T_BASE;
            used = 3;
        }
    }

    out[0] = S_BASE + ((l - L_BASE) * V_COUNT + (v - V_BASE)) * T_COUNT + ti;
    var n: usize = 1;
    for (cps[used..]) |cp| {
        if (n >= out.len) break;
        out[n] = cp;
        n += 1;
    }
    return out[0..n];
}

/// cluster 의 결합 기호가 전부 overlay 류인지 (`ClusterResult.overlay_marks`).
fn clusterOverlayOnly(cps: []const u21) bool {
    if (cps.len < 2) return false;
    for (cps[1..]) |cp| {
        if (!isOverlayMark(cp)) return false;
    }
    return true;
}

const CachedGlyph = struct {
    face: *dw.IDWriteFontFace,
    index: u16,
    /// #584 — atlas 키가 쓰는 폰트 id. 캐시에 담을 때 한 번만 구한다.
    font_id: u64,
};

/// #399 (B) — cluster 캐시가 값을 버릴 때 (퇴출 · 무효화 · 덮어쓰기) 부르는 해제다.
///
/// **`owned` 인 것만 놓는다.** chain face 는 context 가 process lifetime 동안 들고 있고
/// (atlas cache key 가 face 포인터라 안정성이 필수다) `MapCharacters` 로 얻은 face 만
/// 우리가 소유한다 — 그 구분이 곧 `owned` 다.
fn releaseCluster(v: ClusterResult) void {
    if (v.owned) _ = v.face.vtable.Release(v.face);
}

/// [#409](https://github.com/ensky0/tildaz/issues/409) — 이름 정규화. **Linux
/// (`font/linux/font.zig`) · macOS (`font/macos/font.zig`) 의 `normalizeFamily` 와 같은 규칙**
/// 이어야 세 platform 이 같은 이름을 받아 준다: 소문자로 바꾸고 공백 · `-` · `_` 를 뺀다.
///
/// 저쪽 둘은 UTF-8 byte 위에서 돌고 여기는 UTF-16 unit 위에서 돈다. 소문자 변환을 **ASCII 로만**
/// 하는 것도 같다 — 한국어 family 이름 (`맑은 고딕`) 은 대소문자가 없어서 그대로 통과하고,
/// 로케일별 대소문자 규칙에 판정이 흔들리지 않는다.
fn normalizeFamilyW(name: []const WCHAR, buf: []WCHAR) []const WCHAR {
    var n: usize = 0;
    for (name) |c| {
        if (c == ' ' or c == '-' or c == '_') continue;
        if (n >= buf.len) break;
        buf[n] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        n += 1;
    }
    return buf[0..n];
}

fn normalizedEqlW(a: []const WCHAR, b: []const WCHAR) bool {
    var buf_a: [128]WCHAR = undefined;
    var buf_b: [128]WCHAR = undefined;
    return std.mem.eql(WCHAR, normalizeFamilyW(a, &buf_a), normalizeFamilyW(b, &buf_b));
}

test "normalized family match accepts the spellings a font tool shows" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;

    // #409 ② 가 받아야 하는 것들 — 실측에서 `FindFamilyName` 이 전부 거절한 표기다.
    try std.testing.expect(normalizedEqlW(L("CascadiaCode"), L("Cascadia Code")));
    try std.testing.expect(normalizedEqlW(L("Cascadia-Code"), L("Cascadia Code")));
    try std.testing.expect(normalizedEqlW(L("cascadia_code"), L("Cascadia Code")));
    try std.testing.expect(normalizedEqlW(L("MalgunGothic"), L("Malgun Gothic")));
    // 한국어 이름은 대소문자가 없고 공백만 빠진다 — `맑은고딕` 과 `맑은 고딕`.
    try std.testing.expect(normalizedEqlW(L("맑은고딕"), L("맑은 고딕")));

    // 다른 폰트를 같은 것으로 보면 안 된다.
    try std.testing.expect(!normalizedEqlW(L("Cascadia Code"), L("Cascadia Mono")));
    try std.testing.expect(!normalizedEqlW(L("Consolas"), L("Consola")));
}

test "the normalization is not a substitute for a PostScript lookup" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;

    // PostScript 이름은 정규화해도 family 와 같아지지 않는다 — 그래서 ③ 이 따로 필요하다.
    // 실측한 실제 이름이다 (Cascadia 는 roman 계열과 italic 계열의 표기가 서로 다르다).
    try std.testing.expect(!normalizedEqlW(L("CascadiaCodeRoman"), L("Cascadia Code")));
    try std.testing.expect(!normalizedEqlW(L("CascadiaCodeRoman-Bold"), L("Cascadia Code")));
    try std.testing.expect(!normalizedEqlW(L("Cascadia-Code-Italic"), L("Cascadia Code")));
    try std.testing.expect(!normalizedEqlW(L("Consolas-Bold"), L("Consolas")));

    // 반대로 `MalgunGothic` 은 PostScript 이름이면서 동시에 붙여쓴 family 이기도 하다.
    // family 공간을 먼저 보는 순서 (② 가 ③ 보다 앞) 라서 이 이름은 ② 에서 잡힌다.
    try std.testing.expect(normalizedEqlW(L("MalgunGothic"), L("Malgun Gothic")));
}

/// #409 — `font.family` 에 적은 이름 하나를 해석한 결과. **face 단위**다 — PostScript 이름은
/// family 가 아니라 face 를 가리키기 때문이다 (`CascadiaCodeRoman-Bold`).
pub const Resolved = struct {
    /// 그 이름이 가리키는 face. **caller 가 소유한다.**
    face: *dw.IDWriteFontFace,
    /// 변종 (bold / italic) 을 조회할 family. **caller 가 소유한다.** face 가 시스템 컬렉션에
    /// 없으면 `null` 이고, 그때는 변종 없이 regular 만 쓴다.
    family: ?*dw.IDWriteFontFamily = null,
    how: How,
    /// 해석된 **정식 family 이름** (null 종결). `MapCharacters` 의 base family 힌트와 로그가
    /// 사용자 원문 대신 이 값을 쓴다. family 를 못 얻었으면 길이 0 이다.
    family_name: [64]WCHAR = undefined,
    family_name_len: u32 = 0,

    pub const How = enum {
        /// 적은 그대로 family 로 잡혔다.
        family,
        /// 정규화가 같은 family 를 설치 목록에서 찾았다 — `CascadiaCode` · `맑은고딕`.
        respelled,
        /// family 가 아니라 **PostScript 이름**으로 잡았다 — `CascadiaCodeRoman-Bold`.
        postscript,
    };

    pub fn familyName(self: *const Resolved) []const WCHAR {
        return self.family_name[0..self.family_name_len];
    }

    /// face 는 계속 쓰고 family 만 놓을 때 (chain 로드 경로).
    pub fn releaseFamily(self: *const Resolved) void {
        if (self.family) |f| _ = f.Release();
    }

    /// face 까지 전부 놓을 때 (검증 · 측정 경로).
    pub fn deinit(self: *const Resolved) void {
        _ = self.face.vtable.Release(self.face);
        self.releaseFamily();
    }
};

/// `IDWriteLocalizedStrings` 의 `index` 번째 문자열. buffer 를 넘치면 `null` — config 에 적을
/// 만한 폰트 이름이 그렇게 길 수 없다.
fn localizedString(strings: *dw.IDWriteLocalizedStrings, index: dw.UINT32, buf: []WCHAR) ?[]const WCHAR {
    var len: dw.UINT32 = 0;
    if (strings.GetStringLength(index, &len) < 0) return null;
    if (len == 0 or len + 1 > buf.len) return null;
    if (strings.GetString(index, buf.ptr, len + 1) < 0) return null;
    return buf[0..len];
}

/// [#584](https://github.com/ensky0/tildaz/issues/584) — 폰트의 **PostScript 이름 id**
/// (`atlas_common.fontId`). cluster 키가 폰트를 이것으로 식별한다.
///
/// **왜 family 이름이 아닌가.** `Cascadia Code` 는 regular 와 bold 의 family 가 같아서, family
/// 로 묶으면 굵기가 다른 그림이 한 칸을 나눠 쓴다 ([#529](https://github.com/ensky0/tildaz/issues/529)).
/// 세 platform 이 같은 이유로 PostScript 이름을 쓴다.
///
/// 이름을 못 읽으면 0 이다. 그러면 이름 없는 폰트끼리 한 id 로 모여 그림이 섞일 수 있지만,
/// **주소를 쓰던 때처럼 atlas 를 부풀리지는 않는다** — macOS 판과 같은 판단이다.
fn postscriptNameId(font: *dw.IDWriteFont) u64 {
    var strings: ?*dw.IDWriteLocalizedStrings = null;
    var exists: BOOL = .FALSE;
    if (font.GetInformationalStrings(dw.DWRITE_INFORMATIONAL_STRING_POSTSCRIPT_NAME, &strings, &exists) < 0) return 0;
    const ss = strings orelse return 0;
    defer _ = ss.Release();
    if (exists == .FALSE) return 0;

    var w_buf: [128]WCHAR = undefined;
    const name_w = localizedString(ss, 0, &w_buf) orelse return 0;
    var u8_buf: [256]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&u8_buf, name_w) catch return 0;
    if (len == 0) return 0;
    return withSimulations(atlas_common.fontId(u8_buf[0..len]), font.GetSimulations());
}

/// #749 — DirectWrite 가 **합성한 변종**은 regular 와 PostScript 이름이 같다. 맑은 고딕에는
/// italic 파일이 없어서 `GetFirstMatchingFont(italic)` 이 regular 를 비스듬히 합성한 font
/// (`DWRITE_FONT_SIMULATIONS_OBLIQUE`) 를 주는데, 이름만으로 id 를 만들면 같은 글리프 번호의
/// 똑바른 그림과 기울인 그림이 atlas 한 칸을 나눠 쓴다 (실측: regular · italic 둘 다
/// `7af3d9b85a9464a3`). 그래서 합성 비트를 id 에 섞는다. 합성이 없으면 값이 그대로라
/// 기존 id 는 바뀌지 않는다.
fn withSimulations(id: u64, simulations: u32) u64 {
    if (id == 0 or simulations == dw.DWRITE_FONT_SIMULATIONS_NONE) return id;
    var h = id;
    for ([_]u8{ '+', 's', 'i', 'm', @truncate(simulations) }) |b| {
        h ^= @as(u64, b);
        h *%= 0x100000001b3;
    }
    return h;
}

/// #759 — 같은 글꼴 파일로 **기울임 합성만 뺀** face 를 만든다. 굵기 합성 (`BOLD`) 은 남긴다 —
/// DirectWrite 는 굵기 양을 바꿀 수 없어서 그 값 (em/50) 이 곧 세 OS 공통 값이다
/// ([`synthetic`](../synthetic.zig)). 실패하면 `null`.
fn withoutObliqueSimulation(factory: *dw.IDWriteFactory, face: *dw.IDWriteFontFace) ?*dw.IDWriteFontFace {
    var buf: [8]?*dw.IUnknown = @splat(null);
    const files = face.GetFiles(&buf) orelse return null;
    defer {
        for (files) |f| {
            if (f) |ff| _ = ff.Release();
        }
    }
    const sims = face.GetSimulations() & ~dw.DWRITE_FONT_SIMULATIONS_OBLIQUE;
    var out: ?*dw.IDWriteFontFace = null;
    if (factory.CreateFontFace(face.GetType(), files, face.GetIndex(), sims, &out) < 0) return null;
    return out;
}

test "withSimulations — 합성 변종은 regular 와 갈리고, 합성이 없으면 그대로다 (#749)" {
    const base = atlas_common.fontId("MalgunGothic");
    try std.testing.expectEqual(base, withSimulations(base, dw.DWRITE_FONT_SIMULATIONS_NONE));
    const bold = withSimulations(base, 1);
    const oblique = withSimulations(base, 2);
    const both = withSimulations(base, 3);
    try std.testing.expect(bold != base and oblique != base and both != base);
    try std.testing.expect(bold != oblique and oblique != both and bold != both);
    // 이름을 못 읽은 0 은 0 으로 둔다 — "모름" 을 다른 값으로 바꾸지 않는다.
    try std.testing.expectEqual(@as(u64, 0), withSimulations(0, 2));
}

test "#771 VS16 은 컬러 · VS15 는 흑백 글리프로, 기본이 이모지인 글자는 컬러를 먼저 고른다" {
    // Windows 10 · 11 에 늘 있는 글꼴만 쓴다. 없거나 색 판정을 못 하면 건너뛴다.
    const W = std.unicode.utf8ToUtf16LeStringLiteral;
    const chain = [_][*:0]const WCHAR{ W("Consolas"), W("Segoe UI Emoji"), W("Segoe UI Symbol") };
    const spec = font_spec.Spec{ .size_logical = 20, .cell_width_ratio = 1.0, .line_height_ratio = 1.0 };
    var ctx = DWriteFontContext.init(std.testing.allocator, &chain, spec, 11, 23) catch return error.SkipZigTest;
    defer ctx.deinit();
    if (ctx.factory4 == null or ctx.chain_count != chain.len) return error.SkipZigTest;

    // `☺` 는 chain 첫 글꼴 Consolas 가 흑백 글리프로 가진다. VS16 이면 그것을 건너뛰어야 한다.
    const smile16 = ctx.resolveGrapheme(&.{ 0x263A, presentation.VS16 }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Presentation.emoji, ctx.glyphPresentation(smile16.face, smile16.indices[0..smile16.count]).?);
    // VS15 는 흑백 — Segoe UI Emoji 로 가던 글자 (`☔`) 도 흑백 글꼴을 찾는다.
    for ([_]u21{ 0x263A, 0x2614 }) |cp| {
        const r = ctx.resolveGrapheme(&.{ cp, presentation.VS15 }) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(Presentation.text, ctx.glyphPresentation(r.face, r.indices[0..r.count]).?);
    }
    // 선택자 없는 `☺` 는 요청이 없다 — 예전처럼 chain 첫 글꼴이다.
    const plain = ctx.resolveGlyph(0x263A, .regular) orelse return error.TestUnexpectedResult;
    try std.testing.expect(plain.face == ctx.chain_faces[0].?);
    // 기본이 이모지인 `☔` 는 컬러다. 두 번째는 `emoji_glyph` 캐시에서 같은 답이 나온다.
    for (0..2) |_| {
        const g = ctx.resolveGlyph(0x2614, .regular) orelse return error.TestUnexpectedResult;
        const idx = [1]u16{g.index};
        try std.testing.expectEqual(Presentation.emoji, ctx.glyphPresentation(g.face, &idx).?);
    }
}

/// #584 — face 에서 `postscriptNameId` 를 얻는다. face 가 시스템 컬렉션에 없으면 0 이다.
///
/// **chain face 에만 쓴다** (init 에서 한 번). system fallback 은 `IDWriteFont` 를 이미 손에
/// 들고 있어서 이 왕복이 필요 없다.
fn faceFontId(collection: *dw.IDWriteFontCollection, face: *dw.IDWriteFontFace) u64 {
    var font: ?*dw.IDWriteFont = null;
    if (collection.GetFontFromFontFace(face, &font) < 0) return 0;
    const fo = font orelse return 0;
    defer _ = fo.Release();
    return postscriptNameId(fo);
}

/// family 의 정식 표기를 `out` 에 담고 길이를 돌려준다.
///
/// 이름이 여럿일 때 `[0]` 을 쓴다 (로케일마다 다른 이름이 있다 — `Malgun Gothic` / `맑은 고딕`).
/// 실측에서 `[0]` 과 로케일 이름 **둘 다** `FindFamilyName` 으로 왕복했고 (91/91), `[0]` 은
/// 로케일에 흔들리지 않아 로그와 `MapCharacters` 힌트에 쓰기 좋다.
fn copyFamilyName(family: *dw.IDWriteFontFamily, out: *[64]WCHAR) u32 {
    var names: ?*dw.IDWriteLocalizedStrings = null;
    if (family.GetFamilyNames(&names) < 0) return 0;
    const ns = names orelse return 0;
    defer _ = ns.Release();

    var buf: [128]WCHAR = undefined;
    const name = localizedString(ns, 0, &buf) orelse return 0;
    const n = @min(name.len, out.len - 1);
    @memcpy(out[0..n], name[0..n]);
    out[n] = 0;
    return @intCast(n);
}

/// family `index` 의 이름들 (로케일마다 하나씩) 중 정규화가 `wanted` 와 같은 것이 있는지.
fn familyHasName(collection: *dw.IDWriteFontCollection, index: dw.UINT32, wanted: []const WCHAR) bool {
    var family: ?*dw.IDWriteFontFamily = null;
    if (collection.GetFontFamily(index, &family) < 0) return false;
    const fam = family orelse return false;
    defer _ = fam.Release();

    var names: ?*dw.IDWriteLocalizedStrings = null;
    if (fam.GetFamilyNames(&names) < 0) return false;
    const ns = names orelse return false;
    defer _ = ns.Release();

    var buf: [128]WCHAR = undefined;
    const n = ns.GetCount();
    var k: dw.UINT32 = 0;
    while (k < n) : (k += 1) {
        const name = localizedString(ns, k, &buf) orelse continue;
        if (normalizedEqlW(wanted, name)) return true;
    }
    return false;
}

/// family 하나에서 regular face 를 열어 `Resolved` 를 만든다 (① · ② 공용).
fn resolvedFromFamilyIndex(collection: *dw.IDWriteFontCollection, index: dw.UINT32, how: Resolved.How) !Resolved {
    var family: ?*dw.IDWriteFontFamily = null;
    if (collection.GetFontFamily(index, &family) < 0) return error.FontFamilyFailed;
    const fam = family orelse return error.FontFamilyFailed;
    errdefer _ = fam.Release();

    var font: ?*dw.IDWriteFont = null;
    if (fam.GetFirstMatchingFont(
        dw.DWRITE_FONT_WEIGHT_NORMAL,
        dw.DWRITE_FONT_STRETCH_NORMAL,
        dw.DWRITE_FONT_STYLE_NORMAL,
        &font,
    ) < 0) return error.FontMatchFailed;
    const f = font orelse return error.FontMatchFailed;
    defer _ = f.Release();

    var face: ?*dw.IDWriteFontFace = null;
    if (f.CreateFontFace(&face) < 0) return error.FontFaceFailed;
    const fc = face orelse return error.FontFaceFailed;

    var out = Resolved{ .face = fc, .family = fam, .how = how };
    out.family_name_len = copyFamilyName(fam, &out.family_name);
    return out;
}

/// ③ — `IDWriteFontSet` 으로 **PostScript 이름** 조회 (#409).
///
/// `IDWriteFactory3` 를 못 얻는 환경에서는 `null` 을 돌려 ① ② 만으로 판정한다. 그 경우에도
/// 붙여쓰기 (`CascadiaCode`) 는 ② 가 받아 주므로 기능이 통째로 사라지지는 않는다 — 컬렉션
/// 열거는 DirectWrite 1.0 이라서다.
fn resolveByPostScript(
    factory: *dw.IDWriteFactory,
    collection: *dw.IDWriteFontCollection,
    requested: [*:0]const WCHAR,
) ?Resolved {
    var f3_raw: ?*anyopaque = null;
    if (factory.QueryInterface(&dw.IID_IDWriteFactory3, &f3_raw) < 0) return null;
    const f3: *dw.IDWriteFactory3 = @ptrCast(@alignCast(f3_raw orelse return null));
    defer _ = f3.Release();

    var set: ?*dw.IDWriteFontSet = null;
    if (f3.GetSystemFontSet(&set) < 0) return null;
    const s = set orelse return null;
    defer _ = s.Release();

    // locale 을 빈 문자열로 두면 모든 로케일의 값에서 찾는다.
    const props = [_]dw.DWRITE_FONT_PROPERTY{.{
        .propertyId = dw.DWRITE_FONT_PROPERTY_ID_POSTSCRIPT_NAME,
        .propertyValue = requested,
        .localeName = std.unicode.utf8ToUtf16LeStringLiteral(""),
    }};
    var filtered: ?*dw.IDWriteFontSet = null;
    if (s.GetMatchingFonts(&props, props.len, &filtered) < 0) return null;
    const fs = filtered orelse return null;
    defer _ = fs.Release();
    // 없는 이름이면 빈 set 이다 — fontconfig 와 달리 최선 폰트를 끼워 주지 않으므로 (실측)
    // 돌아온 이름을 되짚어 검증할 필요가 없다.
    if (fs.GetFontCount() == 0) return null;

    var ref: ?*dw.IDWriteFontFaceReference = null;
    if (fs.GetFontFaceReference(0, &ref) < 0) return null;
    const r = ref orelse return null;
    defer _ = r.Release();

    var face: ?*dw.IDWriteFontFace = null;
    if (r.CreateFontFace(&face) < 0) return null;
    const fc = face orelse return null;

    var out = Resolved{ .face = fc, .how = .postscript };

    // 변종 (bold / italic) 조회용 family 를 face 로부터 되찾는다. **이 단계가 빠지면 SGR 1 · 3
    // 이 죽는다** — PostScript 로 잡은 face 에는 `IDWriteFontFamily` 가 딸려 오지 않는다.
    // Linux 에서 이 지점이 실제 구멍이었다 (`DejaVuSansMono-Bold` 의 bold 조회가 무관한
    // `NotoSansCJK-Bold.ttc` 로 갔다). face 가 시스템 컬렉션에 없으면 `null` 로 남고 변종 없이
    // regular 만 쓴다.
    var font: ?*dw.IDWriteFont = null;
    if (collection.GetFontFromFontFace(fc, &font) >= 0) {
        if (font) |fo| {
            defer _ = fo.Release();
            var family: ?*dw.IDWriteFontFamily = null;
            if (fo.GetFontFamily(&family) >= 0) {
                if (family) |fam| {
                    out.family = fam;
                    out.family_name_len = copyFamilyName(fam, &out.family_name);
                }
            }
        }
    }
    return out;
}

/// #409 — 사용자가 적은 이름 **하나를 face 하나로** 해석하는 단일 진입점.
///
/// boot 검증 (`isFontAvailable`) · cell 측정 (`measureCell`) · 실제 로드
/// (`DWriteFontContext.init`) 셋이 이 함수를 공유한다. 전에는 셋이 각자 `FindFamilyName` 을
/// 불렀는데, 그러면 한쪽만 통과했을 때 **검증을 지나고도 다른 폰트가 조용히 그려질 수 있다.**
/// Linux 의 `resolveRequested` 와 같은 형태다.
///
/// 해석 순서는 **family 공간이 먼저, PostScript 가 마지막**으로 세 platform 이 같다.
///
///   ① 적은 이름 그대로 family 조회 → `.family`
///   ② 설치된 family 목록에 정규화가 같은 이름이 있으면 그 family → `.respelled`
///   ③ PostScript 이름으로 face 조회 → `.postscript`
///   ④ 셋 다 아니면 `error.FontNotFound` — 오타 · 미설치다
///
/// **Linux 의 `.alias` 에 해당하는 단계는 없다.** fontconfig 처럼 이름을 다른 폰트로 바꿔치기하는
/// 시스템 규칙이 Windows 에는 없어서 (`FindFamilyName` 은 시스템 컬렉션 exact match) 대체가
/// 개입할 여지가 없다 — `font/validate.zig` 이 Windows 의 `substitute` 를 `null` 로 두는 것과
/// 같은 이유다.
pub fn resolveFamily(
    factory: *dw.IDWriteFactory,
    collection: *dw.IDWriteFontCollection,
    requested: [*:0]const WCHAR,
) !Resolved {
    // ① 적은 이름 그대로. 대소문자는 `FindFamilyName` 이 이미 무시한다.
    var family_index: dw.UINT32 = 0;
    var exists: BOOL = .FALSE;
    if (collection.FindFamilyName(requested, &family_index, &exists) >= 0 and exists.toBool())
        return resolvedFromFamilyIndex(collection, family_index, .family);

    // ② 설치 목록의 정식 표기. `CascadiaCode` (붙여쓰기) · `Cascadia-Code` · `맑은고딕` 이
    //    여기서 잡힌다. **PostScript 조회로는 안 잡히므로 이 단계가 꼭 필요하다** — 실측에서
    //    `GetMatchingFonts(WIN32_FAMILY_NAME, "CascadiaCode")` 도 0 개였다.
    const wanted = std.mem.span(requested);
    const count = collection.GetFontFamilyCount();
    var i: dw.UINT32 = 0;
    while (i < count) : (i += 1) {
        if (familyHasName(collection, i, wanted))
            return resolvedFromFamilyIndex(collection, i, .respelled);
    }

    // ③ PostScript 이름.
    if (resolveByPostScript(factory, collection, requested)) |r| return r;

    // ④ 오타 · 미설치. 비슷한 이름으로 넘겨짚지 않는다. 무엇으로 띄울지는 `Config.resolveFonts`
    //    가 정하고 시작 안내로 알린다 (#758) — 조용히 다른 폰트로 띄우면 사용자가 이름을 잘못
    //    적은 것을 영영 모른다.
    return error.FontNotFound;
}

/// #409 — 적은 그대로 잡히지 **않은** entry 만 무엇으로 어떻게 잡혔는지 남긴다. 사용자가
/// 나중에 "왜 다른 폰트로 보이지" 를 추적하는 근거다.
///
/// **문구는 Linux (`font/linux/font.zig` 의 `tryLoadFamily`) 와 글자까지 같다** — 같은 상황을
/// platform 마다 다르게 적으면 사용자가 이슈에 붙인 로그를 읽는 쪽이 두 벌을 알아야 하고,
/// CONFIG.md 가 그 문구를 그대로 인용하고 있다. 로그는 공유되는 진단 자료라 인자까지 영어다.
fn logChainEntry(index: u8, requested: [*:0]const WCHAR, resolved: Resolved) void {
    if (resolved.how == .family) return;

    var req_buf: [256]u8 = undefined;
    var fam_buf: [256]u8 = undefined;
    const req_len = std.unicode.utf16LeToUtf8(&req_buf, std.mem.span(requested)) catch 0;
    const fam_len = std.unicode.utf16LeToUtf8(&fam_buf, resolved.familyName()) catch 0;
    const req = req_buf[0..req_len];
    const fam = fam_buf[0..fam_len];

    switch (resolved.how) {
        .family => unreachable,
        .respelled => log.appendLine("font", "chain[{d}] \"{s}\" matched installed family \"{s}\" — using it", .{ index, req, fam }),
        .postscript => log.appendLine("font", "chain[{d}] \"{s}\" matched the PostScript name of family \"{s}\" — using it", .{ index, req, fam }),
    }
}

/// 정공 cell metric — DWrite design metric (ascent/descent/lineGap/advance) 으로
/// 직접 산출. GDI tm 의 rounding / leading 영향 배제. 여기서는 실수 측정값을
/// 그대로 반환하고 호출처가 ratio 까지 적용한 뒤 공통 정책으로 한 번만 ceil 한다.
///
/// font_height_px = 우리가 raster 할 em-size (#148 B-2 후 = 사용자 font.size ×
/// DPI scale). monospace 폰트의 모든 glyph 가 같은 advance 라 '0' 의 advance 를
/// cell_w 로 사용. cell_h = ascent + descent + lineGap (DWrite design 기반).
///
/// 임시 IDWriteFactory 한 번 만들어 측정 후 release. renderer 의 DWriteFontContext
/// 도 자체 factory 를 따로 만듦 (lifetime 분리). DWrite factory 생성은 가벼워서
/// 부담 없음.
pub fn measureCell(
    primary_family_w: [*:0]const WCHAR,
    font_height_px: f32,
) !struct { cell_w: f32, cell_h: f32 } {
    var factory: ?*dw.IDWriteFactory = null;
    if (dw.DWriteCreateFactory(dw.DWRITE_FACTORY_TYPE_SHARED, &dw.IID_IDWriteFactory, @ptrCast(&factory)) < 0)
        return error.DWriteFactoryFailed;
    defer _ = factory.?.vtable.Release(factory.?);

    var collection: ?*dw.IDWriteFontCollection = null;
    if (factory.?.GetSystemFontCollection(&collection, .FALSE) < 0) return error.FontCollectionFailed;
    defer _ = collection.?.vtable.Release(collection.?);

    // #409 — 실제 로드 (`DWriteFontContext.init`) 와 **같은 해석 함수**를 쓴다. 여기가 따로
    // `FindFamilyName` 을 부르면 `CascadiaCodeRoman` 처럼 chain 은 열리는 이름에서 cell 측정만
    // 실패해, 호출처가 GDI fallback (원문을 그대로 `CreateFontW` 에 넘겨 **조용히 대체되는**
    // 경로) 으로 떨어진다.
    const resolved = try resolveFamily(factory.?, collection.?, primary_family_w);
    defer resolved.deinit();
    const face = resolved.face;

    var metrics: dw.DWRITE_FONT_METRICS = undefined;
    face.GetMetrics(&metrics);
    const em: f32 = @floatFromInt(metrics.designUnitsPerEm);
    const asc: f32 = @floatFromInt(metrics.ascent);
    const desc: f32 = @floatFromInt(metrics.descent);
    const linegap: f32 = @floatFromInt(metrics.lineGap);

    var glyph_idx: dw.UINT16 = 0;
    const cp: dw.UINT32 = '0';
    if (face.GetGlyphIndices(@ptrCast(&cp), 1, @ptrCast(&glyph_idx)) < 0)
        return error.GlyphIndexFailed;

    var glyph_metrics: dw.DWRITE_GLYPH_METRICS = undefined;
    if (face.GetDesignGlyphMetrics(@ptrCast(&glyph_idx), 1, @ptrCast(&glyph_metrics), .FALSE) < 0)
        return error.GlyphMetricsFailed;
    const advance: f32 = @floatFromInt(glyph_metrics.advanceWidth);

    const cell_w_px = font_height_px * advance / em;
    const cell_h_px = font_height_px * (asc + desc + linegap) / em;

    return .{
        .cell_w = cell_w_px,
        .cell_h = cell_h_px,
    };
}

pub const DWriteFontContext = struct {
    alloc: std.mem.Allocator,
    factory: *dw.IDWriteFactory,
    factory2: ?*dw.IDWriteFactory2 = null,
    /// [#771](https://github.com/ensky0/tildaz/issues/771) — 글리프가 컬러인지 판정한다
    /// (`glyphPresentation`). 렌더러 (`glyph_atlas.zig`) 와 같은 `TranslateColorGlyphRun`
    /// (모든 글리프 형식) 이라 "컬러로 골랐다" 와 "컬러로 그린다" 가 갈리지 않는다. 없으면
    /// (Windows 10 1607 이전) 모양 판정을 건너뛰고 예전처럼 고른다.
    factory4: ?*dw.IDWriteFactory4 = null,
    font_collection: *dw.IDWriteFontCollection,
    font_fallback: ?*dw.IDWriteFontFallback = null,
    /// Grapheme cluster shaping (#134) — VS-16 / skin tone modifier / ZWJ
    /// 시퀀스를 OpenType GSUB 로 단일 cluster glyph 로 reduce. macOS 의 CTLine
    /// 동등.
    text_analyzer: ?*dw.IDWriteTextAnalyzer = null,
    /// [#416](https://github.com/ensky0/tildaz/issues/416) — `GetScriptProperties` 하나를
    /// 쓰려고 QueryInterface 해 둔 것. 없으면 (DirectWrite 1.0) script 를 그대로 쓴다.
    text_analyzer1: ?*dw.IDWriteTextAnalyzer1 = null,
    /// font.family chain — `[0]` 이 primary (cell metric / MapCharacters 의 base).
    /// chain entry 마다 IDWriteFontFace 보관, resolveGlyph 가 codepoint 별로
    /// 순회해서 글리프 가진 첫 face 반환. 모든 face 는 process 전체 lifetime
    /// 안정 (deinit 까지 Release 안 함) — atlas cache key 가 face 포인터라
    /// 안정성 필수.
    chain_faces: [MAX_CHAIN]?*dw.IDWriteFontFace = @splat(null),
    /// #584 — chain face 의 `atlas_common.fontId`. **init 에서 한 번만 구한다** — 이름 조회가
    /// COM 왕복 셋 (`GetFontFromFontFace` → `GetInformationalStrings` → `GetString`) 이라
    /// cluster 마다 부를 수 없다. chain face 는 process lifetime 동안 안 바뀌므로 캐시가 맞다.
    chain_font_id: [MAX_CHAIN]u64 = @splat(0),
    /// #584 — `styled_faces` 의 폰트 id. 변종은 PostScript 이름이 달라 (`Cascadia Code Bold`
    /// vs `Cascadia Code`) id 도 갈린다 — 그래야 굵기가 다른 그림이 한 칸을 안 나눠 쓴다 (#529).
    styled_font_id: [font_constants.FaceStyle.count - 1][MAX_CHAIN]u64 =
        @splat(@splat(0)),
    /// #375 — bold · italic · bold_italic chain. regular 는 위 `chain_faces` 가
    /// 담당하므로 3 벌만 둔다 (`FaceStyle.index() - 1` 로 색인).
    ///
    /// `GetFirstMatchingFont` 은 **요청과 가장 근접한 face** 를 돌려주므로 (실패하지
    /// 않는다) bold face 가 없는 family 는 자연히 regular 가 들어온다 — "없으면
    /// regular" 를 우리가 따로 판정하지 않아도 된다.
    styled_faces: [font_constants.FaceStyle.count - 1][MAX_CHAIN]?*dw.IDWriteFontFace =
        @splat(@splat(null)),
    /// #759 — `styled_faces` 를 그릴 때 우리가 기울일지. DirectWrite 가 기울임을 합성한 변종은
    /// 그 합성을 뺀 face 로 바꿔 두고 여기를 `true` 로 한다 (`withoutObliqueSimulation`).
    styled_slant: [font_constants.FaceStyle.count - 1][MAX_CHAIN]bool =
        @splat(@splat(false)),
    chain_count: u8 = 0,
    rendering_params: ?*dw.IDWriteRenderingParams = null,
    number_sub: ?*dw.IUnknown = null,
    primary_family_name: [64]WCHAR = undefined,
    primary_family_len: u32 = 0,
    font_em_size: f32 = 0,
    ascent_px: f32 = 0,
    descent_px: f32 = 0,
    cell_width_px: u32,
    cell_height_px: u32,
    // Caches (codepoint → face/index). Keeps fallback faces alive so atlas
    // cache keys — which use the face pointer — remain stable.
    glyph_map: std.AutoHashMap(u21, CachedGlyph),
    /// [#771](https://github.com/ensky0/tildaz/issues/771) — 기본이 이모지인 단일 글자의 **chain 안
    /// 컬러 글리프**. `null` 은 "chain 에 컬러 글리프가 없다" 다 (그때는 예전 길로 간다).
    /// `resolveGlyph` 가 매 프레임 · 셀마다 불리므로 판정 (`TranslateColorGlyphRun`) 을 글자당 한
    /// 번으로 줄인다. 담는 face 는 chain face 라 **해제하지 않는다** — `glyph_map` 은 system
    /// fallback face 를 담아 `deinit` 이 해제하므로 둘을 섞지 않는다.
    emoji_glyph: std.AutoHashMap(u21, ?CachedGlyph),
    /// pair/triple lookahead cache. 세 backend 공통 key + positive/negative 저장.
    ligature_cache: ligature.Cache,
    /// #399 (B) — grapheme cluster shaping 결과 cache. 세 platform 공용 모듈이고 값만
    /// platform 별이다.
    ///
    /// **Windows 값에는 소유권이 있다** (Linux 의 face index 와 다른 점이다). 그래서
    /// `release` 를 주입하고, 캐시가 소유권을 가져간 뒤 caller 에게는 `owned = false` 로
    /// 넘긴다 — 안 그러면 셀 루프가 매 프레임 `Release` 해서 캐시 안의 face 가 죽는다.
    ///
    /// negative 도 담는다. chain 이 못 맞춘 cluster 를 안 담으면 매 프레임 chain 전체 +
    /// `MapCharacters` + `CreateFontFace` 를 헛도는데, **Windows 는 그 경로가 가장 비싸다.**
    cluster_cache: cluster_cache.ClusterCache(ClusterResult, releaseCluster),
    /// #416 — base codepoint → `DWRITE_SCRIPT_ANALYSIS`. `AnalyzeScript` 를 cluster 마다
    /// 부르면 shaping 의 hot path (#395 에서 `render` 의 91.5 %) 에 COM 왕복이 하나 더 붙으므로
    /// 캐시한다. **폰트와 무관한 텍스트 속성**이라 face 가 키에 없다.
    script_map: std.AutoHashMap(u21, dw.DWRITE_SCRIPT_ANALYSIS),

    pub fn init(
        alloc: std.mem.Allocator,
        font_chain: []const [*:0]const WCHAR,
        spec: font_spec.Spec,
        cell_w: u32,
        cell_h: u32,
    ) !DWriteFontContext {
        if (font_chain.len == 0) return error.EmptyFontChain;
        // 1. Create DWrite factory
        var factory: ?*dw.IDWriteFactory = null;
        if (dw.DWriteCreateFactory(dw.DWRITE_FACTORY_TYPE_SHARED, &dw.IID_IDWriteFactory, @ptrCast(&factory)) < 0)
            return error.DWriteFactoryFailed;
        errdefer _ = factory.?.vtable.Release(factory.?);

        // 2. Get system font collection
        var collection: ?*dw.IDWriteFontCollection = null;
        if (factory.?.GetSystemFontCollection(&collection, .FALSE) < 0) return error.FontCollectionFailed;
        errdefer _ = collection.?.vtable.Release(collection.?);

        // 3. chain entry 마다 face 생성. caller 가 사전에 없는 폰트를 바꾸거나 뺐지만
        //    (`Config.resolveFonts`, #758) race 방지 위해 여기서도 missing 시 error.
        //    중간 실패 시 errdefer 가 이미 만든 faces 모두 release.
        var chain_faces: [MAX_CHAIN]?*dw.IDWriteFontFace = @splat(null);
        // #584 — chain face 의 PostScript 이름 id. 여기서 한 번만 구한다.
        var chain_font_id: [MAX_CHAIN]u64 = @splat(0);
        var styled_font_id: [font_constants.FaceStyle.count - 1][MAX_CHAIN]u64 =
            @splat(@splat(0));
        var styled_faces: [font_constants.FaceStyle.count - 1][MAX_CHAIN]?*dw.IDWriteFontFace =
            @splat(@splat(null));
        var styled_slant: [font_constants.FaceStyle.count - 1][MAX_CHAIN]bool =
            @splat(@splat(false));
        var chain_count: u8 = 0;
        errdefer {
            for (chain_faces[0..chain_count]) |maybe_face| {
                if (maybe_face) |f| _ = f.vtable.Release(f);
            }
        }

        // #409 — primary 의 **해석된 정식 family 이름**. `MapCharacters` 의 base family 힌트가
        // 사용자 원문 대신 이 값을 쓴다 (아래 참고).
        var primary_canon: [64]WCHAR = undefined;
        var primary_canon_len: u32 = 0;

        const limit = @min(font_chain.len, MAX_CHAIN);
        for (font_chain[0..limit]) |family_w| {
            // #409 — boot 검증 (`isFontAvailable`) · cell 측정 (`measureCell`) 과 **같은 해석
            // 함수**다. 이름이 family 표기가 아니어도 (`CascadiaCode` · `CascadiaCodeRoman-Bold`)
            // 여기서 face 로 풀린다.
            const resolved = try resolveFamily(factory.?, collection.?, family_w);
            // family 는 변종 조회에만 쓰고 여기서 놓는다. face 는 context 가 계속 들고 있는다.
            defer resolved.releaseFamily();

            chain_faces[chain_count] = resolved.face;
            chain_font_id[chain_count] = faceFontId(collection.?, resolved.face);
            if (chain_count == 0) {
                primary_canon = resolved.family_name;
                primary_canon_len = resolved.family_name_len;
            }

            // #375 — 같은 family 의 변종 face. weight / style 인자만 바꾼다.
            //
            // #409 — 조회 키는 **해석된 family** 다. 사용자가 적은 원문으로 조회하면 엉뚱한
            // 폰트의 변종이 온다. PostScript 이름으로 face 를 잡은 경우 family 가 `null` 일 수
            // 있는데 (face 가 시스템 컬렉션에 없을 때), 그때는 변종을 만들지 않고 `chainFor` 가
            // regular 로 떨어뜨린다.
            if (resolved.family) |family_obj| {
                inline for ([_]font_constants.FaceStyle{ .bold, .italic, .bold_italic }) |fs| {
                    var styled_font: ?*dw.IDWriteFont = null;
                    if (family_obj.GetFirstMatchingFont(
                        if (fs.isBold()) dw.DWRITE_FONT_WEIGHT_BOLD else dw.DWRITE_FONT_WEIGHT_NORMAL,
                        dw.DWRITE_FONT_STRETCH_NORMAL,
                        if (fs.isItalic()) dw.DWRITE_FONT_STYLE_ITALIC else dw.DWRITE_FONT_STYLE_NORMAL,
                        &styled_font,
                    ) >= 0) {
                        defer _ = styled_font.?.vtable.Release(styled_font.?);
                        var styled_face: ?*dw.IDWriteFontFace = null;
                        if (styled_font.?.CreateFontFace(&styled_face) >= 0) {
                            // #759 — DirectWrite 가 기울임을 합성했으면 (0.340) 그 합성을 빼고
                            // 그릴 때 세 OS 공통 기울기로 기울인다. 다시 만들지 못하면 DirectWrite
                            // 합성을 그대로 쓴다 — 기울기만 다를 뿐 똑바로 서지는 않는다.
                            if (styled_font.?.GetSimulations() & dw.DWRITE_FONT_SIMULATIONS_OBLIQUE != 0) {
                                if (withoutObliqueSimulation(factory.?, styled_face.?)) |plain| {
                                    _ = styled_face.?.Release();
                                    styled_face = plain;
                                    styled_slant[fs.index() - 1][chain_count] = true;
                                }
                            }
                            styled_faces[fs.index() - 1][chain_count] = styled_face.?;
                            // #584 — `IDWriteFont` 를 손에 든 이 자리에서 id 를 구한다.
                            styled_font_id[fs.index() - 1][chain_count] = postscriptNameId(styled_font.?);
                        }
                    }
                    // 실패하면 null 로 남고 `chainFor` 가 regular face 로 떨어뜨린다.
                }
            }

            // #409 — 어느 이름이 무엇으로 풀렸는지 남긴다. Linux 의 chain 줄 (`chain[i] family=…
            // path=… index=…`) 과 같은 자리로, 사용자가 적은 표기가 의도한 폰트로 갔는지 확인하는
            // 근거가 된다.
            logChainEntry(chain_count, family_w, resolved);

            chain_count += 1;
        }

        const primary_face = chain_faces[0].?;

        var self = DWriteFontContext{
            .alloc = alloc,
            .factory = factory.?,
            .font_collection = collection.?,
            .chain_faces = chain_faces,
            .chain_font_id = chain_font_id,
            .styled_font_id = styled_font_id,
            .styled_faces = styled_faces,
            .styled_slant = styled_slant,
            .chain_count = chain_count,
            .cell_width_px = cell_w,
            .cell_height_px = cell_h,
            .glyph_map = std.AutoHashMap(u21, CachedGlyph).init(alloc),
            .emoji_glyph = std.AutoHashMap(u21, ?CachedGlyph).init(alloc),
            .ligature_cache = ligature.Cache.init(alloc),
            .cluster_cache = cluster_cache.ClusterCache(ClusterResult, releaseCluster).init(alloc),
            .script_map = std.AutoHashMap(u21, dw.DWRITE_SCRIPT_ANALYSIS).init(alloc),
        };

        // Store primary family name for MapCharacters fallback (system 의 fallback
        // chain 이 우리 primary 를 base 로 fallback 결정).
        //
        // #409 — **해석된 정식 family 이름**을 쓴다. 사용자가 적은 원문이 아니다. 원문은
        // `CascadiaCode` (붙여쓰기) 나 `CascadiaCodeRoman` (PostScript 이름) 일 수 있는데,
        // 그것을 `MapCharacters` 의 base family 로 주면 DirectWrite 가 알아보지 못해 fallback
        // 폰트 선택이 어긋난다 — 그 힌트는 *family 이름* 을 받는 자리다.
        //
        // family 를 못 되찾은 경우 (PostScript 로 잡은 face 가 시스템 컬렉션에 없을 때) 만
        // 원문으로 떨어진다. 그때도 힌트일 뿐이라 fallback 품질만 영향받는다.
        const fam: []const WCHAR = if (primary_canon_len > 0)
            primary_canon[0..primary_canon_len]
        else
            std.mem.span(font_chain[0]);
        const fam_n = @min(fam.len, self.primary_family_name.len - 1);
        @memcpy(self.primary_family_name[0..fam_n], fam[0..fam_n]);
        self.primary_family_name[fam_n] = 0;
        self.primary_family_len = @intCast(fam_n);

        // 4. Calculate em size from primary font metrics
        var metrics: dw.DWRITE_FONT_METRICS = undefined;
        primary_face.GetMetrics(&metrics);
        const du_per_em: f32 = @floatFromInt(metrics.designUnitsPerEm);
        const ascent: f32 = @floatFromInt(metrics.ascent);
        const abs_height = spec.size_logical;
        // WT BackendD3D 컨벤션 (#148) — em-size = font.size 픽셀 그대로. DWrite
        // native + 일반적인 fontSize 의미와 정합. 이전 식 (`abs_height * em /
        // (asc+desc)`) 은 GDI CreateFontW(positive) 의 cell-height 컨벤션 을
        // DWrite em 으로 환산한 값 — Cascadia 19pt 에서 em=16.4 로 작아져 emoji
        // 가 WT 보다 14% 작게 raster. ascent_px 는 새 em 기준 비례 — `em *
        // ascent / du_per_em`.
        self.font_em_size = abs_height;
        self.ascent_px = abs_height * ascent / du_per_em;
        self.descent_px = abs_height * @as(f32, @floatFromInt(metrics.descent)) / du_per_em;

        // #197 — primary 1줄 lifecycle (cross-platform 동일 형식). path 는 win
        // system font 라 제외. family 는 UTF-16 → UTF-8 변환.
        var fam_buf: [128]u8 = undefined;
        const fam_len = std.unicode.utf16LeToUtf8(&fam_buf, self.primary_family_name[0..self.primary_family_len]) catch 0;
        log.logPrimaryFont(
            fam_buf[0..fam_len],
            self.cell_width_px,
            self.cell_height_px,
            @as(u32, @round(self.ascent_px)),
            @as(u32, @round(self.descent_px)),
        );

        // 5. Get IDWriteFactory2 for system font fallback
        var factory2: ?*dw.IDWriteFactory2 = null;
        if (factory.?.QueryInterface(&dw.IID_IDWriteFactory2, @ptrCast(&factory2)) >= 0) {
            self.factory2 = factory2;
            var fallback: ?*dw.IDWriteFontFallback = null;
            if (factory2.?.GetSystemFontFallback(&fallback) >= 0) {
                self.font_fallback = fallback;
            }
        }
        // #771 — 글리프 색 판정용 (`glyphPresentation`). 렌더러 (`glyph_atlas.zig`) 와 같은 방법이다.
        {
            var f4_ptr: ?*anyopaque = null;
            if (factory.?.QueryInterface(&dw.IID_IDWriteFactory4, &f4_ptr) >= 0 and f4_ptr != null) {
                self.factory4 = @ptrCast(@alignCast(f4_ptr));
            }
        }

        // 6. Get system rendering params
        {
            var sys_params: ?*dw.IDWriteRenderingParams = null;
            if (factory.?.CreateRenderingParams(&sys_params) >= 0) {
                self.rendering_params = sys_params;
            }
        }

        // 7. Create number substitution (for MapCharacters callback)
        const locale = std.unicode.utf8ToUtf16LeStringLiteral("en-us");
        var number_sub: ?*dw.IUnknown = null;
        _ = factory.?.CreateNumberSubstitution(dw.DWRITE_NUMBER_SUBSTITUTION_METHOD_NONE, locale, .FALSE, &number_sub);
        self.number_sub = number_sub;

        // 8. Create text analyzer (for grapheme cluster shaping — #134).
        var analyzer: ?*dw.IDWriteTextAnalyzer = null;
        _ = factory.?.CreateTextAnalyzer(&analyzer);
        self.text_analyzer = analyzer;

        // 9. IDWriteTextAnalyzer1 — script 특성 조회용 (#416). 실패해도 동작은 이어진다
        //    (`scriptFor` 가 cursive 판정 없이 script 를 그대로 쓴다).
        if (analyzer) |a| {
            var a1: ?*anyopaque = null;
            if (a.QueryInterface(&dw.IID_IDWriteTextAnalyzer1, &a1) >= 0) {
                if (a1) |p| self.text_analyzer1 = @ptrCast(@alignCast(p));
            }
        }

        return self;
    }

    pub fn deinit(self: *DWriteFontContext) void {
        // Release all MapCharacters-resolved faces retained in the glyph cache.
        // Chain faces never enter the cache (skipped at insert time) so no
        // double-release risk.
        var it = self.glyph_map.valueIterator();
        while (it.next()) |v| {
            _ = v.face.vtable.Release(v.face);
        }
        self.glyph_map.deinit();
        // #771 — chain face 만 담으므로 face 는 놓지 않는다 (`emoji_glyph` 주석).
        self.emoji_glyph.deinit();
        self.ligature_cache.deinit();
        self.script_map.deinit();
        // #399 — 담아 둔 `MapCharacters` face 들을 여기서 놓는다 (`releaseCluster`).
        //
        // **따로 `clear()` 를 부를 자리는 없다.** 폰트 · DPI 가 바뀌면 renderer 가
        // `DWriteFontContext.init` 으로 Context 를 새로 만들고 옛 것을 `deinit` 한다
        // (`renderer/windows.zig` 의 `recreateFontResources`) — face 만 갈아 끼우는
        // 경로가 없어서, Linux 의 `freeFaces` 에 해당하는 무효화 지점이 이 자리 하나다.
        self.cluster_cache.deinit();
        if (self.rendering_params) |rp| _ = rp.Release();
        if (self.font_fallback) |fb| _ = fb.vtable.Release(fb);
        if (self.number_sub) |ns| _ = ns.Release();
        if (self.text_analyzer1) |ta1| _ = ta1.Release();
        if (self.text_analyzer) |ta| _ = ta.Release();
        for (self.chain_faces[0..self.chain_count]) |maybe_face| {
            if (maybe_face) |f| _ = f.vtable.Release(f);
        }
        // #375 — 변종 chain. 만들지 못한 칸은 null 이라 건너뛴다.
        for (&self.styled_faces) |*chain| {
            for (chain[0..self.chain_count]) |maybe_face| {
                if (maybe_face) |f| _ = f.vtable.Release(f);
            }
        }
        _ = self.font_collection.vtable.Release(self.font_collection);
        if (self.factory2) |f2| _ = f2.Release();
        if (self.factory4) |f4| dw.factory4Release(f4);
        _ = self.factory.Release();
    }

    /// Resolve a codepoint to (font_face, glyph_index). 우선순위:
    ///   1. cache (이전에 resolve 된 결과)
    ///   2. user font.family chain (config 순서대로 — primary → fallback)
    ///   3. system fallback (DirectWrite IDWriteFontFallback.MapCharacters)
    ///
    /// chain face 는 process lifetime 안정 — atlas cache key (face 포인터) 가
    /// 안정적이라 cache miss 시에도 같은 codepoint → 같은 face. system fallback
    /// 으로 resolve 된 face 만 glyph_map 에 cache 해서 pointer 안정성 유지.
    /// `owned` 는 항상 false — context 가 소유.
    /// #375 — 요청한 변종의 chain. 해당 변종 face 가 없는 칸은 regular 로 떨어뜨린다.
    fn faceAt(self: *const DWriteFontContext, i: usize, style: font_constants.FaceStyle) ?*dw.IDWriteFontFace {
        if (style != .regular) {
            if (self.styled_faces[style.index() - 1][i]) |f| return f;
        }
        return self.chain_faces[i];
    }

    /// #584 — `faceAt` 이 고른 face 의 폰트 id. **같은 갈림을 따라야** 한다 — 변종 face 가
    /// 없어 regular 로 떨어지면 id 도 regular 것이어야 한다.
    fn chainFontId(self: *const DWriteFontContext, i: usize, style: font_constants.FaceStyle) u64 {
        if (style != .regular) {
            if (self.styled_faces[style.index() - 1][i] != null) return self.styled_font_id[style.index() - 1][i];
        }
        return self.chain_font_id[i];
    }

    /// #759 — `faceAt` 이 고른 face 를 그릴 때 기울일지. `chainFontId` 와 같은 갈림을 따른다.
    fn chainSlant(self: *const DWriteFontContext, i: usize, style: font_constants.FaceStyle) bool {
        if (style == .regular) return false;
        if (self.styled_faces[style.index() - 1][i] == null) return false;
        return self.styled_slant[style.index() - 1][i];
    }

    /// [#771](https://github.com/ensky0/tildaz/issues/771) — 글리프 (들) 의 모양. 하나라도 컬러
    /// 레이어가 있으면 `.emoji` 다 — 렌더러가 컬러 경로로 그리는 조건과 같다 (`glyph_atlas.zig`
    /// 의 `TranslateColorGlyphRun` · `DWRITE_GLYPH_IMAGE_FORMATS_ALL`). 흑백이면
    /// `DWRITE_E_NOCOLOR` 가 돌아온다. `factory4` 가 없거나 다른 오류면 `null` 이고 caller 는
    /// 모양 판정을 건너뛴다.
    fn glyphPresentation(self: *const DWriteFontContext, face: *dw.IDWriteFontFace, indices: []const u16) ?Presentation {
        const f4 = self.factory4 orelse return null;
        if (indices.len == 0) return null;
        const run = dw.DWRITE_GLYPH_RUN{
            .fontFace = face,
            .fontEmSize = @max(self.font_em_size, 1.0),
            .glyphCount = @intCast(indices.len),
            .glyphIndices = indices.ptr,
            .glyphAdvances = null,
            .glyphOffsets = null,
            .isSideways = .FALSE,
            .bidiLevel = 0,
        };
        var e: ?*dw.IDWriteColorGlyphRunEnumerator1 = null;
        const hr = dw.factory4TranslateColorGlyphRun(f4, 0, 0, &run, null, dw.DWRITE_GLYPH_IMAGE_FORMATS_ALL, dw.DWRITE_MEASURING_MODE_NATURAL, null, 0, &e);
        if (hr >= 0) {
            const en = e orelse return null;
            _ = en.Release();
            return .emoji;
        }
        if (hr == dw.DWRITE_E_NOCOLOR) return .text;
        return null;
    }

    /// #771 — 기본이 이모지인 글자의 chain 안 컬러 글리프. 결과 (없음 포함) 는 `emoji_glyph` 에
    /// 담아 판정을 글자당 한 번으로 줄인다. regular chain 만 본다 — 컬러 emoji 에 굵기는 의미가
    /// 없다 (`resolveGlyph` 주석과 같다).
    fn chainEmojiGlyph(self: *DWriteFontContext, codepoint: u21) ?CachedGlyph {
        if (self.emoji_glyph.get(codepoint)) |cached| return cached;
        const found: ?CachedGlyph = blk: {
            const cp32: dw.UINT32 = codepoint;
            for (self.chain_faces[0..self.chain_count], 0..) |maybe_face, i| {
                const face = maybe_face orelse continue;
                var glyph_index: dw.UINT16 = 0;
                _ = face.GetGlyphIndices(@ptrCast(&cp32), 1, @ptrCast(&glyph_index));
                if (glyph_index == 0) continue;
                const idx = [1]u16{glyph_index};
                if (self.glyphPresentation(face, &idx) == .emoji) {
                    break :blk .{ .face = face, .index = glyph_index, .font_id = self.chain_font_id[i] };
                }
            }
            break :blk null;
        };
        self.emoji_glyph.put(codepoint, found) catch {};
        return found;
    }

    /// `style` (#375) 은 SGR `1` · `3` 이 요구하는 face 변종이다. chain 순회만 이
    /// 값을 따르고, system fallback (`MapCharacters`) 경로와 grapheme · ligature 는
    /// regular 를 쓴다 — 컬러 emoji 에 굵기는 의미가 없다.
    pub fn resolveGlyph(self: *DWriteFontContext, codepoint: u21, style: font_constants.FaceStyle) ?GlyphResult {
        // 캐시는 **chain 밖** cp 의 system fallback 결과만 담는다 (chain 히트는 아래에서
        // 바로 반환하고 캐시에 넣지 않는다) — 그래서 변종이 캐시와 충돌하지 않는다.
        if (self.glyph_map.get(codepoint)) |c| {
            return .{ .face = c.face, .index = c.index, .owned = false, .font_id = c.font_id };
        }

        // #771 — 기본 모양이 이모지인 글자 (`presentation.isEmojiPresentation`) 는 chain 에서
        // **컬러 글리프를 먼저** 찾는다. 없으면 아래 예전 길 (모양과 무관하게 chain → system
        // fallback) 이다. 요청이 없는 글자 (거의 전부) 는 이 비교 하나로 지나간다 — U+231A 아래는
        // 첫 비교에서 끝난다. `◽ ◾ ⬛ ⬜` 는 chain 첫 글꼴 Cascadia Code 가 흑백 글리프를 가져서
        // 예전에는 거기서 멈췄다 (#771 Windows 실기).
        //
        // system fallback (`MapCharacters`) 은 모양을 보지 않는다 — 그 API 가 선택자 · 색을 받지
        // 않는다 (#771 Windows 측정 · 2026-10-17 결정). 다른 터미널도 Windows 에서 같다.
        if (presentation.isEmojiPresentation(codepoint)) {
            if (self.chainEmojiGlyph(codepoint)) |c| {
                return .{ .face = c.face, .index = c.index, .owned = false, .font_id = c.font_id };
            }
        }

        const cp32: dw.UINT32 = codepoint;
        var glyph_index: dw.UINT16 = 0;

        // 1. user chain — config.font.family 순서대로. 글리프 가진 첫 face 반환.
        for (0..self.chain_count) |i| {
            const face = self.faceAt(i, style) orelse continue;
            glyph_index = 0;
            _ = face.GetGlyphIndices(@ptrCast(&cp32), 1, @ptrCast(&glyph_index));
            if (glyph_index != 0) {
                // chain face 는 stable — cache 안 해도 OK (deinit 에서 release).
                // #584 — id 는 `init` 에서 구해 둔 것을 쓴다 (변종도 face 마다 갈린다).
                return .{ .face = face, .index = glyph_index, .owned = false, .font_id = self.chainFontId(i, style), .slant = self.chainSlant(i, style) };
            }
        }

        // Fallback via MapCharacters
        if (self.font_fallback) |fallback| {
            var wchar_buf: [2]WCHAR = undefined;
            var wchar_len: dw.UINT32 = undefined;
            if (codepoint <= 0xFFFF) {
                wchar_buf[0] = @intCast(codepoint);
                wchar_len = 1;
            } else {
                const cp = codepoint - 0x10000;
                wchar_buf[0] = @intCast(0xD800 + (cp >> 10));
                wchar_buf[1] = @intCast(0xDC00 + (cp & 0x3FF));
                wchar_len = 2;
            }

            var source = dw.SimpleTextAnalysisSource.create(&wchar_buf, wchar_len, self.number_sub);
            var mapped_length: dw.UINT32 = 0;
            var mapped_font: ?*dw.IDWriteFont = null;
            var scale: dw.FLOAT = 1.0;
            const family_ptr: ?[*:0]const WCHAR = @ptrCast(&self.primary_family_name);

            if (fallback.MapCharacters(
                @ptrCast(&source),
                0,
                wchar_len,
                self.font_collection,
                family_ptr,
                dw.DWRITE_FONT_WEIGHT_NORMAL,
                dw.DWRITE_FONT_STYLE_NORMAL,
                dw.DWRITE_FONT_STRETCH_NORMAL,
                &mapped_length,
                &mapped_font,
                &scale,
            ) >= 0) {
                if (mapped_font) |mf| {
                    defer _ = mf.vtable.Release(mf);
                    var mf_face: ?*dw.IDWriteFontFace = null;
                    if (mf.CreateFontFace(&mf_face) >= 0) {
                        if (mf_face) |face| {
                            _ = face.GetGlyphIndices(@ptrCast(&cp32), 1, @ptrCast(&glyph_index));
                            if (glyph_index != 0) {
                                // #584 — `IDWriteFont` 를 아직 들고 있는 이 자리에서 id 를 구한다.
                                const fb_id = postscriptNameId(mf);
                                // Retain the face in the cache; ownership stays with the context.
                                // This keeps the face pointer stable for the atlas cache key.
                                self.glyph_map.put(codepoint, .{ .face = face, .index = glyph_index, .font_id = fb_id }) catch {
                                    // On put failure, release to avoid leak and return owned.
                                    return .{ .face = face, .index = glyph_index, .owned = true, .font_id = fb_id };
                                };
                                return .{ .face = face, .index = glyph_index, .owned = false, .font_id = fb_id };
                            }
                            _ = face.vtable.Release(face);
                        }
                    }
                }
            }
        }

        return null;
    }

    /// Resolve a *grapheme cluster* (multiple codepoints that combine via ZWJ /
    /// VS-16 / skin tone modifier 등) to single shaped glyph. macOS 의
    /// `CTLineCreateWithAttributedString` 동등 — DirectWrite `IDWriteTextAnalyzer.GetGlyphs`
    /// 가 OpenType GSUB 를 적용해 cluster 를 단일 glyph 로 reduce.
    ///
    /// `cps[0]` 은 base codepoint, `cps[1..]` 은 modifier (VS-16 / skin tone /
    /// ZWJ + secondary base 등). chain 순회 → system fallback 순. 첫 face 가
    /// non-zero glyph 를 만들면 그걸 반환.
    ///
    /// #395 — 실제 구현은 `resolveGraphemeInner` 이고 여기서는 `perf.shape` 만 얹는다.
    /// cluster 셀마다 · 프레임마다 불리는 경로라, render 안에서 shaping 이 차지하는
    /// 몫을 이 카운터로 가른다. `return null` 경로가 여럿이라 본체를 건드리지 않도록
    /// wrapper 로 분리했다. Linux `resolveCluster` · mac `resolveGrapheme` 과 같은 모양.
    pub fn resolveGrapheme(self: *DWriteFontContext, cps: []const u21) ?ClusterResult {
        const t0 = perf.now();
        const result = self.resolveGraphemeInner(cps);
        perf.addTimed(&perf.shape, t0);
        // miss — chain 도 system fallback 도 못 맞춘 경우. 이 경로가 가장 비싸다
        // (chain 전체 순회 + `MapCharacters` + `CreateFontFace`).
        if (result == null) perf.incExtra(&perf.shape);
        return result;
    }

    /// [#420](https://github.com/ensky0/tildaz/issues/420) — cluster 를 **한 face 로 못 맞췄을 때**
    /// base 와 결합 기호를 각각 맞는 face 에서 얻는다.
    ///
    /// `resolveGrapheme` 은 cluster 전체를 한 face 로 shape 하고 `.notdef` 가 하나라도 나오면 그
    /// face 를 통째로 버린다. 그래서 **base 와 mark 가 서로 다른 폰트에만 있는 조합**은 어느
    /// face 도 통과하지 못하고 miss 가 된다. 실측 (Windows 11 · 2026-08-09):
    ///
    /// | cluster | Malgun Gothic | Segoe UI Symbol | 결과 |
    /// |---|---|---|---|
    /// | `U+AC00` (가) | ✅ | ✕ | 어느 face 도 둘 다 못 가짐 → **miss** |
    /// | `U+0301` (acute) | ✕ | ✅ | 〃 |
    ///
    /// miss 가 되면 셀 루프가 base codepoint 로 떨어져 `가` 만 그리고 **결합 기호가 조용히
    /// 사라진다.** system fallback (`MapCharacters`) 도 답이 아니다 — 문자열 전체를 한 폰트로
    /// 매핑하려 하므로 같은 이유로 실패한다 (`mapped_length = 1`).
    ///
    /// 그래서 base 는 base 대로, mark 는 mark 대로 face 를 찾아 돌려준다. **합성은 renderer 가
    /// 화면에서 한다** — atlas entry 는 face 하나짜리를 그대로 쓰고, mark 를 base 잉크 중앙에
    /// 맞춰 한 번 더 그린다 (`placeUnplacedMarks` 와 같은 정렬 규칙이다).
    ///
    /// **마지막 수단이다.** `resolveGrapheme` 이 성공하면 그쪽이 이긴다 — 한 face 안에서
    /// shaping 이 한 배치 (GPOS) 가 우리 fallback 정렬보다 항상 낫기 때문이다.
    pub const SplitCluster = struct {
        /// base codepoint 하나만으로 얻은 cluster (보통 글리프 1 개).
        base: ClusterResult,
        /// base 뒤의 결합 기호들. 못 찾은 것은 빠지므로 `cps.len - 1` 보다 적을 수 있다.
        marks: [MAX_CLUSTER_GLYPHS - 1]GlyphResult = undefined,
        mark_count: u8 = 0,
    };

    pub fn resolveGraphemeSplit(self: *DWriteFontContext, cps: []const u21) ?SplitCluster {
        if (cps.len < 2) return null;

        const base = self.resolveGrapheme(cps[0..1]) orelse return null;
        var out = SplitCluster{ .base = base };

        for (cps[1..]) |cp| {
            if (out.mark_count == out.marks.len) break;
            const g = self.resolveGlyph(cp, .regular) orelse continue;
            out.marks[out.mark_count] = g;
            out.mark_count += 1;
        }

        // mark 를 하나도 못 찾았으면 이 경로의 이득이 없다 — base 만 그리는 것은 호출자의
        // 기존 fallback 과 같다. base 를 우리가 소유했다면 여기서 놓는다.
        if (out.mark_count == 0) {
            if (base.owned) _ = base.face.vtable.Release(base.face);
            return null;
        }
        return out;
    }

    /// #399 (B) — 캐시를 씌운 층. shape 자체는 `resolveGraphemeUncached` 가 한다.
    ///
    /// **소유권이 이 함수의 핵심이다.** 셀 루프는 `result.owned` 면 매 프레임 `Release` 하는데
    /// (`renderer/windows.zig` 6 곳), 캐시에 담은 face 를 `owned = true` 로 돌려주면 그 Release
    /// 가 캐시 안의 face 를 죽인다 (use-after-free). 그래서 **캐시가 소유권을 가져가고 caller
    /// 에게는 `owned = false`** 로 준다. 해제는 `releaseCluster` 가 퇴출 · 무효화 때 한다.
    ///
    /// ⚠️ **담지 못하는 cluster 는 소유권을 넘기면 안 된다.** `ClusterCache.put` 은 키 상한
    /// (`MAX_KEY_CPS` = 8) 을 넘으면 담지 않고 **그 자리에서 값을 해제**한다 (소유권을 받았다고
    /// 보기 때문이다). 그때까지 `owned = false` 로 바꿔 주면 caller 가 이미 죽은 face 를 쓴다.
    /// 그래서 담을 수 있는지 **먼저 판정**하고, 못 담으면 원래 소유권 그대로 돌려준다.
    fn resolveGraphemeInner(self: *DWriteFontContext, cps: []const u21) ?ClusterResult {
        if (self.cluster_cache.get(cps)) |cached| {
            const c = cached orelse return null; // negative hit — chain 을 다시 헛돌지 않는다
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

    fn resolveGraphemeUncached(self: *DWriteFontContext, cps_in: []const u21) ?ClusterResult {
        if (cps_in.len == 0 or self.text_analyzer == null) return null;

        // #423 — 조합형 한글 자모는 shaping 전에 완성형으로 합친다. DirectWrite 가 안 해 주는
        // 층이고, 캐시 키는 바깥 (`resolveGraphemeInner`) 이 원본 codepoint 로 잡으므로 여기서
        // 바꿔도 캐시가 어긋나지 않는다.
        var composed: [MAX_CLUSTER_GLYPHS]u21 = undefined;
        const cps = composeHangul(cps_in, &composed);

        // UTF-21 codepoint slice → UTF-16 buffer (surrogate pair 처리).
        var u16_buf: [32]WCHAR = undefined;
        var u16_len: dw.UINT32 = 0;
        for (cps) |cp| {
            if (u16_len + 1 >= u16_buf.len) break;
            if (cp <= 0xFFFF) {
                u16_buf[u16_len] = @intCast(cp);
                u16_len += 1;
            } else {
                const off = cp - 0x10000;
                u16_buf[u16_len] = @intCast(0xD800 + (off >> 10));
                u16_buf[u16_len + 1] = @intCast(0xDC00 + (off & 0x3FF));
                u16_len += 2;
            }
        }
        if (u16_len == 0) return null;

        var indices_buf: [MAX_CLUSTER_GLYPHS]u16 = undefined;
        var advances_buf: [MAX_CLUSTER_GLYPHS]dw.FLOAT = undefined;
        var offsets_buf: [MAX_CLUSTER_GLYPHS]dw.DWRITE_GLYPH_OFFSET = undefined;

        // #416 — cluster 의 script. base codepoint 로 판정하고 캐시한다.
        const sa = self.scriptFor(cps[0]);
        // #418 — 결합 기호가 전부 관통 (overlay) 류인지. renderer 의 세로 보정 판단에 쓴다.
        const overlay = clusterOverlayOnly(cps);

        // 1. user chain 순회 — face 별로 cluster shape 시도.
        //
        // #771 — 순서는 셋이다. 모양 요청 (`presentation.forCluster`) 이 없으면 첫 단계에서 바로
        // 답이 나와 예전과 같다.
        //   1. chain 을 앞에서부터 — **모양이 맞는** 첫 face (VS16 = 컬러 · VS15 = 흑백 글리프)
        //   2. chain 에서 모양과 무관하게 처음 맞은 face
        //   3. system fallback (`MapCharacters`) — 모양을 보지 않는다. 그 API 가 선택자 · 색을
        //      받지 않는다 (#771 Windows 측정 · 2026-10-17 결정). Linux · macOS 는 이 단계에서도
        //      모양을 맞추는데, Windows 는 기본 chain 에 Segoe UI Emoji · Segoe UI Symbol 이 있어
        //      VS16 359 / 371 · VS15 371 / 371 이 1 단계에서 맞는다 (같은 측정).
        // 선택자는 원본 (`cps_in`) 의 둘째 글자로 본다 — 한글 합성은 선택자 자리를 바꾸지 않지만
        // 판정 기준을 원본에 둔다.
        const want = presentation.forCluster(cps_in);
        var first: ?ClusterResult = null;
        for (self.chain_faces[0..self.chain_count], 0..) |maybe_face, ci| {
            const face = maybe_face orelse continue;
            const cnt = self.shapeOnFaceMulti(face, &u16_buf, u16_len, cps, sa, &indices_buf, &advances_buf, &offsets_buf);
            if (cnt == 0) continue;
            const r = ClusterResult{ .face = face, .font_id = self.chain_font_id[ci], .indices = indices_buf, .advances = advances_buf, .offsets = offsets_buf, .count = cnt, .owned = false, .overlay_marks = overlay };
            const w = want orelse return r;
            // 판정을 못 하면 (`factory4` 없음) 예전처럼 처음 맞은 face 다.
            const got = self.glyphPresentation(face, indices_buf[0..cnt]) orelse return r;
            if (got == w) return r;
            if (first == null) first = r;
        }
        if (first) |r| return r;

        // 2. system fallback — OS 폰트 매칭에 물어 face 를 얻고 그 face 로 cluster 를 shape.
        //
        // **두 번 물어본다 (#418).** `MapCharacters` 의 `baseFamilyName` 은 *"이 family 에 어울리게
        // fallback 을 골라라"* 는 힌트인데, 그걸 주면 DirectWrite 가 **primary 서체를 지키려고
        // cluster 를 쪼갠다** — `k` + `U+0336` (긴 취소선) 에서 `mapped_length = 1` 로 base 만
        // 매핑하고 mark 는 포기해서, 그 face 로 shape 하면 `.notdef` 가 나와 실패했다. 결과는
        // **mark 가 조용히 사라진 화면**이었다 (`k̶` 가 `k` 로 보인다 — base 만 그려지니 사용자는
        // 입력이 무시된 것을 알 수 없다).
        //
        // `baseFamilyName = null` 로 물으면 힌트가 없으니 **cluster 전체를 덮는 폰트**를 찾아
        // 준다 (실측: `mapped_length = 2` · 두 글리프 모두 유효). 그래서 힌트를 준 시도를 먼저 하고
        // (서체 일관성이 그쪽이 낫다) 실패하면 힌트 없이 다시 묻는다.
        //
        // **폰트 이름을 코드에 박지 않는 것이 핵심이다** — OS 마다 설치 폰트가 다르고 우리는 폰트를
        // 배포하지 않는다. 같은 해법이 세 platform 에 적용된다: Linux 는 fontconfig charset 매치
        // (`system_fallback`), macOS 는 `CTFontCreateForString` 이 이 역할이다.
        //
        // cluster **중간 (mark) 위치**에서 `MapCharacters` 를 부르는 방법도 시도했는데
        // `E_INVALIDARG` 다 — combining mark 는 run 의 시작이 될 수 없다.
        //
        // 비용은 miss 경로에만 붙는다. chain 이 전부 실패한 cluster 만 여기 오고, 성공 · 실패
        // 모두 `cluster_cache` 에 담기므로 (negative 도 담는다) cluster 종류당 한 번이다.
        if (self.font_fallback != null) {
            const primary: ?[*:0]const WCHAR = @ptrCast(&self.primary_family_name);
            const hints = [2]?[*:0]const WCHAR{ primary, null };
            for (hints) |hint| {
                if (self.shapeViaSystemFallback(&u16_buf, u16_len, cps, hint, sa, &indices_buf, &advances_buf, &offsets_buf)) |r| {
                    var result = r;
                    result.overlay_marks = overlay;
                    return result;
                }
            }
        }

        return null;
    }

    /// `MapCharacters` 로 face 를 얻어 **cluster 전체**를 shape 해 본다 (#418).
    /// `base_family` 는 fallback 선택 힌트다 — `null` 이면 힌트 없이 고르게 둔다.
    fn shapeViaSystemFallback(
        self: *DWriteFontContext,
        u16_buf: *const [32]WCHAR,
        u16_len: dw.UINT32,
        cps: []const u21,
        base_family: ?[*:0]const WCHAR,
        sa: dw.DWRITE_SCRIPT_ANALYSIS,
        indices_buf: *[MAX_CLUSTER_GLYPHS]u16,
        advances_buf: *[MAX_CLUSTER_GLYPHS]dw.FLOAT,
        offsets_buf: *[MAX_CLUSTER_GLYPHS]dw.DWRITE_GLYPH_OFFSET,
    ) ?ClusterResult {
        const fallback = self.font_fallback orelse return null;

        var source = dw.SimpleTextAnalysisSource.create(u16_buf, u16_len, self.number_sub);
        var mapped_length: dw.UINT32 = 0;
        var mapped_font: ?*dw.IDWriteFont = null;
        var scale: dw.FLOAT = 1.0;
        if (fallback.MapCharacters(
            @ptrCast(&source),
            0,
            u16_len,
            self.font_collection,
            base_family,
            dw.DWRITE_FONT_WEIGHT_NORMAL,
            dw.DWRITE_FONT_STYLE_NORMAL,
            dw.DWRITE_FONT_STRETCH_NORMAL,
            &mapped_length,
            &mapped_font,
            &scale,
        ) < 0) return null;

        const mf = mapped_font orelse return null;
        defer _ = mf.vtable.Release(mf);

        // #584 — 폰트 id 를 **여기서** 구한다. 이 face 는 `CreateFontFace` 가 매번 새로 만드는
        // 객체라 주소가 안정적이지 않다 (실기: `MV Boli` 가 한 프로세스에서 주소 2 개).
        const fallback_font_id = postscriptNameId(mf);

        var face_ptr: ?*dw.IDWriteFontFace = null;
        if (mf.CreateFontFace(&face_ptr) < 0) return null;
        const face = face_ptr orelse return null;

        // `mapped_length` 를 믿지 않는다 — shape 은 cluster **전체**로 하고 `.notdef` 판정에
        // 맡긴다. 일부만 매핑된 face 는 거기서 걸러진다.
        const cnt = self.shapeOnFaceMulti(face, u16_buf, u16_len, cps, sa, indices_buf, advances_buf, offsets_buf);
        if (cnt == 0) {
            _ = face.vtable.Release(face);
            return null;
        }
        return .{ .face = face, .font_id = fallback_font_id, .indices = indices_buf.*, .advances = advances_buf.*, .offsets = offsets_buf.*, .count = cnt, .owned = true };
    }

    /// 2-char ligature lookup (SPEC § 12.2). `cp0` + `cp1` 을 primary face 로
    /// shape (TextAnalyzer.GetGlyphs) 한 후 결과 glyph 들 vs natural
    /// (`GetGlyphIndices`) 비교로 `LigatureMatch` 판정 — 공유 `ligature.classify`
    /// 사용. Latin ligature 폰트 (Fira Code / JetBrains Mono / Cascadia Code)
    /// 사용 시 `==` / `=>` / `!=` 등 정상 합성.
    ///
    /// Latin ligature 는 primary 의 GSUB — fallback chain 안 봄.
    pub fn ligaturePair(self: *DWriteFontContext, cp0: u21, cp1: u21) ?LigatureMatch {
        if (self.ligature_cache.getPair(cp0, cp1)) |cached| return cached;
        var cps = [_]u21{ cp0, cp1 };
        const result = self.ligatureShape(&cps);
        self.ligature_cache.putPair(cp0, cp1, result);
        return result;
    }

    /// 3-char ligature lookup. `===` / `!==` / `<=>` / `<--` / `-->` / `<->` /
    /// `<==` / `==>` / `||=` / `>>=` 등.
    pub fn ligatureTriple(self: *DWriteFontContext, cp0: u21, cp1: u21, cp2: u21) ?LigatureMatch {
        if (self.ligature_cache.getTriple(cp0, cp1, cp2)) |cached| return cached;
        var cps = [_]u21{ cp0, cp1, cp2 };
        const result = self.ligatureShape(&cps);
        self.ligature_cache.putTriple(cp0, cp1, cp2, result);
        return result;
    }

    /// primary face 로 shape + `ligature.classify`. natural indices 는 primary
    /// face 의 `GetGlyphIndices` 로 직접 계산. fallback chain 안 봄 (Latin
    /// ligature 는 primary 의 GSUB).
    fn ligatureShape(self: *DWriteFontContext, cps: []const u21) ?LigatureMatch {
        if (cps.len == 0 or cps.len > 4 or self.text_analyzer == null) return null;
        if (self.chain_count == 0) return null;
        const face = self.chain_faces[0] orelse return null;

        // UTF-16 buffer. ASCII candidate 만 호출되어 surrogate 없음, but safety
        // 위해 처리도 포함.
        var u16_buf: [8]WCHAR = undefined;
        var u16_len: dw.UINT32 = 0;
        for (cps) |cp| {
            if (u16_len + 1 >= u16_buf.len) return null;
            if (cp <= 0xFFFF) {
                u16_buf[u16_len] = @intCast(cp);
                u16_len += 1;
            } else {
                const off = cp - 0x10000;
                u16_buf[u16_len] = @intCast(0xD800 + (off >> 10));
                u16_buf[u16_len + 1] = @intCast(0xDC00 + (off & 0x3FF));
                u16_len += 2;
            }
        }
        if (u16_len == 0) return null;

        // Natural indices — primary face 의 cp → glyph 직접 매핑.
        var natural: [4]u16 = .{ 0, 0, 0, 0 };
        var cps_u32: [4]u32 = .{ 0, 0, 0, 0 };
        for (cps, 0..) |cp, i| cps_u32[i] = @intCast(cp);
        _ = face.GetGlyphIndices(@ptrCast(&cps_u32), @intCast(cps.len), @ptrCast(&natural));

        // Shape on primary face.
        var indices_buf: [MAX_CLUSTER_GLYPHS]u16 = undefined;
        var advances_buf: [MAX_CLUSTER_GLYPHS]dw.FLOAT = undefined;
        var offsets_buf: [MAX_CLUSTER_GLYPHS]dw.DWRITE_GLYPH_OFFSET = undefined;
        const cnt = self.shapeOnFaceMulti(face, &u16_buf, u16_len, cps, self.scriptFor(cps[0]), &indices_buf, &advances_buf, &offsets_buf);
        if (cnt == 0) return null;

        // ShapedSlot[] 구성. DWrite `DWRITE_GLYPH_OFFSET.advanceOffset` (=
        // GPOS 의 advance 외 추가 x 조정) 를 `x_offset` 으로 추출. Fira Code
        // `||=` 의 spacer 디자인이 `=` glyph 을 `||` 쪽으로 당겨 시각상 연결
        // 시키는 GPOS adjustment 가 이 offset 에 들어있음. paint 단계가 cell
        // base position 에 더해 정확한 GPOS 위치에 그림.
        //
        // y_offset 은 mac 과 동등하게 0 — Fira Code 등의 GPOS y 조정 거의 없음.
        var slots: [4]ligature.ShapedSlot = undefined;
        const checked = @min(@as(usize, cnt), slots.len);
        for (0..checked) |i| {
            const cp_idx = @min(i, cps.len - 1);
            slots[i] = .{
                .glyph_index = indices_buf[i],
                .natural_glyph_index = natural[cp_idx],
                .x_offset = @round(offsets_buf[i].advanceOffset),
                .y_offset = 0,
            };
        }
        return ligature.classify(cps.len, slots[0..checked]);
    }

    /// [#416](https://github.com/ensky0/tildaz/issues/416) — cluster 의 **script 를 판정한다.**
    ///
    /// `GetGlyphs` · `GetGlyphPlacements` 는 script 를 인자로 받고, 그 값으로 어떤 OpenType
    /// feature 를 적용할지 정한다. 지금까지 `script = 0` 을 넘겼는데 그건 어떤 문자 체계도
    /// 아니어서, **script 별 feature 가 통째로 안 걸렸다** — Arabic 의 `mark` (mark 를 base 의
    /// 어디에 놓을지) · `init`/`medi`/`fina` (연결형) 가 그렇다. 실측에서 폰트를 그대로 두고 이
    /// 값만 바꾸자 `Arial` · `Times New Roman` · `Courier New` 의 Arabic mark 배치가 전부
    /// 살아났다. Latin · 한글은 결과가 완전히 동일했다.
    ///
    /// HarfBuzz 는 `hb_buffer_guess_segment_properties` 로 script 를 스스로 추론하지만
    /// (그래서 Linux 는 이 증상이 없다) DirectWrite 는 그 판정을 호출자에게 맡긴다.
    ///
    /// **base codepoint 하나만 분석하고 캐시한다.** cluster 의 나머지는 combining mark 라
    /// script 가 *inherited* — base 를 따라가므로 결과가 같다. shaping 은 `render` 의 91.5 %
    /// (#395) 를 차지하는 hot path 라 cluster 마다 COM 왕복을 더할 수 없다.
    ///
    /// ## 예외 — **cursive script 에는 script 를 주지 않는다** (#416 · #417, 2026-08-09)
    ///
    /// 위 문단대로 script 를 넘긴 뒤 Windows 실기에서 Arabic 이 **더 나빠졌다.** cursive
    /// script 의 shaper 는 *앞뒤 글자와의 연결*을 보고 글자 모양 (`isol`/`init`/`medi`/`fina`)
    /// 을 고르는데, 터미널은 **셀 하나가 shaping 단위**라 그 문맥이 항상 없다. 그래서 shaper 가
    /// 홀로 선 글자에 연결형을 골라 버린다.
    ///
    /// | `U+0628` (ب) · Cascadia Code · 15pt | 글리프 | advance 합 |
    /// |---|---|---:|
    /// | script 안 줌 | `726` 하나 — isolated form (잉크 폭 8.64) | **8.79** (셀 9px 에 맞음) |
    /// | script = Arabic | `3125` (잉크 0) + `727` — final form (잉크 폭 12.82, `lsb = −6.52`) | **17.58** |
    ///
    /// [#417](https://github.com/ensky0/tildaz/issues/417) 이 *"Cascadia Code 의 Arabic 이
    /// 17.6 px 로 셀을 넘는다"* 고 적은 값이 바로 이 17.58 이다 — **폰트 설계가 아니라 이
    /// shaping 결과였다.** 게다가 글리프 순서가 시각 순서 (RTL) 로 뒤집혀 mark 가 배열 앞에
    /// 오는 바람에, renderer 의 mark 보정 (`placeUnplacedMarks` 는 `i > 0` 인 advance 0 글리프를
    /// mark 로 본다) 도 통째로 빗나갔다.
    ///
    /// **cursive 가 아닌 script 는 그대로 넘긴다.** Devanagari 는 script 가 있어야 conjunct 가
    /// 합성된다 (`क्षि` 가 script 지정 시 2 글리프 · advance 14.66, 안 주면 4 글리프 · 25.94).
    /// Hebrew · Thai · Lao · 한글 · 한자는 실측에서 script 유무가 **결과가 완전히 같았다.**
    ///
    /// 판정은 `IDWriteTextAnalyzer1.GetScriptProperties` 의 `isCursiveWriting` 이다 — script
    /// 목록을 코드에 박지 않고 **OS 가 아는 값**을 쓴다. 실측에서 Arabic · Syriac · Nko ·
    /// Mongolian 만 참이고 Latin · Hebrew · Hangul · Devanagari · Thai · Lao · Han · Hiragana 는
    /// 거짓이었다.
    ///
    /// 분석에 실패하면 `script = 0` 을 돌려준다 — 예전 동작 그대로다.
    fn scriptFor(self: *DWriteFontContext, base_cp: u21) dw.DWRITE_SCRIPT_ANALYSIS {
        const none = dw.DWRITE_SCRIPT_ANALYSIS{ .script = 0, .shapes = 0 };
        if (self.script_map.get(base_cp)) |cached| return cached;

        const analyzer = self.text_analyzer orelse return none;

        var u16_buf: [2]WCHAR = undefined;
        var u16_len: dw.UINT32 = 0;
        if (base_cp <= 0xFFFF) {
            u16_buf[0] = @intCast(base_cp);
            u16_len = 1;
        } else {
            const off = base_cp - 0x10000;
            u16_buf[0] = @intCast(0xD800 + (off >> 10));
            u16_buf[1] = @intCast(0xDC00 + (off & 0x3FF));
            u16_len = 2;
        }

        var source = dw.SimpleTextAnalysisSource.create(&u16_buf, u16_len, self.number_sub);
        var sink = dw.ScriptSink.create();
        const analyzed = if (analyzer.AnalyzeScript(@ptrCast(&source), 0, u16_len, @ptrCast(&sink)) >= 0 and sink.got != 0)
            sink.analysis
        else
            none;

        // cursive script 는 `none` 으로 낮춘다 (위 doc comment 의 예외). 캐시에도 낮춘 값을
        // 담아 codepoint 당 한 번만 물어본다.
        const result = if (self.isCursiveScript(analyzed)) none else analyzed;

        // 캐시가 실패해도 동작은 같다 — 다음에 다시 분석할 뿐이다.
        self.script_map.put(base_cp, result) catch {};
        return result;
    }

    /// script 가 **문맥에 따라 글자 모양이 바뀌는 (cursive)** 부류인지 (#416).
    /// `IDWriteTextAnalyzer1` 을 못 얻었으면 (DirectWrite 1.0) 거짓 — script 를 그대로 쓴다.
    fn isCursiveScript(self: *DWriteFontContext, sa: dw.DWRITE_SCRIPT_ANALYSIS) bool {
        if (sa.script == 0) return false;
        const a1 = self.text_analyzer1 orelse return false;
        var props = dw.DWRITE_SCRIPT_PROPERTIES{};
        if (a1.GetScriptProperties(sa, &props) < 0) return false;
        return props.isCursiveWriting();
    }

    /// `face` 로 cluster 를 OpenType shape — single glyph (가장 흔한 path) 또는
    /// multi-glyph cluster (#139, ZWJ family 등 GSUB 미합성). 결과는 indices array
    /// + count. .notdef 만 반환되면 null (다음 face / fallback).
    /// out_indices 는 `[MAX_CLUSTER_GLYPHS]u16`. 리턴 = count (0 = fail).
    fn shapeOnFaceMulti(self: *DWriteFontContext, face: *dw.IDWriteFontFace, text: [*]const WCHAR, text_len: dw.UINT32, cps: []const u21, sa: dw.DWRITE_SCRIPT_ANALYSIS, out_indices: *[MAX_CLUSTER_GLYPHS]u16, out_advances: *[MAX_CLUSTER_GLYPHS]dw.FLOAT, out_offsets: *[MAX_CLUSTER_GLYPHS]dw.DWRITE_GLYPH_OFFSET) u8 {
        const analyzer = self.text_analyzer orelse return 0;

        var cluster_map: [32]u16 = undefined;
        var text_props: [32]dw.DWRITE_SHAPING_TEXT_PROPERTIES = undefined;
        var glyph_indices: [64]u16 = undefined;
        var glyph_props: [64]dw.DWRITE_SHAPING_GLYPH_PROPERTIES = undefined;
        var glyph_advances: [64]dw.FLOAT = undefined;
        var glyph_offsets: [64]dw.DWRITE_GLYPH_OFFSET = undefined;
        var actual_count: dw.UINT32 = 0;

        const locale_name = std.unicode.utf8ToUtf16LeStringLiteral("en-us");

        const hr = analyzer.GetGlyphs(
            text,
            text_len,
            face,
            .FALSE, // is_sideways
            .FALSE, // is_right_to_left
            &sa,
            locale_name,
            null, // number_substitution
            null, // features
            null,
            0,
            glyph_indices.len,
            &cluster_map,
            &text_props,
            &glyph_indices,
            &glyph_props,
            &actual_count,
        );
        if (hr < 0 or actual_count == 0) return 0;
        // cluster 내 어떤 glyph 가 .notdef 면 face 가 cluster 의 모든 codepoint
        // 를 글리프로 갖지 않음 — fallback (다음 face 또는 system fallback) 으로.
        // 예: Cascadia 가 ZWJ family 받으면 emoji codepoint 가 .notdef → reject,
        // Segoe UI Emoji fallback 으로 cluster 합성 시도.
        const out_count: u8 = @intCast(@min(actual_count, MAX_CLUSTER_GLYPHS));
        var i: u8 = 0;
        while (i < out_count) : (i += 1) {
            if (glyph_indices[i] == 0) return 0; // any .notdef → fail
            out_indices[i] = glyph_indices[i];
        }

        // GetGlyphPlacements 로 advances + offsets 계산 (#139). emoji ZWJ family
        // 는 GSUB 가 single glyph 로 ligation 안 되고 multi-glyph + 각자의
        // advance/offset 으로 visual 결합되도록 design 되어 있음 (예: Segoe UI
        // Emoji 의 family-mwg 는 man[adv=11.2 off=+3.4] + woman[adv=9.3] +
        // girl[adv=0 off=-13.3] 로 left-pulled stack 으로 결합). advances=0 stack
        // 으로 그리면 girl 만 위에 보이고 family 깨짐. WT 동등 path.
        if (analyzer.GetGlyphPlacements(
            text,
            &cluster_map,
            &text_props,
            text_len,
            &glyph_indices,
            &glyph_props,
            actual_count,
            face,
            self.font_em_size,
            .FALSE, // is_sideways
            .FALSE, // is_right_to_left
            &sa,
            locale_name,
            null,
            null,
            0,
            &glyph_advances,
            &glyph_offsets,
        ) >= 0) {
            i = 0;
            while (i < out_count) : (i += 1) {
                out_advances[i] = glyph_advances[i];
                out_offsets[i] = glyph_offsets[i];
            }
        } else {
            i = 0;
            while (i < out_count) : (i += 1) {
                out_advances[i] = 0;
                out_offsets[i] = .{ .advanceOffset = 0, .ascenderOffset = 0 };
            }
        }

        // #420 — **결합 기호를 spacing 글리프로 그리는 face 는 거절한다.** 그런 face 로 그리면
        // mark 가 base 뒤 pen 위치에 한 칸 밀려 그려져 옆 칸을 덮는다 (`漢`+acute 실측:
        // CJK fallback face 가 `U+0301` 을 `advance = 7.5` 로 줬고 화면에서 글자 오른쪽 위로
        // 나갔다). 거절하면 다음 face 로 넘어가고, 결국 `resolveGraphemeSplit` 이 base 와 mark 를
        // 각각 맞는 face 에서 가져와 겹쳐 그린다.
        //
        // **cluster 가 합쳐진 경우는 건드리지 않는다.** `clusterMap` 은 codepoint 가 속한
        // *cluster* 의 첫 글리프를 가리킬 뿐이라 mark 글리프를 짚지 못한다 (`漢`+acute 도
        // `clusterMap = [0,0]` 이다). 대신 **글리프가 codepoint 와 1:1 로 나왔을 때만**
        // (= GSUB 합성이 없었을 때) 뒤쪽 mark 자리를 본다. 합성됐으면 글리프 수가 줄어서
        // 이 검사를 건너뛰고, 가나 `か`+濁点 처럼 한 글자가 된 경우가 여기 해당한다.
        if (out_count == cps.len and cps.len >= 2) {
            var tail: usize = 0;
            while (tail < cps.len - 1 and isCombiningMark(cps[cps.len - 1 - tail])) tail += 1;
            var k: usize = out_count - tail;
            while (k < out_count) : (k += 1) {
                if (glyph_advances[k] != 0) return 0;
            }
        }

        return out_count;
    }

    /// Check if a font family is installed on the system via DirectWrite.
    ///
    /// #409 — 실제 로드 (`DWriteFontContext.init`) 와 **같은 해석 함수**를 쓴다. 전에는 이쪽만
    /// `FindFamilyName` 을 따로 불러서, 판정 규칙이 두 벌이면 검증을 통과하고도 다른 폰트가
    /// 조용히 그려질 수 있었다. 해석에 성공하면 face 를 실제로 열어 본 것이므로 (`CreateFontFace`
    /// 까지 통과) "설치돼 있다" 가 로드 가능과 같은 뜻이 된다.
    ///
    /// #758 — DirectWrite 를 열지 못하면 `null` (판정하지 못함) 이다. "없음" 과 가른다 —
    /// `Config.resolveFonts` 는 없는 폰트를 다른 폰트로 바꾸므로, 판정 실패를 없음으로 읽으면
    /// 정상 폰트까지 바꾼다.
    pub fn isFontAvailable(family: [*:0]const WCHAR) ?bool {
        var factory: ?*dw.IDWriteFactory = null;
        if (dw.DWriteCreateFactory(dw.DWRITE_FACTORY_TYPE_SHARED, &dw.IID_IDWriteFactory, @ptrCast(&factory)) < 0) return null;
        defer _ = factory.?.vtable.Release(factory.?);

        var collection: ?*dw.IDWriteFontCollection = null;
        if (factory.?.GetSystemFontCollection(&collection, .FALSE) < 0) return null;
        defer _ = collection.?.vtable.Release(collection.?);

        const resolved = resolveFamily(factory.?, collection.?, family) catch return false;
        resolved.deinit();
        return true;
    }
};
