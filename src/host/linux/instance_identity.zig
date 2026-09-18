const std = @import("std");
const Runtime = @import("../../runtime.zig").Runtime;
const app_id = @import("../../app_id.zig");
const paths = @import("../../paths.zig");

/// #282 G14 — config index 상한 단일 소스 (`instances.max_config_index`). 이
/// 값은 desktop entry 삭제 스윕이 순회할 최대 번호로도 쓰인다.
pub const max_index = @import("../../instances.zig").max_config_index;

/// **`ensureDesktopEntry` 의 파일 이름과 짝이어야 한다** — portal · 데스크톱 환경이
/// 창의 `app_id` 로 desktop 항목을 찾는다. 한쪽만 `app_id.name` 을 타면 그 연결이
/// 끊어진다 (#654).
pub fn appId(buf: []u8, index: u32) ![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}.instance{d}", .{ app_id.name, index }, 0);
}

/// 측정 인스턴스의 app_id ([#382](https://github.com/ensky0/tildaz/issues/382)).
///
/// **worker 의 `tildaz.instanceN` 과 겹치지 않아야 한다** — 우리가 배포하는 GNOME ·
/// Cinnamon extension 이 창 타이틀 (`TildaZ-N`) 과 이 app_id 로 사용자의 드롭다운 창을
/// 찾는다 (`dist/linux/gnome-extension/…/extension.js` 의 `workerIndex`). 측정 창이
/// worker 정체를 쓰면 extension 이 그것을 사용자 창으로 오인해 config 퍼센트 크기로
/// 옮기고 (`-size` 가 깨진다) `hidden_start: true` 면 minimize 한다 (렌더가 없어져 측정이
/// 무의미해진다).
///
/// extension 이 이 창을 **아예 관리하지 않는 것이 의도한 결과**다 — 측정 창은 사용자의
/// 드롭다운이 아니다.
pub const stress_app_id: [:0]const u8 = app_id.name ++ ".stress";

/// 현재 역할의 app_id. Wayland `xdg_toplevel.set_app_id` 와 KDE 단축키 component 가
/// 같은 값을 써야 하므로 파생을 한 곳에 둔다.
pub fn appIdForCurrentRole(buf: []u8) ![:0]const u8 {
    const instance_context = @import("../../instance_context.zig");
    return switch (instance_context.currentRole()) {
        .worker => try appId(buf, instance_context.requireWorkerIndex()),
        .stress => stress_app_id,
    };
}

/// 창 제목. GNOME · Cinnamon 확장이 이 문자열로 사용자의 드롭다운 창을 찾으므로
/// dev 판은 다른 이름을 써서 **확장이 개발 창을 사용자 창으로 오인하지 않게** 한다
/// (`stress_app_id` 를 가른 것과 같은 이유다). 확장 경로 자체를 시연할 때는
/// `-Ddev=false` 로 빌드한다.
pub fn displayName(buf: []u8, index: u32) ![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}_{d}", .{ app_id.window_base, index }, 0);
}

/// wlr-layer-shell surface 의 namespace. compositor 가 **창 규칙을 거는 키**라 개발
/// 빌드와 릴리즈가 같은 값을 쓰면 사용자가 릴리즈에 건 규칙이 개발 창에도 걸린다 (#654).
/// layer surface 에는 `app_id` 가 없어 이 문자열이 그 자리를 대신하므로, 여기서 가른다.
pub const layer_namespace: [:0]const u8 = app_id.name;

pub fn shortcutId(buf: []u8, index: u32) ![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, "toggle-{d}", .{index}, 0);
}

pub fn shortcutDescription(buf: []u8, index: u32) ![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, "Show / hide TildaZ {d}", .{index}, 0);
}

/// 이름 앞부분은 `app_id.name` 을 탄다 (#654) — 개발 빌드가 만든 항목과 릴리즈가 만든
/// 항목이 같은 `~/.local/share/applications/` 에 놓이므로, 여기가 안 갈리면 서로의
/// 인스턴스 항목을 자기 것으로 읽는다. `.desktop` 은 XDG 규격상 공용 디렉터리라
/// 디렉터리로는 가를 수 없어 이름에 섞는다.
fn parseDesktopFileName(name: []const u8) ?u32 {
    const prefix = app_id.name ++ ".instance";
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, ".desktop")) return null;
    const digits = name[prefix.len .. name.len - ".desktop".len];
    if (digits.len == 0 or (digits.len > 1 and digits[0] == '0')) return null;
    const index = std.fmt.parseInt(u32, digits, 10) catch return null;
    return if (index <= max_index) index else null;
}

fn applicationsDir(rt: Runtime, allocator: std.mem.Allocator) ![]u8 {
    const home = try rt.envAlloc(allocator, "HOME");
    defer allocator.free(home);
    return std.Io.Dir.path.join(allocator, &.{ home, ".local", "share", "applications" });
}

fn containsIndex(indices: []const u32, index: u32) bool {
    for (indices) |candidate| if (candidate == index) return true;
    return false;
}

pub fn ensureDesktopEntry(rt: Runtime, allocator: std.mem.Allocator, index: u32) !void {
    const dir = try applicationsDir(rt, allocator);
    defer allocator.free(dir);
    // #451 — `fs.Dir.makePath` ➡️ 공용 helper (`paths.ensureDir` = `createDirPath`).
    try paths.ensureDir(rt, dir);

    const file_name = try std.fmt.allocPrint(allocator, "{s}.instance{d}.desktop", .{ app_id.name, index });
    defer allocator.free(file_name);
    const path = try std.Io.Dir.path.join(allocator, &.{ dir, file_name });
    defer allocator.free(path);

    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // #451 — `fs.selfExePath` ➡️ `std.process.executablePath` (길이를 돌려준다).
    const exe_len = try std.process.executablePath(rt.io, &exe_buf);
    const exe = exe_buf[0..exe_len];
    if (std.mem.findAny(u8, exe, "\n\r\"") != null) return error.UnsupportedExecutablePath;

    // **본문도 `app_id` 를 탄다** — 파일 *이름*만 가르면 그 항목이 릴리즈 창을 가리킨다.
    // `StartupWMClass` 는 데스크톱 · portal 이 창과 이 항목을 묶는 열쇠라 위 `appId` 와
    // 글자 단위로 같아야 하고, `Name` 은 창 제목 (`displayName`) 과, `Icon` 은
    // `install.sh` 가 까는 아이콘 파일 이름 (`<name>.svg`) 과 짝이다.
    const content = try std.fmt.allocPrint(allocator,
        \\[Desktop Entry]
        \\Type=Application
        \\Name={s}_{d}
        \\GenericName=Drop-down Terminal Instance
        \\Comment=Independent TildaZ terminal instance {d}
        \\Exec="{s}" --instance {d}
        \\Icon={s}
        \\Terminal=false
        \\Categories=System;TerminalEmulator;
        \\StartupWMClass={s}.instance{d}
        \\StartupNotify=false
        \\NoDisplay=true
        \\
    , .{ app_id.window_base, index, index, exe, index, app_id.name, app_id.name, index });
    defer allocator.free(content);

    _ = try paths.writeFileIfChanged(rt, allocator, path, content);
}

pub fn syncDesktopEntries(rt: Runtime, allocator: std.mem.Allocator, indices: []const u32) !void {
    const dir_path = try applicationsDir(rt, allocator);
    defer allocator.free(dir_path);
    try paths.ensureDir(rt, dir_path);

    for (indices) |index| try ensureDesktopEntry(rt, allocator, index);

    // #451 — `fs.openDirAbsolute` ➡️ `Io.Dir.openDirAbsolute`. 순회 (`Iterator.next`) 와
    // `close` · `deleteFile` 도 모두 `io` 를 받는다.
    var dir = try std.Io.Dir.openDirAbsolute(rt.io, dir_path, .{ .iterate = true });
    defer dir.close(rt.io);
    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        if (entry.kind != .file) continue;
        const index = parseDesktopFileName(entry.name) orelse continue;
        if (!containsIndex(indices, index)) try dir.deleteFile(rt.io, entry.name);
    }
}

test "numbered Linux identity is canonical" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(app_id.name ++ ".instance12", try appId(&buf, 12));
    try std.testing.expectEqualStrings(app_id.window_base ++ "_12", try displayName(&buf, 12));
    try std.testing.expectEqualStrings("toggle-12", try shortcutId(&buf, 12));
    try std.testing.expectEqualStrings("Show / hide TildaZ 12", try shortcutDescription(&buf, 12));
    try std.testing.expectEqual(@as(?u32, 0), parseDesktopFileName(app_id.name ++ ".instance0.desktop"));
    try std.testing.expectEqual(@as(?u32, null), parseDesktopFileName(app_id.name ++ ".instance01.desktop"));
    try std.testing.expectEqual(@as(?u32, null), parseDesktopFileName(app_id.name ++ ".desktop"));
}
