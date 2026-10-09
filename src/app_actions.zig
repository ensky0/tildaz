//! 사용자 액션의 공통 처리부 (#692). 단축키 · 명령 메뉴 · 마우스 chrome 이 부르는 액션을
//! **세 host 가 이 한 곳에서** 실행한다.
//!
//! 예전에는 같은 액션이 host 마다 한 벌씩 있었다 — Windows `app_controller.zig` 의 `App`,
//! Linux `wayland_minimal.zig` 의 `Client`, macOS `host/macos.zig`. 본문이 조금씩 갈라져도
//! 컴파일러가 잡지 못했고, 액션을 하나 더하면 세 곳을 고쳐야 했다 (#679 · #693 에서 실제로
//! 그랬다).
//!
//! 나누는 기준은 ghostty 와 같다. 액션은 코어의 `Surface.performBindingAction` 한 곳이
//! 처리하고, OS 에 닿는 것만 platform (`rt_app.performAction`) 에 넘긴다. 여기서는 그 경계가
//! host 어댑터다.
//!
//! ## 진입점
//!
//!   - `run(host, action)` — 단축키. 액션은 `config.inputForAction` 이 만든 `ActionInput` 이다.
//!   - `runMenuCommand(host, command)` — `⋯` 명령 메뉴의 항목.
//!   - 마우스 chrome (`+` · `×` · 탭바) 은 아래 액션 함수를 직접 부른다.
//!
//! **조합 확정 정책 (`input_policy.resolve`) 은 여기서 하지 않는다.** IMM · `NSTextInputClient`
//! · text-input-v3 이 OS API 라서, host 가 dispatch 전에 적용한다.
//!
//! ## host 어댑터
//!
//! 함수는 `host: anytype` 을 받는다. 어댑터는 아래 메서드를 가진 struct (또는 그 포인터) 다.
//! 빠진 메서드는 그 host 를 컴파일할 때 걸린다 (`zig build check` 가 세 host 를 다 컴파일한다).
//! `tab_actions.Host` 처럼 함수 포인터 표를 두지 않은 이유는, 그러면 host 마다 `user_data` 를
//! 다시 cast 하는 콜백을 한 벌씩 써야 해서다.
//!
//! 데이터:
//!   - `session() *SessionCore`
//!   - `tabs() *tab_actions.Host` — 탭 이동 · 닫기 · 복사는 `tab_actions` 를 그대로 쓴다.
//!   - `rt() Runtime` · `allocator() std.mem.Allocator` · `shell() []const u8`
//!   - `paneArea() pane_layout.Rect` · `paneMetrics() pane_layout.Metrics`
//!   - `fixedGrid() bool` — `-size` 회차인가 (격자가 창을 정한다).
//!   - `fontSize() *terminal_size.TerminalFontSize` · `cellSize() CellSize`
//!
//! OS 에 닿는 동작:
//!   - `leaveShell()` — 활성 셸을 떠나기 전 입력 정리. 조합 중인 dead key 를 앱이 직접 드는
//!     Linux 만 할 일이 있다 (#536). macOS · Windows 는 조합 주체가 OS 라 빈 함수다.
//!   - `stopAutoScroll()` — 선택 드래그의 자동 스크롤을 멈춘다.
//!   - `syncGrids()` — 모든 탭의 pane 격자를 지금 배치에 맞춘다.
//!   - `syncAfterTabCountChange()` — 탭 수가 바뀐 뒤 (탭바가 생기거나 사라진다) 의 격자 · 창 맞춤.
//!   - `layoutChanged()` — 화면이 바뀌었다. 다시 그리고, macOS 는 커서 영역도 다시 잡는다.
//!   - `rebuildFonts(spec) !void` — 지금 배율 그대로 터미널 폰트를 다시 만든다. 실패하면 이전
//!     폰트가 그대로 남아 있어야 한다.
//!   - `yieldTopmost()` — 바깥 앱을 띄우기 전에 우리 창이 비켜 준다 (#655).
//!   - `fullscreenKind() ?FullscreenKind` · `toggleFullscreen(kind)`
//!   - `toggleVisibility()` · `showAbout()` · `paste()` · `quit()`

const std = @import("std");
const log = @import("log.zig");
const dialog = @import("dialog.zig");
const messages = @import("messages.zig");
const config = @import("config.zig");
const command_menu = @import("command_menu.zig");
const input_policy = @import("input_policy.zig");
const pane_layout = @import("pane_layout.zig");
const paths = @import("paths.zig");
const perf = @import("perf.zig");
const shell_validate = @import("shell_validate.zig");
const system_open = @import("system_open.zig");
const tab_actions = @import("tab_actions.zig");
const terminal_size = @import("font/terminal_size.zig");
const app_version = @import("version.zig");

/// 전체화면의 두 종류. host 마다 이름이 다르다 — Windows · macOS `monitor` / `workarea`,
/// Linux `cover` / `avoid`.
pub const FullscreenKind = enum {
    /// 화면 전체 (패널 · 메뉴 막대를 가린다).
    screen,
    /// 작업 영역 전체 (패널을 가리지 않는다).
    workarea,
};

/// `cellSize()` 의 결과 — 로그에만 쓴다.
pub const CellSize = struct { w: u32, h: u32 };

// === 진입점 ===

/// 단축키 액션을 실행한다. 조합 확정 정책은 host 가 이미 적용했다.
///
/// `false` = 소비하지 않았다. 호출자가 기존 경로로 흘린다 — 단축키가 아닌 입력과 `⋯` 버튼의
/// 입력 정책 자리 (`open_command_menu`) 가 그렇다. 방향 · 인덱스 같은 payload 가 빠진 입력도
/// `false` 다 (`config.inputForAction` 이 늘 채우므로 실제로는 오지 않는다).
pub fn run(host: anytype, action: config.ActionInput) bool {
    const shortcut = switch (action.input) {
        .paste => {
            host.paste();
            return true;
        },
        .shortcut => |sc| sc,
        // 단축키가 아닌 입력 — host 가 PTY 나 검색 입력칸으로 보낸다.
        .text, .edit_key, .nav_key, .interrupt => return false,
    };
    switch (shortcut) {
        .copy => copy(host),
        .new_tab => newTab(host),
        .close_tab => closeTab(host),
        .next_tab => nextTab(host),
        .prev_tab => prevTab(host),
        // 인덱스는 액션 이름에서 왔다 (`switch_tab3` → 2).
        .switch_tab => switchTab(host, action.tab_index orelse return false),
        .reset_terminal => tab_actions.resetActive(host.tabs()),
        .show_about => host.showAbout(),
        .open_config => openConfig(host),
        .open_log => openLog(host),
        .open_shortcuts => openShortcuts(host),
        .dump_perf => perf.dumpAndReset(host.rt(), "snapshot"),
        .quit => host.quit(),
        .toggle_visibility => host.toggleVisibility(),
        // #493 3-c — 두 fullscreen 은 별 액션이다. 예전엔 "Shift 가 눌렸으면 workarea" 라는 암묵
        // 규칙이 있었는데, 사용자가 `fullscreen_workarea` 에 Shift 없는 조합을 줄 수도 있다.
        .fullscreen => host.toggleFullscreen(.screen),
        .fullscreen_workarea => host.toggleFullscreen(.workarea),
        // 액션이 아니라 `⋯` 버튼을 누르는 순간의 입력 정책 자리다 (#329).
        .open_command_menu => return false,
        .split => split(host, action.direction orelse return false),
        .focus_pane => focusPane(host, action.direction orelse return false),
        .resize_pane => resizePane(host, action.direction orelse return false),
        .equalize_panes => equalizePanes(host),
        .zoom_pane => zoomPane(host),
        .close_pane => closePane(host),
        .find => find(host),
        .font_size => fontSize(host, action.font_size orelse return false),
    }
    return true;
}

/// `⋯` 명령 메뉴의 항목을 실행한다. 메뉴를 닫는 것과 조합 확정은 host 가 먼저 한다.
pub fn runMenuCommand(host: anytype, command: command_menu.Command) void {
    switch (command) {
        .toggle_visibility => host.toggleVisibility(),
        .new_tab => newTab(host),
        // #483 — 메뉴의 분할 항목 (마우스 경로).
        .split_right => split(host, .right),
        .split_down => split(host, .down),
        .close_active_tab => closeTab(host),
        .copy => copy(host),
        .paste => host.paste(),
        // #646 — 단축키를 모르는 사용자의 경로.
        .find => find(host),
        // #334 — 메뉴는 상태 기준 토글이다. 어떤 전체화면이든 켜져 있으면 그것을 풀고, 아니면
        // 화면 전체로 들어간다 (단축키는 들어간 키로만 나온다).
        .fullscreen => host.toggleFullscreen(host.fullscreenKind() orelse .screen),
        .open_config => openConfig(host),
        .open_log => openLog(host),
        .keyboard_shortcuts => openShortcuts(host),
        .about => host.showAbout(),
    }
}

/// 메뉴 항목이 거칠 입력 정책 — Windows 가 실행 전에 IMM 조합을 확정할 때 쓴다 (#329).
/// `paste` 는 `null` 이다. 붙여넣기는 commit 정책이 달라 (`Input.paste`) host 의 paste 경로가
/// 스스로 적용한다.
pub fn menuCommandShortcut(command: command_menu.Command) ?input_policy.Shortcut {
    return switch (command) {
        .toggle_visibility => .toggle_visibility,
        .new_tab => .new_tab,
        .split_right, .split_down => .split,
        .close_active_tab => .close_tab,
        .copy => .copy,
        .paste => null,
        .find => .find,
        .fullscreen => .fullscreen,
        .open_config => .open_config,
        .open_log => .open_log,
        .keyboard_shortcuts => .open_shortcuts,
        .about => .show_about,
    };
}

// === 탭 ===

/// 새 탭. 탭 한도 (#248 의 셸 확인 포함) 를 넘으면 알리고 그만둔다.
///
/// 새 탭은 다른 셸이라 `leaveShell` 을 먼저 부른다 (#536). 격자는 **pane 하나짜리 탭의 격자**로
/// 시작한다 — 활성 탭이 갈려 있어도 그 pane 의 크기가 아니다 (`pane_layout.leafRect` 는 단일
/// 창의 격자와 같다는 테스트가 `pane_layout.zig` 에 있다). 1 → 2 탭에서 탭바가 생기며 줄어드는
/// 것은 뒤의 `syncAfterTabCountChange` 가 맞춘다.
pub fn newTab(host: anytype) void {
    host.leaveShell();
    if (tab_actions.checkAtLimitAndDialog(host.rt(), host.tabs())) return;
    // #248 — 셸이 런타임에 사라졌으면 (패키지 업데이트 등) 조용히 죽는 대신 알린다.
    if (!shell_validate.checkForNewTab(host.rt(), host.allocator(), host.shell())) return;
    const grid = pane_layout.leafRect(0, host.paneArea(), host.paneMetrics());
    host.session().createTab(grid.cols, grid.rows) catch |err| {
        log.logNewTabFailed(err);
        return;
    };
    host.syncAfterTabCountChange();
    // #117 — 새 탭이 활성이 됐으니 탭바가 다시 활성 탭을 따라간다 (화살표로 넘겨 둔 상태를 푼다).
    host.tabs().override_ptr.* = false;
    host.layoutChanged();
}

/// 활성 탭을 통째로 닫는다 (그 안의 pane 전부). 마지막 탭이면 앱이 끝난다.
///
/// pane 이 여럿이거나 다른 탭이 있으면 활성 셸이 바뀐다 → `leaveShell`. 2 → 1 탭 전환에서
/// 탭바가 사라지므로 격자를 맞춘다 (#127).
pub fn closeTab(host: anytype) void {
    host.leaveShell();
    if (tab_actions.closeActive(host.tabs()) == .changed) {
        host.syncAfterTabCountChange();
        host.layoutChanged();
    }
}

/// `index` 번 탭으로 (0 부터). 없는 번호면 아무 일도 없다.
pub fn switchTab(host: anytype, index: usize) void {
    host.leaveShell();
    tab_actions.switchTab(host.tabs(), index);
}

pub fn nextTab(host: anytype) void {
    host.leaveShell();
    tab_actions.nextTab(host.tabs());
}

pub fn prevTab(host: anytype) void {
    host.leaveShell();
    tab_actions.prevTab(host.tabs());
}

// === 내용 ===

/// 활성 pane 의 선택을 클립보드로 (#120). 선택이 없으면 아무 일도 없다.
pub fn copy(host: anytype) void {
    tab_actions.copyActiveSelection(host.tabs(), host.allocator());
}

/// #646 — 활성 pane 의 검색바를 연다. 이미 열려 있으면 검색어를 지우지 않는다.
///
/// 바가 새로 뜨면 그 자리의 커서 모양이 바뀐다 (터미널 I-beam → 컨트롤 화살표) — 그래서
/// 다시 그리기만이 아니라 `layoutChanged` 다.
pub fn find(host: anytype) void {
    const tab = host.session().activeTab() orelse return;
    tab.search.open();
    host.layoutChanged();
}

/// #693 — 터미널 글자 크기를 창 전체 (모든 탭 · pane) 에서 바꾼다.
///
/// 사본에 먼저 적용해 폰트를 만든 뒤에 반영한다 — 실패하면 크기도 폰트도 그대로다. 창 크기는
/// 그대로라 격자는 여기서 맞춘다.
///
/// `-size` 회차는 무시한다 — 그 회차는 창을 요청 격자에 맞추므로 글자 크기가 바뀌면 격자를
/// 지킬 수 없다.
pub fn fontSize(host: anytype, change: terminal_size.Change) void {
    if (host.fixedGrid()) {
        log.logFontSizeIgnoredForFixedGrid(@tagName(change));
        return;
    }
    const current = host.fontSize();
    var next = current.*;
    if (!next.apply(change)) return;
    host.rebuildFonts(next.spec()) catch |err| {
        log.logFontSizeRebuildFailed(err, current.size_logical);
        return;
    };
    current.* = next;
    host.syncGrids();
    const cell = host.cellSize();
    log.logFontSize(@tagName(change), current.size_logical, cell.w, cell.h);
    host.layoutChanged();
}

// === 바깥 앱 열기 ===
//
// 셋 다 **바깥 앱을 띄운다** — 먼저 비켜 주지 않으면 우리 창 뒤에 열린다 (#655).

pub fn openConfig(host: anytype) void {
    const path = paths.configPath(host.rt(), host.allocator()) catch return;
    defer host.allocator().free(path);
    host.yieldTopmost();
    system_open.openInDefaultApp(host.rt(), host.allocator(), path);
}

pub fn openLog(host: anytype) void {
    const path = log.filePath() orelse return;
    host.yieldTopmost();
    system_open.openInDefaultApp(host.rt(), host.allocator(), path);
}

/// #682 — 단축키 문서 (`KEYBINDINGS.md`) 를 기본 브라우저로.
pub fn openShortcuts(host: anytype) void {
    host.yieldTopmost();
    system_open.openInDefaultApp(host.rt(), host.allocator(), app_version.keyboard_shortcuts_url);
}

// === pane ===

/// #483 — 활성 pane 을 `dir` 쪽으로 반씩 가른다. 포커스는 새 pane 으로 간다.
///
/// 새 pane 은 다른 셸이라 `leaveShell` 을 먼저 부른다. 셸 경로가 사라졌으면 (#248) 알리고
/// 그만둔다.
pub fn split(host: anytype, dir: pane_layout.Direction) void {
    host.leaveShell();
    if (!shell_validate.checkForNewTab(host.rt(), host.allocator(), host.shell())) return;
    const session = host.session();
    session.splitActive(dir, host.paneArea(), host.paneMetrics()) catch |err| switch (err) {
        error.TooSmall => {
            // #483 — 거부도 로그를 남긴다. 다이얼로그는 사용자에게만 보이므로, 로그로 판정하는
            // 검증 회차에서는 *거부* 와 *액션 미발동* 이 구분되지 않았다 (2026-08-29 macOS 회차).
            log.logPaneSplitTooSmall(@tagName(dir), pane_layout.MIN_PANE_COLS, pane_layout.MIN_PANE_ROWS);
            var buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, messages.pane_too_small_format, .{ pane_layout.MIN_PANE_COLS, pane_layout.MIN_PANE_ROWS }) catch
                messages.pane_too_small_format;
            dialog.showInfo(host.rt(), messages.pane_too_small_title, msg);
            return;
        },
        error.TooManyPanes => {
            log.logPaneSplitTooMany(@tagName(dir), pane_layout.MAX_PANES_PER_TAB);
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, messages.pane_limit_format, .{pane_layout.MAX_PANES_PER_TAB}) catch
                messages.pane_limit_format;
            dialog.showInfo(host.rt(), messages.pane_limit_title, msg);
            return;
        },
        error.NoActiveTab => return,
        else => {
            log.logPaneSplitFailed(err);
            return;
        },
    };
    const group = session.activeGroup().?;
    log.logPaneSplit(@tagName(dir), session.active_tab, group.paneCount(), group.active_pane);
    host.layoutChanged();
}

/// #483 — `dir` 쪽 이웃 pane 으로 포커스를 옮긴다.
///
/// 떠나는 pane 의 입력을 먼저 정리하고 (`leaveShell`), 진행 중인 pointer mode 를 끝낸다.
/// 순서가 바뀌면 조합 중이던 글자가 새 pane 의 셸로 간다 (#536).
pub fn focusPane(host: anytype, dir: pane_layout.Direction) void {
    const session = host.session();
    const leaving = session.activeTab() orelse return;
    host.leaveShell();
    if (!session.focusPane(dir, host.paneArea(), host.paneMetrics())) return;
    leaving.interaction.cancelPointerModes();
    host.stopAutoScroll();
    // 최대화가 풀렸을 수 있다 → 펼친 격자로 (같으면 건너뛴다).
    host.syncGrids();
    log.logPaneFocus(@tagName(dir), session.activeGroup().?.active_pane);
    host.layoutChanged();
}

/// #483 — 활성 pane 의 `dir` 쪽 분할선을 한 칸 옮긴다.
pub fn resizePane(host: anytype, dir: pane_layout.Direction) void {
    if (!host.session().resizeActivePane(dir, 1, host.paneArea(), host.paneMetrics())) return;
    host.layoutChanged();
}

/// #483 — 활성 탭의 pane 을 모두 같은 크기로.
pub fn equalizePanes(host: anytype) void {
    const session = host.session();
    const group = session.activeGroup() orelse return;
    session.equalizeActive(host.paneArea(), host.paneMetrics());
    log.logPaneEqualize(group.tree.count());
    host.layoutChanged();
}

/// #483 — 활성 pane 최대화 토글. 켜면 그 pane 이 탭 영역 전체를 쓰고 다른 pane 은 그리지 않는다
/// (셸은 계속 돈다). 격자는 켤 때 그 pane 만, 풀 때 모두 맞춘다.
///
/// 활성 셸이 바뀌지 않으므로 `leaveShell` 은 부르지 않는다.
pub fn zoomPane(host: anytype) void {
    const session = host.session();
    if (!session.toggleZoomActive()) return;
    host.syncGrids();
    log.logPaneZoom(session.activeGroup().?.zoomed != null, session.activeGroup().?.active_pane);
    host.layoutChanged();
}

/// #544 — 활성 pane 하나만 닫는다. 마지막 pane 이면 탭이 닫히고, 마지막 탭이면 앱이 끝난다
/// (`tab_actions.closeActivePane`).
///
/// pane 이 여럿이면 닫은 뒤 형제 pane 이 활성이 되어 셸이 바뀐다 → `leaveShell`. 남은 pane 이
/// 자리를 이어받으므로 격자를 맞춘다 (2 → 1 탭 전환도 같은 경로다).
pub fn closePane(host: anytype) void {
    host.leaveShell();
    if (tab_actions.closeActivePane(host.tabs()) == .changed) {
        host.syncAfterTabCountChange();
        host.layoutChanged();
    }
}
