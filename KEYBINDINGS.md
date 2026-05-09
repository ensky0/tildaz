# Keybindings

Cross-platform shortcut convention: each platform follows its native modifier (Apple HIG order Shift+Cmd on macOS, Ctrl+Shift on Windows).

| Action | Windows | macOS |
|--------|---------|-------|
| Toggle terminal show/hide | F1 (configurable) | F1 (configurable) |
| Fullscreen (taskbar/dock 덮음) | Alt+Enter | Cmd+Enter |
| 풀스크린 (taskbar/dock 회피) | Shift+Alt+Enter | Shift+Cmd+Enter |
| New tab | Ctrl+Shift+T | Cmd+T |
| Close active tab | Ctrl+Shift+W | Cmd+W |
| Switch tab by index | Alt+1–9 | Cmd+1–9 |
| Previous tab | Ctrl+Shift+[ | Shift+Cmd+[ |
| Next tab | Ctrl+Shift+] | Shift+Cmd+] |
| Copy selection (explicit) | Ctrl+Shift+C | Cmd+C |
| Paste from clipboard | Ctrl+Shift+V | Cmd+V |
| Reset terminal | Ctrl+Shift+R | Shift+Cmd+R |
| About dialog | Ctrl+Shift+I | Shift+Cmd+I |
| Open config in editor | Ctrl+Shift+P | Shift+Cmd+P |
| Open log in editor | Ctrl+Shift+L | Shift+Cmd+L |
| Perf snapshot to log | Ctrl+Shift+F12 | Shift+Cmd+F12 |
| Quit | (close last tab) | Cmd+Q |
| Scrollback page up / down | Shift+PgUp / PgDn | Shift+PgUp / PgDn |

## Quit confirmation

Cmd+Q (macOS) and Alt+F4 (Windows) show a confirmation dialog with the open tab count. Default button is Cancel — an accidental Enter will not terminate. Closing the last tab via Cmd+W / Ctrl+Shift+W keeps its existing instant behavior — that path is an explicit "close this tab" intent.

## Tab rename

Double-click a tab to rename. While renaming:

- Type to insert characters (IME-aware, multi-byte friendly). The IME pre-edit appears inline at the cursor on a purple background on both Windows and macOS.
- Backspace / arrows / Home / End / Delete edit the name
- Enter commits, Escape cancels
- `Ctrl+Shift+V` (Windows) / `Cmd+V` (macOS) pastes clipboard text into the name (printable codepoints only — newlines and control chars are dropped)
- **Click inside the same tab's text** → cursor jumps to the click position; any in-progress IME pre-edit is committed in place. Click outside (other tabs, the close button, the terminal, the arrows) commits and ends the rename.
- **Mid-string typing** pushes only the characters after the cursor by the pre-edit's width. Commit drops the new characters there; Escape returns the trailing characters back to where they were.

## Tab limit

`session_core.MAX_TABS = 32` on both platforms. The `+` button hides automatically at 32 tabs and reappears when one closes. Triggering new-tab via Cmd+T / Ctrl+Shift+T while at the limit shows a "Tab limit reached" dialog so the constraint isn't silently ignored when the visual cue is offscreen.

## Mouse

| Action | Both platforms |
|--------|----------------|
| Drag-select text | Auto-copy on release |
| Double-click word | Word selection + auto-copy. Boundary chars: space / tab / `" \` \| : ; ( ) [ ] { } < >`. Wide chars (Hangul / CJK) treated as word body. |
| Mouse wheel | Scroll viewport |
| Right-click | Paste from clipboard |
| Scrollbar click / drag | Jump or follow viewport |
