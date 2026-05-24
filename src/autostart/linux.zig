// Linux auto-start: `~/.config/autostart/tildaz.desktop`
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

const ENTRY_NAME = "tildaz.desktop";

/// `~/.config/autostart/tildaz.desktop` 경로. 부모 디렉토리 (`~/.config/autostart`)
/// 가 없으면 자동 생성.
fn entryPath(allocator: std.mem.Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    const dir = try std.fmt.allocPrint(allocator, "{s}/.config/autostart", .{home});
    defer allocator.free(dir);
    ensureDir(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, ENTRY_NAME });
}

fn ensureDir(dir: []const u8) !void {
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            if (std.fs.path.dirname(dir)) |parent| {
                try ensureDir(parent);
                try std.fs.makeDirAbsolute(dir);
                return;
            }
            return err;
        },
        else => return err,
    };
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

    const path = try entryPath(allocator);
    defer allocator.free(path);

    // `StartupWMClass=tildaz` 는 `dist/linux/tildaz.desktop` 의 값과 일치 —
    // Wayland `xdg_toplevel.set_app_id` + portal-kde 의 client 식별과 같은
    // identifier 라 두 desktop entry 가 같은 application 으로 인식됨.
    //
    // `Hidden=false` + `X-GNOME-Autostart-enabled=true` 는 GNOME / Cinnamon /
    // KDE 모두에서 항목 활성으로 인식되는 표준 조합.
    const entry = try std.fmt.allocPrint(allocator,
        \\[Desktop Entry]
        \\Type=Application
        \\Name=TildaZ
        \\GenericName=Drop-down Terminal
        \\Comment=Quake-style drop-down terminal for Wayland
        \\Exec={s}
        \\Icon=tildaz
        \\Terminal=false
        \\Categories=System;TerminalEmulator;
        \\StartupWMClass=tildaz
        \\StartupNotify=true
        \\Hidden=false
        \\X-GNOME-Autostart-enabled=true
        \\
    , .{exe});
    defer allocator.free(entry);

    if (std.fs.openFileAbsolute(path, .{})) |existing_file| {
        defer existing_file.close();
        if (existing_file.readToEndAlloc(allocator, 64 * 1024)) |existing| {
            defer allocator.free(existing);
            if (std.mem.eql(u8, existing, entry)) return;
        } else |_| {}
    } else |_| {}

    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(entry);
}

/// auto-start 비활성화 — desktop entry 파일 삭제. 다음 로그인부터 효과.
pub fn disable(allocator: std.mem.Allocator) void {
    const path = entryPath(allocator) catch return;
    defer allocator.free(path);
    std.fs.deleteFileAbsolute(path) catch {};
}
