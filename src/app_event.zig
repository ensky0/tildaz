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
    mouse_right_down: void,
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
    wheel: i16,
};

pub const PageDirection = enum {
    up,
    down,
};

pub const MouseEvent = struct {
    x: c_int,
    y: c_int,
};

pub const MouseMoveEvent = struct {
    x: c_int,
    y: c_int,
    left_button: bool,
};
