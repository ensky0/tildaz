//! #296 — 입력 상태(terminal preedit) × 입력 종류의 처리 정책 단일 소스.
//!
//! host 는 native 입력(xkb sym / VK code / NSEvent)을 `Input` 으로 분류하고 IME
//! 통합만 담당한다. "그래서 무엇을 할지"(PTY 로? 단축키 실행? pending 입력을
//! commit? preedit 자모 discard?)의 결정은 이 순수 함수 `resolve` 한 곳에 모은다.
//!
//! 이전엔 이 정책이 host 3벌로 복제돼 어긋났다 — Windows `app_controller.onAppEvent`,
//! macOS `host/macos.zig` keyDown, Linux `wayland_minimal.processKeyEvent` 등.
//! 그 divergence 가 곧 #282 A1·A3·A4·A5·A6 결함이었다. SPEC §4.1(preedit
//! focus_loss 표)/§5.1(preedit·copy 정책)이 canonical 이며, 아래 테스트가 그
//! 매트릭스를 코드로 고정한다.
//!
//! (탭 inline rename 은 #341 로 제거 — `rename_active` 상태 축과
//! `rename_buffer` target, 문자/편집키/나브키 분류가 함께 사라졌다.)

const std = @import("std");

/// 현재 입력 상태. host 가 자기 preedit 상태로 채운다.
pub const State = struct {
    /// 터미널 IME preedit(조합 중 자모) 활성.
    terminal_preedit_active: bool = false,
};

/// host 가 native 입력에서 분류한 입력 종류. 상태 의존 정책이 있는 입력만
/// 여기로 온다 — 일반 문자/키는 host 가 바로 PTY 로 보낸다.
pub const Input = union(enum) {
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
    toggle_visibility,
    fullscreen,
    /// #493 3-c — 패널을 가리지 않는 fullscreen. 예전엔 `fullscreen` 하나에 host 별로
    /// "Shift 가 눌렸으면 workarea" 라는 암묵 규칙이 붙어 있었다. `[keys]` 가 두
    /// 동작을 각각 바인딩할 수 있게 되면서 그 규칙을 없애고 variant 를 나눈다 —
    /// 사용자가 `fullscreen_workarea` 에 Shift 없는 조합을 줄 수도 있으므로 Shift 로
    /// 갈라서는 안 된다.
    fullscreen_workarea,
    quit,
    /// `…` 버튼으로 command menu 를 여는 순간 (#329). outside click 과 같은
    /// 상태 변경 — pending 입력(terminal preedit)을 먼저 commit 한다.
    open_command_menu,
    /// command menu 의 `Keyboard Shortcuts` — 기본 브라우저 열기 (#329).
    open_shortcuts,
    /// #483 — 화면 분할. 방향은 `config.ActionInput.direction` 에 있다 (`switch_tab` 의
    /// `tab_index` 와 같은 방식). 상태를 바꾸므로 preedit 은 commit 후 실행한다.
    split,
    focus_pane,
    resize_pane,
    equalize_panes,
};

/// 진행 중 입력(terminal preedit)을 어떻게 처리할지.
pub const Pending = enum {
    /// 그대로 둠 (preedit 유지).
    leave,
    /// 확정 — preedit 자모를 PTY 로 flush (SPEC §4.1 모든 focus_loss = commit).
    commit,
    /// 버림 — terminal preedit 자모를 폐기 (Ctrl+C = line abort, §5.1). best-effort:
    /// IME 가 preedit 을 남겨둔 경우만 실제로 폐기된다. Linux fcitx5 는 Ctrl+C 에서
    /// 자모를 먼저 확정해 preedit 이 비므로 이 분기가 안 타고 `가^C`(확정 후 SIGINT,
    /// 취소된 줄이라 무해)가 된다. macOS 는 discardMarkedText 로 완전 폐기.
    discard,
};

/// 입력을 최종적으로 어디로 보낼지.
pub const Target = enum {
    /// 터미널 PTY 로.
    pty,
    /// 단축키 action 실행(host 가 실제 action 수행).
    run_action,
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
        //     터미널 preedit 중에는 자모를 PTY 로 flush 해 보존(§5.1), 그 외엔
        //     leave (no-op commit 불필요).
        //   - 그 외 단축키는 focus-loss 로 preedit 확정(commit) 후 실행.
        .shortcut => |sc| {
            const read_only = sc == .copy_selection or sc == .dump_perf;
            if (read_only) {
                if (state.terminal_preedit_active)
                    return .{ .pending = .commit, .target = .run_action };
                return .{ .pending = .leave, .target = .run_action };
            }
            return .{ .pending = .commit, .target = .run_action };
        },

        // paste: 조합을 먼저 확정하고 payload 를 잇는다 — native textbox 동등(#340,
        // '하' 조합 + 'X' paste = '하X'). 터미널 preedit 을 commit 한 뒤 PTY paste
        // (자모 dangling 방지, #282 A4/A2).
        .paste => return .{ .pending = .commit, .target = .pty },

        // Ctrl+C: 터미널 preedit 중이면 자모 discard 후 SIGINT(§5.1 A5), 그 외
        // PTY 로 \x03.
        .interrupt => {
            if (state.terminal_preedit_active) return .{ .pending = .discard, .target = .pty };
            return .{ .pending = .leave, .target = .pty };
        },
    }
}

// ── SPEC §4.1 / §5.1 매트릭스 미러 테스트 ────────────────────────────────────

const preedit: State = .{ .terminal_preedit_active = true };
const idle: State = .{};

fn expectDisp(input: Input, state: State, pending: Pending, target: Target) !void {
    const d = resolve(input, state);
    try std.testing.expectEqual(pending, d.pending);
    try std.testing.expectEqual(target, d.target);
}

test "SPEC §4.1 — preedit 중 action 단축키는 commit 후 실행" {
    // 상태를 바꾸는 단축키(탭/reset/about/config/log/fullscreen/quit)는 focus-loss 로
    // preedit 을 확정한 뒤 실행.
    for ([_]Shortcut{ .new_tab, .close_tab, .next_tab, .prev_tab, .switch_tab, .reset_terminal, .show_about, .open_config, .open_log, .toggle_visibility, .fullscreen, .fullscreen_workarea, .quit, .open_command_menu, .open_shortcuts, .split, .focus_pane, .resize_pane, .equalize_panes }) |sc| {
        try expectDisp(.{ .shortcut = sc }, preedit, .commit, .run_action);
    }
}

test "#296 — read-only 단축키(copy/perf)는 preedit 자모를 flush 해 보존" {
    // 상태 없을 때는 편집 아니니 leave (no-op commit 불필요).
    try expectDisp(.{ .shortcut = .copy_selection }, idle, .leave, .run_action);
    try expectDisp(.{ .shortcut = .dump_perf }, idle, .leave, .run_action);
    // 터미널 preedit 중에는 자모 보존 위해 flush(commit) 후 실행(§5.1).
    try expectDisp(.{ .shortcut = .copy_selection }, preedit, .commit, .run_action);
    try expectDisp(.{ .shortcut = .dump_perf }, preedit, .commit, .run_action);
}

test "상태 없을 때 action 단축키는 commit(no-op) 후 실행" {
    try expectDisp(.{ .shortcut = .new_tab }, idle, .commit, .run_action);
}

test "#317 — macOS menu/key-equivalent 상태변경 shortcut은 pending 입력 commit 후 실행" {
    for ([_]Shortcut{ .show_about, .open_config, .open_log, .quit }) |sc| {
        try expectDisp(.{ .shortcut = sc }, preedit, .commit, .run_action);
    }
}

test "#340 — paste 는 preedit commit 후 PTY" {
    try expectDisp(.paste, idle, .commit, .pty);
    try expectDisp(.paste, preedit, .commit, .pty);
}

test "#282 A5 §5.1 — Ctrl+C: preedit 중 discard, 그 외 PTY" {
    try expectDisp(.interrupt, preedit, .discard, .pty);
    try expectDisp(.interrupt, idle, .leave, .pty);
}
