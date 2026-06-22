# Configuration

Config file path (per OS standard):

| OS | Path |
|---|---|
| Windows | `%APPDATA%\tildaz\config.json` |
| macOS | `~/.config/tildaz/config.json` (XDG, ghostty / alacritty pattern) |
| Linux | `~/.config/tildaz/config.json` (XDG) |

If missing, it is auto-created with defaults on first launch. macOS and Linux additionally insert the user's `$SHELL` env (or `/bin/bash`) into the `shell` field on first creation, so the value on disk reflects the user's actual shell.

> **Strict schema validation** — every key is required, unknown keys are rejected, type mismatches are fatal. The `defaultConfigJson` function in [`src/config.zig`](src/config.zig) is the single source of truth (used both for first-run file creation and for validating user config). Windows, macOS, and Linux apply the same policy.
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

## Linux example

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
    "family": "DejaVu Sans Mono",
    "glyph_fallback": ["Noto Sans CJK KR", "Noto Color Emoji"],
    "size_point": 15,
    "cell_width_ratio": 1.0,
    "line_height_ratio": 1.1
  },
  "theme": "Tilda",
  "shell": "/bin/bash",
  "hotkey": "f1",
  "auto_start": true,
  "hidden_start": false,
  "max_scroll_lines": 100000
}
```

## Field reference

Every numeric field name carries its unit (`_percent`, `_point`, `_ratio`). String / boolean fields are self-evident.

| Key | Type | Range | Windows default | macOS default | Linux default | Description |
|-----|------|-------|-----------------|---------------|---------------|-------------|
| `window.dock_position` | string | top / bottom / left / right | "top" | "top" | "top" | Edge to dock to |
| `window.width_percent` | float | 1.0–100.0 | 50.0 | 50.0 | 50.0 | Width as % of screen — fractional values OK (e.g. 33.3) |
| `window.height_percent` | float | 1.0–100.0 | 100.0 | 100.0 | 100.0 | Height as % of screen |
| `window.offset_percent` | float | 0.0–100.0 | 100.0 | 100.0 | 100.0 | Position along edge (0 = start, 50 = center, 100 = end) |
| `window.opacity_percent` | float | 0.0–100.0 | 100.0 | 100.0 | 100.0 | Window opacity (%) — internally converted to 0–255 alpha |
| `font.family` | string | — | "Cascadia Code" | "Menlo" | "DejaVu Sans Mono" | Primary font. Must be installed on the system; missing → fatal |
| `font.glyph_fallback` | string[] | max 7 entries (chain total ≤ 8 with `family`) | `["Malgun Gothic", "Segoe UI Emoji", "Segoe UI Symbol"]` | `["Apple SD Gothic Neo", "Apple Color Emoji", "Apple Symbols"]` | `["Noto Sans CJK KR", "Noto Color Emoji"]` | Glyph fallback chain. Codepoints not in `family` are looked up in this order; misses fall through to the OS system font. **All listed entries must be installed.** Empty array `[]` is allowed (system fallback only) |
| `font.size_point` | int | 8–72 | 16 | 15 | 15 | Font size in typographic points (host applies DPI scale) |
| `font.cell_width_ratio` | float | 0.5–2.0 | 1.0 | 1.0 | 1.0 | Cell-width multiplier (1.0 = font's own advance) |
| `font.line_height_ratio` | float | 0.5–2.0 | 1.0 | 1.1 | 1.1 | Line-height multiplier (1.0 = font's own ascent + descent + leading) |
| `theme` | string | see Built-in themes below | "Tilda" | "Tilda" | "Tilda" | Color theme |
| `shell` | string | — | "cmd.exe" | `$SHELL` env (or `/bin/bash`) | `$SHELL` env (or `/bin/bash`) | Shell to spawn. Windows accepts arguments — e.g. `"wsl.exe -d Debian --cd ~"` to drop straight into a WSL home prompt. macOS / Linux expect an absolute binary path; for argv beyond the binary, configure your shell via `~/.zshrc`, `~/.bashrc`, etc. |
| `hotkey` | string | "f1", "ctrl+space", "shift+cmd+t", … | "f1" | "f1" | "f1" | Global toggle hotkey. `cmd` token = Win key on Windows / Cmd on macOS / Super on Linux |
| `auto_start` | bool | — | true | true | true | Start on login (Registry Run on Windows, LaunchAgent on macOS, XDG autostart `.desktop` on Linux) |
| `hidden_start` | bool | — | false | false | false | Start hidden (first toggle reveals) |
| `max_scroll_lines` | int | 100–10,000,000 | 100,000 | 100,000 | 100,000 | Scrollback buffer (lines) |

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
