# Keybindings

Cross-platform shortcut convention: each platform follows its native modifier (Apple HIG order Shift+Cmd on macOS, Ctrl+Shift on Windows).

| Action | Windows | macOS |
|--------|---------|-------|
| Toggle terminal show/hide | F1 (configurable) | F1 (configurable) |
| Fullscreen | Alt+Enter | (TBD) |
| New tab | Ctrl+Shift+T | Cmd+T |
| Close active tab | Ctrl+Shift+W | Cmd+W |
| Switch tab by index | Alt+1–9 | Cmd+1–9 |
| Previous tab | Ctrl+Shift+[ | Shift+Cmd+[ |
| Next tab | Ctrl+Shift+] | Shift+Cmd+] |
| Copy selection (explicit) | Ctrl+Shift+C | Cmd+C |
| Paste from clipboard | Ctrl+Shift+V | Cmd+V |
| Reset terminal | Ctrl+Shift+R | (TBD) |
| About dialog | Ctrl+Shift+I | Shift+Cmd+I |
| Open config in editor | Ctrl+Shift+P | Shift+Cmd+P |
| Open log in editor | Ctrl+Shift+L | Shift+Cmd+L |
| Perf snapshot to log | Ctrl+Shift+F12 | (dev tool, Win-only) |
| Quit | (close last tab) | Cmd+Q |
| Scrollback page up / down | Shift+PgUp / PgDn | Shift+PgUp / PgDn |

## Quit confirmation

Cmd+Q (macOS) and Alt+F4 (Windows) show a confirmation dialog with the open tab count. Default button is Cancel — an accidental Enter will not terminate. Closing the last tab via Cmd+W / Ctrl+Shift+W keeps its existing instant behavior — that path is an explicit "close this tab" intent.

## Tab rename

Double-click a tab to rename. While renaming:

- Type to insert characters (IME-aware, multi-byte friendly)
- Backspace / arrows / Home / End / Delete edit the name
- Enter commits, Escape cancels
- `Ctrl+Shift+V` (Windows) / `Cmd+V` (macOS) pastes clipboard text into the name (printable codepoints only — newlines and control chars are dropped)

## Mouse

| Action | Both platforms |
|--------|----------------|
| Drag-select text | Auto-copy on release |
| Double-click word | Word selection + auto-copy. Boundary chars: space / tab / `" \` \| : ; ( ) [ ] { } < >`. Wide chars (Hangul / CJK) treated as word body. |
| Mouse wheel | Scroll viewport |
| Right-click | Paste from clipboard |
| Scrollbar click / drag | Jump or follow viewport |
