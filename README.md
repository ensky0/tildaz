# TildaZ

Windows용 Quake-style 드롭다운 터미널. Zig + libghostty-vt 기반.

Linux의 [Tilda](https://github.com/lanoxx/tilda) 터미널과 동일한 UX를 Windows에서 제공한다.

## 기능

- **F1** 글로벌 핫키로 터미널 show/hide 토글
- 화면 가장자리(top/bottom/left/right)에 붙는 드롭다운 윈도우
- 크기/위치를 화면 비율(%)로 설정
- Windows 로그인 시 자동 시작
- Ctrl+Shift+V 클립보드 붙여넣기
- 반투명(90%) always-on-top 윈도우

## 빌드

### 필수 요구사항

- [Zig 0.15.2](https://ziglang.org/download/)
- [Visual Studio Build Tools](https://visualstudio.microsoft.com/visual-cpp-build-tools/) (SIMD 가속용)

Build Tools 설치 (winget):
```
winget install Microsoft.VisualStudio.2022.BuildTools --override "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --passive"
```

### 빌드 명령

```bash
# 기본 빌드 (SIMD 활성화)
zig build

# MSVC 없이 빌드 (SIMD 비활성화)
zig build -Dsimd=false

# 릴리즈 빌드
zig build -Doptimize=ReleaseFast
```

## 설정

설정 파일: `%APPDATA%\TildaZ\config.json` (첫 실행 시 자동 생성)

```json
{
  "edge": "top",
  "size": 40,
  "length": 100,
  "offset": 0,
  "shell": "cmd.exe",
  "autostart": false
}
```

| 항목 | 타입 | 기본값 | 설명 |
|------|------|--------|------|
| edge | string | "top" | 화면 가장자리: top, bottom, left, right |
| size | int | 40 | edge 수직 방향 크기 (화면 %) |
| length | int | 100 | edge 평행 방향 크기 (화면 %) |
| offset | int | 0 | edge 평행 방향 위치 (화면 %) |
| shell | string | "cmd.exe" | 실행할 쉘: cmd.exe, powershell.exe, pwsh.exe |
| autostart | bool | false | Windows 로그인 시 자동 시작 |

### 위치 예시

```
edge: "top", size: 40, length: 100, offset: 0
 -> 화면 상단, 높이 40%, 전체 폭

edge: "top", size: 40, length: 60, offset: 20
 -> 화면 상단, 높이 40%, 폭 60%, 왼쪽에서 20% 지점부터

edge: "left", size: 30, length: 80, offset: 10
 -> 화면 왼쪽, 너비 30%, 높이 80%, 위에서 10% 지점부터
```

## 단축키

| 키 | 동작 |
|----|------|
| F1 | 터미널 show/hide 토글 |
| Ctrl+Shift+V | 클립보드 붙여넣기 |

## 기술 스택

| 구성요소 | 선택 |
|---------|------|
| 언어 | Zig 0.15.2 |
| 터미널 에뮬레이션 | [libghostty-vt](https://github.com/ghostty-org/ghostty) |
| PTY | Windows ConPTY |
| 윈도우 | Win32 API (보더리스 팝업) |
| 렌더링 | GDI (TextOutW + 더블 버퍼링) |

## 라이선스

MIT
