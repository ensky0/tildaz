//! GL glyph atlas ([#277](https://github.com/ensky0/tildaz/issues/277) S2-4).
//!
//! FreeType 이 구운 글리프를 GPU 텍스처에 모아 두고, 그리기는 텍스처 조회 + 사각형
//! 하나로 끝낸다. software 경로가 매 글리프마다 픽셀을 블렌딩하던 것을 대체한다.
//!
//! **텍스처를 두 개로 나눈다** — ghostty 가 포맷을 세 종류(grayscale / BGR / BGRA)
//! 로 나누는 것과 같은 이유다. 대부분의 글리프는 알파 마스크 하나면 되므로 1 byte
//! 로 두면 메모리·업로드 대역폭이 4 배 유리하다.
//!
//!   - `gray`  : `GL_ALPHA` (1 byte). `FT_PIXEL_MODE_GRAY` 글리프. 셰이더가 fg 색을
//!               곱한다. **`GL_NEAREST`** — 1:1 로 그리므로 샘플이 텍셀 중심에
//!               정확히 떨어지고, software 경로와 픽셀이 같아진다.
//!   - `color` : `GL_RGBA` (4 byte). `FT_PIXEL_MODE_BGRA` 컬러 emoji. premultiplied
//!               이므로 셰이더가 그대로 출력한다. **`GL_LINEAR`** — emoji bitmap 은
//!               보통 폰트 strike (~109px) 라 cell 로 크게 축소되는데, nearest 는
//!               텍셀을 통째로 버려 가장자리가 거칠다 (2026-08-02 사용자 결정,
//!               ghostty · foot 도 같은 선택). software 경로의 nearest 와는 이
//!               항목만 의도적으로 갈린다.
//!
//! GLES2 코어 포맷만 쓴다 — `GL_R8` 은 GLES3 이상이고, `GL_BGRA` 는 GLES 에 없다
//! (그래서 업로드 시 R/B 를 바꿔 넣는다).
//!
//! 패킹은 공통 [`glyph_atlas_common`](../../renderer/glyph_atlas_common.zig) 의
//! row-based `packRow` 를 쓴다 — macOS · Windows 와 같은 규칙이다. ghostty 의
//! bin-packer 보다 낭비가 크지만 이 규모에서는 문제가 아니고, 세 platform 이 같은
//! 배치 규칙을 쓰는 값이 더 크다.

const std = @import("std");
const egl = @import("../../host/linux/egl.zig");
const font = @import("../../font/linux/font.zig");
const freetype = @import("../../font/linux/freetype.zig");
const atlas_common = @import("../glyph_atlas_common.zig");
const software_terminal = @import("../../host/linux/software_terminal.zig");
const tab_icons = @import("../../tab_icons.zig");
const log = @import("../../log.zig");

pub const AtlasEntry = atlas_common.AtlasEntry;

/// #586 — 시작 크기와 상한. macOS · Windows 와 같은 값 · 같은 정책 — **차면 두 배로 키운다** (`Surface.grow`),
/// 상한에서만 ① 안전망 (비우기). 실제 상한은 `MAX_ATLAS_SIZE` 와 드라이버의 `GL_MAX_TEXTURE_SIZE` 중 작은 쪽이다
/// (`Atlas.max_size`). surface 마다 크기가 따로다 — color 는 폰트 strike 크기로 담겨 gray 보다 훨씬 먼저 찬다.
pub const INITIAL_ATLAS_SIZE: u32 = 2048;
pub const MAX_ATLAS_SIZE: u32 = 8192;

/// 글리프 캐시 키. Linux 폰트 경로는 codepoint lookup 과 glyph_index lookup 두
/// 갈래가 있어 (`Context.glyph` / `Context.glyphByIndex`) 어느 쪽인지 구분해야
/// 한다 — 같은 숫자가 다른 글리프를 뜻할 수 있다.
///
/// 어느 갈래인지는 그리기 목록의 [`software_terminal.GlyphRef`] 가 이미 들고 있다
/// — 여기서 다시 판단하지 않고 그 값을 키로 옮기기만 한다.
const Key = struct {
    /// 어느 폰트에서 구운 그림인지. 터미널 폰트와 탭바 폰트는 크기가 달라 같은
    /// codepoint 라도 다른 그림이다. 아이콘은 폰트가 아니므로 별도 값을 쓴다.
    source: u8,
    /// glyph_index 경로면 face index, codepoint 경로면 0xFF, 아이콘이면 종류.
    face: u8,
    /// codepoint / glyph_index / 아이콘 크기+굵기.
    value: u32,

    fn fromItem(item: *const software_terminal.GlyphItem) Key {
        const source: u8 = @intFromEnum(item.font);
        return switch (item.ref) {
            // #375 — codepoint 경로는 `face` 가 `codepoint_face` 로 고정이라 face 정보가
            // 키에 없다. 변종을 `value` 의 상위 비트에 실어 bold `A` 와 regular `A` 가
            // 같은 칸을 덮어쓰지 않게 한다 (codepoint 는 u21 이라 자리가 남는다).
            .codepoint => |cp| .{
                .source = source,
                .face = codepoint_face,
                .value = @as(u32, cp) | (@as(u32, @intCast(item.face_style.index())) << 21),
            },
            .indexed => |ix| .{ .source = source, .face = ix.face, .value = ix.index },
            // #401 — 합성 글리프. 키가 FreeType glyph index 와 **같은 숫자여도 다른 그림**
            // 이라 `source` 를 갈라 준다. cluster 합성은 터미널 폰트에서만 나오므로 (탭바는
            // cluster shaping 을 하지 않는다) `source` 자리에 폰트 구분을 잃지 않는다.
            .composed => |c| .{ .source = composed_source, .face = c.face, .value = c.key },
        };
    }

    /// 아이콘 키 — 같은 종류라도 크기 · 굵기가 다르면 다른 그림이다. 굵기는
    /// 1/16 px 로 양자화해 넣는다 (그보다 미세한 차이는 래스터 결과가 같다).
    fn fromIcon(kind: tab_icons.Icon, size: u32, stroke: f32) Key {
        const stroke_q: u32 = @round(@max(0.0, stroke * 16.0));
        return .{
            .source = icon_source,
            .face = @intFromEnum(kind),
            .value = (size & 0xFFFF) | (stroke_q << 16),
        };
    }
};

const codepoint_face: u8 = 0xFF;
const icon_source: u8 = 0xFE;
/// #401 — 합성 cluster 글리프의 `source`. `FontId` 와 아이콘 어느 쪽과도 겹치지 않는다.
const composed_source: u8 = 0xFD;

/// 한 텍스처와 그 패킹 상태.
const Surface = struct {
    texture: u32 = 0,
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    row_height: u32 = 0,
    /// atlas 가 가득 차 초기화된 횟수. 진단용 (자주 일어나면 크기를 늘려야 한다).
    resets: u32 = 0,
    /// #586 — 지금 한 변 (px). `grow` 가 두 배로 키운다.
    size: u32 = INITIAL_ATLAS_SIZE,
    /// #586 — 키운 횟수 (진단).
    grows: u32 = 0,
    format: i32,
    filter: i32,
    /// 텍셀 한 개의 byte 수 — gray (`GL_ALPHA`) 1 · color (`GL_RGBA`) 4.
    bpp: u32,
    /// #586 — **CPU 사본** (`size × size × bpp`). GLES2 에는 텍스처 간 복사가 없어서 (`glCopyImageSubData` 는
    /// 3.2, `GL_ALPHA` 는 FBO 첨부 불가) 키울 때 옛 내용을 여기서 다시 올린다 — macOS 의 `pixels` 와 같은
    /// 모델이다. 0 으로 채워 두므로 새 텍스처의 빈 영역 초기화도 겸한다 (`GL_LINEAR` 인 color 에 필수 —
    /// 선형 보간이 글리프 가장자리 바깥 텍셀을 함께 읽는다). 할당에 실패하면 빈 slice 고 그 surface 는
    /// 키우지 못한다 (① 만 남는다).
    shadow: []u8 = &.{},

    fn create(api: *const egl.Api, allocator: std.mem.Allocator, format: i32, filter: i32, bpp: u32, size: u32) Surface {
        var self: Surface = .{ .format = format, .filter = filter, .bpp = bpp, .size = size };
        self.shadow = allocator.alloc(u8, @as(usize, size) * size * bpp) catch &.{};
        if (self.shadow.len > 0) @memset(self.shadow, 0);
        self.texture = self.makeTexture(api);
        return self;
    }

    fn deinit(self: *Surface, api: *const egl.Api, allocator: std.mem.Allocator) void {
        var tex = self.texture;
        api.deleteTextures(1, @ptrCast(&tex));
        if (self.shadow.len > 0) allocator.free(self.shadow);
        self.shadow = &.{};
    }

    /// `size` 크기의 텍스처를 만들고 `shadow` 가 있으면 그 내용으로 채운다 (없으면 미초기화).
    fn makeTexture(self: *const Surface, api: *const egl.Api) u32 {
        var texture: u32 = 0;
        api.genTextures(1, @ptrCast(&texture));
        api.bindTexture(egl.GL_TEXTURE_2D, texture);
        api.texParameteri(egl.GL_TEXTURE_2D, egl.GL_TEXTURE_MIN_FILTER, self.filter);
        api.texParameteri(egl.GL_TEXTURE_2D, egl.GL_TEXTURE_MAG_FILTER, self.filter);
        // 글리프 경계 밖을 샘플링하지 않게 clamp — 인접 글리프가 새어 들어오는
        // 것을 막는다 (`packRow` 가 1px padding 을 주지만 clamp 가 2 차 방어다).
        api.texParameteri(egl.GL_TEXTURE_2D, egl.GL_TEXTURE_WRAP_S, egl.GL_CLAMP_TO_EDGE);
        api.texParameteri(egl.GL_TEXTURE_2D, egl.GL_TEXTURE_WRAP_T, egl.GL_CLAMP_TO_EDGE);
        api.texImage2D(
            egl.GL_TEXTURE_2D,
            0,
            self.format,
            @intCast(self.size),
            @intCast(self.size),
            0,
            @bitCast(self.format),
            egl.GL_UNSIGNED_BYTE,
            if (self.shadow.len > 0) self.shadow.ptr else null,
        );
        return texture;
    }

    /// #586 — **두 배로 키운다** (macOS · Windows `grow` 와 같은 정책). 새 shadow 에 옛 내용을 **같은 (x, y)**
    /// 로 옮기고 (row stride 만 달라진다) 그것으로 새 텍스처를 만든다 — row-based packing 이라 좌표와 커서가
    /// 그대로 유효하고, 정점의 UV 는 픽셀 좌표라 (`gl_text.Batch.add`) 이미 쌓인 것도 그대로 맞는다.
    /// 옛 텍스처는 `glDeleteTextures` — 이미 발행한 draw 와의 순서는 GL command stream 이 지킨다.
    /// 상한 (`max_size`) · shadow 없음 · 할당 실패면 `false`.
    fn grow(self: *Surface, api: *const egl.Api, allocator: std.mem.Allocator, max_size: u32) bool {
        if (self.shadow.len == 0) return false;
        if (self.size * 2 > max_size) return false;
        const new_size = self.size * 2;
        const new_shadow = allocator.alloc(u8, @as(usize, new_size) * new_size * self.bpp) catch return false;
        @memset(new_shadow, 0);
        const old_row = @as(usize, self.size) * self.bpp;
        const new_row = @as(usize, new_size) * self.bpp;
        for (0..self.size) |y| {
            @memcpy(new_shadow[y * new_row ..][0..old_row], self.shadow[y * old_row ..][0..old_row]);
        }
        allocator.free(self.shadow);
        self.shadow = new_shadow;
        self.size = new_size;
        var old_tex = self.texture;
        self.texture = self.makeTexture(api);
        api.deleteTextures(1, @ptrCast(&old_tex));
        self.grows += 1;
        return true;
    }

    /// 업로드한 비트맵을 shadow 에도 적는다 (`grow` 가 다시 올릴 수 있게). `pixels` 는 텍스처에 올린 것과
    /// 같은 순서 (color 는 이미 RGBA 로 바뀐 것) 다.
    fn writeShadow(self: *Surface, x: u32, y: u32, w: u32, h: u32, pixels: [*]const u8) void {
        if (self.shadow.len == 0) return;
        const row = @as(usize, self.size) * self.bpp;
        const src_row = @as(usize, w) * self.bpp;
        for (0..h) |r| {
            const dst = (y + r) * row + @as(usize, x) * self.bpp;
            @memcpy(self.shadow[dst..][0..src_row], pixels[r * src_row ..][0..src_row]);
        }
    }

    /// 패킹 커서를 처음으로 되돌린다. 텍스처 내용은 그대로 두고 덮어쓴다.
    fn rewind(self: *Surface) void {
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.row_height = 0;
    }

    /// 가득 차서 비우는 경우 — 진단 카운터를 올린다. 폰트가 바뀌어 비우는
    /// (`Atlas.invalidate`) 경우와 구분해야 "atlas 가 작다" 를 오판하지 않는다.
    fn reset(self: *Surface) void {
        self.rewind();
        self.resets += 1;
    }
};

pub const Atlas = struct {
    gray: Surface,
    color: Surface,
    /// **캐시를 surface 별로 나눈다** ([#584](https://github.com/ensky0/tildaz/issues/584) ①).
    /// 한쪽이 가득 차 rewind 되면 무효가 되는 것은 **그 surface 의 항목뿐이다** — 다른
    /// surface 는 커서가 그대로여서 이미 내준 좌표가 살아 있다. 한 맵에 섞어 두면 gray 를
    /// 비울 때 color 항목까지 버려서, 같은 emoji 가 color 텍스처에 다시 올라가 자리를 두 번
    /// 먹고 color 가 필요 이상으로 빨리 찬다.
    gray_cache: std.AutoHashMap(Key, AtlasEntry),
    color_cache: std.AutoHashMap(Key, AtlasEntry),
    /// #584 ① — 가득 찬 surface. `null` 이면 안 찼다.
    ///
    /// `upload` 는 여기에 **표시만 하고 그 자리에서 비우지 않는다.** 이 프레임이 이미 emit 한
    /// 정점들이 비우기 전 좌표를 가리키고 있어서, *먼저 그리는 것*은 batch 를 들고 있는
    /// 호출자만 할 수 있다. 호출자는 이 값을 보고 flush → `resetFull` → 재시도 한 번을 한다
    /// (Windows `renderer/windows.zig` 의 `is_full` 경로와 같은 계약, SPEC §12.6 ①).
    full: ?Kind = null,
    /// 업로드용 임시 버퍼 (BGRA → RGBA 변환에 쓴다). 글리프마다 할당하지 않는다.
    swizzle: std.ArrayList(u8) = .empty,
    /// #586 — 키울 수 있는 상한. `MAX_ATLAS_SIZE` 와 드라이버 `GL_MAX_TEXTURE_SIZE` 중 작은 쪽. 조회를
    /// 못 하면 (`glGetIntegerv` 미로딩) 시작 크기 그대로 — 키우지 않는다.
    max_size: u32 = INITIAL_ATLAS_SIZE,

    /// 어느 텍스처인지. 로그의 `kind` 자리에 그대로 쓴다 (`@tagName`).
    pub const Kind = enum { gray, color };

    fn cacheFor(self: *Atlas, is_color: bool) *std.AutoHashMap(Key, AtlasEntry) {
        return if (is_color) &self.color_cache else &self.gray_cache;
    }

    fn surfaceFor(self: *Atlas, is_color: bool) *Surface {
        return if (is_color) &self.color else &self.gray;
    }

    pub fn create(api: *const egl.Api, allocator: std.mem.Allocator) Atlas {
        // 1 byte 정렬 — 글리프 폭이 4 의 배수가 아닐 때 행이 밀리는 것을 막는다.
        api.pixelStorei(egl.GL_UNPACK_ALIGNMENT, 1);
        // #586 — 두 surface 모두 CPU shadow (0 으로 채운 것) 로 만든다 (`Surface.shadow` 주석). 전에는 회색은
        // 미초기화로 두어 4 MB 업로드를 아꼈는데, 이제 키울 때 다시 올릴 원본이 필요해 둘 다 가진다.
        var max_size: u32 = INITIAL_ATLAS_SIZE;
        if (api.get_integerv) |f| {
            var gl_max: i32 = 0;
            f(egl.GL_MAX_TEXTURE_SIZE, &gl_max);
            if (gl_max > 0) max_size = @min(MAX_ATLAS_SIZE, @as(u32, @intCast(gl_max)));
        }
        return .{
            .gray = Surface.create(api, allocator, egl.GL_ALPHA, egl.GL_NEAREST, 1, INITIAL_ATLAS_SIZE),
            .color = Surface.create(api, allocator, egl.GL_RGBA, egl.GL_LINEAR, 4, INITIAL_ATLAS_SIZE),
            .gray_cache = std.AutoHashMap(Key, AtlasEntry).init(allocator),
            .color_cache = std.AutoHashMap(Key, AtlasEntry).init(allocator),
            .max_size = max_size,
        };
    }

    pub fn deinit(self: *Atlas, api: *const egl.Api, allocator: std.mem.Allocator) void {
        self.swizzle.deinit(allocator);
        self.gray_cache.deinit();
        self.color_cache.deinit();
        self.gray.deinit(api, allocator);
        self.color.deinit(api, allocator);
    }

    /// 그리기 목록의 글리프 하나를 atlas 에 확보한다. 이미 있으면 캐시에서 돌려준다.
    ///
    /// **raster 결과를 넘겨받는다** — atlas 가 `font.Context` 를 다시 조회하지 않는다.
    /// 조회는 수집기(`collectTerminalLayer`)가 위치를 계산하며 이미 했고, 그 결과가
    /// [`software_terminal.GlyphItem`] 에 실려 온다. 여기서 또 조회하면 폰트 chain
    /// 탐색이 프레임마다 두 번 돈다.
    pub fn glyphForItem(
        self: *Atlas,
        api: *const egl.Api,
        allocator: std.mem.Allocator,
        item: *const software_terminal.GlyphItem,
    ) ?AtlasEntry {
        const key = Key.fromItem(item);
        // #584 ① — 캐시가 surface 별이라 **조회 전에** 어느 쪽인지 정해야 한다. 여기서는
        // 이미 raster 결과를 들고 있어 (위 주석) 픽셀 모드로 바로 갈린다.
        const g = item.glyph;
        const is_color = g.pixel_mode == freetype.FT_PIXEL_MODE_BGRA;
        if (self.cacheFor(is_color).get(key)) |entry| return entry;
        return self.upload(api, allocator, key, .{
            .pixels = g.bitmap,
            .w = g.width,
            .h = g.height,
            .is_color = is_color,
            .advance = @floatFromInt(g.advance),
        });
    }

    /// #277 S2-5 — chrome 아이콘 (`< > + × …`). 폰트 글리프가 아니라 공통
    /// `tab_icons` 가 그리는 알파 커버리지 비트맵이라, atlas 가 비었을 때만
    /// 래스터화한다 (software 경로는 매 프레임 래스터화한다 — 순수 함수라 결과가
    /// 같다).
    pub fn iconEntry(
        self: *Atlas,
        api: *const egl.Api,
        allocator: std.mem.Allocator,
        kind: tab_icons.Icon,
        size: u32,
        stroke: f32,
    ) ?AtlasEntry {
        if (size == 0 or size > tab_icons.MAX_SIZE) return null;
        const key = Key.fromIcon(kind, size, stroke);
        // 아이콘은 알파 커버리지라 언제나 gray surface 다 (`upload` 에 `is_color = false`).
        if (self.gray_cache.get(key)) |entry| return entry;

        var cov: [tab_icons.MAX_SIZE * tab_icons.MAX_SIZE]u8 = undefined;
        tab_icons.rasterize(kind, size, stroke, &cov);
        return self.upload(api, allocator, key, .{
            .pixels = cov[0 .. size * size],
            .w = size,
            .h = size,
            .is_color = false,
            .advance = @floatFromInt(size),
        });
    }

    /// 폰트가 다시 raster 된 뒤 (scale 변경 등) 캐시를 버린다. 같은 키가 이제 다른
    /// 그림을 뜻하므로 비우지 않으면 이전 크기의 글리프가 그대로 나온다.
    pub fn invalidate(self: *Atlas) void {
        self.gray_cache.clearRetainingCapacity();
        self.color_cache.clearRetainingCapacity();
        self.gray.rewind();
        self.color.rewind();
        // 두 surface 를 함께 되돌렸으니 미처리 `full` 표시도 없앤다 — 남겨 두면 호출자가
        // 이미 비워진 surface 를 또 비운다.
        self.full = null;
    }

    /// #584 ① — 가득 찬 surface 를 비운다. **호출자가 이미 그린 것을 flush 한 뒤에만** 부른다.
    ///
    /// 그 순서가 이 함수의 존재 이유다. rewind 는 커서를 처음으로 돌려 다음 글리프가 앞자리를
    /// **덮어쓰게** 하므로, 그 자리를 가리키는 정점이 아직 안 그려져 있으면 다른 글리프가
    /// 그려진다 (Linux 는 텍스처를 0 으로 지우지 않아 *사라지는* 대신 *바뀐다*). 비운 뒤
    /// 호출자가 한 번만 재시도한다 — 그래도 실패하면 그림 하나가 atlas 보다 큰 경우다.
    pub fn resetFull(self: *Atlas) void {
        const kind = self.full orelse return;
        const is_color = kind == .color;
        const surface = self.surfaceFor(is_color);
        const cache = self.cacheFor(is_color);
        // 로그 값은 **비우기 전에** 읽는다 — 그것이 이 surface 가 실제로 담을 수 있었던 양이다.
        // Linux 는 cluster 를 별도 맵에 두지 않는다 (인덱스 캐시 하나다) — cluster · fonts 칸은 0.
        const held = cache.count();
        const filled_y = surface.cursor_y + surface.row_height;
        cache.clearRetainingCapacity();
        surface.reset();
        // 사용자 로그에 남긴다 — 문구는 세 platform 공통 정의를 쓴다 (#576).
        log.logAtlasFull(@tagName(kind), surface.resets, held, 0, 0, filled_y);
        self.full = null;
    }

    /// atlas 에 올릴 비트맵 하나. 폰트 글리프든 아이콘이든 여기서는 같다.
    const Bitmap = struct {
        pixels: []const u8,
        w: u32,
        h: u32,
        is_color: bool,
        advance: f32,
    };

    fn upload(
        self: *Atlas,
        api: *const egl.Api,
        allocator: std.mem.Allocator,
        key: Key,
        bmp: Bitmap,
    ) ?AtlasEntry {
        const is_color = bmp.is_color;
        const cache = self.cacheFor(is_color);

        // 보이지 않는 그림 (공백 등) 도 캐시한다 — 매번 raster 를 다시 묻지 않게.
        // 자리를 안 먹으므로 rewind 와 무관하게 계속 유효하다.
        if (bmp.w == 0 or bmp.h == 0 or bmp.pixels.len == 0) {
            const empty = AtlasEntry{
                .x = 0,
                .y = 0,
                .w = 0,
                .h = 0,
                .bearing_x = 0,
                .bearing_y = 0,
                .advance = bmp.advance,
            };
            cache.put(key, empty) catch {};
            return empty;
        }

        const surface = self.surfaceFor(is_color);
        // `packRow` 는 **실패할 때도 커서를 움직인다** (줄바꿈 분기가 높이 검사보다 앞이다).
        // 그래서 "비우면 들어갈 여지가 있었나" 는 호출 **전** 값으로 판정해야 한다.
        const before_x = surface.cursor_x;
        const before_y = surface.cursor_y;

        const placed = atlas_common.packRow(
            &surface.cursor_x,
            &surface.cursor_y,
            &surface.row_height,
            surface.size,
            bmp.w,
            bmp.h,
        ) orelse blk: {
            // #586 — **먼저 키운다** (macOS #584 ② · Windows 와 같다). 키우면 프레임 중간에 비우는 상황이
            // 없어 이미 쌓인 정점의 UV 가 무효화되지 않는다 — UV 는 픽셀 좌표고 셰이더가 `u_atlas_size`
            // 로 정규화한다 (`gl_text`). `packRow` 가 실패하며 옮긴 커서는 그대로 두고 (더 큰 atlas 안에서
            // 여전히 유효한 자리다) 이어서 담는다. 상한이면 아래 ① 로.
            while (surface.grow(api, allocator, self.max_size)) {
                log.logAtlasGrew(surface.size, surface.grows, cache.count(), 0);
                if (atlas_common.packRow(&surface.cursor_x, &surface.cursor_y, &surface.row_height, surface.size, bmp.w, bmp.h)) |p| break :blk p;
            }
            // #584 ① — 가득 찼다. **그 자리에서 비우지 않는다.**
            //
            // 이 프레임이 이미 emit 한 정점들이 이 atlas 좌표를 가리키고 있고, UV 는
            // `gl_text.Batch.add` 시점에 굽는다. 여기서 rewind 하면 뒤이어 올라오는
            // 글리프가 그 자리를 덮어써서 **앞의 글자들이 다른 글자로 바뀐다** (Linux 는
            // 텍스처를 0 으로 지우지 않으므로 사라지는 대신 바뀐다). 2026-09-02 KDE 실기에서
            // 화면 위쪽 6.22 줄이 그렇게 어긋나는 것을 확인했다.
            //
            // 그래서 표시만 하고 돌아간다. 호출자가 batch 를 flush 해 그린 뒤 `resetFull`
            // 을 부르고 한 번만 재시도한다 (SPEC §12.6 ①).
            //
            // **이미 빈 surface 인데도 안 들어가면 표시하지 않는다** — 비워도 못 담는다는
            // 뜻이라 (그림 하나가 atlas 보다 크다), 표시하면 호출자가 글리프마다 헛되게
            // flush + reset 을 한다.
            if (before_x != 0 or before_y != 0) {
                self.full = if (is_color) .color else .gray;
            }
            return null;
        };

        const pixels: [*]const u8 = if (is_color) blk: {
            // GLES 에는 `GL_BGRA` 가 없다. FreeType 의 BGRA (premultiplied) 를
            // RGBA 순서로 바꿔 올린다 — 알파는 그대로다.
            const count = @as(usize, bmp.w) * bmp.h * 4;
            self.swizzle.resize(allocator, count) catch return null;
            var i: usize = 0;
            while (i < count) : (i += 4) {
                self.swizzle.items[i + 0] = bmp.pixels[i + 2]; // R ← B
                self.swizzle.items[i + 1] = bmp.pixels[i + 1]; // G
                self.swizzle.items[i + 2] = bmp.pixels[i + 0]; // B ← R
                self.swizzle.items[i + 3] = bmp.pixels[i + 3]; // A
            }
            break :blk self.swizzle.items.ptr;
        } else bmp.pixels.ptr;

        api.bindTexture(egl.GL_TEXTURE_2D, surface.texture);
        api.texSubImage2D(
            egl.GL_TEXTURE_2D,
            0,
            @intCast(placed[0]),
            @intCast(placed[1]),
            @intCast(bmp.w),
            @intCast(bmp.h),
            @bitCast(if (is_color) egl.GL_RGBA else egl.GL_ALPHA),
            egl.GL_UNSIGNED_BYTE,
            pixels,
        );
        // #586 — `grow` 가 다시 올릴 수 있게 CPU 사본에도 적는다.
        surface.writeShadow(placed[0], placed[1], bmp.w, bmp.h, pixels);

        const entry = AtlasEntry{
            .x = @intCast(placed[0]),
            .y = @intCast(placed[1]),
            .w = @intCast(bmp.w),
            .h = @intCast(bmp.h),
            // bearing 은 수집기가 이미 좌표에 반영했다 — atlas 는 그림만 안다.
            .bearing_x = 0,
            .bearing_y = 0,
            .is_color = is_color,
            .advance = bmp.advance,
        };
        cache.put(key, entry) catch {};
        return entry;
    }

    pub fn grayTexture(self: *const Atlas) u32 {
        return self.gray.texture;
    }

    pub fn colorTexture(self: *const Atlas) u32 {
        return self.color.texture;
    }

    /// #586 — 셰이더의 `u_atlas_size` 에 줄 지금 크기 (surface 별).
    pub fn graySize(self: *const Atlas) u32 {
        return self.gray.size;
    }

    pub fn colorSize(self: *const Atlas) u32 {
        return self.color.size;
    }

    /// 진단용 — atlas 가 몇 번 가득 차 비워졌는지. `grow` 가 상한에 닿은 뒤에만 일어난다.
    pub fn resetCount(self: *const Atlas) u32 {
        return self.gray.resets + self.color.resets;
    }
};

test "codepoint 키와 glyph_index 키는 값이 같아도 구분된다" {
    // 같은 숫자 65 가 codepoint 'A' 와 face 0 의 glyph_index 65 를 동시에 뜻할 수
    // 있다. 키가 이를 구분하지 않으면 엉뚱한 글리프가 캐시에서 나온다.
    const a: Key = .{ .source = 0, .face = codepoint_face, .value = 65 };
    const b: Key = .{ .source = 0, .face = 0, .value = 65 };
    try std.testing.expect(!std.meta.eql(a, b));
}

test "#277 S2-5 — 폰트가 다르면 같은 codepoint 도 다른 키다" {
    // 터미널 폰트와 탭바 폰트는 크기가 다르다. 구분하지 않으면 탭 제목이 터미널
    // 크기로 (또는 그 반대로) 나온다.
    var terminal_item: software_terminal.GlyphItem = .{
        .ref = .{ .codepoint = 'A' },
        .font = .terminal,
        .glyph = undefined,
        .x = 0,
        .y = 0,
        .fg = .{ .r = 0, .g = 0, .b = 0 },
    };
    var tab_item = terminal_item;
    tab_item.font = .tab;
    try std.testing.expect(!std.meta.eql(Key.fromItem(&terminal_item), Key.fromItem(&tab_item)));
}

test "#277 S2-5 — 아이콘 키는 종류 · 크기 · 굵기를 구분한다" {
    const a = Key.fromIcon(.plus, 16, 1.5);
    try std.testing.expect(!std.meta.eql(a, Key.fromIcon(.close, 16, 1.5)));
    try std.testing.expect(!std.meta.eql(a, Key.fromIcon(.plus, 20, 1.5)));
    try std.testing.expect(!std.meta.eql(a, Key.fromIcon(.plus, 16, 2.5)));
    // 폰트 글리프 키와도 겹치지 않는다.
    try std.testing.expect(a.source != 0 and a.source != 1);
}
