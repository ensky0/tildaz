//! 모든 사용자 표시 텍스트의 단일 진입점. cross-platform.
//!
//! 같은 의미의 메시지를 platform 별로 두 번 작성하지 않게 한다. format string
//! 은 여기서 정의하고 실제 표시는 호출처가 `dialog.zig` 로 위임.

pub const config_error_title = "TildaZ Config Error";
pub const about_title = "About TildaZ";
pub const error_title = "TildaZ Error";
pub const crash_title = "TildaZ Crash";
pub const info_title = "TildaZ";
pub const quit_confirm_title = "Quit TildaZ?";

/// 종료 확인 (#116). 한 번에 사라지는 탭 수를 본문에 박아 사용자가 잃을
/// 작업량을 즉시 인지하게. {s} 는 영어 복수형 처리 — count==1 이면 "" else "s".
pub const quit_confirm_format = "This will close {d} open tab{s}.";

/// 새 탭 한도 도달 시 (`session_core.MAX_TABS`). `+` 버튼은 layout 에서 자동
/// 사라지지만 단축키 (Cmd+T / Ctrl+Shift+T) 시도 시 무반응 = 사용자 인지 어려움
/// → 명시적 dialog. {d} 는 한도 (현재 32).
pub const tab_limit_title = "Tab limit reached";
pub const tab_limit_format = "Maximum {d} tabs are open. Close a tab to create a new one.";

/// About 다이얼로그 본문 — 양쪽 platform 동일 구조. version / exe / pid /
/// config / log 다음 Tip 라인에 OS 별 단축키 (Windows Ctrl+Shift+P/L vs macOS
/// Shift+Cmd+P/L) 가 들어감. 사용자가 dialog 안에서 path 를 직접 selection +
/// copy (mac NSTextView) 하거나 native Ctrl+C / Cmd+C 로 본문 전체 copy 후
/// path 만 골라낼 수 있고, Tip 의 단축키로 editor 를 바로 열 수도 있음.
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

pub const panic_format = "panic: {s}\nreturn address: 0x{x}";
pub const panic_fallback_msg = "panic (format failed)";
pub const run_failed_format = "TildaZ failed to start.\n\nError: {s}";
pub const run_failed_fallback_msg = "TildaZ failed to start.";
pub const linux_backend_not_ready_msg =
    \\TildaZ for Linux is not implemented yet.
    \\
    \\The accepted direction is a Wayland-first backend. The first alpha target
    \\is a normal Wayland terminal window with PTY, rendering, input,
    \\selection, copy, and paste before full drop-down support is claimed.
    \\
    \\See LINUX.md and issue #189 for the current plan.
;
pub const already_running_msg = "TildaZ is already running.";
pub const font_not_found_format = "Font not found: \"{s}\"";

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
    \\Failed to parse config JSON.
    \\
    \\Path: {s}
    \\Error: {s}
;
pub const config_parse_failed_fallback_msg = "Failed to parse config JSON.";

pub const config_error_fallback_msg = "config.json: invalid config.";
pub const config_top_level_must_be_object_msg = "config.json: top-level must be a JSON object.";
pub const config_dock_position_invalid_format = "config.json: unknown \"window.dock_position\" value \"{s}\".\n\nAllowed: top, bottom, left, right";
pub const config_dock_position_invalid_fallback_msg = "config.json: window.dock_position invalid";
pub const config_field_number_required_format = "config.json: \"{s}\" must be a number.";
pub const config_field_range_required_format = "config.json: \"{s}\" must be in {s}.";
pub const config_field_integer_range_required_format = "config.json: \"{s}\" must be an integer in {s}.";
pub const config_unknown_theme_header_format = "config.json: unknown theme \"{s}\"\n\nAvailable themes:\n";
pub const config_hotkey_invalid_format = "config.json: failed to parse \"hotkey\" value \"{s}\".\n\nExamples: \"f1\", \"ctrl+space\", \"shift+cmd+t\"";
pub const config_hotkey_invalid_fallback_msg = "config.json: hotkey invalid";
pub const config_font_family_empty_msg = "config.json: \"font.family\" must not be empty.";
pub const config_font_chain_too_long_format = "config.json: font.family + glyph_fallback total exceeds {d} entries.";
pub const config_font_chain_too_long_fallback_msg = "config.json: font chain too long";
pub const config_type_mismatch_format = "config.json: type mismatch at \"{s}\" — expected {s}, got {s}.";
pub const config_type_mismatch_fallback_msg = "config.json: type mismatch";
pub const config_missing_key_format = "config.json: missing required key \"{s}\" in {s}.";
pub const config_missing_key_fallback_msg = "config.json: missing key";
pub const config_unknown_key_format = "config.json: unknown key \"{s}\" in {s}.";
pub const config_unknown_key_fallback_msg = "config.json: unknown key";

pub const shell_empty_format =
    "config.json: \"shell\" is empty.\n\n{s}\n\nConfig path:\n{s}";
pub const shell_empty_fallback_msg = "config.json: shell is empty.";
pub const shell_first_token_empty_format =
    "config.json: \"shell\" first token is empty.\n\nValue: \"{s}\"\n\n{s}\n\nConfig path:\n{s}";
pub const shell_first_token_empty_fallback_msg = "config.json: shell first token empty.";
pub const shell_executable_not_found_format =
    "config.json: shell executable not found.\n\n\"shell\" value: \"{s}\"\nLookup token: \"{s}\"\n\n{s}\n\nConfig path:\n{s}";
pub const shell_executable_not_found_fallback_msg = "config.json: shell executable not found.";
pub const shell_examples_windows =
    \\Examples:
    \\  "cmd.exe"
    \\  "powershell.exe"
    \\  "wsl.exe -d Debian --cd ~"
    \\  "C:\\Windows\\System32\\cmd.exe"
;
pub const shell_examples_macos =
    \\macOS expects an absolute path to an executable. Examples:
    \\  "/bin/zsh"
    \\  "/bin/bash"
    \\  "/usr/local/bin/fish"
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
pub const hotkey_registration_failed_fallback_msg = "Failed to register the global hotkey. Edit %APPDATA%\\tildaz\\config.json and restart.";

pub const macos_permission_required_title = "TildaZ — Permission required";
pub const macos_permission_required_format =
    \\TildaZ needs two macOS permissions to work.
    \\Without them the F1 hotkey will not respond.
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
