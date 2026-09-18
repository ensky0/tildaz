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

- **macOS log files moved into their own folder.** They are now
  `~/Library/Logs/tildaz/tildaz_N.log` instead of `~/Library/Logs/tildaz_N.log`, which is
  what the other platforms already did. About and "Open Log" follow automatically; old
  files stay where they are and can be deleted.
  ([#654](https://github.com/ensky0/tildaz/issues/654))

(none yet)

## Body candidates

(none yet)
