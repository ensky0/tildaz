# Configuration

Config file path (per OS standard):

| OS | Path |
|---|---|
| Windows | `%APPDATA%\tildaz\config.json` |
| macOS | `~/.config/tildaz/config.json` (XDG, ghostty / alacritty pattern) |

If missing, it is auto-created with defaults on first launch. macOS additionally inserts the user's `$SHELL` env (or `/bin/bash`) into the `shell` field on first creation, so the value on disk reflects the user's actual shell.

> **Strict schema validation** — every key is required, unknown keys are rejected, type mismatches are fatal. The `defaultConfigJson` function in [`src/config.zig`](src/config.zig) is the single source of truth (used both for first-run file creation and for validating user config). Both Windows and macOS apply the same policy.
>
> **Comment keys** — any key starting with `_` (e.g. `_note`, `_disabled_test_font`) is treated as a user comment and skipped from schema validation. Use this to annotate your config or temporarily disable a field by renaming it (e.g. `"shell": "/bin/zsh"` → `"_shell": "/bin/zsh"`). The `_` prefix convention is not part of JSON itself but is convenient here since the official schema never uses it.

## Windows example

```json
{
  "window": {
    "dock_position": "top",
    "width_percent": 50.0,
    "height_percent": 100.0,
    "offset_percent": 100.0,
    "opacity_percent": 100.0
  },
  "font": {
    "family": "Cascadia Code",
    "glyph_fallback": ["Malgun Gothic", "Segoe UI Emoji", "Segoe UI Symbol"],
    "size_point": 16,
    "cell_width_ratio": 1.0,
    "line_height_ratio": 1.0
  },
  "theme": "Tilda",
  "shell": "cmd.exe",
  "hotkey": "f1",
  "auto_start": true,
  "hidden_start": false,
  "max_scroll_lines": 100000
}
```

## macOS example

```json
{
  "window": {
    "dock_position": "top",
    "width_percent": 50.0,
    "height_percent": 100.0,
    "offset_percent": 100.0,
    "opacity_percent": 100.0
  },
  "font": {
    "family": "Menlo",
    "glyph_fallback": ["Apple SD Gothic Neo", "Apple Color Emoji", "Apple Symbols"],
    "size_point": 15,
    "cell_width_ratio": 1.0,
    "line_height_ratio": 1.1
  },
  "theme": "Tilda",
  "shell": "/bin/zsh",
  "hotkey": "f1",
  "auto_start": true,
  "hidden_start": false,
  "max_scroll_lines": 100000
}
```

## Field reference

Every numeric field name carries its unit (`_percent`, `_point`, `_ratio`). String / boolean fields are self-evident.

| Key | Type | Range | Windows default | macOS default | Description |
|-----|------|-------|-----------------|---------------|-------------|
| `window.dock_position` | string | top / bottom / left / right | "top" | "top" | Edge to dock to |
| `window.width_percent` | float | 1.0–100.0 | 50.0 | 50.0 | Width as % of screen — fractional values OK (e.g. 33.3) |
| `window.height_percent` | float | 1.0–100.0 | 100.0 | 100.0 | Height as % of screen |
| `window.offset_percent` | float | 0.0–100.0 | 100.0 | 100.0 | Position along edge (0 = start, 50 = center, 100 = end) |
| `window.opacity_percent` | float | 0.0–100.0 | 100.0 | 100.0 | Window opacity (%) — internally converted to 0–255 alpha |
| `font.family` | string | — | "Cascadia Code" | "Menlo" | Primary font. Must be installed on the system; missing → fatal |
| `font.glyph_fallback` | string[] | max 7 entries (chain total ≤ 8 with `family`) | `["Malgun Gothic", "Segoe UI Emoji", "Segoe UI Symbol"]` | `["Apple SD Gothic Neo", "Apple Color Emoji", "Apple Symbols"]` | Glyph fallback chain. Codepoints not in `family` are looked up in this order; misses fall through to the OS system font. **All listed entries must be installed.** Empty array `[]` is allowed (system fallback only) |
| `font.size_point` | int | 8–72 | 16 | 15 | Font size in typographic points (host applies DPI scale) |
| `font.cell_width_ratio` | float | 0.5–2.0 | 1.0 | 1.0 | Cell-width multiplier (1.0 = font's own advance) |
| `font.line_height_ratio` | float | 0.5–2.0 | 1.0 | 1.1 | Line-height multiplier (1.0 = font's own ascent + descent + leading) |
| `theme` | string | see Built-in themes below | "Tilda" | "Tilda" | Color theme |
| `shell` | string | — | "cmd.exe" | `$SHELL` env (or `/bin/bash`) | Shell to spawn. Windows accepts arguments — e.g. `"wsl.exe -d Debian --cd ~"` to drop straight into a WSL home prompt. macOS expects an absolute binary path; for argv beyond the binary, configure your shell via `~/.zshrc` etc. |
| `hotkey` | string | "f1", "ctrl+space", "shift+cmd+t", … | "f1" | "f1" | Global toggle hotkey. `cmd` token = Win key on Windows / Cmd on macOS |
| `auto_start` | bool | — | true | true | Start on login (Registry Run on Windows, LaunchAgent on macOS) |
| `hidden_start` | bool | — | false | false | Start hidden (first toggle reveals) |
| `max_scroll_lines` | int | 100–10,000,000 | 100,000 | 100,000 | Scrollback buffer (lines) |

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

| Theme | Background | Foreground |
|-------|------------|------------|
| Tilda | `#000000` | `#FFFFFF` |
| Ghostty | `#1D1F21` | `#C5C8C6` |
| Windows Terminal | `#0C0C0C` | `#CCCCCC` |

### Dark

| Theme | Background | Foreground |
|-------|------------|------------|
| Catppuccin Mocha | `#1E1E2E` | `#CDD6F4` |
| Dracula | `#282A36` | `#F8F8F2` |
| Gruvbox Dark | `#282828` | `#EBDBB2` |
| Tokyo Night | `#1A1B26` | `#C0CAF5` |
| Nord | `#2E3440` | `#D8DEE9` |
| One Half Dark | `#282C34` | `#DCDFE4` |
| Solarized Dark | `#001E27` | `#9CC2C3` |
| Monokai Soda | `#1A1A1A` | `#C4C5B5` |
| Rosé Pine | `#191724` | `#E0DEF4` |
| Kanagawa | `#1F1F28` | `#DCD7BA` |
| Everforest Dark | `#1E2326` | `#D3C6AA` |

### Light

| Theme | Background | Foreground |
|-------|------------|------------|
| Catppuccin Latte | `#EFF1F5` | `#4C4F69` |
| Solarized Light | `#FDF6E3` | `#657B83` |
| Gruvbox Light | `#FBF1C7` | `#3C3836` |
| One Half Light | `#FAFAFA` | `#383A42` |

## TUI dark/light auto-detection

`COLORFGBG` is set automatically from the selected theme's background luminance,
so vim's `:set background?` picks the right scheme without manual configuration.
tmux and less use the same convention. On Windows the value is propagated into
WSL through `WSLENV`.
