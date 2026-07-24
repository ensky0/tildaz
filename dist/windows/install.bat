@echo off
setlocal
REM tildaz Windows install - copy the build output to a user location and create
REM a Start Menu shortcut. No admin rights needed (writes only to the user
REM profile). Same role as Linux install.sh / macOS build_and_install.sh:
REM "installed = shows up in the (Start) menu".
REM
REM Source auto-detect:
REM   - tildaz.exe next to this script  -> use it (extracted release zip)
REM   - otherwise                       -> repo zig-out\bin (dev; run zig build first)
REM Override: install.bat C:\path\to\bin
REM
REM Uninstall: uninstall.bat  (keeps config)  /  uninstall.bat --purge (removes all)

set "SRC=%~1"
if "%SRC%"=="" if exist "%~dp0tildaz.exe" set "SRC=%~dp0."
if "%SRC%"=="" set "SRC=%~dp0..\..\zig-out\bin"

set "DEST=%LOCALAPPDATA%\Programs\TildaZ"
set "SHORTCUT=%APPDATA%\Microsoft\Windows\Start Menu\Programs\TildaZ.lnk"

if not exist "%SRC%\tildaz.exe" (
    echo ERROR: "%SRC%\tildaz.exe" not found.
    echo Run "zig build" first, or run this from inside the extracted release zip.
    exit /b 1
)

echo --- Install to: %DEST% ---
if not exist "%DEST%" mkdir "%DEST%"
copy /Y "%SRC%\tildaz.exe" "%DEST%\tildaz.exe" >nul
REM Microsoft ConPTY runtime lives in _internal\ (conpty.dll + OpenConsole.exe).
if exist "%SRC%\_internal" (
    if not exist "%DEST%\_internal" mkdir "%DEST%\_internal"
    if exist "%SRC%\_internal\conpty.dll" copy /Y "%SRC%\_internal\conpty.dll" "%DEST%\_internal\conpty.dll" >nul
    if exist "%SRC%\_internal\OpenConsole.exe" copy /Y "%SRC%\_internal\OpenConsole.exe" "%DEST%\_internal\OpenConsole.exe" >nul
)
echo Copied: tildaz.exe (+ _internal\conpty.dll / _internal\OpenConsole.exe)

echo --- Create Start Menu shortcut ---
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut('%SHORTCUT%'); $s.TargetPath='%DEST%\tildaz.exe'; $s.WorkingDirectory='%DEST%'; $s.Save()"
echo Created: %SHORTCUT%

echo.
echo Done. Launch "TildaZ" from the Start Menu.
echo Auto-start is managed inside the app (config "auto_start"); the installer does not force it.
endlocal
