const std = @import("std");
const windows = std.os.windows;
const Window = @import("window.zig").Window;
const themes = @import("themes.zig");

const WCHAR = u16;
extern "user32" fn MessageBoxW(?*anyopaque, [*:0]const WCHAR, [*:0]const WCHAR, c_uint) callconv(.c) c_int;
extern "kernel32" fn ExitProcess(c_uint) callconv(.c) noreturn;

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

pub const MAX_FONT_FAMILIES = 8;

pub const Config = struct {
    // window
    dock_position: Window.DockPosition = .top,
    width: u8 = 50,
    height: u8 = 100,
    offset: u8 = 100,
    // font
    font_families: [MAX_FONT_FAMILIES][]const u8 = .{ "Cascadia Mono", "Malgun Gothic", "Segoe UI Symbol" } ++ .{""} ** (MAX_FONT_FAMILIES - 3),
    font_family_count: u8 = 3,
    font_size: u8 = 20,
    // appearance
    opacity: u8 = 255,
    theme: ?*const themes.Theme = themes.findTheme("Tilda"),
    // top-level
    shell: []const u8 = "cmd.exe",
    auto_start: bool = true,
    hidden_start: bool = true,
    max_scroll_lines: u32 = 10_000,
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
            const defaults = [_][]const u8{ "Cascadia Mono", "Malgun Gothic", "Segoe UI Symbol" };
            for (self.font_families[0..self.font_family_count]) |fam| {
                var is_default = false;
                for (defaults) |d| {
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
                    if (getIntField(win, "opacity")) |v| config.opacity = @intCast(std.math.clamp(@divFloor(v * 255, 100), 0, 255));
                }
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
        if (getString(root, "theme")) |name| {
            if (name.len > 0) {
                config.theme = themes.findTheme(name);
                if (config.theme == null) showThemeError(name);
            }
        }
        if (getBool(root, "auto_start")) |v| config.auto_start = v;
        if (getBool(root, "hidden_start")) |v| config.hidden_start = v;
        if (getIntField(root, "max_scroll_lines")) |v| {
            if (v < 100 or v > 100_000) {
                showRangeError("max_scroll_lines", 100, 100_000);
            }
            config.max_scroll_lines = @intCast(v);
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

    // Unused but kept for consistency
    fn getInt(obj: std.json.Value) ?i64 {
        _ = obj;
        return null;
    }

    fn showRangeError(comptime field: []const u8, comptime min: i64, comptime max: i64) void {
        const MB_OK = 0;
        const MB_ICONERROR = 0x10;
        const title = std.unicode.utf8ToUtf16LeStringLiteral("TildaZ Config Error");
        const msg = std.unicode.utf8ToUtf16LeStringLiteral(
            "config.json: \"" ++ field ++ "\" must be between " ++
            std.fmt.comptimePrint("{}", .{min}) ++ " and " ++
            std.fmt.comptimePrint("{}", .{max}),
        );
        _ = MessageBoxW(null, msg, title, MB_OK | MB_ICONERROR);
        ExitProcess(1);
    }

    fn showThemeError(name: []const u8) void {
        const MB_OK = 0;
        const MB_ICONERROR = 0x10;
        const title = std.unicode.utf8ToUtf16LeStringLiteral("TildaZ Config Error");
        var buf: [512]WCHAR = undefined;
        var pos: usize = 0;
        const prefix = std.unicode.utf8ToUtf16LeStringLiteral("config.json: unknown theme \"");
        for (prefix[0..27]) |c| {
            if (pos < buf.len - 1) {
                buf[pos] = c;
                pos += 1;
            }
        }
        for (name) |c| {
            if (pos < buf.len - 1) {
                buf[pos] = c;
                pos += 1;
            }
        }
        const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\"\n\nAvailable themes:\n");
        for (suffix[0..20]) |c| {
            if (pos < buf.len - 1) {
                buf[pos] = c;
                pos += 1;
            }
        }
        for (themes.themes, 0..) |t, i| {
            if (i > 0) {
                for (std.unicode.utf8ToUtf16LeStringLiteral(", ")[0..2]) |c| {
                    if (pos < buf.len - 1) {
                        buf[pos] = c;
                        pos += 1;
                    }
                }
            }
            for (t.name) |c| {
                if (pos < buf.len - 1) {
                    buf[pos] = c;
                    pos += 1;
                }
            }
        }
        buf[pos] = 0;
        _ = MessageBoxW(null, @ptrCast(&buf), title, MB_OK | MB_ICONERROR);
        ExitProcess(1);
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
            \\    "offset": 100,
            \\    "opacity": 100
            \\  },
            \\  "font": {
            \\    "family": ["Cascadia Mono", "Malgun Gothic", "Segoe UI Symbol"],
            \\    "size": 20
            \\  },
            \\  "theme": "Tilda",
            \\  "shell": "cmd.exe",
            \\  "auto_start": true,
            \\  "hidden_start": true,
            \\  "max_scroll_lines": 10000
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

    /// Convert font family at given index to null-terminated UTF-16 for Win32 CreateFontW
    pub fn fontFamilyUtf16(self: *const Config, index: u8) [*:0]const u16 {
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
            if (i >= 63) break;
            if (cp <= 0xFFFF) {
                S.bufs[index][i] = @intCast(cp);
                i += 1;
            }
        }
        S.bufs[index][i] = 0;
        return @ptrCast(&S.bufs[index]);
    }
};
