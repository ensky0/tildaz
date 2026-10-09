//! #700 — sway · Hyprland 사용자 설정에 **우리 줄 두 개만** 넣고 빼는 순수 텍스트 함수.
//!
//! 자동실행 명령은 사용자 설정이 아니라 우리 파일 (`<id>.conf` · `<id>.lua`) 에 둔다. 사용자
//! 설정에는 그 파일을 불러오는 줄과, 그 줄이 무엇인지 알리는 표식 주석만 넣는다. 다른 줄은
//! 읽기만 하고 고치지 않는다 — 예전 `install.sh` 는 "표식 다음 줄은 우리 것" 으로 보고 그
//! 줄을 바꿔 썼다 (#700 표의 5 번).
//!
//! 판정은 모두 **줄 전체가 글자 그대로 같은가** 다 (끝의 공백 · `\r` 만 무시한다). 사용자가
//! 그 줄을 고쳤으면 우리 줄이 아니므로 건드리지 않는다.
const std = @import("std");

/// 설정 파일의 주석 기호. sway · Hyprland legacy (`.conf`) 는 `#`, Hyprland Lua 는 `--`.
pub const Syntax = enum {
    hash,
    lua,

    pub fn comment(self: Syntax) []const u8 {
        return switch (self) {
            .hash => "#",
            .lua => "--",
        };
    }
};

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, " \t\r");
}

pub fn containsLine(content: []const u8, want: []const u8) bool {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, trimLine(line), want)) return true;
    }
    return false;
}

/// 표식과 불러오는 줄을 파일 끝에 붙인 새 내용. 불러오는 줄이 이미 있으면 `null` (쓰지 않는다).
/// 앞에 빈 줄 하나를 두는 것은 예전 `install.sh` 와 같다 — 사용자 본문과 갈라 보이게.
pub fn withInclude(allocator: std.mem.Allocator, content: []const u8, marker: []const u8, line: []const u8) !?[]u8 {
    if (containsLine(content, line)) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, content);
    if (content.len > 0 and content[content.len - 1] != '\n') try out.append(allocator, '\n');
    if (content.len > 0) try out.append(allocator, '\n');
    try out.appendSlice(allocator, marker);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, line);
    try out.append(allocator, '\n');
    return try out.toOwnedSlice(allocator);
}

/// 불러오는 줄을 지운 새 내용. 그 바로 위가 우리 표식이면 표식도, 그 위가 빈 줄이면 빈 줄도
/// 함께 지운다 (`withInclude` 의 역). 불러오는 줄이 없으면 `null`.
pub fn withoutInclude(allocator: std.mem.Allocator, content: []const u8, marker: []const u8, line: []const u8) !?[]u8 {
    return dropBlocks(allocator, content, marker, .{ .exact = line });
}

/// 예전 `install.sh` 가 넣은 블록 (표식 + 다음 한 줄) 을 지운 새 내용. 다음 줄이 그 스크립트가
/// 쓴 모양일 때만 지운다 — 자동실행 줄이거나 그보다 오래된 판의 정적 단축키 줄. 사용자가 그
/// 줄을 고쳤으면 표식도 그 줄도 그대로 둔다. 지울 것이 없으면 `null`.
pub fn withoutLegacyBlocks(allocator: std.mem.Allocator, content: []const u8, marker: []const u8, syntax: Syntax) !?[]u8 {
    return dropBlocks(allocator, content, marker, .{ .legacy = syntax });
}

const Target = union(enum) {
    /// 우리가 쓰는 불러오는 줄. 이 줄이 기준이고 그 위 표식은 있으면 함께 지운다.
    exact: []const u8,
    /// 옛 블록. 표식이 기준이고 그 다음 줄이 옛 모양이어야 한다.
    legacy: Syntax,
};

fn dropBlocks(allocator: std.mem.Allocator, content: []const u8, marker: []const u8, target: Target) !?[]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| try lines.append(allocator, line);
    // 끝이 `\n` 이면 split 이 빈 조각 하나를 더 낸다. 그것은 줄이 아니다.
    const ends_with_newline = content.len > 0 and content[content.len - 1] == '\n';
    if (ends_with_newline) _ = lines.pop();

    const drop = try allocator.alloc(bool, lines.items.len);
    defer allocator.free(drop);
    @memset(drop, false);
    var dropped = false;
    for (lines.items, 0..) |raw, i| {
        const line = trimLine(raw);
        switch (target) {
            .exact => |want| {
                if (!std.mem.eql(u8, line, want)) continue;
                drop[i] = true;
                var top = i;
                if (top > 0 and std.mem.eql(u8, trimLine(lines.items[top - 1]), marker)) {
                    top -= 1;
                    drop[top] = true;
                }
                if (top > 0 and trimLine(lines.items[top - 1]).len == 0) drop[top - 1] = true;
            },
            .legacy => |syntax| {
                if (!std.mem.eql(u8, line, marker)) continue;
                if (i + 1 >= lines.items.len) continue;
                if (!isLegacyLine(trimLine(lines.items[i + 1]), syntax)) continue;
                drop[i] = true;
                drop[i + 1] = true;
                if (i > 0 and trimLine(lines.items[i - 1]).len == 0) drop[i - 1] = true;
            },
        }
        dropped = true;
    }
    if (!dropped) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var kept: usize = 0;
    for (lines.items, drop) |line, gone| {
        if (gone) continue;
        if (kept > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, line);
        kept += 1;
    }
    if (kept > 0 and ends_with_newline) try out.append(allocator, '\n');
    return try out.toOwnedSlice(allocator);
}

/// 예전 `install.sh` 가 표식 아래 쓴 줄인가. 실행 파일 경로는 판마다 달랐으므로 (zig-out ·
/// 설치 폴더 · tarball) 경로 자체가 아니라 **이름이 `tildaz` 인 실행 파일** 인지만 본다.
fn isLegacyLine(line: []const u8, syntax: Syntax) bool {
    switch (syntax) {
        .hash => {
            if (wrapsAutostart(line, "exec ", "")) return true;
            if (wrapsAutostart(line, "exec-once = ", "")) return true;
            // 정적 단축키 (`bind = …, exec, <tildaz> --toggle N`) — 자동실행보다 오래된 판.
            const rest = std.mem.trimStart(u8, line, " \t");
            if (!std.mem.startsWith(u8, rest, "bind")) return false;
            const after = std.mem.trimStart(u8, rest["bind".len..], " \t");
            return after.len > 0 and after[0] == '=' and mentionsToggle(line);
        },
        .lua => {
            if (wrapsAutostart(line, "hl.on(\"hyprland.start\", function() hl.exec_cmd(\"", "\") end)")) return true;
            return std.mem.indexOf(u8, line, "hl.bind(") != null and mentionsToggle(line);
        },
    }
}

fn wrapsAutostart(line: []const u8, prefix: []const u8, suffix: []const u8) bool {
    const tail = " --autostart";
    if (!std.mem.startsWith(u8, line, prefix)) return false;
    if (!std.mem.endsWith(u8, line, suffix)) return false;
    if (line.len < prefix.len + tail.len + suffix.len) return false;
    const middle = line[prefix.len .. line.len - suffix.len];
    if (!std.mem.endsWith(u8, middle, tail)) return false;
    return isTildazExe(middle[0 .. middle.len - tail.len]);
}

fn isTildazExe(path: []const u8) bool {
    if (path.len == 0 or std.mem.indexOfAny(u8, path, " \t\"") != null) return false;
    return std.mem.eql(u8, std.Io.Dir.path.basename(path), "tildaz");
}

fn mentionsToggle(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "tildaz") != null and std.mem.indexOf(u8, line, "--toggle") != null;
}

const testing = std.testing;
const t_marker = "# tildaz autostart (managed by tildaz --desktop)";
const t_line = "include /home/u/.config/sway/tildaz.conf";

test "#700 the include line is added once and removed with its marker" {
    const user = "include /etc/sway/config\nbindsym Mod4+t exec foot\n";
    const added = (try withInclude(testing.allocator, user, t_marker, t_line)).?;
    defer testing.allocator.free(added);
    try testing.expectEqualStrings(user ++ "\n" ++ t_marker ++ "\n" ++ t_line ++ "\n", added);
    // 이미 있으면 쓰지 않는다.
    try testing.expect((try withInclude(testing.allocator, added, t_marker, t_line)) == null);
    // 지우면 원래 바이트로 돌아온다.
    const removed = (try withoutInclude(testing.allocator, added, t_marker, t_line)).?;
    defer testing.allocator.free(removed);
    try testing.expectEqualStrings(user, removed);
    try testing.expect((try withoutInclude(testing.allocator, user, t_marker, t_line)) == null);
}

test "#700 the include line works on an empty file and one without a final newline" {
    const from_empty = (try withInclude(testing.allocator, "", t_marker, t_line)).?;
    defer testing.allocator.free(from_empty);
    try testing.expectEqualStrings(t_marker ++ "\n" ++ t_line ++ "\n", from_empty);

    const added = (try withInclude(testing.allocator, "exec foot", t_marker, t_line)).?;
    defer testing.allocator.free(added);
    try testing.expectEqualStrings("exec foot\n\n" ++ t_marker ++ "\n" ++ t_line ++ "\n", added);
}

test "#700 a user-edited include line or a moved marker is left to the user" {
    // 사용자가 줄을 주석 처리했다 — 우리 줄이 아니다. add 는 새로 붙이고 remove 는 손대지 않는다.
    const commented = "exec foot\n" ++ t_marker ++ "\n#" ++ t_line ++ "\n";
    try testing.expect((try withoutInclude(testing.allocator, commented, t_marker, t_line)) == null);
    // 사용자가 줄을 다른 자리로 옮겼다 — 그 줄만 지우고 그 위 사용자 줄은 둔다.
    const moved = "exec foot\n" ++ t_line ++ "\nexec kitty\n";
    const out = (try withoutInclude(testing.allocator, moved, t_marker, t_line)).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("exec foot\nexec kitty\n", out);
}

test "#700 old install.sh blocks are migrated only when the next line is ours" {
    const old = "# tildaz autostart (added by install.sh — uninstall.sh removes this)";
    const sway = "include /etc/sway/config\n\n" ++ old ++ "\nexec /home/u/tildaz/zig-out/bin/tildaz --autostart\n";
    const out = (try withoutLegacyBlocks(testing.allocator, sway, old, .hash)).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("include /etc/sway/config\n", out);

    const conf = "monitor=,preferred,auto,1\n\n" ++ old ++ "\nexec-once = /usr/bin/tildaz --autostart\n" ++
        old ++ "\nbind = CTRL, F1, exec, /usr/bin/tildaz --toggle 0\nexec-once = waybar\n";
    const conf_out = (try withoutLegacyBlocks(testing.allocator, conf, old, .hash)).?;
    defer testing.allocator.free(conf_out);
    try testing.expectEqualStrings("monitor=,preferred,auto,1\nexec-once = waybar\n", conf_out);

    const lua_old = "-- tildaz autostart (added by install.sh — uninstall.sh removes this)";
    const lua = "hl.config({})\n\n" ++ lua_old ++ "\nhl.on(\"hyprland.start\", function() hl.exec_cmd(\"/opt/t/tildaz --autostart\") end)\n";
    const lua_out = (try withoutLegacyBlocks(testing.allocator, lua, lua_old, .lua)).?;
    defer testing.allocator.free(lua_out);
    try testing.expectEqualStrings("hl.config({})\n", lua_out);

    // 사용자가 표식 아래 줄을 바꿨다 · 다른 프로그램을 적었다 · 주석 처리했다 — 그대로 둔다.
    for ([_][]const u8{
        old ++ "\nexec /home/u/tildaz/zig-out/bin/tildaz --autostart --instance 2\n",
        old ++ "\nexec /usr/bin/foot --autostart\n",
        old ++ "\n# exec /usr/bin/tildaz --autostart\n",
        old ++ "\n",
        old,
    }) |text| try testing.expect((try withoutLegacyBlocks(testing.allocator, text, old, .hash)) == null);
}
