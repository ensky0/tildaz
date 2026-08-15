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

    // 연결된 앱이 없는 확장자면 Windows 는 편집기 대신 "앱 선택" 프롬프트로 넘기는데,
    // `ShellExecuteW` 는 그것도 성공으로 보고한다. `SEE_MASK_FLAG_NO_UI` 를 줘도
    // `SE_ERR_NOASSOC` 가 오지 않는 것을 실측으로 확인했다 — **호출 결과만으로는
    // 편집기가 실제로 떴는지 알 수 없다** (#456). 그래서 열기 전에 연결 유무를 직접
    // 조회하고, 없을 때만 메모장으로 연다. 사용자가 지정해 둔 편집기가 있으면 지금처럼
    // 그쪽이 뜬다 — `.json` 에 아무것도 연결돼 있지 않아 Ctrl+Shift+P 가 조용히 아무 일도
    // 안 하던 것만 사라진다.
    if (!hasOpenAssociation(allocator, path)) {
        log.appendLine("open", "no file association for '{s}'; opening with notepad instead", .{extensionOf(path)});
        // 경로에 공백이 있어도 한 인자로 가도록 따옴표로 감싼다.
        const params = std.fmt.allocPrint(allocator, "\"{s}\"", .{path}) catch return;
        defer allocator.free(params);
        const wparams = std.unicode.utf8ToUtf16LeAllocZ(allocator, params) catch return;
        defer allocator.free(wparams);
        // notepad.exe 는 Windows 10 / 11 에 항상 있다 (메모장이 Store 앱이 된 뒤에도
        // System32 의 실행 스텁이 남는다).
        const notepad_w = std.unicode.utf8ToUtf16LeStringLiteral("notepad.exe");
        _ = ShellExecuteW(null, verb_w, notepad_w, wparams.ptr, null, 1);
        return;
    }

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

// ── 확장자 연결 조회 (Windows-only, #456) ────────────────────────────────────
//
// `AssocQueryStringW(ASSOCSTR_EXECUTABLE)` 는 못 쓴다 — 기본 앱이 Store 앱이면 exe
// 경로가 없어서 *연결이 있는* `.log` 도 `0x80070483` 로 실패한다 (실측). 그래서
// 레지스트리를 직접 본다: 사용자가 고른 앱은 `UserChoice` 에, 시스템 기본 연결은
// `HKCR\<ext>` 의 ProgId 에 남는다.

const HKEY_CLASSES_ROOT: ?*anyopaque = @ptrFromInt(0x80000000);
const HKEY_CURRENT_USER: ?*anyopaque = @ptrFromInt(0x80000001);
const RRF_RT_REG_SZ: u32 = 0x00000002;

extern "advapi32" fn RegGetValueW(
    hkey: ?*anyopaque,
    lpSubKey: ?[*:0]const u16,
    lpValue: ?[*:0]const u16,
    dwFlags: u32,
    pdwType: ?*u32,
    pvData: ?*anyopaque,
    pcbData: ?*u32,
) callconv(.c) i32;

/// 경로의 확장자 (`.json` 처럼 점 포함). 없으면 빈 문자열.
fn extensionOf(path: []const u8) []const u8 {
    const name_start = if (std.mem.lastIndexOfAny(u8, path, "\\/")) |i| i + 1 else 0;
    const name = path[name_start..];
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0) return ""; // `.gitignore` 같은 이름은 확장자가 아니다
    return name[dot..];
}

/// `root\subkey` 의 `value` (null 이면 기본값) 를 REG_SZ 로 읽는다. 값이 없거나
/// 비어 있으면 null. 반환 slice 는 `out` 을 가리킨다.
fn regReadString(
    allocator: std.mem.Allocator,
    root: ?*anyopaque,
    subkey: []const u8,
    value: ?[]const u8,
    out: []u16,
) ?[]const u16 {
    const wsub = std.unicode.utf8ToUtf16LeAllocZ(allocator, subkey) catch return null;
    defer allocator.free(wsub);
    const wval: ?[:0]u16 = if (value) |v|
        (std.unicode.utf8ToUtf16LeAllocZ(allocator, v) catch return null)
    else
        null;
    defer if (wval) |w| allocator.free(w);

    var size: u32 = @intCast(out.len * @sizeOf(u16));
    const rc = RegGetValueW(
        root,
        wsub.ptr,
        if (wval) |w| w.ptr else null,
        RRF_RT_REG_SZ,
        null,
        @ptrCast(out.ptr),
        &size,
    );
    if (rc != 0) return null;
    // `RegGetValueW` 는 종료 NUL 을 보장하고 그 몫까지 크기에 넣는다.
    const chars = size / @sizeOf(u16);
    if (chars <= 1) return null;
    return out[0 .. chars - 1];
}

/// 이 경로의 확장자에 "열기" 로 이어지는 앱이 있는지. **확실히 없을 때만 false** —
/// 조회가 불확실한 경우엔 기존 동작 (OS 에 맡김) 을 유지한다.
fn hasOpenAssociation(allocator: std.mem.Allocator, path: []const u8) bool {
    const ext = extensionOf(path);
    if (ext.len == 0) return true; // 확장자가 없으면 판정 대상이 아니다

    var buf: [512]u16 = undefined;

    // ① 사용자가 고른 기본 앱. Store 앱 (`AppX…`) 도 여기엔 ProgId 로 남는다.
    const user_choice = std.fmt.allocPrint(
        allocator,
        "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts\\{s}\\UserChoice",
        .{ext},
    ) catch return true;
    defer allocator.free(user_choice);
    if (regReadString(allocator, HKEY_CURRENT_USER, user_choice, "ProgId", &buf) != null) return true;

    // ② 시스템 기본 연결. ProgId 만 있고 `shell\open\command` 가 없으면 열리지 않으므로
    //    거기까지 확인한다.
    const prog_id_w = regReadString(allocator, HKEY_CLASSES_ROOT, ext, null, &buf) orelse return false;
    const prog_id = std.unicode.utf16LeToUtf8Alloc(allocator, prog_id_w) catch return true;
    defer allocator.free(prog_id);
    const command_key = std.fmt.allocPrint(allocator, "{s}\\shell\\open\\command", .{prog_id}) catch return true;
    defer allocator.free(command_key);

    var command_buf: [512]u16 = undefined;
    return regReadString(allocator, HKEY_CLASSES_ROOT, command_key, null, &command_buf) != null;
}
