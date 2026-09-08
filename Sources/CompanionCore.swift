// CompanionCore
// โหมด companion, snapshot บริบท และจังหวะคิดของอั่งเปา

import Cocoa

// ── Phase 1: local companion context engine (no network, no token) ──
enum CompanionMode: Int {
    case off = 0, quietWatch = 1, companion = 2
    var label: String {
        switch self {
        case .off: return "ปิด"
        case .quietWatch: return "เฝ้าเงียบ"
        case .companion: return "ผู้ช่วย"
        }
    }
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
    /// งานจริงที่กำลังเปิดอยู่ บรรทัดละงาน — ชื่อโปรเจกต์กับสถานะเท่านั้น ไม่มี path เต็ม ไม่มีเนื้อโค้ด
    var workBriefs: [String] = []

    /// บล็อกบริบทที่ทั้ง Manus และ Claude ใช้ร่วมกัน จะได้ไม่เขียน prompt คนละแบบ
    var contextBlock: String {
        var lines = [
            "active_app=\(activeApp)",
            "user_idle_seconds=\(Int(userIdleSeconds))",
            "working_count=\(workingCount)",
            "waiting_count=\(waitingCount)",
            "attention_count=\(attentionCount)",
            "hottest_context_percent=\(Int(hottestContext))",
            "recent_event=\(recentEvent)"
        ]
        if workBriefs.isEmpty {
            lines.append("open_work=(ไม่มีงานเปิดอยู่)")
        } else {
            lines.append("open_work:")
            lines.append(contentsOf: workBriefs.map { "  - \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}

struct CompanionDecision {
    let message: String
    let mood: String
    let cooldown: Double
}

/// นาฬิกาสถานะของคำตอบ AI — ไม่รู้เรื่อง AppKit/Manus จึงจำลองเวลาได้ตรง ๆ ในเทสต์
struct CompanionThinkingCycle {
    enum Phase: Equatable { case idle, listening, thinking, longThinking }

    private(set) var phase: Phase = .idle
    private(set) var elapsed = 0.0

    mutating func start() {
        phase = .listening
        elapsed = 0
    }

    mutating func advance(by seconds: Double) {
        guard phase != .idle else { return }
        elapsed += max(0, seconds)
        if elapsed >= 8 {
            phase = .longThinking
        } else if elapsed >= 0.45 {
            phase = .thinking
        } else {
            phase = .listening
        }
    }

    mutating func stop() {
        phase = .idle
        elapsed = 0
    }

    var message: String {
        switch phase {
        case .idle: return ""
        case .listening: return "อั่งเปาฟังอยู่นะ…"
        case .thinking:
            let count = Int(max(0, elapsed - 0.45) / 0.45) % 3 + 1
            return "อั่งเปากำลังคิด" + String(repeating: "·", count: count)
        case .longThinking: return "ขอคิดอีกนิดนะ…"
        }
    }
}
