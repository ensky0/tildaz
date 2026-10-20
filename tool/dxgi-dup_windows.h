// dxgi-dup_windows.h — 화면 하나를 DXGI Desktop Duplication 으로 받는 작은 도우미 (#756).
//
// `tool/key-to-screen_windows.c` · `tool/startup-to-screen_windows.c` 가 함께 쓴다. macOS 의 ScreenCaptureKit ·
// Linux 의 portal ScreenCast 자리다.
//
// - 프레임의 시각은 `DXGI_OUTDUPL_FRAME_INFO.LastPresentTime` 이다. 문서: *"The time stamp of the last update of the
//   desktop image. The operating system calls the QueryPerformanceCounter function to obtain the value. A zero value
//   indicates that the desktop image was not updated since an application last called AcquireNextFrame."*
//   ([DXGI_OUTDUPL_FRAME_INFO](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/ns-dxgi1_2-dxgi_outdupl_frame_info)).
//   DWM 이 바탕 화면 그림을 바꾼 순간이라 macOS 의 "창 서버가 표시한 시각" 에 가깝다 (확인 필요 — 모니터에 실제로
//   나간 시각은 아니다). 측정기가 쓰는 QPC 와 같은 시계라 키를 보낸 순간과 바로 뺄 수 있다.
// - 그림에 마우스 커서는 들지 않는다 (커서는 따로 온다 — `PointerPosition`). 커서 움직임만 있는 프레임은
//   `LastPresentTime == 0` 이라 건너뛴다.
// - 프로세스가 **per-monitor DPI aware** 여야 좌표가 물리 px 로 맞는다. 부르는 쪽이 `dup_init` 전에 켠다.
// - `DXGI_ERROR_ACCESS_LOST` (모드 변경 · UAC 화면 등) 가 오면 다시 만든다.

#ifndef TZ_DXGI_DUP_WINDOWS_H
#define TZ_DXGI_DUP_WINDOWS_H

#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <stdint.h>
#include <stdio.h>

typedef struct {
    ID3D11Device *dev;
    ID3D11DeviceContext *ctx;
    IDXGIOutput1 *out;
    IDXGIOutputDuplication *dup;
    RECT desk;           // 이 출력의 바탕 화면 좌표 (물리 px)
    ID3D11Texture2D *stage; // CPU 로 읽을 사본. 크기는 `sw` x `sh`
    int sw, sh;
    int held;            // AcquireNextFrame 을 받고 아직 ReleaseFrame 하지 않았다
} Dup;

// 점 (물리 px · 바탕 화면 좌표) 이 든 출력을 고른다. 못 찾으면 첫 출력.
static int dup_init(Dup *d, int px, int py) {
    memset(d, 0, sizeof(*d));
    IDXGIFactory1 *f = NULL;
    if (FAILED(CreateDXGIFactory1(&IID_IDXGIFactory1, (void **)&f))) return 0;
    IDXGIAdapter1 *pick_a = NULL;
    IDXGIOutput *pick_o = NULL;
    IDXGIAdapter1 *a = NULL;
    for (UINT ai = 0; IDXGIFactory1_EnumAdapters1(f, ai, &a) != DXGI_ERROR_NOT_FOUND; ai++) {
        IDXGIOutput *o = NULL;
        for (UINT oi = 0; IDXGIAdapter1_EnumOutputs(a, oi, &o) != DXGI_ERROR_NOT_FOUND; oi++) {
            DXGI_OUTPUT_DESC od;
            IDXGIOutput_GetDesc(o, &od);
            RECT r = od.DesktopCoordinates;
            int hit = px >= r.left && px < r.right && py >= r.top && py < r.bottom;
            if (!pick_o || hit) {
                if (pick_o) { IDXGIOutput_Release(pick_o); IDXGIAdapter1_Release(pick_a); }
                pick_o = o; pick_a = a; IDXGIAdapter1_AddRef(a);
                d->desk = r;
                if (hit) break;
            } else {
                IDXGIOutput_Release(o);
            }
        }
        IDXGIAdapter1_Release(a);
        if (pick_o && px >= d->desk.left && px < d->desk.right && py >= d->desk.top && py < d->desk.bottom) break;
    }
    IDXGIFactory1_Release(f);
    if (!pick_o) return 0;
    // 출력을 가진 어댑터에서 장치를 만들어야 DuplicateOutput 이 된다 (그 함수 문서의 Remarks).
    D3D_FEATURE_LEVEL fl;
    HRESULT hr = D3D11CreateDevice((IDXGIAdapter *)pick_a, D3D_DRIVER_TYPE_UNKNOWN, NULL, 0, NULL, 0,
                                   D3D11_SDK_VERSION, &d->dev, &fl, &d->ctx);
    IDXGIAdapter1_Release(pick_a);
    if (FAILED(hr)) { fprintf(stderr, "D3D11CreateDevice 실패 0x%08lx\n", (unsigned long)hr); return 0; }
    hr = IDXGIOutput_QueryInterface(pick_o, &IID_IDXGIOutput1, (void **)&d->out);
    IDXGIOutput_Release(pick_o);
    if (FAILED(hr)) return 0;
    hr = IDXGIOutput1_DuplicateOutput(d->out, (IUnknown *)d->dev, &d->dup);
    if (FAILED(hr)) { fprintf(stderr, "DuplicateOutput 실패 0x%08lx\n", (unsigned long)hr); return 0; }
    return 1;
}

static void dup_release_frame(Dup *d) {
    if (d->held) { IDXGIOutputDuplication_ReleaseFrame(d->dup); d->held = 0; }
}

// 다음 프레임을 받아 `sx,sy,sw,sh` (이 출력 기준 물리 px) 영역을 `stage` 로 옮긴다.
//   1  그림이 바뀐 프레임 — `*t` 에 LastPresentTime (QPC)
//   0  시간 안에 바뀐 그림이 없다 (커서만 움직인 프레임 포함)
//  -1  실패
static int dup_next(Dup *d, UINT timeout_ms, int sx, int sy, int sw, int sh, LONGLONG *t) {
    dup_release_frame(d);
    DXGI_OUTDUPL_FRAME_INFO fi;
    IDXGIResource *res = NULL;
    HRESULT hr = IDXGIOutputDuplication_AcquireNextFrame(d->dup, timeout_ms, &fi, &res);
    if (hr == DXGI_ERROR_WAIT_TIMEOUT) return 0;
    if (hr == DXGI_ERROR_ACCESS_LOST) {
        IDXGIOutputDuplication_Release(d->dup);
        d->dup = NULL;
        if (FAILED(IDXGIOutput1_DuplicateOutput(d->out, (IUnknown *)d->dev, &d->dup))) return -1;
        return 0;
    }
    if (FAILED(hr)) return -1;
    d->held = 1;
    if (fi.LastPresentTime.QuadPart == 0) { IDXGIResource_Release(res); return 0; }
    ID3D11Texture2D *tex = NULL;
    hr = IDXGIResource_QueryInterface(res, &IID_ID3D11Texture2D, (void **)&tex);
    IDXGIResource_Release(res);
    if (FAILED(hr)) return -1;
    if (!d->stage || d->sw != sw || d->sh != sh) {
        if (d->stage) ID3D11Texture2D_Release(d->stage);
        D3D11_TEXTURE2D_DESC td;
        ID3D11Texture2D_GetDesc(tex, &td);
        td.Width = (UINT)sw; td.Height = (UINT)sh; td.MipLevels = 1; td.ArraySize = 1;
        td.Usage = D3D11_USAGE_STAGING; td.BindFlags = 0; td.CPUAccessFlags = D3D11_CPU_ACCESS_READ; td.MiscFlags = 0;
        td.SampleDesc.Count = 1; td.SampleDesc.Quality = 0;
        if (FAILED(ID3D11Device_CreateTexture2D(d->dev, &td, NULL, &d->stage))) { ID3D11Texture2D_Release(tex); return -1; }
        d->sw = sw; d->sh = sh;
    }
    D3D11_BOX box = { (UINT)sx, (UINT)sy, 0, (UINT)(sx + sw), (UINT)(sy + sh), 1 };
    ID3D11DeviceContext_CopySubresourceRegion(d->ctx, (ID3D11Resource *)d->stage, 0, 0, 0, 0, (ID3D11Resource *)tex, 0, &box);
    ID3D11Texture2D_Release(tex);
    *t = fi.LastPresentTime.QuadPart;
    return 1;
}

// `stage` 를 읽는다. 바탕 화면 그림은 `DXGI_FORMAT_B8G8R8A8_UNORM` 이다 (Desktop Duplication 문서).
static const uint8_t *dup_map(Dup *d, UINT *pitch) {
    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(ID3D11DeviceContext_Map(d->ctx, (ID3D11Resource *)d->stage, 0, D3D11_MAP_READ, 0, &m))) return NULL;
    *pitch = m.RowPitch;
    return (const uint8_t *)m.pData;
}

static void dup_unmap(Dup *d) { ID3D11DeviceContext_Unmap(d->ctx, (ID3D11Resource *)d->stage, 0); }

#endif
