//! 셸이 첫 OSC 0/2 제목을 보내는 시점 실측 도구 ([#364](https://github.com/ensky0/tildaz/issues/364)).
//!
//! **Windows 전용이다 (ConPTY)**. Linux 는 POSIX PTY 라 별도 도구를 쓴다 —
//! `dist/linux/osc-title-probe.zig`. 출력 형식은 두 platform 결과를 같은 표로
//! 합칠 수 있게 Linux 판과 맞춰 두었다.
//!
//! 왜 필요한가: `src/session_core.zig` 의 `INITIAL_TITLE_GRACE_NS` (1 초) 를 줄여도
//! 되는지는 **셸이 실제로 언제 OSC 를 보내는지**에 달려 있다. 이 도구는 tildaz 가
//! 자식 셸을 띄우는 조건을 그대로 복제해서 그 시점을 µs 해상도로 측정한다.
//!
//! tildaz 와 같게 맞춘 것 (`src/terminal/windows/pty.zig` 의 `ConPty.init`):
//!   - 번들 `_internal\conpty.dll` 의 `ConptyCreatePseudoConsole` (kernel32 fallback
//!     없음, #339). `--system-conpty` 로 시스템 conhost 경로와 비교할 수 있다.
//!   - pipe 4 개 — input 은 익명 (우리 write / conhost read), output 은 named pipe
//!     (conhost sync write / 우리 overlapped read)
//!   - `CreatePseudoConsole` flags `0x8` (GLYPH_WIDTH_GRAPHEMES) → 실패 시 `0x0` 재시도
//!   - `ConptyShowHidePseudoConsole(hpc, TRUE)` 를 `CreateProcessW` 앞에
//!   - `CreateProcessW` = `EXTENDED_STARTUPINFO_PRESENT` +
//!     `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` (0x00020016) + `STARTF_USESTDHANDLES`
//!     + NULL std handle (빼면 셸이 비대화형으로 판단해 즉시 종료, #338)
//!   - **DA1 pre-response** — 프로세스 생성 직후 input pipe 에 `\x1b[?61c`. 없으면
//!     OpenConsole 의 `WaitUntilDA1(3000)` 이 3 초를 다 기다려 측정값이 통째로
//!     밀린다. `--no-da1` 로 그 차이를 직접 확인할 수 있다.
//!   - 시작 디렉토리 = `%USERPROFILE%` (#265). `wsl` / `wsl.exe` 는 명령줄에
//!     ` --cd ~` 를 끼워 넣는다 (tildaz 의 `wslCdInsertion` 과 같은 규칙).
//!   - 환경변수는 `COLORFGBG` 와 `WSLENV` 만 (`host/windows.zig` 의 `buildExtraEnv`).
//!     `TERM` / locale 은 ConPTY 와 셸 기본에 위임한다.
//!   - **터미널 질의에 응답하지 않는다.** Windows tildaz 는 readonly VT stream 을
//!     유지하므로 (#266 / #269) 자식 질의의 수신자가 우리가 아니다. 응답하면 실제
//!     앱보다 빠른 값이 나온다. 대신 어떤 질의가 언제 왔는지는 전부 기록한다.
//!
//! 빌드 / 실행 (본체 빌드에는 들어가지 않고 `zig build probe-check`가 호환만 확인):
//! ```powershell
//! zig build-exe dist/windows/osc-title-probe.zig -O ReleaseSafe -lc --cache-dir C:/ziglang/tildaz-cache
//! .\osc-title-probe.exe --shell "cmd.exe" --runs 10 --verbose
//! .\osc-title-probe.exe --shell "powershell.exe -NoProfile" --runs 10
//! .\osc-title-probe.exe --shell "wsl.exe" --runs 10          # ` --cd ~` 자동 삽입
//! .\osc-title-probe.exe --shell "cmd.exe" --runs 3 --no-da1  # DA1 pre-response 효과 확인
//! ```
//!
//! 인자: `--shell CMDLINE` `--runs N` `--window-ms N` `--label TEXT`
//! `--conpty PATH` (conpty.dll 직접 지정) `--system-conpty` (kernel32 경로)
//! `--no-da1` (DA1 pre-response 생략) `--verbose` (run 별 timeline)
//! `--dump` (첫 run 의 raw 스트림을 escape 해서 출력 — 파서 검증용).

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .windows) {
        @compileError("osc-title-probe 는 Windows 전용 (ConPTY). Linux 는 dist/linux/osc-title-probe.zig 를 쓴다.");
    }
}

const windows = std.os.windows;
const HANDLE = windows.HANDLE;
const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const BYTE = windows.BYTE;
const LPVOID = windows.LPVOID;
// Zig 0.16은 `std.os.windows.HRESULT`를 제거했다. Win32의 HRESULT는 LONG이다.
const HRESULT = c_long;
const WCHAR = u16;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// dark 배경 (기본 테마) → `COLORFGBG=15;0`. `themes.isDark` 가 판정하는 값과 같다.
const colorfgbg = "15;0";

/// Zig 0.16에서 제거된 `std.time.Timer`의 자리. tildaz의 `runtime.Timer`와 같이
/// 절전 시간을 세지 않는 `.awake` 단조 시계로 경과 시간을 잰다.
const Timer = struct {
    io: std.Io,
    start_ns: i96,

    fn start(io: std.Io) Timer {
        return .{ .io = io, .start_ns = std.Io.Timestamp.now(io, .awake).nanoseconds };
    }

    fn read(self: Timer) u64 {
        const now = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        return @intCast(@max(0, now - self.start_ns));
    }
};

// ── Win32 선언 — `src/terminal/windows/pty.zig` 와 같은 집합 ────────────────

const COORD = extern struct { x: i16, y: i16 };

const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?[*:0]WCHAR,
    lpDesktop: ?[*:0]WCHAR,
    lpTitle: ?[*:0]WCHAR,
    dwX: DWORD,
    dwY: DWORD,
    dwXSize: DWORD,
    dwYSize: DWORD,
    dwXCountChars: DWORD,
    dwYCountChars: DWORD,
    dwFillAttribute: DWORD,
    dwFlags: DWORD,
    wShowWindow: u16,
    cbReserved2: u16,
    lpReserved2: ?*BYTE,
    hStdInput: ?HANDLE,
    hStdOutput: ?HANDLE,
    hStdError: ?HANDLE,
};

const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW,
    lpAttributeList: ?LPPROC_THREAD_ATTRIBUTE_LIST,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: DWORD = 0,
    OffsetHigh: DWORD = 0,
    hEvent: ?HANDLE = null,
};

const LPPROC_THREAD_ATTRIBUTE_LIST = *anyopaque;
const HPCON = *anyopaque;

const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
const STARTF_USESTDHANDLES: DWORD = 0x00000100;
const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const PIPE_ACCESS_INBOUND: DWORD = 0x00000001;
const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
const PIPE_TYPE_BYTE: DWORD = 0x00000000;
const PIPE_WAIT: DWORD = 0x00000000;
const GENERIC_WRITE: DWORD = 0x40000000;
const OPEN_EXISTING: DWORD = 3;
const WAIT_OBJECT_0: DWORD = 0;
const ERROR_IO_PENDING: DWORD = 997;
const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;
const READ_BUF_SIZE: usize = 128 * 1024;

extern "kernel32" fn CreatePipe(*HANDLE, *HANDLE, ?*const anyopaque, DWORD) callconv(.c) BOOL;
extern "kernel32" fn CreateNamedPipeW([*:0]const WCHAR, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, ?*const anyopaque) callconv(.c) HANDLE;
extern "kernel32" fn CreateFileW([*:0]const WCHAR, DWORD, DWORD, ?*const anyopaque, DWORD, DWORD, ?HANDLE) callconv(.c) HANDLE;
extern "kernel32" fn CreateEventW(?*anyopaque, BOOL, BOOL, ?[*:0]const WCHAR) callconv(.c) ?HANDLE;
extern "kernel32" fn ResetEvent(HANDLE) callconv(.c) BOOL;
extern "kernel32" fn CloseHandle(HANDLE) callconv(.c) BOOL;
extern "kernel32" fn CancelIo(HANDLE) callconv(.c) BOOL;
extern "kernel32" fn ReadFile(HANDLE, [*]BYTE, DWORD, ?*DWORD, ?*OVERLAPPED) callconv(.c) BOOL;
extern "kernel32" fn WriteFile(HANDLE, [*]const BYTE, DWORD, ?*DWORD, ?*OVERLAPPED) callconv(.c) BOOL;
extern "kernel32" fn GetOverlappedResult(HANDLE, *OVERLAPPED, *DWORD, BOOL) callconv(.c) BOOL;
extern "kernel32" fn WaitForSingleObject(HANDLE, DWORD) callconv(.c) DWORD;
extern "kernel32" fn TerminateProcess(HANDLE, c_uint) callconv(.c) BOOL;
extern "kernel32" fn GetLastError() callconv(.c) DWORD;
extern "kernel32" fn GetCurrentProcessId() callconv(.c) DWORD;
extern "kernel32" fn LoadLibraryW([*:0]const WCHAR) callconv(.c) ?*anyopaque;
extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.c) ?*const anyopaque;
extern "kernel32" fn GetModuleFileNameW(?*anyopaque, [*]WCHAR, DWORD) callconv(.c) DWORD;
extern "kernel32" fn GetFileAttributesW([*:0]const WCHAR) callconv(.c) DWORD;
extern "kernel32" fn SetEnvironmentVariableW([*:0]const WCHAR, ?[*:0]const WCHAR) callconv(.c) BOOL;
extern "kernel32" fn GetEnvironmentVariableW([*:0]const WCHAR, ?[*]WCHAR, DWORD) callconv(.c) DWORD;
extern "kernel32" fn InitializeProcThreadAttributeList(?LPPROC_THREAD_ATTRIBUTE_LIST, DWORD, DWORD, *usize) callconv(.c) BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(LPPROC_THREAD_ATTRIBUTE_LIST, DWORD, usize, ?*anyopaque, usize, ?*anyopaque, ?*usize) callconv(.c) BOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(LPPROC_THREAD_ATTRIBUTE_LIST) callconv(.c) void;
extern "kernel32" fn CreateProcessW(
    ?[*:0]const WCHAR,
    ?[*:0]WCHAR,
    ?*const anyopaque,
    ?*const anyopaque,
    BOOL,
    DWORD,
    ?LPVOID,
    ?[*:0]const WCHAR,
    *STARTUPINFOEXW,
    *PROCESS_INFORMATION,
) callconv(.c) BOOL;

const ConptyCreateFn = *const fn (COORD, HANDLE, HANDLE, DWORD, *HPCON) callconv(.c) HRESULT;
const ConptyCloseFn = *const fn (HPCON) callconv(.c) void;
const ConptyShowHideFn = *const fn (HPCON, BOOL) callconv(.c) HRESULT;

// ── 이벤트 기록 — Linux 판과 같은 shape ────────────────────────────────────

const Kind = enum {
    title, // OSC 0 / 2 (ghostty getTitle() 에 반영되는 것)
    icon, // OSC 1 (제목 아님 — 참고용)
    answered, // 질의에 응답했다 — Windows 에서는 발생하지 않는다 (readonly VT, #269)
    ignored, // 터미널 질의인데 응답하지 않는다
};

const Event = struct {
    t_ns: u64 = 0,
    kind: Kind = .title,
    text: [160]u8 = undefined,
    text_len: usize = 0,

    fn str(self: *const Event) []const u8 {
        return self.text[0..self.text_len];
    }
};

const Recorder = struct {
    events: [768]Event = undefined,
    count: usize = 0,
    dropped: usize = 0,
    timer: Timer = undefined,
    total_bytes: usize = 0,
    /// 화면에 실제로 찍히는 첫 문자의 시각. Windows 의 「첫 출력 byte」는
    /// conhost 자신의 preamble (`CSI 1t` / DA1 질의 / `?1004h`) 이라 셸이 언제
    /// 프롬프트를 내놓는지와 무관하다. Linux 판의 「첫 출력」(셸의 첫 byte) 과
    /// 견주려면 이 값을 봐야 한다.
    first_text_ns: ?u64 = null,

    fn add(self: *Recorder, kind: Kind, text: []const u8) void {
        if (self.count >= self.events.len) {
            self.dropped += 1;
            return;
        }
        const e = &self.events[self.count];
        e.* = .{ .t_ns = self.timer.read(), .kind = kind };
        e.text_len = @min(text.len, e.text.len);
        @memcpy(e.text[0..e.text_len], text[0..e.text_len]);
        self.count += 1;
    }
};

// ── 파서 — OSC / CSI / DCS 만 구분한다. 화면 내용은 관심 없다. ───────────────
//
// Linux 판과 같은 상태 기계다. 다른 점은 응답을 보내지 않는다는 것뿐 — 질의는
// 전부 `.ignored` 로 기록한다 (Windows tildaz 의 readonly VT stream, #266 / #269).

const Parser = struct {
    const State = enum { ground, esc, csi, str };
    const StrKind = enum { osc, dcs, other };

    state: State = .ground,
    str_kind: StrKind = .osc,
    in_esc: bool = false,
    buf: [512]u8 = undefined,
    len: usize = 0,

    fn push(self: *Parser, b: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = b;
            self.len += 1;
        }
    }

    fn feed(self: *Parser, rec: *Recorder, data: []const u8) void {
        for (data) |b| self.byte(rec, b);
    }

    fn byte(self: *Parser, rec: *Recorder, b: u8) void {
        switch (self.state) {
            .ground => if (b == 0x1b) {
                self.state = .esc;
            } else if (b >= 0x20 and b != 0x7f and rec.first_text_ns == null) {
                rec.first_text_ns = rec.timer.read();
            },
            .esc => {
                self.len = 0;
                self.in_esc = false;
                switch (b) {
                    ']' => {
                        self.state = .str;
                        self.str_kind = .osc;
                    },
                    '[' => self.state = .csi,
                    'P' => {
                        self.state = .str;
                        self.str_kind = .dcs;
                    },
                    '_', '^', 'X' => {
                        self.state = .str;
                        self.str_kind = .other;
                    },
                    0x1b => self.state = .esc,
                    else => self.state = .ground,
                }
            },
            .csi => {
                if (b >= 0x40 and b <= 0x7e) {
                    self.push(b);
                    self.dispatchCsi(rec);
                    self.state = .ground;
                    self.len = 0;
                } else self.push(b);
            },
            .str => {
                if (self.in_esc) {
                    self.in_esc = false;
                    if (b == '\\') { // ST
                        self.dispatchStr(rec);
                        self.state = .ground;
                        self.len = 0;
                        return;
                    }
                    self.push(0x1b);
                    self.push(b);
                    return;
                }
                if (b == 0x1b) {
                    self.in_esc = true;
                    return;
                }
                if (b == 0x07 and self.str_kind == .osc) { // BEL
                    self.dispatchStr(rec);
                    self.state = .ground;
                    self.len = 0;
                    return;
                }
                self.push(b);
            },
        }
    }

    fn dispatchStr(self: *Parser, rec: *Recorder) void {
        const s = self.buf[0..self.len];
        switch (self.str_kind) {
            .osc => self.dispatchOsc(rec, s),
            .dcs => {
                // XTGETTCAP (`DCS + q <hex> ST`) 등 — 응답하지 않고 기록만 한다.
                // 무응답 대기로 시점이 밀리면 timeline 에 그대로 드러난다.
                var line: [180]u8 = undefined;
                const n = render(&line, "DCS ", s);
                rec.add(.ignored, line[0..n]);
            },
            .other => {},
        }
    }

    fn dispatchOsc(self: *Parser, rec: *Recorder, s: []const u8) void {
        _ = self;
        const semi = std.mem.indexOfScalar(u8, s, ';');
        const code_str = if (semi) |i| s[0..i] else s;
        const payload = if (semi) |i| s[i + 1 ..] else "";
        const code = std.fmt.parseInt(u32, code_str, 10) catch return;

        switch (code) {
            0, 2 => {
                var line: [180]u8 = undefined;
                const n = (std.fmt.bufPrint(&line, "OSC {d} title=\"{s}\"", .{ code, payload }) catch @as([]u8, line[0..0])).len;
                rec.add(.title, line[0..n]);
            },
            1 => {
                var line: [180]u8 = undefined;
                const n = (std.fmt.bufPrint(&line, "OSC 1 icon=\"{s}\"", .{payload}) catch @as([]u8, line[0..0])).len;
                rec.add(.icon, line[0..n]);
            },
            // 색 질의 — Windows tildaz 는 응답하지 않는다 (#269). 기록만.
            10, 11, 12 => {
                if (std.mem.eql(u8, payload, "?")) {
                    var line: [180]u8 = undefined;
                    const n = (std.fmt.bufPrint(&line, "OSC {d} color query (무응답)", .{code}) catch @as([]u8, line[0..0])).len;
                    rec.add(.ignored, line[0..n]);
                }
            },
            4 => {
                if (std.mem.endsWith(u8, payload, "?")) {
                    const idx_end = std.mem.indexOfScalar(u8, payload, ';') orelse return;
                    var line: [180]u8 = undefined;
                    const n = (std.fmt.bufPrint(&line, "OSC 4;{s} palette query (무응답)", .{payload[0..idx_end]}) catch @as([]u8, line[0..0])).len;
                    rec.add(.ignored, line[0..n]);
                }
            },
            else => {}, // OSC 7 (cwd) / 8 (hyperlink) / 9 / 133 (prompt mark) 등 — 제목 무관
        }
    }

    fn dispatchCsi(self: *Parser, rec: *Recorder) void {
        const s = self.buf[0..self.len];
        if (s.len == 0) return;
        const final = s[s.len - 1];
        var body = s[0 .. s.len - 1];

        var private: u8 = 0;
        if (body.len > 0 and (body[0] == '?' or body[0] == '>' or body[0] == '=' or body[0] == '<')) {
            private = body[0];
            body = body[1..];
        }
        var intermediate: u8 = 0;
        if (body.len > 0 and (body[body.len - 1] == '$' or body[body.len - 1] == ' ' or body[body.len - 1] == '!')) {
            intermediate = body[body.len - 1];
            body = body[0 .. body.len - 1];
        }

        var line: [180]u8 = undefined;
        const is_query = switch (final) {
            'c' => true, // DA1 / DA2 / DA3
            'n' => true, // DSR
            'u' => private == '?', // kitty keyboard 질의
            'q' => private == '>', // XTVERSION
            'p' => private == '?' and intermediate == '$', // DECRQM
            't', 'S' => true, // XTWINOPS / XTSMGRAPHICS
            else => false,
        };
        if (!is_query) return;
        const n = render(&line, "CSI ", s);
        rec.add(.ignored, line[0..n]);
    }
};

/// 제어 시퀀스를 읽을 수 있는 문자열로. ESC 는 `\xNN`, 나머지 비출력 문자도 같게.
fn render(out: []u8, prefix: []const u8, s: []const u8) usize {
    var n: usize = 0;
    for (prefix) |c| {
        if (n < out.len) {
            out[n] = c;
            n += 1;
        }
    }
    for (s) |c| {
        if (c >= 0x20 and c < 0x7f) {
            if (n < out.len) {
                out[n] = c;
                n += 1;
            }
        } else {
            const hex = std.fmt.bufPrint(out[n..], "\\x{x:0>2}", .{c}) catch break;
            n += hex.len;
        }
    }
    return n;
}

// ── ConPTY 런타임 로드 — tildaz 와 같은 쪽 (번들 _internal\conpty.dll) ────────

var conpty_create_fn: ?ConptyCreateFn = null;
var conpty_close_fn: ?ConptyCloseFn = null;
var conpty_show_hide_fn: ?ConptyShowHideFn = null;
var conpty_source_buf: [512]u8 = undefined;
var conpty_source_len: usize = 0;

fn conptySource() []const u8 {
    return conpty_source_buf[0..conpty_source_len];
}

fn setSource(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&conpty_source_buf, fmt, args) catch @as([]u8, conpty_source_buf[0..0]);
    conpty_source_len = s.len;
}

/// exe 가 있는 디렉토리의 경로 prefix 길이 (마지막 구분자 포함).
fn exeDirLen(buf: *[512]WCHAR) ?usize {
    const n = GetModuleFileNameW(null, buf, buf.len);
    if (n == 0 or n >= buf.len) return null;
    var dir_end: usize = n;
    while (dir_end > 0) : (dir_end -= 1) {
        if (buf[dir_end - 1] == '\\' or buf[dir_end - 1] == '/') break;
    }
    return dir_end;
}

fn appendSuffix(buf: *[512]WCHAR, dir_end: usize, comptime suffix: []const u8) ?[:0]const WCHAR {
    const s = L(suffix);
    if (dir_end + s.len + 1 > buf.len) return null;
    @memcpy(buf[dir_end..][0..s.len], s);
    buf[dir_end + s.len] = 0;
    return buf[0 .. dir_end + s.len :0];
}

fn bindConptyModule(mod: *anyopaque, bundled: bool) bool {
    if (bundled) {
        conpty_create_fn = @ptrCast(@alignCast(GetProcAddress(mod, "ConptyCreatePseudoConsole")));
        conpty_close_fn = @ptrCast(@alignCast(GetProcAddress(mod, "ConptyClosePseudoConsole")));
        conpty_show_hide_fn = @ptrCast(@alignCast(GetProcAddress(mod, "ConptyShowHidePseudoConsole")));
    } else {
        conpty_create_fn = @ptrCast(@alignCast(GetProcAddress(mod, "CreatePseudoConsole")));
        conpty_close_fn = @ptrCast(@alignCast(GetProcAddress(mod, "ClosePseudoConsole")));
        conpty_show_hide_fn = null; // 시스템 conhost 에는 없다
    }
    return conpty_create_fn != null and conpty_close_fn != null;
}

fn utf16PathToUtf8(out: []u8, path: []const WCHAR) []const u8 {
    const n = std.unicode.utf16LeToUtf8(out, path) catch return "(경로 변환 실패)";
    return out[0..n];
}

/// tildaz 와 같은 쪽 — exe 옆 `_internal\conpty.dll`. probe 는 저장소에서 바로
/// 빌드하므로 `zig-out\bin\_internal\` 과 `vendor\conpty\<arch>\` 도 순서대로 본다.
fn loadConpty(explicit: ?[]const u8, use_system: bool) !void {
    if (use_system) {
        const mod = LoadLibraryW(L("kernel32.dll")) orelse return error.ConptyLoadFailed;
        if (!bindConptyModule(mod, false)) return error.ConptySymbolsMissing;
        setSource("시스템 conhost (kernel32.dll CreatePseudoConsole)", .{});
        return;
    }

    var path_buf: [512]WCHAR = undefined;
    var utf8_buf: [512]u8 = undefined;

    if (explicit) |p| {
        const n = std.unicode.utf8ToUtf16Le(&path_buf, p) catch return error.ConptyLoadFailed;
        if (n + 1 > path_buf.len) return error.ConptyLoadFailed;
        path_buf[n] = 0;
        const z: [:0]const WCHAR = path_buf[0..n :0];
        const mod = LoadLibraryW(z.ptr) orelse return error.ConptyLoadFailed;
        if (!bindConptyModule(mod, true)) return error.ConptySymbolsMissing;
        setSource("번들 conpty.dll — {s} (--conpty 지정)", .{utf16PathToUtf8(&utf8_buf, z)});
        return;
    }

    const dir_end = exeDirLen(&path_buf) orelse return error.ConptyLoadFailed;
    const arch_dir = if (builtin.cpu.arch == .aarch64)
        "vendor\\conpty\\arm64\\conpty.dll"
    else
        "vendor\\conpty\\x64\\conpty.dll";
    inline for (.{
        "_internal\\conpty.dll",
        "zig-out\\bin\\_internal\\conpty.dll",
        arch_dir,
    }) |suffix| {
        if (appendSuffix(&path_buf, dir_end, suffix)) |z| {
            if (GetFileAttributesW(z.ptr) != INVALID_FILE_ATTRIBUTES) {
                if (LoadLibraryW(z.ptr)) |mod| {
                    if (bindConptyModule(mod, true)) {
                        setSource("번들 conpty.dll — {s}", .{utf16PathToUtf8(&utf8_buf, z)});
                        return;
                    }
                }
            }
        }
    }
    return error.ConptyLoadFailed;
}

// ── #265 — WSL 셸이면 명령줄에 ` --cd ~` 삽입 (pty.zig 의 wslCdInsertion 과 동일) ──

fn wslCdInsertion(cmd: []const WCHAR) struct { is_wsl: bool, insert: bool, insert_at: usize } {
    if (cmd.len == 0) return .{ .is_wsl = false, .insert = false, .insert_at = 0 };

    const quoted = cmd[0] == '"';
    const tok_start: usize = if (quoted) 1 else 0;
    var tok_end = tok_start;
    while (tok_end < cmd.len) : (tok_end += 1) {
        const ch = cmd[tok_end];
        if (quoted) {
            if (ch == '"') break;
        } else if (ch == ' ') break;
    }

    var base_start = tok_start;
    for (cmd[tok_start..tok_end], tok_start..) |ch, i| {
        if (ch == '\\' or ch == '/') base_start = i + 1;
    }
    const basename = cmd[base_start..tok_end];
    const is_wsl = std.mem.eql(WCHAR, basename, L("wsl")) or
        std.mem.eql(WCHAR, basename, L("wsl.exe"));

    const insert_at = if (quoted and tok_end < cmd.len) tok_end + 1 else tok_end;
    if (!is_wsl) return .{ .is_wsl = false, .insert = false, .insert_at = insert_at };

    const args = cmd[@min(insert_at, cmd.len)..];
    if (std.mem.indexOf(WCHAR, args, L("--cd")) != null)
        return .{ .is_wsl = true, .insert = false, .insert_at = insert_at };
    if (std.mem.indexOfScalar(WCHAR, args, '~')) |ti| {
        if (ti + 1 == args.len or args[ti + 1] == ' ')
            return .{ .is_wsl = true, .insert = false, .insert_at = insert_at };
    }
    return .{ .is_wsl = true, .insert = true, .insert_at = insert_at };
}

// ── ConPTY spawn — tildaz 의 `ConPty.init` 과 같은 순서 ──────────────────────

const Spawn = struct {
    hpc: HPCON,
    pipe_in_write: HANDLE,
    pipe_out_read: HANDLE,
    read_event: HANDLE,
    pi: PROCESS_INFORMATION,
    attr_list_buf: []u8,

    fn deinit(self: *Spawn, alloc: std.mem.Allocator) void {
        // 측정이 끝난 뒤라 순서가 시점에 영향을 주지 않는다. orphan 을 확실히
        // 막으려고 자식을 먼저 끝내고 pseudo console 을 닫는다.
        _ = TerminateProcess(self.pi.hProcess, 0);
        _ = WaitForSingleObject(self.pi.hProcess, 3000);
        conpty_close_fn.?(self.hpc);
        _ = CloseHandle(self.pipe_in_write);
        _ = CloseHandle(self.pipe_out_read);
        _ = CloseHandle(self.read_event);
        _ = CloseHandle(self.pi.hProcess);
        _ = CloseHandle(self.pi.hThread);
        DeleteProcThreadAttributeList(@ptrCast(self.attr_list_buf.ptr));
        alloc.free(self.attr_list_buf);
    }
};

/// 자식에 넘길 환경변수 — `host/windows.zig` 의 `buildExtraEnv` 와 같은 2 개.
/// tildaz 와 같은 방식으로 부모 환경을 잠시 바꿔서 상속시키고 곧바로 되돌린다.
const ExtraEnv = struct {
    const max = 2;
    names: [max][:0]const WCHAR = undefined,
    values: [max][:0]const WCHAR = undefined,
    count: usize = 0,
    saved: [max]?[]WCHAR = .{null} ** max,
    wslenv_storage: [1024]WCHAR = undefined,

    fn build(self: *ExtraEnv) void {
        self.names[0] = L("COLORFGBG");
        self.values[0] = L(colorfgbg);

        // WSLENV — 부모값이 있으면 `:` 로 잇고 `COLORFGBG` 를 추가한다.
        var pos: usize = 0;
        const existing = GetEnvironmentVariableW(L("WSLENV"), &self.wslenv_storage, self.wslenv_storage.len);
        if (existing > 0 and existing < self.wslenv_storage.len) {
            pos = existing;
            if (pos + 1 < self.wslenv_storage.len) {
                self.wslenv_storage[pos] = ':';
                pos += 1;
            }
        }
        const suffix = L("COLORFGBG");
        if (pos + suffix.len + 1 <= self.wslenv_storage.len) {
            @memcpy(self.wslenv_storage[pos..][0..suffix.len], suffix);
            pos += suffix.len;
        }
        self.wslenv_storage[pos] = 0;
        self.names[1] = L("WSLENV");
        self.values[1] = self.wslenv_storage[0..pos :0];
        self.count = 2;
    }

    fn apply(self: *ExtraEnv, alloc: std.mem.Allocator) !void {
        for (0..self.count) |i| {
            const needed = GetEnvironmentVariableW(self.names[i].ptr, null, 0);
            if (needed > 0) {
                const buf = try alloc.alloc(WCHAR, needed);
                const copied = GetEnvironmentVariableW(self.names[i].ptr, buf.ptr, needed);
                if (copied >= needed) return error.GetEnvironmentVariableFailed;
                buf[copied] = 0;
                self.saved[i] = buf;
            }
            _ = SetEnvironmentVariableW(self.names[i].ptr, self.values[i].ptr);
        }
    }

    fn restore(self: *ExtraEnv, alloc: std.mem.Allocator) void {
        for (0..self.count) |i| {
            if (self.saved[i]) |buf| {
                _ = SetEnvironmentVariableW(self.names[i].ptr, @ptrCast(buf.ptr));
                alloc.free(buf);
                self.saved[i] = null;
            } else {
                _ = SetEnvironmentVariableW(self.names[i].ptr, null);
            }
        }
    }

    /// 보고용 — 실제로 넘긴 값 두 개를 utf-8 한 줄로.
    fn describe(self: *ExtraEnv, out: []u8) []const u8 {
        var tmp: [1024]u8 = undefined;
        const wslenv = std.unicode.utf16LeToUtf8(&tmp, self.values[1]) catch 0;
        const s = std.fmt.bufPrint(out, "COLORFGBG={s} WSLENV={s}", .{ colorfgbg, tmp[0..wslenv] }) catch @as([]u8, out[0..0]);
        return s;
    }
};

fn spawnShell(alloc: std.mem.Allocator, shell: []const u8, cols: u16, rows: u16, da1: bool) !Spawn {
    // ── Input pipe (익명, sync): 우리 = write, conhost = read
    var pipe_in_read: HANDLE = undefined;
    var pipe_in_write: HANDLE = undefined;
    if (!CreatePipe(&pipe_in_read, &pipe_in_write, null, 0).toBool()) return error.CreatePipeFailed;
    errdefer _ = CloseHandle(pipe_in_write);

    // ── Output pipe (named, 우리 쪽만 overlapped)
    const S = struct {
        var counter: u32 = 0;
    };
    const seq = @atomicRmw(u32, &S.counter, .Add, 1, .monotonic);
    var pipe_name_u8: [128]u8 = undefined;
    const pipe_name_str = std.fmt.bufPrint(&pipe_name_u8, "\\\\.\\pipe\\tildaz_probe_{d}_{d}", .{ GetCurrentProcessId(), seq }) catch
        return error.CreatePipeFailed;
    var pipe_name: [128]WCHAR = undefined;
    const pipe_name_n = std.unicode.utf8ToUtf16Le(&pipe_name, pipe_name_str) catch return error.CreatePipeFailed;
    pipe_name[pipe_name_n] = 0;
    const pipe_name_z: [:0]const WCHAR = pipe_name[0..pipe_name_n :0];

    const pipe_out_read = CreateNamedPipeW(
        pipe_name_z.ptr,
        PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED,
        PIPE_TYPE_BYTE | PIPE_WAIT,
        1,
        READ_BUF_SIZE,
        READ_BUF_SIZE,
        0,
        null,
    );
    if (pipe_out_read == INVALID_HANDLE_VALUE) {
        _ = CloseHandle(pipe_in_read);
        return error.CreatePipeFailed;
    }
    errdefer _ = CloseHandle(pipe_out_read);

    const pipe_out_write = CreateFileW(pipe_name_z.ptr, GENERIC_WRITE, 0, null, OPEN_EXISTING, 0, null);
    if (pipe_out_write == INVALID_HANDLE_VALUE) {
        _ = CloseHandle(pipe_in_read);
        return error.CreatePipeFailed;
    }

    const read_event = CreateEventW(null, .TRUE, .FALSE, null) orelse {
        _ = CloseHandle(pipe_in_read);
        _ = CloseHandle(pipe_out_write);
        return error.CreateEventFailed;
    };
    errdefer _ = CloseHandle(read_event);

    // ── Pseudo console. flags 0x8 = PSEUDOCONSOLE_GLYPH_WIDTH_GRAPHEMES (Win11).
    const create_fn = conpty_create_fn orelse return error.ConptyRuntimeUnavailable;
    const size = COORD{ .x = @intCast(cols), .y = @intCast(rows) };
    var hpc: HPCON = undefined;
    var hr: HRESULT = create_fn(size, pipe_in_read, pipe_out_write, 0x8, &hpc);
    if (hr < 0) hr = create_fn(size, pipe_in_read, pipe_out_write, 0, &hpc);

    _ = CloseHandle(pipe_in_read);
    _ = CloseHandle(pipe_out_write);
    if (hr < 0) return error.CreatePseudoConsoleFailed;
    errdefer conpty_close_fn.?(hpc);

    // Windows Terminal 의 ConptyConnection::Start() 와 같은 순서 — CreateProcessW 앞.
    if (conpty_show_hide_fn) |f| _ = f(hpc, .TRUE);

    // ── STARTUPINFOEX + attribute list
    var attr_list_size: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_list_size);
    const attr_list_buf = try alloc.alloc(u8, attr_list_size);
    errdefer alloc.free(attr_list_buf);
    const attr_list: LPPROC_THREAD_ATTRIBUTE_LIST = @ptrCast(attr_list_buf.ptr);
    if (!InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_list_size).toBool()) return error.InitializeAttributeListFailed;
    if (!UpdateProcThreadAttribute(attr_list, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, @sizeOf(HPCON), null, null).toBool()) {
        return error.UpdateProcThreadAttributeFailed;
    }

    var startup_info = std.mem.zeroes(STARTUPINFOEXW);
    startup_info.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
    startup_info.lpAttributeList = attr_list;
    // NULL std handle + STARTF_USESTDHANDLES — 빼면 셸이 부모의 리다이렉트된
    // stdio 를 물려받아 비대화형으로 판단하고 즉시 종료한다 (#338).
    startup_info.StartupInfo.dwFlags = STARTF_USESTDHANDLES;

    // ── 명령줄 (+ WSL 이면 ` --cd ~`)
    const shell_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, shell);
    defer alloc.free(shell_w);
    const wsl_cd = wslCdInsertion(shell_w);
    const insert: []const WCHAR = if (wsl_cd.insert) L(" --cd ~") else &.{};
    const cmd_len = shell_w.len + insert.len;
    const cmd_buf = try alloc.alloc(WCHAR, cmd_len + 1);
    defer alloc.free(cmd_buf);
    @memcpy(cmd_buf[0..wsl_cd.insert_at], shell_w[0..wsl_cd.insert_at]);
    @memcpy(cmd_buf[wsl_cd.insert_at..][0..insert.len], insert);
    @memcpy(cmd_buf[wsl_cd.insert_at + insert.len ..][0 .. shell_w.len - wsl_cd.insert_at], shell_w[wsl_cd.insert_at..]);
    cmd_buf[cmd_len] = 0;

    // ── 시작 디렉토리 = %USERPROFILE% (WSL 은 ` --cd ~` 가 담당)
    var home_buf: ?[]WCHAR = null;
    defer if (home_buf) |b| alloc.free(b);
    if (!wsl_cd.is_wsl) {
        const needed = GetEnvironmentVariableW(L("USERPROFILE"), null, 0);
        if (needed > 0) {
            const buf = try alloc.alloc(WCHAR, needed);
            const copied = GetEnvironmentVariableW(L("USERPROFILE"), buf.ptr, needed);
            if (copied > 0 and copied < needed) {
                buf[copied] = 0;
                home_buf = buf;
            } else alloc.free(buf);
        }
    }
    const cwd: ?[*:0]const WCHAR = if (home_buf) |b| @ptrCast(b.ptr) else null;

    var env = ExtraEnv{};
    env.build();
    try env.apply(alloc);

    var pi: PROCESS_INFORMATION = undefined;
    const ok = CreateProcessW(
        null,
        @ptrCast(cmd_buf[0..cmd_len :0].ptr),
        null,
        null,
        .FALSE,
        EXTENDED_STARTUPINFO_PRESENT,
        null,
        cwd,
        &startup_info,
        &pi,
    );
    env.restore(alloc);
    if (!ok.toBool()) return error.CreateProcessFailed;

    // ── DA1 pre-response — OpenConsole 의 WaitUntilDA1(3000) 을 즉시 풀어 준다.
    // 빼면 첫 프롬프트가 ~3.9 초 늦어 측정값이 통째로 밀린다 (pty.zig 주석).
    if (da1) {
        const resp = "\x1b[?61c";
        var written: DWORD = 0;
        _ = WriteFile(pipe_in_write, resp.ptr, @intCast(resp.len), &written, null);
    }

    return .{
        .hpc = hpc,
        .pipe_in_write = pipe_in_write,
        .pipe_out_read = pipe_out_read,
        .read_event = read_event,
        .pi = pi,
        .attr_list_buf = attr_list_buf,
    };
}

// ── 한 번의 측정 ──────────────────────────────────────────────────────────

const RunResult = struct {
    /// 첫 출력 byte 시각 — 사용자가 프롬프트를 보기 시작하는 시점의 대용값.
    /// 제목만 늦는 건지 (= 빈 제목이 눈에 띈다) 셸 자체가 늦는 건지 구분한다.
    first_byte_ns: ?u64 = null,
    /// 화면에 찍히는 첫 문자 (conhost preamble 제외) — Windows 전용 열.
    first_text_ns: ?u64 = null,
    first_title_ns: ?u64 = null,
    first_nonempty_ns: ?u64 = null,
    last_title_ns: ?u64 = null,
    titles: usize = 0,
    distinct_titles: usize = 0,
    queries: usize = 0,
    ignored_queries: usize = 0,
    bytes: usize = 0,
};

fn runOnce(
    io: std.Io,
    alloc: std.mem.Allocator,
    shell: []const u8,
    cols: u16,
    rows: u16,
    window_ms: u64,
    da1: bool,
    verbose: bool,
    dump: bool,
) !RunResult {
    var sp = try spawnShell(alloc, shell, cols, rows, da1);
    // 시각 0 — tildaz 는 backend.init (ConPTY + CreateProcessW) 직후 title_clock 을
    // 시작한다 (session_core.zig 의 Tab.init).
    var rec = Recorder{ .timer = .start(io) };
    var parser = Parser{};

    var buf: [8192]u8 = undefined;
    var first_byte_ns: ?u64 = null;
    while (true) {
        const elapsed_ms = rec.timer.read() / std.time.ns_per_ms;
        if (elapsed_ms >= window_ms) break;
        const remaining: DWORD = @intCast(window_ms - elapsed_ms);

        _ = ResetEvent(sp.read_event);
        var ov = OVERLAPPED{ .hEvent = sp.read_event };
        var n: DWORD = 0;
        if (!ReadFile(sp.pipe_out_read, &buf, buf.len, &n, &ov).toBool()) {
            if (GetLastError() != ERROR_IO_PENDING) break;
            if (WaitForSingleObject(sp.read_event, remaining) != WAIT_OBJECT_0) {
                _ = CancelIo(sp.pipe_out_read);
                var discarded: DWORD = 0;
                _ = GetOverlappedResult(sp.pipe_out_read, &ov, &discarded, .TRUE);
                break; // 관측 창 종료
            }
            if (!GetOverlappedResult(sp.pipe_out_read, &ov, &n, .FALSE).toBool()) break;
        }
        if (n == 0) break; // pipe 종료 — 셸 종료
        if (first_byte_ns == null) first_byte_ns = rec.timer.read();
        rec.total_bytes += n;
        if (dump) {
            // 파서가 스트림을 통째로 놓치고 있지 않은지 눈으로 확인하는 용도.
            var esc: [4096]u8 = undefined;
            const written = render(&esc, "", buf[0..@min(n, 1024)]);
            std.debug.print("    <raw {d:>8.3} ms, {d} bytes> {s}\n", .{
                @as(f64, @floatFromInt(rec.timer.read())) / @as(f64, std.time.ns_per_ms),
                n,
                esc[0..written],
            });
        }
        parser.feed(&rec, buf[0..n]);
    }

    sp.deinit(alloc);

    // 결과 집계
    var result = RunResult{
        .bytes = rec.total_bytes,
        .first_byte_ns = first_byte_ns,
        .first_text_ns = rec.first_text_ns,
    };
    var last_title: [160]u8 = undefined;
    var last_title_len: usize = 0;
    for (rec.events[0..rec.count]) |e| {
        switch (e.kind) {
            .title => {
                const payload = titlePayload(e.str());
                result.titles += 1;
                if (result.first_title_ns == null) result.first_title_ns = e.t_ns;
                if (payload.len > 0 and result.first_nonempty_ns == null) result.first_nonempty_ns = e.t_ns;
                if (payload.len > 0) result.last_title_ns = e.t_ns;
                if (!std.mem.eql(u8, last_title[0..last_title_len], payload)) {
                    result.distinct_titles += 1;
                    last_title_len = @min(payload.len, last_title.len);
                    @memcpy(last_title[0..last_title_len], payload[0..last_title_len]);
                }
            },
            .icon => {},
            .answered => result.queries += 1,
            .ignored => {
                result.queries += 1;
                result.ignored_queries += 1;
            },
        }
    }

    if (verbose) {
        for (rec.events[0..rec.count]) |e| {
            const tag = switch (e.kind) {
                .title => "TITLE  ",
                .icon => "icon   ",
                .answered => "query-> ",
                .ignored => "query x ",
            };
            std.debug.print("    [{d:>8.3} ms] {s} {s}\n", .{
                @as(f64, @floatFromInt(e.t_ns)) / @as(f64, std.time.ns_per_ms),
                tag,
                e.str(),
            });
        }
        if (rec.dropped > 0) std.debug.print("    (event buffer overflow: {d} dropped)\n", .{rec.dropped});
    }

    return result;
}

/// `OSC 0 title="..."` 형태에서 제목만 뽑는다.
fn titlePayload(line: []const u8) []const u8 {
    const start = std.mem.indexOfScalar(u8, line, '"') orelse return "";
    const end = std.mem.lastIndexOfScalar(u8, line, '"') orelse return "";
    if (end <= start) return "";
    return line[start + 1 .. end];
}

fn median(values: []u64) u64 {
    if (values.len == 0) return 0;
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[values.len / 2];
}

fn ms(v: u64) f64 {
    return @as(f64, @floatFromInt(v)) / @as(f64, std.time.ns_per_ms);
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    var shell: []const u8 = "cmd.exe";
    var runs: usize = 10;
    var window_ms: u64 = 3000;
    var cols: u16 = 120;
    var rows: u16 = 30;
    var verbose = false;
    var dump = false;
    var da1 = true;
    var use_system_conpty = false;
    var conpty_path: ?[]const u8 = null;
    var label: []const u8 = "";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--shell") and i + 1 < args.len) {
            i += 1;
            shell = args[i];
        } else if (std.mem.eql(u8, a, "--runs") and i + 1 < args.len) {
            i += 1;
            runs = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "--window-ms") and i + 1 < args.len) {
            i += 1;
            window_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--cols") and i + 1 < args.len) {
            i += 1;
            cols = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, a, "--rows") and i + 1 < args.len) {
            i += 1;
            rows = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, a, "--label") and i + 1 < args.len) {
            i += 1;
            label = args[i];
        } else if (std.mem.eql(u8, a, "--conpty") and i + 1 < args.len) {
            i += 1;
            conpty_path = args[i];
        } else if (std.mem.eql(u8, a, "--system-conpty")) {
            use_system_conpty = true;
        } else if (std.mem.eql(u8, a, "--no-da1")) {
            da1 = false;
        } else if (std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "--dump")) {
            dump = true;
        } else {
            std.debug.print("알 수 없는 인자: {s}\n", .{a});
            return error.InvalidArgs;
        }
    }

    loadConpty(conpty_path, use_system_conpty) catch |err| {
        std.debug.print(
            "ConPTY 런타임을 로드하지 못했다 ({s}).\n" ++
                "  번들 경로 후보: <exe dir>\\_internal\\conpty.dll, <exe dir>\\zig-out\\bin\\_internal\\conpty.dll, <exe dir>\\vendor\\conpty\\<arch>\\conpty.dll\n" ++
                "  --conpty <path> 로 직접 지정하거나 --system-conpty 로 시스템 conhost 를 쓸 수 있다.\n",
            .{@errorName(err)},
        );
        return err;
    };

    var env_desc_buf: [1024]u8 = undefined;
    var env_desc = ExtraEnv{};
    env_desc.build();

    std.debug.print("== OSC 제목 도착 시각 실측 (#364) ==\n", .{});
    std.debug.print("shell=\"{s}\" runs={d} window={d}ms query_reply=off(Windows readonly VT, #266/#269) {s}\n", .{
        shell, runs, window_ms, label,
    });
    std.debug.print("conpty={s} size={d}x{d} da1_pre={s} env={s}\n\n", .{
        conptySource(),
        cols,
        rows,
        if (da1) "on(\\x1b[?61c)" else "off",
        env_desc.describe(&env_desc_buf),
    });

    const firsts = try alloc.alloc(u64, runs);
    var firsts_len: usize = 0;
    const lasts = try alloc.alloc(u64, runs);
    var lasts_len: usize = 0;
    const bytes_first = try alloc.alloc(u64, runs);
    var bytes_first_len: usize = 0;
    const texts = try alloc.alloc(u64, runs);
    var texts_len: usize = 0;
    var no_title_runs: usize = 0;

    for (0..runs) |run| {
        if (verbose) std.debug.print("  run {d}:\n", .{run + 1});
        const r = try runOnce(init.io, alloc, shell, cols, rows, window_ms, da1, verbose, dump and run == 0);
        if (r.first_nonempty_ns) |t| {
            firsts[firsts_len] = t;
            firsts_len += 1;
            if (r.last_title_ns) |l| {
                lasts[lasts_len] = l;
                lasts_len += 1;
            }
            const fb = r.first_byte_ns orelse 0;
            bytes_first[bytes_first_len] = fb;
            bytes_first_len += 1;
            std.debug.print(
                "  run {d:>2}: 첫 출력 {d:>7.2} ms | 첫 제목 {d:>8.2} ms | 제목 공백 {d:>8.2} ms | 마지막 제목 {d:>8.2} ms | 제목 {d}회(구별 {d}) | 질의 {d}(무응답 {d}) | {d} bytes | 첫 텍스트 {d:>7.2} ms\n",
                .{ run + 1, ms(fb), ms(t), ms(t -| fb), ms(r.last_title_ns orelse t), r.titles, r.distinct_titles, r.queries, r.ignored_queries, r.bytes, ms(r.first_text_ns orelse 0) },
            );
        } else {
            no_title_runs += 1;
            std.debug.print(
                "  run {d:>2}: 제목 없음 ({d}ms 동안 OSC 0/2 미수신) | 첫 출력 {d:>7.2} ms | 질의 {d}(무응답 {d}) | {d} bytes | 첫 텍스트 {d:>7.2} ms\n",
                .{ run + 1, window_ms, ms(r.first_byte_ns orelse 0), r.queries, r.ignored_queries, r.bytes, ms(r.first_text_ns orelse 0) },
            );
        }
        if (r.first_text_ns) |tx| {
            texts[texts_len] = tx;
            texts_len += 1;
        }
    }

    std.debug.print("\n", .{});
    if (texts_len > 0) {
        const tx = texts[0..texts_len];
        var tmin: u64 = std.math.maxInt(u64);
        var tmax: u64 = 0;
        var tsum: u64 = 0;
        for (tx) |v| {
            tmin = @min(tmin, v);
            tmax = @max(tmax, v);
            tsum += v;
        }
        std.debug.print("첫 화면 텍스트 (conhost preamble 제외 = 셸이 실제로 뭔가 찍은 시점):\n", .{});
        std.debug.print("  min {d:.2} ms | median {d:.2} ms | mean {d:.2} ms | max {d:.2} ms  (n={d})\n\n", .{
            ms(tmin), ms(median(tx)), ms(tsum / texts_len), ms(tmax), texts_len,
        });
    }
    if (bytes_first_len == 0 and no_title_runs == runs) {
        std.debug.print("결과: OSC 0/2 제목을 한 번도 보내지 않았다 ({d}/{d} run). → fallback (`Tab N`) 경로.\n", .{ no_title_runs, runs });
        return;
    }

    const f = firsts[0..firsts_len];
    var min_v: u64 = std.math.maxInt(u64);
    var max_v: u64 = 0;
    var sum: u64 = 0;
    for (f) |v| {
        min_v = @min(min_v, v);
        max_v = @max(max_v, v);
        sum += v;
    }
    const med = median(f);

    std.debug.print("첫 non-empty OSC 제목 (프로세스 생성 기준):\n", .{});
    std.debug.print("  min {d:.2} ms | median {d:.2} ms | mean {d:.2} ms | max {d:.2} ms  (n={d})\n", .{
        ms(min_v), ms(med), ms(sum / firsts_len), ms(max_v), firsts_len,
    });
    if (lasts_len > 0) {
        const l = lasts[0..lasts_len];
        var lmax: u64 = 0;
        for (l) |v| lmax = @max(lmax, v);
        std.debug.print("  마지막 제목 갱신 max {d:.2} ms (150ms debounce 안정화 시점 판단용)\n", .{ms(lmax)});
    }
    if (no_title_runs > 0) {
        std.debug.print("  제목 없음: {d}/{d} run\n", .{ no_title_runs, runs });
    }

    std.debug.print("\n유예 후보별 판정 (첫 제목이 유예보다 늦으면 `Tab N` 이 먼저 보이고 교체됨):\n", .{});
    for ([_]u64{ 1000, 500, 300, 250, 200, 150, 100 }) |cand_ms| {
        const cand_ns = cand_ms * std.time.ns_per_ms;
        var late: usize = 0;
        for (f) |v| {
            if (v > cand_ns) late += 1;
        }
        std.debug.print("  {d:>4} ms 유예: 늦은 run {d}/{d} | 여유 (유예 - max) {d:.2} ms\n", .{
            cand_ms, late, firsts_len, @as(f64, @floatFromInt(cand_ms)) - ms(max_v),
        });
    }
}
