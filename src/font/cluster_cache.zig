//! grapheme cluster shaping 결과 캐시 — 세 platform 공용 (#399 의 B).
//!
//! 셀 루프가 cluster 셀마다 · 프레임마다 shaping API 를 부르는 구조라, 같은 cluster 가
//! 반복되면 그만큼 헛일이다. 이 캐시는 그 shape 호출 자체를 건너뛴다.
//!
//! **뼈대는 공통이고 값만 platform 별이다.** 키 · 해시 · 용량 · 퇴출 · 무효화 정책은 셋이
//! 같아야 갈라지지 않는다. 갈리는 것은 캐시하는 값의 타입과 **버릴 때 해제가 필요한지**뿐이라,
//! 그 하나만 `release` 로 주입받는다.
//!
//! | platform | 값 | 퇴출할 때 |
//! |---|---|---|
//! | macOS | `GlyphResult { font: CTFontRef, … }` | `CFRelease` |
//! | Windows | `ClusterResult { face: *IDWriteFontFace, … }` | COM `Release` |
//! | Linux | `LigatureGlyph { face_idx, glyph_index, … }` | **없음** (인덱스라 소유권이 없다) |
//!
//! ```zig
//! cache: cluster_cache.ClusterCache(LigatureGlyph, null) = …,
//! ```
//!
//! **(A) 런 배칭 위에 얹는 것이지 대체가 아니다.** 배칭은 처음 보는 cluster 에도 듣고,
//! 캐시는 반복될 때만 든다. 특히 Linux 는 배칭이 준 것이 작아서 (HarfBuzz 는 호출당 고정
//! 비용이 작다 — [#399](https://github.com/ensky0/tildaz/issues/399)) 이쪽이 주 레버다.

const std = @import("std");

/// 키에 담을 수 있는 codepoint 수 상한. 넘는 cluster 는 **캐시하지 않는다** (그냥 shape).
///
/// ZWJ family 가 5, 스킨톤 · VS-16 이 2 라 실사용은 다 덮는다. slice 를 그대로 키로 쓰면
/// 수명 문제가 있어서 (셀 루프의 지역 버퍼를 가리킨다) 고정 배열로 복사해 담는다.
pub const MAX_KEY_CPS = 8;

/// 담아 둘 cluster 종류 수 상한. 넘으면 **통째로 비운다** (LRU 없음).
///
/// **한 화면이 요구하는 만큼은 담아야 한다** ([#588](https://github.com/ensky0/tildaz/issues/588)).
/// 예전 값 2048 은 *"한 화면에 동시에 올라오는 distinct cluster 는 최대 520 개"*
/// ([#381](https://github.com/ensky0/tildaz/issues/381) 의 varied 워크로드) 를 근거로 잡았는데,
/// **결합 기호를 많이 쓰는 화면은 셀 수만큼 distinct 가 나온다.** 그러면 매 프레임 캐시가
/// 통째로 비워지고 화면 전체를 다시 shape 한다 — macOS 실측에서 cluster 10,000 종 화면이
/// **프레임마다 570 ms** 를 썼고 (9,766 개 재shape), 상한을 넘겨 잡으면 **17 ms** 가 됐다
/// (33 배). 다시 shape 한 결과가 atlas 를 dirty 로 만들어 **렌더를 또 유발하는 자기 피드백
/// 루프**까지 있었다.
///
/// **값의 근거는 화면 최대 셀 수다.** 캐시의 목적이 *"한 화면분을 프레임 사이에 유지"* 이므로
/// 상한도 거기서 나온다. 그보다 크게 잡으면 화면에 없는 것이 쌓이는 것이라 비워도 된다.
///
/// | 화면 (cell 9.5×19.5 논리) | 최대 셀 |
/// |---|---|
/// | 4K@2x (논리 1920×1080) | 11,110 |
/// | 5K@2x (논리 2560×1440) | **19,637** |
/// | 8K@2x (논리 3840×2160) | 44,440 |
///
/// 5K 까지 덮는 값이다. 8K 를 전부 다른 cluster 로 채우면 비워지지만, 그 화면은 atlas 상한
/// ([#585](https://github.com/ensky0/tildaz/issues/585)) 도 함께 걸리는 극단이다.
///
/// **메모리는 최악 기준이고 실제로는 담긴 만큼만 쓴다** (`AutoHashMap` 은 lazy 할당이다).
/// 항목당 macOS 485 B · Windows 293 B · Linux 는 더 작다 (값이 인덱스다). 상한까지 차면
/// 슬롯 32,768 (load factor 80 %) 로 **macOS 15.2 MB · Windows 9.2 MB** 다 — atlas 가
/// 2048² × 4 = 16 MB 인 것과 같은 자리수다.
///
/// LRU 는 자료구조 비용이 이득보다 클 것으로 보고 두지 않는다 — 상한이 화면을 덮으면
/// 퇴출 자체가 드물다.
pub const CAPACITY = 20480;

const Key = struct {
    cps: [MAX_KEY_CPS]u21,
    len: u8,
};

fn makeKey(cps: []const u21) ?Key {
    if (cps.len == 0 or cps.len > MAX_KEY_CPS) return null;
    var k = Key{ .cps = [_]u21{0} ** MAX_KEY_CPS, .len = @intCast(cps.len) };
    @memcpy(k.cps[0..cps.len], cps);
    return k;
}

/// `V` 를 캐시한다. `release` 가 있으면 값을 버릴 때 (퇴출 · 무효화 · 덮어쓰기) 호출한다.
/// 소유권이 없는 값 (Linux 의 face index 등) 은 `null` 을 준다.
pub fn ClusterCache(comptime V: type, comptime release: ?fn (V) void) type {
    return struct {
        const Self = @This();

        /// 값이 `?V` 인 이유 — **negative 도 담는다.** chain 이 못 맞춘 cluster 를 안 담으면
        /// 그 cluster 가 매 프레임 chain 전체를 헛돈다. `ligature.Cache` 가 `?LigatureMatch`
        /// 로 negative 를 담는 것과 같은 이유다 (#282 B7).
        map: std.AutoHashMap(Key, ?V),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .map = std.AutoHashMap(Key, ?V).init(allocator) };
        }

        pub fn deinit(self: *Self) void {
            self.releaseAll();
            self.map.deinit();
        }

        /// outer null = 캐시에 없음. outer 값의 payload = 찾은 결과 또는 캐시된 실패(null).
        pub fn get(self: *const Self, cps: []const u21) ??V {
            const k = makeKey(cps) orelse return null;
            return self.map.get(k);
        }

        pub fn put(self: *Self, cps: []const u21, value: ?V) void {
            const k = makeKey(cps) orelse {
                // 키에 안 들어가는 cluster 다. 캐시하지 않으므로 여기서 값을 버린다 —
                // caller 가 소유권을 넘긴 뒤라 해제 책임이 이쪽에 있다.
                if (release) |f| if (value) |v| f(v);
                return;
            };
            if (self.map.count() >= CAPACITY and !self.map.contains(k)) self.clear();
            const gop = self.map.getOrPut(k) catch {
                if (release) |f| if (value) |v| f(v);
                return;
            };
            // 같은 키를 덮어쓸 때 옛 값을 흘리지 않는다.
            if (gop.found_existing) {
                if (release) |f| if (gop.value_ptr.*) |old| f(old);
            }
            gop.value_ptr.* = value;
        }

        /// 폰트 · DPI 가 바뀌면 담긴 글리프가 죽으므로 host 가 부른다.
        pub fn clear(self: *Self) void {
            self.releaseAll();
            self.map.clearRetainingCapacity();
        }

        fn releaseAll(self: *Self) void {
            if (release) |f| {
                var it = self.map.valueIterator();
                while (it.next()) |slot| {
                    if (slot.*) |v| f(v);
                }
            }
        }
    };
}

test "cluster 캐시는 값과 negative 를 모두 담는다" {
    const V = struct { idx: u32 };
    var c = ClusterCache(V, null).init(std.testing.allocator);
    defer c.deinit();

    const zwj = [_]u21{ 0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467 };
    try std.testing.expect(c.get(&zwj) == null); // 아직 없음

    c.put(&zwj, .{ .idx = 42 });
    const hit = c.get(&zwj) orelse return error.Missing;
    try std.testing.expectEqual(@as(u32, 42), (hit orelse return error.Null).idx);

    // negative 도 담긴다 — 담아야 매 프레임 chain 을 헛돌지 않는다.
    const unknown = [_]u21{0xFFFD};
    c.put(&unknown, null);
    const neg = c.get(&unknown) orelse return error.Missing;
    try std.testing.expect(neg == null);
}

test "키 상한을 넘는 cluster 는 캐시하지 않는다" {
    const V = struct { idx: u32 };
    var c = ClusterCache(V, null).init(std.testing.allocator);
    defer c.deinit();

    const long = [_]u21{'a'} ** (MAX_KEY_CPS + 1);
    c.put(&long, .{ .idx = 1 });
    // 담기지 않았으므로 계속 miss 다 — caller 는 그냥 shape 한다.
    try std.testing.expect(c.get(&long) == null);
}

test "용량을 넘으면 통째로 비운다" {
    const V = struct { idx: u32 };
    var c = ClusterCache(V, null).init(std.testing.allocator);
    defer c.deinit();

    var i: u21 = 0;
    while (i < CAPACITY) : (i += 1) {
        const key = [_]u21{ 0x1000 + i, 0x200D };
        c.put(&key, .{ .idx = i });
    }
    try std.testing.expectEqual(@as(u32, CAPACITY), c.map.count());

    // 하나 더 넣으면 비우고 그것만 남는다.
    const extra = [_]u21{ 0x9999, 0x200D };
    c.put(&extra, .{ .idx = 999 });
    try std.testing.expectEqual(@as(u32, 1), c.map.count());
    try std.testing.expect(c.get(&extra) != null);
}

test "release 는 버릴 때마다 정확히 한 번 불린다" {
    const S = struct {
        var freed: u32 = 0;
        const V = struct { idx: u32 };
        fn rel(_: V) void {
            freed += 1;
        }
    };
    S.freed = 0;

    var c = ClusterCache(S.V, S.rel).init(std.testing.allocator);
    const a = [_]u21{ 'x', 0x200D };
    c.put(&a, .{ .idx = 1 });
    c.put(&a, .{ .idx = 2 }); // 덮어쓰기 — 옛 값 해제
    try std.testing.expectEqual(@as(u32, 1), S.freed);

    // 키에 안 들어가는 cluster 는 담지 않으므로 그 자리에서 해제된다.
    const long = [_]u21{'a'} ** (MAX_KEY_CPS + 1);
    c.put(&long, .{ .idx = 3 });
    try std.testing.expectEqual(@as(u32, 2), S.freed);

    c.deinit(); // 남은 하나 해제
    try std.testing.expectEqual(@as(u32, 3), S.freed);
}
