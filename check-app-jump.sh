#!/bin/zsh
# ตรวจว่า session.py เก็บสายโปรเซสแม่ และในสายมีแอป GUI ที่สั่งให้ขึ้นหน้าได้จริง
set -u
cd "$(dirname "$0")"
SESS="$HOME/.pixelcat/session.py"
DIR="$HOME/.pixelcat/sessions"
SID="checkapp$$"
FAIL=0
trap 'rm -f "$DIR/$SID" /tmp/cj$$ /tmp/cj$$.swift' EXIT

[[ -f "$SESS" ]] || { print -u2 "FAIL: ไม่พบ $SESS"; exit 1; }
echo "{\"session_id\":\"$SID\",\"cwd\":\"/tmp\"}" | python3 "$SESS" input >/dev/null 2>&1

PIDS=$(python3 -c "
import json,sys
d=json.load(open('$DIR/$SID'))
p=d.get('app_pids') or []
print(' '.join(map(str,p)))" 2>/dev/null)

if [[ -z "$PIDS" ]]; then
    print -u2 "FAIL: ไม่ได้บันทึกสายโปรเซสเลย"
    exit 1
fi
print "PASS  บันทึกสายโปรเซส: $PIDS"

cat > /tmp/cj$$.swift <<'SW'
import Cocoa
var found = false
for s in CommandLine.arguments.dropFirst() {
    if let p = Int32(s), let a = NSRunningApplication(processIdentifier: p),
       a.activationPolicy == .regular {
        print("focusable: \(a.bundleIdentifier ?? "-")")
        found = true
        break
    }
}
exit(found ? 0 : 1)
SW
if ! swiftc -O /tmp/cj$$.swift -o /tmp/cj$$ 2>/dev/null; then
    print -u2 "SKIP  คอมไพล์ตัวตรวจไม่ได้"
    exit $FAIL
fi
if out=$(/tmp/cj$$ ${=PIDS}); then
    print "PASS  เจอแอปที่สั่งได้ — $out"
else
    print -u2 "FAIL  ทั้งสายไม่มีแอป GUI ที่สั่งให้ขึ้นหน้าได้"
    FAIL=1
fi
exit $FAIL
