#!/bin/zsh
# ใส่สไปรต์ชีทที่วาดมาจากข้างนอกเข้าแอป โดยไม่แตะโค้ดวาดของเดิม
#   ./use-sheet.sh path/to/new-sheet.png
set -e
cd "$(dirname "$0")"
SRC="$1"
[[ -z "$SRC" ]] && { echo "ใช้: ./use-sheet.sh path/to/new-sheet.png"; exit 1; }
[[ -f "$SRC" ]] || { echo "ไม่พบไฟล์: $SRC"; exit 1; }

python3 - "$SRC" <<'PY'
import sys, struct
p = sys.argv[1]
d = open(p, 'rb').read()
assert d[:8] == b'\x89PNG\r\n\x1a\n', "ไฟล์นี้ไม่ใช่ PNG"
w, h, depth, ctype = struct.unpack('>IIBB', d[16:26])
names = {0: 'grayscale', 2: 'RGB (ไม่มี alpha)', 3: 'indexed', 4: 'gray+alpha', 6: 'RGBA'}
print(f"  ขนาด {w}x{h}  bit depth {depth}  ชนิดสี {names.get(ctype, ctype)}")
errs = []
if (w, h) != (6016, 100):
    errs.append(f"ขนาดต้องเป็น 6016x100 พอดี (ได้ {w}x{h}) = 47 เฟรม x 128x100")
if ctype == 2 or ctype == 0:
    errs.append("ไม่มีชั้นความโปร่งใส — พื้นหลังต้องโปร่ง ไม่ใช่สีขาวทึบ")
if ctype == 3 and b'tRNS' not in d:
    errs.append("เป็น indexed แต่ไม่มี tRNS chunk = ไม่มีสีโปร่งใส")
if errs:
    print("\nไม่ผ่าน:")
    for e in errs: print("  ✗", e)
    sys.exit(1)
print("  ✓ ผ่านการตรวจ")
PY

STAMP=$(date +%Y%m%d-%H%M%S)
cp cat-sheet.png "cat-sheet.replaced-$STAMP.png"

cp "$SRC" cat-sheet.png
python3 -c "
import base64, pathlib, re
b64 = base64.b64encode(pathlib.Path('cat-sheet.png').read_bytes()).decode()
p = pathlib.Path('Sources/SpriteSheetData.swift')
s = re.sub(r'let SHEET_BASE64 = \"[^\"]*\"', 'let SHEET_BASE64 = \"%s\"' % b64, p.read_text(), count=1)
p.write_text(s)
print('  ฝังลง Sources/SpriteSheetData.swift แล้ว (%d ตัวอักษร)' % len(b64))
"
./build.sh
echo "สำรองของเดิมไว้ที่ cat-sheet.replaced-$STAMP.png"
echo "เปิดใหม่: open PixelCat.app"
