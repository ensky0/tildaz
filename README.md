# TildaZ

Windows용 Quake-style 드롭다운 터미널. Zig + libghostty-vt 기반.

Linux의 [Tilda](https://github.com/lanoxx/tilda) 터미널과 동일한 UX를 Windows에서 제공한다.

## 기능

- **F1** 글로벌 핫키로 터미널 show/hide 토글
- **탭 지원**: 독립 터미널 세션을 가진 다중 탭
  - Ctrl+Shift+T 새 탭 생성
  - Ctrl+Shift+W 현재 탭 닫기
  - Alt+1~9 탭 전환
  - 마우스 클릭으로 탭 선택, X 버튼으로 탭 닫기
  - 마우스 드래그로 탭 순서 변경
  - 마지막 탭을 닫으면 앱 종료
- **유니코드 전체 지원**: 한글, CJK, 이모지 등 전각/반각 문자 정상 렌더링
- **ANSI 색상**: 16색/256색/TrueColor 전경·배경색, bold-is-bright, inverse 지원
- **텍스트 선택 및 복사**:
  - 클릭+드래그로 텍스트 선택 (선택 영역 반전 표시)
  - 더블클릭으로 단어 선택
  - 마우스 버튼 놓으면 자동 클립보드 복사
  - 마우스 휠 클릭으로 붙여넣기
- 화면 가장자리(top/bottom/left/right)에 붙는 드롭다운 윈도우
- 크기/위치를 화면 비율(%)로 설정
- Windows 로그인 시 자동 시작
- Ctrl+Shift+V 클립보드 붙여넣기
- 반투명(설정 가능) always-on-top 윈도우
- **17가지 내장 컬러 테마**: Tilda, Ghostty, Dracula, Catppuccin 등

## 빌드

### 필수 요구사항

- [Zig 0.15.2](https://ziglang.org/download/)

### 빌드 명령

```bash
# 기본 빌드
zig build

# 릴리즈 빌드
zig build -Doptimize=ReleaseFast
```

> **참고**: SIMD 가속 옵션(`-Dsimd=true`)은 현재 Windows에서 동작하지 않습니다.
> Zig 0.15 빌드 시스템이 ghostty의 C++ SIMD 소스에 C++ 표준 라이브러리 경로를
> 전달하지 않는 문제입니다. Zig upstream 수정이 필요합니다.

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
    "family": "Consolas",
    "size": 20
  },
  "theme": "Tilda",
  "shell": "wsl.exe -d Debian --cd ~",
  "auto_start": true,
  "hidden_start": true
}
```

| 섹션 | 항목 | 타입 | 범위 | 기본값 | 설명 |
|------|------|------|------|--------|------|
| window | dock_position | string | top, bottom, left, right | "top" | 도킹 위치 |
| window | width | int | 10~100 | 50 | 가로 크기 (화면 %) |
| window | height | int | 10~100 | 100 | 세로 크기 (화면 %) |
| window | offset | int | 0~100 | 100 | 위치 (0=시작, 50=중앙, 100=끝) |
| window | opacity | int | 0~100 | 100 | 윈도우 투명도 (%) |
| font | family | string | - | "Consolas" | 폰트 이름 |
| font | size | int | 8~72 | 20 | 폰트 크기 (px) |
| - | theme | string | [테마 목록](#테마) 참조 | "Tilda" | 컬러 테마 |
| - | shell | string | - | "cmd.exe" | 실행할 쉘 (wsl.exe 등 가능) |
| - | auto_start | bool | true, false | true | Windows 로그인 시 자동 시작 |
| - | hidden_start | bool | true, false | true | 숨김 상태로 시작 |

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
| F1 | 터미널 show/hide 토글 |
| Ctrl+Shift+T | 새 탭 생성 |
| Ctrl+Shift+W | 현재 탭 닫기 |
| Alt+1~9 | 탭 전환 |
| Ctrl+Shift+V | 클립보드 붙여넣기 |
| 마우스 드래그 | 텍스트 선택 + 자동 복사 |
| 더블클릭 | 단어 선택 + 자동 복사 |
| 마우스 휠 클릭 | 클립보드 붙여넣기 |

## 테마

16가지 내장 컬러 테마를 지원한다. `config.json`에서 `"theme"` 값으로 테마 이름을 지정하면 터미널 전경/배경색과 ANSI 16색 팔레트가 적용된다.

### Classic

| 테마 | 배경 | 전경 | 팔레트 미리보기 |
|------|------|------|----------------|
| **Tilda** | ![](https://placehold.co/16x16/000000/000000) `#000000` | ![](https://placehold.co/16x16/ffffff/ffffff) `#FFFFFF` | ![](https://placehold.co/12x12/cc0000/cc0000) ![](https://placehold.co/12x12/4e9a06/4e9a06) ![](https://placehold.co/12x12/c4a000/c4a000) ![](https://placehold.co/12x12/3465a4/3465a4) ![](https://placehold.co/12x12/75507b/75507b) ![](https://placehold.co/12x12/06989a/06989a) |
| **Ghostty** | ![](https://placehold.co/16x16/1d1f21/1d1f21) `#1D1F21` | ![](https://placehold.co/16x16/c5c8c6/c5c8c6) `#C5C8C6` | ![](https://placehold.co/12x12/cc6666/cc6666) ![](https://placehold.co/12x12/b5bd68/b5bd68) ![](https://placehold.co/12x12/f0c674/f0c674) ![](https://placehold.co/12x12/81a2be/81a2be) ![](https://placehold.co/12x12/b294bb/b294bb) ![](https://placehold.co/12x12/8abeb7/8abeb7) |

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
| 윈도우 | Win32 API (보더리스 팝업) |
| 렌더링 | OpenGL 1.1 + 동적 폰트 아틀라스 (WGL) |
| 폰트 래스터라이즈 | Windows GDI (ANTIALIASED_QUALITY) |

## 라이선스

MIT
