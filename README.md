# TildaZ

Quake-style drop-down terminal for Windows and macOS, built on Zig and libghostty-vt.

Brings the UX of Linux's [Tilda](https://github.com/lanoxx/tilda) to Windows and macOS.

**Website**: https://ensky0.github.io/tildaz/

> **v0.3.3 — Terminal.app-grade rendering on macOS, Windows Terminal-grade emoji on Windows**
>
> macOS now matches Apple's Terminal.app on glyph weight, baseline alignment,
> and block-element gradients, and the F1 hotkey + Cmd+Q routing are reliable
> across long sessions and app focus changes. Windows brings its color emoji
> path up to Windows Terminal quality (premultiplied dual-source blend,
> DPI-correct cluster placement, default font metrics overhauled). See
> [`dist/release-notes/v0.3.3.md`](dist/release-notes/v0.3.3.md) for the full
> changelog. The v0.3.0 cross-platform parity baseline is documented in
> [`dist/release-notes/v0.3.0.md`](dist/release-notes/v0.3.0.md).

## Features

- **Global hotkey** — toggle the terminal show/hide system-wide. Default F1, configurable per-platform via `config.hotkey`
- **Fullscreen** — Alt+Enter on Windows, current-monitor work area (excluding taskbar / Dock). Fullscreen state is preserved across hide → show cycles and re-applied on display / DPI changes
- **Tabs** — multiple independent terminal sessions; click to select, X to close, drag to reorder, double-click to rename. Shortcuts in [KEYBINDINGS.md](KEYBINDINGS.md)
- **Full Unicode support** — Hangul, CJK, emoji (color, ZWJ family), combining marks, wide / narrow cells
- **Font glyph fallback chain** — up to 8 font families; *per-codepoint* lookup walks the chain to find a font with the glyph. Both platforms fall through to OS system fallback for codepoints outside the chain. See [CONFIG.md](CONFIG.md) for the schema.
- **GPU-accelerated rendering**
  - Windows: ClearType subpixel via DirectWrite + Direct3D 11 / HLSL shaders
  - macOS: Metal + CoreText, retina (2x) glyph atlas
- **Bundled OpenConsole** (Windows) — ships `OpenConsole.exe` + `conpty.dll` to bypass `conhost.exe`. 1.26× faster than system conhost on bulk output
- **POSIX PTY** (macOS) — `openpty` + `login_tty` + IUTF8 termios. SIGHUP-ignoring shells (`nohup`, `trap '' HUP`) get SIGKILL after a 500 ms grace
- **ANSI colors** — 16 / 256 / TrueColor foreground and background, bold-is-bright, inverse
- **18 built-in color themes** — see [THEMES.md](THEMES.md)
- **Text selection and copy** — drag-select with auto-copy on release, double-click for word, right-click to paste
- **Scrollback** — mouse wheel, scrollbar drag (configurable up to 10 M lines)
- **IME** (Korean / Japanese / Chinese) — inline pre-edit on the cursor, syllable-boundary commit, Ctrl+key during composition discards the pre-edit and aborts cleanly
- **Multi-monitor follow** — drops onto whichever monitor the cursor is on; auto-reapplies on resolution / DPI / taskbar change
- **Translucent**, always-on-top window (configurable opacity)
- **About dialog** — Ctrl+Shift+I (Windows) / Shift+Cmd+I (macOS). Shows version / exe path / pid / config path / log path
- **Open config / log** — Ctrl+Shift+P / Ctrl+Shift+L (Windows), Shift+Cmd+P / Shift+Cmd+L (macOS)
- **Auto-start on login** — Registry Run on Windows, LaunchAgent on macOS
- **Quit confirmation** — `Cmd+Q` / `Alt+F4` shows a dialog with the open-tab count

## System requirements

| Platform | Minimum |
|---|---|
| **Windows** | Windows 10 (1903) or later, x64. ARM64 is not yet supported. |
| **macOS** | macOS 13 Ventura or later. The release DMG ships a universal binary that runs natively on Apple Silicon (M1/M2/M3/...) and Intel Macs. |

## Install

Download from [Releases](https://github.com/ensky0/tildaz/releases/latest):

| Platform | File | How |
|---|---|---|
| Windows | `tildaz-vX.Y.Z-windows.zip` | Unzip anywhere. Keep `tildaz.exe`, `conpty.dll`, and `OpenConsole.exe` together. Run `tildaz.exe`. |
| macOS | `tildaz-vX.Y.Z-macos.dmg` | Open the DMG, drag `TildaZ.app` into Applications. |

**macOS first-launch**: the app is ad-hoc signed, so Gatekeeper may block the
first open. Right-click `TildaZ.app` → Open, or run
`xattr -d com.apple.quarantine /Applications/TildaZ.app`. Then grant
**Input Monitoring** + **Accessibility** in System Settings → Privacy &
Security (needed for the global hotkey and Cmd+Q).

First launch writes the default config: `%APPDATA%\tildaz\config.json` on
Windows, `~/.config/tildaz/config.json` on macOS. See [CONFIG.md](CONFIG.md)
for the schema.

## Try it — Unicode showcase

Drop this one-liner into a tab to exercise color emoji, skin-tone modifiers,
ZWJ family clusters, Latin / Hangul wide characters, and Unicode block
elements all at once. Useful for a side-by-side comparison with another
terminal:

```sh
echo -e "\n🎉❤️🌈🎨🌞🍎🚀💎✨\n👋🏻👋🏼👋🏽👋🏾👋🏿\n👨‍👩‍👧👨‍👨‍👦‍👦\nABCDEFG abcdefg 0123456789\n한글 ABC 가나다라마바사\n▀▁▂▃▄▅▆▇█▉▊▋▌▍▎▏\n▐░▒▓▔▕\n"
```

Works in any POSIX shell (bash / zsh on Linux / macOS / WSL). PowerShell and
`cmd` variants are documented in [AGENTS.md § 터미널 시각 회귀 테스트](AGENTS.md).

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

# release artifact
zig build package
# Windows -> zig-out/release/tildaz-v<ver>-windows.zip + .sha256
# macOS   -> zig-out/release/tildaz-v<ver>-macos.dmg
```

Output paths:
- Windows: `zig-out/bin/tildaz.exe`
- macOS: `zig-out/TildaZ.app` (codesigned ad-hoc — see [ARCHITECTURE.md § Distribution](ARCHITECTURE.md))

> **Note**: the SIMD option (`-Dsimd=true`) currently does not work on Windows.
> Zig 0.15's build system does not pass C++ stdlib include paths through to
> ghostty's C++ SIMD sources. Upstream fix required ([#19](https://github.com/ensky0/tildaz/issues/19)).

When building a WSL checkout from Windows, use the `\\wsl$\Debian\...` UNC
path. `\\wsl.localhost\Debian\...` can trip security products or exhibit
different Windows network-path behavior that blocks the executable.

### Tag + release

```bash
# pre-req: bump tildaz_version in build.zig + src/tildaz.rc, commit
dist/release.sh --version 0.3.0              # normal flow (tag push → Actions)
dist/release.sh --version 0.3.0 --dry-run    # build/package rehearsal, no tag push
```

A tag push triggers `.github/workflows/release.yml` on `windows-2022` +
`macos-15` runners, which run `zig build package` → upload the zip / DMG +
sha256 → attach `dist/release-notes/v<ver>.md` as the Release body. The
release-notes file **must exist on the tag** — the pre-flight check fails
otherwise.

## Documentation

| Topic | File |
|---|---|
| Configuration schema + examples | [CONFIG.md](CONFIG.md) |
| Keybindings | [KEYBINDINGS.md](KEYBINDINGS.md) |
| Built-in themes | [THEMES.md](THEMES.md) |
| Architecture, tech stack, performance, distribution | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Cross-platform behavior matrix (Korean) | [SPEC.md](SPEC.md) |
| Contributing / agent guidance (Korean) | [AGENTS.md](AGENTS.md) |
| Security policy | [SECURITY.md](SECURITY.md) |
| Release notes | [`dist/release-notes/`](dist/release-notes/) |

## Known limitations

### Windows

- **F1 hotkey does not fire over elevated apps**: while an elevated (Admin) app like Task Manager or regedit has focus, F1 has no effect. Enforced by Windows UIPI (User Interface Privilege Isolation). Running TildaZ elevated works around it, but is not recommended.

### macOS

- **Ad-hoc codesign reissues identity per rebuild** — Input Monitoring / Accessibility grants must be re-enabled after each rebuild during development. Notarized releases ([#109](https://github.com/ensky0/tildaz/issues/109)) will fix this.
- **`IMKCFRunLoopWakeUpReliable` stderr noise** — macOS IMK (Input Method Kit) emits this line via the system framework. Cannot be suppressed without redirecting all stderr; harmless. Same line appears in Ghostty, iTerm2, etc.
- **`SF Mono` not registered by default** — Apple's user-facing "SF Mono" font is shipped with Xcode. Without Xcode (or manual install from Apple Developer Fonts), `["SF Mono"]` resolves to a substitute via CoreText; TildaZ rejects substitutes (strict family-name validation) so the config error is surfaced cleanly. The default chain `["Menlo"]` always works.
- **Emoji & Symbols picker is a floating panel, not a cursor-anchored popover** — `Ctrl+Cmd+Space` opens the picker, but it appears as a free-floating window in its last-used position rather than anchored next to the text cursor, and macOS does not auto-dismiss it on focus loss. Press `Esc` or `Ctrl+Cmd+Space` again to dismiss. macOS reserves the popover path for `NSTextView`-based first responders (Terminal.app, TextEdit, Notes, Mail). Every modern fast terminal on macOS — Ghostty, iTerm2, Alacritty, Kitty — shares this limitation; the cell-grid + GPU-atlas + custom-IME architecture they all use is fundamentally incompatible with `NSTextView`. ([#130](https://github.com/ensky0/tildaz/issues/130))
- **Holding `Cmd+V` to flood-paste a wide grapheme cluster (e.g. `👨‍👩‍👧`) under bash 3.2 stalls line wrap** — single pastes are fine; the issue only appears when `Cmd+V` is held down so the OS key-repeat fires ~30 times per second. ghostty's Mode 2027 (grapheme clustering) treats each ZWJ family as 2 cells, but bash 3.2's `wcwidth(3)` is cluster-unaware and reserves the codepoint-sum width (6 cells per family). The 4-cell mismatch per family eventually puts bash's internal cursor model past its wrap threshold; bash then emits `\r` + erase-line, and the next paste overwrites the same row. The trade-offs to fix it (disable Mode 2027 → broken family/skin-tone/VS-16 ligatures, or fork ghostty's grid model) are large for a workflow most users never hit, so this is a known limitation. macOS default shell is migrating to zsh 5.x, whose line editor is grapheme-cluster-aware and doesn't exhibit the mismatch. ([#141](https://github.com/ensky0/tildaz/issues/141))

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
| `libghostty-vt` | MIT | [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty) | Fetched as the `ghostty` dep in `build.zig.zon` and statically linked into `tildaz.exe` / `tildaz` |
| `OpenConsole.exe` | MIT | [microsoft/terminal](https://github.com/microsoft/terminal) (Microsoft.Windows.Console.ConPTY nuget 1.24.260303001) | Bundled in the Windows release zip — `vendor/conpty/LICENSE.txt` |
| `conpty.dll` | MIT | same | same |

Full MIT text lives in each upstream repo and in the bundled `LICENSE.txt`.
