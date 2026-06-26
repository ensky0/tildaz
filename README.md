# TildaZ

**A native Quake-style drop-down terminal for Linux, macOS, and Windows.** Your
terminal, one key away. If you are looking for a Tilda alternative, a Guake /
Yakuake-style terminal, or a Wayland drop-down terminal that also follows you to
macOS and Windows, TildaZ brings that show-and-hide workflow to every desktop
you use.

Most drop-down terminals stop at one OS, one toolkit, or one Linux desktop.
TildaZ is one native app across Linux, macOS, and Windows. On Linux it brings a
real drop-down with a global hotkey to **every major desktop**: KDE Plasma,
GNOME, Cinnamon, COSMIC, Hyprland, and sway. No Electron, no GTK or Qt runtime
dependency — just a terminal that appears when you need it and disappears when
you do not.

**Website**: https://ensky0.github.io/tildaz/ ·
**Download**: https://github.com/ensky0/tildaz/releases/latest

> **v0.5.2 — box-drawing and dim text rendered the way Windows Terminal does.**
> One drop-down terminal for Linux (Wayland), macOS, and Windows. Box-drawing
> characters (the lines and borders TUIs draw) now render as continuous procedural
> strokes, faint/dim text (SGR 2) dims toward the background, and the scrollbar is
> wider and easier to grab — all verified across KDE Plasma, GNOME, Cinnamon,
> COSMIC, Hyprland, sway, macOS, and Windows.

## Who is TildaZ for?

- **You want a Tilda alternative that follows you across OSes.** TildaZ keeps
  the Quake-style drop-down workflow on Linux, macOS, and Windows instead of
  tying it to one desktop.
- **You like the Guake / Yakuake reflex.** Press one hotkey, get a real terminal
  over your current workspace, press it again, and get back to what you were
  doing.
- **You need a Wayland drop-down terminal.** TildaZ has real drop-down and global
  hotkey paths across KDE Plasma, GNOME, Cinnamon, COSMIC, Hyprland, and sway.
- **You want familiar config everywhere.** Config paths differ by platform, but
  the JSON schema, themes, hotkey, font, shell, opacity, and geometry settings
  stay familiar.

## Why TildaZ

- **One key between thought and shell.** Drop the terminal over your current workspace, run the command, and hide it again before your flow cools off.
- **Same reflex, every OS.** The same drop-down terminal on Linux, macOS, and Windows — one JSON config shape, one muscle memory.
- **Familiar config everywhere.** Config paths differ by platform, but the schema, themes, hotkey, font, shell, opacity, and geometry settings stay familiar.
- **Wayland coverage that matters.** KDE Plasma, GNOME, Cinnamon, COSMIC, Hyprland, and sway all get a real drop-down and global hotkey path.
- **Native where it counts.** No Electron, no GTK or Qt runtime dependency — direct Wayland on Linux, GPU rendering on macOS and Windows, and the fast `libghostty-vt` core.
- **Pretty TUIs, serious text.** Tabs, themes, true color, ligatures, color emoji, full CJK, procedural box-drawing, smooth shaded blocks, and inline IME for Korean / Japanese / Chinese.
- **Personal, not nosy.** No telemetry, no analytics, no auto-update phone-home — only local config and logs.

## See it render

Ligatures, true color, color emoji with skin tones and ZWJ families, full-width
CJK, smoothly-shaded block glyphs (`░▒▓` now use smooth alpha instead of a dot
dither), and procedural box-drawing (continuous lines, corners, and rounded
joints — drawn the way Windows Terminal does) all render correctly — identically
on Linux, macOS, and Windows. Paste this into any TildaZ window:

```sh
echo -e "\n🎉❤️🌈🎨🌞🍎🚀💎✨\n👋🏻👋🏼👋🏽👋🏾👋🏿\n👨‍👩‍👧👨‍👨‍👦‍👦\nABCDEFG abcdefg 0123456789\n한글 ABC 가나다라마바사\n▀▁▂▃▄▅▆▇█▉▊▋▌▍▎▏\n▐░▒▓▔▕\n┌─┬─┐ ╔═╦═╗ ╭───╮\n├─┼─┤ ╠═╬═╣ │░▒▓│\n└─┴─┘ ╚═╩═╝ ╰───╯\n"
```

## Install

Download the latest artifact from
[GitHub Releases](https://github.com/ensky0/tildaz/releases/latest).

| Platform | Artifact | Notes |
|---|---|---|
| Linux (any distro) — portable | `tildaz-vX.Y.Z-linux-{x86_64,aarch64}.tar.gz` | Extract, then `./install.sh` installs the `.desktop` and icon under `~/.local/share`. The binary stays in the extracted directory by default. |
| Linux Debian / Ubuntu | `tildaz_X.Y.Z_{amd64,arm64}.deb` | `sudo dpkg -i tildaz_*.deb` (or open with the Software app). |
| Linux Fedora / RHEL / openSUSE | `tildaz-X.Y.Z-1.{x86_64,aarch64}.rpm` | `sudo dnf install ./tildaz-*.rpm` (or `rpm -Uvh`). |
| Linux distro-independent — single file | `TildaZ-X.Y.Z-{x86_64,aarch64}.AppImage` | `chmod +x TildaZ-*.AppImage && ./TildaZ-*.AppImage` — runs on any glibc 2.28+ system. |
| Linux Arch / Manjaro / EndeavourOS | `tildaz-X.Y.Z-1-x86_64.pkg.tar.zst` | `sudo pacman -U tildaz-*.pkg.tar.zst` (x86_64). |
| macOS 14+ universal | `tildaz-vX.Y.Z-macos.dmg` | Drag `TildaZ.app` into Applications. Apple Silicon and Intel are both included. |
| Windows 10 1903+ x64 | `tildaz-vX.Y.Z-win-x64.zip` | Unzip anywhere and keep `tildaz.exe`, `conpty.dll`, and `OpenConsole.exe` together. |
| Windows 11 ARM64 | `tildaz-vX.Y.Z-win-arm64.zip` | Same layout as the x64 zip with ARM64-native binaries. |

First launch creates the default config:

| Platform | Config | Log |
|---|---|---|
| Linux | `~/.config/tildaz/config.json` | `~/.local/state/tildaz/tildaz.log` |
| macOS | `~/.config/tildaz/config.json` | `~/Library/Logs/tildaz.log` |
| Windows | `%APPDATA%\tildaz\config.json` | `%APPDATA%\tildaz\tildaz.log` |

macOS releases are ad-hoc signed. If Gatekeeper blocks the first open,
right-click `TildaZ.app` and choose **Open**, or run:

```sh
xattr -d com.apple.quarantine /Applications/TildaZ.app
```

Then grant **Input Monitoring** and **Accessibility** in System Settings →
Privacy & Security. Those permissions are needed for the global hotkey and
window control shortcuts.

## Configure

Edit `config.json`; the schema is documented in [CONFIG.md](CONFIG.md).

Common fields:

- `window.dock_position`, `width_percent`, `height_percent`, `offset_percent`,
  `opacity_percent`
- `font.family`, `font.glyph_fallback`, `size_point`,
  `cell_width_ratio`, `line_height_ratio`
- `theme`, `shell`, `hotkey`, `auto_start`, `hidden_start`,
  `max_scroll_lines`

Font fallback is capped at 8 families total: 1 primary `font.family` plus up to
7 entries in `font.glyph_fallback`.

## Build

Requirements:

- [Zig 0.15.2](https://ziglang.org/download/)
- macOS: Xcode Command Line Tools (`xcode-select --install`)
- Windows: no extra C/C++ toolchain; Zig provides clang + LLD for the MSVC ABI

```bash
zig build
zig build test
zig build package
```

Outputs:

| Platform | Local build output | Package output |
|---|---|---|
| Linux | `zig-out/bin/tildaz` (with `-Dtarget={x86_64,aarch64}-linux-gnu.2.28`) | `zig-out/release/{tildaz-v<ver>-linux-<arch>.tar.gz,tildaz_<ver>_<debarch>.deb,tildaz-<ver>-1.<arch>.rpm,TildaZ-<ver>-<arch>.AppImage}` (`-Dformat=tar.gz\|deb\|rpm\|AppImage`) |
| macOS | `zig-out/TildaZ.app` | `zig-out/release/tildaz-v<ver>-macos.dmg` |
| Windows x64 | `zig-out/bin/tildaz.exe` | `zig-out/release/tildaz-v<ver>-win-x64.zip` |
| Windows ARM64 | `zig-out/bin/tildaz.exe` (with `-Dtarget=aarch64-windows`) | `zig-out/release/tildaz-v<ver>-win-arm64.zip` |

Official release binaries are built by GitHub Actions from `v*` tags. Local
packages are useful for testing, but release artifacts are not uploaded by hand.

## Documentation

| Need | Read |
|---|---|
| Configuration schema, themes, examples | [CONFIG.md](CONFIG.md) |
| Keyboard and mouse shortcuts | [KEYBINDINGS.md](KEYBINDINGS.md) |
| Current code structure | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Security reporting | [SECURITY.md](SECURITY.md) |
| Release notes | [`dist/release-notes/`](dist/release-notes/) |

## Known Limitations

- Linux is Wayland-only (no X11) and shipped in v0.5.0. It is verified on real
  hardware across KDE Plasma 6, Hyprland, sway, Cinnamon, GNOME (via a Shell
  extension), and COSMIC. The Linux renderer is still a software path (no GPU
  yet). Z-order yield on focus loss is not implemented on Linux
  (`wp_layer_shell_v1` categorical layers have no normal-window slot). Hanja
  conversion of already-committed Hangul (selecting committed Korean text and
  pressing the Hanja key) is not supported on Linux — `zwp_text_input_v3` has no
  reconversion request.
- macOS releases are ad-hoc signed, so Gatekeeper may require the first-open
  flow above. Developer ID notarization is still blocked by the current signing
  environment.
- macOS Emoji & Symbols opens as a floating panel rather than a cursor-anchored
  popover in custom terminal views. This matches Ghostty, iTerm2, Alacritty,
  Kitty, and similar GPU cell-grid terminals.
- Holding paste-repeat on very wide ZWJ emoji clusters under macOS bash 3.2 can
  desynchronize shell wrapping. Normal single paste is unaffected; zsh 5.x does
  not exhibit the same mismatch.
- Windows binaries are not Authenticode-signed yet, so SmartScreen or EDR tools
  may warn on first launch. The current SignPath application draft lives in
  [dist/signpath-application.md](dist/signpath-application.md).
- The Windows global hotkey cannot fire while an elevated app has focus unless
  TildaZ is also elevated. This is Windows UIPI behavior.

## Privacy

TildaZ has no telemetry, analytics, auto-update check, crash reporter, or
network request path. It stores only local config and log files. Child shells
(`cmd`, PowerShell, WSL, bash, zsh, etc.) are independent processes governed by
the user's shell and OS configuration.

## License

TildaZ is **AGPL-3.0-or-later**. See [LICENSE](LICENSE).

Bundled / linked components:

| Component | License | Source |
|---|---|---|
| `libghostty-vt` | MIT | https://github.com/ghostty-org/ghostty |
| `OpenConsole.exe` / `conpty.dll` | MIT | https://github.com/microsoft/terminal |
