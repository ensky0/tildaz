---
name: macOS Cocoa quirks (시연 중 발견 + 해결 패턴)
description: macOS 포팅 시연 (#121, #122, #124, #128) 중 발견한 Cocoa 동작 quirks 와 해결 패턴 — 향후 macOS 다이얼로그 / IME / 종료 hook / wide char 작업 시 재참고.
type: project
originSessionId: 691f90bd-08eb-4750-b1bf-022a10b2523a
---
2026-05-01 시연 중 발견. 모두 macOS 표준 동작이지만 직관과 다르거나 안내가 부족한 케이스.

## 1. NSApplication.terminate: 가 defer 안 거침
- Cmd+Q (NSApp `terminate:`) 가 `exit()` 직행 → main 의 `defer` 안 불림.
- 해결: POSIX `atexit()` 으로 hook 등록. wrapper 함수에서 cleanup.
- 적용처: `macos_host.zig` 의 `atExitLogStop` ([exit] 라인 기록).

## 2. 영어 key repeat 안 됨 (한글 자모는 정상)
- 원인: macOS "Press and Hold" 기능 — 영어 키 길게 누르면 system 이 accent picker (à á â) 띄우려 key repeat 막음. 한글은 IME 경로라 영향 없어 비대칭.
- 해결: `ApplePressAndHoldEnabled = false` 를 우리 앱 NSUserDefaults 에 register. ghostty / iTerm2 / Alacritty 동일.

## 3. 한글 IME 조합 중 Ctrl+key 처리
- 원인: `keyDown` 에서 IME 가 markedText commit 시 `interpretKeyEvents` 로 흘러 우리 ctrl 분기까지 도달 안 함 → SIGINT 안 감.
- 해결: ctrl modifier 검사를 IME 조합 여부와 무관하게 항상 검사. 조합 중이면 (1) `[inputContext discardMarkedText]` (2) 우리 `g_marked_len = 0` + `g_preedit_len = 0` (overlay 비움) (3) PTY 로 \x03 직송. shell 의 "입력 라인 버리기" 의도와 일관.

## 4. NSAlert modal 안에서 Cmd+C 가 NSTextField/NSTextView 에 라우팅 안 됨
- 원인: NSAlert.runModal 시 default 버튼 (OK) 이 firstResponder 로 강제 고정. NSTextField cell 은 NSText/NSTextView responder chain 밖이라 `copy:` selector 자체가 안 닿음. NSTextView 도 firstResponder 안정적으로 못 잡음.
- 해결: 본문을 `accessoryView` 의 NSTextView (selectable, monospace) 로 표시 + delegate 의 `textViewDidChangeSelection:` 에서 selection 변경 시 즉시 NSPasteboard 복사. 우리 터미널 selection finish auto-copy (#122) 와 같은 패턴 — firstResponder/cmd+c 라우팅 우회 보너스.

## 5. ghostty `selectWord` 가 wide char (한/中/日) 음절마다 끊음
- 원인: wide char 의 `spacer_tail` cell (글자의 right-half) 을 boundary 로 취급 → 음절 사이 클릭 시 null, 음절 위 클릭 시 음절 하나만.
- 해결: `terminal_interaction.selectWord` 를 ghostty 함수와 같은 구조로 직접 구현. (1) 클릭이 spacer_tail 이면 wide cell (x-1) 로 정규화. (2) 확장 중 spacer_tail 만나면 boundary 검사 *skip* 하고 다음 cell 로. (3) 보너스: 시작이 boundary (공백/구두점) 면 즉시 false 반환 — iTerm2 / Terminal.app 동등.

## 6. 환경 quirk: 회사 노트북 `~/Library/LaunchAgents` root 소유
- pulsesecure (회사 VPN) 같은 패키지가 root 권한으로 디렉토리 만들어 사용자 owner 빼앗음.
- 결과: LaunchAgent plist 작성 실패 (`AccessDenied`). graceful fail 로 앱은 정상 동작.
- 복구: `sudo chown -R $(whoami):staff ~/Library/LaunchAgents` (회사 plist owner 도 같이 바뀌므로 신중).
