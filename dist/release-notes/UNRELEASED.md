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

- **`config_N.toml` gains an `[input]` section.** The schema is strict in both
  directions, so a config written by an older version stops the app with
  `missing required key "macos_option_as_alt"`. Add the section by hand, or move the
  file aside and let TildaZ write a fresh one:

  ```toml
  [input]
  macos_option_as_alt = "none"   # none | both | left | right
  ```

  The key is present on all three platforms so one config file stays portable, but it
  only does something on macOS. ([#533](https://github.com/ensky0/tildaz/issues/533))

## Body candidates

- Alt combinations now reach the program running inside TildaZ, so `Alt+n` in zellij,
  tmux and emacs works. Arrow and function keys carry their modifiers too
  (`Shift+Left`, `Alt+Left`). ([#533](https://github.com/ensky0/tildaz/issues/533))
- On macOS, `[input] macos_option_as_alt` chooses whether Option types characters
  (`option+a` → `å`, the default) or acts as Alt.
  ([#533](https://github.com/ensky0/tildaz/issues/533))
