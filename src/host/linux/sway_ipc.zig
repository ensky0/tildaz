//! #207 — sway global hotkey 자동 등록. hotkey 실동작은 #198 single_instance
//! (`tildaz --toggle`) 경로다. 이 모듈은 그
//! `tildaz --toggle` 을 sway 의 `bindsym` 으로 *자동* 등록한다 — 사용자가 sway
//! config 를 손대지 않아도 `config.hotkey` 값이 system binding 에 반영된다
//! (config = source of truth, KDE `setShortcutKeys` 자동 적용과 동등 정책).
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
const unix_socket = @import("unix_socket.zig");
const checkErr = unix_socket.checkErr;
const Runtime = @import("../../runtime.zig").Runtime;
const log = @import("../../log.zig");
const config_mod = @import("../../config.zig");
const hotkey_format = @import("hotkey_format.zig");
const instance_context = @import("../../instance_context.zig");
const instance_identity = @import("instance_identity.zig");

const native_endian = builtin.target.cpu.arch.endian();

/// i3-ipc message type — RUN_COMMAND. (`bindsym ...` 같은 sway 명령 실행.)
const ipc_run_command: u32 = 0;
const ipc_magic = "i3-ipc";
const ipc_header_len = ipc_magic.len + 8; // magic(6) + len(4) + type(4)

/// boot 진입점 — 현재 세션이 sway 면 toggle hotkey 를 `bindsym` 으로 자동 등록.
/// sway 가 아니거나 (`SWAYSOCK` 없음 + `XDG_CURRENT_DESKTOP` 에 sway 토큰 없음)
/// 등록 실패는 모두 graceful — log 만 남기고 반환한다. single_instance toggle
/// listener 는 그대로 살아 있어 사용자가 수동 등록도 가능.
pub fn registerToggleIfSway(rt: Runtime, allocator: std.mem.Allocator, cfg: *const config_mod.Config) void {
    // sway 판별 — `SWAYSOCK` 존재가 가장 확실 (IPC 가능 == socket 있음).
    // `XDG_CURRENT_DESKTOP` 토큰은 보조 (SWAYSOCK 미설정 환경 hedge).
    //
    // #451 — `posix.getenv` ➡️ `Environ.getPosix`. POSIX 에서는 블록을 그대로 훑어
    // **할당이 없고** 이미 NUL 종단이라, 이 함수가 고정 버퍼만 쓰는 성질이 유지된다.
    const sock_path = rt.environ.getPosix("SWAYSOCK") orelse {
        if (isSwayDesktop(rt)) {
            log.appendLine("sway", "XDG_CURRENT_DESKTOP=sway but SWAYSOCK not set — bindsym auto-register skipped", .{});
        }
        return;
    };

    // 자기 실행 파일 절대 경로 — `exec` command 로 다시 `--toggle` 호출.
    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // #451 — `fs.selfExePath` ➡️ `std.process.executablePath` (길이를 돌려준다).
    const exe_len = std.process.executablePath(rt.io, &exe_buf) catch |err| {
        log.appendLine("sway", "executablePath failed: {s} — bindsym auto-register skipped", .{@errorName(err)});
        return;
    };
    const exe_path = exe_buf[0..exe_len];

    // accel 문자열 (`Shift+Ctrl+Alt+Super+<key>`).
    var accel_buf: [96]u8 = undefined;
    const accel = buildAccel(&accel_buf, cfg.hotkey.keysym, cfg.hotkey.modifiers);

    // sway command — `exec` 인자는 sway 가 sh -c 로 실행하므로 path 를 따옴표로.
    var cmd_buf: [std.Io.Dir.max_path_bytes + 128]u8 = undefined;
    const command = std.fmt.bufPrint(&cmd_buf, "bindsym --no-warn {s} exec \"{s}\" --toggle {d}", .{ accel, exe_path, instance_context.requireWorkerIndex() }) catch {
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

/// 이 세션에서 sway 의 xdg_toplevel + IPC 경로를 쓸 것인가
/// ([#454](https://github.com/ensky0/tildaz/issues/454)).
///
/// 판정은 **`SWAYSOCK` 존재 하나**다. 이 경로는 layer-shell 을 버리는 대신 배치 ·
/// 토글을 전부 i3 IPC 로 하므로, IPC 가 불가능하면 layer-shell 유지가 항상 낫다 —
/// `XDG_CURRENT_DESKTOP` 에 sway 토큰이 있어도 `SWAYSOCK` 이 없으면 배치 없는
/// 기본 창만 남는다. 반대 방향은 걱정할 것이 없다: nested sway 는
/// `XDG_CURRENT_DESKTOP` 이 부모 것 (`KDE`) 이지만 `SWAYSOCK` 은 잡히고 (실측),
/// 실기 sway 세션은 둘 다 잡힌다.
pub fn isSwaySession(rt: Runtime) bool {
    return rt.environ.getPosix("SWAYSOCK") != null;
}

/// #454 — sway 전용 창 규칙을 **창이 뜨기 전에** 등록한다.
///
/// sway 는 layer-shell 의 `on_demand` 에서 map 시 keyboard focus 를 주지 않는다 (spec 이
/// compositor 재량으로 남긴 자리다). 그래서 sway 에서는 layer-shell 을 쓰지 않고
/// (`wayland_minimal.Capabilities.record`) 일반 xdg_toplevel 로 뜬 뒤, layer-shell 이 해 주던
/// 배치를 이 규칙이 대신한다. focus 는 sway 가 일반 창에게 정상적으로 준다.
///
/// **`for_window` 여야 한다.** 창이 map 된 뒤 같은 명령을 보내면 그 뒤의 xdg configure 가
/// 크기를 덮는다 — nested sway 실측에서 `resize` 가 성공 응답을 받고도 적용되지 않았고
/// (640x432 요청 → 1276x666), 한참 뒤 같은 명령을 손으로 보내면 정확히 먹었다.
///
/// **단위는 `ppt`** 다. 화면 크기를 몰라도 되고, sway 가 **workspace 영역** (패널을 뺀
/// 사용 가능 영역) 기준으로 계산해 준다 — 다중 모니터 · 해상도 변경에도 규칙이 그대로다.
pub fn registerWindowRuleIfSway(rt: Runtime, allocator: std.mem.Allocator, cfg: *const config_mod.Config) void {
    const sock_path = rt.environ.getPosix("SWAYSOCK") orelse return;

    var app_id_buf: [32]u8 = undefined;
    const app_id = instance_identity.appId(&app_id_buf, instance_context.requireWorkerIndex()) catch return;

    const w = std.math.clamp(cfg.width_percent, 0.0, 100.0);
    const h = std.math.clamp(cfg.height_percent, 0.0, 100.0);
    // **`move` 는 여기 넣지 않는다.** `for_window` 가 도는 시점에는 창 크기가 아직 확정되지
    // 않아 sway 가 그 뒤에 floating 창을 중앙으로 배치해 버린다 (nested 실측: 규칙에
    // `move position 50 ppt 0 ppt` 를 넣었는데 결과가 정확히 화면 중앙 +320+162 였다).
    // 위치는 창이 뜬 뒤 `moveWindowIfSway` 가 준다 — map 후 `move` 는 정상으로 먹는다.
    //
    // **명령마다 `for_window` 를 따로 쓴다 — 콤마 체인 금지.** 콤마는 i3 문법의 최상위
    // 명령 구분자라, `for_window [x] floating enable, sticky enable, …` 을 sway 는
    // "규칙(floating enable 까지) + 즉시 실행 명령들" 로 파싱한다. 즉 sticky · border ·
    // resize 는 규칙에 안 묶이고 **그 순간 focus 된 무관한 창에 바로 적용**된다 (실기
    // sway 1.12 에서 foot 대조군으로 확정 — 창은 640x420 기본 크기로 뜨고, 떠 있던 다른
    // 창이 리사이즈 + sticky 됐다). 세미콜론으로 이은 독립 규칙 4개는 한 IPC 왕복에
    // 전부 등록되고 전부 적용된다 (같은 실기에서 확인).
    var cmd_buf: [512]u8 = undefined;
    const command = std.fmt.bufPrint(
        &cmd_buf,
        "for_window [app_id=\"{s}\"] floating enable; " ++
            "for_window [app_id=\"{s}\"] sticky enable; " ++
            "for_window [app_id=\"{s}\"] border none; " ++
            "for_window [app_id=\"{s}\"] resize set width {d} ppt height {d} ppt",
        .{ app_id, app_id, app_id, app_id, @round(w), @round(h) },
    ) catch {
        log.appendLine("sway", "for_window command too long — skip", .{});
        return;
    };

    log.appendLineVerbose("sway", "RUN_COMMAND payload=[{s}]", .{command});
    const ok = runCommand(allocator, sock_path, command) catch |err| {
        log.appendLine("sway", "for_window IPC failed: {s} — 창이 기본 위치로 뜬다", .{@errorName(err)});
        return;
    };
    if (ok) {
        log.appendLine("sway", "for_window registered — {s} {d}x{d} ppt", .{ app_id, @round(w), @round(h) });
    } else {
        log.appendLine("sway", "for_window rejected (sway success=false) — app_id={s}", .{app_id});
    }
}

/// #454 — 창이 뜬 뒤 위치를 준다. 크기는 `registerWindowRuleIfSway` 의 `for_window` 가
/// 이미 잡았다 (그쪽 주석에 왜 갈라야 하는지 적혀 있다).
///
/// 단위는 `ppt` 라 화면 크기가 필요 없고, sway 가 workspace 영역 기준으로 계산한다.
pub fn moveWindowIfSway(rt: Runtime, allocator: std.mem.Allocator, cfg: *const config_mod.Config) void {
    if (rt.environ.getPosix("SWAYSOCK") == null) return;

    var app_id_buf: [32]u8 = undefined;
    const app_id = instance_identity.appId(&app_id_buf, instance_context.requireWorkerIndex()) catch return;

    const w = std.math.clamp(cfg.width_percent, 0.0, 100.0);
    const h = std.math.clamp(cfg.height_percent, 0.0, 100.0);
    const off = std.math.clamp(cfg.offset_percent, 0.0, 100.0);
    // 남는 축을 offset 비율로 민다 — layer-shell 의 "anchor 가 잡은 edge 는 margin 0,
    // 반대쪽을 offset 으로" 와 같은 의미를 퍼센트로 옮긴 것이다.
    const cross_x = (100.0 - w) * off / 100.0;
    const cross_y = (100.0 - h) * off / 100.0;
    const pos: struct { x: f32, y: f32 } = switch (cfg.dock_position) {
        .top => .{ .x = cross_x, .y = 0.0 },
        .bottom => .{ .x = cross_x, .y = 100.0 - h },
        .left => .{ .x = 0.0, .y = cross_y },
        .right => .{ .x = 100.0 - w, .y = cross_y },
    };

    var cmd_buf: [128]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "move position {d} ppt {d} ppt", .{ @round(pos.x), @round(pos.y) }) catch return;
    const ok = runForAppId(rt, allocator, app_id, cmd);
    log.appendLine("sway", "move {s} — {s} to ({d},{d}) ppt", .{ if (ok) "ok" else "rejected", app_id, @round(pos.x), @round(pos.y) });
}

/// #454 — sway 의 "패널 회피" 전체화면 (Shift+Alt+Enter, `FullscreenMode.avoid`).
///
/// xdg fallback 의 avoid 는 `xdg_toplevel.set_maximized` 인데 **sway 는 floating 창의
/// maximize 요청을 무시한다** (실기 sway 1.12 — 요청 후 rect 무변화). 대신 IPC 로
/// workspace 영역을 채운다: `resize set 100 ppt` + `move position 0 0 ppt`. sway 의
/// workspace rect 는 패널 (exclusive zone) 을 뺀 영역이라 layer-shell avoid
/// (`exclusive_zone=0`, 4-edge anchor) 와 의미가 정확히 같다.
///
/// 해제와 scratchpad 복귀 시 재적용은 `restoreDockLayoutIfSway` / 호출처가 맡는다.
pub fn applyAvoidLayoutIfSway(rt: Runtime, allocator: std.mem.Allocator) bool {
    var app_id_buf: [32]u8 = undefined;
    const app_id = instance_identity.appId(&app_id_buf, instance_context.requireWorkerIndex()) catch return false;
    const resized = runForAppId(rt, allocator, app_id, "resize set width 100 ppt height 100 ppt");
    const moved = runForAppId(rt, allocator, app_id, "move position 0 ppt 0 ppt");
    const ok = resized and moved;
    log.appendLine("sway", "fullscreen avoid layout {s} — {s}", .{ if (ok) "ok" else "rejected", app_id });
    return ok;
}

/// #454 — avoid 전체화면 해제: config 의 dock 크기 · 위치로 되돌린다.
///
/// map 후 `resize set` 은 실기에서 정확히 적용된다 (map **전** for_window 가 필요한
/// 것은 최초 배치뿐 — `registerWindowRuleIfSway` 주석). 위치는 `moveWindowIfSway` 재사용.
pub fn restoreDockLayoutIfSway(rt: Runtime, allocator: std.mem.Allocator, cfg: *const config_mod.Config) void {
    var app_id_buf: [32]u8 = undefined;
    const app_id = instance_identity.appId(&app_id_buf, instance_context.requireWorkerIndex()) catch return;
    const w = std.math.clamp(cfg.width_percent, 0.0, 100.0);
    const h = std.math.clamp(cfg.height_percent, 0.0, 100.0);
    var cmd_buf: [96]u8 = undefined;
    const cmd = std.fmt.bufPrint(
        &cmd_buf,
        "resize set width {d} ppt height {d} ppt",
        .{ @round(w), @round(h) },
    ) catch return;
    _ = runForAppId(rt, allocator, app_id, cmd);
    moveWindowIfSway(rt, allocator, cfg);
}

/// #454 — cover 전체화면 재적용. **`scratchpad show` 보다 먼저** 보내야 한다.
///
/// sway 1.12 실기로 세 구조를 가른 결과다:
/// - show **후** xdg `set_fullscreen` 재전송 — 상태만 서고 크기 configure 유실
///   (트리 `fullscreen_mode=1` 인데 rect 는 이전 크기 `960x1055+0+0`).
/// - show **후** IPC `fullscreen enable` — 같은 증상. 채널이 아니라 un-scratchpad
///   전환 트랜잭션과 겹치는 것 자체가 문제다.
/// - scratchpad **안에서** `fullscreen enable` → 그 뒤 `scratchpad show` — 상태가
///   먼저 서 있어서 **맵 configure 자체가 전체화면 크기**로 온다
///   (`terminal resized cols=210 rows=56` 즉시 수신). ✅ 이 순서만 성립한다.
///
/// 해제는 평소 경로 (xdg `unset_fullscreen`) 그대로다 — fullscreen 상태는 단일해서
/// 어느 쪽으로 세웠든 xdg 해제가 먹는다 (실기 확인).
pub fn fullscreenEnableIfSway(rt: Runtime, allocator: std.mem.Allocator) bool {
    var app_id_buf: [32]u8 = undefined;
    const app_id = instance_identity.appId(&app_id_buf, instance_context.requireWorkerIndex()) catch return false;
    const ok = runForAppId(rt, allocator, app_id, "fullscreen enable");
    log.appendLine("sway", "fullscreen reapply {s} — {s}", .{ if (ok) "ok" else "rejected", app_id });
    return ok;
}

/// #454 — sway 에서 드롭다운을 숨긴다. **surface 를 destroy 하지 않는다.**
///
/// 앱의 기본 hide 는 surface destroy 이고 다음 show 에서 다시 만든다. layer-shell 에서는
/// 그 왕복이 성립하지만 **xdg_toplevel 경로에서는 창이 돌아오지 않는다** (실측: `--toggle`
/// 두 번에 창이 sway 트리에서 사라진 채 남았고 scratchpad 에도 없었다). GNOME · Cinnamon 은
/// extension 이 `minimize` / `show` 로 처리해 이 문제가 없는데 sway 에는 그 주체가 없다.
///
/// 그래서 sway 에서는 **scratchpad** 를 쓴다 — surface 는 살아 있고 sway 가 보관한다.
/// i3-quickterm 등 sway 네이티브 드롭다운이 쓰는 방식이다.
pub fn hideToScratchpad(rt: Runtime, allocator: std.mem.Allocator) bool {
    var app_id_buf: [32]u8 = undefined;
    const app_id = instance_identity.appId(&app_id_buf, instance_context.requireWorkerIndex()) catch return false;
    const ok = runForAppId(rt, allocator, app_id, "move scratchpad");
    log.appendLineVerbose("sway", "hide → scratchpad {s} — {s}", .{ if (ok) "ok" else "rejected", app_id });
    return ok;
}

/// #454 — scratchpad 에서 꺼내 다시 배치한다.
///
/// **꺼낸 뒤 위치를 다시 준다** (`reposition=true`). scratchpad 에서 나온 창은 sway 가
/// 중앙에 놓기 때문이다 (`registerWindowRuleIfSway` 의 `move` 를 for_window 에 넣지
/// 못하는 것과 같은 성질). 크기는 `for_window` 규칙이 계속 잡고 있어 다시 줄 필요가 없다.
///
/// **cover 전체화면 복귀는 `reposition=false`** — 위치가 fullscreen origin 인데 `move`
/// 를 보내면 전체화면 컨테이너 자체가 dock 위치로 밀려난다 (실기: rect 가
/// `1920x1080+960+25` 로 화면 밖까지 밀림). unfullscreen 시 floating 저장 위치는
/// move 와 무관하게 유지된다 (실기 확인).
///
/// **focus 는 sway 가 준다** — 이 이슈 (#454) 의 본체가 여기서 풀린다. layer-shell 의
/// `on_demand` 와 달리 scratchpad 는 사용자가 부른 일반 창이라 sway 가 focus 를 넘긴다.
pub fn showFromScratchpad(rt: Runtime, allocator: std.mem.Allocator, cfg: *const config_mod.Config, reposition: bool) bool {
    var app_id_buf: [32]u8 = undefined;
    const app_id = instance_identity.appId(&app_id_buf, instance_context.requireWorkerIndex()) catch return false;
    const shown = runForAppId(rt, allocator, app_id, "scratchpad show");
    if (reposition) moveWindowIfSway(rt, allocator, cfg);
    log.appendLineVerbose("sway", "show ← scratchpad {s} — {s}", .{ if (shown) "ok" else "rejected", app_id });
    return shown;
}

/// 창 하나를 지목해 sway 명령을 보낸다 (`[app_id="…"] <command>`).
///
/// `SWAYSOCK` 이 없거나 IPC 가 실패하면 **조용히 false** 다 — 배치가 안 되어도 창은
/// 이미 떠 있고, 여기서 죽으면 sway 사용자가 터미널 자체를 못 쓴다.
pub fn runForAppId(rt: Runtime, allocator: std.mem.Allocator, app_id: []const u8, command: []const u8) bool {
    const sock_path = rt.environ.getPosix("SWAYSOCK") orelse return false;
    var buf: [512]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "[app_id=\"{s}\"] {s}", .{ app_id, command }) catch {
        log.appendLine("sway", "command too long — skipped: {s}", .{command});
        return false;
    };
    log.appendLineVerbose("sway", "RUN_COMMAND payload=[{s}]", .{full});
    return runCommand(allocator, sock_path, full) catch |err| {
        log.appendLine("sway", "IPC failed: {s} — command skipped: {s}", .{ @errorName(err), command });
        return false;
    };
}

/// `XDG_CURRENT_DESKTOP` (콜론 구분 다중 토큰) 에 sway 토큰 포함 여부.
fn isSwayDesktop(rt: Runtime) bool {
    const de = rt.environ.getPosix("XDG_CURRENT_DESKTOP") orelse return false;
    var it = std.mem.tokenizeScalar(u8, de, ':');
    while (it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(tok, "sway")) return true;
    }
    return false;
}

/// `config.hotkey` → sway accel 문자열. modifier prefix 는 sway 가 수용하는
/// 친화 이름 (`Shift` / `Ctrl` / `Alt` / `Super`), key 이름은 공통 `hotkey_format.gtkName`
/// 재사용 (XKB keysym name — sway bindsym 과 1:1, nested 시연 확인).
fn buildAccel(buf: []u8, keysym: u32, modifiers: u32) []const u8 {
    const H = config_mod.Hotkey;
    var fbs: std.Io.Writer = .fixed(buf);
    const w = &fbs;
    if ((modifiers & H.MOD_SHIFT) != 0) w.writeAll("Shift+") catch {};
    if ((modifiers & H.MOD_CTRL) != 0) w.writeAll("Ctrl+") catch {};
    if ((modifiers & H.MOD_ALT) != 0) w.writeAll("Alt+") catch {};
    if ((modifiers & H.MOD_SUPER) != 0) w.writeAll("Super+") catch {};
    w.writeAll(hotkey_format.gtkName(keysym)) catch {};
    return fbs.buffered();
}

/// `$SWAYSOCK` 에 i3-ipc RUN_COMMAND 송신 후 응답의 `"success":true` 여부 반환.
/// connect / write / read 실패는 error. sway 가 command 를 거부하면 (false 반환)
/// IPC 자체는 성공이므로 `false` 를 반환 (error 아님).
fn runCommand(allocator: std.mem.Allocator, sock_path: []const u8, command: []const u8) !bool {
    // #451 — `posix.socket` · `posix.connect` · `std.net.Address.initUnix` 가 모두 없어졌다.
    // `unix_socket.zig` 이 그 자리이고 `single_instance` · `wayland_minimal` 과 같은 배관이다.
    const fd = try unix_socket.openSocket(posix.SOCK.CLOEXEC);
    defer unix_socket.closeFd(fd);
    try unix_socket.connect(fd, sock_path);

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
    //
    // 세미콜론으로 이은 다중 명령은 결과가 명령 수만큼 배열로 온다. "true 가 하나라도
    // 있으면 성공" 으로 두면 부분 실패 (예: 규칙 4개 중 1개만 등록) 를 성공으로 읽으므로,
    // **false 가 하나라도 있으면 실패**로 판정한다.
    const any_true = std.mem.find(u8, payload, "\"success\": true") != null or
        std.mem.find(u8, payload, "\"success\":true") != null;
    const any_false = std.mem.find(u8, payload, "\"success\": false") != null or
        std.mem.find(u8, payload, "\"success\":false") != null;
    const ok = any_true and !any_false;
    if (!ok) log.appendLineVerbose("sway", "RUN_COMMAND resp(success=false)=[{s}]", .{payload});
    return ok;
}

const writeAll = unix_socket.writeAll;

fn readAll(fd: posix.fd_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = posix.system.read(fd, buf.ptr + off, buf.len - off);
        if (checkErr(rc)) |e| switch (e) {
            // 시그널에 끊긴 것은 실패가 아니다 — 이어서 다시 읽는다.
            .INTR => continue,
            else => return error.SwayIpcReadFailed,
        };
        const n: usize = @intCast(rc);
        if (n == 0) return error.SwayIpcEof;
        off += n;
    }
}
