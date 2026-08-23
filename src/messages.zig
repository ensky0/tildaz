//! 모든 사용자 표시 텍스트의 단일 진입점. cross-platform.
//!
//! 같은 의미의 메시지를 platform 별로 두 번 작성하지 않게 한다. format string
//! 은 여기서 정의하고 실제 표시는 호출처가 `dialog.zig` 로 위임.

const std = @import("std");

/// #282 G9 — 자체 그리기 dialog 의 버튼 라벨 단일 소스 (macOS NSAlert · Windows
/// 자체 hotkey 프롬프트 · Linux overlay 공용). Windows 표준 MessageBoxW 의
/// OK/Cancel 은 OS 가 제공하므로 해당 없음.
pub const button_ok = "OK";
pub const button_cancel = "Cancel";
pub const button_create = "Create";

pub const config_error_title = "TildaZ Config Error";
pub const about_title = "About TildaZ";
pub const error_title = "TildaZ Error";
pub const crash_title = "TildaZ Crash";
pub const info_title = "TildaZ";
pub const quit_confirm_title = "Quit TildaZ?";

pub const command_toggle_visibility = "Show / Hide TildaZ";
pub const command_new_tab = "New Tab";
pub const command_close_active_tab = "Close Active Tab";
pub const command_copy_selection = "Copy Selection";
pub const command_paste = "Paste";
/// toggle 의미 + 320pt 메뉴 폭에서 hint 와 공존하는 짧은 문구 (#334 피드백 —
/// "Enter / Exit Full Screen" 은 길어서 hint 가 숨겨졌음).
pub const command_full_screen = "Toggle Full Screen";
pub const command_open_config = "Open Config";
pub const command_keyboard_shortcuts = "Keyboard Shortcuts";
pub const command_about = "About TildaZ";
pub const keyboard_shortcuts_url = "https://github.com/ensky0/tildaz/blob/main/KEYBINDINGS.md";
pub const shortcut_new_tab = "Ctrl+Shift+T";
pub const shortcut_new_tab_macos = "Cmd+T";
pub const shortcut_close_tab = "Ctrl+Shift+W";
pub const shortcut_close_tab_macos = "Cmd+W";
pub const shortcut_copy = "Drag / Ctrl+Shift+C";
pub const shortcut_copy_macos = "Drag / Cmd+C";
pub const shortcut_paste = "Right-click / Ctrl+Shift+V";
pub const shortcut_paste_macos = "Right-click / Cmd+V";
pub const shortcut_full_screen = "Alt+Enter";
pub const shortcut_full_screen_macos = "Cmd+Enter";
/// workarea 전체화면 상태에서 메뉴의 Toggle Full Screen 이 하는 일(해제)과
/// 같은 키 — 상태 의존 hint (#334 사용자 결정). 표기는 KEYBINDINGS.md /
/// SPEC §2 의 기존 확립 표기(`Shift+Alt+Enter`)를 따른다.
pub const shortcut_full_screen_workarea = "Shift+Alt+Enter";
pub const shortcut_full_screen_workarea_macos = "Shift+Cmd+Enter";
pub const shortcut_open_config = "Ctrl+Shift+P";
pub const shortcut_open_config_macos = "Shift+Cmd+P";

/// 종료 확인 (#116). 한 번에 사라지는 탭 수를 본문에 박아 사용자가 잃을
/// 작업량을 즉시 인지하게. {s} 는 영어 복수형 처리 — count==1 이면 "" else "s".
pub const quit_confirm_format = "This will close {d} open tab{s}.";

/// 새 탭 한도 도달 시 (`session_core.MAX_TABS`). `+` 버튼은 비활성 색 + noop
/// (#329 — 회색이 곧 피드백) 이지만 단축키 (Cmd+T / Ctrl+Shift+T) 는 시각
/// 피드백이 없어 이 dialog 로 안내. {d} 는 한도 (현재 32).
pub const tab_limit_title = "Tab limit reached";
pub const tab_limit_format = "Maximum {d} tabs are open. Close a tab to create a new one.";

/// Linux KDE — 우리 config 의 hotkey 가 *다른 KDE 컴포넌트* (kwin / plasmashell
/// 등) 의 단축키와 충돌 시 사용자 확인 (#207). OK = 충돌 컴포넌트에서 해당 키만
/// 회수하고 tildaz 로 가져옴, Cancel = 기존 binding 유지.
pub const hotkey_takeover_title = "Hotkey conflict";
pub const hotkey_takeover_format =
    \\"{s}" is currently used by another component:
    \\
    \\  • {s} — {s}
    \\
    \\Take this shortcut for TildaZ? The original component keeps its other shortcuts.
;
pub const hotkey_takeover_declined_title = "Hotkey unchanged";
pub const hotkey_takeover_declined_format = "Kept the existing binding. To use \"{s}\" for TildaZ, free it from {s} in your desktop's Global Shortcuts settings.";

/// #282 G10 — 위 format bufPrint 실패 시 표시할 fallback (사용자 노출 문자열은
/// 모두 messages.zig 에). Linux native hotkey 경로에서만 발동(희귀).
pub const hotkey_takeover_declined_fallback_msg = "Hotkey unchanged.";

/// About 다이얼로그 본문 — 모든 platform 동일 구조. version / exe / pid /
/// config / log 다음 Tip 라인에 OS 별 단축키 (Windows / Linux Ctrl+Shift+P/L
/// vs macOS Shift+Cmd+P/L) 가 들어감. 사용자가 dialog 안에서 path 를 직접
/// selection + copy (mac NSTextView) 하거나 native Ctrl+C / Cmd+C 로 본문
/// 전체 copy 후 path 만 골라낼 수 있고, Tip 의 단축키로 editor 를 바로 열 수도 있음.
pub const about_format =
    \\TildaZ v{s}
    \\
    \\exe   : {s}
    \\pid   : {d}
    \\config: {s}
    \\log   : {s}
    \\
    \\Tip: {s} opens config in default editor.
    \\     {s} opens log.
    \\
    \\https://github.com/ensky0/tildaz
;
pub const about_prepare_failed_msg =
    "TildaZ could not prepare the full About information. Check the TildaZ log for details.";
pub const log_path_prepare_failed_format =
    "TildaZ could not prepare the log file path: {s}";

pub const panic_format = "panic: {s}\nreturn address: 0x{x}";
pub const panic_fallback_msg = "panic (format failed)";
pub const run_failed_format = "TildaZ failed to start.\n\nError: {s}";
pub const run_failed_fallback_msg = "TildaZ failed to start.";
pub const startup_layer_unmappable_title = "TildaZ could not open its window";
pub const startup_layer_unmappable_msg =
    "The drop-down window could not be placed at the configured size on this display. Try increasing \"window.height_percent\" in the config, then start TildaZ again. If this continues, check the TildaZ log.";
pub const request_endpoint_unavailable_msg =
    "TildaZ is running, but it cannot receive a request to create another instance. Restart TildaZ and try again. If this continues, check the TildaZ log.";
pub const worker_exited_before_endpoint_ready_msg =
    "TildaZ exited before it was ready to receive a request to create another instance. Start TildaZ again and check the log if this continues.";
pub const request_endpoint_ready_timeout_msg =
    "TildaZ did not become ready to create another instance in time. Restart TildaZ and try again. If this continues, check the TildaZ log.";
pub const toggle_unsupported_msg =
    "The --toggle option is only supported on Linux.";

/// #383 — CLI 출력. 창을 띄우기 전에 콘솔로 나가는 유일한 텍스트 묶음이라 dialog 를
/// 거치지 않고 `console.zig` 가 직접 쓴다.
///
/// `--help` 는 **사용자 옵션만** 싣는다. 측정용 `-e` · `-size` · `-scrollback` (#381 ·
/// #382) 은 `run_options.zig` 의 문서 주석대로 내부용이라 여기 없다 — 사용자에게 노출하면
/// "이미 떠 있는 인스턴스와의 관계" 같은 미정 사양을 전부 정해야 한다.
///
/// 이름은 `tildaz` (실행 파일 이름) 로 쓴다. About 다이얼로그의 `TildaZ` 는 제품 이름이고,
/// 여기는 사용자가 방금 친 명령어와 같은 토큰이어야 복붙이 성립한다.
pub const version_line_format = "tildaz {s}";

pub const help_text =
    \\TildaZ — drop-down terminal for Linux, macOS, and Windows.
    \\
    \\Usage:
    \\  tildaz [options]
    \\
    \\Options:
    \\  --instance <N>   Run instance N (default: 0). Each instance keeps its own
    \\                   window, config file, and log file.
    \\  --toggle [N]     Show or hide the running instance N (default: 0), then
    \\                   exit. Linux only.
    \\  --autostart      Start the way the desktop session starts TildaZ.
    \\  -v, --version    Print the version, then exit.
    \\  -h, --help       Print this help, then exit.
    \\
    \\Documentation: https://github.com/ensky0/tildaz
;

/// 인자 오류 세 갈래. 셋 다 `--help` 로 안내해 다음 행동이 한 줄로 이어지게 한다.
/// #383 이전에는 세 경우 모두 아무 말 없이 `exit(2)` 였다 (모르는 옵션은 무시되어
/// 창이 그냥 떴다) — 사용자가 오타를 알아챌 방법이 없었다.
pub const unknown_option_format =
    "tildaz: unknown option \"{s}\"\nRun \"tildaz --help\" to see the available options.";
pub const option_needs_value_format =
    "tildaz: \"{s}\" needs a value.\nRun \"tildaz --help\" to see the available options.";
pub const option_invalid_value_format =
    "tildaz: \"{s}\" is not a valid value for \"{s}\".\nRun \"tildaz --help\" to see the available options.";

/// 위 세 format 의 bufPrint 가 실패할 때 (사용자가 준 인자가 버퍼보다 길 때) 쓴다.
/// 값을 못 넣더라도 다음 행동은 알려 준다.
pub const option_error_fallback_msg =
    "tildaz: invalid command line.\nRun \"tildaz --help\" to see the available options.";

/// run/launcher 오류를 세 platform에서 같은 사용자 문구로 변환한다.
pub fn runFailureMessage(buf: []u8, err: anyerror) []const u8 {
    return switch (err) {
        error.RequestEndpointUnavailable => request_endpoint_unavailable_msg,
        error.WorkerExitedBeforeEndpointReady => worker_exited_before_endpoint_ready_msg,
        error.RequestEndpointReadyTimeout => request_endpoint_ready_timeout_msg,
        else => std.fmt.bufPrint(buf, run_failed_format, .{@errorName(err)}) catch run_failed_fallback_msg,
    };
}

test "request endpoint run errors have specific user messages" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        request_endpoint_unavailable_msg,
        runFailureMessage(&buf, error.RequestEndpointUnavailable),
    );
    try std.testing.expectEqualStrings(
        worker_exited_before_endpoint_ready_msg,
        runFailureMessage(&buf, error.WorkerExitedBeforeEndpointReady),
    );
    try std.testing.expectEqualStrings(
        request_endpoint_ready_timeout_msg,
        runFailureMessage(&buf, error.RequestEndpointReadyTimeout),
    );
    try std.testing.expectEqualStrings(
        "TildaZ failed to start.\n\nError: ExampleFailure",
        runFailureMessage(&buf, error.ExampleFailure),
    );
}

pub const linux_backend_not_ready_msg =
    \\TildaZ for Linux is not implemented yet.
    \\
    \\The accepted direction is a Wayland-first backend. The first alpha target
    \\is a normal Wayland terminal window with PTY, rendering, input,
    \\selection, copy, and paste before full drop-down support is claimed.
    \\
    \\See issue #189 for the current plan.
;

/// Wayland compositor unix socket 에 connect 실패 시 사용자가 보는 메시지.
/// `@errorName(err)` 한 단어로는 진단이 불가능해서 시도한 path, errno name,
/// 그리고 진짜 분기 단서가 되는 세 환경변수 raw 값을 같이 보여준다. X11 세션
/// 에서 실행했을 때 `XDG_SESSION_TYPE=x11` / `WAYLAND_DISPLAY=(unset)` 가
/// 보이면 즉시 원인 식별 가능.
///
/// fmt 슬롯 순서: path, err name, WAYLAND_DISPLAY, XDG_SESSION_TYPE, XDG_RUNTIME_DIR.
pub const linux_wayland_socket_unavailable_format =
    \\TildaZ failed to start: could not connect to the Wayland compositor.
    \\
    \\  socket path:      {s}
    \\  error:            {s}
    \\  WAYLAND_DISPLAY:  {s}
    \\  XDG_SESSION_TYPE: {s}
    \\  XDG_RUNTIME_DIR:  {s}
    \\
    \\TildaZ's Linux backend is Wayland-only. If XDG_SESSION_TYPE is not
    \\"wayland", log in to a Wayland session (GNOME, Cinnamon, KDE Plasma,
    \\sway, Hyprland, etc.). Otherwise verify that the compositor is running
    \\and that the socket path above exists.
;
pub const already_running_msg = "TildaZ is already running.";
pub const unknown_path_msg = "(unknown)";
pub const font_schema_error_path_format = "\n\nConfig path:\n  {s}";
pub const font_not_found_format = "Font not found: \"{s}\"\n\n";
pub const font_chain_header_msg = "config \"font.family\" chain (in order):\n";
pub const font_chain_entry_format = "  - \"{s}\"{s}\n";
pub const font_not_installed_marker = " ← not installed";

/// #405 — 요청한 이름이 **다른 폰트로 해석되는** 경우. 이 줄이 없으면 사용자는 파일도 있고
/// 목록에도 나오는 폰트가 왜 "not found" 인지 알 수 없다 (Linux 실기: `ttf-twemoji` 가
/// `Noto Color Emoji` 요청을 가로채 부팅이 막혔다).
///
/// **Linux 전용이 아니다** — macOS 도 PostScript 이름 (`Menlo-Regular`) · 시스템 UI 폰트
/// (`.SF NS Mono`) 를 적으면 같은 자리에 온다 (#406 실기).
///
/// **세 platform 이 같은 문구를 쓴다.** 원인은 OS 마다 다르지만 (Linux 는 fontconfig 별칭,
/// macOS 는 PostScript · 시스템 UI 이름) 사용자가 할 일은 *"정확한 family 이름을 쓰는 것"* 하나로
/// 같다. OS 별 확인 명령은 `CONFIG.md` 의 "Font names" 절에 있으므로 여기서 반복하지 않는다.
///
/// 예전에는 Linux 문구 (`fc-match` · `/etc/fonts/conf.d/`) 가 하드코딩돼 있어서 **macOS 에서
/// 없는 명령을 안내했다** ([#406](https://github.com/ensky0/tildaz/issues/406) 실기).
pub const font_substituted_format =
    "\nThis name resolves to \"{s}\" instead of \"{s}\".\n" ++
    "Use the exact family name as installed on this system.\n" ++
    "See CONFIG.md \"Font names\" for how to list them.\n";
pub const font_chain_footer_format =
    "\nAll families listed in font.family must be installed on the system.\n\nConfig path:\n{s}\n";

/// glyph fallback chain 의 모든 명시 폰트 lookup 실패 — chain 비어있는 케이스
/// (사용자가 모두 잘못된 이름 명시) 등 edge. strict 검증 path 는 한 개 이름을
/// `font_not_found_format` 으로 표시 (Windows 동등).
pub const font_chain_all_failed_msg =
    \\None of the configured font families are available on this system.
    \\
    \\Tried:
;

/// `font.family` 가 string 이 아닐 때 (대표적으로 array). `font/validate.zig`
/// 의 helper 가 Config path 라인을 붙여 표시.
pub const font_family_must_be_string_msg = "Invalid config: font.family must be a string (font name).";

/// `font.glyph_fallback` 이 string 의 array 가 아닐 때 (다른 type, 또는 array
/// element 가 string 아닌 경우). `font/validate.zig` 의 helper 가 Config path
/// 라인을 붙여 표시.
pub const font_glyph_fallback_must_be_list_msg = "Invalid config: font.glyph_fallback must be a list of strings (fallback font names).";

pub const config_dir_create_failed_format =
    \\Failed to create config directory.
    \\
    \\Path: {s}
    \\Error: {s}
;

pub const config_default_write_failed_format =
    \\Failed to write default config file.
    \\
    \\Path: {s}
    \\Error: {s}
;

pub const config_read_failed_format =
    \\Failed to read config file.
    \\
    \\Path: {s}
    \\Error: {s}
;

pub const config_parse_failed_format =
    \\Failed to parse config file.
    \\
    \\Path: {s}
    \\Error: {s}
;
/// #493 — TOML 파서는 구문 오류의 **위치**를 준다 (JSON 은 오류 이름만 줬다).
/// 어디를 고쳐야 하는지 알 수 있어야 사용자가 스스로 해결한다.
pub const config_parse_failed_at_format =
    \\Failed to parse config file.
    \\
    \\Path: {s}
    \\Line {d}, column {d}
    \\Error: {s}
;
pub const config_parse_failed_fallback_msg = "Failed to parse config file.";

pub const config_error_fallback_msg = "Configuration is invalid.";
pub const config_error_with_path_format = "{s}\n\nConfig path:\n  {s}";
pub const config_error_with_path_fallback_msg = "Configuration is invalid.\n\nConfig path:\n  (unknown)";
pub const config_top_level_must_be_object_msg = "Configuration: top-level must be a JSON object.";
pub const config_dock_position_invalid_format = "Configuration: unknown \"window.dock_position\" value \"{s}\".\n\nAllowed: top, bottom, left, right";
pub const config_dock_position_invalid_fallback_msg = "Configuration: window.dock_position invalid";
pub const config_field_number_required_format = "Configuration: \"{s}\" must be a number.";
pub const config_field_range_required_format = "Configuration: \"{s}\" must be in {s}.";
pub const config_field_integer_range_required_format = "Configuration: \"{s}\" must be an integer in {s}.";
pub const config_unknown_theme_header_format = "Configuration: unknown theme \"{s}\"\n\nAvailable themes:\n";
/// #484 — 거부 이유가 둘인데 메시지가 하나였다. `ctrl+twosuperior` 는 이미 modifier 가
/// 있는데도 "Other keys require Ctrl, Alt, Super, or Cmd" 를 받아, 신고자가 modifier 를
/// 더해 보고도 같은 안내를 다시 받았다. 실제 원인 (모르는 key 이름) 을 알 방법이 없었다.
/// 이제 원인별로 갈라 보낸다 — `config.HotkeyFailure` 참고.
///
/// key 이름을 못 알아본 경우. **받는 key 목록을 함께 준다** — 안 되는 이유만 알려 주고
/// 무엇이 되는지 안 알려 주면 사용자가 또 추측해야 한다.
/// #493 — `[keys]` 의 같은 키가 두 액션에 걸린 경우. **양쪽 액션을 다 짚는다** —
/// 한쪽만 알려주면 사용자가 나머지를 찾아 헤맨다 (#484 의 hotkey 메시지 교훈).
/// 바인딩 총량 상한. 조용히 잘라 버리면 사용자가 적은 단축키가 이유 없이 안 먹는다.
pub const config_key_too_many_format = "Configuration: too many key bindings in [keys] (limit {d}).";
pub const config_key_too_many_fallback_msg = "Configuration: too many key bindings in [keys]";
pub const config_key_conflict_format = "Configuration: \"{s}\" is bound to both \"{s}\" and \"{s}\" in [keys].\n\nEach key may trigger only one action. Remove it from one of them.";
pub const config_key_conflict_fallback_msg = "Configuration: the same key is bound to two actions in [keys]";
/// `[keys]` 의 값이 리스트가 아닌 경우.
pub const config_key_not_list_format = "Configuration: \"keys.{s}\" must be a list of key combinations.\n\nExample: {s} = [\"ctrl+shift+t\"]\nUse an empty list [] to leave the action unbound.";
pub const config_key_not_list_fallback_msg = "Configuration: a [keys] entry must be a list";
/// `[keys]` 의 키 문자열을 파싱하지 못한 경우. `hotkey` 와 달리 액션 이름을 함께 짚는다.
pub const config_key_invalid_format = "Configuration: \"keys.{s}\" contains a key TildaZ does not recognize: \"{s}\".\n\nAccepted keys: F1-F12, A-Z, 0-9, space, tab, escape, return, grave (`), pageup, pagedown, [ , ]\nAccepted modifiers: ctrl, shift, alt, super (also win / cmd / meta)\n\nKeys outside this list are not supported yet, including layout-specific ones.";
pub const config_key_invalid_fallback_msg = "Configuration: a [keys] entry uses an unrecognized key";
/// 글자를 내는 키를 modifier 없이 바인딩한 경우 — 그 글자를 터미널에 칠 수 없게 된다.
pub const config_key_needs_modifier_format = "Configuration: \"keys.{s}\" binds \"{s}\" without Ctrl, Alt, or Cmd.\n\nThat key types text, so binding it alone would make it impossible to type in the terminal. Keys that do not type text (F1-F12, PageUp, PageDown) may be bound without a modifier.";
pub const config_key_needs_modifier_fallback_msg = "Configuration: a [keys] entry needs a modifier";
pub const config_hotkey_unknown_key_format = "Configuration: \"hotkey\" value \"{s}\" uses a key TildaZ does not recognize.\n\nAccepted keys: F1-F12, A-Z, 0-9, space, tab, escape, return, grave (`), pageup, pagedown, [ , ]\nAccepted modifiers: ctrl, shift, alt, super (also win / cmd / meta)\n\nKeys outside this list are not supported yet, including layout-specific ones.\n\nExamples: \"f1\", \"ctrl+space\", \"shift+cmd+t\"";
pub const config_hotkey_unknown_key_fallback_msg = "Configuration: hotkey uses an unrecognized key";
/// key 는 유효하지만 modifier 가 없어 전역 등록이 위험한 경우 (일상 입력을 OS 전체에서
/// 가로챈다). 이쪽은 기존 안내가 정확했다.
pub const config_hotkey_invalid_format = "Configuration: failed to parse \"hotkey\" value \"{s}\".\n\nOnly F1-F12 may be used without modifiers. Other keys require Ctrl, Alt, Super, or Cmd.\n\nExamples: \"f1\", \"ctrl+space\", \"shift+cmd+t\"";
pub const config_hotkey_invalid_fallback_msg = "Configuration: hotkey invalid";
/// #431 — 다른 TildaZ 인스턴스가 이미 쓰는 전역 핫키. 뒤에 있는 (index 가 큰) 쪽이 양보하므로
/// 이 메시지는 그 인스턴스에만 나온다. **겹친 상대를 번호로 짚어 주는 것이 핵심이다** — 예전엔
/// Windows 의 `RegisterHotKey` 실패 안내가 "Another app already registered the same combination"
/// 이라고만 해서, 원인이 자기 다른 인스턴스라는 것도 몇 번인지도 알 수 없었다.
pub const config_hotkey_duplicate_format =
    "The hotkey \"{s}\" is already used by TildaZ {d}.\n\n" ++
    "Each TildaZ instance needs its own global hotkey. Change \"hotkey\" in this instance's config and start it again.";
pub const config_hotkey_duplicate_fallback_msg =
    "This hotkey is already used by another TildaZ instance. Change \"hotkey\" in this instance's config and start it again.";
pub const config_font_family_empty_msg = "Configuration: \"font.family\" must not be empty.";
pub const config_font_chain_too_long_format = "Configuration: font.family + glyph_fallback total exceeds {d} entries.";
pub const config_font_chain_too_long_fallback_msg = "Configuration: font chain too long";
pub const config_type_mismatch_format = "Configuration: type mismatch at \"{s}\" — expected {s}, got {s}.";
pub const config_type_mismatch_fallback_msg = "Configuration: type mismatch";
pub const config_missing_key_format = "Configuration: missing required key \"{s}\" in {s}.";
pub const config_missing_key_fallback_msg = "Configuration: missing key";
pub const config_unknown_key_format = "Configuration: unknown key \"{s}\" in {s}.";
pub const config_unknown_key_fallback_msg = "Configuration: unknown key";

pub const shell_empty_format =
    "Configuration: \"shell\" is empty.\n\n{s}\n\nConfig path:\n{s}";
pub const shell_empty_fallback_msg = "Configuration: shell is empty.";
pub const shell_first_token_empty_format =
    "Configuration: \"shell\" first token is empty.\n\nValue: \"{s}\"\n\n{s}\n\nConfig path:\n{s}";
pub const shell_first_token_empty_fallback_msg = "Configuration: shell first token empty.";
pub const shell_executable_not_found_format =
    "Configuration: shell executable not found.\n\n\"shell\" value: \"{s}\"\nLookup token: \"{s}\"\n\n{s}\n\nConfig path:\n{s}";
pub const shell_executable_not_found_fallback_msg = "Configuration: shell executable not found.";

// #248 — 런타임 새 탭 생성 시 shell 바이너리가 사라진 경우 (brew/패키지 업데이트로
// 경로 변경 등). startup fatal 과 달리 종료하지 않고 OK 하나짜리 알림만.
pub const shell_new_tab_error_title = "TildaZ — Cannot Open New Tab";
pub const shell_new_tab_not_found_format =
    "The configured shell could not be found:\n  \"{s}\"\n\nCheck \"shell\" in this instance's config file:\n  {s}";
pub const shell_new_tab_not_found_fallback_msg = "The configured shell could not be found. Check \"shell\" in this instance's config file.";

pub const shell_examples_windows =
    \\Examples:
    \\  "cmd.exe"
    \\  "powershell.exe"
    \\  "wsl.exe -d Debian"
    \\  "C:\\Windows\\System32\\cmd.exe"
;
// macOS 와 Linux 공용 — 둘 다 POSIX 절대 경로를 기대한다. Linux startup shell 검증
// (#282 C2) 이 이 dialog 를 Linux 에서도 띄우므로 "macOS" 로 못박지 않는다.
pub const shell_examples_posix =
    \\Expects an absolute path to an executable. Examples:
    \\  "/bin/bash"
    \\  "/bin/zsh"
    \\  "/usr/bin/fish"
;

/// #339 — Windows 전용. 번들 ConPTY 런타임(`_internal\conpty.dll` +
/// `_internal\OpenConsole.exe`)은 필수다. 시작 시 하나라도 없으면 시스템 conhost
/// 로 조용히 degrade 하지 않고 이 fatal 다이얼로그를 띄운 뒤 종료한다 (보통
/// `_internal` 폴더가 tildaz.exe 옆에서 분리 / 삭제 / AV 격리된 신호).
pub const conpty_missing_title = "TildaZ — Cannot Start";
pub const conpty_missing_msg =
    \\TildaZ is missing its bundled console runtime and cannot start.
    \\
    \\The "_internal" folder next to tildaz.exe must contain both conpty.dll and OpenConsole.exe, but one or both are missing.
    \\
    \\This usually means the "_internal" folder was separated from tildaz.exe (for example, only tildaz.exe was copied elsewhere), it was deleted, or security software quarantined it.
    \\
    \\Re-extract or reinstall TildaZ, keeping the "_internal" folder together with tildaz.exe.
;

/// #363 — Windows 전용. Direct3D 11 하드웨어 device 생성이 실패하면 renderer 가
/// 스스로 WARP (OS 내장 소프트웨어 래스터라이저) 로 재시도하고, 그것마저 실패해
/// error 가 host 까지 올라왔을 때만 이 fatal 을 띄운 뒤 종료한다. 이전엔 renderer
/// 를 null 로 둔 채 계속 실행해서 창은 뜨지만 그리는 주체가 없는 빈 창이 됐다 —
/// 사용자가 원인을 알 수 없는 상태였다.
/// `{s}` 두 개는 각각 최종 error 이름과 로그 파일 경로. 하드웨어 실패 원인은
/// 로그의 `[d3d] hardware renderer failed:` 줄에 남는다.
pub const renderer_init_failed_title = "TildaZ — Cannot Start";
pub const renderer_init_failed_format =
    \\TildaZ could not initialize its renderer and cannot start.
    \\
    \\Both the GPU (hardware) and CPU (software, WARP) rendering paths failed: {s}
    \\
    \\This usually means the graphics driver is missing, outdated, or malfunctioning. Updating or reinstalling the graphics driver is the most common fix.
    \\
    \\Full details were written to the log:
    \\{s}
;
/// 위 format 의 bufPrint 가 실패했을 때만 쓰는 고정 문구.
pub const renderer_init_failed_fallback_msg =
    \\TildaZ could not initialize its renderer and cannot start.
    \\
    \\Both the GPU (hardware) and CPU (software) rendering paths failed. This usually means the graphics driver is missing, outdated, or malfunctioning.
;

pub const hotkey_registration_failed_title = "TildaZ — Hotkey Registration Failed";
pub const hotkey_registration_failed_format =
    \\Failed to register the global hotkey (vkey=0x{x:0>2}, modifiers=0x{x}).
    \\
    \\Common causes:
    \\• The OS reserves the key (F12 is reserved for the kernel debugger and cannot be a global hotkey)
    \\• Another app already registered the same combination
    \\• Windows shell intercepts the combination first (some Win+Shift+letter shortcuts)
    \\
    \\Edit the config and restart:
    \\{s}
;
pub const hotkey_registration_failed_fallback_msg = "Failed to register the global hotkey. Edit this instance's config file and restart.";

pub const new_instance_title = "Create TildaZ Instance";
pub const new_instance_hotkey_prompt_format =
    "A total of {d} TildaZ instances will run.\n\nPress a hotkey for the new instance.";
pub const new_instance_hotkey_invalid_msg =
    "That hotkey is invalid. Press another combination, for example F2, Ctrl+Space, or Shift+Cmd+T.";
pub const new_instance_hotkey_duplicate_format =
    "Already used by TildaZ {d}.";
pub const new_instance_hotkey_duplicate_fallback =
    "Already used by another TildaZ instance.";
pub const new_instance_hotkey_check_failed_msg =
    "Could not check existing TildaZ hotkeys.";
pub const new_instance_create_failed_format = "The new TildaZ instance could not be created.\n\n{s}";
pub const new_instance_create_failed_fallback_msg = "The new TildaZ instance could not be created.";

pub const macos_menu_open_config_label = "Open Config";
pub const macos_menu_open_log_label = "Open Log";
pub const macos_menu_quit_label = "Quit TildaZ";
pub const macos_menu_edit_label = "Edit";
pub const macos_menu_emoji_symbols_label = "Emoji & Symbols";

pub const macos_permission_required_title = "TildaZ — Permission required";
pub const macos_permission_required_format =
    \\TildaZ needs two macOS permissions to work.
    \\Without them the {s} hotkey will not respond.
    \\(Cmd+Q from the menu still works either way.)
    \\
    \\Please follow these steps:
    \\
    \\Step 1 — Input Monitoring
    \\  1. Open the Apple menu  →  System Settings.
    \\  2. In the sidebar, click "Privacy & Security".
    \\  3. Scroll down and click "Input Monitoring".
    \\  4. Look for "tildaz" in the list:
    \\       • If it is there, turn the switch ON.
    \\       • If not, click the "+" button at the bottom,
    \\         find TildaZ.app, click Open, then turn it ON.
    \\
    \\Step 2 — Accessibility
    \\  1. Click "< Privacy & Security" to go back.
    \\  2. Click "Accessibility" instead.
    \\  3. Same as above: turn "tildaz" ON,
    \\     or click "+" to add TildaZ.app and then turn it ON.
    \\
    \\Step 3 — Restart TildaZ
    \\  Quit and relaunch this app for the new permissions to take effect.
    \\
    \\Current status:
    \\  Input Monitoring : {s}
    \\  Accessibility    : {s}
    \\
    \\(Developer note: ad-hoc signed builds get a new identity on each
    \\rebuild, so permissions must be re-granted after every rebuild.)
;
pub const macos_permission_required_fallback_msg = "TildaZ needs Input Monitoring and Accessibility permissions. Open System Settings -> Privacy & Security and enable both for tildaz.";
pub const permission_status_granted = "GRANTED";
pub const permission_status_missing = "MISSING";

test "macOS menu labels and new-instance fallback preserve user text" {
    try std.testing.expectEqualStrings("About TildaZ", about_title);
    try std.testing.expectEqualStrings("Open Config", macos_menu_open_config_label);
    try std.testing.expectEqualStrings("Open Log", macos_menu_open_log_label);
    try std.testing.expectEqualStrings("Quit TildaZ", macos_menu_quit_label);
    try std.testing.expectEqualStrings("Edit", macos_menu_edit_label);
    try std.testing.expectEqualStrings("Emoji & Symbols", macos_menu_emoji_symbols_label);
    try std.testing.expectEqualStrings(
        "The new TildaZ instance could not be created.",
        new_instance_create_failed_fallback_msg,
    );
}
