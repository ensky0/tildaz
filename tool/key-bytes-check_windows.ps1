# `tool/key-bytes.py` 를 tildaz 탭에 띄우고 **합성 입력으로** 키를 쳐서, 앱이 PTY 에 쓴 바이트를 기대값과
# 견준다 (#648 · #650 의 Windows 몫). 손으로 치는 회차를 대신한다 — 판정이 자동이라 회귀 검사로 쓸 수 있다.
#
# ```powershell
# tool\key-bytes-check_windows.ps1                       # 네 회차 (legacy · kitty · mok2 · layout) 전부
# tool\key-bytes-check_windows.ps1 -Mode legacy          # 한 회차만
# tool\key-bytes-check_windows.ps1 -Mode layout          # 비US 배열 (프랑스어 AZERTY · #684)
# tool\key-bytes-check_windows.ps1 -Bin C:\path\tildaz.exe
# ```
#
# ⚠️ **상대 경로로 부르지 않는다** — `powershell -NoProfile -File` 에 상대 경로를 주면 아래
# `$PSScriptRoot` 함정과 겹쳐 더 헷갈린다. 절대 경로로 부른다.
#
# 무엇을 하나 —
# 1. `--instance 9 -e <자식.cmd>` 로 tildaz 를 띄운다. 자식은 `key-bytes.py` 를 돌리고 **stdout 을 파일로**
#    돌린다. `-e` 는 stress run 이라 hotkey 도 config 도 만들지 않는다 (로그는 `tildaz_stress.log`).
# 2. `SendInput` 으로 chord 를 하나씩 보내고 (간격 700 ms) **키마다** 그 뒤에 새로 생긴 hex 줄만 파일에서
#    읽어 기대와 견준다 (#684 — 순서로 맞추면 한 키가 0 바이트일 때 뒤가 전부 밀린다).
#    칠 키는 이 파일의 회차 표에 세 OS 공용 표 [`key-bytes-cases.tsv`](key-bytes-cases.tsv) 의 행을 더한 것이다.
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
#   - ~~`Ctrl+H` → `7f`~~ · ~~`Shift+Tab` → `09`~~ · ~~`Ctrl+Enter` → `0a`~~ — [#653](https://github.com/ensky0/tildaz/issues/653) 에서
#     고쳤다. Backspace · Tab · Enter 를 `WM_CHAR` 가 아니라 **인코더**로 보내면서 세 platform 이 이
#     대역에서 전부 같아졌다. legacy 는 맨 키의 C0 다 — `Ctrl+H`=`08` · `Shift+Tab`=`ESC[Z` ·
#     `Ctrl+Tab`=`09` · `Ctrl+Enter`=`0d` · `Ctrl+Backspace`=`08`.
#   - ~~`mok2` 에서도 `Ctrl+[` 가 `1b`~~ — [#684](https://github.com/ensky0/tildaz/issues/684) 에서 사라졌다.
#     그 차이의 원인은 "Windows 가 legacy · mok2 에서 `Ctrl`+글자를 인코더로 안 보낸다" 였고, 이제 세 모드
#     모두 인코더를 탄다. `mok2` 의 `Ctrl+[` · `Ctrl+I` 는 Linux · macOS 와 같이 `CSI 27;<mods>;<cp>~` 다 —
#     ghostty 가 `i` · `m` · `[` 를 fixterms 명세대로 `ctrlSeq` 에서 **일부러 빼** `CSI u` 로 보내고, mok2 는
#     그것을 "앱이 요청한 인코딩" 으로 보아 C0 로 내리지 않기 때문이다. 그 세 칸은 공용 표에 있다.
#
# 함정 —
#  - **chord 는 `,@(…)` (단항 콤마) 로 감싼다.** PowerShell 이 원소 하나짜리 배열을 평탄화해 modifier 와
#    글자를 따로 누르게 만든다 (AGENTS.md `# Windows — 합성 입력으로 …` 의 같은 주의).
#  - **`SendInput` 은 `wScan` 을 `MapVirtualKeyW` 로 채워야** 앱에 닿는다. 방향키 등 control pad 는
#    확장 (`0xE0`) 플래그도 필요하다 — 안 붙이면 numpad 로 간다.
#  - **키마다 포커스 가드** — foreground 가 tildaz 창이 아니면 그 자리에서 멈춘다. 합성 키는 포커스된
#    창으로 가니 회차 중 다른 창을 만지면 거기에 타이핑된다.
#  - Python 3 이 `python` 으로 PATH 에 있어야 한다 (`kitty-text-check_windows.ps1` 과 같은 전제).
#  - **앱 단축키는 회차에 넣지 않는다 — 바인딩이 *없는* 글자를 고른다.** `Ctrl+Shift+<글자>` 는
#    앱 chrome 대역이고 (AGENTS.md `# 새 단축키 기본값 고르기`) 단축키 조회가 인코더보다 먼저라,
#    그 키는 인코더에 아예 닿지 않는다. 재려는 것이 인코딩이면 그 대역에서 비어 있는 글자를 쓴다
#    (지금은 `Ctrl+Shift+G`). 2026-10-01 첫 회차는 `Ctrl+Shift+F` 를 쳤는데 그것이 검색바
#    ([#646](https://github.com/ensky0/tildaz/issues/646)) 를 열어 **그 뒤 16 키가 통째로 무효**였다
#    (`Escape` 가 바를 닫으며 소비돼 그다음부터 복귀). 앱이 바이트를 안 내는 것으로 읽힐 뻔했다.
#    글자를 바꿀 때는 `config.zig` 의 두 기본값 목록을 grep 해 비어 있는지 먼저 본다.
#  - ⚠️ **`[CmdletBinding()]` 이 붙은 스크립트는 param 기본값에서 `$PSScriptRoot` 가 비어 있다**
#    (Windows PowerShell 5.1 실측 — 본문에서는 정상이다). 기본값에 `Join-Path $PSScriptRoot …` 를
#    쓰면 `-Bin` 을 명시하지 않는 한 도구가 **시작도 못 한다.** 기본 경로는 본문에서 채운다.
#
# 실기라서 **시작 전에 알리고 동의를 받는다** (AGENTS.md `# 실행 환경`) — 창이 모드마다 한 번씩 뜨고
# 합성 키가 나간다.
#
# ⚠️ 이 파일은 UTF-8 **BOM** 으로 저장한다 — Windows PowerShell 5.1 은 BOM 없는 `.ps1` 을 cp949 로 읽는다.
[CmdletBinding()]
param(
    [ValidateSet("all", "legacy", "kitty", "mok2", "layout", "deadkey")][string]$Mode = "all",
    # 기본값은 본문에서 채운다 — 머리 주석의 `$PSScriptRoot` 함정.
    [string]$Bin = ""
)

$ErrorActionPreference = "Stop"
if (-not $Bin) { $Bin = Join-Path $PSScriptRoot '..\zig-out\bin\tildaz.exe' }
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
  [DllImport("user32.dll")] public static extern uint MapVirtualKeyExW(uint c, uint t, IntPtr hkl);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr LoadKeyboardLayoutW(string klid, uint flags);
  [DllImport("user32.dll")] public static extern bool UnloadKeyboardLayout(IntPtr hkl);
  [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint thread);
  [DllImport("user32.dll")] public static extern int GetKeyboardLayoutList(int n, IntPtr[] list);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort vk, scan; public uint flags; public uint time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public KEYBDINPUT ki; public int pad1, pad2; }
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] a, int cb);

  // control pad 는 확장 (0xE0) 이다 — 안 붙이면 numpad 로 간다. VK_RMENU (AltGr 의 오른쪽
  // Alt) 도 확장이라 함께 넣는다 — 안 붙이면 왼쪽 Alt 로 가 AltGr 조합이 성립하지 않는다.
  static bool IsExtended(ushort vk) {
    return vk == 0x25 || vk == 0x26 || vk == 0x27 || vk == 0x28
        || vk == 0x2D || vk == 0x2E || vk == 0x24 || vk == 0x23
        || vk == 0x21 || vk == 0x22 || vk == 0xA5;
  }
  // scan 은 **그 layout 기준**으로 뽑는다 (#684). AZERTY 의 a 는 sc 0x10 인데 US 기준으로
  // 채우면 0x1E 가 실려, 프랑스어 창에는 vk=VK_A + sc=0x1E 라는 없는 조합이 도착한다.
  // hkl 이 0 이면 우리 스레드의 활성 layout 을 명시한다 — NULL 은 MapVirtualKeyExW 에서
  // *마지막에 로드한* layout 을 뜻해서 layout 회차 뒤에 값이 흔들린다 (#496 함정).
  static INPUT Key(ushort vk, bool up, IntPtr hkl) {
    var i = new INPUT(); i.type = 1;
    i.ki.vk = vk;
    i.ki.scan = (ushort)MapVirtualKeyExW(vk, 0, hkl == IntPtr.Zero ? GetKeyboardLayout(0) : hkl);
    i.ki.flags = (uint)((up ? 2 : 0) | (IsExtended(vk) ? 1 : 0));
    return i;
  }
  // 순서대로 누르고 역순으로 뗀다.
  public static uint Chord(ushort[] keys, IntPtr hkl) {
    var a = new INPUT[keys.Length * 2];
    for (int i = 0; i < keys.Length; i++) a[i] = Key(keys[i], false, hkl);
    for (int i = 0; i < keys.Length; i++) a[keys.Length + i] = Key(keys[keys.Length - 1 - i], true, hkl);
    return SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT)));
  }
  // layout 은 **활성화하지 않고** (flags=0) 올린 뒤, 그 창의 스레드만 전환한다 —
  // DefWindowProc 이 WM_INPUTLANGCHANGEREQUEST 를 받아 ActivateKeyboardLayout 한다.
  // 우리 셸도 사용자의 다른 창도 그대로다 (deadkey-check 와 같은 수).
  public static IntPtr LayoutOfWindow(IntPtr h) { uint pid; uint tid = GetWindowThreadProcessId(h, out pid); return GetKeyboardLayout(tid); }
  // 세션 목록 길이 — 올린 layout 이 원래 있던 것인지 (= 내리면 안 되는지) 가린다.
  public static int LayoutCount() { var a = new IntPtr[64]; return GetKeyboardLayoutList(64, a); }
  public static void RequestLayout(IntPtr h, IntPtr hkl) { PostMessageW(h, 0x0050, IntPtr.Zero, hkl); }
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
    Esc = 0x1B                                                    # #650 — VK_ESCAPE
    # `G` 는 `Ctrl+Shift+` 대역에서 바인딩이 없는 글자다 (머리 주석) — `F` 는 검색바라 쓰지 않는다.
    A = 0x41; C = 0x43; G = 0x47; H = 0x48; I = 0x49; M = 0x4D
    LBracket = 0xDB                                               # VK_OEM_4
    # C0 대응이 없는 문장부호 일곱 (#650 본문 "같이 결정할 것" 1 번 — 2026-09-15 에 함께 닫았다).
    Semi = 0xBA; Quote = 0xDE; Comma = 0xBC; Period = 0xBE        # VK_OEM_1 · 7 · COMMA · PERIOD
    Minus = 0xBD; Backtick = 0xC0; Equal = 0xBB                   # VK_OEM_MINUS · 3 · PLUS
}

# 모드별 회차. `e` 는 기대 hex (`""` 는 "아무 바이트도 안 나가야 한다").
$rounds = @(
    @{ mode = "legacy"; enable = ""; keys = @(
        @{ n = "Ctrl+[";           k = ,@($VK.Ctrl, $VK.LBracket);            e = "1b" }          # #650 — 전에는 CSI 91;5u
        @{ n = "Ctrl+I";           k = ,@($VK.Ctrl, $VK.I);                   e = "09" }          # #650
        @{ n = "Ctrl+M";           k = ,@($VK.Ctrl, $VK.M);                   e = "0d" }          # #650
        @{ n = "Ctrl+Shift+G";     k = ,@($VK.Ctrl, $VK.Shift, $VK.G);        e = "" }            # #648 — 억제
        @{ n = "Ctrl+Shift+Enter"; k = ,@($VK.Ctrl, $VK.Shift, $VK.Enter);    e = "" }            # #648 — 억제
        @{ n = "Ctrl+A";           k = ,@($VK.Ctrl, $VK.A);                   e = "01" }          # 회귀 감시
        @{ n = "Ctrl+C";           k = ,@($VK.Ctrl, $VK.C);                   e = "03" }          # 회귀 감시 (raw 라 SIGINT 아님)
        @{ n = "Ctrl+H";           k = ,@($VK.Ctrl, $VK.H);                   e = "08" }          # #653 — 전에는 7f (Backspace 와 합쳐졌다)
        @{ n = "Backspace";        k = ,@($VK.Back);                          e = "7f" }          # #653 — 인코더로 옮긴 뒤에도 그대로여야 한다
        @{ n = "Ctrl+Backspace";   k = ,@($VK.Ctrl, $VK.Back);               e = "08" }          # #653 — 전에는 7f
        @{ n = "Tab";              k = ,@($VK.Tab);                          e = "09" }          # #653 — 그대로
        @{ n = "Shift+Tab";        k = ,@($VK.Shift, $VK.Tab);                e = "1b 5b 5a" }    # #653 — 전에는 09 (back-tab 이 없었다)
        @{ n = "Ctrl+Left";        k = ,@($VK.Ctrl, $VK.Left);                e = "1b 5b 31 3b 35 44" }
        @{ n = "Ctrl+Tab";         k = ,@($VK.Ctrl, $VK.Tab);                 e = "09" }          # #653 — legacy 는 맨 키의 C0 (한때 ESC[27;5;9~ 였다)
        @{ n = "Ctrl+Enter";       k = ,@($VK.Ctrl, $VK.Enter);               e = "0d" }          # #653 — 전에는 0a (Win32 콘솔 관례). xterm 동등
        @{ n = "Shift+Enter";      k = ,@($VK.Shift, $VK.Enter);              e = "0d" }          # #653 — mac · Linux 는 ESC[27;2;13~ 였다
        @{ n = "Enter";            k = ,@($VK.Enter);                         e = "0d" }          # #653 — 인코더로 옮긴 뒤에도 그대로여야 한다
        @{ n = "Escape";           k = ,@($VK.Esc);                           e = "1b" }          # #650 — 인코더로 옮긴 뒤에도 그대로
        @{ n = "Shift+Escape";     k = ,@($VK.Shift, $VK.Esc);                e = "1b" }          # #650 — 맨 키의 C0
        # `Ctrl+Escape` 는 넣지 않는다 — Windows 는 OS 가 시작 메뉴로 가져가 앱에 오지 않고,
        # 회차 중에 그 메뉴가 뜨면 포커스를 잃어 남은 키가 전부 오염된다 (#650 기대표의 주석과 같다).
        #
        # C0 대응이 없는 문장부호 일곱 — `ccf2414` 의 규칙 ② 대로 아무것도 안 나가야 한다.
        # Windows 는 `WM_CHAR` 경로라 원래 0 바이트였을 것으로 보이지만 확인된 적이 없다 (#650).
        @{ n = "Ctrl+;";           k = ,@($VK.Ctrl, $VK.Semi);                e = "" }
        @{ n = "Ctrl+'";           k = ,@($VK.Ctrl, $VK.Quote);               e = "" }
        @{ n = "Ctrl+,";           k = ,@($VK.Ctrl, $VK.Comma);               e = "" }
        @{ n = "Ctrl+.";           k = ,@($VK.Ctrl, $VK.Period);              e = "" }
        @{ n = "Ctrl+-";           k = ,@($VK.Ctrl, $VK.Minus);               e = "" }
        @{ n = "Ctrl+``";          k = ,@($VK.Ctrl, $VK.Backtick);            e = "" }
        @{ n = "Ctrl+=";           k = ,@($VK.Ctrl, $VK.Equal);               e = "" }
    ) },
    # 경계 ① — 앱이 kitty 를 켜면 예전 그대로 나가야 한다. 삼키면 nvim · helix · zellij 가 깨진다.
    @{ mode = "kitty"; enable = "[char]27+'[>1u'"; keys = @(
        @{ n = "Ctrl+[";       k = ,@($VK.Ctrl, $VK.LBracket);        e = "1b 5b 39 31 3b 35 75" }        # CSI 91;5u
        @{ n = "Ctrl+I";       k = ,@($VK.Ctrl, $VK.I);               e = "1b 5b 31 30 35 3b 35 75" }     # CSI 105;5u
        @{ n = "Ctrl+M";       k = ,@($VK.Ctrl, $VK.M);               e = "1b 5b 31 30 39 3b 35 75" }     # CSI 109;5u
        @{ n = "Ctrl+Shift+G"; k = ,@($VK.Ctrl, $VK.Shift, $VK.G);    e = "1b 5b 31 30 33 3b 36 75" }     # CSI 103;6u
        @{ n = "Ctrl+A";       k = ,@($VK.Ctrl, $VK.A);               e = "1b 5b 39 37 3b 35 75" }        # CSI 97;5u — 01 이 아니다
        @{ n = "Shift+Tab";    k = ,@($VK.Shift, $VK.Tab);            e = "1b 5b 39 3b 32 75" }           # #653 — kitty 는 CSI 9;2u (legacy 의 ESC[Z 와 다르다)
        @{ n = "Backspace";    k = ,@($VK.Back);                      e = "7f" }
        @{ n = "Ctrl+Enter";   k = ,@($VK.Ctrl, $VK.Enter);          e = "1b 5b 31 33 3b 35 75" }        # #653 — CSI 13;5u
    ) },
    # 경계 ② — modifyOtherKeys=2. Windows 는 mac · Linux 와 갈린다 (머리 주석).
    @{ mode = "mok2"; enable = "[char]27+'[>4;2m'"; keys = @(
        # `Ctrl+[` · `Ctrl+I` · `Ctrl+Shift+G` 의 mok2 기대값은 **공용 표**에 있다 (#684) —
        # 세 OS 가 같아야 하는 칸이라 값을 한 곳에만 둔다. 아래 `Ctrl+A` 처럼 C0 가 나오는
        # 칸만 여기 남긴다.
        @{ n = "Ctrl+A";       k = ,@($VK.Ctrl, $VK.A);               e = "01" }
        @{ n = "Shift+Tab";    k = ,@($VK.Shift, $VK.Tab);            e = "1b 5b 32 37 3b 32 3b 39 7e" }  # #653 — mok2 는 CSI 27;2;9~
        @{ n = "Ctrl+Enter";   k = ,@($VK.Ctrl, $VK.Enter);          e = "1b 5b 32 37 3b 35 3b 31 33 7e" }  # #653 — 켠 앱에는 그대로
    ) },
    # 경계 ③ — **비US 배열** (#684). 창 스레드만 프랑스어 (레거시 AZERTY) 로 바꿔 두 가지를 본다.
    # 기대값은 `VkKeyScanExW(<글자>, hklFR)` 로 **재기 전에** 뽑았다 (2026-10-01):
    #   `a` vk 0x41 sc 0x10 수식키 없음 · `q` vk 0x51 sc 0x1E 없음 · `EUR` vk 0x45 sc 0x12 Ctrl+Alt
    @{ mode = "layout"; enable = ""; klid = "0000040C"; keys = @(
        # ① 라벨 기준이 유지되는가 — `Ctrl`+글자가 인코더로 가게 바뀐 뒤에도 그 layout 의 라벨
        #    글자로 C0 가 나와야 한다. 자리가 US 와 **뒤바뀐** 두 키를 함께 본다.
        @{ n = "Ctrl+a (AZERTY)"; k = ,@($VK.Ctrl, 0x41); e = "01" }   # US 의 Q 자리
        @{ n = "Ctrl+q (AZERTY)"; k = ,@($VK.Ctrl, 0x51); e = "11" }   # US 의 A 자리
        # ② AltGr 이 보존되는가 — Windows 의 AltGr 은 `Ctrl+Alt` 로 도착한다. 인코더로 보내면
        #    ESC-prefix 경로로 가 `ESC <글자>` 가 되므로 `window.zig` 가 Alt 를 제외한다. 그 제외가
        #    실제로 듣는지 재는 칸이다 — 깨지면 `1b` 로 시작하는 바이트가 온다.
        #
        #    **글자 키를 쓴다 — 숫자는 안 된다.** `AltGr+2` 로 쟀더니 0 바이트였는데, 그것은
        #    `Alt+2` 가 `switch_tab2` 기본 바인딩이라 앱이 먼저 가져간 것이었다 (`Ctrl+Shift+F` 와
        #    같은 부류의 도구 실수 — 2026-10-01). `Alt+<글자>` 에는 기본 바인딩이 없다.
        @{ n = "AltGr+e (EUR)";   k = ,@(0xA2, 0xA5, 0x45); e = "e2 82 ac" } # VK_LCONTROL · VK_RMENU · VK_E
    ) },
    # 경계 ④ — **dead key 대기 중의 `Ctrl` 조합** (#684). US-International (`'` 가 dead key) 로
    # 창을 바꾸고 세 키를 이어서 친다. 재는 것은 `Ctrl+A` 의 바이트만이 아니라 **그다음 글자가
    # 살아 있는가** 다 — 그 상태에서 `swallow_next_wm_char` 를 세웠는데 짝꿍 `WM_CHAR` 가 기대대로
    # 오지 않으면 다음 글자가 통째로 사라진다 (#602 2 회차에서 `é` 가 그렇게 없어졌다).
    # 그래서 `window.zig` 가 dead key 대기 중에는 인코더로 보내지 않는다. 마지막 `x` 칸이 그 증거다.
    @{ mode = "deadkey"; enable = ""; klid = "00020409"; keys = @(
        @{ n = "' (dead key)";   k = ,@(0xDE);            e = "" }    # VK_OEM_7 — 아직 글자가 없다
        @{ n = "Ctrl+A (대기중)"; k = ,@($VK.Ctrl, 0x41); e = "01" }
        # dead key 는 `Ctrl` 조합에 **취소되지 않고 보류된 채 살아남는다** — 그래서 다음 글자는
        # `'` 와 합쳐진 `27 78` 이다 (`x` 는 accent 를 못 받는 글자라 두 글자로 풀린다).
        # `deadkey-check_windows.ps1` 의 `' x` 케이스가 같은 값을 검증된 기대값으로 갖고 있다.
        # **삼킴 사고가 나면 `78` 이 통째로 빠진다** — 그것이 이 칸의 판정 대상이다.
        @{ n = "x (다음 글자)";   k = ,@(0x58);            e = "27 78" }
    ) }
)

# #684 — 세 OS 공용 표 (`key-bytes-cases.tsv`) 의 행을 각 모드 회차에 더한다. 키 이름은
# `vkbd_linux.py` · `input_macos.m` 표기라 여기서 VK 로 바꾼다. 이 파일에 같은 이름의 행이 이미
# 있으면 이 파일 것을 쓴다 (`Ctrl+A` · `Ctrl+;` 등).
$KeyVK = @{ ctrl = 0x11; shift = 0x10; slash = 0xBF; space = 0x20; minus = 0xBD; semicolon = 0xBA
            bracketleft = 0xDB }   # evdev · macOS 표기와 같은 이름을 쓴다 (`VK_OEM_4`)
foreach ($ch in [char[]]'abcdefghijklmnopqrstuvwxyz') { $KeyVK["$ch"] = [int][char]::ToUpper($ch) }
foreach ($d in 0..9) { $KeyVK["$d"] = 0x30 + $d }
$Cases = Join-Path $PSScriptRoot "key-bytes-cases.tsv"
if (-not (Test-Path $Cases)) { throw "key-bytes-cases.tsv 없음: $Cases" }
foreach ($line in (Get-Content -Encoding UTF8 $Cases)) {
    if ($line -match '^\s*(#|$)') { continue }
    $f = $line -split "`t"
    if ($f.Count -ne 4) { throw "열이 넷이 아니다: $line" }
    $round = $rounds | Where-Object { $_.mode -eq $f[0] }
    if (-not $round) { throw "모르는 모드: $($f[0])" }
    if ($round.keys | Where-Object { $_.n -eq $f[1] }) { continue }
    [int[]]$vks = @(foreach ($part in ($f[3] -split '\+')) {
        if (-not $KeyVK.ContainsKey($part)) { throw "모르는 키: $part ($($f[3]))" }
        $KeyVK[$part]
    })
    # `,$vks` — 원소 하나짜리 배열로 감싼다 (위 행들의 `,@(…)` 와 같은 모양 · 머리 주석의 함정).
    $round.keys += @{ n = $f[1]; k = ,$vks; e = $(if ($f[2] -eq "-") { "" } else { $f[2] }) }
}

# 받은 파일의 hex 줄 전부. python 이 쓰는 중에 읽으므로 공유 모드로 연다.
function Read-HexLines([string]$Path) {
    if (-not (Test-Path $Path)) { return ,@() }
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try { $text = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    # `key-bytes.py` 는 `<hex …>  <repr>` 로 한 줄씩 찍는다 — hex 부분만 뽑는다.
    $hex = @($text -split "`r?`n" | ForEach-Object { if ($_ -match '^((?:[0-9a-f]{2} )*[0-9a-f]{2})\s') { $matches[1] } })
    return ,$hex
}

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

    # 비US 배열 회차 — 창 스레드만 전환한다. 전환이 확인되지 않으면 키를 **한 개도** 보내지 않는다
    # (US 기준으로 쳐서 거짓 통과하는 것을 막는다). 올린 layout 은 끝에 내린다.
    $hkl = [IntPtr]::Zero
    $loaded = $false
    if ($r.klid) {
        $before_list = [TzKeyBytes]::LayoutCount()
        $hkl = [TzKeyBytes]::LoadKeyboardLayoutW($r.klid, 0)
        if ($hkl -eq [IntPtr]::Zero) { "❌ LoadKeyboardLayoutW($($r.klid)) 실패"; $allOk = $false; Stop-Tz; continue }
        $loaded = [TzKeyBytes]::LayoutCount() -gt $before_list
        [TzKeyBytes]::RequestLayout($h, $hkl)
        $sw2 = [Diagnostics.Stopwatch]::StartNew()
        while ([TzKeyBytes]::LayoutOfWindow($h) -ne $hkl -and $sw2.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 100 }
        $got = [TzKeyBytes]::LayoutOfWindow($h)
        "  layout $($r.klid) → hkl 0x$('{0:X}' -f [int64]$hkl) · 창 0x$('{0:X}' -f [int64]$got) (이번에 올림: $loaded)"
        if ($got -ne $hkl) {
            "❌ 창 layout 이 안 바뀌었다 — 키를 보내지 않는다"
            $allOk = $false
            if ($loaded) { [void][TzKeyBytes]::UnloadKeyboardLayout($hkl) }
            Stop-Tz; continue
        }
    }

    # #684 — **키마다** 그 뒤에 새로 생긴 줄만 읽어 판정한다. 예전에는 다 친 뒤 받은 줄을 기대값에
    # 순서대로 맞췄는데, 그러면 한 키가 예상과 달리 0 바이트일 때 뒤가 전부 한 칸씩 밀려서 수정 전
    # 판의 결과를 읽을 수 없었다 (`Ctrl+/` 가 정확히 그렇다).
    try {
        if (-not [TzKeyBytes]::Focus($h)) { throw "포커스 못 잡음 — 키를 보내지 않는다" }
        foreach ($c in $r.keys) {
            if ([TzKeyBytes]::GetForegroundWindow() -ne $h) { throw "포커스 잃음 ($($c.n))" }
            $chord = $c.k[0]      # `,@(…)` 의 한 겹을 벗긴다
            $before = (Read-HexLines $result).Count
            $sent = [TzKeyBytes]::Chord([uint16[]]$chord, $hkl)
            if ($sent -ne $chord.Count * 2) { throw "SendInput 거부: $sent (기대 $($chord.Count * 2))" }
            Start-Sleep -Milliseconds 700
            # 변수에 먼저 받는다 — 함수가 `,` 로 감싸 돌려주므로 바로 파이프하면 배열이 **한 덩어리**로
            # 넘어가 `-Skip` 이 통째로 건너뛴다.
            $now = Read-HexLines $result
            $g = ($now | Select-Object -Skip $before) -join ' '
            $ok = $g -eq $c.e
            "{0} {1,-16} 기대 [{2}]  받음 [{3}]" -f $(if ($ok) { "OK  " } else { "FAIL" }), $c.n,
                $(if ($c.e) { $c.e } else { "(없음)" }), $(if ($g) { $g } else { "(없음)" })
            if (-not $ok) { $allOk = $false }
        }
        Start-Sleep -Milliseconds 500
        [TzKeyBytes]::Shot($h, $shot)
    } catch { "❌ $_"; $allOk = $false } finally {
        Stop-Tz
        # 올린 layout 을 내린다 — 남기면 `Win+Space` 전환 목록에 나타나 사용자의 입력 전환을
        # 바꾼다 (#496 함정 ②). 원래 세션에 있던 것이면 두고, 전후 개수를 찍어 보인다.
        if ($loaded) {
            $u = [TzKeyBytes]::UnloadKeyboardLayout($hkl)
            "  layout 내림: $u · 세션 목록 $([TzKeyBytes]::LayoutCount()) 개"
        }
    }

    if (-not (Test-Path $result)) { "❌ 결과 파일 없음: $result"; $allOk = $false; continue }
    "  수신 원본: $result · 캡처: $shot"
}
if ($allOk) { "결과: 전부 OK" } else { "결과: 실패 있음" }
