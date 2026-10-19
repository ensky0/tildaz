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
# Your config and logs in %APPDATA%\tildaz are kept.
#
# Source: https://github.com/ensky0/tildaz/blob/main/docs/uninstall.ps1
#
# Keep this file ASCII (see install.ps1). The whole script is one function
# called on the last line, so a download cut off halfway runs nothing.

function Uninstall-TildaZ {
    $ErrorActionPreference = 'Stop'

    # Same paths as install.ps1 and dist\windows\install.bat --release.
    $dest = Join-Path $env:LOCALAPPDATA 'Programs\TildaZ'
    $shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'TildaZ.lnk'
    $state = Join-Path $env:LOCALAPPDATA 'tildaz'
    $config = Join-Path $env:APPDATA 'tildaz'
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

    # Do not stop a running TildaZ here: it may hold open shells.
    $running = @(Get-Process -Name tildaz, OpenConsole -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith("$dest\", [StringComparison]::OrdinalIgnoreCase) })
    if ($running.Count -gt 0) {
        throw 'TildaZ is running. Quit it and run this uninstaller again.'
    }

    $removed = $false

    # The app writes this value on its first run. Value names are case-insensitive,
    # so this also covers "TildaZ" from releases before 0.10. Leave it alone if it
    # points at a TildaZ copy somewhere else.
    $run = (Get-ItemProperty -Path $runKey -Name tildaz -ErrorAction SilentlyContinue).tildaz
    if ($run -and $run.IndexOf($dest, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        Remove-ItemProperty -Path $runKey -Name tildaz
        $removed = $true
    }

    foreach ($path in @($shortcut, $dest, $state)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
            $removed = $true
        }
    }

    if (-not $removed) {
        Write-Host 'TildaZ is not installed.'
        return
    }
    Write-Host 'Removed TildaZ.'
    Write-Host "Kept your config and logs. Delete them by hand if you do not need them:"
    Write-Host "  $config\"
}

Uninstall-TildaZ
