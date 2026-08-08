//! 결합 기호 · cluster 렌더 검증 화면 — **Linux · macOS · Windows 공용**.
//!
//! ```
//! zig build render-test          # zig-out/bin/render-test 생성
//! tildaz -e <그 경로> -size 84x44 # 세 platform 모두 같은 명령
//! ```
//!
//! **왜 셸 스크립트가 아니라 프로그램인가.** 같은 화면을 세 platform 에서 그대로 띄우려면
//! 셸이 달라도 같은 바이트가 나와야 하는데, `printf` 는 구현마다 escape 해석이 다르고
//! Windows 는 cmd 의 CP949 · PowerShell 인코딩까지 얽힌다. 바이트를 프로그램 안에 두면
//! 그 변수가 전부 사라진다. `tildaz -e` 는 세 platform 모두 지원한다 (인자는 못 넘기므로
//! 프로그램이 화면을 전부 그리고 대기한다 — `run_options.zig`).
//!
//! **결합 문자를 소스에 직접 쓰지 않고 codepoint 배열로 둔다.** 편집기 · 클립보드 · git
//! 이 NFD 를 NFC 로 합쳐 버리면 (`a`+`U+0301` → `á`) 테스트가 조용히 무력해진다 — 화면은
//! 멀쩡해 보이는데 정작 검사하려던 경로를 안 타게 된다.
//!
//! 관련 이슈: #401 (cluster 합성) · #415 (mark 배치) · #416 (script 판정) ·
//! #417 (advance 가 셀보다 큼) · #418 (관통 overlay).

const std = @import("std");

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

/// 라벨 + `[cluster]|` + `base [기본문자]|` 한 줄. **좌우가 같아 보이면 mark 소실**이다.
fn row(o: *Out, label: []const u8, list: []const u21) void {
    o.print("   {s: <22}", .{label});
    cell(o, list);
    o.raw("  base ");
    cell(o, list[0..1]);
    o.raw("\n");
}

/// base 하나에 mark 여러 개를 각각 붙여 한 줄로. 각 칸 뒤에 `|` 가 붙는다.
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
    o.print("   {s} 연속  [", .{label});
    for (items) |it| o.cps(it);
    o.raw("]\n");
    o.print("   {s} 공백  [", .{label});
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

/// 결합 기호 sweep 에 쓰는 mark 들 — 위 · 아래 · 관통이 섞여 있다.
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
    o.raw("(C) 결합 기호 sweep — 각 칸 뒤에 | 가 붙어 있다. | 가 밀리면 셀 밖\n");
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
    for (0..3) |_| {
        o.cps(&DEVA_KSHI);
        o.raw("|");
    }
    o.raw("\n");
}

fn sectionH(o: *Out) void {
    o.raw("(H) overline 높이 — b d f 위만 높으면 정상 (위로 긴 글자를 피해 올라간다)\n   [");
    for ("abcdef") |c| o.cps(&.{ @intCast(c), 0x0305 });
    o.raw("]\n   [");
    for ("abcdef", 0..) |c, i| {
        if (i > 0) o.raw(" ");
        o.cps(&.{ @intCast(c), 0x0305 });
    }
    o.raw("]\n\n");
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
    row(o, "Devanagari kshi", &DEVA_KSHI);
    row(o, "Thai ko+2", &.{ 0x0E01, 0x0E34, 0x0E48 });
    row(o, "Hebrew alef+qamats", &.{ 0x05D0, 0x05B8 });
}

fn sectionL(o: *Out) void {
    o.raw("(L) 한글 조합형 · wide 글자 + mark\n");
    row(o, "조합형 L+V", &.{ 0x1100, 0x1161 });
    row(o, "조합형 L+V+T", &.{ 0x1100, 0x1161, 0x11A8 });
    row(o, "완성형+U+0301", &.{ 0xAC00, 0x0301 });
    row(o, "한자+U+0301", &.{ 0x6F22, 0x0301 });
    row(o, "가나 濁点", &.{ 0x304B, 0x3099 });
}

pub fn main() !void {
    var storage: [1 << 16]u8 = undefined;
    var o = Out{ .buf = &storage };

    o.raw("===== TildaZ 렌더 검증 — #401 / #415 / #416 / #417 / #418 =====\n");
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

    try std.fs.File.stdout().writeAll(o.slice());

    // `-e` 로 띄운 프로세스가 끝나면 앱도 함께 닫힌다. 화면을 보라고 띄운 것이므로 남긴다.
    while (true) std.Thread.sleep(60 * std.time.ns_per_s);
}
