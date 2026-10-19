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

- Linux: GPU rendering now needs OpenGL ES 3.0. Older GPUs without it (for example Raspberry Pi 3 and earlier) use software rendering instead. ([#762](https://github.com/ensky0/tildaz/issues/762))
- If you bound the same key to two actions in `[keys]` yourself, neither action gets it now (one of them used to keep it). The startup dialog names both. ([#758](https://github.com/ensky0/tildaz/issues/758))
- New config files no longer bind `Ctrl+PgUp` / `Ctrl+PgDn` (`Cmd+PgUp` / `Cmd+PgDn` on macOS) to previous / next tab. Existing config files keep them. Use `Ctrl+Shift+[` / `]` instead. ([#760](https://github.com/ensky0/tildaz/issues/760))

## Body candidates

- Typed characters show up one frame sooner on Linux, and keys no longer sometimes lag a frame on macOS and Windows ([#763](https://github.com/ensky0/tildaz/issues/763)).
- Uses much less memory. ([#762](https://github.com/ensky0/tildaz/issues/762))
- On Windows, the Japanese IME candidate list now opens next to the cursor instead of in a corner of the screen ([#772](https://github.com/ensky0/tildaz/issues/772)).
- Emoji with a color request (like `❤️`) now always draw in color, and text requests draw as plain text — no longer depending on what was drawn before. ([#771](https://github.com/ensky0/tildaz/issues/771))
- TildaZ now starts even when the config file is not valid TOML or names a font that is not installed. It uses defaults and tells you what it changed, and a key you set now wins over a default it clashes with. ([#758](https://github.com/ensky0/tildaz/issues/758))
- Italic and bold now show on all three platforms even when the font has no italic or bold file — Korean italic, for example, used to stay upright on Linux and macOS. The slant and weight are the same everywhere. ([#759](https://github.com/ensky0/tildaz/issues/759))
- A hotkey you set by pressing it is now written the same way on every platform, in lowercase (`ctrl+shift+t`). The comments in a new config file are much shorter. ([#760](https://github.com/ensky0/tildaz/issues/760))
- On sway, a window started hidden (`hidden_start`) now shows the terminal on the first hotkey press instead of an empty window. ([#788](https://github.com/ensky0/tildaz/issues/788))
- On KDE Plasma, a global hotkey that combines Shift with a symbol or digit (like `ctrl+shift+]`) now works. ([#760](https://github.com/ensky0/tildaz/issues/760))
- On GNOME and Cinnamon, dialogs now always open in the middle of the TildaZ window. They sometimes opened partly off-screen. ([#782](https://github.com/ensky0/tildaz/issues/782))
- While a dialog is open, the hotkey no longer hides TildaZ and leaves the dialog alone on screen. It brings the dialog to the front instead. On GNOME and Cinnamon the hotkey used to do nothing. ([#801](https://github.com/ensky0/tildaz/issues/801))
