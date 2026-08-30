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

- Heavy output lands faster. Emoji, ZWJ sequences and CJK text parse roughly twice as
  fast, and ANSI-heavy output about 1.5x, measured on Linux, macOS and Windows.
  ([#550](https://github.com/ensky0/tildaz/issues/550))
- Fixed a crash that could corrupt memory while printing grapheme clusters when a
  program emits OSC 8 hyperlinks.
  ([#550](https://github.com/ensky0/tildaz/issues/550))
- Linux: windows and dialogs are no longer resampled at fractional display scales, so
  text and lines stay sharp at 1.7x and other fractional factors.
  ([#539](https://github.com/ensky0/tildaz/issues/539))
- Linux: mouse input lands where you point at fractional display scales; it was biased
  by up to two pixels toward the top-left.
  ([#552](https://github.com/ensky0/tildaz/issues/552))
- Windows: dialogs now follow the display scale while they are open. Changing the scale,
  or dragging the window to a monitor with a different one, used to leave the text and
  buttons at their original size - which could push the OK button outside the window, so
  the dialog could only be closed with the keyboard.
  ([#540](https://github.com/ensky0/tildaz/issues/540))
- Windows: the terminal no longer takes typing while a dialog is open. It was meant to be
  modal all along, as it already is on Linux and macOS.
  ([#567](https://github.com/ensky0/tildaz/issues/567))
- Powerline separators (U+E0B0-E0BF) are drawn by TildaZ itself, so prompts and status
  bars that use them - zellij, starship, powerlevel10k - render on every platform even
  without a Nerd Font installed. They used to show as replacement boxes.
  ([#534](https://github.com/ensky0/tildaz/issues/534))
