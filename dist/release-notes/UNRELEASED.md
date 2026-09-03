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

- Windows now shows the pending dead key (for example `´`) highlighted at the cursor until the next key, as macOS and Linux already did ([#530](https://github.com/ensky0/tildaz/issues/530)).
- Windows: programs that enable the kitty keyboard protocol with "report all keys" now receive letters, Enter, Tab, Backspace and Escape as `CSI u` sequences, matching macOS and Linux ([#602](https://github.com/ensky0/tildaz/issues/602)).
- Linux: unplugging the only keyboard or mouse and plugging it back in no longer leaves TildaZ without input on wlroots-based compositors (sway, Hyprland) — the seat's keyboard and pointer objects are released and recreated with the device ([#347](https://github.com/ensky0/tildaz/issues/347)).
- Linux: when the compositor exits first (logout, `swaymsg exit`), TildaZ shuts down cleanly instead of reporting `TildaZ failed to start … WaylandConnectionClosed` ([#613](https://github.com/ensky0/tildaz/issues/613)).
