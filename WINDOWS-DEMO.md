# Windows 머신 시연 체크리스트 (임시 — 검증 후 삭제)

`git pull origin main` 후 `zig build` → `zig-out\tildaz.exe` 실행.

---

## #127 단일 탭 시 탭바 자리 reserve 안 함
- [ ] 단일 탭 — cell 영역이 윈도우 위쪽 끝까지 (탭바 자리 없음)
- [ ] **Ctrl+Shift+T** 새 탭 → 탭바 등장 + 모든 탭 grid 새 크기로 reflow (vim 띄워두면 자연스럽게)
- [ ] 탭 닫아 1개 → 탭바 사라지고 cell 영역 다시 늘어남

## #125 Ctrl+Tab / Ctrl+Shift+Tab 다음/이전 탭
- [ ] 탭 2개 이상 → **Ctrl+Tab** 다음 (마지막→0 wrap)
- [ ] **Ctrl+Shift+Tab** 이전 (0→마지막 wrap)
- [ ] PTY 에 Tab 문자 안 감 (bash prompt 에 탭 입력 안 됨)
- [ ] **Alt+1~9** 인덱스 점프 그대로 동작

## #120 Ctrl+Shift+C selection 복사
- [ ] 드래그 selection 후 mouseUp → 자동 copy (이미 동작) → 다른 곳 paste OK
- [ ] selection highlight 유지된 상태 → **Ctrl+Shift+C** → 명시적 복사 → paste OK
- [ ] selection 없을 때 Ctrl+Shift+C → 아무 동작 없음

## #119 우클릭 paste (가운데 버튼 → 우클릭)
- [ ] 다른 곳 텍스트 복사 → 터미널 **마우스 우클릭** → paste
- [ ] 가운데 버튼 클릭은 더 이상 paste 안 함 (이전 동작 제거)

## #122 한글 word 더블클릭 (cross-platform 모듈 — 같이 검증)
- [ ] `echo 안녕하세요 반갑습니다` 출력 후 "안녕하세요" 더블클릭 → 단어 본체만 + 자동 copy
- [ ] 빈칸 / 따옴표 더블클릭 → 선택 안 됨

## #128 단축키 + config/log 위치 + About
- [ ] **Ctrl+Shift+P** → default editor (예: VS Code / Notepad) 로 `%APPDATA%\tildaz\config.json` 열림 (이전 perf dump 였던 키)
- [ ] **Ctrl+Shift+L** → default editor 로 `%APPDATA%\tildaz\tildaz.log`
- [ ] **Ctrl+Shift+F12** → perf dump (이동된 단축키)
- [ ] About (**Ctrl+Shift+I**) → exe / pid / config / log 모두 절대경로 (예: `C:\Users\...\AppData\Roaming\tildaz\config.json`)
- [ ] config 가 `<exe_dir>\config.json` 이 아닌 `%APPDATA%\tildaz\config.json` 에 자동 생성

## auto_start / hidden_start (Windows Registry Run)
- [ ] `auto_start: true` → 다음 로그인 자동 실행 (HKCU\...\Run\TildaZ 에 entry)
- [ ] `auto_start: false` → entry 자동 삭제
- [ ] `hidden_start: true` → 부팅 시 윈도우 hidden, F1 첫 누름에 표시
