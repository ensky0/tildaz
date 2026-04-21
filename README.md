# TildaZ

Windows용 Quake-style 드롭다운 터미널. Zig + libghostty-vt 기반.

Linux의 [Tilda](https://github.com/lanoxx/tilda) 터미널과 유사한 UX를 Windows에서 제공한다.

> **v0.2.6 — 퍼포먼스 개선 릴리즈**
>
> 번들 OpenConsole + DA1 핸드셰이크 수정으로 대량 출력이 같은 조건의
> Windows Terminal 보다 **1.26배 빠르다** (`time cat` 1.14 MiB CJK, 화면
> 왼쪽 절반: tildaz 0.074s vs WT 0.093s). WSL 새 탭 프롬프트 도착도
> ~548ms 로, 순수 `wsl + bash interactive` 하한 (~480ms) 에 근접.
> 자세한 내용은 [퍼포먼스](#퍼포먼스) 참고.

## 기능

- **F1** 글로벌 핫키로 터미널 show/hide 토글
- **Alt+Enter** 로 현재 모니터 전체 화면 토글 (작업 영역 = taskbar 제외 전체). F1 hide → F1 show 사이클에서도 전체 화면 상태를 유지, 디스플레이/DPI/작업 영역 변경 시 현재 상태에 맞춰 재배치
- **탭 지원**: 독립 터미널 세션을 가진 다중 탭
  - Ctrl+Shift+T 새 탭 생성
  - Ctrl+Shift+W 현재 탭 닫기
  - Alt+1~9 탭 전환
  - 마우스 클릭으로 탭 선택, X 버튼으로 탭 닫기
  - 마우스 드래그로 탭 순서 변경
  - 마지막 탭을 닫으면 앱 종료
- **유니코드 전체 지원**: 한글, CJK, 이모지 등 전각/반각 문자 정상 렌더링
- **폰트 폴백 체인**: 최대 8개 폰트 지정 가능, 글리프를 못 찾으면 다음 폰트로 자동 폴백
- **ClearType 서브픽셀 렌더링**: DirectWrite + Direct3D 11 셰이더 기반 고품질 텍스트 렌더링
- **번들 OpenConsole**: `OpenConsole.exe` + `conpty.dll` 동봉으로 시스템 `conhost.exe` 우회. 대량 출력 throughput 2.2x, 번들 파일이 없으면 시스템 conhost 로 자동 fallback
- **ANSI 색상**: 16색/256색/TrueColor 전경·배경색, bold-is-bright, inverse 지원
- **18가지 내장 컬러 테마**: Tilda, Ghostty, Windows Terminal, Dracula, Catppuccin 등
- **텍스트 선택 및 복사**:
  - 클릭+드래그로 텍스트 선택 (선택 영역 반전 표시)
  - 더블클릭으로 단어 선택
  - 마우스 버튼 놓으면 자동 클립보드 복사
  - 마우스 휠 클릭으로 붙여넣기
- **스크롤백**: 마우스 휠 스크롤, 스크롤바 드래그, 최대 100,000줄 버퍼. 스크롤백이 많아도 thumb 이 최소 크기 (32px × DPI scale) 를 유지해 드래그 가능
- **vim dark/light 감지**: 테마 배경 밝기에 따라 `COLORFGBG` 환경변수 자동 설정 (WSL 포함)
- 화면 가장자리(top/bottom/left/right)에 붙는 드롭다운 윈도우
- 크기/위치를 화면 비율(%)로 설정
- **멀티 모니터 자동 추적**:
  - F1 로 토글할 때마다 **현재 마우스 커서가 있는 모니터** 에 드롭다운이 등장. 해당 모니터의 work area (작업 표시줄 제외) 기준으로 폭·높이·offset 을 매번 재계산해서 맞춤
  - 해상도 변경 / 외부 모니터 연결·해제 / 작업 표시줄 자동 숨김 토글 / per-monitor DPI 변경도 자동 감지해서 즉시 재배치 (`WM_DISPLAYCHANGE` / `WM_DPICHANGED` / `WM_SETTINGCHANGE`)
  - DPI 가 다른 모니터로 이동하면 GDI 폰트 · cell 크기 · DirectWrite glyph atlas 를 새 DPI 로 재raster 해서 글자가 모니터 배율에 맞춰 다시 그려짐
  - 외부 모니터 해제처럼 창 rect 이 동일해 `WM_SIZE` 가 발생하지 않는 경우에도 terminal grid 를 직접 reflow 해서 새 cell 크기로 화면 전체를 채움
- 반투명(설정 가능) always-on-top 윈도우
- Ctrl+Shift+V 클립보드 붙여넣기
- Ctrl+Shift+R 터미널 초기화 (바이너리 cat 등으로 깨졌을 때)
- **Ctrl+Shift+I** About 다이얼로그 — 현재 실행 중인 tildaz 의 버전 · exe 풀 경로 · pid 를 MessageBox 로 표시. 창에 타이틀바가 없어서 실행 중인 exe 를 식별하기 어려운 문제를 해결
- **PE VERSIONINFO** — `tildaz.exe` 우클릭 → 속성 → 자세히 에서 버전 확인 가능
- **통합 로그** `%APPDATA%\tildaz\tildaz.log` — 부팅 / 종료 / ConPTY 초기화 / autostart 에러 / perf 스냅샷이 같은 타임라인에 쌓임. 기존 `C:\tildaz_win\perf.log` 하드코딩 경로 대체
- Ctrl+Shift+P 퍼포먼스 스냅샷 덤프 (`tildaz.log` 에 push / drain / parse / render / present 단계별 ms·bytes·calls 기록)
- **Windows 로그인 시 자동 시작** — HKCU\Software\Microsoft\Windows\CurrentVersion\Run 레지스트리 값으로 등록. (v0.2.7 까지는 Task Scheduler 기반이었으나 Group Policy / UAC 설정에 따라 `schtasks /create` 가 거부되어 stale 엔트리가 영구히 남는 사고가 있어 v0.2.8 에서 Registry Run 으로 단일화)

## 빌드

### 필수 요구사항

- [Zig 0.15.2](https://ziglang.org/download/)

### 빌드 명령

```bash
# 기본 빌드 (ReleaseFast)
zig build

# 디버그 빌드
zig build -Doptimize=Debug
```

> **참고**: SIMD 가속 옵션(`-Dsimd=true`)은 현재 Windows에서 동작하지 않습니다.
> Zig 0.15 빌드 시스템이 ghostty의 C++ SIMD 소스에 C++ 표준 라이브러리 경로를
> 전달하지 않는 문제입니다. Zig upstream 수정이 필요합니다.

### 배포 (릴리즈)

v0.2.6 부터는 3-file 번들을 단일 zip 으로 배포한다.

```
tildaz-v<ver>-win-x64.zip
  tildaz.exe        본체
  conpty.dll        번들 ConPTY 런타임 (MIT, microsoft/terminal)
  OpenConsole.exe   번들 PTY 호스트     (MIT, microsoft/terminal)
  README.txt        (dist/windows/README.txt)
```

세 파일은 **같은 폴더에** 두어야 번들 경로가 동작한다. `conpty.dll` 또는
`OpenConsole.exe` 가 누락되면 tildaz 는 시스템 `kernel32` conhost 로 자동
fallback 하며, 이 경우 기본 동작은 정상이지만 대량 출력 throughput 이 번들
경로 대비 약 절반 수준이 된다.

#### 번들 빌드 — `zig build package`

```bash
zig build package
# → zig-out/release/tildaz-v<ver>-win-x64.zip
# → zig-out/release/tildaz-v<ver>-win-x64.zip.sha256   (sha256sum -c 호환)
```

내부적으로 `bash dist/windows/package.sh --version <ver>` 를 호출하며,
Windows Git Bash / macOS / Linux 어디서든 동작. zip 압축은 Windows 에서
PowerShell `Compress-Archive`, mac/linux 에서는 `zip` 을 쓴다 (각 OS
기본 도구만 사용, Python/Node/외부 의존성 없음).

#### 태깅 + 릴리즈 — `dist/release.sh`

`.` 에서 한 줄로 태깅 + GitHub Release 생성:

```bash
# 사전: build.zig 의 tildaz_version 을 원하는 버전으로 먼저 bump + commit
dist/release.sh --version 0.2.9              # 정상 플로우 (tag push → Actions)
dist/release.sh --version 0.2.9 --dry-run    # 빌드/패키지만 리허설, tag push 안 함
dist/release.sh --version 0.2.9 --local-upload   # Actions 없이 로컬에서 직접 gh release
```

태그가 push 되면 `.github/workflows/release.yml` (Windows runner) 이
`zig build package` → zip + sha256 업로드 → `dist/release-notes/v<ver>.md`
를 Release body 로 첨부하는 과정을 자동화한다. 수동 재시도가 필요하면
Actions 의 `workflow_dispatch` 로 태그를 넣어 재실행 가능.

릴리즈 노트는 **태그를 push 하기 전에** `dist/release-notes/v<ver>.md` 로
repo 에 체크인되어 있어야 한다 (`release.sh` 의 pre-flight check 가
파일 존재를 강제).

## 설정

설정 파일 경로: `tildaz.exe`와 같은 디렉토리의 `config.json`

설정 파일이 없으면 첫 실행 시 기본값으로 자동 생성된다.

```json
{
  "window": {
    "dock_position": "top",
    "width": 50,
    "height": 100,
    "offset": 100,
    "opacity": 100
  },
  "font": {
    "family": ["Cascadia Mono", "Malgun Gothic", "Segoe UI Symbol"],
    "size": 20,
    "line_height": 0.95,
    "cell_width": 1.2
  },
  "theme": "Tilda",
  "shell": "cmd.exe",
  "auto_start": true,
  "hidden_start": false,
  "max_scroll_lines": 100000
}
```

| 섹션 | 항목 | 타입 | 범위 | 기본값 | 설명 |
|------|------|------|------|--------|------|
| window | dock_position | string | top, bottom, left, right | "top" | 도킹 위치 |
| window | width | int | 10~100 | 50 | 가로 크기 (화면 %) |
| window | height | int | 10~100 | 100 | 세로 크기 (화면 %) |
| window | offset | int | 0~100 | 100 | 위치 (0=시작, 50=중앙, 100=끝) |
| window | opacity | int | 0~100 | 100 | 윈도우 투명도 (%) |
| font | family | string 또는 string[] | - | ["Cascadia Mono", "Malgun Gothic", "Segoe UI Symbol"] | 폰트 (배열 시 폴백 체인, 최대 8개) |
| font | size | int | 8~72 | 20 | 폰트 크기 (px) |
| font | line_height | float | 0.1~10.0 | 0.95 | 줄 높이 배율 (1.0 = 기본 행간) |
| font | cell_width | float | 0.1~10.0 | 1.2 | 셀 너비 배율 (1.0 = 기본 자간) |
| - | theme | string | [테마 목록](#테마) 참조 | "Tilda" | 컬러 테마 |
| - | shell | string | - | "cmd.exe" | 실행할 쉘 (wsl.exe -d Debian --cd ~ 등 가능) |
| - | auto_start | bool | true, false | true | Windows 로그인 시 자동 시작 |
| - | hidden_start | bool | true, false | false | 숨김 상태로 시작 |
| - | max_scroll_lines | int | 100~100,000 | 100,000 | 스크롤백 버퍼 (라인 수) |

### 위치 예시

```
"window": { "dock_position": "top", "width": 100, "height": 40, "offset": 0 }
 -> 화면 상단, 전체 폭, 높이 40%, 왼쪽 끝

"window": { "dock_position": "top", "width": 60, "height": 40, "offset": 50 }
 -> 화면 상단, 폭 60%, 높이 40%, 중앙

"window": { "dock_position": "top", "width": 50, "height": 100, "offset": 100 }
 -> 화면 상단, 폭 50%, 전체 높이, 오른쪽 끝에 붙음

"window": { "dock_position": "left", "width": 30, "height": 80, "offset": 50 }
 -> 화면 왼쪽, 너비 30%, 높이 80%, 세로 중앙
```

## 단축키

| 키 | 동작 |
|----|------|
| F1 | 터미널 show/hide 토글 (fullscreen 상태는 그대로 유지) |
| Alt+Enter | 현재 모니터 전체 화면 토글 (작업 영역 기준) |
| Ctrl+Shift+T | 새 탭 생성 |
| Ctrl+Shift+W | 현재 탭 닫기 |
| Alt+1~9 | 탭 전환 |
| Ctrl+Shift+R | 터미널 초기화 (바이너리 cat 등으로 깨졌을 때) |
| Ctrl+Shift+V | 클립보드 붙여넣기 |
| Ctrl+Shift+I | About — 버전 · exe 풀 경로 · pid MessageBox |
| Ctrl+Shift+P | 퍼포먼스 스냅샷 덤프 (`%APPDATA%\tildaz\tildaz.log`) |
| 마우스 드래그 | 텍스트 선택 + 자동 복사 |
| 더블클릭 | 단어 선택 + 자동 복사 |
| 마우스 휠 | 스크롤 |
| 마우스 휠 클릭 | 클립보드 붙여넣기 |

## 테마

18가지 내장 컬러 테마를 지원한다. `config.json`에서 `"theme"` 값으로 테마 이름을 지정하면 터미널 전경/배경색과 ANSI 16색 팔레트가 적용된다.

### Classic

| 테마 | 배경 | 전경 | 팔레트 미리보기 |
|------|------|------|----------------|
| **Tilda** | ![](https://placehold.co/16x16/000000/000000) `#000000` | ![](https://placehold.co/16x16/ffffff/ffffff) `#FFFFFF` | ![](https://placehold.co/12x12/cc0000/cc0000) ![](https://placehold.co/12x12/4e9a06/4e9a06) ![](https://placehold.co/12x12/c4a000/c4a000) ![](https://placehold.co/12x12/3465a4/3465a4) ![](https://placehold.co/12x12/75507b/75507b) ![](https://placehold.co/12x12/06989a/06989a) |
| **Ghostty** | ![](https://placehold.co/16x16/1d1f21/1d1f21) `#1D1F21` | ![](https://placehold.co/16x16/c5c8c6/c5c8c6) `#C5C8C6` | ![](https://placehold.co/12x12/cc6666/cc6666) ![](https://placehold.co/12x12/b5bd68/b5bd68) ![](https://placehold.co/12x12/f0c674/f0c674) ![](https://placehold.co/12x12/81a2be/81a2be) ![](https://placehold.co/12x12/b294bb/b294bb) ![](https://placehold.co/12x12/8abeb7/8abeb7) |
| **Windows Terminal** | ![](https://placehold.co/16x16/0c0c0c/0c0c0c) `#0C0C0C` | ![](https://placehold.co/16x16/cccccc/cccccc) `#CCCCCC` | ![](https://placehold.co/12x12/c50f1f/c50f1f) ![](https://placehold.co/12x12/13a10e/13a10e) ![](https://placehold.co/12x12/c19c00/c19c00) ![](https://placehold.co/12x12/0037da/0037da) ![](https://placehold.co/12x12/881798/881798) ![](https://placehold.co/12x12/3a96dd/3a96dd) |

### Dark 테마

| 테마 | 배경 | 전경 | 팔레트 미리보기 |
|------|------|------|----------------|
| **Catppuccin Mocha** | ![](https://placehold.co/16x16/1e1e2e/1e1e2e) `#1E1E2E` | ![](https://placehold.co/16x16/cdd6f4/cdd6f4) `#CDD6F4` | ![](https://placehold.co/12x12/f38ba8/f38ba8) ![](https://placehold.co/12x12/a6e3a1/a6e3a1) ![](https://placehold.co/12x12/f9e2af/f9e2af) ![](https://placehold.co/12x12/89b4fa/89b4fa) ![](https://placehold.co/12x12/f5c2e7/f5c2e7) ![](https://placehold.co/12x12/94e2d5/94e2d5) |
| **Dracula** | ![](https://placehold.co/16x16/282a36/282a36) `#282A36` | ![](https://placehold.co/16x16/f8f8f2/f8f8f2) `#F8F8F2` | ![](https://placehold.co/12x12/ff5555/ff5555) ![](https://placehold.co/12x12/50fa7b/50fa7b) ![](https://placehold.co/12x12/f1fa8c/f1fa8c) ![](https://placehold.co/12x12/bd93f9/bd93f9) ![](https://placehold.co/12x12/ff79c6/ff79c6) ![](https://placehold.co/12x12/8be9fd/8be9fd) |
| **Gruvbox Dark** | ![](https://placehold.co/16x16/282828/282828) `#282828` | ![](https://placehold.co/16x16/ebdbb2/ebdbb2) `#EBDBB2` | ![](https://placehold.co/12x12/cc241d/cc241d) ![](https://placehold.co/12x12/98971a/98971a) ![](https://placehold.co/12x12/d79921/d79921) ![](https://placehold.co/12x12/458588/458588) ![](https://placehold.co/12x12/b16286/b16286) ![](https://placehold.co/12x12/689d6a/689d6a) |
| **Tokyo Night** | ![](https://placehold.co/16x16/1a1b26/1a1b26) `#1A1B26` | ![](https://placehold.co/16x16/c0caf5/c0caf5) `#C0CAF5` | ![](https://placehold.co/12x12/f7768e/f7768e) ![](https://placehold.co/12x12/9ece6a/9ece6a) ![](https://placehold.co/12x12/e0af68/e0af68) ![](https://placehold.co/12x12/7aa2f7/7aa2f7) ![](https://placehold.co/12x12/bb9af7/bb9af7) ![](https://placehold.co/12x12/7dcfff/7dcfff) |
| **Nord** | ![](https://placehold.co/16x16/2e3440/2e3440) `#2E3440` | ![](https://placehold.co/16x16/d8dee9/d8dee9) `#D8DEE9` | ![](https://placehold.co/12x12/bf616a/bf616a) ![](https://placehold.co/12x12/a3be8c/a3be8c) ![](https://placehold.co/12x12/ebcb8b/ebcb8b) ![](https://placehold.co/12x12/81a1c1/81a1c1) ![](https://placehold.co/12x12/b48ead/b48ead) ![](https://placehold.co/12x12/88c0d0/88c0d0) |
| **One Half Dark** | ![](https://placehold.co/16x16/282c34/282c34) `#282C34` | ![](https://placehold.co/16x16/dcdfe4/dcdfe4) `#DCDFE4` | ![](https://placehold.co/12x12/e06c75/e06c75) ![](https://placehold.co/12x12/98c379/98c379) ![](https://placehold.co/12x12/e5c07b/e5c07b) ![](https://placehold.co/12x12/61afef/61afef) ![](https://placehold.co/12x12/c678dd/c678dd) ![](https://placehold.co/12x12/56b6c2/56b6c2) |
| **Solarized Dark** | ![](https://placehold.co/16x16/001e27/001e27) `#001E27` | ![](https://placehold.co/16x16/9cc2c3/9cc2c3) `#9CC2C3` | ![](https://placehold.co/12x12/d11c24/d11c24) ![](https://placehold.co/12x12/6cbe6c/6cbe6c) ![](https://placehold.co/12x12/a57706/a57706) ![](https://placehold.co/12x12/2176c7/2176c7) ![](https://placehold.co/12x12/c61c6f/c61c6f) ![](https://placehold.co/12x12/259286/259286) |
| **Monokai Soda** | ![](https://placehold.co/16x16/1a1a1a/1a1a1a) `#1A1A1A` | ![](https://placehold.co/16x16/c4c5b5/c4c5b5) `#C4C5B5` | ![](https://placehold.co/12x12/f4005f/f4005f) ![](https://placehold.co/12x12/98e024/98e024) ![](https://placehold.co/12x12/fa8419/fa8419) ![](https://placehold.co/12x12/9d65ff/9d65ff) ![](https://placehold.co/12x12/f4005f/f4005f) ![](https://placehold.co/12x12/58d1eb/58d1eb) |
| **Rosé Pine** | ![](https://placehold.co/16x16/191724/191724) `#191724` | ![](https://placehold.co/16x16/e0def4/e0def4) `#E0DEF4` | ![](https://placehold.co/12x12/eb6f92/eb6f92) ![](https://placehold.co/12x12/31748f/31748f) ![](https://placehold.co/12x12/f6c177/f6c177) ![](https://placehold.co/12x12/9ccfd8/9ccfd8) ![](https://placehold.co/12x12/c4a7e7/c4a7e7) ![](https://placehold.co/12x12/ebbcba/ebbcba) |
| **Kanagawa** | ![](https://placehold.co/16x16/1f1f28/1f1f28) `#1F1F28` | ![](https://placehold.co/16x16/dcd7ba/dcd7ba) `#DCD7BA` | ![](https://placehold.co/12x12/c34043/c34043) ![](https://placehold.co/12x12/76946a/76946a) ![](https://placehold.co/12x12/c0a36e/c0a36e) ![](https://placehold.co/12x12/7e9cd8/7e9cd8) ![](https://placehold.co/12x12/957fb8/957fb8) ![](https://placehold.co/12x12/6a9589/6a9589) |
| **Everforest Dark** | ![](https://placehold.co/16x16/1e2326/1e2326) `#1E2326` | ![](https://placehold.co/16x16/d3c6aa/d3c6aa) `#D3C6AA` | ![](https://placehold.co/12x12/e67e80/e67e80) ![](https://placehold.co/12x12/a7c080/a7c080) ![](https://placehold.co/12x12/dbbc7f/dbbc7f) ![](https://placehold.co/12x12/7fbbb3/7fbbb3) ![](https://placehold.co/12x12/d699b6/d699b6) ![](https://placehold.co/12x12/83c092/83c092) |

### Light 테마

| 테마 | 배경 | 전경 | 팔레트 미리보기 |
|------|------|------|----------------|
| **Catppuccin Latte** | ![](https://placehold.co/16x16/eff1f5/eff1f5) `#EFF1F5` | ![](https://placehold.co/16x16/4c4f69/4c4f69) `#4C4F69` | ![](https://placehold.co/12x12/d20f39/d20f39) ![](https://placehold.co/12x12/40a02b/40a02b) ![](https://placehold.co/12x12/df8e1d/df8e1d) ![](https://placehold.co/12x12/1e66f5/1e66f5) ![](https://placehold.co/12x12/ea76cb/ea76cb) ![](https://placehold.co/12x12/179299/179299) |
| **Solarized Light** | ![](https://placehold.co/16x16/fdf6e3/fdf6e3) `#FDF6E3` | ![](https://placehold.co/16x16/657b83/657b83) `#657B83` | ![](https://placehold.co/12x12/dc322f/dc322f) ![](https://placehold.co/12x12/859900/859900) ![](https://placehold.co/12x12/b58900/b58900) ![](https://placehold.co/12x12/268bd2/268bd2) ![](https://placehold.co/12x12/d33682/d33682) ![](https://placehold.co/12x12/2aa198/2aa198) |
| **Gruvbox Light** | ![](https://placehold.co/16x16/fbf1c7/fbf1c7) `#FBF1C7` | ![](https://placehold.co/16x16/3c3836/3c3836) `#3C3836` | ![](https://placehold.co/12x12/cc241d/cc241d) ![](https://placehold.co/12x12/98971a/98971a) ![](https://placehold.co/12x12/d79921/d79921) ![](https://placehold.co/12x12/458588/458588) ![](https://placehold.co/12x12/b16286/b16286) ![](https://placehold.co/12x12/689d6a/689d6a) |
| **One Half Light** | ![](https://placehold.co/16x16/fafafa/fafafa) `#FAFAFA` | ![](https://placehold.co/16x16/383a42/383a42) `#383A42` | ![](https://placehold.co/12x12/e45649/e45649) ![](https://placehold.co/12x12/50a14f/50a14f) ![](https://placehold.co/12x12/c18401/c18401) ![](https://placehold.co/12x12/0184bc/0184bc) ![](https://placehold.co/12x12/a626a4/a626a4) ![](https://placehold.co/12x12/0997b3/0997b3) |

> 테마를 지정하지 않으면 Tilda 팔레트가 사용된다.

## 알려진 제한사항

- **F1 핫키가 관리자 권한 앱 위에서 동작하지 않음**: 작업관리자, regedit 등 관리자 권한(elevated)으로 실행된 앱이 포커스된 상태에서는 F1 토글이 동작하지 않습니다. Windows UIPI(User Interface Privilege Isolation) 보안 정책에 의한 제한으로, TildaZ를 관리자 권한으로 실행하면 해결되지만 권장하지 않습니다.

## 기술 스택

| 구성요소 | 선택 |
|---------|------|
| 언어 | Zig 0.15.2 |
| 터미널 에뮬레이션 | [libghostty-vt](https://github.com/ghostty-org/ghostty) |
| PTY | Windows ConPTY |
| PTY 호스트 | 번들 `OpenConsole.exe` + `conpty.dll` ([microsoft/terminal](https://github.com/microsoft/terminal), MIT) · 누락 시 시스템 conhost 로 fallback |
| 윈도우 | Win32 API (보더리스 팝업) |
| 렌더링 | Direct3D 11 + HLSL 셰이더 (ClearType 서브픽셀 블렌딩) |
| 폰트 래스터라이즈 | DirectWrite (동적 폰트 아틀라스 + 시스템 폰트 폴백) |

## 퍼포먼스

v0.2.6 기준 측정. 모든 수치는 화면 왼쪽 절반 스냅 (Windows Terminal 과 동일 grid)
에서 `time cat ~/repo/s2t/bitext_eng_kor.vocab` (1.14 MiB CJK) 3회 median,
WSL Debian.

| 경로 | `time cat` real | throughput | vs WT |
|------|-----------------|------------|-------|
| baseline v0.2.5 (시스템 conhost) | 0.293s | ~4.7 MiB/s | 3.2x 느림 |
| #77 overlapped 128KB read | 0.266s | ~5.2 MiB/s | 2.9x 느림 |
| #78 번들 OpenConsole (회귀 포함) | 0.133s | ~10.5 MiB/s | 1.4x 느림 |
| **v0.2.6 (#77 + #78 + #79)** | **0.074s** | **~15.4 MiB/s** | **1.26x 빠름** |
| Windows Terminal (참고, 동일 grid) | 0.093s | ~12.3 MiB/s | 1.0x |

- **#77** — ConPTY output 파이프를 named pipe + `FILE_FLAG_OVERLAPPED` 로 교체,
  128KB overlapped `ReadFile` + `GetOverlappedResult` 패턴. 단계별 atomic
  counter (`src/perf.zig`) 상시 수집, Ctrl+Shift+P 스냅샷.
- **#78** — `vendor/conpty/` 에 Microsoft.Windows.Console.ConPTY nuget
  `1.24.260303001` 의 `OpenConsole.exe` (1.04 MB) + `conpty.dll` (110 KB) 동봉.
  시작 시 `LoadLibraryW("conpty.dll")` → 성공 시 `ConptyCreatePseudoConsole`
  등을 kernel32 대신 사용. DLL 미존재 시 kernel32 경로로 자동 fallback. 시스템
  conhost 의 내부 flush 타이밍이 실제 병목이었음을 확증.
- **#79** — 번들 OpenConsole 의 `VtIo::StartIfNeeded` 가 기동 시 DA1 (`\x1b[c`)
  를 3초 타임아웃 대기하던 회귀를 수정. (a) `CreateProcessW` 직후 input pipe
  에 `\x1b[?61c` (VT500 conformance) pre-write, (b) `CreateProcessW` 전에
  `ConptyShowHidePseudoConsole(true)` 호출. 탭 시작 ~3997ms → **~548ms**, 부수
  효과로 `time cat` 도 0.133s → 0.074s (VT engine 이 DA1 대기 중 완전
  초기화되지 않아 data path 에 지연이 전파되던 구간 제거).

탭 시작 측정 (`wsl.exe -d Debian --cd ~`, warm):

| 경로 | 프롬프트 도착 |
|------|---------------|
| baseline (kernel32, 시스템 conhost) | ~860 ms |
| #78 직후 (번들 OpenConsole, 회귀) | ~3997 ms |
| **v0.2.6 (#78 + #79)** | **~548 ms** |
| 순수 `wsl + bash interactive` 하한 | ~480 ms |

## 라이선스

tildaz 자체는 **GPL-3.0 + Commons Clause** — 전체 조항은 [`LICENSE`](./LICENSE) 참고.

### 동봉 / 링크된 서드파티

| 구성요소 | 라이선스 | 출처 | 비고 |
|---------|----------|------|------|
| `libghostty-vt` | MIT | [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty) | `build.zig.zon` 의 `ghostty` dep 로 소스 가져와 `tildaz.exe` 에 static link |
| `OpenConsole.exe` | MIT | [microsoft/terminal](https://github.com/microsoft/terminal) (Microsoft.Windows.Console.ConPTY nuget 1.24.260303001) | 릴리즈 zip 에 동봉 — `vendor/conpty/LICENSE.txt` |
| `conpty.dll` | MIT | 동일 | 동일 |

MIT 원문 전체는 각 upstream 저장소 / 번들 `LICENSE.txt` 참고.
