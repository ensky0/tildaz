# Configuration

Config file path (per OS standard):

| OS | Path |
|---|---|
| Linux | `~/.config/tildaz/config_N.toml` (XDG) |
| macOS | `~/.config/tildaz/config_N.toml` (XDG, Ghostty / Alacritty pattern) |
| Windows | `%APPDATA%\tildaz\config_N.toml` |

The first launch creates `config_0.toml` with defaults. Launching TildaZ while
all configured instances are already running shows the resulting instance count
and a hotkey capture dialog before writing the next numbered file. Press the
desired key combination; **Create** remains disabled until a valid, unused
hotkey is captured. Each `config_N.toml` owns one TildaZ process. A legacy
`config.json` is not loaded, converted, or deleted. Neither is a `config_N.json` left over from before TildaZ used TOML — it stays on disk, unread. Linux and macOS insert the
user's `$SHELL` env (or
`/bin/bash`) into newly created configs.

**N runs from 0 to 9 — ten instances.** Each one gets its own default hotkey: a
config TildaZ generates for instance N uses `F(N+1)`, so instance 0 defaults to
`F1`, instance 1 to `F2`, and instance 9 to `F10`. Numbering that way means two
instances never open with the same hotkey, which is what the operating system
needs — on Windows the second one cannot register its hotkey at all.
`--instance 10` and above are rejected with a message naming the range.

The table stops at `F10` rather than `F12` because Windows does not hand out a
bare `F12` as a global hotkey — it is reserved for the kernel debugger, and
`RegisterHotKey` reports it as already registered. An instance whose default
landed on `F12` could never start from a generated config.

The number is reused, not just incremented: TildaZ fills the **lowest free**
slot, so deleting `config_1.toml` frees both the number and `F2` for the next
instance you create.

Only files TildaZ generates carry these defaults. An existing `config_N.toml` is
read exactly as written, and nothing rewrites its `hotkey`.

> **Strict schema validation** — every key is required, unknown keys are rejected, type mismatches are fatal. The `defaultConfigToml` function in [`src/config.zig`](src/config.zig) is the single source of truth (used both for first-run file creation and for validating user config). Linux, macOS, and Windows apply the same policy.
>
> **Upgrading:** when a newer version adds keys (for example the split-pane actions in `[keys]`), a file written by an older version fails to load with `missing required key …`. The message tells you what to do: move the file aside (add `.bak` to its name), start TildaZ to get a fresh default file, then copy back the values you had changed. TildaZ never edits your file for you.
>
> **Comments** — TOML has real comments: anything after `#` on a line is ignored, either on its own line or after a value. Use them to annotate your config.
>
> Note that commenting a field **out** is not the same as leaving it at its default: every field listed in the table above is required, so removing one is an error rather than a fallback. To go back to a default, set the value explicitly.

## Examples

Every field below is required, so a real config also carries the `[keys]`
table -- see [Keyboard shortcuts](#keyboard-shortcuts). The examples omit it
only to stay readable; TildaZ writes the whole file for you on first launch.

These show `config_0.toml`, so `hotkey` reads `"F1"`. In `config_1.toml` that
line is `"F2"`, and so on up to `"F10"` — everything else is the same.

### Linux

```toml
hotkey           = "F1"

shell            = "/bin/bash"

auto_start       = true
hidden_start     = false

theme            = "Tilda"
max_scroll_lines = 10000

[window]
dock_position   = "top"   # top | bottom | left | right
width_percent   = 50.0
height_percent  = 100.0
offset_percent  = 100.0
opacity_percent = 100.0

[font]
family            = "DejaVu Sans Mono"
glyph_fallback    = ["Noto Sans CJK KR", "Noto Color Emoji"]
size_point        = 15
cell_width_ratio  = 1.0
line_height_ratio = 1.1

[input]
macos_option_as_alt = "none"   # none | both | left | right -- macOS only
```

### macOS

```toml
hotkey           = "F1"

shell            = "/bin/zsh"

auto_start       = true
hidden_start     = false

theme            = "Tilda"
max_scroll_lines = 10000

[window]
dock_position   = "top"   # top | bottom | left | right
width_percent   = 50.0
height_percent  = 100.0
offset_percent  = 100.0
opacity_percent = 100.0

[font]
family            = "Menlo"
glyph_fallback    = ["Apple SD Gothic Neo", "Apple Color Emoji", "Apple Symbols"]
size_point        = 15
cell_width_ratio  = 1.0
line_height_ratio = 1.1

[input]
macos_option_as_alt = "none"   # none | both | left | right -- macOS only
```

### Windows

```toml
hotkey           = "F1"

shell            = "cmd.exe"

auto_start       = true
hidden_start     = false

theme            = "Tilda"
max_scroll_lines = 10000

[window]
dock_position   = "top"   # top | bottom | left | right
width_percent   = 50.0
height_percent  = 100.0
offset_percent  = 100.0
opacity_percent = 100.0

[font]
family            = "Cascadia Code"
glyph_fallback    = ["Malgun Gothic", "Segoe UI Emoji", "Segoe UI Symbol"]
size_point        = 15
cell_width_ratio  = 1.0
line_height_ratio = 1.1

[input]
macos_option_as_alt = "none"   # none | both | left | right -- macOS only
```

## Field reference

Every numeric field name carries its unit (`_percent`, `_point`, `_ratio`). String / boolean fields are self-evident.

| Key | Type | Range | Linux default | macOS default | Windows default | Description |
|-----|------|-------|---------------|---------------|-----------------|-------------|
| `window.dock_position` | string | top / bottom / left / right | "top" | "top" | "top" | Edge to dock to |
| `window.width_percent` | float | 1.0–100.0 | 50.0 | 50.0 | 50.0 | Width as % of screen — fractional values OK (e.g. 33.3) |
| `window.height_percent` | float | 1.0–100.0 | 100.0 | 100.0 | 100.0 | Height as % of screen |
| `window.offset_percent` | float | 0.0–100.0 | 100.0 | 100.0 | 100.0 | Position along edge (0 = start, 50 = center, 100 = end) |
| `window.opacity_percent` | float | 0.0–100.0 | 100.0 | 100.0 | 100.0 | Window opacity (%) — internally converted to 0–255 alpha |
| `font.family` | string | — | "DejaVu Sans Mono" | "Menlo" | "Cascadia Code" | Primary font. Must be installed on the system; missing → fatal |
| `font.glyph_fallback` | string[] | max 7 entries (chain total ≤ 8 with `family`) | `["Noto Sans CJK KR", "Noto Color Emoji"]` | `["Apple SD Gothic Neo", "Apple Color Emoji", "Apple Symbols"]` | `["Malgun Gothic", "Segoe UI Emoji", "Segoe UI Symbol"]` | Glyph fallback chain. Codepoints not in `family` are looked up in this order; misses fall through to the OS system font. **All listed entries must be installed.** Empty array `[]` is allowed (system fallback only) |
| `font.size_point` | int | 8–72 | 15 | 15 | 15 | Logical font size (host applies the OS scale; the legacy key name does not mean a physical 1/72-inch point) |
| `font.cell_width_ratio` | float | 0.5–2.0 | 1.0 | 1.0 | 1.0 | Cell-width multiplier (1.0 = font's own advance) |
| `font.line_height_ratio` | float | 0.5–2.0 | 1.1 | 1.1 | 1.1 | Line-height multiplier (1.0 = font's own ascent + descent + leading) |
| `input.macos_option_as_alt` | string | none / both / left / right | "none" | "none" | "none" | **macOS only** — whether Option acts as Alt. On macOS the OS turns `Option+a` into a character (`å` on ABC, `ê` on French), so one key press has two meanings and you pick one: `none` types the character (the macOS default), `both` makes Option act as Alt so `Alt+n` reaches zellij, tmux and emacs, `left` / `right` pick one side and leave the other typing characters. The key exists on all three platforms so a single config file stays portable, but Linux and Windows read it without using it — there Alt is always Meta, because `Alt+a` produces no character |
| `theme` | string | see Built-in themes below | "Tilda" | "Tilda" | "Tilda" | Color theme |
| `shell` | string | — | `$SHELL` env (or `/bin/bash`) | `$SHELL` env (or `/bin/bash`) | "cmd.exe" | Shell to spawn. A new tab starts in the **active tab's current directory**, falling back to your home directory when that location can't be determined or entered (see "New tab working directory" below). WSL tabs use *Linux* paths — TildaZ passes `--cd` to `wsl.exe` automatically, skipped if your command already has `--cd`. Windows accepts arguments — e.g. `"wsl.exe -d Debian"` — so the first space ends the executable path; a path that itself contains spaces has to be quoted inside the value, as in `shell = "\"C:\\Program Files\\Git\\bin\\bash.exe\""`. macOS / Linux expect an absolute binary path; for argv beyond the binary, configure your shell via `~/.zshrc`, `~/.bashrc`, etc. |
| `hotkey` | string | "F1", "Ctrl+Space", "Shift+Cmd+T", … | `F(N+1)` | `F(N+1)` | `F(N+1)` | Global toggle hotkey. Generated configs derive the default from the instance number — `F1` for instance 0, `F2` for 1, up to `F10` for 9. `cmd` token = Win key on Windows / Cmd on macOS / Super on Linux |
| `auto_start` | bool | — | true | true | true | Start on login (Registry Run on Windows, LaunchAgent on macOS, XDG autostart `.desktop` on Linux) |
| `hidden_start` | bool | — | false | false | false | Start hidden (first toggle reveals) |
| `max_scroll_lines` | int | 100–10,000,000 | 10,000 | 10,000 | 10,000 | Scrollback buffer (lines) |

### Font names

Every family in `font.family` and `font.glyph_fallback` must be installed. The spelling is forgiving —
case, spaces, hyphens and underscores are ignored, so `Cascadia Code`, `cascadia code` and
`CascadiaCode` all name the same font. A name that matches no installed font is fatal at startup, so
it is worth checking before editing the config.

The **PostScript name** works too, on all three platforms — the `NotoSansCJKkr-Regular` /
`CascadiaCodeRoman-Bold` form that font tools such as Font Book show. A PostScript name identifies
one face rather than a family, so a bold PostScript name loads the bold face; bold and italic still
come from the family that face belongs to, so `SGR 1` / `SGR 3` keep working either way.

**List the installed family names:**

```sh
# Linux
fc-list : family | tr ',' '\n' | sort -u

# macOS
system_profiler SPFontsDataType | grep "Family:" | sort -u
```

```powershell
# Windows
[Reflection.Assembly]::LoadWithPartialName("System.Drawing")
(New-Object System.Drawing.Text.InstalledFontCollection).Families | Select-Object -Expand Name
```

**List the PostScript names** — there are more of these than families, because each face has its
own:

```sh
# Linux
fc-list -f '%{postscriptname}\n' | grep . | sort -u

# macOS — Font Book shows it in the font's info panel (⌘I)
```

Windows has no built-in way to list them, and you never need one there: the family name is always
accepted, so a PostScript name only has to work for configs written elsewhere. Do not try to guess
one either — a font's PostScript names need not follow its display name. Cascadia Code is
`CascadiaCodeRoman` for Regular but `Cascadia-Code-Italic` for Italic, and `CascadiaCode-Regular`,
the spelling the pattern suggests, is not a name that font has at all.

**Then confirm the name actually resolves to that font** — this second step matters more than it
looks:

```sh
fc-match "Noto Color Emoji"          # Linux
#   Noto Color Emoji  → correct
#   twemoji.ttf       → the system redirects this name, see below
```

#### When the system hands you a different font

A font can be installed and still bring up a *different* one, because the system resolves that name
elsewhere. On Linux this is a fontconfig alias rule: an emoji font package (`ttf-twemoji`,
`ttf-joypixels`, …) claims the emoji names system-wide, usually from a file in `/etc/fonts/conf.d/`.

TildaZ starts anyway — the font it got is real, and the redirection is the system's own rule — and
records what happened in the log (`tildaz_N.log`):

```
[font] chain[2] "Noto Color Emoji" resolved to "Twemoji" (system alias) — using it
```

So when a glyph does not look like the font you picked, read the log first. To get the font you
asked for, either name the substitute directly, or drop the rule:

```sh
sudo rm /etc/fonts/conf.d/75-twemoji.conf && fc-cache -f
```

Startup only fails when the name matches **no** installed font at all — a typo, or a font that is
not installed.

### Keyboard shortcuts

The `[keys]` table binds an action to one or more key combinations. Every action
appears in the file, so you can see the whole set without consulting the docs.

```toml
[keys]
new_tab   = ["ctrl+shift+t"]
prev_tab  = ["ctrl+shift+[", "ctrl+pageup"]
close_tab = ["ctrl+shift+[KeyW]"]
quit      = []
```

- **A list, not a single value** — an action can have several keys.
- **An empty list unbinds the action.** That is the only way to express "no
  key"; the entry itself always stays in the file.
- **Every key may trigger only one action.** Binding the same combination twice
  is an error at startup, and the message names both actions.
- **The defaults are not the same on every OS.** macOS follows Apple's
  convention (`Cmd+T`, `Shift+Cmd+[`), Linux and Windows use `Ctrl+Shift+T`.
  A modifier swap is not enough to express that, so the two default tables are
  separate. See KEYBINDINGS.md for the full list.
- `cmd` resolves per platform (Super on Linux, Win on Windows, Command on
  macOS), so a combination you write yourself works on all three.

#### Two ways to name a key

```toml
close_tab = ["ctrl+shift+w"]         # by label   -- the letter printed on the key
close_tab = ["ctrl+shift+[KeyW]"]    # by position -- the physical spot, any layout
```

**A label is what the key types.** It is the natural way to write a shortcut and
it is what the defaults use. It only works if your layout can actually produce
that character: on a Cyrillic or Greek layout no key produces `w`, so
`ctrl+shift+w` can never fire.

**A position is a physical spot on the keyboard**, independent of layout. The
names are [W3C `KeyboardEvent.code` values][w3c] — the same vocabulary browsers
use, and the same notation VS Code uses in its keybindings. `[KeyW]` means "the
key where a US QWERTY keyboard has `w`", whatever that key prints on your
layout.

[w3c]: https://www.w3.org/TR/uievents-code/

Use a position when a label cannot reach the key you want:

| Situation | Why the label fails | Position form |
|---|---|---|
| Cyrillic, Greek, Arabic, Hebrew… | no key produces a Latin letter — but see below, TildaZ already handles this on Linux and macOS | `ctrl+shift+[KeyW]` |
| French AZERTY brackets | `[` is AltGr+5, so the label needs four fingers | `ctrl+shift+[BracketLeft]` |
| Keys outside the label set | `-` `=` `\` `;` `'` `,` `.` `/`, numpad, arrows | `ctrl+[Minus]` |

Positions and labels can be mixed freely, including within one action's list.

**On Linux and macOS you usually do not need the position form for non-Latin
layouts.** TildaZ checks whether the layout you are currently typing in can
produce each binding's label at all; if nothing can, it falls back to the
physical spot that character has on a US keyboard. So the defaults work on a
Cyrillic layout — or a Korean, Japanese, or Chinese input source — untouched.
The check follows the live layout, so a `us,ru` setup matches by label while you
are on `us` and falls back the moment you switch to `ru`. KEYBINDINGS.md has the
details.

**Windows does not need it either**, for a different reason: a non-Latin layout
DLL assigns Latin virtual-keys to the physical spots, so the OS has already done
the equivalent work.

#### Accepted keys

**By label**: `F1`–`F12`, `A`–`Z`, `0`–`9`, `Space`, `Tab`, `Escape` (`Esc`),
`Return` (`Enter`), `PageUp` (`PgUp`), `PageDown` (`PgDn`), `Left` / `Right` /
`Up` / `Down` (the arrow keys — the split-pane defaults use them), `` ` `` (also
`Grave` / `Backquote`), `[` (also `BracketLeft`), `]` (also `BracketRight`).
Case does not matter. Anything else is an error at startup — including
layout-specific characters such as `²` on French AZERTY.

The label set is deliberately narrow. Widening it would mean giving `-` a value,
and the only fixed values available (`VK_OEM_MINUS`, `kVK_ANSI_Minus`) are not
labels at all — they are "the spot where US QWERTY has `-`". Calling that a
label would make the same config mean different keys on different platforms.
Positions are honest about being positions, so that is where the extra keys
live.

**By position**: every key a keyboard can send, in square brackets.

| Group | Names |
|---|---|
| Function | `[F1]`–`[F24]` |
| Letters | `[KeyA]`–`[KeyZ]` |
| Digit row | `[Digit0]`–`[Digit9]` |
| Symbols | `[Backquote]` `[Minus]` `[Equal]` `[BracketLeft]` `[BracketRight]` `[Backslash]` `[Semicolon]` `[Quote]` `[Comma]` `[Period]` `[Slash]` |
| Non-US keys | `[IntlBackslash]` (the extra key on ISO keyboards — `<>` on AZERTY), `[IntlYen]`, `[IntlRo]` |
| Editing | `[Space]` `[Tab]` `[Escape]` `[Enter]` `[Backspace]` `[Insert]` `[Delete]` `[Home]` `[End]` `[PageUp]` `[PageDown]` |
| Arrows | `[ArrowUp]` `[ArrowDown]` `[ArrowLeft]` `[ArrowRight]` |
| Numpad | `[NumLock]` `[Numpad0]`–`[Numpad9]` `[NumpadDivide]` `[NumpadMultiply]` `[NumpadSubtract]` `[NumpadAdd]` `[NumpadEnter]` `[NumpadDecimal]` `[NumpadEqual]` |
| Other | `[CapsLock]` `[PrintScreen]` `[ScrollLock]` `[Pause]` `[ContextMenu]` `[Lang1]` `[Lang2]` `[Convert]` `[NonConvert]` `[KanaMode]` |

Modifier keys themselves (`[ShiftLeft]`, `[ControlLeft]`, …) are not accepted:
in this syntax a modifier is a prefix, not a key.

**A few positions do not exist on macOS.** `[PrintScreen]`, `[ScrollLock]` and
`[Pause]` arrive there as `[F13]`, `[F14]` and `[F15]` — Apple's extended
keyboard puts those function keys in the same spots, so use those names instead.
`[F21]`–`[F24]`, `[Convert]`, `[NonConvert]` and `[KanaMode]` have no macOS
equivalent at all. TildaZ reports this at startup rather than leaving the
binding quietly dead, and only on macOS: the same config is fine on Linux and
Windows.

#### Modifiers

`Ctrl`, `Alt` (also `Option` / `Opt`), `Shift`, and the platform key written as
`Cmd` (also `Command` / `Super` / `Win` / `Meta` / `Logo`).

**A key that types text needs `Ctrl`, `Alt`, or `Cmd`** — binding it with no
modifier, or with `Shift` alone, would make that character impossible to type in
the terminal. Keys that type nothing may be bound bare: `F1`–`F24`, `PageUp`,
`PageDown`, `Escape`, `NumLock`, `CapsLock`. Arrow and editing keys count as
typing keys even though they produce no character, because they send escape
sequences that programs in the terminal expect to receive.

**Digit bindings ignore Shift.** On layouts where the digit row needs Shift —
French AZERTY, where the unshifted row is `&é"'(-è_çà` — `Alt+1` physically
arrives as Alt+Shift+the `&1` key. Without this exception, switching tabs by
index would be dead on those layouts. It applies to digits only: `Shift+Alt+F4`
still does not trigger a binding on `Alt+F4`.

**Bindings that include Shift match the unshifted key.** `Shift+Alt+0` means
"the `0` key with Shift held". On a US layout that key produces `)` while Shift
is down, so the binding also matches the character the same key produces without
Shift — `Shift+Alt+0`, `Shift+Cmd+0`, `Shift+Cmd+[` work on every layout. The
reverse never happens: a binding without Shift (`Alt+1`) does not fire on
Alt+Shift+1, apart from the digit rule above.

#### Two things are not in `[keys]`

**Scrolling.** `Shift+PgUp` / `Shift+PgDn` scroll the scrollback, and scrolling
is not a shortcut — it is the same action as the mouse wheel, driven from the
keyboard. TildaZ does not let you rebind the wheel either. Those two
combinations are fixed.

**`Ctrl+C`.** It sends SIGINT to the program in the terminal. Letting a config
file shadow it would mean one typo costs you the ability to interrupt a command.

The global `hotkey` is separate for a different reason: it is registered with the
operating system rather than handled inside TildaZ, so it lives at the top level
and takes a single value. It accepts both forms, but a function key is still the
safest choice there, being identical on every layout.

## Hotkey syntax

`hotkey` accepts a single key optionally combined with modifiers, joined by `+`
(e.g. `"F1"`, `"Ctrl+Space"`, `"Shift+Cmd+T"`). Rules (validated at startup — an
invalid value shows an error dialog and exits):

- **Modifiers**: `Ctrl`, `Alt`, `Shift`, and the platform key written as `Cmd`
  (Win key on Windows / Command on macOS / Super on Linux). The `cmd` token maps
  to each platform's equivalent, so one config value works everywhere.
- **A modifier-free hotkey must be a function key** (`F1`–`F12`). A plain letter,
  digit, or `Space` with no modifier is rejected.
- **`Shift` alone is not a valid trigger modifier** — combine it with
  `Ctrl` / `Alt` / `Cmd` (e.g. `Shift+Cmd+T` is fine, `Shift+T` is not).
- **Accepted keys**, in full: `F1`–`F12`, `A`–`Z`, `0`–`9`, `Space`, `Tab`,
  `Escape` (`Esc`), `Return` (`Enter`), `PageUp` (`PgUp`), `PageDown` (`PgDn`),
  `` ` `` (also `Grave` / `Backquote`), `[` (also `BracketLeft`), and `]` (also
  `BracketRight`). Letter case does not matter.
- **Any other key is rejected**, and that includes layout-specific keys such as
  `²` (`twosuperior`) on French AZERTY. The accepted set is deliberately narrow:
  it is the set every platform's native hotkey backend is known to map the same
  way. Widening it means verifying real key codes on Linux, macOS, and Windows,
  which has not been done yet. A rejected value shows an error dialog naming the
  accepted keys rather than failing silently.
- **The position form works here too**, with one caveat below. TildaZ registers
  the hotkey with your desktop, and the desktops differ in what they accept.
  sway, Hyprland, GNOME and Cinnamon take a key position directly. COSMIC and KDE
  take only a character, so TildaZ registers **whatever that position types on
  your current layout** — on a French layout `"ctrl+[Backquote]"` becomes `Ctrl+²`.
  It re-registers when you switch layouts while TildaZ is running.
- **The caveat is dead keys.** If the position you picked is a dead key on your
  layout — the `[Backquote]` spot is `dead_circumflex` on a German layout — COSMIC
  and KDE cannot express it, and TildaZ logs that instead of registering something
  that would fire the wrong key. The other desktops are unaffected, because they
  take the position itself.
- **On COSMIC the entry appears once TildaZ has run.** Resolving a position to a
  character needs the keyboard layout, which only the running terminal knows, so
  the shortcut is written on first launch rather than by the installer.

#### Prefer a function key

`F1`–`F12` are the same on every keyboard layout, which is why the generated
defaults are function keys — `F(N+1)` for instance N. Letters and punctuation are
not, and the failure is quiet.

One exception: **on Windows a bare `F12` is not available.** Windows keeps it for
the kernel debugger, so TildaZ cannot claim it and stops at startup with a
message. `Ctrl+Alt+F12` and other combinations that include a modifier work
normally.

Letters are usually fine: GNOME, Cinnamon, COSMIC and KDE all translate a
Latin-letter shortcut back to the key you actually pressed on a Cyrillic or Greek
layout, and on sway TildaZ registers the hotkey by physical key position so the
same thing happens. **Hyprland is the exception** — a letter hotkey can stop
working there while a non-Latin layout is active.

**Punctuation is the riskier choice**, and not only on non-Latin layouts. German
and Spanish cannot type `` ` `` at all — the key in that position is a dead accent
— so a ``Ctrl+` `` hotkey is silently dead there. GNOME's fallback does not rescue
it either, because that fallback only triggers when the layout is missing the
Latin *alphabet*.

KEYBINDINGS.md has a measured table of which layouts can type which keys, and the
sway / Hyprland limitation it matters most for.

### New tab working directory

A new tab starts in the **active tab's current directory**. When that location
can't be determined or entered, it falls back to your **home directory**. There is
no config switch — to start clean, run `cd ~` in the new tab.

TildaZ finds the location in two ways, in order:

1. **The shell tells us** via the `OSC 7` escape sequence. Shells that already do
   this need no setup (fish, and bash/zsh with a prompt hook installed).
2. **We ask the OS** for the shell process's working directory. This works on
   Linux and macOS regardless of which shell you use, so **no shell configuration
   is required there**.

On **Windows** the second way is not possible (PowerShell keeps its location
per-runspace, and the `cmd`-only alternative relies on an undocumented API), so
TildaZ makes the shell report instead:

| Shell | What TildaZ sets |
|---|---|
| `cmd` | Prepends a reporting fragment to the `PROMPT` environment variable. Your existing prompt is preserved — it is only added in front, so `echo %PROMPT%` shows the extra fragment |
| PowerShell / pwsh | Appends `-NoExit -EncodedCommand …` to the command line, which wraps the existing `prompt` function **after your profile loads**. Custom prompts (oh-my-posh, Starship, …) keep working. Skipped if your `shell` value already passes `-Command`, `-EncodedCommand`, or `-File` |
| WSL (bash) | Passes `PROMPT_COMMAND` through `WSLENV` |
| WSL (fish) | Nothing — fish reports on its own |

Combinations that fall back to the home directory:

| Situation | Why |
|---|---|
| Inside **tmux** | tmux absorbs the escape sequence, so the new tab opens where the shell was **before** tmux started. Other terminals share this limitation; use tmux's own `#{pane_current_path}` for tmux windows |
| **zsh inside WSL** | Requires placing a file inside the WSL filesystem, which TildaZ does not do |
| **Over ssh** | The remote host name doesn't match this machine, so the remote path is ignored (it wouldn't exist locally) |
| The directory was deleted, or isn't a directory | Checked before spawning |
| A shell whose prompt hook was overwritten by your rc file | For bash, assigning `PROMPT_COMMAND=` in `.bashrc` replaces what TildaZ passed in |

**Ligatures** require a ligature-capable `font.family` (e.g. Fira Code or
JetBrains Mono — both free). The Windows default (Cascadia Code) includes them;
the macOS (Menlo) and Linux (DejaVu Sans Mono) defaults do not, so point
`font.family` at a ligature font to enable them. Color emoji and ZWJ families
(skin tones, multi-person families) come from the emoji fallback (Segoe UI Emoji
/ Apple Color Emoji / Noto Color Emoji) and work with the defaults.

## Position examples

```
"window": { "dock_position": "top", "width_percent": 100.0, "height_percent": 40.0, "offset_percent": 0.0 }
 -> top of screen, full width, 40% height, flush to the left edge

"window": { "dock_position": "top", "width_percent": 60.0, "height_percent": 40.0, "offset_percent": 50.0 }
 -> top of screen, 60% width, 40% height, centered horizontally

"window": { "dock_position": "top", "width_percent": 50.0, "height_percent": 100.0, "offset_percent": 100.0 }
 -> top of screen, 50% width, full height, flush to the right edge

"window": { "dock_position": "left", "width_percent": 33.3, "height_percent": 80.0, "offset_percent": 50.0 }
 -> left side of screen, ~one third width, 80% height, vertically centered (fractional percent demonstrating fine adjustment)
```

## Built-in themes

Set `"theme"` to one of the names below. If no theme is set, the Tilda palette is used.

### Classic

| Theme | Background | Foreground | Palette (ANSI 0–15) |
|-------|------------|------------|---------------------|
| Tilda | ![](https://placehold.co/16x16/000000/000000) `#000000` | ![](https://placehold.co/16x16/ffffff/ffffff) `#FFFFFF` | ![](https://placehold.co/14x14/2e3436/2e3436) ![](https://placehold.co/14x14/cc0000/cc0000) ![](https://placehold.co/14x14/4e9a06/4e9a06) ![](https://placehold.co/14x14/c4a000/c4a000) ![](https://placehold.co/14x14/3465a4/3465a4) ![](https://placehold.co/14x14/75507b/75507b) ![](https://placehold.co/14x14/06989a/06989a) ![](https://placehold.co/14x14/d3d7cf/d3d7cf) ![](https://placehold.co/14x14/555753/555753) ![](https://placehold.co/14x14/ef2929/ef2929) ![](https://placehold.co/14x14/8ae234/8ae234) ![](https://placehold.co/14x14/fce94f/fce94f) ![](https://placehold.co/14x14/729fcf/729fcf) ![](https://placehold.co/14x14/ad7fa8/ad7fa8) ![](https://placehold.co/14x14/34e2e2/34e2e2) ![](https://placehold.co/14x14/eeeeec/eeeeec) |
| Ghostty | ![](https://placehold.co/16x16/1d1f21/1d1f21) `#1D1F21` | ![](https://placehold.co/16x16/c5c8c6/c5c8c6) `#C5C8C6` | ![](https://placehold.co/14x14/1d1f21/1d1f21) ![](https://placehold.co/14x14/cc6666/cc6666) ![](https://placehold.co/14x14/b5bd68/b5bd68) ![](https://placehold.co/14x14/f0c674/f0c674) ![](https://placehold.co/14x14/81a2be/81a2be) ![](https://placehold.co/14x14/b294bb/b294bb) ![](https://placehold.co/14x14/8abeb7/8abeb7) ![](https://placehold.co/14x14/c5c8c6/c5c8c6) ![](https://placehold.co/14x14/666666/666666) ![](https://placehold.co/14x14/d54e53/d54e53) ![](https://placehold.co/14x14/b9ca4a/b9ca4a) ![](https://placehold.co/14x14/e7c547/e7c547) ![](https://placehold.co/14x14/7aa6da/7aa6da) ![](https://placehold.co/14x14/c397d8/c397d8) ![](https://placehold.co/14x14/70c0b1/70c0b1) ![](https://placehold.co/14x14/eaeaea/eaeaea) |
| Windows Terminal | ![](https://placehold.co/16x16/0c0c0c/0c0c0c) `#0C0C0C` | ![](https://placehold.co/16x16/cccccc/cccccc) `#CCCCCC` | ![](https://placehold.co/14x14/0c0c0c/0c0c0c) ![](https://placehold.co/14x14/c50f1f/c50f1f) ![](https://placehold.co/14x14/13a10e/13a10e) ![](https://placehold.co/14x14/c19c00/c19c00) ![](https://placehold.co/14x14/0037da/0037da) ![](https://placehold.co/14x14/881798/881798) ![](https://placehold.co/14x14/3a96dd/3a96dd) ![](https://placehold.co/14x14/cccccc/cccccc) ![](https://placehold.co/14x14/767676/767676) ![](https://placehold.co/14x14/e74856/e74856) ![](https://placehold.co/14x14/16c60c/16c60c) ![](https://placehold.co/14x14/f9f1a5/f9f1a5) ![](https://placehold.co/14x14/3b78ff/3b78ff) ![](https://placehold.co/14x14/b4009e/b4009e) ![](https://placehold.co/14x14/61d6d6/61d6d6) ![](https://placehold.co/14x14/f2f2f2/f2f2f2) |

### Dark

| Theme | Background | Foreground | Palette (ANSI 0–15) |
|-------|------------|------------|---------------------|
| Catppuccin Mocha | ![](https://placehold.co/16x16/1e1e2e/1e1e2e) `#1E1E2E` | ![](https://placehold.co/16x16/cdd6f4/cdd6f4) `#CDD6F4` | ![](https://placehold.co/14x14/45475a/45475a) ![](https://placehold.co/14x14/f38ba8/f38ba8) ![](https://placehold.co/14x14/a6e3a1/a6e3a1) ![](https://placehold.co/14x14/f9e2af/f9e2af) ![](https://placehold.co/14x14/89b4fa/89b4fa) ![](https://placehold.co/14x14/f5c2e7/f5c2e7) ![](https://placehold.co/14x14/94e2d5/94e2d5) ![](https://placehold.co/14x14/a6adc8/a6adc8) ![](https://placehold.co/14x14/585b70/585b70) ![](https://placehold.co/14x14/f37799/f37799) ![](https://placehold.co/14x14/89d88b/89d88b) ![](https://placehold.co/14x14/ebd391/ebd391) ![](https://placehold.co/14x14/74a8fc/74a8fc) ![](https://placehold.co/14x14/f2aede/f2aede) ![](https://placehold.co/14x14/6bd7ca/6bd7ca) ![](https://placehold.co/14x14/bac2de/bac2de) |
| Dracula | ![](https://placehold.co/16x16/282a36/282a36) `#282A36` | ![](https://placehold.co/16x16/f8f8f2/f8f8f2) `#F8F8F2` | ![](https://placehold.co/14x14/21222c/21222c) ![](https://placehold.co/14x14/ff5555/ff5555) ![](https://placehold.co/14x14/50fa7b/50fa7b) ![](https://placehold.co/14x14/f1fa8c/f1fa8c) ![](https://placehold.co/14x14/bd93f9/bd93f9) ![](https://placehold.co/14x14/ff79c6/ff79c6) ![](https://placehold.co/14x14/8be9fd/8be9fd) ![](https://placehold.co/14x14/f8f8f2/f8f8f2) ![](https://placehold.co/14x14/6272a4/6272a4) ![](https://placehold.co/14x14/ff6e6e/ff6e6e) ![](https://placehold.co/14x14/69ff94/69ff94) ![](https://placehold.co/14x14/ffffa5/ffffa5) ![](https://placehold.co/14x14/d6acff/d6acff) ![](https://placehold.co/14x14/ff92df/ff92df) ![](https://placehold.co/14x14/a4ffff/a4ffff) ![](https://placehold.co/14x14/ffffff/ffffff) |
| Gruvbox Dark | ![](https://placehold.co/16x16/282828/282828) `#282828` | ![](https://placehold.co/16x16/ebdbb2/ebdbb2) `#EBDBB2` | ![](https://placehold.co/14x14/282828/282828) ![](https://placehold.co/14x14/cc241d/cc241d) ![](https://placehold.co/14x14/98971a/98971a) ![](https://placehold.co/14x14/d79921/d79921) ![](https://placehold.co/14x14/458588/458588) ![](https://placehold.co/14x14/b16286/b16286) ![](https://placehold.co/14x14/689d6a/689d6a) ![](https://placehold.co/14x14/a89984/a89984) ![](https://placehold.co/14x14/928374/928374) ![](https://placehold.co/14x14/fb4934/fb4934) ![](https://placehold.co/14x14/b8bb26/b8bb26) ![](https://placehold.co/14x14/fabd2f/fabd2f) ![](https://placehold.co/14x14/83a598/83a598) ![](https://placehold.co/14x14/d3869b/d3869b) ![](https://placehold.co/14x14/8ec07c/8ec07c) ![](https://placehold.co/14x14/ebdbb2/ebdbb2) |
| Tokyo Night | ![](https://placehold.co/16x16/1a1b26/1a1b26) `#1A1B26` | ![](https://placehold.co/16x16/c0caf5/c0caf5) `#C0CAF5` | ![](https://placehold.co/14x14/15161e/15161e) ![](https://placehold.co/14x14/f7768e/f7768e) ![](https://placehold.co/14x14/9ece6a/9ece6a) ![](https://placehold.co/14x14/e0af68/e0af68) ![](https://placehold.co/14x14/7aa2f7/7aa2f7) ![](https://placehold.co/14x14/bb9af7/bb9af7) ![](https://placehold.co/14x14/7dcfff/7dcfff) ![](https://placehold.co/14x14/a9b1d6/a9b1d6) ![](https://placehold.co/14x14/414868/414868) ![](https://placehold.co/14x14/f7768e/f7768e) ![](https://placehold.co/14x14/9ece6a/9ece6a) ![](https://placehold.co/14x14/e0af68/e0af68) ![](https://placehold.co/14x14/7aa2f7/7aa2f7) ![](https://placehold.co/14x14/bb9af7/bb9af7) ![](https://placehold.co/14x14/7dcfff/7dcfff) ![](https://placehold.co/14x14/c0caf5/c0caf5) |
| Nord | ![](https://placehold.co/16x16/2e3440/2e3440) `#2E3440` | ![](https://placehold.co/16x16/d8dee9/d8dee9) `#D8DEE9` | ![](https://placehold.co/14x14/3b4252/3b4252) ![](https://placehold.co/14x14/bf616a/bf616a) ![](https://placehold.co/14x14/a3be8c/a3be8c) ![](https://placehold.co/14x14/ebcb8b/ebcb8b) ![](https://placehold.co/14x14/81a1c1/81a1c1) ![](https://placehold.co/14x14/b48ead/b48ead) ![](https://placehold.co/14x14/88c0d0/88c0d0) ![](https://placehold.co/14x14/e5e9f0/e5e9f0) ![](https://placehold.co/14x14/596377/596377) ![](https://placehold.co/14x14/bf616a/bf616a) ![](https://placehold.co/14x14/a3be8c/a3be8c) ![](https://placehold.co/14x14/ebcb8b/ebcb8b) ![](https://placehold.co/14x14/81a1c1/81a1c1) ![](https://placehold.co/14x14/b48ead/b48ead) ![](https://placehold.co/14x14/8fbcbb/8fbcbb) ![](https://placehold.co/14x14/eceff4/eceff4) |
| One Half Dark | ![](https://placehold.co/16x16/282c34/282c34) `#282C34` | ![](https://placehold.co/16x16/dcdfe4/dcdfe4) `#DCDFE4` | ![](https://placehold.co/14x14/282c34/282c34) ![](https://placehold.co/14x14/e06c75/e06c75) ![](https://placehold.co/14x14/98c379/98c379) ![](https://placehold.co/14x14/e5c07b/e5c07b) ![](https://placehold.co/14x14/61afef/61afef) ![](https://placehold.co/14x14/c678dd/c678dd) ![](https://placehold.co/14x14/56b6c2/56b6c2) ![](https://placehold.co/14x14/dcdfe4/dcdfe4) ![](https://placehold.co/14x14/5d677a/5d677a) ![](https://placehold.co/14x14/e06c75/e06c75) ![](https://placehold.co/14x14/98c379/98c379) ![](https://placehold.co/14x14/e5c07b/e5c07b) ![](https://placehold.co/14x14/61afef/61afef) ![](https://placehold.co/14x14/c678dd/c678dd) ![](https://placehold.co/14x14/56b6c2/56b6c2) ![](https://placehold.co/14x14/dcdfe4/dcdfe4) |
| Solarized Dark | ![](https://placehold.co/16x16/001e27/001e27) `#001E27` | ![](https://placehold.co/16x16/9cc2c3/9cc2c3) `#9CC2C3` | ![](https://placehold.co/14x14/002831/002831) ![](https://placehold.co/14x14/d11c24/d11c24) ![](https://placehold.co/14x14/6cbe6c/6cbe6c) ![](https://placehold.co/14x14/a57706/a57706) ![](https://placehold.co/14x14/2176c7/2176c7) ![](https://placehold.co/14x14/c61c6f/c61c6f) ![](https://placehold.co/14x14/259286/259286) ![](https://placehold.co/14x14/eae3cb/eae3cb) ![](https://placehold.co/14x14/006488/006488) ![](https://placehold.co/14x14/f5163b/f5163b) ![](https://placehold.co/14x14/51ef84/51ef84) ![](https://placehold.co/14x14/b27e28/b27e28) ![](https://placehold.co/14x14/178ec8/178ec8) ![](https://placehold.co/14x14/e24d8e/e24d8e) ![](https://placehold.co/14x14/00b39e/00b39e) ![](https://placehold.co/14x14/fcf4dc/fcf4dc) |
| Monokai Soda | ![](https://placehold.co/16x16/1a1a1a/1a1a1a) `#1A1A1A` | ![](https://placehold.co/16x16/c4c5b5/c4c5b5) `#C4C5B5` | ![](https://placehold.co/14x14/1a1a1a/1a1a1a) ![](https://placehold.co/14x14/f4005f/f4005f) ![](https://placehold.co/14x14/98e024/98e024) ![](https://placehold.co/14x14/fa8419/fa8419) ![](https://placehold.co/14x14/9d65ff/9d65ff) ![](https://placehold.co/14x14/f4005f/f4005f) ![](https://placehold.co/14x14/58d1eb/58d1eb) ![](https://placehold.co/14x14/c4c5b5/c4c5b5) ![](https://placehold.co/14x14/625e4c/625e4c) ![](https://placehold.co/14x14/f4005f/f4005f) ![](https://placehold.co/14x14/98e024/98e024) ![](https://placehold.co/14x14/e0d561/e0d561) ![](https://placehold.co/14x14/9d65ff/9d65ff) ![](https://placehold.co/14x14/f4005f/f4005f) ![](https://placehold.co/14x14/58d1eb/58d1eb) ![](https://placehold.co/14x14/f6f6ef/f6f6ef) |
| Rosé Pine | ![](https://placehold.co/16x16/191724/191724) `#191724` | ![](https://placehold.co/16x16/e0def4/e0def4) `#E0DEF4` | ![](https://placehold.co/14x14/26233a/26233a) ![](https://placehold.co/14x14/eb6f92/eb6f92) ![](https://placehold.co/14x14/31748f/31748f) ![](https://placehold.co/14x14/f6c177/f6c177) ![](https://placehold.co/14x14/9ccfd8/9ccfd8) ![](https://placehold.co/14x14/c4a7e7/c4a7e7) ![](https://placehold.co/14x14/ebbcba/ebbcba) ![](https://placehold.co/14x14/e0def4/e0def4) ![](https://placehold.co/14x14/6e6a86/6e6a86) ![](https://placehold.co/14x14/eb6f92/eb6f92) ![](https://placehold.co/14x14/31748f/31748f) ![](https://placehold.co/14x14/f6c177/f6c177) ![](https://placehold.co/14x14/9ccfd8/9ccfd8) ![](https://placehold.co/14x14/c4a7e7/c4a7e7) ![](https://placehold.co/14x14/ebbcba/ebbcba) ![](https://placehold.co/14x14/e0def4/e0def4) |
| Kanagawa | ![](https://placehold.co/16x16/1f1f28/1f1f28) `#1F1F28` | ![](https://placehold.co/16x16/dcd7ba/dcd7ba) `#DCD7BA` | ![](https://placehold.co/14x14/090618/090618) ![](https://placehold.co/14x14/c34043/c34043) ![](https://placehold.co/14x14/76946a/76946a) ![](https://placehold.co/14x14/c0a36e/c0a36e) ![](https://placehold.co/14x14/7e9cd8/7e9cd8) ![](https://placehold.co/14x14/957fb8/957fb8) ![](https://placehold.co/14x14/6a9589/6a9589) ![](https://placehold.co/14x14/c8c093/c8c093) ![](https://placehold.co/14x14/727169/727169) ![](https://placehold.co/14x14/e82424/e82424) ![](https://placehold.co/14x14/98bb6c/98bb6c) ![](https://placehold.co/14x14/e6c384/e6c384) ![](https://placehold.co/14x14/7fb4ca/7fb4ca) ![](https://placehold.co/14x14/938aa9/938aa9) ![](https://placehold.co/14x14/7aa89f/7aa89f) ![](https://placehold.co/14x14/dcd7ba/dcd7ba) |
| Everforest Dark | ![](https://placehold.co/16x16/1e2326/1e2326) `#1E2326` | ![](https://placehold.co/16x16/d3c6aa/d3c6aa) `#D3C6AA` | ![](https://placehold.co/14x14/7a8478/7a8478) ![](https://placehold.co/14x14/e67e80/e67e80) ![](https://placehold.co/14x14/a7c080/a7c080) ![](https://placehold.co/14x14/dbbc7f/dbbc7f) ![](https://placehold.co/14x14/7fbbb3/7fbbb3) ![](https://placehold.co/14x14/d699b6/d699b6) ![](https://placehold.co/14x14/83c092/83c092) ![](https://placehold.co/14x14/f2efdf/f2efdf) ![](https://placehold.co/14x14/a6b0a0/a6b0a0) ![](https://placehold.co/14x14/f85552/f85552) ![](https://placehold.co/14x14/8da101/8da101) ![](https://placehold.co/14x14/dfa000/dfa000) ![](https://placehold.co/14x14/3a94c5/3a94c5) ![](https://placehold.co/14x14/df69ba/df69ba) ![](https://placehold.co/14x14/35a77c/35a77c) ![](https://placehold.co/14x14/fffbef/fffbef) |

### Light

| Theme | Background | Foreground | Palette (ANSI 0–15) |
|-------|------------|------------|---------------------|
| Catppuccin Latte | ![](https://placehold.co/16x16/eff1f5/eff1f5) `#EFF1F5` | ![](https://placehold.co/16x16/4c4f69/4c4f69) `#4C4F69` | ![](https://placehold.co/14x14/5c5f77/5c5f77) ![](https://placehold.co/14x14/d20f39/d20f39) ![](https://placehold.co/14x14/40a02b/40a02b) ![](https://placehold.co/14x14/df8e1d/df8e1d) ![](https://placehold.co/14x14/1e66f5/1e66f5) ![](https://placehold.co/14x14/ea76cb/ea76cb) ![](https://placehold.co/14x14/179299/179299) ![](https://placehold.co/14x14/acb0be/acb0be) ![](https://placehold.co/14x14/6c6f85/6c6f85) ![](https://placehold.co/14x14/de293e/de293e) ![](https://placehold.co/14x14/49af3d/49af3d) ![](https://placehold.co/14x14/eea02d/eea02d) ![](https://placehold.co/14x14/456eff/456eff) ![](https://placehold.co/14x14/fe85d8/fe85d8) ![](https://placehold.co/14x14/2d9fa8/2d9fa8) ![](https://placehold.co/14x14/bcc0cc/bcc0cc) |
| Solarized Light | ![](https://placehold.co/16x16/fdf6e3/fdf6e3) `#FDF6E3` | ![](https://placehold.co/16x16/657b83/657b83) `#657B83` | ![](https://placehold.co/14x14/073642/073642) ![](https://placehold.co/14x14/dc322f/dc322f) ![](https://placehold.co/14x14/859900/859900) ![](https://placehold.co/14x14/b58900/b58900) ![](https://placehold.co/14x14/268bd2/268bd2) ![](https://placehold.co/14x14/d33682/d33682) ![](https://placehold.co/14x14/2aa198/2aa198) ![](https://placehold.co/14x14/bbb5a2/bbb5a2) ![](https://placehold.co/14x14/002b36/002b36) ![](https://placehold.co/14x14/cb4b16/cb4b16) ![](https://placehold.co/14x14/586e75/586e75) ![](https://placehold.co/14x14/657b83/657b83) ![](https://placehold.co/14x14/839496/839496) ![](https://placehold.co/14x14/6c71c4/6c71c4) ![](https://placehold.co/14x14/93a1a1/93a1a1) ![](https://placehold.co/14x14/fdf6e3/fdf6e3) |
| Gruvbox Light | ![](https://placehold.co/16x16/fbf1c7/fbf1c7) `#FBF1C7` | ![](https://placehold.co/16x16/3c3836/3c3836) `#3C3836` | ![](https://placehold.co/14x14/fbf1c7/fbf1c7) ![](https://placehold.co/14x14/cc241d/cc241d) ![](https://placehold.co/14x14/98971a/98971a) ![](https://placehold.co/14x14/d79921/d79921) ![](https://placehold.co/14x14/458588/458588) ![](https://placehold.co/14x14/b16286/b16286) ![](https://placehold.co/14x14/689d6a/689d6a) ![](https://placehold.co/14x14/7c6f64/7c6f64) ![](https://placehold.co/14x14/928374/928374) ![](https://placehold.co/14x14/9d0006/9d0006) ![](https://placehold.co/14x14/79740e/79740e) ![](https://placehold.co/14x14/b57614/b57614) ![](https://placehold.co/14x14/076678/076678) ![](https://placehold.co/14x14/8f3f71/8f3f71) ![](https://placehold.co/14x14/427b58/427b58) ![](https://placehold.co/14x14/3c3836/3c3836) |
| One Half Light | ![](https://placehold.co/16x16/fafafa/fafafa) `#FAFAFA` | ![](https://placehold.co/16x16/383a42/383a42) `#383A42` | ![](https://placehold.co/14x14/383a42/383a42) ![](https://placehold.co/14x14/e45649/e45649) ![](https://placehold.co/14x14/50a14f/50a14f) ![](https://placehold.co/14x14/c18401/c18401) ![](https://placehold.co/14x14/0184bc/0184bc) ![](https://placehold.co/14x14/a626a4/a626a4) ![](https://placehold.co/14x14/0997b3/0997b3) ![](https://placehold.co/14x14/bababa/bababa) ![](https://placehold.co/14x14/4f525e/4f525e) ![](https://placehold.co/14x14/e06c75/e06c75) ![](https://placehold.co/14x14/98c379/98c379) ![](https://placehold.co/14x14/d8b36e/d8b36e) ![](https://placehold.co/14x14/61afef/61afef) ![](https://placehold.co/14x14/c678dd/c678dd) ![](https://placehold.co/14x14/56b6c2/56b6c2) ![](https://placehold.co/14x14/ffffff/ffffff) |

## TUI dark/light auto-detection

`COLORFGBG` is set automatically from the selected theme's background luminance,
so vim's `:set background?` picks the right scheme without manual configuration.
tmux and less use the same convention. On Windows the value is propagated into
WSL through `WSLENV`.
