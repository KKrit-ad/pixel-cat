#!/bin/zsh
# ตรวจนโยบาย Cinema Mode โดยไม่ต้องเข้า Full Screen จริง
set -euo pipefail

cd "$(dirname "$0")"

BIN=$(mktemp /tmp/pixelcat-cinema-mode.XXXXXX)
LOG=$(mktemp /tmp/pixelcat-cinema-mode-log.XXXXXX)
trap 'rm -f "$BIN" "$LOG"' EXIT

swiftc -module-cache-path /tmp/pixel-cat-swift-cache \
    Sources/CinemaMode.swift cinema-mode-test.swift -o "$BIN"
"$BIN"

PIXELCAT_SIMCINEMA=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$LOG" 2>&1
rg -q 'SIM CINEMA hidden=true restored=true modes=true' "$LOG" || {
    print -u2 "FAIL: ซ่อนหรือคืนหน้าต่างของน้องไม่ครบ"
    cat "$LOG" >&2
    exit 1
}

print "PASS: cat, bubble, chat, heart, ball, and gecko hide and restore together"
