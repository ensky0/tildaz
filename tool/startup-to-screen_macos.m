// startup-to-screen_macos.m — 터미널을 실행한 순간부터 그 안의 프로그램이 그린 표식이 화면에 처음 보일
// 때까지를 앱 밖에서 잰다 (#756 4 단계 · 시작 시간).
//
//   clang -fobjc-arc -framework Cocoa -framework ScreenCaptureKit -framework CoreMedia \
//         -framework CoreVideo -o /tmp/startup-to-screen tool/startup-to-screen_macos.m
//   /tmp/startup-to-screen [--timeout-ms 10000] [--min-pixels 10000] -- <띄울 명령…>
//
// 1. 주 화면 전체를 ScreenCaptureKit 스트림으로 받는다 (출력 색공간 sRGB — `color-capture_macos.m` 과
//    같은 이유. 디스플레이 프리셋이 wide-gamut 이면 앱이 그린 값과 다르게 읽힌다).
// 2. 첫 프레임에 마젠타가 이미 있으면 멈춘다 — 판정이 성립하지 않는다.
// 3. **명령을 이 프로그램이 직접 띄운다** (`posix_spawnp`). 띄우기 직전의 `mach_absolute_time` 이 기준이다.
// 4. 마젠타 (sRGB R>200 · G<80 · B>200) 픽셀이 `--min-pixels` 이상인 첫 프레임의
//    `SCStreamFrameInfoDisplayTime` 과의 차이를 낸다 — "실행 → 화면에 첫 표식" 이다.
//
// - 표식은 터미널 안 프로그램이 칠한다 (`compare-startup.sh` — 256 색 201 번 배경으로 화면을 지운다).
//   **배경색 지우기 (BCE)** 를 안 하는 터미널도 칠해지게 그 색의 공백 줄도 함께 낸다.
// - 띄운 명령은 기다리지 않는다 (`open` 은 곧 끝나고, 터미널은 계속 떠 있다). 정리는 부르는 쪽 몫이다.
// - 화면 기록 권한 (ScreenCaptureKit) 은 **실행한 쪽** (VS Code 등) 의 것을 쓴다.
// - ScreenCaptureKit 자체의 지연이 섞인다. 같은 실행 안의 대상끼리 견준다.

#import <Cocoa/Cocoa.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <spawn.h>
#include <stdatomic.h>

extern char **environ;

static atomic_uint_fast64_t g_t0 = 0;      // 띄운 순간 (0 이면 아직 안 띄움)
static atomic_uint_fast64_t g_found = 0;   // 표식이 처음 보인 프레임의 표시 시각
static atomic_long g_baseline = -1;        // 띄우기 전 첫 프레임의 마젠타 픽셀 수
static long g_min_pixels = 10000;

static long countMagenta(CVPixelBufferRef pb) {
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    const uint8_t *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb), h = CVPixelBufferGetHeight(pb), w = CVPixelBufferGetWidth(pb);
    long n = 0;
    for (size_t y = 0; y < h; y++) {
        const uint8_t *row = base + y * bpr;
        for (size_t x = 0; x < w; x++) {
            const uint8_t *p = row + x * 4; // BGRA
            if (p[2] > 200 && p[1] < 80 && p[0] > 200) n++;
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return n;
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
    long n = countMagenta(pb);
    if (atomic_load(&g_baseline) < 0) { atomic_store(&g_baseline, n); return; }
    uint64_t t0 = atomic_load(&g_t0);
    if (t0 && !atomic_load(&g_found) && dt.unsignedLongLongValue > t0 && n >= g_min_pixels)
        atomic_store(&g_found, dt.unsignedLongLongValue);
}
@end

static double machToMs(uint64_t d) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)d * tb.numer / tb.denom / 1e6;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // 창 서버 연결을 먼저 연다 — 없으면 SCStream 이 `CGS_REQUIRE_INIT` 단언으로 멈춘다 (`key-to-screen_macos.m`).
        [NSApplication sharedApplication];
        int timeout_ms = 10000, cmd = 0;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--")) { cmd = i + 1; break; }
            if (!strcmp(argv[i], "--timeout-ms") && i + 1 < argc) timeout_ms = atoi(argv[++i]);
            else if (!strcmp(argv[i], "--min-pixels") && i + 1 < argc) g_min_pixels = atol(argv[++i]);
        }
        if (!cmd || cmd >= argc) {
            fprintf(stderr, "쓰는 법: startup-to-screen [--timeout-ms MS] [--min-pixels N] -- <명령…>\n");
            return 2;
        }

        __block SCShareableContent *content = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *c, NSError *e) {
          content = c;
          dispatch_semaphore_signal(sem);
        }];
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) || !content) {
            fprintf(stderr, "화면 목록 조회 실패 — 화면 기록 권한을 확인하세요\n");
            return 2;
        }
        SCDisplay *display = nil;
        for (SCDisplay *d in content.displays) if (d.displayID == CGMainDisplayID()) display = d;
        if (!display) display = content.displays.firstObject;
        if (!display) { fprintf(stderr, "화면을 못 찾았습니다\n"); return 2; }

        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
        SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
        cfg.width = (size_t)display.width; // point 크기 — 판정은 넓이라 해상도를 낮춰 비용을 줄인다
        cfg.height = (size_t)display.height;
        cfg.minimumFrameInterval = kCMTimeZero;
        cfg.queueDepth = 6;
        cfg.showsCursor = NO;
        cfg.pixelFormat = kCVPixelFormatType_32BGRA;
        cfg.colorSpaceName = kCGColorSpaceSRGB;

        Sink *sink = [[Sink alloc] init];
        SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:nil];
        NSError *err = nil;
        dispatch_queue_t q = dispatch_queue_create("startup-to-screen.frames", DISPATCH_QUEUE_SERIAL);
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
        // 기준 프레임이 들어올 때까지. 화면이 안 바뀌면 프레임이 안 오므로 상한을 둔다.
        for (int i = 0; i < 200 && atomic_load(&g_baseline) < 0; i++) usleep(10 * 1000);
        if (atomic_load(&g_baseline) < 0) atomic_store(&g_baseline, 0);
        if (atomic_load(&g_baseline) >= g_min_pixels / 10) {
            fprintf(stderr, "띄우기 전부터 화면에 마젠타가 있어요 (%ld px) — 판정이 성립하지 않아요\n",
                    atomic_load(&g_baseline));
            return 3;
        }

        posix_spawn_file_actions_t fa;
        posix_spawn_file_actions_init(&fa);
        posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
        pid_t child;
        uint64_t t0 = mach_absolute_time();
        atomic_store(&g_t0, t0);
        int rc = posix_spawnp(&child, argv[cmd], &fa, NULL, &argv[cmd], environ);
        posix_spawn_file_actions_destroy(&fa);
        if (rc != 0) {
            fprintf(stderr, "명령을 못 띄웠어요: %s (%s)\n", argv[cmd], strerror(rc));
            return 2;
        }

        uint64_t found = 0;
        for (int waited = 0; waited < timeout_ms && !(found = atomic_load(&g_found)); waited += 2) usleep(2 * 1000);
        [stream stopCaptureWithCompletionHandler:^(NSError *e) { dispatch_semaphore_signal(sem); }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        int st;
        waitpid(child, &st, WNOHANG);
        if (!found) {
            printf("startup_ms=timeout\n");
            return 1;
        }
        printf("startup_ms=%.2f\n", machToMs(found - t0));
    }
    return 0;
}
