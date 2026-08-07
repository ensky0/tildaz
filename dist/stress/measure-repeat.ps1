# perf 스냅숏 반복 측정 (Windows) — 배분을 5 회 규칙대로 뜬다.
#
# `compare-terminals.sh` 와 역할이 다르다. 저쪽은 **여러 터미널을 나란히 놓고 처리량**을
# 재고, 이쪽은 **우리 앱 하나**를 반복해 띄워 종료 시 자동 덤프 (#396) 로 남는
# `parse` · `render` · `shape` 배분을 모은다. 그래서 Git Bash 가 필요 없고 PowerShell
# 에서 그대로 돈다.
#
# 쓰는 법 (README 의 "측정 위생" 을 먼저 읽어요):
#
#   zig build -Doptimize=ReleaseFast -Dsimd=true --cache-dir C:/ziglang/tildaz-cache
#   dist/stress/measure-repeat.ps1 -Phase before
#   dist/stress/measure-repeat.ps1 -Phase after -Workloads zwj,plain
#
# 결과는 `-Out` (기본 `dist/stress/shots/`) 에 `<Phase>-raw.txt` (로그 원문) 와
# `<Phase>.csv` (회차별 값) 로 남고, 표는 화면에 찍는다.

[CmdletBinding()]
param(
    # 결과 파일 이름과 표 제목이 된다. before / after 를 나눠 부를 때 쓴다.
    [string]$Phase = 'run',
    [int]$Mb = 64,
    # `powershell -File` 로 부르면 `-Workloads a,b` 가 **문자열 하나**로 들어온다.
    # 아래에서 쉼표로 다시 쪼갠다.
    [string[]]$Workloads = @('plain', 'cjk', 'emoji_vs16', 'zwj'),
    [int]$Repeat = 5,
    # #397 의 드레인 고침 이후 HOLD 는 필요 없다. 주면 출력이 끝난 뒤 idle 프레임이
    # 섞여 `render` 가 낮게 나오고 `readloop` 이 그 유휴를 통째로 계상한다.
    [int]$HoldMs = 0,
    # 배경 앱이 그리고 있으면 우리 수치만 눌린다 — 창을 내리고 이만큼 가라앉힌다.
    [int]$LeadInSec = 8,
    [string]$Out,
    # AC · 주사율 점검에서 걸려도 강행한다 (동작 확인용).
    [switch]$IgnoreHygiene
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$exe = Join-Path $repo 'zig-out\bin\tildaz.exe'
$stress = Join-Path $repo 'zig-out\bin\tildaz-stress.exe'
$log = Join-Path $env:APPDATA 'tildaz\tildaz_stress.log'
if (-not $Out) { $Out = Join-Path $PSScriptRoot 'shots' }
if (-not (Test-Path $Out)) { New-Item -ItemType Directory -Path $Out | Out-Null }

# `-Workloads a,b` 가 문자열 하나로 들어온 경우를 편다. 이걸 안 하면
# TILDAZ_STRESS_WORKLOAD 에 "a,b" 가 들어가고 stress.zig 의 `Kind.parse` 가
# 탈락시켜 **producer 모드로 진입하지 않는다** — 창은 뜨는데 폭포가 없고 회차가
# 통째로 껍데기가 된다 (실측에서 10 회를 날렸다).
$Workloads = @($Workloads | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })

# 이름을 미리 검증한다. 오타 하나로 회차 전부가 날아가지 않게.
# 목록은 `src/stress/workload.zig` 의 `Kind` 와 같아야 한다.
$known = @('plain', 'ansi', 'cjk', 'hangul', 'emoji_vs16', 'skintone', 'zwj',
    'hangul_varied', 'emoji_vs16_varied', 'skintone_varied', 'zwj_varied')
foreach ($w in $Workloads) {
    if ($known -notcontains $w) { throw "모르는 워크로드 '$w' — 가능: $($known -join ', ')" }
}

if (-not (Test-Path $exe)) { throw "tildaz.exe 없음: $exe  (먼저 zig build)" }
if (-not (Test-Path $stress)) { throw "tildaz-stress.exe 없음: $stress  (먼저 zig build stress)" }

# 평소 쓰는 worker 가 떠 있으면 렌더 · CPU 를 나눠 쓴다 (README 측정 위생).
$worker = Get-Process tildaz -ErrorAction SilentlyContinue
if ($worker) { throw "tildaz worker 가 떠 있어요 (pid $($worker.Id -join ',')) — 먼저 내려요" }

# --- 측정 위생 사전 점검 ---------------------------------------------------
#
# 배터리로 돌거나 동적 새로 고침 빈도(DRR)가 켜져 있으면 값이 조용히 오염된다.
# 전에 이걸 안 보고 40 회차를 버렸다 — `render calls` 가 두 무리로 갈렸고
# 절대값이 35 % 눌렸다. 자세한 내용은 README 의 "측정 위생" 을 봐요.
$warn = @()
$batt = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
if ($batt -and $batt.BatteryStatus -eq 1) {
    $warn += 'AC 미연결 (BatteryStatus=1) — 배터리에서는 스로틀링이 걸리고 패널이 60 Hz 로 강등되기도 해요'
}
$vc = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
if ($vc -and $vc.CurrentRefreshRate -and $vc.MaxRefreshRate -and $vc.CurrentRefreshRate -lt $vc.MaxRefreshRate) {
    $warn += "주사율이 $($vc.CurrentRefreshRate) Hz 인데 이 화면의 최대는 $($vc.MaxRefreshRate) Hz — 동적 새로 고침 빈도(DRR)를 끄고 고정 값을 골라요 (설정 → 시스템 → 디스플레이 → 고급 디스플레이)"
}
if ($warn.Count -gt 0) {
    foreach ($m in $warn) { Write-Warning $m }
    if (-not $IgnoreHygiene) { throw '측정 위생 점검에 걸렸어요. 고치거나 -IgnoreHygiene 로 강행해요.' }
}

# 화면 절전 / 잠금 차단 — Linux 의 `systemd-inhibit --what=idle:sleep` 대응.
# 잠금 화면이 뜨면 `render` 만 무너지고 `parse` 는 정상이라 결과 표에 안 드러난다.
Add-Type -Namespace Tildaz -Name Power -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
# ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED
[void][Tildaz.Power]::SetThreadExecutionState([uint32]2147483651)

$startLen = 0
if (Test-Path $log) { $startLen = (Get-Item $log).Length }

$head = git -C $repo rev-parse --short HEAD
$dirty = if (git -C $repo status --porcelain) { 'yes' } else { 'no' }
Write-Output "phase=$Phase  mb=$Mb  repeat=$Repeat  hold_ms=$HoldMs  workloads=$($Workloads -join ',')"
Write-Output "commit=$head  dirty=$dirty  refresh=$($vc.CurrentRefreshRate)Hz  battery_status=$($batt.BatteryStatus)"
Write-Output "log=$log  start_offset=$startLen"
Write-Output "회차 $($Workloads.Count * $Repeat) 개를 시작해요. 끝날 때까지 기기를 건드리지 마세요."

(New-Object -ComObject Shell.Application).MinimizeAll()
Start-Sleep -Seconds $LeadInSec

$env:TILDAZ_STRESS_BYTES = ([long]$Mb * 1MB).ToString()
$env:TILDAZ_STRESS_HOLD_MS = $HoldMs.ToString()

# **라운드로빈** — 워크로드를 안쪽에 두고 $Repeat 바퀴를 돈다. 한 워크로드를 몰아서
# 돌리면 열 드리프트가 그 워크로드에만 쌓인다 (#389 의 Linux · macOS 세션과 같은 순서).
for ($i = 1; $i -le $Repeat; $i++) {
    foreach ($w in $Workloads) {
        $env:TILDAZ_STRESS_WORKLOAD = $w
        $p = Start-Process -FilePath $exe `
            -ArgumentList @('-e', $stress, '-size', '120x40', '-scrollback', '32767') `
            -PassThru
        $p.WaitForExit()
        Start-Sleep -Milliseconds 1500
    }
}

# ES_CONTINUOUS 만 남겨 절전 억제 해제
[void][Tildaz.Power]::SetThreadExecutionState([uint32]2147483648)

# 이번 phase 에 추가된 로그만 잘라 낸다 (앱이 쥐고 있을 수 있어 공유 모드로 연다).
$fs = [System.IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
[void]$fs.Seek($startLen, 'Begin')
$sr = New-Object System.IO.StreamReader($fs)
$new = $sr.ReadToEnd()
$sr.Close(); $fs.Close()

$rawPath = Join-Path $Out "$Phase-raw.txt"
Set-Content -Path $rawPath -Value $new -Encoding utf8

$rows = @(); $cur = $null
foreach ($line in ($new -split "`r?`n")) {
    if ($line -match '^=== (\S+) @ ts=(\d+)ms ===') { $cur = [ordered]@{ workload = $Matches[1] } }
    elseif ($cur) {
        if ($line -match '^readloop calls=(\d+) bytes=(\d+) ms=([\d.]+)') { $cur.rl_calls = [int]$Matches[1]; $cur.rl_bytes = [long]$Matches[2]; $cur.readloop = [double]$Matches[3] }
        elseif ($line -match '^push\s+calls=(\d+) bytes=(\d+) yields=(\d+)') { $cur.yields = [long]$Matches[3] }
        elseif ($line -match '^drain\s+calls=(\d+) bytes=(\d+) ms=([\d.]+)') {
            $cur.drain_bytes = [long]$Matches[2]
            # #397 — 옳은 유효성 기준. `readloop bytes >= 요청` 은 PTY 에서 읽은 양이라
            # 부분 파싱을 못 잡는다. Windows 는 고정 16 byte 가 남는다 (원인 미확정).
            $cur.lost_bytes = $cur.rl_bytes - $cur.drain_bytes
            $cur.drain = [double]$Matches[3]
        }
        elseif ($line -match '^parse\s+calls=(\d+) ms=([\d.]+)') { $cur.parse = [double]$Matches[2] }
        elseif ($line -match '^render\s+calls=(\d+) ms=([\d.]+)') { $cur.render_calls = [int]$Matches[1]; $cur.render = [double]$Matches[2] }
        elseif ($line -match '^shape\s+calls=(\d+) ms=([\d.]+) miss=(\d+)') { $cur.shape_calls = [long]$Matches[1]; $cur.shape = [double]$Matches[2]; $cur.miss = [int]$Matches[3] }
        elseif ($line -match '^present\s+calls=(\d+) ms=([\d.]+)') { $cur.present_calls = [int]$Matches[1]; $cur.present = [double]$Matches[2] }
        elseif ($line -match '^onrender calls=(\d+) ms=([\d.]+) skip=(\d+)') {
            $cur.onrender_calls = [int]$Matches[1]; $cur.onrender = [double]$Matches[2]; $cur.skip = [int]$Matches[3]
            $rows += [pscustomobject]$cur; $cur = $null
        }
    }
}

$csvPath = Join-Path $Out "$Phase.csv"
$rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8

# 대표값은 절사평균 (min · max 를 뺀 나머지의 평균) — README 의 "대표값" 규칙.
# 표본이 3 개 미만이면 절사하지 않고 단순 평균으로 떨어지고, 그 사실을 표 위에 적는다.
function Trimmed([double[]]$v) {
    $s = @($v | Sort-Object)
    if ($s.Count -ge 3) { $s = $s[1..($s.Count - 2)] }
    ($s | Measure-Object -Average).Average
}

Write-Output ""
Write-Output "##### $Phase — $($rows.Count) 회차 #####"
if ($Repeat -lt 3) { Write-Output "⚠ 표본이 3 개 미만이라 절사하지 않고 단순 평균이에요." }

foreach ($w in $Workloads) {
    $g = @($rows | Where-Object workload -eq $w)
    if ($g.Count -eq 0) { Write-Output "$w : 회차 없음 (⚠ 실패)"; continue }
    $shapeRatio = [double[]]($g | ForEach-Object { if ($_.render -gt 0) { 100.0 * $_.shape / $_.render } else { 0 } })
    # `parse 비중` 은 **기존 표마다 계산식이 달랐다** — #389 의 Linux 표는 present 를 빼고
    # macOS 표는 넣었다 (각 표의 숫자로 역산해 확인). 어느 쪽과 견주든 되게 둘 다 찍는다.
    $parseShare = [double[]]($g | ForEach-Object { 100.0 * $_.parse / ($_.parse + $_.render) })
    $parseShareP = [double[]]($g | ForEach-Object { 100.0 * $_.parse / ($_.parse + $_.render + $_.present) })
    $perFrame = [double[]]($g | ForEach-Object { $_.render / $_.render_calls })
    $perShape = [double[]]($g | ForEach-Object { if ($_.shape_calls -gt 0) { 1000.0 * $_.shape / $_.shape_calls } else { 0 } })
    $lost = @($g | Where-Object { $_.lost_bytes -ne 0 })
    Write-Output ""
    Write-Output ("--- {0} ({1} 회차) ---" -f $w, $g.Count)
    foreach ($k in 'readloop', 'drain', 'parse', 'render', 'shape', 'present') {
        $v = [double[]]($g.$k)
        Write-Output ("{0,-9} {1,10:N3}   min~max {2:N3} ~ {3:N3}" -f $k, (Trimmed $v), ($v | Measure-Object -Minimum).Minimum, ($v | Measure-Object -Maximum).Maximum)
    }
    Write-Output ("{0,-13} {1,10:N1}   min~max {2:N1} ~ {3:N1}" -f 'shape/render%', (Trimmed $shapeRatio), ($shapeRatio | Measure-Object -Minimum).Minimum, ($shapeRatio | Measure-Object -Maximum).Maximum)
    Write-Output ("{0,-13} {1,10:N1}   min~max {2:N1} ~ {3:N1}" -f 'parse비중% (P+R)', (Trimmed $parseShare), ($parseShare | Measure-Object -Minimum).Minimum, ($parseShare | Measure-Object -Maximum).Maximum)
    Write-Output ("{0,-13} {1,10:N1}   min~max {2:N1} ~ {3:N1}" -f 'parse비중% (+pr)', (Trimmed $parseShareP), ($parseShareP | Measure-Object -Minimum).Minimum, ($parseShareP | Measure-Object -Maximum).Maximum)
    Write-Output ("{0,-13} {1,10:N2}   min~max {2:N2} ~ {3:N2}" -f '프레임당render ms', (Trimmed $perFrame), ($perFrame | Measure-Object -Minimum).Minimum, ($perFrame | Measure-Object -Maximum).Maximum)
    Write-Output ("{0,-13} {1,10:N2}   min~max {2:N2} ~ {3:N2}" -f '호출당shape us', (Trimmed $perShape), ($perShape | Measure-Object -Minimum).Minimum, ($perShape | Measure-Object -Maximum).Maximum)
    Write-Output ("shape calls {0}~{1} · miss {2}~{3}" -f `
        ($g.shape_calls | Measure-Object -Minimum).Minimum, ($g.shape_calls | Measure-Object -Maximum).Maximum, `
        ($g.miss | Measure-Object -Minimum).Minimum, ($g.miss | Measure-Object -Maximum).Maximum)
    Write-Output ("그린 프레임 {0}~{1} · skip {2}~{3} / onrender {4}~{5} · yields {6}~{7}" -f `
        ($g.render_calls | Measure-Object -Minimum).Minimum, ($g.render_calls | Measure-Object -Maximum).Maximum, `
        ($g.skip | Measure-Object -Minimum).Minimum, ($g.skip | Measure-Object -Maximum).Maximum, `
        ($g.onrender_calls | Measure-Object -Minimum).Minimum, ($g.onrender_calls | Measure-Object -Maximum).Maximum, `
        ($g.yields | Measure-Object -Minimum).Minimum, ($g.yields | Measure-Object -Maximum).Maximum)
    Write-Output ("소화 바이트 {0} · 손실 {1}" -f (($g.drain_bytes | Select-Object -Unique) -join ','), (($g.lost_bytes | Select-Object -Unique) -join ','))
    if ($lost.Count -gt 0) { Write-Output "  (손실은 #397 참고 — Windows 는 고정 16 byte 가 남아요. 그보다 크면 부분 파싱이에요)" }
}

Write-Output ""
Write-Output "raw=$rawPath"
Write-Output "csv=$csvPath"
Write-Output "##### 끝 #####"
