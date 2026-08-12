//! 이 머신의 hostname. OSC 7 (`report_pwd`) 이 알려 준 host 가 우리 머신인지 검사하는
//! 데 쓴다 (#366) — ssh 안의 셸이 보낸 경로는 이 머신에 없으므로 거부해야 한다.
//!
//! [`system_open.zig`](system_open.zig) 와 같은 성격의 작은 cross-platform helper.
//! `std.posix.gethostname` 은 Windows 에서 `@compileError("TODO implement gethostname
//! for this OS")` 라 쓸 수 없어서 Windows 만 `GetComputerNameW` 를 직접 부른다 (ghostty
//! 의 `src/os/hostname.zig` 도 같은 이유로 `GetComputerNameA` 를 쓴다).

const std = @import("std");
const builtin = @import("builtin");

/// hostname 을 담을 버퍼 크기. RFC 1035 의 label 상한 (255) + NUL 여유.
pub const max_len = 256;

/// hostname 을 `buf` 에 담아 slice 로 돌려준다. 조회에 실패하면 **빈 slice** —
/// 호출처 ([`pwd_uri.parse`](pwd_uri.zig)) 는 hostname 이 비면 빈 host / `localhost`
/// 만 수락하므로, 원격 경로를 잘못 받아들이는 쪽이 아니라 상속을 포기하는 쪽으로
/// 열화한다.
pub fn get(buf: *[max_len]u8) []const u8 {
    switch (builtin.os.tag) {
        .windows => {
            var wbuf: [max_len]u16 = undefined;
            // nSize 는 in/out — 들어갈 때 버퍼 크기, 나올 때 NUL 을 뺀 실제 길이.
            var size: u32 = wbuf.len;
            if (GetComputerNameW(&wbuf, &size) == 0) return "";
            if (size >= wbuf.len) return "";
            const len = std.unicode.utf16LeToUtf8(buf, wbuf[0..size]) catch return "";
            return buf[0..len];
        },
        else => {
            // `gethostname` 은 정확히 `*[HOST_NAME_MAX]u8` 를 받으므로 별도 버퍼로
            // 받아서 옮긴다 (HOST_NAME_MAX 는 OS 마다 다르고 max_len 과 무관).
            var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
            const name = std.posix.gethostname(&host_buf) catch return "";
            if (name.len > buf.len) return "";
            @memcpy(buf[0..name.len], name);
            return buf[0..name.len];
        },
    }
}

extern "kernel32" fn GetComputerNameW(lpBuffer: [*]u16, nSize: *u32) callconv(.c) i32;

test "local_hostname — 조회가 실패해도 안전한 값을 돌려준다" {
    var buf: [max_len]u8 = undefined;
    const name = get(&buf);
    // 실패 시 빈 slice. 성공 시 버퍼 안의 값이어야 한다 (길이 검증만 — 실제 값은
    // 실행 환경에 따라 다르다).
    try std.testing.expect(name.len <= max_len);
    // NUL 이 섞여 들어오면 이후 경로 비교가 어긋난다.
    try std.testing.expect(std.mem.findScalar(u8, name, 0) == null);
}
