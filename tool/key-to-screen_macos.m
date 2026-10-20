// key-to-screen_macos.m — 키를 누른 순간부터 그 결과가 화면에 표시될 때까지를 앱 밖에서 잰다 (#732).
//
// 앱의 `input` 계측 (키 수신 → present) 은 macOS 표시 대기열을 보지 못한다. 그 뒤로 그림이
// 화면에 나오기까지 3~4 프레임이 더 걸렸다 (#476). 이 도구는 앱 내부와 무관한 같은 잣대로
// 두 판을 견준다.
//
//   1. ScreenCaptureKit 스트림으로 창을 주사율 그대로 받는다 (`minimumFrameInterval = 0`).
//   2. 합성 키를 보낸 순간의 `mach_absolute_time` 을 적는다.
//   3. 그 뒤 **그림이 처음 바뀐 프레임**의 `SCStreamFrameInfoDisplayTime` 과의 차이가 키 → 화면이다.
//      헤더: "For a frame event, this is when the frame was displayed by the window server."
//
// - 화면이 안 바뀌면 프레임이 오지 않는다 (`SCFrameStatusIdle`).
// - **폭포 중에는 pane 을 나눠 잰다.** 한 pane 에 출력을 쏟고 다른 pane 은 `cat` 으로 키만 받게
//   한 뒤, `--x0` · `--x1` (창 폭의 비율) 로 조용한 pane 만 해시한다. 표시 대기열이 차는 것은 매 프레임
//   그릴 때라 (#476), 유휴만 재면 두 판의 차이가 거의 안 보인다 (#732 실측 — 중앙값 19.35 vs 18.93 ms).
// - ScreenCaptureKit 자체의 지연이 섞인다. 절대값보다 **두 판의 차이**로 판정한다.
// - 키는 **지금 포커스된 창**으로 간다. 부르기 전에 측정 창을 key window 로 만든다
//   (`tool/input_macos.m` 의 `focus`). 키는 `a` (keycode 0) 이고 수식키는 붙이지 않는다.
// - 측정 창은 키를 그대로 화면에 되돌리는 것이면 된다 (`-e` 로 `cat` 을 띄우면 tty echo 가 그린다).
//
//   clang -fobjc-arc -framework Cocoa -framework ScreenCaptureKit -framework CoreMedia \
//         -framework CoreVideo -o /tmp/key-to-screen tool/key-to-screen_macos.m
//   /tmp/key-to-screen --window <id> [--presses 30] [--gap-ms 250] [--x0 0.55 --x1 1.0] [--focus]
//
// `--focus` 는 재기 전에 **그 창의 가운데를 한 번 누른다** — 키가 그 창으로 가게 하려는 것이다.
// 다른 터미널과 견줄 때 (`tool/stress/compare-latency.sh`, #756) 창을 pid 가 아니라 창 id 로 고르므로
// `tool/input_macos.m` 의 `focus <pid>` 와 같은 클릭을 여기서 한다. 키가 그 창에 안 닿으면 화면이
// 안 바뀌어 `miss` 로 드러난다.
//
// 화면 기록 권한 (ScreenCaptureKit) 과 손쉬운 사용 권한 (CGEventPost) 은 **실행한 터미널** 의 것을 쓴다.

#import <Cocoa/Cocoa.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <mach/mach_time.h>
#include <stdatomic.h>

#define RING 256

typedef struct {
    uint64_t display_time; // mach absolute time
    uint64_t hash;
} Frame;

static Frame g_ring[RING];
static atomic_uint_fast64_t g_count = 0; // 받은 완성 프레임 수
static atomic_uint_fast64_t g_complete = 0;
/// 해시할 가로 범위 (창 폭의 비율). 폭포 회차는 조용한 pane 만 본다 — 아래 사용법.
static double g_x0 = 0.0, g_x1 = 1.0;

static uint64_t hashPixels(CVPixelBufferRef pb) {
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    const uint8_t *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    size_t h = CVPixelBufferGetHeight(pb);
    size_t w = CVPixelBufferGetWidth(pb);
    uint64_t x = 1469598103934665603ULL; // FNV-1a
    size_t i0 = (size_t)(g_x0 * (double)w), i1 = (size_t)(g_x1 * (double)w);
    if (i1 > w) i1 = w;
    for (size_t y = 0; y < h; y++) {
        const uint32_t *row = (const uint32_t *)(base + y * bpr);
        for (size_t i = i0; i < i1; i++) {
            x ^= row[i];
            x *= 1099511628211ULL;
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return x;
}

@interface Sink : NSObject <SCStreamOutput>
@end
@implementation Sink
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen) return;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (!atts || CFArrayGetCount(atts) == 0) return;
    NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(atts, 0);
    NSNumber *status = info[SCStreamFrameInfoStatus];
    if (!status || status.integerValue != SCFrameStatusComplete) return;
    NSNumber *dt = info[SCStreamFrameInfoDisplayTime];
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!dt || !pb) return;
    uint64_t n = atomic_load(&g_count);
    g_ring[n % RING] = (Frame){.display_time = dt.unsignedLongLongValue, .hash = hashPixels(pb)};
    atomic_store(&g_count, n + 1);
    atomic_fetch_add(&g_complete, 1);
}
@end

static double machToMs(uint64_t d) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)d * tb.numer / tb.denom / 1e6;
}

// `tool/input_macos.m` 의 `focusWindowOfPid` 와 같은 순서다 — 이동 이벤트가 없으면 클릭이 안
// 걸리고 (`CGWarpMouseCursorPosition` 만으로는 부족), 끝나면 사용자의 포인터를 원래 자리로 돌린다.
// 창 가운데는 터미널 본문이라 같은 자리에서 떼면 빈 selection 이어서 화면이 안 바뀐다.
static void clickCenter(CGRect frame) {
    CGPoint target = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    CGEventRef probe = CGEventCreate(NULL);
    CGPoint origin = (probe != NULL) ? CGEventGetLocation(probe) : target;
    if (probe != NULL) CFRelease(probe);
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
    CGWarpMouseCursorPosition(origin);
}

static void sendKey(CGKeyCode code) {
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, code, true);
    CGEventRef up = CGEventCreateKeyboardEvent(NULL, code, false);
    CGEventSetFlags(down, 0);
    CGEventSetFlags(up, 0);
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down);
    CFRelease(up);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // 창 서버 연결을 먼저 연다. 없으면 SCStream 이 `CGS_REQUIRE_INIT` 단언으로 멈춘다
        // (한 장만 찍는 `color-capture` 는 필요 없었다).
        [NSApplication sharedApplication];
        uint32_t want = 0;
        int presses = 30, gap_ms = 250, focus = 0;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--window") && i + 1 < argc) want = (uint32_t)strtoul(argv[++i], NULL, 10);
            else if (!strcmp(argv[i], "--presses") && i + 1 < argc) presses = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--gap-ms") && i + 1 < argc) gap_ms = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--x0") && i + 1 < argc) g_x0 = atof(argv[++i]);
            else if (!strcmp(argv[i], "--x1") && i + 1 < argc) g_x1 = atof(argv[++i]);
            else if (!strcmp(argv[i], "--focus")) focus = 1;
        }
        if (want == 0) {
            fprintf(stderr, "쓰는 법: key-to-screen --window <id> [--presses N] [--gap-ms MS]\n");
            return 2;
        }

        __block SCShareableContent *content = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *c, NSError *e) {
          content = c;
          dispatch_semaphore_signal(sem);
        }];
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) || !content) {
            fprintf(stderr, "창 목록 조회 실패 — 화면 기록 권한을 확인하세요\n");
            return 2;
        }
        SCWindow *win = nil;
        for (SCWindow *w in content.windows) if (w.windowID == want) win = w;
        if (!win) {
            fprintf(stderr, "windowID %u 를 찾지 못했습니다\n", want);
            return 2;
        }

        if (focus) {
            clickCenter(win.frame);
            usleep(300 * 1000); // 포커스가 옮겨 가고 클릭이 그린 것이 가라앉을 때까지
        }

        SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:win];
        SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
        // 절반 크기 — 해시 비용을 줄인다. 판정은 프레임에 붙은 displayTime 이라 처리 시간은 섞이지 않는다.
        cfg.width = (size_t)win.frame.size.width;
        cfg.height = (size_t)win.frame.size.height;
        cfg.minimumFrameInterval = kCMTimeZero;
        cfg.queueDepth = 6;
        cfg.showsCursor = NO;
        cfg.pixelFormat = kCVPixelFormatType_32BGRA;

        Sink *sink = [[Sink alloc] init];
        SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:nil];
        NSError *err = nil;
        dispatch_queue_t q = dispatch_queue_create("key-to-screen.frames", DISPATCH_QUEUE_SERIAL);
        if (![stream addStreamOutput:sink type:SCStreamOutputTypeScreen sampleHandlerQueue:q error:&err]) {
            fprintf(stderr, "스트림 출력 추가 실패: %s\n", err.localizedDescription.UTF8String);
            return 2;
        }
        __block NSError *start_err = nil;
        [stream startCaptureWithCompletionHandler:^(NSError *e) {
          start_err = e;
          dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        if (start_err) {
            fprintf(stderr, "캡처 시작 실패: %s\n", start_err.localizedDescription.UTF8String);
            return 2;
        }
        usleep(800 * 1000); // 첫 프레임이 들어와 기준 해시가 생길 때까지

        double *lat = calloc((size_t)presses, sizeof(double));
        int got = 0, miss = 0;
        for (int i = 0; i < presses; i++) {
            usleep((useconds_t)gap_ms * 1000);
            uint64_t n0 = atomic_load(&g_count);
            uint64_t base_hash = n0 ? g_ring[(n0 - 1) % RING].hash : 0;
            uint64_t t0 = mach_absolute_time();
            sendKey(0); // 'a'
            double found = -1;
            for (int spin = 0; spin < 500 && found < 0; spin++) { // 최대 0.5 초
                usleep(1000);
                uint64_t n = atomic_load(&g_count);
                for (uint64_t k = n0; k < n; k++) {
                    Frame f = g_ring[k % RING];
                    if (f.display_time > t0 && f.hash != base_hash) {
                        found = machToMs(f.display_time - t0);
                        break;
                    }
                }
            }
            if (found < 0) {
                miss++;
                printf("press %2d  miss\n", i + 1);
            } else {
                lat[got++] = found;
                printf("press %2d  %6.2f ms\n", i + 1, found);
            }
            fflush(stdout);
        }
        [stream stopCaptureWithCompletionHandler:^(NSError *e) {
          dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

        // 정렬해 중앙값 · 최소 · 최대.
        for (int a = 0; a < got; a++)
            for (int b = a + 1; b < got; b++)
                if (lat[b] < lat[a]) { double t = lat[a]; lat[a] = lat[b]; lat[b] = t; }
        double sum = 0;
        for (int a = 0; a < got; a++) sum += lat[a];
        if (got > 0)
            printf("samples=%d miss=%d mean_ms=%.2f median_ms=%.2f min_ms=%.2f max_ms=%.2f frames_seen=%llu\n", got, miss,
                   sum / got, lat[got / 2], lat[0], lat[got - 1], (unsigned long long)atomic_load(&g_complete));
        else
            printf("samples=0 miss=%d\n", miss);
        free(lat);
    }
    return 0;
}
