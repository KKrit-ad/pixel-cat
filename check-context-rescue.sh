#!/bin/zsh
set -eu

cd "$(dirname "$0")"
LOG=$(mktemp /tmp/pixelcat-context-rescue.XXXXXX)
trap 'rm -f "$LOG"' EXIT

rg -q '"rescuePack".*Pose\(start: 55, count: 3' Sources main.swift || {
    print -u2 "FAIL: missing generated Context Rescue packing pose"
    exit 1
}
rg -q '"rescueReady".*Pose\(start: 58, count: 1' Sources main.swift || {
    print -u2 "FAIL: missing stable Context Rescue ready pose"
    exit 1
}

PIXELCAT_SIMCONTEXTRESCUE=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )) || ! rg -q 'SIM CONTEXT RESCUE threshold=true once=true packed=true handoff=true codexNew=true claudeNew=true focusDeferred=true reset=true superseded=true detail=true' "$LOG"; then
    print -u2 "FAIL: Context Rescue behavior"
    cat "$LOG" >&2
    exit 1
fi

print "PASS: Context Rescue packs one actionable handoff and opens a fresh Codex or Claude task"
