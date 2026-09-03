# Windows 에서 **launcher 단독 실패** 가 다이얼로그로 알려지고 크래시가 없는지 본다 (#577 의 Windows 몫 · #583 A2).
#
# ```powershell
# dist\windows\launcher-fatal-check.ps1                          # zig-out\bin\tildaz.exe
# dist\windows\launcher-fatal-check.ps1 -Bin C:\path\tildaz.exe
# ```
#
# 무엇을 재나 — `showFatalRunError(rt, …)` 가 **launcher 경로**에서 실행되는 자리다. #577 이 서명을 바꾸기 전에는
# 그 함수가 `g_rt` 를 읽었는데 그 값은 `run()` 안에서만 심어지고 launcher 실패 경로는 `run()` 을 거치지 않아
# **`undefined` 를 읽고 있었다.** macOS 회차 (2026-09-02) 는 worker 가 다이얼로그를 띄우는 경로여서 이 자리를 확정하지
# 못했다 — worker 가 스스로 안내를 띄우면 launcher 는 조용히 물러나도록 설계돼 있기 때문이다.
#
# launcher 단독 실패를 만드는 법 — **TOML 문법이 깨진 `config_9.toml`** 을 두고 launcher (인자 없는 `tildaz.exe`) 를 띄운다.
# `runLauncher` 는 spawn 전에 모든 index 의 config 를 `instances.configAutoStart` 로 읽고 (auto_start 집계), 그 파서
# 오류는 **그대로 전파**된다 (#495 — `InvalidConfig` 로 뭉개면 원인이 안 보인다). 그래서 worker 는 뜨지도 않고 launcher 가
# `main.zig` 의 `catch |err| host.showFatalRunError(rt, …, err)` 로 간다 — 기대 다이얼로그는 `TildaZ Error` /
# `TildaZ failed to start.  Error: UnexpectedToken`. 그 실패는 `autostart.enable/disable` **앞**이라 사용자의 자동 시작 설정도,
# 떠 있는 instance 0 도 건드리지 않는다 (launcher_lock · gate 는 defer 로 풀린다).
#
# 판정 — ① 그 프로세스의 `#32770` (MessageBox) 창이 뜬다 ② 제목 · 본문이 위 문구다 ③ 닫으면 (`WM_CLOSE`) 프로세스가
# 끝난다 (다이얼로그 없이 사라졌으면 크래시 의심). 캡처는 PrintWindow 로 남긴다. 끝나면 `config_9.toml` 을 지운다 —
# 있던 파일이면 시작 자체를 거부한다 (사용자 설정을 덮지 않는다).
#
# 곁가지 — 이 문구가 거친 것 (`UnexpectedToken` 만 · 줄 · 열 없음) 은 #583 B7 이고 이 검증의 범위 밖이다.
#
# 실기라서 시작 전에 알린다 — 다이얼로그가 한 번 뜨고 스크립트가 닫는다. launcher 가 `tildaz_0.log` (사용자 instance 의 로그)
# 에 `[fatal]` 한 줄을 남긴다 — 진단 채널이라 그대로 둔다.
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
$c9 = Join-Path $env:APPDATA "tildaz\config_9.toml"
if (Test-Path $c9) { throw "config_9.toml 이 이미 있다 — 사용자 설정일 수 있어 덮지 않는다: $c9" }
$Out = Join-Path $env:TEMP "tildaz-launcher-fatal"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$log0 = Join-Path $env:APPDATA "tildaz\tildaz_0.log"
$logLinesBefore = if (Test-Path $log0) { (Get-Content $log0 -Encoding UTF8).Count } else { 0 }

# TOML 문법 오류 — `= =` 는 UnexpectedToken.
[IO.File]::WriteAllText($c9, "hotkey = = `"F9`"`n", (New-Object System.Text.UTF8Encoding $false))
$ok = $true
try {
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
        # 컨트롤로는 제목 Static 과 OK Button 만 보인다) 이거나 짧은 경로의 MessageBox (`#32770`) 다. 본문 문구는 캡처와
        # 로그 (`[fatal] run failed: <err>`) 로 확인한다.
        if ($cls -ne "#32770" -and $cls -ne "TildaZScrollableDialogWindow") { "❌ 앱 다이얼로그 창이 아니다 (class=$cls)"; $ok = $false }
        if ($title -ne "TildaZ Error") { "❌ 제목이 'TildaZ Error' 가 아니다"; $ok = $false }
        [void][TzFatal]::PostMessageW($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
        $sw2 = [Diagnostics.Stopwatch]::StartNew()
        while (-not $p.HasExited -and $sw2.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 100 }
        if ($p.HasExited) { "닫은 뒤 프로세스 종료 exit=$($p.ExitCode) ({0} ms)" -f $sw2.ElapsedMilliseconds }
        else { "❌ 다이얼로그를 닫았는데 프로세스가 남아 있다"; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; $ok = $false }
    }
} finally {
    Remove-Item $c9 -Force -ErrorAction SilentlyContinue
    "config_9.toml 지움: $(-not (Test-Path $c9))"
}
if (Test-Path $log0) {
    $new = Get-Content $log0 -Encoding UTF8 | Select-Object -Skip $logLinesBefore
    "tildaz_0.log 에 새로 남은 줄 ($($new.Count)):"
    $new | ForEach-Object { "  " + ($_ -replace '^\[[^\]]+\]\s*', '') }
}
if ($ok) { "결과: OK — launcher 단독 실패가 다이얼로그로 알려지고 크래시 없음" } else { "결과: 실패 있음" }
