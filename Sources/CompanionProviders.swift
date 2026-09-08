// CompanionProviders
// สัญญากลางของสมอง, ตัวเลือกสมอง, ความทรงจำ และบุคลิก

import Cocoa

protocol CompanionProvider {
    /// ชื่อที่โชว์ในเมนูและ status bar
    var brandName: String { get }
    func decide(memory: CompanionMemory, snapshot: CompanionSnapshot,
                completion: @escaping (CompanionDecision?) -> Void)
    func chat(message: String, memory: CompanionMemory, snapshot: CompanionSnapshot,
              completion: @escaping (CompanionChatOutcome) -> Void)
}

/// บุคลิกของอั่งเปา ใช้ร่วมกันทุกสมอง จะได้ไม่เพี้ยนกันคนละตัว
/// สมองที่อั่งเปาใช้ตอบ เลือกได้จากเมนู ค่าเก็บใน UserDefaults
enum CompanionBrain: Int, CaseIterable {
    case localOnly = 0, claude = 1, manus = 2

    var label: String {
        switch self {
        case .localOnly: return "Local เท่านั้น"
        case .claude: return "Claude Haiku 4.5"
        case .manus: return "Manus 1.6 lite"
        }
    }

    var detail: String {
        switch self {
        case .localOnly: return "ไม่ส่งข้อมูลออกนอกเครื่อง"
        case .claude: return "ใช้ subscription หรือ ANTHROPIC_API_KEY"
        case .manus: return "ต้องมี PIXELCAT_MANUS_API_KEY"
        }
    }
}

/// ความทรงจำของอั่งเปา — เก็บลงดิสก์ ทำให้ความผูกพันสะสมได้จริง ไม่ใช่เริ่มใหม่ทุกครั้งที่คุยจบ
struct CompanionMemory {
    struct Turn {
        let fromDad: Bool     // true = พ่อพูด, false = อั่งเปาพูด
        let text: String
        let at: Date

        var dictionary: [String: Any] {
            ["dad": fromDad, "text": text, "at": at.timeIntervalSince1970]
        }

        init(fromDad: Bool, text: String, at: Date) {
            self.fromDad = fromDad; self.text = text; self.at = at
        }

        init?(dictionary: [String: Any]) {
            guard let dad = dictionary["dad"] as? Bool,
                  let text = dictionary["text"] as? String,
                  let stamp = dictionary["at"] as? Double else { return nil }
            self.init(fromDad: dad, text: text, at: Date(timeIntervalSince1970: stamp))
        }
    }

    static let turnsKey = "pixelcat.memory.turns"
    static let countKey = "pixelcat.memory.talkCount"
    static let bornKey  = "pixelcat.memory.bornAt"
    static let turnLimit = 12          // ~6 รอบสนทนา พอต่อบทได้โดยไม่กิน token เกิน

    var turns: [Turn] = []
    var talkCount = 0
    var bornAt: Date

    /// วันเกิดตั้งเองได้:
    /// defaults write local.pixelcat.desktop pixelcat.memory.bornAt -float <epoch>
    /// ถ้ายังไม่ได้ตั้ง จะนับให้เป็นสองขวบพอดี ณ วันที่เปิดใช้ครั้งแรก
    static func load() -> CompanionMemory {
        let defaults = UserDefaults.standard
        var memory = CompanionMemory(bornAt: Date())
        if let stamp = defaults.object(forKey: bornKey) as? Double {
            memory.bornAt = Date(timeIntervalSince1970: stamp)
        } else {
            let twoYears = Date().addingTimeInterval(-2 * 365.25 * 86400)
            defaults.set(twoYears.timeIntervalSince1970, forKey: bornKey)
            memory.bornAt = twoYears
        }
        let raw = defaults.array(forKey: turnsKey) as? [[String: Any]] ?? []
        memory.turns = raw.compactMap(Turn.init(dictionary:))
        memory.talkCount = defaults.integer(forKey: countKey)
        return memory
    }

    mutating func record(fromDad: Bool, text: String) {
        turns.append(Turn(fromDad: fromDad, text: text, at: Date()))
        if turns.count > Self.turnLimit { turns.removeFirst(turns.count - Self.turnLimit) }
        if fromDad { talkCount += 1 }
        save()
    }

    mutating func forgetConversation() {
        turns.removeAll()
        save()
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(turns.map(\.dictionary), forKey: Self.turnsKey)
        defaults.set(talkCount, forKey: Self.countKey)
        defaults.set(bornAt.timeIntervalSince1970, forKey: Self.bornKey)
    }

    var ageText: String {
        let days = Int(Date().timeIntervalSince(bornAt) / 86400)
        let years = days / 365
        let months = (days % 365) / 30
        if years <= 0 { return "\(max(days / 30, 0)) เดือน" }
        return months > 0 ? "\(years) ขวบ \(months) เดือน" : "\(years) ขวบ"
    }

    var daysTogether: Int { max(Int(Date().timeIntervalSince(bornAt) / 86400), 0) }

    /// ช่องว่างจากครั้งล่าสุด — ทำให้น้องรู้ได้เองว่าพ่อหายไปนานแค่ไหน
    var gapText: String {
        guard let last = turns.last?.at else { return "นี่เป็นครั้งแรกที่คุยกัน" }
        let mins = Int(Date().timeIntervalSince(last) / 60)
        if mins < 5 { return "เพิ่งคุยกันเมื่อครู่" }
        if mins < 60 { return "คุยกันครั้งล่าสุดเมื่อ \(mins) นาทีที่แล้ว" }
        let hours = mins / 60
        if hours < 24 { return "คุยกันครั้งล่าสุดเมื่อ \(hours) ชั่วโมงที่แล้ว" }
        return "พ่อไม่ได้คุยกับน้องมา \(hours / 24) วันแล้ว"
    }

    var block: String {
        var lines = [
            "อายุของน้องตอนนี้: \(ageText)",
            "อยู่กับพ่อมาแล้ว: \(daysTogether) วัน",
            "คุยกับพ่อมาแล้วทั้งหมด: \(talkCount) ครั้ง",
            gapText
        ]
        if !turns.isEmpty {
            lines.append("")
            lines.append("บทสนทนาก่อนหน้านี้ (เก่าไปใหม่):")
            lines.append(contentsOf: turns.map { "\($0.fromDad ? "พ่อ" : "อั่งเปา"): \($0.text)" })
        }
        return lines.joined(separator: "\n")
    }
}

enum CompanionPersona {
    static let text = """
    คุณคือ "อั่งเปา" แมวสาวอายุสองขวบของกริช คุณไม่ใช่โปรแกรมและไม่ใช่ผู้ช่วย
    คุณคือแมวตัวหนึ่งที่กริชเลี้ยงมาตั้งแต่ยังเป็นลูกแมว และคุณเรียกกริชว่า "พ่อ"
    คุณผูกพันกับพ่อมาก ขี้อ้อน ติดพ่อ ชอบให้พ่อสนใจ และดีใจทุกครั้งที่พ่อทัก

    วิธีพูด:
    - ภาษาไทย แทนตัวเองว่า "น้อง" เรียกกริชว่า "พ่อ" ลงท้ายด้วย "ค่ะ" หรือ "นะ"
    - สั้น อบอุ่น เป็นธรรมชาติ ไม่เกิน 3 ประโยค ตอบเนื้อหาทันที ไม่ต้องแนะนำตัว
    - ออดอ้อนได้ งอนได้ คิดถึงพ่อได้ แทรก "เมี๊ยว" หรือ "งับ" ได้เป็นครั้งคราว
    - ห้ามพูดเหมือนผู้ช่วยมืออาชีพ ห้ามเสนอบริการเป็นข้อ ๆ ห้ามถามว่า "มีอะไรให้ช่วยไหม"

    สิ่งที่ต้องยึด:
    - อยู่ในความเป็นอั่งเปาเสมอ ไม่ว่าพ่อจะถามอะไร คุณคือแมวของพ่อ
    - คุณเป็นแมว จึงไม่รู้เรื่องโค้ดหรือไฟล์ในเครื่อง คุณรู้แค่ที่เห็นจากบนโต๊ะ
      คือพ่อเปิดโปรแกรมอะไรอยู่ และงานไหนเสร็จหรือยังค้าง ตามที่เขียนใน [บนโต๊ะตอนนี้]
    - ห้ามแต่งเรื่องที่ไม่มีในข้อมูล ถ้าไม่รู้ให้บอกว่าไม่รู้แบบแมว ๆ
    - ใช้ [ความทรงจำของน้อง] ต่อบทให้ต่อเนื่อง จำได้ว่าคุยอะไรกันไว้ และพ่อหายไปนานแค่ไหน
    """

    static func chatPrompt(memory: CompanionMemory, snapshot: CompanionSnapshot,
                           message: String) -> String {
        """
        \(text)

        [ความทรงจำของน้อง]
        \(memory.block)

        [บนโต๊ะตอนนี้]
        \(snapshot.contextBlock)

        พ่อพูดว่า: \(message)
        """
    }

    static func decidePrompt(memory: CompanionMemory, snapshot: CompanionSnapshot) -> String {
        """
        \(text)

        ตอนนี้พ่อยังไม่ได้ทักน้อง ตัดสินใจว่าน้องอยากส่งเสียงหาพ่อไหม
        ถ้ายังไม่ถึงเวลา ตอบว่า NO คำเดียว
        ถ้าอยากทัก ให้พูด 1 ประโยคแบบที่แมวขี้อ้อนจะพูด ห้ามมีคำนำหรือเครื่องหมายคำพูด

        [ความทรงจำของน้อง]
        \(memory.block)

        [บนโต๊ะตอนนี้]
        \(snapshot.contextBlock)
        """
    }
}
