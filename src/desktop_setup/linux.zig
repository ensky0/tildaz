//! #700 — `tildaz --desktop` 의 Linux 구현. 머리 주석은 `desktop_setup.zig` 에 있다.
//!
//! 1 단계 (뼈대): 데스크톱 쪽 단축키 등록은 이미 있는 `shortcut_sync.sync` 를 그대로 쓴다.
//! 그 함수는 넘긴 번호 목록에 맞춰 우리 항목을 더하고, 목록에 없는 번호의 우리 항목을 지운다
//! (COSMIC · Hyprland · KDE · desktop 항목). 그래서 `add` · `cleanup` 은 지금 있는 config
//! 번호로, `remove` 는 빈 목록으로 부르면 된다. COSMIC 구조 편집 (2 단계) 과 sway · Hyprland
//! 자동실행 (3 단계) 은 이 자리에 이어 붙인다.
const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Action = @import("../desktop_setup.zig").Action;
const instances = @import("../instances.zig");
const shortcut_sync = @import("../shortcut_sync.zig");
const log = @import("../log.zig");

pub fn run(rt: Runtime, allocator: std.mem.Allocator, action: Action) !void {
    switch (action) {
        .add, .cleanup => {
            const indices = try instances.listConfigIndices(rt, allocator);
            defer allocator.free(indices);
            try shortcut_sync.sync(rt, allocator, indices);
            log.appendLine("desktop", "--desktop {s} done for {d} instance(s)", .{ @tagName(action), indices.len });
        },
        .remove => {
            try shortcut_sync.sync(rt, allocator, &.{});
            log.appendLine("desktop", "--desktop remove done", .{});
        },
    }
}
