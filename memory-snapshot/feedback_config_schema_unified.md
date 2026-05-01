---
name: config schema 는 Windows / macOS 동일 통합 (default 만 OS-specific)
description: config json 의 필드 schema 는 양쪽 platform 동일. font / shell 같은 OS-specific resource 는 default 값만 platform 별로 다름.
type: feedback
originSessionId: 691f90bd-08eb-4750-b1bf-022a10b2523a
---
config json schema 는 Windows / macOS 양쪽 동일해야 해요. 사용자가 같은 config 파일 형식을 두 platform 에서 똑같이 쓸 수 있어야 함 (학습 곡선 / 마이그레이션 단순).

**Why:** 사용자가 두 platform 모두 사용. 같은 키워드 / 같은 구조의 config 를 기대. 한쪽에만 있는 필드 / 한쪽에만 다른 키 이름은 cross-platform 앱의 사용자 expectation 위반.

**How to apply:**
- config 필드 추가 / 변경 시 *양쪽 platform 동시*. Windows 만 추가하고 macOS 는 미루는 식 안 함.
- 필드 *이름* 동일 (예: `width` 같은 키, `width_pct` 같이 한쪽만 다른 이름 X — schema 통합 시 정정).
- **default 값**은 OS-specific resource 가 필요한 항목만 platform 별로 다름. 예: font_family — Windows default `"Cascadia Mono"`, macOS default `"Menlo"`. Validation 로직 / 매핑은 동일.
- 통합은 *단계별* 가능. Windows 가 reference, macOS 가 부분 도달 → 후속 milestone 으로 점진 통합. 다만 *최종 목표는 통일*.

**현재 상태 (2026-04 기준):**
- Windows `src/config.zig` 가 reference — dock_position / width / height / offset / opacity / theme / font (size / family / families / line_height / cell_width) / shell / auto_start / hidden_start / max_scroll_lines.
- macOS `src/macos_config.zig` 가 부분 — dock_position / width_pct / height_pct / offset_pct / opacity / hotkey 만.
- 통합 미완 사항: 필드 이름 정렬 (`width_pct` → `width`), font 필드 도입, shell / auto_start / hidden_start / max_scroll_lines 추가, 그리고 정말 macOS 단독 (hotkey) 만 분리 유지.
