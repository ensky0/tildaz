#!/bin/bash
# #665 — zig 번들 float.h 에 macOS 27 SDK 의 __need_infinity_nan 규약을 넣는다
# (AGENTS.md `# macOS — zig 번들 float.h 가 SDK 와 어긋날 때` 절).
#
#   tool/zig-floath-patch_macos.sh            # 상태를 보고 필요하면 패치한다 (멱등)
#   tool/zig-floath-patch_macos.sh --check    # 상태만 보고 끝 (패치 필요 = 종료 코드 1)
#   tool/zig-floath-patch_macos.sh --revert   # 백업에서 원본으로 되돌린다
#
# 왜 필요한가: macOS 27 SDK 의 <math.h> 는 clang modules 가 켜지면 INFINITY · NAN 을
# 컴파일러의 <float.h> 에 위임한다 (__need_infinity_nan — LLVM 22 · Apple clang 21).
# zig 0.16.0 이 들고 있는 float.h 는 그 규약이 없고, 자체 INFINITY 정의도
# !defined(__STRICT_ANSI__) 안에 있어서 -std=c++23 에서는 나오지 않는다. zig 는 번들
# libc++ 를 정확히 그 -std=c++23 으로 빌드하므로 아무도 INFINITY 를 정의하지 않는다.
#
# ⚠️ 이 스크립트는 **zig 설치본을 고친다.** `brew upgrade zig` 하면 원본으로 돌아가니
# 그때 다시 돌린다. 새 zig 가 규약을 이미 갖고 있으면 스크립트가 스스로 알아보고
# "패치 불필요" 로 끝나므로, 업그레이드 뒤에는 일단 한 번 돌려 보면 된다.
set -u

MARKER='tildaz #665'

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

mode=patch
case "${1:-}" in
    "") ;;
    --check) mode=check ;;
    --revert) mode=revert ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
esac

# --- 대상 파일 찾기 -----------------------------------------------------------
lib_dir=$(zig env 2>/dev/null | sed -n 's/.*\.lib_dir = "\(.*\)".*/\1/p' | head -1)
if [ -z "$lib_dir" ]; then
    echo "FAIL: zig env 에서 lib_dir 을 읽지 못했다 (zig 가 PATH 에 있나?)" >&2
    exit 1
fi
FLOAT_H="$lib_dir/include/float.h"
BACKUP="$FLOAT_H.tildaz-orig"

if [ ! -f "$FLOAT_H" ]; then
    echo "FAIL: $FLOAT_H 이 없다" >&2
    exit 1
fi

echo "zig      : $(zig version)  ($lib_dir)"
echo "float.h  : $FLOAT_H"

# --- 현재 상태 판정 -----------------------------------------------------------
# 셋을 가른다: 이미 우리가 패치함 / zig 가 규약을 갖춤 (패치 불필요) / 패치 필요.
if grep -q "$MARKER" "$FLOAT_H"; then
    state=patched
elif grep -q '__need_infinity_nan' "$FLOAT_H"; then
    state=upstream
else
    state=needed
fi

case "$state" in
    patched)  echo "상태     : 이미 패치돼 있다" ;;
    upstream) echo "상태     : zig 가 __need_infinity_nan 을 스스로 구현한다 — 패치 불필요" ;;
    needed)   echo "상태     : 규약이 없다 — 패치가 필요하다" ;;
esac

# --- --revert ----------------------------------------------------------------
if [ "$mode" = revert ]; then
    if [ ! -f "$BACKUP" ]; then
        echo "FAIL: 백업이 없다 ($BACKUP). brew reinstall zig 로 되돌린다." >&2
        exit 1
    fi
    chmod u+w "$FLOAT_H" 2>/dev/null
    cp "$BACKUP" "$FLOAT_H" || exit 1
    chmod 444 "$FLOAT_H"
    rm -f "$BACKUP"
    echo "되돌렸다: $FLOAT_H"
    exit 0
fi

# --- --check -----------------------------------------------------------------
if [ "$mode" = check ]; then
    [ "$state" = needed ] && exit 1
    exit 0
fi

# --- 패치 --------------------------------------------------------------------
if [ "$state" != needed ]; then
    echo "할 일이 없다."
    exit 0
fi

# 삽입 자리를 확인한다 — 헤더 가드 **앞**이어야 한다. 가드 안에 넣으면 이미 include 된
# 뒤의 재요청 (SDK 가 __need_infinity_nan 을 켜고 다시 include 하는 경로) 이 가드에 막힌다.
guard_line=$(grep -n '^#ifndef __CLANG_FLOAT_H' "$FLOAT_H" | head -1 | cut -d: -f1)
if [ -z "$guard_line" ]; then
    echo "FAIL: __CLANG_FLOAT_H 가드를 못 찾았다 — zig 의 float.h 구조가 바뀌었다." >&2
    echo "      손으로 확인하고 이 스크립트를 고쳐라 (#665)." >&2
    exit 1
fi
echo "가드 줄  : $guard_line"

[ -f "$BACKUP" ] || { cp "$FLOAT_H" "$BACKUP" && chmod 444 "$BACKUP"; }

tmp=$(mktemp) || exit 1
head -n "$((guard_line - 1))" "$FLOAT_H" > "$tmp"
cat >> "$tmp" <<'EOF'
/* --- tildaz #665: macOS 27 SDK __need_infinity_nan protocol ----------------
 * The macOS 27 SDK's <math.h> delegates INFINITY and NAN to the compiler's
 * <float.h> when clang modules are enabled (LLVM 22 / Apple clang 21).  The
 * float.h bundled with zig 0.16.0 predates that protocol, and its own INFINITY
 * lives behind !defined(__STRICT_ANSI__), which -std=c++23 does not satisfy.
 * zig builds its bundled libc++ with exactly -std=c++23, so nothing defines
 * INFINITY and the build fails with:
 *     error: use of undeclared identifier 'INFINITY'
 *
 * This block answers the request before the include guard below, because the
 * SDK re-includes this header after the guard has already been taken.
 *
 * Drop this block once the bundled float.h implements the protocol itself.
 */
#if defined(__need_infinity_nan)
#undef INFINITY
#undef NAN
#define INFINITY (__builtin_inff())
#define NAN (__builtin_nanf(""))
#undef __need_infinity_nan
#else
/* --- tildaz #665 end: the original header follows ------------------------ */

EOF
tail -n "+$guard_line" "$FLOAT_H" >> "$tmp"
cat >> "$tmp" <<'EOF'

/* --- tildaz #665: closes the __need_infinity_nan branch opened above ----- */
#endif /* !defined(__need_infinity_nan) */
EOF

chmod u+w "$FLOAT_H" 2>/dev/null
cp "$tmp" "$FLOAT_H" || { echo "FAIL: 쓰기 실패" >&2; rm -f "$tmp"; exit 1; }
chmod 444 "$FLOAT_H"
rm -f "$tmp"
echo "패치했다 : $FLOAT_H  (백업 $BACKUP)"

# --- 검증 — 실제로 libc++ sub-compilation 이 도는 최소 재현 -------------------
probe=$(mktemp -d) || exit 1
printf '#include <random>\nint main(){std::mt19937 g(1);std::poisson_distribution<int> d(4.0);return d(g)&0;}\n' > "$probe/m.cpp"
echo "검증     : zig c++ -std=c++17 (libc++ 를 링크해 sub-compilation 을 태운다)"
if zig c++ -std=c++17 "$probe/m.cpp" -o "$probe/m" 2>"$probe/err"; then
    echo "RESULT   : PASS — libc++ 가 빌드된다"
    rm -rf "$probe"
    exit 0
fi
echo "RESULT   : FAIL — 아직 깨진다" >&2
head -12 "$probe/err" >&2
echo "         : 캐시가 남아 있으면 지우고 다시 본다 — rm -rf \"$(zig env | sed -n 's/.*\.global_cache_dir = \"\(.*\)\".*/\1/p' | head -1)/o\"" >&2
exit 1
