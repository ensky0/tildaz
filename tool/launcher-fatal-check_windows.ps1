# Windows 에서 **launcher 단독 실패** 가 다이얼로그로 알려지고 크래시가 없는지 본다 (#577 의 Windows 몫 · #583 A2).
#
# ```powershell
# tool\launcher-fatal-check_windows.ps1                          # zig-out\bin\tildaz.exe
# tool\launcher-fatal-check_windows.ps1 -Bin C:\path\tildaz.exe
# ```
#
# 무엇을 재나 — `showFatalRunError(rt, …)` 가 **launcher 경로**에서 실행되는 자리다. #577 이 서명을 바꾸기 전에는
# 그 함수가 `g_rt` 를 읽었는데 그 값은 `run()` 안에서만 심어지고 launcher 실패 경로는 `run()` 을 거치지 않아
# **`undefined` 를 읽고 있었다.** macOS 회차 (2026-09-02) 는 worker 가 다이얼로그를 띄우는 경로여서 이 자리를 확정하지
# 못했다 — worker 가 스스로 안내를 띄우면 launcher 는 조용히 물러나도록 설계돼 있기 때문이다.
#
# launcher 단독 실패를 만드는 법 — **격리한 `APPDATA` 의 config 폴더에서 목록 보기 (`RD`) 를 막고** launcher (인자 없는
# `tildaz.exe`) 를 띄운다. `runLauncher` 는 spawn 전에 `instances.listConfigIndices` 로 그 폴더를 열어 훑는데, 여는 오류는
# 그대로 전파된다. 그래서 worker 는 뜨지도 않고 launcher 가 `main.zig` 의 `catch |err| host.showFatalRunError(rt, …, err)`
# 로 간다 — 기대 다이얼로그는 `TildaZ Error` / `TildaZ failed to start.  Error: AccessDenied`. 그 실패는
# `autostart.enable/disable` **앞**이라 자동 시작 설정을 건드리지 않는다 (launcher_lock · gate 는 defer 로 풀린다).
#
# 실패시키는 법의 이력 (#758) — 처음에는 **문법이 깨진** `config_9.toml` 이었고, 그다음 **읽기를 막은** `config_9.toml`
# 이었다. #758 이 둘 다 그 번호의 기본값으로 읽게 바꿔서 (`ed9a08a` — config 하나 때문에 다른 instance 까지 못 뜨지 않게)
# launcher 가 더는 실패하지 않는다. 그래서 config **파일**이 아니라 config **폴더**를 막는다. 2026-10-17 Windows 실기에서
# 읽기를 막은 config 로 돌린 이 도구가 worker 0 · 9 를 띄우고 `실패 있음` 으로 끝난 것을 보고 바꿨다.
#
# **격리 폴더에서만 돈다** — `APPDATA` · `LOCALAPPDATA` 를 `%TEMP%` 아래로 돌린다. 사용자의 config · lock · 로그를 건드리지
# 않는다 (예전에는 실제 `%APPDATA%\tildaz-dev` 에 `config_9.toml` 을 만들었다). dev 판 (`tildaz-dev`) · 릴리즈 판
# (`tildaz`) 어느 쪽이든 그 이름의 폴더를 둘 다 만들어 막는다.
#
# ⚠️ **이 방법으로는 `[fatal]` 로그 줄이 남지 않는다.** Windows 는 로그 폴더가 config 폴더와 같아서 (`paths.logDir` ·
# `configDir` 둘 다 `%APPDATA%\<앱>`), 로그 경로를 준비하는 `paths.logPath` 의 `ensureDir` 가 같은 이유로 실패해 로그를
# 조용히 건너뛴다. 판정은 다이얼로그와 종료 코드로만 한다.
#
# 판정 — ① launcher 프로세스의 앱 다이얼로그 창이 뜬다 ② 제목이 `TildaZ Error` 다 ③ 닫으면 (`WM_CLOSE`) 프로세스가 끝난다
# (다이얼로그 없이 사라졌으면 크래시 의심) ④ worker 가 뜨지 않는다 (떴으면 이 실패를 만드는 법이 또 깨진 것이다). 본문
# 문구는 캡처로 본다 — 창이 본문을 직접 그려 자식 컨트롤로는 안 보인다.
#
# 곁가지 — 이 문구가 거친 것 (`UnexpectedToken` 만 · 줄 · 열 없음) 은 #583 B7 이고 이 검증의 범위 밖이다.
#
# 실기라서 시작 전에 알린다 — 다이얼로그가 한 번 뜨고 스크립트가 닫는다. 끝나면 격리 폴더의 차단을 풀고 지운다.
#
# ⚠️ 이 파일은 UTF-8 **BOM** 으로 저장한다 (Windows PowerShell 5.1 이 BOM 없는 `.ps1` 을 cp949 로 읽는다).

[CmdletBinding()]
param(
    [string]$Bin = "zig-out\bin\tildaz.exe"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Text;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class TzFatal {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  public static void MakeDpiAware() { try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch {} }
  public static string ClassOf(IntPtr h) { var s = new StringBuilder(256); GetClassNameW(h, s, 256); return s.ToString(); }
  public static string TextOf(IntPtr h) { var s = new StringBuilder(4096); GetWindowTextW(h, s, 4096); return s.ToString(); }
  // pid 의 보이는 최상위 창 — 크기 조건 없음 (MessageBox 는 작다).
  public static IntPtr FindWindowOfPid(uint pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid || !IsWindowVisible(h)) return true;
      RECT r; if (!GetWindowRect(h, out r)) return true;
      if (r.R - r.L < 16 || r.B - r.T < 16) return true;
      found = h; return false;
    }, IntPtr.Zero);
    return found;
  }
  // 자식 컨트롤의 텍스트를 모두 이어 붙인다 — MessageBox 본문은 Static 컨트롤이다.
  public static string ChildTexts(IntPtr h) {
    var sb = new StringBuilder();
    EnumChildWindows(h, (c, l) => { var t = TextOf(c); if (t.Length > 0) { sb.Append('[').Append(ClassOf(c)).Append("] ").Append(t.Replace("\r\n", "⏎").Replace("\n", "⏎")).Append("  "); } return true; }, IntPtr.Zero);
    return sb.ToString();
  }
  public static void Capture(IntPtr h, string png) {
    RECT r; GetWindowRect(h, out r);
    using (var bmp = new Bitmap(r.R - r.L, r.B - r.T, PixelFormat.Format32bppArgb)) {
      using (var g = Graphics.FromImage(bmp)) { IntPtr hdc = g.GetHdc(); PrintWindow(h, hdc, 2); g.ReleaseHdc(hdc); }
      bmp.Save(png, ImageFormat.Png);
    }
  }
}
"@
[TzFatal]::MakeDpiAware()

if (-not (Test-Path $Bin)) { throw "바이너리 없음: $Bin" }
$Out = Join-Path $env:TEMP "tildaz-launcher-fatal"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$iso = Join-Path $env:TEMP "tildaz-launcher-fatal-iso"
if (Test-Path $iso) { throw "격리 폴더가 이미 있다 — 앞 회차의 잔재일 수 있어 지우고 다시 돌린다: $iso" }
$dirs = @("tildaz", "tildaz-dev") | ForEach-Object { Join-Path $iso $_ }     # 릴리즈 · dev 판의 config 폴더 이름
foreach ($d in $dirs) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
New-Item -ItemType Directory -Force -Path (Join-Path $iso "local") | Out-Null
$me = "$env:USERDOMAIN\$env:USERNAME"
foreach ($d in $dirs) {
    & icacls $d /deny "${me}:(RD)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls 로 목록 보기를 막지 못했다 (exit=$LASTEXITCODE): $d" }
}
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runBefore = ((Get-ItemProperty $runKey -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object Name -like '*ildaz*' | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' ; '
$ok = $true
$t0 = Get-Date
try {
    $env:APPDATA = $iso; $env:LOCALAPPDATA = Join-Path $iso "local"     # 이 프로세스가 띄우는 launcher 에만 간다
    $p = Start-Process -FilePath (Resolve-Path $Bin) -PassThru      # 인자 없음 = launcher
    $h = [IntPtr]::Zero
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($h -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 15000) {
        Start-Sleep -Milliseconds 100
        if ($p.HasExited) { break }
        $h = [TzFatal]::FindWindowOfPid([uint32]$p.Id)
    }
    if ($h -eq [IntPtr]::Zero) {
        if ($p.HasExited) { "❌ 다이얼로그 없이 프로세스가 끝났다 (exit=$($p.ExitCode)) — 크래시 또는 조용한 실패" }
        else { "❌ 15 초 안에 창이 뜨지 않았다"; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        $ok = $false
    } else {
        $cls = [TzFatal]::ClassOf($h); $title = [TzFatal]::TextOf($h); $body = [TzFatal]::ChildTexts($h)
        "다이얼로그 뜸 ({0:N0} ms) · class={1} · title=[{2}]" -f $sw.ElapsedMilliseconds, $cls, $title
        "본문: $body"
        $png = Join-Path $Out "dialog.png"; [TzFatal]::Capture($h, $png); "캡처: $png"
        # 앱의 error 다이얼로그는 `dialog/windows.zig` 의 자체 창 (`TildaZScrollableDialogWindow` — 본문을 직접 그려 자식
        # 컨트롤로는 제목 Static 과 OK Button 만 보인다) 이거나 짧은 경로의 MessageBox (`#32770`) 다. 본문 문구는 캡처로 본다.
        if ($cls -ne "#32770" -and $cls -ne "TildaZScrollableDialogWindow") { "❌ 앱 다이얼로그 창이 아니다 (class=$cls)"; $ok = $false }
        if ($title -ne "TildaZ Error") { "❌ 제목이 'TildaZ Error' 가 아니다"; $ok = $false }
        [void][TzFatal]::PostMessageW($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
        $sw2 = [Diagnostics.Stopwatch]::StartNew()
        while (-not $p.HasExited -and $sw2.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 100 }
        if ($p.HasExited) { "닫은 뒤 프로세스 종료 exit=$($p.ExitCode) ({0} ms)" -f $sw2.ElapsedMilliseconds }
        else { "❌ 다이얼로그를 닫았는데 프로세스가 남아 있다"; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; $ok = $false }
    }
} finally {
    # 이 회차가 띄운 worker — 떴다면 실패를 만드는 법이 또 깨진 것이다 (머리 주석의 이력).
    # 같은 실행 파일로 이 회차 뒤에 뜬 것만 본다 — 다른 세션의 TildaZ 를 잡아 내리지 않는다.
    $exe = (Resolve-Path $Bin).Path
    $workers = @(Get-CimInstance Win32_Process -Filter "Name like 'tildaz%'" | Where-Object { $_.CreationDate -ge $t0 -and $_.ExecutablePath -eq $exe -and $_.CommandLine -match '--instance' })
    foreach ($w in $workers) { "❌ worker 가 떴다 — pid=$($w.ProcessId) cmd=[$($w.CommandLine)]"; Stop-Process -Id $w.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($workers.Count -gt 0) { $ok = $false; Start-Sleep -Milliseconds 500 }
    foreach ($d in $dirs) { & icacls $d /remove:d $me | Out-Null }
    Remove-Item $iso -Recurse -Force -ErrorAction SilentlyContinue
    "격리 폴더 지움: $(-not (Test-Path $iso))"
}
$runAfter = ((Get-ItemProperty $runKey -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object Name -like '*ildaz*' | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' ; '
if ($runAfter -ne $runBefore) { "❌ 자동 시작 설정 (HKCU Run) 이 바뀌었다 — 전 [$runBefore] 후 [$runAfter]"; $ok = $false } else { "자동 시작 설정 그대로" }
if ($ok) { "결과: OK — launcher 단독 실패가 다이얼로그로 알려지고 크래시 없음" } else { "결과: 실패 있음" }
