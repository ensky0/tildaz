// 사용자 데이터 파일 (config_N.toml / tildaz_N.log) 의 absolute 절대 경로 — OS
// 표준 위치를 따른다 (SPEC.md §11.1, AGENTS.md "platform native first").
// 로그 파일명은 config 파일명 (config_N.toml) 과 같은 `이름_번호` 형식.
//
//   Windows: %APPDATA%\tildaz\config_N.toml   (Microsoft 표준)
//            %APPDATA%\tildaz\tildaz_N.log
//   macOS:   $XDG_CONFIG_HOME/tildaz/config_N.toml (fallback: $HOME/.config)
//            $HOME/Library/Logs/tildaz_N.log    (Apple HIG — Console.app 인덱싱)
//   Linux:   $XDG_CONFIG_HOME/tildaz/config_N.toml (fallback: $HOME/.config)
//            $XDG_STATE_HOME/tildaz/tildaz_N.log (fallback: $HOME/.local/state)
//
// 모두 allocator-based — 호출처가 free 책임. 부모 디렉토리는 자동 생성
// (이미 존재하면 무시). config 모듈과 log 모듈에서 사용한다. 로그 경로는
// `log.zig`가 프로세스 수명 동안 한 번만 보관하고, 기록 / About / Open Log가
// 그 값을 함께 써 실제 파일과 사용자에게 보이는 경로가 갈라지지 않는다.

// #451 — Zig 0.16 에서 환경변수와 파일 IO 가 전역 함수를 떠나 `Environ` · `Io` 를
// 거치게 됐다. 이 모듈은 그 둘을 가장 많이 쓰는 자리라 `Runtime` 을 인자로 받는다
// (릴리즈 노트가 지정한 두 길 중 "context struct" — `runtime.zig` 주석 참고).
const std = @import("std");
const builtin = @import("builtin");
const instance_context = @import("instance_context.zig");
const Runtime = @import("runtime.zig").Runtime;

pub fn configPath(rt: Runtime, allocator: std.mem.Allocator) ![]u8 {
    return configPathFor(rt, allocator, instance_context.requireWorkerIndex());
}

pub fn configPathFor(rt: Runtime, allocator: std.mem.Allocator, index: u32) ![]u8 {
    const dir = try configDir(rt, allocator);
    defer allocator.free(dir);
    try ensureDir(rt, dir);
    const sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';
    return std.fmt.allocPrint(allocator, "{s}{c}config_{d}.toml", .{ dir, sep, index });
}

pub fn logPath(rt: Runtime, allocator: std.mem.Allocator) ![]u8 {
    const dir = try logDir(rt, allocator);
    defer allocator.free(dir);
    try ensureDir(rt, dir);
    var name_buf: [32]u8 = undefined;
    const name = try logFileName(
        &name_buf,
        instance_context.currentRole(),
        instance_context.workerIndex() orelse 0,
    );
    return logPathFromDir(allocator, dir, name);
}

/// 로그 파일 이름. **측정 인스턴스는 worker 와 다른 파일에 쓴다**
/// ([#382](https://github.com/ensky0/tildaz/issues/382)).
///
/// index 로만 이름을 만들면 측정 인스턴스 (index 0) 가 사용자 세션과 같은
/// `tildaz_0.log` 에 append 한다. 줄이 섞이지는 않지만 pid 가 붙는 줄이 `boot` / `exit`
/// 둘뿐이라, 사후에 어느 줄이 사용자 세션인지 가릴 수 없다 — #382 자체가 실기 로그로
/// 진단된 사안인데 그 진단 채널이 측정으로 오염된다 (macOS 실기 검증에서 실제로 겪었다).
pub fn logFileName(buf: []u8, role: instance_context.Role, index: u32) ![]const u8 {
    return switch (role) {
        .worker => try std.fmt.bufPrint(buf, "tildaz_{d}.log", .{index}),
        // index 를 붙이지 않는다 — 창 타이틀 (`instances.stress_window_title`) 과 같은
        // 이유다. 측정은 한 번에 하나만 돌리고, 어떤 index 로 실행하든 worker 의 파일에서
        // 빠지는 것이 목적이다.
        .stress => "tildaz_stress.log",
    };
}

fn logDir(rt: Runtime, allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        const appdata = try rt.envAlloc(allocator, "APPDATA");
        defer allocator.free(appdata);
        return std.fmt.allocPrint(allocator, "{s}\\tildaz", .{appdata});
    } else if (builtin.os.tag == .macos) {
        const home = try rt.envAlloc(allocator, "HOME");
        defer allocator.free(home);
        return std.fmt.allocPrint(allocator, "{s}/Library/Logs", .{home});
    } else {
        const base = try stateHome(rt, allocator);
        defer allocator.free(base);
        return std.fmt.allocPrint(allocator, "{s}/tildaz", .{base});
    }
}

fn logPathFromDir(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';
    return std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ dir, sep, name });
}

pub fn configDir(rt: Runtime, allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        const appdata = try rt.envAlloc(allocator, "APPDATA");
        defer allocator.free(appdata);
        return std.fmt.allocPrint(allocator, "{s}\\tildaz", .{appdata});
    }
    const base = try configHome(rt, allocator);
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s}/tildaz", .{base});
}

/// Linux · macOS 사용자 config base. 유효한 절대 XDG_CONFIG_HOME을 우선하고
/// unset/empty/relative 값은 XDG 기본인 $HOME/.config로 fallback한다.
pub fn configHome(rt: Runtime, allocator: std.mem.Allocator) ![]u8 {
    return xdgHome(rt, allocator, "XDG_CONFIG_HOME", "/.config");
}

/// Linux 사용자 state base. log가 여기에 tildaz/를 붙인다.
fn stateHome(rt: Runtime, allocator: std.mem.Allocator) ![]u8 {
    return xdgHome(rt, allocator, "XDG_STATE_HOME", "/.local/state");
}

fn xdgHome(rt: Runtime, allocator: std.mem.Allocator, env_name: []const u8, fallback_suffix: []const u8) ![]u8 {
    if (rt.envAlloc(allocator, env_name) catch null) |dir| {
        if (dir.len != 0 and std.Io.Dir.path.isAbsolute(dir)) return dir;
        allocator.free(dir);
    }
    const home = try rt.envAlloc(allocator, "HOME");
    defer allocator.free(home);
    return resolveXdgHome(allocator, null, home, fallback_suffix);
}

/// env를 읽지 않는 pure helper — empty/relative/absolute 경계를 단위 테스트한다.
fn resolveXdgHome(
    allocator: std.mem.Allocator,
    candidate: ?[]const u8,
    home: []const u8,
    fallback_suffix: []const u8,
) ![]u8 {
    if (candidate) |dir| {
        if (dir.len != 0 and std.Io.Dir.path.isAbsolute(dir)) return allocator.dupe(u8, dir);
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ home, fallback_suffix });
}

pub fn ensureConfigDir(rt: Runtime, allocator: std.mem.Allocator) !void {
    const dir = try configDir(rt, allocator);
    defer allocator.free(dir);
    try ensureDir(rt, dir);
}

/// process ownership 파일은 사용자 config가 아닌 transient state다.
/// Linux는 login session runtime 경로를 우선하고, 나머지는 OS 표준 local
/// cache 경로를 사용한다. XDG_RUNTIME_DIR가 없는 Linux session은 XDG cache로
/// fallback한다.
pub fn lockDir(rt: Runtime, allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        const local_appdata = try rt.envAlloc(allocator, "LOCALAPPDATA");
        defer allocator.free(local_appdata);
        return std.fmt.allocPrint(allocator, "{s}\\tildaz\\run", .{local_appdata});
    }

    if (builtin.os.tag == .macos) {
        const home = try rt.envAlloc(allocator, "HOME");
        defer allocator.free(home);
        return std.fmt.allocPrint(allocator, "{s}/Library/Caches/TildaZ", .{home});
    }

    if (rt.envAlloc(allocator, "XDG_RUNTIME_DIR") catch null) |runtime_dir| {
        defer allocator.free(runtime_dir);
        if (runtime_dir.len != 0 and std.Io.Dir.path.isAbsolute(runtime_dir)) return linuxLockDir(allocator, runtime_dir, null, "");
    }
    if (rt.envAlloc(allocator, "XDG_CACHE_HOME") catch null) |cache_dir| {
        defer allocator.free(cache_dir);
        if (cache_dir.len != 0 and std.Io.Dir.path.isAbsolute(cache_dir)) return linuxLockDir(allocator, null, cache_dir, "");
    }
    const home = try rt.envAlloc(allocator, "HOME");
    defer allocator.free(home);
    return linuxLockDir(allocator, null, null, home);
}

fn linuxLockDir(
    allocator: std.mem.Allocator,
    runtime_dir: ?[]const u8,
    cache_dir: ?[]const u8,
    home: []const u8,
) ![]u8 {
    if (runtime_dir) |dir| return std.fmt.allocPrint(allocator, "{s}/tildaz", .{dir});
    if (cache_dir) |dir| return std.fmt.allocPrint(allocator, "{s}/tildaz/run", .{dir});
    return std.fmt.allocPrint(allocator, "{s}/.cache/tildaz/run", .{home});
}

pub fn instanceLockPath(rt: Runtime, allocator: std.mem.Allocator, index: u32) ![]u8 {
    const dir = try lockDir(rt, allocator);
    defer allocator.free(dir);
    try ensureDir(rt, dir);
    const sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';
    return std.fmt.allocPrint(allocator, "{s}{c}instance{d}.lock", .{ dir, sep, index });
}

pub fn instanceEndpointStatePath(rt: Runtime, allocator: std.mem.Allocator, index: u32) ![]u8 {
    const dir = try lockDir(rt, allocator);
    defer allocator.free(dir);
    try ensureDir(rt, dir);
    const sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';
    return std.fmt.allocPrint(allocator, "{s}{c}instance{d}.endpoint", .{ dir, sep, index });
}

pub fn launcherLockPath(rt: Runtime, allocator: std.mem.Allocator) ![]u8 {
    const dir = try lockDir(rt, allocator);
    defer allocator.free(dir);
    try ensureDir(rt, dir);
    const sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';
    return std.fmt.allocPrint(allocator, "{s}{c}launcher.lock", .{ dir, sep });
}

/// 중간 단계 포함 재귀 디렉토리 생성 (`~/.local/state/tildaz` 같이 깊은 경로용).
/// 절대경로 component 는 leading `/` 를 유지해 makeDir 이 dirfd 무시하고 그대로
/// 생성. 다른 모듈 (`autostart/linux.zig`) 도 이걸 쓴다 — 자체 wrapper 금지 (#282 G7).
pub fn ensureDir(rt: Runtime, dir: []const u8) !void {
    // #451 — `fs.Dir.makePath` ➡️ `std.Io.Dir.createDirPath` (릴리즈 노트 upgrade guide).
    try std.Io.Dir.cwd().createDirPath(rt.io, dir);
}

fn currentPid() u32 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
}

/// #282 G6 — atomic write-if-changed. `path` 의 기존 내용이 `content` 와 같으면
/// 아무것도 쓰지 않고 `false`, 다르거나 파일이 없으면 같은 디렉토리의 temp 에
/// 쓰고 fsync 후 rename 으로 원자 교체하고 `true`. temp 를 대상과 같은 fs 에 두어
/// rename 원자성을 보장(부분 기록 파일이 남지 않음). mode 0o644 — desktop entry
/// / plist / 셸 확장 / cosmic 단축키 파일의 표준. autostart·instance_identity·
/// shell_extension·cosmic sync 의 5벌 복제를 대체.
pub fn writeFileIfChanged(rt: Runtime, allocator: std.mem.Allocator, path: []const u8, content: []const u8) !bool {
    // #451 — 파일 IO 가 전부 `Io` 를 받는다. `readToEndAlloc` 은 `File.Reader` 의
    // `allocRemaining` 으로 갔고 (릴리즈 노트 *fs.File.readToEndAlloc*), `mode` 는
    // `permissions` 로 이름과 타입이 바뀌었다 (`fs.File.Mode` ➡️ `Io.File.Permissions`).
    if (std.Io.Dir.openFileAbsolute(rt.io, path, .{})) |existing| {
        defer existing.close(rt.io);
        var existing_reader = existing.reader(rt.io, &.{});
        if (existing_reader.interface.allocRemaining(allocator, .limited(4 * 1024 * 1024))) |old| {
            defer allocator.free(old);
            if (std.mem.eql(u8, old, content)) return false;
        } else |_| {}
    } else |_| {}

    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tildaz-{d}.tmp", .{ path, currentPid() });
    defer allocator.free(temp_path);
    errdefer std.Io.Dir.deleteFileAbsolute(rt.io, temp_path) catch {};
    {
        // 0o644 는 desktop entry / plist / 셸 확장 / cosmic 단축키 파일의 표준이다 —
        // `Permissions.default_file` (POSIX 0o666 + umask) 로 바꾸면 umask 에 따라
        // 결과가 갈리므로 명시값을 유지한다. Windows 는 mode 개념이 없어 기본값.
        const permissions: std.Io.File.Permissions =
            if (builtin.os.tag == .windows) .default_file else .fromMode(0o644);
        const temp = try std.Io.Dir.createFileAbsolute(rt.io, temp_path, .{
            .truncate = true,
            .permissions = permissions,
        });
        defer temp.close(rt.io);
        try temp.writeStreamingAll(rt.io, content);
        try temp.sync(rt.io);
    }
    // `renameAbsolute` 는 `io` 를 **마지막** 인자로 받는다 (다른 `Io.Dir` 함수와 순서가 다르다).
    try std.Io.Dir.renameAbsolute(temp_path, path, rt.io);
    return true;
}

/// #451 — Zig 0.16 은 환경변수를 `main` 밖에서 못 읽게 했다 (릴리즈 노트 *Environment
/// Variables and Process Arguments Become Non-Global*). 그래서 테스트는 실제 환경 대신
/// **합성 `Environ`** 을 만들어 쓴다 — 값이 고정되니 기계마다 결과가 갈리지도 않는다.
/// Windows 는 블록이 PEB 전역 참조 (`GlobalBlock`) 라 주입할 수 없어 실제 환경을 쓴다.
fn testRuntime() Runtime {
    return .{
        .io = std.testing.io,
        .environ = if (builtin.os.tag == .windows)
            .{ .block = .global }
        else
            .{ .block = .{ .slice = &[_:null]?[*:0]const u8{"HOME=/home/test"} } },
    };
}

test "로그 경로가 OS 표준 위치와 worker index 를 따른다" {
    // `logPath` 가 아니라 `logDir` 로 조립을 검증한다 — `logPath` 는 디렉토리를 실제로
    // 만들고 (`ensureDir`), 합성 HOME 은 존재하지 않는 경로라 만들 수 없다. 이 테스트가
    // 보려는 것은 *어느 위치에 어떤 이름으로* 가느냐이고 그건 아래 조합으로 다 덮인다.
    const allocator = std.testing.allocator;
    const rt = testRuntime();

    const dir = logDir(rt, allocator) catch return error.SkipZigTest;
    defer allocator.free(dir);

    var name_buf: [32]u8 = undefined;
    const name = try logFileName(&name_buf, .worker, 7);
    const path = try logPathFromDir(allocator, dir, name);
    defer allocator.free(path);

    try std.testing.expect(std.mem.endsWith(u8, path, switch (builtin.os.tag) {
        .windows => "\\tildaz\\tildaz_7.log",
        .macos => "/Library/Logs/tildaz_7.log",
        else => "/tildaz/tildaz_7.log",
    }));
}

test "측정 인스턴스는 worker 의 로그 파일에 쓰지 않는다" {
    // #382 — 같은 index 여도 파일이 갈려야 한다. 이 성질이 깨지면 측정 로그가 사용자
    // 세션 로그에 섞여 진단이 어려워진다.
    var buf: [32]u8 = undefined;
    var stress_buf: [32]u8 = undefined;
    const stress_name = try logFileName(&stress_buf, .stress, 0);
    for ([_]u32{ 0, 1, 9, 42, 999 }) |index| {
        const worker_name = try logFileName(&buf, .worker, index);
        try std.testing.expect(!std.mem.eql(u8, worker_name, stress_name));
    }
    try std.testing.expectEqualStrings("tildaz_0.log", try logFileName(&buf, .worker, 0));
    try std.testing.expectEqualStrings("tildaz_stress.log", stress_name);
    // 어떤 index 로 실행해도 측정 로그 이름은 하나다 (`--instance N` + `-e`).
    try std.testing.expectEqualStrings(stress_name, try logFileName(&buf, .stress, 9));
}

test "log path builder preserves paths beyond the old fixed limit" {
    const allocator = std.testing.allocator;
    const long_dir = "/base/" ++ ("가" ** 1200);
    const path = try logPathFromDir(allocator, long_dir, "tildaz_42.log");
    defer allocator.free(path);

    try std.testing.expect(path.len > 1024);
    try std.testing.expect(std.mem.startsWith(u8, path, long_dir));
    try std.testing.expect(std.mem.endsWith(u8, path, switch (builtin.os.tag) {
        .windows => "\\tildaz_42.log",
        else => "/tildaz_42.log",
    }));
}

test "Linux lock directory follows runtime then cache fallback order" {
    const allocator = std.testing.allocator;

    const runtime = try linuxLockDir(allocator, "/run/user/1000", "/cache", "/home/test");
    defer allocator.free(runtime);
    try std.testing.expectEqualStrings("/run/user/1000/tildaz", runtime);

    const cache = try linuxLockDir(allocator, null, "/cache", "/home/test");
    defer allocator.free(cache);
    try std.testing.expectEqualStrings("/cache/tildaz/run", cache);

    const home = try linuxLockDir(allocator, null, null, "/home/test");
    defer allocator.free(home);
    try std.testing.expectEqualStrings("/home/test/.cache/tildaz/run", home);
}

test "XDG home accepts only absolute non-empty values" {
    const allocator = std.testing.allocator;

    const custom = try resolveXdgHome(allocator, "/custom/config", "/home/test", "/.config");
    defer allocator.free(custom);
    try std.testing.expectEqualStrings("/custom/config", custom);

    const empty = try resolveXdgHome(allocator, "", "/home/test", "/.config");
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("/home/test/.config", empty);

    const relative = try resolveXdgHome(allocator, "relative/config", "/home/test", "/.config");
    defer allocator.free(relative);
    try std.testing.expectEqualStrings("/home/test/.config", relative);

    const state = try resolveXdgHome(allocator, null, "/home/test", "/.local/state");
    defer allocator.free(state);
    try std.testing.expectEqualStrings("/home/test/.local/state", state);
}

test "#496 1-c the Shell extensions read the same config filename we write" {
    // GNOME · Cinnamon 확장은 zig 를 안 거치고 config 를 직접 읽는다. #493 이 파일을
    // TOML 로 옮길 때 그 두 벌이 남겨져 **확장이 아무 config 도 못 봤다** — 등록 대상
    // 0 개라 GNOME 에서 hotkey 가 하나도 안 걸렸다 (실기 확인, GNOME 50.4). 눈에 띄지
    // 않은 이유는 이관 전의 `config_0.json` 이 디스크에 남아 있었기 때문이다.
    const sources = [_]struct { label: []const u8, js: []const u8 }{
        .{ .label = "gnome", .js = @embedFile("gnome_extension_js") },
        .{ .label = "cinnamon", .js = @embedFile("cinnamon_extension_js") },
    };
    for (sources) |source| {
        // 한 파일을 열 때 (`config_9.toml`) 와 디렉터리를 훑을 때 (`^config_N\.toml$`)
        // 두 자리가 있고, 둘 다 이 확장자여야 한다.
        if (std.mem.indexOf(u8, source.js, "config_${index}.toml") == null) {
            std.debug.print("{s} extension 이 config_{{index}}.toml 을 안 읽는다\n", .{source.label});
            return error.ExtensionConfigNameOutOfSync;
        }
        if (std.mem.indexOf(u8, source.js, "config_(0|[1-9][0-9]*)\\.toml$") == null) {
            std.debug.print("{s} extension 의 디렉터리 훑기가 .toml 이 아니다\n", .{source.label});
            return error.ExtensionConfigNameOutOfSync;
        }
        try std.testing.expect(std.mem.indexOf(u8, source.js, "config_${index}.json") == null);
    }
}
