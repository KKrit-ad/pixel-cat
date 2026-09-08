#!/usr/bin/env python3
"""Claude Code hook -> บันทึกสถานะของ "เซสชันเดียว" ลงไฟล์แยก

ของเดิมเราใช้ inbox ไฟล์เดียว เปิด Claude หลายหน้าต่างแล้วทับกัน
หน้าต่างที่รอ input อยู่จะหายไปเลย — อันนี้แก้ตรงนั้น

ใช้:  session.py <state> [ข้อความ]      state: working | input | idle | end
เงียบเสมอและคืน 0 เพื่อไม่ให้ไปขวาง Claude Code
"""
import sys, os, json, time

DIR = os.path.expanduser("~/.pixelcat/sessions")
DISK_TTL = 6 * 3600        # ไฟล์เงียบเกินเท่านี้ กวาดทิ้งจากดิสก์
CONTEXT_WINDOWS = (200_000, 1_000_000)


def read_context(path):
    """(tokens, เปอร์เซ็นต์) จากท้ายไฟล์ transcript หรือ None

    transcript ใหญ่หลาย MB อ่านทั้งไฟล์ไม่ไหว เลยไล่ถอยหลังจากท้ายทีละก้อน
    แล้วหยุดที่บรรทัดแรกที่มีบล็อก usage จริง — กรองด้วยคีย์ที่โผล่เฉพาะใน usage
    ไม่ใช่คำว่า usage เฉย ๆ ซึ่งอาจอยู่ในเนื้อบทสนทนา
    """
    if not path or not os.path.isfile(path):
        return None
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            for window in (256 * 1024, 1024 * 1024, 4 * 1024 * 1024):
                f.seek(max(0, size - window))
                chunk = f.read()
                if size > window:
                    chunk = chunk.split(b"\n", 1)[-1]      # ตัดบรรทัดแรกที่ขาด
                for line in reversed(chunk.split(b"\n")):
                    if b'"cache_read_input_tokens"' not in line:
                        continue
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    u = (rec.get("message") or {}).get("usage")
                    if not isinstance(u, dict):
                        continue
                    total = (u.get("input_tokens", 0)
                             + u.get("cache_creation_input_tokens", 0)
                             + u.get("cache_read_input_tokens", 0))
                    if total <= 0:
                        continue
                    win = next((w for w in CONTEXT_WINDOWS if total <= w),
                               CONTEXT_WINDOWS[-1])
                    return total, round(100.0 * total / win, 1)
                if size <= window:
                    break
    except Exception:
        pass
    return None

def read_topic(path):
    """หัวข้อของห้องสนทนา — Claude Code ตั้งชื่อให้เองอยู่แล้ว

    ในไฟล์ transcript มี record ชนิด custom-title (ผู้ใช้ตั้งเอง) กับ ai-title
    ทั้งคู่ถูกเขียนซ้ำเรื่อย ๆ เลยไล่ถอยหลังจากท้ายไฟล์แล้วเจอเร็ว
    ไม่เจอทั้งคู่ค่อยถอยไปหยิบข้อความแรกของผู้ใช้จากหัวไฟล์
    """
    if not path or not os.path.isfile(path):
        return ""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - 512 * 1024))
            chunk = f.read()
            if size > 512 * 1024:
                chunk = chunk.split(b"\n", 1)[-1]
            ai = ""
            for line in reversed(chunk.split(b"\n")):
                if b'-title"' not in line:      # custom-title / ai-title เท่านั้น
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                t = rec.get("type")
                if t == "custom-title" and rec.get("customTitle"):
                    return str(rec["customTitle"])[:60]      # ผู้ใช้ตั้งเอง ชนะเสมอ
                if t == "ai-title" and rec.get("aiTitle") and not ai:
                    ai = str(rec["aiTitle"])[:60]
            if ai:
                return ai
            # ไม่มีชื่อ — ใช้ข้อความแรกของผู้ใช้ อ่านแค่หัวไฟล์ก็พอ
            f.seek(0)
            for line in f.read(256 * 1024).split(b"\n"):
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if rec.get("type") != "user":
                    continue
                c = (rec.get("message") or {}).get("content")
                if isinstance(c, list):
                    c = " ".join(b.get("text", "") for b in c
                                 if isinstance(b, dict) and b.get("type") == "text")
                c = (c or "").strip()
                if c and not c.startswith("<"):          # ข้าม system-reminder
                    return " ".join(c.split())[:60]
    except Exception:
        pass
    return ""


def read_recent(path, limit=8):
    """ไฟล์ที่เพิ่งแก้ + คำสั่งล่าสุดของผู้ใช้ ไว้บอกห้องใหม่ว่าห้องเก่าทำอะไรค้างไว้

    อ่านท้าย transcript ก้อนเดียวแล้วดึงทั้งสองอย่าง จะได้ไม่เปิดไฟล์ซ้ำ
    ไฟล์เอาจาก tool_use ที่เป็นการแก้ไฟล์จริง ไม่นับการอ่าน
    """
    out = {"files": [], "last_user": ""}
    if not path or not os.path.isfile(path):
        return out
    edit_tools = {"Edit", "Write", "NotebookEdit", "MultiEdit"}
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - 1024 * 1024))
            chunk = f.read()
            if size > 1024 * 1024:
                chunk = chunk.split(b"\n", 1)[-1]
        seen = []
        for line in reversed(chunk.split(b"\n")):
            if not line.strip():
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            msg = rec.get("message") or {}
            content = msg.get("content")
            if rec.get("type") == "assistant" and isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict) or block.get("type") != "tool_use":
                        continue
                    if block.get("name") not in edit_tools:
                        continue
                    fp = (block.get("input") or {}).get("file_path")
                    if isinstance(fp, str) and fp and fp not in seen:
                        seen.append(fp)
            elif rec.get("type") == "user" and not out["last_user"]:
                text = content
                if isinstance(text, list):
                    text = " ".join(b.get("text", "") for b in text
                                    if isinstance(b, dict) and b.get("type") == "text")
                text = " ".join((text or "").split())
                # ข้าม tool result และ system-reminder ที่ไม่ใช่คำสั่งของผู้ใช้จริง
                if text and not text.startswith("<"):
                    out["last_user"] = text[:400]
            if len(seen) >= limit and out["last_user"]:
                break
        out["files"] = seen[:limit]
    except Exception:
        pass
    return out


def previous(path):
    """ค่าที่เขียนไว้รอบก่อน ใช้คงเวลาเริ่มห้องและรายละเอียดที่ยังไม่ได้คำนวณใหม่"""
    try:
        with open(path) as f:
            old = json.load(f)
        return old if isinstance(old, dict) else {}
    except Exception:
        return {}


def sweep():
    """กวาดไฟล์เซสชันที่ตายแล้วทิ้ง

    ปกติ SessionEnd จะลบไฟล์ให้ แต่ถ้า Claude ถูกฆ่าหรือปิดเทอร์มินัลดื้อ ๆ
    hook นั้นไม่ทำงาน ไฟล์เลยค้าง — กวาดตอนมี hook อื่นวิ่งแทน
    """
    cutoff = time.time() - DISK_TTL
    try:
        for n in os.listdir(DIR):
            f = os.path.join(DIR, n)
            try:
                if os.path.isfile(f) and os.path.getmtime(f) < cutoff:
                    os.remove(f)
            except OSError:
                pass
    except OSError:
        pass


def focus_url():
    """URL ที่โฟกัสกลับมาแท็บนี้ หรือ "" ถ้าเทอร์มินัลไม่รองรับ

    Warp ใส่ warp://session/<uuid> ให้ทุกแท็บผ่าน WARP_FOCUS_URL ซึ่งเป็นทางเดียว
    ที่พากลับมาถูกแท็บได้ — ถ้าใช้ pid ของแอปจะได้แค่หน้าต่างที่โฟกัสอยู่แล้ว
    จำกัดเฉพาะ scheme ที่รู้จัก เพราะค่านี้จะถูกส่งต่อให้ระบบเปิด
    """
    url = os.environ.get("WARP_FOCUS_URL", "").strip()
    if url.startswith("warp://") and len(url) < 512 and "\n" not in url:
        return url
    return ""


def ancestor_pids():
    """PID ของโปรเซสแม่ทั้งสายจากใกล้ไปไกล

    เก็บทั้งสายแทนที่จะเดาเอง เพราะ .app ตัวแรกที่เจออาจเป็นโปรเซสลูกที่ไม่ได้
    ลงทะเบียนเป็นแอป GUI (เช่น claude.app/Contents/MacOS/claude ของแอปเดสก์ท็อป)
    ฝั่งแอปจะไล่หาตัวแรกที่ NSRunningApplication รู้จักเอง
    """
    import subprocess
    out = []
    pid = os.getppid()
    for _ in range(14):
        if pid <= 1:
            break
        out.append(int(pid))
        try:
            r = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)],
                               capture_output=True, text=True, timeout=2).stdout.strip()
        except Exception:
            break
        if not r:
            break
        pid = int(r)
    return out


def main():
    state = sys.argv[1] if len(sys.argv) > 1 else "idle"
    msg = sys.argv[2] if len(sys.argv) > 2 else ""
    try:
        payload = json.load(sys.stdin)
    except Exception:
        payload = {}
    sid = payload.get("session_id") or os.environ.get("CLAUDE_SESSION_ID") or "unknown"
    sid = "".join(c for c in sid if c.isalnum() or c in "-_")[:64] or "unknown"
    path = os.path.join(DIR, sid)

    if state == "end":
        try: os.remove(path)
        except OSError: pass
        return

    cwd = payload.get("cwd") or ""
    tp = payload.get("transcript_path")
    ctx = read_context(tp) if state in ("idle", "input") else None
    topic = read_topic(tp)
    # รายละเอียดห้องนี้ดึงเฉพาะตอนหยุดพัก จะได้ไม่ถ่วงทุกครั้งที่แก้ไฟล์
    now = int(time.time())
    before = previous(path)
    if state in ("idle", "input"):
        recent = read_recent(tp)
    else:
        # ระหว่างทำงานยังไม่ต้องอ่านซ้ำ แต่ต้องไม่ลบของเดิมทิ้ง
        recent = {"files": before.get("files") or [],
                  "last_user": before.get("last_user") or ""}
    started = before.get("started")
    if not isinstance(started, (int, float)) or started <= 0:
        started = now
    sweep()
    raw_sid = (payload.get("session_id") or "").strip()
    rec = {"session_id": raw_sid, "app_pids": ancestor_pids(), "focus_url": focus_url(), "term": os.environ.get("TERM_PROGRAM", ""),
           "topic": topic, "ctx_pct": ctx[1] if ctx else None, "ctx_tok": ctx[0] if ctx else None,
           "files": recent["files"], "last_user": recent["last_user"],
           "started": int(started),
           "state": state, "msg": msg, "at": now,
           "cwd": cwd, "dir": os.path.basename(cwd.rstrip("/")) if cwd else "",
           "pid": os.getppid()}
    os.makedirs(DIR, exist_ok=True)
    tmp = path + ".tmp%d" % os.getpid()
    with open(tmp, "w") as f:
        json.dump(rec, f, ensure_ascii=False)
    os.replace(tmp, path)

if __name__ == "__main__":
    try: main()
    except Exception: pass
    sys.exit(0)
