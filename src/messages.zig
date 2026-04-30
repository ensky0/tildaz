//! 모든 사용자 표시 텍스트의 단일 진입점. cross-platform.
//!
//! 같은 의미의 메시지를 platform 별로 두 번 작성하지 않게 한다. format string
//! 은 여기서 정의하고 실제 표시는 호출처가 `dialog.zig` 로 위임.

pub const config_error_title = "TildaZ Config Error";
pub const about_title = "About TildaZ";
pub const error_title = "TildaZ Error";
pub const crash_title = "TildaZ Crash";
pub const info_title = "TildaZ";

pub const about_format =
    \\TildaZ v{s}
    \\
    \\exe   : {s}
    \\pid   : {d}
    \\config: {s}
    \\log   : {s}
    \\
    \\https://github.com/ensky0/tildaz
;

pub const panic_format = "panic: {s}\nreturn address: 0x{x}";
pub const run_failed_format = "TildaZ failed to start.\n\nError: {s}";
pub const already_running_msg = "TildaZ is already running.";
pub const font_not_found_format = "Font not found: \"{s}\"";

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
