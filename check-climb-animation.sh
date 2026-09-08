#!/bin/zsh
set -u

cd "$(dirname "$0")"
SIM_LOG=$(mktemp /tmp/pixelcat-climb.XXXXXX)
trap 'rm -f "$SIM_LOG"' EXIT

PIXELCAT_SIMTEST=climb ./PixelCat.app/Contents/MacOS/PixelCat >"$SIM_LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: climb simulation exited $STATUS"
    cat "$SIM_LOG" >&2
    exit 1
fi

if ! rg -q 'ปีนเสร็จ:.*ยืนบน=ขอบหน้าต่าง' "$SIM_LOG"; then
    print -u2 "FAIL: cat did not finish on the simulated ledge"
    cat "$SIM_LOG" >&2
    exit 1
fi

print "PASS: four-frame climb reached the simulated ledge"
