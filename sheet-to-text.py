#!/usr/bin/env python3
"""แปลง cat-sheet.png เป็นไฟล์ข้อความ 45 เฟรม เฟรมละ 22 บรรทัด บรรทัดละ 32 ตัวอักษร"""
import zlib, struct, sys, pathlib

PALETTE = {
    '.': None,          '#': '#2b2f36', 'F': '#9aa1a9', 'D': '#6e767f',
    'L': '#c8ced4',     'S': '#7f868f', 'P': '#e2a2ab', 'I': '#b3808a',
    'E': '#63a07d',     'K': '#1b211e', 'W': '#f2f5f2', 'T': '#e88fa0',
    'b': '#d0614a',     'd': '#a8452f', 'h': '#f2a892', 'g': '#8aa06b',
    'j': '#5f7147',
}
RGB = {k: (int(v[1:3],16), int(v[3:5],16), int(v[5:7],16)) for k,v in PALETTE.items() if v}

def read_png(p):
    d = pathlib.Path(p).read_bytes(); pos = 8; idat = b''
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos+4])[0]; t = d[pos+4:pos+8]
        if t == b'IHDR': W, H = struct.unpack('>II', d[pos+8:pos+16])
        elif t == b'IDAT': idat += d[pos+8:pos+8+ln]
        pos += 12 + ln
    raw = zlib.decompress(idat); st = W*4
    return W, H, [raw[y*(st+1)+1:(y+1)*(st+1)] for y in range(H)]

def nearest(c):
    return min(RGB, key=lambda k: sum((RGB[k][i]-c[i])**2 for i in range(3)))

NAMES = [('walk',0,4),('walkBlink',4,4),('run',8,4),('runBlink',12,4),('sit',16,4),
         ('sitBlink',20,4),('tilt',24,2),('lick',26,2),('sleep',28,2),('stretch',30,2),
         ('crouch',32,2),('climb',34,2),('held',36,2),('ball',38,4),('gecko',42,2),('jump',44,1)]

W, H, rows = read_png(sys.argv[1] if len(sys.argv) > 1 else 'cat-sheet.png')
out = ["; สไปรต์ชีทแมวพิกเซล — 45 เฟรม เฟรมละ 32x22",
       "; แต่ละเฟรมมี 22 บรรทัด บรรทัดละ 32 ตัวอักษรพอดี",
       "; ตัวอักษรแทนสี:"]
for k, v in PALETTE.items():
    out.append(f";   {k} = {'โปร่งใส' if v is None else v}")
out.append("")
for name, start, count in NAMES:
    for f in range(count):
        idx = start + f
        out.append(f"=== {idx} {name} {f+1}/{count} ===")
        for y in range(22):
            line = ''
            for x in range(idx*32, idx*32+32):
                r, g, b, a = rows[y][x*4:x*4+4]
                line += '.' if a == 0 else nearest((r, g, b))
            out.append(line)
        out.append("")
text = '\n'.join(out)
pathlib.Path('cat-sheet.txt').write_text(text, encoding='utf-8')
print("เขียน cat-sheet.txt แล้ว %d ตัวอักษร" % len(text))
