# 실제 앱의 pane 마다 하나씩 뜨는 **producer 러너** (Windows · `measure-repeat.sh --panes N` 이 `-e` 로 넘긴다).
#
#   tildaz.exe --instance 9 -e "powershell -NoProfile -ExecutionPolicy Bypass -File pane-runner.ps1 <barrier> <stress.exe> <workload> <bytes>" -size 120x40
#
# **왜 러너인가** — `frame --panes N` 하네스는 내부 TabGroup 에 producer 를 만들고 파일 barrier 로 함께 시작하지만,
# 실제 앱은 pane 을 만들 때 producer 에 `TILDAZ_STRESS_START_BARRIER` · `PANE_ID` 를 넣지 않는다. 그래서 `-e` 에
# producer 를 직접 넘기면 **첫 pane 의 폭포가 분할이 끝나기 전에 흐른다.** 이 러너는 barrier 파일이 생길 때까지
# 50 ms 폴링으로 기다린 뒤 producer 를 띄운다 — 새 pane 의 셸도 같은 `-e` 명령이라 pane 마다 러너 하나가 뜨고,
# `measure-repeat.sh` 가 분할을 끝내고 파일을 만들면 N 개가 함께 (≤ 50 ms + 프로세스 시작 지터) 시작한다.
#
# producer 모드는 환경변수 둘 (`TILDAZ_STRESS_WORKLOAD` · `TILDAZ_STRESS_BYTES`) 로만 켜지고 인자가 있으면 독립 측정
# 모드가 되어 앱 PTY 로 폭포가 흐르지 않는다 (README "producer 는 환경변수 두 개로만 켜져요"). 그래서 여기서 환경변수를
# 심고 인자 없이 실행한다. producer 가 끝나면 러너도 끝나 그 pane 이 닫히고, 마지막 pane 이 닫히면 앱이 종료 덤프를 남긴다.
#
# ⚠️ UTF-8 BOM 으로 저장한다 (Windows PowerShell 5.1).
param(
    [Parameter(Mandatory)][string]$Barrier,
    [Parameter(Mandatory)][string]$Stress,
    [string]$Workload = "plain",
    [string]$Bytes = "67108864",
    # barrier 를 이만큼 기다려도 안 생기면 그냥 시작한다 — 분할이 실패한 회차가 조용히 걸려 있지 않게.
    [int]$TimeoutSec = 20
)
$sw = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path -LiteralPath $Barrier) -and $sw.Elapsed.TotalSeconds -lt $TimeoutSec) { Start-Sleep -Milliseconds 50 }
$env:TILDAZ_STRESS_WORKLOAD = $Workload
$env:TILDAZ_STRESS_BYTES = $Bytes
& $Stress
exit $LASTEXITCODE
