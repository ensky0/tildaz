//! Runtime libfontconfig wrapper — family name → 폰트 파일 path 조회.
//!
//! Wayland 환경에서 시스템에 깔린 monospace 폰트 path 를 얻기 위해 사용한다.
//! `libxkbcommon` 과 같은 dlopen 패턴 — macOS-hosted Linux cross builds 가
//! Linux header / linker 셋업 없이도 cross-compile 된다.

const std = @import("std");

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
const FcFini = *const fn () callconv(.c) void;
const FcCharSetCreate = *const fn () callconv(.c) ?*FcCharSet;
const FcCharSetDestroy = *const fn (cs: *FcCharSet) callconv(.c) void;
const FcCharSetAddChar = *const fn (cs: *FcCharSet, ucs4: FcChar32) callconv(.c) c_int;
const FcPatternAddCharSet = *const fn (
    p: *FcPattern,
    object: [*:0]const u8,
    cs: *const FcCharSet,
) callconv(.c) c_int;

const Api = struct {
    handle: *anyopaque,
    init: FcInit,
    pattern_create: FcPatternCreate,
    pattern_destroy: FcPatternDestroy,
    pattern_add_string: FcPatternAddString,
    config_substitute: FcConfigSubstitute,
    default_substitute: FcDefaultSubstitute,
    font_match: FcFontMatch,
    pattern_get_string: FcPatternGetString,
    fini: FcFini,
    charset_create: FcCharSetCreate,
    charset_destroy: FcCharSetDestroy,
    charset_add_char: FcCharSetAddChar,
    pattern_add_charset: FcPatternAddCharSet,

    fn load() !Api {
        const handle = std.c.dlopen("libfontconfig.so.1", .{ .LAZY = true }) orelse return error.FontconfigLibraryMissing;
        errdefer _ = std.c.dlclose(handle);

        return .{
            .handle = handle,
            .init = lookupSym(handle, FcInit, "FcInit") orelse return error.FontconfigSymbolMissing,
            .pattern_create = lookupSym(handle, FcPatternCreate, "FcPatternCreate") orelse return error.FontconfigSymbolMissing,
            .pattern_destroy = lookupSym(handle, FcPatternDestroy, "FcPatternDestroy") orelse return error.FontconfigSymbolMissing,
            .pattern_add_string = lookupSym(handle, FcPatternAddString, "FcPatternAddString") orelse return error.FontconfigSymbolMissing,
            .config_substitute = lookupSym(handle, FcConfigSubstitute, "FcConfigSubstitute") orelse return error.FontconfigSymbolMissing,
            .default_substitute = lookupSym(handle, FcDefaultSubstitute, "FcDefaultSubstitute") orelse return error.FontconfigSymbolMissing,
            .font_match = lookupSym(handle, FcFontMatch, "FcFontMatch") orelse return error.FontconfigSymbolMissing,
            .pattern_get_string = lookupSym(handle, FcPatternGetString, "FcPatternGetString") orelse return error.FontconfigSymbolMissing,
            .fini = lookupSym(handle, FcFini, "FcFini") orelse return error.FontconfigSymbolMissing,
            .charset_create = lookupSym(handle, FcCharSetCreate, "FcCharSetCreate") orelse return error.FontconfigSymbolMissing,
            .charset_destroy = lookupSym(handle, FcCharSetDestroy, "FcCharSetDestroy") orelse return error.FontconfigSymbolMissing,
            .charset_add_char = lookupSym(handle, FcCharSetAddChar, "FcCharSetAddChar") orelse return error.FontconfigSymbolMissing,
            .pattern_add_charset = lookupSym(handle, FcPatternAddCharSet, "FcPatternAddCharSet") orelse return error.FontconfigSymbolMissing,
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
pub fn lookup(allocator: std.mem.Allocator, family: [*:0]const u8) !MatchResult {
    var api = try Api.load();
    defer api.deinit();

    if (api.init() == 0) return error.FontconfigInitFailed;
    defer api.fini();

    const pattern = api.pattern_create() orelse return error.FontconfigPatternCreateFailed;
    defer api.pattern_destroy(pattern);

    if (api.pattern_add_string(pattern, "family", family) == 0) return error.FontconfigPatternAddFailed;

    return matchAndExtract(&api, pattern, allocator);
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
    var api = try Api.load();
    defer api.deinit();

    if (api.init() == 0) return error.FontconfigInitFailed;
    defer api.fini();

    const pattern = api.pattern_create() orelse return error.FontconfigPatternCreateFailed;
    defer api.pattern_destroy(pattern);

    const charset = api.charset_create() orelse return error.FontconfigCharSetCreateFailed;
    // FcPatternAddCharSet 은 charset 을 복사(FcValueSave)하므로 우리 것은
    // pattern 과 독립적으로 파괴해도 안전.
    defer api.charset_destroy(charset);
    if (api.charset_add_char(charset, cp) == 0) return error.FontconfigCharSetAddFailed;
    if (api.pattern_add_charset(pattern, "charset", charset) == 0) return error.FontconfigPatternAddFailed;

    return matchAndExtract(&api, pattern, allocator);
}

/// substitute → match → family/file 추출의 공통 꼬리. `lookup` (family 기반)
/// 과 `lookupForChar` (charset 기반) 가 공유.
fn matchAndExtract(api: *const Api, pattern: *FcPattern, allocator: std.mem.Allocator) !MatchResult {
    if (api.config_substitute(null, pattern, FC_MATCH_PATTERN) == 0) return error.FontconfigSubstituteFailed;
    api.default_substitute(pattern);

    var result: c_int = FC_RESULT_MATCH;
    const match = api.font_match(null, pattern, &result) orelse return error.FontconfigNoMatch;
    defer api.pattern_destroy(match);
    if (result != FC_RESULT_MATCH) return error.FontconfigNoMatch;

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

    return .{
        .family = family_dup,
        .additional_families = additional_owned,
        .path = path_dup,
    };
}
