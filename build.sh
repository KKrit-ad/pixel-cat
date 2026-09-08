#!/bin/zsh
# คอมไพล์ใหม่หลังแก้โค้ดใน Sources/ แล้วแพ็กเป็น .app
set -e
cd "$(dirname "$0")"
swiftc -module-cache-path /tmp/pixel-cat-swift-cache -O Sources/*.swift main.swift -o PixelCat
# ปิดตัวเก่าก่อน แล้ว unlink ไม่ให้ cp ทับไฟล์ที่กำลังรัน (ลายเซ็นจะพังแล้วโดน SIGKILL)
WAS_RUNNING=""
pgrep -f "PixelCat.app/Contents/MacOS/PixelCat" >/dev/null 2>&1 && WAS_RUNNING=1
pkill -f "PixelCat.app/Contents/MacOS/PixelCat" 2>/dev/null || true
sleep 0.4
rm -f PixelCat.app/Contents/MacOS/PixelCat
cp PixelCat PixelCat.app/Contents/MacOS/PixelCat
codesign --force --sign - PixelCat.app 2>/dev/null
echo "built + signed → PixelCat.app"
# เปิดกลับให้เองถ้าเมื่อกี้น้องรันอยู่ ไม่งั้นน้องหายทุกครั้งที่ build โดยไม่มีใครรู้
if [[ -n "${WAS_RUNNING:-}" ]]; then
    open PixelCat.app
    echo "relaunched PixelCat"
fi
