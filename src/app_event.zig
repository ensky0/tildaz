pub const Event = union(enum) {
    text_input: u21,
    key_input: KeyInput,
    shortcut: Shortcut,
    /// 클립보드 paste (#142). UTF-8 bytes. 탭 rename 활성 시
    /// `app_controller` 가 rename buffer 로 라우팅 (true 반환), 아니면 false
    /// 반환해서 host 가 PTY 로 쓴다.
    paste: []const u8,
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
