# Architecture

TildaZ is a native host on each operating system with a shared terminal,
configuration, tab, dialog, theme, and interaction core.

The project deliberately does not wrap an existing terminal app. Windows uses
ConPTY and Direct3D 11 directly; macOS uses POSIX PTY and Metal directly;
Linux uses a direct Wayland client + software `wl_shm` renderer (no GTK / Qt
toolkit dependency, no X11). The shared code owns terminal state and UI
policy, while each host owns the OS event loop and native APIs.

## Layers

| Layer | Shared? | Main files | Responsibility |
|---|---:|---|---|
| Host | No | `src/host/windows.zig`, `src/host/macos.zig`, `src/host/linux_wayland.zig` + `src/host/linux/wayland_minimal.zig` | OS startup, event loop, global hotkey, window lifecycle |
| Window controller | Mostly Windows | `src/window.zig`, `src/app_controller.zig`, `src/app_event.zig` | Win32 message dispatch and app-level event routing |
| Session core | Yes | `src/session_core.zig` | Tabs, active index, scrollback, VT draining, PTY queues |
| Tab behavior | Yes | `src/tab_actions.zig`, `src/tab_interaction.zig`, `src/tab_layout.zig` | Tab switching, close paths, rename, drag, hit testing |
| Selection | Yes | `src/terminal_interaction.zig` | Drag selection, word selection, wide-cell handling |
| Config | Yes | `src/config.zig` | Strict schema, defaults, `_` comment keys |
| Dialog/messages | Yes wrapper | `src/dialog.zig`, `src/messages.zig` | Single entry point for user-visible text and dialogs |
| PTY | Wrapper | `src/terminal.zig`, `src/terminal/windows/pty.zig`, `src/terminal/macos/pty.zig` | ConPTY or POSIX PTY behind the same external API |
| Renderer | Wrapper | `src/renderer.zig`, `src/renderer/windows.zig`, `src/renderer/macos.zig` | Tab bar + terminal drawing with a shared call shape |
| Fonts | Per OS | `src/font/windows`, `src/font/macos`, `src/font/constants.zig` | Native font lookup, glyph fallback, shared chain limit |
| OS services | Wrapper | `src/autostart.zig`, `src/log.zig`, `src/paths.zig` | Startup registration, logging, platform paths |

## Windows Pipeline

1. `host/windows.zig` initializes DPI awareness, single-instance behavior,
   config, autostart, the Win32 window, renderer, and first tab.
2. `window.zig` converts Win32 messages into `app_event.zig`.
3. `app_controller.zig` applies events to tab/session/selection/rename state.
4. `session_core.zig` drains PTY output through `libghostty-vt`.
5. `terminal/windows/pty.zig` creates ConPTY, preferring bundled
   `conpty.dll` / `OpenConsole.exe` and falling back to system ConPTY.
6. `renderer/windows.zig` draws with DirectWrite glyph rasterization and a
   Direct3D 11 / HLSL atlas pipeline.

## macOS Pipeline

1. `host/macos.zig` owns `NSApplication`, `NSWindow`, global hotkey event tap,
   AppKit input callbacks, and a render timer.
2. `terminal/macos/pty.zig` uses `openpty` + `login_tty` + IUTF8 termios and
   tears down child process groups on tab close.
3. The same `session_core.zig` tab/session model is used as Windows.
4. `renderer/macos.zig` draws with CoreText glyph rasterization and a Metal
   atlas. `renderTabBar` starts the frame; `renderTerminal` presents it.
5. `host/macos.zig` implements `NSTextInputClient` for Korean / Japanese /
   Chinese IME pre-edit and reconversion. Since v0.4.3, committed-text Hanja /
   kanji reconversion works for the active terminal row and tab rename.

## Linux Pipeline

1. `host/linux_wayland.zig` is the Linux entry point: it resolves config and
   shell, then connects to `host/linux/wayland_minimal.zig`.
2. `host/linux/wayland_minimal.zig` is a direct Wayland wire-protocol client (no
   GTK / Qt). It owns the registry, `xdg-shell` / `wlr-layer-shell` surfaces,
   `wl_shm` buffers, keyboard / pointer / data-device, `zwp_text_input_v3` IME,
   the D-Bus / XDG-portal global-shortcut path, and the main event loop.
3. The same `session_core.zig` tab/session model is used as Windows / macOS.
4. `terminal/linux/pty.zig` opens a POSIX PTY (`/dev/ptmx`, `setsid`,
   `TIOCSCTTY`) behind the shared `terminal.zig` API.
5. `host/linux/software_terminal.zig` is a software `wl_shm` renderer that draws
   the terminal grid and tab bar directly into an ARGB8888 buffer. `xkb.zig`
   (runtime `libxkbcommon`) decodes keys; fonts come from fontconfig + FreeType
   + HarfBuzz via `src/font/linux/*`, all `dlopen`-loaded.

The host probes compositor capabilities at startup and degrades gracefully:
`xdg_wm_base` (baseline window — fatal if missing), `zwlr_layer_shell_v1` (true
drop-down; falls back to a normal `xdg-shell` window or a Shell extension on
mutter / muffin), `libxkbcommon` (keymaps), Wayland data-device (clipboard),
XDG-portal `GlobalShortcuts` (global toggle; otherwise per-DE config bind to
`tildaz --toggle`), and `zwp_text_input_v3` (IME). Each missing capability is
logged and surfaced as a documented limitation rather than a crash.

## Design Choices

**Native PTY backends.** ConPTY is the supported Windows pseudoconsole API for
terminal emulators. POSIX PTY is the equivalent primitive on macOS. Both are
wrapped behind `terminal.zig` so session code does not care which host it is on.

**Native text engines.** DirectWrite and CoreText are used for glyph shaping and
rasterization because they already understand each platform's font fallback,
emoji, CJK, and antialiasing behavior. TildaZ caches glyphs in GPU atlases.

**Shared policy, native interaction.** User-visible policy is shared where it
matters: tab lifecycle, rename commit/cancel semantics, IME pre-edit display,
selection behavior, config schema, dialogs, and child shell environment. OS
conventions remain native: Windows uses Ctrl/Alt patterns; macOS uses Cmd/Shift
Cmd patterns and AppKit input callbacks.

**Strict config.** `src/config.zig` is the source of truth for the JSON schema
and defaults. Unknown keys are fatal except `_`-prefixed comment keys. Numeric
fields include their units (`_percent`, `_point`, `_ratio`).

**Wayland-only on Linux.** Wayland is where modern Linux desktops are heading,
which matches the goal of behaving well on current desktop managers. X11 is not
impossible, but supporting it would fork windowing, input, clipboard, global
hotkey, IME, DPI, and focus handling into a second host surface. So the first
Linux backend is Wayland-only; the Linux-specific files keep names and
boundaries (`linux_wayland.zig`, not `linux.zig`) so an X11 backend could sit
alongside later if real user or distribution demand appears.

**No GTK / Qt toolkit dependency.** TildaZ already owns most of a terminal app's
surface — terminal state, tabs, config, renderer, selection policy, dialogs, and
PTY lifecycle. A toolkit would help with window shell, input plumbing, clipboard,
and IME, but it would not remove the Wayland constraints on global shortcuts and
desktop-layer placement, and each toolkit carries a runtime bias (GTK toward
GNOME, Qt toward KDE). A direct Wayland client can probe each desktop's
capabilities at runtime instead. Toolkit integration is only reconsidered as a
fallback if direct Wayland text-input or clipboard becomes unworkable.

## Current Open Work

| Area | Issue | State |
|---|---:|---|
| macOS Developer ID signing / notarization | [#109](https://github.com/ensky0/tildaz/issues/109) | Blocked by current signing environment; releases are ad-hoc signed |
| Config schema completion / future cleanup | [#118](https://github.com/ensky0/tildaz/issues/118) | Open follow-up context |
| Config hot reload | [#170](https://github.com/ensky0/tildaz/issues/170) | Not started |
| Elevated Windows autostart helper | [#151](https://github.com/ensky0/tildaz/issues/151) | Not started |
| Linux renderer (EGL/OpenGL ES) | [#189](https://github.com/ensky0/tildaz/issues/189) | Wayland backend shipped in v0.5.0 (final) — Wayland-only, verified on real hardware across KDE Plasma 6, Hyprland, sway, Cinnamon, GNOME (Shell extension), and COSMIC. The remaining follow-up is replacing the bring-up software `wl_shm` renderer with a GPU (EGL/OpenGL ES) path; the software renderer is correct but is a placeholder. |
| Stress tests | none yet | Needed for bulk output, resize storms, tab close under load, WSL/nvim/mouse, CJK/emoji |

Completed cross-platform work is tracked in
[CROSS_PLATFORM.md](CROSS_PLATFORM.md), [#171](https://github.com/ensky0/tildaz/issues/171),
[#176](https://github.com/ensky0/tildaz/issues/176), and the release notes.

## Distribution

Official release artifacts are generated by `.github/workflows/release.yml`
from `v*` tags.

| Platform | Artifact | Signing |
|---|---|---|
| Windows x64 | `tildaz-v<ver>-win-x64.zip` | Currently unsigned TildaZ binary; bundled Microsoft ConPTY files are Microsoft-signed |
| Windows ARM64 | `tildaz-v<ver>-win-arm64.zip` | Same as x64 with ARM64-native binaries |
| macOS | `tildaz-v<ver>-macos.dmg` | Universal app bundle (Apple Silicon + Intel), ad-hoc signed |
| Linux x86_64 / aarch64 | `tildaz-v<ver>-linux-<arch>.{tar.gz,deb,rpm,AppImage}`, the AppImage as `TildaZ-...`, plus an Arch package `tildaz-<ver>-1-x86_64.pkg.tar.zst` (x86_64 only) | Unsigned; relies on per-distro install path verification. Native dependencies (Wayland / xkbcommon / FreeType / fontconfig / HarfBuzz / D-Bus) are all runtime `dlopen`, so the binary itself has no hard-linked libraries beyond glibc 2.28+. The `.deb` / `.rpm` packages declare the core libraries (xkbcommon, freetype, fontconfig) as dependencies so a fresh install pulls them in. |

The release workflow checks that:

- the tag version matches `build.zig`'s `tildaz_version`;
- `dist/release-notes/v<ver>.md` exists on the tag;
- dependencies in `build.zig.zon` are pinned to 40-character commit SHA tarball
  URLs rather than rolling branch references.

## Performance Notes

The Windows renderer and ConPTY path were benchmarked during the v0.2.x series
with a 1.14 MiB CJK `cat` workload inside WSL. The bundled OpenConsole path
plus the overlapped 128 KiB read pipeline reduced the median `time cat` result
from roughly 0.293 s to roughly 0.074 s on the maintainer's reference machine.

macOS has not yet been benchmarked with the same harness. Subjectively the
Metal path is comparable to the Windows D3D11 path, but formal numbers should
be collected under a dedicated performance issue before being treated as a
published claim.

## Linux Protocol References

- XDG Desktop Portal `GlobalShortcuts` — permissioned cross-desktop API for
  registering shortcuts outside app focus:
  <https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html>
- `wlr-layer-shell` — desktop layer surfaces anchored to an output edge:
  <https://wayland.app/protocols/wlr-layer-shell-unstable-v1>
- `xdg-shell` — baseline Wayland protocol for normal toplevel windows:
  <https://wayland.app/protocols/xdg-shell>
- `libxkbcommon` — shared keyboard handling library:
  <https://xkbcommon.org/>
- Wayland `text-input-v3` — pre-edit and commit-string events for IME (protocol
  family is still unstable/experimental):
  <https://wayland.app/protocols/text-input-unstable-v3>
