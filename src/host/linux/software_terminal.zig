//! Temporary Linux bring-up renderer.
//!
//! This is intentionally small and software-only: it paints ghostty-vt render
//! state into a Wayland `wl_shm` XRGB8888 buffer so the Linux host can validate
//! PTY -> parser -> resize -> frame lifecycle before the real GPU/font stack is
//! selected.

const std = @import("std");
const ghostty = @import("ghostty-vt");
const themes = @import("../../themes.zig");

pub const cell_width_px: i32 = 8;
pub const cell_height_px: i32 = 16;
pub const padding_px: i32 = 8;

pub const Renderer = struct {
    render_state: ghostty.RenderState = .empty,

    pub fn deinit(self: *Renderer, allocator: std.mem.Allocator) void {
        self.render_state.deinit(allocator);
    }

    pub fn paint(
        self: *Renderer,
        allocator: std.mem.Allocator,
        memory: []u8,
        width: i32,
        height: i32,
        stride: i32,
        terminal: *ghostty.Terminal,
        theme: *const themes.Theme,
    ) void {
        self.render_state.update(allocator, terminal) catch {
            fill(memory, width, height, stride, theme.background);
            return;
        };

        const colors = self.render_state.colors;
        fill(memory, width, height, stride, colors.background);

        const rows = self.render_state.rows;
        const cols = self.render_state.cols;
        const row_slice = self.render_state.row_data.slice();
        const all_cells = row_slice.items(.cells);
        const all_sels = row_slice.items(.selection);

        for (0..rows) |y| {
            if (y >= all_cells.len) break;
            const cell_slice = all_cells[y].slice();
            const raws = cell_slice.items(.raw);
            const styles = cell_slice.items(.style);
            const sel_range: ?[2]u16 = if (y < all_sels.len) all_sels[y] else null;

            for (0..cols) |x| {
                if (x >= raws.len) break;
                const raw = raws[x];
                if (raw.wide == .spacer_tail or raw.wide == .spacer_head) continue;

                const style = if (raw.style_id != 0) styles[x] else ghostty.Style{};
                const x16: u16 = @intCast(x);
                const is_selected = if (sel_range) |sr| (x16 >= sr[0] and x16 <= sr[1]) else false;
                const bg = resolveBg(style, &raw, &colors, is_selected);
                const cell_x: i32 = padding_px + @as(i32, @intCast(x)) * cell_width_px;
                const cell_y: i32 = padding_px + @as(i32, @intCast(y)) * cell_height_px;
                const cell_w: i32 = if (raw.wide == .wide) cell_width_px * 2 else cell_width_px;

                if (is_selected or style.flags.inverse or style.bg(&raw, &colors.palette) != null) {
                    rect(memory, width, height, stride, cell_x, cell_y, cell_w, cell_height_px, bg);
                }

                if (!raw.hasText() or raw.codepoint() == 0) continue;
                const fg = resolveFg(style, &colors, is_selected);
                drawGlyph(memory, width, height, stride, cell_x, cell_y, raw.codepoint(), fg);
            }
        }

        if (self.render_state.cursor.visible) {
            if (self.render_state.cursor.viewport) |vp| {
                var cx: i32 = padding_px + @as(i32, @intCast(vp.x)) * cell_width_px;
                if (vp.wide_tail and vp.x > 0) cx -= cell_width_px;
                const cy: i32 = padding_px + @as(i32, @intCast(vp.y)) * cell_height_px;
                const cursor = colors.cursor orelse ghostty.color.RGB{ .r = 180, .g = 180, .b = 180 };
                rect(memory, width, height, stride, cx, cy + cell_height_px - 3, cell_width_px, 2, cursor);
            }
        }
    }
};

fn resolveFg(style: ghostty.Style, colors: *const ghostty.RenderState.Colors, selected: bool) ghostty.color.RGB {
    if (selected) return colors.background;
    if (style.flags.inverse) return colors.background;
    return style.fg(.{
        .default = colors.foreground,
        .palette = &colors.palette,
        .bold = .bright,
    });
}

fn resolveBg(
    style: ghostty.Style,
    raw: *const ghostty.Cell,
    colors: *const ghostty.RenderState.Colors,
    selected: bool,
) ghostty.color.RGB {
    if (selected) return colors.foreground;
    if (style.flags.inverse) {
        return style.fg(.{
            .default = colors.foreground,
            .palette = &colors.palette,
            .bold = .bright,
        });
    }
    return style.bg(raw, &colors.palette) orelse colors.background;
}

fn fill(memory: []u8, width: i32, height: i32, stride: i32, color: ghostty.color.RGB) void {
    rect(memory, width, height, stride, 0, 0, width, height, color);
}

fn rect(
    memory: []u8,
    width: i32,
    height: i32,
    stride: i32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    color: ghostty.color.RGB,
) void {
    const x0 = @max(0, x);
    const y0 = @max(0, y);
    const x1 = @min(width, x + w);
    const y1 = @min(height, y + h);
    if (x1 <= x0 or y1 <= y0) return;

    const packed_color = pack(color);
    var py = y0;
    while (py < y1) : (py += 1) {
        var px = x0;
        while (px < x1) : (px += 1) {
            const off: usize = @intCast(py * stride + px * 4);
            std.mem.writeInt(u32, memory[off..][0..4], packed_color, .little);
        }
    }
}

fn drawGlyph(
    memory: []u8,
    width: i32,
    height: i32,
    stride: i32,
    cell_x: i32,
    cell_y: i32,
    cp: u21,
    color: ghostty.color.RGB,
) void {
    const rows = glyphRows(cp) orelse glyphRows('?').?;
    const glyph_x = cell_x + 1;
    const glyph_y = cell_y + 1;
    for (rows, 0..) |bits, gy| {
        for (0..5) |gx| {
            const mask: u8 = @as(u8, 1) << @intCast(4 - gx);
            if ((bits & mask) == 0) continue;
            rect(
                memory,
                width,
                height,
                stride,
                glyph_x + @as(i32, @intCast(gx)),
                glyph_y + @as(i32, @intCast(gy)) * 2,
                1,
                2,
                color,
            );
        }
    }
}

fn pack(color: ghostty.color.RGB) u32 {
    return (@as(u32, color.r) << 16) | (@as(u32, color.g) << 8) | color.b;
}

fn glyphRows(cp: u21) ?[7]u8 {
    return switch (cp) {
        ' ' => .{ 0, 0, 0, 0, 0, 0, 0 },
        '!' => .{ 0b00100, 0b00100, 0b00100, 0b00100, 0, 0b00100, 0 },
        '"' => .{ 0b01010, 0b01010, 0b01010, 0, 0, 0, 0 },
        '#' => .{ 0b01010, 0b01010, 0b11111, 0b01010, 0b11111, 0b01010, 0b01010 },
        '$' => .{ 0b00100, 0b01111, 0b10100, 0b01110, 0b00101, 0b11110, 0b00100 },
        '%' => .{ 0b11001, 0b11010, 0b00010, 0b00100, 0b01000, 0b01011, 0b10011 },
        '&' => .{ 0b01100, 0b10010, 0b10100, 0b01000, 0b10101, 0b10010, 0b01101 },
        '\'' => .{ 0b00100, 0b00100, 0b01000, 0, 0, 0, 0 },
        '(' => .{ 0b00010, 0b00100, 0b01000, 0b01000, 0b01000, 0b00100, 0b00010 },
        ')' => .{ 0b01000, 0b00100, 0b00010, 0b00010, 0b00010, 0b00100, 0b01000 },
        '*' => .{ 0, 0b10101, 0b01110, 0b11111, 0b01110, 0b10101, 0 },
        '+' => .{ 0, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0 },
        ',' => .{ 0, 0, 0, 0, 0b00100, 0b00100, 0b01000 },
        '-' => .{ 0, 0, 0, 0b11111, 0, 0, 0 },
        '.' => .{ 0, 0, 0, 0, 0, 0b00100, 0 },
        '/' => .{ 0b00001, 0b00010, 0b00010, 0b00100, 0b01000, 0b01000, 0b10000 },
        '0' => .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 },
        '1' => .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        '2' => .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 },
        '3' => .{ 0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110 },
        '4' => .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 },
        '5' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b00001, 0b00001, 0b11110 },
        '6' => .{ 0b01110, 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 },
        '7' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 },
        '8' => .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 },
        '9' => .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b01110 },
        ':' => .{ 0, 0b00100, 0, 0, 0, 0b00100, 0 },
        ';' => .{ 0, 0b00100, 0, 0, 0b00100, 0b00100, 0b01000 },
        '<' => .{ 0b00010, 0b00100, 0b01000, 0b10000, 0b01000, 0b00100, 0b00010 },
        '=' => .{ 0, 0, 0b11111, 0, 0b11111, 0, 0 },
        '>' => .{ 0b01000, 0b00100, 0b00010, 0b00001, 0b00010, 0b00100, 0b01000 },
        '?' => .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0, 0b00100 },
        '@' => .{ 0b01110, 0b10001, 0b10111, 0b10101, 0b10111, 0b10000, 0b01110 },
        'A', 'a' => .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'B', 'b' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 },
        'C', 'c' => .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 },
        'D', 'd' => .{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110 },
        'E', 'e' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 },
        'F', 'f' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 },
        'G', 'g' => .{ 0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110 },
        'H', 'h' => .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'I', 'i' => .{ 0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        'J', 'j' => .{ 0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100 },
        'K', 'k' => .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 },
        'L', 'l' => .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 },
        'M', 'm' => .{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 },
        'N', 'n' => .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 },
        'O', 'o' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'P', 'p' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 },
        'Q', 'q' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 },
        'R', 'r' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 },
        'S', 's' => .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 },
        'T', 't' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 },
        'U', 'u' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'V', 'v' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 },
        'W', 'w' => .{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010 },
        'X', 'x' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 },
        'Y', 'y' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 },
        'Z', 'z' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 },
        '[' => .{ 0b01110, 0b01000, 0b01000, 0b01000, 0b01000, 0b01000, 0b01110 },
        '\\' => .{ 0b10000, 0b01000, 0b01000, 0b00100, 0b00010, 0b00010, 0b00001 },
        ']' => .{ 0b01110, 0b00010, 0b00010, 0b00010, 0b00010, 0b00010, 0b01110 },
        '^' => .{ 0b00100, 0b01010, 0b10001, 0, 0, 0, 0 },
        '_' => .{ 0, 0, 0, 0, 0, 0, 0b11111 },
        '`' => .{ 0b01000, 0b00100, 0b00010, 0, 0, 0, 0 },
        '{' => .{ 0b00010, 0b00100, 0b00100, 0b01000, 0b00100, 0b00100, 0b00010 },
        '|' => .{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 },
        '}' => .{ 0b01000, 0b00100, 0b00100, 0b00010, 0b00100, 0b00100, 0b01000 },
        '~' => .{ 0, 0, 0b01000, 0b10101, 0b00010, 0, 0 },
        else => null,
    };
}

test "software renderer has shell prompt glyphs" {
    for ("ensky0@utm-linux:~$ /bin/sh?") |c| {
        try std.testing.expect(glyphRows(c) != null);
    }
}
