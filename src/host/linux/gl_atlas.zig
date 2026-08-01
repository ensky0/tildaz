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
//!               곱한다.
//!   - `color` : `GL_RGBA` (4 byte). `FT_PIXEL_MODE_BGRA` 컬러 emoji. premultiplied
//!               이므로 셰이더가 그대로 출력한다.
//!
//! GLES2 코어 포맷만 쓴다 — `GL_R8` 은 GLES3 이상이고, `GL_BGRA` 는 GLES 에 없다
//! (그래서 업로드 시 R/B 를 바꿔 넣는다).
//!
//! 패킹은 공통 [`glyph_atlas_common`](../../renderer/glyph_atlas_common.zig) 의
//! row-based `packRow` 를 쓴다 — macOS · Windows 와 같은 규칙이다. ghostty 의
//! bin-packer 보다 낭비가 크지만 이 규모에서는 문제가 아니고, 세 platform 이 같은
//! 배치 규칙을 쓰는 값이 더 크다.

const std = @import("std");
const egl = @import("egl.zig");
const font = @import("../../font/linux/font.zig");
const freetype = @import("../../font/linux/freetype.zig");
const atlas_common = @import("../../renderer/glyph_atlas_common.zig");
const software_terminal = @import("software_terminal.zig");

pub const AtlasEntry = atlas_common.AtlasEntry;

/// 한 변 길이(px). macOS · Windows atlas 와 같은 값.
pub const ATLAS_SIZE: u32 = 2048;

/// 글리프 캐시 키. Linux 폰트 경로는 codepoint lookup 과 glyph_index lookup 두
/// 갈래가 있어 (`Context.glyph` / `Context.glyphByIndex`) 어느 쪽인지 구분해야
/// 한다 — 같은 숫자가 다른 글리프를 뜻할 수 있다.
///
/// 어느 갈래인지는 그리기 목록의 [`software_terminal.GlyphRef`] 가 이미 들고 있다
/// — 여기서 다시 판단하지 않고 그 값을 키로 옮기기만 한다.
const Key = struct {
    /// glyph_index 경로면 face index, codepoint 경로면 0xFF.
    face: u8,
    /// codepoint 또는 glyph_index.
    value: u32,

    fn fromRef(ref: software_terminal.GlyphRef) Key {
        return switch (ref) {
            .codepoint => |cp| .{ .face = codepoint_face, .value = cp },
            .indexed => |ix| .{ .face = ix.face, .value = ix.index },
        };
    }
};

const codepoint_face: u8 = 0xFF;

/// 한 텍스처와 그 패킹 상태.
const Surface = struct {
    texture: u32 = 0,
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    row_height: u32 = 0,
    /// atlas 가 가득 차 초기화된 횟수. 진단용 (자주 일어나면 크기를 늘려야 한다).
    resets: u32 = 0,

    fn create(api: *const egl.Api, format: i32) Surface {
        var texture: u32 = 0;
        api.genTextures(1, @ptrCast(&texture));
        api.bindTexture(egl.GL_TEXTURE_2D, texture);
        api.texParameteri(egl.GL_TEXTURE_2D, egl.GL_TEXTURE_MIN_FILTER, egl.GL_NEAREST);
        api.texParameteri(egl.GL_TEXTURE_2D, egl.GL_TEXTURE_MAG_FILTER, egl.GL_NEAREST);
        // 글리프 경계 밖을 샘플링하지 않게 clamp — 인접 글리프가 새어 들어오는
        // 것을 막는다 (`packRow` 가 1px padding 을 주지만 clamp 가 2 차 방어다).
        api.texParameteri(egl.GL_TEXTURE_2D, egl.GL_TEXTURE_WRAP_S, egl.GL_CLAMP_TO_EDGE);
        api.texParameteri(egl.GL_TEXTURE_2D, egl.GL_TEXTURE_WRAP_T, egl.GL_CLAMP_TO_EDGE);
        api.texImage2D(
            egl.GL_TEXTURE_2D,
            0,
            format,
            @intCast(ATLAS_SIZE),
            @intCast(ATLAS_SIZE),
            0,
            @bitCast(format),
            egl.GL_UNSIGNED_BYTE,
            null,
        );
        return .{ .texture = texture };
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
    cache: std.AutoHashMap(Key, AtlasEntry),
    /// 업로드용 임시 버퍼 (BGRA → RGBA 변환에 쓴다). 글리프마다 할당하지 않는다.
    swizzle: std.ArrayList(u8) = .{},

    pub fn create(api: *const egl.Api, allocator: std.mem.Allocator) Atlas {
        // 1 byte 정렬 — 글리프 폭이 4 의 배수가 아닐 때 행이 밀리는 것을 막는다.
        api.pixelStorei(egl.GL_UNPACK_ALIGNMENT, 1);
        return .{
            .gray = Surface.create(api, egl.GL_ALPHA),
            .color = Surface.create(api, egl.GL_RGBA),
            .cache = std.AutoHashMap(Key, AtlasEntry).init(allocator),
        };
    }

    pub fn deinit(self: *Atlas, api: *const egl.Api, allocator: std.mem.Allocator) void {
        self.swizzle.deinit(allocator);
        self.cache.deinit();
        var gray_tex = self.gray.texture;
        var color_tex = self.color.texture;
        api.deleteTextures(1, @ptrCast(&gray_tex));
        api.deleteTextures(1, @ptrCast(&color_tex));
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
        return self.ensure(api, allocator, Key.fromRef(item.ref), &item.glyph);
    }

    /// 폰트가 다시 raster 된 뒤 (scale 변경 등) 캐시를 버린다. 같은 키가 이제 다른
    /// 그림을 뜻하므로 비우지 않으면 이전 크기의 글리프가 그대로 나온다.
    pub fn invalidate(self: *Atlas) void {
        self.cache.clearRetainingCapacity();
        self.gray.rewind();
        self.color.rewind();
    }

    fn ensure(
        self: *Atlas,
        api: *const egl.Api,
        allocator: std.mem.Allocator,
        key: Key,
        glyph: *const font.Glyph,
    ) ?AtlasEntry {
        if (self.cache.get(key)) |entry| return entry;

        // 보이지 않는 글리프 (공백 등) 도 캐시한다 — 매번 raster 를 다시 묻지 않게.
        if (glyph.width == 0 or glyph.height == 0 or glyph.bitmap.len == 0) {
            const empty = AtlasEntry{
                .x = 0,
                .y = 0,
                .w = 0,
                .h = 0,
                .bearing_x = 0,
                .bearing_y = 0,
                .advance = @floatFromInt(glyph.advance),
            };
            self.cache.put(key, empty) catch {};
            return empty;
        }

        const is_color = glyph.pixel_mode == freetype.FT_PIXEL_MODE_BGRA;
        const surface = if (is_color) &self.color else &self.gray;

        const placed = atlas_common.packRow(
            &surface.cursor_x,
            &surface.cursor_y,
            &surface.row_height,
            ATLAS_SIZE,
            glyph.width,
            glyph.height,
        ) orelse blk: {
            // 가득 찼다 — 비우고 한 번만 재시도한다. 캐시도 함께 버려야 이전
            // 좌표를 가리키는 entry 가 남지 않는다.
            //
            // 이 프레임의 앞쪽 글리프들이 이미 이 atlas 좌표를 참조해 정점을
            // 만들었을 수 있다. 그 프레임은 일부 글리프가 어긋나 보일 수 있고,
            // 다음 프레임부터 정상이다 — atlas 를 키우지 않는 한 근본 회피가
            // 불가능한 지점이라 정직하게 남긴다 (`resets` 로 빈도를 관찰한다).
            self.cache.clearRetainingCapacity();
            surface.reset();
            break :blk atlas_common.packRow(
                &surface.cursor_x,
                &surface.cursor_y,
                &surface.row_height,
                ATLAS_SIZE,
                glyph.width,
                glyph.height,
            ) orelse return null; // 글리프 하나가 atlas 보다 크다 — 포기.
        };

        const pixels: [*]const u8 = if (is_color) blk: {
            // GLES 에는 `GL_BGRA` 가 없다. FreeType 의 BGRA (premultiplied) 를
            // RGBA 순서로 바꿔 올린다 — 알파는 그대로다.
            const count = @as(usize, glyph.width) * glyph.height * 4;
            self.swizzle.resize(allocator, count) catch return null;
            var i: usize = 0;
            while (i < count) : (i += 4) {
                self.swizzle.items[i + 0] = glyph.bitmap[i + 2]; // R ← B
                self.swizzle.items[i + 1] = glyph.bitmap[i + 1]; // G
                self.swizzle.items[i + 2] = glyph.bitmap[i + 0]; // B ← R
                self.swizzle.items[i + 3] = glyph.bitmap[i + 3]; // A
            }
            break :blk self.swizzle.items.ptr;
        } else glyph.bitmap.ptr;

        api.bindTexture(egl.GL_TEXTURE_2D, surface.texture);
        api.texSubImage2D(
            egl.GL_TEXTURE_2D,
            0,
            @intCast(placed[0]),
            @intCast(placed[1]),
            @intCast(glyph.width),
            @intCast(glyph.height),
            @bitCast(if (is_color) egl.GL_RGBA else egl.GL_ALPHA),
            egl.GL_UNSIGNED_BYTE,
            pixels,
        );

        const entry = AtlasEntry{
            .x = @intCast(placed[0]),
            .y = @intCast(placed[1]),
            .w = @intCast(glyph.width),
            .h = @intCast(glyph.height),
            .bearing_x = @intCast(glyph.bitmap_left),
            .bearing_y = @intCast(glyph.bitmap_top),
            .is_color = is_color,
            .advance = @floatFromInt(glyph.advance),
        };
        self.cache.put(key, entry) catch {};
        return entry;
    }

    pub fn grayTexture(self: *const Atlas) u32 {
        return self.gray.texture;
    }

    pub fn colorTexture(self: *const Atlas) u32 {
        return self.color.texture;
    }

    /// 진단용 — atlas 가 몇 번 가득 차 비워졌는지. 자주 일어나면 `ATLAS_SIZE` 를
    /// 늘릴 근거가 된다.
    pub fn resetCount(self: *const Atlas) u32 {
        return self.gray.resets + self.color.resets;
    }
};

test "codepoint 키와 glyph_index 키는 값이 같아도 구분된다" {
    // 같은 숫자 65 가 codepoint 'A' 와 face 0 의 glyph_index 65 를 동시에 뜻할 수
    // 있다. 키가 이를 구분하지 않으면 엉뚱한 글리프가 캐시에서 나온다.
    const a: Key = .{ .face = codepoint_face, .value = 65 };
    const b: Key = .{ .face = 0, .value = 65 };
    try std.testing.expect(!std.meta.eql(a, b));
}
