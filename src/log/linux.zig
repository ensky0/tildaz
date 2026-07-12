// Linux log impl — system-dependent pieces only. Shared formatting / file IO
// lives in `log.zig`. Log file follows XDG state:
// `~/.local/state/tildaz/tildazN.log`.

const std = @import("std");
const log_time = @import("../log_time.zig");
const instance_context = @import("../instance_context.zig");

pub const TimeFields = log_time.TimeFields;

pub fn currentLocalTime() TimeFields {
    const ms_total = std.time.milliTimestamp();
    if (ms_total < 0) return log_time.fallback();

    const unix_secs = @divTrunc(ms_total, 1000);
    const offset = currentUtcOffsetSeconds(unix_secs) catch 0;
    return log_time.fromUnixMillis(ms_total, offset);
}

pub fn currentPid() u64 {
    return @intCast(std.os.linux.getpid());
}

pub fn resolvePath(buf: []u8) ?[]const u8 {
    const home_slice = std.posix.getenv("HOME") orelse return null;
    const dir_suffix = "/.local/state/tildaz";
    if (home_slice.len + dir_suffix.len + 32 >= buf.len) return null;

    @memcpy(buf[0..home_slice.len], home_slice);
    @memcpy(buf[home_slice.len..][0..dir_suffix.len], dir_suffix);
    const dir_end = home_slice.len + dir_suffix.len;

    ensureDir(buf[0..dir_end]) catch {};

    const suffix = std.fmt.bufPrint(buf[dir_end..], "/tildaz{d}.log", .{instance_context.workerIndex() orelse 0}) catch return null;
    return buf[0 .. dir_end + suffix.len];
}

fn ensureDir(dir: []const u8) !void {
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            if (std.fs.path.dirname(dir)) |parent| {
                try ensureDir(parent);
                try std.fs.makeDirAbsolute(dir);
                return;
            }
            return err;
        },
        else => return err,
    };
}

// #282 D6 — TZif 파일 바이트를 프로세스당 한 번만 읽어 캐시한다. 이전엔 로그 한
// 줄마다 /etc/localtime 등을 open + 최대 128KB read 후 파싱해 (macOS localtime_r /
// Windows GetLocalTime 는 시스템 캐시 저비용) 로그 경로 비용이 platform 간 컸다.
// bytes 는 loaded=true 이후 불변이라, mutex 로 최초 로드만 직렬화하고 이후 parse 는
// lock 없이 in-memory 로 수행(offset 은 DST 전이에 따라 달라지므로 매 줄 재계산하되
// I/O 없이). loaded 실패 시에도 재시도 안 해(매 줄 I/O 방지) offset 0 fallback.
var g_tzif_cache: struct {
    mutex: std.Thread.Mutex = .{},
    loaded: bool = false,
    len: usize = 0,
    buf: [128 * 1024]u8 = undefined,
} = .{};

fn cachedTzifBytes() ?[]const u8 {
    g_tzif_cache.mutex.lock();
    defer g_tzif_cache.mutex.unlock();
    if (!g_tzif_cache.loaded) {
        g_tzif_cache.loaded = true;
        g_tzif_cache.len = loadTzifFile(&g_tzif_cache.buf) orelse 0;
    }
    if (g_tzif_cache.len == 0) return null;
    return g_tzif_cache.buf[0..g_tzif_cache.len];
}

fn loadTzifFile(buf: []u8) ?usize {
    if (std.posix.getenv("TZ")) |tz| {
        if (tz.len > 0) {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (tzifPathFromEnv(tz, &path_buf)) |path| {
                if (readFileInto(path, buf)) |n| return n;
            }
        }
    }
    return readFileInto("/etc/localtime", buf);
}

fn readFileInto(path: []const u8, buf: []u8) ?usize {
    var file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    return file.readAll(buf) catch null;
}

fn currentUtcOffsetSeconds(unix_secs: i64) !i32 {
    const bytes = cachedTzifBytes() orelse return 0;
    return utcOffsetFromTzif(bytes, unix_secs);
}

fn tzifPathFromEnv(tz_raw: []const u8, buf: []u8) ?[]const u8 {
    const tz = if (tz_raw[0] == ':') tz_raw[1..] else tz_raw;
    if (tz.len == 0) return null;
    if (tz[0] == '/') return tz;

    const prefix = "/usr/share/zoneinfo/";
    if (prefix.len + tz.len > buf.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..tz.len], tz);
    return buf[0 .. prefix.len + tz.len];
}

const TzifHeader = struct {
    version: u8,
    ttisgmtcnt: u32,
    ttisstdcnt: u32,
    leapcnt: u32,
    timecnt: u32,
    typecnt: u32,
    charcnt: u32,
};

fn utcOffsetFromTzif(data: []const u8, unix_secs: i64) !i32 {
    var header = try readTzifHeader(data, 0);
    var block_offset = @as(usize, 44);
    var time_size = @as(usize, 4);
    var footer: ?[]const u8 = null;

    if (header.version == '2' or header.version == '3' or header.version == '4') {
        const first_block_len = try tzifDataBlockLen(header, 4);
        const second_header_offset = try addLen(block_offset, first_block_len);
        header = try readTzifHeader(data, second_header_offset);
        block_offset = try addLen(second_header_offset, 44);
        time_size = 8;
        // #282 D2 — v2+ data block 뒤의 footer (`\n<POSIX TZ string>\n`) 추출.
        const v2_block_len = try tzifDataBlockLen(header, 8);
        const footer_start = try addLen(block_offset, v2_block_len);
        footer = extractFooter(data, footer_start);
    }

    if (block_offset > data.len) return error.InvalidTzif;
    const block = data[block_offset..];

    // 마지막 transition 이하 구간은 명시 transition 표로 offset 결정.
    const trans_offset = try utcOffsetFromTzifBlock(block, header, time_size, unix_secs);

    // #282 D2 (RFC 9636 §3.3) — v2+ data block 의 마지막 명시 transition *이후* 시각은
    // footer 의 POSIX TZ string 으로 DST 를 계산해야 한다. slim 포맷 tzdata(Debian
    // bookworm / Ubuntu 22.04·24.04 등)는 마지막 transition 이 과거라, footer 없이
    // 마지막 transition 의 offset 을 그대로 쓰면 현재 DST 를 최대 1시간 틀리게 낸다.
    // transition 이 없거나 unix_secs 가 마지막 transition 이상이면 footer 로 계산하되,
    // footer 파싱 실패 시 transition offset 으로 안전하게 fallback.
    const timecnt: usize = @intCast(header.timecnt);
    const in_footer_region = blk: {
        if (timecnt == 0) break :blk true;
        const times_ok = mulLen(timecnt, time_size) catch break :blk false;
        if (times_ok > block.len) break :blk false;
        const last_t = readTransitionTime(block[(timecnt - 1) * time_size ..], time_size);
        break :blk unix_secs >= last_t;
    };
    if (in_footer_region) {
        if (footer) |f| {
            if (parsePosixTz(f)) |tz| return offsetFromPosixTz(tz, unix_secs);
        }
    }
    return trans_offset;
}

/// v2+ data block 뒤의 footer 문자열. `\n<TZ string>\n` 형식에서 두 개행 사이를
/// 반환. 개행이 없거나 빈 문자열이면 null.
fn extractFooter(data: []const u8, footer_start: usize) ?[]const u8 {
    if (footer_start >= data.len or data[footer_start] != '\n') return null;
    var end = footer_start + 1;
    while (end < data.len and data[end] != '\n') end += 1;
    if (end <= footer_start + 1) return null;
    return data[footer_start + 1 .. end];
}

/// POSIX TZ string 파싱 결과 (RFC 9636 §3.3.1). 모든 offset 은 *east-positive UTC
/// offset* (ttinfo utoff 와 같은 부호 — POSIX 표기는 west-positive 라 부호 반전).
const PosixTz = struct {
    std_east: i32,
    dst_east: i32,
    has_dst: bool,
    start: TzRule = .{},
    end: TzRule = .{},
};

const TzRule = struct {
    kind: enum { month_week_day, julian_no_leap, day_of_year } = .month_week_day,
    mon: u8 = 0,
    week: u8 = 0,
    wday: u8 = 0,
    n: u16 = 0,
    time: i32 = 2 * 3600, // 자정 이후 초, 기본 02:00 (부호·24h 초과 허용)
};

fn tzParseInt(s: []const u8, i: *usize) ?i32 {
    const start = i.*;
    var v: i32 = 0;
    while (i.* < s.len and s[i.*] >= '0' and s[i.*] <= '9') : (i.* += 1) {
        v = v * 10 + @as(i32, s[i.*] - '0');
    }
    return if (i.* > start) v else null;
}

/// abbreviation (알파벳 연속 또는 `<...>`) skip. 값은 안 씀.
fn tzSkipAbbrev(s: []const u8, i: *usize) bool {
    if (i.* < s.len and s[i.*] == '<') {
        i.* += 1;
        while (i.* < s.len and s[i.*] != '>') i.* += 1;
        if (i.* >= s.len) return false;
        i.* += 1;
        return true;
    }
    const start = i.*;
    while (i.* < s.len and ((s[i.*] >= 'A' and s[i.*] <= 'Z') or (s[i.*] >= 'a' and s[i.*] <= 'z'))) i.* += 1;
    return i.* > start;
}

/// `[+|-]hh[:mm[:ss]]` → POSIX 초 (west-positive). 부호 그대로.
fn tzParseOffset(s: []const u8, i: *usize) ?i32 {
    var neg = false;
    if (i.* < s.len and (s[i.*] == '+' or s[i.*] == '-')) {
        neg = s[i.*] == '-';
        i.* += 1;
    }
    const hh = tzParseInt(s, i) orelse return null;
    var secs: i32 = hh * 3600;
    if (i.* < s.len and s[i.*] == ':') {
        i.* += 1;
        const mm = tzParseInt(s, i) orelse return null;
        secs += mm * 60;
        if (i.* < s.len and s[i.*] == ':') {
            i.* += 1;
            const ss = tzParseInt(s, i) orelse return null;
            secs += ss;
        }
    }
    return if (neg) -secs else secs;
}

fn tzParseRule(s: []const u8, i: *usize) ?TzRule {
    if (i.* >= s.len) return null;
    var r = TzRule{};
    switch (s[i.*]) {
        'M' => {
            i.* += 1;
            const mon = tzParseInt(s, i) orelse return null;
            if (i.* >= s.len or s[i.*] != '.') return null;
            i.* += 1;
            const week = tzParseInt(s, i) orelse return null;
            if (i.* >= s.len or s[i.*] != '.') return null;
            i.* += 1;
            const wday = tzParseInt(s, i) orelse return null;
            if (mon < 1 or mon > 12 or week < 1 or week > 5 or wday < 0 or wday > 6) return null;
            r = .{ .kind = .month_week_day, .mon = @intCast(mon), .week = @intCast(week), .wday = @intCast(wday) };
        },
        'J' => {
            i.* += 1;
            const n = tzParseInt(s, i) orelse return null;
            if (n < 1 or n > 365) return null;
            r = .{ .kind = .julian_no_leap, .n = @intCast(n) };
        },
        else => {
            const n = tzParseInt(s, i) orelse return null;
            if (n < 0 or n > 365) return null;
            r = .{ .kind = .day_of_year, .n = @intCast(n) };
        },
    }
    r.time = 2 * 3600;
    if (i.* < s.len and s[i.*] == '/') {
        i.* += 1;
        r.time = tzParseOffset(s, i) orelse return null;
    }
    return r;
}

/// POSIX TZ string 파싱. DST 규칙(`,start,end`)이 없는 no-DST zone 도 지원.
/// 규칙 계산이 불가능한 형태(rule 없는 DST 등)는 null 반환 → caller 가 fallback.
fn parsePosixTz(s: []const u8) ?PosixTz {
    var i: usize = 0;
    if (!tzSkipAbbrev(s, &i)) return null;
    const std_val = tzParseOffset(s, &i) orelse return null;
    var tz = PosixTz{ .std_east = -std_val, .dst_east = -std_val, .has_dst = false };
    if (i >= s.len) return tz; // no DST — 고정 offset
    if (!tzSkipAbbrev(s, &i)) return null;
    tz.has_dst = true;
    if (i < s.len and s[i] != ',') {
        const dst_val = tzParseOffset(s, &i) orelse return null;
        tz.dst_east = -dst_val;
    } else {
        tz.dst_east = tz.std_east + 3600; // 기본: 표준시보다 1시간 앞
    }
    if (i >= s.len or s[i] != ',') return null; // DST 인데 규칙 없음 — 계산 불가
    i += 1;
    tz.start = tzParseRule(s, &i) orelse return null;
    if (i >= s.len or s[i] != ',') return null;
    i += 1;
    tz.end = tzParseRule(s, &i) orelse return null;
    return tz;
}

fn offsetFromPosixTz(tz: PosixTz, unix_secs: i64) i32 {
    if (!tz.has_dst) return tz.std_east;
    // 현재 시각의 대략 local 연도로 그 해 DST start/end 전이의 UTC 시각을 계산.
    const approx_local = unix_secs + tz.std_east;
    const civ = civilFromDays(@divFloor(approx_local, 86400));
    const start_utc = ruleTransitionUtc(tz.start, civ.y, tz.std_east); // start 는 표준시 기준
    const end_utc = ruleTransitionUtc(tz.end, civ.y, tz.dst_east); // end 는 DST 시 기준
    const in_dst = if (start_utc <= end_utc)
        (unix_secs >= start_utc and unix_secs < end_utc)
    else
        (unix_secs >= start_utc or unix_secs < end_utc); // 남반구 (연말 걸침)
    return if (in_dst) tz.dst_east else tz.std_east;
}

fn ruleTransitionUtc(r: TzRule, year: i64, east_at_transition: i32) i64 {
    const local_days = ruleDays(r, year);
    const local_secs = local_days * 86400 + r.time;
    return local_secs - east_at_transition; // UTC = local - east_offset
}

fn ruleDays(r: TzRule, year: i64) i64 {
    switch (r.kind) {
        .day_of_year => return daysFromCivil(year, 1, 1) + @as(i64, r.n),
        .julian_no_leap => {
            // Jn: 1..365, Feb 29 미포함 → 비윤년 달력의 month/day.
            const cum = [_]u16{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
            var m: usize = 12;
            const n = r.n;
            while (m > 1 and cum[m - 1] >= n) m -= 1;
            const d = n - cum[m - 1];
            return daysFromCivil(year, @intCast(m), @intCast(d));
        },
        .month_week_day => {
            const first = daysFromCivil(year, r.mon, 1);
            const first_wd: i64 = @mod(first + 4, 7); // 0=Sun
            var day: i64 = 1 + @mod(@as(i64, r.wday) - first_wd + 7, 7);
            if (r.week >= 2) {
                day += @as(i64, r.week - 1) * 7;
                if (r.week == 5) {
                    const dim = daysInMonth(year, r.mon);
                    while (day > dim) day -= 7;
                }
            }
            return daysFromCivil(year, r.mon, @intCast(day));
        },
    }
}

fn daysInMonth(year: i64, m: u8) i64 {
    const leap = (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (leap) @as(i64, 29) else 28,
        else => 30,
    };
}

/// days since 1970-01-01 (Howard Hinnant). m: 1..12, d: 1..31.
fn daysFromCivil(y_in: i64, m: u8, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400; // [0, 399]
    const mm: i64 = m;
    const doy = @divTrunc(153 * (if (mm > 2) mm - 3 else mm + 9) + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

const Civil = struct { y: i64, m: u8, d: u8 };

/// days since 1970-01-01 → civil date (Howard Hinnant).
fn civilFromDays(z_in: i64) Civil {
    const z = z_in + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365); // [0, 399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100)); // [0, 365]
    const mp = @divTrunc(5 * doy + 2, 153); // [0, 11]
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1; // [1, 31]
    const m = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    return .{ .y = if (m <= 2) y + 1 else y, .m = @intCast(m), .d = @intCast(d) };
}

fn utcOffsetFromTzifBlock(block: []const u8, header: TzifHeader, time_size: usize, unix_secs: i64) !i32 {
    if (header.typecnt == 0) return error.InvalidTzif;

    const timecnt: usize = @intCast(header.timecnt);
    const typecnt: usize = @intCast(header.typecnt);
    const times_len = try mulLen(timecnt, time_size);
    const indices_offset = times_len;
    const types_offset = try addLen(indices_offset, timecnt);
    const types_len = try mulLen(typecnt, 6);
    const min_len = try addLen(types_offset, types_len);
    if (min_len > block.len) return error.InvalidTzif;

    var type_index: usize = defaultTypeIndex(block[types_offset .. types_offset + types_len], typecnt);
    if (timecnt > 0) {
        var selected_transition: ?usize = null;
        for (0..timecnt) |i| {
            const transition = readTransitionTime(block[i * time_size ..], time_size);
            if (transition > unix_secs) break;
            selected_transition = i;
        }
        if (selected_transition) |i| {
            const raw_index = block[indices_offset + i];
            if (raw_index >= typecnt) return error.InvalidTzif;
            type_index = raw_index;
        }
    }

    return readI32BE(block[types_offset + type_index * 6 ..][0..4]);
}

fn defaultTypeIndex(types: []const u8, typecnt: usize) usize {
    for (0..typecnt) |i| {
        if (types[i * 6 + 4] == 0) return i;
    }
    return 0;
}

fn readTransitionTime(bytes: []const u8, time_size: usize) i64 {
    return if (time_size == 8)
        readI64BE(bytes[0..8])
    else
        readI32BE(bytes[0..4]);
}

fn readTzifHeader(data: []const u8, offset: usize) !TzifHeader {
    if (offset + 44 > data.len) return error.InvalidTzif;
    const h = data[offset..][0..44];
    if (!std.mem.eql(u8, h[0..4], "TZif")) return error.InvalidTzif;
    return .{
        .version = h[4],
        .ttisgmtcnt = readU32BE(h[20..24]),
        .ttisstdcnt = readU32BE(h[24..28]),
        .leapcnt = readU32BE(h[28..32]),
        .timecnt = readU32BE(h[32..36]),
        .typecnt = readU32BE(h[36..40]),
        .charcnt = readU32BE(h[40..44]),
    };
}

fn tzifDataBlockLen(header: TzifHeader, time_size: usize) !usize {
    var len: usize = 0;
    len = try addLen(len, try mulLen(@intCast(header.timecnt), time_size));
    len = try addLen(len, @intCast(header.timecnt));
    len = try addLen(len, try mulLen(@intCast(header.typecnt), 6));
    len = try addLen(len, @intCast(header.charcnt));
    len = try addLen(len, try mulLen(@intCast(header.leapcnt), time_size + 4));
    len = try addLen(len, @intCast(header.ttisstdcnt));
    len = try addLen(len, @intCast(header.ttisgmtcnt));
    return len;
}

fn addLen(a: usize, b: usize) !usize {
    return std.math.add(usize, a, b) catch error.InvalidTzif;
}

fn mulLen(a: usize, b: usize) !usize {
    return std.math.mul(usize, a, b) catch error.InvalidTzif;
}

fn readU32BE(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .big);
}

// --- #282 D2 tests ---

fn tzOffsetAt(tz_str: []const u8, y: i64, mo: u8, d: u8, hh: u8) i32 {
    const days = daysFromCivil(y, mo, d);
    const unix_secs = days * 86400 + @as(i64, hh) * 3600;
    const tz = parsePosixTz(tz_str).?;
    return offsetFromPosixTz(tz, unix_secs);
}

test "civil/day round-trip (Howard Hinnant)" {
    const T = std.testing;
    try T.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try T.expectEqual(@as(i64, 4), @mod(daysFromCivil(1970, 1, 1) + 4, 7)); // Thursday
    const c = civilFromDays(0);
    try T.expectEqual(@as(i64, 1970), c.y);
    try T.expectEqual(@as(u8, 1), c.m);
    try T.expectEqual(@as(u8, 1), c.d);
    const c2 = civilFromDays(daysFromCivil(2026, 7, 12));
    try T.expectEqual(@as(i64, 2026), c2.y);
    try T.expectEqual(@as(u8, 7), c2.m);
    try T.expectEqual(@as(u8, 12), c2.d);
}

test "parsePosixTz: no-DST 고정 offset" {
    const T = std.testing;
    const kst = parsePosixTz("KST-9").?; // 한국 — UTC+9
    try T.expect(!kst.has_dst);
    try T.expectEqual(@as(i32, 9 * 3600), kst.std_east);
    // 여름/겨울 무관 +9
    try T.expectEqual(@as(i32, 9 * 3600), tzOffsetAt("KST-9", 2026, 1, 15, 12));
    try T.expectEqual(@as(i32, 9 * 3600), tzOffsetAt("KST-9", 2026, 7, 15, 12));
    // <+05>-5 형식
    try T.expectEqual(@as(i32, 5 * 3600), tzOffsetAt("<+05>-5", 2026, 7, 1, 0));
}

test "offsetFromPosixTz: 북반구 America/New_York (EST5EDT,M3.2.0,M11.1.0)" {
    const T = std.testing;
    const ny = "EST5EDT,M3.2.0,M11.1.0";
    // 겨울(EST -5) / 여름(EDT -4)
    try T.expectEqual(@as(i32, -5 * 3600), tzOffsetAt(ny, 2026, 1, 15, 12)); // Jan → EST
    try T.expectEqual(@as(i32, -4 * 3600), tzOffsetAt(ny, 2026, 7, 15, 12)); // Jul → EDT
    // 전이 경계: 2026 봄 = 3월 2번째 일요일(3/8), 2:00 EST → 07:00 UTC 이후 EDT
    try T.expectEqual(@as(i32, -5 * 3600), tzOffsetAt(ny, 2026, 3, 8, 6)); // 06:00 UTC = 아직 EST
    try T.expectEqual(@as(i32, -4 * 3600), tzOffsetAt(ny, 2026, 3, 8, 8)); // 08:00 UTC = EDT
    // 가을 = 11월 1번째 일요일(11/1), 2:00 EDT → 06:00 UTC 이후 EST
    try T.expectEqual(@as(i32, -4 * 3600), tzOffsetAt(ny, 2026, 11, 1, 5)); // 05:00 UTC = 아직 EDT
    try T.expectEqual(@as(i32, -5 * 3600), tzOffsetAt(ny, 2026, 11, 1, 7)); // 07:00 UTC = EST
}

test "offsetFromPosixTz: Europe/London (GMT0BST,M3.5.0/1,M10.5.0)" {
    const T = std.testing;
    const lon = "GMT0BST,M3.5.0/1,M10.5.0";
    try T.expectEqual(@as(i32, 0), tzOffsetAt(lon, 2026, 1, 15, 12)); // 겨울 GMT
    try T.expectEqual(@as(i32, 3600), tzOffsetAt(lon, 2026, 7, 15, 12)); // 여름 BST +1
    // 마지막 주 일요일(week=5) 계산 확인 — 2026 3월 마지막 일요일 = 3/29
    try T.expectEqual(@as(i32, 3600), tzOffsetAt(lon, 2026, 3, 30, 12)); // 전환 후 BST
    try T.expectEqual(@as(i32, 0), tzOffsetAt(lon, 2026, 3, 28, 12)); // 전환 전 GMT
}

test "offsetFromPosixTz: 남반구 (연말 걸침) — America/Santiago 유사" {
    const T = std.testing;
    // 남반구: DST 가 연말~연초 (start 후반, end 전반). CLST-3 / CLT-4 유사 형태.
    // std=CLT(-4), dst=CLST(-3), start 9월 첫 일요일, end 4월 첫 일요일.
    const cl = "CLT4CLST,M9.1.0/0,M4.1.0/0";
    try T.expectEqual(@as(i32, -3 * 3600), tzOffsetAt(cl, 2026, 1, 15, 12)); // 1월 = 여름(남반구) DST
    try T.expectEqual(@as(i32, -4 * 3600), tzOffsetAt(cl, 2026, 6, 15, 12)); // 6월 = 겨울 표준
    try T.expectEqual(@as(i32, -3 * 3600), tzOffsetAt(cl, 2026, 12, 15, 12)); // 12월 = 다시 DST
}

test "utcOffsetFromTzif: slim TZif(마지막 transition 과거) 는 footer 로 DST 계산" {
    const T = std.testing;
    // 최소 v2 TZif 구성: transition 0개, typecnt 1(UT offset 임의), footer=EST5EDT rule.
    // in_footer_region(timecnt==0) → footer 로 여름 EDT(-4)/겨울 EST(-5) 결정.
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    // helper: v1+v2 헤더/블록. timecnt=0, typecnt=1, charcnt=1.
    for (0..2) |ver_pass| {
        try buf.appendSlice(a, "TZif");
        try buf.append(a, if (ver_pass == 0) '2' else '2'); // version '2'
        try buf.appendSlice(a, &[_]u8{0} ** 15); // reserved(15)
        // counts: isutcnt,isstdcnt,leapcnt,timecnt,typecnt,charcnt (u32 BE each)
        const counts = [_]u32{ 0, 0, 0, 0, 1, 1 };
        for (counts) |c| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, c, .big);
            try buf.appendSlice(a, &b);
        }
        // data block: times(0) + indices(0) + ttinfo(1×6: utoff i32=-18000, isdst u8=0, desigidx u8=0)
        var off: [4]u8 = undefined;
        std.mem.writeInt(i32, &off, -18000, .big);
        try buf.appendSlice(a, &off);
        try buf.append(a, 0); // isdst
        try buf.append(a, 0); // desigidx
        try buf.append(a, 0); // charcnt(1): "\0"
    }
    // footer: \nEST5EDT,M3.2.0,M11.1.0\n
    try buf.appendSlice(a, "\nEST5EDT,M3.2.0,M11.1.0\n");

    const jan = daysFromCivil(2026, 1, 15) * 86400 + 12 * 3600;
    const jul = daysFromCivil(2026, 7, 15) * 86400 + 12 * 3600;
    try T.expectEqual(@as(i32, -5 * 3600), try utcOffsetFromTzif(buf.items, jan)); // 겨울 EST
    try T.expectEqual(@as(i32, -4 * 3600), try utcOffsetFromTzif(buf.items, jul)); // 여름 EDT (footer 없으면 -18000 고정이었을 것)
}

fn readI32BE(bytes: *const [4]u8) i32 {
    return @bitCast(readU32BE(bytes));
}

fn readI64BE(bytes: *const [8]u8) i64 {
    return std.mem.readInt(i64, bytes, .big);
}
