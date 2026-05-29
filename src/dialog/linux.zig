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
//! 다른 옵션 비교 + 결정 흐름은 #203 / SPEC.md §6 / LINUX.md 참조.

const std = @import("std");
const dialog = @import("../dialog.zig");
const log = @import("../log.zig");

pub const Callbacks = struct {
    ctx: *anyopaque,
    show_info: *const fn (ctx: *anyopaque, severity: dialog.Severity, title: []const u8, message: []const u8) void,
    show_confirm: *const fn (ctx: *anyopaque, title: []const u8, message: []const u8) bool,
};

var g_callbacks: ?Callbacks = null;

/// Host (wayland_minimal Client) 가 init 마지막에 호출. 이후 dialog.* 가
/// stderr fallback 대신 host overlay 그림.
pub fn registerCallbacks(cb: Callbacks) void {
    g_callbacks = cb;
}

/// Host shutdown 직전 호출 — main loop 빠져나간 후 dialog 호출 시 dangling
/// callback 회피 (예: deinit 안 fatal).
pub fn unregisterCallbacks() void {
    g_callbacks = null;
}

pub fn show(severity: dialog.Severity, title: []const u8, message: []const u8) void {
    if (g_callbacks) |cb| {
        cb.show_info(cb.ctx, severity, title, message);
        return;
    }
    // Fallback — host 초기화 전 / cli mode / dialog backend 등록 안 됨.
    // 창 띄울 backend 없으므로 사용자가 본문 보려면 stderr / log 필요.
    showStderr(severity, title, message);
}

pub fn showAboutAlert(title: []const u8, message: []const u8) void {
    show(.info, title, message);
}

/// "되돌릴 수 없는 작업" 직전 확인. Host 콜백 가용 시 modal 그림 + inner
/// event loop pump 로 사용자 선택 대기. 미가용 시 default Cancel (= false)
/// — 실수 종료 방지 (#116).
pub fn showConfirm(title: []const u8, message: []const u8) bool {
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
