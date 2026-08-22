const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const config = @import("../config.zig");
const instances = @import("../instances.zig");
const log = @import("../log.zig");
const paths = @import("../paths.zig");
const instance_identity = @import("../host/linux/instance_identity.zig");
const gsettings_hotkey = @import("../host/linux/gsettings_hotkey.zig");
const kglobalaccel = @import("../host/linux/kglobalaccel.zig");

pub fn sync(rt: Runtime, allocator: std.mem.Allocator, indices: []const u32) !void {
    try instance_identity.syncDesktopEntries(rt, allocator, indices);
    gsettings_hotkey.syncNumberedEntries(rt, allocator, indices);
    kglobalaccel.syncNumberedIdentities(rt, allocator, indices);
    if (desktopContains(rt, "hyprland")) syncHyprland(rt, allocator, indices) catch |err| {
        log.appendLine("hyprland", "numbered hotkey synchronization skipped: {s}", .{@errorName(err)});
    };
    if (desktopContains(rt, "cosmic")) syncCosmic(rt, allocator, indices) catch |err| {
        log.appendLine("cosmic", "numbered hotkey synchronization skipped: {s}", .{@errorName(err)});
    };
}

/// #451 — `posix.getenv` ➡️ `Environ.getPosix`. POSIX 는 블록을 그대로 훑어 할당이 없다.
fn desktopContains(rt: Runtime, name: []const u8) bool {
    const value = rt.environ.getPosix("XDG_CURRENT_DESKTOP") orelse return false;
    var it = std.mem.tokenizeAny(u8, value, ":;");
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), name)) return true;
    }
    return false;
}

fn syncHyprland(rt: Runtime, allocator: std.mem.Allocator, indices: []const u32) !void {
    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // #451 — `fs.selfExePath` ➡️ `std.process.executablePath` (길이를 돌려준다).
    const exe_len = try std.process.executablePath(rt.io, &exe_buf);
    const exe = exe_buf[0..exe_len];

    var desired: std.ArrayList(HyprlandDesired) = .empty;
    defer {
        for (desired.items) |item| item.deinit(allocator);
        desired.deinit(allocator);
    }
    for (indices) |index| {
        const text = try instances.configHotkeyText(rt, allocator, index);
        defer allocator.free(text);
        const hotkey = config.Hotkey.fromString(text) orelse return error.InvalidConfig;
        var accel_buf: [96]u8 = undefined;
        const accel = try hyprlandAccel(&accel_buf, hotkey);
        const owned_accel = try allocator.dupe(u8, accel);
        errdefer allocator.free(owned_accel);
        const command = try std.fmt.allocPrint(allocator, "{s} --toggle {d}", .{ exe, index });
        errdefer allocator.free(command);
        try desired.append(allocator, .{
            .accel = owned_accel,
            .command = command,
        });
    }

    const actual = try readHyprlandBindings(rt, allocator);
    defer actual.deinit();
    const present = try allocator.alloc(bool, desired.items.len);
    defer allocator.free(present);
    @memset(present, false);
    var removed_accels: std.ArrayList([]u8) = .empty;
    defer {
        for (removed_accels.items) |accel| allocator.free(accel);
        removed_accels.deinit(allocator);
    }

    var kept: usize = 0;
    var removed: usize = 0;
    for (actual.value) |binding| {
        var accel_buf: [96]u8 = undefined;
        const accel = managedHyprlandAccel(&accel_buf, binding, exe) orelse continue;
        if (findHyprlandDesired(desired.items, accel, binding.arg)) |desired_index| {
            if (!present[desired_index]) {
                present[desired_index] = true;
                kept += 1;
                continue;
            }
        }
        if (containsString(removed_accels.items, accel)) continue;
        _ = try runHyprlandKeyword(rt, "unbind", accel);
        try removed_accels.append(allocator, try allocator.dupe(u8, accel));
        removed += 1;
        // Hyprland unbind는 accelerator 단위라 같은 키의 desired binding도 함께
        // 제거될 수 있다. 해당 desired는 아래 add 단계에서 복원한다.
        for (desired.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.accel, accel)) present[i] = false;
        }
    }

    var added: usize = 0;
    for (desired.items, 0..) |item, i| {
        if (present[i]) continue;
        const binding = try std.fmt.allocPrint(allocator, "{s},exec,{s}", .{ item.accel, item.command });
        defer allocator.free(binding);
        if (!try runHyprlandKeyword(rt, "bind", binding)) return error.HyprctlFailed;
        added += 1;
    }
    log.appendLine("hyprland", "numbered hotkeys synchronized desired={} kept={} removed={} added={}", .{ desired.items.len, kept, removed, added });
}

const HyprlandDesired = struct {
    accel: []const u8,
    command: []const u8,

    fn deinit(self: HyprlandDesired, allocator: std.mem.Allocator) void {
        allocator.free(self.accel);
        allocator.free(self.command);
    }
};

const HyprlandBind = struct {
    modmask: u32 = 0,
    key: []const u8 = "",
    keycode: u32 = 0,
    dispatcher: []const u8 = "",
    arg: []const u8 = "",
};

const hypr_mod_shift: u32 = 1;
const hypr_mod_ctrl: u32 = 4;
const hypr_mod_alt: u32 = 8;
const hypr_mod_super: u32 = 64;
const hypr_supported_mods = hypr_mod_shift | hypr_mod_ctrl | hypr_mod_alt | hypr_mod_super;

fn readHyprlandBindings(rt: Runtime, allocator: std.mem.Allocator) !std.json.Parsed([]HyprlandBind) {
    // #451 — `std.process.Child.run` ➡️ `std.process.run(gpa, io, options)` (릴리즈 노트 *Process*).
    const result = try std.process.run(allocator, rt.io, .{
        .argv = &.{ "hyprctl", "-j", "binds" },
        // #451 — `max_output_bytes` 가 `stdout_limit` · `stderr_limit` (`Io.Limit`) 으로
        // 나뉘었다. 예전 한 값이 두 스트림의 합이 아니라 각각의 상한이었으므로 같은 값을 준다.
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.HyprctlFailed,
        else => return error.HyprctlFailed,
    }

    return std.json.parseFromSlice([]HyprlandBind, allocator, result.stdout, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

fn findHyprlandDesired(desired: []const HyprlandDesired, accel: []const u8, command: []const u8) ?usize {
    for (desired, 0..) |item, i| {
        if (std.mem.eql(u8, item.accel, accel) and std.mem.eql(u8, item.command, command)) return i;
    }
    return null;
}

fn containsString(items: []const []u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn managedHyprlandAccel(buf: []u8, binding: HyprlandBind, exe: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, binding.dispatcher, "exec")) return null;
    if (binding.keycode != 0 or binding.key.len == 0) return null;
    if ((binding.modmask & ~hypr_supported_mods) != 0) return null;
    if (!managedToggleCommand(binding.arg, exe)) return null;

    var fbs: std.Io.Writer = .fixed(buf);
    const writer = &fbs;
    if ((binding.modmask & hypr_mod_ctrl) != 0) writer.writeAll("CTRL ") catch return null;
    if ((binding.modmask & hypr_mod_shift) != 0) writer.writeAll("SHIFT ") catch return null;
    if ((binding.modmask & hypr_mod_alt) != 0) writer.writeAll("ALT ") catch return null;
    if ((binding.modmask & hypr_mod_super) != 0) writer.writeAll("SUPER ") catch return null;
    writer.writeByte(',') catch return null;
    writer.writeAll(binding.key) catch return null;
    return fbs.buffered();
}

fn managedToggleCommand(arg: []const u8, exe: []const u8) bool {
    if (!std.mem.startsWith(u8, arg, exe)) return false;
    const rest = arg[exe.len..];
    const prefix = " --toggle ";
    if (!std.mem.startsWith(u8, rest, prefix)) return false;
    const index_text = rest[prefix.len..];
    if (index_text.len == 0) return false;
    _ = std.fmt.parseInt(u32, index_text, 10) catch return false;
    return true;
}

fn runHyprlandKeyword(rt: Runtime, keyword: []const u8, value: []const u8) !bool {
    // #451 — `process.Child.init` + `spawn` ➡️ `process.spawn(io, options)` (릴리즈 노트
    // *Process*). stdio 값이 소문자로 바뀌었다 (`.Ignore` ➡️ `.ignore`). allocator 를 안
    // 받으므로 예전 인자가 사라진다.
    var child = try std.process.spawn(rt.io, .{
        .argv = &.{ "hyprctl", "keyword", keyword, value },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    return switch (try child.wait(rt.io)) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub fn hyprlandAccel(buf: []u8, hotkey: config.Hotkey) ![]const u8 {
    var fbs: std.Io.Writer = .fixed(buf);
    const writer = &fbs;
    if ((hotkey.modifiers & config.Hotkey.MOD_CTRL) != 0) try writer.writeAll("CTRL ");
    if ((hotkey.modifiers & config.Hotkey.MOD_SHIFT) != 0) try writer.writeAll("SHIFT ");
    if ((hotkey.modifiers & config.Hotkey.MOD_ALT) != 0) try writer.writeAll("ALT ");
    if ((hotkey.modifiers & config.Hotkey.MOD_SUPER) != 0) try writer.writeAll("SUPER ");
    try writer.writeByte(',');
    try writer.writeAll(config.linuxKeysymName(hotkey.keysym) orelse return error.InvalidConfig);
    return fbs.buffered();
}

test "managed Hyprland bindings are identified and reconstructed" {
    const exe = "/home/test/tildaz";
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings(",F3", managedHyprlandAccel(&buf, .{
        .key = "F3",
        .dispatcher = "exec",
        .arg = "/home/test/tildaz --toggle 2",
    }, exe).?);
    try std.testing.expectEqualStrings("CTRL SHIFT ,F4", managedHyprlandAccel(&buf, .{
        .modmask = hypr_mod_ctrl | hypr_mod_shift,
        .key = "F4",
        .dispatcher = "exec",
        .arg = "/home/test/tildaz --toggle 3",
    }, exe).?);
    try std.testing.expect(managedHyprlandAccel(&buf, .{
        .key = "F3",
        .dispatcher = "exec",
        .arg = "/usr/bin/other --toggle 2",
    }, exe) == null);
    try std.testing.expect(managedHyprlandAccel(&buf, .{
        .key = "F3",
        .dispatcher = "workspace",
        .arg = "3",
    }, exe) == null);
}

test "Hyprland binds JSON keeps the fields needed for cleanup" {
    const json =
        \\[{"modmask":0,"key":"F3","keycode":0,"dispatcher":"exec","arg":"/home/test/tildaz --toggle 2","description":""}]
    ;
    const parsed = try std.json.parseFromSlice([]HyprlandBind, std.testing.allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.len);
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings(",F3", managedHyprlandAccel(&buf, parsed.value[0], "/home/test/tildaz").?);
}

test "COSMIC entries are identified by our own description marker, not the command" {
    // writer(`appendCosmicEntries`)가 만드는 형태.
    try std.testing.expect(isTildazCosmicEntry(
        "    (modifiers: [], key: \"F1\", description: Some(\"TildaZ_0\")): Spawn(\"/usr/bin/tildaz --toggle 0\"),",
    ));

    // #484 회귀 — 바이너리 **이름**이 `tildaz` 가 아니면 이전 구현은 자기 항목을 못
    // 알아봤다. `tildaz-dev --toggle 0` 에는 `tildaz --toggle` 이라는 연속 문자열이
    // 없다 (하이픈이 끼어서). 못 지우고 하나 더 써서 같은 맵 키가 중복되고, 중복 키가
    // 있는 RON 은 COSMIC 이 파일 전체를 버린다 — 사용자 단축키까지 사라졌다.
    try std.testing.expect(isTildazCosmicEntry(
        "    (modifiers: [], key: \"F1\", description: Some(\"TildaZ_0\")): Spawn(\"/opt/bin/tildaz-dev --toggle 0\"),",
    ));
    // 경로만 바뀐 경우도 같이 고정한다.
    try std.testing.expect(isTildazCosmicEntry(
        "    (modifiers: [Ctrl, Shift], key: \"F2\", description: Some(\"TildaZ_3\")): Spawn(\"/home/u/bin/tz --toggle 3\"),",
    ));
    // 여러 자리 index.
    try std.testing.expect(isTildazCosmicEntry(
        "    (modifiers: [Super], key: \"grave\", description: Some(\"TildaZ_12\")): Spawn(\"/usr/bin/tildaz --toggle 12\"),",
    ));

    // #484 거울상 — 사용자 항목의 **명령**에 `tildaz --toggle` 이 들어 있으면 이전
    // 구현은 우리 것으로 착각해 조용히 지웠다. 이제 남의 항목은 건드리지 않는다.
    try std.testing.expect(!isTildazCosmicEntry(
        "    (modifiers: [Super], key: \"t\", description: Some(\"My wrapper\")): Spawn(\"sh -c 'tildaz --toggle 0; notify-send hi'\"),",
    ));

    // 표식을 흉내낸 남의 이름 — 번호 자리가 정수가 아니면 우리 것이 아니다.
    try std.testing.expect(!isTildazCosmicEntry(
        "    (modifiers: [Super], key: \"b\", description: Some(\"TildaZ_backup\")): Spawn(\"/usr/bin/backup\"),",
    ));
    // 번호 자리가 비어 있는 경우.
    try std.testing.expect(!isTildazCosmicEntry(
        "    (modifiers: [Super], key: \"n\", description: Some(\"TildaZ_\")): Spawn(\"/usr/bin/x\"),",
    ));
    // 음수는 index 가 아니다 (`u32`).
    try std.testing.expect(!isTildazCosmicEntry(
        "    (modifiers: [Super], key: \"m\", description: Some(\"TildaZ_-1\")): Spawn(\"/usr/bin/x\"),",
    ));

    // 전혀 무관한 사용자 항목.
    try std.testing.expect(!isTildazCosmicEntry(
        "    (modifiers: [Super], key: \"e\", description: Some(\"My file manager\")): Spawn(\"nautilus\"),",
    ));
    // 맵 경계 줄.
    try std.testing.expect(!isTildazCosmicEntry("{"));
    try std.testing.expect(!isTildazCosmicEntry("}"));

    // 죽어 있던 옛 표식(`TildaZ instance `)은 writer 가 쓴 적이 없으므로 인식 대상이
    // 아니다 — 살릴 것은 그 절의 *의도* 였고 문자열이 아니다.
    try std.testing.expect(!isTildazCosmicEntry(
        "    (modifiers: [], key: \"F1\", description: Some(\"TildaZ instance 0\")): Spawn(\"/usr/bin/tildaz --toggle 0\"),",
    ));
}

test "COSMIC closing map line is the last one" {
    // `syncCosmic` 은 이 offset 직전에 자기 항목을 끼워 넣는다.
    try std.testing.expectEqual(@as(?usize, 2), findClosingMapLine("{\n}\n"));
    try std.testing.expect(findClosingMapLine("{\n") == null);

    // 중첩된 `}` 가 있으면 **마지막** 것이 맵의 끝이다.
    const nested =
        "{\n" ++
        "    (modifiers: [], key: \"F1\", description: Some(\"TildaZ_0\")): Spawn(\"x\"),\n" ++
        "}\n";
    const offset = findClosingMapLine(nested).?;
    try std.testing.expectEqualStrings("}", nested[offset .. offset + 1]);

    // 들여쓰기 / CR 이 붙어도 닫는 줄로 인정한다 (`trim` 대상).
    try std.testing.expectEqual(@as(?usize, 2), findClosingMapLine("{\n  }  \n"));
    try std.testing.expectEqual(@as(?usize, 2), findClosingMapLine("{\n}\r\n"));
}

test "Hyprland desired lookup distinguishes keep and changed command" {
    const desired = [_]HyprlandDesired{
        .{ .accel = ",F1", .command = "/home/test/tildaz --toggle 0" },
        .{ .accel = ",F2", .command = "/home/test/tildaz --toggle 1" },
    };
    try std.testing.expectEqual(@as(?usize, 0), findHyprlandDesired(&desired, ",F1", "/home/test/tildaz --toggle 0"));
    try std.testing.expectEqual(@as(?usize, null), findHyprlandDesired(&desired, ",F3", "/home/test/tildaz --toggle 2"));
    try std.testing.expectEqual(@as(?usize, null), findHyprlandDesired(&desired, ",F1", "/home/test/tildaz --toggle 9"));
}

fn syncCosmic(rt: Runtime, allocator: std.mem.Allocator, indices: []const u32) !void {
    const home = rt.environ.getPosix("HOME") orelse return error.HomeNotSet;
    const dir_path = try std.Io.Dir.path.join(allocator, &.{ home, ".config", "cosmic", "com.system76.CosmicSettings.Shortcuts", "v1" });
    defer allocator.free(dir_path);
    // #451 — `fs.Dir.makePath` ➡️ 공용 helper (`paths.ensureDir` = `createDirPath`).
    try paths.ensureDir(rt, dir_path);
    const path = try std.Io.Dir.path.join(allocator, &.{ dir_path, "custom" });
    defer allocator.free(path);

    const content = blk: {
        const file = std.Io.Dir.openFileAbsolute(rt.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk try allocator.dupe(u8, "{\n}\n"),
            else => return err,
        };
        defer file.close(rt.io);
        // #451 — `fs.File.readToEndAlloc` ➡️ `File.Reader` 의 `allocRemaining`
        // (릴리즈 노트 *fs.File.readToEndAlloc*).
        var file_reader = file.reader(rt.io, &.{});
        break :blk try file_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    };
    defer allocator.free(content);

    const close_offset = findClosingMapLine(content) orelse return error.UnsupportedCosmicShortcutFormat;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var offset: usize = 0;
    while (offset < content.len) {
        const end = std.mem.findScalarPos(u8, content, offset, '\n') orelse content.len;
        const line = content[offset..end];
        if (offset == close_offset) try appendCosmicEntries(rt, &output, allocator, indices);
        if (!isTildazCosmicEntry(line)) {
            try output.appendSlice(allocator, line);
            try output.append(allocator, '\n');
        }
        offset = if (end < content.len) end + 1 else content.len;
    }

    if (try paths.writeFileIfChanged(rt, allocator, path, output.items)) {
        log.appendLine("cosmic", "numbered hotkeys synchronized ({d})", .{indices.len});
    } else {
        log.appendLine("cosmic", "numbered hotkeys already synchronized ({d})", .{indices.len});
    }
}

pub fn findClosingMapLine(content: []const u8) ?usize {
    var found: ?usize = null;
    var offset: usize = 0;
    while (offset < content.len) {
        const end = std.mem.findScalarPos(u8, content, offset, '\n') orelse content.len;
        if (std.mem.eql(u8, std.mem.trim(u8, content[offset..end], " \t\r"), "}")) found = offset;
        offset = if (end < content.len) end + 1 else content.len;
    }
    return found;
}

/// COSMIC custom shortcut 한 줄이 **우리가 쓴 것**인지 판정한다.
///
/// 근거는 `appendCosmicEntries` 가 직접 쓰는 description 표식
/// (`description: Some("TildaZ_<index>")`) 하나다. 명령 문자열을 보지 않는 이유가
/// [#484](https://github.com/ensky0/tildaz/issues/484) 다 — 이전 구현은
/// `Spawn("` + `tildaz --toggle` 부분 일치였고, 명령에는 바이너리 경로와 이름이
/// 들어가서 **사용자가 바꿀 수 있는 값**을 판정 근거로 삼고 있었다. 양방향으로 틀렸다.
///
/// - 이름을 바꾸면 (`tildaz-dev --toggle 0`) `tildaz --toggle` 이라는 연속 문자열이
///   사라져 자기 항목을 못 알아봤다. 지우지 못한 채 하나 더 쓰니 **같은 맵 키가
///   중복**되고, 중복 키가 있는 RON 은 깨진 데이터라 COSMIC 이 파일 전체를 버린다 —
///   사용자 단축키까지 함께 사라진다. 신고된 "cosmic resets all" 의 기전이다.
/// - 반대로 사용자 항목의 명령에 `tildaz --toggle` 이 들어 있으면 (래퍼 스크립트 등)
///   우리 것으로 착각해 **조용히 지웠다.**
///
/// 표식은 경로 · 이름과 무관하므로 두 방향이 함께 사라진다.
///
/// **접두 매칭**인 이유는 `syncCosmic` 이 "자기 항목 전부 삭제 후 현재 config 목록대로
/// 재작성" 구조라서다 — config 를 지운 인스턴스의 유령 항목도 정리돼야 한다. 단 번호
/// 자리가 정말 정수인지 확인해 `TildaZ_backup` 같은 남의 이름을 집지 않는다 (Hyprland
/// 쪽 `managedToggleCommand` 와 같은 엄격함).
fn isTildazCosmicEntry(line: []const u8) bool {
    const start = std.mem.find(u8, line, cosmic_entry_marker) orelse return false;
    const rest = line[start + cosmic_entry_marker.len ..];
    // 표식 뒤는 `<index>")` 형태다. 닫는 큰따옴표까지가 index 자리.
    const end = std.mem.findScalar(u8, rest, '"') orelse return false;
    _ = std.fmt.parseInt(u32, rest[0..end], 10) catch return false;
    return true;
}

/// `appendCosmicEntries` 의 writer 와 `isTildazCosmicEntry` 의 matcher 가 **같은**
/// 표식을 쓰게 묶어 둔다. 이 둘이 갈라진 게 #484 의 원인이었다 — matcher 는
/// `TildaZ instance ` 를 찾는데 writer 는 `TildaZ_<index>` 를 써서 그 절이 죽어 있었고,
/// 그래서 명령 문자열 매칭으로 떨어졌다.
const cosmic_entry_marker = "description: Some(\"TildaZ_";

fn appendCosmicEntries(rt: Runtime, output: *std.ArrayList(u8), allocator: std.mem.Allocator, indices: []const u32) !void {
    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // #451 — `fs.selfExePath` ➡️ `std.process.executablePath` (길이를 돌려준다).
    const exe_len = try std.process.executablePath(rt.io, &exe_buf);
    const exe = exe_buf[0..exe_len];
    for (indices) |index| {
        const text = try instances.configHotkeyText(rt, allocator, index);
        defer allocator.free(text);
        const hotkey = config.Hotkey.fromString(text) orelse return error.InvalidConfig;
        try output.appendSlice(allocator, "    (modifiers: [");
        var first = true;
        const mods = [_]struct { bit: u32, name: []const u8 }{
            .{ .bit = config.Hotkey.MOD_SUPER, .name = "Super" },
            .{ .bit = config.Hotkey.MOD_CTRL, .name = "Ctrl" },
            .{ .bit = config.Hotkey.MOD_ALT, .name = "Alt" },
            .{ .bit = config.Hotkey.MOD_SHIFT, .name = "Shift" },
        };
        for (mods) |mod| {
            if ((hotkey.modifiers & mod.bit) == 0) continue;
            if (!first) try output.appendSlice(allocator, ", ");
            try output.appendSlice(allocator, mod.name);
            first = false;
        }
        try output.appendSlice(allocator, "], key: \"");
        try output.appendSlice(allocator, config.linuxKeysymName(hotkey.keysym) orelse return error.InvalidConfig);
        // 표식은 `cosmic_entry_marker` 를 그대로 쓴다 — matcher 와 문자열이 갈라지면
        // 자기 항목을 못 알아본다 (#484 의 원인이 정확히 그것이었다).
        const description = try std.fmt.allocPrint(allocator, "\", " ++ cosmic_entry_marker ++ "{d}\")): Spawn(\"", .{index});
        defer allocator.free(description);
        try output.appendSlice(allocator, description);
        try appendRonString(output, allocator, exe);
        const suffix = try std.fmt.allocPrint(allocator, " --toggle {d}\"),\n", .{index});
        defer allocator.free(suffix);
        try output.appendSlice(allocator, suffix);
    }
}

fn appendRonString(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (value) |byte| {
        if (byte == '\\' or byte == '"') try output.append(allocator, '\\');
        try output.append(allocator, byte);
    }
}
