//! 모든 사용자 표시 텍스트의 단일 진입점. cross-platform.
//!
//! 같은 의미의 메시지를 platform 별로 두 번 작성하지 않게 한다. format string
//! 은 여기서 정의하고 실제 표시는 호출처가 `dialog.zig` 로 위임.

pub const config_error_title = "TildaZ Config Error";
pub const about_title = "About TildaZ";
pub const error_title = "TildaZ Error";
pub const crash_title = "TildaZ Crash";
pub const info_title = "TildaZ";
pub const quit_confirm_title = "Quit TildaZ?";

/// 종료 확인 (#116). 한 번에 사라지는 탭 수를 본문에 박아 사용자가 잃을
/// 작업량을 즉시 인지하게. {s} 는 영어 복수형 처리 — count==1 이면 "" else "s".
pub const quit_confirm_format = "This will close {d} open tab{s}.";

/// About 다이얼로그 본문 — 양쪽 platform 동일 구조. version / exe / pid /
/// config / log 다음 Tip 라인에 OS 별 단축키 (Windows Ctrl+Shift+P/L vs macOS
/// Shift+Cmd+P/L) 가 들어감. 사용자가 dialog 안에서 path 를 직접 selection +
/// copy (mac NSTextView) 하거나 native Ctrl+C / Cmd+C 로 본문 전체 copy 후
/// path 만 골라낼 수 있고, Tip 의 단축키로 editor 를 바로 열 수도 있음.
pub const about_format =
    \\TildaZ v{s}
    \\
    \\exe   : {s}
    \\pid   : {d}
    \\config: {s}
    \\log   : {s}
    \\
    \\Tip: {s} opens config in default editor.
    \\     {s} opens log.
    \\
    \\https://github.com/ensky0/tildaz
;

pub const panic_format = "panic: {s}\nreturn address: 0x{x}";
pub const run_failed_format = "TildaZ failed to start.\n\nError: {s}";
pub const already_running_msg = "TildaZ is already running.";
pub const font_not_found_format = "Font not found: \"{s}\"";

/// glyph fallback chain 의 모든 명시 폰트 lookup 실패 — chain 비어있는 케이스
/// (사용자가 모두 잘못된 이름 명시) 등 edge. strict 검증 path 는 한 개 이름을
/// `font_not_found_format` 으로 표시 (Windows 동등).
pub const font_chain_all_failed_msg =
    \\None of the configured font families are available on this system.
    \\
    \\Tried:
;

pub const config_dir_create_failed_format =
    \\Failed to create config directory.
    \\
    \\Path: {s}
    \\Error: {s}
;

pub const config_default_write_failed_format =
    \\Failed to write default config file.
    \\
    \\Path: {s}
    \\Error: {s}
;

pub const config_read_failed_format =
    \\Failed to read config file.
    \\
    \\Path: {s}
    \\Error: {s}
;

pub const config_parse_failed_format =
    \\Failed to parse config JSON.
    \\
    \\Path: {s}
    \\Error: {s}
;
