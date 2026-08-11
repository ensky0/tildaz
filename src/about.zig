//! About / 버전 확인 다이얼로그.
//!   - Linux: F1 으로 띄운 후 Ctrl+Shift+I.
//!   - macOS: Shift+Cmd+I (mainMenu "About TildaZ" 의 keyEquivalent — 메뉴바
//!     UI 는 Accessory mode 라 안 보이지만 키 dispatch 는 동작).
//!   - Windows: F1 으로 띄운 후 Ctrl+Shift+I.
//!
//! Platform 별로 modifier 가 다른 이유: macOS 표준 modifier 가 Cmd, 다른 탭
//! 단축키 (Cmd+T/W/숫자/[/]) 와 일관성. 같은 *기능* 의 단축키지만 각 OS 표준
//! 에 맞게 다름 — Chrome / VS Code 같은 cross-platform 앱과 동일 패턴.
//!
//! 세 platform 모두 같은 텍스트 (`messages.about_format`) 를 같은 다이얼로그
//! 모듈 (`dialog.showAboutAlert`) 로 표시. exe 경로 / pid 만 platform-specific.

const std = @import("std");
const runtime = @import("runtime.zig");
const builtin = @import("builtin");
const dialog = @import("dialog.zig");
const log = @import("log.zig");
const messages = @import("messages.zig");
const paths = @import("paths.zig");
const version = @import("version.zig");

pub const Details = struct {
    version: []const u8,
    exe_path: []const u8,
    pid: u64,
    config_path: []const u8,
    log_path: []const u8,
    open_config_key: []const u8,
    open_log_key: []const u8,
};

/// 실제 입력 길이만큼 About 본문을 조립한다. 호출자가 반환값을 해제한다.
/// 고정 buffer를 쓰지 않아 긴 절대경로와 multibyte 텍스트를 온전히 보존한다.
pub fn formatMessageAlloc(allocator: std.mem.Allocator, details: Details) ![]u8 {
    return std.fmt.allocPrint(allocator, messages.about_format, .{
        details.version,
        details.exe_path,
        details.pid,
        details.config_path,
        details.log_path,
        details.open_config_key,
        details.open_log_key,
    });
}

/// About 다이얼로그 표시. 호출 환경: Linux Ctrl+Shift+I / macOS Shift+Cmd+I /
/// Windows Ctrl+Shift+I 등 일반 사용자 trigger.
///
/// 표시 경로는 모두 절대 경로 (`~` / `%APPDATA%` 같은 단축 안 씀) — SPEC.md
/// §11.3. 사용자가 그대로 vim / explorer 명령에 paste 가능 + 환경 ambiguity 제거.
pub fn showAboutDialog() void {
    const allocator = std.heap.page_allocator;

    const exe_path_owned = std.process.executablePathAlloc(runtime.ioRequired(), allocator) catch null;
    defer if (exe_path_owned) |path| allocator.free(path);
    const exe_path = exe_path_owned orelse messages.unknown_path_msg;

    const pid: u64 = @intCast(switch (builtin.os.tag) {
        .windows => getCurrentProcessIdWindows(),
        else => std.c.getpid(),
    });

    const config_path_owned = paths.configPath(allocator) catch null;
    defer if (config_path_owned) |path| allocator.free(path);
    const config_path = config_path_owned orelse messages.unknown_path_msg;

    const log_path = log.filePath() orelse messages.unknown_path_msg;

    // Tip 라인의 단축키 — platform native modifier (SPEC §0 #2). macOS 만
    // Cmd 기반, Linux / Windows 는 Ctrl 기반 표준. body 구조는 세 platform이
    // 동일하고 토큰만 다름.
    const open_config_key: []const u8 = switch (builtin.os.tag) {
        .macos => "Shift+Cmd+P",
        else => "Ctrl+Shift+P",
    };
    const open_log_key: []const u8 = switch (builtin.os.tag) {
        .macos => "Shift+Cmd+L",
        else => "Ctrl+Shift+L",
    };

    const msg = formatMessageAlloc(allocator, .{
        // #383 — semver 뿐 아니라 빌드한 커밋까지 (`0.7.0 (d1ad1ff-dirty)`). 사용자가
        // 이 다이얼로그를 그대로 복사해 이슈에 붙이므로, 어느 커밋인지가 여기 있어야
        // 릴리즈 사이의 빌드를 되묻지 않는다. `--version` · 로그와 같은 문자열이다.
        .version = version.string,
        .exe_path = exe_path,
        .pid = pid,
        .config_path = config_path,
        .log_path = log_path,
        .open_config_key = open_config_key,
        .open_log_key = open_log_key,
    }) catch |err| {
        log.appendLine("about", "About message allocation failed: {s}", .{@errorName(err)});
        dialog.showAboutAlert(messages.about_title, messages.about_prepare_failed_msg);
        return;
    };
    defer allocator.free(msg);

    dialog.showAboutAlert(messages.about_title, msg);
}

extern "kernel32" fn GetCurrentProcessId() callconv(.c) u32;

fn getCurrentProcessIdWindows() u32 {
    if (builtin.os.tag != .windows) return 0;
    return GetCurrentProcessId();
}

test "#383 About 첫 줄은 `--version` · 로그와 같은 버전 문자열이다" {
    // 세 표시 지점이 갈리지 않게 묶는다. About 만 `build_options.version` 을 그대로 쓰던
    // 시절로 되돌아가면 (= 커밋이 빠지면) 여기서 잡힌다.
    const msg = try formatMessageAlloc(std.testing.allocator, .{
        .version = version.string,
        .exe_path = "/usr/bin/tildaz",
        .pid = 42,
        .config_path = "/tmp/config_0.json",
        .log_path = "/tmp/tildaz_0.log",
        .open_config_key = "Ctrl+Shift+P",
        .open_log_key = "Ctrl+Shift+L",
    });
    defer std.testing.allocator.free(msg);

    var expected_buf: [256]u8 = undefined;
    const expected_first_line = try std.fmt.bufPrint(&expected_buf, "TildaZ v{s}", .{version.string});
    try std.testing.expect(std.mem.startsWith(u8, msg, expected_first_line));
}

test "#314 About formatter preserves content beyond the old 2048-byte limit" {
    const long_path = "/home/" ++ ("x" ** 2300) ++ "/tildaz";
    const msg = try formatMessageAlloc(std.testing.allocator, .{
        .version = "test",
        .exe_path = long_path,
        .pid = 42,
        .config_path = "/tmp/config.json",
        .log_path = "/tmp/tildaz.log",
        .open_config_key = "Ctrl+Shift+P",
        .open_log_key = "Ctrl+Shift+L",
    });
    defer std.testing.allocator.free(msg);

    try std.testing.expect(msg.len > 2048);
    try std.testing.expect(std.mem.indexOf(u8, msg, long_path) != null);
    try std.testing.expect(std.mem.endsWith(u8, msg, "https://github.com/ensky0/tildaz"));
}

test "#314 About formatter preserves multibyte paths" {
    const config_path = "/home/사용자/설정/한글/config_0.json";
    const msg = try formatMessageAlloc(std.testing.allocator, .{
        .version = "test",
        .exe_path = "/응용 프로그램/TildaZ",
        .pid = 7,
        .config_path = config_path,
        .log_path = "/home/사용자/로그/tildaz_0.log",
        .open_config_key = "Shift+Cmd+P",
        .open_log_key = "Shift+Cmd+L",
    });
    defer std.testing.allocator.free(msg);

    try std.testing.expect(std.unicode.utf8ValidateSlice(msg));
    try std.testing.expect(std.mem.indexOf(u8, msg, config_path) != null);
}

test "#314 About formatter reports allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, formatMessageAlloc(failing.allocator(), .{
        .version = "test",
        .exe_path = "/tmp/tildaz",
        .pid = 1,
        .config_path = "/tmp/config.json",
        .log_path = "/tmp/tildaz.log",
        .open_config_key = "Ctrl+Shift+P",
        .open_log_key = "Ctrl+Shift+L",
    }));
}
