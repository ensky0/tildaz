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

설정 파일 경로 (우선순위):
1. `tildaz.exe`와 같은 디렉토리의 `config.json` (portable mode)
2. `%APPDATA%\TildaZ\config.json` (첫 실행 시 자동 생성)

```json
{
  "window": {
    "dock_position": "top",
    "width": 50,
    "height": 100,
    "offset": 100
  },
  "font": {
    "family": "Consolas",
    "size": 16
  },
  "shell": "wsl.exe -d Debian --cd ~",
  "auto_start": false,
  "hidden_start": false
}
```

| 섹션 | 항목 | 타입 | 범위 | 기본값 | 설명 |
|------|------|------|------|--------|------|
| window | dock_position | string | top, bottom, left, right | "top" | 도킹 위치 |
| window | width | int | 10~100 | 40 | 가로 크기 (화면 %) |
| window | height | int | 10~100 | 100 | 세로 크기 (화면 %) |
| window | offset | int | 0~100 | 0 | 위치 (0=시작, 50=중앙, 100=끝) |
| font | family | string | - | "Consolas" | 폰트 이름 |
| font | size | int | 8~72 | 16 | 폰트 크기 (px) |
| - | shell | string | - | "cmd.exe" | 실행할 쉘 (wsl.exe 등 가능) |
| - | auto_start | bool | true, false | false | Windows 로그인 시 자동 시작 |
| - | hidden_start | bool | true, false | false | 숨김 상태로 시작 |

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
| Ctrl+Shift+V | 클립보드 붙여넣기 |

## 알려진 제한사항

- **F1 핫키가 관리자 권한 앱 위에서 동작하지 않음**: 작업관리자, regedit 등 관리자 권한(elevated)으로 실행된 앱이 포커스된 상태에서는 F1 토글이 동작하지 않습니다. Windows UIPI(User Interface Privilege Isolation) 보안 정책에 의한 제한으로, TildaZ를 관리자 권한으로 실행하면 해결되지만 권장하지 않습니다.

## 기술 스택

| 구성요소 | 선택 |
|---------|------|
| 언어 | Zig 0.15.2 |
| 터미널 에뮬레이션 | [libghostty-vt](https://github.com/ghostty-org/ghostty) |
| PTY | Windows ConPTY |
| 윈도우 | Win32 API (보더리스 팝업) |
| 렌더링 | OpenGL 1.1 + 폰트 아틀라스 (WGL) |

## 라이선스

MIT
