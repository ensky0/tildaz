tildaz — Windows 터미널 (v0.2.6)

================================================================
소개
================================================================

tildaz 는 Zig + Direct3D 11 로 작성한 경량 Windows 터미널입니다.
ConPTY 를 통해 cmd.exe / PowerShell / WSL 을 구동합니다.

v0.2.6 은 **같은 조건의 Windows Terminal 보다 대량 출력이 1.26배
빠릅니다** (화면 왼쪽 절반 스냅, `time cat` 1.14 MiB CJK 파일,
median of 3: tildaz 0.074s vs Windows Terminal 0.093s).

탭 시작 (WSL 프롬프트 도착) 은 약 548ms 로, 순수 `wsl + bash
interactive` 하한 (~480ms) 에 근접합니다.

================================================================
이 릴리즈의 주요 개선 (v0.2.6)
================================================================

■ ConPTY overlapped 128KB read + perf 인스트루먼테이션 (#77)

  출력 파이프를 named pipe + FILE_FLAG_OVERLAPPED 로 교체하고
  128KB 단위 overlapped ReadFile 로 수신. 단계별 atomic 카운터
  (push / drain / parse / render / present) 를 상시 수집해
  Ctrl+Shift+P 로 C:\tildaz_win\perf.log 에 스냅샷을 덤프합니다.

■ OpenConsole.exe + conpty.dll 번들 (#78)

  Microsoft.Windows.Console.ConPTY nuget 에서 추출한 최신
  OpenConsole / conpty.dll 을 동봉해 시스템 conhost.exe 를 우회합니다.
  시스템 conhost 의 내부 flush 타이밍이 대량 출력의 실제 병목이었고,
  번들 OpenConsole 로 교체 후 throughput 이 기준선 대비 2.2x 로
  올라갑니다.

■ 번들 OpenConsole 탭 시작 지연 수정 (#79)

  번들 OpenConsole 도입 직후 새 탭 프롬프트가 ~3.9초 늦게 뜨는
  회귀가 있었습니다. microsoft/terminal 의 VtIo::StartIfNeeded 가
  기동 시 DA1 (Primary Device Attributes) 응답을 3초 타임아웃으로
  대기하는데, tildaz 가 응답을 돌려주지 않아 매 탭 3초를 그대로
  소비하던 것이 원인이었습니다. 수정은 (a) CreateProcessW 직후
  input pipe 에 \x1b[?61c (VT500 conformance) 를 미리 기록해 race-free
  로 응답을 선제공하고, (b) Windows Terminal 의 호출 순서를 복제해
  CreateProcessW 전에 ConptyShowHidePseudoConsole(true) 를 호출합니다.

  덤으로 이 수정이 data path 에도 영향을 줘서 `time cat` throughput
  이 추가로 개선되었습니다 (OpenConsole 의 VT engine 이 DA1 대기
  동안 완전 초기화되지 않아 data path 에 지연이 전파됐던 것으로
  보입니다).

측정 요약 (1.14 MiB CJK, 화면 왼쪽 절반):

    baseline (v0.2.5)              0.293s   (기준선)
    v0.2.6  (번들 OpenConsole +
             DA1 수정)             0.074s   (3.96x, WT 대비 1.26x 빠름)
    Windows Terminal (동일 조건)    0.093s   (참고)

================================================================
구성 파일
================================================================

    tildaz.exe        본체
    conpty.dll        번들 ConPTY 런타임  (Microsoft, MIT)
    OpenConsole.exe   번들 PTY 호스트     (Microsoft, MIT)

세 파일을 같은 폴더에 두세요. tildaz.exe 실행 시 자동으로
conpty.dll 을 로드하고, conpty.dll 이 sibling OpenConsole.exe 를
PTY 호스트로 스폰합니다.

conpty.dll 이나 OpenConsole.exe 가 누락되면 tildaz 는 kernel32 의
시스템 conhost.exe 로 자동 fallback 합니다. 이 경우 기본 동작은
정상이지만 대량 출력 throughput 이 번들 경로 대비 약 절반 수준이
됩니다.

================================================================
설정
================================================================

처음 실행하면 %APPDATA%\tildaz\config.json 이 생성됩니다.
셸 · 폰트 · 테마 · 키바인딩 등을 직접 수정할 수 있습니다.

주요 키:
    Ctrl+Shift+T        새 탭
    Ctrl+Tab            탭 전환
    Ctrl+Shift+W        탭 닫기
    Ctrl+Shift+R        터미널 리셋 (fullReset)
    Ctrl+Shift+P        perf.log 스냅샷 덤프
    Ctrl+Shift+C / V    복사 / 붙여넣기 (마우스 선택은 자동 복사)
    Ctrl+Shift+←/→      탭 이동

================================================================
라이선스
================================================================

    tildaz       저장소 LICENSE 참조
    conpty.dll   microsoft/terminal, MIT
    OpenConsole  microsoft/terminal, MIT

번들 바이너리는 Microsoft.Windows.Console.ConPTY nuget 1.24.260303001
에서 추출한 것이며, MIT 라이선스로 재배포됩니다.

================================================================
저장소 · 피드백
================================================================

    https://github.com/ensky0/tildaz
