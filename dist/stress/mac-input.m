// macOS 합성 입력 — `measure-input-latency.sh` 가 쓰는 CGEvent 전송 도구 (#441 축 ②).
//
//   clang -O2 -Wno-deprecated-declarations \
//         -framework ApplicationServices -framework Carbon -o /tmp/mac-input mac-input.m
//
//   /tmp/mac-input check                    # 손쉬운 사용 권한이 있나
//   /tmp/mac-input focus <pid>              # 그 pid 의 창을 클릭해 key window 로
//   /tmp/mac-input send a --repeat 30 --gap 200
//   /tmp/mac-input send shift+cmd+f12
//   /tmp/mac-input ime-get                  # 지금 입력 소스 ID
//   /tmp/mac-input ime-ascii                # 영문(ASCII 가능) 소스로
//   /tmp/mac-input ime-set com.apple.inputmethod.Korean.2SetKorean
//
// ## 왜 `cliclick` 을 안 쓰나
//
// [#387](https://github.com/ensky0/tildaz/issues/387#issuecomment-5188395490) 이 macOS 에서 쓴
// 도구가 `cliclick` 이고 그건 지금도 유효하다 (`osascript keystroke` 는 Accessory mode 때문에
// 새어 나간다). 다만 그때 보낸 것은 **단축키 하나**였고, 여기서 필요한 것은 **문자 키**다.
//
//   - `cliclick` 의 `kp` 는 특수키만 받는다 (`f1`~`f16` · 화살표 · `space` …). 문자는
//     `t:a` 뿐인데 그건 `CGEventKeyboardSetUnicodeString` 방식이라 IME 를 지나는 길이
//     실기와 달라질 수 있다 (*추정 — 확인 안 함*).
//   - 권한이 없을 때 오류 없이 exit 0 이라 **키가 안 나간 회차를 그대로 끝낸다.**
//
// ## 권한 — 이 도구가 존재하는 진짜 이유
//
// CGEvent 로 키를 보내려면 **보내는 쪽**에 손쉬운 사용 (Accessibility) 권한이 있어야 하고,
// 없으면 `CGEventPost` 는 **성공을 반환하면서 아무 일도 하지 않는다.** Linux 에서 `ydotoold`
// 미기동으로 키가 하나도 안 나간 채 회차가 끝난 그 함정과 같은 종류다.
//
// 그래서 `AXIsProcessTrusted()` 를 **키를 보내는 이 프로세스 안에서** 부른다. TCC 는 터미널이
// 띄운 자식의 권한을 부모 (터미널 앱) 기준으로 평가하므로 (AGENTS.md 의 macOS `open` 절),
// 판정과 전송이 같은 프로세스여야 답이 맞는다.
#include <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum {
    EXIT_NO_PERMISSION = 2,
    EXIT_NO_WINDOW = 3,
    EXIT_USAGE = 4,
    EXIT_IME = 5,
};

// macOS 의 가상 키코드는 물리 배치 순서라 알파벳 순이 아니다 (`a` = 0, `s` = 1 …).
// `<Carbon/HIToolbox/Events.h>` 의 `kVK_*` 와 같은 값이며, 여기서 이름을 붙여 둔다.
static const struct {
    const char *name;
    CGKeyCode code;
} kKeys[] = {
    {"a", 0},    {"s", 1},    {"d", 2},     {"f", 3},     {"h", 4},     {"g", 5},
    {"z", 6},    {"x", 7},    {"c", 8},     {"v", 9},     {"b", 11},    {"q", 12},
    {"w", 13},   {"e", 14},   {"r", 15},    {"y", 16},    {"t", 17},    {"o", 31},
    {"u", 32},   {"i", 34},   {"p", 35},    {"l", 37},    {"j", 38},    {"k", 40},
    {"n", 45},   {"m", 46},
    {"1", 18},   {"2", 19},   {"3", 20},    {"4", 21},    {"6", 22},    {"5", 23},
    {"9", 25},   {"7", 26},   {"8", 28},    {"0", 29},
    {"return", 36}, {"tab", 48}, {"space", 49}, {"delete", 51}, {"esc", 53},
    {"f1", 122}, {"f2", 120}, {"f3", 99},   {"f4", 118},  {"f5", 96},   {"f6", 97},
    {"f7", 98},  {"f8", 100}, {"f9", 101},  {"f10", 109}, {"f11", 103}, {"f12", 111},
};

static int lookupKey(const char *name, CGKeyCode *out) {
    for (size_t i = 0; i < sizeof(kKeys) / sizeof(kKeys[0]); i++) {
        if (strcmp(kKeys[i].name, name) == 0) {
            *out = kKeys[i].code;
            return 1;
        }
    }
    return 0;
}

/// `shift+cmd+f12` 처럼 `+` 로 이어 붙인 조합을 keyCode + flags 로 가른다.
static int parseSpec(const char *spec, CGKeyCode *code, CGEventFlags *flags) {
    char buf[128];
    if (strlen(spec) >= sizeof(buf)) return 0;
    strcpy(buf, spec);

    *flags = 0;
    char *cursor = buf;
    for (;;) {
        char *plus = strchr(cursor, '+');
        if (plus == NULL) break;
        *plus = '\0';
        if (strcmp(cursor, "cmd") == 0) *flags |= kCGEventFlagMaskCommand;
        else if (strcmp(cursor, "shift") == 0) *flags |= kCGEventFlagMaskShift;
        else if (strcmp(cursor, "ctrl") == 0) *flags |= kCGEventFlagMaskControl;
        else if (strcmp(cursor, "alt") == 0 || strcmp(cursor, "opt") == 0) *flags |= kCGEventFlagMaskAlternate;
        else return 0;
        cursor = plus + 1;
    }
    return lookupKey(cursor, code);
}

/// 모디파이어는 실제 키를 누르지 않고 `CGEventSetFlags` 로만 준다. 우리 앱이 보는 것이
/// `[event modifierFlags]` 라서 (`host/macos.zig` 의 `tildazKeyDown`) 이걸로 충분하다.
///
/// **flags 는 0 이어도 반드시 설정한다.** 처음에는 `flags != 0` 일 때만 불렀는데, 그러면
/// 새 이벤트가 **직전 조합키의 modifier 를 물려받는다.** Cmd 가 남은 채 `a` 가 나가면 앱은
/// 그걸 `Cmd+A` 로 보고 `macCmdShortcut` 이 인식 못 해 **그냥 return** 한다 — 화면도 안
/// 바뀌고 PTY 로도 안 간다. 그런데 `markInput()` 은 `tildazKeyDown` 첫 줄이라 표본은 그대로
/// 세어져서, **"표본은 다 찼는데 아무것도 안 찍힌"** 회차가 된다 (실측으로 겪었다).
///
/// 소스도 `kCGEventSourceStatePrivate` 로 만들어 시스템의 실제 키보드 상태를 물려받지
/// 않게 한다. 두 겹으로 막는 이유는 이 실패가 **조용해서** — 값이 그럴듯하게 나온다.
static void postKey(CGKeyCode code, CGEventFlags flags) {
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStatePrivate);
    CGEventRef down = CGEventCreateKeyboardEvent(src, code, true);
    CGEventRef up = CGEventCreateKeyboardEvent(src, code, false);
    CGEventSetFlags(down, flags);
    CGEventSetFlags(up, flags);
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down);
    CFRelease(up);
    if (src != NULL) CFRelease(src);
}

static void warnNoPermission(void) {
    fprintf(stderr,
            "손쉬운 사용 (Accessibility) 권한이 없어요 — CGEvent 로 보낸 키가 조용히 사라져요.\n"
            "  시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 에서\n"
            "  **이 스크립트를 실행한 터미널 앱**을 켜 주세요 (권한은 자식이 아니라 부모에 붙어요).\n"
            "  이미 켜져 있는데도 이 메시지가 나오면 토글을 껐다 켜세요 (서명이 바뀌면 stale 해져요).\n");
}

static int requireTrusted(void) {
    if (AXIsProcessTrusted()) return 1;
    warnNoPermission();
    return 0;
}

/// 합성 입력은 **포커스된 창**으로 간다. Accessory mode 앱이라 `osascript` 로는 활성화가
/// 안 새어 나가고 (#387), 창 본문을 클릭하는 것이 실측으로 통한 방법이다. 여기서는 그
/// 클릭까지 CGEvent 로 해서 사람 개입을 없앤다.
static int focusWindowOfPid(pid_t pid) {
    CFArrayRef windows = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (windows == NULL) {
        fprintf(stderr, "창 목록을 못 읽었어요.\n");
        return EXIT_NO_WINDOW;
    }

    CGRect best = CGRectZero;
    int found = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(windows); i++) {
        CFDictionaryRef info = CFArrayGetValueAtIndex(windows, i);
        CFNumberRef owner = CFDictionaryGetValue(info, kCGWindowOwnerPID);
        CFDictionaryRef bounds_dict = CFDictionaryGetValue(info, kCGWindowBounds);
        if (owner == NULL || bounds_dict == NULL) continue;

        int owner_pid = 0;
        CFNumberGetValue(owner, kCFNumberIntType, &owner_pid);
        if (owner_pid != (int)pid) continue;

        // **`kCGWindowLayer` 로 거르면 안 된다.** drop-down 터미널이라 우리 창은
        // `NSPopUpMenuWindowLevel` (101) 로 뜨고 (`host/macos.zig` 의 `setPopupWindowLevel`),
        // 다른 앱이 활성이면 normal (0) 로 내려간다 (#195). 즉 layer 가 **두 값을 오간다.**
        // 처음에 `layer == 0` 만 봤다가 창을 못 찾았다 (실측). pid 로 이미 좁혔으니
        // 층은 보지 않고, 같은 pid 의 보조 창 (다이얼로그 · IME 패널) 은 아래 넓이 비교로 밀어낸다.
        CGRect rect;
        if (!CGRectMakeWithDictionaryRepresentation(bounds_dict, &rect)) continue;
        // 한 프로세스가 창을 여럿 들 수 있다 (다이얼로그 등). 가장 큰 것이 본체다.
        if (rect.size.width * rect.size.height > best.size.width * best.size.height) {
            best = rect;
            found = 1;
        }
    }
    CFRelease(windows);

    if (!found) {
        fprintf(stderr, "pid %d 의 창을 못 찾았어요 (아직 안 떴거나 이미 닫혔어요).\n", (int)pid);
        return EXIT_NO_WINDOW;
    }

    // 창 중앙 — 탭바 (위쪽) 와 스크롤바 (오른쪽) 를 피한다. 터미널 본문이라 클릭해도
    // 같은 자리에서 떼면 빈 selection 이라 화면이 바뀌지 않는다.
    CGPoint target = CGPointMake(CGRectGetMidX(best), CGRectGetMidY(best));

    // 사용자의 포인터를 빼앗지 않도록 원래 자리를 기억해 둔다.
    CGEventRef probe = CGEventCreate(NULL);
    CGPoint origin = (probe != NULL) ? CGEventGetLocation(probe) : target;
    if (probe != NULL) CFRelease(probe);

    // `CGWarpMouseCursorPosition` 만으로는 이동 이벤트가 없어 hover · 클릭이 안 걸린다
    // (AGENTS.md 의 macOS 색 실측 절과 같은 함정). 이동 → 누름 → 뗌을 모두 보낸다.
    CGEventRef move = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, target, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, move);
    CFRelease(move);
    usleep(50 * 1000);

    CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, target, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, down);
    CFRelease(down);
    usleep(30 * 1000);

    CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, target, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(up);
    usleep(50 * 1000);

    // 포인터를 되돌린다. 창 밖으로 나가므로 탭바 hover 도 함께 풀린다.
    CGWarpMouseCursorPosition(origin);
    return 0;
}

/// 주 화면의 주사율. **응답 시간 측정에서 이 값이 결론을 바꾼다** — 프레임 주기가 곧
/// 응답 지연의 하한이라, 120 Hz 와 60 Hz 를 나란히 두려면 함께 적어야 한다 (AGENTS.md 의
/// `# 실행 환경`). `system_profiler` 에는 안 나오고 `hygiene.sh` 도 셸만으로는 못 읽어서
/// 여기서 `CGDisplayModeGetRefreshRate` 로 낸다.
///
/// 창이 뜬 화면이 아니라 **주 화면** 기준이다. 우리 창은 drop-down 이라 주 화면에 뜨지만,
/// 외장 모니터를 함께 쓰는 환경에서는 사람이 확인한다.
static int printRefresh(void) {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(CGMainDisplayID());
    if (mode == NULL) {
        fprintf(stderr, "화면 모드를 못 읽었어요.\n");
        return EXIT_IME;
    }
    double hz = CGDisplayModeGetRefreshRate(mode);
    CGDisplayModeRelease(mode);
    // 일부 화면은 0 을 낸다. 그때는 물음표를 그대로 내보내 **모르는 것을 아는 척하지 않는다.**
    if (hz <= 0.0) {
        printf("?\n");
        return 0;
    }
    printf("%.0fHz\n", hz);
    return 0;
}

static int imeGet(void) {
    TISInputSourceRef current = TISCopyCurrentKeyboardInputSource();
    if (current == NULL) {
        fprintf(stderr, "현재 입력 소스를 못 읽었어요.\n");
        return EXIT_IME;
    }
    CFStringRef source_id = TISGetInputSourceProperty(current, kTISPropertyInputSourceID);
    if (source_id == NULL) {
        CFRelease(current);
        fprintf(stderr, "입력 소스 ID 가 없어요.\n");
        return EXIT_IME;
    }
    char buf[256];
    if (!CFStringGetCString(source_id, buf, sizeof(buf), kCFStringEncodingUTF8)) {
        CFRelease(current);
        fprintf(stderr, "입력 소스 ID 를 못 옮겼어요.\n");
        return EXIT_IME;
    }
    printf("%s\n", buf);
    CFRelease(current);
    return 0;
}

/// 영문 (ASCII 를 낼 수 있는) 소스로 바꾼다. 한글 모드면 `a` 가 조합에 먹혀서
/// PTY 왕복이 아니라 preedit 만 재게 된다.
static int imeAscii(void) {
    TISInputSourceRef ascii = TISCopyCurrentASCIICapableKeyboardInputSource();
    if (ascii == NULL) {
        fprintf(stderr, "ASCII 입력 소스를 못 찾았어요.\n");
        return EXIT_IME;
    }
    OSStatus status = TISSelectInputSource(ascii);
    CFRelease(ascii);
    if (status != noErr) {
        fprintf(stderr, "영문 입력 소스로 못 바꿨어요 (OSStatus %d).\n", (int)status);
        return EXIT_IME;
    }
    return 0;
}

static int imeSet(const char *wanted) {
    CFStringRef wanted_cf = CFStringCreateWithCString(NULL, wanted, kCFStringEncodingUTF8);
    if (wanted_cf == NULL) return EXIT_IME;

    const void *keys[] = {kTISPropertyInputSourceID};
    const void *values[] = {wanted_cf};
    CFDictionaryRef filter = CFDictionaryCreate(NULL, keys, values, 1,
                                                &kCFTypeDictionaryKeyCallBacks,
                                                &kCFTypeDictionaryValueCallBacks);
    // `includeAllInstalled = false` — 켜 둔 소스만 본다. 안 켠 소스는 선택해도 안 먹는다.
    CFArrayRef list = TISCreateInputSourceList(filter, false);
    CFRelease(filter);
    CFRelease(wanted_cf);

    if (list == NULL || CFArrayGetCount(list) == 0) {
        if (list != NULL) CFRelease(list);
        fprintf(stderr, "입력 소스를 못 찾았어요: %s\n", wanted);
        return EXIT_IME;
    }
    TISInputSourceRef source = (TISInputSourceRef)CFArrayGetValueAtIndex(list, 0);
    OSStatus status = TISSelectInputSource(source);
    CFRelease(list);
    if (status != noErr) {
        fprintf(stderr, "입력 소스를 못 바꿨어요: %s (OSStatus %d)\n", wanted, (int)status);
        return EXIT_IME;
    }
    return 0;
}

static void usage(void) {
    fprintf(stderr,
            "쓰는 법: mac-input <명령>\n"
            "\n"
            "  check                       손쉬운 사용 권한이 있나 (없으면 exit 2)\n"
            "  focus <pid>                 그 pid 의 창을 클릭해 key window 로\n"
            "  send <키>... [옵션]         키를 보낸다\n"
            "  refresh                     주 화면 주사율 (측정 기록용)\n"
            "  ime-get                     지금 입력 소스 ID\n"
            "  ime-ascii                   영문 (ASCII 가능) 소스로\n"
            "  ime-set <id>                그 ID 로\n"
            "\n"
            "  send 옵션: --repeat <N> (키 열을 N 번) · --gap <ms> (키 사이 간격, 기본 200)\n"
            "  키 표기: a · ctrl+c · shift+cmd+f12 · cmd+q\n");
}

int main(int argc, const char **argv) {
    if (argc < 2) {
        usage();
        return EXIT_USAGE;
    }
    const char *cmd = argv[1];

    if (strcmp(cmd, "check") == 0) {
        return requireTrusted() ? 0 : EXIT_NO_PERMISSION;
    }

    if (strcmp(cmd, "focus") == 0) {
        if (argc != 3) { usage(); return EXIT_USAGE; }
        if (!requireTrusted()) return EXIT_NO_PERMISSION;
        return focusWindowOfPid((pid_t)atoi(argv[2]));
    }

    if (strcmp(cmd, "refresh") == 0) return printRefresh();
    if (strcmp(cmd, "ime-get") == 0) return imeGet();
    if (strcmp(cmd, "ime-ascii") == 0) return imeAscii();
    if (strcmp(cmd, "ime-set") == 0) {
        if (argc != 3) { usage(); return EXIT_USAGE; }
        return imeSet(argv[2]);
    }

    if (strcmp(cmd, "send") != 0) {
        usage();
        return EXIT_USAGE;
    }

    // **권한 판정을 보내기 전에** 한다. 이게 없으면 회차를 다 돌고 나서야 표본 0 으로 안다.
    if (!requireTrusted()) return EXIT_NO_PERMISSION;

    const char *specs[64];
    int spec_count = 0;
    long repeat = 1;
    long gap_ms = 200;

    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--repeat") == 0 && i + 1 < argc) {
            repeat = strtol(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--gap") == 0 && i + 1 < argc) {
            gap_ms = strtol(argv[++i], NULL, 10);
        } else {
            if (spec_count == (int)(sizeof(specs) / sizeof(specs[0]))) {
                fprintf(stderr, "키가 너무 많아요.\n");
                return EXIT_USAGE;
            }
            specs[spec_count++] = argv[i];
        }
    }
    if (spec_count == 0 || repeat < 1 || gap_ms < 0) {
        usage();
        return EXIT_USAGE;
    }

    // 보내기 전에 전부 파싱한다 — 열 한가운데서 오타로 멈추면 앱이 어중간한 상태로 남는다.
    CGKeyCode codes[64];
    CGEventFlags flags[64];
    for (int i = 0; i < spec_count; i++) {
        if (!parseSpec(specs[i], &codes[i], &flags[i])) {
            fprintf(stderr, "모르는 키: %s\n", specs[i]);
            return EXIT_USAGE;
        }
    }

    for (long r = 0; r < repeat; r++) {
        for (int i = 0; i < spec_count; i++) {
            postKey(codes[i], flags[i]);
            if (gap_ms > 0) usleep((useconds_t)gap_ms * 1000);
        }
    }
    return 0;
}
