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

// 탭바 — Windows app_controller 의 TAB_* 상수와 같은 디자인.
pub const TAB_BAR_HEIGHT_PT: u32 = 28;
pub const TAB_WIDTH_PT: u32 = 150;
pub const TAB_PADDING_PT: u32 = 6;
pub const TAB_CLOSE_SIZE_PT: u32 = 14;

/// 활성 탭 배경 — 어두운 회색 (RGBA 0..1).
pub const TAB_ACTIVE_BG: [4]f32 = .{ 0.30, 0.30, 0.30, 1.0 };
/// 비활성 탭 배경 — 더 어두움.
pub const TAB_INACTIVE_BG: [4]f32 = .{ 0.15, 0.15, 0.15, 1.0 };
/// 탭바 배경 (탭 영역 밖). 비활성보다도 살짝 더 어두움.
pub const TAB_BAR_BG: [4]f32 = .{ 0.10, 0.10, 0.10, 1.0 };
/// 탭 텍스트 색.
pub const TAB_TEXT_COLOR: [4]f32 = .{ 0.85, 0.85, 0.85, 1.0 };
