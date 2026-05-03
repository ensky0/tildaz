//! `config.shell` 값이 실제로 실행 가능한 binary 인지 cross-platform 검증.
//! 실패 시 fatal dialog 띄우고 즉시 종료 — 윈도우 / 렌더러 / PTY 초기화 비용
//! 다 쓴 뒤 generic "TildaZ failed to start" 다이얼로그로 끝나는 사고 방지.
//! Windows host / macOS host 가 Config.load 직후 한 번 호출.
//!
//! OS 별 차이:
//! - Windows: shell 이 인자를 포함할 수 있고 (`"wsl.exe -d Debian --cd ~"`),
//!   첫 토큰만 추출해서 SearchPathW 로 PATH + 절대경로 모두 자동 탐색.
//! - macOS: SPEC §7 상 absolute binary path + 인자 없음. full string 을 그대로
//!   path 로 보고 POSIX `access(X_OK)` 검사. config.shell == "" 이면 host 가
//!   `$SHELL` / `/bin/zsh` fallback 을 따로 처리하므로 검증 skip.

const std = @import("std");
const builtin = @import("builtin");
const dialog = @import("dialog.zig");
const messages = @import("messages.zig");
const paths = @import("paths.zig");

pub fn validateOrFatal(allocator: std.mem.Allocator, shell: []const u8) void {
    const cfg_path_owned: ?[]u8 = paths.configPath(allocator) catch null;
    defer if (cfg_path_owned) |p| allocator.free(p);
    const cfg_path: []const u8 = cfg_path_owned orelse "(unknown)";

    if (shell.len == 0) {
        if (builtin.os.tag == .macos) return; // macOS empty = $SHELL fallback
        var msg_buf: [768]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            "config.json: \"shell\" is empty.\n\n{s}\n\nConfig path:\n{s}",
            .{ examples(), cfg_path },
        ) catch "config.json: shell is empty.";
        dialog.showFatal(messages.config_error_title, msg);
    }

    const tok = firstShellToken(shell);
    if (tok.len == 0) {
        var msg_buf: [768]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            "config.json: \"shell\" first token is empty.\n\nValue: \"{s}\"\n\n{s}\n\nConfig path:\n{s}",
            .{ shell, examples(), cfg_path },
        ) catch "config.json: shell first token empty.";
        dialog.showFatal(messages.config_error_title, msg);
    }

    if (executableExists(allocator, tok)) return;

    var msg_buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "config.json: shell executable not found.\n\n\"shell\" value: \"{s}\"\nLookup token: \"{s}\"\n\n{s}\n\nConfig path:\n{s}",
        .{ shell, tok, examples(), cfg_path },
    ) catch "config.json: shell executable not found.";
    dialog.showFatal(messages.config_error_title, msg);
}

/// `config.shell` 의 첫 *토큰* 추출. Windows 는 인자 허용 → 따옴표 / 첫 공백
/// 까지. macOS 는 spec 상 인자 없음 → full string 이 그대로 토큰. 따옴표만
/// 양쪽으로 strip (사용자가 `"\"...\""` 로 적었을 때 보호).
fn firstShellToken(shell: []const u8) []const u8 {
    if (shell.len == 0) return shell;
    if (builtin.os.tag == .windows) {
        if (shell[0] == '"') {
            const close = std.mem.indexOfScalarPos(u8, shell, 1, '"') orelse return shell[1..];
            return shell[1..close];
        }
        const sp = std.mem.indexOfAnyPos(u8, shell, 0, " \t") orelse return shell;
        return shell[0..sp];
    }
    // macOS / POSIX: spec 상 인자 없음. 따옴표만 strip.
    if (shell.len >= 2 and shell[0] == '"' and shell[shell.len - 1] == '"')
        return shell[1 .. shell.len - 1];
    return shell;
}

fn executableExists(allocator: std.mem.Allocator, token: []const u8) bool {
    return switch (builtin.os.tag) {
        .windows => existsWindows(token),
        else => existsPosix(allocator, token),
    };
}

fn examples() []const u8 {
    return switch (builtin.os.tag) {
        .windows =>
        \\Examples:
        \\  "cmd.exe"
        \\  "powershell.exe"
        \\  "wsl.exe -d Debian --cd ~"
        \\  "C:\\Windows\\System32\\cmd.exe"
        ,
        else =>
        \\macOS expects an absolute path to an executable. Examples:
        \\  "/bin/zsh"
        \\  "/bin/bash"
        \\  "/usr/local/bin/fish"
        \\
        \\Leave "shell": "" to use $SHELL / /bin/zsh fallback.
        ,
    };
}

// --- OS-specific exists helpers ---

const WCHAR = u16;

extern "kernel32" fn SearchPathW(
    lpPath: ?[*:0]const WCHAR,
    lpFileName: [*:0]const WCHAR,
    lpExtension: ?[*:0]const WCHAR,
    nBufferLength: u32,
    lpBuffer: [*]WCHAR,
    lpFilePart: ?*?[*]WCHAR,
) callconv(.c) u32;

fn existsWindows(token: []const u8) bool {
    var exe_buf: [1024]u16 = undefined;
    var resolved: [1024]u16 = undefined;
    const written = std.unicode.utf8ToUtf16Le(exe_buf[0 .. exe_buf.len - 1], token) catch return false;
    exe_buf[written] = 0;
    const found = SearchPathW(
        null,
        @ptrCast(exe_buf[0..written :0].ptr),
        null,
        @intCast(resolved.len),
        @ptrCast(&resolved),
        null,
    );
    return found > 0;
}

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
const X_OK: c_int = 1;

fn existsPosix(allocator: std.mem.Allocator, token: []const u8) bool {
    _ = allocator; // 향후 PATH 탐색 확장 시 사용 — 현재는 token 자체로 access 만.
    var path_buf: [4096]u8 = undefined;
    if (token.len >= path_buf.len) return false;
    @memcpy(path_buf[0..token.len], token);
    path_buf[token.len] = 0;
    return access(@ptrCast(path_buf[0..token.len :0].ptr), X_OK) == 0;
}
