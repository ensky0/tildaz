# Windows 에서 dead key 조합이 PTY 까지 오는지 합성 입력으로 판정한다 (#494 의 Windows 몫 · #583 A3).
# macOS 의 `dist/macos/deadkey-check.sh` 에 대응한다.
#
# ```powershell
# dist\windows\deadkey-check.ps1                                   # zig-out\bin\tildaz.exe · US-International
# dist\windows\deadkey-check.ps1 -Bin C:\path\tildaz.exe -Keep      # layout 을 세션에 남겨 둔다 (직접 쳐 볼 때)
# ```
#
# 무엇을 하나 —
# 1. `--instance 9 -e <자식.ps1>` 로 tildaz 를 띄운다. 자식은 `Read-Host` 로 줄을 N 개 받아 **UTF-8 바이트 hex** 로
#    파일에 적고 끝난다 (자식이 끝나면 앱도 끝난다 — 정리가 자동이다). `-e` 는 stress run 이라 hotkey 도 config 도
#    만들지 않는다. 로그는 `%APPDATA%\tildaz\tildaz_stress.log`.
# 2. `LoadKeyboardLayoutW("00020409", 0)` 로 **US-International** 을 세션에 올린다 — `'` `` ` `` `^` `~` `"` 가 dead key 다.
#    활성화는 하지 않고 (flags=0) `WM_INPUTLANGCHANGEREQUEST` 를 tildaz 창에 보내 **그 스레드만** 전환한다. 우리 셸도
#    사용자의 다른 창도 layout 이 바뀌지 않는다. 전환됐는지 `GetKeyboardLayout(thread)` 로 확인하고 안 됐으면 키를 안 보낸다.
# 3. 케이스마다 `SendInput` 으로 키를 치고 `Enter` 로 줄을 끝낸다. 키마다 **포커스 가드** — foreground 가 tildaz 창이
#    아니면 그 자리에서 멈춘다 (`dist/stress/send-keys.ps1` 과 같은 규칙 — 합성 키는 포커스된 창으로 간다).
# 4. 끝나면 올린 layout 을 `UnloadKeyboardLayout` 으로 내린다 (원래 세션에 있던 것이면 두고, `-Keep` 이면 남긴다).
#    `GetKeyboardLayoutList` 를 전후로 찍어 기기 상태가 되돌아왔는지 보인다. `LoadKeyboardLayoutW` 의 부작용은
#    프로세스보다 오래 살아 `Win+Space` 목록에 나타난다 (AGENTS.md `# Windows — 키보드 layout 조회 실측 방법`).
#
# 판정은 **자식이 받은 바이트**다 — macOS 판이 `cat` 으로 받은 것과 같은 자리. tildaz 가 PTY 에 쓴 것을 ConPTY 가 콘솔
# 입력으로 바꿔 `Read-Host` 가 받으므로, dead key 가 OS (`TranslateMessage` → `WM_CHAR`) 에서 조합되어 앱을 거쳐
# 자식까지 온전히 닿았는지가 여기서 갈린다.
#
# | # | 키 | 기대 | 뜻 |
# |---|---|---|---|
# | 1 | `'` `e` `x` | `c3 a9 78` (`éx`) | dead acute + e |
# | 2 | `'` `Space` `x` | `27 78` (`'x`) | dead key + space = 문자 자체 |
# | 3 | `Shift+6` (`^`) `o` `x` | `c3 b4 78` (`ôx`) | modifier 가 낀 dead key |
# | 4 | `'` `x` | `27 78` (`'x`) | 조합 불가 — 둘 다 나와야 한다 (dead key 가 삼키면 `78` 만) |
#
# 실기라서 **시작 전에 알리고 동의를 받는다** (AGENTS.md `# 실행 환경`) — 창이 한 번 뜨고 합성 키가 나가며, 세션 layout
# 목록이 잠깐 바뀐다. 회차 동안 키 · 마우스를 건드리면 포커스 가드가 멈추고, 이미 나간 키는 그 창에 들어간다.
#
# ⚠️ 이 파일은 UTF-8 **BOM** 으로 저장한다 (Windows PowerShell 5.1 이 BOM 없는 `.ps1` 을 cp949 로 읽는다).

[CmdletBinding()]
param(
    [string]$Bin = "zig-out\bin\tildaz.exe",
    # 올릴 layout 의 KLID. 기본 US-International.
    [string]$Klid = "00020409",
    [switch]$Keep
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class TzDead {
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
  public static IntPtr[] Layouts() {
    var a = new IntPtr[32]; int n = GetKeyboardLayoutList(32, a);
    var r = new IntPtr[Math.Max(n, 0)]; Array.Copy(a, r, r.Length); return r;
  }
  public static IntPtr LayoutOfWindow(IntPtr h) { uint pid; uint tid = GetWindowThreadProcessId(h, out pid); return GetKeyboardLayout(tid); }
  static INPUT Key(ushort vk, uint flags) { var i = new INPUT(); i.type = 1; i.ki.wVk = vk; i.ki.wScan = (ushort)MapVirtualKeyW(vk, 0); i.ki.dwFlags = flags; return i; }
  static INPUT Mouse(int nx, int ny, uint flags) { var i = new INPUT(); i.type = 0; i.mi.dx = nx; i.mi.dy = ny; i.mi.dwFlags = flags; return i; }
  static void Norm(int x, int y, out int nx, out int ny) {
    int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
    nx = (int)(((long)(x - vx) * 65535) / (vw > 1 ? vw - 1 : 1)); ny = (int)(((long)(y - vy) * 65535) / (vh > 1 ? vh - 1 : 1));
  }
  // 앞에서부터 누르고 뒤에서부터 뗀다 — 한 글자 키는 길이 1, Shift+6 은 {Shift, 6}.
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

$VK = @{ Apos = 0xDE; e = 0x45; o = 0x4F; x = 0x58; Space = 0x20; Enter = 0x0D; Shift = 0x10; D6 = 0x36 }
# 케이스 — 이름 · 키 목록 (chord 는 배열) · 기대 hex
$cases = @(
    @{ name = "' e x";        keys = @(@($VK.Apos), @($VK.e), @($VK.x));                 expect = "c3 a9 78" },
    @{ name = "' Space x";    keys = @(@($VK.Apos), @($VK.Space), @($VK.x));             expect = "27 78" },
    @{ name = "Shift+6 o x";  keys = @(@($VK.Shift, $VK.D6), @($VK.o), @($VK.x));        expect = "c3 b4 78" },
    @{ name = "' x";          keys = @(@($VK.Apos), @($VK.x));                           expect = "27 78" }
)

$Out = Join-Path $env:TEMP "tildaz-deadkey"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$result = Join-Path $Out "received.txt"
Remove-Item $result -Force -ErrorAction SilentlyContinue
$child = Join-Path $Out "child.ps1"
# 자식 — 줄을 N 개 받아 UTF-8 hex 로 적는다. Read-Host 는 콘솔 입력을 UTF-16 으로 받으므로 인코딩 설정이 필요 없다.
$childBody = @'
param([string]$Out, [int]$N)
$lines = @()
for ($i = 0; $i -lt $N; $i++) {
    $s = Read-Host
    $lines += ((([Text.Encoding]::UTF8.GetBytes($s)) | ForEach-Object { $_.ToString("x2") }) -join " ")
}
[IO.File]::WriteAllLines($Out, $lines)
'@
[IO.File]::WriteAllText($child, $childBody, (New-Object System.Text.UTF8Encoding $true))

if (-not (Test-Path $Bin)) { throw "바이너리 없음: $Bin" }
$before = [TzDead]::Layouts()
"세션 layout (전): " + (($before | ForEach-Object { '0x{0:x8}' -f [int64]$_ }) -join ' ')

# 인스턴스 9 만 내린다.
function Stop-Tz {
    Get-CimInstance Win32_Process -Filter "Name like 'tildaz%'" |
        Where-Object { $_.CommandLine -match '--instance 9' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
Stop-Tz
$cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$child`" `"$result`" $($cases.Count)"
$p = Start-Process -FilePath (Resolve-Path $Bin) -PassThru -ArgumentList '--instance', '9', '-e', "`"$cmd`""
$h = [IntPtr]::Zero
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($h -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 10000) {
    Start-Sleep -Milliseconds 100
    if ($p.HasExited) { break }
    $h = [TzDead]::FindWindowOfPid([uint32]$p.Id)
}
if ($p.HasExited) { throw "앱이 먼저 끝남 exit=$($p.ExitCode)" }
if ($h -eq [IntPtr]::Zero) { Stop-Tz; throw "창 못 찾음" }
Start-Sleep -Seconds 2   # 자식 PowerShell 이 Read-Host 에 닿을 시간

$hkl = [TzDead]::LoadKeyboardLayoutW($Klid, 0)
if ($hkl -eq [IntPtr]::Zero) { Stop-Tz; throw "LoadKeyboardLayoutW($Klid) 실패" }
$loadedByUs = -not ($before -contains $hkl)
"layout $Klid → hkl 0x{0:x8} (이번에 올림: {1})" -f [int64]$hkl, $loadedByUs

$ok = $true
$sent = 0
try {
    if (-not [TzDead]::Focus($h)) { throw "tildaz 창을 활성으로 못 만들었다 — 키를 보내지 않는다" }
    # 그 창의 스레드만 layout 전환. DefWindowProc 이 WM_INPUTLANGCHANGEREQUEST 를 받아 ActivateKeyboardLayout 한다.
    [void][TzDead]::PostMessageW($h, 0x0050, [IntPtr]::Zero, $hkl)
    Start-Sleep -Milliseconds 400
    $now = [TzDead]::LayoutOfWindow($h)
    "tildaz 창의 layout: 0x{0:x8}" -f [int64]$now
    if ($now -ne $hkl) { throw "창의 layout 이 바뀌지 않았다 — 키를 보내지 않는다" }

    foreach ($c in $cases) {
        foreach ($chord in $c.keys) {
            if ([TzDead]::GetForegroundWindow() -ne $h) { throw "포커스를 잃었다 (케이스 '$($c.name)') — 중단" }
            [void][TzDead]::Chord([uint16[]]$chord)
            Start-Sleep -Milliseconds 120
        }
        [void][TzDead]::Chord([uint16[]]@($VK.Enter))
        $sent++
        Start-Sleep -Milliseconds 300
    }
    # 자식이 N 줄을 받고 끝나면 앱도 끝난다.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited -and $sw.ElapsedMilliseconds -lt 8000) { Start-Sleep -Milliseconds 200 }
    if (-not $p.HasExited) { "앱이 스스로 끝나지 않았다 — 자식이 줄을 다 못 받았을 수 있다"; $ok = $false }
} catch {
    "❌ $_"; $ok = $false
} finally {
    Stop-Tz
    if (-not $Keep -and $loadedByUs) {
        $u = [TzDead]::UnloadKeyboardLayout($hkl)
        "layout 내림: $u"
    }
    $after = [TzDead]::Layouts()
    "세션 layout (후): " + (($after | ForEach-Object { '0x{0:x8}' -f [int64]$_ }) -join ' ')
}

""
if (Test-Path $result) {
    $got = Get-Content $result
    $i = 0
    foreach ($c in $cases) {
        $g = if ($i -lt $got.Count) { $got[$i] } else { "(없음)" }
        $mark = if ($g -eq $c.expect) { "OK  " } else { "FAIL" }
        "{0} {1,-14} 기대 [{2}]  받음 [{3}]" -f $mark, $c.name, $c.expect, $g
        if ($g -ne $c.expect) { $ok = $false }
        $i++
    }
} else {
    "❌ 자식이 결과 파일을 남기지 않았다 ($result)"; $ok = $false
}
"보낸 줄 $sent / $($cases.Count) · 결과: $result · 로그: $env:APPDATA\tildaz\tildaz_stress.log"
if ($ok) { "결과: 전부 OK" } else { "결과: 실패 있음" }
