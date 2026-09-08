// Config
// ค่าคงที่และ environment switch ที่ทุกส่วนใช้ร่วมกัน

import Cocoa

import Cocoa
import Carbon
import SQLite3

// ─────────────────────────────────────────────────────────────
// Sprite sheet — 82 frames of 128×100, embedded as a PNG so the app is one file.
// ─────────────────────────────────────────────────────────────
let SPRITE_W = 128
let SPRITE_H = 100
let SHADOW_H = 6          // แถวพิกเซลใต้ตัวที่กันไว้วาดเงา
// ─────────────────────────────────────────────────────────────
// กล่องจดหมายจาก Claude Code — hooks เขียนไฟล์นี้ น้องอ่านแล้วตอบสนอง
// รูปแบบบรรทัดเดียว:  EVENT|ข้อความ    เช่น  done|เสร็จแล้วน้า~
// EVENT เดิม: busy / done / ask / fail
// EVENT ละเอียด: coding / edit / build / test / test_pass / test_fail / permission
// ─────────────────────────────────────────────────────────────
let HOLD_DELAY = 0.22        // กดค้างนานกว่านี้ = อุ้ม สั้นกว่า = เปิดเมนู
let SESSIONS = ProcessInfo.processInfo.environment["PIXELCAT_SESSIONS"]
    ?? NSString(string: "~/.pixelcat/sessions").expandingTildeInPath
let CODEX_STATE_DB = ProcessInfo.processInfo.environment["PIXELCAT_CODEX_STATE"]
    ?? NSString(string: "~/.codex/state_5.sqlite").expandingTildeInPath
let CODEX_HISTORY_DB = ProcessInfo.processInfo.environment["PIXELCAT_CODEX_HISTORY"]
    ?? NSString(string: "~/.codex/thread_history_1.sqlite").expandingTildeInPath
let SESSION_STALE = 900.0     // เซสชันที่เงียบเกิน 15 นาที ถือว่าตายแล้ว
let WAIT_REMINDER_AFTER = Double(ProcessInfo.processInfo.environment["PIXELCAT_WAIT_REMINDER_AFTER"] ?? "")
    ?? 180.0                  // รอนาน 3 นาทีแล้วเตือนซ้ำหนึ่งครั้ง ถ้ายังไม่ได้เปิดดู
let LONG_WORK_POSE_AFTER = Double(ProcessInfo.processInfo.environment["PIXELCAT_LONG_WORK_POSE_AFTER"] ?? "")
    ?? 120.0                  // งานยาว 2 นาทีแล้วหยุดเดินมานั่งเฝ้าหนึ่งครั้ง
let INBOX_MAX = 12            // แสดงต่อ section มากสุดเท่านี้ ที่เหลือยุบเป็นบรรทัดเดียว
let INBOX = NSString(string: "~/.pixelcat/inbox").expandingTildeInPath
