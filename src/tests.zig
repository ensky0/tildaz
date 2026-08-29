//! Repository-wide unit test root.
//!
//! Zig only collects tests from modules reached by the test root. The runtime
//! `main.zig` root does not reference its imports during test execution, so it
//! previously reported success with zero collected tests (#318). Keep every
//! source file that declares a test listed here, split into common and native
//! host modules.

const builtin = @import("builtin");
const std = @import("std");

test "aggregate root imports every common and native-host test module" {
    // Cross-platform modules (40 files).
    _ = @import("about.zig");
    _ = @import("box_drawing.zig");
    _ = @import("chrome_palette.zig");
    _ = @import("config.zig");
    _ = @import("command_menu.zig");
    _ = @import("dialog.zig");
    _ = @import("font/display_width.zig");
    _ = @import("font/ligature.zig");
    _ = @import("font/spec.zig");
    _ = @import("font/validate.zig");
    _ = @import("input_policy.zig");
    _ = @import("instance_context.zig");
    _ = @import("instances.zig");
    _ = @import("key_encode.zig");
    _ = @import("local_hostname.zig");
    _ = @import("log.zig");
    _ = @import("messages.zig");
    _ = @import("mouse_report.zig");
    _ = @import("pane_layout.zig");
    _ = @import("paths.zig");
    _ = @import("perf.zig");
    _ = @import("physical_key.zig");
    _ = @import("process_cwd.zig");
    _ = @import("pwd_uri.zig");
    _ = @import("renderer/cell_color.zig");
    _ = @import("renderer/cell_decoration.zig");
    _ = @import("root.zig");
    _ = @import("runtime.zig");
    _ = @import("scrollbar.zig");
    _ = @import("session_core.zig");
    _ = @import("shell_integration.zig");
    _ = @import("shortcut_sync.zig");
    _ = @import("stress.zig");
    _ = @import("stress/workload.zig");
    _ = @import("tab_icons.zig");
    _ = @import("tab_interaction.zig");
    _ = @import("tab_layout.zig");
    _ = @import("terminal_interaction.zig");
    _ = @import("ui_metrics.zig");
    _ = @import("version.zig");
    _ = @import("windows_input_adapter.zig");

    switch (builtin.os.tag) {
        .linux => {
            // Linux native modules (11 files).
            _ = @import("dialog/linux.zig");
            _ = @import("font/linux/font.zig");
            _ = @import("host/linux/dialog_layout.zig");
            _ = @import("host/linux/gbm.zig");
            _ = @import("host/linux/gl_atlas.zig");
            _ = @import("host/linux/gl_rects.zig");
            _ = @import("host/linux/gl_text.zig");
            _ = @import("host/linux/gsettings_hotkey.zig");
            _ = @import("host/linux/hotkey_format.zig");
            _ = @import("host/linux/kglobalaccel.zig");
            _ = @import("host/linux/instance_identity.zig");
            _ = @import("host/linux/shell_extension.zig");
            _ = @import("host/linux/sway_ipc.zig");
            _ = @import("host/linux/software_terminal.zig");
            _ = @import("host/linux/wayland_minimal.zig");
            _ = @import("host/linux/xkb.zig");
            _ = @import("shortcut_sync/linux.zig");
            _ = @import("terminal/posix/pty.zig");
        },
        .macos => {
            // macOS native modules (2 files).
            _ = @import("host/macos.zig");
            _ = @import("terminal/posix/pty.zig");
        },
        .windows => {
            // Windows native modules (4 files).
            _ = @import("dialog/windows.zig");
            _ = @import("font/windows/font.zig");
            _ = @import("instance_request/windows.zig");
            _ = @import("terminal/windows/pty.zig");
        },
        else => @compileError("unsupported test target"),
    }

    // This sentinel makes a zero-test regression impossible even if Zig's
    // import reachability rules change. The explicit inventory above protects
    // the actual module coverage.
    try std.testing.expect(true);
}
