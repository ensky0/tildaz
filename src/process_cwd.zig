//! 자식 셸 프로세스의 현재 디렉토리를 **OS 에게 직접 물어본다** (#366).
//!
//! 셸이 OSC 7 을 보내주지 않아도 되는 경로다. 사용자 rc / 프롬프트를 건드리지 않고 우리
//! 코드 안에서만 해결하므로 [#265](https://github.com/ensky0/tildaz/issues/265) (홈 고정)
//! 와 같은 성격이다 — #265 가 `$HOME` 을 부모 환경변수에서 읽어 넘겼듯이, 여기서는 현재
//! 위치를 OS 에 물어 넘긴다.
//!
//! | platform | 방법 |
//! |---|---|
//! | Linux | `readlink /proc/<pid>/cwd` |
//! | macOS | `proc_pidinfo(PROC_PIDVNODEPATHINFO)` — std 에 바인딩이 없어 직접 선언 (libSystem 은 이미 링크됨) |
//! | Windows | **없음 — 항상 `null`** |
//!
//! **Windows 가 없는 이유** (2026-08-03 결정): PowerShell 은 `Set-Location` 이 runspace
//! 별 위치만 바꾸고 프로세스 cwd 는 시작값에 고정돼서 원리적으로 안 된다
//! ([MS 문서](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/set-location)).
//! `cmd` 는 PEB 를 읽으면 되지만 `NtQueryInformationProcess` 는 MS 가 *"may be altered or
//! unavailable in future versions"* 로 표기한 비공개 API 다. PowerShell 에 어차피 OSC 7
//! 주입이 필요하므로 Windows 는 주입 한 방식으로 통일한다.
//!
//! **어느 pid 인가 — 셸 자신이다** (foreground process 아님). `sudo` / `ssh` 로
//! foreground 가 바뀌면 엉뚱한 답이 나오고, root 소유 프로세스는 조회 자체가 `EPERM`
//! 이다 (macOS 실측). 셸은 우리 직계 자식이라 항상 읽힌다. OSC 7 의 의미 (셸이 프롬프트를
//! 그린 위치) 와도 같은 답이라 두 경로가 일관된다.
//!
//! **경로는 물리 경로다.** symlink 를 통해 `cd` 한 사용자는 셸의 `$PWD` (논리 경로) 와
//! 다른 값을 보게 된다. 호출처가 OSC 7 값을 우선하므로 이 차이는 셸이 보고하지 않는
//! 환경에서만 나타난다.

const std = @import("std");
const builtin = @import("builtin");

/// `pid` 셸의 현재 디렉토리를 `buf` 에 담아 돌려준다. 조회할 수 없으면 `null` —
/// 호출자는 홈으로 안전하게 열화한다.
pub fn ofPid(pid: i32, buf: []u8) ?[]const u8 {
    switch (builtin.os.tag) {
        .linux => {
            // `/proc/<pid>/cwd` 는 실제 디렉토리를 가리키는 심볼릭 링크다.
            var link_buf: [64]u8 = undefined;
            const link = std.fmt.bufPrint(&link_buf, "/proc/{d}/cwd", .{pid}) catch return null;
            // `readLinkAbsolute` 는 슬라이스가 아니라 정확히 `*[max_path_bytes]u8` 를
            // 받으므로 (호출자 버퍼 크기와 무관) 따로 받아서 옮긴다.
            var target: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fs.readLinkAbsolute(link, &target) catch return null;
            if (path.len == 0 or path.len > buf.len) return null;
            @memcpy(buf[0..path.len], path);
            return buf[0..path.len];
        },
        .macos => {
            var info: ProcVnodePathInfo = undefined;
            const rc = proc_pidinfo(
                pid,
                PROC_PIDVNODEPATHINFO,
                0,
                &info,
                @sizeOf(ProcVnodePathInfo),
            );
            // 성공하면 채운 바이트 수 (= 구조체 크기), 실패하면 0 + errno.
            if (rc <= 0) return null;
            const path = std.mem.sliceTo(&info.pvi_cdir.vip_path, 0);
            if (path.len == 0 or path.len > buf.len) return null;
            @memcpy(buf[0..path.len], path);
            return buf[0..path.len];
        },
        else => return null,
    }
}

// ── macOS `libproc` 바인딩
//
// 레이아웃은 macOS 26 에서 C 헤더로 직접 측정했다 (#366). 헤더가 바뀌면 아래 comptime
// assert 가 잡는다 — 크기가 어긋난 채로 호출하면 `proc_pidinfo` 가 조용히 실패하거나
// 엉뚱한 offset 에서 경로를 읽는다.

const PROC_PIDVNODEPATHINFO: c_int = 9;
const MAXPATHLEN = 1024;

/// `vnode_info_path`. 앞쪽 `vnode_info` 는 stat 류 필드 뭉치인데 우리는 경로만 쓰므로
/// 크기 (152 바이트, 8 바이트 정렬) 만 맞춰 둔다.
const VnodeInfoPath = extern struct {
    vip_vi: [19]u64,
    vip_path: [MAXPATHLEN]u8,
};

/// `proc_vnodepathinfo`. `pvi_cdir` = 현재 디렉토리, `pvi_rdir` = 루트 디렉토리 (미사용).
const ProcVnodePathInfo = extern struct {
    pvi_cdir: VnodeInfoPath,
    pvi_rdir: VnodeInfoPath,
};

comptime {
    std.debug.assert(@sizeOf(VnodeInfoPath) == 1176);
    std.debug.assert(@offsetOf(VnodeInfoPath, "vip_path") == 152);
    std.debug.assert(@sizeOf(ProcVnodePathInfo) == 2352);
    std.debug.assert(@offsetOf(ProcVnodePathInfo, "pvi_cdir") == 0);
}

extern "c" fn proc_pidinfo(
    pid: c_int,
    flavor: c_int,
    arg: u64,
    buffer: ?*anyopaque,
    buffersize: c_int,
) c_int;

// ── 테스트

test "process_cwd — 자기 프로세스의 cwd 를 조회한다 (Windows 는 미지원)" {
    var buf: [4200]u8 = undefined;

    if (comptime builtin.os.tag == .windows) {
        // Windows 는 OSC 7 주입으로 간다 — 조회는 항상 null.
        try std.testing.expect(ofPid(0, &buf) == null);
        return;
    }

    const probed = ofPid(std.c.getpid(), &buf) orelse return error.ProbeFailed;
    // `getcwd` 도 물리 경로를 주므로 문자열이 그대로 일치해야 한다.
    var actual_buf: [4200]u8 = undefined;
    const actual = try std.posix.getcwd(&actual_buf);
    try std.testing.expectEqualStrings(actual, probed);
}

test "process_cwd — 없는 pid 는 null" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var buf: [4200]u8 = undefined;
    // pid 1 은 macOS 에서 EPERM (실측), Linux 에서도 readlink 가 막힌다. 어느 쪽이든
    // 조회 실패는 null 로 나와야 한다 (호출자가 홈으로 열화).
    try std.testing.expect(ofPid(1, &buf) == null);
}

test "process_cwd — 버퍼가 모자라면 null" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var small: [4]u8 = undefined;
    try std.testing.expect(ofPid(std.c.getpid(), &small) == null);
}
