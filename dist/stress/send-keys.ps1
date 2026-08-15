# 응답 시간 측정 (#441 축 ②) 의 **Windows 합성 입력** — Linux 판의 `ydotool` 자리다.
#
# `measure-input-latency.sh` 가 Windows 회차에서 이 파일을 한 번 부르고, 이 스크립트가
# **한 회차의 키 순서를 통째로** 보낸다 (`a` × N → Ctrl+C → Ctrl+Shift+F12 → Ctrl+Shift+W).
# 키마다 `powershell` 을 새로 띄우면 그 기동 시간 (수백 ms) 이 키 간격을 지배해서
# `--gap` 이 의미를 잃는다.
#
# ## 왜 `SendInput` 인가
#
# `keybd_event` 는 Microsoft 가 대체를 권고한 예전 API 이고, `SendKeys` (WScript.Shell) 는
# **포커스된 창에 blind 로** 넣는 방식이라 아래 포커스 가드를 걸 수 없다. `SendInput` 은
# 큐에 원자적으로 넣고 실패를 반환값으로 알려 준다.
#
# ## 포커스 가드 — 이게 없으면 사용자 창에 타이핑된다
#
# 합성 입력은 **포커스된 창**으로 간다. 예전 Windows 시연에서 `SetForegroundWindow` 가
# 간헐적으로 거부됐고, 그때 키가 그대로 **사용자가 보고 있던 창**에 들어갔다 (Claude Code
# 프롬프트에 명령이 타이핑됐다). 그래서 **키 하나마다** `GetForegroundWindow()` 를 확인하고,
# 어긋나면 그 자리에서 회차를 실패로 끝낸다 — blind 로 계속 치지 않는다.
#
# 그리고 **`SetForegroundWindow` 하나로는 부족하다.** 이 도구 첫 측정에서 Windows 알림 토스트
# (`Windows.UI.Core.CoreWindow` · "새 알림") 가 foreground 를 쥐고 있어 회차가 세 번 연속
# 폐기됐다 — 앱은 정상으로 떴는데 **활성이 못 됐다.** 거부되면 창 안쪽 (client 한가운데) 을
# 실제로 클릭해 회수한다. 사용자가 하는 것과 같은 행위라 foreground lock 이 걸리지 않는다.
#
# ## 이 파일은 UTF-8 **BOM** 으로 저장한다
#
# Windows PowerShell 5.1 은 BOM 이 없으면 `.ps1` 을 ANSI (한국어 Windows 는 CP949) 로 읽어
# 주석의 한글이 깨진다. 편집 후 BOM 이 남아 있는지 확인한다.

param(
    # 보낼 문자 키 횟수.
    [int]$Presses = 30,
    # 키 사이 간격 (초). 각 키가 독립적으로 처리되도록 넉넉히 둔다.
    [double]$GapSec = 0.2,
    # 측정 인스턴스의 창. `instances.zig` 의 `stress_window_title` 과 `window.zig` 의
    # class 이름이다. **둘 다 준다** — class 를 쓰는 창이 둘이라 (숨겨진 owner 창 =
    # `TildaZOwner`, 실제 창 = 아래 title) class 만 주면 owner 를 집는다.
    [string]$WindowTitle = 'TildaZ-stress',
    [string]$WindowClass = 'TildaZWindow',
    # 한글 입력 상태에서 문자 키가 어떻게 되는지 보려는 회차. 기본은 영문으로 맞춘다.
    [switch]$KeepImeMode,
    # 마지막 종료 키 (Ctrl+Shift+W) 를 보내지 않는다 — 창을 남겨 두고 확인할 때.
    [switch]$NoQuit
)

$ErrorActionPreference = 'Stop'
# Git Bash 로 돌려보내는 출력은 UTF-8 이어야 한다 (PowerShell 5.1 의 기본은 CP949).
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

if ([IntPtr]::Size -ne 8) {
    Write-Error '32 비트 PowerShell 이에요 — 아래 INPUT 구조체 배치가 64 비트 기준이에요.'
    exit 2
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class TzInput
{
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    // x64 의 INPUT 은 union 정렬 때문에 type(4) 뒤 4 byte 가 비고 전체가 40 byte 다.
    [StructLayout(LayoutKind.Explicit, Size = 40)]
    public struct INPUT
    {
        [FieldOffset(0)] public uint type;
        [FieldOffset(8)] public KEYBDINPUT ki;
        [FieldOffset(8)] public MOUSEINPUT mi;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left; public int top; public int right; public int bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int x; public int y; }

    public const uint INPUT_MOUSE = 0;
    public const uint INPUT_KEYBOARD = 1;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const uint MOUSEEVENTF_MOVE = 0x0001;
    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP = 0x0004;
    public const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;
    public const uint MOUSEEVENTF_ABSOLUTE = 0x8000;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    public static extern uint MapVirtualKeyW(uint uCode, uint uMapType);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowW(string lpClassName, string lpWindowName);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT r);

    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hWnd, ref POINT p);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT p);

    [DllImport("imm32.dll")]
    public static extern IntPtr ImmGetDefaultIMEWnd(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeoutW(
        IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam,
        uint flags, uint timeout, out IntPtr result);

    // 화면 좌표를 눌렀다 뗀다 (포커스 회수용). 좌표는 가상 데스크톱 기준 0..65535 정규화다.
    public static uint ClickScreen(int x, int y)
    {
        uint move = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
        int nx, ny;
        Normalize(x, y, out nx, out ny);
        INPUT[] inputs = new INPUT[] {
            Mouse(nx, ny, move),
            Mouse(nx, ny, move | MOUSEEVENTF_LEFTDOWN),
            Mouse(nx, ny, move | MOUSEEVENTF_LEFTUP),
        };
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    // **커서를 되돌릴 때는 옮기기만 한다.** 클릭으로 되돌리면 원래 자리에 있던 창 (사용자의
    // 창일 수 있다) 을 실제로 누르게 된다.
    public static uint MoveScreen(int x, int y)
    {
        int nx, ny;
        Normalize(x, y, out nx, out ny);
        INPUT[] inputs = new INPUT[] {
            Mouse(nx, ny, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK),
        };
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    private static void Normalize(int x, int y, out int nx, out int ny)
    {
        int vx = GetSystemMetrics(76); // SM_XVIRTUALSCREEN
        int vy = GetSystemMetrics(77); // SM_YVIRTUALSCREEN
        int vw = GetSystemMetrics(78); // SM_CXVIRTUALSCREEN
        int vh = GetSystemMetrics(79); // SM_CYVIRTUALSCREEN
        nx = (int)(((long)(x - vx) * 65535) / (vw > 1 ? vw - 1 : 1));
        ny = (int)(((long)(y - vy) * 65535) / (vh > 1 ? vh - 1 : 1));
    }

    private static INPUT Mouse(int nx, int ny, uint flags)
    {
        INPUT i = new INPUT();
        i.type = INPUT_MOUSE;
        i.mi.dx = nx;
        i.mi.dy = ny;
        i.mi.mouseData = 0;
        i.mi.dwFlags = flags;
        i.mi.time = 0;
        i.mi.dwExtraInfo = IntPtr.Zero;
        return i;
    }

    // 키 하나를 눌렀다 뗀다. 여러 키를 겹쳐 눌러야 하는 chord 는 downs / ups 로 겹쳐 준다.
    public static uint Send(ushort[] downs, ushort[] ups)
    {
        INPUT[] inputs = new INPUT[downs.Length + ups.Length];
        int n = 0;
        foreach (ushort vk in downs) inputs[n++] = One(vk, 0);
        foreach (ushort vk in ups) inputs[n++] = One(vk, KEYEVENTF_KEYUP);
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    // `wScan` 을 반드시 채운다. scan code 가 0 이면 `TranslateMessage` 의 `ToUnicode` 가
    // 문자를 못 만들어 **WM_CHAR 가 안 오고**, 그러면 셸 에코가 없어 이 측정이 성립하지
    // 않는다 (재는 구간이 "키 → 에코가 화면에 닿기까지" 이므로).
    private static INPUT One(ushort vk, uint flags)
    {
        INPUT i = new INPUT();
        i.type = INPUT_KEYBOARD;
        i.ki.wVk = vk;
        i.ki.wScan = (ushort)MapVirtualKeyW(vk, 0); // MAPVK_VK_TO_VSC
        i.ki.dwFlags = flags;
        i.ki.time = 0;
        i.ki.dwExtraInfo = IntPtr.Zero;
        return i;
    }
}
'@

$VK = @{
    a = 0x41; c = 0x43; w = 0x57; F12 = 0x7B
    Ctrl = 0x11; Shift = 0x10
}

# --- 창 찾기 ---------------------------------------------------------------
$hwnd = [TzInput]::FindWindowW($WindowClass, $WindowTitle)
if ($hwnd -eq [IntPtr]::Zero) {
    Write-Output "  ❌ 측정 창을 못 찾았어요 (class=$WindowClass title=$WindowTitle)"
    exit 3
}

# --- 포커스 가드 -----------------------------------------------------------
#
# **`SetForegroundWindow` 만으로는 부족하다.** Windows 는 *지금 foreground 를 가진
# 프로세스* 가 아니면 이 호출을 조용히 거부한다 (foreground lock). 실측에서 알림 토스트
# (`Windows.UI.Core.CoreWindow` · "새 알림") 가 foreground 를 쥐고 있어 회차가 세 번
# 연속으로 폐기됐다 — 측정 창은 그때 **뜨지도 못한 게 아니라 활성이 못 된 것**이었다.
#
# 그래서 거부되면 **창 안쪽을 실제로 클릭한다.** 사용자가 하는 것과 같은 행위라 foreground
# lock 이 적용되지 않고, Linux 판의 `--focus-wait` (사람이 클릭할 시간을 준다) 와 같은 자리다.
# 클릭 지점은 **client 영역 한가운데**다 — 위쪽 탭바 / 우측 컨트롤 (`[+][×][…]`) · scrollbar 를
# 피해야 버튼이 눌리지 않는다. 커서 위치는 클릭 전 자리로 되돌린다.
function Get-ClientCenter {
    # 중첩 타입은 `외부+내부` 이고, PowerShell 에서는 **따옴표로 감싸야** 파서가 `+` 를
    # 연산자로 읽지 않는다.
    $r = New-Object -TypeName 'TzInput+RECT'
    if (-not [TzInput]::GetClientRect($script:hwnd, [ref]$r)) { return $null }
    $p = New-Object -TypeName 'TzInput+POINT'
    $p.x = [int](($r.right - $r.left) / 2)
    $p.y = [int](($r.bottom - $r.top) / 2)
    if (-not [TzInput]::ClientToScreen($script:hwnd, [ref]$p)) { return $null }
    return $p
}

function Assert-Focus {
    param([switch]$Recover)
    if ([TzInput]::GetForegroundWindow() -eq $script:hwnd) { return $true }
    if (-not $Recover) { return $false }

    [void][TzInput]::SetForegroundWindow($script:hwnd)
    Start-Sleep -Milliseconds 300
    if ([TzInput]::GetForegroundWindow() -eq $script:hwnd) { return $true }

    $center = Get-ClientCenter
    if ($null -eq $center) { return $false }
    $before = New-Object -TypeName 'TzInput+POINT'
    $have_cursor = [TzInput]::GetCursorPos([ref]$before)
    [void][TzInput]::ClickScreen($center.x, $center.y)
    Start-Sleep -Milliseconds 300
    $ok = ([TzInput]::GetForegroundWindow() -eq $script:hwnd)
    if ($ok) { $script:focus_clicked = $true }
    if ($have_cursor) { [void][TzInput]::MoveScreen($before.x, $before.y) }
    return $ok
}

$focus_clicked = $false
if (-not (Assert-Focus -Recover)) {
    Write-Output '  ❌ 측정 창이 활성이 아니에요 — 키를 보내지 않았어요 (사용자 창으로 샐 수 있어요)'
    exit 4
}

# --- IME 상태 --------------------------------------------------------------
#
# Windows 의 한/영 은 keyboard layout 이 아니라 **IME conversion mode** 라서, 다른
# 프로세스의 창이라도 그 창의 default IME 창에 `WM_IME_CONTROL` 을 보내 읽고 쓸 수 있다.
# (`ImmGetConversionStatus` 는 호출 스레드의 IME context 를 보므로 여기서는 못 쓴다.)
$WM_IME_CONTROL = 0x0283
$IMC_GETCONVERSIONMODE = 0x0001
$IMC_SETCONVERSIONMODE = 0x0002
$IME_CMODE_NATIVE = 0x0001
$SMTO_ABORTIFHUNG = 0x0002

function Get-ImeMode {
    $ime = [TzInput]::ImmGetDefaultIMEWnd($script:hwnd)
    if ($ime -eq [IntPtr]::Zero) { return $null }
    $res = [IntPtr]::Zero
    $ok = [TzInput]::SendMessageTimeoutW($ime, $WM_IME_CONTROL,
        [IntPtr]$IMC_GETCONVERSIONMODE, [IntPtr]::Zero, $SMTO_ABORTIFHUNG, 1000, [ref]$res)
    if ($ok -eq [IntPtr]::Zero) { return $null }
    return [int]$res
}

function Set-ImeMode {
    param([int]$Mode)
    $ime = [TzInput]::ImmGetDefaultIMEWnd($script:hwnd)
    if ($ime -eq [IntPtr]::Zero) { return $false }
    $res = [IntPtr]::Zero
    $ok = [TzInput]::SendMessageTimeoutW($ime, $WM_IME_CONTROL,
        [IntPtr]$IMC_SETCONVERSIONMODE, [IntPtr]$Mode, $SMTO_ABORTIFHUNG, 1000, [ref]$res)
    return ($ok -ne [IntPtr]::Zero)
}

$ime_before = Get-ImeMode
$ime_restore = $null
if (-not $KeepImeMode -and $null -ne $ime_before -and ($ime_before -band $IME_CMODE_NATIVE)) {
    # 한글 모드다. 영문 (native 비트 끔) 으로 바꾸고 끝나면 되돌린다.
    if (Set-ImeMode -Mode ($ime_before -band (-bnot $IME_CMODE_NATIVE))) {
        $ime_restore = $ime_before
        Write-Output '  입력기가 한글이라 영문으로 바꿨어요 (측정이 끝나면 되돌립니다).'
    } else {
        Write-Output '  ⚠ 입력기를 영문으로 못 바꿨어요 — 한글 모드 그대로 보냅니다.'
    }
}
$ime_used = Get-ImeMode

# --- 키 전송 ---------------------------------------------------------------
function Send-Key {
    # `[ushort]` 는 PowerShell 5.1 에 없는 타입 가속기다 (`Unable to find type [ushort]`).
    # `.sh` 가 부르는 것이 5.1 이라 여기서는 `[uint16]` 을 쓴다 — C# 쪽 `ushort` 와 같은 타입이다.
    param([uint16[]]$Downs, [uint16[]]$Ups)
    if (-not (Assert-Focus)) { return $false }
    $n = [TzInput]::Send($Downs, $Ups)
    return ($n -eq ($Downs.Length + $Ups.Length))
}

$sent = 0
$fail = ''
for ($i = 1; $i -le $Presses; $i++) {
    if (-not (Send-Key -Downs @($VK.a) -Ups @($VK.a))) {
        $fail = "키 $i 번째에서 멈췄어요 (포커스를 잃었거나 SendInput 이 거부됐어요)"
        break
    }
    $sent++
    Start-Sleep -Milliseconds ([int]($GapSec * 1000))
}

if ($fail -eq '') {
    # Ctrl+C — 입력 줄 비우기.
    [void](Send-Key -Downs @($VK.Ctrl, $VK.c) -Ups @($VK.c, $VK.Ctrl))
    Start-Sleep -Milliseconds 300
    # **덤프를 여기서 직접 남긴다.** 종료 덤프 (#396) 에만 기대면 앱이 제때 안 닫혔을 때
    # 값이 통째로 사라진다 (Linux 판이 실측으로 겪었다).
    [void](Send-Key -Downs @($VK.Ctrl, $VK.Shift, $VK.F12) -Ups @($VK.F12, $VK.Shift, $VK.Ctrl))
    Start-Sleep -Milliseconds 500
    if (-not $NoQuit) {
        # `Alt+F4` 가 아니라 `Ctrl+Shift+W` 다 — Alt+F4 는 종료 확인 다이얼로그를 띄우고
        # 기다려서 앱이 안 닫힌다. 탭이 하나면 탭 닫기가 곧 앱 종료다.
        [void](Send-Key -Downs @($VK.Ctrl, $VK.Shift, $VK.w) -Ups @($VK.w, $VK.Shift, $VK.Ctrl))
    }
}

if ($null -ne $ime_restore) { [void](Set-ImeMode -Mode $ime_restore) }

function Format-Ime {
    param($mode)
    if ($null -eq $mode) { return 'none' }
    if ($mode -band $IME_CMODE_NATIVE) { return "hangul($mode)" }
    return "alpha($mode)"
}

$focus_note = if ($focus_clicked) { '   (포커스를 클릭으로 회수했어요)' } else { '' }
Write-Output ("  보낸 키 {0} / {1}   IME {2} → {3}{4}" -f $sent, $Presses,
    (Format-Ime $ime_before), (Format-Ime $ime_used), $focus_note)
if ($fail -ne '') {
    Write-Output "  ❌ $fail"
    exit 5
}
exit 0
