# tildaz Windows 빌드 스크립트 (PowerShell).
#
# Windows 기본 셸인 PowerShell 에서 바로 실행해요. 실제 빌드는 zig 가 담당하고,
# 이 스크립트는 인자 파싱 + 캐시 디렉토리 관리 + clean 옵션 처리만 해요.
#
# zig 가 WSL UNC 경로 (\\wsl$\...) 를 source root 로 받을 때 Windows 로컬
# 캐시가 있어야 속도가 나오므로 기본 캐시를 C:\ziglang\tildaz-cache 로 잡아요.
#
# `zig build --fetch=all` 은 쓰지 않아요 — 폰트용 lazy 의존성
# (ghostty → fontconfig → libxml2) 의 libxml2 tarball 이 Unix 심볼릭 링크
# (test fixtures) 를 담고 있어, 심볼릭 링크 권한 없는 Windows (Developer Mode
# off) 에선 unpack 이 AccessDenied 로 실패해요. build.zig 가 ghostty 의존성에
# font-backend=.freetype 를 명시해 fontconfig 경로 자체를 차단하므로 libxml2 를
# 아예 안 받아요 (AGENTS.md "실행 환경" 참고).
#
# 사용법:
#   dist\windows\build.ps1                      # 전체 빌드 (ReleaseFast)
#   dist\windows\build.ps1 -Clean
#   dist\windows\build.ps1 -Optimize Debug
#   dist\windows\build.ps1 -CacheDir C:\tmp\zig-cache
#   dist\windows\build.ps1 -Check               # 6-target compile-only 검증 (#201)
#   dist\windows\build.ps1 -Test                # 단위 테스트 (ReleaseSafe)

[CmdletBinding()]
param(
    [switch]$Clean,
    [string]$Optimize = "ReleaseFast",
    [string]$CacheDir = "C:\ziglang\tildaz-cache",
    [switch]$Check,
    [switch]$Test
)

$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $RepoRoot

# zig build 래퍼 — 캐시 디렉토리가 설정돼 있으면 --cache-dir 를 붙여요.
function Invoke-Zig {
    param([string[]]$ZigArgs)
    if ($CacheDir) {
        & zig build @ZigArgs --cache-dir $CacheDir
    } else {
        & zig build @ZigArgs
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

    Write-Host "--- zig build -Doptimize=$Optimize ---"
    Invoke-Zig @("-Doptimize=$Optimize")

    Write-Host "--- Post-build zig-out\bin ---"
    if (Test-Path zig-out\bin) {
        Get-ChildItem zig-out\bin
    } else {
        Write-Error "(no zig-out\bin produced!)"
        exit 1
    }
}
