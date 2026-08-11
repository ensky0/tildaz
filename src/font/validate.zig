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

/// `font.family` 가 string 이 아닐 때 (예: 구 schema 의 array). 메시지 +
/// runtime 에서 결정한 config path 한 줄.
pub fn showFamilyMustBeStringFatal(rt: Runtime) noreturn {
    showSchemaErrorFatal(rt, messages.font_family_must_be_string_msg);
}

/// `font.glyph_fallback` 이 string 의 list 가 아닐 때 (다른 type, 또는 array
/// element 가 string 아닌 경우).
pub fn showGlyphFallbackMustBeListFatal(rt: Runtime) noreturn {
    showSchemaErrorFatal(rt, messages.font_glyph_fallback_must_be_list_msg);
}

/// 단순 schema 위반 메시지 + Config path 라인 → fatal. 위 두 fn 의 공유 helper.
fn showSchemaErrorFatal(rt: Runtime, line: []const u8) noreturn {
    var alloc_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&alloc_buf);
    const cfg_path: []const u8 = paths.configPath(rt, fba.allocator()) catch messages.unknown_path_msg;

    var msg_buf: [1024]u8 = undefined;
    dialog.showFatal(messages.config_error_title, schemaErrorMessage(&msg_buf, line, cfg_path));
}

fn schemaErrorMessage(msg_buf: []u8, line: []const u8, cfg_path: []const u8) []const u8 {
    var fbs: std.Io.Writer = .fixed(msg_buf);
    const w = &fbs;
    w.writeAll(line) catch {};
    w.print(messages.font_schema_error_path_format, .{cfg_path}) catch {};
    return fbs.buffered();
}

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
    dialog.showFatal(messages.config_error_title, notFoundMessageSub(rt, &msg_buf, missing, chain, substitute));
}

/// `showNotFoundFatal` 의 메시지 조립부 — 세 OS 공통 형식의 단일 정의.
/// Linux host 는 boot 단계에서 자체 blocking overlay 로 표시해야 해서 dialog
/// 호출과 분리해 이 함수만 쓴다 (#289 B6).
pub fn notFoundMessage(rt: Runtime, msg_buf: []u8, missing: []const u8, chain: []const []const u8) []const u8 {
    return notFoundMessageSub(msg_buf, missing, chain, null);
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
    w.print(messages.font_chain_footer_format, .{cfg_path}) catch {};
    return fbs.buffered();
}

test "font validation messages preserve runtime values and final newline" {
    var schema_buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Invalid config: font.family must be a string (font name).\n\nConfig path:\n  /tmp/config_3.json",
        schemaErrorMessage(
            &schema_buf,
            messages.font_family_must_be_string_msg,
            "/tmp/config_3.json",
        ),
    );

    var missing_buf: [1024]u8 = undefined;
    const chain = [_][]const u8{ "DejaVu Sans Mono", "Missing Font", "Noto Color Emoji" };
    try std.testing.expectEqualStrings(
        "Font not found: \"Missing Font\"\n\n" ++
            "config \"font.family\" chain (in order):\n" ++
            "  - \"DejaVu Sans Mono\"\n" ++
            "  - \"Missing Font\" ← not installed\n" ++
            "  - \"Noto Color Emoji\"\n" ++
            "\nAll families listed in font.family must be installed on the system.\n\n" ++
            "Config path:\n/tmp/config_3.json\n",
        notFoundMessageForPath(&missing_buf, "Missing Font", &chain, "/tmp/config_3.json", null),
    );
}
