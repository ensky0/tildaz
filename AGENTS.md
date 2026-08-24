# 메시지 언어 — 이 문서에서 **가장 중요한 규칙**

아래 다른 모든 섹션보다 먼저 지켜요. 사용자가 2026-08-02 에 "모든 출력은 한국어로 한다.
반드시 기억하고 … 꼭 가장 중요한 거라고 제일 앞에 적어줘" 라고 명시해, 문서 뒤쪽에 있던
`# 메시지 언어` 섹션을 최상단으로 올렸어요 (내용 변경 없이 위치만 이동 — 같은 규칙을 두
군데 두면 한쪽만 갱신되니까).

**에이전트의 모든 출력은 한국어예요.** 답변, 설명, 질문, 진행 보고, 계획, 요약, 도구 호출의
`description` 필드, 작업 중간 보고까지 사용자 눈에 닿는 모든 텍스트가 예외 없이 한국어예요.
"짧은 확인이라서" / "기술 내용이라서" / "영어가 더 정확해서" 는 예외 사유가 아니에요.

**사용자와의 모든 대화는 항상 한국어로 해요.** 식별자 / 코드 / 명령어 / 외부 고유명사처럼 한국어로 옮기면 의미가 흐려지는 토큰만 영어로 두고, 일반 명사·동사는 한국어로 써요.

**내부 협업 기록은 한국어**로 작성해요. 커밋 메시지, GitHub 이슈 / 이슈 코멘트 / PR, 에이전트와의 대화가 여기에 해당해요. 유지 보수 문맥이 한국어로 쌓여야 작업 기억의 효율이 좋아요.

**외부에 공개되는 텍스트는 영어**로 작성해요. 다음이 여기에 해당해요.

- `README.md`, `SECURITY.md` 등 저장소 최상단 문서
- `docs/` 의 GitHub Pages 사이트
- **릴리즈 노트 (`dist/release-notes/*.md`)** — end-user 가 GitHub Release 페이지에서 직접 봄. 이전 v0.2.13 까지 한국어였지만 앞으로 영어.
- 프로그램 안에서 사용자에게 직접 표시되는 메시지 (MessageBox, 오류 다이얼로그, About 다이얼로그 등 최종 사용자가 앱 안에서 보는 텍스트)
- **로그 파일 (`tildaz_N.log`) 의 모든 메시지** — format string 과 **그 인자까지** 영어예요. 사용자가 이슈에 붙여 공유하는 진단 자료라서요. 로그 옆의 *주석*은 내부 기록이니 계속 한국어예요. (2026-08-03 에 이 규칙이 문서에 없어서 새 `[cwd]` 로그를 한국어로 적었고, 사용자 지적으로 점검하니 기존 코드 29곳도 한국어였어요 — 전부 영어로 고쳤어요.)

공개 레포의 정문과 앱 UI 는 국제 방문자가 바로 읽을 수 있는 언어 (= 영어) 에 맞추는 게 기본값이고, 내부 기록은 한국어로 남겨서 두 역할을 분리해요. **이 구분은 "출력은 한국어" 규칙의 예외가 아니라 대상이 달라서예요** — 사용자에게 하는 말은 한국어, 저장소 방문자 / end-user 가 읽는 산출물은 영어.

# 워크플로우

모든 작업은 아래 순서로 진행해요.

1. **이슈 확인**: 관련 이슈가 이미 있는지 확인하고, 없으면 새로 생성해요.
2. **계획 기록**: 이슈에 구체적인 구현 계획을 먼저 댓글로 기록해요.
3. **작업 수행**: 작업하면서 중간 결과, 결정 사항, 변경 이유 등을 계속 이슈에 댓글로 기록해요.
4. **검증**: 빌드와 테스트를 직접 실행해서 작업 내용이 올바른지 확인해요.
5. **완료**: 검증이 끝나면 커밋해요. (릴리즈는 별도 타이밍 — 여러 작업을 모아 새 버전으로 내요.)
6. **이슈 닫기**: 릴리즈가 아니라 **검증이 끝나 해결되면 바로** 이슈를 닫아요. 릴리즈 여부는 닫기를 막지 않아요.

**코드 변경이 문서 서술을 바꾸면 같은 PR 에 담아요** (2026-08-10 사용자 지적: *"이미 pr만들어서 머지했는데 이제야 고치면 어떡해? 앞으로는 꼭 문서까지 다 고쳐서 pr해"*). 코드만 먼저 머지하고 `SPEC.md` / `AGENTS.md` / `CONFIG.md` 를 나중에 올리면, 그 사이 문서가 사실과 어긋난 채 main 에 남아요. PR 을 올리기 전에 **바꾼 동작을 서술한 문서가 있는지 grep 으로 먼저 확인**해요 (#442 에서 SPEC.md 두 줄과 AGENTS.md 를 놓쳤어요).

**문서만 바뀌는 변경은 PR 없이 main 에 바로 push 해요** (2026-08-10 사용자 지시: *"이런건 그냥 main에 바로 넣어"*). 위의 "같은 PR 에 담아요" 와 충돌하지 않아요 — 코드와 함께 가는 문서는 그 PR 에, 문서만 있는 변경은 main 직행이에요.

**PR 을 올리기 전에 `main` 을 rebase 해요** (2026-08-24 사용자 지시). 브랜치를 딴 뒤에 main 이 움직이면 우리가 돌린 검증은 *그 시점의 main* 기준이라, 그대로 머지하면 텍스트 충돌이 없어도 동작이 깨질 수 있어요 (semantic conflict). 하루에 여러 PR 이 머지되는 저장소라 base 는 거의 항상 움직여 있어요.

```sh
git fetch origin
git rebase origin/main
```

- **rebase 뒤에 검증을 다시 돌려요.** rebase 전에 통과한 `zig build check` / `zig build test` 는 base 가 바뀐 순간 무효예요. 충돌 없이 조용히 rebase 되면 "이미 통과했다" 고 착각하기 쉬운데, 그러면 rebase 가 만든 어긋남을 CI 가 처음 발견해요.
- **merge 가 아니라 rebase 예요.** PR 브랜치에 main 을 merge 하면 무관한 merge commit 이 섞여 리뷰가 흐려져요. merge commit 은 GitHub 이 PR 을 머지할 때 하나만 생기는 게 맞아요.
- rebase 뒤 force push 는 자유롭게 해요 — 아래 `# 커밋 메시지` 의 규칙과 같아요 (검증이 끝난 뒤에).
- 충돌이 문서 (`SPEC.md` · `AGENTS.md` · `CONFIG.md`) 에서 나면 *양쪽 서술을 다시 읽고* 합쳐요. 한쪽을 통째로 고르면 다른 PR 이 쓴 사실이 조용히 사라져요.
- **공유 브랜치를 rebase 할 때는 원격 tip 을 base 로 삼아요.** 여러 머신 · 여러 세션이 같은 브랜치에 올리므로, 내 로컬이 뒤처진 상태에서 rebase 해 force push 하면 **원격에만 있던 남의 커밋이 조용히 사라져요.** `--force-with-lease` 로도 막히지 않아요 — fetch 를 한 뒤 *자기 옛 로컬*을 rebase 하면 lease 검사는 통과해요.

    ```sh
    git fetch origin
    git rebase origin/<브랜치>                 # ① 원격 tip 을 먼저 따라잡고
    git rebase origin/main                     # ② 그다음 main 위로
    git log --oneline origin/<브랜치>..HEAD    # ③ push 전 — 떨어진 커밋이 없는지 확인
    ```

    2026-08-24 [#502](https://github.com/ensky0/tildaz/issues/502) 에서 실제로 겪었어요. 한 세션의 로컬이 한 커밋 뒤처진 상태에서 rebase 해 force push 하는 바람에 원격에 있던 문서 커밋 하나가 사라졌어요. 추적은 `git reflog show origin/<브랜치>` 의 `forced-update` 항목으로 했어요 — 그 줄 앞뒤의 커밋 수를 비교하면 무엇이 떨어졌는지 바로 보여요.

# 문서화

문서는 항상 확인된 내용만 정확하게 작성해요.
추정, 가설, 미확인 내용은 사실처럼 쓰지 말고 `추정`, `가설`, `확인 필요`처럼 상태를 명시해요.
문서화할 때는 가능한 한 **출처 링크를 함께 남겨요**.
특히 GitHub 이슈, 이슈 코멘트, 릴리즈 노트, 작업 기록 문서에는 사실 판단의 근거가 되는 공식 문서, 이슈, 코드, 커밋, 로그 등의 링크를 포함해요.
이 원칙은 GitHub 이슈, 이슈 코멘트, 릴리즈 노트, 작업 기록 문서에 모두 동일하게 적용해요.

**작업 기록은 GitHub 이슈에 남겨요.** 해결한 내용 / 해결 과정 / 버그 추적 같은 **작업 기록은 공유 문서가 아니라 관련 GitHub 이슈에 기록**해요 (워크플로우 ②③). 미해결 버그 / 새 항목은 **새 이슈를 만들어** 거기에 기록해요. `SPEC.md` (cross-platform 동작 사양) 와 `ARCHITECTURE.md` (구조 / 근거) 는 *durable* 한 사양 / 결정만 담는 곳이지 작업 기록 자리가 아니에요. (리눅스 구현 계획 임시 문서였던 `LINUX.md` 는 Wayland 백엔드가 v0.5.0 으로 출시되면서 삭제됐고, durable 내용은 `SPEC.md` §1.2 / `ARCHITECTURE.md` 로 이관됐어요.)

**에이전트 memory 기능은 쓰지 않아요.** 사용자는 여러 머신을 오가며 작업하는데 (아래 `# 실행 환경`
의 머신 목록), memory 는 **기록한 그 머신에만** 남아서 *한쪽에서만 보이는 사실*을 만들어요 — 다른
머신으로 옮기거나 같은 노트북을 다른 OS 로 부팅하면 없는 것과 같아요. 남길 가치가 있는 내용은
**관련 GitHub 이슈 댓글**에 적어요. 어느 머신에서든 같이 보이고, 바로 위의 "작업 기록은 GitHub
이슈에" 와 같은 방향이에요. (2026-08-05 사용자 지적 — 세션마다 반복돼서 문서에 적어요.)

**용어 — Wayland `advertise` 를 "광고 / 미광고" 로 옮기지 않아요.** compositor 가 `wl_registry.global` 로 client 에게 지원 protocol 을 알리는 행위 (*advertise*) 를 "광고" 로 직역하면 한국어로 의미가 안 통해요 (사용자 두 번 지적). 대신 "client 에게 노출 (*advertise*)", "지원 통보가 온다 / 안 온다", "`wl_registry.global` 로 알린다", 또는 영어 *advertised* / *not advertised* 를 그대로 써요. "이 capability 는 compositor 에 없음" 처럼 풀어 써도 좋아요. 이슈 / 답변 / 공유 문서 / 코드 주석 / 커밋 메시지 모두 적용.

**고유명사는 항상 공식 표기 — 대소문자까지 정확히.** 제품 / OS / 데스크톱 / API 이름은 각자의 공식 표기를 그대로 따라요 (사용자 지적). 표기는 이름마다 규칙이 달라요:
- 전부 소문자: `sway`, `i3` (문장 첫머리에서도 소문자가 공식)
- 전부 대문자: `GNOME`, `COSMIC`, `GTK`
- 혼합: `macOS`, `KDE Plasma`, `Cinnamon`, `Hyprland`, `Wayland`, `Metal`, `Direct3D`, `ConPTY`, `GitHub`, `AppImage`, `Electron`, `Qt`, `Windows`, `Linux`
- **예외 — URL · 파일경로 · 파일명 · 코드 식별자는 리터럴 그대로** 둬요 (`github.com`, `src/host/macos.zig`, `conpty.dll`). 이건 산문 속 고유명사가 아니라 실제 문자열이라 교정 대상이 아니에요.
README / 사이트 / SPEC / 이슈 / 답변 / 커밋 / 코드 주석 모두 적용. 확신이 없으면 공식 사이트 표기를 확인하고 써요.

**플랫폼 나열 순서는 항상 `Linux · macOS · Windows`.** 사용자 노출 산문 (README / 사이트 / 마케팅 문구 / 릴리스 소개) 에서 세 플랫폼을 나열할 땐 이 순서를 지켜요 (사용자 지적). 기술 설명 문장이라도 의미를 지키며 Linux 를 먼저 두도록 재배열해요 (예: "a direct Wayland client on Linux, GPU rendering on macOS and Windows"). 사이트의 플랫폼 카드 / 탭 / eyebrow 등 시각 요소도 같은 순서.
- **예외** — SPEC.md 표의 컬럼 순서, ARCHITECTURE 의 코드 경로 나열, 이미 배포된 과거 릴리스 노트, "Windows reference" 처럼 특정 구현이 기준이라는 의미가 고정된 표현은 건드리지 않아요 (사실이 바뀌므로). 단 *동작·시각 parity 의 기준으로서의* "Windows reference" 는 2026-07-12 폐기됨(#297) — 새 산문에서 Windows 를 기준으로 서술하지 않아요.

**Linux 데스크톱 나열 순서는 `KDE Plasma, GNOME, Cinnamon, COSMIC, Hyprland, sway`.** "풀 데스크톱(KDE Plasma / GNOME / Cinnamon / COSMIC) → 타일링 WM(Hyprland / sway)" 묶음 안에서 각각 사용자 수 많은 순. 마케팅 문구의 DE 목록은 이 순서로 통일해요. (검증 하드웨어 목록처럼 테스트 순서를 반영하는 기술 노트는 예외.)

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
- **Windows**: `WM_IME_STARTCOMPOSITION` / `WM_IME_COMPOSITION` /
  `WM_IME_ENDCOMPOSITION` + IMM. `GCS_COMPSTR` 를 UTF-8 preedit buffer 로 받아
  Direct3D renderer 가 terminal cursor 옆에 inline overlay 로
  그려요. `GCS_RESULTSTR` 는 message 안에서 원래 terminal 대상에 동기 전달하고
  그 message 를 소비해 뒤따르는 `WM_CHAR` 중복을 막아요.
  상태를 바꾸는 shortcut / paste (#340) / F1 / Alt+Enter /
  Alt+F4 전에는
  `ImmNotifyIME(CPS_COMPLETE)` 로 결과를 먼저 정확히 한 번 반영하고, Ctrl+C 는
  `CPS_CANCEL` 뒤 ETX(`\x03`)를 정확히 한 번 보내요.
  MS-IME가 Ctrl shortcut보다 먼저
  `GCS_RESULTSTR`를 보내도 결과를 보류한 뒤, 유지 정책이면
  `ImmSetCompositionStringW(SCS_SETSTR)`로 실제 IMM composition을 복원해요.
  한자 / kanji / hanzi 변환 후보 목록은 OS IME popup 을 그대로 쓰고
  `ImmSetCompositionWindow` 로 cursor 위치만 알려요.

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
- **변경 전 정확 분석 후 적용**. "일단 해보고 시연으로 확인" 절대 금지.
  시연은 검증 단계지 가설 발견 단계가 아니에요. 변경할 코드의 입력 / 출력 /
  경계 케이스 (정확 경계, 부동소수점 오차, max/min) 모두 분석해서 동작이
  머리에 그려진 뒤에 patch 하세요. 머리에 안 그려지면 사용자에게 정확한
  의문 (변수 값, 시나리오) 을 묻거나 디버그 정보 (log) 를 추가해 좁히세요.
  시연 결과가 분석과 어긋나면 다른 가설로 점프 X — 분석을 다시 검토해서
  어디서 어긋났는지 식별하고 보강 후 재 patch.
- **가설 fix 가 cause 아니면 즉시 원복.** 진단 사이클에서 가설로 시도한 변경
  (의심 비트 OR, termios 명시 set, trace log 등) 이 시연으로 cause 아니라고
  확정되면 그 변경만 *즉시 원복*해요. 다른 fix 와 mix 해 한 commit 으로 묶지
  않아요 — noise commit 은 review 를 가리고 다음 진단에 hack 을 누적시켜요.
- **cause 확정 전 commit 금지.** 진단 중 working tree 변경은 cause 확정까지
  commit 만들지 않아요. 이미 진단 commit 이 있으면 `git commit --amend` 로
  덮어쓰고 새 commit 을 쌓지 않아요. 진단 노트는 commit body 가 아니라 이슈
  댓글 / 정식 fix 의 reasoning 에 남겨요.

# 버그 / 미동작 발견 시 — 영향 범위를 소스 레벨에서 확인

버그나 미동작을 발견하면 *발견한 환경에서만 보고 끝내지 않는다*. 같은 원인이
다른 Linux DE / compositor (KWin / mutter / wlroots 계열 등), 다른 platform
(Windows / macOS / Linux), 다른 OS 버전에서도 나타날 수 있는지 **반드시
소스 레벨에서 확인**한다. "내 환경에서 재현 안 되니 무관" 식 추정 금지 —
재현 안 되는 환경이라도 *코드 경로를 읽어* 영향 여부를 판정한다.

- **공유 경로면 전 환경 잠재.** 원인이 cross-platform 모듈 / 공통 helper 에
  있으면 다른 platform / DE 에서도 잠재한다. host-specific 경로면 그 host 에서만.
  *어느 쪽인지 코드로 판별*하고 결론 (영향 받는 환경 / 안 받는 환경) 을 이슈
  본문과 커밋 메시지에 명시한다.
- **재현 불가 환경의 판정도 코드로.** 예: 한 DE 에서 dialog 가 안 떠도 그게
  "그 경로를 아예 안 타서" (예: layer-shell 을 advertise 안 함 → `createDialogSurface`
  early return) 인지, "다른 진입점으로 같은 버그가 그대로 사는지" 를 소스로 구분한다.
- **parity 가 깨지는 것 자체가 버그다.** SPEC §0 #1 (세 platform 동등 목표).
  단 맞출 기준은 Windows 로 자동 고정하지 않는다 — 명시 사양이 있으면 그 사양,
  없으면 항목별 UX 방향 결정 (2026-07-12, #297; 과거 "Windows reference" 폐기).
  추가로 *Linux 는 모든 DE 에서 drop-down (quake) 동작이
  목표* — 한 DE / 한 compositor 에서만 되는 기능, 한 platform 에만 있는 동작,
  한 환경에서만 나는 crash 는 모두 이슈로 추적하고 *다른 환경 영향 여부를
  함께 적는다*.

# 의사결정 — 방향은 사용자와 함께 정해요

버그 fix 방향, 스코프 확대 / 축소, 새 작업 착수, 이슈를 몇 개로 나눌지, 우선순위,
SPEC 변경 등 *"방향"* 에 해당하는 결정은 단독으로 정하고 진행하지 않아요. 반드시
사용자와 상의해서 함께 결정해요. 사실 확인 / 소스 분석 / 진단은 자유롭게 하되,
결정 지점에서는 옵션을 제시하고 사용자 선택을 기다려요.

**외부에 공개되는 댓글은 올리기 전에 반드시 확인받아요 — 새 댓글이든 정정이든.**
GitHub 이슈 / PR 의 외부 기여자 대상 답변, 그리고 **이미 올린 댓글의 수정**까지
전부 해당해요. 초안을 보여 주고 사용자 승인을 받은 뒤에 올려요 (2026-08-22 사용자
지시). 내부 기술 기록도 같은 이슈에 올라가 외부에 보이니 함께 적용해요.

이유는 두 가지예요. (1) 그 텍스트는 **사용자 이름으로 나가는 목소리**이고 신고자와의
관계에 영향을 줘요. (2) 잘못 올린 것을 되돌리는 방법 자체가 판단이에요 — 앞선 답변에
틀린 사실을 적었을 때 **새 댓글로 정정하지 말고 원 댓글을 수정**하는 편이 나은 경우가
많아요. 틀린 문장이 스레드에 남지 않고, 신고자가 읽지도 않았을 주장의 정정문을 읽을
필요가 없어요.

2026-08-22 #484 에서 실제로 틀렸어요: 답변에 사실과 다른 주장을 적고, 나중에 그것을
**새 댓글로** 정정했어요. "정정은 당연히 좋은 일" 로 단정해서 결정 사항으로 인식조차
못 했고, 올린 *뒤에* "톤이 괜찮은지" 를 물었어요 — 물어야 했던 건 올리기 *전에*
"어떻게 정정할지" 였어요. 결과적으로 틀린 문장과 그 정정문이 둘 다 스레드에 남았고,
원 댓글 4 개를 다시 수정해 정리했어요.

**댓글을 수정하면 그 텍스트를 인용 / 전제하는 다른 댓글까지 전수 확인해요.** 한 곳을
고치면 그것을 가리키는 다른 글이 붕 떠요. 스레드는 순서대로 읽히니까 **한 댓글만 정확한
것으로는 부족**하고, 전체가 앞뒤로 맞아야 해요. 수정 뒤에는 반드시 스레드를 처음부터
다시 훑어요.

같은 댓글 *안*도 대상이에요 — 본문을 고치고 요약 줄 / 결론 / "앞으로 할 일" 목록을
그대로 두면 한 댓글이 스스로 모순돼요. 특히 이런 것들을 확인해요:

- **약속 / 앞으로 할 일** — 하지 않기로 정한 것이 여전히 약속으로 남아 있는지
- **범위 서술** ("이번 범위 밖", "별도 작업") — 도중에 스코프가 움직였는지
- **다른 글의 인용** — 인용된 원문이 아직 그 자리에 있는지 (정정을 지웠으면 그것을
  정정하던 글도 붕 떠요)
- **항목 번호 참조** ("수정 방향 4") — 그 번호의 내용이 바뀌었는지

2026-08-22 #484 에서 이 실수를 두 번 했어요. 틀린 문장을 고치면서 **같은 댓글 안의 요약
줄**에 남은 "widen the supported hotkeys" (하지 않기로 한 것) 를 놓쳤고, 다른 댓글을
고치면서 **그것을 인용하는 두 댓글**을 확인하지 않았어요. 둘 다 사용자가 "흐름이 이상한
점은 없어?" 라고 물어서야 발견됐어요. 계획이 도중에 바뀐 경우는 조용히 덮어쓰지 말고
**왜 움직였는지**를 남겨요.

**의견 질문 ≠ 작업 지시.** "~할까? 네 생각은 어때?" 는 의견 요청이에요 — 의견만
답하고 사용자 결정을 기다려요. 동의한다고 바로 구현하지 않아요 (2026-07-08 #268
×/+ 순서 스왑에서 지적).

**사용자 질문 답변이 최우선.** 작업 중 질문이 오면 진행 중인 tool 호출을 이어가기
전에 답부터 해요 — 답변을 tool 작업 뒤로 미루지 않아요 (2026-07-08 사용자 명시:
"내 질문에 답하는 게 가장 최우선이야. 항상 기억해").

**시각 / 인지 개선 아이디어는 요청 없어도 먼저 제안해요** (2026-07-27 사용자 명시:
"인지적으로 더 예쁘게 만들 수 있는 방법 있으면 언제든 제안해 줘"). 위의 "방향은
단독으로 정하지 않는다" 와 충돌하지 않아요 — *제안*은 자유롭게 하되 *적용*은 사용자
결정을 기다린다는 뜻이에요. 작업 중 눈에 걸리는 UI 가 있으면 지시받은 범위가
아니어도 짧게 옵션을 제시해요. 같은 맥락에서 사용자가 "예쁘지 않다" 고 언급한
지점은 이슈로 남겨 추적해요.

**진행 계획 / 진행 상황을 한국어로 계속 중간 보고해요.** 단계에 들어가기 전
"지금부터 뭘 왜 하는지", 끝나면 "뭘 확인했고 다음은 뭔지" 를 짧게 보고하고,
조용히 tool 호출만 이어가지 않아요 — **잘못된 방향으로 가면 사용자가 얼른
중지시킬 수 있도록** 하기 위함이에요 (2026-07-08 / 2026-07-10 / 2026-07-13
사용자 명시, 세 번째는 새 세션이 조용히 작업만 이어가다 재지적받음).
특히 방향 전환 (가설 기각, 새 접근) 시점은 반드시 보고해요.

# 렌더링 — 화면 scale 을 처음부터 항상 고려

그리는 작업 (탭바 / 폰트 / cell / scrollbar / padding / 다이얼로그 / 새 UI 요소 등) 을
구현할 때는 **처음부터 항상 화면 scale 을 고려**해요. 크기 상수는 물리 픽셀이 아니라
**logical point (pt)** 로 정의하고, 그릴 때 `pt → px` 변환에 현재 화면 scale 을 곱해요.
"일단 1.0x 로 그리고 나중에 scale 붙이기" 는 금지 — scale 누락은 한 환경 (특히 fractional
배율 / HiDPI) 에서만 작게 / 흐리게 나와 뒤늦게 발견돼요 (#238: GNOME 에서 scale source
누락으로 탭바·폰트가 1.0x 로 작게 — "탭바만 따로" 가 아니라 *scale 을 곱하는 모든 요소* 의
공통 갭이었음).

scale source 는 platform 마다 다르지만 **단일 `scale` 값으로 수렴**시켜 모든 그리기가 그걸
곱하게 해요 (한 곳만 맞으면 전부 일관):

| platform | scale source |
|---|---|
| macOS | `backingScaleFactor` |
| Linux / KDE Plasma (KWin) | `wp_fractional_scale_v1` 의 `preferred_scale` (예 204/120 = 1.7x) |
| Linux / GNOME (mutter) · fractional 미advertise | `wl_output` 정수 scale (event opcode 3) 로 fallback |

- 공통 상수: `src/ui_metrics.zig` (예 `TAB_BAR_HEIGHT_PT`) — platform 별로 다시 정의하지 않아요.
- Linux 변환: `software_terminal.zig` 의 `self.scale` (단일 값). 새 scale source 가 생기면 이
  값 하나로 수렴시키고 `renderer.applyScale()` 로 폰트·탭바·전체 chrome 을 동기 반영해요.
- 새 platform / compositor 포팅 시 **scale source 부터** 확인 — 배율 켜고 다른 환경 (mac / KDE)
  과 나란히 띄워 같은 크기로 보이는지 시연으로 검증해요.

# 크로스 플랫폼 코드 스타일 — single definition 우선

OS-specific 값이 모두 같은 shape (같은 field set 의 struct, 같은 enum, 같은 const
set) 이면 **single definition + 항목별 `if/else` 인라인** 을 먼저 시도해요. Windows /
macOS / Linux 각각 sub-struct 로 쪼개는 안은 마지막 옵션이에요. 같은 shape 분리는
(1) 코드 양이 늘고 (2) 항목 추가 시 N 곳 수정 (3) 공통 값 일관성을 컴파일러가 보장
못 해요. 진짜로 method / type 자체가 OS 별로 다를 때만 그 부분을 분리해요. 적용 예:
`config.zig` 의 `Defaults`.

# 커밋 메시지

`Co-Authored-By` 트레일러 (Claude / AI tool 등) 는 **절대 넣지 않아요**.
사람이 직접 작성한 것처럼 보여야 하는 게 아니라, 단순히 저장소 운영 정책으로
모든 commit author 는 사람으로 통일해요. 도구 사용 사실은 코드 / 이슈 본문
/ 댓글 등 다른 곳에 충분히 남아 있어요.

**amend 할지 새 커밋을 쌓을지** (2026-08-03 사용자 지시):

- **amend** — 기존 커밋에 **문제가 있었거나**, **방향이 바뀌어 그 커밋의 코드 / 메시지가
  쓸모없어진** 경우. 후자의 대표적인 예는 커밋 메시지에 적어 둔 설계 근거의 전제가
  뒤집혀서, 그대로 두면 메시지가 사실과 어긋난 채 남는 때예요.
- **새 커밋** — 그 밖의 전부. 기존 커밋이 그대로 유효하고 그 위에 작업이 쌓이는 경우예요.

amend 와 force push 는 (main 포함) 자유롭게 해요. 단 **검증이 끝난 뒤에** 해요 — 빌드 /
테스트 통과만으로 "완료" 로 적지 않는 규칙과 같은 이유예요. 실기 검증을 남에게 부탁하기
위해 **검증용 브랜치**에 올려 두는 커밋은 예외지만, 그 커밋 메시지에는 무엇이 아직
미검증인지 명시해요.

# 사용자 표시 텍스트 / 다이얼로그

앱이 사용자에게 보여주는 모든 텍스트와 다이얼로그는 두 모듈을 반드시 거쳐요.

- **`src/messages.zig`**: 사용자에게 노출되는 모든 텍스트 상수 / format string 의 단일 진입점. 새 메시지가 필요하면 여기 먼저 추가하고 호출처는 이 상수만 import 해요. 같은 의미의 메시지를 platform 별로 두 번 작성하지 않아요.
- **`src/dialog.zig`**: cross-platform 다이얼로그 추상화. `showInfo` / `showError` / `showFatal` / `showConfirm` / `promptHotkey` / `showAboutAlert` 만 호출해요. comptime 으로 `dialog/linux.zig` (host 의 layer-shell overlay — #203, Wayland 연결 전 config fatal은 stderr + log fallback), `dialog/macos.zig` (짧은 본문은 `NSAlert`, overflow 본문은 `NSScrollView`, 일부 경로는 `osascript` fallback), `dialog/windows.zig` (짧은 본문은 `MessageBoxW`/key capture window, overflow 본문은 read-only `EDIT`)가 선택돼요.

**Dialog overflow 정책은 Linux · macOS · Windows 공통**이에요. 먼저 실제 텍스트를 측정해 화면 안에 들어오도록 창을 키우고, 그래도 화면을 넘을 때만 본문에 세로 scroll을 둬요. 제목과 button, prompt의 input/status는 고정해요. About이나 fatal만의 예외가 아니라 info/error/confirm/prompt를 포함한 모든 dialog에 적용해요.

**금지**: `MessageBoxW` / `MessageBoxA` / `NSAlert` / `osascript` 같은 platform 직접 호출. 정책 우회가 한 군데라도 생기면 메시지 변경 / i18n / 톤 통일 모두 해당 호출처를 따로 추적해야 해요. 새 platform 분기가 필요하면 `dialog.zig` 의 `impl` switch 에 추가해요.

패치 실패 / config 검증 / About 등 사용자 안내 dialog 는 모두 같은 경로 (`dialog.zig`) 를 써요. 이번 변경 (`refactor(dialog)` 커밋) 이전엔 host 별로 흩어져 있었지만 이젠 모두 정리됐어요. **단 panic 은 예외** — Windows / macOS 는 `dialog.showError` + exit(1) 이지만 Linux 는 `showPanic` 이 log + `std.debug.defaultPanic` (stderr backtrace + abort) 으로, dialog 를 호출하지 않아요 (panic 시점엔 renderer / wayland state 가 불안정할 수 있어 overlay 대신 표준 abort — 의도된 차이, SPEC §6).

# 터미널 환경변수 (TUI dark/light colorscheme)

자식 셸 process 에 다음 환경변수를 넘겨요. 한쪽 platform 에 빠지면 사용자가 *터미널 cell 색은 같지만 vim 안 텍스트 색이 다르다* 같은 미묘한 차이를 보고할 가능성이 높아요. macOS 포팅 중 실제 발생 (#113 M13.2) — Windows TildaZ 가 매일 보던 vim 색과 macOS 가 달라 보이는 원인이 이 환경변수였음. Windows 는 `COLORFGBG` / `WSLENV` 만 명시 설정 (TERM / locale 은 ConPTY 와 WSL 셸 자체 기본에 위임), macOS / Linux 는 5종 모두 명시.

| 환경변수 | 역할 | 값 결정 |
|---|---|---|
| `TERM` | escape sequence + 256-color 표준 | `xterm-256color` (macOS · Linux 명시. Windows 는 ConPTY 기본) |
| `LANG` | bash readline 의 multi-byte 처리 | macOS `en_US.UTF-8` / Linux `C.UTF-8` (distro 에 en_US 미설치 가능 — setlocale 실패 시 readline 이 single-byte 로 떨어져 한글 paste 깨짐, 사용자 보고로 확정) |
| `LC_CTYPE` | ditto, 일부 셸이 `LANG` 안 봄 | `LANG` 과 동일 값 |
| `COLORFGBG` | vim / less / tmux 가 자동 dark/light colorscheme 선택 | theme.background luminance 로 `"15;0"` (dark) / `"0;15"` (light) — 세 OS 공통 |
| `SHELL` | 자식 셸이 자기 path 를 봐야 하는 경우 (`echo $SHELL`, oh-my-zsh detect 등) | spawn 한 셸 path 와 일치하게 설정 (macOS · Linux. Windows 는 POSIX `$SHELL` 컨벤션 없음) |
| `WSLENV` | WSL 안 process 에 위 변수들 전달 (Windows 전용) | `COLORFGBG` 추가 |

**환경변수 override 정책:** macOS `pty.spawn` 의 environ 머지는 *extra_env 우선 + 같은 key 부모값 skip*. 부모 environ 의 `SHELL=/bin/bash` 가 우리가 spawn 한 zsh 의 자식 환경에 그대로 전달되면 prompt 와 `$SHELL` 이 어긋나는 #118 이슈 회피. POSIX `getenv` 가 first-match 라 extra_env 를 뒤에 두면 부모값이 wins → 명시 키만 부모에서 빼는 패턴.

**`COLORFGBG` 는 표준 환경변수**로 vim 의 `:set background?` 가 자동 결정하는 근거. tmux / less 도 비슷. 우리 theme 의 background 가 dark 인지 light 인지 OS API query 가 아니라 **theme.background 의 luminance 로 직접 판별**해요 — `themes.isDark(theme: *const Theme) bool` (cross-platform helper, Rec. BT.601 weights 299/587/114, `lum < 128_000` dark).

**구현 위치:**
- 세 OS 공통: [`src/themes.zig`](src/themes.zig) `isDark()` — luminance 계산.
- Windows: [`src/host/windows.zig`](src/host/windows.zig) `buildExtraEnv` 가 ConPty 생성 시 `extra_env` 로 전달.
- macOS: [`src/host/macos.zig`](src/host/macos.zig) `g_extra_env` 에 추가, PTY 생성 시 `extra_env` 로 전달.
- Linux: [`src/host/linux/wayland_minimal.zig`](src/host/linux/wayland_minimal.zig) `Client.init` 의 `extra_env_storage` (5-entry), PTY 생성 시 전달.

**새 platform 포팅 시 체크리스트:**
- TUI 가 dark BG 인식하는지 확인 — `echo $COLORFGBG` 출력 / `vim` 띄워서 colorscheme 자동 적용 여부.
- 안 되면 `themes.isDark` 로 PTY env 에 `COLORFGBG` 추가.

# macOS Cocoa quirks (시연 중 발견 + 해결 패턴)

향후 macOS 작업 시 재참고용. 모두 macOS 표준 동작이지만 직관과 다르거나 안내가 부족한 케이스.

1. **NSApplication.terminate: 가 defer 안 거침.** Cmd+Q (NSApp `terminate:`) 가 `exit()` 직행 → main 의 `defer` 안 불림. 해결: POSIX `atexit()` hook 등록 (`host/macos.zig` 의 `atExitLogStop` 패턴).

2. **영어 key repeat 안 됨 (한글 자모는 정상).** macOS "Press and Hold" 가 영어 키 길게 누름 → accent picker (à á â) 띄우려 repeat 막음. 한글은 IME 경로라 영향 없어 비대칭. 해결: `ApplePressAndHoldEnabled = false` 를 우리 앱 NSUserDefaults 에 register (ghostty / iTerm2 / Alacritty 동일).

3. **한글 IME 조합 중 Ctrl+key 처리.** ctrl modifier 검사를 IME 조합 여부와 무관하게 항상 검사. 조합 중이면 (1) `[inputContext discardMarkedText]` (2) 우리 `g_marked_len = 0 + g_preedit_len = 0` (overlay 비움) (3) PTY 로 \x03 직송. shell 의 "입력 라인 버리기" 의도와 일관.

4. **NSAlert modal 안에서 Cmd+C 가 NSTextField/NSTextView 에 라우팅 안 됨.** NSAlert.runModal 시 default 버튼 (OK) 이 firstResponder 로 강제 고정. 본문은 `accessoryView` 의 NSTextView (selectable, monospace) 로 표시 + delegate 의 `textViewDidChangeSelection:` 에서 selection 변경 시 즉시 NSPasteboard 복사. 우리 터미널 selection finish auto-copy (#122) 와 같은 패턴.

5. **ghostty `selectWord` 가 wide char (한/中/日) 음절마다 끊음.** wide char 의 `spacer_tail` cell (글자의 right-half) 을 boundary 로 취급 → 음절 사이 클릭 시 null, 음절 위 클릭 시 음절 하나만. 해결: `terminal_interaction.selectWord` 직접 구현. 클릭이 spacer_tail 이면 wide cell (x-1) 정규화 + 확장 중 spacer_tail 만나면 boundary 검사 *skip*. 보너스: 시작이 boundary (공백/구두점) 면 false 반환 — iTerm2 / Terminal.app 동등.

6. **`~/Library/LaunchAgents` root 소유 환경 (회사 노트북).** pulsesecure (회사 VPN) 같은 패키지가 root 권한으로 디렉토리 만들어 사용자 owner 빼앗음. LaunchAgent plist 작성 실패 (`AccessDenied`) — graceful fail 로 앱은 정상. 복구: `sudo chown -R $(whoami):staff ~/Library/LaunchAgents` (회사 plist owner 도 같이 바뀌니 신중).

7. **launchd job 은 프로세스 하나가 아니라 자원 묶음이에요** ([#442](https://github.com/ensky0/tildaz/issues/442)). plist 가 지목한 프로세스가 그 job 의 본체이고, 본체가 끝나면 launchd 가 job 을 닫으며 **묶음 안의 다른 프로세스까지 정리**해요. 그래서 우리처럼 "낳고 바로 죽는" launcher 를 plist 가 직접 지목하면, launcher 가 `exit(0)` 하는 순간 방금 태어난 worker 가 함께 사라져요. 해결: plist 가 `/usr/bin/open -a <bundle> --args …` 를 지목해 앱을 LaunchServices 의 별개 job (`application.<bundle-id>.…`) 으로 띄워요 — 수동 실행에 이미 `open` 을 쓰는 규칙 (아래 `# 실행 환경`) 과 같은 이유예요.

   자동 시작이 안 될 때 진단 순서:

   ```sh
   launchctl print gui/$(id -u)/com.tildaz.app        # job 이 등록됐는지 · coalition · minimum runtime
   log show --predicate 'process == "launchd"' --start "YYYY-MM-DD HH:MM:SS" --info --debug \
     | grep com.tildaz.app                            # spawn → exit → service inactive → removing child 흐름
   tail -40 ~/Library/Logs/tildaz_0.log               # worker 가 어디까지 갔는지
   ```

   - **앱 로그에 `[boot]` 만 있고 `config loaded` 가 없으면** worker 가 밖에서 끊긴 거예요. 우리 코드가 죽은 게 아니라 job 정리에 끌려간 신호로 먼저 의심해요.
   - `log show --start` 는 **소수점 초를 못 받아요** (`%Y-%m-%d %H:%M:%S%z`). 초 단위로 넣어요.
   - `launchctl kickstart -k` 로 재현할 수 있어요. 단 `minimum runtime = 10` throttle 때문에 재시작이 10초 늦어질 수 있어요 — 실제 로그인에는 없는 지연이니 결론에 넣지 않아요.
   - 로그인 직후 `pending spawn, domain in on-demand-only mode` 로 20~30초 늦게 뜨는 건 **정상**이에요. launchd 가 로그인 세션이 열릴 때까지 기다리는 구간이에요.

# macOS — emoji 입력 테스트 방법

macOS 의 Show Emoji & Symbols (Apple default `Ctrl+Cmd+Space`) 는 tildaz 안에서
cursor 에 anchored 된 popover 로 뜸 — focus loss 자동 dismiss / `Esc` 닫힘 /
emoji 클릭 즉시 입력 (2026-07-13 macOS 26.5.2 + v0.6.1 실기). 과거 "floating
panel + no auto-dismiss" 기록 ([#130](https://github.com/ensky0/tildaz/issues/130))
은 현재 환경에서 재현 안 됨 — 원인 미확정, 이력은 SPEC.md 부록 B 노트 / 현행
동작은 SPEC.md §5.2.

picker 띄우지 않고 스크립트로 emoji 를 입력해 검증하는 방법 (자동화·headless 검증에 여전히 유용):

```sh
echo "🎉 안녕 ABC"                       # source 에 emoji 직접 (다른 앱에서 복사 → 우클릭 paste)
python3 -c "print('🎉 안녕 ABC')"
printf '\xf0\x9f\x8e\x89\n'              # UTF-8 byte 직접 (🎉 = F0 9F 8E 89)
zsh -c "echo \$'\\U0001F389'"            # zsh unicode escape (macOS bash 3.2 미지원)
```

# macOS — 색 실측 방법

macOS 는 Metal layer 내용을 **sRGB 로 보고 디스플레이 색공간으로 변환해** 합성해요 ([#349](https://github.com/ensky0/tildaz/issues/349)). 그래서 `screencapture` 로 찍은 PNG 은 디스플레이 공간 값이고, 디스플레이 프리셋이 wide-gamut (`Apple XDR Display` 등) 이면 **앱이 그린 값과 다르게 읽혀요** — 실측에서 파생색 45개 중 30개가 어긋났고 (1비트 22개 · 2비트 8개), amber (`#F7A41D` → `#EBA842`) 는 37 차이였어요.

**하지 말 것 — 캡처를 사후에 sRGB 로 역변환.** ImageMagick `-profile` 과 `sips --matchTo` 가 결과가 갈려서 신뢰할 수 없어요 ([#335](https://github.com/ensky0/tildaz/issues/335#issuecomment-5113614333) 에서 7건이 1비트씩 어긋나 보였고, 어느 도구도 전부 맞추지 못했어요).

**할 것 — 출력 색공간을 sRGB 로 지정해 캡처.** [`dist/macos/color-capture.m`](dist/macos/color-capture.m) 이 `SCStreamConfiguration.colorSpaceName` 을 sRGB 로 두고 창을 캡처해요. 캡처 파이프라인이 출력 버퍼를 sRGB 로 만들어 주니, 다 찍은 PNG 을 사후에 변환하는 8-bit 왕복이 없어요.

```sh
clang -fobjc-arc -framework Cocoa -framework ScreenCaptureKit \
      -framework ImageIO -framework UniformTypeIdentifiers \
      -o /tmp/color-capture dist/macos/color-capture.m
/tmp/color-capture --list                              # windowID 찾기
/tmp/color-capture --window <id> out.png               # 출력 색공간 = sRGB
magick out.png -format "%[pixel:p{40,40}]\n" info:     # 값 읽기
```

이러면 **디스플레이 프리셋을 바꾸지 않아도** raw 픽셀이 앱이 그린 값이에요 (#349 에서 46색 46/46 일치 확인). 결과 PNG 은 sRGB 로 태깅되니 ImageMagick / sips 로 읽어도 값이 같아요. 프리셋을 `Internet & Web (sRGB)` 로 바꾸는 예전 우회는 더 필요 없어요.

측정 전제 (빠뜨리면 색이 안 나오거나 다른 색을 읽어요):

- **탭바는 탭 2개 이상에서만** 그려져요.
- **테마는 runtime 에 안 바뀌어요** — config 를 고치고 재시작한 뒤 로그의 `[startup] config loaded: theme=…` 로 실제 적용을 확인해요.
- **hover 색은 포인터를 실제로 올려야** 나와요 (`ctrl_hover_bg` = `+` 위, `menu_hover_bg` = 메뉴 항목 위). 자동화로 포인터를 옮길 때 `CGWarpMouseCursorPosition` 만 쓰면 커서 위치만 바뀌고 **이동 이벤트가 없어서 hover 가 안 걸려요** — `kCGEventMouseMoved` 를 함께 보내야 해요.
- **`arrow_disabled` 는 탭바 overflow 를 만들어야** 나와요. 필요한 탭 수는 창 폭에 따라 달라요 — 탭 하나가 `TAB_WIDTH_PT` (150pt) 라서 1512pt 짜리 외장 모니터 창에서는 8개로는 overflow 가 안 생겼어요 (#349 실측). `창 폭 ÷ 150` 보다 넉넉히 만들어요.
- **색이 "있는지" 만 보는 검사는 오탐이 나요.** 밝은 테마에서는 글리프 안티에일리어싱이 `arrow_disabled` (`#828282`) 와 똑같은 회색을 만들어서, 화살표가 없는 2탭 화면에서도 "있음" 으로 읽혔어요 (#349). **해당 요소가 그려지는 영역** (화살표는 컨트롤 왼쪽 24pt × 2) 으로 좁히고, 그 요소가 없는 상태 캡처와 **비교** 해서 판정해요.
- **기대값은 이슈 표를 베끼지 말고** [`chrome_palette.zig`](src/chrome_palette.zig) 의 `derive()` 를 임시 드라이버로 호출해 덤프해요 — ghostty 비의존 모듈이라 `zig run` 으로 단독 실행돼요. 측정이 끝나면 드라이버를 지우고 트리 clean 을 확인해요.
- 화면이 절전으로 꺼져 있거나 잠금 화면이면 캡처가 실패해요 (`캡처 실패` / 창 목록에 `Display 1 Shield`).

Linux 는 software renderer + 프로파일 없는 캡처라 이 절차가 아예 없고, Windows 는 swapchain 이 `DXGI_FORMAT_B8G8R8A8_UNORM` 이라 raw 픽셀이 곧 앱 출력이에요. **macOS 만 이 절차가 필요해요.**

# 터미널 시각 회귀 테스트 (한 줄)

색 emoji / 스킨톤 / ZWJ family / 라틴 / 한글 / block element 까지 한 번에 화면에 띄우는 표준 시연 입력. emoji path / ClearType path / wide char / block element 회귀 다 동시 확인 가능. WT 와 나란히 띄워 비교 시 표준 입력으로 사용.

**bash / zsh** (Linux · macOS · Windows에서 WSL shell을 선택적으로 사용하는 탭):

```sh
echo -e "\n🎉❤️🌈🎨🌞🍎🚀💎✨\n👋🏻👋🏼👋🏽👋🏾👋🏿\n👨‍👩‍👧👨‍👨‍👦‍👦\nABCDEFG abcdefg 0123456789\n한글 ABC 가나다라마바사\n▀▁▂▃▄▅▆▇█▉▊▋▌▍▎▏\n▐░▒▓▔▕\n"
```

**PowerShell** (Windows 호스트 셸 / TildaZ 의 PS 탭):

```powershell
"`n🎉❤️🌈🎨🌞🍎🚀💎✨`n👋🏻👋🏼👋🏽👋🏾👋🏿`n👨‍👩‍👧👨‍👨‍👦‍👦`nABCDEFG abcdefg 0123456789`n한글 ABC 가나다라마바사`n▀▁▂▃▄▅▆▇█▉▊▋▌▍▎▏`n▐░▒▓▔▕`n"
```

**cmd** (한국어 Windows 는 ANSI=CP949 라 `chcp 65001` 로 UTF-8 활성화 필수, `echo` 가 `\n` 미지원이라 chain):

```cmd
chcp 65001 >nul && echo. && echo 🎉❤️🌈🎨🌞🍎🚀💎✨ && echo 👋🏻👋🏼👋🏽👋🏾👋🏿 && echo 👨‍👩‍👧👨‍👨‍👦‍👦 && echo ABCDEFG abcdefg 0123456789 && echo 한글 ABC 가나다라마바사 && echo ▀▁▂▃▄▅▆▇█▉▊▋▌▍▎▏ && echo ▐░▒▓▔▕ && echo.
```

# Linux — 글리프 · cluster 렌더 실기 검증 방법

폰트 / shaping / cluster 관련 변경 (#401 등) 을 검증하는 절차예요. **소스 판정 → 드라이버로
수치 → 화면으로 눈** 순서로 좁혀요.

## ① 판정만 볼 때 — 독립 드라이버 (레포 트리를 안 건드림)

[`src/font/linux/font.zig`](src/font/linux/font.zig) 는 **ghostty 비의존**이에요 (fontconfig ·
freetype · harfbuzz 를 전부 `dlopen` 하고 나머지 import 는 순수 모듈). `shapeRunOnFace` ·
`resolveCluster` 가 `pub` 이라 **실기와 같은 chain 을 만들어 조합 수천 개를 직접 태울 수 있어요** —
`tryClusterOnFace` 에 임시 로그를 심고 재빌드하는 것보다 빠르고 대상도 넓어요.

```sh
cp <scratchpad>/probe.zig src/probe.zig          # 상대 import 가 맞아야 해서 src/ 아래에 둬요
zig run src/probe.zig -lc -O ReleaseSafe          # Debug 는 이 머신에서 .sframe 링커 에러
rm -f src/probe.zig && git status --short         # 끝나면 지우고 트리 clean 확인
```

- chain 은 **실기 config 와 같게** 만들어요 — `Context.init(alloc, &.{"DejaVu Sans Mono",
  "Noto Sans CJK KR", "Noto Color Emoji"}, 20, 1.0, 1.1)`. 기본값 (`config.zig` 의 `Defaults`) 과
  같은 값이에요.
- **판정 기준은 `.notdef` 예요. 글리프 개수가 아니에요** (#401). `n == cps.len` 이라도 notdef 가
  없으면 폰트가 *겹쳐 그리라고 준 정상 결과*라, 개수로 거르면 진짜 증상을 놓쳐요.
- `perf` / `log` 초기화 없이 쓰려면 `shapeRunOnFace` 만 부르고 chain 판정은 드라이버에서 직접
  계산해요 (= 어느 face 든 notdef 없음).

## ② 화면으로 볼 때 — `render-test` + `-e`

**세 platform 공용 검증 화면이 있어요** ([`src/render_test.zig`](src/render_test.zig), #422).
결합 기호 · cluster 관련 이슈 (#401 · #415~421) 를 (A)~(L) 열두 절로 한 번에 봐요.

```sh
zig build render-test
tildaz --instance 1 -e <zig-out/bin/render-test> -size 88x33 &
```

⚠️ **`-size` 는 반드시 `88x33` 이에요.** 화면이 62 줄이라 그만큼 창을 키우면 **노트북 화면
아래로 잘려서 안 보여요** (실기에서 여러 번 걸렸어요 — 68 줄로 띄웠다가 사용자가 못 봤어요).
33 줄로 띄우고 **스크롤로** 봐요. 절이 위아래로 이어져 있어서 스크롤이 판정을 방해하지 않아요.
**폭 88 도 줄이면 안 돼요** — 가장 긴 줄 기준이라 줄이면 줄바꿈이 생겨 `|` 정렬 판정이 깨져요.

캡처로 판정할 때만 잠깐 크게 띄우되, **사용자에게 보여 줄 때는 다시 `88x33` 으로** 띄워요.

직접 만든 화면이 필요하면 같은 방식으로 스크립트를 넘겨요.

```sh
./zig-out/bin/tildaz --instance 1 -e /path/show.sh -size 70x16 &
```

- **`-e` 는 인자를 못 넘겨요** (`run_options.zig` — POSIX PTY 의 argv 가 `{shell}` 로 고정).
  그래서 출력할 내용을 담은 **스크립트 파일**을 만들어 넘겨요. 스크립트 끝에 `sleep` 을 둬야
  창이 남아요 (`-e` 로 띄운 프로세스가 끝나면 앱도 끝나요).
- **`--instance 1` 을 써요.** 평소 쓰는 daily 인스턴스 (`--instance 0`) 를 건드리지 않아요.
- 입력은 **`printf` 로 UTF-8 byte 를 직접** 내요 — 편집기 · 클립보드가 cluster 를 정규화해
  버리는 것을 피해요.
- 화면 배치는 **`[cluster]` … `base [기본문자]` 좌우 대조**로 만들어요. **좌우가 같아 보이면
  mark 가 사라진 것**이라 판정이 한눈에 돼요.

## ③ 대조군 터미널 — foot

우리만 그런지 가르려면 같은 입력을 foot 에 넣어요. **폰트와 크기를 맞춰야** 비교가 성립해요.

```sh
foot --font="DejaVu Sans Mono:size=15" -w 900x420 -e /path/show.sh &
```

## ④ 캡처 — KDE 는 `spectacle`

```sh
spectacle -b -n -f -o out.png                     # -b 배경 실행 · -n 알림 없음 · -f 전체 화면
```

- **`grim` 은 KDE 에서 안 돼요** (KWin 이 wlr-screencopy 를 지원하지 않아요). sway · Hyprland 는 반대.
- **전체 화면 캡처라 사용자의 다른 창이 함께 담겨요.** 이슈에 올릴 때는 **반드시 터미널 창 영역만
  crop** 해요.
- **작은 화면에서는 mark 유무가 안 보여요.** 판정 · 공유 모두 확대본으로 해요.

```sh
magick out.png -crop 1152x560+2688+0 +repage -resize 200% crop.png   # 창 영역만 확대
magick out.png -crop 130x62+3020+148 +repage -resize 500% one.png    # 글리프 한 칸만
```

## ⑤ 회귀 대조군

cluster 경로를 건드리면 **한글 · ASCII · emoji ZWJ · precomposed 글자 (`é`)** 를 같은 화면에
넣어요. 이 넷이 그대로면 흔한 경로에 회귀가 없다는 뜻이에요.

# 사이트 (`docs/`) 렌더 확인 — headless 브라우저

`docs/` 의 페이지를 고치면 **눈으로 한 번 봐요.** 표 · 각주처럼 구조가 있는 변경은 HTML 파서로 태그
균형만 봐서는 부족해요 — 열이 밀리거나 고유명사가 변형되는 것은 렌더에서만 보여요 ([#434](https://github.com/ensky0/tildaz/issues/434)
에서 `macOS` 가 `MACOS` 로 나오던 것이 그랬어요. 그 표만 uppercase 를 끄는 것으로 고쳤어요).

**Chromium 을 설치하지 않아도 돼요 — Firefox 로 됩니다** (2026-08-11 Linux 세션에서 확인).

```sh
PROF=$(mktemp -d)                                      # 사용자 프로필을 안 건드려요
firefox --headless --profile "$PROF" --window-size=1280,9000 \
        --screenshot /tmp/site.png "file://$PWD/docs/index.html"
rm -rf "$PROF"
magick /tmp/site.png -crop 1280x1000+0+3350 +repage /tmp/crop.png    # 볼 절만 잘라요
```

- **`--window-size` 의 높이가 곧 캡처 높이예요** — 전체 페이지가 아니에요. 페이지 아래쪽 절 (예:
  `#performance`) 을 보려면 넉넉히 (9000 px) 찍고 `magick -crop` 으로 잘라요. 3200 px 로 찍었다가
  성능 절이 통째로 안 담긴 적이 있어요.
- **URL 프래그먼트로는 스크롤이 안 돼요** — headless 는 맨 위에서 렌더해요. `…/index.html#performance`
  를 줘도 맨 위가 찍혀요.
- **임시 프로필을 써요** (`--profile $(mktemp -d)`). 사용자 Firefox 가 떠 있어도 안전하고 설정도 안
  건드려요.
- Chromium 계열도 같은 일을 해요 (`--headless --screenshot --window-size=W,H`). 설치가 필요하면
  CachyOS 에서 `chromium` 은 공식 저장소이고 **`google-chrome` 은 AUR 전용**이에요.

# 도구 실행

**모든 도구 호출에 timeout 은 1분 (60000ms) 을 명시적으로 걸어요.** Bash, PowerShell, Agent 같은 도구의 기본 timeout (2~10 분) 에 의존하지 말고 매 호출마다 `timeout: 60000` 을 직접 넣어요. 사용자가 1 분 넘게 아무 응답도 받지 못하는 상황을 피하기 위한 규칙.

**작업이 1 분 안에 끝나지 않는 게 자연스러운 경우 (예: `zig build` 에서 ghostty 첫 컴파일, 대량 다운로드)** 는 `run_in_background: true` 로 백그라운드에 던지고, 짧은 주기 (1 분 이하) 로 상태를 확인하거나 완료 알림을 기다려요. 단일 blocking 호출로 오래 기다리지 않아요.

이 규칙은 쉘 호출뿐 아니라 Agent / WebFetch / TaskOutput 같은 다른 모든 도구에도 적용해요.

# 실행 환경

**작업 머신은 여러 대예요.** 한 세션이 어느 머신에서 도는지는 그때그때 달라요. 측정값 · 실기
검증 결과에는 **항상 어느 머신인지 함께 적어요** — 절대값이 머신마다 다르고, 특히 화면 주사율은
결론 자체를 바꿔요.

| 머신 | OS | 화면 |
|---|---|---|
| 노트북 · AMD Ryzen AI 7 350 (8C/16T) | **Windows · Linux 듀얼부트** | 2880x1800 · **120 Hz** (Linux scale 1.6 / Windows **150 %**) |
| 노트북 · Intel Core i5-1240P (12C/16T) | **Windows · Linux 듀얼부트** | 1920x1080 · **59.997 Hz** (100 %) |
| 데스크탑 · AMD Ryzen 5 5700G | **Windows · Linux 듀얼부트** | (미기록) |
| 미니PC · Firebat ZY-A8 · AMD Ryzen 7 8845HS (8C/16T) | **Windows · Linux 듀얼부트** (Linux 는 CachyOS) | 3840x2160 · **60 Hz** (Linux scale 1.7 → 논리 2259x1271) |
| MacBook Pro (M5 Pro) | macOS | **120 Hz** (ProMotion) |

**같은 하드웨어에서 OS 만 바꿀 수 있다는 게 성능 측정의 강점이에요.** CPU · 패널이 고정된 채
host 구현 차이만 남아서, platform 비교가 하드웨어 차이에 오염되지 않아요
([#386](https://github.com/ensky0/tildaz/issues/386)). **주사율이 머신마다 다른 것도 중요해요** —
드레인이 프레임에 묶여 있던 시절 예산 8 ms 는 60 Hz 에서 duty 48 %, 120 Hz 에서 96 % 로 전혀 다르게
작동해서, 어느 머신에서 재느냐로 결론이 갈렸어요 (#386 에서 실제로 그랬어요). 그 종속은
[#387](https://github.com/ensky0/tildaz/issues/387) 의 사양 A 로 없앴고 예산도 4 ms 로 내렸지만,
**주사율을 함께 기록하는 규칙은 그대로예요** — fps · 프레임 tick 점유 같은 지표는 여전히 주사율이 정해요.

Windows 환경에서는 **Windows native PowerShell을 기본 셸**로 사용해요. WSL distro가
설치되지 않은 상태가 기본이며, `git`, `gh`, 파일 조작, Zig 빌드와 검증 모두 Windows에
설치된 도구와 `C:\...` Windows 로컬 checkout에서 실행해요. WSL의 `.gitconfig`, SSH 키,
파일 경로, `bash`가 있다고 가정하지 않아요.

`tildaz.exe`는 Windows 프로그램이므로 빌드와 실행도 Windows에서 해요. Zig local/global
cache는 `C:/ziglang/tildaz-cache`처럼 Windows 로컬 경로를 사용해요. `zig build package`의
Windows 경로는 `dist/windows/package.ps1`을 PowerShell로 호출하며 WSL/Git Bash가 필요하지
않아요.

사용자가 명시적으로 WSL 안의 checkout을 작업 대상으로 준 예외적인 경우에만 `\\wsl$\<distro>\...`
UNC 경로를 사용해요. distro 이름을 `Debian`으로 가정하거나 `\\wsl.localhost\...` 경로를
기본값으로 쓰지 않아요.

**예외 — 터미널 비교 측정은 Windows 에서 Git Bash, Linux 에서 KDE Plasma 로 해요.**
[`dist/stress/compare-terminals.sh`](dist/stress/compare-terminals.sh) 는 위의 "기본 셸은
PowerShell" 규칙이 적용되지 않는 유일한 도구예요.

| platform | 어디서 | 안 지키면 |
|---|---|---|
| **Windows** | **Git Bash** (필수) | PowerShell 로는 **아예 안 돌아요** — POSIX `sh` 스크립트이고, `uname -s` 의 `MINGW*`/`MSYS*`/`CYGWIN*` 로 platform 을 판별하고 `cygpath -w` 로 경로를 변환해요. Git for Windows 에 항상 들어 있어요 |
| **Linux** | **KDE Plasma** (권장) | 스크립트 본체는 어느 DE 에서도 돌지만 `--capture` 가 갈려요 — KDE 만 창 단위로 확실히 잡히고 (`spectacle -a`), sway · Hyprland 는 전체 화면 (`grim`), **GNOME 43+ 는 경로가 아예 없어요** |
| **macOS** | 아무 터미널 | 갈리는 게 없어요 |

`zig build stress` **자체는 이 제약이 없어요** — Windows PowerShell 에서 그대로 돌아가요.
Git Bash · KDE 가 필요한 건 여러 터미널을 띄워 비교하는 그 스크립트예요. 자세한 내용은
[`dist/stress/README.md`](dist/stress/README.md) 의 "돌리는 환경" 절에 있어요.

**측정을 시작하기 전에 먼저 말하고 사용자 확인을 받아요** (2026-08-05 사용자 지시:
*"테스트 하기 전에 말하고 해. 좀 전에도 내가 키보드 쳐서 오염되었어"*). 처리량 측정 · perf 덤프 ·
합성 입력이 들어가는 검증은 **사용자가 그 시간 동안 기기를 건드리지 않아야** 값이 살아요. 조용히
시작하면 사용자가 마우스 / 키보드를 쓰다 그 회차를 버리게 돼요 (실제로 두 번 발생). 그래서
"지금부터 몇 초 동안 무엇을 재는지" 를 먼저 알리고, **확인을 받은 뒤에** 실행해요.

**측정 완료를 비프음으로 알리지 않아요** (2026-08-06 사용자 지시: *"실험 완료 때 나오는 비프음 꼭
삭제해줘"*). 측정이 길 때 끝을 알리려고 `[console]::beep` 을 붙이곤 했는데 쓰지 않아요 — 완료는
**텍스트로** 알려요 (`##### 끝 #####` 같은 표시나 그냥 결과 보고). 소요 시간을 미리 알리는 규칙은
그대로예요.

**어느 화면에서 쟀는지도 함께 적어요.** 모니터가 여러 대면 창이 뜬 화면이 값을 정해요 —
Windows 의 `startFrameClock` 은 *우리 창이 올라간 디스플레이* 의 DC 로 `GetDeviceCaps(VREFRESH)` 를
읽으므로, 같은 기기에서도 내장 패널(120 Hz)과 외장 모니터(60 Hz)에서 프레임 주기가 갈려요.
앱 로그의 `[startup] frame clock started: refresh=..Hz` 와 `window initialized: dpi=..` 를 근거로
남겨요.

**측정 때 종료한 평소 쓰는 TildaZ worker 는 다시 띄우지 않아요** (2026-08-05 사용자 지시:
*"측정 위생 때문에 종료한 TildaZ를 다시 띄울 필요는 없어. 다시 묻지 마"*). 처리량 측정은
[`dist/stress/README.md`](dist/stress/README.md) 의 "측정 위생" 대로 worker 를 내려야 하는데,
측정이 끝난 뒤 **다시 띄울지 묻지도 말고 띄우지도 말아요** — 사용자가 필요할 때 직접 띄워요.
worker 를 내리는 것 자체는 측정 절차의 일부라 그대로 진행해요.

**macOS 빌드는 반드시 [`dist/macos/build_and_install.sh`](dist/macos/build_and_install.sh) 로 해요**
(2026-08-03 사용자 지적). `zig build` 만 돌리면 **코드 서명이 붙지 않아서** 권한이 필요한 동작
(전역 핫키 등) 이 안 먹어요.

```sh
dist/macos/build_and_install.sh     # ✅ 빌드 + 서명 + /Applications 설치 + 서명 검증
open /Applications/TildaZ.app       # ✅ 실행
```

스크립트가 하는 일:

- **stable self-signed identity** (`TildazLocal`, `TILDAZ_SIGN_IDENTITY` 로 변경) 로 서명해요.
  ad-hoc (`-`) 서명은 매 빌드마다 바이너리 해시가 바뀌어 *Input Monitoring* 권한이 stale 해지는데
  ([#109](https://github.com/ensky0/tildaz/issues/109)), stable identity 는 그 문제가 없어요.
- `-Doptimize=ReleaseFast -Dsimd=true` 로 빌드해요 (공식 릴리즈와 같은 옵션).
- `/Applications/TildaZ.app` 에 `ditto` 로 설치하고 `codesign --verify` 로 검증해요.
- identity 가 없으면 [`setup-cert.sh`](dist/macos/setup-cert.sh) 를 한 번 실행해 안내해요.

**identity 가 사라졌으면 새로 만들지 말고 백업에서 되살려요** ([#444](https://github.com/ensky0/tildaz/issues/444)).
login keychain 이 밀리면 (`login_renamed_N.keychain-db` 가 생기는 경우 — 2026-08-10 에 실제로
겪었고 그 머신에서 두 번째였어요) 인증서와 private key 가 함께 없어져요. 새로 만들면 서명 해시가
바뀌어 **Input Monitoring · Accessibility 권한 재부여 + GitHub secrets 2개 + 워크플로우의
`MACOS_CERTIFICATE_SHA1` 갱신**이 따라와요.

```sh
security find-identity -v -p codesigning     # TildazLocal 이 안 보이면
./dist/macos/restore-cert.sh                 # ~/.tildaz/TildazLocal.p12 로 같은 인증서 복구
```

- 백업은 `setup-cert.sh` 가 만들어요 — `~/.tildaz/TildazLocal.p12` (권한 600, private key 포함) +
  `~/.tildaz/TildazLocal.crt`. 백업이 있으면 `setup-cert.sh` 는 새로 만들기를 **거부**해요.
- 복구 끝에 찍히는 SHA-1 지문이 워크플로우의 `MACOS_CERTIFICATE_SHA1` 과 같으면 CI 쪽은 손댈 게 없어요.
- 백업이 없어 새로 만들 수밖에 없다면 위의 갱신 목록을 전부 처리해요. 자세한 절차는
  [`dist/macos/SETUP.md`](dist/macos/SETUP.md) 의 "identity 가 사라졌어요" 절.

**앱은 항상 `open` 으로 `.app` 번들을 열어요.** `zig-out/TildaZ.app` 은 서명 전 중간 산출물이라
실행 대상이 아니고, 번들 안의 바이너리를 직접 띄우면 권한이 안 붙어요.

```sh
open /Applications/TildaZ.app                        # ✅ 이걸 써요
/Applications/TildaZ.app/Contents/MacOS/tildaz       # ⚠️ 권한 문제 — 아래 참고
```

- 터미널에서 바이너리를 직접 띄우면 그 프로세스의 권한 요청을 macOS 가 **부모 (터미널 앱) 기준**으로
  평가해요. 그래서 TildaZ.app 자신에게 부여해 둔 *Input Monitoring* · *Accessibility* 권한을 쓰지
  못하고, 전역 핫키 (CGEventTap, [`src/host/macos.zig`](src/host/macos.zig)) 가 안 먹어요. 권한
  설정 절차는 [`dist/macos/SETUP.md`](dist/macos/SETUP.md) 에 있어요.
- `open` 은 LaunchServices 를 거치니 TildaZ.app 이 자기 identity 로 뜨고 `Info.plist` 키
  (Accessory mode 등) 도 정상 적용돼요.
- 터미널에 붙여서 로그를 보려고 직접 실행하는 건 **권한이 필요 없는 검증** (렌더링 / 파싱 / PTY 왕복)
  에서만 써요. 로그는 `Shift+Cmd+L` 이나 `~/Library/Logs/tildaz_N.log` 로 봐요.
- ad-hoc 서명은 매 빌드마다 바이너리 해시가 바뀌어서 Input Monitoring 권한이 stale 해져요 (#109).
  핫키가 갑자기 안 들으면 시스템 설정에서 토글 OFF/ON 하거나 `tccutil reset All me.ensky0.tildaz`
  로 초기화하고 다시 허용해요.

**빌드 / 검증 명령** (Windows 셸, 캐시는 `--cache-dir C:/ziglang/tildaz-cache`). 한 스크립트로는 [`dist/windows/build.ps1`](dist/windows/build.ps1) (`-Clean` / `-Optimize` / `-Check` / `-Test` / `-NoSimd` 지원). 직접 호출 시:
- 전체 빌드: `zig build -Doptimize=ReleaseFast -Dsimd=true`
- Windows 릴리즈 package: `zig build package -Doptimize=ReleaseFast -Dsimd=true`
- **컴파일 검증**: `zig build check` — Linux · macOS · Windows × (x86_64 / aarch64) 6 타겟을 *compile-only* (link 없이 `.o` 만) 로 돌려, mac / Linux host 코드의 type / 컴파일 에러를 Windows 한 머신에서 한 번에 잡아요 (#201). cross-platform 변경 후 필수.
- **독립 진단 도구 검증**: `zig build probe-check` — 본체 빌드에 들어가지 않는 Linux dma-buf / Linux OSC title / Windows OSC title 도구를 각 지원 OS × (x86_64 / aarch64) 로 *compile-only* 검증해요. Zig 버전 이전처럼 저장소 전체 API가 바뀌는 작업 후 필수 (#451).
- 단위 테스트: `zig build test` (이 머신에서 debug `.sframe` 링커 에러 나면 `-Doptimize=ReleaseSafe`).
- 순수 모듈만 빠르게: `zig test src/<module>.zig` (ghostty 의존성 없는 모듈 한정, 예: `src/scrollbar.zig`).

**SIMD 정책 (#19):** 공식 Linux · macOS · Windows ReleaseFast와 Windows
`dist/windows/build.ps1` 기본 빌드는 SIMD를 활성화해요. 일반 Debug와 `zig build check`는
C++ toolchain/SDK를 모든 cross target에 요구하지 않도록 기본 false를 유지해요. scalar 비교
진단은 `-Dsimd=false` 또는 `dist/windows/build.ps1 -NoSimd`를 사용해요. macOS package는
`build.zig`이 이 값을 universal binary의 arm64/x86_64 내부 빌드 양쪽에 전달해요.

**Windows target ABI (#19):** Zig는 ABI를 생략한 Windows target을 GNU로 resolve하지만,
Ghostty는 target query의 ABI가 null이면 [내부 target을 MSVC로
바꿔요](https://github.com/ghostty-org/ghostty/blob/94d775fefc21f74d9cc85a46b34c4e1d85318fd0/src/build/Config.zig#L96-L107)
(그쪽 주석이 이유를 적어 둬요 — GNU ABI가 만드는 COMDAT section을 MSVC 링커가 거부해요, LNK1143).
그러면 TildaZ root와 Ghostty SIMD C++ module의 ABI가 갈리므로, `build.zig`의
`preserveResolvedWindowsAbi`가 이미 resolve된 ABI를 dependency query에도 명시해요.
명시적으로 요청한 ABI는 건드리지 않아요.

**캐시 두 종류 — 헷갈리지 않기.** zig 는 캐시가 둘이에요. (1) **로컬 캐시** = 빌드 산출물·중간물, `--cache-dir` 로 지정 (위 명령의 `C:/ziglang/tildaz-cache`). (2) **글로벌 캐시** = 받아온 의존성 패키지 (`ghostty` / `vaxis` / `uucode` 등, `p/` 디렉토리), `--global-cache-dir` 또는 `ZIG_GLOBAL_CACHE_DIR` 로 지정하고 기본은 `%LocalAppData%\zig`. 둘은 **별개라** `--cache-dir` 만 바꿔도 의존성은 글로벌 캐시에서 따로 관리돼요. 의존성 fetch 문제(아래 libxml2)는 *글로벌* 캐시에서 일어나요.

**새 컴퓨터 첫 빌드 — Windows 는 개발자 모드 필수.** zig 는 `build.zig.zon` 의 `minimum_zig_version` (현재 **0.16.0**) 이상이 필요해요. 첫 빌드는 의존성을 자동 fetch 하는데, **Windows 에서는 먼저 개발자 모드 (Developer Mode) 를 켜야 해요**:

- 켜는 법 (Windows 11): **설정 → 시스템 → 개발자용 (고급) → 개발자 모드 ON**. 재부팅 없이 바로 적용.
- 이유: ghostty tarball 이 upstream [c09ade22](https://github.com/ghostty-org/ghostty/commit/c09ade22) (2026-05-29) 부터 `CLAUDE.md → AGENTS.md` **심볼릭 링크**를 담고 있어요. 우리 pin 은 [ad692f1](https://github.com/ghostty-org/ghostty/commit/ad692f1e858b8c6475aec4539934526a8d783e6d) (#266, 2026-07-08) 부터 해당. 심볼릭 링크 생성 권한이 없으면 fetch 가 `error: unable to unpack tarball ... unable to create symlink from 'CLAUDE.md' to 'AGENTS.md': AccessDenied` 로 실패해요 (Windows 실기에서 실측, 개발자 모드 ON 으로 해결 확인).
- 그 이전 pin (3a1482d, 2026-04-21) 은 symlink 가 없어서 개발자 모드 없이도 빌드됐어요 — 과거 문서의 "Developer Mode 없어도 됩니다" 는 그 시점 기준.
- CI (windows-2022 러너) 는 **별도 조치 없이 ghostty 본체 tarball unpack 성공 확인** — [`windows-fetch-check.yml`](.github/workflows/windows-fetch-check.yml) 수동 실행으로 검증 ([run 28923076087](https://github.com/ensky0/tildaz/actions/runs/28923076087), 2026-07-08 success). 현재 workflow 는 release.yml 의 top-level fetch와 같은 `-Dsimd=true`를 쓰지만, Zig 0.15의 empty-cache `--fetch`는 Ghostty 내부 highway/simdutf lazy dependency의 compile/link 검증이 아니에요. 그 검증은 실제 package job이 담당해요. ghostty pin을 올리면 태그 전에 fetch-check와 package를 모두 다시 실행해요.

libxml2 는 여전히 `font-backend = .freetype` 으로 회피돼요 (아래 문단) — 개발자 모드는 ghostty 자체 tarball 때문에 필요한 것. 글로벌 캐시도 Windows 로컬(예 `C:/ziglang/tildaz-cache`)로 두면 빨라요 (`ZIG_GLOBAL_CACHE_DIR` 설정).

**`zig build --fetch=all` 은 쓰지 않아요.** `--fetch=all` 은 폰트용 lazy 의존성 (ghostty → fontconfig → libxml2) 까지 전부 받는데, libxml2 tarball 은 Unix 심볼릭 링크 (test fixtures) 를 담고 있어 **심볼릭 링크 생성 권한 없는 Windows (Developer Mode off) 환경에선 unpack 이 `AccessDenied` 로 실패**해요. 근본 차단은 [`build.zig`](build.zig) 가 ghostty 의존성에 `font-backend = .freetype` 을 명시한 것 — ghostty 의 `SharedDeps.init` 은 `emit-lib-vt` 여부와 무관하게 항상 돌며 `font_backend.hasFontconfig()` 이 true 면 `lazyDependency("fontconfig")` 를 호출하는데, 기본값(`FontBackend.default`)이 Linux 등에서 `fontconfig_freetype` 이라 끌려와요. `.freetype` 은 `hasFontconfig()=false` 라 그 경로를 통째로 스킵해 libxml2 를 아예 안 받아요 (VT 파서 모듈은 폰트 백엔드 미사용 — 값 무방, 그래프 평가만 통과). prefetch 도 needed (`--fetch`) 만 쓰고 공식 release는 package와 같은 `-Dsimd=true`를 명시해요. 다만 empty-cache prefetch만으로 nested SIMD dependency compile을 검증했다고 판단하지 않아요. CI package가 실제 highway/simdutf compile/link를 검증해요 ([`.github/workflows/release.yml`](.github/workflows/release.yml)).

**git / GitHub 인증.** Windows native Git과 GitHub CLI의 설정·자격 증명을 사용해요.
WSL 설정이나 token이 있다고 가정하지 말고, 필요하면 Windows PowerShell에서
`git config`, `git remote -v`, `gh auth status`로 현재 상태를 확인해요.

# 릴리즈

릴리즈 바이너리는 **반드시 GitHub Actions를 통해 생성**해요.
로컬에서 만든 zip은 업로드하지 않아요.
`v*` 태그 push가 `.github/workflows/release.yml`을 트리거해서 Linux · macOS · Windows
runner에서 각 platform/architecture 아티팩트와 SHA256을 만들고 GitHub Release까지 한 번에 처리해요.

순서는 아래와 같아요.

1. `build.zig.zon`의 `.version`을 새 버전으로 올려요. 이 값이 About / log,
   Linux package metadata, macOS `Info.plist`, Windows `VERSIONINFO`, artifact
   파일명의 단일 원본이에요. 정식 버전은 `X.Y.Z`, prerelease는
   `X.Y.Z-dev.N` / `-alpha.N` / `-beta.N` / `-rc.N` 형식만 사용해요.
2. 정식 버전은 `dist/release-notes/vX.Y.Z.md`를 작성해요. GitHub Actions
   검증용 prerelease (`-dev.N` 등)는 릴리즈 노트를 생략할 수 있어요.
3. 커밋하고 `git push origin main` 해요.
4. Windows PowerShell에서 아래 두 명령으로 태그를 push해 Actions를 트리거해요.

   ```powershell
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

5. Actions가 초록불이면 GitHub Release가 자동 생성돼요.

## 릴리즈 노트는 사람이 읽는 글이에요 — 본문 5줄 이내

2026-08-09 사용자 지시예요: *"릴리즈 노트는 사람이 읽는거야. 5줄 이내의 짧은 문장으로 하자."*
v0.7.0 까지의 긴 형식 (섹션마다 변경을 나열하는 방식, 200줄 넘음) 은 더 쓰지 않아요.

- **본문은 5줄 이내예요.** 본문 = 헤드라인 아래의 변경 요약이고, 한 줄은 한 항목 · 한 문장으로
  짧게 써요. 커밋이 100개든 300개든 줄 수는 늘지 않아요.
- **담는 것은 이전 버전과 달라진 것 중 사용자가 실제로 느끼는 것뿐이에요.** 체감하는 사람이
  적은 항목은 아예 빼요. 내부 구현 · 리팩터링 · 측정 도구 · 문서 · 테스트 변경은 안 적어요.
- **분량에서 빼는 부속 섹션 셋** — `Upgrade notes` · `Downloads` 표 · `Known limitations`.
  실용 정보라 필요하면 넣되, 각 항목은 한 문장으로 유지해요.
- **근거 링크는 줄 끝에 이슈 번호로 짧게** 달아요 (`([#365](...))`). 위쪽 `# 문서화` 의 "출처
  링크를 남긴다" 규칙과 충돌하지 않아요 — 상세한 근거는 본문이 아니라 그 이슈에 있어요.
- 언어는 영어예요 (최상단 `# 메시지 언어` — end-user 가 GitHub Release 에서 직접 봐요).

# 의존성 관리

`build.zig.zon`의 의존성은 **반드시 고정된 commit SHA URL로 pin**해요.

형식은 아래처럼 40자리 commit SHA tarball URL만 사용해요.

`https://github.com/<org>/<repo>/archive/<40-hex-sha>.tar.gz`

`refs/heads/main.tar.gz` 같은 rolling 레퍼런스는 사용하지 않아요.
upstream이 움직이면 CI의 `zig build -Dsimd=true --fetch`가 캐시 불일치로 실패할 수 있어요.
`.github/workflows/release.yml`에는 rolling URL을 막는 sanity check가 있으니, 실수로 되돌리면 바로 빌드가 깨질 수 있어요.

ghostty 의존성을 갱신하려면 `dist/update-ghostty.sh`를 실행해서 upstream `main` HEAD sha 기준으로 URL과 hash를 함께 업데이트해요.
