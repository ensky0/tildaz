//! #700 — `tildaz --desktop` 의 Linux 구현. 머리 주석은 `desktop_setup.zig` 에 있다.
//!
//! 데스크톱 쪽 단축키 등록은 `shortcut_sync` 가 한다. 그 함수는 넘긴 번호 목록에 맞춰 우리
//! 항목을 더하고, 목록에 없는 번호의 우리 항목을 지운다 (COSMIC · Hyprland · KDE · desktop
//! 항목). sway · Hyprland 자동실행은 `wm_linux` 가 한다.
const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Action = @import("../desktop_setup.zig").Action;
const instances = @import("../instances.zig");
const shortcut_sync = @import("../shortcut_sync.zig");
const wm_linux = @import("wm_linux.zig");
const log = @import("../log.zig");

pub fn run(rt: Runtime, allocator: std.mem.Allocator, action: Action) !void {
    switch (action) {
        .add, .cleanup => {
            const indices = try instances.listConfigIndices(rt, allocator);
            defer allocator.free(indices);
            try shortcut_sync.sync(rt, allocator, indices);
            // 자동실행은 add 만 건다. 사용자가 불러오는 줄을 지웠으면 그것은 사용자의 선택이라,
            // 설치 같은 명시적인 요청이 아니면 되살리지 않는다.
            if (action == .add) try wm_linux.run(rt, allocator, .add);
            log.appendLine("desktop", "--desktop {s} done for {d} instance(s)", .{ @tagName(action), indices.len });
        },
        .remove => {
            try shortcut_sync.removeAll(rt, allocator);
            try wm_linux.run(rt, allocator, .remove);
            log.appendLine("desktop", "--desktop remove done", .{});
        },
    }
}
