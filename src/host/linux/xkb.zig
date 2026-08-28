//! Runtime libxkbcommon wrapper for the direct Wayland backend.
//!
//! Wayland delivers keyboard keymaps as XKB text. Loading libxkbcommon at
//! runtime keeps macOS-hosted Linux cross builds from needing Linux headers or a
//! Linux linker setup, while still using the standard Wayland keyboard path on
//! real Linux desktops.

const std = @import("std");
const log = @import("../../log.zig");

const xkb_context = opaque {};
const xkb_keymap = opaque {};
const xkb_state = opaque {};
const xkb_compose_table = opaque {};
const xkb_compose_state = opaque {};

const XKB_CONTEXT_NO_FLAGS: c_uint = 0;
const XKB_KEYMAP_FORMAT_TEXT_V1: c_uint = 1;
const XKB_KEYMAP_COMPILE_NO_FLAGS: c_uint = 0;

// #494 — libxkbcommon Compose (`xkbcommon-compose.h`). 값은 헤더의 enum 순서 그대로다.
const XKB_COMPOSE_COMPILE_NO_FLAGS: c_uint = 0;
const XKB_COMPOSE_STATE_NO_FLAGS: c_uint = 0;
/// `enum xkb_compose_status`
const XKB_COMPOSE_NOTHING: c_int = 0;
const XKB_COMPOSE_COMPOSING: c_int = 1;
const XKB_COMPOSE_COMPOSED: c_int = 2;
const XKB_COMPOSE_CANCELLED: c_int = 3;
/// `enum xkb_compose_feed_result`
const XKB_COMPOSE_FEED_IGNORED: c_int = 0;
const XKB_COMPOSE_FEED_ACCEPTED: c_int = 1;

const XkbContextNew = *const fn (flags: c_uint) callconv(.c) ?*xkb_context;
const XkbContextUnref = *const fn (context: ?*xkb_context) callconv(.c) void;
const XkbKeymapNewFromString = *const fn (
    context: *xkb_context,
    string: [*:0]const u8,
    format: c_uint,
    flags: c_uint,
) callconv(.c) ?*xkb_keymap;
const XkbKeymapUnref = *const fn (keymap: ?*xkb_keymap) callconv(.c) void;
const XkbStateNew = *const fn (keymap: *xkb_keymap) callconv(.c) ?*xkb_state;
const XkbStateUnref = *const fn (state: ?*xkb_state) callconv(.c) void;
const XkbStateUpdateMask = *const fn (
    state: *xkb_state,
    depressed_mods: c_uint,
    latched_mods: c_uint,
    locked_mods: c_uint,
    depressed_layout: c_uint,
    latched_layout: c_uint,
    locked_layout: c_uint,
) callconv(.c) c_uint;
const XkbStateKeyGetUtf8 = *const fn (
    state: *xkb_state,
    key: c_uint,
    buffer: [*]u8,
    size: usize,
) callconv(.c) c_int;
const XkbStateKeyGetOneSym = *const fn (state: *xkb_state, key: c_uint) callconv(.c) c_uint;
const XkbStateModNameIsActive = *const fn (
    state: *xkb_state,
    name: [*:0]const u8,
    component: c_uint,
) callconv(.c) c_int;

// #513 — 진단용. **받은 keymap 이 어느 layout 인지**를 로그에 남긴다. COSMIC 에서
// 키보드를 꽂으면 위치 표기 hotkey 가 직전 layout 의 글자로 재등록되는데, 로그만으로는
// *compositor 가 옛 keymap 을 보낸 것*인지 *우리가 잘못 읽은 것*인지 구분할 수 없었다
// ([#513](https://github.com/ensky0/tildaz/issues/513)).
// #533 — `utf8` 을 만드는 데 쓰인 modifier (`xkb_mod_mask_t`). AltGr 처럼 이미 문자를
// 낸 조합에 ESC 를 붙이지 않으려면 이 정보가 필요하다.
const XkbStateKeyGetConsumedMods2 = *const fn (
    state: *xkb_state,
    key: c_uint,
    mode: c_uint,
) callconv(.c) u32;
// mask 의 비트가 어느 modifier 인지 알려면 index 가 필요하다 (`Shift` · `Control` · …).
const XkbKeymapModGetIndex = *const fn (keymap: *xkb_keymap, name: [*:0]const u8) callconv(.c) c_uint;

// `enum xkb_consumed_mode`. GTK 모드를 쓴다 — ghostty 의 GTK apprt 가 gdk 를 거쳐 쓰는
// 것과 같은 판정이라 두 구현의 결과가 어긋나지 않는다.
const XKB_CONSUMED_MODE_GTK: c_uint = 1;
/// `XKB_MOD_INVALID` — 그 이름의 modifier 가 keymap 에 없다.
const XKB_MOD_INVALID: c_uint = 0xffff_ffff;

const XkbKeymapNumLayouts = *const fn (keymap: *xkb_keymap) callconv(.c) c_uint;
const XkbKeymapLayoutGetName = *const fn (keymap: *xkb_keymap, layout: c_uint) callconv(.c) ?[*:0]const u8;

// #496 1-a — keymap 전수 조회용. **비라틴 layout 에서 "이 문자를 낼 수 있는 키가
// 하나도 없다" 를 판정**하는 데 쓴다. state 가 아니라 keymap 을 보는 이유는 현재
// modifier / layout 과 무관하게 물어야 하기 때문이다 — `xkb_state_key_get_one_sym`
// 은 지금 눌린 modifier 와 활성 group 만 본다.
//
// **이 다섯은 optional 이다.** 없으면 fallback 기능만 끄고 키보드는 정상 동작한다.
// 기존 심볼처럼 `error.XkbSymbolMissing` 으로 묶으면 오래된 libxkbcommon 에서
// 키보드가 통째로 죽는데, 그것은 이 기능이 감당할 대가가 아니다.
const XkbKeymapMinKeycode = *const fn (keymap: *xkb_keymap) callconv(.c) c_uint;
const XkbKeymapMaxKeycode = *const fn (keymap: *xkb_keymap) callconv(.c) c_uint;
const XkbKeymapNumLayoutsForKey = *const fn (keymap: *xkb_keymap, key: c_uint) callconv(.c) c_uint;
const XkbKeymapNumLevelsForKey = *const fn (keymap: *xkb_keymap, key: c_uint, layout: c_uint) callconv(.c) c_uint;
const XkbKeymapKeyGetSymsByLevel = *const fn (
    keymap: *xkb_keymap,
    key: c_uint,
    layout: c_uint,
    level: c_uint,
    syms_out: *[*]const c_uint,
) callconv(.c) c_int;

/// #496 1-c — `xkb_keysym_get_name(keysym, buffer, size)`. 이름 길이를 돌려주고
/// 버퍼가 모자라면 필요한 길이를 준다 (음수는 실패).
/// #496 1-c — `xkb_keysym_to_utf32(keysym)`. 문자를 내지 않는 keysym 은 0 이다.
/// **legacy 국가별 keysym 을 값만으로는 알 수 없어서** 필요하다 — `Cyrillic_io` 는
/// `0x06b3` 이라 Latin-1 구간도, modern 유니코드 keysym (`0x01000000 | cp`) 도 아니다.
/// 그 블록을 손으로 나열하려다 실기에서 키릴이 통째로 빠진 것을 발견했다.
const XkbKeysymToUtf32 = *const fn (keysym: c_uint) callconv(.c) u32;

const XkbKeysymGetName = *const fn (
    keysym: c_uint,
    buffer: [*]u8,
    size: usize,
) callconv(.c) c_int;

// #494 — Compose. dead key (`dead_circumflex` 0xfe52 등) 는 `xkb_state_key_get_utf8` 이 빈
// 문자열을 내고, 다음 키와의 조합 (`^`+`e` → `ê`, `^`+space → `^`) 은 이 상태 기계가 한다 —
// GTK · Qt 가 쓰는 것과 같은 경로다. **여덟 개는 optional 이다.** 없으면 compose 만 꺼지고
// 키보드는 지금처럼 동작한다 (#496 1-a 의 `KeymapScan` 과 같은 이유 — 오래된 libxkbcommon
// 에서 키보드가 통째로 죽을 일이 아니다).
const XkbComposeTableNewFromLocale = *const fn (
    context: *xkb_context,
    locale: [*:0]const u8,
    flags: c_uint,
) callconv(.c) ?*xkb_compose_table;
const XkbComposeTableUnref = *const fn (table: ?*xkb_compose_table) callconv(.c) void;
const XkbComposeStateNew = *const fn (table: *xkb_compose_table, flags: c_uint) callconv(.c) ?*xkb_compose_state;
const XkbComposeStateUnref = *const fn (state: ?*xkb_compose_state) callconv(.c) void;
const XkbComposeStateFeed = *const fn (state: *xkb_compose_state, keysym: c_uint) callconv(.c) c_int;
const XkbComposeStateReset = *const fn (state: *xkb_compose_state) callconv(.c) void;
const XkbComposeStateGetStatus = *const fn (state: *xkb_compose_state) callconv(.c) c_int;
const XkbComposeStateGetUtf8 = *const fn (
    state: *xkb_compose_state,
    buffer: [*]u8,
    size: usize,
) callconv(.c) c_int;

// libxkbcommon `enum xkb_state_component`. MODS_EFFECTIVE = (1 << 3).
// 처음에 (1 << 7) = LAYOUT_EFFECTIVE 로 잘못 적어 mod_name_is_active 가
// modifier component 를 안 보고 항상 0 반환 → 단축키 분기 fail (1차 시연 발견).
const XKB_STATE_MODS_EFFECTIVE: c_uint = 0x0008;

const Api = struct {
    handle: *anyopaque,
    context_new: XkbContextNew,
    context_unref: XkbContextUnref,
    keymap_new_from_string: XkbKeymapNewFromString,
    keymap_unref: XkbKeymapUnref,
    state_new: XkbStateNew,
    state_unref: XkbStateUnref,
    state_update_mask: XkbStateUpdateMask,
    state_key_get_utf8: XkbStateKeyGetUtf8,
    state_key_get_one_sym: XkbStateKeyGetOneSym,
    state_mod_name_is_active: XkbStateModNameIsActive,
    // #496 1-a — optional. 하나라도 없으면 `keymapScan` 이 null 이 되고 fallback 이
    // 꺼진다 (위 주석 참고).
    keymap_scan: ?KeymapScan = null,
    // #513 — optional. 진단 로그 전용이라 없으면 그 줄에서 layout 이름만 빠진다.
    layout_names: ?LayoutNames = null,
    // #494 — optional. 없으면 dead key 조합만 꺼진다 (`Keyboard.composeFeed` 가 passthrough).
    compose: ?ComposeApi = null,
    // #533 — optional. 없으면 consumed modifier 판정만 꺼진다.
    consumed: ?ConsumedApi = null,

    fn load() !Api {
        const handle = std.c.dlopen("libxkbcommon.so.0", .{ .LAZY = true }) orelse return error.XkbLibraryMissing;
        errdefer _ = std.c.dlclose(handle);

        return .{
            .handle = handle,
            .context_new = lookup(handle, XkbContextNew, "xkb_context_new") orelse return error.XkbSymbolMissing,
            .context_unref = lookup(handle, XkbContextUnref, "xkb_context_unref") orelse return error.XkbSymbolMissing,
            .keymap_new_from_string = lookup(handle, XkbKeymapNewFromString, "xkb_keymap_new_from_string") orelse return error.XkbSymbolMissing,
            .keymap_unref = lookup(handle, XkbKeymapUnref, "xkb_keymap_unref") orelse return error.XkbSymbolMissing,
            .state_new = lookup(handle, XkbStateNew, "xkb_state_new") orelse return error.XkbSymbolMissing,
            .state_unref = lookup(handle, XkbStateUnref, "xkb_state_unref") orelse return error.XkbSymbolMissing,
            .state_update_mask = lookup(handle, XkbStateUpdateMask, "xkb_state_update_mask") orelse return error.XkbSymbolMissing,
            .state_key_get_utf8 = lookup(handle, XkbStateKeyGetUtf8, "xkb_state_key_get_utf8") orelse return error.XkbSymbolMissing,
            .state_key_get_one_sym = lookup(handle, XkbStateKeyGetOneSym, "xkb_state_key_get_one_sym") orelse return error.XkbSymbolMissing,
            .state_mod_name_is_active = lookup(handle, XkbStateModNameIsActive, "xkb_state_mod_name_is_active") orelse return error.XkbSymbolMissing,
            .keymap_scan = KeymapScan.load(handle),
            .layout_names = LayoutNames.load(handle),
            .compose = ComposeApi.load(handle),
            .consumed = ConsumedApi.load(handle),
        };
    }

    fn deinit(self: *Api) void {
        _ = std.c.dlclose(self.handle);
    }
};

/// #496 1-a — keymap 전수 조회에 필요한 심볼 묶음. **다 있어야 의미가 있으므로 묶어서
/// all-or-nothing 으로 다룬다** — 넷만 있으면 부분 조회가 되어 오히려 잘못된 답을 낸다.
const KeymapScan = struct {
    /// #496 1-c — keysym → 이름 (`twosuperior` · `Cyrillic_io`). COSMIC 의 RON `key:` 가
    /// 이름 문자열을 받으므로 필요하다. 우리 고정표 (`config.linuxKeysymName`) 는 라벨
    /// 집합만 알아서 위치 표기가 닿는 임의의 keysym 을 이름으로 만들지 못한다.
    ///
    /// **이 묶음에 넣는 이유** — 위치 표기 hotkey 를 처리하려면 조회 심볼과 이 심볼이
    /// *함께* 있어야 한다. 하나만 있으면 자리는 풀되 이름을 못 만들어 결국 등록을 못
    /// 하므로, 갈라 두면 실패 경로만 늘어난다.
    keysym_get_name: XkbKeysymGetName,
    keysym_to_utf32: XkbKeysymToUtf32,
    min_keycode: XkbKeymapMinKeycode,
    max_keycode: XkbKeymapMaxKeycode,
    num_layouts_for_key: XkbKeymapNumLayoutsForKey,
    num_levels_for_key: XkbKeymapNumLevelsForKey,
    key_get_syms_by_level: XkbKeymapKeyGetSymsByLevel,

    fn load(handle: *anyopaque) ?KeymapScan {
        return .{
            .keysym_get_name = lookup(handle, XkbKeysymGetName, "xkb_keysym_get_name") orelse return null,
            .keysym_to_utf32 = lookup(handle, XkbKeysymToUtf32, "xkb_keysym_to_utf32") orelse return null,
            .min_keycode = lookup(handle, XkbKeymapMinKeycode, "xkb_keymap_min_keycode") orelse return null,
            .max_keycode = lookup(handle, XkbKeymapMaxKeycode, "xkb_keymap_max_keycode") orelse return null,
            .num_layouts_for_key = lookup(handle, XkbKeymapNumLayoutsForKey, "xkb_keymap_num_layouts_for_key") orelse return null,
            .num_levels_for_key = lookup(handle, XkbKeymapNumLevelsForKey, "xkb_keymap_num_levels_for_key") orelse return null,
            .key_get_syms_by_level = lookup(handle, XkbKeymapKeyGetSymsByLevel, "xkb_keymap_key_get_syms_by_level") orelse return null,
        };
    }
};

/// #513 — keymap 의 layout 이름 조회. `KeymapScan` 과 갈라 두는 이유는 **쓰임이 다르기
/// 때문**이다 — 그쪽은 없으면 라틴 fallback 기능이 꺼지지만, 이쪽은 진단 로그 한 줄이
/// 짧아질 뿐이다. 한 묶음으로 합치면 없는 쪽 하나가 다른 쪽 기능까지 끈다.
const LayoutNames = struct {
    num_layouts: XkbKeymapNumLayouts,
    layout_get_name: XkbKeymapLayoutGetName,

    fn load(handle: *anyopaque) ?LayoutNames {
        return .{
            .num_layouts = lookup(handle, XkbKeymapNumLayouts, "xkb_keymap_num_layouts") orelse return null,
            .layout_get_name = lookup(handle, XkbKeymapLayoutGetName, "xkb_keymap_layout_get_name") orelse return null,
        };
    }
};

/// #494 — Compose 상태 기계 심볼 묶음. **all-or-nothing** — `feed` 는 있는데 `get_utf8` 이
/// 없으면 조합은 되는데 결과를 못 꺼내 글자가 사라지므로, 하나라도 없으면 통째로 끈다.
/// #533 — consumed modifier 조회. **둘이 함께 있어야 의미가 있다** — 조회 함수만 있고
/// index 를 못 구하면 mask 를 해석할 수 없다. 없으면 판정이 통째로 꺼지고, 그때는 문자를
/// 만든 조합에도 ESC 가 붙을 수 있다 (libxkbcommon 0.4.0 이전 — 실질적으로 없는 환경).
const ConsumedApi = struct {
    key_get_consumed_mods2: XkbStateKeyGetConsumedMods2,
    mod_get_index: XkbKeymapModGetIndex,

    fn load(handle: *anyopaque) ?ConsumedApi {
        return .{
            .key_get_consumed_mods2 = lookup(handle, XkbStateKeyGetConsumedMods2, "xkb_state_key_get_consumed_mods2") orelse return null,
            .mod_get_index = lookup(handle, XkbKeymapModGetIndex, "xkb_keymap_mod_get_index") orelse return null,
        };
    }
};

const ComposeApi = struct {
    table_new_from_locale: XkbComposeTableNewFromLocale,
    table_unref: XkbComposeTableUnref,
    state_new: XkbComposeStateNew,
    state_unref: XkbComposeStateUnref,
    state_feed: XkbComposeStateFeed,
    state_reset: XkbComposeStateReset,
    state_get_status: XkbComposeStateGetStatus,
    state_get_utf8: XkbComposeStateGetUtf8,

    fn load(handle: *anyopaque) ?ComposeApi {
        return .{
            .table_new_from_locale = lookup(handle, XkbComposeTableNewFromLocale, "xkb_compose_table_new_from_locale") orelse return null,
            .table_unref = lookup(handle, XkbComposeTableUnref, "xkb_compose_table_unref") orelse return null,
            .state_new = lookup(handle, XkbComposeStateNew, "xkb_compose_state_new") orelse return null,
            .state_unref = lookup(handle, XkbComposeStateUnref, "xkb_compose_state_unref") orelse return null,
            .state_feed = lookup(handle, XkbComposeStateFeed, "xkb_compose_state_feed") orelse return null,
            .state_reset = lookup(handle, XkbComposeStateReset, "xkb_compose_state_reset") orelse return null,
            .state_get_status = lookup(handle, XkbComposeStateGetStatus, "xkb_compose_state_get_status") orelse return null,
            .state_get_utf8 = lookup(handle, XkbComposeStateGetUtf8, "xkb_compose_state_get_utf8") orelse return null,
        };
    }
};

fn lookup(handle: *anyopaque, comptime T: type, name: [*:0]const u8) ?T {
    const symbol = std.c.dlsym(handle, name) orelse return null;
    return @ptrCast(@alignCast(symbol));
}

pub const Keyboard = struct {
    /// #496 1-a — 마지막으로 받은 layout group (`wl_keyboard.modifiers` 의 `group`).
    /// **라틴 fallback 판정이 이 값을 봐야 한다** — 매처는 활성 group 이 내는 keysym 만
    /// 보기 때문이다. 처음엔 모든 group 을 훑었는데, 그러면 `us,ru` 사용자가 ru group
    /// 으로 전환했을 때 "us group 이 `w` 를 낼 수 있다" 는 이유로 fallback 을 만들지
    /// 않아 단축키가 죽었다 (실측: group1 에서 `sym@KeyW=0x6c3` 인데
    /// `canProduceKeysym('w')` 가 true 였다).
    active_group: u32 = 0,
    api: ?Api = null,
    context: ?*xkb_context = null,
    keymap: ?*xkb_keymap = null,
    state: ?*xkb_state = null,
    /// #494 — Compose. `setComposeLocale` 이 만든다. **keymap 이 바뀌어도 그대로 둔다** —
    /// 표는 layout 이 아니라 locale 의 것이고, 조합 중 상태가 layout 전환에 끊길 이유도 없다.
    compose_table: ?*xkb_compose_table = null,
    compose_state: ?*xkb_compose_state = null,
    /// #533 — consumed mask 를 해석할 modifier index. keymap 마다 다르므로
    /// `setKeymap` 에서 다시 구한다.
    mod_index: ModIndex = .{},

    /// #533 — keymap 안에서 각 modifier 가 몇 번째 비트인가. `XKB_MOD_INVALID` 는
    /// 그 이름이 이 keymap 에 없다는 뜻이라 판정에서 빠진다.
    pub const ModIndex = struct {
        shift: c_uint = XKB_MOD_INVALID,
        ctrl: c_uint = XKB_MOD_INVALID,
        alt: c_uint = XKB_MOD_INVALID,
        super: c_uint = XKB_MOD_INVALID,
    };

    /// #533 — 이 키가 문자를 만드는 데 **쓴** modifier. 여기 표시된 것은 인코더가
    /// 다시 세지 않는다 (AltGr 로 낸 `~` 앞에 ESC 가 붙지 않는 이유).
    pub const ConsumedMods = struct {
        shift: bool = false,
        ctrl: bool = false,
        alt: bool = false,
        super: bool = false,
    };

    pub fn deinit(self: *Keyboard) void {
        self.clearKeymap();
        self.clearCompose();
        if (self.api) |*api| {
            if (self.context) |context| {
                api.context_unref(context);
                self.context = null;
            }
            api.deinit();
            self.api = null;
        }
    }

    pub fn setKeymap(self: *Keyboard, allocator: std.mem.Allocator, text: []const u8) !void {
        try self.ensureApi();
        const api = &self.api.?;

        if (self.context == null) {
            self.context = api.context_new(XKB_CONTEXT_NO_FLAGS) orelse return error.XkbContextCreateFailed;
        }

        const keymap_text = try allocator.dupeZ(u8, text);
        defer allocator.free(keymap_text);

        const keymap = api.keymap_new_from_string(
            self.context.?,
            keymap_text.ptr,
            XKB_KEYMAP_FORMAT_TEXT_V1,
            XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse return error.XkbKeymapCreateFailed;
        errdefer api.keymap_unref(keymap);

        const state = api.state_new(keymap) orelse return error.XkbStateCreateFailed;
        errdefer api.state_unref(state);

        self.clearKeymap();
        self.keymap = keymap;
        self.state = state;
        self.mod_index = if (api.consumed) |consumed| .{
            .shift = consumed.mod_get_index(keymap, "Shift"),
            .ctrl = consumed.mod_get_index(keymap, "Control"),
            // `altActive` 와 같은 이름을 쓴다 — xkb 의 Alt 는 `Mod1`, Super 는 `Mod4` 다.
            .alt = consumed.mod_get_index(keymap, "Mod1"),
            .super = consumed.mod_get_index(keymap, "Mod4"),
        } else .{};
    }

    pub fn updateMask(
        self: *Keyboard,
        depressed_mods: u32,
        latched_mods: u32,
        locked_mods: u32,
        group: u32,
    ) void {
        // #496 1-a — 판정이 활성 group 을 봐야 하므로 기억한다. keymap 이 없어 아래에서
        // 돌아가더라도 값은 남긴다 — 다음 keymap 이 오면 그 group 으로 판정한다.
        self.active_group = group;
        const api = if (self.api) |*api| api else return;
        const state = self.state orelse return;
        _ = api.state_update_mask(
            state,
            @intCast(depressed_mods),
            @intCast(latched_mods),
            @intCast(locked_mods),
            0,
            0,
            @intCast(group),
        );
    }

    /// #496 1-a — **활성 layout group 의 어느 키라도 이 keysym 을 낼 수 있는가.**
    ///
    /// **group 을 전수로 훑지 않는다.** 매처는 활성 group 이 내는 keysym 만 보므로
    /// 판정도 같은 group 을 봐야 한다. 처음엔 모든 group 을 훑었고, 그래서 `us,ru`
    /// 사용자가 ru group 으로 전환하면 — 도착하는 것은 `Cyrillic_tse` 인데 "us group
    /// 이 `w` 를 낼 수 있다" 는 이유로 fallback 을 만들지 않아 — 단축키가 죽었다.
    /// 비라틴 사용자의 **가장 흔한 설정**이 그것이라 정작 다수 사례를 놓쳤다.
    ///
    /// level 은 전수로 훑는다. modifier 상태를 보지 않는 것이 요점이다 — "Shift 를
    /// 눌러야 나오는 문자" 도 *낼 수 있는* 것으로 세야 한다.
    ///
    /// null = 판정할 수 없다 (libxkbcommon 이 필요한 심볼을 안 내주거나 keymap 이
    /// 없다). **false 와 구분해야 한다** — 판정 불가일 때 "낼 수 없다" 로 읽으면
    /// 없어도 되는 fallback 을 만들어 동작을 넓힌다.
    /// #496 1-b — **활성 group 에서 이 keysym 을 내는 물리 키의 evdev keycode.**
    ///
    /// 전역 핫키를 위치로 등록할 때 쓴다 (sway `bindcode`). 반환값은 **evdev** 이고,
    /// compositor 에 넘길 때 `+ 8` 을 해야 한다 — sway 와 Hyprland 둘 다 xkb keycode
    /// (= evdev + 8) 를 받는다 (sway 2018 커밋 *"Use XKB keycode numbering for
    /// bindcode"*, Hyprland `// "code:NN" binds store the xkb keycode`). 그 둘은
    /// 잘못된 숫자를 거부하지 않으므로 off-by-8 이면 조용히 옆 키에 붙는다.
    ///
    /// null = 못 찾았거나 판정할 수 없다. 호출자가 US 위치표로 떨어지거나 keysym 등록을
    /// 유지한다.
    pub fn evdevKeycodeForKeysym(self: *Keyboard, keysym: u32) ?u16 {
        const xkb_code = self.findKeycode(keysym) orelse return null;
        // xkb keycode 는 evdev + 8 이다. 8 미만은 나올 수 없지만 방어한다.
        if (xkb_code < 8) return null;
        return @intCast(xkb_code - 8);
    }

    /// 활성 group 에서 `keysym` 을 내는 첫 xkb keycode. `canProduceKeysym` 과
    /// `evdevKeycodeForKeysym` 이 같은 순회를 쓰게 한다 — 둘이 갈라지면 "닿는다고
    /// 했는데 keycode 는 못 찾는" 모순이 생긴다.
    fn findKeycode(self: *Keyboard, keysym: u32) ?c_uint {
        const api = if (self.api) |*a| a else return null;
        const scan = api.keymap_scan orelse return null;
        const keymap = self.keymap orelse return null;

        const min = scan.min_keycode(keymap);
        const max = scan.max_keycode(keymap);
        var key: c_uint = min;
        while (key <= max) : (key += 1) {
            const layouts = scan.num_layouts_for_key(keymap, key);
            if (layouts == 0) continue;
            // xkb 규칙 — 그 키의 layout 수보다 group 이 크면 wrap 한다. 키마다 layout
            // 수가 다를 수 있어 (`num_layouts_for_key` 가 키별이다) 나눗셈이 필요하다.
            const layout: c_uint = @intCast(self.active_group % layouts);
            const levels = scan.num_levels_for_key(keymap, key, layout);
            var level: c_uint = 0;
            while (level < levels) : (level += 1) {
                var syms: [*]const c_uint = undefined;
                const count = scan.key_get_syms_by_level(keymap, key, layout, level, &syms);
                if (count <= 0) continue;
                for (syms[0..@intCast(count)]) |sym| {
                    if (sym == keysym) return key;
                }
            }
        }
        return null;
    }

    pub fn canProduceKeysym(self: *Keyboard, keysym: u32) ?bool {
        // 판정 불가 (심볼 / keymap 없음) 와 "못 찾았다" 를 갈라야 한다.
        if (self.api == null) return null;
        if (self.api.?.keymap_scan == null) return null;
        if (self.keymap == null) return null;
        return self.findKeycode(keysym) != null;
    }

    /// #496 1-c — 그 **자리**가 지금 layout 에서 내는 keysym (level 0).
    /// `findKeycode` 의 반대 방향이고 group 규칙도 같다 (`active_group % layouts`).
    ///
    /// **level 0 만 본다.** 전역 hotkey 의 modifier 는 따로 실려 가므로 (`Ctrl+Shift+T`
    /// 가 keysym `t` + Shift 비트로 등록된다) 우리가 알아야 하는 것은 그 자리의 *기본*
    /// 문자다. Shift 레벨을 뽑으면 `Ctrl+Shift+[Digit1]` 이 `!` 로 등록돼 어긋난다.
    ///
    /// **`oneSym` 을 쓰지 않는 이유** — 그쪽은 `xkb_state` 를 보므로 *지금 눌려 있는*
    /// modifier 가 결과를 바꾼다. 등록은 부팅 · layout 전환 시점에 일어나 대개 아무 키도
    /// 안 눌려 있지만, 그 우연에 기대면 사용자가 키를 누른 채 layout 을 바꿀 때 조용히
    /// 다른 값이 등록된다.
    ///
    /// 판정 불가 (심볼 / keymap 없음) 와 "그 자리에 keysym 이 없다" 를 **가르지 않는다**
    /// — 호출부의 처리가 같기 때문이다 (등록하지 않고 알린다). 1-a 에서 둘을 가른 것은
    /// 거기서는 결과가 달랐기 때문이다 (fallback 을 만드느냐 마느냐).
    pub fn keysymAtEvdev(self: *Keyboard, evdev: u16) ?u32 {
        const api = if (self.api) |*a| a else return null;
        const scan = api.keymap_scan orelse return null;
        const keymap = self.keymap orelse return null;

        const key: c_uint = @as(c_uint, evdev) + 8; // xkb keycode = evdev + 8
        if (key < scan.min_keycode(keymap) or key > scan.max_keycode(keymap)) return null;
        const layouts = scan.num_layouts_for_key(keymap, key);
        if (layouts == 0) return null;
        const layout: c_uint = @intCast(self.active_group % layouts);
        var syms: [*]const c_uint = undefined;
        const count = scan.key_get_syms_by_level(keymap, key, layout, 0, &syms);
        if (count <= 0) return null;
        return @intCast(syms[0]);
    }

    /// #496 1-c — keysym → xkb 이름 (`twosuperior` · `Cyrillic_io` · `grave`).
    /// COSMIC RON 의 `key:` 가 이 이름을 받는다. 버퍼에 담아 slice 로 돌려준다.
    /// #513 — 지금 keymap 이 담고 있는 layout 이름들을 `", "` 로 이어 돌려준다
    /// (`"English (US), Korean"`). 심볼이 없거나 keymap 이 없으면 `null`.
    ///
    /// **어느 keymap 을 받았는지가 곧 판정 근거다.** 위치 표기 hotkey 가 엉뚱한 글자로
    /// 등록될 때, 이 이름이 직전 layout 이면 compositor 가 옛 keymap 을 보낸 것이고 지금
    /// layout 이면 우리 쪽 처리가 틀린 것이다.
    pub fn layoutNames(self: *Keyboard, buf: []u8) ?[]const u8 {
        const api = self.api orelse return null;
        const names = api.layout_names orelse return null;
        const keymap = self.keymap orelse return null;
        const count = names.num_layouts(keymap);
        var out: usize = 0;
        var layout: c_uint = 0;
        while (layout < count) : (layout += 1) {
            const name = names.layout_get_name(keymap, layout) orelse continue;
            const text = std.mem.span(name);
            const separator: []const u8 = if (out == 0) "" else ", ";
            // 버퍼가 모자라면 거기서 끊는다 — 진단 줄이라 자르는 편이 낫다.
            if (out + separator.len + text.len > buf.len) break;
            @memcpy(buf[out..][0..separator.len], separator);
            out += separator.len;
            @memcpy(buf[out..][0..text.len], text);
            out += text.len;
        }
        return buf[0..out];
    }

    pub fn keysymName(self: *Keyboard, keysym: u32, buf: []u8) ?[]const u8 {
        const api = if (self.api) |*a| a else return null;
        const scan = api.keymap_scan orelse return null;
        const n = scan.keysym_get_name(@intCast(keysym), buf.ptr, buf.len);
        if (n <= 0) return null;
        const len: usize = @intCast(n);
        // 버퍼가 모자라면 필요한 길이를 돌려준다 — 잘린 이름을 쓰면 COSMIC 이 못 읽는
        // 값을 파일에 남기게 되므로 실패로 다룬다.
        if (len >= buf.len) return null;
        return buf[0..len];
    }

    /// #496 1-c — keysym 이 내는 유니코드 코드포인트. 문자를 안 내면 null.
    pub fn keysymToUtf32(self: *Keyboard, keysym: u32) ?u21 {
        const api = if (self.api) |*a| a else return null;
        const scan = api.keymap_scan orelse return null;
        const cp = scan.keysym_to_utf32(@intCast(keysym));
        if (cp == 0 or cp > 0x10ffff) return null;
        return @intCast(cp);
    }

    pub fn oneSym(self: *Keyboard, key: u32) ?u32 {
        const api = if (self.api) |*api| api else return null;
        const state = self.state orelse return null;
        return api.state_key_get_one_sym(state, @intCast(key));
    }

    pub fn utf8(self: *Keyboard, key: u32, buf: []u8) []const u8 {
        if (buf.len == 0) return "";
        const api = if (self.api) |*api| api else return "";
        const state = self.state orelse return "";
        const n = api.state_key_get_utf8(state, @intCast(key), buf.ptr, buf.len);
        if (n <= 0) return "";
        const wanted: usize = @intCast(n);
        if (wanted >= buf.len) return "";
        return buf[0..wanted];
    }

    /// #494 — `setComposeLocale` 의 결과. 호출자가 로그 한 줄로 남긴다.
    pub const ComposeSetup = enum {
        /// 요청한 locale 의 Compose 표가 올라갔다 (이미 올라가 있던 경우도 포함).
        ready,
        /// 요청한 locale 에는 표가 없어 `en_US.UTF-8` 로 올라갔다.
        fallback_locale,
        /// 둘 다 실패 — dead key 는 지금처럼 조합되지 않는다.
        unavailable,
        /// libxkbcommon 이 compose 심볼을 내주지 않거나 아직 context 가 없다.
        no_symbols,
    };

    /// #494 — 이 locale 의 Compose 표를 올린다. 호출 시점은 **첫 keymap 이 온 뒤**다 —
    /// `xkb_context` 가 그때 생긴다. 이미 올라가 있으면 다시 만들지 않는다.
    ///
    /// `locale` 이 가리키는 Compose 파일이 없으면 (`C` · compose.dir 에 없는 locale) `en_US.UTF-8`
    /// 로 한 번 더 시도한다. X11 의 `compose.dir` 에서 거의 모든 UTF-8 locale 이 그 파일을
    /// 가리킨다. libxkbcommon 1.12+ 도 fallback 을 하지만 **C 라이브러리가 아는 locale 에만**
    /// 이다 — 실측 (lima VM · 1.13.1) 에서 설치되지 않은 `xx_XX.UTF-8` 은 `XKB-679` 에러와 함께
    /// `NULL` 을 냈고, 이 재시도가 있어야 조합이 살았다.
    pub fn setComposeLocale(self: *Keyboard, locale: [:0]const u8) ComposeSetup {
        const api = if (self.api) |*a| a else return .no_symbols;
        const compose = api.compose orelse return .no_symbols;
        const context = self.context orelse return .no_symbols;
        if (self.compose_state != null) return .ready;

        var setup: ComposeSetup = .ready;
        var table = compose.table_new_from_locale(context, locale.ptr, XKB_COMPOSE_COMPILE_NO_FLAGS);
        if (table == null) {
            table = compose.table_new_from_locale(context, "en_US.UTF-8", XKB_COMPOSE_COMPILE_NO_FLAGS);
            setup = .fallback_locale;
        }
        const table_ptr = table orelse return .unavailable;
        const state = compose.state_new(table_ptr, XKB_COMPOSE_STATE_NO_FLAGS) orelse {
            compose.table_unref(table_ptr);
            return .unavailable;
        };
        self.compose_table = table_ptr;
        self.compose_state = state;
        return setup;
    }

    /// #494 — `composeFeed` 의 결과. #530 — `composing` 과 `cancelled` 를 가른다 (둘 다 PTY 로는
    /// 아무것도 안 가지만 화면 표시는 반대다 — 전자는 그리고 후자는 지운다).
    pub const ComposeResult = union(enum) {
        /// compose 가 없거나 이 keysym 이 시퀀스와 무관하다 (modifier 키 포함) — 호출자가 기존
        /// utf8 경로로 간다. 조합 중 표시가 있었다면 그대로 둔다 — modifier 키는 상태를 안 바꾼다.
        passthrough,
        /// 조합 중 (`COMPOSING`) — 아무것도 보내지 않고, 이 keysym 을 화면 표시에 덧붙인다.
        composing,
        /// 조합이 깨졌다 (`CANCELLED`) — 아무것도 보내지 않고 표시를 지운다.
        cancelled,
        /// 조합이 끝났다 — 표시를 지우고 이 바이트를 보낸다. `buf` 안을 가리킨다.
        composed: []const u8,
    };

    /// #494 — 눌린 키의 keysym 을 Compose 상태 기계에 먹이고 무엇을 할지 돌려준다.
    /// 호출자는 **글자가 될 키만** 넘긴다 — 단축키 · nav 키 · Ctrl/Alt 조합은 넘기지 않는다
    /// (`wayland_minimal.zig` `processKeyEvent` 의 주석).
    pub fn composeFeed(self: *Keyboard, keysym: u32, buf: []u8) ComposeResult {
        const api = if (self.api) |*a| a else return .passthrough;
        const compose = api.compose orelse return .passthrough;
        const state = self.compose_state orelse return .passthrough;
        const fed = compose.state_feed(state, @intCast(keysym));
        const status = compose.state_get_status(state);
        switch (composeDecision(fed, status)) {
            .passthrough => return .passthrough,
            .composing => return .composing,
            .cancelled => return .cancelled,
            .composed => {
                const n = compose.state_get_utf8(state, buf.ptr, buf.len);
                if (n <= 0) return .cancelled;
                const len: usize = @intCast(n);
                // 버퍼가 모자라면 (libxkbcommon 은 필요한 길이를 돌려준다) 잘린 글자를 보내는
                // 대신 버린다. 64 바이트면 Compose 표의 어떤 결과도 담긴다.
                if (len >= buf.len) return .cancelled;
                return .{ .composed = buf[0..len] };
            },
        }
    }

    /// #494 — 조합 중이던 것을 버린다. compose 를 거치지 않은 키 (단축키 · Enter · Ctrl 조합 ·
    /// IME preedit 중의 키) 가 끼면 호출자가 부른다 — 그 뒤에 예상 못 한 `ê` 가 튀어나오지 않게.
    pub fn composeReset(self: *Keyboard) void {
        const api = if (self.api) |*a| a else return;
        const compose = api.compose orelse return;
        const state = self.compose_state orelse return;
        compose.state_reset(state);
    }

    pub const ComposeDecision = enum { passthrough, composing, cancelled, composed };

    /// #494 — feed 결과와 상태를 동작으로 옮기는 표. 순수 함수라 libxkbcommon 없이 테스트한다.
    ///
    /// | feed | status | 동작 | 뜻 |
    /// |---|---|---|---|
    /// | IGNORED | (무엇이든) | passthrough | modifier 키 같은 무시 keysym — 상태가 안 바뀌었다 |
    /// | ACCEPTED | NOTHING | passthrough | 시퀀스 시작이 아니다 — 보통 글자, 기존 utf8 경로 |
    /// | ACCEPTED | COMPOSING | composing | 시퀀스 진행 중 (`^` 를 누른 직후) — 화면 표시에 덧붙인다 (#530) |
    /// | ACCEPTED | COMPOSED | composed | 끝났다 — 표시를 지우고 `get_utf8` 결과를 보낸다 |
    /// | ACCEPTED | CANCELLED | cancelled | 이어지지 않는 키 (`^` 다음 `x`) — X11 · xterm 관례대로 둘 다 버리고 표시를 지운다 |
    ///
    /// `CANCELLED` 에서 GTK 만 `^x` 처럼 둘 다 내는데, 그건 Compose 표 밖의 별도 규칙이라
    /// 넣지 않는다. 다음 feed 는 헤더 문서대로 `NOTHING` 과 같이 새 시퀀스 판정을 시작한다.
    fn composeDecision(fed: c_int, status: c_int) ComposeDecision {
        if (fed == XKB_COMPOSE_FEED_IGNORED) return .passthrough;
        return switch (status) {
            XKB_COMPOSE_NOTHING => .passthrough,
            XKB_COMPOSE_COMPOSING => .composing,
            XKB_COMPOSE_COMPOSED => .composed,
            XKB_COMPOSE_CANCELLED => .cancelled,
            // 모르는 상태값 — 헤더에 없는 값이 오면 글자를 삼키는 쪽보다 보내는 쪽이 낫다.
            else => .passthrough,
        };
    }

    /// #530 — 조합 중인 dead key 를 화면에 보여 줄 문자. dead keysym 은 유니코드가 없어서
    /// (`xkb_keysym_to_utf32` 가 0) 표시용 표가 필요하다. **GTK 의 표를 그대로 따른다**
    /// (`gtkimcontextsimple.c` `append_dead_key`) — 같은 데스크톱의 GTK · Qt 앱이 보여 주는
    /// 것과 같아야 한다. macOS 는 `ˆ` (U+02C6) 계열을 쓰지만 platform native 가 우선이다.
    ///
    /// GTK 가 spacing 대응이 없어 NBSP + 결합 문자로 근사하는 항목 (`abovedot` · `belowdot` ·
    /// `horn` · `stroke` …) 은 **null** — 우리 셀 렌더는 결합 문자 (폭 0) 를 그리지 않아 빈 칸만
    /// 남는다. 조합 자체는 그대로 된다. `Multi_key` 도 null (GTK 도 표시하지 않는다).
    pub fn deadKeyPreview(keysym: u32) ?u21 {
        return switch (keysym) {
            0xfe50 => 0x60, // dead_grave → `
            0xfe51 => 0xb4, // dead_acute → ´
            0xfe52 => 0x5e, // dead_circumflex → ^
            0xfe53 => 0x7e, // dead_tilde (= dead_perispomeni) → ~
            0xfe54 => 0xaf, // dead_macron → ¯
            0xfe55 => 0x2d8, // dead_breve → ˘
            0xfe57 => 0xa8, // dead_diaeresis → ¨
            0xfe58 => 0x2da, // dead_abovering → ˚
            0xfe59 => 0x2dd, // dead_doubleacute → ˝
            0xfe5a => 0x2c7, // dead_caron → ˇ
            0xfe5b => 0xb8, // dead_cedilla → ¸
            0xfe5c => 0x2db, // dead_ogonek → ˛
            0xfe5d => 0x37a, // dead_iota → ͺ
            0xfe61 => 0x2c0, // dead_hook → ˀ
            0xfe64 => 0x2bc, // dead_abovecomma (= dead_psili) → ʼ
            0xfe67 => 0x2f3, // dead_belowring → ˳
            0xfe68 => 0x2cd, // dead_belowmacron → ˍ
            0xfe8d => 0x621, // dead_hamza → ء
            0xfe90 => 0x5f, // dead_lowline → _
            0xfe91 => 0x2c8, // dead_aboveverticalline → ˈ
            0xfe92 => 0x2cc, // dead_belowverticalline → ˌ
            else => null,
        };
    }

    pub fn ctrlActive(self: *Keyboard) bool {
        return self.modActive("Control");
    }

    pub fn shiftActive(self: *Keyboard) bool {
        return self.modActive("Shift");
    }

    /// xkb 의 Alt = "Mod1" (Linux 표준 — `XKB_MOD_NAME_ALT` 의 underlying name).
    /// SPEC.md §2.2 — Alt+1..9 탭 인덱스 점프 (Win 동등) 등에 사용.
    pub fn altActive(self: *Keyboard) bool {
        return self.modActive("Mod1");
    }

    pub fn superActive(self: *Keyboard) bool {
        return self.modActive("Mod4");
    }

    /// #533 — 이 키가 문자를 만드는 데 쓴 modifier. 조회 심볼이 없거나 keymap 이
    /// 아직 없으면 전부 `false` 다 — 그때는 인코더가 modifier 를 그대로 세므로,
    /// 판정이 없는 쪽이 아니라 **보수적으로 틀리는** 쪽임을 알고 쓴다.
    pub fn consumedMods(self: *Keyboard, key: u32) ConsumedMods {
        const api = if (self.api) |*api| api else return .{};
        const consumed = api.consumed orelse return .{};
        const state = self.state orelse return .{};
        const mask = consumed.key_get_consumed_mods2(state, @intCast(key), XKB_CONSUMED_MODE_GTK);
        return .{
            .shift = maskHasMod(mask, self.mod_index.shift),
            .ctrl = maskHasMod(mask, self.mod_index.ctrl),
            .alt = maskHasMod(mask, self.mod_index.alt),
            .super = maskHasMod(mask, self.mod_index.super),
        };
    }

    fn maskHasMod(mask: u32, index: c_uint) bool {
        // `XKB_MOD_INVALID` 뿐 아니라 32 이상도 걸러야 한다 — mask 가 u32 라
        // 그대로 shift 하면 정의되지 않은 동작이다.
        if (index >= 32) return false;
        return (mask & (@as(u32, 1) << @intCast(index))) != 0;
    }

    fn modActive(self: *Keyboard, comptime name: [:0]const u8) bool {
        const api = if (self.api) |*api| api else return false;
        const state = self.state orelse return false;
        return api.state_mod_name_is_active(state, name.ptr, XKB_STATE_MODS_EFFECTIVE) > 0;
    }

    fn ensureApi(self: *Keyboard) !void {
        if (self.api != null) return;
        self.api = Api.load() catch |err| {
            log.appendLine("wayland", "libxkbcommon load failed: {s}", .{@errorName(err)});
            return error.XkbUnavailable;
        };
    }

    fn clearKeymap(self: *Keyboard) void {
        if (self.api) |*api| {
            if (self.state) |state| {
                api.state_unref(state);
                self.state = null;
            }
            if (self.keymap) |keymap| {
                api.keymap_unref(keymap);
                self.keymap = null;
            }
        }
        self.mod_index = .{};
    }

    fn clearCompose(self: *Keyboard) void {
        const api = if (self.api) |*a| a else return;
        const compose = api.compose orelse return;
        if (self.compose_state) |state| {
            compose.state_unref(state);
            self.compose_state = null;
        }
        if (self.compose_table) |table| {
            compose.table_unref(table);
            self.compose_table = null;
        }
    }
};

test "#494 composeDecision — feed 결과 × 상태 → 동작 표" {
    const D = Keyboard.ComposeDecision;
    // modifier 키처럼 무시된 keysym 은 상태를 안 바꿨으니 그대로 지나간다 — 상태값과 무관하다.
    try std.testing.expectEqual(D.passthrough, Keyboard.composeDecision(XKB_COMPOSE_FEED_IGNORED, XKB_COMPOSE_NOTHING));
    try std.testing.expectEqual(D.passthrough, Keyboard.composeDecision(XKB_COMPOSE_FEED_IGNORED, XKB_COMPOSE_COMPOSING));
    // 보통 글자 — 시퀀스 시작이 아니다.
    try std.testing.expectEqual(D.passthrough, Keyboard.composeDecision(XKB_COMPOSE_FEED_ACCEPTED, XKB_COMPOSE_NOTHING));
    // `^` 를 누른 직후 — 아무것도 보내지 않고 화면에 `^` 를 보여 준다 (#530).
    try std.testing.expectEqual(D.composing, Keyboard.composeDecision(XKB_COMPOSE_FEED_ACCEPTED, XKB_COMPOSE_COMPOSING));
    // `^` 다음 `e` — 결과 (`ê`) 를 보낸다.
    try std.testing.expectEqual(D.composed, Keyboard.composeDecision(XKB_COMPOSE_FEED_ACCEPTED, XKB_COMPOSE_COMPOSED));
    // `^` 다음 `x` — 이어지는 시퀀스가 없다. 둘 다 버리고 표시도 지운다 (X11 · xterm 관례).
    try std.testing.expectEqual(D.cancelled, Keyboard.composeDecision(XKB_COMPOSE_FEED_ACCEPTED, XKB_COMPOSE_CANCELLED));
    // 헤더에 없는 상태값 — 삼키지 않는다.
    try std.testing.expectEqual(D.passthrough, Keyboard.composeDecision(XKB_COMPOSE_FEED_ACCEPTED, 99));
}

test "#494 compose 가 없으면 전부 passthrough — 키보드는 지금처럼 동작한다" {
    // libxkbcommon 이 없거나 (이 테스트 환경) compose 심볼이 없으면 `composeFeed` 는 항상
    // passthrough 라 호출자가 기존 `utf8()` 경로를 탄다. 삼키면 글자가 사라진다.
    var kb: Keyboard = .{};
    defer kb.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(Keyboard.ComposeResult.passthrough, kb.composeFeed(0xfe52, &buf));
    try std.testing.expectEqual(Keyboard.ComposeSetup.no_symbols, kb.setComposeLocale("fr_FR.UTF-8"));
    // reset 도 아무 일 없이 돌아온다.
    kb.composeReset();
    try std.testing.expectEqual(@as(?*xkb_compose_state, null), kb.compose_state);
}

test "#530 deadKeyPreview — GTK 표의 spacing 항목만, 나머지는 null" {
    // 프랑스어 · 독일어 · 스페인어 자판의 흔한 dead key 는 전부 표시가 있다.
    try std.testing.expectEqual(@as(?u21, '^'), Keyboard.deadKeyPreview(0xfe52)); // dead_circumflex
    try std.testing.expectEqual(@as(?u21, 0xa8), Keyboard.deadKeyPreview(0xfe57)); // dead_diaeresis
    try std.testing.expectEqual(@as(?u21, '`'), Keyboard.deadKeyPreview(0xfe50)); // dead_grave
    try std.testing.expectEqual(@as(?u21, 0xb4), Keyboard.deadKeyPreview(0xfe51)); // dead_acute
    try std.testing.expectEqual(@as(?u21, '~'), Keyboard.deadKeyPreview(0xfe53)); // dead_tilde
    // GTK 가 NBSP + 결합 문자로 근사하는 항목은 표시하지 않는다 — 결합 문자는 셀에 안 그려진다.
    try std.testing.expectEqual(@as(?u21, null), Keyboard.deadKeyPreview(0xfe56)); // dead_abovedot
    try std.testing.expectEqual(@as(?u21, null), Keyboard.deadKeyPreview(0xfe60)); // dead_belowdot
    // dead key 가 아닌 것 — Multi_key · 보통 글자.
    try std.testing.expectEqual(@as(?u21, null), Keyboard.deadKeyPreview(0xff20));
    try std.testing.expectEqual(@as(?u21, null), Keyboard.deadKeyPreview('e'));
}

test "#496 1-a canProduceKeysym 은 활성 group 만 본다 — 기본 group 은 0" {
    // 이 결함을 두 번 내지 않기 위한 못이다. keymap 이 없으면 판정 자체가 불가라
    // (`null`) 값 검사는 못 하지만, **`updateMask` 가 group 을 기억한다**는 계약은
    // 여기서 고정할 수 있다 — 그것이 group 인지 판정의 입력이다.
    var kb: Keyboard = .{};
    defer kb.deinit();
    try std.testing.expectEqual(@as(u32, 0), kb.active_group);
    // keymap / api 가 없어도 group 은 남는다 — 다음 keymap 이 그 group 으로 판정한다.
    kb.updateMask(0, 0, 0, 1);
    try std.testing.expectEqual(@as(u32, 1), kb.active_group);
    kb.updateMask(0, 0, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), kb.active_group);
}

test "#496 1-a canProduceKeysym — 판정 불가는 false 가 아니라 null 이다" {
    // keymap 이 없으면 (또는 libxkbcommon 이 조회 심볼을 안 내주면) **null 이다.**
    // false 로 주면 호출자가 "이 라벨은 낼 수 없다" 로 읽어 없어도 되는 라틴 fallback
    // 을 만들고, 그러면 라틴 자판에서 한 동작에 키가 둘 생긴다 (#496 1-a).
    var kb: Keyboard = .{};
    defer kb.deinit();
    try std.testing.expectEqual(@as(?bool, null), kb.canProduceKeysym('w'));
}

// 실측 확인 (2026-08-24, 이 개발 머신 · libxkbcommon.so.0). `xkbcli compile-keymap`
// 으로 뽑은 실제 keymap 을 넣어 확인한 값이다 — keymap 은 하나에 70 KB 대라 fixture
// 로 커밋하지 않았다.
//
// | layout · 활성 group | `w` 를 낼 수 있나 | US `w` 자리 (evdev 17) 가 내는 keysym |
// |---------------------|------------------|--------------------------------------|
// | `us`                | true             | `0x77` (`w`)                          |
// | `ru`                | **false**        | `0x6c3` (`Cyrillic_tse`)              |
// | `us,ru` · group 0   | true             | `0x77`                                |
// | `us,ru` · group 1   | **false**        | `0x6c3`                               |
//
// **마지막 줄이 이 함수를 다시 쓴 이유다.** 처음 구현은 group 을 전수로 훑어서
// `us,ru` · group 1 에서도 `true` 를 냈다 — 도착하는 것은 `Cyrillic_tse` 인데
// fallback 을 만들지 않아 단축키가 죽었다. 비라틴 사용자의 가장 흔한 설정이 그것이라
// 정작 다수 사례를 놓쳤다.
//
// 나머지 줄이 보여 주는 것:
//
//   - `ru` 단독 → 라벨이 닿지 않으므로 fallback 이 생기고 글자 단축키가 살아난다.
//   - `us,ru` · group 0 → `w` 가 닿으므로 fallback 이 생기지 않고, 라벨 매칭이 그대로
//     맞는다. group 을 전환하면 `wl_keyboard.modifiers` 가 오고 다시 푼다.
//   - 도착하는 keysym 이 Unicode 형 (`0x01000426`) 이 아니라 **이름 있는 Cyrillic
//     keysym** (`0x6c3`) 이다. xkb 의 `ru` 는 Cyrillic 블록 keysym 을 쓴다.
