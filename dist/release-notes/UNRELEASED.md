# Unreleased

**This file is not a release note. It is a carrier.**

What goes into a release note is known when the change is made, but it is only
published much later. Nothing used to carry it across that gap, so it lived in
someone's memory. Add the line here in the PR that causes it; the release checklist
(`AGENTS.md`, step 2) folds this file into `vX.Y.Z.md` and empties it.

Two sections, because they land in different places and have different bars.

- **Upgrade notes** — something a person must know or *do* when upgrading. Goes to the
  `Upgrade notes` section, which is exempt from the 5-line body limit.
- **Body candidates** — user-visible improvements worth the note's body. The body is
  capped at 5 lines, so this is a shortlist to choose from, not a list to paste.
  Cut anything only a maintainer would notice.

Internal changes belong in neither.

## Upgrade notes

## Body candidates

- Install with one command: `curl -LsSf https://ensky0.github.io/tildaz/install.sh | sh` on Linux and macOS, `powershell -ExecutionPolicy ByPass -c "irm https://ensky0.github.io/tildaz/install.ps1 | iex"` on Windows. Run it again to update; `uninstall.sh` / `uninstall.ps1` remove it. ([#803](https://github.com/ensky0/tildaz/issues/803))
- Linux: heavy output no longer pauses between frames, so large outputs finish faster. ([#814](https://github.com/ensky0/tildaz/issues/814))
- CJK and emoji-heavy output is processed up to twice as fast on all platforms. ([#812](https://github.com/ensky0/tildaz/issues/812))
- macOS: typing is responsive again; the extra key-to-screen delay added in v0.10.5 is gone. ([#811](https://github.com/ensky0/tildaz/issues/811))
