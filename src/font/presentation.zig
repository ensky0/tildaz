//! 이모지 모양 요청 — 글자를 컬러 이모지로 그릴지 흑백 글자로 그릴지 (#771). 세 OS 공용.
//!
//! **요청은 셋 중 하나다.**
//!
//! | cluster | 요청 |
//! |---|---|
//! | 둘째 글자가 VS16 (U+FE0F) | 이모지 |
//! | 둘째 글자가 VS15 (U+FE0E) | 텍스트 |
//! | 선택자 없음 · 첫 글자의 기본 모양이 이모지 (`Emoji_Presentation`) | 이모지 |
//! | 그 밖 | 없음 (`null`) — 글꼴 chain 순서를 그대로 따른다 |
//!
//! - **둘째 글자만 본다.** variation sequence 는 "글자 + 바로 뒤의 선택자" 다 (UTS #51 ED-8a ·
//!   ED-9a). ghostty 도 같은 자리를 본다 (`font/shaper/run.zig` 의 `RunIterator.next`).
//! - **기본이 텍스트인 글자는 요청하지 않는다** (2026-10-16 사용자 결정 · #771). 요청하면 chain 의
//!   텍스트 글꼴에 없는 글자 (`ℹ` `▶` 등) 가 지금의 컬러에서 흑백으로 바뀌고, macOS 의 단일 글자
//!   경로까지 다시 짜야 세 OS 가 맞는다. 이슈가 고치려는 것은 *이모지를 요청했는데 흑백인* 쪽이다.
//!
//! 요청을 받은 쪽 (각 OS 의 글꼴 코드) 은 **모양이 맞는 글꼴을 먼저** 찾고, 없으면 요청 없이
//! 다시 찾는다. 모양은 글꼴이 아니라 **글리프를 그려 본 결과**로 판정한다 (컬러 비트맵인가).

const std = @import("std");
const table = @import("emoji_presentation_table.zig");

pub const Presentation = enum { text, emoji };

pub const VS15: u21 = 0xFE0E;
pub const VS16: u21 = 0xFE0F;

/// cluster (첫 글자 + 뒤따르는 글자들) 의 모양 요청.
pub fn forCluster(cps: []const u21) ?Presentation {
    if (cps.len == 0) return null;
    if (cps.len >= 2) {
        if (cps[1] == VS16) return .emoji;
        if (cps[1] == VS15) return .text;
    }
    return forCodepoint(cps[0]);
}

/// 선택자 없는 글자 하나의 모양 요청. 기본이 이모지인 글자만 요청한다 (머리 주석).
pub fn forCodepoint(cp: u21) ?Presentation {
    return if (isEmojiPresentation(cp)) .emoji else null;
}

/// Unicode `Emoji_Presentation` — 선택자가 없을 때 기본 모양이 이모지인가.
pub fn isEmojiPresentation(cp: u21) bool {
    const rs = &table.emoji_presentation;
    // 이모지가 기본인 글자는 전부 U+231A 위다. 터미널 글자의 대부분 (ASCII · 한글 일부) 이
    // 여기서 끝난다.
    if (cp < rs[0].lo) return false;
    var lo: usize = 0;
    var hi: usize = rs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < rs[mid].lo) {
            hi = mid;
        } else if (cp > rs[mid].hi) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

test "표는 오름차순이고 범위끼리 겹치거나 붙지 않는다" {
    const rs = &table.emoji_presentation;
    try std.testing.expect(rs.len > 0);
    for (rs, 0..) |r, i| {
        try std.testing.expect(r.lo <= r.hi);
        if (i > 0) try std.testing.expect(rs[i - 1].hi + 1 < r.lo);
    }
}

test "Emoji_Presentation — 경계와 대표 글자" {
    // 기본이 이모지
    for ([_]u21{ 0x231A, 0x231B, 0x2614, 0x2615, 0x26A1, 0x26BD, 0x2648, 0x1F18E, 0x1F389, 0x1F44B }) |cp| {
        try std.testing.expect(isEmojiPresentation(cp));
    }
    // 기본이 텍스트 — 이모지 속성은 있지만 Emoji_Presentation 이 아닌 글자 (`❤` `☺` `ℹ` `▶`) 포함
    for ([_]u21{ 'A', 0x2764, 0x263A, 0x2139, 0x25B6, 0x2219, 0xAC00 }) |cp| {
        try std.testing.expect(!isEmojiPresentation(cp));
    }
    // 첫 범위의 바로 앞 · 바로 뒤
    try std.testing.expect(!isEmojiPresentation(0x2319));
    try std.testing.expect(!isEmojiPresentation(0x231C));
}

test "Emoji_Presentation 글자 수는 Unicode 18.0 의 1,228 개" {
    // #771 판정 드라이버가 같은 파일에서 센 수다. uucode 판이 바뀌면 이 수도 바뀌니
    // 표를 다시 만들 때 함께 고친다.
    try std.testing.expectEqualStrings("18.0.0", table.unicode_version);
    var n: usize = 0;
    for (table.emoji_presentation) |r| n += @as(usize, r.hi) - r.lo + 1;
    try std.testing.expectEqual(@as(usize, 1228), n);
}

test "forCluster — 선택자는 둘째 글자만 본다" {
    try std.testing.expectEqual(@as(?Presentation, .emoji), forCluster(&.{ 0x2764, VS16 }));
    try std.testing.expectEqual(@as(?Presentation, .text), forCluster(&.{ 0x2614, VS15 }));
    // keycap — `#` + VS16 + U+20E3
    try std.testing.expectEqual(@as(?Presentation, .emoji), forCluster(&.{ '#', VS16, 0x20E3 }));
    // 선택자 없음 — 첫 글자의 기본 모양. 피부색 · 국기 · ZWJ 는 첫 글자가 이모지 기본이다.
    try std.testing.expectEqual(@as(?Presentation, .emoji), forCluster(&.{ 0x1F44B, 0x1F3FB }));
    try std.testing.expectEqual(@as(?Presentation, .emoji), forCluster(&.{ 0x1F1F0, 0x1F1F7 }));
    try std.testing.expectEqual(@as(?Presentation, .emoji), forCluster(&.{ 0x1F468, 0x200D, 0x1F469 }));
    // 결합 기호 · 기본이 텍스트인 글자는 요청 없음
    try std.testing.expectEqual(@as(?Presentation, null), forCluster(&.{ 'e', 0x0301 }));
    try std.testing.expectEqual(@as(?Presentation, null), forCluster(&.{0x2764}));
    // 셋째 이후의 선택자는 이 글자의 것이 아니다
    try std.testing.expectEqual(@as(?Presentation, null), forCluster(&.{ 'e', 0x0301, VS16 }));
    try std.testing.expectEqual(@as(?Presentation, null), forCluster(&.{}));
}
