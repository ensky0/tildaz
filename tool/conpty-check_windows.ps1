# 번들 ConPTY 를 바꾼 뒤 TildaZ 가 기대는 ConPTY 동작이 그대로인지 잰다 (#757).
#
# ```powershell
# powershell.exe -NoProfile -File tool\conpty-check_windows.ps1                       # zig-out\bin\tildaz.exe
# powershell.exe -NoProfile -File tool\conpty-check_windows.ps1 -Bin <판>\tildaz.exe  # _internal 도 그 옆에 있어야 한다
# powershell.exe -NoProfile -File tool\conpty-check_windows.ps1 -Wsl Debian             # WSL 셸 칸 (C5) 까지
# ```
#
# | id | 무엇 | 판정 |
# |---|---|---|
# | C1 | 창을 띄운 뒤 자식이 찍은 글자가 화면에 나오기까지 | 2 초 안. OpenConsole 이 DA1 응답을 3 초 기다리던 지연이 다시 생기면 3 초를 넘는다 (`pty.zig` 의 DA1 미리 응답) |
# | C2 | 자식이 시작 직후 3 초 동안 받은 입력 바이트 | 0 — 우리가 미리 쓴 DA1 응답 (`\x1b[?61c`) 이나 ConPTY 의 질문 응답이 셸에 새면 여기 잡힌다 |
# | C3 | 글자 크기를 두 번 바꿔 격자가 바뀐 뒤 3 초 동안 받은 입력 바이트 | 0 — 크기를 바꾼 뒤 커서 위치를 다시 묻는 ConPTY (1.25 #19535) 의 응답이 새면 여기 잡힌다 |
# | C4 | 자식이 출력 없이 끝난 뒤 앱이 끝나기까지 | 5 초 안 (#744 — 출력 EOF 가 와야 끝난다) |
# | C5 | (`-Wsl <배포판>`) WSL 셸이 글자를 찍고 끝나면 | 글자가 보이고 15 초 안에 앱이 끝난다 |
#
# - `-e` 로 띄워 config · hotkey 를 만들지 않는다. 크기는 `-size` 없이 띄운다 (고정 격자면 글자 크기 변경을 무시한다).
# - 자식은 PowerShell 이다. raw 입력 (`ENABLE_VIRTUAL_TERMINAL_INPUT`) 으로 받은 바이트를 hex 로 적는다.
# - 시작할 때 다른 TildaZ 가 떠 있으면 멈춘다. 끝나면 시작 때 앞에 있던 창을 다시 올린다.
#
# 실기라서 **시작 전에 알리고 동의를 받는다** — 창 1 회 · 약 20 초 · 합성 키 (글자 크기).
# ⚠️ 이 파일은 UTF-8 **BOM** 으로 저장한다.
param(
    [string]$Bin = "zig-out\bin\tildaz.exe",
    [string]$Out = (Join-Path $env:TEMP "tildaz-conpty-check"),
    # 주면 C5 — 그 WSL 배포판의 셸로 글자를 찍고 끝나는 자식을 띄운다 (`wsl -l -q` 의 이름).
    [string]$Wsl = ""
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class Cc {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] p, int cb);
  [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint c, uint t);
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Explicit, Size = 40)] public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; }
  public static IntPtr FindWindowOfPid(uint pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid || !IsWindowVisible(h)) return true;
      RECT r; if (!GetWindowRect(h, out r)) return true;
      if (r.R - r.L < 64 || r.B - r.T < 64) return true;
      found = h; return false;
    }, IntPtr.Zero);
    return found;
  }
  // 창 그림에서 가장 흔한 색 (배경) 이 아닌 픽셀 수.
  public static long Ink(IntPtr h) {
    RECT r; GetWindowRect(h, out r);
    using (var bmp = new Bitmap(r.R - r.L, r.B - r.T, PixelFormat.Format32bppArgb)) {
      using (var g = Graphics.FromImage(bmp)) { IntPtr dc = g.GetHdc(); PrintWindow(h, dc, 2); g.ReleaseHdc(dc); }
      var d = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
      try {
        var p = new int[bmp.Width * bmp.Height]; Marshal.Copy(d.Scan0, p, 0, p.Length);
        var count = new System.Collections.Generic.Dictionary<int, int>();
        foreach (var v in p) { int c; count.TryGetValue(v, out c); count[v] = c + 1; }
        int bg = 0, most = -1; foreach (var kv in count) if (kv.Value > most) { most = kv.Value; bg = kv.Key; }
        return p.Length - most;
      } finally { bmp.UnlockBits(d); }
    }
  }
  static INPUT Key(ushort vk, uint f) { var i = new INPUT(); i.type = 1; i.ki.wVk = vk; i.ki.wScan = (ushort)MapVirtualKeyW(vk, 0); i.ki.dwFlags = f; return i; }
  public static void Chord(ushort[] vks) {
    var a = new INPUT[vks.Length * 2]; int n = 0;
    foreach (var v in vks) a[n++] = Key(v, 0);
    for (int k = vks.Length - 1; k >= 0; k--) a[n++] = Key(vks[k], 2);
    SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
  }
}
'@
try { [void][Cc]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch {}

New-Item -ItemType Directory -Force -Path $Out | Out-Null
Get-ChildItem $Out -ErrorAction SilentlyContinue | Remove-Item -Force
$child = Join-Path $Out "child.ps1"
$childBody = @'
param([string]$Out)
$ErrorActionPreference = "Continue"
try {
Add-Type -Name CcChild -Namespace Cc -MemberDefinition @"
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(IntPtr h, uint m);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetNumberOfConsoleInputEvents(IntPtr h, out uint n);
[StructLayout(LayoutKind.Explicit, Size = 20)] public struct REC { [FieldOffset(0)] public ushort EventType; [FieldOffset(4)] public int bKeyDown; [FieldOffset(14)] public ushort UnicodeChar; }
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern bool ReadConsoleInputW(IntPtr h, [Out] REC[] b, uint n, out uint got);
// 큐의 레코드를 다 꺼내 키 누름의 글자만 돌려준다. 크기 바뀜 · 포커스 같은 이벤트는 버린다
// (ReadFile 은 그런 이벤트만 있을 때 글자를 기다리며 막힌다).
public static string Take(IntPtr h) {
  uint n; if (!GetNumberOfConsoleInputEvents(h, out n) || n == 0) return null;
  var b = new REC[n]; uint got; if (!ReadConsoleInputW(h, b, n, out got)) return null;
  var s = new System.Text.StringBuilder();
  for (int i = 0; i < got; i++) if (b[i].EventType == 1 && b[i].bKeyDown != 0 && b[i].UnicodeChar != 0) s.Append((char)b[i].UnicodeChar);
  return s.ToString();
}
"@
$h = [Cc.CcChild]::GetStdHandle(-10)
$mode = 0
[void][Cc.CcChild]::GetConsoleMode($h, [ref]$mode)
[void][Cc.CcChild]::SetConsoleMode($h, ($mode -bor 0x200) -band (-bnot 0x7))
[IO.File]::WriteAllText((Join-Path $Out "started.txt"), [DateTime]::UtcNow.Ticks.ToString())
[Console]::Out.Write("CONPTY-CHECK READY`r`n"); [Console]::Out.Flush()
function Drain([string]$name, [int]$ms) {
    $f = Join-Path $Out $name; [IO.File]::WriteAllText($f, "")
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        $s = [Cc.CcChild]::Take($h)
        if ($s) { [IO.File]::AppendAllText($f, ((($s.ToCharArray()) | ForEach-Object { "{0:x2}" -f [int]$_ }) -join " ") + "`n") }
        else { Start-Sleep -Milliseconds 10 }
    }
}
Drain "start.txt" 3000
[IO.File]::WriteAllText((Join-Path $Out "phase-resize.txt"), "go")
$sw = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path (Join-Path $Out "resized.txt")) -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 50 }
Drain "resize.txt" 3000
[IO.File]::WriteAllText((Join-Path $Out "exiting.txt"), [DateTime]::UtcNow.Ticks.ToString())
} catch { [IO.File]::WriteAllText((Join-Path $Out "child.err"), ($_ | Out-String)) }
'@
[IO.File]::WriteAllText($child, $childBody, (New-Object System.Text.UTF8Encoding $true))

$results = @()
function Record([string]$id, [string]$what, [string]$got, [bool]$ok) {
    $script:results += [pscustomobject]@{ id = $id; ok = $ok }
    Write-Host ("{0,-4} {1} {2} — {3}" -f $id, $(if ($ok) { "PASS" } else { "FAIL" }), $what, $got)
}
function Ticks([string]$name) { $f = Join-Path $Out $name; if (Test-Path $f) { return [long](Get-Content $f -Raw).Trim() } else { return 0 } }
function Bytes([string]$name) { $f = Join-Path $Out $name; if (Test-Path $f) { return "$(Get-Content $f -Raw)".TrimEnd() } else { return "(파일 없음)" } }

if (-not (Test-Path $Bin)) { throw "바이너리 없음: $Bin" }
$others = @(Get-CimInstance Win32_Process -Filter "Name like 'tildaz%'")
if ($others.Count -gt 0) { throw ("다른 TildaZ 가 떠 있다 — 멈춘다 (pid " + (($others | ForEach-Object { $_.ProcessId }) -join ', ') + ")") }
$launcherWnd = [Cc]::GetForegroundWindow()
"bin: $Bin"
$c1 = (Get-Item (Join-Path (Split-Path (Resolve-Path $Bin)) '_internal\conpty.dll')).VersionInfo.FileVersion
"conpty.dll: $c1"

Remove-Item (Join-Path $env:APPDATA 'tildaz-dev\tildaz_stress.log') -Force -ErrorAction SilentlyContinue
$cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$child`" `"$Out`""
$t0 = [DateTime]::UtcNow.Ticks
$p = Start-Process -FilePath (Resolve-Path $Bin) -PassThru -ArgumentList '--instance', '9', '-e', "`"$cmd`""
try {
    $h = [IntPtr]::Zero
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($h -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 20; if ($p.HasExited) { break }; $h = [Cc]::FindWindowOfPid([uint32]$p.Id) }
    if ($h -eq [IntPtr]::Zero) { throw "창 못 찾음" }
    $tWin = [DateTime]::UtcNow.Ticks
    # C1 — 빈 창에서 글자가 처음 생기기까지. 커서 한 칸 정도는 넘는 잉크를 글자로 본다.
    $base = [Cc]::Ink($h); $tDraw = 0
    while ($sw.ElapsedMilliseconds -lt 15000) {
        if ([Cc]::Ink($h) -gt $base + 300) { $tDraw = [DateTime]::UtcNow.Ticks; break }
        Start-Sleep -Milliseconds 20
    }
    $tStart = Ticks "started.txt"
    $ms = { param($a, $b) if ($a -eq 0 -or $b -eq 0) { -1 } else { [math]::Round(($a - $b) / 10000.0) } }
    $toDraw = & $ms $tDraw $t0; $childToDraw = & $ms $tDraw $tStart
    Record 'C1' '띄운 뒤 첫 글자가 화면에 나오기까지' ("띄움→창 $(& $ms $tWin $t0) ms · 띄움→글자 $toDraw ms · 자식 시작→글자 $childToDraw ms") (($childToDraw -ge 0) -and ($childToDraw -lt 2000))

    # C2 · C3
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path (Join-Path $Out "phase-resize.txt")) -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 50 }
    $b2 = Bytes "start.txt"
    Record 'C2' '시작 직후 3 초 동안 자식이 받은 입력' $(if ($b2) { "'$b2'" } else { '없음' }) ($b2 -eq '')
    # 포커스 — SetForegroundWindow 는 앞 창이 남의 프로세스면 조용히 무시될 수 있어 몇 번 다시 한다.
    for ($i = 0; $i -lt 5 -and [Cc]::GetForegroundWindow() -ne $h; $i++) { [void][Cc]::SetForegroundWindow($h); Start-Sleep -Milliseconds 400 }
    if ([Cc]::GetForegroundWindow() -ne $h) { throw "포커스를 못 잡았다 — 크기 바꾸는 키를 보내지 않는다" }
    [Cc]::Chord(@(0x11, 0x10, 0xBB)); Start-Sleep -Milliseconds 700    # Ctrl+Shift+= 글자 크게
    [Cc]::Chord(@(0x11, 0x10, 0x08)); Start-Sleep -Milliseconds 700    # Ctrl+Shift+Backspace 되돌리기
    [IO.File]::WriteAllText((Join-Path $Out "resized.txt"), "1")
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path (Join-Path $Out "exiting.txt")) -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 50 }
    $b3 = Bytes "resize.txt"
    $resizes = @(Get-Content (Join-Path $env:APPDATA 'tildaz-dev\tildaz_stress.log') -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ -match 'terminal font size (increase|reset)' }).Count
    Record 'C3' '글자 크기를 두 번 바꾼 뒤 3 초 동안 자식이 받은 입력' ("$(if ($b3) { "'$b3'" } else { '없음' }) · 로그의 글자 크기 변경 $resizes 줄") (($b3 -eq '') -and ($resizes -ge 2))

    # C4
    $tExit = Ticks "exiting.txt"
    $done = $p.WaitForExit(10000)
    $tEnd = [DateTime]::UtcNow.Ticks
    Record 'C4' '자식이 끝난 뒤 앱이 끝나기까지' $(if ($done) { "$(& $ms $tEnd $tExit) ms (측정 주기 포함)" } else { '10 초 안에 안 끝남' }) ($done -and ((& $ms $tEnd $tExit) -lt 5000))
    if (Test-Path (Join-Path $Out 'child.err')) { "자식 오류: " + (Get-Content (Join-Path $Out 'child.err') -Raw) }
} finally {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    if ($launcherWnd -ne [IntPtr]::Zero) { [void][Cc]::SetForegroundWindow($launcherWnd) }
}
if ($Wsl) {
    Remove-Item (Join-Path $env:APPDATA 'tildaz-dev\tildaz_stress.log') -Force -ErrorAction SilentlyContinue
    $wcmd = "wsl.exe -d $Wsl -- sh -c 'echo CONPTY-CHECK-WSL; sleep 2'"
    $p = Start-Process -FilePath (Resolve-Path $Bin) -PassThru -ArgumentList '--instance', '9', '-e', "`"$wcmd`""
    try {
        $h = [IntPtr]::Zero; $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($h -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 20; if ($p.HasExited) { break }; $h = [Cc]::FindWindowOfPid([uint32]$p.Id) }
        $ink = $false
        if ($h -ne [IntPtr]::Zero) { $base = [Cc]::Ink($h); while (-not $p.HasExited -and $sw.ElapsedMilliseconds -lt 15000) { if ([Cc]::Ink($h) -gt $base + 300) { $ink = $true; break }; Start-Sleep -Milliseconds 50 } }
        $done = $p.WaitForExit(15000)
        Record 'C5' "WSL ($Wsl) 셸이 글자를 찍고 끝남" ("창 $($h -ne [IntPtr]::Zero) · 글자 $ink · 앱 종료 $done · 걸린 시간 $([math]::Round($sw.Elapsed.TotalSeconds, 1)) 초") ($ink -and $done)
    } finally { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
}
$fail = @($results | Where-Object { -not $_.ok }).Count
"결과: $($results.Count) 항목 중 실패 $fail"
