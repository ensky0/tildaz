# 여러 tildaz 판을 **같은 화면**으로 띄워 창을 찍고 최종 그림을 픽셀 수로 견준다 (Windows · PowerShell 5.1).
# macOS 의 `dist/macos/render-ab-shot.sh` · Linux 의 `dist/linux/render-ab-shot.sh` 에 대응한다 — #586 Windows atlas `grow`
# 실기에서 만들었다. #584 의 Windows 계측 (같은 기기) 이 밟은 함정을 그대로 피한다.
#
# ```powershell
# dist\windows\render-ab-shot.ps1 -Screen <화면.cmd> -Size <격자> -Wait <대기초> -Tag <태그> -Bins <exeA>,<exeB>[,<exeC> …]
# dist\windows\render-ab-shot.ps1 -Screen $env:TEMP\stack2.cmd -Size 150x40 -Wait 8 -Tag stack2 -Bins $env:TEMP\tildaz-4096.exe,zig-out\bin\tildaz.exe
# ```
#
# - 화면은 **`.cmd` 래퍼**다 — `-e` 가 `CreateProcessW` 에 명령줄을 통째로 넘기므로 인자도 되지만, `chcp 65001` 과
#   대기 (`timeout /t 3600 /nobreak >nul`) 가 필요해 배치 파일로 감싼다. `dist/screens/clusters.py` 의 출력에서
#   heredoc 본문만 UTF-8 (BOM 없음) 텍스트로 저장하고 `type` 으로 뿌린다. 끝의 대기가 없으면 자식이 끝나며 앱도 끝난다.
# - 판마다 `--instance 9 -e <화면> -size <격자>` 로 띄운다. `-e` 는 stress run 이라 **hotkey 를 등록하지 않고**
#   (`global hotkey not registered (stress run)`) config 도 만들지 않으며 로그는 `%APPDATA%\tildaz\tildaz_stress.log` 다
#   (`run_options.zig` 의 `isStressRun` · `paths.zig` 의 `logFileName`). 사용자의 instance 0 은 건드리지 않는다.
# - **창 찾기** — `Process.MainWindowHandle` 은 `TildaZOwner` (0x0 · `WS_EX_TOOLWINDOW`) 가 owner 로 달린 진짜 창을
#   건너뛰어 0 을 준다 (#584 실측). `EnumWindows` 로 그 pid 의 **보이는 · 크기 있는** 창을 고른다.
# - **DPI** — PowerShell 은 DPI 비인식이라 `GetWindowRect` 가 논리 좌표를 준다 (150 % 에서 1272x989 창이 848x659 로).
#   `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)` 를 먼저 부른다.
# - **캡처는 `PrintWindow(PW_RENDERFULLCONTENT)`** — 가려져 있어도 DWM 이 합성한 최신 내용을 준다 (#413 에서 다섯
#   터미널 전부 성공). 결과가 단색이면 (창이 이미 닫혔거나 아직 안 그렸다) `CopyFromScreen` 으로 한 번 물러선다.
# - **픽셀 대조는 `LockBits`** 로 직접 센다 — 이 기기에 ImageMagick 이 없고, 있어도 `compare -metric AE` 는 소수 · 지수
#   표기를 내서 (AGENTS.md) 쓰지 않는다. 크기가 다르면 그것부터 알린다.
# - 판정에는 로그의 `atlas grew` · `atlas full` 회수를 같이 본다 — `grow` 가 정확하면 **시작 크기가 달라도 최종 그림이
#   같고**, `atlas full` 은 0 이어야 한다 (SPEC §12.6 ②).
# - 실기라서 **시작 전에 창이 몇 번 뜨는지 알리고 동의를 받는다** (AGENTS.md `# 실행 환경`). 회차 동안 키 · 마우스를
#   건드리면 그 회차가 오염된다.
#
# ⚠️ 이 파일은 **UTF-8 BOM** 으로 저장한다 — Windows PowerShell 5.1 은 BOM 없는 `.ps1` 을 ANSI (cp949) 로 읽어 한글
# 주석이 토큰까지 깨뜨릴 수 있다 (`compare-terminals.sh` 의 같은 주석).

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Screen,
    [Parameter(Mandatory)][string]$Size,
    [int]$Wait = 8,
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][string[]]$Bins,
    # 판마다 몇 번 띄울지. 회차 간 비결정을 보려면 2 이상.
    [int]$Repeat = 1,
    # 창이 뜬 뒤 `Ctrl+Shift+T` 를 합성 입력으로 보내 **탭을 하나 더 만든다** — 탭바 · 컨트롤 스트립 아이콘이
    # 그려진 화면을 견줄 때 (#586 W-a: 본문 atlas 만 커진 뒤 탭 atlas 의 UV 정규화가 맞는지). 단축키는
    # `config_9.toml` 이 있어야 산다 (AGENTS.md `# config_N.toml 이 없는 실행에는 …`) — `config_0.toml` 을
    # 복사해 `auto_start = false` 로 두고, 끝나면 지운다. 합성 입력이라 시작 전 사용자 동의가 필요하다.
    [switch]$NewTab
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class TzShot {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public static void MakeDpiAware() {
    try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch {}
    try { SetProcessDPIAware(); } catch {}
  }
  // pid 의 보이는 · 크기 있는 최상위 창. owner 창 (0x0) 은 크기 조건에서 떨어진다.
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
  public static Bitmap Capture(IntPtr h, out string how) {
    RECT r; GetWindowRect(h, out r);
    int w = r.R - r.L, hh = r.B - r.T;
    var bmp = new Bitmap(w, hh, PixelFormat.Format32bppArgb);
    using (var g = Graphics.FromImage(bmp)) {
      IntPtr hdc = g.GetHdc();
      bool ok = PrintWindow(h, hdc, 2);
      g.ReleaseHdc(hdc);
      how = ok ? "PrintWindow" : "PrintWindow(failed)";
    }
    if (IsUniform(bmp)) {
      using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(r.L, r.T, 0, 0, new Size(w, hh));
      how += "->CopyFromScreen";
    }
    return bmp;
  }
  static bool IsUniform(Bitmap b) {
    var d = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    try {
      var px = new int[b.Width * b.Height];
      Marshal.Copy(d.Scan0, px, 0, px.Length);
      for (int i = 1; i < px.Length; i++) if (px[i] != px[0]) return false;
      return true;
    } finally { b.UnlockBits(d); }
  }
  // 두 PNG 의 다른 픽셀 수. 크기가 다르면 -1. `bbox` 는 다른 픽셀의 경계 상자 (x,y,w,h) — 커서 자리처럼
  // 좁은 차이인지 한눈에 가른다.
  public static long Diff(string a, string b, out long total, out string bbox) {
    bbox = "";
    using (var A = new Bitmap(a)) using (var B = new Bitmap(b)) {
      total = (long)A.Width * A.Height;
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
  // ---- 합성 입력 (`-NewTab`) — `dist/stress/send-keys.ps1` 과 같은 규칙: SendInput · scan code 채움 ·
  //      포커스 가드 (foreground 가 아니면 SetForegroundWindow → 그래도 아니면 client 한가운데 클릭 → 확인).
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Explicit, Size = 40)] public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; [FieldOffset(8)] public MOUSEINPUT mi; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
  [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] p, int cb);
  [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint c, uint t);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  static INPUT Key(ushort vk, uint flags) {
    var i = new INPUT(); i.type = 1; i.ki.wVk = vk; i.ki.wScan = (ushort)MapVirtualKeyW(vk, 0); i.ki.dwFlags = flags; return i;
  }
  static INPUT Mouse(int nx, int ny, uint flags) { var i = new INPUT(); i.type = 0; i.mi.dx = nx; i.mi.dy = ny; i.mi.dwFlags = flags; return i; }
  static void Norm(int x, int y, out int nx, out int ny) {
    int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
    nx = (int)(((long)(x - vx) * 65535) / (vw > 1 ? vw - 1 : 1)); ny = (int)(((long)(y - vy) * 65535) / (vh > 1 ? vh - 1 : 1));
  }
  // 겹쳐 누르는 chord — 앞에서부터 누르고 뒤에서부터 뗀다.
  public static uint Chord(ushort[] vks) {
    var a = new INPUT[vks.Length * 2]; int n = 0;
    foreach (var v in vks) a[n++] = Key(v, 0);
    for (int k = vks.Length - 1; k >= 0; k--) a[n++] = Key(vks[k], 2);
    return SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
  }
  public static bool Focus(IntPtr h) {
    if (GetForegroundWindow() == h) return true;
    SetForegroundWindow(h); System.Threading.Thread.Sleep(300);
    if (GetForegroundWindow() == h) return true;
    RECT r; GetClientRect(h, out r);
    var p = new POINT(); p.x = (r.R - r.L) / 2; p.y = (r.B - r.T) / 2; ClientToScreen(h, ref p);
    POINT before; bool hc = GetCursorPos(out before);
    int nx, ny; Norm(p.x, p.y, out nx, out ny);
    uint mv = 0x0001 | 0x8000 | 0x4000;
    var a = new INPUT[] { Mouse(nx, ny, mv), Mouse(nx, ny, mv | 0x0002), Mouse(nx, ny, mv | 0x0004) };
    SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
    System.Threading.Thread.Sleep(300);
    if (hc) { int bx, by; Norm(before.x, before.y, out bx, out by); var m = new INPUT[] { Mouse(bx, by, mv) }; SendInput(1, m, Marshal.SizeOf(typeof(INPUT))); }
    return GetForegroundWindow() == h;
  }
}
"@
[TzShot]::MakeDpiAware()

$Out = Join-Path $env:TEMP "tildaz-ab-shot\$Tag"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Log = Join-Path $env:APPDATA "tildaz\tildaz_stress.log"
if (-not (Test-Path $Screen)) { throw "화면 없음: $Screen" }

# 인스턴스 9 만 내린다 — 명령줄에 `--instance 9` 가 있는 tildaz 만.
function Stop-Tz {
    Get-CimInstance Win32_Process -Filter "Name like 'tildaz%'" |
        Where-Object { $_.CommandLine -match '--instance 9' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

"md5:"
foreach ($b in $Bins) {
    if (-not (Test-Path $b)) { throw "바이너리 없음: $b" }
    "  {0}  {1}" -f (Get-FileHash -Algorithm MD5 $b).Hash.ToLower(), $b
}
# 앞선 로그는 치운다 (측정 전용 파일 — 사용자 설정과 무관).
if (Test-Path $Log) { Move-Item $Log (Join-Path $Out "log_prev.txt") -Force }

$shots = @()
$i = 0
foreach ($bin in $Bins) {
    for ($rep = 1; $rep -le $Repeat; $rep++) {
        $i++
        Stop-Tz; Start-Sleep -Milliseconds 500
        if (Test-Path $Log) { Remove-Item $Log -Force }
        $p = Start-Process -FilePath (Resolve-Path $bin) -PassThru -ArgumentList '--instance', '9', '-e', "`"$Screen`"", '-size', $Size
        $h = [IntPtr]::Zero
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($h -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 10000) {
            Start-Sleep -Milliseconds 100
            if ($p.HasExited) { break }
            $h = [TzShot]::FindWindowOfPid([uint32]$p.Id)
        }
        if ($p.HasExited) { "판 $i 가 먼저 끝남 exit=$($p.ExitCode) — $bin"; continue }
        if ($h -eq [IntPtr]::Zero) { "판 $i 창 못 찾음 — $bin"; Stop-Tz; continue }
        if ($NewTab) {
            Start-Sleep -Seconds 2
            if ([TzShot]::Focus($h)) {
                [void][TzShot]::Chord([uint16[]]@(0x11, 0x10, 0x54))   # Ctrl+Shift+T
            } else {
                "판 $i 포커스를 못 잡아 새 탭 키를 보내지 않았다"
            }
        }
        Start-Sleep -Seconds $Wait
        $how = ""
        $bmp = [TzShot]::Capture($h, [ref]$how)
        $png = Join-Path $Out "shot_$i.png"
        $bmp.Save($png, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        Start-Sleep -Milliseconds 300
        $logCopy = Join-Path $Out "log_$i.txt"
        if (Test-Path $Log) { Copy-Item $Log $logCopy -Force } else { "(로그 없음)" | Set-Content $logCopy }
        Stop-Tz; Start-Sleep -Milliseconds 500
        $lines = Get-Content $logCopy -Encoding UTF8
        $grew = @($lines | Where-Object { $_ -match 'atlas grew' })
        $full = @($lines | Where-Object { $_ -match 'atlas full' })
        $path = [string]($lines | Where-Object { $_ -match 'render_path=' } | Select-Object -First 1) -replace '.*(render_path=\S+).*', '$1'
        $cell = [string]($lines | Where-Object { $_ -match 'window initialized' } | Select-Object -First 1) -replace '.*(dpi=\S+ cell=\S+).*', '$1'
        $fatal = @($lines | Where-Object { $_ -match '\[fatal\]' })
        if ($fatal.Count -gt 0) {
            $m = $fatal[0] -replace '^\[[^\]]+\]\s*', ''
            if ($m.Length -gt 160) { $m = $m.Substring(0, 160) + "…" }
            "판 $i fatal: $m"
        }
        "판 {0}: {1} · {2} · grew={3} full={4} · {5} · {6} · {7}" -f $i, (Split-Path $bin -Leaf), $how, $grew.Count, $full.Count, $path, $cell, $png
        foreach ($g in $grew) { "    " + ($g -replace '^\[[^\]]+\]\s*', '') }
        $shots += $png
    }
}
if ($shots.Count -ge 2) {
    for ($j = 1; $j -lt $shots.Count; $j++) {
        $tot = [long]0; $bbox = ""
        $n = [TzShot]::Diff($shots[0], $shots[$j], [ref]$tot, [ref]$bbox)
        if ($n -lt 0) { "판 1 vs 판 $($j+1): 크기 다름" }
        elseif ($n -eq 0) { "판 1 vs 판 $($j+1): 0 / $tot px" }
        else { "판 1 vs 판 $($j+1): $n / $tot px  (다른 영역 $bbox)" }
    }
}
"캡처 · 로그: $Out"
