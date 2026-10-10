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

- macOS: `⌘Q` now follows the `quit` entry in `[keys]`. If you changed or emptied it, `⌘Q` no longer quits ([#713](https://github.com/ensky0/tildaz/issues/713)).
- Selecting text with the mouse no longer replaces the clipboard. Copy with `Ctrl+Shift+C` (`Cmd+C` on macOS) or a right-click, or set `copy_on_select = true` in `[input]` to get the old behavior back ([#656](https://github.com/ensky0/tildaz/issues/656)).

- macOS: text is drawn with thinner strokes by default, as in iTerm2 and Ghostty. For the old, heavier look, set `macos_smoothing = true` under `[font]` ([#527](https://github.com/ensky0/tildaz/issues/527)).

## Body candidates

- macOS: changing the quit shortcut in `[keys]` now works ([#713](https://github.com/ensky0/tildaz/issues/713)).
- The arrow keys in the `⋯` menu now move in the order you see ([#712](https://github.com/ensky0/tildaz/issues/712)).
- Windows: a new tab scrolls into view in the tab bar, and the pointer shape updates right after a split ([#692](https://github.com/ensky0/tildaz/issues/692)).
- Linux: a mouse selection goes to the primary selection, and middle-click pastes it ([#657](https://github.com/ensky0/tildaz/issues/657)).
- Right-click copies the selection when there is one, and pastes when there is none ([#656](https://github.com/ensky0/tildaz/issues/656)).
- Programs can copy to the clipboard with OSC 52, so copying in tmux, even over SSH, lands in your clipboard ([#266](https://github.com/ensky0/tildaz/issues/266)).
- Fixed a crash when a narrower window or pane cut a wide character such as Korean in a full-screen app ([#723](https://github.com/ensky0/tildaz/issues/723)).
- macOS: thinner, sharper text by default, with `[font] macos_smoothing` to switch back ([#527](https://github.com/ensky0/tildaz/issues/527)).
