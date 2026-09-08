#!/bin/zsh
# กล่องพิมพ์ต้องเป็นกรอบคำพูดใบเดียวกับตอนอั่งเปาพูด — สูงเท่ากัน ยืนที่เดียวกัน ยืดตามข้อความได้
set -u

cd "$(dirname "$0")"
LOG=$(mktemp /tmp/pixelcat-chatbubble.XXXXXX)
trap 'rm -f "$LOG" chat-input-snap.png chat-speech-snap.png' EXIT

PIXELCAT_SNAPCHAT=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: snapchat process exited $STATUS"
    cat "$LOG" >&2
    exit 1
fi

python3 - "$LOG" <<'PY'
import pathlib, re, struct, sys

log = pathlib.Path(sys.argv[1]).read_text()

def frame(kind):
    m = re.search(rf"SNAPCHAT {kind}=\((-?[\d.]+), (-?[\d.]+), ([\d.]+), ([\d.]+)\)", log)
    assert m, f"ไม่พบบรรทัด SNAPCHAT {kind} ใน log:\n{log}"
    return [float(g) for g in m.groups()]

ix, iy, iw, ih = frame("input")
sx, sy, sw, sh = frame("speech")

assert ih == sh, f"กล่องพิมพ์สูง {ih} แต่กรอบคำพูดสูง {sh} — ต้องเท่ากัน"
assert iy == sy, f"กล่องพิมพ์อยู่ y={iy} แต่กรอบคำพูด y={sy} — ต้องยืนที่เดียวกัน"
assert abs((ix + iw / 2) - (sx + sw / 2)) <= 1, "ทั้งสองกรอบต้องอยู่กลางหัวแมวตำแหน่งเดียวกัน"

chars = int(re.search(r"chars=(-?\d+)", log).group(1))
assert chars > 0, "กล่องพิมพ์ควรมีข้อความที่พิมพ์ไว้ตอน snapshot"
assert 200 <= iw <= 460, f"ความกว้างกล่องพิมพ์ {iw} หลุดช่วง 200–460"

for name in ("chat-input-snap.png", "chat-speech-snap.png"):
    data = pathlib.Path(name).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{name} ไม่ใช่ PNG"
    w, h = struct.unpack(">II", data[16:24])
    assert w > 60 and h > 20, f"{name} เล็กผิดปกติ {w}x{h}"

print(f"PASS: chat input bubble matches speech bubble (h={ih}, y={iy}, w={iw})")
PY
