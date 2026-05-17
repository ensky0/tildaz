//! Runtime libfontconfig wrapper — family name → 폰트 파일 path 조회.
//!
//! Wayland 환경에서 시스템에 깔린 monospace 폰트 path 를 얻기 위해 사용한다.
//! `libxkbcommon` 과 같은 dlopen 패턴 — macOS-hosted Linux cross builds 가
//! Linux header / linker 셋업 없이도 cross-compile 된다.

const std = @import("std");

const FcConfig = opaque {};
const FcPattern = opaque {};
const FcChar8 = u8;

// FcMatchKind enum.
const FC_MATCH_PATTERN: c_int = 0;

// FcResult enum.
const FC_RESULT_MATCH: c_int = 0;

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

    fn load() !Api {
        const handle = std.c.dlopen("libfontconfig.so.1", .{ .LAZY = true }) orelse return error.FontconfigLibraryMissing;
        errdefer _ = std.c.dlclose(handle);

        return .{
            .handle = handle,
            .init = lookupSym(handle,FcInit, "FcInit") orelse return error.FontconfigSymbolMissing,
            .pattern_create = lookupSym(handle,FcPatternCreate, "FcPatternCreate") orelse return error.FontconfigSymbolMissing,
            .pattern_destroy = lookupSym(handle,FcPatternDestroy, "FcPatternDestroy") orelse return error.FontconfigSymbolMissing,
            .pattern_add_string = lookupSym(handle,FcPatternAddString, "FcPatternAddString") orelse return error.FontconfigSymbolMissing,
            .config_substitute = lookupSym(handle,FcConfigSubstitute, "FcConfigSubstitute") orelse return error.FontconfigSymbolMissing,
            .default_substitute = lookupSym(handle,FcDefaultSubstitute, "FcDefaultSubstitute") orelse return error.FontconfigSymbolMissing,
            .font_match = lookupSym(handle,FcFontMatch, "FcFontMatch") orelse return error.FontconfigSymbolMissing,
            .pattern_get_string = lookupSym(handle,FcPatternGetString, "FcPatternGetString") orelse return error.FontconfigSymbolMissing,
            .fini = lookupSym(handle,FcFini, "FcFini") orelse return error.FontconfigSymbolMissing,
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
    /// fontconfig 가 *반환한* family 명. 우리가 *요청한* family 와 다르면 fallback
    /// substitution 발생 — caller 가 비교해서 skip 여부 결정.
    family: []u8,
    /// 매치된 폰트 파일 path.
    path: []u8,
};

/// `family` 에 해당하는 폰트의 fontconfig 매치 결과 (반환 family + 파일 path) 를
/// caller-owned 슬라이스로 반환.
///
/// 주의: fontconfig 는 정확한 매치가 없으면 fallback substitution 으로 *다른*
/// family 의 path 를 반환할 수 있다. caller 가 `result.family` 를 우리가 요청한
/// family 와 비교해서 substitution 여부를 판단해야 한다. generic family
/// ("monospace" / "sans-serif" / "serif") 만 substitution 허용 의도.
pub fn lookup(allocator: std.mem.Allocator, family: [*:0]const u8) !MatchResult {
    var api = try Api.load();
    defer api.deinit();

    if (api.init() == 0) return error.FontconfigInitFailed;
    defer api.fini();

    const pattern = api.pattern_create() orelse return error.FontconfigPatternCreateFailed;
    defer api.pattern_destroy(pattern);

    if (api.pattern_add_string(pattern, "family", family) == 0) return error.FontconfigPatternAddFailed;

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
    const path_dup = try allocator.dupe(u8, std.mem.span(file_ptr));

    return .{ .family = family_dup, .path = path_dup };
}
