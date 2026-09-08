#!/bin/zsh
set -u

cd "$(dirname "$0")"
MOTION_LOG=$(mktemp /tmp/pixelcat-motion-levels.XXXXXX)
trap 'rm -f "$MOTION_LOG"' EXIT

PIXELCAT_SIMMOTIONLEVELS=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$MOTION_LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: motion level simulation exited $STATUS"
    cat "$MOTION_LOG" >&2
    exit 1
fi

if ! rg -q 'SIM MOTION LEVELS calm=true normal=true playful=true reduce=true calmBehavior=true noAutoDescend=true reducedPetting=true cancelledActive=true climbingCancelled=true persisted=true' "$MOTION_LOG"; then
    print -u2 "FAIL: motion levels, Calm behavior, or Reduce Motion particle suppression are incomplete"
    cat "$MOTION_LOG" >&2
    exit 1
fi

print "PASS: motion levels persist and Calm/Reduce Motion suppress energetic autonomous movement and particles"
