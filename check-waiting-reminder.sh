#!/bin/zsh
set -u

cd "$(dirname "$0")"
SESSION_FIXTURE=$(mktemp -d /tmp/pixelcat-waiting-reminder.XXXXXX)
REMINDER_LOG=$(mktemp /tmp/pixelcat-waiting-reminder-log.XXXXXX)
trap 'rm -rf "$SESSION_FIXTURE"; rm -f "$REMINDER_LOG"' EXIT

NOW=$(date +%s)
print -r -- "{\"ctx_pct\": 44.0, \"state\": \"input\", \"msg\": \"เลือกวิธีทำต่อ\", \"at\": $((NOW - 240)), \"cwd\": \"/tmp/pixelcat-does-not-exist\", \"dir\": \"waiting-project\"}" > "$SESSION_FIXTURE/waiting"

PIXELCAT_SESSIONS="$SESSION_FIXTURE" \
PIXELCAT_CODEX_STATE="$SESSION_FIXTURE/no-state.sqlite" \
PIXELCAT_CODEX_HISTORY="$SESSION_FIXTURE/no-history.sqlite" \
PIXELCAT_SIMWAITREMINDER=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$REMINDER_LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: waiting reminder simulation exited $STATUS"
    cat "$REMINDER_LOG" >&2
    exit 1
fi

if ! rg -q 'SIM WAIT REMINDER reminded=true once=true acknowledged=true reset=true' "$REMINDER_LOG"; then
    print -u2 "FAIL: an old waiting task was not reminded once, acknowledged, and reset"
    cat "$REMINDER_LOG" >&2
    exit 1
fi

print "PASS: old waiting work reminds once, acknowledges on open, and resets on state change"
