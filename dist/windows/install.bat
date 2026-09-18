@echo off
setlocal
REM tildaz Windows install - copy the build output to a user location and create
REM a Start Menu shortcut. No admin rights needed (writes only to the user
REM profile). Same role as Linux install.sh / macOS build_and_install.sh:
REM "installed = shows up in the (Start) menu".
REM
REM Source auto-detect (this also decides release vs dev naming - #654):
REM   - tildaz.exe next to this script  -> release (script sitting next to a release build)
REM   - otherwise                       -> repo zig-out\bin (dev; run zig build first)
REM Override: install.bat C:\path\to\bin
REM
REM NOTE (#654, verified 2026-09-18): unlike the Linux tar.gz, the Windows release zip does
REM NOT ship this script - it holds tildaz.exe, README.txt, LICENSE, THIRD-PARTY-NOTICES.md
REM and _internal\ only (dist\windows\package.ps1), and README.txt tells the user to run
REM tildaz.exe directly. That is the intended Windows install path (decided 2026-09-18), so
REM the release branch above is reached only when someone copies this script next to an
REM extracted build - not by unpacking the zip.
REM
REM Uninstall: uninstall.bat  (keeps config)  /  uninstall.bat --purge (removes all)

set "SRC=%~1"
set "IS_DEV="
if "%SRC%"=="" if exist "%~dp0tildaz.exe" (
    set "SRC=%~dp0."
    set "IS_DEV=0"
)
if "%SRC%"=="" (
    set "SRC=%~dp0..\..\zig-out\bin"
    set "IS_DEV=1"
)
REM Source given explicitly: treat a zig-out path as a dev build (#654).
if "%IS_DEV%"=="" (
    echo %SRC% | find /I "zig-out" >nul && (set "IS_DEV=1") || (set "IS_DEV=0")
)

REM A dev build installs beside the release one instead of overwriting it (#654).
REM Installing a dev build under the release name is what made a packaged 0.9.5
REM launch an old 0.9.3 dev binary on Linux; Windows had the same overwrite.
if "%IS_DEV%"=="1" (
    set "APP_NAME=TildaZ-dev"
    set "APP_LABEL=TildaZ (dev)"
) else (
    set "APP_NAME=TildaZ"
    set "APP_LABEL=TildaZ"
)

set "DEST=%LOCALAPPDATA%\Programs\%APP_NAME%"
set "SHORTCUT=%APPDATA%\Microsoft\Windows\Start Menu\Programs\%APP_LABEL%.lnk"

if not exist "%SRC%\tildaz.exe" (
    echo ERROR: "%SRC%\tildaz.exe" not found.
    echo Run "zig build" first, or run this from inside the extracted release zip.
    exit /b 1
)

REM #654 - a pre-dev install registered the DEV build under the RELEASE autostart name.
REM The app now writes "tildaz-dev", so the old value is left behind and BOTH fire at
REM logon, which is the "you cannot tell which build is running" symptom this issue
REM removes. Registry value names are case-insensitive, so the release name and the old
REM "TildaZ" are the same value - the test is the DATA, exactly like install.sh on Linux:
REM only an entry pointing at zig-out is our dev leftover. A real release install (its
REM path is the install dir) is preserved.
if not "%IS_DEV%"=="1" goto :no_stale_autostart
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v tildaz 2>nul | find /I "zig-out" >nul
if errorlevel 1 goto :no_stale_autostart
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v tildaz /f >nul 2>&1
echo Removed stale autostart from a pre-dev install [HKCU\...\Run\tildaz pointed at zig-out]
:no_stale_autostart

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
echo Done. Launch "%APP_LABEL%" from the Start Menu.
echo Auto-start is managed inside the app (config "auto_start"); the installer does not force it.
endlocal
