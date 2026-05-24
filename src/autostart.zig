//! Cross-platform 로그인 자동 시작 — 사용자 로그인 시 OS 가 tildaz 를 자동
//! 실행. platform 별 mechanism:
//!
//!   - Windows: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
//!   - macOS:   `~/Library/LaunchAgents/com.tildaz.app.plist` (launchd)
//!   - Linux:   `~/.config/autostart/tildaz.desktop` (XDG Autostart)
//!
//! API 시그니처는 세 platform 동일 — `enable(allocator)` / `disable(allocator)`.
//! Windows 는 allocator 를 무시 (fixed buffer + Win32 API), macOS / Linux 는
//! path 작성에 사용.

const std = @import("std");
const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .windows => @import("autostart/windows.zig"),
    .macos => @import("autostart/macos.zig"),
    .linux => @import("autostart/linux.zig"),
    else => struct {
        pub fn enable(_: std.mem.Allocator) !void {
            return error.AutostartUnsupportedPlatform;
        }
        pub fn disable(_: std.mem.Allocator) void {}
    },
};

pub fn enable(allocator: std.mem.Allocator) !void {
    return impl.enable(allocator);
}

pub fn disable(allocator: std.mem.Allocator) void {
    impl.disable(allocator);
}
