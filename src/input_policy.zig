//! #296 — 입력 상태(rename / terminal preedit) × 입력 종류의 처리 정책 단일 소스.
//!
//! host 는 native 입력(xkb sym / VK code / NSEvent)을 `Input` 으로 분류하고 IME
//! 통합만 담당한다. "그래서 무엇을 할지"(rename buffer 로? PTY 로? 단축키 실행?
//! pending 입력을 commit? preedit 자모 discard?)의 결정은 이 순수 함수 `resolve`
//! 한 곳에 모은다.
//!
//! 이전엔 이 정책이 host 3벌로 복제돼 어긋났다 — Windows `app_controller.onAppEvent`,
//! macOS `host/macos.zig` keyDown, Linux `wayland_minimal.renameShortcutYield` 등.
//! 그 divergence 가 곧 #282 A1·A3·A4·A5·A6·A9·A10 결함이었다. SPEC §4.1(rename
//! focus_loss 통합 표)/§5.1(preedit·copy 정책)이 canonical 이며, 아래 테스트가 그
//! 매트릭스를 코드로 고정한다.

const std = @import("std");

/// 현재 입력 상태. host 가 자기 rename / preedit 상태로 채운다.
pub const State = struct {
    /// 탭 이름 rename 편집 활성.
    rename_active: bool = false,
    /// 터미널(비-rename) IME preedit(조합 중 자모) 활성. rename 자체의 preedit 는
    /// `rename_active` 로 포괄되므로 여기엔 안 셈.
    terminal_preedit_active: bool = false,
};

/// host 가 native 입력에서 분류한 입력 종류.
pub const Input = union(enum) {
    /// 표시 가능한 문자(codepoint ≥ 0x20).
    text,
    /// rename 편집에 의미 있는 키 — enter / backspace / left / right / home / end /
    /// delete / escape. (RenameState 가 enter=commit, escape=cancel 등 자체 처리)
    edit_key,
    /// rename 편집에 의미 *없는* nav 키 — up / down / page_up / page_down / insert.
    /// rename 중 PTY 로 새지 않게 삼켜야 한다 (#282 A9).
    nav_key,
    /// 클립보드 paste 요청.
    paste,
    /// Ctrl+C (SIGINT = line abort). 터미널 preedit 자모 discard *시도* 후 SIGINT
    /// (best-effort — Pending.discard 참고).
    interrupt,
    /// 전역 단축키.
    shortcut: Shortcut,
};

/// 전역 단축키 종류. (paste 는 commit 정책이 달라 `Input.paste` 로 분리)
pub const Shortcut = enum {
    new_tab,
    close_tab,
    next_tab,
    prev_tab,
    switch_tab,
    reset_terminal,
    show_about,
    open_config,
    open_log,
    copy_selection,
    dump_perf,
    fullscreen,
    quit,
};

/// 진행 중 입력(rename / terminal preedit)을 어떻게 처리할지.
pub const Pending = enum {
    /// 그대로 둠 (rename buffer 편집 계속 / preedit 유지).
    leave,
    /// 확정 — rename 이면 현재 값으로 탭 이름 확정, terminal preedit 이면 자모를
    /// PTY 로 flush (SPEC §4.1 모든 focus_loss = commit).
    commit,
    /// 버림 — terminal preedit 자모를 폐기 (Ctrl+C = line abort, §5.1). best-effort:
    /// IME 가 preedit 을 남겨둔 경우만 실제로 폐기된다. Linux fcitx5 는 Ctrl+C 에서
    /// 자모를 먼저 확정해 preedit 이 비므로 이 분기가 안 타고 `가^C`(확정 후 SIGINT,
    /// 취소된 줄이라 무해)가 된다. macOS 는 discardMarkedText 로 완전 폐기.
    discard,
};

/// 입력을 최종적으로 어디로 보낼지.
pub const Target = enum {
    /// rename 편집 버퍼로.
    rename_buffer,
    /// 터미널 PTY 로.
    pty,
    /// 단축키 action 실행(host 가 실제 action 수행).
    run_action,
    /// 아무 데도 — 삼킴.
    drop,
};

pub const Disposition = struct {
    pending: Pending,
    target: Target,
};

/// 정책의 유일한 결정 지점. host 는 이 결과대로 pending 처리 후 target 으로 보낸다.
pub fn resolve(input: Input, state: State) Disposition {
    switch (input) {
        // 전역 단축키:
        //   - copy_selection / dump_perf 는 read-only(클립보드 읽기 / 로그 덤프).
        //     rename 편집을 끝내지 않는다 — rename 중엔 새 선택을 만들 수도 없고
        //     (마우스 클릭이 곧 commit) 기존 선택은 이미 클립보드라, 편집 중 복사가
        //     제목을 확정시키는 건 부자연스럽다(#296 사용자 검증). 단 터미널 preedit
        //     중에는 자모를 PTY 로 flush 해 보존(§5.1).
        //   - 그 외 단축키는 focus-loss 로 rename/preedit 확정(commit) 후 실행.
        .shortcut => |sc| {
            const read_only = sc == .copy_selection or sc == .dump_perf;
            if (read_only) {
                if (state.terminal_preedit_active and !state.rename_active)
                    return .{ .pending = .commit, .target = .run_action };
                return .{ .pending = .leave, .target = .run_action };
            }
            return .{ .pending = .commit, .target = .run_action };
        },

        // paste: rename 중이면 commit 없이 rename buffer 로(#285), 아니면 터미널
        // preedit 을 commit 한 뒤 PTY paste(자모 dangling 방지, #282 A4/A2).
        .paste => {
            if (state.rename_active) return .{ .pending = .leave, .target = .rename_buffer };
            return .{ .pending = .commit, .target = .pty };
        },

        // Ctrl+C: rename 중이면 no-op(삼킴), 터미널 preedit 중이면 자모 discard 후
        // SIGINT(§5.1 A5), 그 외 PTY 로 \x03.
        .interrupt => {
            if (state.rename_active) return .{ .pending = .leave, .target = .drop };
            if (state.terminal_preedit_active) return .{ .pending = .discard, .target = .pty };
            return .{ .pending = .leave, .target = .pty };
        },

        // 문자 / rename 편집키: rename 중이면 rename buffer, 아니면 PTY.
        .text, .edit_key => {
            if (state.rename_active) return .{ .pending = .leave, .target = .rename_buffer };
            return .{ .pending = .leave, .target = .pty };
        },

        // nav 키: rename 중이면 편집 의미 없어 삼킴(#282 A9), 아니면 PTY(escape seq).
        .nav_key => {
            if (state.rename_active) return .{ .pending = .leave, .target = .drop };
            return .{ .pending = .leave, .target = .pty };
        },
    }
}

// ── SPEC §4.1 / §5.1 매트릭스 미러 테스트 ────────────────────────────────────

const rename: State = .{ .rename_active = true };
const preedit: State = .{ .terminal_preedit_active = true };
const idle: State = .{};

fn expectDisp(input: Input, state: State, pending: Pending, target: Target) !void {
    const d = resolve(input, state);
    try std.testing.expectEqual(pending, d.pending);
    try std.testing.expectEqual(target, d.target);
}

test "SPEC §4.1 — rename 중 action 단축키는 commit 후 실행" {
    // 상태를 바꾸는 단축키(탭/reset/about/config/log/fullscreen/quit)는 focus-loss 로
    // rename 을 확정한 뒤 실행.
    for ([_]Shortcut{ .new_tab, .close_tab, .next_tab, .prev_tab, .switch_tab, .reset_terminal, .show_about, .open_config, .open_log, .fullscreen, .quit }) |sc| {
        try expectDisp(.{ .shortcut = sc }, rename, .commit, .run_action);
    }
}

test "#296 — read-only 단축키(copy/perf)는 rename 을 안 끝냄" {
    // rename 중 복사는 대상이 원천적으로 없고(마우스 선택=commit, 기존 선택=이미
    // 클립보드) 제목을 확정시키는 게 부자연스러움 → rename 유지(사용자 검증).
    try expectDisp(.{ .shortcut = .copy_selection }, rename, .leave, .run_action);
    try expectDisp(.{ .shortcut = .dump_perf }, rename, .leave, .run_action);
    // 상태 없을 때도 편집 아니니 leave (no-op commit 불필요).
    try expectDisp(.{ .shortcut = .copy_selection }, idle, .leave, .run_action);
    // 터미널 preedit 중에는 자모 보존 위해 flush(commit) 후 실행(§5.1).
    try expectDisp(.{ .shortcut = .copy_selection }, preedit, .commit, .run_action);
}

test "상태 없을 때 action 단축키는 commit(no-op) 후 실행" {
    try expectDisp(.{ .shortcut = .new_tab }, idle, .commit, .run_action);
}

test "SPEC §4.1 — rename 중 문자/편집키는 rename buffer 로" {
    try expectDisp(.text, rename, .leave, .rename_buffer);
    try expectDisp(.edit_key, rename, .leave, .rename_buffer);
}

test "rename 아닐 때 문자/편집키는 PTY 로" {
    try expectDisp(.text, idle, .leave, .pty);
    try expectDisp(.edit_key, idle, .leave, .pty);
}

test "#282 A9 — rename 중 nav 키는 삼킴, 아니면 PTY" {
    try expectDisp(.nav_key, rename, .leave, .drop);
    try expectDisp(.nav_key, idle, .leave, .pty);
}

test "#285 — paste 는 rename 중 buffer, 아니면 preedit commit 후 PTY" {
    try expectDisp(.paste, rename, .leave, .rename_buffer);
    try expectDisp(.paste, idle, .commit, .pty);
    try expectDisp(.paste, preedit, .commit, .pty);
}

test "#282 A5 §5.1 — Ctrl+C: preedit 중 discard, rename 중 삼킴, 그 외 PTY" {
    try expectDisp(.interrupt, preedit, .discard, .pty);
    try expectDisp(.interrupt, rename, .leave, .drop);
    try expectDisp(.interrupt, idle, .leave, .pty);
}
