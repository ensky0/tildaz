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
const themes = @import("../../themes.zig");
const log = @import("../../log.zig");
const software_terminal = @import("software_terminal.zig");

const display_id: u32 = 1;
const registry_id: u32 = 2;
const compositor_id: u32 = 4;
const shm_id: u32 = 5;
const wm_base_id: u32 = 6;

const surface_id: u32 = 8;
const xdg_surface_id: u32 = 9;
const toplevel_id: u32 = 10;

const shm_format_xrgb8888: u32 = 1;
const default_width: i32 = 640;
const default_height: i32 = 420;
const min_width: i32 = 160;
const min_height: i32 = 120;
const default_theme = &themes.themes[0];
const shell_path = "/bin/sh";
const frame_poll_ms: i32 = 16;

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
    layer_shell: Global = .{},
    text_input_v3: Global = .{},

    fn record(self: *Capabilities, name: u32, interface: []const u8, version: u32) void {
        if (std.mem.eql(u8, interface, "wl_compositor")) {
            self.compositor = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "wl_shm")) {
            self.shm = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "xdg_wm_base")) {
            self.xdg_wm_base = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "zwlr_layer_shell_v1")) {
            self.layer_shell = .{ .name = name, .version = version };
        } else if (std.mem.eql(u8, interface, "zwp_text_input_manager_v3")) {
            self.text_input_v3 = .{ .name = name, .version = version };
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

    fn deinit(self: *ShmBuffer) void {
        posix.munmap(self.memory);
        posix.close(self.fd);
    }
};

const Client = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    caps: Capabilities = .{},
    input: [8192]u8 = undefined,
    input_len: usize = 0,
    wait_callback_id: u32 = 0,
    wait_callback_done: bool = false,
    configured: bool = false,
    running: bool = true,
    saw_xrgb8888: bool = false,
    next_id: u32 = 20,
    pending_width: i32 = 0,
    pending_height: i32 = 0,
    window_width: i32 = default_width,
    window_height: i32 = default_height,
    mapped: bool = false,
    renderer: software_terminal.Renderer = .{},
    session: ?session_core.SessionCore = null,
    shell_exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    active_buffer: ?ShmBuffer = null,
    retired_buffers: std.ArrayList(ShmBuffer) = .{},

    fn init(allocator: std.mem.Allocator) !Client {
        const path = try waylandSocketPath(allocator);
        defer allocator.free(path);
        return .{
            .allocator = allocator,
            .stream = try std.net.connectUnixSocket(path),
        };
    }

    fn deinit(self: *Client) void {
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
        try self.roundtrip(3);

        if (self.caps.compositor.name == 0) return error.WaylandCompositorMissing;
        if (self.caps.shm.name == 0) return error.WaylandShmMissing;
        if (self.caps.xdg_wm_base.name == 0) return error.WaylandXdgWmBaseMissing;

        try self.bindGlobals();
        try self.roundtrip(7);
        self.logCapabilities();
        if (!self.saw_xrgb8888) return error.WaylandShmXrgb8888Missing;

        try self.createShellObjects();
        try self.waitForConfigure();
        try self.ensureSessionGrid();
        try self.redraw();

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
                    try self.redraw();
                }
            }
        }
    }

    fn getRegistry(self: *Client) !void {
        try self.sendNewId(display_id, 1, registry_id);
    }

    fn bindGlobals(self: *Client) !void {
        try self.bind(self.caps.compositor.name, "wl_compositor", @min(self.caps.compositor.version, 4), compositor_id);
        try self.bind(self.caps.shm.name, "wl_shm", 1, shm_id);
        try self.bind(self.caps.xdg_wm_base.name, "xdg_wm_base", 1, wm_base_id);
    }

    fn createShellObjects(self: *Client) !void {
        try self.sendNewId(compositor_id, 0, surface_id);
        try self.sendArgs(wm_base_id, 2, &.{ xdg_surface_id, surface_id });
        try self.sendNewId(xdg_surface_id, 1, toplevel_id);
        try self.sendString(toplevel_id, 2, "TildaZ");
        try self.sendString(toplevel_id, 3, "tildaz");
        try self.sendNoArgs(surface_id, 6);
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

    fn redraw(self: *Client) !void {
        self.applyPendingSize();
        if (self.active_buffer) |buffer| {
            try self.retired_buffers.append(self.allocator, buffer);
            self.active_buffer = null;
        }

        var buffer = try self.createBuffer(self.window_width, self.window_height);
        errdefer {
            self.destroyBufferObject(buffer.id);
            buffer.deinit();
        }
        try self.attachAndCommit(buffer);
        self.active_buffer = buffer;
        self.mapped = true;
        log.appendLine("wayland", "redraw {}x{} buffer_id={}", .{ self.window_width, self.window_height, buffer.id });
    }

    fn createBuffer(self: *Client, width: i32, height: i32) !ShmBuffer {
        const stride: i32 = width * 4;
        const size_i32: i32 = stride * height;
        const size: usize = @intCast(size_i32);
        const pool_id = self.allocId();
        const new_buffer_id = self.allocId();

        const fd = try posix.memfd_create("tildaz-wayland-buffer", posix.MFD.CLOEXEC);
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
        try self.sendArgs(surface_id, 1, &.{ buffer.id, 0, 0 });
        try self.sendArgs(surface_id, 2, &.{
            0,
            0,
            @intCast(buffer.width),
            @intCast(buffer.height),
        });
        try self.sendNoArgs(surface_id, 6);
    }

    fn roundtrip(self: *Client, callback_id: u32) !void {
        self.wait_callback_id = callback_id;
        self.wait_callback_done = false;
        try self.sendNewId(display_id, 0, callback_id);
        while (!self.wait_callback_done) {
            try self.readAndDispatch();
        }
    }

    fn readAndDispatch(self: *Client) !void {
        if (self.input_len == self.input.len) return error.WaylandReadBufferFull;
        const n = try self.stream.read(self.input[self.input_len..]);
        if (n == 0) return error.WaylandConnectionClosed;
        self.input_len += n;
        try self.dispatchBuffered();
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
        if (id == shm_id and opcode == 0 and payload.len >= 4) {
            const fmt = readU32(payload[0..4]);
            if (fmt == shm_format_xrgb8888) self.saw_xrgb8888 = true;
            return;
        }
        if (self.handleBufferEvent(id, opcode)) return;
        if (id == wm_base_id and opcode == 0 and payload.len >= 4) {
            try self.sendArgs(wm_base_id, 3, &.{readU32(payload[0..4])});
            return;
        }
        if (id == toplevel_id and opcode == 0) {
            try self.handleToplevelConfigure(payload);
            return;
        }
        if (id == toplevel_id and opcode == 1) {
            self.running = false;
            return;
        }
        if (id == xdg_surface_id and opcode == 0 and payload.len >= 4) {
            try self.sendArgs(xdg_surface_id, 4, &.{readU32(payload[0..4])});
            self.applyPendingSize();
            try self.ensureSessionGrid();
            self.configured = true;
            if (self.mapped) try self.redraw();
            return;
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
                self.destroyBufferObject(buffer.id);
                buffer.deinit();
                self.active_buffer = null;
                return true;
            }
        }

        for (self.retired_buffers.items, 0..) |*buffer, i| {
            if (buffer.id == id) {
                self.destroyBufferObject(buffer.id);
                buffer.deinit();
                _ = self.retired_buffers.orderedRemove(i);
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
            "capabilities compositor={} shm={} xdg_wm_base={} layer_shell={} text_input_v3={} shm_xrgb8888={}",
            .{
                self.caps.compositor.name != 0,
                self.caps.shm.name != 0,
                self.caps.xdg_wm_base.name != 0,
                layer,
                text_input,
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
        var msg = Msg.init(shm_id, 0);
        try msg.putU32(pool_id);
        try msg.putI32(size);
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

        var control: [cmsgSpace(@sizeOf(c_int))]u8 align(@alignOf(usize)) = @splat(0);
        const hdr: *Cmsghdr = @ptrCast(@alignCast(&control));
        hdr.* = .{
            .len = cmsgLen(@sizeOf(c_int)),
            .level = linux.SOL.SOCKET,
            .type = 1, // SCM_RIGHTS
        };
        const fd_ptr: *c_int = @ptrCast(@alignCast(control[cmsgAlign(@sizeOf(Cmsghdr))..].ptr));
        fd_ptr.* = fd;

        const msg = posix.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = iov.len,
            .control = &control,
            .controllen = control.len,
            .flags = 0,
        };
        _ = try posix.sendmsg(stream.handle, &msg, 0);
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
