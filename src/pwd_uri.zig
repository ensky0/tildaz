//! OSC 7 (`report_pwd`) payload → 새 탭의 시작 디렉토리 경로 (#366). 순수 모듈 —
//! ghostty / OS API 의존 없이 `zig test src/pwd_uri.zig` 로 단독 실행된다.
//!
//! # 왜 우리가 해석하나
//!
//! OSC 파싱 자체는 `ghostty-vt` 가 다 하고 우리는 결과를 읽기만 한다 (OSC 0/2 제목은
//! `getTitle()`, OSC 11 배경색은 renderer). OSC 7 만 예외로 ghostty 가 **raw payload 를
//! 그대로 보관**하고 해석을 embedder 에게 넘긴다 — `stream_terminal.zig` 의 `reportPwd`
//! 주석: *"We store the raw payload unparsed. Embedders read it via getPwd() and are
//! responsible for decoding any URI scheme."* 그래서 이 모듈이 필요하다.
//!
//! payload 형태는 두 가지다.
//!
//! - `file://host/path` — 표준. host 와 path 가 퍼센트 인코딩된다 (fish 가 그렇게 보냄).
//! - `kitty-shell-cwd://host/path` — ghostty / kitty 셸 통합 스크립트가 쓰는 스킴.
//!   인코딩하지 않은 raw 경로를 보내므로 디코딩하지 않는다.
//!
//! # 왜 `std.Uri.parse` 를 쓰지 않나
//!
//! 퍼센트 디코딩은 `std.Uri.percentDecodeBackwards` 를 그대로 재사용하지만, **URI 파싱은
//! 직접 한다.** `std.Uri.parse` 를 쓰면 우리 입력에서 함정 두 개가 생기는 걸 실측으로
//! 확인했다 (아래 "std 동작 근거" 테스트가 이 두 동작을 고정한다).
//!
//! 1. **host 가 MAC 주소면 파싱이 실패한다.** macOS 의 *Private Wi-Fi address* 를 켜면
//!    hostname 이 회전하는 MAC 주소 (`12:34:56:78:90:aa`) 가 되고, `std.Uri.parse` 가
//!    마지막 옥텟을 포트 번호로 읽어 `error.InvalidPort` 를 낸다. ghostty 는 이걸 위해
//!    `src/os/uri.zig` 에 재파싱 wrapper 를 따로 뒀다 (그 모듈은 `ghostty-vt` 밖이라
//!    우리가 import 할 수 없다).
//! 2. **경로에 `?` 나 `#` 이 있으면 잘린다.** `file://h/dir/a?b` 의 path 가 `/dir/a` 가
//!    되고 `?b` 는 query 로 빠진다. 셸이 escape 를 빠뜨리면 경로가 조용히 짧아진다.
//!    ghostty 가 `raw_path` 옵션을 만든 이유가 이것이다.
//!
//! OSC 7 payload 에는 query / fragment 개념이 없고 규칙이 "스킴 → host → path" 세 조각뿐
//! 이라, `://` 와 첫 `/` 로 직접 자르면 위 두 함정이 애초에 생기지 않는다.
//!
//! # 깨진 퍼센트 인코딩
//!
//! `%` 뒤가 hex 두 자리가 아니면 `std.Uri` 는 그 자리를 리터럴로 남긴다 (거부하지 않음).
//! ghostty 도 같은 함수를 쓰므로 동작이 같다. 우리도 그대로 두고, 결과 경로가 실제로
//! 있는지는 호출자가 확인해 없으면 홈으로 열화한다 — escape 를 빠뜨리고 경로에 실제로
//! `%` 를 쓰는 셸이 있을 수 있어 여기서 거부하면 그 경로를 영영 못 쓴다.

const std = @import("std");

/// 결과 경로의 표기 방식. **탭의 셸 종류로 결정**되며 host OS 로 결정되지 않는다 —
/// Windows 의 WSL 탭은 셸이 Linux 경로 (`/home/me`) 를 보고하고 새 탭도 `wsl --cd`
/// 로 Linux 경로를 받으므로 `.posix` 다.
pub const Style = enum {
    /// `/home/me` 그대로.
    posix,
    /// `/C:/Users/me` → `C:\Users\me`.
    windows,
};

/// 경로 버퍼 권장 크기. Linux PATH_MAX (4096) + 스킴 / 인코딩 여유. 호출처가 스택에
/// 이만큼 잡아 `parse` 에 넘긴다.
pub const max_path_len = 4200;

pub const Options = struct {
    /// 이 머신의 hostname. ssh 안에서 온 OSC 7 은 그 경로가 이 머신에 없으므로
    /// 거부해야 한다. 빈 값이면 hostname 비교를 건너뛰고 빈 host / `localhost`
    /// 만 수락한다.
    hostname: []const u8 = "",
    style: Style,
};

/// `payload` 를 해석해 절대 경로를 `out` 에 쓰고 그 slice 를 돌려준다. 수락할 수 없는
/// payload 는 `null` — 호출자는 기존 동작 (홈 디렉토리) 으로 안전하게 열화한다.
///
/// 거부 조건: 모르는 스킴 / host 가 다른 머신 (ssh) / 절대 경로가 아님 / NUL 포함 /
/// `out` 부족.
pub fn parse(payload: []const u8, out: []u8, opts: Options) ?[]const u8 {
    const sep = std.mem.find(u8, payload, "://") orelse return null;
    const scheme = payload[0..sep];
    const rest = payload[sep + 3 ..];

    // `file` 은 퍼센트 인코딩, `kitty-shell-cwd` 는 raw. 그 외 스킴은 우리가 의미를
    // 모르므로 거부한다 (ghostty 의 `stream_handler.zig` 도 이 둘만 받는다).
    const encoded = if (std.ascii.eqlIgnoreCase(scheme, "file"))
        true
    else if (std.ascii.eqlIgnoreCase(scheme, "kitty-shell-cwd"))
        false
    else
        return null;

    // host 는 첫 `/` 앞까지. `/` 가 없으면 경로가 아예 없는 payload 라 거부.
    const slash = std.mem.findScalar(u8, rest, '/') orelse return null;
    if (!hostAccepted(rest[0..slash], opts.hostname, encoded)) return null;

    const path_raw = rest[slash..];
    // `percentDecodeBackwards` 는 출력 인덱스를 뒤에서 줄이며 채우므로 `out` 이
    // 입력보다 짧으면 underflow 로 panic 한다. 미리 막는다.
    if (path_raw.len > out.len) return null;

    // 디코딩 결과는 `out` 의 **뒤쪽**에 정렬된다 (`percentDecodeBackwards` 의 계약).
    // raw 스킴도 같은 자리에 두어 이후 처리가 한 갈래로 흐르게 한다.
    const head = out.len - path_raw.len;
    @memcpy(out[head..], path_raw);
    const path = if (encoded)
        std.Uri.percentDecodeBackwards(out, out[head..])
    else
        out[head..];

    // NUL 은 경로로 쓸 수 없다 (`chdir` / `lpCurrentDirectory` 모두 NUL 종단).
    // `%00` 으로 들어올 수 있어 디코딩 후에 검사한다.
    if (std.mem.findScalar(u8, path, 0) != null) return null;

    return switch (opts.style) {
        .posix => if (path.len > 0 and path[0] == '/') squeezeLeadingSlashes(path) else null,
        .windows => toWindowsPath(path, out),
    };
}

/// 우리 머신의 경로인지 판정. 수락: 빈 host (`file:///path`, 그리고 fish 가 Konsole
/// 대상으로 host 를 비우는 경우) · `localhost` · 우리 hostname.
///
/// hostname 비교는 **첫 라벨까지만** 한다 — FQDN 과 짧은 이름이 갈리는 환경에서도 같은
/// 머신의 경로를 살리기 위한 관용이다 (ghostty 의 `os/hostname.zig` `isLocal` 은 정확
/// 일치만 수락한다).
///
/// **이 관용은 확인된 필요가 아니라 여분이다.** 실측한 두 환경에서는 정확 일치로도
/// 통했다 (2026-08-03): macOS 26 에서 `hostname` · zsh `$HOST` · bash `$HOSTNAME` ·
/// fish `$hostname` 이 모두 `gethostname` 과 같은 `…​.local` 값이었고, Windows 의
/// `GetComputerNameW` 와 WSL Debian 안 `$hostname` 도 서로 같았다. 대가로 다른 머신인데
/// 첫 라벨이 같은 경우 (`mymac` ↔ `mymac.example.com`) 를 수락할 수 있는데, 그건 호출자의
/// 경로 존재 확인이 2차로 막는다 — 원격 경로가 이 머신에도 있어야 통과하기 때문이다.
fn hostAccepted(host_raw: []const u8, hostname: []const u8, encoded: bool) bool {
    // #451 — `std.Uri.host_name_max` 가 없어졌다. 같은 값 (255) 이 호스트 이름 타입 쪽으로
    // 옮겨졌다 (`std.Io.net.HostName.max_len` — DNS 이름 상한).
    var buf: [std.Io.net.HostName.max_len]u8 = undefined;
    if (host_raw.len > buf.len) return false;
    @memcpy(buf[buf.len - host_raw.len ..], host_raw);
    const host = if (encoded)
        std.Uri.percentDecodeBackwards(&buf, buf[buf.len - host_raw.len ..])
    else
        buf[buf.len - host_raw.len ..];

    if (host.len == 0) return true;
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (hostname.len == 0) return false;
    return std.ascii.eqlIgnoreCase(firstLabel(host), firstLabel(hostname));
}

/// 선행 슬래시가 겹친 경로를 하나로 줄인다 (`//home/me` → `/home/me`).
///
/// 보내는 쪽 템플릿의 실수를 흡수하는 방어다. 셸마다 경로 형태가 달라서 (`cmd` 의 `$P`
/// 는 `C:\…`, POSIX 의 `$PWD` 는 `/…`) `kitty-shell-cwd://` 뒤에 슬래시를 몇 개 두어야
/// 하는지가 갈리는데, 이걸 손으로 맞추다 틀리면 `//home/me` 같은 값이 나간다. POSIX 는
/// 선행 `//` 를 구현 정의로 두지만 Linux · macOS 는 `/` 와 같게 취급하므로 축약이 안전하다.
///
/// 경로 **안쪽**의 중복은 건드리지 않는다 — 우리가 만들 수 있는 실수는 앞부분에서만
/// 생기고, 안쪽까지 정규화하면 파서가 경로를 고쳐 쓰는 범위가 넓어진다.
fn squeezeLeadingSlashes(path: []const u8) []const u8 {
    var i: usize = 0;
    while (i + 1 < path.len and path[i] == '/' and path[i + 1] == '/') i += 1;
    return path[i..];
}

fn firstLabel(host: []const u8) []const u8 {
    const dot = std.mem.findScalar(u8, host, '.') orelse return host;
    return host[0..dot];
}

/// `/C:/Users/me` → `C:\Users\me`.
///
/// `path` 는 `out` 뒤쪽의 slice 라 결과를 `out` **앞쪽으로 당겨** 쓴다. 뒤쪽에 그대로
/// 두면 드라이브 루트 정규화 (`C:` → `C:\`) 에서 한 바이트 늘릴 자리가 없다.
///
/// 드라이브 문자로 시작하지 않으면 거부한다 (Windows 탭에 POSIX 경로가 오면 쓸 수
/// 없다). UNC (`file://server/share`) 는 host 가 우리 머신이 아니라 `hostAccepted`
/// 에서 이미 걸린다.
fn toWindowsPath(path: []const u8, out: []u8) ?[]const u8 {
    // 선행 `/` 하나를 뺀 나머지가 `X:` 로 시작해야 한다.
    if (path.len < 3 or path[0] != '/') return null;
    const body = path[1..];
    if (!std.ascii.isAlphabetic(body[0]) or body[1] != ':') return null;

    std.mem.copyForwards(u8, out[0..body.len], body);
    var result = out[0..body.len];
    for (result) |*c| {
        if (c.* == '/') c.* = '\\';
    }

    // `C:` 만 남으면 drive-relative 경로 (그 드라이브의 *현재* 위치) 라 시작
    // 디렉토리로 쓰면 어디로 갈지 모른다. 드라이브 루트로 정규화한다.
    if (result.len == 2) {
        if (out.len < 3) return null;
        out[2] = '\\';
        result = out[0..3];
    }
    return result;
}

// ── 테스트

const testing = std.testing;

/// PATH_MAX (4096) + 여유. 실제 호출처도 이 정도 버퍼를 준다.
var test_buf: [4200]u8 = undefined;

fn parsePosix(payload: []const u8, hostname: []const u8) ?[]const u8 {
    return parse(payload, &test_buf, .{ .hostname = hostname, .style = .posix });
}

fn parseWindows(payload: []const u8, hostname: []const u8) ?[]const u8 {
    return parse(payload, &test_buf, .{ .hostname = hostname, .style = .windows });
}

test "pwd_uri — file:// 기본 형태" {
    try testing.expectEqualStrings("/home/me", parsePosix("file://myhost/home/me", "myhost").?);
    // 빈 host — `file:///path` 와 fish 의 Konsole 대상 출력이 모두 이 형태.
    try testing.expectEqualStrings("/home/me", parsePosix("file:///home/me", "myhost").?);
    try testing.expectEqualStrings("/home/me", parsePosix("file://localhost/home/me", "myhost").?);
    // 루트도 유효한 경로.
    try testing.expectEqualStrings("/", parsePosix("file://myhost/", "myhost").?);
}

test "pwd_uri — 선행 슬래시가 겹쳐도 경로가 깨지지 않는다" {
    // 보내는 쪽 템플릿이 `:///` + `$PWD` 처럼 슬래시를 하나 더 두면 이런 값이 온다.
    try testing.expectEqualStrings("/home/me", parsePosix("file://myhost//home/me", "myhost").?);
    try testing.expectEqualStrings("/home/me", parsePosix("file://myhost///home/me", "myhost").?);
    // 경로 안쪽 중복은 그대로 둔다 (파서가 경로를 고쳐 쓰는 범위를 앞부분으로 제한).
    try testing.expectEqualStrings("/home//me", parsePosix("file://myhost/home//me", "myhost").?);
    // 루트만 온 경우를 빈 문자열로 만들지 않는다.
    try testing.expectEqualStrings("/", parsePosix("file://myhost//", "myhost").?);
}

test "pwd_uri — host 검사로 ssh 원격 경로를 거부" {
    try testing.expect(parsePosix("file://otherbox/home/me", "myhost") == null);
    // hostname 을 모르면 (빈 값) 빈 host / localhost 만 수락.
    try testing.expect(parsePosix("file://myhost/home/me", "") == null);
    try testing.expectEqualStrings("/home/me", parsePosix("file:///home/me", "").?);
}

test "pwd_uri — hostname 표기가 FQDN / 짧은 이름으로 갈려도 첫 라벨로 흡수" {
    // 실측한 환경들에서는 양쪽이 같았다 (`hostAccepted` doc 참조) — 갈리는 환경을 위한
    // 관용이라 여기서만 인위적으로 다르게 준다.
    try testing.expectEqualStrings("/home/me", parsePosix("file://mymac/home/me", "mymac.local").?);
    try testing.expectEqualStrings("/home/me", parsePosix("file://mymac.local/home/me", "mymac").?);
    // 대소문자 무시 (DNS 규칙).
    try testing.expectEqualStrings("/home/me", parsePosix("file://MyMac/home/me", "mymac").?);
    // 첫 라벨이 다르면 여전히 거부.
    try testing.expect(parsePosix("file://mymac2.local/home/me", "mymac") == null);
}

test "pwd_uri — 퍼센트 디코딩" {
    try testing.expectEqualStrings("/home/me/my dir", parsePosix("file://myhost/home/me/my%20dir", "myhost").?);
    // 한글 (UTF-8 3바이트) — 두 셸 모두 URL escape 해서 보낸다.
    try testing.expectEqualStrings("/home/me/한글", parsePosix("file://myhost/home/me/%ED%95%9C%EA%B8%80", "myhost").?);
    try testing.expectEqualStrings("/home/me/100%", parsePosix("file://myhost/home/me/100%25", "myhost").?);
    // host 쪽 인코딩도 디코딩해서 비교.
    try testing.expectEqualStrings("/home/me", parsePosix("file://my%68ost/home/me", "myhost").?);
}

test "pwd_uri — 깨진 퍼센트 인코딩은 리터럴로 남긴다" {
    // std.Uri · ghostty 와 같은 동작. 결과 경로가 없으면 호출자가 홈으로 열화한다.
    try testing.expectEqualStrings("/home/me/50%", parsePosix("file://myhost/home/me/50%", "myhost").?);
    try testing.expectEqualStrings("/home/me/50%zz", parsePosix("file://myhost/home/me/50%zz", "myhost").?);
}

test "pwd_uri — kitty-shell-cwd 는 디코딩하지 않는다" {
    try testing.expectEqualStrings("/home/me", parsePosix("kitty-shell-cwd://myhost/home/me", "myhost").?);
    // 이 스킴은 raw 경로를 보내므로 `%20` 은 경로에 실제로 있는 문자다.
    try testing.expectEqualStrings("/home/me/a%20b", parsePosix("kitty-shell-cwd://myhost/home/me/a%20b", "myhost").?);
    try testing.expectEqualStrings("/home/me/한글", parsePosix("kitty-shell-cwd://myhost/home/me/한글", "myhost").?);
}

test "pwd_uri — 모르는 스킴 / 형태가 아닌 payload 는 거부" {
    try testing.expect(parsePosix("", "myhost") == null);
    try testing.expect(parsePosix("/home/me", "myhost") == null);
    try testing.expect(parsePosix("http://myhost/home/me", "myhost") == null);
    // 스킴은 대소문자 무시.
    try testing.expectEqualStrings("/home/me", parsePosix("FILE://myhost/home/me", "myhost").?);
    // host 뒤에 경로가 없음.
    try testing.expect(parsePosix("file://myhost", "myhost") == null);
    // 상대 경로 (path 가 `/` 로 시작하지 않는 형태는 host/path 분리에서 걸린다).
    try testing.expect(parsePosix("file://home/me", "myhost") == null);
}

test "pwd_uri — NUL 은 거부" {
    try testing.expect(parsePosix("file://myhost/home/%00me", "myhost") == null);
    try testing.expect(parsePosix("kitty-shell-cwd://myhost/home/\x00me", "myhost") == null);
}

test "pwd_uri — out 버퍼가 모자라면 거부" {
    var small: [8]u8 = undefined;
    try testing.expect(parse("file://myhost/home/me/deep/path", &small, .{
        .hostname = "myhost",
        .style = .posix,
    }) == null);
}

test "pwd_uri — Windows 경로 변환" {
    try testing.expectEqualStrings("C:\\Users\\me", parseWindows("file:///C:/Users/me", "myhost").?);
    try testing.expectEqualStrings("C:\\Users\\me", parseWindows("file://myhost/C:/Users/me", "myhost").?);
    try testing.expectEqualStrings("D:\\work\\my dir", parseWindows("file:///D:/work/my%20dir", "myhost").?);
    // 드라이브 루트.
    try testing.expectEqualStrings("C:\\", parseWindows("file:///C:/", "myhost").?);
    // `C:` 만 오면 drive-relative — 루트로 정규화.
    try testing.expectEqualStrings("C:\\", parseWindows("file:///C:", "myhost").?);
    // 드라이브 문자가 없으면 거부 (Windows 탭에 POSIX 경로가 오면 쓸 수 없다).
    try testing.expect(parseWindows("file:///home/me", "myhost") == null);
}

test "pwd_uri — WSL 탭은 Linux 경로라 .posix 로 해석" {
    // 셸이 WSL 안에 있으므로 host OS 가 Windows 여도 경로 표기는 POSIX 다.
    try testing.expectEqualStrings("/home/me/work", parsePosix("file://myhost/home/me/work", "myhost").?);
}

// ── std 동작 근거 — 이 두 테스트는 모듈 doc 의 "왜 `std.Uri.parse` 를 쓰지 않나" 를
// 고정한다. std 가 동작을 바꾸면 여기서 깨지고, 그때 직접 파싱을 유지할지 다시 판단할
// 근거가 된다.

test "pwd_uri — std.Uri.parse 는 MAC 주소 host 에서 실패하지만 우리는 수락한다" {
    // macOS 의 Private Wi-Fi address 를 켜면 hostname 이 회전하는 MAC 주소가 된다.
    const payload = "file://12:34:56:78:90:aa/home/me";
    try testing.expectError(error.InvalidPort, std.Uri.parse(payload));
    try testing.expectEqualStrings("/home/me", parsePosix(payload, "12:34:56:78:90:aa").?);
}

test "pwd_uri — std.Uri.parse 는 경로의 ? · # 를 잘라내지만 우리는 보존한다" {
    {
        const uri = try std.Uri.parse("file://myhost/home/me/a?b");
        try testing.expectEqualStrings("/home/me/a", uri.path.percent_encoded);
        try testing.expectEqualStrings("/home/me/a?b", parsePosix("file://myhost/home/me/a?b", "myhost").?);
    }
    {
        const uri = try std.Uri.parse("file://myhost/home/me/a#b");
        try testing.expectEqualStrings("/home/me/a", uri.path.percent_encoded);
        try testing.expectEqualStrings("/home/me/a#b", parsePosix("file://myhost/home/me/a#b", "myhost").?);
    }
}
