#!/bin/zsh
set -u

cd "$(dirname "$0")"
LOG=$(mktemp /tmp/pixelcat-drag-courier.XXXXXX)
trap 'rm -f "$LOG"' EXIT

rg -q '"courier".*Pose\(start: 51, count: 4' Sources main.swift || {
    print -u2 "FAIL: missing generated courier pose"
    exit 1
}

PIXELCAT_SIMCOURIER=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )) || ! rg -q 'SIM COURIER registered=true sections=true safePayload=true animated=true redirected=true reduced=true dragToAsk=true autoPaste=true' "$LOG"; then
    print -u2 "FAIL: drag courier simulation"
    cat "$LOG" >&2
    exit 1
fi

print "PASS: Drag-to-Ask collects, redirects, and auto-pastes without auto-submitting"
