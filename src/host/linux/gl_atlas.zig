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
const egl = @import("egl.zig");
const font = @import("../../font/linux/font.zig");
const freetype = @import("../../font/linux/freetype.zig");
const atlas_common = @import("../../renderer/glyph_atlas_common.zig");
const software_terminal = @import("software_terminal.zig");
const tab_icons = @import("../../tab_icons.zig");
const log = @import("../../log.zig");

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
        const stroke_q: u32 = @intFromFloat(@max(0.0, @round(stroke * 16.0)));
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

    /// `zeros` 는 텍스처를 0 으로 채워 두기 위한 버퍼다 (null 이면 미초기화).
    /// **`GL_LINEAR` 면 0 초기화가 필수다** — 선형 보간은 글리프 가장자리에서 바로
    /// 바깥 텍셀을 함께 읽는데, 그 자리가 미초기화면 쓰레기가 섞여 보인다.
    /// `packRow` 가 글리프 사이에 1px 를 띄우므로, 그 1px 가 0 (= 투명) 이면
    /// premultiplied 합성에서 가장자리가 투명 쪽으로 부드럽게 떨어진다.
    fn create(api: *const egl.Api, format: i32, filter: i32, zeros: ?[]const u8) Surface {
        var texture: u32 = 0;
        api.genTextures(1, @ptrCast(&texture));
        api.bindTexture(egl.GL_TEXTURE_2D, texture);
        api.texParameteri(egl.GL_TEXTURE_2D, egl.GL_TEXTURE_MIN_FILTER, filter);
        api.texParameteri(egl.GL_TEXTURE_2D, egl.GL_TEXTURE_MAG_FILTER, filter);
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
            if (zeros) |z| z.ptr else null,
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
        // 컬러 텍스처만 0 으로 채운다 — `GL_LINEAR` 가 글리프 가장자리에서 바깥
        // 텍셀을 함께 읽기 때문이다 (`Surface.create` 주석). 회색은 `GL_NEAREST` 에
        // UV 가 글리프 사각형과 1:1 이라 업로드한 영역 밖을 절대 안 읽으므로 4 MB
        // 업로드를 아낀다. 할당 실패하면 미초기화로 만든다 — 컬러 emoji 가장자리
        // 한 줄이 지저분할 수 있지만 렌더 자체는 계속된다.
        const zeros: ?[]u8 = allocator.alloc(u8, ATLAS_SIZE * ATLAS_SIZE * 4) catch null;
        defer if (zeros) |z| allocator.free(z);
        if (zeros) |z| @memset(z, 0);
        return .{
            .gray = Surface.create(api, egl.GL_ALPHA, egl.GL_NEAREST, null),
            .color = Surface.create(api, egl.GL_RGBA, egl.GL_LINEAR, zeros),
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
        const key = Key.fromItem(item);
        if (self.cache.get(key)) |entry| return entry;
        const g = item.glyph;
        return self.upload(api, allocator, key, .{
            .pixels = g.bitmap,
            .w = g.width,
            .h = g.height,
            .is_color = g.pixel_mode == freetype.FT_PIXEL_MODE_BGRA,
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
        if (self.cache.get(key)) |entry| return entry;

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
        self.cache.clearRetainingCapacity();
        self.gray.rewind();
        self.color.rewind();
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
        // 보이지 않는 그림 (공백 등) 도 캐시한다 — 매번 raster 를 다시 묻지 않게.
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
            self.cache.put(key, empty) catch {};
            return empty;
        }

        const is_color = bmp.is_color;
        const surface = if (is_color) &self.color else &self.gray;

        const placed = atlas_common.packRow(
            &surface.cursor_x,
            &surface.cursor_y,
            &surface.row_height,
            ATLAS_SIZE,
            bmp.w,
            bmp.h,
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
            // 사용자 로그에 남긴다 — 이 줄이 자주 보이면 `ATLAS_SIZE` 를 키울 근거다.
            log.appendLine("gpu", "GL atlas {s} full — clearing and refilling (resets={d})", .{
                if (is_color) "color" else "gray",
                surface.resets,
            });
            break :blk atlas_common.packRow(
                &surface.cursor_x,
                &surface.cursor_y,
                &surface.row_height,
                ATLAS_SIZE,
                bmp.w,
                bmp.h,
            ) orelse return null; // 그림 하나가 atlas 보다 크다 — 포기.
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
