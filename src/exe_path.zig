//! #706 — 바깥 파일에 적을 실행 파일 경로.
//!
//! 자동 시작 항목 · 메뉴 항목 · COSMIC 단축키 · sway · Hyprland 자동 실행 파일처럼 **앱이
//! 끝난 뒤에도 남아 나중에 실행되는 명령**은 이 경로를 쓴다. 보통은 `/proc/self/exe` 와 같다.
//!
//! AppImage 만 다르다. runtime 이 이미지를 임시 폴더 (`/tmp/.mount_…`) 에 마운트하고 그 안의
//! 바이너리를 실행하므로 `/proc/self/exe` 가 그 임시 경로다. 앱이 끝나면 마운트가 풀려 그
//! 경로가 사라진다 (2026-10-09 v0.10.1 실기 — 자동 시작 `Exec` 가 그 경로였고, worker 를
//! 끄자 경로가 없어졌다). runtime 은 진짜 파일 경로를 `APPIMAGE` 에, 마운트 폴더를 `APPDIR`
//! 에 넣어 준다 (<https://docs.appimage.org/packaging-guide/environment-variables.html> ·
//! type2-runtime `runtime.c` 의 `setenv("APPIMAGE", fullpath, 1)` — 마운트 실행과
//! `--appimage-extract-and-run` 둘 다).
//!
//! **실행 파일이 `APPDIR` 아래에 있을 때만 `APPIMAGE` 를 믿는다.** 환경변수는 자식에게
//! 물려줘서 TildaZ 안의 셸에도 남는다. 그 셸에서 다른 방식으로 깐 `tildaz` 를 실행하면
//! 남의 `APPIMAGE` 를 자기 경로로 착각한다.
//!
//! worker 를 띄우는 경로와 런타임 단축키 (sway `bindsym` · `hyprctl bind`) 는 이 값을 쓰지
//! 않는다. 앱이 떠 있는 동안만 쓰이고 그동안 마운트가 살아 있으며, `APPIMAGE` 를 쓰면 누를
//! 때마다 이미지를 새로 마운트한다.
const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;

/// 바깥 파일에 적을 실행 파일의 절대 경로. 결과는 `buf` 안에 있다.
pub fn persistent(rt: Runtime, buf: []u8) ![]const u8 {
    const n = try std.process.executablePath(rt.io, buf);
    const exe = buf[0..n];
    const image = appImagePath(exe, rt.environ.getPosix("APPIMAGE"), rt.environ.getPosix("APPDIR")) orelse return exe;
    if (image.len > buf.len) return error.NameTooLong;
    // `image` 는 환경 블록을 가리키므로 `buf` 와 겹치지 않는다.
    @memcpy(buf[0..image.len], image);
    return buf[0..image.len];
}

/// `exe` 가 `appdir` 아래에 있으면 `appimage` 를 돌려준다. 아니면 `null`.
fn appImagePath(exe: []const u8, appimage: ?[]const u8, appdir: ?[]const u8) ?[]const u8 {
    const image = appimage orelse return null;
    const dir_raw = appdir orelse return null;
    if (!std.Io.Dir.path.isAbsolute(image) or !std.Io.Dir.path.isAbsolute(dir_raw)) return null;
    var dir = dir_raw;
    while (dir.len > 1 and dir[dir.len - 1] == '/') dir = dir[0 .. dir.len - 1];
    if (dir.len <= 1) return null;
    if (exe.len <= dir.len + 1 or !std.mem.startsWith(u8, exe, dir) or exe[dir.len] != '/') return null;
    return image;
}

test "#706 APPIMAGE is used only when the running binary is inside APPDIR" {
    const image = "/home/u/Apps/TildaZ-0.10.1-x86_64.AppImage";
    const mount = "/tmp/.mount_TildaZIJCfch";
    const inside = "/tmp/.mount_TildaZIJCfch/usr/bin/tildaz";
    try std.testing.expectEqualStrings(image, appImagePath(inside, image, mount).?);
    // 끝에 `/` 가 붙어도 같다.
    try std.testing.expectEqualStrings(image, appImagePath(inside, image, mount ++ "/").?);
    // AppImage 안의 셸에서 다른 방식으로 깐 tildaz 를 실행한 경우 — 환경변수만 물려받았다.
    try std.testing.expect(appImagePath("/usr/bin/tildaz", image, mount) == null);
    // 이름만 앞이 같은 다른 폴더.
    try std.testing.expect(appImagePath("/tmp/.mount_TildaZIJCfchX/usr/bin/tildaz", image, mount) == null);
    // AppImage 가 아니다.
    try std.testing.expect(appImagePath(inside, null, mount) == null);
    try std.testing.expect(appImagePath(inside, image, null) == null);
    // 상대 경로 · 루트는 믿지 않는다.
    try std.testing.expect(appImagePath(inside, "TildaZ.AppImage", mount) == null);
    try std.testing.expect(appImagePath(inside, image, "tmp/.mount_TildaZIJCfch") == null);
    try std.testing.expect(appImagePath(inside, image, "/") == null);
    try std.testing.expect(appImagePath(mount, image, mount) == null);
}
