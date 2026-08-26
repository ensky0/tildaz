const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const config = @import("../config.zig");
const instances = @import("../instances.zig");
const log = @import("../log.zig");
const paths = @import("../paths.zig");
const instance_identity = @import("../host/linux/instance_identity.zig");
const gsettings_hotkey = @import("../host/linux/gsettings_hotkey.zig");
const physical_key = @import("../physical_key.zig");
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
    // #496 1-c — 위치 표기는 `code:NN` 으로 그대로 넘긴다. **keymap 을 물어볼 필요가
    // 없어서** 이 launcher 단계에서도 된다 (COSMIC 은 keysym 만 받아 그렇지 못하다).
    //
    // **숫자는 xkb keycode (= evdev + 8) 다.** Hyprland 위키가 `code:28` 을 `t` 키의
    // 예로 드는데 `t` 는 evdev 20 이다. sway `bindcode` 와 같은 번호 체계다.
    if (hotkey.code) |code| {
        try writer.print("code:{d}", .{physical_key.evdev(code) + 8});
        return fbs.buffered();
    }
    try writer.writeAll(config.linuxKeysymName(hotkey.keysym) orelse return error.InvalidConfig);
    return fbs.buffered();
}

test "#496 1-c Hyprland takes a position as code:NN in xkb numbering" {
    var buf: [64]u8 = undefined;

    // **evdev + 8 이다.** Hyprland 위키가 `code:28` 을 `t` 키의 예로 드는데 `t` 는
    // evdev 20 이다. sway `bindcode` 와 같은 번호 체계이고, 틀려도 Hyprland 가 거부하지
    // 않아 **조용히 옆 키에 붙으므로** 값을 test 로 고정한다.
    try std.testing.expectEqualStrings(
        "CTRL ,code:28",
        try hyprlandAccel(&buf, config.Hotkey.fromString("ctrl+[KeyT]").?),
    );
    // `[Backquote]` = evdev 41 → 49. `xkbcli how-to-type --layout fr '²'` 가 같은
    // 자리를 keycode 49 로 보고한다.
    try std.testing.expectEqualStrings(
        "CTRL ,code:49",
        try hyprlandAccel(&buf, config.Hotkey.fromString("ctrl+[Backquote]").?),
    );
    // 라벨 binding 은 예전 그대로다.
    try std.testing.expectEqualStrings(
        "CTRL ,F3",
        try hyprlandAccel(&buf, config.Hotkey.fromString("ctrl+f3").?),
    );
}

test "#496 1-c the position table stays in step with the numbers above" {
    // 위 test 의 28 · 49 는 손으로 적은 값이라 표가 바뀌면 스스로 거짓이 된다.
    try std.testing.expectEqual(@as(u16, 20), physical_key.evdev(.key_t));
    try std.testing.expectEqual(@as(u16, 41), physical_key.evdev(.backquote));
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
        // #496 1-c — 우리 줄은 지우고 다시 쓰는 구조다. 그런데 **위치 표기 인스턴스의
        // 줄은 워커가 쓴 것**이라 여기서 지우면 launcher 가 돌 때마다 사라진다. 그래서
        // 그 인스턴스의 줄만 남긴다.
        const keep = if (tildazCosmicEntryIndex(line)) |idx|
            cosmicDeferredToWorker(rt, allocator, idx)
        else
            true;
        if (keep) {
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
    return tildazCosmicEntryIndex(line) != null;
}

/// 우리 항목이면 그 instance index. #496 1-c 가 필요로 한다 — **어느 인스턴스의 줄인지**
/// 알아야 위치 표기 인스턴스의 줄을 지우지 않고 남길 수 있다.
fn tildazCosmicEntryIndex(line: []const u8) ?u32 {
    const start = std.mem.find(u8, line, cosmic_entry_marker) orelse return null;
    const rest = line[start + cosmic_entry_marker.len ..];
    // 표식 뒤는 `<index>")` 형태다. 닫는 큰따옴표까지가 index 자리.
    const end = std.mem.findScalar(u8, rest, '"') orelse return null;
    return std.fmt.parseInt(u32, rest[0..end], 10) catch null;
}

/// #496 1-c — 이 인스턴스의 hotkey 가 **위치 표기**인가.
///
/// 그렇다면 launcher 는 COSMIC 항목을 쓰지 못한다. COSMIC 의 RON `key:` 는 글자만 받는데
/// 자리를 글자로 바꾸려면 keymap 이 있어야 하고, launcher 에는 keyboard 자체가 없다
/// (Hyprland 가 1-b 에서 막혔던 그 자리다. 그쪽은 `code:` 로 자리를 그대로 받아 통과한다).
/// 그래서 그 인스턴스의 항목은 **워커가 keymap 을 받은 뒤에** 쓴다.
fn cosmicDeferredToWorker(rt: Runtime, allocator: std.mem.Allocator, index: u32) bool {
    const text = instances.configHotkeyText(rt, allocator, index) catch return false;
    defer allocator.free(text);
    const hotkey = config.Hotkey.fromString(text) orelse return false;
    return hotkey.code != null;
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
        // #496 1-c — 위치 표기는 워커가 쓴다 (`cosmicDeferredToWorker` 주석).
        if (hotkey.code != null) continue;
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
        try appendCosmicEntryTail(output, allocator, exe, index);
    }
}

/// 엔트리의 `key:` 뒤쪽. **writer 를 한 곳으로 묶어 둔다** — 표식이 matcher 와 갈라지면
/// 자기 항목을 못 알아보고 중복 키를 써서 COSMIC 이 파일을 통째로 버린다 (#484 의 기전).
/// #496 1-c 가 워커 쪽 writer 를 하나 더 만들면서 그 위험이 두 배가 되므로 뽑아 둔다.
fn appendCosmicEntryTail(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    exe: []const u8,
    index: u32,
) !void {
    const description = try std.fmt.allocPrint(allocator, "\", " ++ cosmic_entry_marker ++ "{d}\")): Spawn(\"", .{index});
    defer allocator.free(description);
    try output.appendSlice(allocator, description);
    try appendRonString(output, allocator, exe);
    const suffix = try std.fmt.allocPrint(allocator, " --toggle {d}\"),\n", .{index});
    defer allocator.free(suffix);
    try output.appendSlice(allocator, suffix);
}

/// #496 1-c — **워커가** 자기 인스턴스의 COSMIC 항목을 쓴다. 위치 표기 hotkey 전용이다.
///
/// launcher 가 못 하는 이유는 `cosmicDeferredToWorker` 주석에 있다 — 자리를 글자로
/// 바꾸려면 keymap 이 필요한데 그 시점엔 keyboard 가 없다. 여기서는 `key_name` 을
/// 이미 푼 상태로 받는다 (`xkb_keysym_get_name` 의 결과).
///
/// **대가 하나** — 그 인스턴스를 한 번은 직접 띄워야 항목이 생긴다. RON 은 파일이라 한
/// 번 쓰이면 남으므로 그 뒤로는 정상이고, sway 가 매 실행 `bindcode` 를 다시 거는 것과
/// 같은 성질이다.
pub fn writeCosmicPositionEntry(
    rt: Runtime,
    allocator: std.mem.Allocator,
    index: u32,
    key_name: []const u8,
    modifiers: u32,
) !void {
    return rewriteCosmicPositionEntry(rt, allocator, index, key_name, modifiers);
}

/// #496 1-c — 이 인스턴스의 위치 표기 항목을 RON 에서 **거둔다.**
///
/// 그 자리가 지금 layout 에서 글자를 못 낼 때 쓴다 (dead key). KDE 쪽
/// `KGlobalAccelClient.unbind` 와 같은 역할이고 이유도 같다 — 남겨 두면 직전 layout 의
/// 글자가 COSMIC 단축키 목록에 **죽은 항목**으로 남는다. 실기에서 fr → de 로 바꾸니
/// `key: "twosuperior"` 가 그대로 남았다 (#496 1-c 검증, cosmic-comp 1.0.0).
///
/// 발동하지는 않는다 — 독일어 자판에서 `²` 가 나는 자리 (`Ctrl+AltGr+2`) 를 눌러도
/// cosmic-comp 가 걸어 주지 않는 것까지 같은 실측에서 확인했다. 그래도 사용자 눈에는
/// 남으므로 거둔다.
pub fn removeCosmicPositionEntry(rt: Runtime, allocator: std.mem.Allocator, index: u32) !void {
    return rewriteCosmicPositionEntry(rt, allocator, index, null, 0);
}

/// `key_name` 이 `null` 이면 우리 줄을 지우기만 한다 (거두기), 값이 있으면 그 값으로 다시
/// 쓴다. 두 경로가 **같은 한 줄 규칙**을 쓰게 묶어 둔다 — 지우는 쪽과 쓰는 쪽이 갈리면
/// 같은 map 키가 둘 생기고, 중복 키가 있는 RON 은 COSMIC 이 파일 전체를 버린다 (#484).
fn rewriteCosmicPositionEntry(
    rt: Runtime,
    allocator: std.mem.Allocator,
    index: u32,
    key_name: ?[]const u8,
    modifiers: u32,
) !void {
    const home = rt.environ.getPosix("HOME") orelse return error.HomeNotSet;
    const dir_path = try std.Io.Dir.path.join(allocator, &.{ home, ".config", "cosmic", "com.system76.CosmicSettings.Shortcuts", "v1" });
    defer allocator.free(dir_path);
    try paths.ensureDir(rt, dir_path);
    const path = try std.Io.Dir.path.join(allocator, &.{ dir_path, "custom" });
    defer allocator.free(path);

    const content = blk: {
        const file = std.Io.Dir.openFileAbsolute(rt.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk try allocator.dupe(u8, "{\n}\n"),
            else => return err,
        };
        defer file.close(rt.io);
        var file_reader = file.reader(rt.io, &.{});
        break :blk try file_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    };
    defer allocator.free(content);

    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_len = try std.process.executablePath(rt.io, &exe_buf);
    const exe = exe_buf[0..exe_len];

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try renderCosmicPositionRon(&output, allocator, content, exe, index, key_name, modifiers);

    if (try paths.writeFileIfChanged(rt, allocator, path, output.items)) {
        if (key_name) |name| {
            log.appendLine("cosmic", "position hotkey entry written key={s}", .{name});
        } else {
            log.appendLine("cosmic", "position hotkey entry withdrawn", .{});
        }
    }
}

test "#496 1-c dead key layout withdraws the previous position entry" {
    // 실기 (cosmic-comp 1.0.0): fr 에서 `twosuperior` 로 쓰인 뒤 de 로 바꾸면 그 줄이
    // 그대로 남아 사용자 단축키 목록에 죽은 항목이 됐다. 거두는 쪽이 사용자 항목과 남의
    // 인스턴스는 건드리지 않는 것까지 함께 고정한다.
    const before =
        \\{
        \\    (modifiers: [], key: "F1"): Spawn("/usr/bin/tildaz --toggle 0"),
        \\    (modifiers: [Ctrl], key: "twosuperior", description: Some("TildaZ_9")): Spawn("/usr/bin/tildaz --toggle 9"),
        \\    (modifiers: [Super], key: "b", description: Some("TildaZ_3")): Spawn("/usr/bin/tildaz --toggle 3"),
        \\}
        \\
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try renderCosmicPositionRon(&output, std.testing.allocator, before, "/usr/bin/tildaz", 9, null, 0);
    try std.testing.expectEqualStrings(
        \\{
        \\    (modifiers: [], key: "F1"): Spawn("/usr/bin/tildaz --toggle 0"),
        \\    (modifiers: [Super], key: "b", description: Some("TildaZ_3")): Spawn("/usr/bin/tildaz --toggle 3"),
        \\}
        \\
    , output.items);
}

test "#496 1-c rewriting a position entry replaces our line instead of adding one" {
    // 같은 map 키가 둘 생기면 COSMIC 이 파일 전체를 버린다 (#484). 재등록이 layout 마다
    // 도는 경로라 이 성질이 특히 중요하다 — 실기에서 us · fr · ru · de 를 오갔다.
    const before =
        \\{
        \\    (modifiers: [Ctrl], key: "grave", description: Some("TildaZ_9")): Spawn("/usr/bin/tildaz --toggle 9"),
        \\}
        \\
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try renderCosmicPositionRon(&output, std.testing.allocator, before, "/usr/bin/tildaz", 9, "twosuperior", config.Hotkey.MOD_CTRL);
    try std.testing.expectEqualStrings(
        \\{
        \\    (modifiers: [Ctrl], key: "twosuperior", description: Some("TildaZ_9")): Spawn("/usr/bin/tildaz --toggle 9"),
        \\}
        \\
    , output.items);
}

/// 파일 내용 → 파일 내용. I/O 를 걷어 낸 순수부라 test 가 두 경로를 다 밟을 수 있다.
fn renderCosmicPositionRon(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    content: []const u8,
    exe: []const u8,
    index: u32,
    key_name: ?[]const u8,
    modifiers: u32,
) !void {
    const close_offset = findClosingMapLine(content) orelse return error.UnsupportedCosmicShortcutFormat;
    var offset: usize = 0;
    while (offset < content.len) {
        const end = std.mem.findScalarPos(u8, content, offset, '\n') orelse content.len;
        const line = content[offset..end];
        if (offset == close_offset) {
            if (key_name) |name| {
                try output.appendSlice(allocator, "    (modifiers: [");
                var first = true;
                const mods = [_]struct { bit: u32, name: []const u8 }{
                    .{ .bit = config.Hotkey.MOD_SUPER, .name = "Super" },
                    .{ .bit = config.Hotkey.MOD_CTRL, .name = "Ctrl" },
                    .{ .bit = config.Hotkey.MOD_ALT, .name = "Alt" },
                    .{ .bit = config.Hotkey.MOD_SHIFT, .name = "Shift" },
                };
                for (mods) |mod| {
                    if ((modifiers & mod.bit) == 0) continue;
                    if (!first) try output.appendSlice(allocator, ", ");
                    try output.appendSlice(allocator, mod.name);
                    first = false;
                }
                try output.appendSlice(allocator, "], key: \"");
                try output.appendSlice(allocator, name);
                try appendCosmicEntryTail(output, allocator, exe, index);
            }
        }
        // **내 인스턴스의 줄만** 지운다. 남의 인스턴스는 launcher 소관이다.
        const mine = if (tildazCosmicEntryIndex(line)) |idx| idx == index else false;
        if (!mine) {
            try output.appendSlice(allocator, line);
            try output.append(allocator, '\n');
        }
        offset = if (end < content.len) end + 1 else content.len;
    }
}

fn appendRonString(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (value) |byte| {
        if (byte == '\\' or byte == '"') try output.append(allocator, '\\');
        try output.append(allocator, byte);
    }
}
