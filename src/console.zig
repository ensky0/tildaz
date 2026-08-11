//! CLI 텍스트 출력 — `--version` · `--help` · 인자 오류가 콘솔로 나가는 유일한 경로
//! ([#383](https://github.com/ensky0/tildaz/issues/383)).
//!
//! 창을 띄우기 **전에** 끝나는 명령들이라 `dialog.zig` 를 거치지 않는다. 다이얼로그는
//! 창 · 렌더러 · (Linux 는) Wayland 연결이 선 뒤에야 뜨는데, 여기서는 그 앞에서 한 줄
//! 찍고 종료하는 게 목적이다.
//!
//! ## Windows 가 이 모듈이 존재하는 이유
//!
//! `tildaz.exe` 는 `subsystem = .Windows` 다 (`build.zig` 의 `exe.subsystem`) — 콘솔에
//! 붙어 있지 않아서 `std.Io.File.stdout()` 이 PEB 의 빈 핸들을 돌려주고, 거기 쓴 글은
//! **아무 데도 나타나지 않는다.** 그래서 Windows 만 (1) 상속받은 std handle 을 먼저 보고
//! (2) 없으면 부모 콘솔에 붙어 `CONOUT$` 를 직접 연다.
//!
//! **남아 있는 Windows 한계 (미검증).** GUI subsystem 프로세스는 셸이 종료를 기다리지
//! 않는다. 그래서 `tildaz --version` 의 출력이 다음 프롬프트 *뒤에* 찍혀 보일 수 있다.
//! vim · ghostty 가 콘솔 subsystem 런처 (`.com`) 를 따로 두는 이유가 이것이다. 이 세션은
//! Linux 머신이라 실기 확인을 못 했다 — 실기에서 문제가 되면 런처 분리는 별도 이슈로 뗀다.

const std = @import("std");
const runtime = @import("runtime.zig");
const builtin = @import("builtin");
const windows = std.os.windows;

const Stream = enum { standard, diagnostic };

/// stdout. `--version` · `--help` 처럼 **요청한 결과**를 낸다.
pub fn out(text: []const u8) void {
    write(.standard, text);
}

/// stderr. 인자 오류처럼 **요청이 실패한 이유**를 낸다. 리다이렉트로 결과만 갈무리하는
/// 스크립트가 오류에 오염되지 않게 stdout 과 나눈다.
pub fn err(text: []const u8) void {
    write(.diagnostic, text);
}

/// 줄바꿈까지 붙여 한 번에 쓴다. 두 번 나눠 쓰면 다른 프로세스의 출력이 사이에 끼어든다.
pub fn outLine(text: []const u8) void {
    writeLine(.standard, text);
}

pub fn errLine(text: []const u8) void {
    writeLine(.diagnostic, text);
}

fn writeLine(stream: Stream, text: []const u8) void {
    var buf: [2048]u8 = undefined;
    const joined = std.fmt.bufPrint(&buf, "{s}\n", .{text}) catch {
        // 버퍼를 넘기는 긴 텍스트는 두 번에 나눠 쓴다. 줄이 갈릴 수 있지만 내용을
        // 버리지는 않는다.
        write(stream, text);
        write(stream, "\n");
        return;
    };
    write(stream, joined);
}

fn write(stream: Stream, text: []const u8) void {
    switch (builtin.os.tag) {
        .windows => writeWindows(stream, text),
        else => {
            const file: std.Io.File = switch (stream) {
                .standard => .stdout(),
                .diagnostic => .stderr(),
            };
            // 파이프가 닫혔거나 (`tildaz --version | head`) 콘솔이 없으면 쓸 곳이 없다.
            // 버전을 못 찍었다고 종료 코드를 바꾸지는 않는다.
            // Zig 0.16 — `fs.File.writeAll` ➡️ `Io.File.writeStreamingAll` (릴리즈 노트
            // upgrade guide) 이고 `io` 를 받는다. 이 경로는 `--version` · `--help` 처럼
            // 진입점이 `runtime.install` 을 부른 뒤에만 지나간다.
            file.writeStreamingAll(runtime.ioRequired(), text) catch {};
        },
    }
}

// ── Windows ────────────────────────────────────────────────────────────────

const STD_OUTPUT_HANDLE: windows.DWORD = 0xFFFF_FFF5; // (DWORD)-11
const STD_ERROR_HANDLE: windows.DWORD = 0xFFFF_FFF4; // (DWORD)-12
const ATTACH_PARENT_PROCESS: windows.DWORD = 0xFFFF_FFFF; // (DWORD)-1

extern "kernel32" fn AttachConsole(dwProcessId: windows.DWORD) callconv(.winapi) windows.BOOL;

fn writeWindows(stream: Stream, text: []const u8) void {
    const handle = windowsHandle(stream) orelse return;

    // 콘솔 핸들에 대한 WriteFile 은 바이트를 **콘솔 출력 코드페이지**로 해석한다.
    // 여기 나가는 텍스트 (`messages.zig` 의 CLI 문자열 + 버전) 는 전부 ASCII 라
    // 코드페이지가 무엇이든 같게 보인다. 비 ASCII 를 넣게 되면 `WriteConsoleW` 로
    // 바꿔야 한다.
    var remaining = text;
    while (remaining.len != 0) {
        var written: windows.DWORD = 0;
        const chunk: windows.DWORD = @intCast(@min(remaining.len, std.math.maxInt(u32)));
        if (windows.kernel32.WriteFile(handle, remaining.ptr, chunk, &written, null) == 0) return;
        if (written == 0) return; // 더 이상 진행되지 않는다 — 무한 루프 방지.
        remaining = remaining[written..];
    }
}

fn windowsHandle(stream: Stream) ?windows.HANDLE {
    // ① 상속받은 std handle 이 먼저다. `tildaz --version > out.txt` 처럼 셸이
    //    리다이렉트를 걸어 두면 GUI subsystem 이라도 그 핸들이 상속된다. 이걸 건너뛰고
    //    바로 CONOUT$ 를 열면 리다이렉트가 무시되고 콘솔로 새어 나간다.
    const id: windows.DWORD = switch (stream) {
        .standard => STD_OUTPUT_HANDLE,
        .diagnostic => STD_ERROR_HANDLE,
    };
    if (windows.kernel32.GetStdHandle(id)) |handle| {
        if (handle != windows.INVALID_HANDLE_VALUE) return handle;
    }

    // ② 콘솔에서 띄웠지만 GUI subsystem 이라 핸들이 없는 평범한 경우. 부모 콘솔에
    //    붙는다. 이미 콘솔이 있으면 ERROR_ACCESS_DENIED 로 실패하는데, 그때도 아래
    //    CONOUT$ 는 열리므로 결과를 보지 않는다.
    _ = AttachConsole(ATTACH_PARENT_PROCESS);

    // ③ 콘솔의 활성 출력 버퍼. stdout · stderr 모두 같은 이름을 쓴다 (`CONERR$` 는
    //    없다) — 콘솔로 떨어지는 시점에서 둘의 구분은 의미를 잃는다.
    const handle = windows.kernel32.CreateFileW(
        std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$"),
        windows.GENERIC_READ | windows.GENERIC_WRITE,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE,
        null,
        windows.OPEN_EXISTING,
        0,
        null,
    );
    // 부모가 콘솔이 아니면 (탐색기 · 작업 스케줄러 · 자동 시작) 여기서 실패한다.
    // 쓸 곳이 없다는 뜻이라 조용히 포기한다.
    if (handle == windows.INVALID_HANDLE_VALUE) return null;
    return handle;
}
