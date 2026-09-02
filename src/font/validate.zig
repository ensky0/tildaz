//! `config.font.family` chain 의 entry 가 시스템에 없을 때 부르는 fatal helper.
//! 세 OS 동일 메시지 — chain 전체 dump + 미설치 entry 표시 + config 경로 안내.
//! 다른 config 에러들 (`shell_validate`, hotkey 등록 실패) 와 같은 풍부한
//! 형식으로 일관성 유지.
//!
//! 호출처:
//! - Windows: `windows_host.zig` 의 chain validation loop — `isFontAvailable`
//!   실패 시.
//! - macOS: `macos_font.zig` 의 `CTFontCreateWithName` / `CTFontCopyFamilyName`
//!   검증 실패 시.
//! - Linux: `wayland_minimal.zig` 의 boot 검증 (#289 B6) — fontconfig lookup
//!   substitution 판정 실패 시. dialog 는 host 자체 blocking overlay
//!   (`runFatalDialog`) 라 `notFoundMessage` 만 사용 (C2 패턴 — boot 단계
//!   fire-and-forget `showFatal` 은 paint 전에 죽음).

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const dialog = @import("../dialog.zig");
const messages = @import("../messages.zig");
const paths = @import("../paths.zig");

// #577 — `font.family` / `font.glyph_fallback` 의 **schema** 위반 (string 이
// 아님 · list 가 아님) 은 이 파일을 더 이상 지나지 않는다. 두 가지가 바뀌었다.
//
// (1) 그 검증은 config 파싱 안에서 도는데, 그 시점의 Linux 에는 dialog backend 가
//     없어 여기서 `dialog.showFatal` 을 부르면 안내가 stderr 로만 갔다. 이제
//     `config.zig` 가 문구를 담아 두고 host 가 그릴 수 있게 된 뒤 띄운다.
// (2) 문구 조립도 `config.zig` 의 `recordConfigFatalMsg` 한 곳으로 모았다. 여기서
//     만들면 경로를 `paths.configPath` 로 **다시 조회**해야 했는데, 파싱 중인 파일의
//     경로는 이미 인자로 들어와 있다. 다시 조회하면 instance 번호와 실제 파일이
//     갈릴 수 있다 (#316 의 교훈).
//
// 문구 상수 자체 (`messages.font_family_must_be_string_msg` 등) 는 그대로다 —
// `config.zig` 가 그것을 `recordConfigFatalMsg` 에 넘긴다.

/// `missing` 은 시스템에서 lookup 실패한 chain entry 이름. `chain` 은 사용자
/// config 의 font.family 전체 (UTF-8 raw). 본 함수는 dialog.showFatal 로
/// process 종료.
pub fn showNotFoundFatal(rt: Runtime, missing: []const u8, chain: []const []const u8) noreturn {
    showNotFoundFatalSub(rt, missing, chain, null);
}

/// #405 — `substitute` 는 **그 이름이 실제로 어떤 폰트로 해석됐는지**다. 있으면 "설치는 됐는데
/// 다른 것으로 바뀐다" 를 함께 알린다.
///
/// 세 platform 중 **Linux · macOS 만** 이 값을 채운다. 둘은 요청 이름으로 조회한 뒤 *돌아온
/// family 를 비교*하는 구조라 (Linux 는 fontconfig substitution, macOS 는
/// `CTFontCreateWithName` 이 실패 대신 대체 폰트를 주는 성질) 대체가 실제로 일어난다. Windows 는
/// `IDWriteFontCollection.FindFamilyName` 이 시스템 컬렉션에서 exact match 만 보므로 대체가
/// 개입할 여지가 없어 `null` 이다.
pub fn showNotFoundFatalSub(rt: Runtime, missing: []const u8, chain: []const []const u8, substitute: ?[]const u8) noreturn {
    var msg_buf: [2048]u8 = undefined;
    dialog.showFatal(rt, messages.config_error_title, notFoundMessageSub(rt, &msg_buf, missing, chain, substitute));
}

/// `showNotFoundFatal` 의 메시지 조립부 — 세 OS 공통 형식의 단일 정의.
/// Linux host 는 boot 단계에서 자체 blocking overlay 로 표시해야 해서 dialog
/// 호출과 분리해 이 함수만 쓴다 (#289 B6).
pub fn notFoundMessage(rt: Runtime, msg_buf: []u8, missing: []const u8, chain: []const []const u8) []const u8 {
    return notFoundMessageSub(rt, msg_buf, missing, chain, null);
}

/// #405 — `substitute` 가 있으면 "설치는 됐는데 fontconfig 가 다른 폰트로 바꿨다" 를 함께
/// 알린다. Linux host 만 채우고 (fontconfig 특유), 나머지 platform 은 `null` 로 기존 형식이다.
pub fn notFoundMessageSub(rt: Runtime, msg_buf: []u8, missing: []const u8, chain: []const []const u8, substitute: ?[]const u8) []const u8 {
    var alloc_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&alloc_buf);
    const cfg_path: []const u8 = paths.configPath(rt, fba.allocator()) catch messages.unknown_path_msg;

    return notFoundMessageForPath(msg_buf, missing, chain, cfg_path, substitute);
}

/// 경로 조회와 분리한 순수 formatter. dialog layout 같은 사용자 메시지 경계
/// 테스트도 이 함수를 사용해 실제 producer와 다른 문구를 복제하지 않는다.
pub fn notFoundMessageForPath(msg_buf: []u8, missing: []const u8, chain: []const []const u8, cfg_path: []const u8, substitute: ?[]const u8) []const u8 {
    var fbs: std.Io.Writer = .fixed(msg_buf);
    const w = &fbs;
    // #577 — 경로가 **첫 줄**이다 (#495). 예전에는 맨 끝 footer 였다. 본문을 writer 로
    // 쌓는 구조라 `config_error_with_path_format` 을 한 번에 print 할 수 없어서, 접두만
    // 뺀 `config_error_path_prefix_format` 을 쓴다 — 다른 config 오류와 같은 첫 줄이다.
    w.print(messages.config_error_path_prefix_format, .{cfg_path}) catch {};
    w.print(messages.font_not_found_format, .{missing}) catch {};
    w.writeAll(messages.font_chain_header_msg) catch {};
    for (chain) |fam| {
        if (fam.len == 0) continue;
        const marker = if (std.mem.eql(u8, fam, missing)) messages.font_not_installed_marker else "";
        w.print(messages.font_chain_entry_format, .{ fam, marker }) catch {};
    }
    // #405 — 설치는 됐는데 대체된 경우, 그 사실과 확인 방법을 알린다. 이게 없으면 사용자는
    // 파일도 있고 목록에도 나오는 폰트가 왜 "not found" 인지 알 수 없다.
    if (substitute) |sub| {
        if (sub.len > 0 and !std.mem.eql(u8, sub, missing)) {
            w.print(messages.font_substituted_format, .{ sub, missing }) catch {};
        }
    }
    w.writeAll(messages.font_chain_footer_msg) catch {};
    return fbs.buffered();
}

test "font validation messages preserve runtime values and final newline" {
    var missing_buf: [1024]u8 = undefined;
    const chain = [_][]const u8{ "DejaVu Sans Mono", "Missing Font", "Noto Color Emoji" };
    // #577 — 경로가 **첫 줄**이다 (#495). 예전에는 맨 끝 `Config path:` 였고,
    // 폰트 schema 오류는 또 다른 자기 형식 (`  ` 들여쓰기) 이라 세 갈래였다.
    try std.testing.expectEqualStrings(
        "Config: /tmp/config_3.json\n\n" ++
            "Font not found: \"Missing Font\"\n\n" ++
            "config \"font.family\" chain (in order):\n" ++
            "  - \"DejaVu Sans Mono\"\n" ++
            "  - \"Missing Font\" ← not installed\n" ++
            "  - \"Noto Color Emoji\"\n" ++
            "\nAll families listed in font.family must be installed on the system.\n",
        notFoundMessageForPath(&missing_buf, "Missing Font", &chain, "/tmp/config_3.json", null),
    );
    // 경로는 정확히 한 번만 나온다 — 접두로 옮기면서 footer 에서 뺐다.
    const message = notFoundMessageForPath(&missing_buf, "Missing Font", &chain, "/tmp/config_3.json", null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, message, "/tmp/config_3.json"));
}

test "#577 폰트 schema 오류도 다른 config 오류와 같은 첫 줄을 쓴다" {
    // 이 문구는 이제 `config.zig` 의 `recordConfigFatalMsg` 가 조립한다. 여기서는
    // 그 조립이 지나는 공통 형식만 고정한다 — 세 갈래였던 형식이 하나로 모였다는
    // 사실이 test 로 남아야 한다 (#495 가 노렸고 #577 이 마무리한 지점).
    var buf: [512]u8 = undefined;
    const message = try std.fmt.bufPrint(
        &buf,
        messages.config_error_with_path_format,
        .{ "/tmp/config_3.toml", messages.font_family_must_be_string_msg },
    );
    try std.testing.expectEqualStrings(
        "Config: /tmp/config_3.toml\n\n" ++
            "Invalid config: font.family must be a string (font name).",
        message,
    );
}
