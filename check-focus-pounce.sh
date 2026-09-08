#!/bin/zsh
set -u

cd "$(dirname "$0")"
POUNCE_LOG=$(mktemp /tmp/pixelcat-focus-pounce.XXXXXX)
EMPTY_SESSIONS=$(mktemp -d /tmp/pixelcat-pounce-sessions.XXXXXX)
trap 'rm -f "$POUNCE_LOG"; rm -rf "$EMPTY_SESSIONS"' EXIT

PIXELCAT_SESSIONS="$EMPTY_SESSIONS" PIXELCAT_SIMFOCUSPOUNCE=1 \
    ./PixelCat.app/Contents/MacOS/PixelCat >"$POUNCE_LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: fast nearby mouse movement interrupted focus mode"
    cat "$POUNCE_LOG" >&2
    exit 1
fi

if ! rg -q 'SIM FOCUS POUNCE pounced=false focus=true deferred=true resumed=true claudeDeferred=true claudeResumed=true claudeQueuePreserved=true' "$POUNCE_LOG"; then
    print -u2 "FAIL: cat did not stay seated or defer both session and Claude hook notices during focus mode"
    cat "$POUNCE_LOG" >&2
    exit 1
fi

print "PASS: focus ignores pounces and defers session and Claude hook notices until focus ends"
