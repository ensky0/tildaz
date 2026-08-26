# Unreleased — upgrade notes

**This file is not a release note. It is a carrier.**

An upgrade note has to be written when the change is made, but it is only published
much later, at release time. Nothing used to carry it across that gap, so it lived in
someone's memory. Add the line here in the PR that causes it; the release checklist
(`AGENTS.md`, step 2) folds this file into `vX.Y.Z.md` and empties it.

Only user-visible consequences belong here — things a person must know or do when
upgrading. Internal changes do not.

## Pending

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
