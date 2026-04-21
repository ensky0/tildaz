# 워크플로우

모든 작업은 아래 순서로 진행해요:

1. **이슈 확인** — 관련 이슈가 이미 있는지 확인하고, 없으면 새로 생성
2. **계획 기록** — 이슈에 구체적인 구현 계획을 먼저 댓글로 기록
3. **작업 수행** — 작업하면서 중간 결과, 결정 사항, 변경 이유 등을 계속 이슈에 댓글로 기록
4. **검증** — 빌드 및 테스트, 사용자 직접 확인으로 작업 내용이 올바른지 확인
5. **완료** — 검증이 끝나면 커밋, 새로운 버전으로 릴리즈
6. **이슈 닫기** — 릴리즈 후 이슈를 닫음

# 실행 환경

Windows 환경에서 작업 중이라면 **모든 명령은 WSL에서 실행하는 것을 먼저 고려**해요
(git, gh, 파일 조작 등). `.gitconfig`, SSH 키, 셸 설정 등이 WSL 쪽에 있어서 Windows 셸에서
직접 실행하면 인증·환경 차이로 불필요한 문제가 생기는 경우가 많아요.

예외: `tildaz.exe` 자체는 **Windows 프로그램**이므로 빌드·실행을 WSL 내부에서 하면 안 돼요.
`zig build`는 Windows 셸에서 실행하되, 소스는 UNC 경로(`\\wsl.localhost\Debian\...`)로
접근하고 캐시는 `C:/ziglang/tildaz-cache` 같은 Windows 로컬 경로에 둬요.

# 릴리즈

릴리즈 바이너리는 **반드시 GitHub Actions 를 통해 생성**해요. 로컬에서 만든 zip 을
업로드하지 않음. 태그 `v*` push 가 `.github/workflows/release.yml` 을 트리거해서
windows-2022 러너에서 빌드 → 서명 가능한 아티팩트 + SHA256 생성 → GitHub Release
에 첨부까지 한 번에 해요.

순서:

1. `build.zig` 의 `tildaz_version` 과 `src/tildaz.rc` 의 VERSIONINFO 를 새 버전으로
2. `dist/release-notes/vX.Y.Z.md` 작성
3. 커밋 + `git push origin main`
4. `git tag vX.Y.Z && git push origin vX.Y.Z` — 이게 Actions 를 트리거
5. Actions 가 Green 이 되면 GitHub Release 자동 생성

# 의존성 관리

`build.zig.zon` 의 외부 의존성은 **반드시 특정 commit SHA URL 로 pin**. 즉

    https://github.com/<org>/<repo>/archive/<40-hex-sha>.tar.gz

형식만 허용. `refs/heads/main.tar.gz` 같은 rolling 레퍼런스는 upstream 이 움직이면
CI 의 `zig build --fetch` 가 해시 불일치로 실패해요 (과거 `c41a9ef` 가 같은 이유로
pin 했는데 `e7c3942` 에서 다시 rolling 으로 되돌아갔다가 v0.2.10 에서 CI 가 깨짐).

`.github/workflows/release.yml` 의 sanity check 가 rolling URL 을 거부하도록 박혀
있어서, 실수로 되돌리면 바로 빨갛게 터짐.

ghostty 의존성을 갱신하려면 `dist/update-ghostty.sh` 실행 — upstream main HEAD sha
로 URL + hash 를 자동으로 업데이트해요.
