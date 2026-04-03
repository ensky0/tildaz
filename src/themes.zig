const ghostty = @import("ghostty-vt");
const RGB = ghostty.color.RGB;
const Palette = ghostty.color.Palette;

pub const Theme = struct {
    name: []const u8,
    palette: [16]RGB,
    foreground: RGB,
    background: RGB,
};

fn rgb(comptime hex: u24) RGB {
    return .{
        .r = @truncate(hex >> 16),
        .g = @truncate(hex >> 8),
        .b = @truncate(hex),
    };
}

/// Build a full 256-color palette from the base 16 ANSI colors,
/// using the standard xterm algorithm for indices 16-255.
pub fn buildPalette(base16: [16]RGB) Palette {
    var pal: Palette = undefined;
    // 0-15: user-defined ANSI colors
    for (0..16) |i| pal[i] = base16[i];
    // 16-231: 6x6x6 color cube
    for (0..216) |i| {
        const r: u8 = @intCast(i / 36);
        const g: u8 = @intCast((i % 36) / 6);
        const b: u8 = @intCast(i % 6);
        pal[i + 16] = .{
            .r = if (r == 0) 0 else @as(u8, @intCast(r * 40 + 55)),
            .g = if (g == 0) 0 else @as(u8, @intCast(g * 40 + 55)),
            .b = if (b == 0) 0 else @as(u8, @intCast(b * 40 + 55)),
        };
    }
    // 232-255: grayscale ramp
    for (0..24) |i| {
        const v: u8 = @intCast(i * 10 + 8);
        pal[i + 232] = .{ .r = v, .g = v, .b = v };
    }
    return pal;
}

pub const themes = [_]Theme{
    // ── Classic ─────────────────────────────────────────────
    .{
        .name = "Tilda",
        .foreground = rgb(0xffffff),
        .background = rgb(0x000000),
        .palette = .{
            // VTE Tango palette (Linux Tilda default)
            rgb(0x2e3436), rgb(0xcc0000), rgb(0x4e9a06), rgb(0xc4a000),
            rgb(0x3465a4), rgb(0x75507b), rgb(0x06989a), rgb(0xd3d7cf),
            rgb(0x555753), rgb(0xef2929), rgb(0x8ae234), rgb(0xfce94f),
            rgb(0x729fcf), rgb(0xad7fa8), rgb(0x34e2e2), rgb(0xeeeeec),
        },
    },
    .{
        .name = "Ghostty",
        .foreground = rgb(0xc5c8c6),
        .background = rgb(0x1d1f21),
        .palette = .{
            rgb(0x1d1f21), rgb(0xcc6666), rgb(0xb5bd68), rgb(0xf0c674),
            rgb(0x81a2be), rgb(0xb294bb), rgb(0x8abeb7), rgb(0xc5c8c6),
            rgb(0x666666), rgb(0xd54e53), rgb(0xb9ca4a), rgb(0xe7c547),
            rgb(0x7aa6da), rgb(0xc397d8), rgb(0x70c0b1), rgb(0xeaeaea),
        },
    },
    .{
        .name = "Windows Terminal",
        .foreground = rgb(0xcccccc),
        .background = rgb(0x0c0c0c),
        .palette = .{
            rgb(0x0c0c0c), rgb(0xc50f1f), rgb(0x13a10e), rgb(0xc19c00),
            rgb(0x0037da), rgb(0x881798), rgb(0x3a96dd), rgb(0xcccccc),
            rgb(0x767676), rgb(0xe74856), rgb(0x16c60c), rgb(0xf9f1a5),
            rgb(0x3b78ff), rgb(0xb4009e), rgb(0x61d6d6), rgb(0xf2f2f2),
        },
    },
    // ── Dark themes (인기순) ─────────────────────────────────
    .{
        .name = "Catppuccin Mocha",
        .foreground = rgb(0xcdd6f4),
        .background = rgb(0x1e1e2e),
        .palette = .{
            rgb(0x45475a), rgb(0xf38ba8), rgb(0xa6e3a1), rgb(0xf9e2af),
            rgb(0x89b4fa), rgb(0xf5c2e7), rgb(0x94e2d5), rgb(0xa6adc8),
            rgb(0x585b70), rgb(0xf37799), rgb(0x89d88b), rgb(0xebd391),
            rgb(0x74a8fc), rgb(0xf2aede), rgb(0x6bd7ca), rgb(0xbac2de),
        },
    },
    .{
        .name = "Dracula",
        .foreground = rgb(0xf8f8f2),
        .background = rgb(0x282a36),
        .palette = .{
            rgb(0x21222c), rgb(0xff5555), rgb(0x50fa7b), rgb(0xf1fa8c),
            rgb(0xbd93f9), rgb(0xff79c6), rgb(0x8be9fd), rgb(0xf8f8f2),
            rgb(0x6272a4), rgb(0xff6e6e), rgb(0x69ff94), rgb(0xffffa5),
            rgb(0xd6acff), rgb(0xff92df), rgb(0xa4ffff), rgb(0xffffff),
        },
    },
    .{
        .name = "Gruvbox Dark",
        .foreground = rgb(0xebdbb2),
        .background = rgb(0x282828),
        .palette = .{
            rgb(0x282828), rgb(0xcc241d), rgb(0x98971a), rgb(0xd79921),
            rgb(0x458588), rgb(0xb16286), rgb(0x689d6a), rgb(0xa89984),
            rgb(0x928374), rgb(0xfb4934), rgb(0xb8bb26), rgb(0xfabd2f),
            rgb(0x83a598), rgb(0xd3869b), rgb(0x8ec07c), rgb(0xebdbb2),
        },
    },
    .{
        .name = "Tokyo Night",
        .foreground = rgb(0xc0caf5),
        .background = rgb(0x1a1b26),
        .palette = .{
            rgb(0x15161e), rgb(0xf7768e), rgb(0x9ece6a), rgb(0xe0af68),
            rgb(0x7aa2f7), rgb(0xbb9af7), rgb(0x7dcfff), rgb(0xa9b1d6),
            rgb(0x414868), rgb(0xf7768e), rgb(0x9ece6a), rgb(0xe0af68),
            rgb(0x7aa2f7), rgb(0xbb9af7), rgb(0x7dcfff), rgb(0xc0caf5),
        },
    },
    .{
        .name = "Nord",
        .foreground = rgb(0xd8dee9),
        .background = rgb(0x2e3440),
        .palette = .{
            rgb(0x3b4252), rgb(0xbf616a), rgb(0xa3be8c), rgb(0xebcb8b),
            rgb(0x81a1c1), rgb(0xb48ead), rgb(0x88c0d0), rgb(0xe5e9f0),
            rgb(0x596377), rgb(0xbf616a), rgb(0xa3be8c), rgb(0xebcb8b),
            rgb(0x81a1c1), rgb(0xb48ead), rgb(0x8fbcbb), rgb(0xeceff4),
        },
    },
    .{
        .name = "One Half Dark",
        .foreground = rgb(0xdcdfe4),
        .background = rgb(0x282c34),
        .palette = .{
            rgb(0x282c34), rgb(0xe06c75), rgb(0x98c379), rgb(0xe5c07b),
            rgb(0x61afef), rgb(0xc678dd), rgb(0x56b6c2), rgb(0xdcdfe4),
            rgb(0x5d677a), rgb(0xe06c75), rgb(0x98c379), rgb(0xe5c07b),
            rgb(0x61afef), rgb(0xc678dd), rgb(0x56b6c2), rgb(0xdcdfe4),
        },
    },
    .{
        .name = "Solarized Dark",
        .foreground = rgb(0x9cc2c3),
        .background = rgb(0x001e27),
        .palette = .{
            rgb(0x002831), rgb(0xd11c24), rgb(0x6cbe6c), rgb(0xa57706),
            rgb(0x2176c7), rgb(0xc61c6f), rgb(0x259286), rgb(0xeae3cb),
            rgb(0x006488), rgb(0xf5163b), rgb(0x51ef84), rgb(0xb27e28),
            rgb(0x178ec8), rgb(0xe24d8e), rgb(0x00b39e), rgb(0xfcf4dc),
        },
    },
    .{
        .name = "Monokai Soda",
        .foreground = rgb(0xc4c5b5),
        .background = rgb(0x1a1a1a),
        .palette = .{
            rgb(0x1a1a1a), rgb(0xf4005f), rgb(0x98e024), rgb(0xfa8419),
            rgb(0x9d65ff), rgb(0xf4005f), rgb(0x58d1eb), rgb(0xc4c5b5),
            rgb(0x625e4c), rgb(0xf4005f), rgb(0x98e024), rgb(0xe0d561),
            rgb(0x9d65ff), rgb(0xf4005f), rgb(0x58d1eb), rgb(0xf6f6ef),
        },
    },
    .{
        .name = "Rosé Pine",
        .foreground = rgb(0xe0def4),
        .background = rgb(0x191724),
        .palette = .{
            rgb(0x26233a), rgb(0xeb6f92), rgb(0x31748f), rgb(0xf6c177),
            rgb(0x9ccfd8), rgb(0xc4a7e7), rgb(0xebbcba), rgb(0xe0def4),
            rgb(0x6e6a86), rgb(0xeb6f92), rgb(0x31748f), rgb(0xf6c177),
            rgb(0x9ccfd8), rgb(0xc4a7e7), rgb(0xebbcba), rgb(0xe0def4),
        },
    },
    .{
        .name = "Kanagawa",
        .foreground = rgb(0xdcd7ba),
        .background = rgb(0x1f1f28),
        .palette = .{
            rgb(0x090618), rgb(0xc34043), rgb(0x76946a), rgb(0xc0a36e),
            rgb(0x7e9cd8), rgb(0x957fb8), rgb(0x6a9589), rgb(0xc8c093),
            rgb(0x727169), rgb(0xe82424), rgb(0x98bb6c), rgb(0xe6c384),
            rgb(0x7fb4ca), rgb(0x938aa9), rgb(0x7aa89f), rgb(0xdcd7ba),
        },
    },
    .{
        .name = "Everforest Dark",
        .foreground = rgb(0xd3c6aa),
        .background = rgb(0x1e2326),
        .palette = .{
            rgb(0x7a8478), rgb(0xe67e80), rgb(0xa7c080), rgb(0xdbbc7f),
            rgb(0x7fbbb3), rgb(0xd699b6), rgb(0x83c092), rgb(0xf2efdf),
            rgb(0xa6b0a0), rgb(0xf85552), rgb(0x8da101), rgb(0xdfa000),
            rgb(0x3a94c5), rgb(0xdf69ba), rgb(0x35a77c), rgb(0xfffbef),
        },
    },
    // ── Light themes (인기순) ────────────────────────────────
    .{
        .name = "Catppuccin Latte",
        .foreground = rgb(0x4c4f69),
        .background = rgb(0xeff1f5),
        .palette = .{
            rgb(0x5c5f77), rgb(0xd20f39), rgb(0x40a02b), rgb(0xdf8e1d),
            rgb(0x1e66f5), rgb(0xea76cb), rgb(0x179299), rgb(0xacb0be),
            rgb(0x6c6f85), rgb(0xde293e), rgb(0x49af3d), rgb(0xeea02d),
            rgb(0x456eff), rgb(0xfe85d8), rgb(0x2d9fa8), rgb(0xbcc0cc),
        },
    },
    .{
        .name = "Solarized Light",
        .foreground = rgb(0x657b83),
        .background = rgb(0xfdf6e3),
        .palette = .{
            rgb(0x073642), rgb(0xdc322f), rgb(0x859900), rgb(0xb58900),
            rgb(0x268bd2), rgb(0xd33682), rgb(0x2aa198), rgb(0xbbb5a2),
            rgb(0x002b36), rgb(0xcb4b16), rgb(0x586e75), rgb(0x657b83),
            rgb(0x839496), rgb(0x6c71c4), rgb(0x93a1a1), rgb(0xfdf6e3),
        },
    },
    .{
        .name = "Gruvbox Light",
        .foreground = rgb(0x3c3836),
        .background = rgb(0xfbf1c7),
        .palette = .{
            rgb(0xfbf1c7), rgb(0xcc241d), rgb(0x98971a), rgb(0xd79921),
            rgb(0x458588), rgb(0xb16286), rgb(0x689d6a), rgb(0x7c6f64),
            rgb(0x928374), rgb(0x9d0006), rgb(0x79740e), rgb(0xb57614),
            rgb(0x076678), rgb(0x8f3f71), rgb(0x427b58), rgb(0x3c3836),
        },
    },
    .{
        .name = "One Half Light",
        .foreground = rgb(0x383a42),
        .background = rgb(0xfafafa),
        .palette = .{
            rgb(0x383a42), rgb(0xe45649), rgb(0x50a14f), rgb(0xc18401),
            rgb(0x0184bc), rgb(0xa626a4), rgb(0x0997b3), rgb(0xbababa),
            rgb(0x4f525e), rgb(0xe06c75), rgb(0x98c379), rgb(0xd8b36e),
            rgb(0x61afef), rgb(0xc678dd), rgb(0x56b6c2), rgb(0xffffff),
        },
    },
};

pub fn findTheme(name: []const u8) ?*const Theme {
    for (&themes) |*t| {
        if (eqlIgnoreCase(t.name, name)) return t;
    }
    return null;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (toLower(ca) != toLower(cb)) return false;
    }
    return true;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
