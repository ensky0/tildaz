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
pub const kCGImageAlphaOnly: u32 = 7;
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

/// 폰트의 실제 family name 반환. `CTFontCreateWithName` 이 lookup 실패 시 system
/// substitute (대개 `.SF NS Mono`) 를 반환해도 family name 은 그대로 보고하므로
/// 우리가 요청한 이름과 비교해 substitute 인지 판별 가능.
pub extern "CoreText" fn CTFontCopyFamilyName(font: CTFontRef) CFStringRef;

/// CFString 비교. 0 = equal, -1/1 = less/greater. compareOptions = 0 = literal binary 비교.
pub extern "CoreFoundation" fn CFStringCompare(
    theString1: CFStringRef,
    theString2: CFStringRef,
    compareOptions: u32,
) i32;

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
// 대문자 글자의 visible top 까지 거리 (baseline 부터). ascent 보다 작아서
// (ascent - cap_height) 가 폰트의 위쪽 internal leading.
pub extern "CoreText" fn CTFontGetCapHeight(font: CTFontRef) CGFloat;

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
    // alpha-only (`kCGImageAlphaOnly`) 포맷에서는 colorspace 가 null 이어야
    // 한다 — non-null 넘기면 CG 가 다른 포맷으로 reinterpret 해서 픽셀 데이터
    // 가 깨진다 (#75 댓글 6 의 정정 사항).
    space: ?CGColorSpaceRef,
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

// alpha-only 컨텍스트에는 grayscale + alpha 만 의미있음. RGB fill color 호출은
// CG 가 무시 또는 잘못된 값으로 처리할 수 있어 grayscale 전용 API 사용.
pub extern "CoreGraphics" fn CGContextSetGrayFillColor(
    ctx: CGContextRef,
    gray: CGFloat,
    alpha: CGFloat,
) void;

// CTM (current transformation matrix) scale — bitmap 이 pixel-sized 인데
// CTFontDrawGlyphs 는 point 좌표로 그리는 mismatch 를 보정. Retina scale 을
// CTM 에 곱해 둬야 글리프가 비트맵 가득 차게 그려진다.
pub extern "CoreGraphics" fn CGContextScaleCTM(
    ctx: CGContextRef,
    sx: CGFloat,
    sy: CGFloat,
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
