# TildaZ

Quake-style drop-down terminal for Windows, macOS, and Linux Wayland, built
with Zig and `libghostty-vt`.

TildaZ brings the feel of Linux's [Tilda](https://github.com/lanoxx/tilda) to
native desktop stacks: ConPTY + Direct3D 11 on Windows, POSIX PTY + Metal on
macOS, and a direct Wayland client + software renderer on Linux (no GTK / Qt
dependency).

**Website**: https://ensky0.github.io/tildaz/
**Latest release**: https://github.com/ensky0/tildaz/releases/latest

> **v0.5.0-rc4 — first Linux Wayland preview (workflow-verified)**
>
> rc1 / rc2 / rc3 each failed a different step of the release workflow.
> rc4 is the first release where Windows, macOS, and Linux artifacts are
> all built and uploaded end-to-end by CI. Scope is otherwise identical
> to rc1.
>
> The release candidate introduces the Linux Wayland backend as a preview:
> `xdg-shell` and `wlr-layer-shell` windows, KDE-style fractional scaling,
> fontconfig + FreeType + HarfBuzz, `zwp_text_input_v3` IME, XDG Desktop
> Portal global shortcuts with `tildaz --toggle` IPC fallback, and four
> packaging formats (`.tar.gz`, `.deb`, `.rpm`, `.AppImage`) on `x86_64` and
> `aarch64`. Windows ARM64 is now a first-class build target, and Linux's
> cross-platform ligature module is shared with Windows / macOS. See
> [`dist/release-notes/v0.5.0-rc1.md`](dist/release-notes/v0.5.0-rc1.md).
>
> Linux is verified on KDE Plasma 6.6.5 (KWin) and Cinnamon Wayland with
> fcitx5-hangul. GNOME Wayland is limited support; sway / Hyprland are
> untested in this preview.

## Highlights

| Area | What TildaZ does |
|---|---|
| Drop-down workflow | Global hotkey, always-on-top translucent window, current-monitor docking, fullscreen toggle |
| Tabs | Independent sessions, click/select/close, drag reorder, double-click rename, 32-tab cap with dialog |
| Terminal core | `libghostty-vt`, ANSI 16 / 256 / TrueColor, scrollback up to 10 M lines |
| Rendering | DirectWrite + D3D11 ClearType on Windows; CoreText + Metal retina atlas on macOS |
| Unicode / IME | Hangul, CJK, color emoji, ZWJ clusters, inline IME pre-edit, Hanja / kanji / hanzi candidate tracking and replacement |
| Shells | Bundled OpenConsole ConPTY on Windows; POSIX `openpty` + `login_tty` on macOS |
| Configuration | One JSON schema across platforms, strict validation, `_`-prefixed comment keys |

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
| Linux backend planning | [LINUX.md](LINUX.md) |
| Cross-platform behavior spec | [SPEC.md](SPEC.md) |
| Maintainer / agent workflow rules | [AGENTS.md](AGENTS.md) |
| Security reporting | [SECURITY.md](SECURITY.md) |
| Release notes | [`dist/release-notes/`](dist/release-notes/) |

Historical cross-platform refactor notes are archived in
[CROSS_PLATFORM.md](CROSS_PLATFORM.md).

## Known Limitations

- Linux is **preview** in v0.5.0-rc1 — Wayland-only, no X11. KDE Plasma 6 and
  Cinnamon Wayland are verified; GNOME Wayland is limited (no true drop-down
  path); sway / Hyprland / Wayfire are untested. The Linux renderer is a
  software path (no GPU yet). Z-order yield on focus loss is not implemented
  on Linux (`wp_layer_shell_v1` categorical layers have no normal-window
  slot). Hanja conversion of already-committed Hangul (selecting committed
  Korean text and pressing the Hanja key) is not supported on Linux —
  `zwp_text_input_v3` has no reconversion request. See [LINUX.md](LINUX.md).
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
