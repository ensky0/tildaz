---
name: macOS M3 통과로 검증된 옵션 D 패턴 + 환경 학습
description: 이슈 #108 의 M3 (drop-down 토글) 가 통과해서 옵션 D 살림. 다음 milestone 진행 시 재사용할 환경 학습 정리.
type: project
originSessionId: 691f90bd-08eb-4750-b1bf-022a10b2523a
---
이슈 #108 M3 가 main 머지 (커밋 1affa73) 됐다. 옵션 D (단일 Zig 바이너리 + 드롭다운 모델) 의 핵심 가설 검증됨 — 사용자 드래그 리사이즈 자체가 없으니 #75 가 막혔던 layout() 콜백 시나리오 부재.

**M3 통과로 살아남은 패턴 (M4+ 에서 재사용)**:

1. **글로벌 핫키 = CGEventTap (Carbon RegisterEventHotKey 안 씀)**
   - macOS Tahoe (26) + ad-hoc 서명 환경에서 Carbon 은 silently fail (등록은 OSStatus 0 이지만 dispatch 안 옴 + NSApp 키 dispatch 까지 깸).
   - Apple DTS 권장 modern API. \"Input Monitoring\" 권한 필요.
   - sindresorhus/KeyboardShortcuts 가 Carbon 으로 production 동작하는 건 Apple Developer 인증서 sign 환경. ad-hoc 환경에선 안 됨.

2. **\".app 번들 + Info.plist + ad-hoc 서명\" 트리오 필수**
   - CLI binary 직접 실행은 macOS 의 정식 앱 라이프사이클 못 들어감 — Info.plist 키 무시.
   - build.zig 의 install step 에서 자동화.

3. **`NSApplicationActivationPolicy.Accessory` (= 1) 로 코드 레벨 처리**
   - LSUIElement plist 키만으로는 LaunchServices 캐시 / 정책 때문에 적용 안 되는 경우 있음.
   - 코드에서 `setActivationPolicy:Accessory` 호출하면 plist 무관하게 즉시 효과.

4. **borderless-style 윈도우 = `Titled | FullSizeContentView` + 시각 hide**
   - styleMask=0 (Borderless) 면 canBecomeKeyWindow false → mainMenu Cmd+Q 안 됨.
   - Titled + FullSizeContentView + setTitlebarAppearsTransparent + setTitleVisibility(Hidden) + standardWindowButton 모두 hide + setMovable:NO 조합으로 시각적으로는 borderless 지만 keyWindow 가능. ghostty Quick Terminal 동일 패턴.

5. **Bundle Identifier**: `me.ensky0.tildaz` (사용자 도메인 ensky0.me 의 reverse-DNS).

**알려진 한계 — #109 에서 트래킹**:

- ad-hoc 서명은 매 빌드 binary hash 변경 → Input Monitoring 권한 stale. 매 빌드 후 권한 갱신 (시스템 설정 토글 OFF/ON 또는 `tccutil reset All me.ensky0.tildaz`) 필요.
- self-signed code signing 인증서 시도했지만 회사 MDM 환경에서 trust silently 거부 (`security add-trusted-cert` 가 OSStatus 0 이지만 실제 trust 안 됨, codesign \"Invalid Key Usage for policy\" 에러).
- 영구 해결은 Apple Developer 무료 인증서 (Xcode + Apple ID) 또는 Apple Developer Program 유료. 우선순위 낮음 — 개발 부담만, 동작 자체는 OK.

**Why:** 다음 milestone (M3.5 = config 통합, M4 = 모니터/DPI/Dock 변화 추적, M5 = PTY, M6 = IME) 진행 시 위 패턴 / 한계를 재참고. 같은 진단 사이클 반복 안 하기.

**How to apply:** macOS 환경 통합 코드 작성 시 위 \"M3 통과 패턴\" 체크리스트로 사용. 새로운 권한 시스템 / 윈도우 동작 / 키 이벤트 처리 막히면 `feedback_macos_porting_approach.md` 의 escalation 룰 (즉시 옵션 B 검토) 적용.
