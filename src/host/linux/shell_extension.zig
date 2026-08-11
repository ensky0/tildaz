const std = @import("std");
const runtime = @import("../../runtime.zig");
const paths = @import("../../paths.zig");

pub const Kind = enum {
    gnome,
    cinnamon,
};

const uuid = "tildaz@ensky0.github.io";

const Resource = struct {
    relative_path: []const u8,
};

const gnome_resources = [_]Resource{
    .{ .relative_path = "extension.js" },
    .{ .relative_path = "metadata.json" },
    .{ .relative_path = "schemas/org.gnome.shell.extensions.tildaz.gschema.xml" },
};

const cinnamon_resources = [_]Resource{
    .{ .relative_path = "extension.js" },
    .{ .relative_path = "metadata.json" },
};

/// Package resources live at <prefix>/share/tildaz. AppImage uses the same
/// layout below AppDir/usr, so every packaged Linux format follows this path.
/// A repository/portable install may not have this directory next to the
/// executable; install.sh already copied those resources and this becomes a
/// graceful no-op.
pub fn syncForCurrentUser(allocator: std.mem.Allocator, kind: Kind) !bool {
    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe = try std.fs.selfExePath(&exe_buf);
    const exe_dir = std.Io.Dir.path.dirname(exe) orelse return error.ExecutableDirectoryNotFound;
    const resource_root = try std.Io.Dir.path.join(allocator, &.{ exe_dir, "..", "share", "tildaz" });
    defer allocator.free(resource_root);

    const source_family = switch (kind) {
        .gnome => "gnome-extension",
        .cinnamon => "cinnamon-extension",
    };
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    const destination_dir = switch (kind) {
        .gnome => try std.Io.Dir.path.join(allocator, &.{ home, ".local", "share", "gnome-shell", "extensions", uuid }),
        .cinnamon => try std.Io.Dir.path.join(allocator, &.{ home, ".local", "share", "cinnamon", "extensions", uuid }),
    };
    defer allocator.free(destination_dir);

    const source_dir = try std.Io.Dir.path.join(allocator, &.{ resource_root, source_family, uuid });
    defer allocator.free(source_dir);
    std.Io.Dir.accessAbsolute(runtime.ioRequired(), source_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const installed_entry = try std.Io.Dir.path.join(allocator, &.{ destination_dir, "extension.js" });
            defer allocator.free(installed_entry);
            std.Io.Dir.accessAbsolute(runtime.ioRequired(), installed_entry, .{}) catch return false;
            return true;
        },
        else => return err,
    };

    try std.fs.cwd().makePath(destination_dir);

    var changed = false;
    const resources = switch (kind) {
        .gnome => gnome_resources[0..],
        .cinnamon => cinnamon_resources[0..],
    };
    for (resources) |resource| {
        const source = try std.Io.Dir.path.join(allocator, &.{ source_dir, resource.relative_path });
        defer allocator.free(source);
        const destination = try std.Io.Dir.path.join(allocator, &.{ destination_dir, resource.relative_path });
        defer allocator.free(destination);
        if (std.Io.Dir.path.dirname(destination)) |parent| try std.fs.cwd().makePath(parent);
        changed = (try syncFile(allocator, source, destination)) or changed;
    }

    if (kind == .gnome) {
        const compiled = try std.Io.Dir.path.join(allocator, &.{ destination_dir, "schemas", "gschemas.compiled" });
        defer allocator.free(compiled);
        const compiled_exists = blk: {
            std.Io.Dir.accessAbsolute(runtime.ioRequired(), compiled, .{}) catch break :blk false;
            break :blk true;
        };
        if (changed or !compiled_exists) try compileGnomeSchemas(allocator, destination_dir);
    }
    return true;
}

fn syncFile(allocator: std.mem.Allocator, source_path: []const u8, destination_path: []const u8) !bool {
    const source = try std.Io.Dir.openFileAbsolute(runtime.ioRequired(), source_path, .{});
    defer source.close();
    const content = try source.readToEndAlloc(allocator, 4 * 1024 * 1024);
    defer allocator.free(content);

    return paths.writeFileIfChanged(allocator, destination_path, content);
}

fn compileGnomeSchemas(allocator: std.mem.Allocator, extension_dir: []const u8) !void {
    const schemas_dir = try std.Io.Dir.path.join(allocator, &.{ extension_dir, "schemas" });
    defer allocator.free(schemas_dir);
    const temp_name = try std.fmt.allocPrint(allocator, ".tildaz-compile-{d}", .{std.c.getpid()});
    defer allocator.free(temp_name);
    const temp_dir = try std.Io.Dir.path.join(allocator, &.{ schemas_dir, temp_name });
    defer allocator.free(temp_dir);
    try std.fs.cwd().makePath(temp_dir);
    defer std.fs.cwd().deleteTree(temp_dir) catch {};
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "glib-compile-schemas", "--targetdir", temp_dir, schemas_dir },
        .max_output_bytes = 64 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return error.GlibCompileSchemasFailed,
        else => return error.GlibCompileSchemasFailed,
    }
    const compiled_source = try std.Io.Dir.path.join(allocator, &.{ temp_dir, "gschemas.compiled" });
    defer allocator.free(compiled_source);
    const compiled_destination = try std.Io.Dir.path.join(allocator, &.{ schemas_dir, "gschemas.compiled" });
    defer allocator.free(compiled_destination);
    _ = try syncFile(allocator, compiled_source, compiled_destination);
}

test "shell extension manifests contain required runtime files" {
    try std.testing.expectEqualStrings("extension.js", gnome_resources[0].relative_path);
    try std.testing.expectEqualStrings("metadata.json", gnome_resources[1].relative_path);
    try std.testing.expect(std.mem.startsWith(u8, gnome_resources[2].relative_path, "schemas/"));
    try std.testing.expectEqual(@as(usize, 2), cinnamon_resources.len);
}
