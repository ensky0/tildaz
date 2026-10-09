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
const app_id = @import("../app_id.zig");
const cosmic_ron = @import("../cosmic_ron.zig");

pub fn sync(rt: Runtime, allocator: std.mem.Allocator, indices: []const u32) !void {
    try instance_identity.syncDesktopEntries(rt, allocator, indices);
    // #676 — GNOME · Cinnamon의 불완전한 GSettings hotkey fallback은 없어졌다.
    // 이전 버전이 남긴 우리 항목만 거두고 새 항목은 만들지 않는다.
    gsettings_hotkey.removeLegacyFallbackEntries(rt, allocator);
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

    // #695 — 설정이 Lua (`hyprland.lua` — 0.56 이 처음 실행 때 만든다) 면 `hyprctl keyword`
    // 가 `keyword can't work with non-legacy parsers. Use eval.` 로 거부된다. 종료 코드는
    // 0 이라 예전 구현은 성공으로 세고 아무것도 등록하지 못했다. 그래서 먼저 종류를 묻는다.
    const parser = readHyprlandParser(rt, allocator);

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
        const accel = try hyprlandBindKeys(&accel_buf, hotkey, parser);
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
        const managed = managedHyprlandBinding(&accel_buf, binding, exe, parser) orelse continue;
        // 이미 unbind 한 조합이면 이 binding 도 함께 지워졌다. 아래 keep 판정보다 먼저 봐야
        // 한다 — 예전에는 같은 조합의 낡은 binding 을 먼저 만나 지운 뒤, 뒤따른 맞는
        // binding 을 "있음" 으로 세서 다시 걸지 않았다.
        if (containsString(removed_accels.items, managed.keys)) continue;
        if (findHyprlandDesired(desired.items, managed.keys, managed.command)) |desired_index| {
            if (!present[desired_index]) {
                present[desired_index] = true;
                kept += 1;
                continue;
            }
        }
        if (!try unbindHyprland(rt, allocator, parser, managed.keys)) return error.HyprctlFailed;
        try removed_accels.append(allocator, try allocator.dupe(u8, managed.keys));
        removed += 1;
        // Hyprland unbind는 accelerator 단위라 같은 키의 desired binding도 함께
        // 제거될 수 있다. 해당 desired는 아래 add 단계에서 복원한다. Lua 의
        // `hl.unbind` 도 같은 표시 문자열을 전부 지운다.
        for (desired.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.accel, managed.keys)) {
                if (present[i]) kept -= 1;
                present[i] = false;
            }
        }
    }

    var added: usize = 0;
    for (desired.items, 0..) |item, i| {
        if (present[i]) continue;
        if (!try bindHyprland(rt, allocator, parser, item.accel, item.command)) return error.HyprctlFailed;
        added += 1;
    }
    log.appendLine("hyprland", "numbered hotkeys synchronized parser={s} desired={} kept={} removed={} added={}", .{ @tagName(parser), desired.items.len, kept, removed, added });
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
    /// #510 — submap 안의 binding 은 그 submap 이 활성일 때만 산다. 전역 충돌 판정
    /// (`hyprlandForeignBinding`) 이 이 값을 보고 걸러낸다. 우리 것은 항상 전역이라
    /// 기존 sync 경로는 이 필드를 보지 않는다.
    submap: []const u8 = "",
    /// #695 — Lua 로 건 binding 은 `dispatcher` 가 `"__lua"`, `arg` 가 Lua registry 번호라
    /// 명령이 안 보인다. 위치 binding 은 `key` · `keycode` 도 빈다. 우리 것을 알아볼 표식은
    /// `hl.bind` 의 `description` 뿐이라 거기에 명령과 키를 넣는다 (`luaDescription`).
    description: []const u8 = "",
};

/// #695 — Hyprland 가 읽은 설정의 종류. `hyprctl -j status` 의 `configProvider` 가
/// `"lua"` 면 `.lua`, 그 밖에는 (`"hyprlang"` · 필드가 없는 옛 Hyprland) `.legacy` 다.
const HyprlandParser = enum { legacy, lua };

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

/// sync 가 다루는 우리 binding — 지울 때 쓸 키 문자열과 그 binding 이 부르는 명령.
const ManagedHyprlandBind = struct {
    keys: []const u8,
    command: []const u8,
};

fn managedHyprlandBinding(buf: []u8, binding: HyprlandBind, exe: []const u8, parser: HyprlandParser) ?ManagedHyprlandBind {
    return switch (parser) {
        .lua => parseLuaDescription(binding.description, exe),
        .legacy => .{
            .keys = managedHyprlandAccel(buf, binding, exe) orelse return null,
            .command = binding.arg,
        },
    };
}

fn managedHyprlandAccel(buf: []u8, binding: HyprlandBind, exe: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, binding.dispatcher, "exec")) return null;
    if (!managedToggleCommand(binding.arg, exe)) return null;
    // #695 — 위치 binding (`keycode != 0`) 도 우리 것이다. 예전에는 여기서 걸러져 "있음"
    // 판정을 못 받고, launcher 를 띄울 때마다 같은 binding 을 하나씩 더 걸었다.
    return foreignHyprlandAccel(buf, binding);
}

/// `<명령> · <키>` — Lua binding 의 `description`. 명령으로 legacy 와 같은 기준 (지금 실행
/// 파일의 `--toggle N` 만 우리 것) 을 지키고, 키는 지울 때 `hl.unbind` 에 그대로 준다.
/// 위치 binding 은 JSON 에 키가 안 나오므로 여기서 읽는 수밖에 없다.
const lua_description_separator = " · ";

fn parseLuaDescription(description: []const u8, exe: []const u8) ?ManagedHyprlandBind {
    const at = std.mem.lastIndexOf(u8, description, lua_description_separator) orelse return null;
    const command = description[0..at];
    const keys = description[at + lua_description_separator.len ..];
    if (keys.len == 0) return null;
    if (!managedToggleCommand(command, exe)) return null;
    return .{ .keys = keys, .command = command };
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

/// #695 — `hyprctl -j status` 의 `configProvider` 로 설정 종류를 묻는다. 물어보지 못하면
/// (옛 Hyprland 라 필드가 없거나 `hyprctl` 이 실패) legacy 로 본다 — 예전 동작 그대로다.
fn readHyprlandParser(rt: Runtime, allocator: std.mem.Allocator) HyprlandParser {
    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{ "hyprctl", "-j", "status" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return .legacy;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return .legacy,
        else => return .legacy,
    }
    return parserFromStatusJson(allocator, result.stdout);
}

fn parserFromStatusJson(allocator: std.mem.Allocator, json: []const u8) HyprlandParser {
    const Status = struct { configProvider: []const u8 = "" };
    const parsed = std.json.parseFromSlice(Status, allocator, json, .{
        .ignore_unknown_fields = true,
    }) catch return .legacy;
    defer parsed.deinit();
    return if (std.mem.eql(u8, parsed.value.configProvider, "lua")) .lua else .legacy;
}

fn bindHyprland(rt: Runtime, allocator: std.mem.Allocator, parser: HyprlandParser, keys: []const u8, command: []const u8) !bool {
    switch (parser) {
        .legacy => {
            const value = try std.fmt.allocPrint(allocator, "{s},exec,{s}", .{ keys, command });
            defer allocator.free(value);
            return runHyprctl(rt, allocator, &.{ "hyprctl", "keyword", "bind", value });
        },
        .lua => {
            const code = try luaBindCode(allocator, keys, command);
            defer allocator.free(code);
            return runHyprctl(rt, allocator, &.{ "hyprctl", "eval", code });
        },
    }
}

fn unbindHyprland(rt: Runtime, allocator: std.mem.Allocator, parser: HyprlandParser, keys: []const u8) !bool {
    switch (parser) {
        .legacy => return runHyprctl(rt, allocator, &.{ "hyprctl", "keyword", "unbind", keys }),
        .lua => {
            const code = try luaUnbindCode(allocator, keys);
            defer allocator.free(code);
            return runHyprctl(rt, allocator, &.{ "hyprctl", "eval", code });
        },
    }
}

/// #695 — **성공은 응답이 `ok` 인 것뿐이다.** `hyprctl` 은 응답이 `error:` 로 시작할 때만
/// 0 이 아닌 종료 코드를 낸다 (`hyprctl/src/main.cpp`). 그래서 Lua 설정의 `keyword` 거부
/// 문구도, legacy 설정의 `eval is only supported with the lua config manager` 도 종료
/// 코드는 0 이다. 예전 구현은 종료 코드만 봐서 그 실패를 성공으로 셌다.
fn runHyprctl(rt: Runtime, allocator: std.mem.Allocator, argv: []const []const u8) !bool {
    const result = try std.process.run(allocator, rt.io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const reply = std.mem.trim(u8, result.stdout, " \t\r\n");
    const exited_ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (exited_ok and isHyprctlOk(reply)) return true;
    log.appendLine("hyprland", "hyprctl {s} rejected: {s}", .{ argv[1], reply[0..@min(reply.len, 200)] });
    return false;
}

fn isHyprctlOk(reply: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, reply, " \t\r\n"), "ok");
}

/// Lua 설정의 등록 코드 — `hl.bind(keys, hl.dsp.exec_cmd(command), { description = … })`.
/// 객체를 돌려받아 나중에 `remove()` 하는 길은 쓰지 않는다. 같은 객체를 두 번 지우면
/// Hyprland 0.56.2 가 죽는다 (#695 조사 중 실측 — compositor 가 SIGABRT 로 내려갔다).
fn luaBindCode(allocator: std.mem.Allocator, keys: []const u8, command: []const u8) ![]u8 {
    const description = try std.fmt.allocPrint(allocator, "{s}" ++ lua_description_separator ++ "{s}", .{ command, keys });
    defer allocator.free(description);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "hl.bind(");
    try appendLuaString(&out, allocator, keys);
    try out.appendSlice(allocator, ", hl.dsp.exec_cmd(");
    try appendLuaString(&out, allocator, command);
    try out.appendSlice(allocator, "), { description = ");
    try appendLuaString(&out, allocator, description);
    try out.appendSlice(allocator, " })");
    return out.toOwnedSlice(allocator);
}

/// `hl.unbind` 는 공백 · 대소문자를 무시하고 **같은 표시 문자열의 binding 을 전부** 지운다
/// (Hyprland `KeybindManager.cpp`). 같은 조합에 사용자가 건 binding 도 함께 지워질 수 있는데,
/// 그 조합은 #510 충돌 안내가 이미 알리는 경우라 감수한다 (#695 사용자 결정).
fn luaUnbindCode(allocator: std.mem.Allocator, keys: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "hl.unbind(");
    try appendLuaString(&out, allocator, keys);
    try out.append(allocator, ')');
    return out.toOwnedSlice(allocator);
}

fn appendLuaString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try out.append(allocator, '"');
    for (value) |c| switch (c) {
        '\\', '"' => {
            try out.append(allocator, '\\');
            try out.append(allocator, c);
        },
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        else => try out.append(allocator, c),
    };
    try out.append(allocator, '"');
}

/// sync 가 쓰는 키 문자열 — legacy 는 `CTRL SHIFT ,F12`, Lua 는 `CTRL + SHIFT + F12`.
fn hyprlandBindKeys(buf: []u8, hotkey: config.Hotkey, parser: HyprlandParser) ![]const u8 {
    return switch (parser) {
        .legacy => hyprlandAccel(buf, hotkey),
        .lua => hyprlandLuaKeys(buf, hotkey),
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
    try writeHyprlandKey(writer, hotkey);
    return fbs.buffered();
}

/// #695 — Lua `hl.bind` 의 키 문자열. `+` 로 나누고 토큰의 공백은 무시하며, 수식키가 키보다
/// 먼저 와야 한다 (Hyprland `LuaBindingsToplevel.cpp`). 수식키 순서는 legacy 와 같게 고정한다
/// — `hl.unbind` 는 순서가 다른 문자열로는 못 지우면서도 `ok` 를 돌려준다 (#695 조사 실측).
fn hyprlandLuaKeys(buf: []u8, hotkey: config.Hotkey) ![]const u8 {
    var fbs: std.Io.Writer = .fixed(buf);
    const writer = &fbs;
    if ((hotkey.modifiers & config.Hotkey.MOD_CTRL) != 0) try writer.writeAll("CTRL + ");
    if ((hotkey.modifiers & config.Hotkey.MOD_SHIFT) != 0) try writer.writeAll("SHIFT + ");
    if ((hotkey.modifiers & config.Hotkey.MOD_ALT) != 0) try writer.writeAll("ALT + ");
    if ((hotkey.modifiers & config.Hotkey.MOD_SUPER) != 0) try writer.writeAll("SUPER + ");
    try writeHyprlandKey(writer, hotkey);
    return fbs.buffered();
}

fn writeHyprlandKey(writer: *std.Io.Writer, hotkey: config.Hotkey) !void {
    // #496 1-c — 위치 표기는 `code:NN` 으로 그대로 넘긴다. **keymap 을 물어볼 필요가
    // 없어서** 이 launcher 단계에서도 된다 (COSMIC 은 keysym 만 받아 그렇지 못하다).
    // Lua `hl.bind` 도 같은 `code:NN` 을 받는다 (#695 조사 실측).
    //
    // **숫자는 xkb keycode (= evdev + 8) 다.** Hyprland 위키가 `code:28` 을 `t` 키의
    // 예로 드는데 `t` 는 evdev 20 이다. sway `bindcode` 와 같은 번호 체계다.
    if (hotkey.code) |code| {
        try writer.print("code:{d}", .{physical_key.evdev(code) + 8});
        return;
    }
    try writer.writeAll(config.linuxKeysymName(hotkey.keysym) orelse return error.InvalidConfig);
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

test "#695 configProvider decides Lua or legacy" {
    const a = std.testing.allocator;
    // 미니PC · Hyprland 0.56.2 · `hyprland.lua` 세션의 실제 응답.
    try std.testing.expectEqual(HyprlandParser.lua, parserFromStatusJson(a,
        \\{
        \\    "configProvider": "lua",
        \\    "backend": "drm"
        \\}
    ));
    try std.testing.expectEqual(HyprlandParser.legacy, parserFromStatusJson(a, "{\"configProvider\": \"hyprlang\"}"));
    // 옛 Hyprland 는 필드가 없다 — 예전 동작 (legacy) 을 지킨다.
    try std.testing.expectEqual(HyprlandParser.legacy, parserFromStatusJson(a, "{\"backend\": \"drm\"}"));
    try std.testing.expectEqual(HyprlandParser.legacy, parserFromStatusJson(a, "unknown request"));
}

test "#695 Lua keys keep the legacy modifier order and the code:NN position form" {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("CTRL + SHIFT + F12", try hyprlandLuaKeys(&buf, config.Hotkey.fromString("ctrl+shift+f12").?));
    try std.testing.expectEqualStrings("F1", try hyprlandLuaKeys(&buf, config.Hotkey.fromString("F1").?));
    try std.testing.expectEqualStrings("CTRL + code:28", try hyprlandLuaKeys(&buf, config.Hotkey.fromString("ctrl+[KeyT]").?));
    // legacy 판은 그대로다.
    try std.testing.expectEqualStrings("CTRL SHIFT ,F12", try hyprlandBindKeys(&buf, config.Hotkey.fromString("ctrl+shift+f12").?, .legacy));
}

test "#695 Lua bind and unbind code quote their strings" {
    const a = std.testing.allocator;
    const bind = try luaBindCode(a, "CTRL + F3", "/home/test/tildaz --toggle 2");
    defer a.free(bind);
    try std.testing.expectEqualStrings(
        "hl.bind(\"CTRL + F3\", hl.dsp.exec_cmd(\"/home/test/tildaz --toggle 2\"), { description = \"/home/test/tildaz --toggle 2 · CTRL + F3\" })",
        bind,
    );
    // 경로의 따옴표 · 역슬래시가 Lua 문자열을 깨지 않는다.
    const odd = try luaBindCode(a, "F3", "/opt/a\"b\\c/tildaz --toggle 0");
    defer a.free(odd);
    try std.testing.expect(std.mem.indexOf(u8, odd, "exec_cmd(\"/opt/a\\\"b\\\\c/tildaz --toggle 0\")") != null);

    const unbind = try luaUnbindCode(a, "CTRL + code:113");
    defer a.free(unbind);
    try std.testing.expectEqualStrings("hl.unbind(\"CTRL + code:113\")", unbind);
}

test "#695 Lua bindings are ours only by the description marker of this executable" {
    const exe = "/home/test/tildaz";
    const ours = parseLuaDescription("/home/test/tildaz --toggle 9 · CTRL + code:113", exe).?;
    try std.testing.expectEqualStrings("CTRL + code:113", ours.keys);
    try std.testing.expectEqualStrings("/home/test/tildaz --toggle 9", ours.command);
    // 다른 실행 파일 (dev ↔ 릴리즈) 의 binding 은 우리 것이 아니다 — legacy 와 같은 기준.
    try std.testing.expect(parseLuaDescription("/usr/bin/tildaz --toggle 0 · F1", exe) == null);
    // 사용자 binding 의 설명 · 표식 없는 설명.
    try std.testing.expect(parseLuaDescription("Open terminal", exe) == null);
    try std.testing.expect(parseLuaDescription("/home/test/tildaz --toggle 9 · ", exe) == null);
    try std.testing.expect(parseLuaDescription("", exe) == null);
}

test "#695 sync recognises our Lua and legacy position bindings from binds JSON" {
    const a = std.testing.allocator;
    // Lua 로 건 binding 의 실제 모양 — `__lua` · registry 번호 · 위치 binding 은 키가 빈다.
    const json =
        \\[{"modmask":4,"key":"","keycode":0,"dispatcher":"__lua","arg":"23","submap":"","description":"/home/test/tildaz --toggle 9 · CTRL + code:113"},
        \\ {"modmask":64,"key":"Q","keycode":0,"dispatcher":"__lua","arg":"5","submap":"","description":""},
        \\ {"modmask":4,"key":"","keycode":49,"dispatcher":"exec","arg":"/home/test/tildaz --toggle 1","submap":"","description":""}]
    ;
    const parsed = try std.json.parseFromSlice([]HyprlandBind, a, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const exe = "/home/test/tildaz";
    var buf: [96]u8 = undefined;

    const lua = managedHyprlandBinding(&buf, parsed.value[0], exe, .lua).?;
    try std.testing.expectEqualStrings("CTRL + code:113", lua.keys);
    try std.testing.expect(managedHyprlandBinding(&buf, parsed.value[1], exe, .lua) == null);

    // legacy 의 위치 binding — 예전에는 여기서 null 이라 매 실행 중복이 쌓였다.
    const legacy = managedHyprlandBinding(&buf, parsed.value[2], exe, .legacy).?;
    try std.testing.expectEqualStrings("CTRL ,code:49", legacy.keys);
    try std.testing.expectEqualStrings("/home/test/tildaz --toggle 1", legacy.command);
}

test "#695 only an ok reply counts as success" {
    try std.testing.expect(isHyprctlOk("ok"));
    try std.testing.expect(isHyprctlOk("ok\n"));
    // 둘 다 종료 코드 0 으로 온다 (실측 · `hyprctl/src/main.cpp`).
    try std.testing.expect(!isHyprctlOk("keyword can't work with non-legacy parsers. Use eval."));
    try std.testing.expect(!isHyprctlOk("eval is only supported with the lua config manager"));
    try std.testing.expect(!isHyprctlOk("error: [string \"hl.bind(...)\"]:1: bad key"));
    try std.testing.expect(!isHyprctlOk(""));
}

/// 테스트용 — 한 항목짜리 맵을 스캔해 그 항목에 판정을 돌린다 (#700 — 판정이 줄이 아니라 항목을 본다).
fn testScanOne(comptime entry: []const u8, comptime judge: fn (cosmic_ron.Entry) ?u32) !?u32 {
    const map = try cosmic_ron.scan(std.testing.allocator, "{\n" ++ entry ++ "\n}\n");
    defer map.deinit(std.testing.allocator);
    if (map.entries.len != 1) return error.TestUnexpectedResult;
    return judge(map.entries[0]);
}

test "COSMIC entries are identified by our own description marker, not the command" {
    const ours = tildazCosmicEntryIndex;
    // writer(`appendCosmicEntries`)가 만드는 형태.
    try std.testing.expectEqual(@as(?u32, 0), try testScanOne(
        "    (modifiers: [], key: \"F1\", description: Some(\"" ++ app_id.window_base ++ "_0\")): Spawn(\"/usr/bin/tildaz --toggle 0\"),",
        ours,
    ));
    // #700 · #681 — COSMIC 설정 화면이 다시 쓴 **여러 줄** 항목도 같은 항목이다.
    try std.testing.expectEqual(@as(?u32, 0), try testScanOne(
        "    (\n        modifiers: [],\n        key: \"F1\",\n        description: Some(\"" ++ app_id.window_base ++ "_0\"),\n    ): Spawn(\"/usr/bin/tildaz --toggle 0\"),",
        ours,
    ));

    // #484 회귀 — 바이너리 **이름**이 `tildaz` 가 아니면 이전 구현은 자기 항목을 못
    // 알아봤다. `tildaz-dev --toggle 0` 에는 `tildaz --toggle` 이라는 연속 문자열이
    // 없다 (하이픈이 끼어서). 못 지우고 하나 더 써서 같은 단축키가 둘 남았다.
    try std.testing.expectEqual(@as(?u32, 0), try testScanOne(
        "    (modifiers: [], key: \"F1\", description: Some(\"" ++ app_id.window_base ++ "_0\")): Spawn(\"/opt/bin/tildaz-dev --toggle 0\"),",
        ours,
    ));
    // 경로만 바뀐 경우도 같이 고정한다.
    try std.testing.expectEqual(@as(?u32, 3), try testScanOne(
        "    (modifiers: [Ctrl, Shift], key: \"F2\", description: Some(\"" ++ app_id.window_base ++ "_3\")): Spawn(\"/home/u/bin/tz --toggle 3\"),",
        ours,
    ));
    // 여러 자리 index.
    try std.testing.expectEqual(@as(?u32, 12), try testScanOne(
        "    (modifiers: [Super], key: \"grave\", description: Some(\"" ++ app_id.window_base ++ "_12\")): Spawn(\"/usr/bin/tildaz --toggle 12\"),",
        ours,
    ));

    // #484 거울상 — 사용자 항목의 **명령**에 `tildaz --toggle` 이 들어 있으면 이전
    // 구현은 우리 것으로 착각해 조용히 지웠다. 이제 남의 항목은 건드리지 않는다.
    try std.testing.expectEqual(@as(?u32, null), try testScanOne(
        "    (modifiers: [Super], key: \"t\", description: Some(\"My wrapper\")): Spawn(\"sh -c 'tildaz --toggle 0; notify-send hi'\"),",
        ours,
    ));
    // 표식을 흉내낸 남의 이름 — 번호 자리가 정수가 아니면 우리 것이 아니다.
    try std.testing.expectEqual(@as(?u32, null), try testScanOne(
        "    (modifiers: [Super], key: \"b\", description: Some(\"" ++ app_id.window_base ++ "_backup\")): Spawn(\"/usr/bin/backup\"),",
        ours,
    ));
    // 번호 자리가 비어 있는 경우.
    try std.testing.expectEqual(@as(?u32, null), try testScanOne(
        "    (modifiers: [Super], key: \"n\", description: Some(\"" ++ app_id.window_base ++ "_\")): Spawn(\"/usr/bin/x\"),",
        ours,
    ));
    // 음수는 index 가 아니다 (`u32`).
    try std.testing.expectEqual(@as(?u32, null), try testScanOne(
        "    (modifiers: [Super], key: \"m\", description: Some(\"" ++ app_id.window_base ++ "_-1\")): Spawn(\"/usr/bin/x\"),",
        ours,
    ));
    // 전혀 무관한 사용자 항목 · 표식이 없는 항목.
    try std.testing.expectEqual(@as(?u32, null), try testScanOne(
        "    (modifiers: [Super], key: \"e\", description: Some(\"My file manager\")): Spawn(\"nautilus\"),",
        ours,
    ));
    try std.testing.expectEqual(@as(?u32, null), try testScanOne(
        "    (modifiers: [Super], key: \"q\"): Close,",
        ours,
    ));
    // #654 — **개발 빌드는 릴리즈의 표식 (`TildaZ_N`) 을 자기 것으로 보지 않는다.** 이 판정에
    // 걸린 항목은 `syncCosmic` 이 지우고 다시 쓰므로, 여기가 틀리면 dev 가 사용자의 릴리즈
    // 단축키를 자기 exe 로 바꿔 쓴다. 릴리즈 쪽 리터럴은 동작이 안 바뀌었다는 회귀 가드다.
    if (app_id.is_dev) {
        try std.testing.expectEqual(@as(?u32, null), try testScanOne(
            "    (modifiers: [], key: \"F1\", description: Some(\"TildaZ_0\")): Spawn(\"/usr/bin/tildaz --toggle 0\"),",
            ours,
        ));
        try std.testing.expectEqualStrings("description: Some(\"TildaZ-dev_", cosmic_entry_marker);
    } else {
        try std.testing.expectEqualStrings("description: Some(\"TildaZ_", cosmic_entry_marker);
    }
    // 죽어 있던 옛 표식(`TildaZ instance `)은 writer 가 쓴 적이 없으므로 인식 대상이
    // 아니다 — 살릴 것은 그 절의 *의도* 였고 문자열이 아니다.
    try std.testing.expectEqual(@as(?u32, null), try testScanOne(
        "    (modifiers: [], key: \"F1\", description: Some(\"TildaZ instance 0\")): Spawn(\"/usr/bin/tildaz --toggle 0\"),",
        ours,
    ));
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

/// COSMIC 단축키 폴더. COSMIC (cosmic-config) 은 `XDG_CONFIG_HOME` 을 따른다 (#700 — 예전에는
/// `$HOME/.config` 로 고정돼 있었다).
fn cosmicShortcutsDir(rt: Runtime, allocator: std.mem.Allocator) ![]u8 {
    const base = try paths.configHome(rt, allocator);
    defer allocator.free(base);
    return std.Io.Dir.path.join(allocator, &.{ base, "cosmic", "com.system76.CosmicSettings.Shortcuts", "v1" });
}

/// `custom` 을 읽는다. 없으면 빈 맵으로 보고 `existed` 를 거짓으로 둔다 (백업할 원본이 없다).
fn readCosmicCustom(rt: Runtime, allocator: std.mem.Allocator, path: []const u8, existed: *bool) ![]u8 {
    const file = std.Io.Dir.openFileAbsolute(rt.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            existed.* = false;
            return allocator.dupe(u8, "{\n}\n");
        },
        else => return err,
    };
    defer file.close(rt.io);
    existed.* = true;
    // #451 — `fs.File.readToEndAlloc` ➡️ `File.Reader` 의 `allocRemaining`
    // (릴리즈 노트 *fs.File.readToEndAlloc*).
    var file_reader = file.reader(rt.io, &.{});
    return file_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
}

/// #700 — 고친 내용을 쓴다. 바뀐 게 없으면 열지도 않는다 (cosmic-comp 가 파일이 바뀔 때마다
/// 다시 읽는다). 쓰기 전에 원본을 백업한다 (`writeCosmicBackups`) — 망가지면 되돌리기 어려운
/// 파일이라서다 (#700 D3).
fn writeCosmicCustom(rt: Runtime, allocator: std.mem.Allocator, path: []const u8, old: []const u8, existed: bool, new: []const u8) !bool {
    if (std.mem.eql(u8, old, new)) return false;
    if (existed) try writeCosmicBackups(rt, allocator, old);
    return paths.writeFileIfChanged(rt, allocator, path, new);
}

/// 백업 이름의 앞부분과 남길 개수. `.orig` 는 우리가 처음 고치기 전의 원본이고 지우지 않는다
/// (GNU `patch` · `git mergetool` 이 쓰는 이름). 나머지는 고칠 때마다 직전 내용을
/// `<base>.<YYYYMMDD>-<그날의 순번>` 으로 남기고 최근 `cosmic_backup_keep` 개만 둔다.
const cosmic_backup_base = "cosmic-shortcuts-custom";
const cosmic_backup_keep = 20;

const CosmicBackup = struct {
    date: u32,
    seq: u32,

    fn less(_: void, a: CosmicBackup, b: CosmicBackup) bool {
        return if (a.date != b.date) a.date < b.date else a.seq < b.seq;
    }
};

/// `cosmic-shortcuts-custom.20261009-3` → 날짜 20261009 · 순번 3. 다른 이름이면 `null`.
fn parseCosmicBackupName(name: []const u8) ?CosmicBackup {
    const prefix = cosmic_backup_base ++ ".";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const rest = name[prefix.len..];
    if (rest.len < 10 or rest[8] != '-') return null;
    for (rest[0..8]) |c| if (!std.ascii.isDigit(c)) return null;
    for (rest[9..]) |c| if (!std.ascii.isDigit(c)) return null;
    const date = std.fmt.parseInt(u32, rest[0..8], 10) catch return null;
    const seq = std.fmt.parseInt(u32, rest[9..], 10) catch return null;
    if (seq == 0) return null;
    return .{ .date = date, .seq = seq };
}

/// 날짜순으로 정렬된 목록에서 지울 앞부분 — 최근 `keep` 개만 남긴다.
fn cosmicBackupsToDrop(sorted: []const CosmicBackup, keep: usize) []const CosmicBackup {
    return if (sorted.len > keep) sorted[0 .. sorted.len - keep] else sorted[0..0];
}

fn writeCosmicBackups(rt: Runtime, allocator: std.mem.Allocator, old: []const u8) !void {
    const dir_path = try paths.backupDir(rt, allocator);
    defer allocator.free(dir_path);
    try paths.ensureDir(rt, dir_path);

    const orig = try std.Io.Dir.path.join(allocator, &.{ dir_path, cosmic_backup_base ++ ".orig" });
    defer allocator.free(orig);
    if (std.Io.Dir.openFileAbsolute(rt.io, orig, .{})) |f| {
        f.close(rt.io);
    } else |_| {
        _ = try paths.writeFileIfChanged(rt, allocator, orig, old);
        log.appendLine("cosmic", "original shortcut file backed up to {s}", .{orig});
    }

    var dir = try std.Io.Dir.openDirAbsolute(rt.io, dir_path, .{ .iterate = true });
    defer dir.close(rt.io);
    var backups: std.ArrayList(CosmicBackup) = .empty;
    defer backups.deinit(allocator);
    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        if (parseCosmicBackupName(entry.name)) |b| try backups.append(allocator, b);
    }

    const t = log.currentLocalTime();
    const today: u32 = @as(u32, t.year) * 10000 + @as(u32, t.month) * 100 + t.day;
    var seq: u32 = 1;
    for (backups.items) |b| {
        if (b.date == today and b.seq >= seq) seq = b.seq + 1;
    }
    var name_buf: [96]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, cosmic_backup_base ++ ".{d:0>8}-{d}", .{ today, seq });
    const path = try std.Io.Dir.path.join(allocator, &.{ dir_path, name });
    defer allocator.free(path);
    _ = try paths.writeFileIfChanged(rt, allocator, path, old);
    try backups.append(allocator, .{ .date = today, .seq = seq });

    std.mem.sort(CosmicBackup, backups.items, {}, CosmicBackup.less);
    for (cosmicBackupsToDrop(backups.items, cosmic_backup_keep)) |b| {
        const drop = try std.fmt.bufPrint(&name_buf, cosmic_backup_base ++ ".{d:0>8}-{d}", .{ b.date, b.seq });
        dir.deleteFile(rt.io, drop) catch |err| log.appendLine("cosmic", "old backup {s} not removed: {s}", .{ drop, @errorName(err) });
    }
}

test "#700 COSMIC backups are named by date and sequence and only the latest are kept" {
    try std.testing.expectEqual(CosmicBackup{ .date = 20261009, .seq = 3 }, parseCosmicBackupName("cosmic-shortcuts-custom.20261009-3").?);
    try std.testing.expectEqual(CosmicBackup{ .date = 20261009, .seq = 12 }, parseCosmicBackupName("cosmic-shortcuts-custom.20261009-12").?);
    // 원본 · 남의 파일 · 모양이 다른 이름은 목록에 넣지 않는다 (지우지도 않는다).
    for ([_][]const u8{
        "cosmic-shortcuts-custom.orig",
        "cosmic-shortcuts-custom.20261009",
        "cosmic-shortcuts-custom.20261009-",
        "cosmic-shortcuts-custom.20261009-0",
        "cosmic-shortcuts-custom.2026100x-1",
        "cosmic-shortcuts-custom.20261009-1.tmp",
        "notes.txt",
    }) |name| try std.testing.expect(parseCosmicBackupName(name) == null);

    // 날짜가 먼저, 같은 날이면 순번 — 순번 10 이 2 보다 뒤다 (글자 순서가 아니다).
    var list = [_]CosmicBackup{ .{ .date = 20261010, .seq = 1 }, .{ .date = 20261009, .seq = 10 }, .{ .date = 20261009, .seq = 2 } };
    std.mem.sort(CosmicBackup, &list, {}, CosmicBackup.less);
    try std.testing.expectEqual(CosmicBackup{ .date = 20261009, .seq = 2 }, list[0]);
    try std.testing.expectEqual(CosmicBackup{ .date = 20261010, .seq = 1 }, list[2]);
    // 가장 오래된 것부터 지운다.
    try std.testing.expectEqual(@as(usize, 1), cosmicBackupsToDrop(&list, 2).len);
    try std.testing.expectEqual(CosmicBackup{ .date = 20261009, .seq = 2 }, cosmicBackupsToDrop(&list, 2)[0]);
    try std.testing.expectEqual(@as(usize, 0), cosmicBackupsToDrop(&list, 20).len);
}

fn syncCosmic(rt: Runtime, allocator: std.mem.Allocator, indices: []const u32) !void {
    const dir_path = try cosmicShortcutsDir(rt, allocator);
    defer allocator.free(dir_path);
    // #451 — `fs.Dir.makePath` ➡️ 공용 helper (`paths.ensureDir` = `createDirPath`).
    try paths.ensureDir(rt, dir_path);
    const path = try std.Io.Dir.path.join(allocator, &.{ dir_path, "custom" });
    defer allocator.free(path);

    var existed = false;
    const content = try readCosmicCustom(rt, allocator, path, &existed);
    defer allocator.free(content);

    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // #451 — `fs.selfExePath` ➡️ `std.process.executablePath` (길이를 돌려준다).
    const exe_len = try std.process.executablePath(rt.io, &exe_buf);
    const exe = exe_buf[0..exe_len];

    // #700 — 줄이 아니라 항목 단위로 본다. 읽을 수 없는 파일은 **쓰지 않는다** — 그대로 두고 알린다.
    const map = cosmic_ron.scan(allocator, content) catch |err| {
        log.appendLine("cosmic", "shortcut file could not be read safely — left unchanged: {s} ({s})", .{ @errorName(err), path });
        return err;
    };
    defer map.deinit(allocator);

    const remove = try allocator.alloc(bool, map.entries.len);
    defer allocator.free(remove);
    for (map.entries, remove) |entry, *gone| {
        // #496 1-c — 우리 항목은 지우고 다시 쓰는 구조다. 그런데 **위치 표기 인스턴스의
        // 항목은 워커가 쓴 것**이라 여기서 지우면 launcher 가 돌 때마다 사라진다. 그래서
        // 그 인스턴스의 항목만 남긴다.
        //
        // #514 — 표식 없는 옛 `install.sh` 항목은 **우리가 그 index 를 실제로 관리할 때만**
        // 흡수한다. config 를 지운 인스턴스의 항목까지 지우면 판정 근거가 다시 넓어진다.
        //
        // #654 — **개발 빌드는 흡수하지 않는다.** 옛 항목의 basename 은 dev 도 `tildaz` 라 (zig-out
        // 의 바이너리 이름) 릴리즈가 남긴 것과 구별할 수 없다. 남의 것을 지우는 쪽이 더
        // 위험하다 (dconf 잔재 `tildaz-N` 을 두는 것과 같은 판단).
        gone.* = if (tildazCosmicEntryIndex(entry)) |idx|
            !cosmicDeferredToWorker(rt, allocator, idx)
        else if (!app_id.is_dev) legacy: {
            const idx = legacyInstallScriptEntryIndex(entry) orelse break :legacy false;
            break :legacy std.mem.findScalar(u32, indices, idx) != null;
        } else false;
    }

    var insert: std.ArrayList(u8) = .empty;
    defer insert.deinit(allocator);
    const count = try appendCosmicEntries(rt, &insert, allocator, indices, exe);

    const output = cosmic_ron.rewrite(allocator, content, map, remove, insert.items, count) catch |err| {
        log.appendLine("cosmic", "shortcut file edit did not verify — left unchanged: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(output);

    if (try writeCosmicCustom(rt, allocator, path, content, existed, output)) {
        log.appendLine("cosmic", "numbered hotkeys synchronized ({d})", .{indices.len});
    } else {
        log.appendLine("cosmic", "numbered hotkeys already synchronized ({d})", .{indices.len});
    }
}

/// COSMIC custom shortcut 항목이 **우리가 쓴 것**이면 그 instance index.
///
/// 근거는 `appendCosmicEntries` 가 직접 쓰는 description 표식
/// (`description: Some("TildaZ_<index>")`) 하나다. 명령 문자열을 보지 않는 이유가
/// [#484](https://github.com/ensky0/tildaz/issues/484) 다 — 이전 구현은
/// `Spawn("` + `tildaz --toggle` 부분 일치였고, 명령에는 바이너리 경로와 이름이
/// 들어가서 **사용자가 바꿀 수 있는 값**을 판정 근거로 삼고 있었다. 양방향으로 틀렸다.
///
/// - 이름을 바꾸면 (`tildaz-dev --toggle 0`) `tildaz --toggle` 이라는 연속 문자열이
///   사라져 자기 항목을 못 알아봤다. 지우지 못한 채 하나 더 썼다.
/// - 반대로 사용자 항목의 명령에 `tildaz --toggle` 이 들어 있으면 (래퍼 스크립트 등)
///   우리 것으로 착각해 **조용히 지웠다.**
///
/// 표식은 경로 · 이름과 무관하므로 두 방향이 함께 사라진다.
///
/// **접두 매칭**인 이유는 `syncCosmic` 이 "자기 항목 전부 삭제 후 현재 config 목록대로
/// 재작성" 구조라서다 — config 를 지운 인스턴스의 유령 항목도 정리돼야 한다. 단 번호
/// 자리가 정말 정수인지 확인해 `TildaZ_backup` 같은 남의 이름을 집지 않는다 (Hyprland
/// 쪽 `managedToggleCommand` 와 같은 엄격함).
///
/// #700 — 줄이 아니라 **항목**을 본다. COSMIC 설정 화면은 `description` 을 다른 줄에 쓴다 (#681).
/// #496 1-c 가 index 를 쓴다 — **어느 인스턴스의 항목인지** 알아야 위치 표기 인스턴스의 항목을
/// 지우지 않고 남길 수 있다.
fn tildazCosmicEntryIndex(entry: cosmic_ron.Entry) ?u32 {
    const raw = cosmic_ron.field(entry.key, "description") orelse return null;
    var buf: [256]u8 = undefined;
    const description = cosmic_ron.someString(raw, &buf) orelse return null;
    if (!std.mem.startsWith(u8, description, cosmic_description_prefix)) return null;
    const digits = description[cosmic_description_prefix.len..];
    if (digits.len == 0) return null;
    return std.fmt.parseInt(u32, digits, 10) catch null;
}

/// #514 — 예전 [`dist/linux/install.sh`](../../dist/linux/install.sh) 가 쓴 **표식 없는**
/// COSMIC 항목이면 그 instance index.
///
/// 그 스크립트는 `description` 을 안 붙이고 자기 항목을 썼다. 그래서 launcher 가 자기
/// 것으로 못 알아보고 하나 더 썼고, 같은 hotkey 가 RON 에 두 번 남았다. 지금 install.sh 는
/// COSMIC 항목을 아예 쓰지 않으므로 (writer 는 이 파일 하나다), 남아 있는 옛 줄을 여기서
/// 흡수한다.
///
/// **경로는 보지 않는다** (#583 B18 · 2026-09-05). 예전에는 *지금 실행 파일 경로* 와 바이트까지
/// 같을 때만 흡수했는데, `install.sh` 는 압축을 푼 자리의 `realpath` 를 썼으므로 **새 버전을 다른
/// 곳에 두면 그 줄이 영원히 남았다.** 그리고 남은 줄의 키 이름이 COSMIC 이 모르는 것이면
/// cosmic-settings-daemon 이 custom 파일 **전체**를 무시해 (#484 의 그 증상) 사용자의 다른 단축키까지
/// 죽는다 — v0.9.0 마감 댓글이 "그 줄을 손으로 지우세요" 로 남긴 자리다.
///
/// 대신 **명령의 모양**을 좁게 본다. #484 의 교훈 ("명령 문자열의 *부분* 일치로 판정하지 말라") 은
/// 그대로 지킨다:
///
/// - `description` 이 **아예 없다.** 사용자가 이름을 붙인 줄은 명령이 겹쳐도 남긴다.
/// - 명령이 **공백 없는 실행 파일 경로 + `--toggle [N]`** 뿐이다. 앞에 래퍼가 붙은 줄
///   (`/opt/wrap /…/tildaz --toggle 0`) 은 첫 토큰이 `wrap` 이라 걸러지고, `sh -c '…'` 도
///   `sh` 라 걸러진다. 인자가 더 붙은 줄 (`--toggle 0 --extra`) 도 아니다.
/// - 그 경로의 **basename 이 정확히 `tildaz`** 다. `tildaz-dev` 는 우리 것이 아니다.
/// - 번호 없는 `--toggle` 도 받는다 — #230 의 첫 형태다 (인스턴스 번호가 생기기 전).
///
/// 공백이 든 경로 (`/home/my apps/tildaz`) 는 흡수하지 않는다 — 첫 토큰으로 자르는 규칙의 대가이고,
/// 래퍼를 걸러내는 것이 그보다 중요하다. 그런 줄은 여전히 손으로 지운다.
///
/// 그래도 위험이 하나 남는다: 사용자가 **같은 모양의 단축키**를 손수 만들어 뒀다면 (표식 없이
/// `<경로>/tildaz --toggle 0`) 그것도 우리 것으로 본다. 호출부 (`syncCosmic`) 가 "우리가 그 index 를
/// 실제로 관리할 때만" 으로 한 번 더 좁힌다.
///
/// #700 — 줄이 아니라 **항목**을 본다 (키에 `description` 필드가 없고, 값이 `Spawn("…")` 인 항목).
fn legacyInstallScriptEntryIndex(entry: cosmic_ron.Entry) ?u32 {
    if (cosmic_ron.field(entry.key, "description") != null) return null;
    var buf: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    const command = cosmic_ron.spawnCommand(entry.value, &buf) orelse return null;
    const space = std.mem.findScalar(u8, command, ' ') orelse return null;
    const path = command[0..space];
    const args = command[space + 1 ..];
    if (!std.mem.eql(u8, std.Io.Dir.path.basename(path), "tildaz")) return null;
    // #230 의 첫 형태 — 인스턴스 번호가 없던 때라 0 번이다.
    if (std.mem.eql(u8, args, "--toggle")) return 0;
    const numbered = "--toggle ";
    if (!std.mem.startsWith(u8, args, numbered)) return null;
    return std.fmt.parseInt(u32, args[numbered.len..], 10) catch null;
}

test "#514 · #583 B18 표식 없는 옛 install.sh 줄은 명령의 *모양* 으로만 흡수한다 (경로는 보지 않는다)" {
    // 옛 install.sh 가 쓴 형태 — 표식이 없고 명령이 실행 파일 경로 + `--toggle N` 뿐이다.
    try std.testing.expectEqual(@as(?u32, 0), try testScanOne(
        "    (modifiers: [], key: \"F1\"): Spawn(\"/home/u/.local/bin/tildaz --toggle 0\"),",
        legacyInstallScriptEntryIndex,
    ));
    try std.testing.expectEqual(@as(?u32, 3), try testScanOne(
        "    (modifiers: [Ctrl, Shift], key: \"grave\"): Spawn(\"/home/u/.local/bin/tildaz --toggle 3\"),",
        legacyInstallScriptEntryIndex,
    ));
    // #230 의 첫 형태 — 번호가 없던 때. 0 번이다.
    try std.testing.expectEqual(@as(?u32, 0), try testScanOne(
        "    (modifiers: [], key: \"F1\"): Spawn(\"/home/u/.local/bin/tildaz --toggle\"),",
        legacyInstallScriptEntryIndex,
    ));
    // #583 B18 — **경로가 달라도 흡수한다.** 이것이 예전에 `null` 이었고, 그래서 새 버전을 다른
    // 곳에 두면 옛 줄이 영원히 남았다 (키 이름이 모르는 것이면 custom 파일 전체가 무시된다).
    try std.testing.expectEqual(@as(?u32, 0), try testScanOne(
        "    (modifiers: [], key: \"F1\"): Spawn(\"/usr/bin/tildaz --toggle 0\"),",
        legacyInstallScriptEntryIndex,
    ));
    try std.testing.expectEqual(@as(?u32, 2), try testScanOne(
        "    (modifiers: [], key: \"F3\"): Spawn(\"/tmp/tildaz-0.8.0/tildaz --toggle 2\"),",
        legacyInstallScriptEntryIndex,
    ));
    // PATH 에 의존한 맨 이름도 우리 것이다.
    try std.testing.expectEqual(@as(?u32, 1), try testScanOne(
        "    (modifiers: [], key: \"F2\"): Spawn(\"tildaz --toggle 1\"),",
        legacyInstallScriptEntryIndex,
    ));

    // 표식이 있으면 여기 소관이 아니다 — 우리 줄이든 사용자가 이름 붙인 줄이든.
    try std.testing.expectEqual(@as(?u32, null), try testScanOne(
        "    (modifiers: [], key: \"F1\", description: Some(\"" ++ app_id.window_base ++ "_0\")): Spawn(\"/home/u/.local/bin/tildaz --toggle 0\"),",
        legacyInstallScriptEntryIndex,
    ));
    try std.testing.expectEqual(@as(?u32, null), try testScanOne(
        "    (modifiers: [], key: \"F1\", description: Some(\"My toggle\")): Spawn(\"/home/u/.local/bin/tildaz --toggle 0\"),",
        legacyInstallScriptEntryIndex,
    ));

    // #484 의 교훈 — 부분 일치로 판정하지 않는다. 아래 줄들은 명령에 우리 경로가 들어 있어도
    // **첫 토큰이 우리 실행 파일이 아니거나** 인자가 더 붙어 있어 우리 것이 아니다.
    try std.testing.expectEqual(@as(?u32, null), try testScanOne(
        "    (modifiers: [], key: \"F1\"): Spawn(\"/opt/wrap /home/u/.local/bin/tildaz --toggle 0\"),",
        legacyInstallScriptEntryIndex,
    ));
    try std.testing.expectEqual(@as(?u32, null), try testScanOne(
        "    (modifiers: [], key: \"F1\"): Spawn(\"sh -c '/home/u/.local/bin/tildaz --toggle 0; notify-send hi'\"),",
        legacyInstallScriptEntryIndex,
    ));
    try std.testing.expectEqual(@as(?u32, null), try testScanOne(
        "    (modifiers: [], key: \"F1\"): Spawn(\"/home/u/.local/bin/tildaz --toggle 0 --extra\"),",
        legacyInstallScriptEntryIndex,
    ));
    // 이름이 다른 빌드 — `tildaz-dev` 는 우리 것이 아니다 (basename 정확 일치).
    try std.testing.expectEqual(@as(?u32, null), try testScanOne(
        "    (modifiers: [], key: \"F1\"): Spawn(\"/home/u/.local/bin/tildaz-dev --toggle 0\"),",
        legacyInstallScriptEntryIndex,
    ));
    // 다른 하위 명령.
    try std.testing.expectEqual(@as(?u32, null), try testScanOne(
        "    (modifiers: [], key: \"F1\"): Spawn(\"/home/u/.local/bin/tildaz --autostart\"),",
        legacyInstallScriptEntryIndex,
    ));
    // 번호 자리가 정수가 아니다.
    try std.testing.expectEqual(@as(?u32, null), try testScanOne(
        "    (modifiers: [], key: \"F1\"): Spawn(\"/home/u/.local/bin/tildaz --toggle x\"),",
        legacyInstallScriptEntryIndex,
    ));
    // 공백이 든 경로는 흡수하지 않는다 — 첫 토큰으로 자르는 규칙의 대가다 (문서에 적었다).
    try std.testing.expectEqual(@as(?u32, null), try testScanOne(
        "    (modifiers: [], key: \"F1\"): Spawn(\"/home/my apps/tildaz --toggle 0\"),",
        legacyInstallScriptEntryIndex,
    ));
    // 인자가 아예 없다.
    try std.testing.expectEqual(@as(?u32, null), try testScanOne(
        "    (modifiers: [], key: \"F1\"): Spawn(\"/home/u/.local/bin/tildaz\"),",
        legacyInstallScriptEntryIndex,
    ));
}

test "#514 escaped paths in a legacy entry are matched after unescaping" {
    // `appendRonString` 이 `\\` 와 `"` 를 escape 한다. 읽는 쪽이 같은 규칙을 풀어야
    // 따옴표가 든 경로에서 판정이 갈리지 않는다.
    //
    // #583 B18 — 경로에 **공백**이 있으면 흡수하지 않는다 (첫 토큰으로 자른다). 그래서 이
    // 회귀 테스트의 경로에서 공백을 뺐다 — 검증하려는 것은 escape 해제이고, 공백 경로는
    // 위 테스트가 `null` 로 고정한다. 공백을 허용하면 앞에 래퍼가 붙은 줄
    // (`/opt/wrap /…/tildaz --toggle 0`) 을 우리 것으로 오판한다 (#484 가 그 오판이었다).
    try std.testing.expectEqual(@as(?u32, 2), try testScanOne(
        "    (modifiers: [], key: \"F1\"): Spawn(\"/home/u/my\\\"odd\\\"dir/tildaz --toggle 2\"),",
        legacyInstallScriptEntryIndex,
    ));
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

/// `appendCosmicEntries` 의 writer 와 `tildazCosmicEntryIndex` 의 matcher 가 **같은**
/// 표식을 쓰게 묶어 둔다. 이 둘이 갈라진 게 #484 의 원인이었다 — matcher 는
/// `TildaZ instance ` 를 찾는데 writer 는 `TildaZ_<index>` 를 써서 그 절이 죽어 있었고,
/// 그래서 명령 문자열 매칭으로 떨어졌다.
///
/// **`app_id.window_base` 를 탄다** (#654) — `TildaZ_<index>` · `TildaZ-dev_<index>`. 두 판이 같은
/// 표식을 쓰면 `syncCosmic` 의 "자기 항목 전부 삭제 후 재작성" 이 **릴리즈의 항목을 지우고 dev 의
/// exe 로 다시 쓴다.** kglobalaccel · dconf 와 같은 부류의 함정이고 (Linux 회차 결함 5 · 6),
/// 그 회차가 KDE 기기여서 COSMIC 만 남아 있었다.
const cosmic_description_prefix = app_id.window_base ++ "_";
const cosmic_entry_marker = "description: Some(\"" ++ cosmic_description_prefix;

fn appendCosmicEntries(
    rt: Runtime,
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    indices: []const u32,
    exe: []const u8,
) !usize {
    // #700 — 넣은 항목 수. 고친 결과를 다시 스캔해 항목 수가 맞는지 볼 때 쓴다.
    var count: usize = 0;
    for (indices) |index| {
        const text = try instances.configHotkeyText(rt, allocator, index);
        defer allocator.free(text);
        const hotkey = config.Hotkey.fromString(text) orelse return error.InvalidConfig;
        // #496 1-c — 위치 표기는 워커가 쓴다 (`cosmicDeferredToWorker` 주석).
        if (hotkey.code != null) continue;
        // #616 — 시스템 기본과 겹치면 **우리가 이긴다.** 막지 않고 알리기만 한다 (위 함수 주석).
        var override_buf: [256]u8 = undefined;
        if (cosmicSystemDefaultOverride(rt, allocator, hotkey, &override_buf) catch null) |taken| {
            log.appendLine("cosmic", "instance {d} hotkey overrides a COSMIC system shortcut — that default stops working while the entry exists: {s}", .{ index, taken });
        }
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
        count += 1;
    }
    return count;
}

/// 엔트리의 `key:` 뒤쪽. **writer 를 한 곳으로 묶어 둔다** — 표식이 matcher 와 갈라지면
/// 자기 항목을 못 알아보고 하나 더 써서 같은 단축키가 둘 남는다 (#484 의 기전). COSMIC 은 그때
/// 뒤의 항목만 쓰고 앞의 것은 조용히 무시한다 (#700 조사).
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
/// 쓴다. 두 경로가 **같은 항목 규칙**을 쓰게 묶어 둔다 — 지우는 쪽과 쓰는 쪽이 갈리면
/// 같은 단축키가 둘 생기고, 옛 키가 계속 토글한다 (#484).
fn rewriteCosmicPositionEntry(
    rt: Runtime,
    allocator: std.mem.Allocator,
    index: u32,
    key_name: ?[]const u8,
    modifiers: u32,
) !void {
    const dir_path = try cosmicShortcutsDir(rt, allocator);
    defer allocator.free(dir_path);
    try paths.ensureDir(rt, dir_path);
    const path = try std.Io.Dir.path.join(allocator, &.{ dir_path, "custom" });
    defer allocator.free(path);

    var existed = false;
    const content = try readCosmicCustom(rt, allocator, path, &existed);
    defer allocator.free(content);

    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_len = try std.process.executablePath(rt.io, &exe_buf);
    const exe = exe_buf[0..exe_len];

    const output = renderCosmicPositionRon(allocator, content, exe, index, key_name, modifiers) catch |err| {
        log.appendLine("cosmic", "shortcut file could not be edited safely — left unchanged: {s} ({s})", .{ @errorName(err), path });
        return err;
    };
    defer allocator.free(output);

    // #513 — **안 쓴 경우에도 남긴다.** 예전엔 `writeFileIfChanged` 가 false 면 아무
    // 로그도 없어서, 로그만 보면 "이미 맞아서 안 씀" 과 "이 경로를 아예 안 탐" 이
    // 구분되지 않았다. keymap 재전송을 쫓을 때 특히 걸린다.
    if (try writeCosmicCustom(rt, allocator, path, content, existed, output)) {
        if (key_name) |name| {
            log.appendLine("cosmic", "position hotkey entry written key={s}", .{name});
        } else {
            log.appendLine("cosmic", "position hotkey entry withdrawn", .{});
        }
    } else if (key_name) |name| {
        log.appendLine("cosmic", "position hotkey entry already current key={s}", .{name});
    } else {
        log.appendLine("cosmic", "position hotkey entry already absent", .{});
    }
}

test "#496 1-c dead key layout withdraws the previous position entry" {
    // 실기 (cosmic-comp 1.0.0): fr 에서 `twosuperior` 로 쓰인 뒤 de 로 바꾸면 그 줄이
    // 그대로 남아 사용자 단축키 목록에 죽은 항목이 됐다. 거두는 쪽이 사용자 항목과 남의
    // 인스턴스는 건드리지 않는 것까지 함께 고정한다.
    // 표식은 빌드마다 다르다 (`-Drelease` · #654) — `M` 으로 조립한다.
    const M = app_id.window_base;
    const before =
        "{\n" ++
        "    (modifiers: [], key: \"F1\"): Spawn(\"/usr/bin/tildaz --toggle 0\"),\n" ++
        "    (modifiers: [Ctrl], key: \"twosuperior\", description: Some(\"" ++ M ++ "_9\")): Spawn(\"/usr/bin/tildaz --toggle 9\"),\n" ++
        "    (modifiers: [Super], key: \"b\", description: Some(\"" ++ M ++ "_3\")): Spawn(\"/usr/bin/tildaz --toggle 3\"),\n" ++
        "}\n";
    const output = try renderCosmicPositionRon(std.testing.allocator, before, "/usr/bin/tildaz", 9, null, 0);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "{\n" ++
            "    (modifiers: [], key: \"F1\"): Spawn(\"/usr/bin/tildaz --toggle 0\"),\n" ++
            "    (modifiers: [Super], key: \"b\", description: Some(\"" ++ M ++ "_3\")): Spawn(\"/usr/bin/tildaz --toggle 3\"),\n" ++
            "}\n",
        output,
    );
}

test "#496 1-c rewriting a position entry replaces our line instead of adding one" {
    // 같은 단축키가 둘 남으면 옛 키가 계속 토글한다. 재등록이 layout 마다 도는 경로라 이 성질이
    // 특히 중요하다 — 실기에서 us · fr · ru · de 를 오갔다.
    const M = app_id.window_base;
    const before =
        "{\n" ++
        "    (modifiers: [Ctrl], key: \"grave\", description: Some(\"" ++ M ++ "_9\")): Spawn(\"/usr/bin/tildaz --toggle 9\"),\n" ++
        "}\n";
    const output = try renderCosmicPositionRon(std.testing.allocator, before, "/usr/bin/tildaz", 9, "twosuperior", config.Hotkey.MOD_CTRL);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "{\n" ++
            "    (modifiers: [Ctrl], key: \"twosuperior\", description: Some(\"" ++ M ++ "_9\")): Spawn(\"/usr/bin/tildaz --toggle 9\"),\n" ++
            "}\n",
        output,
    );
}

test "#700 the position entry is found and replaced even when COSMIC Settings rewrote it on several lines" {
    // #681 의 모양 — COSMIC 설정 화면이 우리 항목을 여러 줄로 다시 썼다. 예전 코드는 description 줄만
    // 지워 같은 단축키가 둘 남거나 파일이 깨졌다. 이제 항목째 바뀌고 사용자 항목은 글자 그대로 남는다.
    const M = app_id.window_base;
    const before =
        "{\n" ++
        "    (\n        modifiers: [\n            Ctrl,\n        ],\n        key: \"grave\",\n        description: Some(\"" ++ M ++ "_9\"),\n    ): Spawn(\"/usr/bin/tildaz --toggle 9\"),\n" ++
        "    (\n        modifiers: [\n            Super,\n        ],\n        key: \"v\",\n    ): Spawn(\"vicinae\"),\n" ++
        "}";
    const output = try renderCosmicPositionRon(std.testing.allocator, before, "/usr/bin/tildaz", 9, "twosuperior", config.Hotkey.MOD_CTRL);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        "{\n" ++
            "    (\n        modifiers: [\n            Super,\n        ],\n        key: \"v\",\n    ): Spawn(\"vicinae\"),\n" ++
            "    (modifiers: [Ctrl], key: \"twosuperior\", description: Some(\"" ++ M ++ "_9\")): Spawn(\"/usr/bin/tildaz --toggle 9\"),\n" ++
            "}",
        output,
    );
}

/// 파일 내용 → 파일 내용. I/O 를 걷어 낸 순수부라 test 가 두 경로를 다 밟을 수 있다.
/// **내 인스턴스의 항목만** 바꾼다. 남의 인스턴스는 launcher 소관이다. 읽을 수 없는 파일이면
/// 오류다 (호출부가 그대로 둔다).
fn renderCosmicPositionRon(
    allocator: std.mem.Allocator,
    content: []const u8,
    exe: []const u8,
    index: u32,
    key_name: ?[]const u8,
    modifiers: u32,
) ![]u8 {
    const map = try cosmic_ron.scan(allocator, content);
    defer map.deinit(allocator);
    const remove = try allocator.alloc(bool, map.entries.len);
    defer allocator.free(remove);
    for (map.entries, remove) |entry, *gone| {
        gone.* = if (tildazCosmicEntryIndex(entry)) |idx| idx == index else false;
    }

    var insert: std.ArrayList(u8) = .empty;
    defer insert.deinit(allocator);
    if (key_name) |name| {
        try insert.appendSlice(allocator, "    (modifiers: [");
        var first = true;
        const mods = [_]struct { bit: u32, name: []const u8 }{
            .{ .bit = config.Hotkey.MOD_SUPER, .name = "Super" },
            .{ .bit = config.Hotkey.MOD_CTRL, .name = "Ctrl" },
            .{ .bit = config.Hotkey.MOD_ALT, .name = "Alt" },
            .{ .bit = config.Hotkey.MOD_SHIFT, .name = "Shift" },
        };
        for (mods) |mod| {
            if ((modifiers & mod.bit) == 0) continue;
            if (!first) try insert.appendSlice(allocator, ", ");
            try insert.appendSlice(allocator, mod.name);
            first = false;
        }
        try insert.appendSlice(allocator, "], key: \"");
        try insert.appendSlice(allocator, name);
        try appendCosmicEntryTail(&insert, allocator, exe, index);
    }
    return cosmic_ron.rewrite(allocator, content, map, remove, insert.items, if (key_name != null) 1 else 0);
}

/// RON 문자열 escape. 읽는 쪽은 `cosmic_ron.string` 이다 — 두 규칙이 갈리면 따옴표 · 역슬래시가 든
/// 경로에서 자기 항목을 못 알아본다 (#484 의 기전).
fn appendRonString(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (value) |byte| {
        if (byte == '\\' or byte == '"') try output.append(allocator, '\\');
        try output.append(allocator, byte);
    }
}

// =============================================================================
// #510 — 전역 hotkey 소유권 판정 (read-before-write)
//
// Hyprland 와 COSMIC 은 등록이 **결과를 돌려주지 않는다.** `hyprctl` 은 중복 bind 에도
// exit 0 을 주고 (실측), COSMIC 은 RON 파일 쓰기라 되먹임이 아예 없다. 그래서 "등록이
// 실패했나" 를 물을 수 없고, 대신 **쓰기 전에 이미 잡혀 있는지 읽어서** 판정한다.
//
// KDE 와 sway 는 여기 없다. KDE 는 `claimKey` 가 사전 조회 · 사용자 확인 · 인수 · 사후
// 검증을 다 하고, sway 는 IPC 응답이 거절을 알려 준다 — 둘은 등록 자체가 답을 준다.
// =============================================================================

/// 남의 binding 설명을 담을 버퍼 크기. 명령 문자열이 길 수 있어 넉넉히 잡되, 다이얼로그
/// 본문 한 줄로 읽히는 선에서 끊는다.
pub const foreign_binding_desc_max = 240;

/// #510 — 이 accel 을 **우리 것이 아닌** Hyprland binding 이 이미 쓰고 있는가.
///
/// Hyprland 는 같은 조합에 binding 을 여러 개 두고 **전부 발화시킨다** (실측: 중복 bind
/// 뒤 `hyprctl -j binds` 에 두 항목이 남았다). 그래서 우리 토글과 남의 동작이 함께 돌고,
/// 사용자는 드롭다운을 부를 때마다 엉뚱한 일이 같이 벌어지는 것을 보게 된다.
///
/// 반환: 충돌하는 남의 binding 설명 (`out_buf` 에 담긴다). 없으면 `null`.
pub fn hyprlandForeignBinding(
    rt: Runtime,
    allocator: std.mem.Allocator,
    hotkey: config.Hotkey,
    out_buf: []u8,
) !?[]const u8 {
    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_len = try std.process.executablePath(rt.io, &exe_buf);
    const exe = exe_buf[0..exe_len];

    var want_buf: [96]u8 = undefined;
    const want = try hyprlandAccel(&want_buf, hotkey);

    const actual = try readHyprlandBindings(rt, allocator);
    defer actual.deinit();

    for (actual.value) |binding| {
        // submap 안의 binding 은 그 submap 에서만 산다 — 전역 충돌이 아니다.
        if (binding.submap.len != 0) continue;
        // 우리 것은 충돌이 아니다. launcher 가 worker 를 띄우기 **전에** 등록하므로
        // (`main.zig` 의 `shortcut_sync.sync` → `spawnWorker` 순서) 이 목록에는 방금
        // 넣은 우리 binding 이 반드시 들어 있다.
        if (std.mem.eql(u8, binding.dispatcher, "exec") and managedToggleCommand(binding.arg, exe)) continue;
        // #695 — Lua 로 건 우리 binding 은 `exec` 가 아니라 `__lua` 로 보여서, 표식
        // (`description`) 으로 거른다. 안 거르면 방금 건 우리 토글을 남의 것으로 안내한다.
        if (parseLuaDescription(binding.description, exe) != null) continue;

        var got_buf: [96]u8 = undefined;
        const got = foreignHyprlandAccel(&got_buf, binding) orelse continue;
        if (!std.ascii.eqlIgnoreCase(got, want)) continue;

        // Lua binding 의 `arg` 는 registry 번호라 읽는 사람에게 뜻이 없다. 설명이 있으면 그것을 보인다.
        if (std.mem.eql(u8, binding.dispatcher, "__lua")) {
            const what = if (binding.description.len != 0) binding.description else "Lua binding";
            return std.fmt.bufPrint(out_buf, "{s} → {s}", .{ want, what }) catch
                std.fmt.bufPrint(out_buf, "{s} → Lua binding", .{want}) catch null;
        }
        return std.fmt.bufPrint(out_buf, "{s} → {s} {s}", .{ want, binding.dispatcher, binding.arg }) catch
            std.fmt.bufPrint(out_buf, "{s} → {s}", .{ want, binding.dispatcher }) catch null;
    }
    return null;
}

/// `HyprlandBind` 를 `hyprlandAccel` 과 **같은 형식**의 문자열로 만든다. 우리 것만 보는
/// `managedHyprlandAccel` 과 달리 남의 binding 도 받아야 해서 명령 조건이 없다.
fn foreignHyprlandAccel(buf: []u8, binding: HyprlandBind) ?[]const u8 {
    // 우리가 표현할 수 없는 modifier 가 섞여 있으면 비교 대상이 아니다.
    if ((binding.modmask & ~hypr_supported_mods) != 0) return null;

    var fbs: std.Io.Writer = .fixed(buf);
    const writer = &fbs;
    if ((binding.modmask & hypr_mod_ctrl) != 0) writer.writeAll("CTRL ") catch return null;
    if ((binding.modmask & hypr_mod_shift) != 0) writer.writeAll("SHIFT ") catch return null;
    if ((binding.modmask & hypr_mod_alt) != 0) writer.writeAll("ALT ") catch return null;
    if ((binding.modmask & hypr_mod_super) != 0) writer.writeAll("SUPER ") catch return null;
    writer.writeByte(',') catch return null;
    // 위치로 등록된 binding 은 `key` 가 비고 `keycode` 에 xkb 번호가 온다 —
    // `hyprlandAccel` 이 쓰는 `code:NN` 과 같은 체계다.
    if (binding.keycode != 0) {
        writer.print("code:{d}", .{binding.keycode}) catch return null;
        return fbs.buffered();
    }
    if (binding.key.len == 0) return null;
    writer.writeAll(binding.key) catch return null;
    return fbs.buffered();
}

test "#616 시스템 기본과 겹치는 항목을 찾는다 (조합만 보고 description 은 무시)" {
    const a = std.testing.allocator;
    // 실제 `/usr/share/cosmic/…/v1/defaults` 의 형태 그대로.
    const defaults =
        \\{
        \\    (modifiers: [Super, Alt], key: "Escape"): Terminate,
        \\    (modifiers: [Super], key: "q"): Close,
        \\    (modifiers: [Alt], key: "F4"): Close,
        \\    (modifiers: [Super], key: "Left"): Focus(Left),
        \\}
    ;
    const want = cosmicAccelOf(config.Hotkey.fromString("super+q").?).?;
    const hit = findCosmicAccelEntry(a, defaults, want) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("(modifiers: [Super], key: \"q\"): Close", hit);

    // modifier 는 **집합**이라 순서가 달라도 같다.
    const want2 = cosmicAccelOf(config.Hotkey.fromString("alt+super+escape").?).?;
    try std.testing.expect(findCosmicAccelEntry(a, defaults, want2) != null);

    // 겹치지 않는 조합은 null — 같은 키라도 modifier 가 다르면 다른 항목이다.
    const want3 = cosmicAccelOf(config.Hotkey.fromString("ctrl+q").?).?;
    try std.testing.expect(findCosmicAccelEntry(a, defaults, want3) == null);
    const want4 = cosmicAccelOf(config.Hotkey.fromString("F1").?).?;
    try std.testing.expect(findCosmicAccelEntry(a, defaults, want4) == null);

    // #700 — 여러 줄 형식 (COSMIC 설정 화면이 쓰는 모양) 도 같은 항목으로 읽는다.
    const pretty =
        \\{
        \\    (
        \\        modifiers: [
        \\            Super,
        \\            Alt,
        \\        ],
        \\        key: "Escape",
        \\    ): Terminate,
        \\}
    ;
    try std.testing.expect(findCosmicAccelEntry(a, pretty, want2) != null);
    // 읽을 수 없는 파일은 판정하지 못한다 — 겹쳤다는 뜻이 아니다.
    try std.testing.expect(findCosmicAccelEntry(a, "{ (modifiers: [Super], key: \"q\"): Close", want) == null);
}

test "#700 a conflict description is shown on one line" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "( modifiers: [ Super, ], key: \"v\", ): Spawn(\"vicinae\")",
        compactInto(&buf, "(\n        modifiers: [\n            Super,\n        ],\n        key: \"v\",\n    ): Spawn(\"vicinae\")").?,
    );
}

pub fn cosmicSystemDefaultOverride(
    rt: Runtime,
    allocator: std.mem.Allocator,
    hotkey: config.Hotkey,
    out_buf: []u8,
) !?[]const u8 {
    const want = cosmicAccelOf(hotkey) orelse return null;

    // 기본값은 배포 데이터라 `XDG_DATA_DIRS` 를 따른다 (없으면 XDG 기본값).
    const dirs = rt.environ.getPosix("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var dir_it = std.mem.tokenizeScalar(u8, dirs, ':');
    while (dir_it.next()) |dir| {
        if (dir.len == 0 or dir[0] != '/') continue; // 상대 경로는 XDG 규범상 무시한다
        const path = std.Io.Dir.path.join(allocator, &.{
            dir, "cosmic", "com.system76.CosmicSettings.Shortcuts", "v1", "defaults",
        }) catch continue;
        defer allocator.free(path);

        const file = std.Io.Dir.openFileAbsolute(rt.io, path, .{}) catch continue;
        defer file.close(rt.io);
        var file_reader = file.reader(rt.io, &.{});
        const content = file_reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch continue;
        defer allocator.free(content);

        if (findCosmicAccelEntry(allocator, content, want)) |text| {
            return compactInto(out_buf, text) orelse std.fmt.bufPrint(out_buf, "{s}", .{want.key()}) catch null;
        }
    }
    return null;
}

/// RON 본문에서 `want` 와 같은 조합의 항목 글자를 찾는다. 파일 입출력과 갈라 두어 테스트가
/// 문자열만으로 돈다. 읽을 수 없는 파일이면 `null` — 못 봤다는 것과 겹쳤다는 것은 다르다.
fn findCosmicAccelEntry(allocator: std.mem.Allocator, content: []const u8, want: CosmicAccel) ?[]const u8 {
    const map = cosmic_ron.scan(allocator, content) catch return null;
    defer map.deinit(allocator);
    for (map.entries) |entry| {
        const got = cosmicEntryAccel(entry) orelse continue;
        if (got.modifiers != want.modifiers) continue;
        if (!std.mem.eql(u8, got.key(), want.key())) continue;
        return content[entry.start..entry.end];
    }
    return null;
}

/// #510 — 이 accel 을 **우리 것이 아닌** COSMIC 단축키가 이미 쓰고 있는가.
///
/// COSMIC 의 단축키 파일은 RON **map** 이고, 키 (`Binding`) 는 `modifiers + key` 로만 같은지 본다.
/// 같은 조합이 두 번 나오면 **뒤의 항목이 이기고** 앞의 것은 조용히 안 먹는다 (#700 조사 —
/// cosmic-settings-daemon `config/src/shortcuts/mod.rs:115-139` 가 `HashMap::insert` 로 읽는다).
/// 그래서 여기서의 충돌은 "둘 중 하나가 안 먹는다" 이고, 어느 쪽인지 사용자가 알 수 없다.
///
/// **사용자 `custom` 파일만 본다.** 시스템 기본값 (`/usr/share/cosmic/…/v1/defaults`) 과의
/// 겹침은 **충돌이 아니다 — 우리가 이긴다** (#616 · 2026-09-04 upstream 소스로 확정).
/// `cosmic-settings-daemon` 의 `shortcuts()` 가 `defaults` 를 읽고 `extend(custom)` 로 덮는다.
/// 그래서 그쪽은 막지 않고 `cosmicSystemDefaultOverride` 가 **로그로만** 알린다.
///
/// 반환: 충돌하는 남의 항목 설명 (`out_buf` 에 한 줄로 담긴다). 없으면 `null`. 파일을 읽을 수
/// 없으면 오류다 — 호출부가 "판정을 건너뜀" 으로 남긴다.
pub fn cosmicForeignBinding(
    rt: Runtime,
    allocator: std.mem.Allocator,
    hotkey: config.Hotkey,
    out_buf: []u8,
) !?[]const u8 {
    const want = cosmicAccelOf(hotkey) orelse return null;

    const dir_path = try cosmicShortcutsDir(rt, allocator);
    defer allocator.free(dir_path);
    const path = try std.Io.Dir.path.join(allocator, &.{ dir_path, "custom" });
    defer allocator.free(path);

    var existed = false;
    const content = try readCosmicCustom(rt, allocator, path, &existed);
    defer allocator.free(content);
    // 파일이 없으면 사용자 단축키가 하나도 없다 — 충돌할 것이 없다.
    if (!existed) return null;

    const map = try cosmic_ron.scan(allocator, content);
    defer map.deinit(allocator);
    for (map.entries) |entry| {
        // 우리 항목은 충돌이 아니다 — 표식이 붙은 항목과, 옛 install.sh 가 쓴 표식 없는 항목.
        if (tildazCosmicEntryIndex(entry) != null) continue;
        if (legacyInstallScriptEntryIndex(entry) != null) continue;

        const got = cosmicEntryAccel(entry) orelse continue;
        if (got.modifiers != want.modifiers) continue;
        if (!std.mem.eql(u8, got.key(), want.key())) continue;

        return compactInto(out_buf, content[entry.start..entry.end]) orelse
            std.fmt.bufPrint(out_buf, "{s}", .{got.key()}) catch null;
    }
    return null;
}

/// 여러 줄 항목을 다이얼로그 · 로그 한 줄로 보인다 — 공백이 이어지면 하나로 줄인다.
fn compactInto(out_buf: []u8, text: []const u8) ?[]const u8 {
    var len: usize = 0;
    var in_space = false;
    for (std.mem.trim(u8, text, " \t\r\n")) |c| {
        const space = c == ' ' or c == '\t' or c == '\r' or c == '\n';
        if (space and in_space) continue;
        if (len >= out_buf.len) return null;
        out_buf[len] = if (space) ' ' else c;
        len += 1;
        in_space = space;
    }
    return out_buf[0..len];
}

/// COSMIC 단축키 항목에서 뽑아낸 비교용 accel. modifier 는 **집합**으로 본다 — 파일에
/// 적힌 순서에 기대면 사용자가 손으로 쓴 항목에서 어긋난다.
const CosmicAccel = struct {
    modifiers: u32,
    key_buf: [64]u8,
    key_len: usize,

    fn key(self: *const CosmicAccel) []const u8 {
        return self.key_buf[0..self.key_len];
    }
};

/// 우리 hotkey 를 `CosmicAccel` 로. 위치 표기는 `null` 이다 — COSMIC 은 자리를 못 받고
/// 워커가 *현재 layout 이 내는 글자*로 바꿔 쓰므로 (`writeCosmicPositionHotkey`), 그
/// 변환 결과로 비교해야 한다. 그 경로는 별도로 다룬다.
fn cosmicAccelOf(hotkey: config.Hotkey) ?CosmicAccel {
    if (hotkey.code != null) return null;
    const name = config.linuxKeysymName(hotkey.keysym) orelse return null;
    if (name.len > 64) return null;
    var out: CosmicAccel = .{ .modifiers = hotkey.modifiers, .key_buf = undefined, .key_len = name.len };
    @memcpy(out.key_buf[0..name.len], name);
    return out;
}

/// 항목의 키 (`(modifiers: [Super, Shift], key: "Escape")`) 를 읽는다. #700 — 줄 모양과 무관하다
/// (COSMIC 설정 화면은 modifier 를 한 줄씩, 뒤에 쉼표를 붙여 쓴다).
fn cosmicEntryAccel(entry: cosmic_ron.Entry) ?CosmicAccel {
    const mods_raw = cosmic_ron.field(entry.key, "modifiers") orelse return null;
    if (mods_raw.len < 2 or mods_raw[0] != '[' or mods_raw[mods_raw.len - 1] != ']') return null;

    var modifiers: u32 = 0;
    var it = std.mem.tokenizeAny(u8, mods_raw[1 .. mods_raw.len - 1], ", \t\r\n");
    while (it.next()) |token| {
        if (std.ascii.eqlIgnoreCase(token, "Super")) {
            modifiers |= config.Hotkey.MOD_SUPER;
        } else if (std.ascii.eqlIgnoreCase(token, "Ctrl")) {
            modifiers |= config.Hotkey.MOD_CTRL;
        } else if (std.ascii.eqlIgnoreCase(token, "Alt")) {
            modifiers |= config.Hotkey.MOD_ALT;
        } else if (std.ascii.eqlIgnoreCase(token, "Shift")) {
            modifiers |= config.Hotkey.MOD_SHIFT;
        } else {
            // 우리가 표현할 수 없는 modifier — 비교 대상이 아니다.
            return null;
        }
    }

    var out: CosmicAccel = .{ .modifiers = modifiers, .key_buf = undefined, .key_len = 0 };
    const key_raw = cosmic_ron.field(entry.key, "key") orelse return null;
    const name = cosmic_ron.string(key_raw, &out.key_buf) orelse return null;
    if (name.len == 0) return null;
    out.key_len = name.len;
    return out;
}
