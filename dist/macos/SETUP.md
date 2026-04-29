# macOS 로컬 개발 setup

기본은 ad-hoc 서명 (`codesign --sign -`) 으로 동작하고, 매 빌드마다 권한
재설정이 필요한 짜증을 줄이려면 *stable signing identity* 가 필요해요.
사용자 환경이 허락하면 self-signed code-signing 인증서를 만들면 macOS TCC
(Privacy & Security 권한) 가 *signing identity + bundle identifier* 로 앱을
식별해 코드가 바뀌어도 같은 앱으로 인식 → 권한 한 번 부여로 계속 유지.

⚠️ **회사 / 학교 등 관리되는 macOS 환경 (MDM, keychain password 정책)** 에서는
이 셋업이 안 될 수 있어요. keychain access dialog 의 password 가 macOS 로그인
password 와 다른 별도 정책 password 를 요구하는 경우가 있고, 그 password 는
사용자가 모르거나 회사 IT 만 알기도 합니다. 이런 환경에서는 그냥 ad-hoc 빌드
(`zig build` 인자 없이) 로 유지하고 매 빌드마다 권한 다시 부여하세요.

## 옵션 A: ad-hoc (default, 항상 동작)

```bash
zig build
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
zig build -Dmacos-sign-identity=TildazLocal
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

이후 `zig build -Dmacos-sign-identity=TildazLocal` 로 빌드 + 다시 실행해도
**권한 유지** — signing identity stable.

### 검증

```bash
codesign -dv zig-out/TildaZ.app 2>&1 | grep -i 'authority\|identifier'
# Authority=TildazLocal
# Identifier=me.ensky0.tildaz
```

## 옵션 C: CLI 자동화 시도 (`setup-cert.sh`)

`dist/macos/setup-cert.sh` 가 openssl + security 명령으로 위 GUI 절차를
자동화하려는 시도예요. 그러나 macOS 의 keychain ACL / partition-list / system
trust 가 여러 단계의 사용자 password 입력을 요구해 우리 환경에 따라 어느
단계에서 막힐 수 있음.

```bash
bash dist/macos/setup-cert.sh
```

순서:
1. openssl 로 self-signed code-signing cert 생성.
2. login keychain 에 import (`-A` flag — any-app 접근).
3. cert 파일을 `~/.tildaz/TildazLocal.crt` 로 export.
4. system trust 추가 명령을 stdout 으로 출력 — 사용자가 별도 터미널에서
   직접 `sudo` 실행 (script 가 GUI dialog 환경 못 받는 case 회피).

CLI 시도가 막히면 옵션 B 로 fallback.

## CI 빌드 (`.github/workflows/release.yml`)

GitHub Actions runner 에는 self-signed cert 없으므로 default `-` (ad-hoc)
사용. release 다운로드 사용자가 첫 실행 시 quarantine 우회 + 권한 한 번 부여
필요. CI 빌드의 ad-hoc identity 는 빌드 환경 hash 가 같은 release zip 안에서
일정해 release 끼리는 권한 유지 안 되지만 *같은 release 내* 에서는 일정.
