// CatVoice
// เสียงของน้อง — เล่นจาก WAV ที่ฝังไว้ ไม่แตะไฟล์เสียงข้างนอกและไม่ต่อเน็ต

import Cocoa

/// เสียงแต่ละแบบ เลือกตามอารมณ์ ไม่ใช่ตามเหตุการณ์ จะได้ใช้ซ้ำได้หลายที่
enum CatSound: String, CaseIterable {
    case meow       // เรียกร้อง/ทัก แบบเต็มเสียง
    case mew        // เหมียวสั้น สดใส
    case trill      // ครืดๆ ดีใจ พอใจ
    case mrrp       // ตกใจ สะดุ้ง ผิดหวัง
    case purr       // ครางตอนถูกลูบ
}

/// คุมเสียงทั้งหมดไว้ที่เดียว เพื่อให้กติกา "ไม่รบกวน" อยู่ในที่เดียวจริง ๆ
final class CatVoice {
    static let shared = CatVoice()

    /// ค่าเริ่มต้นเปิดไว้แต่เบา ๆ ปิดได้จากเมนู แล้วจำค่า
    var enabled: Bool = UserDefaults.standard.object(forKey: "voiceOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "voiceOn") }
    }
    /// ระดับเสียงตั้งไว้ต่ำ ตั้งใจให้เป็นเสียงประกอบ ไม่ใช่เสียงเรียก
    var volume: Float = 0.32
    /// ปิดชั่วคราวระหว่างโฟกัส/หลับ โดยไม่แตะค่าที่พ่อตั้งไว้
    var muted = false

    /// ในโหมดจำลองจะไม่เล่นเสียงจริง แต่บันทึกไว้ให้ regression ตรวจได้
    private let simulating = ProcessInfo.processInfo.environment["PIXELCAT_SIMVOICE"] != nil
    private(set) var playLog: [String] = []

    private var cache: [CatSound: NSSound] = [:]
    private var lastPlayedAt: [CatSound: Date] = [:]
    private var lastAnyAt = Date.distantPast

    private init() {}

    /// เสียงที่โหลดแล้วเก็บไว้ใช้ซ้ำ ไม่ต้อง decode base64 ทุกครั้ง
    private func sound(_ kind: CatSound) -> NSSound? {
        if let cached = cache[kind] { return cached }
        guard let b64 = CAT_VOICE_WAV[kind.rawValue],
              let data = Data(base64Encoded: b64),
              let made = NSSound(data: data) else { return nil }
        cache[kind] = made
        return made
    }

    /// - Parameters:
    ///   - minGap: เว้นระยะจากเสียงเดียวกันครั้งก่อน กันเสียงรัวตอนขยับถี่ ๆ
    ///   - gapAny: เว้นระยะจากเสียงใดก็ได้ครั้งก่อน กันเสียงซ้อนกันหลายเหตุการณ์
    @discardableResult
    func play(_ kind: CatSound, minGap: Double = 2.5, gapAny: Double = 0.6) -> Bool {
        guard enabled, !muted else { return false }
        let now = Date()
        guard now.timeIntervalSince(lastPlayedAt[kind] ?? .distantPast) >= minGap,
              now.timeIntervalSince(lastAnyAt) >= gapAny else { return false }
        lastPlayedAt[kind] = now
        lastAnyAt = now
        if simulating {
            playLog.append(kind.rawValue)
            return true
        }
        guard let s = sound(kind) else { return false }
        s.volume = volume
        if s.isPlaying { s.stop() }
        s.play()
        return true
    }

    /// ให้เสียงเงียบทันทีตอนสั่งปิดหรือเข้าโฟกัส ไม่ค้างเสียงที่เล่นอยู่
    func stopAll() {
        for s in cache.values where s.isPlaying { s.stop() }
    }
}
