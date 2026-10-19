// key-to-screen_linux.c — 키를 누른 순간부터 그 창의 그림이 바뀐 프레임이 도착할 때까지를 앱 밖에서 잰다 (#756).
//
// macOS 판 (`tool/key-to-screen_macos.m`) 의 Linux 짝이다. 대상 터미널과 무관한 같은 잣대로 견준다.
//
//   1. xdg-desktop-portal ScreenCast 가 연 PipeWire 스트림 (화면 하나 · 커서 숨김) 을 받는다. 협상은
//      `tool/screencast-portal_linux.py` 가 하고, 이 도구는 그 fd 와 node id 를 받는다.
//   2. uinput 가상 키보드로 `a` 를 누른 순간의 `CLOCK_MONOTONIC` 을 적는다.
//   3. 그 뒤 **창 영역의 그림이 처음 바뀐 프레임이 이 프로세스에 도착한 시각**과의 차이가 키 → 화면이다.
//
// **macOS 와 재는 끝점이 다르다** (2026-10-13 사용자 결정). macOS 는 ScreenCaptureKit 이 프레임마다
// "창 서버가 표시한 시각" 을 준다. KWin 6.7.5 의 스크린캐스트는 그런 시각이 없다 — 화면 스트림은 자기
// 장면을 따로 그려 보내고, 붙는 `pts` 는 출력의 **지난** 표시 시각 (`renderLoop()->lastPresentationTimestamp()`,
// `outputscreencastsource.cpp`) 이다. 그래서 도착 시각을 쓴다. "앱이 그림을 넘기기까지 + KWin 이 캡처를
// 그려 보내는 비용" 이고, 한 DE 표 안에서 대상끼리 견주는 데 쓴다. OS 사이에 절대값을 견주지 않는다.
//
// - 화면이 안 바뀌면 프레임이 안 온다. 키가 창에 안 닿으면 `miss` 로 드러난다.
// - 해시는 창 영역 (`--rect`, 논리 좌표) 만 본다. 시계 · 다른 창의 변화를 키의 결과로 잡지 않게.
// - 포커스는 **창 가운데를 한 번 눌러** 잡는다 (`--click`). layer-shell 창 (TildaZ) 은 띄우기만 해서는
//   키보드 포커스를 안 받는다 (AGENTS.md 의 KDE 커서 절). 누르는 장치는 절대좌표 uinput 포인터라 화면
//   물리 px 과 1:1 이다 (`ydotool mousemove -a` 는 ABS 축이 없어 조용히 무시된다 — 같은 절).
// - 키보드와 포인터는 **장치를 따로** 만든다. 한 장치에 키와 ABS 축을 섞으면 libinput 이 어떻게 분류할지
//   보장이 없다.
//
//   cc -O2 -o /tmp/key-to-screen tool/key-to-screen_linux.c $(pkg-config --cflags --libs libpipewire-0.3)
//   tool/screencast-portal_linux.py -- /tmp/key-to-screen --pw-fd {fd} --node {node}
//       --rect X,Y,W,H --output OW,OH [--click] [--presses 30] [--gap-ms 250]
//
// `--rect` · `--output` 은 KWin 의 논리 좌표다 (`tool/kwin-window_linux.py`). 물리 배율은 받은 스트림
// 크기 ÷ `OW` 로 정한다 — 화면이 하나라고 본다.
//
// **`--find-marker`** 는 `--rect` 대신 창 영역을 캡처에서 찾는다 — 창 위치를 알려 주지 않는 데스크톱 (GNOME ·
// COSMIC) 용이다. 터미널 안 프로그램이 화면을 마젠타 (R>200 · G<80 · B>200) 로 칠해 두면, 그 픽셀들의 경계
// 상자를 영역으로 쓴다. 찾은 뒤 `--go-file` 을 만들어 알리면 프로그램이 화면을 지우고 키를 받기 시작한다.
// 이때 `--output` 은 물리 px 와 `--dpr 1` 이다 (`tool/gnome-screen_linux.py`).

#include <errno.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <linux/uinput.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <pipewire/pipewire.h>
#include <spa/debug/types.h>
#include <spa/param/video/format-utils.h>
#include <spa/param/video/type-info.h>
#include <spa/utils/result.h>

#define RING 512

typedef struct {
    uint64_t arrive_ns; // CLOCK_MONOTONIC
    uint64_t hash;
} Frame;

static Frame g_ring[RING];
static atomic_uint_fast64_t g_count = 0;

struct data {
    struct pw_thread_loop *loop;
    struct pw_stream *stream;
    struct spa_hook listener;
    struct spa_video_info_raw info;
    atomic_int ready; // 포맷이 정해져 크기를 안다
    atomic_int bad;   // 받은 스트림이 화면 전체가 아니다
    // 해시할 영역 (물리 px). 포맷이 정해진 뒤 (또는 표식을 찾은 뒤) 채운다.
    int rx, ry, rw, rh;
    // `--find-marker` — 1 인 동안 프레임마다 마젠타의 경계 상자를 아래 넷에 적는다. 영역을 정한 쪽이 0 으로 내린다.
    atomic_int marker;
    atomic_int mk_x0, mk_y0, mk_x1, mk_y1, mk_n;
    double lrect[4];
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
    // 밀린 버퍼는 버리고 가장 새것만 본다 (`video-play.c` 와 같은 방식). 도착 시각은 꺼낸 순간이다.
    while ((t = pw_stream_dequeue_buffer(d->stream)) != NULL) {
        if (b) pw_stream_queue_buffer(d->stream, b);
        b = t;
    }
    if (b == NULL) return;
    uint64_t arrive = now_ns();
    struct spa_buffer *buf = b->buffer;
    const uint8_t *base = buf->datas[0].data;
    if (base != NULL && atomic_load(&d->ready) && atomic_load(&d->marker)) {
        // 마젠타의 경계 상자 — 두 칸마다 하나씩 본다. 조건이 R · B 대칭이라 BGRx · RGBx 를 가리지 않는다.
        int W = (int)d->info.size.width, H = (int)d->info.size.height;
        int stride = buf->datas[0].chunk->stride;
        if (stride == 0) stride = W * 4;
        int x0 = W, y0 = H, x1 = -1, y1 = -1, n = 0;
        for (int y = 0; y < H; y += 2) {
            const uint8_t *row = base + (size_t)y * (size_t)stride;
            for (int x = 0; x < W; x += 2) {
                const uint8_t *p = row + (size_t)x * 4;
                if (p[0] > 200 && p[1] < 80 && p[2] > 200) {
                    n++;
                    if (x < x0) x0 = x;
                    if (x > x1) x1 = x;
                    if (y < y0) y0 = y;
                    if (y > y1) y1 = y;
                }
            }
        }
        atomic_store(&d->mk_x0, x0); atomic_store(&d->mk_y0, y0);
        atomic_store(&d->mk_x1, x1); atomic_store(&d->mk_y1, y1);
        atomic_store(&d->mk_n, n * 4);
        // 프레임이 오고 있다는 것만 알린다 (해시는 영역을 정한 뒤부터).
        uint64_t k = atomic_load(&g_count);
        g_ring[k % RING] = (Frame){.arrive_ns = arrive, .hash = 0};
        atomic_store(&g_count, k + 1);
    } else if (base != NULL && atomic_load(&d->ready)) {
        int stride = buf->datas[0].chunk->stride;
        if (stride == 0) stride = (int)d->info.size.width * 4;
        uint64_t x = 1469598103934665603ull; // FNV-1a
        for (int y = d->ry; y < d->ry + d->rh; y++) {
            const uint32_t *row = (const uint32_t *)(base + (size_t)y * (size_t)stride);
            for (int i = d->rx; i < d->rx + d->rw; i++) {
                x ^= row[i] & 0x00ffffffu; // BGRx 의 x 바이트는 값이 정해지지 않았다
                x *= 1099511628211ull;
            }
        }
        uint64_t n = atomic_load(&g_count);
        g_ring[n % RING] = (Frame){.arrive_ns = arrive, .hash = x};
        atomic_store(&g_count, n + 1);
    }
    pw_stream_queue_buffer(d->stream, b);
}

static int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

static void on_param_changed(void *userdata, uint32_t id, const struct spa_pod *param) {
    struct data *d = userdata;
    if (param == NULL || id != SPA_PARAM_Format) return;
    struct spa_video_info_raw info;
    uint32_t mt, mst;
    if (spa_format_parse(param, &mt, &mst) < 0 || mt != SPA_MEDIA_TYPE_video || mst != SPA_MEDIA_SUBTYPE_raw) return;
    if (spa_format_video_raw_parse(param, &info) < 0) return;
    d->info = info;
    int W = (int)info.size.width, H = (int)info.size.height;
    double s = (double)W / d->out_w;
    // **화면 전체인지 본다.** 권한 창에서 영역이나 창을 고르면 스트림이 그 크기로 오는데, 영역 좌표는 화면
    // 기준이라 다 어긋난다. 2026-10-13 첫 회차에서 1920x1080 스트림이 왔다 (화면은 2880x1800) — 그
    // 선택이 토큰으로 저장되면 다음 실행도 조용히 같은 것을 받는다.
    double want = d->out_w / d->out_h, got = (double)W / (double)H;
    if (got < want * 0.99 || got > want * 1.01 || (d->dpr > 0 && (W < d->out_w * d->dpr - 2 || W > d->out_w * d->dpr + 2))) {
        fprintf(stderr, "스트림이 %dx%d 예요 — 화면 전체 (%.0fx%.0f) 가 아니에요. 권한 창에서 화면 하나를 골라야 해요.\n",
                W, H, d->out_w * d->dpr, d->out_h * d->dpr);
        atomic_store(&d->bad, 1);
        return;
    }
    if (atomic_load(&d->marker)) {
        fprintf(stderr, "format %s %dx%d @ %u/%u · 영역은 표식으로 찾아요\n",
                spa_debug_type_find_short_name(spa_type_video_format, info.format), W, H,
                info.framerate.num, info.framerate.denom);
    } else {
        // 테두리 반올림에 걸리지 않게 안쪽으로 2 px 줄인다.
        int x0 = clampi((int)(d->lrect[0] * s) + 2, 0, W - 1);
        int y0 = clampi((int)(d->lrect[1] * s) + 2, 0, H - 1);
        int x1 = clampi((int)((d->lrect[0] + d->lrect[2]) * s) - 2, x0 + 1, W);
        int y1 = clampi((int)((d->lrect[1] + d->lrect[3]) * s) - 2, y0 + 1, H);
        d->rx = x0; d->ry = y0; d->rw = x1 - x0; d->rh = y1 - y0;
        fprintf(stderr, "format %s %dx%d @ %u/%u · scale %.3f · rect %d,%d %dx%d\n",
                spa_debug_type_find_short_name(spa_type_video_format, info.format), W, H,
                info.framerate.num, info.framerate.denom, s, d->rx, d->ry, d->rw, d->rh);
    }

    // 공유 메모리로 받는다 — DmaBuf 를 받으면 GPU 에서 읽어 와야 해서 도구가 커진다. 수정자 (modifier)
    // 를 안 주면 KWin 은 메모리 버퍼를 쓴다 (OBS `pipewire.c` 의 `buffer_types` 와 같은 갈림).
    uint8_t buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const struct spa_pod *params[1];
    params[0] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
        SPA_PARAM_BUFFERS_dataType, SPA_POD_CHOICE_FLAGS_Int((1 << SPA_DATA_MemPtr) | (1 << SPA_DATA_MemFd)));
    pw_stream_update_params(d->stream, params, 1);
    atomic_store(&d->ready, 1);
}

static void on_state_changed(void *userdata, enum pw_stream_state old, enum pw_stream_state state, const char *error) {
    (void)userdata; (void)old;
    if (state == PW_STREAM_STATE_ERROR) fprintf(stderr, "스트림 오류: %s\n", error ? error : "?");
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_state_changed,
    .param_changed = on_param_changed,
    .process = on_process,
};

// --- uinput ---

static void emit(int fd, int type, int code, int value) {
    struct input_event ev = {0};
    ev.type = (unsigned short)type;
    ev.code = (unsigned short)code;
    ev.value = value;
    if (write(fd, &ev, sizeof(ev)) != (ssize_t)sizeof(ev)) perror("uinput write");
}

static int make_keyboard(void) {
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) return -1;
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_KEYBIT, KEY_A);
    struct uinput_setup us = {0};
    us.id.bustype = BUS_VIRTUAL;
    snprintf(us.name, UINPUT_MAX_NAME_SIZE, "tildaz-bench keyboard");
    ioctl(fd, UI_DEV_SETUP, &us);
    ioctl(fd, UI_DEV_CREATE);
    return fd;
}

static int make_pointer(void) {
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) return -1;
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_KEYBIT, BTN_LEFT);
    ioctl(fd, UI_SET_EVBIT, EV_ABS);
    ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_POINTER);
    for (int axis = ABS_X; axis <= ABS_Y; axis++) {
        ioctl(fd, UI_SET_ABSBIT, axis);
        struct uinput_abs_setup a = {0};
        a.code = (unsigned short)axis;
        a.absinfo.minimum = 0;
        a.absinfo.maximum = 32767;
        ioctl(fd, UI_ABS_SETUP, &a);
    }
    struct uinput_setup us = {0};
    us.id.bustype = BUS_VIRTUAL;
    snprintf(us.name, UINPUT_MAX_NAME_SIZE, "tildaz-bench pointer");
    ioctl(fd, UI_DEV_SETUP, &us);
    ioctl(fd, UI_DEV_CREATE);
    return fd;
}

static void sleep_ms(int ms) {
    struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
    nanosleep(&ts, NULL);
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

int main(int argc, char *argv[]) {
    int pw_fd = -1, presses = 30, gap_ms = 250, click = 0, find_marker = 0;
    const char *go_file = NULL;
    uint32_t node = 0;
    struct data d = {0};
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--pw-fd") && i + 1 < argc) pw_fd = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--node") && i + 1 < argc) node = (uint32_t)strtoul(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--rect") && i + 1 < argc)
            sscanf(argv[++i], "%lf,%lf,%lf,%lf", &d.lrect[0], &d.lrect[1], &d.lrect[2], &d.lrect[3]);
        else if (!strcmp(argv[i], "--output") && i + 1 < argc) sscanf(argv[++i], "%lf,%lf", &d.out_w, &d.out_h);
        else if (!strcmp(argv[i], "--dpr") && i + 1 < argc) d.dpr = atof(argv[++i]);
        else if (!strcmp(argv[i], "--presses") && i + 1 < argc) presses = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--gap-ms") && i + 1 < argc) gap_ms = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--click")) click = 1;
        else if (!strcmp(argv[i], "--find-marker")) find_marker = 1;
        else if (!strcmp(argv[i], "--go-file") && i + 1 < argc) go_file = argv[++i];
    }
    if (pw_fd < 0 || node == 0 || (d.lrect[2] <= 0 && !find_marker) || d.out_w <= 0 || d.dpr <= 0) {
        fprintf(stderr, "쓰는 법: key-to-screen --pw-fd N --node ID {--rect X,Y,W,H | --find-marker [--go-file F]} --output OW,OH --dpr S [--click] [--presses N] [--gap-ms MS]\n");
        return 2;
    }

    // 장치를 먼저 꽂는다 — 새 입력 장치가 생기면 compositor 가 keymap 을 다시 보내는 구간이 있다
    // (AGENTS.md 의 uinput 함정). 스트림을 여는 동안 가라앉는다.
    int kb = make_keyboard();
    int ptr = click ? make_pointer() : -1;
    if (kb < 0 || (click && ptr < 0)) {
        fprintf(stderr, "/dev/uinput 을 못 열었어요: %s\n", strerror(errno));
        return 2;
    }

    atomic_store(&d.marker, find_marker);
    pw_init(&argc, &argv);
    d.loop = pw_thread_loop_new("key-to-screen", NULL);
    struct pw_context *ctx = pw_context_new(pw_thread_loop_get_loop(d.loop), NULL, 0);
    if (pw_thread_loop_start(d.loop) < 0) { fprintf(stderr, "PipeWire 루프 시작 실패\n"); return 2; }
    pw_thread_loop_lock(d.loop);
    struct pw_core *core = pw_context_connect_fd(ctx, fcntl(pw_fd, F_DUPFD_CLOEXEC, 5), NULL, 0);
    if (core == NULL) { pw_thread_loop_unlock(d.loop); fprintf(stderr, "PipeWire 연결 실패\n"); return 2; }
    d.stream = pw_stream_new(core, "tildaz key-to-screen",
                             pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY, "Capture",
                                               PW_KEY_MEDIA_ROLE, "Screen", NULL));
    pw_stream_add_listener(d.stream, &d.listener, &stream_events, &d);

    // 32 비트 RGB 넷을 받는다. 크기 · 주사율은 범위로 두어 KWin 이 정하게 한다 (OBS `build_format` 과 같은 모양).
    // **범위의 기본값은 화면의 물리 크기**로 준다. 아무 값 (예 1920x1080) 을 주면 KWin 이 그 크기를 골라
    // 화면을 늘려 보낸다 — 비율이 다르면 영역 좌표가 어긋난다.
    uint8_t buffer[2048];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const struct spa_pod *params[1];
    struct spa_rectangle def_size = SPA_RECTANGLE((uint32_t)(d.out_w * d.dpr + 0.5), (uint32_t)(d.out_h * d.dpr + 0.5)), min_size = SPA_RECTANGLE(1, 1),
                         max_size = SPA_RECTANGLE(16384, 16384);
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
    pw_thread_loop_unlock(d.loop);
    if (res < 0) { fprintf(stderr, "스트림 연결 실패: %s\n", spa_strerror(res)); return 2; }

    // 포맷 · 첫 프레임을 기다린다 (최대 5 초).
    for (int i = 0; i < 500 && atomic_load(&g_count) == 0 && !atomic_load(&d.bad); i++) sleep_ms(10);
    if (atomic_load(&d.bad)) return 3;
    if (atomic_load(&g_count) == 0) { fprintf(stderr, "프레임이 안 와요 — 포털 스트림을 확인하세요\n"); return 2; }

    if (find_marker) {
        // 표식 (창 넓이의 대부분) 이 보일 때까지 최대 5 초. 문턱은 화면의 1 % — 작은 마젠타 조각 (아이콘 등) 을
        // 창으로 잡지 않게.
        int W = (int)d.info.size.width, H = (int)d.info.size.height, found = 0, seen = 0;
        for (int i = 0; i < 500 && !found; i++) {
            sleep_ms(10);
            int n = atomic_load(&d.mk_n);
            if (n > seen) seen = n;
            found = n >= W * H / 100;
        }
        // 본 최대 픽셀 수와 경계를 함께 낸다 — 0 이면 창이 안 보였고, 문턱 아래면 칠해진 넓이가 모자라다
        // (#756 · 2026-10-19 GNOME — 작은 창을 이것으로 갈랐다).
        if (!found) {
            fprintf(stderr, "마젠타 표식을 못 찾았어요 — 창이 가려졌는지 봐요 (본 최대 %d px · 문턱 %d px · 경계 %d,%d~%d,%d)\n",
                    seen, W * H / 100, atomic_load(&d.mk_x0), atomic_load(&d.mk_y0), atomic_load(&d.mk_x1), atomic_load(&d.mk_y1));
            return 2;
        }
        sleep_ms(200); // 창이 자리를 잡고 다 칠해질 때까지
        // 두 칸마다 본 경계라 안쪽으로 4 px 줄인다.
        int x0 = atomic_load(&d.mk_x0) + 4, y0 = atomic_load(&d.mk_y0) + 4;
        int x1 = atomic_load(&d.mk_x1) - 4, y1 = atomic_load(&d.mk_y1) - 4;
        if (x1 <= x0 || y1 <= y0) { fprintf(stderr, "표식 영역이 비었어요\n"); return 2; }
        d.rx = x0; d.ry = y0; d.rw = x1 - x0; d.rh = y1 - y0;
        atomic_store(&d.marker, 0); // 영역을 다 적은 뒤에 내린다 — 프레임 쪽이 이것을 보고 해시로 넘어간다
        fprintf(stderr, "표식 영역 %d,%d %dx%d\n", d.rx, d.ry, d.rw, d.rh);
        if (go_file) {
            FILE *g = fopen(go_file, "w");
            if (g) fclose(g);
        }
    }

    if (click) {
        // 창 가운데 (물리 px) → 절대좌표 0..32767. libinput 이 그 범위를 출력 전체에 선형으로 펼친다.
        int W = (int)d.info.size.width, H = (int)d.info.size.height;
        double cx = d.rx + d.rw / 2.0, cy = d.ry + d.rh / 2.0;
        emit(ptr, EV_ABS, ABS_X, (int)(cx * 32767.0 / (W - 1)));
        emit(ptr, EV_ABS, ABS_Y, (int)(cy * 32767.0 / (H - 1)));
        emit(ptr, EV_SYN, SYN_REPORT, 0);
        sleep_ms(60);
        emit(ptr, EV_KEY, BTN_LEFT, 1);
        emit(ptr, EV_SYN, SYN_REPORT, 0);
        sleep_ms(30);
        emit(ptr, EV_KEY, BTN_LEFT, 0);
        emit(ptr, EV_SYN, SYN_REPORT, 0);
    }
    sleep_ms(800); // 포커스가 옮겨 가고 클릭이 그린 것이 가라앉을 때까지 (macOS 판과 같은 대기)

    double *lat = calloc((size_t)presses, sizeof(double));
    int got = 0, miss = 0;
    for (int i = 0; i < presses; i++) {
        sleep_ms(gap_ms);
        uint64_t n0 = atomic_load(&g_count);
        uint64_t base_hash = g_ring[(n0 - 1) % RING].hash;
        uint64_t t0 = now_ns();
        emit(kb, EV_KEY, KEY_A, 1);
        emit(kb, EV_SYN, SYN_REPORT, 0);
        emit(kb, EV_KEY, KEY_A, 0);
        emit(kb, EV_SYN, SYN_REPORT, 0);
        double found = -1;
        for (int spin = 0; spin < 500 && found < 0; spin++) { // 최대 0.5 초
            sleep_ms(1);
            uint64_t n = atomic_load(&g_count);
            for (uint64_t k = n0; k < n; k++) {
                Frame f = g_ring[k % RING];
                if (f.arrive_ns > t0 && f.hash != base_hash) {
                    found = (double)(f.arrive_ns - t0) / 1e6;
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

    pw_thread_loop_lock(d.loop);
    pw_stream_destroy(d.stream);
    pw_thread_loop_unlock(d.loop);
    pw_thread_loop_stop(d.loop);
    ioctl(kb, UI_DEV_DESTROY);
    close(kb);
    if (ptr >= 0) { ioctl(ptr, UI_DEV_DESTROY); close(ptr); }

    qsort(lat, (size_t)got, sizeof(double), cmp_double);
    double sum = 0;
    for (int a = 0; a < got; a++) sum += lat[a];
    if (got > 0)
        printf("samples=%d miss=%d mean_ms=%.2f median_ms=%.2f min_ms=%.2f max_ms=%.2f frames_seen=%llu\n", got, miss,
               sum / got, lat[got / 2], lat[0], lat[got - 1], (unsigned long long)atomic_load(&g_count));
    else
        printf("samples=0 miss=%d frames_seen=%llu\n", miss, (unsigned long long)atomic_load(&g_count));
    return 0;
}
