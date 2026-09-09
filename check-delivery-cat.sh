#!/bin/zsh
# ตรวจจับไฟล์ใหม่แบบ stable และทดสอบ Delivery Cat UI/animation โดยไม่แตะ Downloads จริง
set -euo pipefail

cd "$(dirname "$0")"

BIN=$(mktemp /tmp/pixelcat-delivery-watcher.XXXXXX)
LOG=$(mktemp /tmp/pixelcat-delivery-ui.XXXXXX)
trap 'rm -f "$BIN" "$LOG"' EXIT

swiftc -module-cache-path /tmp/pixel-cat-swift-cache \
    Sources/DeliveryWatcher.swift delivery-watcher-test.swift -o "$BIN"
"$BIN"

PIXELCAT_SIMDELIVERY=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$LOG" 2>&1
rg -q 'SIM DELIVERY detected=true grouped=true pose=true actions=true local=true' "$LOG" || {
    print -u2 "FAIL: Delivery Cat integration ไม่ครบ"
    cat "$LOG" >&2
    exit 1
}

print "PASS: Delivery Cat groups new files, shows its parcel pose, and offers safe actions"

