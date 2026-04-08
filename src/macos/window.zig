// macOS 윈도우 구현
// Cocoa NSPanel (드롭다운 터미널) 브릿지 래퍼.
// windows/window.zig와 동일한 공개 인터페이스를 제공한다.

const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("macos/bridge.h");
});

// ─── 플랫폼 타입 (Windows HWND 대응) ──────────────────────────────
pub const NativeHandle = ?*anyopaque; // TildazWindow (불투명 포인터)

pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

// ─── DockPosition (config.zig와 동일) ─────────────────────────────
pub const DockPosition = enum(u8) {
    top = 0,
    bottom = 1,
    left = 2,
    right = 3,
};

// ─── 앱 이벤트 (WM_* 대응) ────────────────────────────────────────
pub const AppEvent = enum(u32) {
    pty_output = 1,  // PTY에서 데이터 도착
    tab_closed = 2,  // 탭 프로세스 종료
};

// ─── Window ───────────────────────────────────────────────────────
pub const Window = struct {
    handle: NativeHandle = null,  // TildazWindow
    app: ?*anyopaque = null,      // TildazApp
    visible: bool = false,

    cell_width: c_int = 8,
    cell_height: c_int = 16,

    // 렌더/리사이즈 콜백 (Windows 버전과 동일한 시그니처)
    render_fn: ?*const fn (*Window) void = null,
    resize_fn: ?*const fn (u16, u16, ?*anyopaque) void = null,
    app_msg_fn: ?*const fn (c_uint, usize, isize, ?*anyopaque) bool = null,

    skip_swap: bool = false,
    shell_exited: bool = false,

    userdata: ?*anyopaque = null, // App 포인터

    // ─── init ────────────────────────────────────────────────────
    pub fn init(
        self: *Window,
        font_family: [*:0]const u8, // UTF-8 (macOS는 UTF-8 사용)
        font_size: c_int,
        opacity: u8,
        cell_width_scale: f32,
        line_height_scale: f32,
    ) !void {
        const app = c.tildazAppCreate() orelse return error.AppCreateFailed;
        self.app = app;

        var metrics: c.TildazFontMetrics = undefined;
        const win = c.tildazWindowCreate(
            app,
            font_family,
            @floatFromInt(font_size),
            opacity,
            cell_width_scale,
            line_height_scale,
            &metrics,
        ) orelse return error.WindowCreateFailed;

        self.handle = win;
        self.cell_width = @intFromFloat(@round(metrics.cell_width));
        self.cell_height = @intFromFloat(@round(metrics.cell_height));

        // 브릿지 콜백 등록
        c.tildazWindowSetRenderCallback(win, bridgeRenderFn, self);
        c.tildazWindowSetResizeCallback(win, bridgeResizeFn, self);

        // 글로벌 핫키 등록 (F1) — Accessibility 권한 없으면 무시
        _ = c.tildazRegisterHotkey(bridgeHotkeyFn, self);
    }

    pub fn deinit(self: *Window) void {
        c.tildazUnregisterHotkey();
        if (self.handle) |h| {
            c.tildazWindowDestroy(h);
            self.handle = null;
        }
        if (self.app) |a| {
            c.tildazAppTerminate(a);
            self.app = null;
        }
    }

    pub fn show(self: *Window) void {
        if (self.handle) |h| {
            c.tildazWindowShow(h);
            self.visible = true;
        }
    }

    pub fn hide(self: *Window) void {
        if (self.handle) |h| {
            c.tildazWindowHide(h);
            self.visible = false;
        }
    }

    pub fn toggle(self: *Window) void {
        if (self.visible) self.hide() else self.show();
    }

    pub fn setPosition(self: *Window, dock: DockPosition, width_pct: u8, height_pct: u8, offset_pct: u8) void {
        if (self.handle) |h| {
            c.tildazWindowSetPosition(h, @intFromEnum(dock), width_pct, height_pct, offset_pct);
        }
    }

    /// macOS 메인 런 루프 (NSApp run). Windows messageLoop에 대응.
    pub fn messageLoop(_: *Window) void {
        // NSApp.run()은 bridge.m에서 실행됨
        // 이 함수는 호출 후 반환되지 않음
    }

    // ─── 브릿지 콜백 (C 함수 포인터) ─────────────────────────────

    fn bridgeRenderFn(userdata: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(userdata orelse return));
        if (self.render_fn) |f| f(self);
    }

    fn bridgeResizeFn(cols: u16, rows: u16, userdata: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(userdata orelse return));
        if (self.resize_fn) |f| f(cols, rows, self.userdata);
    }

    fn bridgeHotkeyFn(userdata: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(userdata orelse return));
        self.toggle();
    }

    // ─── 클립보드 ────────────────────────────────────────────────

    pub fn clipboardGet(allocator: std.mem.Allocator) !?[]u8 {
        const raw = c.tildazClipboardGet() orelse return null;
        defer std.c.free(raw);
        const len = std.mem.len(raw);
        const buf = try allocator.alloc(u8, len);
        @memcpy(buf, raw[0..len]);
        return buf;
    }

    pub fn clipboardSet(text: []const u8) void {
        // null terminator 추가
        var buf: [4096]u8 = undefined;
        if (text.len < buf.len) {
            @memcpy(buf[0..text.len], text);
            buf[text.len] = 0;
            c.tildazClipboardSet(@ptrCast(&buf));
        }
    }

    // ─── PTY 이벤트 알림 (macOS 메인 스레드로 dispatch) ──────────
    // Windows의 PostMessageW(WM_PTY_OUTPUT) 대응
    pub fn notifyPtyOutput(self: *Window) void {
        if (self.app_msg_fn) |f| {
            // AppEvent.pty_output을 가상 메시지로 전달
            _ = f(@intFromEnum(AppEvent.pty_output), 0, 0, self.userdata);
        }
    }

    pub fn notifyTabClosed(self: *Window) void {
        if (self.app_msg_fn) |f| {
            _ = f(@intFromEnum(AppEvent.tab_closed), 0, 0, self.userdata);
        }
    }

    // ─── Metal 뷰 접근 ────────────────────────────────────────────
    pub fn getMetalView(self: *const Window) ?*anyopaque {
        return if (self.handle) |h| c.tildazWindowGetMetalView(h) else null;
    }
};
