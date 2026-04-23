pub const Event = union(enum) {
    text_input: u21,
    key_input: KeyInput,
    shortcut: Shortcut,
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
    switch_tab: usize,
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
