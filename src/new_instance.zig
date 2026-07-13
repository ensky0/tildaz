const std = @import("std");
const config = @import("config.zig");
const dialog = @import("dialog.zig");
const instances = @import("instances.zig");
const messages = @import("messages.zig");
const autostart = @import("autostart.zig");
const log = @import("log.zig");
const shortcut_sync = @import("shortcut_sync.zig");
const hotkey_capture = @import("hotkey_capture.zig");

const ValidationContext = struct {
    allocator: std.mem.Allocator,
};

fn validateHotkey(ctx_ptr: *anyopaque, text: []const u8) dialog.HotkeyValidation {
    const ctx: *ValidationContext = @ptrCast(@alignCast(ctx_ptr));
    const hotkey = config.Hotkey.fromString(text) orelse return .invalid;
    const current_indices = instances.listConfigIndices(ctx.allocator) catch return .check_failed;
    defer ctx.allocator.free(current_indices);
    const owner = instances.hotkeyOwner(ctx.allocator, current_indices, hotkey) catch return .check_failed;
    return if (owner) |index| .{ .duplicate = index } else .available;
}

/// #301 — 재진입 가드. Windows 에서 `promptHotkey` 의 modal 메시지 루프가 도는
/// 동안 큐에 쌓인 `WM_NEW_INSTANCE_REQUEST` 가 main WndProc 로 dispatch 되어
/// `handle` 이 재진입 → 중첩 프롬프트 + nested modal loop 가 hang("응답 없음"),
/// 그 창(worker 0 UI thread)을 죽이면 coordinator 가 죽어 전 instance 종료.
/// handle 은 main/UI thread 단일 실행이라 plain bool 로 충분. 진행 중이면 추가
/// 요청은 drop — macOS(notification coalesce)/Linux(pending bool + dialog skip)의
/// "연속 요청 1개 병합"과 동일 동작 (그쪽은 상위에서 이미 coalesce 하므로 무해).
var handling: bool = false;

pub fn handle(allocator: std.mem.Allocator) void {
    if (handling) {
        log.appendLine("new-instance", "재진입 요청 drop (프롬프트 진행 중) — #301", .{});
        return;
    }
    handling = true;
    defer handling = false;

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
    const input_prompt = std.fmt.bufPrint(&prompt_buf, messages.new_instance_hotkey_prompt_format, .{indices.len + 1}) catch return;
    var validation_context = ValidationContext{ .allocator = allocator };
    const input_owned = blk: {
        var capture = hotkey_capture.begin(indices) catch |err| {
            showCreateError(err);
            return;
        };
        defer capture.deinit();
        break :blk dialog.promptHotkey(allocator, messages.new_instance_title, input_prompt, .{
            .ctx = &validation_context,
            .validate_fn = validateHotkey,
        }) orelse return;
    };
    const input = std.mem.trim(u8, input_owned, " \t\r\n");
    _ = config.Hotkey.fromString(input) orelse {
        allocator.free(input_owned);
        return;
    };

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
}

fn showCreateError(err: anyerror) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, messages.new_instance_create_failed_format, .{@errorName(err)}) catch "The new TildaZ instance could not be created.";
    dialog.showError(messages.new_instance_title, msg);
}
