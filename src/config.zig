const std = @import("std");
const windows = std.os.windows;
const Window = @import("window.zig").Window;

const WCHAR = u16;

const err_width = std.unicode.utf8ToUtf16LeStringLiteral(
    "config.json: \"window.width\" out of range\n\nAllowed: 10 ~ 100",
);
const err_height = std.unicode.utf8ToUtf16LeStringLiteral(
    "config.json: \"window.height\" out of range\n\nAllowed: 10 ~ 100",
);
const err_offset = std.unicode.utf8ToUtf16LeStringLiteral(
    "config.json: \"window.offset\" out of range\n\nAllowed: 0 ~ 100\n(0=start, 50=center, 100=end)",
);
const err_font_size = std.unicode.utf8ToUtf16LeStringLiteral(
    "config.json: \"font.size\" out of range\n\nAllowed: 8 ~ 72",
);

pub const Config = struct {
    // window
    dock_position: Window.DockPosition = .top,
    width: u8 = 50,
    height: u8 = 100,
    offset: u8 = 100,
    // font
    font_family: []const u8 = "Consolas",
    font_size: u8 = 20,
    // top-level
    shell: []const u8 = "cmd.exe",
    auto_start: bool = true,
    hidden_start: bool = true,
    max_scroll_lines: u32 = 1_000_000,
    _alloc: ?std.mem.Allocator = null,

    pub fn load(allocator: std.mem.Allocator) Config {
        const path = getConfigPath(allocator) catch return .{};
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch {
            createDefaultConfig(path);
            return .{};
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 16384) catch return .{};
        defer allocator.free(content);

        return parse(allocator, content);
    }

    pub fn deinit(self: *const Config) void {
        if (self._alloc) |alloc| {
            if (!isDefaultString(self.shell, "cmd.exe"))
                alloc.free(self.shell);
            if (!isDefaultString(self.font_family, "Consolas"))
                alloc.free(self.font_family);
        }
    }

    fn isDefaultString(s: []const u8, default: []const u8) bool {
        return s.ptr == default.ptr;
    }

    pub fn validate(self: *const Config) ?[*:0]const WCHAR {
        if (self.width < 10 or self.width > 100) return err_width;
        if (self.height < 10 or self.height > 100) return err_height;
        if (self.offset > 100) return err_offset;
        if (self.font_size < 8 or self.font_size > 72) return err_font_size;
        return null;
    }

    fn parse(allocator: std.mem.Allocator, content: []const u8) Config {
        var config = Config{};
        config._alloc = allocator;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return config;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return config;

        // window section
        if (root.object.get("window")) |win| {
            if (win == .object) {
                if (getString(win, "dock_position")) |dp| {
                    if (std.mem.eql(u8, dp, "top")) config.dock_position = .top
                    else if (std.mem.eql(u8, dp, "bottom")) config.dock_position = .bottom
                    else if (std.mem.eql(u8, dp, "left")) config.dock_position = .left
                    else if (std.mem.eql(u8, dp, "right")) config.dock_position = .right;
                }
                if (getInt(win)) |_| {} else {
                    if (getIntField(win, "width")) |v| config.width = @intCast(std.math.clamp(v, 1, 255));
                    if (getIntField(win, "height")) |v| config.height = @intCast(std.math.clamp(v, 1, 255));
                    if (getIntField(win, "offset")) |v| config.offset = @intCast(std.math.clamp(v, 0, 255));
                }
            }
        }

        // font section
        if (root.object.get("font")) |fnt| {
            if (fnt == .object) {
                if (getString(fnt, "family")) |family| {
                    if (family.len > 0) {
                        if (allocator.dupe(u8, family)) |duped| {
                            config.font_family = duped;
                        } else |_| {}
                    }
                }
                if (getIntField(fnt, "size")) |v| config.font_size = @intCast(std.math.clamp(v, 1, 255));
            }
        }

        // top-level fields
        if (getString(root, "shell")) |shell_str| {
            if (shell_str.len > 0) {
                if (allocator.dupe(u8, shell_str)) |duped| {
                    config.shell = duped;
                } else |_| {}
            }
        }
        if (getBool(root, "auto_start")) |v| config.auto_start = v;
        if (getBool(root, "hidden_start")) |v| config.hidden_start = v;
        if (getIntField(root, "max_scroll_lines")) |v| config.max_scroll_lines = @intCast(std.math.clamp(v, 0, 1_000_000));

        return config;
    }

    // -- JSON helpers --

    fn getString(obj: std.json.Value, key: []const u8) ?[]const u8 {
        if (obj.object.get(key)) |val| {
            if (val == .string) return val.string;
        }
        return null;
    }

    fn getIntField(obj: std.json.Value, key: []const u8) ?i64 {
        if (obj.object.get(key)) |val| {
            if (val == .integer) return val.integer;
        }
        return null;
    }

    // Unused but kept for consistency
    fn getInt(obj: std.json.Value) ?i64 {
        _ = obj;
        return null;
    }

    fn getBool(obj: std.json.Value, key: []const u8) ?bool {
        if (obj.object.get(key)) |val| {
            if (val == .bool) return val.bool;
        }
        return null;
    }

    // -- Config path resolution --

    fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
        const exe_dir = try getExeDir(allocator);
        defer allocator.free(exe_dir);
        return std.fmt.allocPrint(allocator, "{s}\\config.json", .{exe_dir});
    }

    fn getExeDir(allocator: std.mem.Allocator) ![]const u8 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_path = std.fs.selfExeDirPath(&buf) catch return error.NoExeDir;
        return allocator.dupe(u8, exe_path);
    }

    fn createDefaultConfig(path: []const u8) void {
        const default_json =
            \\{
            \\  "window": {
            \\    "dock_position": "top",
            \\    "width": 50,
            \\    "height": 100,
            \\    "offset": 100
            \\  },
            \\  "font": {
            \\    "family": "Consolas",
            \\    "size": 20
            \\  },
            \\  "shell": "cmd.exe",
            \\  "auto_start": true,
            \\  "hidden_start": true,
            \\  "max_scroll_lines": 1000000
            \\}
            \\
        ;
        const f = std.fs.createFileAbsolute(path, .{}) catch return;
        defer f.close();
        f.writeAll(default_json) catch {};
    }

    pub fn shellUtf16(self: *const Config) [*:0]const u16 {
        if (std.mem.eql(u8, self.shell, "cmd.exe"))
            return std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe");
        if (std.mem.eql(u8, self.shell, "powershell.exe"))
            return std.unicode.utf8ToUtf16LeStringLiteral("powershell.exe");
        if (std.mem.eql(u8, self.shell, "pwsh.exe"))
            return std.unicode.utf8ToUtf16LeStringLiteral("pwsh.exe");

        const S = struct {
            var buf: [512]u16 = undefined;
        };
        var i: usize = 0;
        var utf8_iter = std.unicode.Utf8View.init(self.shell) catch return std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe");
        var cp_iter = utf8_iter.iterator();
        while (cp_iter.nextCodepoint()) |cp| {
            if (i >= S.buf.len - 1) break;
            if (cp <= 0xFFFF) {
                S.buf[i] = @intCast(cp);
                i += 1;
            } else {
                const adj = cp - 0x10000;
                S.buf[i] = @intCast(0xD800 + (adj >> 10));
                i += 1;
                if (i < S.buf.len - 1) {
                    S.buf[i] = @intCast(0xDC00 + (adj & 0x3FF));
                    i += 1;
                }
            }
        }
        S.buf[i] = 0;
        return @ptrCast(&S.buf);
    }

    /// Convert font_family to null-terminated UTF-16 for Win32 CreateFontW
    pub fn fontFamilyUtf16(self: *const Config) [*:0]const u16 {
        if (std.mem.eql(u8, self.font_family, "Consolas"))
            return std.unicode.utf8ToUtf16LeStringLiteral("Consolas");
        if (std.mem.eql(u8, self.font_family, "Cascadia Code"))
            return std.unicode.utf8ToUtf16LeStringLiteral("Cascadia Code");
        if (std.mem.eql(u8, self.font_family, "Cascadia Mono"))
            return std.unicode.utf8ToUtf16LeStringLiteral("Cascadia Mono");

        const S = struct {
            var buf: [64]u16 = undefined;
        };
        var i: usize = 0;
        var utf8_iter = std.unicode.Utf8View.init(self.font_family) catch return std.unicode.utf8ToUtf16LeStringLiteral("Consolas");
        var cp_iter = utf8_iter.iterator();
        while (cp_iter.nextCodepoint()) |cp| {
            if (i >= S.buf.len - 1) break;
            if (cp <= 0xFFFF) {
                S.buf[i] = @intCast(cp);
                i += 1;
            }
        }
        S.buf[i] = 0;
        return @ptrCast(&S.buf);
    }
};
