// macOS mini config — `~/Library/Application Support/tildaz/config.json`.
//
// `src/config.zig` 와 schema 는 같게 (`dock_position` / `width` / `height` /
// `offset` 같은 필드명) 두지만 platform-leak 정리 (`Window.DockPosition` 의존
// + `MessageBoxW` / `ExitProcess` 직접 호출) 가 안 끝나서 통합은 후속 milestone
// 으로 미루고 macOS 는 일단 자기 모듈을 쓴다 — #108 M3.5.
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

    /// "f1", "cmd+space", "ctrl+grave", "cmd+shift+t" 같은 string 을 keycode +
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

/// 잘못된 config 발견 시 호출되는 콜백. Windows host 와 동일 정책으로 다이얼
/// 로그 띄우고 즉시 종료해야 한다 (`noreturn`).
pub const ErrorReporter = *const fn (msg: []const u8) noreturn;

pub const Config = struct {
    dock_position: DockPosition = .top,
    width_pct: u8 = 50,
    height_pct: u8 = 100,
    offset_pct: u8 = 100,
    hotkey: Hotkey = .{ .keycode = 0x7A, .modifiers = 0 }, // F1

    /// 파일이 없으면 default + 자동 생성. JSON 파싱 실패 / 필드 값 오류 발견 시
    /// `on_error` 콜백 호출 — 콜백은 다이얼로그 띄우고 종료해야 한다.
    pub fn load(allocator: std.mem.Allocator, on_error: ErrorReporter) Config {
        const path = configPath(allocator) catch return .{};
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch {
            createDefault(path);
            return .{};
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 64 * 1024) catch return .{};
        defer allocator.free(content);

        return parse(allocator, content, on_error);
    }

    fn parse(allocator: std.mem.Allocator, content: []const u8, on_error: ErrorReporter) Config {
        var config = Config{};
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch |err| {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "config.json 파싱 실패: {s}\n\n경로: ~/Library/Application Support/tildaz/config.json",
                .{@errorName(err)},
            ) catch "config.json 파싱 실패";
            on_error(msg);
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) on_error("config.json: 최상위가 object 가 아닙니다.");

        if (root.object.get("dock_position")) |v| {
            if (v != .string) on_error("config.json: \"dock_position\" 은 문자열이어야 합니다.");
            if (DockPosition.fromString(v.string)) |dp| {
                config.dock_position = dp;
            } else {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(
                    &buf,
                    "config.json: \"dock_position\" 값 \"{s}\" 알 수 없음.\n\n허용: top, bottom, left, right",
                    .{v.string},
                ) catch "config.json: dock_position invalid";
                on_error(msg);
            }
        }
        if (root.object.get("width")) |v| {
            if (v != .integer or v.integer < 1 or v.integer > 100) {
                on_error("config.json: \"width\" 는 1..100 범위 정수여야 합니다.");
            }
            config.width_pct = @intCast(v.integer);
        }
        if (root.object.get("height")) |v| {
            if (v != .integer or v.integer < 1 or v.integer > 100) {
                on_error("config.json: \"height\" 는 1..100 범위 정수여야 합니다.");
            }
            config.height_pct = @intCast(v.integer);
        }
        if (root.object.get("offset")) |v| {
            if (v != .integer or v.integer < 0 or v.integer > 100) {
                on_error("config.json: \"offset\" 은 0..100 범위 정수여야 합니다.");
            }
            config.offset_pct = @intCast(v.integer);
        }
        if (root.object.get("hotkey")) |v| {
            if (v != .string) on_error("config.json: \"hotkey\" 는 문자열이어야 합니다.");
            if (Hotkey.fromString(v.string)) |h| {
                config.hotkey = h;
            } else {
                var buf: [384]u8 = undefined;
                const msg = std.fmt.bufPrint(
                    &buf,
                    "config.json: \"hotkey\" 값 \"{s}\" 파싱 실패.\n\n예: \"f1\", \"cmd+space\", \"ctrl+grave\", \"cmd+shift+t\"",
                    .{v.string},
                ) catch "config.json: hotkey invalid";
                on_error(msg);
            }
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
            \\  "hotkey": "f1"
            \\}
            \\
        ;
        const file = std.fs.createFileAbsolute(path, .{}) catch return;
        defer file.close();
        file.writeAll(default_json) catch {};
    }
};

/// `~/Library/Application Support/tildaz/config.json` 의 절대 경로.
/// 디렉토리 자동 생성 (이미 있으면 EEXIST 무시).
fn configPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.NoHome;
    defer allocator.free(home);

    const dir = try std.fmt.allocPrint(allocator, "{s}/Library/Application Support/tildaz", .{home});
    defer allocator.free(dir);
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    return std.fmt.allocPrint(allocator, "{s}/config.json", .{dir});
}

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
        Hotkey.fromString("cmd+shift+t").?,
    );
    try std.testing.expectEqual(@as(?Hotkey, null), Hotkey.fromString("nope"));
}

test "DockPosition.fromString" {
    try std.testing.expectEqual(DockPosition.top, DockPosition.fromString("top").?);
    try std.testing.expectEqual(DockPosition.bottom, DockPosition.fromString("bottom").?);
    try std.testing.expectEqual(@as(?DockPosition, null), DockPosition.fromString("nope"));
}
