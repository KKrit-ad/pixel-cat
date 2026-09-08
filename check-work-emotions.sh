#!/bin/zsh
set -u

cd "$(dirname "$0")"
EMOTION_LOG=$(mktemp /tmp/pixelcat-work-emotions.XXXXXX)
trap 'rm -f "$EMOTION_LOG"' EXIT

PIXELCAT_SIMWORKEMOTIONS=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$EMOTION_LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: work emotion was too subtle to see"
    cat "$EMOTION_LOG" >&2
    exit 1
fi

if ! rg -q 'SIM WORK EMOTIONS .*doneVisible=true .*doneSequence=true .*failNoShake=true .*failExpression=true' "$EMOTION_LOG"; then
    print -u2 "FAIL: completion/failure did not use the intended expressive, shake-free sequence"
    cat "$EMOTION_LOG" >&2
    exit 1
fi

print "PASS: completion uses anticipation/hop/settle and failure uses a shake-free sad expression"
