const std = @import("std");
const Runtime = @import("../../runtime.zig").Runtime;
const paths = @import("../../paths.zig");

pub const Kind = enum {
    gnome,
    cinnamon,
};

const app_id = @import("../../app_id.zig");

const uuid = app_id.extension_uuid;

/// 소스의 토큰 → 이 빌드의 값 (#654). `dist/linux/tildaz.desktop` 의 `__TILDAZ_*__` 와
/// 같은 방식이다 — 확장 소스를 **두 벌 두지 않고** 쓰는 시점에 치환한다. 두 벌이면 하나만
/// 고치는 사고가 나고, 그 둘이 어긋나면 확장이 잡는 창과 앱이 내는 창이 갈라진다.
///
/// `install.sh` 도 같은 토큰을 치환한다 (배포물에서 셸이 확장을 먼저 읽어야 하는 경로).
/// 한쪽만 바뀌면 토큰이 남은 파일이 깔리므로 **토큰 이름을 바꿀 때는 두 곳을 함께** 본다.
const substitutions = [_]struct { token: []const u8, value: []const u8 }{
    .{ .token = "__TILDAZ_EXT_UUID__", .value = app_id.extension_uuid },
    .{ .token = "__TILDAZ_EXT_SCHEMA__", .value = app_id.extension_schema },
    .{ .token = "__TILDAZ_EXT_NAME__", .value = if (app_id.is_dev) "TildaZ Drop-down (dev)" else "TildaZ Drop-down" },
    // worker 창 제목의 접두어 — 확장의 `workerIndex()` 가 이것으로 번호를 읽는다. `instances.zig`
    // 의 `window_title_prefix` 와 같은 단일 소스 (`app_id.window_title_prefix`) 다.
    .{ .token = "__TILDAZ_TITLE_PREFIX__", .value = app_id.window_title_prefix },
    // 마지막에 둔다 — 위 토큰들이 이 문자열을 품고 있지 않지만, 접두어가 겹치는 토큰을
    // 나중에 더할 때 짧은 것을 먼저 치환하면 긴 토큰이 깨진다.
    .{ .token = "__TILDAZ_APP__", .value = app_id.name },
};

/// 토큰을 모두 치환한 사본. 소유권을 넘긴다 (치환할 것이 없어도 복사본이다 — 호출부가
/// 해제 조건을 따지지 않게 하려고 한 가지로 맞춘다. 파일이 다섯 개뿐이라 비용은 무시할 수 있다).
fn render(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var current = try allocator.dupe(u8, source);
    errdefer allocator.free(current);
    for (substitutions) |sub| {
        const count = std.mem.count(u8, current, sub.token);
        if (count == 0) continue;
        const size = current.len - count * sub.token.len + count * sub.value.len;
        const next = try allocator.alloc(u8, size);
        _ = std.mem.replace(u8, current, sub.token, sub.value, next);
        allocator.free(current);
        current = next;
    }
    return current;
}

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
        // 파일 이름도 스키마 id 를 따라간다 — `glib-compile-schemas` 는 디렉터리를 통째로
        // 읽으므로 이름이 겹치면 개발 빌드와 릴리즈가 서로의 스키마를 덮어쓴다.
        .relative_path = "schemas/" ++ app_id.extension_schema ++ ".gschema.xml",
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
pub fn syncForCurrentUser(rt: Runtime, allocator: std.mem.Allocator, kind: Kind) !bool {
    const home = try rt.envAlloc(allocator, "HOME");
    defer allocator.free(home);
    const destination_dir = switch (kind) {
        .gnome => try std.Io.Dir.path.join(allocator, &.{ home, ".local", "share", "gnome-shell", "extensions", uuid }),
        .cinnamon => try std.Io.Dir.path.join(allocator, &.{ home, ".local", "share", "cinnamon", "extensions", uuid }),
    };
    defer allocator.free(destination_dir);

    // #676 — Cinnamon은 GNOME의 `disabled-extensions` 같은 명시적 차단 목록이 없다.
    // 그래서 "처음 설치돼 아직 enabled 목록에 없는 것"과 "사용자가 목록에서 빼 꺼 둔
    // 것"을 구분할 수 있는 사실은 sync 전 사용자 디렉터리의 존재뿐이다. 처음 준비한
    // 경우만 호출처가 활성 목록에 넣고, 이미 있던 확장이 빠져 있으면 사용자 선택으로
    // 보고 되살리지 않는다.
    const newly_installed = blk: {
        std.Io.Dir.accessAbsolute(rt.io, destination_dir, .{}) catch break :blk true;
        break :blk false;
    };

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
        const content = try render(allocator, resource.content);
        defer allocator.free(content);
        changed = (try paths.writeFileIfChanged(rt, allocator, destination, content)) or changed;
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
    return newly_installed;
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

test "#676 disabling a Shell extension restores hidden terminal windows" {
    const sources = [_]struct {
        js: []const u8,
        disable_needle: []const u8,
        map_disconnect_needle: []const u8,
        restores_opacity: bool,
    }{
        .{
            .js = gnome_resources[0].content,
            .disable_needle = "  disable() {",
            .map_disconnect_needle = "global.window_manager.disconnect(this._mapWaitId)",
            .restores_opacity = true,
        },
        .{
            .js = cinnamon_resources[0].content,
            .disable_needle = "function disable() {",
            .map_disconnect_needle = "global.window_manager.disconnect(st.mapId)",
            .restores_opacity = false,
        },
    };
    for (sources) |source| {
        const disable_at = std.mem.indexOf(u8, source.js, source.disable_needle) orelse
            return error.ExtensionDisableMissing;
        const disable_body = source.js[disable_at..];
        const disconnect_at = std.mem.indexOf(u8, disable_body, source.map_disconnect_needle) orelse
            return error.ExtensionMapDisconnectMissing;
        const restore_at = std.mem.indexOf(u8, disable_body, "if (win.minimized) win.unminimize();") orelse
            return error.ExtensionWindowRestoreMissing;
        // 복원이 다시 map handler를 타 hidden_start로 최소화되지 않게 먼저 끊는다.
        try std.testing.expect(disconnect_at < restore_at);
        if (source.restores_opacity)
            try std.testing.expect(std.mem.indexOf(u8, disable_body[0..restore_at], "actor.opacity = 255;") != null);
    }
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
    try std.testing.expect(std.mem.indexOf(u8, gnome_resources[2].content, "<schemalist") != null);

    // #654 — 리소스는 `__TILDAZ_*__` 토큰을 담고 쓰는 시점에 치환된다. 그래서 metadata 가
    // 맞는 파일인지는 **치환 결과**로 본다.
    const allocator = std.testing.allocator;
    for ([_][]const u8{ gnome_resources[1].content, cinnamon_resources[1].content }) |metadata| {
        const rendered = try render(allocator, metadata);
        defer allocator.free(rendered);
        try std.testing.expect(std.mem.indexOf(u8, rendered, uuid) != null);
    }
    // gschema 의 id 는 파일 **이름** (`relative_path`) 과 같은 값에서 나온다 — 둘이 어긋나면
    // `glib-compile-schemas` 가 읽는 id 와 우리가 만든 파일 이름이 갈린다.
    {
        const rendered = try render(allocator, gnome_resources[2].content);
        defer allocator.free(rendered);
        try std.testing.expect(std.mem.indexOf(u8, rendered, app_id.extension_schema) != null);
    }
    // 창 제목 접두어 — 확장이 이 값으로 worker 창을 찾으므로 `instances.zig` 가 내는 제목과
    // 글자 단위로 같아야 한다 (#654).
    for ([_][]const u8{ gnome_resources[0].content, cinnamon_resources[0].content }) |js| {
        const rendered = try render(allocator, js);
        defer allocator.free(rendered);
        const needle = "const WINDOW_TITLE_PREFIX = \"" ++ @import("../../instances.zig").window_title_prefix ++ "\";";
        try std.testing.expect(std.mem.indexOf(u8, rendered, needle) != null);
    }
    // **치환 뒤에 토큰이 남으면 안 된다.** 남은 채로 깔리면 셸이 그 확장을 읽지 못하고 그
    // 실패는 사용자 화면에서 조용하다. `package.sh` 의 같은 검사와 짝이다 (그쪽은 배포물을,
    // 이쪽은 앱이 사용자 홈에 쓰는 경로를 본다).
    for (gnome_resources ++ cinnamon_resources) |resource| {
        const rendered = try render(allocator, resource.content);
        defer allocator.free(rendered);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "__TILDAZ_") == null);
    }
    // GNOME 과 Cinnamon 의 extension.js 는 다른 셸 API 를 쓰는 다른 파일이다.
    try std.testing.expect(!std.mem.eql(u8, gnome_resources[0].content, cinnamon_resources[0].content));
}
