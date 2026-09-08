#!/usr/bin/env python3
"""Regression check for sprite undersampling at the default display size."""

from pathlib import Path
import re
import struct


source = "\n".join(f.read_text() for f in sorted(Path("Sources").glob("*.swift")))
sheet = Path("cat-sheet.png").read_bytes()


def swift_int(name: str) -> int:
    match = re.search(rf"let {name} = (\d+)", source)
    assert match, f"missing Swift constant {name}"
    return int(match.group(1))


frame_width = swift_int("SPRITE_W")
frame_height = swift_int("SPRITE_H")
shadow_height = swift_int("SHADOW_H")

default_match = re.search(r"if tenths == 0 \{ tenths = (\d+) \}", source)
assert default_match, "missing default scale"
default_scale = int(default_match.group(1)) / 10

png_width, png_height = struct.unpack(">II", sheet[16:24])
frame_count = 82
assert (png_width, png_height) == (frame_width * frame_count, frame_height), (
    f"sheet dimensions {png_width}x{png_height} do not match "
    f"{frame_count} frames of {frame_width}x{frame_height}"
)

display_width = frame_width * default_scale
display_height = (frame_height + shadow_height) * default_scale
samples_per_point = 1 / default_scale

# Preserve the pet's current on-screen footprint while ensuring the app no
# longer magnifies a low-resolution source frame at its default size.
assert 105 <= display_width <= 125, f"default width changed unexpectedly: {display_width:.1f} pt"
assert 85 <= display_height <= 105, f"default height changed unexpectedly: {display_height:.1f} pt"
assert samples_per_point >= 1, (
    f"undersampled default render: {samples_per_point:.2f} source pixels/display point; "
    "need at least 1.00"
)

print(
    f"PASS: {frame_width}x{frame_height} frames at {default_scale:.1f}x -> "
    f"{display_width:.1f}x{display_height:.1f} pt, "
    f"{samples_per_point:.2f} source pixels/display point"
)
