//! Linux dialog backend — layer-shell overlay 통합 (option A, #203 Phase C).
//!
//! Host (wayland_minimal Client) 가 init 시 `registerCallbacks` 로 runtime
//! 콜백 등록. callback 미등록 환경 (host 초기화 전 fatal / cli mode 등) 에선
//! stderr + log fallback — silent crash 회피.
//!
//! 동작:
//!   - `show(severity, ...)` / `showAboutAlert(...)` — host info dialog 호출
//!     (non-blocking, fire-and-forget). Enter / Esc / OK 클릭 시 자동 닫힘.
//!   - `showConfirm(...)` — host confirm dialog 호출 (synchronous via inner
//!     wayland event loop pump). Cancel default.
//!
//! Wayland dialog API 표준 부재 — 자체 layer-shell overlay surface 그림.
//! 다른 옵션 비교 + 결정 흐름은 #203 / SPEC.md §6 참조.

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const dialog = @import("../dialog.zig");
const log = @import("../log.zig");

pub const Callbacks = struct {
    ctx: *anyopaque,
    show_info: *const fn (ctx: *anyopaque, severity: dialog.Severity, title: []const u8, message: []const u8) void,
    show_about: *const fn (ctx: *anyopaque, title: []const u8, message: []const u8) void,
    show_confirm: *const fn (ctx: *anyopaque, title: []const u8, message: []const u8) bool,
    prompt_hotkey: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, title: []const u8, message: []const u8, validator: dialog.HotkeyValidator) ?[]u8,
};

var g_callbacks: ?Callbacks = null;

/// Linux custom dialog가 저장하는 사용자 메시지의 UTF-8 byte 상한. active
/// overlay와 deferred info request가 같은 값을 사용해야 callback을 거치면서
/// 더 작은 상한으로 줄지 않는다 (#310).
pub const message_capacity: usize = 4096;

/// 고정 buffer에 온전한 UTF-8 prefix만 복사한다. 상한이 multibyte codepoint
/// 중간이거나 입력 자체가 잘못된 UTF-8이면 직전 유효 경계에서 멈춘다.
pub fn copyMessage(dest: []u8, source: []const u8) usize {
    var len: usize = 0;
    while (len < source.len and len < dest.len) {
        const seq_len: usize = std.unicode.utf8ByteSequenceLength(source[len]) catch break;
        if (seq_len > source.len - len or seq_len > dest.len - len) break;
        _ = std.unicode.utf8Decode(source[len..][0..seq_len]) catch break;
        len += seq_len;
    }
    @memcpy(dest[0..len], source[0..len]);
    return len;
}

/// Host (wayland_minimal Client) 가 init 마지막에 호출. 이후 dialog.* 가
/// stderr fallback 대신 host overlay 그림.
pub fn registerCallbacks(cb: Callbacks) void {
    g_callbacks = cb;
}

pub fn promptHotkey(rt: Runtime, allocator: std.mem.Allocator, title: []const u8, message: []const u8, validator: dialog.HotkeyValidator) ?[]u8 {
    _ = rt;
    if (g_callbacks) |cb| return cb.prompt_hotkey(cb.ctx, allocator, title, message, validator);
    showStderr(.info, title, message);
    return null;
}

/// Host shutdown 직전 호출 — main loop 빠져나간 후 dialog 호출 시 dangling
/// callback 회피 (예: deinit 안 fatal).
pub fn unregisterCallbacks() void {
    g_callbacks = null;
}

pub fn show(rt: Runtime, severity: dialog.Severity, title: []const u8, message: []const u8) void {
    _ = rt;
    if (g_callbacks) |cb| {
        cb.show_info(cb.ctx, severity, title, message);
        return;
    }
    // Fallback — host 초기화 전 / cli mode / dialog backend 등록 안 됨.
    // 창 띄울 backend 없으므로 사용자가 본문 보려면 stderr / log 필요.
    showStderr(severity, title, message);
}

/// Config parsing은 Wayland backend 등록 전에 실행되므로 이 경로는 stderr·log에
/// 동적 본문 전체를 남긴다. runtime fatal은 기존 overlay 경로를 사용한다 (#316).
pub fn showFatal(rt: Runtime, title: []const u8, message: []const u8) void {
    show(rt, .err, title, message);
}

pub fn showAboutAlert(rt: Runtime, title: []const u8, message: []const u8) void {
    _ = rt;
    if (g_callbacks) |cb| {
        cb.show_about(cb.ctx, title, message);
        return;
    }
    showStderr(.info, title, message);
}

/// "되돌릴 수 없는 작업" 직전 확인. Host 콜백 가용 시 modal 그림 + inner
/// event loop pump 로 사용자 선택 대기. 미가용 시 default Cancel (= false)
/// — 실수 종료 방지 (#116).
pub fn showConfirm(rt: Runtime, title: []const u8, message: []const u8) bool {
    _ = rt;
    if (g_callbacks) |cb| {
        const result = cb.show_confirm(cb.ctx, title, message);
        log.appendLine("dialog", "confirm title={s} result={s}", .{ title, if (result) "OK" else "Cancel" });
        return result;
    }
    showStderr(.info, title, message);
    return false;
}

fn showStderr(severity: dialog.Severity, title: []const u8, message: []const u8) void {
    const prefix = switch (severity) {
        .info => "info",
        .err => "error",
    };
    std.debug.print("[{s}] {s}\n{s}\n", .{ prefix, title, message });
    log.appendLine("dialog", "{s} title={s} msg={s} (stderr fallback)", .{ prefix, title, message });
}

test "Linux dialog message copy keeps the 4096-byte capacity" {
    var source: [message_capacity + 1]u8 = undefined;
    @memset(&source, 'x');
    var dest: [message_capacity]u8 = undefined;

    const lengths = [_]usize{ 511, 512, 513, 2048, 2049, 4096, 4097 };
    for (lengths) |source_len| {
        const copied = copyMessage(&dest, source[0..source_len]);
        try std.testing.expectEqual(@min(source_len, message_capacity), copied);
        try std.testing.expectEqualSlices(u8, source[0..copied], dest[0..copied]);
    }
}

test "Linux dialog message copy stops at a valid UTF-8 boundary" {
    var split_hangul: [message_capacity + 2]u8 = undefined;
    @memset(split_hangul[0 .. message_capacity - 1], 'x');
    @memcpy(split_hangul[message_capacity - 1 ..], "한");

    var dest: [message_capacity]u8 = undefined;
    const split_len = copyMessage(&dest, &split_hangul);
    try std.testing.expectEqual(message_capacity - 1, split_len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(dest[0..split_len]));

    var exact_hangul: [message_capacity]u8 = undefined;
    @memset(exact_hangul[0 .. message_capacity - 3], 'x');
    @memcpy(exact_hangul[message_capacity - 3 ..], "한");
    const exact_len = copyMessage(&dest, &exact_hangul);
    try std.testing.expectEqual(message_capacity, exact_len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(dest[0..exact_len]));

    var small_dest: [16]u8 = undefined;
    const invalid_len = copyMessage(&small_dest, "abc\xffdef");
    try std.testing.expectEqual(@as(usize, 3), invalid_len);
    try std.testing.expectEqualStrings("abc", small_dest[0..invalid_len]);
}
