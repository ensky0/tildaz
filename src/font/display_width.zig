//! 고정폭 (monospace) 셀 layout 에서 codepoint 한 개의 시각 너비 (0/1/2 cell)
//! 를 반환. UAX #11 (East Asian Width) 의 W (Wide) / F (Fullwidth) → 2,
//! 일반 prinatable → 1, combining mark / 제어문자 / zero-width → 0.
//!
//! 사용처: 탭 제목 / rename 입력 등 *고정폭 cell layout* 으로 그려야 하는
//! 텍스트. 한글 / CJK / 일본어 / 중국어 등 wide 글자가 다음 글리프와 겹쳐
//! 보이는 사고 방지 (cell advance 를 이 폭으로 갱신). 터미널 cell 자체는
//! ghostty 가 grapheme cluster 단위로 wide / spacer_tail 을 따로 다룸.
//!
//! UAX #11 전체 table 을 가져오지 않고 *주요 script 블록만* 하드코딩 — 사용자
//! 환경에서 보일 가능성이 높은 한글 / 한자 / 가나 / 전각 forms / 기본 emoji
//! 블록 커버. 모르는 codepoint 는 1 (보수적 — 약간 좁게 그려질지언정 다음 글리프
//! 위에 올라타지는 않음). 정밀도가 더 필요하면 ghostty `unicode.table.get(cp).width`
//! 또는 `uucode` 를 직접 dep 로 추가하는 길이 있음 (현재는 tab title 정도면
//! 이 helper 로 충분).

const std = @import("std");

/// 0 = invisible (control / combining / zero-width), 1 = single cell,
/// 2 = double cell (CJK / Hangul / fullwidth / 주요 emoji 블록).
pub fn codepointWidth(cp: u21) u8 {
    // ASCII fast path. 제어 0x00-0x1F + DEL 0x7F = 0, 그 외 1.
    if (cp < 0x300) {
        if (cp < 0x20 or cp == 0x7F) return 0;
        return 1;
    }

    // Combining marks / zero-width — UAX #11 N (Neutral) 중 width 0.
    if (cp >= 0x0300 and cp <= 0x036F) return 0; // Combining Diacritical Marks
    if (cp >= 0x0483 and cp <= 0x0489) return 0; // Cyrillic
    if (cp >= 0x0591 and cp <= 0x05BD) return 0; // Hebrew
    if (cp == 0x05BF) return 0;
    if (cp >= 0x05C1 and cp <= 0x05C2) return 0;
    if (cp >= 0x05C4 and cp <= 0x05C5) return 0;
    if (cp == 0x05C7) return 0;
    if (cp >= 0x0610 and cp <= 0x061A) return 0; // Arabic
    if (cp >= 0x064B and cp <= 0x065F) return 0;
    if (cp == 0x0670) return 0;
    if (cp >= 0x06D6 and cp <= 0x06DC) return 0;
    if (cp >= 0x06DF and cp <= 0x06E4) return 0;
    if (cp >= 0x06E7 and cp <= 0x06E8) return 0;
    if (cp >= 0x06EA and cp <= 0x06ED) return 0;
    if (cp == 0x0711) return 0; // Syriac
    if (cp >= 0x0730 and cp <= 0x074A) return 0;
    if (cp >= 0x07A6 and cp <= 0x07B0) return 0; // Thaana
    if (cp >= 0x0900 and cp <= 0x0902) return 0; // Devanagari
    if (cp == 0x093A) return 0;
    if (cp == 0x093C) return 0;
    if (cp >= 0x0941 and cp <= 0x0948) return 0;
    if (cp == 0x094D) return 0;
    if (cp >= 0x0951 and cp <= 0x0957) return 0;
    if (cp >= 0x200B and cp <= 0x200F) return 0; // ZWSP / RTL marks
    if (cp >= 0x202A and cp <= 0x202E) return 0;
    if (cp >= 0x2060 and cp <= 0x2064) return 0;
    if (cp >= 0x2066 and cp <= 0x206F) return 0;
    if (cp == 0xFEFF) return 0; // ZWNBSP / BOM

    // East Asian Wide / Fullwidth.
    if (cp >= 0x1100 and cp <= 0x115F) return 2; // Hangul Jamo
    if (cp >= 0x2E80 and cp <= 0x303E) return 2; // CJK Radicals + Symbols
    if (cp >= 0x3041 and cp <= 0x33FF) return 2; // Hiragana / Katakana / CJK
    if (cp >= 0x3400 and cp <= 0x4DBF) return 2; // CJK Ext A
    if (cp >= 0x4E00 and cp <= 0x9FFF) return 2; // CJK Unified
    if (cp >= 0xA000 and cp <= 0xA4CF) return 2; // Yi Syllables
    if (cp >= 0xA960 and cp <= 0xA97F) return 2; // Hangul Jamo Ext A
    if (cp >= 0xAC00 and cp <= 0xD7A3) return 2; // Hangul Syllables (한글)
    if (cp >= 0xF900 and cp <= 0xFAFF) return 2; // CJK Compat Ideographs
    if (cp >= 0xFE30 and cp <= 0xFE4F) return 2; // CJK Compat Forms
    if (cp >= 0xFF00 and cp <= 0xFF60) return 2; // Fullwidth Latin / Symbols
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return 2; // Fullwidth Currency
    if (cp >= 0x20000 and cp <= 0x3FFFD) return 2; // CJK Ext B-G

    // 기본 emoji 블록 — 사용자가 탭 이름에 emoji 넣을 수 있음. 정밀도 부족하면
    // narrow emoji 가 있을 수 있지만 대다수 face / pictograph 는 wide.
    if (cp >= 0x1F300 and cp <= 0x1F64F) return 2; // Misc Symbols & Pictographs / Emoticons
    if (cp >= 0x1F680 and cp <= 0x1F6FF) return 2; // Transport & Map
    if (cp >= 0x1F900 and cp <= 0x1F9FF) return 2; // Supp Symbols & Pictographs
    if (cp >= 0x1FA70 and cp <= 0x1FAFF) return 2; // Symbols & Pictographs Ext A

    return 1;
}

/// UTF-8 문자열의 총 시각 폭 (cells). truncate / 정렬 계산용.
pub fn stringWidth(s: []const u8) usize {
    var view = std.unicode.Utf8View.init(s) catch return s.len; // invalid → byte length 보수
    var iter = view.iterator();
    var total: usize = 0;
    while (iter.nextCodepoint()) |cp| total += codepointWidth(cp);
    return total;
}

test "ASCII width" {
    try std.testing.expectEqual(@as(u8, 1), codepointWidth('a'));
    try std.testing.expectEqual(@as(u8, 1), codepointWidth(' '));
    try std.testing.expectEqual(@as(u8, 0), codepointWidth(0x1B)); // ESC
    try std.testing.expectEqual(@as(u8, 0), codepointWidth(0x7F)); // DEL
}

test "Hangul / CJK / Fullwidth width" {
    try std.testing.expectEqual(@as(u8, 2), codepointWidth('한')); // U+D55C
    try std.testing.expectEqual(@as(u8, 2), codepointWidth('글')); // U+AE00
    try std.testing.expectEqual(@as(u8, 2), codepointWidth('가')); // U+AC00 (start)
    try std.testing.expectEqual(@as(u8, 2), codepointWidth('힣')); // U+D7A3 (end)
    try std.testing.expectEqual(@as(u8, 2), codepointWidth('中'));
    try std.testing.expectEqual(@as(u8, 2), codepointWidth('日'));
    try std.testing.expectEqual(@as(u8, 2), codepointWidth('あ')); // Hiragana
    try std.testing.expectEqual(@as(u8, 2), codepointWidth('ア')); // Katakana
    try std.testing.expectEqual(@as(u8, 2), codepointWidth('Ａ')); // Fullwidth A
}

test "combining / zero-width" {
    try std.testing.expectEqual(@as(u8, 0), codepointWidth(0x0301)); // combining acute
    try std.testing.expectEqual(@as(u8, 0), codepointWidth(0x200B)); // ZWSP
}

test "stringWidth mixed" {
    try std.testing.expectEqual(@as(usize, 7), stringWidth("hi 한글")); // 1+1+1+2+2 = 7
    try std.testing.expectEqual(@as(usize, 4), stringWidth("中国"));
    try std.testing.expectEqual(@as(usize, 5), stringWidth("hello"));
}
