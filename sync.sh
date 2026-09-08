#!/bin/zsh
# สำหรับชีท legacy เท่านั้น: จะเขียนทับเฟรมภาพอ้างอิง/Context Rescue/ท่าคิดในชีท production
set -e
cd "$(dirname "$0")"
node gen-sheet.js > /dev/null
python3 - <<'PY'
import pathlib, re
p = pathlib.Path('Sources/SpriteSheetData.swift'); s = p.read_text()
b64 = pathlib.Path('cat-sheet.b64').read_text().strip()
s = re.sub(r'let SHEET_BASE64 = "[^"]*"', 'let SHEET_BASE64 = "%s"' % b64, s, count=1)
p.write_text(s)
poses = pathlib.Path('Sources/Sprites.swift'); t = poses.read_text()
start = t.index('let POSES: [String: Pose] = [')
end = t.index(']\n', t.index('"jump"', start)) + 2
poses.write_text(t[:start] + pathlib.Path('poses.swift.txt').read_text() + t[end:])
print('synced sprite sheet + pose table into Sources/')
PY
./build.sh
