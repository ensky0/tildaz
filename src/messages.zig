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
/// #483 4c — `…` 메뉴의 분할 항목 둘 (확정 설계: 아이콘을 늘리지 않고 메뉴에 넣는다).
pub const command_split_vertical = "Split Vertical";
pub const command_split_horizontal = "Split Horizontal";
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
/// #483 — 분할 항목 hint. 기존 hint 처럼 키 이름을 글자로 적는다 (`Enter` 와 같은 표기).
pub const shortcut_split_vertical = "Ctrl+Shift+Right";
pub const shortcut_split_vertical_macos = "Option+Cmd+Right";
pub const shortcut_split_horizontal = "Ctrl+Shift+Down";
pub const shortcut_split_horizontal_macos = "Option+Cmd+Down";
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

/// #483 — 분할 거부 안내. 단축키에는 시각 피드백이 없어 탭 한도와 같은 dialog 로 알린다
/// (확정 설계 §② "거부 + 안내"). {d} 는 `pane_layout.MAX_PANES_PER_TAB` (16).
pub const pane_limit_title = "Pane limit reached";
pub const pane_limit_format = "This tab already has {d} panes. Close one to split again.";
/// 결과 pane 이 `pane_layout.MIN_PANE_COLS × MIN_PANE_ROWS` 아래로 내려갈 때. {d}x{d} 는 그 최소.
pub const pane_too_small_title = "Not enough room to split";
pub const pane_too_small_format = "Each pane needs at least {d} columns × {d} rows. Enlarge the window or close a pane first.";

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
    \\  --instance <N>   Run instance N, 0 to 9 (default: 0). Each instance keeps
    \\                   its own window, config file, log file, and hotkey. A new
    \\                   config defaults to F1 for instance 0, F2 for 1, and so on.
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

/// #510 — `--instance N` 의 상한. `option_invalid_value_format` 으로 대신하면 "10 이 왜
/// 안 되는지" 를 알 방법이 없다. 그 숫자는 파일명 규칙이 아니라 **인스턴스마다 기본 핫키를
/// 하나씩 주기 때문에** 나온 것이라, 범위와 이유를 같이 적는다.
pub const option_instance_out_of_range_format =
    "tildaz: \"{s}\" is out of range for \"--instance\" — pick 0 to {d}.\nEach instance gets its own default hotkey, F1 through F10.\nRun \"tildaz --help\" to see the available options.";

/// 위 세 format 의 bufPrint 가 실패할 때 (사용자가 준 인자가 버퍼보다 길 때) 쓴다.
/// 값을 못 넣더라도 다음 행동은 알려 준다.
pub const option_error_fallback_msg =
    "tildaz: invalid command line.\nRun \"tildaz --help\" to see the available options.";

/// [#506](https://github.com/ensky0/tildaz/issues/506) — `-size` 로 요청한 격자를
/// 끝까지 지킬 수 없을 때의 거부 문구. **다이얼로그가 아니라 stderr + exit(2)** 로
/// 낸다: `-size` 는 `--help` 에 싣지 않는 측정 전용 옵션이라 호출처가 사람이 아니라
/// 스크립트인 경우가 많고, 모달을 띄우면 그 스크립트가 그 자리에서 멈춘다 (AGENTS.md
/// 의 "config 를 만들려고 그냥 띄우면 …" 함정과 같은 종류다).
///
/// 필요한 크기를 함께 적는 이유 — 사용자가 격자를 얼마나 줄여야 하는지 바로 보인다.
/// 크기에 탭바가 포함돼 있다는 것도 밝힌다. 안 그러면 "창이 이만큼 큰데 왜 안 되지"
/// 로 읽힌다.
pub const size_does_not_fit_format =
    "tildaz: \"-size {d}x{d}\" does not fit this screen.\n" ++
    "It needs a {d}x{d} px window (tab bar included) but the work area is {d}x{d} px.\n" ++
    "The requested grid is kept exactly, so a window that cannot hold it would push the bottom row off screen.\n" ++
    "Use a smaller grid.";

/// #506 — layer-shell 경로를 타지 않는 Wayland 데스크톱에서 `-size` 를 거부하는 문구.
/// 그곳은 창 크기를 compositor 가 정해서 요청 격자와 창이 어긋난 채로 돌아가고, 그 사실이
/// 겉으로 드러나지 않는다 — 측정값이 조용히 틀린다.
///
/// **두 가지 경우를 한 문구로 덮는다.** (1) compositor 가 `zwlr_layer_shell_v1` 을 아예
/// 안 내주는 GNOME · Cinnamon, (2) 내주지만 **우리가 일부러 안 쓰는** sway — sway 는
/// `on_demand` layer surface 에 map 시 키보드 포커스를 주지 않아 xdg_toplevel 경로로
/// 보낸다 ([#454](https://github.com/ensky0/tildaz/issues/454)). 그래서 "compositor 가
/// 지원하지 않는다" 가 아니라 "여기서는 그 경로를 쓰지 않는다" 로 적는다.
pub const size_needs_layer_shell_msg =
    "tildaz: \"-size\" cannot be used on this desktop.\n" ++
    "It sizes the window through the wlr-layer-shell protocol, which TildaZ does not use here, " ++
    "so the window size is up to the compositor and would not match the requested grid.\n" ++
    "Run the measurement on KDE Plasma, Hyprland, or COSMIC.";

/// 위 두 문구의 bufPrint 가 실패할 때 (값이 버퍼를 넘길 때) 쓴다.
pub const size_error_fallback_msg =
    "tildaz: \"-size\" cannot be honored on this screen.";

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

/// #501 — config 를 읽지 못하거나 만들지 못했을 때. **fatal 이 아니다.**
///
/// 시작을 거부하면 사용자가 스스로 잠긴다 — config 를 고치려면 편집기가 필요하고
/// 편집기를 띄우려면 터미널이 필요한데, tildaz 가 그 터미널이면 벗어날 방법이 없다.
/// 그래서 안내하고 기본값으로 계속 돈다.
///
/// **"그래서 지금 어떤 상태인가" 를 반드시 말한다.** 오류만 알려 주고 결과를 안
/// 알려 주면 사용자는 자기 설정이 적용됐는지 아닌지 모른 채 쓰게 된다 — 그것이
/// 이 이슈의 원래 증상 (조용한 기본값 동작) 과 사실상 같다.
///
/// 경로는 본문에 없다 — `configErrorMessageAlloc` 이 첫 줄로 붙인다 (#495).
pub const config_read_failed_format =
    \\Failed to read the config file.
    \\
    \\Error: {s}
    \\
    \\TildaZ started with default settings -- nothing from this file was applied.
    \\Fix the file above, then start TildaZ again.
;

pub const config_dir_create_failed_format =
    \\Failed to create the config file.
    \\
    \\Error: {s}
    \\
    \\TildaZ started with default settings. There is no file to edit yet -- check
    \\the permissions on that folder, then start TildaZ again.
;

pub const config_default_write_failed_format =
    \\Failed to write the config file.
    \\
    \\Error: {s}
    \\
    \\TildaZ started with default settings. The file may be missing or incomplete
    \\-- check the permissions on that folder, then start TildaZ again.
;

/// #501 — 이 안내는 fatal 이 아니므로 제목도 "error" 가 아니다. 사용자가 지금 쓰고
/// 있는 인스턴스는 정상 동작하고, 다만 설정이 반영되지 않았다.
///
/// 세 경우 (못 읽음 · 못 만듦 · 못 씀) 를 한 제목으로 덮는다. 각각을 따로 두면
/// "Not Loaded" 가 만들기 실패에 어색해지는데 (애초에 읽을 것이 없었다), 사용자에게
/// 중요한 것은 원인이 아니라 **지금 기본값으로 돌고 있다**는 사실이다.
pub const config_not_loaded_title = "TildaZ — Using Default Settings";

/// #495 — **경로를 담지 않는다.** `showConfigFatalMsg` 가 모든 config 오류 앞에 한
/// 번 붙인다. 예전엔 파싱 오류만 본문 셋째 줄에 `Path:` 를 넣고 의미 오류는 맨 끝에
/// 넣어, 같은 다이얼로그에서 경로 위치가 오류 종류에 따라 달랐다.
pub const config_parse_failed_format =
    \\Failed to parse config file.
    \\
    \\Error: {s}
;
/// #493 — TOML 파서는 구문 오류의 **위치**를 준다 (JSON 은 오류 이름만 줬다).
/// 어디를 고쳐야 하는지 알 수 있어야 사용자가 스스로 해결한다.
pub const config_parse_failed_at_format =
    \\Failed to parse config file.
    \\
    \\Line {d}, column {d}
    \\Error: {s}
;
pub const config_parse_failed_fallback_msg = "Failed to parse config file.";

pub const config_error_fallback_msg = "Configuration is invalid.";
/// #495 — **경로가 첫 줄이다.** 사용자가 오류 내용을 읽기 *전에* 눈에 들어와야 한다.
/// 예전엔 맨 끝이었고, 읽는 순서상 "오류를 읽고 → 고쳐야겠다 판단하고 → 다이얼로그를
/// 닫은 뒤" 경로가 필요해졌다. 위쪽 문구가 명확할수록 (`missing required key
/// "window"`) 더 빨리 닫으므로 더 잘 놓쳤다. 실제로 사용자가 겪었다 (2026-08-22).
///
/// 그리고 **모든 config 오류가 이 한 형식을 지난다** — 파싱 오류든 의미 오류든.
/// 형식이 두 갈래였던 것이 위치 불일치의 원인이었다.
pub const config_error_with_path_format = "Config: {s}\n\n{s}";
/// `allocPrint` 실패 시. **경로 자리를 비우지 않는다** — 예전 파싱 쪽 fallback 은
/// 경로를 아예 잃어서 (`"Failed to parse config JSON."`) 정작 가장 도움이 필요한
/// 상황에서 가장 적은 정보를 줬다.
pub const config_error_with_path_fallback_msg = "Config: (unknown)\n\nConfiguration is invalid.";
pub const config_dock_position_invalid_format = "Configuration: unknown \"window.dock_position\" value \"{s}\".\n\nAllowed: top, bottom, left, right";
pub const config_dock_position_invalid_fallback_msg = "Configuration: window.dock_position invalid";
pub const config_macos_option_as_alt_invalid_format = "Configuration: unknown \"input.macos_option_as_alt\" value \"{s}\".\n\nAllowed: none, both, left, right";
pub const config_macos_option_as_alt_invalid_fallback_msg = "Configuration: input.macos_option_as_alt invalid";
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
/// #496 — 위치 표기를 macOS 에서 쓸 수 없는 두 경우. 안내가 갈리는 이유는 원인이
/// 다르기 때문이다 — 하나는 **키가 다른 이름으로 보고되는 것**이고 다른 하나는
/// **정말 없는 것**이다. 한 메시지로 묶으면 앞쪽 사용자에게 "쓸 수 없다" 고 말하게
/// 되는데 실제로는 이름만 바꾸면 되는 상황이다 (#484 의 교훈).
pub const config_key_position_aliased_format = "Configuration: \"keys.{s}\" uses {s}, and macOS reports that key under a different name.\n\nOn a PC keyboard attached to a Mac, PrintScreen, ScrollLock and Pause arrive as F13, F14 and F15 -- Apple's extended keyboard puts those function keys in the same spots.\n\nUse [F13], [F14] or [F15] instead.";
pub const config_key_position_aliased_fallback_msg = "Configuration: on macOS use [F13] / [F14] / [F15] for PrintScreen / ScrollLock / Pause";
pub const config_key_position_absent_format = "Configuration: \"keys.{s}\" uses {s}, which macOS does not provide.\n\nApple's key codes stop at F20, and the Japanese input-switching keys (Convert, NonConvert, KanaMode) are handled by the input method rather than delivered as keys.\n\nPick a different key for this action, or leave it unbound with an empty list [].";
pub const config_key_position_absent_fallback_msg = "Configuration: that key position does not exist on macOS";
pub const config_hotkey_unknown_key_format = "Configuration: \"hotkey\" value \"{s}\" uses a key TildaZ does not recognize.\n\nAccepted keys: F1-F12, A-Z, 0-9, space, tab, escape, return, grave (`), pageup, pagedown, [ , ]\nAccepted modifiers: ctrl, shift, alt, super (also win / cmd / meta)\n\nKeys outside this list are not supported yet, including layout-specific ones.\n\nExamples: \"f1\", \"ctrl+space\", \"shift+cmd+t\"";
pub const config_hotkey_unknown_key_fallback_msg = "Configuration: hotkey uses an unrecognized key";
/// key 는 유효하지만 modifier 가 없어 전역 등록이 위험한 경우 (일상 입력을 OS 전체에서
/// 가로챈다). 이쪽은 기존 안내가 정확했다.
pub const config_hotkey_invalid_format = "Configuration: failed to parse \"hotkey\" value \"{s}\".\n\nOnly F1-F12 may be used without modifiers. Other keys require Ctrl, Alt, Super, or Cmd.\n\nExamples: \"f1\", \"ctrl+space\", \"shift+cmd+t\"";
pub const config_hotkey_invalid_fallback_msg = "Configuration: hotkey invalid";
// #496 1-c — 위치 표기를 전역 `hotkey` 에서 거부하던 안내 두 개가 여기 있었다. 이제
// 받으므로 지웠다. 등록이 실패할 수 있는 자리는 남아 있지만 (그 layout 에서 그 자리가
// dead key 이거나 글자를 안 내는 경우) 그것은 **파싱이 아니라 등록 시점**에만 알 수
// 있어 다이얼로그가 아니라 로그로 알린다 — config 를 읽는 시점에는 사용자의 자판이
// 무엇을 내는지 모른다.

/// #496 1-c — **macOS 의 자리 거부는 전역 `hotkey` 에도 온다.** 위치 표기를 받기
/// 시작하면서 생긴 경로다 — 그전에는 위치 표기가 파싱 앞단에서 막혀 이 둘이 `[keys]`
/// 에서만 났고, 그래서 hotkey 쪽 config 로드부가 `unreachable` 로 두고 있었다.
///
/// 그 `unreachable` 은 ReleaseFast 에서 안전 검사가 없어 **`modifier_required` 안내로
/// 떨어졌다** (macOS 실기 확인). `ctrl` 을 이미 준 사용자에게 "modifier 를 달라" 고
/// 말하는 것이라, #484 가 "거부 이유별로 다른 안내를 보낸다" 로 막으려던 실패 그대로다.
pub const config_hotkey_position_aliased_format = "Configuration: \"hotkey\" value \"{s}\" uses a key position that macOS reports under a different name.\n\nOn a PC keyboard attached to a Mac, PrintScreen, ScrollLock and Pause arrive as F13, F14 and F15 -- Apple's extended keyboard puts those function keys in the same spots.\n\nUse [F13], [F14] or [F15] instead.";
pub const config_hotkey_position_aliased_fallback_msg = "Configuration: on macOS use [F13] / [F14] / [F15] for PrintScreen / ScrollLock / Pause";
pub const config_hotkey_position_absent_format = "Configuration: \"hotkey\" value \"{s}\" uses a key position that macOS does not provide.\n\nApple's key codes stop at F20, and the Japanese input-switching keys (Convert, NonConvert, KanaMode) are handled by the input method rather than delivered as keys.\n\nPick a different key for the hotkey.";
pub const config_hotkey_position_absent_fallback_msg = "Configuration: that key position does not exist on macOS";
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
/// #483 (2026-08-27 사용자 결정) — 새 버전이 키를 더하면 이전 파일이 여기서 걸린다 (strict schema 는 유지,
/// 파일에 자동으로 써 넣지 않는다). 사용자가 할 일을 한 문단으로: 파일을 **옮겨 두고** (지우지 말고) 다시 띄우면
/// 기본 파일이 새로 생기니, 바꿔 둔 값을 다시 옮겨 적으라. 세 platform 이 같은 문구다.
pub const config_missing_key_format = "Configuration: missing required key \"{s}\" in {s}.\n\n" ++
    "This file was written by an older version and lacks keys the current version needs. " ++
    "Move the file aside (for example add .bak to its name) and start TildaZ again -- " ++
    "a fresh default file will be created. Then copy back any values you had changed.";
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

/// #510 — Linux 의 전역 hotkey 획득 실패. 세 platform 이 같은 정책 (**못 잡으면 멈춘다**)
/// 을 쓰지만 문구는 갈라야 한다: Windows 는 OS 의 hotkey 표가 상대이고, macOS 는 권한이
/// 상대이며, Linux 는 **데스크톱마다 상대가 다르다** (KGlobalAccel · GNOME Shell ·
/// Hyprland · COSMIC). 그래서 어느 상대에게 무엇이 막혔는지를 본문이 직접 말한다.
///
/// 인자: (1) hotkey 표기 (2) 상대 이름 (3) 그 상대가 준 구체적 사유 (4) config 경로.
pub const linux_hotkey_failed_title = "TildaZ — Hotkey Registration Failed";
pub const linux_hotkey_failed_format =
    \\TildaZ could not claim the global hotkey "{s}" from {s}.
    \\
    \\{s}
    \\
    \\A drop-down terminal you cannot summon is no terminal at all, so TildaZ stops here instead of starting into a window you have no way to reach.
    \\
    \\Pick a free combination in the config, then start TildaZ again:
    \\{s}
;
pub const linux_hotkey_failed_fallback_msg =
    "TildaZ could not claim its global hotkey and cannot run without one. Edit this instance's config file and start TildaZ again.";

/// 위 format 의 두 번째 인자 — 등록 상대의 이름. 데스크톱 이름을 그대로 쓰지 않고 실제
/// **등록 상대**를 적는다 (KDE 의 상대는 Plasma 가 아니라 KGlobalAccel 데몬이다).
pub const hotkey_owner_kglobalaccel = "KGlobalAccel";
pub const hotkey_owner_gnome_shell = "GNOME Shell";
pub const hotkey_owner_cinnamon = "Cinnamon";
pub const hotkey_owner_sway = "sway";
pub const hotkey_owner_hyprland = "Hyprland";
pub const hotkey_owner_cosmic = "COSMIC";

/// 위 format 의 세 번째 인자 — 사유. 상대마다 알 수 있는 것이 달라서 문장이 갈린다.
pub const hotkey_reason_taken_by_format =
    "That combination is already bound to another action:\n\n  \u{2022} {s}";
pub const hotkey_reason_taken_unnamed_msg =
    "That combination is already bound to another action on this desktop.";
pub const hotkey_reason_grab_refused_msg =
    "The desktop refused the grab. Another application or the desktop itself holds the combination.";
/// #510 — 인수를 **사용자가 거절한** 경우. 이것을 `hotkey_reason_backend_failed_format` 으로
/// 흘리면 본문에 `KGlobalAccelTakeoverDeclined` 라는 내부 에러 이름이 그대로 찍힌다 (실측).
/// 게다가 그것은 "등록이 실패했다" 가 아니라 **사용자가 고른 결과**라 서술 자체가 틀렸다.
pub const hotkey_reason_takeover_declined_format =
    "You chose to keep the existing binding, so {s} still owns that combination and TildaZ has none. Free it in your desktop's shortcut settings if you want TildaZ to have it.";
pub const hotkey_reason_takeover_declined_msg =
    "You chose to keep the existing binding, so TildaZ has no hotkey to open with.";

pub const hotkey_reason_backend_failed_format =
    "Registration failed: {s}.";

/// #510 — sway 고유 사유. sway 는 등록 상대이자 compositor 자신이라 "다른 앱이 쥐고
/// 있다" 가 아니라 **명령이 통하지 않았다** 쪽 문장이 맞다.
pub const sway_reason_no_socket_msg =
    "This session says it is sway, but SWAYSOCK is not set, so TildaZ cannot reach the compositor to bind the key.";
pub const sway_reason_command_too_long_msg =
    "The bind command did not fit -- the path to the TildaZ executable is unusually long.";
pub const sway_reason_ipc_failed_format =
    "The sway IPC call failed: {s}.";
pub const sway_reason_rejected_msg =
    "sway rejected the bind command.";
pub const sway_reason_rejected_format =
    "sway rejected the bind command:\n\n  \u{2022} {s}";

/// #496 1-c — a position hotkey is matched by physical key, so it needs a low-level
/// keyboard hook rather than the OS hotkey table. The failure causes are different
/// enough from `RegisterHotKey` that reusing that text would misdirect the user.
pub const hotkey_hook_failed_format =
    \\Failed to install the keyboard hook for the global hotkey (position [{s}], modifiers=0x{x}).
    \\
    \\A position hotkey such as "ctrl+[Backquote]" matches the physical key, which requires a
    \\low-level keyboard hook. The OS hotkey table cannot express it: it stores a virtual-key,
    \\and each keyboard layout assigns virtual-keys to different physical keys.
    \\
    \\Common causes:
    \\• Security software blocks low-level keyboard hooks
    \\• The session denies the hook
    \\
    \\Writing the key by label instead (for example "ctrl+space" or "F1") uses the OS hotkey
    \\table and does not need the hook. Edit the config and restart:
    \\{s}
;
pub const hotkey_hook_failed_fallback_msg = "Failed to install the keyboard hook for the global hotkey. Edit this instance's config file and restart.";

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
    \\Without them the {s} hotkey cannot be registered, and a drop-down
    \\terminal you cannot summon is no terminal at all -- so TildaZ closes
    \\when you dismiss this dialog. Grant both, then start it again.
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
    \\Step 3 — Start TildaZ again
    \\  Launch the app. The new permissions take effect on the next start.
    \\
    \\Current status:
    \\  Input Monitoring : {s}
    \\  Accessibility    : {s}
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
