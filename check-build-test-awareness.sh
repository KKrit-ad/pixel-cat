#!/bin/zsh
# Build/Test Awareness ต้องมีภาพเคลื่อนไหวแยกครบทั้งห้าสถานะ
set -u
set -e

cd "$(dirname "$0")"

rg -q '"buildWork".*Pose\(start: 65, count: 3' Sources main.swift || {
    print -u2 "FAIL: missing three-frame builder animation"
    exit 1
}
rg -q '"testWatch".*Pose\(start: 68, count: 3' Sources main.swift || {
    print -u2 "FAIL: missing three-frame test-watching animation"
    exit 1
}
rg -q '"testPass".*Pose\(start: 71, count: 2' Sources main.swift || {
    print -u2 "FAIL: missing two-frame test-pass animation"
    exit 1
}
rg -q '"testFail".*Pose\(start: 73, count: 3' Sources main.swift || {
    print -u2 "FAIL: missing three-frame test-failure animation"
    exit 1
}
rg -q '"permission".*Pose\(start: 76, count: 2' Sources main.swift || {
    print -u2 "FAIL: missing two-frame permission animation"
    exit 1
}

python3 check-sprite-clarity.py >/dev/null
swift -module-cache-path /tmp/pixel-cat-swift-cache check-sprite-halo.swift cat-sheet.png >/dev/null

rg -q 'SIM BUILD TEST classify=' Sources main.swift || {
    print -u2 "FAIL: missing end-to-end Build/Test Awareness simulation"
    exit 1
}

LOG=$(mktemp /tmp/pixelcat-build-test-awareness.XXXXXX)
trap 'rm -f "$LOG"' EXIT
PIXELCAT_SIMBUILDTEST=1 ./PixelCat.app/Contents/MacOS/PixelCat >"$LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: Build/Test Awareness simulation exited $STATUS"
    cat "$LOG" >&2
    exit 1
fi

if ! rg -q 'SIM BUILD TEST classify=true build=true test=true pass=true fail=true permission=true transition=true resume=true priority=true focus=true reduced=true shadow=true' "$LOG"; then
    print -u2 "FAIL: real activity signals did not drive all five accessible animations"
    cat "$LOG" >&2
    exit 1
fi

print "PASS: real build, test, result, and permission signals drive five crisp animations"
