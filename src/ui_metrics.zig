//! 크로스 플랫폼 UI 디자인 상수. logical points 단위 — 사용처에서 DPI /
//! Retina scale 을 곱해 pixel 단위로 변환. Windows / macOS 가 동일 값 사용해
//! 두 플랫폼 시각적 일관성 유지.

/// 터미널 영역 안쪽 padding. 글자가 윈도우 모서리에 딱 붙지 않게.
pub const TERMINAL_PADDING_PT: u32 = 6;

/// 우측 scrollbar 너비.
pub const SCROLLBAR_W_PT: u32 = 8;

/// scrollbar thumb 의 최소 높이 — scrollback 이 길어 ratio 가 매우 작아도
/// thumb 가 클릭 가능한 크기 유지.
pub const SCROLLBAR_MIN_THUMB_H_PT: u32 = 32;

/// scrollbar thumb 색상 — 흰색 알파 30%, 어떤 배경 위에서도 살짝 보임.
pub const SCROLLBAR_COLOR: [4]f32 = .{ 1, 1, 1, 0.3 };

// 탭바 — Windows `d3d11_renderer.zig` 의 TAB_* 상수와 같은 디자인 (시각 일관성).
pub const TAB_BAR_HEIGHT_PT: u32 = 28;
pub const TAB_WIDTH_PT: u32 = 150;
pub const TAB_PADDING_PT: u32 = 6;
pub const TAB_CLOSE_SIZE_PT: u32 = 14;

/// 활성 탭 배경 (50/255 ≈ 0.196). Windows `TAB_ACTIVE_R` 와 동일.
pub const TAB_ACTIVE_BG: [4]f32 = .{ 50.0 / 255.0, 50.0 / 255.0, 50.0 / 255.0, 1.0 };
/// 탭바 배경 (탭 사이 + 외곽). 20/255 ≈ 0.078. Windows `TAB_BAR_R` 와 동일.
/// 비활성 탭과 활성 탭 *주변* 의 어두운 영역 — 탭의 윤곽선 역할.
pub const TAB_BAR_BG: [4]f32 = .{ 20.0 / 255.0, 20.0 / 255.0, 20.0 / 255.0, 1.0 };
/// 탭 텍스트 색 (180/255 ≈ 0.706). Windows `TAB_TEXT_R` 와 동일.
pub const TAB_TEXT_COLOR: [4]f32 = .{ 180.0 / 255.0, 180.0 / 255.0, 180.0 / 255.0, 1.0 };

// 비활성 탭 배경은 상수가 아니라 *renderer 의 default_bg (terminal 배경)* 를
// 사용해요. cell grid 와 같은 색이라 비활성 탭이 cell 영역과 자연스럽게
// 이어지고 활성 탭만 두드러지는 효과 — Windows 패턴.
// 탭 placement 도 Windows 와 동일: 좌우 1px + 상하 2px gap 을 두고 sandwich.
// 그 gap 으로 TAB_BAR_BG 가 보여 탭의 명확한 윤곽선 역할.
