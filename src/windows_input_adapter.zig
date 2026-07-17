//! Windows native 입력 상태를 공통 `input_policy` 실행 계획으로 변환한다.
//!
//! IMM 조작과 app action 자체는 각각 `window.zig` / `app_controller.zig`가
//! 담당한다. 이 모듈은 OS handle 없이 순수하게 다음 순서를 결정한다.
//!
//! 1. IMM preedit preserve/complete/cancel
//! 2. rename commit (complete 결과가 rename buffer에 들어간 뒤)
//! 3. disposition target 실행

const std = @import("std");
const input_policy = @import("input_policy.zig");

pub const Snapshot = struct {
    rename_active: bool,
    /// `Window.imePreeditSlice().len`. rename/terminal overlay가 공유하는 실제
    /// Windows IMM preedit byte 길이이며, rename이 활성일 때는 rename preedit다.
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
    /// `complete_ime`의 동기 결과가 rename buffer에 들어간 *뒤* 실행한다.
    commit_rename_after_ime: bool,
};

pub fn resolve(input: input_policy.Input, snapshot: Snapshot) Resolution {
    const state: input_policy.State = .{
        .rename_active = snapshot.rename_active,
        // rename preedit는 rename_active 축이 포괄한다. 같은 Window buffer라도
        // terminal 축으로 중복 보고하지 않는다.
        .terminal_preedit_active = !snapshot.rename_active and
            (snapshot.ime_preedit_len > 0 or snapshot.ime_result_deferred),
    };
    const disposition = input_policy.resolve(input, state);
    const has_ime_preedit = snapshot.ime_preedit_len > 0 or snapshot.ime_result_deferred;

    return .{
        .disposition = disposition,
        .native_pending = switch (disposition.pending) {
            .leave => if (has_ime_preedit) .preserve_ime else .none,
            .commit => if (has_ime_preedit) .complete_ime else .none,
            .discard => if (has_ime_preedit) .cancel_ime else .none,
        },
        .commit_rename_after_ime = snapshot.rename_active and disposition.pending == .commit,
    };
}

fn expectResolution(
    input: input_policy.Input,
    snapshot: Snapshot,
    pending: input_policy.Pending,
    target: input_policy.Target,
    native_pending: NativePending,
    commit_rename_after_ime: bool,
) !void {
    const got = resolve(input, snapshot);
    try std.testing.expectEqual(pending, got.disposition.pending);
    try std.testing.expectEqual(target, got.disposition.target);
    try std.testing.expectEqual(native_pending, got.native_pending);
    try std.testing.expectEqual(commit_rename_after_ime, got.commit_rename_after_ime);
}

test "Windows adapter — terminal preedit shortcut은 IMM complete 뒤 action" {
    const terminal = Snapshot{ .rename_active = false, .ime_preedit_len = 3 };
    try expectResolution(.{ .shortcut = .new_tab }, terminal, .commit, .run_action, .complete_ime, false);
    try expectResolution(.{ .shortcut = .copy_selection }, terminal, .commit, .run_action, .complete_ime, false);
}

test "Windows adapter — rename preedit은 complete 뒤 rename commit 뒤 action" {
    const rename = Snapshot{ .rename_active = true, .ime_preedit_len = 3 };
    try expectResolution(.{ .shortcut = .new_tab }, rename, .commit, .run_action, .complete_ime, true);
    try expectResolution(.{ .shortcut = .switch_tab }, rename, .commit, .run_action, .complete_ime, true);
    try expectResolution(.{ .shortcut = .toggle_visibility }, rename, .commit, .run_action, .complete_ime, true);
    try expectResolution(.{ .shortcut = .fullscreen }, rename, .commit, .run_action, .complete_ime, true);
    try expectResolution(.{ .shortcut = .quit }, rename, .commit, .run_action, .complete_ime, true);
}

test "Windows adapter — read-only shortcut은 rename/preedit을 유지" {
    const rename = Snapshot{ .rename_active = true, .ime_preedit_len = 3 };
    try expectResolution(.{ .shortcut = .copy_selection }, rename, .leave, .run_action, .preserve_ime, false);
    try expectResolution(.{ .shortcut = .dump_perf }, rename, .leave, .run_action, .preserve_ime, false);
    try expectResolution(.{ .shortcut = .copy_selection }, .{ .rename_active = true, .ime_preedit_len = 0, .ime_result_deferred = true }, .leave, .run_action, .preserve_ime, false);
}

test "Windows adapter — paste는 terminal complete, rename leave" {
    try expectResolution(.paste, .{ .rename_active = false, .ime_preedit_len = 3 }, .commit, .pty, .complete_ime, false);
    try expectResolution(.paste, .{ .rename_active = true, .ime_preedit_len = 3 }, .leave, .rename_buffer, .preserve_ime, false);
}

test "Windows adapter — Ctrl+C는 terminal cancel, rename drop" {
    try expectResolution(.interrupt, .{ .rename_active = false, .ime_preedit_len = 3 }, .discard, .pty, .cancel_ime, false);
    try expectResolution(.interrupt, .{ .rename_active = true, .ime_preedit_len = 3 }, .leave, .drop, .preserve_ime, false);
}

test "Windows adapter — deferred result도 commit/discard 대상 preedit이다" {
    const deferred = Snapshot{ .rename_active = false, .ime_preedit_len = 0, .ime_result_deferred = true };
    try expectResolution(.{ .shortcut = .new_tab }, deferred, .commit, .run_action, .complete_ime, false);
    try expectResolution(.interrupt, deferred, .discard, .pty, .cancel_ime, false);
}

test "Windows adapter — preedit이 없으면 IMM 호출 계획도 없다" {
    try expectResolution(.{ .shortcut = .new_tab }, .{ .rename_active = false, .ime_preedit_len = 0 }, .commit, .run_action, .none, false);
    try expectResolution(.interrupt, .{ .rename_active = false, .ime_preedit_len = 0 }, .leave, .pty, .none, false);
}
