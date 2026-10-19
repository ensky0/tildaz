// startup-to-screen_linux.c — 터미널을 실행한 순간부터 그 안의 프로그램이 그린 표식이 화면 캡처에 처음 보일
// 때까지를 앱 밖에서 잰다 (#756 · 시작 시간). `tool/startup-to-screen_macos.m` 의 Linux 짝이다.
//
//   cc -O2 -o /tmp/startup-to-screen tool/startup-to-screen_linux.c $(pkg-config --cflags --libs libpipewire-0.3)
//   tool/screencast-portal_linux.py -- /tmp/startup-to-screen --pw-fd {fd} --node {node}
//       --output OW,OH --dpr S [--timeout-ms 10000] [--min-pixels 10000] -- <띄울 명령…>
//
// 1. portal ScreenCast 의 화면 스트림을 받는다 (`tool/screencast-portal_linux.py` 가 연다).
// 2. 첫 프레임에 마젠타가 이미 있으면 멈춘다 — 판정이 성립하지 않는다.
// 3. **명령을 이 프로그램이 직접 띄운다** (`posix_spawnp`). 띄우기 직전의 `CLOCK_MONOTONIC` 이 기준이다.
// 4. 마젠타 (R>200 · G<80 · B>200) 픽셀이 `--min-pixels` 이상인 첫 프레임이 **도착한** 시각과의 차이를 낸다.
//
// - macOS 판은 프레임의 **표시** 시각을 쓴다. KWin 은 그 시각을 안 줘서 도착 시각을 쓴다 — 이유는
//   `tool/key-to-screen_linux.c` 머리 주석. OS 사이에 절대값을 견주지 않는다.
// - `--min-pixels` 는 **물리 px** 다 (macOS 는 point²). 표식은 창 전체를 칠하므로 어느 쪽이든 창 넓이보다 한참
//   작은 문턱이다. 픽셀은 가로세로 4 칸마다 하나씩 보고 16 을 곱해 센다 — 프레임마다 화면 전체를 다 보면
//   120 Hz 를 못 따라간다.
// - 마젠타 조건은 R 과 B 가 같아서 BGRx · RGBx 어느 바이트 순서로 와도 판정이 같다.
// - 띄운 명령은 기다리지 않는다 (런처는 곧 끝나고 터미널은 계속 떠 있다). 정리는 부르는 쪽 몫이다.
// - 스트림 여는 코드는 `key-to-screen_linux.c` 와 같다 (화면 전체 확인 · 기본 크기 = 화면 물리 크기).

#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>
#include <spa/utils/result.h>

extern char **environ;

#define RING 512
#define STEP 4

typedef struct {
    uint64_t arrive_ns;
    uint32_t magenta; // 표본으로 센 마젠타 픽셀 × STEP²
} Frame;

static Frame g_ring[RING];
static atomic_uint_fast64_t g_count = 0;

struct data {
    struct pw_stream *stream;
    struct spa_hook listener;
    struct spa_video_info_raw info;
    atomic_int ready, bad;
    double out_w, out_h, dpr;
};

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void on_process(void *userdata) {
    struct data *d = userdata;
    struct pw_buffer *b = NULL, *t;
    while ((t = pw_stream_dequeue_buffer(d->stream)) != NULL) {
        if (b) pw_stream_queue_buffer(d->stream, b);
        b = t;
    }
    if (b == NULL) return;
    uint64_t arrive = now_ns();
    struct spa_buffer *buf = b->buffer;
    const uint8_t *base = buf->datas[0].data;
    if (base != NULL && atomic_load(&d->ready)) {
        int W = (int)d->info.size.width, H = (int)d->info.size.height;
        int stride = buf->datas[0].chunk->stride;
        if (stride == 0) stride = W * 4;
        uint32_t n = 0;
        for (int y = 0; y < H; y += STEP) {
            const uint8_t *row = base + (size_t)y * (size_t)stride;
            for (int x = 0; x < W; x += STEP) {
                const uint8_t *p = row + (size_t)x * 4; // [0] · [2] 가 R · B (순서는 형식마다 다르지만 조건이 대칭이다)
                if (p[0] > 200 && p[1] < 80 && p[2] > 200) n++;
            }
        }
        uint64_t k = atomic_load(&g_count);
        g_ring[k % RING] = (Frame){.arrive_ns = arrive, .magenta = n * STEP * STEP};
        atomic_store(&g_count, k + 1);
    }
    pw_stream_queue_buffer(d->stream, b);
}

static void on_param_changed(void *userdata, uint32_t id, const struct spa_pod *param) {
    struct data *d = userdata;
    if (param == NULL || id != SPA_PARAM_Format) return;
    struct spa_video_info_raw info;
    uint32_t mt, mst;
    if (spa_format_parse(param, &mt, &mst) < 0 || mt != SPA_MEDIA_TYPE_video || mst != SPA_MEDIA_SUBTYPE_raw) return;
    if (spa_format_video_raw_parse(param, &info) < 0) return;
    d->info = info;
    int W = (int)info.size.width, H = (int)info.size.height;
    double want = d->out_w / d->out_h, got = (double)W / (double)H;
    if (got < want * 0.99 || got > want * 1.01 || W < d->out_w * d->dpr - 2 || W > d->out_w * d->dpr + 2) {
        fprintf(stderr, "스트림이 %dx%d 예요 — 화면 전체 (%.0fx%.0f) 가 아니에요. 권한 창에서 화면 하나를 골라야 해요.\n",
                W, H, d->out_w * d->dpr, d->out_h * d->dpr);
        atomic_store(&d->bad, 1);
        return;
    }
    uint8_t buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const struct spa_pod *params[1];
    params[0] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
        SPA_PARAM_BUFFERS_dataType, SPA_POD_CHOICE_FLAGS_Int((1 << SPA_DATA_MemPtr) | (1 << SPA_DATA_MemFd)));
    pw_stream_update_params(d->stream, params, 1);
    atomic_store(&d->ready, 1);
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .param_changed = on_param_changed,
    .process = on_process,
};

static void sleep_ms(int ms) {
    struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
    nanosleep(&ts, NULL);
}

int main(int argc, char *argv[]) {
    int pw_fd = -1, timeout_ms = 10000;
    uint32_t node = 0, min_pixels = 10000;
    struct data d = {0};
    int cmd = -1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--")) { cmd = i + 1; break; }
        else if (!strcmp(argv[i], "--pw-fd") && i + 1 < argc) pw_fd = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--node") && i + 1 < argc) node = (uint32_t)strtoul(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--output") && i + 1 < argc) sscanf(argv[++i], "%lf,%lf", &d.out_w, &d.out_h);
        else if (!strcmp(argv[i], "--dpr") && i + 1 < argc) d.dpr = atof(argv[++i]);
        else if (!strcmp(argv[i], "--timeout-ms") && i + 1 < argc) timeout_ms = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--min-pixels") && i + 1 < argc) min_pixels = (uint32_t)strtoul(argv[++i], NULL, 10);
    }
    if (pw_fd < 0 || node == 0 || d.out_w <= 0 || d.dpr <= 0 || cmd < 0 || cmd >= argc) {
        fprintf(stderr, "쓰는 법: startup-to-screen --pw-fd N --node ID --output OW,OH --dpr S [--timeout-ms MS] [--min-pixels N] -- <명령…>\n");
        return 2;
    }

    pw_init(&argc, &argv);
    struct pw_thread_loop *loop = pw_thread_loop_new("startup-to-screen", NULL);
    struct pw_context *ctx = pw_context_new(pw_thread_loop_get_loop(loop), NULL, 0);
    if (pw_thread_loop_start(loop) < 0) { fprintf(stderr, "PipeWire 루프 시작 실패\n"); return 2; }
    pw_thread_loop_lock(loop);
    struct pw_core *core = pw_context_connect_fd(ctx, fcntl(pw_fd, F_DUPFD_CLOEXEC, 5), NULL, 0);
    if (core == NULL) { pw_thread_loop_unlock(loop); fprintf(stderr, "PipeWire 연결 실패\n"); return 2; }
    d.stream = pw_stream_new(core, "tildaz startup-to-screen",
                             pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY, "Capture",
                                               PW_KEY_MEDIA_ROLE, "Screen", NULL));
    pw_stream_add_listener(d.stream, &d.listener, &stream_events, &d);
    uint8_t buffer[2048];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const struct spa_pod *params[1];
    struct spa_rectangle def_size = SPA_RECTANGLE((uint32_t)(d.out_w * d.dpr + 0.5), (uint32_t)(d.out_h * d.dpr + 0.5)),
                         min_size = SPA_RECTANGLE(1, 1), max_size = SPA_RECTANGLE(16384, 16384);
    struct spa_fraction def_rate = SPA_FRACTION(240, 1), min_rate = SPA_FRACTION(0, 1), max_rate = SPA_FRACTION(1000, 1);
    params[0] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
        SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
        SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
        SPA_FORMAT_VIDEO_format, SPA_POD_CHOICE_ENUM_Id(5, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRx,
                                                        SPA_VIDEO_FORMAT_BGRA, SPA_VIDEO_FORMAT_RGBx, SPA_VIDEO_FORMAT_RGBA),
        SPA_FORMAT_VIDEO_size, SPA_POD_CHOICE_RANGE_Rectangle(&def_size, &min_size, &max_size),
        SPA_FORMAT_VIDEO_framerate, SPA_POD_CHOICE_RANGE_Fraction(&def_rate, &min_rate, &max_rate));
    int res = pw_stream_connect(d.stream, PW_DIRECTION_INPUT, node,
                                PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS, params, 1);
    pw_thread_loop_unlock(loop);
    if (res < 0) { fprintf(stderr, "스트림 연결 실패: %s\n", spa_strerror(res)); return 2; }

    for (int i = 0; i < 500 && atomic_load(&g_count) == 0 && !atomic_load(&d.bad); i++) sleep_ms(10);
    if (atomic_load(&d.bad)) return 3;
    uint64_t n0 = atomic_load(&g_count);
    if (n0 == 0) { fprintf(stderr, "프레임이 안 와요 — 포털 스트림을 확인하세요\n"); return 2; }
    if (g_ring[(n0 - 1) % RING].magenta >= min_pixels) {
        fprintf(stderr, "띄우기 전부터 마젠타가 %u px 있어요 — 판정이 성립하지 않아요\n", g_ring[(n0 - 1) % RING].magenta);
        return 2;
    }

    // 띄운 명령의 표준 입출력은 /dev/null 로 돌린다. 런처 (`gio launch`) 가 띄운 터미널은 그 fd 를 물려받고
    // 측정 프로그램이 끝날 때까지 떠 있다 — 그러면 이 프로그램의 출력을 `$( … )` 로 받는 `compare-startup.sh`
    // 가 통로가 닫히기를 영원히 기다린다 (#756 · 2026-10-19 COSMIC 실측). 파일 동작은 띄우기 전에 만든다 —
    // 기준 시각 `t0` 에 그 비용이 섞이지 않게.
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);

    uint64_t t0 = now_ns();
    pid_t pid;
    int err = posix_spawnp(&pid, argv[cmd], &fa, NULL, &argv[cmd], environ);
    posix_spawn_file_actions_destroy(&fa);
    if (err != 0) { fprintf(stderr, "명령을 못 띄웠어요: %s\n", strerror(err)); return 2; }

    double found = -1;
    for (int spin = 0; spin < timeout_ms && found < 0; spin++) {
        sleep_ms(1);
        uint64_t n = atomic_load(&g_count);
        for (uint64_t k = n0; k < n; k++) {
            Frame f = g_ring[k % RING];
            if (f.arrive_ns > t0 && f.magenta >= min_pixels) { found = (double)(f.arrive_ns - t0) / 1e6; break; }
        }
        if (n - n0 >= RING) n0 = n - RING + 1; // 링이 한 바퀴 돌면 덮인 칸은 버린다
    }

    pw_thread_loop_lock(loop);
    pw_stream_destroy(d.stream);
    pw_thread_loop_unlock(loop);
    pw_thread_loop_stop(loop);
    if (found < 0) {
        printf("timeout_ms=%d frames_seen=%llu\n", timeout_ms, (unsigned long long)atomic_load(&g_count));
        return 1;
    }
    printf("startup_ms=%.2f\n", found);
    return 0;
}
