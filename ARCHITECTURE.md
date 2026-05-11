# Architecture

TildaZ runs as a native host on Windows and macOS, sharing cross-platform
session / VT / config / dialog / themes / terminal-interaction / tab-interaction
/ tab-layout / tab-actions modules. Platform seams are the host
(`host/windows.zig` / `host/macos.zig`), the PTY backend (ConPTY / POSIX),
the window layer (Win32 / NSWindow), and the renderer (Direct3D 11 / Metal).
The architecture review history lives in [#91](https://github.com/ensky0/tildaz/issues/91);
the cross-platform behavior matrix lives in [SPEC.md](SPEC.md). The recent
cross-platform unification work (v0.4.1 Phase 0-7) is tracked in
[CROSS_PLATFORM.md](CROSS_PLATFORM.md) + [#171](https://github.com/ensky0/tildaz/issues/171).

## Cross-platform modules

The shared logic that drives both hosts:

| Module | Purpose |
|---|---|
| `session_core.zig` | Tab list, active-tab index, `MAX_TABS = 32` cap, scrollback, VT drain, PTY queue. Both hosts hold a single `SessionCore`. |
| `tab_interaction.zig` | `RenameState` + `RenameView` (rename buffer, cursor, IME-aware insert), `DragState` + `DragView` (5px threshold, world-coordinate drag follow). Both renderers consume the views directly. |
| `tab_layout.zig` | Pure layout / hit-test math for the tab bar (Firefox pattern: `<` `[tabs]` `+` `>`), arrow scroll alignment (floor / ceil), `renameTextHit` (mouse → byte index), and the IME-aware cursor-follow-scroll helpers (`cursorReserve`, `computeAdvanceTotal`, `cursorScrollOffset`). |
| `tab_actions.zig` | `Host` interface (session ptr, override flag, 5 platform callbacks: invalidate / rename_active / insert_rename_cp / clipboard_copy / terminate) + helpers for `switchTab` / `nextTab` / `prevTab` / `resetActive` / `closeActive` / `closeByPtr` / `closeIndex` / `copyActiveSelection` / `routePaste` / `checkAtLimitAndDialog`. Each helper sequences post-action work (override clear → invalidate → optional terminate) so call sites stay one line. |
| `terminal_interaction.zig` | Cell selection / drag / word selection (wide-char-aware boundary). |
| `dialog.zig` + `messages.zig` | Single entry point for user-facing text and modal dialogs (`MessageBoxW` / `NSAlert`). |
| `themes.zig` | 18 built-in colour palettes + `COLORFGBG` derivation. |
| `terminal.zig` | comptime PTY dispatch — `terminal/windows/pty.zig` (ConPTY) / `terminal/macos/pty.zig` (POSIX). Identical external API on both platforms. |
| `renderer.zig` | comptime Renderer dispatch — `renderer/windows.zig` (D3D11) / `renderer/macos.zig` (Metal). Both expose `renderTabBar` + `renderTerminal` with stateful frame lifecycle (v0.4.1). |
| `dialog.zig` / `autostart.zig` / `log.zig` / `font/validate.zig` | Wrapper + comptime select for the per-OS implementations. |

## Windows pipeline

1. `host/windows.zig` — DPI awareness, single-instance, config, autostart, window, renderer, initial tab
2. `window.zig` — Win32 messages → `app_event.zig`
3. `app_controller.zig` — event → tab / session / selection / rename / scroll
4. `session_core.zig` — tab list, active tab, scrollback, VT drain, PTY queue
5. `terminal.zig` → `terminal/windows/pty.zig` (bundled `conpty.dll` / `OpenConsole.exe`, fallback to `kernel32 CreatePseudoConsole`)
6. PTY read thread → lock-free ring buffer → render callback drains through ghostty VT parser
7. `renderer.zig` → `renderer/windows.zig` (DirectWrite + Direct3D 11 / HLSL, dynamic glyph atlas)

## macOS pipeline

1. `host/macos.zig` — NSApplication accessory mode, NSWindow at popUpMenu level (101), CGEventTap for global hotkey, render timer via CFRunLoopTimer
2. `terminal/macos/pty.zig` — POSIX PTY (`openpty` + `login_tty` + IUTF8). SIGHUP-ignoring shells get SIGKILL after a 500 ms grace
3. Same cross-platform `session_core.zig` as Windows (no platform-specific session module since v0.4.0)
4. `renderer/macos.zig` — Metal renderer (CAMetalLayer + MTLCommandQueue), retina-aware glyph atlas. Frame lifecycle stateful between `renderTabBar` (begin) and `renderTerminal` (present + commit) — same call shape as Windows (v0.4.1)
5. `font/macos/font.zig` — CoreText with explicit *primary + glyph fallback chain* (`config.font.family` string + `config.font.glyph_fallback` array, all entries strict-validated) + system auto fallback (`CTFontCreateForString`) for codepoints outside the chain
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

- macOS Developer ID code signing + notarization ([#109](https://github.com/ensky0/tildaz/issues/109)) — currently ad-hoc signed; per-rebuild identity changes invalidate Input Monitoring / Accessibility grants.
- macOS NSTextInputClient reconversion API ([#166](https://github.com/ensky0/tildaz/issues/166)) — Hanja / kanji conversion via Option+Return needs `attributedSubstring(forProposedRange:actualRange:)` + `firstRect(forCharacterRange:actualRange:)`. Apple's own Terminal.app does not implement these either; matching their behavior is the current state.
- Config hot-reload ([#170](https://github.com/ensky0/tildaz/issues/170)) — disk file watch + per-field hot-apply dispatch (theme / opacity / dock_position / hotkey instant; font / shell heavier).
- Windows `auto_start_elevated` config option ([#151](https://github.com/ensky0/tildaz/issues/151)) — automate the Task Scheduler `/RL HIGHEST` registration documented in README §Known limitations.
- Linux backend (Wayland / X11) — not yet started; the cross-platform unification (v0.4.1) leaves only `host/linux.zig` to write; the rest of the wrapper hierarchy already accepts a third platform via comptime dispatch.
- Stress tests for bulk output, resize storms, output-pipe-full during tab close, WSL/nvim/mouse, and CJK/emoji/combining marks should be pinned down separately.

## Recently closed structural work

- **Per-tab terminal_interaction + cross-platform `cancelPointerModes` + β policy on tab switch** ([#174](https://github.com/ensky0/tildaz/issues/174), v0.4.2) — Windows `App.terminal_interaction` global moved to `session_core.Tab.interaction` per-tab (#159 leftover; macOS already used per-tab state). macOS gains the `cancelPointerModes` call on tab-bar clicks (Windows-equivalent). Keyboard tab-switch cleans up in-progress drag state on the source tab while preserving finished highlights (β policy, matches iTerm2 / Terminal.app / WezTerm / Alacritty).
- **Rename auto-commit on every focus loss** ([#175](https://github.com/ensky0/tildaz/issues/175), v0.4.2) — inline-rename spec unified across mouse, keyboard shortcut, and F1 hide. Any focus-loss action ⇒ current input is committed as the new tab title. Only `Esc` cancels. Windows `.shortcut` keyboard dispatch (Ctrl+N tab-switch, Ctrl+T new tab, Ctrl+W close, …) previously bypassed `commitRename`; both platforms previously dropped the rename on F1 hide. `Window.before_hide_fn` callback added so the app layer can commit on hide without breaking the window/app dependency direction. SPEC `§4.1` documents every action's expected behavior.
- **Cross-platform unification v0.4.1 — Phase 0-7** ([#171](https://github.com/ensky0/tildaz/issues/171), [CROSS_PLATFORM.md](CROSS_PLATFORM.md)) — dead-code cleanup in `host/macos.zig`, About-dialog wrapper consolidation, Windows-only helper renaming, first-run `$SHELL` resolution for macOS shell default, `font.family` + `font.glyph_fallback` schema breaking (primary string + array of fallbacks, both strict-validated), Metal renderer split into `renderTabBar` + `renderTerminal` with stateful frame lifecycle matching Windows, and config schema unit-suffix sweep (`width_percent` / `height_percent` / `offset_percent` / `opacity_percent` as floats, `size_point`, `cell_width_ratio`, `line_height_ratio`; window-side `cell_width_px` / `cell_height_px`).
- **Tab bar / actions / IME pre-edit cross-platform unification** ([#159](https://github.com/ensky0/tildaz/issues/159) Phase 1-3, [#163](https://github.com/ensky0/tildaz/issues/163) Phase 4, v0.4.0) — `tab_layout.zig` extracted (Phase 1), `tab_actions.zig` + `Host` interface (Phase 2), `closeByPtr` / `closeIndex` unified close path (Phase 3), `RenameView` / `DragView` / `TabBarLayout` struct unified across both renderers (Phase 4), and the cursor-follow-scroll math (`cursorReserve` / `computeAdvanceTotal` / `cursorScrollOffset`) shared by both renderers and both hosts' click → cursor logic (option A). About ~400 lines of duplicated cross-platform code removed; future fixes land in one place.
- **Windows IME pre-edit overlay + candidate-popup tracking** ([#164](https://github.com/ensky0/tildaz/issues/164), v0.4.0) — `WM_IME_*` hooked, `ImmGetCompositionStringW` reads `GCS_COMPSTR`, inline purple overlay at the cursor matches macOS, `ImmSetCompositionWindow(CFS_POINT)` keeps the Hanja / kanji / hanzi candidate popup next to the cursor, native-textbox tab-rename UX (click cursor reposition, mid-string push-right, fixed pre-edit reserve).
- **Rename text cursor click → no longer pins to right edge** ([#168](https://github.com/ensky0/tildaz/issues/168), v0.4.0) — `cursorScrollOffset` was recomputed every frame from `cursor_byte` (pure function), so on a long tab name, any new cursor position past `max - reserve` would force the cursor visual to the right edge. Now the scroll offset is *cached state* on `RenameState` (`scroll_offset: f32`), updated by `iterTabText` only when the cursor leaves the visible viewport (native textbox pattern). `renameTextHit` (mouse → byte) reads the same cached value so click position translation matches what's drawn. Both platforms automatically fixed via the shared helper.
- **IME pre-edit × line-nav unified across rename + terminal** (#164 follow-up 4-6, v0.4.0) — pressing Home / End / Ctrl+A / Ctrl+E during Korean / Japanese / Chinese composition commits the in-progress jamo (to rename buf or PTY depending on context) before moving the cursor, matching iTerm2 / native textbox behavior. `Ctrl+C` retains line-abort discard semantics. macOS uses direct keyCode interception in the rename branch (bypasses `interpretKeyEvents` / Cocoa StandardKeyBinding which doesn't reliably dispatch to custom NSViews); Windows routes Ctrl+A / Ctrl+E in `WM_KEYDOWN` to `KeyInput.home / .end` only when rename consumes them (otherwise WM_CHAR 0x01 / 0x05 falls through to readline). `commitPreeditPreserving` helper extracted so the same commit-without-ending-rename logic feeds nav, Cmd shortcuts, and mouse clicks. SPEC §5.1 has the full matrix and rationale.

## Tech stack

| Component | Windows | macOS |
|-----------|---------|-------|
| Language | Zig 0.15.2 | Zig 0.15.2 |
| Terminal emulation | [libghostty-vt](https://github.com/ghostty-org/ghostty) | [libghostty-vt](https://github.com/ghostty-org/ghostty) |
| PTY backend | ConPTY (`terminal/windows/pty.zig`) | POSIX (`terminal/macos/pty.zig`) — `openpty` + `login_tty` + IUTF8 |
| PTY host | Bundled `OpenConsole.exe` + `conpty.dll` ([microsoft/terminal](https://github.com/microsoft/terminal), MIT); falls back to system conhost | (kernel) |
| Window | Win32 API (borderless popup) | NSWindow (popUpMenu level 101) |
| Hotkey | `RegisterHotKey` | CGEventTap (Input Monitoring + Accessibility) |
| Renderer | Direct3D 11 + HLSL (ClearType subpixel) | Metal + CoreText |
| Font | DirectWrite — primary + explicit glyph fallback chain | CoreText — primary + explicit glyph fallback chain + system auto fallback |
| IME | Win32 IMM (`WM_IME_*` + `ImmGetCompositionStringW` for inline pre-edit; `ImmSetCompositionWindow(CFS_POINT)` for candidate-popup tracking) | NSTextInputClient (markedText pre-edit) |
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
- For elevated auto-start at logon under a strict EDR policy, see README §Known limitations (Task Scheduler `/RL HIGHEST` workaround)

Plan: applying to the [SignPath Foundation open-source code-signing program](https://about.signpath.io/foundation). Once approved, future releases will ship with an Authenticode-signed `tildaz.exe`.

### macOS — current state: ad-hoc signed build

The Zig build runs `codesign --sign - --force --timestamp=none` on `TildaZ.app`. This is enough for the app to launch from `/usr/bin/open`, but Apple Developer ID signing + notarization (which would let users skip the Gatekeeper warning) is blocked by corporate keychain policy in the current build environment ([#109](https://github.com/ensky0/tildaz/issues/109)). When unblocked, releases will ship as a signed + notarized `.app` (zip or dmg) and Input Monitoring / Accessibility grants will persist across rebuilds (instead of being invalidated by the per-build ad-hoc identity).
