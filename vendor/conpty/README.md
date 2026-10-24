# ConPTY bundled runtime

`OpenConsole.exe` + `conpty.dll` 은 `microsoft/terminal` 프로젝트가 배포하는
**Microsoft.Windows.Console.ConPTY** nuget 패키지에서 추출한 파일입니다.

## 왜 번들하나

tildaz 는 시스템 `conhost.exe` (kernel32 `CreatePseudoConsole` 이 스폰) 대신
`OpenConsole.exe` (번들) 을 PTY 호스트로 사용합니다. 시스템 conhost 는 대량
VT 출력 시 flush 타이밍이 보수적이라 throughput 병목이 되는데, 번들 OpenConsole
은 Windows Terminal 과 같은 최신 버전으로 동일 조건에서 2배 이상 빠릅니다.

conpty.dll 의 `ConptyCreatePseudoConsole` export 가 자동으로 sibling (같은 폴더)
의 OpenConsole.exe 를 찾아 스폰합니다. 릴리즈 번들은 이 두 파일을 tildaz.exe 옆
`_internal\` 하위에 함께 두어 (build.zig install 단계) 최상위엔 tildaz.exe 만
노출하고, tildaz.exe 가 `_internal\conpty.dll` 을 절대경로로 로드합니다
(`src/terminal/windows/pty.zig`). 이 번들 런타임은 **필수**입니다 — `_internal\`
에 두 파일이 다 있어야 하며, 하나라도 없으면 tildaz 가 시작 시 에러 다이얼로그를
띄우고 종료합니다 (kernel32 시스템 conhost 로의 fallback 은 제거됨, #339).

## 출처 및 버전

- 패키지: `Microsoft.Windows.Console.ConPTY`
- 버전: `1.25.260930003` (stable)
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

[`tool/conpty-update_windows.ps1`](../../tool/conpty-update_windows.ps1) 이 판 고르기부터 파일 교체까지 해요 ([#757](https://github.com/ensky0/tildaz/issues/757)).

```powershell
powershell.exe -NoProfile -File tool\conpty-update_windows.ps1 -List                  # 지금보다 새 판 목록
powershell.exe -NoProfile -File tool\conpty-update_windows.ps1 -Notes <판>            # 그 사이 ConPTY · 콘솔 변경만
powershell.exe -NoProfile -File tool\conpty-update_windows.ps1 -Version <판>          # 네 파일 · 문서 두 곳 교체
```

- **먼저 `-Notes` 로 변경량을 봐요.** Terminal 릴리즈 노트에서 ConPTY · conhost 항목만 뽑아요. 별로 없으면 다음 판까지 모아서 올려요.
- `-Version` 은 바꿀 네 파일의 Authenticode 서명이 유효하고 서명자가 Microsoft 인지 확인한 뒤에만 복사해요.
- 판 번호가 적힌 곳은 이 파일의 `- 버전:` 줄과 `dist/signpath-application.md` 두 곳이에요. 도구가 둘 다 고쳐요.
  `- 버전:` 줄이 도구가 지금 판을 읽는 단일 출처라 모양을 바꾸지 않아요.

## 업데이트 후 확인

새 판과 지금 판을 **둘 다 빌드해** 견줘요. 판마다 `zig-out\bin` 을 (`_internal` 째로) 다른 폴더에 떠 두면 `-Bin` 으로 넘길 수 있어요.
모두 Windows 실기라 AGENTS.md 대로 시작 전에 알리고 동의를 받아요.

| 확인 | 명령 | 판정 |
|---|---|---|
| ConPTY 계약 — 첫 출력 지연 · 셸에 새는 입력 · 셸 종료 → 앱 종료 · WSL | `tool\conpty-check_windows.ps1 -Bin <판> -Wsl <배포판>` | 5 / 5. 1.25 부터 ConPTY 가 DA1 응답을 기다리지 않아 ([#20536](https://github.com/microsoft/terminal/pull/20536)), 우리가 미리 쓰는 DA1 응답 (`pty.zig`) 이 셸에 새는지 C2 가 본다 |
| 탭 · pane · 크기 · worker · 메뉴 | `tool\actions-check_windows.ps1 -Bin <판>` | FAIL 0 |
| 키 바이트 | `tool\key-bytes-check_windows.ps1 -Bin <판>` | 지금 판과 같은 결과 (공용 표의 목표와 어긋난 칸은 지금 판에도 있는지 먼저 본다) |
| 한글 IME · 붙여넣기 · 탭 전환 | `powershell -STA -File tool\key-redraw-check_windows.ps1 -Bin <판>` | 실패 0 (붙여넣기 칸은 클립보드에 서식이 있으면 도구가 건너뛴다) |
| 검색바 IME · 한자 후보창 | `tool\search-bar-check_windows.ps1 -Mode C -Bin <판>` | 6 / 6 |
| dead key | `tool\deadkey-check\deadkey-check_windows.ps1 -Bin <판>` | 전부 OK |
| 처리량 — **번들한 이유라 떨어지면 안 된다** | 두 판 worktree 에서 번갈아 `zig build stress -Doptimize=fast -Dsimd=true -- throughput --layer pty --mb 64` 5 회씩 | 지금 판과 같은 범위 |
| 컴파일 · 단위 테스트 | `zig build check` · `zig build test` | 통과 |

- arm64 는 작업 기기에 Windows arm64 가 없어 실기를 못 해요. 도구의 서명 확인과 `zig build check` 로 대신해요.
- 처리량은 CPU 를 쓰니 다른 세션의 빌드 · 측정이 없을 때 재요.
