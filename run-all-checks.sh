#!/bin/zsh
# รัน regression ทั้งหมด (shell + python) รวดเดียว
cd "$(dirname "$0")"
pass=0; fail=0; failed=()
for f in check-*.sh; do
    if zsh "$f" >/tmp/pixelcat-check-out 2>&1; then
        pass=$((pass+1))
    else
        fail=$((fail+1)); failed+=("$f")
        print "FAIL $f"; tail -3 /tmp/pixelcat-check-out
    fi
done
for f in check-*.py; do
    if python3 "$f" >/tmp/pixelcat-check-out 2>&1; then
        pass=$((pass+1))
    else
        fail=$((fail+1)); failed+=("$f")
        print "FAIL $f"; tail -3 /tmp/pixelcat-check-out
    fi
done
rm -f /tmp/pixelcat-check-out
print "\npass=$pass fail=$fail"
(( fail == 0 )) || exit 1
