/*
 * TildaZ Drop-down — Cinnamon (muffin) extension (#229 Phase 2)
 *
 * 왜 extension 인가: muffin 도 mutter 처럼 wlr-layer-shell 을 구현하지 않고, Wayland
 * 는 client 가 자기 창의 화면 위치를 지정하는 것을 금지한다. 따라서 drop-down 배치
 * (상단 anchor + always-on-top + hotkey 토글)는 Cinnamon 셸 프로세스 안(=이 extension)
 * 에서 privileged Meta API(muffin)로만 가능하다. GNOME Shell extension(#228)과 동일
 * 구조를 Cinnamon 용 Cjs(`imports.*`) 로 포팅. TildaZ 본체는 평범한 Wayland xdg-shell
 * client(app_id="tildaz.instanceN")로 두고, 이 extension이 번호별 창을 잡아 배치/토글한다.
 *
 * 전제: Cinnamon on Wayland 세션 전용. tildaz 는 Wayland client 라 X11 Cinnamon
 * 세션에는 아예 못 뜬다. muffin 이 xdg-shell set_app_id 를 wm_class 로 매핑하므로
 * (meta-wayland-xdg-shell.c) win.get_wm_class() 로 감지한다.
 *
 * 동작:
 *   - 실행(autostart/메뉴) → map 시그널에서 tildaz 창을 잡아 config 위치로 배치.
 *     배치 모니터 = 마우스 커서가 있는 모니터(SPEC: Windows show() 와 동일 — 전
 *     platform 정규 스펙). `global.display.get_current_monitor()`.
 *   - hotkey(F1 등) → extension 이 직접 minimize/unminimize 로 토글. gsettings
 *     `tildaz --toggle` 에 맡기지 않는다 — tildaz 의 --toggle 은 wl_surface.attach
 *     (NULL) 로 숨겼다 재-attach 하는데, 그 재표시 때 muffin 이 'map' 재발동 없이
 *     위치를 리셋해 extension 배치가 깨진다(#229 실측). minimize/unminimize 는
 *     surface 를 unmap 하지 않아 muffin 이 frame geometry 를 보존한다(GNOME 동일).
 *     그래서 zig 는 Cinnamon+extension 이면 gsettings hotkey 를 skip 한다.
 *   - hotkey = toggle 전용: tildaz 가 안 떠 있으면 무동작(전 platform/DE 일관).
 *   - hidden_start=true → map 시 배치 후 minimize (로그인 시 숨김, 첫 hotkey 로 등장).
 *   - 목록 숨김(패널 window-list / Alt-Tab / grouped-list / workspace-switcher):
 *     Cinnamon 은 두 경로로 필터한다 — (a) 메서드 `is_skip_taskbar()` (Alt-Tab /
 *     grouped-list), (b) `Main.isInteresting`→C `tracker.is_window_interesting()`
 *     (window-list / workspace-switcher). muffin 에 set_skip_taskbar 세터가 없어 C
 *     상태를 못 바꾸므로, (a) 는 window 인스턴스 메서드 override, (b) 는 WindowTracker
 *     인스턴스 메서드 패치로 둘 다 JS 레벨에서 가린다. (GNOME 의 property getter
 *     override 는 Cinnamon 이 안 읽어 무효 — #229 실측.)
 *   - Expo(워크스페이스 오버뷰) 숨김: Expo 썸네일은 skip_taskbar / is_window_interesting
 *     을 안 보고 `ExpoWorkspaceThumbnail.prototype.isExpoWindow(win)`(expoThumbnail.js)로
 *     클론 생성을 거른다. 원본은 window TYPE(DESKTOP/DOCK)만 검사 → 일반 worker 창 통과.
 *     이 메서드는 `this.isExpoWindow` 로 호출되는 prototype 메서드라 override 가 내부에
 *     닿는다(is_window_interesting 패치와 동형) → enable 에서 패치해 TildaZ worker 클론을
 *     막는다. worker가 stick()(is_on_all_workspaces)이라 전 workspace 썸네일에 뜨던 것 +
 *     비활성 workspace 가 stale snapshot 으로 그려져(linuxmint/Cinnamon #8095) 현재만 안 보이고
 *     2·3·4 엔 보이던 비대칭까지 함께 해소(클론 자체를 안 만들므로 active/stale 무관).
 *   - drop-down 은 `stick()`(전 워크스페이스)이라 보이는 동안 워크스페이스를 바꿔도
 *     따라온다 — yakuake/guake 등 drop-down 표준 동작(숨김=minimize 면 안 보임).
 *   - dialog(quit confirm/About): tildaz 가 별도 toplevel(app_id="tildaz-dialog",
 *     set_parent(main))로 띄운다(wayland_minimal.zig). client 는 자기 위치를 몰라
 *     화면 중앙에 그리므로(드롭다운 밖), extension 이 잡아 managed 터미널 위 중앙으로
 *     옮긴다(SPEC §6 "main 위 modal" 실현).
 *
 * config = single source of truth: $XDG_CONFIG_HOME/tildaz/config_N.toml
 * (fallback: ~/.config/tildaz) 의 hotkey 와
 * window.{dock_position,width_percent,height_percent,offset_percent} + hidden_start.
 *
 * Cinnamon ↔ GNOME API 차이(실측으로 확정):
 *   - 모듈: 레거시 `imports.gi.*`/`imports.ui.main` (ESM `gi://` 아님).
 *   - lifecycle: 전역 `init/enable/disable` (Extension 클래스 아님).
 *   - hotkey: `Main.keybindingManager.addHotKey(name, accel, cb)` / `removeHotKey`.
 *   - 창 목록: `global.get_window_actors()` (GNOME `display.list_all_windows()` 는
 *     muffin 에 없어 예외 — #229 실측).
 *
 * 다음 라운드(polish): flicker 억제(필요 시), 멀티모니터 추가 케이스.
 */

const GLib = imports.gi.GLib;
const Gio = imports.gi.Gio;
const Meta = imports.gi.Meta;
const Cinnamon = imports.gi.Cinnamon;
const Main = imports.ui.main;

const WORKER_APP_ID_PREFIX = "tildaz.instance";
const DIALOG_APP_ID = "tildaz-dialog";

function configDirPath() {
  const xdgConfigHome = GLib.getenv("XDG_CONFIG_HOME");
  const base = xdgConfigHome && GLib.path_is_absolute(xdgConfigHome)
    ? xdgConfigHome
    : GLib.build_filenamev([GLib.get_home_dir(), ".config"]);
  return GLib.build_filenamev([base, "tildaz"]);
}

/**
 * #510 — worker 가 부팅 때 읽는 hotkey grab 결과 파일이 놓이는 디렉터리.
 *
 * **zig 의 `paths.lockDir` 와 규칙이 같아야 한다.** 한쪽만 바뀌면 worker 가 파일을 못
 * 찾고, 그러면 grab 실패가 다시 조용해진다 (증상은 "가끔 안 잡힌다" 로 보인다).
 * 순서: `$XDG_RUNTIME_DIR/tildaz` → `$XDG_CACHE_HOME/tildaz/run` → `~/.cache/tildaz/run`.
 *
 * **config 디렉터리에 두지 않는 이유**는 이 확장 자신이 그 디렉터리를 `FileMonitor` 로
 * 감시하기 때문이다 — 거기 쓰면 감시가 깨어나 config 재독 → 재등록 → 재실패 → 재기록의
 * 자가 루프가 된다.
 */
function hotkeyStateDirPath() {
  const runtime = GLib.getenv("XDG_RUNTIME_DIR");
  if (runtime && GLib.path_is_absolute(runtime))
    return GLib.build_filenamev([runtime, "tildaz"]);
  const cache = GLib.getenv("XDG_CACHE_HOME");
  if (cache && GLib.path_is_absolute(cache))
    return GLib.build_filenamev([cache, "tildaz", "run"]);
  return GLib.build_filenamev([GLib.get_home_dir(), ".cache", "tildaz", "run"]);
}

function hotkeyStatePath(index) {
  return GLib.build_filenamev([hotkeyStateDirPath(), `instance${index}.hotkey`]);
}

/**
 * #510 — grab 결과를 worker 가 읽을 수 있게 남긴다. 형식은 `v1 <ok|failed> <hotkey>`
 * 한 줄이고, hotkey 는 **config 에 적힌 원문 그대로**다 — worker 가 그 값으로 "이 기록이
 * 지금 config 의 것인가" 를 판정해 stale 파일에 속지 않는다.
 */
function writeHotkeyState(index, hotkey, ok) {
  if (typeof hotkey !== "string" || hotkey.length === 0) return;
  try {
    GLib.mkdir_with_parents(hotkeyStateDirPath(), 0o700);
    GLib.file_set_contents(
      hotkeyStatePath(index),
      `v1 ${ok ? "ok" : "failed"} ${hotkey}\n`
    );
  } catch (e) {
    global.logError("[tildaz] could not record hotkey state for index " + index + ": " + e);
  }
}

/** #510 — 확장이 물러나면 기록도 거둔다. 남겨 두면 worker 가 없는 실패를 읽는다. */
function clearHotkeyState(index) {
  try {
    GLib.unlink(hotkeyStatePath(index));
  } catch (e) {
    global.logError("[tildaz] could not clear hotkey state for index " + index + ": " + e);
  }
}

// CinnamonWindowTracker.is_window_interesting 의 원본(프로토타입) 메서드 — enable
// 에서 인스턴스 메서드를 패치할 때 원본 호출용 (disable 에서 delete 로 복원).
const TrackerProto = Cinnamon.WindowTracker.prototype;

// 모듈 레벨 상태 (Cinnamon 확장은 전역 init/enable/disable + 모듈 상태 패턴).
let st = null;

function init(_meta) {}

function enable() {
  st = {
    mapId: 0,
    windowCreatedId: 0,
    dialogClassWatchers: new Map(),
    dialogIdleIds: new Set(),
    managed: new Set(),
    taskbarPatched: new Set(),
    tracker: null, // is_window_interesting 패치한 WindowTracker (disable 시 복원)
    expoProto: null, // isExpoWindow 패치한 ExpoWorkspaceThumbnail.prototype (disable 복원)
    origIsExpoWindow: null, // 그 원본 메서드
    configs: readConfigs(),
    hotkeys: new Map(),
    configMonitor: null,
    configMonitorId: 0,
    configReloadId: 0,
    monitorsChangedId: 0, // #373 해상도 / 모니터 구성 변경 시 재배치
    workAreasChangedId: 0, // #373 work-area 확정 시점의 재계산
  };

  // 패널 window-list / workspace-switcher 는 Main.isInteresting → C
  // `tracker.is_window_interesting()` 로 필터한다(소스: main.js:1569, window-list
  // applet:1438 _shouldAdd, workspace-switcher:413). is_skip_taskbar 메서드 override
  // 는 *C 호출* 인 이 경로엔 안 닿고(muffin 에 set_skip_taskbar 세터도 없음), 게다가
  // window-list 는 _shouldAdd 를 창 생성 시 1회만 평가하므로(map 후 override 는 늦음)
  // tracker 패치가 race 없이 확실하다. tracker 의 JS proxy 메서드를 패치해 TildaZ
  // 터미널을 not-interesting 으로 만든다(Main.isInteresting 이 JS 로 이걸 호출).
  // (Expo 썸네일은 isInteresting 이 아니라 isExpoWindow 로 거르므로 아래에서 별도 패치.)
  st.tracker = Cinnamon.WindowTracker.get_default();
  st.tracker.is_window_interesting = function (w) {
    return isTildaz(w) ? false : TrackerProto.is_window_interesting.call(this, w);
  };

  // Expo(워크스페이스 오버뷰) 숨김. Expo 썸네일은 is_skip_taskbar / is_window_interesting
  // 을 안 보고, ExpoWorkspaceThumbnail.prototype.isExpoWindow(win) 로 클론 생성을 거른다
  // (소스: expoThumbnail.js, this.isExpoWindow 로 호출 → prototype override 가 내부에 닿음
  // — is_window_interesting 패치와 동형). 원본은 window TYPE(DESKTOP/DOCK)만 검사해 일반
  // TildaZ worker가 통과 → 모든 workspace 썸네일에 뜬다(특히 stick() 이라
  // is_on_all_workspaces → main.js isWindowActorDisplayedOnWorkspace 가 전 workspace true).
  // 번호별 worker identity면 false 로 클론 자체를 막는다. (현재 workspace 만 안 보이고
  // 2·3·4 엔 보이던 비대칭은
  // Cinnamon Expo 가 비활성 workspace 를 stale snapshot 으로 그리는 동작(linuxmint/Cinnamon
  // #8095)과 sticky 가 겹친 것 — 클론을 아예 안 만들면 active/stale 무관하게 해소.)
  // ExpoWorkspaceThumbnail 미존재 버전(매우 구형/비표준)이면 guard 로 skip.
  try {
    const ExpoThumb = imports.ui.expoThumbnail;
    const ExpoProto =
      ExpoThumb && ExpoThumb.ExpoWorkspaceThumbnail && ExpoThumb.ExpoWorkspaceThumbnail.prototype;
    if (ExpoProto && typeof ExpoProto.isExpoWindow === "function") {
      const origIsExpoWindow = ExpoProto.isExpoWindow;
      st.expoProto = ExpoProto;
      st.origIsExpoWindow = origIsExpoWindow;
      ExpoProto.isExpoWindow = function (win) {
        const mw = metaWindowOf(win);
        if (mw && isTildaz(mw)) return false;
        return origIsExpoWindow.call(this, win);
      };
    }
  } catch (e) {
    global.logError("[tildaz] isExpoWindow patch failed: " + e);
  }

  // hotkey 등록 (config = source of truth). addHotKey(name, accel, cb) — accel 은
  // GTK accelerator(예 "F1" / "<Super>grave"), 여러 개는 "::" 구분. cb 는
  // (display, window, binding) 인자를 받지만 toggle 은 무시.
  for (const [index, cfg] of st.configs) registerHotkey(index, cfg);

  const configDir = Gio.File.new_for_path(
    configDirPath()
  );
  try {
    st.configMonitor = configDir.monitor_directory(Gio.FileMonitorFlags.NONE, null);
    st.configMonitorId = st.configMonitor.connect("changed", () => {
      if (st.configReloadId) GLib.source_remove(st.configReloadId);
      st.configReloadId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 150, () => {
        st.configReloadId = 0;
        syncHotkeys(readConfigs());
        return GLib.SOURCE_REMOVE;
      });
    });
  } catch (e) {
    global.logError("[tildaz] config monitor failed: " + e);
  }

  // Worker 배치에는 app_id가 확정된 map을 사용한다. Dialog는 hidden parent 때문에
  // map되지 않을 수 있어 window-created + notify::wm-class에서 parent를 먼저 복원한다.
  st.windowCreatedId = global.display.connect("window-created", (_display, win) => {
    watchDialogBeforeMap(win);
  });
  st.mapId = global.window_manager.connect("map", (_wm, actor) => onMap(actor));

  // #373 — 해상도 / 모니터 구성 변경 시 재배치. 이게 없으면 보이는 중에 해상도를
  // 바꿨을 때 옛 work-area 기준 크기로 남는다 (다음 F1 hide→show 의 place() 가
  // 뒤늦게 교정할 뿐이다). 세 platform 의 동작(Windows WM_DISPLAYCHANGE / macOS
  // NSApplicationDidChangeScreenParameters / Linux layer-shell wl_output.mode)과 맞춘다.
  //
  // **두 시그널을 모두 듣는 이유** — `monitors-changed` 는 패널 strut 이 반영되기
  // *전에* 온다 (layout.js 의 `_monitorsChanged` 가 `_updateMonitors` / `_updateBoxes`
  // 만 하고 emit 한다). 그 시점의 `get_work_area_for_monitor` 는 아직 확정값이 아니라
  // 여기서만 배치하면 틀린 rect 를 요청한다. 실측 (2026-08-02, Cinnamon 6.6.9 Wayland):
  // 2560x1440 으로 내릴 때 `monitors-changed` 의 work-area 는 2560x1440 이고 확정값
  // 2560x1400 은 뒤이은 `workareas-changed` 에서 왔다. 그런데도 결과가 맞아 보였던 건
  // muffin 이 사후에 창을 work-area 로 clamp 해줬기 때문이고, 그 보정에 기대면 타이밍에
  // 따라 어긋난다 (사용자가 본 간헐적 오배치). `workareas-changed` 는 확정값과 함께
  // 오므로 여기서 다시 계산해 바로잡는다. 반대로 `monitors-changed` 만 오고 work-area 는
  // 그대로인 경우(모니터 재배열로 *커서 모니터* 만 달라짐 — place() 는 커서 모니터
  // 기준이다)도 있어 둘 다 필요하다. 중복 호출은 place() 의 멱등 가드가 흡수한다.
  st.monitorsChangedId = Main.layoutManager.connect("monitors-changed", () =>
    replaceAllForMonitorChange()
  );
  st.workAreasChangedId = global.display.connect("workareas-changed", () =>
    replaceAllForMonitorChange()
  );
}

// #373 — 관리 중인 창을 모두 다시 배치. minimized(hidden_start / F1 로 숨긴) 창도
// 포함한다: muffin 이 minimize 중에도 frame geometry 를 보존하므로 지금 맞춰 두면
// 다음 show 가 옳은 크기로 뜬다.
function replaceAllForMonitorChange() {
  for (const win of st?.managed || []) {
    try {
      const index = workerIndex(win);
      if (index === null) continue;
      const cfg = st.configs.get(index);
      if (!cfg) continue;
      place(win, cfg);
    } catch (e) {
      global.logError("[tildaz] monitors-changed replace failed: " + e);
    }
  }
}

function disable() {
  if (st?.monitorsChangedId) {
    try {
      Main.layoutManager.disconnect(st.monitorsChangedId);
    } catch (_e) {}
    st.monitorsChangedId = 0;
  }
  if (st?.workAreasChangedId) {
    try {
      global.display.disconnect(st.workAreasChangedId);
    } catch (_e) {}
    st.workAreasChangedId = 0;
  }
  for (const name of st?.hotkeys?.keys() || []) try { Main.keybindingManager.removeHotKey(name); } catch (_e) {}
  // #510 — grab 기록도 함께 거둔다. **`st.hotkeys` 가 아니라 `st.configs` 를 돈다** —
  // 실패한 항목은 `st.hotkeys` 에 애초에 들어가지 않아서 (위 `registerHotkey`) 그쪽만
  // 돌면 지워야 할 실패 기록이 그대로 남는다.
  for (const index of st?.configs?.keys() || []) clearHotkeyState(index);
  if (st?.configMonitorId) st.configMonitor.disconnect(st.configMonitorId);
  if (st?.configMonitor) st.configMonitor.cancel();
  if (st?.configReloadId) GLib.source_remove(st.configReloadId);
  if (st && st.mapId) {
    global.window_manager.disconnect(st.mapId);
    st.mapId = 0;
  }
  if (st && st.windowCreatedId) {
    global.display.disconnect(st.windowCreatedId);
    st.windowCreatedId = 0;
  }
  for (const [win, id] of st?.dialogClassWatchers || []) {
    try {
      win.disconnect(id);
    } catch (_e) {}
  }
  for (const id of st?.dialogIdleIds || []) GLib.source_remove(id);
  st?.dialogClassWatchers.clear();
  st?.dialogIdleIds.clear();
  for (const win of st?.managed || []) {
    try {
      win.unmake_above();
      win.unstick();
    } catch (_e) {}
  }
  for (const win of st?.taskbarPatched || []) {
    // own 으로 할당한 메서드를 delete → prototype 의 GObject 메서드 복귀.
    try {
      delete win.is_skip_taskbar;
    } catch (_e) {}
  }
  if (st && st.tracker) {
    try {
      delete st.tracker.is_window_interesting; // prototype 원본 복귀.
    } catch (_e) {}
    st.tracker = null;
  }
  if (st && st.expoProto && st.origIsExpoWindow) {
    try {
      st.expoProto.isExpoWindow = st.origIsExpoWindow; // prototype 원본 복귀.
    } catch (_e) {}
    st.expoProto = null;
    st.origIsExpoWindow = null;
  }
  st = null;
}

/** XDG config의 config_N.toml 읽기 (실패 시 해당 항목 제외). */
function readConfig(index) {
  // #510 — `hotkey` 는 config 원문이다. worker 가 grab 결과 기록의 stale 여부를 이 값으로
  // 판정하므로 `accel` 로 변환하기 전 문자열이 그대로 필요하다.
  const out = { accel: "", hotkey: null, dock: "top", wp: 50, hp: 100, op: 100, hidden: false };
  try {
    const path = GLib.build_filenamev([
      configDirPath(),
      `config_${index}.toml`,
    ]);
    const [ok, bytes] = GLib.file_get_contents(path);
    if (ok) {
      const j = parseTomlSubset(new TextDecoder().decode(bytes));
      if (typeof j.hotkey === "string") {
        out.hotkey = j.hotkey;
        const a = toAccel(j.hotkey);
        if (a) out.accel = a;
      }
      if (typeof j.hidden_start === "boolean") out.hidden = j.hidden_start;
      const w = j.window || {};
      if (typeof w.dock_position === "string") out.dock = w.dock_position;
      if (typeof w.width_percent === "number") out.wp = w.width_percent;
      if (typeof w.height_percent === "number") out.hp = w.height_percent;
      if (typeof w.offset_percent === "number") out.op = w.offset_percent;
    }
  } catch (e) {
    global.logError("[tildaz] config read failed: " + e);
  }
  return out;
}

function readConfigs() {
  const configs = new Map();
  try {
    const path = configDirPath();
    const dir = GLib.Dir.open(path, 0);
    let name;
    while ((name = dir.read_name()) !== null) {
      const match = /^config_(0|[1-9][0-9]*)\.toml$/.exec(name);
      if (match) configs.set(Number(match[1]), readConfig(Number(match[1])));
    }
    dir.close();
  } catch (e) {
    global.logError("[tildaz] config directory read failed: " + e);
  }
  return new Map([...configs.entries()].sort((a, b) => a[0] - b[0]));
}

function registerHotkey(index, cfg) {
  const name = `tildaz-toggle-${index}`;
  if (!cfg.accel) {
    // #510 — accel 로 옮기지 못한 것도 "hotkey 를 못 잡았다" 다 (알 수 없는 위치 이름 등).
    global.logError(`[tildaz] no usable accelerator — index ${index} hotkey ${JSON.stringify(cfg.hotkey)}`);
    writeHotkeyState(index, cfg.hotkey, false);
    return;
  }
  // 이미 같은 accel 로 잡혀 있으면 손대지 않는다 — 성공 기록도 그때 이미 남았다.
  if (st.hotkeys.get(name) === cfg.accel) return;
  if (st.hotkeys.has(name)) {
    try { Main.keybindingManager.removeHotKey(name); } catch (_e) {}
  }
  // **실패가 조용하면 진단이 안 된다.** #496 1-c 검증에서 GNOME 쪽 같은 자리가
  // 위치 표기를 못 받아 grab 이 실패했는데 로그가 없어 원인이 안 보였다. 실패한
  // 것은 `st.hotkeys` 에 넣지 않는다 — 넣으면 config 가 다시 와도 재시도하지 않는다.
  //
  // #510 — 로그는 Cinnamon 쪽 journal 이라 tildaz 가 못 읽는다. 같은 사실을 worker 가
  // 읽을 수 있는 자리에도 남긴다. 그래야 "부를 수 없는 창" 대신 안내 후 종료가 된다.
  if (Main.keybindingManager.addHotKey(name, cfg.accel, () => toggle(index)) === false) {
    global.logError(`[tildaz] hotkey registration failed — index ${index} accel ${JSON.stringify(cfg.accel)}`);
    writeHotkeyState(index, cfg.hotkey, false);
    return;
  }
  st.hotkeys.set(name, cfg.accel);
  writeHotkeyState(index, cfg.hotkey, true);
}

function syncHotkeys(nextConfigs) {
  for (const [name, accel] of st.hotkeys) {
    const match = /^tildaz-toggle-(0|[1-9][0-9]*)$/.exec(name);
    const next = match ? nextConfigs.get(Number(match[1])) : null;
    if (next?.accel === accel) continue;
    try { Main.keybindingManager.removeHotKey(name); } catch (_e) {}
    st.hotkeys.delete(name);
  }
  st.configs = nextConfigs;
  for (const [index, cfg] of nextConfigs) registerHotkey(index, cfg);
}

/**
 * TOML 의 **아주 좁은 부분집합** 파서 — 최상위 스칼라와 `[window]` 같은 한 단계
 * 테이블, 문자열 · 숫자 · 참거짓만 본다.
 *
 * GJS 에 TOML 파서가 없어서 직접 둔다. 읽을 파일은 `src/config.zig` 가 만든 템플릿
 * 하나뿐이라 (사용자 편집 포함) 문법 범위가 좁다. 배열 (`glyph_fallback` ·
 * `[keys]` 의 값들) · 여러 줄 문자열 · 점 표기 키는 값을 건너뛴다 — 우리가 읽는
 * 키에는 그런 값이 없다.
 *
 * 주석은 **문자열 밖에서만** 자른다. 안 그러면 `hotkey = "ctrl+#"` 같은 값이 잘린다.
 */
function parseTomlSubset(text) {
  const root = {};
  let table = root;
  for (const rawLine of String(text).split("\n")) {
    const line = tomlStripComment(rawLine).trim();
    if (!line) continue;
    const section = /^\[([A-Za-z0-9_]+)\]$/.exec(line);
    if (section) {
      if (typeof root[section[1]] !== "object" || root[section[1]] === null) root[section[1]] = {};
      table = root[section[1]];
      continue;
    }
    const pair = /^([A-Za-z0-9_-]+)\s*=\s*(.*)$/.exec(line);
    if (!pair) continue;
    const value = tomlValue(pair[2].trim());
    if (value !== undefined) table[pair[1]] = value;
  }
  return root;
}

function tomlStripComment(line) {
  let quoted = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (quoted) {
      if (c === "\\") i++;
      else if (c === '"') quoted = false;
    } else if (c === '"') quoted = true;
    else if (c === "#") return line.slice(0, i);
  }
  return line;
}

function tomlValue(text) {
  if (text.startsWith('"')) {
    let out = "";
    for (let i = 1; i < text.length; i++) {
      const c = text[i];
      if (c === "\\") {
        const next = text[++i];
        out += next === "n" ? "\n" : next === "t" ? "\t" : next;
      } else if (c === '"') {
        return out;
      } else {
        out += c;
      }
    }
    return undefined; // 닫히지 않은 문자열
  }
  if (text === "true") return true;
  if (text === "false") return false;
  if (/^[+-]?(\d+(\.\d+)?|\.\d+)([eE][+-]?\d+)?$/.test(text)) return Number(text);
  return undefined; // 배열 등 — 우리가 안 읽는 값
}

/**
 * #496 1-c — 위치 표기(`[Backquote]`)가 가리키는 **xkb keycode** (= evdev + 8).
 *
 * `src/physical_key.zig` 의 표와 같은 값이어야 한다. 어긋나면 조용히 **옆 키**에
 * 붙으므로 (Muffin 은 틀린 숫자를 거부하지 않는다) zig 쪽 test 가 두 표를 묶는다 —
 * `#496 1-c the Shell extension position tables match physical_key`.
 */
const POSITION_KEYCODES = {
  f1: 0x43, f2: 0x44, f3: 0x45, f4: 0x46, f5: 0x47, f6: 0x48,
  f7: 0x49, f8: 0x4a, f9: 0x4b, f10: 0x4c, f11: 0x5f, f12: 0x60,
  f13: 0xbf, f14: 0xc0, f15: 0xc1, f16: 0xc2, f17: 0xc3, f18: 0xc4,
  f19: 0xc5, f20: 0xc6, f21: 0xc7, f22: 0xc8, f23: 0xc9, f24: 0xca,
  keya: 0x26, keyb: 0x38, keyc: 0x36, keyd: 0x28, keye: 0x1a, keyf: 0x29,
  keyg: 0x2a, keyh: 0x2b, keyi: 0x1f, keyj: 0x2c, keyk: 0x2d, keyl: 0x2e,
  keym: 0x3a, keyn: 0x39, keyo: 0x20, keyp: 0x21, keyq: 0x18, keyr: 0x1b,
  keys: 0x27, keyt: 0x1c, keyu: 0x1e, keyv: 0x37, keyw: 0x19, keyx: 0x35,
  keyy: 0x1d, keyz: 0x34, digit1: 0x0a, digit2: 0x0b, digit3: 0x0c, digit4: 0x0d,
  digit5: 0x0e, digit6: 0x0f, digit7: 0x10, digit8: 0x11, digit9: 0x12, digit0: 0x13,
  backquote: 0x31, minus: 0x14, equal: 0x15, bracketleft: 0x22, bracketright: 0x23, backslash: 0x33,
  semicolon: 0x2f, quote: 0x30, comma: 0x3b, period: 0x3c, slash: 0x3d, intlbackslash: 0x5e,
  intlyen: 0x84, intlro: 0x61, space: 0x41, tab: 0x17, escape: 0x09, enter: 0x24,
  backspace: 0x16, capslock: 0x42, printscreen: 0x6b, scrolllock: 0x4e, pause: 0x7f, contextmenu: 0x87,
  lang1: 0x82, lang2: 0x83, convert: 0x64, nonconvert: 0x66, kanamode: 0x65, insert: 0x76,
  delete: 0x77, home: 0x6e, end: 0x73, pageup: 0x70, pagedown: 0x75, arrowup: 0x6f,
  arrowdown: 0x74, arrowleft: 0x71, arrowright: 0x72, numlock: 0x4d, numpad0: 0x5a, numpad1: 0x57,
  numpad2: 0x58, numpad3: 0x59, numpad4: 0x53, numpad5: 0x54, numpad6: 0x55, numpad7: 0x4f,
  numpad8: 0x50, numpad9: 0x51, numpaddivide: 0x6a, numpadmultiply: 0x3f, numpadsubtract: 0x52, numpadadd: 0x56,
  numpadenter: 0x68, numpaddecimal: 0x5b, numpadequal: 0x7d,
};

/** tildaz hotkey 문자열("ctrl+shift+t" / "f1" / "super+grave") → GTK accelerator. */

function toAccel(s) {
  let mods = "";
  let key = "";
  for (const raw of String(s).split("+")) {
    const t = raw.trim().toLowerCase();
    if (t === "ctrl" || t === "control") mods += "<Control>";
    else if (t === "shift") mods += "<Shift>";
    else if (t === "alt" || t === "option") mods += "<Alt>";
    else if (["super", "cmd", "command", "win", "meta", "logo"].includes(t))
      mods += "<Super>";
    else if (t.length > 0) key = t;
  }
  if (!key) return null;
  // #496 1-c — 위치 표기 `[Backquote]` 는 **자리**다. GTK 의 `is_keycode()` 가 `0x` +
  // **정확히 두 자리** hex 만 keycode 로 인정하고, Muffin 은 그 값을 변환 없이
  // `combo->keycode` 에 넣어 xkb keycode (= evdev + 8) 와 견준다. zig 쪽
  // `buildGtkAccel` (gsettings fallback 경로) 이 내는 형식과 같다.
  //
  // 실측 (GNOME 50.4, nested): `<Control>[backquote]` 는 `grab_accelerator` 가 0
  // (`KeyBindingAction.NONE`) 을 내고 `<Control>0x31` 은 받는다 (#496 1-c).
  const position = /^\[(.+)\]$/.exec(key);
  if (position) {
    const code = POSITION_KEYCODES[position[1]];
    if (code === undefined) {
      console.log(`[tildaz] unknown position "${key}" in hotkey "${s}"`);
      return null;
    }
    return mods + "0x" + code.toString(16).padStart(2, "0");
  }
  if (/^f([1-9]|1[0-2])$/.test(key)) key = key.toUpperCase();
  else if (key === "`" || key === "grave") key = "grave";
  else if (key === "space") key = "space";
  else if (key === "esc" || key === "escape") key = "Escape";
  else if (key === "enter" || key === "return") key = "Return";
  else if (key === "tab") key = "Tab";
  // a-z / 0-9 는 그대로.
  return mods + key;
}

/** MetaWindowActor → MetaWindow. muffin 은 get_meta_window() 제공. */
function metaWindowOf(actor) {
  if (typeof actor.get_meta_window === "function") return actor.get_meta_window();
  return actor.meta_window || null;
}

function wmClassEq(win, id) {
  if (!win) return false;
  const c = win.get_wm_class();
  return c === id || (c && c.toLowerCase() === id);
}

/** app_id(wm_class)와 title이 모두 같은 번호인 worker면 index, 아니면 null. */
function workerIndex(win) {
  if (!win) return null;
  const match = /^TildaZ-(0|[1-9][0-9]*)$/.exec(win.get_title?.() || "");
  if (!match) return null;
  const index = Number(match[1]);
  return wmClassEq(win, `${WORKER_APP_ID_PREFIX}${index}`) ? index : null;
}

function isTildaz(win) {
  return workerIndex(win) !== null;
}

/** wm_class === "tildaz-dialog" (quit confirm / About 등 별도 toplevel). */
function isDialog(win) {
  return wmClassEq(win, DIALOG_APP_ID);
}

/** 떠 있는 tildaz 터미널 창 찾기 (없으면 null). global.get_window_actors() 는 muffin·
 *  cinnamon-global.c 에 확실히 있는 API (GNOME 의 display.list_all_windows() 는
 *  muffin 에 없어 toggle 이 예외로 죽었다 — #229 실측). */
function find(index) {
  const actors = global.get_window_actors();
  for (let i = 0; i < actors.length; i++) {
    const win = metaWindowOf(actors[i]);
    if (workerIndex(win) === index) return win;
  }
  return null;
}

// muffin도 minimize된 parent의 transient dialog를 map하지 않을 수 있다. 생성 직후
// 비어 있는 wm_class는 notify에서 받고, idle에서 set_parent 반영 뒤 parent를 복원한다.
function watchDialogBeforeMap(win) {
  let watcherId = 0;
  const stopWatching = () => {
    if (!watcherId) return;
    try {
      win.disconnect(watcherId);
    } catch (_e) {}
    st.dialogClassWatchers.delete(win);
    watcherId = 0;
  };
  const inspect = () => {
    const c = win.get_wm_class?.();
    if (!c) return;
    stopWatching();
    if (c.toLowerCase() !== DIALOG_APP_ID) return;

    let idleId = 0;
    idleId = GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
      st?.dialogIdleIds.delete(idleId);
      const term = win.get_transient_for?.() || null;
      if (term) restoreDialogParent(term);
      return GLib.SOURCE_REMOVE;
    });
    st.dialogIdleIds.add(idleId);
  };

  watcherId = win.connect("notify::wm-class", inspect);
  st.dialogClassWatchers.set(win, watcherId);
  inspect();
}

function onMap(actor) {
  const win = metaWindowOf(actor);
  if (isDialog(win)) {
    placeDialog(win);
    return;
  }
  const index = workerIndex(win);
  if (index === null) return;
  // tildaz 가 뜰 때마다 config 재독 (single source of truth — config 바꾸고 tildaz
  // 만 재실행해도 extension reload 없이 반영). hotkey 변경은 enable 의 addHotKey
  // 라 예외(extension reload/relogin 필요).
  const cfg = readConfig(index);
  st.configs.set(index, cfg);
  registerHotkey(index, cfg);
  place(win, cfg);
  // hidden_start=true → 배치 후 숨김(첫 hotkey 로 등장). tildaz 는 Cinnamon 에서
  // native shortcut 경로에서는 자기 hidden_start 를 무시하고 항상 창을 만들어
  // (showing on start), 숨김은 여기서 minimize 로 실현한다(KDE 와 동일 결과).
  if (cfg.hidden) win.minimize();
}

// hotkey toggle — extension 이 직접 minimize/unminimize. tildaz 의 --toggle(null
// buffer)에 맡기지 않는다(위 헤더 주석). visible 이면 숨김, minimized 면 보임 + 위치 재확정.
function toggle(index) {
  try {
    const win = find(index);
    if (!win) return; // toggle 전용 — 미실행 시 무동작(실행은 autostart/메뉴).
    if (!win.minimized) {
      win.minimize();
      defocusAfterHide(win);
      return;
    }
    if (win.minimized) win.unminimize();
    // 재배치 — minimize/unminimize 는 geometry 를 보존하지만, drift / 첫 show /
    // 다른 모니터로 커서 이동 대비해 위치를 다시 확정(커서 모니터 기준).
    place(win, st.configs.get(index));
    Main.activateWindow(win);
  } catch (e) {
    global.logError("[tildaz] toggle failed: " + e);
  }
}

// 숨김 시 keyboard focus 를 다른 창으로 넘긴다 (#247). muffin 은 sticky+above 인
// tildaz 를 minimize 해도 focus 를 자동 이양하지 않아, 숨김 중에도 client 가
// wl_keyboard focus 를 유지한다 — Alt+Enter 토글이 먹고, 숨긴 직후 타이핑이 안
// 보이는 터미널로 새어든다. MRU tab list 의 다음 일반 창으로 focus 를 넘겨
// "숨김=비focus" 로 만든다 (Win/macOS 의 hidden=unfocused 모델 동등). GNOME 확장과 동형.
function defocusAfterHide(win) {
  try {
    const wm = global.workspace_manager || global.screen;
    const ws = wm.get_active_workspace();
    const now = global.get_current_time();
    const list = global.display.get_tab_list(Meta.TabList.NORMAL, ws);
    for (let i = 0; i < list.length; i++) {
      const w = list[i];
      if (w !== win && !w.minimized) {
        Main.activateWindow(w);
        return;
      }
    }
    // 넘길 창이 없으면(빈 데스크톱) input focus 자체를 해제.
    if (typeof global.display.unset_input_focus === "function") {
      global.display.unset_input_focus(now);
    }
  } catch (e) {
    global.logError("[tildaz] defocus after hide failed: " + e);
  }
}

/** config 의 dock_position/width/height/offset 으로 *마우스 커서가 있는 모니터*
 *  workArea 기준 배치 (SPEC: drop-down 은 커서 모니터에). */
function place(win, c) {
  const mi = global.display.get_current_monitor();
  const a = win.get_work_area_for_monitor(mi);
  if (!a) return;

  let w = Math.round((a.width * Math.min(c.wp, 100)) / 100);
  let h = Math.round((a.height * Math.min(c.hp, 100)) / 100);
  if (w < 1) w = a.width;
  if (h < 1) h = a.height;

  const offX = Math.round(((a.width - w) * c.op) / 100);
  const offY = Math.round(((a.height - h) * c.op) / 100);
  let x = a.x;
  let y = a.y;
  switch (c.dock) {
    case "bottom":
      x = a.x + offX;
      y = a.y + a.height - h;
      break;
    case "left":
      x = a.x;
      y = a.y + offY;
      break;
    case "right":
      x = a.x + a.width - w;
      y = a.y + offY;
      break;
    case "top":
    default:
      x = a.x + offX;
      y = a.y;
      break;
  }

  win.move_to_monitor(mi);
  // #373 — 목표 rect 가 지금과 같으면 창을 건드리지 않는다. monitors-changed 와
  // toggle 이 같은 place() 를 쓰므로, *크기가 실제로 달라질 때만* move_resize_frame 이
  // 나가게 해서 불필요한 재배치를 없앤다. (Windows 는 WM_DISPLAYCHANGE 의 lParam
  // 해상도를 캐시해 spurious broadcast 를 거르고 — window.zig 의 last_display_w/h —
  // Linux layer-shell 은 wl_output.mode 를 이전 값과 비교한다. 같은 규칙이다.)
  const cur = win.get_frame_rect();
  if (!cur || cur.x !== x || cur.y !== y || cur.width !== w || cur.height !== h)
    win.move_resize_frame(false, x, y, w, h);
  win.make_above();
  win.stick();
  skipTaskbar(win);
  st.managed.add(win);
}

/** dialog(tildaz-dialog)를 managed 터미널 위 중앙에 배치. 터미널이 없으면 커서
 *  모니터 workArea 중앙으로 fallback. 크기는 dialog 자신의 고정 크기 유지. */
function placeDialog(win) {
  const dr = win.get_frame_rect();
  let cx;
  let cy;
  const term = win.get_transient_for?.() || st.managed.values().next().value;
  if (term) {
    restoreDialogParent(term);
    const tr = term.get_frame_rect();
    cx = tr.x + Math.round((tr.width - dr.width) / 2);
    cy = tr.y + Math.round((tr.height - dr.height) / 2);
  } else {
    const mi = global.display.get_current_monitor();
    const a = win.get_work_area_for_monitor(mi);
    if (!a) return;
    cx = a.x + Math.round((a.width - dr.width) / 2);
    cy = a.y + Math.round((a.height - dr.height) / 2);
  }
  win.move_frame(true, cx, cy);
  win.make_above();
  win.stick();
  Main.activateWindow(win);
}

function restoreDialogParent(term) {
  if (term.minimized) term.unminimize();
  Main.activateWindow(term);
}

// Alt-Tab(appSwitcher) / grouped-window-list 에서 창을 숨긴다. 이들은 매번 새로
// 질의하는 **메서드 `is_skip_taskbar()`** 로 필터하므로(소스: appSwitcher.js:35/39/43,
// grouped-window-list:1018) 인스턴스 메서드를 override 한다 (GNOME 식 property getter
// override 는 Cinnamon 이 안 읽어 무효 — #229 실측). disable 에서 delete 로 복원.
// (패널 window-list·workspace-switcher 는 is_window_interesting 경로 — enable 의
// tracker 패치가 담당. Expo 는 둘 다 안 닿는 Cinnamon 한계 — 헤더 참고.)
function skipTaskbar(win) {
  if (st.taskbarPatched.has(win)) return;
  win.is_skip_taskbar = () => true;
  st.taskbarPatched.add(win);
}
