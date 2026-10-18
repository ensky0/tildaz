//! 글꼴에 없는 bold · italic 을 합성할 때의 값 (#759). 세 OS 공용.
//!
//! **값은 여기 한 곳에만 둔다.** 각 OS 의 글꼴 코드는 이 값을 받아 자기 API 로 적용만 한다 —
//! Linux 는 FreeType 외곽선, macOS 는 CoreText 행렬과 외곽선 덧그리기, Windows 는 DirectWrite
//! 변환 행렬이다. 값을 OS 마다 두면 같은 `printf '\e[3m…'` 가 OS 마다 다르게 기운다.
//!
//! | | 값 | 근거 |
//! |---|---|---|
//! | 기울기 | 0.2 (11.3°) | fontconfig 기본 설정 (`90-synthetic.conf`) · WezTerm · iTerm2 와 같다. DirectWrite 의 합성 (0.340, Windows 11 25H2 실측) 은 쓰지 않는다 |
//! | 굵기 | 획을 em/50 굵힌다 (가로) | DirectWrite 합성 bold 의 실측값. DirectWrite 는 양을 바꿀 수 없어서 macOS · Linux 가 맞춘다 |
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

/// 굵기 — 획이 두꺼워지는 양을 글자 크기 (em) 에 대한 비로 적는다. 가로로만 굵힌다.
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
