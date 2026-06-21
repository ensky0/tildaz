# Keybindings

Cross-platform shortcut convention: each platform follows its native modifier (Apple HIG order Shift+Cmd on macOS; Ctrl+Shift on Windows and Linux).

| Action | Windows | macOS | Linux |
|--------|---------|-------|-------|
| Toggle terminal show/hide | F1 (configurable) | F1 (configurable) | F1 (configurable) |
| Fullscreen (taskbar/dock 덮음) | Alt+Enter | Cmd+Enter | Alt+Enter |
| 풀스크린 (taskbar/dock 회피) | Shift+Alt+Enter | Shift+Cmd+Enter | Shift+Alt+Enter |
| New tab | Ctrl+Shift+T | Cmd+T | Ctrl+Shift+T |
| Close active tab | Ctrl+Shift+W | Cmd+W | Ctrl+Shift+W |
| Switch tab by index | Alt+1–9 | Cmd+1–9 | Alt+1–9 |
| Previous tab | Ctrl+Shift+[ | Shift+Cmd+[ | Ctrl+Shift+[ |
| Next tab | Ctrl+Shift+] | Shift+Cmd+] | Ctrl+Shift+] |
| Copy selection (explicit) | Ctrl+Shift+C | Cmd+C | Ctrl+Shift+C |
| Paste from clipboard | Ctrl+Shift+V | Cmd+V | Ctrl+Shift+V |
| Reset terminal | Ctrl+Shift+R | Shift+Cmd+R | Ctrl+Shift+R |
| About dialog | Ctrl+Shift+I | Shift+Cmd+I | Ctrl+Shift+I |
| Open config in editor | Ctrl+Shift+P | Shift+Cmd+P | Ctrl+Shift+P |
| Open log in editor | Ctrl+Shift+L | Shift+Cmd+L | Ctrl+Shift+L |
| Perf snapshot to log | Ctrl+Shift+F12 | Shift+Cmd+F12 | — |
| Quit | Alt+F4 (or close last tab) | Cmd+Q | Alt+F4 (or close last tab) |
| Scrollback page up / down | Shift+PgUp / PgDn | Shift+PgUp / PgDn | Shift+PgUp / PgDn |

On Linux the drop-down is normally sized from config (`dock_position` /
`width_percent` / `height_percent`). Fullscreen is delegated to the compositor:
layer-shell desktops (KDE Plasma, sway, Hyprland, COSMIC) re-anchor the surface
to all four edges — Alt+Enter covers the panels (`exclusive_zone = -1`),
Shift+Alt+Enter keeps them visible (`exclusive_zone = 0`); GNOME and Cinnamon
(no layer-shell) use `xdg_toplevel.set_fullscreen` / `set_maximized`. The toggle
applies only while the terminal is visible, and the fullscreen state is
preserved across F1 hide/show. The perf-snapshot shortcut (Ctrl+Shift+F12) is
not yet wired on Linux.

## Quit confirmation

Cmd+Q (macOS) and Alt+F4 (Windows / Linux) show a confirmation dialog with the open tab count. Enter confirms (Quit); Esc cancels. Closing the last tab via Cmd+W / Ctrl+Shift+W keeps its existing instant behavior — that path is an explicit "close this tab" intent.

## Tab rename

Double-click a tab to rename. While renaming:

- Type to insert characters (IME-aware, multi-byte friendly). The IME pre-edit appears inline at the cursor on a purple background on Windows, macOS, and Linux.
- Backspace / Left / Right / Delete edit the name
- **Line begin / end navigation**: `Home` and `End` keys (all platforms), plus `Ctrl+A` and `Ctrl+E` (terminal-style, all platforms — matches mac Terminal.app and `readline` convention)
- Enter commits, Escape cancels
- `Ctrl+Shift+V` (Windows / Linux) / `Cmd+V` (macOS) pastes clipboard text into the name (printable codepoints only — newlines and control chars are dropped)
- **Click inside the same tab's text** → cursor jumps to the click position; any in-progress IME pre-edit is committed in place. Click outside (other tabs, the close button, the terminal, the arrows) commits and ends the rename.
- **Mid-string typing** pushes only the characters after the cursor by the pre-edit's width. Commit drops the new characters there; Escape returns the trailing characters back to where they were.
- **IME pre-edit + line nav**: pressing Home / End / Ctrl+A / Ctrl+E while a Korean / Japanese / Chinese syllable is composing commits the pre-edit's jamo into the rename buffer at the current cursor position, *then* moves the cursor (no syllable lost). Esc still cancels (pre-edit discarded). See SPEC §5.1 for the full matrix.
- **Click on a long name + cursor jumps** ([#168](https://github.com/ensky0/tildaz/issues/168)): on long tab names, clicking the middle keeps the cursor at the click position — no more "snaps to right edge" (v0.4.0).

## Tab limit

`session_core.MAX_TABS = 32` on all platforms. The `+` button hides automatically at 32 tabs and reappears when one closes. Triggering new-tab via Cmd+T / Ctrl+Shift+T while at the limit shows a "Tab limit reached" dialog so the constraint isn't silently ignored when the visual cue is offscreen.

## Mouse

| Action | All platforms |
|--------|---------------|
| Drag-select text | Auto-copy on release |
| Double-click word | Word selection + auto-copy. Boundary chars: space / tab / `" \` \| : ; ( ) [ ] { } < >`. Wide chars (Hangul / CJK) treated as word body. |
| Mouse wheel | Scroll viewport |
| Right-click | Paste from clipboard |
| Scrollbar click / drag | Jump or follow viewport |
