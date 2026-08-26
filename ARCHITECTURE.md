# Architecture

TildaZ is a native host on each operating system with a shared terminal,
configuration, tab, dialog, theme, and interaction core.

The project deliberately does not wrap an existing terminal app. Windows uses
ConPTY and Direct3D 11 directly; macOS uses POSIX PTY and Metal directly;
Linux uses a direct Wayland client + GBM/dma-buf + OpenGL ES renderer, with the
software `wl_shm` renderer kept as a permanent fallback (no GTK / Qt toolkit
dependency, no X11). The shared code owns terminal state and UI
policy, while each host owns the OS event loop and native APIs.

## Layers

| Layer | Shared? | Main files | Responsibility |
|---|---:|---|---|
| Host | No | `src/host/windows.zig`, `src/host/macos.zig`, `src/host/linux_wayland.zig` + `src/host/linux/wayland_minimal.zig` | OS startup, event loop, global hotkey, window lifecycle |
| Instance coordinator | Yes with OS request adapters | `src/main.zig`, `src/instances.zig`, `src/new_instance.zig`, `src/instance_request/*` | Numbered config discovery, worker locks/spawn, two-stage instance creation |
| Window controller | Mostly Windows | `src/window.zig`, `src/app_controller.zig`, `src/app_event.zig` | Win32 message dispatch and app-level event routing |
| Session core | Yes | `src/session_core.zig` | Tabs, active index, scrollback, VT draining, PTY queues |
| Tab behavior | Yes | `src/tab_actions.zig`, `src/tab_interaction.zig`, `src/tab_layout.zig`, `src/pane_layout.zig` | Tab switching, close paths, drag, hit testing. `pane_layout.zig` holds the split-pane tree and per-pane grid geometry (hit test, neighbor search) as pure functions — landed under [#483](https://github.com/ensky0/tildaz/issues/483) step 1, not yet wired into any host |
| Selection | Yes | `src/terminal_interaction.zig` | Drag selection, word selection, wide-cell handling |
| Config | Yes | `src/config.zig`, `src/paths.zig` | Strict schema, defaults, TOML parse via `sam701/zig-toml`, current `config_N.toml` / `tildaz_N.log` paths |
| Dialog/messages | Yes wrapper | `src/dialog.zig`, `src/messages.zig` | Single entry point for user-visible text and dialogs |
| PTY | Wrapper | `src/terminal.zig`, `src/terminal/windows/pty.zig`, `src/terminal/posix/pty.zig` (Linux · macOS shared) | ConPTY or POSIX PTY behind the same external API |
| Renderer (GPU wrapper) | Wrapper (Windows/macOS only) | `src/renderer.zig`, `src/renderer/windows.zig`, `src/renderer/macos.zig` | Tab bar + terminal drawing with a shared call shape. Linux deliberately has no wrapper implementation (see `src/renderer.zig` comment) |
| Renderer (Linux) | No — host-owned | `src/host/linux/software_terminal.zig`, `gl_*.zig` | `software_terminal.zig` owns the draw lists (`FrameLayer` — what to draw where) and the CPU rasterizer; `gl_atlas.zig` / `gl_text.zig` / `gl_rects.zig` consume the *same* lists on the GPU. Shares cross-platform pieces (`tab_layout`, `tab_chrome`, `block_element`, `ui_metrics`) |
| Fonts | Per OS with shared sizing policy | `src/font/spec.zig`, `src/font/windows`, `src/font/macos`, `src/font/linux` | Native font lookup and fallback; separate terminal and fixed-size tab-label contexts/atlases |
| OS services | Wrapper | `src/autostart.zig`, `src/log.zig`, `src/paths.zig` | Startup registration, logging, platform paths |

## Instance Ownership

The launcher serializes numbered-config discovery and the spawn/dialog decision
with one platform-local `launcher.lock`. Worker 0 acquires the same lock around
the hotkey dialog and config-creation transaction. Each `--instance N` worker
then owns an exclusive advisory lock on `instanceN.lock` for its process
lifetime. A launcher or config-creation transaction that starts a worker retains
`launcher.lock` until every new worker has acquired its own lock, preventing
another launcher from observing a partially started set.

Windows manual launches have one additional session-local request mutex. A
launcher tries to acquire it before blocking on `launcher.lock`; only the winner
performs recovery or requests a new instance, while overlapping launchers are
coalesced. If all workers are already running, the winner releases
`launcher.lock` and sends `WM_NEW_INSTANCE_REQUEST` with `SendMessageW`. It keeps
the request mutex until worker 0 returns from the complete Create/Cancel handler.
This ordering is mandatory: waiting synchronously while still owning
`launcher.lock` would deadlock when worker 0 tries to acquire that lock. A launch
that begins after the handler returns can acquire the mutex immediately and is a
new request; there is no cooldown or queue-wide message deletion. Autostart is
not a new-instance request and does not participate in this mutex.

The worker writes its PID only after acquiring `instanceN.lock`. That PID is
diagnostic metadata and a startup acknowledgement, never the liveness source of
truth: stale files and reused PIDs are possible after a crash. Liveness is
decided only by whether the advisory lock can be acquired. Lock files live in
the runtime/cache paths specified by `SPEC.md` §11.1, separate from user config.

Request readiness is a separate policy. After taking `instanceN.lock`, a worker
atomically writes `v1 <PID> starting` to `instanceN.endpoint` before publishing
the owner PID. The host later replaces it with `ready` or `unavailable`. The
launcher accepts `ready` only when the endpoint PID matches the lock owner PID
and the advisory lock is still owned, so a stale file or reused PID cannot pass.
For an actual worker-0 new-instance request, the launcher waits for this state
with a finite timeout and sends only once; the initial launcher still returns
after the existing lock/PID acknowledgement. The ready points are, in platform
order: Linux after the socket and Wayland UI path have initialized; macOS after
the distributed-notification observer, window, renderer, first tab, and display
link are installed; Windows after the HWND, renderer, first tab, and visibility
policy are complete immediately before the message loop.

On Linux, the visible `tildaz.desktop` entry identifies only the launcher. Each
xdg-shell worker uses `tildaz.instanceN` as its Wayland app ID and has a matching
`NoDisplay=true` desktop entry. This keeps GNOME's normal icon click connected to
the launcher `Exec` while giving every worker an identity consistent with its
config, process lock, systemd scope, and KDE Plasma shortcut component.

## Windows Pipeline

1. The coordinator starts one locked `--instance N` worker per numbered config;
   `host/windows.zig` then initializes DPI awareness, config, the Win32 window,
   renderer, and first tab for that worker.
2. A manual launcher owns the request mutex across the synchronous worker-0
   new-instance handler, coalescing concurrent launches without a time heuristic.
3. `window.zig` converts Win32 messages into `app_event.zig`.
4. `app_controller.zig` applies events to tab/session/selection state.
5. `session_core.zig` drains PTY output through `libghostty-vt`.
6. `terminal/windows/pty.zig` creates ConPTY using the bundled
   `_internal\conpty.dll` / `OpenConsole.exe`, which are required (startup
   hard-fails with an error dialog if either is missing; no system fallback).
7. `renderer/windows.zig` draws with DirectWrite glyph rasterization and a
   Direct3D 11 / HLSL atlas pipeline.

## macOS Pipeline

1. The coordinator starts one locked worker per numbered config. `host/macos.zig`
   owns that worker's `NSApplication`, `NSWindow`, global hotkey event tap,
   AppKit input callbacks, and an `NSWindow.displayLink` (CADisplayLink) render
   loop that auto-suspends while hidden (#255, min macOS 14).
2. `terminal/posix/pty.zig` (shared with Linux) uses `openpty` + `login_tty` +
   IUTF8 termios on macOS and tears down child process groups on tab close.
3. The same `session_core.zig` tab/session model is used as Windows.
4. `renderer/macos.zig` draws with CoreText glyph rasterization and a Metal
   atlas. `renderTabBar` starts the frame; `renderTerminal` presents it.
5. `host/macos.zig` implements `NSTextInputClient` for Korean / Japanese /
   Chinese IME pre-edit and reconversion. Since v0.4.3, committed-text Hanja /
   kanji reconversion works for the active terminal row.

## Linux Pipeline

1. The coordinator starts one locked worker per numbered config and synchronizes
   compositor shortcuts. `host/linux_wayland.zig` resolves that worker's config
   and shell, then connects to `host/linux/wayland_minimal.zig`.
2. `host/linux/wayland_minimal.zig` is a direct Wayland wire-protocol client (no
   GTK / Qt). It owns the registry, `xdg-shell` / `wlr-layer-shell` surfaces,
   `wl_shm` / `zwp_linux_dmabuf_v1` buffers, keyboard / pointer / data-device,
   `zwp_text_input_v3` IME,
   the KDE Plasma direct KGlobalAccel D-Bus client, and the main event loop.
3. The same `session_core.zig` tab/session model is used as Windows / macOS.
4. `terminal/posix/pty.zig` (shared with macOS) opens a POSIX PTY (`/dev/ptmx`,
   `setsid`, `TIOCSCTTY` on Linux) behind the shared `terminal.zig` API.
5. `host/linux/software_terminal.zig` builds the per-frame draw lists (cell
   backgrounds, glyphs, procedural rectangles, chrome) and rasterizes them on
   the CPU into an ARGB8888 buffer. The GL path (`gl_rects.zig` / `gl_text.zig`
   / `gl_atlas.zig`, via `egl.zig` + `gbm.zig`) consumes the *same* lists and
   draws into a dma-buf, so the two paths cannot silently diverge. GL is the
   default; `TILDAZ_GL_RENDER=0` falls back to CPU rasterizing into the dma-buf
   and `TILDAZ_DISABLE_GPU=1` to `wl_shm`. Dialog surfaces are always `wl_shm`.
   `xkb.zig`
   (runtime `libxkbcommon`) decodes keys; fonts come from fontconfig + FreeType
   + HarfBuzz via `src/font/linux/*`, all `dlopen`-loaded.
6. Linux custom dialogs use the same font family and fallback chain as the
   terminal, but fixed 15-point body/button and 18-point title contexts.
   `host/linux/dialog_layout.zig` measures the actual message, wraps it within
   the basis output viewport, and returns one content-sized surface layout to
   both the Wayland host and software renderer. The decorative icon is omitted
   only when the full message and buttons otherwise need the vertical space.

The host probes compositor capabilities at startup and degrades gracefully:
`xdg_wm_base` (baseline window — fatal if missing), `zwlr_layer_shell_v1` (true
drop-down; falls back to a normal `xdg-shell` window or a Shell extension on
mutter / muffin), `libxkbcommon` (keymaps), Wayland data-device (clipboard),
and `zwp_text_input_v3` (IME). Global hotkeys use native desktop paths:
direct KGlobalAccel on KDE Plasma, GSettings / Shell extensions on GNOME and
Cinnamon, and compositor bindings to `tildaz --toggle N` on COSMIC, Hyprland,
and sway. An unrecognized desktop can bind that IPC command manually.

## Design Choices

**Native PTY backends.** ConPTY is the supported Windows pseudoconsole API for
terminal emulators. POSIX PTY is the equivalent primitive on macOS. Both are
wrapped behind `terminal.zig` so session code does not care which host it is on.

**Native text engines.** DirectWrite and CoreText are used for glyph shaping and
rasterization because they already understand each platform's font fallback,
emoji, CJK, and antialiasing behavior. TildaZ caches glyphs in GPU atlases.

**Shared policy, native interaction.** User-visible policy is shared where it
matters: tab lifecycle, IME pre-edit display,
selection behavior, config schema, dialogs, and child shell environment. OS
conventions remain native: Windows uses Ctrl/Alt patterns; macOS uses Cmd/Shift
Cmd patterns and AppKit input callbacks.

**Strict config.** `src/config.zig` is the source of truth for the TOML schema
and defaults. Every key is required and unknown keys are fatal, with no
exception -- TOML has real `#` comments, so there is no need for comment-shaped
keys. Numeric fields include their units (`_percent`, `_point`, `_ratio`).

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
| macOS Developer ID signing / notarization | [#109](https://github.com/ensky0/tildaz/issues/109) | Blocked by current signing environment; releases use a stable self-signed TildaZ identity |
| Config hot reload | [#170](https://github.com/ensky0/tildaz/issues/170) | Not started |
| Elevated Windows autostart helper | [#151](https://github.com/ensky0/tildaz/issues/151) | Not started |
| Linux partial redraw | [#362](https://github.com/ensky0/tildaz/issues/362) | Every frame redraws every cell and damages the whole surface. The GPU renderer ([#277](https://github.com/ensky0/tildaz/issues/277)) cut the cost of drawing; drawing *less* is the complementary win, and matters most for interactive typing. |
| Split panes | [#483](https://github.com/ensky0/tildaz/issues/483) | Slow track. Step 1 of 6 landed: `src/pane_layout.zig` (binary split tree with a fixed node pool, per-pane grid via `ui_metrics.terminalCols/Rows`, separator geometry, hit testing, geometric neighbor search) with tests. Nothing is wired into hosts yet; renderer refactor and `SessionCore` tree come next |
| **VT parser throughput** | [#389](https://github.com/ensky0/tildaz/issues/389) (tools in [`dist/stress/`](dist/stress/README.md), built under [#381](https://github.com/ensky0/tildaz/issues/381)) | **Root cause located, fix not started.** We lead on ASCII and sit just under Windows Terminal on wide cells, then fall to **a tenth of it** once a grapheme cluster lands in every cell — reproduced on two Windows machines and macOS. A second workload joined it: **SGR-heavy output (`ansi`) costs our parser 5~6x plain ASCII**, which stays hidden while the PTY is the bottleneck and surfaces on a slower CPU — 19 % of the fastest terminal on the Intel laptop under Linux, with **94 % of the time in `parse`**. See [Performance Notes](#what-decides-where-we-lose-our-parser-ceiling-versus-the-pty-ceiling-389). Next, in order: **(1)** the parser, which the app's own counters put at 68-83 % of the time on cluster-heavy output — that is inside ghostty-vt, so profile first and take it upstream; **(2)** cut the number of native shaping calls (run batching, then a cluster cache on top) — the paired workloads showed batching is the necessary part, and the win is per-frame cost (4.35 ms/frame on `zwj`) rather than throughput. The `hangul` wide-cell gap is consistent across both machines once payload size is right (80 % and 94 % of wt), so it is a smaller sibling of the same story rather than its own item. Linux is now measured (all eleven workloads, six terminals, 330 runs); the attribution pairs there agree with Windows within -1~-6 %, so run batching stays ahead of a cluster cache. Still unmeasured: the same tables on macOS |

Completed cross-platform unification work is tracked in
[#171](https://github.com/ensky0/tildaz/issues/171),
[#176](https://github.com/ensky0/tildaz/issues/176), and the release notes.

## Distribution

Official release artifacts are generated by `.github/workflows/release.yml`
from `v*` tags.

The sole version source is `.version` in `build.zig.zon`. `build/version.zig`
validates either `X.Y.Z` or `X.Y.Z-(dev|alpha|beta|rc).N` (`N` is 1–255), then
derives the runtime/About version, package metadata, generated macOS
`Info.plist`, generated Windows `VERSIONINFO`, and artifact names. The tag must
match the complete source version, including any prerelease suffix. This keeps
the public version compliant with [Semantic Versioning](https://semver.org/)
while adapting it to each platform's native constraints:

- Linux packages use `X.Y.Z~stage.N-1` for Debian,
  `Version: X.Y.Z~stage.N` plus `Release: 1` for RPM, and
  `pkgver=X.Y.Zstage.N` plus `pkgrel=1` for Arch Linux. These spellings preserve
  prerelease ordering under the respective
  [Debian](https://www.debian.org/doc/debian-policy/ch-controlfields.html#version),
  [RPM](https://rpm.org/docs/latest/manual/spec.html#version), and
  [Arch Linux](https://man.archlinux.org/man/PKGBUILD.5.en.html) rules.
- macOS uses `X.Y.Z` for `CFBundleShortVersionString` and
  `(X+1).Y.Z{d|a|b|fc}N` for `CFBundleVersion`; the major offset keeps the first
  component positive while preserving ordering across the `0.x` series and
  `1.0.0`. This follows Apple's
  [bundle version format](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html).
- Windows stores `X,Y,Z,R` in the four numeric `VERSIONINFO` fields and the full
  Semantic Version in the display strings. `R` uses ordered prerelease ranges
  and `65535` for a final release; prereleases also set `VS_FF_PRERELEASE`, as
  defined by Microsoft's
  [`VERSIONINFO` reference](https://learn.microsoft.com/en-us/windows/win32/menurc/versioninfo-resource).

| Platform | Artifact | Signing |
|---|---|---|
| Linux x86_64 / aarch64 | `tildaz-v<ver>-linux-<arch>.{tar.gz,deb,rpm,AppImage}`, the AppImage as `TildaZ-...`, plus an Arch package `tildaz-<ver>-1-x86_64.pkg.tar.zst` (x86_64 only) | Unsigned; relies on per-distro install path verification. Native dependencies (Wayland / xkbcommon / FreeType / fontconfig / HarfBuzz / D-Bus) are all runtime `dlopen`, so the binary itself has no hard-linked libraries beyond glibc 2.28+. The `.deb` / `.rpm` packages declare the core libraries (xkbcommon, freetype, fontconfig) as dependencies so a fresh install pulls them in. |
| macOS | `tildaz-v<ver>-macos.dmg` | Universal app bundle (Apple Silicon + Intel), stable self-signed TildaZ identity; not Apple-notarized |
| Windows x64 | `tildaz-v<ver>-win-x64.zip` | Currently unsigned TildaZ binary; bundled Microsoft ConPTY files are Microsoft-signed |
| Windows ARM64 | `tildaz-v<ver>-win-arm64.zip` | Same as x64 with ARM64-native binaries |

The release workflow checks that:

- the complete tag version matches `build.zig.zon`'s `.version`;
- `dist/release-notes/v<ver>.md` exists for a stable tag (optional for a
  prerelease validation tag);
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

Throughput of the PTY → VT path is measured by the stress harness in
[`dist/stress/`](dist/stress/README.md) (`zig build stress`), which runs the same
way on Linux, macOS, and Windows. It splits the path into a parser-only layer and
a full PTY layer so the cost of PTY reads and the output ring can be separated
without `perf`. Measured numbers belong in
[#371](https://github.com/ensky0/tildaz/issues/371) together with the build mode,
grid, workload, and machine — absolute values differ per machine, so the
repository keeps no baseline.

### What decides where we lose: our parser ceiling versus the PTY ceiling (#389)

Two workloads beat us, and they are the two where our VT parser is slower than the
PTY can deliver: **grapheme clusters** everywhere, and **SGR-heavy output** on a
slower CPU. Which one shows up is not a property of the workload alone — a parser
ceiling only becomes visible once it drops below the PTY ceiling on that machine.

| Layer ceiling, 64 MiB | `plain` | `ansi` | `cjk` |
|---|---:|---:|---:|
| Parser, macOS M5 Pro | 736 | 149 | 119 |
| Parser, Linux Intel i5-1240P | 278 | **48** | 40 |
| PTY delivery, roughly | ~130 | ~130 | ~130 |

On the M5 Pro the `ansi` parser runs at 149 MiB/s, above PTY delivery, so the PTY
is the bottleneck and the app ranks first on that workload. On the Intel laptop the
same parser runs at 48 MiB/s, below delivery, so it is exposed and the app drops to
19 % of the fastest terminal. The app's own counters confirm the layer: `ansi`
spends **94 % in `parse`**, and its per-frame `render` is *cheaper* than `plain`'s
(0.44 vs 0.67 ms) because it has no clusters to shape. SGR parsing costs 5~6x plain
ASCII for us on both platforms, while foot pays nothing for it (120.2 → 120.1
MiB/s). That cost is inside ghostty-vt, the same place as (1) below.

The cluster story below is measured on Windows; the `ansi` finding above is from
Linux. Both are the same parser, so neither is host-specific.

### Grapheme clusters (#381)

Measured on Windows with every terminal on the same scrollback (32,767 lines) and
the same 120x40 grid. **Read the ratio to Windows Terminal, not the rank** — how fast
the other terminals run varies enormously per machine, so ranks move while the ratio
does not. Full tables and conditions are in
[#381](https://github.com/ensky0/tildaz/issues/381) and
[#389](https://github.com/ensky0/tildaz/issues/389).

| Workload | Content | AMD laptop, 200 % | Intel laptop, 100 % |
|---|---|:--:|:--:|
| `plain` | ASCII | 1st | 1st — **108 %** of wt |
| `ansi` | SGR escapes | 2nd | 2nd — **92 %** |
| `hangul` | wide cells, no grapheme extras | 2nd — 80 % of wt | 2nd — **94 %** |
| `cjk` | above plus a few clusters per line | 2nd — 59 % of wt | 2nd — **56 %** |
| `emoji_vs16` | one VS-16 cluster per cell | last | 3rd of 5 — **10 %** |
| `zwj` | one ZWJ-family cluster per cell | last | **last** — **10 %** |

The two machines agree: we lead on ASCII, sit just under Windows Terminal on wide
cells, and fall to **a tenth of it** once a grapheme cluster lands in every cell.

⚠️ **Payload size decides whether this table is true at all.** The harness times from
the producer's last *write*, not from the terminal finishing its work, and the
un-consumed residue is a fixed read-buffer size (~3 MB for us). At 8 MiB that residue
flattered us enough to invert three rows — `cjk` read 114 % instead of 56 %, and
`emoji_vs16` 25 % instead of 10 %. Record runs use **64 MiB**, and the script now warns
below that; the details are in
[`dist/stress/README.md`](dist/stress/README.md).

Line width is what makes these comparable at all. A ZWJ family is one cluster to
terminals that fold it and up to 8 columns to terminals that do not (they count the
ZWJ itself as a column), so a line sized for the folding case wraps in the others and
a differing row count makes the rates incomparable. The attribution workloads carry
**13 items** per line for that reason (`10 + 13 x 8 <= 120`); absolute MiB/s from
before that change cannot be compared with numbers after it.

Going from `cjk` to `zwj`, the other terminals get *faster* (more bytes per cluster
means less per-cell work per byte) while we get **3.3x slower** — 45.2 to 13.5 MiB/s on
the Intel laptop at 64 MiB, while Windows Terminal gained 72 %, conhost 122 %, and
wezterm 176 % over the same step. That asymmetry is the fingerprint of a per-cluster
cost the others do not pay, and it has two layers:

1. **Parsing** — a grapheme codepoint costs about 5x a non-grapheme one. This is
   inside ghostty-vt (`Terminal.print` plus the per-page grapheme arena, which
   starts at 8 KiB and doubles). Two independent workloads agree within 2.7 %, so
   the cost scales with codepoints, not with clusters.
2. **Rendering — no shaping cache.** `resolveGrapheme` has no memoization and the
   renderer's cell loop calls it per cell per frame: about 84,000 DirectWrite
   shaping calls per second for what is often a single distinct cluster on screen.
   The GPU atlas caches *rasterized* glyphs, not the shaping result. The same gap
   exists on all three platforms — Windows caches single codepoints
   (`glyph_map`), macOS caches ligature pairs (`ligature_cache`), and neither
   caches arbitrary clusters; macOS additionally builds a `CTLine` per call.

**Which layer dominates depends on what you are measuring, and the app's own counters
settle it.** Dumping `perf` (`Ctrl+Shift+F12`) after an 8 MiB run on the Intel laptop:

| Workload | `parse` | `render` | `present` | frames drawn | parse share |
|---|---:|---:|---:|---:|---:|
| `plain` | 26.0 ms | 12.9 | 1.4 | 5 (155 skipped) | 64 % |
| `cjk` | **139.9 ms** | 24.2 | 3.4 | 13 (148 skipped) | **83 %** |
| `emoji_vs16` | **448.6 ms** | 92.5 | 8.4 | 36 (126 skipped) | **82 %** |
| `zwj` | **296.7 ms** | 126.2 | 13.7 | 29 (133 skipped) | **68 %** |

**Parsing dominates bulk throughput** — 68-83 % on cluster-heavy output — because
parsing is paid per byte while rendering is paid per *frame*, and 8 MiB of output
draws only 13-36 frames (the rest are skipped as idle, #386). So the throughput gap
against Windows Terminal is mostly (1), not (2).

**Rendering still matters, as per-frame cost.** `zwj` costs 4.35 ms per frame — 26 %
of a 60 Hz budget and 52 % of 120 Hz. Fixing (2) buys responsiveness and frame
stability, not the throughput ranking; size the expectation accordingly.

Reading the Windows Terminal source showed it has **no shaping
cache either** — the difference is the *call unit*. It maps one whole font-face run
per `MapCharacters`, skips shaping altogether for simple text
(`IDWriteTextAnalyzer::GetTextComplexity`), and shapes a whole script run with one
`GetGlyphs`. A `zwj` line costs it 3-4 DirectWrite calls where it costs us 70-140,
because our cell loop calls `resolveGrapheme` once per grapheme cell and the user
font chain multiplies that (a face is rejected when *any* glyph in the cluster comes
back `.notdef`, so each cluster walks the chain until one accepts). Non-grapheme
cells never pay this — they hit the single-codepoint `glyph_map` — which is why the
same renderer ranks first on ASCII.

Two fixes, not mutually exclusive — **both are now in on all three platforms**
([#399](https://github.com/ensky0/tildaz/issues/399)):

- **(A) run batching** — helps always, including clusters seen for the first time.
  The cell loop collects a run of consecutive grapheme cells, shapes it with **one**
  API call, and distributes the glyphs back per cell.
- **(B) cluster shaping cache** — skips the shape call entirely when a cluster
  repeats. Shared skeleton in [`src/font/cluster_cache.zig`](src/font/cluster_cache.zig),
  per-platform value type.

The measured cost is roughly a 3 µs fixed part plus 0.6 µs per UTF-16 unit, so call
count dominates and (A) attacks it directly. **The paired `*_varied` workloads settled
the order: (A) first.** Each pair holds the code path and the line bytes and varies
only the number of distinct kinds, so the gap within a pair is the share that
repetition explains.

| Pair | ours, repeated → varied | Windows Terminal, repeated → varied |
|---|---:|---:|
| `emoji_vs16` | 25.5 → 25.2 (**-1 %**) | 102.6 → 80.7 (-21 %) |
| `skintone` | 30.5 → 28.7 (**-6 %**) | 101.1 → 83.6 (-17 %) |
| `zwj` | 30.3 → 29.2 (**-4 %**) | 122.1 → 122.7 (+0.5 %) |

These pairs were run at 8 MiB, so read the **within-pair** deltas, not the absolute
numbers or the cross-terminal ratio — both carry the payload bias described above. Both
members of a pair were measured identically, so the delta is sound.

Repetition bought us nothing before (A) — that is what "no cache" looks like — and a
cache alone would not have closed the gap either, because it survives where a cache
cannot help: on `emoji_vs16_varied` every cluster is new. That residue was the call
unit, which is why (A) came first and (B) sits on top of it.

### What each platform actually does

The cell loop lives in three places, so **only the run-boundary rule is shared**; the
shaping call and the glyph-to-cell mapping are per platform. The cache is the opposite
— one shared skeleton, and only the value type and its release differ.

| | shaping call | glyph → cluster mapping | font choice | cached value / release |
|---|---|---|---|---|
| **macOS** | CoreText `CTLine` | `CTRunGetStringIndices` | **CoreText picks** | `GlyphResult` / `CFRelease` |
| **Windows** | DirectWrite `GetGlyphs` | `cluster_map` | we walk the chain | `ClusterResult` / COM `Release` |
| **Linux** | HarfBuzz `shapeRunOnFace` | `hb_glyph_info_t.cluster` | we walk the chain | `LigatureGlyph` / **none** (index) |

Two consequences worth knowing before touching this code:

- **Windows and Linux need a per-face retry that macOS does not.** They pick the font
  themselves, so shaping a whole run on one face can succeed for some clusters and
  fail for others. macOS hands that job to CoreText. All three currently take the
  simple policy: if any cluster in the run fails, the whole run falls back to the
  per-cluster path.
- **Ownership is the trap.** Where the cached value owns a font handle (macOS, Windows),
  the cache takes ownership and hands callers `owned = false` — otherwise the cell
  loop's per-frame release kills the cached font. And since `ClusterCache.put` frees
  values it cannot store (over the 8-codepoint key limit), callers must check
  *before* handing ownership over. macOS needs that check in the run path too, because
  it retains per cluster there; Windows does not, because its run results are chain
  faces it never owned.

### Result

`zwj`, 64 MiB, 5-run trimmed mean, ms. **Before = neither fix; after = both.**
Hardware differs per row, so **read the deltas, not the absolute values** — only the
Windows and Linux rows share a machine.

| platform | render | shape | shape / render | per-frame render |
|---|---|---|---|---|
| **macOS** (M5 Pro) | 305.3 → **19.8** (**-93.5 %**) | 283.1 → **1.8** | 92.7 % → **9.2 %** | 2.86 → **0.18** |
| **Windows** (i5-1240P) | 896.6 → **39.9** (**-95.6 %**) | — → **4.9** | 94.8 % → **11.7 %** | 4.37 → **0.25** |
| **Linux** (i5-1240P) | 1354.2 → **285.4** (**-78.9 %**) | 1261.2 → **200.6** | — | — |

**Shaping no longer dominates rendering on any platform.** How the two fixes split
that total is the mirror of what each API costs per call:

| | batching (`zwj` render) | caching (`zwj` shape) |
|---|---|---|
| macOS | **-67 %** | -97.9 % |
| Windows | -46 % | **-99.1 %** |
| Linux | **-0.6 %** | -84 % |

- **Batching** cuts the *number* of calls, so it paid where per-call fixed cost is
  high, and barely showed on Linux where HarfBuzz's per-call cost is already small.
  Windows gains less than macOS on `zwj` because its ZWJ families shape to multiple
  glyphs — distributing those and drawing a composite in the atlas is work batching
  does not remove. On the single-glyph `emoji_vs16` it beat macOS (-71.9 % vs -63 %).
- **Caching** removes the call itself, so it paid most where a call was most expensive:
  Windows (chain walk plus COM round trips), then macOS (`CTLine` build), then Linux.

Linux also carries a third step between the two — a **width hint** that cut `zwj`
render 1345.5 → 1225.6 before the cache landed.

With rendering fixed, `parse` is now essentially the whole frame budget on
cluster-heavy output (`zwj` parse share 93 % → **98.6 %** on macOS, **98.5 %** on
Windows). The remaining work is the parser, which is upstream — see
[#389](https://github.com/ensky0/tildaz/issues/389).

One more caveat the same run exposed: `hangul_varied` swings 17.2-88.0 MiB/s between
repeats of one measurement. It walks all 11,172 precomposed syllables, so the pressure
is on the glyph atlas and `glyph_map`, not on shaping — a separate thread to pull.

## Linux Integration References

- KGlobalAccel root D-Bus interface — action registration, shortcut assignment,
  owner lookup, and component discovery:
  <https://github.com/KDE/kglobalaccel/blob/master/src/org.kde.KGlobalAccel.xml>
- KGlobalAccel Component D-Bus interface — pressed signal and inactive
  lifecycle:
  <https://github.com/KDE/kglobalaccel/blob/master/src/org.kde.kglobalaccel.Component.xml>
- `wlr-layer-shell` — desktop layer surfaces anchored to an output edge:
  <https://wayland.app/protocols/wlr-layer-shell-unstable-v1>
- `xdg-shell` — baseline Wayland protocol for normal toplevel windows:
  <https://wayland.app/protocols/xdg-shell>
- `libxkbcommon` — shared keyboard handling library:
  <https://xkbcommon.org/>
- Wayland `text-input-v3` — pre-edit and commit-string events for IME (protocol
  family is still unstable/experimental):
  <https://wayland.app/protocols/text-input-unstable-v3>
