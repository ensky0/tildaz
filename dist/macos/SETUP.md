# macOS 로컬 개발 setup

## 1. self-signed code signing 인증서 만들기 (한 번만)

ad-hoc 서명 (`codesign --sign -`) 은 빌드마다 hash 가 변경되어 macOS TCC
(Privacy & Security 권한) 가 매번 재부여를 요구해요. 로컬에서 자주 빌드 /
실행할 때 매우 짜증.

self-signed code signing 인증서를 한 번 만들어 그걸로 sign 하면 코드가
바뀌어도 *signing identity + bundle identifier* 이 일정해 macOS 가 같은 앱으로
인식 → 권한 한 번 부여로 계속 유지.

**Keychain Access GUI 로 만들기 (5분):**

1. `Keychain Access.app` 실행 (Spotlight: "Keychain Access").
2. 메뉴: **Keychain Access → Certificate Assistant → Create a Certificate**.
3. 대화상자:
   - **Name**: `tildaz Local` (원하는 이름. 아래 zig build 옵션에 같은 이름).
   - **Identity Type**: `Self Signed Root`.
   - **Certificate Type**: `Code Signing`.
   - "Let me override defaults" 체크 안 해도 OK.
4. **Create** → **Continue** → **Done**.
5. 새 인증서가 `login` keychain 의 `My Certificates` 에 보이면 성공.

확인:
```bash
security find-identity -v -p codesigning
# 출력에 "tildaz Local" 같은 cert 가 있어야 함.
```

## 2. 빌드

`-Dmacos-sign-identity` 로 1단계의 cert 이름 전달:

```bash
zig build -Dmacos-sign-identity="tildaz Local"
```

매번 입력하기 귀찮으면 shell alias 또는 환경변수 / `.zigrc` 같은 wrapper.

## 3. 권한 부여 (한 번만)

```bash
open zig-out/TildaZ.app
```

처음 F1 누를 때 macOS 가 권한 요구:
- System Settings → Privacy & Security → Input Monitoring → tildaz ON
- System Settings → Privacy & Security → Accessibility → tildaz ON

이후 코드 변경 + `zig build` + 다시 실행해도 *권한 유지* — signing identity
가 stable 이라 macOS 가 같은 앱으로 인식.

## 4. 확인

빌드 후:
```bash
codesign -dv zig-out/TildaZ.app 2>&1 | grep -i 'authority\|identifier'
# Authority=tildaz Local
# Identifier=me.ensky0.tildaz
```

`Authority` 가 ad-hoc (`adhoc`) 이 아니라 본인 cert 이름이면 OK.

## 참고: CI 빌드

GitHub Actions release workflow (`.github/workflows/release.yml`) 는 self-signed
cert 가 없으니 default `-` (ad-hoc) 사용. 사용자가 release 다운로드 시 첫
실행 quarantine 우회 + 권한 한 번 부여 필요. 그러나 CI 빌드의 ad-hoc
identity 는 빌드 환경 hash 가 일정해 *같은 release zip* 이라면 권한 유지됨.
