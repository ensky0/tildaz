//! Runtime libfontconfig wrapper — family name → 폰트 파일 path 조회.
//!
//! Wayland 환경에서 시스템에 깔린 monospace 폰트 path 를 얻기 위해 사용한다.
//! `libxkbcommon` 과 같은 dlopen 패턴 — macOS-hosted Linux cross builds 가
//! Linux header / linker 셋업 없이도 cross-compile 된다.

const std = @import("std");
const font_constants = @import("../constants.zig");

const FcConfig = opaque {};
const FcPattern = opaque {};
const FcCharSet = opaque {};
const FcChar8 = u8;
const FcChar32 = u32;

// FcMatchKind enum.
const FC_MATCH_PATTERN: c_int = 0;

// FcResult enum.
const FC_RESULT_MATCH: c_int = 0;
const FC_RESULT_NO_MATCH: c_int = 1;
const FC_RESULT_TYPE_MISMATCH: c_int = 2;
const FC_RESULT_NO_ID: c_int = 3;
const FC_RESULT_OUT_OF_MEMORY: c_int = 4;

const FcInit = *const fn () callconv(.c) c_int;
const FcPatternCreate = *const fn () callconv(.c) ?*FcPattern;
const FcPatternDestroy = *const fn (p: *FcPattern) callconv(.c) void;
const FcPatternAddString = *const fn (
    p: *FcPattern,
    object: [*:0]const u8,
    s: [*:0]const FcChar8,
) callconv(.c) c_int;
/// #375 — weight / slant 를 pattern 에 넣어 같은 family 의 bold · italic face 를
/// 찾는다. 기존에는 `FcPatternAddString` (family) 만 바인딩돼 있었다.
const FcPatternAddInteger = *const fn (
    p: *FcPattern,
    object: [*:0]const u8,
    i: c_int,
) callconv(.c) c_int;
const FcConfigSubstitute = *const fn (
    config: ?*FcConfig,
    p: *FcPattern,
    kind: c_int,
) callconv(.c) c_int;
const FcDefaultSubstitute = *const fn (p: *FcPattern) callconv(.c) void;
const FcFontMatch = *const fn (
    config: ?*FcConfig,
    p: *FcPattern,
    result: *c_int,
) callconv(.c) ?*FcPattern;
const FcPatternGetString = *const fn (
    p: *FcPattern,
    object: [*:0]const u8,
    n: c_int,
    s: *[*:0]FcChar8,
) callconv(.c) c_int;
/// #428 — 매치된 face 의 `index`. `.ttc` 는 한 파일에 face 가 여러 벌이라 path 만으로는
/// 어느 face 인지 정해지지 않는다.
const FcPatternGetInteger = *const fn (
    p: *FcPattern,
    object: [*:0]const u8,
    n: c_int,
    i: *c_int,
) callconv(.c) c_int;
const FcFini = *const fn () callconv(.c) void;
const FcCharSetCreate = *const fn () callconv(.c) ?*FcCharSet;
const FcCharSetDestroy = *const fn (cs: *FcCharSet) callconv(.c) void;
const FcCharSetAddChar = *const fn (cs: *FcCharSet, ucs4: FcChar32) callconv(.c) c_int;
const FcPatternAddCharSet = *const fn (
    p: *FcPattern,
    object: [*:0]const u8,
    cs: *const FcCharSet,
) callconv(.c) c_int;

// #406 — 설치된 family **목록**을 얻는다. `FcFontMatch` 는 요청한 이름이 시스템에 없어도
// 항상 무언가를 돌려주므로 (오타 `NoSuchFont12345` 에도 `Noto Sans` 가 나온다) 그것만으로는
// "설치돼 있는데 별칭이 가로챈 것" 과 "아예 없는 것" 을 가를 수 없다. 목록에 있는지로 가른다 —
// macOS 의 `CTFontManagerCopyAvailableFontFamilyNames` 에 해당한다.
const FcObjectSet = opaque {};
const FcFontSet = extern struct {
    nfont: c_int,
    sfont: c_int,
    fonts: ?[*]?*FcPattern,
};
const FcObjectSetCreate = *const fn () callconv(.c) ?*FcObjectSet;
const FcObjectSetAdd = *const fn (os: *FcObjectSet, object: [*:0]const u8) callconv(.c) c_int;
const FcObjectSetDestroy = *const fn (os: *FcObjectSet) callconv(.c) void;
const FcFontList = *const fn (config: ?*anyopaque, p: *FcPattern, os: *FcObjectSet) callconv(.c) ?*FcFontSet;

const Api = struct {
    handle: *anyopaque,
    init: FcInit,
    pattern_create: FcPatternCreate,
    pattern_destroy: FcPatternDestroy,
    pattern_add_string: FcPatternAddString,
    pattern_add_integer: FcPatternAddInteger,
    config_substitute: FcConfigSubstitute,
    default_substitute: FcDefaultSubstitute,
    font_match: FcFontMatch,
    pattern_get_string: FcPatternGetString,
    pattern_get_integer: FcPatternGetInteger,
    fini: FcFini,
    charset_create: FcCharSetCreate,
    charset_destroy: FcCharSetDestroy,
    charset_add_char: FcCharSetAddChar,
    pattern_add_charset: FcPatternAddCharSet,
    object_set_create: FcObjectSetCreate,
    object_set_add: FcObjectSetAdd,
    object_set_destroy: FcObjectSetDestroy,
    font_list: FcFontList,

    fn load() !Api {
        const handle = std.c.dlopen("libfontconfig.so.1", .{ .LAZY = true }) orelse return error.FontconfigLibraryMissing;
        errdefer _ = std.c.dlclose(handle);

        return .{
            .handle = handle,
            .init = lookupSym(handle, FcInit, "FcInit") orelse return error.FontconfigSymbolMissing,
            .pattern_create = lookupSym(handle, FcPatternCreate, "FcPatternCreate") orelse return error.FontconfigSymbolMissing,
            .pattern_destroy = lookupSym(handle, FcPatternDestroy, "FcPatternDestroy") orelse return error.FontconfigSymbolMissing,
            .pattern_add_string = lookupSym(handle, FcPatternAddString, "FcPatternAddString") orelse return error.FontconfigSymbolMissing,
            .pattern_add_integer = lookupSym(handle, FcPatternAddInteger, "FcPatternAddInteger") orelse return error.FontconfigSymbolMissing,
            .config_substitute = lookupSym(handle, FcConfigSubstitute, "FcConfigSubstitute") orelse return error.FontconfigSymbolMissing,
            .default_substitute = lookupSym(handle, FcDefaultSubstitute, "FcDefaultSubstitute") orelse return error.FontconfigSymbolMissing,
            .font_match = lookupSym(handle, FcFontMatch, "FcFontMatch") orelse return error.FontconfigSymbolMissing,
            .pattern_get_string = lookupSym(handle, FcPatternGetString, "FcPatternGetString") orelse return error.FontconfigSymbolMissing,
            .pattern_get_integer = lookupSym(handle, FcPatternGetInteger, "FcPatternGetInteger") orelse return error.FontconfigSymbolMissing,
            .fini = lookupSym(handle, FcFini, "FcFini") orelse return error.FontconfigSymbolMissing,
            .charset_create = lookupSym(handle, FcCharSetCreate, "FcCharSetCreate") orelse return error.FontconfigSymbolMissing,
            .charset_destroy = lookupSym(handle, FcCharSetDestroy, "FcCharSetDestroy") orelse return error.FontconfigSymbolMissing,
            .charset_add_char = lookupSym(handle, FcCharSetAddChar, "FcCharSetAddChar") orelse return error.FontconfigSymbolMissing,
            .pattern_add_charset = lookupSym(handle, FcPatternAddCharSet, "FcPatternAddCharSet") orelse return error.FontconfigSymbolMissing,
            .object_set_create = lookupSym(handle, FcObjectSetCreate, "FcObjectSetCreate") orelse return error.FontconfigSymbolMissing,
            .object_set_add = lookupSym(handle, FcObjectSetAdd, "FcObjectSetAdd") orelse return error.FontconfigSymbolMissing,
            .object_set_destroy = lookupSym(handle, FcObjectSetDestroy, "FcObjectSetDestroy") orelse return error.FontconfigSymbolMissing,
            .font_list = lookupSym(handle, FcFontList, "FcFontList") orelse return error.FontconfigSymbolMissing,
        };
    }

    fn deinit(self: *Api) void {
        _ = std.c.dlclose(self.handle);
    }
};

fn lookupSym(handle: *anyopaque, comptime T: type, name: [*:0]const u8) ?T {
    const symbol = std.c.dlsym(handle, name) orelse return null;
    return @ptrCast(@alignCast(symbol));
}

pub const MatchResult = struct {
    /// fontconfig가 반환한 index 0의 primary family 명.
    family: []u8,
    /// `FC_FAMILY` index 1 이후의 정당한 family/alias. explicit family 검증은
    /// primary와 이 항목들을 모두 대소문자 무시 exact 비교해야 한다.
    additional_families: [][]u8,
    /// 매치된 폰트 파일 path.
    path: []u8,
    /// #428 — 그 파일 안의 **face index**. `.ttc` / `.otc` 는 한 파일에 face 가 여러 벌이라
    /// (`NotoSansCJK-Regular.ttc` 는 JP · KR · SC · TC · HK × 일반/Mono 로 10 벌) path 만
    /// 열면 요청과 다른 폰트가 나온다. `FT_New_Face` 의 `face_index` 로 그대로 넘긴다 —
    /// variable font 의 named instance 도 fontconfig 가 상위 16 비트에 실어 주고 FreeType 이
    /// 같은 인코딩을 읽으므로 값을 건드리지 않는 것이 맞다.
    index: i32,

    pub fn deinitAdditionalFamilies(self: MatchResult, allocator: std.mem.Allocator) void {
        for (self.additional_families) |family| allocator.free(family);
        allocator.free(self.additional_families);
    }

    pub fn deinit(self: MatchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.family);
        self.deinitAdditionalFamilies(allocator);
        allocator.free(self.path);
    }
};

/// `family` 에 해당하는 폰트의 fontconfig 매치 결과 (반환 family/alias 전체 +
/// 파일 path)를 caller-owned 슬라이스로 반환.
///
/// 주의: fontconfig 는 정확한 매치가 없으면 fallback substitution 으로 *다른*
/// family 의 path 를 반환할 수 있다. caller 가 `result.family`와
/// `result.additional_families`를 요청 family와 비교해서 substitution 여부를
/// 판단해야 한다. generic family("monospace" / "sans-serif" / "serif")만
/// substitution 허용 의도.
/// **fontconfig 는 프로세스당 한 번만 초기화한다** (#368).
///
/// 예전에는 lookup 마다 `FcInit` → `FcFini` 를 반복했다. `FcInit` 은 시스템의
/// fontconfig 설정 전체를 파싱하므로 실측 **호출당 4.2~4.8 ms** 이고, 시작 시
/// 12 번 불려 (폰트 컨텍스트 4 벌 × chain 3 family) 거기에만 ~54 ms 를 썼다.
/// 정작 match 자체는 0.5 ms 다.
///
/// 그래서 `FcFini` 를 부르지 않고 초기화 상태를 유지한다 — fontconfig 의 정상
/// 사용 패턴이고, 이게 아니면 런타임의 system fallback 조회 (`lookupForChar`,
/// 처음 보는 codepoint 마다) 도 매번 4.5 ms 를 문다.
///
/// 라이브러리도 `dlclose` 하지 않는다 — fontconfig 내부 상태가 살아 있는 채로
/// 닫으면 그 상태를 가리키는 포인터가 무효가 된다.
var cached_api: ?Api = null;

fn sharedApi() !*Api {
    if (cached_api == null) {
        var api = try Api.load();
        if (api.init() == 0) {
            api.deinit();
            return error.FontconfigInitFailed;
        }
        cached_api = api;
    }
    return &cached_api.?;
}

/// 설치된 family 목록. **프로세스당 한 번만 만든다** — `FcInit` 을 한 번만 부르는 위
/// `cached_api` 와 같은 결정이다 (#368). `FcFontList` 는 이미 메모리에 올라온 font set 을
/// 훑는 것이라 실측 0.33 ms 로 싸지만, 같은 답이 나오는 조회를 시작 경로에서 반복할 이유가
/// 없다 (폰트 컨텍스트 4 벌 × chain entry 만큼 불린다).
///
/// 돌려받은 `FcFontSet` 은 원래 caller 가 `FcFontSetDestroy` 로 놓아야 하지만 프로세스 수명
/// 동안 들고 있는다 — `FcFini` 를 부르지 않는 것과 같은 이유다. 그래서 **앱이 도는 중에 폰트를
/// 설치해도 이 목록은 갱신되지 않는다.** chain 은 startup 에 만들어지고 config 변경도 재시작이
/// 필요하므로 동작 차이는 없다.
var cached_family_set: ?*FcFontSet = null;

fn sharedFamilySet(api: *const Api) !*FcFontSet {
    if (cached_family_set) |set| return set;

    const pattern = api.pattern_create() orelse return error.FontconfigListUnavailable;
    defer api.pattern_destroy(pattern);

    const os = api.object_set_create() orelse return error.FontconfigListUnavailable;
    defer api.object_set_destroy(os);
    if (api.object_set_add(os, "family") == 0) return error.FontconfigListUnavailable;

    const set = api.font_list(null, pattern, os) orelse return error.FontconfigListUnavailable;
    cached_family_set = set;
    return set;
}

/// #406 · #409 — `family` 와 **같은 폰트를 가리키는 설치된 family 이름의 정식 표기**를 찾아
/// `out` 에 담아 돌려준다. 없으면 `null` (= 그런 폰트가 시스템에 없다). 이름 비교는 `eql` 이
/// 판정한다 (호출자가 정규화 규칙을 정한다 — 대소문자 · 공백 · `-` 무시 등).
///
/// **왜 목록을 보나** — `FcFontMatch` 는 요청 이름이 시스템에 없어도 항상 무언가를 돌려준다
/// (오타 `NoSuchFont12345` 에도 `Noto Sans` 가 나온다). 그래서 그 반환값만으로는 아래 둘을
/// 가를 수 없는데, 우리는 갈라야 한다.
///
///   - `Noto Color Emoji` -> `Twemoji`  : 설치돼 있는데 별칭 규칙이 가로챈 것 -> 띄운다
///   - `NoSuchFont12345`  -> `Noto Sans`: 아예 없는 것 -> fatal
///
/// **bool 이 아니라 이름을 돌려주는 이유** (#409) — fontconfig 의 family 매칭은 공백과 대소문자만
/// 무시하고 `-` 는 유효 문자로 본다. 그래서 `NotoSerifKannada-Light` 처럼 적으면 `Noto Serif
/// Kannada Light` 가 설치돼 있는데도 매치가 엉뚱한 폰트로 간다. 정식 표기를 받아 **그 표기로 다시
/// 조회해야** 의도한 폰트가 나온다 — 통과만 시키면 다른 폰트가 조용히 그려진다. macOS 판
/// (`font/macos/font.zig` 의 `resolveInstalledName`) 이 정식 이름으로 폰트를 다시 만드는 것과
/// 같은 단계다.
///
/// 목록 조회에 실패하면 `error.FontconfigListUnavailable` — 호출자는 **미설치로 오판하지 않고**
/// 기존 경로에 맡긴다 (판정 불가는 거절 사유가 아니다).
pub fn findInstalledFamily(
    family: []const u8,
    eql: *const fn (a: []const u8, b: []const u8) bool,
    out: []u8,
) !?[]const u8 {
    const api = try sharedApi();
    const set = try sharedFamilySet(api);

    const fonts = set.fonts orelse return error.FontconfigListUnavailable;
    var i: usize = 0;
    while (i < @as(usize, @intCast(set.nfont))) : (i += 1) {
        const pat = fonts[i] orelse continue;
        // 한 pattern 이 family 를 여러 개 가진다 (별칭 · 번역된 이름). 전부 본다.
        var n: c_int = 0;
        while (true) : (n += 1) {
            var value: [*:0]FcChar8 = undefined;
            if (api.pattern_get_string(pat, "family", n, &value) != 0) break;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(value)));
            if (!eql(family, name)) continue;
            // 버퍼보다 긴 이름은 담지 못한다 — 설치는 확인됐으니 원문을 그대로 돌려준다.
            // 호출자는 "정식 표기 == 원문" 으로 보고 재조회를 건너뛴다.
            if (name.len > out.len) return family;
            @memcpy(out[0..name.len], name);
            return out[0..name.len];
        }
    }
    return null;
}

pub fn lookup(allocator: std.mem.Allocator, family: [*:0]const u8) !MatchResult {
    return lookupStyled(allocator, family, .regular);
}

// fontconfig 의 weight / slant 값 (fontconfig.h). 100 단위 weight 체계가 아니라
// 자체 스케일이다.
const FC_WEIGHT_REGULAR: c_int = 80;
const FC_WEIGHT_BOLD: c_int = 200;
const FC_SLANT_ROMAN: c_int = 0;
const FC_SLANT_ITALIC: c_int = 100;

/// #375 — 같은 family 의 face 변종을 찾는다.
///
/// **fontconfig 는 요청과 가장 근접한 face 를 돌려준다** (매치 실패가 아니다).
/// 그래서 bold face 가 없는 family 는 자연히 regular 가 오고, 호출부가 "없으면
/// regular" 를 따로 판정할 필요가 없다 — macOS · Windows 백엔드와 같은 성질이다.
pub fn lookupStyled(
    allocator: std.mem.Allocator,
    family: [*:0]const u8,
    style: font_constants.FaceStyle,
) !MatchResult {
    const api = try sharedApi();

    const pattern = api.pattern_create() orelse return error.FontconfigPatternCreateFailed;
    defer api.pattern_destroy(pattern);

    if (api.pattern_add_string(pattern, "family", family) == 0) return error.FontconfigPatternAddFailed;
    if (style != .regular) {
        const weight: c_int = if (style.isBold()) FC_WEIGHT_BOLD else FC_WEIGHT_REGULAR;
        const slant: c_int = if (style.isItalic()) FC_SLANT_ITALIC else FC_SLANT_ROMAN;
        if (api.pattern_add_integer(pattern, "weight", weight) == 0) return error.FontconfigPatternAddFailed;
        if (api.pattern_add_integer(pattern, "slant", slant) == 0) return error.FontconfigPatternAddFailed;
    }

    return matchAndExtract(api, pattern, allocator);
}

/// `cp` 를 가진 폰트의 fontconfig 매치 (`fc-match ':charset=XXXX'` 동등) —
/// chain 밖 codepoint 의 system font fallback (#289 B5). Windows
/// `MapCharacters` / macOS `CTFontCreateForString` 의 per-codepoint fallback
/// 에 해당.
///
/// 주의: FcFontMatch 는 charset 을 *점수* 로만 반영해 시스템 어느 폰트도 cp
/// 를 안 가져도 "최선" 폰트를 반환한다 (error 아님). caller 가 로드한 face 의
/// `get_char_index(cp)` 로 실보유를 확인하고, 미보유면 negative cache 에
/// 기록해 재조회를 막아야 한다.
pub fn lookupForChar(allocator: std.mem.Allocator, cp: u21) !MatchResult {
    const api = try sharedApi();

    const pattern = api.pattern_create() orelse return error.FontconfigPatternCreateFailed;
    defer api.pattern_destroy(pattern);

    const charset = api.charset_create() orelse return error.FontconfigCharSetCreateFailed;
    // FcPatternAddCharSet 은 charset 을 복사(FcValueSave)하므로 우리 것은
    // pattern 과 독립적으로 파괴해도 안전.
    defer api.charset_destroy(charset);
    if (api.charset_add_char(charset, cp) == 0) return error.FontconfigCharSetAddFailed;
    if (api.pattern_add_charset(pattern, "charset", charset) == 0) return error.FontconfigPatternAddFailed;

    return matchAndExtract(api, pattern, allocator);
}

/// #409 — PostScript 이름 (`NotoSansCJKkr-Regular`) 으로 **face 하나**를 찾는다.
///
/// PostScript 이름을 `font.family` 에 적는 것은 흔한 실수다 — macOS 의 Font Book 을 비롯한
/// 폰트 도구가 그 이름을 보여준다. macOS 는 `CTFontCreateWithName` 이 family · PostScript ·
/// full name 을 모두 받아서 되고 있었고, Linux 는 family 로만 조회해서 못 받았다 (#409 의 표).
///
/// **자기검증이 필수다.** `FcFontMatch` 는 family 때와 마찬가지로 없는 이름에도 "가장 가까운"
/// 폰트를 돌려준다 (실측: `:postscriptname=NoSuchFont12345-Regular` → `Noto Sans CJK KR`).
/// 그래서 돌아온 pattern 의 `postscriptname` 을 `eql` 로 되짚어 확인하고, 아니면
/// `error.FontconfigNoPostScriptMatch` 로 거절한다 — 호출자는 다음 해석 단계로 넘어간다.
///
/// PostScript 이름은 family 가 아니라 **face** 를 가리키므로 (`DejaVuSansMono-Bold`) 결과의
/// `path` + `index` 가 곧 그 face 다. `family` 에는 그 face 가 속한 family 의 정식 이름이
/// 들어오므로, 호출자는 그것을 bold / italic 변종 조회의 기준으로 쓰면 된다.
pub fn lookupPostScript(
    allocator: std.mem.Allocator,
    name: [:0]const u8,
    eql: *const fn (a: []const u8, b: []const u8) bool,
) !MatchResult {
    const api = try sharedApi();

    const pattern = api.pattern_create() orelse return error.FontconfigPatternCreateFailed;
    defer api.pattern_destroy(pattern);
    if (api.pattern_add_string(pattern, "postscriptname", name.ptr) == 0) return error.FontconfigPatternAddFailed;

    const match = try substituteAndMatch(api, pattern);
    defer api.pattern_destroy(match);

    var ps_ptr: [*:0]FcChar8 = undefined;
    if (api.pattern_get_string(match, "postscriptname", 0, &ps_ptr) != FC_RESULT_MATCH) {
        return error.FontconfigNoPostScriptMatch;
    }
    if (!eql(name, std.mem.span(@as([*:0]const u8, @ptrCast(ps_ptr))))) {
        return error.FontconfigNoPostScriptMatch;
    }

    return extract(api, match, allocator);
}

/// substitute → match 까지. 매치 pattern 의 소유권은 caller 에게 있다 (`pattern_destroy`).
fn substituteAndMatch(api: *const Api, pattern: *FcPattern) !*FcPattern {
    if (api.config_substitute(null, pattern, FC_MATCH_PATTERN) == 0) return error.FontconfigSubstituteFailed;
    api.default_substitute(pattern);

    var result: c_int = FC_RESULT_MATCH;
    const match = api.font_match(null, pattern, &result) orelse return error.FontconfigNoMatch;
    errdefer api.pattern_destroy(match);
    if (result != FC_RESULT_MATCH) return error.FontconfigNoMatch;
    return match;
}

/// substitute → match → family/file 추출의 공통 꼬리. `lookup` (family 기반)
/// 과 `lookupForChar` (charset 기반) 가 공유.
fn matchAndExtract(api: *const Api, pattern: *FcPattern, allocator: std.mem.Allocator) !MatchResult {
    const match = try substituteAndMatch(api, pattern);
    defer api.pattern_destroy(match);
    return extract(api, match, allocator);
}

/// 매치 pattern 에서 family / alias / file / index 를 caller-owned 로 뽑아낸다.
fn extract(api: *const Api, match: *FcPattern, allocator: std.mem.Allocator) !MatchResult {
    var family_ptr: [*:0]FcChar8 = undefined;
    if (api.pattern_get_string(match, "family", 0, &family_ptr) != FC_RESULT_MATCH) return error.FontconfigNoFamily;
    var file_ptr: [*:0]FcChar8 = undefined;
    if (api.pattern_get_string(match, "file", 0, &file_ptr) != FC_RESULT_MATCH) return error.FontconfigNoFile;

    const family_dup = try allocator.dupe(u8, std.mem.span(family_ptr));
    errdefer allocator.free(family_dup);

    // FcResultNoId = object는 존재하지만 요청 index의 값은 없음. index 1부터
    // 그 결과가 나올 때까지 순회해야 localized name/alias를 놓치지 않는다.
    var additional: std.ArrayList([]u8) = .empty;
    errdefer {
        for (additional.items) |family| allocator.free(family);
        additional.deinit(allocator);
    }
    var family_index: c_int = 1;
    while (true) : (family_index += 1) {
        var additional_ptr: [*:0]FcChar8 = undefined;
        switch (api.pattern_get_string(match, "family", family_index, &additional_ptr)) {
            FC_RESULT_MATCH => {
                const dup = try allocator.dupe(u8, std.mem.span(additional_ptr));
                additional.append(allocator, dup) catch |err| {
                    allocator.free(dup);
                    return err;
                };
            },
            FC_RESULT_NO_ID => break,
            FC_RESULT_NO_MATCH => return error.FontconfigNoFamily,
            FC_RESULT_TYPE_MISMATCH => return error.FontconfigFamilyTypeMismatch,
            FC_RESULT_OUT_OF_MEMORY => return error.OutOfMemory,
            else => return error.FontconfigFamilyQueryFailed,
        }
    }
    const additional_owned = try additional.toOwnedSlice(allocator);
    errdefer {
        for (additional_owned) |family| allocator.free(family);
        allocator.free(additional_owned);
    }
    const path_dup = try allocator.dupe(u8, std.mem.span(file_ptr));

    // #428 — `index` 가 없는 매치는 face 가 하나인 파일이다 (단일 `.ttf` / `.otf`). 그때는 0 이
    // 맞으므로 조회 실패를 에러로 올리지 않는다.
    var face_index: c_int = 0;
    if (api.pattern_get_integer(match, "index", 0, &face_index) != FC_RESULT_MATCH) face_index = 0;

    return .{
        .family = family_dup,
        .additional_families = additional_owned,
        .path = path_dup,
        .index = @intCast(face_index),
    };
}
