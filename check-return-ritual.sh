#!/bin/zsh
# หายไปนานจึงต้อนรับ กลับเร็วไม่รบกวน
set -u
set -e

cd "$(dirname "$0")"

rg -q 'PIXELCAT_SIMRETURNRITUAL' Sources main.swift || {
    print -u2 "FAIL: missing return ritual simulation"
    exit 1
}

LOG=$(mktemp /tmp/pixelcat-return-ritual.XXXXXX)
trap 'rm -f "$LOG"' EXIT

PIXELCAT_SIMRETURNRITUAL=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: return ritual simulation exited $STATUS"
    cat "$LOG" >&2
    exit 1
fi

rg -q 'SIM RETURN RITUAL eligible=true early=false focus=true priority=true once=true summary=true animation=true clickable=true demo=true' "$LOG" || {
    print -u2 "FAIL: return ritual threshold behavior is wrong"
    cat "$LOG" >&2
    exit 1
}

print "PASS: return ritual has threshold, focus safety, prioritized summary, animation, link, and manual preview"
