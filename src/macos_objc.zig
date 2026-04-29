// Minimal Objective-C runtime bindings for the macOS host.
//
// 패턴: 호출자가 매번 함수 시그니처를 정의해서 `objcSend(FnType)` 로 캐스트
// 한다. comptime 으로 시그니처를 합성하는 방식 (`msgSend(R, target, sel, args)`)
// 보다 callsite 가 길지만, 시그니처를 명시하므로 ABI 실수가 비교적 잘 드러난다.
// arm64 macOS 만 지원 — x86_64 의 stret variants 는 다루지 않는다.

const std = @import("std");

pub const Class = *opaque{};
pub const SEL = *opaque{};
pub const id = ?*opaque{};

pub extern fn objc_getClass(name: [*:0]const u8) ?Class;
pub extern fn sel_registerName(name: [*:0]const u8) SEL;
pub extern fn objc_msgSend() void;

/// 클래스 이름 → Class 포인터. 못 찾으면 panic — 우리가 쓰는 클래스는
/// AppKit / Metal 표준이라 부재시 link/loader 단계에서 잡혀야 정상.
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
