# macOS 로컬 개발 setup

기본은 ad-hoc 서명 (`codesign --sign -`) 으로 동작하고, 매 빌드마다 권한
재설정이 필요한 짜증을 줄이려면 *stable signing identity* 가 필요해요.
사용자 환경이 허락하면 self-signed code-signing 인증서를 만들면 macOS TCC
(Privacy & Security 권한) 가 *signing identity + bundle identifier* 로 앱을
식별해 코드가 바뀌어도 같은 앱으로 인식 → 권한 한 번 부여로 계속 유지.

⚠️ **회사 / 학교 등 관리되는 macOS 환경 (MDM, keychain password 정책)** 에서는
keychain access dialog 의 password 가 로그인 password 와 어긋나 막힐 수 있어요.
많은 경우 아래 [문제 해결](#문제-해결) 의 `security set-keychain-password` 로
풀립니다. 그래도 안 되면 옵션 A (ad-hoc) 으로 유지하고 매 빌드마다 권한 다시
부여하세요.

## 옵션 A: ad-hoc (default, 항상 동작)

```bash
zig build -Doptimize=ReleaseFast -Dsimd=true
```

`codesign --sign -` (ad-hoc) 으로 서명. 매 빌드마다 hash 변경 → macOS 가 새
앱으로 인식 → Input Monitoring + Accessibility 권한 다시 요구. 권한 부여
방법은 README 또는 앱 첫 실행 시 stderr 안내 참고.

## 옵션 B: GUI 로 self-signed cert 만들기 (권장)

### 1. cert 생성

1. **Spotlight (Cmd+Space)** → `Keychain Access` (한국어: 키체인 접근) 실행.
2. 메뉴: **Keychain Access → Certificate Assistant → Create a Certificate...**
3. 대화상자:
   - **Name**: `TildazLocal` (공백 없이, 빌드 옵션 인자와 일치).
   - **Identity Type**: `Self Signed Root`.
   - **Certificate Type**: `Code Signing`.
   - "Let me override defaults" 체크 안 해도 OK.
4. **Create** → 자체 서명 경고 → **Continue** → **Done**.
5. Keychain Access 의 **login** keychain → **My Certificates** 에 `TildazLocal`
   가 보이면 cert + private key 정상 매칭.

### 2. trust 추가 (admin password 필요)

GUI 만든 cert 가 codesigning policy 통과하려면 system keychain 에 trust 추가
필요:

```bash
security find-certificate -c TildazLocal -p ~/Library/Keychains/login.keychain-db > /tmp/TildazLocal.crt
sudo security add-trusted-cert -d -r trustRoot -p codeSign \
    -k /Library/Keychains/System.keychain /tmp/TildazLocal.crt
rm /tmp/TildazLocal.crt
```

검증:

```bash
security find-identity -v -p codesigning
```

`TildazLocal` 가 (Invalid Key Usage 없이) 보이면 OK.

### 3. 빌드

```bash
zig build -Dmacos-sign-identity=TildazLocal -Doptimize=ReleaseFast -Dsimd=true
```

처음 빌드 시 keychain access dialog 가 뜸. **macOS 로그인 password** 입력 +
**"항상 허용" (Always Allow)** 클릭 (그냥 "허용" 아님). 영구 허용 등록.

⚠️ **dialog 가 다른 password 를 요구하거나 로그인 password 가 안 먹히면**
회사 keychain 정책일 가능성 높아요. 옵션 A (ad-hoc) 으로 돌아가세요.

### 4. 권한 부여 한 번

```bash
open zig-out/TildaZ.app
```

F1 첫 누름에 macOS 권한 요구:
- System Settings → Privacy & Security → Input Monitoring → tildaz ON
- System Settings → Privacy & Security → Accessibility → tildaz ON

이후 `zig build -Dmacos-sign-identity=TildazLocal -Doptimize=ReleaseFast -Dsimd=true` 로 빌드 + 다시 실행해도
**권한 유지** — signing identity stable. (codesign 창이나 권한 재요구가 다시
나오면 [문제 해결](#문제-해결) 참고.)

### 검증

```bash
codesign -dv zig-out/TildaZ.app 2>&1 | grep -i 'authority\|identifier'
# Authority=TildazLocal
# Identifier=me.ensky0.tildaz
```

## 옵션 C: CLI 자동화 (`setup-cert.sh`) — 권장

`dist/macos/setup-cert.sh` 가 옵션 B 의 전 과정을 한 번에 자동화해요:

```bash
./dist/macos/setup-cert.sh
```

- 이미 유효한 `TildazLocal` identity 가 있으면 **즉시 종료** (몇 번 돌려도 안전).
- 없으면: 옛 잔재 정리 → openssl 로 cert 생성 → login keychain import →
  **`sudo add-trusted-cert` 를 스크립트가 직접** 실행 (system trust) → 결과 검증.
- 비번을 두 번 물어요: 로그인 비번(osascript 창, keychain unlock) + admin
  비번(터미널 `sudo`, system trust).

끝에 `find-identity` 에 `TildazLocal` 가 valid 로 나오면 성공. 이후 빌드·권한
부여는 옵션 B 의 3·4 와 동일. CLI 가 막히면 옵션 B(GUI) 로 fallback.

## 문제 해결

### 빌드 시 codesign 키체인 창이 계속 뜸

첫 서명에 뜨는 "codesign 이 키 접근을 허용하고자 합니다" 창에서 반드시
**"항상 허용"** 을 누르세요. "허용" 은 한 번만이라 다음 빌드에 또 뜹니다.

### "항상 허용" 을 눌러도 로그인 비번이 거부되거나 창이 계속 뜸

관리되는 Mac (MDM, 비밀번호 회전) 에서 **로그인 키체인 암호가 로그인 암호와
어긋난** 경우예요. 키체인 접근 GUI 의 "암호 변경" 은 MDM 이 막을 수 있지만,
CLI 로는 재설정되는 사례가 있어요:

```bash
security set-keychain-password "$HOME/Library/Keychains/login.keychain-db"
# 옛 암호 → 새 암호(로그인 암호와 동일하게) 순으로 입력
```

재설정 후 codesign 이 키에 접근 가능해집니다. (회사 Mac 1대에서 확인 — 환경에
따라 다를 수 있어요. 그래도 안 되면 옵션 A ad-hoc 으로 fallback.)

### 인증서가 여러 개 쌓였거나 이름이 제각각

과거 셋업을 여러 번 하면 `TildazLocal` / `TildaZ Local` / `tildaz Local` 같은
변형 인증서·키가 키체인에 쌓일 수 있어요. `setup-cert.sh` 가 이제 실행 시
잔재를 정리하고 하나만 다시 만들어요. 전부 지우려면
[`uninstall.sh --purge`](./uninstall.sh) 사용.

## ReleaseFast 빌드 + Applications 설치

`TildazLocal` identity가 이미 유효하면 아래 스크립트가 ReleaseFast 빌드와
`/Applications/TildaZ.app` 설치를 한 번에 수행해요. identity가 없으면
`setup-cert.sh`를 먼저 실행하고, 출력된 system trust 명령까지 완료되지 않은
경우에는 안전하게 중단해요.

```bash
./dist/macos/build_and_install.sh
```

설치 경로 또는 identity를 바꿔야 하면 환경변수로 지정할 수 있어요.

```bash
TILDAZ_INSTALL_PATH="$HOME/Applications/TildaZ.app" \
TILDAZ_SIGN_IDENTITY=TildazLocal \
./dist/macos/build_and_install.sh
```

## CI 빌드 (`.github/workflows/release.yml`)

GitHub-hosted runner는 로컬 Keychain을 직접 볼 수 없어요. `TildazLocal`의
certificate + private key를 password-protected PKCS#12(`.p12`)로 내보내고,
다음 두 repository secret으로 저장해요.

- `MACOS_CERTIFICATE_P12_BASE64`: `.p12` 파일의 Base64
- `MACOS_CERTIFICATE_PASSWORD`: `.p12` export 비밀번호

Base64는 암호화가 아니며 전송용 인코딩일 뿐이에요. 보호 경계는 GitHub Actions
secret과 `.p12`의 별도 비밀번호입니다. private key, `.p12`, 비밀번호는 repository,
이슈, workflow log에 넣지 않아요. 공식 절차:

- [Installing an Apple certificate on macOS runners for Xcode development](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [Using secrets in GitHub Actions](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets)

### 최초 등록 / rotation

먼저 다른 identity가 섞이지 않는지 확인해요. 여러 identity가 보이면
`security export -t identities`를 쓰지 말고 Keychain Access의 **My Certificates**에서
`TildazLocal` 하나만 `.p12`로 export해야 해요.

```bash
security find-identity -v -p codesigning ~/Library/Keychains/login.keychain-db
```

`TildazLocal` 하나만 유효한 현재 개발 환경에서는 repository 밖의 권한 제한 TEMP에
export한 뒤 secret을 stdin으로 등록해요. 아래의 실제 비밀번호와 Base64는 출력하지
않아야 합니다.

```bash
SIGNING_TEMP=$(mktemp -d "${TMPDIR%/}/tildaz-signing.XXXXXX")
chmod 700 "$SIGNING_TEMP"
openssl rand -hex 32 -out "$SIGNING_TEMP/p12-password"
perl -pi -e 'chomp if eof' "$SIGNING_TEMP/p12-password"
chmod 600 "$SIGNING_TEMP/p12-password"

security export \
  -k ~/Library/Keychains/login.keychain-db \
  -t identities \
  -f pkcs12 \
  -P "$(cat "$SIGNING_TEMP/p12-password")" \
  -o "$SIGNING_TEMP/TildazLocal.p12"
base64 -i "$SIGNING_TEMP/TildazLocal.p12" \
  -o "$SIGNING_TEMP/TildazLocal.p12.base64"

gh secret set MACOS_CERTIFICATE_P12_BASE64 \
  --repo ensky0/tildaz \
  < "$SIGNING_TEMP/TildazLocal.p12.base64"
gh secret set MACOS_CERTIFICATE_PASSWORD \
  --repo ensky0/tildaz \
  < "$SIGNING_TEMP/p12-password"
```

등록은 값이 아니라 이름과 갱신 시각만 확인해요.

```bash
gh secret list --repo ensky0/tildaz
```

확인 후 TEMP의 `.p12`, Base64, 비밀번호를 삭제해요. 인증서를 새로 만들면 다음 공개
fingerprint 상수도 함께 바꿔야 해요.

- `.github/workflows/release.yml`의 `MACOS_CERTIFICATE_SHA1`
- `.github/workflows/macos-signing-check.yml`의 `MACOS_CERTIFICATE_SHA1`

### runner 동작

GitHub Actions `macos-15` runner에서 `dist/macos/ci-signing.sh install`이 secret을
`RUNNER_TEMP`에 복원하고, 임시 Keychain에 import하고, self-signed certificate를
passwordless `sudo`로 runner System Keychain의 code-signing trust에 임시 등록하고,
공개 fingerprint를 검증해요. GitHub는 Linux/macOS hosted VM이 passwordless `sudo`로
실행됨을 [공식 문서](https://docs.github.com/en/actions/reference/runners/github-hosted-runners#administrative-privileges)에 명시해요. 로컬 실행에서는 기존 system trust만 읽고
trust 설정을 바꾸지 않아요. 이어서
`zig build package -Dmacos-sign-identity=TildazLocal -Doptimize=ReleaseFast -Dsimd=true`를 실행하면
`dist/macos/package.sh`가:

1. `aarch64-macos` 빌드 (Apple Silicon)
2. `x86_64-macos` 빌드 (Intel) — Apple Silicon runner 에서 cross-compile, build.zig 가 `-Dmacos-sdk=$(xcrun --show-sdk-path)` 받음
3. `lipo -create` 로 universal binary 합침
4. `.app` 번들 조립 + `TildazLocal`로 재 codesign
5. `hdiutil create` 로 DMG (volume 안에 `.app` + `Applications` symlink)

`dist/macos/verify-signing.sh`는 strict signature, bundle identifier, signer name,
designated requirement의 certificate fingerprint를 검증해요. `always()` cleanup은
임시 Keychain과 certificate/password 파일을 지웁니다. publish 없이 이 경로만 확인할
때는 **macOS signing smoke test** workflow를 수동 실행해요.

산출물: `tildaz-vX.Y.Z-macos.dmg` 한 파일 — Apple Silicon / Intel Mac 모두 동작 (#133).

`TildazLocal`은 Apple Developer ID가 아닌 자체 서명 identity예요. release 사이
designated requirement가 안정돼 TCC 권한 identity는 유지되지만 notarization이나
다른 Mac의 Gatekeeper trust를 제공하지 않아요. 사용자 첫 실행은 DMG를 마운트해
`.app`을 `Applications`로 드래그한 뒤, macOS가 차단하면 우클릭 \"Open\" 또는
`xattr -d com.apple.quarantine /Applications/TildaZ.app`이 여전히 필요할 수 있어요.
