#!/bin/zsh
set -u

cd "$(dirname "$0")"
POSE=${1:-sit}
SNAPSHOT_OUT=${2:-$(mktemp /tmp/pixelcat-snapshot.XXXXXX)}
SNAPSHOT_LOG=$(mktemp /tmp/pixelcat-snapshot-log.XXXXXX)
if (( $# < 2 )); then
    trap 'rm -f "$SNAPSHOT_OUT" "$SNAPSHOT_LOG"' EXIT
else
    trap 'rm -f "$SNAPSHOT_LOG"' EXIT
fi

./PixelCat.app/Contents/MacOS/PixelCat --snapshot "$SNAPSHOT_OUT" "$POSE" >"$SNAPSHOT_LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: snapshot process exited $STATUS"
    cat "$SNAPSHOT_LOG" >&2
    exit 1
fi

python3 - "$SNAPSHOT_OUT" <<'PY'
import pathlib, struct, sys

path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
assert data[:8] == b"\x89PNG\r\n\x1a\n", "snapshot is not a PNG"
width, height = struct.unpack(">II", data[16:24])
assert width >= 100 and height >= 90, f"snapshot is unexpectedly small: {width}x{height}"
print(f"PASS: snapshot rendered {width}x{height}")
PY
print "PASS: pose=$POSE output=$SNAPSHOT_OUT"
