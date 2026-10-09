//! #700 — `tildaz --desktop` 의 Linux 구현. 머리 주석은 `desktop_setup.zig` 에 있다.
//!
//! 데스크톱 쪽 단축키 등록은 `shortcut_sync` 가 한다. 그 함수는 넘긴 번호 목록에 맞춰 우리
//! 항목을 더하고, 목록에 없는 번호의 우리 항목을 지운다 (COSMIC · Hyprland · KDE · desktop
//! 항목). sway · Hyprland 자동실행은 `sway_hyprland` 가 한다.
const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Action = @import("../desktop_setup.zig").Action;
const instances = @import("../instances.zig");
const shortcut_sync = @import("../shortcut_sync.zig");
const sway_hyprland = @import("sway_hyprland.zig");
const log = @import("../log.zig");
const unix_socket = @import("../host/linux/unix_socket.zig");
const sway_ipc = @import("../host/linux/sway_ipc.zig");
const hyprland_ipc = @import("../host/linux/hyprland_ipc.zig");
const wayland_minimal = @import("../host/linux/wayland_minimal.zig");
const autostart_notice = @import("autostart_notice.zig");

pub fn run(rt: Runtime, allocator: std.mem.Allocator, action: Action) !void {
    switch (action) {
        .add, .cleanup => {
            const indices = try instances.listConfigIndices(rt, allocator);
            defer allocator.free(indices);
            try shortcut_sync.sync(rt, allocator, indices);
            // 자동실행은 add 만 건다. 사용자가 불러오는 줄을 지웠으면 그것은 사용자의 선택이라,
            // 설치 같은 명시적인 요청이 아니면 되살리지 않는다.
            if (action == .add) try sway_hyprland.run(rt, allocator, .add);
            log.appendLine("desktop", "--desktop {s} done for {d} instance(s)", .{ @tagName(action), indices.len });
        },
        .remove => {
            try shortcut_sync.removeAll(rt, allocator);
            try sway_hyprland.run(rt, allocator, .remove);
            log.appendLine("desktop", "--desktop remove done", .{});
        },
    }
}

/// #701 — launcher 가 뜰 때 부른다. 지금 세션이 sway · Hyprland 면 그 자동 실행을 넣는다
/// (규칙은 `sway_hyprland.zig` 머리 주석). 실패해도 launcher 를 막지 않는다 — 로그만 남긴다.
pub fn onLaunch(rt: Runtime, allocator: std.mem.Allocator) void {
    const target = currentCompositor(rt, allocator) orelse return;
    const inserted = (sway_hyprland.launch(rt, allocator, target) catch |err| {
        log.appendLine("desktop", "{s} autostart could not be set up: {s}", .{ @tagName(target), @errorName(err) });
        return;
    }) orelse return;
    defer inserted.deinit(allocator);
    log.appendLine("desktop", "{s} autostart added to {s}", .{ @tagName(target), inserted.path });
    // 사용자 설정 파일에 줄이 생겼으니 한 번 알린다. launcher 는 창이 없어 worker 가 보여 준다.
    const desktop_name = switch (target) {
        .sway => "sway",
        .hyprland => "Hyprland",
    };
    autostart_notice.record(rt, allocator, desktop_name, inserted.path, inserted.line) catch |err|
        log.appendLine("desktop", "autostart notice could not be recorded: {s}", .{@errorName(err)});
}

/// 지금 세션의 compositor 가 sway · Hyprland 인가. 환경변수가 있는지만으로 판정하지 않는다 —
/// 로그아웃한 sway 세션의 `SWAYSOCK` 이 다음 KDE 세션에 남는다 (2026-10-09 KDE Plasma 실기).
/// launcher 는 Wayland 연결이 없어서 소켓에 잠깐 붙어 그 상대를 worker 의 판정 (#454) 에 넘긴다.
fn currentCompositor(rt: Runtime, allocator: std.mem.Allocator) ?sway_hyprland.Target {
    const path = wayland_minimal.waylandSocketPath(rt, allocator) catch return null;
    defer allocator.free(path);
    const fd = unix_socket.openSocket(std.posix.SOCK.CLOEXEC) catch return null;
    defer unix_socket.closeFd(fd);
    unix_socket.connect(fd, path) catch return null;
    if (sway_ipc.isSwayCompositor(rt, fd)) return .sway;
    if (hyprland_ipc.isHyprlandCompositor(rt, fd)) return .hyprland;
    return null;
}
