const std = @import("std");
const App = @import("app_controller.zig").App;
const SessionCore = @import("session_core.zig").SessionCore;
const RendererBackend = @import("renderer_backend.zig").RendererBackend;
const Config = @import("config.zig").Config;
const autostart = @import("autostart.zig");
const perf = @import("perf.zig");
const tildaz_log = @import("tildaz_log.zig");
const build_options = @import("build_options");

const WCHAR = u16;
extern "user32" fn MessageBoxW(?*anyopaque, [*:0]const WCHAR, [*:0]const WCHAR, c_uint) callconv(.c) c_int;
extern "user32" fn MessageBoxA(?*anyopaque, [*:0]const u8, [*:0]const u8, c_uint) callconv(.c) c_int;
extern "kernel32" fn CreateMutexW(?*anyopaque, c_int, [*:0]const WCHAR) callconv(.c) ?*anyopaque;
extern "kernel32" fn GetLastError() callconv(.c) u32;
extern "kernel32" fn CloseHandle(?*anyopaque) callconv(.c) c_int;
extern "user32" fn SetProcessDpiAwarenessContext(isize) callconv(.c) c_int;
extern "user32" fn GetDpiForWindow(?*anyopaque) callconv(.c) c_uint;

const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;
const ERROR_ALREADY_EXISTS: u32 = 183;
const MB_OK: c_uint = 0x0;
const MB_ICONERROR: c_uint = 0x10;
const MB_ICONINFORMATION: c_uint = 0x40;

pub fn showPanic(msg: []const u8, addr: usize) noreturn {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "panic: {s}\nreturn address: 0x{x}", .{ msg, addr }) catch "panic (format failed)";
    var msgbuf: [512:0]u8 = std.mem.zeroes([512:0]u8);
    const copy_len = @min(text.len, 511);
    @memcpy(msgbuf[0..copy_len], text[0..copy_len]);
    _ = MessageBoxA(null, &msgbuf, "TildaZ Crash", MB_OK | MB_ICONERROR);
    std.process.exit(1);
}

pub fn showFatalRunError(err: anyerror) void {
    tildaz_log.appendLine("fatal", "run failed: {s}", .{@errorName(err)});
    const msg = std.unicode.utf8ToUtf16LeStringLiteral("TildaZ 실행 중 오류가 발생했습니다.");
    const title = std.unicode.utf8ToUtf16LeStringLiteral("TildaZ Error");
    _ = MessageBoxW(null, msg, title, MB_OK | MB_ICONERROR);
}

pub fn run() !void {
    perf.init();

    // Enable per-monitor DPI awareness (must be before any window/GDI calls)
    _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    // Single instance check
    const mutex = CreateMutexW(null, 0, std.unicode.utf8ToUtf16LeStringLiteral("Global\\TildaZ_SingleInstance"));
    if (mutex != null and GetLastError() == ERROR_ALREADY_EXISTS) {
        _ = CloseHandle(mutex);
        const msg = std.unicode.utf8ToUtf16LeStringLiteral("TildaZ is already running.");
        const title = std.unicode.utf8ToUtf16LeStringLiteral("TildaZ");
        _ = MessageBoxW(null, msg, title, MB_OK | MB_ICONINFORMATION);
        return;
    }
    defer if (mutex != null) {
        _ = CloseHandle(mutex);
    };

    // %APPDATA%\tildaz\tildaz.log 에 부팅 / 종료 라인을 남긴다.
    // stale exe 가 자동 실행되는 케이스를 사후 추적하기 위한 감사 로그.
    tildaz_log.logStart(build_options.version);
    defer tildaz_log.logStop(build_options.version);

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Load configuration
    var config = Config.load(alloc);
    defer config.deinit();

    if (config.validate()) |err_msg| {
        const title = std.unicode.utf8ToUtf16LeStringLiteral("TildaZ Config Error");
        _ = MessageBoxW(null, err_msg, title, MB_OK | MB_ICONERROR);
        return;
    }
    tildaz_log.appendLine("startup", "config loaded: hidden_start={} auto_start={} shell={s}", .{
        config.hidden_start,
        config.auto_start,
        config.shell,
    });

    if (config.auto_start) {
        autostart.enable() catch |err| {
            tildaz_log.appendLine("autostart", "enable failed: {s}", .{@errorName(err)});
        };
    } else {
        autostart.disable();
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
    const DWriteFontCtx = @import("dwrite_font.zig").DWriteFontContext;

    // Validate all font families exist on the system
    for (0..config.font_family_count) |i| {
        const idx: u8 = @intCast(i);
        const fam_w = config.fontFamilyUtf16(idx);
        if (!DWriteFontCtx.isFontAvailable(fam_w)) {
            var msg_buf: [256]WCHAR = undefined;
            var pos: usize = 0;
            const prefix = std.unicode.utf8ToUtf16LeStringLiteral("Font not found: \"");
            for (prefix[0..17]) |c| {
                if (pos < msg_buf.len - 2) {
                    msg_buf[pos] = c;
                    pos += 1;
                }
            }
            const fam = config.font_families[i];
            for (fam) |c| {
                if (pos < msg_buf.len - 2) {
                    msg_buf[pos] = c;
                    pos += 1;
                }
            }
            msg_buf[pos] = '"';
            pos += 1;
            msg_buf[pos] = 0;
            _ = MessageBoxW(null, @ptrCast(&msg_buf), std.unicode.utf8ToUtf16LeStringLiteral("TildaZ Config Error"), MB_OK | MB_ICONERROR);
            return;
        }
    }

    const font_family_w = config.fontFamilyUtf16(0);
    const font_size: c_int = @intCast(config.font_size);
    try app.window.init(font_family_w, font_size, config.opacity, config.cell_width, config.line_height);
    tildaz_log.appendLine("startup", "window initialized: dpi={d} cell={}x{}", .{
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
    app.renderer = RendererBackend.init(alloc, app.window.hwnd, font_family_w, font_size, @intCast(app.window.cell_width), @intCast(app.window.cell_height), theme_bg) catch |err| blk: {
        tildaz_log.appendLine("startup", "renderer disabled: {s}", .{@errorName(err)});
        break :blk null;
    };
    tildaz_log.appendLine("startup", "renderer active={}", .{app.renderer != null});
    defer if (app.renderer) |*r| r.deinit();

    // Apply position from config
    app.window.setPosition(config.dock_position, config.width, config.height, config.offset);

    // Create initial tab
    try app.createTab();
    tildaz_log.appendLine("startup", "initial tab created: count={d}", .{app.session.count()});

    if (!config.hidden_start) {
        tildaz_log.appendLine("startup", "show window", .{});
        app.window.show();
    }
    tildaz_log.appendLine("startup", "enter message loop", .{});
    app.window.messageLoop();
    tildaz_log.appendLine("startup", "message loop exited", .{});
}
