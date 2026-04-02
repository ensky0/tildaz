const std = @import("std");
const windows = std.os.windows;
const Window = @import("window.zig").Window;

pub const Config = struct {
    edge: Window.Edge = .top,
    size: u8 = 40,
    length: u8 = 100,
    offset: u8 = 0,
    shell: []const u8 = "cmd.exe",
    autostart: bool = false,

    pub fn load(allocator: std.mem.Allocator) Config {
        const path = getConfigPath(allocator) catch return .{};
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch return .{};
        defer file.close();

        const content = file.readToEndAlloc(allocator, 4096) catch return .{};
        defer allocator.free(content);

        return parse(content);
    }

    pub fn save(self: *const Config, allocator: std.mem.Allocator) !void {
        const dir_path = try getConfigDir(allocator);
        defer allocator.free(dir_path);

        // Ensure directory exists
        std.fs.makeDirAbsolute(dir_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const path = try getConfigPath(allocator);
        defer allocator.free(path);

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();

        const json = try std.fmt.allocPrint(allocator,
            \\{{
            \\  "edge": "{s}",
            \\  "size": {d},
            \\  "length": {d},
            \\  "offset": {d},
            \\  "shell": "{s}",
            \\  "autostart": {s}
            \\}}
        , .{
            @tagName(self.edge),
            self.size,
            self.length,
            self.offset,
            self.shell,
            if (self.autostart) "true" else "false",
        });
        defer allocator.free(json);
        try file.writeAll(json);
    }

    fn parse(content: []const u8) Config {
        var config = Config{};

        // Simple JSON parsing for our known fields
        if (findStringValue(content, "edge")) |edge_str| {
            if (std.mem.eql(u8, edge_str, "top")) config.edge = .top
            else if (std.mem.eql(u8, edge_str, "bottom")) config.edge = .bottom
            else if (std.mem.eql(u8, edge_str, "left")) config.edge = .left
            else if (std.mem.eql(u8, edge_str, "right")) config.edge = .right;
        }

        if (findIntValue(content, "size")) |v| config.size = @intCast(std.math.clamp(v, 10, 100));
        if (findIntValue(content, "length")) |v| config.length = @intCast(std.math.clamp(v, 10, 100));
        if (findIntValue(content, "offset")) |v| config.offset = @intCast(std.math.clamp(v, 0, 100));

        if (findBoolValue(content, "autostart")) |v| config.autostart = v;

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

    fn getConfigDir(allocator: std.mem.Allocator) ![]const u8 {
        // If portable config exists (exe directory), use that directory
        if (getExeDir(allocator)) |exe_dir| {
            const portable_path = std.fmt.allocPrint(allocator, "{s}\\config.json", .{exe_dir}) catch {
                allocator.free(exe_dir);
                return getAppdataDir(allocator);
            };
            defer allocator.free(portable_path);
            std.fs.accessAbsolute(portable_path, .{}) catch {
                allocator.free(exe_dir);
                return getAppdataDir(allocator);
            };
            return exe_dir;
        } else |_| {
            return getAppdataDir(allocator);
        }
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

    fn getAppdataDir(allocator: std.mem.Allocator) ![]const u8 {
        const appdata = std.process.getEnvVarOwned(allocator, "APPDATA") catch return error.NoAppData;
        defer allocator.free(appdata);
        return std.fmt.allocPrint(allocator, "{s}\\TildaZ", .{appdata});
    }

    fn getAppdataPath(allocator: std.mem.Allocator) ![]const u8 {
        const appdata = std.process.getEnvVarOwned(allocator, "APPDATA") catch return error.NoAppData;
        defer allocator.free(appdata);
        return std.fmt.allocPrint(allocator, "{s}\\TildaZ\\config.json", .{appdata});
    }

    pub fn shellUtf16(self: *const Config) [*:0]const u16 {
        // For MVP, we only support cmd.exe and powershell.exe
        if (std.mem.eql(u8, self.shell, "powershell.exe")) {
            return std.unicode.utf8ToUtf16LeStringLiteral("powershell.exe");
        }
        if (std.mem.eql(u8, self.shell, "pwsh.exe")) {
            return std.unicode.utf8ToUtf16LeStringLiteral("pwsh.exe");
        }
        return std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe");
    }
};
