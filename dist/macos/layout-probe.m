// layout-probe.m — 활성 키보드 layout 을 조회하는 세 경로를 나란히 재는 진단 도구
// ([#496](https://github.com/ensky0/tildaz/issues/496) 항목 2 의 전제 조사).
//
// ## 왜 필요한가
//
// tildaz 는 macOS 에서 단축키를 `kVK_ANSI_*` (물리 위치) 로 매칭한다. 그래서 AZERTY
// Mac 에서 `Cmd+W` 가 **`Z` 라 인쇄된 키**다 — Safari 의 `Cmd+W` (Cocoa 메뉴
// `keyEquivalent` = 문자 비교) 와 다른 키를 요구한다. 이것을 고치려면 라벨을 *활성
// layout 으로* 해석해야 하고, 그 수단이 세 갈래다.
//
//   경로 A — Carbon 을 링크해 `TIS*` + `UCKeyTranslate` 를 직접 쓴다.
//   경로 B — HIToolbox 를 `dlopen` 해 `TIS*` 심볼만 런타임에 잡는다.
//   경로 C — CoreGraphics 만 쓴다 (`CGEventKeyboardGetUnicodeString`).
//   경로 D — AppKit 만 쓴다 (`NSEvent charactersByApplyingModifiers:`).
//
// A · B 는 SDK 헤더로 되는 것이 확실하다. **미지수는 C 다.** `CGEvent.h` 가
// *"the system translates the virtual key code in a keyboard event into a Unicode
// string based on the keyboard ID in the event source"* 라고만 적어서, 그 keyboard ID
// 가 (1) 활성 layout 을 따라오는지 (2) `CGEventSource` 를 만든 시점에 고정되는지가
// 문서로는 갈리지 않는다. 이 도구는 그 둘을 실기로 가른다.
//
// `UCKeyTranslate` 는 HIToolbox 가 아니라 **CoreServices/CarbonCore** 의
// `UnicodeUtilities.h` 에 있다 (SDK 26.5 확인). Carbon 이 필요한 것은 `TIS*` 계열
// 뿐이다 — 경로 B 가 성립하는 이유다.
//
// ## 무엇을 재는가
//
// keycode 0..127 을 세 방식으로 번역해 한 표로 덤프한다.
//
//   (A)  `TISCopyCurrentKeyboardLayoutInputSource` + `kTISPropertyUnicodeKeyLayoutData`
//        + `UCKeyTranslate(kUCKeyActionDisplay, kUCKeyTranslateNoDeadKeysMask)`  ← 정답지
//   (C1) `CGEventSourceCreate(kCGEventSourceStateHIDSystemState)` 를 **프로그램 시작에
//        한 번만** 만들어 재사용 + `CGEventCreateKeyboardEvent` +
//        `CGEventKeyboardGetUnicodeString`
//   (C2) 같은데 `CGEventSource` 를 **keycode 마다 새로** 생성
//   (D)  `+[NSEvent eventWithCGEvent:]` + `charactersByApplyingModifiers:0` — `UCKeyTranslate`
//        대신 헤더가 권하는 길 (`UnicodeUtilities.h:521`)
//
// C1 과 C2 를 가르는 것이 설계를 정한다 — C1 이 낡은 값을 들고 있고 C2 만 따라오면,
// 우리는 조회할 때마다 `CGEventSource` 를 새로 만들어야 한다.
//
// ## 두 모드
//
//   layout-probe                 단발 — keycode 0..127 전체 표 + 요약 (layout 별 A vs C 판정)
//   layout-probe --watch N M     같은 프로세스로 M 회, N 초 간격 요약 (layout 추적 판정)
//   layout-probe --watch-runloop N M
//                                같은데 대기를 `CFRunLoopRunInMode` 로 한다 — run loop 를
//                                도는 것이 갱신 조건인지 가른다
//   layout-probe --list-sources [필터]
//                                설치된 입력 소스의 표시 이름 · ID · 추가 여부
//
// **`--watch` 가 C1 판정의 본체다.** 단발 실행은 매 회가 새 프로세스라 C1 이 항상
// fresh 해서, "source 생성 시점에 고정되는가" 를 원리적으로 못 잰다. `--watch` 를
// 띄워 둔 채 시스템 설정에서 입력 소스를 바꾸면 한 프로세스가 전환 전후를 다 본다.
//
// ## 빌드 · 사용
//
//   clang -fobjc-arc -framework AppKit -framework Carbon -framework CoreGraphics \
//         -framework CoreFoundation -o /tmp/layout-probe dist/macos/layout-probe.m
//   /tmp/layout-probe                  # 현재 layout 전체 표
//   /tmp/layout-probe --watch 10 12    # 10 초 간격 12 회 — 그 사이 입력 소스를 바꾼다
//
// 앱에 들어가는 코드가 아니다 — 진단 전용이고 tildaz 본체 빌드와 무관하다.

#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>

#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/// 번역 결과 한 칸. `UCKeyTranslate` 도 `CGEventKeyboardGetUnicodeString` 도 최대
/// 255 자를 낼 수 있지만 실제로 4 자를 넘는 일이 드물다 (`UnicodeUtilities.h` 의
/// `maxStringLength` 주석). 8 로 넉넉히 잡고 넘치면 그 자리에서 드러나게 둔다.
#define PROBE_MAX_CHARS 8

typedef struct {
    UniChar chars[PROBE_MAX_CHARS];
    UniCharCount len;
    bool ok;     ///< 번역 자체가 성공했는가 (실패와 "빈 문자열" 은 다르다)
    bool threw;  ///< 번역이 **예외를 던졌는가** — 경로 D 에서만 일어난다 (아래 주석)
} Translation;

/// `kVK_ANSI_*` 중 단축키 매칭에 실제로 쓰이는 자리들. layout 을 바꿔도 A 와 C 가
/// 같은 값을 내는지 눈으로 바로 보려고 `--watch` 요약에 따로 낸다.
typedef struct {
    UInt16 keycode;
    const char *name;
} WatchedKey;

static const WatchedKey kWatchedKeys[] = {
    {0x0D, "kVK_ANSI_W  (close_tab)"},
    {0x11, "kVK_ANSI_T  (new_tab)"},
    {0x08, "kVK_ANSI_C  (copy)"},
    {0x09, "kVK_ANSI_V  (paste)"},
    {0x00, "kVK_ANSI_A"},
    {0x0C, "kVK_ANSI_Q"},
    {0x06, "kVK_ANSI_Z"},
    {0x2E, "kVK_ANSI_M"},
    {0x32, "kVK_ANSI_Grave"},
    {0x21, "kVK_ANSI_LeftBracket"},
    {0x1E, "kVK_ANSI_RightBracket"},
};

// ===========================================================================
//  경로 A — TIS + UCKeyTranslate (정답지)
// ===========================================================================

/// **매 호출마다** input source 를 새로 조회한다. 정답지 역할을 하려면 layout 변경을
/// 반드시 따라와야 하고, 캐시하면 그 자체가 C1 과 같은 의심을 받는다.
static Translation translateWithTIS(UInt16 keycode) {
    Translation out = {.len = 0, .ok = false, .threw = false};

    TISInputSourceRef source = TISCopyCurrentKeyboardLayoutInputSource();
    if (!source) return out;

    CFDataRef data =
        (CFDataRef)TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData);
    if (!data) {
        CFRelease(source);
        return out;
    }

    const UCKeyboardLayout *layout = (const UCKeyboardLayout *)CFDataGetBytePtr(data);
    UInt32 deadKeyState = 0;
    UniCharCount actual = 0;
    OSStatus status =
        UCKeyTranslate(layout, keycode, kUCKeyActionDisplay,
                       /* modifierKeyState */ 0, LMGetKbdType(),
                       kUCKeyTranslateNoDeadKeysMask, &deadKeyState, PROBE_MAX_CHARS,
                       &actual, out.chars);
    CFRelease(source);

    if (status != noErr) return out;
    out.len = actual;
    out.ok = true;
    return out;
}

/// 현재 입력 소스의 사람이 읽는 이름 + ID. `--watch` 에서 전환 시점을 이것으로 안다.
static void currentInputSourceName(char *nameBuf, size_t nameCap, char *idBuf,
                                   size_t idCap) {
    snprintf(nameBuf, nameCap, "(조회 실패)");
    snprintf(idBuf, idCap, "-");

    TISInputSourceRef source = TISCopyCurrentKeyboardLayoutInputSource();
    if (!source) return;

    CFStringRef name = (CFStringRef)TISGetInputSourceProperty(source, kTISPropertyLocalizedName);
    if (name) CFStringGetCString(name, nameBuf, (CFIndex)nameCap, kCFStringEncodingUTF8);
    CFStringRef sid = (CFStringRef)TISGetInputSourceProperty(source, kTISPropertyInputSourceID);
    if (sid) CFStringGetCString(sid, idBuf, (CFIndex)idCap, kCFStringEncodingUTF8);

    CFRelease(source);
}

// ===========================================================================
//  경로 C — CoreGraphics 만
// ===========================================================================

static Translation translateWithCG(CGEventSourceRef source, UInt16 keycode) {
    Translation out = {.len = 0, .ok = false, .threw = false};

    CGEventRef event = CGEventCreateKeyboardEvent(source, (CGKeyCode)keycode, true);
    if (!event) return out;

    UniCharCount actual = 0;
    CGEventKeyboardGetUnicodeString(event, PROBE_MAX_CHARS, &actual, out.chars);
    CFRelease(event);

    out.len = actual;
    out.ok = true;
    return out;
}

/// C2 — source 를 이 호출 안에서 만들고 버린다. 만들기가 실패하면 `ok = false` 로
/// 남겨서 "빈 문자열" 과 구분한다.
static Translation translateWithFreshCGSource(UInt16 keycode) {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (!source) {
        Translation out = {.len = 0, .ok = false, .threw = false};
        return out;
    }
    Translation out = translateWithCG(source, keycode);
    CFRelease(source);
    return out;
}


// ===========================================================================
//  경로 D — AppKit `charactersByApplyingModifiers:`
// ===========================================================================

/// `UnicodeUtilities.h:521` 이 `UCKeyTranslate` 대신 권하는 길이다. `NSEvent.h:366-371`
/// 이 성질을 적어 두었다 — *"It uses [self keyCode], the new modifiers and **the current
/// keyboard input source's layout data** for re-translation. … calling this method **will
/// not affect the dead key state** for current text input."*
///
/// **낡은 `CGEventSource` 로 만든 이벤트를 일부러 넘긴다.** 그래야 헤더의 "current input
/// source" 서술이 실제로 맞는지 갈린다 — 이벤트가 어느 source 에서 났든 번역이 지금
/// layout 을 따라가면 D 는 경로 C 의 고정 문제가 없다는 뜻이다.
static Translation translateWithNSEvent(CGEventSourceRef source, UInt16 keycode) {
    Translation out = {.len = 0, .ok = false, .threw = false};

    CGEventRef event = CGEventCreateKeyboardEvent(source, (CGKeyCode)keycode, true);
    if (!event) return out;

    NSEvent *ns = [NSEvent eventWithCGEvent:event];
    CFRelease(event);
    if (!ns) return out;

    // modifiers 0 = 아무 modifier 없는 라벨. `charactersIgnoringModifiers` 와 달리
    // shift 도 빼고, 이벤트에 이미 붙은 modifier 를 통째로 무시한다.
    //
    // ⚠️ **예외를 던진다.** `NSEvent.h:369` 는 *"If there is invalid data in this event,
    // -charactersByApplyingModifiers will return nil"* 이라고 적지만, 실기에서는 nil 이
    // 아니라 `NSAssertionHandler` 를 거쳐 `abort()` 로 프로세스를 죽인다 (SDK 26.5 /
    // macOS 26.6.2 확인). 그래서 잡는다 — 어느 keycode 가 그러는지가 경로 D 를 쓸 때
    // 알아야 할 값이다.
    NSString *text = nil;
    @try {
        text = [ns charactersByApplyingModifiers:0];
    } @catch (NSException *e) {
        out.threw = true;
        return out;
    }
    if (!text) return out;

    NSUInteger n = text.length;
    if (n > PROBE_MAX_CHARS) n = PROBE_MAX_CHARS;
    if (n > 0) [text getCharacters:out.chars range:NSMakeRange(0, n)];
    out.len = (UniCharCount)n;
    out.ok = true;
    return out;
}

// ===========================================================================
//  표시 · 비교
// ===========================================================================

static bool sameTranslation(Translation a, Translation b) {
    if (a.ok != b.ok) return false;
    if (a.len != b.len) return false;
    for (UniCharCount i = 0; i < a.len; i++) {
        if (a.chars[i] != b.chars[i]) return false;
    }
    return true;
}

/// `'é' U+00E9` 꼴로 적는다. 제어문자 · 비인쇄는 글자 자리를 `.` 로 두고 코드포인트만
/// 남긴다 — 표가 깨지지 않게. 번역 실패와 빈 문자열은 다른 표기다.
static void formatTranslation(Translation t, char *buf, size_t cap) {
    if (t.threw) {
        snprintf(buf, cap, "%-6s %-24s", "예외", "");
        return;
    }
    if (!t.ok) {
        snprintf(buf, cap, "%-6s %-24s", "FAIL", "");
        return;
    }
    if (t.len == 0) {
        snprintf(buf, cap, "%-6s %-24s", "(빔)", "");
        return;
    }

    char glyphs[PROBE_MAX_CHARS * 4 + 1];
    size_t g = 0;
    char codes[PROBE_MAX_CHARS * 8 + 1];
    size_t c = 0;

    for (UniCharCount i = 0; i < t.len && i < PROBE_MAX_CHARS; i++) {
        UniChar u = t.chars[i];
        if (u < 0x20 || u == 0x7F) {
            // 제어문자 — 글리프 자리를 비운다.
            if (g + 1 < sizeof(glyphs)) glyphs[g++] = '.';
        } else {
            // UTF-16 한 칸을 UTF-8 로 (BMP 만 — surrogate 는 아래 코드포인트로 보인다).
            if (u < 0x80) {
                if (g + 1 < sizeof(glyphs)) glyphs[g++] = (char)u;
            } else if (u < 0x800) {
                if (g + 2 < sizeof(glyphs)) {
                    glyphs[g++] = (char)(0xC0 | (u >> 6));
                    glyphs[g++] = (char)(0x80 | (u & 0x3F));
                }
            } else {
                if (g + 3 < sizeof(glyphs)) {
                    glyphs[g++] = (char)(0xE0 | (u >> 12));
                    glyphs[g++] = (char)(0x80 | ((u >> 6) & 0x3F));
                    glyphs[g++] = (char)(0x80 | (u & 0x3F));
                }
            }
        }
        int n = snprintf(codes + c, sizeof(codes) - c, "%sU+%04X", c ? "," : "", u);
        if (n > 0) c += (size_t)n;
    }
    glyphs[g] = '\0';
    codes[c] = '\0';

    // 글리프는 UTF-8 이라 바이트 폭과 표시 폭이 달라서 `%-*s` 로는 열이 안 맞는다.
    // 그래서 글리프를 따옴표로 감싸 경계를 눈에 보이게 하고, 열 정렬은 코드포인트
    // 쪽에만 준다.
    snprintf(buf, cap, "'%s' %-24s", glyphs, codes);
}

// ===========================================================================
//  ④ dlopen — 경로 B 의 전제
// ===========================================================================

static const char *kHIToolboxPath =
    "/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/"
    "Versions/A/HIToolbox";

typedef TISInputSourceRef (*CopyCurrentLayoutFn)(void);
typedef void *(*GetPropertyFn)(TISInputSourceRef, CFStringRef);

/// 심볼이 **실제로 어느 이미지에 있는지** 를 `dladdr` 로 확인한다. `dlsym` 은 핸들의
/// 의존성 체인까지 뒤지므로 "HIToolbox 핸들에서 잡혔다" 가 "HIToolbox 에 있다" 를
/// 뜻하지 않는다 — 이 구분이 경로 B 의 서술을 정확하게 만든다.
static void reportSymbolImage(const char *label, void *addr) {
    Dl_info info;
    if (addr && dladdr(addr, &info) && info.dli_fname) {
        printf("  %-44s %s\n", label, info.dli_fname);
    } else {
        printf("  %-44s (확인 불가)\n", label);
    }
}

static void reportDlopen(void) {
    printf("\n========== ④ dlopen (경로 B 의 전제) ==========\n");

    struct stat st;
    bool onDisk = (stat(kHIToolboxPath, &st) == 0);
    printf("경로            : %s\n", kHIToolboxPath);
    printf("디스크에 파일   : %s\n",
           onDisk ? "있음" : "없음 (macOS 11+ 는 dyld shared cache 안이라 정상)");

    void *handle = dlopen(kHIToolboxPath, RTLD_LAZY);
    printf("dlopen          : %s\n", handle ? "열림" : "실패");
    if (!handle) {
        printf("dlerror         : %s\n", dlerror());
        return;
    }

    void *fnCopy = dlsym(handle, "TISCopyCurrentKeyboardLayoutInputSource");
    void *fnProp = dlsym(handle, "TISGetInputSourceProperty");
    void *symKey = dlsym(handle, "kTISPropertyUnicodeKeyLayoutData");
    // `UCKeyTranslate` 는 CoreServices/CarbonCore 에 있다는 것을 실기로 확인한다 —
    // 여기서 잡히면 안 되는 것이 정상이다.
    void *fnUC = dlsym(handle, "UCKeyTranslate");

    printf("dlsym  함수 TISCopyCurrentKeyboardLayoutInputSource : %s\n",
           fnCopy ? "잡힘" : "없음");
    printf("dlsym  함수 TISGetInputSourceProperty               : %s\n",
           fnProp ? "잡힘" : "없음");
    printf("dlsym  데이터 kTISPropertyUnicodeKeyLayoutData      : %s\n",
           symKey ? "잡힘" : "없음");
    printf("dlsym  함수 UCKeyTranslate (HIToolbox 에 있는가)     : %s\n",
           fnUC ? "잡힘 (예상 밖)" : "없음 — CoreServices 쪽이라는 뜻");

    printf("\ndladdr — 심볼의 실제 소속 이미지:\n");
    reportSymbolImage("dlsym TISCopyCurrentKeyboardLayoutInputSource", fnCopy);
    reportSymbolImage("dlsym TISGetInputSourceProperty", fnProp);
    reportSymbolImage("dlsym kTISPropertyUnicodeKeyLayoutData", symKey);
    reportSymbolImage("dlsym UCKeyTranslate", fnUC);
    reportSymbolImage("링크된 UCKeyTranslate (-framework Carbon)", (void *)UCKeyTranslate);
    reportSymbolImage("링크된 TISCopyCurrentKeyboardLayoutInputSource",
                      (void *)TISCopyCurrentKeyboardLayoutInputSource);

    // 심볼이 잡히는 것과 **쓸 수 있는 것**은 다르다. dlopen 한 핸들만으로 uchr
    // 데이터까지 실제로 꺼내 본다 — 경로 B 가 성립하는지의 진짜 증거다.
    if (fnCopy && fnProp && symKey) {
        CFStringRef key = *(CFStringRef *)symKey;
        char keyName[128] = "(문자열 변환 실패)";
        if (key && CFGetTypeID(key) == CFStringGetTypeID()) {
            CFStringGetCString(key, keyName, sizeof(keyName), kCFStringEncodingUTF8);
        }
        printf("데이터 심볼 값  : \"%s\"\n", keyName);

        CopyCurrentLayoutFn copyFn = (CopyCurrentLayoutFn)fnCopy;
        GetPropertyFn propFn = (GetPropertyFn)fnProp;
        TISInputSourceRef source = copyFn();
        if (!source) {
            printf("실사용 검증     : input source 조회 실패\n");
        } else {
            CFDataRef data = (CFDataRef)propFn(source, key);
            if (data) {
                printf("실사용 검증     : uchr 데이터 %ld 바이트 획득 — 경로 B 성립\n",
                       (long)CFDataGetLength(data));
            } else {
                printf("실사용 검증     : uchr 데이터 없음\n");
            }
            CFRelease(source);
        }
    }

    dlclose(handle);
}

// ===========================================================================
//  ② 전체 표
// ===========================================================================

/// 세 방식의 불일치 수. 판정은 이 숫자로 하고, 표는 근거로 남긴다.
typedef struct {
    int mismatchAC1;
    int mismatchAC2;
    int mismatchC1C2;
    int mismatchAD;
    int failA;
    int failC1;
    int failC2;
    int failD;
    int threwD;
} Counters;

static Counters dumpFullTable(CGEventSourceRef reusedSource, bool printRows) {
    Counters n = {0};

    if (printRows) {
        printf("\n%-10s  %-32s %-32s %-32s %-32s %s\n", "keycode",
               "(A) TIS+UCKeyTranslate", "(C1) source 재사용", "(C2) source 매번",
               "(D) NSEvent", "일치");
        printf("%.*s\n", 126,
               "----------------------------------------------------------------"
               "----------------------------------------------------------------");
    }

    for (UInt16 kc = 0; kc < 128; kc++) {
        Translation a = translateWithTIS(kc);
        Translation c1 = translateWithCG(reusedSource, kc);
        Translation c2 = translateWithFreshCGSource(kc);
        // 낡을 수 있는 source 를 일부러 넘긴다 (위 함수 주석).
        Translation d = translateWithNSEvent(reusedSource, kc);

        bool eqAC1 = sameTranslation(a, c1);
        bool eqAC2 = sameTranslation(a, c2);
        bool eqC1C2 = sameTranslation(c1, c2);
        bool eqAD = sameTranslation(a, d);

        if (!a.ok) n.failA++;
        if (!c1.ok) n.failC1++;
        if (!c2.ok) n.failC2++;
        if (!d.ok) n.failD++;
        if (d.threw) n.threwD++;
        if (!eqAC1) n.mismatchAC1++;
        if (!eqAC2) n.mismatchAC2++;
        if (!eqC1C2) n.mismatchC1C2++;
        if (!eqAD) n.mismatchAD++;

        if (printRows) {
            char bufA[96], bufC1[96], bufC2[96], bufD[96];
            formatTranslation(a, bufA, sizeof(bufA));
            formatTranslation(c1, bufC1, sizeof(bufC1));
            formatTranslation(c2, bufC2, sizeof(bufC2));
            formatTranslation(d, bufD, sizeof(bufD));
            printf("0x%02X (%3u)  %-32s %-32s %-32s %-32s %s\n", kc, kc, bufA, bufC1, bufC2,
                   bufD, (eqAC1 && eqAC2 && eqAD) ? "OK" : "다름");
        }
    }
    return n;
}

static void printCounters(Counters n) {
    printf("\n---------- 요약 (keycode 0..127, 128 개) ----------\n");
    printf("A vs C1  불일치 : %3d / 128\n", n.mismatchAC1);
    printf("A vs C2  불일치 : %3d / 128\n", n.mismatchAC2);
    printf("C1 vs C2 불일치 : %3d / 128\n", n.mismatchC1C2);
    printf("A vs D   불일치 : %3d / 128\n", n.mismatchAD);
    printf("번역 실패       : A %d · C1 %d · C2 %d · D %d\n", n.failA, n.failC1, n.failC2,
           n.failD);
    printf("D 가 예외를 던진 keycode : %d 개\n", n.threwD);
}

/// 입력 소스 변경 CF distributed notification 을 받은 횟수. **run loop 를 돌려야만**
/// 콜백이 불린다 — 그것이 이 도구가 가르려는 것이다.
static int g_changeNotifications = 0;

static void onInputSourceChanged(CFNotificationCenterRef center, void *observer,
                                 CFNotificationName name, const void *object,
                                 CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    g_changeNotifications++;
    printf("  [통지] 입력 소스 변경 (%d 번째)\n", g_changeNotifications);
    fflush(stdout);
}

/// `--watch` 회차마다 내는 짧은 요약. 전체 표는 128 행이라 회차마다 찍으면 읽을 수
/// 없어서, **불일치 개수 + 관심 키** 만 낸다.
static void printWatchRound(int round, CGEventSourceRef reusedSource) {
    char name[256], sid[256];
    currentInputSourceName(name, sizeof(name), sid, sizeof(sid));

    printf("\n===== 회차 %d — 입력 소스: %s  [%s]  (누적 통지 %d 회) =====\n", round, name,
           sid, g_changeNotifications);

    Counters n = dumpFullTable(reusedSource, /* printRows */ false);
    printf("불일치: A/C1 %d · A/C2 %d · C1/C2 %d · A/D %d   (128 개 중)\n", n.mismatchAC1,
           n.mismatchAC2, n.mismatchC1C2, n.mismatchAD);

    printf("%-28s  %-26s %-26s %-26s %-26s\n", "관심 키", "(A)", "(C1) 재사용", "(C2) 매번",
           "(D) NSEvent");
    for (size_t i = 0; i < sizeof(kWatchedKeys) / sizeof(kWatchedKeys[0]); i++) {
        UInt16 kc = kWatchedKeys[i].keycode;
        Translation a = translateWithTIS(kc);
        Translation c1 = translateWithCG(reusedSource, kc);
        Translation c2 = translateWithFreshCGSource(kc);
        Translation d = translateWithNSEvent(reusedSource, kc);
        char bufA[96], bufC1[96], bufC2[96], bufD[96];
        formatTranslation(a, bufA, sizeof(bufA));
        formatTranslation(c1, bufC1, sizeof(bufC1));
        formatTranslation(c2, bufC2, sizeof(bufC2));
        formatTranslation(d, bufD, sizeof(bufD));
        printf("%-28s  %-26s %-26s %-26s %-26s\n", kWatchedKeys[i].name, bufA, bufC1, bufC2,
               bufD);
    }
    fflush(stdout);
}

// ===========================================================================

// ===========================================================================
//  --list-sources — 설치된 입력 소스의 **표시 이름**과 ID
// ===========================================================================

/// 측정을 시작하기 전에 "시스템 설정에서 무엇을 고를지" 를 정확히 짚기 위한 목록이다.
/// 표시 이름은 **caller 의 언어**를 따르므로 (`kTISPropertyLocalizedName` 주석 —
/// CFBundle 의 best match), 한국어 환경에서 돌리면 설정 앱에 보이는 것과 같은 이름이
/// 나온다. 영어 이름을 문서에서 베껴 안내하면 한국어 UI 사용자가 못 찾는다.
static void listSources(const char *filter) {
    CFArrayRef enabled = TISCreateInputSourceList(NULL, /* includeAllInstalled */ false);
    CFArrayRef all = TISCreateInputSourceList(NULL, /* includeAllInstalled */ true);
    if (!all) {
        printf("입력 소스 목록 조회 실패\n");
        return;
    }

    printf("%-6s  %-44s %s\n", "추가됨", "input source ID", "표시 이름");
    printf("%.*s\n", 100,
           "--------------------------------------------------------------------"
           "--------------------------------------------------------------------");

    CFIndex n = CFArrayGetCount(all);
    for (CFIndex i = 0; i < n; i++) {
        TISInputSourceRef src = (TISInputSourceRef)CFArrayGetValueAtIndex(all, i);

        CFStringRef sid = (CFStringRef)TISGetInputSourceProperty(src, kTISPropertyInputSourceID);
        if (!sid) continue;
        char idBuf[192] = "";
        CFStringGetCString(sid, idBuf, sizeof(idBuf), kCFStringEncodingUTF8);
        if (filter && filter[0] && !strstr(idBuf, filter)) continue;

        CFStringRef name = (CFStringRef)TISGetInputSourceProperty(src, kTISPropertyLocalizedName);
        char nameBuf[192] = "(이름 없음)";
        if (name) CFStringGetCString(name, nameBuf, sizeof(nameBuf), kCFStringEncodingUTF8);

        // 이미 추가돼 있는가 — enabled 목록에 같은 ID 가 있는지로 본다.
        bool isEnabled = false;
        if (enabled) {
            CFIndex m = CFArrayGetCount(enabled);
            for (CFIndex j = 0; j < m; j++) {
                TISInputSourceRef e = (TISInputSourceRef)CFArrayGetValueAtIndex(enabled, j);
                CFStringRef esid =
                    (CFStringRef)TISGetInputSourceProperty(e, kTISPropertyInputSourceID);
                if (esid && CFStringCompare(esid, sid, 0) == kCFCompareEqualTo) {
                    isEnabled = true;
                    break;
                }
            }
        }

        printf("%-6s  %-44s %s\n", isEnabled ? "  O" : "  -", idBuf, nameBuf);
    }

    if (enabled) CFRelease(enabled);
    CFRelease(all);
}

int main(int argc, const char *argv[]) {
    bool watch = false;
    int intervalSec = 10;
    int rounds = 12;

    if (argc >= 2 && strcmp(argv[1], "--list-sources") == 0) {
        listSources(argc >= 3 ? argv[2] : NULL);
        return 0;
    }

    bool useRunLoop = false;
    if (argc >= 2 && strcmp(argv[1], "--watch-runloop") == 0) {
        watch = true;
        useRunLoop = true;
        if (argc >= 3) intervalSec = atoi(argv[2]);
        if (argc >= 4) rounds = atoi(argv[3]);
        if (intervalSec < 1) intervalSec = 1;
        if (rounds < 1) rounds = 1;
    }

    if (argc >= 2 && strcmp(argv[1], "--watch") == 0) {
        watch = true;
        if (argc >= 3) intervalSec = atoi(argv[2]);
        if (argc >= 4) rounds = atoi(argv[3]);
        if (intervalSec < 1) intervalSec = 1;
        if (rounds < 1) rounds = 1;
    }

    // **프로그램 시작에 한 번만** 만든다 — C1 의 정의 그 자체다. 이 위치가 바뀌면
    // 측정의 의미가 사라진다.
    CGEventSourceRef reusedSource = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (!reusedSource) {
        fprintf(stderr, "CGEventSourceCreate 실패 — C1 을 잴 수 없습니다\n");
        return 2;
    }

    char name[256], sid[256];
    currentInputSourceName(name, sizeof(name), sid, sizeof(sid));
    printf("========== layout-probe (#496 항목 2) ==========\n");
    printf("현재 입력 소스  : %s  [%s]\n", name, sid);
    printf("LMGetKbdType()  : %d\n", (int)LMGetKbdType());
    printf("CGEventSourceGetKeyboardType(C1) : %u\n",
           (unsigned)CGEventSourceGetKeyboardType(reusedSource));

    if (!watch) {
        reportDlopen();
        Counters n = dumpFullTable(reusedSource, /* printRows */ true);
        printCounters(n);
    } else {
        printf("\n--watch%s %d 초 간격 %d 회 — 이 프로세스는 살아 있습니다.\n",
               useRunLoop ? "-runloop" : "", intervalSec, rounds);
        printf("회차 사이에 입력 소스를 바꾸면 C1 (source 재사용) 이 따라오는지 보입니다.\n");
        printf("대기 방식: %s\n",
               useRunLoop ? "CFRunLoopRunInMode (통지 처리됨)" : "sleep (통지 처리 안 됨)");

        if (useRunLoop) {
            // 통지를 **관찰**만 한다. 관찰 자체가 갱신을 일으키는지, 아니면 run loop 를
            // 도는 것만으로 충분한지는 이 도구가 가를 수 없다 — 그래서 두 모드의 차이를
            // "run loop 를 돌았는가" 로만 서술하고, 그 안을 더 쪼개지 않는다.
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDistributedCenter(), NULL, onInputSourceChanged,
                kTISNotifySelectedKeyboardInputSourceChanged, NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
        }
        fflush(stdout);

        for (int r = 1; r <= rounds; r++) {
            printWatchRound(r, reusedSource);
            if (r < rounds) {
                if (useRunLoop) {
                    // sleep 과 달리 대기 중에 run loop 소스가 처리된다.
                    CFRunLoopRunInMode(kCFRunLoopDefaultMode, (CFTimeInterval)intervalSec,
                                       false);
                } else {
                    sleep((unsigned)intervalSec);
                }
            }
        }
    }

    CFRelease(reusedSource);
    return 0;
}
