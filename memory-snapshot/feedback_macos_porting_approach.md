---
name: macOS 포팅 접근 방식
description: tildaz macOS 포팅은 작은 milestone 단위로, 매 단계 main 머지, 막힘 발견 시 즉시 escalation. 큰 phase 단위는 거부.
type: feedback
originSessionId: 691f90bd-08eb-4750-b1bf-022a10b2523a
---
tildaz macOS 포팅은 다음 룰로 진행한다.

- **수직 슬라이스, 작은 단위**: 매 milestone 마다 사용자가 직접 실행해 검증할 수 있는 deliverable 한 개씩. PTY/IME 같이 무거운 단계는 기본 UX(드롭다운 토글 / dock rect) 검증이 끝난 다음.
- **매 milestone main 머지**: claude/* 브랜치에 쌓아두기 X. 작은 진척이라도 main 으로 들어가야 다음 단계 실패해도 살아남음.
- **합의된 baseline = "옵션 D"**: 단일 Zig 바이너리 유지 + 드롭다운 모델로 사용자 드래그 리사이즈 자체 없음 → AppKit `layout()` 콜백 회피.
- **escalation rule**: 드롭다운 토글 + dock rect 변경(F1/모니터 변화/DPI) 에서 또 잔상 생기면 즉시 옵션 B (Swift main + Zig backend, ghostty 와 같은 Xcode-기반 모델) 로 escalation. PTY/IME 같이 비싼 단계 추가 진행 전에 결정.

**Why:** 이슈 #75 에서 phase 0~5 + IME 까지 6번 시도 후 리사이즈 잔상으로 main 미머지 종료. 사용자가 명시적으로 "#75 그대로 진행은 절대 안 됨, 몇 번이나 실패했음" 이라고 거부. 큰 phase 가 문제가 아니라 검증 시점이 늦어서 비싼 작업이 사장됐다는 진단.

**How to apply:** macOS 작업 시작 전에 트래킹 이슈로 milestone 시퀀스 확정. M1 (host 골격) → M2 (NSWindow + Metal 빈 화면) → M3 (드롭다운 토글 + dock rect, **최우선 검증 포인트**) 순서. M3 통과 못 하면 PTY/IME 손도 대지 말고 옵션 B 검토. PTY/CoreText/Metal 셰이더는 #75 에서 통과했으니 패턴 재사용 가능.
