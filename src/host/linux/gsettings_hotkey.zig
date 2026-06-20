//! #207 / #229 — GNOME · Cinnamon global hotkey 자동 등록. 둘 다 layer-shell
//! 미지원이라 tildaz 가 xdg-shell 일반 창으로 뜨고, hotkey 실동작은 #198
//! single_instance (`tildaz --toggle`) 경로다. 이 모듈은 그 `tildaz --toggle` 을
//! 세션 DE 의 *custom keybinding* 으로 자동 등록한다 — 사용자가 시스템 설정을
//! 손대지 않아도 `config.hotkey` 가 system binding 에 반영된다 (config = source of
//! truth, KDE / sway 자동 적용과 동등 정책).
//!
//! 구현은 GSettings (`libgio-2.0`) 를 runtime dlopen — `gsettings` CLI subprocess 가
//! 아니라 라이브러리 직접 (dbus / fontconfig / freetype / xkb / harfbuzz 와 같은
//! dlopen 패턴 일관). dconf 직접 D-Bus 쓰기는 gvdb 직렬화가 필요해 회피.
//!
//! custom keybinding 표준 (3단계, GNOME · Cinnamon 공통):
//!   1. 리스트 schema 의 리스트 key (strv) 에 우리 항목 추가.
//!   2. relocatable per-binding schema 를 우리 고정 path 로 열어
//!   3. `name` / `command` / `binding` set.
//!
//! 우리 path 는 고정 (`.../custom-keybindings/tildaz/`) — 매 실행 idempotent
//! (덮어쓰기, customN 번호 충돌 회피). config 변경 시 다음 실행에 자동 반영.
//!
//! GNOME ↔ Cinnamon 차이 (`Variant` descriptor 로 흡수, 그 외 경로는 공통):
//!   - 리스트에 넣는 값: GNOME 은 full dconf path, Cinnamon 은 id (`tildaz`).
//!   - `binding` key 타입: GNOME 은 string, Cinnamon 은 strv (`['<Super>grave']`).
//!   - schema / key / path 이름.
//!   출처: linuxmint/Cinnamon 5a4c4a7, community.linuxmint.com/tutorial/view/1171.
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

// --- GNOME (gnome-settings-daemon media-keys) ---
const gnome_list_schema = "org.gnome.settings-daemon.plugins.media-keys";
const gnome_list_key = "custom-keybindings";
const gnome_kb_schema = "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding";
const gnome_path = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/tildaz/";

// --- Cinnamon (cinnamon-settings-daemon keybindings) ---
const cinnamon_list_schema = "org.cinnamon.desktop.keybindings";
const cinnamon_list_key = "custom-list";
const cinnamon_kb_schema = "org.cinnamon.desktop.keybindings.custom-keybinding";
const cinnamon_path = "/org/cinnamon/desktop/keybindings/custom-keybindings/tildaz/";
const cinnamon_id = "tildaz";

const schema_gnome_shell = "org.gnome.shell";
const schema_cinnamon_shell = "org.cinnamon";
const key_enabled_extensions = "enabled-extensions"; // GNOME · Cinnamon 동일 key 이름.
const extension_uuid = "tildaz@ensky0.github.io";

/// GSettings custom-keybinding 등록의 DE별 차이를 담는 descriptor. GNOME 과
/// Cinnamon 은 같은 3단계 (리스트에 항목 추가 → relocatable schema 를 우리 path 로
/// 열기 → name/command/binding set) 지만 (1) 리스트에 넣는 값이 GNOME 은 full dconf
/// path, Cinnamon 은 id, (2) `binding` key 가 GNOME 은 string, Cinnamon 은 strv 다.
const Variant = struct {
    list_schema: [*:0]const u8,
    list_key: [*:0]const u8,
    kb_schema: [*:0]const u8,
    path: [*:0]const u8,
    list_value: [*:0]const u8,
    binding_is_strv: bool,
};

const gnome_variant = Variant{
    .list_schema = gnome_list_schema,
    .list_key = gnome_list_key,
    .kb_schema = gnome_kb_schema,
    .path = gnome_path,
    .list_value = gnome_path, // GNOME 리스트는 full dconf path 를 담는다.
    .binding_is_strv = false,
};

const cinnamon_variant = Variant{
    .list_schema = cinnamon_list_schema,
    .list_key = cinnamon_list_key,
    .kb_schema = cinnamon_kb_schema,
    .path = cinnamon_path,
    .list_value = cinnamon_id, // Cinnamon 리스트는 id 만 담는다.
    .binding_is_strv = true,
};

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

/// boot 진입점 — 현재 세션이 GNOME 또는 Cinnamon 이면 toggle hotkey 를 custom
/// keybinding 으로 자동 등록. 그 외 DE 거나 (schema 미설치 / libgio 없음) 등록
/// 실패는 모두 graceful — log 만 남기고 반환. single_instance toggle listener 는
/// 그대로 살아 있어 사용자 수동 등록도 가능.
pub fn registerToggleHotkey(allocator: std.mem.Allocator, cfg: *const config_mod.Config) void {
    const de: enum { gnome, cinnamon } = if (isGnomeDesktop(allocator))
        .gnome
    else if (isCinnamonDesktop(allocator))
        .cinnamon
    else
        return;

    const api = Api.load() orelse {
        log.appendLine("gsettings-hotkey", "libgio-2.0 dlopen failed — custom keybinding auto-register skipped", .{});
        return;
    };
    const source = api.schema_source_get_default() orelse {
        log.appendLine("gsettings-hotkey", "GSettings schema source not found — skipped", .{});
        return;
    };

    switch (de) {
        .gnome => {
            if (!schemasPresent(&api, source, gnome_variant)) {
                log.appendLine("gnome", "media-keys custom-keybinding schema not installed (gnome-settings-daemon missing?) — skipped", .{});
                return;
            }
            // tildaz GNOME Shell extension(#228) 이 활성이면 그 extension 이 hotkey 를
            // 전담한다 (extension 의 addKeybinding 과 gsettings custom keybinding 이
            // 같은 키를 두 곳에 등록하면 충돌). 등록을 skip 하고 기존 항목도 제거한다.
            if (isExtensionEnabled(&api)) {
                const media_ext = api.settings_new(gnome_variant.list_schema) orelse return;
                defer api.object_unref(media_ext);
                removeFromList(allocator, &api, media_ext, gnome_variant);
                log.appendLine("gnome", "tildaz extension active — gsettings hotkey skipped + removed existing custom-keybinding (extension handles hotkey)", .{});
                return;
            }
            registerWithVariant(allocator, &api, cfg, gnome_variant);
        },
        .cinnamon => {
            if (!schemasPresent(&api, source, cinnamon_variant)) {
                log.appendLine("cinnamon", "keybindings custom-keybinding schema not installed — skipped", .{});
                return;
            }
            // tildaz Cinnamon extension(#229 Phase 2)이 활성이면 그 extension 이
            // hotkey 를 전담한다 (addHotKey + minimize/unminimize toggle). gsettings
            // custom-keybinding 을 함께 두면 (1) F1 이중 grab, (2) gsettings 가 부르는
            // `tildaz --toggle` 의 null-buffer hide 가 extension 배치를 깨므로(#229
            // 실측) 등록을 skip 하고 기존 항목도 제거한다. 미설치면 일반 xdg 창 +
            // gsettings F1 fallback.
            if (isCinnamonExtensionEnabled(&api)) {
                const list = api.settings_new(cinnamon_variant.list_schema) orelse return;
                defer api.object_unref(list);
                removeFromList(allocator, &api, list, cinnamon_variant);
                log.appendLine("cinnamon", "tildaz extension active — gsettings hotkey skipped + removed existing custom-keybinding (extension handles hotkey)", .{});
                return;
            }
            registerWithVariant(allocator, &api, cfg, cinnamon_variant);
        },
    }
}

/// `Variant` 의 리스트 schema 와 relocatable per-binding schema 가 모두 설치돼
/// 있는지 (`g_settings_new` abort 회피). 둘 다 있으면 true.
fn schemasPresent(api: *const Api, source: *c.GSettingsSchemaSource, v: Variant) bool {
    const sch_list = api.schema_source_lookup(source, v.list_schema, 1) orelse return false;
    api.schema_unref(sch_list);
    const sch_kb = api.schema_source_lookup(source, v.kb_schema, 1) orelse return false;
    api.schema_unref(sch_kb);
    return true;
}

/// 3단계 등록 (GNOME · Cinnamon 공통). 차이는 모두 `v` 에서 읽는다.
fn registerWithVariant(allocator: std.mem.Allocator, api: *const Api, cfg: *const config_mod.Config, v: Variant) void {
    // self exe path + command / accel 준비.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_buf) catch |err| {
        log.appendLine("gsettings-hotkey", "selfExePath failed: {s} — skipped", .{@errorName(err)});
        return;
    };
    var cmd_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const command = std.fmt.bufPrintZ(&cmd_buf, "{s} --toggle", .{exe_path}) catch return;
    var accel_buf: [96]u8 = undefined;
    const accel = buildGtkAccel(&accel_buf, cfg.hotkey.keysym, cfg.hotkey.modifiers) catch return;

    // ⚠️ 순서 중요 — name/command/binding 을 **먼저** set 하고, 리스트 추가를
    // **마지막**에 한다. Cinnamon 은 `changed::custom-list` 를 런타임에 감시해 새
    // 항목을 즉시 bind 하는데, 리스트를 먼저 바꾸면 그 신호를 받는 순간 아직 빈
    // command/binding 을 읽고는 이후 값 변경은 (custom-list 가 안 바뀌니) 다시 안
    // 읽어 — 재로그인 전까지 hotkey 가 안 먹는다 (#229 실측, 재로그인하면 처음부터
    // 값이 다 있는 상태로 읽어 동작). 값을 먼저 넣어두면 리스트 추가 신호 한 번에
    // 라이브로 bind 된다. GNOME (gnome-settings-daemon) 은 기존 순서로도 동작했고
    // 이 순서로도 무해 — 두 DE 공통으로 더 안전하다.
    // 1/2단계 — relocatable schema 를 우리 path 로 열어 name/command/binding set.
    const kb = api.settings_new_with_path(v.kb_schema, v.path) orelse {
        log.appendLine("gsettings-hotkey", "g_settings_new_with_path failed — skipped", .{});
        return;
    };
    defer api.object_unref(kb);
    _ = api.settings_set_string(kb, "name", "TildaZ");
    _ = api.settings_set_string(kb, "command", command);
    if (v.binding_is_strv) {
        // Cinnamon `binding` 은 strv — ['<Super>grave'] 형식.
        const arr = [_]?[*:0]const u8{ accel.ptr, null };
        _ = api.settings_set_strv(kb, "binding", &arr);
    } else {
        _ = api.settings_set_string(kb, "binding", accel);
    }
    // 값을 dconf 백엔드에 먼저 flush — 다음 리스트 변경 신호를 Cinnamon 이 받을 때
    // 값이 이미 있도록 보장한다 (단일 dconf 백엔드라 쓰기 순서는 보존되지만, 명시
    // sync 로 race 여지를 없앤다).
    api.settings_sync();

    // 3단계 — 리스트에 우리 항목 추가 (없을 때만; idempotent). 이 변경이 Cinnamon
    // 의 즉시 re-bind 를 트리거한다 (값은 위에서 이미 들어가 있음).
    const list = api.settings_new(v.list_schema) orelse {
        log.appendLine("gsettings-hotkey", "g_settings_new({s}) failed — skipped", .{v.list_schema});
        return;
    };
    defer api.object_unref(list);
    ensureInList(allocator, api, list, v.list_key, v.list_value) catch |err| {
        log.appendLine("gsettings-hotkey", "{s} list update failed: {s} — skipped", .{ v.list_key, @errorName(err) });
        return;
    };
    api.settings_sync();

    log.appendLine("gsettings-hotkey", "custom keybinding auto-registered OK — binding={s} command={s} (path={s})", .{ accel, command, v.path });
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
    _ = api.settings_set_strv(settings, key, list.items.ptr);
}

/// 리스트 strv (`v.list_key`) 에서 우리 항목 (`v.list_value`) 제거 (GNOME extension
/// 활성 시 중복 정리).
fn removeFromList(allocator: std.mem.Allocator, api: *const Api, settings: *c.GSettings, v: Variant) void {
    const existing = api.settings_get_strv(settings, v.list_key);
    defer api.strfreev(existing);
    if (existing == null) return;
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    defer list.deinit(allocator);
    const want = std.mem.span(v.list_value);
    var found = false;
    var i: usize = 0;
    while (existing.?[i]) |s| : (i += 1) {
        if (std.mem.eql(u8, std.mem.span(s), want)) {
            found = true;
            continue;
        }
        list.append(allocator, s) catch return;
    }
    if (!found) return;
    list.append(allocator, null) catch return;
    _ = api.settings_set_strv(settings, v.list_key, list.items.ptr);
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
    return isExtensionEnabledInSchema(api, schema_gnome_shell);
}

/// `org.cinnamon` 의 `enabled-extensions` 에 tildaz extension uuid 가 있나.
fn isCinnamonExtensionEnabled(api: *const Api) bool {
    return isExtensionEnabledInSchema(api, schema_cinnamon_shell);
}

/// `<schema>` 의 `enabled-extensions` (strv) 에 tildaz uuid 가 있나. GNOME
/// (`org.gnome.shell`) · Cinnamon (`org.cinnamon`) 둘 다 같은 key 이름이라 schema 만
/// 다르다. schema 미설치면 false.
fn isExtensionEnabledInSchema(api: *const Api, schema: [*:0]const u8) bool {
    const source = api.schema_source_get_default() orelse return false;
    const sch = api.schema_source_lookup(source, schema, 1) orelse return false;
    api.schema_unref(sch);
    const s = api.settings_new(schema) orelse return false;
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

/// `XDG_CURRENT_DESKTOP` (콜론 구분 다중 토큰, 예 `ubuntu:GNOME`) 에 GNOME 토큰 여부.
pub fn isGnomeDesktop(allocator: std.mem.Allocator) bool {
    return desktopHasToken(allocator, &.{"GNOME"});
}

/// `XDG_CURRENT_DESKTOP` 에 Cinnamon 토큰 여부. Linux Mint 는 `X-Cinnamon`,
/// 일부 배포 / 설정은 `Cinnamon` — 둘 다 인정.
pub fn isCinnamonDesktop(allocator: std.mem.Allocator) bool {
    return desktopHasToken(allocator, &.{ "X-Cinnamon", "Cinnamon" });
}

/// `XDG_CURRENT_DESKTOP` 의 콜론 구분 토큰 중 하나라도 `wanted` 에 (대소문자 무시)
/// 들어 있나.
fn desktopHasToken(allocator: std.mem.Allocator, wanted: []const []const u8) bool {
    const de = std.process.getEnvVarOwned(allocator, "XDG_CURRENT_DESKTOP") catch return false;
    defer allocator.free(de);
    var it = std.mem.tokenizeScalar(u8, de, ':');
    while (it.next()) |tok| {
        for (wanted) |w| {
            if (std.ascii.eqlIgnoreCase(tok, w)) return true;
        }
    }
    return false;
}

/// `config.hotkey` → GTK accelerator (GNOME `binding` 형식, Cinnamon strv 의 원소).
/// modifier 는 `<Control><Shift><Alt><Super>` (gtk_accelerator_parse 표준), key
/// 이름은 `portal.keysymGtkName` 재사용 (`F1` / `a` / `space` / `grave` 등).
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
