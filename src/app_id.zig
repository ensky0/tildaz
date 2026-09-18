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

/// 사람이 읽는 앱 이름 — 설치 항목처럼 메뉴에 보이는 자리.
pub const display_name = if (build_options.dev) "TildaZ (dev)" else "TildaZ";

/// 개발 빌드인가. 이름이 아니라 *갈래* 자체를 물어야 하는 자리에 쓴다 (예: 기본 hotkey 를
/// 릴리즈와 반대 순서로 고르는 것). 이름 비교 (`eql(name, "tildaz")`) 로 알아내지 않는다 —
/// 이름이 바뀌면 조용히 틀린다.
pub const is_dev = build_options.dev;

/// GNOME · Cinnamon Shell extension 의 UUID. **디렉터리 이름이자 `metadata.json` 의
/// `uuid` 필드**이고 둘은 반드시 같아야 셸이 확장을 읽는다.
///
/// 이것을 가르지 않으면 개발 빌드와 릴리즈가 **같은 확장 하나**를 공유한다. 그러면
/// ① 개발 빌드를 지울 때 릴리즈의 확장까지 지워지고 (`uninstall.sh` 가 UUID 로 지운다),
/// ② 개발 빌드는 그 확장이 자기 창 (`tildaz-dev.instanceN`) 을 안 잡는데도 "확장이
/// 있으니 전역 hotkey 는 확장이 담당한다" 로 판단해 **hotkey 를 아무 데도 등록하지
/// 않는다.** 둘 다 실기에서 확인했다.
pub const extension_uuid = if (build_options.dev) "tildaz-dev@ensky0.github.io" else "tildaz@ensky0.github.io";

/// GNOME 확장의 GSettings 스키마 id. `metadata.json` 의 `settings-schema` · gschema 파일의
/// `id` · 그 파일의 이름이 모두 이 값을 따른다. 같은 id 를 두 확장이 쓰면 설정 경로가
/// 겹쳐 서로의 값을 읽는다.
pub const extension_schema = "org.gnome.shell.extensions." ++ name;

/// 공백을 넣을 수 없는 자리의 이름 — 창 제목 (`TildaZ_N`) 처럼 데스크톱 확장이
/// 문자열로 찾는 값이다. `display_name` 과 갈라 둔 이유가 그 공백 · 괄호다.
pub const window_base = if (build_options.dev) "TildaZ-dev" else "TildaZ";
