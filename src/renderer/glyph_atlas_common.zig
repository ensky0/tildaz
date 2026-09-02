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

/// glyph cache key — 폰트 **id** + glyph index.
///
/// **주소를 쓰면 안 된다** ([#584](https://github.com/ensky0/tildaz/issues/584)). 예전 주석은
/// *"단일 글리프 경로는 chain 폰트만 쓰므로 객체가 재사용된다"* 고 적었는데 **틀렸다.**
///
/// - **macOS 는 codepoint 캐시가 없다.** chain 에 없는 글리프는 셀마다 `CTFontCreateForString`
///   으로 **새 객체**를 받는다. 다국어 화면 (cluster 7,560 종) 실측에서 이 맵의 서로 다른
///   폰트 주소가 **256 개를 넘었다** (실제 폰트는 32 종). 그 중복이 atlas 를 부풀려 프레임마다
///   차게 만들고, 화면이 흐르듯 무너졌다.
/// - **cluster 가 글리프 하나로 합성되면 이 키로 온다** (`getOrInsertCluster` 의 `len == 1`
///   분기). 그 폰트는 cluster 경로의 OS fallback 이라 주소가 더 불안정하다.
/// 탭바 아이콘 (`+` · `×` · `⋯`) 이 `GlyphKey.font_id` 에 쓰는 **예약값**.
///
/// 아이콘은 폰트에서 온 글리프가 아니라 코드로 그리는 그림이라 폰트 id 가 없다. 예전에는
/// 주소 자리에 `0` 을 넣었는데, `fontId` 는 **이름을 못 읽으면 0** 을 내므로 그대로 두면
/// 이름 없는 폰트의 글리프와 한 키 공간을 나눠 쓴다 — index 대역이 겹치면 남의 그림이 나온다
/// ([#529](https://github.com/ensky0/tildaz/issues/529) 가 그 종류였다). 그래서 폰트 이름
/// 해시가 닿을 일이 없는 값을 예약한다.
pub const ICON_FONT_ID: u64 = 0xFFFF_FFFF_FFFF_FFFF;

pub const GlyphKey = struct {
    /// `fontId(PostScript 이름)`. 아래 `ClusterKey.font_id` 와 같은 값을 쓴다.
    font_id: u64,
    index: u16,
};

/// 폰트를 가리키는 **안정된 id** — PostScript 이름의 FNV-1a 64bit 해시다.
///
/// **왜 주소가 아닌가** ([#584](https://github.com/ensky0/tildaz/issues/584)). macOS CoreText 는
/// 같은 폰트에 CTLine 마다 **새 객체**를 준다 — 실측에서 같은 `Monaco` 가 주소 **50 개**로
/// 갈렸다 (640 바이트 간격으로 순차 할당). 주소를 키에 실으면 같은 그림이 주소마다 새로
/// 담겨 atlas 가 몇 배로 찬다 (2,816 종 화면이 5,600 항목을 썼다 — 정확히 2 배).
///
/// **왜 family 이름이 아니라 PostScript 이름인가.** `Menlo-Bold` 와 `Menlo-Regular` 는 family
/// 가 둘 다 `"Menlo"` 다. family 로 묶으면 굵기가 다른 그림이 한 칸을 나눠 써
/// [#529](https://github.com/ensky0/tildaz/issues/529) 가 다시 난다.
///
/// **왜 레지스트리가 아니라 해시인가.** 이름 → id 표를 두면 상한과 초과 처리가 생긴다.
/// 해시는 상태가 없고 상한도 없다. 폰트 이름은 많아도 수십 개라 64bit 충돌은 무시할 수 있고,
/// 키에는 `indices_hash` 가 함께 실려 이중이다.
///
/// **한계** — variable font 의 인스턴스는 PostScript 이름이 같을 수 있어, 그림이 달라도 같은
/// id 가 된다. 지금 chain 에 그런 폰트를 쓰는 경로는 없다.
pub fn fontId(ps_name: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325; // FNV-1a 64-bit offset basis
    for (ps_name) |b| {
        h ^= @as(u64, b);
        h *%= 0x100000001b3;
    }
    return h;
}

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
/// **폰트는 주소가 아니라 `fontId` 로 식별한다** ([#584](https://github.com/ensky0/tildaz/issues/584)).
/// 예전 주석은 *"cluster 캐시가 폰트를 소유한 채 재사용하므로 포인터가 안정적이다"* 라고
/// 적었는데 **실측으로 반증됐다** — shape 결과 캐시 (`cluster_cache.CAPACITY` = 2048) 가 넘치면
/// 통째로 비워지고, 다시 shape 할 때 CoreText 가 새 폰트 객체를 준다. 한 화면이 그 상한을
/// 넘으면 매 프레임 그 일이 일어난다.
pub const ClusterKey = struct {
    /// `fontId(PostScript 이름)`. 주소를 넣지 않는다 — 위 설명을 본다.
    font_id: u64,
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

const std = @import("std");

test "fontId — 같은 이름은 같은 id, 다른 이름은 다른 id" {
    try std.testing.expectEqual(fontId("Menlo-Regular"), fontId("Menlo-Regular"));
    try std.testing.expect(fontId("Menlo-Regular") != fontId("Menlo-Bold"));
    try std.testing.expect(fontId("Menlo-Regular") != fontId("Monaco"));
}

test "fontId — 굵기가 다른 face 가 갈린다 (#529 가 다시 나지 않게)" {
    // family 이름으로 묶으면 둘 다 "Menlo" 라 한 칸을 나눠 쓴다. PostScript 이름은 갈린다.
    const regular = fontId("Menlo-Regular");
    const bold = fontId("Menlo-Bold");
    const italic = fontId("Menlo-Italic");
    try std.testing.expect(regular != bold);
    try std.testing.expect(regular != italic);
    try std.testing.expect(bold != italic);
}

test "fontId — 빈 이름도 값을 낸다 (이름을 못 읽은 경우)" {
    // 이름 조회가 실패하면 호출자가 빈 슬라이스를 넘긴다. 그때도 한 id 로 모여야 한다 —
    // 그림이 섞일 수 있지만 atlas 를 부풀리지는 않는다.
    try std.testing.expectEqual(fontId(""), fontId(""));
    try std.testing.expect(fontId("") != fontId("Menlo-Regular"));
}

test "ClusterKey — 폰트만 다르면 다른 키다" {
    const a = ClusterKey{ .font_id = fontId("Menlo-Regular"), .indices_hash = 0x1234 };
    const b = ClusterKey{ .font_id = fontId("Monaco"), .indices_hash = 0x1234 };
    try std.testing.expect(!std.meta.eql(a, b));
}
