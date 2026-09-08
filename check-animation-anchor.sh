#!/bin/zsh
set -u

cd "$(dirname "$0")"
ANCHOR_LOG=$(mktemp /tmp/pixelcat-animation-anchor.XXXXXX)
trap 'rm -f "$ANCHOR_LOG"' EXIT

PIXELCAT_SIMANIMATIONANCHOR=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$ANCHOR_LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: animation anchor simulation exited $STATUS"
    cat "$ANCHOR_LOG" >&2
    exit 1
fi

if ! rg -q 'SIM ANIMATION ANCHOR locked=true bodyLocked=true feetLocked=true noSyntheticWobble=true correctedFrames=[1-9][0-9]*' "$ANCHOR_LOG"; then
    print -u2 "FAIL: body/foot anchors still drift or runtime adds synthetic cycle wobble"
    cat "$ANCHOR_LOG" >&2
    exit 1
fi

print "PASS: animation frames keep the body landmark locked to the same pixel anchor"
