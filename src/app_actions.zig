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
//! ## host 어댑터
//!
//! 함수는 `host: anytype` 을 받는다. 어댑터는 아래 메서드를 가진 struct 의 포인터다. 빠진
//! 메서드는 그 host 를 컴파일할 때 걸린다 (`zig build check` 가 세 host 를 다 컴파일한다).
//! `tab_actions.Host` 처럼 함수 포인터 표를 두지 않은 이유는, 그러면 host 마다 `user_data` 를
//! 다시 cast 하는 콜백을 한 벌씩 써야 해서다.
//!
//! 데이터:
//!   - `session() *SessionCore`
//!   - `tabs() *tab_actions.Host` — 탭 · pane 닫기는 `tab_actions` 를 그대로 쓴다.
//!   - `rt() Runtime` · `allocator() std.mem.Allocator` · `shell() []const u8`
//!   - `paneArea() pane_layout.Rect` · `paneMetrics() pane_layout.Metrics`
//!
//! OS 에 닿는 동작:
//!   - `leaveShell()` — 활성 셸을 떠나기 전 입력 정리. 조합 중인 dead key 를 앱이 직접 드는
//!     Linux 만 할 일이 있다 (#536). macOS · Windows 는 조합 주체가 OS 라 빈 함수다.
//!   - `stopAutoScroll()` — 선택 드래그의 자동 스크롤을 멈춘다.
//!   - `syncGrids()` — 모든 탭의 pane 격자를 지금 배치에 맞춘다.
//!   - `syncAfterTabCountChange()` — 탭 수가 바뀐 뒤 (탭바가 생기거나 사라진다) 의 격자 · 창 맞춤.
//!   - `layoutChanged()` — 배치가 바뀌었다. 다시 그리고, macOS 는 커서 영역도 다시 잡는다.
//!
//! **조합 확정 정책 (`input_policy.resolve`) 은 여기서 하지 않는다.** IMM · `NSTextInputClient`
//! · text-input-v3 이 OS API 라서, host 가 dispatch 전에 적용한다.

const std = @import("std");
const log = @import("log.zig");
const dialog = @import("dialog.zig");
const messages = @import("messages.zig");
const pane_layout = @import("pane_layout.zig");
const shell_validate = @import("shell_validate.zig");
const tab_actions = @import("tab_actions.zig");

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
