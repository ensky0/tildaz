//! #296 — 입력 상태(terminal preedit / 검색바) × 입력 종류의 처리 정책 단일 소스.
//!
//! host 는 native 입력(xkb sym / VK code / NSEvent)을 `Input` 으로 분류하고 IME
//! 통합만 담당한다. "그래서 무엇을 할지"(검색 입력칸으로? PTY 로? 단축키 실행?
//! pending 입력을 commit? preedit 자모 discard?)의 결정은 이 순수 함수 `resolve`
//! 한 곳에 모은다.
//!
//! 이전엔 이 정책이 host 3벌로 복제돼 어긋났다 — Windows `app_controller.onAppEvent`,
//! macOS `host/macos.zig` keyDown, Linux `wayland_minimal.processKeyEvent` 등.
//! 그 divergence 가 곧 #282 A1·A3·A4·A5·A6 결함이었다. SPEC §4.1(preedit
//! focus_loss 표)/§5.1(preedit·copy 정책)이 canonical 이며, 아래 테스트가 그
//! 매트릭스를 코드로 고정한다.
//!
//! (탭 inline rename 은 #341 로 제거 — `rename_active` 상태 축과
//! `rename_buffer` target, 문자/편집키/나브키 분류가 함께 사라졌다.)
//!
//! **#646 이 그 축을 같은 모양으로 되살린다.** 검색바가 다시 "키가 터미널이 아닌 곳으로
//! 가는 상태" 를 만들기 때문이다. 그때 결함을 낳은 것은 축의 존재가 아니라 **host 3 벌로
//! 흩어진 판정** 이었으므로 (#282 A1·A3·A4·A5·A6), 판정은 여기 한 곳에 두고 host 는
//! 분류와 실행만 한다. 키의 *의미* (어느 키가 무엇을 하는가) 는 또 한 겹 아래,
//! `search_input.zig` 가 정한다 — rename 때 `tab_interaction.RenameState` 가 맡던 자리다.
//!
//! rename 과 다른 점이 하나 있다. rename 의 `commit` 은 "조합 자모 flush" 와 "탭 이름
//! 확정" 두 가지를 뜻해서 전자만 하는 `commit_preedit` 변종이 따로 필요했다. 검색바는
//! 단축키로 닫히지 않으므로 (pane 을 옮겨도 상태가 남는다) `commit` 이 오직 flush 만
//! 뜻한다 — 그래서 그 변종이 없다.

const std = @import("std");

/// 현재 입력 상태. host 가 자기 preedit 상태로 채운다.
pub const State = struct {
    /// 터미널 IME preedit(조합 중 자모) 활성. **검색 입력칸 자체의 preedit 는 여기에
    /// 안 센다** — 그쪽은 `search_active` 가 포괄한다. 둘을 섞으면 sink 를 못 고른다
    /// (같은 "조합 중" 이라도 확정될 자리가 PTY 냐 검색어냐가 다르다).
    terminal_preedit_active: bool = false,

    /// #646 — 검색바가 열려 **키보드 포커스를 갖고 있다**. `PaneSearch.is_open` 과 따로
    /// 두는 이유는, 바가 떠 있어도 포커스가 터미널에 있으면 키는 셸로 가야 하기
    /// 때문이다 (마우스로 터미널을 눌렀을 때).
    search_active: bool = false,
};

/// host 가 native 입력에서 분류한 입력 종류. 상태 의존 정책이 있는 입력만
/// 여기로 온다 — 일반 문자/키는 host 가 바로 PTY 로 보낸다.
pub const Input = union(enum) {
    /// 표시 가능한 문자(codepoint ≥ 0x20).
    text,
    /// 텍스트 편집에 의미 있는 키 — enter / backspace / left / right / home / end /
    /// delete / escape. **어느 키가 무엇을 하는지는 여기서 안 정한다** — 이 분류는
    /// "검색 입력칸이 먹을 키" 라는 뜻이고, 의미는 `search_input.Key` 가 맡는다.
    edit_key,
    /// 편집에 의미 *없는* nav 키 — up / down / page_up / page_down / insert.
    /// 검색 중 PTY 로 새지 않게 삼킨다 (#282 A9 와 같은 자리).
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
    zoom_pane,
    /// #544 — 활성 pane 하나 닫기. `close_tab` 과 정책이 같다 (상태를 바꾸므로 preedit 은
    /// commit 후 실행).
    close_pane,
    /// #646 — 버퍼 안 검색바를 연다. 상태를 바꾸므로 (키보드 포커스가 터미널에서 바로 옮겨간다)
    /// 다른 상태 변경 단축키와 같이 preedit 을 먼저 commit 한다 — 조합 중이던 자모가 검색어로
    /// 흘러 들어가면 안 된다.
    open_search,
};

/// 진행 중 입력(terminal preedit)을 어떻게 처리할지.
pub const Pending = enum {
    /// 그대로 둠 (preedit 유지).
    leave,
    /// 확정 — preedit 자모를 **지금의 sink** 로 flush 한다 (SPEC §4.1 모든 focus_loss =
    /// commit). sink 는 `search_active` 면 검색 입력칸이고 아니면 PTY 다.
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
    /// #646 — 검색바 입력칸으로. 받은 쪽이 할 일은 `search_input.zig` 가 정한다.
    search_field,
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
        // (자모 dangling 방지, #282 A4/A2). 검색 중이면 조합도 payload 도 입력칸으로
        // 간다 — sink 가 바뀔 뿐 순서 규칙은 같다.
        .paste => {
            if (state.search_active) return .{ .pending = .commit, .target = .search_field };
            return .{ .pending = .commit, .target = .pty };
        },

        // Ctrl+C: 터미널 preedit 중이면 자모 discard 후 SIGINT(§5.1 A5), 그 외
        // PTY 로 \x03.
        //
        // 검색 입력칸에서는 삼킨다. 검색어를 치다가 셸이 SIGINT 를 받으면 안 되고
        // (#282 A9 가 rename 에서 막던 것과 같은 샘), 검색바를 벗어나는 키는 Esc 다.
        .interrupt => {
            if (state.search_active) return .{ .pending = .leave, .target = .drop };
            if (state.terminal_preedit_active) return .{ .pending = .discard, .target = .pty };
            return .{ .pending = .leave, .target = .pty };
        },

        // 문자 / 편집키: 검색 중이면 입력칸, 아니면 PTY.
        .text, .edit_key => {
            if (state.search_active) return .{ .pending = .leave, .target = .search_field };
            return .{ .pending = .leave, .target = .pty };
        },

        // nav 키: 한 줄짜리 입력칸에서는 뜻이 없으니 삼킨다 (#282 A9). 삼키지 않으면
        // 검색어를 치는 동안 방향키 escape sequence 가 셸로 새어 히스토리가 넘어간다.
        .nav_key => {
            if (state.search_active) return .{ .pending = .leave, .target = .drop };
            return .{ .pending = .leave, .target = .pty };
        },
    }
}

// ── SPEC §4.1 / §5.1 매트릭스 미러 테스트 ────────────────────────────────────

const preedit: State = .{ .terminal_preedit_active = true };
const searching: State = .{ .search_active = true };
const idle: State = .{};

fn expectDisp(input: Input, state: State, pending: Pending, target: Target) !void {
    const d = resolve(input, state);
    try std.testing.expectEqual(pending, d.pending);
    try std.testing.expectEqual(target, d.target);
}

test "SPEC §4.1 — preedit 중 action 단축키는 commit 후 실행" {
    // 상태를 바꾸는 단축키(탭/reset/about/config/log/fullscreen/quit)는 focus-loss 로
    // preedit 을 확정한 뒤 실행.
    for ([_]Shortcut{ .new_tab, .close_tab, .next_tab, .prev_tab, .switch_tab, .reset_terminal, .show_about, .open_config, .open_log, .toggle_visibility, .fullscreen, .fullscreen_workarea, .quit, .open_command_menu, .open_shortcuts, .split, .focus_pane, .resize_pane, .equalize_panes, .zoom_pane, .close_pane }) |sc| {
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

// ── #646 검색바 축 ───────────────────────────────────────────────────────────

test "#646 — 검색 중 문자/편집키는 입력칸으로, 아니면 PTY" {
    try expectDisp(.text, searching, .leave, .search_field);
    try expectDisp(.edit_key, searching, .leave, .search_field);
    try expectDisp(.text, idle, .leave, .pty);
    try expectDisp(.edit_key, idle, .leave, .pty);
}

test "#646 — 검색 중 nav 키는 삼킨다 (셸 히스토리로 새지 않게)" {
    try expectDisp(.nav_key, searching, .leave, .drop);
    try expectDisp(.nav_key, idle, .leave, .pty);
}

test "#646 — 검색 중 paste 는 조합 확정 후 입력칸으로" {
    try expectDisp(.paste, searching, .commit, .search_field);
}

test "#646 — 검색 중 Ctrl+C 는 삼킨다 (셸로 SIGINT 가 가면 안 된다)" {
    try expectDisp(.interrupt, searching, .leave, .drop);
}

test "#646 — 검색 중에도 단축키는 그대로 실행된다 (pane 이동 포함)" {
    // 사용자 결정 (2026-09-11): 검색바에 포커스가 있어도 pane 을 옮길 수 있어야 한다.
    // 검색바는 단축키로 닫히지 않으므로 여기서 `commit` 은 *조합 자모를 입력칸에
    // 확정* 하라는 뜻이다 — 탭 이름을 확정시키던 rename 의 `commit` 과 다르다.
    for ([_]Shortcut{ .focus_pane, .split, .next_tab, .new_tab, .zoom_pane, .open_search }) |sc| {
        try expectDisp(.{ .shortcut = sc }, searching, .commit, .run_action);
    }
}

test "#646 — 검색 중 copy 는 입력칸을 건드리지 않는다" {
    try expectDisp(.{ .shortcut = .copy_selection }, searching, .leave, .run_action);
    try expectDisp(.{ .shortcut = .dump_perf }, searching, .leave, .run_action);
}
