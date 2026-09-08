#!/bin/zsh
set -u

cd "$(dirname "$0")"
FOCUS_LOG=$(mktemp /tmp/pixelcat-focus.XXXXXX)
EMPTY_SESSIONS=$(mktemp -d /tmp/pixelcat-focus-sessions.XXXXXX)
trap 'rm -f "$FOCUS_LOG"; rm -rf "$EMPTY_SESSIONS"' EXIT

PIXELCAT_SESSIONS="$EMPTY_SESSIONS" PIXELCAT_SIMFOCUS=1 \
    ./PixelCat.app/Contents/MacOS/PixelCat >"$FOCUS_LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: focus simulation exited $STATUS"
    cat "$FOCUS_LOG" >&2
    exit 1
fi

if ! rg -q 'SIM FOCUS rest=true finished=true status=true' "$FOCUS_LOG"; then
    print -u2 "FAIL: focus → rest → idle transition was incomplete"
    cat "$FOCUS_LOG" >&2
    exit 1
fi

print "PASS: focus timer entered rest and reset the menu-bar status"
