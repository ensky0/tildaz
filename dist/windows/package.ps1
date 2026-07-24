# tildaz Windows 릴리즈 번들 zip + SHA256 sidecar 생성.
#
# zip 레이아웃:
#   tildaz.exe                  (최상위 — 사용자가 실행할 단 하나의 exe)
#   README.txt
#   _internal\conpty.dll
#   _internal\OpenConsole.exe
# Microsoft 런타임 2개는 _internal\ 하위로 숨겨 사용자가 tildaz.exe 만 실행하도록
# 유도해요. conpty.dll 이 sibling OpenConsole.exe 를 찾으므로 둘은 같은 폴더에
# 있어야 하고, tildaz.exe 는 <exe dir>\_internal\conpty.dll 을 절대경로로 로드해요.
# 소스는 zig-out\bin (tildaz.exe) + zig-out\bin\_internal (런타임 2개)로, build.zig
# install 단계가 같은 구조로 떨궈요. Windows PowerShell 5.1의 Compress-Archive /
# Get-FileHash만 사용하므로 WSL과 Git Bash가 필요하지 않아요.
#
# 사용법:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File dist\windows\package.ps1 -Version 0.6.2
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File dist\windows\package.ps1 -Version 0.6.2 -Clean

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

if ($Version -notmatch '^[0-9A-Za-z][0-9A-Za-z.+-]*$') {
    throw "Version must be a SemVer-compatible filename component (got '$Version')."
}

$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$SourceBin = Join-Path $RepoRoot "zig-out\bin"
$SourceInternal = Join-Path $SourceBin "_internal"
$SourceReadme = Join-Path $PSScriptRoot "README.txt"
$ReleaseRoot = Join-Path $RepoRoot "zig-out\release"

# 삭제 가능한 경계를 고정된 repo/zig-out/release 아래로 제한해요.
$RepoPrefix = $RepoRoot.TrimEnd('\') + '\'
$ReleaseRootFull = [System.IO.Path]::GetFullPath($ReleaseRoot)
if (-not $ReleaseRootFull.StartsWith($RepoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Release path escaped the repository: $ReleaseRootFull"
}

# 최상위 exe 와 _internal\ 하위 런타임을 나눠 검증. (PE arch 검사 대상이기도 함.)
$RootFiles = @("tildaz.exe")
$InternalFiles = @("conpty.dll", "OpenConsole.exe")
foreach ($FileName in $RootFiles) {
    $Source = Join-Path $SourceBin $FileName
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Missing artifact '$FileName' at $SourceBin. Run 'zig build' first."
    }
}
foreach ($FileName in $InternalFiles) {
    $Source = Join-Path $SourceInternal $FileName
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Missing artifact '_internal\$FileName' at $SourceInternal. Run 'zig build' first."
    }
}
if (-not (Test-Path -LiteralPath $SourceReadme -PathType Leaf)) {
    throw "Missing README at $SourceReadme"
}

function Get-PeArchitecture {
    param([Parameter(Mandatory = $true)][string]$Path)

    $Stream = [System.IO.File]::OpenRead($Path)
    try {
        if ($Stream.Length -lt 0x40) {
            throw "Invalid PE file (DOS header too short): $Path"
        }

        $OffsetBytes = New-Object byte[] 4
        $Stream.Position = 0x3c
        if ($Stream.Read($OffsetBytes, 0, 4) -ne 4) {
            throw "Invalid PE file (missing PE offset): $Path"
        }
        $PeOffset = [System.BitConverter]::ToInt32($OffsetBytes, 0)
        if ($PeOffset -lt 0 -or $PeOffset + 6 -gt $Stream.Length) {
            throw "Invalid PE file (PE offset out of range): $Path"
        }

        $HeaderBytes = New-Object byte[] 6
        $Stream.Position = $PeOffset
        if ($Stream.Read($HeaderBytes, 0, 6) -ne 6 -or
            [System.BitConverter]::ToUInt32($HeaderBytes, 0) -ne 0x00004550) {
            throw "Invalid PE signature: $Path"
        }

        $Machine = [System.BitConverter]::ToUInt16($HeaderBytes, 4)
        switch ($Machine) {
            0x8664 { return "x64" }
            0xAA64 { return "arm64" }
            default { throw ("Unsupported PE machine 0x{0:X4}: {1}" -f $Machine, $Path) }
        }
    } finally {
        $Stream.Dispose()
    }
}

$PeFiles = @(Join-Path $SourceBin "tildaz.exe")
foreach ($FileName in $InternalFiles) { $PeFiles += (Join-Path $SourceInternal $FileName) }
$Arch = $null
foreach ($Source in $PeFiles) {
    $FileArch = Get-PeArchitecture -Path $Source
    if ($null -eq $Arch) {
        $Arch = $FileArch
    } elseif ($FileArch -ne $Arch) {
        throw "PE architecture mismatch: $Source is $FileArch, expected $Arch"
    }
}
Write-Host "--- Detected PE architecture: $Arch ---"

$Name = "tildaz-v$Version-win-$Arch"
$Stage = Join-Path $ReleaseRoot $Name
$Zip = Join-Path $ReleaseRoot "$Name.zip"
$Sha256 = "$Zip.sha256"

if ($Clean -and (Test-Path -LiteralPath $ReleaseRoot)) {
    Write-Host "--- Wiping $ReleaseRoot ---"
    Remove-Item -LiteralPath $ReleaseRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $ReleaseRoot -Force | Out-Null

foreach ($Path in @($Stage, $Zip, $Sha256)) {
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}
New-Item -ItemType Directory -Path $Stage | Out-Null

Write-Host "--- Staging to $Stage ---"
$StageInternal = Join-Path $Stage "_internal"
New-Item -ItemType Directory -Path $StageInternal | Out-Null

foreach ($FileName in $RootFiles) {
    Copy-Item -LiteralPath (Join-Path $SourceBin $FileName) -Destination (Join-Path $Stage $FileName)
}
foreach ($FileName in $InternalFiles) {
    Copy-Item -LiteralPath (Join-Path $SourceInternal $FileName) -Destination (Join-Path $StageInternal $FileName)
}
Copy-Item -LiteralPath $SourceReadme -Destination (Join-Path $Stage "README.txt")
Get-ChildItem -LiteralPath $Stage | Format-Table Mode, Length, Name
Get-ChildItem -LiteralPath $StageInternal | Format-Table Mode, Length, Name

Write-Host "--- Creating $Zip ---"
# 최상위 파일 + _internal 디렉터리를 -LiteralPath 로 넘겨요. Compress-Archive 는
# 디렉터리를 재귀 포함하며 zip 안에 _internal\ 구조를 그대로 보존해요.
$ArchiveInputs = @(
    (Join-Path $Stage "tildaz.exe"),
    (Join-Path $Stage "README.txt"),
    $StageInternal
)
Compress-Archive -LiteralPath $ArchiveInputs -DestinationPath $Zip -CompressionLevel Optimal

Write-Host "--- Creating $Sha256 ---"
$Hash = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToLowerInvariant()
$Sidecar = "$Hash  $([System.IO.Path]::GetFileName($Zip))`n"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($Sha256, $Sidecar, $Utf8NoBom)

Write-Host "--- Output ---"
Get-Item -LiteralPath $Zip, $Sha256 | Format-Table Length, FullName
Get-Content -LiteralPath $Sha256
