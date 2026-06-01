//! #207 — GNOME global hotkey 자동 등록. GNOME (mutter) 은 layer-shell 미지원이라
//! tildaz 가 xdg-shell 일반 창으로 뜨고, portal `GlobalShortcuts` 채택도 ongoing /
//! 불안정이라 hotkey 실동작은 #198 single_instance (`tildaz --toggle`) 경로다. 이
//! 모듈은 그 `tildaz --toggle` 을 GNOME 의 *custom keybinding* 으로 자동 등록한다 —
//! 사용자가 GNOME Settings 를 손대지 않아도 `config.hotkey` 가 system binding 에
//! 반영된다 (config = source of truth, KDE / sway 자동 적용과 동등 정책).
//!
//! 구현은 GSettings (`libgio-2.0`) 를 runtime dlopen — `gsettings` CLI subprocess 가
//! 아니라 라이브러리 직접 (dbus / fontconfig / freetype / xkb / harfbuzz 와 같은
//! dlopen 패턴 일관). dconf 직접 D-Bus 쓰기는 gvdb 직렬화가 필요해 회피.
//!
//! GNOME custom keybinding 표준 (3단계):
//!   1. `org.gnome.settings-daemon.plugins.media-keys` 의 `custom-keybindings`
//!      (strv of dconf paths) 에 우리 path 추가.
//!   2. relocatable schema `...media-keys.custom-keybinding` 을 우리 path 로 열어
//!   3. `name` / `command` / `binding` (모두 string) set.
//!
//! 우리 path 는 고정 (`.../custom-keybindings/tildaz/`) — 매 실행 idempotent
//! (덮어쓰기, customN 번호 충돌 회피). config 변경 시 다음 실행에 자동 반영.
//!
//! ⚠️ `g_settings_new` 은 schema 미설치 시 `g_error` → abort (프로세스 죽음). 반드시
//! `g_settings_schema_source_lookup` 으로 schema 존재를 먼저 확인한 뒤 연다.

const std = @import("std");
const log = @import("../../log.zig");
const config_mod = @import("../../config.zig");
const portal = @import("portal.zig");

const c = struct {
    const GSettings = opaque {};
    const GSettingsSchema = opaque {};
    const GSettingsSchemaSource = opaque {};
};

const schema_media_keys = "org.gnome.settings-daemon.plugins.media-keys";
const schema_custom_kb = "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding";
const key_list = "custom-keybindings";
const our_path = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/tildaz/";
const extension_uuid = "tildaz@ensky0.github.io";
const schema_gnome_shell = "org.gnome.shell";
const key_enabled_extensions = "enabled-extensions";

const Api = struct {
    schema_source_get_default: *const fn () callconv(.c) ?*c.GSettingsSchemaSource,
    schema_source_lookup: *const fn (?*c.GSettingsSchemaSource, [*:0]const u8, c_int) callconv(.c) ?*c.GSettingsSchema,
    schema_unref: *const fn (?*c.GSettingsSchema) callconv(.c) void,
    settings_new: *const fn ([*:0]const u8) callconv(.c) ?*c.GSettings,
    settings_new_with_path: *const fn ([*:0]const u8, [*:0]const u8) callconv(.c) ?*c.GSettings,
    settings_get_strv: *const fn (?*c.GSettings, [*:0]const u8) callconv(.c) ?[*:null]?[*:0]u8,
    settings_set_strv: *const fn (?*c.GSettings, [*:0]const u8, [*]const ?[*:0]const u8) callconv(.c) c_int,
    settings_set_string: *const fn (?*c.GSettings, [*:0]const u8, [*:0]const u8) callconv(.c) c_int,
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
            .settings_new_with_path = lookup(handle, @TypeOf(@as(Api, undefined).settings_new_with_path), "g_settings_new_with_path") orelse return null,
            .settings_get_strv = lookup(handle, @TypeOf(@as(Api, undefined).settings_get_strv), "g_settings_get_strv") orelse return null,
            .settings_set_strv = lookup(handle, @TypeOf(@as(Api, undefined).settings_set_strv), "g_settings_set_strv") orelse return null,
            .settings_set_string = lookup(handle, @TypeOf(@as(Api, undefined).settings_set_string), "g_settings_set_string") orelse return null,
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

/// boot 진입점 — 현재 세션이 GNOME 이면 toggle hotkey 를 custom keybinding 으로
/// 자동 등록. GNOME 이 아니거나 (schema 미설치 / libgio 없음) 등록 실패는 모두
/// graceful — log 만 남기고 반환. single_instance toggle listener 는 그대로
/// 살아 있어 사용자 수동 등록도 가능.
pub fn registerToggleIfGnome(allocator: std.mem.Allocator, cfg: *const config_mod.Config) void {
    if (!isGnomeDesktop(allocator)) return;

    const api = Api.load() orelse {
        log.appendLine("gnome", "libgio-2.0 dlopen 실패 — custom keybinding 자동 등록 skip", .{});
        return;
    };

    // schema 존재 확인 (g_settings_new abort 회피).
    const source = api.schema_source_get_default() orelse {
        log.appendLine("gnome", "GSettings schema source 없음 — skip", .{});
        return;
    };
    const sch_media = api.schema_source_lookup(source, schema_media_keys, 1) orelse {
        log.appendLine("gnome", "schema {s} 미설치 (gnome-settings-daemon 없음?) — skip", .{schema_media_keys});
        return;
    };
    api.schema_unref(sch_media);
    const sch_kb = api.schema_source_lookup(source, schema_custom_kb, 1) orelse {
        log.appendLine("gnome", "relocatable schema {s} 미설치 — skip", .{schema_custom_kb});
        return;
    };
    api.schema_unref(sch_kb);

    // tildaz GNOME Shell extension(#228) 이 활성이면 그 extension 이 hotkey 를
    // 전담한다 (extension 의 addKeybinding 과 gsettings custom keybinding 이 같은
    // 키를 두 곳에 등록하면 충돌). 등록을 skip 하고 기존 우리 항목도 제거한다.
    if (isExtensionEnabled(&api)) {
        const media_ext = api.settings_new(schema_media_keys) orelse return;
        defer api.object_unref(media_ext);
        removeOurKeybinding(allocator, &api, media_ext);
        log.appendLine("gnome", "tildaz extension 활성 — gsettings hotkey skip + 기존 custom-keybinding 제거 (extension 이 hotkey 전담)", .{});
        return;
    }

    // self exe path + command / accel 준비.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_buf) catch |err| {
        log.appendLine("gnome", "selfExePath 실패: {s} — skip", .{@errorName(err)});
        return;
    };
    var cmd_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const command = std.fmt.bufPrintZ(&cmd_buf, "{s} --toggle", .{exe_path}) catch return;
    var accel_buf: [96]u8 = undefined;
    const accel = buildGtkAccel(&accel_buf, cfg.hotkey.keysym, cfg.hotkey.modifiers) catch return;

    // 1단계 — custom-keybindings 리스트에 우리 path 추가 (없을 때만).
    const media = api.settings_new(schema_media_keys) orelse {
        log.appendLine("gnome", "g_settings_new(media-keys) 실패 — skip", .{});
        return;
    };
    defer api.object_unref(media);
    ensurePathInList(allocator, &api, media) catch |err| {
        log.appendLine("gnome", "custom-keybindings 리스트 갱신 실패: {s} — skip", .{@errorName(err)});
        return;
    };

    // 2/3단계 — relocatable schema 를 우리 path 로 열어 name/command/binding set.
    const kb = api.settings_new_with_path(schema_custom_kb, our_path) orelse {
        log.appendLine("gnome", "g_settings_new_with_path 실패 — skip", .{});
        return;
    };
    defer api.object_unref(kb);
    _ = api.settings_set_string(kb, "name", "TildaZ");
    _ = api.settings_set_string(kb, "command", command);
    _ = api.settings_set_string(kb, "binding", accel);
    api.settings_sync();

    log.appendLine("gnome", "custom keybinding 자동 등록 OK — binding={s} command={s} (path={s})", .{ accel, command, our_path });
}

/// `custom-keybindings` strv 에 우리 path 가 없으면 추가. 있으면 no-op (idempotent).
fn ensurePathInList(allocator: std.mem.Allocator, api: *const Api, media: *c.GSettings) !void {
    const existing = api.settings_get_strv(media, key_list);
    defer api.strfreev(existing);

    var list: std.ArrayList(?[*:0]const u8) = .empty;
    defer list.deinit(allocator);

    if (existing) |e| {
        var i: usize = 0;
        while (e[i]) |s| : (i += 1) {
            if (std.mem.eql(u8, std.mem.span(s), our_path)) return; // 이미 등록됨.
            try list.append(allocator, s);
        }
    }
    try list.append(allocator, our_path);
    try list.append(allocator, null); // NULL-terminate (g_settings_set_strv 요구).
    _ = api.settings_set_strv(media, key_list, list.items.ptr);
}

/// GNOME 세션 + tildaz extension 활성 여부. linux_wayland 의 autostart 분기용 —
/// 이 경우 launch/show/hide lifecycle 을 extension 이 담당하므로 zig 의 autostart
/// `.desktop` 은 만들지 않고 (있으면) 삭제한다 (DE 전환 잔재 제거 + 로그인 시
/// placement 전 중앙 일반창 방지).
pub fn isGnomeWithExtension(allocator: std.mem.Allocator) bool {
    if (!isGnomeDesktop(allocator)) return false;
    const api = Api.load() orelse return false;
    return isExtensionEnabled(&api);
}

/// `org.gnome.shell` 의 `enabled-extensions` 에 tildaz extension uuid 가 있나.
fn isExtensionEnabled(api: *const Api) bool {
    const source = api.schema_source_get_default() orelse return false;
    const sch = api.schema_source_lookup(source, schema_gnome_shell, 1) orelse return false;
    api.schema_unref(sch);
    const s = api.settings_new(schema_gnome_shell) orelse return false;
    defer api.object_unref(s);
    const arr = api.settings_get_strv(s, key_enabled_extensions);
    defer api.strfreev(arr);
    if (arr) |e| {
        var i: usize = 0;
        while (e[i]) |item| : (i += 1) {
            if (std.mem.eql(u8, std.mem.span(item), extension_uuid)) return true;
        }
    }
    return false;
}

/// `custom-keybindings` 리스트에서 우리 path 제거 (extension 활성 시 중복 정리).
fn removeOurKeybinding(allocator: std.mem.Allocator, api: *const Api, media: *c.GSettings) void {
    const existing = api.settings_get_strv(media, key_list);
    defer api.strfreev(existing);
    if (existing == null) return;
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    defer list.deinit(allocator);
    var found = false;
    var i: usize = 0;
    while (existing.?[i]) |s| : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(s), our_path)) {
            found = true;
            continue;
        }
        list.append(allocator, s) catch return;
    }
    if (!found) return;
    list.append(allocator, null) catch return;
    _ = api.settings_set_strv(media, key_list, list.items.ptr);
}

/// `XDG_CURRENT_DESKTOP` (콜론 구분 다중 토큰, 예 `ubuntu:GNOME`) 에 GNOME 토큰 여부.
pub fn isGnomeDesktop(allocator: std.mem.Allocator) bool {
    const de = std.process.getEnvVarOwned(allocator, "XDG_CURRENT_DESKTOP") catch return false;
    defer allocator.free(de);
    var it = std.mem.tokenizeScalar(u8, de, ':');
    while (it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(tok, "GNOME")) return true;
    }
    return false;
}

/// `config.hotkey` → GTK accelerator (GNOME `binding` 형식). modifier 는
/// `<Control><Shift><Alt><Super>` (gtk_accelerator_parse 표준), key 이름은
/// `portal.keysymGtkName` 재사용 (`F1` / `a` / `space` / `grave` 등).
fn buildGtkAccel(buf: []u8, keysym: u32, modifiers: u32) ![:0]const u8 {
    const H = config_mod.Hotkey;
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    if ((modifiers & H.MOD_CTRL) != 0) try w.writeAll("<Control>");
    if ((modifiers & H.MOD_SHIFT) != 0) try w.writeAll("<Shift>");
    if ((modifiers & H.MOD_ALT) != 0) try w.writeAll("<Alt>");
    if ((modifiers & H.MOD_SUPER) != 0) try w.writeAll("<Super>");
    try w.writeAll(portal.keysymGtkName(keysym));
    try w.writeByte(0);
    const written = fbs.getWritten();
    return written[0 .. written.len - 1 :0];
}
