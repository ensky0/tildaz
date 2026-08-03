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

// ── PowerShell
//
// `PROMPT` 같은 환경변수로는 PowerShell 의 프롬프트를 바꿀 수 없다 (`prompt` 함수가
// 프롬프트를 만든다). 그래서 명령줄에 `-NoExit -EncodedCommand` 를 붙여 **프로필이
// 로드된 뒤** 기존 `prompt` 를 감싼다 — Windows 실기에서 프로필의 원래 프롬프트가
// 유지된 채 우리 조각만 앞에 붙는 것을 확인했다 (#366).
//
// `-Command "…"` 대신 `-EncodedCommand` 를 쓰는 이유: 셸 경계마다 인용 escape 규칙이
// 달라서 (`cmd` → `powershell.exe` 에서는 `\"`, 우리는 `CreateProcessW` 로 직접 spawn)
// 같은 문자열이 다르게 깨진다. Base64 는 그 문제가 원천적으로 없다.

/// 기존 `prompt` 를 감싸 OSC 7 을 앞에 붙이는 스크립트.
///
/// `$PWD.Provider.Name -eq 'FileSystem'` 검사가 필요하다 — PowerShell 은 `HKLM:` 같은
/// 레지스트리 위치로도 `cd` 할 수 있고, 그때 보고하면 파일시스템 경로가 아닌 값이 간다.
/// 경로는 `$PWD.ProviderPath` (provider 안의 실제 경로) 를 쓴다.
///
/// 종료자는 **BEL** (`$([char]7)`) 이다. ST (`ESC \`) 도 표준이지만 PowerShell 문자열에
/// `\` 를 넣으면 Zig · PowerShell 양쪽 escape 가 겹쳐 읽기 어려워지고, 파서는 둘 다
/// 받는다 (cmd 는 BEL 을 만들 수 없어서 그쪽만 ST 를 쓴다).
const ps_script =
    "$global:tzOrig=(Get-Item function:prompt).ScriptBlock; " ++
    "function global:prompt { $r=''; " ++
    "if ($PWD.Provider.Name -eq 'FileSystem') " ++
    "{ $r=\"$([char]27)]7;kitty-shell-cwd:///$($PWD.ProviderPath)$([char]7)\" }; " ++
    "$r + (& $global:tzOrig) }";

/// `-EncodedCommand` 가 받는 **UTF-16LE Base64**. 스크립트가 ASCII 뿐이라 각 바이트 뒤에
/// 0 을 넣으면 UTF-16LE 가 되고, 전부 comptime 에 계산되므로 런타임 조립이 없다.
pub const ps_encoded = blk: {
    var utf16: [ps_script.len * 2]u8 = undefined;
    for (ps_script, 0..) |c, i| {
        utf16[i * 2] = c;
        utf16[i * 2 + 1] = 0;
    }
    const Enc = std.base64.standard.Encoder;
    var out: [Enc.calcSize(utf16.len)]u8 = undefined;
    _ = Enc.encode(&out, &utf16);
    break :blk out;
};

/// 명령줄 맨 끝에 붙일 인자. `-NoExit` 는 스크립트 실행 후에도 대화형으로 남기 위한
/// 것이고, 사용자가 이미 줬어도 중복은 무해하다.
pub const ps_args = " -NoExit -EncodedCommand " ++ ps_encoded;

/// `CreateProcessW` 가 쓰는 UTF-16 형태. 여기서 미리 변환해 두므로 호출처 (Windows
/// backend) 는 상수를 참조만 한다 — 호출처에서 변환하면 comptime 평가 한도를 늘리는
/// `@setEvalBranchQuota` 가 Windows 전용 코드에 흩어진다.
pub const ps_args_w = blk: {
    @setEvalBranchQuota(10_000);
    break :blk std.unicode.utf8ToUtf16LeStringLiteral(ps_args);
};

pub const PsInjection = struct {
    /// 첫 토큰이 PowerShell 인가.
    is_powershell: bool,
    /// 주입해도 되는가. 사용자가 이미 실행할 명령 / 스크립트를 지정했으면 false —
    /// 우리 `-EncodedCommand` 와 충돌한다.
    inject: bool,
};

/// 이 명령줄이 PowerShell 탭인지, 주입해도 안전한지 판정한다. 첫 토큰 파싱 규칙은
/// `wslCdInsertion` 과 같다 (선행 `"` 지원, basename 비교).
///
/// **대소문자를 무시한다.** `wslCdInsertion` 은 Windows Terminal 의 동작을 그대로 따라
/// 정확 표기만 받지만, 여기는 따를 참조 대상이 없고 `PowerShell.exe` 같은 표기가 흔해서
/// 무시하는 쪽이 사용자에게 이롭다.
pub fn psInjection(cmd: []const u16) PsInjection {
    if (cmd.len == 0) return .{ .is_powershell = false, .inject = false };

    // 첫 토큰 경계 — `"` 로 시작하면 닫는 `"` 까지, 아니면 첫 공백까지.
    const quoted = cmd[0] == '"';
    const tok_start: usize = if (quoted) 1 else 0;
    var tok_end = tok_start;
    while (tok_end < cmd.len) : (tok_end += 1) {
        const ch = cmd[tok_end];
        if (quoted) {
            if (ch == '"') break;
        } else if (ch == ' ') break;
    }

    // 토큰의 파일 이름 = 마지막 경로 구분자 뒤.
    var base_start = tok_start;
    for (cmd[tok_start..tok_end], tok_start..) |ch, i| {
        if (ch == '\\' or ch == '/') base_start = i + 1;
    }
    const basename = cmd[base_start..tok_end];
    const is_powershell = eqlIgnoreCaseAscii(basename, "powershell") or
        eqlIgnoreCaseAscii(basename, "powershell.exe") or
        eqlIgnoreCaseAscii(basename, "pwsh") or
        eqlIgnoreCaseAscii(basename, "pwsh.exe");
    if (!is_powershell) return .{ .is_powershell = false, .inject = false };

    // 나머지 인자에 실행할 명령 / 스크립트 지정이 있으면 주입하지 않는다.
    var i = if (quoted and tok_end < cmd.len) tok_end + 1 else tok_end;
    while (i < cmd.len) {
        while (i < cmd.len and cmd[i] == ' ') i += 1;
        if (i >= cmd.len) break;
        const start = i;
        while (i < cmd.len and cmd[i] != ' ') i += 1;
        const tok = cmd[start..i];
        if (tok.len >= 2 and tok[0] == '-' and isCommandSwitch(tok[1..])) {
            return .{ .is_powershell = true, .inject = false };
        }
    }
    return .{ .is_powershell = true, .inject = true };
}

/// PowerShell 스위치는 **접두어로 줄여 쓸 수 있다** (`-Command` → `-c`). 그래서 정확
/// 비교가 아니라 "이름의 접두어인가" 로 판정한다. `-ExecutionPolicy` 처럼 접두어가 아닌
/// 것은 걸리지 않으므로 (그 사용자도 주입을 받는다) 과잉 차단이 아니다.
fn isCommandSwitch(name: []const u16) bool {
    if (name.len == 0) return false;
    for ([_][]const u8{ "command", "encodedcommand", "file" }) |full| {
        if (name.len > full.len) continue;
        if (eqlIgnoreCaseAscii(name, full[0..name.len])) return true;
    }
    return false;
}

/// UTF-16 (ASCII 범위) 과 ASCII 문자열의 대소문자 무시 비교. 비 ASCII 문자가 있으면
/// 불일치로 본다 — 셸 이름 / 스위치 이름은 모두 ASCII 다.
fn eqlIgnoreCaseAscii(wide: []const u16, ascii: []const u8) bool {
    if (wide.len != ascii.len) return false;
    for (wide, ascii) |w, a| {
        if (w > 127) return false;
        if (std.ascii.toLower(@intCast(w)) != std.ascii.toLower(a)) return false;
    }
    return true;
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

const L = std.unicode.utf8ToUtf16LeStringLiteral;

test "shell_integration — PowerShell 탭을 알아본다" {
    for ([_][:0]const u16{
        L("powershell.exe"),
        L("pwsh"),
        L("pwsh.exe"),
        L("PowerShell.exe -NoLogo"), // 대소문자 무시
        L("\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\" -NoLogo"),
        L("C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"),
    }) |cmd| {
        const r = psInjection(cmd);
        try testing.expect(r.is_powershell and r.inject);
    }

    for ([_][:0]const u16{
        L(""),
        L("cmd.exe"),
        L("wsl.exe -d Debian"),
        L("mypowershell.exe"), // basename 이 정확히 일치해야 한다
    }) |cmd| {
        try testing.expect(!psInjection(cmd).is_powershell);
    }
}

test "shell_integration — 사용자가 명령 / 스크립트를 지정했으면 주입하지 않는다" {
    for ([_][:0]const u16{
        L("powershell.exe -Command \"echo hi\""),
        L("powershell.exe -c foo"), // 접두어 축약
        L("pwsh -File a.ps1"),
        L("pwsh -f a.ps1"),
        L("powershell.exe -EncodedCommand AAAA"),
        L("powershell.exe -e AAAA"),
        L("powershell.exe -NoLogo -Command x"), // 뒤쪽 인자도 본다
    }) |cmd| {
        const r = psInjection(cmd);
        try testing.expect(r.is_powershell and !r.inject);
    }

    // 접두어가 아닌 스위치는 걸리지 않는다 — 이 사용자도 주입을 받는다.
    for ([_][:0]const u16{
        L("powershell.exe -ExecutionPolicy Bypass"),
        L("powershell.exe -NoLogo -NoProfile"),
        L("pwsh -WorkingDirectory C:\\"),
    }) |cmd| {
        const r = psInjection(cmd);
        try testing.expect(r.is_powershell and r.inject);
    }
}

test "shell_integration — PowerShell 스크립트가 UTF-16LE Base64 로 정확히 인코딩된다" {
    // Base64 를 되돌려 원본 스크립트와 같은지 본다 (comptime 계산이 맞는지 검증).
    const Dec = std.base64.standard.Decoder;
    const n = try Dec.calcSizeForSlice(&ps_encoded);
    var utf16_bytes: [ps_script.len * 2]u8 = undefined;
    try testing.expectEqual(utf16_bytes.len, n);
    try Dec.decode(&utf16_bytes, &ps_encoded);

    // UTF-16LE — ASCII 뒤에 0 바이트.
    for (ps_script, 0..) |c, i| {
        try testing.expectEqual(c, utf16_bytes[i * 2]);
        try testing.expectEqual(@as(u8, 0), utf16_bytes[i * 2 + 1]);
    }
    // 스크립트가 실제로 우리 스킴과 provider 검사를 담고 있는지.
    try testing.expect(std.mem.indexOf(u8, ps_script, "kitty-shell-cwd:///") != null);
    try testing.expect(std.mem.indexOf(u8, ps_script, "FileSystem") != null);
    try testing.expect(std.mem.indexOf(u8, ps_script, "$global:tzOrig") != null);
}

test "shell_integration — PowerShell 이 보낼 payload 를 파서가 읽는다" {
    var buf: [pwd_uri.max_path_len]u8 = undefined;
    // `$PWD.ProviderPath` 확장 결과 + BEL 종료. payload 는 종료자를 뺀 부분이다
    // (ghostty 가 OSC 를 잘라 넘긴다).
    try testing.expectEqualStrings(
        "C:\\Users\\me\\proj",
        pwd_uri.parse("kitty-shell-cwd:///C:\\Users\\me\\proj", &buf, .{
            .hostname = "MYPC",
            .style = .windows,
        }).?,
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
