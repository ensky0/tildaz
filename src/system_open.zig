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
const posix = std.posix;
const log = @import("log.zig");

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
    const child = std.process.spawn(rt.io, .{
        .argv = &.{ cmd, path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;

    // #457 — 자식을 거두지 않으면 `[xdg-open] <defunct>` 가 worker 수명 동안 상한
    // 없이 쌓인다. `open` / `xdg-open` 은 편집기를 띄우고 곧 끝나므로 이 thread 도
    // 금방 사라진다.
    //
    // 거두는 대상을 **이 pid 하나로 지목**하는 것이 핵심이다. PTY 는 자식마다
    // `processWaitLoop` 에서 `waitpid(child_pid, ...)` 로 블로킹하고 그 반환을 신호로
    // `child_exited` 를 세운 뒤 `exit_cb` 를 부르는데 (`terminal/posix/pty.zig`),
    // `SIGCHLD = SIG_IGN` 이나 `waitpid(-1)` 로 거두면 그 `waitpid` 가 자식이 죽기도
    // 전에 `ECHILD` 로 반환한다 — 탭이 열리자마자 닫히고 #129 의 SIGHUP grace 와
    // SIGKILL fallback 이 무력화된다. pid 를 지목하면 대상이 겹치지 않는다.
    const pid = child.id orelse return;
    const thread = std.Thread.spawn(.{}, reapChild, .{pid}) catch |err| {
        // 좀비가 하나 남을 뿐 열기 자체는 이미 성공했다. 조용히 넘기지 않고 남긴다.
        log.appendLine("open", "reap thread spawn failed: {s} (pid={d})", .{ @errorName(err), pid });
        return;
    };
    thread.detach();
}

/// spawn 한 자식 하나만 거둔다. 다른 자식 (PTY) 을 건드리지 않으려고 pid 를 지목한다.
fn reapChild(pid: posix.pid_t) void {
    _ = posix.system.waitpid(pid, null, 0);
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
