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

**Linux · macOS · Windows에서 의미가 같은 로그는 [`src/log.zig`](src/log.zig)의 semantic 함수 하나가
category와 format string을 소유하고, 각 host는 값만 넘겨요.** 같은 문자열을 세 파일에 복사하거나
각자 비슷하게 다시 쓰지 않아요. `logStart` · `logDisplayTiming` · pane 로그가 이 형태예요
([#576](https://github.com/ensky0/tildaz/issues/576)). 반대로 font discovery API나 compositor protocol처럼
실제 의미와 인자가 다른 세부 진단은 억지로 합치지 않고 host에 둬요.

공개 레포의 정문과 앱 UI 는 국제 방문자가 바로 읽을 수 있는 언어 (= 영어) 에 맞추는 게 기본값이고, 내부 기록은 한국어로 남겨서 두 역할을 분리해요. **이 구분은 "출력은 한국어" 규칙의 예외가 아니라 대상이 달라서예요** — 사용자에게 하는 말은 한국어, 저장소 방문자 / end-user 가 읽는 산출물은 영어.

**사고 과정 (visible thinking) 도 한국어예요.** 답변만 한국어로 쓰고 생각을 영어로 하면 사용자에게 그
영어가 그대로 보여요 — 2026-07-22 에 두 번 지적됐어요. "보이는 모든 텍스트" 에 thinking 이 들어가요.

# 워크플로우

모든 작업은 아래 순서로 진행해요.

1. **이슈 확인**: 관련 이슈가 이미 있는지 확인하고, 없으면 새로 생성해요.
2. **계획 기록**: 이슈에 구체적인 구현 계획을 먼저 댓글로 기록해요.
3. **작업 수행**: 작업하면서 중간 결과, 결정 사항, 변경 이유 등을 계속 이슈에 댓글로 기록해요.
4. **검증**: 빌드와 테스트를 직접 실행해서 작업 내용이 올바른지 확인해요.
5. **완료**: 검증이 끝나면 커밋해요. (릴리즈는 별도 타이밍 — 여러 작업을 모아 새 버전으로 내요.)
6. **이슈 닫기**: 릴리즈가 아니라 **검증이 끝나 해결되면 바로** 이슈를 닫아요. 릴리즈 여부는 닫기를 막지 않아요.

**닫지 않고 레이블로 남기는 경우가 있어요 — ⑥ 의 예외예요.** 원인 규명이 끝났는데도 남은 일이 있으면 닫지 않고 **왜 열려 있는지**를 레이블로 표시해요. 표시가 없으면 다음 세션이 ⑥ 대로 닫아 버리거나, 반대로 왜 열려 있는지 몰라 **이미 끝난 조사를 다시** 해요.

| 레이블 | 뜻 | 예 |
|---|---|---|
| `long-term watch` | 오래 지켜봐야 하는 것. 주기적으로 다시 확인하며 열어 둬요 | [#513](https://github.com/ensky0/tildaz/issues/513) · [#257](https://github.com/ensky0/tildaz/issues/257) · [#266](https://github.com/ensky0/tildaz/issues/266) |
| `upstream` | 수정이 **다른 프로젝트 소관**인 것. 우리 코드에 고칠 게 없어도 증상은 남아요 | #513 (cosmic-comp) · #257 (`mlugg/setup-zig`) · #266 (ghostty-vt) |
| `slow track` | **큰 작업이라 의도적으로 천천히** 하는 것. 방치가 아니에요 | [#483](https://github.com/ensky0/tildaz/issues/483) |
| `awaiting field test` | **원인과 수정은 끝났는데 실기 측정이 남은** 것. 미결인 것이 코드가 아니라 측정이에요 | [#552](https://github.com/ensky0/tildaz/issues/552) |

- 앞의 둘은 **함께 붙어요** — 위 셋 다 그래요 (upstream 을 기다리며 주기적으로 재확인).
- `wontfix` 와 구분해요. 그건 *하지 않기로 정한 것*이고, 이 넷은 *아직 안 끝난 것*이에요.
- **닫을 때는 무엇이 끝나서 닫는지를 댓글로 남겨요.** 이 레이블이 붙은 이슈가 조용히 닫히면 "오래돼서 정리됐다" 로 읽혀요.
- **레이블을 붙이거나 닫기를 판정할 때는 이슈를 처음부터 다 읽어요.** 마지막 코멘트만 보면 틀려요 — 2026-08-26 에 #266 을 그렇게 오판했어요. 마지막 코멘트가 작은 미결 항목 (Linux 미확인) 이라 "그것만 채우면 닫힌다" 고 봤는데, 실제로 열려 있는 이유는 열여섯 번째가 아니라 **열세 번째 코멘트의 방향 결정** (3 단계 미구현 + upstream 대기) 이었어요.

**코드 변경이 문서 서술을 바꾸면 같은 PR 에 담아요** (2026-08-10 사용자 지적: *"이미 pr만들어서 머지했는데 이제야 고치면 어떡해? 앞으로는 꼭 문서까지 다 고쳐서 pr해"*). 코드만 먼저 머지하고 `SPEC.md` / `AGENTS.md` / `CONFIG.md` 를 나중에 올리면, 그 사이 문서가 사실과 어긋난 채 main 에 남아요. PR 을 올리기 전에 **바꾼 동작을 서술한 문서가 있는지 grep 으로 먼저 확인**해요 (#442 에서 SPEC.md 두 줄과 AGENTS.md 를 놓쳤어요).

**문서만 바뀌는 변경은 PR 없이 main 에 바로 push 할 수 있어요** (2026-08-10 사용자 지시: *"이런건 그냥 main에 바로 넣어"*). 위의 "같은 PR 에 담아요" 와 충돌하지 않아요 — 코드와 함께 가는 문서는 그 PR 에 담아요.

**단 main 직행은 *의무가 아니라 편의*예요** (2026-08-29 사용자 지시: *"브랜치에 얹기 귀찮을 때 main에 바로 넣으라는거지"*). **머지될 브랜치가 이미 열려 있으면 그 브랜치에 얹어 함께 머지해요** — 그게 리뷰에 문맥이 함께 남고 커밋도 한 번이에요. main 직행은 얹을 브랜치가 없거나, 있어도 그 작업과 무관해서 끼워 넣는 것이 더 번거로울 때 쓰는 길이에요. (그날 `#544` 브랜치가 열려 있는데도 AGENTS.md 를 main 에 따로 넣었어요 — 이 문장이 "직행해야 한다" 로 읽혔기 때문이에요.)

**여러 단계로 나눈 큰 작업은 PR 을 마지막에 한 번만 올려요** (2026-08-26 사용자 지시: *"PR 을
작업 다 하고 마지막에 올리자 … PR 에 지저분하게 계속 뭐 추가하는 거 안 좋아 보이더라고"*).
단계마다 브랜치에 커밋 · push 하고 진행은 이슈 댓글로 기록하되, PR 은 전체가 끝난 뒤에 열어요 —
올린 PR 위에 커밋이 계속 쌓이면 리뷰가 지저분해져요. 단계 댓글의 **제목 줄에 브랜치 이름과
커밋을 적어요** (같은 날 사용자 지시) — 다음 세션이 어느 브랜치를 이어받는지 댓글만 보고 알 수
있어야 해요. 브랜치가 오래 살므로 단계가 끝날 때마다 `origin/main` 위로 rebase 해 두면 (아래
규칙과 같은 방법) 마지막 PR 의 충돌이 작아져요. 첫 적용은
[#483](https://github.com/ensky0/tildaz/issues/483) 의 `feat/483-pane-layout` 이에요.

**세션을 시작하면 같은 checkout · 같은 브랜치에서 일하는 다른 세션이 있는지 `ListAgents` 로
먼저 확인해요** (2026-08-26 사용자 지시). 그날 두 세션이 `feat/483-pane-layout` 에서 #483 1단계를
동시에 진행해, 한 세션이 검증을 끝낸 뒤 다른 세션이 넣은 4줄이 함께 커밋되어 **push 된 커밋이
컴파일되지 않았고** (`PANE_SEPARATOR_W_PT` 중복 선언), 같은 결정 댓글이 30초 간격으로 두 번
올라갔어요. 다른 세션이 보이면 메시지로 어느 쪽이 이어갈지 정하고 나머지는 파일 · git · 이슈를
멈춰요. 그리고 세션이 하나뿐이어도 **커밋 직전에 `git diff --cached` 로 검증한 내용과 담는 내용이
같은지** 봐요 — 검증과 커밋 사이에 파일이 바뀌면 검증은 무효예요.

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
**레포에서 관리되는 곳**에 적어요 — 작업 기록은 **관련 GitHub 이슈 댓글**, 검증 절차 · 함정 · 도구
사용법은 **이 문서 (AGENTS.md)** 나 스크립트 머리 주석, 동작 사양은 **SPEC.md**, 재사용할 스크립트는
`dist/<platform>/` 에 커밋. 어느 머신에서든 같이 보이고, 바로 위의 "작업 기록은 GitHub 이슈에" 와
같은 방향이에요. (2026-08-05 사용자 지적 — 세션마다 반복돼서 문서에 적어요. 2026-09-02 에 또
반복됐어요 — 세션이 이 절을 읽기 전에 memory 를 썼어요. **이 문서를 끝까지 읽는 것이 먼저예요.**)

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

# 새 단축키 기본값 고르기 — 형식 규칙

기본 바인딩을 새로 더할 때 형식을 즉흥적으로 고르지 않아요. 2026-08-29 [#544](https://github.com/ensky0/tildaz/issues/544) 에서 `close_pane` 을 더하며 **현재 기본값을 전수로 읽어 규칙을 뽑았어요** — 출처는 [`config.zig`](src/config.zig) 의 macOS · Linux/Windows 두 기본값 목록이에요. 이 절이 없어서 그때 `⌘D` · `⌘X` 를 놓고 논의가 처음부터 다시 돌았어요.

## 글자 키 — platform 마다 대역이 다르다

| | 대역 | 실제 글자 |
|---|---|---|
| **Linux · Windows** | `Ctrl+Shift+<글자>` **하나** | `C` `I` `L` `P` `R` `T` `V` `W` `Z` |
| **macOS** | `⌘<글자>` = **OS 전역 표준만** | `T` (새 탭) · `W` (닫기) · `C` (복사) · `V` (붙여넣기) · `Q` (종료) |
| | `⇧⌘<글자>` = **우리가 고른 글자 전부** | `I` (about) · `L` (log) · `P` (config) · `R` (reset) · `Z` (zoom) |

- Linux · Windows 가 한 대역인 이유는 `Ctrl+<글자>` 가 **터미널의 제어문자**라서예요 (`Ctrl+C` = SIGINT). 그래서 앱 chrome 은 관례적으로 전부 `Ctrl+Shift+` 예요.
- **macOS 는 두 대역을 섞지 않아요.** 자체로 고른 글자를 `⌘<글자>` 에 두면 그게 **유일한 예외**가 되고, 그 자리는 대개 OS 가 이미 쓰는 자리예요. 실측으로 *자체 선택 글자가 `⌘<글자>` 에 있는 경우는 0 건*이에요.

## 글자가 아닌 키 — 일차 동작과 그 변형을 `Shift` 로 짝지운다

| 동작 | macOS | Linux · Windows |
|---|---|---|
| 전체화면 / 작업영역 전체화면 | `⌘↵` / `⇧⌘↵` | `Alt+↵` / `Shift+Alt+↵` |
| pane 포커스 / pane 크기 | `⌘←→↑↓` / `⇧⌘←→↑↓` | `Alt+←→↑↓` / `Shift+Alt+←→↑↓` |
| 탭 전환 | `⌘1`–`⌘9` | `Alt+1`–`Alt+9` |
| pane 균등 | `⇧⌘0` | `Shift+Alt+0` |
| 분할 | `⌥⌘→` `⌥⌘↓` | `Ctrl+Shift+→` `Ctrl+Shift+↓` |

- 분할이 `⌃⌘방향` 이 아닌 이유는 macOS 의 Mission Control (`⌃↑` `⌃↓`) 과 부딪혀서고, Linux 에서 `Ctrl+Alt+방향` 을 피한 이유는 GNOME 이 workspace 전환 · 이동에 쓰기 때문이에요 (둘 다 `config.zig` 주석에 근거가 있어요).
- 탭 순환 (`⇧⌘[` `⇧⌘]` / `Ctrl+Shift+[` `]`) 에는 **`PgUp` / `PgDn` 을 함께** 둬요 — AZERTY 에서 bracket 이 `AltGr+5` 라 못 눌러요 ([#482](https://github.com/ensky0/tildaz/issues/482)).

## 글자를 고르는 세 기준

1. **세 platform 이 같은 글자.** 지금 글자 바인딩 전부가 그래요 — 예외 0 건. 최대화는 세 platform 다 `Z`, 닫기는 다 `W` 예요. 글자를 platform 마다 다르게 두지 않아요.
2. **선례에서 고르고, 뜻 없는 글자는 안 써요.** `Z` (최대화) 는 WezTerm `Ctrl+Shift+Z` 선례이고, `X` (pane 닫기 — [#544](https://github.com/ensky0/tildaz/issues/544) 에서 이 규칙으로 정한 것) 는 tmux `prefix + x` = kill pane 선례 + 앱의 `×` 글리프예요. `⌘D` 는 **"뜻이 없는 글자"** 로 기각했어요 (`config.zig` 의 #483 주석) — 게다가 iTerm2 · Terminal.app 이 `D` 를 **분할** 에 써서 *반대 동작*이 연상돼요.
3. **OS 전역 표준 자리를 빼앗지 않아요.** 되돌릴 수 없는 동작에 근육기억이 걸리면 특히요 — `⌘X` (잘라내기) 를 pane 닫기로 쓰지 않은 이유예요.

**고르기 전에 두 목록을 grep 해 충돌을 확인해요.** 네 조합이 다 비어 있는 것을 본 뒤에 정해요.

```sh
awk '/new_tab => &\.\{"cmd\+t"\}/,/^    \}/' src/config.zig            # macOS 기본값
awk '/new_tab => &\.\{"ctrl\+shift\+t"\}/,/^    \}/' src/config.zig   # Linux · Windows 기본값
```

**액션을 더하면 config 스키마가 바뀌어요.** `[keys]` 는 strict 라 필수 키가 하나 늘고, 기존 `config_N.toml` 은 `missing required key "<액션>"` 으로 **부팅이 막혀요.** 그래서 새 액션은 [`dist/release-notes/UNRELEASED.md`](dist/release-notes/UNRELEASED.md) 의 `Upgrade notes` 에 **같은 PR 에서** 한 줄을 더해요 (아래 `# 릴리즈` 의 운반책 규칙). 이미 그 안내가 있으면 개수를 고쳐요.

# 커밋 메시지

`Co-Authored-By` 트레일러 (Claude / AI tool 등) 는 **절대 넣지 않아요**.
사람이 직접 작성한 것처럼 보여야 하는 게 아니라, 단순히 저장소 운영 정책으로
모든 commit author 는 사람으로 통일해요. 도구 사용 사실은 코드 / 이슈 본문
/ 댓글 등 다른 곳에 충분히 남아 있어요.

**두 겹으로 막아 둬요.** 규칙만으로는 계속 새어 들어왔어요.

- **로컬 훅** — `dist/hooks/commit-msg` 가 커밋이 *만들어지기 전에* 거부해요.
  저장소마다 한 번 켜요: `git config core.hooksPath dist/hooks`
- **CI** — `.github/workflows/trailer-guard.yml` 이 PR 과 **main push 둘 다** 검사해요.
  PR 만 보면 안 되는 이유는 이 저장소가 문서 변경을 main 에 직행시키기 때문이에요.
  다만 Actions 는 push 를 *거부하지 못해요* — 빨간불로 알릴 뿐이라 로컬 훅이 1 차 방어예요.

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

# macOS — 실행마다 화면이 흔들리는지 보는 법

같은 바이너리를 여러 번 띄워 캡처를 견주는 도구예요 ([`dist/macos/repeat-render-check.sh`](dist/macos/repeat-render-check.sh)).
회차 사이에 다른 것이 없으니, 캡처가 회차마다 다르면 그 차이는 **실행 간 비결정**이에요.
[#529](https://github.com/ensky0/tildaz/issues/529) 에서 atlas 의 cluster 키가 일반 글리프와
자리를 나눠 쓰던 결함을 이걸로 잡았어요 — 24 회 중 1 회에서 `a̸` 자리에 `U` 가 그려졌어요.

```sh
dist/macos/repeat-render-check.sh                       # render-test 화면 24 회
dist/macos/repeat-render-check.sh 40                    # 회차만 바꿔서
dist/macos/repeat-render-check.sh 24 6 /path/show.sh    # 다른 화면으로
```

- **A/B 는 반드시 같은 화면에서 찍어요.** `color-capture` 가 출력 색공간을 sRGB 로 잡아도
  **디스플레이가 다르면 값이 갈려요** — 같은 화면인데 내장 120 Hz 캡처와 외장 60 Hz 캡처가
  서로 `AE 168466` 이 나왔어요 (#529 검증). 수정 전후를 견줄 때 화면을 바꾸지 않아요.
- **재현이 관측된 조건과 같은 회차 수로 재요.** 확률이 낮은 결함은 (#529 는 회차당 10.5%)
  회차가 적으면 그냥 지나가요. *"수정 전에 N 회에서 M 번"* 을 적어 두고 수정 뒤 **같은 N**
  으로 다시 재요. 60 Hz 12 회 무재현을 근거로 삼으려다 조건이 안 맞아 120 Hz 24 회로 다시
  쟀어요 (사용자 지적).
- **`AE` 숫자만으로는 *사라짐* 과 *다른 것으로 바뀜* 을 못 갈라요.** 갈린 회차가 나오면 차이
  영역을 잘라 **눈으로** 봐요. #529 의 원 관측이 이것 때문에 어느 쪽인지 끝내 확정되지
  못했어요 — 캡처 원본을 안 남겨서 되짚을 수도 없었어요.
- 도구는 `--instance 9` 로만 띄우고 끝나면 `config_9.toml` 을 스스로 지워요. 실기라서 위
  `# 실행 환경` 대로 **시작 전에 알리고 동의를 받아요** — 창이 회차마다 떴다 사라져 화면이
  깜빡이고, 그동안 사용자가 기기를 만지면 그 회차가 오염돼요.
- **한 회차를 먼저 돌려 조건을 확인하고 시작해요.** 앱이 뜨는지 · 캡처 크기 · 주사율
  (`[startup] display timing`) 을 보고 나서 전체를 돌려요. 이걸 건너뛰어 10 회를 통째로
  버린 적이 있어요 (앱이 매 회차 죽고 있었는데 모르고 끝까지 돌렸어요).

# macOS — 렌더 결과와 그리는 과정을 픽셀로 검증하는 법

렌더 경로 (atlas · 업로드 · pass 구조) 를 바꿨을 때 쓰는 절차예요. #584 · #585 · #591 에서 다듬었어요.
**최종 그림 한 장만 보지 않아요 — 그리는 과정도 봐요** (2026-09-02 사용자 지시). 도구는 셋이에요.

| 도구 | 무엇 |
|---|---|
| [`dist/macos/render-ab-shot.sh`](dist/macos/render-ab-shot.sh) | 두 앱 판을 같은 화면으로 찍어 **최종 그림**을 픽셀 수로 견줘요 |
| [`dist/macos/render-process-check.sh`](dist/macos/render-process-check.sh) | 기동 직후부터 촘촘히 찍어 **이웃 프레임 차이 · 최종 대비 차이**를 내요 — 과정이 단계적으로 채워지면 여기서 보여요 |
| [`dist/screens/clusters.py`](dist/screens/clusters.py) | 검증 화면 생성기 — `many` (일반 · grow 0) · `stack2` (좁은 atlas 를 채움) · `overflow` (17 화면 누적 · 8192² 상한) · `mini` (프레임 수 계측) |

```sh
python3 dist/screens/clusters.py many > /tmp/many.sh && chmod +x /tmp/many.sh
git worktree add /tmp/wt-main main && (cd /tmp/wt-main && zig build -Doptimize=ReleaseFast -Dsimd=true)   # 기준판
zig build -Dmacos-sign-identity=TildazLocal -Doptimize=ReleaseFast -Dsimd=true                             # 수정판
dist/macos/render-ab-shot.sh /tmp/many.sh 88x33 5 /tmp/wt-main/zig-out/TildaZ.app zig-out/TildaZ.app      # 정적 → 0 px
dist/macos/render-process-check.sh zig-out/TildaZ.app /tmp/many.sh 88x33 30 0.03                          # 과정 → 전부 0
```

- **기준판은 별도 worktree 에서 빌드해요.** `.zig-cache` 를 나누지 않으면 두 판의 바이너리가 같아져
  "0 차이" 가짜 통과가 나요. 스크립트가 md5 를 찍어 주니 다른지 봐요.
- **픽셀 수는 `-compose difference` + `-threshold 0` 로 세요.** `magick compare -metric AE` 는 소수 ·
  지수 표기를 내서 (Linux 회차가 실측으로 걸렸어요) 행별 합이 안 맞아요.
- **픽셀 대조에는 로그의 계수도 같이 봐요** — `atlas full` 회수가 `pack fail` 같은 원인 로그 회수와
  맞는지. #585 에서 pass 구간화 시절 잔재 코드가 4,096 인스턴스마다 atlas 를 비우며 우연히 그림을 지켜
  `0 px` 가 났고 (`atlas full` 1,060 회 vs 원인 3 회 — 거짓 full), 잔재를 지우자 5.5 % 어긋났어요.
  임시 · 잔재 코드를 지운 뒤에는 **반드시 다시 견줘요.**
- **atlas 안전망 경로를 강제로 돌리려면** `MAX_ATLAS_SIZE = INITIAL_ATLAS_SIZE` (예 1024) 로 빌드한
  판을 `INITIAL = 4096` (그 화면으로 안 넘침) 판과 견줘요 — 안전망이 정확하면 `0 px` 예요. 상수는 끝나면
  되돌리고 `git diff` 로 확인해요.
- **과정 캡처의 첫 장이 최종과 크게 다르면 "present 전 투명 창" 인지 먼저 가르세요** — 배경색
  `srgba(0,0,0,0)` · 배경 아닌 픽셀 0 이면 아직 아무것도 안 그린 거예요 (안전망이 GPU 를 여러 번 기다리는
  판은 첫 present 가 늦어요). 스크립트가 그 판정을 함께 찍어요.
- **"한 프레임 늦음" 은 캡처로 못 가르세요** — 캡처 간격 20~50 ms 가 60 Hz 한 프레임 (16 ms) 보다
  길어요 (main 의 2-frame 지연도 30 장 전부 0 이었어요). 대신 perf 종료 덤프의 `render calls` (프레임당
  1) 를 봐요 — `clusters.py mini` 가 스스로 끝나는 화면이라 `atexit` 덤프가 남아요 (`pkill` 로 내리면
  덤프가 없어요). 출력이 크면 여러 프레임에 걸쳐 도착해 ±2 노이즈가 나니 작은 화면으로 **3 회 반복**하고,
  구조로 확실한 것과 수치로 보인 것을 갈라 적어요 (#591 2 단계는 기대한 −1 프레임이 수치로 안 보였어요).
- **사용자에게 보여 줄 창은 서명 빌드를 `open` 으로 띄워요** — `zig build -Dmacos-sign-identity=TildazLocal …`
  뒤 `open -n -a zig-out/TildaZ.app --args --instance 9`. 바이너리를 직접 실행하면 TCC 권한이 안 맞아
  안내 다이얼로그가 뜨고 키 입력이 막혀요 (아래 `# 실행 환경` 의 같은 규칙 — 2026-09-02 에 또 걸렸어요).
  캡처만 하는 무입력 회차는 직접 실행도 동작해요.
- **화면이 잠겨 있으면 캡처가 전부 실패해요** (`Display 1 Shield`). 사용자가 자리를 비우면 30 분
  넘게 이어지니 `ioreg -n Root -d1 -r | grep -c CGSSessionScreenIsLocked` 가 0 이 될 때까지 백그라운드로
  기다리고, 그동안 캡처가 필요 없는 일 (빌드 · 문서) 을 먼저 해요. `caffeinate -disu` 는 검증 동안만 켜요.
- 도구는 `--instance 9` 로만 띄우고 내릴 때도 `pkill -f "tildaz --instance 9"` 로 **그 인스턴스만** 잡아요
  (`pkill -x tildaz` 는 사용자의 instance 0 도 죽여요 — #583 A12). 실기라서 `# 실행 환경` 대로
  **시작 전에 창이 몇 번 뜨는지 알리고** 그동안 키 · 마우스를 건드리지 말라고 해요.

# macOS — 합성 입력으로 마우스 보고 · dead key 를 자동 검증하는 법

사람 손 없이 `cliclick` 으로 클릭 · 키를 보내 판정하는 도구 둘이에요 ([#583](https://github.com/ensky0/tildaz/issues/583) A3 · A4).

| 도구 | 무엇 |
|---|---|
| [`dist/mouse/mouse-auto-check.sh`](dist/mouse/mouse-auto-check.sh) | `mouse-probe.sh --log` 를 띄우고 셀을 눌러 `?1005` · `?1015` · `?1016` 같은 형식의 바이트 형태를 판정 |
| [`dist/macos/deadkey-check.sh`](dist/macos/deadkey-check.sh) | 입력 소스 ABC 에서 Option+e · e → `é` (c3 a9) 가 들어오는지 |

- **창 위치는 `dist/macos/color-capture --list` 의 위치 열**에서 읽어요 — Accessory 앱은 AX 의
  `position of window` 가 창을 못 찾고 (`유효하지 않은 인덱스`), JXA 의 `CGWindowListCopyWindowInfo`
  는 CFArray 를 풀지 못했어요. 그래서 우리 도구에 열을 더했어요 (크기 뒤 · 제목 앞 — 앞 열로 읽는
  스크립트가 그대로 맞아요).
- **화면이 잠겨 있으면 클릭 · 키가 잠금 화면으로 가요.** 프로브는 떠 있고 캡처도 되는데 로그만 비어
  있어서 원인을 못 짚어요 — 2026-09-02 에 한 회차를 통째로 버렸어요 (창 목록에 `com.apple.loginwindow`
  30000×30000 이 클릭점을 덮고 있었어요). 두 스크립트가 시작 전에 `CGSSessionScreenIsLocked` 와
  합성 입력 전달 (`cliclick m:` 뒤 `p` 로 위치 확인) 을 먼저 봐요. 회차 동안 `caffeinate -disu` 를 켜요.
- 비활성 창의 **첫 클릭은 창을 깨우는 데 쓰일 수 있어** (`acceptsFirstMouse`) 두 번 눌러요 — 두 번째가
  판정 대상이에요. 키는 창을 클릭해 key window 로 만든 뒤, 무해한 `arrow-right` 하나를 먼저 보내요.

# macOS — 키보드 layout 조회 실측 방법

단축키를 **라벨**로 매칭할지 **위치**로 매칭할지 ([#496](https://github.com/ensky0/tildaz/issues/496) 항목 2) 를 다룰 때, 활성 keyboard layout 이 **어느 키에 어느 글자를 두는지** 실기로 재는 도구예요. [`dist/macos/layout-probe.m`](dist/macos/layout-probe.m) 이 keycode `0..127` 을 네 방식으로 번역해 나란히 덤프해요.

```sh
clang -fobjc-arc -framework AppKit -framework Carbon -framework CoreGraphics \
      -framework CoreFoundation -o /tmp/layout-probe dist/macos/layout-probe.m
/tmp/layout-probe                          # 현재 layout 전체 표 + dlopen 판정
/tmp/layout-probe --list-sources French    # 설치된 입력 소스의 표시 이름 · ID · 추가 여부
/tmp/layout-probe --watch-runloop 15 24    # 한 프로세스로 24 회 — 그 사이 입력 소스를 바꿔요
```

**실측으로 확정된 네 경로** (2026-08-25 · MacBook Pro M5 Pro · macOS 26.6.2 · SDK 26.5 — [#496 코멘트](https://github.com/ensky0/tildaz/issues/496#issuecomment-5402521698)):

| 경로 | live layout 추종 | dead key | Carbon |
|---|---|---|---|
| (A) `TIS*` + `UCKeyTranslate` | ✅ | ✅ | 링크 필요 |
| (B) HIToolbox `dlopen` | ✅ | ✅ | 불필요 |
| (C) `CGEventKeyboardGetUnicodeString` | ❌ **프로세스 시작 시점에 고정** | ❌ 빈 문자열 | 불필요 |
| (D) `NSEvent charactersByApplyingModifiers:` | ✅ | ✅ | 불필요 |

`UCKeyTranslate` 는 HIToolbox 가 아니라 **CoreServices/CarbonCore** 에 있어요 (`dladdr` 로 확인). Carbon 링크가 필요한 건 `TIS*` 계열뿐이에요.

**함정 네 가지 — 빠뜨리면 반대 결론이 나와요.**

- **단발 실행으로는 "layout 고정" 을 못 재요.** 매 회가 새 프로세스라 항상 최신으로 보여요. `--watch-runloop` 로 **한 프로세스를 살려 둔 채** 입력 소스를 바꿔야 드러나요.
- **run loop 를 안 돌리면 `TIS` 도 낡은 layout 을 봐요.** `TISCopyCurrentKeyboardLayoutInputSource` 를 매 호출마다 새로 불러도 그래요 — `sleep` 으로 기다린 프로세스는 10 분 내내 시작 시점 layout 을 냈어요. 앱은 AppKit run loop 가 있어 해당 없지만, 진단 도구에서는 오판의 원인이에요.
- **경로 D 는 modifier keycode 에서 죽어요.** `0x36`–`0x3F` (`kVK_RightCommand` ~ `kVK_Function`) 를 넘기면 헤더 서술(*"will return nil"*) 과 달리 `NSAssertionHandler` 를 거쳐 `abort()` 예요. 쓴다면 걸러야 해요.
- **SDK 헤더가 ISO-8859 라 `grep` 이 조용히 실패해요.** `TextInputSources.h` 를 `grep` 하면 **에러 없이 매치 0 건**으로 나와요. `iconv -f ISO-8859-1 -t UTF-8` 로 바꿔서 읽어요.

**입력 소스 전환은 사용자가 직접 해야 해요.** 한국어 UI 는 설정 앱의 항목 이름이 영어 문서와 달라 보이니, `--list-sources` 로 **그 기기에 실제로 표시되는 이름**을 뽑아서 안내해요 (예: `Russian – Phonetic` 이 이 기기에서는 `Russian – QWERTY` 로 보였어요). 그리고 이 측정도 위 `# 실행 환경` 의 규칙대로 **시작 전에 알리고 확인을 받아요.**

# Windows — 렌더 결과를 픽셀로 검증하는 법

macOS (`dist/macos/render-ab-shot.sh`) · Linux (`dist/linux/render-ab-shot.sh`) 와 같은 일을 PowerShell 로 해요 —
[`dist/windows/render-ab-shot.ps1`](dist/windows/render-ab-shot.ps1). 여러 판을 **같은 화면**으로 띄워 창을 찍고 최종
그림을 픽셀 수로 견줘요. [#586](https://github.com/ensky0/tildaz/issues/586) Windows atlas `grow` 실기에서 만들었고,
[#584](https://github.com/ensky0/tildaz/issues/584) Windows 계측이 밟은 함정을 피해 둔 상태예요.

```powershell
python dist\screens\clusters.py stack2 --cmd $env:TEMP\stack2.txt > $env:TEMP\stack2.cmd   # 화면 (.cmd 래퍼 + UTF-8 본문)
# 판마다 INITIAL_ATLAS_SIZE 만 바꿔 빌드하고 exe 를 한 폴더에 모아요 — **_internal 폴더도 그 옆에 복사**해요 (아래)
dist\windows\render-ab-shot.ps1 -Screen $env:TEMP\stack2.cmd -Size 150x40 -Wait 8 -Tag stack2 `
    -Bins $env:TEMP\bins\tildaz-4096.exe,$env:TEMP\bins\tildaz-2048.exe,$env:TEMP\bins\tildaz-512.exe
dist\windows\render-ab-shot.ps1 … -NewTab        # Ctrl+Shift+T 를 합성 입력으로 보내 탭 2 개 화면 (탭바 · 아이콘) 을 찍어요
```

- **판 exe 를 다른 폴더로 옮기면 `_internal` (conpty.dll · OpenConsole.exe) 도 함께** 옮겨요. 없으면 앱이 `TildaZ — Cannot
  Start` fatal 다이얼로그를 띄우고, 하네스는 **그 다이얼로그를 창으로 잡아 찍어요** (870x968 짜리 캡처가 나오면 이거예요).
  하네스가 로그의 `[fatal]` 줄을 함께 찍어 주니 판 줄 아래를 봐요. 2026-09-03 첫 회차에서 걸렸어요.
- **`clusters.py` 는 `--cmd <본문.txt>` 로** 불러요 — Windows 에는 `sh` 가 없어요. 본문을 UTF-8 (BOM 없음) 로 쓰고
  stdout 에 `.cmd` 래퍼 (`chcp 65001` → `type` → `timeout` 대기) 를 내요. 그 전에는 stdout 이 cp949 라 결합 기호에서
  `UnicodeEncodeError` 로 죽었는데, 스크립트가 stdout 을 UTF-8 로 고정해 `PYTHONUTF8` 없이도 돌아요.
- **`-e` 회차는 config 를 만들지도 hotkey 를 등록하지도 않아요** (`global hotkey not registered (stress run)`) — 사용자의
  `F1` 과 충돌하지 않고 `config_9.toml` 도 남지 않아요. 로그는 `%APPDATA%\tildaz\tildaz_stress.log` 예요. 단축키가
  필요한 회차 (`-NewTab`) 만 `config_0.toml` 을 복사해 `config_9.toml` 을 잠깐 만들고 (`auto_start = false`) 끝나면 지워요.
- **창은 `EnumWindows` + pid + 보이는 · 크기 있는 조건으로** 찾아요. `Process.MainWindowHandle` 은 `TildaZOwner` (0x0)
  가 owner 로 달린 진짜 창을 건너뛰어 0 이고, `FindWindow(class)` 는 그 0x0 창을 집어요 (#584).
- **PowerShell 은 DPI 비인식**이라 `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)` 를 먼저 불러요. 안 하면
  `GetWindowRect` 가 논리 좌표를 줘서 150 % 화면의 1272x989 창이 848x659 로 잡혀요.
- **캡처는 `PrintWindow(PW_RENDERFULLCONTENT)`** 예요 — 가려져 있어도 되고 창 그림자가 안 들어가요. 단색이면 (아직 안
  그렸거나 창이 닫혔거나) `CopyFromScreen` 으로 한 번 물러서고, 어느 쪽이었는지 판 줄에 적어요.
- **픽셀 수는 `LockBits` 로 직접 세요.** ImageMagick 이 없어도 되고, 다른 픽셀의 **경계 상자**를 같이 찍어 주니 커서
  자리 (`14x29`) 처럼 좁은 차이인지 한눈에 갈려요. 픽셀 대조에는 로그의 `atlas grew` · `atlas full` 회수도 같이 봐요.
- 인스턴스 9 만 내려요 — `Win32_Process` 의 `CommandLine` 에 `--instance 9` 가 있는 `tildaz*` 만. 판 바이너리 이름이
  `tildaz-4096.exe` 처럼 달라도 잡혀요.
- 실기라서 `# 실행 환경` 대로 **시작 전에 창이 몇 번 뜨는지 알리고 동의를 받아요.** `-NewTab` 은 합성 키라 특히요.
  그리고 **한 회차를 먼저 돌려** 창 크기 (1272x989 @ 88x33 · 150 %) · `render_path=hardware` · 캡처가 실제 그림인지
  (PNG 을 열어 봐요) 를 확인하고 전체를 돌려요.
- **`grow` 회수 기대표를 판정에 쓰지 말아요 — 최종 그림 `0 px` 과 `atlas full` 0 으로 판정해요.** 두 가지 이유예요.
  ① 150 % 의 `cell 14x29` 에서는 `stack2` 6,000 종이 2048² 에 들어가 기본 판이 `grow` 0 이에요 (Linux `14x31` 과 같고
  macOS `19x39` 와 달라요) — 기본 판의 `grow` 는 `overflow` (17 화면 누적 · `-Wait 15` 이상) 로 봐요. ② `overflow` 의
  누적 종 수는 **회차마다 달라요** (8192 로 커진 시점의 `clusters` 가 22,043 · 23,916 · 25,319) — Windows 는 화면이 바뀔
  때만 그려서 빠른 스크롤의 중간 화면을 건너뛰어요. 4096 판이 같은 화면에서 `grow` 0 인 회차가 실제로 있었어요.
- **`-e` 회차의 새 탭도 같은 `-e` 명령을 다시 실행해요.** `-NewTab` 으로 `Ctrl+Shift+T` 를 보내면 Tab 2 가 화면을 처음부터
  다시 뿌리고 (그동안 Tab 1 도 계속 출력), 캡처는 Tab 2 의 최종 화면 + 탭바예요. 대조에는 지장이 없지만 대기를 화면 출력
  시간만큼 넉넉히 둬요 (`overflow` 는 18 초로 돌렸어요).
- 탭 atlas 의 UV 정규화 (#586 W-a) 를 가르려면 **본문 atlas 가 탭 atlas (2048) 보다 커진 뒤 탭바를 그린 화면**이어야 해요 —
  `stack2` 는 512 판도 2048 에서 멈춰 조건이 안 돼요. `overflow` + `-NewTab` 을 **main 판** (고정 2048 + 안전망) 과 견줘요.
  grow 판끼리는 같은 코드라 함정을 스스로 못 가르니까요 (2026-09-03 실측 `0 / 2,640,760 px`).

# Windows — 합성 입력으로 dead key · launcher 실패를 자동 검증하는 법

macOS 의 `deadkey-check.sh` 에 대응하는 도구 둘이에요 ([#583](https://github.com/ensky0/tildaz/issues/583) A2 · A3 의 Windows 몫).
둘 다 `--instance 9` 또는 launcher 로 앱을 한 번 띄우고 끝나면 만든 것을 스스로 지워요. 실기라서 `# 실행 환경` 대로
**시작 전에 알리고 동의를 받아요** — 합성 키가 나가고 세션 layout 목록 · `config_9.toml` 이 잠깐 바뀌어요.

| 도구 | 무엇 |
|---|---|
| [`dist/windows/deadkey-check.ps1`](dist/windows/deadkey-check.ps1) | US-International (`00020409`) 을 올리고 `'`+`e` 등 네 케이스를 `SendInput` 으로 쳐 자식이 받은 UTF-8 바이트로 판정 (#494) |
| [`dist/windows/launcher-fatal-check.ps1`](dist/windows/launcher-fatal-check.ps1) | TOML 이 깨진 `config_9.toml` 을 두고 인자 없는 `tildaz.exe` (launcher) 를 띄워 `TildaZ failed to start` 다이얼로그가 뜨고 닫으면 exit 0 인지 (#577 의 `showFatalRunError(rt, …)` 자리) |
| [`dist/windows/kitty-text-check.ps1`](dist/windows/kitty-text-check.ps1) | kitty keyboard protocol 을 flags 11 · 1 로 켠 채 `a` · `Shift+a` · `Space` · `Enter` · dead key · `Shift` 단독 · `Ctrl` 단독 (flags 11 만 — #606 의 `CSI 57441;2u`) 을 쳐 **앱이 PTY 에 쓴 바이트**를 판정 (#602). 자식 (Python) 이 `ENABLE_VIRTUAL_TERMINAL_INPUT` 으로 raw 바이트를 받는다 — `Read-Host` 로는 `CSI u` 를 볼 수 없다 |

```powershell
dist\windows\deadkey-check.ps1 -Bin zig-out\bin\tildaz.exe          # 창 1 회 · 합성 키 · layout 잠깐
dist\windows\launcher-fatal-check.ps1 -Bin zig-out\bin\tildaz.exe   # 다이얼로그 1 회 · config_9 잠깐
```

- **layout 은 활성화하지 않고 (`LoadKeyboardLayoutW(klid, 0)`) 창 하나만 전환해요** — `WM_INPUTLANGCHANGEREQUEST` 를 tildaz 창에
  `PostMessage` 하면 `DefWindowProc` 이 **그 스레드**의 layout 만 바꿔요. 우리 셸도 사용자의 다른 창도 그대로예요. 바뀌었는지
  `GetKeyboardLayout(thread)` 로 확인하고 안 됐으면 키를 보내지 않아요. `LoadKeyboardLayoutW` 의 부작용 (세션 목록에 남아
  `Win+Space` 에 나타남) 은 끝에 `UnloadKeyboardLayout` 으로 내리고 `GetKeyboardLayoutList` 를 전후로 찍어 확인해요 (위
  `# Windows — 키보드 layout 조회 실측 방법` 의 같은 주의).
- **자식은 `Read-Host` 로 줄을 받아요** — Windows 에는 `cat` 이 없어요. `-e` 가 명령줄을 통째로 `CreateProcessW` 에 넘기므로
  `powershell -File <자식.ps1> <out> <N>` 처럼 인자도 그대로 가요 (#584 에서 확인). 자식이 N 줄을 받고 끝나면 앱도 끝나
  정리가 자동이에요. 자식 PowerShell 이 `Read-Host` 에 닿기 전에 보낸 키는 콘솔 입력 버퍼에 남아 있다가 읽히지만, 2 초는 둬요.
- **키마다 포커스 가드**예요 (`dist/stress/send-keys.ps1` 과 같은 규칙) — foreground 가 tildaz 창이 아니면 멈춰요. 합성 키는
  포커스된 창으로 가니 회차 동안 사용자가 다른 창을 만지면 거기에 타이핑돼요.
- **앱의 error 다이얼로그는 `MessageBox` (`#32770`) 가 아니에요** — `dialog/windows.zig` 의 자체 창
  `TildaZScrollableDialogWindow` 이고 본문을 직접 그려 자식 컨트롤로는 제목 Static 과 OK Button 만 보여요. 본문 문구는
  **캡처 (PrintWindow) 와 로그** (`tildaz_0.log` 의 `[fatal] run failed: <err>`) 로 확인해요. 첫 회차에 `#32770` 을 기대해
  거짓 FAIL 이 났어요 (2026-09-03).
- **launcher 단독 실패를 만드는 법은 "깨진 TOML 의 `config_9.toml` + 인자 없는 실행"** 이에요. `runLauncher` 가 spawn 전에
  모든 index 의 config 를 `configAutoStart` 로 읽고 파서 오류를 그대로 전파하므로 worker 는 뜨지도 않아요 — worker 가 다이얼로그를
  띄우는 경로 (macOS 2026-09-02 회차) 로는 이 자리를 못 가르니까요. 그 실패는 `autostart.enable/disable` **앞**이라 사용자의
  자동 시작 설정도 떠 있는 instance 0 도 그대로예요. 다만 launcher 는 `tildaz_0.log` 에 `[fatal]` 한 줄을 남겨요. `config_9.toml`
  이 이미 있으면 도구가 시작을 거부해요 — 사용자 설정을 덮지 않아요.
- **`deadkey-check.ps1 -Capture`** 는 dead key 직후와 조합 직후 창을 찍어 preedit 색 (`64,64,128` · ±2) 픽셀을 세요 — #530 의
  Windows 표시 판정이에요 (기대 `>0` → `0`). 2026-09-03 실측 374 → 0.
- **PowerShell 은 원소가 하나인 배열을 평탄화해요** — `@(@($Shift, $A))` 는 `@(16, 65)` 가 되어 chord 가 **키 두 개를 따로**
  누르는 것으로 바뀌어요 (2026-09-03: `Shift+a` 가 `a` 로 나와 앱 결함으로 보일 뻔했어요). chord 는 `,@(…)` (단항 콤마) 로
  감싸요. 원소가 둘 이상인 배열은 그대로 남아서 `deadkey-check` 의 `Shift+6` 은 우연히 살아남았어요.
  **`switch` 의 출력도 같아요** — `$seq = switch ($n) { 2 { @(,$chord) } }` 는 파이프라인을 지나며 풀려 `@(17, 16, 39)` 가
  돼요 (2026-09-03 `split-panes.ps1` — pane 2 회차 5 회가 전부 분할 실패). 블록 안에서 `$seq = ,$chord` 로 **직접 대입**해요.
  단항 콤마 · 직접 대입 뒤에는 `$seq.Count` 와 `$seq[0] -is [array]` 를 한 번 찍어 보고 시작해요.
- **다른 창이 tildaz 창을 덮고 있으면 `SetForegroundWindow` 도 창 중앙 클릭도 안 닿아요** — 사용자가 브라우저를 앞에 두고
  머지하던 회차에서 포커스 가드가 막았어요. 도구들은 잠깐 `HWND_TOPMOST` 로 올려 활성화하고 끝나면 내려요.
- **`ToUnicodeEx` 는 상태 불변 플래그 (bit 2) 로 부르면 dead key 에도 글자 (`'`) 를 돌려줘요** — 반환값으로 dead key 를
  가를 수 없어요. 그래서 `report_all` 에서 dead key 누름도 인코더로 가 `CSI 39 u` 가 나가요 (kitty 도 dead key 누름을 보고하니
  무해) — 다만 그때 세운 "짝꿍 `WM_CHAR` 삼킴" 은 `WM_DEADCHAR` 가 소비해야 다음 글자가 안 삼켜져요 (#602 2 회차에서 `é` 가
  사라졌던 원인).
- **화면 보호기가 켜져 있으면 foreground 창이 없고 합성 키는 화면 보호기로 가요.** 실기 전에 `SystemParametersInfo
  (SPI_GETSCREENSAVERRUNNING)` 과 `GetForegroundWindow` 를 봐요 — 사용자 부재 중에는 돌리지 않아요.
- **자식 (PTY 안 python) 이 죽으면 창도 곧 사라져 "포커스 못 잡음" 으로 보여요.** 자식 코드를 heredoc · python 으로 편집하면 `
` 이 실제 개행으로 바뀌어 문법이 깨질 수 있어요 (2026-09-03 — #606 도구 편집). 도구는 자식 코드를 `py_compile` 로 먼저 검사하고, 자식은 항목마다 파일을 다시 쓰며 예외를 `<out>.err` 에 남겨요 — "결과 파일 없음" 이 아니라 **어느 항목이 비었는지** 가 보여야 원인을 가를 수 있어요.
- **`Start-Process -RedirectStandardError` 로 앱을 띄우면 새 창이 포커스를 못 받아요** (같은 날 실측 — 두 회차 모두 "포커스 못 잡음"). 앱 로그가 필요하면 `%APPDATA%	ildaz	ildaz_<instance>.log` (stress 인스턴스 9 는 `tildaz_stress.log`) 를 읽어요 — `log.appendLine` 이 거기 써요.
- **`$VK.<이름>` 오타 · 누락은 `$null` → VK 0 으로 조용히 눌려요.** 앱에는 `wParam=0 scan=0` 으로 도착해 아무 바이트도 안 나와요 — "앱이 안 낸다" 로 보이지만 도구 표를 먼저 봐요 (2026-09-03 `Ctrl` 이 그랬어요).

# Windows — 키보드 layout 조회 실측 방법

위 macOS 절과 같은 물음을 Windows 에서 재는 도구예요. [`dist/windows/layout-probe.zig`](dist/windows/layout-probe.zig) 가 scancode `0x01`..`0x58` 을 layout 별로 한 표에 덤프해요 — VK (`MapVirtualKeyExW`) · 라벨 base/shift/AltGr (`ToUnicodeEx`) · 역방향 (`VkKeyScanExW`).

```powershell
zig build-exe dist/windows/layout-probe.zig -O ReleaseSafe --cache-dir C:/ziglang/tildaz-cache
.\layout-probe.exe                       # 전체 표 + 판정 + 경계값. 덤프 파일도 함께 써요
.\layout-probe.exe --watch 60            # 창을 띄우고 60 초 — 그 사이 입력 언어를 바꿔요
.\layout-probe.exe --only 0000040c       # 한 layout 만 올려서 hkl=NULL 의 뜻을 가려요
.\layout-probe.exe --unload-session      # 앞선 실행이 세션에 남긴 layout 을 치워요
```

**macOS 보다 유리한 점 — 전환 없이 여러 layout 을 한 번에 재요.** `LoadKeyboardLayoutW("0000040C", 0)` 로 얻은 `hkl` 을 위 API 에 넘기면 돼요. 그 값이 *실제 활성 layout* 과 같은지는 `--watch` 로 한 번 대조해요 (실측에서 일치했어요).

**실측으로 확정된 것** (2026-08-25 · 노트북 i5-1240P · Windows 11 Education 10.0.26200 · zig 0.16.0 — [#496 코멘트](https://github.com/ensky0/tildaz/issues/496)):

| | Windows 의 매칭 기준 |
|---|---|
| 문자 키 · 라틴 layout | **라벨** — AZERTY 에서 sc `0x1E` 가 `VK_Q` |
| 문자 키 · 비라틴 layout | **US 위치** — Russian sc `0x11` 이 `VK_W`. 그래서 라틴 fallback 이 필요 없어요 |
| **기호 키** | **layout DLL 이 배정하는 슬롯** — 라벨도 위치도 아니에요. `VK_OEM_3` 이 US `0x29` · FR legacy `0x28`(`ù`) · German `0x27`(`ö`) 로 **자리가 움직여요** |
| 한국어 · 일본어 | layout DLL 수준에서는 **그냥 US QWERTY** (라틴 26/26). macOS 와 정반대예요 |

**함정 넷 — 빠뜨리면 반대 결론이 나와요.**

- **`hkl = NULL` 이 두 API 에서 뜻이 달라요.** `MapVirtualKeyExW` 는 *마지막에 로드한* layout 을, `ToUnicodeEx` 는 *활성* layout 을 써요. 섞으면 vk 는 A layout, 라벨은 B layout 인 표가 나와요. **항상 `GetKeyboardLayout(0)` 을 명시해요.**
- **`LoadKeyboardLayoutW` 의 부작용이 프로세스보다 오래 살아요.** 올린 layout 은 프로세스가 죽어도 세션에 남고, `Get-WinUserLanguageList` 에는 안 보이지만 **`Win+Space` 전환 목록에는 나타나** 측정 중 사용자의 입력 전환을 바꿔요. 프로브가 끝에 되돌리고 `--watch` 는 아예 로드하지 않지만, 중단된 실행 뒤에는 `--unload-session` 으로 확인해요.
- **`ToUnicodeEx` 의 dead key 오염은 `wFlags` bit 2 로 막아요.** 빼면 FR 의 dead `^` 다음 글자가 `î` 로 오염돼요. macOS 경로 C 가 같은 병으로 탈락했는데 Windows 에는 문서화된 해법이 있고 실제로 들어요.
- **layout 은 스레드별이라 백그라운드 창은 전환을 즉시 못 받아요.** 남의 창에서 바꾸면 우리 스레드 값은 그대로고, **포커스를 얻을 때** `WM_INPUTLANGCHANGE` 로 통보돼요 (실측: 26 초 동안 안 바뀌다가 창을 클릭하자 바뀌었어요).

**입력 언어 추가와 전환은 사용자가 직접 해야 해요.** 한국어 UI 는 항목 이름이 영어 문서와 다르니 레지스트리(`HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layouts\<KLID>` 의 `Layout Display Name` 을 `SHLoadIndirectString` 으로 푼 값)로 **그 기기에 실제로 표시되는 이름**을 먼저 뽑아서 안내해요 — Windows 11 은 French 가 `프랑스어(레거시, AZERTY)`(`0000040C`) 와 `프랑스어(표준, AZERTY)`(`0001040C`) 로 갈려 있고 **`²` 는 레거시에만** 있어요. 이 측정도 위 `# 실행 환경` 의 규칙대로 **시작 전에 알리고 확인을 받아요.**

**tildaz 본체를 함께 검증할 때는 `--instance 9` 로 띄워요.** 사용자의 `config_0` 을 건드리지 않고 별 config 로 테스트할 수 있어요. 그 config 에 **`auto_start = false`** 를 넣고, 끝나면 `config_9.toml` · `tildaz_9.log` · `instance9*` 를 지워요 — 안 지우면 사용자 로그온 때 그 인스턴스가 같이 떠요.

# 전역 hotkey 의 위치 표기 검증 — 데스크톱마다 받는 것이 다르다

`hotkey = "ctrl+[Backquote]"` 같은 **위치 표기** ([#496](https://github.com/ensky0/tildaz/issues/496) 1-c) 는 데스크톱마다 등록 방식이 갈려요. 자리를 그대로 받는 곳, 그 자리가 *지금 내는 글자* 로 바꿔야 하는 곳, VK 로 바꿔야 하는 곳이 있어서 **한 환경에서 통과해도 다른 환경을 보장하지 못해요.** 그래서 어느 머신에서든 같은 절차로 돌리는 도구를 뒀어요.

```sh
./dist/hotkey/position-hotkey-check.sh                  # 기본 ctrl+[Backquote]
./dist/hotkey/position-hotkey-check.sh --hotkey 'ctrl+[KeyT]'
./dist/hotkey/position-hotkey-check.sh --keep           # 남겨 두고 직접 눌러 볼 때
```

`--instance 9` 로만 돌고 (사용자의 일상 인스턴스를 안 건드려요) 끝나면 만든 것을 스스로 지워요 — config · 로그 · KDE (D-Bus) · GNOME/Cinnamon (dconf 항목 **과 목록**) · COSMIC (RON 줄).

| 데스크톱 | 받는 것 | 기대값 (`[Backquote]`) |
|---|---|---|
| sway · Hyprland | **자리** | `49` = evdev 41 + 8 (`bindcode 49` · `keycode=49`) |
| GNOME · Cinnamon | **자리** | `0x31`. 확장이 켜져 있으면 **확장이** `grab_accelerator("<Control>0x31")`, 없으면 gsettings `binding=<Control>0x31` |
| KDE · COSMIC | **그 자리가 지금 내는 글자** | us `` ` `` · fr `²` · ru `Ё` · **de 는 등록 안 함** (dead key) |
| Windows | **자리** (raw scan code) | `0x29`. `RegisterHotKey` 가 아니라 `WH_KEYBOARD_LL` 훅으로 잡아요 — 아래 |
| macOS | 자리 (`kVK_*`) | 변화 없음 |

**Windows 는 `RegisterHotKey` 로 위치 표기를 담을 수 없어요 — 실측으로 확정.** 그 API 는 VK 만 받는데 VK 는 layout DLL 이 배정하는 값이라 자판마다 자리가 움직여요 (`VK_OEM_3` 이 US `0x29` · 프랑스어 legacy `0x28` · 독일어 `0x27`). 그래서 자리를 VK 로 한 번 풀어 등록하면 그 값은 *그 layout 에서만* 맞아요. 처음 구현은 그 파생값을 캐시하고 `WM_INPUTLANGCHANGE` 에서 다시 풀었는데, **숨은 채 layout 이 바뀌면 핫키가 다른 물리 키로 옮겨갔어요** (실측: `[Backquote]` 로 적었는데 `1` 왼쪽 키는 죽고 `'` 키가 창을 띄웠어요 — [#512 코멘트](https://github.com/ensky0/tildaz/pull/512#issuecomment-5412301433)). 그 메시지가 **스레드별이고 포커스를 얻을 때** 와서, 핫키가 먹어야 포커스를 얻고 포커스를 얻어야 갱신되는 순환이라 그 구조로는 창을 좁힐 수만 있고 닫을 수 없어요.

그래서 **위치 표기만 `WH_KEYBOARD_LL` 훅**으로 잡아요. `KBDLLHOOKSTRUCT.scanCode` 가 layout 이 개입하지 않은 raw 값이고 위치 표기가 뜻하는 것이 정확히 그 값이라, 변환도 캐시도 갱신도 없어져요. **라벨 표기는 계속 `RegisterHotKey`** 예요 — 라벨은 OS 가 keypress 시점에 layout DLL 로 풀어 주는 게 옳은 동작이고, 그래서 훅의 대가는 위치 표기를 쓴 사용자에게만 발생해요.

훅을 만질 때 지킬 것:

- **콜백에서 블로킹하지 않아요.** `LowLevelHooksTimeout` (기본 300 ms) 을 넘기면 **훅이 조용히 제거돼요** — 오류도 로그도 없이 핫키가 죽어요. 비교만 하고 실제 작업은 `PostMessageW(WM_HOTKEY)` 로 창의 메시지 큐에 넘겨요 (라벨 경로와 처리부가 하나로 남는 이점도 있어요).
- **modifier 는 `GetAsyncKeyState` 로 읽고 "요구한 것만" 을 확인해요.** 훅은 modifier 상태를 주지 않아요. `RegisterHotKey` 는 여분 modifier 가 있으면 발동하지 않으므로 (`Ctrl+Alt+X` 가 `ctrl+x` 를 안 잡아요) 그 규칙을 훅 쪽에서도 그대로 만들어야 두 표기가 같은 config 로 같게 동작해요.
- **injected 입력을 걸러내지 않아요** (`LLKHF_INJECTED`). `RegisterHotKey` 가 합성 입력에도 반응하므로 (실측) 맞춰요. 덕분에 `SendInput` 으로 핫키 검증을 자동화할 수 있어요.
- **`extended` 를 함께 비교해요.** `0xE0` prefix 가 없으면 control pad 와 numpad 가 같은 하위 바이트를 써서 섞여요 (`physical_key.zig` 헤더).

**⚠️ keymap 재전송을 잴 때 `xkb_config` 를 원자적으로 쓰지 않으면 없는 버그를 만들어요.**
`cat > xkb_config` 는 **truncate 후 write** 라, cosmic-comp 이 그 사이의 빈 파일을 읽고 기본값
`us` keymap 을 client 에 밀어넣어요. 그러면 "compositor 가 layout 전환 중에 US 를 끼워 보낸다"
는 없는 quirk 가 보여요 — [#513](https://github.com/ensky0/tildaz/issues/513) 조사에서 실제로
그것을 compositor 버그로 믿고 문서에까지 적었어요.

```sh
tmp=$XKB.tmp; cat > "$tmp" <<EOF … EOF; mv -f "$tmp" "$XKB"    # ✅ rename 은 원자적
cat > "$XKB" <<EOF … EOF                                        # ❌ truncate 순간을 읽혀요
```

**대조군은 `xkbcli` 로 둬요 — 커스텀 client 를 짤 필요가 없어요.** libxkbcommon 이 주는
도구라 우리 앱과 무관한 제3자 관측이에요.

```sh
xkbcli interactive-wayland --verbose        # 받은 keymap 마다 `Compiling xkb_symbols "<이름>"`
xkbcli dump-keymap --raw | wc -c           # 연결 시점 keymap 의 크기 (wl_keyboard 값보다 1 작음 — 종료 NUL)
```

- `--verbose` 의 symbols 이름이 **options 까지 담아요** (`pc_kr_inet(evdev)_group(alt_shift_toggle)_kr(ralt_hangul)_…`
  vs `pc_kr_inet(evdev)`). 그래서 크기 비교 없이도 어느 config 의 keymap 인지 갈려요.
- **판정은 layout *이름* 만으로 하지 않아요.** 앱 로그가 `size` 를 함께 남기는 이유예요 —
  options 만 달라도 크기가 달라지는데 (`kr` + korean options `35707` vs `kr` 단독 `35566`)
  `layouts=[…]` 는 둘 다 `Korean` 이에요.
- `/dev/uinput` 은 ACL 이 있으면 sudo 없이 열려요 (`getfacl /dev/uinput`).

**compositor 별로 keymap 을 언제 다시 보내는지는 회차마다 결과가 흔들려서 이 문서에 표로
적지 않아요.** 그건 durable 한 사양이 아니라 진행 중인 작업 기록이에요 — 회차별 조건과 결과는
[#513](https://github.com/ensky0/tildaz/issues/513) 에 있고, 거기서 읽어요. 이 문서에는 **재는
법과 함정**만 둬요 (위 원자적 쓰기 · `xkbcli` 대조군 · `size` 병기).

한 가지만 확정된 사실로 적어 둬요 — **cosmic-comp 의 핫플러그 keymap 되돌림은 간헐적이에요.**
그래서 "N 회 안 나왔다" 로 없다고 결론내지 말고, 재현 절차를 남에게 줄 때도 간헐적이라는 것을
함께 적어요.

**실측 완료** (2026-08-25):

| 환경 | 결과 | 기기 |
|---|---|---|
| KDE (KWin 6.7.4) | us · fr · ru · de + 해제/복구 왕복 | 미니PC Firebat ZY-A8 · CachyOS |
| sway 1.12 | `bindcode Ctrl+49` | 같은 기기 (nested) |
| Hyprland 0.56.2 | `keycode=49` | 같은 기기 (nested) |
| GNOME 50.4 | gsettings `<Control>0x31` + **확장 경로** `action != 0` · fr 단독에서 자리 유지 | 노트북 i5-1240P |
| COSMIC 1.0.0 | us `grave` · fr `twosuperior` · ru `Cyrillic_io` · de 거둠 · 복구 | 같은 노트북 |
| Cinnamon 6.6.9 (Muffin) | 확장 `<Control>0x31` grab · fallback gsettings `['<Control>0x31']` · fr · ru 단독에서 자리 유지 | 같은 노트북 |

**Windows · macOS 는 미검증이에요.**

**확장 경로는 `TILDAZ_VERBOSE=1` 로 계측 없이 관측해요.** GNOME · Cinnamon 의 확장은 창을 minimize/unminimize 로 토글하므로 앱이 남기는 lifecycle 로그가 없어요. verbose 를 켜면 `[wayland] drainSurfaceOutputs entered=[] …` (숨김) 과 `entered=[11 ] …` (복귀) 가 그대로 보여서, 확장에 로그를 심지 않고도 왕복을 확인할 수 있어요.

**GNOME 은 gsettings 가 주 경로가 아니에요.** tildaz 가 부팅 때 Shell extension 을 스스로 켜고 (`ensureShellExtensionReady`), 켜져 있으면 gsettings 등록을 건너뛰어요 (`extension active — gsettings hotkey skipped`). 그래서 **스크립트의 GSettings 조회가 `''` 인 것이 정상**이고, 그때의 근거는 셸 로그예요 (`journalctl --user -b -o cat | grep tildaz`). gsettings 값을 직접 보려면 확장을 끄고 `~/.local/share/gnome-shell/extensions/tildaz@ensky0.github.io` 를 옮겨 둬야 해요 (설치돼 있으면 tildaz 가 다시 켜요).

**함정 — 앞의 넷은 스크립트가 이미 피하고, 나머지는 손으로 잴 때 걸려요.**

- **`XDG_CURRENT_DESKTOP` 이 비면 등록 경로를 통째로 건너뛰어요.** tty · ssh 셸에는 대개 없고, 그러면 로그가 `de=(unset)` 이 되며 아무 데도 등록하지 않아요 — "등록이 안 된다" 로 오해하기 쉬워요.
- **config 를 만들려고 그냥 띄우면 기본값 `F1` 이 사용자의 instance 0 과 충돌해요.** 그 충돌 다이얼로그는 **모달이라 부팅을 막고** 로그가 빈 채로 남아요. `env -u XDG_CURRENT_DESKTOP` 으로 한 번 띄워 config 만 만든 뒤 hotkey 를 바꿔요. **`config_N.toml` 을 손으로 쓸 때는 `[keys]` 를 빼먹지 않아요** — 없으면 `missing required key "keys"` 로 같은 모달이 떠서 똑같이 부팅이 막혀요. `config_0.toml` 을 복사해 `hotkey` · `shell` · `auto_start` 만 바꾸는 게 안전해요.
- **`pkill -f 'instance 9'` 는 자기 명령줄을 매치해 셸을 죽여요** (그 문자열이 명령에도 들어 있어서요). `pgrep -x tildaz` 로 좁히고 `/proc/PID/cmdline` 에서 인자를 확인해요. 검증용으로 붙인 이름표 문자열 (`tildaz-530` 같은 임시 경로 · 태그) 도 똑같이 걸려요 — [#530](https://github.com/ensky0/tildaz/issues/530) 정리 단계에서 `pkill -f "tildaz-530"` 으로 셸이 죽었어요. **`pgrep -af <이름표>` 도 자기 명령줄을 매치해요** (KDE 회차에서 걸렸어요). `pgrep -x` 로 PID 를 뽑아 `kill <pid>` 해요.
- **layout 전환은 창을 띄우지 않고 해요.** Wayland 의 group 전환은 *포커스한 client* 에게만 가므로, 창을 띄우면 그 경로로 통과해 버려 D-Bus 통지 경로 (#496 1-c 의 ③) 가 검증되지 않아요.
- **uinput 으로 가상 키보드를 새로 꽂으면 keymap 이 잠깐 바뀌어요.** cosmic-comp 실측에서 장치를 만든 직후 client 가 받은 keymap 이 `grave` → `twosuperior` 로 두 번 왔고, 그 사이에 키를 보내면 **발동하지 않아 거짓 실패**가 나요. 장치를 만든 뒤 **5 초쯤 두고** 눌러요 (`SETTLE`).
- **⚠️ `ydotool mousemove -a` (절대좌표) 는 조용히 아무 일도 하지 않아요.** `ydotoold` 가 만드는 가상 장치는 `EV=7` (SYN · KEY · REL) 로 **`ABS` 축이 없어서** 절대좌표 이벤트가 그대로 버려져요 — 오류도 로그도 없고 `ydotool` 은 성공을 반환해요 (`/proc/bus/input/devices` 의 `B: EV=` 와 `capabilities/abs` 로 확인). 클릭이 안 먹는 것을 **좌표 계산 실수로 오인해** 시간을 씁니다. 상대 이동 (`ydotool mousemove` 기본) 과 키 (`ydotool key`) 는 정상이에요.

    포인터를 특정 자리에 놓아야 하면 **절대좌표 장치를 따로 만들어요** — `ABS_X` · `ABS_Y` (0..32767) + `BTN_LEFT` + `INPUT_PROP_POINTER` 로, QEMU USB 태블릿과 같은 모양이에요. 그러면 libinput 이 그 범위를 output 전체에 선형 매핑해서 **화면 물리 px 과 1:1** 이 돼요 ([#536](https://github.com/ensky0/tildaz/issues/536) 실측 — 계산한 컨트롤 스트립 좌표와 캡처가 정확히 일치). 장치는 **한 번만 꽂고** FIFO 등으로 명령을 받아요 (명령마다 add/remove 하면 위 항목의 keymap 흔들림을 매번 겪어요).

    - 상대 이동으로 버티려 하면 **포인터 가속에 왜곡돼요.** KDE 에서는 그 장치의 가속을 D-Bus 로 끌 수 있어요 (`org.kde.KWin.InputDevice` 의 `pointerAccelerationProfileFlat`) — 다만 그건 `kcminputrc` 에 `[Libinput][…][ydotoold virtual device]` 섹션으로 **남으니 끝나면 지워요.**
    - **좌표는 클릭 전에 hover 로 검증해요.** 메뉴 항목은 `menu_hover_bg` 가 있어서 캡처 한 장으로 어느 줄에 닿았는지 확정돼요. 컨트롤 스트립 (`+` · `×` · `⋯`) 은 hover 가 캡처에 안 잡힐 수 있어, 커서를 포함해 찍고 (`spectacle -p`) 커서 끝 위치로 봐요.
- **`fcitx5` 같은 text-input-v3 IME 가 떠 있으면 키가 앱의 xkb 경로로 오지 않아요.** IME 가 가로채 **자기 구현으로 조합한 뒤 commit** 하므로, 재고 있는 것이 앱 코드가 아니에요. **`fcitx5-remote -c` 로 영문 모드로 바꿔도 경로에서 빠지지 않아요** (fcitx5 에도 자체 Compose 가 있어요). 결과가 우연히 같아 보이는 케이스가 많아 눈치채기 어려워요 — [#494](https://github.com/ensky0/tildaz/issues/494) dead key 검증에서 이 때문에 세 케이스가 거짓 FAIL 로 나왔고, `pkill -x fcitx5` 뒤 전부 통과했어요 (끝나면 `setsid nohup fcitx5 -d &` 로 되돌려요). 판정은 앱 로그의 **`text_input preedit` · `text_input commit` 줄 개수**예요 — 케이스 구간에서 **0 이어야** 앱 자신의 경로를 잰 것이에요. IME 공존 자체를 보는 케이스는 반대로 띄운 채 재고, *조합 주체가 누구인지* 를 결과에 같이 적어요. **입력기에 따라 갈려요** — fcitx5 의 키보드 IM (`keyboard-us` · `keyboard-fr`) 은 fcitx5 가 조합하고, `hangul` 은 조합 중이던 한글을 확정한 뒤 **키를 앱으로 넘겨요** ([#530](https://github.com/ensky0/tildaz/issues/530) COSMIC · KDE 회차). 그 `text_input preedit/commit` 줄은 **`TILDAZ_VERBOSE=1` 게이트**라, verbose 없이 띄운 회차의 "0 줄" 은 IME 부재의 증거가 아니라 그냥 로그가 없는 거예요 — 조합 주체를 갈라야 하면 verbose 로 띄워요 (`dead-key-compose-check.sh` 는 켜 줘요). 그리고 **fcitx5 는 종료할 때 `~/.config/fcitx5/profile` 을 자기 메모리 상태로 덮어써요** — 켜진 채 파일을 고치고 나중에 내리면 편집이 되돌아가요. 순서는 내리기 → 고치기 → 띄우기, 복구도 같아요.
- **`xkbcli interactive-wayland` 는 포커스를 훔치고 안 돌려줘요.** 그 자체가 Wayland client 라, 측정 중에 띄우면 tildaz 의 **layer-shell 표면으로 포커스가 돌아오지 않아** 이후 케이스가 전부 "바이트 없음" 이 돼요 (dead key 가 아니라 평범한 문자 키까지요). 받은 keymap 을 밖에서 확인하는 데는 좋은 도구지만 **tildaz 를 띄우기 전에만** 써요. 띄운 뒤에는 앱 로그의 `keyboard keymap loaded … layouts=[…]` 와 **인앱 가드 키**로 확인해요 — `KEY_Q` 는 fr 에서 `a`, us 에서 `q` 라 한 키로 layout 이 되돌아갔는지 케이스마다 갈려요. 이미 걸렸으면 `tildaz --toggle 9` 두 번으로 회복돼요. **`xkbcli dump-keymap-wayland` 는 안 훔쳐요** — 붙자마자 keymap 을 뱉고 끝나서 tildaz 를 띄운 채로도 안전해요 (KDE 회차 실측). 배열 관련 케이스는 **재기 전에 이걸로 그룹별 기대값을 먼저 뽑아 둬요** — `key <AE02>` 의 `symbols[2]` 가 `[eacute, 2, asciitilde, oneeighth]` 처럼 나오니, 무엇이 나와야 맞는지를 측정 전에 확정할 수 있어요. 기대값 없이 재면 결과를 보고 나서 해석하게 돼 거짓 판정이 섞여요 ([#483 KDE 회차](https://github.com/ensky0/tildaz/issues/483#issuecomment-5459875149)).
- **실기 전에 유휴 잠금을 막아요** — `systemd-inhibit --what=idle:sleep --mode=block sleep infinity &` 를 먼저 걸고, 끝나면 그 PID 를 `kill` 해요. "기기를 건드리지 말아 달라" 는 부탁이 세션을 유휴로 만들어 **KDE 잠금 화면이 떴고 주입한 키가 암호 입력란으로 들어갔어요** ([#530 KDE 회차](https://github.com/ensky0/tildaz/issues/530#issuecomment-5434640115)). layout 이 fr 인 채로 잠기면 사용자가 암호를 제대로 못 치니 해제 전에 `setLayout 0` 으로 되돌려요. 자동 잠금 설정 자체 (`kscreenlockerrc`) 는 건드리지 않아요.
- **⚠️ 주입한 키는 "그때 포커스를 가진 창" 으로 가요 — 대상 창을 고를 수 없어요.** 측정 중에 사용자가 다른 창을 만지면 **그 창에 그대로 타이핑돼요**. [#483 KDE 회차](https://github.com/ensky0/tildaz/issues/483#issuecomment-5459875149) 에서 배열을 추가받는 동안 포커스가 옮겨간 걸 모르고 쳐서, 사용자의 대화창에 `cat -v > ~/kfr.txt` 와 `€` · `é` 가 들어갔어요 (위 잠금 화면 항목과 같은 뿌리예요). 그래서 **타이핑 전에 두 가지를 해요** — ① 창 안을 클릭해 포커스를 잡고, ② `touch ~/probe` 를 보내 **파일이 생기는지로 포커스를 확인**해요. 확인이 안 되면 한 글자도 보내지 않고 멈춰요. 그리고 **단계마다 앱이 살아 있는지 다시 봐요** — `Ctrl+Shift+W` 를 pane 수보다 많이 보내 앱이 스스로 끝난 뒤에도 계속 키를 보내다 타임아웃까지 갔어요 (`pgrep` 으로 확인하고, 죽었으면 중단해요).
- **GNOME 확장은 파일을 고쳐도 `disable`/`enable` 로 다시 안 읽어요.** ESM import 캐시라 셸이 새로 떠야 해요. 계측 로그를 심어 재려면 **nested 로 새로 띄워요** — 로그인 세션을 건드리지 않아요.
- **GNOME 50 은 `--nested` 가 없어요.** `gnome-shell --nested` 가 `Unknown option` 이고, 그냥 `--wayland` 만 주면 native backend 를 골라 `Failed to take control of the session: EBUSY` 로 끝나요. 지금 이름은 **`--devkit`** 이에요.

**KDE 에서 layout 전환하기.** 배열은 **시스템 설정 → 입력 장치 → 키보드 → 배열** 에서 먼저 추가해요 — `kxkbrc` 를 직접 고치면 KWin 이 재시작 전까지 안 읽어요 (`reconfigure` · `kcminit` 둘 다 무반응). **다른 세션에서 미리 고쳐 두는 우회도 안 돼요** — KWin 이 안 떠 있는 COSMIC 세션에서 `LayoutList=us,fr` 로 고쳐 두고 KDE 로 로그인했더니 **로그인 시점에 `LayoutList=us` 로 되돌려 쓰였어요** (2026-08-26 실측). GUI 로 추가하는 수밖에 없어요. 추가한 뒤에는 D-Bus 로 전환해요 — 그쪽은 문서대로 잘 돼요.

**⚠️ 그런데 fcitx5 를 되살리면 그 배열이 사라져요.** fcitx5 가 뜰 때 자기 group 의 `Default Layout`
(`~/.config/fcitx5/profile`, 한국어 사용자는 보통 `us`) 으로 **KDE 의 배열 목록을 덮어써요** —
`kxkbrc` 의 `LayoutList=us,fr` 가 `LayoutList=us` 로 되고 `setLayout 1` 이 `false` 를 반환해요.
그래서 "fcitx5 내림 → 배열 추가 → 측정 → fcitx5 되살림" 을 하면 **사용자가 GUI 로 추가한 배열이
매번 날아가요.** 2026-08-29 [#536](https://github.com/ensky0/tildaz/issues/536) 실기에서 두 번
재현됐고, 사용자가 두 번 다시 추가해야 했어요.

- **되살리기 전에 미리 알려요.** 배열은 되돌릴 방법이 없어요 (`kxkbrc` 를 손으로 고쳐도 KWin 이
  재시작 전까지 안 읽는다는 위 항목과 같은 이유예요).
- 한 회차에서 **여러 케이스를 몰아서** 재고 fcitx5 는 마지막에 한 번만 되살려요. 회차마다
  내렸다 올리면 그만큼 사용자가 다시 추가해야 해요.
- `pkill -x fcitx5` 뒤에도 **세션이 다시 띄우는 경우가 있어요** (D-Bus 활성화 · autostart).
  측정 직전에 `pgrep -x fcitx5` 로 다시 확인해요.

```sh
gdbus call --session --dest org.kde.keyboard --object-path /Layouts \
  --method org.kde.KeyboardLayouts.getLayoutsList
gdbus call --session --dest org.kde.keyboard --object-path /Layouts \
  --method org.kde.KeyboardLayouts.setLayout 1        # 목록 순서의 index
```

**AltGr 케이스는 `<RALT>` 가 정말 `ISO_Level3_Shift` 인지 먼저 봐요.** `kxkbrc` 의 `Options=korean:ralt_hangul` (한국어 사용자에게 흔해요) 이 걸려 있으면 오른쪽 Alt 가 **`Hangul`** 이라 AltGr 조합 자체가 성립하지 않아요. 다만 그 옵션은 **첫 배열(group 1) 에만** 붙어서, fr 로 전환하면 같은 키가 `ISO_Level3_Shift` 로 돌아와요 — 즉 *us 에서 안 되는데 fr 에서는 되는* 상태라 덤벙대면 엉뚱한 결론을 내요. `xkbcli dump-keymap-wayland | grep -A4 'key <RALT>'` 로 그룹별 심볼을 확인하고 시작해요 (2026-08-29 KDE 실측).

**nested 로도 돼요** — sway · Hyprland 는 KDE 안에서 중첩 실행해 잴 수 있어요. 단 **자식 세션이 부모의 `XDG_CURRENT_DESKTOP` 을 물려받으므로** 그 값을 명시해야 해요 (안 하면 `de=KDE` 인 채로 돌아 Hyprland 경로가 안 탑니다).

```sh
WAYLAND_DISPLAY=wayland-0 XDG_CURRENT_DESKTOP=sway sway -c <config>
env -u XDG_CURRENT_DESKTOP WAYLAND_DISPLAY=wayland-0 Hyprland -c <config>

# GNOME 은 `--devkit` 이 nested 예요 (`--nested` 는 50 에서 없어졌어요). 자기 세션
# 버스가 필요해서 `dbus-run-session` 으로 감싸요.
XDG_CURRENT_DESKTOP=GNOME dbus-run-session -- \
  gnome-shell --devkit --wayland --wayland-display=wayland-9

# COSMIC 은 `WAYLAND_DISPLAY` 가 있으면 스스로 중첩해요.
WAYLAND_DISPLAY=wayland-0 XDG_CURRENT_DESKTOP=COSMIC cosmic-comp

# Cinnamon 은 `--nested` 예요. GNOME 처럼 자기 세션 버스가 필요해요.
WAYLAND_DISPLAY=wayland-0 XDG_CURRENT_DESKTOP=X-Cinnamon dbus-run-session -- \
  cinnamon --nested --wayland
```

**Cinnamon 은 `--replace` 를 절대 쓰지 않아요.** `-r` / `--replace` 는 *지금 돌고 있는 창 관리자를
갈아치우는* 옵션이라, 부모 세션에서 그대로 부르면 사용자의 데스크톱이 사라져요. 중첩은 `--nested`
하나예요.

- **`muffin-CRITICAL: Failed to init X11 display: Failed to initialize GDK` 는 정상이에요.** 중첩
  세션에 X11 디스플레이가 없어서 나는 경고이고, 그 뒤로 셸은 정상 기동해요 (`JS LOG: Enabling
  WindowAttentionHandler` 까지 오면 떴어요). 이 줄을 실패로 읽지 말아요.
- **어느 `wayland-N` 을 가져갔는지는 로그에 안 나와요.** `ss` 로 확인해요 — 번호는 그때그때 달라요.

    ```sh
    ss -xlp | grep wayland-        # 소켓별로 잡고 있는 프로세스가 보여요
    ```

- Cinnamon extension 경로를 태우려면 `XDG_CURRENT_DESKTOP` 이 `X-Cinnamon` 이어야 해요
  (`gsettings_hotkey.shellExtensionTargetForDesktopValue` 가 `GNOME` 을 먼저 보고 그다음
  `X-Cinnamon` / `Cinnamon` 을 봐요).

**COSMIC 에서 layout 전환하기.** `~/.config/cosmic/com.system76.CosmicComp/v1/xkb_config` 의 `layout` 을 고치면 cosmic-comp 가 바로 읽어요 (KDE 처럼 재시작이 필요하지 않아요).

```ron
(
    rules: "", model: "pc105", layout: "fr", variant: "",
    options: Some("grp:alt_shift_toggle"), repeat_delay: 600, repeat_rate: 25,
)
```

**Cinnamon 에서 layout 전환하기.** 스키마가 **`org.cinnamon.desktop.input-sources`** 예요 — `org.gnome.desktop.input-sources` 도 `org.gnome.libgnomekbd.keyboard layouts` 도 **값만 바뀌고 아무 일도 안 일어나요** (`csd-keyboard` 가 전자를 읽기는 하지만 Wayland 에서 keymap 을 세우는 것은 `keyboardManager.js` 의 `Meta.get_backend().set_keymap` 이고, 그쪽은 cinnamon 스키마를 봐요). 이걸로 30 분 헤맸어요.

```sh
gsettings set org.cinnamon.desktop.input-sources sources "[('xkb','fr')]"
```

**적용됐는지는 앱 로그로 확인해요** — `ru` 로 바꾸면 `[keys] latin fallback active for N binding(s)` 이 떠요. `setxkbmap -query` 는 **쓸 수 없어요**: Cinnamon · COSMIC 둘 다 Xwayland 에 layout 을 안 내려서 늘 `us` 로 보여요.

**Cinnamon 은 `org.Cinnamon.Eval` 이 열려 있어요** (GNOME 과 달라요). 셸 상태를 물어볼 때 씁니다 — 다만 `imports.ui` 는 막혀 있어요.

```sh
gdbus call --session --dest org.Cinnamon --object-path /org/Cinnamon \
  --method org.Cinnamon.Eval '1+1'
```

**GNOME 에서 layout 전환하기.** `gsettings set org.gnome.desktop.input-sources sources "[('xkb','fr')]"` 예요. **대조군은 layout 을 하나만 켜고 재요** — 둘 이상 켜면 Mutter 가 keysym 을 모든 group 에서 찾아 걸어 주므로 라벨 표기도 되는 것처럼 보여, 위치 표기와 갈리지 않아요 (실측).

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

# `config_N.toml` 이 없는 실행에는 창 안 단축키가 하나도 없어요

**조건은 `-e` 가 아니라 "그 회차가 뜰 때 config 파일이 없었다" 예요.** `Ctrl+Shift+T` ·
`Ctrl+Shift+W` · `Cmd+T` 같은 창 안 단축키가 **0 개**인 채로 돌아요. 세 platform 공통이고,
버그가 아니라 두 규칙이 맞물린 결과예요.

- **config 파일이 없는 경로가 `[keys]` 를 채우지 않아요.** `Config.load` 는 파일이 없으면
  `defaultOwned` 로 가는데 그 함수가 `key_bindings` · `key_binding_count` 를 건드리지 않아서
  `Config{}` 의 기본값 `key_binding_count = 0` 이 그대로 남아요. 바인딩을 채우는 것은 `parse`
  안의 루프뿐이고, 그 안의 `defaultBindings(action)` fallback 도 **파일을 파싱하는 경로에만**
  있어요.
- **측정 인스턴스 (`-e`) 가 대표 사례일 뿐이에요.** 그쪽은 *일부러* config 를 만들지 않아서
  ([#382](https://github.com/ensky0/tildaz/issues/382) — *"측정이 사용자 설정을 만드는 주체가 되면
  안 된다"*, `config.zig` 의 `Config.load` 주석) 매번 걸려요.

**⚠️ `-e` 없이 새 인스턴스를 처음 띄우는 회차도 그대로 걸려요.** 앱이 파일을 *만들기는* 하지만
**그 회차의 메모리 config 는 이미 빈 채**예요. 그래서 **한 번 띄웠다 내리고 다시 띄우면** 그때부터
정상이에요. 2026-08-29 [#483](https://github.com/ensky0/tildaz/issues/483) macOS 회차에서 이것으로
걸렸어요 — `⌘T` 조차 안 먹는데 문자 키 (`h` → `ㅗ`) 는 정상이라 포커스 문제도 아니어서 한참 갈랐어요.
그 전까지 이 절의 제목이 `-e` 로 좁혀져 있어서 해당 없다고 읽혔던 것이 원인이에요.

**그래서 단축키를 쓰는 검증은 config 를 먼저 만들어 두고 시작해요** (아래 `# 실행 환경` 의 `--instance 9`
절차). 파일이 있으면 `-e` 여도 정상이에요 — `-e` 가 config 를 *읽는* 것은 막지 않아요.

**합성 입력 문제로 오진하기 쉬워요.** 2026-08-26 [#506](https://github.com/ensky0/tildaz/issues/506)
Windows 검증에서 VK-only · VK+scancode · scancode-only 세 방식으로 `SendInput` 을 보내도
무반응이라 injection 을 의심하며 시간을 썼어요. 같은 회차의 macOS 에서도 `Cmd+T` 가 안 먹어
사용자가 `+` 를 클릭했어요 — 원인은 같아요.

**탭 수를 바꾸는 다른 진입점이 있어요.** 창 오른쪽 위 컨트롤 스트립이 `+` (새 탭) · `×` (활성 탭
닫기) · `⋯` (메뉴) 순서라, 마우스 클릭으로 탭을 만들고 닫을 수 있어요. 탭 수 변화를 보는 검증
(예: `-size` 가 탭바만큼 창을 키우는지) 에는 단축키와 동등해요.

단축키 자체를 써야 하면 **`-e` 없이 한 번 띄워 config 를 만든 뒤** 측정 인스턴스를 띄워요.

```sh
tildaz --instance 9              # config_9.toml 생성 (뜬 뒤 바로 내려요)
tildaz --instance 9 -e /bin/bash -size 88x33 &
```

⚠️ 이렇게 만든 `config_9.toml` 은 **끝나면 지워요** — 안 지우면 사용자 로그온 때 그 인스턴스가
같이 떠요 (위 `# Windows — 키보드 layout 조회 실측 방법` 절의 같은 주의).

# Linux — headless sway · nested compositor 로 합성 입력 · 다이얼로그 · 배율을 자동 검증하는 법

macOS (`cliclick`) · Windows (`SendInput`) 절에 대응하는 Linux 몫이에요 ([#583](https://github.com/ensky0/tildaz/issues/583)
A5 · A7 · A8 · A2, 2026-09-03 미니PC Firebat ZY-A8). 핵심은 **사용자 세션을 전혀 건드리지 않는 것**이에요 — `ydotool`
은 `/dev/uinput` 이라 그 순간 포커스된 사용자 창에 타이핑되지만, headless sway 안의 가상 키보드는 그 sway 로만 가요.

| 도구 | 무엇 |
|---|---|
| [`dist/linux/vkbd.py`](dist/linux/vkbd.py) | `zwp_virtual_keyboard_v1` 가상 키보드를 **한 번 꽂고 유지**하며 FIFO 로 `type …` · `key ctrl+shift+t` 를 받는 데몬 |
| [`dist/screens/clusters.py bands`](dist/screens/clusters.py) | 밝은 230 / 어두운 20 띠를 3 줄씩 번갈아 채운 화면 — 배율 리샘플 (#539) 판정용 |
| [`dist/linux/bands-check.py`](dist/linux/bands-check.py) | 그 캡처의 세로 단면에서 띠 경계 전이 행의 밝기 종류를 세요 (한 종류 이하 = 리샘플 없음) |
| [`dist/linux/headless-check.sh`](dist/linux/headless-check.sh) | 위를 엮은 회차 — `tabs` (Alt+1~9) · `confirm` · `prompt` (SIGTERM 펌프) · `scale` (배율) · `seat-replug` (#347 착탈) · `compositor-exit` (#613) · `launcher-fatal gnome\|cinnamon` |
| [`dist/linux/real-session-check.sh`](dist/linux/real-session-check.sh) | **실제 세션**에서만 갈리는 것 — `hypr-scale 1.25 …` (다른 TTY 에 뜬 실제 Hyprland 에 붙어 배율별 띠 + foot 대조) · `gnome` (GNOME 세션 안에서 fractional-scale 광고 · 앱의 scale 소스 · #577 다이얼로그 캡처) |

```sh
R=/run/user/$(id -u)/tz583; mkdir -m 700 -p $R                       # ⚠️ 짧은 경로 — 아래
env -u XDG_CURRENT_DESKTOP XDG_RUNTIME_DIR=$R WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
    setsid sway -c sw.conf &                                          # sw.conf: output HEADLESS-1 resolution 1600x1000
export XDG_RUNTIME_DIR=$R WAYLAND_DISPLAY=wayland-1 XDG_CURRENT_DESKTOP=sway SWAYSOCK=$(ls $R/sway-ipc.*.sock)
export XDG_CONFIG_HOME=$T/xdg/config XDG_STATE_HOME=$T/xdg/state        # config_0.toml 은 사용자 것을 복사 (auto_start=false)
python3 dist/linux/vkbd.py --fifo $R/vkbd.fifo &                      # ① 키보드를 먼저 꽂고
TILDAZ_VERBOSE=1 ./zig-out/bin/tildaz --instance 0 &                  # ② 그다음 앱 — seat 에 keyboard 가 처음부터 있게
echo "type touch /tmp/probe" > $R/vkbd.fifo; echo "key Return" > $R/vkbd.fifo   # 포커스 확인 — 파일이 생겨야 시작
grim shot.png                                                          # sway 는 screencopy 를 내줘요
```

- **격리 `XDG_RUNTIME_DIR` 은 짧아야 해요.** scratchpad 경로 (90 자 남짓) 를 주면 sway 가 `Socket path won't fit into
  ipc_sockaddr->sun_path` 로 **세그폴트**해요 (`sun_path` 108 바이트). `/run/user/<uid>/tz583` 처럼 실제 runtime dir 아래
  짧은 디렉터리를 만들어요 — tmpfs 이고 사용자 소유라 lock · 소켓 격리도 그대로예요. tildaz 의 lock · toggle 소켓 · 앱이
  붙는 `wayland-1` 이 전부 그 안에 생겨 사용자 instance 0 과 부딪히지 않아요 (그래서 `--instance 0` 을 써도 돼요 —
  new-instance prompt 는 worker 0 만 처리하니 A7 prompt 회차에는 0 이 필요해요).
- **sway 에 `timeout` 을 걸었으면 그 시간을 기억해요.** 30 분으로 걸어 둔 sway 가 회차 도중 내려가 뒤 회차가 전부
  `ConnectFailed` 였어요 — 앱이 안 뜬 것이 아니라 compositor 가 없는 거예요. 길게 (4 시간) 걸고 끝나면 `swaymsg exit`.
- **`wtype` 은 쓰지 말아요 — 두 가지가 실측으로 걸렸어요.** ① 새 글자가 나올 때마다 keymap 을 다시 올려서 그 사이의 키가
  빠지거나 다른 글자로 읽혀요 (`touch …` 가 `ouch …` 로). ② 호출마다 가상 키보드를 꽂고 뽑아 두 번째 호출부터 키가 아예
  안 닿아요 — seat 의 keyboard capability 가 빠졌다 붙는 왕복을 앱이 처리하지 않기 때문이에요 (아래 결함 후보).
  `vkbd.py` 는 us keymap 을 연결 직후 한 번 올리고 프로세스가 살아 있는 동안 유지해요.
- **modifier 는 `modifiers` 요청으로 보내야 해요.** 프로토콜이 modifier 상태를 client 책임으로 두고 wlroots 는 가상
  키보드의 key 이벤트로 xkb 상태를 갱신하지 않아서, Shift 키 press 만 보내면 `Ctrl+Shift+T` 가 `t` 로 · `>` 가 `.` 로
  들어가요. `vkbd.py` 가 mask (Shift 0 · Control 2 · Mod1 3 · Mod4 6 비트) 를 함께 보내요.
- **이 도구로 찾은 결함 — [#347](https://github.com/ensky0/tildaz/issues/347) (2026-09-03).** `wtype` 이 호출마다 가상
  키보드를 꽂고 뽑는 바람에 seat 의 keyboard capability 가 빠졌다 붙는 왕복이 생겼고, 앱이 그때 `wl_keyboard` 를 놓고
  다시 만들지 않아 두 번째부터 키가 영원히 닿지 않았어요 — 유일한 키보드를 뽑았다 꽂는 데스크톱과 같은 조건이에요.
  `fix/347-seat-capability-release` 가 잃으면 `release` · 돌아오면 재생성으로 고쳤고, **`headless-check.sh seat-replug`**
  (vkbd 를 띄우고 · 내리고 · 다시 띄워 세 번째에 `wl_keyboard … created` 와 키 도착을 봐요) 가 그 회귀 검사예요.
  compositor 가 먼저 끝나는 경우 (#613 — `swaymsg exit` 뒤 `failed to start` 가 아니라 정상 종료) 는
  **`headless-check.sh compositor-exit`** 로 봐요 — 그 회차는 sway 를 내리므로 마지막에 돌리고 다시 `up` 해요.
- **sway 는 layer-shell 을 우리가 일부러 안 써서** (#454) `-size` · dock 배치가 안 먹고 창은 tiling 으로 출력 전체예요. 그래도
  xdg_toplevel · layer-surface · dialog 가 **같은 `logicalToPhysicalSize`** 를 쓰므로 배율 검증은 성립해요.
- **단축키 판정은 파일로 해요.** 탭마다 `cat > tab_N.txt` 를 띄워 두고 `Alt+N` 뒤 글자를 보내면 어느 파일에 들어갔는지로
  전환이 확정돼요 — 캡처의 탭 강조 위치를 읽는 것보다 확실해요. 새 탭은 `Ctrl+Shift+T` 뒤 bash 가 뜨는 2.5 초를 둬요.
- **다이얼로그 펌프의 SIGTERM (#521) 은 로그 한 줄로 판정해요** — `[exit] SIGTERM received while a dialog pump was running
  — leaving the pump`. confirm 은 `Alt+F4`, prompt 는 **worker 0 을 띄운 채 인자 없는 `tildaz` (launcher)** 를 같은 격리
  환경에서 실행하면 launcher 가 worker 소켓에 new-instance 를 보내 핫키 캡처 다이얼로그가 떠요. `tail` 로 볼 때 그 줄이
  `confirm result=Cancel` **앞**에 있어서 잘리기 쉬워요 — `grep` 으로 봐요. map 대기 펌프는 `mapped` 가 attach+commit
  직후 참이 되고 compositor 를 `SIGSTOP` 하면 그 앞의 blocking `readAndDispatch` 에서 먼저 막히므로 **인위로 진입시킬
  수 없어요** — 같은 헬퍼 한 줄이라 코드 판정으로 둬요.
- **띠 화면은 시작 1.5 초 뒤에 그려요.** `-e` 프로세스는 세션 생성 직후 뜨고 창 크기는 그 뒤 configure 로 확정돼요
  (`terminal session created cols=68 rows=21` → `terminal resized cols=86 rows=52`). 바로 `stty size` 를 읽으면 21 줄만
  채워 아래가 배경으로 남고, 자동 기준값을 쓰는 판정이 배경을 띠로 오인해요. `bands` 는 기다린 뒤 그리고 `SIGWINCH` 에
  다시 그려요. `bands-check.py` 는 기준을 230 / 20 으로 고정하고 띠가 아닌 행이 1/4 을 넘으면 경고해요.
- **배율 검증 (#539) 은 sway 에서 세 가지를 맞춰야 성립해요** — 하나라도 어긋나면 *모든* client 가 리샘플되어 (foot 대조군도
  같은 서명을 냈어요) 우리 buffer 가 스펙대로여도 "여러 종류" 가 나와요. 2026-09-03 에 셋을 차례로 밟았어요.
  ① **출력 물리 해상도가 scale 로 정확히 나눠져야** 해요 (1.5 → `1500x999` · 1.7 → `1700x1020`). 안 나눠지면 sway 가 출력
  논리 크기를 내림하고 프레임 전체를 늘려 그려요 — `grim` 캡처가 `1600x999` 처럼 1 px 작게 나오면 이거예요.
  ② **창은 floating 으로 정수 논리 크기를 줘요** (`swaymsg '[app_id="^tildaz"] floating enable, resize set width 800 px
  height 798 px'`). tiling 컨테이너는 논리 높이가 소수 (1000/1.5 = 666.67) 라 sway 가 창을 그 크기에 맞춰 늘려요.
  `-e` 측정 인스턴스의 app_id 는 `tildaz.instance0` 이 아니라 역할별 이름이라 접두어 `^tildaz` 로 잡고, 창이 트리에
  나타난 뒤 (`get_tree` 에 `"app_id": "tildaz`) 앱 자신의 `move position` IPC 뒤에 보내요.
  ③ **floating 폭이 출력 논리 폭을 넘으면 clamp 되어 ② 가 무효**예요 (1.7 의 논리 폭 941 에 1200 을 주면 컨테이너가 출력
  전체로 돌아가요). `get_tree` 의 rect 가 요청과 같은지 회차마다 확인해요.
  셋을 맞추면 목적지 = `round(H × scale)` 이라, 논리 높이 H 를 골라 소수부를 .5 이상으로 만들면 (1.25 · H 798 → 997.5,
  1.7 · H 585 → 994.5) 내림 (#539 이전) 과 반올림 (스펙) 이 갈리는 조합이 돼요. 소수부 0 인 회차를 대조로 함께 둬요.
- **nested Hyprland 는 KWin 에서 창이 가려지면 프레임을 그리지 않아요** — `grim` 이 screencopy 를 영원히 기다려요
  (`timeout 3 grim …` 이 124 로 끝나면 이거예요). 사용자에게 알리지 않고 KWin 스크립트로 창을 올리면 포커스를 빼앗아
  타이핑이 nested 안으로 들어가니 하지 말고, **headless 출력을 하나 더 만들어 거기서 재요** — 그 출력은 부모 창과 무관하게
  그려요.

    ```sh
    hyprctl output create headless HL-1
    hyprctl keyword monitor "HL-1,1500x999,2000x0,1.5"      # 해상도는 scale 의 배수 (아래 배율 검증 조건 ①)
    hyprctl dispatch focusmonitor HL-1                       # layer surface 는 포커스된 모니터에 떠요
    grim -o HL-1 shot.png
    ```

    배율을 바꾼 뒤 **3 초**는 두고, 회차마다 앱 로그의 `logical_h` 가 `height_percent` 와 맞는지 봐요 — 전환 직후에
    옛 work-area 로 뜬 회차 (60 % 인데 논리 높이 180) 가 있었어요. 그리고 **이 출력의 1.25 배율에서는 foot 도 리샘플
    서명**을 냈어요 (1.5 · 1.7 은 둘 다 깨끗) — 그 조건의 "여러 종류" 는 우리 결함이 아니고 실제 Hyprland 세션의 1.25 는
    따로 봐야 해요. **대조군 (foot) 없이 배율 판정을 내리지 않아요.**
- **nested 로 못 가르는 것은 실제 세션에서 재요 — 두 방법이 달라요.** Hyprland 는 D-Bus 의존이 적어 **다른 TTY 에서
  로그인해 `Hyprland` 를 띄우면** KDE 세션 (이 agent 가 도는 곳) 과 동시에 떠도 안전하고, 같은 uid 의 `/run/user/<uid>` 에
  소켓이 생기므로 agent 가 거기 붙어 `real-session-check.sh hypr-scale` 을 돌릴 수 있어요 (사용자는 화면만 그 VT 에 두면
  돼요 — 실제 출력이라 가려짐 문제가 없어요). **GNOME 은 그렇게 하지 말아요** — 세션 전체가 uid 당 하나인 user bus 를 써서
  KDE 와 동시에 띄우면 이름이 충돌해요 (nested 때도 `name already taken` 이 났어요). KDE 를 로그아웃하고 GNOME 으로 로그인한
  뒤 **그 세션 안의 새 agent 세션**에서 `real-session-check.sh gnome` 을 돌려요. 두 스크립트 모두 세션 배율을 바꾸면 끝에
  원래 값으로 되돌리고 config 는 격리 경로예요.
- **COSMIC nested (`cosmic-comp`) 는 `cosmic-randr mode X11-0 1280 800 --scale 1.25` 로 배율을 바꿔요.** 출력이 winit
  창 크기 (1280x800) 로 고정이라 배율은 그 둘을 나누는 값 (1.25 · 1.6 · 2.0) 만 돼요. `grim` 은 wlr-screencopy 가 아니라
  `ext_image_copy_capture_manager_v1` 로 돼요 (grim 1.5). runtime dir 은 격리해도 돼요 (pipewire 불필요).
- **mutter devkit (`gnome-shell --devkit`) 은 runtime dir 을 격리하면 죽어요.** 화면을 pipewire 로 뷰어 창에 보내는데
  `XDG_RUNTIME_DIR` 을 돌리면 pipewire 소켓을 못 찾아 (`Failed to connect pipewire context`) 셸이 곧 내려가요. 실제
  runtime dir 을 쓰고 `--wayland-display=wayland-77` 처럼 특이한 소켓 이름으로 겹침을 피해요. tildaz 쪽 config · 로그만
  `XDG_CONFIG_HOME` · `XDG_STATE_HOME` 으로 격리해요. 그리고 **`spectacle` 은 `dbus-run-session` 안에서 안 돼요** —
  KWin 과 사용자 세션 버스로 말하니 바깥 셸에서 타이머로 찍어요. 다만 devkit 뷰어는 검게, Cinnamon nested 는 희게 찍혀서
  (2026-09-03) **다이얼로그의 픽셀 증거는 못 얻었어요** — 판정은 로그의 `[dialog] configured logical=… physical=…` (configure
  를 받고 buffer 를 만든 것) 과 `layer_shell=false` (= xdg_toplevel fallback 만 가능) 로 해요.
- **Cinnamon nested (`cinnamon --nested --wayland`) 의 소켓은 `ss -xlp` 의 pid 로 찾아요.** 이름을 지정할 수 없고 로그에도
  안 남으며, 실제 runtime dir 의 **기존 `wayland-N` 파일을 재사용**하기도 해서 (`wayland-0.lock` 실패 뒤 `wayland-1` 을
  집었어요) "새로 생긴 소켓" 을 목록 비교로 찾는 방식은 빈손이에요. `ss -xlp | grep "pid=<cinnamon pid>,"` 로 봐요.
- **GNOME 50.4 nested (mutter devkit) 는 `wp_fractional_scale_v1` 을 내줘요** — 다이얼로그 로그가 `source=fractional/dialog`
  로 부모 KWin 의 1.7 을 받았어요. 위 `# 렌더링` 절의 scale 표 ("GNOME · fractional 미advertise → `wl_output` 정수
  fallback") 는 그 이전 버전 기준이라, 실제 GNOME 세션에서도 그런지는 **확인 필요**예요 (nested 만 봤어요).
- 끝나면 `echo quit > $R/vkbd.fifo` · 앱 `kill -TERM` · `swaymsg exit` · `rm -rf $R` 순서로 치우고 `pgrep -a tildaz` 로
  사용자 instance 0 만 남았는지 봐요.

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
zig run src/probe.zig -lc -O ReleaseSafe          # Debug 는 GCC16 머신에서 .sframe 링커 에러 (#232)
rm -f src/probe.zig && git status --short         # 끝나면 지우고 트리 clean 확인
```

- **`-O ReleaseSafe` 는 `build.zig` 를 안 거치는 직접 호출이라 필요해요.** `build.zig` 는 Linux
  타겟에 LLVM/LLD 를 강제하니 `zig build` · `zig build test` 는 Debug 로도 링크돼요. `zig run` 은
  그 강제 밖이라 self-hosted 링커가 GCC16 의 `crt1.o:.sframe` 에서 죽어요 ([#232](https://github.com/ensky0/tildaz/issues/232)).
  upstream 픽스는 Zig 0.17.0 에 실려요 — 그때 이 한 줄도 같이 없어져요.
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

**`-size` 는 요청한 격자를 지킬 수 없으면 아예 시작하지 않아요** ([#506](https://github.com/ensky0/tildaz/issues/506)).
밀린 채로 도는 창은 *검증이 되는 척* 해서, 그걸 진짜 버그로 오인하는 데 시간이 들어요 (#502
에서 실제로 그랬어요). 거부는 stderr + 로그 + 종료 코드 2 예요 — 다이얼로그가 아니라서
스크립트가 멈추지 않아요. 두 경우예요.

- **요청 격자 + 탭바가 화면 작업 영역보다 큰 경우.** 판정에 탭바를 미리 넣으므로 *시작만
  됐으면 탭을 만들어도 안전해요* — 탭이 늘면 창이 탭바 높이만큼 아래로 커지고 격자는 그대로
  유지돼요. 위의 "68 줄로 띄웠다가 못 봤어요" 같은 요청은 이제 조용히 잘리는 대신 필요한 px
  과 화면 px 을 적고 종료해요.
- **layer-shell 경로를 안 타는 데스크톱 (GNOME · Cinnamon · sway).** 거기선 창 크기를
  compositor 가 정해서 `-size` 가 창에 영향을 못 줘요. 예전에도 창과 격자가 어긋난 채
  돌았지만 표가 나지 않았어요. **이 검증은 KDE Plasma · Hyprland · COSMIC 에서 하세요.**
  sway 가 여기 있는 이유는 `zwlr_layer_shell_v1` 을 내주는데도 **우리가 일부러 안 쓰기**
  때문이에요 (#454 — sway 는 `on_demand` layer surface 에 map 시 키보드 포커스를 안 줘요).

직접 만든 화면이 필요하면 같은 방식으로 스크립트를 넘겨요.

```sh
./zig-out/bin/tildaz --instance 1 -e /path/show.sh -size 70x16 &
```

- **`-e` 는 인자를 못 넘겨요** (`run_options.zig` — POSIX PTY 의 argv 가 `{shell}` 로 고정).
  그래서 출력할 내용을 담은 **스크립트 파일**을 만들어 넘겨요. 스크립트 끝에 `sleep` 을 둬야
  창이 남아요 (`-e` 로 띄운 프로세스가 끝나면 앱도 끝나요).
- **`--instance 1` 을 써요.** 평소 쓰는 daily 인스턴스 (`--instance 0`) 를 건드리지 않아요.
- **단축키는 안 먹어요** — 위 `# config_N.toml 이 없는 실행에는 창 안 단축키가 하나도 없어요` 절. 탭을
  만들거나 닫아야 하면 컨트롤 스트립의 `+` / `×` 를 클릭해요.
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

## ⑥ atlas · 렌더 경로를 바꿨을 때 — 판을 맞대 픽셀로 (`render-ab-shot.sh`)

위 `# macOS — 렌더 결과와 그리는 과정을 픽셀로 검증하는 법` 에 대응하는 Linux (KDE) 도구예요 —
[`dist/linux/render-ab-shot.sh`](dist/linux/render-ab-shot.sh). [#586](https://github.com/ensky0/tildaz/issues/586)
Linux atlas `grow` 실기 (2026-09-03) 에서 만들었어요. 판은 상수 (`INITIAL_ATLAS_SIZE` 등) 만 바꿔 **별도 worktree** 에서
빌드해요 — 로컬 캐시는 `--cache-dir` 로 공유해도 돼요 (내용 해시라 섞이지 않아요). 스크립트가 md5 를 찍으니 판이 다른지 봐요.

```sh
python3 dist/screens/clusters.py stack2 > /tmp/stack2.sh && chmod +x /tmp/stack2.sh
git worktree add --detach /tmp/wt HEAD && sed -i 's/INITIAL_ATLAS_SIZE: u32 = 2048/INITIAL_ATLAS_SIZE: u32 = 4096/' /tmp/wt/src/renderer/linux/gl_atlas.zig
(cd /tmp/wt && zig build -Doptimize=ReleaseFast -Dsimd=true --cache-dir "$PWD/../tildaz/.zig-cache") && cp /tmp/wt/zig-out/bin/tildaz /tmp/tildaz-4096
dist/linux/render-ab-shot.sh /tmp/stack2.sh 150x40 8 stack2 /tmp/tildaz-4096 zig-out/bin/tildaz      # 판 1 이 기준
```

- **캡처는 `spectacle -b -n -f` 전체 화면**이라 사용자의 다른 창이 함께 담겨요. 판정은 **창 영역만**으로 하고 이슈에 올릴
  때도 창만 crop 해요 (스크립트가 `crop_1.png` 를 만들어요). `-size` 창은 화면 **오른쪽 위**에 붙어요.
- **창 영역은 로그로 계산해요** — `TILDAZ_VERBOSE=1` 의 `layer-surface configure logical_w=… logical_h=… scale=N/120`
  마지막 줄과 `screen=WxH` 로 `W = round(logical_w × N/120)` · `X = screen_w − W`. 실측과 픽셀 단위로 맞았어요
  (150x40 → `2136x1261+744+0`). 픽셀 스캔으로 검정 배경의 경계를 찾는 방식은 **글자 줄 · 스크롤바 트랙에 걸려** 틀렸어요.
- **⚠️ ImageMagick 에서 두 이미지를 각각 crop 할 때는 괄호로 감싸요.** `magick A -crop G +repage B -crop G +repage
  -compose difference …` 는 두 번째 `-crop` 이 **A 에도 다시** 걸려 크기가 다른 두 이미지를 견주게 돼요. 증상이 특이해요 —
  **모든 쌍이 정확히 같은 픽셀 수로 다르고** (같은 프로세스의 두 캡처까지), 차이 히스토그램이 판이 달라도 똑같아요.
  2026-09-03 에 이걸 "두 상태가 번갈아 보인다" 로 읽고 main 판까지 빌드해 재현하려 했어요. offset 이 crop 결과 밖이면
  (88x33 창) `geometry does not contain image` 경고만 내고 무시돼 **우연히 맞으니** 더 헷갈려요.
  `\( A -crop G +repage \) \( B -crop G +repage \)` 가 맞아요.
- **양성 대조군을 하나 둬요** — 서로 다른 화면의 캡처를 같은 영역으로 견줘 큰 수가 나오는지 (`many` vs emoji 는 353,633 px).
  `0 px` 만 보면 도구가 죽어 있어도 통과처럼 보여요.
- **기대표는 기기마다 달라요.** Ryzen AI 7 350 노트북 (1.6x · DejaVu 15 · `cell 14x31` 대) 은 cell 이 작아 `stack2`
  6,000 종이 2048² 에 다 들어가요 — 기본 2048 판의 `grow` 를 보려면 `overflow` (누적) 를 써요. macOS 의 기대표
  (`stack2` 에서 grow 1) 를 그대로 옮기면 "grow 가 안 된다" 로 오독해요.
- **⚠️ 판 바이너리에 다른 이름을 붙이면 `pgrep -x tildaz` 가 못 잡아요.** `tildaz-4096` · `tildaz-512` 처럼 복사해 두고
  돌리면 comm 이 달라져서, `pgrep -x tildaz` 로 내리는 정리 함수가 **아무것도 안 죽인 채 조용히 통과**해요 — 2026-09-03 에
  회차마다 창이 그대로 남아 17 개가 겹쳐 떠 있었고 사용자가 손으로 닫았어요 (그 사이 캡처는 맨 위 창이라 판정은 맞았지만
  겹친 채 찍힌 거예요). 스크립트는 `/proc/<pid>/cmdline` 의 실행 파일 basename 이 `tildaz*` 이고 `--instance 9` 인 것을
  골라요. **회차 뒤에 `pgrep -a tildaz` 로 0 인지 꼭 봐요** — `-x` 없이요.
- 잠금 억제 (`systemd-inhibit`) · 인스턴스 9 · `pkill -f` 금지 · 시작 전 고지는 `# 실행 환경` · 위 절과 같아요.

# Linux — 이 macOS 머신에서 lima VM 으로 Linux 를 돌려 보는 법 (software 경로만)

macOS 작업 머신에 Linux 실동작을 볼 lima VM 이 있어요 — `tildaz-linux` (Ubuntu aarch64 · sway 1.11 · grim ·
DejaVu Sans Mono · Noto Sans CJK KR · Noto Color Emoji). `limactl start tildaz-linux` 로 켜고 끝나면 `limactl stop`.
(예전에 memory 에만 있던 내용을 여기로 옮겼어요 — 2026-09-03.)

```sh
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe          # 크로스빌드 (macOS 에서)
limactl copy zig-out/bin/tildaz tildaz-linux:/tmp/tildaz-test
limactl shell tildaz-linux -- bash -c '
  cat > /tmp/tz-sway.conf <<EOF
output HEADLESS-1 resolution 1280x800
exec sh -c "sleep 2; /tmp/tildaz-test --instance 1 -e /tmp/screen.sh"      # sleep 없이 exec 하면 소켓 연결이 실패한다 (실측)
exec sh -c "sleep 9; grim /tmp/tz-shot.png; sleep 1; swaymsg exit"
EOF
  env -i HOME=/tmp/tz-home XDG_CONFIG_HOME=/tmp/tz-xdg XDG_STATE_HOME=/tmp/tz-state XDG_RUNTIME_DIR=/tmp/tz-run \
      PATH=/usr/bin:/bin TILDAZ_VERBOSE=1 WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
      timeout 16 sway -c /tmp/tz-sway.conf'
limactl copy tildaz-linux:/tmp/tz-shot.png /tmp/tz-shot.png                # 회수해서 눈으로 · 픽셀로
```

- **격리**는 `env -i` + `/tmp/tz-*` 홈 · config · state 로 해요. 로그는 `/tmp/tz-state/tildaz/tildaz_*.log`
  (`-e` 화면은 측정 역할이라 `tildaz_stress.log`). `-e` 는 인자를 못 받으니 화면은 스크립트 파일로
  (`dist/screens/clusters.py` 가 만들어 줘요).
- **창은 화면 오른쪽 절반 (x 640~1280 · 640×800)** 이에요 — tildaz 가 sway IPC 로 `resize set width 50 ppt`
  를 등록해요. `-size` 는 sway 에서 창에 영향을 못 줘요 (layer-shell 을 일부러 안 써요, #454). 좌우 3분할은
  20 열 최소에 걸려 안 되니 세로축으로 짜요.
- **해상도를 바꾸지 마세요** (`swaymsg output "*" resolution …`) — compositor 가 창을 축소해 보여 1px 선이
  두 픽셀에 번져요 (#374 에서 걸렸어요). 기본 출력 크기 그대로 캡처.
- `set -e` 스크립트에서 `pkill -x sway` 는 죽일 것이 없으면 exit 1 이라 조용히 중단돼요 — `|| true`.
- 폭 0 문자 (default-ignorable) 는 cell 이 안 생겨 렌더 테스트에 못 써요 — 미배정 U+0378 이 "어떤 폰트에도
  없는 폭 1 문자" 로 유용해요.

**⚠️ GL 경로 (atlas · `gl_*.zig`) 는 이 VM 에서 켜지지 않아요 — software (`wl_shm`) 경로만 검증돼요.**
2026-09-03 #586 Linux atlas `grow` 를 재려다 확인했어요. VM 에 `/dev/dri` 가 없어 tildaz 가 *"software path —
cannot open DRM render node"* 로 떨어지고, `sudo modprobe vkms` 는 `card0` 만 (렌더 노드 없음), `sudo modprobe vgem`
+ `MESA_LOADER_DRIVER_OVERRIDE=kms_swrast` + `WLR_RENDERER=gles2` 로 렌더 노드 · dmabuf 광고까지 만들어도 tildaz 의
GLES 가 *"all 1 advertised modifiers failed FBO"* · *"gbm 할당 실패"* 로 software 로 떨어졌어요. **atlas 관련
변경의 Linux 실기는 실제 GPU 가 있는 Linux 기기 (`# 실행 환경` 의 듀얼부트 노트북) 에서** 해요 — 절차는
`# Linux — 글리프 · cluster 렌더 실기 검증 방법` 과 SPEC §12.6 의 Linux 실측 표대로예요.

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

**검증 명령을 파이프로 묶으면 exit code 는 마지막 명령의 것이에요.** `zig build check 2>&1 | tail -3 && echo OK`
는 `tail` 이 성공하면 "OK" 를 찍어요 — 빌드가 실패해도요. 통과를 보고하기 전에 **실제 성공 표식**을 봐요:
`set -o pipefail`, 또는 `zig build check; echo "CHECK=$?"` 처럼 exit code 를 따로 찍기, 또는 `${PIPESTATUS[0]}`.
`| tail && echo OK` 로 가짜 통과를 보고한 적이 있어요.

**Bash 도구의 작업 디렉터리는 앞 호출의 `cd` 가 그대로 남아요 — 검증 명령은 저장소 경로를 명시해요.**
2026-09-03 에 문서용 worktree 로 `cd` 한 호출 뒤에 `zig build check` · `zig build test` 를 돌렸는데, 그것이
**검증하려던 브랜치가 아니라 그 worktree (다른 브랜치) 에서 돌았어요.** 출력만 보면 통과라 알아채지 못했고,
그 worktree 에 `zig-out/test` 가 생긴 것으로 뒤늦게 드러났어요 (이슈 댓글 두 곳을 정정했어요). 검증 · 커밋 · push 처럼
어디서 도는지가 결과를 바꾸는 명령은 `cd /c/Users/<user>/tildaz && …` 로 시작하거나 `git -C` 를 써요. 백그라운드
호출은 cwd 를 바꾸지 않지만 (도구가 알려 줘요) 동기 호출의 `cd` 는 다음 호출까지 살아요.

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
| MacBook Pro (M5 Pro) | macOS | 내장 3024x1964 · **120 Hz** (ProMotion); 보통 clamshell + 외장 **60 Hz** |

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

**실기 검증은 무엇이든 시작 전에 말하고 사용자 동의를 받아요** (2026-08-05 사용자 지시:
*"테스트 하기 전에 말하고 해. 좀 전에도 내가 키보드 쳐서 오염되었어"*, 2026-08-26 범위 확대).
측정만이 아니라 **기기 상태를 건드리는 검증 전부**가 대상이에요.

- **합성 키 · 마우스 입력** (`ydotool` · `SendInput` · `CGEvent` 등) — 사용자가 그 순간 타이핑
  중이면 서로 섞여요.
- **처리량 측정 · perf 덤프** — 사용자가 기기를 건드리면 그 회차를 버려요 (실제로 두 번 발생).
  "지금부터 몇 초 동안 무엇을 재는지" 를 먼저 알려요.
- **nested compositor 를 띄우는 것** (sway · Hyprland · GNOME · COSMIC · Cinnamon) — 창이 뜨고
  Wayland 소켓 번호를 가져가요. **다른 세션 · 다른 agent 가 같은 기기에서 검증 중일 수 있어요.**
- **세션 설정을 바꾸는 것** — 단축키 등록, layout 전환, dconf / RON / kxkbrc 수정. 잠깐이라도
  사용자의 실제 세션 동작이 달라져요.
- **앱을 띄우고 내리는 것** — 평소 쓰는 worker 를 종료시키는 절차가 들어가면 특히.

2026-08-26 에 이것 때문에 실제로 부딪혔어요. 한 agent 가 #510 검증으로 nested Cinnamon 을
띄웠는데 **같은 기기에서 다른 agent 가 이미 검증 중**이었고, 사용자가 멈추라고 해서야 알았어요.
그때 정리하며 배운 것도 함께 적어요.

- **띄운 것은 반드시 되돌려요.** nested compositor · 테스트 프로세스 · 임시 소켓까지.
- **지우기 전에 지금 누가 쓰는지 확인해요.** 위 사례에서 자기가 만든 `wayland-1` 을 지우려다
  `ss -xlp` 로 보니 **그 사이 다른 agent 의 Hyprland 가 그 번호를 물려받아** 있었어요. 소켓 번호는
  재사용돼요 — 이름만 보고 지우면 남의 세션을 끊어요.
- **검증은 임시 XDG 경로로 격리해요.** 사용자의 `config_N.toml` · lock 을 건드리지 않아요.

    ```sh
    env XDG_CONFIG_HOME=$T/config XDG_STATE_HOME=$T/state XDG_RUNTIME_DIR=$T/run \
        WAYLAND_DISPLAY=/run/user/$(id -u)/wayland-1 …            # 절대경로면 RUNTIME_DIR 격리와 양립
    ```

    `WAYLAND_DISPLAY` 는 `/` 로 시작하면 **절대 소켓 경로**로 쓰여요. 그래서 `XDG_RUNTIME_DIR` 를
    임시 경로로 돌려 lock · endpoint 를 격리하면서도 compositor 에는 그대로 붙어요.

- **⚠️ 그 격리가 덮지 못하는 것이 둘 있어요.** 파일 경로만 바꾸는 격리라, 다른 프로세스를
  거치는 상태는 그대로 실제 세션으로 나가요. 2026-08-26 [#510](https://github.com/ensky0/tildaz/issues/510)
  검증에서 둘 다 걸렸어요.

  | 새는 것 | 왜 | 증상 |
  |---|---|---|
  | **GSettings / dconf** | 읽기는 `$XDG_CONFIG_HOME/dconf/user` 를 **mmap** 하고, 쓰기는 세션 버스의 `dconf-service` 가 **자기 환경**으로 해요 | 격리하면 **읽기는 통째로 비고** (스키마 기본값만 보임) **쓰기는 실제 세션에 남아요** |
  | **`hyprctl`** | 진짜 `XDG_RUNTIME_DIR/hypr/<signature>` 를 찾아요 | 격리하면 인스턴스를 못 찾아 조회가 실패해요 |

  그래서 **GNOME · Cinnamon 검증은 격리하지 말고 실제 홈으로 돌리고 뒤에 치워요.** 격리한 채
  돌리면 `enabled-extensions` 가 비어 보여 extension 경로가 아예 안 타는데, 로그만 봐서는
  "왜 판정이 안 도나" 로 보여서 원인을 찾는 데 시간이 걸려요 (실제로 그랬어요). Hyprland 는
  `hypr` 디렉터리만 symlink 로 이어 주면 나머지 격리를 유지할 수 있어요.

**측정 완료를 비프음으로 알리지 않아요** (2026-08-06 사용자 지시: *"실험 완료 때 나오는 비프음 꼭
삭제해줘"*). 측정이 길 때 끝을 알리려고 `[console]::beep` 을 붙이곤 했는데 쓰지 않아요 — 완료는
**텍스트로** 알려요 (`##### 끝 #####` 같은 표시나 그냥 결과 보고). 소요 시간을 미리 알리는 규칙은
그대로예요.

**어느 화면에서 쟀는지도 함께 적어요.** 모니터가 여러 대면 창이 뜬 화면이 값을 정해요 —
Linux · macOS · Windows 모두 현재 창의 화면 timing을 공통 로그
`[startup] display timing: refresh=..Hz period=..ms`로 남겨요. 같은 기기에서도 내장 패널(120 Hz)과
외장 모니터(60 Hz)에서 프레임 주기가 갈리므로, 이 줄과 platform별 화면 정보
(`window initialized: dpi=..` 등)를 근거로 남겨요.

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
- 단위 테스트: `zig build test`.
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

   **[`dist/release-notes/UNRELEASED.md`](dist/release-notes/UNRELEASED.md) 를 먼저 열어요.**
   두 칸이 있어요 — `Upgrade notes` 는 새 노트의 같은 이름 절로, `Body candidates` 는
   **본문 후보**라 5 줄 제한 안에서 골라 담아요 (다 넣는 목록이 아니에요). 옮긴 뒤 그
   파일은 비워요. 업그레이드 주의는
   *변경할 때* 알게 되는데 *릴리스할 때* 발행되므로, 그 사이를 나르는 것이 없으면 기억에
   의존하게 돼요 (2026-08-26 [#510](https://github.com/ensky0/tildaz/issues/510) 에서
   instance 상한이 내려가 기존 config 가 인식 안 되는 주의가 나왔는데, 머지 시점에 적어 둘
   자리가 없었어요). **반대 방향도 규칙이에요** — 업그레이드 주의를 만드는 PR 은 그 파일에
   한 줄을 **같은 PR 에서** 추가해요. 코드와 문서를 같은 PR 에 담는 규칙과 같은 이유예요.
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
- **5줄은 상한이지 채워야 하는 분량이 아니에요** (2026-08-29 사용자 지시: *"5줄 저거 다
  중요한거야? 안중요하면 5줄보다 적어도 되"*). 담을 것이 셋이면 세 줄이에요. 줄을 채우려고
  덜 중요한 항목을 끌어오면 진짜 변경이 묻혀요. v0.9.2 에서 실제로 다섯 줄을 적었다가 둘을
  뺐어요 — 하나는 *브랜치 안에서 만든 퇴행을 고친 것*이라 **이전 버전 대비로는 변화가 없었고**
  (사용자에게는 처음부터 정상이던 동작), 하나는 앞줄이 이미 말한 것의 다른 표현이었어요.
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
