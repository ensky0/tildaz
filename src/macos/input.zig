// Keyboard + mouse + IME input handling for macOS terminal.
// Creates a custom NSView subclass at runtime that intercepts key/mouse/scroll
// events and uses NSTextInputClient for proper IME support (Korean, Japanese, etc.).

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

/// IME marked text state (for composing characters like Korean/Japanese)
var g_marked_len: usize = 0; // number of Unicode characters in current marked text

const NSRange = extern struct {
    location: usize,
    length: usize,
};

const NSNotFound: usize = @as(usize, @bitCast(@as(isize, -1)));

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

    // NSTextInputClient protocol methods (for IME: Korean, Japanese, Chinese, etc.)
    _ = objc.addMethod(cls, objc.sel("insertText:replacementRange:"), @ptrCast(&imeInsertText), "v@:@{_NSRange=QQ}");
    _ = objc.addMethod(cls, objc.sel("insertText:"), @ptrCast(&imeInsertTextSimple), "v@:@");
    _ = objc.addMethod(cls, objc.sel("setMarkedText:selectedRange:replacementRange:"), @ptrCast(&imeSetMarkedText), "v@:@{_NSRange=QQ}{_NSRange=QQ}");
    _ = objc.addMethod(cls, objc.sel("unmarkText"), @ptrCast(&imeUnmarkText), "v@:");
    _ = objc.addMethod(cls, objc.sel("hasMarkedText"), @ptrCast(&imeHasMarkedText), "c@:");
    _ = objc.addMethod(cls, objc.sel("markedRange"), @ptrCast(&imeMarkedRange), "{_NSRange=QQ}@:");
    _ = objc.addMethod(cls, objc.sel("selectedRange"), @ptrCast(&imeSelectedRange), "{_NSRange=QQ}@:");
    _ = objc.addMethod(cls, objc.sel("validAttributesForMarkedText"), @ptrCast(&imeValidAttributes), "@@:");
    _ = objc.addMethod(cls, objc.sel("attributedSubstringForProposedRange:actualRange:"), @ptrCast(&imeAttrSubstring), "@@:{_NSRange=QQ}^{_NSRange=QQ}");
    _ = objc.addMethod(cls, objc.sel("characterIndexForPoint:"), @ptrCast(&imeCharIndex), "Q@:{CGPoint=dd}");
    _ = objc.addMethod(cls, objc.sel("firstRectForCharacterRange:actualRange:"), @ptrCast(&imeFirstRect), "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}");
    _ = objc.addMethod(cls, objc.sel("doCommandBySelector:"), @ptrCast(&imeDoCommand), "v@::");

    // Mouse scroll
    _ = objc.addMethod(cls, objc.sel("scrollWheel:"), @ptrCast(&scrollWheel), "v@:@");

    // Adopt NSTextInputClient protocol so inputContext recognizes this view
    if (objc.objc_getProtocol("NSTextInputClient")) |protocol| {
        _ = objc.class_addProtocol(cls, protocol);
    }

    objc.registerClass(cls);
    registered = true;
    return cls;
}

// ---------------------------------------------------------------------------
// ObjC method implementations
// ---------------------------------------------------------------------------

fn acceptsFirstResponder(_: objc.id, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn canBecomeKeyView(_: objc.id, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn keyDown(self_view: objc.id, _: objc.SEL, event: objc.id) callconv(.c) void {
    const cb = g_input_callback orelse return;

    // Get modifier flags
    const flags = objc.msgSendUint(event, objc.sel("modifierFlags"));
    const keycode = getKeyCode(event);

    const ctrl = (flags & (1 << 18)) != 0;
    const alt = (flags & (1 << 19)) != 0;
    const cmd = (flags & (1 << 20)) != 0;

    // Cmd+V → paste from clipboard
    if (cmd and keycode == 9) {
        if (g_paste_callback) |paste_cb| paste_cb();
        return;
    }

    // Handle Ctrl+key combos → send control character (bypass IME)
    if (ctrl) {
        if (handleCtrlKey(cb, keycode, alt)) return;
    }

    // Alt+key → ESC prefix + character (bypass IME)
    if (alt) {
        const chars = objc.msgSend(event, objc.sel("characters"));
        if (@intFromPtr(chars) != 0) {
            const utf8 = objc.msgSend(chars, objc.sel("UTF8String"));
            if (@intFromPtr(utf8) != 0) {
                const cstr: [*:0]const u8 = @ptrCast(utf8);
                const len = std.mem.len(cstr);
                if (len > 0) {
                    cb("\x1b");
                    cb(cstr[0..len]);
                }
            }
        }
        return;
    }

    // F-keys, Home, End, PageUp, PageDown, Delete forward → bypass IME
    // These have no corresponding doCommandBySelector: mapping
    if (handleFunctionKey(cb, keycode)) return;

    // All other keys (including Enter, Tab, Backspace, Arrows, normal chars)
    // → delegate to IME. This ensures:
    //   1. Korean/Japanese composing works correctly
    //   2. Enter/Backspace first commits any marked text, THEN executes the action
    //   3. inputContext is properly initialized even on first keypress
    const input_ctx = objc.msgSend(self_view, objc.sel("inputContext"));
    if (@intFromPtr(input_ctx) != 0) {
        if (objc.msgSendBool1(input_ctx, objc.sel("handleEvent:"), event)) return;
    }

    // Fallback: use interpretKeyEvents: (works even if inputContext is nil)
    const array_class = objc.getClass("NSArray");
    const array = objc.msgSend1(array_class, objc.sel("arrayWithObject:"), event);
    objc.msgSendVoid1(self_view, objc.sel("interpretKeyEvents:"), array);
}

fn flagsChanged(_: objc.id, _: objc.SEL, _: objc.id) callconv(.c) void {
    // Modifier-only key changes — generally no output for terminals
}

// ---------------------------------------------------------------------------
// NSTextInputClient implementation — IME support
// ---------------------------------------------------------------------------

/// NSResponder's insertText: (1-arg version) — called by some input methods
/// during input source switching (e.g., English → Korean transition)
fn imeInsertTextSimple(_: objc.id, _: objc.SEL, text: objc.id) callconv(.c) void {
    const cb = g_input_callback orelse return;
    eraseMarkedText(cb);

    const str = getStringFromInput(text);
    if (@intFromPtr(str) == 0) return;

    const utf8 = objc.msgSend(str, objc.sel("UTF8String"));
    if (@intFromPtr(utf8) == 0) return;

    const cstr: [*:0]const u8 = @ptrCast(utf8);
    const len = std.mem.len(cstr);
    if (len > 0) cb(cstr[0..len]);
}

/// Called when text input is finalized (e.g., after composing Korean characters)
fn imeInsertText(_: objc.id, _: objc.SEL, text: objc.id, _: NSRange) callconv(.c) void {
    const cb = g_input_callback orelse return;

    // Delete previous marked text by sending DEL characters
    eraseMarkedText(cb);

    // Get the finalized text string
    const str = getStringFromInput(text);
    if (@intFromPtr(str) == 0) return;

    const utf8 = objc.msgSend(str, objc.sel("UTF8String"));
    if (@intFromPtr(utf8) == 0) return;

    const cstr: [*:0]const u8 = @ptrCast(utf8);
    const len = std.mem.len(cstr);
    if (len > 0) cb(cstr[0..len]);
}

/// Called during text composition (e.g., typing Korean jamo that form a syllable)
fn imeSetMarkedText(_: objc.id, _: objc.SEL, text: objc.id, _: NSRange, _: NSRange) callconv(.c) void {
    const cb = g_input_callback orelse return;

    // Delete previous marked text
    eraseMarkedText(cb);

    // Get new marked text
    const str = getStringFromInput(text);
    if (@intFromPtr(str) == 0) {
        g_marked_len = 0;
        return;
    }

    const new_len = objc.msgSendUint(str, objc.sel("length"));
    g_marked_len = new_len;

    if (new_len == 0) return;

    // Send the composing text to PTY so the user can see what they're typing
    const utf8 = objc.msgSend(str, objc.sel("UTF8String"));
    if (@intFromPtr(utf8) == 0) return;

    const cstr: [*:0]const u8 = @ptrCast(utf8);
    const slen = std.mem.len(cstr);
    if (slen > 0) cb(cstr[0..slen]);
}

fn imeUnmarkText(_: objc.id, _: objc.SEL) callconv(.c) void {
    g_marked_len = 0;
}

fn imeHasMarkedText(_: objc.id, _: objc.SEL) callconv(.c) objc.BOOL {
    return if (g_marked_len > 0) objc.YES else objc.NO;
}

fn imeMarkedRange(_: objc.id, _: objc.SEL) callconv(.c) NSRange {
    if (g_marked_len > 0) {
        return .{ .location = 0, .length = g_marked_len };
    }
    return .{ .location = NSNotFound, .length = 0 };
}

fn imeSelectedRange(_: objc.id, _: objc.SEL) callconv(.c) NSRange {
    return .{ .location = NSNotFound, .length = 0 };
}

fn imeValidAttributes(_: objc.id, _: objc.SEL) callconv(.c) objc.id {
    // Return empty NSArray
    return objc.msgSend(objc.getClass("NSArray"), objc.sel("array"));
}

fn imeAttrSubstring(_: objc.id, _: objc.SEL, _: NSRange, _: ?*NSRange) callconv(.c) ?objc.id {
    return null; // nil
}

fn imeCharIndex(_: objc.id, _: objc.SEL, _: objc.CGFloat, _: objc.CGFloat) callconv(.c) usize {
    return NSNotFound;
}

const CGRect = extern struct {
    x: objc.CGFloat,
    y: objc.CGFloat,
    w: objc.CGFloat,
    h: objc.CGFloat,
};

fn imeFirstRect(_: objc.id, _: objc.SEL, _: NSRange, _: ?*NSRange) callconv(.c) CGRect {
    return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
}

/// Called by interpretKeyEvents: for action commands (e.g., arrow keys in some contexts)
fn imeDoCommand(_: objc.id, _: objc.SEL, cmd_sel: objc.SEL) callconv(.c) void {
    // Most special keys are already handled in keyDown: before interpretKeyEvents:
    // This handles edge cases where the input method sends commands
    const cb = g_input_callback orelse return;

    // Map common selectors to escape sequences
    if (cmd_sel == objc.sel("insertNewline:")) {
        cb("\r");
    } else if (cmd_sel == objc.sel("insertTab:")) {
        cb("\t");
    } else if (cmd_sel == objc.sel("deleteBackward:")) {
        cb("\x7f");
    } else if (cmd_sel == objc.sel("moveUp:")) {
        cb("\x1b[A");
    } else if (cmd_sel == objc.sel("moveDown:")) {
        cb("\x1b[B");
    } else if (cmd_sel == objc.sel("moveRight:")) {
        cb("\x1b[C");
    } else if (cmd_sel == objc.sel("moveLeft:")) {
        cb("\x1b[D");
    } else if (cmd_sel == objc.sel("cancelOperation:")) {
        cb("\x1b");
    } else if (cmd_sel == objc.sel("deleteForward:")) {
        cb("\x1b[3~");
    }
    // noop: and other selectors are silently ignored
}

// ---------------------------------------------------------------------------
// IME helpers
// ---------------------------------------------------------------------------

/// Erase previous marked text by sending DEL (0x7f) for each character
fn eraseMarkedText(cb: InputCallback) void {
    for (0..g_marked_len) |_| {
        cb("\x7f");
    }
    g_marked_len = 0;
}

/// Extract NSString from input (could be NSString or NSAttributedString)
fn getStringFromInput(text: objc.id) objc.id {
    if (@intFromPtr(text) == 0) return text;

    // Check if it's an NSAttributedString by checking for 'string' method
    const attr_str_class = objc.getClass("NSAttributedString");
    const is_attr: objc.BOOL = blk: {
        const f: *const fn (objc.id, objc.SEL, objc.Class) callconv(.c) objc.BOOL = @ptrCast(objc.msgSend_raw);
        break :blk f(text, objc.sel("isKindOfClass:"), attr_str_class);
    };

    if (is_attr != 0) {
        return objc.msgSend(text, objc.sel("string"));
    }
    return text;
}

// ---------------------------------------------------------------------------
// Scroll wheel
// ---------------------------------------------------------------------------

fn scrollWheel(_: objc.id, _: objc.SEL, event: objc.id) callconv(.c) void {
    const scroll_cb = g_scroll_callback orelse return;

    const deltaY: objc.CGFloat = blk: {
        const f: *const fn (objc.id, objc.SEL) callconv(.c) objc.CGFloat = @ptrCast(objc.msgSend_raw);
        break :blk f(event, objc.sel("scrollingDeltaY"));
    };

    const hasPreciseDeltas: bool = blk: {
        const f: *const fn (objc.id, objc.SEL) callconv(.c) objc.BOOL = @ptrCast(objc.msgSend_raw);
        break :blk f(event, objc.sel("hasPreciseScrollingDeltas")) != 0;
    };

    if (hasPreciseDeltas) {
        // Trackpad: accumulate pixel deltas, convert to lines (~18px per line)
        const line_height = 18.0;
        const S = struct {
            var accum: f64 = 0;
        };
        S.accum += deltaY;
        if (@abs(S.accum) >= line_height) {
            const lines: i32 = @intFromFloat(S.accum / line_height);
            S.accum -= @as(f64, @floatFromInt(lines)) * line_height;
            if (lines != 0) scroll_cb(-lines);
        }
    } else {
        // Mouse wheel
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
        38 => 0x0A, // Ctrl+J
        40 => 0x0B, // Ctrl+K
        37 => 0x0C, // Ctrl+L
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

/// Handle keys that IME doesn't map to doCommandBySelector:
/// (F-keys, Home, End, PageUp, PageDown, Delete forward, Escape)
fn handleFunctionKey(cb: InputCallback, keycode: u16) bool {
    const seq: ?[]const u8 = switch (keycode) {
        53 => "\x1b", // Escape
        117 => "\x1b[3~", // Delete forward
        115 => "\x1b[H", // Home
        119 => "\x1b[F", // End
        116 => "\x1b[5~", // Page Up
        121 => "\x1b[6~", // Page Down
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
