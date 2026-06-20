//! #207 — sway global hotkey 자동 등록. sway (wlroots) 는 XDG `GlobalShortcuts`
//! portal 을 지원하지 않으므로 (xdg-desktop-portal-wlr 미구현), tildaz 의 hotkey
//! 실동작은 #198 single_instance (`tildaz --toggle`) 경로다. 이 모듈은 그
//! `tildaz --toggle` 을 sway 의 `bindsym` 으로 *자동* 등록한다 — 사용자가 sway
//! config 를 손대지 않아도 `config.hotkey` 값이 system binding 에 반영된다
//! (config = source of truth, KDE `setForeignShortcut` 자동 적용과 동등 정책).
//!
//! IPC 는 sway 의 i3-ipc protocol. `$SWAYSOCK` 의 AF_UNIX socket 에 RUN_COMMAND
//! 메시지를 직접 송신한다 — magic `"i3-ipc"` + payload_len (u32 native endian) +
//! message_type (u32 native endian) + payload. `swaymsg` subprocess 가 아니라
//! 직접 socket 으로 (dbus 와 같은 의존-최소 원칙).
//!
//! `bindsym` 은 runtime-only — sway reload / 재시작 시 사라진다 (KDE
//! `setForeignShortcut` 의 runtime cache 와 같은 성격). 그래서 tildaz 매 실행마다
//! 등록한다 → config 변경 시 다음 실행에 자동 반영.
//!
//! 검증: nested sway 1.12 (KDE Wayland 안) 에서 RUN_COMMAND `bindsym` 응답
//! `[{"success":true}]` 확인, key/modifier 호환 (`F1` / `Mod4+a` /
//! `Control+Shift+t` / `Alt+a` / `Super+a` 모두 수용). 상세 — issue #207 코멘트.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const log = @import("../../log.zig");
const config_mod = @import("../../config.zig");
const portal = @import("portal.zig");

const native_endian = builtin.target.cpu.arch.endian();

/// i3-ipc message type — RUN_COMMAND. (`bindsym ...` 같은 sway 명령 실행.)
const ipc_run_command: u32 = 0;
const ipc_magic = "i3-ipc";
const ipc_header_len = ipc_magic.len + 8; // magic(6) + len(4) + type(4)

/// boot 진입점 — 현재 세션이 sway 면 toggle hotkey 를 `bindsym` 으로 자동 등록.
/// sway 가 아니거나 (`SWAYSOCK` 없음 + `XDG_CURRENT_DESKTOP` 에 sway 토큰 없음)
/// 등록 실패는 모두 graceful — log 만 남기고 반환한다. single_instance toggle
/// listener 는 그대로 살아 있어 사용자가 수동 등록도 가능.
pub fn registerToggleIfSway(allocator: std.mem.Allocator, cfg: *const config_mod.Config) void {
    // sway 판별 — `SWAYSOCK` 존재가 가장 확실 (IPC 가능 == socket 있음).
    // `XDG_CURRENT_DESKTOP` 토큰은 보조 (SWAYSOCK 미설정 환경 hedge).
    const sock_path = posix.getenv("SWAYSOCK") orelse {
        if (isSwayDesktop()) {
            log.appendLine("sway", "XDG_CURRENT_DESKTOP=sway but SWAYSOCK not set — bindsym auto-register skipped", .{});
        }
        return;
    };

    // 자기 실행 파일 절대 경로 — `exec` command 로 다시 `--toggle` 호출.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_buf) catch |err| {
        log.appendLine("sway", "selfExePath failed: {s} — bindsym auto-register skipped", .{@errorName(err)});
        return;
    };

    // accel 문자열 (`Shift+Ctrl+Alt+Super+<key>`).
    var accel_buf: [96]u8 = undefined;
    const accel = buildAccel(&accel_buf, cfg.hotkey.keysym, cfg.hotkey.modifiers);

    // sway command — `exec` 인자는 sway 가 sh -c 로 실행하므로 path 를 따옴표로.
    var cmd_buf: [std.fs.max_path_bytes + 128]u8 = undefined;
    const command = std.fmt.bufPrint(&cmd_buf, "bindsym {s} exec \"{s}\" --toggle", .{ accel, exe_path }) catch {
        log.appendLine("sway", "bindsym command too long — skip", .{});
        return;
    };

    log.appendLineVerbose("sway", "RUN_COMMAND payload=[{s}] (sock={s})", .{ command, sock_path });
    const ok = runCommand(allocator, sock_path, command) catch |err| {
        log.appendLine("sway", "bindsym IPC failed: {s} — single_instance toggle retained (user can register manually)", .{@errorName(err)});
        return;
    };
    if (ok) {
        log.appendLine("sway", "bindsym auto-registered OK — {s} → tildaz --toggle (runtime, refreshed each launch)", .{accel});
    } else {
        log.appendLine("sway", "bindsym auto-register rejected (sway success=false) — accel={s}", .{accel});
    }
}

/// `XDG_CURRENT_DESKTOP` (콜론 구분 다중 토큰) 에 sway 토큰 포함 여부.
fn isSwayDesktop() bool {
    const de = posix.getenv("XDG_CURRENT_DESKTOP") orelse return false;
    var it = std.mem.tokenizeScalar(u8, de, ':');
    while (it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(tok, "sway")) return true;
    }
    return false;
}

/// `config.hotkey` → sway accel 문자열. modifier prefix 는 sway 가 수용하는
/// 친화 이름 (`Shift` / `Ctrl` / `Alt` / `Super`), key 이름은 `portal.keysymGtkName`
/// 재사용 (XKB keysym name — sway bindsym 과 1:1, nested 시연 확인).
fn buildAccel(buf: []u8, keysym: u32, modifiers: u32) []const u8 {
    const H = config_mod.Hotkey;
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    if ((modifiers & H.MOD_SHIFT) != 0) w.writeAll("Shift+") catch {};
    if ((modifiers & H.MOD_CTRL) != 0) w.writeAll("Ctrl+") catch {};
    if ((modifiers & H.MOD_ALT) != 0) w.writeAll("Alt+") catch {};
    if ((modifiers & H.MOD_SUPER) != 0) w.writeAll("Super+") catch {};
    w.writeAll(portal.keysymGtkName(keysym)) catch {};
    return fbs.getWritten();
}

/// `$SWAYSOCK` 에 i3-ipc RUN_COMMAND 송신 후 응답의 `"success":true` 여부 반환.
/// connect / write / read 실패는 error. sway 가 command 를 거부하면 (false 반환)
/// IPC 자체는 성공이므로 `false` 를 반환 (error 아님).
fn runCommand(allocator: std.mem.Allocator, sock_path: []const u8, command: []const u8) !bool {
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(fd);

    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    if (sock_path.len + 1 > addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..sock_path.len], sock_path);
    addr.path[sock_path.len] = 0;
    const addrlen: posix.socklen_t = @intCast(@sizeOf(@TypeOf(addr.family)) + sock_path.len + 1);
    try posix.connect(fd, @ptrCast(&addr), addrlen);

    // request — header(magic + len + type) + payload 한 번에.
    var req = try allocator.alloc(u8, ipc_header_len + command.len);
    defer allocator.free(req);
    @memcpy(req[0..ipc_magic.len], ipc_magic);
    std.mem.writeInt(u32, req[ipc_magic.len..][0..4], @intCast(command.len), native_endian);
    std.mem.writeInt(u32, req[ipc_magic.len + 4 ..][0..4], ipc_run_command, native_endian);
    @memcpy(req[ipc_header_len..], command);
    try writeAll(fd, req);

    // response header.
    var hdr: [ipc_header_len]u8 = undefined;
    try readAll(fd, &hdr);
    if (!std.mem.eql(u8, hdr[0..ipc_magic.len], ipc_magic)) return error.SwayIpcBadMagic;
    const payload_len = std.mem.readInt(u32, hdr[ipc_magic.len..][0..4], native_endian);

    // response payload — RUN_COMMAND 결과 JSON 배열. 작으니 그대로 읽어
    // `"success":true` 부분 문자열로 판정 (dbus 응답 처리와 같은 방식).
    if (payload_len == 0 or payload_len > 64 * 1024) return error.SwayIpcBadLength;
    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);
    try readAll(fd, payload);
    // sway 의 wire 형식은 `[ { "success": true } ]` — 콜론 뒤 공백 포함 (swaymsg
    // CLI 의 compact 표시와 다름, nested 시연 확인). 공백 유무 둘 다 수용.
    const ok = std.mem.indexOf(u8, payload, "\"success\": true") != null or
        std.mem.indexOf(u8, payload, "\"success\":true") != null;
    if (!ok) log.appendLineVerbose("sway", "RUN_COMMAND resp(success=false)=[{s}]", .{payload});
    return ok;
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        off += try posix.write(fd, bytes[off..]);
    }
}

fn readAll(fd: posix.fd_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try posix.read(fd, buf[off..]);
        if (n == 0) return error.SwayIpcEof;
        off += n;
    }
}
