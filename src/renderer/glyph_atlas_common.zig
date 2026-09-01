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

/// cluster cache key — 글리프 여러 개를 한 비트맵으로 합성하는 cluster 용.
///
/// **`GlyphKey` 와 반드시 다른 맵에 산다** ([#529](https://github.com/ensky0/tildaz/issues/529)).
/// 한 맵을 나눠 쓰면 cluster 해시가 *진짜* glyph index 와 겹쳐 남의 그림이 나온다 — macOS 가
/// 64비트 해시를 `u16` 으로 잘라 같은 맵에 넣다가 실측으로 걸렸다 (같은 화면 200 회 중 21 회
/// 겹침, 실기에서 `a̸` 자리에 `U` 가 그려졌다). 그래서 해시를 **자르지 않고** (`u64`) 맵도 따로 둔다.
///
/// **폰트를 함께 본다 (#401).** glyph index 는 폰트 안에서만 뜻이 있어서 `Cascadia Code` 의
/// 3054 번과 `Segoe UI Symbol` 의 3054 번은 전혀 다른 글리프다. 예전에는 인덱스 해시만 키로
/// 썼는데, cluster 경로에 컬러 emoji 만 들어오던 동안에는 face 가 사실상 하나라 드러나지
/// 않다가 결합 기호까지 이 경로를 타면서 mono face 여럿이 같은 캐시를 공유하게 됐다.
///
/// miss 걱정은 없다 — cluster 캐시가 폰트를 **소유한 채 재사용**하므로 같은 cluster 에 대해
/// 포인터가 안정적이다 (#578 뒤로도 캐시가 자기 몫을 들고 있다).
pub const ClusterKey = struct {
    font_ptr: usize,
    /// 자르지 않는다 — 자르면 `GlyphKey.index` 대역과 겹칠 여지가 생긴다 (#529).
    indices_hash: u64,
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
