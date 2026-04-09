// AppKit window — creates NSWindow with Metal-backed NSView.
// macOS equivalent of windows/window.zig (Win32 HWND).

const std = @import("std");
const objc = @import("objc.zig");
const input = @import("input.zig");

pub const Window = struct {
    ns_window: objc.id,
    ns_view: objc.id,
    metal_layer: objc.id,
    device: objc.id,
    scale: f32,

    pub fn init(width: u32, height: u32) !Window {
        // Create Metal device
        const device = objc.MTLCreateSystemDefaultDevice() orelse return error.NoMetalDevice;

        // Create NSWindow
        const rect = objc.NSRect{
            .origin = .{ .x = 100, .y = 100 },
            .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
        };

        // Style mask: titled | closable | resizable | miniaturizable
        const style_mask: objc.NSUInteger = (1 << 0) | (1 << 1) | (1 << 3) | (1 << 2);

        const ns_window_class = objc.getClass("NSWindow");
        const ns_window_alloc = objc.msgSend(ns_window_class, objc.sel("alloc"));

        // initWithContentRect:styleMask:backing:defer:
        // NSBackingStoreBuffered = 2
        const initSel = objc.sel("initWithContentRect:styleMask:backing:defer:");
        const initFn: *const fn (objc.id, objc.SEL, objc.NSRect, objc.NSUInteger, objc.NSUInteger, objc.BOOL) callconv(.c) objc.id = @ptrCast(objc.msgSend_raw);
        const ns_window = initFn(ns_window_alloc, initSel, rect, style_mask, 2, objc.NO);

        // Set window title
        objc.msgSendVoid1(ns_window, objc.sel("setTitle:"), objc.nsString("TildaZ"));

        // Set minimum window size to prevent crashes from tiny windows
        const min_size = objc.NSSize{ .width = 200, .height = 100 };
        const setMinSizeFn: *const fn (objc.id, objc.SEL, objc.NSSize) callconv(.c) void = @ptrCast(objc.msgSend_raw);
        setMinSizeFn(ns_window, objc.sel("setMinSize:"), min_size);

        // Create custom TildaZView (NSView subclass with key event handling)
        const ns_view_class = input.getViewClass();
        const ns_view = objc.msgSend(objc.msgSend(ns_view_class, objc.sel("alloc")), objc.sel("init"));

        // Create CAMetalLayer
        const layer_class = objc.getClass("CAMetalLayer");
        const metal_layer = objc.msgSend(layer_class, objc.sel("layer"));

        // Configure layer
        objc.msgSendVoid1(metal_layer, objc.sel("setDevice:"), device);
        // MTLPixelFormatBGRA8Unorm = 80
        objc.msgSendVoid1(metal_layer, objc.sel("setPixelFormat:"), @as(objc.NSUInteger, 80));
        objc.msgSendVoid1(metal_layer, objc.sel("setContentsScale:"), @as(objc.CGFloat, 2.0));

        // Set view's layer
        objc.msgSendVoid1(ns_view, objc.sel("setWantsLayer:"), objc.YES);
        objc.msgSendVoid1(ns_view, objc.sel("setLayer:"), metal_layer);

        // Set content view
        objc.msgSendVoid1(ns_window, objc.sel("setContentView:"), ns_view);

        // Get backing scale factor
        const screen = objc.msgSend(ns_window, objc.sel("screen"));
        const scale_factor: objc.CGFloat = if (@intFromPtr(screen) != 0)
            objc.msgSendFloat(screen, objc.sel("backingScaleFactor"))
        else
            2.0;

        return .{
            .ns_window = ns_window,
            .ns_view = ns_view,
            .metal_layer = metal_layer,
            .device = device,
            .scale = @floatCast(scale_factor),
        };
    }

    pub fn show(self: *Window) void {
        objc.msgSendVoid1(self.ns_window, objc.sel("makeKeyAndOrderFront:"), @as(?objc.id, null));

        // Center on screen
        objc.msgSendVoid(self.ns_window, objc.sel("center"));

        // Make the view first responder so it receives key events
        _ = objc.msgSendBool1(self.ns_window, objc.sel("makeFirstResponder:"), self.ns_view);
    }

    pub fn getSize(self: *Window) [2]u32 {
        // Get the content view's frame size (in points)
        const frame = self.getContentFrame();
        return .{
            @intFromFloat(frame.size.width * @as(objc.CGFloat, @floatCast(self.scale))),
            @intFromFloat(frame.size.height * @as(objc.CGFloat, @floatCast(self.scale))),
        };
    }

    fn getContentFrame(self: *Window) objc.NSRect {
        const f: *const fn (objc.id, objc.SEL) callconv(.c) objc.NSRect = @ptrCast(objc.msgSend_raw);
        return f(self.ns_view, objc.sel("frame"));
    }
};

/// Initialize NSApplication and set activation policy.
pub fn initApp() void {
    const app_class = objc.getClass("NSApplication");
    const app = objc.msgSend(app_class, objc.sel("sharedApplication"));

    // NSApplicationActivationPolicyRegular = 0
    objc.msgSendVoid1(app, objc.sel("setActivationPolicy:"), @as(objc.NSInteger, 0));

    // Activate (bring to front)
    objc.msgSendVoid1(app, objc.sel("activateIgnoringOtherApps:"), objc.YES);
}

/// Run the NSApplication event loop (blocks).
pub fn runApp() void {
    const app_class = objc.getClass("NSApplication");
    const app = objc.msgSend(app_class, objc.sel("sharedApplication"));
    objc.msgSendVoid(app, objc.sel("run"));
}
