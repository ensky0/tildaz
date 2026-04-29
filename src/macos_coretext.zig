// CoreText / CoreGraphics / CoreFoundation 의 C API 선언 — Zig FFI.
// TildaZ 의 폰트 / 글리프 라스터화에 필요한 최소 부분만. #75 (claude/infallible-
// swartz) 패턴 그대로 차용.

// --- Core Foundation 타입 ---
pub const CFTypeRef = *anyopaque;
pub const CFStringRef = *anyopaque;
pub const CFAllocatorRef = ?*anyopaque;
pub const CFIndex = isize;
pub const CFStringEncoding = u32;
pub const Boolean = u8;

pub const CFRange = extern struct {
    location: CFIndex,
    length: CFIndex,
};

pub const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;

// --- CoreGraphics 타입 ---
pub const CGFloat = f64;
pub const CGGlyph = u16;

pub const CGPoint = extern struct {
    x: CGFloat,
    y: CGFloat,
};

pub const CGSize = extern struct {
    width: CGFloat,
    height: CGFloat,
};

pub const CGRect = extern struct {
    origin: CGPoint,
    size: CGSize,
};

pub const CGAffineTransform = extern struct {
    a: CGFloat,
    b: CGFloat,
    c: CGFloat,
    d: CGFloat,
    tx: CGFloat,
    ty: CGFloat,
};

pub const CGColorSpaceRef = *anyopaque;
pub const CGContextRef = *anyopaque;
pub const CGBitmapInfo = u32;

// CGBitmapInfo 플래그 (`CGImage.h`).
pub const kCGBitmapAlphaInfoMask: u32 = 0x1F;
pub const kCGImageAlphaNoneSkipLast: u32 = 5;
pub const kCGImageAlphaPremultipliedFirst: u32 = 2;
pub const kCGBitmapByteOrder32Host: u32 = 0;

// --- CoreText 타입 ---
pub const CTFontRef = *anyopaque;

// --- Core Foundation 함수 ---
pub extern "CoreFoundation" fn CFRelease(cf: CFTypeRef) void;

pub extern "CoreFoundation" fn CFStringCreateWithBytes(
    alloc: CFAllocatorRef,
    bytes: [*]const u8,
    numBytes: CFIndex,
    encoding: CFStringEncoding,
    isExternalRepresentation: Boolean,
) ?CFStringRef;

pub extern "CoreFoundation" fn CFStringCreateWithCharacters(
    alloc: CFAllocatorRef,
    chars: [*]const u16,
    numChars: CFIndex,
) ?CFStringRef;

// --- CoreText 함수 ---
pub extern "CoreText" fn CTFontCreateWithName(
    name: CFStringRef,
    size: CGFloat,
    matrix: ?*const CGAffineTransform,
) ?CTFontRef;

pub extern "CoreText" fn CTFontCreateForString(
    currentFont: CTFontRef,
    string: CFStringRef,
    range: CFRange,
) ?CTFontRef;

pub extern "CoreText" fn CTFontGetGlyphsForCharacters(
    font: CTFontRef,
    characters: [*]const u16,
    glyphs: [*]CGGlyph,
    count: CFIndex,
) bool;

pub extern "CoreText" fn CTFontGetAscent(font: CTFontRef) CGFloat;
pub extern "CoreText" fn CTFontGetDescent(font: CTFontRef) CGFloat;
pub extern "CoreText" fn CTFontGetLeading(font: CTFontRef) CGFloat;

pub extern "CoreText" fn CTFontGetAdvancesForGlyphs(
    font: CTFontRef,
    orientation: u32, // CTFontOrientation
    glyphs: [*]const CGGlyph,
    advances: ?[*]CGSize,
    count: CFIndex,
) CGFloat;

pub extern "CoreText" fn CTFontGetBoundingRectsForGlyphs(
    font: CTFontRef,
    orientation: u32,
    glyphs: [*]const CGGlyph,
    boundingRects: ?[*]CGRect,
    count: CFIndex,
) CGRect;

// CTFontOrientation
pub const kCTFontOrientationDefault: u32 = 0;
pub const kCTFontOrientationHorizontal: u32 = 1;

// --- CoreGraphics 함수 ---
pub extern "CoreGraphics" fn CGColorSpaceCreateDeviceGray() ?CGColorSpaceRef;
pub extern "CoreGraphics" fn CGColorSpaceCreateDeviceRGB() ?CGColorSpaceRef;
pub extern "CoreGraphics" fn CGColorSpaceRelease(space: CGColorSpaceRef) void;

pub extern "CoreGraphics" fn CGBitmapContextCreate(
    data: ?[*]u8,
    width: usize,
    height: usize,
    bitsPerComponent: usize,
    bytesPerRow: usize,
    space: CGColorSpaceRef,
    bitmapInfo: CGBitmapInfo,
) ?CGContextRef;

pub extern "CoreGraphics" fn CGContextRelease(ctx: CGContextRef) void;

pub extern "CoreGraphics" fn CGContextSetRGBFillColor(
    ctx: CGContextRef,
    red: CGFloat,
    green: CGFloat,
    blue: CGFloat,
    alpha: CGFloat,
) void;

pub extern "CoreGraphics" fn CGContextFillRect(ctx: CGContextRef, rect: CGRect) void;

pub extern "CoreGraphics" fn CGContextSetShouldAntialias(ctx: CGContextRef, shouldAntialias: bool) void;
pub extern "CoreGraphics" fn CGContextSetShouldSmoothFonts(ctx: CGContextRef, shouldSmoothFonts: bool) void;
pub extern "CoreGraphics" fn CGContextSetAllowsFontSmoothing(ctx: CGContextRef, allowsFontSmoothing: bool) void;
pub extern "CoreGraphics" fn CGContextSetAllowsAntialiasing(ctx: CGContextRef, allowsAntialiasing: bool) void;

// CTFontDrawGlyphs — CGContext 에 글리프 렌더.
pub extern "CoreText" fn CTFontDrawGlyphs(
    font: CTFontRef,
    glyphs: [*]const CGGlyph,
    positions: [*]const CGPoint,
    count: usize,
    context: CGContextRef,
) void;
