# Keybindings

Cross-platform shortcut convention: each platform follows its native modifier (Apple HIG order Shift+Cmd on macOS; Ctrl+Shift on Linux and Windows).

These are the **defaults**. Every row except the scrollback pair can be changed in
the `[keys]` table of your config — see [CONFIG.md](CONFIG.md#keyboard-shortcuts)
for the syntax, and [Keyboard layouts](#keyboard-layouts) below if your keyboard
is not US QWERTY.

| Action | Linux | macOS | Windows |
|--------|-------|-------|---------|
| Toggle terminal show/hide | F1 (configurable) | F1 (configurable) | F1 (configurable) |
| Fullscreen (cover taskbar/dock) | Alt+Enter | Cmd+Enter | Alt+Enter |
| Fullscreen (keep taskbar/dock visible) | Shift+Alt+Enter | Shift+Cmd+Enter | Shift+Alt+Enter |
| New tab | Ctrl+Shift+T | Cmd+T | Ctrl+Shift+T |
| Close active tab | Ctrl+Shift+W | Cmd+W | Ctrl+Shift+W |
| Switch tab by index | Alt+1–9 | Cmd+1–9 | Alt+1–9 |
| Previous tab | Ctrl+Shift+[ *or* Ctrl+PgUp | Shift+Cmd+[ *or* Cmd+PgUp | Ctrl+Shift+[ *or* Ctrl+PgUp |
| Next tab | Ctrl+Shift+] *or* Ctrl+PgDn | Shift+Cmd+] *or* Cmd+PgDn | Ctrl+Shift+] *or* Ctrl+PgDn |
| Copy selection (explicit) | Ctrl+Shift+C | Cmd+C | Ctrl+Shift+C |
| Paste from clipboard | Ctrl+Shift+V | Cmd+V | Ctrl+Shift+V |
| Reset terminal | Ctrl+Shift+R | Shift+Cmd+R | Ctrl+Shift+R |
| About dialog | Ctrl+Shift+I | Shift+Cmd+I | Ctrl+Shift+I |
| Open config in editor | Ctrl+Shift+P | Shift+Cmd+P | Ctrl+Shift+P |
| Open log in editor | Ctrl+Shift+L | Shift+Cmd+L | Ctrl+Shift+L |
| Perf snapshot to log | Ctrl+Shift+F12 | Shift+Cmd+F12 | Ctrl+Shift+F12 |
| Quit | Alt+F4 (or close last tab) | Cmd+Q | Alt+F4 (or close last tab) |
| Scrollback page up / down *(fixed)* | Shift+PgUp / PgDn | Shift+PgUp / PgDn | Shift+PgUp / PgDn |

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

Everything in the table above except the scrollback row can be rebound in
`config_N.toml` — see the `[keys]` section in [CONFIG.md](CONFIG.md). Scrolling
the scrollback is fixed, because it is scrolling rather than a shortcut: the same
action as the mouse wheel, which is also not rebindable.

## Keyboard layouts

Every binding above can be changed in `[keys]` (see CONFIG.md). This section is
about the cases where the *default* bindings cannot be typed at all, and what to
write instead.

### Non-Latin layouts: letter shortcuts cannot work by label

On a Cyrillic, Greek, Arabic, or Hebrew layout, **no key produces a Latin
letter**. `Ctrl+Shift+W` is therefore unreachable — not awkward, unreachable.
The keyboard has no `w` to press:

```
$ xkbcli how-to-type --layout ru 'w'
(nothing)
```

Rebinding to another letter does not help, because the problem is the whole
Latin alphabet.

**TildaZ handles this for you.** When it loads a keymap it checks, for every
label binding, whether the current keymap can produce that character at all. If
nothing can, it matches that binding by the physical spot the character occupies
on a US keyboard instead. So the defaults work on a Cyrillic layout with no
config changes: you press the same key a US user presses.

Two details worth knowing:

- **It only kicks in when the label is unreachable in the layout you are
  currently typing in.** With `us,ru` — the common setup — nothing changes while
  you are on `us`, and the fallback takes over the moment you switch to `ru`. It
  is re-evaluated on every layout switch, so you never have to restart.
- **It is Linux-only, because only Linux needs it.** Windows non-Latin layouts
  assign Latin virtual keys to the physical spots (`KBDRU` puts `VK_W` on the
  `w` position), and macOS matches physical key codes to begin with, so letter
  shortcuts already work there.

You can still name a key by **position** explicitly, which is useful if you want
a shortcut pinned to a spot regardless of layout:

```toml
[keys]
new_tab        = ["ctrl+shift+[KeyT]"]
close_tab      = ["ctrl+shift+[KeyW]"]
copy_selection = ["ctrl+shift+[KeyC]"]
paste          = ["ctrl+shift+[KeyV]"]
prev_tab       = ["ctrl+shift+[BracketLeft]", "ctrl+pageup"]
next_tab       = ["ctrl+shift+[BracketRight]", "ctrl+pagedown"]
```

`[KeyW]` means "the key where a US QWERTY keyboard has `w`". You press the same
physical key a US user presses; what it prints does not matter. The names are
W3C `KeyboardEvent.code` values — the full list is in CONFIG.md.

### French AZERTY

Letters are fine on AZERTY (it is a Latin layout), but two of the defaults are
not.

**Brackets.** `[` is AltGr+5, so `Ctrl+Shift+[` means Ctrl+Shift+AltGr+5 — four
fingers. Two ways out, and the second is already bound by default:

```toml
prev_tab = ["ctrl+shift+[BracketLeft]", "ctrl+pageup"]
```

`[BracketLeft]` is the physical spot, which on AZERTY is the `^` key next to
`P` — reachable with no AltGr. And **`Ctrl+PgUp` / `Ctrl+PgDn` work on every
layout** because PgUp and PgDn are single physical keys everywhere; they match
what GNOME Terminal, Konsole, and Windows Terminal use.

**The digit row.** AZERTY needs Shift for digits (unshifted it is `&é"'(-è_çà`),
so `Alt+1` physically arrives as Alt+Shift+the `&1` key. TildaZ accepts that:
digit bindings ignore Shift, on every layout. Nothing to change.

**The extra ISO key.** AZERTY has a `<>` key that US keyboards do not have. It
is `[IntlBackslash]` if you want to bind it.

### macOS

macOS reports the physical key, so a shortcut lands on the same *spot* on every
layout. That is Apple's convention and it cuts both ways: an AZERTY user's
`Cmd+W` is the key printed `Z`, because that spot is where US QWERTY has `w`.
Nothing to configure — but worth knowing if the letter in the menu does not
match the key you press.

Mac laptops have no dedicated PgUp / PgDn keys; they are Fn+Up / Fn+Down. The
`Shift+Cmd+[` / `]` and `Cmd+1`–`9` defaults are unchanged, so nothing is lost.
`Cmd+PgUp` / `Cmd+PgDn` is an addition for people who use the same reflex on more
than one OS.

A few positions do not exist on macOS — `[PrintScreen]`, `[ScrollLock]` and
`[Pause]` arrive as `[F13]`, `[F14]`, `[F15]`. CONFIG.md has the details.

### The global hotkey is different

`hotkey` is registered with the desktop rather than handled inside TildaZ, and
every path TildaZ uses for that — sway, Hyprland, GNOME, Cinnamon, COSMIC, KDE —
accepts only a character, so it does **not** take the position form.

Most desktops paper over this for you: GNOME (since 3.28), Cinnamon (since 5.4),
COSMIC and KDE all translate a Latin-letter shortcut back to the key you actually
pressed on a Cyrillic or Greek layout. GNOME and Cinnamon do it even if a Latin
layout is not among the ones you have configured; COSMIC and KDE need one.
**sway and Hyprland do not do it at all.**

**A function key is the safest choice**: `F1`–`F12` are identical on every layout,
which is why the default is `F1`. Punctuation is the worst choice — a `grave`
hotkey has no key to bind to on a German layout, and GNOME's fallback does not
cover that case because it only triggers when the *alphabet* is missing.

### What stays fixed

`Shift+PgUp` / `Shift+PgDn` scroll the scrollback and cannot be rebound —
scrolling is the mouse wheel's action driven from the keyboard, and the wheel is
not rebindable either. Unmodified PgUp / PgDn go to the program running in the
terminal. `Ctrl+C` always sends SIGINT.

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
