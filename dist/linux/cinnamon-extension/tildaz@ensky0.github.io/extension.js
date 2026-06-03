/*
 * TildaZ Drop-down — Cinnamon (muffin) extension (#229 Phase 2)
 *
 * 왜 extension 인가: muffin 도 mutter 처럼 wlr-layer-shell 을 구현하지 않고, Wayland
 * 는 client 가 자기 창의 화면 위치를 지정하는 것을 금지한다. 따라서 drop-down 배치
 * (상단 anchor + always-on-top + hotkey 토글)는 Cinnamon 셸 프로세스 안(=이 extension)
 * 에서 privileged Meta API(muffin)로만 가능하다. GNOME Shell extension(#228)과 동일
 * 구조를 Cinnamon 용 Cjs(`imports.*`) 로 포팅. tildaz 본체는 평범한 Wayland xdg-shell
 * client(app_id="tildaz")로 그대로 두고, 이 extension 이 그 창을 잡아 배치/토글한다.
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
 *   - overview(Expo/Scale)·Alt-Tab 숨김: skip_taskbar getter override (quake-terminal
 *     표준 기법, GNOME 동일).
 *   - dialog(quit confirm/About): tildaz 가 별도 toplevel(app_id="tildaz-dialog",
 *     set_parent(main))로 띄운다(wayland_minimal.zig). client 는 자기 위치를 몰라
 *     화면 중앙에 그리므로(드롭다운 밖), extension 이 잡아 managed 터미널 위 중앙으로
 *     옮긴다(SPEC §6 "main 위 modal" 실현).
 *
 * config = single source of truth: ~/.config/tildaz/config.json 의 hotkey 와
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
const Main = imports.ui.main;

const APP_ID = "tildaz";
const DIALOG_APP_ID = "tildaz-dialog";
const HOTKEY_NAME = "tildaz-toggle";

// 모듈 레벨 상태 (Cinnamon 확장은 전역 init/enable/disable + 모듈 상태 패턴).
let st = null;

function init(_meta) {}

function enable() {
  st = {
    mapId: 0,
    managed: null, // 배치(make_above/stick)한 터미널 창 (disable 시 복원 + dialog 기준)
    taskbarPatched: null, // skip_taskbar override 한 창 (disable 시 복원)
    cfg: readConfig(),
  };

  // hotkey 등록 (config = source of truth). addHotKey(name, accel, cb) — accel 은
  // GTK accelerator(예 "F1" / "<Super>grave"), 여러 개는 "::" 구분. cb 는
  // (display, window, binding) 인자를 받지만 toggle 은 무시.
  if (st.cfg.accel) {
    Main.keybindingManager.addHotKey(HOTKEY_NAME, st.cfg.accel, () => toggle());
  }

  // 새 창 actor 가 map 될 때마다 검사 — tildaz 터미널이면 drop-down 배치, dialog 면
  // 터미널 위 중앙. window-created 는 Wayland 에서 app_id(wm_class) 미설정 시점이라
  // 놓칠 수 있어 map 을 쓴다. 누가 실행하든(autostart/메뉴) 잡도록 계속 살려두고
  // disable 에서만 해제.
  st.mapId = global.window_manager.connect("map", (_wm, actor) => onMap(actor));
}

function disable() {
  try {
    Main.keybindingManager.removeHotKey(HOTKEY_NAME);
  } catch (_e) {}
  if (st && st.mapId) {
    global.window_manager.disconnect(st.mapId);
    st.mapId = 0;
  }
  if (st && st.managed) {
    try {
      st.managed.unmake_above();
      st.managed.unstick();
    } catch (_e) {}
    st.managed = null;
  }
  if (st && st.taskbarPatched) {
    // configurable:true 로 정의했으므로 delete → GObject prototype getter 복귀.
    try {
      delete st.taskbarPatched.skip_taskbar;
    } catch (_e) {}
    st.taskbarPatched = null;
  }
  st = null;
}

/** ~/.config/tildaz/config.json 읽기 (실패 시 안전한 기본값). */
function readConfig() {
  const out = { accel: "", dock: "top", wp: 50, hp: 100, op: 100, hidden: false };
  try {
    const path = GLib.build_filenamev([
      GLib.get_home_dir(),
      ".config",
      "tildaz",
      "config.json",
    ]);
    const [ok, bytes] = GLib.file_get_contents(path);
    if (ok) {
      const j = JSON.parse(new TextDecoder().decode(bytes));
      if (typeof j.hotkey === "string") {
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

/** wm_class === "tildaz" (메인 터미널). Wayland: app_id 가 wm_class 로 매핑됨. */
function isTildaz(win) {
  return wmClassEq(win, APP_ID);
}

/** wm_class === "tildaz-dialog" (quit confirm / About 등 별도 toplevel). */
function isDialog(win) {
  return wmClassEq(win, DIALOG_APP_ID);
}

/** 떠 있는 tildaz 터미널 창 찾기 (없으면 null). global.get_window_actors() 는 muffin·
 *  cinnamon-global.c 에 확실히 있는 API (GNOME 의 display.list_all_windows() 는
 *  muffin 에 없어 toggle 이 예외로 죽었다 — #229 실측). */
function find() {
  const actors = global.get_window_actors();
  for (let i = 0; i < actors.length; i++) {
    const win = metaWindowOf(actors[i]);
    if (isTildaz(win)) return win;
  }
  return null;
}

function onMap(actor) {
  const win = metaWindowOf(actor);
  if (isDialog(win)) {
    placeDialog(win);
    return;
  }
  if (!isTildaz(win)) return;
  // tildaz 가 뜰 때마다 config 재독 (single source of truth — config 바꾸고 tildaz
  // 만 재실행해도 extension reload 없이 반영). hotkey 변경은 enable 의 addHotKey
  // 라 예외(extension reload/relogin 필요).
  st.cfg = readConfig();
  place(win);
  // hidden_start=true → 배치 후 숨김(첫 hotkey 로 등장). tildaz 는 Cinnamon 에서
  // portal GlobalShortcuts 부재로 자기 hidden_start 를 무시하고 항상 창을 만들어
  // (showing on start), 숨김은 여기서 minimize 로 실현한다(KDE 와 동일 결과).
  if (st.cfg.hidden) win.minimize();
}

// hotkey toggle — extension 이 직접 minimize/unminimize. tildaz 의 --toggle(null
// buffer)에 맡기지 않는다(위 헤더 주석). focus 면 숨김, 아니면 보임 + 위치 재확정.
function toggle() {
  try {
    const win = find();
    if (!win) return; // toggle 전용 — 미실행 시 무동작(실행은 autostart/메뉴).
    if (win.has_focus() && !win.minimized) {
      win.minimize();
      return;
    }
    if (win.minimized) win.unminimize();
    // 재배치 — minimize/unminimize 는 geometry 를 보존하지만, drift / 첫 show /
    // 다른 모니터로 커서 이동 대비해 위치를 다시 확정(커서 모니터 기준).
    place(win);
    Main.activateWindow(win);
  } catch (e) {
    global.logError("[tildaz] toggle failed: " + e);
  }
}

/** config 의 dock_position/width/height/offset 으로 *마우스 커서가 있는 모니터*
 *  workArea 기준 배치 (SPEC: drop-down 은 커서 모니터에). */
function place(win) {
  const mi = global.display.get_current_monitor();
  const a = win.get_work_area_for_monitor(mi);
  if (!a) return;
  const c = st.cfg;

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
  win.move_resize_frame(false, x, y, w, h);
  win.make_above();
  win.stick();
  skipTaskbar(win);
  st.managed = win;
}

/** dialog(tildaz-dialog)를 managed 터미널 위 중앙에 배치. 터미널이 없으면 커서
 *  모니터 workArea 중앙으로 fallback. 크기는 dialog 자신의 고정 크기 유지. */
function placeDialog(win) {
  const dr = win.get_frame_rect();
  let cx;
  let cy;
  const term = st.managed;
  if (term) {
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
}

// overview(Expo/Scale)/Alt-Tab window switcher 에서 창을 숨긴다. muffin 이
// skip_taskbar 창을 두 목록에서 제외하므로 getter 를 true 로 override 한다
// (creation 시점 GObject property 라 set 은 못 하고 instance getter 만 덮어씀).
// reference: quake-terminal quake-mode.js. disable() 에서 delete 로 복원.
function skipTaskbar(win) {
  if (st.taskbarPatched === win) return;
  Object.defineProperty(win, "skip_taskbar", {
    get() {
      return true;
    },
    configurable: true,
  });
  st.taskbarPatched = win;
}
