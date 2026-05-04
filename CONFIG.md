# Configuration

Config file path (per OS standard):

| OS | Path |
|---|---|
| Windows | `%APPDATA%\tildaz\config.json` |
| macOS | `~/.config/tildaz/config.json` (XDG, ghostty / alacritty pattern) |

If missing, it is auto-created with defaults on first launch.

> **Schema status**: Windows and macOS schemas are being unified ([issue #118](https://github.com/ensky0/tildaz/issues/118)). Windows currently uses a *nested* top-level (`"window.dock_position"`), macOS uses *flat*. Both examples are shown below; the keys / types / ranges are otherwise identical. See [SPEC.md §7](SPEC.md) for the up-to-date matrix.

## Windows example (nested)

```json
{
  "window": {
    "dock_position": "top",
    "width": 50,
    "height": 100,
    "offset": 100,
    "opacity": 100
  },
  "font": {
    "family": ["Cascadia Code"],
    "size": 19,
    "line_height": 0.95,
    "cell_width": 1.1
  },
  "theme": "Tilda",
  "shell": "cmd.exe",
  "hotkey": "f1",
  "auto_start": true,
  "hidden_start": false,
  "max_scroll_lines": 100000
}
```

## macOS example (nested — same schema as Windows)

```json
{
  "window": {
    "dock_position": "top",
    "width": 50,
    "height": 100,
    "offset": 100,
    "opacity": 100
  },
  "font": {
    "family": ["Menlo"],
    "size": 15,
    "cell_width": 1.0,
    "line_height": 1.1
  },
  "theme": "Tilda",
  "shell": "",
  "hotkey": "f1",
  "auto_start": true,
  "hidden_start": false,
  "max_scroll_lines": 100000
}
```

> **macOS schema validation is strict** — every key is required, unknown keys are rejected, and type mismatches are fatal. The `DEFAULT_CONFIG_JSON` constant in source serves as the single source of truth (used both for first-run file creation and for validating user config). Windows is currently graceful (missing keys fall back to defaults); both will converge on strict.

## Field reference

| Key | Type | Range | Windows default | macOS default | Description |
|-----|------|-------|-----------------|---------------|-------------|
| dock_position | string | top / bottom / left / right | "top" | "top" | Edge to dock to |
| width | int | 1–100 | 50 | 50 | Width (% of screen) |
| height | int | 1–100 | 100 | 100 | Height (% of screen) |
| offset | int | 0–100 | 100 | 100 | Position along edge (0 = start, 50 = center, 100 = end) |
| opacity | int | 0–100 | 100 | 100 | Window opacity (%) |
| font.family | string \| string[] | — | `["Cascadia Code"]` | `["Menlo"]` | Font families (array = *glyph fallback chain* — per-codepoint lookup, max 8). **All listed families must exist on the system.** Both platforms fall back to the OS system font for glyphs not in the chain (Windows DirectWrite, macOS CoreText). Override with explicit array if you want a specific Korean / CJK font. |
| font.size | int | 8–72 | 19 | 15 | Font size (pt) |
| font.line_height | float | 0.1–10.0 (Win) / 0.5–2.0 (mac) | 0.95 | 1.1 | Line-height multiplier (1.0 = default leading) |
| font.cell_width | float | 0.1–10.0 (Win) / 0.5–2.0 (mac) | 1.1 | 1.0 | Cell-width multiplier (1.0 = default advance) |
| theme | string | see [Themes](THEMES.md) | "Tilda" | "Tilda" | Color theme |
| shell | string | — | "cmd.exe" | "" (= `$SHELL` env / `/bin/zsh`) | Shell to spawn. Windows accepts arguments — e.g. `"wsl.exe -d Debian --cd ~"` to drop straight into a WSL home prompt. macOS expects an absolute binary path; for argv beyond the binary, set up your shell to handle it via `~/.zshrc` etc. |
| hotkey | string | "f1", "ctrl+space", "shift+cmd+t", … | "f1" | "f1" | Global toggle hotkey. `cmd` token = Win key on Windows / Cmd on macOS. |
| auto_start | bool | — | true | true | Start on login (Registry Run on Windows, LaunchAgent on macOS) |
| hidden_start | bool | — | false | false | Start hidden (first toggle reveals) |
| max_scroll_lines | int | 100–10,000,000 | 100,000 | 100,000 | Scrollback buffer (lines) |

## Position examples

```
"window": { "dock_position": "top", "width": 100, "height": 40, "offset": 0 }
 -> top of screen, full width, 40% height, flush to the left edge

"window": { "dock_position": "top", "width": 60, "height": 40, "offset": 50 }
 -> top of screen, 60% width, 40% height, centered horizontally

"window": { "dock_position": "top", "width": 50, "height": 100, "offset": 100 }
 -> top of screen, 50% width, full height, flush to the right edge

"window": { "dock_position": "left", "width": 30, "height": 80, "offset": 50 }
 -> left side of screen, 30% width, 80% height, vertically centered
```
