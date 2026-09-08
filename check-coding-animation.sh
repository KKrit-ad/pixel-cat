#!/bin/zsh
# กิจกรรมแก้โค้ดต้องขับแอนิเมชันพิมพ์จริงและไม่รบกวน Focus/Reduce Motion
set -u
set -e

cd "$(dirname "$0")"

rg -q '"coding".*Pose\(start: 78, count: 4' Sources main.swift || {
    print -u2 "FAIL: missing four-frame coding animation"
    exit 1
}

python3 check-sprite-clarity.py >/dev/null
swift -module-cache-path /tmp/pixel-cat-swift-cache check-sprite-halo.swift cat-sheet.png >/dev/null

rg -q 'SIM CODING classify=' Sources main.swift || {
    print -u2 "FAIL: missing end-to-end coding activity simulation"
    exit 1
}

LOG=$(mktemp /tmp/pixelcat-coding-animation.XXXXXX)
trap 'rm -f "$LOG"' EXIT
PIXELCAT_SIMCODING=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: coding animation simulation exited $STATUS"
    cat "$LOG" >&2
    exit 1
fi

if ! rg -q 'SIM CODING classify=true codex=true claude=true pose=true tail=true transition=true focus=true reduced=true shadow=true' "$LOG"; then
    print -u2 "FAIL: real edit signals did not drive the complete coding animation behavior"
    cat "$LOG" >&2
    exit 1
fi

print "PASS: real Codex and Claude edits drive the four-frame coding animation"
