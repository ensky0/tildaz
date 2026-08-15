# Keybindings

Cross-platform shortcut convention: each platform follows its native modifier (Apple HIG order Shift+Cmd on macOS; Ctrl+Shift on Linux and Windows).

| Action | Linux | macOS | Windows |
|--------|-------|-------|---------|
| Toggle terminal show/hide | F1 (configurable) | F1 (configurable) | F1 (configurable) |
| Fullscreen (cover taskbar/dock) | Alt+Enter | Cmd+Enter | Alt+Enter |
| Fullscreen (keep taskbar/dock visible) | Shift+Alt+Enter | Shift+Cmd+Enter | Shift+Alt+Enter |
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
| Perf snapshot to log | Ctrl+Shift+F12 | Shift+Cmd+F12 | Ctrl+Shift+F12 |
| Quit | Alt+F4 (or close last tab) | Cmd+Q | Alt+F4 (or close last tab) |
| Scrollback page up / down | Shift+PgUp / PgDn | Shift+PgUp / PgDn | Shift+PgUp / PgDn |

On Linux the drop-down is normally sized from config (`dock_position` /
`width_percent` / `height_percent`). Fullscreen is delegated to the compositor:
layer-shell desktops (KDE Plasma, Hyprland, COSMIC) re-anchor the surface
to all four edges — Alt+Enter covers the panels (`exclusive_zone = -1`),
Shift+Alt+Enter keeps them visible (`exclusive_zone = 0`); GNOME and Cinnamon
(no layer-shell) use `xdg_toplevel.set_fullscreen` / `set_maximized`; sway uses
a regular window placed over i3 IPC (#454) — Alt+Enter is
`xdg_toplevel.set_fullscreen`, Shift+Alt+Enter fills the workspace area (panels
stay visible) via IPC. The toggle
applies only while the terminal is visible, and the fullscreen state is
preserved across F1 hide/show. Each fullscreen mode is exited only by its own
shortcut: pressing the *other* combination while fullscreen is ignored on all
three platforms (leave the current mode first, then enter the other one). The perf-snapshot shortcut (Ctrl+Shift+F12)
writes a render / read-loop timing snapshot to the log and works on all three
platforms.

## Quit confirmation

Alt+F4 (Linux and Windows) and Cmd+Q (macOS) show a confirmation dialog with the open tab count. Enter confirms (Quit); Esc cancels. Closing the last tab via Cmd+W / Ctrl+Shift+W keeps its existing instant behavior — that path is an explicit "close this tab" intent.

## Tab bar controls

Tab controls stay at the right edge instead of putting a destructive close
target inside every tab. With one tab, a compact `[+][×][…]` strip overlays the
top-right corner without reserving a full tab bar or moving the terminal grid.
With multiple tabs the order is `[tabs][+][×][…]`; when tabs overflow, it becomes
`[<][tabs][>][+][×][…]`.

- `<` / `>` scroll the visible tab strip and disable at the corresponding end.
- `×` closes the active tab, matching Cmd+W / Ctrl+Shift+W.
- `+` opens a tab. At the 32-tab limit it stays in place, turns gray, and
  ignores clicks.
- `…` opens the command menu. It lists the common tab, clipboard, fullscreen,
  config, shortcut-reference, and About actions together with their shortcuts.
  Its first item toggles TildaZ and shows the current instance's configured
  global hotkey rather than assuming F1.
- While the menu is open it captures the keyboard: `Esc` closes it,
  `Up` / `Down` / `Home` / `End` / `Tab` / `Shift+Tab` move focus, and
  `Enter` / `Space` run the focused command. Hovering an item with the mouse
  moves the keyboard focus there too. Other keys do nothing and are not sent
  to the terminal. Clicking outside (including right-click) only closes the
  menu. If the window is too short, the menu trims whole rows, shows chevron
  rows at the top and bottom (gray when that end is reached), and the mouse
  wheel, arrow keys, or a click on a chevron row scrolls the hidden items
  into view.
- The single-tab scrollbar starts below the 28-point control strip, while the
  terminal grid continues to use the full height behind it.
- Clicking a tab only activates it. Dragging a tab reorders it.

## Tab titles

Tab titles follow the shell automatically (OSC 0/2 window titles — most shells
and programs like vim or ssh set them). A new tab is labeled `Tab N` as soon as
it opens, and the shell's first title replaces it as soon as it arrives; shells
that never send one keep `Tab N`. Later title changes are debounced so a busy
program doesn't flicker the tab. To set a title yourself, use your shell —
e.g. `printf '\033]0;my title\007'` or your shell prompt configuration. (Inline tab renaming was removed in
[#341](https://github.com/ensky0/tildaz/issues/341).)

## Tab limit

`session_core.MAX_TABS = 32` on all platforms. The `+` button hides automatically at 32 tabs and reappears when one closes. Triggering new-tab via Cmd+T / Ctrl+Shift+T while at the limit shows a "Tab limit reached" dialog so the constraint isn't silently ignored when the visual cue is offscreen.

## Mouse

| Action | All platforms |
|--------|---------------|
| Drag-select text | Auto-copy on release |
| Double-click word | Word selection + auto-copy. Boundary chars: space / tab / `" \` \| : ; ( ) [ ] { } < >`. Wide chars (Hangul / CJK) treated as word body. |
| Mouse wheel | Scroll viewport |
| Right-click | Paste from clipboard |
| Click `…` | Open the command menu and shortcut hints |
| Scrollbar click / drag | Jump or follow viewport |
