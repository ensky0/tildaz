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

// #513 — 진단용. **받은 keymap 이 어느 layout 인지**를 로그에 남긴다. COSMIC 에서
// 키보드를 꽂으면 위치 표기 hotkey 가 직전 layout 의 글자로 재등록되는데, 로그만으로는
// *compositor 가 옛 keymap 을 보낸 것*인지 *우리가 잘못 읽은 것*인지 구분할 수 없었다
// ([#513](https://github.com/ensky0/tildaz/issues/513)).
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
