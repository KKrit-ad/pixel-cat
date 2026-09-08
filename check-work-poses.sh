#!/bin/zsh
set -u

cd "$(dirname "$0")"
SESSION_FIXTURE=$(mktemp -d /tmp/pixelcat-work-poses.XXXXXX)
POSE_LOG=$(mktemp /tmp/pixelcat-work-poses-log.XXXXXX)
trap 'rm -rf "$SESSION_FIXTURE"; rm -f "$POSE_LOG"' EXIT

NOW=$(date +%s)
print -r -- "{\"ctx_pct\": 31.0, \"state\": \"working\", \"msg\": \"\", \"at\": $((NOW - 180)), \"cwd\": \"/tmp/pixelcat-does-not-exist\", \"dir\": \"long-running\"}" > "$SESSION_FIXTURE/working"

PIXELCAT_SESSIONS="$SESSION_FIXTURE" \
PIXELCAT_CODEX_STATE="$SESSION_FIXTURE/no-state.sqlite" \
PIXELCAT_CODEX_HISTORY="$SESSION_FIXTURE/no-history.sqlite" \
PIXELCAT_SIMWORKPOSES=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$POSE_LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: meaningful work pose simulation exited $STATUS"
    cat "$POSE_LOG" >&2
    exit 1
fi

if ! rg -q 'SIM WORK POSES watching=true quiet=true once=true reset=true' "$POSE_LOG"; then
    print -u2 "FAIL: long-running work did not produce one quiet watching pose"
    cat "$POSE_LOG" >&2
    exit 1
fi

print "PASS: long-running work produces one quiet watching pose and resets with state"
