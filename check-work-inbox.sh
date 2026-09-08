#!/bin/zsh
set -u

cd "$(dirname "$0")"
SESSION_FIXTURE=$(mktemp -d /tmp/pixelcat-work-inbox.XXXXXX)
CODEX_FIXTURE=$(mktemp -d /tmp/pixelcat-codex-inbox.XXXXXX)
CODEX_STATE="$CODEX_FIXTURE/state.sqlite"
CODEX_HISTORY="$CODEX_FIXTURE/history.sqlite"
INBOX_LOG=$(mktemp /tmp/pixelcat-work-inbox-log.XXXXXX)
trap 'rm -rf "$SESSION_FIXTURE" "$CODEX_FIXTURE"; rm -f "$INBOX_LOG"' EXIT

NOW=$(date +%s)
print -r -- "{\"ctx_pct\": 72.0, \"state\": \"input\", \"msg\": \"เลือกฐานข้อมูล\", \"at\": $NOW, \"cwd\": \"/tmp\", \"dir\": \"backend\"}" > "$SESSION_FIXTURE/waiting"
print -r -- "{\"ctx_pct\": 34.0, \"state\": \"working\", \"msg\": \"\", \"at\": $((NOW - 1)), \"cwd\": \"/tmp\", \"dir\": \"frontend\"}" > "$SESSION_FIXTURE/working"
print -r -- "{\"ctx_pct\": 51.0, \"state\": \"fail\", \"msg\": \"test failed\", \"at\": $((NOW - 2)), \"cwd\": \"/tmp\", \"dir\": \"api\"}" > "$SESSION_FIXTURE/failed"

sqlite3 "$CODEX_STATE" "CREATE TABLE threads (id TEXT, name TEXT, title TEXT, cwd TEXT, updated_at INTEGER, archived INTEGER, preview TEXT, thread_source TEXT); INSERT INTO threads VALUES ('codex-active', 'ปรับกล่องงาน', '', '/tmp/pixel-cat', $NOW, 0, 'preview', 'user'); INSERT INTO threads VALUES ('codex-done', 'ทดสอบแอนิเมชัน', '', '/tmp/pixel-cat', $((NOW - 3)), 0, 'preview', 'user');"
sqlite3 "$CODEX_HISTORY" "CREATE TABLE thread_turns (thread_id TEXT, status TEXT, rollout_ordinal INTEGER); INSERT INTO thread_turns VALUES ('codex-active', 'inProgress', 1); INSERT INTO thread_turns VALUES ('codex-done', 'completed', 1);"

PIXELCAT_SESSIONS="$SESSION_FIXTURE" PIXELCAT_CODEX_STATE="$CODEX_STATE" \
PIXELCAT_CODEX_HISTORY="$CODEX_HISTORY" PIXELCAT_SIMWORKINBOX=1 \
    ./PixelCat.app/Contents/MacOS/PixelCat >"$INBOX_LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: smart work inbox simulation exited $STATUS"
    cat "$INBOX_LOG" >&2
    exit 1
fi

if ! rg -q 'SIM WORK INBOX separated=true codex=true claude=true jump=true counts=true menu=true badge=true' "$INBOX_LOG"; then
    print -u2 "FAIL: work inbox did not separate Codex and Claude Code correctly"
    cat "$INBOX_LOG" >&2
    exit 1
fi

print "PASS: smart work inbox separates Codex and Claude Code with clickable Codex tasks"
