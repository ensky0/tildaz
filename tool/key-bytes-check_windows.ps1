# `tool/key-bytes.py` 를 tildaz 탭에 띄우고 **합성 입력으로** 키를 쳐서, 앱이 PTY 에 쓴 바이트를 기대값과
# 견준다 (#648 · #650 의 Windows 몫). 손으로 치는 회차를 대신한다 — 판정이 자동이라 회귀 검사로 쓸 수 있다.
#
# ```powershell
# tool\key-bytes-check_windows.ps1                       # 세 모드 (legacy · kitty · mok2) 전부
# tool\key-bytes-check_windows.ps1 -Mode legacy          # 한 모드만
# tool\key-bytes-check_windows.ps1 -Bin C:\path\tildaz.exe
# ```
#
# 무엇을 하나 —
# 1. `--instance 9 -e <자식.cmd>` 로 tildaz 를 띄운다. 자식은 `key-bytes.py` 를 돌리고 **stdout 을 파일로**
#    돌린다. `-e` 는 stress run 이라 hotkey 도 config 도 만들지 않는다 (로그는 `tildaz_stress.log`).
# 2. `SendInput` 으로 chord 를 하나씩 보내고 (간격 700 ms) 자식이 받은 hex 를 파일에서 읽어 기대와 견준다.
# 3. 창도 한 장 찍어 둔다 (`PrintWindow`) — 파일이 비었을 때 화면에 무엇이 있었는지 보려고.
#
# ⚠️ **kitty · mok2 의 enable 시퀀스는 이 스크립트가 보낸다.** `key-bytes.py <mode>` 는 그 시퀀스를 *자기
# stdout* 에 쓰는데, 여기서는 stdout 이 파일이라 터미널에 닿지 않는다. 그래서 자식 `.cmd` 가 python 앞에
# `powershell -Command "[Console]::Out.Write(...)"` 로 `CSI > 1 u` · `CSI > 4 ; 2 m` 를 **먼저 콘솔에** 쓰고,
# python 은 `legacy` (아무것도 안 켜는 모드) 로 돌린다. 앱 입장에서는 프로토콜을 켠 앱과 구별되지 않는다.
#
# 기대값의 근거는 [#650 의 Windows 실측](https://github.com/ensky0/tildaz/issues/650) 이다. **mac · Linux 와
# 다른 칸이 셋 있고 전부 Windows 쪽이 원래 그런 것**이다 (main 판과 바이트가 같은 것을 대조로 확인했다).
#
#   - ~~`Ctrl+H` → `7f`~~ · ~~`Shift+Tab` → `09`~~ — [#653](https://github.com/ensky0/tildaz/issues/653) 에서 고쳤다. Backspace 와
#     Tab 을 `WM_CHAR` 가 아니라 **인코더**로 보내면서 `Ctrl+H` = `08` · `Shift+Tab` = `ESC[Z` 가 되고,
#     `Ctrl+Backspace` (`08`) · `Ctrl+Tab` (`ESC[27;5;9~`) 까지 mac · Linux 와 같아졌다.
#   - `mok2` 에서도 `Ctrl+[` 가 `1b` — Windows 는 legacy 에서 글자 키를 인코더로 안 보내고 `WM_CHAR` 로
#     받으므로 앱이 modifyOtherKeys 를 켜도 그 경로가 안 바뀐다.
#
# 함정 —
#  - **chord 는 `,@(…)` (단항 콤마) 로 감싼다.** PowerShell 이 원소 하나짜리 배열을 평탄화해 modifier 와
#    글자를 따로 누르게 만든다 (AGENTS.md `# Windows — 합성 입력으로 …` 의 같은 주의).
#  - **`SendInput` 은 `wScan` 을 `MapVirtualKeyW` 로 채워야** 앱에 닿는다. 방향키 등 control pad 는
#    확장 (`0xE0`) 플래그도 필요하다 — 안 붙이면 numpad 로 간다.
#  - **키마다 포커스 가드** — foreground 가 tildaz 창이 아니면 그 자리에서 멈춘다. 합성 키는 포커스된
#    창으로 가니 회차 중 다른 창을 만지면 거기에 타이핑된다.
#  - Python 3 이 `python` 으로 PATH 에 있어야 한다 (`kitty-text-check_windows.ps1` 과 같은 전제).
#
# 실기라서 **시작 전에 알리고 동의를 받는다** (AGENTS.md `# 실행 환경`) — 창이 모드마다 한 번씩 뜨고
# 합성 키가 나간다.
#
# ⚠️ 이 파일은 UTF-8 **BOM** 으로 저장한다 — Windows PowerShell 5.1 은 BOM 없는 `.ps1` 을 cp949 로 읽는다.
[CmdletBinding()]
param(
    [ValidateSet("all", "legacy", "kitty", "mok2")][string]$Mode = "all",
    [string]$Bin = (Join-Path $PSScriptRoot '..\zig-out\bin\tildaz.exe')
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$Py = Join-Path $PSScriptRoot "key-bytes.py"
if (-not (Test-Path $Py)) { throw "key-bytes.py 없음: $Py" }

Add-Type @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class TzKeyBytes {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint c, uint t);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort vk, scan; public uint flags; public uint time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public KEYBDINPUT ki; public int pad1, pad2; }
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] a, int cb);

  // control pad 는 확장 (0xE0) 이다 — 안 붙이면 numpad 로 간다.
  static bool IsExtended(ushort vk) {
    return vk == 0x25 || vk == 0x26 || vk == 0x27 || vk == 0x28
        || vk == 0x2D || vk == 0x2E || vk == 0x24 || vk == 0x23
        || vk == 0x21 || vk == 0x22;
  }
  static INPUT Key(ushort vk, bool up) {
    var i = new INPUT(); i.type = 1;
    i.ki.vk = vk;
    i.ki.scan = (ushort)MapVirtualKeyW(vk, 0);
    i.ki.flags = (uint)((up ? 2 : 0) | (IsExtended(vk) ? 1 : 0));
    return i;
  }
  // 순서대로 누르고 역순으로 뗀다.
  public static uint Chord(ushort[] keys) {
    var a = new INPUT[keys.Length * 2];
    for (int i = 0; i < keys.Length; i++) a[i] = Key(keys[i], false);
    for (int i = 0; i < keys.Length; i++) a[keys.Length + i] = Key(keys[keys.Length - 1 - i], true);
    return SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
  }
  // `Process.MainWindowHandle` 은 owner 가 달린 진짜 창을 건너뛰어 0 이다 (#584) — pid + 보임 + 크기로 찾는다.
  public static IntPtr FindWindowOfPid(uint pid) {
    IntPtr hit = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid || !IsWindowVisible(h)) return true;
      RECT r; if (!GetWindowRect(h, out r)) return true;
      if (r.R - r.L < 50 || r.B - r.T < 50) return true;
      hit = h; return false;
    }, IntPtr.Zero);
    return hit;
  }
  public static bool Focus(IntPtr h) {
    if (GetForegroundWindow() == h) return true;
    SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040);   // TOPMOST
    SetForegroundWindow(h); System.Threading.Thread.Sleep(300);
    bool ok = GetForegroundWindow() == h;
    SetWindowPos(h, new IntPtr(-2), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);   // NOTOPMOST
    return ok;
  }
  public static void Shot(IntPtr h, string path) {
    RECT r; GetWindowRect(h, out r);
    var bmp = new Bitmap(r.R - r.L, r.B - r.T, PixelFormat.Format32bppArgb);
    using (var g = Graphics.FromImage(bmp)) {
      IntPtr hdc = g.GetHdc(); PrintWindow(h, hdc, 2); g.ReleaseHdc(hdc);    // PW_RENDERFULLCONTENT
    }
    bmp.Save(path, ImageFormat.Png); bmp.Dispose();
  }
}
"@ -ReferencedAssemblies System.Drawing

[void][TzKeyBytes]::SetProcessDpiAwarenessContext([IntPtr](-4))   # PER_MONITOR_AWARE_V2

$VK = @{
    Ctrl = 0x11; Shift = 0x10; Enter = 0x0D; Tab = 0x09; Left = 0x25; Back = 0x08   # #653 — VK_BACK
    A = 0x41; C = 0x43; F = 0x46; H = 0x48; I = 0x49; M = 0x4D
    LBracket = 0xDB                                               # VK_OEM_4
}

# 모드별 회차. `e` 는 기대 hex (`""` 는 "아무 바이트도 안 나가야 한다").
$rounds = @(
    @{ mode = "legacy"; enable = ""; keys = @(
        @{ n = "Ctrl+[";           k = ,@($VK.Ctrl, $VK.LBracket);            e = "1b" }          # #650 — 전에는 CSI 91;5u
        @{ n = "Ctrl+I";           k = ,@($VK.Ctrl, $VK.I);                   e = "09" }          # #650
        @{ n = "Ctrl+M";           k = ,@($VK.Ctrl, $VK.M);                   e = "0d" }          # #650
        @{ n = "Ctrl+Shift+F";     k = ,@($VK.Ctrl, $VK.Shift, $VK.F);        e = "" }            # #648 — 억제
        @{ n = "Ctrl+Shift+Enter"; k = ,@($VK.Ctrl, $VK.Shift, $VK.Enter);    e = "" }            # #648 — 억제
        @{ n = "Ctrl+A";           k = ,@($VK.Ctrl, $VK.A);                   e = "01" }          # 회귀 감시
        @{ n = "Ctrl+C";           k = ,@($VK.Ctrl, $VK.C);                   e = "03" }          # 회귀 감시 (raw 라 SIGINT 아님)
        @{ n = "Ctrl+H";           k = ,@($VK.Ctrl, $VK.H);                   e = "08" }          # #653 — 전에는 7f (Backspace 와 합쳐졌다)
        @{ n = "Backspace";        k = ,@($VK.Back);                          e = "7f" }          # #653 — 인코더로 옮긴 뒤에도 그대로여야 한다
        @{ n = "Ctrl+Backspace";   k = ,@($VK.Ctrl, $VK.Back);               e = "08" }          # #653 — 전에는 7f
        @{ n = "Tab";              k = ,@($VK.Tab);                          e = "09" }          # #653 — 그대로
        @{ n = "Shift+Tab";        k = ,@($VK.Shift, $VK.Tab);                e = "1b 5b 5a" }    # #653 — 전에는 09 (back-tab 이 없었다)
        @{ n = "Ctrl+Left";        k = ,@($VK.Ctrl, $VK.Left);                e = "1b 5b 31 3b 35 44" }
        @{ n = "Ctrl+Tab";         k = ,@($VK.Ctrl, $VK.Tab);                 e = "1b 5b 32 37 3b 35 3b 39 7e" }  # #653 — 전에는 0 바이트. mac · Linux 와 같아졌다
        @{ n = "Ctrl+Enter";       k = ,@($VK.Ctrl, $VK.Enter);               e = "0a" }          # #650 미결 항목의 답
    ) },
    # 경계 ① — 앱이 kitty 를 켜면 예전 그대로 나가야 한다. 삼키면 nvim · helix · zellij 가 깨진다.
    @{ mode = "kitty"; enable = "[char]27+'[>1u'"; keys = @(
        @{ n = "Ctrl+[";       k = ,@($VK.Ctrl, $VK.LBracket);        e = "1b 5b 39 31 3b 35 75" }        # CSI 91;5u
        @{ n = "Ctrl+I";       k = ,@($VK.Ctrl, $VK.I);               e = "1b 5b 31 30 35 3b 35 75" }     # CSI 105;5u
        @{ n = "Ctrl+M";       k = ,@($VK.Ctrl, $VK.M);               e = "1b 5b 31 30 39 3b 35 75" }     # CSI 109;5u
        @{ n = "Ctrl+Shift+F"; k = ,@($VK.Ctrl, $VK.Shift, $VK.F);    e = "1b 5b 31 30 32 3b 36 75" }     # CSI 102;6u
        @{ n = "Ctrl+A";       k = ,@($VK.Ctrl, $VK.A);               e = "1b 5b 39 37 3b 35 75" }        # CSI 97;5u — 01 이 아니다
        @{ n = "Shift+Tab";    k = ,@($VK.Shift, $VK.Tab);            e = "1b 5b 39 3b 32 75" }           # #653 — kitty 는 CSI 9;2u (legacy 의 ESC[Z 와 다르다)
        @{ n = "Backspace";    k = ,@($VK.Back);                      e = "7f" }
    ) },
    # 경계 ② — modifyOtherKeys=2. Windows 는 mac · Linux 와 갈린다 (머리 주석).
    @{ mode = "mok2"; enable = "[char]27+'[>4;2m'"; keys = @(
        @{ n = "Ctrl+[";       k = ,@($VK.Ctrl, $VK.LBracket);        e = "1b" }
        @{ n = "Ctrl+I";       k = ,@($VK.Ctrl, $VK.I);               e = "09" }
        @{ n = "Ctrl+Shift+F"; k = ,@($VK.Ctrl, $VK.Shift, $VK.F);    e = "" }
        @{ n = "Ctrl+A";       k = ,@($VK.Ctrl, $VK.A);               e = "01" }
        @{ n = "Shift+Tab";    k = ,@($VK.Shift, $VK.Tab);            e = "1b 5b 32 37 3b 32 3b 39 7e" }  # #653 — mok2 는 CSI 27;2;9~
    ) }
)

$Out = Join-Path $env:TEMP "tildaz-key-bytes"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
if (-not (Test-Path $Bin)) { throw "바이너리 없음: $Bin" }
function Stop-Tz {
    Get-CimInstance Win32_Process -Filter "Name like 'tildaz%'" |
        Where-Object { $_.CommandLine -match '--instance 9' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

$allOk = $true
foreach ($r in $rounds) {
    if ($Mode -ne "all" -and $Mode -ne $r.mode) { continue }
    "===== $($r.mode)"
    $result = Join-Path $Out "received_$($r.mode).txt"
    $shot = Join-Path $Out "shot_$($r.mode).png"
    Remove-Item $result, $shot -Force -ErrorAction SilentlyContinue

    # 자식 .cmd — enable 은 여기서 콘솔에 쓰고 (머리 주석의 ⚠️), python 은 legacy 로 돌려 stdout 을 파일로 받는다.
    $cmdFile = Join-Path $Out "child_$($r.mode).cmd"
    $lines = @("@echo off", "chcp 65001>nul")
    if ($r.enable) { $lines += "powershell -NoProfile -Command ""[Console]::Out.Write($($r.enable))""" }
    $lines += "python ""$Py"" > ""$result"" 2>&1"
    $lines += "timeout /t 3600 /nobreak >nul"
    [IO.File]::WriteAllText($cmdFile, ($lines -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding $false))

    Stop-Tz
    $p = Start-Process -FilePath (Resolve-Path $Bin) -PassThru -ArgumentList '--instance', '9', '-e', "`"$cmdFile`"", '-size', '100x30'
    $h = [IntPtr]::Zero; $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($h -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt 10000) {
        Start-Sleep -Milliseconds 100
        if ($p.HasExited) { break }
        $h = [TzKeyBytes]::FindWindowOfPid([uint32]$p.Id)
    }
    if ($p.HasExited -or $h -eq [IntPtr]::Zero) { "❌ 앱 또는 창 없음 (exited=$($p.HasExited))"; $allOk = $false; Stop-Tz; continue }
    Start-Sleep -Seconds 3        # python 이 raw 모드에 들어갈 시간

    try {
        if (-not [TzKeyBytes]::Focus($h)) { throw "포커스 못 잡음 — 키를 보내지 않는다" }
        foreach ($c in $r.keys) {
            if ([TzKeyBytes]::GetForegroundWindow() -ne $h) { throw "포커스 잃음 ($($c.n))" }
            $chord = $c.k[0]      # `,@(…)` 의 한 겹을 벗긴다
            $sent = [TzKeyBytes]::Chord([uint16[]]$chord)
            if ($sent -ne $chord.Count * 2) { throw "SendInput 거부: $sent (기대 $($chord.Count * 2))" }
            Start-Sleep -Milliseconds 700
        }
        Start-Sleep -Milliseconds 500
        [TzKeyBytes]::Shot($h, $shot)
    } catch { "❌ $_"; $allOk = $false } finally { Stop-Tz }

    if (-not (Test-Path $result)) { "❌ 결과 파일 없음: $result"; $allOk = $false; continue }
    # `key-bytes.py` 는 `<hex …>  <repr>` 로 한 줄씩 찍는다 — hex 부분만 뽑는다.
    $got = @(Get-Content $result | ForEach-Object {
        if ($_ -match '^((?:[0-9a-f]{2} )*[0-9a-f]{2})\s') { $matches[1] }
    })
    $i = 0
    foreach ($c in $r.keys) {
        if ($c.e -eq "") {
            # 0 바이트 기대 — 줄이 생기지 않아야 한다. 다음 기대값이 제자리에 오는지로 판정된다.
            "OK?  {0,-16} 기대 [(없음)]" -f $c.n
            continue
        }
        $g = if ($i -lt $got.Count) { $got[$i] } else { "(없음)" }
        $ok = $g -eq $c.e
        "{0} {1,-16} 기대 [{2}]  받음 [{3}]" -f $(if ($ok) { "OK  " } else { "FAIL" }), $c.n, $c.e, $g
        if (-not $ok) { $allOk = $false }
        $i++
    }
    $expected = @($r.keys | Where-Object { $_.e -ne "" }).Count
    if ($got.Count -ne $expected) {
        "FAIL 줄 수 $($got.Count) (기대 $expected) — 0 바이트여야 할 키가 바이트를 냈거나 그 반대다"
        $allOk = $false
    }
    "  캡처: $shot"
}
if ($allOk) { "결과: 전부 OK" } else { "결과: 실패 있음" }
