#!/usr/bin/env python3
"""แปลงไฟล์ข้อความกลับเป็น cat-sheet.png พร้อมตรวจความถูกต้องทุกบรรทัด"""
import zlib, struct, binascii, sys, pathlib, re

PALETTE = {
    '.': None,      '#': '#2b2f36', 'F': '#9aa1a9', 'D': '#6e767f',
    'L': '#c8ced4', 'S': '#7f868f', 'P': '#e2a2ab', 'I': '#b3808a',
    'E': '#63a07d', 'K': '#1b211e', 'W': '#f2f5f2', 'T': '#e88fa0',
    'b': '#d0614a', 'd': '#a8452f', 'h': '#f2a892', 'g': '#8aa06b',
    'j': '#5f7147',
}
src = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'cat-sheet.txt').read_text(encoding='utf-8')

frames, cur, idx = {}, None, None
for ln, line in enumerate(src.splitlines(), 1):
    line = line.rstrip('\r')
    if cur is None and (line.startswith(';') or not line.strip()):
        continue   # คอมเมนต์อยู่ได้เฉพาะก่อนเฟรมแรก เพราะ # เป็นสีเส้นขอบ
    m = re.match(r'^===\s*(\d+)\s', line)
    if m:
        if cur is not None:
            frames[idx] = cur
        idx, cur = int(m.group(1)), []
        continue
    if cur is None or not line.strip():
        continue
    cur.append((ln, line))
if cur is not None:
    frames[idx] = cur

errs = []
for i in range(45):
    if i not in frames:
        errs.append(f"ขาดเฟรม {i}"); continue
    rows = frames[i]
    if len(rows) != 22:
        errs.append(f"เฟรม {i}: มี {len(rows)} บรรทัด ต้องเป็น 22")
    for ln, r in rows:
        if len(r) != 32:
            errs.append(f"บรรทัด {ln} (เฟรม {i}): ยาว {len(r)} ตัวอักษร ต้องเป็น 32")
        bad = set(r) - set(PALETTE)
        if bad:
            errs.append(f"บรรทัด {ln} (เฟรม {i}): มีตัวอักษรที่ไม่รู้จัก {sorted(bad)}")
extra = [k for k in frames if k >= 45]
if extra: errs.append(f"มีเฟรมเกิน: {extra}")

if errs:
    print("ไม่ผ่าน %d ข้อ:" % len(errs))
    for e in errs[:25]: print("  ✗", e)
    if len(errs) > 25: print("  ... และอีก %d ข้อ" % (len(errs)-25))
    sys.exit(1)

W, H = 45*32, 22
buf = bytearray(W*H*4)
for i in range(45):
    for y, (_, row) in enumerate(frames[i]):
        for x, chx in enumerate(row):
            hexv = PALETTE[chx]
            if hexv is None: continue
            o = ((y*W) + i*32 + x) * 4
            buf[o]   = int(hexv[1:3], 16)
            buf[o+1] = int(hexv[3:5], 16)
            buf[o+2] = int(hexv[5:7], 16)
            buf[o+3] = 255
raw = b''.join(b'\x00' + bytes(buf[y*W*4:(y+1)*W*4]) for y in range(H))
def chunk(t, d):
    b = t + d
    return struct.pack('>I', len(d)) + b + struct.pack('>I', binascii.crc32(b) & 0xffffffff)
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(raw, 9))
       + chunk(b'IEND', b''))
out = sys.argv[2] if len(sys.argv) > 2 else 'cat-sheet-from-text.png'
pathlib.Path(out).write_bytes(png)
print("✓ ผ่านครบ 45 เฟรม → เขียน %s (%dx%d)" % (out, W, H))
