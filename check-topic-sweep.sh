#!/bin/zsh
# ตรวจ 1) ดึงหัวข้อห้องสนทนาได้  2) กวาดไฟล์เซสชันที่ตายแล้วทิ้ง
set -u
cd "$(dirname "$0")"
SESS="$HOME/.pixelcat/session.py"; FAIL=0
TMP=$(mktemp -d); DIR="$TMP/sessions"; mkdir -p "$DIR"; trap 'rm -rf $TMP' EXIT

# --- หัวข้อ: customTitle ต้องชนะ aiTitle ---
cat > "$TMP/t.jsonl" <<'J'
{"type":"user","message":{"content":"ข้อความแรกของผู้ใช้"}}
{"type":"ai-title","aiTitle":"ชื่อที่ AI ตั้ง"}
{"type":"custom-title","customTitle":"ชื่อที่ผู้ใช้ตั้งเอง"}
J
got=$(python3 -c "
import sys;sys.path.insert(0,'$HOME/.pixelcat');import session
print(session.read_topic('$TMP/t.jsonl'))")
[[ "$got" == "ชื่อที่ผู้ใช้ตั้งเอง" ]] && print "PASS  customTitle ชนะ aiTitle" \
    || { print -u2 "FAIL  หัวข้อ — ได้ '$got'"; FAIL=1; }

# --- ไม่มีชื่อเลย ต้องถอยไปใช้ข้อความแรก และข้าม system-reminder ---
cat > "$TMP/u.jsonl" <<'J'
{"type":"user","message":{"content":"<system-reminder>ไม่เอาอันนี้</system-reminder>"}}
{"type":"user","message":{"content":"คำถามจริงของผู้ใช้"}}
J
got=$(python3 -c "
import sys;sys.path.insert(0,'$HOME/.pixelcat');import session
print(session.read_topic('$TMP/u.jsonl'))")
[[ "$got" == "คำถามจริงของผู้ใช้" ]] && print "PASS  ถอยไปข้อความแรก ข้าม system-reminder" \
    || { print -u2 "FAIL  fallback — ได้ '$got'"; FAIL=1; }

# --- กวาดไฟล์: เก่าต้องหาย ใหม่ต้องอยู่ ---
mkdir -p "$DIR"
OLD="$DIR/zz-test-old"; NEW="$DIR/zz-test-new"
echo '{}' > "$OLD"; echo '{}' > "$NEW"
touch -t 202001010000 "$OLD"
python3 -c "
import sys;sys.path.insert(0,'$HOME/.pixelcat');import session
session.DIR='$DIR'
session.sweep()"
if [[ ! -f "$OLD" && -f "$NEW" ]]; then print "PASS  กวาดไฟล์เก่า เก็บไฟล์ใหม่"
else print -u2 "FAIL  กวาด — เก่าเหลือ=$([[ -f $OLD ]] && echo ใช่ || echo ไม่) ใหม่หาย=$([[ -f $NEW ]] && echo ไม่ || echo ใช่)"; FAIL=1; fi
rm -f "$OLD" "$NEW"

# --- แต่ละ section ในเมนูต้องมีเพดาน ---
rg -q 'sessions\.prefix\(INBOX_MAX\)' Sources main.swift \
    && print "PASS  แต่ละ section ในเมนูจำกัดจำนวนรายการ" \
    || { print -u2 "FAIL  เมนูไม่มีเพดาน"; FAIL=1; }
exit $FAIL
