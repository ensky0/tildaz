const std = @import("std");
const App = @import("../app_controller.zig").App;
const SessionCore = @import("../session_core.zig").SessionCore;
const RendererBackend = @import("../renderer.zig").RendererBackend;
const config_mod = @import("../config.zig");
const Config = config_mod.Config;
const autostart = @import("../autostart.zig");
const perf = @import("../perf.zig");
const log = @import("../log.zig");
const dialog = @import("../dialog.zig");
const messages = @import("../messages.zig");
const shell_validate = @import("../shell_validate.zig");
const terminal = @import("../terminal.zig");
const themes = @import("../themes.zig");
const build_options = @import("build_options");

const WCHAR = u16;
extern "kernel32" fn CreateMutexW(?*anyopaque, c_int, [*:0]const WCHAR) callconv(.c) ?*anyopaque;
extern "kernel32" fn GetLastError() callconv(.c) u32;
extern "kernel32" fn CloseHandle(?*anyopaque) callconv(.c) c_int;
extern "kernel32" fn GetEnvironmentVariableW([*:0]const WCHAR, ?[*]WCHAR, u32) callconv(.c) u32;
extern "user32" fn SetProcessDpiAwarenessContext(isize) callconv(.c) c_int;
extern "user32" fn GetDpiForWindow(?*anyopaque) callconv(.c) c_uint;

const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;
const ERROR_ALREADY_EXISTS: u32 = 183;

pub fn showPanic(msg: []const u8, addr: usize) noreturn {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, messages.panic_format, .{ msg, addr }) catch "panic (format failed)";
    dialog.showError(messages.crash_title, text);
    std.process.exit(1);
}

pub fn showFatalRunError(err: anyerror) void {
    log.appendLine("fatal", "run failed: {s}", .{@errorName(err)});

    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buf,
        messages.run_failed_format,
        .{@errorName(err)},
    ) catch "TildaZ failed to start.";
    dialog.showError(messages.error_title, text);
}

pub fn run() !void {
    perf.init();

    // Enable per-monitor DPI awareness (must be before any window/GDI calls)
    _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    // Single instance check
    const mutex = CreateMutexW(null, 0, std.unicode.utf8ToUtf16LeStringLiteral("Global\\TildaZ_SingleInstance"));
    if (mutex != null and GetLastError() == ERROR_ALREADY_EXISTS) {
        _ = CloseHandle(mutex);
        dialog.showInfo(messages.info_title, messages.already_running_msg);
        return;
    }
    defer if (mutex != null) {
        _ = CloseHandle(mutex);
    };

    // %APPDATA%\tildaz\tildaz.log 에 부팅 / 종료 라인을 남긴다.
    // stale exe 가 자동 실행되는 케이스를 사후 추적하기 위한 감사 로그.
    log.logStart(build_options.version);
    defer log.logStop(build_options.version);

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Load configuration. parse() 가 schema (validateStructure) + 각 필드
    // range 모두 fatal 처리 — 별도 validate() 호출 불필요.
    var config = Config.load(alloc);
    defer config.deinit();
    log.appendLine("startup", "config loaded: hidden_start={} auto_start={} shell={s}", .{
        config.hidden_start,
        config.auto_start,
        config.shell,
    });

    // shell executable 이 PATH 또는 절대경로로 실제 존재하는지 *지금* 검증.
    // CreateProcessW 단계까지 가면 윈도우 / 렌더러 / PTY 초기화 비용 다 쓴
    // 뒤 generic 에러로 끝남 — 사용자에게 어디 고쳐야 할지 안내 안 됨.
    shell_validate.validateOrFatal(alloc, config.shell);

    if (config.auto_start) {
        autostart.enable(alloc) catch |err| {
            log.appendLine("autostart", "enable failed: {s}", .{@errorName(err)});
        };
    } else {
        autostart.disable(alloc);
    }

    var app = App{
        .session = undefined,
        .window = .{},
        .allocator = alloc,
    };
    app.session = SessionCore.init(
        alloc,
        config.shellUtf16(),
        config.max_scroll_lines,
        config.theme,
        buildExtraEnv(config.theme),
        App.onSessionTabExit,
        &app,
    );
    defer app.session.deinit();

    // Set up window
    app.window.userdata = &app;
    app.window.write_fn = App.onKeyInput;
    app.window.render_fn = App.onRender;
    app.window.resize_fn = App.onResize;
    app.window.font_change_fn = App.onFontChange;
    app.window.app_event_fn = App.onAppEvent;
    app.window.quit_request_fn = App.onQuitRequest;
    const DWriteFontCtx = @import("../font/windows/font.zig").DWriteFontContext;

    // Validate all font families exist on the system. 하나라도 미설치면 즉시
    // fatal — 사용자가 명시한 chain 전체가 시스템에 있어야 한다는 의도. macOS
    // CoreTextFontContext.init 의 per-entry CTFontCopyFamilyName 검증과 동등.
    // 메시지는 font_validate 가 처리 — 다른 config 에러 (shell_validate / hotkey)
    // 와 같은 풍부한 형식 (chain dump + 미설치 표시 + config 경로).
    const font_validate = @import("../font/validate.zig");
    for (0..config.font_family_count) |i| {
        const idx: u8 = @intCast(i);
        const fam_w = config.fontFamilyUtf16(idx);
        if (!DWriteFontCtx.isFontAvailable(fam_w)) {
            font_validate.showNotFoundFatal(
                config.font_families[i],
                config.font_families[0..config.font_family_count],
            );
        }
    }

    // font.family chain 을 *전체* renderer 까지 전달 — 이전엔 chain[0] 만 도달
    // 하고 나머지는 validation loop 만 거치고 버려지는 사고 (#135 B2). chain
    // entry 들은 config 의 static buffer (fontFamilyUtf16 의 per-index static)
    // 를 가리키는 포인터라 process lifetime 안정. 로컬 array 는 run() 스택
    // 프레임에 살아 있고 SessionCore / Window / Renderer 모두 같은 스코프.
    var font_chain_arr: [config_mod.MAX_FONT_FAMILIES][*:0]const u16 = undefined;
    for (0..config.font_family_count) |i| {
        font_chain_arr[i] = config.fontFamilyUtf16(@intCast(i));
    }
    const font_chain: []const [*:0]const u16 = font_chain_arr[0..config.font_family_count];
    const font_size: c_int = @intCast(config.font_size);
    try app.window.init(font_chain, font_size, config.opacity, config.cell_width, config.line_height, config.hotkey.vkey, config.hotkey.modifiers);
    log.appendLine("startup", "window initialized: dpi={d} cell={}x{}", .{
        app.window.current_dpi,
        app.window.cell_width,
        app.window.cell_height,
    });
    defer app.window.deinit();

    // Scale tab bar / scrollbar / padding constants by the startup DPI.
    // The same computation runs again via `App.onFontChange` whenever the
    // window moves to a monitor with a different DPI.
    app.applyDpiScale(GetDpiForWindow(app.window.hwnd));

    // Initialize renderer backend
    const theme_bg: ?[3]u8 = if (config.theme) |t| .{ t.background.r, t.background.g, t.background.b } else null;
    app.renderer = RendererBackend.init(alloc, app.window.hwnd, font_chain, font_size, @intCast(app.window.cell_width), @intCast(app.window.cell_height), theme_bg) catch |err| blk: {
        log.appendLine("startup", "renderer disabled: {s}", .{@errorName(err)});
        break :blk null;
    };
    log.appendLine("startup", "renderer active={}", .{app.renderer != null});
    defer if (app.renderer) |*r| r.deinit();

    // Apply position from config
    app.window.setPosition(config.dock_position, config.width, config.height, config.offset);

    // Create initial tab
    try app.createTab();
    log.appendLine("startup", "initial tab created: count={d}", .{app.session.count()});

    if (!config.hidden_start) {
        log.appendLine("startup", "show window", .{});
        app.window.show();
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
        .value = if (themes.isDark(t)) "15;0" else "0;15",
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
