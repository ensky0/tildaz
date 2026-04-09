// Keyboard + mouse input handling for macOS terminal.
// Creates a custom NSView subclass at runtime that intercepts key/mouse/scroll
// events and forwards them to the App via global callbacks.

const std = @import("std");
const objc = @import("objc.zig");

/// Callback type for writing input data to PTY
pub const InputCallback = *const fn (data: []const u8) void;

/// Callback type for scroll events (delta in lines, negative = scroll up)
pub const ScrollCallback = *const fn (delta: i32) void;

/// Callback type for paste (write clipboard text to PTY)
pub const PasteCallback = *const fn () void;

/// Global callbacks — set by main.zig before creating the view
var g_input_callback: ?InputCallback = null;
var g_scroll_callback: ?ScrollCallback = null;
var g_paste_callback: ?PasteCallback = null;

pub fn setInputCallback(cb: InputCallback) void {
    g_input_callback = cb;
}

pub fn setScrollCallback(cb: ScrollCallback) void {
    g_scroll_callback = cb;
}

pub fn setPasteCallback(cb: PasteCallback) void {
    g_paste_callback = cb;
}

/// Register and return the TildaZView class (NSView subclass).
/// Must be called once before creating view instances.
var registered: bool = false;
var view_class: ?objc.Class = null;

pub fn getViewClass() objc.Class {
    if (registered) return view_class.?;

    view_class = objc.createClass("TildaZView", "NSView");
    const cls = view_class orelse @panic("Failed to create TildaZView class");

    // Key events
    _ = objc.addMethod(cls, objc.sel("acceptsFirstResponder"), @ptrCast(&acceptsFirstResponder), "c@:");
    _ = objc.addMethod(cls, objc.sel("keyDown:"), @ptrCast(&keyDown), "v@:@");
    _ = objc.addMethod(cls, objc.sel("flagsChanged:"), @ptrCast(&flagsChanged), "v@:@");
    _ = objc.addMethod(cls, objc.sel("canBecomeKeyView"), @ptrCast(&canBecomeKeyView), "c@:");

    // Mouse scroll
    _ = objc.addMethod(cls, objc.sel("scrollWheel:"), @ptrCast(&scrollWheel), "v@:@");

    objc.registerClass(cls);
    registered = true;
    return cls;
}

// ---------------------------------------------------------------------------
// ObjC method implementations (called by the runtime via objc_msgSend)
// ---------------------------------------------------------------------------

fn acceptsFirstResponder(_: objc.id, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn canBecomeKeyView(_: objc.id, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn keyDown(_: objc.id, _: objc.SEL, event: objc.id) callconv(.c) void {
    const cb = g_input_callback orelse return;

    // Get modifier flags
    const flags = objc.msgSendUint(event, objc.sel("modifierFlags"));
    const keycode = getKeyCode(event);

    // NSEventModifierFlagControl = 1 << 18
    const ctrl = (flags & (1 << 18)) != 0;
    // NSEventModifierFlagOption/Alt = 1 << 19
    const alt = (flags & (1 << 19)) != 0;
    // NSEventModifierFlagCommand = 1 << 20
    const cmd = (flags & (1 << 20)) != 0;

    // Cmd+V → paste from clipboard
    if (cmd and keycode == 9) { // keycode 9 = 'V'
        if (g_paste_callback) |paste_cb| paste_cb();
        return;
    }

    // Cmd+C → for now, send SIGINT-like behavior (same as Ctrl+C when no selection)
    // TODO: copy selection to clipboard when selection exists

    // Handle Ctrl+key combos → send control character
    if (ctrl) {
        if (handleCtrlKey(cb, keycode, alt)) return;
    }

    // Handle special keys (arrows, enter, backspace, tab, escape, etc.)
    if (handleSpecialKey(cb, keycode, flags)) return;

    // For regular characters, get the NSString from the event
    const chars = objc.msgSend(event, objc.sel("characters"));
    if (@intFromPtr(chars) == 0) return;

    const length = objc.msgSendUint(chars, objc.sel("length"));
    if (length == 0) return;

    // Get UTF-8 representation
    const utf8 = objc.msgSend(chars, objc.sel("UTF8String"));
    if (@intFromPtr(utf8) == 0) return;

    const cstr: [*:0]const u8 = @ptrCast(utf8);
    const len = std.mem.len(cstr);
    if (len > 0) {
        // Option/Alt key: send ESC prefix for alt+key combos
        if (alt and len == 1) {
            cb("\x1b");
        }
        cb(cstr[0..len]);
    }
}

fn flagsChanged(_: objc.id, _: objc.SEL, _: objc.id) callconv(.c) void {
    // Modifier-only key changes — generally no output for terminals
}

fn scrollWheel(_: objc.id, _: objc.SEL, event: objc.id) callconv(.c) void {
    const scroll_cb = g_scroll_callback orelse return;

    // Get scroll delta Y (continuous scrolling on trackpad, discrete on mouse wheel)
    const deltaY: objc.CGFloat = blk: {
        const f: *const fn (objc.id, objc.SEL) callconv(.c) objc.CGFloat = @ptrCast(objc.msgSend_raw);
        break :blk f(event, objc.sel("scrollingDeltaY"));
    };

    // Check if this is a precise (trackpad) or line-based (mouse wheel) scroll
    const hasPreciseDeltas: bool = blk: {
        const f: *const fn (objc.id, objc.SEL) callconv(.c) objc.BOOL = @ptrCast(objc.msgSend_raw);
        break :blk f(event, objc.sel("hasPreciseScrollingDeltas")) != 0;
    };

    if (hasPreciseDeltas) {
        // Trackpad: accumulate pixel deltas, convert to lines (~18px per line)
        const line_height = 18.0;
        // Use a static accumulator for smooth scrolling
        const S = struct {
            var accum: f64 = 0;
        };
        S.accum += deltaY;
        if (@abs(S.accum) >= line_height) {
            const lines: i32 = @intFromFloat(S.accum / line_height);
            S.accum -= @as(f64, @floatFromInt(lines)) * line_height;
            if (lines != 0) scroll_cb(-lines); // negate: deltaY>0 = scroll up (content moves down)
        }
    } else {
        // Mouse wheel: deltaY is in lines (usually ±1 or ±3)
        const lines: i32 = @intFromFloat(-deltaY * 3);
        if (lines != 0) scroll_cb(lines);
    }
}

// ---------------------------------------------------------------------------
// Key code helpers
// ---------------------------------------------------------------------------

fn getKeyCode(event: objc.id) u16 {
    const f: *const fn (objc.id, objc.SEL) callconv(.c) u16 = @ptrCast(objc.msgSend_raw);
    return f(event, objc.sel("keyCode"));
}

/// Handle Ctrl+key → send control character (0x01-0x1A for a-z)
fn handleCtrlKey(cb: InputCallback, keycode: u16, alt: bool) bool {
    const ch: ?u8 = switch (keycode) {
        0 => 0x01, // Ctrl+A
        11 => 0x02, // Ctrl+B
        8 => 0x03, // Ctrl+C
        2 => 0x04, // Ctrl+D
        14 => 0x05, // Ctrl+E
        3 => 0x06, // Ctrl+F
        5 => 0x07, // Ctrl+G
        4 => 0x08, // Ctrl+H (backspace)
        // Ctrl+I = Tab (0x09) — handled as special key
        38 => 0x0A, // Ctrl+J
        40 => 0x0B, // Ctrl+K
        37 => 0x0C, // Ctrl+L
        // Ctrl+M = Enter (0x0D) — handled as special key
        45 => 0x0E, // Ctrl+N
        31 => 0x0F, // Ctrl+O
        35 => 0x10, // Ctrl+P
        12 => 0x11, // Ctrl+Q
        15 => 0x12, // Ctrl+R
        1 => 0x13, // Ctrl+S
        17 => 0x14, // Ctrl+T
        32 => 0x15, // Ctrl+U
        9 => 0x16, // Ctrl+V
        13 => 0x17, // Ctrl+W
        7 => 0x18, // Ctrl+X
        16 => 0x19, // Ctrl+Y
        6 => 0x1A, // Ctrl+Z
        33 => 0x1B, // Ctrl+[ (ESC)
        30 => 0x1C, // Ctrl+backslash
        42 => 0x1D, // Ctrl+]
        else => null,
    };

    if (ch) |c| {
        if (alt) cb("\x1b");
        const buf = [1]u8{c};
        cb(&buf);
        return true;
    }
    return false;
}

/// Handle special keys: arrows, function keys, enter, backspace, etc.
fn handleSpecialKey(cb: InputCallback, keycode: u16, flags: usize) bool {
    const shift = (flags & (1 << 17)) != 0;
    _ = shift;

    const seq: ?[]const u8 = switch (keycode) {
        // Arrow keys
        126 => "\x1b[A", // Up
        125 => "\x1b[B", // Down
        124 => "\x1b[C", // Right
        123 => "\x1b[D", // Left

        // Enter / Return
        36 => "\r",
        76 => "\r", // Numpad Enter

        // Backspace (Delete key on Mac)
        51 => "\x7f",

        // Tab
        48 => "\t",

        // Escape
        53 => "\x1b",

        // Delete forward
        117 => "\x1b[3~",

        // Home / End
        115 => "\x1b[H", // Home
        119 => "\x1b[F", // End

        // Page Up / Down
        116 => "\x1b[5~",
        121 => "\x1b[6~",

        // Function keys
        122 => "\x1bOP", // F1
        120 => "\x1bOQ", // F2
        99 => "\x1bOR", // F3
        118 => "\x1bOS", // F4
        96 => "\x1b[15~", // F5
        97 => "\x1b[17~", // F6
        98 => "\x1b[18~", // F7
        100 => "\x1b[19~", // F8
        101 => "\x1b[20~", // F9
        109 => "\x1b[21~", // F10
        103 => "\x1b[23~", // F11
        111 => "\x1b[24~", // F12

        else => null,
    };

    if (seq) |s| {
        cb(s);
        return true;
    }
    return false;
}
