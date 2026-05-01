---
name: Windows tildaz 기능은 macOS 도 모두 동등 구현
description: Windows 에 있는 기능을 macOS 에서 'optional / 마우스로 충분 / nice-to-have' 라고 표기하거나 우선순위 낮추지 말 것. cross-platform 동등성이 critical path.
type: feedback
originSessionId: 691f90bd-08eb-4750-b1bf-022a10b2523a
---
Windows tildaz 에 있는 기능은 macOS 도 *모두* 동등 구현해야 해요. 우선순위 / 작업량 / "비슷한 효과로 우회 가능" 무관.

**Why:** cross-platform 앱의 사용자 expectation 은 platform 간 기능 동등. macOS 사용자가 Windows 에는 있는데 macOS 엔 없는 기능을 만나면 "macOS 는 미완성" 인상. Windows 가 reference 고 macOS 는 그것에 미달이면 안 됨. 사용자가 직접 명시한 룰 (#111 M11.6 "optional 아냐 반드시 해야지", #114 Shift+PgUp "마우스 휠로 충분 안 됨, Windows 에 있는 기능이면 macOS 도 꼭 들어가야").

**How to apply:**
- 이슈 댓글 / 본문 / commit message 에 "optional / nice-to-have / 마우스 / Cmd+숫자로 충분" 같은 macOS 만 빠지는 정당화 표현 안 씀.
- 우선순위 표에서 Windows 기능을 🟢 (편의) / ⚪ (있으면 좋음) 로 분류 안 함. 적어도 🟡 (곧 필요) 이상.
- "사용자 보고 시 추가" 같은 reactive 가 아니라 cross-platform 기능 매트릭스를 사전 점검 → 항목 잡고 진행.
- 예외: macOS 정체상 무의미한 기능 (예: Windows 의 layered window 특정 trick) 은 platform 표준 대안으로 대체. 단순 "skip" 안 함.

**예시:**
- Shift+PgUp scrollback — Windows 있음, macOS 도 추가
- drag 시각 follow — Windows 있음, macOS 도 추가
- rename auto-commit on focus loss — Windows 있음, macOS 도 추가
- About 단축키 — Windows Ctrl+Shift+I, macOS 는 platform 표준 modifier (Cmd+Shift+I). 같은 *기능* 의 platform-equivalent 단축키.
