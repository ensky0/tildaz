# 워크플로우

모든 작업은 아래 순서로 진행해요.

1. **이슈 확인**: 관련 이슈가 이미 있는지 확인하고, 없으면 새로 생성해요.
2. **계획 기록**: 이슈에 구체적인 구현 계획을 먼저 댓글로 기록해요.
3. **작업 수행**: 작업하면서 중간 결과, 결정 사항, 변경 이유 등을 계속 이슈에 댓글로 기록해요.
4. **검증**: 빌드와 테스트를 직접 실행해서 작업 내용이 올바른지 확인해요.
5. **완료**: 검증이 끝나면 커밋하고, 새 버전으로 릴리즈해요.
6. **이슈 닫기**: 릴리즈 후 이슈를 닫아요.

# 문서화

문서는 항상 확인된 내용만 정확하게 작성해요.
추정, 가설, 미확인 내용은 사실처럼 쓰지 말고 `추정`, `가설`, `확인 필요`처럼 상태를 명시해요.
문서화할 때는 가능한 한 **출처 링크를 함께 남겨요**.
특히 GitHub 이슈, 이슈 코멘트, 릴리즈 노트, 작업 기록 문서에는 사실 판단의 근거가 되는 공식 문서, 이슈, 코드, 커밋, 로그 등의 링크를 포함해요.
이 원칙은 GitHub 이슈, 이슈 코멘트, 릴리즈 노트, 작업 기록 문서에 모두 동일하게 적용해요.

# 실행 환경

Windows 환경에서 작업 중이면 **모든 명령은 WSL에서 실행하는 것을 먼저 고려**해요.
`git`, `gh`, 파일 조작 등은 `.gitconfig`, SSH 키, 기타 설정이 WSL 쪽에 있는 경우가 많아서 Windows 셸에서 직접 실행하면 인증이나 환경 차이로 불안한 문제가 생길 수 있어요.

예외: `tildaz.exe` 자체는 **Windows 프로그램**이므로 빌드와 실행은 Windows 쪽에서 해야 해요.
`zig build`는 Windows 셸에서 실행하되, 소스는 UNC 경로(`\\wsl.localhost\Debian\...`)로 접근하고 캐시는 `C:/ziglang/tildaz-cache` 같은 Windows 로컬 경로를 사용해요.

# 릴리즈

릴리즈 바이너리는 **반드시 GitHub Actions를 통해 생성**해요.
로컬에서 만든 zip은 업로드하지 않아요.
`v*` 태그 push가 `.github/workflows/release.yml`을 트리거해서 `windows-2022` 러너에서 빌드하고 서명 가능한 아티팩트와 SHA256을 만들고 GitHub Release까지 한 번에 처리해요.

순서는 아래와 같아요.

1. `build.zig`의 `tildaz_version`과 `src/tildaz.rc`의 VERSIONINFO를 새 버전으로 올려요.
2. `dist/release-notes/vX.Y.Z.md`를 작성해요.
3. 커밋하고 `git push origin main` 해요.
4. `git tag vX.Y.Z && git push origin vX.Y.Z`로 Actions를 트리거해요.
5. Actions가 초록불이면 GitHub Release가 자동 생성돼요.

# 의존성 관리

`build.zig.zon`의 의존성은 **반드시 고정된 commit SHA URL로 pin**해요.

형식은 아래처럼 40자리 commit SHA tarball URL만 사용해요.

`https://github.com/<org>/<repo>/archive/<40-hex-sha>.tar.gz`

`refs/heads/main.tar.gz` 같은 rolling 레퍼런스는 사용하지 않아요.
upstream이 움직이면 CI의 `zig build --fetch`가 캐시 불일치로 실패할 수 있어요.
`.github/workflows/release.yml`에는 rolling URL을 막는 sanity check가 있으니, 실수로 되돌리면 바로 빌드가 깨질 수 있어요.

ghostty 의존성을 갱신하려면 `dist/update-ghostty.sh`를 실행해서 upstream `main` HEAD sha 기준으로 URL과 hash를 함께 업데이트해요.
