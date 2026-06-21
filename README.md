# TildaZ

**The drop-down terminal that works everywhere.** Hit one hotkey and a fast,
native terminal slides down over whatever you're doing — on Linux, macOS,
and Windows. In the spirit of [Tilda](https://github.com/lanoxx/tilda), but on
every desktop you use.

Most drop-down terminals live on a single OS — or a single Linux desktop.
TildaZ is one app across all three platforms, and on Linux it brings a real
drop-down with a global hotkey to **every major desktop**: KDE Plasma, GNOME,
Cinnamon, COSMIC, Hyprland, and sway. No Electron, no toolkit bloat — just a
quick native window that gets out of your way.

**Website**: https://ensky0.github.io/tildaz/ ·
**Download**: https://github.com/ensky0/tildaz/releases/latest

> **v0.5.0 — now on Linux.** One drop-down terminal for Linux (Wayland),
> macOS, and Windows, with verified drop-down + global-hotkey support on KDE
> Plasma, GNOME, Cinnamon, COSMIC, Hyprland, and sway.

## Why TildaZ

- **One terminal, every OS.** The same drop-down terminal on Linux, macOS, and Windows — one config, one muscle memory.
- **Works on every Linux desktop.** A real drop-down and global hotkey on KDE Plasma, GNOME, Cinnamon, COSMIC, Hyprland, and sway — not just one.
- **Native and quick.** No Electron, no GTK/Qt — a direct Wayland client on Linux, GPU rendering on macOS and Windows, and the fast `libghostty-vt` core.
- **A real terminal.** Tabs, themes, true color, ligatures, color emoji, and full CJK with inline IME (Korean / Japanese / Chinese), Hanja / kanji included.
- **Stays out of your way.** Drop it down with a hotkey, dock it to the monitor under your cursor, dismiss it just as fast.
- **Private by default.** No telemetry, no analytics, no auto-update phone-home — only local config and logs.

## See it render

Ligatures, true color, color emoji with skin tones and ZWJ families, full-width
CJK, and block / shade glyphs all render correctly — identically on Linux,
macOS, and Windows. Paste this into any TildaZ window:

```sh
echo -e "\n🎉❤️🌈🎨🌞🍎🚀💎✨\n👋🏻👋🏼👋🏽👋🏾👋🏿\n👨‍👩‍👧👨‍👨‍👦‍👦\nABCDEFG abcdefg 0123456789\n한글 ABC 가나다라마바사\n▀▁▂▃▄▅▆▇█▉▊▋▌▍▎▏\n▐░▒▓▔▕\n"
```

## Install

Download the latest artifact from
[GitHub Releases](https://github.com/ensky0/tildaz/releases/latest).

| Platform | Artifact | Notes |
|---|---|---|
| Windows 10 1903+ x64 | `tildaz-vX.Y.Z-win-x64.zip` | Unzip anywhere and keep `tildaz.exe`, `conpty.dll`, and `OpenConsole.exe` together. |
| Windows 11 ARM64 | `tildaz-vX.Y.Z-win-arm64.zip` | Same layout as the x64 zip with ARM64-native binaries. |
| macOS 13+ universal | `tildaz-vX.Y.Z-macos.dmg` | Drag `TildaZ.app` into Applications. Apple Silicon and Intel are both included. |
| Linux (any distro) — portable | `tildaz-vX.Y.Z-linux-{x86_64,aarch64}.tar.gz` | Extract, then `./install.sh` installs the `.desktop` and icon under `~/.local/share`. The binary stays in the extracted directory by default. |
| Linux Debian / Ubuntu | `tildaz_X.Y.Z_{amd64,arm64}.deb` | `sudo dpkg -i tildaz_*.deb` (or open with the Software app). |
| Linux Fedora / RHEL / openSUSE | `tildaz-X.Y.Z-1.{x86_64,aarch64}.rpm` | `sudo dnf install ./tildaz-*.rpm` (or `rpm -Uvh`). |
| Linux distro-independent — single file | `TildaZ-X.Y.Z-{x86_64,aarch64}.AppImage` | `chmod +x TildaZ-*.AppImage && ./TildaZ-*.AppImage` — runs on any glibc 2.28+ system. |
| Linux Arch / Manjaro / EndeavourOS | `tildaz-X.Y.Z-1-x86_64.pkg.tar.zst` | `sudo pacman -U tildaz-*.pkg.tar.zst` (x86_64). |

First launch creates the default config:

| Platform | Config | Log |
|---|---|---|
| Windows | `%APPDATA%\tildaz\config.json` | `%APPDATA%\tildaz\tildaz.log` |
| macOS | `~/.config/tildaz/config.json` | `~/Library/Logs/tildaz.log` |
| Linux | `~/.config/tildaz/config.json` | `~/.local/state/tildaz/tildaz.log` |

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
| Windows x64 | `zig-out/bin/tildaz.exe` | `zig-out/release/tildaz-v<ver>-win-x64.zip` |
| Windows ARM64 | `zig-out/bin/tildaz.exe` (with `-Dtarget=aarch64-windows`) | `zig-out/release/tildaz-v<ver>-win-arm64.zip` |
| macOS | `zig-out/TildaZ.app` | `zig-out/release/tildaz-v<ver>-macos.dmg` |
| Linux | `zig-out/bin/tildaz` (with `-Dtarget={x86_64,aarch64}-linux-gnu.2.28`) | `zig-out/release/{tildaz-v<ver>-linux-<arch>.tar.gz,tildaz_<ver>_<debarch>.deb,tildaz-<ver>-1.<arch>.rpm,TildaZ-<ver>-<arch>.AppImage}` (`-Dformat=tar.gz\|deb\|rpm\|AppImage`) |

Official release binaries are built by GitHub Actions from `v*` tags. Local
packages are useful for testing, but release artifacts are not uploaded by hand.

## Documentation

| Need | Read |
|---|---|
| Configuration schema, themes, examples | [CONFIG.md](CONFIG.md) |
| Keyboard and mouse shortcuts | [KEYBINDINGS.md](KEYBINDINGS.md) |
| Current code structure | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Cross-platform behavior spec | [SPEC.md](SPEC.md) |
| Maintainer / agent workflow rules | [AGENTS.md](AGENTS.md) |
| Security reporting | [SECURITY.md](SECURITY.md) |
| Release notes | [`dist/release-notes/`](dist/release-notes/) |

Historical cross-platform refactor notes are archived in
[CROSS_PLATFORM.md](CROSS_PLATFORM.md).

## Known Limitations

- Linux is Wayland-only (no X11) and shipped in v0.5.0. It is verified on real
  hardware across KDE Plasma 6, Hyprland, sway, Cinnamon, GNOME (via a Shell
  extension), and COSMIC. The Linux renderer is still a software path (no GPU
  yet). Z-order yield on focus loss is not implemented on Linux
  (`wp_layer_shell_v1` categorical layers have no normal-window slot). Hanja
  conversion of already-committed Hangul (selecting committed Korean text and
  pressing the Hanja key) is not supported on Linux — `zwp_text_input_v3` has no
  reconversion request. See [SPEC.md](SPEC.md) §1.2 for the desktop matrix.
- Windows binaries are not Authenticode-signed yet, so SmartScreen or EDR tools
  may warn on first launch. The current SignPath application draft lives in
  [dist/signpath-application.md](dist/signpath-application.md).
- The Windows global hotkey cannot fire while an elevated app has focus unless
  TildaZ is also elevated. This is Windows UIPI behavior.
- macOS releases are ad-hoc signed, so Gatekeeper may require the first-open
  flow above. Developer ID notarization is still blocked by the current signing
  environment.
- macOS Emoji & Symbols opens as a floating panel rather than a cursor-anchored
  popover in custom terminal views. This matches Ghostty, iTerm2, Alacritty,
  Kitty, and similar GPU cell-grid terminals.
- Holding paste-repeat on very wide ZWJ emoji clusters under macOS bash 3.2 can
  desynchronize shell wrapping. Normal single paste is unaffected; zsh 5.x does
  not exhibit the same mismatch.

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
