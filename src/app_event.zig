const pane_layout = @import("pane_layout.zig");

pub const Event = union(enum) {
    text_input: u21,
    key_input: KeyInput,
    shortcut: Shortcut,
    /// 클립보드 paste (#142). UTF-8 bytes. `app_controller` 가 입력 정책
    /// (preedit commit) 적용 후 PTY 로 라우팅한다.
    paste: []const u8,
    /// Ctrl+C. Windows adapter가 terminal preedit discard와 ETX 전송을
    /// 하나의 입력 정책 순서로 처리하기 위해 WM_CHAR 경로와 분리한다.
    interrupt: void,
    scroll: ScrollEvent,
    mouse_down: MouseEvent,
    mouse_double_click: MouseEvent,
    mouse_move: MouseMoveEvent,
    mouse_up: MouseEvent,
    /// 우클릭 pressed edge (#329). true 반환 = 소비 (열린 command menu 닫기).
    /// false 면 window 가 기존 즉시 paste 를 수행한다 — menu 가 pointer button
    /// 보다 우선하는 SPEC §5.3 라우팅용.
    /// #483 5단계 — 좌표를 싣는다: 비활성 pane 우클릭은 포커스만 (붙여넣기 X).
    mouse_right_down: MouseEvent,
    /// 창이 focus 를 잃었다 (#390 — Windows `WM_ACTIVATEAPP` wParam=0). 창 *밖*
    /// 클릭은 OS 가 다른 창으로 라우팅해 pointer event 가 우리에게 오지 않으므로,
    /// 열린 command menu 를 닫는 훅은 focus 상실뿐이다. menu 상태가 `App` 에 있어
    /// `Window` 가 직접 닫을 수 없어 event 로 넘긴다. true 반환 = menu 를 닫았음.
    focus_lost: void,
    tab_closed: usize,
};

pub const Shortcut = union(enum) {
    new_tab: void,
    close_active_tab: void,
    reset_terminal: void,
    dump_perf: void,
    show_about: void,
    open_config: void,
    open_log: void,
    switch_tab: usize,
    next_tab: void,
    prev_tab: void,
    copy_selection: void,
    toggle_visibility: void,
    /// false = monitor fullscreen, true = work-area fullscreen.
    fullscreen: bool,
    /// #483 — 화면 분할. 방향은 액션 이름에서 왔다 (`config.ActionInput.direction`).
    split: pane_layout.Direction,
    focus_pane: pane_layout.Direction,
    resize_pane: pane_layout.Direction,
    equalize_panes: void,
    zoom_pane: void,
    /// #544 — 활성 pane 하나 닫기. `close_active_tab` 은 탭 통째로다.
    close_pane: void,
};

pub const KeyInput = enum {
    enter,
    escape,
    backspace,
    left,
    right,
    home,
    end,
    delete,
    // command menu 가 열린 동안 swallow 하려고 dispatch (Windows 만 —
    // macOS/Linux 는 자체 menu key 경로).
    up,
    down,
    page_up,
    page_down,
    insert,
};

pub const ScrollEvent = union(enum) {
    page: PageDirection,
    wheel: WheelEvent,
};

/// 휠 notch. `delta` 는 Windows `WHEEL_DELTA` 관례 (양수 = 위로) 이고 세 host 가
/// 자기 단위를 이 값으로 변환해 올린다.
///
/// #502 — reporting 은 휠도 좌표와 modifier 를 실어 보내야 해서 (`Cb` 64/65) 델타
/// 하나로는 부족하다. 좌표는 client 픽셀.
pub const WheelEvent = struct {
    delta: i16,
    x: c_int = 0,
    y: c_int = 0,
    mods: MouseMods = .{},
};

pub const PageDirection = enum {
    up,
    down,
};

/// 마우스 버튼. mouse reporting (#502) 이 `Cb` 에 실을 버튼과 chrome 라우팅이
/// 함께 쓴다. 기존 chrome (탭바 / 스크롤바 / selection) 은 왼쪽만 다뤘다.
pub const MouseButton = enum { left, middle, right };

/// 마우스 이벤트 시점의 keyboard modifier. mouse reporting 의 `Cb` modifier 비트
/// (shift +4 / alt +8 / ctrl +16) 와 Shift bypass 판정에 쓴다 (#502).
pub const MouseMods = struct {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

pub const MouseEvent = struct {
    x: c_int,
    y: c_int,
    /// 기본값 = 왼쪽. 기존 호출부가 왼쪽만 올렸으므로 default 로 둔다.
    button: MouseButton = .left,
    mods: MouseMods = .{},
};

pub const MouseMoveEvent = struct {
    x: c_int,
    y: c_int,
    left_button: bool,
    /// #502 — reporting 은 어떤 버튼을 누른 채 끌고 있는지 알아야 한다.
    middle_button: bool = false,
    right_button: bool = false,
    mods: MouseMods = .{},

    /// 아무 버튼이라도 눌려 있는지. viewport 밖 motion 을 보고할지 판정한다.
    pub fn anyButton(self: MouseMoveEvent) bool {
        return self.left_button or self.middle_button or self.right_button;
    }

    /// motion 에 실을 버튼 하나. 여러 개가 눌려 있으면 왼 > 가운데 > 오른쪽 —
    /// 프로토콜이 버튼 하나만 담을 수 있어서 우선순위를 고정한다.
    pub fn heldButton(self: MouseMoveEvent) ?MouseButton {
        if (self.left_button) return .left;
        if (self.middle_button) return .middle;
        if (self.right_button) return .right;
        return null;
    }
};
