// macOS mini config — `~/.config/tildaz/config.json` (XDG, ghostty/alacritty
// 와 같은 패턴). 구버전 (`~/Library/Application Support/tildaz/`) 에 파일이
// 있고 신규 위치에 없으면 자동 1회 마이그레이션 (#128).
//
// `src/config.zig` 와 schema 는 같게 (`dock_position` / `width` / `height` /
// `offset` 같은 필드명) 두지만 platform-leak 정리 (`Window.DockPosition` 의존)
// 가 안 끝나서 통합은 후속 milestone 으로 미루고 macOS 는 일단 자기 모듈을
// 쓴다 — #108 M3.5. 에러 표시는 cross-platform `dialog.showFatal` 사용.
//
// schema:
//   {
//     "dock_position": "top" | "bottom" | "left" | "right",
//     "width": 1..100,
//     "height": 1..100,
//     "offset": 0..100,
//     "hotkey": "f1" | "cmd+space" | "ctrl+grave" | ...
//   }
//
// 잘못된 값은 stderr 안내 + default 로 fallback. 첫 실행 시 default config
// 자동 생성.

const std = @import("std");
const dialog = @import("dialog.zig");
const messages = @import("messages.zig");
const themes = @import("themes.zig");
const paths = @import("paths.zig");

const DEFAULT_THEME = "Tilda";

pub const DockPosition = enum {
    top,
    bottom,
    left,
    right,

    fn fromString(s: []const u8) ?DockPosition {
        if (std.mem.eql(u8, s, "top")) return .top;
        if (std.mem.eql(u8, s, "bottom")) return .bottom;
        if (std.mem.eql(u8, s, "left")) return .left;
        if (std.mem.eql(u8, s, "right")) return .right;
        return null;
    }
};

/// CGEventTap 이 받는 modifier mask (CGEventTypes.h).
const kCGEventFlagMaskCommand: u64 = 0x00100000;
const kCGEventFlagMaskShift: u64 = 0x00020000;
const kCGEventFlagMaskAlternate: u64 = 0x00080000; // Option
const kCGEventFlagMaskControl: u64 = 0x00040000;

pub const Hotkey = struct {
    keycode: u32,
    modifiers: u64,

    /// "f1", "cmd+space", "ctrl+grave", "shift+cmd+t" 같은 string 을 keycode +
    /// modifier 로 변환. 알 수 없는 토큰이면 null. macOS `Events.h` 의
    /// `kVK_*` 와 CGEventFlags 매핑.
    fn fromString(s: []const u8) ?Hotkey {
        var modifiers: u64 = 0;
        var keycode: ?u32 = null;

        var iter = std.mem.tokenizeScalar(u8, s, '+');
        while (iter.next()) |raw| {
            // 트림 + 소문자 — std.mem 에 직접 lower 가 없어 buf 에 복사.
            var buf: [16]u8 = undefined;
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (trimmed.len == 0 or trimmed.len > buf.len) return null;
            for (trimmed, 0..) |c, i| buf[i] = std.ascii.toLower(c);
            const tok = buf[0..trimmed.len];

            if (modifierFromToken(tok)) |m| {
                modifiers |= m;
            } else if (keycodeFromToken(tok)) |kc| {
                if (keycode != null) return null; // 키는 하나만.
                keycode = kc;
            } else {
                return null;
            }
        }

        return .{ .keycode = keycode orelse return null, .modifiers = modifiers };
    }

    fn modifierFromToken(tok: []const u8) ?u64 {
        if (std.mem.eql(u8, tok, "cmd") or std.mem.eql(u8, tok, "command")) return kCGEventFlagMaskCommand;
        if (std.mem.eql(u8, tok, "shift")) return kCGEventFlagMaskShift;
        if (std.mem.eql(u8, tok, "alt") or std.mem.eql(u8, tok, "option") or std.mem.eql(u8, tok, "opt")) return kCGEventFlagMaskAlternate;
        if (std.mem.eql(u8, tok, "ctrl") or std.mem.eql(u8, tok, "control")) return kCGEventFlagMaskControl;
        return null;
    }

    fn keycodeFromToken(tok: []const u8) ?u32 {
        const map = [_]struct { name: []const u8, code: u32 }{
            .{ .name = "f1", .code = 0x7A },
            .{ .name = "f2", .code = 0x78 },
            .{ .name = "f3", .code = 0x63 },
            .{ .name = "f4", .code = 0x76 },
            .{ .name = "f5", .code = 0x60 },
            .{ .name = "f6", .code = 0x61 },
            .{ .name = "f7", .code = 0x62 },
            .{ .name = "f8", .code = 0x64 },
            .{ .name = "f9", .code = 0x65 },
            .{ .name = "f10", .code = 0x6D },
            .{ .name = "f11", .code = 0x67 },
            .{ .name = "f12", .code = 0x6F },
            .{ .name = "space", .code = 0x31 },
            .{ .name = "grave", .code = 0x32 }, // backquote `
            .{ .name = "backquote", .code = 0x32 },
            .{ .name = "tab", .code = 0x30 },
            .{ .name = "return", .code = 0x24 },
            .{ .name = "enter", .code = 0x24 },
            .{ .name = "escape", .code = 0x35 },
            .{ .name = "esc", .code = 0x35 },
            // 숫자/알파벳 — 자주 쓰는 것만.
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
            if (std.mem.eql(u8, tok, entry.name)) return entry.code;
        }
        return null;
    }
};

pub const Config = struct {
    dock_position: DockPosition = .top,
    width_pct: u8 = 50,
    height_pct: u8 = 100,
    offset_pct: u8 = 100,
    hotkey: Hotkey = .{ .keycode = 0x7A, .modifiers = 0 }, // F1
    /// 윈도우 불투명도 (internal 0..255). config json 의 `opacity` 는 0..100
    /// 퍼센트 — Windows config.zig 와 동일 의미. 100 = 완전 불투명, 0 = 완전
    /// 투명. parse 시 0..100 → 0..255 매핑.
    opacity: u8 = 255,
    /// 색상 테마 (foreground / background / 16-color ANSI palette). Windows
    /// config.zig 와 동일 — `themes.findTheme(name)` 결과. null 이면 ghostty
    /// default (사용자가 default 의도한 명시 없음 등 fallback).
    theme: ?*const themes.Theme = themes.findTheme(DEFAULT_THEME),

    /// 사용자 로그인 시 자동 실행 (LaunchAgent). Windows `auto_start` 동등.
    auto_start: bool = true,
    /// 부팅 시 윈도우 hidden 상태 — F1/hotkey 로 처음 toggle 할 때 첫 표시.
    /// Windows `hidden_start` 동등.
    hidden_start: bool = false,

    /// 파일이 없으면 default + 자동 생성. JSON 파싱 실패 / 필드 값 오류 발견 시
    /// `dialog.showFatal` 로 다이얼로그 띄우고 즉시 종료 (Windows host 와 동일
    /// 정책).
    pub fn load(allocator: std.mem.Allocator) Config {
        const path = paths.configPath(allocator) catch return .{};
        defer allocator.free(path);

        // 신규 위치에 파일 없으면 구버전 (`~/Library/Application Support/tildaz/`)
        // 에서 1회 마이그레이션. 구버전 파일 보존 (rename 실패 / 사용자 직접 백업
        // 모두 대응) — 신규 위치에 copy 만.
        if (std.fs.openFileAbsolute(path, .{})) |file| {
            defer file.close();
            const content = file.readToEndAlloc(allocator, 64 * 1024) catch return .{};
            defer allocator.free(content);
            return parse(allocator, content);
        } else |_| {
            if (paths.legacyMacConfigPath(allocator)) |legacy| {
                defer allocator.free(legacy);
                if (std.fs.copyFileAbsolute(legacy, path, .{})) |_| {
                    if (std.fs.openFileAbsolute(path, .{})) |file2| {
                        defer file2.close();
                        const content = file2.readToEndAlloc(allocator, 64 * 1024) catch return .{};
                        defer allocator.free(content);
                        return parse(allocator, content);
                    } else |_| {}
                } else |_| {}
            }
            createDefault(path);
            return .{};
        }
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

        if (root.object.get("dock_position")) |v| {
            if (v != .string) dialog.showFatal(messages.config_error_title, "config.json: \"dock_position\" must be a string.");
            if (DockPosition.fromString(v.string)) |dp| {
                config.dock_position = dp;
            } else {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(
                    &buf,
                    "config.json: unknown \"dock_position\" value \"{s}\".\n\nAllowed: top, bottom, left, right",
                    .{v.string},
                ) catch "config.json: dock_position invalid";
                dialog.showFatal(messages.config_error_title, msg);
            }
        }
        if (root.object.get("width")) |v| {
            if (v != .integer or v.integer < 1 or v.integer > 100) {
                dialog.showFatal(messages.config_error_title, "config.json: \"width\" must be an integer in 1..100.");
            }
            config.width_pct = @intCast(v.integer);
        }
        if (root.object.get("height")) |v| {
            if (v != .integer or v.integer < 1 or v.integer > 100) {
                dialog.showFatal(messages.config_error_title, "config.json: \"height\" must be an integer in 1..100.");
            }
            config.height_pct = @intCast(v.integer);
        }
        if (root.object.get("offset")) |v| {
            if (v != .integer or v.integer < 0 or v.integer > 100) {
                dialog.showFatal(messages.config_error_title, "config.json: \"offset\" must be an integer in 0..100.");
            }
            config.offset_pct = @intCast(v.integer);
        }
        if (root.object.get("theme")) |v| {
            if (v != .string) dialog.showFatal(messages.config_error_title, "config.json: \"theme\" must be a string.");
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
        if (root.object.get("opacity")) |v| {
            if (v != .integer or v.integer < 0 or v.integer > 100) {
                dialog.showFatal(messages.config_error_title, "config.json: \"opacity\" must be an integer in 0..100 (percent).");
            }
            // 0..100 퍼센트 → 0..255 internal. Windows config.zig 와 동일 매핑.
            config.opacity = @intCast(@divFloor(v.integer * 255, 100));
        }
        if (root.object.get("hotkey")) |v| {
            if (v != .string) dialog.showFatal(messages.config_error_title, "config.json: \"hotkey\" must be a string.");
            if (Hotkey.fromString(v.string)) |h| {
                config.hotkey = h;
            } else {
                var buf: [384]u8 = undefined;
                const msg = std.fmt.bufPrint(
                    &buf,
                    "config.json: failed to parse \"hotkey\" value \"{s}\".\n\nExamples: \"f1\", \"cmd+space\", \"ctrl+grave\", \"shift+cmd+t\"",
                    .{v.string},
                ) catch "config.json: hotkey invalid";
                dialog.showFatal(messages.config_error_title, msg);
            }
        }
        if (root.object.get("auto_start")) |v| {
            if (v != .bool) dialog.showFatal(messages.config_error_title, "config.json: \"auto_start\" must be a boolean.");
            config.auto_start = v.bool;
        }
        if (root.object.get("hidden_start")) |v| {
            if (v != .bool) dialog.showFatal(messages.config_error_title, "config.json: \"hidden_start\" must be a boolean.");
            config.hidden_start = v.bool;
        }

        return config;
    }

    fn createDefault(path: []const u8) void {
        const default_json =
            \\{
            \\  "dock_position": "top",
            \\  "width": 50,
            \\  "height": 100,
            \\  "offset": 100,
            \\  "opacity": 100,
            \\  "theme": "Tilda",
            \\  "hotkey": "f1",
            \\  "auto_start": true,
            \\  "hidden_start": false
            \\}
            \\
        ;
        const file = std.fs.createFileAbsolute(path, .{}) catch return;
        defer file.close();
        file.writeAll(default_json) catch {};
    }
};


test "Hotkey.fromString basic" {
    try std.testing.expectEqual(
        Hotkey{ .keycode = 0x7A, .modifiers = 0 },
        Hotkey.fromString("f1").?,
    );
    try std.testing.expectEqual(
        Hotkey{ .keycode = 0x31, .modifiers = kCGEventFlagMaskCommand },
        Hotkey.fromString("cmd+space").?,
    );
    try std.testing.expectEqual(
        Hotkey{ .keycode = 0x32, .modifiers = kCGEventFlagMaskControl },
        Hotkey.fromString("ctrl+grave").?,
    );
    try std.testing.expectEqual(
        Hotkey{ .keycode = 0x11, .modifiers = kCGEventFlagMaskCommand | kCGEventFlagMaskShift },
        Hotkey.fromString("shift+cmd+t").?,
    );
    try std.testing.expectEqual(@as(?Hotkey, null), Hotkey.fromString("nope"));
}

test "DockPosition.fromString" {
    try std.testing.expectEqual(DockPosition.top, DockPosition.fromString("top").?);
    try std.testing.expectEqual(DockPosition.bottom, DockPosition.fromString("bottom").?);
    try std.testing.expectEqual(@as(?DockPosition, null), DockPosition.fromString("nope"));
}
