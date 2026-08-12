//! 사용자에게 보이는 버전 문자열의 **단일 조립 지점** ([#383](https://github.com/ensky0/tildaz/issues/383)).
//!
//! `--version` · About 다이얼로그 · `tildaz_N.log` 의 `[boot]` / `[exit]` 세 곳이 모두
//! 이 문자열 하나를 쓴다. 규칙을 호출처마다 두면 사용자가 이슈에 붙여 온 버전과 로그의
//! 버전이 갈려서, 어느 쪽이 맞는지 되묻는 비용이 생긴다.
//!
//! ## 형식
//!
//! ```text
//! 0.7.0                   .git 이 없는 소스 tarball 빌드 (배포판 패키지 등)
//! 0.7.0 (d1ad1ff)         그 커밋 그대로 빌드
//! 0.7.0 (d1ad1ff-dirty)   그 커밋 + 커밋되지 않은 로컬 변경
//! ```
//!
//! `-dirty` 는 `git describe --dirty` 의 기본 접미사다. Linux 커널의
//! `scripts/setlocalversion` 도 같은 단어를 쓴다 — 설명 없이 "로컬 수정본" 으로 읽히는
//! 표기라서 골랐다. 후보였던 `modified` (Go 의 `vcs.modified`) 와 `+` (커널이 태그 아닌
//! 커밋에 붙이는 표시) 는 뜻은 통하지만 관례 인지도가 낮다.
//!
//! ## 값의 출처
//!
//! 셋 다 `build_options` 의 comptime 상수다 — `version` 은 `build.zig.zon` 의 `.version`
//! 에서 (`build/version.zig`), `commit` / `commit_dirty` 는 빌드 시점 git 조회에서
//! (`build/git_version.zig`) 온다. 그래서 이 문자열도 comptime 에 완성되고 runtime 에
//! 조립도 할당도 없다.

const std = @import("std");
const build_options = @import("build_options");

/// 이 빌드의 버전 문자열. 위 문서 주석의 형식을 따른다.
pub const string: []const u8 = compose(
    build_options.version,
    build_options.commit,
    build_options.commit_dirty,
);

/// 조립 규칙 그 자체. `string` 이 comptime 에 한 번 부르고, 테스트가 같은 함수로 규칙을
/// 검증한다 — 규칙과 검증이 같은 코드를 보게 하려고 상수 안에 인라인하지 않았다.
pub fn compose(
    comptime version: []const u8,
    comptime commit: []const u8,
    comptime dirty: bool,
) []const u8 {
    // 커밋을 모르면 괄호 자체를 쓰지 않는다. `0.7.0 ()` 나 `0.7.0 (unknown)` 은 값이
    // 없다는 사실만 시끄럽게 알릴 뿐, 읽는 사람이 할 수 있는 일이 없다.
    if (commit.len == 0) return version;
    return version ++ " (" ++ commit ++ (if (dirty) "-dirty" else "") ++ ")";
}

test "compose 는 커밋을 괄호에 넣는다" {
    try std.testing.expectEqualStrings("0.7.0 (d1ad1ff)", compose("0.7.0", "d1ad1ff", false));
}

test "compose 는 커밋되지 않은 변경에 -dirty 를 붙인다" {
    try std.testing.expectEqualStrings("0.7.0 (d1ad1ff-dirty)", compose("0.7.0", "d1ad1ff", true));
}

test "compose 는 커밋이 없으면 버전만 낸다" {
    // `.git` 이 없는 소스 tarball 빌드. dirty 는 커밋을 모르면 의미가 없어서 무시된다.
    try std.testing.expectEqualStrings("0.7.0", compose("0.7.0", "", false));
    try std.testing.expectEqualStrings("0.7.0", compose("0.7.0", "", true));
}

test "compose 는 prerelease 버전과 긴 hash 도 그대로 보존한다" {
    // `build.zig.zon` 이 허용하는 prerelease 형식 (`build/version.zig`) 과, 저장소가
    // 커져서 git 이 abbreviation 을 늘렸을 때를 같이 본다.
    try std.testing.expectEqualStrings(
        "0.7.1-rc.2 (d1ad1ff4ecee-dirty)",
        compose("0.7.1-rc.2", "d1ad1ff4ecee", true),
    );
}

test "string 은 이 빌드의 실제 값으로 조립된다" {
    // 값 자체는 빌드마다 다르므로 형식만 본다. 커밋을 아는 빌드면 버전 뒤에 괄호가 붙고,
    // 모르는 빌드면 버전과 정확히 같다.
    try std.testing.expect(std.mem.startsWith(u8, string, build_options.version));
    if (build_options.commit.len == 0) {
        try std.testing.expectEqualStrings(build_options.version, string);
    } else {
        try std.testing.expect(std.mem.endsWith(u8, string, ")"));
        try std.testing.expect(std.mem.find(u8, string, build_options.commit) != null);
        try std.testing.expectEqual(
            build_options.commit_dirty,
            std.mem.endsWith(u8, string, "-dirty)"),
        );
    }
}
