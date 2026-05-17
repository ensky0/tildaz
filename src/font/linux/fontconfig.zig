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
            .init = lookup(handle, FcInit, "FcInit") orelse return error.FontconfigSymbolMissing,
            .pattern_create = lookup(handle, FcPatternCreate, "FcPatternCreate") orelse return error.FontconfigSymbolMissing,
            .pattern_destroy = lookup(handle, FcPatternDestroy, "FcPatternDestroy") orelse return error.FontconfigSymbolMissing,
            .pattern_add_string = lookup(handle, FcPatternAddString, "FcPatternAddString") orelse return error.FontconfigSymbolMissing,
            .config_substitute = lookup(handle, FcConfigSubstitute, "FcConfigSubstitute") orelse return error.FontconfigSymbolMissing,
            .default_substitute = lookup(handle, FcDefaultSubstitute, "FcDefaultSubstitute") orelse return error.FontconfigSymbolMissing,
            .font_match = lookup(handle, FcFontMatch, "FcFontMatch") orelse return error.FontconfigSymbolMissing,
            .pattern_get_string = lookup(handle, FcPatternGetString, "FcPatternGetString") orelse return error.FontconfigSymbolMissing,
            .fini = lookup(handle, FcFini, "FcFini") orelse return error.FontconfigSymbolMissing,
        };
    }

    fn deinit(self: *Api) void {
        _ = std.c.dlclose(self.handle);
    }
};

fn lookup(handle: *anyopaque, comptime T: type, name: [*:0]const u8) ?T {
    const symbol = std.c.dlsym(handle, name) orelse return null;
    return @ptrCast(@alignCast(symbol));
}

/// `family` 에 해당하는 폰트 파일 path 를 caller-owned 슬라이스로 반환.
///
/// 일반적으로 `family = "monospace"` 를 넣으면 시스템 default monospace
/// (DejaVu Sans Mono / Noto Sans Mono / Liberation Mono 등) path 가 돌아온다.
/// libfontconfig 가 없거나 매치 실패 / 파일 추출 실패 시 error.
pub fn lookupFile(allocator: std.mem.Allocator, family: [*:0]const u8) ![]u8 {
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

    var file_ptr: [*:0]FcChar8 = undefined;
    if (api.pattern_get_string(match, "file", 0, &file_ptr) != FC_RESULT_MATCH) return error.FontconfigNoFile;

    return try allocator.dupe(u8, std.mem.span(file_ptr));
}
