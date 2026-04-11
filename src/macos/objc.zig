// Minimal Objective-C runtime bindings for Zig (ARM64 macOS).
// On ARM64, objc_msgSend handles all return types directly.

const std = @import("std");

pub const id = *anyopaque;
pub const Class = *anyopaque;
pub const SEL = *anyopaque;
pub const NSUInteger = usize;
pub const NSInteger = isize;
pub const CGFloat = f64;
pub const BOOL = i8;
pub const YES: BOOL = 1;
pub const NO: BOOL = 0;

pub const NSRect = extern struct {
    origin: NSPoint,
    size: NSSize,
};

pub const NSPoint = extern struct {
    x: CGFloat,
    y: CGFloat,
};

pub const NSSize = extern struct {
    width: CGFloat,
    height: CGFloat,
};

// --- ObjC runtime C API ---
extern "objc" fn objc_getClass(name: [*:0]const u8) ?Class;
extern "objc" fn sel_registerName(name: [*:0]const u8) SEL;
extern "objc" fn objc_msgSend() callconv(.c) void;
extern "objc" fn objc_msgSendSuper() callconv(.c) void;

pub const ObjcSuper = extern struct {
    receiver: id,
    super_class: Class,
};

pub const msgSendSuper_raw = &objc_msgSendSuper;
extern "objc" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra_bytes: usize) ?Class;
extern "objc" fn objc_registerClassPair(cls: Class) void;
extern "objc" fn class_addMethod(cls: Class, name: SEL, imp: *const anyopaque, types: [*:0]const u8) bool;
pub extern "objc" fn objc_getProtocol(name: [*:0]const u8) ?*anyopaque;
pub extern "objc" fn class_addProtocol(cls: Class, protocol: *anyopaque) bool;
extern "objc" fn object_setInstanceVariable(obj: id, name: [*:0]const u8, value: ?*anyopaque) *anyopaque;
extern "objc" fn object_getInstanceVariable(obj: id, name: [*:0]const u8, out: *?*anyopaque) *anyopaque;

/// Raw pointer to objc_msgSend for custom @ptrCast calls.
/// Use this when you need a non-standard signature (struct args, etc.)
pub const msgSend_raw = &objc_msgSend;

pub fn getClass(name: [*:0]const u8) Class {
    return objc_getClass(name) orelse @panic("ObjC class not found");
}

pub fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}


// --- Message sending (type-safe wrappers via @ptrCast on ARM64) ---

/// Send message returning object (id)
pub fn msgSend(target: anytype, s: SEL) id {
    const f: *const fn (@TypeOf(target), SEL) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(target, s);
}

/// Send message with 1 id arg, returning id
pub fn msgSend1(target: anytype, s: SEL, a1: anytype) id {
    const f: *const fn (@TypeOf(target), SEL, @TypeOf(a1)) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(target, s, a1);
}

/// Send message with 2 args, returning id
pub fn msgSend2(target: anytype, s: SEL, a1: anytype, a2: anytype) id {
    const f: *const fn (@TypeOf(target), SEL, @TypeOf(a1), @TypeOf(a2)) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(target, s, a1, a2);
}

/// Send message with 3 args, returning id
pub fn msgSend3(target: anytype, s: SEL, a1: anytype, a2: anytype, a3: anytype) id {
    const f: *const fn (@TypeOf(target), SEL, @TypeOf(a1), @TypeOf(a2), @TypeOf(a3)) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(target, s, a1, a2, a3);
}

/// Send message with 4 args, returning id
pub fn msgSend4(target: anytype, s: SEL, a1: anytype, a2: anytype, a3: anytype, a4: anytype) id {
    const f: *const fn (@TypeOf(target), SEL, @TypeOf(a1), @TypeOf(a2), @TypeOf(a3), @TypeOf(a4)) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(target, s, a1, a2, a3, a4);
}

/// Send message returning void
pub fn msgSendVoid(target: anytype, s: SEL) void {
    const f: *const fn (@TypeOf(target), SEL) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(target, s);
}

/// Send message with 1 arg, returning void
pub fn msgSendVoid1(target: anytype, s: SEL, a1: anytype) void {
    const f: *const fn (@TypeOf(target), SEL, @TypeOf(a1)) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(target, s, a1);
}

/// Send message with 2 args, returning void
pub fn msgSendVoid2(target: anytype, s: SEL, a1: anytype, a2: anytype) void {
    const f: *const fn (@TypeOf(target), SEL, @TypeOf(a1), @TypeOf(a2)) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(target, s, a1, a2);
}

/// Send message with 3 args, returning void
pub fn msgSendVoid3(target: anytype, s: SEL, a1: anytype, a2: anytype, a3: anytype) void {
    const f: *const fn (@TypeOf(target), SEL, @TypeOf(a1), @TypeOf(a2), @TypeOf(a3)) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(target, s, a1, a2, a3);
}

/// Send message with 4 args, returning void
pub fn msgSendVoid4(target: anytype, s: SEL, a1: anytype, a2: anytype, a3: anytype, a4: anytype) void {
    const f: *const fn (@TypeOf(target), SEL, @TypeOf(a1), @TypeOf(a2), @TypeOf(a3), @TypeOf(a4)) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(target, s, a1, a2, a3, a4);
}

/// Send message returning BOOL
pub fn msgSendBool(target: anytype, s: SEL) bool {
    const f: *const fn (@TypeOf(target), SEL) callconv(.c) BOOL = @ptrCast(&objc_msgSend);
    return f(target, s) != 0;
}

/// Send message returning NSUInteger
pub fn msgSendUint(target: anytype, s: SEL) NSUInteger {
    const f: *const fn (@TypeOf(target), SEL) callconv(.c) NSUInteger = @ptrCast(&objc_msgSend);
    return f(target, s);
}

/// Send message returning CGFloat
pub fn msgSendFloat(target: anytype, s: SEL) CGFloat {
    const f: *const fn (@TypeOf(target), SEL) callconv(.c) CGFloat = @ptrCast(&objc_msgSend);
    return f(target, s);
}

// --- NSString helper ---

pub fn nsString(comptime str: [:0]const u8) id {
    const cls = getClass("NSString");
    return msgSend1(
        cls,
        sel("stringWithUTF8String:"),
        @as([*:0]const u8, str.ptr),
    );
}

pub fn nsStringRuntime(str: [*:0]const u8) id {
    const cls = getClass("NSString");
    return msgSend1(cls, sel("stringWithUTF8String:"), str);
}

/// Send message with 1 arg, returning BOOL
pub fn msgSendBool1(target: anytype, s: SEL, a1: anytype) bool {
    const f: *const fn (@TypeOf(target), SEL, @TypeOf(a1)) callconv(.c) BOOL = @ptrCast(&objc_msgSend);
    return f(target, s, a1) != 0;
}

// --- Runtime class creation ---

/// Create a new ObjC class at runtime (subclass of given superclass).
pub fn createClass(name: [*:0]const u8, superclass_name: [*:0]const u8) ?Class {
    const super = objc_getClass(superclass_name) orelse return null;
    return objc_allocateClassPair(super, name, 0);
}

/// Register a class created with createClass.
pub fn registerClass(cls: Class) void {
    objc_registerClassPair(cls);
}

/// Add a method to an ObjC class. `imp` should be a C-callable function pointer.
/// `types` is the ObjC type encoding string (e.g., "v@:" for void method with no extra args).
pub fn addMethod(cls: Class, name: SEL, imp: *const anyopaque, types: [*:0]const u8) bool {
    return class_addMethod(cls, name, imp, types);
}

// --- Metal C function ---
// MTLCreateSystemDefaultDevice is a plain C function in Metal framework
pub extern "Metal" fn MTLCreateSystemDefaultDevice() ?id;
