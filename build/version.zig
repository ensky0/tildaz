const std = @import("std");

pub const Error = std.mem.Allocator.Error || error{
    InvalidSemanticVersion,
    BuildMetadataUnsupported,
    UnsupportedPrerelease,
    InvalidPrereleaseNumber,
    PlatformVersionOutOfRange,
};

pub const Stage = enum {
    dev,
    alpha,
    beta,
    rc,

    fn appleSuffix(self: Stage) []const u8 {
        return switch (self) {
            .dev => "d",
            .alpha => "a",
            .beta => "b",
            .rc => "fc",
        };
    }

    fn windowsBase(self: Stage) u16 {
        return switch (self) {
            .dev => 0,
            .alpha => 256,
            .beta => 512,
            .rc => 768,
        };
    }
};

pub const Prerelease = struct {
    stage: Stage,
    number: u8,
};

pub const Derived = struct {
    full: []const u8,
    semantic: std.SemanticVersion,
    core: []const u8,
    prerelease: ?Prerelease,

    macos_short: []const u8,
    macos_build: []const u8,

    windows_major: u16,
    windows_minor: u16,
    windows_patch: u16,
    windows_revision: u16,
    windows_file_flags: u32,

    debian_package: []const u8,
    rpm_package: []const u8,
    arch_package: []const u8,

    pub fn isPrerelease(self: Derived) bool {
        return self.prerelease != null;
    }

    pub fn deinit(self: Derived, allocator: std.mem.Allocator) void {
        allocator.free(self.core);
        allocator.free(self.macos_build);
        allocator.free(self.debian_package);
        allocator.free(self.rpm_package);
        allocator.free(self.arch_package);
    }
};

pub fn derive(allocator: std.mem.Allocator, text: []const u8) Error!Derived {
    const semantic = std.SemanticVersion.parse(text) catch return error.InvalidSemanticVersion;
    if (semantic.build != null) return error.BuildMetadataUnsupported;

    // Windows VERSIONINFO는 네 개의 u16이고, Apple CFBundleVersion은 첫 항목
    // 1..9999 / 뒤 두 항목 0..99를 요구한다. 세 플랫폼에서 같은 원본을 안전하게
    // 파생할 수 없는 version은 build graph 생성 시 바로 거부한다.
    if (semantic.major > std.math.maxInt(u16) or
        semantic.minor > std.math.maxInt(u16) or
        semantic.patch > std.math.maxInt(u16) or
        semantic.major + 1 > 9999 or
        semantic.minor > 99 or
        semantic.patch > 99)
    {
        return error.PlatformVersionOutOfRange;
    }

    const prerelease = if (semantic.pre) |pre| try parsePrerelease(pre) else null;
    const core = try std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{
        semantic.major,
        semantic.minor,
        semantic.patch,
    });
    errdefer allocator.free(core);

    const macos_build = if (prerelease) |pre|
        try std.fmt.allocPrint(allocator, "{d}.{d}.{d}{s}{d}", .{
            semantic.major + 1,
            semantic.minor,
            semantic.patch,
            pre.stage.appleSuffix(),
            pre.number,
        })
    else
        try std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{
            semantic.major + 1,
            semantic.minor,
            semantic.patch,
        });
    errdefer allocator.free(macos_build);

    const debian_package = if (semantic.pre) |pre|
        try std.fmt.allocPrint(allocator, "{s}~{s}-1", .{ core, pre })
    else
        try std.fmt.allocPrint(allocator, "{s}-1", .{core});
    errdefer allocator.free(debian_package);

    const rpm_package = if (semantic.pre) |pre|
        try std.fmt.allocPrint(allocator, "{s}~{s}", .{ core, pre })
    else
        try allocator.dupe(u8, core);
    errdefer allocator.free(rpm_package);

    // Arch pkgver는 '-'를 허용하지 않는다. prerelease 식별자를 core 뒤에
    // 바로 붙이면 vercmp의 `1.0rc < 1.0` 규칙과 같은 순서를 유지한다.
    const arch_package = if (semantic.pre) |pre|
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ core, pre })
    else
        try allocator.dupe(u8, core);
    errdefer allocator.free(arch_package);

    const windows_revision: u16 = if (prerelease) |pre|
        pre.stage.windowsBase() + @as(u16, pre.number)
    else
        std.math.maxInt(u16);

    return .{
        .full = text,
        .semantic = semantic,
        .core = core,
        .prerelease = prerelease,
        .macos_short = core,
        .macos_build = macos_build,
        .windows_major = @intCast(semantic.major),
        .windows_minor = @intCast(semantic.minor),
        .windows_patch = @intCast(semantic.patch),
        .windows_revision = windows_revision,
        // VS_FF_PRERELEASE = 0x00000002.
        .windows_file_flags = if (prerelease != null) 0x2 else 0x0,
        .debian_package = debian_package,
        .rpm_package = rpm_package,
        .arch_package = arch_package,
    };
}

fn parsePrerelease(text: []const u8) Error!Prerelease {
    var fields = std.mem.splitScalar(u8, text, '.');
    const stage_text = fields.next() orelse return error.UnsupportedPrerelease;
    const number_text = fields.next() orelse return error.UnsupportedPrerelease;
    if (fields.next() != null) return error.UnsupportedPrerelease;

    const stage: Stage = if (std.mem.eql(u8, stage_text, "dev"))
        .dev
    else if (std.mem.eql(u8, stage_text, "alpha"))
        .alpha
    else if (std.mem.eql(u8, stage_text, "beta"))
        .beta
    else if (std.mem.eql(u8, stage_text, "rc"))
        .rc
    else
        return error.UnsupportedPrerelease;

    const number = std.fmt.parseUnsigned(u16, number_text, 10) catch
        return error.InvalidPrereleaseNumber;
    if (number == 0 or number > 255) return error.InvalidPrereleaseNumber;

    return .{ .stage = stage, .number = @intCast(number) };
}

test "derive dev prerelease for every platform" {
    const allocator = std.testing.allocator;
    const version = try derive(allocator, "0.6.2-dev.1");
    defer version.deinit(allocator);

    try std.testing.expectEqualStrings("0.6.2-dev.1", version.full);
    try std.testing.expectEqualStrings("0.6.2", version.core);
    try std.testing.expectEqualStrings("0.6.2", version.macos_short);
    try std.testing.expectEqualStrings("1.6.2d1", version.macos_build);
    try std.testing.expectEqual(@as(u16, 0), version.windows_major);
    try std.testing.expectEqual(@as(u16, 6), version.windows_minor);
    try std.testing.expectEqual(@as(u16, 2), version.windows_patch);
    try std.testing.expectEqual(@as(u16, 1), version.windows_revision);
    try std.testing.expectEqual(@as(u32, 0x2), version.windows_file_flags);
    try std.testing.expectEqualStrings("0.6.2~dev.1-1", version.debian_package);
    try std.testing.expectEqualStrings("0.6.2~dev.1", version.rpm_package);
    try std.testing.expectEqualStrings("0.6.2dev.1", version.arch_package);
}

test "derive release version" {
    const allocator = std.testing.allocator;
    const version = try derive(allocator, "0.6.2");
    defer version.deinit(allocator);

    try std.testing.expect(!version.isPrerelease());
    try std.testing.expectEqualStrings("1.6.2", version.macos_build);
    try std.testing.expectEqual(std.math.maxInt(u16), version.windows_revision);
    try std.testing.expectEqual(@as(u32, 0), version.windows_file_flags);
    try std.testing.expectEqualStrings("0.6.2-1", version.debian_package);
    try std.testing.expectEqualStrings("0.6.2", version.rpm_package);
    try std.testing.expectEqualStrings("0.6.2", version.arch_package);
}

test "prerelease stages preserve platform ordering" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        text: []const u8,
        macos: []const u8,
        windows_revision: u16,
    }{
        .{ .text = "0.6.2-dev.255", .macos = "1.6.2d255", .windows_revision = 255 },
        .{ .text = "0.6.2-alpha.1", .macos = "1.6.2a1", .windows_revision = 257 },
        .{ .text = "0.6.2-beta.1", .macos = "1.6.2b1", .windows_revision = 513 },
        .{ .text = "0.6.2-rc.1", .macos = "1.6.2fc1", .windows_revision = 769 },
    };

    for (cases) |case| {
        const version = try derive(allocator, case.text);
        defer version.deinit(allocator);
        try std.testing.expectEqualStrings(case.macos, version.macos_build);
        try std.testing.expectEqual(case.windows_revision, version.windows_revision);
    }
}

test "reject versions that cannot map consistently" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidSemanticVersion, derive(allocator, "0.6"));
    try std.testing.expectError(error.BuildMetadataUnsupported, derive(allocator, "0.6.2+sha.1"));
    try std.testing.expectError(error.UnsupportedPrerelease, derive(allocator, "0.6.2-preview.1"));
    try std.testing.expectError(error.UnsupportedPrerelease, derive(allocator, "0.6.2-dev"));
    try std.testing.expectError(error.UnsupportedPrerelease, derive(allocator, "0.6.2-dev.1.extra"));
    try std.testing.expectError(error.InvalidPrereleaseNumber, derive(allocator, "0.6.2-dev.0"));
    try std.testing.expectError(error.InvalidPrereleaseNumber, derive(allocator, "0.6.2-dev.256"));
    try std.testing.expectError(error.PlatformVersionOutOfRange, derive(allocator, "0.100.0"));
    try std.testing.expectError(error.PlatformVersionOutOfRange, derive(allocator, "0.0.100"));
    try std.testing.expectError(error.PlatformVersionOutOfRange, derive(allocator, "9999.0.0"));
}
