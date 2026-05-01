---
name: cross-platform 앱이지만 platform 표준 / native 동작 우선
description: 같은 기능의 platform 별 구현 / 표기 / UX 결정 시 cross-platform 일관성보다 *각 platform 의 표준 / native 사용자 expectation* 을 우선. modifier 순서 / 단축키 표기 / config 위치 / log 위치 / 다이얼로그 패턴 모두 platform 표준 따름.
type: feedback
originSessionId: 691f90bd-08eb-4750-b1bf-022a10b2523a
---
tildaz 는 cross-platform 앱이지만 *platform 의 일반적 동작과 잘 어울리고 자연스러운 것* 을 cross-platform 일관성보다 우선시.

**Why:** 사용자는 자기 OS 의 *native expectation* 으로 앱 평가. 같은 기능을 cross-platform "통일 표기" 로 해도 macOS 사용자에겐 어색하고 Windows 사용자에겐 어색. 양쪽 모두 *각자 평소 패턴* 을 따라야 자연스러움. cross-platform 일관성은 *기능 매핑* 에만 적용 (Windows Ctrl+ ↔ macOS Cmd+ 같은 modifier 1:1 대응).

**적용 영역:**

1. **단축키 modifier 순서** — Apple HIG 따름:
   - macOS: `Control → Option → Shift → Command` 순서. 즉 `Shift+Cmd+P` (Cmd 가 마지막). `Cmd+Shift+P` 비표준 — 사용 X.
   - Windows: 보통 `Ctrl → Shift → Alt` 순서 — `Ctrl+Shift+P`. Microsoft 표준.

2. **config / log 위치** — 각 OS 표준:
   - Windows: `%APPDATA%\tildaz\` (Microsoft 표준)
   - macOS config: `~/.config/tildaz/` (XDG, ghostty/alacritty 패턴 — 터미널 사용자 친숙)
   - macOS log: `~/Library/Logs/tildaz.log` (Apple HIG, Console.app 자동 인덱싱)
   - Linux: `~/.config/tildaz/` (XDG)

3. **다이얼로그** — macOS NSAlert / Windows MessageBoxW. 통일 추상화 (`dialog.zig`) 는 호출 측 단순화 위함, 시각은 platform native.

4. **메뉴 / 단축키 위치** — macOS mainMenu (Accessory mode 라 시각 안 보이지만 keyEquivalent dispatch) / Windows accelerator table.

**룰의 한계 — cross-platform 일관성 영역:**

- *기능 매핑*: 같은 동작은 각 OS 표준 modifier 로 mapping 필요. macOS 새 탭 = Cmd+T, Windows 새 탭 = Ctrl+Shift+T (각자 표준).
- *config schema*: 같은 필드 이름 / 구조 (default 만 OS-specific). #118.
- *내부 코드 모듈* (terminal_interaction, themes 등): cross-platform 그대로.

**예외 (의도된 platform 차이):**

- macOS inline IME preedit overlay. Windows 는 OS candidate window 표준 유지 (#110 close 사유). 각 OS 사용자가 익숙한 패턴 유지.

`AGENTS.md` / `SPEC.md` 의 단축키 / 위치 표기는 이 룰 따라 platform 표준 형식.
