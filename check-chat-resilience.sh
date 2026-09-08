#!/bin/zsh
# คำตอบจากสมองล้มต้องไม่เอา error เทคนิคดิบมาแสดง และต้องตอบ local อย่างเป็นธรรมชาติ
set -u
set -e

cd "$(dirname "$0")"

rg -q 'PIXELCAT_SIMCHATRESILIENCE' Sources main.swift || {
    print -u2 "FAIL: missing end-to-end chat failure simulation"
    exit 1
}

LOG=$(mktemp /tmp/pixelcat-chat-resilience.XXXXXX)
trap 'rm -f "$LOG"' EXIT

PIXELCAT_SIMCHATRESILIENCE=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: chat resilience simulation exited $STATUS"
    cat "$LOG" >&2
    exit 1
fi

rg -q 'SIM CHAT RESILIENCE claudeQuota=true manusMissing=true rawHidden=true localNatural=true' "$LOG" || {
    print -u2 "FAIL: provider failure leaked technical text or produced an unnatural fallback"
    cat "$LOG" >&2
    exit 1
}

print "PASS: Claude/Manus failures fall back naturally without leaking technical errors"
