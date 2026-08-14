// "사용자 default app 으로 path 열기" cross-platform helper.
//
//   Windows: ShellExecuteW(NULL, "open", wpath, ...) — file association
//            (`.json` / `.log`) 따른 default editor 가 열림.
//   macOS:   `/usr/bin/open <path>` — Finder 가 file extension 따라 default app.
//   Linux:   `xdg-open <path>` — XDG MIME database.
//
// Open Config / Open Log 단축키 (Shift+Cmd+P/L on macOS, Ctrl+Shift+P/L on
// Windows) 가 호출. config / log path 는 `paths.zig` 참조.

const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const builtin = @import("builtin");

pub fn openInDefaultApp(rt: Runtime, allocator: std.mem.Allocator, path: []const u8) void {
    switch (builtin.os.tag) {
        // Windows 는 `ShellExecuteW` 라 `Io` 를 안 탄다.
        .windows => openWindows(allocator, path),
        .macos => openSpawn(rt, "/usr/bin/open", path),
        else => openSpawn(rt, "xdg-open", path),
    }
}

fn openWindows(allocator: std.mem.Allocator, path: []const u8) void {
    if (builtin.os.tag != .windows) return;
    const wpath = std.unicode.utf8ToUtf16LeAllocZ(allocator, path) catch return;
    defer allocator.free(wpath);
    const verb_w = std.unicode.utf8ToUtf16LeStringLiteral("open");
    _ = ShellExecuteW(null, verb_w, wpath.ptr, null, null, 1);
}

fn openSpawn(rt: Runtime, cmd: []const u8, path: []const u8) void {
    // #451 — `Child.init` + 필드 설정 + `spawn` ➡️ `std.process.spawn(io, options)`
    // (릴리즈 노트 *Process*). stdio 는 `.Ignore` → `.ignore` 로 이름만 바뀌었다.
    _ = std.process.spawn(rt.io, .{
        .argv = &.{ cmd, path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    // detached — 자식 process 종료 안 기다림. open / xdg-open 은 즉시 fork.
}

// Windows-only — `extern` 은 platform 분기와 무관하게 syntactic 으로 항상
// 컴파일되지만, 호출은 `openWindows` 안에서만 일어나므로 macOS 빌드 시 link
// 단계에서 dead-strip.
extern "shell32" fn ShellExecuteW(
    hwnd: ?*anyopaque,
    lpOperation: [*:0]const u16,
    lpFile: [*:0]const u16,
    lpParameters: ?[*:0]const u16,
    lpDirectory: ?[*:0]const u16,
    nShowCmd: c_int,
) callconv(.c) ?*anyopaque;
