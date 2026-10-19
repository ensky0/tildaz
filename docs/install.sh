#!/bin/sh
# TildaZ installer for Linux and macOS.
#
#   curl -LsSf https://ensky0.github.io/tildaz/install.sh | sh
#
# What it does:
#   1. Finds the latest release (or TILDAZ_VERSION) on GitHub.
#   2. Downloads the release file and its .sha256, and stops if they differ.
#   3. Linux: unpacks the release tarball into $XDG_DATA_HOME/tildaz and runs its
#      install.sh, which adds the app menu entry, the icon, ~/.local/bin/tildaz
#      and the GNOME / Cinnamon Shell extension.
#      macOS: copies TildaZ.app into /Applications (or ~/Applications).
#   4. Starts TildaZ once. TildaZ sets up auto-start itself on its first run.
#
# Everything goes into your user account. No sudo is needed.
#
# Environment:
#   TILDAZ_VERSION=0.10.4   install this release instead of the latest
#   TILDAZ_NO_LAUNCH=1      do not start TildaZ after installing
#
# Source: https://github.com/ensky0/tildaz/blob/main/docs/install.sh
#
# The whole script is one function called on the last line, so a download cut
# off halfway runs nothing.

set -eu

REPO="ensky0/tildaz"

say() { printf '%s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; exit 1; }

download() { # <url> <file>
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        err "curl or wget is required"
    fi
}

# Reads the tag from the address GitHub redirects /releases/latest to. This avoids
# the GitHub API and its rate limit.
latest_tag() {
    url="https://github.com/$REPO/releases/latest"
    if command -v curl >/dev/null 2>&1; then
        final=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$url")
    elif command -v wget >/dev/null 2>&1; then
        final=$(wget -q -S --spider "$url" 2>&1 | sed -n 's/^ *[Ll]ocation: *//p' | tail -n 1 | tr -d '\r')
    else
        err "curl or wget is required"
    fi
    printf '%s\n' "${final##*/}"
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d ' ' -f 1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d ' ' -f 1
    else
        err "sha256sum or shasum is required to check the download"
    fi
}

# Downloads a release file and its .sha256 into $TMP, and checks one against the other.
fetch_verified() { # <file name>
    base="https://github.com/$REPO/releases/download/$TAG"
    say "Downloading $1"
    download "$base/$1" "$TMP/$1" || err "download failed: $base/$1"
    download "$base/$1.sha256" "$TMP/$1.sha256" || err "download failed: $base/$1.sha256"
    want=$(cut -d ' ' -f 1 < "$TMP/$1.sha256")
    got=$(sha256_of "$TMP/$1")
    [ -n "$want" ] && [ "$want" = "$got" ] || err "SHA-256 mismatch for $1 (expected $want, got $got). Nothing was installed."
    say "Checked SHA-256"
}

# Replaces <dest> with <new> so a failed copy never leaves a half-installed app.
swap_dir() { # <new> <dest>
    rm -rf "$2.old"
    if [ -e "$2" ]; then mv "$2" "$2.old"; fi
    mv "$1" "$2"
    rm -rf "$2.old"
}

install_linux() {
    case "$(uname -m)" in
        x86_64 | amd64) arch=x86_64 ;;
        aarch64 | arm64) arch=aarch64 ;;
        *) err "unsupported CPU: $(uname -m) (TildaZ ships x86_64 and aarch64)" ;;
    esac
    command -v bash >/dev/null 2>&1 || err "bash is required"
    command -v tar >/dev/null 2>&1 || err "tar is required"

    case "${XDG_DATA_HOME:-}" in
        /*) data_home=$XDG_DATA_HOME ;;
        *) data_home=$HOME/.local/share ;;
    esac
    case "${XDG_CONFIG_HOME:-}" in
        /*) config_home=$XDG_CONFIG_HOME ;;
        *) config_home=$HOME/.config ;;
    esac
    dest=$data_home/tildaz

    # Do not install a second copy next to a package or an AppImage. Both copies
    # would share the menu entry name, the auto-start entry and the Shell extension,
    # and whichever ran last would own them.
    if [ -e /usr/bin/tildaz ]; then
        err "TildaZ is already installed by your package manager (/usr/bin/tildaz). Update it with your package manager, or remove that package and run this installer again."
    fi
    # An AppImage records its own path in the entries it writes on its first run.
    appimage=$(sed -n 's/^Exec="\([^"]*\.AppImage\)".*/\1/p' \
        "$config_home/autostart/tildaz.desktop" \
        "$data_home/applications/tildaz.desktop" \
        "$data_home"/applications/tildaz.instance*.desktop 2>/dev/null | head -n 1)
    if [ -n "$appimage" ]; then
        err "TildaZ is already installed as an AppImage ($appimage). Keep using it, or run \"$appimage\" --desktop remove, delete the AppImage, and run this installer again."
    fi

    name="tildaz-$TAG-linux-$arch"
    fetch_verified "$name.tar.gz"
    tar -xzf "$TMP/$name.tar.gz" -C "$TMP"
    [ -x "$TMP/$name/tildaz" ] || err "the release tarball has no tildaz binary"
    mkdir -p "$data_home"
    # Copy next to the destination first. $TMP may be on another file system.
    rm -rf "$dest.new"
    cp -R "$TMP/$name" "$dest.new"
    swap_dir "$dest.new" "$dest"

    # install.sh adds the menu entry, icon, ~/.local/bin link and Shell extensions.
    if ! bash "$dest/install.sh" --release > "$TMP/install.log" 2>&1; then
        cat "$TMP/install.log" >&2
        err "install.sh failed"
    fi
    say "Installed TildaZ $TAG to $dest"

    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) say "Note: $HOME/.local/bin is not in PATH. The app menu entry works without it." ;;
    esac

    if pgrep -x tildaz >/dev/null 2>&1; then
        say "A TildaZ process is already running. Quit it and start TildaZ again to use $TAG."
        return
    fi
    case ":${XDG_CURRENT_DESKTOP:-}:" in
        *:GNOME:*)
            say "GNOME loads the TildaZ Shell extension at login."
            say "Log out and back in. TildaZ then starts by itself."
            return
            ;;
    esac
    if [ -n "${TILDAZ_NO_LAUNCH:-}" ] || [ -z "${WAYLAND_DISPLAY:-}" ]; then
        say "Start TildaZ from your app menu."
        return
    fi
    if command -v setsid >/dev/null 2>&1; then
        setsid "$dest/tildaz" > /dev/null 2>&1 < /dev/null &
    else
        nohup "$dest/tildaz" > /dev/null 2>&1 < /dev/null &
    fi
    say "Started TildaZ. Press its hotkey (F1 by default) to show or hide it."
}

install_macos() {
    command -v hdiutil >/dev/null 2>&1 || err "hdiutil is required"
    if pgrep -f '/TildaZ.app/Contents/MacOS/' >/dev/null 2>&1; then
        err "TildaZ is running. Quit it (Cmd+Q) and run this installer again."
    fi

    name="tildaz-$TAG-macos.dmg"
    fetch_verified "$name"
    mnt=$TMP/mnt
    mkdir -p "$mnt"
    hdiutil attach -nobrowse -readonly -noautoopen -quiet -mountpoint "$mnt" "$TMP/$name" ||
        err "could not open $name"
    MOUNTED=$mnt
    [ -d "$mnt/TildaZ.app" ] || err "the disk image has no TildaZ.app"

    if [ -w /Applications ]; then
        apps=/Applications
    else
        apps=$HOME/Applications
        mkdir -p "$apps"
    fi
    dest=$apps/TildaZ.app
    rm -rf "$dest.new"
    ditto "$mnt/TildaZ.app" "$dest.new"
    swap_dir "$dest.new" "$dest"
    hdiutil detach -quiet "$mnt" || true
    MOUNTED=
    say "Installed TildaZ $TAG to $dest"

    if [ -n "${TILDAZ_NO_LAUNCH:-}" ]; then
        say "Start TildaZ from Launchpad or Spotlight."
        return
    fi
    open "$dest"
    # TildaZ names the permissions itself, in the words of this macOS version
    # (Accessibility became "Device Control and Data Access" in macOS 27).
    say "Started TildaZ. If a permission is missing, TildaZ shows which one to turn on."
    say "Turn it on so the hotkey (F1 by default) works."
}

cleanup() {
    if [ -n "${MOUNTED:-}" ]; then hdiutil detach -quiet "$MOUNTED" || true; fi
    rm -rf "$TMP"
}

main() {
    case "${TILDAZ_VERSION:-}" in
        "") TAG=$(latest_tag) ;;
        v*) TAG=$TILDAZ_VERSION ;;
        *) TAG=v$TILDAZ_VERSION ;;
    esac
    case "$TAG" in
        v[0-9]*) ;;
        *) err "could not find the latest TildaZ release (got \"$TAG\")" ;;
    esac

    TMP=$(mktemp -d 2>/dev/null || mktemp -d -t tildaz)
    MOUNTED=
    trap cleanup EXIT
    trap 'exit 1' INT TERM

    case "$(uname -s)" in
        Linux) install_linux ;;
        Darwin) install_macos ;;
        *) err "unsupported OS: $(uname -s). On Windows, run in PowerShell: irm https://ensky0.github.io/tildaz/install.ps1 | iex" ;;
    esac
}

main "$@"
