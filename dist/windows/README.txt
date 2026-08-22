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

    tildaz.exe            TildaZ application - run this
    README.txt            This file
    LICENSE               TildaZ license (AGPL-3.0-or-later)
    THIRD-PARTY-NOTICES.md  Bundled component notices
    _internal\            Bundled Microsoft runtime (do not run)
        conpty.dll        Bundled ConPTY runtime (Microsoft, MIT)
        OpenConsole.exe   Bundled PTY host (Microsoft, MIT)

Run tildaz.exe. The _internal folder holds Microsoft's ConPTY
runtime (conpty.dll + OpenConsole.exe) - you never launch anything
inside it. Keep the _internal folder next to tildaz.exe: it is
required. If it is missing, TildaZ shows an error at startup and
exits, so re-extract or reinstall keeping _internal beside tildaz.exe.

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
    uucode                         MIT
    Highway                        Apache-2.0
    OpenConsole.exe / conpty.dll   MIT

The TildaZ license text is in LICENSE, next to this file.

tildaz.exe is statically linked and contains compiled code from
libghostty-vt, uucode, and Highway. Their copyright notices and
full license texts are in THIRD-PARTY-NOTICES.md, next to this
file, along with attribution for the built-in color themes.

The bundled Microsoft binaries come from
Microsoft.Windows.Console.ConPTY and are redistributed under MIT.

================================================================
PROJECT AND FEEDBACK
================================================================

    https://github.com/ensky0/tildaz
