#!/bin/zsh
# กดเปิดงาน ต้องไปห้องเดิมใน Claude (code/continue) ไม่ใช่ resume ที่สร้างห้องใหม่
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

rg -q 'SIM OPEN ROUTE claude=sessionLink continue=true blocked=focusApp warp=deepLink app=focusApp plain=folder' "$LOG" || {
    print -u2 "FAIL: wrong route back to a task"
    cat "$LOG" >&2
    exit 1
}

print "PASS: Claude tasks open the existing room, fall back to the app when the link is blocked, and keep tab deep links"
