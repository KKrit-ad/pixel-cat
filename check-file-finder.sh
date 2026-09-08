#!/bin/zsh
# ค้นไฟล์จากกล่องคุยแบบ local ไม่ส่ง path ไป provider
set -u
set -e

cd "$(dirname "$0")"

rg -q 'PIXELCAT_SIMFILEFINDER' Sources main.swift || {
    print -u2 "FAIL: missing local file finder simulation"
    exit 1
}

LOG=$(mktemp /tmp/pixelcat-file-finder.XXXXXX)
trap 'rm -f "$LOG"' EXIT

PIXELCAT_SIMFILEFINDER=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: local file finder simulation exited $STATUS"
    cat "$LOG" >&2
    exit 1
fi

rg -q 'SIM FILE FINDER parse=true ranked=true adapter=true private=true ui=true reveal=true menu=true located=true' "$LOG" || {
    print -u2 "FAIL: local file search, result UI, or Finder reveal behavior is wrong"
    cat "$LOG" >&2
    exit 1
}

print "PASS: local file search parses, ranks, shows ~/path location, and reveals results without calling AI"
