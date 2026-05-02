# Windows 머신 시연 체크리스트 (임시 — 검증 후 삭제)

> 검증 끝나면 **`WINDOWS-DEMO.md` + `memory-snapshot/`** 두 디렉토리 모두 삭제 commit.

`git pull origin main` 후 `zig build` → `zig-out\bin\tildaz.exe` 실행.

> ⚠️ macOS 작업 + #118 진행 중 코드 변경이 누적됨. 기존 동작 regression 도 같이 점검.

---

## #117 탭바 가로 스크롤 + 화살표 / `+` 버튼 (Firefox 패턴)

탭 수가 늘어 탭바 총 너비 (count × 150pt) 가 윈도우 너비를 넘어가면 양 끝에 `<` `>` 화살표 + 그 안쪽에 `+` 새 탭 버튼 표시. 탭 너비는 squish 없이 고정. 두 commit 묶음:

- `8eca455` — scroll 핵심 (활성 탭 자동 viewport 이동, drag auto-scroll)
- `861c55d` — 화살표 / `+` 버튼

### scroll 핵심

- [ ] 작은 윈도우에서 **Ctrl+Shift+T** 로 탭 다수 생성 — 화살표 등장 시점부터 viewport 가 활성 (= 마지막) 탭이 보이도록 자동 이동
- [ ] **Alt+1** → viewport 가 왼쪽 끝 (활성 = 첫 탭)
- [ ] **Alt+9** (마지막 탭) → 오른쪽 끝
- [ ] **Alt+3** (중간) — 이미 viewport 안에 있으면 그대로, 가려져 있으면 보이는 가장 가까운 위치 (Chrome 의 minimum 이동 패턴)
- [ ] **탭 drag auto-scroll — 양쪽**:
  - 탭 잡고 viewport **왼쪽 끝** (32px 안) → 왼쪽으로 자동 스크롤
  - 탭 잡고 viewport **오른쪽 끝** → 오른쪽으로 자동 스크롤
  - 마우스 멈추면 추가 스크롤 안 됨 (move event 동안만)
- [ ] 윈도우 너비 줄였다 늘렸다 → 항상 활성 탭 보임 + viewport 안 비움
- [ ] 단일 탭 / 짧은 탭바 (총 너비 ≤ vp) — 스크롤 없음

### 화살표 / `+` 버튼

- [ ] 탭 viewport 가득 차면 좌측 끝 `<`, 우측 끝 `>`, 그 옆 `+` 글리프 표시. 레이아웃 `[<][tabs][+][>]` — `>` 가 가장 끝.
- [ ] 첫 탭 보일 때 `<` 회색 (disabled), 마지막 탭 보일 때 `>` 회색
- [ ] 활성 (밝은 흰색) vs 비활성 (어두운 회색) 명확히 구분되어 보임
- [ ] **`<` 클릭** → viewport 가 1 탭 너비씩 왼쪽으로
- [ ] **`>` 클릭** → 1 탭 너비씩 오른쪽으로
- [ ] 더 갈 곳 없으면 화살표 회색 + 클릭해도 무동작
- [ ] **`+` 클릭** → 새 탭 생성 → viewport 가 우측 끝으로 자동 이동
- [ ] 화살표로 viewport 옮겨 활성 탭이 가려진 상태 → 다른 탭 클릭 / Alt+숫자 / `+` → 활성 탭 다시 보이는 위치로 ensure 자동 정렬
- [ ] 탭 적어 다 보일 때 — 화살표 `<` `>` 안 보이고 마지막 탭 바로 옆에 `+` 만
- [ ] **탭 영역과 화살표 영역 사이 시각 분리 명확** (gap 8pt) — 첫 / 마지막 탭이 viewport 끝에서 잘려도 그 글자가 화살표 영역에 침범해 보이지 않음 (별도 batch 로 위에 덮음)
- [ ] **탭 close 버튼 (탭 우측 X)** 클릭 — 그 탭 닫힘 (영역 분기 정상)
- [ ] **탭 더블클릭** (rename 시작) — 탭 영역 안에서만 동작, 화살표 / `+` 위 더블클릭은 무동작

### 회귀 체크

- [ ] **탭 drag reorder** — auto-scroll 없이도 정상 (탭 적을 때) + auto-scroll 동안에도 정상
- [ ] **탭 close 버튼 (X)** — viewport 안 / 가장자리 모두 정상
- [ ] **rename 진행 중 화살표 / `+` 클릭** — rename commit 후 화살표 / `+` 동작

---

## #116 Alt+F4 종료 confirm 다이얼로그

macOS 에서 `applicationShouldTerminate:` 로 Cmd+Q 가로채 confirm 띄움. Windows 동등은 WM_CLOSE 핸들러 — `MessageBoxW` 인라인 호출을 `dialog.showConfirm` (cross-platform) 으로 교체 + 단축어 통일.

- [ ] **단일 탭 + Alt+F4** → "Quit TildaZ?" 다이얼로그 + 본문 "This will close 1 open tab." + Cancel(default) / OK 버튼
- [ ] Cancel 누름 → 윈도우 그대로, 탭 유지
- [ ] OK 누름 → 종료
- [ ] **탭 2 개 + Alt+F4** → 본문 "This will close 2 open tabs." (`s` 붙음)
- [ ] **탭 3+ Alt+F4** → "This will close 3 open tabs."
- [ ] **시스템 메뉴 (창 좌상단 ☰) → Close** 클릭 → 같은 confirm
- [ ] **Enter 만 눌러도 종료 안 됨** — default 버튼이 Cancel 이라 무심코 Enter 가 종료 안 트리거
- [ ] **마지막 탭 셸 `exit`** → confirm 없이 즉시 종료 (PTY exit 자동 종료 path, `shell_exited` 분기)
- [ ] **탭바 X 클릭으로 마지막 탭 닫기** → confirm 없이 즉시 종료

---

## #118 추가 sub: Windows hotkey config (방금 추가)
- [ ] config 의 `"hotkey": "f1"` default 자동 생성 (`%APPDATA%\tildaz\config.json`)
- [ ] `"hotkey": "ctrl+space"` 로 변경 후 재시작 → Ctrl+Space 가 toggle 트리거
- [ ] `"hotkey": "shift+win+t"` 로 변경 후 재시작 → Shift+Win+T 가 toggle (그 사이 F1 은 동작 X)
- [ ] `"hotkey": "noSuchKey"` → fatal dialog "failed to parse hotkey value"
- [ ] f1..f12, space, grave, alphanumeric (e.g. `"ctrl+a"`) 모두 동작

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

## #132 emoji 렌더링 (macOS 작업 — Windows 동등성 확인)

macOS 에서 R8 alpha-only atlas 가 Apple Color Emoji silhouette 만 표시하는 문제를 BGRA8 atlas 로 fix. Windows 는 ClearType 용 R8G8B8A8 atlas 라 *색깔 자체*는 처음부터 OK 일 가능성 높지만, **grapheme cluster 단위 처리** (VS-16, skin tone modifier, ZWJ 시퀀스) 는 별개 문제로 Windows 도 깨질 가능성 큼.

Windows 의 emoji picker 는 `Win+.` (또는 `Win+;`).

- [ ] **단순 컬러 emoji**: picker 에서 😂 🌀 🐱 🚀 클릭 → 셀에 컬러 글리프 정상 (검은 silhouette 아님)
- [ ] **`echo` 직접 출력**: `echo 😂🌀🐱🚀` → 위와 동일 컬러
- [ ] **VS-16 emoji presentation** (text-default codepoint + U+FE0F):
  - picker 의 ❤️ (HEAVY BLACK HEART + VS-16) → 빨간 하트 emoji (작은 검은 ♥ 아님)
  - ☀️ ☁️ ☕ ✌️ ✈️ — 모두 컬러 emoji presentation
- [ ] **Skin tone modifier** (base + U+1F3FB-U+1F3FF):
  - 👍🏻 👍🏽 👍🏿 — 톤별 갈색 thumbs-up 단일 글리프 (yellow 👍 + 갈색 사각형 분리 X)
  - 👋🏼 ✋🏾 — 손 emoji 도 동일
- [ ] **ZWJ 시퀀스** (U+200D 결합):
  - 👨‍👩‍👧 → 가족 emoji 단일 글리프
  - 👩‍🚀 🧑‍💻 — 직업/역할 합성
  - 🏳️‍🌈 — 무지개 깃발 (깃발 + VS-16 + ZWJ + 무지개)
- [ ] **vim / 다른 셸 안 emoji** — `vim` 열고 emoji 입력 / paste → 동일하게 정상
- [ ] **복사/붙여넣기 round-trip** — 셀의 emoji 드래그 → Cmd+C → 다른 곳 paste → emoji 가 깨지지 않고 그대로 (codepoint 시퀀스 유지)

회귀 체크:
- [ ] 일반 텍스트 (영문/한글/숫자) 색상 정상
- [ ] 커서 / 선택 / 탭바 색상 정상
