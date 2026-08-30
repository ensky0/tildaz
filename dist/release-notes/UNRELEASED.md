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

- Linux: windows and dialogs are no longer resampled at fractional display scales, so
  text and lines stay sharp at 1.7x and other fractional factors.
  ([#539](https://github.com/ensky0/tildaz/issues/539))
- Linux: mouse input lands where you point at fractional display scales; it was biased
  by up to two pixels toward the top-left.
  ([#552](https://github.com/ensky0/tildaz/issues/552))
