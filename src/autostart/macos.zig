// macOS auto-start.
//
// macOS 13+ 는 Login Items / Background Items 를 ServiceManagement 의
// SMAppService 로 관리한다. TildaZ 의 최소 macOS 도 13 이므로 구식
// `~/Library/LaunchAgents` 직접 설치 대신 main app login item 을 등록한다.
//
// 사용자가 System Settings > General > Login Items & Extensions 에서 항목을
// 꺼 둔 경우 앱이 그 결정을 우회해서 다시 켤 수 없다. 이때 SMAppService
// status 는 `requires_approval` 이며, 우리는 로그에 명확히 남기고 사용자가
// 직접 켜야 하는 상태로 처리한다 (#192).

const std = @import("std");
const log = @import("../log.zig");
const objc = @import("../macos_objc.zig");

const LEGACY_LABEL = "com.tildaz.app";

const ServiceStatus = enum(isize) {
    not_registered = 0,
    enabled = 1,
    requires_approval = 2,
    not_found = 3,
    unknown = -1,

    fn label(self: ServiceStatus) []const u8 {
        return switch (self) {
            .not_registered => "not_registered",
            .enabled => "enabled",
            .requires_approval => "requires_approval",
            .not_found => "not_found",
            .unknown => "unknown",
        };
    }
};

/// legacy `~/Library/LaunchAgents/com.tildaz.app.plist` 경로. v0.4.3 중간
/// 빌드에서 생성된 plist 를 정리하기 위해 남겨 둔다.
fn legacyPlistPath(allocator: std.mem.Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
    const dir = try std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents", .{home});
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}.plist", .{ dir, LEGACY_LABEL });
}

pub fn enable(allocator: std.mem.Allocator) !void {
    const service = try mainAppService();
    const before = serviceStatus(service);
    log.appendLine("autostart", "main app service status before register: {s}", .{before.label()});

    switch (before) {
        .enabled => {
            cleanupLegacyLaunchAgent(allocator);
            return;
        },
        .requires_approval => {
            cleanupLegacyLaunchAgent(allocator);
            return error.LoginItemRequiresApproval;
        },
        .not_registered, .not_found, .unknown => {},
    }

    if (!registerService(service)) {
        const after_fail = serviceStatus(service);
        log.appendLine("autostart", "main app register failed; status after failure: {s}", .{after_fail.label()});
        cleanupLegacyLaunchAgent(allocator);
        if (after_fail == .requires_approval) return error.LoginItemRequiresApproval;
        if (after_fail == .enabled) return;
        return error.LoginItemRegisterFailed;
    }

    const after = serviceStatus(service);
    log.appendLine("autostart", "main app service status after register: {s}", .{after.label()});
    cleanupLegacyLaunchAgent(allocator);
    if (after == .requires_approval) return error.LoginItemRequiresApproval;
    if (after != .enabled) return error.LoginItemRegisterFailed;
}

pub fn disable(allocator: std.mem.Allocator) void {
    const service = mainAppService() catch |err| {
        log.appendLine("autostart", "main app service unavailable during disable: {s}", .{@errorName(err)});
        cleanupLegacyLaunchAgent(allocator);
        return;
    };

    const before = serviceStatus(service);
    log.appendLine("autostart", "main app service status before unregister: {s}", .{before.label()});
    if (before != .not_registered and before != .not_found) {
        if (!unregisterService(service)) {
            log.appendLine("autostart", "main app unregister failed; status after failure: {s}", .{serviceStatus(service).label()});
        }
    }
    cleanupLegacyLaunchAgent(allocator);
}

fn mainAppService() !objc.id {
    const SMAppService = objc.objc_getClass("SMAppService") orelse return error.ServiceManagementUnavailable;
    const mainAppServiceFn: *const fn (objc.Class, objc.SEL) callconv(.c) objc.id = @ptrCast(objc.msgSend_raw);
    return mainAppServiceFn(SMAppService, objc.sel("mainAppService")) orelse error.MainAppServiceUnavailable;
}

fn serviceStatus(service: objc.id) ServiceStatus {
    const statusFn: *const fn (objc.id, objc.SEL) callconv(.c) objc.NSInteger = @ptrCast(objc.msgSend_raw);
    const raw = statusFn(service, objc.sel("status"));
    return switch (raw) {
        0 => .not_registered,
        1 => .enabled,
        2 => .requires_approval,
        3 => .not_found,
        else => .unknown,
    };
}

fn registerService(service: objc.id) bool {
    const registerFn: *const fn (objc.id, objc.SEL, ?*objc.id) callconv(.c) objc.BOOL = @ptrCast(objc.msgSend_raw);
    return registerFn(service, objc.sel("registerAndReturnError:"), null);
}

fn unregisterService(service: objc.id) bool {
    const unregisterFn: *const fn (objc.id, objc.SEL, ?*objc.id) callconv(.c) objc.BOOL = @ptrCast(objc.msgSend_raw);
    return unregisterFn(service, objc.sel("unregisterAndReturnError:"), null);
}

fn cleanupLegacyLaunchAgent(allocator: std.mem.Allocator) void {
    const path = legacyPlistPath(allocator) catch return;
    defer allocator.free(path);
    if (std.fs.deleteFileAbsolute(path)) {
        log.appendLine("autostart", "removed legacy LaunchAgent plist: {s}", .{path});
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => log.appendLine("autostart", "failed to remove legacy LaunchAgent plist: {s}: {s}", .{ path, @errorName(err) }),
    }
}
