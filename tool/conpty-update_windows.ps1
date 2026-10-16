# 번들 ConPTY (OpenConsole.exe + conpty.dll) 를 새 판으로 올린다 (#757).
#
# ```powershell
# powershell.exe -NoProfile -File tool\conpty-update_windows.ps1 -List                    # NuGet 판 목록 · 지금 번들 판
# powershell.exe -NoProfile -File tool\conpty-update_windows.ps1 -Notes 1.25.260930003    # 그 사이 ConPTY 변경만
# powershell.exe -NoProfile -File tool\conpty-update_windows.ps1 -Version 1.25.260930003  # 바이너리 · 문서 교체
# ```
#
# - 지금 판은 `vendor/conpty/README.md` 의 `- 버전:` 줄에서 읽는다. 이 줄이 판 번호의 단일 출처다.
# - `-Notes` 는 microsoft/terminal 릴리즈 본문 끝의 "Binary files ... bear the version number `X`" 로
#   각 릴리즈의 ConPTY 판을 알아내, 지금 판보다 크고 대상 판 이하인 릴리즈만 본다. 그 본문에서
#   ConPTY · conhost · 콘솔 호스팅 항목만 뽑고, 미리보기와 안정판에 같은 줄이 있으면 한 번만 낸다.
#   GitHub API 를 인증 없이 부른다 (시간당 60 회 — 한 번에 1 회 쓴다).
# - `-Version` 은 nupkg 를 새 빈 폴더에 받아 푼다. 바꿀 네 파일의 Authenticode 서명이 유효하고
#   서명자가 Microsoft 인지 확인한 뒤에만 복사한다. 판 번호가 적힌 문서 두 곳
#   (`vendor/conpty/README.md` · `dist/signpath-application.md`) 도 고친다.
# - 바꾼 뒤 무엇을 확인할지는 `vendor/conpty/README.md` 의 "업데이트 후 확인" 절이 단일 출처다.
#
# ⚠️ 이 파일은 UTF-8 **BOM** 으로 저장한다 (Windows PowerShell 5.1 이 BOM 없는 `.ps1` 을 cp949 로 읽는다).
param(
    [switch]$List,
    [string]$Notes,
    [string]$Version
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = Split-Path $PSScriptRoot -Parent
$Readme = Join-Path $Root 'vendor\conpty\README.md'
$Signpath = Join-Path $Root 'dist\signpath-application.md'
$Feed = 'https://api.nuget.org/v3-flatcontainer/microsoft.windows.console.conpty'
$Utf8 = New-Object System.Text.UTF8Encoding $false

function CurrentVersion {
    $m = [regex]::Match([IO.File]::ReadAllText($Readme, $Utf8), '(?m)^- 버전: `([^`]+)`')
    if (-not $m.Success) { throw "vendor/conpty/README.md 에서 '- 버전:' 줄을 못 찾았다" }
    return $m.Groups[1].Value
}
# "1.25.260930003" · "1.26.260930004-preview" → 비교용 [major, minor, build]. 미리보기 꼬리는 버린다.
function Key([string]$v) {
    $p = ($v -replace '-.*$', '') -split '\.'
    return , @([long]$p[0], [long]$p[1], [long]$p[2])
}
function Cmp([string]$a, [string]$b) {
    $x = Key $a; $y = Key $b
    for ($i = 0; $i -lt 3; $i++) { if ($x[$i] -ne $y[$i]) { return [math]::Sign($x[$i] - $y[$i]) } }
    return 0
}

$cur = CurrentVersion

if ($List) {
    $all = (Invoke-RestMethod "$Feed/index.json").versions
    "지금 번들: $cur"
    "NuGet 판 (지금보다 새 판만):"
    foreach ($v in $all) {
        if ((Cmp $v $cur) -le 0) { continue }
        $kind = if ($v -match '-') { '미리보기' } else { '안정판' }
        "  $v  ($kind)"
    }
    return
}

if ($Notes) {
    $rel = Invoke-RestMethod 'https://api.github.com/repos/microsoft/terminal/releases?per_page=100' -Headers @{ 'User-Agent' = 'tildaz-conpty-update' }
    $pick = @()
    foreach ($r in $rel) {
        $m = [regex]::Match([string]$r.body, 'version number `([^`]+)`')
        if (-not $m.Success) { continue }
        $bin = $m.Groups[1].Value
        if ((Cmp $bin $cur) -le 0 -or (Cmp $bin $Notes) -gt 0) { continue }
        $pick += [pscustomobject]@{ tag = $r.tag_name; bin = $bin; date = $r.published_at; body = [string]$r.body }
    }
    "지금 번들 $cur → $Notes 사이 Terminal 릴리즈 $($pick.Count) 개"
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $kw = '(?i)conpty|conhost|openconsole|console host|pseudo ?console'
    foreach ($r in ($pick | Sort-Object { $k = Key $_.bin; '{0:d4}{1:d4}{2:d12}' -f $k[0], $k[1], $k[2] }, date)) {
        $out = @(); $inSection = $false
        foreach ($line in ($r.body -split "`r?`n")) {
            if ($line -match '^\s*#') { $inSection = $line -match $kw; continue }
            if ($line -notmatch '^\s*[\*\-]\s') { continue }
            if (-not ($inSection -or $line -match $kw)) { continue }
            $t = $line.Trim()
            if ($seen.Add($t)) { $out += "  $t" }
        }
        "## $($r.tag) (ConPTY $($r.bin), $(([string]$r.date).Substring(0, 10)))"
        if ($out.Count) { $out } else { "  (ConPTY · 콘솔 항목 없음)" }
    }
    return
}

if ($Version) {
    if ((Cmp $Version $cur) -eq 0 -and $Version -eq $cur) { throw "이미 $cur 다" }
    $work = Join-Path $env:TEMP ("conpty-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $work | Out-Null
    $lower = $Version.ToLower()
    $nupkg = Join-Path $work "conpty.$lower.zip"
    "받는 중: $Version"
    Invoke-WebRequest "$Feed/$lower/microsoft.windows.console.conpty.$lower.nupkg" -OutFile $nupkg -UseBasicParsing
    $x = Join-Path $work 'x'
    Expand-Archive $nupkg -DestinationPath $x
    $map = @(
        @{ src = 'build\native\runtimes\x64\OpenConsole.exe';   dst = 'vendor\conpty\x64\OpenConsole.exe' },
        @{ src = 'runtimes\win-x64\native\conpty.dll';          dst = 'vendor\conpty\x64\conpty.dll' },
        @{ src = 'build\native\runtimes\arm64\OpenConsole.exe'; dst = 'vendor\conpty\arm64\OpenConsole.exe' },
        @{ src = 'runtimes\win-arm64\native\conpty.dll';        dst = 'vendor\conpty\arm64\conpty.dll' }
    )
    foreach ($e in $map) {
        $s = Join-Path $x $e.src
        if (-not (Test-Path $s)) { throw "패키지에 없음: $($e.src) — 패키지 구조가 바뀌었다. 이 표를 고친다" }
        $sig = Get-AuthenticodeSignature $s
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
            throw "서명 확인 실패: $($e.src) — $($sig.Status) · $($sig.SignerCertificate.Subject)"
        }
    }
    foreach ($e in $map) {
        $s = Join-Path $x $e.src; $d = Join-Path $Root $e.dst
        $old = if (Test-Path $d) { (Get-Item $d).VersionInfo.FileVersion } else { '(없음)' }
        Copy-Item $s $d -Force
        "  {0,-36} {1} → {2}" -f $e.dst, $old, (Get-Item $d).VersionInfo.FileVersion
    }
    $t = [IO.File]::ReadAllText($Readme, $Utf8)
    $kind = if ($Version -match '-') { 'preview' } else { 'stable' }
    $t = [regex]::Replace($t, '(?m)^- 버전: `[^`]+` \([^)]*\)', "- 버전: ``$Version`` ($kind)")
    [IO.File]::WriteAllText($Readme, $t, $Utf8)
    $s2 = [IO.File]::ReadAllText($Signpath, $Utf8)
    if (-not $s2.Contains("NuGet $cur")) { throw "dist/signpath-application.md 에서 'NuGet $cur' 을 못 찾았다" }
    [IO.File]::WriteAllText($Signpath, $s2.Replace("NuGet $cur", "NuGet $Version"), $Utf8)
    "문서: vendor/conpty/README.md · dist/signpath-application.md 의 판 번호를 $cur → $Version 로 바꿨다"
    Remove-Item $work -Recurse -Force
    "다음: vendor/conpty/README.md 의 '업데이트 후 확인' 절대로 확인한다"
    return
}

"쓰는 법: -List | -Notes <판> | -Version <판>"
