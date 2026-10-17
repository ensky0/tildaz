//! DirectWrite 가 글꼴에 없는 bold · italic 을 **얼마나** 합성하는지 재는 도구예요
//! ([#759](https://github.com/ensky0/tildaz/issues/759)).
//!
//! **Windows 전용이에요.** macOS · Linux 에도 합성을 넣으면서 세 OS 의 기울기 · 굵기를 한 값으로
//! 맞추기로 했어요. Windows 는 DirectWrite 가 합성하고 그 양은 문서에 없어요. Wine 의 재구현은
//! 기울기 1/3 · 굵기 em/24 (가로만) 인데, Microsoft 코드가 아니라서 실기로 재요.
//!
//! **같은 글꼴 파일로 합성 변종을 직접 만들어요.** `IDWriteFactory::CreateFontFace` 가 글꼴 파일과
//! 합성 플래그 (`DWRITE_FONT_SIMULATIONS`) 를 받아요. 그래서 italic · bold 파일이 있는 글꼴로도
//! regular · 합성 bold · 합성 oblique 를 같은 조건에서 견줄 수 있어요.
//!
//! 재는 것 — 글자 하나 (기본 `|`, 곧은 세로획) 를 aliased (흑백) 로 크게 그려서:
//!   - **기울기** — 가운데 60 % 행에서 획 가운데의 가로 위치를 세로 위치에 직선으로 맞춘 기울기.
//!     위가 오른쪽으로 가면 양수예요. 앱이 쓰는 변환 0.2 로 그린 대조 줄이 0.200 근처로 나와야
//!     측정이 맞는 거예요.
//!   - **획 폭** — 같은 행들의 평균 폭 (px). regular 와의 차이를 em 대비로 적어요.
//!   - **advance** — `GetDesignGlyphMetrics` 의 글자 간격 (design unit). 합성 bold 가 글자 간격을
//!     넓히는지 봐요.
//!
//! 빌드 · 실행 (본체 빌드에는 들어가지 않아요):
//! ```powershell
//! zig build-exe -O ReleaseSafe --dep directwrite '-Mroot=tool/synthetic-style-probe_windows.zig' `
//!     -O ReleaseSafe '-Mdirectwrite=src/font/windows/directwrite.zig' --cache-dir C:/ziglang/tildaz-cache
//! ```
//! PowerShell 에서는 `-M…=…` 인자를 따옴표로 감싸요. 감싸지 않으면 PowerShell 5.1 이 `=` 에서 나눠
//! `found another zig file '.zig'` 로 빌드가 실패해요.
//! `-O` (와 `-target`) 는 **`-M` 앞**에 둬요. 모듈 설정은 바로 뒤의 `-M` 에 붙어서, 뒤에 두면 도구가
//! 기본값 (Debug · 지금 기기) 으로 컴파일돼요. `zig build probe-check` 가 같은 도구를 컴파일로 확인해요.
//! ```powershell
//! .\synthetic-style-probe_windows.exe                          # 기본 글꼴 목록
//! .\synthetic-style-probe_windows.exe --family "Cascadia Mono" --char l --em 300
//! ```
//! 결과는 화면과 `synthetic-style-probe.txt` (`--out` 으로 바꿔요) 에 같이 써요.

const std = @import("std");
const builtin = @import("builtin");
const dw = @import("directwrite");

comptime {
    if (builtin.os.tag != .windows) @compileError("synthetic-style-probe 는 Windows 전용이에요.");
}

const BOOL = dw.BOOL;
const HRESULT = dw.HRESULT;
const UINT32 = dw.UINT32;

extern "kernel32" fn GetStdHandle(u32) callconv(.c) ?*anyopaque;
extern "kernel32" fn WriteFile(?*anyopaque, [*]const u8, u32, *u32, ?*anyopaque) callconv(.c) BOOL;

const DWRITE_FONT_SIMULATIONS_BOLD: u32 = 1;
const DWRITE_FONT_SIMULATIONS_OBLIQUE: u32 = 2;

/// 앱이 쓰기로 한 기울기 (#759). 대조 줄이 이 값으로 읽히면 측정이 맞는 거예요.
const control_shear: f32 = 0.2;

const default_families = [_][]const u8{ "Cascadia Mono", "Consolas", "Malgun Gothic", "GulimChe" };

var out_alloc: std.mem.Allocator = undefined;
var dump: std.ArrayList(u8) = .empty;

fn p(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(out_alloc, fmt, args) catch return;
    dump.appendSlice(out_alloc, s) catch {};
    var written: u32 = 0;
    // STD_OUTPUT_HANDLE = -11
    _ = WriteFile(GetStdHandle(@bitCast(@as(i32, -11))), s.ptr, @intCast(s.len), &written, null);
}

// --- 본체 바인딩이 타입 없이 둔 vtable 슬롯 (dwrite.h 시그니처) ---
//
// 본체 `directwrite.zig` 는 쓰지 않는 슬롯을 `*const anyopaque` 로 두었어요. 그 파일은 건드리지
// 않고, `factory4TranslateColorGlyphRun` 과 같은 모양으로 여기서만 타입을 붙여 불러요.

fn faceType(face: *dw.IDWriteFontFace) u32 {
    const f = @as(*const fn (*dw.IDWriteFontFace) callconv(.c) u32, @ptrCast(@alignCast(face.vtable.GetType)));
    return f(face);
}

fn faceIndex(face: *dw.IDWriteFontFace) u32 {
    const f = @as(*const fn (*dw.IDWriteFontFace) callconv(.c) u32, @ptrCast(@alignCast(face.vtable.GetIndex)));
    return f(face);
}

fn faceSimulations(face: *dw.IDWriteFontFace) u32 {
    const f = @as(*const fn (*dw.IDWriteFontFace) callconv(.c) u32, @ptrCast(@alignCast(face.vtable.GetSimulations)));
    return f(face);
}

/// `GetFiles(UINT32* numberOfFiles, IDWriteFontFile** fontFiles)` — 먼저 개수만, 그다음 배열.
fn faceFiles(face: *dw.IDWriteFontFace, buf: []?*dw.IUnknown) ![]?*dw.IUnknown {
    const F = *const fn (*dw.IDWriteFontFace, *UINT32, ?[*]?*dw.IUnknown) callconv(.c) HRESULT;
    const f = @as(F, @ptrCast(@alignCast(face.vtable.GetFiles)));
    var n: UINT32 = 0;
    if (f(face, &n, null) < 0) return error.GetFilesFailed;
    if (n == 0 or n > buf.len) return error.GetFilesCount;
    if (f(face, &n, buf.ptr) < 0) return error.GetFilesFailed;
    return buf[0..n];
}

/// `IDWriteFactory::CreateFontFace(type, numberOfFiles, fontFiles, faceIndex, simulations, fontFace)`.
fn createFace(factory: *dw.IDWriteFactory, ty: u32, files: []?*dw.IUnknown, index: u32, sims: u32) !*dw.IDWriteFontFace {
    const F = *const fn (*dw.IDWriteFactory, u32, UINT32, [*]const ?*dw.IUnknown, UINT32, u32, *?*dw.IDWriteFontFace) callconv(.c) HRESULT;
    const f = @as(F, @ptrCast(@alignCast(factory.vtable.CreateFontFace)));
    var face: ?*dw.IDWriteFontFace = null;
    if (f(factory, ty, @intCast(files.len), files.ptr, index, sims, &face) < 0) return error.CreateFontFaceFailed;
    return face orelse error.CreateFontFaceFailed;
}

// --- 그리기 · 측정 ---

const Measure = struct {
    slant: f64,
    stem_px: f64,
    rows: usize,
    width: i32,
    height: i32,
};

fn render(factory: *dw.IDWriteFactory, face: *dw.IDWriteFontFace, glyph: u16, em: f32, transform: ?*const dw.DWRITE_MATRIX) !Measure {
    const idx = [_]u16{glyph};
    const run = dw.DWRITE_GLYPH_RUN{
        .fontFace = face,
        .fontEmSize = em,
        .glyphCount = 1,
        .glyphIndices = &idx,
        .glyphAdvances = null,
        .glyphOffsets = null,
        .isSideways = .FALSE,
        .bidiLevel = 0,
    };
    var analysis: ?*dw.IDWriteGlyphRunAnalysis = null;
    if (factory.CreateGlyphRunAnalysis(&run, 1.0, transform, dw.DWRITE_RENDERING_MODE_ALIASED, dw.DWRITE_MEASURING_MODE_NATURAL, 0, 0, &analysis) < 0)
        return error.AnalysisFailed;
    defer _ = analysis.?.Release();

    var rc: dw.RECT = undefined;
    if (analysis.?.GetAlphaTextureBounds(dw.DWRITE_TEXTURE_ALIASED_1x1, &rc) < 0) return error.BoundsFailed;
    const w: i32 = @intCast(rc.right - rc.left);
    const h: i32 = @intCast(rc.bottom - rc.top);
    if (w <= 0 or h <= 0) return error.EmptyGlyph;
    const size: usize = @intCast(w * h);
    const px = try out_alloc.alloc(u8, size);
    if (analysis.?.CreateAlphaTexture(dw.DWRITE_TEXTURE_ALIASED_1x1, &rc, px.ptr, @intCast(size)) < 0) return error.TextureFailed;

    // 잉크가 있는 행의 범위.
    var top: i32 = -1;
    var bottom: i32 = -1;
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        const row = px[@intCast(y * w)..@intCast((y + 1) * w)];
        if (std.mem.findNone(u8, row, &.{0}) != null) {
            if (top < 0) top = y;
            bottom = y;
        }
    }
    if (top < 0) return error.EmptyGlyph;

    // 가운데 60 % 행만 — 획 끝의 둥근 부분 · 세리프를 피해요.
    const span = bottom - top + 1;
    const y0 = top + @divTrunc(span * 2, 10);
    const y1 = bottom - @divTrunc(span * 2, 10);
    var n: f64 = 0;
    var sy: f64 = 0;
    var sc: f64 = 0;
    var syy: f64 = 0;
    var syc: f64 = 0;
    var sw: f64 = 0;
    y = y0;
    while (y <= y1) : (y += 1) {
        const row = px[@intCast(y * w)..@intCast((y + 1) * w)];
        const l = std.mem.findNone(u8, row, &.{0}) orelse continue;
        const r = std.mem.findLastNone(u8, row, &.{0}) orelse continue;
        const fy: f64 = @floatFromInt(y);
        const c: f64 = (@as(f64, @floatFromInt(l)) + @as(f64, @floatFromInt(r))) / 2.0;
        n += 1;
        sy += fy;
        sc += c;
        syy += fy * fy;
        syc += fy * c;
        sw += @floatFromInt(r - l + 1);
    }
    if (n < 2) return error.TooFewRows;
    const denom = n * syy - sy * sy;
    const slope = if (denom == 0) 0 else (n * syc - sy * sc) / denom;
    // 비트맵의 y 는 아래로 커요. 위가 오른쪽으로 가면 slope 가 음수라 부호를 뒤집어요.
    return .{ .slant = -slope, .stem_px = sw / n, .rows = @intFromFloat(n), .width = w, .height = h };
}

fn advanceOf(face: *dw.IDWriteFontFace, glyph: u16) i64 {
    const idx = [_]u16{glyph};
    var gm: [1]dw.DWRITE_GLYPH_METRICS = undefined;
    if (face.GetDesignGlyphMetrics(&idx, 1, &gm, .FALSE) < 0) return -1;
    return gm[0].advanceWidth;
}

fn simName(s: u32) []const u8 {
    return switch (s) {
        0 => "none",
        1 => "bold",
        2 => "oblique",
        3 => "bold+oblique",
        else => "?",
    };
}

/// 앱이 실제로 타는 경로 — 그 스타일을 달라고 했을 때 DirectWrite 가 합성한 글꼴을 주는지.
fn matchSims(family: *dw.IDWriteFontFamily, weight: u32, style: u32) ?u32 {
    var font: ?*dw.IDWriteFont = null;
    if (family.GetFirstMatchingFont(weight, dw.DWRITE_FONT_STRETCH_NORMAL, style, &font) < 0) return null;
    defer _ = font.?.Release();
    return font.?.GetSimulations();
}

fn probeFamily(factory: *dw.IDWriteFactory, coll: *dw.IDWriteFontCollection, name: []const u8, cp: u32, em: f32) void {
    p("\n== {s} ==\n", .{name});
    var wbuf: [128]u16 = undefined;
    const wn = std.unicode.utf8ToUtf16Le(wbuf[0 .. wbuf.len - 1], name) catch {
        p("  이름이 너무 길어요\n", .{});
        return;
    };
    wbuf[wn] = 0;
    var fi: UINT32 = 0;
    var exists: BOOL = .FALSE;
    if (coll.FindFamilyName(wbuf[0..wn :0].ptr, &fi, &exists) < 0 or !exists.toBool()) {
        p("  설치되지 않았어요 — 건너뜀\n", .{});
        return;
    }
    var family: ?*dw.IDWriteFontFamily = null;
    if (coll.GetFontFamily(fi, &family) < 0) return;
    defer _ = family.?.Release();

    // 이 글꼴에 진짜 italic · bold 파일이 있는지 (앱 경로에서 합성이 일어나는지).
    p("  앱 경로: italic 요청 → sim={s}, bold 요청 → sim={s}\n", .{
        if (matchSims(family.?, dw.DWRITE_FONT_WEIGHT_NORMAL, dw.DWRITE_FONT_STYLE_ITALIC)) |s| simName(s) else "?",
        if (matchSims(family.?, dw.DWRITE_FONT_WEIGHT_BOLD, dw.DWRITE_FONT_STYLE_NORMAL)) |s| simName(s) else "?",
    });

    var regular_font: ?*dw.IDWriteFont = null;
    if (family.?.GetFirstMatchingFont(dw.DWRITE_FONT_WEIGHT_NORMAL, dw.DWRITE_FONT_STRETCH_NORMAL, dw.DWRITE_FONT_STYLE_NORMAL, &regular_font) < 0) return;
    defer _ = regular_font.?.Release();
    var base: ?*dw.IDWriteFontFace = null;
    if (regular_font.?.CreateFontFace(&base) < 0) return;
    defer _ = base.?.Release();
    if (faceSimulations(base.?) != 0) {
        p("  regular 도 합성된 글꼴이에요 (sim={s}) — 건너뜀\n", .{simName(faceSimulations(base.?))});
        return;
    }

    var fbuf: [8]?*dw.IUnknown = .{null} ** 8;
    const files = faceFiles(base.?, &fbuf) catch |err| {
        p("  GetFiles 실패: {s}\n", .{@errorName(err)});
        return;
    };
    defer {
        for (files) |f| {
            if (f) |ff| _ = ff.Release();
        }
    }
    const ty = faceType(base.?);
    const index = faceIndex(base.?);

    var metrics: dw.DWRITE_FONT_METRICS = undefined;
    base.?.GetMetrics(&metrics);
    const upem: f64 = @floatFromInt(metrics.designUnitsPerEm);

    const cps = [_]u32{cp};
    var gi = [_]u16{0};
    if (base.?.GetGlyphIndices(&cps, 1, &gi) < 0 or gi[0] == 0) {
        p("  U+{X:0>4} 글리프가 없어요 — 건너뜀\n", .{cp});
        return;
    }
    p("  글자 U+{X:0>4} · em {d} px · upem {d}\n", .{ cp, em, metrics.designUnitsPerEm });
    p("  {s:<22} {s:>8} {s:>7} {s:>9} {s:>10} {s:>8} {s:>12}\n", .{ "변종", "기울기", "각도", "획폭px", "Δ획폭/em", "advance", "Δadv/upem" });

    const shear = dw.DWRITE_MATRIX{ .m11 = 1, .m12 = 0, .m21 = -control_shear, .m22 = 1, .dx = 0, .dy = 0 };
    const Variant = struct { label: []const u8, sims: u32, transform: ?*const dw.DWRITE_MATRIX };
    const variants = [_]Variant{
        .{ .label = "regular", .sims = 0, .transform = null },
        .{ .label = "regular + 변환 0.2", .sims = 0, .transform = &shear },
        .{ .label = "합성 oblique", .sims = DWRITE_FONT_SIMULATIONS_OBLIQUE, .transform = null },
        .{ .label = "합성 bold", .sims = DWRITE_FONT_SIMULATIONS_BOLD, .transform = null },
        .{ .label = "합성 bold+oblique", .sims = DWRITE_FONT_SIMULATIONS_BOLD | DWRITE_FONT_SIMULATIONS_OBLIQUE, .transform = null },
    };

    var reg_stem: f64 = 0;
    var reg_adv: i64 = 0;
    for (variants) |v| {
        const face = if (v.sims == 0) base.? else (createFace(factory, ty, files, index, v.sims) catch |err| {
            p("  {s:<22} 만들기 실패: {s}\n", .{ v.label, @errorName(err) });
            continue;
        });
        defer if (v.sims != 0) {
            _ = face.Release();
        };
        const got = faceSimulations(face);
        const m = render(factory, face, gi[0], em, v.transform) catch |err| {
            p("  {s:<22} 그리기 실패: {s}\n", .{ v.label, @errorName(err) });
            continue;
        };
        const adv = advanceOf(face, gi[0]);
        if (v.sims == 0 and v.transform == null) {
            reg_stem = m.stem_px;
            reg_adv = adv;
        }
        const deg = std.math.atan(m.slant) * 180.0 / std.math.pi;
        p("  {s:<22} {d:>8.3} {d:>6.1}° {d:>9.2} {d:>10.4} {d:>8} {d:>12.4}   (sim={s}, 행 {d})\n", .{
            v.label,                                       m.slant,      deg,    m.stem_px, (m.stem_px - reg_stem) / em, @as(u64, @intCast(@max(adv, 0))),
            @as(f64, @floatFromInt(adv - reg_adv)) / upem, simName(got), m.rows,
        });
    }
}

pub fn main(init: std.process.Init) !void {
    out_alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(out_alloc);

    var families: std.ArrayList([]const u8) = .empty;
    var out_path: []const u8 = "synthetic-style-probe.txt";
    var cp: u32 = '|';
    var em: f32 = 200;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--family") and i + 1 < args.len) {
            i += 1;
            try families.append(out_alloc, args[i]);
        } else if (std.mem.eql(u8, a, "--char") and i + 1 < args.len) {
            i += 1;
            const view = std.unicode.Utf8View.init(args[i]) catch return error.BadChar;
            var it = view.iterator();
            cp = it.nextCodepoint() orelse return error.BadChar;
        } else if (std.mem.eql(u8, a, "--em") and i + 1 < args.len) {
            i += 1;
            em = try std.fmt.parseFloat(f32, args[i]);
        } else if (std.mem.eql(u8, a, "--out") and i + 1 < args.len) {
            i += 1;
            out_path = args[i];
        } else {
            p("사용법: synthetic-style-probe_windows.exe [--family 이름]... [--char 글자] [--em px] [--out 파일]\n", .{});
            return;
        }
    }
    if (families.items.len == 0) try families.appendSlice(out_alloc, &default_families);

    var factory: ?*dw.IDWriteFactory = null;
    if (dw.DWriteCreateFactory(dw.DWRITE_FACTORY_TYPE_SHARED, &dw.IID_IDWriteFactory, @ptrCast(&factory)) < 0) return error.FactoryFailed;
    defer _ = factory.?.Release();
    var coll: ?*dw.IDWriteFontCollection = null;
    if (factory.?.GetSystemFontCollection(&coll, .FALSE) < 0) return error.CollectionFailed;
    defer _ = coll.?.Release();

    p("synthetic-style-probe (#759) — DirectWrite 합성 bold · oblique 의 양\n", .{});
    p("기울기: 위가 오른쪽으로 가면 양수. 대조 줄 (변환 {d}) 이 그 값 근처로 나와야 측정이 맞아요.\n", .{control_shear});
    for (families.items) |name| probeFamily(factory.?, coll.?, name, cp, em);

    // 결과 파일 — UTF-8 BOM 을 붙여 메모장 · PowerShell 이 코드페이지로 오해하지 않게 해요.
    const file = std.Io.Dir.cwd().createFile(init.io, out_path, .{}) catch |err| {
        p("\n결과 파일을 못 만들었어요: {s}\n", .{@errorName(err)});
        return;
    };
    defer file.close(init.io);
    file.writeStreamingAll(init.io, "\xEF\xBB\xBF") catch {};
    file.writeStreamingAll(init.io, dump.items) catch {};
    p("\n결과를 {s} 에 썼어요.\n", .{out_path});
}
