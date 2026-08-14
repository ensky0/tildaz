const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const config = @import("config.zig");
const dialog = @import("dialog.zig");
const instances = @import("instances.zig");
const messages = @import("messages.zig");
const autostart = @import("autostart.zig");
const log = @import("log.zig");
const shortcut_sync = @import("shortcut_sync.zig");
const hotkey_capture = @import("hotkey_capture.zig");

const ValidationContext = struct {
    /// #451 — 검증이 다른 인스턴스의 config 를 읽으므로 (`instances.*`) `Io` 가 필요하다.
    rt: Runtime,
    allocator: std.mem.Allocator,
};

fn validateHotkey(ctx_ptr: *anyopaque, text: []const u8) dialog.HotkeyValidation {
    const ctx: *ValidationContext = @ptrCast(@alignCast(ctx_ptr));
    const hotkey = config.Hotkey.fromString(text) orelse return .invalid;
    const current_indices = instances.listConfigIndices(ctx.rt, ctx.allocator) catch return .check_failed;
    defer ctx.allocator.free(current_indices);
    const owner = instances.hotkeyOwner(ctx.rt, ctx.allocator, current_indices, hotkey) catch return .check_failed;
    return if (owner) |index| .{ .duplicate = index } else .available;
}

/// #301 — nested modal 재진입 최종 방어. 정상 Windows plain launch는 sender가
/// request gate를 선점하고 SendMessageW 반환까지 보유하므로 여기서 겹치지 않는다.
/// 다만 gate owner가 prompt 도중 비정상 종료하면 다음 launcher가 abandoned mutex를
/// 얻어 동기 요청할 수 있으므로, 진행 중 요청은 여기서 병합해 worker 0 UI thread의
/// 중첩 prompt/hang을 막는다. handle은 main/UI thread 단일 실행이라 plain bool로 충분.
var handling: bool = false;

pub fn handle(rt: Runtime, allocator: std.mem.Allocator) void {
    if (handling) {
        log.appendLine("new-instance", "dropped re-entrant request (prompt in progress) — #301", .{});
        return;
    }
    handling = true;
    defer handling = false;

    // launcher의 config 열거/spawn 결정과 새 config 생성 transaction이 서로
    // 중간 상태를 관찰하지 않도록 같은 process lock으로 직렬화한다.
    var launcher_lock = instances.acquireLauncherLock(rt, allocator) catch |err| {
        showCreateError(rt, err);
        return;
    };
    defer launcher_lock.deinit(rt);

    const indices = instances.listConfigIndices(rt, allocator) catch |err| {
        showCreateError(rt, err);
        return;
    };
    defer allocator.free(indices);

    var prompt_buf: [256]u8 = undefined;
    const input_prompt = std.fmt.bufPrint(&prompt_buf, messages.new_instance_hotkey_prompt_format, .{indices.len + 1}) catch return;
    var validation_context = ValidationContext{ .rt = rt, .allocator = allocator };
    const input_owned = blk: {
        var capture = hotkey_capture.begin(indices) catch |err| {
            showCreateError(rt, err);
            return;
        };
        defer capture.deinit();
        break :blk dialog.promptHotkey(rt, allocator, messages.new_instance_title, input_prompt, .{
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
        showCreateError(rt, err);
        return;
    };
    const shell = instances.defaultShell(rt, allocator) catch |err| {
        allocator.free(input_owned);
        showCreateError(rt, err);
        return;
    };
    defer allocator.free(shell);
    instances.createDefaultConfig(rt, allocator, index, shell, input) catch |err| {
        allocator.free(input_owned);
        showCreateError(rt, err);
        return;
    };
    allocator.free(input_owned);
    var updated_indices = allocator.alloc(u32, indices.len + 1) catch |err| {
        showCreateError(rt, err);
        return;
    };
    defer allocator.free(updated_indices);
    @memcpy(updated_indices[0..indices.len], indices);
    updated_indices[indices.len] = index;
    shortcut_sync.sync(rt, allocator, updated_indices) catch |err| {
        showCreateError(rt, err);
        return;
    };
    autostart.enable(rt, allocator) catch |err| log.appendLine("autostart", "enable after instance create failed: {s}", .{@errorName(err)});
    instances.spawnWorker(rt, allocator, index) catch |err| {
        showCreateError(rt, err);
        return;
    };
    instances.waitUntilRunning(rt, allocator, index, 10 * std.time.ns_per_s) catch |err| {
        showCreateError(rt, err);
        return;
    };
}

fn showCreateError(rt: Runtime, err: anyerror) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, messages.new_instance_create_failed_format, .{@errorName(err)}) catch messages.new_instance_create_failed_fallback_msg;
    dialog.showError(rt, messages.new_instance_title, msg);
}
