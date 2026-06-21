//! `config.shell` 값이 실제로 실행 가능한 binary 인지 cross-platform 검증.
//! 실패 시 fatal dialog 띄우고 즉시 종료 — 윈도우 / 렌더러 / PTY 초기화 비용
//! 다 쓴 뒤 generic "TildaZ failed to start" 다이얼로그로 끝나는 사고 방지.
//! Windows host / macOS host 가 Config.load 직후 한 번 호출.
//!
//! OS 별 차이:
//! - Windows: shell 이 인자를 포함할 수 있고 (`"wsl.exe -d Debian --cd ~"`),
//!   첫 토큰만 추출해서 SearchPathW 로 PATH + 절대경로 모두 자동 탐색.
//! - macOS: SPEC §7 상 absolute binary path + 인자 없음. full string 을 그대로
//!   path 로 보고 POSIX `access(X_OK)` 검사. 첫 실행의 `$SHELL` resolution 은
//!   host 가 default config 생성 전에 끝내고, 이후 disk config 의 명시값만 사용.

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
        var msg_buf: [768]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            messages.shell_empty_format,
            .{ examples(), cfg_path },
        ) catch messages.shell_empty_fallback_msg;
        dialog.showFatal(messages.config_error_title, msg);
    }

    const tok = firstShellToken(shell);
    if (tok.len == 0) {
        var msg_buf: [768]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            messages.shell_first_token_empty_format,
            .{ shell, examples(), cfg_path },
        ) catch messages.shell_first_token_empty_fallback_msg;
        dialog.showFatal(messages.config_error_title, msg);
    }

    if (executableExists(allocator, tok)) return;

    var msg_buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        messages.shell_executable_not_found_format,
        .{ shell, tok, examples(), cfg_path },
    ) catch messages.shell_executable_not_found_fallback_msg;
    dialog.showFatal(messages.config_error_title, msg);
}

/// #248 — 런타임 새 탭 생성 *직전* shell 바이너리 재검증. startup `validateOrFatal`
/// 과 달리 절대 종료하지 않는다 — 없으면 non-fatal 알림(OK 하나)을 띄우고 `false`
/// 를 반환해 호출자가 탭 생성을 취소하게 한다. brew / 패키지 업데이트로 shell 경로가
/// 런타임에 사라졌을 때 새 탭이 *조용히* 죽던 것을 막고 사용자에게 원인을 알린다.
/// 존재하면 `true` (정상 진행). startup 검증과 같은 `firstShellToken` /
/// `executableExists` 를 공유해 판정 기준이 일관된다.
pub fn checkForNewTab(allocator: std.mem.Allocator, shell: []const u8) bool {
    const tok = firstShellToken(shell);
    if (tok.len != 0 and executableExists(allocator, tok)) return true;

    const cfg_path_owned: ?[]u8 = paths.configPath(allocator) catch null;
    defer if (cfg_path_owned) |p| allocator.free(p);
    const cfg_path: []const u8 = cfg_path_owned orelse "(unknown)";

    var msg_buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        messages.shell_new_tab_not_found_format,
        .{ shell, cfg_path },
    ) catch messages.shell_new_tab_not_found_fallback_msg;
    dialog.showInfo(messages.shell_new_tab_error_title, msg);
    return false;
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
        .windows => messages.shell_examples_windows,
        else => messages.shell_examples_macos,
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
