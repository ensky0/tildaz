// Cross-platform config.json schema + parser. Windows + macOS 같은 nested
// schema, default 만 OS-specific (font.family / font.size / shell / hotkey
// 등). DEFAULT_CONFIG_JSON 한 string 이 schema 의 single source — createDefault
// 가 그대로 파일에 저장 + parse 시 user config 와 비교 (`validateStructure`)
// 검증의 ground truth.
//
// 새 필드 추가 시 *DEFAULT_CONFIG_JSON 한 곳만* update 하면 required / unknown /
// type 검증 자동 sync. value range 만 별도 hardcoded.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const themes = @import("themes.zig");
const dialog = @import("dialog.zig");
const messages = @import("messages.zig");
const paths = @import("paths.zig");

const WCHAR = u16;

pub const MAX_FONT_FAMILIES = 8;

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
            .{ .name = "f1", .code = 0x70 },     .{ .name = "f2", .code = 0x71 },
            .{ .name = "f3", .code = 0x72 },     .{ .name = "f4", .code = 0x73 },
            .{ .name = "f5", .code = 0x74 },     .{ .name = "f6", .code = 0x75 },
            .{ .name = "f7", .code = 0x76 },     .{ .name = "f8", .code = 0x77 },
            .{ .name = "f9", .code = 0x78 },     .{ .name = "f10", .code = 0x79 },
            .{ .name = "f11", .code = 0x7A },    .{ .name = "f12", .code = 0x7B },
            .{ .name = "space", .code = 0x20 },
            .{ .name = "grave", .code = 0xC0 }, // VK_OEM_3
            .{ .name = "tab", .code = 0x09 },
            .{ .name = "escape", .code = 0x1B }, .{ .name = "esc", .code = 0x1B },
            .{ .name = "enter", .code = 0x0D }, .{ .name = "return", .code = 0x0D },
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
            .{ .name = "f1", .code = 0x7A },  .{ .name = "f2", .code = 0x78 },
            .{ .name = "f3", .code = 0x63 },  .{ .name = "f4", .code = 0x76 },
            .{ .name = "f5", .code = 0x60 },  .{ .name = "f6", .code = 0x61 },
            .{ .name = "f7", .code = 0x62 },  .{ .name = "f8", .code = 0x64 },
            .{ .name = "f9", .code = 0x65 },  .{ .name = "f10", .code = 0x6D },
            .{ .name = "f11", .code = 0x67 }, .{ .name = "f12", .code = 0x6F },
            .{ .name = "space", .code = 0x31 },
            .{ .name = "grave", .code = 0x32 }, .{ .name = "backquote", .code = 0x32 },
            .{ .name = "tab", .code = 0x30 },
            .{ .name = "return", .code = 0x24 }, .{ .name = "enter", .code = 0x24 },
            .{ .name = "escape", .code = 0x35 }, .{ .name = "esc", .code = 0x35 },
            // 알파벳 — kVK_ANSI_*
            .{ .name = "a", .code = 0x00 }, .{ .name = "b", .code = 0x0B },
            .{ .name = "c", .code = 0x08 }, .{ .name = "d", .code = 0x02 },
            .{ .name = "e", .code = 0x0E }, .{ .name = "f", .code = 0x03 },
            .{ .name = "g", .code = 0x05 }, .{ .name = "h", .code = 0x04 },
            .{ .name = "i", .code = 0x22 }, .{ .name = "j", .code = 0x26 },
            .{ .name = "k", .code = 0x28 }, .{ .name = "l", .code = 0x25 },
            .{ .name = "m", .code = 0x2E }, .{ .name = "n", .code = 0x2D },
            .{ .name = "o", .code = 0x1F }, .{ .name = "p", .code = 0x23 },
            .{ .name = "q", .code = 0x0C }, .{ .name = "r", .code = 0x0F },
            .{ .name = "s", .code = 0x01 }, .{ .name = "t", .code = 0x11 },
            .{ .name = "u", .code = 0x20 }, .{ .name = "v", .code = 0x09 },
            .{ .name = "w", .code = 0x0D }, .{ .name = "x", .code = 0x07 },
            .{ .name = "y", .code = 0x10 }, .{ .name = "z", .code = 0x06 },
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
//   (a) `DEFAULT_CONFIG_JSON` — `std.fmt.comptimePrint` 로 자동 생성. 첫 실행
//       시 디스크 (`%APPDATA%\tildaz\config.json` 등) 에 저장됨 + parse() 의
//       `validateStructure` 가 schema 검증 ground truth 로 사용.
//   (b) `Config` struct 의 field initializer 가 참조하는 `default_*` const 도
//       모두 같은 Defaults 에서 derive — disk 와 memory 가 자동 sync.
//
// 이전엔 JSON literal + `DEFAULT_FONT_FAMILIES` + `default_font_size` /
// `default_shell` 등 6+ 곳에 default 값이 흩어져 한쪽만 고치면 disk vs memory
// default 가 어긋나는 잠재 버그.
// =============================================================================

const Defaults = if (is_windows) struct {
    pub const dock_position: []const u8 = "top";
    pub const width: u8 = 50;
    pub const height: u8 = 100;
    pub const offset: u8 = 100;
    /// JSON 은 0..100 percent. 메모리 alpha (0..255) 변환은 default_opacity_alpha 가 처리.
    pub const opacity_pct: u8 = 100;
    pub const font_family: []const []const u8 = &.{"Cascadia Code"};
    pub const font_size: u8 = 19;
    pub const cell_width: f32 = 1.1;
    pub const line_height: f32 = 0.95;
    pub const theme: []const u8 = "Tilda";
    pub const shell: []const u8 = "cmd.exe";
    pub const hotkey: []const u8 = "f1";
    pub const auto_start: bool = true;
    pub const hidden_start: bool = false;
    pub const max_scroll_lines: u32 = 100_000;
} else struct {
    pub const dock_position: []const u8 = "top";
    pub const width: u8 = 50;
    pub const height: u8 = 100;
    pub const offset: u8 = 100;
    pub const opacity_pct: u8 = 100;
    pub const font_family: []const []const u8 = &.{"Menlo"};
    pub const font_size: u8 = 15;
    pub const cell_width: f32 = 1.0;
    pub const line_height: f32 = 1.1;
    pub const theme: []const u8 = "Tilda";
    /// 빈 문자열 = host 가 `$SHELL` env / `/bin/zsh` fallback.
    pub const shell: []const u8 = "";
    pub const hotkey: []const u8 = "f1";
    pub const auto_start: bool = true;
    pub const hidden_start: bool = false;
    pub const max_scroll_lines: u32 = 100_000;
};

/// `Defaults` 로부터 자동 생성된 JSON 템플릿. 첫 실행 시 디스크에 저장 + schema
/// 검증 (`validateStructure`) ground truth.
pub const DEFAULT_CONFIG_JSON: []const u8 = blk: {
    @setEvalBranchQuota(100_000);
    // font.family JSON array literal — comptime concat.
    var family_json: []const u8 = "[";
    for (Defaults.font_family, 0..) |f, i| {
        if (i > 0) family_json = family_json ++ ", ";
        family_json = family_json ++ "\"" ++ f ++ "\"";
    }
    family_json = family_json ++ "]";
    break :blk std.fmt.comptimePrint(
        \\{{
        \\  "window": {{
        \\    "dock_position": "{s}",
        \\    "width": {d},
        \\    "height": {d},
        \\    "offset": {d},
        \\    "opacity": {d}
        \\  }},
        \\  "font": {{
        \\    "family": {s},
        \\    "size": {d},
        \\    "cell_width": {d},
        \\    "line_height": {d}
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
        Defaults.width,
        Defaults.height,
        Defaults.offset,
        Defaults.opacity_pct,
        family_json,
        Defaults.font_size,
        Defaults.cell_width,
        Defaults.line_height,
        Defaults.theme,
        Defaults.shell,
        Defaults.hotkey,
        Defaults.auto_start,
        Defaults.hidden_start,
        Defaults.max_scroll_lines,
    });
};

// `Defaults` 의 string / int 값을 Config struct 가 보관하는 native type 으로
// 변환 (DockPosition enum / Hotkey struct / Theme pointer / alpha u8).
const default_dock_position: DockPosition = DockPosition.fromString(Defaults.dock_position) orelse unreachable;
/// JSON 은 percent (0..100), 메모리는 alpha (0..255). `100` percent → `255` alpha.
const default_opacity_alpha: u8 = @intCast(@as(u32, Defaults.opacity_pct) * 255 / 100);
const default_theme: ?*const themes.Theme = themes.findTheme(Defaults.theme);
const default_hotkey: Hotkey = Hotkey.fromString(Defaults.hotkey) orelse unreachable;
const default_font_size: u8 = Defaults.font_size;
const default_cell_width: f32 = Defaults.cell_width;
const default_line_height: f32 = Defaults.line_height;
const default_shell: []const u8 = Defaults.shell;
const DEFAULT_FONT_FAMILIES: []const []const u8 = Defaults.font_family;

fn defaultFontFamiliesArray() [MAX_FONT_FAMILIES][]const u8 {
    var arr: [MAX_FONT_FAMILIES][]const u8 = undefined;
    for (DEFAULT_FONT_FAMILIES, 0..) |fam, i| arr[i] = fam;
    var i: usize = DEFAULT_FONT_FAMILIES.len;
    while (i < MAX_FONT_FAMILIES) : (i += 1) arr[i] = "";
    return arr;
}

pub const Config = struct {
    dock_position: DockPosition = default_dock_position,
    width: u8 = Defaults.width,
    height: u8 = Defaults.height,
    offset: u8 = Defaults.offset,
    /// internal 0..255 alpha. JSON `window.opacity` 는 0..100 percent — parse 시 매핑.
    opacity: u8 = default_opacity_alpha,
    theme: ?*const themes.Theme = default_theme,
    hotkey: Hotkey = default_hotkey,
    /// Shell path. macOS 는 빈 문자열이면 host 가 `$SHELL` env / `/bin/zsh` fallback.
    /// Windows 는 default `cmd.exe`.
    shell: []const u8 = default_shell,
    auto_start: bool = Defaults.auto_start,
    hidden_start: bool = Defaults.hidden_start,
    max_scroll_lines: u32 = Defaults.max_scroll_lines,
    font_size: u8 = default_font_size,
    /// cell width scale (was `cell_width` on Windows / `cell_width_scale` on macOS).
    cell_width: f32 = default_cell_width,
    /// line height scale (was `line_height` on Windows / `line_height_scale` on macOS).
    line_height: f32 = default_line_height,
    font_families: [MAX_FONT_FAMILIES][]const u8 = defaultFontFamiliesArray(),
    font_family_count: u8 = DEFAULT_FONT_FAMILIES.len,

    pub fn load(allocator: std.mem.Allocator) Config {
        const path = paths.configPath(allocator) catch return .{};
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch {
            createDefault(path);
            return .{};
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 64 * 1024) catch return .{};
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
                "config.json parse failed: {s}\n\nPath: {s}",
                .{ @errorName(err), path_buf orelse "(unknown)" },
            ) catch "config.json parse failed";
            dialog.showFatal(messages.config_error_title, msg);
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) dialog.showFatal(messages.config_error_title, "config.json: top-level must be a JSON object.");

        // Schema 검증 — DEFAULT_CONFIG_JSON 과 비교 (key set + nested 구조 + type).
        var default_parsed = std.json.parseFromSlice(std.json.Value, allocator, DEFAULT_CONFIG_JSON, .{}) catch unreachable;
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
                        "config.json: unknown \"window.dock_position\" value \"{s}\".\n\nAllowed: top, bottom, left, right",
                        .{v.string},
                    ) catch "config.json: window.dock_position invalid";
                    dialog.showFatal(messages.config_error_title, msg);
                }
            }
            if (wv.object.get("width")) |v| {
                if (v.integer < 1 or v.integer > 100) {
                    dialog.showFatal(messages.config_error_title, "config.json: \"window.width\" must be an integer in 1..100.");
                }
                config.width = @intCast(v.integer);
            }
            if (wv.object.get("height")) |v| {
                if (v.integer < 1 or v.integer > 100) {
                    dialog.showFatal(messages.config_error_title, "config.json: \"window.height\" must be an integer in 1..100.");
                }
                config.height = @intCast(v.integer);
            }
            if (wv.object.get("offset")) |v| {
                if (v.integer < 0 or v.integer > 100) {
                    dialog.showFatal(messages.config_error_title, "config.json: \"window.offset\" must be an integer in 0..100.");
                }
                config.offset = @intCast(v.integer);
            }
            if (wv.object.get("opacity")) |v| {
                if (v.integer < 0 or v.integer > 100) {
                    dialog.showFatal(messages.config_error_title, "config.json: \"window.opacity\" must be an integer in 0..100 (percent).");
                }
                config.opacity = @intCast(@divFloor(v.integer * 255, 100));
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
                    w.print("config.json: unknown theme \"{s}\"\n\nAvailable themes:\n", .{v.string}) catch {};
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
                    "config.json: failed to parse \"hotkey\" value \"{s}\".\n\nExamples: \"f1\", \"ctrl+space\", \"shift+cmd+t\"",
                    .{v.string},
                ) catch "config.json: hotkey invalid";
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
                dialog.showFatal(messages.config_error_title, "config.json: \"max_scroll_lines\" must be an integer in 100..10_000_000.");
            }
            config.max_scroll_lines = @intCast(v.integer);
        }

        // font section — schema validateStructure 로 family / size / cell_width /
        // line_height 모두 required + type 검증 끝남. 여기서는 value range + parse.
        const fv = root.object.get("font").?;
        if (fv.object.get("size")) |v| {
            if (v.integer < 8 or v.integer > 72) {
                dialog.showFatal(messages.config_error_title, "config.json: \"font.size\" must be an integer in 8..72.");
            }
            config.font_size = @intCast(v.integer);
        }
        if (fv.object.get("cell_width")) |v| {
            const f = parseFloat(v) orelse dialog.showFatal(messages.config_error_title, "config.json: \"font.cell_width\" must be a number.");
            if (f < 0.5 or f > 2.0) dialog.showFatal(messages.config_error_title, "config.json: \"font.cell_width\" must be in 0.5..2.0.");
            config.cell_width = f;
        }
        if (fv.object.get("line_height")) |v| {
            const f = parseFloat(v) orelse dialog.showFatal(messages.config_error_title, "config.json: \"font.line_height\" must be a number.");
            if (f < 0.5 or f > 2.0) dialog.showFatal(messages.config_error_title, "config.json: \"font.line_height\" must be in 0.5..2.0.");
            config.line_height = f;
        }
        if (fv.object.get("family")) |v| {
            var count: usize = 0;
            if (v == .string) {
                if (v.string.len == 0) dialog.showFatal(messages.config_error_title, "config.json: \"font.family\" must not be empty.");
                config.font_families[0] = allocator.dupe(u8, v.string) catch v.string;
                count = 1;
            } else if (v == .array) {
                if (v.array.items.len == 0) dialog.showFatal(messages.config_error_title, "config.json: \"font.family\" array must not be empty.");
                for (v.array.items) |item| {
                    if (count >= MAX_FONT_FAMILIES) break;
                    if (item != .string) dialog.showFatal(messages.config_error_title, "config.json: \"font.family\" array elements must be strings.");
                    if (item.string.len == 0) continue;
                    config.font_families[count] = allocator.dupe(u8, item.string) catch item.string;
                    count += 1;
                }
                if (count == 0) dialog.showFatal(messages.config_error_title, "config.json: \"font.family\" must contain at least one non-empty string.");
            } else {
                dialog.showFatal(messages.config_error_title, "config.json: \"font.family\" must be a string or an array of strings.");
            }
            var i = count;
            while (i < MAX_FONT_FAMILIES) : (i += 1) config.font_families[i] = "";
            config.font_family_count = @intCast(count);
        }

        return config;
    }

    fn createDefault(path: []const u8) void {
        const file = std.fs.createFileAbsolute(path, .{}) catch return;
        defer file.close();
        file.writeAll(DEFAULT_CONFIG_JSON) catch {};
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
    /// 패턴이 `shellUtf16` 에도 있었고 commit `836fe97` 에서 fix. font 도 같이.
    pub fn fontFamilyUtf16(self: *const Config, index: u8) [*:0]const WCHAR {
        if (!is_windows) @compileError("fontFamilyUtf16 is Windows-only");
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
    pub fn shellUtf16(self: *const Config) [*:0]const WCHAR {
        if (!is_windows) @compileError("shellUtf16 is Windows-only");
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
                "config.json: type mismatch at \"{s}\" — expected {s}, got {s}.",
                .{ ctx, @tagName(def_tag), @tagName(user_tag) },
            ) catch "config.json: type mismatch";
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
                "config.json: missing required key \"{s}\" in {s}.",
                .{ key, ctx },
            ) catch "config.json: missing key";
            dialog.showFatal(messages.config_error_title, msg);
        }
    }

    var user_iter = user.object.iterator();
    while (user_iter.next()) |entry| {
        const key = entry.key_ptr.*;
        if (def.object.get(key) == null) {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "config.json: unknown key \"{s}\" in {s}.",
                .{ key, ctx },
            ) catch "config.json: unknown key";
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
