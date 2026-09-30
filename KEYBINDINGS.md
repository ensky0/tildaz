# Keybindings

> **These are the defaults.** You can change any of them in the `[keys]` table of
> your `config_N.toml` ([CONFIG.md](CONFIG.md#keyboard-shortcuts)). Keys you change
> will differ from this page — the `…` menu and your config file show your actual keys.

| Action | Linux · Windows | macOS |
|--------|-----------------|-------|
| Show / hide TildaZ (global) | F1 | F1 |
| New tab | Ctrl+Shift+T | Cmd+T |
| Close tab (all its panes) | Ctrl+Shift+W | Cmd+W |
| Go to tab 1–9 | Alt+1–9 | Cmd+1–9 |
| Previous / next tab | Ctrl+Shift+[ / ] *or* Ctrl+PgUp / PgDn | Shift+Cmd+[ / ] *or* Cmd+PgUp / PgDn |
| Split pane (new pane on that side) | Ctrl+Shift+←/→/↑/↓ | Option+Cmd+←/→/↑/↓ |
| Move focus to a pane | Alt+←/→/↑/↓ | Cmd+←/→/↑/↓ |
| Resize pane by one cell | Shift+Alt+←/→/↑/↓ | Shift+Cmd+←/→/↑/↓ |
| Equalize panes | Shift+Alt+0 | Shift+Cmd+0 |
| Zoom pane (toggle) | Ctrl+Shift+Z | Shift+Cmd+Z |
| Close pane | Ctrl+Shift+X | Shift+Cmd+X |
| Find in scrollback | Ctrl+Shift+F | Cmd+F |
| Copy / paste | Ctrl+Shift+C / V | Cmd+C / V |
| Fullscreen (cover taskbar / dock) | Alt+Enter | Cmd+Enter |
| Fullscreen (keep taskbar / dock) | Shift+Alt+Enter | Shift+Cmd+Enter |
| Reset terminal | Ctrl+Shift+R | Shift+Cmd+R |
| Open config | Ctrl+Shift+P | Shift+Cmd+P |
| Open log | Ctrl+Shift+L | Shift+Cmd+L |
| Open this page | Ctrl+Shift+/ | Shift+Cmd+/ |
| About | Ctrl+Shift+I | Shift+Cmd+I |
| Perf snapshot to log | Ctrl+Shift+F12 | Shift+Cmd+F12 |
| Quit | Alt+F4 | Cmd+Q |
| Scroll up / down *(fixed)* | Shift+PgUp / PgDn | Shift+PgUp / PgDn |

In the search panel: `Enter` next match (down), `Shift+Enter` previous (up), `Esc` close.

## Quit

Quit asks first and shows how many tabs (and panes) will close. `Enter` quits, `Esc`
cancels. Closing the last tab or pane with its own shortcut quits right away.

## Keys we do not take

Anything TildaZ does not bind goes to the program inside, encoded the way xterm does.
Programs that turn on the kitty keyboard protocol get that encoding instead.

On macOS, Option types characters (`Option+a` → `å`). To use it as Alt, set
`[input] macos_option_as_alt` in the config.

`Shift+PgUp` / `Shift+PgDn` and `Ctrl+C` (interrupt) cannot be rebound.

## Keyboard layouts

**Non-Latin layouts** (Cyrillic, Greek, Arabic, Hebrew, and on macOS Korean, Japanese,
Chinese) cannot type Latin letters. TildaZ notices and matches those shortcuts by the key
a US keyboard would press instead. Nothing to configure.

**Name a key by position** if you want it fixed to a spot on every layout. `[KeyW]` means
"the key where US QWERTY has `w`":

```toml
[keys]
close_tab = ["ctrl+shift+[KeyW]"]
prev_tab  = ["ctrl+shift+[BracketLeft]", "ctrl+pageup"]
```

**French AZERTY.** `[` needs AltGr there, so use `Ctrl+PgUp` / `Ctrl+PgDn` (or
`[BracketLeft]`) for tabs. `?` is on a different key, so write `ctrl+shift+[KeyM]` for
*Open this page* if you want it. Digits work as-is: digit shortcuts ignore Shift.

**Dead keys** (`^`, `¨`, `´`, `` ` ``, `~`) combine with the next key the way other apps do:
`^` `e` → `ê`, `^` `Space` → `^`. On Linux this uses your locale's Compose table; if none is
installed, dead keys stay silent and the log says `compose table unavailable`.

**macOS** matches letter shortcuts by the letter printed on the key, like Safari. Dvorak and
Colemak follow their own letters.

## The global hotkey

The show / hide hotkey is registered with your desktop, not handled by TildaZ, and desktops
differ in what they accept. **Use a function key** (`F1`–`F12`): those are the same on every
layout. Letters and punctuation can break on some layouts, especially on Hyprland —
[CONFIG.md](CONFIG.md#prefer-a-function-key) has the details.

## Tab bar and menu

- Controls sit at the top-right: `[tabs][+][×][…]`. With one tab only `[+][×][…]` shows.
- `+` opens a tab. Alt+click splits the active pane instead.
- `×` closes the active tab.
- `…` opens the command menu, with each command's shortcut next to it.
- In the menu, arrow keys move, `Enter` runs, `Esc` closes.
- Drag a tab to reorder it. Up to 32 tabs.

Tab titles follow the shell (OSC 0/2). A new tab is `Tab N` until the shell sends a title.

## Search

Searches the **active pane's** scrollback, case-insensitive, plain text (no regex).
`Enter` goes down and `Shift+Enter` goes up, starting from what is on screen, and wrap
around at the end. Each pane keeps its own search.

## Split panes

- Up to 16 panes per tab. The new pane takes half the space and gets focus.
- The active pane is marked with an amber line. A zoomed pane has an amber frame.
- Drag the gray line between panes to resize.
- Close a pane with `Ctrl+Shift+X` (`Shift+Cmd+X`), or `exit` in its shell.
  `Ctrl+Shift+W` closes the whole tab.
- A split is refused when a half would be smaller than 20 columns × 5 rows.

## Mouse

| Action | Result |
|--------|--------|
| Drag | Select and copy on release |
| Double-click | Select a word and copy |
| Wheel | Scroll the pane under the pointer |
| Right-click | Paste |
| Click a pane | Focus it |
| Drag the line between panes | Resize the panes |
| Click `…` | Open the command menu |
| Click / drag the scrollbar | Jump / scroll |
