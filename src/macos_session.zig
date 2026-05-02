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
const themes = @import("themes.zig");

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
    /// PTY 자식이 종료됐을 때 read thread 가 set, main thread 의 render timer
    /// 가 검사 후 안전하게 closeTab 호출. main thread 외에서 closeTab / deinit
    /// 부르면 read thread 자기 자신을 join 하려는 deadlock 위험.
    exit_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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
        theme: ?*const themes.Theme,
    ) !*Tab {
        const tab = try self.allocator.create(Tab);
        errdefer self.allocator.destroy(tab);

        // theme 의 fg / bg / 16-color palette 적용. null 이면 ghostty default.
        // Windows session_core 의 createTab 과 동일 패턴.
        const term_colors = if (theme) |t| ghostty.Terminal.Colors{
            .foreground = ghostty.color.DynamicRGB.init(t.foreground),
            .background = ghostty.color.DynamicRGB.init(t.background),
            .cursor = .unset,
            .palette = ghostty.color.DynamicPalette.init(themes.buildPalette(t.palette)),
        } else ghostty.Terminal.Colors.default;

        tab.* = .{
            .pty = undefined,
            .terminal = try ghostty.Terminal.init(self.allocator, .{
                .cols = cols,
                .rows = rows,
                .max_scrollback = max_scrollback,
                .colors = term_colors,
            }),
            .stream = undefined,
            .interaction = .{},
        };
        // Mode 2027 (grapheme cluster) — VS-16 / skin tone modifier (U+1F3FB-FF)
        // / ZWJ 시퀀스 (U+200D) 가 같은 cell 의 grapheme 으로 묶이게. 기본 OFF
        // 라 ❤️ 가 [U+2764, U+FE0F] 두 cell 에 분리되고 cell 폭도 narrow 로
        // 남음. ON 시 base cell 의 `cell.grapheme` 에 extras 가 저장 + VS-16
        // 일 때 cell 자동으로 wide. renderer 가 이 grapheme 을 CTLine 으로 shape.
        tab.terminal.modes.set(.grapheme_cluster, true);
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

    /// 인덱스의 탭을 닫음. Tab 의 PTY / Terminal 정리 후 컬렉션에서 제거. 활성
    /// 탭 인덱스를 자동 조정 (Windows `SessionCore.nextActiveIndexAfterClose`
    /// 와 동일 정책).
    /// **반드시 main thread 에서만 호출** — Tab.deinit 이 read thread join 을
    /// 부르므로 read thread 자체에서 부르면 deadlock.
    pub fn closeTab(self: *SessionCore, index: usize) void {
        if (index >= self.tabs.items.len) return;
        const tab = self.tabs.items[index];
        _ = self.tabs.orderedRemove(index);

        // 활성 인덱스 조정.
        if (self.tabs.items.len == 0) {
            self.active_tab = 0;
        } else if (self.active_tab > index) {
            // 닫힌 탭이 활성보다 앞 → 인덱스 한 칸 당김 (활성 탭 자체는 그대로).
            self.active_tab -= 1;
        } else if (self.active_tab >= self.tabs.items.len) {
            // 활성이 마지막 탭이었고 그게 닫힌 경우 → 한 칸 앞 (= 새 마지막).
            self.active_tab = self.tabs.items.len - 1;
        }
        // else: 닫힌 탭이 활성보다 뒤거나 같음 (같은 경우는 위 first branch
        // 에서 길이로 이미 처리). active_tab 인덱스 유효.

        tab.deinit(self.allocator);
        self.allocator.destroy(tab);
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

    /// `from` 인덱스의 탭을 `to` 위치로 옮김 (drag-and-drop reorder).
    /// 활성 탭은 같은 *Tab 을 따라가도록 인덱스만 갱신.
    pub fn reorderTabs(self: *SessionCore, from: usize, to: usize) !bool {
        if (from >= self.tabs.items.len or to >= self.tabs.items.len or from == to) return false;

        const active_ptr = self.activeTab();
        const moved = self.tabs.orderedRemove(from);
        try self.tabs.insert(self.allocator, to, moved);

        if (active_ptr) |active| {
            for (self.tabs.items, 0..) |t, i| {
                if (t == active) {
                    self.active_tab = i;
                    break;
                }
            }
        }
        return true;
    }

    /// 이전 탭으로 (첫 탭이면 마지막 탭으로 wrap). 탭이 1 개 이하면 false.
    pub fn activatePrev(self: *SessionCore) bool {
        if (self.tabs.items.len <= 1) return false;
        self.active_tab = if (self.active_tab == 0) self.tabs.items.len - 1 else self.active_tab - 1;
        return true;
    }
};
