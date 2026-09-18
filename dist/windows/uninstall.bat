@echo off
setlocal
REM tildaz Windows uninstall - reverse of install.bat plus cleanup of the
REM autostart entry the app may have written. Same policy as macOS/Linux:
REM   default   : remove installed files, Start Menu shortcut, autostart
REM               (registry) and state. Keep config + log (print paths).
REM   --purge   : also remove config + log.
REM
REM Usage: uninstall.bat [--purge]

set "PURGE=0"
if /I "%~1"=="--purge" set "PURGE=1"

REM Release and dev installs are both cleaned up (#654). At uninstall time we cannot
REM tell which one was installed, and "remove what I installed" is what the user means.
set "DEST=%LOCALAPPDATA%\Programs\TildaZ"
set "DEST_DEV=%LOCALAPPDATA%\Programs\TildaZ-dev"
set "SHORTCUT=%APPDATA%\Microsoft\Windows\Start Menu\Programs\TildaZ.lnk"
set "SHORTCUT_DEV=%APPDATA%\Microsoft\Windows\Start Menu\Programs\TildaZ (dev).lnk"
set "STATE=%LOCALAPPDATA%\tildaz"
set "STATE_DEV=%LOCALAPPDATA%\tildaz-dev"
set "CONFIG=%APPDATA%\tildaz"
set "CONFIG_DEV=%APPDATA%\tildaz-dev"

REM Stop running instances AND their child ConPTY helpers (OpenConsole.exe), which
REM otherwise keep conpty.dll / OpenConsole.exe locked. /T kills the whole tree.
taskkill /F /T /IM tildaz.exe >nul 2>&1 && echo Stopped: running tildaz.exe
REM Also kill any OpenConsole.exe launched from our install dir. Its parent tildaz
REM may have already exited (orphan), so /T above would miss it. Path-scoped, so
REM other apps' OpenConsole (e.g. Windows Terminal) are left alone.
powershell -NoProfile -Command "Get-Process OpenConsole -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '%DEST%\*' -or $_.Path -like '%DEST_DEV%\*' } | Stop-Process -Force" >nul 2>&1
REM brief pause so the OS releases the file handles before we delete the folder
ping -n 2 127.0.0.1 >nul 2>&1

REM --- autostart (registry Run value "TildaZ") ---
REM The value name is app_id.name now (lowercase, #654 (e)); "TildaZ" is the pre-#654 name.
for %%V in (tildaz tildaz-dev TildaZ) do (
    reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v %%V /f >nul 2>&1 && echo Removed: autostart [HKCU\...\Run\%%V]
)

REM --- Start Menu shortcut ---
if exist "%SHORTCUT%" ( del /F /Q "%SHORTCUT%" & echo Removed: %SHORTCUT% )
if exist "%SHORTCUT_DEV%" ( del /F /Q "%SHORTCUT_DEV%" & echo Removed: %SHORTCUT_DEV% )

REM --- installed files (report accurately; folder may be locked if TildaZ is still up) ---
set "HAD_DEST="
if exist "%DEST%" set "HAD_DEST=1"
if defined HAD_DEST rmdir /S /Q "%DEST%" 2>nul
if defined HAD_DEST if exist "%DEST%" echo WARNING: %DEST% still present [file in use] - close TildaZ, then re-run uninstall.bat
if defined HAD_DEST if not exist "%DEST%" echo Removed: %DEST%

set "HAD_DEST_DEV="
if exist "%DEST_DEV%" set "HAD_DEST_DEV=1"
if defined HAD_DEST_DEV rmdir /S /Q "%DEST_DEV%" 2>nul
if defined HAD_DEST_DEV if exist "%DEST_DEV%" echo WARNING: %DEST_DEV% still present [file in use] - close TildaZ (dev), then re-run uninstall.bat
if defined HAD_DEST_DEV if not exist "%DEST_DEV%" echo Removed: %DEST_DEV%

REM --- state (run/lock) ---
if exist "%STATE%" ( rmdir /S /Q "%STATE%" & echo Removed: %STATE% [state] )
if exist "%STATE_DEV%" ( rmdir /S /Q "%STATE_DEV%" & echo Removed: %STATE_DEV% [state] )

if "%PURGE%"=="0" (
    echo.
    echo Preserved [use --purge to remove]:
    echo   %CONFIG%\   [config + log]
    echo   %CONFIG_DEV%\   [config + log, dev build]
)
if "%PURGE%"=="1" if exist "%CONFIG%" ( rmdir /S /Q "%CONFIG%" & echo Removed: %CONFIG% [config + log] )
if "%PURGE%"=="1" if exist "%CONFIG_DEV%" ( rmdir /S /Q "%CONFIG_DEV%" & echo Removed: %CONFIG_DEV% [config + log] )

echo.
echo Note: if you manually created an admin Task Scheduler "TildaZ" task (see README),
echo       remove it separately with:  schtasks /delete /tn TildaZ /f
endlocal
