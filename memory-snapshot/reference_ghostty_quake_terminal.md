---
name: ghostty Quick Terminal (drop-down 모드) 코드 위치
description: ghostty 도 drop-down 터미널 (Quick Terminal) 을 가지고 있어서 tildaz macOS 포팅의 직접 참조처. 탭 기능이 없어서 tildaz 가 별도 구현하지만 dock rect / hide-show / 글로벌 단축키 등은 그대로 참고 가능.
type: reference
originSessionId: 691f90bd-08eb-4750-b1bf-022a10b2523a
---
ghostty 의 drop-down 터미널 ("Quick Terminal") 코드는 ghostty 저장소 `macos/Sources/Features/QuickTerminal/` 에 9개 파일로 구성:

- `QuickTerminalController.swift` (~788줄) — NSWindowController. 토글 / hide-show / 애니메이션 / 멀티 모니터 처리의 메인.
- `QuickTerminalWindow.swift` — NSWindow 서브클래스. styleMask / 동작 결정.
- `QuickTerminalPosition.swift` — top/bottom/left/right/center dock 위치 enum.
- `QuickTerminalSize.swift` — width/height 비율 처리.
- `QuickTerminalScreen.swift`, `QuickTerminalScreenStateCache.swift` — 멀티 모니터 / Space 추적.
- `QuickTerminalSpaceBehavior.swift` — Space (mission control) 에서 어떻게 보일지.
- `QuickTerminalRestorableState.swift` — 종료 후 복원.

라이선스는 ghostty 와 같은 MIT (확인 후 차용 시 출처 / 라이선스 헤더 처리).

**Why:** macOS drop-down 터미널의 까다로운 부분 (글로벌 단축키, 멀티 모니터, Space 추적, dock rect 계산, hide-show 애니메이션) 이 이미 검증된 구현으로 존재함. tildaz Windows 의 `window.zig` 가 풀어둔 같은 문제들의 macOS 판본.

**How to apply:** macOS 포팅 milestone (특히 M3 = 드롭다운 토글 + dock rect) 진입할 때 해당 파일을 직접 열어 패턴 비교. 의존성 캐시(`/tmp/tildaz-zig-global-cache/p/ghostty-1.3.2-dev-...`) 또는 GitHub `ghostty-org/ghostty` 의 동일 경로에서 접근. 단, ghostty 는 Swift 기반이라 우리 Zig + ObjC runtime 모델로 옮길 때 layout() / Space 알림 같이 Swift 가 자연스럽게 받는 콜백을 어떻게 다룰지가 결정점 (옵션 D vs B).
