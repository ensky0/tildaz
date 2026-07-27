//! Windows native 입력 상태를 공통 `input_policy` 실행 계획으로 변환한다.
//!
//! IMM 조작과 app action 자체는 각각 `window.zig` / `app_controller.zig`가
//! 담당한다. 이 모듈은 OS handle 없이 순수하게 다음 순서를 결정한다.
//!
//! 1. IMM preedit preserve/complete/cancel
//! 2. disposition target 실행

const std = @import("std");
const input_policy = @import("input_policy.zig");

pub const Snapshot = struct {
    /// `Window.imePreeditSlice().len`. terminal overlay의 실제 Windows IMM
    /// preedit byte 길이.
    ime_preedit_len: usize,
    /// Read-only shortcut보다 먼저 온 GCS_RESULTSTR를 아직 target에 보내지 않고
    /// 보류한 상태. overlay는 계속 preedit로 표시한다.
    ime_result_deferred: bool = false,
};

pub const NativePending = enum {
    none,
    preserve_ime,
    complete_ime,
    cancel_ime,
};

pub const Resolution = struct {
    disposition: input_policy.Disposition,
    native_pending: NativePending,
};

pub fn resolve(input: input_policy.Input, snapshot: Snapshot) Resolution {
    const has_ime_preedit = snapshot.ime_preedit_len > 0 or snapshot.ime_result_deferred;
    const state: input_policy.State = .{
        .terminal_preedit_active = has_ime_preedit,
    };
    const disposition = input_policy.resolve(input, state);

    return .{
        .disposition = disposition,
        .native_pending = switch (disposition.pending) {
            .leave => if (has_ime_preedit) .preserve_ime else .none,
            .commit => if (has_ime_preedit) .complete_ime else .none,
            .discard => if (has_ime_preedit) .cancel_ime else .none,
        },
    };
}

fn expectResolution(
    input: input_policy.Input,
    snapshot: Snapshot,
    pending: input_policy.Pending,
    target: input_policy.Target,
    native_pending: NativePending,
) !void {
    const got = resolve(input, snapshot);
    try std.testing.expectEqual(pending, got.disposition.pending);
    try std.testing.expectEqual(target, got.disposition.target);
    try std.testing.expectEqual(native_pending, got.native_pending);
}

test "Windows adapter — terminal preedit shortcut은 IMM complete 뒤 action" {
    const terminal = Snapshot{ .ime_preedit_len = 3 };
    try expectResolution(.{ .shortcut = .new_tab }, terminal, .commit, .run_action, .complete_ime);
    try expectResolution(.{ .shortcut = .copy_selection }, terminal, .commit, .run_action, .complete_ime);
}

test "Windows adapter — paste는 IMM complete 뒤 PTY(#340)" {
    try expectResolution(.paste, .{ .ime_preedit_len = 3 }, .commit, .pty, .complete_ime);
    try expectResolution(.paste, .{ .ime_preedit_len = 0 }, .commit, .pty, .none);
}

test "Windows adapter — Ctrl+C는 terminal preedit cancel" {
    try expectResolution(.interrupt, .{ .ime_preedit_len = 3 }, .discard, .pty, .cancel_ime);
}

test "Windows adapter — deferred result도 commit/discard 대상 preedit이다" {
    const deferred = Snapshot{ .ime_preedit_len = 0, .ime_result_deferred = true };
    try expectResolution(.{ .shortcut = .new_tab }, deferred, .commit, .run_action, .complete_ime);
    try expectResolution(.{ .shortcut = .copy_selection }, deferred, .commit, .run_action, .complete_ime);
    try expectResolution(.interrupt, deferred, .discard, .pty, .cancel_ime);
}

test "Windows adapter — preedit이 없으면 IMM 호출 계획도 없다" {
    try expectResolution(.{ .shortcut = .new_tab }, .{ .ime_preedit_len = 0 }, .commit, .run_action, .none);
    try expectResolution(.interrupt, .{ .ime_preedit_len = 0 }, .leave, .pty, .none);
}
