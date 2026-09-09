#!/bin/zsh
# ตรวจว่าตัวเฝ้า Claude log อ่านเฉพาะข้อมูลที่ต่อท้าย แม้ไฟล์จะใหญ่กว่าหน้าต่างเดิม 8 KB
set -euo pipefail

cd "$(dirname "$0")"

BIN=$(mktemp /tmp/pixelcat-claude-link-monitor.XXXXXX)
trap 'rm -f "$BIN"' EXIT

swiftc -module-cache-path /tmp/pixel-cat-swift-cache \
    Sources/ClaudeDeepLinkLog.swift claude-link-monitor-test.swift -o "$BIN"
"$BIN"
