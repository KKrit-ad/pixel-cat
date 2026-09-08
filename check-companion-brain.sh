#!/bin/zsh
# สมองที่เลือกได้ + งานจริงเข้า prompt + handoff กดย้อนหลังได้
set -u

cd "$(dirname "$0")"
LOG=$(mktemp /tmp/pixelcat-brain.XXXXXX)
trap 'rm -f "$LOG"' EXIT

PIXELCAT_BRAINTEST=offline ./PixelCat.app/Contents/MacOS/PixelCat >"$LOG" 2>&1
STATUS=$?
if (( STATUS != 0 )); then
    print -u2 "FAIL: braintest process exited $STATUS"
    cat "$LOG" >&2
    exit 1
fi

python3 - "$LOG" <<'PY'
import pathlib, re, sys

log = pathlib.Path(sys.argv[1]).read_text()

def field(name):
    m = re.search(rf"(?:^|\s){name}=(\[[^\]]*\]|\S+)", log, re.M)
    assert m, f"ไม่พบ {name} ใน log:\n{log}"
    return m.group(1).strip("[]")

# งานจริงต้องถึง prompt — ไม่ใช่แค่ตัวเลขนับ
assert field("context_has_work") == "true", "prompt ต้องมีชื่อโปรเจกต์จริงอยู่ด้วย"
assert field("has_topic") == "true", "prompt ต้องมีหัวข้อห้องงาน"
assert field("has_open_work") == "true", "prompt ต้องมีบล็อก open_work"

# handoff ต้องกดย้อนหลังได้ และเสนอซ้ำต้องไม่เพิ่มรายการ
assert field("history_count") == "1", f"เสนอซ้ำงานเดิมต้องไม่เพิ่มรายการ (ได้ {field('history_count')})"
assert field("persisted") == "1", "ประวัติ handoff ต้องอ่านกลับมาจากดิสก์ได้"
assert field("has_handoff") == "true", "ต้องเก็บเนื้อ handoff ไว้วาง pasteboard ตอนกดย้อนหลัง"

title = field("title")
assert "pixel-cat" in title, f"เมนูต้องโชว์ชื่อโปรเจกต์: {title}"
assert "/Users/" not in title, f"ห้ามมี path เต็มหลุดออกมา: {title}"

# เมนู = 1 รายการ + separator + ล้างประวัติ
assert field("menu_items") == "3", f"เมนูประวัติควรมี 3 บรรทัด (ได้ {field('menu_items')})"

# ความทรงจำ — ต้องสะสมข้ามการเปิดปิดแอปและเข้าไปอยู่ใน prompt จริง
assert field("mem_turns") == "2", f"บทสนทนาต้องอ่านกลับจากดิสก์ได้ (ได้ {field('mem_turns')})"
assert field("mem_has_history") == "true", "prompt ต้องมีบทสนทนาก่อนหน้า"
assert field("mem_has_age") == "true", "น้องต้องรู้อายุตัวเอง"
assert field("mem_has_gap") == "true", "น้องต้องรู้ว่าห่างจากครั้งล่าสุดนานแค่ไหน"
assert int(field("days")) > 700, f"อยู่ด้วยกันควรราวสองปี (ได้ {field('days')} วัน)"

# ตัวตน — เป็นแมวของพ่อ ไม่ใช่ผู้ช่วย และไม่ประกาศตัวว่าเป็น AI
assert field("prompt_is_cat") == "true", "persona ต้องเป็นแมวสาวอายุสองขวบ"
assert field("prompt_says_dad") == "true", "น้องต้องเรียกกริชว่าพ่อ"
assert field("prompt_no_ai_claim") == "true", "ต้องไม่มีคำสั่งให้ประกาศตัวว่าเป็น AI"
assert field("prompt_has_memory") == "true", "prompt ต้องมีบล็อกความทรงจำ"

assert "reply=SKIPPED_OFFLINE" in log, "โหมด offline ต้องไม่ยิงสมองจริง"

print(f"PASS: brain={field('brain')} • งานจริงเข้า prompt • จำได้ {field('mem_turns')} บท"
      f" • อายุ {field('age')} • handoff ย้อนหลังได้ ({title})")
PY
