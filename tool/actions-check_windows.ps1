# 공통 처리부 (`src/app_actions.zig`, #692) 로 모은 액션을 합성 키 · 마우스로 눌러 자동 판정한다 (Windows · PowerShell 5.1).
#
# ```powershell
# powershell.exe -NoProfile -File tool\actions-check_windows.ps1                 # 다섯 모드 전부
# powershell.exe -NoProfile -File tool\actions-check_windows.ps1 -Mode actions   # 단축키 (Linux `headless-check_linux.sh actions` 의 짝)
# powershell.exe -NoProfile -File tool\actions-check_windows.ps1 -Mode mouse     # ⋯ 메뉴 · + 클릭 · Alt+클릭
# powershell.exe -NoProfile -File tool\actions-check_windows.ps1 -Mode cursor    # 배치가 바뀐 직후의 커서 · 남의 창 커서
# powershell.exe -NoProfile -File tool\actions-check_windows.ps1 -Mode ime       # MS-IME 조합 중 메뉴 · 단축키
# powershell.exe -NoProfile -File tool\actions-check_windows.ps1 -Mode worker    # 전역 hotkey · Alt+F4 · 바깥 앱 열기
# powershell.exe -NoProfile -File tool\actions-check_windows.ps1 -Mode cursor -Bin <수정 전 판>\tildaz.exe   # 대조군
# ```
#
# 칸은 [#692 의 실기 절차](https://github.com/ensky0/tildaz/issues/692) 를 따른다. 판정은 셋이다.
#
# - **앱 로그 줄** — 세 host 가 같은 문장을 남긴다 (`log.zig`). `TILDAZ_VERBOSE=1` 로 띄워 전체화면 · 토글 줄도 받는다.
# - **자식 파일** — 탭 · pane 마다 뜨는 자식 PowerShell 이 시작할 때와 한 줄을 받을 때마다 `$Host.UI.RawUI.WindowSize`
#   를 자기 PID 파일에 적는다. 그래서 *어느 pane · 탭에 키가 갔는지* 와 *격자 크기* 를 파일로 가른다
#   (Linux 의 `stty size` · `touch` 자리). Python 이 없는 기기가 있어 자식도 PowerShell 이다.
# - **창 · 커서** — `GetWindowRect` 와 모니터 · 작업 영역, 그리고 커서 모양.
#
# ## 커서는 `GetCursorInfo` 가 아니라 앱 스레드의 `GetCursor` 로 잰다
#
# 마우스가 연결되지 않은 기기 (`SM_MOUSEPRESENT = 0`) 에서는 Windows 가 커서를 숨겨 `GetCursorInfo` 가 늘
# `hCursor = 0` 이다 — 2026-10-09 데스크탑 Ryzen 7 5700G 에서 `search-bar-check -Mode D` 의 D28 이 그렇게
# 떨어졌다. 대신 `AttachThreadInput` 으로 앱 창 스레드의 입력 상태에 잠깐 붙어 `GetCursor()` 를 읽는다.
# 화면에 안 보여도 **앱이 마지막으로 `SetCursor` 한 모양**이 나온다 (셀 `ibeam` · 분할선 `sizewe` 실측).
#
# ## 안전 규칙 (AGENTS.md `# 실행 환경` · `# Windows — 합성 입력으로 …`)
#
# - `--instance 9` 로만 띄운다. `worker` 말고는 `-e` 측정 인스턴스라 config 를 만들지 않고 전역 hotkey 도 없다.
#   `worker` 모드만 `-e` 없이 띄워 `config_9.toml` 이 생긴다 — dev 판은 `auto_start = false` 가 기본이고 (#683)
#   끝나면 그 파일과 `tildaz_9.log` 를 지운다. 시작할 때 `config_9.toml` 이 이미 있으면 멈춘다.
# - **키 · 마우스마다 포커스 가드**다. foreground 가 우리 창 (또는 우리 앱이 띄운 다이얼로그) 이 아니면 멈춘다.
# - 클립보드를 쓰는 칸은 시작 전 내용을 글자로 보관했다가 되돌린다. 글자가 아닌 것 (그림 등) 이 들어 있으면
#   지우지 않으려고 그 칸을 건너뛴다.
# - 실기라서 **시작 전에 알리고 동의를 받는다** — 모드마다 창이 한 번 뜨고 합성 키 · 마우스가 나간다.
#   `ime` 는 한국어 layout 을 **창 스레드에만** 올린다. `worker` 는 바깥 앱 (메모장 등) 을 띄웠다가 닫는다.
#
# ⚠️ 이 파일은 **UTF-8 BOM** 으로 저장한다 — Windows PowerShell 5.1 은 BOM 없는 `.ps1` 을 ANSI (cp949) 로
# 읽어 한글 주석이 토큰까지 깨뜨린다. C# 은 작은따옴표 here-string 안에 있어 백틱 · `$` 가 풀리지 않는다.

[CmdletBinding()]
param(
    [ValidateSet('all', 'actions', 'mouse', 'cursor', 'ime', 'worker')][string]$Mode = 'all',
    # 기본값은 본문에서 채운다 (`$PSScriptRoot` 는 param 기본값에서 비어 있을 수 있다).
    [string]$Bin = '',
    [int]$Wait = 5,
    # worker 모드에서 단축키 문서 (`Ctrl+Shift+/`) 도 연다 — 기본 브라우저에 탭이 하나 생긴다.
    [switch]$Browser
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
if (-not $Bin) { $Bin = Join-Path $PSScriptRoot '..\zig-out\bin\tildaz.exe' }
if (-not (Test-Path $Bin)) { throw "바이너리 없음: $Bin" }
$Bin = (Resolve-Path $Bin).Path
if ([IntPtr]::Size -ne 8) { throw '32 비트 PowerShell 이다 — INPUT 구조체 배치가 64 비트 기준이다' }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies System.Drawing @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class TzAct {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Explicit, Size = 40)] public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; [FieldOffset(8)] public MOUSEINPUT mi; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] p, int cb);
  [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint c, uint t);
  [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint thread);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr LoadKeyboardLayoutW(string klid, uint flags);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
  [DllImport("user32.dll")] public static extern bool GetMonitorInfoW(IntPtr m, ref MONITORINFO mi);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr GetCursor();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern IntPtr LoadCursorW(IntPtr hInst, IntPtr name);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);

  public static void MakeDpiAware() { try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch {} }

  // 그 pid 의 보이는 · 크기 있는 최상위 창들. 첫 번째가 본 창이다 (다이얼로그는 나중에 생긴다).
  public static IntPtr[] WindowsOfPid(uint pid) {
    var list = new System.Collections.Generic.List<IntPtr>();
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid || !IsWindowVisible(h)) return true;
      RECT r; if (!GetWindowRect(h, out r)) return true;
      if (r.R - r.L < 64 || r.B - r.T < 64) return true;
      list.Add(h); return true;
    }, IntPtr.Zero);
    return list.ToArray();
  }
  public static string Title(IntPtr h) { var s = new System.Text.StringBuilder(200); GetWindowTextW(h, s, 200); return s.ToString(); }
  public static string ClassOf(IntPtr h) { var s = new System.Text.StringBuilder(128); GetClassNameW(h, s, 128); return s.ToString(); }
  public static uint PidOf(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
  public static string Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return r.L + "," + r.T + "," + r.R + "," + r.B; }
  public static string MonitorRect(IntPtr h, bool work) {
    var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
    GetMonitorInfoW(MonitorFromWindow(h, 2), ref mi);
    var r = work ? mi.rcWork : mi.rcMonitor;
    return r.L + "," + r.T + "," + r.R + "," + r.B;
  }

  public static Bitmap Capture(IntPtr h) {
    RECT r; GetWindowRect(h, out r);
    var bmp = new Bitmap(r.R - r.L, r.B - r.T, PixelFormat.Format32bppArgb);
    using (var g = Graphics.FromImage(bmp)) { IntPtr hdc = g.GetHdc(); PrintWindow(h, hdc, 2); g.ReleaseHdc(hdc); }
    return bmp;
  }
  static int[] Pixels(Bitmap b) {
    var d = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    try { var p = new int[b.Width * b.Height]; Marshal.Copy(d.Scan0, p, 0, p.Length); return p; } finally { b.UnlockBits(d); }
  }
  // 영역 안에서 가장 흔한 색 (= 배경) 이 아닌 픽셀 수. 초기화 (화면이 비었는가) 판정용.
  public static long NonBg(string f, int rx, int ry, int rw, int rh) {
    using (var A = new Bitmap(f)) {
      var pa = Pixels(A);
      int x0 = Math.Max(0, rx), y0 = Math.Max(0, ry), x1 = Math.Min(A.Width, rx + rw), y1 = Math.Min(A.Height, ry + rh);
      var hist = new System.Collections.Generic.Dictionary<int, int>();
      for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) { int v = pa[y * A.Width + x]; int c; hist.TryGetValue(v, out c); hist[v] = c + 1; }
      int bg = 0, best = -1; foreach (var kv in hist) if (kv.Value > best) { best = kv.Value; bg = kv.Key; }
      long n = 0; for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) if (pa[y * A.Width + x] != bg) n++;
      return n;
    }
  }
  // 위에서부터 처음으로 배경이 아닌 픽셀이 있는 행 (글자가 시작하는 y). 없으면 -1.
  public static int FirstInkRow(string f, int rx, int ry, int rw, int rh) {
    using (var A = new Bitmap(f)) {
      var pa = Pixels(A);
      int x0 = Math.Max(0, rx), y0 = Math.Max(0, ry), x1 = Math.Min(A.Width, rx + rw), y1 = Math.Min(A.Height, ry + rh);
      int bg = pa[y0 * A.Width + x1 - 1];
      for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) if (pa[y * A.Width + x] != bg) return y;
      return -1;
    }
  }
  // 두 캡처의 다른 픽셀 수와 경계 상자. `yFrom` 위는 안 센다 — 커서 깜빡임이 위쪽 줄에 있다.
  public static long Diff(string a, string b, int yFrom, out string bbox) {
    bbox = "";
    using (var A = new Bitmap(a)) using (var B = new Bitmap(b)) {
      if (A.Width != B.Width || A.Height != B.Height) return -1;
      var pa = Pixels(A); var pb = Pixels(B);
      long n = 0; int x0 = int.MaxValue, y0 = int.MaxValue, x1 = -1, y1 = -1;
      for (int y = Math.Max(0, yFrom); y < A.Height; y++) for (int x = 0; x < A.Width; x++) {
        int i = y * A.Width + x; if (pa[i] == pb[i]) continue;
        n++; if (x < x0) x0 = x; if (y < y0) y0 = y; if (x > x1) x1 = x; if (y > y1) y1 = y;
      }
      if (n > 0) bbox = x0 + "," + y0 + "," + (x1 - x0 + 1) + "," + (y1 - y0 + 1);
      return n;
    }
  }

  // 앱 창 스레드가 마지막으로 정한 커서. 마우스가 없어 화면 커서가 숨겨진 기기에서도 잴 수 있다.
  public static string AppCursor(IntPtr w) {
    uint pid; uint them = GetWindowThreadProcessId(w, out pid); uint me = GetCurrentThreadId();
    AttachThreadInput(me, them, true); IntPtr c = GetCursor(); AttachThreadInput(me, them, false);
    return CursorName(c);
  }
  public static string CursorName(IntPtr c) {
    int[] ids = { 32512, 32513, 32649, 32644, 32645, 32646, 32515, 32650, 32514 };
    string[] nm = { "arrow", "ibeam", "hand", "sizewe", "sizens", "sizeall", "cross", "appstarting", "wait" };
    for (int i = 0; i < ids.Length; i++) if (c == LoadCursorW(IntPtr.Zero, new IntPtr(ids[i]))) return nm[i];
    return c == IntPtr.Zero ? "null" : "other";
  }
  public static IntPtr TopUnder(int x, int y) { var p = new POINT(); p.x = x; p.y = y; return GetAncestor(WindowFromPoint(p), 2); }

  static INPUT Key(ushort vk, uint flags) {
    var i = new INPUT(); i.type = 1; i.ki.wVk = vk; i.ki.wScan = (ushort)MapVirtualKeyW(vk, 0);
    // 방향 · Home · End · PgUp · PgDn · Delete 는 확장 키다 — 빼면 numpad 쪽으로 읽힌다.
    if ((vk >= 0x21 && vk <= 0x28) || vk == 0x2E) flags |= 1;
    i.ki.dwFlags = flags; return i;
  }
  static INPUT Mouse(int nx, int ny, uint flags) { var i = new INPUT(); i.type = 0; i.mi.dx = nx; i.mi.dy = ny; i.mi.dwFlags = flags; return i; }
  static void Norm(int x, int y, out int nx, out int ny) {
    int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
    nx = (int)(((long)(x - vx) * 65535) / (vw > 1 ? vw - 1 : 1)); ny = (int)(((long)(y - vy) * 65535) / (vh > 1 ? vh - 1 : 1));
  }
  const uint MOVE_ABS = 0x0001 | 0x8000 | 0x4000;
  public static void MoveTo(int x, int y) {
    int nx, ny;
    Norm(x + 1, y, out nx, out ny); SendInput(1, new INPUT[] { Mouse(nx, ny, MOVE_ABS) }, Marshal.SizeOf(typeof(INPUT)));
    System.Threading.Thread.Sleep(50);
    Norm(x, y, out nx, out ny); SendInput(1, new INPUT[] { Mouse(nx, ny, MOVE_ABS) }, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void Click() {
    SendInput(1, new INPUT[] { Mouse(0, 0, 0x0002) }, Marshal.SizeOf(typeof(INPUT)));
    System.Threading.Thread.Sleep(80);
    SendInput(1, new INPUT[] { Mouse(0, 0, 0x0004) }, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void Drag(int x0, int y0, int x1, int y1) {
    MoveTo(x0, y0); System.Threading.Thread.Sleep(120);
    SendInput(1, new INPUT[] { Mouse(0, 0, 0x0002) }, Marshal.SizeOf(typeof(INPUT))); System.Threading.Thread.Sleep(120);
    for (int k = 1; k <= 6; k++) { MoveTo(x0 + (x1 - x0) * k / 6, y0 + (y1 - y0) * k / 6); System.Threading.Thread.Sleep(40); }
    System.Threading.Thread.Sleep(120);
    SendInput(1, new INPUT[] { Mouse(0, 0, 0x0004) }, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void KeyDownUp(ushort vk, bool down) { SendInput(1, new INPUT[] { Key(vk, down ? 0u : 2u) }, Marshal.SizeOf(typeof(INPUT))); }
  public static uint Chord(ushort[] vks) {
    var a = new INPUT[vks.Length * 2]; int n = 0;
    foreach (var v in vks) a[n++] = Key(v, 0);
    for (int k = vks.Length - 1; k >= 0; k--) a[n++] = Key(vks[k], 2);
    return SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void Topmost(IntPtr h, bool on) { SetWindowPos(h, new IntPtr(on ? -1 : -2), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); }
  public static POINT ToScreen(IntPtr h, int x, int y) { var p = new POINT(); p.x = x; p.y = y; ClientToScreen(h, ref p); return p; }
  public static bool Focus(IntPtr h, int cx, int cy) {
    for (int k = 0; k < 3; k++) { if (GetForegroundWindow() == h) return true; SetForegroundWindow(h); System.Threading.Thread.Sleep(300); }
    if (cx >= 0) { var p = ToScreen(h, cx, cy); MoveTo(p.x, p.y); System.Threading.Thread.Sleep(150); Click(); System.Threading.Thread.Sleep(400); }
    return GetForegroundWindow() == h;
  }
}
'@
[TzAct]::MakeDpiAware()

$VK = @{
    A = 0x41; B = 0x42; C = 0x43; D = 0x44; E = 0x45; F = 0x46; G = 0x47; H = 0x48; I = 0x49; J = 0x4A
    K = 0x4B; L = 0x4C; M = 0x4D; N = 0x4E; O = 0x4F; P = 0x50; Q = 0x51; R = 0x52; S = 0x53; T = 0x54
    U = 0x55; V = 0x56; W = 0x57; X = 0x58; Y = 0x59; Z = 0x5A; D0 = 0x30; D1 = 0x31; D2 = 0x32; D3 = 0x33
    Shift = 0x10; Ctrl = 0x11; Alt = 0x12; Enter = 0x0D; Esc = 0x1B; Back = 0x08; F1 = 0x70; F4 = 0x73; F12 = 0x7B
    Left = 0x25; Up = 0x26; Right = 0x27; Down = 0x28; Home = 0x24; End = 0x23; PgUp = 0x21; PgDn = 0x22
    Plus = 0xBB; Minus = 0xBD; LBracket = 0xDB; RBracket = 0xDD; Slash = 0xBF; Hangul = 0x15
}
foreach ($k in @($VK.Keys)) { if ($null -eq $VK[$k]) { throw "VK 표에 빈 값: $k" } }   # 오타는 VK 0 으로 조용히 눌린다 (AGENTS.md)

$Root = Join-Path $env:TEMP 'tildaz-actions-check'
$AppDir = Join-Path $env:APPDATA 'tildaz-dev'
$StressLog = Join-Path $AppDir 'tildaz_stress.log'
$Cfg9 = Join-Path $AppDir 'config_9.toml'
$Log9 = Join-Path $AppDir 'tildaz_9.log'

# ---------- 공통 ----------

$script:results = @()
function Record([string]$id, [string]$what, [string]$expect, [string]$got, $ok) {
    $tag = if ($ok -is [string]) { $ok } elseif ($ok) { 'PASS' } else { 'FAIL' }
    $script:results += [pscustomobject]@{ mode = $script:mode; id = $id; what = $what; expect = $expect; got = $got; tag = $tag }
    # Write-Host 로 낸다 — 파이프라인에 내면 값을 돌려주는 함수 (`PaneStep` · `TabCheck`) 의 반환값에 섞인다.
    Write-Host ("{0,-4} {1,-44} {2}  기대 [{3}] 받음 [{4}]" -f $id, $what, $tag, $expect, $got)
}

function Stop-Tz {
    Get-CimInstance Win32_Process -Filter "Name like 'tildaz%'" |
        Where-Object { $_.CommandLine -match '--instance 9' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 5000) {
        $left = @(Get-CimInstance Win32_Process -Filter "Name like 'tildaz%'" | Where-Object { $_.CommandLine -match '--instance 9' })
        if ($left.Count -eq 0) { return }
        Start-Sleep -Milliseconds 200
    }
    "인스턴스 9 가 5 초 안에 안 내려갔다"
}

# 로그 — 표시한 자리 뒤에 새로 생긴 줄만 본다. 순서로 맞추면 한 칸이 빠질 때 뒤가 밀린다.
$script:logBase = 0
function LogLines { if (Test-Path $script:LogPath) { return @(Get-Content $script:LogPath -Encoding UTF8) } else { return @() } }
function LogMark { $script:logBase = (LogLines).Count }
function LogNew { $a = LogLines; if ($a.Count -le $script:logBase) { return @() }; return @($a[$script:logBase..($a.Count - 1)]) }
function LogFind([string]$re) { return @(LogNew | Where-Object { $_ -match $re }) }
function WaitLog([string]$re, [int]$ms = 3000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) { if ((LogFind $re).Count -gt 0) { return $true }; Start-Sleep -Milliseconds 150 }
    return ((LogFind $re).Count -gt 0)
}
function Short([string]$line) { return ($line -replace '^\[[^\]]+\]\s*', '') }

# 자식 파일 — `c_<pid>.txt` 의 줄 수.
function Kids { return @(Get-ChildItem $script:KidDir -Filter 'c_*.txt' -ErrorAction SilentlyContinue | Sort-Object CreationTimeUtc | ForEach-Object { $_.Name }) }
function KidLines([string]$name) { return @(Get-Content (Join-Path $script:KidDir $name) -Encoding UTF8 -ErrorAction SilentlyContinue) }
function KidState { $s = @{}; foreach ($k in Kids) { $s[$k] = (KidLines $k).Count }; return $s }
function WaitKids([int]$n, [int]$ms = 8000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) { if ((Kids).Count -ge $n) { return $true }; Start-Sleep -Milliseconds 150 }
    return ((Kids).Count -ge $n)
}
function StartSize([string]$kid) { $l = KidLines $kid | Where-Object { $_ -match '^start ' } | Select-Object -First 1; if ($l -match '(\d+x\d+)$') { return $matches[1] }; return '' }
# 지금 활성 pane 의 셸에 `word` 한 줄을 보내고, 그 줄을 받은 자식과 그때 크기를 돌려준다.
function SendLine([string]$word, [int]$ms = 4000) {
    $before = KidState
    TzType $word
    TzSend @($VK.Enter) 200
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        foreach ($k in Kids) {
            $lines = @(KidLines $k)
            $old = if ($before.ContainsKey($k)) { $before[$k] } else { 0 }
            if ($lines.Count -le $old) { continue }
            # 줄 앞의 제어 문자는 허용한다 — 초기화가 셸에 보내는 `Ctrl+L` (`0x0c`) 이 `Read-Host` 의 다음 줄에 담긴다.
            $hit = @($lines[$old..($lines.Count - 1)] | Where-Object { $_ -match ('^line [\x00-\x1f]*' + [regex]::Escape($word) + ' ') })
            if ($hit.Count -gt 0 -and $hit[-1] -match '(\d+)x(\d+)$') { return @{ kid = $k; cols = [int]$matches[1]; rows = [int]$matches[2]; size = "$($matches[1])x$($matches[2])"; raw = $hit[-1] } }
        }
        Start-Sleep -Milliseconds 150
    }
    return $null
}

function Shot([string]$tag) {
    $script:shotN++
    $f = Join-Path $script:Out ("{0:d2}_{1}.png" -f $script:shotN, $tag)
    $bmp = [TzAct]::Capture($script:h); $bmp.Save($f, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    return $f
}
function ClientRect { $r = New-Object TzAct+RECT; [void][TzAct]::GetClientRect($script:h, [ref]$r); return @{ w = $r.R; h = $r.B } }

function Guard {
    if ([TzAct]::GetForegroundWindow() -eq $script:h) { return }
    $c = ClientRect
    if ([TzAct]::Focus($script:h, [int]($c.w / 2), [int]($c.h / 3))) { Start-Sleep -Milliseconds 250; return }
    Stop-Tz
    throw "포커스를 잃었고 되찾지 못했다 — 회차 중단 (foreground=$([TzAct]::GetForegroundWindow()))"
}
function TzSend([uint16[]]$chord, [int]$ms = 250) { Guard; [void][TzAct]::Chord($chord); Start-Sleep -Milliseconds $ms }
function TzType([string]$s) {
    foreach ($ch in $s.ToCharArray()) {
        $c = [string]$ch
        if ($c -cmatch '^[a-z]$') { TzSend @([uint16][char]$c.ToUpper()) 70 }
        elseif ($c -match '^[0-9]$') { TzSend @([uint16][char]$c) 70 }
        else { throw "TzType 이 못 보내는 글자: $c" }
    }
}
function MoveClient([int]$x, [int]$y) { $p = [TzAct]::ToScreen($script:h, $x, $y); [TzAct]::MoveTo($p.x, $p.y); Start-Sleep -Milliseconds 300 }
function ClickClient([int]$x, [int]$y) { Guard; MoveClient $x $y; [TzAct]::Click(); Start-Sleep -Milliseconds 700 }

# 우리 앱이 새로 띄운 창 (다이얼로그). 본 창은 뺀다.
function NewDialog([int]$ms = 3000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        $d = @([TzAct]::WindowsOfPid([uint32]$script:p.Id) | Where-Object { $_ -ne $script:h })
        if ($d.Count -gt 0) { return $d[0] }
        Start-Sleep -Milliseconds 150
    }
    return [IntPtr]::Zero
}
# 다이얼로그에 키를 보낸다 — foreground 가 그 다이얼로그일 때만.
function SendToDialog([IntPtr]$d, [uint16[]]$chord) {
    for ($k = 0; $k -lt 3 -and [TzAct]::GetForegroundWindow() -ne $d; $k++) { [void][TzAct]::SetForegroundWindow($d); Start-Sleep -Milliseconds 300 }
    if ([TzAct]::GetForegroundWindow() -ne $d) { return $false }
    [void][TzAct]::Chord($chord); Start-Sleep -Milliseconds 600
    return $true
}
function DismissDialog([IntPtr]$d) {
    if ($d -eq [IntPtr]::Zero) { return 'no dialog' }
    $t = [TzAct]::Title($d)
    if (-not (SendToDialog $d @($VK.Enter))) { return "포커스 못 잡음 ($t)" }
    Start-Sleep -Milliseconds 400
    if ([TzAct]::IsWindow($d) -and [TzAct]::IsWindowVisible($d)) { return "안 닫힘 ($t)" }
    return "closed ($t)"
}

# 앱을 띄운다. `$stress` 면 `-e <자식>` 측정 인스턴스, 아니면 worker.
function Start-App([bool]$stress) {
    Stop-Tz; Start-Sleep -Milliseconds 400
    $script:shotN = 0
    $script:LogPath = if ($stress) { $StressLog } else { $Log9 }
    if (Test-Path $script:LogPath) { Move-Item $script:LogPath (Join-Path $script:Out 'log_prev.txt') -Force }
    $script:KidDir = Join-Path $script:Out 'kids'
    Remove-Item $script:KidDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $script:KidDir | Out-Null
    $env:TILDAZ_VERBOSE = '1'
    try {
        if ($stress) {
            $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$script:ChildPath`" `"$script:KidDir`""
            $script:p = Start-Process -FilePath $Bin -PassThru -ArgumentList '--instance', '9', '-e', "`"$cmd`""
        } else {
            $script:p = Start-Process -FilePath $Bin -PassThru -ArgumentList '--instance', '9'
        }
    } finally { Remove-Item Env:\TILDAZ_VERBOSE -ErrorAction SilentlyContinue }
    $script:h = [IntPtr]::Zero
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($script:h -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 20000) {
        Start-Sleep -Milliseconds 150
        if ($script:p.HasExited) { break }
        $w = @([TzAct]::WindowsOfPid([uint32]$script:p.Id))
        if ($w.Count -gt 0) { $script:h = $w[0] }
    }
    if ($script:p.HasExited) { throw "앱이 먼저 끝남 exit=$($script:p.ExitCode)" }
    if ($script:h -eq [IntPtr]::Zero) { Stop-Tz; throw '창을 못 찾음' }
    # ⚠️ fatal 다이얼로그도 창이라 위에서 잡힌다 — 로그로 먼저 가른다 (AGENTS.md 의 같은 함정).
    Start-Sleep -Seconds $Wait
    $fatal = @(LogLines | Where-Object { $_ -match '\[fatal\]' })
    if ($fatal.Count -gt 0) { Stop-Tz; throw ("앱이 fatal 로 끝났다 — 잡힌 창은 다이얼로그다: " + (Short $fatal[0])) }
    $script:S = 1.0
    $dpi = @(LogLines | Where-Object { $_ -match 'window initialized: dpi=(\d+)' } | Select-Object -First 1)
    if ($dpi.Count -gt 0 -and $dpi[0] -match 'dpi=(\d+)') { $script:S = [int]$matches[1] / 96.0 }
    $cell = @(LogLines | Where-Object { $_ -match 'cell_w=(\d+) cell_h=(\d+)' } | Select-Object -First 1)
    $script:CellW = 14; $script:CellH = 29
    if ($cell.Count -gt 0 -and $cell[0] -match 'cell_w=(\d+) cell_h=(\d+)') { $script:CellW = [int]$matches[1]; $script:CellH = [int]$matches[2] }
    $c = ClientRect
    "창: hwnd=$script:h  rect=$([TzAct]::Rect($script:h))  client=$($c.w)x$($c.h)  scale=$script:S  cell=$($script:CellW)x$($script:CellH)"
    if (-not [TzAct]::Focus($script:h, [int]($c.w / 2), [int]($c.h / 3))) { Stop-Tz; throw '포커스를 못 잡음 — 다른 창이 앞에 있다' }
    [TzAct]::Topmost($script:h, $true)
    if ($stress -and -not (WaitKids 1)) { Stop-Tz; throw "자식이 뜨지 않았다 — $script:KidDir" }
}

# 컨트롤 스트립 `+ x ⋯` (창 오른쪽 위). `link-click-check` · `search-bar-check` 와 같은 계산이다.
function MorePt { $c = ClientRect; return @([int]($c.w - 13 * $script:S), [int](13 * $script:S)) }
function PlusPt { $c = ClientRect; return @([int]($c.w - 61 * $script:S), [int](13 * $script:S)) }
# 메뉴를 열고 키로 항목을 고른다 (#712 — 키 이동이 화면 차례다).
function MenuKeys([uint16[]]$keys) {
    $m = MorePt
    ClickClient $m[0] $m[1]
    foreach ($k in $keys) { TzSend @($k) 150 }
    TzSend @($VK.Enter) 600
}

# 자식 — 시작 크기와 받은 줄마다 크기를 자기 파일에 적는다.
$ChildBody = @'
param([string]$Dir)
$ErrorActionPreference = "Continue"
$enc = New-Object System.Text.UTF8Encoding $false
$f = Join-Path $Dir ("c_{0}.txt" -f $PID)
try {
    function Sz { $s = $Host.UI.RawUI.WindowSize; "{0}x{1}" -f $s.Width, $s.Height }
    [IO.File]::AppendAllText($f, "start " + (Sz) + "`n", $enc)
    for ($i = 0; $i -lt 3; $i++) { Write-Host ("COPYME line{0} COPYME" -f $i) }
    while ($true) {
        $l = Read-Host
        [IO.File]::AppendAllText($f, "line " + $l + " " + (Sz) + "`n", $enc)
    }
} catch {
    [IO.File]::AppendAllText($f + ".err", ($_ | Out-String), $enc)
}
'@

# ---------- 모드: actions ----------

function Run-Actions {
    Start-App $true
    $k1 = @(Kids)[0]
    $single = StartSize $k1
    "첫 자식 $k1 · 시작 크기 $single"

    # A1 · A2 — 복사 · 붙여넣기. 끌어 선택한 뒤 클립보드를 비우고 단축키로 복사한다 (선택이 끝날 때
    # 자동 복사가 있어도 판정이 그것에 기대지 않게).
    $clip = [Windows.Forms.Clipboard]::GetDataObject()
    $hasText = [Windows.Forms.Clipboard]::ContainsText()
    $other = ($null -ne $clip) -and (@($clip.GetFormats()).Count -gt 0) -and -not $hasText
    if ($other) {
        Record 'A1' '복사 (Ctrl+Shift+C)' '클립보드에 선택' '클립보드에 글자가 아닌 것이 있어 건너뜀' 'SKIP'
        Record 'A2' '붙여넣기 (Ctrl+Shift+V)' '셸이 그 글자를 받는다' '건너뜀' 'SKIP'
    } else {
        $savedClip = if ($hasText) { [Windows.Forms.Clipboard]::GetText() } else { $null }
        try {
            $c = ClientRect
            $s0 = Shot 'A1_base'
            $ink = [TzAct]::FirstInkRow($s0, 0, 0, [int]($c.w * 0.6), [int]($script:CellH * 4))
            $y = if ($ink -ge 0) { $ink + [int]($script:CellH * 1.3) } else { [int]($script:CellH * 1.5) }
            Guard
            $a = [TzAct]::ToScreen($script:h, [int]($script:CellW * 1.5), $y)
            $b = [TzAct]::ToScreen($script:h, [int]($script:CellW * 18.5), $y)
            [TzAct]::Drag($a.x, $a.y, $b.x, $b.y); Start-Sleep -Milliseconds 400
            [Windows.Forms.Clipboard]::Clear()
            TzSend @($VK.Ctrl, $VK.Shift, $VK.C) 600
            $got = [Windows.Forms.Clipboard]::GetText()
            Record 'A1' '복사 (Ctrl+Shift+C)' "'line1' 이 든 글자" "'$got'" ($got -match 'line1')
            $before = KidState
            TzSend @($VK.Ctrl, $VK.Shift, $VK.V) 600
            TzSend @($VK.Enter) 300
            $pasted = ''
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while (-not $pasted -and $sw.ElapsedMilliseconds -lt 3000) {
                $l = @(KidLines $k1)
                if ($l.Count -gt $before[$k1]) { $pasted = (@($l[$before[$k1]..($l.Count - 1)]) -join ' | ') }
                Start-Sleep -Milliseconds 150
            }
            Record 'A2' '붙여넣기 (Ctrl+Shift+V)' "셸이 'line1' 을 받는다" "'$pasted'" ($pasted -match 'line1')
        } finally {
            if ($null -ne $savedClip -and $savedClip -ne '') { [Windows.Forms.Clipboard]::SetText($savedClip) } else { [Windows.Forms.Clipboard]::Clear() }
        }
    }

    # A3 — 초기화. 화면이 비어 글자 픽셀이 크게 준다.
    $c = ClientRect
    $r0 = Shot 'A3_before'
    TzSend @($VK.Ctrl, $VK.Shift, $VK.R) 900
    $r1 = Shot 'A3_after'
    $n0 = [TzAct]::NonBg($r0, 0, 0, $c.w, $c.h); $n1 = [TzAct]::NonBg($r1, 0, 0, $c.w, $c.h)
    Record 'A3' '초기화 (Ctrl+Shift+R)' '글자 픽셀이 절반 아래로' "$n0 → $n1 px" ($n0 -gt 0 -and $n1 * 2 -lt $n0)
    # 초기화는 프롬프트를 다시 그리라고 셸에 `Ctrl+L` 을 보낸다 (`SessionCore.resetActive`). `Read-Host` 는 그것을
    # 다음 줄 앞에 담는다.
    $rs = SendLine 'rs'
    $ff = $rs -and $rs.raw.Contains([string][char]12)
    Record 'A3b' '초기화가 셸에 Ctrl+L (0x0c) 을 보낸다' '다음 줄 앞에 0x0c' $(if ($rs) { (([Text.Encoding]::UTF8.GetBytes($rs.raw) | Select-Object -First 8 | ForEach-Object { '{0:x2}' -f $_ }) -join ' ') + ' …' } else { '응답 없음' }) $ff

    # A4 — perf 덤프.
    LogMark; TzSend @($VK.Ctrl, $VK.Shift, $VK.F12) 300
    Record 'A4' 'perf 덤프 (Ctrl+Shift+F12)' '=== snapshot @' $(if (WaitLog '=== snapshot @') { 'snapshot 덤프' } else { '없음' }) (WaitLog '=== snapshot @' 200)

    # A5 — 글자 크기. 크게 → 작게 → 크게 → 되돌리기.
    foreach ($st in @(
            @{ id = 'A5a'; what = '글자 크게 (Ctrl+Shift+=)'; chord = @($VK.Ctrl, $VK.Shift, $VK.Plus); re = 'terminal font size increase — ' },
            @{ id = 'A5b'; what = '글자 작게 (Ctrl+Shift+-)'; chord = @($VK.Ctrl, $VK.Shift, $VK.Minus); re = 'terminal font size decrease — ' },
            @{ id = '';    what = ''; chord = @($VK.Ctrl, $VK.Shift, $VK.Plus); re = 'increase' },
            @{ id = 'A5c'; what = '글자 되돌리기 (Ctrl+Shift+Backspace)'; chord = @($VK.Ctrl, $VK.Shift, $VK.Back); re = 'terminal font size reset — ' })) {
        LogMark; TzSend ([uint16[]]$st.chord) 300
        $ok = WaitLog $st.re
        if ($st.id) { Record $st.id $st.what $st.re $(if ($ok) { Short (@(LogFind $st.re)[0]) } else { '로그 없음' }) $ok }
    }
    $sz = SendLine 'fz'
    Record 'A5d' '되돌린 뒤 격자가 처음과 같다' $single $(if ($sz) { $sz.size } else { '응답 없음' }) ($sz -and $sz.size -eq $single)

    # A6 — 전체화면 두 종류. 창이 모니터 / 작업 영역과 같아졌다가 돌아온다.
    $orig = [TzAct]::Rect($script:h)
    $mon = [TzAct]::MonitorRect($script:h, $false); $work = [TzAct]::MonitorRect($script:h, $true)
    TzSend @($VK.Alt, $VK.Enter) 900;               $r = [TzAct]::Rect($script:h); Record 'A6a' '전체화면 (Alt+Enter)' $mon $r ($r -eq $mon)
    TzSend @($VK.Alt, $VK.Enter) 900;               $r = [TzAct]::Rect($script:h); Record 'A6b' '전체화면 끄기' $orig $r ($r -eq $orig)
    TzSend @($VK.Shift, $VK.Alt, $VK.Enter) 900;    $r = [TzAct]::Rect($script:h); Record 'A6c' '작업영역 전체화면 (Shift+Alt+Enter)' $work $r ($r -eq $work)
    TzSend @($VK.Shift, $VK.Alt, $VK.Enter) 900;    $r = [TzAct]::Rect($script:h); Record 'A6d' '작업영역 끄기' $orig $r ($r -eq $orig)

    # A7 — About.
    Guard; [void][TzAct]::Chord(@($VK.Ctrl, $VK.Shift, $VK.I))
    $d = NewDialog
    $t = if ($d -ne [IntPtr]::Zero) { [TzAct]::Title($d) } else { '' }
    Record 'A7' 'About (Ctrl+Shift+I)' 'About 창' $(if ($t) { "'$t'" } else { '창 없음' }) ($t -match 'About')
    if ($d -ne [IntPtr]::Zero) { "  닫기: $(DismissDialog $d)" }

    # B — pane. Linux 회차와 같은 순서다.
    function PaneStep([string]$id, [string]$what, [uint16[]]$keys, [string]$re) {
        LogMark; TzSend $keys 300
        $ok = WaitLog $re
        Record $id $what $re $(if ($ok) { Short (@(LogFind $re)[0]) } else { '로그 없음' }) $ok
        return $ok
    }
    [void](PaneStep 'B1' '분할 오른쪽' @($VK.Ctrl, $VK.Shift, $VK.Right) 'split right — tab 0 has 2 panes')
    $okKid = WaitKids 2
    Record 'B1b' '분할한 pane 에 자식이 뜬다' '자식 2 개' "$((Kids).Count) 개" $okKid
    [void](PaneStep 'B2' '분할 아래' @($VK.Ctrl, $VK.Shift, $VK.Down) 'split down — tab 0 has 3 panes')
    [void](PaneStep 'B3' '포커스 위 (Alt+Up)' @($VK.Alt, $VK.Up) 'focus up — active pane')
    $sa = SendLine 'ra'
    TzSend @($VK.Shift, $VK.Alt, $VK.Left) 700
    $sb = SendLine 'rb'
    $okR = $sa -and $sb -and $sa.kid -eq $sb.kid -and $sa.rows -eq $sb.rows -and ($sb.cols - $sa.cols) -eq 1
    Record 'B4' '크기 왼쪽 (Shift+Alt+Left) — 열 +1' 'cols +1' $(if ($sa -and $sb) { "$($sa.size) → $($sb.size)" } else { '응답 없음' }) $okR
    [void](PaneStep 'B5' '균등 (Shift+Alt+0)' @($VK.Shift, $VK.Alt, $VK.D0) 'equalize — 3 panes')
    [void](PaneStep 'B6' '최대화 켜기 (Ctrl+Shift+Z)' @($VK.Ctrl, $VK.Shift, $VK.Z) 'zoom on — active pane')
    $sz = SendLine 'zm'
    Record 'B6b' '최대화한 pane 이 탭 전체 격자다' $single $(if ($sz) { $sz.size } else { '응답 없음' }) ($sz -and $sz.size -eq $single)
    [void](PaneStep 'B7' '최대화 끄기' @($VK.Ctrl, $VK.Shift, $VK.Z) 'zoom off — active pane')
    LogMark; TzSend @($VK.Ctrl, $VK.Shift, $VK.X) 1500
    $ended = (LogFind 'shell exited').Count
    Record 'B8' 'pane 닫기 (Ctrl+Shift+X)' 'shell exited 1 줄' "$ended 줄" ($ended -eq 1)
    # 너무 좁아질 때까지 오른쪽으로 가른다 → 거부 + 다이얼로그.
    $rejected = $false; $tries = 0; $last = ''
    while (-not $rejected -and $tries -lt 6) {
        $tries++
        LogMark; Guard; [void][TzAct]::Chord(@($VK.Ctrl, $VK.Shift, $VK.Right)); Start-Sleep -Milliseconds 700
        if ((LogFind 'split right rejected: pane would be under').Count -gt 0) { $rejected = $true; break }
        $s = @(LogFind 'split right — tab 0 has'); if ($s.Count -gt 0) { $last = Short $s[0] }
    }
    $d = if ($rejected) { NewDialog } else { [IntPtr]::Zero }
    $t = if ($d -ne [IntPtr]::Zero) { [TzAct]::Title($d) } else { '' }
    Record 'B9' '너무 좁은 분할 — 거부 + 다이얼로그' 'rejected · Not enough room' "rejected=$rejected (시도 $tries · 마지막 성공 '$last') · 창 '$t'" ($rejected -and $t -match 'Not enough room')
    if ($d -ne [IntPtr]::Zero) { "  닫기: $(DismissDialog $d)" }
    $okB10 = PaneStep 'B10' '거부 뒤에도 분할이 된다 (아래)' @($VK.Ctrl, $VK.Shift, $VK.Down) 'split down — tab 0 has \d+ panes'
    $tab0Panes = 0
    $sp = @(LogFind 'split down — tab 0 has (\d+) panes')
    if ($sp.Count -gt 0 -and $sp[-1] -match 'has (\d+) panes') { $tab0Panes = [int]$matches[1] }

    # C — 검색. 바가 열려 있으면 글자는 입력칸으로 간다 → 어느 자식도 그 줄을 안 받는다.
    TzSend @($VK.Ctrl, $VK.Shift, $VK.F) 700
    $r = SendLine 'zq' 1500
    Record 'C1' '검색 (Ctrl+Shift+F) — 글자가 입력칸으로' '셸에 안 닿는다' $(if ($r) { "셸 $($r.kid) 가 받았다" } else { '안 닿음' }) ($null -eq $r)
    TzSend @($VK.Esc) 500
    $r = SendLine 'zw'
    Record 'C2' '검색 닫기 (Esc) — 뒤 글자는 셸로' '셸이 받는다' $(if ($r) { "$($r.kid)" } else { '안 닿음' }) ($null -ne $r)

    # D — 탭.
    $tab1 = @(Kids)
    TzSend @($VK.Ctrl, $VK.Shift, $VK.T) 300
    $okT = WaitKids ($tab1.Count + 1)
    $k2 = @(Kids | Where-Object { $tab1 -notcontains $_ }) | Select-Object -First 1
    Record 'D1' '새 탭 (Ctrl+Shift+T)' '새 자식' $(if ($k2) { $k2 } else { '없음' }) ($okT -and $k2)
    Start-Sleep -Milliseconds 800
    function TabCheck([string]$id, [string]$what, [uint16[]]$keys, [string]$word, [bool]$wantTab1) {
        TzSend $keys 500
        $r = SendLine $word
        $inT1 = $r -and ($tab1 -contains $r.kid)
        $ok = $r -and ($(if ($wantTab1) { $inT1 } else { $r.kid -eq $k2 }))
        Record $id $what $(if ($wantTab1) { '첫 탭의 셸' } else { "새 탭 $k2" }) $(if ($r) { $r.kid } else { '응답 없음' }) $ok
        return $r
    }
    [void](TabCheck 'D2' '탭 전환 Alt+1' @($VK.Alt, $VK.D1) 'ta' $true)
    $t2 = TabCheck 'D3' '탭 전환 Alt+2' @($VK.Alt, $VK.D2) 'tb' $false
    [void](TabCheck 'D4' '이전 탭 (Ctrl+Shift+[)' @($VK.Ctrl, $VK.Shift, $VK.LBracket) 'tc' $true)
    [void](TabCheck 'D5' '다음 탭 (Ctrl+Shift+])' @($VK.Ctrl, $VK.Shift, $VK.RBracket) 'td' $false)
    [void](TabCheck 'D6' '다음 탭 — 끝에서 돈다' @($VK.Ctrl, $VK.Shift, $VK.RBracket) 'te' $true)
    [void](TabCheck 'D7' '다음 탭 (Ctrl+PgDn)' @($VK.Ctrl, $VK.PgDn) 'tf' $false)
    [void](TabCheck 'D8' '이전 탭 (Ctrl+PgUp)' @($VK.Ctrl, $VK.PgUp) 'tg' $true)
    # D9 — 갈린 탭 (지금 첫 탭) 에서 새 탭. 새 셸은 처음부터 탭 전체 격자다 (`leafRect`).
    $before = @(Kids)
    TzSend @($VK.Ctrl, $VK.Shift, $VK.T) 300
    [void](WaitKids ($before.Count + 1))
    $k3 = @(Kids | Where-Object { $before -notcontains $_ }) | Select-Object -First 1
    Start-Sleep -Milliseconds 800
    $start3 = if ($k3) { StartSize $k3 } else { '' }
    $now3 = SendLine 'lr'
    $want = if ($t2) { $t2.size } else { '?' }
    Record 'D9' '갈린 탭에서 새 탭 — 처음부터 탭 전체' "시작 = 지금 = 탭 2 ($want)" "시작 $start3 · 지금 $(if ($now3) { $now3.size } else { '?' })" ($k3 -and $now3 -and $start3 -eq $now3.size -and $start3 -eq $want)
    # D10 — 첫 탭을 통째로 닫는다 → 그 탭의 셸이 pane 수만큼 끝난다.
    TzSend @($VK.Alt, $VK.D1) 500
    LogMark; TzSend @($VK.Ctrl, $VK.Shift, $VK.W) 2500
    $ended = (LogFind 'shell exited').Count
    Record 'D10' '탭 닫기 (Ctrl+Shift+W)' "shell exited $tab0Panes 줄" "$ended 줄" ($tab0Panes -gt 0 -and $ended -eq $tab0Panes)

    if ($script:p.HasExited) { Record 'Z' '앱이 회차 끝까지 살아 있다' 'alive' 'exited' $false }
    $bad = @(LogLines | Where-Object { $_ -match '\[(fatal|panic)\]' })
    if ($bad.Count -gt 0) { Record 'Z2' 'fatal · panic 없음' '0 줄' (Short $bad[0]) $false }
    Stop-Tz
}

# ---------- 모드: mouse ----------

function Run-Mouse {
    Start-App $true
    $orig = [TzAct]::Rect($script:h)
    $mon = [TzAct]::MonitorRect($script:h, $false)
    # M1 — #712: Home → ↓ 세 번 = Split Left / Right (화면 차례 Show/Hide · New Tab · Close Tab · Split).
    LogMark; MenuKeys @($VK.Home, $VK.Down, $VK.Down, $VK.Down)
    $ok = WaitLog 'split right — tab 0 has 2 panes'
    Record 'M1' '⋯ → Home ↓↓↓ = Split Right (#712)' 'split right — 2 panes' $(if ($ok) { Short (@(LogFind 'split right')[0]) } else { ((LogFind '\[pane\]') | ForEach-Object { Short $_ }) -join ' / ' }) $ok
    # M2 — 메뉴 Fullscreen 은 상태 기준 토글이다. 작업영역을 켠 뒤 메뉴 → 풀린다 (화면 전체로 안 바뀐다).
    TzSend @($VK.Shift, $VK.Alt, $VK.Enter) 900
    $fsUp = @($VK.End, $VK.Up, $VK.Up, $VK.Up, $VK.Up)
    MenuKeys $fsUp; Start-Sleep -Milliseconds 400
    $r = [TzAct]::Rect($script:h)
    Record 'M2' '작업영역 중 ⋯ → Fullscreen = 풀림' $orig $r ($r -eq $orig)
    # M3 — 아무것도 안 켠 상태에서 메뉴 → 화면 전체, 한 번 더 → 원래대로.
    MenuKeys $fsUp; Start-Sleep -Milliseconds 400
    $r = [TzAct]::Rect($script:h); Record 'M3' '⋯ → Fullscreen = 화면 전체' $mon $r ($r -eq $mon)
    MenuKeys $fsUp; Start-Sleep -Milliseconds 400
    $r = [TzAct]::Rect($script:h); Record 'M3b' '⋯ → Fullscreen 한 번 더 = 원래대로' $orig $r ($r -eq $orig)
    # M4 — `+` 클릭 = 새 탭 (분할이 아니다).
    $before = @(Kids); LogMark
    $pp = PlusPt; ClickClient $pp[0] $pp[1]
    $okT = WaitKids ($before.Count + 1)
    $split = (LogFind '\] split ').Count
    Record 'M4' '+ 클릭 = 새 탭' '새 자식 · split 줄 0' "자식 $((Kids).Count - $before.Count) 개 · split 줄 $split" ($okT -and $split -eq 0)
    Start-Sleep -Milliseconds 800
    # M5 — Alt 를 누른 채 `+` = 활성 pane 분할. 탭이 둘이 되며 탭바가 생겼으니 자리를 다시 잰다.
    $pp = PlusPt
    LogMark; Guard; MoveClient $pp[0] $pp[1]
    [TzAct]::KeyDownUp($VK.Alt, $true); Start-Sleep -Milliseconds 150
    [TzAct]::Click(); Start-Sleep -Milliseconds 150
    [TzAct]::KeyDownUp($VK.Alt, $false); Start-Sleep -Milliseconds 300
    $ok = WaitLog 'split (right|down) — tab 1 has 2 panes'
    Record 'M5' 'Alt + 클릭 = 분할' 'split — tab 1 has 2 panes' $(if ($ok) { Short (@(LogFind '\] split ')[0]) } else { '로그 없음' }) $ok
    Stop-Tz
}

# ---------- 모드: cursor ----------

function Run-Cursor {
    Start-App $true
    $c = ClientRect
    $cy = [int]($c.h / 3)
    # X1 — 기준: 셀 위는 I-beam.
    MoveClient ([int]($c.w / 4)) $cy
    Record 'X1' '기준 — 셀 위' 'ibeam' ([TzAct]::AppCursor($script:h)) ([TzAct]::AppCursor($script:h) -eq 'ibeam')

    # X2 — 분할선이 생길 자리에 포인터를 두고 **움직이지 않은 채** 분할 → 곧바로 리사이즈 커서.
    # 먼저 한 번 갈라 분할선 x 를 커서로 찾고, pane 을 닫아 되돌린 뒤 그 자리에서 다시 가른다.
    LogMark; TzSend @($VK.Ctrl, $VK.Shift, $VK.Right) 900
    $sepX = -1
    for ($x = [int]($c.w * 0.40); $x -le [int]($c.w * 0.60); $x += 2) {
        MoveClient $x $cy
        if ([TzAct]::AppCursor($script:h) -eq 'sizewe') { $sepX = $x + 2; break }
    }
    if ($sepX -ge 0) {
        MoveClient $sepX $cy
        if ([TzAct]::AppCursor($script:h) -ne 'sizewe') { $sepX -= 2 }
    }
    TzSend @($VK.Ctrl, $VK.Shift, $VK.X) 1200
    if ($sepX -lt 0) {
        Record 'X2' '분할 직후 커서 (움직이지 않음)' 'sizewe' '분할선 자리를 못 찾음' $false
    } else {
        MoveClient $sepX $cy
        $pre = [TzAct]::AppCursor($script:h)
        Guard; [void][TzAct]::Chord(@($VK.Ctrl, $VK.Shift, $VK.Right)); Start-Sleep -Milliseconds 800
        $post = [TzAct]::AppCursor($script:h)
        Record 'X2' '분할 직후 커서 (움직이지 않음)' 'ibeam → sizewe' "x=$sepX · $pre → $post" ($pre -eq 'ibeam' -and $post -eq 'sizewe')

        # X2b — **Ctrl 이 없는** 배치 단축키. X2 · X3 는 수정 전 판도 통과한다 — 단축키의 `Ctrl` 을 뗄 때
        # #647 의 `refreshCursor` 가 돌아서다 (`window.zig` 의 WM_KEYUP). 그래서 `layoutChanged` 훅의 효과는
        # `Shift+Alt+…` 로만 갈린다. 분할선을 세 칸 왼쪽으로 옮기고 그 자리에 포인터를 둔 뒤 균등 →
        # 분할선이 떠나 그 자리는 셀이 된다.
        TzSend @($VK.Shift, $VK.Alt, $VK.Left) 300; TzSend @($VK.Shift, $VK.Alt, $VK.Left) 300; TzSend @($VK.Shift, $VK.Alt, $VK.Left) 700
        $movedX = -1
        for ($x = $sepX - [int]($script:CellW * 5); $x -le $sepX - 4; $x += 2) {
            MoveClient $x $cy
            if ([TzAct]::AppCursor($script:h) -eq 'sizewe') { $movedX = $x + 2; break }
        }
        if ($movedX -lt 0) {
            Record 'X2b' '균등 (Shift+Alt+0) 직후 커서 — Ctrl 없음' 'sizewe → ibeam' '옮긴 분할선을 못 찾음' $false
        } else {
            MoveClient $movedX $cy
            $pre = [TzAct]::AppCursor($script:h)
            Guard; [void][TzAct]::Chord(@($VK.Shift, $VK.Alt, $VK.D0)); Start-Sleep -Milliseconds 800
            $post = [TzAct]::AppCursor($script:h)
            Record 'X2b' '균등 (Shift+Alt+0) 직후 커서 — Ctrl 없음' 'sizewe → ibeam' "x=$movedX · $pre → $post" ($pre -eq 'sizewe' -and $post -eq 'ibeam')
        }
        TzSend @($VK.Ctrl, $VK.Shift, $VK.X) 1200
    }

    # X3 — 검색바가 뜰 자리 (오른쪽 아래 · 컨트롤 쪽) 에 포인터를 두고 움직이지 않은 채 연다 → 화살표.
    $s0 = Shot 'X3_closed'
    TzSend @($VK.Ctrl, $VK.Shift, $VK.F) 800
    $s1 = Shot 'X3_open'
    TzSend @($VK.Esc) 600
    $bb = ''; $n = [TzAct]::Diff($s0, $s1, [int]($c.h * 0.6), [ref]$bb)
    if (-not $bb) {
        Record 'X3' '검색바 연 직후 커서 (움직이지 않음)' 'ibeam → arrow' '바 자리를 못 찾음' $false
    } else {
        $a = $bb.Split(',') | ForEach-Object { [int]$_ }
        $o = [TzAct]::ToScreen($script:h, 0, 0); $wr = [TzAct]::Rect($script:h).Split(',') | ForEach-Object { [int]$_ }
        $ox = $o.x - $wr[0]; $oy = $o.y - $wr[1]
        $bx = $a[0] - $ox + $a[2] - [int](30 * $script:S); $by = $a[1] - $oy + [int]($a[3] / 2)
        MoveClient $bx $by
        $pre = [TzAct]::AppCursor($script:h)
        Guard; [void][TzAct]::Chord(@($VK.Ctrl, $VK.Shift, $VK.F)); Start-Sleep -Milliseconds 800
        $post = [TzAct]::AppCursor($script:h)
        Record 'X3' '검색바 연 직후 커서 (움직이지 않음)' 'ibeam → arrow' "($bx,$by) · $pre → $post" ($pre -eq 'ibeam' -and $post -eq 'arrow')
        TzSend @($VK.Esc) 500
    }

    # X4 — 포인터가 남의 창 위일 때 Ctrl 을 눌렀다 떼도 우리 커서를 안 정한다 (`WindowFromPoint`).
    # 남의 창은 이 회차가 띄우는 빈 폼이다 (메모장은 Windows 11 에서 사용자 창에 탭으로 붙을 수 있다).
    $wr = [TzAct]::Rect($script:h).Split(',') | ForEach-Object { [int]$_ }
    $fx = if ($wr[0] -ge 700) { $wr[0] - 640 } else { $wr[2] + 40 }
    $fy = $wr[1] + 200
    # 폼은 제목으로 찾는다 — pid 로 찾으면 그 PowerShell 의 **콘솔 창**이 잡힌다 (콘솔 창의
    # `GetWindowThreadProcessId` 는 붙은 프로세스 pid 를 돌려준다). 콘솔 창은 폼을 가리지 않게 숨긴다.
    $formPath = Join-Path $script:Out 'probe-form.ps1'
    $formBody = @'
param([int]$X, [int]$Y)
Add-Type -Name W -Namespace TzForm -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n); [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][TzForm.W]::ShowWindow([TzForm.W]::GetConsoleWindow(), 0)
# 좌표는 물리 px 다 — DPI 비인식이면 150 % 에서 1.5 배로 커져 tildaz 창과 겹친다 (2026-10-10 실측).
[void][TzForm.W]::SetProcessDPIAware()
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object Windows.Forms.Form
$f.Text = 'tz-cursor-probe'; $f.StartPosition = 'Manual'; $f.TopMost = $true
# 십자 커서 — tildaz 가 끼어들 때만 나오는 `arrow` 와 갈린다.
$f.Cursor = [Windows.Forms.Cursors]::Cross
$f.Location = New-Object Drawing.Point($X, $Y); $f.Size = New-Object Drawing.Size(600, 400)
[Windows.Forms.Application]::Run($f)
'@
    [IO.File]::WriteAllText($formPath, $formBody, (New-Object System.Text.UTF8Encoding $true))
    $fp = Start-Process powershell -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$formPath`"", $fx, $fy
    $fh = [IntPtr]::Zero
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # ⚠️ `$null` 은 .NET 문자열 인자로 넘기면 빈 문자열이 된다 — `FindWindowW("", …)` 는 아무것도 못 찾는다.
    while ($fh -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 200; $fh = [TzAct]::FindWindowW([NullString]::Value, 'tz-cursor-probe') }
    # 새 프로세스를 띄우면 몇 초 동안 "앱 시작 중" 커서 (`IDC_APPSTARTING`) 가 걸린다 — 그것이 판정에 섞인다
    # (2026-10-10 첫 회차에서 `other` 로 읽혔다). 사라질 때까지 기다린다.
    Start-Sleep -Seconds 6
    try {
        if ($fh -eq [IntPtr]::Zero) {
            Record 'X4' '남의 창 위 Ctrl — 우리 커서 그대로' '그대로' '폼을 못 띄움' $false
        } else {
            MoveClient ([int]($c.w / 4)) $cy                    # 우리 셀 위 → ibeam
            Guard
            $fr = [TzAct]::Rect($fh).Split(',') | ForEach-Object { [int]$_ }
            $px = [int](($fr[0] + $fr[2]) / 2); $py = [int](($fr[1] + $fr[3]) / 2)
            [TzAct]::MoveTo($px, $py); Start-Sleep -Milliseconds 400
            $under = [TzAct]::TopUnder($px, $py)
            $pre = [TzAct]::AppCursor($script:h)
            $fg = [TzAct]::GetForegroundWindow()
            [TzAct]::KeyDownUp($VK.Ctrl, $true); Start-Sleep -Milliseconds 400
            $mid = [TzAct]::AppCursor($script:h)
            [TzAct]::KeyDownUp($VK.Ctrl, $false); Start-Sleep -Milliseconds 400
            $post = [TzAct]::AppCursor($script:h)
            $cond = ($under -eq $fh) -and ($fg -eq $script:h)
            # 수정 전 코드는 포인터가 클라이언트 밖이어도 그 좌표로 모양을 골라 `SetCursor` 했다 — 밖은 `.other` 라
            # `arrow` 다 (`window.zig` 의 `refreshCursor`). 그래서 `arrow` 가 나오면 tildaz 가 끼어든 것이다.
            # 끼어들지 않으면 폼의 `cross` 나 원래 `ibeam` 이 읽힌다 (어느 쪽인지는 Windows 가 정한다).
            Record 'X4' '남의 창 위 Ctrl — 우리가 커서를 안 정한다' "포인터=폼 · 포커스=우리 · Ctrl 뒤 arrow 아님" "포인터=$(if ($under -eq $fh) { '폼' } else { "$under" }) · 포커스=$(if ($fg -eq $script:h) { '우리' } else { "$fg" }) · $pre → $mid → $post" ($cond -and $mid -ne 'arrow' -and $post -ne 'arrow')
        }
    } finally { Stop-Process -Id $fp.Id -Force -ErrorAction SilentlyContinue }
    Stop-Tz
}

# ---------- 모드: ime ----------

function Run-Ime {
    Start-App $true
    $k1 = @(Kids)[0]
    # 한국어 layout 을 창 스레드에만 올린다 (`search-bar-check -Mode C` 와 같은 방법).
    $hkl = [TzAct]::LoadKeyboardLayoutW('00000412', 0)
    [void][TzAct]::PostMessageW($script:h, 0x0050, [IntPtr]::Zero, $hkl); Start-Sleep -Milliseconds 600
    [uint32]$uiTid = 0; $now = [TzAct]::GetKeyboardLayout([TzAct]::GetWindowThreadProcessId($script:h, [ref]$uiTid))
    if ($now -ne $hkl) { Record 'I0' '창 스레드만 한국어 layout' "0x$('{0:x8}' -f [int64]$hkl)" "0x$('{0:x8}' -f [int64]$now)" $false; Stop-Tz; return }
    # 한글 모드 — 한/영 키를 누르고 `gk` = 하 가 셸에 닿는지로 본다. 영문이면 한 번 더 누른다.
    $mode = ''
    for ($k = 0; $k -lt 2 -and -not $mode; $k++) {
        TzSend @($VK.Hangul) 500
        $before = (KidLines $k1).Count
        TzSend @($VK.G) 120; TzSend @($VK.K) 300; TzSend @($VK.Enter) 600
        $l = @(KidLines $k1)
        if ($l.Count -gt $before) { $last = $l[-1]; if ($last -match '^line 하 ') { $mode = 'hangul' } }
    }
    Record 'I0' '한글 조합이 셸에 닿는다 (gk → 하)' '하' $(if ($mode) { '하' } else { @(KidLines $k1)[-1] }) ($mode -eq 'hangul')
    if (-not $mode) { Stop-Tz; return }
    # 조합 중 (`하` 를 친 채) 액션 → 조합이 원래 탭에 한 번 확정된 뒤 실행된다.
    function ImeCase([string]$id, [string]$what, [scriptblock]$act, [bool]$newTab) {
        $kidsBefore = @(Kids)
        $before = (KidLines $k1).Count
        TzSend @($VK.G) 120; TzSend @($VK.K) 300           # 조합 중
        & $act
        Start-Sleep -Milliseconds 900
        $newKid = ''
        if ($newTab) { [void](WaitKids ($kidsBefore.Count + 1)); $newKid = @(Kids | Where-Object { $kidsBefore -notcontains $_ }) | Select-Object -First 1; Start-Sleep -Milliseconds 800; TzSend @($VK.Alt, $VK.D1) 500 }
        else { TzSend @($VK.Esc) 500 }
        TzSend @($VK.Enter) 700                             # 원래 탭의 셸이 받은 줄을 끝낸다
        $l = @(KidLines $k1)
        $got = if ($l.Count -gt $before) { (@($l[$before..($l.Count - 1)]) -join ' | ') } else { '(없음)' }
        $newGot = if ($newKid) { (@(KidLines $newKid | Where-Object { $_ -match '^line ' }) -join ' | ') } else { '' }
        $ok = ($got -match '^line 하 \d+x\d+$') -and (-not $newTab -or ($newKid -and -not ($newGot -match '하')))
        Record $id $what "원래 탭에 '하' 한 번$(if ($newTab) { ' · 새 탭' } else { '' })" "원래 '$got'$(if ($newTab) { " · 새 탭 $newKid '$newGot'" })" $ok
        if ($newTab -and $newKid) { TzSend @($VK.Alt, $VK.D2) 400; TzSend @($VK.Ctrl, $VK.Shift, $VK.W) 1200 }   # 새 탭을 닫아 다음 칸을 같은 상태로
    }
    ImeCase 'I1' '조합 중 ⋯ → New Tab (메뉴)' { MenuKeys @($VK.Home, $VK.Down) } $true
    ImeCase 'I2' '조합 중 Ctrl+Shift+T' { TzSend @($VK.Ctrl, $VK.Shift, $VK.T) 300 } $true
    ImeCase 'I3' '조합 중 Ctrl+Shift+F' { TzSend @($VK.Ctrl, $VK.Shift, $VK.F) 300 } $false
    Stop-Tz
}

# ---------- 모드: worker ----------

function Run-Worker {
    if (Test-Path $Cfg9) { throw "config_9.toml 이 이미 있다 — 사용자 설정을 건드리지 않으려고 멈춘다: $Cfg9" }
    $runBefore = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).'tildaz-dev'
    try {
        Start-App $false
        $hot = ((Get-Content $Cfg9 -Encoding UTF8 -ErrorAction SilentlyContinue) | Where-Object { $_ -match '^\s*hotkey\s*=' } | Select-Object -First 1)
        $auto = ((Get-Content $Cfg9 -Encoding UTF8 -ErrorAction SilentlyContinue) | Where-Object { $_ -match '^\s*auto_start\s*=' } | Select-Object -First 1)
        "config_9: $hot · $auto"
        $hk = if ($hot -match '"([^"]+)"') { $matches[1].ToLower() } else { '' }
        if ($hk -ne 'f1') { Record 'W0' 'dev instance 9 의 hotkey 는 F1' 'f1' $hk $false; return }
        Record 'W0' 'config_9 auto_start = false (#683)' 'false' $auto ($auto -match 'false')

        # W1 — 전역 hotkey 토글. 첫 F1 은 우리 창이 foreground 일 때만 보낸다 (안 먹으면 그 창으로 간다).
        Guard; LogMark; [void][TzAct]::Chord(@($VK.F1)); Start-Sleep -Milliseconds 900
        $v1 = [TzAct]::IsWindowVisible($script:h)
        $hidden = -not $v1
        if ($hidden) { [void][TzAct]::Chord(@($VK.F1)); Start-Sleep -Milliseconds 1200 }
        $v2 = [TzAct]::IsWindowVisible($script:h)
        Record 'W1' '전역 hotkey F1 두 번 — 숨김 → 보임' '1 → 0 → 1' "1 → $([int]$v1) → $([int]$v2) · 로그 $(((LogFind '\[toggle\]') | ForEach-Object { Short $_ }) -join ' / ')" ($hidden -and $v2)
        if (-not $v2) { return }
        Start-Sleep -Milliseconds 500; [TzAct]::Topmost($script:h, $true); Guard

        # W2 — ⋯ → Show/Hide (첫 항목) → 숨김. F1 로 다시 띄운다.
        MenuKeys @($VK.Home)
        $v1 = [TzAct]::IsWindowVisible($script:h)
        if (-not $v1) { [void][TzAct]::Chord(@($VK.F1)); Start-Sleep -Milliseconds 1200 }
        $v2 = [TzAct]::IsWindowVisible($script:h)
        Record 'W2' '⋯ → Show/Hide → 숨김, F1 → 보임' '0 → 1' "$([int]$v1) → $([int]$v2)" ((-not $v1) -and $v2)
        if (-not $v2) { return }
        Start-Sleep -Milliseconds 500; [TzAct]::Topmost($script:h, $true); Guard

        # W3 — Alt+F4 → 확인 다이얼로그. Esc 로 취소하면 앱은 그대로다.
        [void][TzAct]::Chord(@($VK.Alt, $VK.F4))
        $d = NewDialog
        $t = if ($d -ne [IntPtr]::Zero) { [TzAct]::Title($d) } else { '' }
        $esc = if ($d -ne [IntPtr]::Zero) { SendToDialog $d @($VK.Esc) } else { $false }
        Start-Sleep -Milliseconds 500
        $gone = ($d -ne [IntPtr]::Zero) -and -not ([TzAct]::IsWindow($d) -and [TzAct]::IsWindowVisible($d))
        $alive = -not $script:p.HasExited
        Record 'W3' 'Alt+F4 → 확인 창 · Esc → 그대로' '창 뜸 · 닫힘 · 앱 살아 있음' "창 '$t' · Esc 전달 $esc · 닫힘 $gone · 앱 $alive" ($t -and $gone -and $alive)
        if (-not $alive) { return }
        [TzAct]::Topmost($script:h, $true); Guard

        # W4 · W5 (· W6) — 바깥 앱이 **우리 창 위로** 뜬다. 새로 뜬 창만 닫는다 (사용자 창은 안 건드린다).
        $opens = @(@{ id = 'W4'; what = 'config 열기 (Ctrl+Shift+P)'; chord = @($VK.Ctrl, $VK.Shift, $VK.P) },
                   @{ id = 'W5'; what = 'log 열기 (Ctrl+Shift+L)'; chord = @($VK.Ctrl, $VK.Shift, $VK.L) })
        if ($Browser) { $opens += @{ id = 'W6'; what = '단축키 문서 (Ctrl+Shift+/)'; chord = @($VK.Ctrl, $VK.Shift, $VK.Slash); browser = $true } }
        foreach ($o in $opens) {
            $all0 = New-Object System.Collections.Generic.HashSet[string]
            Get-Process | Where-Object { $_.MainWindowHandle -ne 0 } | ForEach-Object { [void]$all0.Add("$($_.Id)") }
            Guard; [void][TzAct]::Chord([uint16[]]$o.chord); Start-Sleep -Seconds 3
            $fg = [TzAct]::GetForegroundWindow()
            $fgPid = [TzAct]::PidOf($fg)
            $fgT = [TzAct]::Title($fg)
            $ok = ($fg -ne $script:h) -and ($fgPid -ne [uint32]$script:p.Id) -and ($fgPid -ne 0)
            Record $o.id $o.what '바깥 앱이 foreground' "'$fgT' (pid $fgPid)" $ok
            # 이 회차가 띄운 프로세스의 창이면 닫는다. 브라우저는 사용자 창일 수 있어 닫지 않는다.
            if ($ok -and -not $o.browser -and -not $all0.Contains("$fgPid") -and ($fgT -match 'config_9|tildaz_9|\.toml|\.log|열기|Open')) {
                [void][TzAct]::PostMessageW($fg, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero); Start-Sleep -Milliseconds 800
                "  닫음: '$fgT'"
            } elseif ($ok -and -not $o.browser) { "  ⚠️ 남김 (이 회차 전부터 있던 프로세스이거나 제목이 예상 밖): '$fgT'" }
            Start-Sleep -Milliseconds 400; [TzAct]::Topmost($script:h, $true); Guard
        }
    } finally {
        Stop-Tz
        Start-Sleep -Milliseconds 500
        Remove-Item $Cfg9, $Log9 -Force -ErrorAction SilentlyContinue
        $runAfter = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).'tildaz-dev'
        "정리: config_9 존재=$(Test-Path $Cfg9) · tildaz_9.log 존재=$(Test-Path $Log9) · Run 'tildaz-dev' 전 '$runBefore' 후 '$runAfter'"
    }
}

# ---------- 실행 ----------

$modes = if ($Mode -eq 'all') { @('actions', 'mouse', 'cursor', 'ime', 'worker') } else { @($Mode) }
foreach ($m in $modes) {
    $script:mode = $m
    $script:Out = Join-Path $Root $m
    New-Item -ItemType Directory -Force $script:Out | Out-Null
    Get-ChildItem $script:Out -Filter *.png -ErrorAction SilentlyContinue | Remove-Item -Force
    $script:ChildPath = Join-Path $script:Out 'child.ps1'
    [IO.File]::WriteAllText($script:ChildPath, $ChildBody, (New-Object System.Text.UTF8Encoding $true))
    "===== $m  (bin $Bin)"
    try {
        switch ($m) {
            'actions' { Run-Actions }
            'mouse'   { Run-Mouse }
            'cursor'  { Run-Cursor }
            'ime'     { Run-Ime }
            'worker'  { Run-Worker }
        }
    } catch {
        Record 'ERR' "회차 중단" '끝까지' ($_.Exception.Message) $false
        Stop-Tz
    }
    $errs = @(Get-ChildItem (Join-Path $script:Out 'kids') -Filter '*.err' -ErrorAction SilentlyContinue)
    if ($errs.Count -gt 0) { "  ⚠️ 자식 오류: $($errs[0].FullName)" }
}
""
$fails = @($script:results | Where-Object { $_.tag -eq 'FAIL' })
$pass = @($script:results | Where-Object { $_.tag -eq 'PASS' }).Count
$skip = @($script:results | Where-Object { $_.tag -eq 'SKIP' }).Count
"결과: $pass PASS · $($fails.Count) FAIL · $skip SKIP"
$fails | ForEach-Object { "  FAIL [$($_.mode)] $($_.id) $($_.what) — 기대 [$($_.expect)] 받음 [$($_.got)]" }
"캡처 · 자식 파일: $Root"
