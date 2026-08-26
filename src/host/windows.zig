const std = @import("std");
const run_options = @import("../run_options.zig");
const Runtime = @import("../runtime.zig").Runtime;

/// #451 — panic / fatal 경로는 호출 사슬 밖에서 불린다 (panic handler 는 인자를 못 받는다).
/// `run` 이 심어 두고 그 두 자리에서만 읽는다 — macOS 의 `g_rt` 와 같은 이유다.
var g_rt: Runtime = undefined;
const App = @import("../app_controller.zig").App;
const SessionCore = @import("../session_core.zig").SessionCore;
const Window = @import("../window.zig").Window;
const RendererBackend = @import("../renderer.zig").RendererBackend;
const config_mod = @import("../config.zig");
const Config = config_mod.Config;
const log = @import("../log.zig");
const perf = @import("../perf.zig");
const dialog = @import("../dialog.zig");
const messages = @import("../messages.zig");
const shell_integration = @import("../shell_integration.zig");
const shell_validate = @import("../shell_validate.zig");
const terminal = @import("../terminal.zig");
const windows_pty = @import("../terminal/windows/pty.zig");
const themes = @import("../themes.zig");
const instance_context = @import("../instance_context.zig");
const instances = @import("../instances.zig");
const version = @import("../version.zig");

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
    dialog.showError(g_rt, messages.crash_title, text);
    std.process.exit(1);
}

pub fn showFatalRunError(err: anyerror) void {
    log.appendLine("fatal", "run failed: {s}", .{@errorName(err)});

    var buf: [256]u8 = undefined;
    const text = messages.runFailureMessage(&buf, err);
    dialog.showError(g_rt, messages.error_title, text);
}

pub fn run(rt: Runtime, opts: run_options.RunOptions) !void {
    g_rt = rt;
    // Enable per-monitor DPI awareness (must be before any window/GDI calls)
    _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    // %APPDATA%\tildaz\tildaz_N.log 에 부팅 / 종료 라인을 남긴다.
    // stale exe 가 자동 실행되는 케이스를 사후 추적하기 위한 감사 로그.
    log.logStart(rt.io, version.string);
    defer log.logStop(version.string);
    // #396 — 측정 인스턴스면 종료 직전에 perf 스냅숏을 남긴다. `defer` 는 LIFO 라
    // 위의 `logStop` **보다 먼저** 돈다 — 로그 파일이 닫히기 전이어야 한다.
    // worker 는 no-op (게이트는 `instance_context.isStress`).
    defer perf.dumpOnExit(rt);
    // #197 — env TILDAZ_VERBOSE 면 protocol/timing/detail 로그까지 (기본은 lifecycle).
    log.setVerbose(rt.envHas("TILDAZ_VERBOSE"));

    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
    var config = Config.load(rt, alloc, shell_resolved);
    defer config.deinit(alloc);
    log.logConfigLoaded(config);

    // shell executable 이 PATH 또는 절대경로로 실제 존재하는지 *지금* 검증.
    // CreateProcessW 단계까지 가면 윈도우 / 렌더러 / PTY 초기화 비용 다 쓴
    // 뒤 generic 에러로 끝남 — 사용자에게 어디 고쳐야 할지 안내 안 됨.
    shell_validate.validateOrFatal(rt, alloc, config.shell);

    // #339 — 번들 ConPTY 런타임(_internal\conpty.dll + OpenConsole.exe)은 Windows
    // 필수다. 하나라도 없으면 시스템 conhost 로 조용히 느리게 도는 대신 시작 시
    // 바로 fatal 로 막아 사용자가 설치를 고치게 한다 (압축 해제 후 _internal 분리 /
    // 삭제 / AV 격리 등). showFatal 은 다이얼로그 표시 후 프로세스를 종료한다.
    if (!windows_pty.bundledRuntimeFilesPresent()) {
        log.appendLine("conpty", "bundled _internal runtime missing — cannot start", .{});
        dialog.showFatal(rt, messages.conpty_missing_title, messages.conpty_missing_msg);
    }

    var app = App{
        .rt = rt,
        .session = undefined,
        // #493 3-c — `[keys]` 를 window 의 키 경로에 넘긴다. `config` 는 이 함수의
        // 지역이고 `app` 보다 먼저 선언되므로 slice 가 window 보다 오래 산다.
        .window = .{ .rt = rt, .key_bindings = config.key_bindings[0..config.key_binding_count] },
        .allocator = alloc,
        .shell = config.shell, // #248 — 런타임 새 탭 재검증용 (config 생존 동안 유효).
    };
    // #382 — `-e <실행파일>` 이면 셸 대신 그것을 띄운다. Windows 의 `ShellCommand` 는
    // UTF-16 이라 변환한다 (`run()` 이 끝날 때까지 살아 있어야 해서 여기서 free 하지
    // 않는다 — 프로세스 수명과 같다).
    const stress_shell_w: ?[:0]const u16 = if (opts.command) |cmd|
        std.unicode.utf8ToUtf16LeAllocZ(alloc, cmd) catch null
    else
        null;
    app.session = SessionCore.init(
        rt,
        alloc,
        if (stress_shell_w) |w| w.ptr else config.windowsShellUtf16(),
        // #381 — `-scrollback N` 이면 config 를 무시한다 (터미널 비교에서 scrollback 을
        // 맞추기 위한 측정용 override, `run_options.zig` 참고).
        opts.scrollLines(config.max_scroll_lines),
        config.theme,
        buildExtraEnv(config.theme),
        App.onSessionTabExit,
        &app,
    );
    defer app.session.deinit();
    // #381 — override 가 먹었는지 로그로 확인할 수 있어야 한다. `config loaded:` 줄은 config
    // 값을 찍으므로 그것만 보면 override 실패를 알 수 없다 (측정이 이 값에 걸려 있다).
    if (opts.scrollback) |n| {
        log.appendLine("startup", "scrollback override: {d} lines (config {d})", .{ n, config.max_scroll_lines });
    }
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
    // #387 — 메시지 큐가 빈 순간의 추가 드레인 (사양 A). `messageLoop` 주석 참고.
    app.window.idle_drain_fn = App.onIdleDrain;
    app.window.quit_request_fn = App.onQuitRequest;
    app.window.before_hide_fn = App.onBeforeHide;
    app.window.scroll_to_bottom_fn = App.onImeCompositionStart;
    app.window.cursor_region_fn = App.cursorRegion;
    // #439 — PTY 출력 도착을 UI 스레드에 알린다. 이것이 없으면 유휴에서 `WaitMessage` 가
    // 다음 `WM_FRAME_TICK` 까지 자고, 그 주기가 그대로 응답 지연이 된다.
    app.session.setOutputWake(onOutputWake, &app.window);
    log.appendLine("startup", "output wake installed (idle PTY notify)", .{});
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
                rt,
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
    // 창 타이틀은 `instance_context.Role` 에서 나온다 (#382) — 측정 인스턴스는 worker 가
    // 아니고, Windows 는 worker 창을 타이틀로 찾는다 (`instance_request` ·
    // `hotkey_capture`). 역할은 `main.zig` 이 한 번 정하므로 여기서 넘기지 않는다.
    try app.window.init(font_chain, terminal_font, config.opacity_alpha);
    // 측정 모드는 전역 핫키를 등록하지 않는다 (#382) — 평소 쓰는 TildaZ 와 같은 키에
    // 두 프로세스가 반응한다. **등록 여부는 host 의 정책이라 여기서 드러낸다** — 이전에는
    // `init` 인자로 `vkey 0` 을 넘겨 "등록하지 않는다" 를 표현했고, 그 가드의 `return` 이
    // 폰트 · DC · 렌더 타이머 초기화까지 삼켰다 (`window.registerGlobalHotkey` 주석).
    // macOS 의 `if (!g_run_opts.isStressRun()) try installEventTap();` 와 같은 형태다.
    if (!opts.isStressRun()) {
        app.window.registerGlobalHotkey(config.hotkey.vkey, config.hotkey.modifiers, config.hotkey.code);
    } else {
        // 건너뛴 사실을 로그에 남긴다 — 측정 실행이 사용자의 핫키를 건드리지 않았는지
        // 확인하는 근거다 (세 host 의 `(stress run)` 로그와 같은 어휘).
        log.appendLine("hotkey", "global hotkey not registered (stress run)", .{});
    }
    log.appendLine("startup", "window initialized: dpi={d} cell={}x{}", .{
        app.window.current_dpi,
        app.window.cell_width_px,
        app.window.cell_height_px,
    });
    // #501 — config 를 읽지 못했거나 만들지 못했으면 여기서 한 번 알린다. **fatal 이
    // 아니다** — 기본값으로 계속 돈다. 창이 뜬 뒤인 것은 세 platform 을 같은 시점으로
    // 맞추기 위함이다 (Linux 는 그 전에 다이얼로그가 보이지 않는다).
    config_mod.showLoadNotice(rt, &config);
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
        dialog.showFatal(rt, messages.renderer_init_failed_title, msg);
    };
    log.appendLine("startup", "render_path={s}", .{app.renderer.?.renderPath()});
    defer if (app.renderer) |*r| r.deinit();

    // Apply position from config.
    //
    // #382 — `-size COLSxROWS` 는 퍼센트를 무시하고 셀 개수로 창을 만든다. 이 시점에
    // `window.init` 이 이미 셀 크기를 확정했으므로 (위 로그의 `cell=WxH`) 바로 환산할
    // 수 있다.
    //
    // #506 — 환산은 `App.gridWindowPercent` 가 한다. 창 크기를 여기서 한 번 정하고 마는
    // 것이 아니라 **탭 수가 1↔2 로 바뀔 때마다** 다시 정해야 해서 (탭바가 세로 공간을
    // 먹거나 돌려준다) 계산이 App 에 있어야 두 시점이 같은 값을 쓴다.
    var want_w_pct = config.width_percent;
    var want_h_pct = config.height_percent;
    app.grid = opts.grid;
    // #506 — 요청 격자를 이 화면에서 끝까지 지킬 수 있는지 **첫 탭 · PTY 를 만들기 전에**
    // 확인한다. 못 지키면 여기서 실행이 끝난다.
    app.guardRequestedGridFits();
    if (app.gridWindowPercent()) |pct| {
        want_w_pct = pct.w;
        want_h_pct = pct.h;
    }
    app.window.setPosition(config.dock_position, want_w_pct, want_h_pct, config.offset_percent);

    // Create initial tab
    try app.createTab();
    log.appendLine("startup", "initial tab created: count={d}", .{app.session.count()});

    // 측정 모드는 `hidden_start` 를 무시한다 (#382) — 숨겨져 있으면 렌더가 일어나지
    // 않아 측정이 무의미하다.
    if (!config.hidden_start or opts.isStressRun()) {
        log.appendLine("startup", "show window", .{});
        app.window.show();
    }

    // #304 — HWND 생성만으로는 충분하지 않다. renderer와 첫 tab, 표시 정책을
    // 모두 적용한 뒤 message loop 진입 직전에 request endpoint를 ready로 공개한다.
    //
    // #382 — 측정 인스턴스는 worker 가 아니다 (worker lock 도 잡지 않는다). 같은 index
    // 의 endpoint 상태를 자기 PID 로 덮으면 lock 의 owner PID 와 snapshot PID 가 어긋나
    // `instances.probeEndpointFiles` 가 계속 `.starting` 을 돌려주고, 측정 프로세스가
    // 사라진 뒤에도 그 파일이 남는다 — 측정이 끝난 다음 사용자가 TildaZ 를 평소처럼
    // 실행하면 10 초 뒤 `RequestEndpointReadyTimeout` 으로 실패한다 (Windows 실기 확인).
    // 측정 인스턴스는 새 instance 요청을 받을 대상이 아니므로 아예 기록하지 않는다.
    if (!opts.isStressRun()) {
        try instances.recordEndpointState(rt, alloc, instance_context.requireWorkerIndex(), .ready);
    }
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
///   - `PROMPT` — cmd 가 프롬프트를 그릴 때마다 OSC 7 로 현재 위치를 알리게 (#366).
///     새 탭이 그 위치에서 시작한다. 조립은 `shell_integration.cmdPrompt` 가 하고,
///     **기존 값 앞에만 덧붙이므로** 사용자 프롬프트 모양이 유지된다. PowerShell 은
///     이 변수를 쓰지 않고 (별도 주입), WSLENV 에 넣지 않으므로 WSL 안 셸에도 전달되지
///     않는다 — cmd 탭에만 효과가 있다.
///
/// #439 — PTY 출력이 ring 에 들어갔다는 통보. **PTY read thread 에서 불린다.**
///
/// 하는 일은 `PostMessageW` 하나뿐이고 (thread-safe), coalescing 과 `hwnd` 검사는
/// `Window.notifyPtyOutput` 안에 있다. Linux 의 `linuxOutputWake` 와 같은 자리다.
fn onOutputWake(userdata: ?*anyopaque) void {
    const window: *Window = @ptrCast(@alignCast(userdata.?));
    window.notifyPtyOutput();
}

/// Buffer lifetime: process lifetime static (다음 호출 시 덮어쓰지만 SessionCore
/// 가 슬라이스를 들고 있는 동안 유효).
fn buildExtraEnv(theme: ?*const themes.Theme) ?[]const terminal.ExtraEnv {
    const t = theme orelse return null;
    const S = struct {
        var wslenv_buf: [768]u8 = undefined;
        var wslenv_len: usize = 0;
        var prompt_buf: [1024]u8 = undefined;
        var vars: [4]terminal.ExtraEnv = undefined;
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
    // `PROMPT_COMMAND` 도 WSL 안까지 넘겨야 bash 가 OSC 7 을 보낸다 (#366).
    const suffix = "COLORFGBG:PROMPT_COMMAND";
    if (pos + suffix.len <= S.wslenv_buf.len) {
        @memcpy(S.wslenv_buf[pos..][0..suffix.len], suffix);
        pos += suffix.len;
    }
    S.wslenv_len = pos;
    S.vars[1] = .{
        .name = "WSLENV",
        .value = S.wslenv_buf[0..S.wslenv_len],
    };

    // PROMPT — 부모의 기존 값을 읽어 보고 조각을 앞에 덧붙인다 (#366). 조립이 실패
    // (버퍼 부족) 하면 이 항목만 빼고 나머지는 그대로 전달한다 — 새 탭이 홈에서
    // 시작하는 기존 동작으로 열화한다.
    var pbuf: [512]WCHAR = undefined;
    const prompt_name = std.unicode.utf8ToUtf16LeStringLiteral("PROMPT");
    const existing_wide = GetEnvironmentVariableW(prompt_name, &pbuf, pbuf.len);
    var existing_storage: [1024]u8 = undefined;
    var existing: []const u8 = &.{};
    if (existing_wide > 0 and existing_wide < pbuf.len) {
        const utf8_len = std.unicode.utf16LeToUtf8(&existing_storage, pbuf[0..existing_wide]) catch 0;
        existing = existing_storage[0..utf8_len];
    }
    // PROMPT_COMMAND — WSL 안 bash 용 (#366). 위 WSLENV 가 이 이름을 넘기게 해 두었다.
    // cmd / PowerShell 은 이 변수를 쓰지 않으므로 무해하다.
    S.vars[2] = .{
        .name = "PROMPT_COMMAND",
        .value = shell_integration.bash_prompt_command,
    };

    if (shell_integration.cmdPrompt(&S.prompt_buf, existing)) |value| {
        S.vars[3] = .{ .name = "PROMPT", .value = value };
        return S.vars[0..4];
    }
    return S.vars[0..3];
}
