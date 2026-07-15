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

set "DEST=%LOCALAPPDATA%\Programs\TildaZ"
set "SHORTCUT=%APPDATA%\Microsoft\Windows\Start Menu\Programs\TildaZ.lnk"
set "STATE=%LOCALAPPDATA%\tildaz"
set "CONFIG=%APPDATA%\tildaz"

REM Stop running instances AND their child ConPTY helpers (OpenConsole.exe), which
REM otherwise keep conpty.dll / OpenConsole.exe locked. /T kills the whole tree.
taskkill /F /T /IM tildaz.exe >nul 2>&1 && echo Stopped: running tildaz.exe
REM Also kill any OpenConsole.exe launched from our install dir. Its parent tildaz
REM may have already exited (orphan), so /T above would miss it. Path-scoped, so
REM other apps' OpenConsole (e.g. Windows Terminal) are left alone.
powershell -NoProfile -Command "Get-Process OpenConsole -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '%DEST%\*' } | Stop-Process -Force" >nul 2>&1
REM brief pause so the OS releases the file handles before we delete the folder
ping -n 2 127.0.0.1 >nul 2>&1

REM --- autostart (registry Run value "TildaZ") ---
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v TildaZ /f >nul 2>&1 && echo Removed: autostart [HKCU\...\Run\TildaZ]

REM --- Start Menu shortcut ---
if exist "%SHORTCUT%" ( del /F /Q "%SHORTCUT%" & echo Removed: %SHORTCUT% )

REM --- installed files (report accurately; folder may be locked if TildaZ is still up) ---
set "HAD_DEST="
if exist "%DEST%" set "HAD_DEST=1"
if defined HAD_DEST rmdir /S /Q "%DEST%" 2>nul
if defined HAD_DEST if exist "%DEST%" echo WARNING: %DEST% still present [file in use] - close TildaZ, then re-run uninstall.bat
if defined HAD_DEST if not exist "%DEST%" echo Removed: %DEST%

REM --- state (run/lock) ---
if exist "%STATE%" ( rmdir /S /Q "%STATE%" & echo Removed: %STATE% [state] )

if "%PURGE%"=="0" (
    echo.
    echo Preserved [use --purge to remove]:
    echo   %CONFIG%\   [config + log]
)
if "%PURGE%"=="1" if exist "%CONFIG%" ( rmdir /S /Q "%CONFIG%" & echo Removed: %CONFIG% [config + log] )

echo.
echo Note: if you manually created an admin Task Scheduler "TildaZ" task (see README),
echo       remove it separately with:  schtasks /delete /tn TildaZ /f
endlocal
