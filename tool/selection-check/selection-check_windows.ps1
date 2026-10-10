# #656 — 마우스 선택 · 오른쪽 클릭 · 더블 클릭이 클립보드와 앱에 무엇을 남기는지 **자동으로** 재는 Windows 몫.
# macOS 판 (`selection-check_macos.sh`) 의 여섯 칸을 그대로 옮겼다. Windows 에는 PRIMARY 가 없다.
# 같은 칸을 **Windows Terminal** 에서도 돌려 견준다 (`-Target wt`).
#
# ```powershell
# powershell -NoProfile -ExecutionPolicy Bypass -File C:\…\tool\selection-check\selection-check_windows.ps1
# … -Target tildaz                       # tildaz 만 (여섯 칸)
# … -Target wt                           # Windows Terminal 만 (기본값 회차 네 칸)
# … -Target wt -WtCopyOnSelect           # WT 의 ⑤ ⑥ 도 — settings.json 의 copyOnSelect 를 잠깐 true 로 바꾼다
# … -Bin C:\path\tildaz.exe
# ```
#
# 무엇을 하나 —
# 1. 측정 창을 띄운다. 자식은 0 행에 `COPYME word2` 를 찍고, **받은 바이트를 hex 로 파일에** 남긴다.
#    tildaz 는 `--instance 9 -e <자식>` (config 도 hotkey 등록도 안 만든다), WT 는 `wt -w new -f` (focus 모드 —
#    탭 줄 · 제목 줄이 없어 0 행이 창 맨 위다).
# 2. `SendInput` 으로 끌어 선택 · 오른쪽 클릭 · 더블 클릭을 하고, 클립보드와 받은 바이트로 판정한다.
# 3. tildaz 는 기본값 회차 끝에 **Windows 전용 칸** (⑦~⑪) 을 더 본다 — 메뉴가 열린 채 오른쪽 클릭 ·
#    `Ctrl+Shift+C` · 메뉴 *Copy* · 비활성 pane 오른쪽 클릭 (선택 없을 때 · 활성 pane 에 선택이 있을 때).
#    pane 판정은 로그의 `focus by click` 줄과 pane 마다의 수신 파일 (`recv_….txt` · `….txt.2`) 이다. `-NoExtra` 로 뺀다.
# 4. tildaz 는 기본값 회차 뒤 `copy_on_select = true` 회차. 그 회차만 `config_9.toml` 을 잠깐 만들고 지운다.
#
# 좌표 —
#  - tildaz 는 앱 로그의 `window initialized: dpi= cell=WxH` 와 여백 `round(6 pt × dpi / 96)` 로 계산한다
#    (`ui_metrics.TERMINAL_PADDING_PT`). 탭이 하나라 탭바가 없다.
#  - WT 는 로그가 없어서 **캡처에서 0 행 글자의 잉크 범위**를 찾아 셀 폭을 추정한다 (12 글자).
#
# 함정 —
#  - **수신자는 python 이 아니라 PowerShell 이다.** python 이 Store 스텁뿐인 기기가 있다 (AGENTS.md
#    `# Windows — 합성 입력으로 …`). `Read-Host` 는 Enter 를 기다려 붙여넣은 `COPYME` 를 못 받으므로,
#    콘솔을 `ENABLE_VIRTUAL_TERMINAL_INPUT` 하나로 바꾸고 `ReadFile` 로 받는다 (`tool/key-bytes.py` 와 같은 모드).
#  - **클립보드를 잠깐 바꾼다.** 시작 때 글자를 저장하고 끝나면 되돌린다. 순수 글자 말고 다른 형식
#    (`HTML Format` · 이미지 · 파일) 이 함께 있으면 되돌릴 수 없어서 손대지 않고 멈춘다 — macOS 판이
#    HTML 서식을 한 번 잃었다. 브라우저에서 복사한 것은 대개 `HTML Format` 을 함께 담는다.
#  - `-WtCopyOnSelect` 는 **사용자의 WT 설정 파일**을 고친다 — 시작 전 사본을 두고 끝나면 바이트 그대로
#    되돌린다. WT 는 그 파일을 바로 다시 읽는다.
#  - 마우스가 연결되지 않은 기기도 `SendInput` 의 마우스 이벤트는 앱에 닿는다 (커서만 안 보인다).
#  - 키 · 마우스마다 포커스 가드다 — foreground 가 측정 창이 아니면 멈춘다. 합성 입력은 포커스된 창으로 간다.
#
# 실기라서 **시작 전에 알리고 동의를 받는다** (AGENTS.md `# 실행 환경`) — 측정 창이 tildaz 두 번 · WT 한두 번
# 뜨고 합성 클릭이 나간다. 그동안 키보드 · 마우스를 건드리지 않는다.
#
# ⚠️ 이 파일은 UTF-8 **BOM** 으로 저장한다 — Windows PowerShell 5.1 은 BOM 없는 `.ps1` 을 cp949 로 읽는다.
[CmdletBinding()]
param(
    [ValidateSet('all', 'tildaz', 'wt')][string]$Target = 'all',
    # 기본값은 본문에서 채운다 — `[CmdletBinding()]` 의 param 기본값에서는 `$PSScriptRoot` 가 비어 있다.
    [string]$Bin = '',
    [switch]$WtCopyOnSelect,
    # tildaz 기본값 회차 끝의 Windows 전용 칸 (⑦~⑪) 을 건너뛴다.
    [switch]$NoExtra
)

$ErrorActionPreference = 'Stop'
if (-not $Bin) { $Bin = Join-Path $PSScriptRoot '..\..\zig-out\bin\tildaz.exe' }
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class TzSel {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  // CharSet.Unicode 가 없으면 StringBuilder 가 ANSI 로 마샬돼 첫 글자 ("C") 만 돌아온다 — 클래스 비교가 늘 어긋난다.
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] p, int cb);
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Explicit, Size = 40)] public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public MOUSEINPUT mi; [FieldOffset(8)] public KEYBDINPUT ki; }
  [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint c, uint t);

  public static void MakeDpiAware() { try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch {} }
  // `Process.MainWindowHandle` 은 owner 가 달린 진짜 창을 건너뛰어 0 이다 (#584) — pid + 보임 + 크기로 찾는다.
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
  // 보이는 창 중 그 클래스인 것 전부 — WT 는 이미 떠 있는 프로세스에 새 창을 만들 수 있어 pid 로 못 찾는다.
  public static IntPtr[] WindowsOfClass(string cls) {
    var list = new List<IntPtr>();
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      var s = new System.Text.StringBuilder(128); GetClassNameW(h, s, 128);
      if (s.ToString() == cls) list.Add(h);
      return true;
    }, IntPtr.Zero);
    return list.ToArray();
  }
  public static POINT ToScreen(IntPtr h, int x, int y) { var p = new POINT(); p.x = x; p.y = y; ClientToScreen(h, ref p); return p; }
  // 창의 클라이언트 영역을 화면에서 찍는다 — 회차 동안 창이 맨 위라 다른 창이 끼지 않는다.
  public static Bitmap CaptureClient(IntPtr h) {
    RECT c; GetClientRect(h, out c);
    var o = ToScreen(h, 0, 0);
    var bmp = new Bitmap(c.R, c.B, PixelFormat.Format32bppArgb);
    using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(o.x, o.y, 0, 0, new Size(c.R, c.B));
    return bmp;
  }
  // 첫 글자 줄의 잉크 범위 "x0 x1 y0 y1" (클라이언트 px). 밝기 > 110 을 잉크로 본다.
  // WT 의 클라이언트 영역은 둥근 모서리 · 테두리까지 덮어 **가장자리에 뒤쪽 창이 비친다** — 그래서 가장자리
  // 6 px 를 빼고, 높이가 8 px 이상인 띠만 글자 줄로 본다 (2026-10-10 첫 회차가 위 3 px 의 비친 글자를 잡았다).
  static bool Ink(Bitmap b, int x, int y) { Color c = b.GetPixel(x, y); return (c.R * 299 + c.G * 587 + c.B * 114) / 1000 > 110; }
  public static string FirstTextRow(Bitmap b) {
    const int M = 6;
    int y0 = -1;
    for (int y = M; y < b.Height - M; y++) {
      bool any = false;
      for (int x = M; x < b.Width - M && !any; x++) any = Ink(b, x, y);
      if (any) { if (y0 < 0) y0 = y; continue; }
      if (y0 >= 0 && y - y0 >= 8) {
        int x0 = int.MaxValue, x1 = -1;
        for (int yy = y0; yy < y; yy++)
          for (int x = M; x < b.Width - M; x++)
            if (Ink(b, x, yy)) { if (x < x0) x0 = x; if (x > x1) x1 = x; }
        return string.Format("{0} {1} {2} {3}", x0, x1, y0, y - 1);
      }
      y0 = -1;
    }
    return "";
  }
  static INPUT Mouse(int nx, int ny, uint flags) { var i = new INPUT(); i.type = 0; i.mi.dx = nx; i.mi.dy = ny; i.mi.dwFlags = flags; return i; }
  static void Send(uint flags) { var a = new INPUT[] { Mouse(0, 0, flags) }; SendInput(1, a, Marshal.SizeOf(typeof(INPUT))); }
  public static void MoveTo(int x, int y) {
    int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
    int nx = (int)(((long)(x - vx) * 65535) / (vw > 1 ? vw - 1 : 1)), ny = (int)(((long)(y - vy) * 65535) / (vh > 1 ? vh - 1 : 1));
    var a = new INPUT[] { Mouse(nx, ny, 0x0001 | 0x8000 | 0x4000) };   // MOVE | ABSOLUTE | VIRTUALDESK
    SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
  }
  // 누른 채 여섯 걸음으로 끌어서 뗀다 (link-click-check 의 DragTo 와 같다).
  public static void Drag(int x0, int y, int x1) {
    MoveTo(x0, y); System.Threading.Thread.Sleep(120);
    Send(0x0002); System.Threading.Thread.Sleep(120);
    for (int k = 1; k <= 6; k++) { MoveTo(x0 + (x1 - x0) * k / 6, y); System.Threading.Thread.Sleep(40); }
    System.Threading.Thread.Sleep(120);
    Send(0x0004);
  }
  public static void LeftClick(int x, int y) { MoveTo(x, y); System.Threading.Thread.Sleep(100); Send(0x0002); System.Threading.Thread.Sleep(80); Send(0x0004); }
  public static string Describe(IntPtr h) {
    var c = new System.Text.StringBuilder(128); GetClassNameW(h, c, 128);
    uint p; GetWindowThreadProcessId(h, out p);
    return string.Format("hwnd={0} pid={1} class={2}", h, p, c);
  }
  public static void RightClick(int x, int y) { MoveTo(x, y); System.Threading.Thread.Sleep(100); Send(0x0008); System.Threading.Thread.Sleep(80); Send(0x0010); }
  // 더블 클릭 — 두 번 사이를 시스템 더블 클릭 시간 (기본 500 ms) 보다 훨씬 짧게 둔다.
  public static void DoubleClick(int x, int y) {
    MoveTo(x, y); System.Threading.Thread.Sleep(100);
    Send(0x0002); Send(0x0004); System.Threading.Thread.Sleep(60); Send(0x0002); Send(0x0004);
  }
  // 키 — INPUT 은 PowerShell 이 아니라 여기서 만든다 (중첩 값 타입 대입이 PowerShell 에서 조용히 사라진다 · AGENTS.md).
  // control pad (방향 · Home 등) 는 확장 (0xE0) 플래그가 있어야 numpad 로 안 간다.
  static INPUT Key(ushort vk, bool up) {
    var i = new INPUT(); i.type = 1; i.ki.wVk = vk; i.ki.wScan = (ushort)MapVirtualKeyW(vk, 0);
    bool ext = vk == 0x21 || vk == 0x22 || vk == 0x23 || vk == 0x24 || vk == 0x25 || vk == 0x26 || vk == 0x27 || vk == 0x28;
    i.ki.dwFlags = (uint)((up ? 2 : 0) | (ext ? 1 : 0)); return i;
  }
  // 순서대로 누르고 역순으로 뗀다.
  public static uint Chord(ushort[] keys) {
    var a = new INPUT[keys.Length * 2];
    for (int i = 0; i < keys.Length; i++) a[i] = Key(keys[i], false);
    for (int i = 0; i < keys.Length; i++) a[keys.Length + i] = Key(keys[keys.Length - 1 - i], true);
    return SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void Topmost(IntPtr h, bool on) { SetWindowPos(h, new IntPtr(on ? -1 : -2), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); }
}
"@
[TzSel]::MakeDpiAware()

if (-not (Test-Path $Bin) -and $Target -ne 'wt') { throw "바이너리 없음: $Bin" }
$W = Join-Path $env:TEMP 'tildaz-selection-check'
New-Item -ItemType Directory -Force -Path $W | Out-Null

# ── 클립보드 — 순수 글자만 있거나 비어 있을 때만 진행한다 ────────────────────────────────
$TextFormats = @('UnicodeText', 'Text', 'OEMText', 'Locale', 'System.String')
function Clip-Formats { $d = [System.Windows.Forms.Clipboard]::GetDataObject(); if ($d) { @($d.GetFormats($false)) } else { @() } }
# 앱이 클립보드를 쥐고 있는 순간에는 열기가 실패한다 — 몇 번 다시 해 본다.
function Clip-Try([scriptblock]$f) {
    for ($k = 0; $k -lt 10; $k++) { try { return (& $f) } catch { Start-Sleep -Milliseconds 100 } }
    return (& $f)
}
function Clip-Get { Clip-Try { [System.Windows.Forms.Clipboard]::GetText() } }
function Clip-Set([string]$s) { Clip-Try { [System.Windows.Forms.Clipboard]::SetText($s) } | Out-Null }
$others = @(Clip-Formats | Where-Object { $TextFormats -notcontains $_ })
if ($others.Count -gt 0) { throw "클립보드에 글자 말고 다른 형식이 있다 ($($others -join ', ')) — 되돌릴 수 없어서 멈춘다" }
$ClipBak = Clip-Get
$ClipWasEmpty = (@(Clip-Formats).Count -eq 0)

# ── 수신자 — 0 행에 `COPYME word2` 를 찍고 받은 바이트를 hex 로 남긴다 ─────────────────────
$Child = Join-Path $W 'child.ps1'
$childSrc = @'
$base = $args[0]
# pane 을 나누면 같은 `-e` 명령이 한 번 더 뜬다 — 뒤에 뜬 자식은 `<이름>.2` 처럼 비어 있는 이름을 고른다.
$out = $base; $k = 2
while ($true) { try { [IO.File]::Open($out, 'CreateNew').Close(); break } catch { $out = "$base.$k"; $k++ } }
[Console]::Out.Write("COPYME word2`r`n")
$sig = '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n); [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m); [DllImport("kernel32.dll")] public static extern bool ReadFile(IntPtr h, byte[] b, int n, out int r, IntPtr o);'
$K = Add-Type -MemberDefinition $sig -Name Con -Namespace TzSelChild -PassThru
$h = $K::GetStdHandle(-10)
[void]$K::SetConsoleMode($h, 0x0200)          # ENABLE_VIRTUAL_TERMINAL_INPUT 만 — 줄 편집 · 에코 끔
[IO.File]::AppendAllText($out, "[ready]`r`n")
$buf = New-Object byte[] 256
while ($true) {
    $n = 0
    if (-not $K::ReadFile($h, $buf, 256, [ref]$n, [IntPtr]::Zero) -or $n -eq 0) { break }
    $hex = ($buf[0..($n - 1)] | ForEach-Object { '{0:x2}' -f $_ }) -join ' '
    [IO.File]::AppendAllText($out, $hex + "`r`n")
}
'@
[IO.File]::WriteAllText($Child, $childSrc, (New-Object System.Text.UTF8Encoding $true))

function Hex-Of([string]$s) { ([Text.Encoding]::UTF8.GetBytes($s) | ForEach-Object { '{0:x2}' -f $_ }) -join ' ' }
function Lines-Of([string]$f = $script:OUT) { if (Test-Path $f) { @(Get-Content $f) } else { @() } }
function Hex-Since([int]$n, [string]$f = $script:OUT) {
    $l = Lines-Of $f
    if ($l.Count -le $n) { return '' }
    (@($l[$n..($l.Count - 1)] | Where-Object { $_ -match '^[0-9a-f]{2}( [0-9a-f]{2})*$' })) -join ' '
}
$script:fail = 0
$script:rows = @()
function Verdict([string]$name, [string]$wantClip, [string]$wantApp, [int]$n) {   # '-' = 안 봄, '' = 없음
    $gc = Clip-Get; $ga = Hex-Since $n; $ok = 'OK'
    if ($wantClip -ne '-' -and $gc -cne $wantClip) { $ok = 'FAIL' }
    if ($wantApp -ne '-' -and $ga -ne $wantApp) { $ok = 'FAIL' }
    if ($ok -ne 'OK') { $script:fail = 1 }
    $line = '{0,-4} {1,-38} 클립보드=[{2}]  앱=[{3}]' -f $ok, $name, $gc, $ga
    $line
    $script:rows += "$($script:who)`t$line"
}
function Guard {
    $fg = [TzSel]::GetForegroundWindow()
    if ($fg -ne $script:H) { throw "foreground 가 측정 창이 아니다 — 합성 입력을 멈춘다 (앞에 있는 창 $([TzSel]::Describe($fg)) · $((Get-Process -Id ([TzSel]::Describe($fg) -replace '.*pid=(\d+).*', '$1') -ErrorAction SilentlyContinue).ProcessName))" }
}

# ── tildaz ──────────────────────────────────────────────────────────────────────────
$LogDirs = @((Join-Path $env:APPDATA 'tildaz-dev'), (Join-Path $env:APPDATA 'tildaz'))
function Stop-Tz {
    Get-CimInstance Win32_Process -Filter "Name like 'tildaz%'" |
        Where-Object { $_.CommandLine -match '--instance 9' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    for ($k = 0; $k -lt 25; $k++) {
        if (@(Get-CimInstance Win32_Process -Filter "Name like 'tildaz%'" | Where-Object { $_.CommandLine -match '--instance 9' }).Count -eq 0) { return }
        Start-Sleep -Milliseconds 200
    }
    "⚠️ 인스턴스 9 가 5 초 안에 안 내려갔다"
}
function Stop-Child {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($Child) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
function Wait-Ready {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 20000) {
        if ((Lines-Of) -contains '[ready]') { Start-Sleep -Milliseconds 800; return }
        Start-Sleep -Milliseconds 200
    }
    throw "수신자가 준비되지 않았다 — $($script:OUT)"
}
function Launch-Tz([string]$tag) {
    $script:OUT = Join-Path $W "recv_tildaz_$tag.txt"; Remove-Item "$($script:OUT)*" -ErrorAction SilentlyContinue
    Stop-Tz
    $before = @{}; foreach ($d in $LogDirs) { $f = Join-Path $d 'tildaz_stress.log'; $before[$d] = if (Test-Path $f) { @(Get-Content $f).Count } else { 0 } }
    $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File $Child $($script:OUT)"
    # `-e` 의 값은 따옴표로 감싼다 — `Start-Process` 는 공백 있는 원소를 감싸 주지 않는다 (AGENTS.md).
    $p = Start-Process -FilePath (Resolve-Path $Bin) -PassThru -ArgumentList '--instance', '9', '-e', "`"$cmd`"", '-size', '60x12'
    $sw = [Diagnostics.Stopwatch]::StartNew(); $script:H = [IntPtr]::Zero
    while ($script:H -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 15000) {
        Start-Sleep -Milliseconds 150
        if ($p.HasExited) { throw "앱이 먼저 끝났다 exit=$($p.ExitCode)" }
        $script:H = [TzSel]::FindWindowOfPid([uint32]$p.Id)
    }
    if ($script:H -eq [IntPtr]::Zero) { throw "tildaz 창을 못 찾았다" }
    Wait-Ready
    # 이번 실행이 쓴 줄에서 dpi · cell 을 읽는다. 어느 판 (dev · 릴리즈) 인지도 여기서 갈린다.
    $init = $null
    foreach ($d in $LogDirs) {
        $f = Join-Path $d 'tildaz_stress.log'; if (-not (Test-Path $f)) { continue }
        $new = @(Get-Content $f -Encoding UTF8 | Select-Object -Skip $before[$d])
        if (@($new | Where-Object { $_ -match '\[fatal\]' }).Count -gt 0) { throw "앱 로그에 [fatal] 이 있다 — $f" }
        $m = @($new | Where-Object { $_ -match 'window initialized: dpi=(\d+) cell=(\d+)x(\d+)' })
        if ($m.Count -gt 0) { [void]($m[-1] -match 'dpi=(\d+) cell=(\d+)x(\d+)'); $init = $Matches; $script:AppDir = $d }
    }
    if (-not $init) { throw "로그에서 'window initialized' 줄을 못 찾았다" }
    $dpi = [int]$init[1]; $cw = [int]$init[2]; $ch = [int]$init[3]
    $script:Scale = $dpi / 96.0
    $script:LogFile = Join-Path $script:AppDir 'tildaz_stress.log'
    $pad = [int][Math]::Round(6 * $dpi / 96.0, [MidpointRounding]::AwayFromZero)
    $y = $pad + [int]($ch / 2)
    $script:P0 = [TzSel]::ToScreen($script:H, $pad + [int]($cw / 2), $y)
    $script:P5 = [TzSel]::ToScreen($script:H, $pad + [int]($cw * 5.5), $y)
    $script:PW = [TzSel]::ToScreen($script:H, $pad + [int]($cw * 8.5), $y)
    "     창 hwnd=$($script:H)  dpi=$dpi cell=${cw}x${ch} pad=$pad · 0 행 y=$($script:P0.y) x=$($script:P0.x)..$($script:P5.x) (판: $(Split-Path $script:AppDir -Leaf))"
    Focus-Up
}
function Focus-Up {
    [TzSel]::Topmost($script:H, $true)
    for ($k = 0; $k -lt 5 -and [TzSel]::GetForegroundWindow() -ne $script:H; $k++) { [void][TzSel]::SetForegroundWindow($script:H); Start-Sleep -Milliseconds 300 }
    # `SetForegroundWindow` 는 남의 프로세스가 foreground 면 조용히 무시된다 — WT 는 그 경우다 (wt.exe 가
    # 띄우고 바로 끝나 창 주인은 다른 프로세스다). 창 안 맨 아래 빈 자리를 한 번 클릭해 되찾는다 (AGENTS.md).
    if ([TzSel]::GetForegroundWindow() -ne $script:H) {
        $c = New-Object TzSel+RECT; [void][TzSel]::GetClientRect($script:H, [ref]$c)
        $p = [TzSel]::ToScreen($script:H, [int]($c.R * 0.7), $c.B - 8)
        [TzSel]::LeftClick($p.x, $p.y); Start-Sleep -Milliseconds 500
    }
    if ([TzSel]::GetForegroundWindow() -ne $script:H) {
        throw "측정 창이 포커스를 못 받았다 — 측정 창 $([TzSel]::Describe($script:H)) · 앞에 있는 창 $([TzSel]::Describe([TzSel]::GetForegroundWindow()))"
    }
}
function Shot([string]$tag) {
    $bmp = [TzSel]::CaptureClient($script:H); $bmp.Save((Join-Path $W "shot_$($script:who)_$tag.png"), [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}
function Drag-Row0 { Guard; [TzSel]::Drag($script:P0.x, $script:P0.y, $script:P5.x); Start-Sleep -Milliseconds 600 }
function Right-Here { Guard; [TzSel]::RightClick($script:P0.x, $script:P0.y); Start-Sleep -Milliseconds 800 }
function Double-Word { Guard; [TzSel]::DoubleClick($script:PW.x, $script:PW.y); Start-Sleep -Milliseconds 800 }
$SEL = 'COPYME'

# 기본값 회차 네 칸 — tildaz · WT 공용.
function Default-Cells {
    Clip-Set 'ORIG'
    $n = (Lines-Of).Count; Drag-Row0;   Verdict '① 끌어 선택' 'ORIG' '' $n
    Shot 'after_drag'
    $n = (Lines-Of).Count; Right-Here;  Verdict '② 선택 있는 채 오른쪽 클릭' $SEL '' $n
    $n = (Lines-Of).Count; Right-Here;  Verdict '③ 선택 없이 오른쪽 클릭' '-' (Hex-Of $SEL) $n
    Clip-Set 'ORIG2'
    $n = (Lines-Of).Count; Double-Word; Verdict '④ 더블 클릭 (word2)' 'ORIG2' '' $n
    Shot 'after_double'
    # ④ 는 클릭이 안 닿아도 통과하는 부정 판정이다 — 이어서 오른쪽 클릭으로 그 선택이 정말 있었는지 본다
    # (①은 ②가 같은 증거다). macOS 판에는 없는 줄이다.
    $n = (Lines-Of).Count; Right-Here;  Verdict '  ④ 의 증거 — 이어서 오른쪽 클릭' 'word2' '' $n
}
# ── Windows 전용 칸 (tildaz 기본값 회차 끝) — 오른쪽 클릭의 두 예외와 명시적 복사 ─────────────
# 오른쪽 클릭은 **메뉴 닫기 → 비활성 pane 포커스 → 선택 복사 → 붙여넣기** 순서로 판정된다
# (`app_controller.zig` 의 `.mouse_right_down`). 앞 둘은 "아무 일도 안 한다" 가 기대라, 칸마다 이어서
# 오른쪽 클릭을 한 번 더 해 **그 조작이 실제로 닿았다**는 증거를 함께 본다.
$VK = @{ Ctrl = 0x11; Shift = 0x10; C = 0x43; Right = 0x27; Home = 0x24; Down = 0x28; Enter = 0x0D }
function Log-Count { if ($script:LogFile -and (Test-Path $script:LogFile)) { @(Get-Content $script:LogFile -Encoding UTF8).Count } else { 0 } }
function Log-Since([int]$n) { if (-not (Test-Path $script:LogFile)) { return @() }; @(Get-Content $script:LogFile -Encoding UTF8 | Select-Object -Skip $n) }
function Send-Keys([uint16[]]$keys, [int]$ms = 300) { Guard; [void][TzSel]::Chord($keys); Start-Sleep -Milliseconds $ms }
# 컨트롤 스트립 `⋯` — 창 오른쪽 위 (`actions-check_windows.ps1` 의 `MorePt` 와 같은 계산).
function Open-Menu {
    Guard
    $c = New-Object TzSel+RECT; [void][TzSel]::GetClientRect($script:H, [ref]$c)
    $p = [TzSel]::ToScreen($script:H, [int]($c.R - 13 * $script:Scale), [int](13 * $script:Scale))
    [TzSel]::LeftClick($p.x, $p.y); Start-Sleep -Milliseconds 600
}
function Click-At($pt) { Guard; [TzSel]::LeftClick($pt.x, $pt.y); Start-Sleep -Milliseconds 500 }
function Right-At($pt) { Guard; [TzSel]::RightClick($pt.x, $pt.y); Start-Sleep -Milliseconds 800 }
# 클립보드 · 두 pane 의 수신 바이트 · (있으면) 로그 줄 하나를 함께 판정한다. '-' = 안 봄, '' = 없음.
function Mark { @{ a = (Lines-Of $script:OUT).Count; b = (Lines-Of "$($script:OUT).2").Count; log = (Log-Count) } }
function Verdict2([string]$name, [string]$wantClip, [string]$wantA, [string]$wantB, $m, [string]$logRe = '') {
    $gc = Clip-Get; $ga = Hex-Since $m.a $script:OUT; $gb = Hex-Since $m.b "$($script:OUT).2"; $ok = 'OK'
    if ($wantClip -ne '-' -and $gc -cne $wantClip) { $ok = 'FAIL' }
    if ($wantA -ne '-' -and $ga -ne $wantA) { $ok = 'FAIL' }
    if ($wantB -ne '-' -and $gb -ne $wantB) { $ok = 'FAIL' }
    $gl = ''
    if ($logRe) { $hit = @(Log-Since $m.log | Where-Object { $_ -match $logRe }); if ($hit.Count -eq 0) { $ok = 'FAIL'; $gl = ' 로그=[없음]' } else { $gl = ' 로그=[' + ($hit[-1] -replace '^\[[^\]]+\]\s*', '') + ']' } }
    if ($ok -ne 'OK') { $script:fail = 1 }
    $line = '{0,-4} {1,-38} 클립보드=[{2}]  pane1=[{3}]  pane2=[{4}]{5}' -f $ok, $name, $gc, $ga, $gb, $gl
    $line
    $script:rows += "$($script:who)`t$line"
}
function Extra-Cells {
    $ORIGH = Hex-Of 'ORIG'
    # ⑦ 메뉴가 열린 채 오른쪽 클릭 — 메뉴만 닫는다.
    Clip-Set 'ORIG'; Drag-Row0; Open-Menu
    $m = Mark; Right-Here; Verdict2 '⑦ 선택 + 메뉴 연 채 오른쪽 클릭' 'ORIG' '' '-' $m
    Shot 'after_menu_right'
    $m = Mark; Right-Here; Verdict2 '  ⑦ 의 증거 — 메뉴가 닫혀 이번엔 복사' $SEL '' '-' $m
    # ⑧ Ctrl+Shift+C — copy_on_select 와 무관하게 CLIPBOARD 로.
    Clip-Set 'ORIG'; Drag-Row0
    $m = Mark; Send-Keys @($VK.Ctrl, $VK.Shift, $VK.C) 600; Verdict2 '⑧ 선택 + Ctrl+Shift+C' $SEL '' '-' $m
    # ⑨ 메뉴 Copy — 화면 차례 Show/Hide · New Tab · Close Tab · Split Right · Split Down · Copy (#712).
    Clip-Set 'ORIG'; Drag-Row0; Open-Menu
    $m = Mark
    foreach ($k in @($VK.Home, $VK.Down, $VK.Down, $VK.Down, $VK.Down, $VK.Down)) { Send-Keys @($k) 150 }
    Send-Keys @($VK.Enter) 700
    Verdict2 '⑨ 선택 + 메뉴 Copy' $SEL '' '-' $m
    # 선택을 지우고 (빈 자리 한 번 클릭) 오른쪽으로 나눈다 — 새 pane (pane 2) 이 활성이다.
    Click-At ([TzSel]::ToScreen($script:H, [int](9 * $script:Scale), [int](120 * $script:Scale)))
    $n = Log-Count; Send-Keys @($VK.Ctrl, $VK.Shift, $VK.Right) 400
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 10000 -and -not ((Lines-Of "$($script:OUT).2") -contains '[ready]')) { Start-Sleep -Milliseconds 200 }
    if (-not ((Lines-Of "$($script:OUT).2") -contains '[ready]')) { throw "분할한 pane 의 수신자가 준비되지 않았다 — 로그: $((Log-Since $n | Where-Object { $_ -match '\[pane\]' }) -join ' / ')" }
    Start-Sleep -Milliseconds 800
    "     분할: $(((Log-Since $n | Where-Object { $_ -match 'split right' }) | Select-Object -Last 1) -replace '^\[[^\]]+\]\s*', '')"
    Shot 'after_split'
    $c = New-Object TzSel+RECT; [void][TzSel]::GetClientRect($script:H, [ref]$c)
    $pane1 = $script:P0                                                  # 왼쪽 pane 의 0 행 첫 칸
    $pane2 = [TzSel]::ToScreen($script:H, [int]($c.R * 0.75), [int]($c.B * 0.5))   # 오른쪽 pane 가운데
    Clip-Set 'ORIG'
    # ⑩ 선택 없이 비활성 pane (pane 1) 을 오른쪽 클릭 — 포커스만 옮긴다.
    $m = Mark; Right-At $pane1; Verdict2 '⑩ 선택 없이 비활성 pane 오른쪽 클릭' 'ORIG' '' '' $m 'focus by click'
    $m = Mark; Right-At $pane1; Verdict2 '  ⑩ 의 증거 — 다시 누르면 그 pane 에 붙음' 'ORIG' $ORIGH '' $m
    # ⑪ 활성 pane (pane 1) 에 선택이 있는 채 비활성 pane (pane 2) 을 오른쪽 클릭 — 복사하지 않는다.
    Drag-Row0
    $m = Mark; Right-At $pane2; Verdict2 '⑪ 선택 있는 채 비활성 pane 오른쪽 클릭' 'ORIG' '' '' $m 'focus by click'
    $m = Mark; Right-At $pane2; Verdict2 '  ⑪ 의 증거 — 다시 누르면 그 pane 에 붙음' 'ORIG' '' $ORIGH $m
    Shot 'after_panes'
}
function On-Cells {
    Clip-Set 'ORIG'
    $n = (Lines-Of).Count; Drag-Row0;   Verdict '⑤ 끌어 선택' $SEL '' $n
    $n = (Lines-Of).Count; Right-Here;  Verdict '⑥ 선택 있는 채 오른쪽 클릭 (늘 붙임)' '-' (Hex-Of $SEL) $n
}

# ── Windows Terminal ────────────────────────────────────────────────────────────────
$WtClass = 'CASCADIA_HOSTING_WINDOW_CLASS'
$WtSettings = Get-ChildItem "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal*\LocalState\settings.json" -ErrorAction SilentlyContinue | Select-Object -First 1
$WtBak = Join-Path $W 'wt-settings.bak'
function Launch-Wt([string]$tag) {
    $script:OUT = Join-Path $W "recv_wt_$tag.txt"; Remove-Item "$($script:OUT)*" -ErrorAction SilentlyContinue
    $old = @([TzSel]::WindowsOfClass($WtClass))
    # -f = focus 모드 (탭 줄 · 제목 줄 없음). --size 는 칸 수.
    Start-Process wt.exe -ArgumentList '-w', 'new', '-f', '--size', '60,12', 'powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Child, $script:OUT | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew(); $script:H = [IntPtr]::Zero
    while ($script:H -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 15000) {
        Start-Sleep -Milliseconds 200
        $new = @([TzSel]::WindowsOfClass($WtClass) | Where-Object { $old -notcontains $_ })
        if ($new.Count -gt 0) { $script:H = $new[0] }
    }
    if ($script:H -eq [IntPtr]::Zero) { throw "Windows Terminal 창을 못 찾았다" }
    Wait-Ready
    Focus-Up
    Start-Sleep -Milliseconds 400
    $bmp = [TzSel]::CaptureClient($script:H)
    $bmp.Save((Join-Path $W "shot_wt_${tag}_start.png"), [Drawing.Imaging.ImageFormat]::Png)
    $r = [TzSel]::FirstTextRow($bmp); $bmp.Dispose()
    if (-not $r) { throw "WT 캡처에서 글자 줄을 못 찾았다" }
    $v = $r.Split(' ') | ForEach-Object { [int]$_ }
    # 잉크 범위는 12 글자 (`COPYME word2`) 의 첫 글자 왼쪽 ~ 끝 글자 오른쪽이다. 곁 여백을 감안해 11.6 으로 나눈다.
    $cw = ($v[1] - $v[0]) / 11.6; $y = [int](($v[2] + $v[3]) / 2)
    $script:P0 = [TzSel]::ToScreen($script:H, [int]($v[0] + $cw * 0.4), $y)
    $script:P5 = [TzSel]::ToScreen($script:H, [int]($v[0] + $cw * 5.4), $y)
    $script:PW = [TzSel]::ToScreen($script:H, [int]($v[0] + $cw * 8.4), $y)
    "     창 hwnd=$($script:H)  0 행 잉크 x=$($v[0])..$($v[1]) y=$($v[2])..$($v[3]) · 셀 폭 추정 $([Math]::Round($cw, 1)) px"
}
function Stop-Wt {
    if ($script:H -ne [IntPtr]::Zero) { [void][TzSel]::SendMessageW($script:H, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }   # WM_CLOSE
    Start-Sleep -Milliseconds 800
    Stop-Child
}
function Restore-WtSettings {
    if ((Test-Path $WtBak) -and $WtSettings) { Copy-Item $WtBak $WtSettings.FullName -Force; Remove-Item $WtBak -Force; "     WT settings.json 되돌림" }
}

$Cfg9 = $null
$script:H = [IntPtr]::Zero
$script:who = ''
try {
    if ($Target -ne 'wt') {
        foreach ($d in $LogDirs) { if (Test-Path (Join-Path $d 'config_9.toml')) { throw "$d\config_9.toml 이 이미 있다 — 덮지 않고 멈춘다" } }
        $script:who = 'tildaz'
        "===== tildaz · 기본값 (copy_on_select = false)  ($Bin)"
        Launch-Tz 'default'
        Default-Cells
        if (-not $NoExtra) { "----- Windows 전용 칸 — 오른쪽 클릭의 예외 · 명시적 복사"; Extra-Cells }
        Stop-Tz
        "===== tildaz · copy_on_select = true (임시 config_9.toml)"
        $Cfg9 = Join-Path $script:AppDir 'config_9.toml'
        # 빠진 키는 config 가 없을 때와 같은 기본값이다 (#655 · #718) — 그래서 두 줄만 적는다.
        [IO.File]::WriteAllText($Cfg9, "auto_start = false`n`n[input]`ncopy_on_select = true`n", (New-Object System.Text.UTF8Encoding $false))
        Launch-Tz 'on'
        On-Cells
        Stop-Tz
        Remove-Item $Cfg9 -Force; $Cfg9 = $null
    }
    if ($Target -ne 'tildaz') {
        if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) { throw "wt.exe 가 없다 — Windows Terminal 이 설치돼 있지 않다" }
        $wtVer = (Get-AppxPackage Microsoft.WindowsTerminal* | Select-Object -First 1).Version
        $script:who = 'wt'
        "===== Windows Terminal $wtVer · 기본값 (copyOnSelect = false)"
        if ($WtSettings -and (Select-String -Path $WtSettings.FullName -Pattern '"copyOnSelect"\s*:\s*true' -Quiet)) { throw "WT 설정이 copyOnSelect = true 다 — 기본값 회차가 성립하지 않는다" }
        Launch-Wt 'default'
        Default-Cells
        Stop-Wt
        if ($WtCopyOnSelect) {
            if (-not $WtSettings) { throw "WT settings.json 을 못 찾았다" }
            "===== Windows Terminal · copyOnSelect = true (settings.json 을 잠깐 고친다)"
            Copy-Item $WtSettings.FullName $WtBak -Force
            $txt = [IO.File]::ReadAllText($WtSettings.FullName)
            if ($txt -match '"copyOnSelect"\s*:\s*false') { $txt = $txt -replace '"copyOnSelect"\s*:\s*false', '"copyOnSelect": true' }
            else { $txt = $txt -replace '^\s*\{', "{`n    `"copyOnSelect`": true," }
            [IO.File]::WriteAllText($WtSettings.FullName, $txt, (New-Object System.Text.UTF8Encoding $false))
            Start-Sleep -Seconds 1
            Launch-Wt 'on'
            On-Cells
            Stop-Wt
            Restore-WtSettings
        }
    }
} finally {
    if ($script:H -ne [IntPtr]::Zero) { [TzSel]::Topmost($script:H, $false) }
    # 도중에 멈췄으면 WT 창을 먼저 닫는다 — 자식만 내리면 WT 가 "프로세스가 끝났다" 창을 남긴다.
    if ($script:who -eq 'wt') { Stop-Wt }
    Stop-Tz | Out-Null
    Stop-Child
    if ($Cfg9 -and (Test-Path $Cfg9)) { Remove-Item $Cfg9 -Force }
    Restore-WtSettings
    if ($ClipWasEmpty) { Clip-Try { [System.Windows.Forms.Clipboard]::Clear() } | Out-Null } else { Clip-Set $ClipBak }
}

"결과: $(if ($script:fail -eq 0) { '전부 OK' } else { '기대와 다른 칸 있음' })  (클립보드 · config_9 · WT 설정은 끝나며 되돌린다 · 캡처와 수신 바이트: $W)"
exit $script:fail
