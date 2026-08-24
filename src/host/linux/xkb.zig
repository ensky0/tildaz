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

const XKB_CONTEXT_NO_FLAGS: c_uint = 0;
const XKB_KEYMAP_FORMAT_TEXT_V1: c_uint = 1;
const XKB_KEYMAP_COMPILE_NO_FLAGS: c_uint = 0;

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
        };
    }

    fn deinit(self: *Api) void {
        _ = std.c.dlclose(self.handle);
    }
};

/// #496 1-a — keymap 전수 조회에 필요한 심볼 묶음. **다 있어야 의미가 있으므로 묶어서
/// all-or-nothing 으로 다룬다** — 넷만 있으면 부분 조회가 되어 오히려 잘못된 답을 낸다.
const KeymapScan = struct {
    min_keycode: XkbKeymapMinKeycode,
    max_keycode: XkbKeymapMaxKeycode,
    num_layouts_for_key: XkbKeymapNumLayoutsForKey,
    num_levels_for_key: XkbKeymapNumLevelsForKey,
    key_get_syms_by_level: XkbKeymapKeyGetSymsByLevel,

    fn load(handle: *anyopaque) ?KeymapScan {
        return .{
            .min_keycode = lookup(handle, XkbKeymapMinKeycode, "xkb_keymap_min_keycode") orelse return null,
            .max_keycode = lookup(handle, XkbKeymapMaxKeycode, "xkb_keymap_max_keycode") orelse return null,
            .num_layouts_for_key = lookup(handle, XkbKeymapNumLayoutsForKey, "xkb_keymap_num_layouts_for_key") orelse return null,
            .num_levels_for_key = lookup(handle, XkbKeymapNumLevelsForKey, "xkb_keymap_num_levels_for_key") orelse return null,
            .key_get_syms_by_level = lookup(handle, XkbKeymapKeyGetSymsByLevel, "xkb_keymap_key_get_syms_by_level") orelse return null,
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

    pub fn deinit(self: *Keyboard) void {
        self.clearKeymap();
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
    }
};

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
