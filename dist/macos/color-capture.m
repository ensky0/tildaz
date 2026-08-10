// color-capture.m — 창을 sRGB 색공간으로 캡처하는 색 실측용 도구 (#349).
//
// macOS 는 layer 내용을 sRGB 로 보고 **디스플레이 색공간으로 변환해** 합성한다.
// `screencapture` 는 출력 색공간을 고를 수 없어서 (`man screencapture` — 관련
// 플래그 없음, `-r` 은 dpi 메타만 제거) 캡처 픽셀이 항상 디스플레이 공간 값이고,
// 프리셋이 wide-gamut 이면 앱이 그린 값과 다르게 읽힌다. 그래서 예전에는 실측할
// 때마다 디스플레이 프리셋을 `Internet & Web (sRGB)` 로 바꿔야 했다.
//
// ScreenCaptureKit 은 출력 색공간을 지정할 수 있다 —
// `SCStreamConfiguration.colorSpaceName` 헤더 주석: "If not set the output buffer
// uses the same color space as the display". sRGB 로 지정하면 출력 버퍼가 sRGB 로
// 나오니, 다 찍은 PNG 을 사후에 변환하는 8-bit 왕복이 없다 (#349 에서 파생색 46개
// 46/46 일치 확인, 프리셋 무관). 파이프라인 내부에서 어느 단계에 변환이 일어나는지는
// 확인하지 않았다 — 확인한 것은 결과 픽셀이 authored 값과 같다는 것이다.
//
// 빌드 · 사용 (`AGENTS.md` 의 "macOS — 색 실측 방법" 절 참고):
//
//   clang -fobjc-arc -framework Cocoa -framework ScreenCaptureKit \
//         -framework ImageIO -framework UniformTypeIdentifiers \
//         -o /tmp/color-capture dist/macos/color-capture.m
//   /tmp/color-capture --list                    # windowID 찾기
//   /tmp/color-capture --window <id> out.png     # 출력 색공간 = sRGB
//   magick out.png -format "%[pixel:p{40,40}]\n" info:
//
// 결과 PNG 은 sRGB 로 태깅되므로 ImageMagick / sips 로 읽어도 값이 같다 (#349
// 확인). 색공간이 어긋난 캡처를 **사후에 역변환하는 방식은 쓰지 않는다** —
// ImageMagick `-profile` 과 `sips --matchTo` 결과가 갈린다 (#335).
//
// `SCScreenshotManager.captureImageWithFilter:` 가 macOS 14+ 라 그 이상에서만
// 동작한다. 앱에 들어가는 코드가 아니라 tildaz 의 최소 지원 버전과는 무관하다.

#import <Cocoa/Cocoa.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

/// 화면 기록 권한이 없으면 여기서 막힌다 (실행한 터미널의 권한을 따라가고,
/// 재빌드해도 다시 묻지 않는다 — #349 확인).
static SCShareableContent *shareableContentOrDie(void) {
    __block SCShareableContent *result = nil;
    __block NSError *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [SCShareableContent
        getShareableContentWithCompletionHandler:^(SCShareableContent *c, NSError *e) {
          result = c;
          err = e;
          dispatch_semaphore_signal(sem);
        }];
    if (dispatch_semaphore_wait(sem,
                                dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC))) {
        fprintf(stderr, "창 목록 조회 시간 초과 — 화면 기록 권한을 확인하세요\n");
        exit(2);
    }
    if (!result) {
        fprintf(stderr, "창 목록 조회 실패: %s\n", err.localizedDescription.UTF8String);
        exit(2);
    }
    return result;
}

/// `app` 열 옆에 **bundle identifier** 를 함께 낸다 (#414).
///
/// `applicationName` 은 **시스템 로케일로 번역된 표시 이름**이다. 한국어 macOS 에서
/// Terminal.app 은 `터미널` 로 나오고 (`제어 센터` · `알림 센터` 도 마찬가지다), 이걸
/// 영문 이름으로 찾으면 조용히 빗나간다 — `compare-terminals.sh --capture` 가 실제로
/// Terminal.app 창을 못 찾아 전체 화면으로 물러섰다. bundle identifier 는 언어에 따라
/// 바뀌지 않아 스크립트가 찾는 기준으로 쓸 수 있다.
///
/// 사람이 눈으로 읽을 때는 `app` 이 여전히 편하므로 **두 열을 같이 둔다.**
static void listWindows(void) {
    SCShareableContent *content = shareableContentOrDie();
    printf("%-8s %-28s %-24s %-12s %s\n", "id", "bundle", "app", "크기(pt)", "제목");
    for (SCWindow *w in content.windows) {
        if (!w.onScreen) continue;
        char size[32];
        snprintf(size, sizeof(size), "%.0fx%.0f", w.frame.size.width,
                 w.frame.size.height);
        // **빈 문자열도 `-` 로 채운다.** `?:` 는 nil 만 걸러서, bundle identifier 가 빈
        // 문자열인 앱은 그대로 통과해 **공백만 찍힌다.** 그러면 이 줄을 공백으로 쪼개 읽는
        // 쪽 (`compare-terminals.sh` 의 awk) 에서 **열이 하나 통째로 밀려** 엉뚱한 값을 본다.
        // CLI 로 띄운 alacritty 가 실제로 그랬다 (실측 — LaunchServices 를 안 거쳐서 그렇다).
        const char *bundle = w.owningApplication.bundleIdentifier.UTF8String;
        if (!bundle || !*bundle) bundle = "-";
        const char *app = w.owningApplication.applicationName.UTF8String;
        if (!app || !*app) app = "(?)";
        printf("%-8u %-28s %-24s %-12s %s\n", (unsigned)w.windowID, bundle, app,
               size, w.title.UTF8String ?: "");
    }
}

static void writePNG(CGImageRef img, const char *path) {
    NSURL *url = [NSURL fileURLWithPath:@(path)];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    if (!dst) {
        fprintf(stderr, "PNG 저장 대상 생성 실패: %s\n", path);
        exit(3);
    }
    CGImageDestinationAddImage(dst, img, NULL);
    if (!CGImageDestinationFinalize(dst)) {
        fprintf(stderr, "PNG 저장 실패: %s\n", path);
        exit(3);
    }
    CFRelease(dst);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        unsigned want_id = 0;
        const char *out = NULL;
        BOOL srgb = YES; // 기본 = sRGB 지정 (이 도구를 쓰는 이유)
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--list") == 0) {
                listWindows();
                return 0;
            }
            if (strcmp(argv[i], "--window") == 0 && i + 1 < argc) {
                want_id = (unsigned)strtoul(argv[++i], NULL, 10);
            } else if (strcmp(argv[i], "--space") == 0 && i + 1 < argc) {
                // `display` 는 `screencapture` 와 같은 결과를 내는 비교용이다.
                srgb = strcmp(argv[++i], "display") != 0;
            } else {
                out = argv[i];
            }
        }
        if (!want_id || !out) {
            fprintf(stderr,
                    "사용법: color-capture --window <id> <out.png> [--space srgb|display]\n"
                    "        color-capture --list\n");
            return 1;
        }

        SCShareableContent *content = shareableContentOrDie();
        SCWindow *target = nil;
        for (SCWindow *w in content.windows) {
            if (w.windowID == want_id) {
                target = w;
                break;
            }
        }
        if (!target) {
            fprintf(stderr, "windowID %u 를 찾지 못했습니다 (--list 로 확인)\n", want_id);
            return 2;
        }

        // 창의 물리 픽셀 크기로 캡처한다 — scalesToFit 를 끄고 크기를 정확히 맞춰
        // 리샘플링이 픽셀 값을 섞지 않게 한다 (색 실측에서는 치명적).
        CGFloat scale = 1.0;
        for (NSScreen *s in [NSScreen screens]) {
            if (NSIntersectsRect(s.frame, target.frame)) {
                scale = s.backingScaleFactor;
                break;
            }
        }
        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
        config.width = (size_t)(target.frame.size.width * scale);
        config.height = (size_t)(target.frame.size.height * scale);
        config.scalesToFit = NO;
        config.showsCursor = NO;
        config.ignoreShadowsSingleWindow = YES;
        config.captureResolution = SCCaptureResolutionBest;
        if (srgb) config.colorSpaceName = kCGColorSpaceSRGB;

        SCContentFilter *filter =
            [[SCContentFilter alloc] initWithDesktopIndependentWindow:target];

        __block CGImageRef image = NULL;
        __block NSError *err = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [SCScreenshotManager captureImageWithFilter:filter
                                      configuration:config
                                  completionHandler:^(CGImageRef img, NSError *e) {
                                    if (img) image = (CGImageRef)CFRetain(img);
                                    err = e;
                                    dispatch_semaphore_signal(sem);
                                  }];
        if (dispatch_semaphore_wait(
                sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC))) {
            fprintf(stderr, "캡처 시간 초과\n");
            return 2;
        }
        if (!image) {
            // 화면이 절전으로 꺼져 있으면 여기서 실패한다.
            fprintf(stderr, "캡처 실패: %s\n", err.localizedDescription.UTF8String);
            return 2;
        }

        CGColorSpaceRef cs = CGImageGetColorSpace(image);
        CFStringRef name = cs ? CGColorSpaceCopyName(cs) : NULL;
        printf("%s: %zux%zu px (scale %.2f), 색공간 %s\n", out, CGImageGetWidth(image),
               CGImageGetHeight(image), scale,
               name ? [(__bridge NSString *)name UTF8String] : "(디스플레이 공간)");
        if (name) CFRelease(name);

        writePNG(image, out);
        CFRelease(image);
    }
    return 0;
}
