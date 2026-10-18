# 키가 화면을 바꾸는 장면이 **키 직후 (150 ms) 에 이미 그려졌는지** 합성 입력과 창 캡처로 판정한다
# (#763 의 Windows 회귀).
#
# ```powershell
# powershell.exe -NoProfile -STA -File tool\key-redraw-check_windows.ps1                       # zig-out\bin\tildaz.exe
# powershell.exe -NoProfile -STA -File tool\key-redraw-check_windows.ps1 -Bin <판>\tildaz.exe  # _internal 도 그 옆에 있어야 한다
# ```
#
# 왜 150 ms 인가 — #763 부터 키 메시지 (`WM_KEYDOWN` … `WM_SYSDEADCHAR`) 는 그리기 게이트를 열지 않고,
# 화면을 바꾸는 키가 각자 그리기를 요청한다 (`window.zig` 의 `isFrameGateExempt`). 요청이 빠진 자리는
# 다른 그리기가 올 때까지 **화면이 안 바뀐다** (커서 깜빡임 타이머도 없다). 그래서 키 뒤 150 ms 와 800 ms 에
# 찍어 "150 ms 에 이미 바뀌었고 · 그 뒤로 안 바뀐다" 를 본다. 에코가 없는 장면 (R2 · R3a) 이 가장 확실하다.
#
# | id | 장면 | 판정 |
# |---|---|---|
# | R1 | 스크롤백을 올린 채 `a` (에코) | 맨 아래로 왔고 맨 아래 사진과 두 줄 안에서만 다르다 |
# | R2 | 스크롤백을 올린 채 `q` (자식이 에코하지 않는다) | 같음 |
# | R3a · R3b | 스크롤백을 올린 채 `Ctrl+C` · `Ctrl+Shift+V` | 같음 + 자식이 `03` · `50 5a` 를 받는다 |
# | R4 | MS-IME `ㄱ` `ㅏ` → `→` · 다시 → `Enter` | 조합 색 (64,64,128) 이 생겼다 사라진다 + 자식이 `가` 와 그 키를 받는다 |
# | R6 | `Alt+1` · `Ctrl+Shift+]` · `Ctrl+Shift+[` · `⋯` 클릭 뒤 `↓` × 2 · `Esc` | 150 ms 에 바뀌었고 800 ms 와 같다 |
#
# dead key 표시는 `tool\deadkey-check\deadkey-check_windows.ps1 -Capture` 가 본다 (이 도구는 안 본다).
#
# 하는 일 · 되돌리는 것 —
# - `--instance 9 -e <자식>` 로 창 하나를 띄운다 (`-e` 라 config · hotkey 를 만들지 않는다). 자식 PowerShell 은
#   300 줄을 찍고 raw 입력 (`ENABLE_VIRTUAL_TERMINAL_INPUT`) 을 hex 로 적는다. `q` · 제어 문자 · ESC 시퀀스는 에코하지 않는다.
# - 한국어 IME (`00000412`) 를 **tildaz 창 스레드에만** 올리고 끝에 되돌린다 (이번에 올렸으면 내린다).
# - 클립보드를 잠깐 `PZ` 로 바꾸고 되돌린다. **순수 글자 말고 다른 형식이 있으면 붙여넣기 장면만 건너뛴다**
#   (되돌릴 수 없어서 — AGENTS.md 의 selection-check 와 같은 규칙).
# - 시작할 때 다른 TildaZ 가 떠 있으면 멈춘다 (AGENTS.md — 다른 세션의 창을 잡지 않도록). 끝나면 시작 때 앞에 있던 창을 다시 올린다.
#
# 실기라서 **시작 전에 알리고 동의를 받는다** — 약 1 분 동안 창이 뜨고 합성 키 · 클릭이 나간다.
# 처음 적용은 2026-10-16 데스크탑 Ryzen 7 5700G · 150 % · 60 Hz 에서 17 / 17 이었다
# ([#763 ⑩](https://github.com/ensky0/tildaz/issues/763#issuecomment-6204832506)).
#
# ⚠️ 이 파일은 UTF-8 **BOM** 으로 저장한다 (Windows PowerShell 5.1 이 BOM 없는 `.ps1` 을 cp949 로 읽는다).
# `-STA` 로 부른다 — 클립보드 (`System.Windows.Forms.Clipboard`) 가 STA 스레드를 요구한다.
param(
    [string]$Bin = "zig-out\bin\tildaz.exe",
    [string]$Out = (Join-Path $env:TEMP "tildaz-key-redraw")
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies System.Drawing @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class Tz {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] p, int cb);
  [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint c, uint t);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr LoadKeyboardLayoutW(string klid, uint flags);
  [DllImport("user32.dll")] public static extern bool UnloadKeyboardLayout(IntPtr hkl);
  [DllImport("user32.dll")] public static extern int GetKeyboardLayoutList(int n, IntPtr[] list);
  [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint thread);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Explicit, Size = 40)] public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; [FieldOffset(8)] public MOUSEINPUT mi; }
  public static void MakeDpiAware() { try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch {} }
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
  public static void Shot(IntPtr h, string png) {
    RECT r; GetWindowRect(h, out r);
    using (var bmp = new Bitmap(r.R - r.L, r.B - r.T, PixelFormat.Format32bppArgb)) {
      using (var g = Graphics.FromImage(bmp)) { IntPtr hdc = g.GetHdc(); PrintWindow(h, hdc, 2); g.ReleaseHdc(hdc); }
      bmp.Save(png, ImageFormat.Png);
    }
  }
  static int[] Pixels(Bitmap b) {
    var d = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    try { var p = new int[b.Width * b.Height]; Marshal.Copy(d.Scan0, p, 0, p.Length); return p; } finally { b.UnlockBits(d); }
  }
  public static long Diff(string a, string b, out string bbox) {
    bbox = "";
    using (var A = new Bitmap(a)) using (var B = new Bitmap(b)) {
      if (A.Width != B.Width || A.Height != B.Height) { bbox = "size"; return -1; }
      var pa = Pixels(A); var pb = Pixels(B);
      long n = 0; int x0 = int.MaxValue, y0 = int.MaxValue, x1 = -1, y1 = -1;
      for (int y = 0; y < A.Height; y++) for (int x = 0; x < A.Width; x++) {
        int i = y * A.Width + x; if (pa[i] == pb[i]) continue; n++;
        if (x < x0) x0 = x; if (y < y0) y0 = y; if (x > x1) x1 = x; if (y > y1) y1 = y;
      }
      if (n > 0) bbox = string.Format("{0},{1} {2}x{3}", x0, y0, x1 - x0 + 1, y1 - y0 + 1);
      return n;
    }
  }
  public static long CountColor(string f, int r, int g, int b, int tol) {
    using (var A = new Bitmap(f)) {
      var pa = Pixels(A); long n = 0;
      foreach (var v in pa) { int R = (v >> 16) & 0xFF, G = (v >> 8) & 0xFF, Bb = v & 0xFF;
        if (Math.Abs(R - r) <= tol && Math.Abs(G - g) <= tol && Math.Abs(Bb - b) <= tol) n++; }
      return n;
    }
  }
  static INPUT Key(ushort vk, uint flags) { var i = new INPUT(); i.type = 1; i.ki.wVk = vk; i.ki.wScan = (ushort)MapVirtualKeyW(vk, 0); i.ki.dwFlags = flags; return i; }
  static INPUT Mouse(int nx, int ny, uint flags) { var i = new INPUT(); i.type = 0; i.mi.dx = nx; i.mi.dy = ny; i.mi.dwFlags = flags; return i; }
  static void Norm(int x, int y, out int nx, out int ny) {
    int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
    nx = (int)(((long)(x - vx) * 65535) / (vw > 1 ? vw - 1 : 1)); ny = (int)(((long)(y - vy) * 65535) / (vh > 1 ? vh - 1 : 1));
  }
  // 확장 키 (방향 · PgUp/PgDn · Home/End) 는 KEYEVENTF_EXTENDEDKEY 를 붙인다.
  static bool Ext(ushort v) { return (v >= 0x21 && v <= 0x28) || v == 0x2D || v == 0x2E; }
  public static uint Chord(ushort[] vks) {
    var a = new INPUT[vks.Length * 2]; int n = 0;
    foreach (var v in vks) a[n++] = Key(v, Ext(v) ? 1u : 0u);
    for (int k = vks.Length - 1; k >= 0; k--) a[n++] = Key(vks[k], 2u | (Ext(vks[k]) ? 1u : 0u));
    return SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void MoveClient(IntPtr h, int cx, int cy) {
    var p = new POINT(); p.x = cx; p.y = cy; ClientToScreen(h, ref p);
    int nx, ny; Norm(p.x, p.y, out nx, out ny);
    var a = new INPUT[] { Mouse(nx, ny, 0x0001 | 0x8000 | 0x4000) };
    SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void ClickClient(IntPtr h, int cx, int cy) {
    MoveClient(h, cx, cy); System.Threading.Thread.Sleep(150);
    var a = new INPUT[] { Mouse(0, 0, 0x0002) }; SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    System.Threading.Thread.Sleep(80);
    var b = new INPUT[] { Mouse(0, 0, 0x0004) }; SendInput(1, b, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void Topmost(IntPtr h, bool on) { SetWindowPos(h, new IntPtr(on ? -1 : -2), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); }
  public static IntPtr[] Layouts() { var a = new IntPtr[32]; int n = GetKeyboardLayoutList(32, a); var r = new IntPtr[Math.Max(n, 0)]; Array.Copy(a, r, r.Length); return r; }
  public static IntPtr LayoutOfWindow(IntPtr h) { uint pid; uint tid = GetWindowThreadProcessId(h, out pid); return GetKeyboardLayout(tid); }
}
'@
[Tz]::MakeDpiAware()

$VK = @{ A = 0x41; K = 0x4B; Q = 0x51; R = 0x52; T = 0x54; V = 0x56; C = 0x43; D1 = 0x31
         Shift = 0x10; Ctrl = 0x11; Alt = 0x12; Enter = 0x0D; Esc = 0x1B; Right = 0x27; Down = 0x28
         PgUp = 0x21; PgDn = 0x22; Hangul = 0x15; LBracket = 0xDB; RBracket = 0xDD }

New-Item -ItemType Directory -Force -Path $Out | Out-Null
Get-ChildItem $Out -Filter *.png -ErrorAction SilentlyContinue | Remove-Item -Force
$Log = Join-Path $env:APPDATA "tildaz-dev\tildaz_stress.log"
$rx = Join-Path $Out "rx.txt"
Remove-Item $rx, "$rx.err" -Force -ErrorAction SilentlyContinue

# 자식 — 300 줄을 찍고 raw 입력을 받는다. 'q' · 제어 문자 · ESC 시퀀스는 에코하지 않는다 (에코 없는 입력).
$child = Join-Path $Out "child.ps1"
$childBody = @'
param([string]$Out)
$ErrorActionPreference = "Continue"
try {
Add-Type -Name TzChild -Namespace Tz -MemberDefinition @"
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(IntPtr h, uint m);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool ReadFile(IntPtr h, byte[] b, uint n, out uint got, IntPtr o);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetNumberOfConsoleInputEvents(IntPtr h, out uint n);
"@
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
for ($i = 1; $i -le 300; $i++) { Write-Host ("line {0} {1}" -f $i, ("#" * ($i % 40))) }
Write-Host -NoNewline "READY> "
$h = [Tz.TzChild]::GetStdHandle(-10)
$mode = 0
[void][Tz.TzChild]::GetConsoleMode($h, [ref]$mode)
[void][Tz.TzChild]::SetConsoleMode($h, ($mode -bor 0x200) -band (-bnot 0x7))
[IO.File]::AppendAllText($Out, "")
$buf = New-Object byte[] 512
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 600) {
    $n = 0
    if ([Tz.TzChild]::GetNumberOfConsoleInputEvents($h, [ref]$n) -and $n -gt 0) {
        $got = 0
        if ([Tz.TzChild]::ReadFile($h, $buf, 512, [ref]$got, [IntPtr]::Zero) -and $got -gt 0) {
            $b = $buf[0..($got - 1)]
            [IO.File]::AppendAllText($Out, ((($b | ForEach-Object { "{0:x2}" -f $_ }) -join " ") + "`n"))
            if (-not ($b -contains 0x1b)) {
                $s = [Text.Encoding]::UTF8.GetString([byte[]]$b)
                $e = -join ($s.ToCharArray() | Where-Object { [int]$_ -ge 0x20 -and $_ -cne 'q' })
                if ($e) { Write-Host -NoNewline $e }
            }
        }
    } else { Start-Sleep -Milliseconds 5 }
}
} catch { [IO.File]::WriteAllText($Out + ".err", ($_ | Out-String)) }
'@
[IO.File]::WriteAllText($child, $childBody, (New-Object System.Text.UTF8Encoding $true))

function Stop-Tz {
    Get-CimInstance Win32_Process -Filter "Name like 'tildaz%'" |
        Where-Object { $_.CommandLine -match '--instance 9' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
function RxText { if (Test-Path $rx) { return (Get-Content $rx -Raw) } else { return "" } }

$results = @()
function Record([string]$id, [string]$what, [string]$got, [bool]$ok) {
    $script:results += [pscustomobject]@{ id = $id; ok = $ok }
    Write-Host ("{0,-6} {1} {2,-44} {3}" -f $id, $(if ($ok) { "PASS" } else { "FAIL" }), $what, $got)
}
$script:n = 0
function Shot([string]$tag) { $script:n++; $f = Join-Path $Out ("{0:d2}_{1}.png" -f $script:n, $tag); [Tz]::Shot($script:h, $f); return $f }
function D($a, $b) { $bb = ""; $n = [Tz]::Diff($a, $b, [ref]$bb); return @{ n = $n; bb = $bb } }
function BBH($bb) { if ($bb -match ' \d+x(\d+)$') { return [int]$matches[1] } else { return 0 } }
function Guard {
    if ([Tz]::GetForegroundWindow() -eq $script:h) { return }
    [void][Tz]::SetForegroundWindow($script:h); Start-Sleep -Milliseconds 300
    if ([Tz]::GetForegroundWindow() -eq $script:h) { return }
    [Tz]::ClickClient($script:h, [int]($script:CW / 2), [int]($script:CH / 2)); Start-Sleep -Milliseconds 400
    if ([Tz]::GetForegroundWindow() -ne $script:h) { Stop-Tz; throw "포커스를 잃었다 — 중단" }
}
function Send([uint16[]]$chord) { Guard; [void][Tz]::Chord([uint16[]]$chord) }
# 키 뒤 150 ms 와 800 ms 사진.
function After([uint16[]]$chord, [string]$tag) {
    Send $chord
    Start-Sleep -Milliseconds 150; $a = Shot "${tag}_150"
    Start-Sleep -Milliseconds 650; $b = Shot "${tag}_800"
    return @($a, $b)
}
function ScrollUp([string]$tag) {
    Send @($VK.Shift, $VK.PgUp); Start-Sleep -Milliseconds 200
    Send @($VK.Shift, $VK.PgUp); Start-Sleep -Milliseconds 500
    return (Shot "${tag}_up")
}
# 스크롤을 올린 채 키 — 움직였고 (올린 화면과 크게 다름) · 맨 아래와는 한두 줄만 다르고 · 150 ms 에 이미 끝났다.
function ScrollCase([string]$id, [string]$what, $bottom, [uint16[]]$chord, [string]$tag) {
    $up = ScrollUp $tag
    $dUp0 = D $up $bottom
    $s = After $chord $tag
    $dUp = D $s[0] $up; $dBot = D $s[0] $bottom; $dLate = D $s[0] $s[1]
    $ok = ($dUp0.n -gt 5000) -and ($dUp.n -gt 5000) -and ((BBH $dBot.bb) -le (2 * $script:CellH)) -and ($dLate.n -eq 0)
    Record $id $what ("올림 $($dUp0.n) · 150ms vs 올림 $($dUp.n) · vs 맨아래 $($dBot.n) [$($dBot.bb)] · 150↔800 $($dLate.n)") $ok
    return $s[1]
}

if (-not (Test-Path $Bin)) { throw "바이너리 없음: $Bin" }
$others = @(Get-CimInstance Win32_Process -Filter "Name like 'tildaz%'")
if ($others.Count -gt 0) {
    throw ("다른 TildaZ 가 떠 있다 — 멈춘다 (pid " + (($others | ForEach-Object { $_.ProcessId }) -join ', ') + ")")
}
$launcherWnd = [Tz]::GetForegroundWindow()
$logStart = if (Test-Path $Log) { (Get-Content $Log).Count } else { 0 }
$cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$child`" `"$rx`""
$p = Start-Process -FilePath (Resolve-Path $Bin) -PassThru -ArgumentList '--instance', '9', '-e', "`"$cmd`"", '-size', '100x30'
$script:h = [IntPtr]::Zero
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($script:h -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 15000) {
    Start-Sleep -Milliseconds 150; if ($p.HasExited) { break }
    $script:h = [Tz]::FindWindowOfPid([uint32]$p.Id)
}
if ($p.HasExited) { throw "앱이 먼저 끝남 exit=$($p.ExitCode)" }
if ($script:h -eq [IntPtr]::Zero) { Stop-Tz; throw "창 못 찾음" }
$sw = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path $rx) -and $sw.ElapsedMilliseconds -lt 15000) { Start-Sleep -Milliseconds 200 }
Start-Sleep -Seconds 2
$newLog = @(Get-Content $Log -Encoding UTF8 | Select-Object -Skip $logStart)
if (@($newLog | Where-Object { $_ -match '\[fatal\]' }).Count -gt 0) { Stop-Tz; throw "앱이 fatal — 잡힌 창은 다이얼로그다" }
$init = [string]($newLog | Where-Object { $_ -match 'window initialized' } | Select-Object -Last 1)
$script:CellH = 29; $dpi = 96
if ($init -match 'dpi=(\d+) cell=(\d+)x(\d+)') { $dpi = [int]$matches[1]; $script:CellH = [int]$matches[3] }
$Scale = $dpi / 96.0
$cr = New-Object Tz+RECT; [void][Tz]::GetClientRect($script:h, [ref]$cr)
$script:CW = $cr.R - $cr.L; $script:CH = $cr.B - $cr.T
"창 hwnd=$script:h client=$($script:CW)x$($script:CH) · $($init -replace '^\[[^\]]+\]\s*', '')"

$layoutsBefore = [Tz]::Layouts()
$hkl = [IntPtr]::Zero; $loadedByUs = $false; $prevHkl = [IntPtr]::Zero
$clipSaved = $null; $clipTouched = $false
try {
    Guard
    [Tz]::Topmost($script:h, $true)
    # 포인터를 터미널 가운데로 (메뉴 · 탭바 hover 를 피한다).
    [Tz]::MoveClient($script:h, [int]($script:CW / 2), [int]($script:CH / 2)); Start-Sleep -Milliseconds 400

    # ---------------------------------------------------------------- 1 · 2 · 3 스크롤
    $b0 = Shot "bottom0"
    $b1 = ScrollCase "R1" "올린 채 글자 a (에코 있음) → 맨 아래" $b0 @($VK.A) "R1"
    $b1 = Shot "bottom1"
    [void](ScrollCase "R2" "올린 채 q (에코 없음) → 맨 아래" $b1 @($VK.Q) "R2")
    [void](ScrollCase "R3a" "올린 채 Ctrl+C → 맨 아래" $b1 @($VK.Ctrl, $VK.C) "R3a")
    $rxNow = RxText
    Record "R-rx" "자식이 a · q · 03 을 받았다" (($rxNow -split "`n" | Where-Object { $_ }) -join ' | ') (($rxNow -match '(^|\n)61') -and ($rxNow -match '(^|\n)71') -and ($rxNow -match '(^|\n)03'))

    # 붙여넣기 — 클립보드가 순수 글자일 때만 (다른 형식은 되돌릴 수 없다).
    $fmts = @([Windows.Forms.Clipboard]::GetDataObject().GetFormats())
    $textOnly = @($fmts | Where-Object { $_ -notmatch '^(Text|UnicodeText|System\.String|OEMText|Locale)$' }).Count -eq 0
    if ($textOnly) {
        $clipSaved = if ([Windows.Forms.Clipboard]::ContainsText()) { [Windows.Forms.Clipboard]::GetText() } else { $null }
        [Windows.Forms.Clipboard]::SetText("PZ"); $clipTouched = $true
        [void](ScrollCase "R3b" "올린 채 Ctrl+Shift+V → 맨 아래" $b1 @($VK.Ctrl, $VK.Shift, $VK.V) "R3b")
        Record "R3b-rx" "자식이 붙인 PZ 를 받았다" (((RxText) -split "`n" | Where-Object { $_ } | Select-Object -Last 1)) ((RxText) -match '50 5a')
    } else {
        Record "R3b" "붙여넣기 — 건너뜀" ("클립보드에 글자 말고 다른 형식이 있다: " + ($fmts -join ',')) $false
    }

    # ---------------------------------------------------------------- 4 한글 조합
    $hkl = [Tz]::LoadKeyboardLayoutW("00000412", 0)
    $loadedByUs = ($hkl -ne [IntPtr]::Zero) -and -not ($layoutsBefore -contains $hkl)
    $prevHkl = [Tz]::LayoutOfWindow($script:h)
    [void][Tz]::PostMessageW($script:h, 0x0050, [IntPtr]::Zero, $hkl); Start-Sleep -Milliseconds 600
    $now = [Tz]::LayoutOfWindow($script:h)
    if ($now -ne $hkl) {
        Record "R4" "한글 조합 — layout 전환 실패" ("0x{0:x8}" -f [int64]$now) $false
    } else {
        Send @($VK.Hangul); Start-Sleep -Milliseconds 600
        $k0 = Shot "R4_base"
        Send @($VK.R); Start-Sleep -Milliseconds 200
        $k1 = (After @($VK.K) "R4_ga")[0]
        $pe1 = [Tz]::CountColor($k1, 64, 64, 128, 2); $d1 = D $k1 $k0
        $k2 = After @($VK.Right) "R4_right"
        $pe2 = [Tz]::CountColor($k2[0], 64, 64, 128, 2); $l2 = D $k2[0] $k2[1]
        Send @($VK.R); Start-Sleep -Milliseconds 200
        $k3 = (After @($VK.K) "R4_ga2")[0]
        $pe3 = [Tz]::CountColor($k3, 64, 64, 128, 2)
        $k4 = After @($VK.Enter) "R4_enter"
        $pe4 = [Tz]::CountColor($k4[0], 64, 64, 128, 2); $l4 = D $k4[0] $k4[1]
        Send @($VK.Hangul); Start-Sleep -Milliseconds 400
        Record "R4a" "ㄱ+ㅏ → 조합 표시가 150 ms 에 보인다" "조합색 $pe1 px · 바뀐 $($d1.n) px [$($d1.bb)]" ($pe1 -gt 0)
        Record "R4b" "→ 로 확정 → 조합 표시가 사라진다" "조합색 $pe2 px · 150↔800 $($l2.n)" (($pe2 -eq 0) -and ($l2.n -eq 0))
        Record "R4c" "다시 ㄱ+ㅏ → 조합 표시" "조합색 $pe3 px" ($pe3 -gt 0)
        Record "R4d" "Enter 로 확정 → 조합 표시가 사라진다" "조합색 $pe4 px · 150↔800 $($l4.n)" (($pe4 -eq 0) -and ($l4.n -eq 0))
        $rxNow = RxText
        $hasArrow = $rxNow -match 'ea b0 80[^\n]*\n(1b 5b 43|[^\n]*1b 5b 43)|ea b0 80 1b 5b 43'
        $hasEnter = $rxNow -match 'ea b0 80[^\n]*\n0d|ea b0 80 0d'
        Record "R4-rx" "자식이 가→ · 가↵ 를 받았다" (($rxNow -split "`n" | Where-Object { $_ } | Select-Object -Last 5) -join ' | ') ($hasArrow -and $hasEnter)
    }
    if ($prevHkl -ne [IntPtr]::Zero) { [void][Tz]::PostMessageW($script:h, 0x0050, [IntPtr]::Zero, $prevHkl); Start-Sleep -Milliseconds 400 }

    # ---------------------------------------------------------------- 6 탭 · 메뉴
    [Tz]::MoveClient($script:h, [int]($script:CW / 2), [int]($script:CH / 2))
    Send @($VK.Ctrl, $VK.Shift, $VK.T); Start-Sleep -Seconds 5
    $t2 = Shot "T_tab2"
    $s = After @($VK.Alt, $VK.D1) "T_alt1"
    $dA = D $s[0] $t2; $lA = D $s[0] $s[1]
    # 두 탭은 같은 300 줄이라 차이는 탭바 강조와 1 번 탭의 마지막 줄 (에코한 글자) 뿐이다.
    Record "R6a" "Alt+1 → 150 ms 에 1 번 탭" "tab2 와 $($dA.n) px [$($dA.bb)] · 150↔800 $($lA.n)" (($dA.n -gt 500) -and ($lA.n -eq 0))
    $t1 = $s[1]
    $s = After @($VK.Ctrl, $VK.Shift, $VK.RBracket) "T_next"
    $dB = D $s[0] $t1; $dB2 = D $s[0] $t2; $lB = D $s[0] $s[1]
    Record "R6b" "Ctrl+Shift+] → 150 ms 에 2 번 탭" "tab1 과 $($dB.n) · tab2 와 $($dB2.n) [$($dB2.bb)] · 150↔800 $($lB.n)" (($dB.n -gt 500) -and ((BBH $dB2.bb) -le (2 * $script:CellH)) -and ($lB.n -eq 0))
    $s = After @($VK.Ctrl, $VK.Shift, $VK.LBracket) "T_prev"
    $dC = D $s[0] $t1; $lC = D $s[0] $s[1]
    Record "R6c" "Ctrl+Shift+[ → 150 ms 에 1 번 탭" "tab1 과 $($dC.n) [$($dC.bb)] · 150↔800 $($lC.n)" (((BBH $dC.bb) -le (2 * $script:CellH)) -and ($lC.n -eq 0))

    # 메뉴 — ⋯ 위에 포인터를 둔 채 (hover) 기준을 찍고, 클릭으로 열고, ↓ · Esc 를 키로.
    $mx = [int]($script:CW - 13 * $Scale); $my = [int](13 * $Scale)
    [Tz]::MoveClient($script:h, $mx, $my); Start-Sleep -Milliseconds 500
    $pre = Shot "M_hover"
    [Tz]::ClickClient($script:h, $mx, $my); Start-Sleep -Milliseconds 600
    $m0 = Shot "M_open"
    $dO = D $m0 $pre
    $s = After @($VK.Down) "M_down"
    $dD = D $s[0] $m0; $lD = D $s[0] $s[1]
    $s2 = After @($VK.Down) "M_down2"
    $dD2 = D $s2[0] $s[1]; $lD2 = D $s2[0] $s2[1]
    $s3 = After @($VK.Esc) "M_esc"
    $dE = D $s3[0] $pre; $dEo = D $s3[0] $m0; $lE = D $s3[0] $s3[1]
    Record "R6d" "⋯ 클릭 → 메뉴가 열린다 (마우스)" "$($dO.n) px [$($dO.bb)]" ($dO.n -gt 5000)
    Record "R6e" "↓ → 150 ms 에 강조가 움직인다" "1 회 $($dD.n) px [$($dD.bb)] · 150↔800 $($lD.n) · 2 회 $($dD2.n) · 150↔800 $($lD2.n)" (($dD.n -gt 0) -and ($lD.n -eq 0) -and ($dD2.n -gt 0) -and ($lD2.n -eq 0))
    Record "R6f" "Esc → 150 ms 에 메뉴가 닫힌다" "열린 화면과 $($dEo.n) · 열기 전과 $($dE.n) [$($dE.bb)] · 150↔800 $($lE.n)" (($dEo.n -gt 5000) -and ($dE.n -lt 2000) -and ($lE.n -eq 0))
} catch {
    "❌ $_"
} finally {
    if ($script:h -ne [IntPtr]::Zero) { [Tz]::Topmost($script:h, $false) }
    Stop-Tz
    if ($loadedByUs) { "한국어 layout 내림: $([Tz]::UnloadKeyboardLayout($hkl))" }
    "세션 layout 전: " + (($layoutsBefore | ForEach-Object { '0x{0:x8}' -f [int64]$_ }) -join ' ')
    "세션 layout 후: " + (([Tz]::Layouts() | ForEach-Object { '0x{0:x8}' -f [int64]$_ }) -join ' ')
    if ($clipTouched) {
        if ($null -ne $clipSaved) { [Windows.Forms.Clipboard]::SetText($clipSaved); "클립보드 되돌림 (글자 $($clipSaved.Length) 자)" }
        else { [Windows.Forms.Clipboard]::Clear(); "클립보드 비움 (원래 비어 있었음)" }
    }
    # 시작 때 앞에 있던 창 (보통 VS Code) 을 다시 올린다 (AGENTS.md `# 실행 환경`).
    if ($launcherWnd -ne [IntPtr]::Zero) { [void][Tz]::ShowWindow($launcherWnd, 9); [void][Tz]::SetForegroundWindow($launcherWnd) }
}
if (Test-Path "$rx.err") { "자식 오류: " + (Get-Content "$rx.err" -Raw) }
$fail = @($results | Where-Object { -not $_.ok }).Count
"결과: $($results.Count) 항목 중 실패 $fail · 캡처 $Out"
