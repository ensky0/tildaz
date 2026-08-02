const std = @import("std");
const App = @import("../app_controller.zig").App;
const SessionCore = @import("../session_core.zig").SessionCore;
const RendererBackend = @import("../renderer.zig").RendererBackend;
const config_mod = @import("../config.zig");
const Config = config_mod.Config;
const log = @import("../log.zig");
const dialog = @import("../dialog.zig");
const messages = @import("../messages.zig");
const shell_validate = @import("../shell_validate.zig");
const terminal = @import("../terminal.zig");
const windows_pty = @import("../terminal/windows/pty.zig");
const themes = @import("../themes.zig");
const instance_context = @import("../instance_context.zig");
const instances = @import("../instances.zig");
const build_options = @import("build_options");

const WCHAR = u16;
extern "kernel32" fn GetEnvironmentVariableW([*:0]const WCHAR, ?[*]WCHAR, u32) callconv(.c) u32;
extern "user32" fn SetProcessDpiAwarenessContext(isize) callconv(.c) c_int;
extern "user32" fn GetDpiForWindow(?*anyopaque) callconv(.c) c_uint;

const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;

pub fn showPanic(msg: []const u8, addr: usize, _: ?*std.builtin.StackTrace) noreturn {
    // #197 — macOS / Linux showPanic 와 동일하게 crash 를 로그에 남긴다 (parity).
    log.appendLine("panic", "{s}  return_addr=0x{x}", .{ msg, addr });
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, messages.panic_format, .{ msg, addr }) catch messages.panic_fallback_msg;
    dialog.showError(messages.crash_title, text);
    std.process.exit(1);
}

pub fn showFatalRunError(err: anyerror) void {
    log.appendLine("fatal", "run failed: {s}", .{@errorName(err)});

    var buf: [256]u8 = undefined;
    const text = messages.runFailureMessage(&buf, err);
    dialog.showError(messages.error_title, text);
}

pub fn run() !void {
    // Enable per-monitor DPI awareness (must be before any window/GDI calls)
    _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    // %APPDATA%\tildaz\tildaz_N.log 에 부팅 / 종료 라인을 남긴다.
    // stale exe 가 자동 실행되는 케이스를 사후 추적하기 위한 감사 로그.
    log.logStart(build_options.version);
    defer log.logStop(build_options.version);
    // #197 — env TILDAZ_VERBOSE 면 protocol/timing/detail 로그까지 (기본은 lifecycle).
    log.setVerbose(std.process.hasEnvVarConstant("TILDAZ_VERBOSE"));

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Load configuration. parse() 가 schema (validateStructure) + 각 필드
    // range 모두 fatal 처리 — 별도 validate() 호출 불필요.
    //
    // shell_resolved: 첫 실행 시 disk 에 명시될 shell path. Windows 는 OS env
    // 와 무관하게 항상 `Defaults.shell` (= `cmd.exe`) — `$SHELL` 같은 POSIX
    // 컨벤션이 없음. macOS 는 `$SHELL` 우선 (host/macos.zig 의 resolveShell 참고).
    // #218 — Config.load 가 owned shell 인수를 기대 (disk 경로서 free). Windows 는
    // $SHELL 컨벤션이 없어 Defaults.shell 을 owned dupe 로 전달.
    const shell_resolved = alloc.dupe(u8, config_mod.Defaults.shell) catch config_mod.Defaults.shell;
    var config = Config.load(alloc, shell_resolved);
    defer config.deinit(alloc);
    log.logConfigLoaded(config);

    // shell executable 이 PATH 또는 절대경로로 실제 존재하는지 *지금* 검증.
    // CreateProcessW 단계까지 가면 윈도우 / 렌더러 / PTY 초기화 비용 다 쓴
    // 뒤 generic 에러로 끝남 — 사용자에게 어디 고쳐야 할지 안내 안 됨.
    shell_validate.validateOrFatal(alloc, config.shell);

    // #339 — 번들 ConPTY 런타임(_internal\conpty.dll + OpenConsole.exe)은 Windows
    // 필수다. 하나라도 없으면 시스템 conhost 로 조용히 느리게 도는 대신 시작 시
    // 바로 fatal 로 막아 사용자가 설치를 고치게 한다 (압축 해제 후 _internal 분리 /
    // 삭제 / AV 격리 등). showFatal 은 다이얼로그 표시 후 프로세스를 종료한다.
    if (!windows_pty.bundledRuntimeFilesPresent()) {
        log.appendLine("conpty", "bundled _internal runtime missing — cannot start", .{});
        dialog.showFatal(messages.conpty_missing_title, messages.conpty_missing_msg);
    }

    var app = App{
        .session = undefined,
        .window = .{},
        .allocator = alloc,
        .shell = config.shell, // #248 — 런타임 새 탭 재검증용 (config 생존 동안 유효).
    };
    app.session = SessionCore.init(
        alloc,
        config.windowsShellUtf16(),
        config.max_scroll_lines,
        config.theme,
        buildExtraEnv(config.theme),
        App.onSessionTabExit,
        &app,
    );
    defer app.session.deinit();
    // tab_actions.Host 콜백 — &app 안정 후 한 번만. helper 가 user_data 통해
    // *App 으로 cast 후 invalidateRenderer / window.copyToClipboard
    // 등 instance 메서드 호출.
    app.setupHost();
    var hotkey_hint_buf: [64]u8 = undefined;
    app.setToggleHotkeyHint(config_mod.hotkeyDisplay(&hotkey_hint_buf, config.hotkey));

    // Set up window
    app.window.userdata = &app;
    app.window.write_fn = App.onKeyInput;
    app.window.render_fn = App.onRender;
    app.window.resize_fn = App.onResize;
    app.window.font_change_fn = App.onFontChange;
    app.window.app_event_fn = App.onAppEvent;
    app.window.quit_request_fn = App.onQuitRequest;
    app.window.before_hide_fn = App.onBeforeHide;
    app.window.scroll_to_bottom_fn = App.onImeCompositionStart;
    app.window.cursor_region_fn = App.cursorRegion;
    const DWriteFontCtx = @import("../font/windows/font.zig").DWriteFontContext;

    // Validate all font families exist on the system. 하나라도 미설치면 즉시
    // fatal — 사용자가 명시한 chain 전체가 시스템에 있어야 한다는 의도. macOS
    // CoreTextFontContext.init 의 per-entry CTFontCopyFamilyName 검증과 동등.
    // 메시지는 font_validate 가 처리 — 다른 config 에러 (shell_validate / hotkey)
    // 와 같은 풍부한 형식 (chain dump + 미설치 표시 + config 경로).
    const font_validate = @import("../font/validate.zig");
    for (0..config.font_family_count) |i| {
        const idx: u8 = @intCast(i);
        const fam_w = config.windowsFontFamilyUtf16(idx);
        if (!DWriteFontCtx.isFontAvailable(fam_w)) {
            font_validate.showNotFoundFatal(
                config.font_families[i],
                config.font_families[0..config.font_family_count],
            );
        }
    }

    // font.family chain 을 *전체* renderer 까지 전달 — 이전엔 chain[0] 만 도달
    // 하고 나머지는 validation loop 만 거치고 버려지는 사고 (#135 B2). chain
    // entry 들은 config 의 static buffer (windowsFontFamilyUtf16 의 per-index static)
    // 를 가리키는 포인터라 process lifetime 안정. 로컬 array 는 run() 스택
    // 프레임에 살아 있고 SessionCore / Window / Renderer 모두 같은 스코프.
    var font_chain_arr: [config_mod.MAX_FONT_FAMILIES][*:0]const u16 = undefined;
    for (0..config.font_family_count) |i| {
        font_chain_arr[i] = config.windowsFontFamilyUtf16(@intCast(i));
    }
    const font_chain: []const [*:0]const u16 = font_chain_arr[0..config.font_family_count];
    const terminal_font = config.terminalFontSpec();
    // #352 — 이 `try` 가 "이후 `window.hwnd` 는 항상 있다" 는 불변식을 세운다.
    // `CreateWindowExW` 실패는 `error.CreateWindowFailed` 로 여기서 `run()` 을
    // 중단시키므로, 아래의 `applyDpiScale(GetDpiForWindow(hwnd))` 부터 첫
    // `createTab()` 까지 hwnd 를 다시 검사할 필요가 없다. `app_controller` 의
    // `getTerminalGridSize` 는 이 불변식을 assert 로만 밝히고 가짜 fallback 을
    // 두지 않는다.
    try app.window.init(font_chain, terminal_font, config.opacity_alpha, config.hotkey.vkey, config.hotkey.modifiers);
    log.appendLine("startup", "window initialized: dpi={d} cell={}x{}", .{
        app.window.current_dpi,
        app.window.cell_width_px,
        app.window.cell_height_px,
    });
    defer app.window.deinit();

    // Scale tab bar / scrollbar / padding constants by the startup DPI.
    // The same computation runs again via `App.onFontChange` whenever the
    // window moves to a monitor with a different DPI.
    app.applyDpiScale(GetDpiForWindow(app.window.hwnd));

    // Initialize renderer backend
    const theme_bg: ?[3]u8 = if (config.theme) |t| .{ t.background.r, t.background.g, t.background.b } else null;
    // #363 — renderer 초기화 실패를 더 이상 삼키지 않는다. 이전엔 `catch → null`
    // 로 두고 계속 실행해서, 창은 뜨고 PTY 도 돌지만 그리는 주체가 없는 빈 창이
    // 됐고 원인은 로그에만 남았다.
    //
    // GPU → WARP (OS 내장 소프트웨어 래스터라이저) 재시도는 renderer 안에서 한다.
    // 여기까지 error 가 올라왔다는 것은 두 경로가 모두 실패했다는 뜻이므로 안내 후
    // 종료 — `dialog.showFatal` 이 noreturn 이라 이 줄 아래로는 renderer 가 반드시
    // 있다.
    app.renderer = RendererBackend.init(alloc, app.window.hwnd, font_chain, terminal_font, @intCast(app.window.cell_width_px), @intCast(app.window.cell_height_px), theme_bg, config.opacity_alpha) catch |err| {
        log.appendLine("startup", "renderer init failed: {s}", .{@errorName(err)});
        var msg_buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, messages.renderer_init_failed_format, .{
            @errorName(err),
            log.filePath() orelse messages.unknown_path_msg,
        }) catch messages.renderer_init_failed_fallback_msg;
        dialog.showFatal(messages.renderer_init_failed_title, msg);
    };
    log.appendLine("startup", "render_path={s}", .{app.renderer.?.renderPath()});
    defer if (app.renderer) |*r| r.deinit();

    // Apply position from config
    app.window.setPosition(config.dock_position, config.width_percent, config.height_percent, config.offset_percent);

    // Create initial tab
    try app.createTab();
    log.appendLine("startup", "initial tab created: count={d}", .{app.session.count()});

    if (!config.hidden_start) {
        log.appendLine("startup", "show window", .{});
        app.window.show();
    }

    // #304 — HWND 생성만으로는 충분하지 않다. renderer와 첫 tab, 표시 정책을
    // 모두 적용한 뒤 message loop 진입 직전에 request endpoint를 ready로 공개한다.
    try instances.recordEndpointState(alloc, instance_context.requireWorkerIndex(), .ready);
    log.appendLine("startup", "enter message loop", .{});
    app.window.messageLoop();
    log.appendLine("startup", "message loop exited", .{});
}

/// 자식 셸에 inject 할 env. macOS host 의 `g_extra_env` 와 동등 — 양쪽 host 가
/// SessionCore.init 인자로 명시 전달. terminal backend 는 platform-agnostic.
///
/// 항목:
///   - `COLORFGBG` — vim / less / tmux 같은 TUI 가 dark / light colorscheme
///     자동 선택할 때 보는 표준. dark = "15;0", light = "0;15".
///   - `WSLENV` — WSL 자식 프로세스에 어떤 env 를 forward 할지 hint. 부모의
///     기존 WSLENV (있으면) 에 ":COLORFGBG" 를 append. WSL 환경 외에서는
///     무해.
///
/// Buffer lifetime: process lifetime static (다음 호출 시 덮어쓰지만 SessionCore
/// 가 슬라이스를 들고 있는 동안 유효).
fn buildExtraEnv(theme: ?*const themes.Theme) ?[]const terminal.ExtraEnv {
    const t = theme orelse return null;
    const S = struct {
        var wslenv_buf: [768]u8 = undefined;
        var wslenv_len: usize = 0;
        var vars: [2]terminal.ExtraEnv = undefined;
    };

    S.vars[0] = .{
        .name = "COLORFGBG",
        .value = themes.colorFgBg(t),
    };

    // WSLENV — 부모 utf-16 query → utf-8 변환 + ":COLORFGBG" suffix.
    var wbuf: [512]WCHAR = undefined;
    const wslenv_name = std.unicode.utf8ToUtf16LeStringLiteral("WSLENV");
    const existing_wlen = GetEnvironmentVariableW(wslenv_name, &wbuf, wbuf.len);
    var pos: usize = 0;
    if (existing_wlen > 0 and existing_wlen < wbuf.len) {
        const utf8_len = std.unicode.utf16LeToUtf8(&S.wslenv_buf, wbuf[0..existing_wlen]) catch 0;
        pos = utf8_len;
        if (pos < S.wslenv_buf.len) {
            S.wslenv_buf[pos] = ':';
            pos += 1;
        }
    }
    const suffix = "COLORFGBG";
    if (pos + suffix.len <= S.wslenv_buf.len) {
        @memcpy(S.wslenv_buf[pos..][0..suffix.len], suffix);
        pos += suffix.len;
    }
    S.wslenv_len = pos;
    S.vars[1] = .{
        .name = "WSLENV",
        .value = S.wslenv_buf[0..S.wslenv_len],
    };

    return &S.vars;
}
