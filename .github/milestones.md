# TildaZ 버전 히스토리 (개인 메모)

큰 버전이 바뀔 때마다 무엇이 달라졌는지 한 줄로 적어 둔 개인 기록. 공식 문서가 아니라
"어떤 순서로 자랐는지" 를 혼자 떠올리기 위한 메모라서 `.github/` 에 둔다.

| 버전 | 날짜 | 내용 |
|---|---|---|
| 0.0.1 | 2026-04-02 | 첫 커밋. Windows 용 Quake-style 드롭다운 터미널 |
| 0.1.0 | 2026-04-04 | 렌더링 품질과 속도 개선 |
| 0.2.0 | 2026-04-06 | 렌더링 엔진 교체하여 Windows Terminal 과 동등한 텍스트 렌더링 품질 달성 |
| 0.3.0 | 2026-05-04 | macOS 지원 |
| 0.4.0 | 2026-05-10 | Windows 를 macOS 수준으로 개선, 모듈 공통화 |
| 0.5.0 | 2026-06-21 | Linux 지원 |
| 0.6.0 | 2026-07-12 | Multiple config, multiple instance 지원 |
| 0.7.0 | 2026-08-02 | 탭바 예쁘게. Linux GPU 렌더링 추가 |
| 0.8.0 | 2026-08-09 | 텍스트 속성 (밑줄 · 취소선 · blink · italic/bold face) 구현. 새 탭이 현재 디렉토리에서 시작. cluster 렌더 성능 |

## 기록과 대조한 근거 (2026-08-03)

기억을 태그 · 커밋 · 릴리즈 노트와 맞춰 본 결과. 대부분 일치했고 두 곳을 고쳤다.

- **0.0.1** — 첫 커밋 `Initial project scaffold: Zig 0.15.2 + tildaz skeleton`, 이어서
  ConPTY backend + ghostty-vt 통합.
- **0.1.0** — `GDI → DirectWrite 래스터라이저 마이그레이션`, `OpenGL 3.3 셰이더 기반
  ClearType 서브픽셀 렌더링으로 전면 전환`, `대용량 출력 성능 최적화`, `렌더 스로틀`.
- **0.2.0** — 태그 커밋이 `Merge pull request #68 from ensky0/d3d11-cleartype-pipeline`.
- **0.3.0** — 릴리즈 노트: *"macOS officially shipped, Windows feature parity"*.
- **0.4.0** — 릴리즈 노트: *"cross-platform unification + Windows IME parity with macOS"*.
  `tab_layout.zig` / `tab_actions.zig` + `Host` 인터페이스로 합치며 중복 400줄 제거.
  → 처음 기억한 "macOS 개선" 은 방향이 반대였다. **Windows 를 macOS 수준으로 끌어올린**
  릴리즈다.
- **0.5.0** — 릴리즈 노트: *"Linux support arrives"*. GTK / Qt 없는 직접 Wayland client.
- **0.6.0** — 릴리즈 노트: *"Independent drop-down instances, each with its own config
  and hotkey"*.
- **0.7.0** — 릴리즈 노트 헤드라인은 *"GPU rendering on Linux, and a command menu in
  every window"*. 탭바 시각 (연속 띠 + amber 밑줄) 은 §"Tab bar and tab titles" 항목.
  → 처음 기억에 **Linux GPU 렌더링**이 빠져 있었다.

각 버전의 상세는 `dist/release-notes/vX.Y.Z.md` 와 GitHub Releases 에 있다.
