//! 글꼴에 없는 bold · italic 을 합성할 때의 값 (#759). 세 OS 공용.
//!
//! **값은 여기 한 곳에만 둔다.** 각 OS 의 글꼴 코드는 이 값을 받아 자기 API 로 적용만 한다 —
//! Linux 는 FreeType 외곽선, macOS 는 CoreText 행렬과 외곽선 덧그리기, Windows 는 DirectWrite
//! 변환 행렬이다. 값을 OS 마다 두면 같은 `printf '\e[3m…'` 가 OS 마다 다르게 기운다.
//!
//! | | 값 | 근거 |
//! |---|---|---|
//! | 기울기 | 0.2 (11.3°) | fontconfig 기본 설정 (`90-synthetic.conf`) · WezTerm · iTerm2 와 같다. DirectWrite 의 합성 (0.340, Windows 11 25H2 실측) 은 쓰지 않는다 |
//! | 굵기 | 획을 em/50 굵힌다 (가로 · 세로 모두) | DirectWrite 합성 bold 의 실측값 — 세로획 em/50, 가로획도 약 em/50 (Windows 11 25H2). DirectWrite 는 양을 바꿀 수 없어서 macOS · Linux 가 맞춘다 |
//!
//! 두 값은 2026-10-17 사용자 결정이다 (#759 질문과 답 · 구현 계획 댓글). 글자 간격은 넓히지
//! 않는다 — 터미널은 글자를 칸 단위로 놓아서 간격을 쓰지 않는다.
//!
//! **언제 합성하나** — 그 스타일을 요청했는데 글꼴에 그 파일이 없을 때다. 무엇으로 "없다" 를
//! 아는지는 OS 마다 다르다 (Linux 는 fontconfig 가 붙여 주는 `embolden` · 기울임 행렬,
//! macOS 는 `CTFontCreateCopyWithSymbolicTraits` 가 변종을 못 찾음, Windows 는 DirectWrite 의
//! `GetSimulations`).

const std = @import("std");

/// 기울기 — 세로로 1 올라갈 때 가로로 옮기는 양. 위가 오른쪽으로 간다.
pub const slant: f64 = 0.2;

/// 굵기 — 획이 두꺼워지는 양을 글자 크기 (em) 에 대한 비로 적는다. 가로 · 세로로 같은 양을 굵힌다
/// (DirectWrite 가 위아래로도 굵히는 것을 2026-10-18 Windows 측정에서 확인 — #759).
pub const embolden_per_em: f64 = 1.0 / 50.0;

/// 어떤 합성을 할지. 둘 다 거짓이면 합성하지 않는다.
pub const Synthetic = packed struct(u2) {
    bold: bool = false,
    italic: bool = false,

    pub fn any(self: Synthetic) bool {
        return self.bold or self.italic;
    }
};

/// 글자 크기 `em_px` 에서 획이 두꺼워지는 양 (px).
pub fn emboldenPx(em_px: f64) f64 {
    return em_px * embolden_per_em;
}

/// 저장소 (atlas) 키의 글꼴 id 에 합성 여부를 섞는다. 합성한 글꼴은 regular 와 이름 (PostScript)
/// 이 같아서, 섞지 않으면 기울인 그림과 똑바른 그림이 한 칸을 나눠 쓴다 — Windows 가
/// [#749](https://github.com/ensky0/tildaz/issues/749) 에서 겪은 결함이다. 합성이 없으면 값이 그대로다.
pub fn mixId(id: u64, s: Synthetic) u64 {
    if (id == 0 or !s.any()) return id;
    var h = id;
    for ([_]u8{ '+', 's', 'y', 'n', @as(u8, @as(u2, @bitCast(s))) }) |b| {
        h ^= @as(u64, b);
        h *%= 0x100000001b3;
    }
    return h;
}

test "mixId — 합성이 없으면 그대로, 있으면 종류마다 갈린다" {
    const base: u64 = 0x1234_5678_9abc_def0;
    try std.testing.expectEqual(base, mixId(base, .{}));
    const b = mixId(base, .{ .bold = true });
    const i = mixId(base, .{ .italic = true });
    const bi = mixId(base, .{ .bold = true, .italic = true });
    try std.testing.expect(b != base and i != base and bi != base);
    try std.testing.expect(b != i and b != bi and i != bi);
    try std.testing.expectEqual(@as(u64, 0), mixId(0, .{ .italic = true }));
}

test "기울기는 0.2 — 11.3° 다" {
    const deg = std.math.atan(slant) * 180.0 / std.math.pi;
    try std.testing.expectApproxEqAbs(@as(f64, 11.31), deg, 0.01);
}

test "굵기는 em/50 — 글자 크기 50 px 에서 1 px" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), emboldenPx(50), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), emboldenPx(20), 1e-9);
}

test "Synthetic.any" {
    try std.testing.expect(!(Synthetic{}).any());
    try std.testing.expect((Synthetic{ .bold = true }).any());
    try std.testing.expect((Synthetic{ .italic = true }).any());
}
