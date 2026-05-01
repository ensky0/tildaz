---
name: 이슈 close 신중 — 보이면 끝이 아님
description: 동작 일부 OK 라고 close 하려는 경향이 강함. UX / 완성도 차이 남아있으면 OPEN 유지 + 코멘트로 진행 상황 남김.
type: feedback
originSessionId: 691f90bd-08eb-4750-b1bf-022a10b2523a
---
이슈가 *기능적으로 동작* 한다고 close 하려는 경향이 있는데, 사용자는 동작 + UX + 완성도 모두 일치할 때까지 OPEN 유지 선호.

**Why:** "보이면 다가 아니라" — 예: emoji picker 가 뜨긴 해도 cursor 옆 popover 가 아니거나 focus 잃어도 안 닫히는 등 UX 차이가 있으면 그 차이도 같은 이슈에서 추적해야. 별도 issue 분리하면 맥락 끊기고, close 하면 "끝난 것" 으로 보여 follow-up 잊힘.

**How to apply:**
- 동작 가능한 상태에서도 *남은 UX / 완성도 차이* 가 있으면 OPEN 유지.
- 진행 상태 / 시도한 fix / 남은 작업 / 분석한 원인 모두 *해당 이슈 코멘트* 로 누적. 별도 issue 로 분리하지 않음 (맥락 보존).
- close 결정은 *사용자 명시* 후만. 내가 먼저 "close 가능합니다" 제안 자체도 신중 — 사용자가 만족 안 한 부분 있을 수 있음.
- "동작 자체는 가능 + UX 차이 별도 issue" 같은 분리도 사용자 합의 후만.

**관련:** `feedback_no_premature_completed.md` 와 같은 정신 — *시연 + 사용자 만족* 까지 진짜 끝.
