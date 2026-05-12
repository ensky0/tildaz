# TildaZ

Quake-style drop-down terminal for Windows and macOS, built with Zig and
`libghostty-vt`.

TildaZ brings the feel of Linux's [Tilda](https://github.com/lanoxx/tilda) to
native desktop stacks: ConPTY + Direct3D 11 on Windows, POSIX PTY + Metal on
macOS.

**Website**: https://ensky0.github.io/tildaz/
**Latest release**: https://github.com/ensky0/tildaz/releases/latest

> **v0.4.3 — macOS Hanja conversion UX + reliability cleanup**
>
> This release adds the macOS `NSTextInputClient` reconversion surface needed
> for Hanja / kanji candidate replacement in the terminal row and tab rename.
> Option+Return can commit an in-progress Hangul syllable, open the candidate
> list immediately, keep the original Hangul visible while choosing, and
> replace it only when a candidate is accepted. It also tightens shell/env and
> renderer behavior across platforms and routes user-visible dialogs through
> the shared message layer. See
> [`dist/release-notes/v0.4.3.md`](dist/release-notes/v0.4.3.md).

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
| Windows 10 1903+ x64 | `tildaz-vX.Y.Z-windows.zip` | Unzip anywhere and keep `tildaz.exe`, `conpty.dll`, and `OpenConsole.exe` together. |
| macOS 13+ universal | `tildaz-vX.Y.Z-macos.dmg` | Drag `TildaZ.app` into Applications. Apple Silicon and Intel are both included. |

First launch creates the default config:

| Platform | Config | Log |
|---|---|---|
| Windows | `%APPDATA%\tildaz\config.json` | `%APPDATA%\tildaz\tildaz.log` |
| macOS | `~/.config/tildaz/config.json` | `~/Library/Logs/tildaz.log` |

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
| Windows | `zig-out/bin/tildaz.exe` | `zig-out/release/tildaz-v<ver>-windows.zip` |
| macOS | `zig-out/TildaZ.app` | `zig-out/release/tildaz-v<ver>-macos.dmg` |

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

- Linux is planned but not released yet. The accepted direction is a
  Wayland-first backend with no initial X11 support; GNOME Wayland will start as
  limited support until a correct full drop-down path is verified. See
  [LINUX.md](LINUX.md).
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
