pub const Event = union(enum) {
    text_input: u21,
    key_input: KeyInput,
    shortcut: Shortcut,
    /// 클립보드 paste (#142). UTF-8 bytes. 탭 rename 활성 시
    /// `app_controller` 가 rename buffer 로 라우팅 (true 반환), 아니면 false
    /// 반환해서 host 가 PTY 로 쓴다.
    paste: []const u8,
    /// Ctrl+C. Windows adapter가 terminal preedit discard와 ETX 전송을
    /// 하나의 입력 정책 순서로 처리하기 위해 WM_CHAR 경로와 분리한다.
    interrupt: void,
    scroll: ScrollEvent,
    mouse_down: MouseEvent,
    mouse_double_click: MouseEvent,
    mouse_move: MouseMoveEvent,
    mouse_up: MouseEvent,
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
    // #282 A9 — rename 편집에 안 쓰는 nav 키. rename 활성 시 PTY 로 새지 않게
    // swallow 하려고 dispatch (Windows 만 — macOS/Linux 는 자체 rename 경로).
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
