//! 새 instance 단축키 입력 중 기존 TildaZ global hotkey 가 먼저 입력을
//! 소비하지 않도록 모든 worker 의 등록을 잠시 중지한다.

const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .windows => @import("hotkey_capture/windows.zig"),
    .macos => @import("hotkey_capture/macos.zig"),
    .linux => @import("hotkey_capture/linux.zig"),
    else => @compileError("unsupported platform"),
};

pub const Session = impl.Session;

pub fn begin(indices: []const u32) !Session {
    return impl.begin(indices);
}
