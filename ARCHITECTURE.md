# Architecture

TildaZ is a native host on each operating system with a shared terminal,
configuration, tab, dialog, theme, and interaction core.

The project deliberately does not wrap an existing terminal app. Windows uses
ConPTY and Direct3D 11 directly; macOS uses POSIX PTY and Metal directly. The
shared code owns terminal state and UI policy, while each host owns the OS event
loop and native APIs.

## Layers

| Layer | Shared? | Main files | Responsibility |
|---|---:|---|---|
| Host | No | `src/host/windows.zig`, `src/host/macos.zig` | OS startup, event loop, global hotkey, window lifecycle |
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

## Current Open Work

| Area | Issue | State |
|---|---:|---|
| macOS Developer ID signing / notarization | [#109](https://github.com/ensky0/tildaz/issues/109) | Blocked by current signing environment; releases are ad-hoc signed |
| Config schema completion / future cleanup | [#118](https://github.com/ensky0/tildaz/issues/118) | Open follow-up context |
| Config hot reload | [#170](https://github.com/ensky0/tildaz/issues/170) | Not started |
| Elevated Windows autostart helper | [#151](https://github.com/ensky0/tildaz/issues/151) | Not started |
| Linux backend | [#189](https://github.com/ensky0/tildaz/issues/189) | Planning in [LINUX.md](LINUX.md); Wayland-only direction under discussion |
| Stress tests | none yet | Needed for bulk output, resize storms, tab close under load, WSL/nvim/mouse, CJK/emoji |

Completed cross-platform work is tracked in
[CROSS_PLATFORM.md](CROSS_PLATFORM.md), [#171](https://github.com/ensky0/tildaz/issues/171),
[#176](https://github.com/ensky0/tildaz/issues/176), and the release notes.

## Distribution

Official release artifacts are generated by `.github/workflows/release.yml`
from `v*` tags.

| Platform | Artifact | Signing |
|---|---|---|
| Windows | `tildaz-v<ver>-windows.zip` | Currently unsigned TildaZ binary; bundled Microsoft ConPTY files are Microsoft-signed |
| macOS | `tildaz-v<ver>-macos.dmg` | Universal app bundle, ad-hoc signed |

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
