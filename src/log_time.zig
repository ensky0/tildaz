const std = @import("std");

pub const TimeFields = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    min: u8,
    sec: u8,
    ms: u16,
};

pub fn fallback() TimeFields {
    return .{ .year = 1970, .month = 1, .day = 1, .hour = 0, .min = 0, .sec = 0, .ms = 0 };
}

// 이전엔 여기 `fromUnixMillis` (unix ms + UTC offset → 필드 분해)가 있었으나, 세
// platform 모두 시스템 시간 함수로 로컬 시각을 직접 분해받는다 (Windows `GetLocalTime`
// → SYSTEMTIME, macOS/Linux `localtime_r` → struct tm). Linux 가 자체 TZif 파서로
// offset 을 구하던 유일한 소비자였고 localtime_r 로 전환되면서 dead code 가 되어 제거.
// `TimeFields` / `fallback` 만 세 platform 공통으로 남는다.
