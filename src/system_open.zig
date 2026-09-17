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
        //
        // ⚠️ **이름이 아니라 전체 경로로 지정한다** ([#655](https://github.com/ensky0/tildaz/issues/655)
        // Windows 회차 실측). `lpFile` 에 `"notepad.exe"` 만 주면 `ShellExecuteW` 가 PATH 보다
        // 먼저 **App Paths** (`HKCU\…\App Paths\notepad.exe`) 를 조회하는데, Store 메모장이
        // 깔린 Windows 11 에서 그 값이 `C:\Program Files\WindowsApps\Microsoft.WindowsNotepad_…`
        // 를 가리킨다. 그 디렉터리는 TrustedInstaller 소유라 사용자가 접근할 수 없어 실행이
        // `SE_ERR_ACCESSDENIED` (rc=5) 로 막히고 **편집기가 조용히 안 뜬다.** 같은 회차에서
        // 이름만 주면 rc=5, `System32\notepad.exe` 전체 경로면 rc=42 로 갈렸다.
        var notepad_buf: [max_notepad_path]u16 = undefined;
        const notepad_path = systemFilePath(&notepad_buf, "notepad.exe") orelse {
            log.appendLine("open", "cannot build the notepad path; giving up", .{});
            return;
        };
        launch(verb_w, notepad_path, wparams.ptr, "notepad");
        return;
    }

    launch(verb_w, wpath.ptr, null, "the associated app");
}

/// `GetSystemDirectoryW` 아래의 실행 파일 전체 경로. 버퍼가 모자라면 null.
///
/// 하드코딩한 `C:\Windows\System32` 를 쓰지 않는 이유는 시스템 디렉터리가 그 자리라는
/// 보장이 없어서다 (다른 드라이브에 설치된 Windows · WoW64 리다이렉션).
fn systemFilePath(buf: []u16, comptime name: []const u8) ?[*:0]const u16 {
    const name_w = std.unicode.utf8ToUtf16LeStringLiteral("\\" ++ name);
    const dir_len = GetSystemDirectoryW(buf.ptr, @intCast(buf.len));
    // 0 은 실패, `buf.len` 이상이면 필요한 크기를 돌려준 것이라 담지 못한 것이다.
    if (dir_len == 0 or dir_len >= buf.len) return null;
    if (dir_len + name_w.len + 1 > buf.len) return null;
    @memcpy(buf[dir_len..][0..name_w.len], name_w[0..name_w.len]);
    buf[dir_len + name_w.len] = 0;
    return @ptrCast(buf.ptr);
}

/// `\notepad.exe` 같은 이름까지 담을 수 있는 크기. `MAX_PATH` (260) 에 이름 몫을 더한다.
const max_notepad_path = 260 + 32;

/// 열기를 시도하고 **실패를 반드시 남긴다.** 반환값 32 이하가 오류라는 것은
/// `ShellExecuteW` 계약이다. 이 값을 버리던 동안 #655 의 `ACCESS_DENIED` 가 로그 한 줄
/// 없이 조용히 실패했고, 사용자에게는 *"눌러도 아무 일도 안 난다"* 로만 보였다.
///
/// 반대로 **rc > 32 가 "편집기가 떴다" 를 뜻하지는 않는다** (#456 — "앱 선택" 프롬프트로
/// 넘어가도 성공으로 보고한다). 그래서 성공 쪽은 로그를 남기지 않고, 연결 유무 판정은
/// 위의 `hasOpenAssociation` 이 계속 맡는다.
fn launch(verb_w: [*:0]const u16, file_w: [*:0]const u16, params_w: ?[*:0]const u16, what: []const u8) void {
    const rc = @intFromPtr(ShellExecuteW(null, verb_w, file_w, params_w, null, 1));
    if (rc <= 32) log.appendLine("open", "failed to open {s}: ShellExecuteW rc={d}", .{ what, rc });
}

fn openSpawn(rt: Runtime, cmd: []const u8, path: []const u8) void {
    // #451 — `Child.init` + 필드 설정 + `spawn` ➡️ `std.process.spawn(io, options)`
    // (릴리즈 노트 *Process*). stdio 는 `.Ignore` → `.ignore` 로 이름만 바뀌었다.
    // #655 — 실패를 조용히 삼키지 않는다. Windows 쪽에서 `ShellExecuteW` 반환값을 버린
    // 탓에 `ACCESS_DENIED` 가 로그 한 줄 없이 지나갔고, 사용자에게는 *"눌러도 아무 일도
    // 안 난다"* 로만 보였다. 여기도 같은 모양이었다 — `open` · `xdg-open` 이 없거나
    // 실행되지 않으면 아무 흔적이 남지 않는다.
    const child = std.process.spawn(rt.io, .{
        .argv = &.{ cmd, path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        log.appendLine("open", "failed to spawn {s}: {s}", .{ cmd, @errorName(err) });
        return;
    };

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

extern "kernel32" fn GetSystemDirectoryW(lpBuffer: [*]u16, uSize: u32) callconv(.c) u32;

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

// ── test ─────────────────────────────────────────────────────────────────────
//
// #655 — 이 자리에 test 가 없어서 "이름만 주면 App Paths 가 접근 불가 경로로 보낸다" 는
// 결함이 Windows 실기에서야 드러났다. 경로를 **만드는** 부분은 순수 계산이라 고정할 수 있다
// (실제 실행은 OS 상태에 달려 있어 test 대상이 아니다).

test "systemFilePath — 시스템 디렉터리 아래의 절대 경로를 만든다" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var buf: [max_notepad_path]u16 = undefined;
    const p = systemFilePath(&buf, "notepad.exe") orelse return error.TestUnexpectedResult;

    var utf8: [1024]u8 = undefined;
    const n = try std.unicode.utf16LeToUtf8(&utf8, std.mem.span(p));
    const got = utf8[0..n];

    // 이름만이 아니라 **절대 경로** 여야 한다 — 그것이 이 함수의 존재 이유다.
    try std.testing.expect(std.mem.endsWith(u8, got, "\\notepad.exe"));
    try std.testing.expect(std.mem.indexOf(u8, got, ":\\") != null);
    try std.testing.expect(got.len > "notepad.exe".len);
}

test "systemFilePath — 버퍼가 모자라면 null (잘린 경로를 실행하지 않는다)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tiny: [8]u16 = undefined;
    try std.testing.expect(systemFilePath(&tiny, "notepad.exe") == null);
}
