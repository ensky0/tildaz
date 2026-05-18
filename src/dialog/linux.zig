//! Linux dialog backend — 임시 stderr 출력만. GUI 다이얼로그 (zenity /
//! kdialog / GTK MessageDialog) 통합은 L11 packaging 사이클에서. dialog.zig
//! 의 cross-platform 인터페이스 (show / showAboutAlert / showConfirm) 를
//! 만족시키는 최소 구현 — 사용자가 config 검증 fatal 등을 stderr 로 보고
//! `tildaz.log` 에도 자연스럽게 남는다 (host 가 log.appendLine 별도).

const std = @import("std");
const dialog = @import("../dialog.zig");

pub fn show(severity: dialog.Severity, title: []const u8, message: []const u8) void {
    const prefix = switch (severity) {
        .info => "info",
        .err => "error",
    };
    std.debug.print("[{s}] {s}\n{s}\n", .{ prefix, title, message });
}

pub fn showAboutAlert(title: []const u8, message: []const u8) void {
    show(.info, title, message);
}

/// "되돌릴 수 없는 작업" 직전 확인. GUI 없는 임시 backend 에서는 default
/// Cancel (= false) — 실수 종료 방지 정책 (#116) 동등. TTY 없는 환경에서
/// 사용자에게 묻지 않고 진행하면 안전 사고 가능.
pub fn showConfirm(title: []const u8, message: []const u8) bool {
    show(.info, title, message);
    return false;
}
