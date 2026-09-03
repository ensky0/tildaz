# 떠 있는 측정 인스턴스 (`TildaZ-stress` 창) 의 활성 탭을 **합성 키로 N 개 pane 으로 가른다** (Windows ·
# `measure-repeat.sh --panes N` 이 부른다). 앱은 pane 을 만들 때 producer 의 barrier 환경변수를 넣지 않으므로
# 실제 앱 회차는 이렇게 분할한 뒤 `pane-runner.ps1` 의 barrier 파일을 만들어 N 개 producer 를 함께 시작한다.
#
#   split-panes.ps1 -Panes 8            # 2 · 4 · 8
#
# 분할 순서 — 새 pane 이 활성이 된다 (`session_core.splitActive`). 포커스 이동은 기하 기반 이웃 (SPEC §? pane 표).
#   2: →                           → [L | R]
#   4: → ↓ Alt+← ↓                 → 2 × 2  (60x20 근사)
#   8: 4 뒤 → Alt+↑ → Alt+→ → Alt+↓ →   → 4 열 × 2 행 (30x20 근사)   그리고 Shift+Alt+0 (균등)
# 120 열은 3 열 상태에서 더 못 가른다 (`MIN_PANE_COLS` 20 — #551 macOS 회차) 라 반씩 가르는 순서를 지킨다.
#
# 단축키는 기본 바인딩 (`config.zig` Linux · Windows 기본값 — `ctrl+shift+방향` 분할 · `alt+방향` 포커스 ·
# `shift+alt+0` 균등) 이고 **`config_9.toml` 이 있어야 산다** — `measure-repeat.sh` 가 만들고 지운다.
#
# 규칙 — 키마다 foreground 가 그 창인지 확인하고 어긋나면 멈춘다 (`send-keys.ps1` 과 같다). 덮인 창은 잠깐 TOPMOST
# 로 올려 활성화한다. chord 는 `,@(…)` 로 감싼다 (PowerShell 이 원소 하나인 배열을 평탄화한다 — AGENTS.md).
# pane 수는 호출자가 앱 로그 `[pane] split … — tab 0 has N panes` 로 확인한다.
#
# ⚠️ UTF-8 BOM 으로 저장한다 (Windows PowerShell 5.1).
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$Panes,
    [string]$WindowTitle = 'TildaZ-stress',
    [string]$WindowClass = 'TildaZWindow',
    # 창이 뜨기를 기다릴 시간.
    [int]$WaitMs = 15000,
    # 키 사이 간격 (ms). 분할은 새 셸 spawn 을 동반하니 넉넉히.
    [int]$GapMs = 350
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class TzSplit {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint c, uint t);
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Explicit, Size = 40)] public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; [FieldOffset(8)] public MOUSEINPUT mi; }
  [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] p, int cb);
  static INPUT Key(ushort vk, uint flags) {
    var i = new INPUT(); i.type = 1; i.ki.wVk = vk; i.ki.wScan = (ushort)MapVirtualKeyW(vk, 0);
    // 화살표는 extended key — scan code 에 KEYEVENTF_EXTENDEDKEY 를 붙여야 numpad 와 안 섞인다.
    if (vk >= 0x25 && vk <= 0x28) flags |= 0x0001;
    i.ki.dwFlags = flags; return i;
  }
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
  public static bool Focus(IntPtr h) {
    if (GetForegroundWindow() == h) return true;
    SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040);
    SetForegroundWindow(h); System.Threading.Thread.Sleep(300);
    bool ok = GetForegroundWindow() == h;
    if (!ok) {
      RECT r; GetClientRect(h, out r);
      var p = new POINT(); p.x = (r.R - r.L) / 2; p.y = (r.B - r.T) / 2; ClientToScreen(h, ref p);
      POINT before; bool hc = GetCursorPos(out before);
      int nx, ny; Norm(p.x, p.y, out nx, out ny);
      uint mv = 0x0001 | 0x8000 | 0x4000;
      var a = new INPUT[] { Mouse(nx, ny, mv), Mouse(nx, ny, mv | 0x0002), Mouse(nx, ny, mv | 0x0004) };
      SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
      System.Threading.Thread.Sleep(300);
      if (hc) { int bx, by; Norm(before.x, before.y, out bx, out by); var m = new INPUT[] { Mouse(bx, by, mv) }; SendInput(1, m, Marshal.SizeOf(typeof(INPUT))); }
      ok = GetForegroundWindow() == h;
    }
    SetWindowPos(h, new IntPtr(-2), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
    return ok;
  }
}
"@

if ($Panes -notin 1, 2, 4, 8) { Write-Output "  ❌ --panes 는 1 · 2 · 4 · 8 만"; exit 2 }
$VK = @{ Ctrl = 0x11; Shift = 0x10; Alt = 0x12; Left = 0x25; Up = 0x26; Right = 0x27; Down = 0x28; D0 = 0x30 }
$SR = @($VK.Ctrl, $VK.Shift, $VK.Right)   # split_right
$SD = @($VK.Ctrl, $VK.Shift, $VK.Down)    # split_down
$FL = @($VK.Alt, $VK.Left); $FR = @($VK.Alt, $VK.Right); $FU = @($VK.Alt, $VK.Up); $FD = @($VK.Alt, $VK.Down)
$EQ = @($VK.Shift, $VK.Alt, $VK.D0)       # equalize_panes
# ⚠️ `$seq = switch (…) { 2 { @(,$SR) } }` 는 안 돼요 — switch 의 **출력**은 파이프라인을 지나며 풀려서 원소가 하나인
# 배열이 `@(17, 16, 39)` 가 되고 Ctrl · Shift · → 가 따로 눌려요 (2026-09-03 실측 — pane 2 회차 5 회가 전부 분할 실패).
# 블록 안에서 변수에 **직접 대입**하면 풀리지 않아요. 4 · 8 은 원소가 여럿이라 우연히 살아남았어요.
$seq = @()
switch ($Panes) {
    2 { $seq = ,$SR }
    4 { $seq = @($SR, $SD, $FL, $SD) }
    8 { $seq = @($SR, $SD, $FL, $SD, $SR, $FU, $SR, $FR, $SR, $FD, $SR, $EQ) }
}

# 창 대기 — owner 창 (0x0) 도 같은 class 라 제목까지 준다.
$h = [IntPtr]::Zero; $sw = [Diagnostics.Stopwatch]::StartNew()
while ($h -eq [IntPtr]::Zero -and $sw.ElapsedMilliseconds -lt $WaitMs) {
    $h = [TzSplit]::FindWindowW($WindowClass, $WindowTitle)
    if ($h -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 100 }
}
if ($h -eq [IntPtr]::Zero) { Write-Output "  ❌ 측정 창을 못 찾았어요 (class=$WindowClass title=$WindowTitle)"; exit 3 }
Start-Sleep -Milliseconds 800   # 첫 셸 (러너) 이 뜨고 레이아웃이 자리 잡을 시간
if ($seq.Count -eq 0) { Write-Output "  pane 1 — 분할 없음"; exit 0 }
if (-not [TzSplit]::Focus($h)) { Write-Output "  ❌ 측정 창이 활성이 아니에요 — 키를 보내지 않았어요"; exit 4 }
$sent = 0
foreach ($chord in $seq) {
    if ([TzSplit]::GetForegroundWindow() -ne $h) { Write-Output "  ❌ 포커스를 잃었어요 — $sent 번째 뒤 중단"; exit 5 }
    [void][TzSplit]::Chord([uint16[]]$chord)
    $sent++
    Start-Sleep -Milliseconds $GapMs
}
Write-Output "  분할 키 $sent 개 보냄 (pane $Panes 목표)"
exit 0
