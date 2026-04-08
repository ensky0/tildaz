const std = @import("std");
const Config = @import("../config.zig").Config;
const themes = @import("../themes.zig");
const Pty = @import("pty.zig").Pty;
const CoreTextFontContext = @import("font.zig").CoreTextFontContext;
const GlyphAtlas = @import("glyph_atlas.zig").GlyphAtlas;
const MetalRenderer = @import("renderer.zig").MetalRenderer;
const Window = @import("window.zig").Window;
const window_mod = @import("window.zig");
const objc = @import("objc.zig");
const ghostty = @import("ghostty-vt");

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
    var font_ctx = CoreTextFontContext.init(config.font_families[0], font_size, 0, 0) catch |err| {
        std.log.err("Font init failed: {s}", .{@errorName(err)});
        return;
    };

    // Get advance width of 'M' to determine cell width
    const ct = @import("coretext.zig");
    var m_glyph: [1]ct.CGGlyph = .{0};
    var m_utf16: [1]u16 = .{'M'};
    _ = ct.CTFontGetGlyphsForCharacters(font_ctx.primary_font, &m_utf16, &m_glyph, 1);
    var advance: ct.CGSize = .{ .width = 0, .height = 0 };
    _ = ct.CTFontGetAdvancesForGlyphs(font_ctx.primary_font, ct.kCTFontOrientationDefault, &m_glyph, @ptrCast(&advance), 1);

    const cell_w: u32 = @intFromFloat(@ceil(advance.width));
    const cell_h: u32 = @intFromFloat(@ceil(font_ctx.ascent_px + font_ctx.descent_px + @as(f32, @floatCast(ct.CTFontGetLeading(font_ctx.primary_font)))));
    font_ctx.cell_width = cell_w;
    font_ctx.cell_height = cell_h;
    font_ctx.deinit();

    std.log.info("Cell size: {d}x{d}, font_size={d:.1}", .{ cell_w, cell_h, font_size });

    // Get theme background color
    const bg_rgb: ?[3]u8 = if (config.theme) |t| .{ t.background.r, t.background.g, t.background.b } else null;

    // Initialize Metal renderer
    var renderer = MetalRenderer.init(
        alloc,
        win.device,
        win.metal_layer,
        config.font_families[0],
        font_size,
        cell_w,
        cell_h,
        bg_rgb,
        win.scale,
    ) catch |err| {
        std.log.err("Renderer init failed: {s}", .{@errorName(err)});
        return;
    };
    defer renderer.deinit();

    // Set viewport size
    const size = win.getSize();
    renderer.resize(size[0], size[1]);

    std.log.info("Renderer initialized: {d}x{d}", .{ size[0], size[1] });

    // Show window
    win.show();

    // Start PTY
    const term_env = Pty.EnvVar{ .name = "TERM", .value = "xterm-256color" };
    const extra_env = [_]Pty.EnvVar{term_env};
    var pty = Pty.init(alloc, @intCast(size[0] / cell_w), @intCast(size[1] / cell_h), config.shell, &extra_env) catch |err| {
        std.log.err("PTY init failed: {s}", .{@errorName(err)});
        return;
    };
    defer pty.deinit();

    std.log.info("PTY started, running event loop...", .{});

    // For now, just run the app event loop
    // Full integration (PTY read → terminal → render) requires connecting
    // the read callback to terminal.feed() and triggering redraws
    window_mod.runApp();
}
