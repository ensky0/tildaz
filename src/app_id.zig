//! 개발 빌드와 릴리즈를 가르는 이름 — **한 곳에서만 정한다** ([#654](https://github.com/ensky0/tildaz/issues/654)).
//!
//! 둘이 같은 `config_N.toml` · 로그 · lock · 소켓을 쓰면 버전이 다른 판끼리 부딪힌다.
//! 실제로 패키지 0.9.5 를 깔아 둔 기기에서 개발 빌드 v0.9.3 이 떠 v0.9.0 스키마 config 로
//! 아무 안내 없이 죽었다.
//!
//! **자리마다 따로 분기하지 않는 이유**는 누락을 구조적으로 막기 위해서다 — 격리해야 할
//! 자리가 아홉 군데라 (config · 로그 · lock · 소켓 · 런타임 desktop · autostart 셋 · stress)
//! 하나씩 조건을 쓰면 반드시 하나를 빠뜨린다. 여기 두 값만 보면 된다.
//!
//! **가능하면 디렉터리 이름으로 가른다.** `.desktop` · LaunchAgent · 소켓처럼 공용 디렉터리에
//! 놓여 디렉터리를 만들 자리가 없는 것만 이름에 섞는다.

const build_options = @import("build_options");

/// config · 로그 · lock 디렉터리 이름이고, 공용 디렉터리에 놓이는 파일 이름의 밑동이다
/// (`<name>.desktop` · `<name>-stress-*` 등).
pub const name = if (build_options.dev) "tildaz-dev" else "tildaz";

/// macOS bundle identifier — LaunchAgent label 도 이 값을 쓴다.
///
/// **경로만 가르면 소용이 없다.** LaunchServices 는 같은 bundle id 를 가진 번들을 한 앱으로
/// 묶어서, `/Applications/TildaZ-dev.app` 을 따로 두어도 메뉴 · `open` 이 어느 쪽을 열지
/// 모호해진다 — Linux 의 desktop ID shadowing 과 같은 모양이다. 대가는 TCC 권한
/// (Input Monitoring · Accessibility) 1 회 재부여다. TCC 는 경로가 아니라 bundle id + 서명으로
/// 앱을 식별하므로, 반대로 경로만 바꾸면 권한은 유지되지만 분리도 되지 않는다.
pub const bundle_id = if (build_options.dev) "me.ensky0.tildaz.dev" else "me.ensky0.tildaz";

/// 사람이 읽는 앱 이름 — 설치 항목 · 창 제목처럼 사용자에게 보이는 자리.
pub const display_name = if (build_options.dev) "TildaZ (dev)" else "TildaZ";
