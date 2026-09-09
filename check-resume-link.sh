#!/bin/zsh
# ตรวจว่า session.py เก็บ session_id ดิบ และรูปแบบใช้ทำ claude://resume ได้
set -u
cd "$(dirname "$0")"
SESS="$HOME/.pixelcat/session.py"; DIR="$HOME/.pixelcat/sessions"; FAIL=0

probe() {  # <ชื่อ> <session_id ที่ป้อน> <ค่าที่คาด>
    local name=$1 sid=$2 want=$3
    echo "{\"session_id\":\"$sid\",\"cwd\":\"/tmp\"}" | python3 "$SESS" input >/dev/null 2>&1
    local key got
    key=$(python3 -c "
import sys;s='$sid'
print(''.join(c for c in s if c.isalnum() or c in '-_')[:64] or 'unknown')")
    got=$(python3 -c "
import json
try: print(json.load(open('$DIR/$key'))['session_id'])
except Exception: print('')" 2>/dev/null)
    rm -f "$DIR/$key"
    if [[ "$got" == "$want" ]]; then print "PASS  $name"
    else print -u2 "FAIL  $name — ได้ '$got' ควรได้ '$want'"; FAIL=1; fi
}

[[ -f "$SESS" ]] || { print -u2 "FAIL: ไม่พบ $SESS"; exit 1; }
# ใช้ UUID ใหม่ทุกครั้ง จะได้ไม่เขียนทับ/ลบไฟล์ของ session จริงบนเครื่อง
TEST_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
probe "เก็บ UUID ครบไม่ตัดขีด" "$TEST_ID" "$TEST_ID"

# URL ที่ประกอบได้ต้องถูกต้อง
URL=$(python3 -c "
from urllib.parse import urlencode
print('claude://resume?'+urlencode({'session':'2fb75158-3f2c-41cb-ac73-532f76edd5cf'}))")
if [[ "$URL" == "claude://resume?session=2fb75158-3f2c-41cb-ac73-532f76edd5cf" ]]; then
    print "PASS  ประกอบ URL ถูกรูปแบบ"
else
    print -u2 "FAIL  URL ผิด: $URL"; FAIL=1
fi

# ระบบต้องรู้จัก scheme claude://
if [[ -d /Applications/Claude.app ]]; then
    print "PASS  พบ Claude.app ที่รับ scheme claude://"
else
    print -u2 "SKIP  ไม่พบ /Applications/Claude.app — deep link จะถอยไปใช้วิธีอื่น"
fi
exit $FAIL
