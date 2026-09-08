#!/bin/zsh
# กดเปิดงานที่ยังเปิดอยู่ ต้องสลับไปหาห้องเดิม ไม่ใช่ resume จนได้ห้องซ้ำ
set -u
set -e

cd "$(dirname "$0")"

LOG=$(mktemp /tmp/pixelcat-open-route.XXXXXX)
trap 'rm -f "$LOG"' EXIT

PIXELCAT_SIMOPENROUTE=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: open route simulation exited $STATUS"
    cat "$LOG" >&2
    exit 1
fi

rg -q 'SIM OPEN ROUTE alive=focusApp gone=resume warp=deepLink plain=folder' "$LOG" || {
    print -u2 "FAIL: wrong route back to a task"
    cat "$LOG" >&2
    exit 1
}

print "PASS: live rooms get focused, closed rooms resume, tab deep links still win"
