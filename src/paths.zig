// 사용자 데이터 파일 (config_N.json / tildaz_N.log) 의 absolute 절대 경로 — OS
// 표준 위치를 따른다 (SPEC.md §11.1, AGENTS.md "platform native first").
// 로그 파일명은 config 파일명 (config_N.json) 과 같은 `이름_번호` 형식.
//
//   Windows: %APPDATA%\tildaz\config_N.json   (Microsoft 표준)
//            %APPDATA%\tildaz\tildaz_N.log
//   macOS:   $HOME/.config/tildaz/config_N.json (XDG, ghostty/alacritty 패턴)
//            $HOME/Library/Logs/tildaz_N.log    (Apple HIG — Console.app 인덱싱)
//   Linux:   $HOME/.config/tildaz/config_N.json (XDG)
//            $HOME/.local/state/tildaz/tildaz_N.log
//
// 모두 allocator-based — 호출처가 free 책임. 부모 디렉토리는 자동 생성
// (이미 존재하면 무시). About 다이얼로그 / Open Config & Log 단축키 /
// 모듈 (`config.zig` / `log.zig` / host 별 파일) 에서 사용.
//
// 로그 경로만은 buffer 기반 `logPathBuf` 가 단일 소스 (#282 G3) — 매 로그
// 라인마다 불리는 `log.zig` `writeRaw` 가 allocation-free 로 소비하고,
// allocator 기반 `logPath` (About / Open Log) 는 그 결과를 dupe 만 한다.
// 두 소비 계열이 같은 규칙을 쓰므로 'Open Log' 가 실제 기록 파일과
// 갈라질 수 없다.

const std = @import("std");
const builtin = @import("builtin");
const instance_context = @import("instance_context.zig");

pub fn configPath(allocator: std.mem.Allocator) ![]u8 {
    return configPathFor(allocator, instance_context.requireWorkerIndex());
}

pub fn configPathFor(allocator: std.mem.Allocator, index: u32) ![]u8 {
    const dir = try configDir(allocator);
    defer allocator.free(dir);
    try ensureDir(dir);
    const sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';
    return std.fmt.allocPrint(allocator, "{s}{c}config_{d}.json", .{ dir, sep, index });
}

/// 로그 경로 buffer 의 최소 크기. buffer 기반 / allocator 기반 두 소비 계열이
/// 같은 한도를 공유해야 한쪽만 성공하는 경로가 안 생긴다 (Windows worst case:
/// `%APPDATA%` UTF-16 → UTF-8 3 byte/unit 팽창 고려).
pub const LOG_PATH_MAX = 1024;

pub fn logPath(allocator: std.mem.Allocator) ![]u8 {
    var buf: [LOG_PATH_MAX]u8 = undefined;
    const path = logPathBuf(&buf) orelse return error.LogPathUnavailable;
    return allocator.dupe(u8, path);
}

/// 로그 파일 경로의 단일 소스 — allocation-free (#282 G3). 매 로그 라인마다
/// 불리는 `log.zig` `writeRaw` 가 직접 소비하므로 allocator 를 받지 않는다.
/// 부모 디렉토리 생성 포함 (macOS `~/Library/Logs` 는 default 존재라 생략).
/// env 부재 / buf 부족 시 null.
pub fn logPathBuf(buf: []u8) ?[]const u8 {
    return logPathBufFor(buf, instance_context.workerIndex() orelse 0);
}

pub fn logPathBufFor(buf: []u8, index: u32) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        const appdata = std.process.getenvW(std.unicode.utf8ToUtf16LeStringLiteral("APPDATA")) orelse return null;
        // utf16LeToUtf8 은 목적지 bounds-check 가 없다 — UTF-8 worst case
        // (3 byte/unit) 를 먼저 보장 (이전 log/windows.zig 구현의 잠재 overflow 해소).
        if (appdata.len * 3 > buf.len) return null;
        const appdata_len = std.unicode.utf16LeToUtf8(buf, appdata) catch return null;

        const dir_suffix = "\\tildaz";
        if (appdata_len + dir_suffix.len > buf.len) return null;
        @memcpy(buf[appdata_len..][0..dir_suffix.len], dir_suffix);
        const dir_end = appdata_len + dir_suffix.len;
        ensureDir(buf[0..dir_end]) catch {};

        const file = std.fmt.bufPrint(buf[dir_end..], "\\tildaz_{d}.log", .{index}) catch return null;
        return buf[0 .. dir_end + file.len];
    } else if (builtin.os.tag == .macos) {
        // `~/Library/Logs` 는 macOS default 로 항상 존재 — 디렉토리 생성 불필요.
        const home = std.posix.getenv("HOME") orelse return null;
        return std.fmt.bufPrint(buf, "{s}/Library/Logs/tildaz_{d}.log", .{ home, index }) catch return null;
    } else {
        const home = std.posix.getenv("HOME") orelse return null;
        const dir = std.fmt.bufPrint(buf, "{s}/.local/state/tildaz", .{home}) catch return null;
        ensureDir(dir) catch {};

        const file = std.fmt.bufPrint(buf[dir.len..], "/tildaz_{d}.log", .{index}) catch return null;
        return buf[0 .. dir.len + file.len];
    }
}

pub fn configDir(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        const appdata = try std.process.getEnvVarOwned(allocator, "APPDATA");
        defer allocator.free(appdata);
        return std.fmt.allocPrint(allocator, "{s}\\tildaz", .{appdata});
    }
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.config/tildaz", .{home});
}

pub fn ensureConfigDir(allocator: std.mem.Allocator) !void {
    const dir = try configDir(allocator);
    defer allocator.free(dir);
    try ensureDir(dir);
}

/// process ownership 파일은 사용자 config가 아닌 transient state다.
/// Linux는 login session runtime 경로를 우선하고, 나머지는 OS 표준 local
/// cache 경로를 사용한다. XDG_RUNTIME_DIR가 없는 Linux session은 XDG cache로
/// fallback한다.
pub fn lockDir(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        const local_appdata = try std.process.getEnvVarOwned(allocator, "LOCALAPPDATA");
        defer allocator.free(local_appdata);
        return std.fmt.allocPrint(allocator, "{s}\\tildaz\\run", .{local_appdata});
    }

    if (builtin.os.tag == .macos) {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);
        return std.fmt.allocPrint(allocator, "{s}/Library/Caches/TildaZ", .{home});
    }

    if (std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR") catch null) |runtime_dir| {
        defer allocator.free(runtime_dir);
        if (runtime_dir.len != 0) return linuxLockDir(allocator, runtime_dir, null, "");
    }
    if (std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME") catch null) |cache_dir| {
        defer allocator.free(cache_dir);
        if (cache_dir.len != 0) return linuxLockDir(allocator, null, cache_dir, "");
    }
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return linuxLockDir(allocator, null, null, home);
}

fn linuxLockDir(
    allocator: std.mem.Allocator,
    runtime_dir: ?[]const u8,
    cache_dir: ?[]const u8,
    home: []const u8,
) ![]u8 {
    if (runtime_dir) |dir| return std.fmt.allocPrint(allocator, "{s}/tildaz", .{dir});
    if (cache_dir) |dir| return std.fmt.allocPrint(allocator, "{s}/tildaz/run", .{dir});
    return std.fmt.allocPrint(allocator, "{s}/.cache/tildaz/run", .{home});
}

pub fn instanceLockPath(allocator: std.mem.Allocator, index: u32) ![]u8 {
    const dir = try lockDir(allocator);
    defer allocator.free(dir);
    try ensureDir(dir);
    const sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';
    return std.fmt.allocPrint(allocator, "{s}{c}instance{d}.lock", .{ dir, sep, index });
}

pub fn launcherLockPath(allocator: std.mem.Allocator) ![]u8 {
    const dir = try lockDir(allocator);
    defer allocator.free(dir);
    try ensureDir(dir);
    const sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';
    return std.fmt.allocPrint(allocator, "{s}{c}launcher.lock", .{ dir, sep });
}

/// 중간 단계 포함 재귀 디렉토리 생성 (`~/.local/state/tildaz` 같이 깊은 경로용).
/// 절대경로 component 는 leading `/` 를 유지해 makeDir 이 dirfd 무시하고 그대로
/// 생성. 다른 모듈 (`autostart/linux.zig`) 도 이걸 쓴다 — 자체 wrapper 금지 (#282 G7).
pub fn ensureDir(dir: []const u8) !void {
    try std.fs.cwd().makePath(dir);
}

fn currentPid() u32 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
}

/// #282 G6 — atomic write-if-changed. `path` 의 기존 내용이 `content` 와 같으면
/// 아무것도 쓰지 않고 `false`, 다르거나 파일이 없으면 같은 디렉토리의 temp 에
/// 쓰고 fsync 후 rename 으로 원자 교체하고 `true`. temp 를 대상과 같은 fs 에 두어
/// rename 원자성을 보장(부분 기록 파일이 남지 않음). mode 0o644 — desktop entry
/// / plist / 셸 확장 / cosmic 단축키 파일의 표준. autostart·instance_identity·
/// shell_extension·cosmic sync 의 5벌 복제를 대체.
pub fn writeFileIfChanged(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !bool {
    if (std.fs.openFileAbsolute(path, .{})) |existing| {
        defer existing.close();
        if (existing.readToEndAlloc(allocator, 4 * 1024 * 1024)) |old| {
            defer allocator.free(old);
            if (std.mem.eql(u8, old, content)) return false;
        } else |_| {}
    } else |_| {}

    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tildaz-{d}.tmp", .{ path, currentPid() });
    defer allocator.free(temp_path);
    errdefer std.fs.deleteFileAbsolute(temp_path) catch {};
    {
        const temp = try std.fs.createFileAbsolute(temp_path, .{ .truncate = true, .mode = 0o644 });
        defer temp.close();
        try temp.writeAll(content);
        try temp.sync();
    }
    try std.fs.renameAbsolute(temp_path, path);
    return true;
}

test "logPath (allocator) 와 logPathBuf (buffer) 가 같은 경로를 낸다" {
    // #282 G3 — 'Open Log' (allocator 계열) 와 실제 기록 (buffer 계열) 이
    // 다시 갈라지는 회귀를 차단. 테스트 host 에 HOME/APPDATA 가 없으면 skip.
    const allocator = std.testing.allocator;
    var buf: [LOG_PATH_MAX]u8 = undefined;
    const from_buf = logPathBuf(&buf) orelse return error.SkipZigTest;
    const allocated = try logPath(allocator);
    defer allocator.free(allocated);
    try std.testing.expectEqualStrings(from_buf, allocated);
}

test "logPathBufFor 가 OS 표준 위치와 worker index 를 따른다" {
    var buf: [LOG_PATH_MAX]u8 = undefined;
    const path = logPathBufFor(&buf, 7) orelse return error.SkipZigTest;
    try std.testing.expect(std.mem.endsWith(u8, path, switch (builtin.os.tag) {
        .windows => "\\tildaz\\tildaz_7.log",
        .macos => "/Library/Logs/tildaz_7.log",
        else => "/.local/state/tildaz/tildaz_7.log",
    }));
}

test "Linux lock directory follows runtime then cache fallback order" {
    const allocator = std.testing.allocator;

    const runtime = try linuxLockDir(allocator, "/run/user/1000", "/cache", "/home/test");
    defer allocator.free(runtime);
    try std.testing.expectEqualStrings("/run/user/1000/tildaz", runtime);

    const cache = try linuxLockDir(allocator, null, "/cache", "/home/test");
    defer allocator.free(cache);
    try std.testing.expectEqualStrings("/cache/tildaz/run", cache);

    const home = try linuxLockDir(allocator, null, null, "/home/test");
    defer allocator.free(home);
    try std.testing.expectEqualStrings("/home/test/.cache/tildaz/run", home);
}
