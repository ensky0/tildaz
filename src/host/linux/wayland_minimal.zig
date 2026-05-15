//! Minimal Wayland wire client for the first Linux window milestone.
//!
//! This intentionally avoids linking `libwayland-client` so macOS-hosted Linux
//! cross builds keep working while the Linux backend is still young. It only
//! implements the tiny subset needed to create an `xdg-shell` toplevel with one
//! shared-memory color buffer.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const session_core = @import("../../session_core.zig");
const terminal_backend = @import("../../terminal.zig");
const terminal_interaction = @import("../../terminal_interaction.zig");
const app_event = @import("../../app_event.zig");
const themes = @import("../../themes.zig");
const log = @import("../../log.zig");
const software_terminal = @import("software_terminal.zig");
const xkb = @import("xkb.zig");

const display_id: u32 = 1;
const registry_id: u32 = 2;
const first_client_alloc_id: u32 = registry_id + 1;

const shm_format_xrgb8888: u32 = 1;
const default_width: i32 = 640;
const default_height: i32 = 420;
const min_width: i32 = 160;
const min_height: i32 = 120;
const default_theme = &themes.themes[0];
const shell_path = "/bin/sh";
const frame_poll_ms: i32 = 16;
const max_buffers_per_size: usize = 2;
const wl_seat_capability_pointer: u32 = 1;
const wl_seat_capability_keyboard: u32 = 2;
const wl_keyboard_keymap_format_xkb_v1: u32 = 1;
const wl_keyboard_key_state_pressed: u32 = 1;
const wl_keyboard_key_state_repeated: u32 = 2;
const wayland_xkb_keycode_offset: u32 = 8;

// Linux input-event-codes BTN_LEFT.
const wl_pointer_button_left: u32 = 0x110;
const wl_pointer_button_state_released: u32 = 0;
const wl_pointer_button_state_pressed: u32 = 1;
const wl_pointer_axis_vertical: u32 = 0;

// wl_seat opcodes (request side, used by `get_pointer` / `get_keyboard`).
const wl_seat_request_get_pointer: u16 = 0;
const wl_seat_request_get_keyboard: u16 = 1;

// wl_data_device_manager / wl_data_device / wl_data_source / wl_data_offer
// opcodes (request side, used by us).
const wl_data_device_manager_request_create_data_source: u16 = 0;
const wl_data_device_manager_request_get_data_device: u16 = 1;
const wl_data_source_request_offer: u16 = 0;
const wl_data_source_request_destroy: u16 = 1;
const wl_data_device_request_set_selection: u16 = 1;
// wl_data_offer requests: 0=accept (안 씀), 1=receive, 2=destroy.
// 처음 a9dab9e (L6.3 우클릭 paste) 에선 한 칸씩 어긋난 값 (0, 1) 으로 적혀
// receive 가 accept 자리로 보내져 서버가 args 검사 실패 → protocol error.
// L6.4 의 Ctrl+Shift+V 시연에서 첫 발현.
const wl_data_offer_request_receive: u16 = 1;
const wl_data_offer_request_destroy: u16 = 2;

// 우리가 광고할 / 받아들일 mime. 셋 모두 paste 인입 시 동일하게 처리.
const clipboard_mime_utf8: []const u8 = "text/plain;charset=utf-8";
const clipboard_mime_utf8_string: []const u8 = "UTF8_STRING";
const clipboard_mime_text_plain: []const u8 = "text/plain";

// Linux input-event-codes BTN_RIGHT (좌 = 0x110 위에서 정의).
const wl_pointer_button_right: u32 = 0x111;
// 더블클릭 인식 시간 — macOS / Windows / GTK / Qt 의 표준 ~500ms 와 동일.
const double_click_threshold_ms: u32 = 500;

const xkb_key_backspace: u32 = 0xff08;
const xkb_key_tab: u32 = 0xff09;
const xkb_key_return: u32 = 0xff0d;
const xkb_key_escape: u32 = 0xff1b;
const xkb_key_home: u32 = 0xff50;
const xkb_key_left: u32 = 0xff51;
const xkb_key_up: u32 = 0xff52;
const xkb_key_right: u32 = 0xff53;
const xkb_key_down: u32 = 0xff54;
const xkb_key_page_up: u32 = 0xff55;
const xkb_key_page_down: u32 = 0xff56;
const xkb_key_end: u32 = 0xff57;
const xkb_key_insert: u32 = 0xff63;
const xkb_key_delete: u32 = 0xffff;
const xkb_key_iso_left_tab: u32 = 0xfe20;
// 알파벳 키는 ASCII codepoint — xkb 가 Shift 활성 시 대문자 keysym 을 돌려준다.
const xkb_key_c_lower: u32 = 0x63;
const xkb_key_c_upper: u32 = 0x43;
const xkb_key_v_lower: u32 = 0x76;
const xkb_key_v_upper: u32 = 0x56;

const linux_extra_env = [_]terminal_backend.ExtraEnv{
    .{ .name = "TERM", .value = "xterm-256color" },
    .{ .name = "LANG", .value = "en_US.UTF-8" },
    .{ .name = "LC_CTYPE", .value = "en_US.UTF-8" },
    .{ .name = "COLORFGBG", .value = "15;0" },
    .{ .name = "SHELL", .value = shell_path },
};

const Global = struct {
    name: u32 = 0,
    version: u32 = 0,
};

const Capabilities = struct {
    compositor: Global = .{},
    shm: Global = .{},
    xdg_wm_base: Global = .{},
    seat: Global = .{},
    layer_shell: Global = .{},
    text_input_v3: Global = .{},
    data_device_manager: Global = .{},

    fn record(self: *Capabilities, name: u32, interface: []const u8, version: u32) void {
        if (std.mem.eql(u8, interface, "wl_compositor")) {
            self.compositor = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "wl_shm")) {
            self.shm = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "xdg_wm_base")) {
            self.xdg_wm_base = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "wl_seat")) {
            self.seat = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "zwlr_layer_shell_v1")) {
            self.layer_shell = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "zwp_text_input_manager_v3")) {
            self.text_input_v3 = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "wl_data_device_manager")) {
            self.data_device_manager = .{ .name = name, .version = version };
        }
    }
};

const ShmBuffer = struct {
    id: u32,
    fd: posix.fd_t,
    memory: []align(std.heap.page_size_min) u8,
    width: i32,
    height: i32,
    stride: i32,
    released: bool = false,

    fn deinit(self: *ShmBuffer) void {
        posix.munmap(self.memory);
        posix.close(self.fd);
    }
};

fn terminalSequenceForKeysym(sym: u32) ?[]const u8 {
    return switch (sym) {
        xkb_key_return => "\r",
        xkb_key_escape => "\x1b",
        xkb_key_backspace => "\x7f",
        xkb_key_tab => "\t",
        xkb_key_iso_left_tab => "\x1b[Z",
        xkb_key_up => "\x1b[A",
        xkb_key_down => "\x1b[B",
        xkb_key_right => "\x1b[C",
        xkb_key_left => "\x1b[D",
        xkb_key_home => "\x1b[H",
        xkb_key_end => "\x1b[F",
        xkb_key_insert => "\x1b[2~",
        xkb_key_delete => "\x1b[3~",
        xkb_key_page_up => "\x1b[5~",
        xkb_key_page_down => "\x1b[6~",
        else => null,
    };
}

fn createMemfd(name: [*:0]const u8) !posix.fd_t {
    const rc = linux.memfd_create(name, linux.MFD.CLOEXEC);
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .ACCES => error.AccessDenied,
        .INVAL => error.InvalidMemfdFlags,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        else => error.MemfdCreateFailed,
    };
}

const Client = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    caps: Capabilities = .{},
    input: [8192]u8 = undefined,
    input_len: usize = 0,
    received_fds: std.ArrayList(posix.fd_t) = .{},
    wait_callback_id: u32 = 0,
    wait_callback_done: bool = false,
    configured: bool = false,
    running: bool = true,
    saw_xrgb8888: bool = false,
    next_id: u32 = first_client_alloc_id,
    pending_width: i32 = 0,
    pending_height: i32 = 0,
    window_width: i32 = default_width,
    window_height: i32 = default_height,
    mapped: bool = false,
    renderer: software_terminal.Renderer = .{},
    session: ?session_core.SessionCore = null,
    shell_exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    needs_redraw: bool = false,
    active_buffer: ?ShmBuffer = null,
    retired_buffers: std.ArrayList(ShmBuffer) = .{},
    compositor_id: u32 = 0,
    shm_id: u32 = 0,
    wm_base_id: u32 = 0,
    surface_id: u32 = 0,
    xdg_surface_id: u32 = 0,
    toplevel_id: u32 = 0,
    seat_id: u32 = 0,
    keyboard_id: u32 = 0,
    pointer_id: u32 = 0,
    seat_capabilities: u32 = 0,
    keyboard: xkb.Keyboard = .{},
    pointer_x_px: i32 = -1,
    pointer_y_px: i32 = -1,
    pointer_inside: bool = false,
    data_device_manager_id: u32 = 0,
    data_device_id: u32 = 0,
    active_data_source_id: u32 = 0,
    clipboard_text: ?[]const u8 = null,
    last_serial: u32 = 0,
    // 우리가 paste 받기 위해 추적하는 wl_data_offer 객체. data_offer event 가
    // 새 객체를 알리면 pending 자리, selection event 가 그 객체를 인정하면
    // `paste_*` 로 승격. mime 광고는 offer event 가 도착할 때마다 누적.
    pending_offer_id: u32 = 0,
    pending_offer_has_utf8: bool = false,
    paste_offer_id: u32 = 0,
    paste_offer_has_utf8: bool = false,
    // 더블클릭 검출 — wayland `wl_pointer.button` event 에 click count 정보 없음.
    // 같은 cell 의 좌클릭 press 가 `double_click_threshold_ms` 이내 두 번이면 더블클릭.
    last_left_click_time_ms: u32 = 0,
    last_left_click_cell: ?terminal_interaction.Cell = null,

    fn init(allocator: std.mem.Allocator) !Client {
        const path = try waylandSocketPath(allocator);
        defer allocator.free(path);
        return .{
            .allocator = allocator,
            .stream = try std.net.connectUnixSocket(path),
        };
    }

    fn deinit(self: *Client) void {
        self.clearClipboardOwnership();
        self.keyboard.deinit();
        for (self.received_fds.items) |fd| posix.close(fd);
        self.received_fds.deinit(self.allocator);
        if (self.active_buffer) |*buffer| {
            self.destroyBufferObject(buffer.id);
            buffer.deinit();
            self.active_buffer = null;
        }
        for (self.retired_buffers.items) |*buffer| {
            self.destroyBufferObject(buffer.id);
            buffer.deinit();
        }
        self.retired_buffers.deinit(self.allocator);
        if (self.session) |*session| {
            session.deinit();
            self.session = null;
        }
        self.renderer.deinit(self.allocator);
        self.stream.close();
    }

    fn run(self: *Client) !void {
        try self.getRegistry();
        try self.roundtrip();

        if (self.caps.compositor.name == 0) return error.WaylandCompositorMissing;
        if (self.caps.shm.name == 0) return error.WaylandShmMissing;
        if (self.caps.xdg_wm_base.name == 0) return error.WaylandXdgWmBaseMissing;

        try self.bindGlobals();
        try self.roundtrip();
        self.logCapabilities();
        if (!self.saw_xrgb8888) return error.WaylandShmXrgb8888Missing;
        try self.createKeyboardIfAvailable();
        if (self.keyboard_id != 0) try self.roundtrip();

        try self.createShellObjects();
        try self.waitForConfigure();
        try self.ensureSessionGrid();
        _ = try self.redraw();

        std.debug.print("TildaZ Linux Wayland terminal window is open. Close the window to exit.\n", .{});
        log.appendLine("linux", "Wayland terminal window mapped", .{});

        while (self.running) {
            try self.pollAndDispatch(frame_poll_ms);
            if (self.shell_exited.load(.acquire)) {
                self.running = false;
                break;
            }
            if (self.session) |*session| {
                if (session.drainActiveOutputForRender()) {
                    self.requestRedraw();
                }
            }
            try self.maybeRedraw();
        }
    }

    fn getRegistry(self: *Client) !void {
        try self.sendNewId(display_id, 1, registry_id);
    }

    fn bindGlobals(self: *Client) !void {
        self.compositor_id = self.allocId();
        try self.bind(self.caps.compositor.name, "wl_compositor", @min(self.caps.compositor.version, 4), self.compositor_id);
        self.shm_id = self.allocId();
        try self.bind(self.caps.shm.name, "wl_shm", 1, self.shm_id);
        self.wm_base_id = self.allocId();
        try self.bind(self.caps.xdg_wm_base.name, "xdg_wm_base", 1, self.wm_base_id);
        if (self.caps.seat.name != 0) {
            self.seat_id = self.allocId();
            try self.bind(self.caps.seat.name, "wl_seat", @min(self.caps.seat.version, 7), self.seat_id);
        }
        if (self.caps.data_device_manager.name != 0) {
            self.data_device_manager_id = self.allocId();
            try self.bind(
                self.caps.data_device_manager.name,
                "wl_data_device_manager",
                @min(self.caps.data_device_manager.version, 3),
                self.data_device_manager_id,
            );
        }
        log.appendLine("wayland", "bound globals compositor_id={} shm_id={} wm_base_id={} seat_id={} data_device_manager_id={}", .{
            self.compositor_id,
            self.shm_id,
            self.wm_base_id,
            self.seat_id,
            self.data_device_manager_id,
        });
    }

    fn createKeyboardIfAvailable(self: *Client) !void {
        if (self.seat_id == 0 or self.keyboard_id != 0) return;
        if ((self.seat_capabilities & wl_seat_capability_keyboard) == 0) {
            log.appendLine("wayland", "wl_seat has no keyboard capability", .{});
            return;
        }

        self.keyboard_id = self.allocId();
        try self.sendNewId(self.seat_id, wl_seat_request_get_keyboard, self.keyboard_id);
        log.appendLine("wayland", "keyboard object created keyboard_id={}", .{self.keyboard_id});
    }

    fn createPointerIfAvailable(self: *Client) !void {
        if (self.seat_id == 0 or self.pointer_id != 0) return;
        if ((self.seat_capabilities & wl_seat_capability_pointer) == 0) {
            log.appendLine("wayland", "wl_seat has no pointer capability", .{});
            return;
        }

        self.pointer_id = self.allocId();
        try self.sendNewId(self.seat_id, wl_seat_request_get_pointer, self.pointer_id);
        log.appendLine("wayland", "pointer object created pointer_id={}", .{self.pointer_id});
    }

    /// seat 와 data_device_manager 가 모두 있으면 wl_data_device 객체 생성.
    /// clipboard 의 선결 조건. 없으면 자동 copy / paste 불가하지만 terminal 자체는
    /// 정상 — graceful degrade.
    fn createDataDeviceIfAvailable(self: *Client) !void {
        if (self.data_device_id != 0) return;
        if (self.seat_id == 0 or self.data_device_manager_id == 0) return;
        self.data_device_id = self.allocId();
        try self.sendArgs(
            self.data_device_manager_id,
            wl_data_device_manager_request_get_data_device,
            &.{ self.data_device_id, self.seat_id },
        );
        log.appendLine("wayland", "data device created data_device_id={}", .{self.data_device_id});
    }

    fn createShellObjects(self: *Client) !void {
        self.surface_id = self.allocId();
        try self.sendNewId(self.compositor_id, 0, self.surface_id);
        self.xdg_surface_id = self.allocId();
        try self.sendArgs(self.wm_base_id, 2, &.{ self.xdg_surface_id, self.surface_id });
        self.toplevel_id = self.allocId();
        try self.sendNewId(self.xdg_surface_id, 1, self.toplevel_id);
        try self.sendString(self.toplevel_id, 2, "TildaZ");
        try self.sendString(self.toplevel_id, 3, "tildaz");
        try self.sendNoArgs(self.surface_id, 6);
        log.appendLine("wayland", "shell objects surface_id={} xdg_surface_id={} toplevel_id={}", .{
            self.surface_id,
            self.xdg_surface_id,
            self.toplevel_id,
        });
    }

    fn waitForConfigure(self: *Client) !void {
        while (!self.configured) {
            try self.readAndDispatch();
        }
    }

    fn allocId(self: *Client) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn applyPendingSize(self: *Client) void {
        if (self.pending_width > 0) self.window_width = @max(self.pending_width, min_width);
        if (self.pending_height > 0) self.window_height = @max(self.pending_height, min_height);
    }

    fn requestRedraw(self: *Client) void {
        self.needs_redraw = true;
    }

    fn maybeRedraw(self: *Client) !void {
        if (!self.needs_redraw) return;
        if (try self.redraw()) {
            self.needs_redraw = false;
        }
    }

    fn gridSize(self: *const Client) struct { cols: u16, rows: u16 } {
        const usable_w = @max(software_terminal.cell_width_px, self.window_width - software_terminal.padding_px * 2);
        const usable_h = @max(software_terminal.cell_height_px, self.window_height - software_terminal.padding_px * 2);
        const cols_i32 = @max(1, @divTrunc(usable_w, software_terminal.cell_width_px));
        const rows_i32 = @max(1, @divTrunc(usable_h, software_terminal.cell_height_px));
        return .{
            .cols = @intCast(@min(cols_i32, std.math.maxInt(u16))),
            .rows = @intCast(@min(rows_i32, std.math.maxInt(u16))),
        };
    }

    fn ensureSessionGrid(self: *Client) !void {
        const grid = self.gridSize();
        if (self.session) |*session| {
            if (session.activeTab()) |tab| {
                if (tab.terminal.cols != grid.cols or tab.terminal.rows != grid.rows) {
                    session.resizeAll(grid.cols, grid.rows);
                    log.appendLine("linux", "terminal resized cols={} rows={}", .{ grid.cols, grid.rows });
                }
            }
            return;
        }

        self.session = session_core.SessionCore.init(
            self.allocator,
            shell_path,
            10_000,
            default_theme,
            &linux_extra_env,
            linuxTabExit,
            self,
        );
        try self.session.?.createTab(grid.cols, grid.rows);
        log.appendLine("linux", "terminal session created cols={} rows={}", .{ grid.cols, grid.rows });
    }

    fn redraw(self: *Client) !bool {
        self.applyPendingSize();
        self.discardReleasedRetiredBuffersExcept(self.window_width, self.window_height);
        if (self.active_buffer) |*buffer| {
            if (buffer.width == self.window_width and buffer.height == self.window_height) {
                if (buffer.released) {
                    self.paintBuffer(buffer.memory, buffer.width, buffer.height, buffer.stride);
                    try self.attachAndCommit(buffer.*);
                    buffer.released = false;
                    self.mapped = true;
                    return true;
                }
            }
        }

        var buffer = if (self.takeReusableBuffer(self.window_width, self.window_height)) |reusable|
            reusable
        else blk: {
            if (self.bufferCountForSize(self.window_width, self.window_height) >= max_buffers_per_size) return false;
            break :blk try self.createBuffer(self.window_width, self.window_height);
        };
        errdefer {
            self.destroyBufferObject(buffer.id);
            buffer.deinit();
        }
        self.paintBuffer(buffer.memory, buffer.width, buffer.height, buffer.stride);
        try self.retireActiveBuffer();
        try self.attachAndCommit(buffer);
        self.active_buffer = buffer;
        self.mapped = true;
        return true;
    }

    fn retireActiveBuffer(self: *Client) !void {
        if (self.active_buffer) |buffer| {
            if (buffer.released) {
                self.destroyBufferObject(buffer.id);
                var owned = buffer;
                owned.deinit();
            } else {
                try self.retired_buffers.append(self.allocator, buffer);
            }
            self.active_buffer = null;
        }
    }

    fn discardReleasedRetiredBuffersExcept(self: *Client, width: i32, height: i32) void {
        var i: usize = 0;
        while (i < self.retired_buffers.items.len) {
            const buffer = &self.retired_buffers.items[i];
            if (buffer.released and (buffer.width != width or buffer.height != height)) {
                self.destroyBufferObject(buffer.id);
                buffer.deinit();
                _ = self.retired_buffers.orderedRemove(i);
                continue;
            }
            i += 1;
        }
    }

    fn takeReusableBuffer(self: *Client, width: i32, height: i32) ?ShmBuffer {
        for (self.retired_buffers.items, 0..) |*buffer, i| {
            if (buffer.released and buffer.width == width and buffer.height == height) {
                return self.retired_buffers.orderedRemove(i);
            }
        }
        return null;
    }

    fn bufferCountForSize(self: *const Client, width: i32, height: i32) usize {
        var count: usize = 0;
        if (self.active_buffer) |buffer| {
            if (buffer.width == width and buffer.height == height) count += 1;
        }
        for (self.retired_buffers.items) |buffer| {
            if (buffer.width == width and buffer.height == height) count += 1;
        }
        return count;
    }

    fn createBuffer(self: *Client, width: i32, height: i32) !ShmBuffer {
        const stride: i32 = width * 4;
        const size_i32: i32 = stride * height;
        const size: usize = @intCast(size_i32);
        const pool_id = self.allocId();
        const new_buffer_id = self.allocId();
        log.appendLine("wayland", "create shm buffer {}x{} stride={} size={} pool_id={} buffer_id={}", .{
            width,
            height,
            stride,
            size_i32,
            pool_id,
            new_buffer_id,
        });

        const fd = try createMemfd("tildaz-wayland-buffer");
        errdefer posix.close(fd);
        try posix.ftruncate(fd, @intCast(size));

        const memory = try posix.mmap(
            null,
            size,
            linux.PROT.READ | linux.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer posix.munmap(memory);

        self.paintBuffer(memory, width, height, stride);

        try self.sendCreatePool(fd, size_i32, pool_id);
        try self.sendArgs(pool_id, 0, &.{
            new_buffer_id,
            0,
            @intCast(width),
            @intCast(height),
            @intCast(stride),
            shm_format_xrgb8888,
        });
        try self.sendNoArgs(pool_id, 1);

        return .{
            .id = new_buffer_id,
            .fd = fd,
            .memory = memory,
            .width = width,
            .height = height,
            .stride = stride,
            .released = false,
        };
    }

    fn paintBuffer(self: *Client, memory: []u8, width: i32, height: i32, stride: i32) void {
        if (self.session) |*session| {
            if (session.activeTab()) |tab| {
                self.renderer.paint(
                    self.allocator,
                    memory,
                    width,
                    height,
                    stride,
                    &tab.terminal,
                    default_theme,
                );
                return;
            }
        }
        fillBuffer(memory, width, height, stride);
    }

    fn attachAndCommit(self: *Client, buffer: ShmBuffer) !void {
        try self.sendArgs(self.surface_id, 1, &.{ buffer.id, 0, 0 });
        try self.sendArgs(self.surface_id, 2, &.{
            0,
            0,
            @intCast(buffer.width),
            @intCast(buffer.height),
        });
        try self.sendNoArgs(self.surface_id, 6);
    }

    fn roundtrip(self: *Client) !void {
        const callback_id = self.allocId();
        self.wait_callback_id = callback_id;
        self.wait_callback_done = false;
        try self.sendNewId(display_id, 0, callback_id);
        while (!self.wait_callback_done) {
            try self.readAndDispatch();
        }
    }

    fn readAndDispatch(self: *Client) !void {
        if (self.input_len == self.input.len) return error.WaylandReadBufferFull;
        const n = try self.recvWaylandBytes(self.input[self.input_len..]);
        if (n == 0) return error.WaylandConnectionClosed;
        self.input_len += n;
        try self.dispatchBuffered();
    }

    fn recvWaylandBytes(self: *Client, buf: []u8) !usize {
        var iov = [_]posix.iovec{.{
            .base = buf.ptr,
            .len = buf.len,
        }};
        var control: [cmsgSpace(@sizeOf(c_int) * 8)]u8 align(@alignOf(Cmsghdr)) = @splat(0);
        var msg = posix.msghdr{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = iov.len,
            .control = &control,
            .controllen = control.len,
            .flags = 0,
        };

        while (true) {
            const rc = linux.recvmsg(self.stream.handle, &msg, linux.MSG.CMSG_CLOEXEC);
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    if ((msg.flags & linux.MSG.CTRUNC) != 0) return error.WaylandControlMessageTruncated;
                    try self.storeReceivedFds(control[0..msg.controllen]);
                    return @intCast(rc);
                },
                .INTR => continue,
                .AGAIN => return 0,
                else => return error.WaylandReadFailed,
            }
        }
    }

    fn storeReceivedFds(self: *Client, control: []const u8) !void {
        var offset: usize = 0;
        while (offset + @sizeOf(Cmsghdr) <= control.len) {
            const hdr: *const Cmsghdr = @ptrCast(@alignCast(control.ptr + offset));
            if (hdr.len < @sizeOf(Cmsghdr) or offset + hdr.len > control.len) return error.WaylandBadControlMessage;
            if (hdr.level == linux.SOL.SOCKET and hdr.type == 1) {
                const data_start = offset + cmsgAlign(@sizeOf(Cmsghdr));
                const data_end = offset + hdr.len;
                var data_offset = data_start;
                while (data_offset + @sizeOf(c_int) <= data_end) : (data_offset += @sizeOf(c_int)) {
                    const fd: *const c_int = @ptrCast(@alignCast(control.ptr + data_offset));
                    try self.received_fds.append(self.allocator, fd.*);
                }
            }
            offset += cmsgAlign(hdr.len);
        }
    }

    fn pollAndDispatch(self: *Client, timeout_ms: i32) !void {
        if (self.input_len > 0) {
            try self.dispatchBuffered();
            return;
        }

        var fds = [_]posix.pollfd{.{
            .fd = self.stream.handle,
            .events = posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP,
            .revents = 0,
        }};
        const n = try posix.poll(&fds, timeout_ms);
        if (n == 0) return;
        if ((fds[0].revents & posix.POLL.NVAL) != 0) return error.WaylandConnectionClosed;
        if ((fds[0].revents & (posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP)) != 0) {
            try self.readAndDispatch();
        }
    }

    fn dispatchBuffered(self: *Client) !void {
        var offset: usize = 0;
        while (self.input_len - offset >= 8) {
            const id = readU32(self.input[offset..][0..4]);
            const word = readU32(self.input[offset + 4 ..][0..4]);
            const opcode: u16 = @intCast(word & 0xffff);
            const size: usize = @intCast(word >> 16);
            if (size < 8 or size > self.input.len) return error.WaylandBadMessage;
            if (self.input_len - offset < size) break;
            try self.handleEvent(id, opcode, self.input[offset + 8 .. offset + size]);
            offset += size;
        }

        if (offset > 0) {
            const rem = self.input_len - offset;
            std.mem.copyForwards(u8, self.input[0..rem], self.input[offset..self.input_len]);
            self.input_len = rem;
        }
    }

    fn handleEvent(self: *Client, id: u32, opcode: u16, payload: []const u8) !void {
        if (id == display_id) {
            if (opcode == 0) return self.handleDisplayError(payload);
            return;
        }
        if (id == registry_id) {
            if (opcode == 0) try self.handleRegistryGlobal(payload);
            return;
        }
        if (id == self.wait_callback_id and opcode == 0) {
            self.wait_callback_done = true;
            return;
        }
        if (id == self.shm_id and opcode == 0 and payload.len >= 4) {
            const fmt = readU32(payload[0..4]);
            if (fmt == shm_format_xrgb8888) self.saw_xrgb8888 = true;
            return;
        }
        if (id == self.seat_id) {
            try self.handleSeatEvent(opcode, payload);
            return;
        }
        if (id == self.keyboard_id) {
            try self.handleKeyboardEvent(opcode, payload);
            return;
        }
        if (self.pointer_id != 0 and id == self.pointer_id) {
            try self.handlePointerEvent(opcode, payload);
            return;
        }
        if (self.data_device_id != 0 and id == self.data_device_id) {
            try self.handleDataDeviceEvent(opcode, payload);
            return;
        }
        if (self.active_data_source_id != 0 and id == self.active_data_source_id) {
            try self.handleDataSourceEvent(opcode, payload);
            return;
        }
        if (self.pending_offer_id != 0 and id == self.pending_offer_id) {
            try self.handleDataOfferEvent(opcode, payload, true);
            return;
        }
        if (self.paste_offer_id != 0 and id == self.paste_offer_id) {
            try self.handleDataOfferEvent(opcode, payload, false);
            return;
        }
        if (self.handleBufferEvent(id, opcode)) return;
        if (id == self.wm_base_id and opcode == 0 and payload.len >= 4) {
            try self.sendArgs(self.wm_base_id, 3, &.{readU32(payload[0..4])});
            return;
        }
        if (id == self.toplevel_id and opcode == 0) {
            try self.handleToplevelConfigure(payload);
            return;
        }
        if (id == self.toplevel_id and opcode == 1) {
            self.running = false;
            return;
        }
        if (id == self.xdg_surface_id and opcode == 0 and payload.len >= 4) {
            try self.sendArgs(self.xdg_surface_id, 4, &.{readU32(payload[0..4])});
            self.applyPendingSize();
            if (self.session != null) try self.ensureSessionGrid();
            self.configured = true;
            if (self.mapped) self.requestRedraw();
            return;
        }
    }

    fn handleSeatEvent(self: *Client, opcode: u16, payload: []const u8) !void {
        if (opcode == 0 and payload.len >= 4) {
            self.seat_capabilities = readU32(payload[0..4]);
            if (self.keyboard_id == 0) try self.createKeyboardIfAvailable();
            if (self.pointer_id == 0) try self.createPointerIfAvailable();
            if (self.data_device_id == 0) try self.createDataDeviceIfAvailable();
            return;
        }
    }

    fn handleKeyboardEvent(self: *Client, opcode: u16, payload: []const u8) !void {
        switch (opcode) {
            0 => try self.handleKeyboardKeymap(payload),
            3 => try self.handleKeyboardKey(payload),
            4 => self.handleKeyboardModifiers(payload),
            5 => self.handleKeyboardRepeatInfo(payload),
            else => {},
        }
    }

    fn handleKeyboardKeymap(self: *Client, payload: []const u8) !void {
        if (payload.len < 8) return error.WaylandBadMessage;
        const format = readU32(payload[0..4]);
        const size_u32 = readU32(payload[4..8]);
        const fd = try self.takeReceivedFd();
        defer posix.close(fd);

        if (format != wl_keyboard_keymap_format_xkb_v1) {
            log.appendLine("wayland", "unsupported keyboard keymap format={}", .{format});
            return;
        }
        if (size_u32 == 0) return error.WaylandBadKeymap;

        const size: usize = @intCast(size_u32);
        const memory = try posix.mmap(
            null,
            size,
            linux.PROT.READ,
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        );
        defer posix.munmap(memory);

        try self.keyboard.setKeymap(self.allocator, memory);
        log.appendLine("wayland", "keyboard keymap loaded size={}", .{size});
    }

    fn handleKeyboardKey(self: *Client, payload: []const u8) !void {
        if (payload.len < 16) return error.WaylandBadMessage;
        self.last_serial = readU32(payload[0..4]);
        const key = readU32(payload[8..12]);
        const state = readU32(payload[12..16]);
        if (state != wl_keyboard_key_state_pressed and state != wl_keyboard_key_state_repeated) return;

        const xkb_key = key + wayland_xkb_keycode_offset;
        if (self.keyboard.oneSym(xkb_key)) |sym| {
            // Ctrl+Shift+C / V — SPEC.md §2.3 클립보드. Linux 도 Windows 와 같은
            // native modifier (Ctrl+Shift). 분기 안에서 utf8 PTY 송신은 차단해서
            // xkb 가 만든 noise byte 가 shell 에 들어가지 않게 한다.
            if (self.keyboard.ctrlActive() and self.keyboard.shiftActive()) {
                if (sym == xkb_key_c_lower or sym == xkb_key_c_upper) {
                    self.copyActiveSelection();
                    return;
                }
                if (sym == xkb_key_v_lower or sym == xkb_key_v_upper) {
                    self.pasteFromClipboard();
                    return;
                }
            }
            if (terminalSequenceForKeysym(sym)) |seq| {
                self.queueInput(seq);
                return;
            }
        }

        var buf: [64]u8 = undefined;
        const bytes = self.keyboard.utf8(xkb_key, &buf);
        if (bytes.len > 0) self.queueInput(bytes);
    }

    fn handleKeyboardModifiers(self: *Client, payload: []const u8) void {
        if (payload.len < 20) return;
        self.keyboard.updateMask(
            readU32(payload[4..8]),
            readU32(payload[8..12]),
            readU32(payload[12..16]),
            readU32(payload[16..20]),
        );
    }

    fn handleKeyboardRepeatInfo(_: *Client, payload: []const u8) void {
        if (payload.len < 8) return;
        log.appendLine("wayland", "keyboard repeat rate={} delay={}", .{
            readI32(payload[0..4]),
            readI32(payload[4..8]),
        });
    }

    fn handlePointerEvent(self: *Client, opcode: u16, payload: []const u8) !void {
        switch (opcode) {
            0 => self.handlePointerEnter(payload),
            1 => self.handlePointerLeave(payload),
            2 => self.handlePointerMotion(payload),
            3 => self.handlePointerButton(payload),
            4 => self.handlePointerAxis(payload),
            else => {},
        }
    }

    /// wl_pointer.enter(serial, surface, surface_x_fixed, surface_y_fixed).
    fn handlePointerEnter(self: *Client, payload: []const u8) void {
        if (payload.len < 16) return;
        self.last_serial = readU32(payload[0..4]);
        const sx = readI32(payload[8..12]);
        const sy = readI32(payload[12..16]);
        self.pointer_x_px = wlFixedToPx(sx);
        self.pointer_y_px = wlFixedToPx(sy);
        self.pointer_inside = true;
    }

    /// wl_pointer.leave(serial, surface) — drag 중이면 selection 은 유지.
    /// SPEC.md §3 / macOS `tildazMouseUp` 패턴 — drag 종료는 button release 에서만.
    fn handlePointerLeave(self: *Client, payload: []const u8) void {
        _ = payload;
        self.pointer_inside = false;
        self.pointer_x_px = -1;
        self.pointer_y_px = -1;
    }

    /// wl_pointer.motion(time, surface_x_fixed, surface_y_fixed).
    fn handlePointerMotion(self: *Client, payload: []const u8) void {
        if (payload.len < 12) return;
        // payload[0..4]=time.
        const sx = readI32(payload[4..8]);
        const sy = readI32(payload[8..12]);
        self.pointer_x_px = wlFixedToPx(sx);
        self.pointer_y_px = wlFixedToPx(sy);

        const tab = self.activeTabOrNull() orelse return;
        // 스크롤바 drag 중 — selection 검사보다 먼저. drag 가 cell 영역 밖으로
        // 나가도 follow (Windows `app_controller.scrollToY` 와 동등).
        if (tab.interaction.scrollbar.active) {
            self.scrollToY(self.pointer_y_px);
            return;
        }
        if (!tab.interaction.selection.active) return;
        const cell = self.pixelToCell(self.pointer_x_px, self.pointer_y_px) orelse return;
        tab.interaction.selection.update(tab.terminal.screens.active, cell);
        self.requestRedraw();
    }

    /// wl_pointer.button(serial, time, button, state).
    fn handlePointerButton(self: *Client, payload: []const u8) void {
        if (payload.len < 16) return;
        self.last_serial = readU32(payload[0..4]);
        const time_ms = readU32(payload[4..8]);
        const button = readU32(payload[8..12]);
        const state = readU32(payload[12..16]);

        if (button == wl_pointer_button_right) {
            // 우클릭 — pressed edge 에서 paste (cmd.exe console 표준 + Windows /
            // macOS 와 같은 정책. SPEC.md §3).
            if (state == wl_pointer_button_state_pressed) self.pasteFromClipboard();
            return;
        }
        if (button != wl_pointer_button_left) return;

        const tab = self.activeTabOrNull() orelse return;
        switch (state) {
            wl_pointer_button_state_pressed => {
                // 우측 스크롤바 영역 클릭 — selection / 더블클릭 보다 우선.
                // Windows `app_controller.zig:835` 와 동등.
                if (self.pointer_x_px >= self.window_width - software_terminal.scrollbar_w_px) {
                    tab.interaction.scrollbar.begin();
                    self.scrollToY(self.pointer_y_px);
                    return;
                }

                const cell = self.pixelToCell(self.pointer_x_px, self.pointer_y_px) orelse return;

                // 더블클릭 검출 — 같은 cell + threshold 이내 두 번째 좌클릭.
                // wayland `wl_pointer.button` event 에는 click count 정보가 없어
                // 직접 추적. SPEC.md §3 더블클릭 word selection.
                const is_double_click = blk: {
                    const prev_cell = self.last_left_click_cell orelse break :blk false;
                    if (time_ms -% self.last_left_click_time_ms > double_click_threshold_ms) break :blk false;
                    if (prev_cell.col != cell.col or prev_cell.row != cell.row) break :blk false;
                    break :blk true;
                };
                self.last_left_click_time_ms = time_ms;
                self.last_left_click_cell = cell;

                if (is_double_click) {
                    // selectWord 는 screen.selection 을 직접 갱신 (cross-platform
                    // 단일 구현 — [`terminal_interaction.selectWord`](src/terminal_interaction.zig)).
                    // SelectionState.begin 안 함 → 다음 release 의 finish 가 false
                    // → 자동 copy 중복 방지. 여기서 명시 copy 호출.
                    if (terminal_interaction.selectWord(tab.terminal.screens.active, cell)) {
                        self.copyActiveSelection();
                        self.requestRedraw();
                    }
                    return;
                }

                tab.interaction.selection.begin(tab.terminal.screens.active, cell);
                self.requestRedraw();
            },
            wl_pointer_button_state_released => {
                if (tab.interaction.scrollbar.active) {
                    tab.interaction.scrollbar.end();
                    return;
                }
                if (tab.interaction.selection.finish()) {
                    self.copyActiveSelection();
                    self.requestRedraw();
                }
            },
            else => {},
        }
    }

    /// 스크롤바 thumb 위치를 mouse_y 에 맞춘다. Windows `app_controller.scrollToY`
    /// (`src/app_controller.zig:422`) 의 패턴 그대로 — track height = `window_height
    /// - 2*padding`, thumb 의 최소 높이 / available 계산 / `scrollViewport(.delta)`.
    fn scrollToY(self: *Client, mouse_y: i32) void {
        const tab = self.activeTabOrNull() orelse return;
        const screen = tab.terminal.screens.active;
        const sb = screen.pages.scrollbar();
        if (sb.total <= sb.len) return;

        const track_h: i32 = self.window_height - 2 * software_terminal.padding_px;
        if (track_h <= 0) return;

        const rel_y: i32 = @max(0, mouse_y - software_terminal.padding_px);
        const track_hf: f64 = @floatFromInt(track_h);
        const ratio_px: f64 = track_hf / @as(f64, @floatFromInt(sb.total));
        const min_thumb: f64 = @floatFromInt(software_terminal.scrollbar_min_thumb_h);
        const thumb_h: f64 = @max(min_thumb, ratio_px * @as(f64, @floatFromInt(sb.len)));
        const available: f64 = track_hf - thumb_h;
        if (available <= 0) return;
        const clamped_y: f64 = @min(@as(f64, @floatFromInt(rel_y)), available);
        const scroll_ratio: f64 = clamped_y / available;
        const target_row: usize = @intFromFloat(scroll_ratio * @as(f64, @floatFromInt(sb.total - sb.len)));

        const current: isize = @intCast(sb.offset);
        const target: isize = @intCast(target_row);
        const delta = target - current;
        if (delta != 0) {
            tab.terminal.scrollViewport(.{ .delta = delta });
            self.requestRedraw();
        }
    }

    /// wl_pointer.axis(time, axis, value).
    ///
    /// 변환: wayland axis value 는 wl_fixed_t. mouse wheel 한 notch ≈ 10.0 (=2560 fixed).
    /// 부호는 wayland 가 *positive=scroll down* (content 가 위로 이동) 인 반면
    /// 우리 `ScrollEvent.wheel` 은 Windows 패턴 (positive=notch up = view 위로) — 부호 반전.
    /// Magnitude: 한 notch 당 wheel=120 (Windows WHEEL_DELTA 표준), session_core 의
    /// `@divTrunc(raw, 40)` 로 3 lines 가 default 가 되는 흐름과 호환.
    fn handlePointerAxis(self: *Client, payload: []const u8) void {
        if (payload.len < 12) return;
        const axis = readU32(payload[4..8]);
        if (axis != wl_pointer_axis_vertical) return;
        const value_fixed = readI32(payload[8..12]);

        // 한 notch (2560) → -120, 부호 반전 + magnitude 정규화.
        const wheel_i32: i32 = -@divTrunc(value_fixed * 120, 2560);
        if (wheel_i32 == 0) return;
        const wheel_i16: i16 = @intCast(std.math.clamp(wheel_i32, -32768, 32767));

        if (self.session) |*session| {
            const visible_rows: u16 = visibleRowCount(self.window_height);
            const did = session.scrollActive(.{ .wheel = wheel_i16 }, visible_rows);
            if (did) self.requestRedraw();
        }
    }

    /// wl_data_device 이벤트.
    /// - opcode 0: data_offer(new_id) — compositor 가 새 wl_data_offer 객체를
    ///   알린다. selection event 직전 단계라 일단 pending 자리에 기록.
    /// - opcode 5: selection(id) — clipboard 현재 owner 의 offer (id=0 이면 빈).
    ///   pending 을 paste 위치로 승격하거나, 이전 paste offer 를 정리한다.
    /// - 그 외 (enter / leave / motion / drop) — drag-and-drop 용이라 무관.
    fn handleDataDeviceEvent(self: *Client, opcode: u16, payload: []const u8) !void {
        switch (opcode) {
            0 => {
                if (payload.len < 4) return;
                self.discardPendingOffer();
                self.pending_offer_id = readU32(payload[0..4]);
                self.pending_offer_has_utf8 = false;
            },
            5 => self.handleDataDeviceSelection(payload),
            else => {},
        }
    }

    fn handleDataDeviceSelection(self: *Client, payload: []const u8) void {
        const offer_id: u32 = if (payload.len >= 4) readU32(payload[0..4]) else 0;

        // 이전 paste offer 정리.
        if (self.paste_offer_id != 0) {
            self.sendNoArgs(self.paste_offer_id, wl_data_offer_request_destroy) catch {};
            self.paste_offer_id = 0;
            self.paste_offer_has_utf8 = false;
        }

        if (offer_id != 0 and offer_id == self.pending_offer_id) {
            self.paste_offer_id = self.pending_offer_id;
            self.paste_offer_has_utf8 = self.pending_offer_has_utf8;
            self.pending_offer_id = 0;
            self.pending_offer_has_utf8 = false;
        } else {
            // 빈 selection 또는 우리가 추적 못 한 offer — pending 도 청소.
            self.discardPendingOffer();
        }
    }

    fn discardPendingOffer(self: *Client) void {
        if (self.pending_offer_id != 0) {
            self.sendNoArgs(self.pending_offer_id, wl_data_offer_request_destroy) catch {};
            self.pending_offer_id = 0;
            self.pending_offer_has_utf8 = false;
        }
    }

    /// wl_data_offer 이벤트. 우리가 관심 있는 것은 offer(mime) 만.
    /// `is_pending` 은 caller 가 분기 — 같은 코드, 다른 flag 슬롯.
    fn handleDataOfferEvent(self: *Client, opcode: u16, payload: []const u8, is_pending: bool) !void {
        if (opcode != 0) return; // source_actions / action 은 dnd 전용이라 무시.
        var p = Parser{ .buf = payload };
        const mime = p.readString() catch return;
        if (!isAcceptableTextMime(mime)) return;
        if (is_pending) {
            self.pending_offer_has_utf8 = true;
        } else {
            self.paste_offer_has_utf8 = true;
        }
    }

    /// 우클릭 paste — Windows / macOS 와 같은 패턴 ([SPEC.md §3 우클릭 paste]).
    /// 현재 paste_offer 가 utf8 광고했으면 pipe 만든 뒤 wl_data_offer.receive 로
    /// write end 를 송신측에 넘기고, read end 에서 끝까지 읽어 PTY 로 paste.
    fn pasteFromClipboard(self: *Client) void {
        if (self.paste_offer_id == 0 or !self.paste_offer_has_utf8) return;
        const session = if (self.session) |*s| s else return;
        _ = session.activeTab() orelse return;

        // self-paste 가드: 우리 자신이 마지막 clipboard owner 면 wayland 경유
        // 시 compositor 가 우리 source.send event 를 main thread 로 보내는데
        // 우리는 아래 posix.read 에서 blocking → wayland event 못 들어와
        // deadlock. 우리 buffer 직접 사용.
        if (self.active_data_source_id != 0) {
            if (self.clipboard_text) |text| {
                session.pasteToActive(text);
                self.requestRedraw();
            }
            return;
        }

        const pipe_fds = posix.pipe() catch return;
        // read end 는 우리, write end 는 wayland 가 보낼 송신측.
        const read_fd = pipe_fds[0];
        const write_fd = pipe_fds[1];

        self.sendStringWithFd(
            self.paste_offer_id,
            wl_data_offer_request_receive,
            clipboard_mime_utf8,
            write_fd,
        ) catch {
            posix.close(read_fd);
            posix.close(write_fd);
            return;
        };
        posix.close(write_fd); // 우리 쪽 write end 는 안 씀.

        // wayland 가 우리 송신 후 다른 쪽 fd 에 write 하기 시작. blocking read 로
        // 끝까지 (EOF) 받는다. text paste 가 일반적으로 짧고 fd 가 pipe 라 deadlock
        // 없음 — 송신측이 close 하면 우리 read 0 반환.
        defer posix.close(read_fd);
        var buf: [4096]u8 = undefined;
        var accumulated: std.ArrayList(u8) = .{};
        defer accumulated.deinit(self.allocator);
        while (true) {
            const n = posix.read(read_fd, &buf) catch break;
            if (n == 0) break;
            accumulated.appendSlice(self.allocator, buf[0..n]) catch break;
        }
        if (accumulated.items.len == 0) return;
        if (self.session) |*s| {
            s.pasteToActive(accumulated.items);
            self.requestRedraw();
        }
    }

    /// wl_data_source 이벤트 분기.
    /// - opcode 1: send(mime, fd) — compositor 가 paste 요청. fd 에 우리 clipboard
    ///   text 를 동기 write 후 close.
    /// - opcode 2: cancelled — 다른 앱이 clipboard 점유. 우리 source 정리.
    /// - 그 외 (target / dnd_*) — drag-and-drop 용이라 우리 흐름에 무관.
    fn handleDataSourceEvent(self: *Client, opcode: u16, payload: []const u8) !void {
        switch (opcode) {
            1 => try self.handleDataSourceSend(payload),
            2 => self.handleDataSourceCancelled(),
            else => {},
        }
    }

    fn handleDataSourceSend(self: *Client, payload: []const u8) !void {
        _ = payload; // mime 문자열은 우리가 advertise 한 유일 mime 라 검사 생략.
        const fd = self.takeReceivedFd() catch return;
        defer posix.close(fd);

        const text = self.clipboard_text orelse return;
        // fd 가 pipe 이므로 한 번에 다 못 보낼 수 있다 — 짧은 selection 위주라
        // loop 으로 끝까지 시도. SIGPIPE 는 wayland 가 자기 reader 쪽에서 처리한다.
        var offset: usize = 0;
        while (offset < text.len) {
            const n = posix.write(fd, text[offset..]) catch return;
            if (n == 0) break;
            offset += n;
        }
    }

    fn handleDataSourceCancelled(self: *Client) void {
        self.clearClipboardOwnership();
    }

    /// 활성 탭의 ghostty selection 을 추출해 wayland clipboard owner 로 등록.
    /// macOS / Windows 의 `tab_actions.copyActiveSelection` 와 결과 동등.
    fn copyActiveSelection(self: *Client) void {
        if (self.data_device_id == 0) return; // clipboard protocol 없음 — graceful.
        const tab = self.activeTabOrNull() orelse return;
        const screen = tab.terminal.screens.active;
        const sel = screen.selection orelse return;
        // ghostty selectionString 결과 ptr 의 ownership 이 우리 allocator 가 아니라
        // ghostty 의 자체 arena. 우리 GPA 로 free 하면 invalid free panic. dupe 로
        // 우리 buffer 만들어 그것만 보관 + free (#189 5차 시연 진단).
        const ghostty_text = screen.selectionString(self.allocator, .{ .sel = sel }) catch return;
        if (ghostty_text.len == 0) return;
        const owned = self.allocator.dupe(u8, ghostty_text) catch return;
        self.setClipboardText(owned) catch {
            self.allocator.free(owned);
        };
    }

    /// 새 clipboard text 로 owner 갱신. 기존 source 가 있으면 cleanup 후 새로.
    /// `text` ownership 을 self 가 가져간다. 호출 후 호출자는 free 하지 않는다.
    fn setClipboardText(self: *Client, text: []const u8) !void {
        if (self.last_serial == 0) {
            // 어떤 input event 도 아직 못 받았으면 wayland 가 set_selection 을 거부.
            // 실용적으로 거의 불가능한 path 지만 안전상 명시.
            self.allocator.free(text);
            return;
        }
        self.clearClipboardOwnership();

        const source_id = self.allocId();
        try self.sendNewId(
            self.data_device_manager_id,
            wl_data_device_manager_request_create_data_source,
            source_id,
        );
        try self.sendString(source_id, wl_data_source_request_offer, clipboard_mime_utf8);
        try self.sendArgs(
            self.data_device_id,
            wl_data_device_request_set_selection,
            &.{ source_id, self.last_serial },
        );

        self.active_data_source_id = source_id;
        self.clipboard_text = text;
    }

    fn clearClipboardOwnership(self: *Client) void {
        if (self.active_data_source_id != 0) {
            self.sendNoArgs(self.active_data_source_id, wl_data_source_request_destroy) catch {};
            self.active_data_source_id = 0;
        }
        if (self.clipboard_text) |buf| {
            self.allocator.free(buf);
            self.clipboard_text = null;
        }
    }

    /// surface pixel → grid cell. padding 영역 / grid 범위 밖이면 null.
    fn pixelToCell(self: *Client, px: i32, py: i32) ?terminal_interaction.Cell {
        if (px < software_terminal.padding_px or py < software_terminal.padding_px) return null;
        const tab = self.activeTabOrNull() orelse return null;
        const col_i32: i32 = @divTrunc(px - software_terminal.padding_px, software_terminal.cell_width_px);
        const row_i32: i32 = @divTrunc(py - software_terminal.padding_px, software_terminal.cell_height_px);
        if (col_i32 < 0 or row_i32 < 0) return null;
        const cols_i32: i32 = @intCast(tab.terminal.cols);
        const rows_i32: i32 = @intCast(tab.terminal.rows);
        if (col_i32 >= cols_i32 or row_i32 >= rows_i32) return null;
        return .{ .col = @intCast(col_i32), .row = @intCast(row_i32) };
    }

    fn activeTabOrNull(self: *Client) ?*session_core.Tab {
        if (self.session) |*session| return session.activeTab();
        return null;
    }

    fn takeReceivedFd(self: *Client) !posix.fd_t {
        if (self.received_fds.items.len == 0) return error.WaylandMissingFd;
        return self.received_fds.orderedRemove(0);
    }

    fn queueInput(self: *Client, bytes: []const u8) void {
        if (self.session) |*session| {
            session.queueInputToActive(bytes);
            self.requestRedraw();
        }
    }

    fn handleToplevelConfigure(self: *Client, payload: []const u8) !void {
        if (payload.len < 12) return error.WaylandBadMessage;
        self.pending_width = readI32(payload[0..4]);
        self.pending_height = readI32(payload[4..8]);
    }

    fn handleBufferEvent(self: *Client, id: u32, opcode: u16) bool {
        if (opcode != 0) return false;

        if (self.active_buffer) |*buffer| {
            if (buffer.id == id) {
                buffer.released = true;
                return true;
            }
        }

        for (self.retired_buffers.items) |*buffer| {
            if (buffer.id == id) {
                buffer.released = true;
                return true;
            }
        }

        return false;
    }

    fn handleRegistryGlobal(self: *Client, payload: []const u8) !void {
        if (payload.len < 12) return error.WaylandBadMessage;
        const name = readU32(payload[0..4]);
        var p = Parser{ .buf = payload[4..] };
        const interface = try p.readString();
        const version = try p.readU32();
        self.caps.record(name, interface, version);
    }

    fn handleDisplayError(_: *Client, payload: []const u8) !void {
        if (payload.len < 12) return error.WaylandDisplayError;
        const object_id = readU32(payload[0..4]);
        const code = readU32(payload[4..8]);
        var p = Parser{ .buf = payload[8..] };
        const msg = p.readString() catch "(unparseable)";
        std.debug.print("Wayland protocol error: object={} code={} message={s}\n", .{ object_id, code, msg });
        log.appendLine("wayland", "protocol error object={} code={} message={s}", .{ object_id, code, msg });
        return error.WaylandDisplayError;
    }

    fn logCapabilities(self: *Client) void {
        const layer = self.caps.layer_shell.name != 0;
        const text_input = self.caps.text_input_v3.name != 0;
        std.debug.print(
            "Wayland capabilities: wl_compositor={} wl_shm={} xdg_wm_base={} zwlr_layer_shell_v1={} zwp_text_input_manager_v3={}\n",
            .{
                self.caps.compositor.name != 0,
                self.caps.shm.name != 0,
                self.caps.xdg_wm_base.name != 0,
                layer,
                text_input,
            },
        );
        log.appendLine(
            "wayland",
            "capabilities compositor={} shm={} xdg_wm_base={} layer_shell={} text_input_v3={} data_device_manager={} shm_xrgb8888={}",
            .{
                self.caps.compositor.name != 0,
                self.caps.shm.name != 0,
                self.caps.xdg_wm_base.name != 0,
                layer,
                text_input,
                self.caps.data_device_manager.name != 0,
                self.saw_xrgb8888,
            },
        );
    }

    fn bind(self: *Client, name: u32, interface: []const u8, version: u32, new_id: u32) !void {
        var msg = Msg.init(registry_id, 0);
        try msg.putU32(name);
        try msg.putString(interface);
        try msg.putU32(version);
        try msg.putU32(new_id);
        try msg.send(self.stream);
    }

    fn sendCreatePool(self: *Client, fd: posix.fd_t, size: i32, pool_id: u32) !void {
        var msg = Msg.init(self.shm_id, 0);
        try msg.putU32(pool_id);
        try msg.putI32(size);
        try msg.sendWithFd(self.stream, fd);
    }

    fn sendStringWithFd(self: *Client, id: u32, opcode: u16, text: []const u8, fd: posix.fd_t) !void {
        var msg = Msg.init(id, opcode);
        try msg.putString(text);
        try msg.sendWithFd(self.stream, fd);
    }

    fn sendNoArgs(self: *Client, id: u32, opcode: u16) !void {
        var msg = Msg.init(id, opcode);
        try msg.send(self.stream);
    }

    fn sendNewId(self: *Client, id: u32, opcode: u16, new_id: u32) !void {
        var msg = Msg.init(id, opcode);
        try msg.putU32(new_id);
        try msg.send(self.stream);
    }

    fn sendString(self: *Client, id: u32, opcode: u16, text: []const u8) !void {
        var msg = Msg.init(id, opcode);
        try msg.putString(text);
        try msg.send(self.stream);
    }

    fn sendArgs(self: *Client, id: u32, opcode: u16, args: []const u32) !void {
        var msg = Msg.init(id, opcode);
        for (args) |arg| try msg.putU32(arg);
        try msg.send(self.stream);
    }

    fn destroyBufferObject(self: *Client, id: u32) void {
        self.sendNoArgs(id, 0) catch {};
    }
};

fn linuxTabExit(_: usize, userdata: ?*anyopaque) void {
    const client: *Client = @ptrCast(@alignCast(userdata.?));
    client.shell_exited.store(true, .release);
}

pub fn runBaselineWindow(allocator: std.mem.Allocator) !void {
    var client = try Client.init(allocator);
    defer client.deinit();
    try client.run();
}

const Msg = struct {
    buf: [512]u8 = undefined,
    len: usize = 8,
    id: u32,
    opcode: u16,

    fn init(id: u32, opcode: u16) Msg {
        return .{ .id = id, .opcode = opcode };
    }

    fn putU32(self: *Msg, value: u32) !void {
        if (self.len + 4 > self.buf.len) return error.WaylandMessageTooLarge;
        writeU32(self.buf[self.len..][0..4], value);
        self.len += 4;
    }

    fn putI32(self: *Msg, value: i32) !void {
        try self.putU32(@bitCast(value));
    }

    fn putString(self: *Msg, value: []const u8) !void {
        const wire_len = value.len + 1;
        const padded = align4(wire_len);
        if (self.len + 4 + padded > self.buf.len) return error.WaylandMessageTooLarge;
        try self.putU32(@intCast(wire_len));
        @memcpy(self.buf[self.len..][0..value.len], value);
        self.buf[self.len + value.len] = 0;
        @memset(self.buf[self.len + wire_len .. self.len + padded], 0);
        self.len += padded;
    }

    fn finish(self: *Msg) []const u8 {
        writeU32(self.buf[0..4], self.id);
        const word = (@as(u32, @intCast(self.len)) << 16) | self.opcode;
        writeU32(self.buf[4..8], word);
        return self.buf[0..self.len];
    }

    fn send(self: *Msg, stream: std.net.Stream) !void {
        try stream.writeAll(self.finish());
    }

    fn sendWithFd(self: *Msg, stream: std.net.Stream, fd: posix.fd_t) !void {
        const bytes = self.finish();
        var iov = [_]posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};

        const fd_payload_size = @sizeOf(c_int);
        const control_len = cmsgLen(fd_payload_size);
        var control: [cmsgSpace(fd_payload_size)]u8 align(@alignOf(Cmsghdr)) = @splat(0);
        const hdr: *Cmsghdr = @ptrCast(@alignCast(&control));
        hdr.* = .{
            .len = control_len,
            .level = linux.SOL.SOCKET,
            .type = 1, // SCM_RIGHTS
        };
        const fd_i32: c_int = fd;
        const data_offset = cmsgAlign(@sizeOf(Cmsghdr));
        @memcpy(control[data_offset..][0..fd_payload_size], std.mem.asBytes(&fd_i32));

        const msg = posix.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = iov[0..].ptr,
            .iovlen = iov.len,
            .control = control[0..].ptr,
            .controllen = control_len,
            .flags = 0,
        };
        const sent = try posix.sendmsg(stream.handle, &msg, 0);
        if (sent != bytes.len) return error.WaylandShortFdWrite;
    }
};

const Cmsghdr = extern struct {
    len: usize,
    level: c_int,
    type: c_int,
};

const Parser = struct {
    buf: []const u8,
    pos: usize = 0,

    fn readU32(self: *Parser) !u32 {
        if (self.pos + 4 > self.buf.len) return error.WaylandBadMessage;
        const v = wayland_minimal_readU32(self.buf[self.pos..][0..4]);
        self.pos += 4;
        return v;
    }

    fn readString(self: *Parser) ![]const u8 {
        const wire_len = try self.readU32();
        if (wire_len == 0) return error.WaylandBadMessage;
        const len_usize: usize = @intCast(wire_len);
        const padded = align4(len_usize);
        if (self.pos + padded > self.buf.len) return error.WaylandBadMessage;
        const raw = self.buf[self.pos .. self.pos + len_usize];
        self.pos += padded;
        if (raw[raw.len - 1] != 0) return error.WaylandBadMessage;
        return raw[0 .. raw.len - 1];
    }
};

fn waylandSocketPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "WAYLAND_DISPLAY")) |display| {
        if (display.len > 0 and display[0] == '/') return display;
        errdefer allocator.free(display);
        const runtime = try std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR");
        defer allocator.free(runtime);
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ runtime, display });
        allocator.free(display);
        return path;
    } else |_| {
        const runtime = try std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR");
        defer allocator.free(runtime);
        return std.fmt.allocPrint(allocator, "{s}/wayland-0", .{runtime});
    }
}

fn fillBuffer(memory: []u8, width: i32, height: i32, stride: i32) void {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const s: usize = @intCast(stride);
    for (0..h) |y| {
        for (0..w) |x| {
            const green: u32 = @intCast(92 + (x * 80 / @max(w, 1)));
            const blue: u32 = @intCast(48 + (y * 70 / @max(h, 1)));
            const color: u32 = (0x24 << 16) | (green << 8) | blue;
            writeU32(memory[y * s + x * 4 ..][0..4], color);
        }
    }
}

/// paste 인입으로 받아들일 mime. 셋 중 하나만 광고돼도 paste 가능. 셋 다
/// UTF-8 plain text 표기 — 우리는 byte 그대로 PTY 로 넣으므로 charset
/// fallback 가공 없음.
fn isAcceptableTextMime(mime: []const u8) bool {
    return std.mem.eql(u8, mime, clipboard_mime_utf8) or
        std.mem.eql(u8, mime, clipboard_mime_utf8_string) or
        std.mem.eql(u8, mime, clipboard_mime_text_plain);
}

/// wayland wire string parsing — `u32 length + (length bytes, null 포함)` +
/// 4-byte 정렬 padding. length 가 null 을 포함하는 게 일반적이지만 일부
/// compositor 가 안 포함하는 경우 대비해 마지막 byte 가 null 이면 빼고
/// 반환. payload 가 짧거나 length 가 0 이면 null.
fn readWaylandString(payload: []const u8) ?[]const u8 {
    if (payload.len < 4) return null;
    const len = readU32(payload[0..4]);
    if (len == 0) return null;
    const total: usize = @intCast(len);
    if (payload.len < 4 + total) return null;
    if (payload[4 + total - 1] == 0) {
        return payload[4 .. 4 + total - 1];
    }
    return payload[4 .. 4 + total];
}

/// wl_fixed_t (signed 24.8 fixed-point packed in i32) → integer pixel.
/// surface 좌표는 음수가 정상 흐름엔 안 들어오지만, leave 직후 등 edge case 대비
/// `@divTrunc` 로 0 방향 정수 변환 — pixelToCell 의 범위 검사가 음수 reject.
fn wlFixedToPx(value: i32) i32 {
    return @divTrunc(value, 256);
}

/// 현재 window_height 에서 grid 가 그릴 수 있는 row 수. SessionCore.scrollActive
/// 의 visible_rows 인자에 사용 — page scroll 계산용. wheel scroll 자체는 wheel
/// 값 (i16) 만 보지만 인터페이스 합치기 위해 같이 전달.
fn visibleRowCount(window_height: i32) u16 {
    const usable = @max(0, window_height - software_terminal.padding_px * 2);
    const rows_i32 = @divTrunc(usable, software_terminal.cell_height_px);
    if (rows_i32 <= 0) return 1;
    return @intCast(@min(rows_i32, std.math.maxInt(u16)));
}

fn readU32(bytes: *const [4]u8) u32 {
    return wayland_minimal_readU32(bytes);
}

fn readI32(bytes: *const [4]u8) i32 {
    return @bitCast(readU32(bytes));
}

fn wayland_minimal_readU32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .little);
}

fn writeU32(bytes: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, bytes, value, .little);
}

fn align4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

fn cmsgAlign(n: usize) usize {
    const a = @sizeOf(usize);
    const mask: usize = a - 1;
    return (n + mask) & ~mask;
}

fn cmsgLen(payload_len: usize) usize {
    return cmsgAlign(@sizeOf(Cmsghdr)) + payload_len;
}

fn cmsgSpace(payload_len: usize) usize {
    return cmsgAlign(@sizeOf(Cmsghdr)) + cmsgAlign(payload_len);
}
