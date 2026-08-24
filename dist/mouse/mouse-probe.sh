#!/usr/bin/env bash
# TUI mouse reporting 프로브 (#502).
#
# 터미널이 앱에게 보내는 마우스 바이트를 **그대로 화면에 찍는다.** 어떤 앱을 띄워
# "클릭이 먹네" 를 보는 것과 달리 어떤 시퀀스가 실제로 나갔는지 눈으로 확인해서
# `Cb` 값 · 좌표 · 뗌의 대소문자까지 판정할 수 있다.
#
# 사용법:
#   sh mouse-probe.sh [tracking] [format]        (종료: q 또는 Ctrl+C)
#     tracking: 9 (x10) | 1000 (normal) | 1002 (button, 기본) | 1003 (any)
#     format:   1005 (utf8) | 1006 (SGR, 기본) | 1015 (urxvt) | 1016 (SGR-pixels)
#
#   sh mouse-probe.sh              # ?1002 + ?1006 — 평소 쓰는 조합
#   sh mouse-probe.sh 1003         # hover 까지 (버튼 없는 이동)
#   sh mouse-probe.sh 1000         # motion 없음 — 누름/뗌만
#   sh mouse-probe.sh 9 1006       # x10 — 누름만, modifier 없음, 좌표 223 상한
#
# Windows 에서는 PowerShell 이 아니라 **Git Bash** 로 돌린다. TildaZ 의 PowerShell
# 탭에서 `bash <경로>/mouse-probe.sh` 로 실행해도 된다.
#
# **`stty` 를 쓰지 않는다.** 예전 판은 `stty -icanon -echo` 로 모드를 직접 바꾸고
# 트랩에서 되돌렸는데, 실기에서 두 가지가 깨졌다 (2026-08-24):
#   - 복구가 실패해도 `2>/dev/null` 이 삼켜서, 프로브를 나온 뒤 셸에 타이핑이 안
#     보였다 (echo 가 안 돌아왔다).
#   - 읽기를 `$(dd ...)` 명령 치환으로 해서 Ctrl+C 가 서브셸로 먼저 가고, 한 번에
#     빠져나오지 못했다.
# bash 의 `read -rsn1` 은 한 글자 읽기에 필요한 모드를 스스로 걸고 **스스로 되돌린다**.
# 터미널 상태를 우리가 소유하지 않으므로 복구 실패라는 실패 유형 자체가 없어진다.

TRACKING=${1:-1002}
FORMAT=${2:-1006}

cleanup() { printf '\033[?%s;%sl\n' "$TRACKING" "$FORMAT"; }
trap 'cleanup; exit 130' INT TERM
trap cleanup EXIT

printf '\033[?%s;%sh' "$TRACKING" "$FORMAT"

cat <<TXT
=================== #502 mouse probe ===================
tracking = ?$TRACKING    format = ?$FORMAT

^[ 는 ESC. 좌표는 1-based (맨 왼쪽 위 칸 = 1;1).

  A1 클릭          -> ^[[<0;C;R M  그리고  ^[[<0;C;R m  (뗌은 소문자)
  A2 드래그        -> ^[[<32;C;R M  (칸이 바뀔 때만)
  A3 Ctrl+클릭     -> Cb 16      (Alt 8 / Shift 4)
  A4 휠            -> 64 (위) / 65 (아래)
  A5 가운데 클릭   -> Cb 1       (탭이 생기거나 닫히면 버그)
  A6 Shift+드래그  -> 출력 0건   (우리 selection + 자동 복사)
  A7 우클릭        -> 출력 0건   (paste 유지)
  A8 우클릭 드래그 -> 출력 0건   (오른쪽은 motion 도 안 보낸다)
  A9 가운데 드래그 -> Cb 33      (1 + 32)

종료: q 또는 Ctrl+C
   탭바 hover 를 보려면 먼저 Ctrl+Shift+T 로 탭을 2개 이상 만든다
   (탭바는 탭 2개부터 그려진다).
========================================================

TXT

# `-r` 백슬래시 그대로, `-s` echo 없음, `-n1` 한 글자. 읽은 글자가 없으면 (EOF)
# 루프가 끝난다.
while IFS= read -rsn1 c; do
  case "$c" in
    q)      break ;;                     # 마우스 보고에 없는 글자라 종료 키로 안전
    $'\e')  printf '^[' ;;               # ESC — `cat -v` 와 같은 표기
    M|m)    printf '%s\n' "$c" ;;        # 보고가 끝나는 자리 — 여기서 줄을 나눈다
    *)      printf '%s' "$c" ;;
  esac
done
