# Architecture

TildaZ runs as a native host on Windows and macOS, sharing cross-platform
session / VT / config / dialog / themes / terminal-interaction / tab-interaction
modules. Platform seams are the host (`windows_host.zig` / `macos_host.zig`),
the PTY backend (ConPTY / POSIX), the window layer (Win32 / NSWindow), and the
renderer (Direct3D 11 / Metal). The architecture review history lives in
[#91](https://github.com/ensky0/tildaz/issues/91); the cross-platform behavior
matrix lives in [SPEC.md](SPEC.md).

## Windows pipeline

1. `windows_host.zig` — DPI awareness, single-instance, config, autostart, window, renderer, initial tab
2. `window.zig` — Win32 messages → `app_event.zig`
3. `app_controller.zig` — event → tab / session / selection / rename / scroll
4. `session_core.zig` — tab list, active tab, scrollback, VT drain, PTY queue
5. `terminal_backend.zig` → `conpty.zig` (bundled `conpty.dll` / `OpenConsole.exe`, fallback to `kernel32 CreatePseudoConsole`)
6. PTY read thread → lock-free ring buffer → render callback drains through ghostty VT parser
7. `renderer_backend.zig` → `d3d11_renderer.zig` (DirectWrite + Direct3D 11 / HLSL, dynamic glyph atlas)

## macOS pipeline

1. `macos_host.zig` — NSApplication accessory mode, NSWindow at popUpMenu level (101), CGEventTap for global hotkey, render timer via CFRunLoopTimer
2. `macos_pty.zig` — POSIX PTY (`openpty` + `login_tty` + IUTF8). SIGHUP-ignoring shells get SIGKILL after a 500 ms grace
3. Same cross-platform `session_core` analog (`macos_session.zig`) — schema-compatible with Windows `session_core`
4. `macos_metal.zig` — Metal renderer (CAMetalLayer + MTLCommandQueue), retina-aware glyph atlas
5. `macos_font.zig` — CoreText with explicit *glyph fallback chain* (config.font.family) + system auto fallback (`CTFontCreateForString`) for codepoints outside the chain
6. NSTextInputClient implementation for IME (Korean / Japanese / Chinese composition) — inline pre-edit overlay, syllable-boundary commit
7. macOS quirks tracked in [AGENTS.md § macOS Cocoa quirks](AGENTS.md): `atexit()` for `[exit]` log line (NSApp `terminate:` skips `defer`), `ApplePressAndHoldEnabled = false` for English key repeat, NSAlert TextView selection-auto-copy for Cmd+C routing, etc.

## Why these choices

**ConPTY / OpenConsole** (Windows). ConPTY is the standard for attaching both
legacy Console-API apps and VT-based apps to an external terminal window. TildaZ
bundles OpenConsole to flatten out system-conhost version variance and falls back
to `kernel32 CreatePseudoConsole` when the bundle is missing.

**POSIX PTY + login_tty** (macOS). `login_tty` makes the child a new session
leader so `kill(-pid, SIGHUP)` cleans up the whole process group on tab close.
IUTF8 termios bit is set so multi-byte input does not mangle Korean / Japanese
keystrokes.

**Direct3D 11 / Metal**. GPU-accelerated rendering is necessary for bulk output
+ deep scrollback to keep up with modern terminals (Windows Terminal, WezTerm,
Ghostty, Alacritty). Both backends rasterize through the platform's native
text engine (DirectWrite / CoreText), atlas glyphs once, and re-blit textured
quads per frame.

**Cross-platform native first**. Each OS's modifiers / shortcut order /
config-file conventions follow the platform standard rather than a forced
identical UX (Apple HIG `Shift+Cmd` order on macOS, Windows `Ctrl+Shift`;
`%APPDATA%\tildaz\` on Windows, XDG `~/.config/tildaz/` on macOS). See
[AGENTS.md](AGENTS.md).

## Open structural work

- Cross-platform `config.zig` unification ([#118](https://github.com/ensky0/tildaz/issues/118)) — schemas already compatible at the field level, the parser file is still split.
- macOS Developer ID code signing + notarization ([#109](https://github.com/ensky0/tildaz/issues/109)) — currently ad-hoc signed; per-rebuild identity changes invalidate Input Monitoring / Accessibility grants.
- Linux backend (Wayland / X11) — not yet started.
- Stress tests for bulk output, resize storms, output-pipe-full during tab close, WSL/nvim/mouse, and CJK/emoji/combining marks should be pinned down separately.

## Tech stack

| Component | Windows | macOS |
|-----------|---------|-------|
| Language | Zig 0.15.2 | Zig 0.15.2 |
| Terminal emulation | [libghostty-vt](https://github.com/ghostty-org/ghostty) | [libghostty-vt](https://github.com/ghostty-org/ghostty) |
| PTY backend | ConPTY (`conpty.zig`) | POSIX (`macos_pty.zig`) — `openpty` + `login_tty` + IUTF8 |
| PTY host | Bundled `OpenConsole.exe` + `conpty.dll` ([microsoft/terminal](https://github.com/microsoft/terminal), MIT); falls back to system conhost | (kernel) |
| Window | Win32 API (borderless popup) | NSWindow (popUpMenu level 101) |
| Hotkey | `RegisterHotKey` | CGEventTap (Input Monitoring + Accessibility) |
| Renderer | Direct3D 11 + HLSL (ClearType subpixel) | Metal + CoreText |
| Font | DirectWrite — explicit glyph fallback chain | CoreText — explicit glyph fallback chain + system auto fallback |
| IME | Win32 IMM | NSTextInputClient (markedText pre-edit) |
| Autostart | HKCU `Run` registry entry | LaunchAgent plist (`~/Library/LaunchAgents/com.tildaz.app.plist`) |
| Log path | `%APPDATA%\tildaz\tildaz.log` | `~/Library/Logs/tildaz.log` (Console.app indexed) |
| Config path | `%APPDATA%\tildaz\config.json` | `~/.config/tildaz/config.json` (XDG) |

## Performance (Windows)

Measured at v0.2.6, still the baseline. All numbers are median of 3 runs of
`time cat ~/repo/s2t/bitext_eng_kor.vocab` (1.14 MiB CJK) inside WSL Debian,
with the window snapped to the left half of the screen (same grid as Windows
Terminal for comparability).

| Path | `time cat` real | Throughput | vs WT |
|------|-----------------|------------|-------|
| baseline v0.2.5 (system conhost) | 0.293s | ~4.7 MiB/s | 3.2× slower |
| #77 overlapped 128KB read | 0.266s | ~5.2 MiB/s | 2.9× slower |
| #78 bundled OpenConsole (with regression) | 0.133s | ~10.5 MiB/s | 1.4× slower |
| **v0.2.6 (#77 + #78 + #79)** | **0.074s** | **~15.4 MiB/s** | **1.26× faster** |
| Windows Terminal (reference, same grid) | 0.093s | ~12.3 MiB/s | 1.0× |

- **#77** — Replace ConPTY output pipe with a named pipe + `FILE_FLAG_OVERLAPPED`, 128KB overlapped `ReadFile` + `GetOverlappedResult` pattern. Per-stage atomic counters in `src/perf.zig` collected continuously; snapshot via Ctrl+Shift+P.
- **#78** — Ship `OpenConsole.exe` (1.04 MB) + `conpty.dll` (110 KB) from Microsoft.Windows.Console.ConPTY nuget `1.24.260303001` under `vendor/conpty/`. At startup, `LoadLibraryW("conpty.dll")` is tried; on success `ConptyCreatePseudoConsole` replaces the kernel32 version. Missing DLL falls back to kernel32. This pinned down that the actual bottleneck was system conhost's internal flush timing.
- **#79** — Fix a regression where the bundled OpenConsole's `VtIo::StartIfNeeded` waits up to 3 seconds for a DA1 response (`\x1b[c`) at startup. (a) Pre-write `\x1b[?61c` (VT500 conformance) to the input pipe immediately after `CreateProcessW`, (b) call `ConptyShowHidePseudoConsole(true)` before `CreateProcessW`. Tab cold start ~3997ms → **~548ms**; as a side effect `time cat` improved from 0.133s → 0.074s (the VT engine was not fully initialized during the DA1 wait, propagating delay into the data path).

Tab startup time (`"wsl.exe -d Debian --cd ~"`, warm):

| Path | Prompt visible |
|------|----------------|
| baseline (kernel32, system conhost) | ~860 ms |
| right after #78 (bundled OpenConsole, regression) | ~3997 ms |
| **v0.2.6 (#78 + #79)** | **~548 ms** |
| lower bound for raw `wsl + bash interactive` | ~480 ms |

macOS performance has not been benchmarked in the same harness. Subjectively the Metal path matches the D3D11 path; formal numbers are open work.

## Distribution and code signing

### Windows — current state: unsigned build

GitHub Release Windows binaries are not yet Authenticode-signed. Some Windows Defender / Endpoint Security products (CrowdStrike, SentinelOne, etc.) flag the combination of unsigned binary + ConPTY-based child process spawn + multi-threading as suspicious behavior and can block execution.

If your AV/EDR flags `tildaz.exe`:

- With admin rights, add a SHA256 allowlist exception in your EDR
- On a corporate-managed PC, file a false-positive report with your security team
- Or copy the binary to a local-disk path (e.g. `%LOCALAPPDATA%\Programs\tildaz\`) before running — execution from UNC paths is scored as more suspicious

Plan: applying to the [SignPath Foundation open-source code-signing program](https://about.signpath.io/foundation). Once approved, future releases will ship with an Authenticode-signed `tildaz.exe`.

### macOS — current state: ad-hoc signed build

The Zig build runs `codesign --sign - --force --timestamp=none` on `TildaZ.app`. This is enough for the app to launch from `/usr/bin/open`, but Apple Developer ID signing + notarization (which would let users skip the Gatekeeper warning) is blocked by corporate keychain policy in the current build environment ([#109](https://github.com/ensky0/tildaz/issues/109)). When unblocked, releases will ship as a signed + notarized `.app` (zip or dmg) and Input Monitoring / Accessibility grants will persist across rebuilds (instead of being invalidated by the per-build ad-hoc identity).
