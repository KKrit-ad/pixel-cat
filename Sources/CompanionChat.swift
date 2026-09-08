// CompanionChat
// กล่องคุยและการกู้สถานการณ์เมื่อสมองออนไลน์ล่ม

import Cocoa

final class CompanionInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }   // Esc = เก็บกล่องพิมพ์
}

/// ผลลัพธ์ของหนึ่งรอบสนทนา แยก error ให้ชัดว่าเป็นอะไร จะได้ไม่ขึ้น "ยังตอบไม่ได้" ลอย ๆ
enum CompanionChatOutcome {
    case reply(String)
    case failure(String)
}

/// กำแพงระหว่าง error ของ provider กับสิ่งที่อั่งเปาพูดจริง
/// รายละเอียดเทคนิคยังเก็บไว้ใน debug log แต่ห้ามหลุดเข้า speech bubble
enum CompanionChatResilience {
    static func claudeCLIFailure(stdout: String, stderr: String, status: Int32) -> String {
        let combined = [stdout, stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hint = combined.lowercased()
        if hint.contains("login") || hint.contains("authenticat") || hint.contains("unauthorized") {
            return "สมอง Claude ของน้องยังไม่ได้ล็อกอิน พ่อเปิด Claude Code แล้วล็อกอินให้น้องก่อนนะคะ"
        }
        if hint.contains("session limit") || hint.contains("limit") || hint.contains("quota") {
            let reset: String? = {
                guard let range = combined.range(of: "resets ", options: .caseInsensitive) else { return nil }
                let line = String(combined[range.upperBound...].prefix { $0 != "\n" && $0 != "\r" })
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return line.isEmpty ? nil : String(line.prefix(48))
            }()
            if let reset {
                return "วันนี้น้องใช้สมอง Claude เต็มแล้ว ขอพักถึง \(reset) แล้วค่อยคุยกันนะพ่อ"
            }
            return "วันนี้น้องใช้สมอง Claude เต็มแล้ว ขอพักแป๊บหนึ่งแล้วค่อยคุยกันนะพ่อ"
        }
        return "provider=claude-cli status=\(status) detail=\(String(combined.prefix(160)))"
    }

    static func localReply(to message: String, snapshot: CompanionSnapshot) -> String {
        let q = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if q.contains("สวัสดี") || q.contains("หวัดดี") || q == "ดี" {
            return "พ่อมาแล้วเหรอคะ น้องกำลังคิดถึงพอดีเลย เมี๊ยว~"
        }
        if q.contains("คิดถึง") || q.contains("รัก") {
            return "น้องก็คิดถึงและรักพ่อนะคะ มาลูบหัวน้องหน่อย~"
        }
        if q.contains("เหนื่อย") || q.contains("เครียด") || q.contains("ไม่ไหว") {
            return "พักกับน้องสักครู่นะพ่อ ไม่ต้องเก่งตลอดเวลาก็ได้ค่ะ"
        }
        if q.contains("เป็นไง") || q.contains("สบายดี") {
            return "น้องสบายดีค่ะ แค่ดีใจที่พ่อหันมาคุยด้วย"
        }
        if q.contains("ทำอะไรอยู่") {
            return "น้องกำลังนั่งเฝ้าพ่ออยู่ค่ะ เผื่อพ่ออยากพักมาเล่นด้วยกัน"
        }
        if q.contains("ขอบคุณ") {
            return "ยินดีค่ะพ่อ ขอค่าตอบแทนเป็นลูบหัวหนึ่งทีนะ"
        }
        if q.contains("งาน") || q.contains("สถานะ") {
            if snapshot.workingCount == 0 && snapshot.waitingCount == 0 {
                return "ตอนนี้น้องไม่เห็นงานที่กำลังรันหรืองานรอตอบเลยค่ะพ่อ"
            }
            return "ตอนนี้มีงานกำลังทำ \(snapshot.workingCount) งาน และรอพ่อไปตอบ \(snapshot.waitingCount) งานค่ะ"
        }
        if q.contains("ไหม") || q.contains("อะไร") || q.contains("ทำไม")
            || q.contains("ยังไง") || q.hasSuffix("?") || q.hasSuffix("？") {
            return "เรื่องนี้น้องยังตอบแทนสมองออนไลน์ไม่ได้ค่ะ แต่พ่อถามน้องใหม่อีกทีตอนมันตื่นนะ"
        }
        return "น้องฟังอยู่นะพ่อ ถึงตอนนี้สมองออนไลน์จะง่วงไปหน่อย แต่น้องยังอยู่ตรงนี้ค่ะ"
    }

    static func visibleFailure(providerFailure: String, message: String,
                               snapshot: CompanionSnapshot) -> String {
        // ข้อความ quota/auth ที่แปลงเป็นภาษาของอั่งเปาแล้ว ปลอดภัยที่จะแสดง
        if providerFailure.hasPrefix("วันนี้น้อง") || providerFailure.hasPrefix("สมอง Claude") {
            return providerFailure
        }
        return localReply(to: message, snapshot: snapshot)
    }
}
