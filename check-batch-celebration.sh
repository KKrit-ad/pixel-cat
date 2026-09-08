#!/bin/zsh
set -u

cd "$(dirname "$0")"
BATCH_LOG=$(mktemp /tmp/pixelcat-batch-celebration.XXXXXX)
trap 'rm -f "$BATCH_LOG"' EXIT

PIXELCAT_SIMBATCHDONE=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$BATCH_LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: batch completion simulation exited $STATUS"
    cat "$BATCH_LOG" >&2
    exit 1
fi

if ! rg -q 'SIM BATCH DONE grouped=true stars=true once=true targets=true' "$BATCH_LOG"; then
    print -u2 "FAIL: simultaneous completions did not create one targeted star celebration"
    cat "$BATCH_LOG" >&2
    exit 1
fi

print "PASS: simultaneous completions create one star celebration targeting the latest task"
