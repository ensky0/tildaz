# TildaZ installer for Windows.
#
#   powershell -ExecutionPolicy ByPass -c "irm https://ensky0.github.io/tildaz/install.ps1 | iex"
#
# What it does:
#   1. Finds the latest release (or $env:TILDAZ_VERSION) on GitHub.
#   2. Downloads the release zip and its .sha256, and stops if they differ.
#   3. Installs to %LOCALAPPDATA%\Programs\TildaZ and adds a Start Menu shortcut.
#   4. Starts TildaZ once. TildaZ sets up auto-start itself on its first run.
#
# Everything goes into your user profile. No admin rights are needed.
#
# Environment:
#   $env:TILDAZ_VERSION = '0.10.4'   install this release instead of the latest
#   $env:TILDAZ_NO_LAUNCH = '1'      do not start TildaZ after installing
#
# Source: https://github.com/ensky0/tildaz/blob/main/docs/install.ps1
#
# Keep this file ASCII. "irm | iex" reads it as a string, and Windows
# PowerShell 5.1 reads a BOM-less non-ASCII file in the local code page.
#
# The whole script is one function called on the last lines, so a download cut
# off halfway runs nothing.

function Install-TildaZ {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is much slower with the progress bar
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $repo = 'ensky0/tildaz'

    # Same paths as dist\windows\install.bat --release, so uninstall.bat removes them.
    $dest = Join-Path $env:LOCALAPPDATA 'Programs\TildaZ'
    $shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'TildaZ.lnk'

    # The tag comes from the address GitHub redirects /releases/latest to. This avoids
    # the GitHub API and its rate limit.
    $tag = $env:TILDAZ_VERSION
    if (-not $tag) {
        $req = [Net.WebRequest]::Create("https://github.com/$repo/releases/latest")
        $req.Method = 'HEAD'
        $resp = $req.GetResponse()
        $tag = $resp.ResponseUri.AbsoluteUri.Split('/')[-1]
        $resp.Close()
    } elseif (-not $tag.StartsWith('v')) {
        $tag = "v$tag"
    }
    if ($tag -notmatch '^v[0-9]') { throw "Could not find the latest TildaZ release (got '$tag')." }

    $cpu = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $arch = switch ($cpu) {
        'AMD64' { 'x64' }
        'ARM64' { 'arm64' }
        default { throw "Unsupported CPU: $cpu (TildaZ ships x64 and arm64)." }
    }

    # A running TildaZ locks its files. Do not stop it here: it may hold open shells.
    # A release TildaZ started from anywhere else, such as an unzipped release, counts
    # too: the new copy would only ask it to open another instance. Every release
    # since v0.0.1 names its window class TildaZWindow (dev builds use TildaZ-devWindow).
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
        throw "TildaZ is running. Quit it and run this installer again."
    }

    # An earlier copy started at login from another folder (an unzipped release).
    # The new copy takes over auto-start on its first run; the old folder stays.
    $oldDir = $null
    $run = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name tildaz -ErrorAction SilentlyContinue).tildaz
    if ($run -and $run -match '^"([^"]+)"') {
        $oldExe = $Matches[1]
        if (-not $oldExe.StartsWith("$dest\", [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $oldExe)) {
            $oldDir = Split-Path $oldExe
        }
    }

    $name = "tildaz-$tag-win-$arch.zip"
    $base = "https://github.com/$repo/releases/download/$tag"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("tildaz-install-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp $name
        Write-Host "Downloading $name"
        Invoke-WebRequest -UseBasicParsing -Uri "$base/$name" -OutFile $zip
        Invoke-WebRequest -UseBasicParsing -Uri "$base/$name.sha256" -OutFile "$zip.sha256"
        $want = ((Get-Content -Raw "$zip.sha256").Trim() -split '\s+')[0].ToLowerInvariant()
        $got = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash.ToLowerInvariant()
        if ($want -ne $got) {
            throw "SHA-256 mismatch for $name (expected $want, got $got). Nothing was installed."
        }
        Write-Host 'Checked SHA-256'

        $unpacked = Join-Path $tmp 'unpacked'
        Expand-Archive -Path $zip -DestinationPath $unpacked
        if (-not (Test-Path (Join-Path $unpacked 'tildaz.exe'))) { throw 'The release zip has no tildaz.exe.' }

        # Copy next to the destination first, then swap, so a failed copy never
        # leaves a half-installed app.
        $parent = Split-Path $dest
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        $new = "$dest.new"
        $old = "$dest.old"
        if (Test-Path $new) { Remove-Item -Recurse -Force $new }
        Copy-Item -Recurse -Path $unpacked -Destination $new
        Get-ChildItem -Recurse -File $new | Unblock-File
        if (Test-Path $old) { Remove-Item -Recurse -Force $old }
        if (Test-Path $dest) {
            try { Rename-Item -Path $dest -NewName (Split-Path $old -Leaf) }
            catch { throw "Could not replace $dest. A file in it is in use: quit TildaZ and run this installer again." }
        }
        Rename-Item -Path $new -NewName (Split-Path $dest -Leaf)
        if (Test-Path $old) { Remove-Item -Recurse -Force $old -ErrorAction SilentlyContinue }
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }

    $exe = Join-Path $dest 'tildaz.exe'
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($shortcut)
    $lnk.TargetPath = $exe
    $lnk.WorkingDirectory = $dest
    $lnk.Save()

    Write-Host "Installed TildaZ $tag to $dest"
    Write-Host "Added Start Menu shortcut: $shortcut"
    if ($oldDir) {
        Write-Host "An earlier TildaZ is in $oldDir. Your config is shared, so you can delete that folder."
    }
    if ($env:TILDAZ_NO_LAUNCH) {
        Write-Host 'Start TildaZ from the Start Menu. Auto-start moves to this copy on its first run.'
        return
    }
    Start-Process -FilePath $exe -WorkingDirectory $dest
    Write-Host 'Started TildaZ. Press its hotkey (F1 by default) to show or hide it.'
}

# Print a failure as one line instead of a PowerShell error record.
try { Install-TildaZ } catch { Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red }
