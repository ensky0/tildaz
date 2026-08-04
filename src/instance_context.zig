const std = @import("std");

/// 이 프로세스가 무엇인가 ([#382](https://github.com/ensky0/tildaz/issues/382)).
///
/// 측정 인스턴스는 **worker 가 아니다** — worker lock 도 endpoint 상태도 갖지 않고
/// 전역 핫키도 등록하지 않는다. 그런데 worker index 는 그대로 쓴다 (`--instance` 없으면
/// 0): 측정도 사용자의 폰트 · 테마로 재야 "같은 조건에서 다른 터미널과 비교" 가 성립하니
/// **config 는 공유가 맞다.**
///
/// 문제는 그 index 에서 config 말고도 이름이 파생된다는 것이다 — 창 타이틀, Wayland
/// app_id, 로그 파일. 그 이름들이 worker 와 같으면 worker 를 찾는 쪽 (Windows 의
/// `FindWindowW`, GNOME · Cinnamon extension) 이 측정 창을 집고, 로그도 사용자 세션과
/// 섞여 진단이 어려워진다. e5c7857 이 Windows 창 타이틀 하나만 분리했다가 Linux 두 곳이
/// 남은 것이 그 증거다.
///
/// 그래서 "무엇인가" 를 index 옆에 따로 둔다. 이름을 만드는 함수는 index 가 아니라 이
/// 값을 봐야 한다 (`instances.windowTitleForCurrentRole` ·
/// `instance_identity.appIdForCurrentRole` · `paths.logPath`).
pub const Role = enum { worker, stress };

var worker_index: ?u32 = null;
var role: Role = .worker;

pub fn setWorkerIndex(index: u32) void {
    worker_index = index;
}

pub fn setRole(new_role: Role) void {
    role = new_role;
}

pub fn currentRole() Role {
    return role;
}

/// 측정 인스턴스인가. `run_options.isStressRun()` 은 *옵션* 을 보고 이쪽은 *프로세스
/// 전역 상태* 를 본다 — 이름 파생처럼 `RunOptions` 를 들고 다니지 않는 자리에서 쓴다.
pub fn isStress() bool {
    return role == .stress;
}

pub fn workerIndex() ?u32 {
    return worker_index;
}

pub fn requireWorkerIndex() u32 {
    return worker_index orelse @panic("TildaZ worker index is not set");
}

test "worker index context" {
    const previous = worker_index;
    defer worker_index = previous;

    setWorkerIndex(7);
    try std.testing.expectEqual(@as(?u32, 7), workerIndex());
    try std.testing.expectEqual(@as(u32, 7), requireWorkerIndex());
}

test "역할은 index 와 별개다 — 측정 인스턴스도 worker index 를 갖는다" {
    const previous_index = worker_index;
    const previous_role = role;
    defer {
        worker_index = previous_index;
        role = previous_role;
    }

    // 기본값은 worker — `--instance N` 만 준 평소 실행이 여기 해당한다.
    role = .worker;
    try std.testing.expect(!isStress());

    // 측정 실행은 index 0 을 그대로 쓰면서 (config 공유) 역할만 다르다.
    setWorkerIndex(0);
    setRole(.stress);
    try std.testing.expectEqual(@as(u32, 0), requireWorkerIndex());
    try std.testing.expectEqual(Role.stress, currentRole());
    try std.testing.expect(isStress());
}
