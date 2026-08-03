//! SGR 선 속성 — `underline` (5 종) · `strikethrough` · `overline` 의
//! 사각형 조립 (#365 · #374). 세 renderer (Linux software / macOS Metal / Windows d3d11)
//! 공통 정책. [`cell_color.zig`](cell_color.zig) · [`block_element.zig`](block_element.zig)
//! 와 같은 패턴이다 — **정책은 여기 한 곳, platform 은 자기 목록에 넣는 것만.**
//!
//! ## 좌표 계약
//!
//! 돌려주는 좌표는 **셀 좌상단 기준 상대 physical px** 이다. 호출부는 자기 셀의
//! 원점에 더하기만 하면 된다.
//!
//! `x` · `w` 를 담는 것은 점선 · 파선 ([#374](https://github.com/ensky0/tildaz/issues/374))
//! 때문이다. 그 전에는 폭이 언제나 셀 폭이라 `y` · `h` 만 냈지만, 점선은 셀 안을
//! 가로로 쪼개므로 여기서 폭을 정해야 한다. 대신 **셀 폭을 인자로 받는다** — wide
//! char 판정 (2배) 은 호출부가 이미 한 값을 그대로 넘긴다.
//!
//! 기준점은 **baseline = 셀 top + `ascent_px`** 다. 세 renderer 가 글리프를 그 식으로
//! 놓는다 (macOS `emitTextInstance` · Windows `emitClusterInstance` · Linux
//! `appendGlyph`). 같은 기준을 쓰므로 선과 글리프는 항상 일관되고, macOS 만 행 원점을
//! `top_pad_px` 만큼 올리는 기존 차이도 자동으로 따라간다 — 호출부가 글리프에 쓰는
//! 것과 같은 셀 top 을 넘기기만 하면 된다.
//!
//! ## 그리는 순서 — 글리프 **아래**
//!
//! 이 사각형들은 글리프보다 **먼저** 그려야 한다 (Linux `layer.cell_bg`,
//! macOS · Windows 는 bg pass). ghostty 와 같은 선택이고 이유도 같다 —
//! *"We draw underlines first so that they layer underneath text. This improves
//! readability when a colored underline is used which intersects parts of the
//! text (descenders)."* `underline_color` (SGR 58) 로 밑줄이 글자와 다른 색일 때
//! 차이가 실제로 보인다. 글리프 위에 그리면 `g` `y` `p` 의 꼬리가 선에 잘린다.

const std = @import("std");
const ghostty = @import("ghostty-vt");
const ui_metrics = @import("../ui_metrics.zig");

/// 점선 · 파선의 **base 셀 하나**당 조각 수 상한 (#374). 실제 개수는
/// [`pieceCount`] 가 정한다. wide char 는 base 셀의 배치를 `span` 번 되풀이하므로
/// 셀 전체로는 `× span` (지금은 최대 2) 까지 나온다 — `14 × 2` 에 윗줄 · 취소선을
/// 더해도 [`MAX_RECTS`] 안이다.
///
/// **상한을 `span` 으로 나누지 않는다.** 나누면 wide 만 조각이 줄어 "wide 는 narrow
/// 의 정확히 2 배" 가 깨진다 — 이 파일이 한 번 겪은 버그가 그 형태였다 (아래
/// `dotted` 분기 주석).
pub const MAX_UNDERLINE_PIECES = 14;

/// 한 셀이 만들 수 있는 최대 사각형 수.
///
/// **물결 밑줄이 상한을 정한다** — 픽셀 열마다 coverage 사각형을 내므로
/// `셀 폭 × (두께에 걸치는 행 수)` 만큼 나온다. [`box_drawing.MAX_RECTS`](../box_drawing.zig)
/// 가 호·대각선 AA 때문에 384 를 쓰는 것과 같은 이유이고 값도 맞춘다 — 큰 폰트의
/// wide char (셀 폭 74px × 5행) 까지 담긴다.
pub const MAX_RECTS = 384;

/// 선 하나. 좌표는 셀 좌상단 기준 상대 physical px (위 「좌표 계약」).
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    /// 두께 (physical px).
    h: f32,
    color: ghostty.color.RGB,
    /// 0~1 anti-alias coverage — [`box_drawing.Rect.cov`](../box_drawing.zig) 와
    /// 같은 의미다. 직선 · 이중 · 점선 · 파선은 픽셀 격자에 맞아떨어져 언제나 1
    /// (crisp) 이고, **물결만** 곡선이라 가장자리 픽셀이 1 미만이 된다.
    ///
    /// 호출부는 box drawing 과 똑같이 처리한다 — `ui_metrics.blendOverRgb` 로 셀
    /// 배경과 미리 합성해 **알파 1.0 solid** 로 그린다 (#353: 합성은 공통 모듈이
    /// 한 번만). `cov == 1` 이면 합성 결과가 `color` 그대로라 기존 선은 픽셀이
    /// 바뀌지 않는다.
    cov: f32 = 1,
};

/// 이 셀에 그릴 선이 있는가. 호출부가 셀을 빠르게 거르는 용도이고,
/// [`rects`] 가 0 을 돌려주는 조건과 **정확히 같다**.
///
/// `invisible` (SGR 8) 이 여기 들어 있는 것은 의도다 — 선까지 전부 숨기는 것이
/// 이 저장소의 정책이라 (아래 [`rects`] 주석) 그 판단을 호출부 세 곳에 흩어 두지
/// 않는다.
pub fn hasDecoration(style: ghostty.Style) bool {
    if (style.flags.invisible) return false;
    return style.flags.underline != .none or
        style.flags.strikethrough or
        style.flags.overline;
}

/// 셀 하나가 그릴 선 사각형들을 `out` 에 채우고 개수를 돌려준다.
///
/// `fg` 는 호출부가 [`cell_color.resolveFg`](cell_color.zig) 로 구한 값이다 —
/// selection / inverse 교환이 이미 반영돼 있다. 밑줄은 SGR 58 로 색이 명시돼
/// 있으면 그 색을, 없으면 `fg` 를 쓴다 (ghostty `underlineColor(palette) orelse fg`
/// 와 같다). 취소선과 윗줄은 `underline_color` 를 보지 않고 항상 `fg` 다.
///
/// `ascent_px` · `cell_h` 는 physical px 다.
///
/// ## `invisible` (SGR 8) — 선까지 전부 숨긴다
///
/// xterm · ghostty 와 같은 선택이다 (2026-08-03 사용자 확정). ghostty 주석이 이
/// 갈래를 짚는다 — *"NOTE: This behavior matches xterm. Some other terminal
/// emulators, e.g. Alacritty, still render text decorations and only make the text
/// itself invisible."* 비밀번호 입력처럼 "아무것도 안 보임" 이 SGR 8 의 의도에 가깝다.
///
/// ## 밑줄 스타일 5 종을 모두 그린다
///
/// `single` · `double` (#365) 에 이어 `dotted` (`4:4`) · `dashed` (`4:5`) ·
/// `curly` (`4:3`) 를 [#374](https://github.com/ensky0/tildaz/issues/374) 로
/// 구현했다. ghostty 파서가 `4:6` 이상의 **미정의** 숫자를 `single` 로 떨어뜨리므로
/// 이 모듈에 도달하는 값은 언제나 이 5 종 중 하나다.
pub fn rects(
    style: ghostty.Style,
    fg: ghostty.color.RGB,
    palette: *const ghostty.color.Palette,
    ascent_px: f32,
    cell_w: f32,
    cell_h: f32,
    /// 이 셀이 차지하는 격자 칸 수 — wide char (한글 · CJK) 는 2, 그 외 1.
    /// 물결 밑줄이 파장을 narrow 셀 기준으로 유지하는 데만 쓴다 (wide 는 산 2 개).
    /// 호출부가 이미 `raw.wide` 로 알고 있는 값이다.
    span: usize,
    out: *[MAX_RECTS]Rect,
) usize {
    if (!hasDecoration(style)) return 0;

    const t = ui_metrics.cellLineThicknessPx(ascent_px);
    var n: usize = 0;

    // 위에서 아래 순서 — 윗줄, 취소선, 밑줄.

    if (style.flags.overline) {
        // ghostty 의 `overline_position = 0` 과 같다 — 셀 최상단.
        out[n] = .{ .x = 0, .w = cell_w, .y = clampY(0, t, cell_h), .h = t, .color = fg };
        n += 1;
    }

    if (style.flags.strikethrough) {
        // 상수는 선의 **중심** 위치다 (정석이 `x_height / 2` 이므로) — 사각형
        // 좌표로 바꾸려면 두께의 절반만큼 올려야 한다.
        const center = ascent_px - ascent_px * ui_metrics.STRIKETHROUGH_CENTER_RATIO;
        out[n] = .{ .x = 0, .w = cell_w, .y = clampY(@round(center - t / 2), t, cell_h), .h = t, .color = fg };
        n += 1;
    }

    if (style.flags.underline != .none) {
        const color = style.underlineColor(palette) orelse fg;
        const gap = @round(ascent_px * ui_metrics.UNDERLINE_GAP_RATIO);
        const y = clampY(@round(ascent_px + gap), t, cell_h);

        switch (style.flags.underline) {
            .none => unreachable, // 위 조건이 이미 걸렀다.

            .double => {
                // ghostty 의 "negative underline" — 단일 밑줄 자리를 **비우고** 위아래로
                // 두께만큼 놓는다. 전체가 3×t 를 차지하므로 아래 선이 셀 밖으로 나가지
                // 않도록 기준선 자체를 먼저 당긴다 (ghostty `special.zig` 와 같은 방식).
                const base = @min(ascent_px + gap, cell_h - 2 * t);
                out[n] = .{ .x = 0, .w = cell_w, .y = clampY(@round(base - t), t, cell_h), .h = t, .color = color };
                n += 1;
                out[n] = .{ .x = 0, .w = cell_w, .y = clampY(@round(base + t), t, cell_h), .h = t, .color = color };
                n += 1;
            },

            // #374 — 점선 · 파선은 **같은 경로**다. 셀을 `count` 조각으로 나누고 각
            // 조각의 앞 절반을 칠한다 (칠한 폭 = 빈 폭). 둘의 차이는 조각 크기뿐이다 —
            // 점선은 `2 × 두께` (정사각형 dot), 파선은 **셀 폭** (셀당 1 조각).
            //
            // 셀 경계 위상을 따로 맞출 필요가 없다: 셀 폭이 모두 같으므로 셀마다 같은
            // 리듬이 되어 이웃 셀과 자연히 이어진다.
            //
            // **간격(pitch)을 정수로 고정한다.** 이전에는 조각 경계를 각각
            // `@round(slot × i)` 로 구했는데, `slot = 셀폭 / 조각수` 가 정수가 아니면
            // 조각마다 1px 씩 흔들렸다 (2026-08-03 Windows 실기에서 발견, macOS 실측으로
            // 확인). 셀 폭에 따라 폭 또는 간격 한쪽으로 나타났다.
            //
            // | 폰트 · 셀 | slot | 증상 |
            // |---|---|---|
            // | Cascadia 15pt (`cell_w 9`, `t 1`) | 1.8 | 폭 `1,1,2,1` — 두 조각이 인접해 붙음 |
            // | Menlo 15pt @2x (`cell_w 19`, `t 2`) | 3.8 | 간격 `2,2,1,2` |
            // | Lucida Console 15pt (`cell_w 10`) | 2.0 | 균일 (정수라서) |
            //
            // 정수 pitch 로 놓으면 폭과 간격이 **둘 다** 균일해진다. 대가는 셀 끝에 남는
            // 여백만큼 **셀 경계의 간격이 달라지는** 것인데, 조각 하나 폭보다 작은
            // 잔여이므로 리듬이 깨져 보이지 않는다.
            //
            // **wide char 는 base 셀의 배치를 `span` 번 되풀이한다.** 셀 전체를 한 번에
            // 나누지 않는 이유가 있다 — 그렇게 하면 아래 「셀 끝에 닿는 조각 버림」이
            // `span` 을 모르는 채 셀당 한 번만 일어나서, 홀수 폭에서 narrow 는 5 중 1
            // (20%) 을, wide 는 10 중 1 (10%) 을 버려 **밀도가 갈렸다** (2026-08-03
            // Linux GL 실기: DejaVu Sans Mono 15pt `cell_w 9` 에서 narrow 4 / wide 9,
            // 기대 8 — [#365](https://github.com/ensky0/tildaz/issues/365)). 되풀이하면
            // wide 가 narrow 의 리듬을 글자 그대로 반복하므로 개수도 정확히 2 배고
            // 한글 구간과 ASCII 구간이 같아 보인다. 물결이 `cycles = span` 으로 산을
            // span 개 넣는 것과 같은 원리다.
            .dotted, .dashed => {
                // 점선은 두께 기준으로 촘촘하게, 파선은 **셀 하나에 조각 하나**다.
                // `4 × 두께` 로 뒀더니 15pt 셀(19px)에 2 개가 들어가 글자 한 칸에
                // "칠·빔·칠·빔" 이 반복돼 너무 촘촘했다 (2026-08-03 실기, 사용자 지적).
                const sp = @max(1, span);
                const base_w = cell_w / @as(f32, @floatFromInt(sp));
                const slot_px = if (style.flags.underline == .dotted) 2 * t else base_w;
                const per = pieceCount(base_w, slot_px);
                // 정수 pitch — 최소 2 라야 칠한 칸과 빈 칸이 각각 1px 이상 남는다.
                const pitch = @max(2, @round(base_w / @as(f32, @floatFromInt(per))));
                const piece_w = @max(1, @round(pitch / 2));
                const before = n;
                for (0..sp) |k| {
                    const ox = base_w * @as(f32, @floatFromInt(k));
                    for (0..per) |i| {
                        const x0 = ox + pitch * @as(f32, @floatFromInt(i));
                        // 조각이 base 셀을 넘거나 **base 셀 끝에 딱 닿으면** 버린다.
                        //
                        // 넘는 것을 잘라 넣으면 폭이 다시 불균일해지고, 끝에 딱 닿게 두면
                        // 다음 base 셀의 첫 조각과 **맞붙어** 원래 증상이 되돌아온다
                        // (Cascadia 15pt 는 `cell_w 9` · `pitch 2` 라 다섯째 조각이
                        // `[8,9)` 로 정확히 닿는다). 버리면 그 자리 간격만 조각 하나
                        // 폭만큼 넓어지고, 되풀이라 wide 의 모든 base 셀이 똑같이 버린다.
                        if (x0 + piece_w >= ox + base_w) break;
                        if (n >= MAX_RECTS) break;
                        out[n] = .{ .x = x0, .w = piece_w, .y = y, .h = t, .color = color };
                        n += 1;
                    }
                }
                // 셀이 조각 하나도 못 담는 극단 (아주 작은 폰트) 에서는 최소 하나를
                // 보장한다 — 밑줄이 통째로 사라지지 않게.
                if (n == before) {
                    out[n] = .{ .x = 0, .w = @max(1, @min(piece_w, cell_w)), .y = y, .h = t, .color = color };
                    n += 1;
                }
            },

            // #374 — 물결. 셀 하나에 **산 하나** (x=0 바닥 → 중앙 꼭대기 → x=셀폭
            // 바닥) 를 넣는다. 이웃 셀이 같은 모양이라 셀 경계가 골이 되어 물결로
            // 이어진다 — 점선 · 파선과 같은 원리라 절대 x 좌표가 필요 없다.
            // wide char 는 셀 폭이 2배라 산을 2 개 넣어 파장을 narrow 와 맞춘다.
            //
            // **픽셀 열마다 coverage 사각형을 낸다** — [`box_drawing`](../box_drawing.zig)
            // 이 호 · 대각선에 쓰는 방식 그대로다. 처음에는 굵은 계단 7 조각으로
            // 근사했는데, 15pt 에서 반올림 후 실질 진폭이 3px 까지 줄어 거의 직선처럼
            // 뭉개졌다 (2026-08-03 실기 비교 — ghostty · kitty · Alacritty 는 매끈한
            // 사인파). 세로 AA 를 넣으면서 진폭도 ghostty 와 같은 `파장 / π` 로 올린다.
            //
            // `shade` 셰이더 채널을 쓰지 않는 이유는 그대로다 — 그쪽은 `discard` 이진
            // 마스크라 **AA 가 아예 안 되고**, 셰이더 네 곳 (Metal · HLSL · Linux CPU ·
            // Linux GL) 에 정점 구조와 varying 까지 손대야 한다.
            .curly => {
                const cycles: f32 = @floatFromInt(@max(1, span));
                const wave_len = cell_w / cycles;
                // ghostty 는 `파장 / π` (≈0.32×파장) 를 쓰지만 실기에서 나란히 보니
                // 우리가 가장 출렁였다 — 물결 밴드가 TildaZ 8px · Alacritty 7px ·
                // kitty 6px 였다 (2026-08-03, Menlo 15pt @2x). 밑줄은 정보 전달이지
                // 장식이 아니라서 Alacritty 쪽으로 낮춘다 (사용자 선택).
                const amp = wave_len * ui_metrics.CURLY_AMPLITUDE_RATIO;
                // 파형 전체 (진폭 + 두께) 가 셀 안에 들어오도록 기준선을 당긴다.
                // `mid` 는 **선의 중심**이 지나는 가장 높은 y (산꼭대기) 다.
                const mid = @min(ascent_px + gap + t / 2, cell_h - amp - t / 2);
                var px: f32 = 0;
                while (px < cell_w and n + 3 <= MAX_RECTS) : (px += 1) {
                    // 열 중앙에서 곡선의 중심 y. 파장마다 위상이 되풀이된다.
                    //
                    // **raised cosine 이어야 한다.** `sin(π·phase)` 를 쓰면 양 끝
                    // (셀 경계) 에서 기울기가 최대라 골이 뾰족한 `V` 가 되고, 산만
                    // 도드라져 `∩∩∩` 으로 보인다 (2026-08-03 실기에서 사용자 지적).
                    // `(1 − cos(2π·phase)) / 2` 는 phase 0 · 0.5 · 1 **세 곳 모두
                    // 접선이 수평**이라 이웃 셀과 만나는 지점이 둥근 골이 되어 `∿∿∿`
                    // 이 된다. ghostty 가 베지어 제어점을 시작·끝점과 같은 y 에 둬서
                    // (`curveTo(center*r, bottom, …)`) 얻는 모양과 같다.
                    //
                    // **셀 경계가 산, 중앙이 골이다** (`rise` 를 그대로 더한다).
                    // 반대로 두면 (경계가 골, 중앙이 산) 물결이 밑줄 자리에서
                    // *올라가며* 시작해 불안정해 보인다 — Alacritty 처럼 baseline 에
                    // 가까운 높이에서 시작해 중앙으로 처지는 쪽이 글자와의 거리가
                    // 일정하게 느껴진다 (2026-08-03 실기 비교, 사용자 지적).
                    const phase = @mod(px + 0.5, wave_len) / wave_len;
                    const rise = (1 - @cos(2 * std.math.pi * phase)) / 2;
                    const cy = mid + amp * rise;
                    const y_top = cy - t / 2;
                    const y_bot = cy + t / 2;

                    // 한 열은 **최대 3 조각**이다 — 위 가장자리(부분) · 가운데(완전)
                    // · 아래 가장자리(부분). 완전히 덮인 행을 하나로 합치지 않고
                    // 행마다 내면 두꺼운 선에서 조각이 몇 배로 늘어난다.
                    const top_row = @floor(y_top);
                    const bot_row = @floor(y_bot);
                    if (top_row == bot_row) {
                        emitCov(out, &n, px, top_row, 1, y_bot - y_top, cell_h, color);
                    } else {
                        emitCov(out, &n, px, top_row, 1, top_row + 1 - y_top, cell_h, color);
                        const solid_h = bot_row - (top_row + 1);
                        if (solid_h > 0) {
                            emitCov(out, &n, px, top_row + 1, solid_h, 1, cell_h, color);
                        }
                        emitCov(out, &n, px, bot_row, 1, y_bot - bot_row, cell_h, color);
                    }
                }
            },

            .single => {
                out[n] = .{ .x = 0, .w = cell_w, .y = y, .h = t, .color = color };
                n += 1;
            },
        }
    }

    return n;
}

/// 물결의 조각 하나. 셀 밖으로 나가거나 coverage 가 무시할 만큼 작으면 버린다.
/// [`box_drawing`](../box_drawing.zig) 의 AA 헬퍼가 `cov <= 0.02` 를 버리는 것과
/// 같은 기준이다.
fn emitCov(
    out: *[MAX_RECTS]Rect,
    n: *usize,
    x: f32,
    y: f32,
    h: f32,
    cov: f32,
    cell_h: f32,
    color: ghostty.color.RGB,
) void {
    if (n.* >= MAX_RECTS) return;
    if (cov <= 0.02 or h <= 0) return;
    if (y < 0 or y + h > cell_h) return;
    out[n.*] = .{ .x = x, .y = y, .w = 1, .h = h, .color = color, .cov = @min(1, cov) };
    n.* += 1;
}

/// **base 셀 하나**의 점선 · 파선 조각 수. base 셀을 이 수만큼 등분해 각 구간의 앞
/// 절반을 칠한다.
///
/// wide char 를 여기서 곱하지 않는다 — 호출부가 이 배치를 `span` 번 **되풀이**해서
/// 2 배를 만든다. 세는 단계에서 곱하면 셀 전체를 다시 나누게 되고, 그때 셀 경계
/// 버림이 span 을 모르는 채 한 번만 일어나 밀도가 깨졌다 (아래 `dotted` 분기 주석).
fn pieceCount(base_w: f32, slot: f32) usize {
    const raw = @round(base_w / slot);
    // 상한을 먼저 f32 에서 걸어 `@intFromFloat` 에 범위 밖 값이 들어가지 않게 한다.
    const capped = @min(raw, @as(f32, @floatFromInt(MAX_UNDERLINE_PIECES)));
    const per: usize = if (!(capped >= 1)) 1 else @intFromFloat(capped);
    return @max(1, per);
}

/// 선이 셀 밖으로 나가지 않게 가둔다. 아래로 넘치면 셀 바닥에 붙이고, 셀이 두께보다
/// 얇은 극단(작은 폰트 + 큰 두께)에서는 0 으로 떨어뜨려 음수 좌표를 만들지 않는다.
fn clampY(y: f32, h: f32, cell_h: f32) f32 {
    return @max(0, @min(y, cell_h - h));
}

// --- tests (순수 로직 — 세 platform 이 같은 값을 쓴다) ---

const test_palette = ghostty.color.default;
const test_fg = ghostty.color.RGB{ .r = 200, .g = 210, .b = 220 };

/// 실측 기준값 — Menlo 14pt @1.0x (`ascent_px` 13, `cell_w` 8, `cell_h` 17).
/// 이 값에서 두께 `t` 는 `max(1, round(13 × 0.06)) = 1` 이다.
const A: f32 = 13.0;
const W: f32 = 8.0;
const H: f32 = 17.0;

fn collect(style: ghostty.Style) struct { n: usize, r: [MAX_RECTS]Rect } {
    var out: [MAX_RECTS]Rect = undefined;
    const n = rects(style, test_fg, &test_palette, A, W, H, 1, &out);
    return .{ .n = n, .r = out };
}

test "선이 없는 셀은 사각형을 만들지 않는다" {
    try std.testing.expectEqual(@as(usize, 0), collect(.{}).n);
    try std.testing.expect(!hasDecoration(.{}));
    // inverse / bold 처럼 선과 무관한 flag 는 사각형을 만들지 않는다.
    try std.testing.expectEqual(@as(usize, 0), collect(.{ .flags = .{ .inverse = true, .bold = true } }).n);
}

test "single 밑줄 — baseline 아래 gap 만큼, 두께는 정수 1px 이상" {
    const got = collect(.{ .flags = .{ .underline = .single } });
    try std.testing.expectEqual(@as(usize, 1), got.n);
    // t = max(1, round(13 × 0.06)) = max(1, round(0.78)) = 1
    try std.testing.expectEqual(@as(f32, 1), got.r[0].h);
    // gap = round(13 × 0.07) = round(0.91) = 1 → y = 13 + 1 = 14
    try std.testing.expectEqual(@as(f32, 14), got.r[0].y);
    // 색이 명시되지 않았으면 fg.
    try std.testing.expectEqual(test_fg, got.r[0].color);
}

test "double 밑줄 — 단일 자리를 비우고 위아래로 두께만큼 (ghostty negative underline)" {
    const got = collect(.{ .flags = .{ .underline = .double } });
    try std.testing.expectEqual(@as(usize, 2), got.n);
    // single_y = 14, t = 1 → 위 선 13, 아래 선 15. 가운데 14 가 비어 "이중" 으로 보인다.
    try std.testing.expectEqual(@as(f32, 13), got.r[0].y);
    try std.testing.expectEqual(@as(f32, 15), got.r[1].y);
    try std.testing.expectEqual(got.r[0].y + 2 * got.r[0].h, got.r[1].y);
}

/// 물결의 각 픽셀 열에서 coverage 무게중심 y 를 구한다 — 계단이 아니라 **연속
/// 곡선**인지 검사하는 데 쓴다.
fn waveCenters(r: []const Rect, cell_w: f32) [64]f32 {
    var sum: [64]f32 = @splat(0);
    var wsum: [64]f32 = @splat(0);
    for (r) |d| {
        const col: usize = @intFromFloat(d.x);
        if (col >= 64 or d.x >= cell_w) continue;
        // 면적 = 높이 × coverage. 가운데 solid 조각은 높이가 1 보다 클 수 있다.
        const weight = d.cov * d.h;
        sum[col] += (d.y + d.h / 2) * weight;
        wsum[col] += weight;
    }
    var out: [64]f32 = @splat(0);
    for (0..64) |i| out[i] = if (wsum[i] > 0) sum[i] / wsum[i] else 0;
    return out;
}

test "#374 curly — 픽셀 열마다 coverage 로 AA 하고 셀 전체를 덮는다" {
    const got = collect(.{ .flags = .{ .underline = .curly } });
    try std.testing.expect(got.n > 0);

    // 모든 열이 빠짐없이 채워진다 — 한 열이라도 비면 물결이 끊겨 보인다.
    var seen: [64]bool = @splat(false);
    for (got.r[0..got.n]) |d| {
        try std.testing.expect(d.cov > 0 and d.cov <= 1);
        try std.testing.expectEqual(@as(f32, 1), d.w);
        try std.testing.expect(d.h >= 1);
        try std.testing.expect(d.x >= 0 and d.x < W);
        seen[@intFromFloat(d.x)] = true;
    }
    for (0..@as(usize, @intFromFloat(W))) |i| try std.testing.expect(seen[i]);

    // **AA 가 실제로 걸린다** — 곡선이라 부분 coverage 픽셀이 반드시 생긴다.
    var has_partial = false;
    for (got.r[0..got.n]) |d| {
        if (d.cov < 0.98) has_partial = true;
    }
    try std.testing.expect(has_partial);
}

test "#374 curly — 셀 경계가 산 · 중앙이 골이고 좌우 대칭이라 이웃 셀과 이어진다" {
    const got = collect(.{ .flags = .{ .underline = .curly } });
    const c = waveCenters(got.r[0..got.n], W);
    const last: usize = @as(usize, @intFromFloat(W)) - 1;
    const mid = last / 2;

    // 가운데가 가장 **낮다** (y 는 아래로 증가) — 경계에서 시작해 중앙으로 처진다.
    // 반대로 두면 밑줄 자리에서 올라가며 시작해 불안정해 보인다 (사용자 지적).
    try std.testing.expect(c[mid] > c[0]);
    try std.testing.expect(c[mid] > c[last]);
    // 좌우 대칭 — 셀 경계 양쪽이 같은 높이라야 이웃과 매끄럽게 만난다.
    try std.testing.expectApproxEqAbs(c[0], c[last], 0.35);

    // **진폭이 살아 있다** — 계단 근사 때 15pt 에서 3px 까지 줄어 직선처럼 보였다.
    // 열 **중앙**에서 재므로 끝 열의 위상이 0 이 아니라 `0.5 / 셀폭` 이고 그만큼
    // 관측값이 작게 나온다. 그 손실을 감안한 하한이다.
    try std.testing.expect(c[mid] - c[0] > W * ui_metrics.CURLY_AMPLITUDE_RATIO * 0.7);

    // 연속 곡선이다 — 이웃 열의 중심 차이가 1px 을 크게 넘지 않는다.
    for (0..last) |i| try std.testing.expect(@abs(c[i + 1] - c[i]) <= 1.5);
}

test "#374 curly — wide char 는 산 2 개로 파장을 narrow 와 맞춘다" {
    var narrow: [MAX_RECTS]Rect = undefined;
    var wide: [MAX_RECTS]Rect = undefined;
    const style = ghostty.Style{ .flags = .{ .underline = .curly } };
    const n_narrow = rects(style, test_fg, &test_palette, A, W, H, 1, &narrow);
    const n_wide = rects(style, test_fg, &test_palette, A, 2 * W, H, 2, &wide);

    const cn = waveCenters(narrow[0..n_narrow], W);
    const cw = waveCenters(wide[0..n_wide], 2 * W);
    const wi: usize = @intFromFloat(W);
    // wide 의 앞 절반과 뒤 절반이 narrow 와 같은 파형 = 파장이 같다.
    for (0..wi) |i| {
        try std.testing.expectApproxEqAbs(cn[i], cw[i], 0.01);
        try std.testing.expectApproxEqAbs(cn[i], cw[i + wi], 0.01);
    }
}

test "#374 curly — 파형 전체가 셀 안에 들어간다 (진폭 + 두께)" {
    var out: [MAX_RECTS]Rect = undefined;
    // descent 가 거의 없어 baseline 이 셀 바닥에 붙은 극단.
    inline for (.{ .{ A, H }, .{ 20.0, 20.0 }, .{ 56.0, 77.0 } }) |c| {
        const n = rects(.{ .flags = .{ .underline = .curly } }, test_fg, &test_palette, c[0], W, c[1], 1, &out);
        for (out[0..n]) |r| {
            try std.testing.expect(r.y >= 0);
            try std.testing.expect(r.y + r.h <= c[1]);
        }
    }
}

test "#374 dotted · dashed — 칠한 폭과 빈 폭이 같고 간격이 균일하다" {
    // W=8, t=1. 점선 slot=2 → 4 조각 [0,1) [2,3) [4,5) [6,7).
    //          파선 slot=셀폭 → 1 조각 [0,4), 나머지 [4,8) 은 빈칸.
    const cases = [_]struct { kind: @TypeOf(@as(ghostty.Style, undefined).flags.underline), n: usize, w: f32, pitch: f32 }{
        .{ .kind = .dotted, .n = 4, .w = 1, .pitch = 2 },
        .{ .kind = .dashed, .n = 1, .w = 4, .pitch = 8 },
    };
    for (cases) |c| {
        const got = collect(.{ .flags = .{ .underline = c.kind } });
        try std.testing.expectEqual(c.n, got.n);
        const single_y = collect(.{ .flags = .{ .underline = .single } }).r[0].y;
        for (got.r[0..got.n], 0..) |d, i| {
            try std.testing.expectEqual(single_y, d.y); // 직선 밑줄과 같은 높이
            // **모든 조각의 길이가 같다** — 이게 얼룩덜룩함의 원인이었다.
            try std.testing.expectEqual(c.w, d.w);
            // **등간격** — 구간 경계를 반올림해 이어 붙이므로 pitch 가 일정하다.
            try std.testing.expectEqual(c.pitch * @as(f32, @floatFromInt(i)), d.x);
            try std.testing.expect(d.x >= 0 and d.x + d.w <= W);
        }
        // 칠한 폭 == 빈 폭.
        try std.testing.expectEqual(c.w, c.pitch - c.w);
        // 셀 경계에서도 리듬이 이어진다 — 마지막 조각 끝에서 셀 끝까지 남은 빈 폭이
        // 조각 폭과 같아야, 다음 셀 첫 조각과의 간격이 셀 안 간격과 같아진다.
        const last = got.r[got.n - 1];
        try std.testing.expectEqual(c.w, W - (last.x + last.w));
    }
}

/// 점선 조각의 폭 목록과 간격 목록. 균일성 검사 전용.
fn dotShape(ascent: f32, cell_w: f32, span: usize) struct { w: [16]f32, gap: [16]f32, n: usize } {
    var out: [MAX_RECTS]Rect = undefined;
    const n = rects(.{ .flags = .{ .underline = .dotted } }, test_fg, &test_palette, ascent, cell_w, cell_w * 2, span, &out);
    var w: [16]f32 = @splat(0);
    var gap: [16]f32 = @splat(0);
    for (out[0..@min(n, 16)], 0..) |d, i| {
        w[i] = d.w;
        if (i > 0) gap[i - 1] = d.x - (out[i - 1].x + out[i - 1].w);
    }
    return .{ .w = w, .gap = gap, .n = n };
}

test "#374 dotted — **비정수 slot** 에서도 폭과 간격이 균일하다" {
    // 2026-08-03 Windows 실기에서 발견한 회귀를 고정한다. 조각 경계를 각각
    // `@round(slot × i)` 로 구하던 때는 `slot = 셀폭 / 조각수` 가 정수가 아니면
    // 조각마다 1px 씩 흔들렸다. 아래 세 조합이 그 증거이고, 앞선 테스트는 `slot`
    // 이 정수인 경우 (`W=8` → 2.0) 만 검증해서 놓쳤다.
    const cases = [_]struct { name: []const u8, ascent: f32, cell_w: f32 }{
        // Cascadia Code 15pt (Windows): cell_w 9, t 1 → slot 1.8. 폭이 `1,1,2,1` 로 갈렸다.
        .{ .name = "Cascadia 15pt", .ascent = 13.92, .cell_w = 9 },
        // Menlo 15pt @2x (macOS): cell_w 19, t 2 → slot 3.8. 간격이 `2,2,1,2` 로 갈렸다.
        .{ .name = "Menlo 15pt@2x", .ascent = 28, .cell_w = 19 },
        // Cascadia Code 30pt: cell_w 18, t 2 → slot 3.6. 폭이 `2,1,2,2,2` 로 갈렸다.
        .{ .name = "Cascadia 30pt", .ascent = 27.83, .cell_w = 18 },
        // Lucida Console 15pt: cell_w 10 → slot 2.0 (정수). 원래도 균일했다.
        .{ .name = "Lucida 15pt", .ascent = 13.92, .cell_w = 10 },
    };
    for (cases) |c| {
        const shape = dotShape(c.ascent, c.cell_w, 1);
        try std.testing.expect(shape.n >= 1);
        // 모든 조각의 폭이 같다.
        for (shape.w[0..shape.n]) |w| {
            std.testing.expectEqual(shape.w[0], w) catch |err| {
                std.debug.print("{s}: 폭이 갈렸다 {any}\n", .{ c.name, shape.w[0..shape.n] });
                return err;
            };
        }
        // 셀 **안**의 간격이 모두 같다 (셀 경계 간격은 잔여 여백만큼 좁을 수 있다).
        if (shape.n >= 3) {
            for (shape.gap[0 .. shape.n - 1]) |g| {
                std.testing.expectEqual(shape.gap[0], g) catch |err| {
                    std.debug.print("{s}: 간격이 갈렸다 {any}\n", .{ c.name, shape.gap[0 .. shape.n - 1] });
                    return err;
                };
            }
        }
        // 셀을 넘지 않고, **셀 끝에 딱 닿지도 않는다** — 닿으면 다음 셀의 첫 조각과
        // 맞붙어 원래 증상이 되돌아온다.
        var out: [MAX_RECTS]Rect = undefined;
        const n = rects(.{ .flags = .{ .underline = .dotted } }, test_fg, &test_palette, c.ascent, c.cell_w, c.cell_w * 2, 1, &out);
        for (out[0..n]) |d| try std.testing.expect(d.x + d.w <= c.cell_w);
        if (n >= 2) {
            const last = out[n - 1];
            std.testing.expect(last.x + last.w < c.cell_w) catch |err| {
                std.debug.print("{s}: 마지막 조각이 셀 끝에 닿는다 x={d} w={d} cell_w={d}\n", .{ c.name, last.x, last.w, c.cell_w });
                return err;
            };
        }
    }
}

test "#374 dotted · dashed — wide char 는 base 셀 배치를 되풀이한다 (같은 밀도 · 같은 리듬)" {
    // **홀수 셀 폭이 핵심 케이스다.** 셀 전체를 한 번에 나누던 때는 셀 경계 버림이
    // span 을 모르는 채 셀당 한 번만 일어나서, 홀수 폭에서 narrow 4 / wide 9 (기대 8)
    // 로 밀도가 갈렸다 (2026-08-03 Linux GL 실기, #365). 짝수 폭 (`W = 8`) 만 검증하던
    // 앞 버전이 그래서 놓쳤다.
    const cases = [_]struct { name: []const u8, ascent: f32, base_w: f32 }{
        .{ .name = "Menlo 14pt (짝수 8)", .ascent = A, .base_w = W },
        // DejaVu Sans Mono 15pt (Linux) · Cascadia Code 15pt (Windows): t 1, 다섯째
        // 조각이 `[8,9)` 로 base 셀 끝에 닿아 버려진다 → base 셀당 4.
        .{ .name = "DejaVu/Cascadia 15pt (홀수 9)", .ascent = 14, .base_w = 9 },
        // Menlo 15pt @2x (macOS): t 2, 마지막 조각이 `[16,18)` 로 살아남아 base 셀당 5.
        .{ .name = "Menlo 15pt@2x (홀수 19)", .ascent = 28, .base_w = 19 },
    };
    var narrow: [MAX_RECTS]Rect = undefined;
    var wide: [MAX_RECTS]Rect = undefined;
    for (cases) |c| {
        inline for (.{ .dotted, .dashed }) |kind| {
            const style = ghostty.Style{ .flags = .{ .underline = kind } };
            const n_narrow = rects(style, test_fg, &test_palette, c.ascent, c.base_w, c.base_w * 2, 1, &narrow);
            const n_wide = rects(style, test_fg, &test_palette, c.ascent, 2 * c.base_w, c.base_w * 2, 2, &wide);
            // 개수가 정확히 2 배다 — 밀도가 유지된다.
            std.testing.expectEqual(n_narrow * 2, n_wide) catch |err| {
                std.debug.print("{s} {s}: narrow {d} / wide {d}\n", .{ c.name, @tagName(kind), n_narrow, n_wide });
                return err;
            };
            // **리듬까지 같다** — wide 의 둘째 타일이 첫 타일을 `base_w` 만큼 옮긴 것과
            // 같다. 개수만 맞고 조각이 다르게 놓이는 경우 (셀 끝에 큰 구멍) 를 막는다.
            for (0..n_narrow) |i| {
                try std.testing.expectEqual(narrow[i].x, wide[i].x);
                try std.testing.expectEqual(narrow[i].w, wide[i].w);
                try std.testing.expectEqual(narrow[i].x + c.base_w, wide[n_narrow + i].x);
                try std.testing.expectEqual(narrow[i].w, wide[n_narrow + i].w);
            }
        }
    }
}

test "#374 점선·파선도 underline_color 를 따르고 취소선·윗줄과 공존한다" {
    const ul = ghostty.color.RGB{ .r = 255, .g = 0, .b = 0 };
    inline for (.{ .dotted, .dashed }) |kind| {
        const got = collect(.{
            .underline_color = .{ .rgb = ul },
            .flags = .{ .underline = kind, .strikethrough = true, .overline = true },
        });
        // 윗줄 + 취소선은 fg, 나머지 밑줄 조각은 전부 underline_color.
        try std.testing.expectEqual(test_fg, got.r[0].color);
        try std.testing.expectEqual(test_fg, got.r[1].color);
        try std.testing.expect(got.n > 2);
        for (got.r[2..got.n]) |d| try std.testing.expectEqual(ul, d.color);
        // 윗줄·취소선은 셀 전체 폭이다 (점선이 되지 않는다).
        try std.testing.expectEqual(W, got.r[0].w);
        try std.testing.expectEqual(W, got.r[1].w);
    }
}

test "underline_color (SGR 58) 는 밑줄에만 적용되고 취소선·윗줄은 fg 를 쓴다" {
    const ul = ghostty.color.RGB{ .r = 255, .g = 0, .b = 0 };
    const got = collect(.{
        .underline_color = .{ .rgb = ul },
        .flags = .{ .underline = .single, .strikethrough = true, .overline = true },
    });
    try std.testing.expectEqual(@as(usize, 3), got.n);
    // 순서는 위에서 아래 — 윗줄, 취소선, 밑줄.
    try std.testing.expectEqual(test_fg, got.r[0].color); // overline
    try std.testing.expectEqual(test_fg, got.r[1].color); // strikethrough
    try std.testing.expectEqual(ul, got.r[2].color); // underline
}

test "underline_color 가 palette 색이면 palette 에서 읽는다" {
    const got = collect(.{
        .underline_color = .{ .palette = 1 },
        .flags = .{ .underline = .single },
    });
    try std.testing.expectEqual(test_palette[1], got.r[0].color);
}

test "윗줄은 셀 최상단, 취소선은 baseline 위" {
    const got = collect(.{ .flags = .{ .strikethrough = true, .overline = true } });
    try std.testing.expectEqual(@as(usize, 2), got.n);
    try std.testing.expectEqual(@as(f32, 0), got.r[0].y); // overline = 셀 top
    // center = 13 − 13×0.30 = 9.1 → y = round(9.1 − 0.5) = round(8.6) = 9
    try std.testing.expectEqual(@as(f32, 9), got.r[1].y);
    // 취소선은 baseline(13) 보다 위에 있어야 한다 — 소문자 한가운데를 지나는 선.
    try std.testing.expect(got.r[1].y + got.r[1].h < A);
}

test "invisible (SGR 8) 은 선까지 전부 숨긴다 — xterm · ghostty 정책" {
    const style = ghostty.Style{ .flags = .{
        .invisible = true,
        .underline = .double,
        .strikethrough = true,
        .overline = true,
    } };
    try std.testing.expect(!hasDecoration(style));
    try std.testing.expectEqual(@as(usize, 0), collect(style).n);
}

test "선은 셀을 벗어나지 않는다 — 큰 폰트·얇은 셀 경계" {
    // descent 가 거의 없어 baseline 이 셀 바닥에 붙은 극단. double 의 아래 선이
    // 밖으로 나가려 하므로 기준선이 당겨진다.
    var out: [MAX_RECTS]Rect = undefined;
    inline for (.{ .double, .dotted, .dashed, .curly, .single }) |kind| {
        const n = rects(
            .{ .flags = .{ .underline = kind, .strikethrough = true, .overline = true } },
            test_fg,
            &test_palette,
            20.0, // ascent
            10.0, // cell_w
            20.0, // cell_h — baseline 이 곧 셀 바닥
            1,
            &out,
        );
        for (out[0..n]) |r| {
            try std.testing.expect(r.y >= 0);
            try std.testing.expect(r.y + r.h <= 20.0);
            try std.testing.expect(r.x >= 0);
            try std.testing.expect(r.x + r.w <= 10.0);
            try std.testing.expect(r.h >= 1 and r.w >= 1);
        }
    }
}

test "두께는 폰트가 커지면 함께 굵어지고 항상 정수다" {
    // 같은 폰트를 키우거나 배율을 올리면 ascent_px 가 커진다.
    const cases = [_]struct { ascent: f32, expect_t: f32 }{
        .{ .ascent = 8, .expect_t = 1 }, // round(0.48) = 0 → 최소 1
        .{ .ascent = 13, .expect_t = 1 }, // round(0.78) = 1
        .{ .ascent = 26, .expect_t = 2 }, // round(1.56) = 2  (Menlo 14pt @2x)
        .{ .ascent = 45, .expect_t = 3 }, // round(2.70) = 3
    };
    for (cases) |c| {
        var out: [MAX_RECTS]Rect = undefined;
        const n = rects(.{ .flags = .{ .underline = .single } }, test_fg, &test_palette, c.ascent, c.ascent * 0.6, c.ascent * 1.3, 1, &out);
        try std.testing.expectEqual(@as(usize, 1), n);
        try std.testing.expectEqual(c.expect_t, out[0].h);
        try std.testing.expectEqual(out[0].h, @round(out[0].h));
    }
}

test "MAX_RECTS — 가장 큰 조합에서도 넘치지 않는다" {
    var out: [MAX_RECTS]Rect = undefined;
    // 가장 많이 나오는 조합 = wide 물결 + 취소선 + 윗줄. 열마다 최대 3 조각이다.
    // 28pt @2x 의 wide 셀 (74 × 77, ascent 56) — 실사용 중 큰 축에 속한다.
    const n_big = rects(
        .{ .flags = .{ .underline = .curly, .strikethrough = true, .overline = true } },
        test_fg,
        &test_palette,
        56,
        74,
        77,
        2, // wide
        &out,
    );
    try std.testing.expect(n_big <= MAX_RECTS);
    try std.testing.expect(n_big > 74); // 열마다 최소 한 조각은 나온다

    // 상한을 넘길 만큼 극단적인 셀에서도 버퍼를 넘지 않는다 (잘릴 뿐).
    const n_huge = rects(
        .{ .flags = .{ .underline = .curly, .strikethrough = true, .overline = true } },
        test_fg,
        &test_palette,
        200,
        400,
        280,
        2,
        &out,
    );
    try std.testing.expect(n_huge <= MAX_RECTS);

    // 점선은 상한에 걸려도 그 안에 들어간다.
    const n_dot = rects(
        .{ .flags = .{ .underline = .dotted, .strikethrough = true, .overline = true } },
        test_fg,
        &test_palette,
        A,
        4000, // dotCount 가 상한에 걸리는 넓은 셀
        H,
        1,
        &out,
    );
    try std.testing.expect(n_dot <= MAX_RECTS);
    try std.testing.expect(n_dot <= MAX_UNDERLINE_PIECES + 2); // 선 2 개 + base 셀 상한

    // wide 는 base 셀 배치를 되풀이하므로 상한도 `× span` 이다. 상한을 span 으로
    // 나누면 wide 만 조각이 줄어 밀도가 깨지므로 일부러 이렇게 둔다.
    const n_dot_wide = rects(
        .{ .flags = .{ .underline = .dotted, .strikethrough = true, .overline = true } },
        test_fg,
        &test_palette,
        A,
        8000,
        H,
        2,
        &out,
    );
    try std.testing.expect(n_dot_wide <= MAX_RECTS);
    try std.testing.expectEqual(MAX_UNDERLINE_PIECES * 2 + 2, n_dot_wide);

    // 이중 밑줄(2)은 상한 안에 들어가므로 별도 여유가 필요 없다.
    const dbl = collect(.{ .flags = .{ .underline = .double, .strikethrough = true, .overline = true } });
    try std.testing.expectEqual(@as(usize, 4), dbl.n);
}
