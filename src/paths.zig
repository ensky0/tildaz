// 사용자 데이터 파일 (config_N.json / tildaz_N.log) 의 absolute 절대 경로 — OS
// 표준 위치를 따른다 (SPEC.md §11.1, AGENTS.md "platform native first").
// 로그 파일명은 config 파일명 (config_N.json) 과 같은 `이름_번호` 형식.
//
//   Windows: %APPDATA%\tildaz\config_N.json   (Microsoft 표준)
//            %APPDATA%\tildaz\tildaz_N.log
//   macOS:   $XDG_CONFIG_HOME/tildaz/config_N.json (fallback: $HOME/.config)
//            $HOME/Library/Logs/tildaz_N.log    (Apple HIG — Console.app 인덱싱)
//   Linux:   $XDG_CONFIG_HOME/tildaz/config_N.json (fallback: $HOME/.config)
//            $XDG_STATE_HOME/tildaz/tildaz_N.log (fallback: $HOME/.local/state)
//
// 모두 allocator-based — 호출처가 free 책임. 부모 디렉토리는 자동 생성
// (이미 존재하면 무시). config 모듈과 log 모듈에서 사용한다. 로그 경로는
// `log.zig`가 프로세스 수명 동안 한 번만 보관하고, 기록 / About / Open Log가
// 그 값을 함께 써 실제 파일과 사용자에게 보이는 경로가 갈라지지 않는다.

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

pub fn logPath(allocator: std.mem.Allocator) ![]u8 {
    return logPathFor(allocator, instance_context.workerIndex() orelse 0);
}

pub fn logPathFor(allocator: std.mem.Allocator, index: u32) ![]u8 {
    const dir = try logDir(allocator);
    defer allocator.free(dir);
    try ensureDir(dir);
    return logPathFromDir(allocator, dir, index);
}

fn logDir(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        const appdata = try std.process.getEnvVarOwned(allocator, "APPDATA");
        defer allocator.free(appdata);
        return std.fmt.allocPrint(allocator, "{s}\\tildaz", .{appdata});
    } else if (builtin.os.tag == .macos) {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);
        return std.fmt.allocPrint(allocator, "{s}/Library/Logs", .{home});
    } else {
        const base = try stateHome(allocator);
        defer allocator.free(base);
        return std.fmt.allocPrint(allocator, "{s}/tildaz", .{base});
    }
}

fn logPathFromDir(allocator: std.mem.Allocator, dir: []const u8, index: u32) ![]u8 {
    const sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';
    return std.fmt.allocPrint(allocator, "{s}{c}tildaz_{d}.log", .{ dir, sep, index });
}

pub fn configDir(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        const appdata = try std.process.getEnvVarOwned(allocator, "APPDATA");
        defer allocator.free(appdata);
        return std.fmt.allocPrint(allocator, "{s}\\tildaz", .{appdata});
    }
    const base = try configHome(allocator);
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s}/tildaz", .{base});
}

/// Linux · macOS 사용자 config base. 유효한 절대 XDG_CONFIG_HOME을 우선하고
/// unset/empty/relative 값은 XDG 기본인 $HOME/.config로 fallback한다.
pub fn configHome(allocator: std.mem.Allocator) ![]u8 {
    return xdgHome(allocator, "XDG_CONFIG_HOME", "/.config");
}

/// Linux 사용자 state base. log가 여기에 tildaz/를 붙인다.
fn stateHome(allocator: std.mem.Allocator) ![]u8 {
    return xdgHome(allocator, "XDG_STATE_HOME", "/.local/state");
}

fn xdgHome(allocator: std.mem.Allocator, env_name: []const u8, fallback_suffix: []const u8) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, env_name) catch null) |dir| {
        if (dir.len != 0 and std.fs.path.isAbsolute(dir)) return dir;
        allocator.free(dir);
    }
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return resolveXdgHome(allocator, null, home, fallback_suffix);
}

/// env를 읽지 않는 pure helper — empty/relative/absolute 경계를 단위 테스트한다.
fn resolveXdgHome(
    allocator: std.mem.Allocator,
    candidate: ?[]const u8,
    home: []const u8,
    fallback_suffix: []const u8,
) ![]u8 {
    if (candidate) |dir| {
        if (dir.len != 0 and std.fs.path.isAbsolute(dir)) return allocator.dupe(u8, dir);
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ home, fallback_suffix });
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
        if (runtime_dir.len != 0 and std.fs.path.isAbsolute(runtime_dir)) return linuxLockDir(allocator, runtime_dir, null, "");
    }
    if (std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME") catch null) |cache_dir| {
        defer allocator.free(cache_dir);
        if (cache_dir.len != 0 and std.fs.path.isAbsolute(cache_dir)) return linuxLockDir(allocator, null, cache_dir, "");
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

pub fn instanceEndpointStatePath(allocator: std.mem.Allocator, index: u32) ![]u8 {
    const dir = try lockDir(allocator);
    defer allocator.free(dir);
    try ensureDir(dir);
    const sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';
    return std.fmt.allocPrint(allocator, "{s}{c}instance{d}.endpoint", .{ dir, sep, index });
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

test "logPathFor 가 OS 표준 위치와 worker index 를 따른다" {
    const allocator = std.testing.allocator;
    if (!std.process.hasEnvVarConstant(if (builtin.os.tag == .windows) "APPDATA" else "HOME"))
        return error.SkipZigTest;
    const path = try logPathFor(allocator, 7);
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, switch (builtin.os.tag) {
        .windows => "\\tildaz\\tildaz_7.log",
        .macos => "/Library/Logs/tildaz_7.log",
        else => "/tildaz/tildaz_7.log",
    }));
}

test "log path builder preserves paths beyond the old fixed limit" {
    const allocator = std.testing.allocator;
    const long_dir = "/base/" ++ ("가" ** 1200);
    const path = try logPathFromDir(allocator, long_dir, 42);
    defer allocator.free(path);

    try std.testing.expect(path.len > 1024);
    try std.testing.expect(std.mem.startsWith(u8, path, long_dir));
    try std.testing.expect(std.mem.endsWith(u8, path, switch (builtin.os.tag) {
        .windows => "\\tildaz_42.log",
        else => "/tildaz_42.log",
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

test "XDG home accepts only absolute non-empty values" {
    const allocator = std.testing.allocator;

    const custom = try resolveXdgHome(allocator, "/custom/config", "/home/test", "/.config");
    defer allocator.free(custom);
    try std.testing.expectEqualStrings("/custom/config", custom);

    const empty = try resolveXdgHome(allocator, "", "/home/test", "/.config");
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("/home/test/.config", empty);

    const relative = try resolveXdgHome(allocator, "relative/config", "/home/test", "/.config");
    defer allocator.free(relative);
    try std.testing.expectEqualStrings("/home/test/.config", relative);

    const state = try resolveXdgHome(allocator, null, "/home/test", "/.local/state");
    defer allocator.free(state);
    try std.testing.expectEqualStrings("/home/test/.local/state", state);
}
