//! Cross-platform 로그인 자동 시작 — 사용자 로그인 시 OS 가 tildaz 를 자동
//! 실행. platform 별 mechanism:
//!
//!   - Windows: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
//!   - macOS:   `~/Library/LaunchAgents/com.tildaz.app.plist` (launchd)
//!   - Linux:   `$XDG_CONFIG_HOME/autostart/tildaz.desktop` (fallback `~/.config`)
//!
//! API 시그니처는 세 platform 동일 — `enable(rt, allocator)` / `disable(rt, allocator)`.
//! Windows 는 allocator 를 무시 (fixed buffer + Win32 API), macOS / Linux 는
//! path 작성에 사용. `rt` 는 #451 이후 파일 IO · 환경변수 통로다.

const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("runtime.zig").Runtime;
const instances = @import("instances.zig");

const impl = switch (builtin.os.tag) {
    .windows => @import("autostart/windows.zig"),
    .macos => @import("autostart/macos.zig"),
    .linux => @import("autostart/linux.zig"),
    else => struct {
        pub fn enable(_: Runtime, _: std.mem.Allocator) !void {
            return error.AutostartUnsupportedPlatform;
        }
        pub fn disable(_: Runtime, _: std.mem.Allocator) void {}
    },
};

pub fn enable(rt: Runtime, allocator: std.mem.Allocator) !void {
    return impl.enable(rt, allocator);
}

pub fn disable(rt: Runtime, allocator: std.mem.Allocator) void {
    impl.disable(rt, allocator);
}

/// config 들의 `auto_start` 에 자동 시작을 맞춘다 — 하나라도 true 면 켜고, 아니면 끈다.
/// launcher 의 평소 실행과 새 instance 생성이 같은 규칙을 쓰도록 한 곳에 둔다 (#755).
/// 예전에는 새 instance 가 config 를 보지 않고 켜서, `auto_start = false` 인 dev 판
/// config 로도 자동 시작이 등록됐다. 다 false 일 때 끌지는 #753 에서 정한다.
pub fn syncWithConfigs(rt: Runtime, allocator: std.mem.Allocator, indices: []const u32) !void {
    for (indices) |index| {
        if (try instances.configAutoStart(rt, allocator, index)) return enable(rt, allocator);
    }
    disable(rt, allocator);
}
