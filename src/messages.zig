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
// #646 — 메뉴는 **네 방향이 다 있다는 것을 알리는 자리**다. 항목을 넷으로 늘리는 대신 쌍으로
// 묶어 같은 높이에 네 방향을 담는다 (2026-09-16 사용자 요청 — "있는 기능인데 너무 잘 안
// 보여서"). 누르면 기본 방향 (오른쪽 · 아래) 으로 나뉜다.
pub const command_split_right = "Split Left / Right";
pub const command_split_down = "Split Up / Down";
// "Active" 는 뺀다 (2026-09-16 사용자 결정) — 메뉴의 다른 항목도 전부 활성 탭 · 활성 pane
// 에 대한 것이라 이 항목에만 붙여 둘 이유가 없었다.
pub const command_close_active_tab = "Close Tab";
/// #646 — 버퍼 검색.
pub const command_find = "Find";
pub const shortcut_find = "Ctrl+Shift+F";
pub const shortcut_find_macos = "Cmd+F";
pub const command_copy = "Copy";
pub const command_paste = "Paste";
/// toggle 의미 + 320pt 메뉴 폭에서 hint 와 공존하는 짧은 문구 (#334 피드백 —
/// "Enter / Exit Full Screen" 은 길어서 hint 가 숨겨졌음).
pub const command_full_screen = "Toggle Full Screen";
pub const command_open_config = "Open Config";
pub const command_open_log = "Open Log";
pub const command_keyboard_shortcuts = "Keyboard Shortcuts";
pub const command_about = "About TildaZ";

/// #646 — 검색바 입력칸이 비어 있을 때의 안내문. **앱 UI 라 영어다** (AGENTS.md 의
/// "프로그램 안에서 사용자에게 직접 표시되는 메시지는 영어").
pub const search_placeholder = "Find";
pub const keyboard_shortcuts_url = "https://github.com/ensky0/tildaz/blob/main/KEYBINDINGS.md";
pub const shortcut_new_tab = "Ctrl+Shift+T";
pub const shortcut_new_tab_macos = "Cmd+T";
/// #483 — 분할 항목 hint. 기존 hint 처럼 키 이름을 글자로 적는다 (`Enter` 와 같은 표기).
// 화살표는 글자 대신 기호로 적는다 — 두 방향을 한 줄에 담아야 해서 폭이 빠듯하고,
// `←/→` 는 키캡 모양 그대로라 더 빨리 읽힌다.
pub const shortcut_split_right = "Ctrl+Shift+←/→";
pub const shortcut_split_right_macos = "Option+Cmd+←/→";
pub const shortcut_split_down = "Ctrl+Shift+↑/↓";
pub const shortcut_split_down_macos = "Option+Cmd+↑/↓";
pub const shortcut_close_tab = "Ctrl+Shift+W";
pub const shortcut_close_tab_macos = "Cmd+W";
// 힌트는 **키만** 적는다 (2026-09-16 사용자 결정). 예전에는 `Drag /` · `Right-click /` 을
// 앞에 붙여 마우스 경로도 함께 알렸는데, 다른 항목은 전부 키 하나만 적고 있어 이 둘만
// 형식이 달랐다. 폭도 그만큼 먹어 좁은 창에서 힌트가 먼저 숨는 항목이 이 둘이었다.
pub const shortcut_copy = "Ctrl+Shift+C";
pub const shortcut_copy_macos = "Cmd+C";
pub const shortcut_paste = "Ctrl+Shift+V";
pub const shortcut_paste_macos = "Cmd+V";
pub const shortcut_full_screen = "Alt+Enter";
pub const shortcut_full_screen_macos = "Cmd+Enter";
/// workarea 전체화면 상태에서 메뉴의 Toggle Full Screen 이 하는 일(해제)과
/// 같은 키 — 상태 의존 hint (#334 사용자 결정). 표기는 KEYBINDINGS.md /
/// SPEC §2 의 기존 확립 표기(`Shift+Alt+Enter`)를 따른다.
pub const shortcut_full_screen_workarea = "Shift+Alt+Enter";
pub const shortcut_full_screen_workarea_macos = "Shift+Cmd+Enter";
pub const shortcut_open_log = "Ctrl+Shift+L";
pub const shortcut_open_log_macos = "Shift+Cmd+L";
pub const shortcut_open_config = "Ctrl+Shift+P";
pub const shortcut_open_config_macos = "Shift+Cmd+P";

/// 종료 확인 (#116). 한 번에 사라지는 탭 수를 본문에 박아 사용자가 잃을
/// 작업량을 즉시 인지하게. {s} 는 영어 복수형 처리 — count==1 이면 "" else "s".
pub const quit_confirm_format = "This will close {d} open tab{s}.";

/// #483 — 탭 하나가 pane 을 여럿 담을 수 있게 되면서 (`pane_layout.MAX_PANES_PER_TAB` = 16)
/// 위 문구만으로는 **사라지는 셸 수를 알 수 없다** (1 탭 · 16 pane 도 "1 open tab" 이었다 —
/// 2026-08-29 Windows 실기). 분할이 있을 때만 이 문구를 쓰고, pane 수 = 탭 수 (아무 탭도 안
/// 갈라짐) 면 위 문구를 그대로 써서 분할을 안 쓰는 사용자에게 낯선 낱말을 안 보인다.
/// pane 수가 탭 수보다 크면 pane 은 반드시 둘 이상이라 복수형 처리가 필요 없다.
pub const quit_confirm_panes_format = "This will close {d} open tab{s} ({d} panes).";

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
/// #577 — launcher 가 띄운 worker 가 **기동 중에** 끝난 경우. 위 문구와 상황이 다르다:
/// 그쪽은 이미 떠 있는 인스턴스에 "새 인스턴스를 만들라" 고 보내려던 참이고, 이쪽은
/// 창이 한 번도 뜨지 못한 첫 기동이다.
///
/// 예전에는 이 경우가 generic `WorkerStartTimeout` ("Error: WorkerStartTimeout") 이었고,
/// 그것도 10 초를 기다린 뒤였다. 사용자가 무엇을 해야 하는지 말해 주지 않았다.
///
/// **로그를 가리키는 것이 핵심이다.** worker 가 스스로 안내를 띄웠다면 (config 오류 등)
/// launcher 는 여기까지 오지 않는다 — 그쪽은 안내를 띄우는 동안 lock 을 들고 살아 있어
/// `waitUntilRunning` 이 성공한다. 그래서 이 문구에 도달한 실행은 **아무 화면도 없이**
/// 끝난 경우이고, 남은 단서가 로그뿐이다.
pub const worker_exited_during_startup_msg =
    "TildaZ stopped while starting up, before any window appeared.\n\n" ++
    "The reason is in the TildaZ log -- open it and read the last lines. " ++
    "Start TildaZ again and check the log if this continues.";
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

/// `runFailureMessage` 가 담긴 config 문구를 쓰는 상황인지. **판단을 여기 한 곳에 둔다** —
/// host 는 이 답으로 "이미 나간 문구를 또 내지 않기" 를 결정한다. `publishFatalNotice` 가 담는
/// 순간 stderr + 로그에 이미 냈으므로, host 가 다시 내면 사용자가 같은 문구를 **두 번** 본다
/// (#583 B7 첫 실기에서 그랬다 — worker 경로는 예전부터 다시 내지 않는다).
pub fn usesConfigNotice(err: anyerror, config_notice: ?[]const u8) bool {
    return err == error.InvalidConfig and config_notice != null;
}

/// run/launcher 오류를 세 platform에서 같은 사용자 문구로 변환한다.
///
/// `config_notice` — `config.pendingFatalNotice()` 의 값 (없으면 `null`). config 오류로 죽은
/// 것이면 그 문구가 **더 정확하다** (경로 · 줄 · 열 · 오류) 라서 그것을 그대로 보여 준다.
/// #583 B7 전에는 launcher 가 이 자리에서 `TildaZ failed to start. Error: UnexpectedToken` 만
/// 보여 줬는데, worker 는 같은 파일의 같은 오류에 `Line 12, column 3` 까지 알려 줬다.
/// `error.InvalidConfig` 로만 좁힌 이유는, 담긴 문구가 있어도 그 뒤 다른 원인으로 죽었으면
/// 그 원인을 가려서는 안 되기 때문이다.
pub fn runFailureMessage(buf: []u8, err: anyerror, config_notice: ?[]const u8) []const u8 {
    if (usesConfigNotice(err, config_notice)) return config_notice.?;
    return switch (err) {
        error.RequestEndpointUnavailable => request_endpoint_unavailable_msg,
        error.WorkerExitedBeforeEndpointReady => worker_exited_before_endpoint_ready_msg,
        error.RequestEndpointReadyTimeout => request_endpoint_ready_timeout_msg,
        // #577 — 첫 기동이 화면 없이 끝난 경우. generic `WorkerStartTimeout` 대신.
        error.WorkerExitedDuringStartup => worker_exited_during_startup_msg,
        else => std.fmt.bufPrint(buf, run_failed_format, .{@errorName(err)}) catch run_failed_fallback_msg,
    };
}

test "#583 B7 config 파싱 오류는 담긴 상세 문구를 그대로 보여 준다" {
    var buf: [256]u8 = undefined;
    // launcher 가 config 를 읽다 죽은 경우 — `recordTomlParseFatal` 이 담아 둔 문구다.
    const notice = "Config: /home/user/.config/tildaz/config_0.toml\n\n" ++
        "Failed to parse config file.\n\nLine 12, column 3\nError: UnexpectedToken";
    try std.testing.expectEqualStrings(notice, runFailureMessage(&buf, error.InvalidConfig, notice));
    // 담긴 것이 없으면 일반 문구 (파싱이 아닌 의미 오류로 `InvalidConfig` 가 오는 경로).
    try std.testing.expectEqualStrings(
        "TildaZ failed to start.\n\nError: InvalidConfig",
        runFailureMessage(&buf, error.InvalidConfig, null),
    );
    // 다른 원인으로 죽었으면 담긴 config 문구가 그 원인을 **가리지 않는다.**
    try std.testing.expectEqualStrings(
        "TildaZ failed to start.\n\nError: ExampleFailure",
        runFailureMessage(&buf, error.ExampleFailure, notice),
    );
}

test "request endpoint run errors have specific user messages" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        request_endpoint_unavailable_msg,
        runFailureMessage(&buf, error.RequestEndpointUnavailable, null),
    );
    try std.testing.expectEqualStrings(
        worker_exited_before_endpoint_ready_msg,
        runFailureMessage(&buf, error.WorkerExitedBeforeEndpointReady, null),
    );
    try std.testing.expectEqualStrings(
        request_endpoint_ready_timeout_msg,
        runFailureMessage(&buf, error.RequestEndpointReadyTimeout, null),
    );
    // #577 — 첫 기동이 화면 없이 끝난 경우. 예전에는 generic
    // `"Error: WorkerStartTimeout"` 이었고 그것도 10 초 뒤였다.
    try std.testing.expectEqualStrings(
        worker_exited_during_startup_msg,
        runFailureMessage(&buf, error.WorkerExitedDuringStartup, null),
    );
    // 이 문구는 사용자에게 **무엇을 볼지** 말해야 한다 — 여기까지 온 실행은 화면에
    // 아무것도 남기지 않았으므로 단서가 로그뿐이다.
    try std.testing.expect(std.mem.indexOf(u8, worker_exited_during_startup_msg, "log") != null);
    try std.testing.expectEqualStrings(
        "TildaZ failed to start.\n\nError: ExampleFailure",
        runFailureMessage(&buf, error.ExampleFailure, null),
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
// #577 — `font_schema_error_path_format` 을 없앴다. 폰트 schema 오류
// (`font.family` 가 string 이 아님 등) 는 config 파싱 안에서 나므로 다른 config
// 오류와 같은 `config_error_with_path_format` 을 지난다. 경로를 본문 끝에 다시
// 붙이는 자기 형식이 있어서 #495 가 정한 "경로는 첫 줄" 과 어긋나 있었고,
// 들여쓰기 (`  {s}`) 까지 아래 chain footer 와 달랐다.
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
/// #577 — 경로가 빠졌다. 이제 `notFoundMessageForPath` 가 본문 **앞에**
/// `config_error_path_prefix_format` 으로 붙인다 (#495 의 "경로는 첫 줄").
/// 형식 인자가 없어져 `_format` 이 아니라 `_msg` 다.
pub const font_chain_footer_msg =
    "\nAll families listed in font.family must be installed on the system.\n";

/// glyph fallback chain 의 모든 명시 폰트 lookup 실패 — chain 비어있는 케이스
/// (사용자가 모두 잘못된 이름 명시) 등 edge. strict 검증 path 는 한 개 이름을
/// `font_not_found_format` 으로 표시 (Windows 동등).
pub const font_chain_all_failed_msg =
    \\None of the configured font families are available on this system.
    \\
    \\Tried:
;

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
///
/// #577 — 경로 접두만 따로 뺀다. 본문을 writer 로 조금씩 쌓는 쪽 (폰트 chain 안내)
/// 은 `{s}` 두 개를 한 번에 print 할 수 없어서 예전에는 자기 형식으로 경로를 **끝에**
/// 붙였다. 접두를 상수로 두면 그쪽도 같은 첫 줄을 쓴다 — #495 가 노린 "한 형식" 이
/// 그 세 갈래 (config / 폰트 / shell) 까지 실제로 덮인다.
pub const config_error_path_prefix_format = "Config: {s}\n\n";
pub const config_error_with_path_format = config_error_path_prefix_format ++ "{s}";
/// `allocPrint` 실패 시. **경로 자리를 비우지 않는다** — 예전 파싱 쪽 fallback 은
/// 경로를 아예 잃어서 (`"Failed to parse config JSON."`) 정작 가장 도움이 필요한
/// 상황에서 가장 적은 정보를 줬다.
pub const config_error_with_path_fallback_msg = "Config: (unknown)\n\nConfiguration is invalid.";
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

// #655 — **고쳐서 계속 뜨는** 항목의 문구. 예전에는 이 자리에 `config_missing_key_format`
// ("파일을 옮겨 두고 다시 시작하라") 이 있었는데, 그 문구 자체가 *종료* 안내라 함께 지웠다.
// SPEC 원칙 5 (언제나 부팅은 되게) 와 §7.3 이 정본이다.
//
// 문구는 **무엇을 했는지 + 사용자가 할 일** 두 조각이다. 앞만 있으면 "그래서 어쩌라고" 가
// 되고, 뒤만 있으면 지금 어떤 값으로 도는지를 모른다.
/// #655 — 이제 **로그에만** 간다. 테마가 18 개라 다이얼로그에 펼치면 나머지 안내가
/// 밀려난다. 다이얼로그에는 `config_notice_bad_value_format` 한 줄만 선다.
pub const config_unknown_theme_header_format = "Configuration: unknown theme \"{s}\"\n\nAvailable themes:";

/// #655 — 안내 다이얼로그의 두 번째 버튼. 사용자가 **직접 고치게** 만드는 것이 이
/// 안내의 목적이라, 고칠 파일을 여는 길을 그 자리에 둔다. 메뉴의 `Open Config` 와
/// 같은 글자다 — 같은 일을 하는 자리가 다르게 불리면 안 된다.
pub const button_open_config = command_open_config;

pub const config_notice_title = "TildaZ started with parts of your config replaced.";
pub const config_notice_repaired_header = "Using defaults for these -- add or fix them in the file:";
pub const config_notice_removable_header = "These are not used any more -- delete them:";
/// 키가 없어 기본값을 쓴 경우. `{s}` = 키 경로.
pub const config_notice_missing_format = "  {s} -- missing, using the default";
/// 값을 읽을 수 없어 기본값을 쓴 경우. `{s}` = 키 경로, `{s}` = 쓰는 값.
pub const config_notice_bad_value_format = "  {s} -- could not read the value, using {s}";
/// 범위 밖이라 잘라낸 경우. `{s}` = 키 경로, `{s}` = 잘라낸 값.
pub const config_notice_clamped_format = "  {s} -- out of range, limited to {s}";
/// 리스트에서 항목 하나를 뺀 경우. `{s}` = 키 경로, `{s}` = 뺀 항목.
pub const config_notice_dropped_format = "  {s} -- dropped {s}";
/// 모르는 키 · 섹션. `{s}` = 키 경로.
pub const config_notice_unknown_format = "  {s}";
/// `config_notice_bad_value_format` 의 흔한 인자 — "기본값" 이라고만 적는 경우.
pub const config_notice_used_default = "the default";
/// 담을 자리를 넘겼을 때 마지막 줄. 조용히 자르지 않는다.
pub const config_notice_truncated_msg = "  ... and more (see the log for the full list)";
/// #655 — **빠져나갈 길**. 목록이 길면 (v0.9.2 → v0.9.3 업그레이드가 45 줄이었다) 한 줄씩
/// 고치는 것보다 파일을 버리는 쪽이 빠르다. 그 길이 있다는 것을 모르면 사용자는 45 줄을
/// 손으로 고치거나 포기한다. 남은 fatal 안내도 같은 줄을 쓴다 — 거기서는 이것이 **유일한**
/// 길이다 (TOML 구문이 깨지면 고칠 자리를 짚어 줄 수조차 없다).
pub const config_notice_reset_hint =
    "Or delete the file: TildaZ creates a fresh one with the defaults on the next start.";
/// 숫자를 문구로 못 옮겼을 때 (`bufPrint` 실패) `config_notice_clamped_format` 에 넣는 말.
/// 값은 잃어도 "범위 밖이라 잘렸다" 는 사실은 남아야 한다.
pub const config_notice_the_limit = "the limit";
/// #655 — 전역 hotkey 가 낮은 index 의 인스턴스와 겹쳐 파생 기본값으로 갈아탔다.
/// 죽이는 대신 갈아타므로 안내 묶음으로 간다.
pub const config_notice_hotkey_taken_format = "  hotkey -- already used by instance {d}, using {s}";
/// `[keys]` 의 한 항목만 버렸을 때. 액션은 남은 키로, 다 버렸으면 기본 바인딩으로 돈다.
pub const config_notice_key_dropped_format = "  keys.{s} -- dropped \"{s}\" ({s})";
pub const config_notice_key_dropped_fallback_msg = "  keys -- dropped a key that could not be read";
/// 두 액션이 같은 조합을 쓸 때. 먼저 나온 쪽이 이긴다 (SPEC 7.3).
pub const config_notice_key_conflict_format = "  keys.{s} -- \"{s}\" is already used by {s}, dropped";
pub const config_notice_key_conflict_fallback_msg = "  keys -- dropped a key that was already used";
pub const config_notice_key_reason_unknown = "unknown key";
pub const config_notice_key_reason_needs_modifier = "needs a modifier";
pub const config_notice_key_reason_position_aliased = "left/right is not distinguished on macOS";
pub const config_notice_key_reason_position_absent = "needs left or right on macOS";
pub const config_notice_key_reason_not_text = "not a text value";
pub const config_notice_key_reason_too_many = "too many key bindings";

// #577 — 세 문구 모두 경로가 **첫 줄**로 왔다 (#495). 예전에는 맨 끝의
// `Config path:` 였는데, 그러면 같은 다이얼로그 안에서도 오류 종류에 따라 경로
// 위치가 달라졌다 — #495 가 없애려던 바로 그 불일치다.
//
// 경로가 첫 인자가 된 것에 주의한다 (`shell_validate.zig` 의 인자 순서도 함께
// 바뀐다). 형식 문자열이 인자 순서를 정하므로 접두를 앞에 두면 경로가 앞이다.
pub const shell_empty_format =
    config_error_path_prefix_format ++
    "Configuration: \"shell\" is empty.\n\n{s}";
pub const shell_empty_fallback_msg = "Configuration: shell is empty.";
pub const shell_first_token_empty_format =
    config_error_path_prefix_format ++
    "Configuration: \"shell\" first token is empty.\n\nValue: \"{s}\"\n\n{s}";
pub const shell_first_token_empty_fallback_msg = "Configuration: shell first token empty.";
pub const shell_executable_not_found_format =
    config_error_path_prefix_format ++
    "Configuration: shell executable not found.\n\n\"shell\" value: \"{s}\"\nLookup token: \"{s}\"\n\n{s}";
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
/// #616 — 이 사유는 **GNOME · Cinnamon 의 Shell extension 이 보고한 실패**에만 쓴다. 그쪽은
/// 판정이 셸 안에서 나고 그 기록 (`instanceN.hotkey`) 을 worker 가 부팅 때 읽으므로, 사용자가
/// 조합을 비운 것을 셸이 **알아차려야** 기록이 갱신된다. extension 은 데스크톱의 단축키 목록을
/// 감시해 대개 즉시 갱신하지만 (Cinnamon 은 `custom-list` · 항목별 `binding` · `wm` ·
/// `media-keys`), 다른 extension 이 코드로 직접 잡은 조합처럼 **감시에 걸리지 않는 경로**가 남는다.
/// 그때는 셸이 다시 등록해야 하니 재로그인이 답이다 — 그 두 갈래를 본문이 직접 말한다. 안 적으면
/// "조합을 비웠는데 앱이 계속 거부한다" 에서 사용자가 막힌다.
pub const hotkey_reason_grab_refused_msg =
    \\The desktop refused the grab. Another application or the desktop itself holds the combination.
    \\
    \\If you free that combination in your desktop's shortcut settings, TildaZ takes it on the next start. If it still refuses right after you freed it, log out and back in — some shortcuts are only re-checked when the desktop shell starts.
;
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
    \\Step 2 — {s}
    \\  1. Click "< Privacy & Security" to go back.
    \\  2. Click "{s}" instead.
    \\  3. Same as above: turn "tildaz" ON,
    \\     or click "+" to add TildaZ.app and then turn it ON.
    \\
    \\Step 3 — Start TildaZ again
    \\  Launch the app. The new permissions take effect on the next start.
    \\
    \\Current status:
    \\  Input Monitoring : {s}
    \\  {s} : {s}
;

/// macOS 27 이 `Accessibility` 를 `Device Control and Data Access` 로 바꿨다
/// ([#674](https://github.com/ensky0/tildaz/issues/674)). 두 값은 그 OS 의
/// `SecurityPrivacyExtension` 리소스 (`Localizable.loctable` 의 `ACCESSIBILITY` 키) 에서
/// 그대로 읽은 것이다 — 우리가 지어낸 말이 아니다. `Input Monitoring` (`LISTEN_EVENT`) 은
/// 바뀌지 않았다.
///
/// 이름만 바뀌었고 API · TCC 서비스 키는 그대로라 판정 · 부여 동작에는 영향이 없다.
/// 문제는 **사용자가 이 안내를 그대로 따라가면 없는 메뉴를 찾게 된다**는 것이다.
pub const macos_accessibility_label_legacy = "Accessibility";
pub const macos_accessibility_label_modern = "Device Control and Data Access";
/// `bufPrint` 가 실패했을 때만 쓰는 짧은 안내다. 여기서는 권한 이름을 주입할 수 없으므로
/// **양쪽 macOS 에서 다 통하는 표현**을 쓴다 (#674).
pub const macos_permission_required_fallback_msg = "TildaZ needs two permissions: Input Monitoring, and the one that lets apps control your Mac (\"Device Control and Data Access\" on macOS 27 and later, \"Accessibility\" before that). Open System Settings -> Privacy & Security and enable both for tildaz.";
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
