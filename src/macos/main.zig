const std = @import("std");
const Config = @import("../config.zig").Config;
const themes = @import("../themes.zig");
const Pty = @import("pty.zig").Pty;
const CoreTextFontContext = @import("font.zig").CoreTextFontContext;
const GlyphAtlas = @import("glyph_atlas.zig").GlyphAtlas;
const MetalRenderer = @import("renderer.zig").MetalRenderer;
const Window = @import("window.zig").Window;
const window_mod = @import("window.zig");
const input_mod = @import("input.zig");
const objc = @import("objc.zig");
const ct = @import("coretext.zig");
const ghostty = @import("ghostty-vt");

// ---------------------------------------------------------------------------
// Lock-free 링버퍼 (단일 생산자, 단일 소비자) — windows/main.zig와 동일
// ---------------------------------------------------------------------------
const RingBuffer = struct {
    buf: [SIZE]u8 align(64) = undefined,
    head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    const SIZE = 4 * 1024 * 1024; // 4MB

    fn push(self: *RingBuffer, data: []const u8) void {
        var i: usize = 0;
        while (i < data.len) {
            const pos = self.head.load(.monotonic);
            const t = self.tail.load(.acquire);
            const free = if (t <= pos) (SIZE - pos + t - 1) else (t - pos - 1);
            if (free == 0) {
                std.Thread.yield() catch {};
                continue;
            }
            const batch = @min(data.len - i, free);
            const first = @min(batch, SIZE - pos);
            @memcpy(self.buf[pos..][0..first], data[i..][0..first]);
            if (batch > first) {
                @memcpy(self.buf[0..batch - first], data[i + first ..][0 .. batch - first]);
            }
            self.head.store((pos + batch) % SIZE, .release);
            i += batch;
        }
    }

    fn pop(self: *RingBuffer, out: []u8) usize {
        const h = self.head.load(.acquire);
        const t = self.tail.load(.monotonic);
        if (t == h) return 0;
        const avail = if (h >= t) (h - t) else (SIZE - t + h);
        const n = @min(avail, out.len);
        const first = @min(n, SIZE - t);
        @memcpy(out[0..first], self.buf[t..][0..first]);
        if (n > first) {
            @memcpy(out[first..n], self.buf[0 .. n - first]);
        }
        self.tail.store((t + n) % SIZE, .release);
        return n;
    }
};

// ---------------------------------------------------------------------------
// App state — 글로벌 싱글톤 (ObjC 콜백에서 접근)
// ---------------------------------------------------------------------------
var g_app: ?*App = null;

const App = struct {
    alloc: std.mem.Allocator,
    win: Window,
    renderer: MetalRenderer,
    terminal: ghostty.Terminal,
    stream: ghostty.TerminalStream,
    pty: Pty,
    output_ring: RingBuffer = .{},
    cell_w: u32,
    cell_h: u32,
    padding: i32 = 4,
    last_cols: u16 = 0,
    last_rows: u16 = 0,
    select_start_pin: ?ghostty.PageList.Pin = null,

    /// Get layer pixel size from bounds × contentsScale (ghostty approach).
    fn getLayerPixelSize(self: *App) [2]u32 {
        const GetBounds: *const fn (objc.id, objc.SEL) callconv(.c) objc.NSRect = @ptrCast(objc.msgSend_raw);
        const bounds = GetBounds(self.win.metal_layer, objc.sel("bounds"));
        const scale = objc.msgSendFloat(self.win.metal_layer, objc.sel("contentsScale"));
        const w = bounds.size.width * scale;
        const h = bounds.size.height * scale;
        return .{
            if (w > 0) @as(u32, @intFromFloat(w)) else 1,
            if (h > 0) @as(u32, @intFromFloat(h)) else 1,
        };
    }

    fn drainOutput(self: *App) void {
        var buf: [65536]u8 = undefined;
        while (true) {
            const n = self.output_ring.pop(&buf);
            if (n == 0) break;
            self.stream.nextSlice(buf[0..n]);
        }
    }

    fn render(self: *App) void {
        // CAMetalLayer is a sublayer with autoresizing — bounds track view size.
        // Read actual pixel size from layer.bounds × contentsScale.
        const size = self.getLayerPixelSize();

        if (size[0] < self.cell_w * 2 or size[1] < self.cell_h * 2) return;

        self.renderer.resize(size[0], size[1]);

        // Check for resize → update terminal grid + PTY
        const new_cols: u16 = @intCast(@min(500, @max(2, size[0] / self.cell_w)));
        const new_rows: u16 = @intCast(@min(300, @max(2, size[1] / self.cell_h)));
        if (new_cols != self.last_cols or new_rows != self.last_rows) {
            // Invalidate render state BEFORE resize to prevent reading
            // stale data during terminal reflow
            self.renderer.render_state.rows = 0;
            self.renderer.render_state.cols = 0;
            self.renderer.render_state.viewport_pin = null;

            self.last_cols = new_cols;
            self.last_rows = new_rows;
            self.terminal.resize(self.alloc, new_cols, new_rows) catch {};
            self.pty.resize(new_cols, new_rows) catch {};
        }

        // Drain PTY output → VT parser
        self.drainOutput();

        // Render terminal to Metal layer
        self.renderer.renderFrame(
            self.win.metal_layer,
            &self.terminal,
            @intCast(self.cell_w),
            @intCast(self.cell_h),
            0, // no tab bar
            self.padding,
        );
    }

    fn writeInput(self: *App, data: []const u8) void {
        _ = self.pty.write(data) catch {};
    }

    fn handleScroll(self: *App, delta: i32) void {
        self.terminal.scrollViewport(.{ .delta = @as(isize, delta) });
    }

    fn handleMouse(self: *App, action: input_mod.MouseAction, px: i32, py: i32) void {
        const cw: i32 = @intCast(self.cell_w);
        const ch: i32 = @intCast(self.cell_h);
        const pad = self.padding;

        // Convert pixel → cell coordinates
        const term_x = px - pad;
        const term_y = py - pad;
        const col: u16 = if (cw > 0 and term_x >= 0) @intCast(@min(@divTrunc(term_x, cw), @as(i32, self.last_cols) - 1)) else 0;
        const row: u16 = if (ch > 0 and term_y >= 0) @intCast(@min(@divTrunc(term_y, ch), @as(i32, self.last_rows) - 1)) else 0;

        const screen: *ghostty.Screen = self.terminal.screens.active;

        switch (action) {
            .down => {
                screen.clearSelection();
                self.select_start_pin = screen.pages.pin(.{ .viewport = .{ .x = col, .y = row } });
            },
            .dragged => {
                const start_pin = self.select_start_pin orelse return;
                const end_pin = screen.pages.pin(.{ .viewport = .{ .x = col, .y = row } }) orelse return;
                const sel = ghostty.Selection.init(start_pin, end_pin, false);
                screen.select(sel) catch {};
            },
            .up => {
                // Selection stays active for Cmd+C
            },
        }
    }

    fn copyToClipboard(self: *App) void {
        const screen: *ghostty.Screen = self.terminal.screens.active;
        const sel = screen.selection orelse return;
        const text = screen.selectionString(self.alloc, .{ .sel = sel }) catch return;
        defer self.alloc.free(text);
        if (text.len == 0) return;

        // Write to NSPasteboard
        const pb_class = objc.getClass("NSPasteboard");
        const pb = objc.msgSend(pb_class, objc.sel("generalPasteboard"));
        if (@intFromPtr(pb) == 0) return;

        objc.msgSendVoid(pb, objc.sel("clearContents"));

        // selectionString returns [:0]const u8 (null-terminated)
        const ns_str = objc.msgSend1(
            objc.getClass("NSString"),
            objc.sel("stringWithUTF8String:"),
            @as([*:0]const u8, text.ptr),
        );
        if (@intFromPtr(ns_str) == 0) return;

        const type_str = objc.nsString("public.utf8-plain-text");
        _ = objc.msgSend2(pb, objc.sel("setString:forType:"), ns_str, type_str);
    }

    fn pasteFromClipboard(self: *App) void {
        // Get general pasteboard
        const pb_class = objc.getClass("NSPasteboard");
        const pb = objc.msgSend(pb_class, objc.sel("generalPasteboard"));
        if (@intFromPtr(pb) == 0) return;

        // Get string from pasteboard
        const str = objc.msgSend1(pb, objc.sel("stringForType:"), objc.nsString("public.utf8-plain-text"));
        if (@intFromPtr(str) == 0) return;

        const utf8 = objc.msgSend(str, objc.sel("UTF8String"));
        if (@intFromPtr(utf8) == 0) return;

        const cstr: [*:0]const u8 = @ptrCast(utf8);
        const len = std.mem.len(cstr);
        if (len > 0) {
            _ = self.pty.write(cstr[0..len]) catch {};
        }
    }
};

// ---------------------------------------------------------------------------
// ObjC 콜백들
// ---------------------------------------------------------------------------

/// PTY read callback → 링버퍼에 push
fn onPtyOutput(data: []const u8, userdata: ?*anyopaque) void {
    _ = userdata;
    if (g_app) |app| {
        app.output_ring.push(data);
    }
}

/// Keyboard input callback → write to PTY
fn onKeyInput(data: []const u8) void {
    if (g_app) |app| {
        app.writeInput(data);
    }
}

/// Scroll callback → scroll terminal viewport
fn onScroll(delta: i32) void {
    if (g_app) |app| {
        app.handleScroll(delta);
    }
}

/// Paste callback → read clipboard and write to PTY
fn onPaste() void {
    if (g_app) |app| {
        app.pasteFromClipboard();
    }
}

/// Copy callback → selection to clipboard
fn onCopy() void {
    if (g_app) |app| {
        app.copyToClipboard();
    }
}

/// Mouse callback → text selection
fn onMouse(action: input_mod.MouseAction, px: i32, py: i32) void {
    if (g_app) |app| {
        app.handleMouse(action, px, py);
    }
}

/// Flag set by PTY exit callback (from read thread) — checked in render loop (main thread)
var g_pty_exited = std.atomic.Value(bool).init(false);

/// PTY exit callback — set flag for main thread to handle
fn onPtyExit(userdata: ?*anyopaque) void {
    _ = userdata;
    std.log.info("Shell process exited", .{});
    g_pty_exited.store(true, .release);
}

// ---------------------------------------------------------------------------
// 메인
// ---------------------------------------------------------------------------
pub fn main() void {
    run() catch |err| {
        std.log.err("TildaZ failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Load configuration
    var config = Config.load(alloc);
    defer config.deinit();

    if (config.validate()) |err_msg| {
        std.log.err("{s}", .{err_msg});
        return;
    }

    std.log.info("TildaZ macOS — shell: {s}, theme: {s}", .{
        config.shell,
        if (config.theme) |t| t.name else "default",
    });

    // Initialize NSApplication
    window_mod.initApp();

    // Create window
    var win = Window.init(800, 600) catch |err| {
        std.log.err("Window init failed: {s}", .{@errorName(err)});
        return;
    };

    std.log.info("Window created, Metal device ready, scale={d:.1}", .{win.scale});

    // Calculate cell dimensions (in PIXELS — point × Retina scale)
    const font_size: f32 = @floatFromInt(config.font_size);
    const scale: f32 = win.scale;
    var font_ctx = try CoreTextFontContext.init(config.font_families[0], font_size, 0, 0, scale);

    var m_glyph: [1]ct.CGGlyph = .{0};
    var m_utf16: [1]u16 = .{'M'};
    _ = ct.CTFontGetGlyphsForCharacters(font_ctx.primary_font, &m_utf16, &m_glyph, 1);

    // CTFontGetAdvancesForGlyphs returns total advance (CGFloat).
    // We use that directly as the single-glyph advance (since count=1).
    const total_advance: f32 = @floatCast(ct.CTFontGetAdvancesForGlyphs(
        font_ctx.primary_font,
        ct.kCTFontOrientationDefault,
        &m_glyph,
        null, // don't need per-glyph array, total return is enough
        1,
    ));

    // CoreText returns point units; multiply by scale for pixel units.
    // font_ctx.ascent_px/descent_px are already in pixels (scale applied in font.zig).
    // CTFontGetLeading returns points, so we scale it here.
    const leading_px: f32 = @as(f32, @floatCast(ct.CTFontGetLeading(font_ctx.primary_font))) * scale;
    const cell_w: u32 = @intFromFloat(@ceil(total_advance * scale));
    const cell_h: u32 = @intFromFloat(@ceil(font_ctx.ascent_px + font_ctx.descent_px + leading_px));
    font_ctx.deinit();

    std.log.info("Cell size: {d}x{d}, font_size={d:.1}, advance={d:.2}pt", .{ cell_w, cell_h, font_size, total_advance });

    // Get theme colors
    const bg_rgb: ?[3]u8 = if (config.theme) |t| .{ t.background.r, t.background.g, t.background.b } else null;
    const term_colors = if (config.theme) |t| ghostty.Terminal.Colors{
        .foreground = ghostty.color.DynamicRGB.init(t.foreground),
        .background = ghostty.color.DynamicRGB.init(t.background),
        .cursor = .unset,
        .palette = ghostty.color.DynamicPalette.init(themes.buildPalette(t.palette)),
    } else ghostty.Terminal.Colors.default;

    // Terminal grid size
    const size = win.getSize();
    const cols: u16 = @intCast(@max(1, size[0] / cell_w));
    const rows: u16 = @intCast(@max(1, size[1] / cell_h));

    // Initialize Metal renderer
    var renderer = try MetalRenderer.init(
        alloc,
        win.device,
        win.metal_layer,
        config.font_families[0],
        font_size,
        cell_w,
        cell_h,
        bg_rgb,
        win.scale,
    );
    renderer.resize(size[0], size[1]);

    std.log.info("Renderer initialized: {d}x{d} ({d}x{d} grid)", .{ size[0], size[1], cols, rows });

    // Initialize ghostty terminal
    var terminal = try ghostty.Terminal.init(alloc, .{
        .cols = cols,
        .rows = rows,
        .colors = term_colors,
    });
    const stream = terminal.vtStream();

    // Start PTY
    const term_env = Pty.EnvVar{ .name = "TERM", .value = "xterm-256color" };
    const extra_env = [_]Pty.EnvVar{term_env};
    const pty = try Pty.init(alloc, cols, rows, config.shell, &extra_env);

    // Setup global app state
    var app = App{
        .alloc = alloc,
        .win = win,
        .renderer = renderer,
        .terminal = terminal,
        .stream = stream,
        .pty = pty,
        .cell_w = cell_w,
        .cell_h = cell_h,
        .last_cols = cols,
        .last_rows = rows,
    };
    g_app = &app;

    // Setup input callbacks
    input_mod.setInputCallback(&onKeyInput);
    input_mod.setScrollCallback(&onScroll);
    input_mod.setPasteCallback(&onPaste);
    input_mod.setCopyCallback(&onCopy);
    input_mod.setMouseCallback(&onMouse);

    // Register for input source change notifications (Korean/English switching)
    input_mod.registerInputSourceObserver(win.ns_view);
    defer {
        g_app = null;
        app.pty.deinit();
        app.terminal.deinit(alloc);
        app.renderer.deinit();
    }

    // Start PTY read thread
    try app.pty.startReadThread(onPtyOutput, onPtyExit, null);

    std.log.info("PTY started (pid={d}), starting render loop...", .{app.pty.child_pid});

    // Show window
    win.show();

    // Create render timer (NSTimer, 16ms ≈ 60fps)
    setupRenderTimer();

    // Run NSApplication event loop
    window_mod.runApp();
}

/// Create a repeating NSTimer for the render loop.
/// Uses NSRunLoop + NSTimer since we need to run inside the AppKit event loop.
fn setupRenderTimer() void {
    // We use a CFRunLoopTimer via Core Foundation, as it's easier to set up
    // from Zig than NSTimer (which needs an ObjC target/selector).
    const CFRunLoopTimerCallBack = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;

    const cf = struct {
        extern "CoreFoundation" fn CFRunLoopGetMain() *anyopaque;
        extern "CoreFoundation" fn CFRunLoopAddTimer(*anyopaque, *anyopaque, *anyopaque) void;
        extern "CoreFoundation" fn CFRunLoopTimerCreate(
            allocator: ?*anyopaque,
            fireDate: f64,
            interval: f64,
            flags: u64,
            order: i64,
            callout: CFRunLoopTimerCallBack,
            context: ?*anyopaque,
        ) *anyopaque;
        extern "CoreFoundation" fn CFAbsoluteTimeGetCurrent() f64;
        extern "CoreFoundation" fn kCFRunLoopCommonModes() *anyopaque;
    };

    // Get kCFRunLoopCommonModes string constant
    // On macOS, this is a global CFStringRef. We access it via dlsym.
    const kCFRunLoopCommonModes = getCommonModes();

    const now = cf.CFAbsoluteTimeGetCurrent();
    const timer = cf.CFRunLoopTimerCreate(
        null, // allocator
        now, // first fire
        1.0 / 60.0, // interval (60fps)
        0, // flags
        0, // order
        &renderTimerCallback,
        null, // context
    );

    const main_loop = cf.CFRunLoopGetMain();
    cf.CFRunLoopAddTimer(main_loop, timer, kCFRunLoopCommonModes);
}

fn renderTimerCallback(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    // Check if shell exited → terminate app
    if (g_pty_exited.load(.acquire)) {
        const app_class = objc.getClass("NSApplication");
        const app = objc.msgSend(app_class, objc.sel("sharedApplication"));
        objc.msgSendVoid1(app, objc.sel("terminate:"), @as(?objc.id, null));
        return;
    }

    if (g_app) |app| {
        app.render();
    }
}

fn getCommonModes() *anyopaque {
    // kCFRunLoopCommonModes is a global CFStringRef exported by CoreFoundation
    const dlsym_fn = @extern(*const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque, .{ .name = "dlsym" });
    const RTLD_DEFAULT = @as(?*anyopaque, @ptrFromInt(@as(usize, @bitCast(@as(isize, -2)))));
    const ptr = dlsym_fn(RTLD_DEFAULT, "kCFRunLoopCommonModes") orelse @panic("kCFRunLoopCommonModes not found");
    // It's a pointer to a CFStringRef, so dereference
    return @as(*const *anyopaque, @ptrCast(@alignCast(ptr))).*;
}
