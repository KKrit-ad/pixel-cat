#!/bin/zsh
# ตรวจว่า session.py เก็บ URL ของแท็บ Warp ถูกต้องและกัน scheme แปลกปลอม
set -u
cd "$(dirname "$0")"
SESS="$HOME/.pixelcat/session.py"
DIR="$HOME/.pixelcat/sessions"
FAIL=0

probe() {   # <ชื่อเทส> <ค่า WARP_FOCUS_URL> <ค่าที่คาดว่าจะได้>
    local name=$1 url=$2 want=$3 sid="checkwarp$$"
    echo "{\"session_id\":\"$sid\",\"cwd\":\"/tmp\"}" \
        | WARP_FOCUS_URL="$url" python3 "$SESS" input >/dev/null 2>&1
    local got
    got=$(python3 -c "import json;print(json.load(open('$DIR/$sid'))['focus_url'])" 2>/dev/null)
    rm -f "$DIR/$sid"
    if [[ "$got" == "$want" ]]; then
        print "PASS  $name"
    else
        print -u2 "FAIL  $name — ได้ '$got' ควรได้ '$want'"
        FAIL=1
    fi
}

[[ -f "$SESS" ]] || { print -u2 "FAIL: ไม่พบ $SESS"; exit 1; }
probe "รับ warp:// ปกติ"        "warp://session/abc-123"  "warp://session/abc-123"
probe "ปฏิเสธ file://"          "file:///etc/passwd"      ""
probe "ปฏิเสธ scheme อื่น"      "http://evil.example"     ""
probe "ปฏิเสธค่าที่มีขึ้นบรรทัดใหม่" "warp://a
b"                        ""
probe "ไม่มีตัวแปร = ว่าง"       ""                        ""

# ยาวเกิน 512 ต้องถูกตัดทิ้ง
probe "ปฏิเสธ URL ยาวผิดปกติ" "warp://session/$(head -c 600 /dev/zero | tr '\0' 'a')" ""

exit $FAIL
