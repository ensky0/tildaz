// 글리프 텍스처 아틀라스 — CoreText 로 글리프 라스터 + 2D atlas (BGRA8) 에 캐시.
// macOS Mojave 이후 subpixel/ClearType 미지원이라 일반 텍스트는 grayscale alpha
// 로 충분하지만, Apple Color Emoji (SBIX) 같은 컬러 글리프는 BGRA premultiplied
// 비트맵이 필요해 atlas 자체를 BGRA8 로 통일 (#132). Metal 텍스처는 BGRA8Unorm.
//
// 라스터 path 단일화: 모든 글리프를 RGBA premultiplied + 흰색 fill 로 그림.
// - 일반 글리프: antialiased 흰색 → atlas 픽셀 = (a, a, a, a). 셰이더가 fg 와 곱해 tint.
// - 컬러 글리프 (CTFontGetSymbolicTraits & kCTFontTraitColorGlyphs): SBIX bitmap
//   이 fill 색깔 무시하고 그대로 합성 → atlas 픽셀 = 본래 색 premultiplied. 셰이더
//   는 fg 무시하고 atlas 그대로 출력.
// AtlasEntry.is_color 가 셰이더 path 결정 — TextInstance 의 color_flag 로 전달.
//
// #75 (claude/infallible-swartz) 패턴 + #132 컬러 emoji 확장.

const std = @import("std");
const ct = @import("../../font/macos/coretext.zig");
const tab_icons = @import("../../tab_icons.zig");
const atlas_common = @import("../glyph_atlas_common.zig");
const log = @import("../../log.zig");

/// atlas 텍스처의 **처음** 한 변 (px). 차면 `grow` 가 두 배로 키운다 (#584 ②).
pub const INITIAL_ATLAS_SIZE: u32 = atlas_common.INITIAL_ATLAS_SIZE;

/// 키울 수 있는 상한. Metal 의 텍스처 상한은 기종에 따라 16384 이지만, 8192² 는 이미
/// **256 MB** (BGRA8) 라 그 위로 가면 메모리가 화면 이득을 넘는다. 여기 닿으면 더 키우지
/// 않고 ① 안전망 (찬 것을 표시하고 호출자가 flush → 비우기 → 재시도) 으로 물러선다.
pub const MAX_ATLAS_SIZE: u32 = atlas_common.MAX_ATLAS_SIZE;

// #282 G5 — AtlasEntry / GlyphKey / packing 은 Windows atlas 와 공통(라인 동일).
pub const AtlasEntry = atlas_common.AtlasEntry;
const GlyphKey = atlas_common.GlyphKey;
/// #529 — cluster 는 **일반 글리프와 다른 맵**에 산다. 근거는 공용 파일의 정의에 있다.
const ClusterKey = atlas_common.ClusterKey;

pub const GlyphAtlas = struct {
    alloc: std.mem.Allocator,
    /// 단일 글리프 + 탭 아이콘. 키가 **진짜 glyph index** 다.
    cache: std.AutoHashMap(GlyphKey, AtlasEntry),
    /// 여러 글리프를 합성한 cluster (#401). **위 맵과 반드시 갈라 둔다** (#529) —
    /// 한 맵을 쓰면 cluster 해시가 진짜 glyph index 와 겹쳐 남의 그림이 나온다.
    cluster_cache: std.AutoHashMap(ClusterKey, AtlasEntry),

    /// 지금 atlas 한 변 (px). `grow` 가 두 배로 키운다 (#584 ②) — ghostty 가 쓰는 방식이다
    /// (`font.Atlas.grow` + `syncAtlasTexture`). 비우고 재사용하는 것보다 나은 이유는
    /// **프레임 중간에 비우는 상황 자체가 없어지기** 때문이다. 이미 emit 한 인스턴스의 UV 가
    /// 무효화될 일이 없다.
    ///
    /// #604 — 패킹 상태 + 지금 크기 (`size`). 세 platform 공통 (`atlas_common.Packer`).
    pack: atlas_common.Packer = .{},

    // 라스터 시 사용할 폰트 메트릭.
    font_size: f32,
    scale: f32, // Retina backing scale (1.0 / 2.0).
    /// #421 — primary 폰트의 ascent (pt). 위 결합 기호를 여기에 맞춰 높이를 고른다.
    /// renderer 가 폰트 컨텍스트를 만든 뒤 채운다. 0 이면 그 보정을 건너뛴다.
    ascent_pt: f32 = 0,

    // 아틀라스 픽셀 데이터 (BGRA8 — 4 bytes per pixel, premultiplied alpha).
    // 일반 글리프는 (a, a, a, a) (흰색 premult), 컬러 글리프는 (B*a, G*a, R*a, a).
    pixels: []u8,

    /// #584 ① — 프레임 중간에 자리를 못 잡았다. **그 자리에서 비우지 않는다** — 호출자가
    /// 이미 그린 것을 flush 하고 텍스처를 올린 뒤 비우고 재시도한다 (SPEC §12.6). 예전에는
    /// 여기서 바로 `reset` 을 불러 **앞서 emit 한 인스턴스의 UV 가 빈 자리를 가리켰다.**
    is_full: bool = false,
    /// #584 — 어느 라스터 경로에서 찼는지 (`icon` · `cluster` · `glyph`). 호출자가 비울 때
    /// 로그에 실어 어느 쪽이 용량을 먹는지 가른다.
    full_kind: []const u8 = "unknown",

    /// #584 ② — 두 배로 키운 횟수. 이 값이 늘면 `INITIAL_ATLAS_SIZE` 를 올릴 근거다.
    grows: u32 = 0,

    /// 가득 차서 통째로 비운 횟수. **scale 변경으로 부르는 `reset` 은 세지 않는다** —
    /// 그쪽은 정상 동작이다. 이 값이 프레임마다 늘면 한 화면이 요구하는 글리프가 용량을
    /// 넘었다는 뜻이다 ([#584](https://github.com/ensky0/tildaz/issues/584)).
    resets: u32 = 0,

    // Metal 업로드를 위한 dirty 영역 트래킹.
    dirty: bool = false,
    dirty_min_y: u32 = INITIAL_ATLAS_SIZE,
    dirty_max_y: u32 = 0,

    // 글리프 라스터 임시 버퍼 (RGBA premultiplied, max 256x256).
    temp_buf: []u8,

    pub fn init(
        alloc: std.mem.Allocator,
        font_size: f32,
        scale: f32,
    ) !GlyphAtlas {
        // BGRA8 = 4 bytes per pixel.
        const pixels = try alloc.alloc(u8, INITIAL_ATLAS_SIZE * INITIAL_ATLAS_SIZE * 4);
        @memset(pixels, 0);

        const temp_buf = try alloc.alloc(u8, 256 * 256 * 4);

        return .{
            .alloc = alloc,
            .cache = std.AutoHashMap(GlyphKey, AtlasEntry).init(alloc),
            .cluster_cache = std.AutoHashMap(ClusterKey, AtlasEntry).init(alloc),
            .font_size = font_size,
            .scale = scale,
            .pixels = pixels,
            .temp_buf = temp_buf,
        };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        self.alloc.free(self.temp_buf);
        self.alloc.free(self.pixels);
        self.cache.deinit();
        self.cluster_cache.deinit();
    }

    /// 글리프 lookup or rasterize. 라스터 실패 시 null.
    pub fn getOrInsert(
        self: *GlyphAtlas,
        font: ct.CTFontRef,
        /// #584 — 폰트를 가리키는 **안정된 id** (`atlas_common.fontId`). 주소를 쓰면 macOS 는
        /// codepoint 캐시가 없어 같은 글리프가 셀마다 새 키로 담긴다.
        font_id: u64,
        glyph_index: ct.CGGlyph,
    ) ?AtlasEntry {
        const key = GlyphKey{ .font_id = font_id, .index = glyph_index };
        if (self.cache.get(key)) |entry| return entry;

        const entry = self.rasterize(font, glyph_index) orelse return null;
        self.cache.put(key, entry) catch return null;
        return entry;
    }

    /// #401 — **cluster 가 글리프 여러 개일 때 하나의 비트맵으로 합성**한다.
    ///
    /// Apple Color Emoji 는 `👨‍❤️‍👨` 같은 `❤️` 조합을 글리프 2 개로 준다 (`👨‍👩‍👧` 는 1 개다).
    /// 예전에는 첫 글리프만 그려서 `👨` 만 보였다. Windows 의 `getOrInsertCluster` 와 같은
    /// 자리이고, 거기서 `advances` · `offsets` 를 넘기는 것이 여기서는 `positions` 다 — `CTRun`
    /// 이 준 GPOS 적용 위치라 이대로 그려야 모양이 맞는다.
    ///
    /// 글리프가 하나면 기존 경로로 넘긴다 — 키가 `(font, index)` 라 캐시 적중률이 그쪽이 높다.
    pub fn getOrInsertCluster(
        self: *GlyphAtlas,
        font: ct.CTFontRef,
        /// #584 — cluster 안 글리프들의 폰트를 가리키는 **안정된 id** (`GlyphResult.font_id`).
        /// 폰트 층이 PostScript 이름으로 만들어 넘긴다. **주소를 넣지 않는다.**
        font_id: u64,
        glyphs: []const ct.CGGlyph,
        positions: []const ct.CGPoint,
        /// #420 — 글리프마다의 폰트. `가` + acute 처럼 CoreText 가 base 와 mark 를 다른 폰트로
        /// 배정하면 여기가 갈린다. 길이가 `glyphs` 와 다르면 전부 `font` 로 본다.
        fonts: []const ct.CTFontRef,
        /// cluster 가 차지하는 가로 폭 (pt). 0 이면 모르는 것이라 첫 글리프 advance 로 물러선다.
        /// 폰트 층이 `CTRunGetTypographicBounds` 로 재서 넘긴다 (#401).
        cluster_advance_pt: f32,
    ) ?AtlasEntry {
        if (glyphs.len == 0) return null;
        if (glyphs.len == 1) return self.getOrInsert(font, font_id, glyphs[0]);

        // 키는 글리프 인덱스들의 해시 + **폰트 id** 다. 같은 인덱스 조합이면 결과가 같다
        // (positions 는 그 조합에서 결정되므로 키에 안 넣는다).
        //
        // **폰트는 `font_id` 로만 본다** (#584). 같은 인덱스가 폰트마다 다른 글리프를 가리키므로
        // 폰트 식별은 반드시 필요하지만, 예전처럼 **주소**를 해시에 섞으면 안 된다 — CoreText 가
        // 같은 폰트에 CTLine 마다 새 객체를 줘서 같은 그림이 주소마다 새로 담겼다. `font_id` 는
        // cluster 안 글리프들의 폰트를 순서까지 담고 있어 갈린 cluster 도 구분된다.
        //
        // ⚠️ **해시를 자르지 않고, 일반 글리프와 다른 맵에 넣는다** (#529). 예전에는 `u16` 으로
        // 잘라 `cache` 에 넣었는데, 그 대역이 *진짜* glyph index 와 같은 자리라 값이 겹치면 먼저
        // 들어간 쪽의 비트맵이 나왔다 — 실기에서 `a̸` 자리에 `U` 가 그려졌다.
        var h = std.hash.Wyhash.init(0xC1_05_7E_47);
        for (glyphs) |g| h.update(std.mem.asBytes(&g));
        const key = ClusterKey{ .font_id = font_id, .indices_hash = h.final() };
        if (self.cluster_cache.get(key)) |entry| return entry;

        const entry = self.rasterizeCluster(font, glyphs, positions, fonts, cluster_advance_pt) orelse return null;
        self.cluster_cache.put(key, entry) catch return null;
        return entry;
    }

    /// 탭바 컨트롤 아이콘 (`< > × +`) 을 `tab_icons` 로 rasterize 해 atlas 에
    /// 캐시 (#268). 폰트 글리프가 아니라 우리가 만든 알파 커버리지라 codepoint
    /// 대신 아이콘 enum 을 key 로 씀 (font=0 은 유효한 CTFontRef 아님). 커버리지
    /// `a` 를 흰색 premultiplied (a,a,a,a) 로 써서 일반 글리프와 같은 셰이더
    /// tint 경로 사용. scale 변경 시 `applyScale` 이 `reset` 하므로 다음 render
    /// 에서 새 size 로 재라스터.
    pub fn getOrInsertIcon(self: *GlyphAtlas, icon: tab_icons.Icon, size: u32, stroke_px: f32) ?AtlasEntry {
        const key = GlyphKey{ .font_id = atlas_common.ICON_FONT_ID, .index = @intFromEnum(icon) };
        if (self.cache.get(key)) |entry| return entry;
        if (size == 0 or size > tab_icons.MAX_SIZE) return null;

        var cov: [tab_icons.MAX_SIZE * tab_icons.MAX_SIZE]u8 = undefined;
        tab_icons.rasterize(icon, size, stroke_px, &cov);

        const bytes_per_row = size * 4;
        for (0..size) |row| {
            for (0..size) |col| {
                const a = cov[row * size + col];
                const off = row * bytes_per_row + col * 4;
                // BGRA premultiplied 흰색 — 일반 글리프와 동일 (a,a,a,a).
                self.temp_buf[off + 0] = a;
                self.temp_buf[off + 1] = a;
                self.temp_buf[off + 2] = a;
                self.temp_buf[off + 3] = a;
            }
        }

        // #584 ① — 자리가 없으면 **여기서 비우지 않고** 호출자에게 알린다. 호출자가 이미
        // 그린 것을 flush 하고 텍스처를 올린 뒤 비우고 재시도한다 (SPEC §12.6).
        const pos = self.packOrMarkFull(size, size, "icon") orelse return null;
        const atlas_x = pos[0];
        const atlas_y = pos[1];
        const atlas_row_bytes = self.pack.size * 4;
        for (0..size) |row| {
            const src_off = row * bytes_per_row;
            const dst_off = (atlas_y + @as(u32, @intCast(row))) * atlas_row_bytes + atlas_x * 4;
            @memcpy(self.pixels[dst_off..][0..bytes_per_row], self.temp_buf[src_off..][0..bytes_per_row]);
        }

        self.dirty = true;
        if (atlas_y < self.dirty_min_y) self.dirty_min_y = atlas_y;
        if (atlas_y + size > self.dirty_max_y) self.dirty_max_y = atlas_y + size;

        const entry = AtlasEntry{
            .x = @intCast(atlas_x),
            .y = @intCast(atlas_y),
            .w = @intCast(size),
            .h = @intCast(size),
            .bearing_x = 0,
            .bearing_y = 0,
            .is_color = false,
        };
        self.cache.put(key, entry) catch return null;
        return entry;
    }

    /// 아틀라스 reset (cache + packing 상태 + 픽셀 모두 클리어).
    pub fn reset(self: *GlyphAtlas) void {
        self.cache.clearRetainingCapacity();
        // cluster 맵도 함께 비운다 — 빠뜨리면 폰트 · scale 이 바뀐 뒤 죽은 좌표가 남는다.
        self.cluster_cache.clearRetainingCapacity();
        self.pack.rewind();
        self.is_full = false;
        // #584 — **픽셀을 0 으로 밀지 않는다.** 예전에는 `@memset(self.pixels, 0)` 을 했는데,
        // 이 atlas 는 프레임 시작에 한 번만 업로드되므로 (2-frame 정책) 비운 직후의 0 이 다음
        // 프레임에 올라가 **화면이 통째로 비었다.** 자리만 되돌리면 다음에 담기는 글리프가
        // 그 위를 덮어쓴다 — 아무도 참조하지 않는 옛 픽셀이 남는 것은 무해하다.
        self.dirty = true;
        self.dirty_min_y = 0;
        self.dirty_max_y = self.pack.size;
    }

    /// cluster 키에 실린 **서로 다른 폰트 id 수**. 진단 전용 (`resetFull` 에서만 부른다).
    ///
    /// 화면이 쓰는 폰트 수와 이 값이 맞아야 한다. 크게 벗어나면 같은 그림이 여러 키로 담긴다는
    /// 뜻이다 ([#584](https://github.com/ensky0/tildaz/issues/584) — 예전에는 키에 폰트 **주소**가
    /// 실려 CoreText 가 새 객체를 줄 때마다 새 칸을 썼다). 256 개까지만 세고 그 이상은 256 으로
    /// 보고한다.
    fn distinctClusterFonts(self: *const GlyphAtlas) u32 {
        var seen: [256]u64 = undefined;
        var n: u32 = 0;
        var it = self.cluster_cache.keyIterator();
        while (it.next()) |k| {
            var found = false;
            for (seen[0..n]) |s| {
                if (s == k.font_id) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (n >= seen.len) return @intCast(seen.len);
                seen[n] = k.font_id;
                n += 1;
            }
        }
        return n;
    }

    /// **가득 차서** 비운다 — `reset` 에 횟수 세기와 로그를 얹은 것이다. scale 변경 경로와
    /// 갈라 두어야 로그가 "용량이 모자란다" 는 뜻으로만 읽힌다
    /// ([#584](https://github.com/ensky0/tildaz/issues/584)).
    pub fn resetFull(self: *GlyphAtlas) void {
        self.resets += 1;
        const kind = self.full_kind;
        // `reset` 전에 읽는다 — 그 값이 이 atlas 가 실제로 담을 수 있었던 양이다.
        log.logAtlasFull(kind, self.resets, self.cache.count(), self.cluster_cache.count(), self.distinctClusterFonts(), self.pack.filledY());
        self.reset();
    }

    /// #401 — 여러 글리프를 `positions` 대로 한 비트맵에 그린다. `rasterize` 의 multi-glyph 판이라
    /// 주석은 그쪽을 참고한다 (색 · smoothing · CTM scale · baseline 정렬 이유가 모두 같다).
    ///
    /// **다른 것은 bounding box 하나다.** 글리프마다 rect 를 받아 각자의 position 만큼 옮긴 뒤
    /// 합집합을 낸다 — 그래야 겹쳐 쌓이는 글리프 (Apple Color Emoji 의 `❤️` 조합) 가 안 잘린다.
    fn rasterizeCluster(
        self: *GlyphAtlas,
        font: ct.CTFontRef,
        glyphs: []const ct.CGGlyph,
        positions: []const ct.CGPoint,
        fonts: []const ct.CTFontRef,
        cluster_advance_pt: f32,
    ) ?AtlasEntry {
        const n = glyphs.len;
        if (n == 0 or n > 16 or positions.len < n) return null;

        // #420 — 글리프마다의 폰트. 길이가 안 맞으면 (구 호출부) 전부 `font` 로 본다.
        var font_buf: [16]ct.CTFontRef = undefined;
        for (0..n) |i| font_buf[i] = if (fonts.len == n) fonts[i] else font;
        const gf = font_buf[0..n];

        // bounding rect 는 **글리프마다 자기 폰트에** 물어야 한다. 같은 인덱스라도 폰트가
        // 다르면 다른 글리프다.
        var rects: [16]ct.CGRect = undefined;
        for (0..n) |i| {
            var one = [1]ct.CGGlyph{glyphs[i]};
            var r: [1]ct.CGRect = undefined;
            _ = ct.CTFontGetBoundingRectsForGlyphs(
                gf[i],
                ct.kCTFontOrientationDefault,
                &one,
                &r,
                1,
            );
            rects[i] = r[0];
        }

        // #421 — **위 결합 기호를 ascent 에 맞춰 높이를 고른다.**
        //
        // 폰트 · shaping 은 mark 를 base 잉크 바로 위에 놓는다. 겹치지 않으려는 동작이라 각각은
        // 옳지만, 그 결과 같은 `U+0305` 가 `a` 위에서는 낮고 `b` 위에서는 높아 `a̅b̅c̅d̅e̅f̅` 의
        // 윗줄이 계단처럼 보인다 (실측: top 11.29 vs 14.01 pt).
        //
        // **무엇이 위 mark 인지는 잉크로 가른다** — codepoint 표가 필요 없다. base (잉크가 가장
        // 높은 글리프) 의 잉크 top 위에 통째로 있는 글리프만 대상이다. 그러면 이런 것들이
        // 자동으로 빠진다 (실측):
        //
        //   Devanagari `क्षि`  두 글리프가 세로로 겹친다        -> 대상 아님
        //   `k` + U+0336      관통선이 base 잉크 **안**에 있다  -> 대상 아님 (#418 이 따로 맞춘다)
        //   아래 mark         base 잉크 아래                    -> 대상 아님
        //
        // **올리기만 한다.** 이미 ascent 위에 있는 mark 를 끌어내리면 base 와 겹친다 — `가` +
        // acute 가 그렇다 (acute top 15.87, `가` 잉크 top 12.06. ascent 13.92 로 내리면 acute
        // 아래끝이 11.53 이 되어 `가` 안으로 들어간다, #420). Linux 는 mark 가 base 에 묻혀
        // 있어서 양방향으로 옮겼지만 여기는 반대 상황이다.
        var adj_buf: [16]ct.CGPoint = undefined;
        @memcpy(adj_buf[0..n], positions[0..n]);
        const adj = adj_buf[0..n];
        if (self.ascent_pt > 0 and n >= 2) alignAboveMarks(rects[0..n], adj, self.ascent_pt);

        // 각 글리프 rect 를 자기 position 만큼 옮겨 합집합. 여기가 단일 글리프판과 갈리는 곳이다.
        var min_x = rects[0].origin.x + adj[0].x;
        var min_y = rects[0].origin.y + adj[0].y;
        var max_x = min_x + rects[0].size.width;
        var max_y = min_y + rects[0].size.height;
        for (1..n) |i| {
            const rx = rects[i].origin.x + adj[i].x;
            const ry = rects[i].origin.y + adj[i].y;
            if (rx < min_x) min_x = rx;
            if (ry < min_y) min_y = ry;
            if (rx + rects[i].size.width > max_x) max_x = rx + rects[i].size.width;
            if (ry + rects[i].size.height > max_y) max_y = ry + rects[i].size.height;
        }

        // 하나라도 컬러 글리프면 컬러 경로로 그린다 — 갈린 cluster 에서 폰트마다 다를 수 있다.
        var is_color = false;
        for (gf) |f| {
            if ((ct.CTFontGetSymbolicTraits(f) & ct.kCTFontTraitColorGlyphs) != 0) is_color = true;
        }

        // cluster 가 차지하는 폭. renderer 가 이 값으로 셀 안 가운데 정렬을 한다
        // (`glyphCenterDx`). 폰트 층이 재 준 값을 쓰고, 못 받았을 때만 첫 글리프 advance 로
        // 물러선다 — 그 값은 **가로로 늘어서는 cluster 에서 틀린다** (Devanagari `क्षि` 는
        // 첫 글리프 4.09 pt, cluster 15.33 pt. 실측으로 14 px 밀렸다, #401).
        const advance_px: f32 = if (cluster_advance_pt > 0)
            cluster_advance_pt * @as(f32, @floatCast(self.scale))
        else blk: {
            var adv = [1]ct.CGSize{.{ .width = 0, .height = 0 }};
            var first = [1]ct.CGGlyph{glyphs[0]};
            _ = ct.CTFontGetAdvancesForGlyphs(font, ct.kCTFontOrientationDefault, &first, &adv, 1);
            break :blk @floatCast(adv[0].width * self.scale);
        };

        const s = self.scale;
        const x0 = @floor(min_x * s);
        const y0 = @floor(min_y * s);
        const x1 = @ceil(max_x * s);
        const y1 = @ceil(max_y * s);
        const gw_f = x1 - x0;
        const gh_f = y1 - y0;
        if (gw_f <= 0 or gh_f <= 0) return null;

        const gw: u32 = @trunc(gw_f);
        const gh: u32 = @trunc(gh_f);
        if (gw > 256 or gh > 256) return null; // temp_buf 한계.

        const bytes_per_row = gw * 4;
        const colorspace = ct.CGColorSpaceCreateDeviceRGB() orelse return null;
        defer ct.CGColorSpaceRelease(colorspace);
        const ctx = ct.CGBitmapContextCreate(
            self.temp_buf.ptr,
            gw,
            gh,
            8,
            bytes_per_row,
            colorspace,
            ct.kCGImageAlphaPremultipliedFirst | ct.kCGBitmapByteOrder32Little,
        ) orelse return null;
        defer ct.CGContextRelease(ctx);

        @memset(self.temp_buf[0 .. gw * gh * 4], 0);
        ct.CGContextSetAllowsFontSmoothing(ctx, true);
        ct.CGContextSetShouldSmoothFonts(ctx, true);
        ct.CGContextSetShouldAntialias(ctx, true);
        ct.CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
        ct.CGContextScaleCTM(ctx, @floatCast(s), @floatCast(s));

        // 합집합 원점을 비트맵 (0,0) 에 맞추고, 각 글리프는 자기 position 을 더해 그린다.
        // 원점 보정이 `floor(·*s)/s` 인 이유는 단일 글리프판과 같다 (#156 baseline jitter).
        const base_x = -@floor(min_x * s) / s;
        const base_y = -@floor(min_y * s) / s;
        var draw_pos: [16]ct.CGPoint = undefined;
        for (0..n) |i| {
            draw_pos[i] = .{ .x = base_x + adj[i].x, .y = base_y + adj[i].y };
        }
        // #420 — **연속된 같은 폰트끼리 묶어 그린다.** 폰트가 갈린 cluster (`가` + acute 는
        // `Apple SD Gothic Neo` + `Monaco`) 를 한 번에 그리면 뒤 글리프가 남의 폰트에서
        // 인덱스로 찾아져 엉뚱한 그림이 된다. 갈리지 않은 흔한 경우는 호출이 한 번 그대로다.
        var i: usize = 0;
        while (i < n) {
            var j = i + 1;
            while (j < n and gf[j] == gf[i]) j += 1;
            ct.CTFontDrawGlyphs(gf[i], glyphs.ptr + i, draw_pos[i..].ptr, j - i, ctx);
            i = j;
        }

        const pos = self.packOrMarkFull(gw, gh, "cluster") orelse return null;
        const atlas_x = pos[0];
        const atlas_y = pos[1];
        const atlas_row_bytes = self.pack.size * 4;
        for (0..gh) |row| {
            const src_off = row * bytes_per_row;
            const dst_off = (atlas_y + @as(u32, @intCast(row))) * atlas_row_bytes + atlas_x * 4;
            @memcpy(self.pixels[dst_off..][0..bytes_per_row], self.temp_buf[src_off..][0..bytes_per_row]);
        }
        self.dirty = true;
        if (atlas_y < self.dirty_min_y) self.dirty_min_y = atlas_y;
        if (atlas_y + gh > self.dirty_max_y) self.dirty_max_y = atlas_y + gh;

        return AtlasEntry{
            .x = @intCast(atlas_x),
            .y = @intCast(atlas_y),
            .w = @intCast(gw),
            .h = @intCast(gh),
            .bearing_x = @trunc(x0),
            .bearing_y = @trunc(y0),
            .is_color = is_color,
            .advance = advance_px,
        };
    }

    fn rasterize(self: *GlyphAtlas, font: ct.CTFontRef, glyph_index: ct.CGGlyph) ?AtlasEntry {
        const glyphs = [1]ct.CGGlyph{glyph_index};
        var bounding_rect: ct.CGRect = undefined;
        _ = ct.CTFontGetBoundingRectsForGlyphs(
            font,
            ct.kCTFontOrientationDefault,
            &glyphs,
            @ptrCast(&bounding_rect),
            1,
        );

        // 폰트 트레이트 — SBIX/COLR (Apple Color Emoji 등) 면 컬러 글리프.
        // 같은 RGBA path 로 그리지만 셰이더 분기를 위해 entry 에 플래그 저장.
        const traits = ct.CTFontGetSymbolicTraits(font);
        const is_color = (traits & ct.kCTFontTraitColorGlyphs) != 0;

        // 글리프 advance (pt) → 물리 px. 셀 영역 가운데 정렬용 (#299).
        var adv_size = [1]ct.CGSize{.{ .width = 0, .height = 0 }};
        _ = ct.CTFontGetAdvancesForGlyphs(font, ct.kCTFontOrientationDefault, &glyphs, &adv_size, 1);
        const advance_px: f32 = @floatCast(adv_size[0].width * self.scale);

        // Retina 스케일 적용 + 정수 픽셀 align.
        const s = self.scale;
        const x0 = @floor(bounding_rect.origin.x * s);
        const y0 = @floor(bounding_rect.origin.y * s);
        const x1 = @ceil((bounding_rect.origin.x + bounding_rect.size.width) * s);
        const y1 = @ceil((bounding_rect.origin.y + bounding_rect.size.height) * s);

        const gw_f = x1 - x0;
        const gh_f = y1 - y0;

        if (gw_f <= 0 or gh_f <= 0) {
            // 빈 글리프 (space, control char 등).
            return AtlasEntry{
                .x = 0,
                .y = 0,
                .w = 0,
                .h = 0,
                .bearing_x = @trunc(x0),
                .bearing_y = @trunc(y0),
                .is_color = is_color,
                .advance = advance_px,
            };
        }

        const gw: u32 = @trunc(gw_f);
        const gh: u32 = @trunc(gh_f);

        if (gw > 256 or gh > 256) return null; // temp_buf 한계.

        // BGRA premultiplied CGBitmapContext.
        // PremultipliedFirst + ByteOrder32Little = 메모리 레이아웃 BGRA →
        // Metal BGRA8Unorm 텍스처와 직접 매칭.
        // - 일반 글리프: 흰색 fill 로 antialiased 라스터 → 픽셀 = (a, a, a, a).
        //   셰이더가 fg 와 곱해 색 입힘.
        // - 컬러 글리프 (SBIX): fill 색 무시되고 본래 비트맵 합성 → 픽셀 = 본래 색
        //   premultiplied. 셰이더는 atlas 그대로 출력.
        const bytes_per_row = gw * 4;
        const colorspace = ct.CGColorSpaceCreateDeviceRGB() orelse return null;
        defer ct.CGColorSpaceRelease(colorspace);
        const ctx = ct.CGBitmapContextCreate(
            self.temp_buf.ptr,
            gw,
            gh,
            8,
            bytes_per_row,
            colorspace,
            ct.kCGImageAlphaPremultipliedFirst | ct.kCGBitmapByteOrder32Little,
        ) orelse return null;
        defer ct.CGContextRelease(ctx);

        // 매 글리프마다 temp_buf 의 사용 영역 (gw*gh*4 bytes) 만 0 으로 clear.
        @memset(self.temp_buf[0 .. gw * gh * 4], 0);

        // Apple 의 LCD font smoothing (회색 stroke fattening). Terminal.app /
        // iTerm2 default 와 동등 (#157). retina 환경에서 stroke 약간 두꺼워져
        // 검정 배경 흰 글자 가독성 향상. RGB subpixel 이 아니라 회색 fattening
        // 이라 색 fringing 없음. 사용자 취향 차이 있어 향후 config 옵션화 검토.
        ct.CGContextSetAllowsFontSmoothing(ctx, true);
        ct.CGContextSetShouldSmoothFonts(ctx, true);
        ct.CGContextSetShouldAntialias(ctx, true);

        // 흰색 opaque fill — 일반 글리프엔 흰색 antialiased 마스크가 그려짐.
        // 컬러 글리프는 이 색깔 무시되고 SBIX bitmap 의 본래 색이 들어감.
        ct.CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);

        // CTM scale = Retina factor. bitmap 은 gw x gh pixel 인데
        // CTFontDrawGlyphs 는 point 좌표로 그리므로 scale 보정 없으면 글리프가
        // 1/scale 크기로 작게 들어간다 (#75 nostalgic-edison 의 결정적 fix).
        ct.CGContextScaleCTM(ctx, @floatCast(s), @floatCast(s));

        // 글리프의 baseline 위치를 bitmap 안에서 *정수 pixel* 그리드와 정확히
        // 정렬 (#156). 직접 `-origin.x`/`-origin.y` 를 쓰면 bitmap 의 (0,0)
        // pixel 이 글리프별로 fractional offset 만큼 어긋나, 정수 bearing 으로
        // 화면에 placement 할 때 글리프마다 ±0.5 logical-px baseline jitter
        // 발생 (사용자 시연: C 내려가고, 4/7 올라감).
        //
        // floor(origin*s)/s 로 보정하면 bitmap (0,0) 이 정확히 bearing pixel
        // 위치에 align. 글리프의 진짜 fractional 위치는 bitmap 안에서 sub-pixel
        // anti-aliasing 으로 흡수 (gw/gh 가 ceil-floor 라 충분한 여유). renderer
        // 는 정수 bearing 만 쓰면 baseline 일관 정렬. iTerm2 / Terminal.app
        // 표준 패턴.
        const pos_x_pt = -@floor(bounding_rect.origin.x * s) / s;
        const pos_y_pt = -@floor(bounding_rect.origin.y * s) / s;
        const positions = [1]ct.CGPoint{.{
            .x = pos_x_pt,
            .y = pos_y_pt,
        }};
        ct.CTFontDrawGlyphs(font, &glyphs, &positions, 1, ctx);

        // 아틀라스에 packing.
        const pos = self.packOrMarkFull(gw, gh, "glyph") orelse return null;

        // BGRA temp_buf (4 bytes per pixel) 를 atlas (BGRA8) 로 row 단위 복사.
        const atlas_x = pos[0];
        const atlas_y = pos[1];
        const atlas_row_bytes = self.pack.size * 4;
        for (0..gh) |row| {
            const src_off = row * bytes_per_row;
            const dst_off = (atlas_y + @as(u32, @intCast(row))) * atlas_row_bytes + atlas_x * 4;
            @memcpy(self.pixels[dst_off..][0..bytes_per_row], self.temp_buf[src_off..][0..bytes_per_row]);
        }

        // dirty 영역 마킹.
        self.dirty = true;
        if (atlas_y < self.dirty_min_y) self.dirty_min_y = atlas_y;
        if (atlas_y + gh > self.dirty_max_y) self.dirty_max_y = atlas_y + gh;

        return AtlasEntry{
            .x = @intCast(atlas_x),
            .y = @intCast(atlas_y),
            .w = @intCast(gw),
            .h = @intCast(gh),
            .bearing_x = @trunc(x0),
            .bearing_y = @trunc(y0),
            .is_color = is_color,
            .advance = advance_px,
        };
    }

    /// #282 G5 — 공통 row-based packing 에 위임.
    /// #584 ② — atlas 를 **두 배로 키운다.** ghostty 가 쓰는 방식이다 (`font.Atlas.grow`).
    ///
    /// **비우고 재사용하는 것보다 나은 이유.** 비우면 이미 emit 한 인스턴스의 UV 가 무효가
    /// 되고, macOS 는 그것을 프레임 안에서 되살릴 방법이 없다 — `replaceRegion` 은 **즉시
    /// CPU 복사이고 GPU 작업과 순서가 보장되지 않아서**, render pass 를 몇 번 끊어도 모든
    /// pass 가 최종 텍스처를 읽는다 (Apple 문서: *"immediately copies … does not synchronize
    /// against GPU accesses"*). 키우면 그 상황 자체가 없다.
    ///
    /// 옛 내용을 **같은 (x, y) 로** 옮긴다 — row-based packing 이라 좌표가 그대로 유효하고,
    /// 커서도 이어서 쓸 수 있다. 다만 UV 는 크기로 정규화되므로 renderer 가 uniform 과 Metal
    /// 텍스처를 함께 갱신해야 한다 (`syncAtlasTexture`).
    ///
    /// 상한 (`MAX_ATLAS_SIZE`) 에 닿으면 `false` 를 돌려준다 — 호출자는 ① 안전망으로 물러선다.
    pub fn grow(self: *GlyphAtlas) bool {
        const new_size = self.pack.grownSize(MAX_ATLAS_SIZE) orelse return false;
        const new_pixels = self.alloc.alloc(u8, @as(usize, new_size) * new_size * 4) catch return false;
        @memset(new_pixels, 0);

        // 옛 내용을 같은 좌표로 복사한다 — row stride 만 달라진다.
        const old_row = @as(usize, self.pack.size) * 4;
        const new_row = @as(usize, new_size) * 4;
        for (0..self.pack.size) |y| {
            @memcpy(new_pixels[y * new_row ..][0..old_row], self.pixels[y * old_row ..][0..old_row]);
        }

        self.alloc.free(self.pixels);
        self.pixels = new_pixels;
        self.pack.size = new_size;
        self.grows += 1;
        // 전체를 다시 올려야 한다 — 텍스처가 새로 만들어진다.
        self.dirty = true;
        self.dirty_min_y = 0;
        self.dirty_max_y = new_size;
        log.logAtlasGrew("main", new_size, self.grows, self.cache.count(), self.cluster_cache.count());
        return true;
    }

    /// 자리를 잡고, 못 잡으면 **비울 가치가 있을 때만** `is_full` 을 세운다 (#584 ①). 두 조건은 공통
    /// `Packer.tryPack` 에 있다 (#604 — 세 platform 이 같은 규칙).
    fn packOrMarkFull(self: *GlyphAtlas, w: u32, h: u32, kind: []const u8) ?[2]u32 {
        switch (self.pack.tryPack(w, h)) {
            .placed => |pos| return pos,
            .full => {
                self.is_full = true;
                self.full_kind = kind;
                return null;
            },
            .too_big => return null,
        }
    }
};

/// #421 — cluster 안의 **위 결합 기호**를 `ascent_pt` 에 맞춰 평행이동한다.
/// `rasterizeCluster` 의 주석에 근거가 있다. `pos` 를 제자리에서 고친다.
///
/// **cluster 안의 위 mark 전체를 같은 양만큼** 옮긴다 — 그래야 연속 조합
/// (`a`+301+308+323) 의 적층 간격이 유지된다. 기준은 **가장 위에 있는 mark** 다. 가장 아래
/// 것에 맞추면 그 위에 쌓인 mark 가 셀 밖으로 나간다 (Linux 에서 Lao 가 위 칸을 침범해 실측으로
/// 잡혔다, efc182c).
fn alignAboveMarks(rects: []const ct.CGRect, pos: []ct.CGPoint, ascent_pt: f32) void {
    const n = rects.len;
    if (n < 2 or pos.len < n) return;

    // base = 잉크가 가장 높은 글리프. advance 로는 못 가른다 — CoreText 는 합성 cluster 에서
    // advance 를 글리프 사이에 나눠 담아, base 가 0.03 이고 mark 가 9.00 으로 오기도 한다 (실측).
    var base: usize = 0;
    for (1..n) |i| {
        if (rects[i].size.height > rects[base].size.height) base = i;
    }
    const base_top = rects[base].origin.y + pos[base].y + rects[base].size.height;

    var highest: ?f64 = null;
    for (0..n) |i| {
        if (i == base or rects[i].size.height <= 0) continue;
        const bottom = rects[i].origin.y + pos[i].y;
        if (bottom < base_top) continue; // base 잉크와 겹치거나 그 아래면 위 mark 가 아니다
        const top = bottom + rects[i].size.height;
        if (highest == null or top > highest.?) highest = top;
    }
    const top = highest orelse return;

    // **올리기만 한다** (주석 참고 — 내리면 base 와 겹친다).
    const delta = @as(f64, ascent_pt) - top;
    if (delta <= 0) return;

    for (0..n) |i| {
        if (i == base or rects[i].size.height <= 0) continue;
        if (rects[i].origin.y + pos[i].y < base_top) continue;
        pos[i].y += delta;
    }
}
