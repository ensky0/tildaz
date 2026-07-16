TildaZ - Windows package

================================================================
ABOUT
================================================================

TildaZ is a native Quake-style drop-down terminal for Linux,
macOS, and Windows. This package contains the Windows host built
with Zig, DirectWrite, Direct3D 11, and ConPTY.

Press F1 to show or hide the terminal. TildaZ supports cmd.exe,
PowerShell, and WSL shells through ConPTY.

Release notes and checksums:

    https://github.com/ensky0/tildaz/releases

================================================================
PACKAGE CONTENTS
================================================================

    tildaz.exe        TildaZ application
    conpty.dll        Bundled ConPTY runtime (Microsoft, MIT)
    OpenConsole.exe   Bundled PTY host (Microsoft, MIT)
    README.txt        This file

Keep tildaz.exe, conpty.dll, and OpenConsole.exe in the same
directory. TildaZ prefers the bundled runtime and falls back to
the system ConPTY implementation if the two Microsoft files are
missing.

================================================================
CONFIG AND LOG
================================================================

The first launch creates:

    Config: %APPDATA%\tildaz\config_0.json
    Log:    %APPDATA%\tildaz\tildaz_0.log

Launch TildaZ again while every configured instance is running to add
another one. Press its global hotkey and choose Create. Each numbered
config owns one process and a matching numbered log.

New shells start in the Windows home directory. WSL commands start
in the Linux home unless the configured command already supplies
an explicit --cd option.

Configuration reference:

    https://github.com/ensky0/tildaz/blob/main/CONFIG.md

Keyboard and mouse controls:

    https://github.com/ensky0/tildaz/blob/main/KEYBINDINGS.md

================================================================
LICENSES
================================================================

    TildaZ                         AGPL-3.0-or-later
    libghostty-vt                  MIT
    OpenConsole.exe / conpty.dll   MIT

The TildaZ license text is available in the repository:

    https://github.com/ensky0/tildaz/blob/main/LICENSE

The bundled Microsoft binaries come from
Microsoft.Windows.Console.ConPTY and are redistributed under MIT.

================================================================
PROJECT AND FEEDBACK
================================================================

    https://github.com/ensky0/tildaz
