//! #700 — `tildaz --desktop add | remove | cleanup`.
//!
//! 사용자 데스크톱 설정 (COSMIC 단축키 파일 · sway · Hyprland 설정 · KDE 단축키 등) 을 고치는
//! 일을 **이 명령 한 곳**에 모은다. `install.sh` · `uninstall.sh` 는 파일을 직접 고치지 않고
//! 이 명령을 부르기만 한다 — 예전에는 셸의 `awk` · `sed -i` · `mv` 가 사용자 파일을 줄 단위로
//! 고쳐 결함이 반복됐다 (#681 · #698). 고치는 코드가 한 곳에 있어야 안전한 쓰기
//! (`paths.writeFileIfChanged`) 와 단위 테스트를 함께 쓴다.
//!
//!   - `add`     — 설치 때. 지금 있는 config 번호로 데스크톱 쪽 등록을 맞춘다.
//!   - `cleanup` — config 에 없는 번호의 낡은 항목만 지운다.
//!   - `remove`  — 제거 때. 우리가 넣은 것을 모두 지운다. `uninstall.sh` 가 실행 파일을
//!                 지우기 **전에** 부른다.
const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("runtime.zig").Runtime;

pub const Action = enum { add, remove, cleanup };

pub fn parseAction(text: []const u8) ?Action {
    return std.meta.stringToEnum(Action, text);
}

/// Linux 만 지원한다. 다른 OS 는 데스크톱 설정 파일을 고치는 일이 없다 (macOS 는 LaunchAgent ·
/// Windows 는 레지스트리를 앱이 직접 다룬다).
pub const supported = builtin.os.tag == .linux;

const impl = if (supported) @import("desktop_setup/linux.zig") else struct {
    pub fn run(_: Runtime, _: std.mem.Allocator, _: Action) !void {
        return error.Unsupported;
    }
};

pub fn run(rt: Runtime, allocator: std.mem.Allocator, action: Action) !void {
    return impl.run(rt, allocator, action);
}

test "#700 --desktop takes exactly the three actions" {
    try std.testing.expectEqual(Action.add, parseAction("add").?);
    try std.testing.expectEqual(Action.remove, parseAction("remove").?);
    try std.testing.expectEqual(Action.cleanup, parseAction("cleanup").?);
    try std.testing.expect(parseAction("Add") == null);
    try std.testing.expect(parseAction("") == null);
    try std.testing.expect(parseAction("install") == null);
}
