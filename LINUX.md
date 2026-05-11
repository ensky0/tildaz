# Linux Backend Plan

Status: accepted planning direction for issue
[#189](https://github.com/ensky0/tildaz/issues/189). No Linux release artifact
exists yet.

This document records the Linux backend contract before implementation starts.
It separates decisions, support promises, fallbacks, and validation gates so the
first Linux port does not accidentally promise more than the platform can
provide.

## Decision Summary

| Area | Decision |
|---|---|
| Initial display target | Wayland-only. X11 is not part of the first Linux implementation. |
| X11 future path | Keep module boundaries open for a later `host/linux_x11.zig`, but do not implement it now. |
| Toolkit | Direct Wayland backend. Do not add a mandatory GTK or Qt dependency to the core app. |
| GTK / Qt fallback | Keep toolkit input integration as a last-resort option only if direct Wayland IME or clipboard support proves too brittle. |
| Baseline window | `xdg-shell` toplevel window. This is the minimum viable Linux window path. |
| True drop-down | Use `wlr-layer-shell` when the compositor advertises it. |
| GNOME support | Limited at first. Promote to full support as soon as the implementation can provide the full drop-down workflow on GNOME without fragile hacks. |
| Global shortcut | Prefer XDG Desktop Portal `GlobalShortcuts`. Missing portal support must produce a clear limitation, not a silent failure. |
| Keyboard | `libxkbcommon`. |
| IME | Wayland text-input v3 target, with desktop/IME compatibility tracked explicitly. |
| Renderer | EGL + OpenGL ES first. Vulkan can be evaluated after the Linux host surface is stable. |
| Font stack | fontconfig + FreeType + HarfBuzz. |
| First alpha scope | Normal window, POSIX PTY, basic rendering path, keyboard/mouse input, selection, copy/paste. |

## Support Tiers

TildaZ should describe Linux support by observed capabilities, not by desktop
brand alone.

| Tier | Meaning |
|---|---|
| Full support | Global toggle, monitor-aware drop-down placement, tabbed terminal, Unicode rendering, clipboard, config parity, and IME behavior meet the cross-platform spec on that desktop. |
| Limited support | The terminal is usable, but at least one platform capability is missing or unverified: true drop-down layer, global shortcut, IME pre-edit, or desktop integration. |
| Unsupported | The app cannot open a baseline Wayland window or cannot run a terminal session. |

GNOME Wayland starts as **limited support**, not because it is unimportant, but
because GNOME does not expose the same layer-shell contract that wlroots
compositors commonly provide. The project goal is to move GNOME to full support
as soon as a correct, maintainable implementation path exists.

## Why Wayland First

Wayland is the modern Linux desktop direction and matches the user's target:
current desktop managers should work well without carrying a second legacy X11
backend from day one.

X11 support is not impossible, but it would create another host surface with its
own windowing, input, clipboard, global hotkey, IME, DPI, and focus behavior. It
should be reopened only if real users or distributions need it after the Wayland
backend is useful.

The code should still avoid painting itself into a corner. Linux-specific files
should be named and layered so a later X11 backend can live beside Wayland
instead of replacing it.

## Why Not GTK or Qt First?

GTK and Qt are both good Linux UI stacks, but TildaZ already owns most of the
terminal application surface:

- terminal state and tabs;
- config and validation;
- custom GPU renderer;
- selection and mouse policy;
- dialogs and user-visible messages;
- platform-specific PTY lifecycle.

A toolkit would provide a window shell, input plumbing, clipboard, and IME
integration, but it would not remove the hard Wayland constraints around global
shortcuts and desktop-layer placement. GTK also biases the runtime toward GNOME,
while Qt biases it toward KDE/Plasma. A direct Wayland backend keeps the
capability boundary explicit and lets TildaZ probe each desktop at runtime.

Toolkit integration remains a fallback candidate only if direct Wayland
text-input or clipboard behavior blocks a correct IME implementation.

## Desktop Matrix

| Desktop / compositor | Initial status | Expected baseline | Full-support blocker |
|---|---|---|---|
| wlroots compositors such as Sway, Hyprland, Wayfire | Full-support target | `xdg-shell` plus `wlr-layer-shell` when advertised | Global shortcut and IME behavior still require validation per compositor/session. |
| KDE Plasma Wayland | Full-support candidate | `xdg-shell`; layer-shell support must be probed directly | Portal global shortcut and layer-shell behavior must be verified without requiring Qt. |
| GNOME Wayland | Limited support first | `xdg-shell` normal app window | True drop-down placement needs a correct GNOME path, such as a proven shell-extension path or another maintainable compositor-supported mechanism. |
| X11 sessions | Out of initial scope | None | Requires a separate backend decision and implementation issue. |

## Capability Strategy

The Linux host must probe capabilities during startup and keep the result
visible in logs. Missing support should degrade honestly.

| Capability | Probe | If missing |
|---|---|---|
| Baseline window | `xdg_wm_base` | Fatal: Linux host cannot open the app. |
| Desktop layer | `zwlr_layer_shell_v1` | Use a normal `xdg-shell` window and mark true drop-down unavailable. |
| Keyboard maps | `libxkbcommon` setup | Fatal or startup error: keyboard input cannot be interpreted correctly. |
| Clipboard | Wayland data-device support | Terminal remains usable, but copy/paste is limited with a clear message/log. |
| Global shortcut | XDG Desktop Portal `GlobalShortcuts` over D-Bus | Keep in-app shortcuts; show setup/unsupported guidance for global toggle. |
| IME | `zwp_text_input_manager_v3` and real pre-edit/commit events | Raw keyboard and paste continue; IME is documented as unavailable on that session. |

## Proposed Module Boundaries

Final file names can change during implementation, but the first pass should
keep these ownership lines clear:

| Area | Planned location | Notes |
|---|---|---|
| Host entry | `src/host/linux_wayland.zig` | Wayland connection, event loop, window lifecycle, capability probing. |
| PTY | `src/terminal/linux/pty.zig` | POSIX PTY; share concepts with macOS but keep Linux-specific termios/process details local. |
| Terminal backend wrapper | `src/terminal/linux.zig` | Same public shape as Windows/macOS terminal backends. |
| Renderer | `src/renderer/linux.zig`, `src/renderer/linux/*` | EGL/OpenGL ES surface, glyph atlas, frame lifecycle. |
| Font | `src/font/linux/*` | fontconfig discovery, FreeType rasterization, HarfBuzz shaping, shared fallback-chain cap. |
| Dialogs | `src/dialog/linux.zig` | Start with shared message text and a minimal desktop-safe path. Portal dialogs can be evaluated later. |
| Logging / paths / autostart | Existing wrappers plus Linux impls | Follow XDG paths and keep user-visible messages through `src/messages.zig`. |

Do not make shared core modules depend on Wayland types. Platform-specific
objects should stay behind host, renderer, terminal, font, dialog, path, and
autostart wrappers.

## Milestones

| Milestone | Goal | Validation |
|---|---|---|
| L0 | Documentation + build boundary | This plan is documented; no code behavior change. |
| L1 | Linux build skeleton | `zig build -Dtarget=x86_64-linux` reaches an intentional Linux-host TODO or minimal no-op host. |
| L2 | POSIX PTY | A Linux shell starts through a Linux PTY backend. |
| L3 | Wayland baseline window | `xdg-shell` window opens, resizes, closes, and logs probed capabilities. |
| L4 | EGL/OpenGL renderer | Clear frame, then terminal grid, renders inside the Wayland window. |
| L5 | Fonts | fontconfig + FreeType + HarfBuzz render Latin, Hangul, CJK, emoji fallback, and block elements. |
| L6 | Input and clipboard | xkbcommon keyboard, mouse selection, scroll, copy, paste, tab shortcuts. |
| L7 | First alpha | Normal Linux terminal window with PTY, rendering, input, selection, and copy/paste. |
| L8 | Layer-shell drop-down | If `zwlr_layer_shell_v1` exists, anchor to the configured monitor edge. |
| L9 | Global shortcut | Register the configured toggle through XDG Desktop Portal when supported. |
| L10 | IME | text-input v3 pre-edit / commit path with inline overlay and cursor rectangle. |
| L11 | Packaging | `.desktop` file, icon, AppImage or distro package plan, autostart, config/log paths. |

## First Alpha Contract

The first Linux alpha is allowed to be a normal Wayland terminal window. It must
not claim full TildaZ parity until these are all true on the target desktop:

- global toggle works while another app is focused;
- the window can appear as a monitor-aware drop-down at the configured edge;
- keyboard, mouse, selection, copy, paste, resize, and tab operations work;
- Unicode rendering passes the existing visual regression line from
  `AGENTS.md`;
- IME pre-edit and commit behavior match `SPEC.md` or are explicitly marked as
  unavailable for that desktop/session.

## Validation Checklist

Each Linux support promotion should record:

- desktop/compositor name and version;
- Wayland session confirmation;
- portal implementation and `GlobalShortcuts` availability;
- layer-shell availability;
- IME stack, such as ibus or fcitx, and tested language;
- GPU/driver path used by EGL;
- font fallback result for Latin, Hangul, CJK, emoji, and block elements;
- exact command or script used for visual text regression.

## Source Notes

- XDG Desktop Portal `GlobalShortcuts` is the permissioned cross-desktop API for
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
