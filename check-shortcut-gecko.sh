#!/bin/zsh
# คีย์ลัดเปิดแชตได้จากทุกแอป และคลิกเฉพาะตัวกิ้งก่าแล้วทำให้หาย
set -u
set -e

cd "$(dirname "$0")"

rg -q 'PIXELCAT_SIMSHORTCUTGECKO' Sources main.swift || {
    print -u2 "FAIL: missing shortcut/gecko simulation"
    exit 1
}

LOG=$(mktemp /tmp/pixelcat-shortcut-gecko.XXXXXX)
trap 'rm -f "$LOG"' EXIT

PIXELCAT_SIMSHORTCUTGECKO=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: shortcut/gecko simulation exited $STATUS"
    cat "$LOG" >&2
    exit 1
fi

rg -q 'SIM SHORTCUT GECKO registered=true chat=true opaque=true transparent=true dismissed=true' "$LOG" || {
    print -u2 "FAIL: shortcut or gecko click behavior is wrong"
    cat "$LOG" >&2
    exit 1
}

print "PASS: Control-Option-C opens companion chat and clicking visible gecko pixels dismisses it"
