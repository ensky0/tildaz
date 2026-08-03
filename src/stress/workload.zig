//! stress 하네스가 터미널에 쏟아붓는 바이트를 만든다 (#371 · #278).
//!
//! **결정적이다** — 같은 `Kind` 로 같은 순서만큼 읽으면 어느 platform 에서든
//! 같은 바이트가 나온다. 난수 · 시각 · locale · 셸을 쓰지 않는다. 이게 세
//! platform 비교와 다른 터미널 비교의 전제다: 입력이 다르면 숫자를 나란히 둘 수
//! 없다 ([#362](https://github.com/ensky0/tildaz/issues/362#issuecomment-5154483380)
//! 에서 그리드가 31 배 어긋나 비교가 성립하지 않은 적이 있다).
//!
//! `ghostty` 에 의존하지 않아 단독으로 테스트할 수 있다:
//!
//! ```sh
//! zig test src/stress/workload.zig
//! ```

const std = @import("std");

pub const Kind = enum {
    /// ASCII 만. 파서에 가장 싼 경로 — escape sequence 도 wide cell 도 없다.
    plain,
    /// SGR 색이 섞인 빌드 로그 모양. escape sequence 파싱 비용이 더해진다.
    ansi,
    /// 한글 · color emoji · ZWJ 묶음 · block element. wide cell 과 grapheme
    /// cluster 경로를 태운다 (#278 의 검증 범위 ⑤).
    cjk,

    pub fn parse(name: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, name);
    }
};

/// 한 줄이 넘지 않는 크기. `cjk` 가 가장 길다 (emoji 하나가 4 byte, ZWJ 묶음은
/// 그 여러 배).
const max_line = 512;

/// 줄을 이어서 내보내는 생성기. `read` 를 여러 번 불러 조각으로 받아도 전체
/// 스트림은 한 번에 받은 것과 같다 — 조각 경계가 줄 중간이나 UTF-8 문자 중간에
/// 떨어져도 된다. 실제 PTY 도 그렇게 들어오고, VT 파서는 조각 사이 상태를
/// 유지한다.
pub const Generator = struct {
    kind: Kind,
    /// 다음에 만들 줄 번호. 줄마다 내용을 바꿔서 같은 page 를 재사용하는 최적화가
    /// 우연히 유리하게 걸리지 않도록 한다.
    line: usize = 0,
    line_buf: [max_line]u8 = undefined,
    /// `line_buf` 안에서 아직 내보내지 않은 구간.
    pending_off: usize = 0,
    pending_len: usize = 0,

    /// `out` 을 끝까지 채우고 채운 바이트 수를 돌려준다. 항상 `out.len` 이다 —
    /// 생성기는 무한하다. 총량은 호출자가 마지막 조각을 짧게 잡아 맞춘다.
    pub fn read(self: *Generator, out: []u8) usize {
        var written: usize = 0;
        while (written < out.len) {
            if (self.pending_off == self.pending_len) {
                self.pending_len = renderLine(self.kind, self.line, &self.line_buf);
                self.pending_off = 0;
                self.line +%= 1;
            }
            const n = @min(self.pending_len - self.pending_off, out.len - written);
            @memcpy(out[written..][0..n], self.line_buf[self.pending_off..][0..n]);
            self.pending_off += n;
            written += n;
        }
        return written;
    }
};

/// 줄 하나를 `buf` 에 쓰고 길이를 돌려준다. 개행을 포함한다.
fn renderLine(kind: Kind, line: usize, buf: []u8) usize {
    return switch (kind) {
        .plain => renderPlain(line, buf),
        .ansi => renderAnsi(line, buf),
        .cjk => renderCjk(line, buf),
    };
}

/// 80 열 ASCII. 뒤쪽 채움 문자를 줄마다 회전시켜 같은 내용이 반복되지 않게 한다.
fn renderPlain(line: usize, buf: []u8) usize {
    const filler = "abcdefghijklmnopqrstuvwxyz0123456789";
    var w = Writer{ .buf = buf };
    w.print("line {d:0>9} ", .{line});
    const start = line % filler.len;
    var i: usize = 0;
    while (w.len < 79) : (i += 1) {
        w.byte(filler[(start + i) % filler.len]);
    }
    w.byte('\n');
    return w.len;
}

/// SGR 색이 섞인 로그 한 줄. 실제 빌드 로그처럼 앞머리에 색을 넣고 본문은
/// 무채색으로 돌린다 — escape sequence 가 줄마다 여러 번 나온다.
fn renderAnsi(line: usize, buf: []u8) usize {
    const levels = [_][]const u8{ "INFO ", "WARN ", "ERROR", "DEBUG" };
    const level = levels[line % levels.len];
    // 256-color palette 를 돌린다. 16 미만은 테마 색과 겹쳐 대비가 낮으므로 건너뛴다.
    const color: usize = 16 + (line % 216);

    var w = Writer{ .buf = buf };
    w.print("\x1b[38;5;{d}m[{s}]\x1b[0m ", .{ color, level });
    w.print("line {d:0>9} ", .{line});
    w.print("\x1b[1mtarget\x1b[22m=obj/{d}.o ", .{line % 997});
    w.print("\x1b[38;5;{d}mstatus\x1b[0m=ok elapsed={d}ms\n", .{ color, line % 1000 });
    return w.len;
}

/// 한글 · emoji · 스킨톤 · ZWJ 묶음 · block element 를 한 줄에 섞는다. wide cell
/// 과 grapheme cluster 경로를 함께 태우는 것이 목적이다.
fn renderCjk(line: usize, buf: []u8) usize {
    const words = [_][]const u8{ "가나다라", "터미널", "처리량", "측정", "한글" };
    const emoji = [_][]const u8{ "🎉", "❤️", "🌈", "🚀", "💎" };
    const tone = [_][]const u8{ "👋🏻", "👋🏼", "👋🏽", "👋🏾", "👋🏿" };
    const blocks = "▀▁▂▃▄▅▆▇█";

    var w = Writer{ .buf = buf };
    w.print("{d:0>9} ", .{line});
    w.str(words[line % words.len]);
    w.byte(' ');
    w.str(emoji[line % emoji.len]);
    w.str(tone[line % tone.len]);
    // ZWJ 묶음 — 여러 codepoint 가 한 grapheme 으로 묶이는 경로.
    w.str("👨‍👩‍👧");
    w.print(" ABC {d} ", .{line % 100});
    w.str(words[(line + 2) % words.len]);
    w.byte(' ');
    // block element 는 3 byte 씩이라 codepoint 경계로 잘라 넣는다.
    const bstart = (line % 9) * 3;
    w.str(blocks[bstart .. bstart + 3]);
    w.byte('\n');
    return w.len;
}

/// 고정 버퍼에 이어 쓰는 최소 writer. 넘치면 조용히 버린다 — `max_line` 이
/// 모든 줄보다 크다는 것은 아래 테스트가 지킨다.
const Writer = struct {
    buf: []u8,
    len: usize = 0,

    fn byte(self: *Writer, c: u8) void {
        if (self.len >= self.buf.len) return;
        self.buf[self.len] = c;
        self.len += 1;
    }

    fn str(self: *Writer, s: []const u8) void {
        const n = @min(s.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], s[0..n]);
        self.len += n;
    }

    fn print(self: *Writer, comptime fmt: []const u8, args: anytype) void {
        const rest = self.buf[self.len..];
        const out = std.fmt.bufPrint(rest, fmt, args) catch return;
        self.len += out.len;
    }
};

test "같은 kind 는 두 번 읽어도 같은 바이트" {
    for ([_]Kind{ .plain, .ansi, .cjk }) |kind| {
        var a: Generator = .{ .kind = kind };
        var b: Generator = .{ .kind = kind };
        var buf_a: [8192]u8 = undefined;
        var buf_b: [8192]u8 = undefined;
        _ = a.read(&buf_a);
        _ = b.read(&buf_b);
        try std.testing.expectEqualSlices(u8, &buf_a, &buf_b);
    }
}

test "조각 크기가 달라도 스트림은 같다" {
    // 실제 PTY 는 임의 크기로 조각이 온다. 조각 경계가 줄 중간 / UTF-8 문자
    // 중간에 떨어져도 전체 스트림이 흔들리지 않아야 한다.
    for ([_]Kind{ .plain, .ansi, .cjk }) |kind| {
        var whole: Generator = .{ .kind = kind };
        var piecewise: Generator = .{ .kind = kind };

        var expected: [4096]u8 = undefined;
        _ = whole.read(&expected);

        var actual: [4096]u8 = undefined;
        var off: usize = 0;
        var step: usize = 1;
        while (off < actual.len) {
            const n = @min(step, actual.len - off);
            _ = piecewise.read(actual[off..][0..n]);
            off += n;
            step = step * 2 + 1; // 1, 3, 7, 15 … 로 경계를 흩는다
        }

        try std.testing.expectEqualSlices(u8, &expected, &actual);
    }
}

test "줄 단위로 모으면 유효한 UTF-8 이고 개행으로 끝난다" {
    for ([_]Kind{ .plain, .ansi, .cjk }) |kind| {
        var buf: [max_line]u8 = undefined;
        for (0..200) |line| {
            const n = renderLine(kind, line, &buf);
            try std.testing.expect(n > 0);
            try std.testing.expect(n < max_line); // 버림이 없었다
            try std.testing.expectEqual(@as(u8, '\n'), buf[n - 1]);
            try std.testing.expect(std.unicode.utf8ValidateSlice(buf[0..n]));
        }
    }
}

test "plain 줄은 80 byte 로 고정" {
    var buf: [max_line]u8 = undefined;
    for (0..100) |line| {
        try std.testing.expectEqual(@as(usize, 80), renderPlain(line, &buf));
    }
}

test "kind 이름 파싱" {
    try std.testing.expectEqual(@as(?Kind, .plain), Kind.parse("plain"));
    try std.testing.expectEqual(@as(?Kind, .cjk), Kind.parse("cjk"));
    try std.testing.expectEqual(@as(?Kind, null), Kind.parse("nope"));
}
