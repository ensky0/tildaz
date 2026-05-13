// Linux log impl — system-dependent pieces only. Shared formatting / file IO
// lives in `log.zig`. Log file follows XDG state:
// `~/.local/state/tildaz/tildaz.log`.

const std = @import("std");
const log_time = @import("../log_time.zig");

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
    const file_suffix = "/tildaz.log";
    if (home_slice.len + dir_suffix.len + file_suffix.len >= buf.len) return null;

    @memcpy(buf[0..home_slice.len], home_slice);
    @memcpy(buf[home_slice.len..][0..dir_suffix.len], dir_suffix);
    const dir_end = home_slice.len + dir_suffix.len;

    std.fs.makeDirAbsolute(buf[0..dir_end]) catch {};

    @memcpy(buf[dir_end..][0..file_suffix.len], file_suffix);
    return buf[0 .. dir_end + file_suffix.len];
}

fn currentUtcOffsetSeconds(unix_secs: i64) !i32 {
    if (std.posix.getenv("TZ")) |tz| {
        if (tz.len > 0) {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (tzifPathFromEnv(tz, &path_buf)) |path| {
                if (utcOffsetFromTzifPath(path, unix_secs)) |offset| return offset else |_| {}
            }
        }
    }
    return utcOffsetFromTzifPath("/etc/localtime", unix_secs);
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

fn utcOffsetFromTzifPath(path: []const u8, unix_secs: i64) !i32 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var buf: [128 * 1024]u8 = undefined;
    const len = try file.readAll(&buf);
    return utcOffsetFromTzif(buf[0..len], unix_secs);
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

    if (header.version == '2' or header.version == '3' or header.version == '4') {
        const first_block_len = try tzifDataBlockLen(header, 4);
        const second_header_offset = try addLen(block_offset, first_block_len);
        header = try readTzifHeader(data, second_header_offset);
        block_offset = try addLen(second_header_offset, 44);
        time_size = 8;
    }

    if (block_offset > data.len) return error.InvalidTzif;
    return utcOffsetFromTzifBlock(data[block_offset..], header, time_size, unix_secs);
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

fn readI32BE(bytes: *const [4]u8) i32 {
    return @bitCast(readU32BE(bytes));
}

fn readI64BE(bytes: *const [8]u8) i64 {
    return std.mem.readInt(i64, bytes, .big);
}
