#!/bin/zsh
# Smart Action Bubble ต้องให้ผู้ใช้ทำขั้นต่อไปจากการแจ้งเตือนได้ ไม่ใช่แค่เปิด task อย่างเดียว
set -u

cd "$(dirname "$0")"
LOG=$(mktemp /tmp/pixelcat-smart-action.XXXXXX)
trap 'rm -f "$LOG"' EXIT

PIXELCAT_SIMWORKNOTICE=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: smart action simulation exited $STATUS"
    cat "$LOG" >&2
    exit 1
fi

if ! rg -q 'SIM SMART ACTION doneCard=true summaryCopied=true summaryOpened=true' "$LOG"; then
    print -u2 "FAIL: completed work did not expose and perform its smart actions"
    cat "$LOG" >&2
    exit 1
fi

if ! rg -q 'SIM SMART ACTION STATUS failedCard=true helpCopied=true helpOpened=true waitingCard=true snoozed=true' "$LOG"; then
    print -u2 "FAIL: failed and waiting work did not expose their status-specific actions"
    cat "$LOG" >&2
    exit 1
fi

print "PASS: smart action cards offer Open, Summarize, Help Fix, and Snooze for the right work states"
