/*
 * TildaZ Drop-down — GNOME Shell extension (#228)
 *
 * 왜 extension 인가: mutter 는 wlr-layer-shell 을 구현하지 않고, Wayland 는 client
 * 가 자기 창의 화면 위치를 지정하는 것을 금지한다(보안 + compositor 권한). 따라서
 * drop-down 의 핵심(상단 anchor + always-on-top + hotkey 토글)은 GNOME Shell
 * 프로세스 안(=이 extension)에서 privileged Meta API 로만 가능하다. tildaz 본체는
 * 평범한 Wayland xdg-shell client(app_id="tildaz")로 그대로 두고, 이 extension 이
 * 그 창을 잡아 배치/토글한다. reference: ddterm / quake-terminal 패턴.
 *
 * config = single source of truth: ~/.config/tildaz/config.json 의 hotkey 와
 * window.{dock_position,width_percent,height_percent,offset_percent} 를 읽는다.
 *
 * 동작: app_id 감지 + config 기반 placement(move_resize_frame) + make_above +
 * stick + skip_taskbar(overview/Alt-Tab 에서 숨김) + hotkey 토글(focus 면 minimize
 * / 아니면 show). hotkey 는 toggle 전용 — tildaz 가 안 떠 있으면 무동작(KDE/sway/
 * Win/mac 과 동일한 일관모델). 실행은 autostart(enable 시 launch)/메뉴가 담당.
 * slide 애니메이션 / 멀티모니터 선택은 향후.
 */

import Meta from "gi://Meta";
import Shell from "gi://Shell";
import GLib from "gi://GLib";
import { Extension } from "resource:///org/gnome/shell/extensions/extension.js";
import * as Main from "resource:///org/gnome/shell/ui/main.js";

const APP_ID = "tildaz";
const DESKTOP_ID = "tildaz.desktop";
const KEY = "toggle-hotkey";

export default class TildazExtension extends Extension {
  enable() {
    this._settings = this.getSettings();
    this._appSystem = Shell.AppSystem.get_default();
    this._cfg = this._readConfig();
    this._mapWaitId = 0;
    this._managed = null; // make_above 해 둔 창 (disable 시 복원)
    this._placed = null; // placement 를 이미 적용한 창 (1회만)
    this._taskbarPatched = null; // skip_taskbar override 한 창 (disable 시 복원)
    this._startupHookId = 0; // hidden preload 의 startup-complete overview 닫기 hook

    // config.json 의 hotkey 를 gschema 키에 반영한 뒤 등록 (config = source of truth).
    if (this._cfg.accel) this._settings.set_strv(KEY, [this._cfg.accel]);

    Main.wm.addKeybinding(
      KEY,
      this._settings,
      Meta.KeyBindingFlags.IGNORE_AUTOREPEAT,
      Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW | Shell.ActionMode.POPUP,
      () => this._toggle()
    );

    // 배치(우측 드롭다운) 핸들러는 auto_start 와 무관하게 *항상* 건다 — 그래야 앱
    // 그리드/터미널로 수동 실행해도(auto_start=false) extension 이 그 창을 잡아
    // 드롭다운으로 만든다. (전엔 _launch 안에서만 걸려 수동 실행이 일반 창으로 떴다.)
    this._armMapHandler();

    // auto_start 면 로그인(enable) 시 미리 launch. 표시/숨김은 map 핸들러가
    // config(hidden_start) 로 결정한다 (false → 우측에 바로 표시, true → 배치 후
    // 숨김, hotkey 로 등장). auto_start=false 면 로그인 시 안 뜨고(앱 그리드/터미널로
    // 수동 실행), F1 은 실행 중일 때만 toggle(미실행 시 무동작). zig 는 GNOME 에서
    // autostart .desktop 을 삭제하므로 launch lifecycle 은 여기(extension)가 담당한다.
    if (this._cfg.autoStart) this._launch();
  }

  disable() {
    Main.wm.removeKeybinding(KEY);
    if (this._mapWaitId) {
      global.window_manager.disconnect(this._mapWaitId);
      this._mapWaitId = 0;
    }
    if (this._managed) {
      try {
        this._managed.unmake_above();
        this._managed.unstick();
      } catch (_e) {}
      this._managed = null;
    }
    if (this._taskbarPatched) {
      // configurable:true 로 정의했으므로 delete → GObject prototype getter 복귀.
      try {
        delete this._taskbarPatched.skip_taskbar;
      } catch (_e) {}
      this._taskbarPatched = null;
    }
    if (this._startupHookId) {
      try {
        Main.layoutManager.disconnect(this._startupHookId);
      } catch (_e) {}
      this._startupHookId = 0;
    }
    this._settings = null;
    this._appSystem = null;
    this._cfg = null;
    this._placed = null;
  }

  /** ~/.config/tildaz/config.json 읽기 (실패 시 안전한 기본값). */
  _readConfig() {
    const out = {
      accel: "<Super>grave",
      dock: "top",
      wp: 50,
      hp: 100,
      op: 100,
      autoStart: true,
      hiddenStart: false,
    };
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
          const a = this._toAccel(j.hotkey);
          if (a) out.accel = a;
        }
        const w = j.window || {};
        if (typeof w.dock_position === "string") out.dock = w.dock_position;
        if (typeof w.width_percent === "number") out.wp = w.width_percent;
        if (typeof w.height_percent === "number") out.hp = w.height_percent;
        if (typeof w.offset_percent === "number") out.op = w.offset_percent;
        if (typeof j.auto_start === "boolean") out.autoStart = j.auto_start;
        if (typeof j.hidden_start === "boolean") out.hiddenStart = j.hidden_start;
      }
    } catch (e) {
      console.log(`[tildaz] config read failed: ${e}`);
    }
    return out;
  }

  /** tildaz hotkey 문자열("ctrl+shift+t" / "f1" / "super+grave") → GTK accelerator. */
  _toAccel(s) {
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
    // a-z / 0-9 는 그대로 (GTK accelerator 는 소문자 letter 수용).
    return mods + key;
  }

  /** app_id == "tildaz" 인 창 찾기 (Wayland: get_wm_class 가 app_id 를 반환). */
  _find() {
    const wins = global.display.list_all_windows();
    for (const w of wins) {
      const c = w.get_wm_class();
      const ci = w.get_wm_class_instance ? w.get_wm_class_instance() : null;
      if (c === APP_ID || ci === APP_ID) return w;
      if (c && c.toLowerCase() === APP_ID) return w;
    }
    return null;
  }

  _toggle() {
    const win = this._find();

    if (!win) {
      // 일관모델: hotkey = toggle 전용. tildaz 가 안 떠 있으면 무동작
      // (KDE/sway/Win/mac 모두 동일 — hotkey 는 실행 중인 창을 show/hide 만).
      // 실행은 autostart(enable 시 launch) 또는 메뉴/터미널이 담당한다.
      return;
    }

    // 떠 있고 focus → 숨김. minimize 의 mutter 기본 애니메이션은 skip
    // (drop-down 은 즉시 사라지는 게 자연스러움; slide 는 Phase 2).
    if (win.has_focus() && !win.minimized) {
      this._skipEffect(win);
      win.minimize();
      return;
    }

    // 보이기 — flicker 방지: show 마다 move_resize_frame 을 호출하면 tildaz(xdg
    // client) 가 configure→buffer 재그리기 race 로 '왼쪽 전체→우측' 희번덕이 난다.
    // placement 는 launch 시 1회만 하고(아래 _ensurePlacedOnce), 이후 show 는
    // minimize 가 유지한 geometry 그대로 unminimize + activate 만 한다.
    // hidden preload(_launch hidden=true)는 opacity 0 으로 숨겨둔 상태라 여기서
    // 처음 보일 때 255 로 복원한다 — 복원 누락 시 unminimize 해도 안 보인다.
    this._skipEffect(win);
    const actor = win.get_compositor_private();
    if (actor) actor.opacity = 255;
    if (win.minimized) win.unminimize();
    this._ensurePlacedOnce(win);
    Main.activateWindow(win);
  }

  _skipEffect(win) {
    const actor = win.get_compositor_private();
    if (actor) Main.wm.skipNextEffect(actor);
  }

  // hidden preload 시 로그인 startup overview 를 닫는다. 지금 한 번 닫고, 아직
  // startup 중이면 startup 애니메이션이 overview 를 다시 SHOWN 으로 만들 수 있어
  // startup-complete 직후 한 번 더 닫는다(이미 끝났으면 신호가 안 와 no-op).
  _dismissOverview() {
    try {
      Main.overview.hide();
    } catch (_e) {}
    if (this._startupHookId) return;
    const lm = Main.layoutManager;
    this._startupHookId = lm.connect("startup-complete", () => {
      lm.disconnect(this._startupHookId);
      this._startupHookId = 0;
      try {
        Main.overview.hide();
      } catch (_e) {}
    });
  }

  // tildaz 의 map 시그널을 잡아 우측 드롭다운으로 배치하는 핸들러를 건다. enable()
  // 에서 auto_start 와 무관하게 항상 호출 — 앱 그리드/터미널로 *수동* 실행해도
  // extension 이 그 창을 잡아 드롭다운으로 만든다. 표시/숨김은 실행 경로와 무관하게
  // config(hidden_start) 단일 기준(핸들러 안에서 읽음).
  // window-created 는 Wayland 에서 app_id(wm_class) 미설정 시점이라 tildaz 를 놓친다
  // (실측). map 은 app_id 확정 후라 wm_class 로 안정 식별 가능 — 여기서 잡는다.
  // 핸들러는 close→relaunch 도 잡도록 계속 살려두고, disable() 에서만 해제한다.
  _armMapHandler() {
    const wm = global.window_manager;
    if (this._mapWaitId) wm.disconnect(this._mapWaitId);
    this._mapWaitId = wm.connect("map", (_wm, actor) => {
      const win = actor.meta_window;
      const c = win.get_wm_class();
      if (!(c === APP_ID || (c && c.toLowerCase() === APP_ID))) return;

      // tildaz 가 뜰 때마다 config 를 다시 읽는다 (config = single source of truth).
      // 사용자가 config.json 의 hidden_start / 위치(dock/width/...) 를 바꾸고 tildaz 만
      // 재실행해도 extension reload 없이 반영된다. (hotkey 는 enable 의 gschema 바인딩
      // 이라 예외 — 바꾸면 extension reload/relogin 이 필요하다.)
      this._cfg = this._readConfig();

      // 숨김 여부는 config(hidden_start)가 단일 기준 — 실행 경로(auto_start preload /
      // 앱 그리드 / 터미널)와 무관하게 일관. hidden_start=true 면 배치 후 minimize
      // (첫 hotkey 로 등장), false 면 우측 드롭다운으로 바로 표시.
      const hidden = this._cfg.hiddenStart;

      // map 직후엔 mutter 의 map 애니메이션(opacity 0→255 ease)이 진행 중이다.
      // kill-window-effects 로 그 애니메이션을 *먼저* 끝낸 뒤(끝나면 opacity 가
      // 255/중간값으로 남는다) opacity 0 을 박아야 placement(기본 위치→우측) 이동이
      // 안 보인다. 순서를 반대로(0 먼저 → kill) 하면 kill 이 0 을 덮어써 왼쪽→우측
      // 이동이 그대로 보인다(실측 버그).
      wm.emit("kill-window-effects", actor);
      actor.opacity = 0;
      this._ensurePlacedOnce(win);

      if (hidden) {
        // preload: 절대 보이지 않게. opacity 0(invisible) 인 채로 배치까지 끝낸 뒤
        // minimize 만 한다. opacity 255 복원은 첫 hotkey show(_toggle)에서 한다.
        // (여기서 255 로 올렸다가 minimize 하면 우측에 한 프레임 번쩍인다 — 기존 버그.)
        this._skipEffect(win);
        win.minimize();
        // GNOME 은 로그인 시 overview 에서 startup 한다(layout.js
        // _startupAnimationSession → overview.runStartupAnimation). 보통 첫 창이
        // map 되며 activate 경로로 overview 가 닫히는데, hidden preload 는 minimize
        // 라 그 트리거가 없어 overview 에 남는다(실측). 명시적으로 닫는다.
        this._dismissOverview();
        return;
      }

      // 표시(수동 실행, 또는 auto_start + hidden_start=false): placement 가 정착
      // (repaint)해 보일 준비가 되면 opacity 복원 + activate. stage-views-changed 가
      // 먼저 오면 그때, 안 오면 200ms 안전망.
      let shown = false;
      const reveal = () => {
        if (shown) return;
        shown = true;
        actor.opacity = 255;
        Main.activateWindow(win);
      };
      const svId = actor.connect("stage-views-changed", () => {
        actor.disconnect(svId);
        reveal();
      });
      GLib.timeout_add(GLib.PRIORITY_DEFAULT, 200, () => {
        try {
          actor.disconnect(svId);
        } catch (_e) {}
        reveal();
        return GLib.SOURCE_REMOVE;
      });
    });
  }

  // tildaz 를 실행. 이미 떠 있으면 no-op. 배치/숨김은 map 핸들러(_armMapHandler,
  // enable 에서 이미 걸림)가 config(hidden_start) 기준으로 처리한다. auto_start
  // preload 전용 경로다(수동 실행은 .desktop activate 가 직접 같은 핸들러를 탄다).
  _launch() {
    if (this._find()) return;
    const app = this._appSystem.lookup_app(DESKTOP_ID);
    if (!app) {
      Main.notify("TildaZ", `${DESKTOP_ID} not found — run dist/linux/install.sh`);
      return;
    }
    app.activate();
  }

  // 한 창에 대해 placement(move_resize_frame) 를 한 번만 수행. show 마다 재배치하면
  // tildaz xdg buffer 재그리기 race 로 flicker 가 나므로, 최초 1회만 우측에 맞춘다.
  _ensurePlacedOnce(win) {
    if (this._placed === win) return;
    this._place(win);
    this._placed = win;
  }

  /** config 의 dock_position/width/height/offset 으로 primary monitor workArea 기준 배치. */
  _place(win) {
    const mi = Main.layoutManager.primaryIndex;
    const a = win.get_work_area_for_monitor(mi);
    if (!a) return;
    const c = this._cfg;

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
    this._skipTaskbar(win);
    this._managed = win;
  }

  // overview(Activities)/Alt-Tab window switcher 에서 창을 숨긴다. mutter 가
  // skip_taskbar 창을 두 목록에서 제외하므로, getter 를 true 로 override 한다
  // (creation 시점에 GObject property 라 set 은 못 하고 instance getter 만 덮어씀).
  // reference: quake-terminal quake-mode.js _configureSkipTaskbarProperty.
  // hidden_start=true 의 로그인 백그라운드 대기(minimize)에서 단독 창이라도
  // overview thumbnail 로 안 보이게 하는 게 목적 — KDE 의 숨김과 동일한 결과.
  _skipTaskbar(win) {
    if (this._taskbarPatched === win) return;
    Object.defineProperty(win, "skip_taskbar", {
      get() {
        return true;
      },
      configurable: true,
    });
    this._taskbarPatched = win;
  }
}
