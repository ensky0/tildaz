---
name: tildaz commit 에 Co-Authored-By 트레일러 금지
description: tildaz 저장소의 모든 commit 메시지에서 `Co-Authored-By` 트레일러 (Claude / AI tool 등) 를 절대 넣지 말 것.
type: feedback
originSessionId: 691f90bd-08eb-4750-b1bf-022a10b2523a
---
tildaz 저장소의 모든 commit 메시지에서 `Co-Authored-By` 트레일러 (Claude /
AI tool 등) 를 **절대 넣지 않음**. 어떤 변경이든 어떤 commit 이든.

**Why:** 사용자가 명시적으로 요청 (2026-04-30). 저장소 운영 정책 — 모든 commit
author 는 사람으로 통일. 도구 사용 사실은 코드 / 이슈 본문 / 댓글 등 다른
곳에 충분히 남아 있음. 같은 규칙이 `AGENTS.md` 의 "커밋 메시지" 섹션에도
명시됨.

**How to apply:** tildaz 저장소 (`/Users/mac_al03241613/tildaz`) 에서 commit
메시지 작성 시. 기존 default behavior (Co-Authored-By 추가) 와 반대 — 매
commit 마다 의식적으로 제외.
