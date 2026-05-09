//! 탭 단위 사용자 action — cross-platform helper 모듈 (#159 Phase 2). 양쪽
//! host (host/macos.zig, app_controller.zig) 가 자기 `Host` 인스턴스 + 콜백
//! 채워서 호출. helper 안에서 platform-specific 동작 (invalidate / clipboard
//! / rename routing) 은 콜백 통해 위임.
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

    /// 활성 rename 모드 검사. mac `g_rename.isActive()` / win `self.isRenaming()`.
    rename_active: *const fn (*const Host) bool,

    /// rename 모드 codepoint 추가. paste routing 에서 printable cp 만 forward.
    /// mac `g_rename.insertCodepoint(cp)` / win `self.handleRenameChar(cp)`.
    insert_rename_cp: *const fn (*Host, u21) void,

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
pub fn checkAtLimitAndDialog(host: *const Host) bool {
    if (host.session.count() < session_core.MAX_TABS) return false;
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, messages.tab_limit_format, .{session_core.MAX_TABS}) catch
        messages.tab_limit_format;
    dialog.showInfo(messages.tab_limit_title, msg);
    return true;
}

// === 활성 탭 이동 (override clear + invalidate 패턴 통일) ===

/// idx 번 탭으로 활성. setActiveTab 의 변경 여부에 따라 override clear +
/// invalidate. 호출처는 한 줄.
pub fn switchTab(host: *Host, idx: usize) void {
    if (host.session.setActiveTab(idx)) {
        host.override_ptr.* = false;
        host.invalidate(host);
    }
}

/// 다음 탭 활성 (wrap-around). activateNext 의 변경 여부에 따라 사후 처리.
pub fn nextTab(host: *Host) void {
    if (host.session.activateNext()) {
        host.override_ptr.* = false;
        host.invalidate(host);
    }
}

/// 이전 탭 활성 (wrap-around).
pub fn prevTab(host: *Host) void {
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

/// 활성 탭 닫기. 마지막 탭이면 host.terminate 호출 (앱 종료). 아니면 override
/// clear + invalidate. 호출처는 .changed 분기에서 grid resize 등 platform 동작.
pub fn closeActive(host: *Host) ?CloseOutcome {
    if (host.session.activeTab() == null) return null;
    return outcome(host, host.session.closeTab(host.session.active_tab));
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

/// closeActive / closeByPtr 공통 사후 처리 — close 의 source 만 다르고 마지막
/// 탭 정책 / override clear / invalidate 동일.
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

/// paste 텍스트 라우팅. rename 활성 시 codepoint 단위 (printable cp >= 0x20 만)
/// 로 host.insert_rename_cp. 아니면 session.pasteToActive — bracketed paste mode
/// 검사 + wrap 은 거기서 처리.
pub fn routePaste(host: *Host, bytes: []const u8) void {
    if (host.rename_active(host)) {
        var iter = std.unicode.Utf8Iterator{ .bytes = bytes, .i = 0 };
        while (iter.nextCodepoint()) |cp| {
            if (cp >= 0x20) host.insert_rename_cp(host, cp);
        }
        return;
    }
    host.session.pasteToActive(bytes);
}
