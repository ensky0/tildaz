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

- **`config_N.toml` gains thirteen `[keys]` actions for split panes.** The schema is strict
  in both directions, so a file written by an older version stops the app with
  `missing required key "focus_pane_left"` (or another of the thirteen). Move the file
  aside (add `.bak` to its name), start TildaZ to get a fresh default file, then copy
  back the values you had changed. ([#483](https://github.com/ensky0/tildaz/issues/483))

## Body candidates

- Tabs can be split into panes. `Ctrl+Shift+Right` / `Ctrl+Shift+Down` (`Option+Cmd` on
  macOS) split the active pane, `Alt`/`Cmd`+arrows move the focus, `Shift+Alt`/`Shift+Cmd`
  +arrows move the split line, `Shift+Alt+0` spreads the panes evenly, `Ctrl+Shift+Z`
  (`Shift+Cmd+Z`) zooms one pane to the whole tab, and `Ctrl+Shift+X` (`Shift+Cmd+X`)
  closes one. Panes can also be dragged apart by the line between them.
  ([#483](https://github.com/ensky0/tildaz/issues/483),
  [#544](https://github.com/ensky0/tildaz/issues/544))
- A plain click no longer starts a text selection: the pointer has to move about 4 pt (or
  into another cell) first, so a shaky click cannot copy a single character over your
  clipboard. ([#483](https://github.com/ensky0/tildaz/issues/483))
- Alt combinations now reach the program on non-Latin keyboard layouts too — `Alt+n` sends
  `ESC n` on a Russian layout or a Korean input source instead of the layout's own letter.
  ([#483](https://github.com/ensky0/tildaz/issues/483))
- On Linux, the IME candidate window for Hanja, Kanji and Hanzi follows the terminal cursor
  again on the default GPU render path, instead of staying pinned to the corner of the pane.
  ([#535](https://github.com/ensky0/tildaz/issues/535))
