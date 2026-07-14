//! #282 G5 — macOS / Windows glyph atlas 의 공통 데이터 타입 + packing 알고리즘.
//! 두 renderer 의 atlas 는 픽셀 포맷(BGRA premult vs ClearType)·업로드 경로가
//! 달라 전체를 합치진 않지만, cache entry 구조와 row-based packing 은 라인 단위
//! 동일했다. 그 공통분만 여기로 모은다 (per-OS 파일은 이 타입/함수를 사용).

/// atlas cache entry — 글리프의 atlas 내 위치·크기·bearing·색 여부·advance.
pub const AtlasEntry = struct {
    x: u16, // atlas 내 위치 (pixel).
    y: u16,
    w: u16, // 글리프 크기 (pixel).
    h: u16,
    bearing_x: i16, // cell origin 에서 글리프 좌상단까지 offset.
    bearing_y: i16,
    /// 컬러 글리프(emoji 등) 여부. true 면 셰이더가 fg 를 곱하지 않고 atlas 를
    /// 그대로 출력 (macOS: SBIX/COLR premult, Windows: depremult RGB + A mask).
    is_color: bool = false,
    /// 글리프 advance (물리 px, retina/DPI scale 반영). wide 글리프(한글/CJK/
    /// emoji)를 배정된 셀 영역 가운데 정렬할 때 사용 (#299 — Linux 와 동일 정책).
    advance: f32 = 0,
};

/// glyph cache key — 폰트 객체 포인터 값(라이프타임 동안 stable 가정) + glyph
/// index. macOS 는 CTFontRef, Windows 는 IDWriteFontFace 포인터.
pub const GlyphKey = struct {
    font_ptr: usize,
    index: u16,
};

/// 단순 row-based atlas packing. cursor / row_height 상태를 포인터로 받아
/// 갱신하고 배치 좌표 (x, y) 를 반환. 현재 row 에 안 들어가면 다음 row 로,
/// atlas 가 가득 차면 null (caller 가 reset 후 재시도).
pub fn packRow(cursor_x: *u32, cursor_y: *u32, row_height: *u32, atlas_size: u32, w: u32, h: u32) ?[2]u32 {
    const pad = 1; // 글리프 간 1px padding.

    if (cursor_x.* + w + pad > atlas_size) {
        cursor_x.* = 0;
        cursor_y.* += row_height.* + pad;
        row_height.* = 0;
    }

    if (cursor_y.* + h > atlas_size) return null;

    const x = cursor_x.*;
    const y = cursor_y.*;
    cursor_x.* += w + pad;
    if (h > row_height.*) row_height.* = h;

    return .{ x, y };
}
