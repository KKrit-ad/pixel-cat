#!/bin/zsh
# เสียงเหมียว: ถอด WAV ที่ฝังไว้ได้ครบ, กันเสียงรัว, ดังเบา ๆ ตอน AI ทำงานเสร็จ, ปิดได้ และเงียบเองตอนโฟกัส
set -u
set -e

cd "$(dirname "$0")"

rg -q 'PIXELCAT_SIMVOICE' Sources || {
    print -u2 "FAIL: missing cat voice simulation"
    exit 1
}
rg -q 'let CAT_VOICE_WAV' Sources || {
    print -u2 "FAIL: missing embedded cat voice data"
    exit 1
}

LOG=$(mktemp /tmp/pixelcat-voice.XXXXXX)
trap 'rm -f "$LOG"' EXIT

PIXELCAT_SIMVOICE=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: cat voice simulation exited $STATUS"
    cat "$LOG" >&2
    exit 1
fi

rg -q 'SIM VOICE assets=true play=true throttle=true mute=true off=true log=true focus=true done=true' "$LOG" || {
    print -u2 "FAIL: cat voice assets, throttling, mute or focus behavior is wrong"
    cat "$LOG" >&2
    exit 1
}

print "PASS: cat voice plays, throttles, chimes once when AI work finishes, respects the menu toggle, and goes quiet in focus"
