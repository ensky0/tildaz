// 사용자 데이터 파일 (config.json / tildaz.log) 의 absolute 절대 경로 — OS
// 표준 위치를 따른다 (SPEC.md §11.1, AGENTS.md "platform native first").
//
//   Windows: %APPDATA%\tildaz\config.json     (Microsoft 표준)
//            %APPDATA%\tildaz\tildaz.log
//   macOS:   $HOME/.config/tildaz/config.json (XDG, ghostty/alacritty 패턴)
//            $HOME/Library/Logs/tildaz.log    (Apple HIG — Console.app 인덱싱)
//   Linux:   $HOME/.config/tildaz/config.json (XDG)
//            $HOME/.local/state/tildaz/tildaz.log
//
// 모두 allocator-based — 호출처가 free 책임. 부모 디렉토리는 자동 생성
// (이미 존재하면 무시). About 다이얼로그 / Open Config & Log 단축키 /
// 모듈 (`config.zig` / `macos_config.zig` / `tildaz_log.zig`) 에서 사용.

const std = @import("std");
const builtin = @import("builtin");

pub fn configPath(allocator: std.mem.Allocator) ![]u8 {
    const dir = try configDir(allocator);
    defer allocator.free(dir);
    try ensureDir(dir);
    const sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';
    return std.fmt.allocPrint(allocator, "{s}{c}config.json", .{ dir, sep });
}

pub fn logPath(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        const dir = try configDir(allocator);
        defer allocator.free(dir);
        try ensureDir(dir);
        return std.fmt.allocPrint(allocator, "{s}\\tildaz.log", .{dir});
    } else if (builtin.os.tag == .macos) {
        // `~/Library/Logs` 는 macOS default 로 항상 존재 — 디렉토리 생성 불필요.
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);
        return std.fmt.allocPrint(allocator, "{s}/Library/Logs/tildaz.log", .{home});
    } else {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);
        const dir = try std.fmt.allocPrint(allocator, "{s}/.local/state/tildaz", .{home});
        defer allocator.free(dir);
        try ensureDir(dir);
        return std.fmt.allocPrint(allocator, "{s}/tildaz.log", .{dir});
    }
}

fn configDir(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        const appdata = try std.process.getEnvVarOwned(allocator, "APPDATA");
        defer allocator.free(appdata);
        return std.fmt.allocPrint(allocator, "{s}\\tildaz", .{appdata});
    }
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.config/tildaz", .{home});
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
