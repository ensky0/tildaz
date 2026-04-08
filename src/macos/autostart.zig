// macOS 자동 시작 관리
// Windows Task Scheduler 대신 ~/Library/LaunchAgents/ plist 사용.
// launchctl bootstrap/bootout으로 등록/해제.

const std = @import("std");
const posix = std.posix;

const PLIST_LABEL = "com.tildaz.launcher";

fn getPlistPath(alloc: std.mem.Allocator) ![]u8 {
    const home = posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(
        alloc,
        "{s}/Library/LaunchAgents/{s}.plist",
        .{ home, PLIST_LABEL },
    );
}

fn getExePath(alloc: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    const len = std.fs.selfExePath(&buf) catch return error.ExePathFailed;
    return alloc.dupe(u8, buf[0..len]);
}

/// 자동 시작 활성화: plist 작성 후 launchctl 등록
pub fn setAutostart(alloc: std.mem.Allocator, enabled: bool) !void {
    if (enabled) {
        try enable(alloc);
    } else {
        try disable(alloc);
    }
}

pub fn isEnabled(alloc: std.mem.Allocator) bool {
    const path = getPlistPath(alloc) catch return false;
    defer alloc.free(path);
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn enable(alloc: std.mem.Allocator) !void {
    const plist_path = try getPlistPath(alloc);
    defer alloc.free(plist_path);

    const exe_path = try getExePath(alloc);
    defer alloc.free(exe_path);

    // LaunchAgents 디렉터리 생성
    const dir = std.fs.path.dirname(plist_path) orelse return error.NoDirname;
    std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    // plist 내용
    const plist = try std.fmt.allocPrint(alloc,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        \\  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key>
        \\  <string>{s}</string>
        \\  <key>ProgramArguments</key>
        \\  <array>
        \\    <string>{s}</string>
        \\  </array>
        \\  <key>RunAtLoad</key>
        \\  <true/>
        \\  <key>KeepAlive</key>
        \\  <false/>
        \\  <key>StandardOutPath</key>
        \\  <string>/tmp/tildaz.log</string>
        \\  <key>StandardErrorPath</key>
        \\  <string>/tmp/tildaz.log</string>
        \\</dict>
        \\</plist>
    , .{ PLIST_LABEL, exe_path });
    defer alloc.free(plist);

    // plist 파일 작성
    const file = try std.fs.createFileAbsolute(plist_path, .{});
    defer file.close();
    try file.writeAll(plist);

    // launchctl bootstrap 등록
    const uid = posix.getuid();
    const domain = try std.fmt.allocPrint(alloc, "gui/{d}", .{uid});
    defer alloc.free(domain);

    var child = std.process.Child.init(&.{ "launchctl", "bootstrap", domain, plist_path }, alloc);
    _ = child.spawnAndWait() catch {};
}

fn disable(alloc: std.mem.Allocator) !void {
    const plist_path = try getPlistPath(alloc);
    defer alloc.free(plist_path);

    const uid = posix.getuid();
    const domain = try std.fmt.allocPrint(alloc, "gui/{d}", .{uid});
    defer alloc.free(domain);

    // launchctl bootout 해제
    var child = std.process.Child.init(&.{ "launchctl", "bootout", domain, plist_path }, alloc);
    _ = child.spawnAndWait() catch {};

    // plist 파일 삭제
    std.fs.deleteFileAbsolute(plist_path) catch {};
}
