from pathlib import Path
import re
root = Path(__file__).resolve().parent
target = root / 'Sources' / 'SpriteSheetData.swift'
b64 = (root / 'cat-sheet.b64').read_text().strip()
s = target.read_text()
s2, n = re.subn(r'let SHEET_BASE64 = "[^"]*"', 'let SHEET_BASE64 = "' + b64 + '"', s, count=1)
if n != 1:
    raise SystemExit(f'expected one SHEET_BASE64 replacement, got {n}')
target.write_text(s2)
print('embedded generated sprite base64 into Sources/SpriteSheetData.swift')

