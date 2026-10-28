#!/bin/sh
# TildaZ uninstaller for Linux and macOS. Removes what install.sh installed.
#
#   curl -LsSf https://tildaz.dev/uninstall.sh | sh
#
# What it removes:
#   Linux: runs the uninstall.sh that came with the release (app menu entry, icon,
#          ~/.local/bin/tildaz, GNOME / Cinnamon Shell extension, auto-start, and
#          the desktop hotkey entries), then deletes $XDG_DATA_HOME/tildaz.
#   macOS: the auto-start LaunchAgent, TildaZ.app, and ~/Library/Caches/tildaz.
#
# Your config and logs are kept. The script prints where they are.
#
# Source: https://github.com/ensky0/tildaz/blob/main/docs/uninstall.sh
#
# The whole script is one function called on the last line, so a download cut
# off halfway runs nothing.

set -eu

say() { printf '%s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; exit 1; }

uninstall_linux() {
    if pgrep -x tildaz >/dev/null 2>&1; then
        err "TildaZ is running. Quit it and run this uninstaller again."
    fi
    case "${XDG_DATA_HOME:-}" in
        /*) data_home=$XDG_DATA_HOME ;;
        *) data_home=$HOME/.local/share ;;
    esac
    case "${XDG_CONFIG_HOME:-}" in
        /*) config_home=$XDG_CONFIG_HOME ;;
        *) config_home=$HOME/.config ;;
    esac
    case "${XDG_STATE_HOME:-}" in
        /*) state_home=$XDG_STATE_HOME ;;
        *) state_home=$HOME/.local/state ;;
    esac
    dest=$data_home/tildaz
    if [ ! -f "$dest/uninstall.sh" ]; then
        err "TildaZ was not installed by the install script ($dest not found). If you installed a deb, rpm, Arch package, or AppImage, remove it the same way."
    fi
    command -v bash >/dev/null 2>&1 || err "bash is required"

    # The release's uninstall.sh asks the tildaz binary to remove its desktop
    # settings, so it must run before the binary is deleted.
    log=$(mktemp 2>/dev/null || mktemp -t tildaz)
    if ! bash "$dest/uninstall.sh" > "$log" 2>&1; then
        cat "$log" >&2
        rm -f "$log"
        err "uninstall.sh failed"
    fi
    rm -f "$log"
    rm -rf "$dest"
    say "Removed TildaZ."
    say "Kept your config and logs. Delete them by hand if you do not need them:"
    say "  $config_home/tildaz/"
    say "  $state_home/tildaz/"
    # The removed entries (auto-start, Shell extension, desktop hotkeys) were shared
    # with a packaged copy installed alongside, if any. It writes them again at start.
    if [ -e /usr/bin/tildaz ]; then
        say "The packaged TildaZ (/usr/bin/tildaz) is still installed. Start it once to set up its auto-start and hotkey again."
    fi
}

# Homebrew keeps a record of each cask under <prefix>/Caskroom. brew may not be in
# PATH here, so the default prefixes are checked too.
brew_cask_installed() {
    for prefix in "$(brew --prefix 2>/dev/null)" /opt/homebrew /usr/local; do
        if [ -n "$prefix" ] && [ -d "$prefix/Caskroom/tildaz" ]; then return 0; fi
    done
    return 1
}

uninstall_macos() {
    # Leave a Homebrew install to brew, so its record goes away with the app.
    if brew_cask_installed; then
        err "TildaZ was installed by Homebrew. Remove it with: brew uninstall --cask tildaz"
    fi
    if pgrep -f '/TildaZ.app/Contents/MacOS/' >/dev/null 2>&1; then
        err "TildaZ is running. Quit it (Cmd+Q) and run this uninstaller again."
    fi
    removed=0
    # Remove auto-start first, or launchd starts a deleted app at the next login.
    # com.tildaz.app is the label of releases before 0.10.
    for label in me.ensky0.tildaz com.tildaz.app; do
        launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
        agent=$HOME/Library/LaunchAgents/$label.plist
        if [ -f "$agent" ]; then
            rm -f "$agent"
            removed=1
        fi
    done
    for path in /Applications/TildaZ.app "$HOME/Applications/TildaZ.app" "$HOME/Library/Caches/tildaz"; do
        if [ -e "$path" ]; then
            rm -rf "$path"
            removed=1
        fi
    done
    if [ "$removed" -eq 0 ]; then
        say "TildaZ is not installed."
        return
    fi
    case "${XDG_CONFIG_HOME:-}" in
        /*) config_home=$XDG_CONFIG_HOME ;;
        *) config_home=$HOME/.config ;;
    esac
    say "Removed TildaZ."
    say "Kept your config and logs. Delete them by hand if you do not need them:"
    say "  $config_home/tildaz/"
    say "  $HOME/Library/Logs/tildaz/"
    say "TildaZ may still be listed in System Settings > Privacy & Security."
    say "Remove it there if you want."
}

main() {
    case "$(uname -s)" in
        Linux) uninstall_linux ;;
        Darwin) uninstall_macos ;;
        *) err "unsupported OS: $(uname -s). On Windows, run in PowerShell: irm https://tildaz.dev/uninstall.ps1 | iex" ;;
    esac
}

main "$@"
