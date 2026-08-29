//! 탭 단위 사용자 action — cross-platform helper 모듈 (#159 Phase 2). 양쪽
//! host (host/macos.zig, app_controller.zig) 가 자기 `Host` 인스턴스 + 콜백
//! 채워서 호출. helper 안에서 platform-specific 동작 (invalidate / clipboard)
//! 은 콜백 통해 위임.
//!
//! 추상화 경계:
//!   - SessionCore 호출 (mutating / query) — helper 가 직접
//!   - override flag (tab_scroll_user_override) — Host 의 *bool 통해
//!   - cross-platform 자체 모듈 (`messages.zig` / `dialog.zig` / `ghostty`)
//!     — helper 가 직접 import
//!   - platform-specific (NSPasteboard / D3D invalidate / NSApp terminate) —
//!     콜백
//!
//! 호출처는 Host setup 한 번만 — 핸들러 구현은 한 줄.

const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const session_core = @import("session_core.zig");
const SessionCore = session_core.SessionCore;
const messages = @import("messages.zig");
const dialog = @import("dialog.zig");
const ghostty = @import("ghostty-vt");

/// host 가 자기 state + platform 콜백을 묶어 helper 에 넘기는 interface.
/// mac 은 module-level (g_session 등) 을 wrap 한 const, win 은 App instance 를
/// wrap 한 member.
pub const Host = struct {
    session: *SessionCore,
    /// `#117 — 사용자가 화살표 < / > 누르면 true (활성 탭 추적 일시 정지),
    /// 탭 변경 / 새 탭 / 닫기 등 활성 탭 이동이면 false (다시 추적 재가동).
    override_ptr: *bool,

    /// 즉시 redraw. mac 은 60fps timer 가 자동 그리니 보통 noop, win 은
    /// `self.renderer.invalidate()`. helper 가 mutating 후 한 번만 호출.
    invalidate: *const fn (*Host) void,

    /// 텍스트를 platform clipboard 로 복사. mac NSPasteboard / win
    /// `self.window.copyToClipboard(text)`. ghostty 의 `selectionString` 이
    /// sentinel slice 반환 → Windows clipboard API (null-terminated 요구) 와
    /// 자연스럽게 호환. caller 가 이미 비어있지 않음 보장.
    clipboard_copy: *const fn (*Host, [:0]const u8) void,

    /// 마지막 탭 닫혔을 때 — mac NSApp.terminate / win
    /// `self.window.closeAfterShellExit()`. 양쪽 다 "탭 0 = 앱 종료" 동일 정책,
    /// API 만 차이.
    terminate: *const fn (*Host) void,

    /// platform host instance 포인터 — 콜백이 cast 해서 자기 state 접근. mac
    /// 은 module-level 이라 null OK, win 은 *App. 콜백 시그니처에서 첫 인자
    /// `*Host` 만 받기 때문에 callback 안에서 `host.user_data` 로 dereference.
    user_data: ?*anyopaque = null,
};

// === query ===

/// MAX_TABS 도달 검사 + dialog 표시 (도달 시). true 면 호출처가 새 탭 생성
/// 진행 안 함. cross-platform dialog.zig 가 platform 별 dispatch — helper 가
/// 직접 호출 (콜백 불필요).
pub fn checkAtLimitAndDialog(rt: Runtime, host: *const Host) bool {
    if (host.session.count() < session_core.MAX_TABS) return false;
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, messages.tab_limit_format, .{session_core.MAX_TABS}) catch
        messages.tab_limit_format;
    dialog.showInfo(rt, messages.tab_limit_title, msg);
    return true;
}

// === 활성 탭 이동 (override clear + invalidate 패턴 통일) ===

/// 탭 전환 직전에 *기존 활성 탭* 의 진행 중 pointer mode (selection drag /
/// scrollbar drag) 만 cleanup. 정책 β — drag 는 multi-tab span 의미 없음 (애초에
/// 비정상 워크플로우 + #172 stuck path 와 같은 영역). cancelPointerModes 는
/// active flag + start_pin 만 리셋, ghostty screen 의 highlight 는 그대로 보존
/// 하므로 *완료된 selection* 은 탭별로 자연 보존.
fn cancelDragOnActiveTab(host: *Host) void {
    if (host.session.activeTab()) |tab| tab.interaction.cancelPointerModes();
}

/// idx 번 탭으로 활성. setActiveTab 의 변경 여부에 따라 override clear +
/// invalidate. 호출처는 한 줄.
pub fn switchTab(host: *Host, idx: usize) void {
    cancelDragOnActiveTab(host);
    if (host.session.setActiveTab(idx)) {
        host.override_ptr.* = false;
        host.invalidate(host);
    }
}

/// 다음 탭 활성 (wrap-around). activateNext 의 변경 여부에 따라 사후 처리.
pub fn nextTab(host: *Host) void {
    cancelDragOnActiveTab(host);
    if (host.session.activateNext()) {
        host.override_ptr.* = false;
        host.invalidate(host);
    }
}

/// 이전 탭 활성 (wrap-around).
pub fn prevTab(host: *Host) void {
    cancelDragOnActiveTab(host);
    if (host.session.activatePrev()) {
        host.override_ptr.* = false;
        host.invalidate(host);
    }
}

/// 활성 탭 reset (fullReset + Ctrl+L). #162 Shift+Cmd+R / Ctrl+Shift+R.
pub fn resetActive(host: *Host) void {
    if (host.session.resetActive()) host.invalidate(host);
}

/// closeActive 결과 — 호출처가 platform-specific 사후 (sync geometry / resize)
/// 처리. helper 가 ended 일 때 host.terminate, changed 일 때 override clear +
/// invalidate. 활성 탭 없으면 null.
pub const CloseOutcome = enum { changed, ended };

/// 활성 **탭** 닫기 — 그 탭의 pane 을 전부 닫는다. 마지막 탭이면 host.terminate 호출
/// (앱 종료). 아니면 override clear + invalidate. 호출처는 .changed 분기에서 grid
/// resize 등 platform 동작.
///
/// #544 — #483 이 이것을 `closeActivePane` 으로 바꿨다가 되돌렸다. 액션 이름 (`close_tab`) ·
/// 메뉴 라벨 (`"Close Active Tab"`) · SPEC 두 줄이 모두 "탭" 인데 동작만 pane 이어서, 같은
/// helper 를 쓰던 마우스 `×` 까지 함께 pane 을 닫고 있었다. pane 하나를 닫는 것은 아래
/// `closeActivePane` (액션 `close_pane`) 이 맡는다.
pub fn closeActive(host: *Host) ?CloseOutcome {
    if (host.session.activeTab() == null) return null;
    return outcome(host, host.session.closeTab(host.session.active_tab));
}

/// 활성 **pane** 닫기 (#544 의 새 액션 `close_pane`) — 그룹에 pane 이 둘 이상이면 그 pane 만
/// (형제가 자리를 이어받는다), 마지막 하나면 탭, 마지막 탭이면 앱 종료. PTY 종료 경로
/// (`closeByPtr`) 와 같은 규칙이라, 셸에 `exit` 를 치는 것과 결과가 같다.
pub fn closeActivePane(host: *Host) ?CloseOutcome {
    if (host.session.activeTab() == null) return null;
    return outcome(host, host.session.closeActivePane());
}

/// PTY exit (자식 shell 종료) → host 의 deferred drain 이 호출. 정책 동일 —
/// 마지막 탭이면 terminate, 아니면 override clear + invalidate. mac 의
/// drainExitedTabs (mutex queue) / win 의 WM_TAB_CLOSED 모두 같은 helper.
pub fn closeByPtr(host: *Host, tab_ptr: usize) ?CloseOutcome {
    return outcome(host, host.session.closeTabByPtr(tab_ptr));
}

/// 인덱스 기반 close — 탭바 close 버튼 마우스 클릭 path. closeActive 와의 차이:
/// 어떤 탭이든 닫을 수 있음 (활성 탭 X). 정책은 동일 — 마지막 탭 → terminate
/// 등.
pub fn closeIndex(host: *Host, idx: usize) ?CloseOutcome {
    return outcome(host, host.session.closeTab(idx));
}

/// closeActive / closeActivePane / closeByPtr / closeIndex 공통 사후 처리 — close 의
/// source 만 다르고 마지막 탭 정책 / override clear / invalidate 동일.
fn outcome(host: *Host, result: session_core.SessionCore.CloseResult) ?CloseOutcome {
    return switch (result) {
        .none => null,
        .closed_last => blk: {
            host.terminate(host);
            break :blk .ended;
        },
        .changed => blk: {
            host.override_ptr.* = false;
            host.invalidate(host);
            break :blk .changed;
        },
    };
}

// === clipboard ===

/// 활성 탭의 selection → text → clipboard. selection 없거나 빈 문자면 noop.
/// allocator 는 selection string 추출 / free 에만 — clipboard 콜백은 동기 복사
/// 후 끝.
pub fn copyActiveSelection(host: *Host, alloc: std.mem.Allocator) void {
    const tab = host.session.activeTab() orelse return;
    const screen: *ghostty.Screen = tab.terminal.screens.active;
    const sel = screen.selection orelse return;
    const text = screen.selectionString(alloc, .{ .sel = sel }) catch return;
    defer alloc.free(text);
    if (text.len == 0) return;
    host.clipboard_copy(host, text);
}

/// paste 텍스트 라우팅 — session.pasteToActive. bracketed paste mode 검사 +
/// wrap 은 거기서 처리.
pub fn routePaste(host: *Host, bytes: []const u8) void {
    host.session.pasteToActive(bytes);
}

// ── 테스트 ──────────────────────────────────────────────────────────────────
//
// #544 — 닫기 정책을 여기서 고정한다. `closeActive` (탭 통째로) 와 `closeActivePane`
// (pane 하나) 은 **세 host 가 공유**하므로, 이 테스트가 macOS · Windows 의 동작까지
// 함께 지킨다 — 그 두 platform 은 실기 검증을 Linux 기기에서 할 수 없고, 이 helper 의
// 의미가 뒤바뀐 것이 #544 의 원인이었다 (#483 이 `closeActive` 를 pane 닫기로 바꾸면서
// 액션 이름 · 메뉴 라벨 · SPEC 과 어긋났고, 같은 helper 를 쓰던 마우스 `×` 까지 딸려갔다).

fn testCloseHost(session: *SessionCore, override: *bool) Host {
    const Cb = struct {
        fn invalidate(_: *Host) void {}
        fn clip(_: *Host, _: [:0]const u8) void {}
        fn term(h: *Host) void {
            const n: *usize = @ptrCast(@alignCast(h.user_data.?));
            n.* += 1;
        }
    };
    return .{
        .session = session,
        .override_ptr = override,
        .invalidate = Cb.invalidate,
        .clipboard_copy = Cb.clip,
        .terminate = Cb.term,
        .user_data = null,
    };
}

test "POSIX: #544 — closeActive 는 탭 통째로, closeActivePane 은 pane 하나" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    const pane_layout = @import("pane_layout.zig");
    const Exit = struct {
        fn notify(_: usize, _: ?*anyopaque) void {}
    };

    var session = SessionCore.init(
        .{ .io = std.testing.io, .environ = .empty },
        std.testing.allocator,
        "/bin/sh",
        100,
        null,
        null,
        &Exit.notify,
        null,
    );
    defer session.deinit();

    var override = true;
    var terminated: usize = 0;
    var host = testCloseHost(&session, &override);
    host.user_data = &terminated;

    // `pane_layout` 테스트와 같은 metrics — 탭바를 뺀 3052×1000 px 영역.
    const m: pane_layout.Metrics = .{ .cell_w = 19, .cell_h = 39, .pad = 12, .scrollbar_w = 20, .separator_w = 2 };
    const rect: pane_layout.Rect = .{ .x = 0, .y = 0, .w = 3052, .h = 1000 };

    // 탭 둘 · 활성 탭 (index 1) 을 2 pane 으로 가른다.
    try session.createTab(80, 24);
    try session.createTab(80, 24);
    try session.splitActive(.right, rect, m);
    try std.testing.expectEqual(@as(usize, 2), session.count());
    try std.testing.expectEqual(@as(usize, 2), session.activeGroup().?.paneCount());

    // `closeActive` = 활성 탭 통째로. pane 둘이 함께 사라지고 탭 수가 줄며, 남은 탭은
    // 손대지 않는다 (`Ctrl+Shift+W` · `Cmd+W` · `×` · `⋯` 메뉴가 모두 이 경로다).
    try std.testing.expectEqual(@as(?CloseOutcome, .changed), closeActive(&host));
    try std.testing.expectEqual(@as(usize, 1), session.count());
    try std.testing.expectEqual(@as(usize, 1), session.activeGroup().?.paneCount());
    try std.testing.expectEqual(@as(usize, 0), terminated);

    // 남은 탭을 다시 2 pane 으로 → `closeActivePane` 은 **그 pane 만** 닫는다 (`close_pane`).
    try session.splitActive(.right, rect, m);
    try std.testing.expectEqual(@as(usize, 2), session.activeGroup().?.paneCount());
    try std.testing.expectEqual(@as(?CloseOutcome, .changed), closeActivePane(&host));
    try std.testing.expectEqual(@as(usize, 1), session.count());
    try std.testing.expectEqual(@as(usize, 1), session.activeGroup().?.paneCount());
    try std.testing.expectEqual(@as(usize, 0), terminated);

    // 마지막 pane 이면 탭, 마지막 탭이면 앱 종료 — `terminate` 콜백이 정확히 한 번.
    try std.testing.expectEqual(@as(?CloseOutcome, .ended), closeActivePane(&host));
    try std.testing.expectEqual(@as(usize, 0), session.count());
    try std.testing.expectEqual(@as(usize, 1), terminated);

    // 탭이 없으면 둘 다 null (호출처가 사후 처리를 건너뛴다).
    try std.testing.expectEqual(@as(?CloseOutcome, null), closeActive(&host));
    try std.testing.expectEqual(@as(?CloseOutcome, null), closeActivePane(&host));
}

test "POSIX: #544 — 마지막 탭의 closeActive 는 pane 이 여럿이어도 앱을 종료한다" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    const pane_layout = @import("pane_layout.zig");
    const Exit = struct {
        fn notify(_: usize, _: ?*anyopaque) void {}
    };

    var session = SessionCore.init(
        .{ .io = std.testing.io, .environ = .empty },
        std.testing.allocator,
        "/bin/sh",
        100,
        null,
        null,
        &Exit.notify,
        null,
    );
    defer session.deinit();

    var override = true;
    var terminated: usize = 0;
    var host = testCloseHost(&session, &override);
    host.user_data = &terminated;

    const m: pane_layout.Metrics = .{ .cell_w = 19, .cell_h = 39, .pad = 12, .scrollbar_w = 20, .separator_w = 2 };
    const rect: pane_layout.Rect = .{ .x = 0, .y = 0, .w = 3052, .h = 1000 };

    try session.createTab(80, 24);
    try session.splitActive(.right, rect, m);
    try session.splitActive(.down, rect, m);
    try std.testing.expectEqual(@as(usize, 1), session.count());
    try std.testing.expectEqual(@as(usize, 3), session.activeGroup().?.paneCount());

    // 실기에서 본 것과 같다 — 1 탭 · 다중 pane 에서 `Ctrl+Shift+W` 는 앱을 끝낸다.
    // (#544 전에는 pane 하나만 닫히고 앱이 살아 있었다.)
    try std.testing.expectEqual(@as(?CloseOutcome, .ended), closeActive(&host));
    try std.testing.expectEqual(@as(usize, 0), session.count());
    try std.testing.expectEqual(@as(usize, 1), terminated);
}
