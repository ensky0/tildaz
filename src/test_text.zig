//! 테스트 입력용 긴 문자열 ([#820](https://github.com/ensky0/tildaz/issues/820)).
//!
//! Zig 0.17 이 배열 반복 (`"x" ** 5000`) 을 없앴다. 배열은 `@splat` 으로 바꾸면 되지만, 문자열은
//! 두 가지가 걸린다.
//!   - `@splat` 은 한 원소만 반복한다. `"셸"` · `"경로/"` 처럼 여러 바이트를 반복하지 못한다.
//!   - `std.simd.repeat` 는 벡터를 만든다. 수천 바이트짜리를 컴파일 때 만들면 분기 한도
//!     (`@setEvalBranchQuota` 기본 1,000) 를 넘는다 (0.17 실측).
//! 그래서 여기서 한 번 만든다. 결과가 `*const [N]u8` 이라 예전 `"x" ** N` 과 같은 타입이고,
//! `++` 로 이어 붙이거나 `[]const u8` 인자로 그대로 넘긴다.

/// `text` 를 `count` 번 이어 붙인 문자열. 컴파일 때 만든다.
pub fn repeat(comptime text: []const u8, comptime count: usize) *const [text.len * count]u8 {
    return &Repeated(text, count).value;
}

/// 컴파일 때 만든 값은 타입의 `const` 에 둬야 런타임 함수가 그 주소를 돌려줄 수 있다.
fn Repeated(comptime text: []const u8, comptime count: usize) type {
    return struct {
        const value: [text.len * count]u8 = blk: {
            @setEvalBranchQuota(1000 + count * 4);
            var buf: [text.len * count]u8 = undefined;
            for (0..count) |i| @memcpy(buf[i * text.len ..][0..text.len], text);
            break :blk buf;
        };
    };
}

test "repeat 는 여러 바이트 글자도 그대로 이어 붙인다" {
    const std = @import("std");
    try std.testing.expectEqualStrings("셸셸셸", repeat("셸", 3));
    try std.testing.expectEqualStrings("/a/x/x/", "/a/" ++ repeat("x/", 2));
    try std.testing.expectEqual(@as(usize, 1200 * "가".len), repeat("가", 1200).len);
}
