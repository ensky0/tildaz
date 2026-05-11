// Cross-platform config.json schema + parser. Windows + macOS 같은 nested
// schema, default 만 OS-specific (font.family / font.size / shell / hotkey
// 등). `Defaults` struct + `defaultConfigJson(alloc, shell_resolved)` 가 schema
// single source — createDefault 가 그대로 파일에 저장 + parse 시 user config
// 와 비교 (`validateStructure`) 검증의 ground truth.
//
// 새 필드 추가 시 *Defaults + defaultConfigJson 한 곳만* update 하면 required /
// unknown / type 검증 자동 sync. value range 만 별도 hardcoded.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const themes = @import("themes.zig");
const dialog = @import("dialog.zig");
const messages = @import("messages.zig");
const paths = @import("paths.zig");
const font_validate = @import("font/validate.zig");
const font_constants = @import("font/constants.zig");

const WCHAR = u16;

pub const MAX_FONT_FAMILIES = font_constants.MAX_CHAIN;

const is_windows = builtin.os.tag == .windows;
const is_macos = builtin.os.tag == .macos;

// --- DockPosition (cross-platform) ---

pub const DockPosition = enum {
    top,
    bottom,
    left,
    right,

    pub fn fromString(s: []const u8) ?DockPosition {
        const map = [_]struct { name: []const u8, val: DockPosition }{
            .{ .name = "top", .val = .top },
            .{ .name = "bottom", .val = .bottom },
            .{ .name = "left", .val = .left },
            .{ .name = "right", .val = .right },
        };
        for (map) |entry| {
            if (std.mem.eql(u8, s, entry.name)) return entry.val;
        }
        return null;
    }
};

// --- Hotkey (platform-specific ABI, same string parser interface) ---

/// Windows: `RegisterHotKey` 의 vkey + modifier flags. macOS: CGEventTap 이
/// 받는 `kVK_*` keycode + `kCGEventFlagMask*` modifier mask. 외부 인터페이스는
/// `Hotkey.fromString(s)` 로 동일.
pub const Hotkey = if (is_windows) WindowsHotkey else if (is_macos) MacHotkey else struct {};

const WindowsHotkey = struct {
    vkey: u32 = 0x70, // VK_F1
    modifiers: u32 = 0,

    pub fn fromString(s: []const u8) ?WindowsHotkey {
        var modifiers: u32 = 0;
        var keycode: ?u32 = null;
        var iter = std.mem.tokenizeScalar(u8, s, '+');
        while (iter.next()) |raw| {
            const tok = std.mem.trim(u8, raw, " \t");
            if (eqIc(tok, "ctrl") or eqIc(tok, "control")) {
                modifiers |= 0x2; // MOD_CONTROL
            } else if (eqIc(tok, "shift")) {
                modifiers |= 0x4; // MOD_SHIFT
            } else if (eqIc(tok, "alt")) {
                modifiers |= 0x1; // MOD_ALT
            } else if (eqIc(tok, "win") or eqIc(tok, "super") or eqIc(tok, "cmd")) {
                modifiers |= 0x8; // MOD_WIN — `cmd` token 도 같이 (cross-platform string)
            } else {
                if (winVkeyFromName(tok)) |k| keycode = k else return null;
            }
        }
        return .{ .vkey = keycode orelse return null, .modifiers = modifiers };
    }

    fn winVkeyFromName(name: []const u8) ?u32 {
        const map = [_]struct { name: []const u8, code: u32 }{
            .{ .name = "f1", .code = 0x70 },    .{ .name = "f2", .code = 0x71 },
            .{ .name = "f3", .code = 0x72 },    .{ .name = "f4", .code = 0x73 },
            .{ .name = "f5", .code = 0x74 },    .{ .name = "f6", .code = 0x75 },
            .{ .name = "f7", .code = 0x76 },    .{ .name = "f8", .code = 0x77 },
            .{ .name = "f9", .code = 0x78 },    .{ .name = "f10", .code = 0x79 },
            .{ .name = "f11", .code = 0x7A },   .{ .name = "f12", .code = 0x7B },
            .{ .name = "space", .code = 0x20 },
            .{ .name = "grave", .code = 0xC0 }, // VK_OEM_3
            .{ .name = "tab", .code = 0x09 },
            .{ .name = "escape", .code = 0x1B },
            .{ .name = "esc", .code = 0x1B },
            .{ .name = "enter", .code = 0x0D },
            .{ .name = "return", .code = 0x0D },
        };
        for (map) |entry| {
            if (eqIc(name, entry.name)) return entry.code;
        }
        if (name.len == 1) {
            const c = std.ascii.toUpper(name[0]);
            if (c >= 'A' and c <= 'Z') return c;
            if (c >= '0' and c <= '9') return c;
        }
        return null;
    }
};

const MacHotkey = struct {
    /// `kVK_*` (Carbon Events.h). 우리는 macOS Tahoe + Carbon 못 써 직접 매핑.
    keycode: u32 = 0x7A, // kVK_F1
    /// CGEventFlags (`kCGEventFlagMask*`). u64 — bit 16..23 사용.
    modifiers: u64 = 0,

    pub fn fromString(s: []const u8) ?MacHotkey {
        var modifiers: u64 = 0;
        var keycode: ?u32 = null;
        var iter = std.mem.tokenizeScalar(u8, s, '+');
        while (iter.next()) |raw| {
            const tok = std.mem.trim(u8, raw, " \t");
            if (eqIc(tok, "cmd") or eqIc(tok, "command") or eqIc(tok, "win") or eqIc(tok, "super")) {
                modifiers |= 0x00100000; // kCGEventFlagMaskCommand
            } else if (eqIc(tok, "shift")) {
                modifiers |= 0x00020000; // kCGEventFlagMaskShift
            } else if (eqIc(tok, "alt") or eqIc(tok, "option") or eqIc(tok, "opt")) {
                modifiers |= 0x00080000; // kCGEventFlagMaskAlternate
            } else if (eqIc(tok, "ctrl") or eqIc(tok, "control")) {
                modifiers |= 0x00040000; // kCGEventFlagMaskControl
            } else {
                if (macKeycodeFromName(tok)) |k| keycode = k else return null;
            }
        }
        return .{ .keycode = keycode orelse return null, .modifiers = modifiers };
    }

    fn macKeycodeFromName(name: []const u8) ?u32 {
        const map = [_]struct { name: []const u8, code: u32 }{
            .{ .name = "f1", .code = 0x7A },        .{ .name = "f2", .code = 0x78 },
            .{ .name = "f3", .code = 0x63 },        .{ .name = "f4", .code = 0x76 },
            .{ .name = "f5", .code = 0x60 },        .{ .name = "f6", .code = 0x61 },
            .{ .name = "f7", .code = 0x62 },        .{ .name = "f8", .code = 0x64 },
            .{ .name = "f9", .code = 0x65 },        .{ .name = "f10", .code = 0x6D },
            .{ .name = "f11", .code = 0x67 },       .{ .name = "f12", .code = 0x6F },
            .{ .name = "space", .code = 0x31 },     .{ .name = "grave", .code = 0x32 },
            .{ .name = "backquote", .code = 0x32 }, .{ .name = "tab", .code = 0x30 },
            .{ .name = "return", .code = 0x24 },    .{ .name = "enter", .code = 0x24 },
            .{ .name = "escape", .code = 0x35 },    .{ .name = "esc", .code = 0x35 },
            // 알파벳 — kVK_ANSI_*
            .{ .name = "a", .code = 0x00 },         .{ .name = "b", .code = 0x0B },
            .{ .name = "c", .code = 0x08 },         .{ .name = "d", .code = 0x02 },
            .{ .name = "e", .code = 0x0E },         .{ .name = "f", .code = 0x03 },
            .{ .name = "g", .code = 0x05 },         .{ .name = "h", .code = 0x04 },
            .{ .name = "i", .code = 0x22 },         .{ .name = "j", .code = 0x26 },
            .{ .name = "k", .code = 0x28 },         .{ .name = "l", .code = 0x25 },
            .{ .name = "m", .code = 0x2E },         .{ .name = "n", .code = 0x2D },
            .{ .name = "o", .code = 0x1F },         .{ .name = "p", .code = 0x23 },
            .{ .name = "q", .code = 0x0C },         .{ .name = "r", .code = 0x0F },
            .{ .name = "s", .code = 0x01 },         .{ .name = "t", .code = 0x11 },
            .{ .name = "u", .code = 0x20 },         .{ .name = "v", .code = 0x09 },
            .{ .name = "w", .code = 0x0D },         .{ .name = "x", .code = 0x07 },
            .{ .name = "y", .code = 0x10 },         .{ .name = "z", .code = 0x06 },
        };
        for (map) |entry| {
            if (eqIc(name, entry.name)) return entry.code;
        }
        return null;
    }
};

fn eqIc(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// =============================================================================
// Defaults — config 의 *모든* default 값 단일 source of truth.
//
// Win 과 Mac 에서 schema (키 set / 중첩 구조 / value type) 는 동일하고 *값* 만
// 일부 OS-specific (font.family / font.size / cell_width / line_height /
// shell). 두 OS 의 default 를 같은 struct 의 if-else 분기 + 같은 필드 순서로
// 나란히 두어서 한눈에 비교 / 편집 가능.
//
// 이 한 곳만 고치면:
//   (a) `defaultConfigJson(alloc, shell_resolved)` — Defaults 값 그대로 JSON
//       템플릿 생성. 첫 실행 시 디스크 (`%APPDATA%\tildaz\config.json` 등)
//       에 저장됨 + parse() 의 `validateStructure` 가 schema 검증 ground
//       truth 로 사용. shell 만 host 가 첫 실행 시점에 resolveShell 로 결정해
//       인자로 전달 (Windows 는 항상 Defaults.shell, macOS 는 $SHELL 우선).
//   (b) `Config` struct 의 field initializer 가 참조하는 `default_*` const 도
//       모두 같은 Defaults 에서 derive — disk 와 memory 가 자동 sync.
//
// 이전엔 JSON literal + `DEFAULT_FONT_FAMILIES` + `default_font_size` /
// `default_shell` 등 6+ 곳에 default 값이 흩어져 한쪽만 고치면 disk vs memory
// default 가 어긋나는 잠재 버그.
// =============================================================================

pub const Defaults = if (is_windows) struct {
    pub const dock_position: []const u8 = "top";
    /// percent (0..100). 실수 — 사용자 세밀 조정용 (예: 33.3, 66.7).
    pub const width_percent: f32 = 50.0;
    pub const height_percent: f32 = 100.0;
    pub const offset_percent: f32 = 100.0;
    /// JSON 은 0..100 percent (실수). 메모리 alpha (0..255 u8) 변환은
    /// default_opacity_alpha 가 처리.
    pub const opacity_percent: f32 = 100.0;
    /// Primary font — 단일 string. 시스템에 반드시 설치돼 있어야 함 (없으면
    /// startup 시 fatal). Cascadia Code 는 Windows 11 / Win10 22H2+ 기본.
    pub const font_family: []const u8 = "Cascadia Code";
    /// Glyph fallback chain — primary 에 글리프 없을 때 순서대로 lookup. 모두
    /// 시스템에 설치돼 있어야 함. 한글 (Malgun Gothic) → 이모지 (Segoe UI
    /// Emoji) → 심볼 (Segoe UI Symbol). 모두 Windows 8.1+ 기본 설치.
    pub const glyph_fallback: []const []const u8 = &.{ "Malgun Gothic", "Segoe UI Emoji", "Segoe UI Symbol" };
    /// font size in *typographic point*. 두 platform 모두 host 에서 DPI scale
    /// 곱한 후 raster (#148 B-2 후 = 사용자 size_point × DPI scale = font_height_px).
    pub const font_size_point: u8 = 16;
    /// cell width *ratio* — 측정된 advance 에 곱해 글자 사이 padding 조절.
    /// 1.0 = 폰트 그대로, 1.1 = 10% 더 넓음.
    pub const cell_width_ratio: f32 = 1.0;
    /// line height ratio — 측정된 ascent+descent+leading 에 곱해 줄 높이 조절.
    pub const line_height_ratio: f32 = 1.0;
    pub const theme: []const u8 = "Tilda";
    pub const shell: []const u8 = "cmd.exe";
    pub const hotkey: []const u8 = "f1";
    pub const auto_start: bool = true;
    pub const hidden_start: bool = false;
    pub const max_scroll_lines: u32 = 100_000;
} else struct {
    pub const dock_position: []const u8 = "top";
    pub const width_percent: f32 = 50.0;
    pub const height_percent: f32 = 100.0;
    pub const offset_percent: f32 = 100.0;
    pub const opacity_percent: f32 = 100.0;
    /// Primary font — Menlo 는 OS X 10.6+ 기본 등록 monospace.
    pub const font_family: []const u8 = "Menlo";
    /// Glyph fallback chain — 한글 (Apple SD Gothic Neo, 10.11+) → 이모지
    /// (Apple Color Emoji, 10.7+) → 심볼 (Apple Symbols, 10.5+). 모두
    /// macOS 기본 설치.
    pub const glyph_fallback: []const []const u8 = &.{ "Apple SD Gothic Neo", "Apple Color Emoji", "Apple Symbols" };
    pub const font_size_point: u8 = 15;
    pub const cell_width_ratio: f32 = 1.0;
    pub const line_height_ratio: f32 = 1.1;
    pub const theme: []const u8 = "Tilda";
    /// host 의 `resolveShell` 이 `$SHELL` env 가 비어있을 때 쓰는 fallback.
    /// 첫 실행 시 host 는 `$SHELL` (있으면) 또는 이 값을 disk JSON 에 명시.
    pub const shell: []const u8 = "/bin/bash";
    pub const hotkey: []const u8 = "f1";
    pub const auto_start: bool = true;
    pub const hidden_start: bool = false;
    pub const max_scroll_lines: u32 = 100_000;
};

/// `Defaults` + host 가 첫-실행 시 결정한 `shell_resolved` 로부터 JSON 템플릿
/// 생성. 첫 실행 시 디스크 (`%APPDATA%\tildaz\config.json` 등) 에 저장 +
/// schema 검증 (`validateStructure`) ground truth. Caller 는 반환 slice 를 free.
///
/// `shell_resolved` 는 host 의 `resolveShell` 이 OS 환경에서 결정한 값:
///   - Windows: 항상 `Defaults.shell` (= `cmd.exe`).
///   - macOS: `$SHELL` env 가 있으면 그 값, 없으면 `Defaults.shell` (= `/bin/bash`).
/// 이렇게 disk 에 명시값으로 적어두면 이후 실행은 disk 그대로 사용 — host 의
/// runtime fallback 분기 없음 (config 가 단일 source of truth).
pub fn defaultConfigJson(
    allocator: std.mem.Allocator,
    shell_resolved: []const u8,
) ![]const u8 {
    var fb_buf: [1024]u8 = undefined;
    var fb_fbs = std.io.fixedBufferStream(&fb_buf);
    const fw = fb_fbs.writer();
    try fw.writeAll("[");
    for (Defaults.glyph_fallback, 0..) |f, i| {
        if (i > 0) try fw.writeAll(", ");
        try fw.print("\"{s}\"", .{f});
    }
    try fw.writeAll("]");
    const glyph_fallback_json = fb_fbs.getWritten();

    return try std.fmt.allocPrint(allocator,
        \\{{
        \\  "window": {{
        \\    "dock_position": "{s}",
        \\    "width_percent": {d:.1},
        \\    "height_percent": {d:.1},
        \\    "offset_percent": {d:.1},
        \\    "opacity_percent": {d:.1}
        \\  }},
        \\  "font": {{
        \\    "family": "{s}",
        \\    "glyph_fallback": {s},
        \\    "size_point": {d},
        \\    "cell_width_ratio": {d:.1},
        \\    "line_height_ratio": {d:.1}
        \\  }},
        \\  "theme": "{s}",
        \\  "shell": "{s}",
        \\  "hotkey": "{s}",
        \\  "auto_start": {},
        \\  "hidden_start": {},
        \\  "max_scroll_lines": {d}
        \\}}
        \\
    , .{
        Defaults.dock_position,
        Defaults.width_percent,
        Defaults.height_percent,
        Defaults.offset_percent,
        Defaults.opacity_percent,
        Defaults.font_family,
        glyph_fallback_json,
        Defaults.font_size_point,
        Defaults.cell_width_ratio,
        Defaults.line_height_ratio,
        Defaults.theme,
        shell_resolved,
        Defaults.hotkey,
        Defaults.auto_start,
        Defaults.hidden_start,
        Defaults.max_scroll_lines,
    });
}

// `Defaults` 의 string / float 값을 Config struct 가 보관하는 native type 으로
// 변환 (DockPosition enum / Hotkey struct / Theme pointer / alpha u8).
const default_dock_position: DockPosition = DockPosition.fromString(Defaults.dock_position) orelse unreachable;
/// JSON 은 percent (0..100, f32), 메모리는 alpha (0..255 u8). `100.0` percent → `255` alpha.
const default_opacity_alpha: u8 = @intFromFloat(@round(Defaults.opacity_percent * 255.0 / 100.0));
const default_theme: ?*const themes.Theme = themes.findTheme(Defaults.theme);
const default_hotkey: Hotkey = Hotkey.fromString(Defaults.hotkey) orelse unreachable;
const default_font_size_point: u8 = Defaults.font_size_point;
const default_cell_width_ratio: f32 = Defaults.cell_width_ratio;
const default_line_height_ratio: f32 = Defaults.line_height_ratio;
const default_shell: []const u8 = Defaults.shell;
/// Internal chain = primary (Defaults.font_family) + glyph_fallback. parse 후
/// `Config.font_families` 도 같은 의미 — chain[0] 은 primary, chain[1..] 은
/// glyph fallback. host / renderer 가 보는 인터페이스는 합친 chain 한 개.
const DEFAULT_FONT_CHAIN_COUNT: u8 = @intCast(1 + Defaults.glyph_fallback.len);

fn defaultFontFamiliesArray() [MAX_FONT_FAMILIES][]const u8 {
    var arr: [MAX_FONT_FAMILIES][]const u8 = undefined;
    arr[0] = Defaults.font_family;
    for (Defaults.glyph_fallback, 0..) |fb, i| arr[i + 1] = fb;
    var i: usize = 1 + Defaults.glyph_fallback.len;
    while (i < MAX_FONT_FAMILIES) : (i += 1) arr[i] = "";
    return arr;
}

pub const Config = struct {
    dock_position: DockPosition = default_dock_position,
    /// 화면 가로 점유율 percent (1..100, f32). 실수 허용 — 세밀 조정용.
    width_percent: f32 = Defaults.width_percent,
    height_percent: f32 = Defaults.height_percent,
    offset_percent: f32 = Defaults.offset_percent,
    /// memory 0..255 alpha. JSON `window.opacity_percent` (0..100, f32) → parse
    /// 시 alpha 로 매핑. memory 표현은 host 의 native API (NSWindow.alphaValue,
    /// SetLayeredWindowAttributes) 가 byte alpha 사용해 그 형식 그대로 보관.
    opacity_alpha: u8 = default_opacity_alpha,
    theme: ?*const themes.Theme = default_theme,
    hotkey: Hotkey = default_hotkey,
    /// Shell path. 첫 실행 시 host 의 `resolveShell` 이 결정한 값으로 disk 에
    /// 명시되며, 이후 실행은 disk 의 명시값을 그대로 읽음 (runtime fallback
    /// 분기 없음). 빈 문자열은 허용하지 않음 — `shell_validate` 가 잡음.
    shell: []const u8 = default_shell,
    auto_start: bool = Defaults.auto_start,
    hidden_start: bool = Defaults.hidden_start,
    max_scroll_lines: u32 = Defaults.max_scroll_lines,
    /// font size in typographic point (8..72). host 가 DPI scale 곱해 raster.
    font_size_point: u8 = default_font_size_point,
    /// cell width ratio — 측정된 advance 에 곱해 글자 사이 padding 조절. 1.0
    /// = 폰트 그대로, 1.1 = 10% 넓음. range 0.5..2.0.
    cell_width_ratio: f32 = default_cell_width_ratio,
    /// line height ratio — 측정된 ascent+descent+leading 에 곱해 줄 높이 조절.
    line_height_ratio: f32 = default_line_height_ratio,
    /// chain = primary + glyph_fallback (parse 후 합쳐짐). chain[0] 은 primary,
    /// chain[1..] 은 glyph fallback 순서. host / renderer 가 한 개의 array 로 받음.
    font_families: [MAX_FONT_FAMILIES][]const u8 = defaultFontFamiliesArray(),
    font_family_count: u8 = DEFAULT_FONT_CHAIN_COUNT,

    /// `shell_resolved` 는 host 의 `resolveShell` 결과 (process lifetime 보유).
    /// 첫 실행이거나 disk 를 못 읽을 때 memory default `Config.shell` 도 이
    /// 값으로 sync. disk 명시값이 있으면 그 값 그대로 (parse 가 alloc.dupe).
    pub fn load(allocator: std.mem.Allocator, shell_resolved: []const u8) Config {
        const path = paths.configPath(allocator) catch {
            var c: Config = .{};
            c.shell = shell_resolved;
            return c;
        };
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch {
            createDefault(allocator, path, shell_resolved);
            var c: Config = .{};
            c.shell = shell_resolved;
            return c;
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 64 * 1024) catch {
            var c: Config = .{};
            c.shell = shell_resolved;
            return c;
        };
        defer allocator.free(content);

        return parse(allocator, content);
    }

    fn parse(allocator: std.mem.Allocator, content: []const u8) Config {
        var config = Config{};
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch |err| {
            const path_buf = paths.configPath(allocator) catch null;
            defer if (path_buf) |p| allocator.free(p);
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                messages.config_parse_failed_format,
                .{ path_buf orelse "(unknown)", @errorName(err) },
            ) catch messages.config_parse_failed_fallback_msg;
            dialog.showFatal(messages.config_error_title, msg);
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) showConfigFatalMsg(messages.config_top_level_must_be_object_msg);

        // font.family / font.glyph_fallback 의 type 만 우선 사전 체크 —
        // validateStructure 의 일반 missing-key / type-mismatch 메시지보다 schema
        // 의도 (primary single string + glyph fallback list) 를 명확히 안내.
        if (root == .object) {
            if (root.object.get("font")) |fv_pre| {
                if (fv_pre == .object) {
                    if (fv_pre.object.get("family")) |fam_v| {
                        if (fam_v != .string) font_validate.showFamilyMustBeStringFatal();
                    }
                    if (fv_pre.object.get("glyph_fallback")) |fb_v| {
                        if (fb_v != .array) font_validate.showGlyphFallbackMustBeListFatal();
                        for (fb_v.array.items) |item| {
                            if (item != .string) font_validate.showGlyphFallbackMustBeListFatal();
                        }
                    }
                }
            }
        }

        // Schema 검증 — `defaultConfigJson` 과 비교 (key set + nested 구조 + type).
        // shell 인자는 schema 검증 시 *값* 무관 — `Defaults.shell` 한 번 사용.
        const default_json = defaultConfigJson(allocator, Defaults.shell) catch unreachable;
        defer allocator.free(default_json);
        var default_parsed = std.json.parseFromSlice(std.json.Value, allocator, default_json, .{}) catch unreachable;
        defer default_parsed.deinit();
        validateStructure(root, default_parsed.value, "(top-level)");

        // window section
        if (root.object.get("window")) |wv| {
            if (wv.object.get("dock_position")) |v| {
                if (DockPosition.fromString(v.string)) |dp| {
                    config.dock_position = dp;
                } else {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(
                        &buf,
                        messages.config_dock_position_invalid_format,
                        .{v.string},
                    ) catch messages.config_dock_position_invalid_fallback_msg;
                    dialog.showFatal(messages.config_error_title, msg);
                }
            }
            if (wv.object.get("width_percent")) |v| {
                const f = parseFloat(v) orelse showConfigFatal(messages.config_field_number_required_format, .{"window.width_percent"});
                if (f < 1.0 or f > 100.0) showConfigFatal(messages.config_field_range_required_format, .{ "window.width_percent", "1..100" });
                config.width_percent = f;
            }
            if (wv.object.get("height_percent")) |v| {
                const f = parseFloat(v) orelse showConfigFatal(messages.config_field_number_required_format, .{"window.height_percent"});
                if (f < 1.0 or f > 100.0) showConfigFatal(messages.config_field_range_required_format, .{ "window.height_percent", "1..100" });
                config.height_percent = f;
            }
            if (wv.object.get("offset_percent")) |v| {
                const f = parseFloat(v) orelse showConfigFatal(messages.config_field_number_required_format, .{"window.offset_percent"});
                if (f < 0.0 or f > 100.0) showConfigFatal(messages.config_field_range_required_format, .{ "window.offset_percent", "0..100" });
                config.offset_percent = f;
            }
            if (wv.object.get("opacity_percent")) |v| {
                const f = parseFloat(v) orelse showConfigFatal(messages.config_field_number_required_format, .{"window.opacity_percent"});
                if (f < 0.0 or f > 100.0) showConfigFatal(messages.config_field_range_required_format, .{ "window.opacity_percent", "0..100" });
                config.opacity_alpha = @intFromFloat(@round(f * 255.0 / 100.0));
            }
        }

        // theme
        if (root.object.get("theme")) |v| {
            if (v.string.len > 0) {
                config.theme = themes.findTheme(v.string);
                if (config.theme == null) {
                    var buf: [512]u8 = undefined;
                    var fbs = std.io.fixedBufferStream(&buf);
                    const w = fbs.writer();
                    w.print(messages.config_unknown_theme_header_format, .{v.string}) catch {};
                    for (themes.themes, 0..) |t, i| {
                        if (i > 0) w.writeAll(", ") catch {};
                        w.writeAll(t.name) catch {};
                    }
                    dialog.showFatal(messages.config_error_title, fbs.getWritten());
                }
            }
        }

        // hotkey
        if (root.object.get("hotkey")) |v| {
            if (Hotkey.fromString(v.string)) |h| {
                config.hotkey = h;
            } else {
                var buf: [384]u8 = undefined;
                const msg = std.fmt.bufPrint(
                    &buf,
                    messages.config_hotkey_invalid_format,
                    .{v.string},
                ) catch messages.config_hotkey_invalid_fallback_msg;
                dialog.showFatal(messages.config_error_title, msg);
            }
        }

        // shell
        if (root.object.get("shell")) |v| {
            if (v.string.len > 0) {
                config.shell = allocator.dupe(u8, v.string) catch v.string;
            } else {
                config.shell = "";
            }
        }

        // auto_start / hidden_start
        if (root.object.get("auto_start")) |v| config.auto_start = v.bool;
        if (root.object.get("hidden_start")) |v| config.hidden_start = v.bool;

        // max_scroll_lines
        if (root.object.get("max_scroll_lines")) |v| {
            if (v.integer < 100 or v.integer > 10_000_000) {
                showConfigFatal(messages.config_field_integer_range_required_format, .{ "max_scroll_lines", "100..10_000_000" });
            }
            config.max_scroll_lines = @intCast(v.integer);
        }

        // font section — schema validateStructure 로 family / size_point /
        // cell_width_ratio / line_height_ratio 모두 required + type 검증 끝남.
        // 여기서는 value range + parse.
        const fv = root.object.get("font").?;
        if (fv.object.get("size_point")) |v| {
            if (v.integer < 8 or v.integer > 72) {
                showConfigFatal(messages.config_field_integer_range_required_format, .{ "font.size_point", "8..72" });
            }
            config.font_size_point = @intCast(v.integer);
        }
        if (fv.object.get("cell_width_ratio")) |v| {
            const f = parseFloat(v) orelse showConfigFatal(messages.config_field_number_required_format, .{"font.cell_width_ratio"});
            if (f < 0.5 or f > 2.0) showConfigFatal(messages.config_field_range_required_format, .{ "font.cell_width_ratio", "0.5..2.0" });
            config.cell_width_ratio = f;
        }
        if (fv.object.get("line_height_ratio")) |v| {
            const f = parseFloat(v) orelse showConfigFatal(messages.config_field_number_required_format, .{"font.line_height_ratio"});
            if (f < 0.5 or f > 2.0) showConfigFatal(messages.config_field_range_required_format, .{ "font.line_height_ratio", "0.5..2.0" });
            config.line_height_ratio = f;
        }
        // font.family — primary, single string. type 은 사전 체크에서 이미
        // 보장됨 (위 font_validate.showFamilyMustBeStringFatal). 여기서는 빈
        // 문자열만 reject + chain[0] 에 저장.
        var chain_count: usize = 0;
        if (fv.object.get("family")) |v| {
            if (v.string.len == 0) showConfigFatalMsg(messages.config_font_family_empty_msg);
            config.font_families[0] = allocator.dupe(u8, v.string) catch v.string;
            chain_count = 1;
        }

        // font.glyph_fallback — array of strings. type / element 모두 사전
        // 체크 보장. 빈 array 는 허용 (system fallback 만 의존). chain[1..] 에
        // 저장. chain 총 길이 (1 + fallback) 가 MAX_FONT_FAMILIES 초과 시 fatal —
        // silent truncate 방지.
        if (fv.object.get("glyph_fallback")) |v| {
            for (v.array.items) |item| {
                if (item.string.len == 0) continue;
                if (chain_count >= MAX_FONT_FAMILIES) {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(
                        &buf,
                        messages.config_font_chain_too_long_format,
                        .{MAX_FONT_FAMILIES},
                    ) catch messages.config_font_chain_too_long_fallback_msg;
                    dialog.showFatal(messages.config_error_title, msg);
                }
                config.font_families[chain_count] = allocator.dupe(u8, item.string) catch item.string;
                chain_count += 1;
            }
        }

        var i = chain_count;
        while (i < MAX_FONT_FAMILIES) : (i += 1) config.font_families[i] = "";
        config.font_family_count = @intCast(chain_count);

        return config;
    }

    fn createDefault(allocator: std.mem.Allocator, path: []const u8, shell_resolved: []const u8) void {
        const file = std.fs.createFileAbsolute(path, .{}) catch return;
        defer file.close();
        const json_text = defaultConfigJson(allocator, shell_resolved) catch return;
        defer allocator.free(json_text);
        file.writeAll(json_text) catch {};
    }

    pub fn deinit(self: *const Config) void {
        _ = self;
        // Process exit 시 OS 가 모든 메모리 회수 — host loop 종료 후 명시적
        // free 불필요. 명확한 leak 만 막기 위해 함수 자체는 유지 (host 가 호출
        // 해도 no-op).
    }

    /// Windows 만 사용하는 helper — UTF-8 `font_families[index]` 를 Win32 가
    /// 받는 UTF-16 null-terminated string 으로 변환. chain entry 별 별도 static
    /// buffer 라 process 전체 lifetime 동안 안정적인 포인터 (호출처가 보관해도
    /// 안전). DWriteFontContext / 검증 loop 가 이 포인터를 들고 있어도 OK.
    ///
    /// 이전 버전은 6 개 hardcoded 폰트 이름만 if-eql 로 인식하고 그 외엔 모두
    /// `"Consolas"` literal 반환 — 사용자가 `"JetBrains Mono"` 같은 일반 코딩
    /// 폰트를 적어도 시스템에 설치되어 있는지와 무관하게 결과는 Consolas. 같은
    /// 패턴이 `windowsShellUtf16` 에도 있었고 commit `836fe97` 에서 fix. font 도 같이.
    pub fn windowsFontFamilyUtf16(self: *const Config, index: u8) [*:0]const WCHAR {
        if (!is_windows) @compileError("windowsFontFamilyUtf16 is Windows-only");
        const S = struct {
            var bufs: [MAX_FONT_FAMILIES][512]u16 = undefined;
        };
        if (index >= self.font_family_count or index >= MAX_FONT_FAMILIES) {
            return std.unicode.utf8ToUtf16LeStringLiteral("Consolas");
        }
        const family = self.font_families[index];
        const buf = &S.bufs[index];
        const reserve_for_null = 1;
        const max_in = buf.len - reserve_for_null;
        const written = std.unicode.utf8ToUtf16Le(buf[0..max_in], family) catch {
            return std.unicode.utf8ToUtf16LeStringLiteral("Consolas");
        };
        buf[written] = 0;
        return buf[0..written :0].ptr;
    }

    /// Windows 만 — `config.shell` (UTF-8) 을 `CreateProcessW` 가 받는 UTF-16
    /// null-terminated string 으로 변환. 함수-local static buffer 에 한 번 변환
    /// 후 그 포인터 반환 — process 전체 lifetime. 단일 startup 콜만 가정 (host
    /// 가 SessionCore.init 에 한 번 넘김), 이후 SessionCore 가 그 포인터 보관.
    ///
    /// 이전 버전은 `_ = self;` + literal "cmd.exe" 만 반환해서 사용자가 config
    /// 의 `"shell"` 값을 바꿔도 적용 안 되는 사고 (시연 중 발견 — `"wsl.exe -d
    /// Debian --cd ~"` 무시되고 cmd 만 떴음).
    pub fn windowsShellUtf16(self: *const Config) [*:0]const WCHAR {
        if (!is_windows) @compileError("windowsShellUtf16 is Windows-only");
        const S = struct {
            var buf: [1024]u16 = undefined;
        };
        const reserve_for_null = 1;
        const max_in = S.buf.len - reserve_for_null;
        const written = std.unicode.utf8ToUtf16Le(S.buf[0..max_in], self.shell) catch {
            // 비정상 UTF-8 (JSON parser 가 이미 막지만 방어). cmd.exe 로 fallback —
            // 적어도 윈도우는 떠 있게.
            return std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe");
        };
        S.buf[written] = 0;
        return S.buf[0..written :0].ptr;
    }
};

// --- Helpers ---

fn parseFloat(v: std.json.Value) ?f32 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => null,
    };
}

fn showConfigFatalMsg(message: []const u8) noreturn {
    dialog.showFatal(messages.config_error_title, message);
}

fn showConfigFatal(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch messages.config_error_fallback_msg;
    dialog.showFatal(messages.config_error_title, msg);
}

/// user config 의 구조가 default config 와 일치하는지 재귀 검증:
/// - object: key set 일치 (missing / unknown 양방향) + 각 value 재귀
/// - 그 외 type: tag 일치 (integer ≠ float, string ≠ bool 등)
///
/// value range / 의미 검증은 caller (각 필드 별로 hardcoded — default 만으로는
/// "1..100" 같은 range 표현 불가).
fn validateStructure(user: std.json.Value, def: std.json.Value, ctx: []const u8) void {
    const user_tag = std.meta.activeTag(user);
    const def_tag = std.meta.activeTag(def);
    if (user_tag != def_tag) {
        const both_numeric = (user_tag == .integer or user_tag == .float) and
            (def_tag == .integer or def_tag == .float);
        if (!both_numeric) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                messages.config_type_mismatch_format,
                .{ ctx, @tagName(def_tag), @tagName(user_tag) },
            ) catch messages.config_type_mismatch_fallback_msg;
            dialog.showFatal(messages.config_error_title, msg);
        }
    }

    if (user_tag != .object) return;

    var def_iter = def.object.iterator();
    while (def_iter.next()) |entry| {
        const key = entry.key_ptr.*;
        if (user.object.get(key) == null) {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                messages.config_missing_key_format,
                .{ key, ctx },
            ) catch messages.config_missing_key_fallback_msg;
            dialog.showFatal(messages.config_error_title, msg);
        }
    }

    var user_iter = user.object.iterator();
    while (user_iter.next()) |entry| {
        const key = entry.key_ptr.*;
        if (def.object.get(key) == null) {
            // `_` prefix key 는 사용자 주석 — 알 수 없는 key 라도 무시 (#173).
            // JSON 표준 자체엔 주석 없지만 convention. schema 의 정식 key 는
            // 모두 `_` 안 붙으니 기존 검증과 충돌 X. type / 재귀 검사도 모두
            // skip — caller 가 자유로운 형식의 주석 사용 가능.
            if (key.len > 0 and key[0] == '_') continue;
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                messages.config_unknown_key_format,
                .{ key, ctx },
            ) catch messages.config_unknown_key_fallback_msg;
            dialog.showFatal(messages.config_error_title, msg);
        }
    }

    var rec_iter = def.object.iterator();
    while (rec_iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const u_val = user.object.get(key).?;
        var path_buf: [256]u8 = undefined;
        const path = if (std.mem.eql(u8, ctx, "(top-level)"))
            std.fmt.bufPrint(&path_buf, "{s}", .{key}) catch key
        else
            std.fmt.bufPrint(&path_buf, "{s}.{s}", .{ ctx, key }) catch key;
        validateStructure(u_val, entry.value_ptr.*, path);
    }
}

// --- Tests ---

test "DockPosition.fromString" {
    try std.testing.expectEqual(DockPosition.top, DockPosition.fromString("top").?);
    try std.testing.expectEqual(DockPosition.bottom, DockPosition.fromString("bottom").?);
    try std.testing.expectEqual(@as(?DockPosition, null), DockPosition.fromString("nope"));
}
