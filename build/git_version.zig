//! 빌드 시점 git 상태 조회 — About / `--version` / 로그에 찍히는 commit 정보 ([#383](https://github.com/ensky0/tildaz/issues/383)).
//!
//! release version 의 단일 원본은 `build.zig.zon` 의 `.version` 이고 그 파생은
//! `build/version.zig` 가 담당한다. 이 모듈은 그 위에 얹는 **어느 커밋에서 빌드했나**
//! 하나만 본다. 둘을 사람이 읽는 한 줄로 합치는 규칙은 runtime 쪽 `src/version.zig`
//! 한 곳에 있다 — 규칙이 두 군데면 About 과 `--version` 이 갈린다.
//!
//! ## 조회에 실패해도 빌드는 계속된다
//!
//! git 이 PATH 에 없거나 `.git` 이 없는 소스 tarball (배포판 패키지 빌드가 그렇다) 이면
//! `commit` 이 빈 문자열이 되고 버전 문자열은 `0.7.0` 처럼 커밋 없이 나온다. 여기서
//! 빌드를 세우지 않는 이유는 commit 이 *진단 편의* 값이지 동작에 필요한 값이 아니라서다.
//!
//! ## 이 조회는 `zig build` 를 부를 때마다 다시 돈다
//!
//! `runFallible` 은 build graph 를 만드는 시점 (= configure) 에 실행된다. Zig 0.17 은 그 설정
//! 결과를 캐시하므로 `detect` 가 `poisonCache` 로 매번 다시 돌게 한다 (#820). 그래서 커밋을
//! 하거나 작업 트리를 더럽히면 다음 `zig build` 에서 값이 갱신되고, 값이 그대로면
//! `addOptions` 가 만드는 파일 내용도 같아서 컴파일 캐시는 그대로 맞는다.

const std = @import("std");

pub const Info = struct {
    /// short commit hash (git 이 정하는 길이, 최소 7자). 조회 실패면 빈 문자열.
    commit: []const u8 = "",

    /// 작업 트리에 커밋되지 않은 변경이 있는가. `commit` 이 비면 항상 false —
    /// 커밋을 모르는데 "그 커밋에서 바뀌었다" 고 말할 수 없다.
    dirty: bool = false,
};

pub fn detect(b: *std.Build) Info {
    // #820 — Zig 0.17 은 설정 결과를 캐시하고 같은 설정이면 build.zig 를 건너뛴다. git 조회는
    // 캐시가 추적하지 못하는 입력이라, 그대로 두면 커밋해도 옛 commit 이 찍힌다. 매번 다시
    // 돌게 알린다 (`runFallible` 은 스스로 캐시를 무효로 하지 않는다).
    b.graph.poisonCache();

    // build root 를 명시한다. `zig build` 를 어느 cwd 에서 부르든 같은 저장소를 본다.
    const root = b.root.toString(b.allocator) catch @panic("OOM");
    const hash_raw = switch (b.runFallible(
        &.{ "git", "-C", root, "rev-parse", "--short", "HEAD" },
        .{ .stderr_behavior = .ignore },
    )) {
        .success => |stdout| stdout,
        .spawn_failed, .bad_exit_code, .crashed => return .{},
    };
    const commit = std.mem.trim(u8, hash_raw, " \t\r\n");
    // 커밋이 하나도 없는 저장소 (`git init` 직후) 는 위에서 실패하지만, 방어적으로 본다.
    if (commit.len == 0) return .{};

    // `--untracked-files=no` 는 `git describe --dirty` 와 같은 판정이다. 추적되지 않는
    // 새 파일 (빌드 산출물 · 스크래치 파일) 은 dirty 로 치지 않고 **추적 중인 파일의
    // staged + unstaged 변경**만 본다.
    //
    // `git diff --quiet` 를 쓰지 않는 이유: staged 변경을 못 본다 (`git add` 만 한 상태가
    // clean 으로 읽힌다). `status` 는 그것까지 보고, 덤으로 index 를 refresh 해서 내용은
    // 같은데 mtime 만 바뀐 파일이 dirty 로 오탐되는 것도 막는다.
    const status = switch (b.runFallible(
        &.{ "git", "-C", root, "status", "--porcelain", "--untracked-files=no" },
        .{ .stderr_behavior = .ignore },
    )) {
        .success => |stdout| stdout,
        .spawn_failed, .bad_exit_code, .crashed => return .{ .commit = commit },
    };

    return .{
        .commit = commit,
        .dirty = std.mem.trim(u8, status, " \t\r\n").len != 0,
    };
}
