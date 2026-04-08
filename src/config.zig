const std = @import("std");
const builtin = @import("builtin");
const themes = @import("themes.zig");

pub const DockPosition = enum { top, bottom, left, right };

pub const MAX_FONT_FAMILIES = 8;

const DEFAULT_THEME = "Tilda";

const DEFAULT_SHELL: []const u8 = switch (builtin.os.tag) {
    .windows => "cmd.exe",
    .macos => "/bin/zsh",
    .linux => "/bin/bash",
    else => "/bin/sh",
};

const DEFAULT_FONT_FAMILIES: []const []const u8 = switch (builtin.os.tag) {
    .windows => &.{ "Cascadia Mono", "Malgun Gothic", "Segoe UI Symbol" },
    .macos => &.{ "SF Mono", "Apple SD Gothic Neo", "Apple Symbols" },
    .linux => &.{ "JetBrains Mono", "Noto Sans CJK", "Noto Color Emoji" },
    else => &.{"monospace"},
};

fn defaultFontFamiliesArray() [MAX_FONT_FAMILIES][]const u8 {
    var result: [MAX_FONT_FAMILIES][]const u8 = .{""} ** MAX_FONT_FAMILIES;
    for (DEFAULT_FONT_FAMILIES, 0..) |fam, i| {
        result[i] = fam;
    }
    return result;
}

pub const Config = struct {
    // window
    dock_position: DockPosition = .top,
    width: u8 = 50,
    height: u8 = 100,
    offset: u8 = 100,
    // font
    font_families: [MAX_FONT_FAMILIES][]const u8 = defaultFontFamiliesArray(),
    font_family_count: u8 = @intCast(DEFAULT_FONT_FAMILIES.len),
    font_size: u8 = 19,
    line_height: f32 = 0.95,
    cell_width: f32 = 1.1,
    // appearance
    opacity: u8 = 255,
    theme: ?*const themes.Theme = themes.findTheme(DEFAULT_THEME),
    // top-level
    shell: []const u8 = DEFAULT_SHELL,
    auto_start: bool = true,
    hidden_start: bool = false,
    max_scroll_lines: u32 = 100_000,
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
            if (!isDefaultString(self.shell, DEFAULT_SHELL))
                alloc.free(self.shell);
            for (self.font_families[0..self.font_family_count]) |fam| {
                var is_default = false;
                for (DEFAULT_FONT_FAMILIES) |d| {
                    if (isDefaultString(fam, d)) {
                        is_default = true;
                        break;
                    }
                }
                if (!is_default and fam.len > 0) alloc.free(fam);
            }
        }
    }

    fn isDefaultString(s: []const u8, default: []const u8) bool {
        return s.ptr == default.ptr;
    }

    /// Validate config values. Returns an error message string or null if valid.
    pub fn validate(self: *const Config) ?[]const u8 {
        if (self.width < 10 or self.width > 100) return "config.json: \"window.width\" out of range (10~100)";
        if (self.height < 10 or self.height > 100) return "config.json: \"window.height\" out of range (10~100)";
        if (self.offset > 100) return "config.json: \"window.offset\" out of range (0~100)";
        if (self.font_size < 8 or self.font_size > 72) return "config.json: \"font.size\" out of range (8~72)";
        return null;
    }

    fn parse(allocator: std.mem.Allocator, content: []const u8) Config {
        var config = Config{};
        config._alloc = allocator;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch |err| {
            showJsonError(content, err);
            return config;
        };
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
                if (getIntField(win, "width")) |v| config.width = @intCast(std.math.clamp(v, 1, 255));
                if (getIntField(win, "height")) |v| config.height = @intCast(std.math.clamp(v, 1, 255));
                if (getIntField(win, "offset")) |v| config.offset = @intCast(std.math.clamp(v, 0, 255));
                if (getIntField(win, "opacity")) |v| config.opacity = @intCast(std.math.clamp(@divFloor(v * 255, 100), 0, 255));
            }
        }

        // font section
        if (root.object.get("font")) |fnt| {
            if (fnt == .object) {
                if (fnt.object.get("family")) |fam_val| {
                    switch (fam_val) {
                        .string => |s| {
                            if (s.len > 0) {
                                if (allocator.dupe(u8, s)) |duped| {
                                    config.font_families[0] = duped;
                                    config.font_family_count = 1;
                                } else |_| {}
                            }
                        },
                        .array => |arr| {
                            var count: u8 = 0;
                            for (arr.items) |item| {
                                if (count >= MAX_FONT_FAMILIES) break;
                                if (item == .string and item.string.len > 0) {
                                    if (allocator.dupe(u8, item.string)) |duped| {
                                        config.font_families[count] = duped;
                                        count += 1;
                                    } else |_| {}
                                }
                            }
                            if (count > 0) config.font_family_count = count;
                        },
                        else => {},
                    }
                }
                if (fnt.object.get("size")) |size_val| {
                    switch (size_val) {
                        .integer => |v| config.font_size = @intCast(std.math.clamp(v, 1, 255)),
                        .float => showConfigError("config.json: \"font.size\" must be integer (not float)"),
                        else => {},
                    }
                }
                if (getFloatField(fnt, "line_height")) |v| config.line_height = std.math.clamp(v, 0.1, 10.0);
                if (getFloatField(fnt, "cell_width")) |v| config.cell_width = std.math.clamp(v, 0.1, 10.0);
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
        if (getString(root, "theme")) |name| {
            if (name.len > 0) {
                config.theme = themes.findTheme(name);
                if (config.theme == null) {
                    std.log.err("config.json: unknown theme \"{s}\"", .{name});
                }
            }
        }
        if (getBool(root, "auto_start")) |v| config.auto_start = v;
        if (getBool(root, "hidden_start")) |v| config.hidden_start = v;
        if (root.object.get("max_scroll_lines")) |msv| {
            switch (msv) {
                .integer => |v| {
                    if (v < 100 or v > 100_000) {
                        std.log.err("config.json: \"max_scroll_lines\" must be between 100 and 100000", .{});
                    }
                    config.max_scroll_lines = @intCast(v);
                },
                .float => showConfigError("config.json: \"max_scroll_lines\" must be integer (not float)"),
                else => {},
            }
        }

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

    fn getFloatField(obj: std.json.Value, key: []const u8) ?f32 {
        if (obj.object.get(key)) |val| {
            return switch (val) {
                .float => @floatCast(val.float),
                .integer => @floatFromInt(val.integer),
                else => null,
            };
        }
        return null;
    }

    fn showConfigError(comptime msg: []const u8) void {
        std.log.err("{s}", .{msg});
        std.process.exit(1);
    }

    fn showJsonError(content: []const u8, err: anyerror) void {
        var line: usize = 1;
        var col: usize = 1;
        var scanner = std.json.Scanner.initCompleteInput(std.heap.page_allocator, content);
        defer scanner.deinit();
        while (true) {
            const token = scanner.next() catch break;
            if (token == .end_of_document) break;
        }
        const err_pos = @min(scanner.cursor, content.len);
        for (content[0..err_pos]) |c| {
            if (c == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }
        std.log.err("config.json: invalid JSON at line {}, column {} — {s}", .{ line, col, @errorName(err) });
        std.process.exit(1);
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
        return std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "config.json", .{exe_dir});
    }

    fn getExeDir(allocator: std.mem.Allocator) ![]const u8 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_path = std.fs.selfExeDirPath(&buf) catch return error.NoExeDir;
        return allocator.dupe(u8, exe_path);
    }

    fn createDefaultConfig(path: []const u8) void {
        const d = Config{};
        const t = "true";
        const f = "false";
        const default_json = std.fmt.comptimePrint(
            \\{{
            \\  "window": {{
            \\    "dock_position": "{s}",
            \\    "width": {d},
            \\    "height": {d},
            \\    "offset": {d},
            \\    "opacity": {d}
            \\  }},
            \\  "font": {{
            \\    "family": ["{s}", "{s}", "{s}"],
            \\    "size": {d},
            \\    "line_height": {d},
            \\    "cell_width": {d}
            \\  }},
            \\  "theme": "{s}",
            \\  "shell": "{s}",
            \\  "auto_start": {s},
            \\  "hidden_start": {s},
            \\  "max_scroll_lines": {d}
            \\}}
            \\
        , .{
            @tagName(d.dock_position),
            d.width,
            d.height,
            d.offset,
            @as(u32, d.opacity) * 100 / 255,
            DEFAULT_FONT_FAMILIES[0],
            DEFAULT_FONT_FAMILIES[1],
            DEFAULT_FONT_FAMILIES[2],
            d.font_size,
            d.line_height,
            d.cell_width,
            DEFAULT_THEME,
            d.shell,
            if (d.auto_start) t else f,
            if (d.hidden_start) t else f,
            d.max_scroll_lines,
        });
        const file = std.fs.createFileAbsolute(path, .{}) catch return;
        defer file.close();
        file.writeAll(default_json) catch {};
    }

    // -- Windows-specific UTF-16 helpers (only compiled on Windows) --

    pub fn shellUtf16(self: *const Config) [*:0]const u16 {
        comptime std.debug.assert(builtin.os.tag == .windows);
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
            if (i >= S.buf.len - 3) break;
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

    /// Convert font family at given index to null-terminated UTF-16 for Win32 CreateFontW
    pub fn fontFamilyUtf16(self: *const Config, index: u8) [*:0]const u16 {
        comptime std.debug.assert(builtin.os.tag == .windows);
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

        const S = struct {
            var bufs: [MAX_FONT_FAMILIES][64]u16 = undefined;
        };
        var i: usize = 0;
        var utf8_iter = std.unicode.Utf8View.init(family) catch return std.unicode.utf8ToUtf16LeStringLiteral("Consolas");
        var cp_iter = utf8_iter.iterator();
        while (cp_iter.nextCodepoint()) |cp| {
            if (i >= 62) break;
            if (cp <= 0xFFFF) {
                S.bufs[index][i] = @intCast(cp);
                i += 1;
            } else {
                const adj = cp - 0x10000;
                S.bufs[index][i] = @intCast(0xD800 + (adj >> 10));
                i += 1;
                S.bufs[index][i] = @intCast(0xDC00 + (adj & 0x3FF));
                i += 1;
            }
        }
        S.bufs[index][i] = 0;
        return @ptrCast(&S.bufs[index]);
    }
};
