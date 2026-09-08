#!/bin/zsh
set -u

cd "$(dirname "$0")"
TRANSITION_LOG=$(mktemp /tmp/pixelcat-animation-transitions.XXXXXX)
trap 'rm -f "$TRANSITION_LOG"' EXIT

PIXELCAT_SIMTRANSITIONS=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$TRANSITION_LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: transition simulation exited $STATUS"
    cat "$TRANSITION_LOG" >&2
    exit 1
fi

if ! rg -q 'SIM TRANSITIONS settleBridge=true settleReached=true jumpBridge=true jumpReached=true reducedDirect=true productionPaths=true' "$TRANSITION_LOG"; then
    print -u2 "FAIL: poses still cut directly without anticipation/settle frames"
    cat "$TRANSITION_LOG" >&2
    exit 1
fi

print "PASS: locomotion settles before sitting and jumps use a one-shot anticipation frame"
