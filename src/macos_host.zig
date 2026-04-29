// macOS host — drop-down terminal entry point.
//
// 진행 메모는 이슈 #108 참고. 이번 M1 단계는 골격만:
//
//   - run(): "under construction" 메시지를 stderr 로 출력 후 정상 종료.
//   - showPanic / showFatalRunError 는 unsupported_host 와 같은 stderr-기반
//     포맷. NSAlert 같은 macOS-native UI 는 M2 (NSWindow 등장) 이후 검토.
//
// 향후 milestone:
//   M2 — NSWindow + CAMetalLayer 빈 화면 + Cmd+Q
//   M3 — 글로벌 단축키 토글 + dock rect (config.dock_position 적용)
//   M4 — POSIX PTY + ghostty-vt + CoreText/Metal 글리프
//   M5 — 한글 IME

const std = @import("std");
const build_options = @import("build_options");

pub fn showPanic(msg: []const u8, addr: usize) noreturn {
    std.debug.print("panic: {s}\nreturn address: 0x{x}\n", .{ msg, addr });
    std.process.exit(1);
}

pub fn showFatalRunError(err: anyerror) void {
    std.debug.print("TildaZ failed to start.\n\nError: {s}\n", .{@errorName(err)});
}

pub fn run() !void {
    std.debug.print(
        "TildaZ macOS v{s} — under construction (#108).\n" ++
            "M1: host skeleton wired up. Future milestones will bring up the\n" ++
            "drop-down NSWindow, dock rect toggle, and the PTY/renderer pipeline.\n",
        .{build_options.version},
    );
}
