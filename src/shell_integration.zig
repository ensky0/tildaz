//! 셸이 OSC 7 (`report_pwd`) 로 현재 위치를 알리게 만드는 주입 문자열 (#366).
//!
//! 순수 모듈 — 문자열 조립만 하고 환경변수 조회 / 전달은 각 host 가 한다
//! ([`host/windows.zig`](host/windows.zig) 의 `buildExtraEnv`). 조립을 host 안에 두면
//! Windows 전용 코드가 되어 다른 머신에서 단위 테스트를 돌릴 수 없기 때문이다.
//!
//! # Windows 만 주입한다
//!
//! Linux · macOS 는 프로세스 cwd 조회 ([`process_cwd.zig`](process_cwd.zig)) 로 셸과
//! 무관하게 위치를 얻으므로 **사용자 환경을 전혀 건드리지 않는다** (2026-08-03 결정).
//! Windows 는 PowerShell 이 `Set-Location` 을 runspace 별로만 반영해서 프로세스 cwd
//! 조회가 원리적으로 불가하고, `cmd` 만 되는 PEB 읽기는 비공개 API 라 주입이 유일한
//! 길이다.
//!
//! # 스킴은 `kitty-shell-cwd://`
//!
//! 셸의 프롬프트 기능으로는 퍼센트 인코딩을 할 수 없다. `file://` 로 보내면 파서가
//! 인코딩된 값으로 읽어서 `C:\50%20x` 같은 경로가 `C:\50 x` 로 **잘못 디코딩된다.**
//! raw 스킴은 그 문제가 없다 (아래 왕복 테스트가 이 차이를 고정한다).

const std = @import("std");

/// cmd 가 프롬프트를 그릴 때마다 OSC 7 을 보내게 하는 조각.
///
/// `$E` = ESC, `$P` = 현재 드라이브+경로, `$E\` = ST (String Terminator). host 는 비워
/// 둔다 (`:///` — 슬래시 셋) — 파서가 빈 host 를 수락한다. cmd 는 프롬프트를 그릴 때마다
/// `PROMPT` 를 다시 확장하므로 `cd` 를 따라온다 (Windows 실기 확인, #366).
const cmd_report = "$E]7;kitty-shell-cwd:///$P$E\\";

/// cmd 의 기본 프롬프트. `PROMPT` 가 설정돼 있지 않을 때 이어 붙인다 — 환경변수를
/// 설정하는 순간 cmd 의 기본값은 적용되지 않으므로, 우리가 명시하지 않으면 프롬프트에
/// 경로도 `>` 도 남지 않는다.
const cmd_default_prompt = "$P$G";

/// cmd 의 `PROMPT` 값을 조립한다. 보고 조각을 **기존 값 앞에** 붙인다 — `PROMPT` 는
/// 프롬프트 *모양* 자체라 덮어쓰면 사용자가 정해 둔 프롬프트가 사라진다.
///
/// 버퍼가 모자라면 `null` — 호출자는 주입을 건너뛰고 기존 동작 (홈에서 시작) 을 남긴다.
pub fn cmdPrompt(buf: []u8, existing: []const u8) ?[]const u8 {
    const tail = if (existing.len > 0) existing else cmd_default_prompt;
    const total = cmd_report.len + tail.len;
    if (total > buf.len) return null;
    @memcpy(buf[0..cmd_report.len], cmd_report);
    @memcpy(buf[cmd_report.len..][0..tail.len], tail);
    return buf[0..total];
}

// ── 테스트

const testing = std.testing;
const pwd_uri = @import("pwd_uri.zig");

test "shell_integration — cmd PROMPT 는 기존 값 앞에 보고 조각을 붙인다" {
    var buf: [256]u8 = undefined;
    // 사용자가 정해 둔 프롬프트 모양은 그대로 뒤에 남는다.
    try testing.expectEqualStrings(
        "$E]7;kitty-shell-cwd:///$P$E\\[$P]$G",
        cmdPrompt(&buf, "[$P]$G").?,
    );
    // 설정돼 있지 않으면 cmd 기본값을 이어 붙인다.
    try testing.expectEqualStrings(
        "$E]7;kitty-shell-cwd:///$P$E\\$P$G",
        cmdPrompt(&buf, "").?,
    );
}

test "shell_integration — 버퍼가 모자라면 주입을 건너뛴다" {
    var small: [8]u8 = undefined;
    try testing.expect(cmdPrompt(&small, "") == null);
}

test "shell_integration — cmd 가 보낼 payload 를 파서가 그대로 읽는다" {
    var buf: [pwd_uri.max_path_len]u8 = undefined;
    const opts: pwd_uri.Options = .{ .hostname = "MYPC", .style = .windows };

    // cmd 가 `$P` 를 확장한 결과 (Windows 경로, 인코딩 없음).
    try testing.expectEqualStrings(
        "C:\\Users\\me",
        pwd_uri.parse("kitty-shell-cwd:///C:\\Users\\me", &buf, opts).?,
    );
    // 공백도 그대로 (cmd 는 escape 하지 않는다).
    try testing.expectEqualStrings(
        "D:\\my dir",
        pwd_uri.parse("kitty-shell-cwd:///D:\\my dir", &buf, opts).?,
    );
    // 드라이브 루트.
    try testing.expectEqualStrings(
        "C:\\",
        pwd_uri.parse("kitty-shell-cwd:///C:\\", &buf, opts).?,
    );
}

test "shell_integration — raw 스킴을 쓰는 이유: file:// 이면 % 가 든 경로가 깨진다" {
    var buf: [pwd_uri.max_path_len]u8 = undefined;
    const opts: pwd_uri.Options = .{ .hostname = "MYPC", .style = .windows };

    // 우리가 쓰는 스킴 — `%20` 이 경로에 실제로 있는 문자로 남는다.
    try testing.expectEqualStrings(
        "C:\\50%20x",
        pwd_uri.parse("kitty-shell-cwd:///C:\\50%20x", &buf, opts).?,
    );
    // 같은 값을 `file://` 로 보냈다면 공백으로 디코딩돼 존재하지 않는 경로가 된다.
    try testing.expectEqualStrings(
        "C:\\50 x",
        pwd_uri.parse("file:///C:\\50%20x", &buf, opts).?,
    );
}
