// Keyboard input handling for macOS terminal.
// Creates a custom NSView subclass at runtime that intercepts key events
// and forwards them to the PTY via the global App singleton.

const std = @import("std");
const objc = @import("objc.zig");

/// Callback type for writing input data to PTY
pub const InputCallback = *const fn (data: []const u8) void;

/// Global callback — set by main.zig before creating the view
var g_input_callback: ?InputCallback = null;

pub fn setInputCallback(cb: InputCallback) void {
    g_input_callback = cb;
}

/// Register and return the TildaZView class (NSView subclass).
/// Must be called once before creating view instances.
var registered: bool = false;
var view_class: ?objc.Class = null;

pub fn getViewClass() objc.Class {
    if (registered) return view_class.?;

    view_class = objc.createClass("TildaZView", "NSView");
    const cls = view_class orelse @panic("Failed to create TildaZView class");

    // acceptsFirstResponder → YES (required to receive key events)
    _ = objc.addMethod(cls, objc.sel("acceptsFirstResponder"), @ptrCast(&acceptsFirstResponder), "c@:");

    // keyDown: → forward characters to PTY
    _ = objc.addMethod(cls, objc.sel("keyDown:"), @ptrCast(&keyDown), "v@:@");

    // flagsChanged: → handle modifier key events (for standalone modifiers)
    _ = objc.addMethod(cls, objc.sel("flagsChanged:"), @ptrCast(&flagsChanged), "v@:@");

    // canBecomeKeyView → YES
    _ = objc.addMethod(cls, objc.sel("canBecomeKeyView"), @ptrCast(&canBecomeKeyView), "c@:");

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
