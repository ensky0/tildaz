// 사용자 데이터 파일 (config_N.json / tildazN.log) 의 absolute 절대 경로 — OS
// 표준 위치를 따른다 (SPEC.md §11.1, AGENTS.md "platform native first").
//
//   Windows: %APPDATA%\tildaz\config_N.json   (Microsoft 표준)
//            %APPDATA%\tildaz\tildazN.log
//   macOS:   $HOME/.config/tildaz/config_N.json (XDG, ghostty/alacritty 패턴)
//            $HOME/Library/Logs/tildazN.log    (Apple HIG — Console.app 인덱싱)
//   Linux:   $HOME/.config/tildaz/config_N.json (XDG)
//            $HOME/.local/state/tildaz/tildazN.log
//
// 모두 allocator-based — 호출처가 free 책임. 부모 디렉토리는 자동 생성
// (이미 존재하면 무시). About 다이얼로그 / Open Config & Log 단축키 /
// 모듈 (`config.zig` / `log.zig` / host 별 파일) 에서 사용.

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
    const index = instance_context.workerIndex() orelse 0;
    if (builtin.os.tag == .windows) {
        const dir = try configDir(allocator);
        defer allocator.free(dir);
        try ensureDir(dir);
        return std.fmt.allocPrint(allocator, "{s}\\tildaz{d}.log", .{ dir, index });
    } else if (builtin.os.tag == .macos) {
        // `~/Library/Logs` 는 macOS default 로 항상 존재 — 디렉토리 생성 불필요.
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);
        return std.fmt.allocPrint(allocator, "{s}/Library/Logs/tildaz{d}.log", .{ home, index });
    } else {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);
        const dir = try std.fmt.allocPrint(allocator, "{s}/.local/state/tildaz", .{home});
        defer allocator.free(dir);
        try ensureDir(dir);
        return std.fmt.allocPrint(allocator, "{s}/tildaz{d}.log", .{ dir, index });
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

fn ensureDir(dir: []const u8) !void {
    // makePath = 중간 단계 포함 자동 생성 (`~/.local/state/tildaz` 같이 깊은 경로용).
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            // 부모가 없는 경우 (예: ~/.local/state) — 재귀 생성.
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
