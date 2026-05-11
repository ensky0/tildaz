# Cross-Platform 통합 기록

이 문서는 예전 `CROSS_PLATFORM.md`의 긴 Phase 계획을 짧게 보관하는 archive다.
현재 구조 설명은 [ARCHITECTURE.md](ARCHITECTURE.md), 사용자 시각 동작 사양은
[SPEC.md](SPEC.md), 설정 schema는 [CONFIG.md](CONFIG.md)를 기준으로 본다.

## 상태

v0.4.1의 Phase 0-7 cross-platform unification은 완료됐다. 이후 발견된 후속
정리는 umbrella [#176](https://github.com/ensky0/tildaz/issues/176) 아래에서
#177-#185, #166으로 나눠 처리했고, v0.4.3에 포함한다.

| 범위 | 상태 | 기록 |
|---|---|---|
| v0.4.1 Phase 0-7 | 완료 | [#171](https://github.com/ensky0/tildaz/issues/171), [`v0.4.1.md`](dist/release-notes/v0.4.1.md) |
| v0.4.2 follow-up | 완료 | [#172](https://github.com/ensky0/tildaz/issues/172)-[#175](https://github.com/ensky0/tildaz/issues/175), [`v0.4.2.md`](dist/release-notes/v0.4.2.md) |
| v0.4.3 repository audit follow-up | 완료 | [#176](https://github.com/ensky0/tildaz/issues/176), [#166](https://github.com/ensky0/tildaz/issues/166), [#177](https://github.com/ensky0/tildaz/issues/177)-[#185](https://github.com/ensky0/tildaz/issues/185), [`v0.4.3.md`](dist/release-notes/v0.4.3.md) |

## 완료된 통합 축

| 영역 | 현재 source of truth |
|---|---|
| PTY API | `src/terminal.zig` wrapper + `terminal/windows/pty.zig` / `terminal/macos/pty.zig` |
| Renderer API | `src/renderer.zig` wrapper + `renderTabBar` / `renderTerminal` shared call shape |
| Tab layout / rename / drag | `src/tab_layout.zig`, `src/tab_interaction.zig`, `src/tab_actions.zig` |
| Selection behavior | `src/terminal_interaction.zig` |
| Config schema/defaults | `src/config.zig` |
| Font chain limit | `src/font/constants.zig` (`MAX_CHAIN = 8`) |
| Dialogs / user-visible messages | `src/dialog.zig`, `src/messages.zig` |
| Themes and TUI dark/light env | `src/themes.zig`, host extra-env builders |
| Autostart / log / paths | `src/autostart.zig`, `src/log.zig`, `src/paths.zig` |

## 남은 큰 축

| 항목 | 상태 |
|---|---|
| macOS Developer ID notarization | [#109](https://github.com/ensky0/tildaz/issues/109) — 현재 환경 한계로 ad-hoc signing |
| Config hot reload | [#170](https://github.com/ensky0/tildaz/issues/170) — 미시작 |
| Config schema 후속 정리 | [#118](https://github.com/ensky0/tildaz/issues/118) — 열림 |
| Linux host | 미시작. 현재 wrapper 구조상 host / renderer / font / dialog / autostart / log 구현 추가가 필요 |
| 스트레스 테스트 | 별도 이슈 필요. bulk output, resize storm, tab close under load, WSL/nvim/mouse, CJK/emoji 입력 회귀 |

## 보존 정책

완료된 Phase의 세부 계획과 결정 이력은 이 파일에 다시 길게 복사하지 않는다.
필요하면 GitHub issue와 과거 release note를 본다. 현재 코드 판단에 필요한
내용만 `ARCHITECTURE.md`, `SPEC.md`, `CONFIG.md`에 남긴다.
