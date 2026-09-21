@echo off
setlocal
REM tildaz Windows install - copy the build output to a user location and create
REM a Start Menu shortcut. No admin rights needed (writes only to the user
REM profile). Same role as Linux install.sh / macOS build_and_install.sh:
REM "installed = shows up in the (Start) menu".
REM
REM Dev is the default on all platforms. Only --release selects release.
REM Always build first, so a previous release build cannot be installed as dev.
REM This script is not shipped in the release zip; users run tildaz.exe there.
REM Usage: install.bat [--release]
REM Uninstall: uninstall.bat / uninstall.bat --purge

set "IS_DEV=1"
set "BUILD_ARGS="
:parse_args
if "%~1"=="" goto :args_done
if "%~1"=="--release" goto :release_arg
if "%~1"=="--help" goto :help
if "%~1"=="-h" goto :help
echo ERROR: Unknown argument: "%~1" >&2
exit /b 2
:release_arg
set "IS_DEV=0"
set "BUILD_ARGS=--release"
shift /1
goto :parse_args
:help
echo Usage: install.bat [--release]
echo Build and install dev by default; --release selects the release identity.
exit /b 0
:args_done
set "SRC=%~dp0..\..\zig-out\bin"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %BUILD_ARGS%
if errorlevel 1 exit /b %errorlevel%

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
    echo ERROR: the build did not produce tildaz.exe.
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
if errorlevel 1 exit /b %errorlevel%
REM Microsoft ConPTY runtime lives in _internal\ (conpty.dll + OpenConsole.exe).
if exist "%SRC%\_internal" (
    if not exist "%DEST%\_internal" mkdir "%DEST%\_internal"
    if exist "%SRC%\_internal\conpty.dll" copy /Y "%SRC%\_internal\conpty.dll" "%DEST%\_internal\conpty.dll" >nul
    if exist "%SRC%\_internal\OpenConsole.exe" copy /Y "%SRC%\_internal\OpenConsole.exe" "%DEST%\_internal\OpenConsole.exe" >nul
)
echo Copied: tildaz.exe (+ _internal\conpty.dll / _internal\OpenConsole.exe)

echo --- Create Start Menu shortcut ---
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut('%SHORTCUT%'); $s.TargetPath='%DEST%\tildaz.exe'; $s.WorkingDirectory='%DEST%'; $s.Save()"
if errorlevel 1 exit /b %errorlevel%
echo Created: %SHORTCUT%

echo.
echo Done. Launch "%APP_LABEL%" from the Start Menu.
echo Auto-start is managed inside the app (config "auto_start"); the installer does not force it.
endlocal
