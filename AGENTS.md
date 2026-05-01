# 워크플로우

모든 작업은 아래 순서로 진행해요.

1. **이슈 확인**: 관련 이슈가 이미 있는지 확인하고, 없으면 새로 생성해요.
2. **계획 기록**: 이슈에 구체적인 구현 계획을 먼저 댓글로 기록해요.
3. **작업 수행**: 작업하면서 중간 결과, 결정 사항, 변경 이유 등을 계속 이슈에 댓글로 기록해요.
4. **검증**: 빌드와 테스트를 직접 실행해서 작업 내용이 올바른지 확인해요.
5. **완료**: 검증이 끝나면 커밋하고, 새 버전으로 릴리즈해요.
6. **이슈 닫기**: 릴리즈 후 이슈를 닫아요.

# 문서화

문서는 항상 확인된 내용만 정확하게 작성해요.
추정, 가설, 미확인 내용은 사실처럼 쓰지 말고 `추정`, `가설`, `확인 필요`처럼 상태를 명시해요.
문서화할 때는 가능한 한 **출처 링크를 함께 남겨요**.
특히 GitHub 이슈, 이슈 코멘트, 릴리즈 노트, 작업 기록 문서에는 사실 판단의 근거가 되는 공식 문서, 이슈, 코드, 커밋, 로그 등의 링크를 포함해요.
이 원칙은 GitHub 이슈, 이슈 코멘트, 릴리즈 노트, 작업 기록 문서에 모두 동일하게 적용해요.

# 한글 IME 동작 스펙

한글 (한국어 / 일본어 / 중국어 IME 일반) 입력 시 다음 동작이 정의된 스펙이에요.
플랫폼별 OS API 차이는 있지만 사용자 시각 동작은 동일해야 해요.

- **조합 중 (preedit)** 표시: 자모 / 미완성 음절을 cursor 위치에 강조 배경 (보라색
  계열) + 글자로 inline 표시. 별도 candidate window 안 띄움.
- **음절 단위 backspace**: 조합 중에 backspace → IME 가 자모 단위로 되돌리고
  화면도 대응해 갱신.
- **화살표 / 영문 / space / Enter 등 IME 가 모르는 키**: IME 가 현재 음절을 즉시
  commit (확정) 한 후 그 키를 PTY 로 전달. 즉 `'하'` 까지 친 상태에서 →
  화살표 누르면 `'하'` 가 commit 되고 cursor 가 한 칸 이동.
- **commit 트리거**: 위 키 외에도 음절이 더 이상 확장 안 되는 자모 시퀀스 (예:
  `'한'` 다음 추가 자음) 가 와도 IME 가 자동 commit.

플랫폼 구현:
- **macOS**: NSTextInputClient protocol — `interpretKeyEvents:` → `setMarkedText:`
  (조합 중) / `insertText:` (commit) / `doCommandBySelector:` (special key) 콜백.
  preedit overlay 는 우리 metal renderer 가 `cursor.viewport` 위치에 직접 그림.
- **Windows**: OS IME 자체 candidate window 가 표시 + commit 만 `WM_CHAR` 로 전달.
  *의도된 platform 차이* (#110 close 사유, SPEC.md §5) — Windows 사용자가 OS
  candidate window 에 익숙 + IMM 통합 시 모든 IME 종류 (한글 / 일본어 / 중국어
  / 베트남어 등) 책임지는 부담 회피. cross-platform 동등성 룰의 명시 예외.

# 근본 해결 원칙

증상을 가리는 hack / 우회 / dummy 데이터 / "이렇게 두면 일단 보이긴 한다"
류의 fix 는 **절대 채택하지 않아요**. 모든 버그는 *진짜 원인*을 찾아 그 자리에서
고쳐요. 원인을 못 찾는다면 그렇다고 솔직히 말하고 더 진단해요.

이유:
- hack 은 다른 곳에서 더 큰 버그로 나타나요. 원인은 그대로 남으니까요.
- "dummy 첫 instance" / "1px shift" / "+1 / -1 보정" 같은 fix 는 다른 코드의
  의미를 흐리고, 다음 사람이 왜 그렇게 되어 있는지 못 알아봐요.
- 미해결 quirk 는 코드 안의 hack 보다 코드 옆 주석 + follow-up 이슈가 나아요.
  "여기서 막혔고 원인을 모름" 을 정직하게 남기는 게 후속 디버깅에 훨씬 도움.

원칙:
- 한 번에 여러 hypothesis 를 hack 으로 시도하지 말고, 진단으로 사실을 좁히고
  진짜 원인을 좁힌 뒤에 1 발에 끝내요.
- 막히면 "이 부분에서 원인 모름. 진단 더 필요" 라고 솔직하게 사용자에게 보고.

# 커밋 메시지

`Co-Authored-By` 트레일러 (Claude / AI tool 등) 는 **절대 넣지 않아요**.
사람이 직접 작성한 것처럼 보여야 하는 게 아니라, 단순히 저장소 운영 정책으로
모든 commit author 는 사람으로 통일해요. 도구 사용 사실은 코드 / 이슈 본문
/ 댓글 등 다른 곳에 충분히 남아 있어요.

# 사용자 표시 텍스트 / 다이얼로그

앱이 사용자에게 보여주는 모든 텍스트와 다이얼로그는 두 모듈을 반드시 거쳐요.

- **`src/messages.zig`**: 사용자에게 노출되는 모든 텍스트 상수 / format string 의 단일 진입점. 새 메시지가 필요하면 여기 먼저 추가하고 호출처는 이 상수만 import 해요. 같은 의미의 메시지를 platform 별로 두 번 작성하지 않아요.
- **`src/dialog.zig`**: cross-platform 다이얼로그 추상화. `showInfo` / `showError` / `showFatal` 만 호출해요. comptime 으로 `dialog_windows.zig` (`MessageBoxW`) 또는 `dialog_macos.zig` (`osascript display dialog`) 가 선택돼요.

**금지**: `MessageBoxW` / `MessageBoxA` / `NSAlert` / `osascript` 같은 platform 직접 호출. 정책 우회가 한 군데라도 생기면 메시지 변경 / i18n / 톤 통일 모두 해당 호출처를 따로 추적해야 해요. 새 platform 분기가 필요하면 `dialog.zig` 의 `impl` switch 에 추가해요.

panic / 패치 실패 / config 검증 / About 등 모두 같은 경로를 써요. 이번 변경 (`refactor(dialog)` 커밋) 이전엔 host 별로 흩어져 있었지만 이젠 모두 정리됐어요.

# 터미널 환경변수 (TUI dark/light colorscheme)

자식 셸 process 에 다음 환경변수를 *항상* 넘겨요. 한쪽 platform 에 빠지면 사용자가 *터미널 cell 색은 같지만 vim 안 텍스트 색이 다르다* 같은 미묘한 차이를 보고할 가능성이 높아요. macOS 포팅 중 실제 발생 (#113 M13.2) — Windows TildaZ 가 매일 보던 vim 색과 macOS 가 달라 보이는 원인이 이 환경변수였음.

| 환경변수 | 역할 | 값 결정 |
|---|---|---|
| `TERM` | escape sequence + 256-color 표준 | `xterm-256color` (양쪽 동일) |
| `LANG` | bash readline 의 multi-byte 처리 | `en_US.UTF-8` (양쪽 동일) |
| `LC_CTYPE` | ditto, 일부 셸이 `LANG` 안 봄 | `en_US.UTF-8` (양쪽 동일) |
| `COLORFGBG` | vim / less / tmux 가 자동 dark/light colorscheme 선택 | theme.background luminance 로 `"15;0"` (dark) / `"0;15"` (light) |
| `WSLENV` | WSL 안 process 에 위 변수들 전달 (Windows 전용) | `COLORFGBG` 추가 |

**`COLORFGBG` 는 표준 환경변수**로 vim 의 `:set background?` 가 자동 결정하는 근거. tmux / less 도 비슷. 우리 theme 의 background 가 dark 인지 light 인지 OS API query 가 아니라 **theme.background 의 luminance 로 직접 판별**해요 — `themes.isDark(theme: *const Theme) bool` (cross-platform helper, Rec. BT.601 weights 299/587/114, `lum < 128_000` dark).

**구현 위치:**
- 양쪽 공통: [`src/themes.zig`](src/themes.zig) `isDark()` — luminance 계산.
- Windows: [`src/terminal_backend.zig`](src/terminal_backend.zig) `envVarsForTheme` 가 ConPty 생성 시 `extra_env` 로 전달.
- macOS: [`src/macos_host.zig`](src/macos_host.zig) `g_extra_env` 에 추가, PTY 생성 시 `extra_env` 로 전달.

**새 platform 포팅 시 체크리스트:**
- TUI 가 dark BG 인식하는지 확인 — `echo $COLORFGBG` 출력 / `vim` 띄워서 colorscheme 자동 적용 여부.
- 안 되면 `themes.isDark` 로 PTY env 에 `COLORFGBG` 추가.

# 메시지 언어

**내부 협업 기록은 한국어**로 작성해요. 커밋 메시지, GitHub 이슈 / 이슈 코멘트 / PR, 에이전트와의 대화가 여기에 해당해요. 유지 보수 문맥이 한국어로 쌓여야 작업 기억의 효율이 좋아요.

**외부에 공개되는 텍스트는 영어**로 작성해요. 다음이 여기에 해당해요.

- `README.md`, `SECURITY.md` 등 저장소 최상단 문서
- `docs/` 의 GitHub Pages 사이트
- **릴리즈 노트 (`dist/release-notes/*.md`)** — end-user 가 GitHub Release 페이지에서 직접 봄. 이전 v0.2.13 까지 한국어였지만 앞으로 영어.
- 프로그램 안에서 사용자에게 직접 표시되는 메시지 (MessageBox, 오류 다이얼로그, About 다이얼로그 등 최종 사용자가 앱 안에서 보는 텍스트)

공개 레포의 정문과 앱 UI 는 국제 방문자가 바로 읽을 수 있는 언어 (= 영어) 에 맞추는 게 기본값이고, 내부 기록은 한국어로 남겨서 두 역할을 분리해요.

# macOS Cocoa quirks (시연 중 발견 + 해결 패턴)

향후 macOS 작업 시 재참고용. 모두 macOS 표준 동작이지만 직관과 다르거나 안내가 부족한 케이스.

1. **NSApplication.terminate: 가 defer 안 거침.** Cmd+Q (NSApp `terminate:`) 가 `exit()` 직행 → main 의 `defer` 안 불림. 해결: POSIX `atexit()` hook 등록 (`macos_host.zig` 의 `atExitLogStop` 패턴).

2. **영어 key repeat 안 됨 (한글 자모는 정상).** macOS "Press and Hold" 가 영어 키 길게 누름 → accent picker (à á â) 띄우려 repeat 막음. 한글은 IME 경로라 영향 없어 비대칭. 해결: `ApplePressAndHoldEnabled = false` 를 우리 앱 NSUserDefaults 에 register (ghostty / iTerm2 / Alacritty 동일).

3. **한글 IME 조합 중 Ctrl+key 처리.** ctrl modifier 검사를 IME 조합 여부와 무관하게 항상 검사. 조합 중이면 (1) `[inputContext discardMarkedText]` (2) 우리 `g_marked_len = 0 + g_preedit_len = 0` (overlay 비움) (3) PTY 로 \x03 직송. shell 의 "입력 라인 버리기" 의도와 일관.

4. **NSAlert modal 안에서 Cmd+C 가 NSTextField/NSTextView 에 라우팅 안 됨.** NSAlert.runModal 시 default 버튼 (OK) 이 firstResponder 로 강제 고정. 본문은 `accessoryView` 의 NSTextView (selectable, monospace) 로 표시 + delegate 의 `textViewDidChangeSelection:` 에서 selection 변경 시 즉시 NSPasteboard 복사. 우리 터미널 selection finish auto-copy (#122) 와 같은 패턴.

5. **ghostty `selectWord` 가 wide char (한/中/日) 음절마다 끊음.** wide char 의 `spacer_tail` cell (글자의 right-half) 을 boundary 로 취급 → 음절 사이 클릭 시 null, 음절 위 클릭 시 음절 하나만. 해결: `terminal_interaction.selectWord` 직접 구현. 클릭이 spacer_tail 이면 wide cell (x-1) 정규화 + 확장 중 spacer_tail 만나면 boundary 검사 *skip*. 보너스: 시작이 boundary (공백/구두점) 면 false 반환 — iTerm2 / Terminal.app 동등.

6. **`~/Library/LaunchAgents` root 소유 환경 (회사 노트북).** pulsesecure (회사 VPN) 같은 패키지가 root 권한으로 디렉토리 만들어 사용자 owner 빼앗음. LaunchAgent plist 작성 실패 (`AccessDenied`) — graceful fail 로 앱은 정상. 복구: `sudo chown -R $(whoami):staff ~/Library/LaunchAgents` (회사 plist owner 도 같이 바뀌니 신중).

# 도구 실행

**모든 도구 호출에 timeout 은 1분 (60000ms) 을 명시적으로 걸어요.** Bash, PowerShell, Agent 같은 도구의 기본 timeout (2~10 분) 에 의존하지 말고 매 호출마다 `timeout: 60000` 을 직접 넣어요. 사용자가 1 분 넘게 아무 응답도 받지 못하는 상황을 피하기 위한 규칙.

**작업이 1 분 안에 끝나지 않는 게 자연스러운 경우 (예: `zig build` 에서 ghostty 첫 컴파일, 대량 다운로드)** 는 `run_in_background: true` 로 백그라운드에 던지고, 짧은 주기 (1 분 이하) 로 상태를 확인하거나 완료 알림을 기다려요. 단일 blocking 호출로 오래 기다리지 않아요.

이 규칙은 쉘 호출뿐 아니라 Agent / WebFetch / TaskOutput 같은 다른 모든 도구에도 적용해요.

# 실행 환경

Windows 환경에서 작업 중이면 **모든 명령은 WSL에서 실행하는 것을 먼저 고려**해요.
`git`, `gh`, 파일 조작 등은 `.gitconfig`, SSH 키, 기타 설정이 WSL 쪽에 있는 경우가 많아서 Windows 셸에서 직접 실행하면 인증이나 환경 차이로 불안한 문제가 생길 수 있어요.

예외: `tildaz.exe` 자체는 **Windows 프로그램**이므로 빌드와 실행은 Windows 쪽에서 해야 해요.
`zig build`는 Windows 셸에서 실행하되, 소스는 UNC 경로(`\\wsl$\Debian\...`)로 접근하고 캐시는 `C:/ziglang/tildaz-cache` 같은 Windows 로컬 경로를 사용해요.

WSL 파일을 Windows 경로로 접근해야 할 때는 반드시 `\\wsl$\Debian\...` 형식을 사용해요. `\\wsl.localhost\Debian\...`는 사용하지 않아요.

# 릴리즈

릴리즈 바이너리는 **반드시 GitHub Actions를 통해 생성**해요.
로컬에서 만든 zip은 업로드하지 않아요.
`v*` 태그 push가 `.github/workflows/release.yml`을 트리거해서 `windows-2022` 러너에서 빌드하고 서명 가능한 아티팩트와 SHA256을 만들고 GitHub Release까지 한 번에 처리해요.

순서는 아래와 같아요.

1. `build.zig`의 `tildaz_version`과 `src/tildaz.rc`의 VERSIONINFO를 새 버전으로 올려요.
2. `dist/release-notes/vX.Y.Z.md`를 작성해요.
3. 커밋하고 `git push origin main` 해요.
4. `git tag vX.Y.Z && git push origin vX.Y.Z`로 Actions를 트리거해요.
5. Actions가 초록불이면 GitHub Release가 자동 생성돼요.

# 의존성 관리

`build.zig.zon`의 의존성은 **반드시 고정된 commit SHA URL로 pin**해요.

형식은 아래처럼 40자리 commit SHA tarball URL만 사용해요.

`https://github.com/<org>/<repo>/archive/<40-hex-sha>.tar.gz`

`refs/heads/main.tar.gz` 같은 rolling 레퍼런스는 사용하지 않아요.
upstream이 움직이면 CI의 `zig build --fetch`가 캐시 불일치로 실패할 수 있어요.
`.github/workflows/release.yml`에는 rolling URL을 막는 sanity check가 있으니, 실수로 되돌리면 바로 빌드가 깨질 수 있어요.

ghostty 의존성을 갱신하려면 `dist/update-ghostty.sh`를 실행해서 upstream `main` HEAD sha 기준으로 URL과 hash를 함께 업데이트해요.
