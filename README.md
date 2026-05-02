# TildaZ

Quake-style drop-down terminal for Windows and macOS, built on Zig and libghostty-vt.

Brings the UX of Linux's [Tilda](https://github.com/lanoxx/tilda) to Windows and macOS.

**Website**: https://ensky0.github.io/tildaz/

> **v0.2.13 — macOS support**
>
> macOS native backend lands: PTY via `login_tty` + IUTF8 termios, CoreText
> + Metal renderer, NSWindow drop-down at popUpMenu level, CGEventTap for
> the global hotkey, NSTextInputClient for IME (Korean / Japanese / Chinese
> composition with inline pre-edit). Cross-platform behavior is tracked in
> [SPEC.md](SPEC.md). The same `zig build` produces `tildaz.exe` on Windows
> and `TildaZ.app` on macOS.

## Features

- **Global hotkey** — toggles the terminal show/hide system-wide. Default F1 (configurable on both platforms via `config.hotkey`)
- **Fullscreen** — Alt+Enter on Windows, current-monitor work area (excluding taskbar / Dock). Fullscreen state is preserved across hide → show cycles and re-applied on display / DPI changes
- **Tabs** — multiple independent terminal sessions
  - New tab: Ctrl+Shift+T (Windows) / Cmd+T (macOS)
  - Close active: Ctrl+Shift+W (Windows) / Cmd+W (macOS)
  - Switch by index: Alt+1–9 (Windows) / Cmd+1–9 (macOS)
  - Prev / next tab: Ctrl+Shift+Tab / Ctrl+Tab (Windows) — Shift+Cmd+[ / Shift+Cmd+] (macOS)
  - Click to select, X button to close, drag to reorder, double-click to rename
  - Closing the last tab quits the app
- **Full Unicode support** — Hangul, CJK, emoji, combining marks, wide / narrow cells
- **Font glyph fallback chain** — up to 8 font families; *per-codepoint* lookup walks the chain to find a font with the glyph (e.g. Latin → Cascadia Mono / Menlo, Hangul → Malgun Gothic / Apple SD Gothic Neo, symbols → Segoe UI Symbol / Apple Symbols). All listed families must exist on the system.
  - macOS additionally falls through to the system auto fallback (CoreText `CTFontCreateForString`) for codepoints not in the chain (Apple Color Emoji, etc.) — a single `["Menlo"]` is enough for most cases.
- **GPU-accelerated rendering**
  - Windows: ClearType subpixel via DirectWrite + Direct3D 11 / HLSL shaders
  - macOS: Metal + CoreText, retina (2x) glyph atlas
- **Bundled OpenConsole** (Windows) — ships `OpenConsole.exe` + `conpty.dll` to bypass the system `conhost.exe`. Bulk output throughput is 2.2× over system conhost; falls back to system conhost automatically when the bundled files are missing
- **POSIX PTY** (macOS) — `openpty` + `login_tty` + IUTF8 termios. SIGHUP-ignoring shells (`nohup`, `trap '' HUP`) are killed with SIGKILL after a 500 ms grace, so closing a tab never hangs
- **ANSI colors** — 16 / 256 / TrueColor foreground and background, bold-is-bright, inverse
- **18 built-in color themes** — Tilda, Ghostty, Windows Terminal, Dracula, Catppuccin, and more
- **Text selection and copy**
  - Click-drag to select (selection inverted in place)
  - Double-click to select a word (boundary chars: space / tab / `" \` | : ; ( ) [ ] { } < >`)
  - Release mouse button → automatic clipboard copy
  - Right-click to paste (clipboard)
  - Cross-platform shortcut: Ctrl+Shift+C (Windows) / Cmd+C (macOS) for explicit copy of current selection
- **Scrollback** — mouse wheel, scrollbar drag (configurable lines, up to 10 M). Thumb stays at least 32 px × DPI scale so it remains draggable even with deep scrollback. Selection survives viewport movement (ghostty `Pin` based)
- **IME (Korean / Japanese / Chinese)** — inline pre-edit on the cursor; commit via Enter or syllable boundary; Ctrl+key during composition discards the pre-edit and is sent to the PTY (so Ctrl+C aborts cleanly even mid-composition)
- **Vim dark/light detection** — sets `COLORFGBG` based on theme background luminance (propagated into WSL on Windows)
- **Drop-down** — docks to any screen edge (top / bottom / left / right). Size and offset as percentages of the screen
- **Multi-monitor follow**
  - Toggle drops onto the monitor containing the mouse cursor; size / offset are recomputed against that monitor's work area
  - Resolution change / external monitor connect-disconnect / taskbar (Dock) auto-hide / per-monitor DPI change are all detected and re-applied immediately
  - Moving to a different-DPI monitor re-rasters the font + cell metrics + glyph atlas at the new DPI
- **Translucent**, always-on-top window (configurable opacity)
- **Ctrl+Shift+V** (Windows) / Cmd+V (macOS) — paste
- **Ctrl+Shift+R** (Windows) / TBD (macOS) — reset the terminal
- **About dialog** — Ctrl+Shift+I (Windows) / Shift+Cmd+I (macOS). Shows version / exe full path / pid / config path / log path. Selection auto-copies to clipboard (terminal-style) for easy paste of paths
- **Open config / log shortcuts** — Ctrl+Shift+P / Ctrl+Shift+L (Windows), Shift+Cmd+P / Shift+Cmd+L (macOS) — opens the file in the system default editor
- **Unified log**
  - Windows: `%APPDATA%\tildaz\tildaz.log`
  - macOS: `~/Library/Logs/tildaz.log` (Console.app auto-indexed)
  - boot / exit / autostart / PTY events / perf snapshots share a single timeline
- Perf snapshot — Ctrl+Shift+F12 (Windows) — appends ms / bytes / call counts per push / drain / parse / render / present stage to the log
- **Auto-start on login**
  - Windows: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` (consolidated from Task Scheduler in v0.2.8 — GPO / UAC blocked `schtasks /create` and left stale entries)
  - macOS: `~/Library/LaunchAgents/com.tildaz.app.plist` (RunAtLoad)

## System requirements (running TildaZ)

| Platform | Minimum |
|---|---|
| **Windows** | Windows 10 (1903) or later, x64. ARM64 is not yet supported. |
| **macOS** | macOS 13 Ventura or later. The release DMG ships a universal binary that runs natively on Apple Silicon (M1/M2/M3/...) and Intel Macs. |

## Build

### Requirements

- [Zig 0.15.2](https://ziglang.org/download/)
- **macOS** — Xcode Command Line Tools (`xcode-select --install`). Provides the macOS SDK (linked via `xcrun --show-sdk-path`), `codesign` (ad-hoc signing), and `lipo` (universal binary). Full Xcode is *not* required.
- **Windows** — no extra toolchain. Zig bundles its own MSVC ABI clang + LLD. The release pipeline builds on a `windows-2022` GitHub Actions runner; cross-compiling from macOS / Linux is technically possible but not part of the official release flow.

### Build commands

```bash
# default build (ReleaseFast)
zig build

# debug build
zig build -Doptimize=Debug
```

Output:
- Windows: `zig-out/bin/tildaz.exe`
- macOS: `zig-out/TildaZ.app` (codesigned ad-hoc — see Distribution)

> **Note**: the SIMD option (`-Dsimd=true`) currently does not work on Windows.
> Zig 0.15's build system does not pass C++ stdlib include paths through to
> ghostty's C++ SIMD sources. Upstream fix required.

When building a WSL checkout from Windows, use the `\\wsl$\Debian\...` UNC
path. `\\wsl.localhost\Debian\...` can trip security products or exhibit
different Windows network-path behavior that blocks the executable.

### macOS — first-run permissions

The global hotkey (default F1) and Cmd+Q quit need two macOS permissions:
**Input Monitoring** and **Accessibility**. On first launch (and after each
ad-hoc rebuild — the codesign identity changes per build) TildaZ shows a
step-by-step dialog. Open System Settings → Privacy & Security and enable
*both* for `tildaz`. Without these, the window still works but global
hotkeys do not.

### Packaging (release zip — Windows)

Starting with v0.2.6 the Windows release is a single zip with three files:

```
tildaz-v<ver>-win-x64.zip
  tildaz.exe        the binary
  conpty.dll        bundled ConPTY runtime (MIT, microsoft/terminal)
  OpenConsole.exe   bundled PTY host        (MIT, microsoft/terminal)
  README.txt        (dist/windows/README.txt)
```

All three files must live in the **same folder** for the bundled path to
activate. If `conpty.dll` or `OpenConsole.exe` is missing, TildaZ falls back
to the system `kernel32` conhost — baseline behavior still works, but bulk
output throughput is roughly half of the bundled path.

#### Bundle build — `zig build package`

```bash
zig build package
# → zig-out/release/tildaz-v<ver>-win-x64.zip
# → zig-out/release/tildaz-v<ver>-win-x64.zip.sha256   (compatible with `sha256sum -c`)
```

Internally this calls `bash dist/windows/package.sh --version <ver>` and works
under Git Bash on Windows, macOS, and Linux. Zip compression uses PowerShell
`Compress-Archive` on Windows and `zip` on macOS/Linux — only first-party
OS tools, no Python / Node / external dependencies.

#### Tag + release — `dist/release.sh`

Tag and create a GitHub Release in one command from the repo root:

```bash
# pre-req: bump tildaz_version in build.zig first, commit it
dist/release.sh --version 0.2.9              # normal flow (tag push → Actions)
dist/release.sh --version 0.2.9 --dry-run    # build/package rehearsal, no tag push
dist/release.sh --version 0.2.9 --local-upload   # skip Actions, gh release directly
```

A tag push triggers `.github/workflows/release.yml` on a Windows runner,
which runs `zig build package` → uploads the zip + sha256 → attaches
`dist/release-notes/v<ver>.md` as the Release body. For manual retries,
`workflow_dispatch` accepts the tag name directly.

The release-notes file **must exist on the tag** — `release.sh`'s pre-flight
check fails if `dist/release-notes/v<ver>.md` is missing.

## Configuration

Config file path (per OS standard):

| OS | Path |
|---|---|
| Windows | `%APPDATA%\tildaz\config.json` |
| macOS | `~/.config/tildaz/config.json` (XDG, ghostty / alacritty pattern) |
| Linux | `~/.config/tildaz/config.json` |

If missing, it is auto-created with defaults on first launch.

> **Schema status**: Windows and macOS schemas are being unified ([issue #118](https://github.com/ensky0/tildaz/issues/118)). Windows currently uses a *nested* top-level (`"window.dock_position"`), macOS uses *flat*. Both examples are shown below; the keys / types / ranges are otherwise identical. See [SPEC.md §7](SPEC.md) for the up-to-date matrix.

### Windows example (nested)

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
    "family": ["Cascadia Mono", "Malgun Gothic", "Segoe UI Symbol"],
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

### macOS example (nested — same schema as Windows)

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

| Key | Type | Range | Windows default | macOS default | Description |
|-----|------|-------|-----------------|---------------|-------------|
| dock_position | string | top / bottom / left / right | "top" | "top" | Edge to dock to |
| width | int | 1–100 | 50 | 50 | Width (% of screen) |
| height | int | 1–100 | 100 | 100 | Height (% of screen) |
| offset | int | 0–100 | 100 | 100 | Position along edge (0 = start, 50 = center, 100 = end) |
| opacity | int | 0–100 | 100 | 100 | Window opacity (%) |
| font.family | string \| string[] | — | `["Cascadia Mono", "Malgun Gothic", "Segoe UI Symbol"]` | `["Menlo"]` | Font families (array = *glyph fallback chain* — per-codepoint lookup, max 8). **All listed families must exist on the system.** macOS additionally falls back to the system font for glyphs not in the chain. |
| font.size | int | 8–72 | 19 | 15 | Font size (pt) |
| font.line_height | float | 0.1–10.0 (Win) / 0.5–2.0 (mac) | 0.95 | 1.1 | Line-height multiplier (1.0 = default leading) |
| font.cell_width | float | 0.1–10.0 (Win) / 0.5–2.0 (mac) | 1.1 | 1.0 | Cell-width multiplier (1.0 = default advance) |
| theme | string | see [Themes](#themes) | "Tilda" | "Tilda" | Color theme |
| shell | string | — | "cmd.exe" | "" (= `$SHELL` env / `/bin/zsh`) | Shell to spawn. Windows accepts arguments — e.g. `"wsl.exe -d Debian --cd ~"` to drop straight into a WSL home prompt. macOS expects an absolute binary path; for argv beyond the binary, set up your shell to handle it via `~/.zshrc` etc. |
| hotkey | string | "f1", "ctrl+space", "shift+cmd+t", … | "f1" | "f1" | Global toggle hotkey. `cmd` token = Win key on Windows / Cmd on macOS. |
| auto_start | bool | — | true | true | Start on login (Registry Run on Windows, LaunchAgent on macOS) |
| hidden_start | bool | — | false | false | Start hidden (first toggle reveals) |
| max_scroll_lines | int | 100–10,000,000 | 100,000 | 100,000 | Scrollback buffer (lines) |

### Position examples

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

## Keybindings

Cross-platform shortcut convention: each platform follows its native modifier (Apple HIG order Shift+Cmd on macOS, Ctrl+Shift on Windows).

| Action | Windows | macOS |
|--------|---------|-------|
| Toggle terminal show/hide | F1 (configurable) | F1 (configurable) |
| Fullscreen | Alt+Enter | (TBD) |
| New tab | Ctrl+Shift+T | Cmd+T |
| Close active tab | Ctrl+Shift+W | Cmd+W |
| Switch tab by index | Alt+1–9 | Cmd+1–9 |
| Previous tab | Ctrl+Shift+Tab | Shift+Cmd+[ |
| Next tab | Ctrl+Tab | Shift+Cmd+] |
| Copy selection (explicit) | Ctrl+Shift+C | Cmd+C |
| Paste from clipboard | Ctrl+Shift+V | Cmd+V |
| Reset terminal | Ctrl+Shift+R | (TBD) |
| About dialog | Ctrl+Shift+I | Shift+Cmd+I |
| Open config in editor | Ctrl+Shift+P | Shift+Cmd+P |
| Open log in editor | Ctrl+Shift+L | Shift+Cmd+L |
| Perf snapshot to log | Ctrl+Shift+F12 | (dev tool, Win-only) |
| Quit | (close last tab) | Cmd+Q |
| Scrollback page up / down | Shift+PgUp / PgDn | Shift+PgUp / PgDn |

Mouse:

| Action | Both platforms |
|--------|----------------|
| Drag-select text | Auto-copy on release |
| Double-click word | Word selection + auto-copy. Boundary chars: space / tab / `" \` | : ; ( ) [ ] { } < >`. Wide chars (Hangul / CJK) treated as word body. |
| Mouse wheel | Scroll viewport |
| Right-click | Paste from clipboard |
| Scrollbar click / drag | Jump or follow viewport |

## Themes

18 built-in color themes. Set `"theme"` in `config.json` to apply foreground/background and the ANSI 16-color palette.

### Classic

| Theme | Background | Foreground | Palette preview |
|-------|------------|------------|-----------------|
| **Tilda** | ![](https://placehold.co/16x16/000000/000000) `#000000` | ![](https://placehold.co/16x16/ffffff/ffffff) `#FFFFFF` | ![](https://placehold.co/12x12/cc0000/cc0000) ![](https://placehold.co/12x12/4e9a06/4e9a06) ![](https://placehold.co/12x12/c4a000/c4a000) ![](https://placehold.co/12x12/3465a4/3465a4) ![](https://placehold.co/12x12/75507b/75507b) ![](https://placehold.co/12x12/06989a/06989a) |
| **Ghostty** | ![](https://placehold.co/16x16/1d1f21/1d1f21) `#1D1F21` | ![](https://placehold.co/16x16/c5c8c6/c5c8c6) `#C5C8C6` | ![](https://placehold.co/12x12/cc6666/cc6666) ![](https://placehold.co/12x12/b5bd68/b5bd68) ![](https://placehold.co/12x12/f0c674/f0c674) ![](https://placehold.co/12x12/81a2be/81a2be) ![](https://placehold.co/12x12/b294bb/b294bb) ![](https://placehold.co/12x12/8abeb7/8abeb7) |
| **Windows Terminal** | ![](https://placehold.co/16x16/0c0c0c/0c0c0c) `#0C0C0C` | ![](https://placehold.co/16x16/cccccc/cccccc) `#CCCCCC` | ![](https://placehold.co/12x12/c50f1f/c50f1f) ![](https://placehold.co/12x12/13a10e/13a10e) ![](https://placehold.co/12x12/c19c00/c19c00) ![](https://placehold.co/12x12/0037da/0037da) ![](https://placehold.co/12x12/881798/881798) ![](https://placehold.co/12x12/3a96dd/3a96dd) |

### Dark

| Theme | Background | Foreground | Palette preview |
|-------|------------|------------|-----------------|
| **Catppuccin Mocha** | ![](https://placehold.co/16x16/1e1e2e/1e1e2e) `#1E1E2E` | ![](https://placehold.co/16x16/cdd6f4/cdd6f4) `#CDD6F4` | ![](https://placehold.co/12x12/f38ba8/f38ba8) ![](https://placehold.co/12x12/a6e3a1/a6e3a1) ![](https://placehold.co/12x12/f9e2af/f9e2af) ![](https://placehold.co/12x12/89b4fa/89b4fa) ![](https://placehold.co/12x12/f5c2e7/f5c2e7) ![](https://placehold.co/12x12/94e2d5/94e2d5) |
| **Dracula** | ![](https://placehold.co/16x16/282a36/282a36) `#282A36` | ![](https://placehold.co/16x16/f8f8f2/f8f8f2) `#F8F8F2` | ![](https://placehold.co/12x12/ff5555/ff5555) ![](https://placehold.co/12x12/50fa7b/50fa7b) ![](https://placehold.co/12x12/f1fa8c/f1fa8c) ![](https://placehold.co/12x12/bd93f9/bd93f9) ![](https://placehold.co/12x12/ff79c6/ff79c6) ![](https://placehold.co/12x12/8be9fd/8be9fd) |
| **Gruvbox Dark** | ![](https://placehold.co/16x16/282828/282828) `#282828` | ![](https://placehold.co/16x16/ebdbb2/ebdbb2) `#EBDBB2` | ![](https://placehold.co/12x12/cc241d/cc241d) ![](https://placehold.co/12x12/98971a/98971a) ![](https://placehold.co/12x12/d79921/d79921) ![](https://placehold.co/12x12/458588/458588) ![](https://placehold.co/12x12/b16286/b16286) ![](https://placehold.co/12x12/689d6a/689d6a) |
| **Tokyo Night** | ![](https://placehold.co/16x16/1a1b26/1a1b26) `#1A1B26` | ![](https://placehold.co/16x16/c0caf5/c0caf5) `#C0CAF5` | ![](https://placehold.co/12x12/f7768e/f7768e) ![](https://placehold.co/12x12/9ece6a/9ece6a) ![](https://placehold.co/12x12/e0af68/e0af68) ![](https://placehold.co/12x12/7aa2f7/7aa2f7) ![](https://placehold.co/12x12/bb9af7/bb9af7) ![](https://placehold.co/12x12/7dcfff/7dcfff) |
| **Nord** | ![](https://placehold.co/16x16/2e3440/2e3440) `#2E3440` | ![](https://placehold.co/16x16/d8dee9/d8dee9) `#D8DEE9` | ![](https://placehold.co/12x12/bf616a/bf616a) ![](https://placehold.co/12x12/a3be8c/a3be8c) ![](https://placehold.co/12x12/ebcb8b/ebcb8b) ![](https://placehold.co/12x12/81a1c1/81a1c1) ![](https://placehold.co/12x12/b48ead/b48ead) ![](https://placehold.co/12x12/88c0d0/88c0d0) |
| **One Half Dark** | ![](https://placehold.co/16x16/282c34/282c34) `#282C34` | ![](https://placehold.co/16x16/dcdfe4/dcdfe4) `#DCDFE4` | ![](https://placehold.co/12x12/e06c75/e06c75) ![](https://placehold.co/12x12/98c379/98c379) ![](https://placehold.co/12x12/e5c07b/e5c07b) ![](https://placehold.co/12x12/61afef/61afef) ![](https://placehold.co/12x12/c678dd/c678dd) ![](https://placehold.co/12x12/56b6c2/56b6c2) |
| **Solarized Dark** | ![](https://placehold.co/16x16/001e27/001e27) `#001E27` | ![](https://placehold.co/16x16/9cc2c3/9cc2c3) `#9CC2C3` | ![](https://placehold.co/12x12/d11c24/d11c24) ![](https://placehold.co/12x12/6cbe6c/6cbe6c) ![](https://placehold.co/12x12/a57706/a57706) ![](https://placehold.co/12x12/2176c7/2176c7) ![](https://placehold.co/12x12/c61c6f/c61c6f) ![](https://placehold.co/12x12/259286/259286) |
| **Monokai Soda** | ![](https://placehold.co/16x16/1a1a1a/1a1a1a) `#1A1A1A` | ![](https://placehold.co/16x16/c4c5b5/c4c5b5) `#C4C5B5` | ![](https://placehold.co/12x12/f4005f/f4005f) ![](https://placehold.co/12x12/98e024/98e024) ![](https://placehold.co/12x12/fa8419/fa8419) ![](https://placehold.co/12x12/9d65ff/9d65ff) ![](https://placehold.co/12x12/f4005f/f4005f) ![](https://placehold.co/12x12/58d1eb/58d1eb) |
| **Rosé Pine** | ![](https://placehold.co/16x16/191724/191724) `#191724` | ![](https://placehold.co/16x16/e0def4/e0def4) `#E0DEF4` | ![](https://placehold.co/12x12/eb6f92/eb6f92) ![](https://placehold.co/12x12/31748f/31748f) ![](https://placehold.co/12x12/f6c177/f6c177) ![](https://placehold.co/12x12/9ccfd8/9ccfd8) ![](https://placehold.co/12x12/c4a7e7/c4a7e7) ![](https://placehold.co/12x12/ebbcba/ebbcba) |
| **Kanagawa** | ![](https://placehold.co/16x16/1f1f28/1f1f28) `#1F1F28` | ![](https://placehold.co/16x16/dcd7ba/dcd7ba) `#DCD7BA` | ![](https://placehold.co/12x12/c34043/c34043) ![](https://placehold.co/12x12/76946a/76946a) ![](https://placehold.co/12x12/c0a36e/c0a36e) ![](https://placehold.co/12x12/7e9cd8/7e9cd8) ![](https://placehold.co/12x12/957fb8/957fb8) ![](https://placehold.co/12x12/6a9589/6a9589) |
| **Everforest Dark** | ![](https://placehold.co/16x16/1e2326/1e2326) `#1E2326` | ![](https://placehold.co/16x16/d3c6aa/d3c6aa) `#D3C6AA` | ![](https://placehold.co/12x12/e67e80/e67e80) ![](https://placehold.co/12x12/a7c080/a7c080) ![](https://placehold.co/12x12/dbbc7f/dbbc7f) ![](https://placehold.co/12x12/7fbbb3/7fbbb3) ![](https://placehold.co/12x12/d699b6/d699b6) ![](https://placehold.co/12x12/83c092/83c092) |

### Light

| Theme | Background | Foreground | Palette preview |
|-------|------------|------------|-----------------|
| **Catppuccin Latte** | ![](https://placehold.co/16x16/eff1f5/eff1f5) `#EFF1F5` | ![](https://placehold.co/16x16/4c4f69/4c4f69) `#4C4F69` | ![](https://placehold.co/12x12/d20f39/d20f39) ![](https://placehold.co/12x12/40a02b/40a02b) ![](https://placehold.co/12x12/df8e1d/df8e1d) ![](https://placehold.co/12x12/1e66f5/1e66f5) ![](https://placehold.co/12x12/ea76cb/ea76cb) ![](https://placehold.co/12x12/179299/179299) |
| **Solarized Light** | ![](https://placehold.co/16x16/fdf6e3/fdf6e3) `#FDF6E3` | ![](https://placehold.co/16x16/657b83/657b83) `#657B83` | ![](https://placehold.co/12x12/dc322f/dc322f) ![](https://placehold.co/12x12/859900/859900) ![](https://placehold.co/12x12/b58900/b58900) ![](https://placehold.co/12x12/268bd2/268bd2) ![](https://placehold.co/12x12/d33682/d33682) ![](https://placehold.co/12x12/2aa198/2aa198) |
| **Gruvbox Light** | ![](https://placehold.co/16x16/fbf1c7/fbf1c7) `#FBF1C7` | ![](https://placehold.co/16x16/3c3836/3c3836) `#3C3836` | ![](https://placehold.co/12x12/cc241d/cc241d) ![](https://placehold.co/12x12/98971a/98971a) ![](https://placehold.co/12x12/d79921/d79921) ![](https://placehold.co/12x12/458588/458588) ![](https://placehold.co/12x12/b16286/b16286) ![](https://placehold.co/12x12/689d6a/689d6a) |
| **One Half Light** | ![](https://placehold.co/16x16/fafafa/fafafa) `#FAFAFA` | ![](https://placehold.co/16x16/383a42/383a42) `#383A42` | ![](https://placehold.co/12x12/e45649/e45649) ![](https://placehold.co/12x12/50a14f/50a14f) ![](https://placehold.co/12x12/c18401/c18401) ![](https://placehold.co/12x12/0184bc/0184bc) ![](https://placehold.co/12x12/a626a4/a626a4) ![](https://placehold.co/12x12/0997b3/0997b3) |

> If no theme is set, the Tilda palette is used.

## Known limitations

### Windows
- **F1 hotkey does not fire over elevated apps**: while an elevated (Admin) app like Task Manager or regedit has focus, F1 has no effect. This is enforced by Windows UIPI (User Interface Privilege Isolation). Running TildaZ elevated works around it, but is not recommended.

### macOS
- **Ad-hoc codesign reissues identity per rebuild** — Input Monitoring / Accessibility grants must be re-enabled after each rebuild during development. Notarized releases ([#109](https://github.com/ensky0/tildaz/issues/109)) will fix this.
- **`IMKCFRunLoopWakeUpReliable` stderr noise** — macOS IMK (Input Method Kit) emits this line via the system framework. Cannot be suppressed without redirecting all stderr; harmless. Same line appears in Ghostty, iTerm2, etc.
- **`SF Mono` not registered by default** — Apple's user-facing "SF Mono" font is shipped with Xcode. Without Xcode (or manual install from the Apple Developer Fonts download), `["SF Mono"]` resolves to a substitute via CoreText; TildaZ rejects substitutes (strict family-name validation) so the config error is surfaced cleanly. The default chain `["Menlo"]` always works.
- **macOS-specific glyph fallback** — codepoints outside the configured font.family chain still resolve via CoreText system auto fallback (Apple Color Emoji, Apple SD Gothic Neo, Apple Symbols, etc.). On Windows the chain must explicitly include a font for every script you want to display.

## Architecture

TildaZ runs as a native host on Windows and macOS, sharing cross-platform
session / VT / config / dialog / themes / terminal-interaction / tab-interaction
modules. Platform seams are the host (`windows_host.zig` / `macos_host.zig`),
the PTY backend (ConPTY / POSIX), the window layer (Win32 / NSWindow), and the
renderer (Direct3D 11 / Metal). The architecture review history lives in
[#91](https://github.com/ensky0/tildaz/issues/91); the cross-platform behavior
matrix lives in [SPEC.md](SPEC.md).

### Windows pipeline

1. `windows_host.zig` — DPI awareness, single-instance, config, autostart, window, renderer, initial tab
2. `window.zig` — Win32 messages → `app_event.zig`
3. `app_controller.zig` — event → tab / session / selection / rename / scroll
4. `session_core.zig` — tab list, active tab, scrollback, VT drain, PTY queue
5. `terminal_backend.zig` → `conpty.zig` (bundled `conpty.dll` / `OpenConsole.exe`, fallback to `kernel32 CreatePseudoConsole`)
6. PTY read thread → lock-free ring buffer → render callback drains through ghostty VT parser
7. `renderer_backend.zig` → `d3d11_renderer.zig` (DirectWrite + Direct3D 11 / HLSL, dynamic glyph atlas)

### macOS pipeline

1. `macos_host.zig` — NSApplication accessory mode, NSWindow at popUpMenu level (101), CGEventTap for global hotkey, render timer via CFRunLoopTimer
2. `macos_pty.zig` — POSIX PTY (`openpty` + `login_tty` + IUTF8). SIGHUP-ignoring shells get SIGKILL after a 500 ms grace
3. Same cross-platform `session_core` analog (`macos_session.zig`) — schema-compatible with Windows `session_core`
4. `macos_metal.zig` — Metal renderer (CAMetalLayer + MTLCommandQueue), retina-aware glyph atlas
5. `macos_font.zig` — CoreText with explicit *glyph fallback chain* (config.font.family) + system auto fallback (`CTFontCreateForString`) for codepoints outside the chain
6. NSTextInputClient implementation for IME (Korean / Japanese / Chinese composition) — inline pre-edit overlay, syllable-boundary commit
7. macOS quirks tracked in [AGENTS.md § macOS Cocoa quirks](AGENTS.md): `atexit()` for `[exit]` log line (NSApp `terminate:` skips `defer`), `ApplePressAndHoldEnabled = false` for English key repeat, NSAlert TextView selection-auto-copy for Cmd+C routing, etc.

### Why these choices

**ConPTY / OpenConsole** (Windows). ConPTY is the standard for attaching both
legacy Console-API apps and VT-based apps to an external terminal window. TildaZ
bundles OpenConsole to flatten out system-conhost version variance and falls back
to `kernel32 CreatePseudoConsole` when the bundle is missing.

**POSIX PTY + login_tty** (macOS). `login_tty` makes the child a new session
leader so `kill(-pid, SIGHUP)` cleans up the whole process group on tab close.
IUTF8 termios bit is set so multi-byte input does not mangle Korean / Japanese
keystrokes.

**Direct3D 11 / Metal**. GPU-accelerated rendering is necessary for bulk output
+ deep scrollback to keep up with modern terminals (Windows Terminal, WezTerm,
Ghostty, Alacritty). Both backends rasterize through the platform's native
text engine (DirectWrite / CoreText), atlas glyphs once, and re-blit textured
quads per frame.

**Cross-platform native first**. Each OS's modifiers / shortcut order /
config-file conventions follow the platform standard rather than a forced
identical UX (Apple HIG `Shift+Cmd` order on macOS, Windows `Ctrl+Shift`;
`%APPDATA%\tildaz\` on Windows, XDG `~/.config/tildaz/` on macOS). See
[AGENTS.md § cross-platform 앱이지만 platform native 동작 우선](AGENTS.md).

### Open structural work

- Cross-platform `config.zig` unification ([#118](https://github.com/ensky0/tildaz/issues/118)) — schemas already compatible at the field level, the parser file is still split.
- macOS Developer ID code signing + notarization ([#109](https://github.com/ensky0/tildaz/issues/109)) — currently ad-hoc signed; per-rebuild identity changes invalidate Input Monitoring / Accessibility grants.
- Linux backend (Wayland / X11) — not yet started.
- Stress tests for bulk output, resize storms, output-pipe-full during tab close, WSL/nvim/mouse, and CJK/emoji/combining marks should be pinned down separately.

## Tech stack

| Component | Windows | macOS |
|-----------|---------|-------|
| Language | Zig 0.15.2 | Zig 0.15.2 |
| Terminal emulation | [libghostty-vt](https://github.com/ghostty-org/ghostty) | [libghostty-vt](https://github.com/ghostty-org/ghostty) |
| PTY backend | ConPTY (`conpty.zig`) | POSIX (`macos_pty.zig`) — `openpty` + `login_tty` + IUTF8 |
| PTY host | Bundled `OpenConsole.exe` + `conpty.dll` ([microsoft/terminal](https://github.com/microsoft/terminal), MIT); falls back to system conhost | (kernel) |
| Window | Win32 API (borderless popup) | NSWindow (popUpMenu level 101) |
| Hotkey | `RegisterHotKey` | CGEventTap (Input Monitoring + Accessibility) |
| Renderer | Direct3D 11 + HLSL (ClearType subpixel) | Metal + CoreText |
| Font | DirectWrite — explicit glyph fallback chain | CoreText — explicit glyph fallback chain + system auto fallback |
| IME | Win32 IMM | NSTextInputClient (markedText pre-edit) |
| Autostart | HKCU `Run` registry entry | LaunchAgent plist (`~/Library/LaunchAgents/com.tildaz.app.plist`) |
| Log path | `%APPDATA%\tildaz\tildaz.log` | `~/Library/Logs/tildaz.log` (Console.app indexed) |
| Config path | `%APPDATA%\tildaz\config.json` | `~/.config/tildaz/config.json` (XDG) |

## Performance

Measured at v0.2.6. All numbers are median of 3 runs of
`time cat ~/repo/s2t/bitext_eng_kor.vocab` (1.14 MiB CJK) inside WSL Debian,
with the window snapped to the left half of the screen (same grid as Windows
Terminal for comparability).

| Path | `time cat` real | Throughput | vs WT |
|------|-----------------|------------|-------|
| baseline v0.2.5 (system conhost) | 0.293s | ~4.7 MiB/s | 3.2× slower |
| #77 overlapped 128KB read | 0.266s | ~5.2 MiB/s | 2.9× slower |
| #78 bundled OpenConsole (with regression) | 0.133s | ~10.5 MiB/s | 1.4× slower |
| **v0.2.6 (#77 + #78 + #79)** | **0.074s** | **~15.4 MiB/s** | **1.26× faster** |
| Windows Terminal (reference, same grid) | 0.093s | ~12.3 MiB/s | 1.0× |

- **#77** — Replace ConPTY output pipe with a named pipe + `FILE_FLAG_OVERLAPPED`, 128KB overlapped `ReadFile` + `GetOverlappedResult` pattern. Per-stage atomic counters in `src/perf.zig` collected continuously; snapshot via Ctrl+Shift+P.
- **#78** — Ship `OpenConsole.exe` (1.04 MB) + `conpty.dll` (110 KB) from Microsoft.Windows.Console.ConPTY nuget `1.24.260303001` under `vendor/conpty/`. At startup, `LoadLibraryW("conpty.dll")` is tried; on success `ConptyCreatePseudoConsole` replaces the kernel32 version. Missing DLL falls back to kernel32. This pinned down that the actual bottleneck was system conhost's internal flush timing.
- **#79** — Fix a regression where the bundled OpenConsole's `VtIo::StartIfNeeded` waits up to 3 seconds for a DA1 response (`\x1b[c`) at startup. (a) Pre-write `\x1b[?61c` (VT500 conformance) to the input pipe immediately after `CreateProcessW`, (b) call `ConptyShowHidePseudoConsole(true)` before `CreateProcessW`. Tab cold start ~3997ms → **~548ms**; as a side effect `time cat` improved from 0.133s → 0.074s (the VT engine was not fully initialized during the DA1 wait, propagating delay into the data path).

Tab startup time (`"wsl.exe -d Debian --cd ~"`, warm):

| Path | Prompt visible |
|------|----------------|
| baseline (kernel32, system conhost) | ~860 ms |
| right after #78 (bundled OpenConsole, regression) | ~3997 ms |
| **v0.2.6 (#78 + #79)** | **~548 ms** |
| lower bound for raw `wsl + bash interactive` | ~480 ms |

## Distribution and code signing

### Windows — current state: **unsigned build**

Through v0.2.13, GitHub Release Windows binaries are not Authenticode-signed. Some Windows Defender / Endpoint Security products (CrowdStrike, SentinelOne, etc.) flag the combination of unsigned binary + ConPTY-based child process spawn + multi-threading as suspicious behavior and can block execution.

If your AV/EDR flags `tildaz.exe`:

- With admin rights, add a SHA256 allowlist exception in your EDR
- On a corporate-managed PC, file a false-positive report with your security team
- Or copy the binary to a local-disk path (e.g. `%LOCALAPPDATA%\Programs\tildaz\`) before running — execution from UNC paths is scored as more suspicious

Plan: applying to the [SignPath Foundation open-source code-signing program](https://about.signpath.io/foundation). Once approved, future releases will ship with an Authenticode-signed `tildaz.exe`.

### macOS — current state: **ad-hoc signed build**

The Zig build runs `codesign --sign - --force --timestamp=none` on `TildaZ.app`. This is enough for the app to launch from `/usr/bin/open`, but Apple Developer ID signing + notarization (which would let users skip the Gatekeeper warning) is blocked by corporate keychain policy in the current build environment ([#109](https://github.com/ensky0/tildaz/issues/109)). When unblocked, releases will ship as a signed + notarized `.app` (zip or dmg) and Input Monitoring / Accessibility grants will persist across rebuilds (instead of being invalidated by the per-build ad-hoc identity).

## Privacy

TildaZ does not collect, transmit, or store any user data.

- No telemetry, analytics, or crash reporting
- No automatic update checks
- No network requests of any kind from `tildaz.exe` / `tildaz` itself
- All state is local only:
  - Config: `%APPDATA%\tildaz\config.json` (Windows) · `~/.config/tildaz/config.json` (macOS)
  - Log: `%APPDATA%\tildaz\tildaz.log` (Windows) · `~/Library/Logs/tildaz.log` (macOS) — boot / exit / errors / perf snapshots; never transmitted
- Optional autostart:
  - Windows: HKCU `Run` entry, read locally by the Windows shell
  - macOS: LaunchAgent plist, read locally by `launchd`

Child shells spawned by TildaZ (cmd, PowerShell, wsl, bash, zsh, etc.) are independent processes; their own network and data behavior is governed by the user's operating system and shell configuration, not by TildaZ.

## License

TildaZ is **AGPL-3.0-or-later** — see [`LICENSE`](./LICENSE) for the full text. The network clause (AGPL §13) means that offering TildaZ as a network-accessible service also requires source availability under the same license.

### Bundled / linked third-party

| Component | License | Source | Notes |
|-----------|---------|--------|-------|
| `libghostty-vt` | MIT | [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty) | Fetched as the `ghostty` dep in `build.zig.zon` and statically linked into `tildaz.exe` |
| `OpenConsole.exe` | MIT | [microsoft/terminal](https://github.com/microsoft/terminal) (Microsoft.Windows.Console.ConPTY nuget 1.24.260303001) | Bundled in the release zip — `vendor/conpty/LICENSE.txt` |
| `conpty.dll` | MIT | same | same |

Full MIT text lives in each upstream repo and in the bundled `LICENSE.txt`.
