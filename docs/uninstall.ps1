# TildaZ uninstaller for Windows. Removes what install.ps1 installed.
#
#   powershell -ExecutionPolicy ByPass -c "irm https://ensky0.github.io/tildaz/uninstall.ps1 | iex"
#
# What it removes:
#   - the auto-start entry (HKCU\...\Run\tildaz), if it points at the installed app
#   - the Start Menu shortcut
#   - %LOCALAPPDATA%\Programs\TildaZ
#   - %LOCALAPPDATA%\tildaz (run-time state)
#
# Your config and logs in %APPDATA%\tildaz are kept. An unzipped release in
# another folder is left alone.
#
# Source: https://github.com/ensky0/tildaz/blob/main/docs/uninstall.ps1
#
# Keep this file ASCII (see install.ps1). The whole script is one function
# called on the last lines, so a download cut off halfway runs nothing.

function Uninstall-TildaZ {
    $ErrorActionPreference = 'Stop'

    # Same paths as install.ps1 and dist\windows\install.bat --release.
    $dest = Join-Path $env:LOCALAPPDATA 'Programs\TildaZ'
    $shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'TildaZ.lnk'
    $state = Join-Path $env:LOCALAPPDATA 'tildaz'
    $config = Join-Path $env:APPDATA 'tildaz'
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

    # Nothing to do for a user who only ever unzipped a release. The state folder
    # below is shared with that copy, so leave it alone too.
    if (-not (Test-Path -LiteralPath $dest)) {
        if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force }
        Write-Host 'TildaZ is not installed.'
        return
    }

    # Do not stop a running TildaZ here: it may hold open shells. A release started
    # from another folder counts too, because it uses the state folder removed below.
    # See install.ps1 for the window class.
    if (-not ('TildaZInstall.Win32' -as [type])) {
        Add-Type -Namespace TildaZInstall -Name Win32 -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr FindWindowW(string lpClassName, string lpWindowName);
'@
    }
    $window = [TildaZInstall.Win32]::FindWindowW('TildaZWindow', [NullString]::Value)
    $running = @(Get-Process -Name tildaz, OpenConsole -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith("$dest\", [StringComparison]::OrdinalIgnoreCase) })
    if ($window -ne [IntPtr]::Zero -or $running.Count -gt 0) {
        throw 'TildaZ is running. Quit it and run this uninstaller again.'
    }

    # The app writes this value on its first run. Value names are case-insensitive,
    # so this also covers "TildaZ" from releases before 0.10. Leave it alone if it
    # points at a TildaZ copy somewhere else.
    $run = (Get-ItemProperty -Path $runKey -Name tildaz -ErrorAction SilentlyContinue).tildaz
    if ($run -and $run.IndexOf($dest, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        Remove-ItemProperty -Path $runKey -Name tildaz
    }

    foreach ($path in @($shortcut, $dest, $state)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }

    Write-Host 'Removed TildaZ.'
    Write-Host "Kept your config and logs. Delete them by hand if you do not need them:"
    Write-Host "  $config\"
}

# Print a failure as one line instead of a PowerShell error record.
try { Uninstall-TildaZ } catch { Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red }
