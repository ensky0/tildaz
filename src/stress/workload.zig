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

    // --- 귀속용 (#381) — `cjk` 가 섞어 쓰는 경로를 하나씩만 태운다 ------------
    //
    // 넷 다 한 줄의 구조가 같다 (앞머리 10 열 + 항목 `attr_items` 개). 그래서
    // MiB/s 에서 줄 수를 역산하면 (`MiB/s ÷ 줄 byte`) 셀 기준으로 나란히 비교할 수
    // 있다 — 줄마다 byte 수는 경로마다 다르므로 (한글 3 · VS-16 emoji 6 · 스킨톤 8 ·
    // ZWJ 묶음 18 byte) MiB/s 를 그대로 비교하면 안 된다.

    /// 한글만. **wide cell 은 태우고 grapheme extras 는 안 태운다** — BMP
    /// codepoint 하나가 셀 하나라 `cell.grapheme` 저장 경로를 지나지 않는다.
    hangul,
    /// `❤️` (U+2764 U+FE0F) 만. **VS-16 경로** — codepoint 두 개가 한 grapheme 으로
    /// 묶이고 셀이 wide 로 바뀐다.
    emoji_vs16,
    /// `👋🏻` (U+1F44B U+1F3FB) 만. **스킨톤 modifier 경로** — non-BMP codepoint 두
    /// 개가 한 grapheme 이다. `emoji_vs16` 과 codepoint 수는 같고 base 가 non-BMP 다.
    skintone,
    /// `👨‍👩‍👧` 만. **ZWJ 묶음 경로** — codepoint 다섯 개 (emoji 3 + ZWJ 2) 가 한
    /// grapheme 이다. grapheme extras 가 가장 깊게 쌓이는 경로다.
    zwj,

    // --- 종류 다양성 (#381) — 위 넷과 **짝**이다 ------------------------------
    //
    // 위 넷은 항목이 한두 종류라 캐시 hit 율이 사실상 100 % 다 — "캐시에 가장
    // 유리한 극단" 이다. 아래 넷은 같은 경로 · 같은 줄 byte 인 채 **종류만** 늘려
    // 반대쪽 극단을 만든다. 짝 사이의 차이가 곧 *조회 반복이 병목에서 차지하는 몫*
    // 이고, 그 값이 shaping 호출 자체를 줄일지 (run 배칭) 결과를 캐시할지
    // (cluster 캐시) 를 가른다.

    /// 완성형 한글 음절 (`가`~`힣`) 을 순회한다. `hangul` 과 같은 경로이고
    /// **glyph atlas / rasterize** 몫만 달라진다.
    hangul_varied,
    /// text presentation 이 기본인 BMP 기호 여러 종에 VS-16 을 붙인다.
    emoji_vs16_varied,
    /// base emoji 여러 종 × 스킨톤 다섯을 조합한다.
    skintone_varied,
    /// 3 인 가족 ZWJ 묶음 여러 종을 순회한다.
    zwj_varied,

    pub fn parse(name: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, name);
    }
};

/// 한 줄이 넘지 않는 크기. `zwj` 계열이 가장 길다 — 앞머리 10 + 18 byte × 13 개 +
/// 개행 = 245 byte.
const max_line = 512;

/// 귀속용 워크로드 한 줄이 담는 항목 수. **최악의 표시 폭**으로 정한다 (#381).
///
/// 우리는 `👨‍👩‍👧` 를 한 grapheme 으로 접어 2 열에 그리지만, **ZWJ 를 안 접는 터미널은
/// 구성원 emoji 세 개를 따로 그린다.** 그때 한 항목이 몇 열이냐가 이 상수를 정한다.
///
/// | 세는 방식 | 항목당 열 |
/// |---|---:|
/// | 한 grapheme 으로 접는다 (우리 · Windows Terminal) | 2 |
/// | 구성원만 세고 ZWJ 는 0 열 (`Cf` · default-ignorable 이므로) | 6 |
/// | **구성원 + ZWJ 도 1 열씩** | **8** |
///
/// 처음엔 가운데 줄 (6 열) 을 최악으로 보고 `110 ÷ 6 = 18` 을 썼다. 그런데 **Windows 실기에서
/// alacritty · wezterm 이 ZWJ 를 1 열로 세는 것이 확인됐다** (#381). 그러면 한 항목이
/// `👨(2) + ZWJ(1) + 👩(2) + ZWJ(1) + 👧(2) = 8` 열이라 한 줄이 `10 + 18 × 8 = 154` 열이 되어
/// 120 열 격자를 넘는다.
///
/// 넘는 지점이 하필 한 grapheme 한가운데라 **그 항목 하나가 앞뒤로 쪼개져 합성이 깨진 채**
/// 그려졌다. 실제 출력이 계산과 정확히 맞았다 — `10 + 13 × 8 = 114` 까지 온전하고, 남은 6 열에
/// `👨‍👩‍` (2+1+2+1) 가 들어간 뒤 `👧` 가 다음 행으로 넘어갔다.
///
/// 그래서 최악을 8 열로 잡고 다시 푼다: `10 + N × 8 ≤ 120` → **N = 13**.
///
/// 접히면 대상마다 줄 수가 달라져 비교 자체가 성립하지 않는다 — 열 수가 줄바꿈 횟수를
/// 바꾸기 때문이고, `측정 중 resize` 검사에는 안 걸리는 종류다. 처음의 35 개
/// (= `cjk` 와 같은 80 열) 도 같은 이유로 버렸다 — 그건 **접는 터미널에서만** 80 열이었다.
///
/// 접는 터미널에서 `10 + 13 × 2 = 36` 열로 격자보다 짧은 것은 의도다.
///
/// **ZWJ 를 2 열로 세는 터미널이 나오면 이 값을 또 내려야 한다** (항목당 10 열 → N = 11).
/// 판정은 `--capture` 로 찍어 줄이 접혔는지 눈으로 본다 — 번호 줄 사이에 조각 줄이 끼면
/// 접힌 것이다.
const attr_items = 13;

/// `hangul` 이 도는 여섯 음절.
const hangul_items = [_][]const u8{ "가", "나", "다", "라", "한", "글" };

/// `hangul_varied` 가 훑는 완성형 한글 음절 (U+AC00 ~ U+D7A3). **전부 3 byte** 라
/// 줄 byte 가 흔들리지 않는다.
const hangul_first: u21 = 0xAC00;
const hangul_count: usize = 11172;

/// `emoji_vs16_varied` 의 기호들. **text presentation 이 기본인 BMP 기호**만 골랐다 —
/// VS-16 이 실제로 표시를 바꾸는 것들이고, BMP 라 3 byte + U+FE0F 3 byte = 6 byte 로
/// `emoji_vs16` 과 항목 byte 가 같다.
const emoji_vs16_items = [_][]const u8{
    "❤️", "☀️", "☁️", "☂️", "☃️", "☎️", "☘️", "☠️", "☢️", "☣️",
    "☮️", "☯️", "♠️", "♣️", "♥️", "♦️", "♻️", "⚠️", "✈️", "✉️",
};

/// `zwj_varied` 의 3 인 가족 묶음. 구성원이 전부 non-BMP (4 byte) 라 항목이
/// `4 × 3 + 3 × 2 = 18` byte 로 `zwj` 와 같다. **2 인 묶음을 섞으면 11 byte 라 줄
/// byte 가 흔들린다** — 섞고 싶으면 별도 워크로드로 나눈다.
const zwj_items = [_][]const u8{
    "👨‍👩‍👦", "👨‍👩‍👧", "👨‍👨‍👦", "👨‍👨‍👧", "👩‍👩‍👦", "👩‍👩‍👧",
    "👨‍👦‍👦", "👨‍👧‍👦", "👨‍👧‍👧", "👩‍👦‍👦", "👩‍👧‍👦", "👩‍👧‍👧",
};

/// `skintone_varied` 의 base emoji. **전부 non-BMP (4 byte)** 로만 골랐다 — 스킨톤을
/// 받는 BMP 기호 (`✋` U+270B 등) 를 섞으면 항목이 7 byte 가 되어 줄 byte 가 흔들린다.
const skintone_bases = [_][]const u8{
    "👋", "🤚", "👌", "🤌", "🤏", "🤞", "🤟", "🤘", "🤙", "👈",
    "👉", "👆", "👇", "👍", "👎", "👊", "🤛", "🤜", "👏", "🙌",
    "👐", "🤲", "🙏", "💪", "🤳",
};

/// Fitzpatrick 스킨톤 modifier 다섯 (U+1F3FB ~ U+1F3FF). 각 4 byte.
const skin_tone_first: u21 = 0x1F3FB;
const skin_tone_count: usize = 5;

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

        .hangul => renderRepeat(line, buf, &hangul_items),
        .emoji_vs16 => renderRepeat(line, buf, &.{"❤️"}),
        .skintone => renderRepeat(line, buf, &.{"👋🏻"}),
        .zwj => renderRepeat(line, buf, &.{"👨‍👩‍👧"}),

        .hangul_varied => renderVariedCp(line, buf, hangul_first, hangul_count),
        .emoji_vs16_varied => renderVaried(line, buf, &emoji_vs16_items),
        .skintone_varied => renderSkintoneVaried(line, buf),
        .zwj_varied => renderVaried(line, buf, &zwj_items),
    };
}

/// 귀속용 (#381) — 항목 하나를 `attr_items` 개 반복한다. `items` 가 여럿이면 줄마다
/// 한 칸씩 회전시켜 같은 내용이 반복되지 않게 한다 (`renderPlain` 의 filler 회전과
/// 같은 이유 — page 재사용 최적화가 우연히 유리하게 걸리지 않도록).
///
/// **종류가 적은 쪽 (`hangul` 6 · 나머지 1) 전용이다.** 종류가 많으면 이 회전으로는
/// 한 화면에 종류가 거의 안 올라온다 (줄마다 1 칸이라 40 행에 `attr_items + 39` 종류)
/// — 그래서 varied 쪽은 `renderVaried` 의 전역 색인을 쓴다.
fn renderRepeat(line: usize, buf: []u8, items: []const []const u8) usize {
    var w = Writer{ .buf = buf };
    w.print("{d:0>9} ", .{line});
    for (0..attr_items) |i| {
        w.str(items[(line + i) % items.len]);
    }
    w.byte('\n');
    return w.len;
}

/// varied 워크로드가 훑는 **전역 항목 색인**. 줄마다 `attr_items` 만큼 전진하므로 한
/// 화면 (40 행) 에 `40 × attr_items` = 520 종류까지 동시에 올라온다. 재는 것이 캐시 ·
/// atlas 의 hit 율이라 *화면에 동시에 있는 종류 수*가 핵심이다.
///
/// `renderRepeat` 의 회전 (`line + i`) 을 쓰면 안 된다 — 그건 줄마다 1 칸만 밀어서
/// 종류가 많아도 화면에 `40 + attr_items - 1` = 52 종류밖에 안 올라온다. 반대로 종류가
/// 적은 쪽에 이 색인을 쓰면 `attr_items % items.len == 0` 일 때 모든 줄이 똑같아진다
/// (`attr_items` 가 소수인 13 이라 지금은 항목이 13 개일 때만 걸린다).
inline fn globalIndex(line: usize, i: usize) usize {
    return line *% attr_items +% i;
}

/// 종류가 많은 항목 집합을 전역 색인으로 훑는다.
fn renderVaried(line: usize, buf: []u8, items: []const []const u8) usize {
    var w = Writer{ .buf = buf };
    w.print("{d:0>9} ", .{line});
    for (0..attr_items) |i| {
        w.str(items[globalIndex(line, i) % items.len]);
    }
    w.byte('\n');
    return w.len;
}

/// 연속한 codepoint 범위를 전역 색인으로 훑는다 (`hangul_varied` 의 `가`~`힣`).
/// 항목 표를 11,172 개 적어 두지 않기 위한 경로다.
fn renderVariedCp(line: usize, buf: []u8, first: u21, count: usize) usize {
    var w = Writer{ .buf = buf };
    w.print("{d:0>9} ", .{line});
    for (0..attr_items) |i| {
        w.codepoint(first + @as(u21, @intCast(globalIndex(line, i) % count)));
    }
    w.byte('\n');
    return w.len;
}

/// base emoji × 스킨톤 조합을 전역 색인으로 훑는다. base 가 먼저 돌고 한 바퀴마다
/// 스킨톤이 넘어가서, `skintone_bases.len × skin_tone_count` = 125 종류가 다 나온다.
fn renderSkintoneVaried(line: usize, buf: []u8) usize {
    var w = Writer{ .buf = buf };
    w.print("{d:0>9} ", .{line});
    for (0..attr_items) |i| {
        const k = globalIndex(line, i);
        w.str(skintone_bases[k % skintone_bases.len]);
        const tone = (k / skintone_bases.len) % skin_tone_count;
        w.codepoint(skin_tone_first + @as(u21, @intCast(tone)));
    }
    w.byte('\n');
    return w.len;
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

    /// codepoint 를 UTF-8 로 쓴다. 호출처가 넘기는 값은 컴파일 시점에 정해진 범위
    /// (`hangul_first` · `skin_tone_first` 기준) 라 인코딩이 실패할 수 없다 —
    /// 조용히 버리면 줄 byte 가 어긋나므로 여기서는 버리지 않는다.
    fn codepoint(self: *Writer, c: u21) void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c, &tmp) catch unreachable;
        self.str(tmp[0..n]);
    }

    fn print(self: *Writer, comptime fmt: []const u8, args: anytype) void {
        const rest = self.buf[self.len..];
        const out = std.fmt.bufPrint(rest, fmt, args) catch return;
        self.len += out.len;
    }
};

test "같은 kind 는 두 번 읽어도 같은 바이트" {
    for (std.enums.values(Kind)) |kind| {
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
    for (std.enums.values(Kind)) |kind| {
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
    for (std.enums.values(Kind)) |kind| {
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

/// 귀속 워크로드의 항목 byte. 짝 (`X` · `X_varied`) 은 같은 값을 쓴다.
const attr_cases = [_]struct { kind: Kind, item_bytes: usize, distinct: usize }{
    // 한글 3 byte. 40 행 × 13 개 = 520 개를 연속으로 훑으므로 varied 는 520 종류다.
    .{ .kind = .hangul, .item_bytes = 3, .distinct = hangul_items.len },
    .{ .kind = .hangul_varied, .item_bytes = 3, .distinct = 40 * attr_items },
    // U+2764 3 + U+FE0F 3.
    .{ .kind = .emoji_vs16, .item_bytes = 6, .distinct = 1 },
    .{ .kind = .emoji_vs16_varied, .item_bytes = 6, .distinct = emoji_vs16_items.len },
    // base 4 + modifier 4.
    .{ .kind = .skintone, .item_bytes = 8, .distinct = 1 },
    .{ .kind = .skintone_varied, .item_bytes = 8, .distinct = skintone_bases.len * skin_tone_count },
    // emoji 4×3 + ZWJ 3×2.
    .{ .kind = .zwj, .item_bytes = 18, .distinct = 1 },
    .{ .kind = .zwj_varied, .item_bytes = 18, .distinct = zwj_items.len },
};

test "귀속 워크로드는 줄 byte 가 고정" {
    // #381 의 분석이 이 값으로 MiB/s → 줄/초 를 역산한다. 바뀌면 그 수치가 조용히
    // 어긋나므로 못 박아 둔다. 앞머리 10 + 항목 `attr_items` 개 + 개행 1.
    //
    // **짝끼리 값이 같은 것도 여기서 지킨다** — `X` 와 `X_varied` 의 차이가 종류 수
    // 하나로만 남아야 캐시 hit 율의 몫을 가릴 수 있다 (#381 의 (A)/(B) 판정).
    var buf: [max_line]u8 = undefined;
    for (attr_cases) |c| {
        const want = 10 + attr_items * c.item_bytes + 1;
        // `hangul_varied` 의 범위 (11,172) 를 한 바퀴 넘게 돈다 — 범위 어디서도 항목
        // byte 가 3 이라는 것까지 확인한다.
        for (0..700) |line| {
            try std.testing.expectEqual(want, renderLine(c.kind, line, &buf));
        }
    }
}

test "varied 워크로드는 한 화면에 여러 종류를 올린다" {
    // 이 워크로드들의 **존재 이유**가 종류 수다 (#381). 종류 수가 캐시 · atlas 의
    // hit 율을 정하고, 그 hit 율이 shaping 호출을 줄일지 (run 배칭) 결과를 캐시할지
    // (cluster 캐시) 를 가른다. 짝과 종류 수가 같아지면 판정이 불가능해진다.
    const rows = 40; // 비교 격자의 행 수 (`--rows 40`)
    var buf: [max_line]u8 = undefined;

    for (attr_cases) |c| {
        var seen = std.AutoHashMap([18]u8, void).init(std.testing.allocator);
        defer seen.deinit();

        for (0..rows) |line| {
            const n = renderLine(c.kind, line, &buf);
            try std.testing.expectEqual(10 + attr_items * c.item_bytes + 1, n);
            for (0..attr_items) |i| {
                // 항목이 고정 byte 라 앞머리 10 부터 잘라내면 된다. 짧은 항목은
                // 0 으로 채워 키 길이를 맞춘다 (가장 긴 항목이 18 byte).
                var key = [_]u8{0} ** 18;
                @memcpy(key[0..c.item_bytes], buf[10 + i * c.item_bytes ..][0..c.item_bytes]);
                try seen.put(key, {});
            }
        }
        try std.testing.expectEqual(c.distinct, seen.count());
    }
}

test "kind 이름 파싱" {
    try std.testing.expectEqual(@as(?Kind, .plain), Kind.parse("plain"));
    try std.testing.expectEqual(@as(?Kind, .cjk), Kind.parse("cjk"));
    try std.testing.expectEqual(@as(?Kind, .skintone), Kind.parse("skintone"));
    try std.testing.expectEqual(@as(?Kind, .zwj_varied), Kind.parse("zwj_varied"));
    try std.testing.expectEqual(@as(?Kind, null), Kind.parse("nope"));
}
