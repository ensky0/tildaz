pub const Session = struct {
    pub fn deinit(_: *Session) void {}
};

pub fn begin(_: []const u32) !Session {
    // Wayland dialog 가 keyboard-shortcuts inhibitor 로 compositor binding 을
    // 막는다. worker 별 등록을 따로 중지할 필요가 없다.
    return .{};
}
