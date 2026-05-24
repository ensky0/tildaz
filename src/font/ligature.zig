//! Cross-platform ligature shape primitives. Linux / macOS / Windows 의 font
//! backend 가 모두 같은 `LigatureMatch` tagged union 으로 결과 보고. 각 platform
//! 의 paint loop 가 `.single` / `.spacer` switch 로 동일 그리기 로직 사용.
//!
//! ## Pattern
//!
//! Latin ligature 폰트 (Fira Code / JetBrains Mono / Cascadia Code 등) 는 OpenType
//! GSUB 의 `liga` / `calt` feature 로 인접 char sequence 를 ligature glyph 으로
//! substitute. 폰트 별로 두 가지 디자인:
//!
//! - **Single-glyph ligature** (JetBrains Mono / Cascadia Code 일부): 입력 N
//!   chars → 1 glyph 으로 합성. 그 glyph 의 advance 는 N × cell_w. 우리 paint
//!   는 base cell 위치에 1 glyph 을 N-cell 너비로 draw.
//! - **Spacer-pattern ligature** (Fira Code 6.x): 입력 N chars → N glyph 으로
//!   substitute 되되 각 glyph index 가 natural (= 자연 글리프) 과 다름. e.g.
//!   `=>` → `LIG.arrow.start` (cell 0) + `LIG.arrow.end` (cell 1) — 두 glyph 이
//!   각자 자기 cell 차지하며 시각적으로 합쳐진 화살표. cursor positioning +
//!   cell-grid 정렬 유지가 디자인 의도.
//!
//! ## Detection (`classify`)
//!
//! N chars shape 결과 vs natural glyph indices:
//! - n < input_count → `.single` (classic GSUB merged)
//! - n == input_count + 한 glyph index 라도 natural 과 다름 → `.spacer`
//! - n == input_count + 모두 natural → null (ligature 아님)
//! - 그 외 (n == 0 or n > input_count) → null
//!
//! ## platforms
//!
//! - Linux: HarfBuzz `hb_shape` → `shapeRunOnFace` ([src/font/linux/font.zig]).
//! - macOS: CoreText `CTLineCreateWithAttributedString` → first CTRun.
//! - Windows: DirectWrite `IDWriteTextAnalyzer.GetGlyphs`.
//!
//! 각 platform 이 shape 결과 + natural indices 를 `ShapedSlot` array 로 구성 후
//! `classify` 호출.

const std = @import("std");

/// Single-glyph ligature 의 정보 — N chars 가 1 glyph 으로 합성된 경우.
/// caller 가 `font_backend.glyphByIndex(face_idx, glyph_index)` 로 raster 후
/// base cell 위치에 N × cell_w 너비로 draw.
pub const LigatureGlyph = struct {
    /// chain index 의 face — `glyphByIndex(face_idx, glyph_index)` 로 raster.
    /// Latin ligature 는 항상 primary (face_idx=0). cluster shape 는 ZWJ family
    /// emoji 등 emoji face (NotoColorEmoji 등) 에서 매치되어 face_idx>0 가능.
    /// mac / Windows 의 system font fallback 은 face index 개념 없어 항상 0.
    face_idx: u8 = 0,
    glyph_index: u32,
    /// HarfBuzz GPOS / DWrite GlyphOffset 의 ink box offset (cell-center 정렬에
    /// 더해 적용). 대부분 0, 일부 cluster 에서만 non-zero.
    x_offset: i32 = 0,
    y_offset: i32 = 0,
};

/// Spacer-pattern ligature — N chars 가 N glyph 으로 substitute 되되 각 glyph
/// index 가 natural 과 다름. caller 가 각 glyph 을 자기 cell 너비 (cw) 로 draw.
/// MAX 4 cells (2/3/4-char ligature 지원).
pub const LigatureSpacer = struct {
    face_idx: u8 = 0,
    count: u8,
    glyph_indices: [4]u32,
    x_offsets: [4]i32,
    y_offsets: [4]i32,
};

/// Ligature detect 결과의 tagged union — single-glyph 와 spacer-pattern 둘 다
/// 표현. `null` 은 ligature 아님 (자연 글자).
pub const LigatureMatch = union(enum) {
    single: LigatureGlyph,
    spacer: LigatureSpacer,
};

/// Shape 결과의 한 slot — caller 가 `classify` 호출 시 채워서 넘김.
/// platform 별 shape API 의 결과를 이 형태로 normalize.
pub const ShapedSlot = struct {
    /// shape 결과의 glyph index (FreeType `FT_Load_Glyph(idx, ...)` / mac
    /// `CGGlyph` / Windows `UINT16`).
    glyph_index: u32,
    /// `get_char_index(face, cp)` (FT) / mac `CTFontGetGlyphsForCharacters` /
    /// Windows `GetGlyphIndicesA` 의 결과 = 자연 (ligature 미적용) glyph index.
    /// ligature 검출은 shape result 와 비교로.
    natural_glyph_index: u32,
    x_offset: i32 = 0,
    y_offset: i32 = 0,
};

/// `LigatureMatch` 판정 — platform-agnostic 순수 로직.
///
/// `input_count` = 입력 codepoint 수 (2 또는 3, 향후 4 까지 확장).
/// `slots` = shape 결과 (slots.len = shape glyph count). 빈 slots 또는 input
/// 보다 많은 slots 면 비정상 → null.
pub fn classify(input_count: usize, slots: []const ShapedSlot) ?LigatureMatch {
    const n = slots.len;
    if (n == 0 or n > input_count) return null;

    if (n < input_count) {
        // Classic single-glyph ligature (입력 N → 1 glyph).
        return .{ .single = .{
            .face_idx = 0,
            .glyph_index = slots[0].glyph_index,
            .x_offset = slots[0].x_offset,
            .y_offset = slots[0].y_offset,
        } };
    }

    // n == input_count — spacer 후보. natural 과 비교.
    //
    // **ALL** glyph 이 natural 과 달라야 valid N-char spacer ligature. 만약
    // 하나라도 natural 과 같으면 → GSUB 가 그 position 의 char 는 substitute
    // 안 했음 → ligature 가 position 0 에서 N 까지 *완전히 걸쳐 있지 않음*.
    //
    // 예: space + `<=` 의 3-char shape — glyph[0]=space_natural, glyph[1,2]=
    // LIG.<=.start/end 의 substituted. 일부 substitute 만 됐으니 3-char ligature
    // 아님 (실제로는 1-char space + 2-char `<=`). null 반환 → caller 가 2-char
    // fallback 시도.
    //
    // 초기 구현 ("any differs") 은 너무 aggressive — 위 케이스를 spacer 로
    // 잘못 분류해서 paint loop 가 cell 3개 consume + 다음 ligature 의 첫 cell
    // 들 건너뛰는 버그 발생 (Linux 시연에서 `-->` 가 `--` + `>` 로 분해 보였던
    // 원인).
    for (slots) |slot| {
        if (slot.glyph_index == slot.natural_glyph_index) {
            // 하나라도 natural 그대로 — N-char spacer 가 아님.
            return null;
        }
    }

    var spacer = LigatureSpacer{
        .face_idx = 0,
        .count = @intCast(@min(n, 4)),
        .glyph_indices = .{ 0, 0, 0, 0 },
        .x_offsets = .{ 0, 0, 0, 0 },
        .y_offsets = .{ 0, 0, 0, 0 },
    };
    const checked = @min(n, 4);
    for (slots[0..checked], 0..) |slot, i| {
        spacer.glyph_indices[i] = slot.glyph_index;
        spacer.x_offsets[i] = slot.x_offset;
        spacer.y_offsets[i] = slot.y_offset;
    }
    return .{ .spacer = spacer };
}

/// ASCII printable (0x20..0x7E) — paint loop 의 ligature lookahead 후보 검사.
/// Latin ligature 폰트 (Fira Code / JetBrains Mono / Cascadia Code) 의 ligature
/// 대부분이 이 범위 char 들로 구성. CJK / 한글 / emoji 등은 cluster path 또는
/// single-char path 로.
pub fn isLigatureCandidate(cp: u21) bool {
    return cp >= 0x20 and cp <= 0x7E;
}

test "classify: single-glyph ligature (n < input)" {
    const slots = [_]ShapedSlot{
        .{ .glyph_index = 999, .natural_glyph_index = 100 }, // anything — only n < input matters
    };
    const result = classify(2, &slots);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .single);
    try std.testing.expectEqual(@as(u32, 999), result.?.single.glyph_index);
}

test "classify: spacer pattern (n == input, indices differ)" {
    const slots = [_]ShapedSlot{
        .{ .glyph_index = 1457, .natural_glyph_index = 1578 }, // =
        .{ .glyph_index = 1461, .natural_glyph_index = 1580 }, // >
    };
    const result = classify(2, &slots);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .spacer);
    try std.testing.expectEqual(@as(u8, 2), result.?.spacer.count);
    try std.testing.expectEqual(@as(u32, 1457), result.?.spacer.glyph_indices[0]);
    try std.testing.expectEqual(@as(u32, 1461), result.?.spacer.glyph_indices[1]);
}

test "classify: no ligature (n == input, indices match natural)" {
    const slots = [_]ShapedSlot{
        .{ .glyph_index = 100, .natural_glyph_index = 100 },
        .{ .glyph_index = 101, .natural_glyph_index = 101 },
    };
    const result = classify(2, &slots);
    try std.testing.expect(result == null);
}

test "classify: bad shape (n > input) returns null" {
    const slots = [_]ShapedSlot{
        .{ .glyph_index = 1, .natural_glyph_index = 100 },
        .{ .glyph_index = 2, .natural_glyph_index = 101 },
        .{ .glyph_index = 3, .natural_glyph_index = 102 },
    };
    try std.testing.expect(classify(2, &slots) == null);
}

test "classify: empty shape returns null" {
    const slots = [_]ShapedSlot{};
    try std.testing.expect(classify(2, &slots) == null);
}
