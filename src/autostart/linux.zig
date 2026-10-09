// Linux auto-start: `$XDG_CONFIG_HOME/autostart/tildaz.desktop`
// (unset/empty/relative fallback: `~/.config/autostart/tildaz.desktop`)
//
// XDG Autostart Specification 의 desktop entry. 사용자 로그인 후 세션이 시작될
// 때 desktop environment (GNOME / KDE / Cinnamon / XFCE 등) 가 이 경로의
// `.desktop` 파일을 읽어 `Exec=...` 의 실행을 트리거.
//
// Windows `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` (`autostart/windows.zig`)
// 와 macOS `~/Library/LaunchAgents/com.tildaz.app.plist` (`autostart/macos.zig`)
// 와 동등 — 같은 wrapper API (`enable(allocator)` / `disable(allocator)`).
//
// `Exec` 의 path 는 `selfExePath` 로 실행 중 binary 의 절대 경로 — `~/.local/bin`,
// distro packaging (`/usr/bin/tildaz`), 또는 git clone 한 위치의 `zig-out/bin/tildaz`
// 어느 install 패턴이든 정확히 그 위치를 가리킴. macOS 패턴 (`currentExePath`)
// 동등.
//
// 같은 내용이면 file 안 건드림 (timestamp 보존) — macOS 패턴 동등.
//
// #700 — **데스크톱 설정 화면에서 끈 것을 되살리지 않는다.** 예전에는 실행할 때마다 이 파일을
// 통째로 다시 써서, 사용자가 끈 표시가 사라졌다. 끄는 모양은 데스크톱마다 다르다.
//   - KDE Plasma 6.7 — `Hidden=true` 를 쓴다. 켜면 그 줄을 지운다
//     (plasma-workspace `kcms/autostart/autostartmodel.cpp`).
//   - Cinnamon 6.6 — `X-GNOME-Autostart-enabled=false` 를 쓴다 (`cs_startup.py`).
//   - COSMIC 1.9 — 파일을 지운다 (cosmic-settings `pages/applications/startup_apps.rs`).
// 앞의 둘은 그 표시가 있으면 파일을 건드리지 않는다. 지운 경우는 "만든 적이 있는데 없다" 로
// 알아본다 — 만들 때 상태 폴더에 표시 파일 (`autostart-created`) 을 남긴다. config 의
// `auto_start` 를 모두 끄면 (`disable`) 파일과 표시를 함께 지우므로, 다시 켜면 새로 만든다.
// Windows · macOS 는 해당이 없다 — 끈 사실이 우리가 쓰는 자리와 다른 곳에 저장된다
// (Windows `StartupApproved` 키 · macOS 백그라운드 항목 관리).

const std = @import("std");
const app_id = @import("../app_id.zig");
const paths = @import("../paths.zig");
const exe_path = @import("../exe_path.zig");
const log = @import("../log.zig");
const Runtime = @import("../runtime.zig").Runtime;

/// `$XDG_CONFIG_HOME/autostart/` 는 공용 디렉터리라 이름으로 가른다 (#654).
const ENTRY_NAME = app_id.name ++ ".desktop";

/// XDG user autostart 경로. config base와 같은 `paths.configHome`을 사용해
/// 본체 config와 autostart가 서로 다른 XDG 해석을 갖지 않게 한다.
fn entryPath(rt: Runtime, allocator: std.mem.Allocator) ![]u8 {
    const config_home = try paths.configHome(rt, allocator);
    defer allocator.free(config_home);
    const dir = try std.fmt.allocPrint(allocator, "{s}/autostart", .{config_home});
    defer allocator.free(dir);
    paths.ensureDir(rt, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, ENTRY_NAME });
}

/// XDG 지원 전 버전이 항상 쓴 기본 위치. custom XDG_CONFIG_HOME을 쓰는 경우
/// 이 generated entry를 남기면 두 autostart directory에서 중복 실행된다.
fn legacyEntryPath(rt: Runtime, allocator: std.mem.Allocator) ![]u8 {
    const home = try rt.envAlloc(allocator, "HOME");
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.config/autostart/{s}", .{ home, ENTRY_NAME });
}

fn removeLegacyEntryIfDifferent(rt: Runtime, allocator: std.mem.Allocator, current_path: []const u8) void {
    const legacy_path = legacyEntryPath(rt, allocator) catch return;
    defer allocator.free(legacy_path);
    if (!std.mem.eql(u8, current_path, legacy_path)) {
        std.Io.Dir.deleteFileAbsolute(rt.io, legacy_path) catch {};
    }
}

/// 현재 실행 중 binary 의 절대 경로. macOS `currentExePath` 동등. AppImage 면 임시 마운트
/// 경로가 아니라 그 파일의 경로다 (#706 — `exe_path.persistent`).
fn currentExePath(rt: Runtime, allocator: std.mem.Allocator) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return allocator.dupe(u8, try exe_path.persistent(rt, &buf));
}

const created_marker = "autostart-created";

fn createdMarkerPath(rt: Runtime, allocator: std.mem.Allocator) ![]u8 {
    const dir = try paths.stateDir(rt, allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, created_marker });
}

fn fileExists(rt: Runtime, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(rt.io, path, .{}) catch return false;
    return true;
}

fn readEntry(rt: Runtime, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(rt.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(rt.io);
    var reader = file.reader(rt.io, &.{});
    return try reader.interface.allocRemaining(allocator, .limited(64 * 1024));
}

/// 데스크톱 설정 화면이 이 항목을 껐는가 — `[Desktop Entry]` 그룹의 `Hidden=true` (KDE) 나
/// `X-GNOME-Autostart-enabled=false` (Cinnamon). 다른 그룹 (`[Desktop Action …]`) 은 보지 않는다.
fn userDisabled(text: []const u8) bool {
    var in_entry = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] == '[') {
            in_entry = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_entry) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "Hidden") and std.ascii.eqlIgnoreCase(value, "true")) return true;
        if (std.mem.eql(u8, key, "X-GNOME-Autostart-enabled") and std.ascii.eqlIgnoreCase(value, "false")) return true;
    }
    return false;
}

/// auto-start 활성화 — XDG autostart desktop entry 작성. 이미 같은 내용이면
/// 건드리지 않음 (timestamp 보존). 사용자가 데스크톱 설정에서 껐으면 그대로 둔다 (#700).
pub fn enable(rt: Runtime, allocator: std.mem.Allocator) !void {
    const exe = try currentExePath(rt, allocator);
    defer allocator.free(exe);

    // XDG Desktop Entry `Exec` 는 공백 포함 경로를 그대로 두면 인자 경계가 깨진다.
    // `instance_identity.ensureDesktopEntry` 와 같은 규칙 — 경로를 큰따옴표로 감싸
    // 공백을 보호하고, quoting 을 깨는 개행 / 큰따옴표가 든 경로는 거부한다.
    if (std.mem.findAny(u8, exe, "\n\r\"") != null) return error.UnsupportedExecutablePath;

    const path = try entryPath(rt, allocator);
    defer allocator.free(path);
    const marker = try createdMarkerPath(rt, allocator);
    defer allocator.free(marker);

    if (try readEntry(rt, allocator, path)) |existing| {
        defer allocator.free(existing);
        if (userDisabled(existing)) {
            log.appendLine("autostart", "left off — it is turned off in the desktop's startup settings ({s})", .{path});
            removeLegacyEntryIfDifferent(rt, allocator, path);
            return;
        }
    } else if (fileExists(rt, marker)) {
        log.appendLine("autostart", "not recreated — the startup entry was removed in the desktop's settings ({s})", .{path});
        removeLegacyEntryIfDifferent(rt, allocator, path);
        return;
    }

    // `StartupWMClass=<name>` 은 launcher identity다. Worker 창은 번호별
    // `<name>.instanceN`을 사용하므로 launcher와 실행 중 앱으로 묶이지 않는다.
    //
    // **`Name` · `Icon` · `StartupWMClass` 도 `app_id` 를 탄다** (#654) — 파일 이름만
    // 가르면 자동 시작 목록에 개발 빌드와 릴리즈가 *같은 이름*으로 나란히 보여서,
    // 이 이슈가 없애려던 "어느 쪽이 도는지 알 수 없다" 가 그 화면에 그대로 남는다.
    // launcher 자신은 창을 만들지 않고 worker를 spawn/request한 뒤 종료하므로
    // StartupNotify=false로 시작 완료 창을 기다리지 않게 한다.
    //
    // `Hidden=false` + `X-GNOME-Autostart-enabled=true` 는 GNOME / Cinnamon /
    // KDE 모두에서 항목 활성으로 인식되는 표준 조합.
    //
    // `NotShowIn=GNOME;` — GNOME 은 tildaz Shell extension 이 launch lifecycle 을
    // 담당하므로(mutter 엔 wlr-layer-shell 이 없어 placement 가 셸 안에서만 가능)
    // gnome-session 의 XDG autostart 로는 *띄우지 않는다*. 이 키 하나로 GNOME 만
    // 이 항목을 건너뛰고(extension 이 대신 launch), KDE/Cinnamon/COSMIC 등은 그대로
    // honor 한다. 이 파일은 전 DE 가 공유하므로(XDG user autostart), 예전처럼
    // GNOME 진입 시 파일을 삭제하면 GNOME 을 거친 뒤 KDE/Cinnamon autostart 가
    // 통째로 깨졌다 — NotShowIn 으로 파일을 지우지 않고 DE 왕복에도 살아남게 한다.
    const entry = try std.fmt.allocPrint(allocator,
        \\[Desktop Entry]
        \\Type=Application
        \\Name={s}
        \\GenericName=Drop-down Terminal
        \\Comment=Quake-style drop-down terminal for Wayland
        \\Exec="{s}" --autostart
        \\Icon={s}
        \\Terminal=false
        \\Categories=System;TerminalEmulator;
        \\StartupWMClass={s}
        \\StartupNotify=false
        \\Hidden=false
        \\X-GNOME-Autostart-enabled=true
        \\NotShowIn=GNOME;
        \\
    , .{ app_id.display_name, exe, app_id.name, app_id.name });
    defer allocator.free(entry);

    _ = try paths.writeFileIfChanged(rt, allocator, path, entry);
    removeLegacyEntryIfDifferent(rt, allocator, path);
    if (std.Io.Dir.path.dirname(marker)) |dir| try paths.ensureDir(rt, dir);
    _ = try paths.writeFileIfChanged(rt, allocator, marker, "");
}

/// auto-start 비활성화 — desktop entry 파일 삭제. 다음 로그인부터 효과.
pub fn disable(rt: Runtime, allocator: std.mem.Allocator) void {
    const path = entryPath(rt, allocator) catch return;
    defer allocator.free(path);
    std.Io.Dir.deleteFileAbsolute(rt.io, path) catch {};
    removeLegacyEntryIfDifferent(rt, allocator, path);
    // config 로 끈 것이므로 "사용자가 데스크톱에서 지웠다" 는 기억도 지운다 — 다시 켜면 만든다.
    const marker = createdMarkerPath(rt, allocator) catch return;
    defer allocator.free(marker);
    std.Io.Dir.deleteFileAbsolute(rt.io, marker) catch {};
}

test "#700 the startup entry counts as turned off the way each desktop writes it" {
    const ours =
        \\[Desktop Entry]
        \\Type=Application
        \\Exec="/usr/bin/tildaz" --autostart
        \\Hidden=false
        \\X-GNOME-Autostart-enabled=true
        \\
    ;
    try std.testing.expect(!userDisabled(ours));
    // KDE Plasma — `Hidden=true` 로 바꿔 쓴다.
    try std.testing.expect(userDisabled("[Desktop Entry]\nType=Application\nHidden=true\n"));
    // Cinnamon — GLib 키 파일이라 `=` 앞뒤에 공백이 없다. 있어도 받는다.
    try std.testing.expect(userDisabled("[Desktop Entry]\nX-GNOME-Autostart-enabled=false\n"));
    try std.testing.expect(userDisabled("[Desktop Entry]\r\nX-GNOME-Autostart-enabled = false\r\n"));
    // 다른 그룹의 같은 키는 항목의 상태가 아니다.
    try std.testing.expect(!userDisabled("[Desktop Entry]\nName=TildaZ\n[Desktop Action new]\nHidden=true\n"));
    try std.testing.expect(!userDisabled(""));
}
