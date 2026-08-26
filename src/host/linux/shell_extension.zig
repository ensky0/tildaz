const std = @import("std");
const Runtime = @import("../../runtime.zig").Runtime;
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

/// #520 — 동기화 결과. 예전에는 `bool` 이라 **"복사했다" 와 "소스가 없어 손대지 않았다"
/// 가 같은 값**이었고, 호출자가 둘 다 `Shell extension synchronized and enabled` 로
/// 찍었다. 그래서 dev 빌드에서 extension 이 갱신되지 않는 것을 로그로 알아챌 수 없었다.
pub const SyncOutcome = enum {
    /// 소스에서 대상으로 반영했다 (내용이 같아 실제 쓰기가 없었던 경우도 포함).
    synced,
    /// **소스가 없어 손대지 않았다.** 설치본이 이미 있어서 진행은 가능하지만, 지금 레포의
    /// extension 이 아닐 수 있다.
    kept_installed,
    /// 소스도 설치본도 없다.
    unavailable,
};

/// Package resources live at <prefix>/share/tildaz. AppImage uses the same
/// layout below AppDir/usr, so every packaged Linux format follows this path.
/// `zig build` 도 #520 이후 같은 배치를 `zig-out/share/tildaz` 에 만든다.
///
/// 그래도 그 디렉터리가 없을 수 있다 — 레포에서 바이너리만 옮겨 쓰거나, install.sh 가
/// 이미 복사해 둔 portable 설치가 그렇다. 그때는 설치본을 그대로 두고 `kept_installed`
/// 를 돌려준다.
pub fn syncForCurrentUser(rt: Runtime, allocator: std.mem.Allocator, kind: Kind) !SyncOutcome {
    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // #451 — `fs.selfExePath` ➡️ `std.process.executablePath` (길이를 돌려준다).
    const exe_len = try std.process.executablePath(rt.io, &exe_buf);
    const exe = exe_buf[0..exe_len];
    const exe_dir = std.Io.Dir.path.dirname(exe) orelse return error.ExecutableDirectoryNotFound;
    const resource_root = try std.Io.Dir.path.join(allocator, &.{ exe_dir, "..", "share", "tildaz" });
    defer allocator.free(resource_root);

    const source_family = switch (kind) {
        .gnome => "gnome-extension",
        .cinnamon => "cinnamon-extension",
    };
    const home = try rt.envAlloc(allocator, "HOME");
    defer allocator.free(home);
    const destination_dir = switch (kind) {
        .gnome => try std.Io.Dir.path.join(allocator, &.{ home, ".local", "share", "gnome-shell", "extensions", uuid }),
        .cinnamon => try std.Io.Dir.path.join(allocator, &.{ home, ".local", "share", "cinnamon", "extensions", uuid }),
    };
    defer allocator.free(destination_dir);

    const source_dir = try std.Io.Dir.path.join(allocator, &.{ resource_root, source_family, uuid });
    defer allocator.free(source_dir);
    // #451 — `fs.accessAbsolute` ➡️ `std.Io.Dir.accessAbsolute` (릴리즈 노트 upgrade guide).
    std.Io.Dir.accessAbsolute(rt.io, source_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const installed_entry = try std.Io.Dir.path.join(allocator, &.{ destination_dir, "extension.js" });
            defer allocator.free(installed_entry);
            std.Io.Dir.accessAbsolute(rt.io, installed_entry, .{}) catch return .unavailable;
            return .kept_installed;
        },
        else => return err,
    };

    // #451 — `fs.Dir.makePath` ➡️ `Io.Dir.createDirPath`. 공통 helper 를 쓴다 (#282 G7).
    try paths.ensureDir(rt, destination_dir);

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
        if (std.Io.Dir.path.dirname(destination)) |parent| try paths.ensureDir(rt, parent);
        changed = (try syncFile(rt, allocator, source, destination)) or changed;
    }

    if (kind == .gnome) {
        const compiled = try std.Io.Dir.path.join(allocator, &.{ destination_dir, "schemas", "gschemas.compiled" });
        defer allocator.free(compiled);
        const compiled_exists = blk: {
            std.Io.Dir.accessAbsolute(rt.io, compiled, .{}) catch break :blk false;
            break :blk true;
        };
        if (changed or !compiled_exists) try compileGnomeSchemas(rt, allocator, destination_dir);
    }
    return .synced;
}

fn syncFile(rt: Runtime, allocator: std.mem.Allocator, source_path: []const u8, destination_path: []const u8) !bool {
    const source = try std.Io.Dir.openFileAbsolute(rt.io, source_path, .{});
    defer source.close(rt.io);
    // #451 — `fs.File.readToEndAlloc` ➡️ `File.Reader.allocRemaining` (릴리즈 노트 전용 절).
    var source_reader = source.reader(rt.io, &.{});
    const content = try source_reader.interface.allocRemaining(allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(content);

    return paths.writeFileIfChanged(rt, allocator, destination_path, content);
}

fn compileGnomeSchemas(rt: Runtime, allocator: std.mem.Allocator, extension_dir: []const u8) !void {
    const schemas_dir = try std.Io.Dir.path.join(allocator, &.{ extension_dir, "schemas" });
    defer allocator.free(schemas_dir);
    const temp_name = try std.fmt.allocPrint(allocator, ".tildaz-compile-{d}", .{std.c.getpid()});
    defer allocator.free(temp_name);
    const temp_dir = try std.Io.Dir.path.join(allocator, &.{ schemas_dir, temp_name });
    defer allocator.free(temp_dir);
    try paths.ensureDir(rt, temp_dir);
    defer std.Io.Dir.cwd().deleteTree(rt.io, temp_dir) catch {};
    // #451 — `std.process.Child.run` ➡️ `std.process.run(gpa, io, options)` (릴리즈 노트 *Process*).
    const result = try std.process.run(allocator, rt.io, .{
        .argv = &.{ "glib-compile-schemas", "--targetdir", temp_dir, schemas_dir },
        // #451 — `max_output_bytes` 가 `stdout_limit` · `stderr_limit` (`Io.Limit`) 으로
        // 나뉘었다. 예전 한 값이 두 스트림의 합이 아니라 각각의 상한이었으므로 같은 값을 준다.
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.GlibCompileSchemasFailed,
        else => return error.GlibCompileSchemasFailed,
    }
    const compiled_source = try std.Io.Dir.path.join(allocator, &.{ temp_dir, "gschemas.compiled" });
    defer allocator.free(compiled_source);
    const compiled_destination = try std.Io.Dir.path.join(allocator, &.{ schemas_dir, "gschemas.compiled" });
    defer allocator.free(compiled_destination);
    _ = try syncFile(rt, allocator, compiled_source, compiled_destination);
}

test "shell extension manifests contain required runtime files" {
    try std.testing.expectEqualStrings("extension.js", gnome_resources[0].relative_path);
    try std.testing.expectEqualStrings("metadata.json", gnome_resources[1].relative_path);
    try std.testing.expect(std.mem.startsWith(u8, gnome_resources[2].relative_path, "schemas/"));
    try std.testing.expectEqual(@as(usize, 2), cinnamon_resources.len);
}
