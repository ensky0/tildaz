//! 결합 기호 · cluster 렌더 검증 화면 — **Linux · macOS · Windows 공용**.
//!
//! ```
//! zig build render-test               # zig-out/bin/render-test 생성
//! tildaz -e <그 경로> -size 88x33      # 세 platform 모두 같은 명령
//! ```
//!
//! **창 높이를 화면에 맞춘다.** 화면은 62 줄인데 그만큼 창을 키우면 노트북에서 **아래가
//! 화면 밖으로 나간다** (실기에서 걸렸다). 33 줄로 띄우고 **스크롤로 본다** — 절이 위아래로
//! 이어져 있어서 스크롤이 판정을 방해하지 않는다. 폭 88 은 가장 긴 줄에 맞춘 값이라 줄이면
//! 줄바꿈이 생겨 `|` 정렬 판정이 깨진다.
//!
//! **왜 셸 스크립트가 아니라 프로그램인가.** 같은 화면을 세 platform 에서 그대로 띄우려면
//! 셸이 달라도 같은 바이트가 나와야 하는데, `printf` 는 구현마다 escape 해석이 다르고
//! Windows 는 cmd 의 CP949 · PowerShell 인코딩까지 얽힌다. 바이트를 프로그램 안에 두면
//! **셸 쪽 변수**가 전부 사라진다. `tildaz -e` 는 세 platform 모두 지원한다 (인자는 못 넘기므로
//! 프로그램이 화면을 전부 그리고 대기한다 — `run_options.zig`).
//!
//! **단 Windows 콘솔의 디코드 단계는 남는다** — 프로그램이 낸 바이트를 콘솔이 출력 코드페이지로
//! 해석하므로 UTF-8 을 직접 선언해야 한다 (아래 `SetConsoleOutputCP`). 이걸 빼면 한국어 Windows
//! 에서 화면 전체가 모지바케가 된다.
//!
//! **결합 문자를 소스에 직접 쓰지 않고 codepoint 배열로 둔다.** 편집기 · 클립보드 · git
//! 이 NFD 를 NFC 로 합쳐 버리면 (`a`+`U+0301` → `á`) 테스트가 조용히 무력해진다 — 화면은
//! 멀쩡해 보이는데 정작 검사하려던 경로를 안 타게 된다.
//!
//! 관련 이슈: #401 (cluster 합성) · #415 (mark 배치) · #416 (script 판정) ·
//! #417 (advance 가 셀보다 큼) · #418 (관통 overlay).

const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const builtin = @import("builtin");

/// Windows 콘솔은 `WriteFile` 로 나간 바이트를 **콘솔 출력 코드페이지**로 디코드한 뒤
/// UTF-16 으로 들고 있고, ConPTY 가 그것을 다시 UTF-8 로 인코딩해 터미널에 보낸다. 한국어
/// Windows 의 기본값은 CP949 라 우리가 낸 UTF-8 바이트가 통째로 모지바케가 된다 (실측:
/// `한글` → `議 고 빅`). **바이트를 프로그램 안에 둔 것만으로는 이 변수가 안 없어진다** —
/// 위 doc comment 가 없앤 것은 셸의 `printf` 구현차이지 콘솔의 디코드 단계가 아니다.
/// 그래서 출력 전에 코드페이지를 UTF-8 로 선언한다. `chcp 65001` 의 API 판이고, 이 프로세스의
/// 콘솔에만 적용된다. Linux · macOS 는 PTY 가 바이트를 그대로 날라서 이 단계가 없다.
extern "kernel32" fn SetConsoleOutputCP(code_page: c_uint) callconv(.winapi) c_int;

// ── 출력 ───────────────────────────────────────────────────────────────────

const Out = struct {
    buf: []u8,
    len: usize = 0,

    fn raw(self: *Out, s: []const u8) void {
        if (self.len + s.len > self.buf.len) return;
        @memcpy(self.buf[self.len..][0..s.len], s);
        self.len += s.len;
    }

    fn print(self: *Out, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch return;
        self.len += s.len;
    }

    /// codepoint 배열을 UTF-8 로 낸다.
    fn cps(self: *Out, list: []const u21) void {
        var b: [4]u8 = undefined;
        for (list) |cp| {
            const n = std.unicode.utf8Encode(@intCast(cp), &b) catch continue;
            self.raw(b[0..n]);
        }
    }

    fn slice(self: *Out) []const u8 {
        return self.buf[0..self.len];
    }
};

const GREEN = "\x1b[32m";
const RESET = "\x1b[0m";

/// `[cluster]|` — 뒤의 `|` 가 **옆 칸 침범 검사**다. mark 가 셀을 넘으면 `|` 가 밀리거나
/// 뭉개진다.
fn cell(o: *Out, list: []const u21) void {
    o.raw("[");
    o.cps(list);
    o.raw("]|");
}

/// 문자열이 터미널에서 차지하는 **칸 수**. 한글 · 한자는 두 칸이다.
///
/// Zig 의 `{s: <N}` 패딩은 **바이트 기준**이라 한글이 든 라벨에서 열이 어긋난다 — `한자+U+0301`
/// 은 13 바이트지만 화면에서는 11 칸이다. 라벨을 세로로 맞추려면 칸 수로 세야 한다.
fn cellWidth(s: []const u8) usize {
    var w: usize = 0;
    const view = std.unicode.Utf8View.init(s) catch return s.len;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        w += switch (cp) {
            0x1100...0x115F,
            0x2E80...0xA4CF,
            0xAC00...0xD7A3,
            0xF900...0xFAFF,
            0xFE30...0xFE4F,
            0xFF00...0xFF60,
            0xFFE0...0xFFE6,
            0x1F300...0x1FAFF,
            => 2,
            else => 1,
        };
    }
    return w;
}

/// 라벨을 **칸 수** 기준으로 채운다.
fn pad(o: *Out, label: []const u8, width: usize) void {
    o.raw(label);
    const w = cellWidth(label);
    var i = w;
    while (i < width) : (i += 1) o.raw(" ");
}

/// 라벨 + `[cluster]|` + `base [기본문자]|` 한 줄. **좌우가 같아 보이면 mark 소실**이다.
fn row(o: *Out, label: []const u8, list: []const u21) void {
    rowGap(o, label, list, 2);
}

/// `row` 인데 `base` 앞 공백 수를 정한다.
///
/// cluster 가 셀보다 넓으면 (Devanagari `क्षि` 는 두 칸을 쓴다) 뒤가 한 칸 밀려 `base` 열이
/// 어긋난다. 그 줄만 공백을 하나 줄여 세로를 맞춘다 — **폭이 넘친다는 사실 자체는 `]|` 가
/// 이미 보여 주므로**, 라벨 열까지 흐트러뜨릴 이유가 없다.
fn rowGap(o: *Out, label: []const u8, list: []const u21, gap: usize) void {
    o.raw("   ");
    pad(o, label, 22);
    cell(o, list);
    var i: usize = 0;
    while (i < gap) : (i += 1) o.raw(" ");
    o.raw("base ");
    cell(o, list[0..1]);
    o.raw("\n");
}

/// base 하나에 mark 를 하나씩 붙여 한 줄로 늘어놓는다. 각 칸 뒤의 `|` 가 **셀 경계 표시**다 —
/// mark 가 셀을 넘으면 그 `|` 가 밀리거나 뭉개져서 눈에 띈다.
fn sweep(o: *Out, base: u21, marks: []const u21) void {
    o.raw("   ");
    for (marks) |m| {
        o.cps(&.{ base, m });
        o.raw("|");
    }
    o.raw("\n");
}

/// 연속판 / 공백판 두 줄. **배칭 경로와 개별 경로가 같은 그림을 내야** 정상이라,
/// 두 줄의 글자 모양이 같아야 한다 (간격만 다르다).
fn batchPair(o: *Out, label: []const u8, items: []const []const u21) void {
    o.raw("   ");
    pad(o, label, 6);
    o.raw("연속  [");
    for (items) |it| o.cps(it);
    o.raw("]\n");
    o.raw("   ");
    pad(o, label, 6);
    o.raw("공백  [");
    for (items, 0..) |it, i| {
        if (i > 0) o.raw(" ");
        o.cps(it);
    }
    o.raw("]\n");
}

// ── 케이스 ─────────────────────────────────────────────────────────────────

const A_ACUTE = [_]u21{ 'a', 0x0301 };
const A_OVERLINE = [_]u21{ 'a', 0x0305 };
const E_ACUTE = [_]u21{ 'e', 0x0301 };
const A_ACUTE_DIA = [_]u21{ 'a', 0x0301, 0x0308 };
const A_DIA_ACUTE = [_]u21{ 'a', 0x0308, 0x0301 };
const LAO = [_]u21{ 0x0E81, 0x0EB4, 0x0EC8 };
const ARABIC_KASRA = [_]u21{ 0x0628, 0x0650 };
const ARABIC_FATHA = [_]u21{ 0x0628, 0x064E };
const Z_OVERLINE = [_]u21{ 'z', 0x0305 };
const G_DIA = [_]u21{ 'g', 0x0308 };
const ZWJ_COUPLE = [_]u21{ 0x1F468, 0x200D, 0x2764, 0xFE0F, 0x200D, 0x1F468 };
const ZWJ_FAMILY = [_]u21{ 0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467 };
const DEVA_KSHI = [_]u21{ 0x0915, 0x094D, 0x0937, 0x093F };

/// 위 mark 와 아래 mark. (C) 절이 base 하나에 이것들을 차례로 붙여 셀 경계를 확인한다.
const MARKS_ABOVE = [_]u21{ 0x0300, 0x0302, 0x0308, 0x0303, 0x0304, 0x0306, 0x0307, 0x030A, 0x030C, 0x0301, 0x030B, 0x0311 };
const MARKS_BELOW = [_]u21{ 0x0323, 0x0327, 0x0328, 0x0331, 0x032E, 0x0330, 0x0324, 0x0325, 0x032D, 0x0326 };

fn sectionA(o: *Out) void {
    o.raw("(A) 전부 초록이어야 정상 — 흰 셀이 있으면 컬러 글리프 경로로 샌 것\n");
    o.raw(GREEN);
    o.raw("   ");
    // 번호는 (B) 의 줄 번호와 같게 둔다 — 흰 셀이 보이면 (B) 의 어느 줄인지 바로 찾는다.
    const items = [_]struct { n: []const u8, cps: []const u21 }{
        .{ .n = "1", .cps = &A_OVERLINE },
        .{ .n = "2", .cps = &E_ACUTE },
        .{ .n = "3", .cps = &A_ACUTE_DIA },
        .{ .n = "4", .cps = &LAO },
        .{ .n = "5", .cps = &ARABIC_KASRA },
        .{ .n = "9", .cps = &Z_OVERLINE },
        .{ .n = "10", .cps = &G_DIA },
    };
    for (items) |it| {
        o.print("{s}", .{it.n});
        o.raw("[");
        o.cps(it.cps);
        o.raw("] ");
    }
    o.raw("\n   abc ");
    o.cps(&.{ 0xAC00, 0xB098, 0xB2E4 });
    o.raw(" ");
    o.cps(&.{ 'e', 0x0301 });
    o.raw(" ");
    o.cps(&.{ 'n', 0x0303 });
    o.raw(" ");
    o.cps(&.{ 'o', 0x0302, 0x0323 });
    o.raw(" ");
    o.cps(&.{ 'k', 0x0336 });
    o.raw(" ");
    o.cps(&.{ 0x0628, 0x0650 });
    // **emoji 는 여기 넣지 않는다.** 컬러 글리프는 원래 자기 색으로 그려져서 늘 흰 셀이 되고,
    // 그러면 "흰 셀 = 컬러 경로로 샜다" 는 이 절의 판정이 무의미해진다. emoji 회귀는 (D) · (J)
    // 가 따로 본다.
    o.raw(RESET);
    o.raw("\n");
}

fn sectionB(o: *Out) void {
    o.raw("(B) [cluster] 가 오른쪽 base 와 달라야 정상 — mark 가 옆 칸(|)을 침범해도 실패\n");
    row(o, "1  a+U+0305", &A_OVERLINE);
    row(o, "2  e+U+0301  ctrl", &E_ACUTE);
    row(o, "3  a+U+0301+U+0308", &A_ACUTE_DIA);
    row(o, "3b a+U+0308+U+0301", &A_DIA_ACUTE);
    row(o, "4  Lao U+0E81+2", &LAO);
    row(o, "5  Arabic U+0628+650", &ARABIC_KASRA);
    row(o, "6  Arabic U+0628+64E", &ARABIC_FATHA);
    row(o, "9  z+U+0305", &Z_OVERLINE);
    row(o, "10 g+U+0308", &G_DIA);
}

fn sectionC(o: *Out) void {
    o.raw("(C) 같은 글자에 mark 를 차례로 — 칸 뒤 | 가 일정 간격이면 정상 (밀리면 셀 밖)\n");
    sweep(o, 'a', &MARKS_ABOVE);
    sweep(o, 'x', &MARKS_ABOVE);
    sweep(o, 'o', &MARKS_BELOW);
    sweep(o, 'd', &MARKS_BELOW);
}

fn sectionD(o: *Out) void {
    o.raw("(D) 회귀 대조군 — 전부 예전 그대로여야 한다\n   ");
    o.cps(&.{ 0xAC00, 0xB098, 0xB2E4, 0xB77C });
    o.raw("  ABCDEFG abcdefg 0123456789  ");
    o.cps(&.{ 'e', 0x0301 });
    o.raw(" ");
    o.cps(&.{ 'n', 0x0303 });
    o.raw(" ");
    o.cps(&.{ 'o', 0x0302, 0x0323 });
    o.raw("\n   ");
    // AGENTS.md 의 표준 회귀 입력과 같은 emoji 세트 — 색 emoji · ZWJ · 스킨톤.
    o.cps(&.{ 0x1F389, 0x2764, 0xFE0F, 0x1F308, 0x1F3A8, 0x1F31E, 0x1F34E, 0x1F680, 0x1F48E, 0x2728 });
    o.raw(" ");
    o.cps(&.{ 0x1F44B, 0x1F3FB });
    o.cps(&.{ 0x1F44B, 0x1F3FD });
    o.cps(&.{ 0x1F44B, 0x1F3FF });
    o.raw("\n   ");
    o.cps(&ZWJ_COUPLE);
    o.raw(" ");
    o.cps(&ZWJ_FAMILY);
    o.raw(" ");
    o.cps(&.{ 0x1F468, 0x200D, 0x1F468, 0x200D, 0x1F466, 0x200D, 0x1F466 });
    o.raw(" ");
    o.cps(&.{ 0x1F3F3, 0xFE0F, 0x200D, 0x1F308 });
    o.raw("\n   ");
    // block element — **세로로 반만 찬 것들 (`▌` `▐`) 까지 전부** 넣는다. 부분 블록은 셀
    // 경계에 딱 맞아야 해서 폭 · 정렬 회귀가 제일 먼저 드러나는 자리다.
    o.cps(&.{
        0x2580, 0x2581, 0x2582, 0x2583, 0x2584, 0x2585, 0x2586, 0x2587,
        0x2588, 0x2589, 0x258A, 0x258B, 0x258C, 0x258D, 0x258E, 0x258F,
        0x2590, 0x2591, 0x2592, 0x2593, 0x2594, 0x2595,
    });
    o.raw("\n");
}

fn sectionE(o: *Out) void {
    o.raw("(E) 연속 조합 — mark 3 개 이상이 위아래로 쌓여야 정상\n");
    row(o, "a+301+308+323", &.{ 'a', 0x0301, 0x0308, 0x0323 });
    row(o, "o+302+323", &.{ 'o', 0x0302, 0x0323 });
    row(o, "u+308+304", &.{ 'u', 0x0308, 0x0304 });
    row(o, "z+301+327+331", &.{ 'z', 0x0301, 0x0327, 0x0331 });
    row(o, "e+300+301+302+303", &.{ 'e', 0x0300, 0x0301, 0x0302, 0x0303 });
}

fn sectionF(o: *Out) void {
    o.raw("(F) 배칭 — 두 줄의 글자 모양이 같아야 정상 (간격만 다르다)\n");
    batchPair(o, "라틴", &.{
        &.{ 'a', 0x0301 }, &.{ 'e', 0x0301 }, &.{ 'i', 0x0301 }, &.{ 'o', 0x0301 }, &.{ 'u', 0x0301 },
    });
    batchPair(o, "emoji", &.{ &ZWJ_COUPLE, &ZWJ_FAMILY });
}

fn sectionG(o: *Out) void {
    o.raw("(G) cluster 폭 — | 가 세로로 맞아야 정상\n   ");
    const items = [_][]const u21{
        &.{'d'}, &.{'h'}, &.{'k'}, &.{ 'n', 0x0303 }, &.{ 'x', 0x0308 }, &DEVA_KSHI,
    };
    for (items) |it| {
        o.cps(it);
        o.raw("|");
    }
    o.raw("\n   ");
    // 위 줄과 **같은 칸 수**로 늘어놓는다 — `|` 가 세로로 맞는지 보려면 비교 대상이 있어야 한다.
    for (0..4) |_| {
        o.cps(&DEVA_KSHI);
        o.raw("|");
    }
    o.raw("\n");
}

fn sectionH(o: *Out) void {
    o.raw("(H) overline 높이 — 여섯 개가 다 같은 높이여야 정상 (계단이면 실패)\n   [");
    for ("abcdef") |c| o.cps(&.{ @intCast(c), 0x0305 });
    o.raw("]\n   [");
    for ("abcdef", 0..) |c, i| {
        if (i > 0) o.raw(" ");
        o.cps(&.{ @intCast(c), 0x0305 });
    }
    o.raw("]\n");
}

fn sectionI(o: *Out) void {
    o.raw("(I) 관통 overlay — 글자 가운데를 선이 지나야 정상 (옆 칸에 있으면 실패)\n");
    row(o, "k+U+0336 긴취소선", &.{ 'k', 0x0336 });
    row(o, "k+U+0335 짧은취소선", &.{ 'k', 0x0335 });
    row(o, "a+U+0338 사선", &.{ 'a', 0x0338 });
    row(o, "O+U+0337 짧은사선", &.{ 'O', 0x0337 });
}

fn sectionJ(o: *Out) void {
    o.raw("(J) emoji 시퀀스 — keycap · 국기 · 스킨톤 · 가족 · 깃발\n   ");
    const items = [_][]const u21{
        &.{ '1', 0xFE0F, 0x20E3 },
        &.{ '#', 0xFE0F, 0x20E3 },
        &.{ 0x1F1F0, 0x1F1F7 },
        &.{ 0x1F1FA, 0x1F1F8 },
        &.{ 0x1F44B, 0x1F3FB },
        &.{ 0x1F44B, 0x1F3FF },
        &ZWJ_FAMILY,
        &.{ 0x1F3F4, 0x200D, 0x2620, 0xFE0F },
        &.{ 0x2764, 0xFE0F, 0x200D, 0x1F525 },
        &.{ 0x1F3F4, 0xE0067, 0xE0062, 0xE0073, 0xE0063, 0xE0074, 0xE007F },
    };
    for (items) |it| {
        o.raw("[");
        o.cps(it);
        o.raw("]");
    }
    o.raw("\n");
}

fn sectionK(o: *Out) void {
    o.raw("(K) 폰트 유무 · advance — | 를 침범하면 셀보다 넓은 것\n");
    row(o, "Arabic beh", &.{0x0628});
    row(o, "Arabic alef", &.{0x0627});
    row(o, "Devanagari ka", &.{0x0915});
    rowGap(o, "Devanagari kshi", &DEVA_KSHI, 1);
    row(o, "Thai ko+2", &.{ 0x0E01, 0x0E34, 0x0E48 });
    row(o, "Hebrew alef+qamats", &.{ 0x05D0, 0x05B8 });
    // 뒤에 글자를 **바로 붙여** 침범을 눈에 보이게 한다. `|` 하나만 두면 겹쳐도 애매하다 —
    // `ABC` 의 `A` 가 가려지거나 뭉개지면 그 글자가 배정된 칸을 넘은 것이다 (#417).
    o.raw("   ");
    pad(o, "침범 확인 (A 가 온전한가)", 26);
    o.cps(&DEVA_KSHI);
    o.raw("ABC  ");
    o.cps(&.{0x0915});
    o.raw("ABC  ");
    o.cps(&.{ 0x0E01, 0x0E34, 0x0E48 });
    o.raw("ABC  aABC\n");
}

fn sectionL(o: *Out) void {
    o.raw("(L) 한글 조합형 · wide 글자 + mark\n");
    row(o, "조합형 L+V", &.{ 0x1100, 0x1161 });
    row(o, "조합형 L+V+T", &.{ 0x1100, 0x1161, 0x11A8 });
    row(o, "완성형+U+0301", &.{ 0xAC00, 0x0301 });
    row(o, "한자+U+0301", &.{ 0x6F22, 0x0301 });
    row(o, "가나 濁点", &.{ 0x304B, 0x3099 });
}

pub fn main(init: std.process.Init) !void {
    // #451 — 진입점이 `Io` 를 받는다 (릴리즈 노트 *"Juicy Main"*). 이 하네스는 stdout 쓰기와
    // 대기밖에 하지 않으므로 `Runtime` 하나면 충분하다.
    const rt: Runtime = .fromInit(init);
    if (builtin.os.tag == .windows) _ = SetConsoleOutputCP(65001);

    var storage: [1 << 16]u8 = undefined;
    var o = Out{ .buf = &storage };

    o.raw("===== TildaZ 렌더 검증 — #401 · #415~421  (현황판 #422) =====\n");
    sectionA(&o);
    sectionB(&o);
    sectionC(&o);
    sectionD(&o);
    sectionE(&o);
    sectionF(&o);
    sectionG(&o);
    sectionH(&o);
    sectionI(&o);
    sectionJ(&o);
    sectionK(&o);
    sectionL(&o);

    try std.Io.File.stdout().writeStreamingAll(rt.io, o.slice());

    // `-e` 로 띄운 프로세스가 끝나면 앱도 함께 닫힌다. 화면을 보라고 띄운 것이므로 남긴다.
    while (true) rt.sleepNs(60 * std.time.ns_per_s);
}
