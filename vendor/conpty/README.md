# ConPTY bundled runtime

`OpenConsole.exe` + `conpty.dll` 은 `microsoft/terminal` 프로젝트가 배포하는
**Microsoft.Windows.Console.ConPTY** nuget 패키지에서 추출한 파일입니다.

## 왜 번들하나

tildaz 는 시스템 `conhost.exe` (kernel32 `CreatePseudoConsole` 이 스폰) 대신
`OpenConsole.exe` (번들) 을 PTY 호스트로 사용합니다. 시스템 conhost 는 대량
VT 출력 시 flush 타이밍이 보수적이라 throughput 병목이 되는데, 번들 OpenConsole
은 Windows Terminal 과 같은 최신 버전으로 동일 조건에서 2배 이상 빠릅니다.

conpty.dll 의 `ConptyCreatePseudoConsole` export 가 자동으로 sibling 폴더의
OpenConsole.exe 를 찾아 스폰하므로, tildaz.exe 옆에 두 파일만 함께 배포하면
됩니다. 런타임에 `conpty.dll` 이 없으면 kernel32 의 시스템 conhost 로 자동
fallback 합니다 (`src/conpty.zig` 참조).

## 출처 및 버전

- 패키지: `Microsoft.Windows.Console.ConPTY`
- 버전: `1.24.260303001` (stable)
- 배포: https://www.nuget.org/packages/Microsoft.Windows.Console.ConPTY/
- 원본 저장소: https://github.com/microsoft/terminal
- 라이선스: MIT (이 디렉터리의 `LICENSE.txt` 참조)

## 디렉터리 구조

```
vendor/conpty/
├── LICENSE.txt
├── README.md            (이 파일)
├── x64/
│   ├── conpty.dll       (PE32+ x86_64)
│   └── OpenConsole.exe  (PE32+ x86_64)
└── arm64/
    ├── conpty.dll       (PE32+ ARM64)
    └── OpenConsole.exe  (PE32+ ARM64)
```

`build.zig` 가 target arch 따라 `vendor/conpty/<arch>/` 두 파일을 install bin
에 복사합니다. PE loader 가 arch mismatch 시 `STATUS_INVALID_IMAGE_FORMAT` 로
거부하므로 분리 필수 — x64 binary 를 ARM64 Windows 에서 못 씁니다 (그 반대도).

## 업데이트 방법

```sh
# 새 버전 확인
curl -s https://api.nuget.org/v3-flatcontainer/microsoft.windows.console.conpty/index.json

# 다운로드 + 추출
VER=<버전>
curl -sL -o conpty.nupkg \
  "https://api.nuget.org/v3-flatcontainer/microsoft.windows.console.conpty/$VER/microsoft.windows.console.conpty.$VER.nupkg"
unzip -o conpty.nupkg -d /tmp/conpty_unpacked

# x64
cp /tmp/conpty_unpacked/build/native/runtimes/x64/OpenConsole.exe vendor/conpty/x64/
cp /tmp/conpty_unpacked/runtimes/win-x64/native/conpty.dll        vendor/conpty/x64/

# arm64
cp /tmp/conpty_unpacked/build/native/runtimes/arm64/OpenConsole.exe vendor/conpty/arm64/
cp /tmp/conpty_unpacked/runtimes/win-arm64/native/conpty.dll        vendor/conpty/arm64/
```

업그레이드 후에는 **회귀 테스트** (cat, vim, fzf, 선택·복사, 리사이즈) 를
돌리고 `time cat` throughput 에 이상이 없는지 확인합니다.
