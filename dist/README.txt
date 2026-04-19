tildaz — Windows 드롭다운 터미널

================================================================
소개
================================================================

tildaz 는 Zig + Direct3D 11 로 작성한 경량 Windows 터미널입니다.
Linux Tilda 의 Quake-style 드롭다운 UX 를 Windows 에 제공하며,
ConPTY 를 통해 cmd.exe / PowerShell / WSL 을 구동합니다.

DirectWrite + Direct3D 11 ClearType 서브픽셀 렌더링으로 저지연
고품질 텍스트 출력을 지원합니다.

버전별 변경 이력 · 벤치마크는 GitHub Releases 페이지에서 확인할
수 있습니다:

    https://github.com/ensky0/tildaz/releases

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
    F1                  창 show/hide 토글
    Ctrl+Shift+T        새 탭
    Ctrl+Tab            탭 전환
    Ctrl+Shift+W        탭 닫기
    Ctrl+Shift+R        터미널 리셋 (fullReset)
    Ctrl+Shift+I        About / 버전 · exe 경로 · pid 확인
    Ctrl+Shift+P        tildaz.log 에 perf 스냅샷 덤프
    Ctrl+Shift+C / V    복사 / 붙여넣기 (마우스 선택은 자동 복사)
    Ctrl+Shift+←/→      탭 이동

로그 파일:
    %APPDATA%	ildaz	ildaz.log
    부팅 · 종료 · ConPTY 초기화 · autostart 에러 · perf 스냅샷이
    같은 타임라인에 쌓입니다. 예전 버전이 자동 실행되는 등 이상 동작이
    있을 때 사후 추적용.

================================================================
라이선스
================================================================

    tildaz.exe       저장소 LICENSE 참조 (GPL-3.0 + Commons Clause)
                     (libghostty-vt MIT 를 static link
                      — ghostty-org/ghostty)
    conpty.dll       microsoft/terminal, MIT
    OpenConsole.exe  microsoft/terminal, MIT

OpenConsole / conpty 번들 바이너리는 Microsoft.Windows.Console.ConPTY
nuget 에서 추출한 것이며, MIT 라이선스로 재배포됩니다.

================================================================
저장소 · 피드백
================================================================

    https://github.com/ensky0/tildaz
