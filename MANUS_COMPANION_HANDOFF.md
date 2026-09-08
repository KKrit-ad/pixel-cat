# PixelCat — Manus Companion Handoff

## บริบทโปรเจกต์

โปรเจกต์นี้ชื่อ **PixelCat** เป็น macOS desktop pet เขียนด้วย Swift/AppKit ในไฟล์หลัก `main.swift` ไฟล์เดียว ผู้ใช้ชื่อ **กริช** และแมวชื่อ **อั่งเปา** เป็นแมวเพศเมีย อั่งเปาควรเป็น AI companion หลักที่คุยกับกริชผ่าน Manus ส่วน Claude Code และ Codex ยังคงเป็นแหล่งสถานะงานใน Work Inbox เดิม

โปรเจกต์อยู่ที่:

```text
~/Desktop/pixel-cat
```

ใน sandbox path คือ:

```text
/mnt/c7f87fc8-c643-4a5a-9e37-25aa9ea51917/pixel-cat
```

คำสั่ง build:

```bash
./build.sh
```

## เป้าหมายที่ต้องการ

ต้องการให้กริชเปิดเมนู `AI companion → คุยกับอั่งเปา…` แล้วเห็น input bubble เล็ก ๆ เหนือตัวแมว ไม่ใช่หน้าต่าง chat ขนาดใหญ่

Flow ที่ต้องการ:

```text
กด “คุยกับอั่งเปา…”
    ↓
input bubble เล็ก ๆ ปรากฏและรับ keyboard focus
    ↓
กริชพิมพ์ข้อความ + กด Enter หรือปุ่มส่ง
    ↓
input bubble หายไป
    ↓
แสดง “อั่งเปากำลังคิด…” ใน speech bubble เดิม
    ↓
Manus lite ตอบ
    ↓
แทนที่ด้วยคำตอบปัจจุบันใน speech bubble ของอั่งเปา
```

## สิ่งที่มีอยู่แล้วใน `main.swift`

### Work Inbox

- `WorkSession`
- Claude Code session files จาก `~/.pixelcat/sessions`
- Codex SQLite state/history
- `WorkNotice`
- deep links ไปยัง Claude/Codex/Warp
- Context Rescue
- Task Shepherd
- Drag Courier
- notification และ cooldown เดิม

### Local Companion ระยะที่ 1

มีชนิดข้อมูล:

```swift
enum CompanionMode: Int {
    case off = 0, quietWatch = 1, companion = 2
}

struct CompanionSnapshot {
    let activeApp: String
    let userIdleSeconds: Double
    let workingCount: Int
    let waitingCount: Int
    let attentionCount: Int
    let hottestContext: Double
    let focusActive: Bool
    let recentEvent: String
}

struct CompanionDecision {
    let message: String
    let mood: String
    let cooldown: Double
}
```

มี local observer/rule engine ใน `PetController`:

- `localCompanionSnapshot()`
- `companionDecision(for:)`
- `runLocalCompanion(_:)`
- `applyCompanionDecision(_:source:)`
- cooldown
- active app observation
- idle time observation
- local fallback

## Manus API ที่ใช้อยู่

ใช้ Manus API v2:

```text
Base URL: https://api.manus.ai
Authentication header: x-manus-api-key
Profile: manus-1.6-lite
```

API key ต้องอ่านจาก environment เท่านั้น:

```text
PIXELCAT_MANUS_API_KEY
```

มี fallback เป็น:

```text
MANUS_API_KEY
```

ห้าม hardcode key ลง `main.swift`, binary, README หรือ Git เด็ดขาด

API key ที่ผู้ใช้เคยส่งในแชตก่อนหน้านี้ถือว่าเปิดเผยแล้ว ห้ามนำกลับมาใช้ ให้ผู้ใช้ revoke และสร้าง key ใหม่เอง

### Context request

Local companion ส่ง metadata ที่กรองแล้วไป `POST /v2/task.create` โดยมีโครงสร้างหลัก:

```json
{
  "message": { "content": "...persona + context..." },
  "agent_profile": "manus-1.6-lite",
  "locale": "th",
  "interactive_mode": false,
  "hide_in_task_list": true,
  "share_visibility": "private",
  "structured_output_schema": {
    "type": "object",
    "properties": {
      "should_speak": { "type": "boolean" },
      "message": { "type": "string" },
      "mood": { "type": "string", "enum": ["quiet", "curious", "concerned", "happy"] },
      "cooldown_seconds": { "type": "integer" }
    },
    "required": ["should_speak", "message", "mood", "cooldown_seconds"],
    "additionalProperties": false
  }
}
```

### Interactive chat request

ใน `ManusCompanionProvider.chat(message:snapshot:completion:)`:

- อ่าน `pixelcat.manus.chatTaskID` จาก `UserDefaults`
- ถ้าไม่มี task id: เรียก `POST /v2/task.create`
- ถ้ามี task id: เรียก `POST /v2/task.sendMessage`
- ทุกครั้งใช้ `agent_profile: manus-1.6-lite`
- เก็บ task id กลับใน `UserDefaults`
- หลัง POST ให้ poll `GET /v2/task.listMessages`

`task.sendMessage` body ปัจจุบัน:

```json
{
  "task_id": "...",
  "message": { "content": "..." },
  "agent_profile": "manus-1.6-lite"
}
```

## อาการบัคปัจจุบัน

เมื่อกริชส่งคำถามจาก input bubble:

1. bubble input แสดงได้แล้ว
2. กดส่งได้แล้ว
3. speech bubble ขึ้น `อั่งเปากำลังคิด…`
4. ผ่านไปสักพักขึ้น `ตอนนี้ Manus ยังตอบไม่ได้`
5. ไม่ได้รับคำตอบจาก Manus

ก่อนหน้านี้เคยมีอาการตอบคำถามเก่าก่อนหน้าแทนคำถามใหม่ด้วย จึงเพิ่ม timestamp filtering แล้ว แต่ยังไม่หายและตอนนี้มัก timeout

## จุดที่ควรตรวจเป็นอันดับแรก

### 1. Timestamp ของ Manus เป็น milliseconds

จาก OpenAPI schema ของ Manus:

```text
timestamp = Unix timestamp in milliseconds
```

โค้ดมี `eventIsAfter(_:date:)` ซึ่งพยายามรองรับ:

- `NSNumber`
- `Double`
- `Int`
- ISO8601 string

ต้องตรวจว่าการแปลง milliseconds เป็น seconds ถูกต้อง และควร log timestamp/raw event แบบไม่เปิดเผย key

### 2. รูปแบบ `assistant_message`

OpenAPI ระบุว่า event มีรูปแบบ:

```json
{
  "id": "event-id",
  "type": "assistant_message",
  "timestamp": 1730000000000,
  "assistant_message": {
    "content": "ข้อความจาก Manus",
    "attachments": []
  }
}
```

ตัวอ่านปัจจุบันตรวจ:

```swift
for event in messages where event["type"] as? String == "assistant_message" {
    guard eventIsAfter(event, date: notBefore) else { continue }
    if let assistant = event["assistant_message"] as? [String: Any],
       let text = assistant["content"] as? String,
       !text.isEmpty {
        completion(text)
        return
    }
}
```

ต้องตรวจ response จริงว่า `messages` เป็น `[[String: Any]]` ตามที่คาดหรือไม่ และ `assistant_message.content` เป็น String จริงหรือไม่

### 3. การกรอง event เก่า

ปัจจุบัน chat บันทึก:

```swift
let sentAt = Date().addingTimeInterval(-5)
```

แล้วส่ง `notBefore: sentAt` เข้า poller

การลบ 5 วินาทีช่วย clock skew แต่มีความเสี่ยงรับ response เก่าที่เกิดในช่วง 5 วินาทีก่อนส่งได้ ควรเปลี่ยนแนวทางเป็นใช้ event id/assistant event baseline ก่อนส่ง หรือใช้ timestamp ที่แม่นยำกว่า

วิธีที่ robust กว่า:

1. ก่อน `task.sendMessage` ให้ดึง messages ล่าสุดของ task และบันทึก `lastEventID` หรือ `lastAssistantEventID`
2. ส่งข้อความ
3. poll จนเจอ event id ใหม่ที่เป็น `assistant_message`
4. ไม่ใช้เพียงเวลาเป็นตัวกรอง

สำหรับ task ใหม่จาก `task.create` ไม่ต้อง baseline เพราะ task เพิ่งถูกสร้าง

### 4. สถานะ task เดิมอาจมี event ค้าง

UserDefaults เก็บ task id:

```text
pixelcat.manus.chatTaskID
```

ถ้า task เดิมเสียหรืออยู่ในสถานะผิด อาจต้องล้างค่าเพื่อทดสอบ task ใหม่:

```bash
defaults delete com.pixelcat.PixelCat pixelcat.manus.chatTaskID 2>/dev/null || true
```

แต่ bundle identifier ต้องตรวจจาก `Info.plist` ก่อน อย่าเดา ถ้าคำสั่งไม่ตรงให้ล้างด้วย bundle id จริง หรือเพิ่มเมนู reset chat task

### 5. Error response ถูกกลืน

ปัจจุบัน `post()` completion เป็นเพียง `[String: Any]?` และทิ้ง:

- HTTP status code
- response body error
- `request_id`
- `error.code`
- `error.message`

ควรเปลี่ยนเป็น result type เช่น:

```swift
enum ManusAPIResult<T> {
    case success(T)
    case failure(status: Int, code: String?, message: String?, requestID: String?)
}
```

อย่างน้อยให้ debug log แบบนี้:

```text
MANUS API path=/v2/task.create status=401 code=permission_denied request_id=... message=...
```

ห้าม log API key หรือ Authorization header

### 6. `listMessages` อาจคืน status/error ก่อน assistant message

ควรอ่าน:

```text
status_update.agent_status
```

ค่าที่สำคัญ:

- `running` → poll ต่อ
- `stopped` → ตรวจ assistant message/structured output
- `waiting` → สำหรับ interactive mode ปกติอาจต้องจัดการ แต่ companion chat ตั้ง `interactive_mode=false`
- `error` → แสดง error จริง

อย่าใช้ status เก่าจาก task เดิมเป็นตัวจบรอบใหม่ ต้องกรองตาม event id/timestamp ด้วย

## UI ที่เพิ่งแก้

มี class:

```swift
final class CompanionInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
```

input panel ถูกสร้างด้วย:

```swift
CompanionInputPanel(
    contentRect: NSRect(x: 0, y: 0, width: 330, height: 42),
    styleMask: .borderless,
    backing: .buffered,
    defer: false
)
```

ตั้งค่า:

- `.floating`
- `canJoinAllSpaces`
- `fullScreenAuxiliary`
- visual effect popover
- border/shadow
- input width อย่างน้อย 240
- `makeKey()`
- `makeFirstResponder(input)` บน `DispatchQueue.main.async`

ตอนส่ง:

```swift
chatWindow?.orderOut(nil)
say("อั่งเปากำลังคิด…", for: 30.0)
```

เมื่อเสร็จให้เรียก `say(response, for: 8.0)` โดยตรง ไม่ต้องใช้ transcript window

## Debug ที่มีอยู่

เปิดแอปด้วย:

```bash
PIXELCAT_MANUS_API_KEY='KEY_ใหม่' PIXELCAT_DEBUG=1 open PixelCat.app
```

อย่าให้ผู้ใช้ส่งบรรทัด command ที่มี key กลับมาในแชต

log ที่มีอยู่:

```text
COMPANION STATUS ...
COMPANION manus-lite ...
COMPANION local-fallback ...
MANUS POLL attempt=N events=...
```

ควรเพิ่ม log ของ HTTP response อย่างปลอดภัย:

```text
MANUS HTTP path=/v2/task.create status=200
MANUS CREATE task_id_present=true
MANUS HTTP path=/v2/task.listMessages status=200
MANUS POLL attempt=2 count=5 types=user_message,status_update,assistant_message
MANUS ASSISTANT candidate id=... fresh=true content_length=123
```

ไม่ควร log เนื้อหาข้อความเต็ม เพราะอาจมีข้อมูลส่วนตัว

## ข้อควรระวังสำคัญ

1. อย่า hardcode API key
2. อย่า log API key
3. อย่าส่ง source code, clipboard, `.env` หรือ secret ไป Manus
4. อย่าใช้ key ที่ผู้ใช้เคยแปะในแชต
5. ต้อง build ด้วย `./build.sh` หลังแก้
6. ต้องรัน regression tests อย่างน้อย:

```bash
zsh check-work-inbox.sh
zsh check-work-notification.sh
zsh check-context-rescue.sh
zsh check-waiting-reminder.sh
```

## สถานะ build ล่าสุด

ก่อนส่งต่อ build ผ่าน:

```text
built + signed → PixelCat.app
```

และ regression หลักผ่านในรอบก่อนหน้า

## สิ่งที่อยากให้ AI ตัวถัดไปทำ

ลำดับที่แนะนำ:

1. ตรวจ `Info.plist` หา bundle identifier จริง
2. เพิ่ม HTTP status/error/request_id logging แบบ redact
3. รันแอปด้วย key ใหม่ของผู้ใช้เอง ไม่ใช้ key ที่เคยเปิดเผย
4. ส่งคำถามสั้น ๆ หนึ่งข้อความ
5. เก็บเฉพาะ log `MANUS HTTP`, `MANUS POLL`, `COMPANION STATUS`
6. แก้ parser/รอบ event โดยใช้ event id baseline ไม่ใช่ timestamp อย่างเดียว
7. เพิ่ม timeout ที่แสดง error เฉพาะเจาะจง ไม่ค้าง “กำลังคิด”
8. เพิ่มเมนู reset Manus chat task หาก task เดิมเสีย
9. build และรัน regression tests

## เกณฑ์ว่าสำเร็จ

ถือว่าสำเร็จเมื่อ:

```text
กริชพิมพ์คำถาม A → อั่งเปาตอบ A
กริชพิมพ์คำถาม B → อั่งเปาตอบ B ไม่ใช่ A
ไม่มีคำตอบเก่าถูกนำมาใช้
API error แสดงสาเหตุที่พอวินิจฉัยได้
ไม่มีการค้าง “อั่งเปากำลังคิด…” ถาวร
ไม่มี API key ใน source/log
```

## Persona ที่ต้องคงไว้

อั่งเปาควรพูดกับ **กริช** ในฐานะ:

- แมวเพศเมีย
- เพื่อนร่วมโต๊ะ
- อบอุ่นและกระชับ
- ซื่อสัตย์ว่าเป็น AI
- ไม่อ้างว่าเห็นหน้าจอหรือ source code ถ้าไม่ได้รับข้อมูลนั้น
- ใช้บริบท Claude/Codex ที่ถูกกรองแล้วเพื่อช่วยตอบเรื่อง workflow
