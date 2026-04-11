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

/// Callback type for copy (selection → clipboard)
pub const CopyCallback = *const fn () void;

/// Mouse action types
pub const MouseAction = enum { down, dragged, up };

/// Callback for mouse events (action, pixel_x, pixel_y)
pub const MouseCallback = *const fn (action: MouseAction, px: i32, py: i32) void;

/// Global callbacks — set by main.zig before creating the view
var g_input_callback: ?InputCallback = null;
var g_scroll_callback: ?ScrollCallback = null;
var g_paste_callback: ?PasteCallback = null;
var g_copy_callback: ?CopyCallback = null;
var g_mouse_callback: ?MouseCallback = null;

/// IME marked text state (for composing characters like Korean/Japanese)
var g_marked_len: usize = 0; // number of Unicode characters in current marked text

/// Preedit text buffer — stores UTF-8 of the current composing text for rendering
var g_preedit_buf: [64]u8 = undefined;
var g_preedit_len: usize = 0;

/// Tracks whether the input source just changed. Used to detect and work around
/// the macOS IMK mach port timing bug where the first keystroke after switching
/// input sources gets committed directly instead of entering composition mode.
var g_source_just_changed: bool = false;
/// Set to true when we suppressed a jamo insertText and need to replay the key event.
var g_needs_replay: bool = false;

/// Returns the current preedit (composing) text, or null if not composing.
pub fn getPreeditText() ?[]const u8 {
    if (g_preedit_len == 0) return null;
    return g_preedit_buf[0..g_preedit_len];
}

/// IME cursor rect in screen coordinates (for candidate window positioning)
var g_ime_cursor_rect: CGRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

pub fn setIMECursorRect(rect: CGRect) void {
    g_ime_cursor_rect = rect;
}

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

pub fn setCopyCallback(cb: CopyCallback) void {
    g_copy_callback = cb;
}

pub fn setMouseCallback(cb: MouseCallback) void {
    g_mouse_callback = cb;
}

/// Register and return the TildaZView class (NSView subclass).
/// Must be called once before creating view instances.
var registered: bool = false;
var view_class: ?objc.Class = null;

pub fn getViewClass() objc.Class {
    if (registered) return view_class.?;

    view_class = objc.createClass("TildaZView", "NSView");
    const cls = view_class orelse @panic("Failed to create TildaZView class");

    // Layout: sync layer bounds with view bounds (layer-hosting view)
    _ = objc.addMethod(cls, objc.sel("layout"), @ptrCast(&viewLayout), "v@:");

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

    // Mouse events
    _ = objc.addMethod(cls, objc.sel("scrollWheel:"), @ptrCast(&scrollWheel), "v@:@");
    _ = objc.addMethod(cls, objc.sel("mouseDown:"), @ptrCast(&mouseDown), "v@:@");
    _ = objc.addMethod(cls, objc.sel("mouseDragged:"), @ptrCast(&mouseDragged), "v@:@");
    _ = objc.addMethod(cls, objc.sel("mouseUp:"), @ptrCast(&mouseUp), "v@:@");

    // Input source change notification handler (for Korean/English switching)
    _ = objc.addMethod(cls, objc.sel("inputSourceChanged:"), @ptrCast(&inputSourceChanged), "v@:@");

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

/// Called by AppKit during layout — sync layer geometry with view bounds.
/// With layer-hosting view, [view layer] IS the CAMetalLayer, so we update
/// its bounds and drawableSize directly.
fn viewLayout(self_view: objc.id, _: objc.SEL) callconv(.c) void {
    // Call [super layout]
    const super_class = objc.getClass("NSView");
    const sup = objc.ObjcSuper{ .receiver = self_view, .super_class = super_class };
    const superLayoutFn: *const fn (*const objc.ObjcSuper, objc.SEL) callconv(.c) void = @ptrCast(objc.msgSendSuper_raw);
    superLayoutFn(&sup, objc.sel("layout"));

    // [view layer] is our CAMetalLayer (layer-hosting view)
    const layer = objc.msgSend(self_view, objc.sel("layer"));
    if (@intFromPtr(layer) == 0) return;

    const GetBounds: *const fn (objc.id, objc.SEL) callconv(.c) objc.NSRect = @ptrCast(objc.msgSend_raw);
    const bounds = GetBounds(self_view, objc.sel("bounds"));

    const SetBounds: *const fn (objc.id, objc.SEL, objc.NSRect) callconv(.c) void = @ptrCast(objc.msgSend_raw);
    SetBounds(layer, objc.sel("setBounds:"), bounds);

    // Update Metal drawable size to match pixel dimensions
    const scale = objc.msgSendFloat(layer, objc.sel("contentsScale"));
    const pw = bounds.size.width * scale;
    const ph = bounds.size.height * scale;
    if (pw > 0 and ph > 0) {
        const SetDrawableSize: *const fn (objc.id, objc.SEL, objc.NSSize) callconv(.c) void = @ptrCast(objc.msgSend_raw);
        SetDrawableSize(layer, objc.sel("setDrawableSize:"), .{
            .width = pw,
            .height = ph,
        });
    }
}

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

    // Cmd+C → copy selection to clipboard
    if (cmd and keycode == 8) {
        if (g_copy_callback) |copy_cb| copy_cb();
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

    const array_class = objc.getClass("NSArray");
    const array = objc.msgSend1(array_class, objc.sel("arrayWithObject:"), event);
    objc.msgSendVoid1(self_view, objc.sel("interpretKeyEvents:"), array);

    // Replay mechanism for IMK mach port timing bug:
    // If the first keystroke after input source switch was incorrectly committed
    // (insertText instead of setMarkedText), we suppressed it and retry here.
    // The first attempt triggers the mach port setup; the retry should compose.
    if (g_needs_replay) {
        g_needs_replay = false;
        // The first interpretKeyEvents triggered the mach port setup;
        // this retry enters composition mode correctly.
        const array2 = objc.msgSend1(array_class, objc.sel("arrayWithObject:"), event);
        objc.msgSendVoid1(self_view, objc.sel("interpretKeyEvents:"), array2);
    }
}

/// Called when macOS input source changes (e.g., English → Korean via Cmd+Space)
fn inputSourceChanged(self_view: objc.id, _: objc.SEL, _: objc.id) callconv(.c) void {
    const input_ctx = objc.msgSend(self_view, objc.sel("inputContext"));
    if (@intFromPtr(input_ctx) != 0) {
        // Only discard if we actually have marked text.
        if (g_marked_len > 0) {
            objc.msgSendVoid(input_ctx, objc.sel("discardMarkedText"));
        }
        objc.msgSendVoid(input_ctx, objc.sel("invalidateCharacterCoordinates"));
    }
    g_marked_len = 0;
    g_preedit_len = 0;
    g_source_just_changed = true;
}

/// Register for input source change notifications (call after view is added to window)
pub fn registerInputSourceObserver(view: objc.id) void {
    const center = objc.msgSend(
        objc.getClass("NSDistributedNotificationCenter"),
        objc.sel("defaultCenter"),
    );
    if (@intFromPtr(center) == 0) return;

    const name = objc.nsString("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged");
    // addObserver:selector:name:object:
    objc.msgSendVoid4(
        center,
        objc.sel("addObserver:selector:name:object:"),
        view,
        objc.sel("inputSourceChanged:"),
        name,
        @as(?objc.id, null),
    );
}

fn flagsChanged(self_view: objc.id, _: objc.SEL, event: objc.id) callconv(.c) void {
    // Forward modifier changes to inputContext so it tracks input source switches
    // (e.g., Caps Lock toggles Korean/English on macOS Korean keyboard).
    const input_ctx = objc.msgSend(self_view, objc.sel("inputContext"));
    if (@intFromPtr(input_ctx) != 0) {
        _ = objc.msgSendBool1(input_ctx, objc.sel("handleEvent:"), event);
    }
}

// ---------------------------------------------------------------------------
// NSTextInputClient implementation — IME support
// ---------------------------------------------------------------------------

/// Returns true if the UTF-8 bytes encode a single Hangul Compatibility Jamo
/// (ㄱ-ㅎ U+3131..U+314E, ㅏ-ㅣ U+314F..U+3163) — characters that should be
/// composing but the IME incorrectly committed.
fn isHangulJamo(bytes: []const u8) bool {
    if (bytes.len != 3) return false;
    // Hangul Compatibility Jamo: U+3131..U+3163, UTF-8: E3 84 B1..E3 85 A3
    if (bytes[0] != 0xE3) return false;
    if (bytes[1] == 0x84 and bytes[2] >= 0xB1) return true; // U+3131..U+313F
    if (bytes[1] == 0x85 and bytes[2] <= 0xA3) return true; // U+3140..U+3163
    return false;
}

/// NSResponder's insertText: (1-arg version)
fn imeInsertTextSimple(_: objc.id, _: objc.SEL, text: objc.id) callconv(.c) void {
    const cb = g_input_callback orelse return;

    const str = getStringFromInput(text);
    if (@intFromPtr(str) == 0) return;

    const utf8 = objc.msgSend(str, objc.sel("UTF8String"));
    if (@intFromPtr(utf8) == 0) return;

    const cstr: [*:0]const u8 = @ptrCast(utf8);
    const len = std.mem.len(cstr);
    if (len == 0) return;

    // Workaround: if this is the first key after input source switch and the
    // text is a Hangul jamo, suppress it and request a replay. The first
    // interpretKeyEvents call triggered the mach port setup; the replay will
    // enter composition mode correctly.
    if (g_source_just_changed and isHangulJamo(cstr[0..len])) {
        g_source_just_changed = false;
        g_needs_replay = true;
        g_marked_len = 0;
        g_preedit_len = 0;
        return;
    }
    g_source_just_changed = false;
    g_marked_len = 0;
    g_preedit_len = 0;

    cb(cstr[0..len]);
}

/// Called when text input is finalized (e.g., after composing Korean characters)
fn imeInsertText(_: objc.id, _: objc.SEL, text: objc.id, _: NSRange) callconv(.c) void {
    const cb = g_input_callback orelse return;

    // Get the finalized text string
    const str = getStringFromInput(text);
    if (@intFromPtr(str) == 0) return;

    const utf8 = objc.msgSend(str, objc.sel("UTF8String"));
    if (@intFromPtr(utf8) == 0) return;

    const cstr: [*:0]const u8 = @ptrCast(utf8);
    const len = std.mem.len(cstr);
    if (len == 0) return;

    // Workaround for IMK mach port timing bug (same as insertTextSimple)
    if (g_source_just_changed and isHangulJamo(cstr[0..len])) {
        g_source_just_changed = false;
        g_needs_replay = true;
        g_marked_len = 0;
        g_preedit_len = 0;
        return;
    }
    g_source_just_changed = false;
    g_marked_len = 0;
    g_preedit_len = 0;

    cb(cstr[0..len]);
}

/// Called during text composition (e.g., typing Korean jamo that form a syllable).
/// Stores composing text for preedit rendering; does NOT send to PTY.
fn imeSetMarkedText(_: objc.id, _: objc.SEL, text: objc.id, _: NSRange, _: NSRange) callconv(.c) void {
    // If setMarkedText is called, composition started successfully — no replay needed.
    g_source_just_changed = false;
    const str = getStringFromInput(text);
    if (@intFromPtr(str) == 0) {
        g_marked_len = 0;
        g_preedit_len = 0;
        return;
    }
    g_marked_len = objc.msgSendUint(str, objc.sel("length"));

    // Store UTF-8 for preedit rendering
    const utf8 = objc.msgSend(str, objc.sel("UTF8String"));
    if (@intFromPtr(utf8) != 0) {
        const cstr: [*:0]const u8 = @ptrCast(utf8);
        const len = std.mem.len(cstr);
        const copy_len = @min(len, g_preedit_buf.len);
        @memcpy(g_preedit_buf[0..copy_len], cstr[0..copy_len]);
        g_preedit_len = copy_len;
    } else {
        g_preedit_len = 0;
    }
}

fn imeUnmarkText(_: objc.id, _: objc.SEL) callconv(.c) void {
    g_marked_len = 0;
    g_preedit_len = 0;
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
    // Return {0, 0} (empty selection at start) instead of NSNotFound.
    // Some IMEs (including Korean) expect a valid range here.
    return .{ .location = 0, .length = 0 };
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

pub const CGRect = extern struct {
    x: objc.CGFloat,
    y: objc.CGFloat,
    w: objc.CGFloat,
    h: objc.CGFloat,
};

fn imeFirstRect(_: objc.id, _: objc.SEL, _: NSRange, _: ?*NSRange) callconv(.c) CGRect {
    return g_ime_cursor_rect;
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
// Mouse events (selection)
// ---------------------------------------------------------------------------

fn getMousePixelPos(self_view: objc.id, event: objc.id) [2]i32 {
    // locationInWindow returns NSPoint in window coordinates (Y-up from bottom)
    const GetLoc = *const fn (objc.id, objc.SEL) callconv(.c) objc.NSPoint;
    const loc: objc.NSPoint = @as(GetLoc, @ptrCast(objc.msgSend_raw))(event, objc.sel("locationInWindow"));

    // Convert to view coordinates
    const ConvertPt = *const fn (objc.id, objc.SEL, objc.NSPoint, ?objc.id) callconv(.c) objc.NSPoint;
    const view_pt: objc.NSPoint = @as(ConvertPt, @ptrCast(objc.msgSend_raw))(self_view, objc.sel("convertPoint:fromView:"), loc, @as(?objc.id, null));

    // Get view height for Y-flip (NSView is Y-up, terminal is Y-down)
    const GetFrame = *const fn (objc.id, objc.SEL) callconv(.c) objc.NSRect;
    const frame: objc.NSRect = @as(GetFrame, @ptrCast(objc.msgSend_raw))(self_view, objc.sel("frame"));

    // Get backing scale factor from window
    const window = objc.msgSend(self_view, objc.sel("window"));
    var scale_factor: objc.CGFloat = 2.0;
    if (@intFromPtr(window) != 0) {
        const screen = objc.msgSend(window, objc.sel("screen"));
        if (@intFromPtr(screen) != 0) {
            scale_factor = objc.msgSendFloat(screen, objc.sel("backingScaleFactor"));
        }
    }

    // Convert to pixel coordinates (point × scale) with Y-flip
    const px_x: i32 = @intFromFloat(view_pt.x * scale_factor);
    const px_y: i32 = @intFromFloat((frame.size.height - view_pt.y) * scale_factor);
    return .{ px_x, px_y };
}

fn mouseDown(self_view: objc.id, _: objc.SEL, event: objc.id) callconv(.c) void {
    const mouse_cb = g_mouse_callback orelse return;
    const pos = getMousePixelPos(self_view, event);
    mouse_cb(.down, pos[0], pos[1]);
}

fn mouseDragged(self_view: objc.id, _: objc.SEL, event: objc.id) callconv(.c) void {
    const mouse_cb = g_mouse_callback orelse return;
    const pos = getMousePixelPos(self_view, event);
    mouse_cb(.dragged, pos[0], pos[1]);
}

fn mouseUp(self_view: objc.id, _: objc.SEL, event: objc.id) callconv(.c) void {
    const mouse_cb = g_mouse_callback orelse return;
    const pos = getMousePixelPos(self_view, event);
    mouse_cb(.up, pos[0], pos[1]);
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
