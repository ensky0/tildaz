# Cross-Platform 통합 현황 + 정리 계획

> tildaz 는 zig 로 작성된 cross-platform 터미널 (현재 Windows + macOS, 향후
> Linux). 이 문서는 (1) 두 platform 코드의 통합 현황, (2) 발견된 오류 /
> dead code / misnomer, (3) 정리 계획 (Phase 0 ~ 7) 을 한 곳에 모은
> 살아있는 문서다.
>
> ARCHITECTURE.md 가 *현재 어떻게 동작하는가* 를 설명한다면, 이 문서는
> *어디가 정리되어야 하는가 + 어떤 순서로 갈 것인가* 를 담는다. Linux 추가
> 시 boundary 도 같이 정리.

---

## 0. 큰 그림

| 항목 | 값 |
|---|---|
| shared (top-level zig) | ~6.3k LOC |
| platform 분리 모듈 | ~12k LOC (mac 4.6k + win 5.4k + 공유 디스패치 ~50줄) |
| 가장 비대칭 페어 | host/macos.zig 2672 vs host/windows.zig 242 (10배) |
| 통합 패턴 정착도 | 양호 — `terminal.zig` / `dialog.zig` / `autostart.zig` / `log.zig` / `renderer.zig` / `host` 모두 wrapper + comptime dispatch |
| Linux 추가 시 새 파일 추가만으로 가능한 영역 | 5/6 (host 만 신규 작성 필요) |

`src/host/unsupported.zig` (14줄) 는 Linux 등 미지원 플랫폼에서 빌드는
통과하도록 stub 형태로 이미 존재. 좋은 자리잡음.

---

## 1. Platform 모듈 매핑

| 영역 | macOS LOC | Windows LOC | shared dispatch | 외부 API 통일? | 통합 점수 (1=낮음, 5=완료) |
|---|---:|---:|---|:---:|:---:|
| host | 2672 | 242 | [main.zig](src/main.zig) (comptime select) | ✗ (이벤트 모델 자체가 다름) | **1** |
| renderer | 1167 + 267 (atlas) | 1429 + 700 (d3d11) + 733 (atlas) + 392 (direct2d) | [renderer.zig](src/renderer.zig) | 부분 — #163 / #165 로 시그니처 정렬 진행 중 | **4** |
| terminal/pty | 315 | 567 | [terminal.zig](src/terminal.zig) | ✓ (init / deinit / write / resize / startReadThread) | **5** |
| font | 265 + 319 | 1165 + 560 | renderer 측에서 호출 | ✗ (CoreText vs DirectWrite) | **2** |
| autostart | 77 | 164 | [autostart.zig](src/autostart.zig) | ✓ (enable / disable) | **5** |
| dialog | 305 | 68 | [dialog.zig](src/dialog.zig) | ✓ (showInfo / showError / showFatal / showConfirm) — 단, About 은 leak | **4** |
| log | 74 | 75 | [log.zig](src/log.zig) | ✓ | **5** |
| paths | shared | shared | [paths.zig](src/paths.zig) | builtin.os.tag branch (필연) | **N/A** |

---

## 2. 이미 통합 잘 된 reference 패턴 (그대로 더 늘리면 됨)

| 영역 | 패턴 | 위치 |
|---|---|---|
| PTY API | wrapper + comptime select, **양쪽 시그니처 완벽 동일** | [terminal.zig](src/terminal.zig) |
| Tab layout | platform-agnostic struct를 두 renderer가 직접 공유 | [tab_layout.zig](src/tab_layout.zig) |
| Tab interaction (rename / drag) | shared state + host가 callback 으로 변경 | [tab_interaction.zig](src/tab_interaction.zig) |
| Tab title 그리기 | iterTabText callback (#167) | [tab_layout.zig](src/tab_layout.zig) |
| Font validation 메시지 | `font/validate.zig` 가 양쪽 host 에서 같은 fatal helper 호출 | [font/validate.zig](src/font/validate.zig) |
| Config Defaults | 단일 source of truth → JSON 템플릿 + native defaults 모두 derive | [config.zig:172-292](src/config.zig#L172) |
| ExtraEnv (COLORFGBG / WSLENV) | shared `buildExtraEnv` | session_core / host |

→ **Linux 추가 시 dispatch 파일 (`*.zig` wrapper) 에 1줄씩만 추가** 하면 되는
구조가 이미 자리 잡음.

---

## 3. 통합 추천 (점수 4-5)

| # | 영역 | 현재 상태 | 제안 | 예상 효과 | 위험 |
|---|---|---|---|---|---|
| **R1** | About dialog leak | [about.zig:61](src/about.zig#L61) 가 `@import("dialog/macos.zig").showAboutAlert(...)` 직접 import — wrapper 우회 | `dialog.zig` 에 `showAboutAlert` 공개 (Windows 는 `showInfo` 로 fallback) | top-level platform leak 1건 제거 | **낮음** |
| **R2** | macOS host 의 hardcoded font 상수 | [host/macos.zig:366-372](src/host/macos.zig#L366) `FONT_FAMILY="Menlo"`, `CELL_WIDTH_SCALE=1.1`, `LINE_HEIGHT_SCALE=0.95` — **정의만 있고 호출 사이트는 이미 `g_config.*` 사용 중** ([host/macos.zig:1869,1880](src/host/macos.zig#L1869)) | 상수 3개 삭제 (dead code) | macOS 도 이미 config 통합 완료 — 코드 유물만 정리 | **낮음** |
| **R3** | Renderer init 시그니처 | Windows: `init(alloc, hwnd, font_chain, font_size, cell_w, cell_h, bg)` / macOS: 다른 시그니처 (host 가 직접 Metal layer 받음) | `renderer.zig` 에 `RendererBackend` 타입 정의 + 양쪽 init 정렬 | host 코드 단순화 (~50-100 LOC) | **중** |
| **R4** | Renderer 호출 API | #165 에서 `renderTabBar` + `renderTerminal` 분리로 통일됐지만 macOS 쪽 진입점 일부 미정렬 | 호출처 `renderTabBar + renderTerminal` 형태로 단일화, wrapper 가 platform 디스패치 | host 의 render trigger 단순화 | **중** |
| **R5** | host 자체는 통합 X | event loop (Win32 message vs CFRunLoop) 모델이 근본적으로 다름 | **현 상태 유지**. 단 host 가 들고 있는 cross-platform state 는 계속 빼낼 가치 있음 (#159 진행 중인 per-tab interaction 등) | host LOC 점진 감소 | **낮음** |

> **결정 (사용자):** R3 / R4 계속 추진. `renderTabBar` + `renderTerminal` 형태로 통일.

---

## 4. Linux 추가 시 가장 먼저 그어야 할 boundary

이미 거의 다 됨. 우선 순위:

1. **host/linux.zig** (신규) — Wayland / X11 event loop, single-instance, hotkey (host 만 신규 작성 필요)
2. **renderer/linux.zig** + 하위 (Vulkan 또는 OpenGL) — block_element / glyph_atlas 일부 공유 가능
3. **font/linux/** — fontconfig + FreeType
4. **terminal/linux.zig** — POSIX `forkpty`, macOS pty 와 거의 동일 (가장 쉬움)
5. **dialog/linux.zig**, **autostart/linux.zig**, **log/linux.zig** — 기존 wrapper 에 1줄씩 추가

§6 / §7 의 첫-실행 resolution 패턴 (한글 fallback chain, $SHELL) 은 Linux
에서도 같은 모양 (fc-match / `getenv("SHELL")`) 으로 자연스럽게 확장된다.

---

## 5. 발견된 코드 오류 / misnomer / dead code

> **검증 등급**: ✅ 코드 직접 확인 / ⚠️ 부분 확인 / ❓ 확인 필요

### 5.1 즉시 정리 가능 (검증 ✅, 비용 낮음)

| # | 위치 | 문제 | 권장 |
|---|---|---|---|
| **E1** | [host/macos.zig:366](src/host/macos.zig#L366) `FONT_FAMILY = "Menlo"` | **dead code** — 호출 사이트는 `g_config.font_families` 를 씀 | 삭제 |
| **E2** | [host/macos.zig:371-372](src/host/macos.zig#L371) `CELL_WIDTH_SCALE / LINE_HEIGHT_SCALE` | **dead code** — host 가 `g_config.cell_width / line_height` 직접 전달 ([host/macos.zig:1880](src/host/macos.zig#L1880)) | 삭제 |
| **E3** | [host/macos.zig:358](src/host/macos.zig#L358) 주석 "font_family 는 config 통합 전까지 hardcoded" | **사실과 불일치** — 이미 config 통합 완료. 주석이 stale | 주석 삭제 또는 "통합 완료" 로 갱신 |
| **E4** | [about.zig:61](src/about.zig#L61) | platform 모듈을 wrapper 우회로 직접 import | dialog.zig 에 `showAboutAlert` 공개 |

### 5.2 비대칭 — Windows / macOS 정책 차이 (검증 ✅, 정책 결정 필요)

| # | 영역 | Windows | macOS | 권장 결정 |
|---|---|---|---|---|
| **A1** | ~~font chain validation 정책~~ | ~~per-entry 검증~~ | ~~chain 전체 lookup 모두 실패해야 fatal — chain[i] 일부 미설치는 통과~~ | **정정**: macOS 도 이미 per-entry strict 였음 ([font/macos/font.zig:65-94](src/font/macos/font.zig#L65)) — `CTFontCreateWithName` + `CTFontCopyFamilyName` 으로 실제 family 검증, match 안 되면 즉시 `showNotFoundFatal`. 분석 보고서의 클레임이 잘못된 것. Phase 4 에서 정책 통일 작업 불필요 |
| **A2** | rename state 접근 | Windows: `App.isRenaming()` 메서드 / macOS: `g_rename.isActive()` 직접 호출 (⚠️ 부분 확인) | — | callback 통일 (#159 의 per-tab 이행 중) |

> **결정 (사용자):** A1 — Windows 가 옳음. 모든 폰트는 시스템에 있어야
> 하고, chain 은 글리프 fallback 순서. 첫 폰트에 없는 글리프는 다음
> 폰트에서 찾고, 모두 없으면 시스템 fallback. **설정 이름까지 바꿔서
> fallback 임을 명확히** 해야 함. → §6.

### 5.3 misnomer / 명명 (⚠️ 부분 확인 — 호출 컨텍스트 따라 판단 필요)

| # | 위치 | 문제 | 권장 |
|---|---|---|---|
| **N1** | [config.zig:528,555](src/config.zig#L528) `fontFamilyUtf16()` / `shellUtf16()` | 이름이 generic — Windows 전용 헬퍼이며 macOS 에서 호출 시 `@compileError`. 네임 스페이싱 부재 | `windowsFontFamilyUtf16` 등으로 prefix, 또는 `os_specific.windows.*` 네임스페이스로 모음 |
| **N2** | [window.zig:337](src/window.zig#L337), [config.zig:320-321](src/config.zig#L320) `cell_width_scale / line_height_scale` | 같은 이름이 두 의미로 쓰임 — config 의 scale factor 와 변환 후 px 값. 혼동 여지 | 하나는 `_factor` suffix, 다른 하나는 `_px` suffix |

### 5.4 의심스러운 패턴 (❓ 확인 필요 — 코드 영향 좁아 우선순위 낮음)

| # | 위치 | 패턴 | 비고 |
|---|---|---|---|
| **S1** | [app_controller.zig:198-199](src/app_controller.zig#L198) | `cell_width / height == 0` 일 때 hardcoded 120 / 30 fallback | font 로드 실패는 이미 `dialog.showFatal` 로 종료시키므로 사실상 도달 불가. 주석 한 줄로 충분 |
| **S2** | [config.zig:286](src/config.zig#L286) `@intCast(@as(u32, Defaults.opacity_pct) * 255 / 100)` | overflow 위험 없음 (`u8 * 255 = u32 범위 내`) | 무시 가능 |
| **S3** | [session_core.zig:163](src/session_core.zig#L163) `interaction` 필드가 Windows 에서 dormant | 주석에 의도 명시됨 (#159 에서 활성화 예정) | 의도된 것 — 추적만 |

---

## 6. Font glyph fallback — schema + 정책 + 마이그레이션

### 6.1 정책 (확정)

1. **모든 chain entry 는 시스템에 설치돼 있어야 한다.** 하나라도 없으면
   startup 시 fatal — Windows 의 현재 동작과 같음. macOS 도 통일.
2. **chain 의 의미는 글리프 fallback 순서.** primary 폰트에 글리프가
   있으면 그 글리프, 없으면 chain 의 다음 폰트, 그 다음… 모두 없으면 OS
   system fallback.
3. **primary 와 fallback 은 어휘로도 분리.** `family` 는 단일 string,
   `glyph_fallback` 은 array.

### 6.2 Schema (Plan A 확정)

```jsonc
{
  "font": {
    "family": "Cascadia Code",
    "glyph_fallback": ["Malgun Gothic", "Segoe UI Emoji", "Segoe UI Symbol"],
    "size": 16,
    "cell_width": 1.0,
    "line_height": 1.0
  }
}
```

- `font.family` — **단일 string**. 시스템에 반드시 설치돼 있어야 함.
- `font.glyph_fallback` — **string array**. 각 entry 가 시스템에 반드시
  설치돼 있어야 함. 빈 array `[]` 허용 (system fallback 만 의존).
- 순서 의미: primary → glyph_fallback[0] → glyph_fallback[1] → … →
  OS system fallback.

### 6.3 OS-specific default 값

primary 폰트의 default 는 platform native (이미 그러함). glyph_fallback
default 는 한글 / 이모지 / 심볼 순서로 OS 기본 설치 폰트를 명시.

| OS | `family` (primary) default | `glyph_fallback` default |
|---|---|---|
| **Windows** | `"Cascadia Code"` | `["Malgun Gothic", "Segoe UI Emoji", "Segoe UI Symbol"]` |
| **macOS** | `"Menlo"` | `["Apple SD Gothic Neo", "Apple Color Emoji", "Apple Symbols"]` |

OS 별 폰트 보장 버전 (모두 현재 지원 OS 에서 안전):

| 폰트 | 보장 OS |
|---|---|
| Cascadia Code | Windows 11 / Win10 22H2+, 또는 별도 설치 |
| Malgun Gothic (맑은 고딕) | Windows Vista+ 기본 |
| Segoe UI Emoji | Windows 8.1+ |
| Segoe UI Symbol | Windows 7+ |
| Menlo | OS X 10.6+ |
| Apple SD Gothic Neo | macOS 10.11 El Capitan+ |
| Apple Color Emoji | OS X 10.7+ |
| Apple Symbols | OS X 10.5+ |

순서가 한글 → 이모지 → 심볼 인 이유: 한글 사용자가 가장 자주 마주치는
fallback 이라 chain 의 앞에 두면 lookup 비용이 적게 든다.

### 6.4 마이그레이션 — 안 함

- **자동 변환 없음.** schema 위반 시 즉시 fatal.
- **fatal 메시지 형식** (실제 문구는 `messages.zig` 에 정의 후 양쪽 host
  동일 사용. Config path 라인은 `font/validate.zig` 의 `showNotFoundFatal`
  와 같이 runtime OS 별 치환):

  `font.family` 가 string 이 아닐 때:
  ```
  Invalid config: font.family must be a string (font name).

  Config path:
    <runtime-resolved>
  ```

  `font.glyph_fallback` 이 string 의 list 가 아닐 때:
  ```
  Invalid config: font.glyph_fallback must be a list of strings (fallback font names).

  Config path:
    <runtime-resolved>
  ```

- 이유: 단순 형식 안내. 마이그레이션 안내 / 이전 schema 의 흔적 없음.

### 6.5 영향 받는 파일 (Phase 4 진입 시 detail plan 으로 보강)

| 파일 | 변경 내용 |
|---|---|
| [config.zig](src/config.zig) | `Defaults.font_family` 를 string 으로, `Defaults.glyph_fallback` array 신규. 둘 다 OS-specific. JSON 템플릿 갱신. parsing 시 `family` 가 array 면 fatal helper 호출. native field rename (`font_families` → `font_family` + `font_glyph_fallback`). |
| [font/validate.zig](src/font/validate.zig) | 메시지 추가: `showOldSchemaFatal()`. 기존 `showNotFoundFatal()` 재사용 (chain 시그니처는 동일). |
| [host/windows.zig](src/host/windows.zig) | per-entry validation loop 가 primary + fallback 모두 같은 strict 정책으로. |
| [host/macos.zig](src/host/macos.zig) | macOS 도 per-entry strict 로 변경 (현재 chain 일부 누락은 통과하던 동작 제거). |
| [renderer/macos.zig](src/renderer/macos.zig), [renderer/windows.zig](src/renderer/windows.zig) | font_family_slice 구성: `[1]string{family}` ++ `glyph_fallback[]`. |
| [messages.zig](src/messages.zig) | `font_old_schema_msg` 추가. |

### 6.6 Phase 4 사용자 시연 시나리오

- 정상: primary + 한글 + 이모지 + 심볼 모두 표시 (glyph fallback 동작).
- 미설치: glyph_fallback 의 entry 1개를 임시로 존재하지 않는 이름으로 변경
  → startup 시 fatal 메시지 + chain dump.
- 구 schema: `"family": ["A", "B"]` 로 적은 config → startup fatal
  ("font.family must be a string"). glyph_fallback 이 string list 가
  아닌 경우도 별도 fatal.

---

## 7. shell default — first-run resolution 패턴

### 7.1 현황

| OS | 현재 default | 동작 |
|---|---|---|
| Windows | `"cmd.exe"` | 명시값. PATH 에서 lookup. |
| macOS | `""` (빈 문자열) | host 가 `$SHELL` env > `/bin/zsh` 순서로 fallback ([host/macos.zig:1924-1929](src/host/macos.zig#L1924)) |

문제: macOS 의 `""` 가 hidden semantics. config 만 봐서는 어떤 shell 이
실행될지 알 수 없음.

### 7.2 결정 (사용자) — first-run dynamic resolution

**첫 실행 시점** (config 파일이 없어서 새로 작성하는 시점) 에 host 가
`$SHELL` env 를 읽어 그 값을 disk JSON 의 `"shell": "..."` 에 명시한다.
`$SHELL` 이 없으면 `"/bin/bash"`. 이후 실행은 disk 에 적힌 명시값을 그대로
읽는다.

```
첫 실행 (config 없음):
  $SHELL = "/usr/local/bin/zsh"
    ↓ host 가 첫 실행 감지 + $SHELL 읽음
  disk: {"shell": "/usr/local/bin/zsh", ...}
  memory: g_config.shell = "/usr/local/bin/zsh"

  $SHELL 없음:
  disk: {"shell": "/bin/bash", ...}
  memory: g_config.shell = "/bin/bash"

이후 실행 (config 있음):
  disk 에 적힌 값 그대로 읽음. host 의 $SHELL 분기 코드 제거.
```

### 7.3 Defaults 단일 source of truth 와의 관계

현재 [config.zig:172-292](src/config.zig#L172) 의 `Defaults` 는 모두
compile-time 상수. `Defaults` 가 단일 source of truth → JSON 템플릿과
memory 의 native default 가 자동 sync.

**first-run resolution** 은 이 모델을 깨지 않는다.

- `Defaults.shell` (macOS) = `"/bin/bash"` — compile-time fallback. memory
  native default 도 `/bin/bash`.
- JSON 템플릿 작성은 별도 step. 템플릿 안에 `"shell": "{s}"` placeholder
  를 두고, 작성 시점에 host 가 `$SHELL` (있으면) 또는 `Defaults.shell`
  (없으면) 을 채워 넣음.
- disk 와 memory 는 항상 같은 값 (disk 작성 = memory 주입 동시 수행).

즉 Defaults 는 fallback 의 책임만 갖고, "사용자 환경 반영" 은 host 의
첫-실행 단계에서 처리.

### 7.4 영향 받는 파일

| 파일 | 변경 내용 |
|---|---|
| [config.zig:222](src/config.zig#L222) | `Defaults.shell` (macOS) = `""` → `"/bin/bash"`. |
| [config.zig](src/config.zig) (DEFAULT_CONFIG_JSON 근처) | JSON 템플릿 작성 fn 에 `shell_resolved: []const u8` 인자 추가. macOS 만 host 가 `$SHELL` 로 채워 호출. |
| [host/macos.zig:1924-1929](src/host/macos.zig#L1924) | runtime 의 `$SHELL` env / `/bin/zsh` fallback 분기 제거 — disk 의 명시값만 사용. |
| [host/windows.zig](src/host/windows.zig) | 변경 없음 (이미 명시값). 단 first-run resolution hook 은 같은 entry point 통과해야 일관 (Linux 추가 시 재사용). |

### 7.5 Linux 일반화

같은 패턴이 Linux 에서도 그대로 적용됨 — `getenv("SHELL")` 또는
`getpwuid(getuid())->pw_shell` 로 첫 실행 시점에 명시. 이후 disk 명시값.
host 별 first-run resolver fn 시그니처를 일관 (`fn resolveShell(alloc) []const u8`)
하게 두면 dispatch 깔끔.

---

## 8. 실행 순서 (Phase 0 ~ 7)

각 Phase 끝마다:

- 빌드 + smoke 테스트 (Windows + macOS)
- main 머지
- #108 트래킹 이슈에 댓글 + 표 업데이트 (사용자 메모)
- "완료" 표현은 사용자 시연 OK 후에만 (사용자 메모)

| Phase | 내용 | 항목 | 위험 | 변경 파일 (요약) | 사용자 시연 포인트 |
|---|---|---|:---:|---|---|
| **0** | macOS dead code / stale 주석 정리 | E1, E2, E3 | 매우 낮음 | host/macos.zig | macOS 빌드 + 폰트 정상 표시 |
| **1** | About dialog wrapper 통합 | E4, R1 | 낮음 | dialog.zig, dialog/macos.zig, dialog/windows.zig, about.zig | About 다이얼로그 (Win + Mac) |
| **2** | config Utf16 헬퍼 네이밍 정리 | N1 | 매우 낮음 | config.zig, host/windows.zig | 빌드 통과 (semantic 변경 없음) |
| **3** | shell default macOS = `/bin/bash` + first-run resolution | §7 | 낮음-중 | config.zig, host/macos.zig (env fallback 제거), JSON 템플릿 | 첫 실행 시 disk config 에 `$SHELL` 명시 확인. 두 번째 실행 시 disk 그대로 사용 확인. `$SHELL` 없는 셸에서도 `/bin/bash` 로 동작 |
| **4** | Font glyph fallback schema + 정책 통일 | A1, §6 | **중-상** | config.zig, font/validate.zig, host/{macos,windows}.zig, renderer/{macos,windows}.zig, messages.zig | (1) 정상 chain 모두 표시 (한글/이모지/심볼) (2) chain entry 1개 임시 미설치 → fatal (3) 구 schema (`family` array) → fatal + 안내 메시지 |
| **5** | Renderer init 시그니처 통일 | R3 | 중 | renderer.zig, renderer/{macos,windows}.zig, host/{macos,windows}.zig | Win + Mac 정상 렌더 |
| **6** | renderTabBar + renderTerminal 호출 통일 | R4 | 중 | renderer.zig, renderer/{macos,windows}.zig, host/{macos,windows}.zig | Win + Mac 탭바 / 터미널 그리기, IME composition, rename 모두 정상 |
| **7** | cell_width_scale 명명 / 변환 정리 | N2 | 낮음 | config.zig, window.zig, host/{macos,windows}.zig | 빌드 통과 |

### 8.1 왜 이 순서인가

- **Phase 0-2** 는 fact 검증 끝나서 risk 거의 0. 워밍업 + 통합 패턴 학습.
- **Phase 3** 는 shell first-run resolution 패턴 도입. 구현 detail
  (Defaults vs runtime resolver 분담) 학습이 Phase 4 의 schema 변경
  설계에 도움.
- **Phase 4** 는 schema breaking + 정책 통일 (양쪽 host 동작 변경) 으로
  가장 큰 변화. Phase 3 까지의 정리가 끝난 안정된 상태에서 진행.
- **Phase 5-6** 는 renderer 의 큰 리팩. Phase 4 에서 font chain 처리가
  안정된 후 진입해야 회귀 추적이 깔끔.
- **Phase 7** 은 5-6 의 renderer 재배치 후 자연스럽게 따라옴.

### 8.2 각 Phase 진입 게이트

- Phase 진입 전: 이 문서의 해당 §에 detail plan (변경 파일 / 함수 /
  마이그레이션) 추가 → 사용자 1줄 OK.
- Phase 종료 후: 변경 사항 commit + 이 문서 status update.

### 8.3 release-notes / breaking change 표시

- **Phase 3**: 새 macOS config 의 shell 이 명시값으로 적힘 — 기존 사용자
  영향 없음 (disk 에 이미 `""` 또는 명시값이 있으면 그대로 사용. 단 §7.4
  의 host fallback 제거로 `""` 으로 명시된 경우 shell_validate 가 잡음).
- **Phase 4**: schema breaking. release-notes 에 명시 + fatal 메시지로
  안내. 자동 변환 없음.

---

## 9. 결정 이력 + open question

### 9.1 결정 완료

| # | 결정 | 일자 | 결정자 |
|---|---|---|---|
| D1 | A1 정책 = Windows strict (모든 chain entry 시스템 존재 필수, 누락 시 fatal) | 2026-05-10 | 사용자 |
| D2 | Phase 4 schema = Plan A (`family` 단일 string + `glyph_fallback` array) | 2026-05-10 | 사용자 |
| D3 | Phase 4 마이그레이션 = 자동 변환 안 함, 구 schema 발견 시 fatal | 2026-05-10 | 사용자 |
| D4 | glyph_fallback default = OS 기본 한글 + 이모지 + 심볼 (§6.3 표) | 2026-05-10 | 사용자 |
| D5 | Phase 3 shell = first-run `$SHELL` resolution (없으면 `/bin/bash`), 이후 disk 명시값 사용. macOS host 의 env fallback 분기 제거 | 2026-05-10 | 사용자 |
| D6 | R3 / R4 (Renderer API 통일, `renderTabBar` + `renderTerminal`) 계속 추진 | 2026-05-10 | 사용자 |

### 9.2 진입 게이트별 confirm 필요

- [ ] Phase 3 진입 전: §7.4 의 변경 파일 list 가 충분한지 (특히 JSON
      템플릿 fn 시그니처) 사용자 검토.
- [ ] Phase 4 진입 전: §6.4 fatal 메시지 문구 사용자 검토.
- [ ] Phase 5 진입 전: #163 / #165 의 기존 PR / commit 들 재확인 후
      RendererBackend 타입 시그니처 detail 보강.

### 9.3 Open (열린 채로 둬도 진행 가능)

- A2 의 macOS `g_rename.isActive()` vs Windows `App.isRenaming()` 통일
  은 #159 의 per-tab interaction 작업에서 자연스럽게 처리 — 별도 Phase X.

---

## 10. 변경 이력

| 날짜 | 변경 |
|---|---|
| 2026-05-10 | 초기 작성 — Phase 0-7 정의, 사용자 결정 D1-D3, D6 반영 |
| 2026-05-10 | §6 schema Plan A 확정, 마이그레이션 안 함 정책, glyph_fallback OS default 표 (한글 → 이모지 → 심볼). §7 first-run `$SHELL` resolution 패턴 명세. §8 Phase 표에 변경 파일 컬럼 추가. §9 결정 이력 표 신설 (D1-D6) |
| 2026-05-10 | Phase 0-3 완료 + commit. §6.4 fatal 메시지 단순화 — 마이그레이션 / 이전 schema 흔적 제거, 형식 안내만. family 와 glyph_fallback 별도 fatal |
| 2026-05-10 | Phase 4 schema breaking 완료. §5.2 A1 정정 — macOS 도 이미 per-entry strict (font/macos/font.zig:65-94 의 CTFontCopyFamilyName 검증). 분석 보고서의 "macOS 관대" 클레임이 잘못된 것. Phase 4 에서 macOS validation 추가 작업 불필요 — config.zig schema + parse + fatal helper 만으로 완료 |
| 2026-05-10 | Phase 5/6 완료 — renderer API 통일. macOS MetalRenderer 의 renderFrame 을 renderTabBar + renderTerminal 두 fn 으로 분리 (frame state stateful, drawable / cmd_buf / encoder / pending tabs 가 두 fn 사이 self 안 보관). renderer.zig 의 RendererBackend 가 macOS 도 dispatch (UnsupportedRendererBackend stub 제거) |
| 2026-05-11 | Phase 7 완료 — config schema 단위 일관 (α-전면). 모든 numeric 필드에 단위 suffix (_percent / _point / _ratio). percent 4개 (width / height / offset / opacity) 가 정수 → 실수 (사용자 세밀 조정용). 내부 변수 (window.cell_width / cell_height) 도 _px suffix. 트래킹 issue 생성 — umbrella #171, hot-reload 후속 #170 |
