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

- `[keys]` gained one action (`open_search`). The section is strict in both directions,
  so an existing `config_N.toml` fails to start with `missing required key "open_search"`.
  Add the line below, or delete the config and let TildaZ regenerate it.

  ```toml
  open_search = "cmd+f"        # macOS
  open_search = "ctrl+shift+f" # Linux, Windows
  ```

## Body candidates

- Click a link in the terminal to open it in your browser — both OSC 8 hyperlinks and plain URLs found on screen. Hold `Ctrl` (`⌘` on macOS) while an app is using the mouse ([#643](https://github.com/ensky0/tildaz/issues/643)).
- Search the scrollback of the focused pane. `Cmd+F` / `Ctrl+Shift+F` opens a panel in the
  top-right corner; matches are highlighted in place and `Enter` / `Shift+Enter` step
  through them ([#642](https://github.com/ensky0/tildaz/issues/642)).
