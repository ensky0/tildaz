---
name: macOS 포팅 트래킹 이슈는 milestone 전체 완료까지 열어두기
description: tildaz macOS 포팅의 트래킹 이슈 (#108) 는 단일 milestone 완료마다 close 하지 말고 큰 묶음 (M3 / M5 / M6 같은) 전체가 끝날 때까지 open 유지. 진척은 댓글로 표.
type: feedback
originSessionId: 691f90bd-08eb-4750-b1bf-022a10b2523a
---
이슈 #108 같은 macOS 포팅 트래킹 이슈는 sub-milestone (M5.0 → M5.1 → M5.2 → ...) 마다 close 하지 않는다. 큰 묶음 단위 (M3 검증 / M5 PTY+렌더 전체 / M6 IME 전체) 가 끝날 때까지 open 유지하면서 진척은 매 commit 후 댓글로 표 업데이트.

**Why:** M3 검증 통과 후 #108 close 했더니 M3.5 / M5.x 진행하면서 같은 이슈에 댓글 다는 게 어색해졌다. 사용자가 \"close 하지 말고 열어놔\" 명시적으로 요청 — milestone 트래킹용 이슈는 큰 단위로 묶어서 진행 추적이 자연스러움.

**How to apply:** 매 sub-milestone commit 후 #108 에 결과 댓글 + milestone 표 업데이트. Close 는 큰 묶음 (M5 전체 끝, 또는 macOS 포팅 자체 완료) 시점에만. 별도 후속 이슈 (#109 같은 \"개발 환경 안정화\") 는 당장 작업 안 해도 되는 별개 영역만 분리해서 만든다.
