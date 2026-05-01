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

const DEFAULT_THEME = "Tilda";
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

const DEFAULT_HOTKEY: Hotkey = if (is_windows)
    .{ .vkey = 0x70, .modifiers = 0 }
else
    .{ .keycode = 0x7A, .modifiers = 0 };

// --- DEFAULT_CONFIG_JSON (per-OS) ---

/// Single source of truth — schema 의 키 / 중첩 구조 / value type 모두 이
/// 한 JSON 이 정의. Windows 와 macOS 는 default *값* 만 다름 (font.family /
/// font.size / cell_width / line_height / shell). schema 자체는 동일.
pub const DEFAULT_CONFIG_JSON: []const u8 = if (is_windows)
    \\{
    \\  "window": {
    \\    "dock_position": "top",
    \\    "width": 50,
    \\    "height": 100,
    \\    "offset": 100,
    \\    "opacity": 100
    \\  },
    \\  "font": {
    \\    "family": ["Cascadia Mono", "Malgun Gothic", "Segoe UI Symbol"],
    \\    "size": 19,
    \\    "cell_width": 1.1,
    \\    "line_height": 0.95
    \\  },
    \\  "theme": "Tilda",
    \\  "shell": "cmd.exe",
    \\  "hotkey": "f1",
    \\  "auto_start": true,
    \\  "hidden_start": false,
    \\  "max_scroll_lines": 100000
    \\}
    \\
else
    \\{
    \\  "window": {
    \\    "dock_position": "top",
    \\    "width": 50,
    \\    "height": 100,
    \\    "offset": 100,
    \\    "opacity": 100
    \\  },
    \\  "font": {
    \\    "family": ["Menlo"],
    \\    "size": 15,
    \\    "cell_width": 1.0,
    \\    "line_height": 1.1
    \\  },
    \\  "theme": "Tilda",
    \\  "shell": "",
    \\  "hotkey": "f1",
    \\  "auto_start": true,
    \\  "hidden_start": false,
    \\  "max_scroll_lines": 100000
    \\}
    \\
;

// --- Config struct ---

const default_font_size: u8 = if (is_windows) 19 else 15;
const default_cell_width: f32 = if (is_windows) 1.1 else 1.0;
const default_line_height: f32 = if (is_windows) 0.95 else 1.1;
const default_shell: []const u8 = if (is_windows) "cmd.exe" else "";

const DEFAULT_FONT_FAMILIES: []const []const u8 = if (is_windows)
    &[_][]const u8{ "Cascadia Mono", "Malgun Gothic", "Segoe UI Symbol" }
else
    &[_][]const u8{"Menlo"};

fn defaultFontFamiliesArray() [MAX_FONT_FAMILIES][]const u8 {
    var arr: [MAX_FONT_FAMILIES][]const u8 = undefined;
    for (DEFAULT_FONT_FAMILIES, 0..) |fam, i| arr[i] = fam;
    var i: usize = DEFAULT_FONT_FAMILIES.len;
    while (i < MAX_FONT_FAMILIES) : (i += 1) arr[i] = "";
    return arr;
}

pub const Config = struct {
    dock_position: DockPosition = .top,
    width: u8 = 50,
    height: u8 = 100,
    offset: u8 = 100,
    /// internal 0..255. JSON `window.opacity` 는 0..100 percent — parse 시 매핑.
    opacity: u8 = 255,
    theme: ?*const themes.Theme = themes.findTheme(DEFAULT_THEME),
    hotkey: Hotkey = DEFAULT_HOTKEY,
    /// Shell path. macOS 는 빈 문자열이면 host 가 `$SHELL` env / `/bin/zsh` fallback.
    /// Windows 는 default `cmd.exe`.
    shell: []const u8 = default_shell,
    auto_start: bool = true,
    hidden_start: bool = false,
    max_scroll_lines: u32 = 100_000,
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

    /// Windows 만 사용하는 helper — UTF-16 family name (Win32 CreateFontW 등).
    pub fn fontFamilyUtf16(self: *const Config, index: u8) [*:0]const WCHAR {
        if (!is_windows) @compileError("fontFamilyUtf16 is Windows-only");
        const family = if (index < self.font_family_count) self.font_families[index] else "Consolas";
        if (std.mem.eql(u8, family, "Consolas"))
            return std.unicode.utf8ToUtf16LeStringLiteral("Consolas");
        if (std.mem.eql(u8, family, "Cascadia Code"))
            return std.unicode.utf8ToUtf16LeStringLiteral("Cascadia Code");
        if (std.mem.eql(u8, family, "Cascadia Mono"))
            return std.unicode.utf8ToUtf16LeStringLiteral("Cascadia Mono");
        if (std.mem.eql(u8, family, "Segoe UI Symbol"))
            return std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI Symbol");
        if (std.mem.eql(u8, family, "Segoe UI Emoji"))
            return std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI Emoji");
        if (std.mem.eql(u8, family, "Malgun Gothic"))
            return std.unicode.utf8ToUtf16LeStringLiteral("Malgun Gothic");
        // 기타 — fallback 으로 Consolas. 진짜 dynamic UTF-16 변환은 host 가 별도.
        return std.unicode.utf8ToUtf16LeStringLiteral("Consolas");
    }

    /// Windows 만 — `shellUtf16` 변환은 windows_host 가 자체 처리. 여기는 raw 만.
    pub fn shellUtf16(self: *const Config) [*:0]const WCHAR {
        _ = self;
        if (!is_windows) @compileError("shellUtf16 is Windows-only");
        // 단순화 — windows_host 가 동적 변환 알아서 처리. 여긴 placeholder.
        return std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe");
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
