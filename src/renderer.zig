//! Renderer dispatch — 호출처가 platform 별 그래픽스 API (D3D11 / Metal) 를
//! 직접 다루지 않게.
//!
//! 양쪽 platform 모두 `deinit` / `resize` / `renderTabBar` / `renderTerminal`
//! 을 노출 — host 는 `RendererBackend.<fn>` 한 줄로 호출. `init` 시그니처는
//! platform-specific 객체 (HWND vs CAMetalLayer + Metal device) 가 필요해 통일
//! 하지 않음 — host 의 platform-specific init 호출은 그대로 (각 host 가 자기
//! platform 의 backend type 만 알면 충분).
//!
//! 호출 순서: 항상 renderTabBar → renderTerminal. macOS 측 frame lifecycle
//! (drawable 획득 → present → commit) 이 두 fn 사이에 stateful — Windows 의
//! self.rtv / setupFrame 패턴과 같은 의도.

const builtin = @import("builtin");

pub const RendererBackend = switch (builtin.os.tag) {
    .windows => @import("renderer/windows.zig").D3d11Renderer,
    .macos => @import("renderer/macos.zig").MetalRenderer,
    else => UnsupportedRendererBackend,
};

/// Linux 등 미지원 플랫폼에서 빌드는 통과하도록 stub. 실제 호출 시 host
/// 가 Renderer 를 만들지 않으므로 fn body 는 도달 안 함.
const UnsupportedRendererBackend = struct {
    pub fn deinit(_: *UnsupportedRendererBackend) void {}
};
