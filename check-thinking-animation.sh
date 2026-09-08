#!/bin/zsh
# วงจรตอบ AI ต้องสื่อสถานะครบและหยุดเองเมื่อได้คำตอบ/เกิดข้อผิดพลาด
set -u

cd "$(dirname "$0")"
LOG=$(mktemp /tmp/pixelcat-thinking.XXXXXX)
trap 'rm -f "$LOG" chat-input-snap.png chat-speech-snap.png' EXIT

rg -q '"think".*Pose\(start: 59, count: 4' Sources main.swift || {
    print -u2 "FAIL: missing four-frame thinking pose"
    exit 1
}
rg -q '"aha".*Pose\(start: 63, count: 2' Sources main.swift || {
    print -u2 "FAIL: missing two-frame answer pose"
    exit 1
}
python3 check-sprite-clarity.py >/dev/null || exit 1
swift -module-cache-path /tmp/pixel-cat-swift-cache check-sprite-halo.swift cat-sheet.png \
    >/dev/null || exit 1

PIXELCAT_SNAPCHAT=1 PIXELCAT_SIMTHINKING=1 \
    ./PixelCat.app/Contents/MacOS/PixelCat >"$LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: thinking animation simulation exited $STATUS"
    cat "$LOG" >&2
    exit 1
fi

if ! rg -q 'SIM THINKING listen=true dots=true long=true success=true failure=true reduced=true focus=true notice=true shadow=true stopped=true' "$LOG"; then
    print -u2 "FAIL: AI response animation did not cover its complete state cycle"
    cat "$LOG" >&2
    exit 1
fi

print "PASS: AI response animation covers listen, think, long wait, success, failure, Focus, Reduce Motion, and grounded shadows"
