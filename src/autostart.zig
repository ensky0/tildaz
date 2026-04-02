const std = @import("std");
const windows = std.os.windows;

const HKEY = ?*anyopaque;
const DWORD = windows.DWORD;
const WCHAR = u16;
const BYTE = windows.BYTE;

const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
const KEY_SET_VALUE: DWORD = 0x0002;
const KEY_QUERY_VALUE: DWORD = 0x0001;
const REG_SZ: DWORD = 1;
const ERROR_SUCCESS: DWORD = 0;

extern "advapi32" fn RegOpenKeyExW(HKEY, [*:0]const WCHAR, DWORD, DWORD, *HKEY) callconv(.c) DWORD;
extern "advapi32" fn RegSetValueExW(HKEY, [*:0]const WCHAR, DWORD, DWORD, [*]const BYTE, DWORD) callconv(.c) DWORD;
extern "advapi32" fn RegDeleteValueW(HKEY, [*:0]const WCHAR) callconv(.c) DWORD;
extern "advapi32" fn RegCloseKey(HKEY) callconv(.c) DWORD;
extern "kernel32" fn GetModuleFileNameW(HKEY, [*]WCHAR, DWORD) callconv(.c) DWORD;

const RUN_KEY = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const VALUE_NAME = std.unicode.utf8ToUtf16LeStringLiteral("TildaZ");

pub fn enable() !void {
    // Get current exe path
    var path_buf: [260]WCHAR = undefined;
    const len = GetModuleFileNameW(null, &path_buf, path_buf.len);
    if (len == 0) return error.GetModuleFileNameFailed;

    // Open registry key
    var hkey: HKEY = null;
    const result = RegOpenKeyExW(HKEY_CURRENT_USER, RUN_KEY, 0, KEY_SET_VALUE, &hkey);
    if (result != ERROR_SUCCESS) return error.RegOpenFailed;
    defer _ = RegCloseKey(hkey);

    // Set value (exe path as REG_SZ)
    const byte_len: DWORD = @intCast((len + 1) * @sizeOf(WCHAR));
    const set_result = RegSetValueExW(
        hkey,
        VALUE_NAME,
        0,
        REG_SZ,
        @ptrCast(&path_buf),
        byte_len,
    );
    if (set_result != ERROR_SUCCESS) return error.RegSetValueFailed;
}

pub fn disable() !void {
    var hkey: HKEY = null;
    const result = RegOpenKeyExW(HKEY_CURRENT_USER, RUN_KEY, 0, KEY_SET_VALUE, &hkey);
    if (result != ERROR_SUCCESS) return error.RegOpenFailed;
    defer _ = RegCloseKey(hkey);

    _ = RegDeleteValueW(hkey, VALUE_NAME);
}
