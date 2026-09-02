//! 측정용 실행 옵션 ([#382](https://github.com/ensky0/tildaz/issues/382)).
//!
//! **내부용이다.** `README` · `CONFIG.md` · `KEYBINDINGS.md` 에 넣지 않고, 쓰는 곳은
//! `dist/stress/compare-terminals.sh` 하나다. 사용자 기능으로 만들려면 "이미 떠 있는
//! 인스턴스와의 관계", "drop-down 을 어떻게 표시하나", "탭을 더 열면 그 탭은 무엇인가"
//! 를 다 정해야 하는데, 측정용으로 한정하면 그것들이 필요 없다.
//!
//! ## 왜 필요한가
//!
//! [#371](https://github.com/ensky0/tildaz/issues/371) 의 터미널 비교에서 우리만 손으로
//! 재야 했다. 다른 넷은 명령 실행 옵션(`-e`)과 셀 단위 창 크기 지정을 갖고 있다.
//! 그것이 없으면 측정 한 번에 config 를 고치고 재시작하고 명령을 붙여넣는 절차가 든다.

const std = @import("std");
const log = @import("log.zig");
const messages = @import("messages.zig");

pub const Grid = struct { cols: u16, rows: u16 };

pub const RunOptions = struct {
    /// `-e <실행파일>` — 셸 대신 이 실행파일을 띄우고, 그것이 끝나면 앱도 끝낸다.
    ///
    /// **인자를 넘길 수 없다.** POSIX 는 PTY 자식의 argv 가 `{shell}` 로 고정이라
    /// (`terminal/posix/pty.zig`) 실행파일 경로 하나만 의미가 있다. 측정에는 충분하다 —
    /// producer 가 파라미터를 환경변수로 받는다 (`src/stress.zig`).
    command: ?[]const u8 = null,

    /// `-size <COLS>x<ROWS>` — config 의 `window.width_percent` / `height_percent` 를
    /// 무시하고 **셀 개수**로 창을 만든다. 다른 터미널이 모두 갖고 있는 방식이다
    /// (kitty 의 `initial_window_width=120c`, ghostty 의 `window-width = 120`).
    ///
    /// 셀 크기는 폰트 metrics 에서 나오므로 renderer 초기화 뒤에야 안다. 그래서 각 host
    /// 는 창을 먼저 띄우고 그 뒤에 `ui_metrics.viewportForGrid` 로 크기를 다시 맞춘다.
    grid: ?Grid = null,

    /// `-scrollback <N>` — config 의 `max_scroll_lines` 를 무시하고 이 줄 수를 쓴다
    /// ([#381](https://github.com/ensky0/tildaz/issues/381)).
    ///
    /// **왜 필요한가**: 터미널 비교에서 scrollback 을 맞추지 않으면 우리가 불리하다.
    /// 우리 기본값은 100,000 인데 **Windows Terminal 은 `historySize` 최대가 32,767**
    /// 이고 CLI 로는 지정할 수도 없다 (profile 설정이라 `settings.json` 뿐). 그리고 그
    /// 차이가 작지 않다 — 파서 층 실측으로 `plain` 이 100,000 → 9,000 에서 **+45 %**
    /// (294.6 → 427.8 MiB/s) 다. 100,000 줄이면 작업 집합이 약 120 MB 라 캐시를 밀어낸다.
    ///
    /// 다른 터미널은 전부 CLI 로 지정할 수 있어서 (alacritty `-o scrolling.history`,
    /// wezterm `--config scrollback_lines`, kitty `-o scrollback_lines`) 우리만 없었다.
    /// **사용자 config 를 고치지 않고** 맞추기 위한 옵션이다.
    scrollback: ?usize = null,

    /// config 값 위에 측정 override 를 얹는다. `-scrollback` 이 없으면 config 값 그대로.
    pub fn scrollLines(self: RunOptions, config_value: usize) usize {
        return self.scrollback orelse config_value;
    }

    /// 측정 모드인가. `-e` 가 기준이다 — 그때만 아래를 건너뛴다.
    ///
    /// - **worker lock**: 잡으면 평소 쓰는 TildaZ 와 충돌한다.
    /// - **전역 핫키 등록**: 등록하면 F1 이 두 프로세스에 걸린다.
    /// - **launcher 경로**: 다른 worker 를 spawn 하거나 새 instance 를 요청하면 안 된다.
    ///
    /// 그리고 창을 **표시한 채** 시작한다 (`hidden_start` 무시) — 숨김이면 렌더가 일어나지
    /// 않아 측정이 무의미하다.
    pub fn isStressRun(self: RunOptions) bool {
        return self.command != null;
    }
};

/// `<COLS>x<ROWS>` 를 읽는다. 잘못된 형식이면 `null`.
pub fn parseGrid(text: []const u8) ?Grid {
    const sep = std.mem.findScalar(u8, text, 'x') orelse return null;
    const cols = std.fmt.parseInt(u16, text[0..sep], 10) catch return null;
    const rows = std.fmt.parseInt(u16, text[sep + 1 ..], 10) catch return null;
    if (cols == 0 or rows == 0) return null;
    return .{ .cols = cols, .rows = rows };
}

/// [#506](https://github.com/ensky0/tildaz/issues/506) — `-size` 요청을 **끝까지 지킬 수
/// 없을 때의 단일 거부 경로.** 세 host 가 같은 문구 · 같은 종료 코드를 쓰도록 여기 하나만
/// 둔다.
///
/// **다이얼로그가 아니다.** `-size` 는 `--help` 에 싣지 않는 측정 전용 옵션이라 호출처가
/// 사람이 아니라 스크립트인 경우가 많고, 모달을 띄우면 그 스크립트가 그 자리에서 멈춘다.
/// `log.userFacing` 이 stderr 와 로그 파일 양쪽에 남기므로 사람이 직접 띄운 경우에도
/// 보인다. 종료 코드 2 는 `main.zig` 의 인자 오류 (`printOptionError`) 와 같은 값이다 —
/// 둘 다 "준 명령을 그대로 수행할 수 없다" 이기 때문이다.
///
/// 밀린 채로 도는 창을 두지 않는 이유는 그것이 **측정이 되는 척** 하기 때문이다. 맨 아래
/// 행이 화면 밖이면 그 회차의 숫자는 틀렸는데, 그 사실이 timing 파일에는 남지 않는다.
pub fn exitSizeDoesNotFit(want: Grid, needed_w: i64, needed_h: i64, screen_w: i64, screen_h: i64) noreturn {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, messages.size_does_not_fit_format, .{
        want.cols,
        want.rows,
        needed_w,
        needed_h,
        screen_w,
        screen_h,
    }) catch messages.size_error_fallback_msg;
    log.userFacing("startup", msg);
    std.process.exit(2);
}

test "parseGrid 는 COLSxROWS 를 읽는다" {
    try std.testing.expectEqual(Grid{ .cols = 120, .rows = 40 }, parseGrid("120x40").?);
    try std.testing.expectEqual(Grid{ .cols = 1, .rows = 1 }, parseGrid("1x1").?);
    try std.testing.expectEqual(Grid{ .cols = 424, .rows = 113 }, parseGrid("424x113").?);
}

test "parseGrid 는 잘못된 형식을 거른다" {
    for ([_][]const u8{
        "",      "120",      "120x",    "x40",       "120x40x2", "0x40", "120x0",
        "-1x40", "120 x 40", "abcxdef", "999999x40",
    }) |bad| {
        try std.testing.expectEqual(@as(?Grid, null), parseGrid(bad));
    }
}

test "scrollLines 는 -scrollback 이 있을 때만 config 를 덮는다" {
    try std.testing.expectEqual(@as(usize, 100_000), (RunOptions{}).scrollLines(100_000));
    try std.testing.expectEqual(@as(usize, 9001), (RunOptions{ .scrollback = 9001 }).scrollLines(100_000));
    // 0 도 유효한 요청이다 (scrollback 없이 재는 경우) — `orelse` 가 아니라 값으로 판정한다.
    try std.testing.expectEqual(@as(usize, 0), (RunOptions{ .scrollback = 0 }).scrollLines(100_000));
}

test "isStressRun 은 -e 를 기준으로 한다" {
    try std.testing.expect(!(RunOptions{}).isStressRun());
    try std.testing.expect(!(RunOptions{ .grid = .{ .cols = 120, .rows = 40 } }).isStressRun());
    try std.testing.expect((RunOptions{ .command = "/bin/echo" }).isStressRun());
}
