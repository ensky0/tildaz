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

    fn drainOutput(self: *App) void {
        var buf: [65536]u8 = undefined;
        while (true) {
            const n = self.output_ring.pop(&buf);
            if (n == 0) break;
            self.stream.nextSlice(buf[0..n]);
        }
    }

    fn render(self: *App) void {
        // Update viewport size
        const size = self.win.getSize();
        self.renderer.resize(size[0], size[1]);

        // Check for resize → update terminal grid + PTY
        const new_cols: u16 = @intCast(@max(1, size[0] / self.cell_w));
        const new_rows: u16 = @intCast(@max(1, size[1] / self.cell_h));
        if (new_cols != self.last_cols or new_rows != self.last_rows) {
            self.last_cols = new_cols;
            self.last_rows = new_rows;
            self.terminal.resize(self.alloc, new_cols, new_rows) catch {};
            self.pty.resize(new_cols, new_rows) catch {};

            // Update CAMetalLayer drawable size
            const drawableSize = extern struct {
                width: objc.CGFloat,
                height: objc.CGFloat,
            };
            const ds = drawableSize{
                .width = @floatFromInt(size[0]),
                .height = @floatFromInt(size[1]),
            };
            const f: *const fn (objc.id, objc.SEL, @TypeOf(ds)) callconv(.c) void = @ptrCast(objc.msgSend_raw);
            f(self.win.metal_layer, objc.sel("setDrawableSize:"), ds);
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

/// PTY exit callback
fn onPtyExit(userdata: ?*anyopaque) void {
    _ = userdata;
    std.log.info("Shell process exited", .{});
    // TODO: 창 닫기 or 재시작
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

    // Calculate cell dimensions
    const font_size: f32 = @floatFromInt(config.font_size);
    var font_ctx = try CoreTextFontContext.init(config.font_families[0], font_size, 0, 0);

    var m_glyph: [1]ct.CGGlyph = .{0};
    var m_utf16: [1]u16 = .{'M'};
    _ = ct.CTFontGetGlyphsForCharacters(font_ctx.primary_font, &m_utf16, &m_glyph, 1);
    var advance: ct.CGSize = .{ .width = 0, .height = 0 };
    _ = ct.CTFontGetAdvancesForGlyphs(font_ctx.primary_font, ct.kCTFontOrientationDefault, &m_glyph, @ptrCast(&advance), 1);

    const cell_w: u32 = @intFromFloat(@ceil(advance.width));
    const cell_h: u32 = @intFromFloat(@ceil(font_ctx.ascent_px + font_ctx.descent_px + @as(f32, @floatCast(ct.CTFontGetLeading(font_ctx.primary_font)))));
    font_ctx.deinit();

    std.log.info("Cell size: {d}x{d}, font_size={d:.1}", .{ cell_w, cell_h, font_size });

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

    // Setup keyboard input callback
    input_mod.setInputCallback(&onKeyInput);
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
