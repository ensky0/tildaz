//! `config.shell` 값이 실제로 실행 가능한 binary 인지 cross-platform 검증.
//! 실패 시 fatal dialog 띄우고 즉시 종료 — 윈도우 / 렌더러 / PTY 초기화 비용
//! 다 쓴 뒤 generic "TildaZ failed to start" 다이얼로그로 끝나는 사고 방지.
//!
//! Windows host / macOS host 는 `validateOrFatal` 을 Config.load 직후 한 번 호출한다.
//! Linux host 는 dialog overlay 를 Wayland 연결 이후에만 그릴 수 있어(연결 전
//! fire-and-forget showFatal 은 paint 전에 죽는다, #282 F9), `validationMessage` 로
//! 메시지만 받아 host 가 blocking overlay 로 표시한 뒤 종료한다. token / exists /
//! 메시지 조립 로직은 세 platform 이 이 모듈로 공유한다.
//!
//! OS 별 차이:
//! - Windows: shell 이 인자를 포함할 수 있고 (`"wsl.exe -d Debian"`),
//!   첫 토큰만 추출해서 SearchPathW 로 PATH + 절대경로 모두 자동 탐색.
//! - macOS / Linux: SPEC §7 상 absolute binary path + 인자 없음. full string 을 그대로
//!   path 로 보고 POSIX `access(X_OK)` 검사. 첫 실행의 `$SHELL` resolution 은
//!   host 가 default config 생성 전에 끝내고, 이후 disk config 의 명시값만 사용.

const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const builtin = @import("builtin");
const dialog = @import("dialog.zig");
const messages = @import("messages.zig");
const paths = @import("paths.zig");

pub const ValidationMessage = struct {
    text: []const u8,
    owned: ?[]u8 = null,

    pub fn deinit(self: ValidationMessage, allocator: std.mem.Allocator) void {
        if (self.owned) |message| allocator.free(message);
    }
};

const ValidationFailure = enum {
    empty,
    first_token_empty,
    executable_not_found,
};

fn allocMessageOrFallback(
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
    fallback: []const u8,
) ValidationMessage {
    const owned = std.fmt.allocPrint(allocator, fmt, args) catch
        return .{ .text = fallback };
    return .{ .text = owned, .owned = owned };
}

fn formatValidationFailure(
    allocator: std.mem.Allocator,
    failure: ValidationFailure,
    shell: []const u8,
    token: []const u8,
    config_path: []const u8,
) ValidationMessage {
    return switch (failure) {
        .empty => allocMessageOrFallback(
            allocator,
            messages.shell_empty_format,
            .{ examples(), config_path },
            messages.shell_empty_fallback_msg,
        ),
        .first_token_empty => allocMessageOrFallback(
            allocator,
            messages.shell_first_token_empty_format,
            .{ shell, examples(), config_path },
            messages.shell_first_token_empty_fallback_msg,
        ),
        .executable_not_found => allocMessageOrFallback(
            allocator,
            messages.shell_executable_not_found_format,
            .{ shell, token, examples(), config_path },
            messages.shell_executable_not_found_fallback_msg,
        ),
    };
}

/// `config.shell` 검증. 유효하면 `null`, 아니면 실제 입력 길이로 조립한 메시지를
/// 반환한다. allocation 실패 때만 failure 종류별 정적 fallback을 반환한다.
/// 호출자는 non-null 결과를 dialog에 전달한 뒤 `deinit`해야 한다.
///
/// `validateOrFatal` (Windows / macOS host) 와 Linux host 의 blocking overlay 경로가
/// 이 함수를 공유해 token / exists / 메시지 조립 로직을 한 곳에 둔다. Linux 는
/// `dialog.showFatal` 이 fire-and-forget + 즉시 exit 이라 overlay 가 paint 전에 죽어
/// (#282 F9), host 가 이 메시지를 받아 자체 blocking overlay 로 표시한 뒤 종료한다.
pub fn validationMessage(rt: Runtime, allocator: std.mem.Allocator, shell: []const u8) ?ValidationMessage {
    const token = firstShellToken(shell);
    const failure: ValidationFailure = if (shell.len == 0)
        .empty
    else if (token.len == 0)
        .first_token_empty
    else if (executableExists(allocator, token))
        return null
    else
        .executable_not_found;

    const cfg_path_owned: ?[]u8 = paths.configPath(rt, allocator) catch null;
    defer if (cfg_path_owned) |p| allocator.free(p);
    const cfg_path: []const u8 = cfg_path_owned orelse "(unknown)";
    return formatValidationFailure(allocator, failure, shell, token, cfg_path);
}

pub fn validateOrFatal(rt: Runtime, allocator: std.mem.Allocator, shell: []const u8) void {
    if (validationMessage(rt, allocator, shell)) |message| {
        // showFatal은 process를 종료한다. owned 본문은 dialog가 닫힐 때까지
        // 유효하고 process 종료와 함께 회수된다.
        dialog.showFatal(rt, messages.config_error_title, message.text);
    }
}

/// #248 — 런타임 새 탭 생성 *직전* shell 바이너리 재검증. startup `validateOrFatal`
/// 과 달리 절대 종료하지 않는다 — 없으면 non-fatal 알림(OK 하나)을 띄우고 `false`
/// 를 반환해 호출자가 탭 생성을 취소하게 한다. brew / 패키지 업데이트로 shell 경로가
/// 런타임에 사라졌을 때 새 탭이 *조용히* 죽던 것을 막고 사용자에게 원인을 알린다.
/// 존재하면 `true` (정상 진행). startup 검증과 같은 `firstShellToken` /
/// `executableExists` 를 공유해 판정 기준이 일관된다.
pub fn checkForNewTab(rt: Runtime, allocator: std.mem.Allocator, shell: []const u8) bool {
    const tok = firstShellToken(shell);
    if (tok.len != 0 and executableExists(allocator, tok)) return true;

    const cfg_path_owned: ?[]u8 = paths.configPath(rt, allocator) catch null;
    defer if (cfg_path_owned) |p| allocator.free(p);
    const cfg_path: []const u8 = cfg_path_owned orelse "(unknown)";

    const message = allocMessageOrFallback(
        allocator,
        messages.shell_new_tab_not_found_format,
        .{ shell, cfg_path },
        messages.shell_new_tab_not_found_fallback_msg,
    );
    defer message.deinit(allocator);
    dialog.showInfo(rt, messages.shell_new_tab_error_title, message.text);
    return false;
}

/// `config.shell` 의 첫 *토큰* 추출. Windows 는 인자 허용 → 따옴표 / 첫 공백
/// 까지. macOS 는 spec 상 인자 없음 → full string 이 그대로 토큰. 따옴표만
/// 양쪽으로 strip (사용자가 `"\"...\""` 로 적었을 때 보호).
fn firstShellToken(shell: []const u8) []const u8 {
    if (shell.len == 0) return shell;
    if (builtin.os.tag == .windows) {
        if (shell[0] == '"') {
            const close = std.mem.findScalarPos(u8, shell, 1, '"') orelse return shell[1..];
            return shell[1..close];
        }
        const sp = std.mem.findAnyPos(u8, shell, 0, " \t") orelse return shell;
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
        else => messages.shell_examples_posix,
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

test "shell validation preserves long and multibyte failure details beyond 1024 bytes" {
    const allocator = std.testing.allocator;
    const shell = "/missing/" ++ ("셸" ** 600);
    const config_path = "/tmp/" ++ ("경로/" ** 400) ++ "config_998.json";
    const message = formatValidationFailure(
        allocator,
        .executable_not_found,
        shell,
        shell,
        config_path,
    );
    defer message.deinit(allocator);

    try std.testing.expect(message.owned != null);
    try std.testing.expect(message.text.len > 1024);
    try std.testing.expect(std.unicode.utf8ValidateSlice(message.text));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, message.text, shell));
    try std.testing.expect(std.mem.endsWith(u8, message.text, config_path));
}

test "shell validation uses the specific static fallback only when allocation fails" {
    var storage: [1]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    const message = formatValidationFailure(
        fba.allocator(),
        .executable_not_found,
        "/missing/shell",
        "/missing/shell",
        "/tmp/config_998.json",
    );
    defer message.deinit(fba.allocator());

    try std.testing.expect(message.owned == null);
    try std.testing.expectEqualStrings(messages.shell_executable_not_found_fallback_msg, message.text);
}

test "new tab failure message preserves long shell and final config path" {
    const allocator = std.testing.allocator;
    const shell = "/missing/" ++ ("x" ** 1600);
    const config_path = "/tmp/" ++ ("y/" ** 900) ++ "config_998.json";
    const message = allocMessageOrFallback(
        allocator,
        messages.shell_new_tab_not_found_format,
        .{ shell, config_path },
        messages.shell_new_tab_not_found_fallback_msg,
    );
    defer message.deinit(allocator);

    try std.testing.expect(message.owned != null);
    try std.testing.expect(message.text.len > 1024);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, message.text, shell));
    try std.testing.expect(std.mem.endsWith(u8, message.text, config_path));
}

test "valid shell returns null without preparing an error message" {
    const allocator = std.testing.allocator;
    const shell = if (builtin.os.tag == .windows) "cmd.exe" else "/bin/sh";
    if (!executableExists(allocator, shell)) return error.SkipZigTest;
    // #451 — 유효한 셸이면 config 경로를 읽기 전에 `null` 로 빠져나오므로 환경변수가
    // 필요 없다. `Environ.empty` 로 두어 테스트가 기계의 환경에 안 묶이게 한다.
    const rt: Runtime = .{ .io = std.testing.io, .environ = .empty };
    try std.testing.expect(validationMessage(rt, allocator, shell) == null);
}
