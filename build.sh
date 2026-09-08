#!/bin/zsh
# คอมไพล์ใหม่หลังแก้โค้ดใน Sources/ แล้วแพ็กเป็น .app
set -e
cd "$(dirname "$0")"
swiftc -module-cache-path /tmp/pixel-cat-swift-cache -O Sources/*.swift main.swift -o PixelCat
# ปิดตัวเก่าก่อน แล้ว unlink ไม่ให้ cp ทับไฟล์ที่กำลังรัน (ลายเซ็นจะพังแล้วโดน SIGKILL)
pkill -f "PixelCat.app/Contents/MacOS/PixelCat" 2>/dev/null || true
sleep 0.4
rm -f PixelCat.app/Contents/MacOS/PixelCat
cp PixelCat PixelCat.app/Contents/MacOS/PixelCat
codesign --force --sign - PixelCat.app 2>/dev/null
echo "built + signed → PixelCat.app"
