#!/bin/zsh
set -u

cd "$(dirname "$0")"
LOG=$(mktemp /tmp/pixelcat-task-shepherd.XXXXXX)
trap 'rm -f "$LOG"' EXIT

rg -q '"point".*Pose\(start: 47, count: 4' Sources main.swift || {
    print -u2 "FAIL: missing generated pointing pose"
    exit 1
}

PIXELCAT_SIMSHEPHERD=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )) || ! rg -q 'SIM SHEPHERD direction=true walked=true pointed=true clickable=true focusDeferred=true' "$LOG"; then
    print -u2 "FAIL: task shepherd simulation"
    cat "$LOG" >&2
    exit 1
fi

print "PASS: cat shepherds toward attention-required tasks and keeps Focus mode intact"
