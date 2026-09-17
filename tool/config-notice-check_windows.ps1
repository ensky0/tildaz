# #655 — config 가 망가져도 **뜨는지**, 그리고 무엇을 고쳤다고 알리는지를 자동 검증한다.
# Windows 몫 (Linux · macOS 는 `tool/config-notice-check.sh` — 회차 이름과 판정이 같다).
#
# ```powershell
# tool\config-notice-check_windows.ps1                    # 전체
# tool\config-notice-check_windows.ps1 -Cases order,clamp # 고른 회차만
# tool\config-notice-check_windows.ps1 -List              # 회차 목록 + 눈으로 볼 것
# tool\config-notice-check_windows.ps1 -Bin C:\path\tildaz.exe
# ```
#
# 판정 줄은 `RESULT <회차>: PASS|FAIL …` 로 시작한다. 하나라도 FAIL 이면 exit 1.
#
# **사용자 파일을 건드리지 않는다.** Windows 는 config · 로그가 모두 `%APPDATA%\tildaz`
# 아래라 (`paths.configDir` · `logDir`) `APPDATA` 하나만 작업 디렉터리로 돌리면 격리된다.
# instance 9 를 쓰는 것도 같은 이유다 — 격리가 어디선가 새더라도 평소 쓰는 0 번과 겹치지
# 않는다.
#
# **기본 config 를 스크립트가 적지 않는다.** 빈 디렉터리에서 앱을 한 번 띄워 *앱이*
# 만들게 하고 그것을 망가뜨린다. 손으로 적으면 스키마가 넓어진 날 (이 이슈가 다루는 바로
# 그 일이다) 검증이 조용히 헛돈다.
#
# 회차는 앱을 **평소처럼 띄웠다 내린다.** `-e` 로 대신할 수 없다 — 측정 인스턴스는 config
# 파일을 만들지 않고 로그도 `tildaz_stress.log` 로 간다. 안내 다이얼로그가 뜨지만 곧
# 죽이므로 막히지 않는다. 예외는 `quiet` 회차 하나로, `-e` 가 **다이얼로그를 띄우지
# 않는다**는 것 자체를 잰다.
#
# 다이얼로그의 *생김새* (여백 · 스크롤 · 버튼 동작) 는 로그로 못 재니 `-List` 의
# "눈으로 볼 것" 을 따로 둔다.

param(
    [string[]]$Cases,
    [string]$Bin,
    [switch]$List
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $Bin) { $Bin = Join-Path $root 'zig-out\bin\tildaz.exe' }
$work = if ($env:TZCN_WORK) { $env:TZCN_WORK } else { Join-Path $env:TEMP 'tildaz-config-notice' }
$idx = 9
$script:failCount = 0

$allCases = @('boots','order','clamp','first-wins','drop-one','unknown','font-missing','quiet','clean','hotkey','truncate')

function Show-Usage {
    Write-Host "회차: $($allCases -join ' ')"
    Write-Host ''
    Write-Host '눈으로 볼 것 (로그로는 못 잰다 — 다이얼로그를 띄워서 본다):'
    Write-Host '  · 목록이 길 때 스크롤러가 나오고 창이 화면을 덮지 않는다'
    Write-Host '  · 제목 · 본문이 창 가장자리에 붙지 않는다 (좌우 · 위 여백)'
    Write-Host '  · 커스텀 창이 뜬다 — MessageBoxW 로 떨어지면 Open Config 버튼 자체가 없다'
    Write-Host '    (MB_OKCANCEL 의 글자는 OS 가 정해서 바꿀 수 없다)'
    Write-Host '  · Open Config 를 누르면 창이 남은 채 편집기가 뜨고, 편집기가 터미널 앞에 온다'
    Write-Host '  · 확인 · Esc · 창 닫기로는 편집기가 뜨지 않는다 (로그의 notice action 줄로도 확인)'
    Write-Host '  · 창을 내렸다 올려도 다시 뜨지 않는다'
}

function Write-Result([string]$name, [string]$verdict, [string]$note) {
    Write-Host "RESULT ${name}: $verdict $note"
    if ($verdict -eq 'FAIL') { $script:failCount++ }
}

function Reset-Env {
    $run = Join-Path $work 'run'
    if (Test-Path $run) { Remove-Item -Recurse -Force $run }
    New-Item -ItemType Directory -Force -Path $run | Out-Null
}

function Get-Cfg([int]$i) { Join-Path $work "run\tildaz\config_$i.toml" }
function Get-Log([string]$i) { Join-Path $work "run\tildaz\tildaz_$i.log" }

# `Start-Process -Environment` 는 PowerShell 7.4+ 라 쓰지 않는다 — Windows 에 기본으로
# 깔린 5.1 에서도 돌아야 한다. 자식이 물려받도록 `$env:APPDATA` 를 잠시 돌린다.
function Use-IsolatedAppData([scriptblock]$Body) {
    $saved = $env:APPDATA
    $env:APPDATA = Join-Path $work 'run'
    try { & $Body } finally { $env:APPDATA = $saved }
}

# 평소처럼 띄웠다 내린다. `config loaded` 가 찍힐 때까지 기다린다.
function Invoke-App([int]$i, [int]$WaitSeconds = 8) {
    Use-IsolatedAppData {
        Start-Process -FilePath $Bin -ArgumentList '--instance', "$i" -PassThru -WindowStyle Hidden | Out-Null
    }
    $log = Get-Log $i
    for ($n = 0; $n -lt $WaitSeconds * 4; $n++) {
        if ((Test-Path $log) -and (Select-String -Path $log -Pattern 'config loaded' -Quiet)) { break }
        Start-Sleep -Milliseconds 250
    }
    Start-Sleep -Milliseconds 500
    Get-Process -Name tildaz -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
}

# `-e` 로 돈다 — 다이얼로그가 뜨지 않는 경로 그 자체를 재는 회차에서만 쓴다.
#
# **`-e` 의 값은 따옴표로 감싸야 한다.** `Start-Process -ArgumentList` 는 배열 원소를 공백으로
# 이어 붙일 뿐 공백이 있는 원소를 감싸 주지 않아서, 그냥 넘기면 앱이 `-e cmd.exe /c exit` 로
# 읽고 `unknown option "/c"` (exit 2) 로 거부한다 — 로그 파일 자체가 생기지 않아 "앱이 조용하다"
# 가 아니라 "앱이 뜨지도 않았다" 가 된다. 레포의 다른 Windows 도구 (`key-bytes-check` ·
# `search-bar-check` · `link-click-check` · `render-ab-shot`) 가 전부 이 형태다.
function Invoke-AppQuiet([int]$i) {
    Use-IsolatedAppData {
        Start-Process -FilePath $Bin -ArgumentList '--instance', "$i", '-e', "`"cmd.exe /c exit`"" `
            -Wait -WindowStyle Hidden | Out-Null
    }
}

function New-Base([int]$i) {
    Invoke-App $i
    Test-Path (Get-Cfg $i)
}

# 로그에서 `[config]` 안내 줄 (들여쓴 목록 항목) 만 뽑는다.
function Get-NoticeLines([string]$i = "$idx") {
    $log = Get-Log $i
    if (-not (Test-Path $log)) { return @() }
    Get-Content $log | ForEach-Object {
        if ($_ -match '\[config\]   (.*)$') { $Matches[1] }
    }
}

# 네 갈래를 한 파일에 모두 넣는다. 반환: "첫액션 둘째액션".
function Set-BrokenConfig {
    $p = Get-Cfg $idx
    $out = & python -c @"
import sys, re
p = r'''$p'''
s = open(p, encoding='utf-8').read()
i, j = s.index('\n[input]\n'), s.index('\n[keys]\n')
s = s[:i] + s[j:]
s = re.sub(r'^auto_start\s*=.*$', 'auto_start = \"yes\"', s, count=1, flags=re.M)
s = re.sub(r'^width_percent\s*=.*$', 'width_percent = 1000.0', s, count=1, flags=re.M)
s = re.sub(r'^theme\s*=.*$', 'theme = \"Nonesuch\"', s, count=1, flags=re.M)
first_table = s.index('\n[')
s = s[:first_table] + '\nbogus_key = 1\n' + s[first_table:]
body = s[s.index('\n[keys]\n'):]
m = re.search(r'^(\w+)\s*=\s*\[([^\]]*)\]', body, flags=re.M)
first_action, first_keys = m.group(1), m.group(2)
s = re.sub(r'^(\w+)(\s*=\s*\[)([^\]]*)(\])',
           lambda mm: mm.group(0) if mm.group(1) != first_action
           else f'{mm.group(1)}{mm.group(2)}{mm.group(3)}, \"ctrl+shift+nosuchkey\"{mm.group(4)}',
           s, flags=re.M)
actions = re.findall(r'^(\w+)\s*=\s*\[', s[s.index('\n[keys]\n'):], flags=re.M)
second = actions[1]
first_key = first_keys.split(',')[0].strip()
s = re.sub(rf'^({second})(\s*=\s*\[)([^\]]*)(\])',
           lambda mm: f'{mm.group(1)}{mm.group(2)}{mm.group(3)}, {first_key}{mm.group(4)}',
           s, count=1, flags=re.M)
s += '\n[nosuch_section]\nfoo = 1\nbar = 2\n'
open(p, 'w', encoding='utf-8').write(s)
print(first_action, second)
"@
    return $out.Trim()
}

function Case-boots {
    Reset-Env
    if (-not (New-Base $idx)) { Write-Result boots FAIL '기본 config 를 만들지 못했다'; return }
    Set-BrokenConfig | Out-Null
    Remove-Item (Get-Log $idx) -ErrorAction SilentlyContinue
    Invoke-App $idx
    $log = Get-Log $idx
    if (-not ((Test-Path $log) -and (Select-String -Path $log -Pattern 'config loaded' -Quiet))) {
        Write-Result boots FAIL '뜨지 않았다 — 이 이슈가 고치려는 바로 그 증상이다'; return
    }
    $m = Select-String -Path $log -Pattern 'notice shown: (\d+) item' | Select-Object -First 1
    if ($m -and [int]$m.Matches[0].Groups[1].Value -ge 8) {
        Write-Result boots PASS "떴고 안내 $($m.Matches[0].Groups[1].Value) 줄"
    } else {
        Write-Result boots FAIL '떴지만 안내가 비었거나 너무 적다'
    }
}

function Case-order {
    Reset-Env
    if (-not (New-Base $idx)) { Write-Result order FAIL '준비 실패'; return }
    $p = Get-Cfg $idx
    & python -c "import sys; p=r'''$p'''; s=open(p,encoding='utf-8').read(); i=s.index('\n[keys]\n'); open(p,'w',encoding='utf-8').write(s[:i]+'\n[keys]\n')"
    Remove-Item (Get-Log $idx) -ErrorAction SilentlyContinue
    Invoke-App $idx
    # 로그를 먼저 떠 둔다 — 아래에서 환경을 지우면 로그도 함께 사라진다.
    $saved = Join-Path $work 'order.log'
    Copy-Item (Get-Log $idx) $saved -Force -ErrorAction SilentlyContinue
    $base = Join-Path $work 'order-base.toml'
    Reset-Env
    if (New-Base $idx) { Copy-Item (Get-Cfg $idx) $base -Force }
    & python -c @"
import sys, re
base, log = r'''$base''', r'''$saved'''
s = open(base, encoding='utf-8').read()
body = s[s.index('\n[keys]\n') + len('\n[keys]\n'):]
want = [m.group(1) for m in re.finditer(r'^(\w+)\s*=', body, flags=re.M)]
got = [m.group(1) for m in re.finditer(r'keys\.(\w+) -- missing', open(log, encoding='utf-8').read())]
if not want or not got: sys.exit(1)
common = [k for k in want if k in got]
sys.exit(0 if got[:len(common)] == common else 1)
"@
    if ($LASTEXITCODE -eq 0) { Write-Result order PASS '안내가 파일 차례대로다' }
    else { Write-Result order FAIL '안내 차례가 파일과 다르다 (해시 순서로 나오면 45 줄을 대조할 수 없다)' }
}

function Case-clamp {
    Reset-Env
    if (-not (New-Base $idx)) { Write-Result clamp FAIL '준비 실패'; return }
    Set-BrokenConfig | Out-Null
    Remove-Item (Get-Log $idx) -ErrorAction SilentlyContinue
    Invoke-App $idx
    # **기본값으로 되돌리지 않는다** — 경계값이어야 한다 (SPEC §7.3).
    if ((Get-NoticeLines) -match 'window\.width_percent -- out of range, limited to 100') {
        Write-Result clamp PASS '1000 → 100 으로 clamp'
    } else {
        Write-Result clamp FAIL 'clamp 줄이 없다 (기본값으로 되돌렸다면 그것도 틀렸다)'
    }
}

function Case-first-wins {
    Reset-Env
    if (-not (New-Base $idx)) { Write-Result first-wins FAIL '준비 실패'; return }
    $pair = (Set-BrokenConfig) -split '\s+'
    Remove-Item (Get-Log $idx) -ErrorAction SilentlyContinue
    Invoke-App $idx
    # 먼저 나온 액션이 그 조합을 지키고, 뒤엣것이 버려진다.
    if ((Get-NoticeLines) -match "keys\.$($pair[1]) -- .* is already used by $($pair[0]), dropped") {
        Write-Result first-wins PASS "$($pair[0]) 가 이기고 $($pair[1]) 가 그 키를 잃었다"
    } else {
        Write-Result first-wins FAIL '충돌 안내가 없거나 이긴 쪽이 다르다'
    }
}

function Case-drop-one {
    Reset-Env
    if (-not (New-Base $idx)) { Write-Result drop-one FAIL '준비 실패'; return }
    $pair = (Set-BrokenConfig) -split '\s+'
    Remove-Item (Get-Log $idx) -ErrorAction SilentlyContinue
    Invoke-App $idx
    # **나쁜 항목만** 버린다 — 같은 액션의 나머지 키는 살아야 한다.
    if ((Get-NoticeLines) -match "keys\.$($pair[0]) -- dropped ""ctrl\+shift\+nosuchkey"" \(unknown key\)") {
        Write-Result drop-one PASS '읽을 수 없는 조합 하나만 버렸다'
    } else {
        Write-Result drop-one FAIL '항목 단위로 버리지 않았다'
    }
}

function Case-unknown {
    Reset-Env
    if (-not (New-Base $idx)) { Write-Result unknown FAIL '준비 실패'; return }
    Set-BrokenConfig | Out-Null
    Remove-Item (Get-Log $idx) -ErrorAction SilentlyContinue
    Invoke-App $idx
    $lines = Get-NoticeLines
    # 모르는 **섹션** 은 안의 키를 나열하지 않고 테이블 하나로만 알린다.
    $hasSection = $lines -contains 'nosuch_section'
    $hasKey = $lines -contains 'bogus_key'
    $leaked = ($lines -match 'nosuch_section\.').Count -gt 0
    if ($hasSection -and $hasKey -and -not $leaked) {
        Write-Result unknown PASS '모르는 키 · 섹션을 한 줄씩 (섹션 내부는 안 편다)'
    } else {
        Write-Result unknown FAIL '모르는 키 · 섹션 안내가 틀렸다'
    }
}

function Case-font-missing {
    Reset-Env
    if (-not (New-Base $idx)) { Write-Result font-missing FAIL '준비 실패'; return }
    $p = Get-Cfg $idx
    & python -c "import sys; p=r'''$p'''; s=open(p,encoding='utf-8').read(); i,j=s.index('\n[font]\n'),s.index('\n[input]\n'); open(p,'w',encoding='utf-8').write(s[:i]+s[j:])"
    Remove-Item (Get-Log $idx) -ErrorAction SilentlyContinue
    Invoke-App $idx
    # 예전 코드는 `root.table.get("font").?` 로 **그 자리에서 패닉**했다.
    if (Select-String -Path (Get-Log $idx) -Pattern 'config loaded' -Quiet -ErrorAction SilentlyContinue) {
        Write-Result font-missing PASS '[font] 없이도 떴다'
    } else {
        Write-Result font-missing FAIL '[font] 없는 config 에서 죽었다 (패닉 의심)'
    }
}

function Case-quiet {
    Reset-Env
    if (-not (New-Base $idx)) { Write-Result quiet FAIL '준비 실패'; return }
    Set-BrokenConfig | Out-Null
    Remove-Item (Get-Log 'stress') -ErrorAction SilentlyContinue
    Invoke-AppQuiet $idx
    $log = Get-Log 'stress'
    # 이 회차가 끝까지 돌아 **여기 도달한 것 자체**가 모달이 안 떴다는 증거다.
    $shown = (Test-Path $log) -and (Select-String -Path $log -Pattern 'notice shown' -Quiet)
    $acted = (Test-Path $log) -and (Select-String -Path $log -Pattern 'notice (action|dismissed)' -Quiet)
    if ($shown -and -not $acted) {
        Write-Result quiet PASS '로그에만 남고 다이얼로그가 뜨지 않았다'
    } else {
        Write-Result quiet FAIL '-e 인데 로그가 비었거나 다이얼로그 상호작용이 찍혔다'
    }
}

function Case-clean {
    Reset-Env
    if (-not (New-Base $idx)) { Write-Result clean FAIL '준비 실패'; return }
    Remove-Item (Get-Log $idx) -ErrorAction SilentlyContinue
    Invoke-App $idx
    # **이 회차가 가장 중요하다.** 여기가 깨지면 아무 잘못 없는 사용자가 뜰 때마다
    # 다이얼로그를 본다 — 대조 기준 (`schemaReferenceToml`) 과 생성기
    # (`defaultConfigToml`) 가 갈렸다는 뜻이다.
    $n = (Get-NoticeLines).Count
    if ($n -eq 0) { Write-Result clean PASS '정상 config 는 완전히 무음이다' }
    else { Write-Result clean FAIL "정상 config 가 안내 $n 줄을 만들었다" }
}

function Case-hotkey {
    Reset-Env
    # 낮은 index 의 config 를 먼저 만들어 두고, 9 번이 **같은 키**를 쓰게 한다.
    if (-not (New-Base 0)) { Write-Result hotkey FAIL '준비 실패'; return }
    if (-not (New-Base $idx)) { Write-Result hotkey FAIL '준비 실패'; return }
    $taken = (Select-String -Path (Get-Cfg 0) -Pattern '^hotkey\s*=\s*"(.*)"').Matches[0].Groups[1].Value
    $p = Get-Cfg $idx
    # **한 줄 `-c` 에 `\"` 를 쓰지 않는다.** PowerShell 5.1 이 네이티브 인자로 넘기며 그
    # 따옴표를 인자 경계로 다시 읽어 python 코드가 잘린다 (`unterminated string literal`).
    # 이 파일의 다른 자리처럼 here-string 으로 넘기고, 큰따옴표는 `chr(34)` 로 만든다.
    & python -c @"
import re
p, taken = r'''$p''', r'''$taken'''
q = chr(34)
s = open(p, encoding='utf-8').read()
open(p, 'w', encoding='utf-8').write(
    re.sub(r'^hotkey\s*=.*$', 'hotkey = ' + q + taken + q, s, count=1, flags=re.M))
"@
    Remove-Item (Get-Log $idx) -ErrorAction SilentlyContinue
    Invoke-App $idx
    # 죽지 않고 파생 기본값 F{N+1} 로 갈아탄다 (SPEC §7.3 의 유일한 예외 — 갈아탈
    # 자리까지 없을 때만 종료한다).
    $booted = Select-String -Path (Get-Log $idx) -Pattern 'config loaded' -Quiet -ErrorAction SilentlyContinue
    $line = (Get-NoticeLines) | Where-Object { $_ -match 'hotkey -- already used by instance 0, using ' }
    if ($booted -and $line) { Write-Result hotkey PASS "중복을 감지하고 갈아탔다 — $line" }
    else { Write-Result hotkey FAIL '중복에서 죽었거나 갈아탔다는 안내가 없다' }
}

function Case-truncate {
    Reset-Env
    if (-not (New-Base $idx)) { Write-Result truncate FAIL '준비 실패'; return }
    # **config 파일은 64 KiB 를 넘기면 안 된다** (`Config.load` 의 `allocRemaining` 상한).
    # 넘기면 파일이 통째로 거부돼 `load failed — running with defaults` 로 빠지고, 이
    # 회차가 재려던 잘림은 일어나지 않는다. 150 × 200 자 ≈ 30 KiB 로 상한 안에 든다.
    $p = Get-Cfg $idx
    & python -c "p=r'''$p'''; f=open(p,'a',encoding='utf-8'); f.write('\n'); [f.write('k'*200+str(i)+' = 1\n') for i in range(150)]; f.close()"
    Remove-Item (Get-Log $idx) -ErrorAction SilentlyContinue
    Invoke-App $idx
    # 버퍼가 넘쳐도 **몇 개였는지는 정확**하고, 로그에는 전부 남는다.
    if (Select-String -Path (Get-Log $idx) -Pattern 'notice shown: \d+ item\(s\) \(truncated\)' -Quiet -ErrorAction SilentlyContinue) {
        Write-Result truncate PASS '넘친 것을 잘렸다고 표시했다'
    } else {
        Write-Result truncate FAIL '잘림 표시가 없다 — 사용자가 목록이 전부인 줄 안다'
    }
}

if ($List) { Show-Usage; exit 0 }
if (-not (Test-Path $Bin)) { Write-Host "바이너리가 없다: $Bin (-Bin 으로 지정하거나 zig build 먼저)"; exit 2 }
if (-not $Cases) { $Cases = $allCases }

New-Item -ItemType Directory -Force -Path $work | Out-Null
Write-Host "bin=$Bin"
Write-Host "work=$work"
foreach ($c in $Cases) {
    if ($allCases -notcontains $c) { Write-Host "모르는 회차: $c"; Show-Usage; exit 2 }
    & "Case-$c"
}

Write-Host ''
if ($script:failCount -eq 0) {
    Write-Host '모든 회차 PASS. 위 ''눈으로 볼 것'' 은 따로 확인한다 (-List).'
    exit 0
} else {
    Write-Host "FAIL $($script:failCount) 건."
    exit 1
}
