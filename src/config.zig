const std = @import("std");
const windows = std.os.windows;
const Window = @import("window.zig").Window;

const WCHAR = u16;

const err_invalid_key = std.unicode.utf8ToUtf16LeStringLiteral(
    "config.json: invalid key\n\n\"edge\" -> \"dock_position\"\n\"size\" -> \"width\"\n\"length\" -> \"height\"",
);
const err_width = std.unicode.utf8ToUtf16LeStringLiteral(
    "config.json: \"width\" out of range\n\nAllowed: 10 ~ 100",
);
const err_height = std.unicode.utf8ToUtf16LeStringLiteral(
    "config.json: \"height\" out of range\n\nAllowed: 10 ~ 100",
);
const err_offset = std.unicode.utf8ToUtf16LeStringLiteral(
    "config.json: \"offset\" out of range\n\nAllowed: 0 ~ 100\n(0=start, 50=center, 100=end)",
);

pub const Config = struct {
    dock_position: Window.DockPosition = .top,
    width: u8 = 40,
    height: u8 = 100,
    offset: u8 = 0,
    shell: []const u8 = "cmd.exe",
    auto_start: bool = false,
    hidden_start: bool = false,
    has_invalid_key: bool = false,
    _alloc: ?std.mem.Allocator = null,

    pub fn load(allocator: std.mem.Allocator) Config {
        const path = getConfigPath(allocator) catch return .{};
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch return .{};
        defer file.close();

        const content = file.readToEndAlloc(allocator, 4096) catch return .{};
        defer allocator.free(content);

        return parse(allocator, content);
    }

    pub fn deinit(self: *const Config) void {
        if (self._alloc) |alloc| {
            alloc.free(self.shell);
        }
    }

    pub fn validate(self: *const Config) ?[*:0]const WCHAR {
        if (self.has_invalid_key) return err_invalid_key;
        if (self.width < 10 or self.width > 100) return err_width;
        if (self.height < 10 or self.height > 100) return err_height;
        if (self.offset > 100) return err_offset;
        return null;
    }


    fn parse(allocator: std.mem.Allocator, content: []const u8) Config {
        var config = Config{};

        // Simple JSON parsing for our known fields
        if (findStringValue(content, "dock_position")) |dp_str| {
            if (std.mem.eql(u8, dp_str, "top")) config.dock_position = .top
            else if (std.mem.eql(u8, dp_str, "bottom")) config.dock_position = .bottom
            else if (std.mem.eql(u8, dp_str, "left")) config.dock_position = .left
            else if (std.mem.eql(u8, dp_str, "right")) config.dock_position = .right;
        }

        // Detect deprecated/invalid keys
        config.has_invalid_key = findStringValue(content, "edge") != null or findIntValue(content, "size") != null or findIntValue(content, "length") != null;

        if (findIntValue(content, "width")) |v| config.width = @intCast(std.math.clamp(v, 1, 255));
        if (findIntValue(content, "height")) |v| config.height = @intCast(std.math.clamp(v, 1, 255));
        if (findIntValue(content, "offset")) |v| config.offset = @intCast(std.math.clamp(v, 0, 255));

        if (findBoolValue(content, "auto_start")) |v| config.auto_start = v;
        if (findBoolValue(content, "hidden_start")) |v| config.hidden_start = v;

        if (findStringValue(content, "shell")) |shell_str| {
            if (shell_str.len > 0) {
                if (allocator.dupe(u8, shell_str)) |duped| {
                    config.shell = duped;
                    config._alloc = allocator;
                } else |_| {}
            }
        }

        return config;
    }

    fn findStringValue(content: []const u8, key: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i < content.len) : (i += 1) {
            if (content.len - i < key.len + 5) break;
            if (content[i] == '"' and i + 1 + key.len < content.len) {
                if (std.mem.eql(u8, content[i + 1 .. i + 1 + key.len], key)) {
                    // Find the value after ": "
                    var j = i + 1 + key.len;
                    // Skip to value start
                    while (j < content.len and content[j] != '"') : (j += 1) {}
                    if (j >= content.len) return null;
                    j += 1; // skip opening "
                    // skip ': ' part
                    while (j < content.len and content[j] != '"') : (j += 1) {}
                    if (j >= content.len) return null;
                    j += 1; // skip the " after :
                    const start = j;
                    while (j < content.len and content[j] != '"') : (j += 1) {}
                    return content[start..j];
                }
            }
        }
        return null;
    }

    fn findIntValue(content: []const u8, key: []const u8) ?i64 {
        var i: usize = 0;
        while (i < content.len) : (i += 1) {
            if (content[i] == '"' and i + 1 + key.len < content.len) {
                if (std.mem.eql(u8, content[i + 1 .. i + 1 + key.len], key)) {
                    var j = i + 1 + key.len;
                    // Skip to after ':'
                    while (j < content.len and content[j] != ':') : (j += 1) {}
                    j += 1;
                    // Skip whitespace
                    while (j < content.len and (content[j] == ' ' or content[j] == '\t')) : (j += 1) {}
                    // Parse number
                    const start = j;
                    while (j < content.len and (content[j] >= '0' and content[j] <= '9')) : (j += 1) {}
                    if (j > start) {
                        return std.fmt.parseInt(i64, content[start..j], 10) catch null;
                    }
                }
            }
        }
        return null;
    }

    fn findBoolValue(content: []const u8, key: []const u8) ?bool {
        var i: usize = 0;
        while (i < content.len) : (i += 1) {
            if (content[i] == '"' and i + 1 + key.len < content.len) {
                if (std.mem.eql(u8, content[i + 1 .. i + 1 + key.len], key)) {
                    var j = i + 1 + key.len;
                    while (j < content.len and content[j] != ':') : (j += 1) {}
                    j += 1;
                    while (j < content.len and (content[j] == ' ' or content[j] == '\t')) : (j += 1) {}
                    if (j + 4 <= content.len and std.mem.eql(u8, content[j .. j + 4], "true")) return true;
                    if (j + 5 <= content.len and std.mem.eql(u8, content[j .. j + 5], "false")) return false;
                }
            }
        }
        return null;
    }


    fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
        // 1. Check exe directory first (portable mode)
        if (getExeDir(allocator)) |exe_dir| {
            defer allocator.free(exe_dir);
            const portable_path = try std.fmt.allocPrint(allocator, "{s}\\config.json", .{exe_dir});
            std.fs.accessAbsolute(portable_path, .{}) catch {
                allocator.free(portable_path);
                return getAppdataPath(allocator);
            };
            return portable_path;
        } else |_| {}

        // 2. Fallback to %APPDATA%\TildaZ\config.json
        return getAppdataPath(allocator);
    }

    fn getExeDir(allocator: std.mem.Allocator) ![]const u8 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_path = std.fs.selfExeDirPath(&buf) catch return error.NoExeDir;
        return allocator.dupe(u8, exe_path);
    }


    fn getAppdataPath(allocator: std.mem.Allocator) ![]const u8 {
        const appdata = std.process.getEnvVarOwned(allocator, "APPDATA") catch return error.NoAppData;
        defer allocator.free(appdata);
        return std.fmt.allocPrint(allocator, "{s}\\TildaZ\\config.json", .{appdata});
    }

    pub fn shellUtf16(self: *const Config) [*:0]const u16 {
        // Known shells: return comptime literals
        if (std.mem.eql(u8, self.shell, "cmd.exe"))
            return std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe");
        if (std.mem.eql(u8, self.shell, "powershell.exe"))
            return std.unicode.utf8ToUtf16LeStringLiteral("powershell.exe");
        if (std.mem.eql(u8, self.shell, "pwsh.exe"))
            return std.unicode.utf8ToUtf16LeStringLiteral("pwsh.exe");

        // Arbitrary shell: runtime UTF-8 to UTF-16 conversion into static buffer
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
};
