# Linux Backend Plan

Status: draft for issue [#189](https://github.com/ensky0/tildaz/issues/189).

This document records the first Linux backend decision pass. It is intentionally
about architecture and constraints, not implementation details.

## Goals

- Ship a Linux build without adding an X11 backend.
- Work well across modern Wayland desktops: GNOME, KDE Plasma, and wlroots
  compositors such as Sway / Hyprland / Wayfire.
- Preserve TildaZ's core UX where the compositor allows it: global toggle,
  monitor-aware drop-down window, tabbed terminal, Unicode/IME, selection,
  clipboard, themes, and config parity.
- Keep Linux as a first-class host beside Windows and macOS, not a wrapper
  around another terminal emulator.

## Proposed Direction

| Decision | Proposal | Reason |
|---|---|---|
| Display protocol | Wayland-only | X11 support adds a second Linux host surface and does not match the desired modern target. |
| Toolkit | No mandatory GTK / Qt dependency in the core backend | TildaZ already owns rendering, tabs, config, dialogs, and terminal state. A toolkit does not remove the hard Wayland constraints around global shortcuts and window layering. |
| Baseline window | `xdg-shell` toplevel | Works across general Wayland desktops and gives us a normal app window baseline. |
| True drop-down window | Use `wlr-layer-shell` only when the compositor advertises it | Layer shell supports anchored desktop-layer surfaces, which matches the drop-down model. It is not guaranteed on every desktop. |
| Global hotkey | Prefer XDG Desktop Portal `GlobalShortcuts` | This is the cross-desktop permissioned path for shortcuts that fire while the app is not focused. |
| Keyboard | `libxkbcommon` | It is the standard keyboard handling library used by Wayland clients and toolkits. |
| IME | Wayland text-input v3, with compatibility tracked explicitly | The protocol provides pre-edit / commit text flow, but it is still an unstable/experimental protocol family, so desktop support must be verified. |
| Renderer | Start with EGL + OpenGL ES; keep Vulkan as a later option | OpenGL/EGL is the shortest first path to a GPU-backed Wayland surface. Vulkan can be evaluated after the host/input surface is stable. |
| Font stack | fontconfig + FreeType + HarfBuzz | Linux-native font discovery, rasterization, and shaping. |

## Why Not GTK or Qt First?

GTK and Qt are both viable UI stacks, but neither solves the core drop-down
problem by itself:

- TildaZ is not using native widgets for the terminal area. The renderer is a
  custom GPU cell grid, so the toolkit would mostly provide a window shell,
  input plumbing, clipboard, and IME integration.
- GNOME, KDE, and wlroots differ in which Wayland extension protocols they
  expose. A GTK app and a Qt app still need compositor support for global
  shortcuts and layer-shell behavior.
- Choosing GTK can feel natural on GNOME but adds a large runtime dependency on
  KDE/minimal systems. Choosing Qt has the inverse bias.
- A direct Wayland host keeps the dependency boundary explicit and lets us
  probe capabilities at runtime.

GTK / Qt can still be revisited if direct Wayland IME proves too brittle. That
should be a measured fallback, not the first architecture.

## Desktop Support Model

| Desktop / compositor | Baseline app window | True drop-down layer | Global hotkey | Notes |
|---|---:|---:|---:|---|
| GNOME Wayland | Expected via `xdg-shell` | Not assumed | Portal-dependent | True always-on-top / anchored drop-down may require a GNOME Shell extension or accepting a normal-window fallback. |
| KDE Plasma Wayland | Expected via `xdg-shell` | Check by probing `zwlr_layer_shell_v1` | Portal-dependent | KDE has LayerShellQt for Qt shell surfaces, but TildaZ should probe the compositor protocol directly rather than require Qt. |
| wlroots compositors | Expected via `xdg-shell` | Expected when `wlr-layer-shell` is advertised | Portal or compositor config | Best match for the drop-down terminal model. |
| X11 sessions | Not targeted | Not targeted | Not targeted | Out of scope unless a later issue reopens it. |

## Capability Strategy

TildaZ should not assume a single Wayland desktop contract. On startup, the
Linux host should detect and log:

- `xdg_wm_base` for baseline app window support.
- `zwlr_layer_shell_v1` for anchored overlay/drop-down support.
- `zwp_text_input_manager_v3` / related text-input protocol support for IME.
- XDG Desktop Portal `GlobalShortcuts` availability over D-Bus.
- Clipboard/data-device support.

If a capability is missing, the app should degrade honestly:

- No layer shell: run as a normal app window and document that true drop-down is
  unavailable on that compositor.
- No global shortcut portal: show a clear setup/unsupported message and keep
  in-app shortcuts working.
- No text-input protocol: raw keyboard input works, but IME is disabled with a
  documented limitation.

## Milestones

| Milestone | Goal | Validation |
|---|---|---|
| L0 | Documentation + build boundary | Linux plan documented; no code behavior change. |
| L1 | Build target skeleton | `zig build -Dtarget=x86_64-linux` reaches an intentional Linux-host TODO or a minimal no-op host. |
| L2 | POSIX PTY reuse | Factor macOS POSIX PTY pieces that can be shared with Linux; shell starts under Linux. |
| L3 | Wayland baseline window | `xdg-shell` window opens, resizes, closes, and renders a clear color. |
| L4 | EGL/OpenGL renderer | Terminal grid renders with fontconfig / FreeType / HarfBuzz glyph atlas. |
| L5 | Keyboard, mouse, clipboard | xkbcommon input, selection, copy/paste, scroll, tab shortcuts. |
| L6 | Layer-shell drop-down | If `zwlr_layer_shell_v1` exists, anchor the terminal to the configured screen edge. |
| L7 | Global shortcut portal | Register the configured hotkey through XDG Desktop Portal when supported. |
| L8 | IME | text-input v3 pre-edit / commit path with inline overlay and cursor rectangle. |
| L9 | Packaging | AppImage or distro package plan, `.desktop` file, autostart, config/log paths. |

## Open Questions

1. Should GNOME Wayland without layer-shell be considered supported with a
   normal-window fallback, or should it be marked limited until a GNOME Shell
   extension exists?
2. Is OpenGL/EGL acceptable for the first Linux renderer, or should Linux start
   with Vulkan despite the larger first implementation?
3. Do we want a hard dependency on XDG Desktop Portal, or a soft dependency with
   compositor-specific fallback hooks later?
4. Should the first alpha require Wayland text-input support, or can IME land
   after ASCII/UTF-8 keyboard input and paste are stable?

## Source Notes

- XDG Desktop Portal GlobalShortcuts is the permissioned cross-desktop API for
  registering shortcuts that activate while the app is not focused:
  <https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html>
- `wlr-layer-shell` creates desktop layer surfaces that can be anchored to
  output edges and assigned z-depth layers:
  <https://wayland.app/protocols/wlr-layer-shell-unstable-v1>
- `xdg-shell` is the baseline Wayland protocol for normal desktop-style
  toplevel windows:
  <https://wayland.app/protocols/xdg-shell>
- gtk-layer-shell documents that layer-shell only makes sense on Wayland
  compositors that support the protocol:
  <https://wmww.github.io/gtk-layer-shell/gtk-layer-shell.html>
- KDE LayerShellQt is a Qt integration layer around the layer-shell Wayland
  shell integration:
  <https://api.kde.org/plasma/layer-shell-qt/html/index.html>
- `libxkbcommon` is the common keyboard handling library used by Wayland,
  GTK, Qt, KWin, and others:
  <https://xkbcommon.org/>
- Wayland text-input v3 provides pre-edit and commit string events, but the
  protocol family is still unstable/experimental:
  <https://wayland.app/protocols/text-input-unstable-v3>
