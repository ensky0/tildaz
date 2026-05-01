---
name: macOS 포팅 과거 시도 이력
description: 이슈 #75에서의 macOS 포팅 시도 결과 + 막힌 원인 + 학습 포인트.
type: project
originSessionId: 691f90bd-08eb-4750-b1bf-022a10b2523a
---
이슈 #75 macOS 포팅 시도는 main 미머지로 종료. claude/infallible-swartz, claude/nostalgic-edison, claude/fervent-hellman 세 브랜치에 15+ 커밋이 남아 있고, 거기서 통과/실패한 것을 다음 시도가 재사용해야 한다.

**통과했던 영역 (재사용 가능):**
- POSIX PTY (openpty/forkpty/login_tty/execve) — `src/macos/pty.zig` 패턴.
- CoreText 폰트 + R8 글리프 아틀라스 — alpha-only CGBitmapContext (colorspace=null), CTFontCreateForString 폴백.
- Metal 셰이더 (HLSL → MSL), 인스턴스드 쿼드, TriangleStrip(4) primitive.
- 한글 IME (NSTextInputClient + preedit overlay + 첫 글자 replay 워크어라운드).

**막힌 영역:**
- 사용자 드래그 리사이즈 시 잔상/문자 사이 빈 칸. 6+ 시도 모두 실패. setDrawableSize / setBounds / makeBackingLayer / IOSurface 더블버퍼 / 디바운스 등 모두 부분 개선만.
- 근본 원인: AppKit `layout()` 콜백이 Zig ObjC runtime 으로 등록한 NSView 서브클래스에선 호출되지 않음. ghostty 는 Swift NSView 로 처리.

**Why:** 다음 시도가 #75 의 실패한 길을 똑같이 밟지 않게 함. 특히 "Zig ObjC runtime 으로 layout 우회" 시도는 막다른 길임이 검증됨.

**How to apply:** 다음 시도 시작 전에 #75 댓글 다시 안 읽어도 되도록 핵심만 여기에 둠. 실패한 영역(드래그 리사이즈)을 회피하는 모델(드롭다운 = 사용자 드래그 없음)이 합의된 baseline. PTY/CoreText/Metal/IME 패턴은 #75 브랜치 커밋들에서 그대로 들고 와도 됨.
