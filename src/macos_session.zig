//! macOS host 의 멀티탭 자료구조. Windows `session_core.zig` 의 사용자
//! visible 모양 (ArrayList(*Tab) + active_tab) 만 차용한 mini 구현.
//!
//! Windows session_core 를 그대로 import 못 하는 이유는 거기 `TerminalBackend`
//! 가 ConPTY 의존이기 때문. macOS 는 `macos_pty.Pty` 직접 사용. 양쪽 host 모두
//! 안정되면 `TerminalBackend` 추상화로 통합 — 별도 후속 이슈.
//!
//! 이번 단계 (#111 M11.1) 는 *데이터 모델* 만 도입 — 실제 멀티탭 동작
//! (생성 / 닫기 / 전환) 은 후속 milestone 에서.

const std = @import("std");
const ghostty = @import("ghostty-vt");
const macos_pty = @import("macos_pty.zig");
const terminal_interaction = @import("terminal_interaction.zig");

/// 한 탭 = PTY 1 + ghostty Terminal 1 + stream + 마우스 selection 상태.
/// per-tab 자원만 들고 shared (Metal device, glyph atlas, font, NSWindow) 는
/// host 의 글로벌에 둠.
pub const Tab = struct {
    pty: macos_pty.Pty,
    terminal: ghostty.Terminal,
    stream: ghostty.TerminalStream,
    interaction: terminal_interaction.TerminalInteraction = .{},

    pub fn deinit(self: *Tab, allocator: std.mem.Allocator) void {
        self.pty.deinit();
        self.terminal.deinit(allocator);
        // stream 은 terminal 의 view (vtStream) 라 별도 deinit 없음.
    }
};

/// 탭 컬렉션 + 활성 탭 인덱스. Windows `SessionCore` 와 같은 모양.
pub const SessionCore = struct {
    allocator: std.mem.Allocator,
    tabs: std.ArrayList(*Tab) = .{},
    active_tab: usize = 0,

    pub fn deinit(self: *SessionCore) void {
        for (self.tabs.items) |tab| {
            tab.deinit(self.allocator);
            self.allocator.destroy(tab);
        }
        self.tabs.deinit(self.allocator);
    }

    /// 새 탭을 컬렉션 끝에 붙임. 활성 탭 변경은 호출처가 결정.
    pub fn appendTab(self: *SessionCore, tab: *Tab) !void {
        try self.tabs.append(self.allocator, tab);
    }

    pub fn activeTab(self: *SessionCore) ?*Tab {
        if (self.active_tab >= self.tabs.items.len) return null;
        return self.tabs.items[self.active_tab];
    }

    pub fn count(self: *const SessionCore) usize {
        return self.tabs.items.len;
    }
};
