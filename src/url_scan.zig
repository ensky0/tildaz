//! 터미널 텍스트에서 URL 을 찾는 스캐너 ([#647](https://github.com/ensky0/tildaz/issues/647),
//! 요청은 [#643](https://github.com/ensky0/tildaz/issues/643)).
//!
//! **순수 · 플랫폼 무관 · ghostty 비의존** — `zig test src/url_scan.zig` 로 단독 검증된다
//! (`mouse_report.zig` · `scrollbar.zig` 와 같은 패턴).
//!
//! **정규식을 쓰지 않는 이유.** ghostty 본체는 이 일을 oniguruma 정규식으로 한다
//! (`src/config/url.zig` 의 `url.regex`). 그런데 그 파일은 `config/` 아래라 우리가 받는
//! `ghostty-vt` 모듈 **밖**이고 (`build.zig` 의 `emit-lib-vt = true`), 이 기능 하나를 위해
//! oniguruma 를 새 의존성으로 들이는 것은 `build.zig.zon` 의 commit SHA pin 유지 부담까지
//! 생각하면 과하다. 그래서 **그 정규식의 scheme 분기 하나를 손으로 옮긴다.**
//!
//! 옮긴 것은 `scheme_url_branch` 뿐이다. 원본의 나머지 두 분기는 *파일 경로* 매처인데
//! (`/tmp/test.txt` · `./src/main.zig` · `src/config/url.zig`), 우리는 찾은 것을 기본
//! 브라우저로 여는 것이 목적이라 경로를 클릭 대상으로 삼지 않는다. 원본 주석도 그 regex 를
//! *"URLs and file paths"* 로 소개한다 — 두 용도가 한 정규식에 들어 있을 뿐이다.
//!
//! 원본 (pin `83c5671`) 의 해당 분기는 이렇다.
//!
//! ```text
//! (?: https?://|mailto:|ftp://|file:|ssh:|git://|ssh://|tel:|magnet:|ipfs://|ipns://|gemini://|gopher://|news: )
//! (?: (?:\[[:0-9a-fA-F]+(?:[:0-9a-fA-F]*)+\](?::[0-9]+)?) | [\w\-.~:/?#@!$&*+,;=%]+ (?:[\(\[]\w*[\)\]])? )+
//! (?<![,.])
//! ```
//!
//! 마지막 lookbehind 가 *"매치가 `,` 나 `.` 로 끝나지 않는다"* 이고, 가운데의 괄호 접미가
//! *"`(…)` 는 URL 의 일부지만 URL 을 감싼 `(…)` 는 아니다"* 를 만든다. 원본 주석이 그 두
//! 규칙의 근거를 적어 둔다 — `https://en.wikipedia.org/wiki/Rust_(video_game)` 은 괄호까지
//! 링크이고 `(https://example.com)` 은 괄호를 뺀다.
//!
//! **입력은 codepoint 슬라이스다.** 터미널 셀이 codepoint 단위라 열 번호와 1:1 로 맞물리고,
//! 호출자가 반환된 `Range` 를 그대로 셀 범위로 쓸 수 있다. 줄을 넘어간 URL 은 호출자가
//! `row.wrap` 을 따라 논리 줄을 이어 붙여 넘긴다 — 이 모듈은 한 줄만 본다.

const std = @import("std");

/// 찾은 URL 의 codepoint 인덱스 범위. `end` 는 배타적이다.
pub const Range = struct {
    start: usize,
    end: usize,

    pub fn len(self: Range) usize {
        return self.end - self.start;
    }

    pub fn contains(self: Range, index: usize) bool {
        return index >= self.start and index < self.end;
    }
};

/// scheme 목록 — 원본의 `url_schemes` 를 alternation 순서까지 그대로 옮긴다.
///
/// 정규식 alternation 은 왼쪽 우선이라 순서가 결과를 바꿀 수 있어서 손대지 않았다. `ssh:` 가
/// `ssh://` 보다 앞이라 `ssh://host` 는 `ssh:` 로 매치되고 남은 `//host` 는 URL 문자로 흡수
/// 된다 — 결과 문자열은 같다.
///
/// 소문자만 받는 것도 원본과 같다. oniguruma 는 기본이 대소문자 구분이고 원본이 `(?i)` 를
/// 켜지 않는다. `HTTPS://` 를 받으려면 여기서 정책을 바꾸는 것이 아니라 관례를 다시 재고
/// 근거를 남긴 뒤에 바꾼다.
const schemes = [_][]const u8{
    "https://",
    "http://",
    "mailto:",
    "ftp://",
    "file:",
    "ssh:",
    "git://",
    "tel:",
    "magnet:",
    "ipfs://",
    "ipns://",
    "gemini://",
    "gopher://",
    "news:",
};

/// 원본의 `scheme_url_chars` = `[\w\-.~:/?#@!$&*+,;=%]`.
///
/// **`\w` 를 ASCII 로 제한한다.** oniguruma 를 UTF-8 인코딩으로 초기화하면 `\w` 가 유니코드
/// word 까지 먹을 수 있는데, 그러면 `링크 https://example.com 입니다` 에서 한글이 URL 에 딸려
/// 들어간다. 터미널에서 URL 뒤에 CJK 가 바로 붙는 것은 흔한 배치라 실질적인 차이가 난다.
/// URL 에 non-ASCII 를 그대로 쓰는 IDN · 퍼센트 미인코딩 경로는 이 스캐너가 못 잡는데,
/// 그쪽은 잡아서 틀리는 것보다 못 잡는 편이 낫다.
fn isUrlChar(c: u21) bool {
    if (c > 127) return false;
    const b: u8 = @intCast(c);
    if (std.ascii.isAlphanumeric(b) or b == '_') return true;
    return switch (b) {
        '-', '.', '~', ':', '/', '?', '#', '@', '!', '$', '&', '*', '+', ',', ';', '=', '%' => true,
        else => false,
    };
}

/// 괄호 접미 안에 올 수 있는 문자 — 원본의 `\w` (위와 같은 이유로 ASCII).
fn isWordChar(c: u21) bool {
    if (c > 127) return false;
    const b: u8 = @intCast(c);
    return std.ascii.isAlphanumeric(b) or b == '_';
}

/// `text[i..]` 가 scheme 으로 시작하면 그 끝 인덱스.
fn matchScheme(text: []const u21, i: usize) ?usize {
    for (schemes) |scheme| {
        if (text.len - i < scheme.len) continue;
        var k: usize = 0;
        const ok = while (k < scheme.len) : (k += 1) {
            if (text[i + k] != scheme[k]) break false;
        } else true;
        if (ok) return i + scheme.len;
    }
    return null;
}

/// 원본의 `ipv6_url_pattern` — `[::1]` 같은 bracketed 주소와 선택적 `:포트`.
///
/// 원본의 `[:0-9a-fA-F]+(?:[:0-9a-fA-F]*)+` 는 같은 문자 집합의 중첩 반복이라 `+` 하나와
/// 같다. 주소의 형식 (그룹 수 · `::` 축약) 은 검사하지 않는다 — 원본도 안 한다.
fn matchIpv6(text: []const u21, i: usize) ?usize {
    if (i >= text.len or text[i] != '[') return null;
    var j = i + 1;
    const body_start = j;
    while (j < text.len and isHexOrColon(text[j])) : (j += 1) {}
    if (j == body_start) return null;
    if (j >= text.len or text[j] != ']') return null;
    j += 1;

    // 선택적 `:포트`. 숫자가 하나도 없으면 `:` 를 소비하지 않는다 — 그 `:` 는 URL 문자라
    // 바깥 루프가 다음 반복에서 먹는다.
    if (j < text.len and text[j] == ':') {
        var k = j + 1;
        while (k < text.len and text[k] >= '0' and text[k] <= '9') : (k += 1) {}
        if (k > j + 1) j = k;
    }
    return j;
}

fn isHexOrColon(c: u21) bool {
    if (c > 127) return false;
    const b: u8 = @intCast(c);
    return b == ':' or std.ascii.isHex(b);
}

/// 원본의 `optional_bracketed_word_suffix` = `(?:[\(\[]\w*[\)\]])?`.
///
/// 여는 기호와 닫는 기호의 **짝을 맞추지 않는 것도 원본 그대로**다 (`(abc]` 도 통과한다).
/// 실제 URL 에서 나올 배치가 아니라 무해하고, 관례를 옮기는 자리에서 원본과 다르게 둘 이유가
/// 없다.
fn matchBracketSuffix(text: []const u21, i: usize) ?usize {
    if (i >= text.len) return null;
    if (text[i] != '(' and text[i] != '[') return null;
    var j = i + 1;
    while (j < text.len and isWordChar(text[j])) : (j += 1) {}
    if (j >= text.len) return null;
    if (text[j] != ')' and text[j] != ']') return null;
    return j + 1;
}

/// `from` 이후의 **첫** URL. 없으면 null.
pub fn findFrom(text: []const u21, from: usize) ?Range {
    var i = from;
    while (i < text.len) : (i += 1) {
        const body_start = matchScheme(text, i) orelse continue;

        // `(?: ipv6 | chars+ suffix? )+` — 괄호 접미는 **URL 문자 뒤에만** 온다. 그래서
        // `https://(abc)` 는 매치되지 않는다 (원본과 같다).
        var j = body_start;
        while (j < text.len) {
            if (matchIpv6(text, j)) |e| {
                j = e;
                continue;
            }
            const run_end = runUrlChars(text, j);
            if (run_end == j) break;
            j = run_end;
            if (matchBracketSuffix(text, j)) |e| j = e;
        }
        if (j == body_start) continue; // scheme 만 있고 본문이 없다

        // `(?<![,.])` — 문장 끝의 마침표와 목록의 쉼표를 URL 에서 뺀다. 정규식은 `+` 를
        // 되감아 만족시키는데, 되감는 것과 끝에서 벗기는 것은 이 문자 집합에서 같다.
        var end = j;
        while (end > body_start and (text[end - 1] == ',' or text[end - 1] == '.')) : (end -= 1) {}
        if (end == body_start) continue; // 벗기고 나니 본문이 없다

        return .{ .start = i, .end = end };
    }
    return null;
}

/// 그 자리를 덮는 URL. hover · 클릭 판정이 쓴다.
pub fn findAt(text: []const u21, index: usize) ?Range {
    if (index >= text.len) return null;
    var from: usize = 0;
    while (findFrom(text, from)) |r| {
        if (r.contains(index)) return r;
        if (r.start > index) return null; // 매치는 왼쪽부터라 더 볼 것이 없다
        from = r.end;
    }
    return null;
}

fn runUrlChars(text: []const u21, i: usize) usize {
    var j = i;
    while (j < text.len and isUrlChar(text[j])) : (j += 1) {}
    return j;
}

// ── 테스트 ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// UTF-8 리터럴을 codepoint 슬라이스로. 테스트 입력을 읽기 쉽게 쓰려고 둔다.
fn cps(comptime s: []const u8) []const u21 {
    const decoded = comptime blk: {
        var buf: [s.len]u21 = undefined;
        var n: usize = 0;
        var it = std.unicode.Utf8View.initComptime(s).iterator();
        while (it.nextCodepoint()) |c| {
            buf[n] = c;
            n += 1;
        }
        const fixed: [n]u21 = buf[0..n].*;
        break :blk fixed;
    };
    return &decoded;
}

/// 첫 매치의 문자열을 돌려준다 (없으면 null). 기대값을 눈으로 읽히게 하려는 helper.
fn firstMatch(comptime s: []const u8, buf: []u8) ?[]const u8 {
    const text = cps(s);
    const r = findFrom(text, 0) orelse return null;
    var n: usize = 0;
    for (text[r.start..r.end]) |c| {
        n += std.unicode.utf8Encode(c, buf[n..]) catch return null;
    }
    return buf[0..n];
}

fn expectFirst(comptime s: []const u8, expected: ?[]const u8) !void {
    var buf: [256]u8 = undefined;
    const got = firstMatch(s, &buf);
    if (expected) |e| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(e, got.?);
    } else {
        try testing.expect(got == null);
    }
}

test "ghostty 원본 테스트 케이스 — scheme 분기" {
    // 원본 `src/config/url.zig` 의 `test "url regex"` 에서 scheme 분기에 해당하는 것들.
    // 경로 분기 (`/tmp/test.txt` 등) 는 우리가 옮기지 않았으므로 제외했다.
    try expectFirst("hello https://example.com world", "https://example.com");
    try expectFirst("also match http://example.com non-secure links", "http://example.com");
    try expectFirst("match ftp://example.com ftp links", "ftp://example.com");
    try expectFirst("match file://example.com file links", "file://example.com");
    try expectFirst("match ssh://example.com ssh links", "ssh://example.com");
    try expectFirst("match git://example.com git links", "git://example.com");
    try expectFirst("match tel:+18005551234 tel links", "tel:+18005551234");
    try expectFirst("match tel://+12123456789 phone numbers", "tel://+12123456789");
    try expectFirst("match magnet:?xt=urn:btih:1234567890 magnet links", "magnet:?xt=urn:btih:1234567890");
    try expectFirst("match ipfs://QmSomeHashValue ipfs links", "ipfs://QmSomeHashValue");
    try expectFirst("match ipns://QmSomeHashValue ipns links", "ipns://QmSomeHashValue");
    try expectFirst("match gemini://example.com gemini links", "gemini://example.com");
    try expectFirst("match gopher://example.com gopher links", "gopher://example.com");
    try expectFirst("dot.http://example.com", "http://example.com");
    try expectFirst(
        "match with query url https://example.com?query=1&other=2 and more text.",
        "https://example.com?query=1&other=2",
    );
    try expectFirst(
        "weird characters https://example.com/~user/?query=1&other=2#hash and more",
        "https://example.com/~user/?query=1&other=2#hash",
    );
    try expectFirst("some file with https://google.com https://duckduckgo.com links.", "https://google.com");
}

test "괄호는 URL 의 일부일 때만 — 감싼 괄호는 뺀다" {
    // 원본 주석의 두 예가 이 규칙의 전부다.
    try expectFirst("https://example.com/foo(bar) more", "https://example.com/foo(bar)");
    try expectFirst("https://example.com/foo(bar)baz more", "https://example.com/foo(bar)baz");
    try expectFirst("Link inside (https://example.com) parens", "https://example.com");
    try expectFirst(
        "url with dashes [mode 2027](https://github.com/contour-terminal/terminal-unicode-core) for better unicode support",
        "https://github.com/contour-terminal/terminal-unicode-core",
    );
    // 대괄호도 같다 — 경로 안이면 포함, 감싸고 있으면 제외.
    try expectFirst("square brackets https://example.com/[foo] and more", "https://example.com/[foo]");
    try expectFirst(
        "[13]:TooManyStatements: TempFile#assign_temp_file_to_entity has approx 7 statements [https://example.com/docs/Too-Many-Statements.md]",
        "https://example.com/docs/Too-Many-Statements.md",
    );
    // 괄호 접미는 URL 문자 뒤에만 붙는다 — scheme 바로 뒤에 괄호면 본문이 없다.
    try expectFirst("https://(abc) nothing", null);
}

test "문장 끝의 마침표와 쉼표는 URL 이 아니다" {
    try expectFirst("Link period https://example.com. More text.", "https://example.com");
    try expectFirst("Link trailing comma https://example.com, more text.", "https://example.com");
    // 여러 개도 전부 벗긴다.
    try expectFirst("see https://example.com/a...", "https://example.com/a");
    // 벗기고 나면 본문이 없는 경우.
    try expectFirst("https://.", null);
    try expectFirst("https://", null);
    // 가운데 마침표는 그대로다.
    try expectFirst("https://example.com/a.b.c end", "https://example.com/a.b.c");
}

test "따옴표는 URL 문자가 아니다" {
    try expectFirst("Link in double quotes \"https://example.com\" and more", "https://example.com");
    try expectFirst("Link in single quotes 'https://example.com' and more", "https://example.com");
}

test "CJK 가 URL 에 딸려 들어가지 않는다 — `\\w` 를 ASCII 로 제한한 이유" {
    try expectFirst("링크 https://example.com 입니다", "https://example.com");
    try expectFirst("https://example.com한글", "https://example.com");
    try expectFirst("URL 없는 한글 줄입니다", null);
}

test "IPv6 주소와 포트" {
    try expectFirst("http://[::1]:8080/path and more", "http://[::1]:8080/path");
    try expectFirst("http://[2001:db8::1] end", "http://[2001:db8::1]");
    // 포트 자리에 숫자가 없으면 `:` 는 그냥 URL 문자로 이어진다.
    try expectFirst("http://[::1]:x end", "http://[::1]:x");
}

test "findAt — 그 자리를 덮는 URL 만" {
    const line = cps("go to https://example.com now");
    //              0123456^ start=6, end=6+19=25

    try testing.expectEqual(@as(?Range, null), findAt(line, 0));
    try testing.expectEqual(@as(?Range, null), findAt(line, 5)); // 바로 앞 공백
    try testing.expectEqual(Range{ .start = 6, .end = 25 }, findAt(line, 6).?); // 첫 글자
    try testing.expectEqual(Range{ .start = 6, .end = 25 }, findAt(line, 15).?); // 가운데
    try testing.expectEqual(Range{ .start = 6, .end = 25 }, findAt(line, 24).?); // 끝 글자
    try testing.expectEqual(@as(?Range, null), findAt(line, 25)); // 끝 바로 뒤 (배타적)
    try testing.expectEqual(@as(?Range, null), findAt(line, 26));
    try testing.expectEqual(@as(?Range, null), findAt(line, 999)); // 범위 밖
}

test "findAt — 한 줄에 URL 이 여럿" {
    const line = cps("a https://one.com b https://two.com c");
    const first = findAt(line, 5).?;
    const second = findAt(line, 25).?;
    try testing.expect(first.start != second.start);
    try testing.expectEqual(@as(usize, 2), first.start);
    try testing.expectEqual(@as(usize, 20), second.start);
    // 두 URL 사이의 공백은 어느 쪽도 아니다.
    try testing.expectEqual(@as(?Range, null), findAt(line, 19));
}

test "findFrom — 이어서 찾기" {
    const line = cps("a https://one.com b https://two.com c");
    const first = findFrom(line, 0).?;
    const second = findFrom(line, first.end).?;
    try testing.expectEqual(@as(usize, 2), first.start);
    try testing.expectEqual(@as(usize, 20), second.start);
    try testing.expectEqual(@as(?Range, null), findFrom(line, second.end));
}

test "빈 입력과 경계" {
    const empty: []const u21 = &.{};
    try testing.expectEqual(@as(?Range, null), findFrom(empty, 0));
    try testing.expectEqual(@as(?Range, null), findAt(empty, 0));
    // 줄 끝에 딱 맞는 URL.
    try expectFirst("https://a.io", "https://a.io");
    // scheme 이 줄 끝에서 잘린 경우.
    try expectFirst("http", null);
    try expectFirst("https:/", null);
}

test "Range helper" {
    const r = Range{ .start = 3, .end = 7 };
    try testing.expectEqual(@as(usize, 4), r.len());
    try testing.expect(!r.contains(2));
    try testing.expect(r.contains(3));
    try testing.expect(r.contains(6));
    try testing.expect(!r.contains(7));
}
