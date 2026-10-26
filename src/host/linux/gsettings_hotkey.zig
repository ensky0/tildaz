//! #676 — GNOME · Cinnamon Shell extension 준비와 활성 상태 판정.
//!
//! 두 desktop은 layer-shell을 지원하지 않아 extension이 창 배치·always-on-top·창
//! 목록 숨김·hotkey를 한 묶음으로 맡는다. 예전 GSettings custom-keybinding fallback은
//! hotkey만 살리고 일반 xdg-shell 창을 남겼다. 그것은 drop-down terminal 동작이
//! 아니므로 삭제했다. 이 모듈은 이제 extension 리소스를 동기화하고, 처음 준비한
//! extension만 활성화하며, 이전 버전이 남긴 fallback 항목을 정리한다.
//!
//! 구현은 GSettings (`libgio-2.0`) 를 runtime dlopen — `gsettings` CLI subprocess 가
//! 아니라 라이브러리 직접 (dbus / fontconfig / freetype / xkb / harfbuzz 와 같은
//! dlopen 패턴 일관). dconf 직접 D-Bus 쓰기는 gvdb 직렬화가 필요해 회피.
//!
//! ⚠️ `g_settings_new` 은 schema 미설치 시 `g_error` → abort (프로세스 죽음). 반드시
//! `g_settings_schema_source_lookup` 으로 schema 존재를 먼저 확인한 뒤 연다.

const std = @import("std");
const Runtime = @import("../../runtime.zig").Runtime;
const log = @import("../../log.zig");
const app_id = @import("../../app_id.zig");
const shell_extension = @import("shell_extension.zig");
const paths = @import("../../paths.zig");
const instances = @import("../../instances.zig");

const c = struct {
    const GSettings = opaque {};
    const GSettingsSchema = opaque {};
    const GSettingsSchemaSource = opaque {};
};

// --- GNOME (gnome-settings-daemon media-keys) ---
const gnome_list_schema = "org.gnome.settings-daemon.plugins.media-keys";
const gnome_list_key = "custom-keybindings";
// dconf 의 custom-keybinding 은 데스크톱 하나가 공유하는 자리라 **이름으로 가른다**
// (#654). 안 가르면 개발 빌드와 릴리즈가 같은 항목을 써서 서로의 단축키를 덮어쓰고,
// 아래 `gsettingsTildazIndex` 의 정리 경로가 **남의 것을 지운다**.

// --- Cinnamon (cinnamon-settings-daemon keybindings) ---
const cinnamon_list_schema = "org.cinnamon.desktop.keybindings";
const cinnamon_list_key = "custom-list";

const LegacyListTarget = struct {
    schema: [*:0]const u8,
    key: [*:0]const u8,
};

const schema_gnome_shell = "org.gnome.shell";
const schema_cinnamon_shell = "org.cinnamon";
const key_enabled_extensions = "enabled-extensions"; // GNOME · Cinnamon 동일 key 이름.
const key_disabled_extensions = "disabled-extensions";
const key_disable_user_extensions = "disable-user-extensions";
/// `app_id.extension_uuid` 하나가 정한다 (#654) — 개발 빌드와 릴리즈가 같은 UUID 를
/// 쓰면 서로의 확장을 자기 것으로 보고, `uninstall.sh` 가 남의 확장을 지운다.
const extension_uuid = app_id.extension_uuid;

/// 일반 xdg-shell TildaZ 창의 placement/show/hide lifecycle을 맡는 Shell extension.
/// GNOME과 Cinnamon이 같은 소유권 계약을 공유하도록 startup 판정의 단일 결과로 쓴다.
pub const ShellExtensionOwner = enum {
    gnome,
    cinnamon,

    pub fn displayName(self: ShellExtensionOwner) []const u8 {
        return switch (self) {
            .gnome => "GNOME",
            .cinnamon => "Cinnamon",
        };
    }

    fn logCategory(self: ShellExtensionOwner) []const u8 {
        return switch (self) {
            .gnome => "gnome",
            .cinnamon => "cinnamon",
        };
    }
};

const ShellExtensionTarget = struct {
    owner: ShellExtensionOwner,
    kind: shell_extension.Kind,
    schema: [*:0]const u8,
};

pub const Status = union(enum) {
    not_applicable,
    active: ShellExtensionOwner,
    inactive: ShellExtensionOwner,
};

/// `XDG_CURRENT_DESKTOP`의 콜론 구분 토큰을 exact/case-insensitive로 판정한다.
/// GNOME을 먼저 보는 기존 우선순위를 보존한다.
fn shellExtensionTargetForDesktopValue(value: []const u8) ?ShellExtensionTarget {
    if (desktopValueHasToken(value, &.{"GNOME"})) {
        return .{ .owner = .gnome, .kind = .gnome, .schema = schema_gnome_shell };
    }
    if (desktopValueHasToken(value, &.{ "X-Cinnamon", "Cinnamon" })) {
        return .{ .owner = .cinnamon, .kind = .cinnamon, .schema = schema_cinnamon_shell };
    }
    return null;
}

fn currentShellExtensionTarget(rt: Runtime) ?ShellExtensionTarget {
    // #451 — `std.posix.getenv` 제거. `Environ.getPosix` 는 POSIX 블록을 그대로 훑어
    // 할당이 없다 (릴리즈 노트 *Environment Variables … Become Non-Global*).
    const desktop = rt.environ.getPosix("XDG_CURRENT_DESKTOP") orelse return null;
    return shellExtensionTargetForDesktopValue(desktop);
}

/// 리소스를 현재 사용자 디렉터리에 맞춘 뒤 실제 설정상 활성 여부를 돌려준다.
///
/// #676 — 처음 준비한 디렉터리만 enabled 목록에 넣는다. 이미 설치된 UUID가 목록에서
/// 빠졌거나 GNOME의 disabled 목록에 있으면 사용자가 끈 상태이므로 되살리지 않는다.
/// GNOME의 전체 확장 비활성 설정도 바꾸지 않는다.
pub fn prepareShellExtension(rt: Runtime, allocator: std.mem.Allocator) Status {
    const target = currentShellExtensionTarget(rt) orelse return .not_applicable;
    const label = target.owner.logCategory();

    const newly_installed = shell_extension.syncForCurrentUser(rt, allocator, target.kind) catch |err| {
        log.appendLine(label, "Shell extension resource sync failed: {s}", .{@errorName(err)});
        return .{ .inactive = target.owner };
    };
    const api = Api.load() orelse return .{ .inactive = target.owner };
    const source = api.schema_source_get_default() orelse return .{ .inactive = target.owner };
    const schema = api.schema_source_lookup(source, target.schema, 1) orelse
        return .{ .inactive = target.owner };
    api.schema_unref(schema);
    const settings = api.settings_new(target.schema) orelse return .{ .inactive = target.owner };
    defer api.object_unref(settings);
    var enabled = listContains(&api, settings, key_enabled_extensions, extension_uuid);
    const explicitly_disabled = target.owner == .gnome and
        listContains(&api, settings, key_disabled_extensions, extension_uuid);
    const legacy = legacyState(rt, allocator, &api, settings, target);

    if (shouldEnableFirstUse(newly_installed, enabled, explicitly_disabled, legacy)) {
        ensureInList(allocator, &api, settings, key_enabled_extensions, extension_uuid) catch |err| {
            log.appendLine(label, "Shell extension first-time enable failed: {s}", .{@errorName(err)});
            return .{ .inactive = target.owner };
        };
        api.settings_sync();
        enabled = true;
        log.appendLine(label, "Shell extension synchronized and enabled for first use", .{});
    } else {
        log.appendLine(label, "Shell extension synchronized; existing enabled state preserved", .{});
    }
    if (legacy != .absent) removeLegacyExtension(rt, allocator, &api, settings, target, legacy);

    const all_user_extensions_disabled = target.owner == .gnome and
        api.settings_get_boolean(settings, key_disable_user_extensions) != 0;
    if (!extensionActive(target.owner, enabled, explicitly_disabled, all_user_extensions_disabled))
        return .{ .inactive = target.owner };
    return .{ .active = target.owner };
}

/// #830 — 옛 UUID (`app_id.legacy_extension_uuid`) 가 남긴 것. 사용자가 옛 확장을 켜 두었는지
/// 꺼 두었는지를 새 UUID 로 옮기려고 가른다.
const Legacy = enum {
    /// 옛 폴더도 목록의 자리도 없다.
    absent,
    /// 켜진 목록에 있었다 (GNOME 은 꺼진 목록에 없는 것까지).
    enabled,
    /// 폴더나 목록의 자리는 있는데 켜져 있지 않았다 — 사용자가 끈 것으로 본다 (#676).
    disabled,
};

fn legacyState(rt: Runtime, allocator: std.mem.Allocator, api: *const Api, settings: *c.GSettings, target: ShellExtensionTarget) Legacy {
    const in_enabled = listContains(api, settings, key_enabled_extensions, app_id.legacy_extension_uuid);
    const in_disabled = target.owner == .gnome and
        listContains(api, settings, key_disabled_extensions, app_id.legacy_extension_uuid);
    const installed = shell_extension.legacyInstalled(rt, allocator, target.kind) catch false;
    return classifyLegacy(installed, in_enabled, in_disabled);
}

fn classifyLegacy(installed: bool, in_enabled: bool, in_disabled: bool) Legacy {
    if (in_enabled and !in_disabled) return .enabled;
    if (installed or in_enabled or in_disabled) return .disabled;
    return .absent;
}

/// #830 — 옛 UUID 를 켜진 · 꺼진 목록에서 빼고 옛 폴더를 지운다. 남겨 두면 다시 로그인했을 때
/// 옛 확장과 새 확장이 같은 창 · 같은 단축키를 함께 잡는다. GNOME 은 목록이 바뀌는 순간 옛 확장을
/// 내리고, 새 UUID 는 다시 로그인해야 읽는다. 실패해도 기동은 막지 않는다 — 다음 실행에 다시 한다.
fn removeLegacyExtension(rt: Runtime, allocator: std.mem.Allocator, api: *const Api, settings: *c.GSettings, target: ShellExtensionTarget, legacy: Legacy) void {
    const label = target.owner.logCategory();
    removeFromList(allocator, api, settings, key_enabled_extensions, app_id.legacy_extension_uuid) catch |err| {
        log.appendLine(label, "legacy Shell extension list cleanup failed: {s}", .{@errorName(err)});
        return;
    };
    if (target.owner == .gnome) {
        removeFromList(allocator, api, settings, key_disabled_extensions, app_id.legacy_extension_uuid) catch |err| {
            log.appendLine(label, "legacy Shell extension list cleanup failed: {s}", .{@errorName(err)});
            return;
        };
    }
    api.settings_sync();
    shell_extension.removeLegacy(rt, allocator, target.kind) catch |err| {
        log.appendLine(label, "legacy Shell extension directory removal failed: {s}", .{@errorName(err)});
        return;
    };
    // GNOME 은 새 UUID 를 다시 로그인해야 읽는다. Cinnamon 은 목록이 바뀌면 바로 읽는다 (AGENTS.md 실측).
    const next_step = switch (target.owner) {
        .gnome => "log out and back in to load ",
        .cinnamon => "replaced by ",
    };
    log.appendLine(label, "legacy Shell extension {s} removed (was {s}); {s}{s}", .{
        app_id.legacy_extension_uuid, @tagName(legacy), next_step, extension_uuid,
    });
}

fn shouldEnableFirstUse(newly_installed: bool, enabled: bool, explicitly_disabled: bool, legacy: Legacy) bool {
    if (enabled or explicitly_disabled) return false;
    return switch (legacy) {
        .absent => newly_installed,
        // #830 — 사용자가 옛 확장을 켜 두었으면 새 UUID 도 켜고, 꺼 두었으면 켜지 않는다.
        .enabled => true,
        .disabled => false,
    };
}

fn extensionActive(
    owner: ShellExtensionOwner,
    enabled: bool,
    explicitly_disabled: bool,
    all_user_extensions_disabled: bool,
) bool {
    if (!enabled) return false;
    return switch (owner) {
        .gnome => !explicitly_disabled and !all_user_extensions_disabled,
        .cinnamon => true,
    };
}

const Api = struct {
    schema_source_get_default: *const fn () callconv(.c) ?*c.GSettingsSchemaSource,
    schema_source_lookup: *const fn (?*c.GSettingsSchemaSource, [*:0]const u8, c_int) callconv(.c) ?*c.GSettingsSchema,
    schema_unref: *const fn (?*c.GSettingsSchema) callconv(.c) void,
    settings_new: *const fn ([*:0]const u8) callconv(.c) ?*c.GSettings,
    settings_get_strv: *const fn (?*c.GSettings, [*:0]const u8) callconv(.c) ?[*:null]?[*:0]u8,
    settings_get_boolean: *const fn (?*c.GSettings, [*:0]const u8) callconv(.c) c_int,
    settings_set_strv: *const fn (?*c.GSettings, [*:0]const u8, [*]const ?[*:0]const u8) callconv(.c) c_int,
    settings_sync: *const fn () callconv(.c) void,
    strfreev: *const fn (?[*:null]?[*:0]u8) callconv(.c) void,
    object_unref: *const fn (?*anyopaque) callconv(.c) void,

    fn load() ?Api {
        const handle = std.c.dlopen("libgio-2.0.so.0", .{ .LAZY = true }) orelse return null;
        return Api{
            .schema_source_get_default = lookup(handle, @TypeOf(@as(Api, undefined).schema_source_get_default), "g_settings_schema_source_get_default") orelse return null,
            .schema_source_lookup = lookup(handle, @TypeOf(@as(Api, undefined).schema_source_lookup), "g_settings_schema_source_lookup") orelse return null,
            .schema_unref = lookup(handle, @TypeOf(@as(Api, undefined).schema_unref), "g_settings_schema_unref") orelse return null,
            .settings_new = lookup(handle, @TypeOf(@as(Api, undefined).settings_new), "g_settings_new") orelse return null,
            .settings_get_strv = lookup(handle, @TypeOf(@as(Api, undefined).settings_get_strv), "g_settings_get_strv") orelse return null,
            .settings_get_boolean = lookup(handle, @TypeOf(@as(Api, undefined).settings_get_boolean), "g_settings_get_boolean") orelse return null,
            .settings_set_strv = lookup(handle, @TypeOf(@as(Api, undefined).settings_set_strv), "g_settings_set_strv") orelse return null,
            .settings_sync = lookup(handle, @TypeOf(@as(Api, undefined).settings_sync), "g_settings_sync") orelse return null,
            .strfreev = lookup(handle, @TypeOf(@as(Api, undefined).strfreev), "g_strfreev") orelse return null,
            .object_unref = lookup(handle, @TypeOf(@as(Api, undefined).object_unref), "g_object_unref") orelse return null,
        };
    }

    fn lookup(handle: *anyopaque, comptime T: type, name: [*:0]const u8) ?T {
        const sym = std.c.dlsym(handle, name) orelse return null;
        return @ptrCast(@alignCast(sym));
    }
};

/// #676 — 이전 버전이 만든 fallback 항목을 모두 거둔다. 다른 앱의 항목과 다른 판
/// (dev/release)의 이름은 `gsettingsTildazIndex`가 걸러 보존한다.
pub fn removeLegacyFallbackEntries(rt: Runtime, allocator: std.mem.Allocator) void {
    const target = currentShellExtensionTarget(rt) orelse return;
    const de = target.owner;
    const api = Api.load() orelse return;
    const source = api.schema_source_get_default() orelse return;
    const list_target: LegacyListTarget = switch (de) {
        .gnome => .{ .schema = gnome_list_schema, .key = gnome_list_key },
        .cinnamon => .{ .schema = cinnamon_list_schema, .key = cinnamon_list_key },
    };
    const schema = api.schema_source_lookup(source, list_target.schema, 1) orelse return;
    api.schema_unref(schema);

    const list = api.settings_new(list_target.schema) orelse return;
    defer api.object_unref(list);
    const existing = api.settings_get_strv(list, list_target.key);
    defer api.strfreev(existing);
    if (existing == null) return;

    var next: std.ArrayList(?[*:0]const u8) = .empty;
    defer next.deinit(allocator);
    var changed = false;
    var i: usize = 0;
    while (existing.?[i]) |entry| : (i += 1) {
        const text = std.mem.span(entry);
        if (gsettingsTildazIndex(text, de == .gnome) != null) {
            changed = true;
            continue;
        }
        next.append(allocator, entry) catch return;
    }
    if (!changed) {
        log.appendLine("gsettings-hotkey", "legacy fallback entries already absent", .{});
        return;
    }
    next.append(allocator, null) catch return;
    if (api.settings_set_strv(list, list_target.key, next.items.ptr) == 0) {
        log.appendLine("gsettings-hotkey", "legacy fallback entry removal failed", .{});
        return;
    }
    api.settings_sync();
    log.appendLine("gsettings-hotkey", "removed legacy fallback entries", .{});
}

/// **`app_id.name` 을 탄다** (#654) — 호출처가 이 판정에 걸린 항목을 활성 목록에서
/// 빼므로, 안 갈리면 개발 빌드가 릴리즈의 `tildaz-N` 단축키를 지운다 (위
/// `kglobalaccel.numberedComponentIndex` 와 같은 모양의 함정이다).
fn gsettingsTildazIndex(value: []const u8, gnome: bool) ?u32 {
    const prefix = if (gnome)
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/" ++ app_id.name ++ "-"
    else
        app_id.name ++ "-";
    const suffix = if (gnome) "/" else "";
    if (!std.mem.startsWith(u8, value, prefix) or !std.mem.endsWith(u8, value, suffix)) return null;
    const end = value.len - suffix.len;
    const digits = value[prefix.len..end];
    if (digits.len == 0 or (digits.len > 1 and digits[0] == '0')) return null;
    return std.fmt.parseInt(u32, digits, 10) catch null;
}

test "GSettings numbered TildaZ entries are identified without user entries" {
    try std.testing.expectEqual(@as(?u32, 2), gsettingsTildazIndex(
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/" ++ app_id.name ++ "-2/",
        true,
    ));
    try std.testing.expectEqual(@as(?u32, 3), gsettingsTildazIndex(app_id.name ++ "-3", false));
    try std.testing.expectEqual(@as(?u32, null), gsettingsTildazIndex("custom0", false));
    try std.testing.expectEqual(@as(?u32, null), gsettingsTildazIndex(app_id.name ++ "-03", false));
    // #654 — 개발 빌드가 **릴리즈의** 항목을 자기 것으로 보면 그것을 지운다.
    if (comptime !std.mem.eql(u8, app_id.name, "tildaz")) {
        try std.testing.expectEqual(@as(?u32, null), gsettingsTildazIndex("tildaz-3", false));
    }
}

/// 리스트 strv (`key`) 에 `value` 가 없으면 추가. 있으면 no-op (idempotent).
/// 기존 항목 (`__dummy__` 등) 은 보존한다.
fn ensureInList(allocator: std.mem.Allocator, api: *const Api, settings: *c.GSettings, key: [*:0]const u8, value: [*:0]const u8) !void {
    const existing = api.settings_get_strv(settings, key);
    defer api.strfreev(existing);

    var list: std.ArrayList(?[*:0]const u8) = .empty;
    defer list.deinit(allocator);

    const want = std.mem.span(value);
    if (existing) |e| {
        var i: usize = 0;
        while (e[i]) |s| : (i += 1) {
            if (std.mem.eql(u8, std.mem.span(s), want)) return; // 이미 등록됨.
            try list.append(allocator, s);
        }
    }
    try list.append(allocator, value);
    try list.append(allocator, null); // NULL-terminate (g_settings_set_strv 요구).
    if (api.settings_set_strv(settings, key, list.items.ptr) == 0)
        return error.GSettingsWriteFailed;
}

/// 리스트 strv (`key`) 에서 `value` 를 뺀다. 없으면 쓰지 않는다 (idempotent). 나머지 항목과
/// 순서는 그대로 둔다.
fn removeFromList(allocator: std.mem.Allocator, api: *const Api, settings: *c.GSettings, key: [*:0]const u8, value: [*:0]const u8) !void {
    const existing = api.settings_get_strv(settings, key);
    defer api.strfreev(existing);
    const entries = existing orelse return;

    var list: std.ArrayList(?[*:0]const u8) = .empty;
    defer list.deinit(allocator);

    const unwanted = std.mem.span(value);
    var found = false;
    var i: usize = 0;
    while (entries[i]) |s| : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(s), unwanted)) {
            found = true;
            continue;
        }
        try list.append(allocator, s);
    }
    if (!found) return;
    try list.append(allocator, null); // NULL-terminate (g_settings_set_strv 요구).
    if (api.settings_set_strv(settings, key, list.items.ptr) == 0)
        return error.GSettingsWriteFailed;
}

fn listContains(api: *const Api, settings: *c.GSettings, key: [*:0]const u8, value: [*:0]const u8) bool {
    const existing = api.settings_get_strv(settings, key);
    defer api.strfreev(existing);
    const entries = existing orelse return false;
    const want = std.mem.span(value);
    var i: usize = 0;
    while (entries[i]) |entry| : (i += 1)
        if (std.mem.eql(u8, std.mem.span(entry), want)) return true;
    return false;
}

fn desktopValueHasToken(value: []const u8, wanted: []const []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, value, ':');
    while (it.next()) |tok| {
        for (wanted) |w| {
            if (std.ascii.eqlIgnoreCase(tok, w)) return true;
        }
    }
    return false;
}

test "Shell extension target follows exact GNOME and Cinnamon desktop tokens" {
    const T = std.testing;

    const gnome = shellExtensionTargetForDesktopValue("ubuntu:GNOME").?;
    try T.expectEqual(ShellExtensionOwner.gnome, gnome.owner);
    try T.expectEqual(shell_extension.Kind.gnome, gnome.kind);
    try T.expectEqualStrings(schema_gnome_shell, std.mem.span(gnome.schema));

    const cinnamon = shellExtensionTargetForDesktopValue("X-Cinnamon").?;
    try T.expectEqual(ShellExtensionOwner.cinnamon, cinnamon.owner);
    try T.expectEqual(shell_extension.Kind.cinnamon, cinnamon.kind);
    try T.expectEqualStrings(schema_cinnamon_shell, std.mem.span(cinnamon.schema));

    try T.expectEqual(ShellExtensionOwner.cinnamon, shellExtensionTargetForDesktopValue("cinnamon").?.owner);
    try T.expectEqual(ShellExtensionOwner.gnome, shellExtensionTargetForDesktopValue("GNOME:X-Cinnamon").?.owner);
    try T.expect(shellExtensionTargetForDesktopValue("") == null);
    try T.expect(shellExtensionTargetForDesktopValue("KDE") == null);
    try T.expect(shellExtensionTargetForDesktopValue("KDESomething") == null);
    try T.expect(shellExtensionTargetForDesktopValue("GNOME-Classic") == null);
}

test "#676 Shell extension state respects explicit and global disable" {
    const T = std.testing;
    try T.expect(extensionActive(.gnome, true, false, false));
    try T.expect(!extensionActive(.gnome, false, false, false));
    try T.expect(!extensionActive(.gnome, true, true, false));
    try T.expect(!extensionActive(.gnome, true, false, true));
    try T.expect(extensionActive(.cinnamon, true, false, false));
    try T.expect(!extensionActive(.cinnamon, false, false, false));

    try T.expect(shouldEnableFirstUse(true, false, false, .absent));
    try T.expect(!shouldEnableFirstUse(false, false, false, .absent));
    try T.expect(!shouldEnableFirstUse(true, false, true, .absent));
    try T.expect(!shouldEnableFirstUse(true, true, false, .absent));
}

test "#830 legacy extension UUID carries the user's choice to the new UUID" {
    const T = std.testing;
    try T.expectEqual(Legacy.absent, classifyLegacy(false, false, false));
    try T.expectEqual(Legacy.enabled, classifyLegacy(true, true, false));
    // 폴더 없이 목록의 자리만 남은 경우도 켜 둔 것이다 (폴더를 손으로 지운 경우).
    try T.expectEqual(Legacy.enabled, classifyLegacy(false, true, false));
    // GNOME 은 꺼진 목록이 켜진 목록보다 우선이다.
    try T.expectEqual(Legacy.disabled, classifyLegacy(true, true, true));
    try T.expectEqual(Legacy.disabled, classifyLegacy(true, false, false));
    try T.expectEqual(Legacy.disabled, classifyLegacy(false, false, true));

    // 옛 확장을 켜 두었으면 새 폴더가 이미 있어도 (지난 실행이 중간에 멈춘 경우) 켠다.
    try T.expect(shouldEnableFirstUse(true, false, false, .enabled));
    try T.expect(shouldEnableFirstUse(false, false, false, .enabled));
    // 꺼 두었으면 처음 깔린 새 UUID 도 켜지 않는다 (#676).
    try T.expect(!shouldEnableFirstUse(true, false, false, .disabled));
    // 새 UUID 를 사용자가 GNOME 에서 끈 것은 옛 상태보다 우선한다.
    try T.expect(!shouldEnableFirstUse(true, false, true, .enabled));
}

test "#830 legacy UUID is the same build kind with the old namespace" {
    const T = std.testing;
    try T.expect(std.mem.endsWith(u8, app_id.extension_uuid, "@tildaz.dev"));
    try T.expect(std.mem.endsWith(u8, app_id.legacy_extension_uuid, "@ensky0.github.io"));
    const new_name = app_id.extension_uuid[0..std.mem.indexOfScalar(u8, app_id.extension_uuid, '@').?];
    const old_name = app_id.legacy_extension_uuid[0..std.mem.indexOfScalar(u8, app_id.legacy_extension_uuid, '@').?];
    try T.expectEqualStrings(new_name, old_name);
}

// =============================================================================
// #510 — Shell extension 의 grab 결과 읽기
// =============================================================================

/// extension 이 남기는 상태 줄의 형식 판별자. 형식을 바꾸면 이 값을 올리고, 모르는
/// 판별자는 **무시**한다 (옛 extension 이 남긴 줄을 오해하지 않게).
const hotkey_state_version = "v1";

pub const HotkeyState = enum { unavailable, ok, failed };

/// GNOME · Cinnamon Shell extension이 현재 config의 hotkey를 실제로 처리한 결과.
///
/// extension 은 `grab_accelerator` (GNOME) / `addHotKey` (Cinnamon) 의 실패를 알지만
/// 지금까지 셸 journal 에만 적었다. 그 결과를
/// `paths.instanceHotkeyStatePath` 에 `v1 <ok|failed> <hotkey 문자열>` 한 줄로 남기게
/// 하고, worker 가 부팅 때 이 함수로 읽는다. 왜 파일이어야 하는지는 그 경로의 주석에
/// 있다 (grab 실패가 worker 탄생보다 앞선다).
///
/// **stale 파일이 멀쩡한 환경을 죽이지 않게** 두 겹으로 막는다.
///   1. extension 이 성공하면 `ok` 로 덮어쓰고, `disable()` 에서 지운다.
///   2. 줄에 적힌 hotkey 문자열이 **지금 config 의 값과 다르면 무시한다.** 사용자가
///      키를 고쳐 다시 띄운 경우가 여기 걸린다 — 그때 파일이 아직 옛 값이면 그것은
///      지난 실행의 기록이다.
///
/// #676 이후 `unavailable`은 조용히 일반 창으로 내려가는 조건이 아니라 extension이
/// 실제로 동작하지 않는다는 기동 실패다. 설정 목록의 active와 이 결과가 둘 다 있어야
/// Shell extension을 창 lifecycle owner로 인정한다.
pub fn shellExtensionHotkeyState(rt: Runtime, allocator: std.mem.Allocator, index: u32) HotkeyState {
    const content = readHotkeyState(rt, allocator, index) orelse return .unavailable;
    defer allocator.free(content);

    const line = std.mem.trim(u8, content[0 .. std.mem.findScalar(u8, content, '\n') orelse content.len], " \t\r");
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const version = it.next() orelse return .unavailable;
    if (!std.mem.eql(u8, version, hotkey_state_version)) return .unavailable;
    const state = it.next() orelse return .unavailable;

    // hotkey 문자열은 **줄 끝까지**다 — 사용자가 `ctrl + space` 처럼 공백을 넣어 적을 수
    // 있어서 토큰 하나로 자르면 안 된다.
    const recorded = std.mem.trim(u8, it.rest(), " \t");
    if (recorded.len == 0) return .unavailable;

    const current = instances.configHotkeyText(rt, allocator, index) catch return .unavailable;
    defer allocator.free(current);
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, current, " \t\r\n"), recorded)) {
        log.appendLine("hotkey", "shell extension state is stale (recorded={s}) — ignored", .{recorded});
        return .unavailable;
    }

    if (std.mem.eql(u8, state, "ok")) return .ok;
    if (std.mem.eql(u8, state, "failed")) {
        log.appendLine("hotkey", "shell extension reported a failed grab for {s}", .{recorded});
        return .failed;
    }
    return .unavailable;
}

/// #758 — 이 worker 가 config 내용을 **무시하고 기본값으로 시작했는지**를 확장에게 남긴다.
///
/// GNOME · Cinnamon 확장은 config 를 자기 파서로 직접 읽어 hotkey 를 잡고 창을 놓는다. 로그인
/// 때는 앱이 아직 없어서 확장이 먼저 읽어야 하기 때문이다. 그 파서는 줄 단위라, 문법이 깨진
/// 파일에서도 읽히는 줄 (`hotkey = "F5"`) 은 읽는다. 반면 앱은 그 파일을 통째로 기본값으로 읽는다
/// (`Config.load`). 그대로 두면 확장은 F5 를 잡고 앱은 F1 을 기대해, 위 `shellExtensionHotkeyState`
/// 가 기록을 stale 로 보고 "확장이 필요하다" 로 시작을 멈춘다 (#676). 창 배치도 파일 값을 쓴다.
///
/// 깨졌는지 판정은 **앱 한 곳에서만** 한다. 확장이 같은 판정을 하려면 TOML 전체를 검사해야
/// 하고, 그러면 두 판정이 언젠가 어긋난다. 그래서 앱이 그 파일 내용의 SHA-256 을 남기고, 확장은
/// 해시가 지금 파일과 같으면 그 번호를 통째로 기본값으로 읽은 뒤 hotkey 를 다시 잡는다. 사용자가
/// 파일을 고치면 해시가 달라져 확장은 평소대로 읽는다. 정상 파일을 읽은 worker 는 표시를 지운다.
///
/// 순서 — 이 표시는 hotkey 상태를 기다리기 (`waitForShellExtensionHotkeyState`) **전에** 써야
/// 한다. 확장이 표시를 보고 기본 키로 다시 잡아 기록을 고칠 시간이 그 기다림 안에 든다.
pub fn recordIgnoredConfig(rt: Runtime, allocator: std.mem.Allocator, index: u32, sha256: ?[32]u8) void {
    const path = paths.instanceIgnoredConfigPath(rt, allocator, index) catch |err| {
        log.appendLine("config", "ignored-config marker path unavailable: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(path);
    const digest = sha256 orelse {
        std.Io.Dir.deleteFileAbsolute(rt.io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => log.appendLine("config", "could not remove the ignored-config marker: {s}", .{@errorName(err)}),
        };
        return;
    };
    const line = ignoredConfigLine(digest);
    _ = paths.writeFileIfChanged(rt, allocator, path, &line) catch |err| {
        log.appendLine("config", "could not write the ignored-config marker: {s}", .{@errorName(err)});
        return;
    };
    log.appendLine("config", "told the Shell extension to read config {d} as defaults", .{index});
}

/// 표시 파일의 한 줄 — `v1 <SHA-256 소문자 16진수>\n`. 확장은 `GLib.compute_checksum_for_data`
/// (소문자 16진수) 로 같은 줄을 만들어 견준다.
fn ignoredConfigLine(digest: [32]u8) [3 + 64 + 1]u8 {
    var line: [3 + 64 + 1]u8 = undefined;
    @memcpy(line[0..3], "v1 ");
    line[3..67].* = std.fmt.bytesToHex(digest, .lower);
    line[67] = '\n';
    return line;
}

test "#758 무시 표시의 줄은 GLib 의 SHA-256 소문자 16진수와 같은 모양이다" {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("abc", &digest, .{});
    // FIPS 180-2 의 "abc" 시험값. GLib 도 같은 소문자 표기를 낸다.
    try std.testing.expectEqualStrings(
        "v1 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n",
        &ignoredConfigLine(digest),
    );
}

/// 상태 파일 내용. 새 자리에 없으면 옛 확장의 자리를 본다 — 업그레이드 뒤 첫 실행에는 셸에
/// 아직 옛 확장 코드가 올라가 있다 (#708, `paths.legacyHotkeyStatePath`). 내용 검사는
/// 두 자리가 같다 — 형식이 같고 (`v1 …`), hotkey 가 지금 config 와 같아야 한다.
fn readHotkeyState(rt: Runtime, allocator: std.mem.Allocator, index: u32) ?[]u8 {
    const path = paths.instanceHotkeyStatePath(rt, allocator, index) catch return null;
    defer allocator.free(path);
    if (readSmallFile(rt, allocator, path)) |content| return content;
    const legacy = (paths.legacyHotkeyStatePath(rt, allocator, index) catch return null) orelse return null;
    defer allocator.free(legacy);
    const content = readSmallFile(rt, allocator, legacy) orelse return null;
    log.appendLine("hotkey", "shell extension state read from the old extension's path (the shell still runs the previous extension until the next login)", .{});
    return content;
}

fn readSmallFile(rt: Runtime, allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(rt.io, path, .{}) catch return null;
    defer file.close(rt.io);
    var file_reader = file.reader(rt.io, &.{});
    return file_reader.interface.allocRemaining(allocator, .limited(4 * 1024)) catch null;
}

/// 처음 활성화된 extension의 config monitor가 상태 파일을 쓰는 짧은 구간을 기다린다.
/// 설정상 active인데 1초 뒤에도 파일이 없으면 새로 발견되지 않았거나 load error인
/// 것이므로 일반 창으로 내리지 않고 필수 extension 오류로 멈춘다 (#676).
pub fn waitForShellExtensionHotkeyState(rt: Runtime, allocator: std.mem.Allocator, index: u32) HotkeyState {
    const interval_ns = 20 * std.time.ns_per_ms;
    const timeout_ns = std.time.ns_per_s;
    var elapsed: u64 = 0;
    while (true) {
        const state = shellExtensionHotkeyState(rt, allocator, index);
        if (state != .unavailable or elapsed >= timeout_ns) return state;
        rt.sleepNs(interval_ns);
        elapsed += interval_ns;
    }
}
