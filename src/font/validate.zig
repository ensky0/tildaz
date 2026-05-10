//! `config.font.family` chain 의 entry 가 시스템에 없을 때 부르는 fatal helper.
//! Windows / macOS 동일 메시지 — chain 전체 dump + 미설치 entry 표시 + config
//! 경로 안내. 다른 config 에러들 (`shell_validate`, hotkey 등록 실패) 와 같은
//! 풍부한 형식으로 일관성 유지.
//!
//! 호출처:
//! - Windows: `windows_host.zig` 의 chain validation loop — `isFontAvailable`
//!   실패 시.
//! - macOS: `macos_font.zig` 의 `CTFontCreateWithName` / `CTFontCopyFamilyName`
//!   검증 실패 시.

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
    const cfg_path: []const u8 = paths.configPath(fba.allocator()) catch "(unknown)";

    var msg_buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&msg_buf);
    const w = fbs.writer();
    w.writeAll(line) catch {};
    w.writeAll("\n\nConfig path:\n  ") catch {};
    w.writeAll(cfg_path) catch {};

    dialog.showFatal(messages.config_error_title, fbs.getWritten());
}

/// `missing` 은 시스템에서 lookup 실패한 chain entry 이름. `chain` 은 사용자
/// config 의 font.family 전체 (UTF-8 raw). 본 함수는 dialog.showFatal 로
/// process 종료.
pub fn showNotFoundFatal(missing: []const u8, chain: []const []const u8) noreturn {
    var alloc_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&alloc_buf);
    const cfg_path: []const u8 = paths.configPath(fba.allocator()) catch "(unknown)";

    var msg_buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&msg_buf);
    const w = fbs.writer();
    w.print("Font not found: \"{s}\"\n\n", .{missing}) catch {};
    w.writeAll("config \"font.family\" chain (in order):\n") catch {};
    for (chain) |fam| {
        if (fam.len == 0) continue;
        const marker = if (std.mem.eql(u8, fam, missing)) " \u{2190} not installed" else "";
        w.print("  - \"{s}\"{s}\n", .{ fam, marker }) catch {};
    }
    w.writeAll(
        \\
        \\All families listed in font.family must be installed on the system.
        \\
        \\Config path:
        \\
    ) catch {};
    w.print("{s}\n", .{cfg_path}) catch {};

    dialog.showFatal(messages.config_error_title, fbs.getWritten());
}
