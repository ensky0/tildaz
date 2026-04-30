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
    /// 탭바에 표시할 제목. 현재는 default "Tab N" — rename 은 후속 milestone.
    title_buf: [64]u8 = [_]u8{0} ** 64,
    title_len: usize = 0,

    pub fn deinit(self: *Tab, allocator: std.mem.Allocator) void {
        self.pty.deinit();
        self.terminal.deinit(allocator);
        // stream 은 terminal 의 view (vtStream) 라 별도 deinit 없음.
    }

    pub fn title(self: *const Tab) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn setTitle(self: *Tab, s: []const u8) void {
        const n = @min(s.len, self.title_buf.len);
        @memcpy(self.title_buf[0..n], s[0..n]);
        self.title_len = n;
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

    pub fn activeTab(self: *SessionCore) ?*Tab {
        if (self.active_tab >= self.tabs.items.len) return null;
        return self.tabs.items[self.active_tab];
    }

    pub fn count(self: *const SessionCore) usize {
        return self.tabs.items.len;
    }

    /// 새 Tab 한 개를 만들고 (PTY + Terminal + read thread 시작) 컬렉션에
    /// append, 활성 탭으로 전환. 실패 시 부분 init 한 자원 모두 정리.
    pub fn createTab(
        self: *SessionCore,
        cols: u16,
        rows: u16,
        max_scrollback: usize,
        shell_path: []const u8,
        extra_env: ?[]const macos_pty.Pty.EnvVar,
        pty_output_cb: macos_pty.Pty.ReadCallback,
        pty_exit_cb: macos_pty.Pty.ExitCallback,
    ) !*Tab {
        const tab = try self.allocator.create(Tab);
        errdefer self.allocator.destroy(tab);

        tab.* = .{
            .pty = undefined,
            .terminal = try ghostty.Terminal.init(self.allocator, .{
                .cols = cols,
                .rows = rows,
                .max_scrollback = max_scrollback,
                .colors = ghostty.Terminal.Colors.default,
            }),
            .stream = undefined,
            .interaction = .{},
        };
        // default 제목: "Tab N" — N 은 1-base 인덱스 (현재 컬렉션 길이 + 1).
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "Tab {d}", .{self.tabs.items.len + 1}) catch "Tab";
        tab.setTitle(name);
        errdefer tab.terminal.deinit(self.allocator);
        tab.stream = tab.terminal.vtStream();

        tab.pty = try macos_pty.Pty.init(self.allocator, cols, rows, shell_path, extra_env);
        errdefer tab.pty.deinit();

        // userdata = *Tab — 콜백이 어느 탭 출력 / 종료인지 식별.
        try tab.pty.startReadThread(pty_output_cb, pty_exit_cb, tab);

        try self.tabs.append(self.allocator, tab);
        self.active_tab = self.tabs.items.len - 1;

        return tab;
    }

    /// 활성 탭을 인덱스로 직접 변경. 변경됐으면 true.
    pub fn setActiveTab(self: *SessionCore, index: usize) bool {
        if (index >= self.tabs.items.len) return false;
        if (self.active_tab == index) return false;
        self.active_tab = index;
        return true;
    }

    /// 다음 탭으로 (마지막이면 첫 탭으로 wrap). 탭이 1 개 이하면 false.
    pub fn activateNext(self: *SessionCore) bool {
        if (self.tabs.items.len <= 1) return false;
        self.active_tab = (self.active_tab + 1) % self.tabs.items.len;
        return true;
    }

    /// 이전 탭으로 (첫 탭이면 마지막 탭으로 wrap). 탭이 1 개 이하면 false.
    pub fn activatePrev(self: *SessionCore) bool {
        if (self.tabs.items.len <= 1) return false;
        self.active_tab = if (self.active_tab == 0) self.tabs.items.len - 1 else self.active_tab - 1;
        return true;
    }
};
