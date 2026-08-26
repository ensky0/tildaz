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

- Instance numbers now stop at **9** (ten instances, `F1`–`F10`). A `config_N.toml` or
  `tildaz.instanceN.desktop` numbered 10 or above is no longer recognised: that
  instance disappears from the list, and its desktop entry is not cleaned up. Renumber
  it below 10 if you still want it. ([#510](https://github.com/ensky0/tildaz/issues/510))
- A newly created config picks its hotkey from its instance number — `F1` for instance
  0, `F2` for 1, and so on. Existing configs are untouched.
  ([#510](https://github.com/ensky0/tildaz/issues/510))
- TildaZ now **stops with a dialog** when it cannot claim its global hotkey, on all
  three platforms. It used to do that only on Windows; macOS and Linux carried on with
  a hotkey that never fired. On macOS this includes the first run before Input
  Monitoring and Accessibility are granted.
  ([#510](https://github.com/ensky0/tildaz/issues/510))

## Body candidates

- Error dialogs name the config file again. They used to print `(unknown)` where the
  path belongs, on every platform, which left nothing to act on.
  ([#519](https://github.com/ensky0/tildaz/issues/519))
