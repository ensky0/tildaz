# SignPath Foundation Open Source Code Signing — Application Draft

This is a draft to paste into the SignPath Foundation OSS signing application form
at https://about.signpath.io/foundation. Fields below follow the typical form
structure; rename/reorder as needed to match the live form.

---

## Project name

TildaZ

## Project URL

- GitHub repository: https://github.com/ensky0/tildaz
- Project website: https://ensky0.github.io/tildaz/
- Latest release: https://github.com/ensky0/tildaz/releases/latest

## Project description (short)

TildaZ is a Quake-style drop-down terminal emulator for Windows, written in Zig
and built on the libghostty-vt terminal engine. It brings the UX of the Linux
[Tilda](https://github.com/lanoxx/tilda) terminal to Windows while staying
native to the Windows stack: OpenConsole / ConPTY pseudoconsole host, DirectWrite
glyph rasterization, and a Direct3D 11 renderer with HLSL shaders for ClearType
subpixel text.

A single global hotkey (F1) drops the terminal in from the top of the current
monitor; pressing F1 again hides it. The app supports tabs, drag-to-reorder,
ANSI/TrueColor, 18 built-in themes, multi-monitor DPI-aware layout, and
Unicode/CJK/emoji rendering.

## Project description (long / why this exists)

Windows lacks a well-maintained native drop-down terminal comparable to Tilda,
Guake, or Yakuake on Linux. Windows Terminal and WezTerm are excellent but are
not drop-down-first. TildaZ fills that gap.

Design decisions of note for a security-review audience:
- **Bundled OpenConsole / ConPTY**: TildaZ ships Microsoft's
  `Microsoft.Windows.Console.ConPTY` NuGet package (`OpenConsole.exe` +
  `conpty.dll`) to stabilize behavior across Windows versions. It falls back to
  the system `kernel32` ConPTY if the bundle is missing.
- **Pseudoconsole spawning**: TildaZ creates child processes via ConPTY for the
  user's chosen shell (cmd.exe, PowerShell, wsl.exe, etc.). This is the same
  pattern used by Windows Terminal, WezTerm, Alacritty on Windows.
- **Lock-free I/O**: PTY output is piped into a single-producer / single-consumer
  ring buffer (4 MiB), drained on the UI thread through the ghostty VT parser.
- **Direct3D 11 rendering**: DirectWrite rasterizes glyphs into a dynamic atlas;
  D3D11 draws instanced quads with a custom HLSL dual-source ClearType pipeline.

## License

**AGPL-3.0-or-later** (OSI-approved: https://opensource.org/license/agpl-v3)

The `LICENSE` file at the repository root contains the unmodified GNU Affero
General Public License v3 text, prepended by a one-line project copyright
notice.

## Maintainer

- GitHub: https://github.com/ensky0 (@ensky0)
- Single maintainer, hobby project.

Identity verification can be established via the maintainer's GitHub account
and its commit history. The maintainer's email is kept private; contact is via
GitHub issues or Private Vulnerability Reporting.

## Why code signing is needed

Multiple end-users have reported Endpoint Detection & Response (EDR) products —
specifically SentinelOne — flagging unsigned `tildaz.exe` builds as malicious
and auto-quarantining the binary shortly after launch. The behavioral
combination that triggers heuristics is common to every terminal emulator:

- Unsigned PE
- ConPTY / pseudoconsole creation
- Multiple worker threads for read / write / render
- Spawning child shells (cmd, wsl, powershell)

Each new release ships a new binary hash, which forces the end user's security
admin to re-approve the file through their EDR console every version. This is
untenable for ongoing maintenance.

Authenticode code signing, combined with publisher-based trust rules in the
EDR, would let a single cert-level approval cover all future releases.

## Release artifacts to be signed

- `tildaz.exe` (single Windows PE, AMD64, statically linked)
- Bundled `OpenConsole.exe` and `conpty.dll` ship alongside but are already
  signed by Microsoft — TildaZ does not need to re-sign them.

## Build pipeline

Builds are produced entirely on GitHub-hosted runners via GitHub Actions. The
release workflow is committed at `.github/workflows/release.yml` on the default
branch, runs on `windows-2022`, and:

1. Validates the tag matches `build.zig`'s `tildaz_version` constant.
2. Validates `build.zig.zon` dependencies are pinned to 40-hex-digit commit
   SHAs (no rolling branch/tag URLs).
3. Fetches dependencies (`zig build --fetch`).
4. Builds and packages (`zig build package`) into
   `zig-out/release/tildaz-v<ver>-win-x64.zip` + `.sha256`.
5. Creates the GitHub Release with the zip, SHA256 sidecar, and the release
   notes file `dist/release-notes/v<ver>.md` as the body.

The trigger is a `v*` tag push on `main`. There is no local/manual release
path for the authoritative binary — all shipped artifacts come from CI.

## Expected signing integration

If approved, I plan to add a signing step to `release.yml` using
`signpath-io/github-action-submit-signing-request`, positioned between the
`zig build package` step and the upload step. The signed artifact from SignPath
would replace the unsigned `tildaz.exe` inside the release zip before the zip
is finalized and its SHA256 is computed.

## Release cadence and project activity

- **Public commit history**: active since March 2026 on a public repository.
- **Recent releases** (as of writing): v0.2.5 through v0.3.0 shipped from
  April through May 2026. See https://github.com/ensky0/tildaz/releases for
  the full list.
- **Expected cadence**: roughly weekly minor releases (0.2.x) with occasional
  hotfixes. No enterprise SLAs.

## Security policy

`SECURITY.md` is committed at the repository root. Vulnerability reports go
through GitHub Private Vulnerability Reporting
(https://github.com/ensky0/tildaz/security/advisories/new) — no personal email
is used as the disclosure channel.

## Dependencies and their licenses

- **libghostty-vt** — MIT, pinned by commit SHA in `build.zig.zon`. Source:
  https://github.com/ghostty-org/ghostty
- **OpenConsole.exe** / **conpty.dll** — MIT, Microsoft.Windows.Console.ConPTY
  NuGet 1.24.260303001. Source: https://github.com/microsoft/terminal
- **Zig** — MIT (compiler / build system).

No other runtime dependencies.

## Anything else

- The project targets a single platform (Windows x64) — signing scope is narrow.
- No network services, no telemetry, no auto-updater. TildaZ runs fully offline
  after install.
- Source is ~5k LOC of Zig + HLSL shaders embedded as string literals; the
  bundled DLL/EXE come from an official Microsoft NuGet package.
