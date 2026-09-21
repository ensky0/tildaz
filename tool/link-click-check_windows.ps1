# 링크 클릭 (#647 · 요청 #643) 을 합성 마우스 · 키 입력으로 자동 검증한다 (Windows · PowerShell 5.1).
#
# ```powershell
# tool\link-click-check_windows.ps1 -Mode probe                      # 창을 띄워 캡처만 — 좌표를 눈으로 확인
# tool\link-click-check_windows.ps1 -Mode A -Link 320,150 -Osc8 210,90 -Plain 60,150
# tool\link-click-check_windows.ps1 -Mode B -Link 320,150 -Osc8 210,90 -Plain 60,150
# ```
#
# - 회차 A 는 평소 셸 (앱이 마우스를 안 잡음), 회차 B 는 화면 스크립트가 `DECSET 1000` 을 켜 **앱이 마우스를
#   잡은** 상태다. 확정된 동작은 "밑줄이 보이면 클릭하면 열린다" 이고, B 에서는 `Ctrl` 을 눌러야 보인다.
# - 좌표는 **클라이언트 좌표 (px)** 다. `-Mode probe` 가 캡처를 남기니 그 PNG 에서 읽어 넣는다. 창 위치가
#   회차마다 달라도 클라이언트 기준이라 그대로 쓸 수 있다.
# - **판정 셋을 함께 본다.** ① 밑줄 — `PrintWindow` 캡처를 중립 상태와 픽셀로 견준다 (커서는 캡처에 안 들어가
#   므로 오염이 없다). ② 커서 모양 — `GetCursorInfo` 의 `hCursor` 를 `LoadCursorW` 의 공유 핸들과 견준다.
#   ③ 열림 — `tildaz_stress.log` 의 `[link] opening link:` 줄이 케이스마다 **정확히 한 줄** 늘었는지.
# - `--instance 9` + `-e` 로만 띄운다 — config 를 만들지 않고 (#382) hotkey 도 등록하지 않아 사용자의
#   instance 0 과 부딪히지 않는다. 로그는 `%APPDATA%\tildaz-dev\tildaz_stress.log` 다.
# - **키 · 마우스마다 포커스 가드**다 (`tool/send-keys_windows.ps1` 과 같은 규칙) — foreground 가 tildaz 창이
#   아니면 멈춘다. 합성 입력은 포커스된 창으로 가니 회차 동안 사용자가 다른 창을 만지면 거기에 간다.
# - 실기라서 **시작 전에 알리고 동의를 받는다** (AGENTS.md `# 실행 환경`). A2 에서 `https://example.com` 이
#   실제로 열려 **브라우저 창이 한 번 뜬다**. 나머지 클릭은 등록된 앱이 없는 `x-tildaz-test://` 라 창이 안 뜬다.
#
# ⚠️ 이 파일은 **UTF-8 BOM** 으로 저장한다 — Windows PowerShell 5.1 은 BOM 없는 `.ps1` 을 ANSI (cp949) 로
# 읽어 한글 주석이 토큰까지 깨뜨린다 (`render-ab-shot_windows.ps1` 의 같은 주석).

[CmdletBinding()]
param(
    [ValidateSet('probe', 'A', 'B', 'C', 'D', 'E')][string]$Mode = 'probe',
    [string]$Bin = 'zig-out\bin\tildaz.exe',
    [string]$Screen = "$env:TEMP\tz-link.ps1",
    [string]$Size = '88x20',
    # 클라이언트 좌표 "x,y". probe 캡처에서 읽는다.
    [string]$Link = '',
    [string]$Osc8 = '',
    [string]$Plain = '',
    # 회차 E 전용 — 컨트롤 스트립 `+` 의 클라이언트 좌표. 비우면 창 폭에서 계산한다.
    [string]$Plus = '',
    [int]$Wait = 6
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class TzLink {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
  [StructLayout(LayoutKind.Sequential)] public struct CURSORINFO { public int cbSize, flags; public IntPtr hCursor; public POINT pt; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool GetCursorInfo(ref CURSORINFO ci);
  [DllImport("user32.dll")] public static extern IntPtr LoadCursorW(IntPtr hInst, IntPtr name);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] p, int cb);
  [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint c, uint t);
  [DllImport("user32.dll")] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Explicit, Size = 40)] public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; [FieldOffset(8)] public MOUSEINPUT mi; }

  public static void MakeDpiAware() {
    try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch {}
    try { SetProcessDPIAware(); } catch {}
  }
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
  // 앞선 회차가 남긴 cmd.exe - 응용 프로그램 오류 (#32770) 를 닫는다 — 떠 있으면 다음 회차가 즉시 막힌다.
  public static int CloseStaleErrorDialogs() {
    int n = 0;
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      var cls = new System.Text.StringBuilder(64); GetClassNameW(h, cls, 64);
      if (cls.ToString() != "#32770") return true;
      var t = new System.Text.StringBuilder(256); GetWindowTextW(h, t, 256);
      string s = t.ToString();
      if (s.IndexOf("cmd.exe", StringComparison.OrdinalIgnoreCase) < 0 &&
          s.IndexOf("powershell", StringComparison.OrdinalIgnoreCase) < 0) return true;
      SendMessageW(h, 0x0010, IntPtr.Zero, IntPtr.Zero);   // WM_CLOSE
      n++; return true;
    }, IntPtr.Zero);
    return n;
  }
  public static Bitmap Capture(IntPtr h) {
    RECT r; GetWindowRect(h, out r);
    var bmp = new Bitmap(r.R - r.L, r.B - r.T, PixelFormat.Format32bppArgb);
    using (var g = Graphics.FromImage(bmp)) {
      IntPtr hdc = g.GetHdc();
      PrintWindow(h, hdc, 2);
      g.ReleaseHdc(hdc);
    }
    return bmp;
  }
  public static long Diff(string a, string b, out string bbox) {
    bbox = "";
    using (var A = new Bitmap(a)) using (var B = new Bitmap(b)) {
      if (A.Width != B.Width || A.Height != B.Height) return -1;
      var da = A.LockBits(new Rectangle(0, 0, A.Width, A.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
      var db = B.LockBits(new Rectangle(0, 0, B.Width, B.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
      try {
        var pa = new int[A.Width * A.Height]; var pb = new int[pa.Length];
        Marshal.Copy(da.Scan0, pa, 0, pa.Length); Marshal.Copy(db.Scan0, pb, 0, pb.Length);
        long n = 0; int x0 = int.MaxValue, y0 = int.MaxValue, x1 = -1, y1 = -1;
        for (int i = 0; i < pa.Length; i++) if (pa[i] != pb[i]) {
          n++; int x = i % A.Width, y = i / A.Width;
          if (x < x0) x0 = x; if (y < y0) y0 = y; if (x > x1) x1 = x; if (y > y1) y1 = y;
        }
        if (n > 0) bbox = string.Format("{0},{1} {2}x{3}", x0, y0, x1 - x0 + 1, y1 - y0 + 1);
        return n;
      } finally { A.UnlockBits(da); B.UnlockBits(db); }
    }
  }
  // 지금 화면의 커서가 어느 시스템 커서인지. 모르는 핸들이면 "other".
  public static string CursorName() {
    var ci = new CURSORINFO(); ci.cbSize = Marshal.SizeOf(typeof(CURSORINFO));
    if (!GetCursorInfo(ref ci)) return "query-failed";
    if (ci.hCursor == IntPtr.Zero) return "hidden";
    if (ci.hCursor == LoadCursorW(IntPtr.Zero, new IntPtr(32649))) return "hand";
    if (ci.hCursor == LoadCursorW(IntPtr.Zero, new IntPtr(32513))) return "ibeam";
    if (ci.hCursor == LoadCursorW(IntPtr.Zero, new IntPtr(32512))) return "arrow";
    if (ci.hCursor == LoadCursorW(IntPtr.Zero, new IntPtr(32644))) return "sizewe";
    if (ci.hCursor == LoadCursorW(IntPtr.Zero, new IntPtr(32645))) return "sizens";
    return "other";
  }
  static INPUT Key(ushort vk, uint flags) {
    var i = new INPUT(); i.type = 1; i.ki.wVk = vk; i.ki.wScan = (ushort)MapVirtualKeyW(vk, 0); i.ki.dwFlags = flags; return i;
  }
  static INPUT Mouse(int nx, int ny, uint flags) { var i = new INPUT(); i.type = 0; i.mi.dx = nx; i.mi.dy = ny; i.mi.dwFlags = flags; return i; }
  static void Norm(int x, int y, out int nx, out int ny) {
    int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
    nx = (int)(((long)(x - vx) * 65535) / (vw > 1 ? vw - 1 : 1)); ny = (int)(((long)(y - vy) * 65535) / (vh > 1 ? vh - 1 : 1));
  }
  const uint MOVE_ABS = 0x0001 | 0x8000 | 0x4000;
  // 화면 좌표로 포인터를 옮긴다. steps 로 나눠 보내 hover 가 실제 이동으로 잡히게 한다.
  public static void MoveTo(int x, int y, int steps) {
    int nx, ny; Norm(x, y, out nx, out ny);
    for (int k = 0; k < steps; k++) {
      int sx, sy; Norm(x + (k < steps - 1 ? (k % 2 == 0 ? 1 : -1) : 0), y, out sx, out sy);
      var a = new INPUT[] { Mouse(sx, sy, MOVE_ABS) };
      SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
      System.Threading.Thread.Sleep(60);
    }
    var b = new INPUT[] { Mouse(nx, ny, MOVE_ABS) };
    SendInput(1, b, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void ClickHere() {
    var a = new INPUT[] { Mouse(0, 0, 0x0002) };
    SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    System.Threading.Thread.Sleep(80);
    var b = new INPUT[] { Mouse(0, 0, 0x0004) };
    SendInput(1, b, Marshal.SizeOf(typeof(INPUT)));
  }
  // 누른 채 끌어서 뗀다 — 선택이지 링크 열기가 아님을 본다 (A5).
  public static void DragTo(int x0, int y0, int x1, int y1) {
    MoveTo(x0, y0, 1);
    System.Threading.Thread.Sleep(120);
    var d = new INPUT[] { Mouse(0, 0, 0x0002) };
    SendInput(1, d, Marshal.SizeOf(typeof(INPUT)));
    System.Threading.Thread.Sleep(120);
    for (int k = 1; k <= 6; k++) MoveTo(x0 + (x1 - x0) * k / 6, y0 + (y1 - y0) * k / 6, 1);
    System.Threading.Thread.Sleep(120);
    var u = new INPUT[] { Mouse(0, 0, 0x0004) };
    SendInput(1, u, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void KeyDownUp(ushort vk, bool down) {
    var a = new INPUT[] { Key(vk, down ? 0u : 2u) };
    SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
  }
  // A2 는 브라우저를 실제로 띄운다 — 그 창이 포커스와 화면을 가져가므로 회차 동안 tildaz 를 잠깐
  // HWND_TOPMOST 로 올려 둔다 (AGENTS.md # Windows — 합성 입력으로 … 의 같은 규칙). 끝에 내린다.
  public static void Topmost(IntPtr h, bool on) {
    SetWindowPos(h, new IntPtr(on ? -1 : -2), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);   // NOSIZE|NOMOVE|NOACTIVATE
  }
  // SetForegroundWindow 는 남의 프로세스가 foreground 일 때 조용히 무시된다 — 그래서 **창 안을 한 번
  // 클릭**해 되찾는다 (render-ab-shot_windows.ps1 의 같은 폴백). 클릭 자리는 호출자가 주는 중립 지점이라
  // 링크 클릭으로 오인되지 않는다.
  public static bool Focus(IntPtr h, int neutralX, int neutralY) {
    for (int k = 0; k < 3; k++) {
      if (GetForegroundWindow() == h) return true;
      SetForegroundWindow(h);
      System.Threading.Thread.Sleep(350);
    }
    if (neutralX >= 0) {
      var p = new POINT(); p.x = neutralX; p.y = neutralY; ClientToScreen(h, ref p);
      MoveTo(p.x, p.y, 1);
      System.Threading.Thread.Sleep(150);
      ClickHere();
      System.Threading.Thread.Sleep(400);
    }
    return GetForegroundWindow() == h;
  }
  public static POINT ClientToScreenPt(IntPtr h, int x, int y) {
    var p = new POINT(); p.x = x; p.y = y; ClientToScreen(h, ref p); return p;
  }
}
"@
[TzLink]::MakeDpiAware()

$Out = Join-Path $env:TEMP "tildaz-link-check\$Mode"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
Get-ChildItem $Out -Filter *.png -ErrorAction SilentlyContinue | Remove-Item -Force
$Log = Join-Path $env:APPDATA "tildaz-dev\tildaz_stress.log"
$Cfg9 = Join-Path $env:APPDATA "tildaz-dev\config_9.toml"
if (Test-Path $Cfg9) { throw "config_9.toml 이 이미 있다 — 사용자 설정을 건드리지 않으려고 멈춘다: $Cfg9" }
if (-not (Test-Path $Screen)) { throw "화면 스크립트 없음: $Screen" }
if (-not (Test-Path $Bin)) { throw "바이너리 없음: $Bin" }

# 인스턴스 9 만 내린다 — 명령줄에 `--instance 9` 가 있는 tildaz 만. **정말 사라졌는지 확인한다** —
# 종료가 늦으면 다음 `zig build` 가 `zig-outin	ildaz.exe` 를 못 덮어 `AccessDenied` 로 떨어진다
# (2026-09-15 실측 — 회차 뒤 한 프로세스가 남아 빌드가 막혔다).
function Stop-Tz {
    Get-CimInstance Win32_Process -Filter "Name like 'tildaz%'" |
        Where-Object { $_.CommandLine -match '--instance 9' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 5000) {
        $left = @(Get-CimInstance Win32_Process -Filter "Name like 'tildaz%'" |
            Where-Object { $_.CommandLine -match '--instance 9' })
        if ($left.Count -eq 0) { return }
        Start-Sleep -Milliseconds 200
    }
    "⚠️ 인스턴스 9 가 5 초 안에 안 내려갔다 — 다음 빌드가 막힐 수 있다"
}
function Parse-Pt([string]$s, [string]$name) {
    if (-not $s) { throw "$name 좌표가 없다 — probe 캡처에서 읽어 -$name x,y 로 준다" }
    $a = $s.Split(',')
    if ($a.Count -ne 2) { throw "$name 좌표 형식은 x,y 다: $s" }
    return @([int]$a[0], [int]$a[1])
}
# `[link] opening link:` 줄 수.
function Get-OpenCount {
    if (-not (Test-Path $Log)) { return 0 }
    return @(Get-Content $Log -Encoding UTF8 | Where-Object { $_ -match 'opening link' }).Count
}
function Get-OpenLast {
    if (-not (Test-Path $Log)) { return '' }
    $l = @(Get-Content $Log -Encoding UTF8 | Where-Object { $_ -match 'opening link' })
    if ($l.Count -eq 0) { return '' }
    return ($l[-1] -replace '.*opening link:\s*', '')
}

$stale = [TzLink]::CloseStaleErrorDialogs()
if ($stale -gt 0) { "앞선 회차의 오류 다이얼로그 $stale 개를 닫았다"; Start-Sleep -Milliseconds 500 }
Stop-Tz; Start-Sleep -Milliseconds 500
if (Test-Path $Log) { Move-Item $Log (Join-Path $Out "log_prev.txt") -Force }

if ($Mode -eq 'B' -or $Mode -eq 'C') { $env:TZ_MOUSE = "1" } else { Remove-Item Env:\TZ_MOUSE -ErrorAction SilentlyContinue }
$cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File $Screen"
$p = Start-Process -FilePath (Resolve-Path $Bin) -PassThru -ArgumentList '--instance', '9', '-e', "`"$cmd`"", '-size', $Size
$h = [IntPtr]::Zero
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($h -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 15000) {
    Start-Sleep -Milliseconds 150
    if ($p.HasExited) { break }
    $h = [TzLink]::FindWindowOfPid([uint32]$p.Id)
}
if ($p.HasExited) { Remove-Item Env:\TZ_MOUSE -ErrorAction SilentlyContinue; throw "앱이 먼저 끝남 exit=$($p.ExitCode)" }
if ($h -eq [IntPtr]::Zero) { Stop-Tz; Remove-Item Env:\TZ_MOUSE -ErrorAction SilentlyContinue; throw "창을 못 찾음" }
Start-Sleep -Seconds $Wait

$cr = New-Object TzLink+RECT
[void][TzLink]::GetClientRect($h, [ref]$cr)
$wr = New-Object TzLink+RECT
[void][TzLink]::GetWindowRect($h, [ref]$wr)
"창: hwnd=$h  window=$($wr.R - $wr.L)x$($wr.B - $wr.T) @ $($wr.L),$($wr.T)  client=$($cr.R - $cr.L)x$($cr.B - $cr.T)"
$initLine = ''
if (Test-Path $Log) { $initLine = [string](Get-Content $Log -Encoding UTF8 | Where-Object { $_ -match 'window initialized' } | Select-Object -First 1) }
if ($initLine) { "  " + ($initLine -replace '^\[[^\]]+\]\s*', '') }

if ($Mode -eq 'probe') {
    $shot = Join-Path $Out "probe.png"
    $bmp = [TzLink]::Capture($h); $bmp.Save($shot, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    "캡처: $shot"
    "  (클라이언트 원점은 창 좌상단에서 x=$($wr.L * 0) 기준 — PrintWindow 는 창 전체를 찍으므로 비클라이언트 여백을 감안한다)"
    Stop-Tz
    "정리: 인스턴스 9 종료. config_9.toml 존재=" + (Test-Path $Cfg9)
    return
}

$LinkPt = Parse-Pt $Link 'Link'
$Osc8Pt = Parse-Pt $Osc8 'Osc8'
$PlainPt = Parse-Pt $Plain 'Plain'
# 중립 지점 — 창 안의 링크가 아닌 자리 (맨 아래 줄). hover 를 확실히 벗긴다.
$NeutralPt = @([int](($cr.R - $cr.L) / 2), [int](($cr.B - $cr.T) - 8))

if (-not [TzLink]::Focus($h, $NeutralPt[0], $NeutralPt[1])) { Stop-Tz; Remove-Item Env:\TZ_MOUSE -ErrorAction SilentlyContinue; throw "포커스를 못 잡음 — 다른 창이 앞에 있다" }
[TzLink]::Topmost($h, $true)

$script:shotN = 0
function Shot([string]$tag) {
    $script:shotN++
    $f = Join-Path $Out ("{0:d2}_{1}.png" -f $script:shotN, $tag)
    $bmp = [TzLink]::Capture($h); $bmp.Save($f, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    return $f
}
# 포커스 가드. A2 가 띄운 브라우저처럼 **우리가 만든 창**이 앞을 가져갈 수 있으므로 한 번 되찾아 보고,
# 그래도 안 되면 멈춘다 — 합성 입력이 남의 창으로 가는 것보다 회차를 버리는 편이 낫다.
function Guard {
    if ([TzLink]::GetForegroundWindow() -eq $h) { return }
    if ([TzLink]::Focus($h, $NeutralPt[0], $NeutralPt[1])) { Start-Sleep -Milliseconds 300; return }
    Stop-Tz; Remove-Item Env:\TZ_MOUSE -ErrorAction SilentlyContinue
    throw "포커스를 잃었고 되찾지 못했다 — 회차 중단"
}
function MoveClient($pt, [int]$steps = 4) {
    Guard
    $s = [TzLink]::ClientToScreenPt($h, $pt[0], $pt[1])
    [TzLink]::MoveTo($s.x, $s.y, $steps)
    Start-Sleep -Milliseconds 350
}
$results = @()
function Record([string]$id, [string]$what, [string]$expect, [string]$got, [bool]$ok) {
    $script:results += [pscustomobject]@{ id = $id; what = $what; expect = $expect; got = $got; ok = $ok }
    "{0,-3} {1,-46} {2}  {3}" -f $id, $what, $(if ($ok) { "PASS" } else { "FAIL" }), $got
}

MoveClient $NeutralPt 2
$base = Shot "base"

if ($Mode -eq 'A') {
    # A1 — URL 위 hover: 밑줄 + 손 커서
    MoveClient $LinkPt 5
    $s = Shot "A1_hover_text"
    $bb = ""; $d = [TzLink]::Diff($base, $s, [ref]$bb)
    $cur = [TzLink]::CursorName()
    Record "A1" "자동 검출 URL hover — 밑줄 · 손 커서" ">0 px · hand" "$d px ($bb) · cursor=$cur" ($d -gt 0 -and $cur -eq 'hand')

    # A3 — OSC 8
    MoveClient $NeutralPt 2; Start-Sleep -Milliseconds 400
    $base2 = Shot "base2"
    MoveClient $Osc8Pt 5
    $s = Shot "A3_hover_osc8"
    $bb = ""; $d = [TzLink]::Diff($base2, $s, [ref]$bb)
    $cur = [TzLink]::CursorName()
    $n0 = Get-OpenCount
    Guard; [TzLink]::ClickHere(); Start-Sleep -Seconds 3
    $n1 = Get-OpenCount
    $last = Get-OpenLast
    Record "A3" "OSC 8 링크 hover + 클릭" ">0 px · hand · +1" "$d px · cursor=$cur · +$($n1 - $n0) · $last" ($d -gt 0 -and $cur -eq 'hand' -and ($n1 - $n0) -eq 1 -and $last -match 'x-tildaz-test')

    # A4 — 링크가 아닌 글자
    MoveClient $NeutralPt 2; Start-Sleep -Milliseconds 400
    $base3 = Shot "base3"
    MoveClient $PlainPt 5
    $s = Shot "A4_hover_plain"
    $bb = ""; $d = [TzLink]::Diff($base3, $s, [ref]$bb)
    $cur = [TzLink]::CursorName()
    $n0 = Get-OpenCount
    Guard; [TzLink]::ClickHere(); Start-Sleep -Seconds 3
    $n1 = Get-OpenCount
    Record "A4" "링크 아닌 글자 — 밑줄 없음 · I-beam · 안 열림" "0 px · ibeam · +0" "$d px · cursor=$cur · +$($n1 - $n0)" ($d -eq 0 -and $cur -eq 'ibeam' -and ($n1 - $n0) -eq 0)

    # A5 — 드래그 선택은 링크를 열지 않는다
    MoveClient $NeutralPt 2; Start-Sleep -Milliseconds 400
    $n0 = Get-OpenCount
    Guard
    $s0 = [TzLink]::ClientToScreenPt($h, $LinkPt[0], $LinkPt[1])
    $s1 = [TzLink]::ClientToScreenPt($h, $LinkPt[0] + 90, $LinkPt[1])
    [TzLink]::DragTo($s0.x, $s0.y, $s1.x, $s1.y)
    Start-Sleep -Seconds 3
    $n1 = Get-OpenCount
    [void](Shot "A5_drag")
    Record "A5" "URL 위 드래그 — 선택이지 열기가 아님" "+0" "+$($n1 - $n0)" (($n1 - $n0) -eq 0)

    # A2 — 수식키 없이 클릭: 실제로 열린다. **맨 뒤에 둔다** — 여기서만 브라우저가 뜨는데, 그 창이
    # foreground 를 가져가면 뒤따르는 케이스의 합성 입력이 그쪽으로 간다 (첫 회차에서 A4 가 그렇게 막혔다).
    MoveClient $NeutralPt 2; Start-Sleep -Milliseconds 400
    MoveClient $LinkPt 5
    $n0 = Get-OpenCount
    Guard; [TzLink]::ClickHere(); Start-Sleep -Seconds 5
    $n1 = Get-OpenCount
    Record "A2" "수식키 없이 좌클릭 — 브라우저로 열림" "+1" "+$($n1 - $n0)  last=$(Get-OpenLast)" (($n1 - $n0) -eq 1)
}

if ($Mode -eq 'B') {
    # B1 — 수식키 없이 hover: 아무 일도 없음
    MoveClient $LinkPt 5
    $s = Shot "B1_hover_nomod"
    $bb = ""; $d = [TzLink]::Diff($base, $s, [ref]$bb)
    $cur = [TzLink]::CursorName()
    Record "B1" "앱이 마우스를 잡음 · 수식키 없이 hover" "0 px · ibeam" "$d px ($bb) · cursor=$cur" ($d -eq 0 -and $cur -eq 'ibeam')

    # B2 — 마우스를 멈춘 채 Ctrl 누르기
    $noMod = Shot "B2_before"
    Guard; [TzLink]::KeyDownUp(0x11, $true); Start-Sleep -Milliseconds 700
    $s = Shot "B2_ctrl_down"
    $bb = ""; $d = [TzLink]::Diff($noMod, $s, [ref]$bb)
    $cur = [TzLink]::CursorName()
    Record "B2" "마우스 정지 · Ctrl 누름 — 즉시 밑줄 · 손 커서" ">0 px · hand" "$d px ($bb) · cursor=$cur" ($d -gt 0 -and $cur -eq 'hand')

    # B4 — Ctrl 누른 채 클릭 (B3 보다 먼저 — Ctrl 을 떼면 다시 눌러야 한다)
    $n0 = Get-OpenCount
    Guard; [TzLink]::ClickHere(); Start-Sleep -Seconds 3
    $n1 = Get-OpenCount
    $last = Get-OpenLast
    # 클릭 자리는 `-Link` (자동 검출 URL) 이므로 기대 URL 도 그쪽이다. OSC 8 은 A3 에서 본다.
    Record "B4" "Ctrl + 클릭 — 열림" "+1 · 그 URL" "+$($n1 - $n0) · $last" (($n1 - $n0) -eq 1 -and $last -match 'example\.com/pr/B')

    # B3 — Ctrl 떼기: 원상복구
    Guard; [TzLink]::KeyDownUp(0x11, $false); Start-Sleep -Milliseconds 700
    $s = Shot "B3_ctrl_up"
    $bb = ""; $d = [TzLink]::Diff($noMod, $s, [ref]$bb)
    $cur = [TzLink]::CursorName()
    Record "B3" "Ctrl 뗌 — 즉시 원상복구" "0 px · ibeam" "$d px ($bb) · cursor=$cur" ($d -eq 0 -and $cur -eq 'ibeam')

    # B5 — Ctrl 없이 클릭: 안 열리고 앱으로 간다
    $n0 = Get-OpenCount
    Guard; [TzLink]::ClickHere(); Start-Sleep -Seconds 3
    $n1 = Get-OpenCount
    Record "B5" "Ctrl 없이 클릭 — 안 열리고 앱 것" "+0" "+$($n1 - $n0)" (($n1 - $n0) -eq 0)
}

# 회차 C — B 와 같은 상태 (앱이 마우스를 잡음) 인데 **Ctrl 앞에 클릭이 한 번 들어간다.**
# 클릭이 앱으로 라우팅된 뒤에도 수식키 훅이 그대로 듣는지 (`link_pointer` 가 살아 있는지) 를 본다.
# C3 (정지 상태에서 Ctrl) 과 C4 (Ctrl 유지 + 1 px 이동) 가 같은 결과여야 정상이다.
if ($Mode -eq 'C') {
    MoveClient $LinkPt 5
    $c0 = Shot "C1_hover"
    $bb = ""; $d = [TzLink]::Diff($base, $c0, [ref]$bb)
    Record "C1" "hover (수식키 없음)" "0 px · ibeam" "$d px · cursor=$([TzLink]::CursorName())" ($d -eq 0)

    # C2 — Ctrl 없이 클릭. 앱이 가져간다 (열리지 않는다).
    $n0 = Get-OpenCount
    Guard; [TzLink]::ClickHere(); Start-Sleep -Seconds 2
    $n1 = Get-OpenCount
    $c2 = Shot "C2_after_click"
    Record "C2" "Ctrl 없이 클릭 — 앱 것" "+0" "+$($n1 - $n0)" (($n1 - $n0) -eq 0)

    # C3 — **클릭 뒤에** 마우스를 멈춘 채 Ctrl 누름.
    Guard; [TzLink]::KeyDownUp(0x11, $true); Start-Sleep -Milliseconds 900
    $c3 = Shot "C3_ctrl_after_click"
    $bb = ""; $d3 = [TzLink]::Diff($c2, $c3, [ref]$bb)
    $cur3 = [TzLink]::CursorName()
    Record "C3" "클릭 뒤 · 마우스 정지 · Ctrl 누름" ">0 px · hand" "$d3 px ($bb) · cursor=$cur3" ($d3 -gt 0 -and $cur3 -eq 'hand')

    # C4 — Ctrl 을 누른 채 1 px 움직인다. C3 와 결과가 같아야 한다 (움직여야만 되는 것이 아니다).
    $sp = [TzLink]::ClientToScreenPt($h, $LinkPt[0] + 1, $LinkPt[1])
    [TzLink]::MoveTo($sp.x, $sp.y, 1); Start-Sleep -Milliseconds 700
    $c4 = Shot "C4_ctrl_after_move"
    $bb = ""; $d4 = [TzLink]::Diff($c2, $c4, [ref]$bb)
    $cur4 = [TzLink]::CursorName()
    Record "C4" "Ctrl 유지 + 1 px 이동" ">0 px · hand" "$d4 px ($bb) · cursor=$cur4" ($d4 -gt 0 -and $cur4 -eq 'hand')

    Guard; [TzLink]::KeyDownUp(0x11, $false); Start-Sleep -Milliseconds 400
}

# 회차 D — 누른 뒤 미끄러진 클릭 (#647, 2026-09-15 사용자 발견). 칸이 좁아 (150 % 에서 14 px)
# 경계 근처를 누르면 1 px 만 밀려도 칸이 바뀌는데, 그때 선택이 시작되면 뗌에서 링크가 안 열렸다.
# 링크 위에서는 문턱 (`slop_px`) 만 보도록 고쳤으므로 **문턱 안 미끄러짐은 열리고, 넘으면 선택**이다.
if ($Mode -eq 'D') {
    # D1 — 누르고 문턱 안에서 미끄러진 뒤 뗀다 (2 px · 칸 경계를 넘도록 셀 폭의 절반 자리에서 시작).
    $n0 = Get-OpenCount
    Guard
    $s0 = [TzLink]::ClientToScreenPt($h, $LinkPt[0], $LinkPt[1])
    $s1 = [TzLink]::ClientToScreenPt($h, $LinkPt[0] + 3, $LinkPt[1])
    [TzLink]::DragTo($s0.x, $s0.y, $s1.x, $s1.y)
    Start-Sleep -Seconds 4
    $n1 = Get-OpenCount
    Record "D1" "링크 위 3 px 미끄러짐 — 열린다" "+1" "+$($n1 - $n0) · $(Get-OpenLast)" (($n1 - $n0) -eq 1)

    # D2 — 문턱 (6 px) 을 넘게 끌면 선택이고 열리지 않는다.
    MoveClient $NeutralPt 2; Start-Sleep -Milliseconds 400
    $n0 = Get-OpenCount
    Guard
    $s1 = [TzLink]::ClientToScreenPt($h, $LinkPt[0] + 60, $LinkPt[1])
    [TzLink]::DragTo($s0.x, $s0.y, $s1.x, $s1.y)
    Start-Sleep -Seconds 3
    $n1 = Get-OpenCount
    Record "D2" "문턱을 넘게 끌면 선택 — 안 열린다" "+0" "+$($n1 - $n0)" (($n1 - $n0) -eq 0)
}

# 회차 E — 포인터가 **창을 떠날 때** hover 가 풀리는가 (#647 의 Windows 몫).
# macOS 는 `tildazMouseExited`, Linux 는 `handlePointerLeave` 가 그 자리인데 Windows 에는
# `WM_MOUSELEAVE` · `TrackMouseEvent` 가 아예 없었다 — 밑줄이 남으면 그 결함이다.
# 탭바 hover 도 같은 뿌리라 E3 에서 함께 본다 (Linux 의 `handlePointerLeave` 는 둘을 함께 푼다).
if ($Mode -eq 'E') {
    # 창 밖 좌표 — **아무 창도 없는 자리**를 고른다. macOS 회차가 브라우저에 덮인 자리에
    # 포인터를 두고 없는 결함을 만들 뻔했다 (#647 정정 코멘트). 창 오른쪽 · 아래 바깥이면
    # tildaz 는 확실히 벗어나고, 무엇이 그 밑에 있든 *우리 창이 아닌 것*이 판정 조건이다.
    $dpi = 96
    if ($initLine -match 'dpi=(\d+)') { $dpi = [int]$matches[1] }
    $scale = $dpi / 96.0
    $vw = [TzLink]::GetSystemMetrics(78); $vh = [TzLink]::GetSystemMetrics(79)
    $outX = [Math]::Min($wr.R + 120, $vw - 8)
    $outY = [Math]::Min($wr.B + 120, $vh - 8)
    if ($outX -le $wr.R) { $outX = [Math]::Max($wr.L - 120, 8) }
    if ($outY -le $wr.B) { $outY = [Math]::Max($wr.T - 120, 8) }
    "창 밖 지점: $outX,$outY  (창 $($wr.L),$($wr.T)-$($wr.R),$($wr.B) · 가상화면 ${vw}x${vh})"

    # E1 — 링크 위 hover. 밑줄이 떠야 E2 를 판정할 수 있다 (기준).
    MoveClient $LinkPt 5
    $e1 = Shot "E1_hover"
    $bb = ""; $d1 = [TzLink]::Diff($base, $e1, [ref]$bb)
    $cur1 = [TzLink]::CursorName()
    Record "E1" "URL hover — 밑줄 (E2 의 기준)" ">0 px · hand" "$d1 px ($bb) · cursor=$cur1" ($d1 -gt 0 -and $cur1 -eq 'hand')

    # E2 — 창 밖으로 뺀다. 밑줄이 남으면 결함이다.
    Guard
    [TzLink]::MoveTo($outX, $outY, 3)
    Start-Sleep -Seconds 1
    $e2 = Shot "E2_outside"
    $bb = ""; $d2 = [TzLink]::Diff($base, $e2, [ref]$bb)
    Record "E2" "창 밖으로 — 밑줄이 풀린다" "0 px" "$d2 px ($bb)" ($d2 -eq 0)

    # E3 — 탭바 hover 도 같은 뿌리인가 (`App.tab_hover`). **탭 본체에는 hover 강조가 없다** —
    # `updateTabHover` 가 `.tab_area` 를 `.none` 으로 접는다. 강조가 있는 것은 컨트롤 버튼
    # (`+` · `×` · `⋯` · 화살표) 뿐이라 `+` 위에서 본다. 탭을 만들지 않으므로 창 크기도
    # 그대로고 앞의 `base` 를 그대로 기준으로 쓴다.
    $PlusPt = if ($Plus) { Parse-Pt $Plus 'Plus' } else { @([int](($cr.R - $cr.L) - 61 * $scale), [int](13 * $scale)) }
    "컨트롤 `+` 지점: $($PlusPt[0]),$($PlusPt[1])"
    MoveClient $NeutralPt 2; Start-Sleep -Milliseconds 500
    $t0 = Shot "E3_ctrl_base"
    MoveClient $PlusPt 4
    $t1 = Shot "E3_ctrl_hover"
    $bb = ""; $dt1 = [TzLink]::Diff($t0, $t1, [ref]$bb)
    Guard
    [TzLink]::MoveTo($outX, $outY, 3)
    Start-Sleep -Seconds 1
    $t2 = Shot "E3_ctrl_outside"
    $bb2 = ""; $dt2 = [TzLink]::Diff($t0, $t2, [ref]$bb2)
    # 강조가 잡혀야 (dt1 > 0) 풀리는지를 물을 수 있다. 안 잡히면 좌표 문제지 결함이 아니다.
    $ok3 = ($dt1 -gt 0 -and $dt2 -eq 0)
    $note = if ($dt1 -eq 0) { "컨트롤 hover 강조가 안 잡혔다 (좌표 의심 — 판정 불가)" } else { "" }
    Record "E3" "컨트롤 `+` hover — 창 밖에서 풀린다" "hover>0 px · 밖 0 px" "hover=$dt1 px ($bb) · 밖=$dt2 px ($bb2) $note" $ok3
}

# 비활성 창에서의 hover (Windows 만 따로 보는 항목 — #647 7 절).
# 회차 E 는 건너뛴다 — 탭을 만들어 창 크기가 바뀐 뒤라 앞 캡처와 못 견주고, 이 항목은
# 회차 A · B 에서 이미 답이 나와 있다.
"";
if ($Mode -eq 'E') {
    "--- 비활성 창 hover: 회차 E 에서는 건너뜀 ---"
}
else {
"--- 비활성 창 hover (참고 항목) ---"
MoveClient $NeutralPt 2
$inactiveBase = Shot "inactive_base"
$other = Get-Process -Name explorer -ErrorAction SilentlyContinue | Select-Object -First 1
if ($other -and $other.MainWindowHandle -ne 0) { [void][TzLink]::SetForegroundWindow($other.MainWindowHandle) }
Start-Sleep -Milliseconds 600
$nowFg = [TzLink]::GetForegroundWindow()
if ($nowFg -ne $h) {
    $s = [TzLink]::ClientToScreenPt($h, $LinkPt[0], $LinkPt[1])
    [TzLink]::MoveTo($s.x, $s.y, 5)
    Start-Sleep -Milliseconds 600
    $sInact = Shot "inactive_hover"
    $bb = ""; $d = [TzLink]::Diff($inactiveBase, $sInact, [ref]$bb)
    $cur = [TzLink]::CursorName()
    "비활성 상태 hover: 밑줄차이=$d px ($bb) · cursor=$cur"
} else {
    "비활성으로 만들지 못해 건너뜀"
}
}

[TzLink]::Topmost($h, $false)
Stop-Tz; Start-Sleep -Milliseconds 500
Remove-Item Env:\TZ_MOUSE -ErrorAction SilentlyContinue
$stale2 = [TzLink]::CloseStaleErrorDialogs()
if ($stale2 -gt 0) { "회차 뒤 오류 다이얼로그 $stale2 개를 닫았다" }
"";
"결과: {0} PASS / {1} 항목" -f @($results | Where-Object { $_.ok }).Count, $results.Count
"캡처: $Out"
"정리: 인스턴스 9 종료 · config_9.toml 존재=" + (Test-Path $Cfg9)
