const std = @import("std");
const ghostty = @import("ghostty-vt");
const win = @import("window.zig");

const WCHAR = u16;
const LONG = c_long;
const COLORREF = c_ulong;
const HDC = ?*anyopaque;
const HBRUSH = ?*anyopaque;
const HGDIOBJ = ?*anyopaque;
const RECT = extern struct { left: LONG, top: LONG, right: LONG, bottom: LONG };

extern "gdi32" fn SetTextColor(HDC, COLORREF) callconv(.c) COLORREF;
extern "gdi32" fn TextOutW(HDC, c_int, c_int, [*]const WCHAR, c_int) callconv(.c) c_int;
extern "gdi32" fn CreateSolidBrush(COLORREF) callconv(.c) HBRUSH;
extern "gdi32" fn FillRect(HDC, *const RECT, HBRUSH) callconv(.c) c_int;
extern "gdi32" fn DeleteObject(HGDIOBJ) callconv(.c) c_int;

fn rgbColor(r: u8, g: u8, b: u8) COLORREF {
    return @as(COLORREF, r) | (@as(COLORREF, g) << 8) | (@as(COLORREF, b) << 16);
}

/// Render terminal content using plainString approach.
/// This is a simple MVP renderer - extracts text and draws line by line.
pub fn renderTerminal(
    hdc: HDC,
    terminal: *ghostty.Terminal,
    alloc: std.mem.Allocator,
    cell_w: c_int,
    cell_h: c_int,
) void {
    _ = SetTextColor(hdc, rgbColor(204, 204, 204));

    // Get plain text content
    const text = terminal.plainString(alloc) catch return;
    defer alloc.free(text);

    // Draw text line by line
    var row: c_int = 0;
    var iter = std.mem.splitSequence(u8, text, "\n");
    while (iter.next()) |line| {
        if (line.len == 0) {
            row += 1;
            continue;
        }

        // Convert UTF-8 line to UTF-16 for TextOutW
        var wbuf: [512]WCHAR = undefined;
        var wlen: usize = 0;
        var utf8_view = std.unicode.Utf8View.init(line) catch {
            row += 1;
            continue;
        };
        var cp_iter = utf8_view.iterator();
        while (cp_iter.nextCodepoint()) |cp| {
            if (wlen >= wbuf.len - 1) break;
            if (cp <= 0xFFFF) {
                wbuf[wlen] = @intCast(cp);
                wlen += 1;
            } else {
                const adj = cp - 0x10000;
                wbuf[wlen] = @intCast(0xD800 + (adj >> 10));
                wlen += 1;
                if (wlen < wbuf.len) {
                    wbuf[wlen] = @intCast(0xDC00 + (adj & 0x3FF));
                    wlen += 1;
                }
            }
        }

        if (wlen > 0) {
            _ = TextOutW(hdc, 0, row * cell_h, &wbuf, @intCast(wlen));
        }
        row += 1;
    }

    // Draw cursor block
    const cursor_x: c_int = @intCast(terminal.screens.active.cursor.x);
    const cursor_y: c_int = @intCast(terminal.screens.active.cursor.y);
    const cursor_rect = RECT{
        .left = cursor_x * cell_w,
        .top = cursor_y * cell_h,
        .right = cursor_x * cell_w + cell_w,
        .bottom = cursor_y * cell_h + cell_h,
    };
    const cursor_brush = CreateSolidBrush(rgbColor(180, 180, 180));
    _ = FillRect(hdc, &cursor_rect, cursor_brush);
    _ = DeleteObject(cursor_brush);
}
