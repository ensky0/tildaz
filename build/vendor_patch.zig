//! 받아 온 의존성 소스에 우리 패치를 얹는다 ([#812](https://github.com/ensky0/tildaz/issues/812)).
//!
//! 패치 파일은 저장소 (`vendor/<의존성>/patches/*.patch`) 에 두고, `zig build` 가 설정 단계에서
//! `zig-pkg/` 안의 그 의존성 소스에 적용한다. fork 를 따로 두지 않으려고 고른 방식이다
//! (#812 ⑥ 사용자 결정).
//!
//! ## 왜 build.zig 에서 하나
//!
//! 모든 빌드 (`zig build` · `test` · `check` · CI · 릴리즈 · 설치 스크립트) 가 build.zig 를
//! 거친다. 빌드 전에 따로 스크립트를 돌리게 하면 그중 하나만 빠져도 패치 없는 판이 조용히
//! 나간다. zig 0.16 은 `zig-pkg/` 에 폴더가 있으면 해시를 다시 검사하지 않고, 없으면 원본에서
//! 다시 풀기 때문이다 (zig `src/Package/Fetch.zig`).
//!
//! ## 적용 규칙 — 줄 번호가 아니라 글 내용으로 맞춘다
//!
//! hunk 마다 "바뀌기 전 글" (` ` 와 `-` 줄) 과 "바뀐 뒤 글" (` ` 와 `+` 줄) 을 만든다.
//!
//! - 모든 hunk 의 바뀌기 전 글이 정확히 한 번씩 있으면 → 적용한다.
//! - 모든 hunk 의 바뀐 뒤 글이 정확히 한 번씩 있으면 → 이미 적용됐다. 아무것도 안 한다.
//! - 둘 다 아니면 → 빌드를 멈춘다. pin 을 올려 패치가 안 맞거나, 누가 그 파일을 고친 것이다.
//!
//! 한 패치가 여러 파일을 고치면 파일 전부가 같은 상태일 때만 진행한다. 일부만 적용된 상태는
//! 멈춘다.
//!
//! `git apply` 를 쓰지 않는 이유 — `zig-pkg/` 가 우리 git 작업 트리 안에 있어서 `git apply` 가
//! 경로를 저장소 기준으로 읽는다. 그리고 `git` 이 없어도 빌드가 돼야 한다.
//!
//! ## 동시에 빌드해도 깨지지 않는다
//!
//! 파일은 임시 파일에 쓴 뒤 이름을 바꿔 (`createFileAtomic` · `replace`) 한 번에 바꾼다. 같은
//! checkout 에서 빌드 둘이 동시에 처음 돌면 둘 다 원본을 읽고 같은 결과를 같은 자리에 쓴다.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Hunk = struct {
    old: []const u8,
    new: []const u8,
};

pub const FilePatch = struct {
    /// 의존성 루트 기준 경로 (`b/` 를 뗀 값).
    path: []const u8,
    hunks: []const Hunk,
};

pub const ParseError = error{ MalformedPatch, UnsupportedPatch } || Allocator.Error;

/// unified diff 를 파일별 hunk 로 나눈다. hunk 의 줄 수는 `@@` 머리의 수를 따른다 —
/// `-` 로 시작하는 지운 줄이 다음 파일의 `--- ` 머리처럼 보일 수 있어서다.
pub fn parse(arena: Allocator, text: []const u8) ParseError![]const FilePatch {
    var files: std.ArrayList(FilePatch) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');

    var path: ?[]const u8 = null;
    var hunks: std.ArrayList(Hunk) = .empty;

    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "+++ ")) {
            if (path) |p| try files.append(arena, .{ .path = p, .hunks = try hunks.toOwnedSlice(arena) });
            var name = line["+++ ".len..];
            if (std.mem.findScalar(u8, name, '\t')) |tab| name = name[0..tab];
            if (std.mem.startsWith(u8, name, "b/")) name = name[2..];
            if (name.len == 0) return error.MalformedPatch;
            path = name;
            continue;
        }
        if (!std.mem.startsWith(u8, line, "@@ ")) continue;
        if (path == null) return error.MalformedPatch;

        const counts = try parseHunkHeader(line);
        var old: std.ArrayList(u8) = .empty;
        var new: std.ArrayList(u8) = .empty;
        var old_left = counts.old;
        var new_left = counts.new;
        while (old_left > 0 or new_left > 0) {
            const body_raw = lines.next() orelse return error.MalformedPatch;
            const body = std.mem.trimEnd(u8, body_raw, "\r");
            // 빈 줄은 내용이 빈 문맥 줄이다 (끝 공백을 지우는 도구가 있다).
            const tag: u8 = if (body.len == 0) ' ' else body[0];
            const content = if (body.len == 0) body else body[1..];
            switch (tag) {
                ' ' => {
                    if (old_left == 0 or new_left == 0) return error.MalformedPatch;
                    try old.appendSlice(arena, content);
                    try old.append(arena, '\n');
                    try new.appendSlice(arena, content);
                    try new.append(arena, '\n');
                    old_left -= 1;
                    new_left -= 1;
                },
                '-' => {
                    if (old_left == 0) return error.MalformedPatch;
                    try old.appendSlice(arena, content);
                    try old.append(arena, '\n');
                    old_left -= 1;
                },
                '+' => {
                    if (new_left == 0) return error.MalformedPatch;
                    try new.appendSlice(arena, content);
                    try new.append(arena, '\n');
                    new_left -= 1;
                },
                // `\ No newline at end of file` — 우리 패치는 늘 줄바꿈으로 끝나는 파일만 다룬다.
                '\\' => return error.UnsupportedPatch,
                else => return error.MalformedPatch,
            }
        }
        // 바뀌기 전 글이 비면 (새 파일 · 빈 문맥) 내용으로 자리를 찾을 수 없다.
        if (old.items.len == 0) return error.UnsupportedPatch;
        try hunks.append(arena, .{ .old = old.items, .new = new.items });
    }
    if (path) |p| try files.append(arena, .{ .path = p, .hunks = try hunks.toOwnedSlice(arena) });
    if (files.items.len == 0) return error.MalformedPatch;
    for (files.items) |f| if (f.hunks.len == 0) return error.MalformedPatch;
    return files.toOwnedSlice(arena);
}

const HunkCounts = struct { old: usize, new: usize };

/// `@@ -a,b +c,d @@` 의 `b` · `d`. `,b` 가 없으면 1 이다 (diff 규칙).
fn parseHunkHeader(line: []const u8) ParseError!HunkCounts {
    var parts = std.mem.splitScalar(u8, line, ' ');
    _ = parts.next(); // "@@"
    const old_part = parts.next() orelse return error.MalformedPatch;
    const new_part = parts.next() orelse return error.MalformedPatch;
    if (old_part.len < 2 or old_part[0] != '-') return error.MalformedPatch;
    if (new_part.len < 2 or new_part[0] != '+') return error.MalformedPatch;
    return .{ .old = try rangeCount(old_part[1..]), .new = try rangeCount(new_part[1..]) };
}

fn rangeCount(range: []const u8) ParseError!usize {
    const comma = std.mem.findScalar(u8, range, ',') orelse return 1;
    return std.fmt.parseInt(usize, range[comma + 1 ..], 10) catch error.MalformedPatch;
}

pub const State = enum { unpatched, patched };

/// 파일 내용이 hunk 들에 대해 어느 상태인지. 판정할 수 없으면 `error.PatchDoesNotApply`.
pub fn state(text: []const u8, hunks: []const Hunk) error{PatchDoesNotApply}!State {
    var all_old = true;
    var all_new = true;
    for (hunks) |h| {
        if (std.mem.count(u8, text, h.old) != 1) all_old = false;
        if (std.mem.count(u8, text, h.new) != 1) all_new = false;
    }
    if (all_old and !all_new) return .unpatched;
    if (all_new and !all_old) return .patched;
    return error.PatchDoesNotApply;
}

/// hunk 들을 차례로 적용한 새 내용. `state` 가 `.unpatched` 인 내용에만 부른다.
pub fn apply(arena: Allocator, text: []const u8, hunks: []const Hunk) (error{PatchDoesNotApply} || Allocator.Error)![]u8 {
    var current: []const u8 = text;
    for (hunks) |h| {
        // 앞 hunk 가 바꾼 뒤에도 자리가 하나뿐이어야 한다.
        if (std.mem.count(u8, current, h.old) != 1) return error.PatchDoesNotApply;
        const at = std.mem.find(u8, current, h.old).?;
        current = try std.mem.concat(arena, u8, &.{ current[0..at], h.new, current[at + h.old.len ..] });
    }
    return @constCast(current);
}

/// 실패했을 때 무엇이 어디서 안 맞았는지.
pub const Diagnostic = struct {
    patch: []const u8 = "",
    file: []const u8 = "",
};

pub const Outcome = enum { applied, already_applied };

/// `patches` 폴더의 `*.patch` 를 이름 순으로 `root` 에 적용한다. 이미 적용된 패치는 건너뛴다.
/// 적용한 패치 이름은 `applied` 에 담는다 (처음 빌드할 때만 생긴다).
pub fn ensureApplied(
    io: Io,
    arena: Allocator,
    root: Io.Dir,
    patches: Io.Dir,
    applied: *std.ArrayList([]const u8),
    diag: *Diagnostic,
) !void {
    var names: std.ArrayList([]const u8) = .empty;
    var it = patches.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".patch")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);

    for (names.items) |name| {
        diag.* = .{ .patch = name };
        const text = try patches.readFileAlloc(io, name, arena, .limited(16 * 1024 * 1024));
        const files = try parse(arena, text);

        // 파일 전부의 상태를 먼저 본다 — 일부만 적용된 상태로 쓰기 시작하지 않는다.
        const contents = try arena.alloc([]const u8, files.len);
        var patched_count: usize = 0;
        for (files, 0..) |f, i| {
            diag.file = f.path;
            contents[i] = try root.readFileAlloc(io, f.path, arena, .limited(64 * 1024 * 1024));
            if (try state(contents[i], f.hunks) == .patched) patched_count += 1;
        }
        diag.file = "";
        if (patched_count == files.len) continue;
        if (patched_count != 0) return error.PatchDoesNotApply;

        for (files, 0..) |f, i| {
            diag.file = f.path;
            const result = try apply(arena, contents[i], f.hunks);
            var atomic = try root.createFileAtomic(io, f.path, .{ .replace = true });
            defer atomic.deinit(io);
            try atomic.file.writeStreamingAll(io, result);
            try atomic.replace(io);
        }
        diag.file = "";
        try applied.append(arena, name);
    }
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const testing = std.testing;

const sample_patch =
    \\--- a/src/x.zig
    \\+++ b/src/x.zig
    \\@@ -1,3 +1,4 @@
    \\ const a = 1;
    \\-const b = 2;
    \\+const b = 3;
    \\+const c = 4;
    \\ const d = 5;
    \\@@ -8,2 +9,2 @@
    \\ fn f() void {}
    \\--- removed line that looks like a header
    \\+++ added line that looks like a header
    \\
;

const sample_before = "const a = 1;\nconst b = 2;\nconst d = 5;\n\n\n\n\nfn f() void {}\n-- removed line that looks like a header\n";
const sample_after = "const a = 1;\nconst b = 3;\nconst c = 4;\nconst d = 5;\n\n\n\n\nfn f() void {}\n++ added line that looks like a header\n";

test "#812 — hunk 의 줄 수를 머리에서 읽어, 머리처럼 보이는 지운 줄 · 더한 줄을 내용으로 다룬다" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const files = try parse(arena_state.allocator(), sample_patch);
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expectEqualStrings("src/x.zig", files[0].path);
    try testing.expectEqual(@as(usize, 2), files[0].hunks.len);
    try testing.expectEqualStrings("fn f() void {}\n-- removed line that looks like a header\n", files[0].hunks[1].old);
    try testing.expectEqualStrings("fn f() void {}\n++ added line that looks like a header\n", files[0].hunks[1].new);
}

test "#812 — 원본은 적용하고, 적용된 내용은 그대로 두고, 둘 다 아니면 멈춘다" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const hunks = (try parse(arena, sample_patch))[0].hunks;

    try testing.expectEqual(State.unpatched, try state(sample_before, hunks));
    const result = try apply(arena, sample_before, hunks);
    try testing.expectEqualStrings(sample_after, result);
    try testing.expectEqual(State.patched, try state(result, hunks));

    // pin 을 올려 문맥이 바뀐 경우.
    try testing.expectError(error.PatchDoesNotApply, state("const a = 1;\nconst b = 9;\n", hunks));
    // hunk 하나만 적용된 경우.
    const half = "const a = 1;\nconst b = 3;\nconst c = 4;\nconst d = 5;\n\nfn f() void {}\n-- removed line that looks like a header\n";
    try testing.expectError(error.PatchDoesNotApply, state(half, hunks));
}

test "#812 — CRLF 로 받은 패치도 같은 hunk 가 된다" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const crlf = try std.mem.replaceOwned(u8, arena, sample_patch, "\n", "\r\n");
    const lf_files = try parse(arena, sample_patch);
    const crlf_files = try parse(arena, crlf);
    try testing.expectEqualStrings(lf_files[0].hunks[0].old, crlf_files[0].hunks[0].old);
    try testing.expectEqualStrings(lf_files[0].hunks[1].new, crlf_files[0].hunks[1].new);
}

test "#812 — 폴더의 패치를 적용하고, 두 번째에는 건너뛴다" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "pkg/src");
    try tmp.dir.createDirPath(io, "patches");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/src/x.zig", .data = sample_before });
    try tmp.dir.writeFile(io, .{ .sub_path = "patches/0001-x.patch", .data = sample_patch });
    try tmp.dir.writeFile(io, .{ .sub_path = "patches/README.md", .data = "not a patch" });

    var root = try tmp.dir.openDir(io, "pkg", .{});
    defer root.close(io);
    var patches = try tmp.dir.openDir(io, "patches", .{ .iterate = true });
    defer patches.close(io);

    var applied: std.ArrayList([]const u8) = .empty;
    var diag: Diagnostic = .{};
    try ensureApplied(io, arena, root, patches, &applied, &diag);
    try testing.expectEqual(@as(usize, 1), applied.items.len);
    try testing.expectEqualStrings(sample_after, try root.readFileAlloc(io, "src/x.zig", arena, .limited(4096)));

    applied.clearRetainingCapacity();
    try ensureApplied(io, arena, root, patches, &applied, &diag);
    try testing.expectEqual(@as(usize, 0), applied.items.len);

    // 누가 파일을 고쳐 패치가 안 맞으면 멈추고, 어느 패치 · 파일인지 알려 준다.
    try root.writeFile(io, .{ .sub_path = "src/x.zig", .data = "changed\n" });
    try testing.expectError(error.PatchDoesNotApply, ensureApplied(io, arena, root, patches, &applied, &diag));
    try testing.expectEqualStrings("0001-x.patch", diag.patch);
    try testing.expectEqualStrings("src/x.zig", diag.file);
}
