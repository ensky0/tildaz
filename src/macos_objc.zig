// Minimal Objective-C runtime bindings for the macOS host.
//
// 두 가지 패턴 같이 제공:
//
//   1. `objcSend(FnType)` — callsite 가 함수 시그니처를 명시. ABI 실수 시
//      컴파일러가 잡아 주지만 호출 코드가 길어진다. M3 host 코드 (NSApp /
//      NSWindow / mainMenu) 가 이 패턴 사용.
//
//   2. `msgSend` / `msgSend1` / `msgSendVoid` / ... — 흔한 시그니처를 미리
//      만들어 둔 helper. callsite 가 짧지만 ABI 가 helper 시그니처에 맞게
//      자동 추론. Metal 렌더러처럼 ObjC 호출이 많은 코드에 사용. 비표준
//      시그니처 (struct by-value 인자 등) 는 `msgSend_raw` 로 직접 cast.
//
// arm64 macOS 만 지원 — x86_64 의 stret variants 는 다루지 않는다.

const std = @import("std");

pub const Class = *opaque{};
pub const SEL = *opaque{};
pub const id = ?*opaque{};

// Cocoa 표준 타입 별칭 (Apple 의 Foundation/MacTypes 헤더와 같은 의미).
pub const NSUInteger = usize;
pub const NSInteger = isize;
pub const BOOL = bool;
pub const YES: BOOL = true;
pub const NO: BOOL = false;

pub extern fn objc_getClass(name: [*:0]const u8) ?Class;
pub extern fn sel_registerName(name: [*:0]const u8) SEL;
pub extern fn objc_msgSend() void;

// 동적 클래스 등록 — NSWindow / NSView subclass 만들어 method override 할 때.
// `types` 는 method signature (e.g. "B@:" = bool method 인자 없음).
pub extern fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra: usize) ?Class;
pub extern fn class_addMethod(cls: Class, sel_: SEL, imp: *const anyopaque, types: [*:0]const u8) bool;
pub extern fn objc_registerClassPair(cls: Class) void;

// Protocol — IME (NSTextInputClient) 같은 Objective-C protocol 을 동적 등록한
// 클래스에 채택시킬 때.
pub const Protocol = *anyopaque;
pub extern fn objc_getProtocol(name: [*:0]const u8) ?Protocol;
pub extern fn class_addProtocol(cls: Class, protocol: Protocol) bool;

/// `objc_msgSend` 의 raw 함수 포인터. 표준 helper 들 (msgSend, msgSendVoid,
/// ...) 이 처리 못 하는 시그니처 (예: struct by value, double 반환) 는
/// callsite 가 직접 `@ptrCast(macos_objc.msgSend_raw)` 로 cast 해서 쓴다.
pub const msgSend_raw = &objc_msgSend;

/// 클래스 이름 → Class 포인터. 못 찾으면 panic — 우리가 쓰는 클래스는
/// AppKit / Metal 표준이라 부재 시 link / loader 단계에서 잡혀야 정상.
pub fn getClass(name: [*:0]const u8) Class {
    return objc_getClass(name) orelse {
        std.debug.print("objc class not found: {s}\n", .{name});
        std.process.exit(1);
    };
}

pub fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

/// `objc_msgSend` 를 callsite 의 함수 타입으로 캐스트한 포인터를 돌려준다.
/// 사용 예:
///     const Send = fn (Class, SEL) callconv(.c) id;
///     const app = objcSend(Send)(getClass("NSApplication"), sel("sharedApplication"));
pub fn objcSend(comptime FnType: type) *const FnType {
    return @ptrCast(&objc_msgSend);
}

// =============================================================================
// 흔한 시그니처용 helper — Metal 렌더러처럼 ObjC 호출이 많은 코드에서 사용.
// 모두 `id` (= `?*opaque`) 를 nullable 로 다룬다. caller 가 NULL 검사 책임.
// =============================================================================

/// `[target sel]` (인자 없음, return id).
pub fn msgSend(target: anytype, s: SEL) id {
    const f: *const fn (@TypeOf(target), SEL) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(target, s);
}

/// `[target sel:a1]` (인자 1개, return id).
pub fn msgSend1(target: anytype, s: SEL, a1: anytype) id {
    const f: *const fn (@TypeOf(target), SEL, @TypeOf(a1)) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(target, s, a1);
}

pub fn msgSend2(target: anytype, s: SEL, a1: anytype, a2: anytype) id {
    const f: *const fn (@TypeOf(target), SEL, @TypeOf(a1), @TypeOf(a2)) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(target, s, a1, a2);
}

pub fn msgSend3(target: anytype, s: SEL, a1: anytype, a2: anytype, a3: anytype) id {
    const f: *const fn (@TypeOf(target), SEL, @TypeOf(a1), @TypeOf(a2), @TypeOf(a3)) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(target, s, a1, a2, a3);
}

pub fn msgSendVoid(target: anytype, s: SEL) void {
    const f: *const fn (@TypeOf(target), SEL) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(target, s);
}

pub fn msgSendVoid1(target: anytype, s: SEL, a1: anytype) void {
    const f: *const fn (@TypeOf(target), SEL, @TypeOf(a1)) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(target, s, a1);
}

pub fn msgSendVoid2(target: anytype, s: SEL, a1: anytype, a2: anytype) void {
    const f: *const fn (@TypeOf(target), SEL, @TypeOf(a1), @TypeOf(a2)) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(target, s, a1, a2);
}

pub fn msgSendVoid3(target: anytype, s: SEL, a1: anytype, a2: anytype, a3: anytype) void {
    const f: *const fn (@TypeOf(target), SEL, @TypeOf(a1), @TypeOf(a2), @TypeOf(a3)) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(target, s, a1, a2, a3);
}

pub fn msgSendVoid4(target: anytype, s: SEL, a1: anytype, a2: anytype, a3: anytype, a4: anytype) void {
    const f: *const fn (@TypeOf(target), SEL, @TypeOf(a1), @TypeOf(a2), @TypeOf(a3), @TypeOf(a4)) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(target, s, a1, a2, a3, a4);
}

/// UTF-8 string literal → autoreleased NSString. NSApp.run 의 lifetime 동안
/// 살아있으므로 별도 retain 불필요.
pub fn nsString(s: [:0]const u8) id {
    const NSString = getClass("NSString");
    const f: *const fn (Class, SEL, [*:0]const u8) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(NSString, sel("stringWithUTF8String:"), s.ptr);
}
