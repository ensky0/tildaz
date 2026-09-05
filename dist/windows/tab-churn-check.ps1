# 탭을 만들자마자 닫아 ConPTY teardown 이 어긋나지 않는지 보는 회귀 검사 (#611).
#
# ## 무엇을 재나
#
# `ClosePseudoConsole` 은 연결된 클라이언트에게 `CTRL_CLOSE_EVENT` 를 **보낼 뿐**이라, 자식이
# 막 시작해 콘솔 컨트롤 핸들러를 세우기 전이면 그것을 놓치고 계속 연결된 채 남는다. 그러면
# conpty 가 출력 pipe 를 닫지 않아 `readLoop` 이 끝나지 않고 `deinit` 의 join 이 영원히 안
# 풀린다 — **탭 닫기가 UI 스레드에서 멈춰 앱이 얼어붙는다.** 이 스크립트는 `Ctrl+Shift+T`
# 직후 `Ctrl+Shift+W` 를 반복하며 두 가지를 본다.
#
#   1. `WM_NULL` 이 돌아오는가 (= UI 스레드가 살아 있는가). 안 돌아오면 최대 40 초 재확인해
#      **일시적 지연**과 **영구 정지**를 가른다.
#   2. tildaz 경로의 `OpenConsole.exe` 가 쌓이는가 (자식이 안 죽으면 남는다).
#
# 수정 전 판: 사이클 1 에서 UI 영구 무응답 · 앱 강제 종료 뒤에도 OpenConsole 1 잔존.
# 수정 후 판: 전 사이클 UI 정상 · 앱 종료 뒤 0.
#
# ```powershell
# dist\windows\tab-churn-check.ps1 -Probe               # ① 조건 확인 (단축키가 먹는지) — 먼저 돌린다
# dist\windows\tab-churn-check.ps1                      # ② 본 회차 20 사이클 · 간격 1.5 초
# dist\windows\tab-churn-check.ps1 -Cycles 10 -GapMs 2000
# ```
#
# ## 함정 — 빠뜨리면 반대 결론이 나온다
#
#  - **`SendInput` 은 `wScan` 을 `MapVirtualKeyW` 로 채워야 한다.** 안 채우면 `Ctrl+Shift+T` 가
#    앱에 닿지 않는데 화면상 아무 일도 안 일어나서 **"앱이 정상" 으로 오독**한다. 실제로 회차를
#    하나 그렇게 버렸다 (`dist/stress/send-keys.ps1` 이 같은 주의를 적어 두었다).
#  - **탭 생성은 성공 시 로그를 남기지 않는다** (`log.zig` 는 실패만 적는다). 그래서 로그로는
#    "단축키가 안 먹었다" 와 "먹었다" 를 못 가른다. 판정은 `-Probe` 의 **ConPTY 개수 (1 → 2)** 로
#    하고, 본 회차 전에 반드시 한 번 돌린다.
#  - **간격 없이 몰아 돌리면 자식 `cmd.exe` 가 `0xc0000142` 로 시작에 실패**하고 Windows 오류
#    다이얼로그가 **사용자 화면에** 뜬다. 그 회차는 정지 원인을 가릴 수 없어 무효다. 그래서
#    `#32770` 창을 매 사이클 확인해 뜨면 멈추고, 기본 간격을 1.5 초로 둔다.
#
# ## 안전 규칙 (AGENTS.md `# 실행 환경`)
#
#  - `--instance 9` + `-e` 회차라 `config_9.toml` 도 전역 hotkey 도 만들지 않는다.
#  - 키마다 포커스 가드 — foreground 가 우리 창이 아니면 그 자리에서 멈춘다 (사용자 창에
#    타이핑되는 것을 막는다).
#  - 끝나면 인스턴스 9 만 내리고 남은 프로세스를 정리한다.
#  - 실기라 **시작 전에 사용자에게 알리고 동의를 받는다** — 창이 뜨고 합성 키가 나간다.
#
# 이 파일은 UTF-8 **BOM** 으로 저장한다 (PowerShell 5.1 은 BOM 이 없으면 CP949 로 읽어 한글 주석이 깨진다).

param(
    [string]$Bin = (Join-Path $PSScriptRoot '..\..\zig-out\bin\tildaz.exe'),
    [int]$Cycles = 20,
    # 새 탭을 만든 뒤 닫기까지의 간격 (ms). 0 에 가까울수록 자식이 콘솔 컨트롤 핸들러를
    # 세우기 전에 CTRL_CLOSE_EVENT 를 받는다.
    [int]$HoldMs = 0,
    # 사이클 사이 간격 (ms). 짧으면 콘솔 프로세스가 몰려 세션 자원이 모자라고
    # 자식이 0xc0000142 로 시작 실패한다 — 그 회차는 측정이 성립하지 않는다.
    [int]$GapMs = 1500,
    # 조건 확인 — 단축키가 실제로 먹는지를 단계별 ConPTY 개수로 본다.
    [switch]$Probe
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public static class TzWin
{
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }
    [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }

    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint n, INPUT[] inputs, int cb);
    [DllImport("user32.dll")] private static extern uint MapVirtualKeyW(uint code, uint mapType);
    private const uint INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;

    // `wScan` 을 반드시 채운다 (`dist/stress/send-keys.ps1` 의 같은 주석) — scan code 가 0 이면
    // 키가 제대로 해석되지 않는다. 그리고 구조체 배열은 **C# 안에서** 채운다: PowerShell 로
    // `$arr[$i].field = x` 를 하면 값 타입이 복사돼 원본이 안 바뀔 수 있다.
    private static INPUT One(ushort vk, uint flags)
    {
        INPUT i = new INPUT();
        i.type = INPUT_KEYBOARD;
        i.u.ki.wVk = vk;
        i.u.ki.wScan = (ushort)MapVirtualKeyW(vk, 0); // MAPVK_VK_TO_VSC
        i.u.ki.dwFlags = flags;
        return i;
    }

    /// chord — downs 를 순서대로, ups 를 역순으로 한 번에 보낸다.
    public static uint SendChord(ushort[] keys)
    {
        INPUT[] inputs = new INPUT[keys.Length * 2];
        int n = 0;
        for (int k = 0; k < keys.Length; k++) inputs[n++] = One(keys[k], 0);
        for (int k = keys.Length - 1; k >= 0; k--) inputs[n++] = One(keys[k], KEYEVENTF_KEYUP);
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SendMessageTimeoutW(IntPtr hWnd, uint msg, IntPtr wp, IntPtr lp, uint flags, uint timeoutMs, out IntPtr result);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }

    private delegate bool EnumProc(IntPtr hWnd, IntPtr lp);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr lp);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(IntPtr hWnd, System.Text.StringBuilder buf, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr hWnd, System.Text.StringBuilder buf, int max);

    /// 자식 셸이 시작에 실패하면 Windows 가 `#32770` 오류 다이얼로그를 띄운다
    /// (0xc0000142 — 콘솔 프로세스를 몰아서 만들면 세션 자원이 모자라 난다).
    /// 그 상태의 회차는 측정이 성립하지 않으므로 감지하면 멈춘다.
    public static string FindShellErrorDialog()
    {
        string hit = null;
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            var cls = new System.Text.StringBuilder(64);
            GetClassNameW(h, cls, cls.Capacity);
            if (cls.ToString() != "#32770") return true;
            var txt = new System.Text.StringBuilder(256);
            GetWindowTextW(h, txt, txt.Capacity);
            string t = txt.ToString();
            if (t.IndexOf("cmd.exe", StringComparison.OrdinalIgnoreCase) >= 0 ||
                t.IndexOf("powershell", StringComparison.OrdinalIgnoreCase) >= 0) { hit = t; return false; }
            return true;
        }, IntPtr.Zero);
        return hit;
    }

    // AGENTS.md — Process.MainWindowHandle 은 owner 가 달린 진짜 창을 건너뛰어 0 이고,
    // FindWindow(class) 는 숨은 owner 창 (TildaZOwner) 을 집는다. pid + 보임 + 크기로 찾는다.
    public static List<IntPtr> WindowsOf(uint pid)
    {
        var found = new List<IntPtr>();
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid) return true;
            if (!IsWindowVisible(h)) return true;
            RECT r; if (!GetWindowRect(h, out r)) return true;
            if ((r.right - r.left) < 100 || (r.bottom - r.top) < 100) return true;
            found.Add(h);
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@

$VK = @{ Control = 0x11; Shift = 0x10; T = 0x54; W = 0x57 }
$KEYEVENTF_KEYUP = 0x0002

function Send-Chord {
    param([uint16[]]$Keys)
    # 보낸 이벤트 수가 기대와 다르면 SendInput 이 거부된 것이다 — 조용히 넘어가지 않는다.
    $n = [TzWin]::SendChord($Keys)
    if ($n -ne ($Keys.Count * 2)) { throw "SendInput 거부: 보낸 수 $n (기대 $($Keys.Count * 2))" }
}

function Get-TzConsole {
    Get-CimInstance Win32_Process -Filter "Name='OpenConsole.exe'" | Where-Object { $_.ExecutablePath -like '*tildaz*' }
}

function Test-UiAlive {
    param([IntPtr]$Hwnd)
    # WM_NULL 을 타임아웃과 함께 보내 UI 스레드가 메시지 펌프에 응답하는지 본다.
    # deinit 이 join 에서 막히면 여기서 0 (타임아웃) 이 돌아온다.
    $res = [IntPtr]::Zero
    $ok = [TzWin]::SendMessageTimeoutW($Hwnd, 0, [IntPtr]::Zero, [IntPtr]::Zero, 0x0002, 2000, [ref]$res)
    return ($ok -ne [IntPtr]::Zero)
}

# ── 시작 전 위생
$before = @(Get-TzConsole).Count
"시작 전 tildaz OpenConsole = $before"
if (-not (Test-Path $Bin)) { throw "바이너리 없음: $Bin" }

# -e 회차 — config_9.toml 도 전역 hotkey 도 만들지 않는다 (AGENTS.md).
$proc = Start-Process -FilePath $Bin -ArgumentList '--instance', '9', '-e', 'cmd.exe' -PassThru
Start-Sleep -Seconds 3

$hwnds = [TzWin]::WindowsOf([uint32]$proc.Id)
if ($hwnds.Count -eq 0) { $proc | Stop-Process -Force -ErrorAction SilentlyContinue; throw '창을 못 찾았어요 — 앱이 떴는지 로그를 보세요.' }
$hwnd = $hwnds[0]
"창 hwnd=$hwnd pid=$($proc.Id)"

# 다른 창이 덮고 있으면 SetForegroundWindow 도 클릭도 안 닿는다 — 잠깐 TOPMOST 로 올린다.
[void][TzWin]::SetWindowPos($hwnd, [IntPtr](-1), 0, 0, 0, 0, 0x0003)
[void][TzWin]::SetForegroundWindow($hwnd)
Start-Sleep -Milliseconds 500

if ([TzWin]::GetForegroundWindow() -ne $hwnd) {
    [void][TzWin]::SetForegroundWindow($hwnd)
    Start-Sleep -Milliseconds 500
}
if ([TzWin]::GetForegroundWindow() -ne $hwnd) {
    $proc | Stop-Process -Force -ErrorAction SilentlyContinue
    throw '포커스를 못 잡았어요 — blind 로 키를 보내지 않고 멈춥니다.'
}

# ── 조건 확인 모드 — 단축키가 실제로 먹는지를 ConPTY 개수로 확정한다.
# 탭 생성은 **성공 시 로그를 남기지 않으므로** (log.zig 는 실패만 적는다) 로그로는
# "안 먹었다" 와 "먹었다" 를 가를 수 없다. 새 탭이 생기면 OpenConsole 이 하나 늘어난다.
if ($Probe) {
    "① 시작 상태: OpenConsole = $(@(Get-TzConsole).Count)  (탭 1 개 = 1 이 정상)"
    Send-Chord @([uint16]$VK.Control, [uint16]$VK.Shift, [uint16]$VK.T)
    Start-Sleep -Seconds 2
    "② Ctrl+Shift+T 뒤: OpenConsole = $(@(Get-TzConsole).Count)  (2 여야 단축키가 먹은 것)"
    Send-Chord @([uint16]$VK.Control, [uint16]$VK.Shift, [uint16]$VK.W)
    Start-Sleep -Seconds 2
    "③ Ctrl+Shift+W 뒤: OpenConsole = $(@(Get-TzConsole).Count)  (1 이면 정상 정리)"
    Get-CimInstance Win32_Process -Filter "Name='tildaz.exe'" | Where-Object { $_.CommandLine -like '*--instance 9*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    "④ 앱 종료 뒤: OpenConsole = $(@(Get-TzConsole).Count)"
    foreach ($x in (Get-TzConsole)) {
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$($x.ProcessId)" -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

$hangCycle = -1
$maxLeft = 0
for ($c = 1; $c -le $Cycles; $c++) {
    if ([TzWin]::GetForegroundWindow() -ne $hwnd) { "사이클 ${c}: 포커스 이탈 — 중단"; break }
    Send-Chord @([uint16]$VK.Control, [uint16]$VK.Shift, [uint16]$VK.T)   # 새 탭
    if ($HoldMs -gt 0) { Start-Sleep -Milliseconds $HoldMs }
    if ([TzWin]::GetForegroundWindow() -ne $hwnd) { "사이클 ${c}: 포커스 이탈 — 중단"; break }
    Send-Chord @([uint16]$VK.Control, [uint16]$VK.Shift, [uint16]$VK.W)   # 그 탭 닫기
    Start-Sleep -Milliseconds 400

    $err = [TzWin]::FindShellErrorDialog()
    if ($err) {
        "사이클 ${c}: **자식 셸 시작 실패 다이얼로그** [$err] — 자원 고갈이라 이 회차는 무효. 중단합니다."
        break
    }

    $alive = Test-UiAlive -Hwnd $hwnd
    $left = @(Get-TzConsole).Count
    if ($left -gt $maxLeft) { $maxLeft = $left }
    if (-not $alive) {
        # 일시적 지연과 영구 정지를 가른다 — 최대 40 초까지 다시 물어본다.
        $waited = 2
        $recovered = $false
        while ($waited -lt 40) {
            if (Test-UiAlive -Hwnd $hwnd) { $recovered = $true; break }
            $waited += 2
        }
        if ($recovered) {
            "사이클 ${c}: UI 무응답 ${waited}초 뒤 회복 (일시적) · OpenConsole=$left"
        } else {
            $hangCycle = $c
            "사이클 ${c}: **UI 영구 무응답** (40초 재확인 실패) · OpenConsole=$left"
            break
        }
    }
    if ($c % 5 -eq 0) { "사이클 ${c}: UI 정상 · OpenConsole=$left" }
    Start-Sleep -Milliseconds $GapMs
}

$leftEnd = @(Get-TzConsole).Count
"결과: 사이클=$Cycles hold=${HoldMs}ms · UI무응답=$(if ($hangCycle -gt 0) { "사이클 $hangCycle" } else { '없음' }) · OpenConsole 최대=$maxLeft 최종=$leftEnd"

# ── 정리: 인스턴스 9 만 내린다
Get-CimInstance Win32_Process -Filter "Name='tildaz.exe'" | Where-Object { $_.CommandLine -like '*--instance 9*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
$after = @(Get-TzConsole).Count
"앱 종료 뒤 남은 OpenConsole = $after"
foreach ($x in (Get-TzConsole)) {
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$($x.ProcessId)" -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue
}
"정리 완료"
