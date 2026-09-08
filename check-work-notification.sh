#!/bin/zsh
set -u

cd "$(dirname "$0")"
NOTICE_LOG=$(mktemp /tmp/pixelcat-work-notice.XXXXXX)
trap 'rm -f "$NOTICE_LOG"' EXIT

PIXELCAT_SIMWORKNOTICE=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$NOTICE_LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: clickable work notice simulation exited $STATUS"
    cat "$NOTICE_LOG" >&2
    exit 1
fi

if ! rg -q 'SIM WORK NOTICE claude=true codex=true codexNamed=true codexJump=true' "$NOTICE_LOG"; then
    print -u2 "FAIL: Claude/Codex work notices were not named, clickable, and targeted"
    cat "$NOTICE_LOG" >&2
    exit 1
fi

print "PASS: finished Claude and Codex work show named, clickable, targeted bubbles"
