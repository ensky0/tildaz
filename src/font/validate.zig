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
const dialog = @import("../dialog.zig");
const messages = @import("../messages.zig");
const paths = @import("../paths.zig");

/// `font.family` 가 string 이 아닐 때 (예: 구 schema 의 array). 메시지 +
/// runtime 에서 결정한 config path 한 줄.
pub fn showFamilyMustBeStringFatal() noreturn {
    showSchemaErrorFatal(messages.font_family_must_be_string_msg);
}

/// `font.glyph_fallback` 이 string 의 list 가 아닐 때 (다른 type, 또는 array
/// element 가 string 아닌 경우).
pub fn showGlyphFallbackMustBeListFatal() noreturn {
    showSchemaErrorFatal(messages.font_glyph_fallback_must_be_list_msg);
}

/// 단순 schema 위반 메시지 + Config path 라인 → fatal. 위 두 fn 의 공유 helper.
fn showSchemaErrorFatal(line: []const u8) noreturn {
    var alloc_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&alloc_buf);
    const cfg_path: []const u8 = paths.configPath(fba.allocator()) catch messages.unknown_path_msg;

    var msg_buf: [1024]u8 = undefined;
    dialog.showFatal(messages.config_error_title, schemaErrorMessage(&msg_buf, line, cfg_path));
}

fn schemaErrorMessage(msg_buf: []u8, line: []const u8, cfg_path: []const u8) []const u8 {
    var fbs = std.io.fixedBufferStream(msg_buf);
    const w = fbs.writer();
    w.writeAll(line) catch {};
    w.print(messages.font_schema_error_path_format, .{cfg_path}) catch {};
    return fbs.getWritten();
}

/// `missing` 은 시스템에서 lookup 실패한 chain entry 이름. `chain` 은 사용자
/// config 의 font.family 전체 (UTF-8 raw). 본 함수는 dialog.showFatal 로
/// process 종료.
pub fn showNotFoundFatal(missing: []const u8, chain: []const []const u8) noreturn {
    var msg_buf: [2048]u8 = undefined;
    dialog.showFatal(messages.config_error_title, notFoundMessage(&msg_buf, missing, chain));
}

/// `showNotFoundFatal` 의 메시지 조립부 — 세 OS 공통 형식의 단일 정의.
/// Linux host 는 boot 단계에서 자체 blocking overlay 로 표시해야 해서 dialog
/// 호출과 분리해 이 함수만 쓴다 (#289 B6).
pub fn notFoundMessage(msg_buf: []u8, missing: []const u8, chain: []const []const u8) []const u8 {
    var alloc_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&alloc_buf);
    const cfg_path: []const u8 = paths.configPath(fba.allocator()) catch messages.unknown_path_msg;

    return notFoundMessageWithPath(msg_buf, missing, chain, cfg_path);
}

fn notFoundMessageWithPath(msg_buf: []u8, missing: []const u8, chain: []const []const u8, cfg_path: []const u8) []const u8 {
    var fbs = std.io.fixedBufferStream(msg_buf);
    const w = fbs.writer();
    w.print(messages.font_not_found_format, .{missing}) catch {};
    w.writeAll(messages.font_chain_header_msg) catch {};
    for (chain) |fam| {
        if (fam.len == 0) continue;
        const marker = if (std.mem.eql(u8, fam, missing)) messages.font_not_installed_marker else "";
        w.print(messages.font_chain_entry_format, .{ fam, marker }) catch {};
    }
    w.print(messages.font_chain_footer_format, .{cfg_path}) catch {};
    return fbs.getWritten();
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
        notFoundMessageWithPath(&missing_buf, "Missing Font", &chain, "/tmp/config_3.json"),
    );
}
