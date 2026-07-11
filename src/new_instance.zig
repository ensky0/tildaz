const std = @import("std");
const config = @import("config.zig");
const dialog = @import("dialog.zig");
const instances = @import("instances.zig");
const messages = @import("messages.zig");
const autostart = @import("autostart.zig");
const log = @import("log.zig");
const shortcut_sync = @import("shortcut_sync.zig");

pub fn handle(allocator: std.mem.Allocator) void {
    // launcher의 config 열거/spawn 결정과 새 config 생성 transaction이 서로
    // 중간 상태를 관찰하지 않도록 같은 process lock으로 직렬화한다.
    var launcher_lock = instances.acquireLauncherLock(allocator) catch |err| {
        showCreateError(err);
        return;
    };
    defer launcher_lock.deinit();

    const indices = instances.listConfigIndices(allocator) catch |err| {
        showCreateError(err);
        return;
    };
    defer allocator.free(indices);

    var prompt_buf: [256]u8 = undefined;
    var input_prompt: []const u8 = std.fmt.bufPrint(&prompt_buf, messages.new_instance_hotkey_prompt_format, .{indices.len + 1}) catch return;
    while (true) {
        const input_owned = dialog.promptHotkey(allocator, messages.new_instance_title, input_prompt) orelse return;
        const input = std.mem.trim(u8, input_owned, " \t\r\n");
        const hotkey = config.Hotkey.fromString(input) orelse {
            allocator.free(input_owned);
            input_prompt = messages.new_instance_hotkey_invalid_msg;
            continue;
        };
        const taken = instances.hotkeyTaken(allocator, indices, hotkey) catch |err| {
            allocator.free(input_owned);
            showCreateError(err);
            return;
        };
        if (taken) {
            allocator.free(input_owned);
            input_prompt = messages.new_instance_hotkey_duplicate_msg;
            continue;
        }

        const index = instances.nextConfigIndex(indices) catch |err| {
            allocator.free(input_owned);
            showCreateError(err);
            return;
        };
        const shell = instances.defaultShell(allocator) catch |err| {
            allocator.free(input_owned);
            showCreateError(err);
            return;
        };
        defer allocator.free(shell);
        instances.createDefaultConfig(allocator, index, shell, input) catch |err| {
            allocator.free(input_owned);
            showCreateError(err);
            return;
        };
        allocator.free(input_owned);
        var updated_indices = allocator.alloc(u32, indices.len + 1) catch |err| {
            showCreateError(err);
            return;
        };
        defer allocator.free(updated_indices);
        @memcpy(updated_indices[0..indices.len], indices);
        updated_indices[indices.len] = index;
        shortcut_sync.sync(allocator, updated_indices) catch |err| {
            showCreateError(err);
            return;
        };
        autostart.enable(allocator) catch |err| log.appendLine("autostart", "enable after instance create failed: {s}", .{@errorName(err)});
        instances.spawnWorker(allocator, index) catch |err| {
            showCreateError(err);
            return;
        };
        instances.waitUntilRunning(allocator, index, 10 * std.time.ns_per_s) catch |err| {
            showCreateError(err);
            return;
        };
        return;
    }
}

fn showCreateError(err: anyerror) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, messages.new_instance_create_failed_format, .{@errorName(err)}) catch "The new TildaZ instance could not be created.";
    dialog.showError(messages.new_instance_title, msg);
}
