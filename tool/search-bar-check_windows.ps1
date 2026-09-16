# 버퍼 검색바 (#646) 를 합성 키 · 마우스로 자동 검증한다 (Windows · PowerShell 5.1).
#
# ```powershell
# tool\search-bar-check_windows.ps1 -Mode probe          # 창을 띄워 바 위치 · 격자를 재고 끝낸다
# tool\search-bar-check_windows.ps1 -Mode A              # 렌더 · 배치 (A1-6)
# tool\search-bar-check_windows.ps1 -Mode B              # 키보드 (B7-17)
# tool\search-bar-check_windows.ps1 -Mode C              # IME (C18-20)
# tool\search-bar-check_windows.ps1 -Mode D              # 마우스 (D23-29)
# tool\search-bar-check_windows.ps1 -Mode E              # 메뉴 (E30-33)
# ```
#
# 항목 번호는 [#646 의 Windows · Linux 실기 절차](https://github.com/ensky0/tildaz/issues/646) 를 그대로 따른다.
#
# 무엇을 하나 —
# - `--instance 9` + `-e <자식.ps1>` 로만 띄운다. `-e` 는 config 를 만들지 않고 (#382) 전역 hotkey 도 등록하지
#   않아 사용자의 instance 0 과 부딪히지 않는다. 로그는 `%APPDATA%\tildaz\tildaz_stress.log` 다.
# - 자식 (PowerShell) 은 `line N FINDMEk` 300 줄과 마지막 줄 `== MAIN READY ==` 를 찍은 뒤 콘솔 입력을
#   **`ENABLE_VIRTUAL_TERMINAL_INPUT`** 으로 바꿔 stdin 을 raw 바이트로 읽어 파일에 기록한다. 그래야
#   "앱이 그 키를 PTY 로 보냈는가" 를 캡처가 아니라 **파일**로 판정할 수 있다 (B14 · B15 · D27).
#   Python 이 없는 기기가 있어 자식도 PowerShell 이다 (`kitty-text-check_windows.ps1` 은 python 을 쓴다).
# - **바 위치는 계산하지 않고 캡처에서 찾는다** — 열기 전 · 후 캡처의 차이 상자가 곧 바다. 창 크기 · 배율 ·
#   스크롤바 유무로 자리가 달라지므로 좌표를 밖에서 계산하면 틀린다 (AGENTS.md Linux 절의 같은 교훈).
# - 판정 셋을 함께 쓴다. ① 캡처 픽셀 (차이 · 색 개수 · 경계 상자) ② 커서 모양 (`GetCursorInfo` 의 `hCursor` 를
#   `LoadCursorW` 공유 핸들과 비교 — `PrintWindow` 는 커서를 안 그린다) ③ 자식이 받은 raw 바이트.
# - **키 · 마우스마다 포커스 가드**다 — foreground 가 tildaz 창이 아니면 멈춘다. 합성 입력은 포커스된 창으로
#   가니 회차 동안 사용자가 다른 창을 만지면 거기에 간다.
#
# 실기라서 **시작 전에 알리고 동의를 받는다** (AGENTS.md `# 실행 환경`) — 모드마다 창이 한 번 뜨고 합성 키 ·
# 마우스가 나간다. C 모드는 한국어 IME layout 을 창 스레드에만 잠깐 올린다.
#
# ⚠️ 이 파일은 **UTF-8 BOM** 으로 저장한다 — Windows PowerShell 5.1 은 BOM 없는 `.ps1` 을 ANSI (cp949) 로
# 읽어 한글 주석이 토큰까지 깨뜨린다.

[CmdletBinding()]
param(
    [ValidateSet('probe', 'A', 'B', 'C', 'D', 'E')][string]$Mode = 'probe',
    [string]$Bin = 'zig-out\bin\tildaz.exe',
    [string]$Size = '88x33',
    [int]$Wait = 7,
    [int]$SizePoint = 0,          # >0 이면 config_9.toml 을 잠깐 만들어 그 폰트 크기로 띄운다 (A3)
    [switch]$Mouse,               # 자식이 DECSET 1000 을 켠다 (D27)
    [switch]$Keep                 # 회차 뒤 앱을 남긴다 (손으로 더 볼 때)
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class TzSearch {
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
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr LoadKeyboardLayoutW(string klid, uint flags);
  [DllImport("user32.dll")] public static extern bool UnloadKeyboardLayout(IntPtr hkl);
  [DllImport("user32.dll")] public static extern int GetKeyboardLayoutList(int n, IntPtr[] list);
  [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint thread);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
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
  // 화면 전체 (다른 창 · IME 후보창까지). PrintWindow 로는 남의 창이 안 찍힌다.
  public static Bitmap CaptureScreen() {
    int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
    var bmp = new Bitmap(vw, vh, PixelFormat.Format32bppArgb);
    using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(vx, vy, 0, 0, new Size(vw, vh));
    return bmp;
  }
  static int[] Pixels(Bitmap b) {
    var d = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    try { var p = new int[b.Width * b.Height]; Marshal.Copy(d.Scan0, p, 0, p.Length); return p; }
    finally { b.UnlockBits(d); }
  }
  // 두 캡처의 다른 픽셀 수와 경계 상자. 영역 (x,y,w,h) 를 주면 그 안만 센다 (w<=0 이면 전체).
  public static long Diff(string a, string b, int rx, int ry, int rw, int rh, out string bbox) {
    bbox = "";
    using (var A = new Bitmap(a)) using (var B = new Bitmap(b)) {
      if (A.Width != B.Width || A.Height != B.Height) return -1;
      var pa = Pixels(A); var pb = Pixels(B);
      if (rw <= 0) { rx = 0; ry = 0; rw = A.Width; rh = A.Height; }
      long n = 0; int x0 = int.MaxValue, y0 = int.MaxValue, x1 = -1, y1 = -1;
      for (int y = Math.Max(0, ry); y < Math.Min(A.Height, ry + rh); y++)
        for (int x = Math.Max(0, rx); x < Math.Min(A.Width, rx + rw); x++) {
          int i = y * A.Width + x;
          if (pa[i] == pb[i]) continue;
          n++;
          if (x < x0) x0 = x; if (y < y0) y0 = y; if (x > x1) x1 = x; if (y > y1) y1 = y;
        }
      if (n > 0) bbox = string.Format("{0},{1} {2}x{3}", x0, y0, x1 - x0 + 1, y1 - y0 + 1);
      return n;
    }
  }
  // 정확히 그 RGB 인 픽셀 수와 경계 상자. 강조 색 (#f7a41d · #8c5c0e) 판정용.
  public static long CountColor(string f, int r, int g, int b, int tol, int rx, int ry, int rw, int rh, out string bbox) {
    bbox = "";
    using (var A = new Bitmap(f)) {
      var pa = Pixels(A);
      if (rw <= 0) { rx = 0; ry = 0; rw = A.Width; rh = A.Height; }
      long n = 0; int x0 = int.MaxValue, y0 = int.MaxValue, x1 = -1, y1 = -1;
      for (int y = Math.Max(0, ry); y < Math.Min(A.Height, ry + rh); y++)
        for (int x = Math.Max(0, rx); x < Math.Min(A.Width, rx + rw); x++) {
          int v = pa[y * A.Width + x];
          int R = (v >> 16) & 0xFF, G = (v >> 8) & 0xFF, Bb = v & 0xFF;
          if (Math.Abs(R - r) > tol || Math.Abs(G - g) > tol || Math.Abs(Bb - b) > tol) continue;
          n++;
          if (x < x0) x0 = x; if (y < y0) y0 = y; if (x > x1) x1 = x; if (y > y1) y1 = y;
        }
      if (n > 0) bbox = string.Format("{0},{1} {2}x{3}", x0, y0, x1 - x0 + 1, y1 - y0 + 1);
      return n;
    }
  }
  // 스크롤바 thumb 의 y 범위. 트랙 색 (그 열의 최빈색) 이 아닌 픽셀이 thumb 이다.
  // viewport 가 버퍼의 어디에 있는지를 재는 데 쓴다 — 매치 이동의 방향 · wrap 판정 (B9).
  public static string ThumbRange(string f, int x0, int w, int yTop, int yBot) {
    using (var A = new Bitmap(f)) {
      var pa = Pixels(A);
      if (x0 < 0 || x0 + w > A.Width) return "";
      if (yBot <= 0 || yBot > A.Height) yBot = A.Height;
      if (yTop < 0) yTop = 0;
      var hist = new System.Collections.Generic.Dictionary<int, int>();
      for (int y = yTop; y < yBot; y++)
        for (int x = x0; x < x0 + w; x++) {
          int v = pa[y * A.Width + x];
          if (hist.ContainsKey(v)) hist[v]++; else hist[v] = 1;
        }
      int track = 0, best = -1;
      foreach (var kv in hist) if (kv.Value > best) { best = kv.Value; track = kv.Key; }
      int y0 = -1, y1 = -1, n = 0;
      for (int y = yTop; y < yBot; y++) {
        bool any = false;
        for (int x = x0; x < x0 + w; x++) if (pa[y * A.Width + x] != track) { any = true; break; }
        if (!any) continue;
        if (y0 < 0) y0 = y;
        y1 = y; n++;
      }
      if (y0 < 0) return "";
      return string.Format("{0},{1},{2}", y0, y1, n);
    }
  }
  public static void Crop(string src, string dst, int x, int y, int w, int h, int zoom) {
    using (var A = new Bitmap(src)) {
      x = Math.Max(0, Math.Min(x, A.Width - 1)); y = Math.Max(0, Math.Min(y, A.Height - 1));
      w = Math.Min(w, A.Width - x); h = Math.Min(h, A.Height - y);
      using (var c = A.Clone(new Rectangle(x, y, w, h), A.PixelFormat)) {
        if (zoom <= 1) { c.Save(dst, ImageFormat.Png); return; }
        using (var z = new Bitmap(w * zoom, h * zoom, PixelFormat.Format32bppArgb))
        using (var g = Graphics.FromImage(z)) {
          g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.NearestNeighbor;
          g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.Half;
          g.DrawImage(c, 0, 0, w * zoom, h * zoom);
          z.Save(dst, ImageFormat.Png);
        }
      }
    }
  }
  public static string CursorName() {
    var ci = new CURSORINFO(); ci.cbSize = Marshal.SizeOf(typeof(CURSORINFO));
    if (!GetCursorInfo(ref ci)) return "query-failed";
    if (ci.hCursor == IntPtr.Zero) return "hidden";
    if (ci.hCursor == LoadCursorW(IntPtr.Zero, new IntPtr(32649))) return "hand";
    if (ci.hCursor == LoadCursorW(IntPtr.Zero, new IntPtr(32513))) return "ibeam";
    if (ci.hCursor == LoadCursorW(IntPtr.Zero, new IntPtr(32512))) return "arrow";
    return "other";
  }
  static INPUT Key(ushort vk, uint flags) {
    var i = new INPUT(); i.type = 1; i.ki.wVk = vk; i.ki.wScan = (ushort)MapVirtualKeyW(vk, 0); i.ki.dwFlags = flags; return i;
  }
  static INPUT Mouse(int nx, int ny, uint flags, uint data) { var i = new INPUT(); i.type = 0; i.mi.dx = nx; i.mi.dy = ny; i.mi.dwFlags = flags; i.mi.mouseData = data; return i; }
  static void Norm(int x, int y, out int nx, out int ny) {
    int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
    nx = (int)(((long)(x - vx) * 65535) / (vw > 1 ? vw - 1 : 1)); ny = (int)(((long)(y - vy) * 65535) / (vh > 1 ? vh - 1 : 1));
  }
  const uint MOVE_ABS = 0x0001 | 0x8000 | 0x4000;
  public static void MoveTo(int x, int y, int steps) {
    int nx, ny; Norm(x, y, out nx, out ny);
    for (int k = 0; k < steps; k++) {
      int sx, sy; Norm(x + (k % 2 == 0 ? 1 : -1), y, out sx, out sy);
      var a = new INPUT[] { Mouse(sx, sy, MOVE_ABS, 0) };
      SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
      System.Threading.Thread.Sleep(50);
    }
    var b = new INPUT[] { Mouse(nx, ny, MOVE_ABS, 0) };
    SendInput(1, b, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void ClickHere() {
    var a = new INPUT[] { Mouse(0, 0, 0x0002, 0) };
    SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    System.Threading.Thread.Sleep(80);
    var b = new INPUT[] { Mouse(0, 0, 0x0004, 0) };
    SendInput(1, b, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void Wheel(int clicks) {
    var a = new INPUT[] { Mouse(0, 0, 0x0800, unchecked((uint)(clicks * 120))) };
    SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void DragTo(int x0, int y0, int x1, int y1) {
    MoveTo(x0, y0, 1);
    System.Threading.Thread.Sleep(120);
    var d = new INPUT[] { Mouse(0, 0, 0x0002, 0) };
    SendInput(1, d, Marshal.SizeOf(typeof(INPUT)));
    System.Threading.Thread.Sleep(120);
    for (int k = 1; k <= 6; k++) { MoveTo(x0 + (x1 - x0) * k / 6, y0 + (y1 - y0) * k / 6, 1); System.Threading.Thread.Sleep(40); }
    System.Threading.Thread.Sleep(120);
    var u = new INPUT[] { Mouse(0, 0, 0x0004, 0) };
    SendInput(1, u, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void KeyDownUp(ushort vk, bool down) {
    var a = new INPUT[] { Key(vk, down ? 0u : 2u) };
    SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
  }
  public static uint Chord(ushort[] vks) {
    var a = new INPUT[vks.Length * 2]; int n = 0;
    foreach (var v in vks) a[n++] = Key(v, 0);
    for (int k = vks.Length - 1; k >= 0; k--) a[n++] = Key(vks[k], 2);
    return SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void Topmost(IntPtr h, bool on) {
    SetWindowPos(h, new IntPtr(on ? -1 : -2), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
  }
  public static void Resize(IntPtr h, int w, int ht) {
    SetWindowPos(h, IntPtr.Zero, 0, 0, w, ht, 0x0002 | 0x0010 | 0x0004);   // NOMOVE|NOACTIVATE|NOZORDER
  }
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
  public static IntPtr[] Layouts() { var a = new IntPtr[32]; int n = GetKeyboardLayoutList(32, a); var r = new IntPtr[Math.Max(n, 0)]; Array.Copy(a, r, r.Length); return r; }
  public static IntPtr LayoutOfWindow(IntPtr h) { uint pid; uint tid = GetWindowThreadProcessId(h, out pid); return GetKeyboardLayout(tid); }
  // 우리 창 밖에 새로 뜬 보이는 창들 (IME 후보창 · 메모장 등). 클래스와 사각형을 돌려준다.
  public static string[] VisibleWindows(uint skipPid) {
    var list = new System.Collections.Generic.List<string>();
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      uint p; GetWindowThreadProcessId(h, out p);
      RECT r; if (!GetWindowRect(h, out r)) return true;
      if (r.R - r.L < 8 || r.B - r.T < 8) return true;
      var cls = new System.Text.StringBuilder(128); GetClassNameW(h, cls, 128);
      var t = new System.Text.StringBuilder(160); GetWindowTextW(h, t, 160);
      list.Add(string.Format("{0}|{1}|{2},{3},{4},{5}|{6}", p, cls.ToString(), r.L, r.T, r.R, r.B, t.ToString()));
      return true;
    }, IntPtr.Zero);
    return list.ToArray();
  }
}
"@
[TzSearch]::MakeDpiAware()

$VK = @{
    A = 0x41; B = 0x42; C = 0x43; D = 0x44; E = 0x45; F = 0x46; G = 0x47; H = 0x48; I = 0x49; J = 0x4A
    K = 0x4B; L = 0x4C; M = 0x4D; N = 0x4E; O = 0x4F; P = 0x50; Q = 0x51; R = 0x52; S = 0x53; T = 0x54
    U = 0x55; V = 0x56; W = 0x57; X = 0x58; Y = 0x59; Z = 0x5A
    D0 = 0x30; D1 = 0x31; D2 = 0x32; D3 = 0x33; D4 = 0x34; D5 = 0x35; D6 = 0x36; D7 = 0x37; D8 = 0x38; D9 = 0x39
    Shift = 0x10; Ctrl = 0x11; Alt = 0x12; Enter = 0x0D; Esc = 0x1B; Space = 0x20; Tab = 0x09; Back = 0x08
    Left = 0x25; Up = 0x26; Right = 0x27; Down = 0x28; Home = 0x24; End = 0x23; PgUp = 0x21; PgDn = 0x22
    Hangul = 0x15; Hanja = 0x19
}

$Out = Join-Path $env:TEMP "tildaz-search-check\$Mode"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
Get-ChildItem $Out -Filter *.png -ErrorAction SilentlyContinue | Remove-Item -Force
$Log = Join-Path $env:APPDATA "tildaz\tildaz_stress.log"
$Cfg9 = Join-Path $env:APPDATA "tildaz\config_9.toml"
$Cfg0 = Join-Path $env:APPDATA "tildaz\config_0.toml"
$madeCfg = $false
if (-not (Test-Path $Bin)) { throw "바이너리 없음: $Bin" }
if ((Test-Path $Cfg9) -and $SizePoint -le 0) { throw "config_9.toml 이 이미 있다 — 사용자 설정을 건드리지 않으려고 멈춘다: $Cfg9" }

# 자식 — 화면을 찍고 raw 입력을 파일에 기록한다.
$childPath = Join-Path $Out "child.ps1"
$childBody = @'
param([string]$Out, [int]$MouseOn = 0)
$ErrorActionPreference = "Continue"
try {
Add-Type -Name TzChild -Namespace Tz -MemberDefinition @"
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(IntPtr h, uint m);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool ReadFile(IntPtr h, byte[] b, uint n, out uint got, IntPtr o);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetNumberOfConsoleInputEvents(IntPtr h, out uint n);
"@
$ESC = [char]27
for ($i = 1; $i -le 300; $i++) {
    Write-Host ("line {0} FINDME{1}" -f $i, ($i % 7))
    # B9 용 — 화면 **밖 (위쪽)** 에만 있는 매치 두 개. 맨 아래에서 Enter 가 버퍼 맨 위로
    # 감싸 도는지, Shift+Enter 가 가장 최근 (아래쪽) 으로 가는지를 이 둘로 가른다.
    if ($i -eq 10 -or $i -eq 150) { Write-Host ("WRAPMARK at {0}" -f $i) }
}
if ($MouseOn -ne 0) { [Console]::Out.Write("$ESC[?1000h"); [Console]::Out.Flush() }
Write-Host "== MAIN READY =="
$h = [Tz.TzChild]::GetStdHandle(-10)
$mode = 0
[void][Tz.TzChild]::GetConsoleMode($h, [ref]$mode)
# ENABLE_VIRTUAL_TERMINAL_INPUT (0x200) 켜고 PROCESSED (0x1) · LINE (0x2) · ECHO (0x4) 끈다.
[void][Tz.TzChild]::SetConsoleMode($h, ($mode -bor 0x200) -band (-bnot 0x7))
[IO.File]::WriteAllText($Out, "")
$buf = New-Object byte[] 512
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 900) {
    $n = 0
    if ([Tz.TzChild]::GetNumberOfConsoleInputEvents($h, [ref]$n) -and $n -gt 0) {
        $got = 0
        if ([Tz.TzChild]::ReadFile($h, $buf, 512, [ref]$got, [IntPtr]::Zero) -and $got -gt 0) {
            $hex = ($buf[0..($got - 1)] | ForEach-Object { "{0:x2}" -f $_ }) -join " "
            [IO.File]::AppendAllText($Out, $hex + "`n")
        }
    } else { Start-Sleep -Milliseconds 20 }
}
} catch {
    [IO.File]::WriteAllText($Out + ".err", ($_ | Out-String))
}
'@
[IO.File]::WriteAllText($childPath, $childBody, (New-Object System.Text.UTF8Encoding $true))
$rx = Join-Path $Out "rx.txt"
Remove-Item $rx, "$rx.err" -Force -ErrorAction SilentlyContinue

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
    "인스턴스 9 가 5 초 안에 안 내려갔다 — 다음 빌드가 막힐 수 있다"
}
function Rx-Bytes { if (Test-Path $rx) { return (Get-Content $rx -Raw -ErrorAction SilentlyContinue) } else { return "" } }
function Rx-Len { $s = Rx-Bytes; if (-not $s) { return 0 }; return ($s -split '\s+' | Where-Object { $_ }).Count }

Stop-Tz; Start-Sleep -Milliseconds 400
if (Test-Path $Log) { Move-Item $Log (Join-Path $Out "log_prev.txt") -Force }

# A3 — 폰트 크기를 바꿔 여백이 셀 단위인지 본다. 사용자 config 를 복사해 size_point 만 바꾼다.
if ($SizePoint -gt 0) {
    if (Test-Path $Cfg9) { throw "config_9.toml 이 이미 있다: $Cfg9" }
    if (-not (Test-Path $Cfg0)) { throw "config_0.toml 이 없어 A3 회차를 만들 수 없다" }
    $txt = Get-Content $Cfg0 -Raw -Encoding UTF8
    $txt = $txt -replace '(?m)^size_point\s*=.*$', ("size_point        = " + $SizePoint)
    $txt = $txt -replace '(?m)^auto_start\s*=.*$', 'auto_start       = false'
    # `[keys]` 는 strict 다 — 사용자 config 가 이 브랜치보다 오래됐으면 `open_search` 가 없어서
    # 앱이 **fatal 다이얼로그**로 끝난다 (#655). 그 다이얼로그는 창이라 하네스가 그것을 잡아
    # 엉뚱한 것을 잰다 (2026-09-16 첫 회차에서 580x573 짜리를 검색바로 읽을 뻔했다).
    if ($txt -notmatch '(?m)^\s*open_search\s*=') {
        $txt = $txt -replace '(?m)^(\[keys\]\s*)$', "`$1`r`nopen_search         = [`"ctrl+shift+f`"]"
        "  config_0 에 open_search 가 없어 넣었다 (#655)"
    }
    [IO.File]::WriteAllText($Cfg9, $txt, (New-Object System.Text.UTF8Encoding $false))
    $madeCfg = $true
    "config_9.toml 을 잠깐 만들었다 (size_point=$SizePoint · auto_start=false)"
}

$mouseArg = if ($Mouse) { 1 } else { 0 }
$cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$childPath`" `"$rx`" $mouseArg"
$p = Start-Process -FilePath (Resolve-Path $Bin) -PassThru -ArgumentList '--instance', '9', '-e', "`"$cmd`"", '-size', $Size
$h = [IntPtr]::Zero
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($h -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 20000) {
    Start-Sleep -Milliseconds 150
    if ($p.HasExited) { break }
    $h = [TzSearch]::FindWindowOfPid([uint32]$p.Id)
}
if ($p.HasExited) { if ($madeCfg) { Remove-Item $Cfg9 -Force }; throw "앱이 먼저 끝남 exit=$($p.ExitCode)" }
if ($h -eq [IntPtr]::Zero) { Stop-Tz; if ($madeCfg) { Remove-Item $Cfg9 -Force }; throw "창을 못 찾음" }
# ⚠️ 앱이 config 오류 등으로 **fatal 다이얼로그**를 띄우면 그것도 창이라 위에서 잡힌다. 로그로 먼저 가른다
# (AGENTS.md `# Windows — 렌더 결과를 픽셀로 …` 의 같은 함정 — 그쪽은 `_internal` 누락이었다).
if (Test-Path $Log) {
    $fatal = @(Get-Content $Log -Encoding UTF8 | Where-Object { $_ -match '\[fatal\]' })
    if ($fatal.Count -gt 0) {
        Stop-Tz; if ($madeCfg) { Remove-Item $Cfg9 -Force }
        throw ("앱이 fatal 로 끝났다 — 잡힌 창은 다이얼로그다: " + ($fatal[0] -replace '^\[[^\]]+\]\s*', ''))
    }
}
Start-Sleep -Seconds $Wait

$cr = New-Object TzSearch+RECT
[void][TzSearch]::GetClientRect($h, [ref]$cr)
$wr = New-Object TzSearch+RECT
[void][TzSearch]::GetWindowRect($h, [ref]$wr)
$CW = $cr.R - $cr.L; $CH = $cr.B - $cr.T
"창: hwnd=$h  window=$($wr.R - $wr.L)x$($wr.B - $wr.T) @ $($wr.L),$($wr.T)  client=${CW}x${CH}"
$initLine = ''
if (Test-Path $Log) { $initLine = [string](Get-Content $Log -Encoding UTF8 | Where-Object { $_ -match 'window initialized' } | Select-Object -First 1) }
if ($initLine) { "  " + ($initLine -replace '^\[[^\]]+\]\s*', '') }
$fontLine = ''
if (Test-Path $Log) { $fontLine = [string](Get-Content $Log -Encoding UTF8 | Where-Object { $_ -match 'applied ratios|cell_w' } | Select-Object -First 1) }
if ($fontLine) { "  " + ($fontLine -replace '^\[[^\]]+\]\s*', '') }
"자식 수신 파일: $rx (지금 $(Rx-Len) 바이트)"

# PrintWindow 는 창 전체를 찍으므로 클라이언트 원점의 캡처 안 오프셋을 구해 둔다.
$o = [TzSearch]::ClientToScreenPt($h, 0, 0)
$OX = $o.x - $wr.L; $OY = $o.y - $wr.T
"캡처 안 클라이언트 원점: $OX,$OY"

$script:shotN = 0
function Shot([string]$tag) {
    $script:shotN++
    $f = Join-Path $Out ("{0:d2}_{1}.png" -f $script:shotN, $tag)
    $bmp = [TzSearch]::Capture($h); $bmp.Save($f, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    return $f
}
function ShotScreen([string]$tag) {
    $script:shotN++
    $f = Join-Path $Out ("{0:d2}_{1}_screen.png" -f $script:shotN, $tag)
    $bmp = [TzSearch]::CaptureScreen(); $bmp.Save($f, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    return $f
}
$NeutralPt = @([int]($CW / 2), [int]($CH / 3))
function Guard {
    if ([TzSearch]::GetForegroundWindow() -eq $h) { return }
    if ([TzSearch]::Focus($h, $NeutralPt[0], $NeutralPt[1])) { Start-Sleep -Milliseconds 300; return }
    Stop-Tz
    throw "포커스를 잃었고 되찾지 못했다 — 회차 중단"
}
function TzSend([uint16[]]$chord, [int]$ms = 160) {
    Guard
    [void][TzSearch]::Chord([uint16[]]$chord)
    Start-Sleep -Milliseconds $ms
}
function TzType([string]$s, [int]$ms = 90) {
    foreach ($ch in $s.ToCharArray()) {
        $vk = switch -regex ([string]$ch) {
            '^[a-z]$' { [int][char]([string]$ch).ToUpper(); break }
            '^[A-Z]$' { [int][char]$ch; break }
            '^[0-9]$' { [int][char]$ch; break }
            '^ $'     { 0x20; break }
            default   { -1 }
        }
        if ($vk -lt 0) { throw "Type 이 못 보내는 글자: $ch" }
        if ([string]$ch -cmatch '^[A-Z]$') { TzSend @([uint16]$VK.Shift, [uint16]$vk) $ms } else { TzSend @([uint16]$vk) $ms }
    }
}
function MoveClient($pt, [int]$steps = 4) {
    Guard
    $s = [TzSearch]::ClientToScreenPt($h, $pt[0], $pt[1])
    [TzSearch]::MoveTo($s.x, $s.y, $steps)
    Start-Sleep -Milliseconds 320
}
$results = @()
function Record([string]$id, [string]$what, [string]$expect, [string]$got, [bool]$ok) {
    $script:results += [pscustomobject]@{ id = $id; what = $what; expect = $expect; got = $got; ok = $ok }
    "{0,-4} {1,-50} {2}  기대 [{3}] 받음 [{4}]" -f $id, $what, $(if ($ok) { "PASS" } else { "FAIL" }), $expect, $got
}
function DiffOf([string]$a, [string]$b) {
    $bb = ""
    $n = [TzSearch]::Diff($a, $b, 0, 0, 0, 0, [ref]$bb)
    return @{ n = $n; bbox = $bb }
}
function DiffIn([string]$a, [string]$b, $r) {
    $bb = ""
    $n = [TzSearch]::Diff($a, $b, $r.x, $r.y, $r.w, $r.h, [ref]$bb)
    return @{ n = $n; bbox = $bb }
}
function ColorCount([string]$f, [int]$r, [int]$g, [int]$b, [int]$tol = 6) {
    $bb = ""
    $n = [TzSearch]::CountColor($f, $r, $g, $b, $tol, 0, 0, 0, 0, [ref]$bb)
    return @{ n = $n; bbox = $bb }
}
function ColorCountIn([string]$f, [int]$r, [int]$g, [int]$b, $rect, [int]$tol = 6) {
    $bb = ""
    $n = [TzSearch]::CountColor($f, $r, $g, $b, $tol, $rect.x, $rect.y, $rect.w, $rect.h, [ref]$bb)
    return @{ n = $n; bbox = $bb }
}
function ParseBBox([string]$bb) {
    if (-not $bb) { return $null }
    if ($bb -notmatch '^(\d+),(\d+) (\d+)x(\d+)$') { return $null }
    return @{ x = [int]$matches[1]; y = [int]$matches[2]; w = [int]$matches[3]; h = [int]$matches[4] }
}

if (-not [TzSearch]::Focus($h, $NeutralPt[0], $NeutralPt[1])) { Stop-Tz; if ($madeCfg) { Remove-Item $Cfg9 -Force }; throw "포커스를 못 잡음 — 다른 창이 앞에 있다" }
[TzSearch]::Topmost($h, $true)
MoveClient $NeutralPt 2

# --- 공통: 바를 열고 그 사각형을 캡처에서 찾는다 -------------------------------------------------
$closed = Shot "closed"
TzSend @($VK.Ctrl, $VK.Shift, $VK.F) 900
$opened = Shot "opened"
$d = DiffOf $closed $opened
$Bar = ParseBBox $d.bbox
"검색바 (열기 전후 차이 상자): $($d.bbox)  = $($d.n) px"
if (-not $Bar) {
    Stop-Tz; if ($madeCfg) { Remove-Item $Cfg9 -Force }
    throw "Ctrl+Shift+F 로 바뀐 픽셀이 없다 — 바가 안 열렸거나 키가 안 닿았다"
}
$BarRect = @{ x = $Bar.x; y = $Bar.y; w = $Bar.w; h = $Bar.h }
# 바 안의 지점들 (캡처 좌표 → 클라이언트 좌표는 OX/OY 를 뺀다)
function ToClient($cx, $cy) { return @([int]($cx - $OX), [int]($cy - $OY)) }
$BarFieldPt = ToClient ($Bar.x + [int]($Bar.w * 0.45)) ($Bar.y + [int]($Bar.h / 2))
$BarLeftCtrlPt = ToClient ($Bar.x + 12) ($Bar.y + [int]($Bar.h / 2))
$BarRightCtrlPt = ToClient ($Bar.x + $Bar.w - 12) ($Bar.y + [int]($Bar.h / 2))
"바 안 지점 (클라이언트): 입력칸 $($BarFieldPt -join ',') · 왼끝 $($BarLeftCtrlPt -join ',') · 오른끝 $($BarRightCtrlPt -join ',')"

if ($Mode -eq 'probe') {
    [void](Shot "probe_bar")
    [TzSearch]::Crop($opened, (Join-Path $Out "bar_zoom.png"), ($Bar.x - 8), ($Bar.y - 8), ($Bar.w + 16), ($Bar.h + 16), 3)
    "확대: $(Join-Path $Out 'bar_zoom.png')"
    [TzSearch]::Topmost($h, $false)
    if (-not $Keep) { Stop-Tz }
    if ($madeCfg) { Remove-Item $Cfg9 -Force; "config_9.toml 삭제" }
    "캡처: $Out"
    return
}

# --- 바 안 자리 — `search_bar.view` 의 상수로 계산한다 (캡처에서 잰 바 사각형 기준) ------------
# WIDTH 320 · HEIGHT 36 · PADDING 8 · GAP 6 · ICON_SLOT 20 (ICON 14 + GAP 6) · COUNT_W 56 ·
# CONTROL_W 24 (`ui_metrics.TAB_CLOSE_W_PT`) · BORDER 1 (`TAB_SEPARATOR_W_PT`).
$DPI = 96
if ($initLine -match 'dpi=(\d+)') { $DPI = [int]$matches[1] }
$CELLW = 9; $CELLH = 20
if ($initLine -match 'cell=(\d+)x(\d+)') { $CELLW = [int]$matches[1]; $CELLH = [int]$matches[2] }
$S = $DPI / 96.0
$PAD = [int](8 * $S); $GAPX = [int](6 * $S); $ICONSLOT = [int](20 * $S)
$COUNTW = [int](56 * $S); $CTRLW = [int](24 * $S)
$fieldX0 = $Bar.x + $PAD + $ICONSLOT
$fieldW = $Bar.w - $PAD * 2 - $ICONSLOT - $COUNTW - $GAPX - $CTRLW * 3
$countX = $fieldX0 + $fieldW + $GAPX
$prevX = $countX + $COUNTW
$nextX = $prevX + $CTRLW
$closeX = $nextX + $CTRLW
$midY = $Bar.y + [int]($Bar.h / 2)
$PtField = ToClient ($fieldX0 + 20) $midY
$PtFieldMid = ToClient ($fieldX0 + [int]($fieldW / 2)) $midY
$PtCount = ToClient ($countX + [int]($COUNTW / 2)) $midY
$PtPrev = ToClient ($prevX + [int]($CTRLW / 2)) $midY
$PtNext = ToClient ($nextX + [int]($CTRLW / 2)) $midY
$PtClose = ToClient ($closeX + [int]($CTRLW / 2)) $midY
"바 자리 계산 (scale=$S · cell=${CELLW}x${CELLH}): field $fieldX0..$($fieldX0+$fieldW) · count $countX · prev $prevX · next $nextX · close $closeX · midY $midY"
# 바가 아닌 터미널 영역 (강조 색을 세는 곳) — **클라이언트 전체에서 바 사각형만 뺀다.**
# 바 위쪽만 보면 맨 아랫줄의 매치를 놓친다 (2026-09-16 첫 B 회차에서 버퍼 마지막 줄 매치가
# 바와 같은 높이에 있어 `amber=0` 으로 읽혔다 — 캡처에는 또렷이 강조돼 있었다).
$TermRect = @{ x = 0; y = 0; w = ($CW + 40); h = ($CH + 40) }
# 바 아래 한 줄 — A2 (프롬프트 줄을 안 가린다) 를 보는 띠.
$UnderRect = @{ x = 0; y = ($Bar.y + $Bar.h); w = ($CW + 40); h = $CELLH }

$AMBER = @(247, 164, 29)      # TAB_ACCENT_COLOR — 지금 고른 매치
$DARK = @(140, 92, 14)        # SEARCH_MATCH_BG — 나머지 매치
# 바 안에도 같은 색이 쓰일 수 있으니 (테두리 · 포커스 선) 전체에서 바 안을 뺀다.
function AmberN($f) {
    $all = ColorCountIn $f $AMBER[0] $AMBER[1] $AMBER[2] $TermRect 4
    $inBar = ColorCountIn $f $AMBER[0] $AMBER[1] $AMBER[2] $BarRect 4
    return @{ n = ($all.n - $inBar.n); bbox = $all.bbox }
}
function DarkN($f) {
    $all = ColorCountIn $f $DARK[0] $DARK[1] $DARK[2] $TermRect 4
    $inBar = ColorCountIn $f $DARK[0] $DARK[1] $DARK[2] $BarRect 4
    return @{ n = ($all.n - $inBar.n); bbox = $all.bbox }
}
$baseAmber = (AmberN $opened).n
$baseDark = (DarkN $opened).n
"바만 열린 상태의 강조 색 기준: amber=$baseAmber · dark=$baseDark (터미널 영역)"

# ================================================================= A. 렌더 · 배치
if ($Mode -eq 'A') {
    # A1 — 창 우하단에 320x36 (pt) 로 뜬다.
    $wantW = [int](320 * $S); $wantH = [int](36 * $S)
    $okSize = ($Bar.w -eq $wantW -and $Bar.h -eq $wantH)
    $okPlace = ($Bar.x -gt $CW / 2 -and $Bar.y -gt $CH / 2)
    Record "A1" "창 우하단에 바가 뜬다" "${wantW}x${wantH} · 우하단" "$($Bar.w)x$($Bar.h) @ $($Bar.x),$($Bar.y) (client ${CW}x${CH})" ($okSize -and $okPlace)

    # A4 — 오른쪽 여백: 스크롤바 왼쪽에서 셀 한 칸. 스크롤백이 300 줄이라 스크롤바가 떠 있다.
    # 바 오른쪽 끝 + 셀 한 칸 + 스크롤바 폭 = 클라이언트 폭.
    $barRight = $Bar.x + $Bar.w
    $sbW = $CW - $barRight - $CELLW
    Record "A4" "오른쪽 여백 = 셀 한 칸 + 스크롤바" "셀 $CELLW px · 스크롤바 > 0" "바 오른끝 $barRight · 남은 폭 $($CW - $barRight) = 셀 $CELLW + 스크롤바 $sbW" ($sbW -gt 0 -and $sbW -le 20)

    # A2 — 바 아래에 격자 한 줄이 온전히 남는다. 그 띠에 글자 잉크가 있으면 가려지지 않은 것이다.
    # (마지막 줄은 자식이 찍은 `== MAIN READY ==` 다 — 바는 오른쪽이라 왼쪽 글자와 겹치지 않는다.)
    $under = DiffIn $closed $opened $UnderRect
    $inkUnder = ColorCountIn $opened 204 204 204 $UnderRect 60
    Record "A2" "바 아래 한 줄이 온전히 보인다" "바가 안 덮음 (0 px) · 그 줄에 글자" "바 침범 $($under.n) px · 글자 $($inkUnder.n) px" ($under.n -eq 0 -and $inkUnder.n -gt 0)

    # A6 — 검색어를 넣고 강조 색을 본다. **타이핑만으로는 고른 매치가 없다** (카운터가 `43` 처럼
    # 개수만 나온다) — 전부 어두운 amber 다. `Enter` 를 눌러야 하나가 밝은 amber 가 된다.
    TzType "FINDME3"
    Start-Sleep -Milliseconds 900
    $hl = Shot "A6_highlight"
    $a = AmberN $hl; $dk = DarkN $hl
    Record "A6" "타이핑 직후 — 매치가 전부 어두운 amber" "amber 0 · dark>0" "amber=$($a.n) · dark=$($dk.n) ($($dk.bbox))" ($a.n -eq $baseAmber -and $dk.n -gt $baseDark)
    TzSend @($VK.Enter) 900
    $hl2 = Shot "A6_selected"
    $a2 = AmberN $hl2; $dk2 = DarkN $hl2
    Record "A6b" "Enter 뒤 — 고른 매치만 밝은 amber" "amber>0 · dark>0" "amber=$($a2.n) ($($a2.bbox)) · dark=$($dk2.n)" ($a2.n -gt $baseAmber -and $dk2.n -gt $baseDark)
    [TzSearch]::Crop($hl2, (Join-Path $Out "A6_selected_zoom.png"), 0, ($Bar.y - 200), 420, 200, 2)
    [TzSearch]::Crop($hl, (Join-Path $Out "A6_bar.png"), ($Bar.x - 4), ($Bar.y - 4), ($Bar.w + 8), ($Bar.h + 8), 3)
    [TzSearch]::Crop($hl, (Join-Path $Out "A6_match.png"), 0, ($Bar.y - 200), 420, 200, 2)

    # A5 — 탭을 2 개로 늘려도 바가 격자 바닥을 따라간다. 창 크기가 바뀌므로 바를 다시 잰다.
    $beforeW = $wr.R - $wr.L; $beforeH = $wr.B - $wr.T; $beforeBarY = $Bar.y; $beforeBarX = $Bar.x
    TzSend @($VK.Ctrl, $VK.Shift, $VK.T) 2500
    $wr2 = New-Object TzSearch+RECT
    [void][TzSearch]::GetWindowRect($h, [ref]$wr2)
    $tabShot = Shot "A5_two_tabs"
    # 새 탭에는 검색바가 없다 (pane 별 상태) — 그 탭에서 다시 열어 자리를 잰다.
    $closed2 = Shot "A5_closed"
    TzSend @($VK.Ctrl, $VK.Shift, $VK.F) 900
    $opened2 = Shot "A5_opened"
    $d2 = DiffOf $closed2 $opened2
    $Bar2 = ParseBBox $d2.bbox
    $gotY = if ($Bar2) { $Bar2.y } else { -1 }
    $gotX = if ($Bar2) { $Bar2.x } else { -1 }
    $newH = $wr2.B - $wr2.T
    # 탭바가 생기면 창이 그만큼 커지고 격자는 그대로다 — 바의 클라이언트 y 는 탭바 높이만큼 내려간다.
    $grew = $newH - $beforeH
    $okA5 = ($Bar2 -ne $null -and $gotX -eq $beforeBarX -and ($gotY - $beforeBarY) -eq $grew)
    Record "A5" "탭 2 개에서도 바가 격자 바닥을 따라간다" "x 그대로 · y 가 탭바만큼만 이동" "창 ${beforeW}x${beforeH} -> $($wr2.R - $wr2.L)x$newH (+$grew) · 바 $beforeBarX,$beforeBarY -> $gotX,$gotY" $okA5
}

# ================================================================= B. 키보드
if ($Mode -eq 'B') {
    # B7 — 디바운스. 2 자는 300 ms 뒤에 검색된다.
    $rx0 = Rx-Len
    TzType "FI" 60
    Start-Sleep -Milliseconds 120
    $fast = Shot "B7_fast"
    Start-Sleep -Milliseconds 700
    $slow = Shot "B7_slow"
    $aFast = (AmberN $fast).n; $aSlow = (AmberN $slow).n
    $dFast = (DarkN $fast).n; $dSlow = (DarkN $slow).n
    Record "B7" "1-2 자는 300 ms 디바운스 뒤 검색" "직후 0 · 뒤 >0" "직후 amber=$aFast dark=$dFast · 700 ms 뒤 amber=$aSlow dark=$dSlow" (($aFast + $dFast) -le ($baseAmber + $baseDark) -and ($aSlow + $dSlow) -gt ($baseAmber + $baseDark))

    # 이어서 3 자 이상 — 즉시 검색된다.
    TzType "NDME3" 60
    Start-Sleep -Milliseconds 700
    $typed = Shot "B7_typed"
    [TzSearch]::Crop($typed, (Join-Path $Out "B7_bar.png"), ($Bar.x - 4), ($Bar.y - 4), ($Bar.w + 8), ($Bar.h + 8), 3)
    $rx1 = Rx-Len
    Record "B7b" "타이핑이 셸로 새지 않는다" "PTY 바이트 +0" "+$($rx1 - $rx0)" (($rx1 - $rx0) -eq 0)

    # B8 — Enter 는 아래로, Shift+Enter 는 위로. 지금 고른 매치 (amber) 의 y 로 방향을 본다.
    $s0 = Shot "B8_0"
    $m0 = (AmberN $s0)
    TzSend @($VK.Enter) 900
    $s1 = Shot "B8_enter1"
    $m1 = (AmberN $s1)
    TzSend @($VK.Enter) 900
    $s2 = Shot "B8_enter2"
    $m2 = (AmberN $s2)
    $y0 = (ParseBBox $m0.bbox).y; $y1 = (ParseBBox $m1.bbox).y; $y2 = (ParseBBox $m2.bbox).y
    Record "B8" "Enter 가 아래로 간다" "y 증가 (또는 wrap)" "y $y0 -> $y1 -> $y2" ($y1 -ne $y0 -and $y2 -ne $y1)
    TzSend @($VK.Shift, $VK.Enter) 900
    $s3 = Shot "B8_shift_enter"
    $m3 = (AmberN $s3)
    $y3 = (ParseBBox $m3.bbox).y
    Record "B8b" "Shift+Enter 가 되돌아간다" "직전 자리 ($y1)" "y $y2 -> $y3" ($y3 -eq $y1)
    [TzSearch]::Crop($s3, (Join-Path $Out "B8_bar.png"), ($Bar.x - 4), ($Bar.y - 4), ($Bar.w + 8), ($Bar.h + 8), 3)

    # B9 — 프롬프트 (맨 아래) 에 서 있을 때 `Enter` 는 버퍼 **맨 위**로 감싸 돌고 `Shift+Enter` 는
    # **가장 최근** 매치로 간다 (SPEC §2.9 의 방향 대칭). viewport 가 버퍼의 어디인지는
    # **스크롤바 thumb** 으로 잰다 — 화면 글자를 읽지 않아도 위 · 아래가 확정된다.
    # 먼저 화면을 **맨 아래**로 되돌린다 (B8 이 매치를 따라 올라가 있다). 그리고 매치가 화면에
    # 하나도 없는 검색어를 쓴다 — `WRAPMARK` 는 line 10 · 150 에만 있어 맨 아래 화면에서는 안 보인다.
    # (`FINDME3` 처럼 화면 안에 매치가 있으면 wrap 이 아예 안 일어나는 것이 사양이라 판정이 안 된다.)
    TzSend @($VK.Esc) 700
    MoveClient $NeutralPt 2
    for ($i = 0; $i -lt 80; $i++) { [TzSearch]::Wheel(-1); Start-Sleep -Milliseconds 25 }
    Start-Sleep -Milliseconds 700
    Guard
    TzSend @($VK.Ctrl, $VK.Shift, $VK.F) 900
    TzType "WRAPMARK" 60
    Start-Sleep -Milliseconds 900
    $sbX = $CW - 10
    $b9a = Shot "B9_bottom"
    $th0 = [TzSearch]::ThumbRange($b9a, $sbX, 10, [int](30 * $S), $Bar.y)
    TzSend @($VK.Enter) 1200
    $b9b = Shot "B9_enter_wrap"
    $th1 = [TzSearch]::ThumbRange($b9b, $sbX, 10, [int](30 * $S), $Bar.y)
    TzSend @($VK.Esc) 700
    MoveClient $NeutralPt 2
    for ($i = 0; $i -lt 80; $i++) { [TzSearch]::Wheel(-1); Start-Sleep -Milliseconds 25 }
    Start-Sleep -Milliseconds 700
    Guard
    TzSend @($VK.Ctrl, $VK.Shift, $VK.F) 900
    TzType "WRAPMARK" 60
    Start-Sleep -Milliseconds 900
    $b9bot = Shot "B9_bottom2"
    TzSend @($VK.Shift, $VK.Enter) 1200
    $b9c = Shot "B9_shift_enter"
    $th2 = [TzSearch]::ThumbRange($b9c, $sbX, 10, [int](30 * $S), $Bar.y)
    # 시작이 정말 맨 아래였는지 — 아니면 "가장 최근" 이 무엇인지 자체가 달라진다.
    $th0b = [TzSearch]::ThumbRange($b9bot, $sbX, 10, [int](30 * $S), $Bar.y)
    $y0b = if ($th0b) { [int]($th0b.Split(',')[0]) } else { -1 }
    $y0 = if ($th0) { [int]($th0.Split(',')[0]) } else { -1 }
    $y1 = if ($th1) { [int]($th1.Split(',')[0]) } else { -1 }
    $y2 = if ($th2) { [int]($th2.Split(',')[0]) } else { -1 }
    Record "B9" "맨 아래에서 Enter 는 버퍼 맨 위로 감싸 돈다" "thumb 이 위로 크게 올라간다" "thumb y $y0 -> $y1 (Enter)" ($y1 -ge 0 -and $y0 -ge 0 -and $y1 -lt $y0 - 100)
    Record "B9b" "같은 자리에서 Shift+Enter 는 가장 최근 (더 아래) 매치로" "Enter 가 간 자리보다 아래" "시작 thumb $y0b -> $y2 (Shift+Enter) · Enter 는 $y1" ($y2 -ge 0 -and $y2 -gt $y1)

    # B10 — **버퍼 마지막 줄 매치** (Linux 회차가 찾은 결함 `e545ad8` 의 재현 조건).
    # 검색어를 지우고 `MAIN READY` 로 바꾼 뒤, 화면을 위로 올려 마커를 화면 밖으로 보낸다.
    for ($i = 0; $i -lt 12; $i++) { TzSend @($VK.Back) 40 }
    Start-Sleep -Milliseconds 400
    TzType "MAIN READY" 60
    Start-Sleep -Milliseconds 800
    # 스크롤을 위로 — 검색바가 열려 있어도 휠은 터미널로 간다.
    MoveClient $NeutralPt 2
    for ($i = 0; $i -lt 10; $i++) { [TzSearch]::Wheel(1); Start-Sleep -Milliseconds 60 }
    Start-Sleep -Milliseconds 700
    $up = Shot "B10_scrolled_up"
    $aUp = (AmberN $up).n
    Guard
    TzSend @($VK.Enter) 1200
    $down = Shot "B10_enter"
    $aDown = (AmberN $down)
    Record "B10" "버퍼 마지막 줄 매치로 화면이 따라간다 (Enter)" "강조 >0 px" "스크롤 뒤 amber=$aUp · Enter 뒤 amber=$($aDown.n) ($($aDown.bbox))" ($aDown.n -gt 0)
    # 같은 조건에서 Shift+Enter 도 본다.
    for ($i = 0; $i -lt 10; $i++) { [TzSearch]::Wheel(1); Start-Sleep -Milliseconds 60 }
    Start-Sleep -Milliseconds 700
    Guard
    TzSend @($VK.Shift, $VK.Enter) 1200
    $down2 = Shot "B10_shift_enter"
    $aDown2 = (AmberN $down2)
    Record "B10b" "같은 매치로 Shift+Enter 도 화면이 따라간다" "강조 >0 px" "amber=$($aDown2.n) ($($aDown2.bbox))" ($aDown2.n -gt 0)

    # B10c — 이미 보이는 매치는 화면을 안 움직인다.
    $vis0 = Shot "B10c_before"
    Guard
    TzSend @($VK.Enter) 1000
    $vis1 = Shot "B10c_after"
    # 매치가 하나뿐 (`== MAIN READY ==`) 이라 같은 자리로 돌아온다 — 화면이 움직이면 안 된다.
    $dv = DiffIn $vis0 $vis1 $TermRect
    Record "B10c" "이미 보이는 매치는 화면을 안 움직인다" "터미널 영역 0 px" "$($dv.n) px ($($dv.bbox))" ($dv.n -eq 0)

    # B11 — Backspace 와 caret 이동. 캡처 차이가 바 안에만 생겨야 한다.
    $c0 = Shot "B11_0"
    TzSend @($VK.Back) 400
    $c1 = Shot "B11_back"
    $dBack = DiffIn $c0 $c1 $BarRect
    Record "B11" "Backspace 가 검색어를 한 글자 지운다" "바 안 변화 >0" "$($dBack.n) px ($($dBack.bbox))" ($dBack.n -gt 0)
    TzSend @($VK.Left) 350
    $c2 = Shot "B11_left"
    $dLeft = DiffIn $c1 $c2 $BarRect
    TzSend @($VK.Home) 350
    $c3 = Shot "B11_home"
    $dHome = DiffIn $c2 $c3 $BarRect
    TzSend @($VK.End) 350
    $c4 = Shot "B11_end"
    $dEnd = DiffIn $c3 $c4 $BarRect
    Record "B11b" "left · Home · End 로 caret 이 움직인다" "각 단계 >0 px" "left=$($dLeft.n) home=$($dHome.n) end=$($dEnd.n)" ($dLeft.n -gt 0 -and $dHome.n -gt 0 -and $dEnd.n -gt 0)

    # B12 — 320 pt 를 넘는 검색어에서 caret 이 글자와 안 어긋난다. 확대본을 남겨 눈으로 본다.
    for ($i = 0; $i -lt 12; $i++) { TzSend @($VK.Back) 40 }
    TzType "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" 50
    Start-Sleep -Milliseconds 700
    $long = Shot "B12_long"
    [TzSearch]::Crop($long, (Join-Path $Out "B12_bar.png"), ($Bar.x - 4), ($Bar.y - 4), ($Bar.w + 8), ($Bar.h + 8), 4)
    $dLong = DiffIn $c4 $long $BarRect
    Record "B12" "긴 검색어가 가로로 스크롤된다 (확대본 육안)" "바 안 변화 >0" "$($dLong.n) px · 확대본 B12_bar.png" ($dLong.n -gt 0)

    # B14 · B15 — 삼킴. 앱이 PTY 로 아무 바이트도 보내지 않아야 한다.
    $rxA = Rx-Len
    TzSend @($VK.Ctrl, $VK.C) 500
    $rxB = Rx-Len
    Record "B14" "Ctrl+C 가 삼켜진다 (셸에 SIGINT 안 감)" "PTY +0 바이트" "+$($rxB - $rxA)" (($rxB - $rxA) -eq 0)
    $rxC = Rx-Len
    TzSend @($VK.Up) 250; TzSend @($VK.Down) 250; TzSend @($VK.PgUp) 250; TzSend @($VK.PgDn) 250; TzSend @($VK.Tab) 250
    Start-Sleep -Milliseconds 400
    $rxD = Rx-Len
    Record "B15" "up · down · PgUp · PgDn · Tab 이 삼켜진다" "PTY +0 바이트" "+$($rxD - $rxC)" (($rxD - $rxC) -eq 0)

    # B13 — Esc 로 닫으면 강조가 남김없이 사라진다. **탭을 만들기 전에** 본다 — 탭이 2 개면 탭바의
    # 활성 탭 선이 `TAB_ACCENT_COLOR` 라 검색 강조와 **같은 색**이어서 판정이 오염된다 (첫 회차에서
    # 그 300 px 를 "안 지워진 강조" 로 읽었다).
    $beforeEsc = Shot "B13_before"
    TzSend @($VK.Esc) 900
    $afterEsc = Shot "B13_after"
    $aAfter = (AmberN $afterEsc).n; $dAfter = (DarkN $afterEsc).n
    $barGone = DiffIn $beforeEsc $afterEsc $BarRect
    Record "B13" "Esc 로 닫히고 강조가 사라진다" "amber 0 · dark 0 · 바 자리 변함" "amber=$aAfter dark=$dAfter · 바 자리 $($barGone.n) px" ($aAfter -eq 0 -and $dAfter -eq 0 -and $barGone.n -gt 0)

    # B16 — 검색바에 포커스가 있어도 탭 전환 · pane 단축키가 돈다. 다시 열고 검색어를 넣어 둔다.
    TzSend @($VK.Ctrl, $VK.Shift, $VK.F) 900
    TzType "FINDME3" 60
    Start-Sleep -Milliseconds 800
    $beforeTab = Shot "B16_before"
    TzSend @($VK.Ctrl, $VK.Shift, $VK.T) 2500
    $afterTab = Shot "B16_newtab"
    $dTab = DiffOf $beforeTab $afterTab
    # 창이 탭바만큼 커지면 크기가 달라 -1 이 나온다 — 그것도 탭이 생겼다는 증거다.
    Record "B16" "검색바 포커스에서도 새 탭 단축키가 돈다" "화면이 바뀐다" "$($dTab.n) px (-1 = 창 크기 변함)" ($dTab.n -ne 0)
    # ⚠️ 탭바가 생기면 창이 그만큼 커지고 **바도 같이 내려간다** (A5 에서 확인한 정상 동작).
    # 여기서 `$BarRect` 를 갱신하지 않으면 뒤 항목이 옛 자리를 봐서 전부 `0 px` 이 된다.
    $wrT = New-Object TzSearch+RECT
    [void][TzSearch]::GetWindowRect($h, [ref]$wrT)
    $grewT = ($wrT.B - $wrT.T) - ($wr.B - $wr.T)
    if ($grewT -ne 0) {
        $BarRect = @{ x = $Bar.x; y = ($Bar.y + $grewT); w = $Bar.w; h = $Bar.h }
        "탭바가 생겨 창이 $grewT px 커졌다 — 바 판정 영역을 y $($Bar.y) -> $($BarRect.y) 로 옮긴다"
    }
    TzSend @($VK.Alt, $VK.D1) 1200
    $tab1 = Shot "B16_tab1"
    TzSend @($VK.Alt, $VK.D2) 1200
    $tab2 = Shot "B16_tab2"
    $dSwitch = DiffOf $tab1 $tab2
    Record "B16b" "Alt+1 · Alt+2 탭 전환이 돈다" "두 탭 화면이 다르다" "$($dSwitch.n) px" ($dSwitch.n -ne 0)

    # B17 — 붙여넣기는 검색어로 들어가고 **여러 줄이면 첫 줄만** 들어간다.
    # ⚠️ **분할 앞에** 둔다 — 분할로 생긴 새 pane 에는 검색바가 없어서 (상태는 pane 별) 그 뒤에
    # 두면 타이핑도 붙여넣기도 갈 곳이 없다 (첫 회차에서 0 px 로 거짓 실패했다).
    # ⚠️ 앞의 B16b 가 탭 2 에 가 있다 — 그 탭에는 검색바가 없다 (상태는 pane 별). 탭 1 로 돌아온다.
    TzSend @($VK.Alt, $VK.D1) 1500
    Set-Clipboard -Value "PASTED_FIRST`nSECOND_LINE`nTHIRD"
    Start-Sleep -Milliseconds 400
    "클립보드: " + ((Get-Clipboard -Raw) -replace "`r?`n", "\n")
    for ($i = 0; $i -lt 10; $i++) { TzSend @($VK.Back) 40 }
    Start-Sleep -Milliseconds 400
    $p0 = Shot "B17_before"
    TzSend @($VK.Ctrl, $VK.Shift, $VK.V) 1200
    $p1 = Shot "B17_paste"
    $dp = DiffIn $p0 $p1 $BarRect
    Record "B17" "붙여넣기가 검색어로 들어간다 (첫 줄만 — 확대본 육안)" "바 안 변화 >0" "$($dp.n) px · 확대본 B17_bar.png" ($dp.n -gt 0)
    [TzSearch]::Crop($p1, (Join-Path $Out "B17_bar.png"), ($BarRect.x - 4), ($BarRect.y - 4), ($BarRect.w + 8), ($BarRect.h + 8), 4)

    # B16d — pane 을 나누고 **검색바에 포커스가 있는 채로** pane 이동 단축키가 도는지.
    # 활성 pane 은 amber 선으로 표시되므로 (#483 4b) 그 선이 옮겨 가는 것으로 판정한다.
    # 먼저 **검색바를 연 채** 분할을 시도하고, 안 되면 **닫고 다시** 시도한다 — 두 결과가 다르면
    # `.shortcut` 이 검색 중에 안 도는 것이고 (SPEC §5.1 은 항상 `run_action` 이다) 같으면 환경 탓이다.
    $pre = Shot "B16d_pre"
    TzSend @($VK.Ctrl, $VK.Shift, $VK.Right) 2500
    $split = Shot "B16d_split_searching"
    $dSplitOpen = DiffOf $pre $split
    TzSend @($VK.Esc) 800
    $closed2 = Shot "B16d_closed"
    TzSend @($VK.Ctrl, $VK.Shift, $VK.Right) 2500
    $split2 = Shot "B16d_split_closed"
    $dSplitClosed = DiffOf $closed2 $split2
    Record "B16d" "검색바가 열려 있어도 분할 단축키가 돈다" "열림/닫힘 결과가 같다" "열린 채 $($dSplitOpen.n) px · 닫고 $($dSplitClosed.n) px" (($dSplitOpen.n -ne 0) -eq ($dSplitClosed.n -ne 0))
    # pane 이 둘이 된 뒤 pane 이동. 활성 pane 은 amber 선으로 표시되므로 (#483 4b) 그 선이 옮겨 간다.
    TzSend @($VK.Alt, $VK.Left) 1200
    $focusL = Shot "B16d_focus_left"
    TzSend @($VK.Alt, $VK.Right) 1200
    $focusR = Shot "B16d_focus_right"
    $dL = DiffOf $split2 $focusL
    $dR = DiffOf $focusL $focusR
    Record "B16e" "Alt+←/→ 로 pane 포커스가 옮겨 간다" "각 단계에서 화면이 바뀐다" "Alt+left $($dL.n) px · Alt+right $($dR.n) px" ($dL.n -ne 0 -and $dR.n -ne 0)


    # B16c — 탭 1 로 돌아오면 그 pane 의 검색이 그대로 살아 있다 (상태는 pane 별 · SPEC §2.9).
    # 앞의 B16d 가 대조군을 만드느라 바를 닫았으므로 다시 연다 — 그래야 "탭을 오가도 남아 있다" 를
    # 묻는 질문이 성립한다.
    TzSend @($VK.Ctrl, $VK.Shift, $VK.F) 900
    TzSend @($VK.Alt, $VK.D2) 1500
    $tab2 = Shot "B16c_tab2"
    TzSend @($VK.Alt, $VK.D1) 1500
    $back1 = Shot "B16c_back_tab1"
    $dBack = DiffIn $tab2 $back1 $BarRect
    # 탭 2 에는 바가 없고 탭 1 에는 있다 — 그 자리가 달라지는 것이 곧 복원의 증거다.
    # (강조 픽셀로는 못 본다 — 이 시점 검색어는 B17 이 붙여넣은 `PASTED_FIRST` 라 매치가 0 이다.)
    Record "B16c" "탭을 오가도 그 pane 의 검색바가 복원된다" "탭 2 와 바 자리가 다르다" "바 자리 차이 $($dBack.n) px" ($dBack.n -gt 1000)
}

# ================================================================= C. IME (MS-IME 한국어)
if ($Mode -eq 'C') {
    # 한국어 layout 을 **창 스레드에만** 올린다 (`deadkey-check_windows.ps1` 과 같은 방법) —
    # `WM_INPUTLANGCHANGEREQUEST` 를 PostMessage 하면 `DefWindowProc` 이 그 스레드의 layout 만 바꾼다.
    # 사용자의 다른 창도 세션 기본값도 그대로다. 끝에 되돌린다.
    $before = [TzSearch]::Layouts()
    $hkl = [TzSearch]::LoadKeyboardLayoutW("00000412", 0)
    $loadedByUs = ($hkl -ne [IntPtr]::Zero) -and -not ($before -contains $hkl)
    $prevHkl = [TzSearch]::LayoutOfWindow($h)
    if ($hkl -eq [IntPtr]::Zero) {
        Record "C-pre" "한국어 IME layout 로드" "hkl != 0" "로드 실패 — IME 항목을 건너뛴다" $false
    } else {
        [void][TzSearch]::PostMessageW($h, 0x0050, [IntPtr]::Zero, $hkl)
        Start-Sleep -Milliseconds 600
        $now = [TzSearch]::LayoutOfWindow($h)
        $switched = ($now -eq $hkl)
        Record "C-pre" "창 스레드만 한국어 layout 으로" "hkl 일치" ("이전 0x{0:x8} -> 지금 0x{1:x8} (요청 0x{2:x8})" -f [int64]$prevHkl, [int64]$now, [int64]$hkl) $switched
        if ($switched) {
            # 한글 모드 켜기 (한/영). 켜졌는지는 조합이 생기는지로 본다.
            TzSend @($VK.Hangul) 700

            # C18 — 조합 글자가 **검색바 안**에 보인다. `r` `k` = ㄱ+ㅏ = 가.
            $c18base = Shot "C18_base"
            TzSend @($VK.R) 350
            TzSend @($VK.K) 700
            $c18 = Shot "C18_preedit"
            $dBar = DiffIn $c18base $c18 $BarRect
            $dTerm = DiffIn $c18base $c18 $TermRect
            # 터미널 영역 변화에서 바 안 변화를 뺀 것이 "바 밖에서 바뀐 픽셀" 이다.
            $outside = $dTerm.n - $dBar.n
            Record "C18" "조합 글자가 검색바 안에 보인다" "바 안 >0 · 바 밖 0" "바 안 $($dBar.n) px · 바 밖 $outside px" ($dBar.n -gt 0 -and $outside -eq 0)
            [TzSearch]::Crop($c18, (Join-Path $Out "C18_bar.png"), ($Bar.x - 4), ($Bar.y - 4), ($Bar.w + 8), ($Bar.h + 8), 4)

            # C20 — 한자 후보창이 **검색바 caret 아래**에 뜬다.
            # ⚠️ 후보창은 `EnumWindows` 로 못 찾는다 (한국어 IME 의 후보 UI 는 창 목록에 우리가 보는
            # 모양으로 나타나지 않는다 — 2026-09-16 실측에서 "새 창 0 개" 인데 화면에는 또렷이 떠
            # 있었다). 그래서 **화면 캡처의 그 영역이 바뀌는지**로 판정한다. 창 클래스에 안 기댄다.
            $barScreenY = $wr.T + $Bar.y + $Bar.h
            $barScreenX = $wr.L + $Bar.x
            # 검색바 바로 아래 · 가로로 바 근처. 우리 창 밖이라 PrintWindow 가 아니라 화면 캡처다.
            $CandRect = @{ x = ($barScreenX - 120); y = $barScreenY; w = 560; h = 380 }
            $scr0 = ShotScreen "C20_before"
            Start-Sleep -Milliseconds 400
            $scrIdle = ShotScreen "C20_idle"
            $idle = DiffIn $scr0 $scrIdle $CandRect       # 양성 대조 — 가만두면 안 바뀐다
            TzSend @($VK.Hanja) 1500
            $scr = ShotScreen "C20_hanja"
            $dCand = DiffIn $scrIdle $scr $CandRect
            $bbCand = ParseBBox $dCand.bbox
            "검색바 아래 기준점 (화면 좌표): $barScreenX,$barScreenY · 후보 영역 $($CandRect.x),$($CandRect.y) $($CandRect.w)x$($CandRect.h)"
            $okC20 = ($dCand.n -gt 2000 -and $idle.n -lt 200)
            $where = if ($bbCand) { "bbox $($dCand.bbox) (바 기준 dx=$($bbCand.x - $barScreenX) dy=$($bbCand.y - $barScreenY))" } else { "변화 없음" }
            Record "C20" "한자 후보창이 검색바 caret 아래에 뜬다" "그 영역이 크게 바뀐다 (유휴는 0)" "유휴 $($idle.n) px · 한자키 뒤 $($dCand.n) px · $where" $okC20
            [TzSearch]::Crop($scr, (Join-Path $Out "C20_zoom.png"), $CandRect.x, ($CandRect.y - 60), $CandRect.w, ($CandRect.h + 60), 1)
            # 후보창과 조합을 정리한다. ⚠️ `Esc` 는 후보창 → 조합 → **검색바** 순으로 먹으므로
            # 두 번 보내면 바까지 닫힌다 (첫 회차에서 그 뒤 타이핑이 터미널로 갔다 — C19 · C-bs 가
            # "바 안 0 px" 로 거짓 실패했다). 닫혔는지 캡처로 확인하고 필요하면 다시 연다.
            TzSend @($VK.Esc) 600
            TzSend @($VK.Esc) 600
            $chk = Shot "C_after_esc"
            $barNow = DiffIn $opened $chk $BarRect
            if ($barNow.n -gt 2000) {
                "  검색바가 닫혔다 (바 자리 $($barNow.n) px) — 다시 연다"
                TzSend @($VK.Ctrl, $VK.Shift, $VK.F) 900
            }

            # C19 — 스크롤을 올려 둔 채 조합해도 화면이 맨 아래로 안 끌려간다.
            MoveClient $NeutralPt 2
            for ($i = 0; $i -lt 8; $i++) { [TzSearch]::Wheel(1); Start-Sleep -Milliseconds 60 }
            Start-Sleep -Milliseconds 700
            Guard
            $c19base = Shot "C19_scrolled"
            TzSend @($VK.R) 350
            TzSend @($VK.K) 700
            $c19 = Shot "C19_preedit"
            $dBar2 = DiffIn $c19base $c19 $BarRect
            $dTerm2 = DiffIn $c19base $c19 $TermRect
            $outside2 = $dTerm2.n - $dBar2.n
            Record "C19" "조합해도 화면이 맨 아래로 안 끌려간다" "바 밖 0 px" "바 안 $($dBar2.n) px · 바 밖 $outside2 px" ($outside2 -eq 0)

            # C-bs — Backspace 는 **두 경우를 갈라 봐야 한다** (AGENTS.md `# 한글 IME 동작 스펙`).
            #  ① 조합 중이면 IME 가 **자모 단위**로 되돌린다 (`가` → `ㄱ`) — 이것이 사양이다.
            #  ② 확정된 글자는 **한 글자씩** 사라진다.
            # 첫 회차에 ① 을 보고 "자모 단위라 틀렸다" 로 읽을 뻔했다. 확정은 IME 가 모르는 키
            # (여기서는 `←`) 로 시킨다 — 그 키가 현재 음절을 commit 한다.
            TzSend @($VK.R) 300; TzSend @($VK.K) 500      # 가 (조합 중)
            $bsA0 = Shot "Cbs_composing"
            TzSend @($VK.Back) 600
            $bsA1 = Shot "Cbs_composing_back"
            $dbsA = DiffIn $bsA0 $bsA1 $BarRect
            Record "C-bs1" "조합 중 Backspace 는 자모 단위로 되돌린다" "바 안 변화 >0" "$($dbsA.n) px (확대본 Cbs_composing*.png)" ($dbsA.n -gt 0)
            [TzSearch]::Crop($bsA0, (Join-Path $Out "Cbs_composing_bar.png"), ($Bar.x - 4), ($Bar.y - 4), ($Bar.w + 8), ($Bar.h + 8), 4)
            [TzSearch]::Crop($bsA1, (Join-Path $Out "Cbs_composing_back_bar.png"), ($Bar.x - 4), ($Bar.y - 4), ($Bar.w + 8), ($Bar.h + 8), 4)

            # ② 확정된 글자 — `←` 로 commit 시키고 `End` 로 caret 을 끝에 둔 뒤 지운다.
            TzSend @($VK.R) 300; TzSend @($VK.K) 500      # 가 (다시 조합)
            TzSend @($VK.Left) 500                         # IME 가 모르는 키 → 현재 음절 commit
            TzSend @($VK.End) 400
            $bs0 = Shot "Cbs_committed"
            TzSend @($VK.Back) 700
            $bs1 = Shot "Cbs_committed_back"
            $dbs = DiffIn $bs0 $bs1 $BarRect
            Record "C-bs2" "확정된 한글은 Backspace 한 번에 한 글자" "바 안 변화 >0" "$($dbs.n) px (확대본 Cbs_committed*.png)" ($dbs.n -gt 0)
            [TzSearch]::Crop($bs0, (Join-Path $Out "Cbs_committed_bar.png"), ($Bar.x - 4), ($Bar.y - 4), ($Bar.w + 8), ($Bar.h + 8), 4)
            [TzSearch]::Crop($bs1, (Join-Path $Out "Cbs_committed_back_bar.png"), ($Bar.x - 4), ($Bar.y - 4), ($Bar.w + 8), ($Bar.h + 8), 4)

            # 한/영 을 원래대로 (영문) 돌려 놓는다.
            TzSend @($VK.Hangul) 500
        }
    }
    if ($prevHkl -ne [IntPtr]::Zero -and $prevHkl -ne $hkl) {
        [void][TzSearch]::PostMessageW($h, 0x0050, [IntPtr]::Zero, $prevHkl)
        Start-Sleep -Milliseconds 400
        "창 layout 복구: 0x{0:x8}" -f [int64][TzSearch]::LayoutOfWindow($h)
    }
    if ($loadedByUs) { "세션에서 layout 내림: $([TzSearch]::UnloadKeyboardLayout($hkl))" }
    "세션 layout (후): " + (([TzSearch]::Layouts() | ForEach-Object { '0x{0:x8}' -f [int64]$_ }) -join ' ')
}

# ================================================================= D. 마우스
if ($Mode -eq 'D') {
    TzType "FINDME3"
    Start-Sleep -Milliseconds 900
    # **선택을 먼저 만든다** — 타이핑만으로는 고른 매치가 없어 (카운터가 개수만 나온다)
    # `'>' 로 갔다가 '<' 로 돌아온다` 가 대칭이 되지 않는다.
    TzSend @($VK.Enter) 900
    $ready = Shot "D_ready"
    $m0 = ParseBBox (AmberN $ready).bbox

    # D24 — 컨트롤 hover 강조.
    MoveClient $PtCount 2; Start-Sleep -Milliseconds 400
    $hb = Shot "D24_base"
    MoveClient $PtNext 4
    $hn = Shot "D24_hover_next"
    $dh = DiffIn $hb $hn $BarRect
    $curNext = [TzSearch]::CursorName()
    Record "D24" "컨트롤에 hover 강조가 켜진다" ">0 px" "$($dh.n) px ($($dh.bbox))" ($dh.n -gt 0)

    # D28 — 커서 모양. 입력칸 위는 I-beam, 컨트롤 · 여백 위는 화살표.
    MoveClient $PtField 4; Start-Sleep -Milliseconds 300
    $curField = [TzSearch]::CursorName()
    MoveClient $PtCount 4; Start-Sleep -Milliseconds 300
    $curCount = [TzSearch]::CursorName()
    MoveClient $NeutralPt 4; Start-Sleep -Milliseconds 300
    $curTerm = [TzSearch]::CursorName()
    Record "D28" "커서 — 입력칸 I-beam · 컨트롤/여백 화살표 · 터미널 I-beam" "ibeam · arrow · arrow · ibeam" "field=$curField · next=$curNext · count=$curCount · term=$curTerm" ($curField -eq 'ibeam' -and $curNext -eq 'arrow' -and $curCount -eq 'arrow' -and $curTerm -eq 'ibeam')

    # D23 — `›` `‹` 클릭이 다음 · 이전 매치로 간다.
    MoveClient $PtNext 4
    Guard; [TzSearch]::ClickHere(); Start-Sleep -Milliseconds 900
    $n1 = Shot "D23_next"
    $mn = ParseBBox (AmberN $n1).bbox
    MoveClient $PtPrev 4
    Guard; [TzSearch]::ClickHere(); Start-Sleep -Milliseconds 900
    $p1 = Shot "D23_prev"
    $mp = ParseBBox (AmberN $p1).bbox
    $okD23 = ($mn -ne $null -and $mp -ne $null -and $mn.y -ne $m0.y -and $mp.y -eq $m0.y)
    Record "D23" "'>' 클릭은 다음 · '<' 클릭은 이전" "next 로 이동 · prev 로 복귀" "시작 y=$($m0.y) · next y=$($mn.y) · prev y=$($mp.y)" $okD23

    # D25 — 입력칸 글자 사이 클릭으로 caret 이 그 자리로 간다.
    $cb = Shot "D25_base"
    MoveClient $PtField 4
    Guard; [TzSearch]::ClickHere(); Start-Sleep -Milliseconds 600
    $ca = Shot "D25_click"
    $dc = DiffIn $cb $ca $BarRect
    Record "D25" "입력칸 클릭으로 caret 이 그 자리로" "바 안 변화 >0" "$($dc.n) px ($($dc.bbox))" ($dc.n -gt 0)
    [TzSearch]::Crop($ca, (Join-Path $Out "D25_bar.png"), ($Bar.x - 4), ($Bar.y - 4), ($Bar.w + 8), ($Bar.h + 8), 4)

    # D26 — 바 위에서 드래그해도 터미널 선택이 안 생긴다. 선택은 터미널 영역 픽셀이 바뀌는 것으로 본다.
    $sb = Shot "D26_base"
    $s0 = [TzSearch]::ClientToScreenPt($h, $PtField[0], $PtField[1])
    $s1 = [TzSearch]::ClientToScreenPt($h, ($PtField[0] - 200), ($PtField[1] - 60))
    Guard; [TzSearch]::DragTo($s0.x, $s0.y, $s1.x, $s1.y); Start-Sleep -Milliseconds 800
    $sa = Shot "D26_drag"
    $ds = DiffIn $sb $sa $TermRect
    Record "D26" "바에서 시작한 드래그는 터미널 선택을 안 만든다" "터미널 0 px" "$($ds.n) px ($($ds.bbox))" ($ds.n -eq 0)

    # D29 — 바가 열려 있어도 터미널 드래그 선택과 휠 스크롤은 평소대로.
    # ⚠️ `-Mouse` 회차에서는 **성립하지 않는다** — 앱이 마우스를 잡으면 드래그 선택에 `Shift` 가
    # 필요하고 (SPEC §3) 휠도 앱으로 가서 화면이 안 바뀐다. 그건 검색바와 무관한 사양이다.
    if ($Mouse) {
        Record "D29" "터미널 드래그 · 휠 (마우스 리포팅 회차는 건너뜀)" "해당 없음" "-Mouse 회차 — SPEC §3 대로 Shift 가 필요하다" $true
    } else {
    $tb = Shot "D29_base"
    $t0 = [TzSearch]::ClientToScreenPt($h, 60, 120)
    $t1 = [TzSearch]::ClientToScreenPt($h, 300, 160)
    Guard; [TzSearch]::DragTo($t0.x, $t0.y, $t1.x, $t1.y); Start-Sleep -Milliseconds 700
    $ta = Shot "D29_select"
    $dt = DiffIn $tb $ta $TermRect
    Record "D29" "터미널 드래그 선택이 평소대로 된다" ">0 px" "$($dt.n) px ($($dt.bbox))" ($dt.n -gt 0)
    $wb = Shot "D29_wheel_base"
    MoveClient $NeutralPt 2
    for ($i = 0; $i -lt 4; $i++) { [TzSearch]::Wheel(1); Start-Sleep -Milliseconds 80 }
    Start-Sleep -Milliseconds 600
    $wa = Shot "D29_wheel"
    $dw = DiffIn $wb $wa $TermRect
    Record "D29b" "바가 열려 있어도 휠이 터미널로 간다" ">0 px" "$($dw.n) px" ($dw.n -gt 0)
    }

    # D27 — 마우스 리포팅을 켠 앱 (`-Mouse` 로 자식이 `DECSET 1000`) 에 **바 위 클릭이 전달되지
    # 않는다.** Linux 회차는 vim 으로 쟀지만, 자식이 raw 바이트를 받으므로 여기서는 PTY 로 나간
    # 바이트를 직접 센다 — 더 강한 판정이다. 터미널 본문 클릭을 대조군으로 함께 둔다.
    if ($Mouse) {
        $r0 = Rx-Len
        MoveClient @(120, 200) 3
        Guard; [TzSearch]::ClickHere(); Start-Sleep -Milliseconds 700
        $r1 = Rx-Len
        MoveClient $PtField 3
        Guard; [TzSearch]::ClickHere(); Start-Sleep -Milliseconds 700
        $r2 = Rx-Len
        MoveClient $PtNext 3
        Guard; [TzSearch]::ClickHere(); Start-Sleep -Milliseconds 700
        $r3 = Rx-Len
        Record "D27" "마우스 리포팅 앱에 바 위 클릭이 안 간다" "본문 +>0 · 바 +0" "본문 +$($r1 - $r0) · 입력칸 +$($r2 - $r1) · 컨트롤 +$($r3 - $r2)" (($r1 - $r0) -gt 0 -and ($r2 - $r1) -eq 0 -and ($r3 - $r2) -eq 0)
    }

    # D23c — `x` 클릭으로 닫힌다.
    MoveClient $PtClose 4
    Guard; [TzSearch]::ClickHere(); Start-Sleep -Milliseconds 900
    $cl = Shot "D23c_close"
    $aCl = (AmberN $cl).n; $dCl = (DarkN $cl).n
    $gone = DiffIn $ready $cl $BarRect
    Record "D23c" "'x' 클릭으로 닫히고 강조가 사라진다" "amber 0 · dark 0" "amber=$aCl dark=$dCl · 바 자리 $($gone.n) px" ($aCl -eq 0 -and $dCl -eq 0 -and $gone.n -gt 0)
}

# ================================================================= E. 메뉴
if ($Mode -eq 'E') {
    # 메뉴는 컨트롤 스트립의 `...` 다. 탭이 1 개면 `+ x ...` 가 창 오른쪽 위에 있다.
    TzSend @($VK.Esc) 600      # 검색바를 닫고 메뉴만 본다
    $menuBase = Shot "E_base"
    $MorePt = @([int]($CW - 13 * $S), [int](13 * $S))
    MoveClient $MorePt 4
    Guard; [TzSearch]::ClickHere(); Start-Sleep -Milliseconds 900
    $menu = Shot "E30_menu"
    $dm = DiffOf $menuBase $menu
    $mb = ParseBBox $dm.bbox
    Record "E30" "'...' 클릭으로 메뉴가 열린다" ">0 px" "$($dm.n) px ($($dm.bbox))" ($dm.n -gt 0)
    if ($mb) {
        [TzSearch]::Crop($menu, (Join-Path $Out "E30_menu_zoom.png"), $mb.x, $mb.y, $mb.w, $mb.h, 2)
        "메뉴 확대: $(Join-Path $Out 'E30_menu_zoom.png')  (항목 · 차례 · 화살표 글리프를 눈으로 본다 — E30 · E31)"
    }
    # E32 — 메뉴의 `Find` 로 검색바가 열린다. 항목 자리는 확대본에서 읽어 넣는다.
    # 자동 판정은 "메뉴를 닫고 Ctrl+Shift+F 와 같은 결과인가" 로 대신하지 않는다 — 클릭을 실제로 한다.
    # `Find` 는 목록의 8 번째 줄 (Show/Hide · 구분선 · New Tab · Close Tab · Split LR · Split UD · Copy · Paste · Find).
    if ($mb) {
        # 항목 자리는 `command_menu.zig` 의 상수로 계산한다 (PADDING 6 · ITEM 22 · SEPARATOR 9).
        # `entries` 차례: toggle · 구분선 · new_tab · close_tab · split_right · split_down ·
        # copy · paste · **find** · fullscreen · 구분선 · open_config · open_log · shortcuts · about.
        # Find 앞에는 항목 7 개와 구분선 1 개가 있다.
        $ITEMH = [int](22 * $S); $SEPH = [int](9 * $S); $MPAD = [int](6 * $S)
        $findY = $mb.y + $MPAD + $ITEMH * 7 + $SEPH + [int]($ITEMH / 2)
        $findPt = ToClient ($mb.x + [int]($mb.w / 2)) $findY
        "메뉴 Find 항목 y (계산): $findY  (메뉴 $($mb.y)..$($mb.y + $mb.h))"
        MoveClient $findPt 4
        $hoverShot = Shot "E32_hover_find"
        [TzSearch]::Crop($hoverShot, (Join-Path $Out "E32_hover.png"), $mb.x, $mb.y, $mb.w, $mb.h, 2)
        Guard; [TzSearch]::ClickHere(); Start-Sleep -Milliseconds 1000
        $afterFind = Shot "E32_after"
        $dFind = DiffIn $menuBase $afterFind $BarRect
        Record "E32" "메뉴 Find 로 검색바가 열린다" "바 자리 >0 px" "$($dFind.n) px (hover 확대본 E32_hover.png 로 어느 항목을 눌렀는지 확인)" ($dFind.n -gt 0)
    }
    # E32b — `Open Log` 가 로그 파일을 연다. 연결 프로그램 (메모장 등) 창이 새로 뜬다.
    # ⚠️ 그 창이 foreground 를 가져가므로 **맨 뒤에** 둔다 (AGENTS.md 의 같은 규칙 — `link-click-check`
    # 첫 회차에서 브라우저 뒤 케이스가 막혔다).
    TzSend @($VK.Esc) 600
    $winBefore = [TzSearch]::VisibleWindows(0)
    MoveClient $MorePt 4
    Guard; [TzSearch]::ClickHere(); Start-Sleep -Milliseconds 900
    $menu2 = Shot "E32b_menu"
    $dm2 = DiffOf $menuBase $menu2
    $mb2 = ParseBBox $dm2.bbox
    if ($mb2) {
        # `Open Log` 는 두 번째 구분선 뒤 두 번째 항목이다 — 앞에 항목 10 개와 구분선 2 개.
        $logY = $mb2.y + [int](6 * $S) + [int](22 * $S) * 10 + [int](9 * $S) * 2 + [int](22 * $S / 2)
        $logPt = ToClient ($mb2.x + [int]($mb2.w / 2)) $logY
        MoveClient $logPt 4
        $hov = Shot "E32b_hover_openlog"
        [TzSearch]::Crop($hov, (Join-Path $Out "E32b_hover.png"), $mb2.x, $mb2.y, $mb2.w, $mb2.h, 2)
        Guard; [TzSearch]::ClickHere(); Start-Sleep -Seconds 3
        $winAfter = [TzSearch]::VisibleWindows(0)
        $new = @($winAfter | Where-Object { $winBefore -notcontains $_ })
        $viewer = @($new | Where-Object { $_ -match 'tildaz_stress|tildaz_9|\.log' })
        "새로 뜬 창:"; $new | ForEach-Object { "    $_" }
        Record "E32b" "메뉴 Open Log 가 로그를 연다" "로그 뷰어 창이 뜬다" "새 창 $($new.Count) 개 · 로그로 보이는 것 $($viewer.Count) 개" ($viewer.Count -gt 0)
        # 띄운 뷰어를 닫는다 — 우리가 띄운 것이므로 되돌린다.
        foreach ($w in $viewer) {
            $pid2 = [int]($w.Split('|')[0])
            Stop-Process -Id $pid2 -Force -ErrorAction SilentlyContinue
        }
    }

    # E33 — 좁은 창에서 **힌트가 먼저 숨고 라벨은 온전하다.** 창은 `WM_WINDOWPOSCHANGING` 이
    # 의도한 rect 로 되돌리므로 `SetWindowPos` 로 못 좁힌다 — **`-Size` 를 좁게 주어 다시 띄운다.**
    Record "E33" "좁은 창의 메뉴 (별도 회차)" "-Size 를 좁게 준 회차에서 본다" "이 회차의 client 폭 $CW — 좁은 회차는 -Mode E -Size 30x20" $true
}


[TzSearch]::Topmost($h, $false)
if (-not $Keep) { Stop-Tz; Start-Sleep -Milliseconds 400 }
if ($madeCfg) { Remove-Item $Cfg9 -Force -ErrorAction SilentlyContinue; "config_9.toml 삭제" }
""
"결과: {0} PASS / {1} 항목" -f @($results | Where-Object { $_.ok }).Count, $results.Count
$results | Where-Object { -not $_.ok } | ForEach-Object { "  FAIL {0} {1} — 기대 [{2}] 받음 [{3}]" -f $_.id, $_.what, $_.expect, $_.got }
"캡처: $Out"
"정리: 인스턴스 9 종료=$(-not $Keep) · config_9.toml 존재=" + (Test-Path $Cfg9)
