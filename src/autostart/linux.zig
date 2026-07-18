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

const std = @import("std");
const paths = @import("../paths.zig");

const ENTRY_NAME = "tildaz.desktop";

/// XDG user autostart 경로. config base와 같은 `paths.configHome`을 사용해
/// 본체 config와 autostart가 서로 다른 XDG 해석을 갖지 않게 한다.
fn entryPath(allocator: std.mem.Allocator) ![]u8 {
    const config_home = try paths.configHome(allocator);
    defer allocator.free(config_home);
    const dir = try std.fmt.allocPrint(allocator, "{s}/autostart", .{config_home});
    defer allocator.free(dir);
    paths.ensureDir(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, ENTRY_NAME });
}

/// XDG 지원 전 버전이 항상 쓴 기본 위치. custom XDG_CONFIG_HOME을 쓰는 경우
/// 이 generated entry를 남기면 두 autostart directory에서 중복 실행된다.
fn legacyEntryPath(allocator: std.mem.Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.config/autostart/{s}", .{ home, ENTRY_NAME });
}

fn removeLegacyEntryIfDifferent(allocator: std.mem.Allocator, current_path: []const u8) void {
    const legacy_path = legacyEntryPath(allocator) catch return;
    defer allocator.free(legacy_path);
    if (!std.mem.eql(u8, current_path, legacy_path)) {
        std.fs.deleteFileAbsolute(legacy_path) catch {};
    }
}

/// 현재 실행 중 binary 의 절대 경로. macOS `currentExePath` 동등.
fn currentExePath(allocator: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const slice = try std.fs.selfExePath(&buf);
    return allocator.dupe(u8, slice);
}

/// auto-start 활성화 — XDG autostart desktop entry 작성. 이미 같은 내용이면
/// 건드리지 않음 (timestamp 보존).
pub fn enable(allocator: std.mem.Allocator) !void {
    const exe = try currentExePath(allocator);
    defer allocator.free(exe);

    // XDG Desktop Entry `Exec` 는 공백 포함 경로를 그대로 두면 인자 경계가 깨진다.
    // `instance_identity.ensureDesktopEntry` 와 같은 규칙 — 경로를 큰따옴표로 감싸
    // 공백을 보호하고, quoting 을 깨는 개행 / 큰따옴표가 든 경로는 거부한다.
    if (std.mem.indexOfAny(u8, exe, "\n\r\"") != null) return error.UnsupportedExecutablePath;

    const path = try entryPath(allocator);
    defer allocator.free(path);

    // `StartupWMClass=tildaz` 는 launcher identity다. Worker 창은 번호별
    // `tildaz.instanceN`을 사용하므로 launcher와 실행 중 앱으로 묶이지 않는다.
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
        \\Name=TildaZ
        \\GenericName=Drop-down Terminal
        \\Comment=Quake-style drop-down terminal for Wayland
        \\Exec="{s}" --autostart
        \\Icon=tildaz
        \\Terminal=false
        \\Categories=System;TerminalEmulator;
        \\StartupWMClass=tildaz
        \\StartupNotify=false
        \\Hidden=false
        \\X-GNOME-Autostart-enabled=true
        \\NotShowIn=GNOME;
        \\
    , .{exe});
    defer allocator.free(entry);

    _ = try paths.writeFileIfChanged(allocator, path, entry);
    removeLegacyEntryIfDifferent(allocator, path);
}

/// auto-start 비활성화 — desktop entry 파일 삭제. 다음 로그인부터 효과.
pub fn disable(allocator: std.mem.Allocator) void {
    const path = entryPath(allocator) catch return;
    defer allocator.free(path);
    std.fs.deleteFileAbsolute(path) catch {};
    removeLegacyEntryIfDifferent(allocator, path);
}
