# ghostty 패치

TildaZ 는 터미널 해석기로 ghostty 의 `libghostty-vt` 를 써요 (`build.zig.zon` 이 upstream 커밋에 pin).
이 폴더의 `patches/*.patch` 는 그 소스에 우리가 얹는 수정이에요
([#812](https://github.com/ensky0/tildaz/issues/812)).

## 어떻게 적용되나

- `zig build` 가 설정 단계에서 `zig-pkg/ghostty-*` 에 패치를 얹어요 (`build.zig` 의 `ghosttyDependency`,
  규칙은 [`build/vendor_patch.zig`](../../build/vendor_patch.zig)). 모든 빌드 (`test` · `check` · CI · 릴리즈) 가
  그 자리를 거쳐서 패치가 빠진 판이 나가지 않아요.
- 처음 한 번만 실제로 고치고 `ghostty: applied …` 한 줄을 찍어요. 그 뒤로는 이미 적용됐는지만 봐요.
- 패치는 줄 번호가 아니라 **글 내용**으로 맞춰요. 원본도 적용본도 아니면 빌드를 멈춰요.
- 이름 순서로 적용해요 (`0001-…`, `0002-…`).
- 패치가 고칠 수 있는 것은 **컴파일되는 소스 파일**뿐이에요. ghostty 의 `build.zig` 는 패치보다 먼저 돌아서 못 고쳐요.

fork 저장소를 따로 두지 않으려고 고른 방식이에요 (#812 ⑥). 패치가 쌓일수록 pin 을 올리기 어려워지니,
효과가 확인된 패치는 upstream 에 내는 길도 열어 둬요.

## 패치 목록

| 파일 | 무엇 | 효과 |
|---|---|---|
| [`0001-grapheme-capacity-from-filled-page.patch`](patches/0001-grapheme-capacity-from-filled-page.patch) | `PageList.grow` 가 새 page 의 grapheme 용량을 방금 가득 찬 page 의 사용량 (× 1.25) 으로 잡아요. byte 한도의 재사용 경로는 그 용량에 맞는 heap page 도 다시 써요. 원래는 새 page 마다 기본 용량에서 시작해 두 배씩 키우며 page 를 통째로 복사했어요 ([ghostty Discussion #10244](https://github.com/ghostty-org/ghostty/discussions/10244)). | 해석기만 · 미니PC Ryzen 7 8845HS: `cjk` 41.6 → 131.0 · `emoji_vs16` 45.5 → 80.7 · `zwj` 71.2 → 88.3 MiB/s ([#812 ⑦](https://github.com/ensky0/tildaz/issues/812#issuecomment-6279259175)) |

## ghostty pin 을 올릴 때

1. `./dist/update-ghostty.sh` 로 pin 을 올려요.
2. `zig build` 를 돌려요. 패치가 새 소스에 맞으면 그대로 얹히고 끝나요.
3. 안 맞으면 빌드가 패치 이름 · 파일 이름과 함께 멈춰요. 그때 `zig-pkg/ghostty-<새 해시>` 는 아직 원본이에요
   (적용기는 파일 전부가 맞을 때만 써요). 아래 "패치를 만들거나 고치는 법" 대로 다시 만들어요.
4. 패치의 ghostty 테스트를 돌려요 (아래).

## 패치를 만들거나 고치는 법

`zig-pkg/` 는 손으로 고치지 않아요. 원본을 복사해 그 복사본을 고치고, 원본과의 차이를 패치로 만들어요.

```sh
G=zig-pkg/ghostty-<해시>            # 원본 (패치 전)
cp -r "$G" /tmp/ghostty-edit         # 복사본을 고친다
# … /tmp/ghostty-edit/src/terminal/PageList.zig 를 고친다 …
diff -u --label a/src/terminal/PageList.zig --label b/src/terminal/PageList.zig \
    "$G/src/terminal/PageList.zig" /tmp/ghostty-edit/src/terminal/PageList.zig \
    > vendor/ghostty/patches/0001-grapheme-capacity-from-filled-page.patch
```

- 원본이 이미 패치된 상태면 (한 번 빌드한 checkout) `zig-pkg/ghostty-*` 를 지우고 `zig build --fetch` 로 다시 받아요.
- hunk 의 문맥이 파일 안에서 한 곳만 맞아야 해요. 같은 글이 두 곳에 있으면 적용기가 멈춰요.
- **같은 줄을 고치는 변경은 한 패치 파일에 합쳐요.** 적용기는 패치마다 글 내용으로 "적용 전 / 적용됨" 을 가려요.
  뒤 패치가 앞 패치가 고친 줄을 다시 고치면, 다 얹힌 소스에서 앞 패치가 "적용됨" 으로 보이지 않아 빌드가 멈춰요
  (2026-10-20 #812 ⑫ 실험에서 실제로 그랬어요). 패치 파일을 나누는 것은 서로 다른 곳을 고치는 변경끼리만이에요.
- 패치에 그 동작을 지키는 ghostty 쪽 테스트를 함께 넣어요. 0001 은 `PageList grow sizes the next page's graphemes from the filled page (TildaZ #812)` 예요.

### ghostty 테스트 돌리기

복사본에서 돌려요.

```sh
cd /tmp/ghostty-edit
zig build test-lib-vt -Demit-lib-vt=true -Dtest-filter=PageList --summary all
```

- Linux 에서 GCC 16 이 깔린 기기는 Debug 테스트가 링크 단계에서 실패해요 (`R_X86_64_PC64` — zig 자체 링커 문제, #232).
  복사본의 `build.zig` 에서 lib-vt 테스트 (`b.addTest(.{ .root_module = mod.vt, … })` 두 곳) 에 `.use_llvm = true` · `.use_lld = true` 를
  더해 돌려요. 이 수정은 패치에 넣지 않아요.
- `-Doptimize=ReleaseSafe` 로는 일부 테스트가 Debug 전용 검사를 요구해 컴파일되지 않아요.
- 2026-10-20 미니PC 에서 `kitty.graphics_image` 의 *"temporary file outside directory prefix is rejected"* 는 **원본에서도** 실패했어요.
  패치와 무관한 환경 문제로 봐요.

## CI

`pr-verify.yml` 은 `zig-pkg/` 를 캐시해요. 패치가 얹힌 채 캐시되므로 캐시 키에 `vendor/ghostty/patches/**` 를 넣었어요 —
패치를 고치면 원본부터 다시 받아요.
