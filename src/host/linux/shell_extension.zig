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
    /// #583 B8 — 파일 **내용을 바이너리가 싣는다.** 익명 import 는 `build.zig` 의
    /// `addShellExtensionResources` 가 넘긴다 (`@embedFile` 이 `src/` 밖을 못 읽는다).
    content: []const u8,
};

const gnome_resources = [_]Resource{
    .{ .relative_path = "extension.js", .content = @embedFile("gnome_extension_js") },
    .{ .relative_path = "metadata.json", .content = @embedFile("gnome_extension_metadata") },
    .{
        .relative_path = "schemas/org.gnome.shell.extensions.tildaz.gschema.xml",
        .content = @embedFile("gnome_extension_gschema"),
    },
};

const cinnamon_resources = [_]Resource{
    .{ .relative_path = "extension.js", .content = @embedFile("cinnamon_extension_js") },
    .{ .relative_path = "metadata.json", .content = @embedFile("cinnamon_extension_metadata") },
};

/// 패키지 리소스를 현재 사용자의 Shell extension 디렉터리에 반영한다.
///
/// #520 은 이 함수가 exe 옆 `../share/tildaz/` 에서 파일을 읽게 두고, 그 디렉터리가 없으면
/// 설치본을 그대로 두고 `kept_installed` 를 돌려주게 했다. 그런데 그 결과를 받은 쪽이 할 수
/// 있는 일이 **"오래됐을 수 있다" 고 로그에 남기는 것뿐**이었다 (#583 B8) — 레포에서 바이너리만
/// 옮겨 쓰거나 install.sh 로 깐 portable 설치는 계속 옛 extension 으로 돌았고, 사용자가 그것을
/// 고칠 방법을 안내받지 못했다.
///
/// 그래서 리소스를 **바이너리가 싣는다.** 배치와 무관하게 항상 반영되고, extension 은 자기를
/// 실은 바이너리와 늘 같은 버전이다 — extension 이 그 바이너리의 IPC 를 부르므로 이 짝이
/// 어긋나면 안 된다. 결과 종류 (`synced` · `kept_installed` · `unavailable`) 도 함께 사라졌다:
/// 이제 실패는 오류이고 성공은 한 가지다.
pub fn syncForCurrentUser(rt: Runtime, allocator: std.mem.Allocator, kind: Kind) !void {
    const home = try rt.envAlloc(allocator, "HOME");
    defer allocator.free(home);
    const destination_dir = switch (kind) {
        .gnome => try std.Io.Dir.path.join(allocator, &.{ home, ".local", "share", "gnome-shell", "extensions", uuid }),
        .cinnamon => try std.Io.Dir.path.join(allocator, &.{ home, ".local", "share", "cinnamon", "extensions", uuid }),
    };
    defer allocator.free(destination_dir);

    // #451 — `fs.Dir.makePath` ➡️ `Io.Dir.createDirPath`. 공통 helper 를 쓴다 (#282 G7).
    try paths.ensureDir(rt, destination_dir);

    var changed = false;
    const resources = switch (kind) {
        .gnome => gnome_resources[0..],
        .cinnamon => cinnamon_resources[0..],
    };
    for (resources) |resource| {
        const destination = try std.Io.Dir.path.join(allocator, &.{ destination_dir, resource.relative_path });
        defer allocator.free(destination);
        if (std.Io.Dir.path.dirname(destination)) |parent| try paths.ensureDir(rt, parent);
        changed = (try paths.writeFileIfChanged(rt, allocator, destination, resource.content)) or changed;
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
}

/// disk → disk 복사. #583 B8 이후 쓰임이 하나 남았다 — `glib-compile-schemas` 가 임시
/// 디렉터리에 낸 `gschemas.compiled` 를 제자리로 옮기는 것 (그 파일은 embed 대상이 아니다).
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

test "#583 B8 extension 리소스는 바이너리가 싣는다 (빈 파일이 실리면 사용자 홈을 비운다)" {
    // 내용이 비면 `writeFileIfChanged` 가 사용자 홈의 extension 을 **빈 파일로 덮는다** —
    // 익명 import 가 잘못된 경로를 가리켜도 컴파일은 되므로 여기서 잡는다.
    for (gnome_resources ++ cinnamon_resources) |resource| {
        try std.testing.expect(resource.content.len > 0);
    }
    // 파일이 서로 바뀌지 않았는지 — 각 종류의 표식을 본다.
    try std.testing.expect(std.mem.indexOf(u8, gnome_resources[0].content, "imports.gi") != null or
        std.mem.indexOf(u8, gnome_resources[0].content, "import ") != null);
    try std.testing.expect(std.mem.indexOf(u8, gnome_resources[1].content, uuid) != null);
    try std.testing.expect(std.mem.indexOf(u8, gnome_resources[2].content, "<schemalist") != null);
    try std.testing.expect(std.mem.indexOf(u8, cinnamon_resources[1].content, uuid) != null);
    // GNOME 과 Cinnamon 의 extension.js 는 다른 셸 API 를 쓰는 다른 파일이다.
    try std.testing.expect(!std.mem.eql(u8, gnome_resources[0].content, cinnamon_resources[0].content));
}
