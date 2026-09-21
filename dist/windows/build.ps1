# tildaz Windows 빌드 스크립트 (PowerShell).
#
# Windows 기본 셸인 PowerShell 에서 바로 실행해요. 실제 빌드는 zig 가 담당하고,
# 이 스크립트는 빌드 종류 선택 + 캐시 디렉터리 관리 + clean 옵션을 맡아요.
#
# Windows 로컬 checkout에서 빌드 산출물과 dependency cache를 모두 native
# filesystem에 두도록 기본 캐시를 C:\ziglang\tildaz-cache 로 잡아요.
# WSL distro나 UNC source path는 필요하지 않아요.
#
# `zig build --fetch=all` 은 쓰지 않아요 — 폰트용 lazy 의존성
# (ghostty → fontconfig → libxml2) 의 libxml2 tarball 이 Unix 심볼릭 링크
# (test fixtures) 를 담고 있어, 심볼릭 링크 권한 없는 Windows (Developer Mode
# off) 에선 unpack 이 AccessDenied 로 실패해요. build.zig 가 ghostty 의존성에
# font-backend=.freetype 를 명시해 fontconfig 경로 자체를 차단하므로 libxml2 를
# 아예 안 받아요 (AGENTS.md "실행 환경" 참고).
#
# 사용법:
#   dist\windows\build.ps1                      # dev 빌드 (ReleaseFast + SIMD)
#   dist\windows\build.ps1 --release            # 릴리즈 빌드
#   dist\windows\build.ps1 --no-simd            # scalar 진단 빌드
#   dist\windows\build.ps1 --clean
#   dist\windows\build.ps1 --optimize Debug
#   dist\windows\build.ps1 --cache-dir C:\tmp\zig-cache
#   dist\windows\build.ps1 --check               # 6-target compile-only 검증 (#201)
#   dist\windows\build.ps1 --test                # 단위 테스트 (ReleaseSafe)

# PowerShell 고유 인자 표기 대신 세 OS 공통 --release 를 그대로 받는다.
# dev 는 옵션이 없는 기본값이다. 환경변수나 경로로 종류를 추측하지 않는다.
$ErrorActionPreference = "Stop"
$Clean = $false
$Optimize = "ReleaseFast"
$CacheDir = "C:\ziglang\tildaz-cache"
$Check = $false
$Test = $false
$NoSimd = $false
$ReleaseValue = "false"
$ScriptArgs = @($args)
for ($i = 0; $i -lt $ScriptArgs.Count; $i++) {
    $arg = $ScriptArgs[$i]
    switch -CaseSensitive ($arg) {
        '--release' { $ReleaseValue = "true" }
        '--clean' { $Clean = $true }
        '--check' { $Check = $true }
        '--test' { $Test = $true }
        '--no-simd' { $NoSimd = $true }
        { $_ -eq '--optimize' -or $_ -eq '--cache-dir' } {
            if ($i + 1 -ge $ScriptArgs.Count -or [string]::IsNullOrEmpty($ScriptArgs[$i + 1]) -or $ScriptArgs[$i + 1].StartsWith('--')) {
                [Console]::Error.WriteLine("ERROR: $arg requires a value")
                exit 2
            }
            $i++
            if ($arg -eq '--optimize') { $Optimize = $ScriptArgs[$i] }
            else { $CacheDir = $ScriptArgs[$i] }
        }
        { $_ -eq '--help' -or $_ -eq '-h' } {
            Write-Output "Usage: build.ps1 [--release] [--clean] [--optimize <mode>] [--cache-dir <path>] [--check | --test] [--no-simd]"
            Write-Output "Build dev by default; --release selects the release identity."
            exit 0
        }
        default {
            [Console]::Error.WriteLine("Unknown argument: $arg")
            exit 2
        }
    }
}
if (@('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall') -cnotcontains $Optimize) {
    [Console]::Error.WriteLine("ERROR: invalid optimization mode: $Optimize")
    exit 2
}
if ($Check -and $Test) {
    [Console]::Error.WriteLine("ERROR: choose --check or --test")
    exit 2
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $RepoRoot

# zig build 래퍼 — 캐시 디렉토리가 설정돼 있으면 --cache-dir 를 붙여요.
function Invoke-Zig {
    param([string[]]$ZigArgs)
    if ($CacheDir) {
        & zig build "-Drelease=$ReleaseValue" @ZigArgs --cache-dir $CacheDir
    } else {
        & zig build "-Drelease=$ReleaseValue" @ZigArgs
    }
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if ($Clean) {
    Write-Host "--- Wiping zig-out\ and cache ---"
    if (Test-Path zig-out) { Remove-Item -Recurse -Force zig-out }
    if ($CacheDir -and (Test-Path $CacheDir)) { Remove-Item -Recurse -Force $CacheDir }
}

if ($Check) {
    # Linux / macOS / Windows x (x86_64 / aarch64) 6 타겟 compile-only.
    # mac / Linux host 코드의 컴파일 에러를 Windows 한 머신에서 잡아요.
    Write-Host "--- zig build check (6-target compile-only, #201) ---"
    Invoke-Zig @("check")
    Write-Host "--- check OK ---"
} elseif ($Test) {
    # 단위 테스트. debug .sframe 링커 에러 회피 위해 ReleaseSafe.
    Write-Host "--- zig build test -Doptimize=ReleaseSafe ---"
    Invoke-Zig @("test", "-Doptimize=ReleaseSafe")
    Write-Host "--- test OK ---"
} else {
    Write-Host "--- Pre-build zig-out\bin ---"
    if (Test-Path zig-out\bin) { Get-ChildItem zig-out\bin } else { Write-Host "(no zig-out\bin)" }

    # 공식 구성과 같은 ReleaseFast는 SIMD on. Debug 등 다른 mode와 --no-simd
    # 진단 빌드는 scalar를 유지한다 (#19).
    $SimdValue = if ($Optimize -eq "ReleaseFast" -and -not $NoSimd) { "true" } else { "false" }
    Write-Host "--- zig build -Doptimize=$Optimize -Dsimd=$SimdValue ---"
    Invoke-Zig @("-Doptimize=$Optimize", "-Dsimd=$SimdValue")

    Write-Host "--- Post-build zig-out\bin ---"
    if (Test-Path zig-out\bin) {
        Get-ChildItem zig-out\bin
    } else {
        Write-Error "(no zig-out\bin produced!)"
        exit 1
    }
}
