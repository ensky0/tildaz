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
const ui_metrics = @import("../../ui_metrics.zig");
const scrollbar = @import("../../scrollbar.zig");
const app_event = @import("../../app_event.zig");
const input_policy = @import("../../input_policy.zig");
const themes = @import("../../themes.zig");
const perf = @import("../../perf.zig");
const log = @import("../../log.zig");
const messages = @import("../../messages.zig");
const command_menu = @import("../../command_menu.zig");
const config_mod = @import("../../config.zig");
const software_terminal = @import("software_terminal.zig");
const dialog_layout = @import("dialog_layout.zig");
const xkb = @import("xkb.zig");
const gbm = @import("gbm.zig");
const egl = @import("egl.zig");
const gl_rects = @import("gl_rects.zig");
const gl_atlas = @import("gl_atlas.zig");
const gl_text = @import("gl_text.zig");
const dbus = @import("dbus.zig");
const kglobalaccel = @import("kglobalaccel.zig");
const single_instance = @import("single_instance.zig");
const sway_ipc = @import("sway_ipc.zig");
const gsettings_hotkey = @import("gsettings_hotkey.zig");
const about = @import("../../about.zig");
const paths = @import("../../paths.zig");
const shell_validate = @import("../../shell_validate.zig");
const font_linux = @import("../../font/linux/font.zig");
const font_validate = @import("../../font/validate.zig");
const system_open = @import("../../system_open.zig");
const dialog_mod = @import("../../dialog.zig");
const dialog_linux = @import("../../dialog/linux.zig");
const instance_context = @import("../../instance_context.zig");
const instances = @import("../../instances.zig");
const instance_identity = @import("instance_identity.zig");

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
/// #245 — drag-select auto-scroll tick 간격(ms). 한 tick 당 `sel_autoscroll_step`
/// 줄. 40ms × 3줄 ≈ 75줄/s — 편안한 속도. frame_poll_ms(16) 보다 커 매 frame 마다는
/// 아니고 timestamp 게이트로 throttle.
const sel_autoscroll_interval_ms: i64 = 40;
const sel_autoscroll_step: isize = 3;
const max_buffers_per_size: usize = 2;
/// #277 — compositor 가 공표하는 ARGB8888 modifier 후보 상한. 실측은 AMD 8 종 /
/// NVIDIA 13 종이었다. 넘치면 앞쪽만 본다 (뒤쪽이 더 나을 이유가 없다).
const max_dmabuf_mods: usize = 64;
/// #367 — feedback tranche 수 상한. 실측은 세 기기 모두 3 개.
const max_dmabuf_tranches: usize = 16;
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
const zwlr_layer_surface_keyboard_interactivity_on_demand: u32 = 2;
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

// keyboard-shortcuts-inhibit-unstable-v1. Prompt가 focus를 가진 동안
// compositor global binding보다 captured key를 먼저 받는다.
const keyboard_shortcuts_inhibit_manager_request_inhibit_shortcuts: u16 = 1;
const keyboard_shortcuts_inhibitor_request_destroy: u16 = 0;
const keyboard_shortcuts_inhibitor_event_active: u16 = 0;
const keyboard_shortcuts_inhibitor_event_inactive: u16 = 1;

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

// #295 — main surface 가 어느 output 에 올라갔는지 알려주는 유일한 신호.
// enter payload = 해당 wl_output 의 (우리가 bind 한) object id.
const wl_surface_event_enter: u16 = 0;
const wl_surface_event_leave: u16 = 1;

/// #295 — advertise 된 모든 wl_output 의 per-output 상태. 첫 output 만 저장하던
/// L8-β scope 를 확장 — mixed-monitor 에서 surface 가 놓인 output 과 layout/scale
/// 계산 기준 output 이 달라지는 구조 문제의 해소 단위. 고정 배열 (일반 데스크탑
/// 은 output 몇 개 수준, 초과분은 무시 + 로그).
const max_tracked_outputs = 8;
const OutputSlot = struct {
    global_name: u32 = 0, // registry global name (0 = 빈 slot)
    version: u32 = 0, // advertise 된 interface version
    object_id: u32 = 0, // bind 된 proxy id (0 = 미bind)
    width: i32 = 0, // 물리 px — mode(CURRENT) event
    height: i32 = 0,
    scale: i32 = 1, // wl_output.scale (정수 배율)
    // #295 — main surface 가 현재 이 output 에 걸쳐있는지 (`wl_surface.enter`
    // 로 set, `leave` 로 clear). 한 surface 가 동시에 여러 output 에 걸칠 수
    // 있어(spec) 집합으로 추적 — basis 선택 안정화에 사용.
    entered: bool = false,
};
const wl_output_mode_flag_current: u32 = 0x1;
// L8-β — wl_output 없는 환경 fallback. 정상 Wayland session 에선 늘 advertise
// 되므로 거의 안 닿음 — 닿으면 startup 로그에 fallback 명시.
const screen_fallback_width: i32 = 1920;
const screen_fallback_height: i32 = 1080;
// #351 — `stretch_threshold_pct` (99.9) 는 제거했다. logical 로 계산하면
// `width_percent`/`height_percent` 100 에서 margin 이 정확히 0 이 되므로 "거의 100"
// 을 따로 판정할 이유가 없다. 이 상수는 그 강제 0 과 overscan gating 에만 쓰였다.

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

// xdg_toplevel request opcodes (xdg-shell stable). 선언 순서 = opcode:
// destroy=0 set_parent=1 set_title=2 set_app_id=3 show_window_menu=4 move=5
// resize=6 set_max_size=7 set_min_size=8 set_maximized=9 unset_maximized=10
// set_fullscreen=11 unset_fullscreen=12 set_minimized=13. #87 fullscreen 의
// xdg fallback(GNOME/Cinnamon) 경로에서만 사용 — set_title/set_app_id 는
// 현재 리터럴(2/3)로 송신 중이라 여기 안 옮긴다.
const xdg_toplevel_request_set_maximized: u16 = 9;
const xdg_toplevel_request_unset_maximized: u16 = 10;
const xdg_toplevel_request_set_fullscreen: u16 = 11;
const xdg_toplevel_request_unset_fullscreen: u16 = 12;

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
// 그래서 Shift 를 쓰는 단축키만 `_upper` 가 필요하다. Ctrl+A / Ctrl+E 는 Shift
// 없이 판정하므로 `_lower` 만 둔다 — #341 로 rename 의 Ctrl+A/E 매핑(양쪽 다
// 받았음)이 사라져 그 둘의 `_upper` 는 쓰이지 않게 됐다.
const xkb_key_a_lower: u32 = 0x61;
const xkb_key_c_lower: u32 = 0x63;
const xkb_key_c_upper: u32 = 0x43;
const xkb_key_e_lower: u32 = 0x65;
const xkb_key_i_lower: u32 = 0x69;
const xkb_key_i_upper: u32 = 0x49;
const xkb_key_l_lower: u32 = 0x6c;
const xkb_key_l_upper: u32 = 0x4c;
const xkb_key_p_lower: u32 = 0x70;
const xkb_key_p_upper: u32 = 0x50;
const xkb_key_v_lower: u32 = 0x76;
const xkb_key_v_upper: u32 = 0x56;
// #214 — Ctrl+Shift+R : 활성 탭 화면 reset (Win `Ctrl+Shift+R` / mac `Shift+Cmd+R` 동등).
const xkb_key_r_lower: u32 = 0x72;
const xkb_key_r_upper: u32 = 0x52;
// XKB F1..F12 keysyms — `xkbcommon/xkbcommon-keysyms.h`. F4 = Alt+F4 quit,
// F-key keysym (연속: F1=0xffbe … F12=0xffc9). Alt+F4 / Ctrl+Shift+F12 외에도
// #282 A7 로 F1~F12 를 TUI(htop/mc 등)용 xterm escape sequence 로 PTY 전달.
// (F1 은 보통 전역 hotkey 라 도달 안 하지만 매핑은 둔다 — macOS 동등.)
const xkb_key_f1: u32 = 0xffbe;
const xkb_key_f2: u32 = 0xffbf;
const xkb_key_f3: u32 = 0xffc0;
const xkb_key_f4: u32 = 0xffc1;
const xkb_key_f5: u32 = 0xffc2;
const xkb_key_f6: u32 = 0xffc3;
const xkb_key_f7: u32 = 0xffc4;
const xkb_key_f8: u32 = 0xffc5;
const xkb_key_f9: u32 = 0xffc6;
const xkb_key_f10: u32 = 0xffc7;
const xkb_key_f11: u32 = 0xffc8;
const xkb_key_f12: u32 = 0xffc9;
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
    // (#295: wl_output 은 여기 아닌 Client.outputs slot 이 *전부* 추적 —
    // handleRegistryGlobal 참고. 첫 번째만 쓰던 L8-β scope 제한 해소.)
    // fractional scaling — KDE Plasma 6 의 125% / 150% / 170% 등.
    viewporter: Global = .{},
    fractional_scale_manager: Global = .{},
    // #193 — `wp_cursor_shape_manager_v1` advertise 면 themed cursor 사용
    // (compositor 가 XCursor 테마 자동 매칭). 미advertise 시 default arrow 만.
    cursor_shape_manager: Global = .{},
    // #203 Phase C — `xdg_activation_v1` (focus return). 활성 surface 가
    // token 발급 → 다른 surface 에 양도. KWin / Mutter / wlroots 모두 지원.
    xdg_activation: Global = .{},
    keyboard_shortcuts_inhibit: Global = .{},
    // #277 — GPU (dma-buf) 렌더 경로. 미advertise 면 software `wl_shm` 으로 돈다.
    linux_dmabuf: Global = .{},

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
        } else if (std.mem.eql(u8, interface, "wp_viewporter")) {
            self.viewporter = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "wp_fractional_scale_manager_v1")) {
            self.fractional_scale_manager = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "wp_cursor_shape_manager_v1")) {
            self.cursor_shape_manager = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "xdg_activation_v1")) {
            self.xdg_activation = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "zwp_keyboard_shortcuts_inhibit_manager_v1")) {
            self.keyboard_shortcuts_inhibit = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "zwp_linux_dmabuf_v1")) {
            self.linux_dmabuf = .{ .name = name, .version = version };
        }
    }
};

/// L8-β — layer-shell 한 surface 의 anchor / size / margin 합본. 우리 config
/// (dock_position / width_percent / height_percent / offset_percent) 와 wire
/// protocol args 사이의 변환 결과. `Client.computeLayerLayout` 가 채움,
/// `createLayerSurface` 가 그대로 송신.
/// #87 — Alt+Enter fullscreen 토글 (Win `FullscreenMode` 동등). layer-shell 계열
/// (KWin/wlroots/COSMIC) 전용. drop-down 을 output 전체로 키운다:
///   - cover  (Alt+Enter):       4-edge anchor + size 0 + exclusive_zone(-1) → 패널 위 덮음 (Win `.monitor`).
///   - avoid  (Shift+Alt+Enter):  4-edge anchor + size 0 + exclusive_zone(0)  → 패널 비킨 work-area (Win `.workarea`).
/// F1 hide/show 가 이 상태를 보존 (sendLayerSurfaceLayout 이 매 재배치/재생성에서 반영).
const FullscreenMode = enum { none, cover, avoid };

/// #351 — 모든 값이 **logical (surface-local) 픽셀** 이다. layer-shell 의
/// `set_size` / `set_margin` 이 그 단위이므로 (spec: *"in surface-local
/// coordinates"*) 변환 없이 그대로 송신한다. 이전에는 physical 로 계산해 송신 시
/// `physicalToLogical` 로 버림 변환했고, 그 오차를 `overscan(-1)` 으로 보정했다.
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

/// surface 에 attach 하는 buffer 하나. #277 이전엔 `wl_shm` 전용이었고 지금은
/// GPU (dma-buf) 경로도 같은 타입으로 담는다 — 두 경로의 shape 이 같아서
/// (id / 크기 / stride / released) 타입을 쪼개지 않고 항목별로 분기한다
/// (AGENTS.md `# 크로스 플랫폼 코드 스타일 — single definition 우선`).
///
/// 구분은 `bo` 의 유무다. `bo != null` 이면 GPU 경로 (memory 는 매 frame
/// `gbm_bo_map` 으로 잠깐 얻는다), null 이면 software 경로 (memfd + 상주 mmap).
const SurfaceBuffer = struct {
    id: u32,
    /// software 경로의 memfd. GPU 경로에선 -1 (dma-buf fd 는 송신 즉시 닫는다 —
    /// compositor 가 자기 참조를 갖고, 우리는 `bo` 로 buffer 를 유지한다).
    fd: posix.fd_t,
    /// software 경로의 상주 mapping. GPU 경로에선 null.
    memory: ?[]align(std.heap.page_size_min) u8 = null,
    width: i32,
    height: i32,
    stride: i32,
    released: bool = false,
    /// #277 — GPU 경로일 때만 non-null. 이 buffer 를 만든 api 를 같이 들고 있어야
    /// `deinit` 이 인자 없이 자기 자원을 정리한다 (호출처가 20 곳이라 인자를
    /// 늘리지 않는 편이 안전하다).
    ///
    /// 포인터가 아니라 **값**으로 담는다. GPU 경로를 도중에 끄면
    /// (`Client.disableGpu`) `Client.gpu` 가 null 이 되는데, 아직 살아 있는
    /// buffer 가 그 안을 가리키고 있으면 dangling 이 된다. api 는 함수 포인터
    /// 묶음이라 복사가 싸고, 이렇게 두면 그 부류의 버그가 아예 성립하지 않는다.
    gbm_api: ?gbm.Api = null,
    bo: ?gbm.Bo = null,
    /// #277 S2 — GL 로 그리는 buffer 의 렌더 타깃 (EGLImage + texture + FBO).
    /// null 이면 CPU 가 그리는 buffer 다.
    gl_target: ?egl.Target = null,
    /// target 을 파괴하려면 EGL display 와 GL 함수가 필요하다. `gbm_api` 와 같은
    /// 이유로 **값**으로 담는다 — `deinit` 이 인자 없이 자기 자원을 정리해야 하고
    /// (호출처가 20 곳), context 가 먼저 사라져도 dangling 이 되지 않는다.
    gl_ctx: ?egl.Context = null,

    fn deinit(self: *SurfaceBuffer) void {
        if (self.gl_target) |target| {
            if (self.gl_ctx) |ctx| ctx.destroyTarget(target);
            self.gl_target = null;
        }
        if (self.gbm_api) |api| {
            if (self.bo) |bo| api.destroyBo(bo);
            self.bo = null;
            return;
        }
        if (self.memory) |m| posix.munmap(m);
        if (self.fd >= 0) posix.close(self.fd);
    }
};

/// #277 — GPU (dma-buf) 경로 자원. `Client.gpu` 가 null 이면 software `wl_shm`
/// 으로 그린다.
///
/// 초기화에 실패하거나 도중에 한 번이라도 실패하면 null 로 되돌리고 다시
/// 시도하지 않는다 (`Client.disableGpu`). 매 frame 실패를 반복하는 것보다
/// 조용히 software 로 도는 편이 낫다 — 두 경로의 렌더 결과는 같으므로 사용자
/// 눈에 보이는 차이가 없고, 어느 경로인지는 로그에 남는다.
/// `zwp_linux_buffer_params_v1` 의 결과. `created` 는 **server 가 할당한**
/// wl_buffer id 다 (event 의 new_id 라 우리 id 공간이 아니다).
const DmabufResult = union(enum) {
    created: u32,
    failed,
};

const Gpu = struct {
    api: gbm.Api,
    device: *anyopaque,
    drm_fd: posix.fd_t,

    fn deinit(self: *Gpu) void {
        self.api.destroyDevice(self.device);
        posix.close(self.drm_fd);
        self.api.deinit();
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
    pub const Kind = enum { none, info, about, confirm, prompt };

    // --- content ---
    kind: Kind = .none,
    severity: dialog_mod.Severity = .info,
    title_buf: [128]u8 = undefined,
    title_len: usize = 0,
    msg_buf: [dialog_linux.message_capacity]u8 = undefined,
    msg_len: usize = 0,
    message_owned: ?[]u8 = null,
    input_buf: [128]u8 = undefined,
    input_len: usize = 0,
    status_buf: [256]u8 = undefined,
    status_len: usize = 0,
    prompt_available: bool = false,
    wrap_cells: usize = 1,
    message_rows: usize = 1,
    visible_message_rows: usize = 1,
    message_scroll_row: usize = 0,
    message_scroll_max: usize = 0,
    scrollbar_drag_grab: ?f64 = null,
    /// Pointer motion batch 안의 여러 drag 위치를 마지막 row 하나로 합친다.
    /// `takeRepaintRequest`가 batch 뒤 한 번만 소비한다.
    repaint_requested: bool = false,
    scroll_axis_remainder_fixed: i64 = 0,
    show_icon: bool = true,
    layout_fits: bool = true,

    // --- wayland 객체 ---
    surface_id: u32 = 0,
    layer_surface_id: u32 = 0,
    /// #231 — layer-shell 미advertise (GNOME mutter / Cinnamon muffin) 시 dialog
    /// 를 일반 xdg_toplevel 로 띄운다. layer_surface_id 와 상호배타 — 둘 중 하나만
    /// 0 아님. 그리기/버퍼/입력/dismiss 경로는 surface_id 기준이라 공유.
    xdg_surface_id: u32 = 0,
    xdg_toplevel_id: u32 = 0,
    /// xdg 경로 — xdg_toplevel.configure 가 알려준 크기(logical). 같은 commit
    /// 의 xdg_surface.configure 에서 ack 후 이 값으로 paint. 0 이면 요청 크기 유지.
    pending_w_logical: u32 = 0,
    pending_h_logical: u32 = 0,
    viewport_id: u32 = 0,
    /// #210 — dialog 자체 fractional_scale 객체. main 의 fractional_scale 와
    /// 독립 — dialog 가 main createShellObjects *이전* 띄울 때 (예: boot 중
    /// startup hotkey dialog) main 의 preferred_scale event 아직 안 받음 →
    /// dialog 가 1x 로 표시 + click 좌표 변환 mismatch 의 cause. dialog 자체
    /// 객체 + roundtrip 으로 dialog 가 자기 surface 의 preferred_scale event
    /// 받음 보장. 같은 output 가정상 main 의 preferred_scale 값과 동일.
    fractional_scale_id: u32 = 0,
    active_buffer: ?SurfaceBuffer = null,
    retired_buffers: std.ArrayList(SurfaceBuffer) = .{},
    /// configure event 가 알려준 buffer 크기 (physical px).
    buffer_w: i32 = 0,
    buffer_h: i32 = 0,
    configured: bool = false,

    pub fn title(self: *const DialogOverlay) []const u8 {
        return self.title_buf[0..self.title_len];
    }
    pub fn message(self: *const DialogOverlay) []const u8 {
        if (self.message_owned) |owned| return owned;
        return self.msg_buf[0..self.msg_len];
    }
    pub fn active(self: *const DialogOverlay) bool {
        return self.kind != .none;
    }
    pub fn input(self: *const DialogOverlay) []const u8 {
        return self.input_buf[0..self.input_len];
    }
    pub fn status(self: *const DialogOverlay) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn hasPromptInput(self: *const DialogOverlay) bool {
        return std.mem.trim(u8, self.input(), " \t\r\n").len > 0;
    }

    fn setDragScrollRow(self: *DialogOverlay, row: usize) bool {
        if (row == self.message_scroll_row) return false;
        self.message_scroll_row = row;
        self.repaint_requested = true;
        return true;
    }

    fn takeRepaintRequest(self: *DialogOverlay) bool {
        const requested = self.repaint_requested;
        self.repaint_requested = false;
        return requested;
    }
};

test "#314 dialog drag repaint requests coalesce to the latest row" {
    var dialog: DialogOverlay = .{};
    try std.testing.expect(dialog.setDragScrollRow(3));
    try std.testing.expect(dialog.setDragScrollRow(11));
    try std.testing.expect(!dialog.setDragScrollRow(11));
    try std.testing.expectEqual(@as(usize, 11), dialog.message_scroll_row);
    try std.testing.expect(dialog.takeRepaintRequest());
    try std.testing.expect(!dialog.takeRepaintRequest());
}

/// #296 — native xkb sym + modifier 를 공통 정책의 `input_policy.Input` 으로
/// 분류. null = 정책 대상 아님(일반 문자 / 터미널 control char / preedit-Ctrl
/// commit / scroll 등) → processKeyEvent 의 기존 PTY 경로로. 상태(preedit)에
/// 따른 "그래서 무엇을 할지" 결정은 여기가 아니라 `input_policy.resolve` 가 한다.
fn classifyInput(sym: u32, ctrl: bool, shift: bool, alt: bool) ?input_policy.Input {
    // Ctrl+Shift+* — 클립보드 / 탭 / About / Open Config·Log / reset / perf.
    if (ctrl and shift and !alt) {
        return switch (sym) {
            xkb_key_c_lower, xkb_key_c_upper => .{ .shortcut = .copy_selection },
            xkb_key_v_lower, xkb_key_v_upper => .paste,
            xkb_key_t_lower, xkb_key_t_upper => .{ .shortcut = .new_tab },
            xkb_key_w_lower, xkb_key_w_upper => .{ .shortcut = .close_tab },
            xkb_key_bracketright, xkb_key_braceright => .{ .shortcut = .next_tab },
            xkb_key_bracketleft, xkb_key_braceleft => .{ .shortcut = .prev_tab },
            xkb_key_i_lower, xkb_key_i_upper => .{ .shortcut = .show_about },
            xkb_key_p_lower, xkb_key_p_upper => .{ .shortcut = .open_config },
            xkb_key_l_lower, xkb_key_l_upper => .{ .shortcut = .open_log },
            xkb_key_r_lower, xkb_key_r_upper => .{ .shortcut = .reset_terminal },
            xkb_key_f12 => .{ .shortcut = .dump_perf },
            else => null,
        };
    }
    // Ctrl+C (Shift 없음) — SIGINT(line abort). preedit 자모 discard 는 best-effort:
    // fcitx5 는 Ctrl+C 에서 자모를 먼저 확정해 `가^C`(취소된 줄이라 무해, §5.1).
    if (ctrl and !shift and !alt and (sym == xkb_key_c_lower or sym == xkb_key_c_upper)) return .interrupt;
    // Alt+Enter(fullscreen) / Alt+F4(quit) / Alt+1..9(탭 전환). Ctrl 미동반.
    if (alt and !ctrl) {
        if (sym == xkb_key_return) return .{ .shortcut = .fullscreen };
        if (!shift and sym == xkb_key_f4) return .{ .shortcut = .quit };
        if (!shift and sym >= xkb_key_1 and sym <= xkb_key_9) return .{ .shortcut = .switch_tab };
    }
    // 그 외는 정책 대상 아님(일반 문자 / 터미널 control char / preedit-Ctrl
    // commit / scroll) → 기존 PTY 경로.
    return null;
}

test "#296 classifyInput — native xkb → 공통 Input 분류" {
    const T = std.testing;
    const C = classifyInput;
    const I = input_policy.Input;
    // Ctrl+Shift+* → shortcut / paste
    try T.expectEqual(@as(?I, .{ .shortcut = .copy_selection }), C(xkb_key_c_lower, true, true, false));
    try T.expectEqual(@as(?I, .paste), C(xkb_key_v_lower, true, true, false));
    try T.expectEqual(@as(?I, .{ .shortcut = .new_tab }), C(xkb_key_t_lower, true, true, false));
    try T.expectEqual(@as(?I, .{ .shortcut = .close_tab }), C(xkb_key_w_lower, true, true, false));
    try T.expectEqual(@as(?I, .{ .shortcut = .next_tab }), C(xkb_key_bracketright, true, true, false));
    try T.expectEqual(@as(?I, .{ .shortcut = .prev_tab }), C(xkb_key_bracketleft, true, true, false));
    try T.expectEqual(@as(?I, .{ .shortcut = .show_about }), C(xkb_key_i_lower, true, true, false));
    try T.expectEqual(@as(?I, .{ .shortcut = .open_config }), C(xkb_key_p_lower, true, true, false));
    try T.expectEqual(@as(?I, .{ .shortcut = .open_log }), C(xkb_key_l_lower, true, true, false));
    try T.expectEqual(@as(?I, .{ .shortcut = .reset_terminal }), C(xkb_key_r_lower, true, true, false));
    try T.expectEqual(@as(?I, .{ .shortcut = .dump_perf }), C(xkb_key_f12, true, true, false));
    // Alt 계열 (fullscreen 은 shift 로 cover/avoid — 분류는 동일)
    try T.expectEqual(@as(?I, .{ .shortcut = .fullscreen }), C(xkb_key_return, false, false, true));
    try T.expectEqual(@as(?I, .{ .shortcut = .fullscreen }), C(xkb_key_return, false, true, true));
    try T.expectEqual(@as(?I, .{ .shortcut = .quit }), C(xkb_key_f4, false, false, true));
    try T.expectEqual(@as(?I, .{ .shortcut = .switch_tab }), C(xkb_key_1, false, false, true));
    try T.expectEqual(@as(?I, .{ .shortcut = .switch_tab }), C(xkb_key_9, false, false, true));
    // Ctrl+C (Shift 없음) → interrupt
    try T.expectEqual(@as(?I, .interrupt), C(xkb_key_c_lower, true, false, false));
    // 미분류(null → 기존 PTY 경로):
    try T.expectEqual(@as(?I, null), C(xkb_key_t_lower, false, false, false)); // 일반 문자
    try T.expectEqual(@as(?I, null), C(xkb_key_return, false, false, false)); // Enter
    try T.expectEqual(@as(?I, null), C(xkb_key_up, false, false, false)); // nav 키
    try T.expectEqual(@as(?I, null), C(xkb_key_a_lower, true, false, false)); // Ctrl+A = 터미널 \x01
    try T.expectEqual(@as(?I, null), C(xkb_key_e_lower, true, false, false)); // Ctrl+E = 터미널 \x05
    try T.expectEqual(@as(?I, null), C(xkb_key_page_up, false, true, false)); // Shift+PgUp = scroll
    try T.expectEqual(@as(?I, null), C(xkb_key_t_lower, true, false, false)); // Ctrl+T = shell transpose
    try T.expectEqual(@as(?I, null), C(xkb_key_1, false, true, true)); // Alt+Shift+숫자
    try T.expectEqual(@as(?I, null), C(xkb_key_return, true, false, true)); // Ctrl+Alt+Enter
}

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
        // #282 A7 — F1~F12 xterm sequence (htop/mc 등 TUI). macOS keyCodeToEscape 와 동일.
        xkb_key_f1 => "\x1bOP",
        xkb_key_f2 => "\x1bOQ",
        xkb_key_f3 => "\x1bOR",
        xkb_key_f4 => "\x1bOS",
        xkb_key_f5 => "\x1b[15~",
        xkb_key_f6 => "\x1b[17~",
        xkb_key_f7 => "\x1b[18~",
        xkb_key_f8 => "\x1b[19~",
        xkb_key_f9 => "\x1b[20~",
        xkb_key_f10 => "\x1b[21~",
        xkb_key_f11 => "\x1b[23~",
        xkb_key_f12 => "\x1b[24~",
        else => null,
    };
}

test "terminalSequenceForKeysym: F1~F12 xterm sequence (#282 A7)" {
    const T = std.testing;
    try T.expectEqualStrings("\x1bOP", terminalSequenceForKeysym(xkb_key_f1).?);
    try T.expectEqualStrings("\x1bOQ", terminalSequenceForKeysym(xkb_key_f2).?);
    try T.expectEqualStrings("\x1bOR", terminalSequenceForKeysym(xkb_key_f3).?);
    try T.expectEqualStrings("\x1bOS", terminalSequenceForKeysym(xkb_key_f4).?);
    try T.expectEqualStrings("\x1b[15~", terminalSequenceForKeysym(xkb_key_f5).?);
    try T.expectEqualStrings("\x1b[17~", terminalSequenceForKeysym(xkb_key_f6).?);
    try T.expectEqualStrings("\x1b[18~", terminalSequenceForKeysym(xkb_key_f7).?);
    try T.expectEqualStrings("\x1b[19~", terminalSequenceForKeysym(xkb_key_f8).?);
    try T.expectEqualStrings("\x1b[20~", terminalSequenceForKeysym(xkb_key_f9).?);
    try T.expectEqualStrings("\x1b[21~", terminalSequenceForKeysym(xkb_key_f10).?);
    try T.expectEqualStrings("\x1b[23~", terminalSequenceForKeysym(xkb_key_f11).?);
    try T.expectEqualStrings("\x1b[24~", terminalSequenceForKeysym(xkb_key_f12).?);
    // nav 키는 기존대로 유지 (회귀 없음)
    try T.expectEqualStrings("\x1b[2~", terminalSequenceForKeysym(xkb_key_insert).?);
    try T.expectEqualStrings("\x1b[3~", terminalSequenceForKeysym(xkb_key_delete).?);
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

/// hotkey 를 **compositor keybind → `tildaz --toggle`** (#198 single-instance
/// socket) 로 거는 환경인지. 이 환경이면 hidden_start 를 존중한다(첫 toggle 이
/// surface 생성).
///   - sway: `$SWAYSOCK` (sway_ipc 가 런타임 `bindsym` 등록)
///   - Hyprland: `$HYPRLAND_INSTANCE_SIGNATURE` (launcher 의 `shortcut_sync` 가
///     `hyprctl keyword bind`/`unbind` 로 런타임 증분 등록 — #267. install.sh 는
///     legacy 정적 bind 제거만)
///   - COSMIC: `$XDG_CURRENT_DESKTOP` 에 "cosmic" (#230) — launcher 의
///     `shortcut_sync.syncCosmic` 이 RON custom shortcut(`Spawn("tildaz --toggle N")`)
///     파일을 동기화.
fn compositorHotkeyEnv() bool {
    if (posix.getenv("SWAYSOCK") != null) return true;
    if (posix.getenv("HYPRLAND_INSTANCE_SIGNATURE") != null) return true;
    if (cosmicCompositor()) return true;
    return false;
}

/// `$XDG_CURRENT_DESKTOP` 에 `needle` (소문자) 가 들어있나. XDG 값은 ':' 다중
/// 토큰일 수 있어 정확매칭 대신 substring + 대소문자 무관.
fn currentDesktopContains(needle: []const u8) bool {
    if (posix.getenv("XDG_CURRENT_DESKTOP")) |xcd| {
        var buf: [128]u8 = undefined;
        if (xcd.len <= buf.len) {
            const lower = std.ascii.lowerString(buf[0..xcd.len], xcd);
            if (std.mem.indexOf(u8, lower, needle) != null) return true;
        }
    }
    return false;
}

/// COSMIC (smithay `cosmic-comp`) 세션인지 — hotkey 를 RON custom shortcut
/// (`Spawn("tildaz --toggle N")`) 으로 거는 환경 식별용 (`compositorHotkeyEnv`).
fn cosmicCompositor() bool {
    return currentDesktopContains("cosmic");
}

/// KWin (KDE Plasma) 세션인지. drop-down 재표시는 **기본이 destroy/recreate**
/// (단순·범용·정확 — 모든 compositor 의 첫 show 경로) 인데, KWin 만 surface 전체
/// 재생성이 ~165ms 로 느려(KWin Bug 503121) 그 한 곳에서만 #205 의 unmap→remap
/// (`attach(null)` 로 숨기고 속성 재전송으로 다시 map, wl_surface/layer_surface 유지)
/// 워크어라운드를 쓴다. wlroots 는 remap 도 되지만 recreate 도 빠르고, smithay
/// (cosmic-comp #230) 는 remap 미지원이라 recreate 가 정답 — 그래서 *예외는 KWin 한
/// 곳* 으로 모은다 (워크어라운드를 그 버그가 있는 compositor 에만).
fn kwinCompositor() bool {
    return currentDesktopContains("kde");
}

const Client = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    // #198 — native hotkey IPC. `tildaz --toggle` 보낸 두 번째 인스턴스의
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
    active_buffer: ?SurfaceBuffer = null,
    retired_buffers: std.ArrayList(SurfaceBuffer) = .{},
    compositor_id: u32 = 0,
    shm_id: u32 = 0,
    // #277 — `zwp_linux_dmabuf_v1`. 0 이면 compositor 가 노출하지 않은 것.
    linux_dmabuf_id: u32 = 0,
    // #277 — dmabuf v3 `modifier` event 로 확인한 "ARGB8888 + LINEAR" 지원 여부.
    // 현재 그리기는 CPU 가 하므로 (`gbm_bo_map` 필요) LINEAR 가 없으면 GPU 경로를
    // 쓰지 않는다. GLES 렌더러가 오면 이 제약이 사라진다.
    dmabuf_linear_supported: bool = false,
    // #277 — compositor 가 공표한 ARGB8888 modifier 후보. GLES 렌더러가 쓸 수 있는
    // modifier 를 고르는 데 쓴다 (LINEAR 를 공표하지 않는 환경 — NVIDIA 실측 — 대응).
    dmabuf_mods: [max_dmabuf_mods]u64 = undefined,
    dmabuf_mod_count: usize = 0,
    /// #367 — tranche 경계 (배타적 끝 index). 협상이 **tranche 단위로** 시도하려면
    /// 평탄화만으로는 부족하다 — tranche *사이*는 선호 순서지만 *안*은 동등해서,
    /// 안쪽 순위는 드라이버에게 맡겨야 하기 때문이다.
    dmabuf_tranche_ends: [max_dmabuf_tranches]usize = undefined,
    dmabuf_tranche_end_count: usize = 0,
    /// 채택한 modifier 의 plane 수 (압축이면 2 이상).
    gl_plane_count: usize = 1,
    /// #369 — 프레임 GPU 시간 측정 (`TILDAZ_GPU_TIMING=1`). timer query 가 동기점을
    /// 만들 수 있어 평소에는 끈다.
    gpu_timer: ?egl.GpuTimer = null,
    gpu_timer_frames: u64 = 0,
    // #277 S2-6 — dmabuf feedback (v4+). compositor 가 지원 목록을 **선호 내림차순
    // tranche** 로 준다 — v3 의 평면 `modifier` 목록에는 순서 정의가 아예 없어서
    // "처음 통과하는 것" 이 벤더마다 다른 품질의 선택이 됐다 (Intel 실기에서 LINEAR).
    dmabuf_feedback_id: u32 = 0,
    /// 후보 목록이 **이미 선호 순**인가 (feedback 경로). v3 평면 목록은 순서가
    /// 없으므로 false — 그때만 우리가 tiled 우선 규칙을 적용한다.
    dmabuf_mods_ordered: bool = false,
    /// `format_table` 로 받은 mmap. 항목은 16 byte {u32 format, 4 pad, u64 modifier}.
    dmabuf_format_table: ?[]align(std.heap.page_size_min) const u8 = null,
    dmabuf_main_device: u64 = 0,
    /// 현재 수신 중인 tranche 의 상태. `tranche_done` 에서 확정한다.
    dmabuf_tranche_device: u64 = 0,
    dmabuf_tranche_scanout: bool = false,
    dmabuf_tranche_mods: [max_dmabuf_mods]u64 = undefined,
    dmabuf_tranche_count: usize = 0,
    dmabuf_tranche_index: u32 = 0,
    // #277 — 위 후보 중 "할당 → EGLImage import → FBO complete" 까지 통과한 첫
    // modifier. null 이면 이 환경에서는 GLES 렌더러를 쓸 수 없다는 뜻이다.
    // 지금은 판정과 로그만 하고 실제 그리기에는 아직 쓰지 않는다.
    gl_modifier: ?u64 = null,
    // #277 — GPU 경로 자원. null 이면 처음부터 software `wl_shm` 으로 그린다.
    // 한 번 만들면 `Client.deinit` 까지 유지한다 — 아직 살아 있는 buffer 의 bo 를
    // 파괴하려면 device 가 필요하므로, 중간에 없애면 파괴 순서가 위험해진다.
    gpu: ?Gpu = null,
    // #277 — 새 buffer 를 GPU 로 할당할지. GPU 경로에서 한 번이라도 실패하면
    // false 로 내리고 (`disableGpu`) 다시 시도하지 않는다. 이미 할당된 GPU
    // buffer 는 평소 경로로 자연스럽게 회수된다.
    gpu_enabled: bool = false,
    // #277 — dmabuf buffer 생성 왕복 중인 params 객체와 그 결과. 생성은 동기
    // (`sendDmabufCreate` 가 결과까지 기다림) 라 한 번에 하나만 뜬다.
    pending_dmabuf_params: u32 = 0,
    pending_dmabuf_result: ?DmabufResult = null,
    // #277 S2 — GL 렌더용 EGL context. `gl_modifier` 가 정해지고 opt-in 이 켜진
    // 경우에만 유지한다. 있으면 buffer 를 GL 로 그리고, 없으면 CPU 가 그린다.
    gl_context: ?egl.Context = null,
    // #277 S2-6 — GL 로 그린다. 기본값이고 `TILDAZ_GL_RENDER=0` 으로 끈다.
    gl_render_enabled: bool = false,
    // #277 S2-3 — 단색 사각형 정점 배치. GL context 와 함께 만들고 매 frame 재사용한다.
    gl_batch: ?gl_rects.Batch = null,
    // #277 S2-4 — 글리프 atlas 와 텍스트 정점 배치. 역시 context 수명과 같이 간다.
    gl_atlas_store: ?gl_atlas.Atlas = null,
    gl_text_batch: ?gl_text.Batch = null,
    // #277 — GPU 경로 전용 scratch (일반 RAM).
    //
    // dma-buf 매핑은 write-combined (비캐시) 메모리라 **읽기가 매우 느린데**,
    // 우리 그리기는 알파 블렌딩에서 프레임버퍼를 읽는다 (`blendPixel`). 매핑에
    // 직접 그렸더니 같은 워크로드에서 CPU 점유가 shm 5.0% 대비 14.8% 로 3 배였다.
    // 그래서 일반 RAM 에 그린 뒤 dma-buf 로 한 번에 복사한다 — WC 는 순차 쓰기는
    // 빠르므로 읽기를 전부 캐시 메모리에서 끝내는 것이 이득이다.
    //
    // 크기가 바뀌면 재할당한다. software 경로에서는 쓰지 않는다.
    gpu_scratch: ?[]align(std.heap.page_size_min) u8 = null,
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
    pending_prompt_result: ?bool = null,
    prompt_validator: ?dialog_mod.HotkeyValidator = null,
    prompt_shortcuts_inhibitor_id: u32 = 0,
    pending_new_instance_request: bool = false,
    /// #203 Phase C step 4 — Alt+F4 의 deferred quit. Alt+F4 핸들러는 flag 만
    /// set, main loop 의 `drainQuitRequest` 가 multi-tab confirm + `running=false`.
    /// `dialog.showConfirm` 의 inner pump 가 `dispatchBuffered` 의 reentrant
    /// context 안에서 호출되면 안 됨 (deferred dismiss 와 동일 reentrancy 위험).
    pending_quit_request: bool = false,
    /// #87 — Alt+Enter / Shift+Alt+Enter fullscreen 상태. hide 가 건드리지 않아
    /// F1 hide→show 시 그대로 복원된다 (Win `Window.fullscreen_mode` 동등).
    /// layer-shell 계열에서만 동작 — xdg fallback(GNOME/Cinnamon)은 별도(#87).
    fullscreen_mode: FullscreenMode = .none,
    /// #213 — Ctrl+Shift+I 의 deferred About. key 핸들러는 flag 만 set, main
    /// loop 의 `drainAboutRequest` 가 실제로 About 다이얼로그를 연다. About 의
    /// `createDialogSurface` 가 `roundtrip` (inner dispatchBuffered) 을 돌리는데,
    /// 이게 outer `dispatchBuffered` 의 reentrant context 안에서 호출되면 공유
    /// `self.input` / `input_len` 이 outer 의 stale `offset` 과 어긋나 post-loop
    /// 의 `input_len - offset` 뺄셈이 underflow → integer overflow panic (#213).
    /// quit / dismiss 와 동일하게 deferred 로 reentrancy 제거.
    pending_about_request: bool = false,
    /// #282 C1 — info/error dialog 도 About 과 같은 deferred. `showInfo` 는
    /// 탭 한도(Ctrl+Shift+T)·shell 소실 알림에서 `handleNewTab`(= processKeyEvent
    /// reentrant) 를 통해 동기 호출되는데, `openInfoDialog` → `createDialogSurface`
    /// 의 roundtrip 이 outer dispatchBuffered 를 corrupt 한다 (About 과 동일 원인).
    /// callback 은 아래 buffer 에 복사 + flag set 만, main loop 의 `drainInfoRequest`
    /// 가 reentrancy 밖에서 연다.
    pending_info_request: bool = false,
    pending_info_severity: dialog_mod.Severity = .info,
    pending_info_title_buf: [128]u8 = undefined,
    pending_info_title_len: usize = 0,
    pending_info_msg_buf: [dialog_linux.message_capacity]u8 = undefined,
    pending_info_msg_len: usize = 0,
    pending_info_is_about: bool = false,
    pending_info_msg_owned: ?[]u8 = null,
    // L8-β / #295 — wl_output binding + 화면 해상도. layer-shell anchor / size /
    // margin 계산에 사용. mode event (flag CURRENT) 에서 width / height 받음.
    // 0 이면 못 받은 상태 — `screen_fallback_*` 로 대체.
    //
    // #295 — screen_width/height 는 "현재 기준 output" 의 해상도. 기준 output 은
    //   1. main surface 의 `wl_surface.enter` 가 가리킨 output (최우선), 없으면
    //   2. 첫 bind output (`output_id`).
    // advertise 된 모든 wl_output 을 `outputs` slot 에 bind/추적 — mixed-monitor
    // 에서 compositor 가 layer surface 를 focused output 에 놓았을 때 그 output
    // 의 mode/scale 로 layout 을 재계산한다 (sway headless 실측: 기준 불일치 시
    // 이종 해상도 폭 50%→62.5%, 이종 배율 50%→25% + 1x buffer upscale blur).
    output_id: u32 = 0,
    screen_width: i32 = 0,
    screen_height: i32 = 0,
    // #351 — layout 계산에 쓰는 **logical** work-area. compositor 가 알려준 값이고
    // 우리가 physical 에서 추정하지 않는다. 0 = 아직 못 받음.
    //
    // 출처는 `createShellObjects` 의 초기 안전 commit (#336) 이다 — 4-edge anchor
    // + `set_size(0,0)` + `set_margin(0,0,0,0)` + `exclusive_zone(0)` 상태의
    // configure 가 정확히 work-area (다른 panel 의 exclusive zone 을 뺀 영역) 다.
    // layer-shell spec: *"If you pass 0 for either value, the compositor will
    // assign it and inform you of the assignment in the configure event."*
    //
    // 왜 추정하지 않는가 — physical → logical 유도 규칙이 compositor 마다 다르다
    // (실측: 3840/1.7=2258.8 을 KWin 은 2259 로 올리고, 1280/1.7=752.9 를 sway 는
    // 752 로 내린다).
    // `physicalToLogical` 로 계산하면 KWin 에서 2258 이 나와 실제(2259)와 1 어긋나고,
    // 그 오차를 보정하려던 것이 overscan 이었다 (#220 → #233 → #351 로 세 번 반복).
    screen_logical_w: i32 = 0,
    screen_logical_h: i32 = 0,
    // #351 — 초기 안전 commit 을 보내고 그 configure 를 아직 못 받았는가. 두 가지를
    // 담당한다:
    //   ① 그 상태의 configure 만 work-area 로 latch (아래 configure 핸들러).
    //      **one-shot** — Hyprland 는 한 상태에서 configure 를 여러 번 보낸다 (실측 14회).
    //   ② 그 사이 실제 layout 송신을 **보류**. 두 state 가 동시에 outstanding 이면
    //      도착한 configure 가 어느 state 의 것인지 특정할 수 없다 (configure 를 commit
    //      마다 1:1 로 보내는 것은 spec 보장이 아니다 — coalesce 하는 compositor 에서는
    //      실제 layout 의 크기를 work-area 로 오인 latch 하게 된다). 보류한 송신은
    //      latch 직후 configure 핸들러가 이어서 보낸다 (continuation) — 유실이 아니다.
    initial_safe_pending: bool = false,
    outputs: [max_tracked_outputs]OutputSlot = [_]OutputSlot{.{}} ** max_tracked_outputs,
    // #295 — 현재 basis 로 쓰는 output 의 object id. 0 = 아직 미확정 (startup /
    // 재생성 직후) → 첫 bind output 이 기준. `wl_surface.enter`/`leave` 로 갱신되는
    // OutputSlot.entered 집합에서 batch 종료 후 안정적으로 선택 (drainSurfaceOutputs):
    // 현재 basis 가 여전히 집합에 있으면 유지한다. 이 "유지" 규칙이 핵심 —
    // sway/wlroots 는 인접 output 경계에 flush 인 layer surface 에 *양쪽* output
    // 의 enter 를 보내는데(KWin 은 실제 픽셀 덮는 output 만), enter 마다 basis 를
    // 뒤집으면 재생성 surface 가 또 양쪽 enter → 무한 recreate 진동이 된다
    // (기본 config offset=100 우측 패널 + 오른쪽 인접 모니터에서 실측 재현).
    current_output_object_id: u32 = 0,
    // #295 — 이번 dispatch batch 에 surface 의 enter/leave 가 있었음. batch 종료
    // 후 drainSurfaceOutputs 가 entered 집합을 보고 basis 를 한 번만 재선택한다
    // (intra-batch 의 중간 enter 값으로 recreate 예약하던 진동 제거). batch-local.
    surface_outputs_dirty: bool = false,
    // #295 — bindGlobals 완료 표시. 이후 도착하는 wl_output global (hotplug 연결)
    // 은 handleRegistryGlobal 이 즉시 bind, 이전 (startup registry dump) 은
    // bindGlobals 가 일괄 bind.
    globals_bound: bool = false,
    // #241 — 모니터 hotplug 대응 플래그.
    //  - output_topology_pending: 이번 dispatch batch 에 output topology 변화가
    //    있었음 — wl_output 의 global 추가(모니터 연결/재구성) 또는 우리 bind 한
    //    output 의 global_remove(분리). KWin 은 분리·재연결 모두에서 topology
    //    이벤트와 layer-surface closed 를 같은 batch 로 보낸다(시연 확인). 그래서
    //    closed 즉시 판정 대신, batch 전체 처리 후 main loop drain 에서 "quit 요청
    //    + 이 flag" 면 사용자 Alt+F4 가 아니라 output re-home 으로 보고 recreate.
    //    batch-local — drain 끝에서 clear 해 다음의 *진짜* Alt+F4 가 오인되지 않게.
    //    (batch 내 이벤트 순서 무관 — closed 가 topology 이벤트보다 먼저 와도 OK.)
    //  - pending_output_recreate: visible 상태 output topology 변화로 closed 된
    //    경우의 deferred 재생성 요청. closed/drain 은 swapMainSurfaceSeamless(내부
    //    configure pump=reentrant) 를 직접 못 부르므로 main loop 에서 처리.
    //  (#295 note: 이전의 output_rebind_pending 은 "첫 output 재bind 전용" 이라
    //   제거 — 이제 모든 신규 wl_output global 이 즉시 bind 되므로 replug 는
    //   일반 add 경로로 처리된다.)
    output_topology_pending: bool = false,
    pending_output_recreate: bool = false,
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
    keyboard_shortcuts_inhibit_manager_id: u32 = 0,
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
    /// #336 — preferred_scale event 를 한 번이라도 받았는지. layer-shell 의 첫
    /// 실제 layout commit 을 scale 확정까지 보류하는 boot 대기(settleInitialLayout)
    /// 의 종료 조건. 값이 안 바뀌는 100%(120→120) 케이스도 event 수신 자체로 확정
    /// 처리하려고 applyScaleChange 의 값 비교와 별개로 event handler 가 set 한다.
    preferred_scale_received: bool = false,
    /// #336 — 첫 frame(map) 이전에 layer-surface 가 closed 된 신호. boot 표시
    /// 경로가 이걸 보고 quit 이 아니라 destroy + 재생성(상한)으로 처리한다. map
    /// 이후의 pending_quit_request(Alt+F4 / output re-home, #241)와 구분된다.
    init_layer_closed: bool = false,
    // #244 — KDE Plasma direct KGlobalAccel용 D-Bus session bus client
    // (libdbus-1 dlopen). 연결 실패는 fatal 아님 — hotkey 없이 terminal 자체는
    // 정상이며 hidden_start는 즉시 표시로 fallback한다.
    dbus_session: ?dbus.SessionBus = null,
    // #244 — KDE Plasma KGlobalAccel direct client.
    // heap stable address는 D-Bus filter user_data가 참조하며, dbus_session보다
    // 먼저 deinit해야 한다.
    kglobalaccel_client: ?*kglobalaccel.Client = null,
    // KGlobalAccel filter 안에서는 Wayland roundtrip을 시작하지 않는다. Pressed
    // callback은 이 flag만 세우고 main loop가 D-Bus dispatch 반환 뒤 toggle한다.
    kglobalaccel_toggle_pending: bool = false,
    // surface visibility toggle state. macOS `g_visible` 동등. false
    // = 평소 (layer-shell mapped), true = hidden (wl_surface.attach(NULL) +
    // commit 송신 끝난 상태). 다음 toggle → flip + re-attach.
    surface_hidden: bool = false,
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
    /// #268 2b — 탭바 컨트롤 버튼 (`<` `>` `×` `+`) 의 hover 대상. pointer
    /// motion 마다 갱신, 변경 시에만 재렌더. 렌더러가 hover 배경 박스를 그림.
    tab_hover: tab_layout.Area = .none,
    /// #329 command/shortcut menu 표시 상태.
    command_menu_open: bool = false,
    command_menu_hover: ?command_menu.Command = null,
    /// #329 — 메뉴 keyboard focus (Up/Down/Home/End/Tab 이동, Enter/Space 실행).
    command_menu_focus: ?command_menu.Command = null,
    /// #329 — 작은 viewport 에서 entry 단위 scroll 의 첫 표시 entry 인덱스.
    command_menu_first: usize = 0,
    /// wheel fixed(1/256) 값 누적 — notch(2560) 단위 menu scroll (dialog 동일 패턴).
    command_menu_axis_remainder: i64 = 0,
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
    /// #245 — drag-select auto-scroll. 선택 드래그 중 포인터가 grid 위/아래 경계
    /// 밖이면 방향 저장(-1=위/older, +1=아래/newer, 0=비활성). main loop tick
    /// (`maybeAutoScrollSelection`)이 이 동안 주기적으로 viewport 스크롤 + 마지막
    /// 포인터(`pointer_*_px`)로 selection.update 재호출 → 멈춰 있어도 연속 스크롤 +
    /// scrollback 까지 선택 연장. 선택 종료(button release)에서 0 으로.
    sel_autoscroll_dir: i8 = 0,
    sel_autoscroll_next_ms: i64 = 0,
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
                .{ .name = "COLORFGBG", .value = themes.colorFgBg(theme) },
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
        if (self.kglobalaccel_client) |client| {
            client.deinit();
            self.allocator.destroy(client);
            self.kglobalaccel_client = null;
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
        for (self.dialog.retired_buffers.items) |*buffer| buffer.deinit();
        self.dialog.retired_buffers.deinit(self.allocator);
        if (self.gpu_scratch) |scratch| {
            self.allocator.free(scratch);
            self.gpu_scratch = null;
        }
        // #277 S2 — GL context 도 buffer 정리 뒤에 없앤다 (target 파괴가 context 를
        // 필요로 한다).
        if (self.gl_context) |*ctx| {
            // batch (셰이더 / 버퍼) 를 context 파괴 **전에** 정리한다 — GL 객체라
            // context 가 살아 있어야 지울 수 있다.
            if (self.gl_batch) |*batch| {
                batch.deinit(&ctx.api, self.allocator);
                self.gl_batch = null;
            }
            if (self.gl_text_batch) |*batch| {
                batch.deinit(&ctx.api, self.allocator);
                self.gl_text_batch = null;
            }
            if (self.gl_atlas_store) |*atlas| {
                atlas.deinit(&ctx.api, self.allocator);
                self.gl_atlas_store = null;
            }
            if (self.gpu_timer) |*t| {
                t.deinit(&ctx.api);
                self.gpu_timer = null;
            }
            ctx.deinit();
            self.gl_context = null;
            self.gl_render_enabled = false;
        }
        // #277 — GPU 자원은 **모든 buffer 를 정리한 뒤에** 없앤다. bo 파괴에
        // device 가 필요하므로 순서가 뒤바뀌면 안 된다.
        if (self.gpu) |*gpu| {
            gpu.deinit();
            self.gpu = null;
            self.gpu_enabled = false;
        }
        if (self.dialog.message_owned) |message| self.allocator.free(message);
        self.dialog.message_owned = null;
        if (self.pending_info_msg_owned) |message| self.allocator.free(message);
        self.pending_info_msg_owned = null;
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

        // Linux 세션 식별 — 어느 로그가 어느 DE인지 구분 + tildaz 의 sway/Hyprland
        // 감지 진단용. server=display protocol(XDG_SESSION_TYPE), de=DE 이름
        // (XDG_CURRENT_DESKTOP). swaysock/hyprland 신호는 tildaz 가 실제 감지에 쓰는
        // env($SWAYSOCK / $HYPRLAND_INSTANCE_SIGNATURE) — *있을 때만* 덧붙인다(평소
        // 깔끔, 어긋날 때만 튄다: 예 de=KDE 인데 swaysock=set = stale SWAYSOCK 버그).
        log.appendLine("startup", "session: server={s} de={s}{s}{s}", .{
            posix.getenv("XDG_SESSION_TYPE") orelse "(unset)",
            posix.getenv("XDG_CURRENT_DESKTOP") orelse "(unset)",
            if (posix.getenv("SWAYSOCK") != null) " swaysock=set" else "",
            if (posix.getenv("HYPRLAND_INSTANCE_SIGNATURE") != null) " hyprland=set" else "",
        });

        // #203 Phase C — dialog backend host callback 등록. self pointer 가
        // final 위치 (Client.init 가 by value 반환이라 init 안에서는 등록 못 함).
        // run 진입 시점 = stable address. defer 해제로 deinit 안 dangling 회피.
        dialog_linux.registerCallbacks(.{
            .ctx = self,
            .show_info = Client.dialogShowInfoCb,
            .show_about = Client.dialogShowAboutCb,
            .show_confirm = Client.dialogShowConfirmCb,
            .prompt_hotkey = Client.dialogPromptHotkeyCb,
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
        // #277 — roundtrip 이후여야 dmabuf 의 modifier event 가 다 도착해 있다.
        self.initGpuIfAvailable();
        self.logCapabilities();
        self.logBootElapsed("bind globals");
        self.tryConnectKGlobalAccel();
        self.logBootElapsed("KGlobalAccel");
        // L13-γ — ARGB8888 광고 필수 (opacity_percent 적용을 위한 alpha
        // channel). 거의 모든 compositor 가 광고하므로 fallback 없이 fatal.
        if (!self.saw_argb8888) return error.WaylandShmArgb8888Missing;
        try self.createKeyboardIfAvailable();
        if (self.keyboard_id != 0) try self.roundtrip();
        self.logBootElapsed("keyboard ready");

        // #282 C2 — startup shell 검증. Windows / macOS host 는 Config.load 직후
        // `shell_validate.validateOrFatal` 로 잘못된 `config.shell` 을 안내 후 종료하지만
        // Linux 는 이 검증이 없어, 잘못된 shell 이 안내 없이 첫 탭 execve 127 → 마지막
        // 탭 종료로 이어져 무설명으로 꺼졌다. dialog overlay 는 Wayland 연결 + globals
        // + keyboard 준비 이후에만 그릴 수 있으므로(연결 전 fire-and-forget showFatal 은
        // paint 전에 죽는다, #282 F9), 준비가 끝난 여기서 검증하고 — hidden_start 여부와
        // 무관하게, 첫 탭 PTY 를 띄우기 전에 — blocking overlay 로 안내한 뒤 종료한다.
        // 연결 자체가 실패한 환경은 이 지점에 도달하지 못하고 상위에서 stderr fallback.
        {
            if (shell_validate.validationMessage(self.allocator, self.config.shell)) |message| {
                // 메시지를 stderr + log 에도 남긴다 — overlay 를 못 띄우는 환경(headless
                // 등)에서도 원인이 남게. 그 뒤 blocking overlay 로 화면 안내.
                log.userFacing("fatal", message.text);
                self.runFatalDialog(messages.config_error_title, message.text);
                message.deinit(self.allocator);
                std.process.exit(1);
            }
        }

        // #282 B6 — startup font chain 검증 (#289). Windows(`isFontAvailable`)/
        // macOS(`CTFontCopyFamilyName`) 는 명시 family 미설치 시 fatal dialog 인데
        // Linux 만 loader 가 log + skip 으로 조용히 진행해 chain 의미가 달라졌다
        // (첫 family 미설치면 fallback 이 사실상 primary). 위 C2 shell 검증과 같은
        // 시점 — Wayland 준비 후, 첫 탭 PTY/renderer 전 — 에 fontconfig 가용성을
        // 검증하고 blocking overlay 로 안내 후 종료한다. libfontconfig 를 못 여는
        // 등 판정 불가(unknown)면 미설치로 오판하지 않고 loader 의 기존 에러
        // 경로에 맡긴다.
        {
            const chain = self.config.font_families[0..self.config.font_family_count];
            for (chain) |family| {
                if (family.len == 0) continue;
                if (font_linux.familyInstalled(self.allocator, family) != .missing) continue;
                var font_msg_buf: [2048]u8 = undefined;
                const msg = font_validate.notFoundMessage(&font_msg_buf, family, chain);
                log.userFacing("fatal", msg);
                self.runFatalDialog(messages.config_error_title, msg);
                std.process.exit(1);
            }
        }

        // L11-β — hidden_start: 등록 완료된 hotkey 경로가 있는 경우에만
        // surface 생성 skip + `surface_hidden=true` set. 첫 hotkey 신호가
        // `handleActivatedToggle` → `createShellObjects`
        // → configure handler 의 `ensureSessionGrid` 자동 호출로 정상 show.
        // mac `if (!g_config.hidden_start) showWindow();` / Windows `if (!config.hidden_start) app.window.show();`
        // 동등.
        //
        // hotkey backend 미가용 환경에서 hidden_start=true 면
        // 사용자가 영영 볼 수 없는 trap — warning log + 즉시 show 로 fallback.
        // hotkey 전달 경로가 있을 때만 hidden_start 존중 (없으면 사용자가 영영 못
        // 띄우는 trap → show-on-start fallback). 경로: KGlobalAccel(KDE Plasma)
        // 또는 sway/Hyprland/COSMIC 의 compositor keybind→`tildaz --toggle`
        // (sway_ipc 자동등록 / Hyprland·COSMIC 은 launcher 의 shortcut_sync 가
        // hyprctl bind / RON shortcut 으로 single_instance socket toggle 연결 —
        // compositorHotkeyEnv 주석 참조).
        // 첫 toggle 은 handleActivatedToggle 가 surface_id==0 분기로 createShellObjects.
        const has_compositor_hotkey = compositorHotkeyEnv();
        const has_kde_hotkey = if (self.kglobalaccel_client) |client| client.registered() else false;
        const hidden_at_start = self.config.hidden_start and (has_kde_hotkey or has_compositor_hotkey);
        if (self.config.hidden_start and !hidden_at_start) {
            log.appendLine("startup", "hidden_start ignored — no hotkey path (KGlobalAccel/GNOME/Cinnamon/COSMIC/Hyprland/sway), showing on start", .{});
        }
        if (hidden_at_start) {
            self.surface_hidden = true;
            log.appendLine("startup", "hidden_start — surface deferred until first hotkey toggle", .{});
            self.logBootElapsed("ready (hidden_start, awaiting first hotkey)");
        } else {
            try self.bringUpInitialSurface();
            self.logBootElapsed("first configure");
            try self.ensureSessionGrid();
            self.logBootElapsed("session+PTY");
            _ = try self.redraw();
            self.logBootElapsed("first frame");

            log.appendLine("linux", "Wayland terminal window mapped", .{});
        }

        // #304 — listener만 먼저 열린 시점이 아니라 Wayland globals, 입력,
        // renderer/첫 tab 또는 hidden-start 경로까지 준비된 뒤 endpoint 상태를
        // 공개한다. listener 실패는 terminal 실행을 막지 않고 unavailable로 남긴다.
        try instances.recordEndpointState(
            self.allocator,
            instance_context.requireWorkerIndex(),
            if (self.toggle_listener_fd >= 0) .ready else .unavailable,
        );

        while (self.running) {
            try self.pollAndDispatch(frame_poll_ms);
            // #203 Phase C — dialog dismiss 가 pending 이면 *여기서* 실제 처리.
            // pointer button / dialog key / layer-surface closed handler 들은
            // dispatchBuffered 의 reentrant context 안이라 inner roundtrip 시
            // outer buffer state corrupt (사용자 시연 발견 — `BadMessage offset
            // input_len=0` 진단). deferred 로 reentrancy 해소.
            self.drainPendingDialogDismiss();
            self.drainDialogRepaint();
            // #241 — batch 전체 처리 후 판정: visible 상태에서 들어온 quit 요청
            // (layer-surface closed)이 이번 batch 의 output topology 변화(모니터
            // 연결/분리)와 함께 온 것이면 사용자 Alt+F4 가 아니라 output re-home →
            // quit 대신 재생성. batch 내 이벤트 순서 무관. layer-shell 전용(xdg 의
            // close 는 advisory — 이 경로로 안 옴).
            if (self.pending_quit_request and self.output_topology_pending and self.layer_surface_id != 0) {
                self.pending_quit_request = false;
                self.pending_output_recreate = true;
                log.appendLine("input", "quit request coincided with output topology change — recreate instead of quit (#241)", .{});
            }
            // #203 Phase C step 4 — Alt+F4 deferred quit. confirm 의 inner pump
            // 도 outer dispatchBuffered 밖에서 호출.
            self.drainQuitRequest();
            // #295 — batch 종료 후 surface 의 enter/leave 집합으로 basis 재선택.
            // drainOutputRecreate 보다 먼저 — mapped basis 전환은 여기서
            // pending_output_recreate 를 set 하고 아래 drain 이 같은 iteration 에 처리.
            self.drainSurfaceOutputs() catch |err| {
                log.appendLineVerbose("wayland", "drainSurfaceOutputs 실패: {s}", .{@errorName(err)});
            };
            // #241 — visible 상태 output topology 변화로 closed 된 경우의 재생성도
            // outer dispatchBuffered 밖에서(swapMainSurfaceSeamless 가 configure pump).
            self.drainOutputRecreate();
            // #241 — output_topology_pending 은 batch-local. 위 판정/소비 후 매
            // iteration 끝에서 clear 해 다음의 *진짜* Alt+F4 가 오인되지 않게 한다.
            self.output_topology_pending = false;
            // #213 — Ctrl+Shift+I deferred About. createDialogSurface 의 inner
            // roundtrip 을 outer dispatchBuffered 밖에서 돌려 buffer corrupt 회피.
            self.drainAboutRequest();
            self.drainInfoRequest();
            self.drainNewInstanceRequest();
            // L12-β — exit 한 탭들을 main thread 에서 close. read thread 의
            // `linuxTabExit` 가 pending_close_buf 에 ptr 쌓아둠. drain 이
            // 마지막 탭 닫음을 만나면 shell_exited 트리거.
            self.drainExitedTabs();
            // KGlobalAccel Pressed / NameOwnerChanged D-Bus signal dispatch.
            self.dispatchDbusMessages();
            // L12-γ-5 — Wayland client-side key repeat timer 검사.
            try self.maybeRepeatKey();
            // #245 — drag-select auto-scroll tick (포인터가 grid 경계 밖에 머물면 연속).
            self.maybeAutoScrollSelection();
            if (self.shell_exited.load(.acquire)) {
                self.running = false;
                break;
            }
            if (self.session) |*session| {
                if (session.drainOutputForRender()) {
                    self.requestRedraw();
                }
            }
            try self.maybeRedraw();
            // #193 — command menu 열림/닫힘 등 state 변화 후 mouse 안 움직여도 즉시
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
        // #277 — GPU (dma-buf) 경로. **v4 가 있으면 v4 로 bind 하고 feedback 을 쓴다.**
        // v4 부터 `format` / `modifier` event 는 deprecated 이고 compositor 가 보내지
        // *않으므로* (프로토콜 명시), v4 로 bind 하면 feedback 이 유일한 정보원이다.
        // 그 대신 tranche 가 **선호 내림차순**으로 오고 scanout 힌트가 붙는다 —
        // v3 의 평면 목록에는 순서 정의가 없어서 우리가 임의로 골라야 했다.
        if (self.caps.linux_dmabuf.name != 0) {
            const version = @min(self.caps.linux_dmabuf.version, 4);
            self.linux_dmabuf_id = self.allocId();
            try self.bind(
                self.caps.linux_dmabuf.name,
                "zwp_linux_dmabuf_v1",
                version,
                self.linux_dmabuf_id,
            );
            if (version >= 4) {
                // zwp_linux_dmabuf_v1.get_default_feedback (opcode 2, since v4).
                self.dmabuf_feedback_id = self.allocId();
                try self.sendNewId(self.linux_dmabuf_id, 2, self.dmabuf_feedback_id);
            }
        }
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
        // L8-β / #295 — wl_output bind. mode event 에서 screen_width /
        // screen_height 받아 layer-shell anchor / size / margin 계산에 사용.
        // #295: advertise 된 *모든* wl_output 을 bind (registry dump 중
        // handleRegistryGlobal 이 `outputs` slot 에 기록). 첫 bind output 이
        // enter 이전의 기본 기준. v≤2 로 bind — release destructor 가 v3 부터라
        // 제거된 output 의 proxy id 는 그냥 버린다 (#241 주석 참고).
        for (&self.outputs) |*slot| {
            if (slot.global_name == 0 or slot.object_id != 0) continue;
            slot.object_id = self.allocId();
            try self.bind(slot.global_name, "wl_output", @min(slot.version, 2), slot.object_id);
            if (self.output_id == 0) self.output_id = slot.object_id;
        }
        self.globals_bound = true;
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
        if (self.caps.keyboard_shortcuts_inhibit.name != 0) {
            self.keyboard_shortcuts_inhibit_manager_id = self.allocId();
            try self.bind(
                self.caps.keyboard_shortcuts_inhibit.name,
                "zwp_keyboard_shortcuts_inhibit_manager_v1",
                @min(self.caps.keyboard_shortcuts_inhibit.version, 1),
                self.keyboard_shortcuts_inhibit_manager_id,
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
        // #197 — 개별 protocol object id 는 wire-level detail 이라 verbose.
        // production 용 capabilities 요약은 boot 시 logCapabilities() 가 담당.
        log.appendLineVerbose("wayland", "bound globals compositor_id={} shm_id={} wm_base_id={} seat_id={} data_device_manager_id={} text_input_manager_id={} text_input_id={} layer_shell_id={} output_id={}", .{
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
    /// SPEC.md §3.1 — cell 영역 → text (I-beam), 그 외 → default arrow.
    fn updateCursorShape(self: *Client) !void {
        if (self.cursor_shape_device_id == 0) return; // protocol 미advertise
        if (self.last_pointer_enter_serial == 0) return; // enter event 아직
        const shape = cursorShapeForSurface(
            self.last_pointer_enter_surface_id,
            self.surface_id,
            self.pointerInCellArea(),
        );
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

    /// #329 정책 변경 (2026-07-22) — MAX_TABS 도달 시 `+` 는 자리 유지 +
    /// 비활성 (색 / hover 없음 / click noop). 단축키 경로 dialog 는 그대로.
    fn tabPlusEnabled(self: *const Client) bool {
        const session = if (self.session) |*s| s else return true;
        return session.count() < session_core.MAX_TABS;
    }

    /// #268 2b — 탭바 컨트롤 버튼 hover 갱신. 버튼 (`<` `>` `×` `+`) 위에서만
    /// hover, 탭 본체 / 탭바 밖은 .none. 변경 시에만 재렌더.
    fn updateTabHover(self: *Client) void {
        if (self.command_menu_open) {
            const hover = self.commandMenuHit(self.pointer_x_px, self.pointer_y_px);
            if (hover != self.command_menu_hover or self.tab_hover != .none) {
                self.command_menu_hover = hover;
                // #329 — pointer 가 항목 위로 오면 keyboard focus 도 동기화 (표준
                // 메뉴 동작). 안 하면 마우스로 건너뛴 뒤 ↑↓ 가 옛 위치에서 출발.
                if (hover) |h| self.command_menu_focus = h;
                self.tab_hover = .none;
                self.needs_redraw = true;
            }
            return;
        }
        self.command_menu_hover = null;
        const new_hover: tab_layout.Area = blk: {
            const session = if (self.session) |*s2| s2 else break :blk .none;
            const x = self.pointer_x_px;
            const y = self.pointer_y_px;
            if (session.count() == 1) break :blk self.singleControlHit(x, y);
            const tab_bar_h = self.effectiveTabBarHeightPx();
            if (x < 0 or y < 0 or y >= tab_bar_h) break :blk .none;
            const layout_inputs = tab_layout.Inputs{
                .viewport_w = @floatFromInt(self.window_width),
                .tab_count = @intCast(session.count()),
                .tab_w = @floatFromInt(self.renderer.tabWidthPx()),
                .arrow_w = @floatFromInt(self.renderer.tabArrowWPx()),
                .plus_w = @floatFromInt(self.renderer.tabPlusWPx()),
                .plus_enabled = self.tabPlusEnabled(),
                .close_w = @floatFromInt(self.renderer.tabCloseWPx()),
                .more_w = @floatFromInt(self.renderer.tabMoreWPx()),
                .scroll_x = self.tab_scroll_x,
            };
            const layout = tab_layout.compute(layout_inputs);
            break :blk switch (tab_layout.hitArea(
                @floatFromInt(x),
                @floatFromInt(y),
                @floatFromInt(tab_bar_h),
                layout,
            )) {
                // #329 — 비활성 `+` 는 hover 강조도 없음.
                .plus => if (layout.plus_enabled) tab_layout.Area.plus else .none,
                .left_arrow, .right_arrow, .close, .more => |a| a,
                .tab_area, .none => .none,
            };
        };
        if (new_hover != self.tab_hover) {
            self.tab_hover = new_hover;
            self.needs_redraw = true;
        }
    }

    fn singleControlHit(self: *const Client, x: i32, y: i32) tab_layout.Area {
        const session = if (self.session) |*s| s else return .none;
        if (session.count() != 1 or x < 0 or y < 0) return .none;
        const layout = tab_layout.compute(.{
            .viewport_w = @floatFromInt(self.window_width),
            .tab_count = 1,
            .tab_w = @floatFromInt(self.renderer.tabWidthPx()),
            .arrow_w = @floatFromInt(self.renderer.tabArrowWPx()),
            .plus_w = @floatFromInt(self.renderer.tabPlusWPx()),
            .plus_enabled = self.tabPlusEnabled(),
            .close_w = @floatFromInt(self.renderer.tabCloseWPx()),
            .more_w = @floatFromInt(self.renderer.tabMoreWPx()),
            .scroll_x = 0,
        });
        return switch (tab_layout.hitArea(
            @floatFromInt(x),
            @floatFromInt(y),
            @floatFromInt(self.renderer.chromeHeightPx()),
            layout,
        )) {
            .plus, .close, .more => |a| a,
            else => .none,
        };
    }

    /// 현재 pointer 위치 (physical px) 가 cell 영역인지. 좌표가 음수 (pointer
    /// 영역 밖) 면 false.
    fn pointerInCellArea(self: *const Client) bool {
        const x = self.pointer_x_px;
        const y = self.pointer_y_px;
        if (x < 0 or y < 0) return false;
        if (self.singleControlHit(x, y) != .none) return false;
        if (self.command_menu_open) {
            const scale = self.renderer.scale;
            const menu = self.commandMenuView().rect;
            const px = @as(f32, @floatFromInt(x)) / scale;
            const py = @as(f32, @floatFromInt(y)) / scale;
            if (px >= menu.x and px < menu.x + menu.w and py >= menu.y and py < menu.y + menu.h) return false;
        }
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
        const index = instance_context.requireWorkerIndex();
        var title_buf: [32]u8 = undefined;
        const title = try @import("../../instances.zig").windowTitle(&title_buf, index);
        var app_id_buf: [32]u8 = undefined;
        const app_id = try instance_identity.appId(&app_id_buf, index);
        try self.sendString(self.toplevel_id, 2, title);
        try self.sendString(self.toplevel_id, 3, app_id);
        try self.sendNoArgs(self.surface_id, 6);
        log.appendLineVerbose("wayland", "shell objects (xdg) surface_id={} xdg_surface_id={} toplevel_id={}", .{
            self.surface_id,
            self.xdg_surface_id,
            self.toplevel_id,
        });
    }

    /// L8-α — wlr-layer-shell drop-down surface 경로. compositor 가
    /// `zwlr_layer_shell_v1` advertise 한 경우. config 의 dock_position /
    /// width_percent / height_percent / offset_percent 를 anchor / size /
    /// margin 으로 변환해 송신. L8-γ slide animation 은 SPEC 아님,
    /// global hotkey toggle 은 별도.
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

        // #336 — 첫 commit 은 preferred_scale 확정 전이라 scale=1.0 로 물리 margin 을
        // logical 로 오해할 수 있다(낮은 height_percent + fractional 이면 유효 높이
        // 음수 → compositor 가 surface 를 closed). 그래서 여기선 scale 무관 항상 유효한
        // 초기 안전 layout(4-edge span)만 commit 해 output 배정을 트리거하고, 실제 config
        // layout 은 settleInitialLayout 이 preferred_scale 을 받은(또는 타임아웃) 뒤 보낸다.
        try self.sendLayerSurfaceLayout(true);
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
    fn sendLayerSurfaceLayout(self: *Client, initial_safe: bool) !void {
        if (self.layer_surface_id == 0) return;
        // #351 — 초기 안전 commit 의 configure 를 기다리는 중이면 실제 layout 송신을
        // 보류한다. outstanding state 를 항상 하나로 유지해 도착한 configure 가 어느
        // state 의 것인지 모호해지지 않게 하는 것 (필드 주석 참고). 보류한 송신은
        // configure 핸들러가 latch 직후 이어서 보낸다.
        //
        // `!configured` 를 함께 보는 이유 — 보류가 필요한 구간은 map 전(첫 configure
        // 전)뿐이다. 그 이후 경로 (remapShellObjects / toggleFullscreen /
        // applyBasisOutput / applyScaleChange) 는 pending 이 어떤 값이든 막히지 않는다.
        if (!initial_safe and self.initial_safe_pending and !self.configured) {
            log.appendLineVerbose("wayland", "layout send deferred — awaiting initial-safe configure (#351)", .{});
            return;
        }
        self.initial_safe_pending = initial_safe;
        const layout = self.computeLayerLayout();
        // #87 — fullscreen 이면 config layout 대신 output 전체로 override:
        // 4-edge anchor + size 0 (compositor 가 anchored span 채움) + margin 0.
        // exclusive_zone 은 아래에서 cover=-1 (패널 덮음) / avoid=0 (work-area).
        //
        // #336 — initial_safe: preferred_scale 확정 전 boot 첫 commit. scale 무관
        // 항상 유효한 4-edge span + size 0 + margin 0 으로 output 배정만 트리거해
        // compositor 가 preferred_scale 을 보내게 한다 (buffer attach 전이라 화면
        // 안 보임). fullscreen 과 같은 span 배치라 같은 분기를 재사용 — exclusive_zone
        // 은 아래에서 fs 로 별도 판정(.none → 0)하므로 초기 commit 은 work-area 존중.
        const fs = self.fullscreen_mode;
        const fullscreen = fs != .none or initial_safe;
        const all_anchor: u32 = zwlr_layer_surface_anchor_top | zwlr_layer_surface_anchor_bottom | zwlr_layer_surface_anchor_left | zwlr_layer_surface_anchor_right;
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
            &.{if (fullscreen) all_anchor else layout.anchor},
        );
        // layer-shell spec: set_size / set_margin 은 *surface-local logical pixel*
        // 단위이고, #351 이후 `LayerLayout` 이 이미 logical 이라 변환이 없다.
        // (현재 `computeLayerLayout` 은 항상 4-edge anchor + size 0 을 쓰므로 두 값은
        // 0 이다 — spec: 0 이면 compositor 가 정하고 configure 로 알려준다.)
        const logical_w: u32 = if (fullscreen) 0 else layout.width;
        const logical_h: u32 = if (fullscreen) 0 else layout.height;
        try self.sendArgs(
            self.layer_surface_id,
            zwlr_layer_surface_v1_request_set_size,
            &.{ logical_w, logical_h },
        );
        // set_exclusive_zone — 평소 0 (다른 panel exclusive zone 회피). #87 cover
        // fullscreen 만 -1 로 패널 위까지 덮음 (avoid / non-fullscreen 은 0).
        //
        // #351 — 초기 안전 commit 은 cover fullscreen 중에도 0 이다. 이 commit 의
        // configure 를 logical work-area 로 latch 하는데, -1 이면 패널을 포함한 화면
        // 전체가 와서 work-area 가 아니게 된다 (fullscreen 을 빠져나온 뒤 layout 이
        // 패널을 침범 — #233 회귀). buffer attach 전이라 화면에 안 보이고, 뒤이어
        // continuation 이 실제 layout(-1) 을 보낸다. boot 는 이미 이 값(fs=.none → 0)
        // 으로 #336 검증을 통과한 경로라, recreate 도 같은 값으로 통일된다.
        const ez_i32: i32 = if (fs == .cover and !initial_safe) -1 else 0;
        const ez_u32: u32 = @bitCast(ez_i32);
        try self.sendArgs(
            self.layer_surface_id,
            zwlr_layer_surface_v1_request_set_exclusive_zone,
            &.{ez_u32},
        );
        // set_margin — 논리 픽셀 단위. cross-axis 위치 결정.
        // #220/#233 — overscan = "각 변의 목표를 올림(ceil)". 화면 먼 끝(우/하)은
        // 분수 logical 위치(예 3840÷1.7=2258.82)라, KWin 의 화면 논리 너비
        // = floor(물리/배율) 에 둔 부분 크기 표면의 그 가장자리가 물리 끝보다 1픽셀
        // 미만 짧아져 마지막 한 줄이 안 덮인다(#220). 그 변만 여백 1 논리 픽셀 음수로
        // 보내(= 올림) 화면 밖으로 넘기면 compositor 가 경계에서 잘라내 마지막 줄을
        // 덮는다.
        //
        // #233 — 단, 올림은 "분수일 때만" 이다. 정수 logical 목표인 변엔 올릴 게 없다:
        //   (a) 원점 변(top/left): logical 0 = 물리 0 → 항상 정확(#220 실측: offset 0
        //       좌측 갭 0). overscan 불필요·유해.
        //   (b) stretch 축의 먼 변: KWin 이 full-span 을 물리 경계로 snap (또는 다른
        //       panel 의 exclusive zone 을 피해 정수 경계에 배치) → 정확. overscan 시
        //       그 정수 경계(예: 하단 시스템 패널 top)를 1 논리 픽셀(≈ scale 물리 px)
        //       침범한다(#233 회귀: dock=top 풀높이 + 하단 패널에서 패널 top 가림).
        // 그래서 overscan 은 **부분축(non-stretch)의 화면 먼 끝 flush 변(right/bottom,
        // 여백 0)** 에만 건다. 원점·stretch축·패널에 닿는 변은 여백 0 그대로 두면 KWin
        // 이 정수 경계에 정확히 놓는다(= 정수 올림 no-op).
        if (fullscreen) {
            // #87 — output 전체라 여백 0, overscan 불필요 (4-edge anchor + size 0).
            var margin_msg = Msg.init(self.layer_surface_id, zwlr_layer_surface_v1_request_set_margin);
            try margin_msg.putI32(0);
            try margin_msg.putI32(0);
            try margin_msg.putI32(0);
            try margin_msg.putI32(0);
            try margin_msg.send(self.stream);
        } else {
            // #351 — margin 은 `computeLayerLayout` 이 이미 **logical** 로 계산했다.
            // 변환도 overscan 보정도 없다.
            //
            // 이전에는 physical 로 계산해 여기서 `physicalToLogical` (버림) 했고,
            // 그 버림 오차 때문에 먼 끝이 1px 안 맞아 `overscan(-1)` 로 보정했다.
            // 오차의 정체는 "compositor 의 logical work-area 를 우리가 추정한 것"
            // 이고, 그 추정을 없앤 지금은 보정할 것이 없다.
            //
            // 실측 근거 — KWin · sway · Hyprland · cosmic-comp 네 compositor 에서
            // overscan 없이 먼 끝이 물리적으로 flush 이고, KWin scale 1.0 에서는
            // overscan 이 오히려 창 마지막 물리 열을 화면 밖으로 밀어냈다 (#351).
            var margin_msg = Msg.init(self.layer_surface_id, zwlr_layer_surface_v1_request_set_margin);
            try margin_msg.putI32(layout.margin_top);
            try margin_msg.putI32(layout.margin_right);
            try margin_msg.putI32(layout.margin_bottom);
            try margin_msg.putI32(layout.margin_left);
            try margin_msg.send(self.stream);
        }
        // set_keyboard_interactivity(on_demand) — show 시 키보드 포커스를 받되 *독점
        // 안 함*. exclusive 는 떠 있는 동안 다른 창에 포커스를 못 줘서(특히 Hyprland 은
        // 엄격히 키보드를 독점 → 다른 창 클릭 불가), on_demand 로 클릭-어웨이 허용 →
        // mac/win 의 focus-loss z-order 양보(#195) 정신과 맞다. (dialog 는 modal 이라
        // exclusive 유지 — createDialogSurface 참고.) 단 on_demand 는 show 시 자동
        // 포커스가 compositor 구현마다 달라(KDE/sway/Hyprland) 실기 확인 필요.
        //
        // on_demand(값 2) enum 은 layer-shell **version 4 부터**. v4 미만 서버에 보내면
        // 표준상 invalid — wlroots 는 관대히 `!!interactive`(=exclusive) 로 강등하지만
        // (크래시 X) 그 관대함에 기대지 않고, set_layer(`version >= 2`) 와 같은 패턴으로
        // 버전 가드를 둔다: v4+ 면 on_demand, 미만이면 exclusive(전 버전 유효, 무회귀).
        // 현행 compositor 는 모두 v4+ advertise (KWin v5 / Hyprland·sway v4) 라 실제론
        // 항상 on_demand — 가드는 오래된 wlroots(<0.15, v3) 등 tail case 안전망.
        const ki: u32 = if (self.caps.layer_shell.version >= 4)
            zwlr_layer_surface_keyboard_interactivity_on_demand
        else
            zwlr_layer_surface_keyboard_interactivity_exclusive;
        try self.sendArgs(
            self.layer_surface_id,
            zwlr_layer_surface_v1_request_set_keyboard_interactivity,
            &.{ki},
        );
        // wl_surface.commit (opcode 6) — pending double-buffered state 적용.
        try self.sendNoArgs(self.surface_id, 6);

        // #351 — `work_area` 는 layout 계산의 기준값이다. `latched=true` 면 초기 안전
        // commit 의 configure 로 받은 compositor 의 logical work-area, false 면 아직
        // 못 받아 physical 에서 추정한 fallback (변환 오차 ±1 가능).
        log.appendLineVerbose("wayland", "shell objects (layer-shell) surface_id={} layer_surface_id={} dock={s} screen={}x{} work_area={}x{} latched={} scale={d}/120 anchor=0x{x} size={}x{} (logical {}x{}) margin=({},{},{},{}) keyboard_interactivity={s} (layer_shell v{})", .{
            self.surface_id,
            self.layer_surface_id,
            @tagName(self.config.dock_position),
            self.screen_width,
            self.screen_height,
            self.screenLogicalWidth(),
            self.screenLogicalHeight(),
            self.screen_logical_w > 0 and self.screen_logical_h > 0,
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
            if (ki == zwlr_layer_surface_keyboard_interactivity_on_demand) "on_demand" else "exclusive",
            self.caps.layer_shell.version,
        });
    }

    /// #87 — Alt+Enter (cover) / Shift+Alt+Enter (avoid) fullscreen 토글.
    /// Win `toggleFullscreenMode` 동등 — 같은 모드 키 = dock 복귀(none), none →
    /// 그 모드, 다른 모드 = no-op.
    ///   • layer-shell(KWin/sway/Hyprland/COSMIC): sendLayerSurfaceLayout 가
    ///     anchor/size/exclusive_zone 를 재전송 → configure → resize + redraw.
    ///   • xdg-shell fallback(GNOME/Cinnamon): 위치/크기를 Shell 확장이 잡으므로
    ///     layer 식 재배치 불가. xdg_toplevel 표준 상태 요청을 compositor 에 위임
    ///     (cover=set_fullscreen, avoid=set_maximized) — applyXdgFullscreen 참조.
    fn toggleFullscreen(self: *Client, mode: FullscreenMode) void {
        const prev = self.fullscreen_mode;
        const next: FullscreenMode = if (prev == mode)
            .none
        else if (prev == .none)
            mode
        else
            return; // 다른 모드 → no-op (Win 동등)
        self.fullscreen_mode = next;

        if (self.layer_surface_id != 0) {
            self.sendLayerSurfaceLayout(false) catch |err| {
                log.appendLine("wayland", "fullscreen relayout failed: {s}", .{@errorName(err)});
                return;
            };
        } else if (self.toplevel_id != 0) {
            self.applyXdgFullscreen(prev, next) catch |err| {
                log.appendLine("wayland", "fullscreen xdg request failed: {s}", .{@errorName(err)});
                return;
            };
        } else return;

        self.requestRedraw();
        log.appendLine("input", "fullscreen → {s}", .{@tagName(self.fullscreen_mode)});
    }

    /// #87 xdg-shell 경로 — fullscreen_mode 전이를 xdg_toplevel 상태 요청으로 변환.
    /// toggle 로직상 prev↔next 는 항상 한쪽이 none(cover↔avoid 직접 전환 없음)이라
    /// 두 switch 중 하나만 동작 — 나머지는 안전망. set_fullscreen 의 output 인자는
    /// null(0) = compositor 선택. 새 크기는 뒤따르는 xdg_toplevel.configure 가
    /// 전달 → 기존 configure 처리로 resize. mutter/muffin 은 maximize/fullscreen
    /// 상태를 minimize↔복원 간 보존하므로 확장의 F1 hide/show 후에도 유지된다.
    fn applyXdgFullscreen(self: *Client, prev: FullscreenMode, next: FullscreenMode) !void {
        switch (prev) {
            .cover => try self.sendNoArgs(self.toplevel_id, xdg_toplevel_request_unset_fullscreen),
            .avoid => try self.sendNoArgs(self.toplevel_id, xdg_toplevel_request_unset_maximized),
            .none => {},
        }
        switch (next) {
            .cover => try self.sendArgs(self.toplevel_id, xdg_toplevel_request_set_fullscreen, &.{0}),
            .avoid => try self.sendNoArgs(self.toplevel_id, xdg_toplevel_request_set_maximized),
            .none => {},
        }
        // wl_surface.commit (opcode 6) — 상태 요청 반영.
        try self.sendNoArgs(self.surface_id, 6);
    }

    /// #351 — layout 계산의 기준이 되는 **logical work-area**. 우선순위:
    ///   ① `screen_logical_*` — 초기 안전 commit 의 configure 로 compositor 가 알려준
    ///      값 (패널의 exclusive zone 을 뺀 영역). 정확하다.
    ///   ② physical → logical 추정 — ①을 아직 못 받은 구간 (첫 configure 전, 또는
    ///      output dims 변경 후 재생성 전) 의 fallback. 유도 규칙이 compositor 마다
    ///      달라 ±1 오차가 가능하다 (실측: 3840/1.7 을 KWin 은 2259 로 올리고 sway 는
    ///      1280/1.7 을 752 로 내린다). ①이 도착하면 교정된다.
    ///   ③ output mode 도 아직 모르는 boot 극초기 — 고정 fallback 상수.
    fn screenLogicalWidth(self: *const Client) i32 {
        if (self.screen_logical_w > 0) return self.screen_logical_w;
        if (self.screen_width > 0) return self.physicalToLogical(self.screen_width);
        return screen_fallback_width;
    }

    fn screenLogicalHeight(self: *const Client) i32 {
        if (self.screen_logical_h > 0) return self.screen_logical_h;
        if (self.screen_height > 0) return self.physicalToLogical(self.screen_height);
        return screen_fallback_height;
    }

    /// L8-β — config 의 dock_position / width_percent / height_percent /
    /// offset_percent 를 layer-shell 의 anchor mask / set_size args / margin
    /// args 로 변환. mac `screenFrameForDock` 와 동등 시각 결과 — 4-edge anchor
    /// + size 0 + 양쪽 margin 으로 표현하고, 점유율은 margin 차이로 낸다.
    fn computeLayerLayout(self: *const Client) LayerLayout {
        const cfg = self.config;
        // #351 — **logical 단위로 계산한다** (layer-shell 의 native 단위).
        const sw_i: i32 = self.screenLogicalWidth();
        const sh_i: i32 = self.screenLogicalHeight();
        const sw_f: f32 = @floatFromInt(sw_i);
        const sh_f: f32 = @floatFromInt(sh_i);
        const off_pct = std.math.clamp(cfg.offset_percent, 0.0, 100.0);
        const want_w: u32 = pctToPx(sw_f, cfg.width_percent);
        const want_h: u32 = pctToPx(sh_f, cfg.height_percent);
        const want_w_i: i32 = @intCast(@min(want_w, @as(u32, std.math.maxInt(i32))));
        const want_h_i: i32 = @intCast(@min(want_h, @as(u32, std.math.maxInt(i32))));
        // 점유율 100% 는 특수 분기가 필요 없다 (#351) — logical 로 계산하면
        // `want == screen` 이라 margin 이 **정확히 0** 이 된다. 이전에는 physical
        // 계산 + 버림 변환의 잔차를 없애려고 `stretch_w`/`stretch_h` 로 강제 0 을
        // 넣었고, 그 플래그가 overscan 판정에도 쓰였다. 둘 다 사라졌다.

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
        // 패턴으로 보낸다. 한 축이 100% 인 케이스도 동일 — 양쪽 margin 모두 지정
        // (한 쪽은 0). 이유: size 를 명시하면 compositor 가 그 크기를 놓고 반대편
        // edge 위치를 우리 계산에 맡기지만, size=0 + 양쪽 margin 이면 surface 크기를
        // compositor 가 `screen_logical − margin_start − margin_end` 로 **자기 좌표계
        // 안에서** 계산한다. #351 이후 우리 margin 도 그 screen_logical 을 그대로 쓴
        // logical 값이라 이 식이 정수로 정확히 닫히고, 먼 edge 가 구조적으로 flush 다
        // (예전에는 physical 계산 + 버림 변환의 잔차 때문에 여기서 1px 이 어긋났고
        // overscan 으로 보정했다). 폭 차이를 *size* 가 아니라 *margin 차이* 로
        // 표현하는 게 핵심.
        const margin_h_extra = sw_i - want_w_i; // 남는 공간 (가로)
        const margin_v_extra = sh_i - want_h_i; // 남는 공간 (세로)
        // cross-axis (docked 축이 아닌 축) — 남는 공간을 offset_percent 로 분배.
        const ml = pxOffset(margin_h_extra, off_pct);
        const mr = margin_h_extra - ml;
        const mt = pxOffset(margin_v_extra, off_pct);
        const mb = margin_v_extra - mt;
        // docked 축 — 붙는 edge 는 margin 0, 반대 edge 가 남는 공간 전부.
        return switch (cfg.dock_position) {
            .top => LayerLayout{
                .anchor = a_top | a_bottom | a_left | a_right,
                .width = 0,
                .height = 0,
                .margin_top = 0,
                .margin_right = mr,
                .margin_bottom = margin_v_extra,
                .margin_left = ml,
            },
            .bottom => LayerLayout{
                .anchor = a_top | a_bottom | a_left | a_right,
                .width = 0,
                .height = 0,
                .margin_top = margin_v_extra,
                .margin_right = mr,
                .margin_bottom = 0,
                .margin_left = ml,
            },
            .left => LayerLayout{
                .anchor = a_top | a_bottom | a_left | a_right,
                .width = 0,
                .height = 0,
                .margin_top = mt,
                .margin_right = margin_h_extra,
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
                .margin_left = margin_h_extra,
            },
        };
    }

    /// #210/#238 — preferred_scale 변경 적용. 두 scale source 의 단일 진입점:
    /// `wp_fractional_scale_v1`(KDE) 와 `wl_output` 정수 scale fallback(GNOME
    /// mutter). new_scale 은 /120 단위(120=1.0x, 240=2.0x). renderer scale 갱신
    /// + (layer 면) layout 재송신 + grid 재계산 + redraw 로 폰트·탭바·전체 chrome
    /// 을 동기 반영. xdg(GNOME)는 layer 재송신 대신 configure 가 viewport/size 를
    /// 새 scale 로 맞춘다 — wl_output scale 은 초기 bind roundtrip 에서 첫 surface
    /// configure *이전* 에 도착하므로 첫 frame 부터 올바른 크기.
    fn applyScaleChange(self: *Client, new_scale: u32, source: []const u8) !void {
        if (new_scale == 0 or new_scale == self.preferred_scale) return;
        self.preferred_scale = new_scale;
        log.appendLineVerbose("wayland", "scale preferred={d}/120 (≈{d}.{d:0>2}x) source={s}", .{
            new_scale,
            new_scale / 120,
            (new_scale * 100 / 120) % 100,
            source,
        });
        // renderer scale apply — paint 가 1x layout 그리면 큰 buffer 안 작은
        // content (#210). 실패해도 default scale 로 진행.
        const renderer_scale_applied = blk: {
            self.renderer.applyScale(
                self.allocator,
                self.config,
                new_scale,
                fractional_scale_denominator,
            ) catch |err| {
                log.appendLine("wayland", "renderer applyScale failed: {s} — keeping default scale", .{@errorName(err)});
                break :blk false;
            };
            break :blk true;
        };
        // #277 S2-4 — 폰트를 새 크기로 다시 raster 했으므로 GL atlas 의 캐시는
        // 이제 이전 크기의 그림을 가리킨다. 비우지 않으면 scale 이 바뀐 뒤에도
        // 작은 글리프가 계속 나온다 (캐시 키는 codepoint / glyph_index 라 크기를
        // 구분하지 않는다).
        if (renderer_scale_applied) {
            if (self.gl_atlas_store) |*atlas| atlas.invalidate();
        }
        // dialog surface가 map된 뒤 preferred_scale이 도착할 수 있다. font만
        // 바꾸고 1x 요청 폭을 유지하면 본문이 불필요하게 더 wrap되므로 dialog
        // role의 size/margin도 같은 scale에서 다시 요청한다 (#306).
        // #368 — dialog 가 떠 있는 동안 scale 이 바뀌면 `applyScale` 이 dialog 폰트를
        // 버린다 (지연 생성 정책). 그 상태로 다시 그리면 탭 폰트로 떨어지므로, 열려
        // 있을 때만 즉시 새 scale 로 다시 만든다.
        if (renderer_scale_applied and self.dialog.surface_id != 0) {
            self.renderer.ensureDialogFonts(self.allocator);
        }
        if (renderer_scale_applied and self.dialog.surface_id != 0) {
            try self.sendDialogSurfaceLayout(source);
        }
        // layer surface 재송신 + grid 재계산. layer 없으면(xdg/GNOME) skip —
        // configure 가 viewport/size 처리. boot 중 dialog 가 main 이전이면 main skip.
        if (self.layer_surface_id != 0) {
            // boot 중 preferred_scale 도착이면 여기서 실제 layout 이 나간다. 뒤이어
            // settleInitialLayout 도 한 번 더 보내지만 double-buffered commit 이라
            // idempotent (#336).
            try self.sendLayerSurfaceLayout(false);
        }
        if (self.session != null) try self.ensureSessionGrid();
        self.requestRedraw();
    }

    /// L8-β / #295 — wl_output 의 mode (current flag) / scale 처리. geometry /
    /// done / transform 은 미사용(일반 monitor default 0 가정).
    /// #295: 이벤트는 해당 output 의 slot 에 기록하고, 그 output 이 현재 기준
    /// (`basisOutputObjectId`) 일 때만 screen dims / 앱 scale 에 반영.
    /// #238 — `wl_output.scale`(정수) 는 `wp_fractional_scale_v1` 미advertise 환경
    /// (GNOME mutter / Cinnamon muffin) 의 scale source fallback. fractional manager
    /// 가 advertise 된 환경(KDE)은 그쪽이 우선이라 wl_output scale 을 무시한다.
    fn handleOutputEvent(self: *Client, slot: *OutputSlot, opcode: u16, payload: []const u8) !void {
        const is_basis = slot.object_id == self.basisOutputObjectId();
        switch (opcode) {
            wl_output_event_mode => {
                if (payload.len < 16) return;
                const flags = readU32(payload[0..4]);
                if ((flags & wl_output_mode_flag_current) == 0) return;
                slot.width = readI32(payload[4..8]);
                slot.height = readI32(payload[8..12]);
                if (is_basis) {
                    self.screen_width = slot.width;
                    self.screen_height = slot.height;
                }
                log.appendLineVerbose("wayland", "output mode object_id={} width={} height={} refresh={} basis={}", .{
                    slot.object_id,
                    slot.width,
                    slot.height,
                    readI32(payload[12..16]),
                    is_basis,
                });
            },
            wl_output_event_scale => {
                if (payload.len < 4) return;
                const factor = readI32(payload[0..4]);
                if (factor < 1) return;
                slot.scale = factor;
                // fractional manager 가 있으면 그쪽이 source of truth → 무시.
                if (self.fractional_scale_manager_id != 0) return;
                if (!is_basis) return;
                const new_scale: u32 = @as(u32, @intCast(factor)) * fractional_scale_denominator;
                try self.applyScaleChange(new_scale, "wl_output");
            },
            // geometry / done / transform 은 미사용.
            else => {},
        }
    }

    /// #295 — entered 집합에서 basis 로 쓸 output 을 안정적으로 고른다. batch 종료
    /// 후 drainSurfaceOutputs 가 호출. 규칙 (진동 방지 우선):
    ///   1. 현재 basis 가 여전히 걸쳐있으면 그대로 유지 (surface 가 인접 output
    ///      경계에 flush 라 양쪽에 걸쳐도 basis 를 안 뒤집는다).
    ///   2. 아니면 build 기준(첫 bind output_id)이 걸쳐있으면 그것.
    ///   3. 아니면 걸쳐있는 첫 output.
    ///   4. 아무 데도 안 걸쳐있으면 null → 호출측이 현재 basis 유지.
    fn pickBasisOutput(self: *Client) ?u32 {
        if (self.current_output_object_id != 0) {
            if (self.findOutputSlot(.{ .object_id = self.current_output_object_id })) |s| {
                if (s.entered) return self.current_output_object_id;
            }
        }
        if (self.output_id != 0) {
            if (self.findOutputSlot(.{ .object_id = self.output_id })) |s| {
                if (s.entered) return self.output_id;
            }
        }
        for (&self.outputs) |*s| {
            if (s.object_id != 0 and s.entered) return s.object_id;
        }
        return null;
    }

    /// #295 — dispatch batch 종료 후 entered 집합을 보고 basis 를 재선택 (main loop
    /// drain). enter/leave 마다 즉시 반응하지 않는 이유는 위 field 주석 참고 —
    /// sway/wlroots 의 양쪽-enter 진동을 막는 핵심.
    fn drainSurfaceOutputs(self: *Client) !void {
        if (!self.surface_outputs_dirty) return;
        self.surface_outputs_dirty = false;
        const basis = self.pickBasisOutput();
        var entered_buf: [64]u8 = undefined;
        var w: usize = 0;
        for (&self.outputs) |*s| {
            if (s.object_id != 0 and s.entered) {
                if (std.fmt.bufPrint(entered_buf[w..], "{} ", .{s.object_id})) |written| {
                    w += written.len;
                } else |_| {}
            }
        }
        log.appendLineVerbose("wayland", "drainSurfaceOutputs entered=[{s}] current={} picked={} (#295)", .{
            entered_buf[0..w], self.current_output_object_id, basis orelse 0,
        });
        const chosen = basis orelse return; // 안 걸침 → 현 basis 유지
        if (chosen == self.current_output_object_id) return; // 변화 없음
        try self.applyBasisOutput(chosen);
    }

    /// #295 — 선택된 basis output 으로 전환. compositor 는 output=NULL layer surface
    /// 를 focused output 에 놓으므로 소환된 모니터가 계산 기준과 달라질 수 있고,
    /// wl_surface.enter 집합이 그 유일한 신호. 전환 후 mode/scale 이 기존 기준과
    /// 다르면 screen dims + scale 재동기 + layout 재송신/재생성 + grid 재계산 —
    /// mixed-monitor 크기/선명도 증상의 해소 지점.
    fn applyBasisOutput(self: *Client, output_object_id: u32) !void {
        const slot = self.findOutputSlot(.{ .object_id = output_object_id }) orelse {
            log.appendLineVerbose("wayland", "basis output unknown object_id={} — ignored (#295)", .{output_object_id});
            return;
        };
        self.current_output_object_id = output_object_id;
        // mode event 이전이면 보류 — 도착 시 handleOutputEvent 가 basis 로 반영.
        if (slot.width <= 0 or slot.height <= 0) return;
        const dims_changed = slot.width != self.screen_width or slot.height != self.screen_height;
        self.screen_width = slot.width;
        self.screen_height = slot.height;
        if (dims_changed) {
            // #351 — work-area 가 바뀌었으니 latch 를 버린다. 다음 초기 안전 commit 의
            // configure 가 정확한 값으로 다시 채운다 — mapped 면 아래에서 예약하는
            // seamless 재생성이, hidden 중 output 소멸이면 `closed` 핸들러의
            // destroyShellObjects → 다음 show 의 createShellObjects 가 보낸다.
            // 그 사이 layout 은 physical 추정 fallback 을 쓴다 (변환 오차 ±1 — #351
            // 이전 동작). 재생성 없이 같은 output 의 mode 만 바뀌는 경로는 다음 재생성
            // 까지 그 fallback 에 머문다 (remapShellObjects 는 재latch 하지 않는다 —
            // 보이는 상태에서 초기 안전 commit 을 보내면 창이 한 frame 동안 work-area
            // 전체로 보이므로). 드문 경로라 ±1 을 감수한다.
            self.screen_logical_w = 0;
            self.screen_logical_h = 0;
        }
        log.appendLineVerbose("wayland", "basis output object_id={} {}x{} scale={} dims_changed={} (#295)", .{
            output_object_id,
            slot.width,
            slot.height,
            slot.scale,
            dims_changed,
        });
        // scale 동기 — fractional manager 있으면 per-surface `preferred_scale` 이
        // source of truth (output 이동 시 compositor 가 새 preferred_scale 을
        // 발신하고 그 handler 가 relayout). 없으면 이 output 의 정수 scale 적용.
        // 아래 재생성보다 먼저 — 재생성 경로가 새 scale 로 layout 을 계산하도록.
        var scale_applied = false;
        if (self.fractional_scale_manager_id == 0) {
            const new_scale: u32 = @as(u32, @intCast(@max(slot.scale, 1))) * fractional_scale_denominator;
            if (new_scale != self.preferred_scale) {
                // applyScaleChange 가 renderer scale + layout 재송신 + grid 재계산
                // + redraw 까지 처리.
                try self.applyScaleChange(new_scale, "wl_output/enter");
                scale_applied = true;
            }
        }
        if (!dims_changed) return;
        // mapped layer surface 의 margin-only 재송신은 sway 1.7 (wlroots 0.15)
        // 이 다음 전역 arrange 까지 시각 반영하지 않는다 (실측: 새 configure 는
        // 보내면서 surface box 는 안 옮김 — output 설정 no-op 재적용으로 강제
        // arrange 하면 즉시 반영됨). 그래서 in-place 재송신 대신 #241 의
        // swapMainSurfaceSeamless (create-before-destroy, 깜빡임 없음) 재생성을
        // 예약한다 — 신규 map 은 모든 compositor 가 즉시 정확히 배치.
        // (직접 호출 금지 — 내부 configure pump 가 reentrant. main loop 의
        // drainOutputRecreate 가 dispatch 밖에서 처리, #241 과 동일.)
        if (self.layer_surface_id != 0 and self.mapped and !self.surface_hidden) {
            self.pending_output_recreate = true;
            log.appendLineVerbose("wayland", "basis output changed while mapped — seamless recreate scheduled (#295)", .{});
            return;
        }
        // 미mapped (첫 configure 전) / xdg 경로 — in-place 재계산으로 충분.
        if (scale_applied) return; // applyScaleChange 가 이미 전부 처리.
        if (self.layer_surface_id != 0) try self.sendLayerSurfaceLayout(false);
        if (self.session != null) try self.ensureSessionGrid();
        self.requestRedraw();
    }

    /// #336 — 초기 안전 commit(createLayerSurface 의 4-edge span) 후 실제 config
    /// layout 을 보내기 전에, compositor 의 preferred_scale 이 도착하길 최대 100ms
    /// 대기한다. 이 대기가 없으면 첫 실제 layout 이 scale=1.0 로 계산돼 낮은
    /// height_percent + fractional 환경에서 유효 높이가 음수가 되고 surface 가 closed 된다.
    ///
    /// wp_fractional_scale_manager_v1 미advertise 환경(GNOME xdg / non-fractional
    /// wlroots)은 preferred_scale 이 default 120(1.0x, no-op 변환)으로 이미 정확하니
    /// 대기 없이 즉시 실제 layout 을 보낸다. (KWin 은 layer role + 첫 commit 이후에야
    /// preferred_scale 을 보내므로 "commit 없이 기다리기"는 불가 — 초기 안전 commit 이
    /// output 배정을 먼저 트리거해야 한다.)
    ///
    /// 실측(#336 로그): preferred_scale 은 첫 commit 과 같은 ms 에 도착 — 실제 대기는
    /// roundtrip 수 ms 수준이고 100ms 는 안전 상한. 상한 초과 시엔 현재 scale 로 실제
    /// layout 을 보내고(fallback), map 전 closed 는 bringUpInitialSurface 가 destroy+재생성.
    fn settleInitialLayout(self: *Client) !void {
        if (self.layer_surface_id == 0) return; // xdg-shell(GNOME) 경로 — 무관.
        if (self.fractional_scale_manager_id == 0) {
            // fractional 미advertise — scale 확정 불필요, 즉시 실제 layout.
            try self.sendLayerSurfaceLayout(false);
            return;
        }
        // #336 — preferred_scale 도착은 실측 <0.14ms(첫 commit 과 사실상 동시 — KWin
        // Plasma 6, 1.7x fractional 에서 7/7 회 28~137us)라 정상 boot 는 첫 poll 에서
        // 즉시 확정된다. 상한은 event 가 아예 안 오는 극단에서만 걸리고 그땐 (b) 재생성
        // 이 받는다. 실측 근거로 10ms(도착의 ~70배 여유). poll 도 2ms 로 짧게 — 상한이
        // 기본 frame poll(16ms)보다 작아 극단에서 첫 poll 한 번이 상한을 넘겨버리지 않도록.
        const settle_budget_ns: u64 = 10 * std.time.ns_per_ms;
        const settle_poll_ms: i32 = 2;
        var timer = try std.time.Timer.start();
        while (!self.preferred_scale_received and !self.init_layer_closed and timer.read() < settle_budget_ns) {
            try self.pollAndDispatch(settle_poll_ms);
        }
        if (self.init_layer_closed) return; // boot 루프가 destroy+재생성으로 처리.
        if (!self.preferred_scale_received) {
            log.appendLine("wayland", "preferred_scale not received within 10ms — layout at current scale={d}/120 (#336)", .{self.preferred_scale});
        }
        // 도착 케이스: applyScaleChange 가 이미 실제 layout 을 보냈을 수 있으나(값이
        // 바뀐 경우), 120→120 no-op 이면 미송신이므로 여기서 보장 송신(idempotent).
        //
        // #351 — 초기 안전 commit 의 configure 가 아직 안 왔으면 이 송신은 보류되고,
        // 뒤이은 waitForConfigure 가 그 configure 를 받아 work-area 를 latch 한 뒤
        // continuation 이 보낸다. 실측(KWin Plasma 6): 그 configure 는 초기 안전
        // commit 과 거의 동시에 socket 에 도착해 있으므로 boot 지연이 없다 — 기존에
        // 관측된 63ms 간격은 compositor 지연이 아니라 그 사이의 renderer.applyScale
        // (font chain 재빌드) 이 socket 을 안 읽은 시간이었다.
        try self.sendLayerSurfaceLayout(false);
    }

    fn waitForConfigure(self: *Client) !void {
        while (!self.configured) {
            // #336 — map 전 closed 는 boot 재시도 신호. quit(pending_quit_request)이
            // 아니라 여기서 빠져나가 bringUpInitialSurface 가 destroy+재생성한다.
            if (self.init_layer_closed) return error.InitLayerClosed;
            try self.readAndDispatch();
        }
    }

    /// #336 — boot 첫 표시 시퀀스. createShellObjects 의 초기 안전 commit(4-edge
    /// span) → preferred_scale 대기(settleInitialLayout) → 실제 config layout →
    /// configure 를 한 세트로 돌린다. 첫 frame(map) 전에 layer-surface 가 closed
    /// 되면(첫 실제 layout 이 잘못 나가 compositor 가 거부한 극단) quit 이 아니라
    /// destroy + 재생성으로 재시도하고, 상한(3회)을 넘기면 정직하게 안내(showError,
    /// host overlay 또는 stderr fallback) 후 실패를 반환한다. (a)가 정상 동작하면
    /// 재시도 분기는 거의 타지 않는 순수 안전망이다.
    fn bringUpInitialSurface(self: *Client) !void {
        const max_attempts: u8 = 3;
        var attempt: u8 = 0;
        while (true) {
            attempt += 1;
            try self.createShellObjects();
            self.logBootElapsed("createShellObjects");
            try self.settleInitialLayout();
            self.waitForConfigure() catch |err| switch (err) {
                error.InitLayerClosed => {
                    log.appendLine("input", "main layer-surface closed before first map (attempt {d}/{d}) — destroy + recreate, NOT quit (#336)", .{ attempt, max_attempts });
                    try self.destroyShellObjects();
                    self.init_layer_closed = false;
                    if (attempt >= max_attempts) {
                        dialog_mod.showError(messages.startup_layer_unmappable_title, messages.startup_layer_unmappable_msg);
                        return error.MainSurfaceUnmappable;
                    }
                    continue;
                },
                else => return err,
            };
            return;
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

    /// dialog surface 요청은 계산한 physical content보다 작아지면 마지막 glyph가
    /// 잘릴 수 있으므로 positive ceil을 쓴다. configure의 logical→physical floor와
    /// 짝을 이뤄 요청한 buffer 크기를 보존한다 (#306).
    fn physicalToLogicalCeil(self: *const Client, physical: i32) i32 {
        if (physical <= 0) return 0;
        const num: i64 = @intCast(self.preferred_scale);
        const den: i64 = fractional_scale_denominator;
        const value: i64 = @intCast(physical);
        return @intCast(@divFloor(value * den + num - 1, num));
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
        return .{
            // #350 — 열 수는 공통 `ui_metrics.terminalCols` (좌우 padding +
            // scrollbar 자리 차감). 이전에는 scrollbar 를 안 빼서 마지막 열이
            // scrollbar 와 겹쳤다.
            .cols = ui_metrics.terminalCols(self.window_width, pad, self.renderer.scrollbarWPx(), cw),
            // #352 — 행 수도 공통 `ui_metrics.terminalRows`. L12-α — 상단 tab bar
            // 영역만큼 grid height 축소. 단일 탭이면 `effectiveTabBarHeightPx` 가
            // 0 → 탭바 자리 안 띄움 (#127, mac / Win 동등).
            .rows = ui_metrics.terminalRows(self.window_height, tab_bar_h, pad, ch),
        };
    }

    /// 현재 세션 탭 수 기준 탭바 픽셀 높이. `Renderer.tabBarHeightPx(count)`
    /// 가 count < 2 시 0 반환 (#127, mac `tabBarHeightPx` / Win
    /// `effectiveTabBarHeight` 동등). 세션 미초기화면 count = 0 으로 자연 0.
    fn effectiveTabBarHeightPx(self: *const Client) i32 {
        const count: usize = if (self.session) |*s| s.count() else 0;
        return self.renderer.tabBarHeightPx(count);
    }

    /// #329 — scrollbar는 단일 탭의 항상-visible control strip과도 겹치지
    /// 않아야 한다. Terminal grid top과 분리된 scrollbar 전용 inset.
    fn scrollbarTopInsetPx(self: *const Client) i32 {
        const session = if (self.session) |*s| s else return 0;
        return if (session.count() > 0) self.renderer.chromeHeightPx() else 0;
    }

    /// #205 — boot phase elapsed log. `boot_timer` 가 `runBaselineWindow` 진입에
    /// start 됐을 때만 동작. 사용자 *체감* 1-2 sec startup latency 가 어느
    /// phase 에 모이는지 확정 위한 진단.
    fn logBootElapsed(self: *Client, phase: []const u8) void {
        if (self.boot_timer) |*t| {
            const elapsed_ms = t.read() / std.time.ns_per_ms;
            log.appendLineVerbose("startup", "boot phase={s} elapsed={d}ms (#205)", .{ phase, elapsed_ms });
        }
    }

    /// #205 — show phase elapsed log. `show_timer` 는 매 `handleActivatedToggle`
    /// show 분기 시작에 reset. hotkey activation → first frame 까지.
    fn logShowElapsed(self: *Client, phase: []const u8) void {
        if (self.show_timer) |*t| {
            const elapsed_ms = t.read() / std.time.ns_per_ms;
            log.appendLineVerbose("startup", "show phase={s} elapsed={d}ms (#205)", .{ phase, elapsed_ms });
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
        // #160 — onrender(프레임 tick 전체) 계측. Windows app_controller 동등. paint 못
        // 한 frame(awaiting_frame / not configured 등)은 skip(extra) 으로 카운트.
        const onrender_t0 = perf.now();
        var painted_frame = false;
        defer {
            perf.addTimed(&perf.onrender, onrender_t0);
            if (!painted_frame) perf.incExtra(&perf.onrender);
        }
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
                    // #277 — 그리지 못했으면 attach 하지 않는다. GPU 경로에서
                    // 매핑이 실패한 경우인데, `disableGpu` 가 이미 걸려 있어
                    // 다음 frame 은 software buffer 를 새로 만들어 정상 복귀한다.
                    if (!self.paintIntoBuffer(buffer)) {
                        self.disableGpu("dma-buf 재매핑 실패");
                        return false;
                    }
                    self.logShowElapsed("paint done (reuse)");
                    try self.attachAndCommit(buffer.*);
                    self.logShowElapsed("commit done (reuse)");
                    buffer.released = false;
                    self.mapped = true;
                    painted_frame = true;
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
        if (!self.paintIntoBuffer(&buffer)) {
            self.destroyBufferObject(buffer.id);
            buffer.deinit();
            self.disableGpu("dma-buf 매핑 실패");
            return false;
        }
        self.logShowElapsed("paint done (new buf)");
        try self.retireActiveBuffer();
        try self.attachAndCommit(buffer);
        self.logShowElapsed("commit done (new buf)");
        self.active_buffer = buffer;
        self.mapped = true;
        painted_frame = true;
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

    fn takeReusableBuffer(self: *Client, width: i32, height: i32) ?SurfaceBuffer {
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

    /// #277 — GPU (dma-buf) 경로를 쓸 수 있으면 준비한다.
    ///
    /// 실패는 전부 **조용한 software fallback** 이다. 어느 한 단계라도 안 되면
    /// `gpu_enabled` 를 false 로 두고 기존 `wl_shm` 경로로 돈다 — 두 경로의 렌더
    /// 결과가 같으므로 사용자에게 보이는 차이는 없고, 어느 쪽인지는 로그에 남는다.
    /// 대상 환경: NVIDIA proprietary · llvmpipe · VM · render node 없는 시스템.
    fn initGpuIfAvailable(self: *Client) void {
        // 진단용 탈출구. GPU 경로를 강제로 끈다 (`TILDAZ_DISABLE_GPU=1`).
        // 두 가지 용도가 있다 — (1) 사용자 문제 보고에서 렌더 경로를 원인
        // 후보에서 배제하고 재현, (2) #277 의 "픽셀 동일" 검증에서 **같은
        // 바이너리로** software / GPU 두 경로를 각각 찍어 비교.
        if (posix.getenv("TILDAZ_DISABLE_GPU")) |value| {
            if (!std.mem.eql(u8, value, "0")) {
                log.appendLine("gpu", "software 경로 — TILDAZ_DISABLE_GPU 로 비활성화", .{});
                return;
            }
        }
        if (self.linux_dmabuf_id == 0) {
            log.appendLineVerbose("gpu", "software 경로 — compositor 가 zwp_linux_dmabuf_v1 을 노출하지 않음", .{});
            return;
        }
        var api = gbm.Api.load() catch |err| {
            log.appendLineVerbose("gpu", "software 경로 — libgbm 로드 실패 ({s})", .{@errorName(err)});
            return;
        };
        const drm_fd = gbm.openRenderNode() orelse {
            log.appendLineVerbose("gpu", "software 경로 — DRM render node 를 열 수 없음", .{});
            api.deinit();
            return;
        };
        const device = api.createDevice(drm_fd) orelse {
            log.appendLineVerbose("gpu", "software 경로 — gbm device 생성 실패", .{});
            posix.close(drm_fd);
            api.deinit();
            return;
        };
        self.gpu = .{ .api = api, .device = device, .drm_fd = drm_fd };

        // GLES 렌더러가 이 환경에서 가능한지 먼저 판정한다 (로그용 — S2 준비).
        // LINEAR 여부와 무관하게 돌린다: NVIDIA 처럼 **지금 경로는 불가한데 GLES
        // 는 가능한** 환경이 실재하고, 그 사실이 로그에 남아야 실기 없이도 데이터가
        // 쌓인다.
        // 창 크기를 아직 모르므로 작은 크기로 판정한다 — 이 단계의 목적은 "이
        // 환경에서 GLES 렌더가 가능한가" 를 로그에 남기는 것이다. 실제로 쓸
        // modifier 는 첫 buffer 를 만들 때 그 크기로 다시 고른다 (#367).
        self.negotiateGlModifier(256, 256);

        // #277 S2 — GL 로 그린다 (기본). 켜지면 CPU 매핑이 필요 없으므로 LINEAR
        // 제약이 사라진다 — NVIDIA 처럼 LINEAR 를 공표하지 않는 환경이 이 경로로만
        // 열린다. 실패하면 아래 LINEAR 검사로 내려가 S1 또는 software 로 떨어진다.
        if (self.gl_modifier != null and glRenderRequested()) {
            // context 는 협상이 이미 열어 뒀다 (`negotiateGlModifier`).
            if (self.gl_context) |*ctx| {
                // 셰이더 / 정점 버퍼 / atlas 는 context 와 수명을 같이 한다. 하나라도
                // 실패하면 GL 경로를 켜지 않는다 — 반만 그리면 화면이 깨진다.
                const gl_api = &ctx.api;
                if (gl_rects.Batch.create(gl_api)) |batch| {
                    self.gl_batch = batch;
                    if (gl_text.Batch.create(gl_api)) |text_batch| {
                        self.gl_text_batch = text_batch;
                        self.gl_atlas_store = gl_atlas.Atlas.create(gl_api, self.allocator);
                        if (gpuTimingRequested()) {
                            software_terminal.timing_enabled = true;
                            self.gpu_timer = egl.GpuTimer.create(gl_api);
                            log.appendLine("gpu", "GPU 시간 계측 {s} (TILDAZ_GPU_TIMING)", .{
                                if (self.gpu_timer != null) @as([]const u8, "켬") else "불가 — GL_EXT_disjoint_timer_query 없음",
                            });
                        }
                        self.gl_render_enabled = true;
                        self.gpu_enabled = true;
                        log.appendLine("gpu", "GL 렌더 활성 — modifier=0x{x:0>16}", .{self.gl_modifier.?});
                        return;
                    }
                    self.gl_batch.?.deinit(gl_api, self.allocator);
                    self.gl_batch = null;
                }
                log.appendLine("gpu", "셰이더 준비 실패 — GL 없이 기존 경로로", .{});
            }
        }
        // 여기까지 왔으면 GL 을 쓰지 않는다 — 협상용 context 를 놓는다.
        self.releaseNegotiationContext();

        // 현재 그리기는 CPU 가 하므로 `gbm_bo_map` 이 되는 LINEAR 가 필요하다.
        // 없으면 GPU 자원을 놓고 software 로 돈다 (아직 쓸 데가 없으므로).
        if (!self.dmabuf_linear_supported) {
            log.appendLineVerbose("gpu", "software 경로 — ARGB8888 + LINEAR modifier 미지원 (CPU 가 dma-buf 에 그려야 함)", .{});
            if (self.gpu) |*gpu| {
                gpu.deinit();
                self.gpu = null;
            }
            return;
        }
        self.gpu_enabled = true;
    }

    /// #277 — GLES 렌더러가 쓸 수 있는 modifier 를 고른다.
    ///
    /// compositor 가 공표한 후보를 "할당 → EGLImage import → FBO complete" 까지
    /// 시도해 **처음 통과한 것**을 채택한다. 고정 규칙으로는 벤더를 못 덮는다는
    /// 것이 실측으로 확인됐다:
    ///
    ///   - AMD (Radeon 780M / Mesa): DCC(압축) modifier 는 할당은 되지만 import 가
    ///     `EGL_BAD_MATCH`. LINEAR 는 정상.
    ///   - NVIDIA (RTX 3060 Ti / 610.43.03): LINEAR 는 공표조차 안 하고, 억지로
    ///     할당해도 FBO 가 불완전. tiled 12 종은 전부 정상.
    ///
    /// 두 제약이 정반대라 "LINEAR 를 쓴다" 도 "GBM 이 고르게 둔다" 도 한쪽에서
    /// 깨진다. 실제로 시도해 보는 것만이 양쪽을 덮는다.
    ///
    /// 지금은 **판정과 로그만** 한다 — 그리기는 아직 CPU 라 이 값이 실제 할당에
    /// 쓰이지 않는다. 그래도 켜 두는 이유는, 사용자 로그에 "이 환경에서 GLES
    /// 렌더러가 가능한가" 가 남아 실기 없이도 데이터가 쌓이기 때문이다.
    /// #277 S2-6 — GL 렌더가 **기본**이다 (2026-08-02 사용자 결정). 되돌리는 길을
    /// 두 단계로 남긴다:
    ///
    ///   `TILDAZ_GL_RENDER=0`   GPU buffer 는 쓰되 CPU 가 그린다 (S1)
    ///   `TILDAZ_DISABLE_GPU=1` GPU 를 아예 안 쓴다 (software `wl_shm`)
    ///
    /// 둘을 나눠 둔 이유는 진단 축이 다르기 때문이다 — 전자는 "GL 래스터가 문제인가",
    /// 후자는 "dma-buf 배관이 문제인가" 를 가른다. 어느 쪽이든 화면은 나온다.
    /// #369 — `TILDAZ_GPU_TIMING=1` 이면 프레임 GPU 시간을 잰다.
    fn gpuTimingRequested() bool {
        const value = posix.getenv("TILDAZ_GPU_TIMING") orelse return false;
        return !std.mem.eql(u8, value, "0");
    }

    /// #369 — `TILDAZ_GL_MODIFIER=<hex>` 로 modifier 를 고정한다 (A/B 측정용).
    /// 협상 결과를 무시하므로 **진단 전용**이다 — 그 modifier 로 할당·import 가
    /// 안 되면 평소 경로대로 software 로 떨어진다.
    fn forcedModifier() ?u64 {
        const value = posix.getenv("TILDAZ_GL_MODIFIER") orelse return null;
        const trimmed = if (std.mem.startsWith(u8, value, "0x")) value[2..] else value;
        return std.fmt.parseInt(u64, trimmed, 16) catch null;
    }

    fn glRenderRequested() bool {
        const value = posix.getenv("TILDAZ_GL_RENDER") orelse return true;
        return !std.mem.eql(u8, value, "0");
    }

    /// wayland array 인자에서 `dev_t` (8 byte) 를 읽는다. 앞 4 byte 는 배열 크기다.
    fn readDevT(payload: []const u8) u64 {
        if (payload.len < 12) return 0;
        const size = readU32(payload[0..4]);
        if (size < 8) return 0;
        return (@as(u64, readU32(payload[8..12])) << 32) | @as(u64, readU32(payload[4..8]));
    }

    /// `tranche_formats` — 표 index 배열을 modifier 로 풀어 현재 tranche 에 모은다.
    /// 표가 없으면 (format_table 이 안 왔거나 mmap 실패) 아무것도 못 한다.
    fn collectTrancheFormats(self: *Client, payload: []const u8) void {
        const table = self.dmabuf_format_table orelse return;
        if (payload.len < 4) return;
        const size: usize = @intCast(readU32(payload[0..4]));
        const body = payload[4..];
        const count = @min(size, body.len) / 2;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const index: usize = @as(usize, body[i * 2]) | (@as(usize, body[i * 2 + 1]) << 8);
            const entry = index * 16;
            if (entry + 16 > table.len) continue;
            const format = std.mem.readInt(u32, table[entry..][0..4], .little);
            if (format != gbm.FORMAT_ARGB8888) continue;
            const modifier = std.mem.readInt(u64, table[entry + 8 ..][0..8], .little);
            if (modifier == gbm.MOD_INVALID) continue; // 명시 modifier 를 넘길 수 없다.
            if (self.dmabuf_tranche_count >= max_dmabuf_mods) return;
            self.dmabuf_tranche_mods[self.dmabuf_tranche_count] = modifier;
            self.dmabuf_tranche_count += 1;
        }
    }

    /// `tranche_done` — 모인 modifier 를 후보 목록 **뒤에** 붙인다. tranche 자체가
    /// 선호 내림차순이므로 순서를 그대로 보존하면 된다.
    ///
    /// 다른 device 를 겨냥한 tranche 는 건너뛴다 — 우리는 한 device 에만 할당한다.
    /// tranche 안에서는 모든 항목의 선호가 같으므로 (프로토콜 명시) 순서를 그대로
    /// 두고, **안쪽 순위는 협상이 드라이버에게 맡긴다** (#367) — 드라이버는 자기
    /// tiling·압축 순위를 안다.
    fn flushDmabufTranche(self: *Client) void {
        defer {
            self.dmabuf_tranche_count = 0;
            self.dmabuf_tranche_scanout = false;
            self.dmabuf_tranche_index += 1;
        }
        if (self.dmabuf_main_device != 0 and self.dmabuf_tranche_device != self.dmabuf_main_device) {
            log.appendLineVerbose("gpu", "dmabuf tranche {d} 건너뜀 — 다른 device (0x{x} != 0x{x})", .{
                self.dmabuf_tranche_index,
                self.dmabuf_tranche_device,
                self.dmabuf_main_device,
            });
            return;
        }
        for (self.dmabuf_tranche_mods[0..self.dmabuf_tranche_count]) |modifier| {
            if (modifier == gbm.MOD_LINEAR) self.dmabuf_linear_supported = true;
            if (self.dmabuf_mod_count >= max_dmabuf_mods) break;
            self.dmabuf_mods[self.dmabuf_mod_count] = modifier;
            self.dmabuf_mod_count += 1;
        }
        // 경계를 남긴다 — 협상이 이 묶음 단위로 드라이버에게 고르게 한다.
        if (self.dmabuf_tranche_count > 0 and self.dmabuf_tranche_end_count < max_dmabuf_tranches) {
            self.dmabuf_tranche_ends[self.dmabuf_tranche_end_count] = self.dmabuf_mod_count;
            self.dmabuf_tranche_end_count += 1;
        }
        log.appendLineVerbose("gpu", "dmabuf tranche {d}: ARGB8888 {d} 종{s}", .{
            self.dmabuf_tranche_index,
            self.dmabuf_tranche_count,
            if (self.dmabuf_tranche_scanout) @as([]const u8, " (scanout)") else "",
        });
    }

    /// `done` — 표는 더 필요 없다. 결과를 한 줄로 남긴다.
    fn finishDmabufFeedback(self: *Client) void {
        self.dmabuf_mods_ordered = self.dmabuf_mod_count > 0;
        if (self.dmabuf_format_table) |table| {
            posix.munmap(@constCast(table));
            self.dmabuf_format_table = null;
        }
        log.appendLine("gpu", "dmabuf feedback — main_device=0x{x} tranche {d} 개, ARGB8888 후보 {d} 종 (선호 순)", .{
            self.dmabuf_main_device,
            self.dmabuf_tranche_index,
            self.dmabuf_mod_count,
        });
    }

    /// 협상에 쓴 EGL context 를 **버리지 않고 `self.gl_context` 에 남긴다.** 호출처가
    /// GL 을 켜면 그대로 쓰고, 안 켜면 정리한다.
    ///
    /// 이유는 실측이다 — NVIDIA (RTX 3060 Ti / 610.43.03) 는 context 생성이 비싸서,
    /// 협상용과 렌더용을 따로 만들면 부팅이 **120 ms** 더 걸렸다 (AMD · Intel 은
    /// 30 ms 안쪽이라 안 드러났다).
    fn negotiateGlModifier(self: *Client, probe_w: u32, probe_h: u32) void {
        const gpu = if (self.gpu) |*g| g else return;
        if (self.dmabuf_mod_count == 0) return;
        self.gl_modifier = null;

        // 이미 열어 둔 context 가 있으면 그것을 쓴다 (재협상). 없으면 만든다.
        var owned_ctx: ?egl.Context = null;
        if (self.gl_context == null) {
            owned_ctx = egl.Context.create(gpu.device) orelse {
                log.appendLine("gpu", "GLES 렌더러 불가 — EGL context 생성 실패", .{});
                return;
            };
            self.gl_context = owned_ctx;
        }
        var ctx = self.gl_context.?;

        // v3 평면 목록에는 tranche 가 없다 — 전체를 한 묶음으로 본다. 그러면 아래
        // 루프가 그 묶음 안에서 드라이버에게 고르게 하므로, feedback 이 없는
        // compositor 에서도 순위 판단이 드라이버 몫이 된다.
        if (self.dmabuf_tranche_end_count == 0 and self.dmabuf_mod_count > 0) {
            self.dmabuf_tranche_ends[0] = self.dmabuf_mod_count;
            self.dmabuf_tranche_end_count = 1;
        }

        // **시험 크기가 중요하다.** 압축 modifier (AMD DCC / Intel CCS) 는 표면 크기와
        // 정렬에 제약이 있어, 작은 시험 크기에서 되던 것이 실제 창 크기에서 할당
        // 실패할 수 있다 — AMD 실기에서 256×256 으로 고른 DCC 가 실제 창에서
        // `gbm_bo_create_with_modifiers` 를 실패시켜 software 로 떨어졌다 (#367).
        // 그래서 실제 크기를 아는 시점(첫 buffer 생성)에 다시 부른다.

        // #369 — 진단용 고정. A/B 측정에서 modifier 만 바꿔 같은 워크로드를 돌린다.
        if (forcedModifier()) |forced| {
            const bo = gpu.api.createWithModifier(gpu.device, forced, probe_w, probe_h);
            if (bo) |b| {
                var planes: [gbm.MAX_PLANES]gbm.Plane = undefined;
                if (gpu.api.exportPlanes(b, &planes)) |n| {
                    if (ctx.importAsTarget(planes[0..n], b)) |t| {
                        ctx.destroyTarget(t);
                        self.gl_modifier = forced;
                        self.gl_plane_count = n;
                    }
                    gbm.Api.closePlanes(planes[0..n]);
                }
                gpu.api.destroyBo(b);
            }
            log.appendLine("gpu", "modifier 고정 요청 0x{x:0>16} — {s} (TILDAZ_GL_MODIFIER)", .{
                forced,
                if (self.gl_modifier != null) @as([]const u8, "채택") else "실패, 협상으로",
            });
            if (self.gl_modifier != null) {
                self.gl_context = ctx;
                return;
            }
        }

        // **tranche 단위로 드라이버에게 고르게 하고 검증한다** (#367).
        //
        //   바깥 루프 = tranche 순서  → compositor 가 정한 선호 내림차순
        //   안쪽      = GBM 에 목록 통째로 → 드라이버가 자기 순위로 고른다
        //   그다음    = import + FBO 검증 → 실패하면 그 modifier 를 빼고 재시도
        //
        // 두 선호 원천이 각자 맞는 층에서 작동한다. tranche 안은 프로토콜상 선호가
        // 같아 우리가 순서를 정할 근거가 없고, 드라이버는 Y_TILED > X_TILED 같은
        // 자기 순위를 안다 (Intel 실기에서 우리 규칙은 X_TILED 를 골랐다).
        //
        // 예전에 GBM 위임을 버린 이유는 "AMD 에서 DCC 를 골랐는데 EGL import 가
        // EGL_BAD_MATCH" 였는데, 그건 아래 **검증 후 재시도** 가 흡수한다.
        var pool: [max_dmabuf_mods]u64 = undefined;
        var tranche_start: usize = 0;
        for (self.dmabuf_tranche_ends[0..self.dmabuf_tranche_end_count]) |tranche_end| {
            defer tranche_start = tranche_end;
            if (tranche_end <= tranche_start) continue;
            var pool_len = tranche_end - tranche_start;
            @memcpy(pool[0..pool_len], self.dmabuf_mods[tranche_start..tranche_end]);

            while (pool_len > 0) {
                const bo = gpu.api.createWithModifiers(gpu.device, pool[0..pool_len], probe_w, probe_h) orelse break;
                const chosen = bo.modifier;
                var planes: [gbm.MAX_PLANES]gbm.Plane = undefined;
                const plane_count = gpu.api.exportPlanes(bo, &planes) orelse {
                    gpu.api.destroyBo(bo);
                    break;
                };
                const target = ctx.importAsTarget(planes[0..plane_count], bo);
                gbm.Api.closePlanes(planes[0..plane_count]);
                gpu.api.destroyBo(bo);
                if (target) |t| {
                    ctx.destroyTarget(t);
                    self.gl_modifier = chosen;
                    self.gl_plane_count = plane_count;
                    break;
                }
                // 드라이버가 고른 것을 GL 이 못 받는다 — 빼고 다시 고르게 한다.
                log.appendLineVerbose("gpu", "modifier 0x{x:0>16} (plane {d}) import 실패 — 후보에서 제외", .{ chosen, plane_count });
                var w: usize = 0;
                for (pool[0..pool_len]) |m| {
                    if (m == chosen) continue;
                    pool[w] = m;
                    w += 1;
                }
                if (w == pool_len) break; // 못 지웠다 — 무한 루프 방지
                pool_len = w;
            }
            if (self.gl_modifier != null) break;
        }

        if (self.gl_modifier) |modifier| {
            log.appendLine("gpu", "GLES 렌더러 가능 — modifier=0x{x:0>16}{s} plane={d}{s} renderer={s} version={s}", .{
                modifier,
                if (modifier == gbm.MOD_LINEAR) @as([]const u8, " (LINEAR)") else " (tiled)",
                self.gl_plane_count,
                if (self.dmabuf_mods_ordered) @as([]const u8, " feedback-선호") else " v3-목록",
                ctx.rendererName(),
                ctx.versionName(),
            });
        } else {
            log.appendLine("gpu", "GLES 렌더러 불가 — 공표 modifier {d} 종이 모두 FBO 실패", .{self.dmabuf_mod_count});
        }
        self.gl_context = ctx;
    }

    /// 협상용으로 열어 둔 context 를 쓰지 않기로 했을 때 정리한다.
    fn releaseNegotiationContext(self: *Client) void {
        if (self.gl_render_enabled) return; // 렌더에 쓰는 중이면 건드리지 않는다.
        if (self.gl_context) |*ctx| {
            ctx.deinit();
            self.gl_context = null;
        }
    }

    /// GPU 경로에서 실패했을 때 software 로 되돌린다. 자원(gbm device)은 그대로
    /// 두고 **새 할당만** 멈춘다 — 살아 있는 buffer 의 bo 를 파괴하려면 device 가
    /// 필요해서, 여기서 device 를 없애면 파괴 순서가 위험해진다. 이미 붙어 있는
    /// GPU buffer 는 평소 회수 경로(`released` → `discard…`)로 자연히 빠진다.
    fn disableGpu(self: *Client, reason: []const u8) void {
        if (!self.gpu_enabled) return;
        self.gpu_enabled = false;
        // GL 렌더도 함께 끈다 — dma-buf 없이는 렌더 타깃이 없다. 남겨 두면 상태가
        // 사실과 어긋나고 `render_path` 로그가 거짓을 말한다.
        const was_gl = self.gl_render_enabled;
        self.gl_render_enabled = false;
        log.appendLine("gpu", "{s} 경로 중단 — {s}. software wl_shm 으로 되돌린다", .{
            if (was_gl) @as([]const u8, "GL 렌더") else "dmabuf",
            reason,
        });
    }

    /// #277 — GPU 경로 buffer 하나. 실패하면 null 을 돌려주고 호출처가 shm 으로
    /// 떨어진다 (여기서 fatal 로 만들지 않는다).
    ///
    /// `create_immed` 가 아니라 `create` 를 쓴다. compositor 가 이 dma-buf 를
    /// 거부할 때 `create_immed` 는 **protocol error (연결 종료 = 앱 종료)** 지만
    /// `create` 는 `failed` 이벤트로 와서 조용히 fallback 할 수 있다. 낯선
    /// compositor / 드라이버 조합에서 앱이 죽지 않게 하는 것이 이 선택의 목적이다.
    fn createDmabufBuffer(self: *Client, width: i32, height: i32) ?SurfaceBuffer {
        const gpu = if (self.gpu) |*g| g else return null;
        // GL 로 그릴 때는 협상된 modifier 를 쓴다 (CPU 매핑이 필요 없으므로 LINEAR
        // 가 아니어도 된다). CPU 로 그릴 때는 매핑이 되는 LINEAR 여야 한다.
        const want_modifier = if (self.gl_render_enabled) self.gl_modifier.? else gbm.MOD_LINEAR;
        const bo = gpu.api.createWithModifier(gpu.device, want_modifier, @intCast(width), @intCast(height)) orelse blk: {
            // #367 — 시험 크기에서 되던 modifier 가 실제 크기에서 실패할 수 있다
            // (압축은 표면 크기·정렬 제약이 있다). GPU 를 통째로 포기하기 전에
            // **이 크기로 다시 고른다** — 협상 루프가 할당까지 검증하므로, 이 크기에
            // 안 되는 후보는 자연히 걸러진다.
            if (!self.gl_render_enabled) {
                self.disableGpu("gbm 할당 실패");
                return null;
            }
            log.appendLine("gpu", "modifier 0x{x:0>16} 이 {d}x{d} 에서 할당 실패 — 이 크기로 재협상", .{ want_modifier, width, height });
            self.negotiateGlModifier(@intCast(width), @intCast(height));
            const retry_modifier = self.gl_modifier orelse {
                self.disableGpu("이 크기에 쓸 수 있는 modifier 가 없다");
                return null;
            };
            break :blk gpu.api.createWithModifier(gpu.device, retry_modifier, @intCast(width), @intCast(height)) orelse {
                self.disableGpu("재협상 후에도 gbm 할당 실패");
                return null;
            };
        };
        var planes: [gbm.MAX_PLANES]gbm.Plane = undefined;
        const plane_count = gpu.api.exportPlanes(bo, &planes) orelse {
            gpu.api.destroyBo(bo);
            self.disableGpu("dma-buf fd export 실패");
            return null;
        };
        defer gbm.Api.closePlanes(planes[0..plane_count]);

        const params_id = self.allocId();
        const buffer_id = self.sendDmabufCreate(params_id, planes[0..plane_count], bo) catch {
            gpu.api.destroyBo(bo);
            self.disableGpu("dmabuf 프로토콜 송신 실패");
            return null;
        } orelse {
            gpu.api.destroyBo(bo);
            self.disableGpu("compositor 가 dma-buf 를 거부 (params.failed)");
            return null;
        };

        var buffer: SurfaceBuffer = .{
            .id = buffer_id,
            .fd = -1,
            .memory = null,
            .width = width,
            .height = height,
            .stride = @intCast(bo.stride),
            .released = false,
            .gbm_api = gpu.api,
            .bo = bo,
        };

        // #277 S2 — GL 로 그릴 buffer 면 렌더 타깃까지 붙여 둔다. 매 frame 만들지
        // 않고 buffer 수명과 함께 간다 (buffer 는 재사용되므로).
        if (self.gl_render_enabled) {
            const ctx = self.gl_context.?;
            // import 용 fd 를 다시 얻는다 — 위에서 프로토콜에 넘긴 fd 는 곧 닫힌다.
            var gl_planes: [gbm.MAX_PLANES]gbm.Plane = undefined;
            const gl_plane_count = gpu.api.exportPlanes(bo, &gl_planes) orelse {
                self.destroyBufferObject(buffer.id);
                buffer.deinit();
                self.disableGpu("GL import 용 dma-buf fd export 실패");
                return null;
            };
            defer gbm.Api.closePlanes(gl_planes[0..gl_plane_count]);
            buffer.gl_target = ctx.importAsTarget(gl_planes[0..gl_plane_count], bo) orelse {
                self.destroyBufferObject(buffer.id);
                buffer.deinit();
                self.disableGpu("dma-buf 를 GL 렌더 타깃으로 만들지 못함");
                return null;
            };
            buffer.gl_ctx = ctx;
        }

        return buffer;
    }

    /// `zwp_linux_buffer_params_v1` 왕복. `created` 면 server 가 할당한 wl_buffer
    /// id, `failed` 면 null.
    fn sendDmabufCreate(self: *Client, params_id: u32, planes: []const gbm.Plane, bo: gbm.Bo) !?u32 {
        // zwp_linux_dmabuf_v1.create_params (opcode 1).
        try self.sendArgs(self.linux_dmabuf_id, 1, &.{params_id});
        // params.add (opcode 1) — (fd, plane_idx, offset, stride, mod_hi, mod_lo).
        // **plane 마다 한 번씩** 보낸다 (#367 — 압축 modifier 는 메타데이터 평면을
        // 더 갖는다). modifier 는 plane 마다 같은 값을 반복한다 (프로토콜 계약).
        for (planes, 0..) |plane, i| {
            var msg = Msg.init(params_id, 1);
            try msg.putU32(@intCast(i));
            try msg.putU32(plane.offset);
            try msg.putU32(plane.stride);
            try msg.putU32(@truncate(bo.modifier >> 32));
            try msg.putU32(@truncate(bo.modifier & 0xffff_ffff));
            try msg.sendWithFd(self.stream, plane.fd);
        }
        {
            // params.create (opcode 2) — (width, height, format, flags).
            var msg = Msg.init(params_id, 2);
            try msg.putI32(@intCast(bo.width));
            try msg.putI32(@intCast(bo.height));
            try msg.putU32(gbm.FORMAT_ARGB8888);
            try msg.putU32(0);
            try msg.send(self.stream);
        }

        self.pending_dmabuf_params = params_id;
        self.pending_dmabuf_result = null;
        defer self.pending_dmabuf_params = 0;
        while (self.pending_dmabuf_result == null) try self.readAndDispatch();
        // params 객체는 결과와 무관하게 더 쓰지 않는다 (spec: create 이후 destroy).
        self.sendNoArgs(params_id, 0) catch {};
        return switch (self.pending_dmabuf_result.?) {
            .created => |bid| bid,
            .failed => null,
        };
    }

    /// buffer 의 픽셀을 채운다. software 경로는 상주 mapping 에 바로 그리고,
    /// GPU 경로는 `gbm_bo_map` / `unmap` 으로 감싼다 — unmap 이 있어야 compositor
    /// 가 읽기 전에 우리 쓰기가 보이는 것이 보장된다.
    ///
    /// **그리기 자체(`paintBuffer`)는 두 경로가 완전히 같은 코드다.** #277 S1 의
    /// 판정 기준이 "픽셀 동일" 인 근거가 이것이다 — 바뀐 것은 픽셀을 담는 그릇뿐이다.
    ///
    /// false = 이번 frame 을 그리지 못했다. 호출처는 attach 하지 않는다 (덜 그린
    /// buffer 를 붙이면 깨진 화면이 보인다).
    /// u8 색 채널 → GL 의 0..1. 한 방향 변환만 한다 (왕복하면 1 비트가 깎인다 —
    /// `software_terminal.SolidRect` 주석 참고).
    fn colorF(v: u8) f32 {
        return @as(f32, @floatFromInt(v)) / 255.0;
    }

    /// #277 S2-4 — 사각형 목록 한 계층을 그린다.
    fn glDrawRects(
        self: *Client,
        ctx: egl.Context,
        batch: *gl_rects.Batch,
        rects: []const software_terminal.SolidRect,
        viewport_w: f32,
        viewport_h: f32,
    ) void {
        if (rects.len == 0) return;
        batch.clear();
        for (rects) |r| {
            batch.add(self.allocator, .{
                .x = @floatFromInt(r.x),
                .y = @floatFromInt(r.y),
                .w = @floatFromInt(r.w),
                .h = @floatFromInt(r.h),
                .color = .{ colorF(r.color.r), colorF(r.color.g), colorF(r.color.b), 1.0 },
            }, r.shade);
        }
        batch.flush(&ctx.api, viewport_w, viewport_h);
    }

    /// #277 S2-5 — chrome 명령 목록을 **순서 그대로** 그린다.
    ///
    /// 종류(사각형 / 글리프)나 clip 경계가 바뀌는 지점에서만 batch 를 flush 한다 —
    /// 그 지점이 곧 software 경로의 그리기 순서 경계다. 탭바 한 프레임에서 전환은
    /// 몇 번뿐이라 draw call 이 늘어나는 폭이 작다.
    ///
    /// 아이콘은 글리프와 같은 회색 atlas 를 쓰므로 같은 batch 에 들어간다.
    fn glDrawChrome(
        self: *Client,
        ctx: egl.Context,
        rect_batch: *gl_rects.Batch,
        text_batch: *gl_text.Batch,
        atlas: *gl_atlas.Atlas,
        items: []const software_terminal.ChromeItem,
        viewport_w: f32,
        viewport_h: f32,
    ) void {
        if (items.len == 0) return;
        const Kind = enum { none, rect, glyph };
        var kind: Kind = .none;
        var clip: [2]i32 = .{ 0, 0 };
        rect_batch.clear();
        text_batch.clear();

        for (items) |item| {
            const item_kind: Kind = switch (item) {
                .rect => .rect,
                .glyph, .icon => .glyph,
            };
            const item_clip: [2]i32 = switch (item) {
                .glyph => |g| .{ g.clip_x0, g.clip_x1 },
                else => .{ 0, @intFromFloat(viewport_w) },
            };
            if (kind != .none and (item_kind != kind or !std.mem.eql(i32, &item_clip, &clip))) {
                self.glFlushChrome(ctx, rect_batch, text_batch, atlas, kind == .rect, clip, viewport_w, viewport_h);
            }
            kind = item_kind;
            clip = item_clip;

            switch (item) {
                .rect => |r| rect_batch.add(self.allocator, .{
                    .x = @floatFromInt(r.x),
                    .y = @floatFromInt(r.y),
                    .w = @floatFromInt(r.w),
                    .h = @floatFromInt(r.h),
                    .color = .{ colorF(r.color.r), colorF(r.color.g), colorF(r.color.b), 1.0 },
                }, r.shade),
                .glyph => |g| self.glAddGlyph(ctx, text_batch, atlas, &g.item),
                .icon => |ic| {
                    const entry = atlas.iconEntry(&ctx.api, self.allocator, ic.kind, ic.size, ic.stroke) orelse continue;
                    text_batch.add(self.allocator, .{
                        .x = @floatFromInt(ic.x),
                        .y = @floatFromInt(ic.y),
                        .w = @floatFromInt(entry.w),
                        .h = @floatFromInt(entry.h),
                        .entry = entry,
                        .color = .{ colorF(ic.color.r), colorF(ic.color.g), colorF(ic.color.b), 1.0 },
                    });
                },
            }
        }
        if (kind != .none) {
            self.glFlushChrome(ctx, rect_batch, text_batch, atlas, kind == .rect, clip, viewport_w, viewport_h);
        }
    }

    /// clip 이 화면 전체가 아니면 `glScissor` 로 자른다. scissor 는 `gl_FragCoord`
    /// 와 같은 window 좌표계라 세로는 손대지 않고 가로만 준다 (#277 S0-b — 우리
    /// FBO 는 GL y=0 행이 화면 최상단이다).
    fn glFlushChrome(
        self: *Client,
        ctx: egl.Context,
        rect_batch: *gl_rects.Batch,
        text_batch: *gl_text.Batch,
        atlas: *gl_atlas.Atlas,
        is_rect: bool,
        clip: [2]i32,
        viewport_w: f32,
        viewport_h: f32,
    ) void {
        _ = self;
        const clipped = clip[0] > 0 or clip[1] < @as(i32, @intFromFloat(viewport_w));
        if (clipped) {
            ctx.api.enable(egl.GL_SCISSOR_TEST);
            ctx.api.scissor(clip[0], 0, @max(0, clip[1] - clip[0]), @intFromFloat(viewport_h));
        }
        if (is_rect) {
            rect_batch.flush(&ctx.api, viewport_w, viewport_h);
            rect_batch.clear();
        } else {
            text_batch.flush(&ctx.api, atlas, viewport_w, viewport_h);
            text_batch.clear();
        }
        if (clipped) ctx.api.disable(egl.GL_SCISSOR_TEST);
    }

    /// #277 S2-4 — 글리프 목록 한 계층을 그린다. atlas 에 없는 글리프는 여기서
    /// 업로드된다 (목록이 이미 raster 결과를 들고 있어 폰트를 다시 조회하지 않는다).
    ///
    /// 위치는 목록의 값 그대로다. 컬러 글리프만 공통 `colorGlyphFit` 으로 대상
    /// 사각형을 구하는데, 그 함수는 software 경로의 `drawGlyphBgra` 도 쓴다.
    fn glDrawGlyphs(
        self: *Client,
        ctx: egl.Context,
        batch: *gl_text.Batch,
        atlas: *gl_atlas.Atlas,
        items: []const software_terminal.GlyphItem,
        viewport_w: f32,
        viewport_h: f32,
    ) void {
        if (items.len == 0) return;
        batch.clear();
        for (items) |*item| self.glAddGlyph(ctx, batch, atlas, item);
        batch.flush(&ctx.api, atlas, viewport_w, viewport_h);
    }

    /// 글리프 하나를 atlas 에 확보하고 정점을 쌓는다. 위치는 목록의 값 그대로다 —
    /// 컬러 글리프만 공통 `colorGlyphFit` 으로 대상 사각형을 구하는데, 그 함수는
    /// software 경로의 `drawGlyphBgra` 도 쓴다.
    fn glAddGlyph(
        self: *Client,
        ctx: egl.Context,
        batch: *gl_text.Batch,
        atlas: *gl_atlas.Atlas,
        item: *const software_terminal.GlyphItem,
    ) void {
        const entry = atlas.glyphForItem(&ctx.api, self.allocator, item) orelse return;
        if (entry.is_color) {
            const fit = software_terminal.colorGlyphFit(item.w, item.h, item.glyph.width, item.glyph.height) orelse return;
            batch.add(self.allocator, .{
                .x = @floatFromInt(item.x + fit.off_x),
                .y = @floatFromInt(item.y + fit.off_y),
                .w = @floatFromInt(fit.w),
                .h = @floatFromInt(fit.h),
                .entry = entry,
                // 컬러 텍셀을 그대로 쓴다 — rgb 는 무시되고 알파만 곱해진다.
                .color = .{ 0, 0, 0, 1.0 },
            });
            return;
        }
        batch.add(self.allocator, .{
            .x = @floatFromInt(item.x),
            .y = @floatFromInt(item.y),
            .w = @floatFromInt(entry.w),
            .h = @floatFromInt(entry.h),
            .entry = entry,
            .color = .{ colorF(item.fg.r), colorF(item.fg.g), colorF(item.fg.b), 1.0 },
        });
    }

    fn paintIntoBuffer(self: *Client, buffer: *SurfaceBuffer) bool {
        // #277 S2-4 — GL 경로. **그리기 목록은 CPU 경로와 같은 수집기가 만든다**
        // (`buildGlFrame` → `collectTerminalLayer`). 여기서 하는 일은 그 목록을
        // 정점으로 옮기는 것뿐이고, "무엇을 어디에" 는 한 글자도 다시 쓰지 않는다.
        //
        // dialog 만 이 경로 밖이다 — layer-shell dialog surface 는 항상 `wl_shm` 이라
        // GPU buffer 가 붙지 않는다.
        if (buffer.gl_target) |target| {
            const ctx = buffer.gl_ctx orelse return false;
            const theme = self.config.theme orelse fallback_theme;

            var titles_storage: [session_core.MAX_TABS][]const u8 = undefined;
            var hotkey_hint_buf: [64]u8 = undefined;
            var frame: software_terminal.GlFrame = .{
                .background = theme.background,
                .layer = self.renderer.emptyLayer(),
            };
            if (self.session) |*session| {
                if (session.activeTab()) |tab| {
                    const collect_t0 = perf.now();
                    frame = self.renderer.buildGlFrame(self.allocator, self.frameInputs(
                        session,
                        tab,
                        buffer.width,
                        buffer.height,
                        &titles_storage,
                        &hotkey_hint_buf,
                    ));
                    // #362 — 목록 생성 비용. GPU 로 옮긴 뒤 남은 CPU 의 어디가
                    // 무거운지 보려면 이 값이 필요하다 (계측은 GPU 타이밍과 같은
                    // 스위치로 켠다).
                    if (self.gpu_timer != null) perf.addTimed(&perf.render, collect_t0);
                }
            }

            if (self.gpu_timer) |*t| t.begin(&ctx.api);
            ctx.api.bindFramebuffer(egl.GL_FRAMEBUFFER, target.framebuffer);
            ctx.api.viewport(0, 0, buffer.width, buffer.height);
            ctx.api.clearColor(
                colorF(frame.background.r),
                colorF(frame.background.g),
                colorF(frame.background.b),
                colorF(self.renderer.opacity_alpha),
            );
            ctx.api.clear(egl.GL_COLOR_BUFFER_BIT);
            // L13-γ — 알파는 `glClear` 가 칠한 `opacity_alpha` 하나로 끝낸다. 이후
            // 드로가 알파를 건드리지 못하게 막으면 software 경로가 마지막에 도는
            // "alpha sweep" 과 정확히 같은 결과가 된다. 막지 않으면 사각형이 그린
            // 자리만 불투명해져 반투명 창이 얼룩진다.
            ctx.api.colorMask(1, 1, 1, 0);

            const viewport_w: f32 = @floatFromInt(buffer.width);
            const viewport_h: f32 = @floatFromInt(buffer.height);
            if (self.gl_batch) |*batch| {
                if (self.gl_text_batch) |*text_batch| {
                    if (self.gl_atlas_store) |*atlas| {
                        // 목록 순서 그대로 (`TerminalLayer` 참고). 계층마다 flush 하는
                        // 것이 곧 그 순서를 지키는 방법이다.
                        self.glDrawChrome(ctx, batch, text_batch, atlas, frame.layer.chrome_before.items, viewport_w, viewport_h);
                        self.glDrawRects(ctx, batch, frame.layer.cell_bg.items, viewport_w, viewport_h);
                        self.glDrawGlyphs(ctx, text_batch, atlas, frame.layer.glyphs.items, viewport_w, viewport_h);
                        self.glDrawRects(ctx, batch, frame.layer.overlay.items, viewport_w, viewport_h);
                        self.glDrawRects(ctx, batch, frame.layer.preedit_bg.items, viewport_w, viewport_h);
                        self.glDrawGlyphs(ctx, text_batch, atlas, frame.layer.preedit_glyphs.items, viewport_w, viewport_h);
                        self.glDrawChrome(ctx, batch, text_batch, atlas, frame.layer.chrome_after.items, viewport_w, viewport_h);
                    }
                }
            }
            ctx.api.colorMask(1, 1, 1, 1);

            // compositor 는 dma-buf 의 implicit fence 를 기다린다. glFinish 로
            // 동기 대기하면 그 비용이 프레임 시간에 섞이므로 flush 만 한다.
            ctx.api.flush();
            if (self.gpu_timer) |*t| {
                t.end(&ctx.api);
                self.gpu_timer_frames += 1;
                // 120 프레임마다 한 줄. 매 프레임 찍으면 로그가 계측을 방해한다.
                if (self.gpu_timer_frames % 120 == 0) {
                    if (t.averageNs()) |avg| {
                        const rc = perf.snapshot(&perf.render);
                        const nf = @max(software_terminal.acc_frames, 1);
                        log.appendLine("gpu", "프레임 CPU 평균 update={d:.1} collect={d:.1} µs (프레임 {d}) [전체 {d:.1} µs]", .{
                            @as(f64, @floatFromInt(software_terminal.acc_update_ns)) / @as(f64, @floatFromInt(nf)) / 1000.0,
                            @as(f64, @floatFromInt(software_terminal.acc_collect_ns)) / @as(f64, @floatFromInt(nf)) / 1000.0,
                            software_terminal.acc_frames,
                            if (rc[0] > 0) @as(f64, @floatFromInt(rc[1])) / @as(f64, @floatFromInt(rc[0])) / 1000.0 else 0.0,
                        });
                        software_terminal.acc_update_ns = 0;
                        software_terminal.acc_collect_ns = 0;
                        software_terminal.acc_frames = 0;
                        log.appendLine("gpu", "프레임 GPU 시간 평균 {d:.1} µs (표본 {d}, 버린 것 {d}, {d}x{d}, modifier=0x{x:0>16} plane={d})", .{
                            @as(f64, @floatFromInt(avg)) / 1000.0,
                            t.samples,
                            t.discarded,
                            buffer.width,
                            buffer.height,
                            self.gl_modifier orelse 0,
                            self.gl_plane_count,
                        });
                    }
                    t.reset();
                }
            }
            return true;
        }
        if (buffer.bo) |bo| {
            const api = buffer.gbm_api orelse return false;
            const len: usize = @as(usize, @intCast(buffer.height)) * bo.stride;
            const scratch = self.ensureGpuScratch(len) orelse return false;

            // 그리기는 **일반 RAM 에서** 끝낸다 (위 `gpu_scratch` 주석 참고 —
            // WC 메모리에 직접 그리면 블렌딩의 읽기 때문에 CPU 가 3 배 든다).
            self.paintBuffer(scratch, buffer.width, buffer.height, @intCast(bo.stride));

            const mapping = api.map(bo) orelse return false;
            defer api.unmap(bo, mapping);
            // compositor 는 `params.add` 로 알려준 `bo.stride` 로 읽는다. CPU
            // mapping 의 stride 가 그와 다르면 서로 다른 배치를 보게 되므로
            // 그리지 않는다 (실측 환경에선 항상 같았지만 계약상 보장은 없다).
            if (mapping.stride != bo.stride) return false;
            @memcpy(mapping.data[0..len], scratch[0..len]);
            return true;
        }
        const memory = buffer.memory orelse return false;
        self.paintBuffer(memory, buffer.width, buffer.height, buffer.stride);
        return true;
    }

    /// GPU 경로 scratch 확보. 크기가 모자라면 재할당한다. 실패하면 null —
    /// 호출처가 이번 frame 을 건너뛰고 software 로 되돌린다.
    fn ensureGpuScratch(self: *Client, len: usize) ?[]align(std.heap.page_size_min) u8 {
        if (self.gpu_scratch) |existing| {
            if (existing.len >= len) return existing;
            self.allocator.free(existing);
            self.gpu_scratch = null;
        }
        const fresh = self.allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), len) catch return null;
        self.gpu_scratch = fresh;
        return fresh;
    }

    fn createBuffer(self: *Client, width: i32, height: i32) !SurfaceBuffer {
        // #277 — GPU 경로 우선. 실패하면 아래 software 경로로 그대로 흘러간다
        // (`disableGpu` 가 이미 불려서 다음 frame 부터는 시도조차 하지 않는다).
        if (self.gpu_enabled) {
            if (self.createDmabufBuffer(width, height)) |gpu_buffer| {
                var owned = gpu_buffer;
                if (self.paintIntoBuffer(&owned)) return owned;
                self.destroyBufferObject(owned.id);
                owned.deinit();
                self.disableGpu("dma-buf CPU 매핑 실패");
            }
        }

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

    /// #277 S2-5 — 한 프레임의 렌더 입력을 모은다. **CPU 경로(`paintBuffer`)와 GL
    /// 경로(`paintIntoBuffer`)가 같은 함수를 쓴다** — 입력이 갈리면 그리기 목록을
    /// 공유해도 소용이 없다.
    ///
    /// `titles_storage` / `hotkey_buf` 는 호출처 stack 이고 반환값이 그 안을
    /// 가리킨다 — paint 가 끝날 때까지 살아 있어야 한다.
    fn frameInputs(
        self: *Client,
        session: *session_core.SessionCore,
        tab: *session_core.Tab,
        width: i32,
        height: i32,
        titles_storage: *[session_core.MAX_TABS][]const u8,
        hotkey_buf: *[64]u8,
    ) software_terminal.FrameInputs {
        const tabs = session.tabsSlice();
        const count = @min(tabs.len, titles_storage.len);
        for (tabs[0..count], 0..) |t, i| {
            titles_storage[i] = t.title[0..t.title_len];
        }
        // L12-γ — tab_layout.compute 로 arrow/plus/tab area 영역 분할. override 가
        // false 면 ensureActiveVisible 로 활성 탭이 보이는 위치로 scroll_x 보정.
        // compute / ensureActiveVisible 둘 다 cross-platform pure function —
        // side effect 없음, client field 갱신은 여기서.
        const layout_inputs = tab_layout.Inputs{
            .viewport_w = @floatFromInt(width),
            .tab_count = @intCast(count),
            .tab_w = @floatFromInt(self.renderer.tabWidthPx()),
            .arrow_w = @floatFromInt(self.renderer.tabArrowWPx()),
            .plus_w = @floatFromInt(self.renderer.tabPlusWPx()),
            .plus_enabled = self.tabPlusEnabled(),
            .close_w = @floatFromInt(self.renderer.tabCloseWPx()),
            .more_w = @floatFromInt(self.renderer.tabMoreWPx()),
            .scroll_x = self.tab_scroll_x,
        };
        const layout = tab_layout.compute(layout_inputs);
        if (!self.tab_scroll_override) {
            self.tab_scroll_x = tab_layout.ensureActiveVisible(layout_inputs, layout, @intCast(session.active_tab));
        }
        return .{
            .terminal = &tab.terminal,
            .theme = self.config.theme orelse fallback_theme,
            .width = width,
            .height = height,
            .tab_titles = titles_storage[0..count],
            .active_tab_idx = session.active_tab,
            .layout = layout,
            .tab_scroll_x = self.tab_scroll_x,
            .drag_view = self.tab_drag.view(),
            .tab_hover = self.tab_hover,
            .menu_ui = .{
                .open = self.command_menu_open,
                .hover = self.command_menu_hover,
                .focused = self.command_menu_focus,
                .first_visible = self.command_menu_first,
                .fullscreen_workarea = self.fullscreen_mode == .avoid,
            },
            .toggle_hotkey = config_mod.hotkeyDisplay(hotkey_buf, self.config.hotkey),
        };
    }

    fn paintBuffer(self: *Client, memory: []u8, width: i32, height: i32, stride: i32) void {
        // #160 — render(그리기, present 제외) 계측. Windows renderer/windows.zig 동등.
        const render_t0 = perf.now();
        defer perf.addTimed(&perf.render, render_t0);
        if (self.session) |*session| {
            if (session.activeTab()) |tab| {
                // Titles slice / hotkey 힌트는 **호출처 stack** 에 둔다 —
                // `FrameInputs` 가 그 안을 가리키므로 paint 동안만 valid 하다.
                var titles_storage: [session_core.MAX_TABS][]const u8 = undefined;
                var hotkey_hint_buf: [64]u8 = undefined;
                const in = self.frameInputs(session, tab, width, height, &titles_storage, &hotkey_hint_buf);
                self.renderer.paint(self.allocator, memory, stride, in);
                // L10-γ — cursor 위치가 변했으면 server 에 알린다. fcitx5
                // popover (한자 후보, 확장 candidate window 등) 가 우리 cursor
                // 근처에 정렬되도록. error 는 main loop 멈추지 않게 swallow.
                self.updateCursorRectangle() catch {};
                return;
            }
        }
        fillBuffer(memory, width, height, stride);
    }

    fn attachAndCommit(self: *Client, buffer: SurfaceBuffer) !void {
        // #160 — present(attach + damage + commit) 계측. Windows present(swap) 동등.
        const present_t0 = perf.now();
        defer perf.addTimed(&perf.present, present_t0);
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
            // 모든 native hotkey backend와 같은 path로 hide/show.
            const command = single_instance.acceptCommand(self.toggle_listener_fd) catch null;
            if (command) |cmd| switch (cmd) {
                .toggle => self.handleActivatedToggle() catch |err| {
                    log.appendLine("toggle-ipc", "handleActivatedToggle failed: {s}", .{@errorName(err)});
                },
                .new_instance => {
                    if (@import("../../instance_context.zig").requireWorkerIndex() == 0) {
                        self.pending_new_instance_request = true;
                    }
                },
            };
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
            if (opcode == 0) {
                try self.handleRegistryGlobal(payload);
            } else if (opcode == 1) {
                self.handleRegistryGlobalRemove(payload);
            }
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
        // #277 — zwp_linux_dmabuf_v1.modifier (opcode 1, since v3):
        // (format, modifier_hi, modifier_lo). v1~v2 의 `format` event (opcode 0)
        // 는 modifier 를 알려주지 않아 무시한다 — LINEAR 를 명시로 확인할 수 없으면
        // GPU 경로를 켜지 않는다.
        if (self.linux_dmabuf_id != 0 and id == self.linux_dmabuf_id and opcode == 1 and payload.len >= 12) {
            const format = readU32(payload[0..4]);
            const modifier = (@as(u64, readU32(payload[4..8])) << 32) | @as(u64, readU32(payload[8..12]));
            if (format == gbm.FORMAT_ARGB8888) {
                if (modifier == gbm.MOD_LINEAR) self.dmabuf_linear_supported = true;
                // INVALID 는 후보가 아니다 — 명시 modifier 를 넘길 수 없다.
                if (modifier != gbm.MOD_INVALID and self.dmabuf_mod_count < max_dmabuf_mods) {
                    self.dmabuf_mods[self.dmabuf_mod_count] = modifier;
                    self.dmabuf_mod_count += 1;
                }
            }
            return;
        }
        // #277 S2-6 — zwp_linux_dmabuf_feedback_v1 (v4+).
        //
        //   0 done                   모든 파라미터 전송 끝
        //   1 format_table  (fd, u32 size)      16 byte 항목 표 (fd 는 cmsg 로)
        //   2 main_device   (array dev_t)
        //   3 tranche_done                      현재 tranche 확정
        //   4 tranche_target_device (array dev_t)
        //   5 tranche_formats (array of u16)    표의 index 목록
        //   6 tranche_flags (uint)              bit 0 = scanout
        //
        // tranche 는 **선호 내림차순**으로 온다. 우리는 그 순서를 그대로
        // `dmabuf_mods` 에 쌓아 협상이 앞에서부터 시험하게 한다.
        if (self.dmabuf_feedback_id != 0 and id == self.dmabuf_feedback_id) {
            switch (opcode) {
                0 => self.finishDmabufFeedback(),
                1 => {
                    const fd = self.takeReceivedFd() catch return;
                    defer posix.close(fd);
                    if (payload.len < 4) return;
                    const size: usize = @intCast(readU32(payload[0..4]));
                    if (size == 0) return;
                    if (self.dmabuf_format_table) |old| posix.munmap(@constCast(old));
                    self.dmabuf_format_table = posix.mmap(
                        null,
                        size,
                        linux.PROT.READ,
                        .{ .TYPE = .PRIVATE },
                        fd,
                        0,
                    ) catch null;
                },
                2 => self.dmabuf_main_device = readDevT(payload),
                3 => self.flushDmabufTranche(),
                4 => self.dmabuf_tranche_device = readDevT(payload),
                5 => self.collectTrancheFormats(payload),
                6 => if (payload.len >= 4) {
                    self.dmabuf_tranche_scanout = (readU32(payload[0..4]) & 1) != 0;
                },
                else => {},
            }
            return;
        }
        // #277 — zwp_linux_buffer_params_v1: created (0, new_id) / failed (1).
        if (self.pending_dmabuf_params != 0 and id == self.pending_dmabuf_params) {
            if (opcode == 0 and payload.len >= 4) {
                self.pending_dmabuf_result = .{ .created = readU32(payload[0..4]) };
            } else if (opcode == 1) {
                self.pending_dmabuf_result = .failed;
            }
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
        if (self.prompt_shortcuts_inhibitor_id != 0 and id == self.prompt_shortcuts_inhibitor_id) {
            if (opcode == keyboard_shortcuts_inhibitor_event_active) {
                log.appendLineVerbose("dialog", "keyboard shortcuts inhibitor active", .{});
            } else if (opcode == keyboard_shortcuts_inhibitor_event_inactive) {
                log.appendLine("dialog", "keyboard shortcuts inhibitor inactive; compositor bindings may intercept prompt input", .{});
            }
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
        if (self.findOutputSlot(.{ .object_id = id })) |slot| {
            try self.handleOutputEvent(slot, opcode, payload);
            return;
        }
        // #295 — main surface 의 enter/leave (surface 가 걸친 output 알림). 여기선
        // entered 집합만 갱신하고 basis 판정은 batch 종료 후 drainSurfaceOutputs 로
        // 미룬다 — 한 batch 에 여러 enter 가 와도 중간값으로 recreate 예약하지 않게.
        if (self.surface_id != 0 and id == self.surface_id and
            (opcode == wl_surface_event_enter or opcode == wl_surface_event_leave))
        {
            if (payload.len >= 4) {
                if (self.findOutputSlot(.{ .object_id = readU32(payload[0..4]) })) |slot| {
                    slot.entered = (opcode == wl_surface_event_enter);
                    self.surface_outputs_dirty = true;
                }
            }
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
                // #336 — main surface 의 preferred_scale 수신 표시. settleInitialLayout
                // 의 대기 종료 조건 (값이 안 바뀌는 100%(120→120) 케이스도 event 수신
                // 자체로 확정 처리 — applyScaleChange 의 값 비교와 무관).
                if (matches_main) self.preferred_scale_received = true;
                try self.applyScaleChange(new_scale, if (matches_dialog) "fractional/dialog" else "fractional/main");
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
            // #241 — hide 상태의 close 는 사용자 Alt+F4 가 아니라 compositor 측
            // 이벤트(output 변화 등). xdg_toplevel.close 는 권고일 뿐이고 surface 는
            // 살아있으므로 아무 것도 안 하고 무시 — 다음 show(remap)가 정상 동작.
            // (재생성하면 GNOME 확장 #228/#231 이 새 map 을 다시 placement/minimize
            // 로 가로채 숨겨버림 → 재생성 금지.) quit 으로 안 감.
            if (self.surface_hidden) {
                log.appendLine("input", "xdg-shell toplevel close while hidden — ignored (surface alive), NOT quit (#241)", .{});
                return;
            }
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
            // Fresh xdg-shell recreate는 아직 mapped=false지만 visible이다.
            // 첫 non-null buffer attach가 일어나도록 layer-shell configure와
            // 같은 조건으로 redraw를 요청한다.
            if (self.mapped or !self.surface_hidden) self.requestRedraw();
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
        // #231 — dialog xdg_toplevel events (layer-shell 없는 mutter/muffin).
        // configure(opcode 0): width/height(+states) — 0 이면 "you decide" 라
        // 보관한 요청 크기 유지. close(opcode 1): 사용자가 창 닫음 → dismiss.
        if (self.dialog.xdg_toplevel_id != 0 and id == self.dialog.xdg_toplevel_id) {
            if (opcode == 0 and payload.len >= 8) {
                const w = readU32(payload[0..4]);
                const h = readU32(payload[4..8]);
                if (w > 0) self.dialog.pending_w_logical = w;
                if (h > 0) self.dialog.pending_h_logical = h;
                return;
            }
            if (opcode == 1) {
                log.appendLine("dialog", "dialog xdg_toplevel closed by user/compositor", .{});
                self.requestDismissDialog();
                return;
            }
        }
        // #231 — dialog xdg_surface configure(opcode 0): ack(opcode 4) 후 보관한
        // 크기로 공통 paint. (layer 경로의 handleDialogConfigure 와 ack opcode 만 다름.)
        if (self.dialog.xdg_surface_id != 0 and id == self.dialog.xdg_surface_id and opcode == 0 and payload.len >= 4) {
            const serial = readU32(payload[0..4]);
            try self.sendArgs(self.dialog.xdg_surface_id, 4, &.{serial});
            try self.applyDialogSizeAndPaint(self.dialog.pending_w_logical, self.dialog.pending_h_logical);
            return;
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
                log.appendLineVerbose("wayland", "layer-surface configure serial={} logical_w={} logical_h={} scale={d}/120", .{
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
                // #351 — 초기 안전 commit (4-edge span + size 0 + margin 0 +
                // exclusive_zone 0) 의 configure 는 곧 **logical work-area** 다.
                // 이후 layout 계산이 이 값을 쓴다. **one-shot** — Hyprland 는 같은
                // 상태에서 configure 를 여러 번 보내므로 (실측 14회) 플래그를 바로
                // 내려 재latch 와 무한 전환을 막는다 (`configured` 도 이 핸들러 끝에서
                // 세워지므로 두 조건 다 재진입을 막는다).
                if (self.initial_safe_pending and !self.configured and w > 0 and h > 0) {
                    self.initial_safe_pending = false;
                    self.screen_logical_w = w_logical;
                    self.screen_logical_h = h_logical;
                    log.appendLineVerbose("wayland", "logical work-area latched {}x{} (initial-safe configure, #351)", .{ w_logical, h_logical });
                    // continuation — 보류했던 실제 layout 을 이제 정확한 work-area 로
                    // 보낸다. 이 지점이 초기 안전 commit 을 보내는 모든 경로
                    // (boot 의 bringUpInitialSurface, #241/#295 의 swapMainSurfaceSeamless)
                    // 에서 실제 layout 송신을 보장하는 단일 위치다.
                    try self.sendLayerSurfaceLayout(false);
                }
                // 아래 크기 적용 / grid 생성 / `configured` 는 이 configure 로 그대로
                // 진행한다 (#351 이 바꾸지 않음). `width_percent`=`height_percent`=100
                // 이면 실제 layout 의 크기가 초기 안전 commit 과 같아 compositor 가 두
                // 번째 configure 를 안 보낼 수 있으므로, 이 configure 를 boot 진행
                // 신호로 계속 써야 한다 (안 그러면 그 config 에서 boot 가 멈춘다).
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
                // #241 — `closed` 는 의미가 둘: (1) 사용자/compositor 의 닫기 요청
                // (KWin Alt+F4 등), (2) surface 가 올라간 output 이 사라짐 (모니터
                // 분리, compositor 재구성 — wlr-layer-shell spec 에 "output may
                // have been destroyed" 명시). hide 상태(surface_hidden)면 안 보이는
                // 창을 사용자가 닫을 수 없으므로 (2) 로 확정 — quit 으로 오해하지
                // 않는다. layer-surface 는 closed 후 재사용 불가라 destroyShellObjects
                // 로 정리(surface_id=0) → 다음 show 가 createShellObjects 로 현재
                // 모니터(output=NULL)에 완전 재생성. Win/mac 처럼 hide 는 순수
                // visibility 토글로 유지.
                if (self.surface_hidden) {
                    log.appendLine("input", "main layer-surface closed while hidden (output gone) — destroy + recreate on next show, NOT quit (#241)", .{});
                    try self.destroyShellObjects();
                    return;
                }
                // #336 — 아직 map(첫 frame) 전이면 이 closed 는 사용자 Alt+F4 가 아니라
                // 첫 실제 layout 이 잘못 나가 compositor 가 거부한 것(fractional + 낮은
                // height_percent). quit 이 아니라 boot 재시도 신호만 세운다 —
                // waitForConfigure 가 error.InitLayerClosed 로 빠져 bringUpInitialSurface
                // 가 destroy+재생성(상한)한다. map 이후 closed(아래)만 Alt+F4 / output re-home.
                if (!self.mapped) {
                    log.appendLine("input", "main layer-surface closed before first map — boot retry signal, NOT quit (#336)", .{});
                    self.init_layer_closed = true;
                    return;
                }
                // #241 Fix B — visible 상태의 closed 는 즉시 판정하지 않는다.
                // 모니터 분리(global_remove)뿐 아니라 재연결(global add)도 surface
                // re-home 을 위해 closed 를 보내며(KWin 시연 확인), 둘 다 같은 batch
                // 의 topology 이벤트와 함께 온다. closed 시점엔 그 topology 이벤트가
                // 이 batch 의 앞/뒤 어디 있을지 모르므로, 일단 quit 요청만 세우고
                // main loop drain 이 batch 전체를 본 뒤 output_topology_pending 으로
                // "Alt+F4 vs output re-home" 을 판정한다(아래 step 4 와 동일 경로).
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
                // L12-γ-2 — macOS #175 동등. focus loss = commit (preedit
                // 보존). Escape 만 cancel.
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
            .clipboard_copy = linuxTabClipboardCopy,
            .terminate = linuxTabTerminate,
            .user_data = self,
        };
    }

    /// L12-β — Ctrl+Shift+T 새 탭. 32-tab cap 도달 시 dialog + skip.
    /// L12-γ-2 — macOS `commitPendingInput` 정책 — 단축키 진입 시 진행 중
    /// preedit 을 commit (보존).
    fn handleNewTab(self: *Client) void {
        if (self.session == null) return;
        self.commitPendingInput();
        var host = self.buildTabActionsHost();
        if (tab_actions.checkAtLimitAndDialog(&host)) return;
        // #248 — shell 이 런타임에 사라졌으면 (패키지 업데이트 등) 조용히 죽는 대신 알림.
        if (!shell_validate.checkForNewTab(self.allocator, self.config.shell)) return;
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
    /// 등 "지금 멈춰" 시점에 진행 중인 입력 (cell preedit + IME pending) 을
    /// 활성 탭 PTY 로 **commit** (cancel 아님). Escape 만 명시적 cancel —
    /// macOS Cocoa quirk (#175) 동등 정책.
    fn commitPendingInput(self: *Client) void {
        const had_preedit = self.preedit_text.items.len > 0 or self.pending_preedit.items.len > 0;
        // 1) Cell preedit (terminal IME 조합 중) — PTY 로 직접 송신.
        if (self.preedit_text.items.len > 0) {
            self.queueInput(self.preedit_text.items);
            self.preedit_text.clearRetainingCapacity();
            self.renderer.preedit_text = "";
        }
        // 2) Wayland text-input pending (다음 done 안 온 batch) 도 cleanup.
        self.pending_preedit.clearRetainingCapacity();
        self.pending_commit.clearRetainingCapacity();
        // 3) 시연 사이클 발견: client 가 preedit 자모를 PTY 송신해도 fcitx5
        //    의 internal IME state 의 자모 buffer 는 그대로 남음 → 다음
        //    typing 시 *이전 자모 + 새 자모* 가 한 음절로 commit 됨.
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
    /// 으로 어떤 탭인지. close 'x' → closeIndex.
    fn handleTabBarClick(self: *Client, px: i32, py: i32) void {
        if (self.session == null) return;
        const session = &self.session.?;
        const tab_w_px = self.renderer.tabWidthPx();
        const layout_inputs = tab_layout.Inputs{
            .viewport_w = @floatFromInt(self.window_width),
            .tab_count = @intCast(session.count()),
            .tab_w = @floatFromInt(tab_w_px),
            .arrow_w = @floatFromInt(self.renderer.tabArrowWPx()),
            .plus_w = @floatFromInt(self.renderer.tabPlusWPx()),
            .plus_enabled = self.tabPlusEnabled(),
            .close_w = @floatFromInt(self.renderer.tabCloseWPx()),
            .more_w = @floatFromInt(self.renderer.tabMoreWPx()),
            .scroll_x = self.tab_scroll_x,
        };
        const layout = tab_layout.compute(layout_inputs);
        const px_f: f32 = @floatFromInt(px);
        const py_f: f32 = @floatFromInt(py);
        const tab_bar_h_f: f32 = @floatFromInt(self.effectiveTabBarHeightPx());
        const area = tab_layout.hitArea(px_f, py_f, tab_bar_h_f, layout);
        // #282 A6 — SPEC §4.1 "영역 무관 mouse_down = commit". 탭바 컨트롤
        // (화살표 / `+` / `×`) 클릭도 진행 중 preedit 을 확정한다.
        switch (area) {
            .left_arrow => {
                self.commitPendingInput();
                if (tab_layout.scrollByArrow(layout_inputs, layout, .left)) |sx| {
                    self.tab_scroll_x = sx;
                    self.tab_scroll_override = true;
                    self.needs_redraw = true;
                }
            },
            .right_arrow => {
                self.commitPendingInput();
                if (tab_layout.scrollByArrow(layout_inputs, layout, .right)) |sx| {
                    self.tab_scroll_x = sx;
                    self.tab_scroll_override = true;
                    self.needs_redraw = true;
                }
            },
            // #329 — MAX_TABS 도달 시 비활성 `+` 클릭은 완전 noop (dialog
            // 없음 — 비활성 overflow 화살표와 같은 관례).
            .plus => if (layout.plus_enabled) self.handleNewTab(),
            // #268 — 우측 끝 `x` = 활성 탭 닫기 (per-tab close 대체).
            .close => {
                self.commitPendingInput();
                var host = self.buildTabActionsHost();
                const outcome = tab_actions.closeIndex(&host, session.activeIndex());
                // #127 — 2 → 1 전환 시 탭바 사라짐 → grid 재계산.
                if (outcome == .changed) {
                    self.ensureSessionGrid() catch |err| {
                        log.appendLine("tab", "ensureSessionGrid after close 'x' failed: {s}", .{@errorName(err)});
                    };
                }
            },
            .more => {
                self.commitPendingInput();
                self.command_menu_open = !self.command_menu_open;
                self.command_menu_hover = null;
                self.needs_redraw = true;
            },
            .tab_area => {
                const hit_index = tab_layout.hitTab(
                    px_f,
                    layout,
                    @floatFromInt(tab_w_px),
                    self.tab_scroll_x,
                    @intCast(session.count()),
                ) orelse return;
                var host = self.buildTabActionsHost();
                tab_actions.switchTab(&host, hit_index);
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
            .plus_enabled = self.tabPlusEnabled(),
            .close_w = @floatFromInt(self.renderer.tabCloseWPx()),
            .more_w = @floatFromInt(self.renderer.tabMoreWPx()),
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

    /// IME cursor rectangle 의 named 형 — `updateCursorRectangle` 용.
    const CursorRect = struct { x: i32, y: i32, w: i32, h: i32 };

    /// L10-γ — `set_cursor_rectangle(x, y, w, h)` + commit. surface-relative
    /// pixel 좌표. fcitx5 popover (한자 / 확장 candidate window) 가 cursor 근처
    /// 에 정렬되도록. text-input-v3 spec 의 cursor_rectangle 단위 = **logical
    /// pixel** — fractional scale 환경 (KDE 1.5x / 1.7x 등) 에서 우리 physical
    /// 좌표를 그대로 넘기면 IME 가 큰 logical 좌표로 해석 → popup 화면 중간 등
    /// 엉뚱한 위치. `enableTextInput` 의 변환과 같은 패턴 (사용자 시연 발견).
    ///
    /// 캐시 비교로 cursor 가 실제로 이동했을 때만 전송 (spam 회피). text_input
    /// 미활성이면 no-op.
    fn updateCursorRectangle(self: *Client) !void {
        if (!self.text_input_enabled or self.text_input_id == 0) return;

        const cw = self.renderer.cellWidth();
        const ch = self.renderer.cellHeight();
        const rect: CursorRect = blk: {
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
            log.appendLineVerbose("wayland", "text_input commit text_len={}", .{self.pending_commit.items.len});
            self.queueInput(self.pending_commit.items);
            self.pending_commit.clearRetainingCapacity();
        }
        // pending_preedit → preedit_text 로 옮긴 뒤 renderer slice 갱신. paint
        // 호출 시점에 storage 가 valid 해야 하므로 ArrayList 의 owned 메모리에
        // 보관. pending_preedit 가 비어 있으면 preedit_text 도 비움 (overlay
        // 사라짐 = 조합 끝).
        if (self.pending_preedit.items.len > 0) {
            log.appendLineVerbose("wayland", "text_input preedit text_len={}", .{self.pending_preedit.items.len});
        }
        self.preedit_text.clearRetainingCapacity();
        try self.preedit_text.appendSlice(self.allocator, self.pending_preedit.items);
        self.pending_preedit.clearRetainingCapacity();
        self.renderer.preedit_text = self.preedit_text.items;
        // #242 — preedit(조합 중)도 사용자 입력 → 맨 아래로(scroll-on-keystroke).
        // composition 은 cursor(맨 아래 live line)에 inline 표시되므로 스크롤백
        // 올린 상태에서 안 내려가면 자기 조합이 안 보임. commit 은 위
        // queueInput 이 scroll.
        if (self.preedit_text.items.len > 0) {
            if (self.session) |*session| session.scrollActiveToBottom();
        }
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
        log.appendLineVerbose("wayland", "keyboard keymap loaded size={}", .{size});
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
        // Tab 만 의미). modal — 다른 키 swallow. preedit / 단축키 모두
        // 이 위로 통과 못 함 (NSAlert / MessageBoxW 의 modal 동등).
        if (self.dialog.active()) {
            self.handleDialogKey(key);
            return;
        }

        // #329 — command menu 가 열려 있으면 키는 메뉴 계층이 소비한다.
        // 단 Ctrl/Alt 조합(단축키·paste·interrupt)은 **메뉴를 닫고 아래 기존
        // 경로로 정상 실행** — SPEC §3 "단축키·명시적 paste 는 메뉴 닫고
        // 정상 실행" + Ctrl+C 도 동일(2026-07-23 사용자 확정 (a)). 재감사에서
        // Linux 만 모든 키를 삼켜 Ctrl+Shift+T 가 noop 이고 Alt+Enter 가
        // Return 으로 오인돼 focus 항목을 실행하던 결함 수정. Windows
        // (.shortcut/.paste/.interrupt 이벤트에서 close 후 실행) / macOS
        // (Cmd·Ctrl 조합이면 close 후 기존 경로)와 대칭.
        if (self.command_menu_open) {
            if (self.keyboard.ctrlActive() or self.keyboard.altActive()) {
                self.closeCommandMenu();
                // fallthrough — 아래 classifyInput → input_policy 경로가 처리.
            } else {
                self.handleCommandMenuKey(key);
                return;
            }
        }

        const xkb_key = key + wayland_xkb_keycode_offset;
        const sym_opt = self.keyboard.oneSym(xkb_key);
        const ctrl = self.keyboard.ctrlActive();
        const shift = self.keyboard.shiftActive();
        const alt = self.keyboard.altActive();

        // #296 — 상태-의존 정책(terminal preedit × 입력)은 공통
        // input_policy.resolve 한 곳에서 결정한다. host 는 native → Input 분류만.
        // 정책 대상이 아니면(일반 문자 / 터미널 control char / preedit-Ctrl
        // commit / scroll) 아래 기존 PTY 경로로 흘린다.
        if (sym_opt) |sym| {
            if (classifyInput(sym, ctrl, shift, alt)) |input| {
                // #333 — paste 는 우클릭 / command menu 와 공통 semantic helper(requestPaste)
                // 로 정책을 정확히 한 번 적용한다. generic resolve/switch 보다 먼저 분기해
                // 이중 commit 을 막는다.
                if (input == .paste) {
                    self.requestPaste();
                    return;
                }
                const disp = input_policy.resolve(input, .{
                    .terminal_preedit_active = self.preedit_text.items.len > 0,
                });
                switch (disp.pending) {
                    .leave => {},
                    // SPEC §4.1 — preedit 을 현재 값으로 확정(단축키 진입).
                    .commit => self.commitPendingInput(),
                    // #282 A5 §5.1 — Ctrl+C: 터미널 preedit 자모 폐기(SIGINT line abort,
                    // fcitx5 IME state 도 다음 typing 에서 reset).
                    .discard => {
                        self.pending_preedit.clearRetainingCapacity();
                        self.pending_commit.clearRetainingCapacity();
                        self.preedit_text.clearRetainingCapacity();
                        self.renderer.preedit_text = "";
                        self.needs_redraw = true;
                    },
                }
                switch (disp.target) {
                    .run_action => {
                        self.runShortcutForKey(sym, shift);
                        return;
                    },
                    // interrupt \x03 는 아래 escape / utf8 로. paste 는 위에서 처리.
                    .pty => {},
                }
            }
        }

        // ── 기존 PTY 경로 (정책 target=pty 또는 미분류 키) ──────────────
        if (sym_opt) |sym| {
            // Ctrl + 터미널 preedit(Ctrl+C 아님) → 자모를 PTY 로 commit 후 진행
            // (terminal readline 이 자모 먼저 받고 Ctrl byte 처리). Ctrl+C 는 위
            // interrupt 경로가 discard 로 처리하므로 여기 도달 안 함.
            if (ctrl and self.preedit_text.items.len > 0) self.commitPendingInput();
            // SPEC §2.5 — Shift+PgUp / Shift+PgDn scrollback (정책 아님 — 별도).
            if (shift and !ctrl and !alt and (sym == xkb_key_page_up or sym == xkb_key_page_down)) {
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
            if (terminalSequenceForKeysym(sym)) |seq| {
                self.queueInput(seq);
                return;
            }
        }

        var buf: [64]u8 = undefined;
        const bytes = self.keyboard.utf8(xkb_key, &buf);
        if (bytes.len > 0) self.queueInput(bytes);
    }

    /// #296 — resolve 가 run_action 으로 판정한 전역 단축키 실행. pending
    /// (preedit) commit 은 resolve 의 `.commit` 이 이미 처리하므로 여기선 action 만.
    fn runShortcutForKey(self: *Client, sym: u32, shift: bool) void {
        if (sym == xkb_key_c_lower or sym == xkb_key_c_upper) {
            self.copyActiveSelection();
        } else if (sym == xkb_key_t_lower or sym == xkb_key_t_upper) {
            self.handleNewTab();
        } else if (sym == xkb_key_w_lower or sym == xkb_key_w_upper) {
            self.handleCloseTab();
        } else if (sym == xkb_key_bracketright or sym == xkb_key_braceright) {
            self.handleNextTab();
        } else if (sym == xkb_key_bracketleft or sym == xkb_key_braceleft) {
            self.handlePrevTab();
        } else if (sym == xkb_key_i_lower or sym == xkb_key_i_upper) {
            // #213 — About 은 reentrancy 밖 drainAboutRequest 가 열도록 flag 만.
            self.pending_about_request = true;
        } else if (sym == xkb_key_p_lower or sym == xkb_key_p_upper) {
            const cfg_path = paths.configPath(self.allocator) catch return;
            defer self.allocator.free(cfg_path);
            system_open.openInDefaultApp(self.allocator, cfg_path);
        } else if (sym == xkb_key_l_lower or sym == xkb_key_l_upper) {
            const log_path = log.filePath() orelse return;
            system_open.openInDefaultApp(self.allocator, log_path);
        } else if (sym == xkb_key_r_lower or sym == xkb_key_r_upper) {
            if (self.session) |*session| {
                if (session.resetActive()) self.requestRedraw();
            }
        } else if (sym == xkb_key_f12) {
            perf.dumpAndReset("snapshot");
        } else if (sym == xkb_key_f4) {
            self.pending_quit_request = true;
        } else if (sym == xkb_key_return) {
            self.toggleFullscreen(if (shift) .avoid else .cover);
        } else if (sym >= xkb_key_1 and sym <= xkb_key_9) {
            self.handleSwitchTab(@intCast(sym - xkb_key_1));
        }
    }

    fn executeCommandMenu(self: *Client, command: command_menu.Command) void {
        self.closeCommandMenu();
        switch (command) {
            .toggle_visibility => self.handleActivatedToggle() catch |err| {
                log.appendLine("command-menu", "toggle failed: {s}", .{@errorName(err)});
            },
            .new_tab => self.handleNewTab(),
            .close_active_tab => self.handleCloseTab(),
            .copy_selection => self.copyActiveSelection(),
            .paste => self.requestPaste(),
            // #334 — 메뉴는 상태 기준 토글: 어떤 모드든 전체화면이면 그 모드를
            // 해제, 아니면 cover 진입 (키보드 self-symmetric 정책은 그대로).
            .fullscreen => self.toggleFullscreen(if (self.fullscreen_mode != .none) self.fullscreen_mode else .cover),
            .open_config => {
                const path = paths.configPath(self.allocator) catch return;
                defer self.allocator.free(path);
                system_open.openInDefaultApp(self.allocator, path);
            },
            .keyboard_shortcuts => system_open.openInDefaultApp(self.allocator, messages.keyboard_shortcuts_url),
            .about => self.pending_about_request = true,
        }
        self.needs_redraw = true;
    }

    /// #329 — 현재 viewport / scroll 기준의 menu View (renderer 와 같은 계산).
    fn commandMenuView(self: *const Client) command_menu.View {
        const scale = self.renderer.scale;
        return command_menu.view(
            @as(f32, @floatFromInt(self.window_width)) / scale,
            @as(f32, @floatFromInt(self.window_height)) / scale,
            @floatFromInt(ui_metrics.TAB_BAR_HEIGHT_PT),
            self.command_menu_first,
        );
    }

    /// #329 — 메뉴 닫기 공통 지점. focus / scroll / wheel 누적까지 초기화해
    /// 다음 열기가 항상 처음 상태에서 시작한다.
    fn closeCommandMenu(self: *Client) void {
        self.command_menu_open = false;
        self.command_menu_hover = null;
        self.command_menu_focus = null;
        self.command_menu_first = 0;
        self.command_menu_axis_remainder = 0;
        self.needs_redraw = true;
    }

    fn commandMenuHit(self: *const Client, x: i32, y: i32) ?command_menu.Command {
        if (!self.command_menu_open or x < 0 or y < 0) return null;
        // #329 — software renderer 의 draw 와 같은 `@round` px 경계로 판정.
        // pt 공간 비교는 1.7x 같은 fractional scale 에서 draw 의 round 와
        // 어긋나 경계에 ~1px dead band 가 생겼다 (pointer 는 정수 px).
        const scale = self.renderer.scale;
        const v = self.commandMenuView();
        const mx: i32 = @intFromFloat(@round(v.rect.x * scale));
        const my: i32 = @intFromFloat(@round(v.rect.y * scale));
        const mw: i32 = @intFromFloat(@round(v.rect.w * scale));
        const mh: i32 = @intFromFloat(@round(v.rect.h * scale));
        if (x < mx or x >= mx + mw or y < my or y >= my + mh) return null;
        for (v.first..v.first + v.count) |i| {
            const command = command_menu.entries[i] orelse continue;
            const r = command_menu.entryRect(v, i).?;
            const ix: i32 = @intFromFloat(@round(r.x * scale));
            const iy: i32 = @intFromFloat(@round(r.y * scale));
            const iw: i32 = @intFromFloat(@round(r.w * scale));
            const ih: i32 = @intFromFloat(@round(r.h * scale));
            if (x >= ix and x < ix + iw and y >= iy and y < iy + ih) return command;
        }
        return null;
    }

    /// #329 — 메뉴가 열린 동안의 키 입력 (Ctrl/Alt 조합은 호출 전에
    /// processKeyEvent 가 메뉴를 닫고 기존 단축키 경로로 보냄 — 여기 오는
    /// 키는 modifier 없는 navigation/문자뿐). 메뉴 계층이 소비한다 (native
    /// menu 동등) — PTY 로 보내지 않는다.
    fn handleCommandMenuKey(self: *Client, key: u32) void {
        const xkb_key = key + wayland_xkb_keycode_offset;
        const sym = self.keyboard.oneSym(xkb_key) orelse return;
        const shift = self.keyboard.shiftActive();
        const menu_key: command_menu.MenuKey = switch (sym) {
            0xff1b => .escape, // XKB_KEY_Escape
            0xff52 => .up, // XKB_KEY_Up
            0xff54 => .down, // XKB_KEY_Down
            0xff50 => .home, // XKB_KEY_Home
            0xff57 => .end, // XKB_KEY_End
            0xff09 => if (shift) command_menu.MenuKey.shift_tab else .tab, // XKB_KEY_Tab
            0xfe20 => .shift_tab, // XKB_KEY_ISO_Left_Tab (Shift+Tab)
            0xff0d, 0xff8d => .enter, // Return / KP_Enter
            ' ' => .space,
            else => .other,
        };
        switch (command_menu.onKey(menu_key, &self.command_menu_focus)) {
            .consumed => {
                // #334 — 키보드를 쓰는 순간 pointer hover 강조를 지운다.
                // 마우스가 항목 위에 머물러 있으면 hover 가 focus 를 덮어
                // 키보드 이동이 화면에 안 보였다 (사용자 시연 발견). 마우스를
                // 다시 움직이면 hover 가 재적용되며 focus 도 동기화된다.
                self.command_menu_hover = null;
                if (self.command_menu_focus) |focused| {
                    const scale = self.renderer.scale;
                    self.command_menu_first = command_menu.ensureVisible(
                        @as(f32, @floatFromInt(self.window_width)) / scale,
                        @as(f32, @floatFromInt(self.window_height)) / scale,
                        @floatFromInt(ui_metrics.TAB_BAR_HEIGHT_PT),
                        self.command_menu_first,
                        focused,
                    );
                }
                self.needs_redraw = true;
            },
            .close => self.closeCommandMenu(),
            .activate => |command| {
                // outside click 실행과 동일 — pending 입력 commit 후 실행.
                self.commitPendingInput();
                self.executeCommandMenu(command);
            },
        }
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
        log.appendLineVerbose("wayland", "keyboard repeat rate={} delay={}", .{ rate, delay });
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
        // #268 2b — 창 밖으로 나가면 hover 해제 (안 하면 강조 박스가 남음).
        if (self.tab_hover != .none) {
            self.tab_hover = .none;
            self.needs_redraw = true;
        }
        // #334 재감사 — 메뉴 항목 hover 도 창 이탈 시 해제 (keyboard focus
        // 는 유지 — 표준 메뉴의 마지막 selection 기억과 동일).
        if (self.command_menu_hover != null) {
            self.command_menu_hover = null;
            self.needs_redraw = true;
        }
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

        // Dialog 본문 scrollbar drag는 modal 입력이므로 terminal selection/tab
        // drag보다 먼저 처리한다. 다른 dialog motion도 뒤 terminal로 통과시키지 않는다.
        if (self.dialog.active()) {
            if (self.dialog.scrollbar_drag_grab != null) self.scrollDialogToPointer();
            return;
        }
        // #268 2b — 탭바 컨트롤 버튼 hover 갱신 (변경 시에만 재렌더).
        self.updateTabHover();

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
        // #245 — 경계 밖이어도 null 대신 clamp 된 cell 로 선택 연장 + 위/아래 경계면
        // auto-scroll 방향 arm. pixelToCell(클릭용, 범위 밖 null)과 분리.
        const sc = self.selectionCellAndDir(tab);
        tab.interaction.selection.update(tab.terminal.screens.active, sc.cell);
        const prev_dir = self.sel_autoscroll_dir;
        self.sel_autoscroll_dir = sc.dir;
        // 0→nonzero 전환이면 즉시 첫 tick (다음 run loop iteration 에서 스크롤 시작).
        if (sc.dir != 0 and prev_dir == 0) self.sel_autoscroll_next_ms = 0;
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
        // surface 위 + OK / Cancel 버튼 좌표 안* 의 누름만 dismiss 트리거이고,
        // About overflow scrollbar는 왼쪽 누름/drag만 자체 처리한다.
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
            log.appendLineVerbose("dialog", "pointer button kind={s} state={d} button=0x{x} last_enter={} dialog_surface={} pointer_xy=({},{})", .{
                @tagName(self.dialog.kind),
                state,
                button,
                self.last_pointer_enter_surface_id,
                self.dialog.surface_id,
                self.pointer_x_px,
                self.pointer_y_px,
            });
            if (button == wl_pointer_button_left and state == wl_pointer_button_state_released) {
                self.dialog.scrollbar_drag_grab = null;
                return;
            }
            if (state == wl_pointer_button_state_pressed and
                self.last_pointer_enter_surface_id == self.dialog.surface_id)
            {
                if (button == wl_pointer_button_left and
                    self.hitDialogRect(self.renderer.last_dialog_scrollbar_hit_rect) and
                    self.beginDialogScrollbarDrag())
                {
                    return;
                } else if (self.hitDialogRect(self.renderer.last_dialog_ok_rect)) {
                    log.appendLineVerbose("dialog", "OK hit — dismiss request", .{});
                    if (self.dialog.kind == .confirm) self.pending_confirm_result = true;
                    if (self.dialog.kind == .prompt and self.validatePromptInput()) self.pending_prompt_result = true;
                    if (self.dialog.kind == .prompt and self.pending_prompt_result == null) return;
                    self.requestDismissDialog();
                } else if (self.hitDialogRect(self.renderer.last_dialog_cancel_rect)) {
                    log.appendLineVerbose("dialog", "Cancel hit — dismiss request", .{});
                    if (self.dialog.kind == .confirm) self.pending_confirm_result = false;
                    if (self.dialog.kind == .prompt) self.pending_prompt_result = false;
                    self.requestDismissDialog();
                } else {
                    log.appendLineVerbose("dialog", "button in dialog area but no OK/Cancel rect hit (ok={any} cancel={any})", .{ self.renderer.last_dialog_ok_rect, self.renderer.last_dialog_cancel_rect });
                }
            } else if (state == wl_pointer_button_state_pressed) {
                log.appendLineVerbose("dialog", "button rejected — enter_surface mismatch (need {} got {})", .{ self.dialog.surface_id, self.last_pointer_enter_surface_id });
            }
            return;
        }

        if (button == wl_pointer_button_right) {
            // #329 — 열린 menu 는 모든 pointer button 보다 우선. 우클릭은
            // 메뉴만 닫고 paste 하지 않는다 (SPEC §5.3 — menu 밖 click 은 닫고
            // 해당 click 은 terminal 에 전달하지 않음).
            if (self.command_menu_open) {
                if (state == wl_pointer_button_state_pressed) self.closeCommandMenu();
                return;
            }
            // 우클릭 — pressed edge 에서 paste (cmd.exe console 표준 + Windows /
            // macOS 와 같은 정책. SPEC.md §3). #333 — preedit 정책은 requestPaste.
            if (state == wl_pointer_button_state_pressed) self.requestPaste();
            return;
        }
        if (button != wl_pointer_button_left) return;

        const tab = self.activeTabOrNull() orelse return;
        switch (state) {
            wl_pointer_button_state_pressed => {
                if (self.command_menu_open) {
                    // #334 — 스크롤 표시 행 클릭 = 한 entry 스크롤, 메뉴 유지.
                    {
                        const menu_view = self.commandMenuView();
                        const s = self.renderer.scale;
                        const px_pt = @as(f32, @floatFromInt(self.pointer_x_px)) / s;
                        const py_pt = @as(f32, @floatFromInt(self.pointer_y_px)) / s;
                        if (command_menu.hitScrollIndicator(menu_view, px_pt, py_pt)) |dir| {
                            self.command_menu_first = command_menu.scrollStep(menu_view, dir == .down);
                            self.needs_redraw = true;
                            return;
                        }
                    }
                    const hit = self.commandMenuHit(self.pointer_x_px, self.pointer_y_px);
                    self.closeCommandMenu();
                    // #329 — menu 위 클릭(항목 실행)이든 외부 클릭(close)이든
                    // outside click — 진행 중 입력(cell preedit)을 먼저
                    // commit. macOS tildazMouseDown 의 공통 commit 지점과 동등.
                    self.commitPendingInput();
                    if (hit) |command| self.executeCommandMenu(command);
                    return;
                }
                if (self.session.?.count() == 1) {
                    switch (self.singleControlHit(self.pointer_x_px, self.pointer_y_px)) {
                        .plus => {
                            tab.interaction.cancelPointerModes();
                            self.handleNewTab();
                            return;
                        },
                        .close => {
                            tab.interaction.cancelPointerModes();
                            self.handleCloseTab();
                            return;
                        },
                        .more => {
                            tab.interaction.cancelPointerModes();
                            self.commitPendingInput();
                            self.command_menu_open = !self.command_menu_open;
                            self.command_menu_hover = null;
                            self.needs_redraw = true;
                            return;
                        },
                        else => {},
                    }
                }
                // L12-β/γ — tab bar 영역 클릭 → tab_layout.hitArea 로 분기.
                // 다른 모든 pointer mode (scrollbar / selection / 더블클릭)
                // 보다 *우선* 검사 — tab bar 안에서 selection drag 안 시작.
                if (self.pointer_y_px >= 0 and self.pointer_y_px < self.effectiveTabBarHeightPx()) {
                    self.handleTabBarClick(self.pointer_x_px, self.pointer_y_px);
                    return;
                }
                // 우측 스크롤바 영역 클릭 — selection / 더블클릭 보다 우선.
                // Windows `app_controller.zig:835` 와 동등.
                if (self.pointer_x_px >= self.window_width - self.renderer.scrollbarWPx()) {
                    // #282 A6 — SPEC §4.1 "영역 무관 mouse_down = commit".
                    // 스크롤바 click 도 preedit 을 확정한다(Windows/macOS 동등).
                    self.commitPendingInput();
                    tab.interaction.scrollbar.begin(self.scrollbarGrabAt(self.pointer_y_px));
                    self.scrollToY(self.pointer_y_px);
                    return;
                }

                // L12-γ-2 — cell 영역 클릭 진입 시 commitPendingInput.
                // preedit 보존.
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
                // #245 — 어떤 release 든 drag-select auto-scroll 해제 (선택 끝/취소).
                self.sel_autoscroll_dir = 0;
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
                                log.appendLine("tab", "reorder failed: {s}", .{@errorName(err)});
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

    /// 현재 활성 탭의 scrollbar `Hit` (track + thumb geometry). 스크롤백이 없거나
    /// thumb 여유가 없으면 null. 렌더러(`software_terminal.zig`)와 같은
    /// `scrollbar.hit` 입력을 써서 그림 영역과 클릭 영역을 일치시킨다 (#259).
    /// track_top 은 `tab_bar_h + pad` — 이전엔 탭바 높이를 빼지 않아 멀티탭에서
    /// 스크롤바 클릭이 탭바 높이만큼 어긋났다.
    fn scrollbarHit(self: *Client) ?scrollbar.Hit {
        const tab = self.activeTabOrNull() orelse return null;
        const sb = tab.terminal.screens.active.pages.scrollbar();
        return scrollbar.hit(
            sb.total,
            sb.len,
            sb.offset,
            @floatFromInt(self.window_height),
            @floatFromInt(self.scrollbarTopInsetPx()),
            @floatFromInt(self.renderer.paddingPx()),
            @floatFromInt(self.renderer.scrollbarMinThumbHPx()),
        );
    }

    /// mouse-down 시 grab offset (#259). 스크롤바 없으면 0.
    fn scrollbarGrabAt(self: *Client, mouse_y: i32) f64 {
        const h = self.scrollbarHit() orelse return 0;
        return h.grab(@floatFromInt(mouse_y));
    }

    /// 스크롤바 드래그 시 thumb 위치 따라 viewport scroll. grab offset 은 down 때
    /// `scrollbar.begin` 으로 저장된 값을 사용 — thumb 어디를 잡아도 그 지점이
    /// 커서 아래 고정돼 따라온다 (#259, 이전엔 thumb 윗변이 커서로 점프).
    fn scrollToY(self: *Client, mouse_y: i32) void {
        const tab = self.activeTabOrNull() orelse return;
        const h = self.scrollbarHit() orelse return;
        const target_row = h.target(@floatFromInt(mouse_y), tab.interaction.scrollbar.grab_offset);
        const delta = @as(isize, @intCast(target_row)) - @as(isize, @intCast(h.offset));
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

        if (self.dialog.active()) {
            if (self.dialog.message_scroll_max > 0 and
                self.last_pointer_enter_surface_id == self.dialog.surface_id)
            {
                self.dialog.scroll_axis_remainder_fixed += @as(i64, value_fixed);
                const rows = @divTrunc(self.dialog.scroll_axis_remainder_fixed * 3, 2560);
                if (rows != 0) {
                    self.dialog.scroll_axis_remainder_fixed -= @divTrunc(rows * 2560, 3);
                    // Wayland positive axis = 아래로 이동 = 더 뒤의 본문 행 표시.
                    self.scrollDialogRows(@intCast(rows));
                }
            }
            return;
        }

        // #329 — 열린 menu 는 wheel 도 소비한다. 작은 viewport 에서 잘린
        // 항목에 pointer 로 도달하는 경로 (entry 단위 scroll). terminal
        // scrollback 으로 보내지 않는다.
        if (self.command_menu_open) {
            self.command_menu_axis_remainder += @as(i64, value_fixed);
            var steps = @divTrunc(self.command_menu_axis_remainder, 2560);
            self.command_menu_axis_remainder -= steps * 2560;
            while (steps != 0) {
                const down = steps > 0; // Wayland positive axis = 아래
                const next = command_menu.scrollStep(self.commandMenuView(), down);
                if (next == self.command_menu_first) break;
                self.command_menu_first = next;
                self.needs_redraw = true;
                steps += if (down) @as(i64, -1) else 1;
            }
            return;
        }

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
    /// #333 — paste semantic entry. 우클릭(BTN_RIGHT) / keyboard / command menu 가
    /// 공통으로 이걸 거쳐 input_policy.resolve(.paste)를 정확히 한 번 적용한다.
    /// terminal preedit 이면 먼저 commit(자모 flush 로 '하'+'X' 순서 보존,
    /// #282 A2/A4).
    fn requestPaste(self: *Client) void {
        const disp = input_policy.resolve(.paste, .{
            .terminal_preedit_active = self.preedit_text.items.len > 0,
        });
        switch (disp.pending) {
            .leave => {},
            // terminal preedit — commit 후 PTY paste ('하X', #282 A4/A2).
            .commit => self.commitPendingInput(),
            // paste 정책에 discard 없음 (input_policy.resolve 참고).
            .discard => unreachable,
        }
        self.pasteFromClipboard();
    }

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
                // PTY paste (cross-platform tab_actions.routePaste 단일 구현.
                // Windows/macOS 동등).
                var host = self.buildTabActionsHost();
                tab_actions.routePaste(&host, text);
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
        if (self.session != null) {
            // PTY 로 라우팅. routePaste 단일 구현.
            var host = self.buildTabActionsHost();
            tab_actions.routePaste(&host, accumulated.items);
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
        // ghostty selectionString 은 *우리가 넘긴 allocator* 로 결과를 할당하고 그
        // ownership 을 caller(우리)에게 준다 (ghostty Screen.zig doc 명시: "owned by
        // the caller and allocated using alloc"). 따라서 우리가 free 해야 한다 — 안
        // 하면 누수(#235, 종료 시 GPA leak 리포트로 확인). 반환 타입은 sentinel slice
        // ([:0]const u8, 할당 = len+1) 라 *그 타입 그대로* free 해야 길이가 맞다(defer).
        // clipboard 에는 sentinel 없는 []u8 dupe 본을 보관한다 — setClipboardText 가
        // []const u8 (길이 N) 로 free 하므로, sentinel 본(N+1)을 그대로 넘기면 길이
        // 불일치 free 가 난다(이게 #189 에서 "invalid free panic" 으로 보였던 증상 —
        // ownership 이 ghostty arena 라서가 아니라 sentinel 길이 불일치였음).
        const ghostty_text = screen.selectionString(self.allocator, .{ .sel = sel }) catch return;
        defer self.allocator.free(ghostty_text);
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

    /// #245 — 선택 드래그용 포인터→cell. `pixelToCell`(클릭용, 범위 밖 null)과 달리
    /// 경계 밖이어도 가장자리로 clamp 한 cell + 위/아래 경계 방향(dir)을 함께 반환.
    /// 음수 좌표를 위해 `@divFloor` 사용(py < grid_top 이면 row 가 음수 → dir=-1).
    fn selectionCellAndDir(self: *Client, tab: *session_core.Tab) struct { cell: terminal_interaction.Cell, dir: i8 } {
        const pad = self.renderer.paddingPx();
        const grid_top: i32 = self.effectiveTabBarHeightPx() + pad;
        const cw = self.renderer.cellWidth();
        const ch = self.renderer.cellHeight();
        const cols: u16 = tab.terminal.cols;
        const rows: u16 = tab.terminal.rows;
        const col_i32: i32 = @divFloor(self.pointer_x_px - pad, cw);
        const row_i32: i32 = @divFloor(self.pointer_y_px - grid_top, ch);
        return .{
            .cell = terminal_interaction.clampCell(col_i32, row_i32, cols, rows),
            .dir = terminal_interaction.edgeScrollDir(row_i32, rows),
        };
    }

    /// #245 — drag-select auto-scroll tick (main loop 매 iteration 호출). 포인터가
    /// grid 위/아래 경계 밖(dir!=0)이고 선택 활성이면 주기적으로 viewport 를 dir
    /// 방향으로 한 step 스크롤 + 마지막 포인터 위치(clamp cell)로 selection.update
    /// → 포인터를 멈춰 둬도 scrollback 까지 선택이 따라 연장된다. key repeat tick 과
    /// 같은 timestamp-gate 패턴.
    fn maybeAutoScrollSelection(self: *Client) void {
        if (self.sel_autoscroll_dir == 0) return;
        const tab = self.activeTabOrNull() orelse {
            self.sel_autoscroll_dir = 0;
            return;
        };
        if (!tab.interaction.selection.active) {
            self.sel_autoscroll_dir = 0;
            return;
        }
        const now = std.time.milliTimestamp();
        if (now < self.sel_autoscroll_next_ms) return;
        // scrollViewport: delta<0 = older(위로), >0 = newer(아래로).
        const delta: isize = if (self.sel_autoscroll_dir < 0) -sel_autoscroll_step else sel_autoscroll_step;
        tab.terminal.scrollViewport(.{ .delta = delta });
        // 스크롤 뒤 가장자리 cell 로 선택 end 재계산 — 새로 보이는 scrollback 행을 가리킴.
        const sc = self.selectionCellAndDir(tab);
        tab.interaction.selection.update(tab.terminal.screens.active, sc.cell);
        self.requestRedraw();
        self.sel_autoscroll_next_ms = now + sel_autoscroll_interval_ms;
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
            // #282 A8 — Ctrl+C(ETX 0x03) 는 write_queue 우회 즉시 송신(SIGINT). 대량
            // paste 로 큐가 가득 차면 SIGINT 가 뒤에 밀려 늦게 도착하는 것을 막는다
            // (macOS/Windows 동등). 단독 0x03 = Ctrl+C (nav 키는 multi-byte escape).
            if (bytes.len == 1 and bytes[0] == 0x03) {
                session.interruptActive(bytes);
            } else {
                session.queueInputToActive(bytes);
            }
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

        // Dialog active/retired buffer도 main surface와 같은 release 수명으로
        // 관리한다. 현재 표시 중인 buffer는 compositor가 release하지 않을 수
        // 있으므로 입력 갱신 때 새 buffer로 교체하고, 여기서 이전 것을 회수한다.
        if (self.dialog.active_buffer) |*buffer| {
            if (buffer.id == id) {
                buffer.released = true;
                return true;
            }
        }
        for (self.dialog.retired_buffers.items, 0..) |*buffer, i| {
            if (buffer.id == id) {
                self.destroyBufferObject(buffer.id);
                buffer.deinit();
                _ = self.dialog.retired_buffers.orderedRemove(i);
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
        // #241/#295 — wl_output 의 global 추가(모니터 연결/재구성). 이번 batch
        // 안에서 들어오는 layer-surface closed 는 사용자 Alt+F4 가 아니라 output
        // re-home 이다 → drain 단계에서 quit 대신 recreate 로 전환(batch-local 판정).
        // #295: 모든 wl_output 을 `outputs` slot 에 기록. startup registry dump 는
        // bindGlobals 가 일괄 bind, 그 이후 (hotplug 연결/재연결) 는 여기서 즉시
        // bind — 새 output 이 geometry/mode/scale/done 자동 발신 → handleOutputEvent
        // 가 slot 갱신 (+기준 output 이면 screen dims/scale 재동기).
        if (std.mem.eql(u8, interface, "wl_output")) {
            self.output_topology_pending = true;
            const slot = self.findOutputSlot(.{ .global_name = name }) orelse self.findOutputSlot(.empty) orelse {
                log.appendLine("wayland", "wl_output name={} ignored — {} tracked outputs 초과 (#295)", .{ name, max_tracked_outputs });
                return;
            };
            if (slot.global_name == 0) slot.* = .{ .global_name = name, .version = version };
            if (self.globals_bound and slot.object_id == 0) {
                slot.object_id = self.allocId();
                self.bind(slot.global_name, "wl_output", @min(slot.version, 2), slot.object_id) catch |err| {
                    log.appendLine("wayland", "wl_output bind failed: {s} (#241)", .{@errorName(err)});
                    slot.* = .{};
                    return;
                };
                if (self.output_id == 0) self.output_id = slot.object_id;
                log.appendLine("wayland", "wl_output bound after hotplug name={} object_id={} (#241/#295)", .{ slot.global_name, slot.object_id });
            }
        }
    }

    /// #295 — `outputs` slot 조회. `.empty` = 빈 slot, `.global_name`/`.object_id`
    /// = 해당 키 매칭.
    const OutputSlotKey = union(enum) { empty, global_name: u32, object_id: u32 };
    fn findOutputSlot(self: *Client, key: OutputSlotKey) ?*OutputSlot {
        for (&self.outputs) |*slot| {
            switch (key) {
                .empty => if (slot.global_name == 0) return slot,
                .global_name => |n| if (slot.global_name != 0 and slot.global_name == n) return slot,
                .object_id => |id| if (slot.object_id != 0 and slot.object_id == id) return slot,
            }
        }
        return null;
    }

    /// #295 — 현재 layout/scale 계산 기준 output 의 object id.
    /// wl_surface.enter 로 확정된 output 최우선, 없으면 첫 bind output.
    fn basisOutputObjectId(self: *const Client) u32 {
        if (self.current_output_object_id != 0) return self.current_output_object_id;
        return self.output_id;
    }

    /// #241/#295 — `wl_registry.global_remove` (opcode 1). payload = 제거된
    /// global name (u32). 우리가 bind 한 wl_output 이 사라진 경우(모니터 분리 등):
    /// (1) output_topology_pending set — 이번 batch 의 layer-surface closed 를
    ///     quit 아닌 output 변화로 보게 함(판정은 main loop drain, batch-local).
    /// (2) 해당 slot clear. wl_output 은 v≤2 로 bind 해 release(v3) destructor 가
    ///     없으므로 proxy id 는 그냥 버린다(server 측 이미 소멸).
    ///     screen_width/height 는 대체 output 의 mode event 또는 재생성 surface 의
    ///     enter 가 갱신할 때까지 last-known 유지 — replug 전 transient fallback
    ///     layout 회피.
    /// (3) #295: 기준 output 이 제거됐으면 기준을 남은 첫 output 으로 fall back.
    fn handleRegistryGlobalRemove(self: *Client, payload: []const u8) void {
        if (payload.len < 4) return;
        const name = readU32(payload[0..4]);
        const slot = self.findOutputSlot(.{ .global_name = name }) orelse {
            log.appendLineVerbose("wayland", "registry global_remove name={} (not bound output) (#241)", .{name});
            return;
        };
        const removed_object_id = slot.object_id;
        slot.* = .{};
        self.output_topology_pending = true;
        if (self.current_output_object_id == removed_object_id) self.current_output_object_id = 0;
        if (self.output_id == removed_object_id) {
            self.output_id = 0;
            for (&self.outputs) |*s| {
                if (s.object_id != 0) {
                    self.output_id = s.object_id;
                    break;
                }
            }
        }
        log.appendLine("wayland", "bound wl_output removed name={} object_id={} — slot cleared, topology_pending set (#241/#295)", .{ name, removed_object_id });
    }

    fn handleDisplayError(_: *Client, payload: []const u8) !void {
        if (payload.len < 12) return error.WaylandDisplayError;
        const object_id = readU32(payload[0..4]);
        const code = readU32(payload[4..8]);
        var p = Parser{ .buf = payload[8..] };
        const msg = p.readString() catch "(unparseable)";
        log.appendLine("wayland", "protocol error object={} code={} message={s}", .{ object_id, code, msg });
        return error.WaylandDisplayError;
    }

    /// #244 — KDE Plasma에서만 session bus에 연결해 KGlobalAccel에 direct
    /// 등록한다. 다른 desktop은 launcher/extension/compositor가 `--toggle N`
    /// IPC를 호출하므로 worker에서 D-Bus hotkey client를 만들지 않는다.
    /// 연결·등록 실패는 fatal이 아니며 hidden_start는 즉시 표시로 fallback한다.
    fn tryConnectKGlobalAccel(self: *Client) void {
        if (!kglobalaccel.isCurrentDesktop()) return;
        const session = dbus.SessionBus.connect() catch |err| {
            log.appendLine("dbus", "session bus connect skipped: {s} — hotkey disabled", .{@errorName(err)});
            return;
        };
        self.dbus_session = session;
        // direct 등록이 성공한 뒤에만 hidden_start가 surface 생성을 미룬다.
        kglobalaccel.cleanupLegacyIdentity(self.allocator, &self.dbus_session.?);
        const client = kglobalaccel.Client.create(
            self.allocator,
            &self.dbus_session.?,
            self.config.hotkey.keysym,
            self.config.hotkey.modifiers,
            onKGlobalAccelPressed,
            self,
        ) catch |err| {
            log.appendLine("kglobalaccel", "direct hotkey registration failed: {s} — hotkey disabled", .{@errorName(err)});
            return;
        };
        self.kglobalaccel_client = client;
    }

    /// main loop 매 iteration 마다 D-Bus message를 dispatch.
    /// `read_write_dispatch(conn, 0)` 는 socket 의 pending data read + 누적된
    /// message dispatch (filter callback 호출 포함) + 0 timeout 이라 즉시 반환.
    /// dbus fd 를 wayland fd 와 함께 poll 통합하는 대신 매 iteration 0-timeout
    /// dispatch 호출 — frame_poll_ms (16ms) 가 wayland poll timeout 이라 hotkey
    /// latency 도 같은 수준으로 충분 (60Hz 한 frame).
    fn dispatchDbusMessages(self: *Client) void {
        if (self.dbus_session) |*bus| {
            const r = bus.api.read_write_dispatch(bus.conn, 0);
            // r == 0 은 connection disconnected — fatal 아니지만 KDE hotkey 더 안 옴.
            if (r == 0) {
                log.appendLine("dbus", "connection disconnected — KDE hotkey routing stopped", .{});
            }
        }
        if (self.kglobalaccel_client) |client| {
            client.drainOwnerRestart(self.config.hotkey.keysym, self.config.hotkey.modifiers);
        }
        if (self.kglobalaccel_toggle_pending) {
            self.kglobalaccel_toggle_pending = false;
            self.handleActivatedToggle() catch |err| {
                log.appendLine("kglobalaccel", "toggle failed: {s}", .{@errorName(err)});
            };
        }
    }

    fn onKGlobalAccelPressed(user_data: ?*anyopaque, timestamp: i64) void {
        const self: *Client = @ptrCast(@alignCast(user_data.?));
        log.appendLineVerbose("kglobalaccel", "globalShortcutPressed received timestamp={}", .{timestamp});
        self.kglobalaccel_toggle_pending = true;
    }

    /// surface visibility flip. mac `toggleWindow` 동등 — hide 시점에
    /// `commitPendingInput` (preedit 보존). show 는 `mapped=false`
    /// + `requestRedraw` 로 maybeRedraw 가 buffer 다시 attach (자연 re-map).
    ///
    /// hide / show — wl_surface + layer_surface (또는 xdg_toplevel + xdg_surface)
    /// 둘 다 destroy / recreate.
    ///
    /// 배경:
    /// - [wlr-layer-shell spec](https://wayland.app/protocols/wlr-layer-shell-unstable-v1)
    ///   는 "perform a commit without any buffer attached, waiting for a
    ///   configure event" 로 re-map 가능하다고 명시.
    /// - KDE Plasma 6.6.5 시연에서 그 sequence
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
            // #205 — show phase elapsed timer. hotkey activation → first frame.
            // configure handler / ensureSessionGrid / redraw 가 후속 호출에서
            // 발생하므로 그 site 에 별도 logShowElapsed.
            self.show_timer = std.time.Timer.start() catch null;
            self.surface_hidden = false;
            // 첫 show (hidden_start=true 의 첫 hotkey activation) 면 surface 아직
            // 안 만들어졌으므로 full create. 이후 hide/show cycle 은 unmap/remap
            // path (#205 — wl_surface + layer_surface 유지가 ~165ms → ~16ms 줄임,
            // KWin Bug 503121 의 kitty workaround pattern).
            if (self.surface_id == 0) {
                try self.createShellObjects();
                self.logShowElapsed("createShellObjects (first show)");
                log.appendLine("toggle", "show — created shell objects (first)", .{});
            } else {
                try self.remapShellObjects();
                self.logShowElapsed("remapShellObjects");
                // per-toggle — verbose (#197 Option B, 3 플랫폼 공통 category "toggle").
                log.appendLineVerbose("toggle", "show — remapped shell objects (#205)", .{});
            }
            return;
        }
        // hide 진입 — mac #175 동등 정책: preedit commit (cancel
        // 아님), 다음 show 때 사용자가 이어서 작업 가능.
        self.commitPendingInput();
        // #329 — 열린 menu 는 hide 때 닫는다. global hotkey 로 show 했을 때
        // 이전 menu 가 남아 있지 않게 (transient overlay 는 복원 대상 아님).
        if (self.command_menu_open) self.closeCommandMenu();
        // hide/show 재표시는 **기본이 destroy/recreate** (다음 show 는 surface_id==0
        // → createShellObjects, 첫 show 와 동일 경로 = 모든 compositor 에서 동작).
        // 단 KWin 만 surface 재생성이 ~165ms 로 느려(Bug 503121) #205 의 unmap→remap
        // (wl_surface/layer_surface 유지) 워크어라운드를 쓴다 — 예외는 버그 있는 KWin
        // 한 곳뿐. (smithay/cosmic-comp 은 remap 미지원 #230, wlroots 는 recreate 도 빠름.)
        // 세션(PTY/shell)은 destroyShellObjects 가 안 건드림 → 재표시 후 그대로 유지.
        if (kwinCompositor()) {
            try self.unmapShellObjects();
            self.surface_hidden = true;
            // per-toggle — verbose (#197 Option B, 3 플랫폼 공통 category "toggle").
            log.appendLineVerbose("toggle", "hide — unmapped shell objects (#205 KWin 503121 workaround)", .{});
            return;
        }
        try self.destroyShellObjects();
        self.surface_hidden = true;
        log.appendLineVerbose("toggle", "hide — destroyed shell objects (recreate path)", .{});
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
        // #295 — unmap 하면 output 소속이 무효 (remap 시 새 enter 를 받는다). stale
        // entered flag 를 남기면 다른 output 으로 재소환해도 옛 basis 를 유지해
        // 폭/dims 가 안 바뀐다 (sway focus 이동 후 hide/show 실측). clear.
        for (&self.outputs) |*s| s.entered = false;
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
            try self.sendLayerSurfaceLayout(false);
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
        // #351 — 이 surface 의 초기 안전 configure 는 이제 오지 않는다 (surface destroy).
        // 남겨두면 다음 surface 의 첫 실제 layout 송신이 보류 조건에 걸린다.
        self.initial_safe_pending = false;
        // issue #196: surface destroy → 이전 frame callback 은 더 이상 fire
        // 안 함 (surface 가 사라졌으니 compositor 가 callback 발신 안 함).
        // 재생성 (show) 후 첫 redraw 가 막히지 않도록 reset.
        self.frame_callback_id = 0;
        self.awaiting_frame = false;
    }

    fn dialogViewportPhysicalSize(self: *const Client) dialog_layout.Size {
        return .{
            .w = if (self.screen_width > 0) self.screen_width else screen_fallback_width,
            .h = if (self.screen_height > 0) self.screen_height else screen_fallback_height,
        };
    }

    fn dialogLayoutKind(kind: DialogOverlay.Kind) dialog_layout.Kind {
        return switch (kind) {
            .none, .info => .info,
            .about => .about,
            .confirm => .confirm,
            .prompt => .prompt,
        };
    }

    fn computeCurrentDialogLayout(self: *const Client) dialog_layout.Layout {
        const viewport = self.dialogViewportPhysicalSize();
        return self.renderer.computeDialogLayout(
            self.dialog.title(),
            self.dialog.message(),
            dialogLayoutKind(self.dialog.kind),
            viewport.w,
            viewport.h,
        );
    }

    fn applyCurrentDialogLayout(self: *Client) dialog_layout.Layout {
        const layout = self.computeCurrentDialogLayout();
        self.dialog.wrap_cells = layout.wrap_cells;
        self.dialog.message_rows = layout.message_rows;
        self.dialog.visible_message_rows = layout.visible_message_rows;
        self.dialog.message_scroll_max = layout.message_scroll_max;
        self.dialog.message_scroll_row = @min(self.dialog.message_scroll_row, layout.message_scroll_max);
        self.dialog.show_icon = layout.show_icon;
        self.dialog.layout_fits = layout.fits;
        return layout;
    }

    fn applyCurrentDialogLayoutForSurface(self: *Client, surface: dialog_layout.Size) dialog_layout.Layout {
        const layout = self.renderer.computeDialogLayoutForSurface(
            self.dialog.title(),
            self.dialog.message(),
            dialogLayoutKind(self.dialog.kind),
            surface.w,
            surface.h,
        );
        self.dialog.wrap_cells = layout.wrap_cells;
        self.dialog.message_rows = layout.message_rows;
        self.dialog.visible_message_rows = layout.visible_message_rows;
        self.dialog.message_scroll_max = layout.message_scroll_max;
        self.dialog.message_scroll_row = @min(self.dialog.message_scroll_row, layout.message_scroll_max);
        self.dialog.show_icon = layout.show_icon;
        self.dialog.layout_fits = layout.fits;
        return layout;
    }

    fn sendDialogSurfaceLayout(self: *Client, source: []const u8) !void {
        if (!self.dialog.active() or self.dialog.surface_id == 0) return;

        const layout = self.applyCurrentDialogLayout();
        const logical_w: u32 = @intCast(self.physicalToLogicalCeil(layout.size.w));
        const logical_h: u32 = @intCast(self.physicalToLogicalCeil(layout.size.h));

        if (self.dialog.layer_surface_id != 0) {
            try self.sendArgs(
                self.dialog.layer_surface_id,
                zwlr_layer_surface_v1_request_set_size,
                &.{ logical_w, logical_h },
            );
            // anchor=0이면 compositor가 현재 output 중앙에 배치한다. main 창의
            // dock/width_percent margin과 분리해 오른쪽 50% 설정에도 화면 중앙 유지.
            try self.sendArgs(
                self.dialog.layer_surface_id,
                zwlr_layer_surface_v1_request_set_anchor,
                &.{0},
            );
            var margin = Msg.init(self.dialog.layer_surface_id, zwlr_layer_surface_v1_request_set_margin);
            try margin.putI32(0);
            try margin.putI32(0);
            try margin.putI32(0);
            try margin.putI32(0);
            try margin.send(self.stream);
        } else if (self.dialog.xdg_toplevel_id != 0) {
            try self.sendArgs(self.dialog.xdg_toplevel_id, 7, &.{ logical_w, logical_h });
            try self.sendArgs(self.dialog.xdg_toplevel_id, 8, &.{ logical_w, logical_h });
            self.dialog.pending_w_logical = logical_w;
            self.dialog.pending_h_logical = logical_h;
        } else {
            // createDialogSurface의 fractional-scale roundtrip 중 아직 role을
            // 만들기 전이면 caller가 갱신된 scale로 최초 요청을 계산한다.
            return;
        }

        try self.sendNoArgs(self.dialog.surface_id, 6);
        log.appendLine("dialog", "relayout source={s} logical={}x{} wrap_cells={} icon={} fits={}", .{
            source,
            logical_w,
            logical_h,
            layout.wrap_cells,
            layout.show_icon,
            layout.fits,
        });
    }

    /// #203 Phase C — info / error dialog 표시. content 저장 + box 크기 계산 →
    /// dialog surface 생성 (이미 떠 있으면 새 크기로 재생성). cross-platform
    /// `dialog.showInfo` / `dialog.showAboutAlert` 등의 종착점 (dialog/linux.zig
    /// callback 통과). fire-and-forget — 사용자가 Enter / Esc / 클릭으로 dismiss.
    fn openInfoDialog(self: *Client, severity: dialog_mod.Severity, title: []const u8, message: []const u8) !void {
        try self.openDialog(.info, severity, title, message);
    }

    fn openAboutDialog(self: *Client, title: []const u8, message: []const u8) !void {
        try self.openDialog(.about, .info, title, message);
    }

    /// #203 Phase C step 4 — confirm dialog (OK + Cancel). `dialogShowConfirmCb`
    /// 의 inner pump 가 결과 (`pending_confirm_result`) 를 받아 호출자에게 반환.
    /// dismiss 전 default `pending_confirm_result = null` — Cancel 등 명시 결정.
    fn openConfirmDialog(self: *Client, title: []const u8, message: []const u8) !void {
        try self.openDialog(.confirm, .info, title, message);
    }

    fn openPromptDialog(self: *Client, title: []const u8, message: []const u8) !void {
        self.dialog.input_len = 0;
        self.dialog.status_len = 0;
        self.dialog.prompt_available = false;
        self.pending_prompt_result = null;
        try self.openDialog(.prompt, .info, title, message);
        try self.createPromptShortcutsInhibitor();
    }

    fn createPromptShortcutsInhibitor(self: *Client) !void {
        if (self.keyboard_shortcuts_inhibit_manager_id == 0 or self.seat_id == 0 or self.dialog.surface_id == 0) return;
        std.debug.assert(self.prompt_shortcuts_inhibitor_id == 0);
        self.prompt_shortcuts_inhibitor_id = self.allocId();
        try self.sendArgs(
            self.keyboard_shortcuts_inhibit_manager_id,
            keyboard_shortcuts_inhibit_manager_request_inhibit_shortcuts,
            &.{ self.prompt_shortcuts_inhibitor_id, self.dialog.surface_id, self.seat_id },
        );
        log.appendLineVerbose("dialog", "keyboard shortcuts inhibitor requested for prompt surface_id={}", .{self.dialog.surface_id});
    }

    fn openDialog(self: *Client, kind: DialogOverlay.Kind, severity: dialog_mod.Severity, title: []const u8, message: []const u8) !void {
        const message_owned = self.allocator.dupe(u8, message) catch null;

        const title_len = @min(title.len, self.dialog.title_buf.len);
        @memcpy(self.dialog.title_buf[0..title_len], title[0..title_len]);
        self.dialog.title_len = title_len;
        if (self.dialog.message_owned) |old| self.allocator.free(old);
        self.dialog.message_owned = message_owned;
        self.dialog.msg_len = if (self.dialog.message_owned) |owned|
            owned.len
        else
            dialog_linux.copyMessage(&self.dialog.msg_buf, message);
        self.dialog.kind = kind;
        self.dialog.severity = severity;
        self.dialog.message_scroll_row = 0;
        self.dialog.scrollbar_drag_grab = null;
        self.dialog.repaint_requested = false;
        self.dialog.scroll_axis_remainder_fixed = 0;
        if (self.dialog.msg_len != message.len) {
            log.appendLine("dialog", "message truncated at UTF-8 boundary original_len={} stored_len={} capacity={}", .{
                message.len,
                self.dialog.msg_len,
                dialog_linux.message_capacity,
            });
        }
        // Confirm pending 새로 시작 — 이전 dialog 의 result 가 남아 있을 가능성 0.
        self.pending_confirm_result = null;

        // #368 — dialog 폰트를 여기서 만든다 (지연 생성). 아래 layout 계산부터
        // 이미 dialog 폰트의 cell 크기를 쓰므로 **그보다 먼저** 있어야 한다.
        // 대부분의 세션은 이 지점에 오지 않아 시작 시간에서 그만큼을 아낀다.
        self.renderer.ensureDialogFonts(self.allocator);

        // #306 — basis output viewport 안에서 실제 텍스트 폭/줄 수로 surface를
        // 계산한다. physical→logical은 ceil로 왕복 축소를 막는다.
        const layout = self.applyCurrentDialogLayout();
        const logical_w: u32 = @intCast(self.physicalToLogicalCeil(layout.size.w));
        const logical_h: u32 = @intCast(self.physicalToLogicalCeil(layout.size.h));
        if (!layout.fits) {
            log.appendLine("dialog", "content exceeds supported viewport={}x{} title={s} msg_len={} (#306)", .{
                self.dialogViewportPhysicalSize().w,
                self.dialogViewportPhysicalSize().h,
                self.dialog.title(),
                self.dialog.message().len,
            });
        }

        // 이미 떠 있으면 destroy 후 새 크기로 재생성. 같은 surface 에 set_size
        // 만 다시 보낼 수도 있으나, buffer 크기 / configure 흐름 일관성을 위해
        // recreate. 사용자가 같은 dialog 를 두 번 못 띄우는 시나리오라 부담 없음.
        if (self.dialog.surface_id != 0) {
            try self.destroyDialogSurface();
        }
        const requested = try self.createDialogSurface(logical_w, logical_h);
        log.appendLine("dialog", "open {s} severity={s} title={s} msg_len={d} initial_logical={}x{}", .{
            @tagName(kind),
            @tagName(severity),
            self.dialog.title(),
            self.dialog.message().len,
            requested.w,
            requested.h,
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
        // #295 — 옛 surface 의 entered 집합은 새 surface 에 무효. 새 surface 가
        // enter 를 새로 받으므로 clear (dirty 는 set 안 함 — 새 enter 도착 시 set).
        // current_output_object_id 는 유지 (새 surface 가 같은 basis 로 map → 그
        // enter 가 current 를 그대로 확인, 다른 데 놓이면 그 enter 가 전환).
        for (&self.outputs) |*s| s.entered = false;

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

        log.appendLineVerbose("dialog", "swapMainSurface — create-before-destroy (new surface_id={} configured={})", .{ self.surface_id, self.configured });
    }

    /// #241 — visible 상태에서 output 소멸로 layer-surface 가 closed 된 경우의
    /// deferred 재생성. closed 핸들러(dispatchBuffered 안)는 pending_output_recreate
    /// 만 set → 여기(outer dispatchBuffered 밖, drainQuitRequest 와 같은 위치)서
    /// swapMainSurfaceSeamless(내부 configure pump = reentrant dispatch) 실행해
    /// reentrancy 회피. layer-shell 전용 — xdg-shell 의 close 는 advisory 라 이
    /// 경로로 안 온다(handleEvent 의 toplevel close 분기에서 hidden 무시).
    fn drainOutputRecreate(self: *Client) void {
        if (!self.pending_output_recreate) return;
        self.pending_output_recreate = false;
        if (self.layer_surface_id == 0) return;
        log.appendLineVerbose("input", "drainOutputRecreate — swapMainSurfaceSeamless after output loss (visible) (#241)", .{});
        self.swapMainSurfaceSeamless();
    }

    fn drainQuitRequest(self: *Client) void {
        if (!self.pending_quit_request) return;
        self.pending_quit_request = false;
        log.appendLineVerbose("dialog", "drainQuitRequest — calling dialog.showConfirm", .{});

        const n: usize = if (self.session) |*session| session.count() else 0;
        if (n == 0) {
            self.running = false;
            return;
        }

        var msg_buf: [256]u8 = undefined;
        const msg = dialog_mod.quitConfirmMessage(&msg_buf, n) orelse {
            self.running = false;
            return;
        };
        // 다이얼로그 동안엔 KWin 이 옛 메인 frame 을 유지 → 터미널이 뒤에 보임
        // (원래 동작, Alt+F4 시점 깜박임 없음).
        if (dialog_mod.showConfirm(messages.quit_confirm_title, msg)) {
            self.running = false;
            return;
        }
        // Cancel — 메인 surface 처리는 close 가 온 경로에 따라 다르다.
        // - layer-shell(KWin): `closed` 가 메인 surface 를 죽이므로(재사용 불가)
        //   create-before-destroy 로 깜박임 없이 교체해야 다음 Alt+F4 가 동작(#216).
        // - xdg-shell(mutter/muffin): `xdg_toplevel.close` 는 권고일 뿐 surface 가
        //   살아있다 → 재생성 불필요. 재생성하면 새 map 을 GNOME 확장(#228)이 다시
        //   잡아 placement+(hidden_start면)minimize 로 *숨겨버린다*(#231 시연 회귀).
        //   surface 가 그대로라 아무것도 안 하면 터미널이 그 자리에 유지된다.
        if (self.layer_surface_id != 0) {
            self.swapMainSurfaceSeamless();
        }
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
            log.appendLine("dialog", "focus return via xdg-activation failed: {s} — fallback (manual focus)", .{@errorName(err)});
        };

        self.destroyDialogSurface() catch |err| {
            log.appendLine("dialog", "destroyDialogSurface in dismiss failed: {s}", .{@errorName(err)});
        };
        if (self.dialog.message_owned) |message| self.allocator.free(message);
        self.dialog.message_owned = null;
        self.dialog.msg_len = 0;
        self.dialog.message_scroll_row = 0;
        self.dialog.message_scroll_max = 0;
        self.dialog.scrollbar_drag_grab = null;
        self.dialog.scroll_axis_remainder_fixed = 0;
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
            log.appendLineVerbose("dialog", "skip xdg-activation: dialog not focused (kbd_focus={} dialog_surface={})", .{ self.last_keyboard_focus_surface_id, self.dialog.surface_id });
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
        log.appendLineVerbose("dialog", "xdg-activation token activated for main surface_id={}", .{self.surface_id});
    }

    /// dialog 활성 시 모든 키 라우팅. SPEC §6 — Enter / Esc / 클릭 dismiss.
    /// 그 외 키 무시 (modal). Confirm 모드: Enter = OK (true), Esc = Cancel (false).
    fn handleDialogKey(self: *Client, key: u32) void {
        const xkb_key = key + wayland_xkb_keycode_offset;
        const sym = self.keyboard.oneSym(xkb_key) orelse return;
        if (self.dialog.kind == .prompt) {
            if (sym == xkb_key_return) {
                if (self.validatePromptInput()) {
                    self.pending_prompt_result = true;
                    self.requestDismissDialog();
                }
                return;
            }
            if (sym == xkb_key_escape) {
                self.pending_prompt_result = false;
                self.requestDismissDialog();
                return;
            }
            if (sym == xkb_key_backspace) {
                self.dialog.input_len = 0;
                self.dialog.status_len = 0;
                self.dialog.prompt_available = false;
                self.repaintDialog();
                return;
            }
            var modifiers: u32 = 0;
            if (self.keyboard.altActive()) modifiers |= config_mod.CAPTURE_MOD_ALT;
            if (self.keyboard.ctrlActive()) modifiers |= config_mod.CAPTURE_MOD_CTRL;
            if (self.keyboard.shiftActive()) modifiers |= config_mod.CAPTURE_MOD_SHIFT;
            if (self.keyboard.superActive()) modifiers |= config_mod.CAPTURE_MOD_PRIMARY;
            var capture_buf: [64]u8 = undefined;
            if (config_mod.capturedHotkeyText(&capture_buf, sym, modifiers)) |captured| {
                @memcpy(self.dialog.input_buf[0..captured.len], captured);
                self.dialog.input_len = captured.len;
                _ = self.validatePromptInput();
            }
            return;
        }
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

    fn dialogScrollbarGeom(self: *const Client) ?scrollbar.Geom {
        if (self.dialog.message_scroll_max == 0) return null;
        const track = self.renderer.last_dialog_scrollbar_track_rect;
        if (track.h <= 0) return null;
        const scale_num: i64 = @intCast(self.preferred_scale);
        const scale_den: i64 = fractional_scale_denominator;
        // 여기만 `ui_metrics.scaledPx` 를 쓰지 않는다 (#350). 그 helper 는 f32
        // scale 을 받는데, 이 자리는 `preferred_scale` 을 **유리수 그대로**
        // (204/120 등) 정수 산술로 반올림해 f32 변환 오차를 아예 만들지 않는다
        // (`+ den/2` 후 나누기 = 반올림). `font/spec.zig` 의 rational scale 과
        // 같은 이유다. 규칙(반올림)은 helper 와 동일하므로 결과도 일치한다.
        const min_thumb_h = @divTrunc(
            @as(i64, ui_metrics.SCROLLBAR_MIN_THUMB_H_PT) * scale_num + @divTrunc(scale_den, 2),
            scale_den,
        );
        return scrollbar.geom(
            self.dialog.message_rows,
            self.dialog.visible_message_rows,
            self.dialog.message_scroll_row,
            @floatFromInt(track.h),
            @floatFromInt(min_thumb_h),
        );
    }

    fn beginDialogScrollbarDrag(self: *Client) bool {
        const geom = self.dialogScrollbarGeom() orelse return false;
        const track = self.renderer.last_dialog_scrollbar_track_rect;
        self.dialog.scrollbar_drag_grab = scrollbar.grabOffset(
            geom,
            @floatFromInt(self.pointer_y_px - track.y),
        );
        self.scrollDialogToPointer();
        return true;
    }

    fn scrollDialogToPointer(self: *Client) void {
        const grab = self.dialog.scrollbar_drag_grab orelse return;
        const geom = self.dialogScrollbarGeom() orelse return;
        const track = self.renderer.last_dialog_scrollbar_track_rect;
        const target = scrollbar.targetOffset(
            self.dialog.message_rows,
            self.dialog.visible_message_rows,
            geom,
            @floatFromInt(self.pointer_y_px - track.y),
            grab,
        );
        _ = self.dialog.setDragScrollRow(target);
    }

    fn scrollDialogRows(self: *Client, delta: i32) void {
        if (self.dialog.message_scroll_max == 0 or delta == 0) return;
        const current: i64 = @intCast(self.dialog.message_scroll_row);
        const max_row: i64 = @intCast(self.dialog.message_scroll_max);
        const target: usize = @intCast(std.math.clamp(current + @as(i64, delta), 0, max_row));
        if (target == self.dialog.message_scroll_row) return;
        self.dialog.message_scroll_row = target;
        self.repaintDialog();
    }

    /// pointer 가 *dialog surface-local* rect 안인지. `last_dialog_*_rect`
    /// 가 그리기 때 set + destroyDialogSurface 가 reset (w == 0 → 자동 miss).
    fn hitDialogRect(self: *const Client, r: anytype) bool {
        return r.w > 0 and
            self.pointer_x_px >= r.x and self.pointer_x_px < r.x + r.w and
            self.pointer_y_px >= r.y and self.pointer_y_px < r.y + r.h;
    }

    fn validatePromptInput(self: *Client) bool {
        if (!self.dialog.hasPromptInput()) {
            self.dialog.status_len = 0;
            self.dialog.prompt_available = false;
            self.repaintDialog();
            return false;
        }
        const validator = self.prompt_validator orelse {
            self.dialog.status_len = 0;
            self.dialog.prompt_available = false;
            self.repaintDialog();
            return false;
        };
        const result = validator.validate(self.dialog.input());
        self.dialog.prompt_available = switch (result) {
            .available => true,
            else => false,
        };
        var status_buf: [256]u8 = undefined;
        const status = dialog_mod.hotkeyValidationMessage(&status_buf, result);
        const len = @min(status.len, self.dialog.status_buf.len);
        @memcpy(self.dialog.status_buf[0..len], status[0..len]);
        self.dialog.status_len = len;
        self.repaintDialog();
        return self.dialog.prompt_available;
    }

    /// 별 layer-shell `overlay` surface 생성. 새 wl_surface + zwlr_layer_surface
    /// (layer=overlay, anchor=0 → compositor 중앙 배치, set_size=박스 크기,
    /// set_keyboard_interactivity=exclusive). 첫 commit 은 buffer 없이 send —
    /// layer-shell spec: "buffer 는 첫 configure event ack 전에 attach 불가".
    /// `handleDialogConfigure` 가 ack + buffer attach 담당.
    fn createDialogSurface(self: *Client, initial_logical_w: u32, initial_logical_h: u32) !dialog_layout.Size {
        if (self.dialog.surface_id != 0) return .{
            .w = @intCast(initial_logical_w),
            .h = @intCast(initial_logical_h),
        };
        var logical_w = initial_logical_w;
        var logical_h = initial_logical_h;
        if (self.layer_shell_id == 0 and self.wm_base_id == 0) {
            // role object 를 만들 protocol 이 전혀 없음 — surface 만 만들면 영영
            // 안 뜨는 trap 이라 skip. (createShellObjects 가 wm_base 를 필수로
            // 요구하므로 실제로는 거의 도달 안 함.)
            log.appendLine("dialog", "createDialogSurface skipped — neither layer-shell nor xdg_wm_base available", .{});
            self.dialog.kind = .none;
            return .{ .w = 0, .h = 0 };
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
        // (boot 중 hotkey dialog 등) main 의 preferred_scale 가 아직
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
            // Boot fatal dialog는 main surface보다 먼저 열릴 수 있다. dialog 자체
            // preferred_scale을 받은 뒤 고정 15/18 typography와 viewport를 다시
            // 계산해야 첫 1x 추정 크기가 fractional output에 남지 않는다 (#306).
            const scaled_layout = self.applyCurrentDialogLayout();
            logical_w = @intCast(self.physicalToLogicalCeil(scaled_layout.size.w));
            logical_h = @intCast(self.physicalToLogicalCeil(scaled_layout.size.h));
        }

        // role object — surface 종류만 compositor 별로 갈린다. 그리기/버퍼/
        // 입력/dismiss 는 surface_id 기준이라 이후 경로 공유.
        if (self.layer_shell_id != 0) {
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
            // anchor=0 — layer-shell compositor가 현재 output 중앙에 배치한다.
            // main 창의 dock/width_percent와 독립이므로 오른쪽 50%에서도 화면 중앙.
            try self.sendArgs(
                self.dialog.layer_surface_id,
                zwlr_layer_surface_v1_request_set_anchor,
                &.{0},
            );
            var dlg_margin = Msg.init(self.dialog.layer_surface_id, zwlr_layer_surface_v1_request_set_margin);
            try dlg_margin.putI32(0);
            try dlg_margin.putI32(0);
            try dlg_margin.putI32(0);
            try dlg_margin.putI32(0);
            try dlg_margin.send(self.stream);
            // exclusive — modal 입력. 사용자가 main surface 클릭해도 키 입력은
            // 우리 dialog 로 옴.
            try self.sendArgs(
                self.dialog.layer_surface_id,
                zwlr_layer_surface_v1_request_set_keyboard_interactivity,
                &.{zwlr_layer_surface_keyboard_interactivity_exclusive},
            );
            try self.sendNoArgs(self.dialog.surface_id, 6);

            log.appendLineVerbose("dialog", "createDialogSurface surface_id={} layer_surface_id={} size={}x{} (logical) layer=overlay anchor=0 keyboard=exclusive", .{
                self.dialog.surface_id,
                self.dialog.layer_surface_id,
                logical_w,
                logical_h,
            });
        } else {
            // #231 — layer-shell 미advertise (GNOME mutter / Cinnamon muffin):
            // 일반 xdg_toplevel 로 띄운다. xdg_surface(get_xdg_surface) →
            // xdg_toplevel(get_toplevel) → title/app_id → main 을 parent 로 →
            // min=max size 로 고정 크기 → commit. compositor 가 새 toplevel 에
            // 키보드 focus 를 줘 Enter/Esc(handleDialogKey)·클릭(hit-test) 동작.
            self.dialog.xdg_surface_id = self.allocId();
            try self.sendArgs(self.wm_base_id, 2, &.{ self.dialog.xdg_surface_id, self.dialog.surface_id });
            self.dialog.xdg_toplevel_id = self.allocId();
            try self.sendNewId(self.dialog.xdg_surface_id, 1, self.dialog.xdg_toplevel_id);
            try self.sendString(self.dialog.xdg_toplevel_id, 2, self.dialog.title()); // set_title
            // set_app_id — 메인 창("tildaz")과 *다른* id. GNOME 확장(#228)이
            // app_id=="tildaz" 인 창을 drop-down 으로 가로채(opacity 0 + 상단 배치)
            // dialog 가 안 보이던 버그(#231 시연) 회피 — 확장의 exact match 에서
            // 제외돼 mutter 가 transient child 로 중앙에 정상 표시한다.
            try self.sendString(self.dialog.xdg_toplevel_id, 3, "tildaz-dialog"); // set_app_id
            // set_parent(main toplevel) — main 이 xdg_toplevel (layer-shell 없는
            // 환경이라 main 도 xdg) 일 때만. transient grouping + 중앙 배치 유도.
            if (self.toplevel_id != 0) {
                try self.sendArgs(self.dialog.xdg_toplevel_id, 1, &.{self.toplevel_id});
            }
            // set_max_size(7) + set_min_size(8) = 같은 크기 → 고정 크기 dialog
            // 창. compositor 의 tile/maximize 회피.
            try self.sendArgs(self.dialog.xdg_toplevel_id, 7, &.{ logical_w, logical_h });
            try self.sendArgs(self.dialog.xdg_toplevel_id, 8, &.{ logical_w, logical_h });
            // xdg_toplevel.configure 가 0x0("you decide")을 줄 수 있으니 요청 크기를
            // 미리 보관 — xdg_surface.configure 에서 이 값으로 paint. toplevel.configure
            // 가 non-zero 면 덮어씀.
            self.dialog.pending_w_logical = logical_w;
            self.dialog.pending_h_logical = logical_h;
            try self.sendNoArgs(self.dialog.surface_id, 6); // commit — 첫 configure 유도

            log.appendLineVerbose("dialog", "createDialogSurface surface_id={} xdg_surface_id={} xdg_toplevel_id={} size={}x{} (logical) role=xdg_toplevel parent={}", .{
                self.dialog.surface_id,
                self.dialog.xdg_surface_id,
                self.dialog.xdg_toplevel_id,
                logical_w,
                logical_h,
                self.toplevel_id,
            });
        }
        return .{ .w = @intCast(logical_w), .h = @intCast(logical_h) };
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

        if (self.prompt_shortcuts_inhibitor_id != 0) {
            try self.sendNoArgs(self.prompt_shortcuts_inhibitor_id, keyboard_shortcuts_inhibitor_request_destroy);
            self.prompt_shortcuts_inhibitor_id = 0;
        }

        if (self.dialog.active_buffer) |*buffer| {
            self.destroyBufferObject(buffer.id);
            buffer.deinit();
            self.dialog.active_buffer = null;
        }
        for (self.dialog.retired_buffers.items) |*buffer| {
            self.destroyBufferObject(buffer.id);
            buffer.deinit();
        }
        self.dialog.retired_buffers.clearRetainingCapacity();
        if (self.dialog.layer_surface_id != 0) {
            try self.sendNoArgs(self.dialog.layer_surface_id, zwlr_layer_surface_v1_request_destroy);
            self.dialog.layer_surface_id = 0;
        }
        // #231 — xdg role 객체 정리 (toplevel 먼저, 그 다음 xdg_surface). 둘 다
        // destroy 가 opcode 0.
        if (self.dialog.xdg_toplevel_id != 0) {
            try self.sendNoArgs(self.dialog.xdg_toplevel_id, 0);
            self.dialog.xdg_toplevel_id = 0;
        }
        if (self.dialog.xdg_surface_id != 0) {
            try self.sendNoArgs(self.dialog.xdg_surface_id, 0);
            self.dialog.xdg_surface_id = 0;
        }
        self.dialog.pending_w_logical = 0;
        self.dialog.pending_h_logical = 0;
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
        self.renderer.last_dialog_scrollbar_track_rect = .{};
        self.renderer.last_dialog_scrollbar_hit_rect = .{};
        self.renderer.last_dialog_scrollbar_thumb_rect = .{};
        self.dialog.scrollbar_drag_grab = null;
        self.dialog.repaint_requested = false;
        log.appendLineVerbose("dialog", "destroyDialogSurface", .{});
    }

    /// dialog surface buffer painting. `drawDialogContent` 호출 — title /
    /// separator / message / footer / border / alpha sweep 모두 renderer 처리.
    /// step 4 — confirm 모드 (`kind == .confirm`) 면 `confirm_focus_ok = true`
    /// 전달 (OK 버튼 + Cancel 버튼 그림). Info 모드 면 null (OK 하나만).
    fn paintDialogBuffer(self: *Client, memory: []u8, w: i32, h: i32, stride: i32) void {
        const focus_arg: ?bool = if (self.dialog.kind == .confirm or self.dialog.kind == .prompt) true else null;
        self.renderer.drawDialogContent(
            memory,
            w,
            h,
            stride,
            self.dialog.severity,
            self.dialog.title(),
            self.dialog.message(),
            focus_arg,
            if (self.dialog.kind == .prompt) self.dialog.input() else null,
            if (self.dialog.kind == .prompt) self.dialog.status() else null,
            self.dialog.prompt_available,
            self.dialog.wrap_cells,
            self.dialog.message_rows,
            self.dialog.visible_message_rows,
            self.dialog.message_scroll_row,
            self.dialog.show_icon,
        );
    }

    fn repaintDialog(self: *Client) void {
        const current = self.dialog.active_buffer orelse return;
        var buffer = if (current.released) current else self.createDialogBuffer(current.width, current.height) catch |err| {
            log.appendLine("dialog", "repaint buffer creation failed: {s}", .{@errorName(err)});
            return;
        };

        if (!current.released) {
            self.dialog.retired_buffers.append(self.allocator, current) catch {
                self.destroyBufferObject(buffer.id);
                buffer.deinit();
                return;
            };
        }
        self.dialog.active_buffer = null;
        buffer.released = false;
        // #277 — dialog surface 는 항상 software `wl_shm` 이다 (GPU 경로는 main
        // surface 에만 적용). `createDialogBuffer` 가 memfd mapping 을 반드시
        // 채우므로 null 이 될 수 없지만, panic 대신 조용히 건너뛴다.
        const dialog_memory = buffer.memory orelse {
            self.destroyBufferObject(buffer.id);
            buffer.deinit();
            return;
        };
        self.paintDialogBuffer(dialog_memory, buffer.width, buffer.height, buffer.stride);
        self.sendArgs(self.dialog.surface_id, 1, &.{ buffer.id, 0, 0 }) catch {
            self.destroyBufferObject(buffer.id);
            buffer.deinit();
            return;
        };
        self.sendArgs(self.dialog.surface_id, 9, &.{ 0, 0, @as(u32, @intCast(buffer.width)), @as(u32, @intCast(buffer.height)) }) catch {
            self.destroyBufferObject(buffer.id);
            buffer.deinit();
            return;
        };
        self.sendNoArgs(self.dialog.surface_id, 6) catch {
            self.destroyBufferObject(buffer.id);
            buffer.deinit();
            return;
        };
        self.dialog.active_buffer = buffer;
    }

    /// 한 번의 Wayland 입력 batch에서 들어온 drag motion을 최신 row 하나로
    /// 합쳐 전체 dialog buffer를 한 번만 다시 그린다. 즉시 repaint하면 긴 About
    /// 의 13MB대 buffer paint가 pointer event 처리를 막아 thumb가 뒤처진다.
    fn drainDialogRepaint(self: *Client) void {
        if (!self.dialog.takeRepaintRequest()) return;
        if (!self.dialog.active() or self.dialog.surface_id == 0) return;
        self.repaintDialog();
    }

    /// dialog surface 용 buffer 생성. main createBuffer 패턴 (memfd + mmap +
    /// shm pool + wl_buffer). main 의 retired_buffers cycle 미사용 — dialog 는
    /// configure 한 번에 그리고 dismiss 까지 그대로.
    fn createDialogBuffer(self: *Client, width: i32, height: i32) !SurfaceBuffer {
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

    /// dialog layer-surface configure event handler. ack_configure (opcode 6)
    /// 후 공통 paint. #231 — xdg fallback 은 `handleDialogXdgSurfaceConfigure`
    /// 가 opcode 4 로 ack 한 뒤 같은 `applyDialogSizeAndPaint` 를 부른다.
    fn handleDialogConfigure(self: *Client, serial: u32, w_logical: u32, h_logical: u32) !void {
        try self.sendArgs(
            self.dialog.layer_surface_id,
            zwlr_layer_surface_v1_request_ack_configure,
            &.{serial},
        );
        try self.applyDialogSizeAndPaint(w_logical, h_logical);
    }

    /// #231 — surface role(layer/xdg) 무관 공통 paint. viewport set_destination
    /// → buffer (재)생성 + attach + damage_buffer + commit. frame callback
    /// throttling 없음 — dialog 는 정적. ack_configure 는 호출자(role별 opcode)가
    /// 먼저 보낸다.
    fn applyDialogSizeAndPaint(self: *Client, w_logical: u32, h_logical: u32) !void {
        // compositor 가 0 으로 답하면 (= "you decide") 우리 요청 크기 그대로 —
        // 새로 계산 (openInfoDialog 가 보낸 set_size 값 회수). 다만 그 값은
        // 이미 보냈으니 0 fall-back 은 거의 안 닿음. 보수적으로 renderer 재계산.
        const physical: dialog_layout.Size = blk: {
            if (w_logical > 0 and h_logical > 0) {
                const w_clamped: i32 = @intCast(@min(w_logical, @as(u32, std.math.maxInt(i32))));
                const h_clamped: i32 = @intCast(@min(h_logical, @as(u32, std.math.maxInt(i32))));
                const configured = dialog_layout.Size{
                    .w = self.logicalToPhysical(w_clamped),
                    .h = self.logicalToPhysical(h_clamped),
                };
                const configured_layout = self.applyCurrentDialogLayoutForSurface(configured);
                if (!configured_layout.fits) {
                    log.appendLine("dialog", "configured surface cannot fit content: physical={}x{} title={s} msg_len={} (#306)", .{
                        configured.w,
                        configured.h,
                        self.dialog.title(),
                        self.dialog.message().len,
                    });
                }
                break :blk configured;
            }
            const want = self.applyCurrentDialogLayout();
            break :blk .{ .w = want.size.w, .h = want.size.h };
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
        log.appendLine("dialog", "configured logical={}x{} physical={}x{} wrap_cells={} rows={}/{} scroll_max={} icon={} fits={}", .{
            w_logical,
            h_logical,
            physical.w,
            physical.h,
            self.dialog.wrap_cells,
            self.dialog.visible_message_rows,
            self.dialog.message_rows,
            self.dialog.message_scroll_max,
            self.dialog.show_icon,
            self.dialog.layout_fits,
        });
    }

    /// dialog_linux 의 info / error callback. cross-platform `dialog.show*` /
    /// `dialog.showAboutAlert` 가 종착점으로 도달.
    fn dialogShowInfoCb(ctx: *anyopaque, severity: dialog_mod.Severity, title: []const u8, message: []const u8) void {
        const self: *Client = @ptrCast(@alignCast(ctx));
        self.queueInfoDialog(severity, title, message, false);
    }

    fn dialogShowAboutCb(ctx: *anyopaque, title: []const u8, message: []const u8) void {
        const self: *Client = @ptrCast(@alignCast(ctx));
        self.queueInfoDialog(.info, title, message, true);
    }

    fn queueInfoDialog(self: *Client, severity: dialog_mod.Severity, title: []const u8, message: []const u8, is_about: bool) void {
        // #282 C1 — 즉시 열지 않고 deferred. 호출부(handleNewTab 등)가 dispatchBuffered
        // reentrant 라 여기서 createDialogSurface(roundtrip)를 돌리면 buffer corrupt.
        // title/message 는 호출부 stack buffer 일 수 있어 owned 로 복사.
        if (self.pending_info_msg_owned) |old| self.allocator.free(old);
        self.pending_info_msg_owned = null;
        const tlen = @min(title.len, self.pending_info_title_buf.len);
        const owned = self.allocator.dupe(u8, message) catch null;
        const mlen = if (owned) |full_message| blk: {
            self.pending_info_msg_owned = full_message;
            break :blk full_message.len;
        } else dialog_linux.copyMessage(&self.pending_info_msg_buf, message);
        @memcpy(self.pending_info_title_buf[0..tlen], title[0..tlen]);
        self.pending_info_title_len = tlen;
        self.pending_info_msg_len = mlen;
        self.pending_info_severity = severity;
        self.pending_info_is_about = is_about;
        self.pending_info_request = true;
        if (mlen != message.len) {
            log.appendLine("dialog", "deferred info message truncated at UTF-8 boundary original_len={} stored_len={} capacity={}", .{
                message.len,
                mlen,
                dialog_linux.message_capacity,
            });
        }
    }

    fn pendingInfoMessage(self: *const Client) []const u8 {
        if (self.pending_info_msg_owned) |message| return message;
        return self.pending_info_msg_buf[0..self.pending_info_msg_len];
    }

    fn clearPendingInfoMessage(self: *Client) void {
        if (self.pending_info_msg_owned) |message| self.allocator.free(message);
        self.pending_info_msg_owned = null;
    }

    /// #282 C1 — deferred info dialog 를 reentrancy 밖(main loop)에서 연다.
    /// 다른 dialog 가 이미 떠 있으면(About/confirm 등) 이번 info 는 버린다
    /// (advisory 알림 — 탭 한도/shell 소실). fire-and-forget 이라 pump 불필요.
    fn drainInfoRequest(self: *Client) void {
        if (!self.pending_info_request) return;
        self.pending_info_request = false;
        defer self.clearPendingInfoMessage();
        if (self.dialog.active()) {
            log.appendLine("dialog", "deferred info dropped — another dialog active", .{});
            return;
        }
        const title = self.pending_info_title_buf[0..self.pending_info_title_len];
        const message = self.pendingInfoMessage();
        const result = if (self.pending_info_is_about)
            self.openAboutDialog(title, message)
        else
            self.openInfoDialog(self.pending_info_severity, title, message);
        result catch |err| {
            log.appendLine("dialog", "openInfoDialog failed: {s} — falling back to log only", .{@errorName(err)});
            if (self.pending_info_is_about) {
                self.openInfoDialog(.info, title, messages.about_prepare_failed_msg) catch |fallback_err| {
                    log.appendLine("dialog", "About fallback dialog failed: {s}", .{@errorName(fallback_err)});
                };
            }
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
        return self.runConfirmDialog(.confirm, title, message);
    }

    fn runConfirmDialog(self: *Client, kind: DialogOverlay.Kind, title: []const u8, message: []const u8) bool {
        // Confirm dialog 띄움. 실패 시 안전 default Cancel.
        std.debug.assert(kind == .confirm);
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
            self.drainDialogRepaint();
            self.drainExitedTabs();
            self.dispatchDbusMessages();
            self.maybeRepeatKey() catch {};
            if (self.session) |*session| {
                if (session.drainOutputForRender()) {
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

    /// #282 C2 — fatal 안내를 overlay 로 띄우고 사용자가 닫을 때까지(Enter / Esc /
    /// OK 클릭 / 창 닫기) event loop 를 pump 한 뒤 반환한다. info dialog 는
    /// fire-and-forget 이라 그냥 띄우고 exit 하면 paint 전에 프로세스가 죽어 아무것도
    /// 안 보인다(#282 F9). confirm pump(`runConfirmDialog`)와 같은 패턴이지만 결과값이
    /// 없고, main terminal surface 없이도 dialog 는 layer-shell overlay(exclusive
    /// keyboard) / 독립 xdg_toplevel 로 자체 focus·paint 하므로 startup 시점에도 동작한다.
    /// 호출자는 반환 후 exit 한다. backend 미가용(dialog 생성 실패) 시 즉시 반환 —
    /// 메시지는 호출자가 이미 stderr / log 에 남겼다.
    fn runFatalDialog(self: *Client, title: []const u8, message: []const u8) void {
        self.openInfoDialog(.err, title, message) catch |err| {
            log.appendLine("dialog", "openInfoDialog (fatal) failed: {s} — stderr/log only", .{@errorName(err)});
            return;
        };
        // dialog.kind 가 .none 이 되면(= dismiss 처리 완료) 종료. running=false(외부
        // 종료 신호)면 무한 대기 방지로 함께 탈출.
        while (self.running and self.dialog.kind != .none) {
            self.pollAndDispatch(frame_poll_ms) catch |err| {
                log.appendLine("dialog", "fatal dialog pump pollAndDispatch failed: {s} — break", .{@errorName(err)});
                break;
            };
            self.drainPendingDialogDismiss();
            self.drainDialogRepaint();
        }
    }

    fn dialogPromptHotkeyCb(ctx: *anyopaque, allocator: std.mem.Allocator, title: []const u8, message: []const u8, validator: dialog_mod.HotkeyValidator) ?[]u8 {
        const self: *Client = @ptrCast(@alignCast(ctx));
        self.prompt_validator = validator;
        defer self.prompt_validator = null;
        self.openPromptDialog(title, message) catch return null;
        // Inner pump — confirm pump(`runConfirmDialog`)와 동일 work 로 (#282 C4).
        // 이전엔 key repeat / PTY drain / redraw 를 생략해 캡처 dialog 동안
        // 배경 터미널이 정지했다 (Windows GetMessageW / macOS runModal 은 계속 그림).
        while (self.running and self.pending_prompt_result == null) {
            self.pollAndDispatch(frame_poll_ms) catch {
                self.pending_prompt_result = false;
                break;
            };
            self.drainPendingDialogDismiss();
            self.drainDialogRepaint();
            self.drainExitedTabs();
            self.dispatchDbusMessages();
            self.maybeRepeatKey() catch {};
            if (self.session) |*session| {
                if (session.drainOutputForRender()) {
                    self.requestRedraw();
                }
            }
            self.maybeRedraw() catch {};
        }
        const accepted = self.pending_prompt_result orelse false;
        self.pending_prompt_result = null;
        if (!accepted) return null;
        return allocator.dupe(u8, self.dialog.input()) catch null;
    }

    fn drainNewInstanceRequest(self: *Client) void {
        if (!self.pending_new_instance_request) return;
        if (self.dialog.active()) return;
        self.pending_new_instance_request = false;
        self.showMainBeforeNewInstancePrompt() catch |err| {
            log.appendLine("dialog", "show main before new-instance prompt failed: {s}", .{@errorName(err)});
            return;
        };
        @import("../../new_instance.zig").handle(self.allocator);
    }

    fn showMainBeforeNewInstancePrompt(self: *Client) !void {
        if (!self.surface_hidden) return;

        try self.handleActivatedToggle();
        // KWin Bug 503121 workaround는 surface/role/active buffer를 유지한 채
        // layer state를 재전송한다. KWin은 화면을 복원해도 새 configure/non-null
        // attach를 생략할 수 있어 protocol-state `mapped`가 false로 남는다. display
        // sync로 remap request 처리 순서를 보장한 뒤, configure가 왔다면 redraw까지
        // 수행하고 prompt 생성으로 진행한다. 다른 compositor의 recreate path는 아래서
        // 실제 non-null buffer attach (`mapped=true`)를 계속 기다린다.
        if (kwinCompositor() and self.layer_surface_id != 0) {
            try self.roundtrip();
            try self.maybeRedraw();
            log.appendLine("dialog", "main remap processed before new-instance prompt (KWin)", .{});
            return;
        }

        var timer = try std.time.Timer.start();
        while (self.running and !self.mapped and timer.read() < 5 * std.time.ns_per_s) {
            try self.pollAndDispatch(frame_poll_ms);
            self.drainPendingDialogDismiss();
            self.drainExitedTabs();
            self.dispatchDbusMessages();
            // Fresh surface의 configure handler가 예약한 첫 frame을 이 bounded
            // pump 안에서 attach해야 mapped=true가 된다. outer main loop의 redraw는
            // 이 함수가 반환한 뒤라 여기서 기다리는 동안에는 실행될 수 없다.
            try self.maybeRedraw();
        }
        if (!self.mapped) return error.MainWindowShowTimeout;
        log.appendLine("dialog", "main window shown before new-instance prompt", .{});
    }

    fn logCapabilities(self: *Client) void {
        // #197 — production capabilities 요약 (once per boot). lifecycle 성격이라 [startup].
        log.appendLine(
            "startup",
            "wayland capabilities: compositor={} shm={} xdg_wm_base={} layer_shell={} text_input_v3={} data_device_manager={} shortcuts_inhibit={} shm_xrgb8888={} shm_argb8888={} dmabuf={} dmabuf_linear={} dmabuf_modifiers={} gles_capable={} render_path={s}",
            .{
                self.caps.compositor.name != 0,
                self.caps.shm.name != 0,
                self.caps.xdg_wm_base.name != 0,
                self.caps.layer_shell.name != 0,
                self.caps.text_input_v3.name != 0,
                self.caps.data_device_manager.name != 0,
                self.caps.keyboard_shortcuts_inhibit.name != 0,
                self.saw_xrgb8888,
                self.saw_argb8888,
                self.caps.linux_dmabuf.name != 0,
                self.dmabuf_linear_supported,
                self.dmabuf_mod_count,
                // #277 — GLES 렌더러(S2)가 이 환경에서 가능한가. 사용자 보고에서
                // "이 머신은 GPU 로 갈 수 있는가" 를 한 줄로 판정하는 값이다.
                self.gl_modifier != null,
                // #277 — 어느 경로로 그리는지. 사용자 보고를 진단할 때 첫 번째로
                // 볼 값이라 capability 줄에 같이 남긴다. **래스터화 주체까지
                // 구분한다** — `gpu-dmabuf` 는 GPU buffer 에 CPU 가 그리는 S1 이고
                // `gpu-gl` 은 GPU 가 그리는 S2 다. 둘을 뭉치면 사용자 로그만 보고
                // 어느 쪽 문제인지 가릴 수 없다.
                if (!self.gpu_enabled)
                    @as([]const u8, "software-shm")
                else if (self.gl_render_enabled)
                    "gpu-gl"
                else
                    "gpu-dmabuf",
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
    // #198 / #230 — single-instance. 이미 살아있는 인스턴스가 있으면 toggle 신호만
    // 보내고 종료해 기존 인스턴스를 보여준다. #267 이후 중복 재실행(앱 아이콘 /
    // autostart)은 launcher 의 advisory lock 이 먼저 차단하므로, 이 분기는 lock
    // 파일 훼손 같은 edge 에서만 도달하는 잔존 방어층이다. socket 을 빼앗지
    // 않으므로 orphan/hotkey 라우팅 깨짐 없음. Client.init(wayland 연결) *전에*
    // 검사 — 두 번째 인스턴스가 창을 안 만든다.
    const listener_fd = single_instance.createListener() catch |err| switch (err) {
        error.AlreadyRunning => {
            log.appendLine("toggle-ipc", "already running — sending toggle to existing instance + exiting", .{});
            single_instance.sendToggle(@import("../../instance_context.zig").requireWorkerIndex()) catch |e| {
                log.appendLine("toggle-ipc", "delegate toggle failed: {s}", .{@errorName(e)});
            };
            return;
        },
        // 그 외(권한 등)는 fatal 아님 — listener 없이 진행 (graceful degrade).
        else => blk: {
            log.appendLine("toggle-ipc", "listener disabled: {s}", .{@errorName(err)});
            break :blk @as(posix.fd_t, -1);
        },
    };
    var client = try Client.init(allocator, cfg);
    defer client.deinit();
    client.toggle_listener_fd = listener_fd;
    // #207 — toggle listener가 준비된 직후, sway 세션이면 `tildaz --toggle`을 sway의
    // `bindsym` 으로 자동 등록 (config = source of truth). 비-sway 면 no-op.
    sway_ipc.registerToggleIfSway(allocator, cfg);
    // #207 / #229 — GNOME · Cinnamon 세션이면 `tildaz --toggle`을
    // custom keybinding (GSettings)
    // 으로 자동 등록. 그 외 DE 면 no-op.
    gsettings_hotkey.registerToggleHotkey(allocator, cfg);
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

    // #197 — 사용자 메시지(path / errno / 환경변수 3종 포함 = 진단 정보 전부)를
    // 한 번 렌더해 stderr + 로그 양쪽에 동일하게. 이전엔 compact 진단 한 줄을
    // 따로 log 하고 friendly 본문을 따로 print 해 같은 데이터를 두 번 포맷했음.
    var buf: [1536]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buf,
        messages.linux_wayland_socket_unavailable_format,
        .{ path, @errorName(err), display_str, session_str, runtime_str },
    ) catch messages.run_failed_fallback_msg;
    log.userFacing("fatal", text);
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

/// Surface-local pointer 좌표는 서로 비교할 수 없으므로, terminal text cursor는
/// main surface 위에서만 선택한다. Dialog surface는 같은 좌표가 terminal cell
/// 범위와 겹쳐도 기본 arrow를 유지한다.
fn cursorShapeForSurface(focused_surface_id: u32, main_surface_id: u32, in_cell: bool) u32 {
    if (focused_surface_id != 0 and
        focused_surface_id == main_surface_id and
        in_cell) return wp_cursor_shape_v1_text;
    return wp_cursor_shape_v1_default;
}

test "#314 dialog surface keeps arrow cursor while main text areas use I-beam" {
    try std.testing.expectEqual(
        wp_cursor_shape_v1_default,
        cursorShapeForSurface(200, 100, true),
    );
    try std.testing.expectEqual(
        wp_cursor_shape_v1_text,
        cursorShapeForSurface(100, 100, true),
    );
    try std.testing.expectEqual(
        wp_cursor_shape_v1_default,
        cursorShapeForSurface(100, 100, false),
    );
    try std.testing.expectEqual(
        wp_cursor_shape_v1_default,
        cursorShapeForSurface(0, 0, true),
    );
}

/// paste 인입으로 받아들일 mime. 셋 중 하나만 광고돼도 paste 가능. 셋 다
/// UTF-8 plain text 표기 — 우리는 byte 그대로 PTY 로 넣으므로 charset
/// fallback 가공 없음.
fn isAcceptableTextMime(mime: []const u8) bool {
    return std.mem.eql(u8, mime, clipboard_mime_utf8) or
        std.mem.eql(u8, mime, clipboard_mime_utf8_string) or
        std.mem.eql(u8, mime, clipboard_mime_text_plain);
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
