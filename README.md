# TildaZ

Quake-style drop-down terminal for Windows, built on Zig and libghostty-vt.

Brings the UX of Linux's [Tilda](https://github.com/lanoxx/tilda) to Windows.

**Website**: https://ensky0.github.io/tildaz/

> **v0.2.12 — architecture cleanup release**
>
> Reviewed TildaZ against Windows Terminal and WezTerm and separated the
> boundaries for input events, session/tab, terminal backend, Windows host,
> build target, and renderer backend. The core Windows choice —
> **OpenConsole/ConPTY + ghostty VT + Direct3D 11 renderer** — stays the same,
> but the seams are now in place to add macOS/Linux backends later.
> See [Architecture](#architecture) for details.

## Features

- **F1** global hotkey toggles the terminal show/hide
- **Alt+Enter** toggles current-monitor fullscreen (work area = excluding taskbar). Fullscreen state is preserved across F1 hide → F1 show cycles and re-applied on display / DPI / work-area changes
- **Tabs** — multiple independent terminal sessions
  - Ctrl+Shift+T to open a new tab
  - Ctrl+Shift+W to close the active tab
  - Alt+1~9 to switch between tabs
  - Click to select, X button to close
  - Drag to reorder
  - Closing the last tab quits the app
- **Full Unicode support** — correct rendering for Hangul, CJK, emoji and other wide/narrow character sets
- **Font glyph fallback chain** — up to 8 font families; *per-codepoint* lookup walks the chain to find a font that has the glyph (e.g. Latin → Cascadia Mono, Hangul → Malgun Gothic, symbols → Segoe UI Symbol)
- **ClearType subpixel rendering** — high-quality text via DirectWrite + Direct3D 11 shaders
- **Bundled OpenConsole** — ships `OpenConsole.exe` + `conpty.dll` to bypass the system `conhost.exe`. Bulk output throughput is 2.2× over system conhost; falls back to system conhost automatically when the bundled files are missing
- **ANSI colors** — 16 / 256 / TrueColor foreground and background, bold-is-bright, inverse
- **18 built-in color themes** — Tilda, Ghostty, Windows Terminal, Dracula, Catppuccin, and more
- **Text selection and copy**
  - Click-drag to select (selection inverted in place)
  - Double-click to select a word
  - Release mouse button → automatic clipboard copy
  - Middle-click to paste
- **Scrollback** — mouse wheel, scrollbar drag, up to 100,000 lines. Thumb stays at least 32px × DPI scale so it remains draggable even with deep scrollback
- **Vim dark/light detection** — sets `COLORFGBG` based on theme background luminance (propagated into WSL too)
- Drop-down docks to any screen edge (top/bottom/left/right)
- Size and offset specified as percentages of the screen
- **Multi-monitor follow**
  - Each F1 toggle drops onto **the monitor containing the mouse cursor**. Width / height / offset are recomputed against that monitor's work area (excluding the taskbar)
  - Resolution change / external monitor connect-disconnect / taskbar auto-hide toggle / per-monitor DPI change are all detected and re-applied immediately (`WM_DISPLAYCHANGE` / `WM_DPICHANGED` / `WM_SETTINGCHANGE`)
  - Moving to a different-DPI monitor re-rasters the GDI font, cell metrics, and DirectWrite glyph atlas at the new DPI so glyphs are drawn at the new monitor's pixel density
  - When the window rect is unchanged (e.g. unplugging an external monitor), the terminal grid is reflowed directly even though `WM_SIZE` never fires, so the full client area stays in sync with the new cell size
- Translucent (configurable), always-on-top window
- Ctrl+Shift+V to paste from clipboard
- Ctrl+Shift+R to reset the terminal (e.g. after `cat`-ing a binary)
- **Ctrl+Shift+I** About dialog — shows version / exe full path / pid in a MessageBox. Useful because the borderless window has no title bar to identify the running exe from
- **PE VERSIONINFO** — right-click `tildaz.exe` → Properties → Details shows the version
- **Unified log** `%APPDATA%\tildaz\tildaz.log` — boot / exit / ConPTY init / autostart errors / perf snapshots share a single timeline. Replaces the previous hard-coded `C:\tildaz_win\perf.log`
- Ctrl+Shift+P dumps a perf snapshot (ms / bytes / call counts per push / drain / parse / render / present stage) into `tildaz.log`
- **Auto-start on Windows login** — registers via `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`. (Through v0.2.7 this used Task Scheduler, but Group Policy / UAC settings caused `schtasks /create` to be denied and left stale entries behind permanently. v0.2.8 consolidated on Registry Run.)

## Build

### Requirements

- [Zig 0.15.2](https://ziglang.org/download/)

### Build commands

```bash
# default build (ReleaseFast)
zig build

# debug build
zig build -Doptimize=Debug
```

> **Note**: the SIMD option (`-Dsimd=true`) currently does not work on Windows.
> Zig 0.15's build system does not pass C++ stdlib include paths through to
> ghostty's C++ SIMD sources. Upstream fix required.

When building a WSL checkout from Windows, use the `\\wsl$\Debian\...` UNC
path. `\\wsl.localhost\Debian\...` can trip security products or exhibit
different Windows network-path behavior that blocks the executable. Build
output stays at the default `zig-out/bin`.

### Packaging (release zip)

Starting with v0.2.6 the release is a single zip with three files:

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

> **Schema status**: Windows and macOS schemas are being unified ([issue #118](https://github.com/ensky0/tildaz/issues/118)). The example below reflects the Windows schema. macOS currently uses a *flat* top-level (e.g. `"dock_position"` directly instead of `"window.dock_position"`); both will converge. See [SPEC.md §7](SPEC.md) for the up-to-date matrix.

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
    "size": 20,
    "line_height": 0.95,
    "cell_width": 1.2
  },
  "theme": "Tilda",
  "shell": "cmd.exe",
  "auto_start": true,
  "hidden_start": false,
  "max_scroll_lines": 100000
}
```

| Section | Key | Type | Range | Default | Description |
|---------|-----|------|-------|---------|-------------|
| window | dock_position | string | top, bottom, left, right | "top" | Dock edge |
| window | width | int | 10–100 | 50 | Width (% of screen) |
| window | height | int | 10–100 | 100 | Height (% of screen) |
| window | offset | int | 0–100 | 100 | Position along the edge (0 = start, 50 = center, 100 = end) |
| window | opacity | int | 0–100 | 100 | Window opacity (%) |
| font | family | string or string[] | — | ["Cascadia Mono", "Malgun Gothic", "Segoe UI Symbol"] | Font families (array = *glyph fallback chain* — per-codepoint lookup walks the list to find a font with the glyph; max 8). All listed families must exist on the system. |
| font | size | int | 8–72 | 20 | Font size (px) |
| font | line_height | float | 0.1–10.0 | 0.95 | Line-height multiplier (1.0 = default leading) |
| font | cell_width | float | 0.1–10.0 | 1.2 | Cell-width multiplier (1.0 = default advance) |
| — | theme | string | see [Themes](#themes) | "Tilda" | Color theme |
| — | shell | string | — | "cmd.exe" | Shell to spawn (e.g. `"wsl.exe -d Debian --cd ~"`) |
| — | auto_start | bool | true, false | true | Start on Windows login |
| — | hidden_start | bool | true, false | false | Start hidden |
| — | max_scroll_lines | int | 100–100,000 | 100,000 | Scrollback buffer (lines) |

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

| Key | Action |
|-----|--------|
| F1 | Toggle terminal show/hide (fullscreen state is preserved) |
| Alt+Enter | Toggle current-monitor fullscreen (work area) |
| Ctrl+Shift+T | Open a new tab |
| Ctrl+Shift+W | Close the active tab |
| Alt+1–9 | Switch tab |
| Ctrl+Shift+R | Reset the terminal (recover from broken state, e.g. after `cat` on a binary) |
| Ctrl+Shift+V | Paste from clipboard |
| Ctrl+Shift+I | About — version / exe full path / pid MessageBox |
| Ctrl+Shift+P | Dump a perf snapshot to `%APPDATA%\tildaz\tildaz.log` |
| Mouse drag | Select text + auto-copy |
| Double click | Select word + auto-copy |
| Mouse wheel | Scroll |
| Middle click | Paste from clipboard |

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

- **F1 hotkey does not fire over elevated apps**: while an elevated (Admin) app like Task Manager or regedit has focus, F1 has no effect. This is enforced by Windows UIPI (User Interface Privilege Isolation). Running TildaZ elevated works around it, but is not recommended.

## Architecture

TildaZ targets two goals at once: run efficiently as a Windows terminal host
today, and keep the boundary in place where a macOS/Linux backend can slot in
later. The review and refactoring history lives in
[#91](https://github.com/ensky0/tildaz/issues/91).

### Windows pipeline

The Windows execution path flows as follows:

1. `windows_host.zig` sets up DPI awareness, single-instance enforcement,
   config, autostart, window, renderer, and the initial tab.
2. `window.zig` translates Win32 messages into the app events defined in
   `app_event.zig`.
3. `app_controller.zig` receives app events and drives tab / session /
   selection / rename / scroll policy.
4. `session_core.zig` manages the tab list, the active tab, scrollback, VT
   drain, and the PTY input queue.
5. `terminal_backend.zig` selects the PTY backend per OS. On Windows, the
   ConPTY backend in `conpty.zig` is used; non-Windows platforms currently
   have an unsupported placeholder.
6. `conpty.zig` prefers bundled `conpty.dll` / `OpenConsole.exe` and falls
   back to `kernel32 CreatePseudoConsole` when the bundle is missing.
7. PTY output enters a lock-free ring buffer on the read thread; the render
   callback drains it through the ghostty VT parser.
8. `renderer_backend.zig` selects the renderer per OS. Windows uses the
   Direct3D 11 renderer in `d3d11_renderer.zig`; non-Windows platforms
   currently have an unsupported placeholder.

### Why these choices

**ConPTY / OpenConsole**

ConPTY is the standard way to attach both legacy Console-API apps and VT-based
apps to an external terminal window on Windows. TildaZ uses the bundled
OpenConsole path when `conpty.dll` is available (to flatten out
version-to-version differences in the system conhost) and falls back to the
system `kernel32` ConPTY otherwise. This trades a small amount of bundle
weight for deployment stability and compatibility coverage.

**Pipe / thread structure**

ConPTY input stays as a synchronous write pipe for simplicity; output is read
through a named pipe that supports overlapped I/O. The read thread and the
process-wait thread are separated so a full pipe cannot block the UI thread
directly. The ring buffer in `session_core.zig` is the buffer that decouples
the ConPTY read thread from the UI/render thread.

**Direct3D 11 renderer**

The Windows renderer rasterizes glyphs through DirectWrite and draws cells
and the glyph atlas through Direct3D 11 / HLSL. This outperforms
redrawing text through GDI every frame under bulk output and deep scrollback,
and matches the GPU-accelerated direction modern terminal emulators like
Windows Terminal and WezTerm have taken.

**Platform seams**

Phases 1–12 sequentially split out input events, session core, terminal
backend, app controller, Windows host, build target, and renderer backend.
Current Windows behavior is preserved, and adding macOS/Linux later is a
matter of swapping `unsupported_host.zig`, `terminal_backend.zig`,
`renderer_backend.zig`, and the window host layer.

### Open structural work

- Real macOS/Linux hosts and a POSIX PTY backend are not yet implemented.
- No non-Windows renderer (Metal / OpenGL / Vulkan / Skia) exists yet.
- No software renderer fallback when renderer init fails.
- The `ShowHide` and DA1 pre-response paths that track OpenConsole internals
  need regression tests whenever the bundled version is bumped.
- Stress tests for bulk output, resize storms, output-pipe-full during tab
  close, WSL/nvim/mouse, and CJK/emoji/combining marks should be pinned down
  separately.

## Tech stack

| Component | Choice |
|-----------|--------|
| Language | Zig 0.15.2 |
| Terminal emulation | [libghostty-vt](https://github.com/ghostty-org/ghostty) |
| PTY backend | `terminal_backend.zig` — Windows ConPTY, non-Windows placeholder |
| PTY host | Bundled `OpenConsole.exe` + `conpty.dll` ([microsoft/terminal](https://github.com/microsoft/terminal), MIT) · falls back to system conhost when missing |
| Window | Win32 API (borderless popup) |
| Renderer backend | `renderer_backend.zig` — Windows Direct3D 11, non-Windows placeholder |
| Rendering | Direct3D 11 + HLSL shaders (ClearType dual-source subpixel blending) |
| Font rasterizer | DirectWrite (dynamic glyph atlas + system font fallback) |

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

Current state: **unsigned build**

Through v0.2.13, GitHub Release binaries are not Authenticode-signed. Some Windows Defender / Endpoint Security products (CrowdStrike, SentinelOne, etc.) flag the combination of unsigned binary + ConPTY-based child process spawn + multi-threading as suspicious behavior and can block execution.

**If your AV/EDR flags `tildaz.exe`**:

- With admin rights, add a SHA256 allowlist exception in your EDR
- On a corporate-managed PC, file a false-positive report with your security team
- Or copy the binary to a local-disk path (e.g. `%LOCALAPPDATA%\Programs\tildaz\`) before running — execution from UNC paths is scored as more suspicious

**Plan**: applying to the [SignPath Foundation open-source code-signing program](https://about.signpath.io/foundation). Once approved, future releases will ship with an Authenticode-signed `tildaz.exe`, which should eliminate most EDR false positives. This section will track the progress.

## Privacy

TildaZ does not collect, transmit, or store any user data.

- No telemetry, analytics, or crash reporting
- No automatic update checks
- No network requests of any kind from `tildaz.exe` itself
- All state is local only:
  - Config: `%APPDATA%\tildaz\config.json`
  - Log: `%APPDATA%\tildaz\tildaz.log` (boot / exit / errors / perf snapshots; never transmitted)
- Optional autostart adds an entry to `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, read locally by the Windows shell

Child shells spawned by TildaZ (cmd, PowerShell, wsl, etc.) are independent processes; their own network and data behavior is governed by the user's operating system and shell configuration, not by TildaZ.

## License

TildaZ is **AGPL-3.0-or-later** — see [`LICENSE`](./LICENSE) for the full text. The network clause (AGPL §13) means that offering TildaZ as a network-accessible service also requires source availability under the same license.

### Bundled / linked third-party

| Component | License | Source | Notes |
|-----------|---------|--------|-------|
| `libghostty-vt` | MIT | [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty) | Fetched as the `ghostty` dep in `build.zig.zon` and statically linked into `tildaz.exe` |
| `OpenConsole.exe` | MIT | [microsoft/terminal](https://github.com/microsoft/terminal) (Microsoft.Windows.Console.ConPTY nuget 1.24.260303001) | Bundled in the release zip — `vendor/conpty/LICENSE.txt` |
| `conpty.dll` | MIT | same | same |

Full MIT text lives in each upstream repo and in the bundled `LICENSE.txt`.
