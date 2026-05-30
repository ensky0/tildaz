//! Minimal Wayland wire client for the first Linux window milestone.
//!
//! This intentionally avoids linking `libwayland-client` so macOS-hosted Linux
//! cross builds keep working while the Linux backend is still young. It only
//! implements the tiny subset needed to create an `xdg-shell` toplevel with one
//! shared-memory color buffer.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const session_core = @import("../../session_core.zig");
const terminal_backend = @import("../../terminal.zig");
const terminal_interaction = @import("../../terminal_interaction.zig");
const tab_interaction = @import("../../tab_interaction.zig");
const tab_actions = @import("../../tab_actions.zig");
const tab_layout = @import("../../tab_layout.zig");
const display_width = @import("../../font/display_width.zig");
const ui_metrics = @import("../../ui_metrics.zig");
const app_event = @import("../../app_event.zig");
const themes = @import("../../themes.zig");
const log = @import("../../log.zig");
const messages = @import("../../messages.zig");
const config_mod = @import("../../config.zig");
const software_terminal = @import("software_terminal.zig");
const xkb = @import("xkb.zig");
const dbus = @import("dbus.zig");
const portal = @import("portal.zig");
const single_instance = @import("single_instance.zig");
const about = @import("../../about.zig");
const paths = @import("../../paths.zig");
const system_open = @import("../../system_open.zig");
const dialog_mod = @import("../../dialog.zig");
const dialog_linux = @import("../../dialog/linux.zig");

const display_id: u32 = 1;
const registry_id: u32 = 2;
const first_client_alloc_id: u32 = registry_id + 1;

const shm_format_argb8888: u32 = 0;
const shm_format_xrgb8888: u32 = 1;
const default_width: i32 = 640;
const default_height: i32 = 420;
const min_width: i32 = 160;
const min_height: i32 = 120;
/// `config.theme` 가 disk 값 매핑 실패 등으로 null 일 때 fallback. themes
/// 모듈의 첫 entry (= "Tilda" 기본 테마). L13-α 이전엔 항상 이 값을 사용했다.
const fallback_theme = &themes.themes[0];
const frame_poll_ms: i32 = 16;
const max_buffers_per_size: usize = 2;
const wl_seat_capability_pointer: u32 = 1;
const wl_seat_capability_keyboard: u32 = 2;
const wl_keyboard_keymap_format_xkb_v1: u32 = 1;
const wl_keyboard_key_state_pressed: u32 = 1;
const wl_keyboard_key_state_repeated: u32 = 2;
const wayland_xkb_keycode_offset: u32 = 8;

// Linux input-event-codes BTN_LEFT.
const wl_pointer_button_left: u32 = 0x110;
const wl_pointer_button_state_released: u32 = 0;
const wl_pointer_button_state_pressed: u32 = 1;
const wl_pointer_axis_vertical: u32 = 0;

// wl_seat opcodes (request side, used by `get_pointer` / `get_keyboard`).
const wl_seat_request_get_pointer: u16 = 0;
const wl_seat_request_get_keyboard: u16 = 1;

// zwp_text_input_manager_v3 / zwp_text_input_v3 wire opcodes (v1 of unstable
// protocol — https://wayland.app/protocols/text-input-unstable-v3). Wire-level
// 직접 송수신이라 spec 의 zero-based 선언 순서가 그대로 opcode. v3 spec 은
// enable / disable / set_* state 가 double-buffered — 반드시 마지막에 commit()
// 으로 flush 해야 server 가 적용한다.
const text_input_manager_request_get_text_input: u16 = 1;
const text_input_request_destroy: u16 = 0;
const text_input_request_enable: u16 = 1;
const text_input_request_disable: u16 = 2;
const text_input_request_set_content_type: u16 = 5;
const text_input_request_set_cursor_rectangle: u16 = 6;
const text_input_request_commit: u16 = 7;
// content_hint / content_purpose enum 값 — text-input-unstable-v3 spec
// (wayland.app/protocols/text-input-unstable-v3). terminal purpose 가
// 우리 의도 ("일반 텍스트 입력 + 단축키 raw forward").
const text_input_content_hint_none: u32 = 0x0;
const text_input_content_purpose_terminal: u32 = 13;
const text_input_event_enter: u16 = 0;
const text_input_event_leave: u16 = 1;
const text_input_event_preedit_string: u16 = 2;
const text_input_event_commit_string: u16 = 3;
const text_input_event_delete_surrounding_text: u16 = 4;
const text_input_event_done: u16 = 5;
// wl_keyboard event opcodes — keymap=0 / enter=1 / leave=2 / key=3 / modifiers=4
// / repeat_info=5. 이전엔 enter/leave 무시했는데 L10-α 부터는 keyboard focus 가
// 토글되는 시점에 text input 의 enable / disable + commit 도 함께 트리거한다.
const wl_keyboard_event_keymap: u16 = 0;
const wl_keyboard_event_enter: u16 = 1;
const wl_keyboard_event_leave: u16 = 2;
const wl_keyboard_event_key: u16 = 3;
const wl_keyboard_event_modifiers: u16 = 4;
const wl_keyboard_event_repeat_info: u16 = 5;

// zwlr_layer_shell_v1 / zwlr_layer_surface_v1 wire opcodes (unstable v1 — 출처
// https://wayland.app/protocols/wlr-layer-shell-unstable-v1). L8-α 의 핵심
// protocol — Tilda-style drop-down 처럼 compositor 의 output edge 에 anchor
// 한 surface 를 만든다. xdg-shell toplevel 과는 별도 경로 — 둘 다 만들 필요는
// 없고, layer-shell 이 advertise 됐을 때만 layer-shell 경로 사용 (없으면
// xdg-shell fallback, Capability Strategy 표대로).
const zwlr_layer_shell_v1_request_get_layer_surface: u16 = 0;
const zwlr_layer_shell_v1_request_destroy: u16 = 1;
const zwlr_layer_surface_v1_request_set_size: u16 = 0;
const zwlr_layer_surface_v1_request_set_anchor: u16 = 1;
const zwlr_layer_surface_v1_request_set_exclusive_zone: u16 = 2;
const zwlr_layer_surface_v1_request_set_margin: u16 = 3;
const zwlr_layer_surface_v1_request_set_keyboard_interactivity: u16 = 4;
// opcode 5 = get_popup (set_layer 아님 — #205 진단 cycle 발견, 우리 코드 미사용)
const zwlr_layer_surface_v1_request_ack_configure: u16 = 6;
/// `set_layer` 는 since version 2. layer_shell version 1 환경에서 송신 시
/// protocol error → BrokenPipe. KWin Plasma 6 은 v4 이상 (안전).
const zwlr_layer_surface_v1_request_set_layer: u16 = 8;
const zwlr_layer_surface_v1_request_destroy: u16 = 7;
const zwlr_layer_surface_v1_event_configure: u16 = 0;
const zwlr_layer_surface_v1_event_closed: u16 = 1;
// layer enum: 0=background, 1=bottom, 2=top, 3=overlay. drop-down 은 normal
// window 위 / lock screen 아래 → top (2). overlay 면 panel / 알림 위까지 덮음.
const zwlr_layer_shell_layer_top: u32 = 2;
// #203 Phase C — 대화상자는 main surface (`top`) 위로 떠야 modal 가시화 보장.
// `overlay` 면 panel / 알림 위까지 덮어 native NSAlert / MessageBoxW 동등.
const zwlr_layer_shell_layer_overlay: u32 = 3;
// anchor bitmask. top+left+right (= 13) 이면 width 는 compositor 가 결정 (full
// 가로), height 만 set_size 값 사용 (spec: "anchored to opposing edges → 그
// axis 의 size 는 anchor 가 결정, set_size 무시").
const zwlr_layer_surface_anchor_top: u32 = 1;
const zwlr_layer_surface_anchor_bottom: u32 = 2;
const zwlr_layer_surface_anchor_left: u32 = 4;
const zwlr_layer_surface_anchor_right: u32 = 8;
// keyboard_interactivity. v1 spec 은 0/1 (none / exclusive — exclusive 면 모든
// keyboard event 가 우리 surface 로). drop-down 본분 — yakuake / guake 등 모든
// Linux drop-down terminal 의 표준. mac NSPopUpMenuWindowLevel / Win
// WS_EX_TOPMOST 의 *level toggle* z-order 양보 (#195) 는 layer-shell categorical
// (top / bottom / overlay / background) 이라 unavailable — Linux platform-limit.
const zwlr_layer_surface_keyboard_interactivity_exclusive: u32 = 1;
// 첫 set_size 의 fallback 높이. compositor 가 0 으로 답하면 (= "you decide")
// 이 값 사용. 보통은 screen 폭 + 우리 요청 height 를 그대로 돌려보냄.
const layer_surface_default_height: u32 = 400;
// wp_cursor_shape_v1 (#193) — compositor 가 themed cursor 직접 처리. wl_pointer
// 의 set_cursor + XCursor 테마 로딩 직접 구현 대안. KDE Plasma 6 / GNOME 등이
// advertise. 출처 https://wayland.app/protocols/cursor-shape-v1.
const wp_cursor_shape_manager_v1_request_destroy: u16 = 0;
const wp_cursor_shape_manager_v1_request_get_pointer: u16 = 1;
const wp_cursor_shape_device_v1_request_destroy: u16 = 0;
const wp_cursor_shape_device_v1_request_set_shape: u16 = 1;
// shape enum (https://wayland.app/protocols/cursor-shape-v1):
// 1=default(arrow), 4=pointer(hand), 7=cell(crosshair-like), 8=crosshair,
// 9=text(I-beam), 10=vertical_text 등. 시연 결과 7 (`cell`) 로 잘못 보내
// 스프레드시트 셀 선택 + 모양이 나오던 회귀 — 9 (`text`) 가 정답.
const wp_cursor_shape_v1_default: u32 = 1;
const wp_cursor_shape_v1_text: u32 = 9;

// wp_viewporter (stable v1) — fractional scaling 환경의 logical / physical 분리.
// https://wayland.app/protocols/viewporter
const wp_viewporter_request_destroy: u16 = 0;
const wp_viewporter_request_get_viewport: u16 = 1;
const wp_viewport_request_destroy: u16 = 0;
const wp_viewport_request_set_destination: u16 = 2;

// xdg-activation-v1 — focus return. activate 활성 surface 가 token 발급 → 다른
// surface 에 양도. https://wayland.app/protocols/xdg-activation-v1
const xdg_activation_v1_request_destroy: u16 = 0;
const xdg_activation_v1_request_get_activation_token: u16 = 1;
const xdg_activation_v1_request_activate: u16 = 2;
const xdg_activation_token_v1_request_set_serial: u16 = 0;
const xdg_activation_token_v1_request_set_app_id: u16 = 1;
const xdg_activation_token_v1_request_set_surface: u16 = 2;
const xdg_activation_token_v1_request_commit: u16 = 3;
const xdg_activation_token_v1_request_destroy: u16 = 4;
const xdg_activation_token_v1_event_done: u16 = 0;

// wp_fractional_scale_v1 (staging) — compositor 가 권장하는 fractional scale 통보.
// https://wayland.app/protocols/fractional-scale-v1
// preferred_scale 의 unit = scale / 120. 즉 240 = 2.0x, 204 = 1.7x, 120 = 1.0x.
const wp_fractional_scale_manager_v1_request_destroy: u16 = 0;
const wp_fractional_scale_manager_v1_request_get_fractional_scale: u16 = 1;
const wp_fractional_scale_v1_request_destroy: u16 = 0;
const wp_fractional_scale_v1_event_preferred_scale: u16 = 0;
const fractional_scale_denominator: u32 = 120;


// L8-β — wl_output 의 mode / done event. geometry / scale 은 아직 안 씀.
const wl_output_event_geometry: u16 = 0;
const wl_output_event_mode: u16 = 1;
const wl_output_event_done: u16 = 2;
const wl_output_event_scale: u16 = 3;
const wl_output_mode_flag_current: u32 = 0x1;
// L8-β — wl_output 없는 환경 fallback. 정상 Wayland session 에선 늘 advertise
// 되므로 거의 안 닿음 — 닿으면 startup 로그에 fallback 명시.
const screen_fallback_width: i32 = 1920;
const screen_fallback_height: i32 = 1080;
// width_percent / height_percent 가 거의 100 일 때 opposing edge anchor 로
// stretch (full screen 한 축). 정확히 100.0 비교는 부동소수점 위험.
const stretch_threshold_pct: f32 = 99.9;

// wl_data_device_manager / wl_data_device / wl_data_source / wl_data_offer
// opcodes (request side, used by us).
const wl_data_device_manager_request_create_data_source: u16 = 0;
const wl_data_device_manager_request_get_data_device: u16 = 1;
const wl_data_source_request_offer: u16 = 0;
const wl_data_source_request_destroy: u16 = 1;
const wl_data_device_request_set_selection: u16 = 1;
// wl_data_offer requests: 0=accept (안 씀), 1=receive, 2=destroy.
// 처음 a9dab9e (L6.3 우클릭 paste) 에선 한 칸씩 어긋난 값 (0, 1) 으로 적혀
// receive 가 accept 자리로 보내져 서버가 args 검사 실패 → protocol error.
// L6.4 의 Ctrl+Shift+V 시연에서 첫 발현.
const wl_data_offer_request_receive: u16 = 1;
const wl_data_offer_request_destroy: u16 = 2;

// 우리가 광고할 / 받아들일 mime. 셋 모두 paste 인입 시 동일하게 처리.
const clipboard_mime_utf8: []const u8 = "text/plain;charset=utf-8";
const clipboard_mime_utf8_string: []const u8 = "UTF8_STRING";
const clipboard_mime_text_plain: []const u8 = "text/plain";

// Linux input-event-codes BTN_RIGHT (좌 = 0x110 위에서 정의).
const wl_pointer_button_right: u32 = 0x111;
// 더블클릭 인식 시간 — macOS / Windows / GTK / Qt 의 표준 ~500ms 와 동일.
const double_click_threshold_ms: u32 = 500;

const xkb_key_backspace: u32 = 0xff08;
const xkb_key_tab: u32 = 0xff09;
const xkb_key_return: u32 = 0xff0d;
const xkb_key_escape: u32 = 0xff1b;
const xkb_key_home: u32 = 0xff50;
const xkb_key_left: u32 = 0xff51;
const xkb_key_up: u32 = 0xff52;
const xkb_key_right: u32 = 0xff53;
const xkb_key_down: u32 = 0xff54;
const xkb_key_page_up: u32 = 0xff55;
const xkb_key_page_down: u32 = 0xff56;
const xkb_key_end: u32 = 0xff57;
const xkb_key_insert: u32 = 0xff63;
const xkb_key_delete: u32 = 0xffff;
const xkb_key_iso_left_tab: u32 = 0xfe20;
// 알파벳 키는 ASCII codepoint — xkb 가 Shift 활성 시 대문자 keysym 을 돌려준다.
const xkb_key_a_lower: u32 = 0x61;
const xkb_key_a_upper: u32 = 0x41;
const xkb_key_c_lower: u32 = 0x63;
const xkb_key_c_upper: u32 = 0x43;
const xkb_key_e_lower: u32 = 0x65;
const xkb_key_e_upper: u32 = 0x45;
const xkb_key_i_lower: u32 = 0x69;
const xkb_key_i_upper: u32 = 0x49;
const xkb_key_l_lower: u32 = 0x6c;
const xkb_key_l_upper: u32 = 0x4c;
const xkb_key_p_lower: u32 = 0x70;
const xkb_key_p_upper: u32 = 0x50;
const xkb_key_v_lower: u32 = 0x76;
const xkb_key_v_upper: u32 = 0x56;
// XKB F1..F12 keysyms — `xkbcommon/xkbcommon-keysyms.h`. F4 만 Alt+F4 quit
// 단축키용. (F1 toggle 은 portal hotkey 처리이라 별 매핑 필요 없음.)
const xkb_key_f4: u32 = 0xffc1;
// L12-β — tab 단축키. Linux / Windows 의 일반 terminal 관습 (gnome-terminal /
// kitty) 동등 — `Ctrl+Shift+T` 새 탭 / `Ctrl+Shift+W` 활성 탭 닫기 / `Ctrl+
// Shift+]` 다음 탭 / `Ctrl+Shift+[` 이전 탭. Ctrl 단독 단축키는 shell 의 정상
// 통과 (Ctrl+T = transpose, Ctrl+W = kill word 등) 를 보존.
const xkb_key_t_lower: u32 = 0x74;
const xkb_key_t_upper: u32 = 0x54;
const xkb_key_w_lower: u32 = 0x77;
const xkb_key_w_upper: u32 = 0x57;
// `[` 과 Shift 의 `{` 가 keymap 별로 다른 keysym — 둘 다 매치. `]` / `}` 도
// 동일.
const xkb_key_bracketleft: u32 = 0x5b;
const xkb_key_braceleft: u32 = 0x7b;
// SPEC §2.2 — Alt+1..9 탭 인덱스 점프. xkb keysym = ASCII '1'..'9'.
const xkb_key_1: u32 = 0x31;
const xkb_key_9: u32 = 0x39;
const xkb_key_bracketright: u32 = 0x5d;
const xkb_key_braceright: u32 = 0x7d;

// 자식 셸 process 에 넘기는 extra env — AGENTS.md "터미널 환경변수" 정책
// 동등. SHELL / COLORFGBG 값이 사용자 config.shell / config.theme 에 따라
// 달라지므로 module-level const 가 아니라 `Client.extra_env_storage` 에 보관
// (Client.init 에서 채움). entry 수가 변하면 `Client.extra_env_storage` 의
// array size 도 같이 갱신.
const linux_extra_env_entry_count: usize = 5;

const Global = struct {
    name: u32 = 0,
    version: u32 = 0,
};

const Capabilities = struct {
    compositor: Global = .{},
    shm: Global = .{},
    xdg_wm_base: Global = .{},
    seat: Global = .{},
    layer_shell: Global = .{},
    text_input_v3: Global = .{},
    data_device_manager: Global = .{},
    // L8-β — 화면 해상도 알아내기 위해 wl_output bind. multi-monitor 환경에선
    // wl_output 여러 개 advertise 되지만 L8-β scope 에선 첫 번째만 사용 (multi-
    // monitor 선택은 후속 sub-step).
    output: Global = .{},
    // fractional scaling — KDE Plasma 6 의 125% / 150% / 170% 등.
    viewporter: Global = .{},
    fractional_scale_manager: Global = .{},
    // #193 — `wp_cursor_shape_manager_v1` advertise 면 themed cursor 사용
    // (compositor 가 XCursor 테마 자동 매칭). 미advertise 시 default arrow 만.
    cursor_shape_manager: Global = .{},
    // #203 Phase C — `xdg_activation_v1` (focus return). 활성 surface 가
    // token 발급 → 다른 surface 에 양도. KWin / Mutter / wlroots 모두 지원.
    xdg_activation: Global = .{},

    fn record(self: *Capabilities, name: u32, interface: []const u8, version: u32) void {
        if (std.mem.eql(u8, interface, "wl_compositor")) {
            self.compositor = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "wl_shm")) {
            self.shm = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "xdg_wm_base")) {
            self.xdg_wm_base = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "wl_seat")) {
            self.seat = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "zwlr_layer_shell_v1")) {
            self.layer_shell = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "zwp_text_input_manager_v3")) {
            self.text_input_v3 = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "wl_data_device_manager")) {
            self.data_device_manager = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "wl_output") and self.output.name == 0) {
            // 첫 번째만 저장 (multi-monitor 시 후속 wl_output 무시 — L8-β scope).
            self.output = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "wp_viewporter")) {
            self.viewporter = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "wp_fractional_scale_manager_v1")) {
            self.fractional_scale_manager = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "wp_cursor_shape_manager_v1")) {
            self.cursor_shape_manager = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "xdg_activation_v1")) {
            self.xdg_activation = .{ .name = name, .version = version };
        }
    }
};

/// L8-β — layer-shell 한 surface 의 anchor / size / margin 합본. 우리 config
/// (dock_position / width_percent / height_percent / offset_percent) 와 wire
/// protocol args 사이의 변환 결과. `Client.computeLayerLayout` 가 채움,
/// `createLayerSurface` 가 그대로 송신.
const LayerLayout = struct {
    anchor: u32,
    width: u32,
    height: u32,
    margin_top: i32,
    margin_right: i32,
    margin_bottom: i32,
    margin_left: i32,
};

/// L8-β — 화면 한 축 (가로 또는 세로) 의 percent 점유율을 픽셀로. clamp 후
/// 음수 방지 위해 max(0). `width_percent` / `height_percent` 모두 동일 식.
fn pctToPx(screen_dim: f32, pct: f32) u32 {
    const clamped = std.math.clamp(pct, 0.0, 100.0);
    const v = screen_dim * clamped / 100.0;
    if (v < 0.0) return 0;
    return @intFromFloat(@round(v));
}

/// L8-β — cross-axis margin 계산. `remaining = screen_dim - surface_dim` 의
/// `offset_percent` 비율만큼 한 쪽 (`anchor` 잡힌 edge) 에 띄움. 음수 방지.
fn pxOffset(remaining: i32, off_pct: f32) i32 {
    if (remaining <= 0) return 0;
    const rem_f: f32 = @floatFromInt(remaining);
    return @intFromFloat(@round(rem_f * off_pct / 100.0));
}

const ShmBuffer = struct {
    id: u32,
    fd: posix.fd_t,
    memory: []align(std.heap.page_size_min) u8,
    width: i32,
    height: i32,
    stride: i32,
    released: bool = false,

    fn deinit(self: *ShmBuffer) void {
        posix.munmap(self.memory);
        posix.close(self.fd);
    }
};

/// #203 Phase C — 별 layer-shell `overlay` surface 의 dialog 상태. content
/// (kind / severity / title / message) + wayland 객체 (별 surface + layer_surface
/// + viewport + buffer) 가 한 데. mac NSAlert / Win MessageBoxW 의 native dialog
/// 동등 — main 위 modal.
///
/// kind = .none → dialog 없음 (모든 입력 정상 라우팅).
/// kind = .info → Info / Error dialog. Enter / Esc / 클릭 → dismiss.
/// step 4 에서 confirm (동기 wait) 추가.
pub const DialogOverlay = struct {
    /// `.confirm` — OK + Cancel 두 버튼. Enter = OK (= true), Esc = Cancel (= false).
    /// dismiss 시 호출자가 `pending_confirm_result` 로 결과 받음 (step 4, #203).
    pub const Kind = enum { none, info, confirm };

    // --- content ---
    kind: Kind = .none,
    severity: dialog_mod.Severity = .info,
    title_buf: [128]u8 = undefined,
    title_len: usize = 0,
    msg_buf: [4096]u8 = undefined,
    msg_len: usize = 0,

    // --- wayland 객체 ---
    surface_id: u32 = 0,
    layer_surface_id: u32 = 0,
    viewport_id: u32 = 0,
    /// #210 — dialog 자체 fractional_scale 객체. main 의 fractional_scale 와
    /// 독립 — dialog 가 main createShellObjects *이전* 띄울 때 (예: boot 중
    /// portal Hotkey updated) main 의 preferred_scale event 아직 안 받음 →
    /// dialog 가 1x 로 표시 + click 좌표 변환 mismatch 의 cause. dialog 자체
    /// 객체 + roundtrip 으로 dialog 가 자기 surface 의 preferred_scale event
    /// 받음 보장. 같은 output 가정상 main 의 preferred_scale 값과 동일.
    fractional_scale_id: u32 = 0,
    active_buffer: ?ShmBuffer = null,
    /// configure event 가 알려준 buffer 크기 (physical px).
    buffer_w: i32 = 0,
    buffer_h: i32 = 0,
    configured: bool = false,

    pub fn title(self: *const DialogOverlay) []const u8 {
        return self.title_buf[0..self.title_len];
    }
    pub fn message(self: *const DialogOverlay) []const u8 {
        return self.msg_buf[0..self.msg_len];
    }
    pub fn active(self: *const DialogOverlay) bool {
        return self.kind != .none;
    }
};

fn terminalSequenceForKeysym(sym: u32) ?[]const u8 {
    return switch (sym) {
        xkb_key_return => "\r",
        xkb_key_escape => "\x1b",
        xkb_key_backspace => "\x7f",
        xkb_key_tab => "\t",
        xkb_key_iso_left_tab => "\x1b[Z",
        xkb_key_up => "\x1b[A",
        xkb_key_down => "\x1b[B",
        xkb_key_right => "\x1b[C",
        xkb_key_left => "\x1b[D",
        xkb_key_home => "\x1b[H",
        xkb_key_end => "\x1b[F",
        xkb_key_insert => "\x1b[2~",
        xkb_key_delete => "\x1b[3~",
        xkb_key_page_up => "\x1b[5~",
        xkb_key_page_down => "\x1b[6~",
        else => null,
    };
}

fn createMemfd(name: [*:0]const u8) !posix.fd_t {
    const rc = linux.memfd_create(name, linux.MFD.CLOEXEC);
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .ACCES => error.AccessDenied,
        .INVAL => error.InvalidMemfdFlags,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        else => error.MemfdCreateFailed,
    };
}

const Client = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    // #198 — portal-less hotkey IPC. `tildaz --toggle` 보낸 두 번째 인스턴스의
    // 신호를 받는 Unix domain socket listener. -1 = listener 생성 실패 (이미
    // 다른 인스턴스가 사용 중 — 정상). createListener 가 실패해도 시작은 계속.
    toggle_listener_fd: posix.fd_t = -1,
    caps: Capabilities = .{},
    input: [8192]u8 = undefined,
    input_len: usize = 0,
    received_fds: std.ArrayList(posix.fd_t) = .{},
    wait_callback_id: u32 = 0,
    wait_callback_done: bool = false,
    configured: bool = false,
    running: bool = true,
    saw_xrgb8888: bool = false,
    saw_argb8888: bool = false,
    next_id: u32 = first_client_alloc_id,
    pending_width: i32 = 0,
    pending_height: i32 = 0,
    window_width: i32 = default_width,
    window_height: i32 = default_height,
    mapped: bool = false,
    renderer: software_terminal.Renderer,
    session: ?session_core.SessionCore = null,
    shell_exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    needs_redraw: bool = false,
    // Frame callback throttling (issue #196 — KDE Plasma 6 fractional scaling
    // 환경에서 타이핑마다 짧은 flicker). compositor 의 next-frame timing 에
    // commit 을 정렬해서 60Hz 보다 빠른 commit (fast typing 시) 을 차단. foot
    // / alacritty / wezterm 등 표준 Wayland client 패턴. `attachAndCommit` 가
    // commit 직전 `wl_surface.frame(id)` request 보내고 `awaiting_frame=true`
    // 표시. 다음 `redraw` 호출은 `awaiting_frame` 면 skip (needs_redraw 는
    // true 로 남아 다음 iter 에 재시도). `wl_callback.done` 도착 시 false.
    frame_callback_id: u32 = 0,
    awaiting_frame: bool = false,
    active_buffer: ?ShmBuffer = null,
    retired_buffers: std.ArrayList(ShmBuffer) = .{},
    compositor_id: u32 = 0,
    shm_id: u32 = 0,
    wm_base_id: u32 = 0,
    surface_id: u32 = 0,
    xdg_surface_id: u32 = 0,
    toplevel_id: u32 = 0,
    // L8-α — wlr-layer-shell surface. compositor 가 `zwlr_layer_shell_v1` 을
    // advertise 한 경우에만 활성. 둘 다 0 이면 xdg-shell fallback 경로 사용.
    // layer-shell 활성 시 xdg_surface_id / toplevel_id 는 0 으로 유지 — 두
    // 경로를 동시에 만들면 안 된다 (한 surface 의 role 충돌).
    layer_shell_id: u32 = 0,
    layer_surface_id: u32 = 0,
    /// #203 Phase C — 별 layer-shell `overlay` dialog surface + content state.
    /// main surface (`top`) 와 *동일 connection* 의 별 wl_surface 쌍 — native
    /// NSAlert / MessageBoxW 와 동등하게 main terminal 위 modal 로 그려진다.
    /// `kind == .none` 이면 inactive (대화상자 없음).
    dialog: DialogOverlay = .{},
    /// #203 Phase C — dismissDialog 를 main loop 로 deferred. dismiss 가 inner
    /// `roundtrip()` 호출하는데, dispatchBuffered 의 reentrant 안에서 호출하면
    /// `copyForwards` 가 outer dispatchBuffered 의 input_len/offset state 를
    /// corrupt → 다음 iteration 에서 underflow → BadMessage → fatal (사용자 시연
    /// 발견 + `BadMessage offset=132 input_len=0` 진단 dump 로 확정).
    /// 호출자 (handlePointerButton / handleDialogKey / layer-surface closed) 는
    /// `requestDismissDialog` 로 flag 만 set, main loop 가 매 iteration drain.
    pending_dialog_dismiss: bool = false,
    /// #203 Phase C step 4 — confirm dialog 의 결과. dismiss 시 set, host 의
    /// `dialogShowConfirmCb` inner pump 가 `null != null` 으로 break.
    ///   - `true` = OK 클릭 / Enter
    ///   - `false` = Cancel 클릭 / Esc / 외부 dismiss (closed event 등)
    pending_confirm_result: ?bool = null,
    /// #203 Phase C step 4 — Alt+F4 의 deferred quit. Alt+F4 핸들러는 flag 만
    /// set, main loop 의 `drainQuitRequest` 가 multi-tab confirm + `running=false`.
    /// `dialog.showConfirm` 의 inner pump 가 `dispatchBuffered` 의 reentrant
    /// context 안에서 호출되면 안 됨 (deferred dismiss 와 동일 reentrancy 위험).
    pending_quit_request: bool = false,
    /// #213 — Ctrl+Shift+I 의 deferred About. key 핸들러는 flag 만 set, main
    /// loop 의 `drainAboutRequest` 가 실제로 About 다이얼로그를 연다. About 의
    /// `createDialogSurface` 가 `roundtrip` (inner dispatchBuffered) 을 돌리는데,
    /// 이게 outer `dispatchBuffered` 의 reentrant context 안에서 호출되면 공유
    /// `self.input` / `input_len` 이 outer 의 stale `offset` 과 어긋나 post-loop
    /// 의 `input_len - offset` 뺄셈이 underflow → integer overflow panic (#213).
    /// quit / dismiss 와 동일하게 deferred 로 reentrancy 제거.
    pending_about_request: bool = false,
    // L8-β — wl_output binding + 화면 해상도. layer-shell anchor / size /
    // margin 계산에 사용. mode event (flag CURRENT) 에서 width / height 받음.
    // 0 이면 못 받은 상태 — `screen_fallback_*` 로 대체.
    output_id: u32 = 0,
    screen_width: i32 = 0,
    screen_height: i32 = 0,
    // fractional scaling — KDE Plasma 6 의 125% / 150% / 170% 등. compositor 가
    // advertise 안 한 환경 (GNOME mutter / wlroots 등) 에선 0 이라 미사용 — `preferred_scale`
    // default `fractional_scale_denominator` (= 120 = 1.0x) 로 no-op 동작.
    viewporter_id: u32 = 0,
    fractional_scale_manager_id: u32 = 0,
    // #193 — wp_cursor_shape protocol object ids + cached last shape (set_shape
    // 가 last_serial 필요해 enter event 까지 0 으로 둠, 변경 시만 송신).
    cursor_shape_manager_id: u32 = 0,
    cursor_shape_device_id: u32 = 0,
    last_cursor_shape: u32 = 0,
    // #203 Phase C — xdg_activation_v1 global. focus return 용. dismiss 직전
    // 활성 surface (dialog) 가 token 발급 → main 에 activate. 미advertise
    // 환경은 fallback (focus return 안 됨, 사용자가 main 클릭 필요).
    xdg_activation_id: u32 = 0,
    // 진행 중 token 발급 단계 추적 — get_activation_token 요청 후 done event
    // 받을 때까지 임시. 받으면 token 문자열을 별 buffer 에 저장 + activate
    // 호출. 동기 roundtrip 으로 wait.
    pending_activation_token_id: u32 = 0,
    pending_activation_token_done: bool = false,
    pending_activation_token: std.ArrayList(u8) = .{},
    // #193 — `set_shape(serial, shape)` 의 serial 은 *pointer enter event*
    // serial 이어야 함 (spec). `last_serial` 은 keyboard / button / pointer
    // 모든 종류의 최신 serial 이라 typing / click 직후엔 pointer-enter 가
    // 아닌 serial → compositor reject + cursor 변경 안 됨. pointer enter
    // 만 별도 보관.
    last_pointer_enter_serial: u32 = 0,
    /// #203 Phase C — focus surface 추적. dialog 가 *실제* keyboard focus 인지
    /// 확인 + xdg-activation token 발급 가드 + pointer focus 기반 modal click
    /// filter. wl_keyboard.enter / wl_pointer.enter payload 의 surface
    /// object id, leave 시 매칭되는 id 면 0 으로 reset. 같은 client 의 다른
    /// surface (dialog vs main) 구분 가능.
    last_keyboard_focus_surface_id: u32 = 0,
    last_pointer_enter_surface_id: u32 = 0,
    /// per-surface — `createShellObjects` 가 create, `destroyShellObjects` 가 destroy.
    viewport_id: u32 = 0,
    fractional_scale_id: u32 = 0,
    /// preferred_scale event 가 받는 numerator. denominator = 120.
    /// physical_px = logical_px × preferred_scale / 120.
    preferred_scale: u32 = fractional_scale_denominator,
    // L9-α — D-Bus session bus client (libdbus-1 dlopen). portal `GlobalShortcuts`
    // 의 진입 자리. 연결 실패는 fatal 아님 — minimal Wayland session (portal
    // 없음) 에선 hotkey 기능 없이 terminal 자체는 정상. L9-β-1 부터 method call /
    // signal subscribe.
    dbus_session: ?dbus.SessionBus = null,
    // L9-β-1 — portal `GlobalShortcuts.CreateSession` 결과. session_handle 은
    // 후속 `BindShortcuts` (L9-β-2) / `Activated` signal subscribe (L9-γ) 에서
    // 사용. dbus_session null 이거나 CreateSession 실패 시 null — hotkey 기능
    // 미제공 graceful degrade.
    portal_session: ?portal.GlobalShortcutsSession = null,
    // L9-γ — portal `Activated` signal subscription. BindShortcuts 성공 후
    // 등록 — compositor 가 hotkey 누름마다 portal 통해 Activated signal 보내고
    // filter callback (`onPortalActivated`) 가 toggle 호출. heap 할당 — filter
    // user_data 가 stable address 요구.
    portal_subscription: ?*portal.ActivatedSubscription = null,
    // L9-γ — surface visibility toggle state. macOS `g_visible` 동등. false
    // = 평소 (layer-shell mapped), true = hidden (wl_surface.attach(NULL) +
    // commit 송신 끝난 상태). 다음 Activated → flip + re-attach.
    surface_hidden: bool = false,
    // L9-γ — 중복 Activated debounce. 일부 compositor 가 같은 hotkey press
    // 에 대해 portal 통해 두 번 signal 보낼 가능성 (key repeat 자체는 보통
    // compositor 가 차단 — repeat_info 와 다른 channel). 같은 timestamp 면
    // 같은 누름으로 간주. 0 timestamp 면 debounce 안 함 (compositor 미채움).
    last_toggle_timestamp: u64 = 0,
    seat_id: u32 = 0,
    keyboard_id: u32 = 0,
    pointer_id: u32 = 0,
    seat_capabilities: u32 = 0,
    keyboard: xkb.Keyboard = .{},
    pointer_x_px: i32 = -1,
    pointer_y_px: i32 = -1,
    pointer_inside: bool = false,
    data_device_manager_id: u32 = 0,
    data_device_id: u32 = 0,
    active_data_source_id: u32 = 0,
    clipboard_text: ?[]const u8 = null,
    last_serial: u32 = 0,
    // 우리가 paste 받기 위해 추적하는 wl_data_offer 객체. data_offer event 가
    // 새 객체를 알리면 pending 자리, selection event 가 그 객체를 인정하면
    // `paste_*` 로 승격. mime 광고는 offer event 가 도착할 때마다 누적.
    pending_offer_id: u32 = 0,
    pending_offer_has_utf8: bool = false,
    paste_offer_id: u32 = 0,
    paste_offer_has_utf8: bool = false,
    // 더블클릭 검출 — wayland `wl_pointer.button` event 에 click count 정보 없음.
    // 같은 cell 의 좌클릭 press 가 `double_click_threshold_ms` 이내 두 번이면 더블클릭.
    last_left_click_time_ms: u32 = 0,
    last_left_click_cell: ?terminal_interaction.Cell = null,
    // L10-α IME wiring. zwp_text_input_v3 manager / object id. keyboard focus
    // 가 들어오면 enable + commit, 나가면 disable + commit. commit_string event
    // 가 도착하면 그 텍스트를 PTY 로 송신 — fcitx5 가 음절 완성 시점에 보내준다.
    // preedit_string 도 받지만 overlay 는 L10-β 의 scope.
    text_input_manager_id: u32 = 0,
    text_input_id: u32 = 0,
    text_input_enabled: bool = false,
    text_input_done_serial: u32 = 0,
    // L10-β. text-input-v3 는 enter/leave/preedit/commit/delete 가 batch 로
    // 오고 `done(serial)` 에서 한 번에 적용해야 한다 (spec). batch 안 누적용
    // pending buffer 두 개 + `done` 직후 renderer 가 가리킬 preedit storage.
    pending_preedit: std.ArrayList(u8) = .{},
    pending_commit: std.ArrayList(u8) = .{},
    preedit_text: std.ArrayList(u8) = .{},
    // L10-γ — 마지막으로 server 에 알린 cursor rect (pixel, surface-relative).
    // paint 끝마다 비교해 변경 시만 set_cursor_rectangle + commit 보내 spam 회피.
    last_cursor_rect_x: i32 = -1,
    last_cursor_rect_y: i32 = -1,
    last_cursor_rect_w: i32 = 0,
    last_cursor_rect_h: i32 = 0,
    // L13-α — 사용자 설정. `runBaselineWindow` 가 host 의 g_config 포인터를
    // 전달. SessionCore.init 시 shell / theme / max_scroll_lines 가 여기서.
    config: *const config_mod.Config,
    /// #205 — boot / show phase elapsed log 용 monotonic timer. boot path
    /// 는 `runBaselineWindow` 진입에 start, show path 는 매 `handleActivatedToggle`
    /// show 분기 시작에 reset. 사용자 *체감* 1-2 sec startup latency 가 어느
    /// phase 에 모이는지 확정 위한 진단 인프라 — fix 는 측정 결과 본 후.
    boot_timer: ?std.time.Timer = null,
    show_timer: ?std.time.Timer = null,
    /// 자식 셸 extra env. Client.init 에서 config.shell + theme luminance 로
    /// 채워진다. SessionCore.init 에 slice 로 전달 — Client lifetime 안에서
    /// storage valid.
    extra_env_storage: [linux_extra_env_entry_count]terminal_backend.ExtraEnv = undefined,
    /// L12-β — `tab_actions.Host.override_ptr` 가 가리키는 storage. arrow `<`
    /// `>` 로 사용자가 활성 탭 추적을 일시 정지한 경우 true — L12-γ scope,
    /// L12-β 에서는 항상 false. `tab_actions.Host` 자체는 매 호출 시 stack
    /// 에 build (`buildTabActionsHost`) — Client field 로 보관하면 init
    /// 시점 (return-by-value) 의 callback ptr / override_ptr 주소가 stale.
    tab_scroll_override: bool = false,
    /// L12-β — read thread → main thread pending close queue. shell process
    /// 가 exit (PTY EOF) 시 read thread 가 `linuxTabExit` 호출 → 직접 close
    /// 면 다른 탭의 read thread join 시 deadlock 가능 + multi-tab 시 잘못된
    /// 종료 (모든 탭 cascade). macOS host (`g_pending_close_buf`) 와 동등
    /// 패턴 — read thread 는 buf 에 ptr append, main loop 가 drain.
    pending_close_buf: std.ArrayList(usize) = .{},
    pending_close_mutex: std.Thread.Mutex = .{},
    /// L12-γ — tab bar 의 가로 scroll 위치 (pixel, tab area 좌측 기준). 탭
    /// 폭 합이 viewport 폭 넘을 때만 의미. user override = false 면 매 paint
    /// 시 `ensureActiveVisible` 로 자동 보정 (활성 탭이 viewport 안 들어옴).
    /// user 가 `<` `>` 클릭하면 override true 되어 자동 보정 정지.
    tab_scroll_x: f32 = 0,
    /// L12-γ-5 — Wayland client-side key repeat state. compositor 가 알려준
    /// rate / delay (`wl_keyboard.repeat_info`) 따라 main loop 의 timer 가
    /// repeat event simulate. macOS / Windows 는 OS 자동, Linux Wayland 는
    /// client 책임 (spec). keycode=0 이면 disarm. delay 가 첫 repeat 까지,
    /// 그 후 `1000/rate` ms 마다 repeat.
    key_repeat_keycode: u32 = 0,
    key_repeat_next_ms: i64 = 0,
    key_repeat_rate_hz: i32 = 0,
    key_repeat_delay_ms: i32 = 0,
    /// L12-γ-2 — tab rename 모드. cross-platform `tab_interaction.RenameState`
    /// — macOS / Windows 가 같은 module 사용. 더블클릭으로 begin, Enter / Escape
    /// 으로 종료, typing / IME commit 으로 buffer 갱신.
    rename_state: tab_interaction.RenameState = .{},
    /// tab bar 더블클릭 검출 — `wl_pointer.button` 의 click count 정보 없음.
    /// 같은 tab_index 좌클릭 press 가 `double_click_threshold_ms` (= 500) 안
    /// 두 번이면 더블클릭. cell 영역 (`last_left_click_*`) 과 별도 — 영역 간섭
    /// 방지 (cell drag selection 과 tab bar rename 의 timer 분리).
    last_tab_click_time_ms: u32 = 0,
    last_tab_click_idx: usize = std.math.maxInt(usize),
    /// L12-γ-3 — tab drag-and-drop reorder state. cross-platform
    /// `tab_interaction.DragState` — mac / win 공유. `handleTabBarClick`
    /// 의 본체 single-click 에서 `begin`, `handlePointerMotion` 에서 `move`
    /// + 탭 area 가장자리 auto-scroll, button release 에서 `finish` →
    /// `session.reorderTabs` (mac 패턴 그대로, host hook 추가 안 함).
    tab_drag: tab_interaction.DragState = .{},

    fn init(allocator: std.mem.Allocator, cfg: *const config_mod.Config) !Client {
        const path = try waylandSocketPath(allocator);
        defer allocator.free(path);
        // 첫 init 시점엔 wp_fractional_scale_v1 의 preferred_scale event 가
        // 아직 안 왔으니 default 120/120 (= 1.0x). event 받은 후 applyScale.
        var renderer = try software_terminal.Renderer.init(
            allocator,
            cfg,
            fractional_scale_denominator,
            fractional_scale_denominator,
        );
        renderer.opacity_alpha = cfg.opacity_alpha;
        errdefer renderer.deinit(allocator);
        const stream = std.net.connectUnixSocket(path) catch |err| {
            // connectUnixSocket 의 `FileNotFound` / `AccessDenied` / `ConnectionRefused`
            // 만 위로 올리면 사용자가 본 메시지가 "TildaZ failed to start. Error: FileNotFound"
            // 한 줄 — Wayland 세션인지 X11 세션인지조차 알 수 없다. 시도한 socket
            // path + WAYLAND_DISPLAY / XDG_SESSION_TYPE / XDG_RUNTIME_DIR raw 값을
            // log + stderr 양쪽에 같이 노출하고, caller 가 분기 가능한 의미 이름
            // (`WaylandSocketUnavailable`) 으로 변환.
            reportWaylandSocketFailure(allocator, path, err);
            return error.WaylandSocketUnavailable;
        };
        const theme = cfg.theme orelse fallback_theme;
        return .{
            .allocator = allocator,
            .stream = stream,
            .renderer = renderer,
            .config = cfg,
            .extra_env_storage = .{
                .{ .name = "TERM", .value = "xterm-256color" },
                // Linux 는 `C.UTF-8` — POSIX 표준 portable UTF-8 locale, 모든
                // 주요 distro 에 보장. macOS / Windows 의 `en_US.UTF-8` 은 그
                // OS 의 기본 locale 이라 setlocale OK, 단 Linux 는 distro 에
                // 따라 `en_US.UTF-8` 미설치 가능 (사용자 환경 = ko_KR.utf8 +
                // C.utf8 만). setlocale 실패하면 bash readline 이 single-byte
                // 모드로 떨어져 한글 paste / IME commit 깨짐 — 사용자 보고로
                // 확정.
                .{ .name = "LANG", .value = "C.UTF-8" },
                .{ .name = "LC_CTYPE", .value = "C.UTF-8" },
                .{ .name = "COLORFGBG", .value = if (themes.isDark(theme)) "15;0" else "0;15" },
                .{ .name = "SHELL", .value = cfg.shell },
            },
        };
    }

    fn deinit(self: *Client) void {
        // #198 — toggle listener cleanup. socket file 도 unlink — 다음 인스턴스가
        // 깨끗하게 bind 가능.
        if (self.toggle_listener_fd >= 0) {
            posix.close(self.toggle_listener_fd);
            single_instance.cleanup();
            self.toggle_listener_fd = -1;
        }
        if (self.portal_subscription) |sub| {
            sub.deinit();
            self.allocator.destroy(sub);
            self.portal_subscription = null;
        }
        if (self.portal_session) |*session| {
            session.deinit();
            self.portal_session = null;
        }
        if (self.dbus_session) |*session| {
            session.deinit();
            self.dbus_session = null;
        }
        self.clearClipboardOwnership();
        self.keyboard.deinit();
        self.pending_preedit.deinit(self.allocator);
        self.pending_commit.deinit(self.allocator);
        self.preedit_text.deinit(self.allocator);
        self.pending_activation_token.deinit(self.allocator);
        for (self.received_fds.items) |fd| posix.close(fd);
        self.received_fds.deinit(self.allocator);
        if (self.active_buffer) |*buffer| {
            self.destroyBufferObject(buffer.id);
            buffer.deinit();
            self.active_buffer = null;
        }
        for (self.retired_buffers.items) |*buffer| {
            self.destroyBufferObject(buffer.id);
            buffer.deinit();
        }
        self.retired_buffers.deinit(self.allocator);
        // #203 Phase C — dialog surface 가 떠 있는 상태로 종료 시 cleanup.
        // wayland connection 이 곧 close 라 send 실패는 무시 — buffer mmap /
        // fd 만 안전하게 해제.
        if (self.dialog.active_buffer) |*buffer| {
            buffer.deinit();
            self.dialog.active_buffer = null;
        }
        if (self.session) |*session| {
            session.deinit();
            self.session = null;
        }
        // #212 — `pending_close_buf` 는 *session.deinit 뒤에* 해제. session.deinit
        // 이 각 Tab 의 backend.deinit (master_fd close) → PTY read/wait thread 가
        // EOF 로 `onPtyExit` → `linuxTabExit` 를 호출해 이 buffer 에 append 하기
        // 때문. 먼저 해제하면 종료 (quit confirm OK 등) 시 freed ArrayList 에
        // append → capacity 산정에서 integer overflow (use-after-free). session.
        // deinit 이 모든 PTY thread 를 join 한 뒤엔 더 이상 append 없으므로 안전.
        self.pending_close_buf.deinit(self.allocator);
        self.renderer.deinit(self.allocator);
        self.stream.close();
    }

    fn run(self: *Client) !void {
        // #205 — boot phase elapsed timer start. 사용자 *체감* 1-2 sec startup
        // latency 진단용. monotonic, ns_per_ms 단위로 log.
        self.boot_timer = std.time.Timer.start() catch null;

        // #203 Phase C — dialog backend host callback 등록. self pointer 가
        // final 위치 (Client.init 가 by value 반환이라 init 안에서는 등록 못 함).
        // run 진입 시점 = stable address. defer 해제로 deinit 안 dangling 회피.
        dialog_linux.registerCallbacks(.{
            .ctx = self,
            .show_info = Client.dialogShowInfoCb,
            .show_confirm = Client.dialogShowConfirmCb,
        });
        defer dialog_linux.unregisterCallbacks();

        try self.getRegistry();
        try self.roundtrip();
        self.logBootElapsed("registry+roundtrip");

        if (self.caps.compositor.name == 0) return error.WaylandCompositorMissing;
        if (self.caps.shm.name == 0) return error.WaylandShmMissing;
        if (self.caps.xdg_wm_base.name == 0) return error.WaylandXdgWmBaseMissing;

        try self.bindGlobals();
        try self.roundtrip();
        self.logCapabilities();
        self.logBootElapsed("bind globals");
        self.tryConnectDbus();
        self.logBootElapsed("dbus+portal");
        // L13-γ — ARGB8888 광고 필수 (opacity_percent 적용을 위한 alpha
        // channel). 거의 모든 compositor 가 광고하므로 fallback 없이 fatal.
        if (!self.saw_argb8888) return error.WaylandShmArgb8888Missing;
        try self.createKeyboardIfAvailable();
        if (self.keyboard_id != 0) try self.roundtrip();
        self.logBootElapsed("keyboard ready");

        // L11-β — hidden_start: portal `GlobalShortcuts` 가 가용한 경우에만
        // surface 생성 skip + `surface_hidden=true` set. 첫 portal Activated
        // 신호 (사용자가 hotkey 누름) 가 `handleActivatedToggle` → `createShellObjects`
        // → configure handler 의 `ensureSessionGrid` 자동 호출로 정상 show.
        // mac `if (!g_config.hidden_start) showWindow();` / Windows `if (!config.hidden_start) app.window.show();`
        // 동등.
        //
        // portal 미가용 환경 (portal_session == null) 에서 hidden_start=true 면
        // 사용자가 영영 볼 수 없는 trap — warning log + 즉시 show 로 fallback.
        const hidden_at_start = self.config.hidden_start and self.portal_session != null;
        if (self.config.hidden_start and self.portal_session == null) {
            log.appendLine("startup", "hidden_start ignored — portal GlobalShortcuts unavailable, showing on start", .{});
        }
        if (hidden_at_start) {
            self.surface_hidden = true;
            log.appendLine("startup", "hidden_start — surface deferred until first portal Activated", .{});
            self.logBootElapsed("ready (hidden_start, awaiting first hotkey)");
            std.debug.print("TildaZ Linux Wayland terminal is hidden — press the configured hotkey to show.\n", .{});
        } else {
            try self.createShellObjects();
            self.logBootElapsed("createShellObjects");
            try self.waitForConfigure();
            self.logBootElapsed("first configure");
            try self.ensureSessionGrid();
            self.logBootElapsed("session+PTY");
            _ = try self.redraw();
            self.logBootElapsed("first frame");

            std.debug.print("TildaZ Linux Wayland terminal window is open. Close the window to exit.\n", .{});
            log.appendLine("linux", "Wayland terminal window mapped", .{});
        }

        while (self.running) {
            try self.pollAndDispatch(frame_poll_ms);
            // #203 Phase C — dialog dismiss 가 pending 이면 *여기서* 실제 처리.
            // pointer button / dialog key / layer-surface closed handler 들은
            // dispatchBuffered 의 reentrant context 안이라 inner roundtrip 시
            // outer buffer state corrupt (사용자 시연 발견 — `BadMessage offset
            // input_len=0` 진단). deferred 로 reentrancy 해소.
            self.drainPendingDialogDismiss();
            // #203 Phase C step 4 — Alt+F4 deferred quit. confirm 의 inner pump
            // 도 outer dispatchBuffered 밖에서 호출.
            self.drainQuitRequest();
            // #213 — Ctrl+Shift+I deferred About. createDialogSurface 의 inner
            // roundtrip 을 outer dispatchBuffered 밖에서 돌려 buffer corrupt 회피.
            self.drainAboutRequest();
            // L12-β — exit 한 탭들을 main thread 에서 close. read thread 의
            // `linuxTabExit` 가 pending_close_buf 에 ptr 쌓아둠. drain 이
            // 마지막 탭 닫음을 만나면 shell_exited 트리거.
            self.drainExitedTabs();
            // L9-γ — portal Activated signal 등 dbus message dispatch (filter
            // callback 통해 onPortalActivated → handleActivatedToggle).
            self.dispatchDbusMessages();
            // L12-γ-5 — Wayland client-side key repeat timer 검사.
            try self.maybeRepeatKey();
            if (self.shell_exited.load(.acquire)) {
                self.running = false;
                break;
            }
            if (self.session) |*session| {
                if (session.drainActiveOutputForRender()) {
                    self.requestRedraw();
                }
            }
            try self.maybeRedraw();
            // #193 — rename begin/end 등 state 변화 후 mouse 안 움직여도 즉시
            // cursor 갱신. cached `last_cursor_shape` 비교라 no-op 자주.
            self.updateCursorShape() catch {};
        }
    }

    fn getRegistry(self: *Client) !void {
        try self.sendNewId(display_id, 1, registry_id);
    }

    fn bindGlobals(self: *Client) !void {
        self.compositor_id = self.allocId();
        try self.bind(self.caps.compositor.name, "wl_compositor", @min(self.caps.compositor.version, 4), self.compositor_id);
        self.shm_id = self.allocId();
        try self.bind(self.caps.shm.name, "wl_shm", 1, self.shm_id);
        self.wm_base_id = self.allocId();
        try self.bind(self.caps.xdg_wm_base.name, "xdg_wm_base", 1, self.wm_base_id);
        if (self.caps.seat.name != 0) {
            self.seat_id = self.allocId();
            try self.bind(self.caps.seat.name, "wl_seat", @min(self.caps.seat.version, 7), self.seat_id);
        }
        if (self.caps.data_device_manager.name != 0) {
            self.data_device_manager_id = self.allocId();
            try self.bind(
                self.caps.data_device_manager.name,
                "wl_data_device_manager",
                @min(self.caps.data_device_manager.version, 3),
                self.data_device_manager_id,
            );
        }
        // L8-α — `zwlr_layer_shell_v1` bind. advertise 안 됐으면 (GNOME 등)
        // skip — `createShellObjects` 가 xdg-shell fallback 경로로 분기.
        if (self.caps.layer_shell.name != 0) {
            self.layer_shell_id = self.allocId();
            // #205 — version 2 이상이 필요 (set_layer since v2, #205 kitty
            // workaround 의 핵심). spec 의 latest = 4. 최대 4 까지 bind.
            // version 1 만 advertise 하는 compositor 면 set_layer 미사용 path
            // 로 fallback 필요 — 아래 send 사이트의 version check.
            try self.bind(
                self.caps.layer_shell.name,
                "zwlr_layer_shell_v1",
                @min(self.caps.layer_shell.version, 4),
                self.layer_shell_id,
            );
        }
        // L8-β — wl_output bind. mode event 에서 screen_width / screen_height
        // 받아 layer-shell anchor / size / margin 계산에 사용. multi-monitor
        // 환경에선 첫 번째 wl_output 만 — `Capabilities.record` 가 첫 advertise
        // 만 저장. 정상 Wayland session 에선 항상 advertise — 없으면 fallback.
        if (self.caps.output.name != 0) {
            self.output_id = self.allocId();
            try self.bind(
                self.caps.output.name,
                "wl_output",
                @min(self.caps.output.version, 2),
                self.output_id,
            );
        }
        // fractional scaling — wp_viewporter + wp_fractional_scale_manager_v1.
        // 둘 다 advertise 된 환경 (KDE Plasma 6) 에서만 fractional scale 정확.
        // 한 쪽만 있어도 effective 0 (둘 다 묶여야 의미) — 그래도 bind 시도.
        if (self.caps.viewporter.name != 0) {
            self.viewporter_id = self.allocId();
            try self.bind(
                self.caps.viewporter.name,
                "wp_viewporter",
                @min(self.caps.viewporter.version, 1),
                self.viewporter_id,
            );
        }
        if (self.caps.fractional_scale_manager.name != 0) {
            self.fractional_scale_manager_id = self.allocId();
            try self.bind(
                self.caps.fractional_scale_manager.name,
                "wp_fractional_scale_manager_v1",
                @min(self.caps.fractional_scale_manager.version, 1),
                self.fractional_scale_manager_id,
            );
        }
        // #193 — wp_cursor_shape_manager_v1 bind. advertise 안 됐으면 (older
        // compositor) cursor 변경 비활성 (compositor default arrow 유지).
        if (self.caps.cursor_shape_manager.name != 0) {
            self.cursor_shape_manager_id = self.allocId();
            try self.bind(
                self.caps.cursor_shape_manager.name,
                "wp_cursor_shape_manager_v1",
                @min(self.caps.cursor_shape_manager.version, 1),
                self.cursor_shape_manager_id,
            );
        }
        // #203 Phase C — xdg_activation_v1. focus return 용. compositor 가
        // advertise 한 경우만. KWin / Mutter / wlroots 모두 지원.
        if (self.caps.xdg_activation.name != 0) {
            self.xdg_activation_id = self.allocId();
            try self.bind(
                self.caps.xdg_activation.name,
                "xdg_activation_v1",
                @min(self.caps.xdg_activation.version, 1),
                self.xdg_activation_id,
            );
        }
        // L10-α — `zwp_text_input_manager_v3` bind + 그 자리에서 바로
        // `get_text_input(seat)` 호출해 text_input object 생성. enable / disable
        // 은 keyboard focus enter / leave 이벤트에서 트리거.
        if (self.caps.text_input_v3.name != 0 and self.seat_id != 0) {
            self.text_input_manager_id = self.allocId();
            try self.bind(
                self.caps.text_input_v3.name,
                "zwp_text_input_manager_v3",
                @min(self.caps.text_input_v3.version, 1),
                self.text_input_manager_id,
            );
            self.text_input_id = self.allocId();
            try self.sendArgs(
                self.text_input_manager_id,
                text_input_manager_request_get_text_input,
                &.{ self.text_input_id, self.seat_id },
            );
        }
        log.appendLine("wayland", "bound globals compositor_id={} shm_id={} wm_base_id={} seat_id={} data_device_manager_id={} text_input_manager_id={} text_input_id={} layer_shell_id={} output_id={}", .{
            self.compositor_id,
            self.shm_id,
            self.wm_base_id,
            self.seat_id,
            self.data_device_manager_id,
            self.text_input_manager_id,
            self.text_input_id,
            self.layer_shell_id,
            self.output_id,
        });
    }

    fn createKeyboardIfAvailable(self: *Client) !void {
        if (self.seat_id == 0 or self.keyboard_id != 0) return;
        if ((self.seat_capabilities & wl_seat_capability_keyboard) == 0) {
            log.appendLine("wayland", "wl_seat has no keyboard capability", .{});
            return;
        }

        self.keyboard_id = self.allocId();
        try self.sendNewId(self.seat_id, wl_seat_request_get_keyboard, self.keyboard_id);
    }

    fn createPointerIfAvailable(self: *Client) !void {
        if (self.seat_id == 0 or self.pointer_id != 0) return;
        if ((self.seat_capabilities & wl_seat_capability_pointer) == 0) {
            log.appendLine("wayland", "wl_seat has no pointer capability", .{});
            return;
        }

        self.pointer_id = self.allocId();
        try self.sendNewId(self.seat_id, wl_seat_request_get_pointer, self.pointer_id);

        // #193 — cursor_shape_device 가 wl_pointer 와 1:1 매칭. manager advertise
        // 된 경우만. set_shape 는 last_serial (enter event) 필요해 이 시점엔 송신
        // X — handlePointerEnter / handlePointerMotion 가 시점에 따라 호출.
        if (self.cursor_shape_manager_id != 0 and self.cursor_shape_device_id == 0) {
            self.cursor_shape_device_id = self.allocId();
            try self.sendArgs(
                self.cursor_shape_manager_id,
                wp_cursor_shape_manager_v1_request_get_pointer,
                &.{ self.cursor_shape_device_id, self.pointer_id },
            );
        }
    }

    /// #193 — pointer 위치 기반 cursor 결정 + set_shape 송신 (변경 시만).
    /// SPEC.md §3.1 — cell 영역 + rename 활성 탭 text 영역 → text (I-beam),
    /// 그 외 → default arrow.
    fn updateCursorShape(self: *Client) !void {
        if (self.cursor_shape_device_id == 0) return; // protocol 미advertise
        if (self.last_pointer_enter_serial == 0) return; // enter event 아직
        const want_text = self.pointerInCellArea() or self.pointerInRenameText();
        const shape: u32 = if (want_text) wp_cursor_shape_v1_text else wp_cursor_shape_v1_default;
        if (shape == self.last_cursor_shape) return; // 캐시 hit — spam 회피
        // spec: serial = pointer enter event serial (latest 권장). keyboard /
        // button serial 보내면 compositor reject + cursor 안 바뀜 (시연 회귀).
        try self.sendArgs(
            self.cursor_shape_device_id,
            wp_cursor_shape_device_v1_request_set_shape,
            &.{ self.last_pointer_enter_serial, shape },
        );
        self.last_cursor_shape = shape;
    }

    /// 현재 pointer 위치 (physical px) 가 cell 영역인지. 좌표가 음수 (pointer
    /// 영역 밖) 면 false.
    fn pointerInCellArea(self: *const Client) bool {
        const x = self.pointer_x_px;
        const y = self.pointer_y_px;
        if (x < 0 or y < 0) return false;
        const pad = self.renderer.paddingPx();
        const tab_bar_h = self.effectiveTabBarHeightPx();
        const sbw = self.renderer.scrollbarWPx();
        if (y < tab_bar_h) return false; // 탭바
        if (x >= self.window_width - sbw) return false; // 스크롤바
        if (x < pad or y < tab_bar_h + pad) return false; // 좌측 / 상단 padding
        if (y >= self.window_height - pad) return false; // 하단 padding
        if (x >= self.window_width - pad - sbw) return false; // 우측 padding
        return true;
    }

    /// SPEC.md §3.1 — rename 활성 탭의 text 입력 영역 hit-test (close 'x' 박스
    /// 제외). `tab_layout.hitRenameText` 공유 helper 사용 — Win / mac 동등 로직.
    fn pointerInRenameText(self: *const Client) bool {
        if (!self.rename_state.isActive()) return false;
        const session = if (self.session) |*s| s else return false;
        const x = self.pointer_x_px;
        const y = self.pointer_y_px;
        if (x < 0 or y < 0) return false;
        const layout_inputs = tab_layout.Inputs{
            .viewport_w = @floatFromInt(self.window_width),
            .tab_count = @intCast(session.count()),
            .tab_w = @floatFromInt(self.renderer.tabWidthPx()),
            .arrow_w = @floatFromInt(self.renderer.tabArrowWPx()),
            .plus_w = @floatFromInt(self.renderer.tabPlusWPx()),
            .scroll_x = self.tab_scroll_x,
        };
        const layout = tab_layout.compute(layout_inputs);
        return tab_layout.hitRenameText(
            @floatFromInt(x),
            @floatFromInt(y),
            layout,
            @floatFromInt(self.renderer.tabWidthPx()),
            @floatFromInt(self.renderer.tabPaddingPx()),
            @floatFromInt(self.renderer.tabCloseSizePx()),
            @floatFromInt(self.effectiveTabBarHeightPx()),
            self.tab_scroll_x,
            @intCast(session.count()),
            self.rename_state.tab_index,
        );
    }

    /// seat 와 data_device_manager 가 모두 있으면 wl_data_device 객체 생성.
    /// clipboard 의 선결 조건. 없으면 자동 copy / paste 불가하지만 terminal 자체는
    /// 정상 — graceful degrade.
    fn createDataDeviceIfAvailable(self: *Client) !void {
        if (self.data_device_id != 0) return;
        if (self.seat_id == 0 or self.data_device_manager_id == 0) return;
        self.data_device_id = self.allocId();
        try self.sendArgs(
            self.data_device_manager_id,
            wl_data_device_manager_request_get_data_device,
            &.{ self.data_device_id, self.seat_id },
        );
    }

    fn createShellObjects(self: *Client) !void {
        self.surface_id = self.allocId();
        try self.sendNewId(self.compositor_id, 0, self.surface_id);
        // `set_opaque_region` 으로 surface 가 alpha 블렌딩 없이 직접 composite
        // 되도록. opacity_alpha==255 (= 100%) 일 때만. compositor 는 ARGB8888
        // buffer 라도 모든 픽셀이 opaque 임을 알면 background 합성 단계를
        // 생략 → fractional scale 환경 (KDE 170%) 에서 타이핑마다 flicker
        // (배경 비침) 추적, sub-pixel 스케일링 + alpha blending 의 race 가
        // 후보. region 의 좌표는 surface-local — 큰 rectangle 로 보내면 KWin
        // 이 surface 영역으로 clip. region object 는 set 직후 destroy 가능
        // (surface state 로 copy 된다 — spec).
        if (self.renderer.opacity_alpha == 255) {
            const region_id = self.allocId();
            // wl_compositor.create_region (opcode 1).
            try self.sendNewId(self.compositor_id, 1, region_id);
            // wl_region.add (opcode 1) — (x, y, w, h). 65535 = 모든 실용적 화면 cover.
            try self.sendArgs(region_id, 1, &.{ 0, 0, 65535, 65535 });
            // wl_surface.set_opaque_region (opcode 4).
            try self.sendArgs(self.surface_id, 4, &.{region_id});
            // wl_region.destroy (opcode 0) — pending state 는 surface 가 보유.
            try self.sendNoArgs(region_id, 0);
        }
        // fractional scaling — surface 생성 직후 viewport + fractional_scale 객체
        // 생성. compositor 가 두 protocol 다 advertise 한 경우만. preferred_scale
        // event 는 이후 비동기 — `createLayerSurface` 의 첫 commit 전후로 도착.
        if (self.viewporter_id != 0) {
            self.viewport_id = self.allocId();
            try self.sendArgs(
                self.viewporter_id,
                wp_viewporter_request_get_viewport,
                &.{ self.viewport_id, self.surface_id },
            );
        }
        if (self.fractional_scale_manager_id != 0) {
            self.fractional_scale_id = self.allocId();
            try self.sendArgs(
                self.fractional_scale_manager_id,
                wp_fractional_scale_manager_v1_request_get_fractional_scale,
                &.{ self.fractional_scale_id, self.surface_id },
            );
            // preferred_scale event 를 *첫 sendLayerSurfaceLayout 이전에* 받기 위한
            // roundtrip. 안 그러면 default scale=120 으로 logical 계산해 KWin 에 잘못된
            // 첫 layout 송신 (예: 1.7x 환경에서 margin_left=1920 logical = screen 절반
            // 보다 큼). KWin 이 그걸 받아 logical_w=339 같은 비정상 첫 configure 응답
            // → preferred_scale event 받은 후 우리가 재송신해 정정되지만, 그 사이 인접
            // xdg-shell window 의 Quick Tile work area 가 잘못된 첫 configure 기준으로
            // 잡혀 ~10-20 physical pixel 갭 발생 가능 (3차 시연 cycle 발견).
            // fractional_scale advertise 안 한 환경 (mutter / wlroots) 에선 이 branch
            // skip — `preferred_scale` 가 default 120 그대로 유효 (no-op 변환).
            try self.roundtrip();
        }
        if (self.layer_shell_id != 0) {
            try self.createLayerSurface();
        } else {
            try self.createXdgToplevel();
        }
    }

    /// L8-α — xdg-shell toplevel 경로. compositor 가 `zwlr_layer_shell_v1` 을
    /// advertise 안 한 경우 (예: GNOME mutter). normal desktop window 로 동작.
    fn createXdgToplevel(self: *Client) !void {
        self.xdg_surface_id = self.allocId();
        try self.sendArgs(self.wm_base_id, 2, &.{ self.xdg_surface_id, self.surface_id });
        self.toplevel_id = self.allocId();
        try self.sendNewId(self.xdg_surface_id, 1, self.toplevel_id);
        try self.sendString(self.toplevel_id, 2, "TildaZ");
        try self.sendString(self.toplevel_id, 3, "tildaz");
        try self.sendNoArgs(self.surface_id, 6);
        log.appendLine("wayland", "shell objects (xdg) surface_id={} xdg_surface_id={} toplevel_id={}", .{
            self.surface_id,
            self.xdg_surface_id,
            self.toplevel_id,
        });
    }

    /// L8-α — wlr-layer-shell drop-down surface 경로. compositor 가
    /// `zwlr_layer_shell_v1` advertise 한 경우. config 의 dock_position /
    /// width_percent / height_percent / offset_percent 를 anchor / size /
    /// margin 으로 변환해 송신. L8-γ slide animation 은 SPEC 아님,
    /// L9 portal hotkey toggle 은 별도.
    fn createLayerSurface(self: *Client) !void {
        self.layer_surface_id = self.allocId();
        // get_layer_surface(new_id, surface, output=NULL, layer=TOP, namespace)
        // output=0 → compositor 가 현재 monitor 선택 (보통 pointer / focus).
        var msg = Msg.init(self.layer_shell_id, zwlr_layer_shell_v1_request_get_layer_surface);
        try msg.putU32(self.layer_surface_id);
        try msg.putU32(self.surface_id);
        try msg.putU32(0);
        try msg.putU32(zwlr_layer_shell_layer_top);
        try msg.putString("tildaz");
        try msg.send(self.stream);

        try self.sendLayerSurfaceLayout();
    }

    /// layer-surface 의 set_anchor / set_size / set_exclusive_zone / set_margin
    /// / set_keyboard_interactivity + commit 묶음. createLayerSurface 의 초기
    /// 송신 + preferred_scale event 받은 후 재송신 둘 다 사용.
    ///
    /// fractional scaling 시점 문제 — createShellObjects 의 첫 commit 시점에
    /// preferred_scale event 가 아직 도착 안 했을 수 있다 (compositor 가 우리
    /// commit 다음에 send). 이때 physicalToLogical 가 default scale=1.0 으로
    /// no-op → physical 단위 그대로 송신 → KWin 이 logical 단위로 해석해 surface
    /// 가 over-scaled 됨. preferred_scale event handler 가 이 함수 재호출 하면
    /// 새 scale 로 정확히 변환된 layout 송신 + 두 번째 configure event 가 정확.
    fn sendLayerSurfaceLayout(self: *Client) !void {
        if (self.layer_surface_id == 0) return;
        const layout = self.computeLayerLayout();
        // #205 — set_layer 재송신 (kitty workaround pattern, `layer_set_properties`
        // 의 `during_creation=false` 분기). get_layer_surface 시 layer argument
        // 로 지정했지만, KWin Bug 503121 의 remap path 에서 *layer state 도
        // 재송신* 해야 visibility tracking 정확. 이게 빠지면 KWin 이 frame_done
        // 발신해도 surface 시각상 안 그려짐 (사용자 시연 발견).
        // `set_layer` 는 since version 2 — v1 환경 (advertise version 검사) 에선
        // 송신 시 unknown opcode → BrokenPipe protocol error 가 됨 (시연 확정).
        // v2+ 만 송신.
        if (self.caps.layer_shell.version >= 2) {
            try self.sendArgs(
                self.layer_surface_id,
                zwlr_layer_surface_v1_request_set_layer,
                &.{zwlr_layer_shell_layer_top},
            );
        }
        try self.sendArgs(
            self.layer_surface_id,
            zwlr_layer_surface_v1_request_set_anchor,
            &.{layout.anchor},
        );
        // layer-shell spec: set_size / set_margin 은 *surface-local logical pixel*
        // 단위. 우리 layout 은 physical 이라 송신 시 logical 변환.
        const logical_w: u32 = @intCast(self.physicalToLogical(@intCast(layout.width)));
        const logical_h: u32 = @intCast(self.physicalToLogical(@intCast(layout.height)));
        try self.sendArgs(
            self.layer_surface_id,
            zwlr_layer_surface_v1_request_set_size,
            &.{ logical_w, logical_h },
        );
        // set_exclusive_zone(0) — 다른 panel / dock exclusive zone 회피.
        try self.sendArgs(
            self.layer_surface_id,
            zwlr_layer_surface_v1_request_set_exclusive_zone,
            &.{0},
        );
        // set_margin — logical. cross-axis 위치 결정.
        var margin_msg = Msg.init(self.layer_surface_id, zwlr_layer_surface_v1_request_set_margin);
        try margin_msg.putI32(self.physicalToLogical(layout.margin_top));
        try margin_msg.putI32(self.physicalToLogical(layout.margin_right));
        try margin_msg.putI32(self.physicalToLogical(layout.margin_bottom));
        try margin_msg.putI32(self.physicalToLogical(layout.margin_left));
        try margin_msg.send(self.stream);
        // set_keyboard_interactivity(exclusive) — drop-down 본분. yakuake /
        // guake 등 모든 Linux drop-down terminal 의 표준. mac/win 의 z-order
        // 양보 (#195) 는 layer-shell categorical 라 Linux 적용 불가 platform-limit.
        try self.sendArgs(
            self.layer_surface_id,
            zwlr_layer_surface_v1_request_set_keyboard_interactivity,
            &.{zwlr_layer_surface_keyboard_interactivity_exclusive},
        );
        // wl_surface.commit (opcode 6) — pending double-buffered state 적용.
        try self.sendNoArgs(self.surface_id, 6);

        log.appendLine("wayland", "shell objects (layer-shell) surface_id={} layer_surface_id={} dock={s} screen={}x{} scale={d}/120 anchor=0x{x} size={}x{} (logical {}x{}) margin=({},{},{},{}) keyboard_interactivity=exclusive", .{
            self.surface_id,
            self.layer_surface_id,
            @tagName(self.config.dock_position),
            self.screen_width,
            self.screen_height,
            self.preferred_scale,
            layout.anchor,
            layout.width,
            layout.height,
            logical_w,
            logical_h,
            layout.margin_top,
            layout.margin_right,
            layout.margin_bottom,
            layout.margin_left,
        });
    }

    /// L8-β — config 의 dock_position / width_percent / height_percent /
    /// offset_percent 를 layer-shell 의 anchor mask / set_size args / margin
    /// args 로 변환. mac `screenFrameForDock` 와 동등 시각 결과 — 한 축 anchor
    /// 두 edge 면 stretch, 한 edge 면 percent 기반 size + cross-axis margin.
    fn computeLayerLayout(self: *const Client) LayerLayout {
        const cfg = self.config;
        const sw_i: i32 = if (self.screen_width > 0) self.screen_width else screen_fallback_width;
        const sh_i: i32 = if (self.screen_height > 0) self.screen_height else screen_fallback_height;
        const sw_f: f32 = @floatFromInt(sw_i);
        const sh_f: f32 = @floatFromInt(sh_i);
        const off_pct = std.math.clamp(cfg.offset_percent, 0.0, 100.0);
        const want_w: u32 = pctToPx(sw_f, cfg.width_percent);
        const want_h: u32 = pctToPx(sh_f, cfg.height_percent);
        const want_w_i: i32 = @intCast(@min(want_w, @as(u32, std.math.maxInt(i32))));
        const want_h_i: i32 = @intCast(@min(want_h, @as(u32, std.math.maxInt(i32))));
        // 가로/세로 점유율이 거의 100 이면 opposing edge 두 개 anchor —
        // compositor 가 자동 stretch. size 의 해당 축은 0 으로 (spec: anchor 가
        // 양 edge 에 잡힌 축은 set_size 무시).
        const stretch_w = cfg.width_percent >= stretch_threshold_pct;
        const stretch_h = cfg.height_percent >= stretch_threshold_pct;

        const a_top = zwlr_layer_surface_anchor_top;
        const a_bottom = zwlr_layer_surface_anchor_bottom;
        const a_left = zwlr_layer_surface_anchor_left;
        const a_right = zwlr_layer_surface_anchor_right;

        // dock_position 별 anchor / size / margin. 두 축 각각 stretch (full 점유)
        // / single edge anchor (percent 점유) 의 4 조합. 두 축 stretch 면 모든
        // edge anchor + size=(0, 0), 한 축 stretch 면 그 축의 opposing 두 edge +
        // 다른 축의 single edge + size=(0 / w_or_h, 0 / w_or_h). 두 축 모두
        // single edge 면 corner anchor + 명시 size + margin 으로 cross-axis 이동.
        //
        // height_percent=100 일 때 size.height=0 + 양 edge anchor (top+bottom) →
        // mac `usable_height = visibleFrame.maxY - visibleFrame.minY` 와 동등 —
        // compositor 가 다른 panel 의 exclusive zone honor 한 영역 안에서 stretch
        // (KDE Plasma 의 floating dock 등도 자동 회피). size 를 명시하면 compositor
        // 가 그대로 깔아서 dock 영역까지 침범 — Plasma 시연으로 확인된 패턴.
        // 가로/세로 양 edge 의 margin 을 *둘 다* 지정해 4-edge anchor + size=0
        // 패턴으로 보낸다. 한 축 stretch + 한 축 partial 케이스도 동일 — 양쪽
        // margin 모두 지정 (한 쪽은 0). 이유: width / margin 둘 다 physical →
        // logical 변환을 거치는데 KWin 이 받은 두 logical 값을 *각각* round-trip
        // 하면 누적 오차로 인접 surface 와 1-2px 갭. 4-edge anchor + 양쪽 margin
        // 만 보내면 surface width 는 KWin 이 `screen_logical − margin_l − margin_r`
        // 로 자체 계산 → margin 두 개의 rounding error 만 합산되고, 반대편 edge
        // 는 정확히 screen edge 에 fit. width 차이를 *외형* 가 아닌 *margin 차이*
        // 로 표현하는 게 핵심.
        const margin_h_extra = sw_i - want_w_i; // cross-axis 빈 공간 (가로)
        const margin_v_extra = sh_i - want_h_i; // cross-axis 빈 공간 (세로)
        const ml = pxOffset(margin_h_extra, off_pct);
        const mr = margin_h_extra - ml;
        const mt = pxOffset(margin_v_extra, off_pct);
        const mb = margin_v_extra - mt;

        return switch (cfg.dock_position) {
            .top => LayerLayout{
                .anchor = a_top | a_bottom | a_left | a_right,
                .width = 0,
                .height = 0,
                .margin_top = 0,
                .margin_right = mr,
                .margin_bottom = if (stretch_h) 0 else (sh_i - want_h_i),
                .margin_left = ml,
            },
            .bottom => LayerLayout{
                .anchor = a_top | a_bottom | a_left | a_right,
                .width = 0,
                .height = 0,
                .margin_top = if (stretch_h) 0 else (sh_i - want_h_i),
                .margin_right = mr,
                .margin_bottom = 0,
                .margin_left = ml,
            },
            .left => LayerLayout{
                .anchor = a_top | a_bottom | a_left | a_right,
                .width = 0,
                .height = 0,
                .margin_top = mt,
                .margin_right = if (stretch_w) 0 else (sw_i - want_w_i),
                .margin_bottom = mb,
                .margin_left = 0,
            },
            .right => LayerLayout{
                .anchor = a_top | a_bottom | a_left | a_right,
                .width = 0,
                .height = 0,
                .margin_top = mt,
                .margin_right = 0,
                .margin_bottom = mb,
                .margin_left = if (stretch_w) 0 else (sw_i - want_w_i),
            },
        };
    }

    /// L8-β — wl_output 의 mode (current flag 인 것만) / done 처리. geometry /
    /// scale 은 아직 안 씀 (HiDPI / rotation 은 후속 sub-step). transform 도
    /// 무시 — 일반 monitor 의 default 0 (normal) 가정.
    fn handleOutputEvent(self: *Client, opcode: u16, payload: []const u8) !void {
        switch (opcode) {
            wl_output_event_mode => {
                if (payload.len < 16) return;
                const flags = readU32(payload[0..4]);
                if ((flags & wl_output_mode_flag_current) == 0) return;
                self.screen_width = readI32(payload[4..8]);
                self.screen_height = readI32(payload[8..12]);
                log.appendLine("wayland", "output mode width={} height={} refresh={}", .{
                    self.screen_width,
                    self.screen_height,
                    readI32(payload[12..16]),
                });
            },
            // geometry / done / scale 은 layer-shell layout 에 직접 안 씀.
            else => {},
        }
    }

    fn waitForConfigure(self: *Client) !void {
        while (!self.configured) {
            try self.readAndDispatch();
        }
    }

    fn allocId(self: *Client) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// fractional scaling 변환. 우리 코드 내부 단위 = physical pixel. compositor
    /// 와 I/O 시 logical 단위로 변환 / 역변환. KDE Plasma 6 의 170% 환경에서
    /// preferred_scale=204 (= 120×1.7) → logical_w × 204 / 120 = physical_w.
    /// fallback (advertise 안 된 compositor): preferred_scale=120 → no-op.
    fn logicalToPhysical(self: *const Client, logical: i32) i32 {
        const num: i32 = @intCast(self.preferred_scale);
        const den: i32 = @intCast(fractional_scale_denominator);
        return @divFloor(logical * num, den);
    }

    fn physicalToLogical(self: *const Client, physical: i32) i32 {
        const num: i32 = @intCast(self.preferred_scale);
        const den: i32 = @intCast(fractional_scale_denominator);
        // fractional scale 환경의 logical 추정 — `preferred_scale / 120` 비율
        // 로 physical → logical. 단 KWin 내부의 정확한 screen_logical 과 round
        // 정책 차이로 1px 오차 가능 — fallback 용. xdg-output-unstable-v1 의
        // `logical_size` event 가 와서 `screen_logical_*` 이 채워지면 layout
        // 계산은 그 정확한 값을 직접 사용 (이 함수 미사용).
        if (physical <= 0) return 0;
        return @divFloor(physical * den, num);
    }

    fn applyPendingSize(self: *Client) void {
        if (self.pending_width > 0) self.window_width = @max(self.pending_width, min_width);
        if (self.pending_height > 0) self.window_height = @max(self.pending_height, min_height);
    }

    fn requestRedraw(self: *Client) void {
        self.needs_redraw = true;
    }

    fn maybeRedraw(self: *Client) !void {
        if (!self.needs_redraw) return;
        if (try self.redraw()) {
            self.needs_redraw = false;
        }
    }

    fn gridSize(self: *const Client) struct { cols: u16, rows: u16 } {
        const cw = self.renderer.cellWidth();
        const ch = self.renderer.cellHeight();
        const pad = self.renderer.paddingPx();
        const tab_bar_h = self.effectiveTabBarHeightPx();
        const usable_w = @max(cw, self.window_width - pad * 2);
        // L12-α — 상단 tab bar 영역만큼 grid height 축소. 단일 탭이면
        // `effectiveTabBarHeightPx` 가 0 → 탭바 자리 안 띄움 (#127, mac /
        // Win 동등).
        const usable_h = @max(ch, self.window_height - tab_bar_h - pad * 2);
        const cols_i32 = @max(1, @divTrunc(usable_w, cw));
        const rows_i32 = @max(1, @divTrunc(usable_h, ch));
        return .{
            .cols = @intCast(@min(cols_i32, std.math.maxInt(u16))),
            .rows = @intCast(@min(rows_i32, std.math.maxInt(u16))),
        };
    }

    /// 현재 세션 탭 수 기준 탭바 픽셀 높이. `Renderer.tabBarHeightPx(count)`
    /// 가 count < 2 시 0 반환 (#127, mac `tabBarHeightPx` / Win
    /// `effectiveTabBarHeight` 동등). 세션 미초기화면 count = 0 으로 자연 0.
    fn effectiveTabBarHeightPx(self: *const Client) i32 {
        const count: usize = if (self.session) |*s| s.count() else 0;
        return self.renderer.tabBarHeightPx(count);
    }

    /// #205 — boot phase elapsed log. `boot_timer` 가 `runBaselineWindow` 진입에
    /// start 됐을 때만 동작. 사용자 *체감* 1-2 sec startup latency 가 어느
    /// phase 에 모이는지 확정 위한 진단.
    fn logBootElapsed(self: *Client, phase: []const u8) void {
        if (self.boot_timer) |*t| {
            const elapsed_ms = t.read() / std.time.ns_per_ms;
            log.appendLine("startup", "boot phase={s} elapsed={d}ms (#205)", .{ phase, elapsed_ms });
        }
    }

    /// #205 — show phase elapsed log. `show_timer` 는 매 `handleActivatedToggle`
    /// show 분기 시작에 reset. portal Activated → first frame 까지.
    fn logShowElapsed(self: *Client, phase: []const u8) void {
        if (self.show_timer) |*t| {
            const elapsed_ms = t.read() / std.time.ns_per_ms;
            log.appendLine("startup", "show phase={s} elapsed={d}ms (#205)", .{ phase, elapsed_ms });
        }
    }

    fn ensureSessionGrid(self: *Client) !void {
        const grid = self.gridSize();
        if (self.session) |*session| {
            if (session.activeTab()) |tab| {
                if (tab.terminal.cols != grid.cols or tab.terminal.rows != grid.rows) {
                    session.resizeAll(grid.cols, grid.rows);
                    log.appendLine("linux", "terminal resized cols={} rows={}", .{ grid.cols, grid.rows });
                }
            }
            return;
        }

        const theme = self.config.theme orelse fallback_theme;
        self.session = session_core.SessionCore.init(
            self.allocator,
            self.config.shell,
            self.config.max_scroll_lines,
            theme,
            &self.extra_env_storage,
            linuxTabExit,
            self,
        );
        try self.session.?.createTab(grid.cols, grid.rows);
        log.appendLine("linux", "terminal session created cols={} rows={}", .{ grid.cols, grid.rows });
    }

    fn redraw(self: *Client) !bool {
        // L9-γ hide / show — layer-shell spec 의 re-map sequence 준수:
        // 1. hide path 가 `surface_hidden=true` set → 어떤 attach 도 skip.
        // 2. show path 가 `surface_hidden=false` + `configured=false` + commit
        //    only → compositor 가 new configure event 발신. configure handler
        //    가 `configured=true` set + requestRedraw.
        // 3. 그 사이 (`surface_hidden=false` 인데 `configured=false`) 의 main
        //    loop iteration 에선 *어떤 attach 도 skip* — 아니면 protocol error
        //    "a buffer has been attached to a layer surface prior to the
        //    first layer_surface.configure event".
        if (self.surface_hidden) return false;
        if (!self.configured) return false;
        // issue #196: compositor 의 frame callback 받기 전엔 다음 commit skip
        // — fast typing 시 over-commit 차단 (60Hz 보다 빠르게 commit 안 함).
        // `needs_redraw` 는 true 로 유지되어 callback 도착 후 다음 main loop
        // iter 가 자연스럽게 redraw 진행.
        if (self.awaiting_frame) return false;
        self.applyPendingSize();
        self.discardReleasedRetiredBuffersExcept(self.window_width, self.window_height);
        // #205 B-phase 진단 — show_timer valid (= show 의 첫 frame 까지) 동안만
        // 3 phase elapsed log: paint / commit / frame_done. show_timer null 면
        // 모든 호출 no-op (logShowElapsed 안 가드). spam 차단.
        self.logShowElapsed("redraw begin");
        if (self.active_buffer) |*buffer| {
            if (buffer.width == self.window_width and buffer.height == self.window_height) {
                if (buffer.released) {
                    self.paintBuffer(buffer.memory, buffer.width, buffer.height, buffer.stride);
                    self.logShowElapsed("paint done (reuse)");
                    try self.attachAndCommit(buffer.*);
                    self.logShowElapsed("commit done (reuse)");
                    buffer.released = false;
                    self.mapped = true;
                    return true;
                }
            }
        }

        var buffer = if (self.takeReusableBuffer(self.window_width, self.window_height)) |reusable|
            reusable
        else blk: {
            if (self.bufferCountForSize(self.window_width, self.window_height) >= max_buffers_per_size) return false;
            break :blk try self.createBuffer(self.window_width, self.window_height);
        };
        errdefer {
            self.destroyBufferObject(buffer.id);
            buffer.deinit();
        }
        self.paintBuffer(buffer.memory, buffer.width, buffer.height, buffer.stride);
        self.logShowElapsed("paint done (new buf)");
        try self.retireActiveBuffer();
        try self.attachAndCommit(buffer);
        self.logShowElapsed("commit done (new buf)");
        self.active_buffer = buffer;
        self.mapped = true;
        return true;
    }

    fn retireActiveBuffer(self: *Client) !void {
        if (self.active_buffer) |buffer| {
            if (buffer.released) {
                self.destroyBufferObject(buffer.id);
                var owned = buffer;
                owned.deinit();
            } else {
                try self.retired_buffers.append(self.allocator, buffer);
            }
            self.active_buffer = null;
        }
    }

    fn discardReleasedRetiredBuffersExcept(self: *Client, width: i32, height: i32) void {
        var i: usize = 0;
        while (i < self.retired_buffers.items.len) {
            const buffer = &self.retired_buffers.items[i];
            if (buffer.released and (buffer.width != width or buffer.height != height)) {
                self.destroyBufferObject(buffer.id);
                buffer.deinit();
                _ = self.retired_buffers.orderedRemove(i);
                continue;
            }
            i += 1;
        }
    }

    fn takeReusableBuffer(self: *Client, width: i32, height: i32) ?ShmBuffer {
        for (self.retired_buffers.items, 0..) |*buffer, i| {
            if (buffer.released and buffer.width == width and buffer.height == height) {
                return self.retired_buffers.orderedRemove(i);
            }
        }
        return null;
    }

    fn bufferCountForSize(self: *const Client, width: i32, height: i32) usize {
        var count: usize = 0;
        if (self.active_buffer) |buffer| {
            if (buffer.width == width and buffer.height == height) count += 1;
        }
        for (self.retired_buffers.items) |buffer| {
            if (buffer.width == width and buffer.height == height) count += 1;
        }
        return count;
    }

    fn createBuffer(self: *Client, width: i32, height: i32) !ShmBuffer {
        const stride: i32 = width * 4;
        const size_i32: i32 = stride * height;
        const size: usize = @intCast(size_i32);
        const pool_id = self.allocId();
        const new_buffer_id = self.allocId();

        const fd = try createMemfd("tildaz-wayland-buffer");
        errdefer posix.close(fd);
        try posix.ftruncate(fd, @intCast(size));

        const memory = try posix.mmap(
            null,
            size,
            linux.PROT.READ | linux.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer posix.munmap(memory);

        self.paintBuffer(memory, width, height, stride);

        try self.sendCreatePool(fd, size_i32, pool_id);
        try self.sendArgs(pool_id, 0, &.{
            new_buffer_id,
            0,
            @intCast(width),
            @intCast(height),
            @intCast(stride),
            shm_format_argb8888,
        });
        try self.sendNoArgs(pool_id, 1);

        return .{
            .id = new_buffer_id,
            .fd = fd,
            .memory = memory,
            .width = width,
            .height = height,
            .stride = stride,
            .released = false,
        };
    }

    fn paintBuffer(self: *Client, memory: []u8, width: i32, height: i32, stride: i32) void {
        if (self.session) |*session| {
            if (session.activeTab()) |tab| {
                // Titles slice — stack 의 임시 array. session_core.MAX_TABS (= 32)
                // 안. paint 호출 동안만 valid (각 title slice 는 Tab.title 의 view).
                var titles_storage: [session_core.MAX_TABS][]const u8 = undefined;
                const tabs = session.tabsSlice();
                const count = @min(tabs.len, titles_storage.len);
                for (tabs[0..count], 0..) |t, i| {
                    titles_storage[i] = t.title[0..t.title_len];
                }
                // L12-γ — tab_layout.compute 로 arrow/plus/tab area 영역 분할.
                // override 가 false 면 ensureActiveVisible 로 활성 탭이 보이는
                // 위치로 scroll_x 보정. compute / ensureActiveVisible 둘 다
                // cross-platform pure function — side effect 없음, client field
                // 갱신은 여기서.
                const layout_inputs = tab_layout.Inputs{
                    .viewport_w = @floatFromInt(width),
                    .tab_count = @intCast(count),
                    .tab_w = @floatFromInt(self.renderer.tabWidthPx()),
                    .arrow_w = @floatFromInt(self.renderer.tabArrowWPx()),
                    .plus_w = @floatFromInt(self.renderer.tabPlusWPx()),
                    .scroll_x = self.tab_scroll_x,
                };
                const layout = tab_layout.compute(layout_inputs);
                if (!self.tab_scroll_override) {
                    const sx = tab_layout.ensureActiveVisible(layout_inputs, layout, @intCast(session.active_tab));
                    self.tab_scroll_x = sx;
                }
                self.renderer.paint(
                    self.allocator,
                    memory,
                    width,
                    height,
                    stride,
                    &tab.terminal,
                    self.config.theme orelse fallback_theme,
                    titles_storage[0..count],
                    session.active_tab,
                    layout,
                    self.tab_scroll_x,
                    self.rename_state.view(),
                    self.tab_drag.view(),
                );
                // L10-γ — cursor 위치가 변했으면 server 에 알린다. fcitx5
                // popover (한자 후보, 확장 candidate window 등) 가 우리 cursor
                // 근처에 정렬되도록. error 는 main loop 멈추지 않게 swallow.
                self.updateCursorRectangle() catch {};
                return;
            }
        }
        fillBuffer(memory, width, height, stride);
    }

    fn attachAndCommit(self: *Client, buffer: ShmBuffer) !void {
        // wl_surface.attach (opcode 1) — (buffer_id, x=0, y=0).
        try self.sendArgs(self.surface_id, 1, &.{ buffer.id, 0, 0 });
        // wl_surface.damage_buffer (opcode 9) — viewport 적용된 surface 에서는
        // `wl_surface.damage` (surface-local 좌표) 가 modeled scale 누적으로
        // 부정확. `damage_buffer` 는 buffer-local 좌표 (= physical) 라 viewport
        // 와 무관하게 일관. 시연 사이클 (KDE 170%) 에서 타이핑마다 1-frame
        // 노이즈 (배경 비침) 추적 — `damage` 를 surface coords 로 보내며 viewport
        // scale 의 sub-pixel 정렬과 충돌하던 게 후보.
        try self.sendArgs(self.surface_id, 9, &.{
            0,
            0,
            @intCast(buffer.width),
            @intCast(buffer.height),
        });
        // wl_surface.frame (opcode 3) — compositor 가 next frame 준비됐을 때
        // wl_callback.done 발신. spec 상 *commit 전에* request — pending state
        // 의 일부로 atomic 적용. issue #196: KDE Plasma 6 fractional scaling
        // 의 잔류 flicker (타이핑 burst 마다 짧은 시각 disturbance) 대응.
        // 미throttle 하면 user typing 속도 따라 60Hz 보다 빠르게 commit → KWin
        // shader-scaling tick 과 비동기. frame callback 을 한 번 받기 전까지
        // 다음 commit skip 하면 자연스럽게 vsync 와 정렬.
        const callback_id = self.allocId();
        try self.sendNewId(self.surface_id, 3, callback_id);
        self.frame_callback_id = callback_id;
        self.awaiting_frame = true;
        // wl_surface.commit (opcode 6) — pending double-buffered state apply.
        try self.sendNoArgs(self.surface_id, 6);
    }

    fn roundtrip(self: *Client) !void {
        const callback_id = self.allocId();
        self.wait_callback_id = callback_id;
        self.wait_callback_done = false;
        try self.sendNewId(display_id, 0, callback_id);
        while (!self.wait_callback_done) {
            try self.readAndDispatch();
        }
    }

    fn readAndDispatch(self: *Client) !void {
        if (self.input_len == self.input.len) return error.WaylandReadBufferFull;
        const n = try self.recvWaylandBytes(self.input[self.input_len..]);
        if (n == 0) return error.WaylandConnectionClosed;
        self.input_len += n;
        try self.dispatchBuffered();
    }

    fn recvWaylandBytes(self: *Client, buf: []u8) !usize {
        var iov = [_]posix.iovec{.{
            .base = buf.ptr,
            .len = buf.len,
        }};
        var control: [cmsgSpace(@sizeOf(c_int) * 8)]u8 align(@alignOf(Cmsghdr)) = @splat(0);
        var msg = posix.msghdr{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = iov.len,
            .control = &control,
            .controllen = control.len,
            .flags = 0,
        };

        while (true) {
            const rc = linux.recvmsg(self.stream.handle, &msg, linux.MSG.CMSG_CLOEXEC);
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    if ((msg.flags & linux.MSG.CTRUNC) != 0) return error.WaylandControlMessageTruncated;
                    try self.storeReceivedFds(control[0..msg.controllen]);
                    return @intCast(rc);
                },
                .INTR => continue,
                .AGAIN => return 0,
                else => return error.WaylandReadFailed,
            }
        }
    }

    fn storeReceivedFds(self: *Client, control: []const u8) !void {
        var offset: usize = 0;
        while (offset + @sizeOf(Cmsghdr) <= control.len) {
            const hdr: *const Cmsghdr = @ptrCast(@alignCast(control.ptr + offset));
            if (hdr.len < @sizeOf(Cmsghdr) or offset + hdr.len > control.len) return error.WaylandBadControlMessage;
            if (hdr.level == linux.SOL.SOCKET and hdr.type == 1) {
                const data_start = offset + cmsgAlign(@sizeOf(Cmsghdr));
                const data_end = offset + hdr.len;
                var data_offset = data_start;
                while (data_offset + @sizeOf(c_int) <= data_end) : (data_offset += @sizeOf(c_int)) {
                    const fd: *const c_int = @ptrCast(@alignCast(control.ptr + data_offset));
                    try self.received_fds.append(self.allocator, fd.*);
                }
            }
            offset += cmsgAlign(hdr.len);
        }
    }

    fn pollAndDispatch(self: *Client, timeout_ms: i32) !void {
        if (self.input_len > 0) {
            try self.dispatchBuffered();
            return;
        }

        // #198 — wayland fd + toggle listener fd 둘 다 polling. listener fd 가
        // -1 (생성 실패 또는 비활성) 이면 OS poll 이 자동 skip (POSIX 표준).
        var fds = [_]posix.pollfd{
            .{
                .fd = self.stream.handle,
                .events = posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP,
                .revents = 0,
            },
            .{
                .fd = self.toggle_listener_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            },
        };
        const n = try posix.poll(&fds, timeout_ms);
        if (n == 0) return;
        if ((fds[0].revents & posix.POLL.NVAL) != 0) return error.WaylandConnectionClosed;
        if ((fds[0].revents & (posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP)) != 0) {
            try self.readAndDispatch();
        }
        if (self.toggle_listener_fd >= 0 and (fds[1].revents & posix.POLL.IN) != 0) {
            // #198 — `tildaz --toggle` 두 번째 인스턴스로부터 toggle 신호.
            // portal `Activated` 와 같은 path 로 hide/show.
            const did_toggle = single_instance.acceptToggle(self.toggle_listener_fd) catch false;
            if (did_toggle) {
                self.handleActivatedToggle() catch |err| {
                    log.appendLine("toggle-ipc", "handleActivatedToggle failed: {s}", .{@errorName(err)});
                };
            }
        }
    }

    /// dispatchBuffered 의 post-loop 버퍼 compaction — `offset` 바이트만큼 소비한
    /// 뒤 남은 바이트를 buffer 앞으로 당기고 새 length 반환.
    ///
    /// #213 — `input_len - offset` 은 usize 라 `input_len < offset` 이면 underflow
    /// → integer overflow panic. 이 상황은 `handleEvent` 안에서 inner reentrant
    /// `dispatchBuffered` (예: `createDialogSurface` 의 `roundtrip`) 가 공유
    /// `input` 을 *이미* compact 해 `input_len` 을 줄였는데 outer 의 `offset` 은
    /// stale 일 때 발생. 그 경우 inner 가 이미 올바른 remaining 으로 compact 했으니
    /// outer 는 재compact 하지 않고 현재 `input_len` 을 그대로 반환 (1935 루프
    /// 가드의 2 차 방어 대응). 근본 fix 는 dialog open 을 main loop 로 deferred 한
    /// 것 (`drainAboutRequest` / `drainQuitRequest` / `drainPendingDialogDismiss`).
    /// `offset == 0` (소비 없음) / `input_len == offset` (전량 소비, rem=0) 은 정상.
    fn compactInput(input: []u8, input_len: usize, offset: usize) usize {
        if (offset == 0 or input_len < offset) return input_len;
        const rem = input_len - offset;
        std.mem.copyForwards(u8, input[0..rem], input[offset..input_len]);
        return rem;
    }

    fn dispatchBuffered(self: *Client) !void {
        var offset: usize = 0;
        // #203 Phase C — `offset + 8 <= input_len` 형태로 작성 (이전: `input_len
        // - offset >= 8`). usize 라 input_len < offset 일 때 underflow → 거대한
        // 값 → loop 재진입 → garbage parse → BadMessage. inner reentrancy 가
        // outer state 를 corrupt 시키는 경로 (사용자 시연 진단으로 확정) 의 2 차
        // 방어. inner reentrancy 자체는 `pending_dialog_dismiss` 로 차단.
        while (offset + 8 <= self.input_len) {
            const id = readU32(self.input[offset..][0..4]);
            const word = readU32(self.input[offset + 4 ..][0..4]);
            const opcode: u16 = @intCast(word & 0xffff);
            const size: usize = @intCast(word >> 16);
            if (size < 8 or size > self.input.len) return error.WaylandBadMessage;
            if (self.input_len - offset < size) break;
            try self.handleEvent(id, opcode, self.input[offset + 8 .. offset + size]);
            offset += size;
        }

        self.input_len = compactInput(&self.input, self.input_len, offset);
    }

    fn handleEvent(self: *Client, id: u32, opcode: u16, payload: []const u8) !void {
        if (id == display_id) {
            if (opcode == 0) return self.handleDisplayError(payload);
            return;
        }
        if (id == registry_id) {
            if (opcode == 0) try self.handleRegistryGlobal(payload);
            return;
        }
        if (id == self.wait_callback_id and opcode == 0) {
            self.wait_callback_done = true;
            return;
        }
        // issue #196: frame callback done — compositor 가 next frame 준비됨.
        // commit gate 해제. callback id 는 one-shot 이라 한 번 받으면 reset.
        if (self.frame_callback_id != 0 and id == self.frame_callback_id and opcode == 0) {
            self.awaiting_frame = false;
            self.frame_callback_id = 0;
            // #205 — show path 의 *visible 까지* 측정. boot path 의 first frame
            // elapsed 와 다른 metric: compositor 가 우리 buffer 를 화면에 그리고
            // next frame ready 신호. 사용자 perception "show 가 느림" 의 객관
            // 측정 (createShellObjects~configure 까지의 0ms vs visible 까지의
            // 실제 시간 격차 잡기). first frame done 후 timer null 로 매 frame
            // spam 차단 — 다음 show 분기 진입 시 handleActivatedToggle 가 재
            // start.
            self.logShowElapsed("first frame done");
            self.show_timer = null;
            return;
        }
        if (id == self.shm_id and opcode == 0 and payload.len >= 4) {
            const fmt = readU32(payload[0..4]);
            if (fmt == shm_format_xrgb8888) self.saw_xrgb8888 = true;
            if (fmt == shm_format_argb8888) self.saw_argb8888 = true;
            return;
        }
        if (id == self.seat_id) {
            try self.handleSeatEvent(opcode, payload);
            return;
        }
        if (id == self.keyboard_id) {
            try self.handleKeyboardEvent(opcode, payload);
            return;
        }
        if (self.text_input_id != 0 and id == self.text_input_id) {
            try self.handleTextInputEvent(opcode, payload);
            return;
        }
        if (self.pointer_id != 0 and id == self.pointer_id) {
            try self.handlePointerEvent(opcode, payload);
            return;
        }
        if (self.data_device_id != 0 and id == self.data_device_id) {
            try self.handleDataDeviceEvent(opcode, payload);
            return;
        }
        if (self.active_data_source_id != 0 and id == self.active_data_source_id) {
            try self.handleDataSourceEvent(opcode, payload);
            return;
        }
        if (self.pending_offer_id != 0 and id == self.pending_offer_id) {
            try self.handleDataOfferEvent(opcode, payload, true);
            return;
        }
        if (self.paste_offer_id != 0 and id == self.paste_offer_id) {
            try self.handleDataOfferEvent(opcode, payload, false);
            return;
        }
        if (self.handleBufferEvent(id, opcode)) return;
        if (self.output_id != 0 and id == self.output_id) {
            try self.handleOutputEvent(opcode, payload);
            return;
        }
        // #203 Phase C — xdg_activation_token_v1.done(token: string) event.
        // get_activation_token 후 한 번만 도착. payload = length(u32) + utf8
        // bytes + padding. dismissDialog 의 roundtrip 가 done event 받을 때까지
        // pump → 이후 activate(token, main_surface) 송신.
        if (self.pending_activation_token_id != 0 and id == self.pending_activation_token_id and opcode == xdg_activation_token_v1_event_done) {
            var p = Parser{ .buf = payload };
            const token = p.readString() catch return;
            self.pending_activation_token.clearRetainingCapacity();
            self.pending_activation_token.appendSlice(self.allocator, token) catch return;
            self.pending_activation_token_done = true;
            return;
        }
        // #210 — dialog 의 fractional_scale 객체 event 도 같은 path 처리. 같은
        // output 의 preferred_scale 라 같은 변수 갱신. 단 layout 재송신은 dialog
        // 가 별 path — handleDialogConfigure 가 자체 logicalToPhysical 사용.
        const matches_main = self.fractional_scale_id != 0 and id == self.fractional_scale_id;
        const matches_dialog = self.dialog.fractional_scale_id != 0 and id == self.dialog.fractional_scale_id;
        if (matches_main or matches_dialog) {
            if (opcode == wp_fractional_scale_v1_event_preferred_scale and payload.len >= 4) {
                const new_scale = readU32(payload[0..4]);
                if (new_scale != self.preferred_scale and new_scale > 0) {
                    self.preferred_scale = new_scale;
                    log.appendLine("wayland", "fractional scale preferred={d}/120 (≈{d}.{d:0>2}x) source={s}", .{
                        new_scale,
                        new_scale / 120,
                        (new_scale * 100 / 120) % 100,
                        if (matches_dialog) "dialog" else "main",
                    });
                    // renderer scale apply — main / dialog 든 같은 output 의 scale.
                    // dialog event 가 먼저 도착해도 (boot 중 Hotkey updated)
                    // renderer 의 scale 갱신 필요. paint 가 1x layout 그리면
                    // 큰 buffer 안 작은 content (#210 사용자 시연 발견). 두 번째
                    // 호출은 new_scale 같으면 이 분기 자체 안 들어옴 (no-op).
                    self.renderer.applyScale(
                        self.allocator,
                        self.config,
                        new_scale,
                        fractional_scale_denominator,
                    ) catch |err| {
                        log.appendLine("wayland", "renderer applyScale failed: {s} — keeping default scale", .{@errorName(err)});
                    };
                    // layer surface 재송신 + grid 재계산. main 없으면 skip
                    // (boot 중 dialog 가 main 이전 created 시점).
                    if (self.layer_surface_id != 0) {
                        try self.sendLayerSurfaceLayout();
                    }
                    if (self.session != null) try self.ensureSessionGrid();
                    self.requestRedraw();
                }
            }
            return;
        }
        if (id == self.wm_base_id and opcode == 0 and payload.len >= 4) {
            try self.sendArgs(self.wm_base_id, 3, &.{readU32(payload[0..4])});
            return;
        }
        if (self.toplevel_id != 0 and id == self.toplevel_id and opcode == 0) {
            try self.handleToplevelConfigure(payload);
            return;
        }
        if (self.toplevel_id != 0 and id == self.toplevel_id and opcode == 1) {
            // step 4 — xdg-shell toplevel close 도 quit confirm 거침. KWin /
            // GNOME mutter 의 Alt+F4 가 fallback 경로일 때 (= xdg-shell mode).
            log.appendLine("input", "xdg-shell toplevel close — set pending_quit_request", .{});
            self.pending_quit_request = true;
            return;
        }
        if (self.xdg_surface_id != 0 and id == self.xdg_surface_id and opcode == 0 and payload.len >= 4) {
            try self.sendArgs(self.xdg_surface_id, 4, &.{readU32(payload[0..4])});
            // issue #196: configure 는 surface 가 다시 보이거나 크기 변경된
            // 신호 — 이전 frame callback 이 fire 안 했을 수도 있으므로 reset.
            self.awaiting_frame = false;
            self.frame_callback_id = 0;
            self.applyPendingSize();
            if (self.viewport_id != 0 and self.window_width > 0 and self.window_height > 0) {
                const dw: u32 = @intCast(self.physicalToLogical(self.window_width));
                const dh: u32 = @intCast(self.physicalToLogical(self.window_height));
                try self.sendArgs(
                    self.viewport_id,
                    wp_viewport_request_set_destination,
                    &.{ dw, dh },
                );
            }
            if (self.session != null) try self.ensureSessionGrid();
            self.configured = true;
            if (self.mapped) self.requestRedraw();
            return;
        }
        // #203 Phase C — dialog layer-surface events. main layer-surface 와
        // 동일 protocol (`zwlr_layer_surface_v1`) — opcode / payload 동등. main
        // 분기 *앞에* 위치 — dialog 가 inactive (id=0) 일 때만 main 분기 fall
        // through. closed event 시 dismiss (compositor 측 dismiss 가능성).
        if (self.dialog.layer_surface_id != 0 and id == self.dialog.layer_surface_id) {
            if (opcode == zwlr_layer_surface_v1_event_configure and payload.len >= 12) {
                const serial = readU32(payload[0..4]);
                const w = readU32(payload[4..8]);
                const h = readU32(payload[8..12]);
                try self.handleDialogConfigure(serial, w, h);
                return;
            }
            if (opcode == zwlr_layer_surface_v1_event_closed) {
                log.appendLine("dialog", "dialog layer-surface closed by compositor", .{});
                self.requestDismissDialog();
                return;
            }
        }
        // L8-α — zwlr_layer_surface_v1 events. configure(serial, w, h) 와
        // closed 두 가지. configure 는 xdg_surface configure 와 동일한 ack
        // + size apply 흐름이지만 ack opcode 가 6 (xdg 는 4), payload 도
        // (serial + w + h) 합쳐서 12 바이트.
        if (self.layer_surface_id != 0 and id == self.layer_surface_id) {
            if (opcode == zwlr_layer_surface_v1_event_configure and payload.len >= 12) {
                const serial = readU32(payload[0..4]);
                const w = readU32(payload[4..8]);
                const h = readU32(payload[8..12]);
                // issue #196: configure 는 surface 재출현 / 크기 변경 신호 —
                // 이전 frame callback 이 fire 안 했을 수도 있으므로 reset.
                self.awaiting_frame = false;
                self.frame_callback_id = 0;
                // 진단 — KWin 이 우리 anchor + margin 설정을 받아 계산한 surface
                // 의 logical 크기. 우리가 보낸 margin 의 합과 screen logical
                // 크기 사이 mismatch 가 보이면 KWin 의 round 정책 추정 가능.
                log.appendLine("wayland", "layer-surface configure serial={} logical_w={} logical_h={} scale={d}/120", .{
                    serial,
                    w,
                    h,
                    self.preferred_scale,
                });
                try self.sendArgs(self.layer_surface_id, zwlr_layer_surface_v1_request_ack_configure, &.{serial});
                // compositor 가 0 으로 보내면 "you decide" — 기존 size 유지.
                // 보통은 anchor L+R 기반 full screen width + 우리 요청 height
                // 그대로 돌려보냄. w/h 는 *logical pixel* (layer-shell spec).
                // 우리 코드 내부는 physical 이라 변환.
                const w_logical: i32 = @intCast(@min(w, @as(u32, std.math.maxInt(i32))));
                const h_logical: i32 = @intCast(@min(h, @as(u32, std.math.maxInt(i32))));
                if (w > 0) self.pending_width = self.logicalToPhysical(w_logical);
                if (h > 0) self.pending_height = self.logicalToPhysical(h_logical);
                self.applyPendingSize();
                // viewport.set_destination — compositor 가 우리 buffer (physical)
                // 를 logical surface size 안에 1:1 매핑하게. 호출 안 하면 buffer
                // 가 logical size 로 stretch 되어 흐려짐 (fractional scale 환경).
                if (self.viewport_id != 0 and w > 0 and h > 0) {
                    try self.sendArgs(
                        self.viewport_id,
                        wp_viewport_request_set_destination,
                        &.{ w, h },
                    );
                }
                // hidden_start=true 의 첫 toggle show — handleActivatedToggle 가
                // createShellObjects 만 하고 session 생성은 안 함. 이전 guard
                // `if (self.session != null)` 가 첫 configure 에서 ensureSessionGrid
                // 를 skip 시켜 session 이 영영 안 만들어졌음 (사용자가 fillBuffer
                // gradient 만 봄). ensureSessionGrid 는 idempotent (session 존재
                // 시 resize, null 시 create) — guard 없이 호출 안전.
                try self.ensureSessionGrid();
                self.configured = true;
                self.logShowElapsed("first configure+session");
                // mapped 면 단순 redraw. unmapped + show 대기 (surface_hidden=false)
                // 인 경우도 redraw — hide 후 re-map sequence 의 첫 attach.
                if (self.mapped or !self.surface_hidden) self.requestRedraw();
                return;
            }
            if (opcode == zwlr_layer_surface_v1_event_closed) {
                // step 4 — main layer-surface closed event 가 KWin 의 Alt+F4
                // 단축키 ("Close window") 도 같은 path. 사용자 시연 진단 결과:
                // KWin 이 F4 key event 를 우리에게 보내지 않고 (system shortcut
                // 가로챔) 대신 closed event 발송. 즉 *우리 Alt+F4 keysym 핸들러*
                // 우회. step 4 정책: closed event 도 quit confirm 거침. confirm
                // OK = 종료, Cancel = 사용자가 다시 F1 으로 표시 (현재 단순 path,
                // 후속 polish 에서 자동 main surface 재생성 가능).
                log.appendLine("input", "main layer-surface closed — set pending_quit_request", .{});
                self.pending_quit_request = true;
                return;
            }
        }
    }

    fn handleSeatEvent(self: *Client, opcode: u16, payload: []const u8) !void {
        if (opcode == 0 and payload.len >= 4) {
            self.seat_capabilities = readU32(payload[0..4]);
            if (self.keyboard_id == 0) try self.createKeyboardIfAvailable();
            if (self.pointer_id == 0) try self.createPointerIfAvailable();
            if (self.data_device_id == 0) try self.createDataDeviceIfAvailable();
            return;
        }
    }

    fn handleKeyboardEvent(self: *Client, opcode: u16, payload: []const u8) !void {
        switch (opcode) {
            wl_keyboard_event_keymap => try self.handleKeyboardKeymap(payload),
            // foot terminal 패턴 동등 — enable / disable 은 `text_input.enter
            // / leave` event 시점에만. wl_keyboard.enter / leave 시점은 별도
            // 처리 없음. fcitx5 의 wayland frontend 가 자기 enter/leave event
            // 보내는 시점을 정확히 제어.
            //
            // #203 Phase C — focus surface 만 추적 (text-input 동작 영향 없음).
            // payload[4..8] = surface object id. xdg-activation token 발급 가드
            // (`requestMainFocusViaActivation`) 에서 dialog 가 *실제* keyboard
            // focus 인지 확인 용.
            wl_keyboard_event_enter => {
                if (payload.len >= 8) {
                    self.last_keyboard_focus_surface_id = readU32(payload[4..8]);
                }
            },
            wl_keyboard_event_leave => {
                if (payload.len >= 8) {
                    const left_surface = readU32(payload[4..8]);
                    if (left_surface == self.last_keyboard_focus_surface_id) {
                        self.last_keyboard_focus_surface_id = 0;
                    }
                }
                // L12-γ-5 — focus 떠나면 key repeat timer disarm (release event
                // 못 받는 stuck 방지).
                self.key_repeat_keycode = 0;
                // L12-γ-2 — macOS #175 동등. focus loss = commit (preedit /
                // rename 모두 보존). Escape 만 cancel.
                self.commitPendingInput();
                // 시연 사이클 발견: focus loss 마다 `text_input.disable + commit`
                // 호출하면 fcitx5 가 매 cycle 한글 모드 상태 reset → 사용자가
                // 다시 focus 받았을 때 한글 모드인데 영문만 들어오는 회귀.
                // 다른 wayland terminal (gnome-terminal / kitty) 도 명시 disable
                // 안 보냄 — fcitx5 가 자체 wl_keyboard focus 추적해서 비활성.
                // 우리도 disable 생략 + state 만 동기.
                self.text_input_enabled = false;
                self.last_cursor_rect_x = -1;
            },
            wl_keyboard_event_key => try self.handleKeyboardKey(payload),
            wl_keyboard_event_modifiers => self.handleKeyboardModifiers(payload),
            wl_keyboard_event_repeat_info => self.handleKeyboardRepeatInfo(payload),
            else => {},
        }
    }

    /// L12-β — cross-platform `tab_actions.Host` build. callback ptr 와
    /// override_ptr 가 Client 의 stable 주소를 가리키도록 매 호출 시 fresh.
    /// session 이 null (createTab 전) 이면 fatal — 호출자가 보장해야 한다.
    fn buildTabActionsHost(self: *Client) tab_actions.Host {
        return .{
            .session = &self.session.?,
            .override_ptr = &self.tab_scroll_override,
            .invalidate = linuxTabInvalidate,
            .rename_active = linuxTabRenameActive,
            .insert_rename_cp = linuxTabInsertRenameCp,
            .clipboard_copy = linuxTabClipboardCopy,
            .terminate = linuxTabTerminate,
            .user_data = self,
        };
    }

    /// L12-β — Ctrl+Shift+T 새 탭. 32-tab cap 도달 시 dialog + skip.
    /// L12-γ-2 — macOS `commitPendingInput` 정책 — 단축키 진입 시 진행 중
    /// preedit / rename 을 commit (보존).
    fn handleNewTab(self: *Client) void {
        if (self.session == null) return;
        self.commitPendingInput();
        var host = self.buildTabActionsHost();
        if (tab_actions.checkAtLimitAndDialog(&host)) return;
        const active = self.activeTabOrNull() orelse return;
        self.session.?.createTab(active.terminal.cols, active.terminal.rows) catch |err| {
            log.appendLine("tab", "new tab failed: {s}", .{@errorName(err)});
            return;
        };
        // #127 — 1 → 2 탭 전환 시 탭바 등장으로 cell 영역 변함 → 모든 탭
        // cols/rows 재계산. mac `syncTerminalGeometry` 동등.
        self.ensureSessionGrid() catch |err| {
            log.appendLine("tab", "ensureSessionGrid after new tab failed: {s}", .{@errorName(err)});
        };
        self.tab_scroll_override = false;
        self.needs_redraw = true;
    }

    /// L12-γ-2 — macOS `commitPendingInput` 동등. focus loss / hide / 단축키
    /// 등 "지금 멈춰" 시점에 진행 중인 모든 입력 (cell preedit + rename buf
    /// + IME pending) 을 적절한 곳으로 **commit** (cancel 아님). Escape 만
    /// 명시적 cancel — macOS Cocoa quirk (#175) 동등 정책.
    fn commitPendingInput(self: *Client) void {
        const had_preedit = self.preedit_text.items.len > 0 or self.pending_preedit.items.len > 0;
        // 1) Cell preedit (terminal IME 조합 중) — rename 활성 시 rename buf
        //    으로 자모 commit, 비활성 시 PTY 로 직접 송신.
        if (self.preedit_text.items.len > 0) {
            if (self.rename_state.isActive()) {
                var iter = std.unicode.Utf8Iterator{ .bytes = self.preedit_text.items, .i = 0 };
                while (iter.nextCodepoint()) |cp| {
                    if (cp >= 0x20) _ = self.rename_state.insertCodepoint(cp);
                }
            } else {
                self.queueInput(self.preedit_text.items);
            }
            self.preedit_text.clearRetainingCapacity();
            self.renderer.preedit_text = "";
        }
        // 2) Wayland text-input pending (다음 done 안 온 batch) 도 cleanup.
        self.pending_preedit.clearRetainingCapacity();
        self.pending_commit.clearRetainingCapacity();
        // 3) Rename 활성이면 buf 의 현재 값으로 setCustomTitle (commit).
        if (self.rename_state.isActive()) {
            if (self.session) |*session| {
                if (self.rename_state.commitRequest()) |req| {
                    const tabs = session.tabsSlice();
                    if (req.tab_index < tabs.len) {
                        tabs[req.tab_index].setCustomTitle(req.title);
                    }
                }
            }
            self.rename_state.clear();
        }
        // 4) 시연 사이클 발견: client 가 preedit 자모를 PTY 송신해도 fcitx5
        //    의 internal IME state 의 자모 buffer 는 그대로 남음 → 다음
        //    typing 시 *이전 자모 + 새 자모* 가 한 음절로 commit 됨 (사용자
        //    보고: 터미널 한글 후 탭바 한글 시 터미널 한글이 탭바에 다시 써짐).
        //    text_input.disable + commit → fcitx5 가 자기 IME session 종료
        //    + 자모 buffer 비움. 즉시 enable + commit 으로 새 session 시작.
        if (had_preedit and self.text_input_id != 0 and self.text_input_enabled) {
            self.sendNoArgs(self.text_input_id, text_input_request_disable) catch {};
            self.sendNoArgs(self.text_input_id, text_input_request_commit) catch {};
            self.text_input_enabled = false;
            self.enableTextInput() catch {};
        }
        self.needs_redraw = true;
    }

    /// L12-β — Ctrl+Shift+W. 활성 탭 닫기. 마지막 탭이면 `terminate` 콜백
    /// (= shell_exited true) → main loop 가 종료. 다중 탭이면 그 탭만.
    /// L12-γ-2 — 단축키 진입 시 commitPendingInput.
    fn handleCloseTab(self: *Client) void {
        if (self.session == null) return;
        self.commitPendingInput();
        var host = self.buildTabActionsHost();
        const outcome = tab_actions.closeActive(&host);
        // #127 — 2 → 1 탭 전환 시 탭바 사라지면서 cell 영역 변함. `.changed`
        // 면 grid 재계산. `.ended` 는 main loop 가 종료 처리.
        if (outcome == .changed) {
            self.ensureSessionGrid() catch |err| {
                log.appendLine("tab", "ensureSessionGrid after close failed: {s}", .{@errorName(err)});
            };
        }
    }

    /// L12-β — read thread 가 `pending_close_buf` 에 쌓아둔 ptr 들 main thread
    /// 에서 일괄 처리. `tab_actions.closeByPtr` 의 outcome 가 `.ended` (마지막
    /// 탭) 면 shell_exited true → main loop 종료. `.changed` 면 redraw.
    fn drainExitedTabs(self: *Client) void {
        if (self.session == null) return;
        self.pending_close_mutex.lock();
        const closes = self.pending_close_buf.toOwnedSlice(self.allocator) catch &.{};
        self.pending_close_mutex.unlock();
        defer self.allocator.free(closes);
        if (closes.len == 0) return;

        var host = self.buildTabActionsHost();
        var any_changed = false;
        for (closes) |ptr| switch (tab_actions.closeByPtr(&host, ptr) orelse continue) {
            .ended => {
                log.appendLine("tab", "last tab exited — shutting down", .{});
                self.shell_exited.store(true, .release);
                return;
            },
            .changed => any_changed = true,
        };
        if (any_changed) {
            // #127 — 탭 카운트 변화 시 cell 영역 동기화. 2 → 1 전환이면
            // 탭바 사라짐 → 남은 탭 grid 확장.
            self.ensureSessionGrid() catch |err| {
                log.appendLine("tab", "ensureSessionGrid after drain failed: {s}", .{@errorName(err)});
            };
            self.needs_redraw = true;
        }
    }

    /// L12-β/γ — tab bar 영역 좌클릭. cross-platform `tab_layout.hitArea`
    /// 로 분기 — `<` `>` 화살표 / `+` plus / tab area. tab area 면 hitTab
    /// 으로 어떤 탭인지. close 'x' → closeIndex. 같은 tab 두 번 (500ms 안)
    /// 더블클릭 → rename 모드 시작.
    fn handleTabBarClick(self: *Client, px: i32, py: i32, time_ms: u32) void {
        if (self.session == null) return;
        const session = &self.session.?;
        const tab_w_px = self.renderer.tabWidthPx();
        const tab_pad_px = self.renderer.tabPaddingPx();
        const tab_close_px = self.renderer.tabCloseSizePx();
        const layout_inputs = tab_layout.Inputs{
            .viewport_w = @floatFromInt(self.window_width),
            .tab_count = @intCast(session.count()),
            .tab_w = @floatFromInt(tab_w_px),
            .arrow_w = @floatFromInt(self.renderer.tabArrowWPx()),
            .plus_w = @floatFromInt(self.renderer.tabPlusWPx()),
            .scroll_x = self.tab_scroll_x,
        };
        const layout = tab_layout.compute(layout_inputs);
        const px_f: f32 = @floatFromInt(px);
        const py_f: f32 = @floatFromInt(py);
        const tab_bar_h_f: f32 = @floatFromInt(self.effectiveTabBarHeightPx());
        const area = tab_layout.hitArea(px_f, py_f, tab_bar_h_f, layout);
        switch (area) {
            .left_arrow => {
                if (tab_layout.scrollByArrow(layout_inputs, layout, .left)) |sx| {
                    self.tab_scroll_x = sx;
                    self.tab_scroll_override = true;
                    self.needs_redraw = true;
                }
            },
            .right_arrow => {
                if (tab_layout.scrollByArrow(layout_inputs, layout, .right)) |sx| {
                    self.tab_scroll_x = sx;
                    self.tab_scroll_override = true;
                    self.needs_redraw = true;
                }
            },
            .plus => self.handleNewTab(),
            .tab_area => {
                const hit = tab_layout.hitTab(
                    px_f,
                    py_f,
                    layout,
                    @floatFromInt(tab_w_px),
                    @floatFromInt(tab_pad_px),
                    @floatFromInt(tab_close_px),
                    tab_bar_h_f,
                    self.tab_scroll_x,
                    @intCast(session.count()),
                ) orelse return;
                // SPEC §4.1 — rename 활성 중 *다른* 탭 click (switch / close / drag begin)
                // 진입 시 commitPendingInput. 같은 탭 click 은 cursor 이동 (아래 별
                // 분기) 이라 commit 안 함. 사용자 시연 발견 — 다른 탭바 클릭 시
                // 3번탭 rename 이 commit 안 되어 I-beam 편집 상태 유지되던 버그.
                if (self.rename_state.isActive() and self.rename_state.tab_index != hit.tab_index) {
                    self.commitPendingInput();
                }
                var host = self.buildTabActionsHost();
                if (hit.on_close) {
                    const outcome = tab_actions.closeIndex(&host, hit.tab_index);
                    // #127 — 2 → 1 전환 시 탭바 사라짐 → grid 재계산.
                    if (outcome == .changed) {
                        self.ensureSessionGrid() catch |err| {
                            log.appendLine("tab", "ensureSessionGrid after close 'x' failed: {s}", .{@errorName(err)});
                        };
                    }
                    self.last_tab_click_idx = std.math.maxInt(usize);
                    return;
                }
                // L12-γ-2 — rename 활성 중 같은 탭 클릭 (single) → cursor
                // 위치 이동 (`tab_layout.renameTextHit` byte index). native
                // textbox UX (mac / win 동등).
                if (self.rename_state.isActive() and self.rename_state.tab_index == hit.tab_index) {
                    const tab_w_f: f32 = @floatFromInt(tab_w_px);
                    const tab_pad_f: f32 = @floatFromInt(tab_pad_px);
                    const close_size_f: f32 = @floatFromInt(tab_close_px);
                    const tab_world_x_f: f32 = @as(f32, @floatFromInt(hit.tab_index)) * tab_w_f;
                    const text_x_start_f: f32 = layout.tab_area_x + tab_world_x_f - self.tab_scroll_x + tab_pad_f;
                    const max_text_w_f: f32 = tab_w_f - close_size_f - tab_pad_f * 3;
                    const cw_f: f32 = @floatFromInt(self.renderer.cellWidth());
                    if (tab_layout.renameTextHit(
                        self.rename_state.buf[0..self.rename_state.len],
                        self.rename_state.scroll_offset,
                        text_x_start_f,
                        cw_f,
                        max_text_w_f,
                        px_f,
                    )) |byte_idx| {
                        self.rename_state.setCursor(byte_idx);
                        self.needs_redraw = true;
                        return;
                    }
                }
                // 더블클릭이면 rename 모드 시작 — 같은 tab_index 좌클릭 500ms 안 두 번.
                const is_double = self.last_tab_click_idx == hit.tab_index and
                    (time_ms -% self.last_tab_click_time_ms) <= double_click_threshold_ms;
                self.last_tab_click_idx = hit.tab_index;
                self.last_tab_click_time_ms = time_ms;
                if (is_double) {
                    // L12-γ-2 — begin 전 commitPendingInput. 터미널에서 한글
                    // 조합 중 (cell preedit) 인 상태로 더블클릭 → 자모가 rename
                    // buffer 로 들어가는 회귀 fix. begin 후 호출하면 rename
                    // 활성이라 buffer 행, begin 전 호출이면 rename 비활성이라
                    // PTY 송신 (의도된 commit policy).
                    self.commitPendingInput();
                    const tab = session.tabsSlice()[hit.tab_index];
                    self.rename_state.begin(hit.tab_index, tab.title[0..tab.title_len]);
                    self.needs_redraw = true;
                    return;
                }
                tab_actions.switchTab(&host, hit.tab_index);
                // L12-γ-3 — drag-begin. `world_x = (px - tab_area_x) + scroll_x`
                // — DragState 의 mouse_x 는 idx 0 의 left edge 부터 측정한
                // 좌표 (= 탭 area world 좌표). single-click 이면 `move` 가
                // threshold (5px) 안 넘어 `dragging=false` 유지 → release
                // 의 `finish` 가 null 반환 → reorder 일어나지 않음.
                const world_x: f32 = px_f - layout.tab_area_x + self.tab_scroll_x;
                const tab_w_int: c_int = @intCast(tab_w_px);
                _ = self.tab_drag.begin(@intFromFloat(world_x), tab_w_int, session.count());
            },
            .none => {},
        }
    }

    /// L12-γ-3 — drag 중 pointer motion 처리. tab area 가장자리 hover 시
    /// auto-scroll + `DragState.move` 호출. mouse 가 cell 영역 / scrollbar
    /// 영역으로 벗어나도 drag 자체는 wayland implicit grab 으로 우리 surface
    /// 까지 도달 — `pointer_inside=false` 와 무관.
    fn handleTabDragMotion(self: *Client) void {
        if (self.session == null) return;
        const session = &self.session.?;
        const tab_w_px = self.renderer.tabWidthPx();
        const layout_inputs = tab_layout.Inputs{
            .viewport_w = @floatFromInt(self.window_width),
            .tab_count = @intCast(session.count()),
            .tab_w = @floatFromInt(tab_w_px),
            .arrow_w = @floatFromInt(self.renderer.tabArrowWPx()),
            .plus_w = @floatFromInt(self.renderer.tabPlusWPx()),
            .scroll_x = self.tab_scroll_x,
        };
        const layout = tab_layout.compute(layout_inputs);
        const px_f: f32 = @floatFromInt(self.pointer_x_px);
        const tab_area_end_f: f32 = layout.tab_area_x + layout.tab_area_w;

        // Drag auto-scroll — pointer 가 tab area 좌/우 가장자리 hover 시 한
        // step 이동. `auto_scroll_w` 안으로 들어오면 한 motion 당 step 만큼.
        const auto_scroll_w: f32 = 30;
        const auto_scroll_step: f32 = 12;
        const total_tabs_w_f: f32 = @as(f32, @floatFromInt(session.count())) *
            @as(f32, @floatFromInt(tab_w_px));
        const max_scroll: f32 = @max(0, total_tabs_w_f - layout.tab_area_w);
        if (px_f < layout.tab_area_x + auto_scroll_w and self.tab_scroll_x > 0) {
            self.tab_scroll_x = @max(0, self.tab_scroll_x - auto_scroll_step);
            self.tab_scroll_override = true;
        } else if (px_f > tab_area_end_f - auto_scroll_w and self.tab_scroll_x < max_scroll) {
            self.tab_scroll_x = @min(max_scroll, self.tab_scroll_x + auto_scroll_step);
            self.tab_scroll_override = true;
        }

        // DragState.move 는 world_x (idx 0 의 left edge 부터 측정) — `begin`
        // 과 같은 좌표계. surface_x - tab_area_x + scroll_x.
        const world_x: f32 = px_f - layout.tab_area_x + self.tab_scroll_x;
        _ = self.tab_drag.move(@intFromFloat(world_x));
        self.needs_redraw = true;
    }

    fn handleNextTab(self: *Client) void {
        if (self.session == null) return;
        self.commitPendingInput();
        var host = self.buildTabActionsHost();
        tab_actions.nextTab(&host);
    }

    fn handlePrevTab(self: *Client) void {
        if (self.session == null) return;
        self.commitPendingInput();
        var host = self.buildTabActionsHost();
        tab_actions.prevTab(&host);
    }

    /// SPEC §2.2 — Alt+1..9 탭 인덱스 점프 (Win 동등, `window.zig:1194-1200`).
    /// 1 → index 0, 9 → index 8. 탭 수보다 큰 인덱스는 `setActiveTab` 가 false
    /// 반환하고 no-op.
    fn handleSwitchTab(self: *Client, idx: usize) void {
        if (self.session == null) return;
        self.commitPendingInput();
        var host = self.buildTabActionsHost();
        tab_actions.switchTab(&host, idx);
    }

    /// L10-α — `text_input.enable()` + content_type + cursor_rect + commit 한
    /// batch. foot terminal (`enter` handler in `ime.c`) 의 정확한 sequence
    /// 동등 — wayland-native terminal 의 검증된 패턴. foot 은 enable 전에
    /// 정확한 cursor 위치 set (0,0,0,0 같은 placeholder 안 보냄) — fcitx5
    /// 가 IME session init 시 cursor 정확한 위치 알아야 자기 한/영 state
    /// 정상 보존.
    fn enableTextInput(self: *Client) !void {
        if (self.text_input_id == 0 or self.text_input_enabled) return;
        try self.sendNoArgs(self.text_input_id, text_input_request_enable);
        try self.sendArgs(self.text_input_id, text_input_request_set_content_type, &.{
            text_input_content_hint_none,
            text_input_content_purpose_terminal,
        });
        // Cursor rectangle — 활성 탭 cursor 의 surface pixel 위치. 정확한
        // 위치 set 후 batch commit (foot 패턴 동등). text-input v3 spec 의
        // cursor_rectangle 단위 = *logical pixel* — 우리 rect 는 physical 이라
        // 변환 후 송신 (fractional scale 환경에서 IME candidate window 정확 위치).
        const rect = self.computeCursorRect();
        var rect_msg = Msg.init(self.text_input_id, text_input_request_set_cursor_rectangle);
        try rect_msg.putI32(self.physicalToLogical(rect.x));
        try rect_msg.putI32(self.physicalToLogical(rect.y));
        try rect_msg.putI32(self.physicalToLogical(rect.w));
        try rect_msg.putI32(self.physicalToLogical(rect.h));
        try rect_msg.send(self.stream);
        try self.sendNoArgs(self.text_input_id, text_input_request_commit);
        self.text_input_enabled = true;
        self.last_cursor_rect_x = rect.x;
        self.last_cursor_rect_y = rect.y;
        self.last_cursor_rect_w = rect.w;
        self.last_cursor_rect_h = rect.h;
    }

    /// 활성 탭 cursor 의 surface-relative pixel rect. cursor 미가시 / session
    /// 없음이면 (0, 0, cw, ch) — fcitx5 한테 의미 있는 placeholder.
    fn computeCursorRect(self: *const Client) struct { x: i32, y: i32, w: i32, h: i32 } {
        const cw = self.renderer.cellWidth();
        const ch = self.renderer.cellHeight();
        const pad = self.renderer.paddingPx();
        const tab_bar_h = self.effectiveTabBarHeightPx();
        if (self.renderer.render_state.cursor.viewport) |vp| {
            const x: i32 = pad + @as(i32, @intCast(vp.x)) * cw;
            const y: i32 = tab_bar_h + pad + @as(i32, @intCast(vp.y)) * ch;
            return .{ .x = x, .y = y, .w = cw, .h = ch };
        }
        return .{ .x = pad, .y = tab_bar_h + pad, .w = cw, .h = ch };
    }

    /// IME cursor rectangle 의 named 형 — `updateCursorRectangle` / `computeRenameCursorRect`
    /// 의 anonymous struct 들이 if-else branch 에서 같은 type 으로 합쳐지도록.
    const CursorRect = struct { x: i32, y: i32, w: i32, h: i32 };

    /// rename 활성 시 — 탭바의 rename cursor 의 surface-relative pixel rect.
    /// mac `firstRectForCharacterRange` 가 tab rename snapshot 기준 rect 반환
    /// 하는 패턴 동등 — IME popup 이 탭바 cursor 옆에 뜨도록.
    fn computeRenameCursorRect(self: *const Client) ?CursorRect {
        const session = if (self.session) |*s| s else return null;
        const tab_idx = self.rename_state.tab_index orelse return null;
        if (tab_idx >= session.count()) return null;

        const cw = self.renderer.cellWidth();
        const tab_w_px = self.renderer.tabWidthPx();
        const tab_pad_px = self.renderer.tabPaddingPx();
        const tab_bar_h = self.effectiveTabBarHeightPx();

        const layout_inputs = tab_layout.Inputs{
            .viewport_w = @floatFromInt(self.window_width),
            .tab_count = @intCast(session.count()),
            .tab_w = @floatFromInt(tab_w_px),
            .arrow_w = @floatFromInt(self.renderer.tabArrowWPx()),
            .plus_w = @floatFromInt(self.renderer.tabPlusWPx()),
            .scroll_x = self.tab_scroll_x,
        };
        const layout = tab_layout.compute(layout_inputs);
        const tab_world_x: f32 = @as(f32, @floatFromInt(tab_idx)) * @as(f32, @floatFromInt(tab_w_px));
        const text_x_start: f32 = layout.tab_area_x + tab_world_x - self.tab_scroll_x +
            @as(f32, @floatFromInt(tab_pad_px));

        // title bytes [0..cursor] 의 cell width 합. preedit advance 는 cursor
        // *뒤* 에 push-right 라 cursor x 자체엔 영향 X (cursor 가 preedit 앞).
        var cursor_x_in_text: f32 = 0;
        const title = self.rename_state.buf[0..self.rename_state.len];
        var iter = std.unicode.Utf8Iterator{ .bytes = title, .i = 0 };
        var byte: usize = 0;
        while (iter.nextCodepoint()) |cp| {
            if (byte >= self.rename_state.cursor) break;
            const cells = display_width.codepointWidth(@intCast(cp));
            cursor_x_in_text += @as(f32, @floatFromInt(cw)) * @as(f32, @floatFromInt(cells));
            const len = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
            byte += len;
        }
        const cursor_visual_x: f32 = text_x_start + cursor_x_in_text - self.rename_state.scroll_offset;
        return .{
            .x = @intFromFloat(cursor_visual_x),
            .y = 0, // 탭바 최상단 — IME popup 이 탭바 아래로 나옴
            .w = cw,
            .h = tab_bar_h,
        };
    }

    /// L10-γ — `set_cursor_rectangle(x, y, w, h)` + commit. surface-relative
    /// pixel 좌표. fcitx5 popover (한자 / 확장 candidate window) 가 cursor 근처
    /// 에 정렬되도록. text-input-v3 spec 의 cursor_rectangle 단위 = **logical
    /// pixel** — fractional scale 환경 (KDE 1.5x / 1.7x 등) 에서 우리 physical
    /// 좌표를 그대로 넘기면 IME 가 큰 logical 좌표로 해석 → popup 화면 중간 등
    /// 엉뚱한 위치. `enableTextInput` 의 변환과 같은 패턴 (사용자 시연 발견).
    ///
    /// rename 활성 시 — 탭바 rename cursor 위치 (사용자 시연 — 한자키 누르면
    /// popup 이 탭바 위치 아닌 cell cursor 위치에 떴음). mac SPEC §5 의
    /// firstRectForCharacterRange 의 terminal cursor row / tab rename snapshot
    /// 분기 동등.
    ///
    /// 캐시 비교로 cursor 가 실제로 이동했을 때만 전송 (spam 회피). text_input
    /// 미활성이면 no-op.
    fn updateCursorRectangle(self: *Client) !void {
        if (!self.text_input_enabled or self.text_input_id == 0) return;

        const cw = self.renderer.cellWidth();
        const ch = self.renderer.cellHeight();
        const rect: CursorRect = if (self.rename_state.isActive())
            self.computeRenameCursorRect() orelse return
        else blk: {
            const vp = self.renderer.render_state.cursor.viewport orelse return;
            const pad = self.renderer.paddingPx();
            const tab_bar_h = self.effectiveTabBarHeightPx();
            const x: i32 = pad + @as(i32, @intCast(vp.x)) * cw;
            const y: i32 = tab_bar_h + pad + @as(i32, @intCast(vp.y)) * ch;
            break :blk CursorRect{ .x = x, .y = y, .w = cw, .h = ch };
        };

        if (rect.x == self.last_cursor_rect_x and
            rect.y == self.last_cursor_rect_y and
            rect.w == self.last_cursor_rect_w and
            rect.h == self.last_cursor_rect_h) return;
        var msg = Msg.init(self.text_input_id, text_input_request_set_cursor_rectangle);
        try msg.putI32(self.physicalToLogical(rect.x));
        try msg.putI32(self.physicalToLogical(rect.y));
        try msg.putI32(self.physicalToLogical(rect.w));
        try msg.putI32(self.physicalToLogical(rect.h));
        try msg.send(self.stream);
        try self.sendNoArgs(self.text_input_id, text_input_request_commit);
        self.last_cursor_rect_x = rect.x;
        self.last_cursor_rect_y = rect.y;
        self.last_cursor_rect_w = rect.w;
        self.last_cursor_rect_h = rect.h;
    }

    fn disableTextInput(self: *Client) !void {
        if (self.text_input_id == 0 or !self.text_input_enabled) return;
        try self.sendNoArgs(self.text_input_id, text_input_request_disable);
        try self.sendNoArgs(self.text_input_id, text_input_request_commit);
        self.text_input_enabled = false;
        // focus 떠나는 시점에 preedit overlay 도 같이 사라져야 자연. pending
        // batch 잔여물도 초기화 — disable 직전에 들어온 preedit 가 다음 enable
        // 시 잘못 적용되지 않게.
        self.pending_preedit.clearRetainingCapacity();
        self.pending_commit.clearRetainingCapacity();
        self.preedit_text.clearRetainingCapacity();
        self.renderer.preedit_text = "";
        log.appendLine("wayland", "text_input disabled id={}", .{self.text_input_id});
    }

    /// L10-α + L10-β — zwp_text_input_v3 server → client events. spec 상
    /// preedit / commit / delete 는 한 batch 로 들어와 `done(serial)` 에서 한
    /// 번에 apply. preedit/commit 텍스트는 pending buffer 에 누적했다가 done
    /// 시점에 commit → PTY 송신, preedit → renderer overlay 갱신.
    fn handleTextInputEvent(self: *Client, opcode: u16, payload: []const u8) !void {
        switch (opcode) {
            text_input_event_enter => {
                // payload: object<wl_surface>. 우리 surface 하나뿐이라 검증 생략.
                // spec 정확한 시점에 enable() 호출 — fcitx5 의 IME session init
                // 이 우리 wayland frontend 에 align.
                try self.enableTextInput();
            },
            text_input_event_leave => {
                // foot `ime_disable` 동등 — disable + commit + state clear.
                // fcitx5 가 leave 시 명시 disable 받아야 자기 IME session
                // 정확히 종료.
                if (self.text_input_id != 0 and self.text_input_enabled) {
                    try self.sendNoArgs(self.text_input_id, text_input_request_disable);
                    try self.sendNoArgs(self.text_input_id, text_input_request_commit);
                }
                self.text_input_enabled = false;
                // pending preedit / commit batch 도 cleanup (foot `ime_reset_
                // pending` / `ime_reset_preedit` 동등).
                self.pending_preedit.clearRetainingCapacity();
                self.pending_commit.clearRetainingCapacity();
                self.preedit_text.clearRetainingCapacity();
                self.renderer.preedit_text = "";
                self.last_cursor_rect_x = -1;
            },
            text_input_event_preedit_string => {
                // string text + int cursor_begin + int cursor_end. text 만
                // 사용 (cursor_begin/end 는 split 표시용 — L10 단순화 scope 밖).
                var cursor = Parser{ .buf = payload };
                const text = cursor.readString() catch "";
                self.pending_preedit.clearRetainingCapacity();
                try self.pending_preedit.appendSlice(self.allocator, text);
            },
            text_input_event_commit_string => {
                // string text. fcitx5 가 음절 완성 시점에 보내준다. 한 batch
                // 안에 한 commit_string 이 보통이라 append 누적 (spec 상 둘 이상
                // 와도 안전).
                var cursor = Parser{ .buf = payload };
                const text = cursor.readString() catch "";
                try self.pending_commit.appendSlice(self.allocator, text);
            },
            text_input_event_delete_surrounding_text => {
                // uint before + uint after. surrounding_text 미설정이라 보통
                // 안 온다. 로그만.
                log.appendLine("wayland", "text_input delete_surrounding (unexpected — no surrounding set)", .{});
            },
            text_input_event_done => {
                if (payload.len >= 4) {
                    self.text_input_done_serial = readU32(payload[0..4]);
                }
                try self.applyTextInputBatch();
            },
            else => {},
        }
    }

    /// L10-β — text-input-v3 `done` 시점의 batch apply. spec 상 한 batch 의
    /// commit 은 PTY 로, preedit 는 화면 overlay 로 갱신. 매 batch 마다 preedit
    /// 은 새 값 (= empty 도 정상, "조합 끝" 의미) 으로 reset 된다.
    fn applyTextInputBatch(self: *Client) !void {
        if (self.pending_commit.items.len > 0) {
            log.appendLine("wayland", "text_input commit text_len={}", .{self.pending_commit.items.len});
            // L12-γ-2 — rename 모드 활성 시 IME commit 도 PTY 가 아니라 rename
            // buffer 로 라우팅 (macOS / Windows 동등). codepoint 별 insert —
            // utf8 byte 단위로 처리하면 한글 음절 안 byte boundary 깨짐.
            if (self.rename_state.isActive()) {
                var utf8_iter = std.unicode.Utf8Iterator{ .bytes = self.pending_commit.items, .i = 0 };
                while (utf8_iter.nextCodepoint()) |cp| {
                    if (cp < 0x20) continue;
                    _ = self.rename_state.insertCodepoint(cp);
                }
            } else {
                self.queueInput(self.pending_commit.items);
            }
            self.pending_commit.clearRetainingCapacity();
        }
        // pending_preedit → preedit_text 로 옮긴 뒤 renderer slice 갱신. paint
        // 호출 시점에 storage 가 valid 해야 하므로 ArrayList 의 owned 메모리에
        // 보관. pending_preedit 가 비어 있으면 preedit_text 도 비움 (overlay
        // 사라짐 = 조합 끝).
        if (self.pending_preedit.items.len > 0) {
            log.appendLine("wayland", "text_input preedit text_len={}", .{self.pending_preedit.items.len});
        }
        self.preedit_text.clearRetainingCapacity();
        try self.preedit_text.appendSlice(self.allocator, self.pending_preedit.items);
        self.pending_preedit.clearRetainingCapacity();
        self.renderer.preedit_text = self.preedit_text.items;
        // IME 활성 시 wl_keyboard.key event 는 IME 로 raised 되어 우리한테 안
        // 온다. text_input event 만 들어오는 동안 다른 갱신 트리거가 없어
        // `needs_redraw` 가 자동으로 안 켜진다. preedit 변화가 화면에 보이려면
        // 명시 트리거 필수 — commit batch 면 PTY echo 가 다음 frame 을 어차피
        // 끌고 오지만 preedit 만 변하는 경우는 이 줄이 유일 트리거.
        self.needs_redraw = true;
    }

    fn handleKeyboardKeymap(self: *Client, payload: []const u8) !void {
        if (payload.len < 8) return error.WaylandBadMessage;
        const format = readU32(payload[0..4]);
        const size_u32 = readU32(payload[4..8]);
        const fd = try self.takeReceivedFd();
        defer posix.close(fd);

        if (format != wl_keyboard_keymap_format_xkb_v1) {
            log.appendLine("wayland", "unsupported keyboard keymap format={}", .{format});
            return;
        }
        if (size_u32 == 0) return error.WaylandBadKeymap;

        const size: usize = @intCast(size_u32);
        const memory = try posix.mmap(
            null,
            size,
            linux.PROT.READ,
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        );
        defer posix.munmap(memory);

        try self.keyboard.setKeymap(self.allocator, memory);
        log.appendLine("wayland", "keyboard keymap loaded size={}", .{size});
    }

    fn handleKeyboardKey(self: *Client, payload: []const u8) !void {
        if (payload.len < 16) return error.WaylandBadMessage;
        const serial = readU32(payload[0..4]);
        const key = readU32(payload[8..12]);
        const state = readU32(payload[12..16]);
        // L12-γ-5 — pressed 면 repeat timer arm, released 면 disarm (같은
        // key 한정 — 다른 key 가 이미 repeat 중이면 그건 새 key 의 press 가
        // swap 했을 때만 cancel).
        if (state == wl_keyboard_key_state_pressed) {
            self.key_repeat_keycode = key;
            self.key_repeat_next_ms = std.time.milliTimestamp() + @as(i64, self.key_repeat_delay_ms);
        } else if (state == 0 and self.key_repeat_keycode == key) {
            // released — same key disarm.
            self.key_repeat_keycode = 0;
        }
        if (state != wl_keyboard_key_state_pressed and state != wl_keyboard_key_state_repeated) return;
        try self.processKeyEvent(serial, key);
    }

    /// L12-γ-2 — rename 모드 활성 시 key 라우팅. xkb keysym → RenameKey 매핑
    /// 또는 printable utf8 → `insertCodepoint`. RenameOutcome 으로 commit /
    /// cancel 분기.
    ///
    /// SPEC §5.1 — Ctrl+A / Ctrl+E 도 line-nav (Home / End) 로 매핑. terminal
    /// readline 컨벤션 + native textbox 표준. mac `tildazKeyDown` 의 keyCode
    /// intercept 동등 (mac SPEC §5.1 시도/폐기 기록 참조). preedit 자모는 IME
    /// 자체 commit_string 으로 rename buf 에 들어옴 (별도 명시 commit 호출 X
    /// — 같은 batch 안 commit_string + preedit_string(empty) + done 흐름).
    fn handleRenameKey(self: *Client, key: u32) !void {
        const xkb_key = key + wayland_xkb_keycode_offset;
        const sym = self.keyboard.oneSym(xkb_key) orelse return;

        // 사용자 시연 발견 — Ctrl+A / Ctrl+E 가 mapping 없어 (utf8 cp < 0x20
        // reject) no-op 였음. Ctrl 단독 (Shift 없을 때) + a/e 만 매핑.
        // Ctrl+Shift+A / Ctrl+Shift+E 는 별 의미 없어 그대로 utf8 path.
        var rename_key: ?tab_interaction.RenameKey = null;
        if (self.keyboard.ctrlActive() and !self.keyboard.shiftActive()) {
            rename_key = switch (sym) {
                xkb_key_a_lower, xkb_key_a_upper => .home,
                xkb_key_e_lower, xkb_key_e_upper => .end,
                else => null,
            };
        }
        if (rename_key == null) {
            rename_key = switch (sym) {
                xkb_key_return => .enter,
                xkb_key_escape => .escape,
                xkb_key_backspace => .backspace,
                xkb_key_delete => .delete,
                xkb_key_left => .left,
                xkb_key_right => .right,
                xkb_key_home => .home,
                xkb_key_end => .end,
                else => null,
            };
        }
        if (rename_key) |rk| {
            const outcome = self.rename_state.handleKey(rk);
            try self.applyRenameOutcome(outcome);
            return;
        }
        // printable utf8 — keyboard.utf8 로 decode 후 codepoint 별 insert.
        var buf: [64]u8 = undefined;
        const bytes = self.keyboard.utf8(xkb_key, &buf);
        if (bytes.len == 0) return;
        var utf8_iter = std.unicode.Utf8Iterator{ .bytes = bytes, .i = 0 };
        while (utf8_iter.nextCodepoint()) |cp| {
            if (cp < 0x20) continue;
            _ = self.rename_state.insertCodepoint(cp);
        }
        self.needs_redraw = true;
    }

    /// rename 의 commit / cancel / changed 적용. commit 면 tab.setCustomTitle
    /// + clear, cancel 면 clear 만, changed 면 needs_redraw.
    fn applyRenameOutcome(self: *Client, outcome: tab_interaction.RenameOutcome) !void {
        switch (outcome) {
            .commit => {
                if (self.session) |*session| {
                    if (self.rename_state.commitRequest()) |req| {
                        const tabs = session.tabsSlice();
                        if (req.tab_index < tabs.len) {
                            tabs[req.tab_index].setCustomTitle(req.title);
                        }
                    }
                }
                self.rename_state.clear();
                self.needs_redraw = true;
            },
            .cancel => {
                self.rename_state.clear();
                self.needs_redraw = true;
            },
            .changed => self.needs_redraw = true,
            .none => {},
        }
    }

    /// L12-γ-5 — main loop 의 매 iteration 에서 repeat timer 검사. timer 가
    /// arm 되어 있고 (`key_repeat_keycode != 0`) 현재 시간이 next_ms 넘으면
    /// `processKeyEvent` 를 simulated `repeated` state 로 재호출.
    fn maybeRepeatKey(self: *Client) !void {
        if (self.key_repeat_keycode == 0) return;
        if (self.key_repeat_rate_hz <= 0) return;
        const now = std.time.milliTimestamp();
        if (now < self.key_repeat_next_ms) return;
        try self.processKeyEvent(self.last_serial, self.key_repeat_keycode);
        self.key_repeat_next_ms = now + @divTrunc(1000, @as(i64, self.key_repeat_rate_hz));
    }

    /// L12-γ-5 — keyboard.key 의 실제 처리 (byte parsing 분리 후). pressed /
    /// repeated 둘 다 같은 path. serial 은 clipboard 등 시점 기록용으로 자기
    /// 자신에게 보관 (matchClipboardSerial 같은 path 에서 사용).
    fn processKeyEvent(self: *Client, serial: u32, key: u32) !void {
        self.last_serial = serial;

        // #203 Phase C — dialog 활성 시 모든 키 dialog 로 라우팅 (Enter / Esc /
        // Tab 만 의미). modal — 다른 키 swallow. rename / preedit / 단축키 모두
        // 이 위로 통과 못 함 (NSAlert / MessageBoxW 의 modal 동등).
        if (self.dialog.active()) {
            self.handleDialogKey(key);
            return;
        }

        // L12-γ-2 — rename 모드 활성 시 모든 키를 PTY 가 아니라 RenameState 로
        // 라우팅 (macOS `g_rename.isActive()` 분기 동등). modifier 단축키
        // (ctrl+shift+*) 도 무시 — 사용자가 Enter / Escape 로 나가야.
        if (self.rename_state.isActive()) {
            try self.handleRenameKey(key);
            return;
        }

        const xkb_key = key + wayland_xkb_keycode_offset;
        const sym_opt = self.keyboard.oneSym(xkb_key);

        // SPEC §2.6 / §5.1 — Ctrl+key + preedit 정책 (사용자 시연 발견 후 정정).
        //   Ctrl+C 만 *discard* — shell line abort (\\x03 SIGINT) 의도와 일관.
        //     fcitx5 의 자체 IME state 도 reset 가정.
        //   그 외 모든 Ctrl+letter (Ctrl+A / Ctrl+E / Ctrl+L / Ctrl+D 등) 는
        //     *commit to PTY* — terminal readline 이 자모 먼저 받고 그 다음
        //     Ctrl byte 처리 (`commitPendingInput` 이 자모 PTY 송신 + fcitx5
        //     session disable/enable 으로 IME 자모 buffer 도 비움).
        if (self.keyboard.ctrlActive() and self.preedit_text.items.len > 0) {
            const is_ctrl_c = if (sym_opt) |s|
                (s == xkb_key_c_lower or s == xkb_key_c_upper)
            else
                false;
            if (is_ctrl_c) {
                self.pending_preedit.clearRetainingCapacity();
                self.pending_commit.clearRetainingCapacity();
                self.preedit_text.clearRetainingCapacity();
                self.renderer.preedit_text = "";
                self.needs_redraw = true;
            } else {
                self.commitPendingInput();
            }
        }

        if (sym_opt) |sym| {
            // Ctrl+Shift+C / V — SPEC.md §2.3 클립보드. Linux 도 Windows 와 같은
            // native modifier (Ctrl+Shift). 분기 안에서 utf8 PTY 송신은 차단해서
            // xkb 가 만든 noise byte 가 shell 에 들어가지 않게 한다.
            if (self.keyboard.ctrlActive() and self.keyboard.shiftActive()) {
                if (sym == xkb_key_c_lower or sym == xkb_key_c_upper) {
                    // copy 는 read-only — commitPendingInput 호출 안 함 (preedit
                    // / rename 상태 무관 동작).
                    self.copyActiveSelection();
                    return;
                }
                if (sym == xkb_key_v_lower or sym == xkb_key_v_upper) {
                    // L12-γ-2 — paste 진입 시 preedit / rename commit (macOS
                    // Cmd 단축키 패턴 동등). preedit 자모를 dangling 시키지 않게.
                    self.commitPendingInput();
                    self.pasteFromClipboard();
                    return;
                }
                // L12-β — tab 단축키 모두 `Ctrl+Shift+*` 자리. Ctrl 단독은
                // shell 통과 (Ctrl+T transpose / Ctrl+W kill-word / Ctrl+Tab
                // 일부 shell 단축키). gnome-terminal / kitty 와 동등 관습.
                if (sym == xkb_key_t_lower or sym == xkb_key_t_upper) {
                    self.handleNewTab();
                    return;
                }
                if (sym == xkb_key_w_lower or sym == xkb_key_w_upper) {
                    self.handleCloseTab();
                    return;
                }
                if (sym == xkb_key_bracketright or sym == xkb_key_braceright) {
                    self.handleNextTab();
                    return;
                }
                if (sym == xkb_key_bracketleft or sym == xkb_key_braceleft) {
                    self.handlePrevTab();
                    return;
                }
                // SPEC §2.4 — Ctrl+Shift+I : About 다이얼로그 (Win 동등 native).
                // §4.1 — 단축키 진입 시 rename commit (commitPendingInput).
                // #213 — About 의 `createDialogSurface` 가 roundtrip (inner
                // dispatchBuffered) 을 돌려서, 여기 (outer dispatchBuffered 의
                // reentrant context) 에서 직접 열면 outer buffer state corrupt →
                // overflow. quit / dismiss 와 동일하게 flag 만 set, main loop 의
                // `drainAboutRequest` 가 reentrancy 밖에서 연다.
                if (sym == xkb_key_i_lower or sym == xkb_key_i_upper) {
                    self.commitPendingInput();
                    self.pending_about_request = true;
                    return;
                }
                // SPEC §11.2 — Ctrl+Shift+P : Open Config (default editor 로).
                if (sym == xkb_key_p_lower or sym == xkb_key_p_upper) {
                    self.commitPendingInput();
                    const cfg_path = paths.configPath(self.allocator) catch return;
                    defer self.allocator.free(cfg_path);
                    system_open.openInDefaultApp(self.allocator, cfg_path);
                    return;
                }
                // SPEC §11.2 — Ctrl+Shift+L : Open Log.
                if (sym == xkb_key_l_lower or sym == xkb_key_l_upper) {
                    self.commitPendingInput();
                    const log_path = paths.logPath(self.allocator) catch return;
                    defer self.allocator.free(log_path);
                    system_open.openInDefaultApp(self.allocator, log_path);
                    return;
                }
            }
            // SPEC §2.5 — Shift+PgUp / Shift+PgDn : scrollback (한 페이지 단위).
            // mac `tab.terminal.scrollViewport({-rows / +rows})` 와 동등하게
            // `session.scrollActive({.page = .up/.down}, visible_rows)` 사용
            // — wheel 분기와 같은 통로. Ctrl 동반 X.
            if (self.keyboard.shiftActive() and !self.keyboard.ctrlActive() and !self.keyboard.altActive()) {
                if (sym == xkb_key_page_up or sym == xkb_key_page_down) {
                    self.commitPendingInput();
                    if (self.session) |*session| {
                        const ch = self.renderer.cellHeight();
                        const usable_h = @max(0, self.window_height - self.effectiveTabBarHeightPx() - self.renderer.paddingPx() * 2);
                        const rows_i32 = @divTrunc(usable_h, ch);
                        const visible_rows: u16 = if (rows_i32 <= 0) 1 else @intCast(@min(rows_i32, std.math.maxInt(u16)));
                        const dir: app_event.PageDirection = if (sym == xkb_key_page_up) .up else .down;
                        const did = session.scrollActive(.{ .page = dir }, visible_rows);
                        if (did) self.requestRedraw();
                    }
                    return;
                }
            }
            // SPEC §2.1 — Alt+F4 : 앱 종료 (Win 동등 native, Linux desktop 표준).
            // step 4 — multi-tab / 단일 탭 *모두* confirm dialog (mac
            // `applicationShouldTerminate:` / Win `onQuitRequest` 동등). flag 만
            // set, main loop 의 `drainQuitRequest` 가 *outer dispatchBuffered
            // reentrancy 밖* 에서 dialog.showConfirm 호출. OK 면 종료, Cancel 이면
            // 무시.
            //
            // 시연 진단으로 발견 — KDE Plasma 6 + KWin 의 Alt+F4 는 *system
            // shortcut* 으로 F4 key event 를 우리 client 에 안 보냄. 대신 main
            // layer-surface 에 `zwlr_layer_surface_v1.closed` event 발송. 그
            // 경로는 `handleEvent` 의 layer_surface closed 분기에서 동일하게
            // pending_quit_request 처리. 이 keysym 분기는 *KWin 외 compositor*
            // (예: sway / hyprland / GNOME mutter) 에서 F4 가 도달하는 경우 대비
            // 유지.
            if (self.keyboard.altActive() and !self.keyboard.ctrlActive() and !self.keyboard.shiftActive() and sym == xkb_key_f4) {
                self.commitPendingInput();
                self.pending_quit_request = true;
                return;
            }
            // SPEC §2.2 — Alt+1..9 탭 인덱스 점프 (Win 동등). Ctrl / Shift 미동반
            // 만 trigger — Alt+Shift+숫자 / Alt+Ctrl+숫자 같은 다른 조합은 shell /
            // X 의 통과로 둠. Alt+0 은 사용 안 (spec 9 까지만).
            if (self.keyboard.altActive() and !self.keyboard.ctrlActive() and !self.keyboard.shiftActive() and sym >= xkb_key_1 and sym <= xkb_key_9) {
                self.handleSwitchTab(@intCast(sym - xkb_key_1));
                return;
            }
            if (terminalSequenceForKeysym(sym)) |seq| {
                self.queueInput(seq);
                return;
            }
        }

        var buf: [64]u8 = undefined;
        const bytes = self.keyboard.utf8(xkb_key, &buf);
        if (bytes.len > 0) self.queueInput(bytes);
    }

    fn handleKeyboardModifiers(self: *Client, payload: []const u8) void {
        if (payload.len < 20) return;
        self.keyboard.updateMask(
            readU32(payload[4..8]),
            readU32(payload[8..12]),
            readU32(payload[12..16]),
            readU32(payload[16..20]),
        );
    }

    fn handleKeyboardRepeatInfo(self: *Client, payload: []const u8) void {
        if (payload.len < 8) return;
        const rate = readI32(payload[0..4]);
        const delay = readI32(payload[4..8]);
        self.key_repeat_rate_hz = rate;
        self.key_repeat_delay_ms = delay;
        log.appendLine("wayland", "keyboard repeat rate={} delay={}", .{ rate, delay });
    }

    fn handlePointerEvent(self: *Client, opcode: u16, payload: []const u8) !void {
        switch (opcode) {
            0 => self.handlePointerEnter(payload),
            1 => self.handlePointerLeave(payload),
            2 => self.handlePointerMotion(payload),
            3 => self.handlePointerButton(payload),
            4 => self.handlePointerAxis(payload),
            else => {},
        }
    }

    /// wl_pointer.enter(serial, surface, surface_x_fixed, surface_y_fixed).
    /// 좌표 = *surface-local logical pixel* (fixed 24.8). 우리 paint area / cell
    /// metric 은 physical 이라 fixed → logical → physical 변환.
    fn handlePointerEnter(self: *Client, payload: []const u8) void {
        if (payload.len < 16) return;
        const serial = readU32(payload[0..4]);
        self.last_serial = serial;
        // #193 — set_shape 의 serial 은 pointer enter event serial 이어야 함.
        self.last_pointer_enter_serial = serial;
        // #203 Phase C — pointer focus surface 추적. dialog active 시 modal
        // click filter (main surface click 은 dismiss 안 함) 에 사용.
        self.last_pointer_enter_surface_id = readU32(payload[4..8]);
        const sx = readI32(payload[8..12]);
        const sy = readI32(payload[12..16]);
        self.pointer_x_px = self.logicalToPhysical(wlFixedToPx(sx));
        self.pointer_y_px = self.logicalToPhysical(wlFixedToPx(sy));
        self.pointer_inside = true;
        // #193 — enter 시 우리 surface 가 받는 첫 serial. 이 시점에 cursor 첫
        // 송신해야 compositor 의 default cursor 가 우리 의도 (cell I-beam 또는
        // arrow) 로 즉시 전환. enter 후 cached shape 가 stale 할 수 있어 강제
        // reset.
        self.last_cursor_shape = 0;
        self.updateCursorShape() catch {};
    }

    /// wl_pointer.leave(serial, surface) — drag 중이면 selection 은 유지.
    /// SPEC.md §3 / macOS `tildazMouseUp` 패턴 — drag 종료는 button release 에서만.
    fn handlePointerLeave(self: *Client, payload: []const u8) void {
        // #203 Phase C — leave 한 surface 가 현재 추적 중인 pointer focus 와
        // 같으면 0 으로 reset. 다른 surface (이미 다른 곳으로 enter 했음) 의
        // 늦은 leave 면 무시.
        if (payload.len >= 8) {
            const left_surface = readU32(payload[4..8]);
            if (left_surface == self.last_pointer_enter_surface_id) {
                self.last_pointer_enter_surface_id = 0;
            }
        }
        self.pointer_inside = false;
        self.pointer_x_px = -1;
        self.pointer_y_px = -1;
    }

    /// wl_pointer.motion(time, surface_x_fixed, surface_y_fixed). 좌표 = logical.
    fn handlePointerMotion(self: *Client, payload: []const u8) void {
        if (payload.len < 12) return;
        // payload[0..4]=time.
        const sx = readI32(payload[4..8]);
        const sy = readI32(payload[8..12]);
        self.pointer_x_px = self.logicalToPhysical(wlFixedToPx(sx));
        self.pointer_y_px = self.logicalToPhysical(wlFixedToPx(sy));
        // #193 — region 변경 시만 set_shape (캐시 hit 시 no-op).
        self.updateCursorShape() catch {};

        // L12-γ-3 — tab drag 활성이면 selection / scrollbar 우선이 아니라
        // drag move 만 처리. mouse 가 cell 영역으로 벗어나도 drag 자체는
        // tab area 의 가장자리 auto-scroll + drop_idx 업데이트.
        if (self.tab_drag.active) {
            self.handleTabDragMotion();
            return;
        }

        const tab = self.activeTabOrNull() orelse return;
        // 스크롤바 drag 중 — selection 검사보다 먼저. drag 가 cell 영역 밖으로
        // 나가도 follow (Windows `app_controller.scrollToY` 와 동등).
        if (tab.interaction.scrollbar.active) {
            self.scrollToY(self.pointer_y_px);
            return;
        }
        if (!tab.interaction.selection.active) return;
        const cell = self.pixelToCell(self.pointer_x_px, self.pointer_y_px) orelse return;
        tab.interaction.selection.update(tab.terminal.screens.active, cell);
        self.requestRedraw();
    }

    /// wl_pointer.button(serial, time, button, state).
    fn handlePointerButton(self: *Client, payload: []const u8) void {
        if (payload.len < 16) return;
        self.last_serial = readU32(payload[0..4]);
        const time_ms = readU32(payload[4..8]);
        const button = readU32(payload[8..12]);
        const state = readU32(payload[12..16]);

        // #203 Phase C — dialog 활성 시 모든 클릭 무시 (modal). 단 *dialog
        // surface 위 + OK / Cancel 버튼 좌표 안* 의 누름만 dismiss 트리거. 사용자
        // 대화로 확정된 정책 (mac NSAlert / Win MessageBoxW 표준 동등):
        //   - 본문 (텍스트 / 여백) 누름 → 무시 + dismiss X (포커스 회복만)
        //   - terminal 영역 누름 → 무시 + dismiss X
        //   - OK 버튼 → dismiss + result=true (confirm 시)
        //   - Cancel 버튼 → dismiss + result=false (confirm 시)
        //   - Enter / Esc → handleDialogKey 가 처리
        // 다른 단축키 (tab bar / scrollbar / selection / paste) 보다 우선.
        if (self.dialog.active()) {
            // #210 진단 — dialog 활성 시 pointer button 도착 여부 + enter_surface
            // 매칭 + hit-test 결과 추적. 사용자 시연에서 *Esc/Enter 동작 / 마우스
            // click 안 동작* 보고. enter event 가 dialog 로 안 오면 가드 reject —
            // 그 여부 확인.
            log.appendLine("dialog", "pointer button kind={s} state={d} button=0x{x} last_enter={} dialog_surface={} pointer_xy=({},{})", .{
                @tagName(self.dialog.kind),
                state,
                button,
                self.last_pointer_enter_surface_id,
                self.dialog.surface_id,
                self.pointer_x_px,
                self.pointer_y_px,
            });
            if (state == wl_pointer_button_state_pressed and
                self.last_pointer_enter_surface_id == self.dialog.surface_id)
            {
                if (self.hitDialogRect(self.renderer.last_dialog_ok_rect)) {
                    log.appendLine("dialog", "OK hit — dismiss request", .{});
                    if (self.dialog.kind == .confirm) self.pending_confirm_result = true;
                    self.requestDismissDialog();
                } else if (self.hitDialogRect(self.renderer.last_dialog_cancel_rect)) {
                    log.appendLine("dialog", "Cancel hit — dismiss request", .{});
                    if (self.dialog.kind == .confirm) self.pending_confirm_result = false;
                    self.requestDismissDialog();
                } else {
                    log.appendLine("dialog", "button in dialog area but no OK/Cancel rect hit (ok={any} cancel={any})", .{ self.renderer.last_dialog_ok_rect, self.renderer.last_dialog_cancel_rect });
                }
            } else if (state == wl_pointer_button_state_pressed) {
                log.appendLine("dialog", "button rejected — enter_surface mismatch (need {} got {})", .{ self.dialog.surface_id, self.last_pointer_enter_surface_id });
            }
            return;
        }

        if (button == wl_pointer_button_right) {
            // 우클릭 — pressed edge 에서 paste (cmd.exe console 표준 + Windows /
            // macOS 와 같은 정책. SPEC.md §3).
            if (state == wl_pointer_button_state_pressed) self.pasteFromClipboard();
            return;
        }
        if (button != wl_pointer_button_left) return;

        const tab = self.activeTabOrNull() orelse return;
        switch (state) {
            wl_pointer_button_state_pressed => {
                // L12-β/γ — tab bar 영역 클릭 → tab_layout.hitArea 로 분기.
                // 다른 모든 pointer mode (scrollbar / selection / 더블클릭)
                // 보다 *우선* 검사 — tab bar 안에서 selection drag 안 시작.
                if (self.pointer_y_px >= 0 and self.pointer_y_px < self.effectiveTabBarHeightPx()) {
                    self.handleTabBarClick(self.pointer_x_px, self.pointer_y_px, time_ms);
                    return;
                }
                // 우측 스크롤바 영역 클릭 — selection / 더블클릭 보다 우선.
                // Windows `app_controller.zig:835` 와 동등.
                if (self.pointer_x_px >= self.window_width - self.renderer.scrollbarWPx()) {
                    tab.interaction.scrollbar.begin();
                    self.scrollToY(self.pointer_y_px);
                    return;
                }

                // L12-γ-2 — cell 영역 클릭 진입 시 commitPendingInput. 탭바
                // 에서 rename 중 한글 typing 후 터미널 클릭 시 rename 이 commit
                // (= setCustomTitle) 되어야 함. preedit / rename 모두 보존.
                self.commitPendingInput();

                const cell = self.pixelToCell(self.pointer_x_px, self.pointer_y_px) orelse return;

                // 더블클릭 검출 — 같은 cell + threshold 이내 두 번째 좌클릭.
                // wayland `wl_pointer.button` event 에는 click count 정보가 없어
                // 직접 추적. SPEC.md §3 더블클릭 word selection.
                const is_double_click = blk: {
                    const prev_cell = self.last_left_click_cell orelse break :blk false;
                    if (time_ms -% self.last_left_click_time_ms > double_click_threshold_ms) break :blk false;
                    if (prev_cell.col != cell.col or prev_cell.row != cell.row) break :blk false;
                    break :blk true;
                };
                self.last_left_click_time_ms = time_ms;
                self.last_left_click_cell = cell;

                if (is_double_click) {
                    // selectWord 는 screen.selection 을 직접 갱신 (cross-platform
                    // 단일 구현 — [`terminal_interaction.selectWord`](src/terminal_interaction.zig)).
                    // SelectionState.begin 안 함 → 다음 release 의 finish 가 false
                    // → 자동 copy 중복 방지. 여기서 명시 copy 호출.
                    if (terminal_interaction.selectWord(tab.terminal.screens.active, cell)) {
                        self.copyActiveSelection();
                        self.requestRedraw();
                    }
                    return;
                }

                tab.interaction.selection.begin(tab.terminal.screens.active, cell);
                self.requestRedraw();
            },
            wl_pointer_button_state_released => {
                // L12-γ-3 — drag 활성이면 reorder 처리. `dragging=true`
                // (= move 5px threshold 넘김) 였으면 `finish` 가 ReorderRequest
                // 반환 → `session.reorderTabs`. single-click 이면 finish 가 null
                // → reset 만 일어남 (defer reset 으로 자동). 어느 경우든 selection
                // / scrollbar 분기보다 우선.
                if (self.tab_drag.active) {
                    const tab_w_int: c_int = @intCast(self.renderer.tabWidthPx());
                    if (self.session) |*session_ptr| {
                        if (self.tab_drag.finish(tab_w_int, session_ptr.count())) |req| {
                            _ = session_ptr.reorderTabs(req.from, req.to) catch |err| {
                                log.appendLine("tab", "reorder 실패: {s}", .{@errorName(err)});
                            };
                            // 활성 탭 위치 변경 — auto-scroll override 해제 +
                            // 다음 paint 의 `ensureActiveVisible` 가 갱신.
                            self.tab_scroll_override = false;
                            self.requestRedraw();
                        }
                    } else {
                        self.tab_drag.reset();
                    }
                    return;
                }
                if (tab.interaction.scrollbar.active) {
                    tab.interaction.scrollbar.end();
                    return;
                }
                if (tab.interaction.selection.finish()) {
                    self.copyActiveSelection();
                    self.requestRedraw();
                }
            },
            else => {},
        }
    }

    /// 스크롤바 thumb 위치를 mouse_y 에 맞춘다. Windows `app_controller.scrollToY`
    /// (`src/app_controller.zig:422`) 의 패턴 그대로 — track height = `window_height
    /// - 2*padding`, thumb 의 최소 높이 / available 계산 / `scrollViewport(.delta)`.
    fn scrollToY(self: *Client, mouse_y: i32) void {
        const tab = self.activeTabOrNull() orelse return;
        const screen = tab.terminal.screens.active;
        const sb = screen.pages.scrollbar();
        if (sb.total <= sb.len) return;

        const pad = self.renderer.paddingPx();
        const track_h: i32 = self.window_height - 2 * pad;
        if (track_h <= 0) return;

        const rel_y: i32 = @max(0, mouse_y - pad);
        const track_hf: f64 = @floatFromInt(track_h);
        const ratio_px: f64 = track_hf / @as(f64, @floatFromInt(sb.total));
        const min_thumb: f64 = @floatFromInt(self.renderer.scrollbarMinThumbHPx());
        const thumb_h: f64 = @max(min_thumb, ratio_px * @as(f64, @floatFromInt(sb.len)));
        const available: f64 = track_hf - thumb_h;
        if (available <= 0) return;
        const clamped_y: f64 = @min(@as(f64, @floatFromInt(rel_y)), available);
        const scroll_ratio: f64 = clamped_y / available;
        const target_row: usize = @intFromFloat(scroll_ratio * @as(f64, @floatFromInt(sb.total - sb.len)));

        const current: isize = @intCast(sb.offset);
        const target: isize = @intCast(target_row);
        const delta = target - current;
        if (delta != 0) {
            tab.terminal.scrollViewport(.{ .delta = delta });
            self.requestRedraw();
        }
    }

    /// wl_pointer.axis(time, axis, value).
    ///
    /// 변환: wayland axis value 는 wl_fixed_t. mouse wheel 한 notch ≈ 10.0 (=2560 fixed).
    /// 부호는 wayland 가 *positive=scroll down* (content 가 위로 이동) 인 반면
    /// 우리 `ScrollEvent.wheel` 은 Windows 패턴 (positive=notch up = view 위로) — 부호 반전.
    /// Magnitude: 한 notch 당 wheel=120 (Windows WHEEL_DELTA 표준), session_core 의
    /// `@divTrunc(raw, 40)` 로 3 lines 가 default 가 되는 흐름과 호환.
    fn handlePointerAxis(self: *Client, payload: []const u8) void {
        if (payload.len < 12) return;
        const axis = readU32(payload[4..8]);
        if (axis != wl_pointer_axis_vertical) return;
        const value_fixed = readI32(payload[8..12]);

        // 한 notch (2560) → -120, 부호 반전 + magnitude 정규화.
        const wheel_i32: i32 = -@divTrunc(value_fixed * 120, 2560);
        if (wheel_i32 == 0) return;
        const wheel_i16: i16 = @intCast(std.math.clamp(wheel_i32, -32768, 32767));

        if (self.session) |*session| {
            // SessionCore.scrollActive 의 visible_rows 인자 — page scroll 계산용.
            // wheel 자체는 i16 만 보지만 같은 인터페이스라 함께 전달.
            const ch = self.renderer.cellHeight();
            const usable_h = @max(0, self.window_height - self.effectiveTabBarHeightPx() - self.renderer.paddingPx() * 2);
            const rows_i32 = @divTrunc(usable_h, ch);
            const visible_rows: u16 = if (rows_i32 <= 0) 1 else @intCast(@min(rows_i32, std.math.maxInt(u16)));
            const did = session.scrollActive(.{ .wheel = wheel_i16 }, visible_rows);
            if (did) self.requestRedraw();
        }
    }

    /// wl_data_device 이벤트.
    /// - opcode 0: data_offer(new_id) — compositor 가 새 wl_data_offer 객체를
    ///   알린다. selection event 직전 단계라 일단 pending 자리에 기록.
    /// - opcode 5: selection(id) — clipboard 현재 owner 의 offer (id=0 이면 빈).
    ///   pending 을 paste 위치로 승격하거나, 이전 paste offer 를 정리한다.
    /// - 그 외 (enter / leave / motion / drop) — drag-and-drop 용이라 무관.
    fn handleDataDeviceEvent(self: *Client, opcode: u16, payload: []const u8) !void {
        switch (opcode) {
            0 => {
                if (payload.len < 4) return;
                self.discardPendingOffer();
                self.pending_offer_id = readU32(payload[0..4]);
                self.pending_offer_has_utf8 = false;
            },
            5 => self.handleDataDeviceSelection(payload),
            else => {},
        }
    }

    fn handleDataDeviceSelection(self: *Client, payload: []const u8) void {
        const offer_id: u32 = if (payload.len >= 4) readU32(payload[0..4]) else 0;

        // 이전 paste offer 정리.
        if (self.paste_offer_id != 0) {
            self.sendNoArgs(self.paste_offer_id, wl_data_offer_request_destroy) catch {};
            self.paste_offer_id = 0;
            self.paste_offer_has_utf8 = false;
        }

        if (offer_id != 0 and offer_id == self.pending_offer_id) {
            self.paste_offer_id = self.pending_offer_id;
            self.paste_offer_has_utf8 = self.pending_offer_has_utf8;
            self.pending_offer_id = 0;
            self.pending_offer_has_utf8 = false;
        } else {
            // 빈 selection 또는 우리가 추적 못 한 offer — pending 도 청소.
            self.discardPendingOffer();
        }
    }

    fn discardPendingOffer(self: *Client) void {
        if (self.pending_offer_id != 0) {
            self.sendNoArgs(self.pending_offer_id, wl_data_offer_request_destroy) catch {};
            self.pending_offer_id = 0;
            self.pending_offer_has_utf8 = false;
        }
    }

    /// wl_data_offer 이벤트. 우리가 관심 있는 것은 offer(mime) 만.
    /// `is_pending` 은 caller 가 분기 — 같은 코드, 다른 flag 슬롯.
    fn handleDataOfferEvent(self: *Client, opcode: u16, payload: []const u8, is_pending: bool) !void {
        if (opcode != 0) return; // source_actions / action 은 dnd 전용이라 무시.
        var p = Parser{ .buf = payload };
        const mime = p.readString() catch return;
        if (!isAcceptableTextMime(mime)) return;
        if (is_pending) {
            self.pending_offer_has_utf8 = true;
        } else {
            self.paste_offer_has_utf8 = true;
        }
    }

    /// 우클릭 paste — Windows / macOS 와 같은 패턴 ([SPEC.md §3 우클릭 paste]).
    /// 현재 paste_offer 가 utf8 광고했으면 pipe 만든 뒤 wl_data_offer.receive 로
    /// write end 를 송신측에 넘기고, read end 에서 끝까지 읽어 PTY 로 paste.
    fn pasteFromClipboard(self: *Client) void {
        if (self.paste_offer_id == 0 or !self.paste_offer_has_utf8) return;
        const session = if (self.session) |*s| s else return;
        _ = session.activeTab() orelse return;

        // self-paste 가드: 우리 자신이 마지막 clipboard owner 면 wayland 경유
        // 시 compositor 가 우리 source.send event 를 main thread 로 보내는데
        // 우리는 아래 posix.read 에서 blocking → wayland event 못 들어와
        // deadlock. 우리 buffer 직접 사용.
        if (self.active_data_source_id != 0) {
            if (self.clipboard_text) |text| {
                session.pasteToActive(text);
                self.requestRedraw();
            }
            return;
        }

        const pipe_fds = posix.pipe() catch return;
        // read end 는 우리, write end 는 wayland 가 보낼 송신측.
        const read_fd = pipe_fds[0];
        const write_fd = pipe_fds[1];

        self.sendStringWithFd(
            self.paste_offer_id,
            wl_data_offer_request_receive,
            clipboard_mime_utf8,
            write_fd,
        ) catch {
            posix.close(read_fd);
            posix.close(write_fd);
            return;
        };
        posix.close(write_fd); // 우리 쪽 write end 는 안 씀.

        // wayland 가 우리 송신 후 다른 쪽 fd 에 write 하기 시작. blocking read 로
        // 끝까지 (EOF) 받는다. text paste 가 일반적으로 짧고 fd 가 pipe 라 deadlock
        // 없음 — 송신측이 close 하면 우리 read 0 반환.
        defer posix.close(read_fd);
        var buf: [4096]u8 = undefined;
        var accumulated: std.ArrayList(u8) = .{};
        defer accumulated.deinit(self.allocator);
        while (true) {
            const n = posix.read(read_fd, &buf) catch break;
            if (n == 0) break;
            accumulated.appendSlice(self.allocator, buf[0..n]) catch break;
        }
        if (accumulated.items.len == 0) return;
        if (self.session) |*s| {
            s.pasteToActive(accumulated.items);
            self.requestRedraw();
        }
    }

    /// wl_data_source 이벤트 분기.
    /// - opcode 1: send(mime, fd) — compositor 가 paste 요청. fd 에 우리 clipboard
    ///   text 를 동기 write 후 close.
    /// - opcode 2: cancelled — 다른 앱이 clipboard 점유. 우리 source 정리.
    /// - 그 외 (target / dnd_*) — drag-and-drop 용이라 우리 흐름에 무관.
    fn handleDataSourceEvent(self: *Client, opcode: u16, payload: []const u8) !void {
        switch (opcode) {
            1 => try self.handleDataSourceSend(payload),
            2 => self.handleDataSourceCancelled(),
            else => {},
        }
    }

    fn handleDataSourceSend(self: *Client, payload: []const u8) !void {
        _ = payload; // mime 문자열은 우리가 advertise 한 유일 mime 라 검사 생략.
        const fd = self.takeReceivedFd() catch return;
        defer posix.close(fd);

        const text = self.clipboard_text orelse return;
        // fd 가 pipe 이므로 한 번에 다 못 보낼 수 있다 — 짧은 selection 위주라
        // loop 으로 끝까지 시도. SIGPIPE 는 wayland 가 자기 reader 쪽에서 처리한다.
        var offset: usize = 0;
        while (offset < text.len) {
            const n = posix.write(fd, text[offset..]) catch return;
            if (n == 0) break;
            offset += n;
        }
    }

    fn handleDataSourceCancelled(self: *Client) void {
        self.clearClipboardOwnership();
    }

    /// 활성 탭의 ghostty selection 을 추출해 wayland clipboard owner 로 등록.
    /// macOS / Windows 의 `tab_actions.copyActiveSelection` 와 결과 동등.
    fn copyActiveSelection(self: *Client) void {
        if (self.data_device_id == 0) return; // clipboard protocol 없음 — graceful.
        const tab = self.activeTabOrNull() orelse return;
        const screen = tab.terminal.screens.active;
        const sel = screen.selection orelse return;
        // ghostty selectionString 결과 ptr 의 ownership 이 우리 allocator 가 아니라
        // ghostty 의 자체 arena. 우리 GPA 로 free 하면 invalid free panic. dupe 로
        // 우리 buffer 만들어 그것만 보관 + free (#189 5차 시연 진단).
        const ghostty_text = screen.selectionString(self.allocator, .{ .sel = sel }) catch return;
        if (ghostty_text.len == 0) return;
        const owned = self.allocator.dupe(u8, ghostty_text) catch return;
        self.setClipboardText(owned) catch {
            self.allocator.free(owned);
        };
    }

    /// 새 clipboard text 로 owner 갱신. 기존 source 가 있으면 cleanup 후 새로.
    /// `text` ownership 을 self 가 가져간다. 호출 후 호출자는 free 하지 않는다.
    fn setClipboardText(self: *Client, text: []const u8) !void {
        if (self.last_serial == 0) {
            // 어떤 input event 도 아직 못 받았으면 wayland 가 set_selection 을 거부.
            // 실용적으로 거의 불가능한 path 지만 안전상 명시.
            self.allocator.free(text);
            return;
        }
        self.clearClipboardOwnership();

        const source_id = self.allocId();
        try self.sendNewId(
            self.data_device_manager_id,
            wl_data_device_manager_request_create_data_source,
            source_id,
        );
        try self.sendString(source_id, wl_data_source_request_offer, clipboard_mime_utf8);
        try self.sendArgs(
            self.data_device_id,
            wl_data_device_request_set_selection,
            &.{ source_id, self.last_serial },
        );

        self.active_data_source_id = source_id;
        self.clipboard_text = text;
    }

    fn clearClipboardOwnership(self: *Client) void {
        if (self.active_data_source_id != 0) {
            self.sendNoArgs(self.active_data_source_id, wl_data_source_request_destroy) catch {};
            self.active_data_source_id = 0;
        }
        if (self.clipboard_text) |buf| {
            self.allocator.free(buf);
            self.clipboard_text = null;
        }
    }

    /// surface pixel → grid cell. tab bar / padding 영역 / grid 범위 밖이면
    /// null. L12-α — grid 영역이 tab_bar_height_px + padding 만큼 아래로
    /// 밀려있으므로 py 의 origin 도 같이 보정.
    fn pixelToCell(self: *Client, px: i32, py: i32) ?terminal_interaction.Cell {
        const pad = self.renderer.paddingPx();
        const grid_top: i32 = self.effectiveTabBarHeightPx() + pad;
        if (px < pad or py < grid_top) return null;
        const cw = self.renderer.cellWidth();
        const ch = self.renderer.cellHeight();
        const tab = self.activeTabOrNull() orelse return null;
        const col_i32: i32 = @divTrunc(px - pad, cw);
        const row_i32: i32 = @divTrunc(py - grid_top, ch);
        if (col_i32 < 0 or row_i32 < 0) return null;
        const cols_i32: i32 = @intCast(tab.terminal.cols);
        const rows_i32: i32 = @intCast(tab.terminal.rows);
        if (col_i32 >= cols_i32 or row_i32 >= rows_i32) return null;
        return .{ .col = @intCast(col_i32), .row = @intCast(row_i32) };
    }

    fn activeTabOrNull(self: *Client) ?*session_core.Tab {
        if (self.session) |*session| return session.activeTab();
        return null;
    }

    fn takeReceivedFd(self: *Client) !posix.fd_t {
        if (self.received_fds.items.len == 0) return error.WaylandMissingFd;
        return self.received_fds.orderedRemove(0);
    }

    fn queueInput(self: *Client, bytes: []const u8) void {
        if (self.session) |*session| {
            session.queueInputToActive(bytes);
            self.requestRedraw();
        }
    }

    fn handleToplevelConfigure(self: *Client, payload: []const u8) !void {
        if (payload.len < 12) return error.WaylandBadMessage;
        // xdg-shell configure 의 width/height = *logical pixel* (compositor 단위).
        // 우리 내부 단위는 physical 이라 변환.
        self.pending_width = self.logicalToPhysical(readI32(payload[0..4]));
        self.pending_height = self.logicalToPhysical(readI32(payload[4..8]));
    }

    fn handleBufferEvent(self: *Client, id: u32, opcode: u16) bool {
        if (opcode != 0) return false;

        if (self.active_buffer) |*buffer| {
            if (buffer.id == id) {
                buffer.released = true;
                return true;
            }
        }

        for (self.retired_buffers.items) |*buffer| {
            if (buffer.id == id) {
                buffer.released = true;
                return true;
            }
        }

        // #203 Phase C — dialog surface 도 동일 release event 흐름. dialog 는
        // 정적이라 released 표시만 — refresh 시 in-place 재paint.
        if (self.dialog.active_buffer) |*buffer| {
            if (buffer.id == id) {
                buffer.released = true;
                return true;
            }
        }

        return false;
    }

    fn handleRegistryGlobal(self: *Client, payload: []const u8) !void {
        if (payload.len < 12) return error.WaylandBadMessage;
        const name = readU32(payload[0..4]);
        var p = Parser{ .buf = payload[4..] };
        const interface = try p.readString();
        const version = try p.readU32();
        self.caps.record(name, interface, version);
    }

    fn handleDisplayError(_: *Client, payload: []const u8) !void {
        if (payload.len < 12) return error.WaylandDisplayError;
        const object_id = readU32(payload[0..4]);
        const code = readU32(payload[4..8]);
        var p = Parser{ .buf = payload[8..] };
        const msg = p.readString() catch "(unparseable)";
        std.debug.print("Wayland protocol error: object={} code={} message={s}\n", .{ object_id, code, msg });
        log.appendLine("wayland", "protocol error object={} code={} message={s}", .{ object_id, code, msg });
        return error.WaylandDisplayError;
    }

    /// L9-α — D-Bus session bus 연결 시도. 실패는 fatal 아님 (portal 없는
    /// minimal Wayland session, libdbus 미설치 등) — log 만 남기고 진행.
    /// dbus_session 이 null 이면 후속 L9 sub-step 도 skip — hotkey 기능 미제공.
    /// L9-β-1 — 성공 시 곧바로 portal `CreateSession` 호출. 실패해도 fatal 아님
    /// (portal 미설치 / 사용자 거부 등).
    /// L9-γ — BindShortcuts 성공 후 곧바로 `Activated` signal subscribe.
    /// subscribe 실패해도 fatal 아님 — hotkey 미동작이라도 terminal 자체는 OK.
    fn tryConnectDbus(self: *Client) void {
        const session = dbus.SessionBus.connect() catch |err| {
            log.appendLine("dbus", "session bus connect skipped: {s} — hotkey 기능 비활성", .{@errorName(err)});
            return;
        };
        self.dbus_session = session;
        const portal_session = portal.createGlobalShortcutsSession(self.allocator, &self.dbus_session.?) catch |err| {
            log.appendLine("portal", "CreateSession skipped: {s} — hotkey 기능 비활성", .{@errorName(err)});
            return;
        };
        self.portal_session = portal_session;
        // L9-β-2 — 단일 "toggle" shortcut 등록. 첫 호출 시 KDE / GNOME portal
        // UI dialog 뜸 (사용자 승인). 실패해도 fatal 아님 — session 은 살아
        // 있고 다음 실행에서 재시도 가능. 실패 시 Activated subscribe 도 skip
        // (shortcut bound 안 됐으니 signal 도 안 옴).
        portal.bindToggleShortcut(
            self.allocator,
            &self.dbus_session.?,
            self.portal_session.?.session_handle,
            self.config.hotkey.keysym,
            self.config.hotkey.modifiers,
        ) catch |err| {
            log.appendLine("portal", "BindShortcuts skipped: {s} — hotkey 기능 비활성", .{@errorName(err)});
            return;
        };
        // L9-γ — Activated signal subscribe. 이후 main loop 의
        // `dispatchDbusMessages` 가 매 iteration `read_write_dispatch(0)` 호출
        // → filter callback (`onPortalActivated`) 가 우리 toggle 발동.
        log.appendLine("portal", "subscribing Activated signal...", .{});
        const sub = portal.subscribeActivatedSignal(
            self.allocator,
            &self.dbus_session.?,
            self.portal_session.?.session_handle,
            onPortalActivated,
            self,
        ) catch |err| {
            log.appendLine("portal", "Activated subscribe skipped: {s} — hotkey 비활성", .{@errorName(err)});
            return;
        };
        self.portal_subscription = sub;
    }

    /// L9-γ — main loop 매 iteration 마다 dbus 의 들어온 message 를 dispatch.
    /// `read_write_dispatch(conn, 0)` 는 socket 의 pending data read + 누적된
    /// message dispatch (filter callback 호출 포함) + 0 timeout 이라 즉시 반환.
    /// dbus fd 를 wayland fd 와 함께 poll 통합하는 대신 매 iteration 0-timeout
    /// dispatch 호출 — frame_poll_ms (16ms) 가 wayland poll timeout 이라 hotkey
    /// latency 도 같은 수준으로 충분 (60Hz 한 frame).
    fn dispatchDbusMessages(self: *Client) void {
        if (self.dbus_session) |*bus| {
            const r = bus.api.read_write_dispatch(bus.conn, 0);
            // r == 0 은 connection disconnected — fatal 아니지만 hotkey 더 안 옴.
            if (r == 0) {
                log.appendLine("portal", "dbus connection disconnected — hotkey routing stopped", .{});
            }
        }
    }

    /// L9-γ — portal `Activated` signal filter callback. `shortcut_id` 가
    /// "toggle" 이면 surface visibility flip. 같은 timestamp 의 중복 호출은
    /// debounce (compositor 가 한 누름에 두 번 보낼 가능성 hedge). 0 timestamp
    /// 면 debounce 안 함 (compositor 미채움 — 매번 toggle).
    fn onPortalActivated(user_data: ?*anyopaque, shortcut_id: []const u8, timestamp: u64) void {
        const self: *Client = @ptrCast(@alignCast(user_data.?));
        // #207 진단 — Activated signal 도달 확인 (시연 단계, fix 확정 후 제거).
        log.appendLine("portal", "Activated signal received — shortcut_id={s} timestamp={}", .{ shortcut_id, timestamp });
        if (!std.mem.eql(u8, shortcut_id, std.mem.span(portal.shortcut_id_toggle))) return;
        if (timestamp != 0 and timestamp == self.last_toggle_timestamp) return;
        self.last_toggle_timestamp = timestamp;
        self.handleActivatedToggle() catch |err| {
            log.appendLine("portal", "toggle failed: {s}", .{@errorName(err)});
        };
    }

    /// L9-γ — surface visibility flip. mac `toggleWindow` 동등 — hide 시점에
    /// `commitPendingInput` (preedit / rename buf 보존). show 는 `mapped=false`
    /// + `requestRedraw` 로 maybeRedraw 가 buffer 다시 attach (자연 re-map).
    ///
    /// hide / show — wl_surface + layer_surface (또는 xdg_toplevel + xdg_surface)
    /// 둘 다 destroy / recreate.
    ///
    /// 배경:
    /// - [wlr-layer-shell spec](https://wayland.app/protocols/wlr-layer-shell-unstable-v1)
    ///   는 "perform a commit without any buffer attached, waiting for a
    ///   configure event" 로 re-map 가능하다고 명시.
    /// - 시연 사이클 (KDE Plasma 6.6.5 + xdg-desktop-portal-kde) 에서 그 sequence
    ///   가 동작 안 함 — `commit only` 후 compositor 가 configure event 안 보냄.
    ///   KWin 의 wlr-layer-shell impl 이 spec 의 commit-only re-map 안 따르는
    ///   것으로 보임. 검증된 reference (wlroots compositor: Sway / Hyprland)
    ///   환경에선 commit-only re-map 동작 가능.
    /// - [wayland-book](https://wayland-book.com/) 의 "Destroying the role
    ///   object does not remove the role from the wl_surface" 에 따라, role
    ///   object (layer_surface) 만 destroy 후 같은 wl_surface 에 new role
    ///   부여는 protocol error 가능 — wl_surface 도 destroy + recreate 필수.
    ///
    /// → 모든 compositor 일관 동작 위해 destroy + recreate 정공 채택.
    fn handleActivatedToggle(self: *Client) !void {
        if (self.surface_hidden) {
            // #205 — show phase elapsed timer. portal Activated → first frame.
            // configure handler / ensureSessionGrid / redraw 가 후속 호출에서
            // 발생하므로 그 site 에 별도 logShowElapsed.
            self.show_timer = std.time.Timer.start() catch null;
            self.surface_hidden = false;
            // 첫 show (hidden_start=true 의 첫 portal Activated) 면 surface 아직
            // 안 만들어졌으므로 full create. 이후 hide/show cycle 은 unmap/remap
            // path (#205 — wl_surface + layer_surface 유지가 ~165ms → ~16ms 줄임,
            // KWin Bug 503121 의 kitty workaround pattern).
            if (self.surface_id == 0) {
                try self.createShellObjects();
                self.logShowElapsed("createShellObjects (first show)");
                log.appendLine("portal", "toggle show — created shell objects (first)", .{});
            } else {
                try self.remapShellObjects();
                self.logShowElapsed("remapShellObjects");
                log.appendLine("portal", "toggle show — remapped shell objects (#205)", .{});
            }
            return;
        }
        // hide 진입 — mac #175 동등 정책: preedit / rename buf commit (cancel
        // 아님), 다음 show 때 사용자가 이어서 작업 가능.
        self.commitPendingInput();
        try self.unmapShellObjects();
        self.surface_hidden = true;
        log.appendLine("portal", "toggle hide — unmapped shell objects (#205)", .{});
    }

    /// #205 — kitty pattern hide: `wl_surface.attach(null) + commit`. wl_surface
    /// + layer_surface + buffer 모두 유지 — show 시 fresh surface mapping cost
    /// (~165ms) 회피. configure 다시 받아야 하므로 `configured=false` reset.
    ///
    /// active_buffer / retired_buffers 는 유지 — 다음 paint 가 재사용 가능.
    /// kitty 의 `swaps_disallowed=true` 와 동등 효과는 `surface_hidden=true` +
    /// `redraw()` 의 가드.
    fn unmapShellObjects(self: *Client) !void {
        if (self.surface_id != 0) {
            // wl_surface.attach (opcode 1) — buffer=null (id 0) + x=0 + y=0.
            try self.sendArgs(self.surface_id, 1, &.{ 0, 0, 0 });
            // wl_surface.commit (opcode 6) — pending state (= null buffer) 적용.
            try self.sendNoArgs(self.surface_id, 6);
        }
        self.configured = false;
        self.mapped = false;
        // issue #196: 이전 frame callback 은 unmap 후 더 이상 fire 안 함.
        // 재 map 후 첫 attachAndCommit 가 새 frame request — reset 필수.
        self.frame_callback_id = 0;
        self.awaiting_frame = false;
    }

    /// #205 — kitty pattern show: layer properties 재송신 + commit. KWin Bug
    /// 503121 workaround — KWin 의 wlr-layer-shell 이 "commit-only re-map"
    /// (= commit 만으로 configure 트리거) 미구현. set_anchor / set_size /
    /// set_exclusive_zone / set_margin / set_keyboard_interactivity 재송신
    /// → KWin 이 *state 변경* 으로 인식 → configure event 발신.
    ///
    /// Sway / Hyprland 등 wlroots 계열은 commit-only 만으로 충분하지만 redundant
    /// set_* 도 spec 가 명시 prohibit 안 함 + double-buffered 라 idempotent
    /// 효과 (compositor 가 pending state overwrite). kitty 가 모든 compositor
    /// 에 동일 path 적용 — compositor 분기 불필요.
    ///
    /// configure 도착 시 handler 가 `configured=true` set + `requestRedraw` —
    /// 다음 main loop redraw 가 active_buffer (유지된 것) 재 attach + commit.
    fn remapShellObjects(self: *Client) !void {
        if (self.layer_surface_id != 0) {
            try self.sendLayerSurfaceLayout();
        } else if (self.surface_id != 0) {
            // xdg-shell fallback (mutter 등) — set_* 같은 toplevel state 송신
            // 필요. 일단 commit 만 — 충분한지 검증 필요 (현재 xdg-shell 환경
            // 에서 unmap/remap 시연 안 됨).
            try self.sendNoArgs(self.surface_id, 6);
        }
    }

    /// wl_surface + role object (layer_surface 또는 xdg_toplevel+xdg_surface) +
    /// 모든 wl_buffer destroy. pending/active flag reset. hide path 의 핵심.
    fn destroyShellObjects(self: *Client) !void {
        // 모든 buffer destroy + release. compositor 가 surface destroy 시 자체
        // 적으로 attach 해제하지만, 우리 wl_buffer object 는 직접 destroy.
        if (self.active_buffer) |*buffer| {
            self.destroyBufferObject(buffer.id);
            buffer.deinit();
            self.active_buffer = null;
        }
        for (self.retired_buffers.items) |*buffer| {
            self.destroyBufferObject(buffer.id);
            buffer.deinit();
        }
        self.retired_buffers.clearRetainingCapacity();

        // layer_surface destroy (opcode 7).
        if (self.layer_surface_id != 0) {
            try self.sendNoArgs(self.layer_surface_id, zwlr_layer_surface_v1_request_destroy);
            self.layer_surface_id = 0;
        }
        // xdg_toplevel.destroy (opcode 0) + xdg_surface.destroy (opcode 0) —
        // layer-shell fallback path (mutter 등 GNOME).
        if (self.toplevel_id != 0) {
            try self.sendNoArgs(self.toplevel_id, 0);
            self.toplevel_id = 0;
        }
        if (self.xdg_surface_id != 0) {
            try self.sendNoArgs(self.xdg_surface_id, 0);
            self.xdg_surface_id = 0;
        }
        // fractional scaling — viewport + fractional_scale_v1 destroy. surface
        // 보다 먼저 destroy (둘 다 surface 의 extension 이라 surface 보다 nested).
        if (self.viewport_id != 0) {
            try self.sendNoArgs(self.viewport_id, wp_viewport_request_destroy);
            self.viewport_id = 0;
        }
        if (self.fractional_scale_id != 0) {
            try self.sendNoArgs(self.fractional_scale_id, wp_fractional_scale_v1_request_destroy);
            self.fractional_scale_id = 0;
        }
        // wl_surface destroy (opcode 0).
        if (self.surface_id != 0) {
            try self.sendNoArgs(self.surface_id, 0);
            self.surface_id = 0;
        }

        self.mapped = false;
        self.configured = false;
        // issue #196: surface destroy → 이전 frame callback 은 더 이상 fire
        // 안 함 (surface 가 사라졌으니 compositor 가 callback 발신 안 함).
        // 재생성 (show) 후 첫 redraw 가 막히지 않도록 reset.
        self.frame_callback_id = 0;
        self.awaiting_frame = false;
    }

    /// #203 Phase C — info / error dialog 표시. content 저장 + box 크기 계산 →
    /// dialog surface 생성 (이미 떠 있으면 새 크기로 재생성). cross-platform
    /// `dialog.showInfo` / `dialog.showAboutAlert` 등의 종착점 (dialog/linux.zig
    /// callback 통과). fire-and-forget — 사용자가 Enter / Esc / 클릭으로 dismiss.
    fn openInfoDialog(self: *Client, severity: dialog_mod.Severity, title: []const u8, message: []const u8) !void {
        try self.openDialog(.info, severity, title, message);
    }

    /// #203 Phase C step 4 — confirm dialog (OK + Cancel). `dialogShowConfirmCb`
    /// 의 inner pump 가 결과 (`pending_confirm_result`) 를 받아 호출자에게 반환.
    /// dismiss 전 default `pending_confirm_result = null` — Cancel 등 명시 결정.
    fn openConfirmDialog(self: *Client, title: []const u8, message: []const u8) !void {
        try self.openDialog(.confirm, .info, title, message);
    }

    fn openDialog(self: *Client, kind: DialogOverlay.Kind, severity: dialog_mod.Severity, title: []const u8, message: []const u8) !void {
        const title_len = @min(title.len, self.dialog.title_buf.len);
        const msg_len = @min(message.len, self.dialog.msg_buf.len);
        @memcpy(self.dialog.title_buf[0..title_len], title[0..title_len]);
        @memcpy(self.dialog.msg_buf[0..msg_len], message[0..msg_len]);
        self.dialog.title_len = title_len;
        self.dialog.msg_len = msg_len;
        self.dialog.kind = kind;
        self.dialog.severity = severity;
        // Confirm pending 새로 시작 — 이전 dialog 의 result 가 남아 있을 가능성 0.
        self.pending_confirm_result = null;

        // 박스 크기 — 텍스트 폭 / 라인 수 기반 (renderer 가 cell metric 으로
        // 계산). physical → logical 변환해 layer-shell 에 송신.
        const size = self.renderer.computeDialogSize(self.dialog.title(), self.dialog.message(), kind == .confirm);
        const logical_w: u32 = @intCast(self.physicalToLogical(size.w));
        const logical_h: u32 = @intCast(self.physicalToLogical(size.h));

        // 이미 떠 있으면 destroy 후 새 크기로 재생성. 같은 surface 에 set_size
        // 만 다시 보낼 수도 있으나, buffer 크기 / configure 흐름 일관성을 위해
        // recreate. 사용자가 같은 dialog 를 두 번 못 띄우는 시나리오라 부담 없음.
        if (self.dialog.surface_id != 0) {
            try self.destroyDialogSurface();
        }
        try self.createDialogSurface(logical_w, logical_h);
        log.appendLine("dialog", "open {s} severity={s} title={s} msg_len={d} logical={}x{}", .{
            @tagName(kind), @tagName(severity), self.dialog.title(), msg_len, logical_w, logical_h,
        });
    }

    /// #203 Phase C — dialog 닫기. focus return 정통 fix (xdg-activation-v1):
    ///   1) dialog (현 활성) 가 token 발급 요청
    ///   2) roundtrip 으로 done event 동기 wait
    ///   3) token 으로 main_surface activate 요청
    ///   4) token destroy + dialog surface destroy + kind=.none
    ///
    /// KWin 의 layer-shell focus return 거동이 pointer 위치 기반이라 (시연
    /// 진단 확정 — 16:55:48 / 16:55:54 등 로그 패턴), xdg-activation 표준
    /// 으로 명시 양도 신호. xdg_activation_v1 미advertise 환경은 fallback
    /// (자동 focus return 안 됨, 사용자 직접 main 클릭 필요).
    ///
    /// 출처: https://wayland.app/protocols/xdg-activation-v1
    /// step 4 에서 confirm result 전달 추가.
    /// #203 Phase C — dismiss 요청 (deferred). 진짜 dismiss 는 main loop 의
    /// `drainPendingDialogDismiss` 가 호출. inner roundtrip reentrancy 차단.
    fn requestDismissDialog(self: *Client) void {
        if (self.dialog.kind == .none) return;
        self.pending_dialog_dismiss = true;
    }

    /// main loop 에서 매 iteration 호출. pending flag 가 set 이면 실제 dismiss
    /// 수행. dispatchBuffered 의 reentrant context 밖이라 roundtrip 안전.
    fn drainPendingDialogDismiss(self: *Client) void {
        if (!self.pending_dialog_dismiss) return;
        self.pending_dialog_dismiss = false;
        self.dismissDialog();
    }

    /// #203 Phase C step 4 — Alt+F4 quit confirm. mac `applicationShouldTerminate:`
    /// / Win `app_controller.onQuitRequest` 동등 정책 — count == 0 (PTY 자동
    /// 종료) 만 skip, 단일 / 다중 탭 *항상* confirm. `dialog.showConfirm` 이 inner
    /// pump 라 main loop 의 deferred phase 에서 호출 (outer dispatchBuffered
    /// reentrancy 안전).
    /// #213 — Ctrl+Shift+I 가 set 한 deferred About 를 main loop 에서 실제 표시.
    /// `about.showAboutDialog` → `dialog.showAboutAlert` → `openInfoDialog` →
    /// `createDialogSurface` 가 inner roundtrip (dispatchBuffered) 을 돌리는데,
    /// 여기는 outer dispatchBuffered 밖이라 reentrancy 위험 없음. dismiss /
    /// quit 의 deferred 패턴과 동일.
    fn drainAboutRequest(self: *Client) void {
        if (!self.pending_about_request) return;
        self.pending_about_request = false;
        about.showAboutDialog();
    }

    /// #216 — KWin Alt+F4 `closed` 후 메인 surface 를 **깜박임 없이** 교체.
    ///
    /// KWin 은 `closed` 를 보낸 뒤에도 메인 surface 의 마지막 frame 을 화면에
    /// *유지* 한다 (사용자 시연 확정 — Cancel 전까지 터미널이 다이얼로그 뒤에
    /// 계속 보임). 따라서 깜박임의 원인은 KWin 의 unmap 이 아니라 우리의
    /// `destroyShellObjects`(→ 유지 frame 제거 → 데스크톱 노출) → `createShellObjects`
    /// (→ 재 paint) **순서** 였다.
    ///
    /// fix = **create-before-destroy**: 옛 surface 객체를 스냅샷으로 보존한 채
    /// (KWin 이 옛 frame 계속 표시), 새 surface 를 만들어 첫 frame 까지 paint 한
    /// *뒤에* 옛 surface 를 destroy. 옛 frame 이 새 frame 준비될 때까지 화면에
    /// 남아 빈 frame (깜박임) 이 없다. `closed` 된 옛 surface 는 protocol 상 재사용
    /// 불가라 새로 만들어야 하고, 새 surface 는 다음 Alt+F4 `closed` 도 다시 받는다.
    fn swapMainSurfaceSeamless(self: *Client) void {
        // 옛 surface 객체 스냅샷 — destroy 는 새 frame paint 후로 미룬다.
        const old_surface_id = self.surface_id;
        const old_layer_surface_id = self.layer_surface_id;
        const old_viewport_id = self.viewport_id;
        const old_fractional_scale_id = self.fractional_scale_id;
        const old_xdg_surface_id = self.xdg_surface_id;
        const old_toplevel_id = self.toplevel_id;
        var old_active = self.active_buffer;
        var old_retired = self.retired_buffers;

        // self 필드 초기화 → createShellObjects 가 fresh id 할당. 옛 객체는
        // 스냅샷이 보유 (KWin 이 옛 frame 화면에 유지).
        self.surface_id = 0;
        self.layer_surface_id = 0;
        self.viewport_id = 0;
        self.fractional_scale_id = 0;
        self.xdg_surface_id = 0;
        self.toplevel_id = 0;
        self.active_buffer = null;
        self.retired_buffers = .{};
        self.configured = false;
        self.mapped = false;
        self.frame_callback_id = 0;
        self.awaiting_frame = false;

        // 새 surface 생성 + 첫 frame 동기 paint (옛 frame 위에 동일 내용 올림).
        self.createShellObjects() catch |err| {
            log.appendLine("dialog", "swapMainSurface: createShellObjects failed: {s} — fatal", .{@errorName(err)});
            self.running = false;
            return;
        };
        // 새 layer-surface 첫 configure 까지 pump (bounded — 안 오면 main loop 의
        // 다음 redraw 가 그림). drainQuitRequest 는 outer dispatchBuffered 밖에서
        // 호출되어 reentrancy 안전 (#213 무관).
        var tries: u8 = 0;
        while (!self.configured and tries < 64) : (tries += 1) {
            self.readAndDispatch() catch break;
        }
        self.needs_redraw = true;
        _ = self.redraw() catch |err| {
            log.appendLine("dialog", "swapMainSurface: redraw failed: {s}", .{@errorName(err)});
        };

        // 새 frame 이 올라왔으니 옛 surface destroy (KWin 이 유지하던 옛 frame 제거).
        if (old_active) |*buffer| {
            self.destroyBufferObject(buffer.id);
            buffer.deinit();
        }
        for (old_retired.items) |*buffer| {
            self.destroyBufferObject(buffer.id);
            buffer.deinit();
        }
        old_retired.deinit(self.allocator);
        if (old_layer_surface_id != 0) self.sendNoArgs(old_layer_surface_id, zwlr_layer_surface_v1_request_destroy) catch {};
        if (old_toplevel_id != 0) self.sendNoArgs(old_toplevel_id, 0) catch {};
        if (old_xdg_surface_id != 0) self.sendNoArgs(old_xdg_surface_id, 0) catch {};
        if (old_viewport_id != 0) self.sendNoArgs(old_viewport_id, wp_viewport_request_destroy) catch {};
        if (old_fractional_scale_id != 0) self.sendNoArgs(old_fractional_scale_id, wp_fractional_scale_v1_request_destroy) catch {};
        if (old_surface_id != 0) self.sendNoArgs(old_surface_id, 0) catch {};

        log.appendLine("dialog", "swapMainSurface — create-before-destroy (new surface_id={} configured={})", .{ self.surface_id, self.configured });
    }

    fn drainQuitRequest(self: *Client) void {
        if (!self.pending_quit_request) return;
        self.pending_quit_request = false;
        log.appendLine("dialog", "drainQuitRequest — calling dialog.showConfirm", .{});

        const n: usize = if (self.session) |*session| session.count() else 0;
        if (n == 0) {
            self.running = false;
            return;
        }

        const plural: []const u8 = if (n == 1) "" else "s";
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, messages.quit_confirm_format, .{ n, plural }) catch {
            self.running = false;
            return;
        };
        // 다이얼로그 동안엔 KWin 이 옛 메인 frame 을 유지 → 터미널이 뒤에 보임
        // (원래 동작, Alt+F4 시점 깜박임 없음).
        if (dialog_mod.showConfirm(messages.quit_confirm_title, msg)) {
            self.running = false;
            return;
        }
        // Cancel — `closed` 된 메인 surface 를 create-before-destroy 로 깜박임 없이
        // 교체. 다음 Alt+F4 가 다시 동작하려면 새 surface 필요 (#216).
        self.swapMainSurfaceSeamless();
    }

    fn dismissDialog(self: *Client) void {
        if (self.dialog.kind == .none) return;
        log.appendLine("dialog", "dismiss kind={s}", .{@tagName(self.dialog.kind)});

        // #203 Phase C — 진입 *즉시* kind=.none. (1) inner roundtrip 중 다른
        // button event 처리 → dismissDialog 재호출 시 위 early-return 으로 차단.
        // (2) 사용자 시연 발견 crash 의 한 축 — focus 없는 dialog 가 activation
        // token 발급 시 KWin protocol error → connection 종료 → exit 의 cause
        // 가 재진입 가능 path 도 포함.
        self.dialog.kind = .none;

        // (1~3) xdg-activation token 발급 + main activate. 실패해도 fallback
        // (focus return 안 되지만 dialog 는 정상 dismiss).
        self.requestMainFocusViaActivation() catch |err| {
            log.appendLine("dialog", "focus return via xdg-activation failed: {s} — fallback (focus 수동)", .{@errorName(err)});
        };

        self.destroyDialogSurface() catch |err| {
            log.appendLine("dialog", "destroyDialogSurface in dismiss failed: {s}", .{@errorName(err)});
        };
    }

    /// #203 Phase C — xdg-activation-v1 표준으로 main surface 에 focus 양도.
    /// dialog 가 *현 활성* 상태에서만 호출 가능 (compositor 가 활성 surface
    /// 의 token 만 발급). xdg_activation_v1 미advertise / main 미존재 / token
    /// done 안 옴 모두 graceful fallback.
    ///
    /// **사용자 시연 발견 crash fix**: spec 명시 "The compositor may use this
    /// information to verify that the request comes from a focused window."
    /// 시연: dialog 가 focus 잃은 후 (다른 앱으로 양도) 어떤 클릭이든 →
    /// dismissDialog → 여기 → KWin 이 *focus 없는 surface* 의 token 요청을
    /// protocol error 로 응답 → wayland connection 종료 → tildaz exit.
    /// 가드: dialog 가 *실제 keyboard focus* 일 때만 token 발급. 아니면 skip
    /// (사용자가 이미 다른 surface 에 focus 줬으니 자동 return 의미 없음).
    fn requestMainFocusViaActivation(self: *Client) !void {
        if (self.xdg_activation_id == 0) return; // compositor 미지원
        if (self.surface_id == 0) return; // main 미존재 (hidden 등)
        if (self.dialog.surface_id == 0) return; // dialog 이미 사라짐
        if (self.last_keyboard_focus_surface_id != self.dialog.surface_id) {
            // dialog 가 keyboard focus 가 아님 — 사용자가 이미 다른 곳에 focus
            // 양도. token 발급 자체가 spec 위반 + KWin 의 protocol error 유발
            // path. skip + log (focus 자동 return 의미도 없음).
            log.appendLine("dialog", "skip xdg-activation: dialog not focused (kbd_focus={} dialog_surface={})", .{ self.last_keyboard_focus_surface_id, self.dialog.surface_id });
            return;
        }

        // (1) get_activation_token — 새 token object id.
        const token_id = self.allocId();
        try self.sendNewId(self.xdg_activation_id, xdg_activation_v1_request_get_activation_token, token_id);

        self.pending_activation_token_id = token_id;
        self.pending_activation_token_done = false;
        self.pending_activation_token.clearRetainingCapacity();

        // (2) set_serial (마지막 input event serial + seat) + set_surface (현
        // 활성 = dialog) + commit. compositor 가 done event 로 token 응답.
        if (self.seat_id != 0) {
            try self.sendArgs(token_id, xdg_activation_token_v1_request_set_serial, &.{ self.last_serial, self.seat_id });
        }
        try self.sendArgs(token_id, xdg_activation_token_v1_request_set_surface, &.{self.dialog.surface_id});
        try self.sendNoArgs(token_id, xdg_activation_token_v1_request_commit);

        // (3) done event 동기 wait — roundtrip 동안 dispatchBuffered 가 위
        // handleEvent 의 token done 분기로 들어가 pending_activation_token 채움.
        try self.roundtrip();

        if (!self.pending_activation_token_done) {
            // done 안 옴 — token destroy + 종료.
            try self.sendNoArgs(token_id, xdg_activation_token_v1_request_destroy);
            self.pending_activation_token_id = 0;
            return error.ActivationTokenTimeout;
        }

        // (4) activate(token_string, main_surface) — compositor 가 main 활성화.
        var msg = Msg.init(self.xdg_activation_id, xdg_activation_v1_request_activate);
        try msg.putString(self.pending_activation_token.items);
        try msg.putU32(self.surface_id);
        try msg.send(self.stream);

        // token object destroy.
        try self.sendNoArgs(token_id, xdg_activation_token_v1_request_destroy);
        self.pending_activation_token_id = 0;
        log.appendLine("dialog", "xdg-activation token activated for main surface_id={}", .{self.surface_id});
    }

    /// dialog 활성 시 모든 키 라우팅. SPEC §6 — Enter / Esc / 클릭 dismiss.
    /// 그 외 키 무시 (modal). Confirm 모드: Enter = OK (true), Esc = Cancel (false).
    fn handleDialogKey(self: *Client, key: u32) void {
        const xkb_key = key + wayland_xkb_keycode_offset;
        const sym = self.keyboard.oneSym(xkb_key) orelse return;
        switch (sym) {
            xkb_key_return => {
                if (self.dialog.kind == .confirm) self.pending_confirm_result = true;
                self.requestDismissDialog();
            },
            xkb_key_escape => {
                if (self.dialog.kind == .confirm) self.pending_confirm_result = false;
                self.requestDismissDialog();
            },
            else => {}, // modal — 다른 키 swallow
        }
    }

    /// pointer 가 *dialog surface-local* rect 안인지. `last_dialog_*_rect`
    /// 가 그리기 때 set + destroyDialogSurface 가 reset (w == 0 → 자동 miss).
    fn hitDialogRect(self: *const Client, r: anytype) bool {
        return r.w > 0 and
            self.pointer_x_px >= r.x and self.pointer_x_px < r.x + r.w and
            self.pointer_y_px >= r.y and self.pointer_y_px < r.y + r.h;
    }

    /// 별 layer-shell `overlay` surface 생성. 새 wl_surface + zwlr_layer_surface
    /// (layer=overlay, anchor=0 → compositor 중앙 배치, set_size=박스 크기,
    /// set_keyboard_interactivity=exclusive). 첫 commit 은 buffer 없이 send —
    /// layer-shell spec: "buffer 는 첫 configure event ack 전에 attach 불가".
    /// `handleDialogConfigure` 가 ack + buffer attach 담당.
    fn createDialogSurface(self: *Client, logical_w: u32, logical_h: u32) !void {
        if (self.dialog.surface_id != 0) return;
        if (self.layer_shell_id == 0) {
            // xdg-shell fallback 환경 (GNOME mutter 등) — layer-shell overlay
            // 미가용. log + 즉시 dismiss state 로 — 사용자가 dialog 호출했는데
            // 영영 안 뜨는 trap 회피. (xdg-popup fallback 은 후속 별 작업.)
            log.appendLine("dialog", "createDialogSurface skipped — zwlr_layer_shell_v1 unavailable", .{});
            self.dialog.kind = .none;
            return;
        }
        self.dialog.surface_id = self.allocId();
        try self.sendNewId(self.compositor_id, 0, self.dialog.surface_id);

        // viewporter (fractional scaling) — main surface 와 동일 패턴.
        if (self.viewporter_id != 0) {
            self.dialog.viewport_id = self.allocId();
            try self.sendArgs(
                self.viewporter_id,
                wp_viewporter_request_get_viewport,
                &.{ self.dialog.viewport_id, self.dialog.surface_id },
            );
        }
        // #210 — dialog 자체 fractional_scale 객체 + roundtrip 으로 preferred_scale
        // event 받음 보장. dialog 가 main createShellObjects *이전* 호출 시
        // (boot 중 portal Hotkey updated 등) main 의 preferred_scale 가 아직
        // default 120 (1x) → dialog physical=logical (1x 표시) → click 좌표
        // 변환 mismatch (main 의 1.7x 변환 잘못 적용) 의 cause. main 의
        // createShellObjects 와 같은 pattern.
        if (self.fractional_scale_manager_id != 0) {
            self.dialog.fractional_scale_id = self.allocId();
            try self.sendArgs(
                self.fractional_scale_manager_id,
                wp_fractional_scale_manager_v1_request_get_fractional_scale,
                &.{ self.dialog.fractional_scale_id, self.dialog.surface_id },
            );
            try self.roundtrip();
        }

        // get_layer_surface(new_id, surface, output=NULL, layer=OVERLAY, namespace).
        // overlay layer 라 panel / 알림 위까지 덮음 — modal 가시화.
        self.dialog.layer_surface_id = self.allocId();
        var msg = Msg.init(self.layer_shell_id, zwlr_layer_shell_v1_request_get_layer_surface);
        try msg.putU32(self.dialog.layer_surface_id);
        try msg.putU32(self.dialog.surface_id);
        try msg.putU32(0);
        try msg.putU32(zwlr_layer_shell_layer_overlay);
        try msg.putString("tildaz-dialog");
        try msg.send(self.stream);

        try self.sendArgs(
            self.dialog.layer_surface_id,
            zwlr_layer_surface_v1_request_set_size,
            &.{ logical_w, logical_h },
        );
        try self.sendArgs(
            self.dialog.layer_surface_id,
            zwlr_layer_surface_v1_request_set_anchor,
            &.{0},
        );
        // exclusive — modal 입력. 사용자가 main surface 클릭해도 키 입력은
        // 우리 dialog 로 옴.
        try self.sendArgs(
            self.dialog.layer_surface_id,
            zwlr_layer_surface_v1_request_set_keyboard_interactivity,
            &.{zwlr_layer_surface_keyboard_interactivity_exclusive},
        );
        try self.sendNoArgs(self.dialog.surface_id, 6);

        log.appendLine("dialog", "createDialogSurface surface_id={} layer_surface_id={} size={}x{} (logical) layer=overlay anchor=0 keyboard=exclusive", .{
            self.dialog.surface_id,
            self.dialog.layer_surface_id,
            logical_w,
            logical_h,
        });
    }

    /// dialog surface 의 모든 wayland 객체 destroy. content state (kind /
    /// title / message) 는 caller 가 별도 관리 — 본 함수는 wayland 객체만.
    ///
    /// 이전 시도 (focus v1: main 의 set_keyboard_interactivity 재송신,
    /// focus v2: dialog 의 keyboard_interactivity=none 토글) 모두 시연 실패 +
    /// 진짜 분석으로 잘못된 방향 확정 (Sway #7936 / Hyprland #8293 / Wayfire
    /// #1204 — wlroots 기반 모두 같은 패턴이 *compositor 측 버그* 였고 *client*
    /// 측 fix 불가). 사용자 단서: pointer 가 main 위에 있을 때만 focus 자동
    /// 복귀 → KWin 의 focus return 이 pointer 위치 기반. xdg-activation-v1
    /// 표준으로 정공 fix (focus 가드 포함). 자세한 학습 기록은 #203 코멘트 chain.
    fn destroyDialogSurface(self: *Client) !void {
        if (self.dialog.surface_id == 0) return;

        if (self.dialog.active_buffer) |*buffer| {
            self.destroyBufferObject(buffer.id);
            buffer.deinit();
            self.dialog.active_buffer = null;
        }
        if (self.dialog.layer_surface_id != 0) {
            try self.sendNoArgs(self.dialog.layer_surface_id, zwlr_layer_surface_v1_request_destroy);
            self.dialog.layer_surface_id = 0;
        }
        if (self.dialog.viewport_id != 0) {
            try self.sendNoArgs(self.dialog.viewport_id, wp_viewport_request_destroy);
            self.dialog.viewport_id = 0;
        }
        if (self.dialog.fractional_scale_id != 0) {
            try self.sendNoArgs(self.dialog.fractional_scale_id, wp_fractional_scale_v1_request_destroy);
            self.dialog.fractional_scale_id = 0;
        }
        try self.sendNoArgs(self.dialog.surface_id, 0);
        self.dialog.surface_id = 0;
        self.dialog.configured = false;
        self.dialog.buffer_w = 0;
        self.dialog.buffer_h = 0;
        // #203 Phase C — OK / Cancel 버튼 hit-test 좌표 reset. dialog 없는 동안
        // stale rect 로 hit 되지 않게. Confirm pending 도 reset (dismiss 가 결과
        // 미설정 시 default Cancel 보장).
        self.renderer.last_dialog_ok_rect = .{};
        self.renderer.last_dialog_cancel_rect = .{};
        log.appendLine("dialog", "destroyDialogSurface", .{});
    }

    /// dialog surface buffer painting. `drawDialogContent` 호출 — title /
    /// separator / message / footer / border / alpha sweep 모두 renderer 처리.
    /// step 4 — confirm 모드 (`kind == .confirm`) 면 `confirm_focus_ok = true`
    /// 전달 (OK 버튼 + Cancel 버튼 그림). Info 모드 면 null (OK 하나만).
    fn paintDialogBuffer(self: *Client, memory: []u8, w: i32, h: i32, stride: i32) void {
        const focus_arg: ?bool = if (self.dialog.kind == .confirm) true else null;
        self.renderer.drawDialogContent(
            memory,
            w,
            h,
            stride,
            self.dialog.severity,
            self.dialog.title(),
            self.dialog.message(),
            focus_arg,
        );
    }

    /// dialog surface 용 buffer 생성. main createBuffer 패턴 (memfd + mmap +
    /// shm pool + wl_buffer). main 의 retired_buffers cycle 미사용 — dialog 는
    /// configure 한 번에 그리고 dismiss 까지 그대로.
    fn createDialogBuffer(self: *Client, width: i32, height: i32) !ShmBuffer {
        const stride: i32 = width * 4;
        const size_i32: i32 = stride * height;
        const size: usize = @intCast(size_i32);
        const pool_id = self.allocId();
        const new_buffer_id = self.allocId();

        const fd = try createMemfd("tildaz-wayland-dialog-buffer");
        errdefer posix.close(fd);
        try posix.ftruncate(fd, @intCast(size));

        const memory = try posix.mmap(
            null,
            size,
            linux.PROT.READ | linux.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer posix.munmap(memory);

        self.paintDialogBuffer(memory, width, height, stride);

        try self.sendCreatePool(fd, size_i32, pool_id);
        try self.sendArgs(pool_id, 0, &.{
            new_buffer_id,
            0,
            @intCast(width),
            @intCast(height),
            @intCast(stride),
            shm_format_argb8888,
        });
        try self.sendNoArgs(pool_id, 1);

        return .{
            .id = new_buffer_id,
            .fd = fd,
            .memory = memory,
            .width = width,
            .height = height,
            .stride = stride,
            .released = false,
        };
    }

    /// dialog layer-surface configure event handler. ack_configure → viewport
    /// set_destination → buffer (재)생성 + attach + damage_buffer + commit.
    /// frame callback throttling 없음 — dialog 는 정적.
    fn handleDialogConfigure(self: *Client, serial: u32, w_logical: u32, h_logical: u32) !void {
        try self.sendArgs(
            self.dialog.layer_surface_id,
            zwlr_layer_surface_v1_request_ack_configure,
            &.{serial},
        );
        // compositor 가 0 으로 답하면 (= "you decide") 우리 요청 크기 그대로 —
        // 새로 계산 (openInfoDialog 가 보낸 set_size 값 회수). 다만 그 값은
        // 이미 보냈으니 0 fall-back 은 거의 안 닿음. 보수적으로 renderer 재계산.
        const physical: struct { w: i32, h: i32 } = blk: {
            if (w_logical > 0 and h_logical > 0) {
                const w_clamped: i32 = @intCast(@min(w_logical, @as(u32, std.math.maxInt(i32))));
                const h_clamped: i32 = @intCast(@min(h_logical, @as(u32, std.math.maxInt(i32))));
                break :blk .{
                    .w = self.logicalToPhysical(w_clamped),
                    .h = self.logicalToPhysical(h_clamped),
                };
            }
            const want = self.renderer.computeDialogSize(self.dialog.title(), self.dialog.message(), false);
            break :blk .{ .w = want.w, .h = want.h };
        };
        // viewport set_destination — buffer (physical) 를 surface (logical) 에
        // 1:1 매핑. compositor 자체 stretch 차단.
        if (self.dialog.viewport_id != 0 and w_logical > 0 and h_logical > 0) {
            try self.sendArgs(
                self.dialog.viewport_id,
                wp_viewport_request_set_destination,
                &.{ w_logical, h_logical },
            );
        }
        // 크기 변경 또는 buffer 부재 시 (재)생성.
        const need_new = self.dialog.active_buffer == null or self.dialog.buffer_w != physical.w or self.dialog.buffer_h != physical.h;
        if (need_new) {
            if (self.dialog.active_buffer) |*old| {
                self.destroyBufferObject(old.id);
                old.deinit();
                self.dialog.active_buffer = null;
            }
            const buffer = try self.createDialogBuffer(physical.w, physical.h);
            self.dialog.active_buffer = buffer;
            self.dialog.buffer_w = physical.w;
            self.dialog.buffer_h = physical.h;
        }
        if (self.dialog.active_buffer) |buffer| {
            try self.sendArgs(self.dialog.surface_id, 1, &.{ buffer.id, 0, 0 });
            try self.sendArgs(self.dialog.surface_id, 9, &.{
                0,
                0,
                @intCast(buffer.width),
                @intCast(buffer.height),
            });
            try self.sendNoArgs(self.dialog.surface_id, 6);
        }
        self.dialog.configured = true;
        log.appendLine("dialog", "configure ack serial={} logical={}x{} physical={}x{}", .{
            serial, w_logical, h_logical, physical.w, physical.h,
        });
    }

    /// dialog_linux 의 info / error callback. cross-platform `dialog.show*` /
    /// `dialog.showAboutAlert` 가 종착점으로 도달.
    fn dialogShowInfoCb(ctx: *anyopaque, severity: dialog_mod.Severity, title: []const u8, message: []const u8) void {
        const self: *Client = @ptrCast(@alignCast(ctx));
        self.openInfoDialog(severity, title, message) catch |err| {
            log.appendLine("dialog", "openInfoDialog failed: {s} — falling back to log only", .{@errorName(err)});
        };
    }

    /// dialog_linux 의 confirm callback. step 4 — confirm dialog 띄움 + inner
    /// wayland event pump 로 사용자 선택 (OK / Cancel / Enter / Esc / external
    /// dismiss) 대기. 결과 반환.
    ///
    /// **reentrancy 안전성**: 호출 site (예: `app_controller.onQuitRequest`) 는
    /// *main loop 의 keyboard handler* 가 아니라 *deferred path* (Linux 의 경우
    /// Alt+F4 핸들러도 곧 deferred 으로 만듦 — main loop 의 quit check phase).
    /// 즉 *outer dispatchBuffered 안 호출 X* — inner pump 의 `pollAndDispatch`
    /// + `drainPendingDialogDismiss` 패턴 안전. dismiss 의 xdg-activation
    /// roundtrip 도 main loop 의 drain 시점에서 *outer pump cycle 밖* 에 처리.
    fn dialogShowConfirmCb(ctx: *anyopaque, title: []const u8, message: []const u8) bool {
        const self: *Client = @ptrCast(@alignCast(ctx));

        // Confirm dialog 띄움. 실패 시 안전 default Cancel.
        self.openConfirmDialog(title, message) catch |err| {
            log.appendLine("dialog", "openConfirmDialog failed: {s} — default Cancel", .{@errorName(err)});
            return false;
        };

        // Inner pump — 결과 받을 때까지 (`pending_confirm_result != null`) 또는
        // app 종료 (`self.running == false`). 각 iteration 의 work 는 main loop
        // 의 그것과 일치 (dispatch / drain dismiss / drain exited tabs / dbus /
        // key repeat / redraw).
        while (self.running and self.pending_confirm_result == null) {
            self.pollAndDispatch(frame_poll_ms) catch |err| {
                log.appendLine("dialog", "confirm inner pump pollAndDispatch failed: {s} — break + Cancel", .{@errorName(err)});
                self.pending_confirm_result = false;
                break;
            };
            self.drainPendingDialogDismiss();
            self.drainExitedTabs();
            self.dispatchDbusMessages();
            self.maybeRepeatKey() catch {};
            if (self.session) |*session| {
                if (session.drainActiveOutputForRender()) {
                    self.requestRedraw();
                }
            }
            self.maybeRedraw() catch {};
        }

        const result = self.pending_confirm_result orelse false;
        self.pending_confirm_result = null;
        log.appendLine("dialog", "confirm result={s} title={s}", .{ if (result) "OK" else "Cancel", title });
        return result;
    }

    fn logCapabilities(self: *Client) void {
        const layer = self.caps.layer_shell.name != 0;
        const text_input = self.caps.text_input_v3.name != 0;
        std.debug.print(
            "Wayland capabilities: wl_compositor={} wl_shm={} xdg_wm_base={} zwlr_layer_shell_v1={} zwp_text_input_manager_v3={}\n",
            .{
                self.caps.compositor.name != 0,
                self.caps.shm.name != 0,
                self.caps.xdg_wm_base.name != 0,
                layer,
                text_input,
            },
        );
        log.appendLine(
            "wayland",
            "capabilities compositor={} shm={} xdg_wm_base={} layer_shell={} text_input_v3={} data_device_manager={} shm_xrgb8888={} shm_argb8888={}",
            .{
                self.caps.compositor.name != 0,
                self.caps.shm.name != 0,
                self.caps.xdg_wm_base.name != 0,
                layer,
                text_input,
                self.caps.data_device_manager.name != 0,
                self.saw_xrgb8888,
                self.saw_argb8888,
            },
        );
    }

    fn bind(self: *Client, name: u32, interface: []const u8, version: u32, new_id: u32) !void {
        var msg = Msg.init(registry_id, 0);
        try msg.putU32(name);
        try msg.putString(interface);
        try msg.putU32(version);
        try msg.putU32(new_id);
        try msg.send(self.stream);
    }

    fn sendCreatePool(self: *Client, fd: posix.fd_t, size: i32, pool_id: u32) !void {
        var msg = Msg.init(self.shm_id, 0);
        try msg.putU32(pool_id);
        try msg.putI32(size);
        try msg.sendWithFd(self.stream, fd);
    }

    fn sendStringWithFd(self: *Client, id: u32, opcode: u16, text: []const u8, fd: posix.fd_t) !void {
        var msg = Msg.init(id, opcode);
        try msg.putString(text);
        try msg.sendWithFd(self.stream, fd);
    }

    fn sendNoArgs(self: *Client, id: u32, opcode: u16) !void {
        var msg = Msg.init(id, opcode);
        try msg.send(self.stream);
    }

    fn sendNewId(self: *Client, id: u32, opcode: u16, new_id: u32) !void {
        var msg = Msg.init(id, opcode);
        try msg.putU32(new_id);
        try msg.send(self.stream);
    }

    fn sendString(self: *Client, id: u32, opcode: u16, text: []const u8) !void {
        var msg = Msg.init(id, opcode);
        try msg.putString(text);
        try msg.send(self.stream);
    }

    fn sendArgs(self: *Client, id: u32, opcode: u16, args: []const u32) !void {
        var msg = Msg.init(id, opcode);
        for (args) |arg| try msg.putU32(arg);
        try msg.send(self.stream);
    }

    fn destroyBufferObject(self: *Client, id: u32) void {
        self.sendNoArgs(id, 0) catch {};
    }
};

/// L12-β — read thread callback. shell process exit (PTY EOF) 시 호출.
/// 직접 closeTab 면 self-join deadlock + multi-tab cascade 잘못된 종료. macOS
/// 패턴 동등 — buf 에 ptr append 만, main loop 의 `drainExitedTabs` 가 처리.
fn linuxTabExit(tab_ptr: usize, userdata: ?*anyopaque) void {
    const client: *Client = @ptrCast(@alignCast(userdata.?));
    client.pending_close_mutex.lock();
    defer client.pending_close_mutex.unlock();
    client.pending_close_buf.append(client.allocator, tab_ptr) catch {};
}

// L12-β — tab_actions.Host callbacks. `user_data` 가 `*Client`. 모두 module-
// level fn 이라 ptr 가 static — host build 마다 fresh 해도 stable.

fn linuxTabInvalidate(host: *tab_actions.Host) void {
    const client: *Client = @ptrCast(@alignCast(host.user_data.?));
    client.needs_redraw = true;
}

fn linuxTabRenameActive(host: *const tab_actions.Host) bool {
    const client: *Client = @ptrCast(@alignCast(host.user_data.?));
    return client.rename_state.isActive();
}

fn linuxTabInsertRenameCp(host: *tab_actions.Host, cp: u21) void {
    const client: *Client = @ptrCast(@alignCast(host.user_data.?));
    _ = client.rename_state.insertCodepoint(cp);
    client.needs_redraw = true;
}

fn linuxTabClipboardCopy(_: *tab_actions.Host, _: [:0]const u8) void {
    // L12-β 에서 미사용 — Linux 는 자체 `copyActiveSelection` path 가 직접
    // wl_data_source 로 보낸다. `tab_actions.copyActiveSelection` helper 도
    // 우리는 호출 안 함 (selection 자동 copy 는 wl_pointer.button release 가
    // 직접 처리). callback contract 만 만족.
}

fn linuxTabTerminate(host: *tab_actions.Host) void {
    const client: *Client = @ptrCast(@alignCast(host.user_data.?));
    client.shell_exited.store(true, .release);
}

pub fn runBaselineWindow(allocator: std.mem.Allocator, cfg: *const config_mod.Config) !void {
    var client = try Client.init(allocator, cfg);
    defer client.deinit();
    // #198 — portal-less hotkey IPC. listener 생성 실패는 fatal 아님 (이미
    // 다른 인스턴스가 listen 중이거나 socket 권한 문제 — graceful degrade).
    client.toggle_listener_fd = single_instance.createListener() catch |err| blk: {
        log.appendLine("toggle-ipc", "listener disabled: {s}", .{@errorName(err)});
        break :blk -1;
    };
    try client.run();
}

const Msg = struct {
    buf: [512]u8 = undefined,
    len: usize = 8,
    id: u32,
    opcode: u16,

    fn init(id: u32, opcode: u16) Msg {
        return .{ .id = id, .opcode = opcode };
    }

    fn putU32(self: *Msg, value: u32) !void {
        if (self.len + 4 > self.buf.len) return error.WaylandMessageTooLarge;
        writeU32(self.buf[self.len..][0..4], value);
        self.len += 4;
    }

    fn putI32(self: *Msg, value: i32) !void {
        try self.putU32(@bitCast(value));
    }

    fn putString(self: *Msg, value: []const u8) !void {
        const wire_len = value.len + 1;
        const padded = align4(wire_len);
        if (self.len + 4 + padded > self.buf.len) return error.WaylandMessageTooLarge;
        try self.putU32(@intCast(wire_len));
        @memcpy(self.buf[self.len..][0..value.len], value);
        self.buf[self.len + value.len] = 0;
        @memset(self.buf[self.len + wire_len .. self.len + padded], 0);
        self.len += padded;
    }

    fn finish(self: *Msg) []const u8 {
        writeU32(self.buf[0..4], self.id);
        const word = (@as(u32, @intCast(self.len)) << 16) | self.opcode;
        writeU32(self.buf[4..8], word);
        return self.buf[0..self.len];
    }

    fn send(self: *Msg, stream: std.net.Stream) !void {
        try stream.writeAll(self.finish());
    }

    fn sendWithFd(self: *Msg, stream: std.net.Stream, fd: posix.fd_t) !void {
        const bytes = self.finish();
        var iov = [_]posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};

        const fd_payload_size = @sizeOf(c_int);
        const control_len = cmsgLen(fd_payload_size);
        var control: [cmsgSpace(fd_payload_size)]u8 align(@alignOf(Cmsghdr)) = @splat(0);
        const hdr: *Cmsghdr = @ptrCast(@alignCast(&control));
        hdr.* = .{
            .len = control_len,
            .level = linux.SOL.SOCKET,
            .type = 1, // SCM_RIGHTS
        };
        const fd_i32: c_int = fd;
        const data_offset = cmsgAlign(@sizeOf(Cmsghdr));
        @memcpy(control[data_offset..][0..fd_payload_size], std.mem.asBytes(&fd_i32));

        const msg = posix.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = iov[0..].ptr,
            .iovlen = iov.len,
            .control = control[0..].ptr,
            .controllen = control_len,
            .flags = 0,
        };
        const sent = try posix.sendmsg(stream.handle, &msg, 0);
        if (sent != bytes.len) return error.WaylandShortFdWrite;
    }
};

const Cmsghdr = extern struct {
    len: usize,
    level: c_int,
    type: c_int,
};

const Parser = struct {
    buf: []const u8,
    pos: usize = 0,

    fn readU32(self: *Parser) !u32 {
        if (self.pos + 4 > self.buf.len) return error.WaylandBadMessage;
        const v = wayland_minimal_readU32(self.buf[self.pos..][0..4]);
        self.pos += 4;
        return v;
    }

    fn readString(self: *Parser) ![]const u8 {
        const wire_len = try self.readU32();
        if (wire_len == 0) return error.WaylandBadMessage;
        const len_usize: usize = @intCast(wire_len);
        const padded = align4(len_usize);
        if (self.pos + padded > self.buf.len) return error.WaylandBadMessage;
        const raw = self.buf[self.pos .. self.pos + len_usize];
        self.pos += padded;
        if (raw[raw.len - 1] != 0) return error.WaylandBadMessage;
        return raw[0 .. raw.len - 1];
    }
};

/// `connectUnixSocket` 실패 컨텍스트를 log + stderr 에 같이 남긴다. 사용자
/// 메시지 텍스트는 `messages.linux_wayland_socket_unavailable_format` 단일
/// 진입점 (AGENTS.md "사용자 표시 텍스트 / 다이얼로그" 정책). env 값은
/// `(unset)` 로 정직하게 노출 — X11 세션일 때 `WAYLAND_DISPLAY=(unset)` /
/// `XDG_SESSION_TYPE=x11` 가 보이면 즉시 원인 식별 가능.
fn reportWaylandSocketFailure(
    allocator: std.mem.Allocator,
    path: []const u8,
    err: anyerror,
) void {
    const display_owned = std.process.getEnvVarOwned(allocator, "WAYLAND_DISPLAY") catch null;
    defer if (display_owned) |s| allocator.free(s);
    const session_owned = std.process.getEnvVarOwned(allocator, "XDG_SESSION_TYPE") catch null;
    defer if (session_owned) |s| allocator.free(s);
    const runtime_owned = std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR") catch null;
    defer if (runtime_owned) |s| allocator.free(s);

    const display_str: []const u8 = if (display_owned) |s| s else "(unset)";
    const session_str: []const u8 = if (session_owned) |s| s else "(unset)";
    const runtime_str: []const u8 = if (runtime_owned) |s| s else "(unset)";

    log.appendLine(
        "fatal",
        "wayland socket connect failed: path={s} err={s} WAYLAND_DISPLAY={s} XDG_SESSION_TYPE={s} XDG_RUNTIME_DIR={s}",
        .{ path, @errorName(err), display_str, session_str, runtime_str },
    );
    std.debug.print(
        messages.linux_wayland_socket_unavailable_format ++ "\n",
        .{ path, @errorName(err), display_str, session_str, runtime_str },
    );
}

fn waylandSocketPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "WAYLAND_DISPLAY")) |display| {
        if (display.len > 0 and display[0] == '/') return display;
        errdefer allocator.free(display);
        const runtime = try std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR");
        defer allocator.free(runtime);
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ runtime, display });
        allocator.free(display);
        return path;
    } else |_| {
        const runtime = try std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR");
        defer allocator.free(runtime);
        return std.fmt.allocPrint(allocator, "{s}/wayland-0", .{runtime});
    }
}

fn fillBuffer(memory: []u8, width: i32, height: i32, stride: i32) void {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const s: usize = @intCast(stride);
    for (0..h) |y| {
        for (0..w) |x| {
            const green: u32 = @intCast(92 + (x * 80 / @max(w, 1)));
            const blue: u32 = @intCast(48 + (y * 70 / @max(h, 1)));
            // ARGB8888 — alpha=255 (fully opaque). 이 fallback path 는
            // session 미연결 placeholder 라 사용자 opacity 적용 무의미.
            const color: u32 = (0xFF << 24) | (0x24 << 16) | (green << 8) | blue;
            writeU32(memory[y * s + x * 4 ..][0..4], color);
        }
    }
}

/// paste 인입으로 받아들일 mime. 셋 중 하나만 광고돼도 paste 가능. 셋 다
/// UTF-8 plain text 표기 — 우리는 byte 그대로 PTY 로 넣으므로 charset
/// fallback 가공 없음.
fn isAcceptableTextMime(mime: []const u8) bool {
    return std.mem.eql(u8, mime, clipboard_mime_utf8) or
        std.mem.eql(u8, mime, clipboard_mime_utf8_string) or
        std.mem.eql(u8, mime, clipboard_mime_text_plain);
}

/// wayland wire string parsing — `u32 length + (length bytes, null 포함)` +
/// 4-byte 정렬 padding. length 가 null 을 포함하는 게 일반적이지만 일부
/// compositor 가 안 포함하는 경우 대비해 마지막 byte 가 null 이면 빼고
/// 반환. payload 가 짧거나 length 가 0 이면 null.
fn readWaylandString(payload: []const u8) ?[]const u8 {
    if (payload.len < 4) return null;
    const len = readU32(payload[0..4]);
    if (len == 0) return null;
    const total: usize = @intCast(len);
    if (payload.len < 4 + total) return null;
    if (payload[4 + total - 1] == 0) {
        return payload[4 .. 4 + total - 1];
    }
    return payload[4 .. 4 + total];
}

/// wl_fixed_t (signed 24.8 fixed-point packed in i32) → integer pixel.
/// surface 좌표는 음수가 정상 흐름엔 안 들어오지만, leave 직후 등 edge case 대비
/// `@divTrunc` 로 0 방향 정수 변환 — pixelToCell 의 범위 검사가 음수 reject.
fn wlFixedToPx(value: i32) i32 {
    return @divTrunc(value, 256);
}

fn readU32(bytes: *const [4]u8) u32 {
    return wayland_minimal_readU32(bytes);
}

fn readI32(bytes: *const [4]u8) i32 {
    return @bitCast(readU32(bytes));
}

fn wayland_minimal_readU32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .little);
}

fn writeU32(bytes: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, bytes, value, .little);
}

fn align4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

fn cmsgAlign(n: usize) usize {
    const a = @sizeOf(usize);
    const mask: usize = a - 1;
    return (n + mask) & ~mask;
}

fn cmsgLen(payload_len: usize) usize {
    return cmsgAlign(@sizeOf(Cmsghdr)) + payload_len;
}

fn cmsgSpace(payload_len: usize) usize {
    return cmsgAlign(@sizeOf(Cmsghdr)) + cmsgAlign(payload_len);
}

// #213 회귀 가드 — About 를 dispatchBuffered (outer) 안에서 직접 열면
// `createDialogSurface` 의 inner `roundtrip` 이 reentrant `dispatchBuffered` 를
// 돌려 공유 `input` 을 compact, `input_len` 을 outer 의 `offset` 밑으로 줄인다.
// 그 뒤 outer post-loop 의 `input_len - offset` 가 usize underflow → integer
// overflow panic. 근본 fix 는 About 를 main loop 로 deferred (`pending_about_
// request` / `drainAboutRequest`) 한 것이고, 이 테스트는 2 차 방어인
// `compactInput` 의 underflow guard 를 직접 검증한다 (compositor 불필요).
test "#213 compactInput — input_len < offset 일 때 underflow 없이 length 보존" {
    var buf: [256]u8 = undefined;

    // 정상 compaction: offset=10 소비, input_len=40 → 남은 30 bytes 를 앞으로.
    for (0..40) |i| buf[i] = @intCast(i);
    try std.testing.expectEqual(@as(usize, 30), Client.compactInput(&buf, 40, 10));
    // [10..40] (값 10..39) 이 [0..30] 으로 이동했는지 표본 확인.
    try std.testing.expectEqual(@as(u8, 10), buf[0]);
    try std.testing.expectEqual(@as(u8, 39), buf[29]);

    // underflow 방어 ①: input_len=0, offset=24 (inner 가 전량 compact) → 0 그대로.
    try std.testing.expectEqual(@as(usize, 0), Client.compactInput(&buf, 0, 24));

    // underflow 방어 ②: input_len(10) < offset(24) → input_len 보존 (재compact X).
    try std.testing.expectEqual(@as(usize, 10), Client.compactInput(&buf, 10, 24));

    // 전량 소비: input_len == offset → rem 0.
    try std.testing.expectEqual(@as(usize, 0), Client.compactInput(&buf, 24, 24));

    // 소비 없음: offset == 0 → length 불변.
    try std.testing.expectEqual(@as(usize, 50), Client.compactInput(&buf, 50, 0));
}
