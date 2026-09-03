# Windows 에서 kitty keyboard protocol 이 켜졌을 때 **글자 키가 PTY 에 어떤 바이트로 나가는지** 합성 입력으로 판정한다
# (#602 · #583 B5). `report_all` (flag 8) 이 켜지면 macOS · Linux 처럼 `a` 가 `CSI 97 u` 여야 하고, 꺼진 kitty
# (`disambiguate` 만) 에서는 `61` 그대로여야 한다.
#
# ```powershell
# dist\windows\kitty-text-check.ps1                          # zig-out\bin\tildaz.exe
# dist\windows\kitty-text-check.ps1 -Bin C:\path\tildaz.exe
# ```
#
# 무엇을 하나 —
# 1. `--instance 9 -e <자식.py>` 로 tildaz 를 띄운다. 자식 (Python) 은 콘솔 입력을 **`ENABLE_VIRTUAL_TERMINAL_INPUT`**
#    으로 바꿔 stdin 을 raw 바이트로 읽는다 — 그래야 앱이 PTY 에 쓴 `CSI u` 시퀀스가 ConPTY 를 지나 키 이벤트로
#    해석되지 않고 **바이트 그대로** 온다 (`Read-Host` 로는 볼 수 없다 — 그쪽은 이미 문자로 바뀐 것이다).
# 2. 자식이 stdout 에 `CSI > <flags> u` 를 써서 tildaz 의 터미널에 kitty 모드를 켠다 (앱의 VT 파서가 그 시퀀스를
#    받아 `kitty_keyboard.push` 한다). 회차마다 flags 를 바꾼다 — **11** (disambiguate + report_events + report_all) ·
#    **1** (disambiguate 만). 끝에 `CSI < u` 로 내린다.
# 3. 회차마다 `SendInput` 으로 키를 치고 (`a` · `Shift+a` · `Space` · `Enter` · dead key `'` `e`), 자식은 각 키 뒤 짧은
#    유휴 (300 ms 동안 바이트 없음) 를 한 항목의 끝으로 보아 hex 를 한 줄씩 기록한다. 마지막에 `Ctrl+D` 대신
#    **정해진 개수**만큼 읽고 끝난다 — 자식이 끝나면 앱도 끝난다.
# 4. 기대값과 견준다. 기대는 ghostty 인코더 (`src/input/key_encode.zig` 의 `kitty()`) 의 규칙이다 — `report_all`
#    에서 글자는 `CSI <cp> u`, Shift 가 있으면 `CSI <cp>;2 u` (`:<shifted>` 는 `report_alternates` = flag 4 에서만 붙는다 —
#    2026-09-03 실측), Enter 는 `CSI 13 u`, flags 11 은 `report_events` 라 누름 뒤에 뗌 `CSI <cp>;<mods>:3 u` 가 따라온다.
#    dead key 는 누름이 `CSI 39 u` 로 보고되고 조합 결과 `é` 는 텍스트 (`c3 a9`) 로 온다. `disambiguate` 만이면 글자는 텍스트 그대로.
#
# 실기라서 **시작 전에 알리고 동의를 받는다** — 창이 두 번 뜨고 합성 키가 나간다. 키마다 포커스 가드 (foreground 가 tildaz
# 창이 아니면 멈춤). dead key 회차는 US-International 을 잠깐 올린다 (`deadkey-check.ps1` 과 같은 방법 · 끝나면 내림).
#
# ⚠️ 이 파일은 UTF-8 **BOM** 으로 저장한다 (Windows PowerShell 5.1 이 BOM 없는 `.ps1` 을 cp949 로 읽는다). Python 3 이
# `python` 으로 PATH 에 있어야 한다 (이 기기는 3.14).

[CmdletBinding()]
param(
    [string]$Bin = "zig-out\bin\tildaz.exe",
    [string]$Klid = "00020409"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class TzKitty {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint c, uint t);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr LoadKeyboardLayoutW(string klid, uint flags);
  [DllImport("user32.dll")] public static extern bool UnloadKeyboardLayout(IntPtr hkl);
  [DllImport("user32.dll")] public static extern int GetKeyboardLayoutList(int n, IntPtr[] list);
  [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint thread);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Explicit, Size = 40)] public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; [FieldOffset(8)] public MOUSEINPUT mi; }
  [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] p, int cb);
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
  public static IntPtr[] Layouts() { var a = new IntPtr[32]; int n = GetKeyboardLayoutList(32, a); var r = new IntPtr[Math.Max(n, 0)]; Array.Copy(a, r, r.Length); return r; }
  public static IntPtr LayoutOfWindow(IntPtr h) { uint pid; uint tid = GetWindowThreadProcessId(h, out pid); return GetKeyboardLayout(tid); }
  static INPUT Key(ushort vk, uint flags) { var i = new INPUT(); i.type = 1; i.ki.wVk = vk; i.ki.wScan = (ushort)MapVirtualKeyW(vk, 0); i.ki.dwFlags = flags; return i; }
  static INPUT Mouse(int nx, int ny, uint flags) { var i = new INPUT(); i.type = 0; i.mi.dx = nx; i.mi.dy = ny; i.mi.dwFlags = flags; return i; }
  static void Norm(int x, int y, out int nx, out int ny) {
    int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
    nx = (int)(((long)(x - vx) * 65535) / (vw > 1 ? vw - 1 : 1)); ny = (int)(((long)(y - vy) * 65535) / (vh > 1 ? vh - 1 : 1));
  }
  public static uint Chord(ushort[] vks) {
    var a = new INPUT[vks.Length * 2]; int n = 0;
    foreach (var v in vks) a[n++] = Key(v, 0);
    for (int k = vks.Length - 1; k >= 0; k--) a[n++] = Key(vks[k], 2);
    return SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
  }
  // 다른 창이 덮고 있으면 SetForegroundWindow 도 클릭도 안 닿는다 (2026-09-03 실기 — 브라우저가 앞에 있던 회차).
  // 잠깐 최상위로 올려 활성화하고, 끝나면 내린다 (compare-terminals 의 찍기 직전 TOPMOST 와 같은 수).
  public static bool Focus(IntPtr h) {
    if (GetForegroundWindow() == h) return true;
    SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040);   // TOPMOST · NOSIZE|NOMOVE|SHOWWINDOW
    SetForegroundWindow(h); System.Threading.Thread.Sleep(300);
    bool ok = GetForegroundWindow() == h;
    if (!ok) ok = ClickCenter(h);
    SetWindowPos(h, new IntPtr(-2), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);  // NOTOPMOST · NOACTIVATE
    return ok;
  }
  static bool ClickCenter(IntPtr h) {
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

$VK = @{ a = 0x41; e = 0x45; Space = 0x20; Enter = 0x0D; Shift = 0x10; Apos = 0xDE }
$Out = Join-Path $env:TEMP "tildaz-kitty-text"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$child = Join-Path $Out "child.py"
# 자식 — 콘솔 입력을 VT 모드로 바꾸고 stdin 을 raw 로 읽어, 300 ms 유휴로 항목을 끊어 hex 로 기록한다.
$childBody = @'
import sys, os, time, ctypes, msvcrt
from ctypes import wintypes
out, flags, n_items = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
k32 = ctypes.windll.kernel32
h_in = k32.GetStdHandle(-10)
mode = wintypes.DWORD()
k32.GetConsoleMode(h_in, ctypes.byref(mode))
# ENABLE_VIRTUAL_TERMINAL_INPUT (0x200) 켜고 ECHO (0x4) · LINE (0x2) · PROCESSED (0x1) 끈다.
k32.SetConsoleMode(h_in, (mode.value | 0x200) & ~0x7)
sys.stdout.write("\x1b[>%du" % flags); sys.stdout.flush()      # kitty 모드 켬
items, cur, last = [], b"", None
t_start = time.time()
while len(items) < n_items and time.time() - t_start < 40:
    if msvcrt.kbhit():
        ch = msvcrt.getwch()
        cur += ch.encode("utf-8", "surrogatepass"); last = time.time()
    elif cur and last is not None and time.time() - last > 0.3:
        items.append(cur); cur = b""
    else:
        time.sleep(0.01)
if cur: items.append(cur)
sys.stdout.write("\x1b[<u"); sys.stdout.flush()               # kitty 모드 내림
with open(out, "w", encoding="utf-8") as f:
    for it in items: f.write(" ".join("%02x" % b for b in it) + "\n")
'@
[IO.File]::WriteAllText($child, $childBody, (New-Object System.Text.UTF8Encoding $false))

if (-not (Test-Path $Bin)) { throw "바이너리 없음: $Bin" }
function Stop-Tz { Get-CimInstance Win32_Process -Filter "Name like 'tildaz%'" | Where-Object { $_.CommandLine -match '--instance 9' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
$before = [TzKitty]::Layouts()
$hkl = [TzKitty]::LoadKeyboardLayoutW($Klid, 0)
$loadedByUs = ($hkl -ne [IntPtr]::Zero) -and -not ($before -contains $hkl)

# 회차 — flags · 키 목록 (chord) · 기대 (hex 또는 정규식 접두 'RE:')
$rounds = @(
    # ⚠️ chord 는 `,@(…)` (단항 콤마) 로 감싼다 — PowerShell 은 원소가 하나인 배열 `@(@(a,b))` 를 평탄화해 Shift 와 a 를
    #    따로 누르게 만든다 (2026-09-03 실측 — `Shift+a` 가 `a` 로 나왔다). 원소가 둘 이상이면 그대로 남는다.
    # flags 11 은 `report_events` 를 포함하므로 누름 뒤에 뗌 (`CSI …;1:3 u`) 이 붙는다 — 기대는 정규식으로 둘을 다 받는다.
    @{ flags = 11; name = "report_all + report_events (11)"; keys = @(
        @{ n = "a";        k = @(,@($VK.a));                e = "RE:^1b 5b 39 37 75( 1b 5b 39 37 3b 31 3a 33 75)?$" },              # CSI 97 u
        @{ n = "Shift+a";  k = @(,@($VK.Shift, $VK.a));     e = "RE:^1b 5b 39 37 3b 32 75( 1b 5b 39 37 3b 32 3a 33 75)?$" },          # CSI 97;2 u — `:65` 는 report_alternates (4) 에서만 붙는다
        @{ n = "Space";    k = @(,@($VK.Space));            e = "RE:^1b 5b 33 32 75( 1b 5b 33 32 3b 31 3a 33 75)?$" },              # CSI 32 u
        @{ n = "Enter";    k = @(,@($VK.Enter));            e = "RE:^1b 5b 31 33 75( 1b 5b 31 33 3b 31 3a 33 75)?$" },              # CSI 13 u
        @{ n = "' e (dead)"; k = @(@($VK.Apos), @($VK.e));  e = "RE:c3 a9" }                                                        # 조합 결과 é 가 텍스트로 온다 (dead key 누름 CSI 39 u 는 앞에 붙는다)
    ) },
    @{ flags = 1; name = "disambiguate (1)"; keys = @(
        @{ n = "a";        k = @(,@($VK.a));                e = "61" },
        @{ n = "Shift+a";  k = @(,@($VK.Shift, $VK.a));     e = "41" },
        @{ n = "Enter";    k = @(,@($VK.Enter));            e = "0d" },
        @{ n = "' e (dead)"; k = @(@($VK.Apos), @($VK.e));  e = "c3 a9" }
    ) }
)
$allOk = $true
foreach ($r in $rounds) {
    "===== $($r.name)"
    $result = Join-Path $Out ("received_" + $r.flags + ".txt"); Remove-Item $result -Force -ErrorAction SilentlyContinue
    Stop-Tz
    $cmd = "python `"$child`" `"$result`" $($r.flags) $($r.keys.Count)"
    $p = Start-Process -FilePath (Resolve-Path $Bin) -PassThru -ArgumentList '--instance', '9', '-e', "`"$cmd`""
    $h = [IntPtr]::Zero; $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($h -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 100; if ($p.HasExited) { break }; $h = [TzKitty]::FindWindowOfPid([uint32]$p.Id) }
    if ($p.HasExited -or $h -eq [IntPtr]::Zero) { "❌ 앱/창 없음"; $allOk = $false; Stop-Tz; continue }
    Start-Sleep -Seconds 2
    try {
        if (-not [TzKitty]::Focus($h)) { throw "포커스 못 잡음 — 키를 보내지 않는다" }
        if ($hkl -ne [IntPtr]::Zero) {
            [void][TzKitty]::PostMessageW($h, 0x0050, [IntPtr]::Zero, $hkl); Start-Sleep -Milliseconds 400
            if ([TzKitty]::LayoutOfWindow($h) -ne $hkl) { "⚠ 창 layout 전환 실패 — dead key 항목은 무효" }
        }
        foreach ($c in $r.keys) {
            foreach ($chord in $c.k) {
                if ([TzKitty]::GetForegroundWindow() -ne $h) { throw "포커스 잃음 ($($c.n))" }
                [void][TzKitty]::Chord([uint16[]]$chord); Start-Sleep -Milliseconds 120
            }
            Start-Sleep -Milliseconds 600   # 자식의 유휴 판정 (300 ms) 보다 길게
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not $p.HasExited -and $sw.ElapsedMilliseconds -lt 8000) { Start-Sleep -Milliseconds 200 }
    } catch { "❌ $_"; $allOk = $false } finally { Stop-Tz }
    if (Test-Path $result) {
        $got = Get-Content $result; $i = 0
        foreach ($c in $r.keys) {
            $g = if ($i -lt $got.Count) { $got[$i] } else { "(없음)" }
            $ok = if ($c.e -like "RE:*") { $g -match $c.e.Substring(3) } else { $g -eq $c.e }
            "{0} {1,-12} 기대 [{2}]  받음 [{3}]" -f ($(if ($ok) { "OK  " } else { "FAIL" })), $c.n, $c.e, $g
            if (-not $ok) { $allOk = $false }; $i++
        }
    } else { "❌ 결과 파일 없음"; $allOk = $false }
}
if ($loadedByUs) { "layout 내림: $([TzKitty]::UnloadKeyboardLayout($hkl))" }
"세션 layout (후): " + (([TzKitty]::Layouts() | ForEach-Object { '0x{0:x8}' -f [int64]$_ }) -join ' ')
if ($allOk) { "결과: 전부 OK" } else { "결과: 실패 있음" }
