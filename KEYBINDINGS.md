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
| Close active pane (the tab, when it is the last pane) | Ctrl+Shift+W | Cmd+W | Ctrl+Shift+W |
| Switch tab by index | Alt+1–9 | Cmd+1–9 | Alt+1–9 |
| Previous tab | Ctrl+Shift+[ *or* Ctrl+PgUp | Shift+Cmd+[ *or* Cmd+PgUp | Ctrl+Shift+[ *or* Ctrl+PgUp |
| Next tab | Ctrl+Shift+] *or* Ctrl+PgDn | Shift+Cmd+] *or* Cmd+PgDn | Ctrl+Shift+] *or* Ctrl+PgDn |
| Split pane — new pane to the left / right / above / below *(Linux; see [Split panes](#split-panes))* | Ctrl+Shift+←/→/↑/↓ | Ctrl+Cmd+←/→/↑/↓ | Ctrl+Shift+←/→/↑/↓ |
| Focus the pane in a direction | Alt+←/→/↑/↓ | Cmd+←/→/↑/↓ | Alt+←/→/↑/↓ |
| Move the split next to the active pane by one cell | Shift+Alt+←/→/↑/↓ | Shift+Cmd+←/→/↑/↓ | Shift+Alt+←/→/↑/↓ |
| Make all panes of the tab the same size | Shift+Alt+0 | Shift+Cmd+0 | Shift+Alt+0 |
| Zoom the active pane to the whole tab (toggle) | Ctrl+Shift+Z | Shift+Cmd+Z | Ctrl+Shift+Z |
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

**TildaZ handles this for you.** It checks, for every label binding, whether the
layout you are currently typing in can produce that character at all. If nothing
can, it matches that binding by the physical spot the character occupies on a US
keyboard instead. So the defaults work on a Cyrillic layout with no config
changes: you press the same key a US user presses.

Two details worth knowing:

- **It only kicks in when the label is unreachable in the layout you are
  currently typing in.** With `us,ru` — the common setup — nothing changes while
  you are on `us`, and the fallback takes over the moment you switch to `ru`. It
  is re-evaluated on every layout switch, so you never have to restart.
- **Linux and macOS both do this; Windows does not need it.** A Windows
  non-Latin layout DLL assigns Latin virtual keys to the physical spots (`KBDRU`
  puts `VK_W` on the `w` position), so the OS has already done the equivalent
  work. On macOS the fallback also covers Korean, Japanese, and Chinese input
  sources — those keyboard layouts produce no Latin letters either, so the same
  rule keeps their shortcuts working.

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

**Letter shortcuts match the letter printed on the key**, the same way Safari and
other Mac apps do. On AZERTY, `Cmd+W` is the key printed `W`. If your layout
produces no Latin letters at all — Cyrillic, Greek, or a Korean / Japanese /
Chinese input source — the Latin fallback above takes over and you press the spot
a US user presses. Nothing to configure either way.

This is a change: TildaZ used to match the physical *spot* on macOS, so an AZERTY
user's `Cmd+W` was the key printed `Z` — a different key from the one Safari
wanted on the same Mac ([#496](https://github.com/ensky0/tildaz/issues/496)).
**Dvorak and Colemak users are affected by the same change**: shortcuts now
follow the letters printed on your keys rather than the US spots.

Mac laptops have no dedicated PgUp / PgDn keys; they are Fn+Up / Fn+Down. The
`Shift+Cmd+[` / `]` and `Cmd+1`–`9` defaults are unchanged, so nothing is lost.
`Cmd+PgUp` / `Cmd+PgDn` is an addition for people who use the same reflex on more
than one OS.

A few positions do not exist on macOS — `[PrintScreen]`, `[ScrollLock]` and
`[Pause]` arrive as `[F13]`, `[F14]`, `[F15]`. CONFIG.md has the details.

### The global hotkey is different

`hotkey` is registered with the desktop rather than handled inside TildaZ, and
the desktops do not agree on what they accept. It takes the position form, but
how that reaches the desktop differs:

| Desktop | How a position is registered |
|---|---|
| sway, Hyprland | by key position (`bindcode`, `code:`) |
| GNOME, Cinnamon | by key position (`0x31`) |
| **COSMIC, KDE** | **by the character that position types on your current layout** |
| Windows | by the virtual key that position holds on your current layout |
| macOS | by key position |

The rows that follow your layout re-register themselves when you switch layouts
while TildaZ is running. A layout switch while TildaZ is closed is picked up the
next time it starts.

**Dead keys are the exception.** On a German layout the `[Backquote]` position is
a dead accent, and COSMIC and KDE have no way to express that, so TildaZ logs it
instead of registering a shortcut that would fire the wrong key.

**On macOS the global hotkey matches by position, not by label.** It is caught by
an event tap before any layout translation, so `hotkey` and `[keys]` use
different criteria there. The default `F1` is layout-independent, so this stays
invisible unless you change `hotkey` to a letter combination *and* use a non-US
layout — then the global hotkey wants the US spot while a `[keys]` binding for
the same letter wants the printed key. Unifying the two is tracked in
[#496](https://github.com/ensky0/tildaz/issues/496) (item 1-c).

Most desktops paper over this for you: GNOME (since 3.28), Cinnamon (since 5.4),
COSMIC and KDE all translate a Latin-letter shortcut back to the key you actually
pressed on a Cyrillic or Greek layout. GNOME and Cinnamon do it even if a Latin
layout is not among the ones you have configured; COSMIC and KDE need one.
**sway and Hyprland do not do it at all.**

**A function key is the safest choice**: `F1`–`F12` are identical on every layout,
which is why the default is `F1`. Punctuation is the worst choice — a `grave`
hotkey has no key to bind to on a German layout, and GNOME's fallback does not
cover that case because it only triggers when the *alphabet* is missing.

### Known limitation: the global hotkey on Hyprland

Every desktop except Hyprland gets this right, by one route or another:

| Desktop | How the hotkey survives a layout it cannot type |
|---|---|
| GNOME (3.28+), Cinnamon (5.4+) | the compositor falls back to a US layout it compiles itself |
| COSMIC, KDE | the compositor falls back to another layout you have configured |
| **sway** | **TildaZ registers it by physical key position** (`bindcode`) |
| **Hyprland** | — nothing |

On Hyprland the hotkey is matched against the character the active layout
produces, so it stops working while a layout that cannot type that character is
active, and starts working again when you switch back. The binding is registered
successfully either way. Nothing warns you; it just does not fire.

**So on Hyprland, do not use a letter or punctuation for `hotkey` if you type in
any of the layouts below. Use a function key.** `F1`–`F12` are the same on every
layout, which is why the default is `F1`.

Measured with `xkbcli how-to-type` — ✅ means that layout can type the character,
so a hotkey using it keeps working:

| Layout | `A`–`Z` | `0`–`9` | `` ` `` | `[` `]` |
|---|:--:|:--:|:--:|:--:|
| US, UK, French, Italian, Japanese | ✅ | ✅ | ✅ | ✅ |
| **German, Spanish** | ✅ | ✅ | **❌** | ✅ |
| Greek, Arabic | ❌ | ✅ | ✅ | ✅ |
| Ukrainian, Bulgarian, Hebrew | ❌ | ✅ | ❌ | ✅ |
| **Russian** | ❌ | ✅ | ❌ | **❌** |
| **Thai** | ❌ | **❌** | ❌ | ❌ |

Three of those are easy to get wrong:

- **German and Spanish cannot type `` ` ``** even though they are Latin layouts.
  A ``Ctrl+` `` hotkey is dead there. Their key in that position is a dead
  accent, not a backtick.
- **Greek and Arabic can**, so ``Ctrl+` `` survives on those while letters do not.
- **Thai cannot type digits**, so even `Alt+1` is dead — the only layout here
  where a digit hotkey fails.

This affects the **global hotkey on Hyprland only**. Shortcuts inside TildaZ
(`[keys]`) are matched by TildaZ itself and fall back to the physical key
position, so they keep working on every layout above — on every desktop.

TildaZ could do the same for Hyprland, but its hotkeys are written from the
launcher, before any keyboard exists, so there is no keymap to ask which physical
key types your hotkey. sway is different only because TildaZ registers there from
inside the running terminal, after the keymap has arrived.

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
  ignores clicks. Alt+click splits the active pane instead (see
  [Split panes](#split-panes)).
- `…` opens the command menu. It lists the common tab, split-pane (*Split Right* /
  *Split Down*), clipboard, fullscreen, config, shortcut-reference, and About actions
  together with their shortcuts.
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

## Split panes

A tab can hold up to 16 panes (`pane_layout.MAX_PANES_PER_TAB`, independent of the
32-tab limit), each a full terminal with its own shell. Splitting puts the new pane on
the side you name: Ctrl+Shift+→ opens a new shell to the right of the active pane and
gives it half of the space (the split falls on a cell boundary of the left pane; the
leftover pixels go to the right one). Focus follows the arrow keys with Alt (Cmd on
macOS): the pane that is geometrically next in that direction takes the keyboard,
measured from the cursor's row or column, so in a three-pane layout you land on the
neighbour the cursor is actually facing. Shift+Alt+arrows move the split line touching
the active pane by one cell; Shift+Alt+0 makes every pane in the tab the same size
(a split between one pane and two stacked panes becomes 1/3 : 2/3, like tmux's
`select-layout even-*`).

The active pane is marked by an amber line along the edges it shares with other panes
(never along the window edge); inactive panes are not dimmed, so all of them stay
readable. Ctrl+Shift+Z zooms the active pane to the whole tab (the other panes keep
running but are not drawn); pressing it again, or splitting, moving focus, or
resizing, restores the layout. Clicking a pane focuses it and starts a selection
there in one click; right-clicking an *inactive* pane only focuses it and does not
paste. Dragging the gray line between two panes moves the split: while you drag, an
amber ghost shows where the line will land (snapped to a cell boundary), and the
panes are resized once, when you release. The `…` menu has *Split Right* and *Split
Down*, and Alt+clicking the `+` button splits the active pane instead of opening a
tab (to the right if the pane is wider than it is tall, otherwise below). Ctrl+Shift+W
closes the active pane — the neighbour that shared the split takes its place — and
closes the tab when the pane is the last one; a shell exiting inside a pane does the
same. A split that would leave any pane smaller than 20×5 cells is refused with a
dialog, as is the 17th pane.

**Status:** implemented on all three platforms ([#483](https://github.com/ensky0/tildaz/issues/483));
Linux and macOS are verified, the Windows build is awaiting hands-on verification.

## Tab limit

`session_core.MAX_TABS = 32` on all platforms. The `+` button hides automatically at 32 tabs and reappears when one closes. Triggering new-tab via Cmd+T / Ctrl+Shift+T while at the limit shows a "Tab limit reached" dialog so the constraint isn't silently ignored when the visual cue is offscreen.

## Mouse

| Action | All platforms |
|--------|---------------|
| Drag-select text | Auto-copy on release |
| Double-click word | Word selection + auto-copy. Boundary chars: space / tab / `" \` \| : ; ( ) [ ] { } < >`. Wide chars (Hangul / CJK) treated as word body. |
| Mouse wheel | Scroll the pane under the pointer (focus stays where it is; page keys scroll the active pane) |
| Right-click | Paste from clipboard (on the active pane; an inactive pane is only focused) |
| Click an inactive pane | Focus that pane and start selecting there |
| Drag the line between two panes | Move the split (amber ghost while dragging, applied on release) |
| Click `…` | Open the command menu and shortcut hints |
| Scrollbar click / drag | Jump or follow viewport |
